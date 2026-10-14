// SPDX-License-Identifier: Apache-2.0

package challenge

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/sagar2395/snowopslabs/internal/challenge"
	"github.com/sagar2395/snowopslabs/internal/config"
	"github.com/sagar2395/snowopslabs/internal/executor"
	"github.com/sagar2395/snowopslabs/internal/incident"
	"github.com/sagar2395/snowopslabs/internal/scenario"
)

const script = "#!/usr/bin/env bash\nset -eu\n"

// The lab is broken while a BROKEN marker exists: the fault's inject.sh and
// the scenario's setup.sh create it, resolve.sh and teardown.sh remove it, and
// every grading check passes only once it is gone.
var labFiles = map[string]string{
	"incidents/demo-fault/fault.yaml": `name: demo-fault
displayName: "Demo fault"
description: "the demo app is broken"
category: workload
severity: low
target:
  namespace: demo
  workload: demo
detection:
  name: marker-gone
  type: script
  script: checks/resolved.sh
  timeoutSeconds: 5
`,
	"incidents/demo-fault/inject.sh":          script + "touch \"$PROJECT_ROOT/BROKEN\"\n",
	"incidents/demo-fault/resolve.sh":         script + "rm -f \"$PROJECT_ROOT/BROKEN\"\necho resolved >>\"$PROJECT_ROOT/CLEANED\"\n",
	"incidents/demo-fault/checks/resolved.sh": script + "[ ! -f \"$PROJECT_ROOT/BROKEN\" ]\n",
	"incidents/demo-fault/hints.md":           "## Hint 1\nlook at the pods\n",
	"incidents/demo-fault/solution.md":        "# Solution\nroll it back\n",

	"scenarios/demo-scenario/scenario.yaml": `apiVersion: scenario.snowops.net/v2
name: demo-scenario
displayName: Demo scenario
description: A scenario
category: reliability
components:
  - name: setup
    type: script
    script: setup.sh
    uninstallScript: teardown.sh
checks:
  - name: marker-gone
    type: script
    script: checks/fixed.sh
    timeoutSeconds: 5
    remediation: fix it
`,
	"scenarios/demo-scenario/setup.sh":        script + "touch \"$PROJECT_ROOT/BROKEN\"\n",
	"scenarios/demo-scenario/teardown.sh":     script + "rm -f \"$PROJECT_ROOT/BROKEN\"\necho down >>\"$PROJECT_ROOT/CLEANED\"\n",
	"scenarios/demo-scenario/checks/fixed.sh": script + "[ ! -f \"$PROJECT_ROOT/BROKEN\" ]\n",

	"checks/fixed.sh":  script + "[ ! -f \"$PROJECT_ROOT/BROKEN\" ]\n",
	"checks/always.sh": script + "exit 0\n",

	"challenges/by-detection/challenge.yaml": `name: by-detection
displayName: "Graded by the fault's check"
parTime: "10m"
setup: {type: incident, ref: demo-fault}
grading: {useDetectionCheck: true}
`,
	"challenges/by-checks/challenge.yaml": `name: by-checks
displayName: "Graded by its own checks"
parTime: "10m"
setup: {type: incident, ref: demo-fault}
grading:
  checks:
    - {name: always, type: script, script: checks/always.sh, timeoutSeconds: 5}
    - {name: fixed, type: script, script: checks/fixed.sh, timeoutSeconds: 5}
`,
	"challenges/by-scenario/challenge.yaml": `name: by-scenario
displayName: "Set up by a scenario"
parTime: "10m"
setup: {type: scenario, ref: demo-scenario}
grading:
  checks:
    - {name: fixed, type: script, script: checks/fixed.sh, timeoutSeconds: 5}
`,
	"challenges/no-checks/challenge.yaml": `name: no-checks
displayName: "A detection check on a scenario resolves to nothing"
setup: {type: scenario, ref: demo-scenario}
grading: {useDetectionCheck: true}
`,
	"challenges/ghost-fault/challenge.yaml": `name: ghost-fault
displayName: "Names a fault that does not exist"
setup: {type: incident, ref: ghost}
grading: {useDetectionCheck: true}
`,
	"challenges/odd-setup/challenge.yaml": `name: odd-setup
displayName: "Names a setup type nothing implements"
setup: {type: wizardry, ref: demo-fault}
grading:
  checks:
    - {name: always, type: script, script: checks/always.sh, timeoutSeconds: 5}
`,
}

