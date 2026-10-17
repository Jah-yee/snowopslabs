// SPDX-License-Identifier: Apache-2.0

package challenge

import (
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

const validChallengeYAML = `
name: test-challenge
displayName: "Test Challenge"
description: "A test challenge"
category: workload
parTime: "10m"
setup:
  type: incident
  ref: bad-deploy-rollout
grading:
  useDetectionCheck: true
hintPenalty: 5
`

func makeEngine(t *testing.T) (*Engine, string) {
	t.Helper()
	dir := t.TempDir()
	cDir := filepath.Join(dir, "challenges")
	sDir := filepath.Join(dir, ".labctl", "challenges")
	if err := os.MkdirAll(cDir, 0o755); err != nil {
		t.Fatal(err)
	}
	e := New(cDir, sDir, "")
	fixed := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	e.now = func() time.Time { return fixed }
	return e, cDir
}

func writeChallengeYAML(t *testing.T, cDir, name, content string) {
	t.Helper()
	dir := filepath.Join(cDir, name)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "challenge.yaml"), []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestLoad_Valid(t *testing.T) {
	e, cDir := makeEngine(t)
	writeChallengeYAML(t, cDir, "test-challenge", validChallengeYAML)
	c, err := e.Load("test-challenge")
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if c.Name != "test-challenge" {
		t.Errorf("name = %q", c.Name)
	}
	if c.Setup.Ref != "bad-deploy-rollout" {
		t.Errorf("setup.ref = %q", c.Setup.Ref)
	}
}

// What Load says when a challenge cannot be used tells the user what to run
// next, and never the path it looked under.
func TestLoad_Errors(t *testing.T) {
	tests := []struct {
		name         string
		yaml         string // "" writes no file
		wantText     string
		wantNotExist bool
	}{
		{"no such challenge", "", `challenge "broken" not found (see 'labctl challenge list')`, true},
		{"YAML that does not parse", "name: [unclosed", "challenge broken is malformed (run 'labctl validate')", false},
		{"missing required fields", "name: broken\n", "displayName is required", false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			e, cDir := makeEngine(t)
			if tt.yaml != "" {
				writeChallengeYAML(t, cDir, "broken", tt.yaml)
			}
			_, err := e.Load("broken")
			if err == nil {
				t.Fatal("Load() returned no error")
			}
			if !strings.Contains(err.Error(), tt.wantText) {
				t.Errorf("Load() error = %q, want it to say %q", err, tt.wantText)
			}
			if strings.Contains(err.Error(), cDir) {
				t.Errorf("Load() error names the directory it read: %q", err)
			}
			if got := errors.Is(err, fs.ErrNotExist); got != tt.wantNotExist {
				t.Errorf("errors.Is(err, fs.ErrNotExist) = %v, want %v", got, tt.wantNotExist)
			}
		})
	}
}

func TestValidate_MissingGrading(t *testing.T) {
	c := &Challenge{
		Name:        "bad",
		DisplayName: "Bad",
		Setup:       SetupSpec{Type: "incident", Ref: "x"},
		Grading:     GradingSpec{}, // neither useDetectionCheck nor checks
	}
	errs := c.Validate()
	if len(errs) == 0 {
		t.Fatal("expected validation error for missing grading spec")
	}
}

func TestValidate_BadParTime(t *testing.T) {
	c := &Challenge{
		Name:        "bad",
		DisplayName: "Bad",
		Setup:       SetupSpec{Type: "incident", Ref: "x"},
		Grading:     GradingSpec{UseDetectionCheck: true},
		ParTime:     "not-a-duration",
	}
	errs := c.Validate()
	found := false
	for _, e := range errs {
		if e == "parTime: invalid duration format (use e.g. 10m, 1h)" {
			found = true
		}
	}
	if !found {
		t.Errorf("expected parTime error, got: %v", errs)
	}
}

func TestChallenges_Empty(t *testing.T) {
	e, _ := makeEngine(t)
	cs, err := e.Challenges()
	if err != nil {
		t.Fatalf("Challenges: %v", err)
	}
	if len(cs) != 0 {
		t.Errorf("expected 0 challenges, got %d", len(cs))
	}
}

