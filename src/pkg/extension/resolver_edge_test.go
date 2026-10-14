// SPDX-License-Identifier: Apache-2.0

package extension

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestDefaultResolver_ChainComposition verifies that DefaultResolver returns a
// chain handling both supported ref schemes, and rejects an unsupported one.
func TestDefaultResolver_ChainComposition(t *testing.T) {
	src := t.TempDir()
	chain := DefaultResolver()

	tests := []struct {
		name string
		ref  string
		want bool
	}{
		{"local dir", src, true},
		{"git https url", "https://github.com/example/content", true},
		{"git+ prefixed url", "git+https://github.com/example/content@v1", true},
		{"oci ref is no longer supported", "oci://ghcr.io/example/pack:v1", false},
		{"nonexistent local path", filepath.Join(src, "missing"), false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := chain.CanResolve(tt.ref); got != tt.want {
				t.Errorf("CanResolve(%q) = %v, want %v", tt.ref, got, tt.want)
			}
		})
	}
}

// TestSplitGitRef covers the URL / @ref splitting logic.
func TestSplitGitRef(t *testing.T) {
	tests := []struct {
		src string
		url string
		ref string
	}{
		{"https://github.com/x/y@v1.0", "https://github.com/x/y", "v1.0"},
		{"https://github.com/x/y", "https://github.com/x/y", ""},
		// scp-like: the @ is part of the host, not a ref separator
		{"git@github.com:x/y.git", "git@github.com:x/y.git", ""},
	}
	for _, tt := range tests {
		u, r := splitGitRef(tt.src)
		if u != tt.url || r != tt.ref {
			t.Errorf("splitGitRef(%q) = (%q, %q), want (%q, %q)", tt.src, u, r, tt.url, tt.ref)
		}
	}
}

// TestLocalResolver_FilePrefix verifies that file:// refs are accepted.
func TestLocalResolver_FilePrefix(t *testing.T) {
	dir := t.TempDir()
	r := LocalResolver{}
	if !r.CanResolve("file://" + dir) {
		t.Error("LocalResolver should CanResolve file:// refs")
	}
}

// TestLocalResolver_NonexistentDir verifies that a path that does not exist
// is not claimed by LocalResolver.
func TestLocalResolver_NonexistentDir(t *testing.T) {
	r := LocalResolver{}
	if r.CanResolve("/totally/nonexistent/path/xyz") {
		t.Error("LocalResolver should not CanResolve a path that does not exist")
	}
}

// TestGitResolver_ErrorPropagation verifies that Resolve wraps runner errors.
func TestGitResolver_ErrorPropagation(t *testing.T) {
	r := GitResolver{Run: func(ctx context.Context, dir string, args ...string) error {
		return errors.New("network timeout")
	}}
	err := r.Resolve(context.Background(), "https://github.com/x/y", t.TempDir())
	if err == nil {
		t.Fatal("expected error from failed git runner, got nil")
	}
	if !strings.Contains(err.Error(), "cloning") {
		t.Errorf("error should mention 'cloning': %v", err)
	}
}

// TestCopyTree_CopiesFiles verifies that copyTree copies files and directories
// recursively.
func TestCopyTree_CopiesFiles(t *testing.T) {
	src := t.TempDir()
	dst := filepath.Join(t.TempDir(), "out")

	// Create source structure.
	os.MkdirAll(filepath.Join(src, "sub"), 0755)
	os.WriteFile(filepath.Join(src, "root.txt"), []byte("root"), 0644)
	os.WriteFile(filepath.Join(src, "sub", "nested.txt"), []byte("nested"), 0644)

	if err := copyTree(src, dst); err != nil {
		t.Fatalf("copyTree: %v", err)
	}

	// Verify copied files exist.
	for _, rel := range []string{"root.txt", filepath.Join("sub", "nested.txt")} {
		if _, err := os.Stat(filepath.Join(dst, rel)); err != nil {
			t.Errorf("expected %s to exist in dst: %v", rel, err)
		}
	}
}

// stubGit puts a fake git first on PATH. script is the body of a POSIX shell
// script that sees git's arguments as "$*".
func stubGit(t *testing.T, script string) {
	t.Helper()
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "git"), []byte("#!/bin/sh\n"+script), 0o755); err != nil { //nolint:gosec // a test stub must be executable
		t.Fatal(err)
	}
	t.Setenv("PATH", dir+string(os.PathListSeparator)+"/usr/bin:/bin")
}

func TestDefaultGitRunner(t *testing.T) {
	t.Run("runs git with the arguments in the directory given", func(t *testing.T) {
		work := t.TempDir()
		stubGit(t, "printf '%s\\n' \"$*\" >ran.txt\n")
		if err := DefaultGitRunner(t.Context(), work, "clone", "--depth", "1", "https://example.test/pack.git", "dest"); err != nil {
			t.Fatalf("DefaultGitRunner() error = %v", err)
		}
		got, err := os.ReadFile(filepath.Join(work, "ran.txt"))
		if err != nil {
			t.Fatalf("git did not run in the directory given: %v", err)
		}
		if want := "clone --depth 1 https://example.test/pack.git dest\n"; string(got) != want {
			t.Errorf("git ran with %q, want %q", got, want)
		}
	})
	t.Run("a failing git names the command that failed", func(t *testing.T) {
		stubGit(t, "echo 'fatal: repository not found' >&2\nexit 128\n")
		err := DefaultGitRunner(t.Context(), t.TempDir(), "clone", "https://example.test/ghost.git")
		if err == nil || !strings.Contains(err.Error(), "git clone https://example.test/ghost.git") {
			t.Errorf("DefaultGitRunner() error = %v, want it to name the git command", err)
		}
	})
	t.Run("git is not installed", func(t *testing.T) {
		t.Setenv("PATH", t.TempDir())
		err := DefaultGitRunner(t.Context(), t.TempDir(), "version")
		if err == nil || !strings.Contains(err.Error(), "git not found on PATH") {
			t.Errorf("DefaultGitRunner() error = %v, want git not found on PATH", err)
		}
	})
	t.Run("a cancelled context stops git", func(t *testing.T) {
		stubGit(t, "exec sleep 30\n")
		ctx, cancel := context.WithCancel(t.Context())
		cancel()
		if err := DefaultGitRunner(ctx, t.TempDir(), "clone", "x"); err == nil {
			t.Error("DefaultGitRunner() on a cancelled context returned no error")
		}
	})
}

