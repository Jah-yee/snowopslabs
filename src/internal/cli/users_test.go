// SPDX-License-Identifier: Apache-2.0

package cli

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestUsers_Journey(t *testing.T) {
	l := newTerminal(t)
	var steps []cliResult
	step := func(args ...string) cliResult {
		t.Helper()
		r := l.mustRun(args...)
		steps = append(steps, r)
		return r
	}

	step("users", "list")
	step("users", "add", "olive", "--role", "operator", "--password", "s3cret-pass")
	l.stdin = "typed-pass\n"
	step("users", "add", "pat", "--role", "participant")
	if r := step("users", "list"); !strings.Contains(r.stdout, "olive   operator") || !strings.Contains(r.stdout, "pat     participant") {
		t.Errorf("list does not show both users with their roles:\n%s", r.stdout)
	}
	if r := step("users", "add", "pat", "--role", "operator", "--password", "another-pass"); !strings.Contains(r.stdout, `User "pat" updated (role: operator)`) {
		t.Errorf("adding an existing user does not report an update:\n%s", r.stdout)
	}
	step("users", "remove", "olive")
	step("users", "list")
	l.golden("users_journey", steps...)

	// The file holds hashes; no password a user typed is ever written.
	data, err := os.ReadFile(filepath.Join(l.Home, "state", "clitest", "users.yaml"))
	if err != nil {
		t.Fatal(err)
	}
	for _, secret := range []string{"s3cret-pass", "typed-pass", "another-pass"} {
		if strings.Contains(string(data), secret) {
			t.Errorf("the users file stores the password %q in plain text", secret)
		}
	}
	for _, r := range steps {
		if strings.Contains(r.stdout+r.stderr, "pbkdf2") || strings.Contains(r.stdout, "s3cret-pass") {
			t.Errorf("`labctl %s` prints a password or its hash:\n%s", strings.Join(r.args, " "), r.stdout)
		}
	}
}

func TestUsers_PasswordFromTheEnvironment(t *testing.T) {
	l := newTerminal(t)
	t.Setenv("LABCTL_PASSWORD", "from-the-env")
	if r := l.mustRun("users", "add", "olive", "--role", "operator"); strings.Contains(r.stdout, "Password:") {
		t.Errorf("the password was prompted for although LABCTL_PASSWORD was set:\n%s", r.stdout)
	}
}

func TestUsers_Failures(t *testing.T) {
	tests := []struct {
		name    string
		stdin   string
		args    []string
		wantErr string
	}{
		{"a role that does not exist", "", []string{"users", "add", "olive", "--role", "admin", "--password", "x"}, `invalid role "admin" (want operator or participant)`},
		{"no password anywhere", "", []string{"users", "add", "olive", "--role", "operator"}, "no password provided"},
		{"an empty password typed", "\n", []string{"users", "add", "olive", "--role", "operator"}, "password must not be empty"},
		{"remove a user that does not exist", "", []string{"users", "remove", "ghost"}, `user "ghost" not found`},
		{"list takes no arguments", "", []string{"users", "list", "extra"}, "unknown command"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			l := newTerminal(t)
			l.stdin = tt.stdin
			r := l.run(tt.args...)
			if r.exitCode() != 1 || !strings.Contains(r.stderr, tt.wantErr) {
				t.Errorf("exit %d, stderr %q; want exit 1 saying %q", r.exitCode(), r.stderr, tt.wantErr)
			}
			if list := l.mustRun("users", "list"); !strings.Contains(list.stdout, "No users defined") {
				t.Errorf("a refused command changed the users file:\n%s", list.stdout)
			}
		})
	}
}
