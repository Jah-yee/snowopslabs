// SPDX-License-Identifier: Apache-2.0

package cli

import (
	"bytes"
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/sagar2395/snowopslabs/internal/labtest"
	incsvc "github.com/sagar2395/snowopslabs/internal/service/incident"
	"github.com/sagar2395/snowopslabs/internal/store"
)

func TestTidyAfterFix(t *testing.T) {
	tests := []struct {
		name       string
		exitCode   int
		wantStatus store.Status
		wantAdvice bool
	}{
		{name: "resolve.sh runs as a recorded resolve", exitCode: 0, wantStatus: store.StatusSucceeded},
		{name: "a failed tidy-up says how to finish it", exitCode: 1, wantStatus: store.StatusFailed, wantAdvice: true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			f, st := fakeIncidentEnv(t)
			f.WhenArgsContainStderr("resolve.sh", "", "stderr\n", tt.exitCode)

			var buf bytes.Buffer
			tidyAfterFix(dummyCmd(&buf), "oom-kill", incsvc.Target{Namespace: "go-api", Workload: "go-api"})

			out := buf.String()
			if !strings.Contains(out, "Tidying up") {
				t.Errorf("output does not announce the tidy-up: %q", out)
			}
			if got := strings.Contains(out, "labctl incident resolve oom-kill"); got != tt.wantAdvice {
				t.Errorf("recovery advice shown = %v, want %v; output: %q", got, tt.wantAdvice, out)
			}
			runs, err := st.ListRuns(context.Background(), store.RunFilter{Kind: incsvc.KindResolve})
			if err != nil {
				t.Fatalf("ListRuns: %v", err)
			}
			if len(runs) != 1 || runs[0].Target != "oom-kill" || runs[0].Status != tt.wantStatus {
				t.Fatalf("want one %s resolve of oom-kill, got %+v", tt.wantStatus, runs)
			}
		})
	}
}

// faultMarker is the file the fixture fault creates: while it exists the demo
// app is broken and the detection check fails.
const faultMarker = "incidents/" + labtest.Fault + "/BROKEN"

// The whole game day at the terminal: inject, look, take hints, fix it by
// hand, be told it is fixed, then use the escape hatch on a second run.
func TestIncident_Journey(t *testing.T) {
	l := newTerminal(t)
	var steps []cliResult
	step := func(args ...string) cliResult {
		t.Helper()
		r := l.mustRun(args...)
		steps = append(steps, r)
		return r
	}

	step("incident", "list")
	step("incident", "info", labtest.Fault)
	step("incident", "status")
	step("incident", "history")

	step("incident", "inject", labtest.Fault)
	if !l.exists(faultMarker) {
		t.Fatal("inject reported success but did not break the lab")
	}
	step("incident", "list")
	if r := step("incident", "status"); !strings.Contains(r.stdout, "NOT RESOLVED") {
		t.Errorf("status on a broken lab does not say NOT RESOLVED:\n%s", r.stdout)
	}
	for range 3 {
		step("incident", "hint")
	}
	step("incident", "hint") // none left

	l.stdin = "no\n"
	if r := step("incident", "solution"); strings.Contains(r.stdout, "roll it back") {
		t.Errorf("the solution was shown without confirmation:\n%s", r.stdout)
	}
	l.stdin = "yes\n"
	if r := step("incident", "solution"); !strings.Contains(r.stdout, "roll it back") {
		t.Errorf("the confirmed solution was not shown:\n%s", r.stdout)
	}

	l.remove(faultMarker) // the learner's own fix
	fixed := step("incident", "status")
	if !strings.Contains(fixed.stdout, "RESOLVED — detection check") || !strings.Contains(fixed.stdout, "Tidying up") {
		t.Errorf("status after a hand fix does not confirm it and tidy up:\n%s", fixed.stdout)
	}
	if r := step("incident", "status"); !strings.Contains(r.stdout, "No incident is active") {
		t.Errorf("the incident is still active after the fix was confirmed:\n%s", r.stdout)
	}

	step("incident", "inject", labtest.Fault)
	step("incident", "resolve")
	if l.exists(faultMarker) {
		t.Error("resolve reported success but left the lab broken")
	}
	history := step("incident", "history")
	for _, by := range []string{"manual", "auto"} {
		if !strings.Contains(history.stdout, by) {
			t.Errorf("history does not record a run resolved by %q:\n%s", by, history.stdout)
		}
	}
	l.golden("incident_journey", steps...)
}

