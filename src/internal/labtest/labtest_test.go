// SPDX-License-Identifier: Apache-2.0

package labtest

import (
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"testing"
)

func TestNew_BuildsAnIsolatedLab(t *testing.T) {
	t.Setenv("CLUSTER_NAME", "the-developers-own-cluster")
	l := New(t)

	for _, rel := range []string{
		"apps/" + App + "/app.env",
		"scenarios/" + Scenario + "/scenario.yaml",
		"incidents/" + Fault + "/fault.yaml",
		"learn/" + Path + "/path.yaml",
		"challenges/" + Challenge + "/challenge.yaml",
		"src/services/" + Service + "/install.sh",
		"runtimes/" + Runtime + "/up.sh",
	} {
		if _, err := os.Stat(filepath.Join(l.Root, rel)); err != nil {
			t.Errorf("the lab has no %s: %v", rel, err)
		}
	}
	info, err := os.Stat(filepath.Join(l.Root, "incidents", Fault, "inject.sh"))
	if err != nil || info.Mode()&0o111 == 0 {
		t.Errorf("inject.sh is not executable in the copy: %v, %v", info, err)
	}

	if got := os.Getenv("CLUSTER_NAME"); got != "" {
		t.Errorf("CLUSTER_NAME = %q leaked from the caller's environment", got)
	}
	if got := os.Getenv("SNOWOPS_HOME"); got != l.Home {
		t.Errorf("SNOWOPS_HOME = %q, want the lab's own %q", got, l.Home)
	}
	for _, tool := range []string{"kubectl", "helm", "docker", "k3d"} {
		path, err := exec.LookPath(tool)
		if err != nil || filepath.Dir(path) != l.Bin {
			t.Errorf("%s resolves to %q (%v), want the stand-in in %s", tool, path, err, l.Bin)
		}
	}
}

func TestLab_StandInToolsAnswerAndAreRecorded(t *testing.T) {
	l := New(t)
	if calls := l.Calls(t); calls != nil {
		t.Fatalf("calls before any tool ran = %v", calls)
	}

	out, err := exec.CommandContext(t.Context(), "kubectl", "config", "current-context").Output()
	if err != nil || strings.TrimSpace(string(out)) != "k3d-contract" {
		t.Errorf("kubectl config current-context = %q, %v", out, err)
	}
	if err := exec.CommandContext(t.Context(), "kubectl", "get", "namespace", "ghost", "--no-headers").Run(); err == nil {
		t.Error("a namespace the lab does not have was reported as present")
	}
	if err := exec.CommandContext(t.Context(), "helm", "upgrade", "--install", "x").Run(); err != nil {
		t.Errorf("helm: %v", err)
	}

	want := []string{"kubectl config current-context", "kubectl get namespace ghost --no-headers", "helm upgrade --install x"}
	if got := l.Calls(t); !slices.Equal(got, want) {
		t.Errorf("Calls() = %q, want %q", got, want)
	}
}

func TestLab_StubAndWrite(t *testing.T) {
	l := New(t)
	l.Stub(t, "kubectl", "#!/bin/sh\necho unreachable >&2\nexit 1\n")
	if err := exec.CommandContext(t.Context(), "kubectl", "get", "nodes").Run(); err == nil {
		t.Error("the replaced kubectl still succeeds")
	}

	l.Write(t, "scenarios/extra/setup.sh", "#!/bin/sh\necho hi\n")
	l.Write(t, "scenarios/extra/scenario.yaml", "name: extra\n")
	for rel, wantExec := range map[string]bool{"scenarios/extra/setup.sh": true, "scenarios/extra/scenario.yaml": false} {
		info, err := os.Stat(filepath.Join(l.Root, rel))
		if err != nil {
			t.Fatalf("%s: %v", rel, err)
		}
		if isExec := info.Mode()&0o111 != 0; isExec != wantExec {
			t.Errorf("%s executable = %v, want %v", rel, isExec, wantExec)
		}
	}
}
