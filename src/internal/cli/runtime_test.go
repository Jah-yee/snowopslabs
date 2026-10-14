// SPDX-License-Identifier: Apache-2.0

package cli

import (
	"strings"
	"testing"
)

func TestRuntime_Journey(t *testing.T) {
	l := newTerminal(t)
	l.Write(t, "runtimes/k3d/up.sh", "#!/usr/bin/env bash\nset -eu\necho \"creating cluster $1 with $LAB_CPUS CPUs and ${LAB_MEMORY}G\"\n")
	up := l.mustRun("runtime", "up")
	if !strings.Contains(up.stdout, "creating cluster clitest with 2 CPUs and 4G") {
		t.Errorf("up did not pass the cluster name and size to the runtime script:\n%s", up.stdout)
	}
	status := l.mustRun("runtime", "status")
	if !strings.Contains(status.stdout, "Kubernetes control plane is running") {
		t.Errorf("status does not show the cluster info:\n%s", status.stdout)
	}
	down := l.mustRun("runtime", "down")
	l.golden("runtime_journey", up, status, down)
}

func TestRuntime_Failures(t *testing.T) {
	tests := []struct {
		name    string
		prepare func(t *testing.T, l *terminal)
		args    []string
		wantErr string
	}{
		{"up when the runtime script fails",
			func(t *testing.T, l *terminal) {
				l.Write(t, "runtimes/k3d/up.sh", "#!/usr/bin/env bash\necho 'docker is not running' >&2\nexit 2\n")
			},
			[]string{"runtime", "up"}, "docker is not running"},
		{"down when the runtime script fails",
			func(t *testing.T, l *terminal) { l.Write(t, "runtimes/k3d/down.sh", "#!/usr/bin/env bash\nexit 2\n") },
			[]string{"runtime", "down"}, "exit status 2"},
		{"status when the cluster does not answer",
			func(_ *testing.T, l *terminal) { l.clusterDown() },
			[]string{"runtime", "status"}, "was refused"},
		{"a profile with no runtime",
			func(t *testing.T, l *terminal) { l.Write(t, ".env", "PROFILE=ghost\n") },
			[]string{"runtime", "up"}, `runtime profile "ghost" not found in runtimes/; available profiles: k3d`},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			l := newTerminal(t)
			tt.prepare(t, l)
			r := l.run(tt.args...)
			if r.exitCode() != 1 || !strings.Contains(r.stderr, tt.wantErr) {
				t.Errorf("exit %d, stderr %q; want exit 1 saying %q", r.exitCode(), r.stderr, tt.wantErr)
			}
		})
	}
}
