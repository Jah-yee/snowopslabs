// SPDX-License-Identifier: Apache-2.0

package checks

import (
	"math"
	"strconv"
	"testing"

	"gopkg.in/yaml.v3"
)

// FuzzCompare holds the comparison every kubectl and promql check is graded
// with to its own rules, for any observed value a cluster could return.
func FuzzCompare(f *testing.F) {
	for _, seed := range [][3]string{
		{"3", ">=", "2"}, {"", ">=", "1"}, {"", "<", "1"}, {"1e3", "==", "1000"},
		{"NaN", "!=", "0"}, {"NaN", "<", "0.01"}, {"+Inf", ">", "5"}, {"-Inf", "<", "5"},
		{"Running", "==", "Running"}, {"Running", ">", "1"}, {"0x10", "==", "16"},
		{"a b", "contains", "b"}, {"1", "~=", "1"}, {" 2", "==", "2"}, {"2\n", ">=", "2"},
	} {
		f.Add(seed[0], seed[1], seed[2])
	}
	f.Fuzz(func(t *testing.T, got, op, want string) {
		pass, err := compare(got, op, want)
		if err != nil && pass {
			t.Fatalf("compare(%q %s %q) passed and returned an error: %v", got, op, want, err)
		}

		// A value that is not a number can never satisfy a numeric threshold:
		// "no data" must not grade as a pass.
		if g, perr := strconv.ParseFloat(got, 64); perr == nil && (math.IsNaN(g) || math.IsInf(g, 0)) && op != "contains" {
			if pass {
				t.Fatalf("compare(%q %s %q) passed on a value that is not a finite number", got, op, want)
			}
		}

		switch op {
		case "==", "!=":
			other := map[string]string{"==": "!=", "!=": "=="}[op]
			otherPass, otherErr := compare(got, other, want)
			if err == nil && otherErr == nil && pass == otherPass {
				t.Fatalf("%q == %q is %v and != is %v: they must disagree", got, want, pass, otherPass)
			}
		case "<", "<=", ">", ">=":
			if err != nil {
				return
			}
			lt, _ := compare(got, "<", want)
			eq, _ := compare(got, "==", want)
			gt, _ := compare(got, ">", want)
			if n := count(lt, eq, gt); n != 1 {
				t.Fatalf("for %q and %q, < is %v, == is %v, > is %v: exactly one must hold", got, want, lt, eq, gt)
			}
		}
	})
}

func count(bs ...bool) int {
	n := 0
	for _, b := range bs {
		if b {
			n++
		}
	}
	return n
}

// FuzzCheckYAML parses arbitrary YAML as a check. Whatever it holds, Validate
// never panics, and a check it accepts has a type the runner knows and the
// field that type is graded from.
func FuzzCheckYAML(f *testing.F) {
	for _, seed := range []string{
		"name: c\ntype: http\nurl: http://x/health\nexpectStatus: 200\n",
		"name: c\ntype: script\nscript: checks/c.sh\n",
		"name: c\ntype: promql\nquery: up\noperator: \">=\"\nvalue: \"1\"\n",
		"name: c\ntype: kubectl\nresource: deploy/x\njsonpath: \"{.status.readyReplicas}\"\noperator: \">=\"\nvalue: \"1\"\n",
		"name: c\ntype: kubectl\noperator: \">=\"\n",
		"type: [not, a, string]\n",
		"name: c\ntype: http\ntimeoutSeconds: -4\n",
		"name: c\ntype: promql\nquery: up\noperator: In\nvalue: x\n",
		"a: &a [*a]",
		"",
	} {
		f.Add([]byte(seed))
	}
	f.Fuzz(func(t *testing.T, data []byte) {
		var c Check
		if err := yaml.Unmarshal(data, &c); err != nil {
			return
		}
		if err := c.Validate(); err != nil {
			return
		}
		if !validKnownType(c.Type) {
			t.Fatalf("Validate accepted a check of unknown type %q", c.Type)
		}
		graded := map[string]string{TypeHTTP: c.URL, TypeScript: c.Script, TypePromQL: c.Query, TypeKubectl: c.Resource}
		if graded[c.Type] == "" {
			t.Fatalf("Validate accepted a %s check with nothing to grade: %+v", c.Type, c)
		}
		if c.Operator != "" && !validOperators[c.Operator] {
			t.Fatalf("Validate accepted the operator %q", c.Operator)
		}
		if c.TimeoutSeconds < 0 {
			t.Fatalf("Validate accepted a negative timeout: %d", c.TimeoutSeconds)
		}
	})
}
