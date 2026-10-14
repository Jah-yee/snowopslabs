// SPDX-License-Identifier: Apache-2.0

package tmpl

import (
	"strings"
	"testing"
)

// FuzzExpand holds template expansion to its contract for any content string:
// text without a placeholder is returned as it is, and content that passes
// Validate has every placeholder labctl knows filled in one pass, so a second
// pass changes nothing.
func FuzzExpand(f *testing.F) {
	for _, seed := range []string{
		"", "plain text", "http://{{.WorkloadName}}.{{.IngressURLSuffix}}/health",
		"{{.Nope}} and {{.WorkloadName}}", "{{ .WorkloadName }}", "{{.WorkloadName", "{{{{.WorkloadName}}}}",
		`{{.method}} {{.status}}`, "{{.Threshold}}", "{{.WorkloadName}}{{.WorkloadName}}", "}}{{", "{{.}}",
		"line1\n{{.WorkloadNamespace}}\nline3", "{{.WorkloadName}}\x00", "{{.Workload\nName}}",
		"{{.Workload{{.ProjectRoot}}Name}}", "{{.{{.WorkloadName}}}}", "{{ {{.StateDir}} }}",
	} {
		f.Add(seed)
	}
	ctx := Context{DomainSuffix: "lab.test", IngressURLSuffix: "lab.test:8080", MonitoringNamespace: "monitoring", WorkloadName: "go-api"}
	extra := map[string]string{"Threshold": "15", "WorkloadName": "an extra must never win"}
	f.Fuzz(func(t *testing.T, input string) {
		got := Expand(input, ctx, extra)

		if !IsTemplated(input) && got != input {
			t.Fatalf("Expand(%q) = %q: text with no placeholder changed", input, got)
		}
		if strings.Contains(got, "an extra must never win") {
			t.Fatalf("Expand(%q) = %q: an extra value replaced a built-in variable", input, got)
		}

		// Validate judges any input without panicking, and never rejects text
		// that holds no placeholder at all.
		err := Validate(input, "Threshold")
		if err != nil {
			if !IsTemplated(input) {
				t.Fatalf("Validate(%q) = %v for text with no placeholder", input, err)
			}
			return
		}
		// Content that validates expands completely, in one pass.
		for name := range ctx.Vars() {
			if strings.Contains(got, "{{."+name+"}}") {
				t.Fatalf("Expand(%q) = %q: the known placeholder {{.%s}} was left unfilled", input, got, name)
			}
		}
		if again := Expand(got, ctx, extra); again != got {
			t.Fatalf("Expand is not stable: %q became %q, then %q", input, got, again)
		}
	})
}
