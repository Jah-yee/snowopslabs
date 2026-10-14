// SPDX-License-Identifier: Apache-2.0

// Package labtest gives a test a complete, tiny lab. The project root is a
// copy of src/test/fixtures/lab, and kubectl, helm, docker and k3d are the
// scripts in src/test/fixtures/bin, which answer as a healthy cluster. A test
// built on it never reaches a real cluster, the network or the developer's
// own lab state.
package labtest

import (
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

// The one of everything the fixture lab holds.
const (
	App       = "demo-app"
	Scenario  = "demo-scenario"
	Fault     = "demo-fault"
	Path      = "demo-path"
	Challenge = "demo-challenge"
	Service   = "pager"
	Runtime   = "k3d"
)

// isolatedEnv are the variables that would let the developer's shell or lab
// change what a command under test does. New clears each of them.
var isolatedEnv = []string{
	"SNOWOPS_LAB_DIR", "KUBECONFIG", "PROFILE", "CLUSTER_NAME", "APP_NAME",
	"DOMAIN_SUFFIX", "HTTP_PORT", "HTTPS_PORT", "LAB_CPUS", "LAB_MEMORY", "AGENTS",
	"INGRESS_CLASS", "STORAGE_CLASS", "REGISTRY_TYPE", "MONITORING_NAMESPACE",
	"INGRESS_PROVIDER", "METRICS_PROVIDER", "LOGGING_PROVIDER", "TRACING_PROVIDER",
	"GITOPS_PROVIDER", "CHAOS_PROVIDER", "POLICY_PROVIDER", "SECRETS_PROVIDER",
	"MESH_PROVIDER", "DATA_PROVIDER", "AUTOSCALING_PROVIDER", "COST_PROVIDER",
	"PROMETHEUS_URL", "ALERTMANAGER_URL", "GRAFANA_URL",
	"LABCTL_AUTH", "LABCTL_USERS_FILE", "LABCTL_ADDR", "LABCTL_PASSWORD",
}

// Lab is one test's private copy of the fixture lab.
type Lab struct {
	// Root is the project root: apps/, scenarios/, incidents/ and the rest.
	Root string
	// Bin holds the stand-in tools and is first on PATH.
	Bin string
	// Home is SNOWOPS_HOME: lab state, the run store and cluster records.
	Home string

	calls string
}

// New copies the fixture lab into temp directories and points the process
// environment at it for the length of the test: PATH is the stand-in tools
// plus the system directories, and HOME and SNOWOPS_HOME are empty temp
// directories.
func New(t testing.TB) *Lab {
	t.Helper()
	fixtures := fixturesDir(t)
	l := &Lab{Root: t.TempDir(), Bin: t.TempDir(), Home: t.TempDir()}
	l.calls = filepath.Join(t.TempDir(), "calls.log")
	for src, dst := range map[string]string{"lab": l.Root, "bin": l.Bin} {
		if err := os.CopyFS(dst, os.DirFS(filepath.Join(fixtures, src))); err != nil {
			t.Fatalf("copying the fixture %s: %v", src, err)
		}
	}

	for _, k := range isolatedEnv {
		t.Setenv(k, "")
	}
	t.Setenv("PATH", strings.Join([]string{l.Bin, "/usr/bin", "/bin"}, string(os.PathListSeparator)))
	t.Setenv("HOME", t.TempDir())
	t.Setenv("SNOWOPS_HOME", l.Home)
	t.Setenv("STUB_LOG", l.calls)
	return l
}

// fixturesDir is src/test/fixtures, found from this file so it works from any
// package's test.
func fixturesDir(t testing.TB) string {
	t.Helper()
	_, file, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("cannot locate the labtest package to find the fixture lab")
	}
	return filepath.Join(filepath.Dir(file), "..", "..", "test", "fixtures")
}

// Write puts content at a path under the project root, creating its
// directories. A path ending in .sh is written executable.
func (l *Lab) Write(t testing.TB, rel, content string) {
	t.Helper()
	writeFile(t, filepath.Join(l.Root, rel), content, filepath.Ext(rel) == ".sh")
}

// Stub replaces a stand-in tool with script, for a test that needs the
// cluster to answer differently.
func (l *Lab) Stub(t testing.TB, tool, script string) {
	t.Helper()
	writeFile(t, filepath.Join(l.Bin, tool), script, true)
}

func writeFile(t testing.TB, path, content string, executable bool) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil { //nolint:gosec // a test fixture directory
		t.Fatal(err)
	}
	mode := os.FileMode(0o644)
	if executable {
		mode = 0o755
	}
	if err := os.WriteFile(path, []byte(content), mode); err != nil { //nolint:gosec // a test fixture; scripts must be executable
		t.Fatal(err)
	}
}

// Calls returns every call made to a stand-in tool so far, one per entry, as
// "<tool> <arguments>".
func (l *Lab) Calls(t testing.TB) []string {
	t.Helper()
	data, err := os.ReadFile(l.calls)
	if errors.Is(err, fs.ErrNotExist) {
		return nil
	}
	if err != nil {
		t.Fatal(err)
	}
	var calls []string
	for line := range strings.Lines(string(data)) {
		calls = append(calls, strings.Replace(strings.TrimRight(line, "\n"), "\t", " ", 1))
	}
	return calls
}
