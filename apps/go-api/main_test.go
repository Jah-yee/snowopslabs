package main

import (
	"bytes"
	"encoding/json"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/prometheus/client_golang/prometheus/promhttp"
	"go.opentelemetry.io/otel"
)

func TestRouteLabel(t *testing.T) {
	tests := []struct {
		name string
		path string
		want string
	}{
		{"root is a known route", "/", "/"},
		{"health is a known route", "/health", "/health"},
		{"unknown path is bucketed", "/does-not-exist", "other"},
		{"attacker-controlled path cannot create a series", "/../../etc/passwd", "other"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := routeLabel(tt.path); got != tt.want {
				t.Errorf("routeLabel(%q) = %q, want %q", tt.path, got, tt.want)
			}
		})
	}
}

// Every served route must be metered. "/" was previously unmetered, so k6
// traffic against the app root produced logs but a flat request-rate graph.
func TestInstrument_MetersEveryRoute(t *testing.T) {
	tests := []struct {
		name      string
		path      string
		status    int
		wantRoute string
		wantCount int
	}{
		{"root", "/", http.StatusOK, "/", 1},
		{"version", "/version", http.StatusOK, "/version", 1},
		{"error status is labelled", "/ready", http.StatusServiceUnavailable, "/ready", 1},
		{"metrics endpoint is not self-metered", "/metrics", http.StatusOK, "/metrics", 0},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			httpRequestDuration.Reset()
			h := instrument(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
				w.WriteHeader(tt.status)
			}))
			h.ServeHTTP(httptest.NewRecorder(), httptest.NewRequest(http.MethodGet, tt.path, nil))

			// Assert on the actual exposition Prometheus scrapes. Semconv has no
			// request counter, so the histogram's _count series IS the count.
			want := `http_server_request_duration_seconds_count{app="` + serviceName +
				`",http_request_method="GET",http_response_status_code="` + strconv.Itoa(tt.status) +
				`",http_route="` + tt.wantRoute + `"} ` + strconv.Itoa(tt.wantCount)
			body := scrapeMetrics(t)
			if tt.wantCount == 0 {
				if strings.Contains(body, `http_route="`+tt.wantRoute+`"`) {
					t.Errorf("expected no series for http_route=%q, got:\n%s", tt.wantRoute, body)
				}
				return
			}
			if !strings.Contains(body, want) {
				t.Errorf("missing %q in /metrics output:\n%s", want, body)
			}
		})
	}
}

// Turning tracing on used to replace the access-log middleware, which silently
// emptied the Loki log stream. The chain must keep logging either way.
func TestAccessLog_LogsRequestsAndSkipsProbes(t *testing.T) {
	tests := []struct {
		name    string
		path    string
		wantLog bool
	}{
		{"root is logged", "/", true},
		{"health probe is not logged", "/health", false},
		{"metrics scrape is not logged", "/metrics", false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			var buf bytes.Buffer
			logger = slog.New(slog.NewJSONHandler(&buf, nil))

			h := accessLog(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {}))
			h.ServeHTTP(httptest.NewRecorder(), httptest.NewRequest(http.MethodGet, tt.path, nil))

			logged := strings.Contains(buf.String(), `"msg":"request"`)
			if logged != tt.wantLog {
				t.Fatalf("access log for %q: got logged=%v, want %v (output: %s)", tt.path, logged, tt.wantLog, buf.String())
			}
			if tt.wantLog {
				var line map[string]any
				if err := json.Unmarshal(buf.Bytes(), &line); err != nil {
					t.Fatalf("log line is not valid JSON (Loki parses it as JSON): %v", err)
				}
				if line["path"] != tt.path {
					t.Errorf("log path = %v, want %q", line["path"], tt.path)
				}
			}
		})
	}
}

// scrapeMetrics returns the /metrics exposition, the same text Prometheus reads.
func scrapeMetrics(t *testing.T) string {
	t.Helper()
	rec := httptest.NewRecorder()
	promhttp.Handler().ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/metrics", nil))
	return rec.Body.String()
}