// With no runner set, the resolver clones with the real git and drops the
// clone's .git directory, leaving a plain content snapshot.
func TestGitResolver_DefaultRunnerLeavesNoGitDir(t *testing.T) {
	stubGit(t, `for last; do :; done
mkdir -p "$last/.git" "$last/scenarios/demo"
echo ref >"$last/.git/HEAD"
echo "name: demo" >"$last/scenarios/demo/scenario.yaml"
`)
	dest := filepath.Join(t.TempDir(), "pack")
	if err := (GitResolver{}).Resolve(t.Context(), "git+https://example.test/pack.git@v1", dest); err != nil {
		t.Fatalf("Resolve() error = %v", err)
	}
	if _, err := os.Stat(filepath.Join(dest, ".git")); err == nil {
		t.Error("the resolved pack still has its .git directory")
	}
	if _, err := os.Stat(filepath.Join(dest, "scenarios", "demo", "scenario.yaml")); err != nil {
		t.Errorf("the resolved pack lost its content: %v", err)
	}
}

func TestCopyTree(t *testing.T) {
	t.Run("copies nested files with their modes, and empty directories", func(t *testing.T) {
		src, dst := t.TempDir(), filepath.Join(t.TempDir(), "out")
		mustWrite := func(rel, content string, mode os.FileMode) {
			t.Helper()
			path := filepath.Join(src, rel)
			if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(path, []byte(content), mode); err != nil {
				t.Fatal(err)
			}
		}
		mustWrite("scenarios/demo/scenario.yaml", "name: demo\n", 0o644)
		mustWrite("scenarios/demo/checks/ok.sh", "#!/bin/sh\n", 0o755)
		if err := os.MkdirAll(filepath.Join(src, "empty"), 0o755); err != nil {
			t.Fatal(err)
		}

		if err := copyTree(src, dst); err != nil {
			t.Fatalf("copyTree() error = %v", err)
		}
		got, err := os.ReadFile(filepath.Join(dst, "scenarios", "demo", "scenario.yaml"))
		if err != nil || string(got) != "name: demo\n" {
			t.Errorf("copied file = %q, %v", got, err)
		}
		info, err := os.Stat(filepath.Join(dst, "scenarios", "demo", "checks", "ok.sh"))
		if err != nil || info.Mode().Perm()&0o100 == 0 {
			t.Errorf("the copied script lost its executable bit: %v, %v", info, err)
		}
		if info, err := os.Stat(filepath.Join(dst, "empty")); err != nil || !info.IsDir() {
			t.Errorf("the empty directory was not copied: %v", err)
		}
	})
	t.Run("overwrites a file already at the destination", func(t *testing.T) {
		src, dst := t.TempDir(), t.TempDir()
		if err := os.WriteFile(filepath.Join(src, "f"), []byte("new"), 0o644); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(dst, "f"), []byte("old and longer"), 0o644); err != nil {
			t.Fatal(err)
		}
		if err := copyTree(src, dst); err != nil {
			t.Fatal(err)
		}
		if got, _ := os.ReadFile(filepath.Join(dst, "f")); string(got) != "new" {
			t.Errorf("destination = %q, want it replaced by %q", got, "new")
		}
	})

	failures := []struct {
		name    string
		prepare func(t *testing.T, src, dst string)
	}{
		{"the source does not exist", func(t *testing.T, src, _ string) {
			if err := os.RemoveAll(src); err != nil {
				t.Fatal(err)
			}
		}},
		{"a source file cannot be read", func(t *testing.T, src, _ string) {
			if err := os.Chmod(filepath.Join(src, "f"), 0o000); err != nil {
				t.Fatal(err)
			}
		}},
		{"the destination cannot be written", func(t *testing.T, _, dst string) {
			if err := os.Chmod(dst, 0o500); err != nil {
				t.Fatal(err)
			}
			t.Cleanup(func() { _ = os.Chmod(dst, 0o700) }) //nolint:gosec // restore so the temp dir can be removed
		}},
		{"a file is where a directory must go", func(t *testing.T, src, dst string) {
			if err := os.MkdirAll(filepath.Join(src, "sub"), 0o755); err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(filepath.Join(src, "sub", "g"), []byte("x"), 0o644); err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(filepath.Join(dst, "sub"), []byte("in the way"), 0o644); err != nil {
				t.Fatal(err)
			}
		}},
	}
	for _, tt := range failures {
		t.Run(tt.name, func(t *testing.T) {
			if os.Geteuid() == 0 {
				t.Skip("file permissions do not stop root")
			}
			src, dst := t.TempDir(), t.TempDir()
			if err := os.WriteFile(filepath.Join(src, "f"), []byte("x"), 0o644); err != nil {
				t.Fatal(err)
			}
			tt.prepare(t, src, dst)
			if err := copyTree(src, dst); err == nil {
				t.Error("copyTree() returned no error")
			}
		})
	}
}