func TestChallenges_SkipsMalformed(t *testing.T) {
	e, cDir := makeEngine(t)
	writeChallengeYAML(t, cDir, "good", validChallengeYAML)
	writeChallengeYAML(t, cDir, "bad", "invalid: yaml: {{{{")
	cs, err := e.Challenges()
	if err != nil {
		t.Fatalf("Challenges: %v", err)
	}
	if len(cs) != 1 || cs[0] == nil || cs[0].Name != "test-challenge" {
		t.Errorf("Challenges() = %v, want only the valid challenge", cs)
	}
}

func TestActiveRun_Lifecycle(t *testing.T) {
	e, cDir := makeEngine(t)
	writeChallengeYAML(t, cDir, "test-challenge", validChallengeYAML)

	// No active run initially.
	active, err := e.Active()
	if err != nil {
		t.Fatalf("Active: %v", err)
	}
	if active != nil {
		t.Fatal("expected no active run")
	}

	// Start.
	run, err := e.Start("test-challenge", false)
	if err != nil {
		t.Fatalf("Start: %v", err)
	}
	if run.ChallengeName != "test-challenge" {
		t.Errorf("challenge name = %q", run.ChallengeName)
	}

	// Active returns it.
	active, err = e.Active()
	if err != nil {
		t.Fatalf("Active after start: %v", err)
	}
	if active == nil {
		t.Fatal("expected active run after start")
	}
}

func TestStart_AlreadyActive(t *testing.T) {
	e, cDir := makeEngine(t)
	writeChallengeYAML(t, cDir, "test-challenge", validChallengeYAML)
	_, _ = e.Start("test-challenge", false)
	_, err := e.Start("test-challenge", false)
	if err == nil {
		t.Fatal("expected error when starting challenge while one is already active")
	}
}

func TestStart_Force(t *testing.T) {
	e, cDir := makeEngine(t)
	writeChallengeYAML(t, cDir, "test-challenge", validChallengeYAML)
	_, _ = e.Start("test-challenge", false)
	_, err := e.Start("test-challenge", true)
	if err != nil {
		t.Fatalf("Force start: %v", err)
	}
}

func TestRecordHint(t *testing.T) {
	e, cDir := makeEngine(t)
	writeChallengeYAML(t, cDir, "test-challenge", validChallengeYAML)
	_, _ = e.Start("test-challenge", false)
	if err := e.RecordHint(); err != nil {
		t.Fatalf("RecordHint: %v", err)
	}
	active, _ := e.Active()
	if active.HintsUsed != 1 {
		t.Errorf("hints = %d, want 1", active.HintsUsed)
	}
}

func TestEngine_NoActiveChallenge(t *testing.T) {
	tests := []struct {
		name string
		call func(e *Engine) error
	}{
		{"RecordHint", func(e *Engine) error { return e.RecordHint() }},
		{"Attempt", func(e *Engine) error { _, err := e.Attempt(1, 1); return err }},
		{"Complete", func(e *Engine) error { _, err := e.Complete(1, 1, "passed", ""); return err }},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			e, _ := makeEngine(t)
			err := tt.call(e)
			if !errors.Is(err, ErrNoActive) {
				t.Fatalf("with nothing running, error = %v, want ErrNoActive", err)
			}
			if history, _ := e.History(); len(history) != 0 {
				t.Errorf("a call with nothing running recorded %d history entries", len(history))
			}
		})
	}
}

func TestComplete_RecordsHistory(t *testing.T) {
	e, cDir := makeEngine(t)
	writeChallengeYAML(t, cDir, "test-challenge", validChallengeYAML)
	_, _ = e.Start("test-challenge", false)
	_ = e.RecordHint()

	rec, err := e.Complete(2, 2, "passed", "")
	if err != nil {
		t.Fatalf("Complete: %v", err)
	}
	if rec.ChecksPassed != 2 {
		t.Errorf("checks passed = %d", rec.ChecksPassed)
	}
	if rec.HintsUsed != 1 {
		t.Errorf("hints used = %d", rec.HintsUsed)
	}
	if rec.Score <= 0 || rec.Score > 100 {
		t.Errorf("score %d out of range", rec.Score)
	}

	// Active should be cleared.
	active, _ := e.Active()
	if active != nil {
		t.Error("expected no active run after complete")
	}

	// History should have a record.
	history, err := e.History()
	if err != nil {
		t.Fatalf("History: %v", err)
	}
	if len(history) != 1 {
		t.Fatalf("expected 1 history record, got %d", len(history))
	}
	if history[0].Outcome != "passed" {
		t.Errorf("outcome = %q", history[0].Outcome)
	}
}

