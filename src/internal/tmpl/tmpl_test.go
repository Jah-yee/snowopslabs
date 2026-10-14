// SPDX-License-Identifier: Apache-2.0

package tmpl

import (
	"reflect"
	"sort"
	"strings"
	"testing"
	"time"
)

func testContext() Context {
	return Context{
		DomainSuffix:        "k3d.local",
		MonitoringNamespace: "monitoring",
		ProjectRoot:         "/repo",
		LokiRetentionPeriod: "72h",
		IngressClass:        "traefik",
		WorkloadName:        "go-api",
		WorkloadNamespace:   "go-api",
		WorkloadService:     "go-api.go-api.svc.cluster.local",
		WorkloadPort:        "8080",
		WorkloadMetric:      "http_server_request_duration_seconds",
		SinceActivation:     "95m",
	}
}

func TestSince(t *testing.T) {
	now := time.Date(2026, 9, 11, 20, 0, 0, 0, time.UTC)
	tests := []struct {
		name  string
		start time.Time
		want  string
	}{
		{"nothing active", time.Time{}, "1m"},
		{"start in the future (clock skew)", now.Add(time.Minute), "1m"},
		{"seconds ago rounds up", now.Add(-10 * time.Second), "1m"},
		{"a partial minute rounds up so start is inside", now.Add(-(94*time.Minute + time.Second)), "95m"},
		{"whole minutes", now.Add(-2 * time.Hour), "120m"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := Since(tt.start, now); got != tt.want {
				t.Errorf("Since() = %q, want %q", got, tt.want)
			}
		})
	}
}

// A field added to Context but missing from Vars would pass validation and
// expand to nothing at run time.
func TestVarsCoversEveryField(t *testing.T) {
	vars := Context{}.Vars()
	for _, name := range FieldNames() {
		if _, ok := vars[name]; !ok {
			t.Errorf("Context field %q is missing from Vars()", name)
		}
	}
	if len(vars) != len(FieldNames()) {
		t.Errorf("Vars() has %d keys, Context has %d fields", len(vars), len(FieldNames()))
	}
}

func TestVarsValuesMatchFields(t *testing.T) {
	ctx := testContext()
	vars := ctx.Vars()
	v := reflect.ValueOf(ctx)
	for i, name := range FieldNames() {
		if got, want := vars[name], v.Field(i).String(); got != want {
			t.Errorf("Vars()[%q] = %q, want %q", name, got, want)
		}
	}
}

func TestValidate(t *testing.T) {
	tests := []struct {
		name    string
		input   string
		wantErr string
	}{
		{name: "no template", input: "plain string"},
		{name: "empty", input: ""},
		{name: "known built-in", input: "http://grafana.{{.IngressURLSuffix}}"},
		{name: "known workload var", input: "deployment/{{.WorkloadName}}"},
		{name: "several known vars", input: "{{.WorkloadName}}.{{.WorkloadNamespace}}:{{.WorkloadPort}}"},
		{name: "spaces inside braces", input: "{{ .IngressClass }}"},

		// Other systems' templating shares these files and must pass untouched.
		{name: "loki line_format", input: `line_format "{{.method}} {{.path}} {{.status}}"`},
		{name: "prometheus value", input: "current value {{ $value }}"},
		{name: "prometheus labels", input: "pod {{ $labels.pod }} is down"},
		{name: "grafana legend", input: "{{namespace}}"},
		{name: "helm pipeline", input: `{{ index .data "x" | base64decode }}`},
		{name: "helm nested field", input: "{{ .Values.image.tag }}"},

		// A PascalCase name is claiming to be one of ours, so it must resolve.
		{name: "typo in a built-in", input: "{{.DomainSufix}}", wantErr: "DomainSufix"},
		{name: "typo in a workload var", input: "{{.WorkloadNam}}", wantErr: "WorkloadNam"},
		{name: "unknown var lists the known ones", input: "{{.Nope}}", wantErr: "DomainSuffix"},
		{name: "typo among valid vars is still caught", input: "{{.WorkloadName}} in {{.Wrongo}}", wantErr: "Wrongo"},

		// Only the inner placeholder of a nested pair is filled, which leaves
		// a raw one in what is applied to the cluster.
		{name: "a placeholder inside another", input: "{{.Workload{{.ProjectRoot}}Name}}", wantErr: "opened inside another"},
		{name: "a placeholder wrapped in braces", input: "{{ {{.WorkloadName}} }}", wantErr: "opened inside another"},
		{name: "two placeholders side by side", input: "{{.WorkloadName}}{{.WorkloadNamespace}}"},
		{name: "a JSON object next to a placeholder", input: `{"app": "{{.WorkloadName}}"}`},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			err := Validate(tc.input)
			if tc.wantErr == "" {
				if err != nil {
					t.Fatalf("Validate(%q) = %v, want nil", tc.input, err)
				}
				return
			}
			if err == nil {
				t.Fatalf("Validate(%q) = nil, want an error containing %q", tc.input, tc.wantErr)
			}
			if !strings.Contains(err.Error(), tc.wantErr) {
				t.Errorf("error %q does not contain %q", err, tc.wantErr)
			}
		})
	}
}

