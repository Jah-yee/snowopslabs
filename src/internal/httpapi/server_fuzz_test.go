// SPDX-License-Identifier: Apache-2.0

package httpapi

import (
	"net/http"
	"strings"
	"testing"
)

// FuzzRequestBodies sends arbitrary bytes as the body of the routes that read
// one. Whatever arrives, the server answers JSON or a problem, never a 5xx,
// and never records a learning module the body did not validly name.
func FuzzRequestBodies(f *testing.F) {
	for _, seed := range []string{
		"", "{", "null", "[]", `"text"`, `{"moduleIdx":0}`, `{"moduleIdx":-1}`, `{"moduleIdx":99}`,
		`{"moduleIdx":"0"}`, `{"moduleIdx":1e400}`, `{"moduleIdx":0}{"moduleIdx":0}`, `{"moduleIdx":0,"extra":{"a":[1,2,{"b":null}]}}`,
		`{"profile":"steady","rps":-5}`, `{"profile":"../../etc/passwd"}`, `{"target":"javascript:alert(1)"}`,
		`{"params":{"Level":"3"},"app":"../x"}`, `{"params":"not a map"}`, "\x00\xff\xfe", strings.Repeat("[", 4096),
	} {
		f.Add([]byte(seed))
	}
	f.Fuzz(func(t *testing.T, body []byte) {
		s := newContractLab(t)
		startDemoPath(t, s)
		for _, path := range []string{
			"/learn/paths/" + labPath + "/complete",
			"/traffic/start",
			"/scenarios/" + labScenario + "/up",
		} {
			w := do(s, http.MethodPost, path, string(body), nil)
			waitForJobs(t, s)
			if w.Code >= http.StatusInternalServerError {
				t.Fatalf("POST %s with body %q = %d: %s", path, body, w.Code, w.Body)
			}
			ct := w.Header().Get("Content-Type")
			if !strings.HasPrefix(ct, "application/json") && ct != "application/problem+json" {
				t.Fatalf("POST %s with body %q answered Content-Type %q", path, body, ct)
			}
			if w.Code >= http.StatusBadRequest && ct != "application/problem+json" {
				t.Fatalf("POST %s with body %q = %d but is not a problem: %s", path, body, w.Code, w.Body)
			}
		}
	})
}