func TestComputeScore_AllPass_NoPenalty(t *testing.T) {
	c := &Challenge{ParTime: "10m", HintPenalty: 5}
	elapsed := 5 * time.Minute // under par
	score := computeScore(c, elapsed, 0, 2, 2)
	if score != 100 {
		t.Errorf("expected 100, got %d", score)
	}
}

func TestComputeScore_HintPenalty(t *testing.T) {
	c := &Challenge{ParTime: "10m", HintPenalty: 5}
	score := computeScore(c, 5*time.Minute, 3, 2, 2)
	// 100 - 3*5 = 85
	if score != 85 {
		t.Errorf("expected 85, got %d", score)
	}
}

func TestComputeScore_TimePenalty(t *testing.T) {
	c := &Challenge{ParTime: "10m", HintPenalty: 5}
	score := computeScore(c, 20*time.Minute, 0, 2, 2) // 2x par = 20% penalty
	// 100 - 0 - 20 = 80
	if score != 80 {
		t.Errorf("expected 80, got %d", score)
	}
}

func TestComputeScore_PartialChecks(t *testing.T) {
	c := &Challenge{ParTime: "10m", HintPenalty: 5}
	score := computeScore(c, 5*time.Minute, 0, 1, 2) // 1/2 checks pass
	// base = 100, scaled by 1/2 = 50
	if score != 50 {
		t.Errorf("expected 50, got %d", score)
	}
}

func TestComputeScore_NoChecksPass(t *testing.T) {
	c := &Challenge{ParTime: "10m", HintPenalty: 5}
	score := computeScore(c, 5*time.Minute, 0, 0, 2)
	if score != 0 {
		t.Errorf("expected 0, got %d", score)
	}
}

func TestParDuration(t *testing.T) {
	c := &Challenge{ParTime: "15m"}
	d := c.ParDuration()
	if d != 15*time.Minute {
		t.Errorf("expected 15m, got %v", d)
	}
}

func TestHistory_EmptyIsNil(t *testing.T) {
	e, _ := makeEngine(t)
	h, err := e.History()
	if err != nil {
		t.Fatalf("History: %v", err)
	}
	if h != nil {
		t.Error("expected nil history when no runs")
	}
}

// A failed submit must not end the run: the learner can keep working, and
// `abort` still has an active run to clean up.
func TestAttemptGradesWithoutEndingTheRun(t *testing.T) {
	e, cDir := makeEngine(t)
	writeChallengeYAML(t, cDir, "test-challenge", validChallengeYAML)
	if _, err := e.Start("test-challenge", false); err != nil {
		t.Fatalf("Start: %v", err)
	}

	rec, err := e.Attempt(0, 1)
	if err != nil {
		t.Fatalf("Attempt: %v", err)
	}
	if rec.Score != 0 {
		t.Errorf("zero-work attempt scored %d, want 0", rec.Score)
	}

	active, err := e.Active()
	if err != nil || active == nil {
		t.Fatalf("Attempt ended the run: active=%v err=%v", active, err)
	}

	hist, _ := e.History()
	for _, h := range hist {
		if h.Outcome == "failed" {
			t.Error("Attempt wrote a history record; only Complete may")
		}
	}
}

// A finished run goes into the shared results history when the engine has one,
// and nowhere when it does not.
func TestComplete_WritesTheResultsHistory(t *testing.T) {
	for _, withResults := range []bool{true, false} {
		t.Run(fmt.Sprintf("results dir set: %v", withResults), func(t *testing.T) {
			dir := t.TempDir()
			cDir := filepath.Join(dir, "challenges")
			resultsDir := ""
			if withResults {
				resultsDir = filepath.Join(dir, "history")
			}
			e := New(cDir, filepath.Join(dir, "state"), resultsDir)
			writeChallengeYAML(t, cDir, "test-challenge", validChallengeYAML)
			t.Chdir(dir)
			if _, err := e.Start("test-challenge", false); err != nil {
				t.Fatal(err)
			}
			if _, err := e.Complete(1, 1, "passed", "olive"); err != nil {
				t.Fatal(err)
			}
			data, err := os.ReadFile(filepath.Join(dir, "history", "results.jsonl"))
			if withResults && (err != nil || !strings.Contains(string(data), `"user":"olive"`)) {
				t.Errorf("results history = %q, %v; want the run recorded for olive", data, err)
			}
			if !withResults {
				if _, err := os.Stat(filepath.Join(dir, "results.jsonl")); err == nil {
					t.Error("an engine with no results dir wrote results.jsonl into the working directory")
				}
			}
		})
	}
}