// handlerEnv points the handlers at a test upstream and a quiet logger, and
// puts the package's switches back afterwards.
func handlerEnv(t *testing.T, upstream string) *bytes.Buffer {
	t.Helper()
	var logs bytes.Buffer
	prevURL, prevLogger, prevTracer := upstreamURL, logger, tracer
	upstreamURL = upstream
	logger = slog.New(slog.NewJSONHandler(&logs, nil))
	tracer = otel.Tracer("test")
	t.Cleanup(func() { upstreamURL, logger, tracer = prevURL, prevLogger, prevTracer })
	return &logs
}

func serve(t *testing.T, h http.HandlerFunc, path string) (int, map[string]any) {
	t.Helper()
	rec := httptest.NewRecorder()
	h(rec, httptest.NewRequest(http.MethodGet, path, nil))
	var body map[string]any
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("%s did not answer JSON: %v: %s", path, err, rec.Body.String())
	}
	return rec.Code, body
}

// An upstream that answers with status, or a URL nothing listens on.
func upstreamAt(t *testing.T, status int) string {
	t.Helper()
	if status == 0 {
		srv := httptest.NewServer(http.NotFoundHandler())
		srv.Close()
		return srv.URL
	}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(status)
	}))
	t.Cleanup(srv.Close)
	return srv.URL
}

func TestRoot_CallsTheUpstreamWhenOneIsSet(t *testing.T) {
	tests := []struct {
		name       string
		upstream   int // 0: nothing listens; -1: no UPSTREAM_URL
		wantStatus int
		wantKey    string
		wantText   string
	}{
		{"no upstream: the body is unchanged", -1, http.StatusOK, "", ""},
		{"a healthy upstream is reported", http.StatusOK, http.StatusOK, "upstreamStatus", ""},
		{"an upstream that fails makes the request fail", http.StatusServiceUnavailable, http.StatusBadGateway, "error", "answered 503"},
		{"an unreachable upstream makes the request fail", 0, http.StatusBadGateway, "error", "connection refused"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			url := ""
			if tt.upstream >= 0 {
				url = upstreamAt(t, tt.upstream)
			}
			logs := handlerEnv(t, url)
			code, body := serve(t, handleRoot, "/")
			if code != tt.wantStatus {
				t.Fatalf("status = %d, want %d: %v", code, tt.wantStatus, body)
			}
			if tt.wantKey == "" {
				if _, ok := body["upstreamStatus"]; ok {
					t.Errorf("body names an upstream although none is set: %v", body)
				}
				return
			}
			got, ok := body[tt.wantKey]
			if !ok {
				t.Fatalf("body has no %q: %v", tt.wantKey, body)
			}
			if tt.wantText != "" {
				if !strings.Contains(got.(string), tt.wantText) {
					t.Errorf("%s = %q, want it to contain %q", tt.wantKey, got, tt.wantText)
				}
				if !strings.Contains(logs.String(), "upstream call failed") {
					t.Errorf("the failure was not logged: %s", logs.String())
				}
			}
		})
	}
}

func TestReady_ReportsTheUpstreamWithoutFailingReadiness(t *testing.T) {
	tests := []struct {
		name         string
		upstream     int
		wantUpstream string
	}{
		{"healthy upstream", http.StatusOK, "ok"},
		{"failing upstream", http.StatusBadGateway, "answered 502"},
		{"unreachable upstream", 0, "connection refused"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			handlerEnv(t, upstreamAt(t, tt.upstream))
			code, body := serve(t, handleReady, "/ready")
			if code != http.StatusOK {
				t.Fatalf("readiness = %d, want 200: a dependency must not pull the pod out of the Service", code)
			}
			if got, _ := body["upstream"].(string); !strings.Contains(got, tt.wantUpstream) {
				t.Errorf("upstream = %q, want it to contain %q", got, tt.wantUpstream)
			}
		})
	}
	t.Run("no upstream: the body is unchanged", func(t *testing.T) {
		handlerEnv(t, "")
		_, body := serve(t, handleReady, "/ready")
		if _, ok := body["upstream"]; ok {
			t.Errorf("body names an upstream although none is set: %v", body)
		}
	})
}

