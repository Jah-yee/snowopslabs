// SPDX-License-Identifier: Apache-2.0

package checks

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestCheckValidate(t *testing.T) {
	tests := []struct {
		name    string
		check   Check
		wantErr string // substring of the expected error; "" means valid
	}{
		{
			name:  "valid http minimal",
			check: Check{Name: "grafana", Type: "http", URL: "http://grafana.k3d.local"},
		},
		{
			name:  "valid http full",
			check: Check{Name: "api", Type: "http", URL: "http://x", ExpectStatus: 204, BodyContains: "ok", TimeoutSeconds: 5},
		},
		{
			name:  "valid kubectl existence",
			check: Check{Name: "rules", Type: "kubectl", Resource: "prometheusrules", Namespace: "monitoring"},
		},
		{
			name: "valid kubectl jsonpath",
			check: Check{Name: "loki", Type: "kubectl", Resource: "statefulset/loki",
				JSONPath: "{.status.readyReplicas}", Operator: ">=", Value: "1"},
		},
		{
			name:  "valid promql",
			check: Check{Name: "p99", Type: "promql", Query: "up", Operator: "==", Value: "1"},
		},
		{
			name:  "valid script",
			check: Check{Name: "custom", Type: "script", Script: "checks/verify.sh"},
		},
		{
			name:    "missing name",
			check:   Check{Type: "http", URL: "http://x"},
			wantErr: "name is required",
		},
		{
			name:    "missing type",
			check:   Check{Name: "x"},
			wantErr: "type is required",
		},
		{
			name:    "unknown type",
			check:   Check{Name: "x", Type: "grpc"},
			wantErr: `unknown check type "grpc"`,
		},
		{
			name:    "http without url",
			check:   Check{Name: "x", Type: "http"},
			wantErr: "requires url",
		},
		{
			name:    "http bad status",
			check:   Check{Name: "x", Type: "http", URL: "http://x", ExpectStatus: 999},
			wantErr: "not a valid HTTP status",
		},
		{
			name:    "kubectl without resource",
			check:   Check{Name: "x", Type: "kubectl"},
			wantErr: "requires resource",
		},
		{
			name:    "kubectl jsonpath without operator",
			check:   Check{Name: "x", Type: "kubectl", Resource: "deploy/x", JSONPath: "{.x}"},
			wantErr: "requires operator and value",
		},
		{
			name:    "kubectl operator without jsonpath",
			check:   Check{Name: "x", Type: "kubectl", Resource: "deploy/x", Operator: "==", Value: "1"},
			wantErr: "no jsonpath",
		},
		{
			name:    "promql without query",
			check:   Check{Name: "x", Type: "promql", Operator: "<", Value: "1"},
			wantErr: "requires query",
		},
		{
			name:    "promql without operator",
			check:   Check{Name: "x", Type: "promql", Query: "up"},
			wantErr: "requires operator and value",
		},
		{
			name:    "bad operator",
			check:   Check{Name: "x", Type: "promql", Query: "up", Operator: "~=", Value: "1"},
			wantErr: `unknown operator "~="`,
		},
		{
			name:    "script without path",
			check:   Check{Name: "x", Type: "script"},
			wantErr: "requires script",
		},
		{
			name:    "negative timeout",
			check:   Check{Name: "x", Type: "http", URL: "http://x", TimeoutSeconds: -1},
			wantErr: "timeoutSeconds",
		},
		{
			name:    "http check with promql field",
			check:   Check{Name: "x", Type: "http", URL: "http://x", Query: "up"},
			wantErr: `fields not valid for type "http": query`,
		},
		{
			name:    "script check with kubectl fields",
			check:   Check{Name: "x", Type: "script", Script: "s.sh", Resource: "deploy/x", Namespace: "ns"},
			wantErr: `fields not valid for type "script": namespace, resource`,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			err := tt.check.Validate()
			if tt.wantErr == "" {
				if err != nil {
					t.Fatalf("expected valid, got: %v", err)
				}
				return
			}
			if err == nil {
				t.Fatalf("expected error containing %q, got nil", tt.wantErr)
			}
			if !strings.Contains(err.Error(), tt.wantErr) {
				t.Fatalf("error %q does not contain %q", err.Error(), tt.wantErr)
			}
		})
	}
}

func TestCompare(t *testing.T) {
	tests := []struct {
		got, op, want string
		pass          bool
		wantErr       bool
	}{
		{"1", ">=", "1", true, false},
		{"2", ">=", "1", true, false},
		{"0", ">=", "1", false, false},
		{"0.25", "<", "0.3", true, false},
		{"3", "==", "3.0", true, false},
		{"3", "!=", "4", true, false},
		{"abc", "==", "abc", true, false},
		{"abc", "!=", "abd", true, false},
		{"hello world", "contains", "world", true, false},
		{"hello", "contains", "world", false, false},
		{"abc", "<", "1", false, true}, // ordering needs numbers
		{"1", "~", "1", false, true},   // unknown operator
		// Empty left operand (absent .status.readyReplicas) is treated as 0 for
		// ordering ops, so the check fails cleanly instead of erroring.
		{"", ">=", "1", false, false},
		{"", "<", "1", true, false},
		{"", ">=", "abc", false, true}, // still errors if the want side isn't numeric
		// The same holds for equality: no ready replicas is 0, not "something
		// other than 0".
		{"", "==", "0", true, false},
		{"", "!=", "0", false, false},
		{"", "==", "1", false, false},
		{"", "!=", "1", true, false},
		{"", "==", "", true, false}, // two empty strings are still equal text
		{"", "!=", "v1.0.0", true, false},
		// PromQL's "nothing to divide" answers never satisfy a threshold.
		{"NaN", "!=", "0", false, true},
		{"NaN", "<", "0.01", false, true},
		{"+Inf", ">=", "0.99", false, true},
		{"-Inf", "<", "5", false, true},
		{"1", ">=", "NaN", false, true},
		{"NaN", "contains", "Na", true, false}, // text matching is not a measurement
	}

	for _, tt := range tests {
		pass, err := compare(tt.got, tt.op, tt.want)
		if tt.wantErr {
			if err == nil {
				t.Errorf("compare(%q,%q,%q): expected error", tt.got, tt.op, tt.want)
			}
			continue
		}
		if err != nil {
			t.Errorf("compare(%q,%q,%q): unexpected error %v", tt.got, tt.op, tt.want, err)
			continue
		}
		if pass != tt.pass {
			t.Errorf("compare(%q,%q,%q) = %v, want %v", tt.got, tt.op, tt.want, pass, tt.pass)
		}
	}
}

