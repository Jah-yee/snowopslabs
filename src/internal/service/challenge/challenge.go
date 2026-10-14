// SPDX-License-Identifier: Apache-2.0

// Package challenge sets up, grades and cleans up a timed challenge. The CLI
// and the API both submit through Grader, so a recorded score always comes
// from the challenge's own checks run against the lab.
package challenge

import (
	"context"
	"errors"
	"fmt"

	"github.com/sagar2395/snowopslabs/internal/challenge"
	"github.com/sagar2395/snowopslabs/internal/config"
	"github.com/sagar2395/snowopslabs/internal/executor"
	"github.com/sagar2395/snowopslabs/internal/incident"
	"github.com/sagar2395/snowopslabs/internal/labcheck"
	"github.com/sagar2395/snowopslabs/internal/scenario"
	"github.com/sagar2395/snowopslabs/internal/workload"
	"github.com/sagar2395/snowopslabs/pkg/checks"
)

// ErrNoChecks reports a challenge whose grading resolves to no checks. With
// nothing to pass it is never recorded as passed.
var ErrNoChecks = errors.New("the challenge has no grading checks: run 'labctl validate'")

// Grader runs a challenge's setup, grading and cleanup against the lab. Its
// engines must already be bound to the workload the challenge acts on.
type Grader struct {
	Engine    *challenge.Engine
	Scenarios *scenario.Engine
	Incidents *incident.Engine
	Config    *config.Config
	Exec      *executor.Executor
}

// Submission is one graded attempt at the active challenge.
type Submission struct {
	Challenge *challenge.Challenge
	Record    *challenge.RunRecord
	Checks    []checks.Result
	// Passed is true when every check passed and the run was recorded.
	Passed bool
	// CleanupErr is why the setup could not be undone after a pass. The score
	// is recorded either way.
	CleanupErr error
}

// Submit grades the active challenge. A pass records the score for user ("" is
// the OS user), ends the run and undoes the setup. A fail scores the attempt
// and leaves the run going, so the learner can fix it and submit again.
func (g *Grader) Submit(ctx context.Context, user string) (*Submission, error) {
	active, err := g.Engine.Active()
	if err != nil {
		return nil, err
	}
	if active == nil {
		return nil, challenge.ErrNoActive
	}
	c, err := g.Engine.Load(active.ChallengeName)
	if err != nil {
		return nil, err
	}
	gradingChecks, scriptDir, err := g.Checks(c)
	if err != nil {
		return nil, err
	}
	if len(gradingChecks) == 0 {
		return nil, fmt.Errorf("challenge %s: %w", c.Name, ErrNoChecks)
	}

	results := labcheck.NewRunner(g.Config, g.workload(c), scriptDir).RunAll(ctx, gradingChecks)
	passed := 0
	for _, r := range results {
		if r.Pass {
			passed++
		}
	}
	sub := &Submission{Challenge: c, Checks: results}

	if passed < len(results) {
		sub.Record, err = g.Engine.Attempt(passed, len(results))
		return sub, err
	}
	sub.Record, err = g.Engine.Complete(passed, len(results), "passed", user)
	if err != nil {
		return sub, err
	}
	sub.Passed = true
	// Undo the setup so no incident stays active to block the next challenge.
	sub.CleanupErr = g.Cleanup(c)
	return sub, nil
}

// Checks returns the checks a challenge is graded with and the directory
// their scripts are relative to: the fault's directory for a detection check,
// otherwise the project root.
func (g *Grader) Checks(c *challenge.Challenge) ([]checks.Check, string, error) {
	if c.Grading.UseDetectionCheck && c.Setup.Type == "incident" {
		f, err := g.Incidents.Get(c.Setup.Ref)
		if err != nil {
			return nil, "", fmt.Errorf("loading detection check for %s: %w", c.Setup.Ref, err)
		}
		return []checks.Check{g.Incidents.ResolveCheck(f.Detection)}, f.Dir, nil
	}
	cs := make([]checks.Check, 0, len(c.Grading.Checks))
	for _, gc := range c.Grading.Checks {
		cs = append(cs, g.resolveCheck(c, checks.Check{
			Name:           gc.Name,
			Type:           gc.Type,
			URL:            gc.URL,
			ExpectStatus:   gc.ExpectStatus,
			Script:         gc.Script,
			Query:          gc.Query,
			Operator:       gc.Operator,
			Value:          gc.Value,
			TimeoutSeconds: gc.TimeoutSeconds,
		}))
	}
	return cs, g.Config.ProjectRoot, nil
}

// resolveCheck expands template variables with the engine that runs the
// challenge's setup.
func (g *Grader) resolveCheck(c *challenge.Challenge, k checks.Check) checks.Check {
	if c.Setup.Type == "scenario" {
		return g.Scenarios.ResolveCheck(k)
	}
	return g.Incidents.ResolveCheck(k)
}

// workload is the app the challenge's setup acts on.
func (g *Grader) workload(c *challenge.Challenge) workload.Workload {
	if c.Setup.Type == "scenario" || g.Incidents == nil {
		return g.Scenarios.Workload
	}
	return g.Incidents.Workload
}

// Setup prepares the lab for a challenge: it injects the fault or activates
// the scenario the challenge names.
func (g *Grader) Setup(c *challenge.Challenge) error {
	switch c.Setup.Type {
	case "incident":
		_, err := g.Incidents.Inject(c.Setup.Ref, g.Exec, false, false)
		return err
	case "scenario":
		return g.Scenarios.Up(c.Setup.Ref, g.Exec, false)
	default:
		return fmt.Errorf("unknown setup type %q", c.Setup.Type)
	}
}

// Cleanup undoes Setup.
func (g *Grader) Cleanup(c *challenge.Challenge) error {
	switch c.Setup.Type {
	case "incident":
		_, err := g.Incidents.Resolve(c.Setup.Ref, g.Exec, "")
		return err
	case "scenario":
		return g.Scenarios.Down(c.Setup.Ref, g.Exec)
	default:
		return fmt.Errorf("unknown setup type %q", c.Setup.Type)
	}
}
