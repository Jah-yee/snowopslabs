// SPDX-License-Identifier: Apache-2.0

package httpapi

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/gorilla/mux"
)

// ctxKey is an unexported context-key type so values stored here can't collide
// with keys from other packages.
type ctxKey int

const (
	requestIDKey ctxKey = iota
)

// requestIDHeader is both read (to honour a caller-supplied correlation ID) and
// written (so the client can tie its request to server logs).
const requestIDHeader = "X-Request-ID"

// maxInboundRequestID caps how long a caller-supplied ID we will echo back, so a
// hostile client can't bloat our logs or response headers with a giant value.
const maxInboundRequestID = 200

// requestIDMiddleware gives every request a correlation ID: the incoming
// X-Request-ID if it is acceptable, otherwise a new UUIDv4. The ID is stored
// in the request context and returned in the response header.
func (s *Server) requestIDMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		id := sanitizeRequestID(r.Header.Get(requestIDHeader))
		if id == "" {
			id = uuid.NewString()
		}
		w.Header().Set(requestIDHeader, id)
		ctx := context.WithValue(r.Context(), requestIDKey, id)
		next.ServeHTTP(w, r.WithContext(ctx))
	})
}

// sanitizeRequestID accepts a caller's request ID only if it is short and
// printable ASCII, so it cannot inject headers or forge log lines.
func sanitizeRequestID(v string) string {
	if v == "" || len(v) > maxInboundRequestID {
		return ""
	}
	for _, c := range v {
		if c < 0x20 || c > 0x7e {
			return ""
		}
	}
	return v
}

// requestIDFrom returns the correlation ID stored on the context, or "" if the
// request did not pass through requestIDMiddleware (e.g. a unit test hitting a
// handler directly).
func requestIDFrom(ctx context.Context) string {
	if id, ok := ctx.Value(requestIDKey).(string); ok {
		return id
	}
	return ""
}

// accessLogMiddleware writes one slog line per request with the method, path,
// route template, status, duration, response size, client address and request
// ID. A WebSocket upgrade is logged once when it opens and is not timed.
func (s *Server) accessLogMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		reqID := requestIDFrom(r.Context())

		if strings.EqualFold(r.Header.Get("Upgrade"), "websocket") {
			slog.Info("http_ws_open",
				"method", r.Method,
				"path", r.URL.Path,
				"remote", clientAddr(r),
				"request_id", reqID,
			)
			next.ServeHTTP(w, r)
			return
		}

		rec := &statusRecorder{ResponseWriter: w, status: http.StatusOK}
		start := time.Now()
		next.ServeHTTP(rec, r)

		slog.Info("http_request",
			"method", r.Method,
			"path", r.URL.Path,
			"route", routeTemplate(r),
			"status", rec.status,
			"duration_ms", time.Since(start).Milliseconds(),
			"bytes", rec.bytes,
			"remote", clientAddr(r),
			"request_id", reqID,
		)
	})
}

// routeTemplate returns the matched route's path template, such as
// /scenarios/{name}, or "unmatched".
func routeTemplate(r *http.Request) string {
	if cr := mux.CurrentRoute(r); cr != nil {
		if tmpl, err := cr.GetPathTemplate(); err == nil {
			return tmpl
		}
	}
	return "unmatched"
}

// clientAddr returns the request's remote address without the port.
func clientAddr(r *http.Request) string {
	addr := r.RemoteAddr
	if i := strings.LastIndex(addr, ":"); i > 0 {
		return addr[:i]
	}
	return addr
}

// maxRequestBody is the largest request body the API reads. No route takes
// more than a few hundred bytes of JSON.
const maxRequestBody = 1 << 20

// limitBodyMiddleware refuses a request that declares a body over
// maxRequestBody, and stops reading one that streams past it, so a client
// cannot make the server buffer an arbitrarily large body.
func limitBodyMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.ContentLength > maxRequestBody {
			respondTooLarge(w, r)
			return
		}
		r.Body = http.MaxBytesReader(w, r.Body, maxRequestBody)
		next.ServeHTTP(w, r)
	})
}

func respondTooLarge(w http.ResponseWriter, r *http.Request) {
	respondError(w, r, http.StatusRequestEntityTooLarge, "request_too_large",
		fmt.Sprintf("the request body is larger than the %d MiB limit", maxRequestBody>>20))
}

// decodeBody reads the request's JSON body into v. It answers the request
// itself and returns false when the body is too large or is not valid JSON.
// With optional set, an empty body is accepted and leaves v as it was.
func decodeBody(w http.ResponseWriter, r *http.Request, v any, optional bool) bool {
	err := json.NewDecoder(r.Body).Decode(v)
	var tooLarge *http.MaxBytesError
	switch {
	case err == nil, optional && errors.Is(err, io.EOF):
		return true
	case errors.As(err, &tooLarge):
		respondTooLarge(w, r)
	default:
		respondError(w, r, http.StatusBadRequest, "invalid_request", "the request body is not valid JSON")
	}
	return false
}