func TestAllPass(t *testing.T) {
	if AllPass(nil) {
		t.Error("AllPass(nil) must be false - nothing verified is not success")
	}
	if AllPass([]Result{{Pass: true}, {Pass: false}}) {
		t.Error("AllPass with a failure must be false")
	}
	if !AllPass([]Result{{Pass: true}, {Pass: true}}) {
		t.Error("AllPass with all passes must be true")
	}
}

// The edges the mutation run found unpinned.
func TestValidate_ExpectStatusBounds(t *testing.T) {
	for status, valid := range map[int]bool{0: true, 99: false, 100: true, 200: true, 599: true, 600: false} {
		c := Check{Name: "c", Type: TypeHTTP, URL: "http://x", ExpectStatus: status}
		if err := c.Validate(); (err == nil) != valid {
			t.Errorf("expectStatus %d: Validate() = %v, want valid=%v", status, err, valid)
		}
	}
}

func TestValidate_NamesAnUnnamedCheck(t *testing.T) {
	err := (&Check{Type: TypeHTTP}).Validate()
	if err == nil || !strings.Contains(err.Error(), "(unnamed)") {
		t.Errorf("Validate() = %v, want the error to call the check (unnamed)", err)
	}
}

func TestNewRunner_Defaults(t *testing.T) {
	if got := NewRunner().DefaultTimeout; got != 30*time.Second {
		t.Errorf("DefaultTimeout = %s, want 30s", got)
	}
}

func TestEventuallyOpts_KeepsAMultiplierOfOne(t *testing.T) {
	if got := (EventuallyOpts{Multiplier: 1}).withDefaults().Multiplier; got != 1 {
		t.Errorf("Multiplier = %v, want 1 kept: a fixed interval is a valid choice", got)
	}
}

func TestRunHTTP_StatusDefaultsTo200(t *testing.T) {
	tests := []struct {
		name   string
		served int
		expect int
		pass   bool
	}{
		{"200 with no expectation", http.StatusOK, 0, true},
		{"201 with no expectation", http.StatusCreated, 0, false},
		{"201 when 201 is expected", http.StatusCreated, http.StatusCreated, true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(tt.served) }))
			defer srv.Close()
			res := NewRunner().Run(t.Context(), Check{Name: "c", Type: TypeHTTP, URL: srv.URL, ExpectStatus: tt.expect})
			if res.Pass != tt.pass {
				t.Errorf("pass = %v, want %v (%s)", res.Pass, tt.pass, res.Explanation)
			}
		})
	}
}

// A check with no timeout of its own is still bounded by the runner's default.
func TestRun_NoTimeoutOfItsOwnUsesTheDefault(t *testing.T) {
	release := make(chan struct{})
	srv := httptest.NewServer(http.HandlerFunc(func(http.ResponseWriter, *http.Request) { <-release }))
	defer srv.Close()
	defer close(release)
	r := NewRunner()
	r.DefaultTimeout = 50 * time.Millisecond
	start := time.Now()
	res := r.Run(t.Context(), Check{Name: "c", Type: TypeHTTP, URL: srv.URL})
	if res.Pass || time.Since(start) > 5*time.Second {
		t.Errorf("pass = %v after %s; want a failure at the 50ms default", res.Pass, time.Since(start))
	}
}

// A runner with no default timeout runs a check without a deadline, rather
// than one that has already expired.
func TestRun_ZeroDefaultTimeoutMeansNoDeadline(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(http.ResponseWriter, *http.Request) {}))
	defer srv.Close()
	r := NewRunner()
	r.DefaultTimeout = 0
	if res := r.Run(t.Context(), Check{Name: "c", Type: TypeHTTP, URL: srv.URL}); !res.Pass {
		t.Errorf("check failed with no timeout set: %s %s", res.Error, res.Explanation)
	}
}

// What an HTTP check wanted is reported in full, and only what it wanted.
func TestRunHTTP_WantDescribesTheExpectation(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) { _, _ = w.Write([]byte("ok")) }))
	defer srv.Close()
	plain := NewRunner().Run(t.Context(), Check{Name: "c", Type: TypeHTTP, URL: srv.URL})
	if plain.Want != "status 200" {
		t.Errorf("want = %q, want %q", plain.Want, "status 200")
	}
	withBody := NewRunner().Run(t.Context(), Check{Name: "c", Type: TypeHTTP, URL: srv.URL, BodyContains: "ok"})
	if withBody.Want != `status 200, body contains "ok"` || !withBody.Pass {
		t.Errorf("want = %q, pass = %v", withBody.Want, withBody.Pass)
	}
}