func TestWaitBeforeServing(t *testing.T) {
	handlerEnv(t, "")
	stopped := make(chan os.Signal, 1)
	stopped <- syscall.SIGTERM
	tests := []struct {
		name  string
		delay time.Duration
		sig   chan os.Signal
		want  bool
		atMin time.Duration
	}{
		{"no delay serves at once", 0, make(chan os.Signal), true, 0},
		{"a delay holds the listener back", 50 * time.Millisecond, make(chan os.Signal), true, 50 * time.Millisecond},
		{"a signal during the delay stops the start", time.Hour, stopped, false, 0},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			start := time.Now()
			if got := waitBeforeServing(tt.delay, tt.sig); got != tt.want {
				t.Fatalf("waitBeforeServing = %v, want %v", got, tt.want)
			}
			if took := time.Since(start); took < tt.atMin {
				t.Errorf("returned after %v, want at least %v", took, tt.atMin)
			}
		})
	}
}

func TestDoWork_TakesTheCalibratedTime(t *testing.T) {
	calibrateWork()
	tests := []struct {
		name    string
		ms      int
		atLeast time.Duration
		atMost  time.Duration
	}{
		{"no work returns at once", 0, 0, 5 * time.Millisecond},
		{"40ms of work takes about 40ms", 40, 20 * time.Millisecond, 400 * time.Millisecond},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			start := time.Now()
			doWork(tt.ms)
			took := time.Since(start)
			if took < tt.atLeast || took > tt.atMost {
				t.Errorf("doWork(%d) took %v, want between %v and %v", tt.ms, took, tt.atLeast, tt.atMost)
			}
		})
	}
}

func TestGetIntEnv(t *testing.T) {
	tests := []struct {
		name  string
		value string
		set   bool
		want  int
	}{
		{"unset uses the default", "", false, 7},
		{"a number is read", "30", true, 30},
		{"a negative number uses the default", "-5", true, 7},
		{"text uses the default", "soon", true, 7},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if tt.set {
				t.Setenv("ZZ_INT", tt.value)
			}
			if got := getIntEnv("ZZ_INT", 7); got != tt.want {
				t.Errorf("getIntEnv = %d, want %d", got, tt.want)
			}
		})
	}
}

// A hanging dependency must not cost the pod its readiness, and "/" must
// answer with its own error before the server cuts the response.
func TestUpstreamTimeouts_AnswerBeforeTheProbeAndTheServerGiveUp(t *testing.T) {
	if upstreamTimeout >= writeTimeout {
		t.Errorf("upstreamTimeout %v must be under the server's write timeout %v", upstreamTimeout, writeTimeout)
	}
	// The chart's readiness probe allows 3s; liveness allows 5s.
	if readyUpstreamTimeout >= 3*time.Second {
		t.Errorf("readyUpstreamTimeout %v must be under the readiness probe's 3s", readyUpstreamTimeout)
	}

	hang := make(chan struct{})
	srv := httptest.NewServer(http.HandlerFunc(func(_ http.ResponseWriter, r *http.Request) {
		select {
		case <-hang:
		case <-r.Context().Done():
		}
	}))
	t.Cleanup(func() { close(hang); srv.Close() })
	handlerEnv(t, srv.URL)
	prevRoot, prevReady := upstreamTimeout, readyUpstreamTimeout
	upstreamTimeout, readyUpstreamTimeout = time.Second, 100*time.Millisecond
	t.Cleanup(func() { upstreamTimeout, readyUpstreamTimeout = prevRoot, prevReady })

	tests := []struct {
		name       string
		handler    http.HandlerFunc
		path       string
		wantStatus int
		within     time.Duration
	}{
		{"/ready stays ready and answers within its own bound", handleReady, "/ready", http.StatusOK, 600 * time.Millisecond},
		{"/ answers 502 within its bound", handleRoot, "/", http.StatusBadGateway, 3 * time.Second},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			start := time.Now()
			code, body := serve(t, tt.handler, tt.path)
			if code != tt.wantStatus {
				t.Errorf("status = %d, want %d: %v", code, tt.wantStatus, body)
			}
			if took := time.Since(start); took > tt.within {
				t.Errorf("answered after %v, want within %v", took, tt.within)
			}
		})
	}
}