// The score, exactly: 100 less 5 (or the challenge's own rate) per hint, less
// up to 20 for time over par in proportion to how far over, never below 0,
// then scaled by the share of checks that passed.
func TestComputeScore_Exact(t *testing.T) {
	par10 := &Challenge{ParTime: "10m"}
	tests := []struct {
		name          string
		c             *Challenge
		elapsed       time.Duration
		hints         int
		passed, total int
		want          int
	}{
		{"on par, no hints, all checks", par10, 10 * time.Minute, 0, 4, 4, 100},
		{"a second over par costs nothing measurable", par10, 10*time.Minute + time.Second, 0, 4, 4, 100},
		{"half as long again costs 10", par10, 15 * time.Minute, 0, 4, 4, 90},
		{"the time penalty stops at 20", par10, 60 * time.Minute, 0, 4, 4, 80},
		{"no par means no time penalty", &Challenge{}, 5 * time.Hour, 0, 1, 1, 100},
		{"two hints at the default 5", par10, time.Minute, 2, 1, 1, 90},
		{"two hints at the challenge's own 15", &Challenge{ParTime: "10m", HintPenalty: 15}, time.Minute, 2, 1, 1, 70},
		{"three of four checks", par10, time.Minute, 0, 3, 4, 75},
		{"one of three checks", par10, time.Minute, 0, 1, 3, 33},
		{"penalties and partial checks together", par10, 15 * time.Minute, 2, 1, 2, 40},
		{"deductions never go below zero", &Challenge{HintPenalty: 60}, time.Minute, 2, 1, 1, 0},
		{"no checks pass", par10, time.Minute, 0, 0, 3, 0},
		{"no checks at all", par10, time.Minute, 0, 0, 0, 0},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := computeScore(tt.c, tt.elapsed, tt.hints, tt.passed, tt.total); got != tt.want {
				t.Errorf("computeScore() = %d, want %d", got, tt.want)
			}
		})
	}
}

func TestValidate_SetupRefs(t *testing.T) {
	grading := GradingSpec{UseDetectionCheck: true}
	tests := []struct {
		name    string
		setup   SetupSpec
		wantErr string // "" means valid
		wantAll []string
	}{
		{"one fault by ref", SetupSpec{Type: "incident", Ref: "a"}, "", []string{"a"}},
		{"several faults by refs", SetupSpec{Type: "incident", Refs: []string{"a", "b"}}, "", []string{"a", "b"}},
		{"neither", SetupSpec{Type: "incident"}, "setup.ref is required", nil},
		{"both", SetupSpec{Type: "incident", Ref: "a", Refs: []string{"b", "c"}}, "not both", nil},
		{"scenarios cannot be set up together", SetupSpec{Type: "scenario", Refs: []string{"a", "b"}}, "only incidents", nil},
		{"a list of one", SetupSpec{Type: "incident", Refs: []string{"a"}}, "two or more", nil},
		{"a fault listed twice", SetupSpec{Type: "incident", Refs: []string{"a", "a"}}, `"a" is empty or listed twice`, nil},
		{"an empty name", SetupSpec{Type: "incident", Refs: []string{"a", ""}}, "is empty or listed twice", nil},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			c := &Challenge{Name: "x", DisplayName: "X", Setup: tt.setup, Grading: grading}
			errs := strings.Join(c.Validate(), "; ")
			if tt.wantErr == "" {
				if errs != "" {
					t.Fatalf("Validate() = %q, want no errors", errs)
				}
				if got := strings.Join(tt.setup.All(), ","); got != strings.Join(tt.wantAll, ",") {
					t.Errorf("All() = %q, want %q", got, strings.Join(tt.wantAll, ","))
				}
				return
			}
			if !strings.Contains(errs, tt.wantErr) {
				t.Errorf("Validate() = %q, want it to contain %q", errs, tt.wantErr)
			}
		})
	}
}
