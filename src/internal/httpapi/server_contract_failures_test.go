// SPDX-License-Identifier: Apache-2.0

package httpapi

// What the content routes answer when a request is wrong or the lab's own
// files are broken: always a problem, never a plain-text error, and never a
// success over state that could not be read.

import (
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// replaceWithFile puts a plain file where a directory is expected, so reading
// the directory fails with something other than "not found".
func replaceWithFile(t *testing.T, path string) {
	t.Helper()
	if err := os.RemoveAll(path); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte("not a directory"), 0o600); err != nil {
		t.Fatal(err)
	}
}

// corrupt writes text that is not JSON where a state file is expected.
func corrupt(t *testing.T, path string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte("{ not json"), 0o600); err != nil {
		t.Fatal(err)
	}
}

func TestContentRoutes_Failures(t *testing.T) {
	state := func(s *Server, parts ...string) string {
		return filepath.Join(append([]string{s.cfg.StateDir}, parts...)...)
	}
	root := func(s *Server, parts ...string) string {
		return filepath.Join(append([]string{s.cfg.ProjectRoot}, parts...)...)
	}
	brokenResults := func(t *testing.T, s *Server) { replaceWithFile(t, state(s, "history")) }
	brokenProgress := func(t *testing.T, s *Server) { corrupt(t, state(s, "learn", labPath+".json")) }
	brokenActiveChallenge := func(t *testing.T, s *Server) { corrupt(t, state(s, "challenges", "active.json")) }
	brokenIncidents := func(t *testing.T, s *Server) { replaceWithFile(t, state(s, "incidents")) }
	brokenSnapshots := func(t *testing.T, s *Server) { replaceWithFile(t, state(s, "snapshots")) }
	// clusterDown replaces the stand-in kubectl, first on PATH, with one that
	// cannot reach the API server.
	clusterDown := func(t *testing.T, _ *Server) {
		bin := filepath.SplitList(os.Getenv("PATH"))[0]
		writeLabFile(t, filepath.Join(bin, "kubectl.sh"), "#!/bin/sh\necho 'connection refused' >&2\nexit 1\n")
		if err := os.Rename(filepath.Join(bin, "kubectl.sh"), filepath.Join(bin, "kubectl")); err != nil {
			t.Fatal(err)
		}
	}
	closedRunStore := func(t *testing.T, s *Server) {
		if err := s.runStore.Close(); err != nil {
			t.Fatal(err)
		}
	}

	tests := []struct {
		name    string
		method  string
		path    string
		body    string
		breakIt func(t *testing.T, s *Server)
		status  int
		problem string
	}{
		// A name that could not be a content directory.
		{"challenge: invalid name", get, "/challenges/bad%20name", "", nil, http.StatusBadRequest, "invalid_input"},
		{"path: invalid name", get, "/learn/paths/bad%20name", "", nil, http.StatusBadRequest, "invalid_input"},
		{"path start: invalid name", post, "/learn/paths/bad%20name/start", "", nil, http.StatusBadRequest, "invalid_input"},
		{"path reset: invalid name", post, "/learn/paths/bad%20name/reset", "", nil, http.StatusBadRequest, "invalid_input"},
		{"path progress: invalid name", get, "/learn/paths/bad%20name/progress", "", nil, http.StatusBadRequest, "invalid_input"},
		{"path complete: invalid name", post, "/learn/paths/bad%20name/complete", `{"moduleIdx":0}`, nil, http.StatusBadRequest, "invalid_input"},

		// A body that is not JSON, or names a module the path does not have.
		{"path complete: body is not JSON", post, "/learn/paths/demo-path/complete", "{", nil, http.StatusBadRequest, "invalid_request"},
		{"path complete: module out of range", post, "/learn/paths/demo-path/complete", `{"moduleIdx":7}`,
			func(t *testing.T, s *Server) { startDemoPath(t, s) }, http.StatusBadRequest, "invalid_input"},
		{"path complete: negative module", post, "/learn/paths/demo-path/complete", `{"moduleIdx":-1}`,
			func(t *testing.T, s *Server) { startDemoPath(t, s) }, http.StatusBadRequest, "invalid_input"},
		{"path complete: path does not exist", post, "/learn/paths/ghost/complete", `{"moduleIdx":0}`, nil, http.StatusNotFound, "not_found"},

		// Content on disk that does not parse.
		{"challenge: malformed on disk", get, "/challenges/broken", "",
			func(t *testing.T, s *Server) {
				writeLabFile(t, root(s, "challenges", "broken", "challenge.yaml"), "name: [unclosed")
			}, http.StatusInternalServerError, "internal_error"},
		{"path: malformed on disk", get, "/learn/paths/broken", "",
			func(t *testing.T, s *Server) {
				writeLabFile(t, root(s, "learn", "broken", "path.yaml"), "name: [unclosed")
			},
			http.StatusInternalServerError, "internal_error"},

		// Content directories that cannot be listed.
		{"challenges: directory unreadable", get, "/challenges", "",
			func(t *testing.T, s *Server) { replaceWithFile(t, root(s, "challenges")) }, http.StatusInternalServerError, "internal_error"},
		{"paths: directory unreadable", get, "/learn/paths", "",
			func(t *testing.T, s *Server) { replaceWithFile(t, root(s, "learn")) }, http.StatusInternalServerError, "internal_error"},

		// State files that cannot be read.
		{"scenario up: a parameter body that is not JSON", post, "/scenarios/" + labScenario + "/up", `{"params": {"Level": "3"`, nil, http.StatusBadRequest, "invalid_request"},
		{"snapshot: the cluster does not answer", post, "/lab/snapshots/before", "", clusterDown, http.StatusServiceUnavailable, "unavailable"},
		{"reset: the cluster does not answer", post, "/lab/reset?confirm=true", "", clusterDown, http.StatusServiceUnavailable, "unavailable"},
		{"challenge status: state corrupt", get, "/challenges/status", "", brokenActiveChallenge, http.StatusInternalServerError, "internal_error"},
		{"challenge complete: state corrupt", post, "/challenges/complete", "", brokenActiveChallenge, http.StatusInternalServerError, "internal_error"},
		{"challenge complete: the challenge's files are gone", post, "/challenges/complete", "",
			func(t *testing.T, s *Server) {
				startDemoChallenge(t, s)
				if err := os.RemoveAll(root(s, "challenges", labChallenge)); err != nil {
					t.Fatal(err)
				}
			}, http.StatusInternalServerError, "internal_error"},
		{"challenge complete: the fault it grades with is gone", post, "/challenges/complete", "",
			func(t *testing.T, s *Server) {
				writeLabFile(t, root(s, "challenges", "orphan", "challenge.yaml"),
					"name: orphan\ndisplayName: Orphan\nsetup: {type: incident, ref: ghost}\ngrading: {useDetectionCheck: true}\n")
				if _, err := challengeEngine(s).Start("orphan", false); err != nil {
					t.Fatal(err)
				}
			}, http.StatusInternalServerError, "internal_error"},
		{"challenge complete: grading resolves to no checks", post, "/challenges/complete", "",
			func(t *testing.T, s *Server) {
				writeLabFile(t, root(s, "challenges", "ungraded", "challenge.yaml"),
					"name: ungraded\ndisplayName: Ungraded\nsetup: {type: scenario, ref: demo-scenario}\ngrading: {useDetectionCheck: true}\n")
				if _, err := challengeEngine(s).Start("ungraded", false); err != nil {
					t.Fatal(err)
				}
			}, http.StatusConflict, "no_checks"},
		{"challenge history: state unreadable", get, "/challenges/history", "",
			func(t *testing.T, s *Server) { replaceWithFile(t, state(s, "challenges")) }, http.StatusInternalServerError, "internal_error"},
		{"path progress: state corrupt", get, "/learn/paths/demo-path/progress", "", brokenProgress, http.StatusInternalServerError, "internal_error"},
		{"path complete: state corrupt", post, "/learn/paths/demo-path/complete", `{"moduleIdx":0}`, brokenProgress, http.StatusInternalServerError, "internal_error"},
		{"path start: state directory unwritable", post, "/learn/paths/demo-path/start", "",
			func(t *testing.T, s *Server) { replaceWithFile(t, state(s, "learn")) }, http.StatusInternalServerError, "internal_error"},
		{"path reset: progress cannot be removed", post, "/learn/paths/demo-path/reset", "",
			func(t *testing.T, s *Server) {
				writeLabFile(t, state(s, "learn", labPath+".json", "blocker"), "a file inside makes the path a non-empty directory")
			}, http.StatusInternalServerError, "internal_error"},
		{"results: store unreadable", get, "/results", "", brokenResults, http.StatusInternalServerError, "internal_error"},
		{"results by kind: store unreadable", get, "/results/incident", "", brokenResults, http.StatusInternalServerError, "internal_error"},
		{"leaderboard: store unreadable", get, "/leaderboard", "", brokenResults, http.StatusInternalServerError, "internal_error"},
		{"progress: store unreadable", get, "/progress", "", brokenResults, http.StatusInternalServerError, "internal_error"},
		{"comparisons: store unreadable", get, "/comparisons", "", brokenResults, http.StatusInternalServerError, "internal_error"},
		{"apps: directory unreadable", get, "/apps", "",
			func(t *testing.T, s *Server) { replaceWithFile(t, root(s, "apps")) }, http.StatusInternalServerError, "internal_error"},
		{"incidents: state unreadable", get, "/incidents", "", brokenIncidents, http.StatusInternalServerError, "internal_error"},
		{"incident status: state unreadable", get, "/incidents/status", "", brokenIncidents, http.StatusInternalServerError, "internal_error"},
		{"incident hint: state unreadable", post, "/incidents/hint", "", brokenIncidents, http.StatusInternalServerError, "internal_error"},
		{"incident history: state unreadable", get, "/incidents/history", "", brokenResults, http.StatusInternalServerError, "internal_error"},
		{"snapshots: store unreadable", get, "/lab/snapshots", "", brokenSnapshots, http.StatusInternalServerError, "internal_error"},
		{"snapshot take: store unwritable", post, "/lab/snapshots/before-drill", "", brokenSnapshots, http.StatusInternalServerError, "internal_error"},
		{"runs: store closed", get, "/runs", "", closedRunStore, http.StatusInternalServerError, "internal_error"},
		{"run: store closed", get, "/runs/run-1", "", closedRunStore, http.StatusInternalServerError, "internal_error"},
		{"run logs: store closed", get, "/runs/run-1/logs", "", closedRunStore, http.StatusInternalServerError, "internal_error"},
		{"run cancel: store closed", post, "/runs/run-1/cancel", "", closedRunStore, http.StatusInternalServerError, "internal_error"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			s := newContractLab(t)
			if tt.breakIt != nil {
				tt.breakIt(t, s)
			}
			w := do(s, tt.method, tt.path, tt.body, nil)
			waitForJobs(t, s)
			assertProblem(t, w, tt.status, tt.problem, instanceOf(t, tt.path))
		})
	}
}

