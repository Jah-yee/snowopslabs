#!/usr/bin/env bats
# SPDX-License-Identifier: Apache-2.0
#
# How bootstrap/setup-tools.sh installs kubectl, helm, k3d and kind: through
# Homebrew on macOS, and as a pinned download into ~/.local/bin (never sudo) on
# Linux and WSL. A tool at or above its minimum is never replaced.

load 'helpers/stub'

setup() {
  stub_setup
  # Run on WSL, the real WSL_DISTRO_NAME would turn every Linux test into a WSL
  # one; the WSL tests set it themselves.
  unset WSL_DISTRO_NAME
  ROOT="$(project_root)"
  export HOME="$STUB_DIR/home"
  mkdir -p "$HOME"
  CALLS="$STUB_DIR/tool-calls"
  export CALLS

  # A fake binary that reports a version the way the real one does.
  cat >"$STUB_DIR/make-tool" <<'EOF'
#!/usr/bin/env bash
# make-tool <path> <name> <version>
case "$2" in
  kubectl) body="echo 'Client Version: v$3'" ;;
  helm) body="echo 'v$3+gabc'" ;;
  k3d) body="echo 'k3d version v$3'" ;;
  kind) body="echo 'kind v$3 go1.22'" ;;
esac
printf '#!/usr/bin/env bash\n%s\n' "$body" >"$1"
chmod +x "$1"
EOF
  chmod +x "$STUB_DIR/make-tool"

  # curl -fsSLo <out> <url>: "downloads" the pinned version of the tool.
  cat >"$STUB_BIN/curl" <<'EOF'
#!/usr/bin/env bash
echo "curl $*" >>"$CALLS"
out="$2"; url="$3"
case "$url" in
  *kubectl) "$STUB_DIR/make-tool" "$out" kubectl 1.36.1 ;;
  *k3d-*) "$STUB_DIR/make-tool" "$out" k3d 5.8.3 ;;
  *kind-*) "$STUB_DIR/make-tool" "$out" kind 0.27.0 ;;
esac
EOF
  # brew install/upgrade <formula>: puts a current tool on PATH.
  cat >"$STUB_BIN/brew" <<'EOF'
#!/usr/bin/env bash
echo "brew $*" >>"$CALLS"
case "$1" in
  list) [ -n "${BREW_HAS:-}" ] && [ "$3" = "$BREW_HAS" ] ;;
  install|upgrade)
    [ -n "${BREW_NOOP:-}" ] && exit 0
    case "$2" in
      kubernetes-cli) "$STUB_DIR/make-tool" "$STUB_BIN/kubectl" kubectl 1.36.1 ;;
      helm) "$STUB_DIR/make-tool" "$STUB_BIN/helm" helm 4.2.3 ;;
    esac ;;
esac
EOF
  cat >"$STUB_BIN/sudo" <<'EOF'
#!/usr/bin/env bash
echo "sudo $*" >>"$CALLS"
EOF
  chmod +x "$STUB_BIN/curl" "$STUB_BIN/brew" "$STUB_BIN/sudo"
  export STUB_DIR
}

teardown() {
  stub_teardown
}

# base_path links the base system's commands into $STUB_DIR/base, leaving out
# the tools setup-tools manages. A machine that has them installed in /usr/bin,
# as CI runners do, would otherwise make a missing tool look installed.
base_path() {
  local dir="$STUB_DIR/base" f name
  [ -d "$dir" ] && return 0
  mkdir -p "$dir"
  for f in /usr/bin/* /bin/* /usr/sbin/* /sbin/*; do
    name="${f##*/}"
    case "$name" in kubectl | helm | k3d | kind | brew) continue ;; esac
    [ -e "$dir/$name" ] || ln -s "$f" "$dir/$name"
  done
}

# setup_tools runs one function from setup-tools.sh with a given OS.
setup_tools() {
  local os="$1"
  shift
  # Only the stubs and the base system: no real kubectl/helm/brew leaks in.
  base_path
  PATH="$STUB_BIN:$STUB_DIR/base"
  cat >"$STUB_BIN/uname" <<EOF
#!/usr/bin/env bash
case "\$1" in -m) echo arm64 ;; *) echo $os ;; esac
EOF
  chmod +x "$STUB_BIN/uname"
  # Everything but the final `main "$@"` line, still resolving its sibling
  # files from the real bootstrap/ directory.
  sed -e '$d' -e "s#^SCRIPT_DIR=.*#SCRIPT_DIR=$ROOT/bootstrap#" \
    "$ROOT/bootstrap/setup-tools.sh" >"$STUB_DIR/lib.sh"
  # shellcheck disable=SC1091
  . "$STUB_DIR/lib.sh"
  "$@"
}

@test "linux: a missing tool is downloaded into ~/.local/bin without sudo" {
  run setup_tools Linux ensure_tool kubectl
  [ "$status" -eq 0 ]
  [ -x "$HOME/.local/bin/kubectl" ]
  grep -q "dl.k8s.io/release/v1.36.1/bin/linux/arm64/kubectl" "$CALLS"
  ! grep -q "^sudo" "$CALLS"
}