type lab struct {
	root   string
	grader *Grader
}

func newLab(t *testing.T) *lab {
	t.Helper()
	root := t.TempDir()
	for rel, content := range labFiles {
		path := filepath.Join(root, rel)
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			t.Fatal(err)
		}
		mode := os.FileMode(0o644)
		if strings.HasSuffix(rel, ".sh") {
			mode = 0o755
		}
		if err := os.WriteFile(path, []byte(content), mode); err != nil {
			t.Fatal(err)
		}
	}
	state := filepath.Join(root, ".labctl")
	cfg := &config.Config{ProjectRoot: root, StateDir: state, DomainSuffix: "lab.test", MonitoringNamespace: "monitoring"}
	ex := executor.New(root)
	ex.SetEnv("PROJECT_ROOT", root)
	return &lab{root: root, grader: &Grader{
		Engine:    challenge.New(filepath.Join(root, "challenges"), filepath.Join(state, "challenges"), filepath.Join(state, "history")),
		Scenarios: scenario.NewEngine(root, cfg.DomainSuffix, "k3d"),
		Incidents: incident.NewEngine(root, cfg.DomainSuffix),
		Config:    cfg,
		Exec:      ex,
	}}
}

// start sets the lab up for a challenge and starts its timer, as `labctl
// challenge start` does.
func (l *lab) start(t *testing.T, name string) *challenge.Challenge {
	t.Helper()
	c, err := l.grader.Engine.Load(name)
	if err != nil {
		t.Fatalf("Load(%s): %v", name, err)
	}
	if err := l.grader.Setup(c); err != nil {
		t.Fatalf("Setup(%s): %v", name, err)
	}
	if _, err := l.grader.Engine.Start(name, false); err != nil {
		t.Fatalf("Start(%s): %v", name, err)
	}
	return c
}

func (l *lab) exists(rel string) bool {
	_, err := os.Stat(filepath.Join(l.root, rel))
	return err == nil
}

// fix is the learner repairing the lab by hand.
func (l *lab) fix(t *testing.T) {
	t.Helper()
	if err := os.Remove(filepath.Join(l.root, "BROKEN")); err != nil {
		t.Fatalf("fixing the lab: %v", err)
	}
}

func TestGrader_Submit(t *testing.T) {
	tests := []struct {
		name      string
		challenge string
		fixed     bool
		wantPass  bool
		wantOK    int
		wantTotal int
	}{
		{"detection check, lab still broken", "by-detection", false, false, 0, 1},
		{"detection check, lab fixed", "by-detection", true, true, 1, 1},
		{"own checks, lab still broken: the check that always passes earns no pass", "by-checks", false, false, 1, 2},
		{"own checks, lab fixed", "by-checks", true, true, 2, 2},
		{"scenario setup, lab still broken", "by-scenario", false, false, 0, 1},
		{"scenario setup, lab fixed", "by-scenario", true, true, 1, 1},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			l := newLab(t)
			l.start(t, tt.challenge)
			if !l.exists("BROKEN") {
				t.Fatal("the setup did not break the lab; the test would prove nothing")
			}
			if tt.fixed {
				l.fix(t)
			}

			sub, err := l.grader.Submit(t.Context(), "olive")
			if err != nil {
				t.Fatalf("Submit() error = %v", err)
			}
			if sub.Passed != tt.wantPass {
				t.Errorf("Passed = %v, want %v", sub.Passed, tt.wantPass)
			}
			if sub.Record.ChecksPassed != tt.wantOK || sub.Record.ChecksTotal != tt.wantTotal {
				t.Errorf("checks = %d/%d, want %d/%d", sub.Record.ChecksPassed, sub.Record.ChecksTotal, tt.wantOK, tt.wantTotal)
			}
			if len(sub.Checks) != tt.wantTotal {
				t.Errorf("got %d check results, want %d", len(sub.Checks), tt.wantTotal)
			}

			active, err := l.grader.Engine.Active()
			if err != nil {
				t.Fatal(err)
			}
			history, err := l.grader.Engine.History()
			if err != nil {
				t.Fatal(err)
			}
			if tt.wantPass {
				if sub.Record.Outcome != "passed" || sub.Record.Score != 100 {
					t.Errorf("record = %s with score %d, want passed with 100", sub.Record.Outcome, sub.Record.Score)
				}
				if active != nil {
					t.Error("the run is still active after a pass")
				}
				if len(history) != 1 || history[0].Outcome != "passed" {
					t.Errorf("history = %+v, want one passed run", history)
				}
				if sub.CleanupErr != nil {
					t.Errorf("CleanupErr = %v", sub.CleanupErr)
				}
				if !l.exists("CLEANED") {
					t.Error("the setup was not undone after a pass")
				}
				return
			}
			if sub.Record.Outcome != "failed" || sub.Record.Score == 100 {
				t.Errorf("record = %s with score %d, want failed with less than 100", sub.Record.Outcome, sub.Record.Score)
			}
			if active == nil {
				t.Error("a failed attempt ended the run; the learner could not submit again")
			}
			if len(history) != 0 {
				t.Errorf("a failed attempt was recorded in history: %+v", history)
			}
			if l.exists("CLEANED") {
				t.Error("a failed attempt undid the setup")
			}
		})
	}
}