// Silent mode is a game day: nothing the learner can run tells them which
// fault they were given until they have fixed it.
func TestIncident_SilentModeNeverNamesTheFault(t *testing.T) {
	l := newTerminal(t)
	l.Write(t, "incidents/other-fault/fault.yaml", strings.ReplaceAll(readFixture(t, l, "incidents/"+labtest.Fault+"/fault.yaml"), "demo-fault", "other-fault"))
	for _, f := range []string{"inject.sh", "resolve.sh", "checks/resolved.sh", "hints.md", "solution.md"} {
		l.Write(t, "incidents/other-fault/"+f, readFixture(t, l, "incidents/"+labtest.Fault+"/"+f))
	}

	inject := l.mustRun("incident", "inject", "--random", "--silent", "--seed", "3")
	injected := ""
	for _, name := range []string{labtest.Fault, "other-fault"} {
		if l.exists("incidents/" + name + "/BROKEN") {
			injected = name
		}
	}
	if injected == "" {
		t.Fatal("no fault was injected")
	}

	hidden := []cliResult{inject, l.mustRun("incident", "status"), l.mustRun("incident", "list"), l.mustRun("incident", "hint")}
	for _, r := range hidden {
		out := r.stdout + r.stderr
		if strings.Contains(out, injected+" started") || strings.Contains(out, "incident.inject "+injected) {
			t.Errorf("`labctl %s` names the fault it injected:\n%s", strings.Join(r.args, " "), out)
		}
		if strings.Contains(out, "ACTIVE") {
			t.Errorf("`labctl %s` marks the active fault:\n%s", strings.Join(r.args, " "), out)
		}
	}
	if list := hidden[2].stdout; !strings.Contains(list, "An incident is active") {
		t.Errorf("list in silent mode does not say an incident is active:\n%s", list)
	}

	// The run history neither names the fault nor shows what its script
	// printed.
	runs := l.mustRun("runs", "list")
	if strings.Contains(runs.stdout, injected) || !strings.Contains(runs.stdout, "(hidden)") {
		t.Errorf("runs list names the silent fault:\n%s", runs.stdout)
	}
	runID := runIDRe.FindString(runs.stdout)
	if logs := l.run("runs", "logs", runID); logs.exitCode() != 1 || !strings.Contains(logs.stderr, "output is withheld") {
		t.Errorf("runs logs %s = exit %d, stderr %q; want the output withheld", runID, logs.exitCode(), logs.stderr)
	}

	l.remove("incidents/" + injected + "/BROKEN")
	if r := l.mustRun("incident", "status"); !strings.Contains(r.stdout, "It was: "+injected) {
		t.Errorf("status after the fix does not reveal the fault:\n%s", r.stdout)
	}
}

func readFixture(t *testing.T, l *terminal, rel string) string {
	t.Helper()
	data, err := os.ReadFile(filepath.Join(l.Root, rel))
	if err != nil {
		t.Fatal(err)
	}
	return string(data)
}

func TestIncident_Failures(t *testing.T) {
	tests := []struct {
		name    string
		prepare func(t *testing.T, l *terminal)
		args    []string
		wantErr string
	}{
		{"hint with nothing injected", nil, []string{"incident", "hint"}, "no incident is active"},
		{"resolve with nothing injected", nil, []string{"incident", "resolve"}, "pass a fault name to force-resolve"},
		{"inject with neither a name nor --random", nil, []string{"incident", "inject"}, "pass exactly one of a fault name or --random"},
		{"inject with both a name and --random", nil, []string{"incident", "inject", labtest.Fault, "--random"}, "pass exactly one of a fault name or --random"},
		{"inject a fault that does not exist", nil, []string{"incident", "inject", "ghost"}, "see 'labctl incident list'"},
		{"info on a fault that does not exist", nil, []string{"incident", "info", "ghost"}, "see 'labctl incident list'"},
		{"resolve a fault that does not exist", nil, []string{"incident", "resolve", "ghost"}, "see 'labctl incident list'"},
		{"random pick in a category with no faults", nil, []string{"incident", "inject", "--random", "--category", "storage"}, "storage"},
		{"a second inject while one is active",
			func(_ *testing.T, l *terminal) { l.mustRun("incident", "inject", labtest.Fault) },
			[]string{"incident", "inject", labtest.Fault}, "resolve it first, or use --force"},
		{"inject when the app is not deployed",
			func(_ *testing.T, l *terminal) { l.undeploy(labtest.App) },
			[]string{"incident", "inject", labtest.Fault}, "labctl app build demo-app && labctl app deploy demo-app"},
		{"inject when the fault's script fails",
			func(t *testing.T, l *terminal) {
				l.Write(t, "incidents/"+labtest.Fault+"/inject.sh", "#!/usr/bin/env bash\necho 'the cluster refused' >&2\nexit 4\n")
			},
			[]string{"incident", "inject", labtest.Fault}, "inject demo-fault failed"},
		{"an app that does not exist", nil, []string{"incident", "inject", labtest.Fault, "--app", "ghost"}, "app ghost"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			l := newTerminal(t)
			if tt.prepare != nil {
				tt.prepare(t, l)
			}
			r := l.run(tt.args...)
			if r.exitCode() != 1 {
				t.Fatalf("exit code = %d, want 1\nstdout:\n%s", r.exitCode(), r.stdout)
			}
			if !strings.Contains(r.stderr, tt.wantErr) {
				t.Errorf("stderr = %q, want it to say %q", r.stderr, tt.wantErr)
			}
			if strings.Contains(r.stderr, l.Root) {
				t.Errorf("the error shows a path inside the lab instead of what to do: %q", r.stderr)
			}
		})
	}
}

// A failed inject leaves nothing recorded as active, so the learner is not
// told to resolve an incident that never started.
func TestIncident_FailedInjectIsNotRecorded(t *testing.T) {
	l := newTerminal(t)
	l.Write(t, "incidents/"+labtest.Fault+"/inject.sh", "#!/usr/bin/env bash\nexit 4\n")
	if r := l.run("incident", "inject", labtest.Fault); r.err == nil {
		t.Fatal("the failing inject reported success")
	}
	if r := l.mustRun("incident", "status"); !strings.Contains(r.stdout, "No incident is active") {
		t.Errorf("a failed inject left an incident active:\n%s", r.stdout)
	}
}

// --force replaces the active incident; the fault script still runs.
func TestIncident_ForceInjectReplacesTheActiveIncident(t *testing.T) {
	l := newTerminal(t)
	l.mustRun("incident", "inject", labtest.Fault)
	l.remove(faultMarker)
	l.mustRun("incident", "inject", labtest.Fault, "--force")
	if !l.exists(faultMarker) {
		t.Error("--force did not run the fault's inject script again")
	}
}