func TestLearnComplete_OutOfRangeModuleIsNotRecorded(t *testing.T) {
	s := newContractLab(t)
	startDemoPath(t, s)

	if w := do(s, post, "/learn/paths/demo-path/complete", `{"moduleIdx":7}`, nil); w.Code != http.StatusBadRequest {
		t.Fatalf("an out-of-range module = %d, want 400: %s", w.Code, w.Body)
	}
	progress := decodeProgress(t, do(s, get, "/learn/paths/demo-path/progress", "", nil).Body.String())
	if done, _ := progress["completedIdxs"].([]any); len(done) != 0 {
		t.Errorf("the refused module was recorded anyway: completedIdxs = %v", done)
	}
}

// No route reads more than maxRequestBody bytes, whether the client declares
// the size or streams it.
func TestRequestBody_IsBounded(t *testing.T) {
	big := `{"profile":"` + strings.Repeat("x", maxRequestBody) + `"}`
	routes := []struct {
		name string
		path string
	}{
		{"traffic start", "/traffic/start"},
		{"learn complete", "/learn/paths/" + labPath + "/complete"},
		{"scenario up", "/scenarios/" + labScenario + "/up"},
		{"challenge complete", "/challenges/complete"},
	}
	for _, rt := range routes {
		t.Run(rt.name+": a declared size over the limit", func(t *testing.T) {
			s := newContractLab(t)
			w := do(s, http.MethodPost, rt.path, big, nil)
			waitForJobs(t, s)
			assertProblem(t, w, http.StatusRequestEntityTooLarge, "request_too_large", apiPrefix+rt.path)
		})
	}

	// Login is open without a session, so its body is bounded for anyone.
	t.Run("login with auth on: a declared size over the limit", func(t *testing.T) {
		s, _, _ := newAuthedLab(t)
		w := do(s, http.MethodPost, "/auth/login", big, nil)
		assertProblem(t, w, http.StatusRequestEntityTooLarge, "request_too_large", apiPrefix+"/auth/login")
	})

	t.Run("a streamed body over the limit", func(t *testing.T) {
		s := newContractLab(t)
		req := httptest.NewRequest(http.MethodPost, apiPrefix+"/traffic/start", io.NopCloser(strings.NewReader(big)))
		req.ContentLength = -1
		w := httptest.NewRecorder()
		s.router.ServeHTTP(w, req)
		assertProblem(t, w, http.StatusRequestEntityTooLarge, "request_too_large", apiPrefix+"/traffic/start")
	})

	t.Run("a body at the limit is read", func(t *testing.T) {
		s := newContractLab(t)
		atLimit := `{"profile":"steady","pad":"` + strings.Repeat("x", maxRequestBody-40) + `"}`
		w := do(s, http.MethodPost, "/traffic/start", atLimit, nil)
		waitForJobs(t, s)
		if w.Code == http.StatusRequestEntityTooLarge {
			t.Errorf("a %d-byte body was refused; the limit is %d", len(atLimit), maxRequestBody)
		}
	})
}