func TestGrader_Submit_RetryAfterAFailedAttemptPasses(t *testing.T) {
	l := newLab(t)
	l.start(t, "by-detection")

	first, err := l.grader.Submit(t.Context(), "olive")
	if err != nil || first.Passed {
		t.Fatalf("first Submit() = passed %v, err %v; want a failed attempt", first != nil && first.Passed, err)
	}
	l.fix(t)
	second, err := l.grader.Submit(t.Context(), "olive")
	if err != nil {
		t.Fatalf("second Submit() error = %v", err)
	}
	if !second.Passed {
		t.Error("the fixed lab did not pass on the second submit")
	}
}

func TestGrader_Submit_Refused(t *testing.T) {
	tests := []struct {
		name      string
		challenge string // started without its setup; "" starts nothing
		wantErr   error
		wantText  string
	}{
		{"no challenge is running", "", challenge.ErrNoActive, ""},
		{"grading resolves to no checks", "no-checks", ErrNoChecks, "no-checks"},
		{"the fault it grades with is gone", "ghost-fault", nil, "loading detection check for ghost"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			l := newLab(t)
			if tt.challenge != "" {
				if _, err := l.grader.Engine.Start(tt.challenge, false); err != nil {
					t.Fatal(err)
				}
			}
			sub, err := l.grader.Submit(t.Context(), "olive")
			if err == nil {
				t.Fatalf("Submit() = %+v, want an error", sub)
			}
			if tt.wantErr != nil && !errors.Is(err, tt.wantErr) {
				t.Errorf("Submit() error = %v, want %v", err, tt.wantErr)
			}
			if !strings.Contains(err.Error(), tt.wantText) {
				t.Errorf("Submit() error = %q, want it to mention %q", err, tt.wantText)
			}
			if history, _ := l.grader.Engine.History(); len(history) != 0 {
				t.Errorf("a refused submit was recorded: %+v", history)
			}
		})
	}
}

// A request that is cancelled mid-grading fails its checks; that must never
// be recorded as a pass.
func TestGrader_Submit_CancelledContextIsNotAPass(t *testing.T) {
	l := newLab(t)
	l.start(t, "by-detection")
	l.fix(t)

	ctx, cancel := context.WithCancel(t.Context())
	cancel()
	sub, err := l.grader.Submit(ctx, "olive")
	if err != nil {
		t.Fatalf("Submit() error = %v", err)
	}
	if sub.Passed {
		t.Error("a cancelled submit was recorded as a pass")
	}
	if active, _ := l.grader.Engine.Active(); active == nil {
		t.Error("a cancelled submit ended the run")
	}
}