// Validate must accept exactly what Expand resolves: a variable Expand
// substitutes must never be reported unknown, and vice versa.
func TestValidateAgreesWithExpand(t *testing.T) {
	for _, name := range FieldNames() {
		ref := "{{." + name + "}}"
		if err := Validate(ref); err != nil {
			t.Errorf("Validate(%q) = %v, want nil", ref, err)
		}
		if got := Expand(ref, testContext(), nil); got == ref {
			t.Errorf("Expand(%q) left it unresolved", ref)
		}
	}
}

// Expand must leave every other template syntax found in content files
// unchanged.
func TestExpandLeavesForeignTemplatingAlone(t *testing.T) {
	tests := []struct {
		name  string
		input string
	}{
		{name: "prometheus value", input: "current value {{ $value }}"},
		{name: "prometheus labels", input: "pod {{ $labels.pod }} is down"},
		{name: "grafana legend", input: "{{namespace}}"},
		{name: "helm sprig pipeline", input: `{{ index .data "x" | base64decode }}`},
		{name: "helm nested field", input: "{{ .Values.image.tag }}"},
		{name: "unknown labctl var", input: "{{.NotAThing}}"},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			if got := Expand(tc.input, testContext(), nil); got != tc.input {
				t.Errorf("Expand(%q) = %q, want it unchanged", tc.input, got)
			}
		})
	}
}

func TestExpand(t *testing.T) {
	tests := []struct {
		name  string
		input string
		extra map[string]string
		want  string
	}{
		{name: "empty input", input: "", want: ""},
		{name: "no braces", input: "plain", want: "plain"},
		{name: "built-in", input: "ns={{.MonitoringNamespace}}", want: "ns=monitoring"},
		{name: "workload service", input: "http://{{.WorkloadService}}:{{.WorkloadPort}}/", want: "http://go-api.go-api.svc.cluster.local:8080/"},
		{name: "extra value", input: "max={{.MaxReplicas}}", extra: map[string]string{"MaxReplicas": "6"}, want: "max=6"},
		{
			name:  "extra cannot shadow a built-in",
			input: "{{.DomainSuffix}}",
			extra: map[string]string{"DomainSuffix": "hijacked"},
			want:  "k3d.local",
		},
		{
			name:  "mixed labctl and prometheus syntax",
			input: "{{.WorkloadName}} in {{.WorkloadNamespace}} at {{ $value }}",
			want:  "go-api in go-api at {{ $value }}",
		},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			if got := Expand(tc.input, testContext(), tc.extra); got != tc.want {
				t.Errorf("Expand(%q) = %q, want %q", tc.input, got, tc.want)
			}
		})
	}
}

func TestExpandVars(t *testing.T) {
	vars := map[string]string{"WorkloadName": "zz-app", "SinceActivation": "37m", "MaxReplicas": "6"}
	tests := []struct {
		name  string
		input string
		want  string
	}{
		{name: "empty input", input: "", want: ""},
		{name: "no braces", input: "plain", want: "plain"},
		{name: "every name comes from the map", input: "{{.WorkloadName}}[{{.SinceActivation}}] max={{.MaxReplicas}}", want: "zz-app[37m] max=6"},
		{name: "a name the map lacks is left for the next tool", input: "{{.DomainSuffix}} {{ $value }}", want: "{{.DomainSuffix}} {{ $value }}"},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			if got := ExpandVars(tc.input, vars); got != tc.want {
				t.Errorf("ExpandVars(%q) = %q, want %q", tc.input, got, tc.want)
			}
		})
	}
}

// An empty binding must not silently produce "deployment/" — callers are
// expected to populate the workload before expanding content.
func TestExpandZeroContextEmptiesKnownVars(t *testing.T) {
	if got := Expand("deployment/{{.WorkloadName}}", Context{}, nil); got != "deployment/" {
		t.Errorf("got %q, want %q", got, "deployment/")
	}
}

func TestFieldNamesIsStable(t *testing.T) {
	got := FieldNames()
	if len(got) == 0 {
		t.Fatal("FieldNames() is empty")
	}
	sorted := append([]string(nil), got...)
	sort.Strings(sorted)
	for _, n := range sorted {
		if n == "" || strings.ToUpper(n[:1]) != n[:1] {
			t.Errorf("field %q is not exported", n)
		}
	}
}

func TestValidate_URLsNeedIngressURLSuffix(t *testing.T) {
	tests := []struct {
		name    string
		input   string
		wantErr bool
	}{
		{name: "url from domain suffix", input: "http://grafana.{{.DomainSuffix}}/d/x", wantErr: true},
		{name: "url with templated host", input: "curl https://{{.WorkloadName}}.{{ .DomainSuffix }}/health", wantErr: true},
		{name: "url from ingress url suffix", input: "http://grafana.{{.IngressURLSuffix}}/d/x", wantErr: false},
		{name: "hostname from domain suffix", input: "host: {{.WorkloadName}}.{{.DomainSuffix}}", wantErr: false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if err := Validate(tt.input); (err != nil) != tt.wantErr {
				t.Errorf("Validate(%q) = %v, wantErr %v", tt.input, err, tt.wantErr)
			}
		})
	}
}