@test "linux: a new-enough tool is left alone" {
  "$STUB_DIR/make-tool" "$STUB_BIN/kubectl" kubectl 1.30.2
  run setup_tools Linux ensure_tool kubectl
  [ "$status" -eq 0 ]
  [[ "$output" == *"kubectl v1.30.2 is installed"* ]] || false
  [ ! -e "$CALLS" ] || ! grep -q curl "$CALLS"
}

@test "linux: an older tool is replaced by the pinned download" {
  "$STUB_DIR/make-tool" "$STUB_BIN/k3d" k3d 5.4.0
  run setup_tools Linux ensure_tool k3d
  [ "$status" -eq 0 ]
  grep -q "k3d/releases/download/v5.8.3/k3d-linux-arm64" "$CALLS"
}

@test "macOS: kubectl comes from Homebrew's kubernetes-cli formula" {
  run setup_tools Darwin ensure_tool kubectl
  [ "$status" -eq 0 ]
  grep -q "brew install kubernetes-cli" "$CALLS"
  ! grep -q "curl" "$CALLS"
}

@test "macOS: an old brew-installed tool is upgraded, not reinstalled" {
  "$STUB_DIR/make-tool" "$STUB_BIN/helm" helm 3.9.0
  BREW_HAS=helm run setup_tools Darwin ensure_tool helm
  [ "$status" -eq 0 ]
  grep -q "brew upgrade helm" "$CALLS"
}

@test "a copy that stays too old after installing is reported, not ignored" {
  "$STUB_DIR/make-tool" "$STUB_BIN/helm" helm 3.9.0
  BREW_NOOP=1 run setup_tools Darwin ensure_tool helm
  [ "$status" -eq 1 ]
  [[ "$output" == *"older than v3.12.0"* ]] || false
}

@test "WSL: Docker Desktop's shim without integration stops with the fix, no second install" {
  cat >"$STUB_BIN/docker" <<'EOF'
#!/usr/bin/env bash
echo "The command 'docker' could not be found in this WSL 2 distro." >&2
exit 1
EOF
  chmod +x "$STUB_BIN/docker"
  WSL_DISTRO_NAME=Ubuntu run setup_tools Linux install_docker_linux
  [ "$status" -eq 1 ]
  [[ "$output" == *"WSL Integration"* ]] || false
  ! grep -q "apt-get" "$CALLS" 2>/dev/null
}

@test "WSL: a stopped Docker Desktop is named, and no second engine is installed" {
  export WINDOWS_PROGRAM_FILES="$STUB_DIR/pf"
  mkdir -p "$WINDOWS_PROGRAM_FILES/Docker/Docker"
  touch "$WINDOWS_PROGRAM_FILES/Docker/Docker/Docker Desktop.exe"
  # No daemon answers, whatever docker the machine running the test has.
  cat >"$STUB_BIN/docker" <<'EOF'
#!/usr/bin/env bash
echo "Cannot connect to the Docker daemon at unix:///var/run/docker.sock." >&2
exit 1
EOF
  chmod +x "$STUB_BIN/docker"
  # While Docker Desktop is stopped its docker shim is gone from the distro.
  without_docker_cli() {
    docker_cli_missing() { return 0; }
    "$@"
  }
  WSL_DISTRO_NAME=Ubuntu run setup_tools Linux without_docker_cli install_docker_linux
  [ "$status" -eq 1 ]
  [[ "$output" == *"Docker Desktop is installed on Windows but not running"* ]] || false
  [[ "$output" == *"SNOWOPS_NATIVE_DOCKER=1 labctl init"* ]] || false
  ! grep -q "sudo" "$CALLS" 2>/dev/null
}

@test "WSL: SNOWOPS_NATIVE_DOCKER=1 installs Docker Engine beside a stopped Docker Desktop" {
  export WINDOWS_PROGRAM_FILES="$STUB_DIR/pf"
  mkdir -p "$WINDOWS_PROGRAM_FILES/Docker/Docker"
  touch "$WINDOWS_PROGRAM_FILES/Docker/Docker/Docker Desktop.exe"
  printf '#!/usr/bin/env bash\nexit 1\n' >"$STUB_BIN/docker"
  chmod +x "$STUB_BIN/docker"
  # No docker CLI, and a distro whose install is a single recorded command.
  native_engine() {
    docker_cli_missing() { return 0; }
    _linux_distro() { echo alpine; }
    "$@"
  }
  SNOWOPS_NATIVE_DOCKER=1 WSL_DISTRO_NAME=Ubuntu run setup_tools Linux native_engine install_docker_linux
  [[ "$output" != *"is installed on Windows but not running"* ]] || false
  grep -q "sudo apk add --no-cache docker" "$CALLS"
}

@test "linux: a stale docker-group session is explained, not waited on" {
  cat >"$STUB_BIN/docker" <<'EOF'
#!/usr/bin/env bash
echo "permission denied while trying to connect to the Docker daemon socket" >&2
exit 1
EOF
  chmod +x "$STUB_BIN/docker"
  run setup_tools Linux install_docker_linux
  [ "$status" -eq 1 ]
  [[ "$output" == *"log out and back in"* ]] || false
}