func TestGrader_Submit_CleanupFailureKeepsTheScore(t *testing.T) {
	l := newLab(t)
	l.start(t, "by-detection")
	l.fix(t)
	resolve := filepath.Join(l.root, "incidents", "demo-fault", "resolve.sh")
	if err := os.WriteFile(resolve, []byte(script+"exit 3\n"), 0o755); err != nil { //nolint:gosec // a test script must be executable
		t.Fatal(err)
	}

	sub, err := l.grader.Submit(t.Context(), "olive")
	if err != nil {
		t.Fatalf("Submit() error = %v", err)
	}
	if !sub.Passed || sub.CleanupErr == nil {
		t.Errorf("Passed = %v, CleanupErr = %v; want a pass that reports the failed cleanup", sub.Passed, sub.CleanupErr)
	}
	if history, _ := l.grader.Engine.History(); len(history) != 1 {
		t.Errorf("history has %d runs, want the pass recorded", len(history))
	}
}

func TestGrader_Checks(t *testing.T) {
	l := newLab(t)
	tests := []struct {
		name      string
		challenge string
		wantNames []string
		wantDir   string
	}{
		{"a detection check runs from the fault's directory", "by-detection", []string{"marker-gone"}, filepath.Join(l.root, "incidents", "demo-fault")},
		{"own checks run from the project root", "by-checks", []string{"always", "fixed"}, l.root},
		{"a scenario challenge's checks run from the project root", "by-scenario", []string{"fixed"}, l.root},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			c, err := l.grader.Engine.Load(tt.challenge)
			if err != nil {
				t.Fatal(err)
			}
			cs, dir, err := l.grader.Checks(c)
			if err != nil {
				t.Fatalf("Checks() error = %v", err)
			}
			var names []string
			for _, k := range cs {
				names = append(names, k.Name)
			}
			if strings.Join(names, ",") != strings.Join(tt.wantNames, ",") {
				t.Errorf("checks = %v, want %v", names, tt.wantNames)
			}
			if dir != tt.wantDir {
				t.Errorf("script dir = %q, want %q", dir, tt.wantDir)
			}
		})
	}
}

// Template variables in a challenge's own checks are expanded by the engine
// that runs its setup.
func TestGrader_Checks_ExpandsTemplates(t *testing.T) {
	l := newLab(t)
	for _, setup := range []string{"incident", "scenario"} {
		t.Run(setup, func(t *testing.T) {
			c := &challenge.Challenge{
				Setup: challenge.SetupSpec{Type: setup, Ref: "demo-fault"},
				Grading: challenge.GradingSpec{Checks: []challenge.GCheck{{
					Name: "reachable", Type: "http", URL: "http://demo.{{.DomainSuffix}}/health", ExpectStatus: 200,
				}}},
			}
			cs, _, err := l.grader.Checks(c)
			if err != nil {
				t.Fatal(err)
			}
			if got, want := cs[0].URL, "http://demo.lab.test/health"; got != want {
				t.Errorf("url = %q, want %q", got, want)
			}
		})
	}
}

func TestGrader_SetupAndCleanup(t *testing.T) {
	tests := []struct {
		name      string
		challenge string
		wantErr   string
	}{
		{"incident", "by-detection", ""},
		{"scenario", "by-scenario", ""},
		{"a setup type nothing implements", "odd-setup", `unknown setup type "wizardry"`},
		{"a fault that does not exist", "ghost-fault", "ghost"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			l := newLab(t)
			c, err := l.grader.Engine.Load(tt.challenge)
			if err != nil {
				t.Fatal(err)
			}
			setupErr, cleanupErr := l.grader.Setup(c), error(nil)
			if tt.wantErr == "" {
				if setupErr != nil {
					t.Fatalf("Setup() error = %v", setupErr)
				}
				if !l.exists("BROKEN") {
					t.Fatal("Setup() did not break the lab")
				}
			}
			cleanupErr = l.grader.Cleanup(c)
			if tt.wantErr == "" {
				if cleanupErr != nil {
					t.Fatalf("Cleanup() error = %v", cleanupErr)
				}
				if l.exists("BROKEN") {
					t.Error("Cleanup() left the lab broken")
				}
				return
			}
			for step, err := range map[string]error{"Setup": setupErr, "Cleanup": cleanupErr} {
				if err == nil || !strings.Contains(err.Error(), tt.wantErr) {
					t.Errorf("%s() error = %v, want it to mention %q", step, err, tt.wantErr)
				}
			}
		})
	}
}
