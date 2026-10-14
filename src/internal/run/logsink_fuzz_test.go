// SPDX-License-Identifier: Apache-2.0

package run

import (
	"strings"
	"testing"
)

// FuzzParseStepMarker feeds arbitrary script output lines to the step-marker
// parser. Only a line that starts with the marker names a step, the name it
// returns is never blank or padded, and writing that name back as a marker
// parses to the same name.
func FuzzParseStepMarker(f *testing.F) {
	for _, seed := range []string{
		StepMarker + "install traefik", "  " + StepMarker + "  wait for pods  \r", StepMarker, StepMarker + "   ",
		"echo " + StepMarker + "not a step", "plain output", "", "##snowops:step", "##snowops:STEP:x",
		StepMarker + "a\tb", StepMarker + StepMarker + "nested", "\x00" + StepMarker + "x",
	} {
		f.Add(seed)
	}
	f.Fuzz(func(t *testing.T, line string) {
		name, ok := parseStepMarker(line)
		if !ok {
			if name != "" {
				t.Fatalf("parseStepMarker(%q) returned the name %q for a line that is not a marker", line, name)
			}
			return
		}
		if !strings.HasPrefix(strings.TrimSpace(line), StepMarker) {
			t.Fatalf("parseStepMarker(%q) accepted a line that does not start with the marker", line)
		}
		if name == "" || name != strings.TrimSpace(name) {
			t.Fatalf("parseStepMarker(%q) = %q: a step name is never blank or padded", line, name)
		}
		if again, ok := parseStepMarker(StepMarker + name); !ok || again != name {
			t.Fatalf("the name %q does not survive being written back as a marker: got %q, %v", name, again, ok)
		}
	})
}
