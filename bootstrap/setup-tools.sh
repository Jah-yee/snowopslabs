#!/usr/bin/env bash
set -euo pipefail

# Detect host OS and architecture once; all download URLs use these.
OS="$(uname -s | tr '[:upper:]' '[:lower:]')" # linux | darwin
ARCH="$(uname -m)"
case "$ARCH" in
  x86_64 | amd64) ARCH=amd64 ;;
  arm64 | aarch64) ARCH=arm64 ;;
  *)
    echo "ERROR: unsupported architecture: $ARCH" >&2
    exit 1
    ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION_FILE="${SCRIPT_DIR}/../config/versions.env"
# shellcheck source=../runtimes/_lib/docker.sh
. "${SCRIPT_DIR}/../runtimes/_lib/docker.sh"

if [ ! -f "$VERSION_FILE" ]; then
  echo "Error: versions.env not found at $VERSION_FILE" >&2
  exit 1
fi

# shellcheck source=/dev/null
source "$VERSION_FILE"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Where downloaded tools go on Linux and WSL: user-owned, so no sudo. labctl
# adds it to its own PATH, so tools work before the user's shell picks it up.
# macOS installs through Homebrew instead.
INSTALL_DIR="${SNOWOPS_BIN_DIR:-$HOME/.local/bin}"
# The user's own PATH, before labctl or this script extended it; used to tell
# them when INSTALL_DIR is missing from it.
ORIGINAL_PATH="${SNOWOPS_ORIGINAL_PATH:-$PATH}"
case ":$PATH:" in
  *":$INSTALL_DIR:"*) ;;
  *) PATH="$INSTALL_DIR:$PATH" ;;
esac

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# is_wsl - succeeds when running under the Windows Subsystem for Linux.
#
# Kept pure (reads only WSL_DISTRO_NAME and the two kernel files) so it can be
# sourced and exercised in isolation by bats. WSL only exists on Linux; the
# WSL_DISTRO_NAME env var is set by WSL2, and both WSL1/WSL2 kernels carry
# "microsoft" (or "wsl") in /proc/version and /proc/sys/kernel/osrelease.
is_wsl() {
  [ "$OS" = "linux" ] || return 1
  [ -n "${WSL_DISTRO_NAME:-}" ] && return 0
  local f
  for f in /proc/sys/kernel/osrelease /proc/version; do
    if [ -r "$f" ] && grep -qiE 'microsoft|wsl' "$f" 2>/dev/null; then
      return 0
    fi
  done
  return 1
}

# maybe_wsl_notice - when on WSL, say that the dashboard and lab URLs open in
# the Windows browser. `labctl ui` opens it through wslview or, without wslu,
# powershell.exe, so nothing needs installing. Printed once at the end of
# setup; never fails the run.
maybe_wsl_notice() {
  is_wsl || return 0
  echo
  echo -e "${YELLOW}WSL detected.${NC} The dashboard and lab URLs (e.g. http://grafana.snowops.localhost)"
  echo "  open in your Windows browser. Run 'labctl doctor' for the full WSL checklist."
}

ensure_install_dir() {
  mkdir -p "$INSTALL_DIR"
}

# version_ge <have> <want> - succeeds when <have> >= <want> as a semver.
#
# The pinned versions in versions.env are MINIMUMS, not exact matches. A user
# who brought their own newer helm (via brew, apt, whatever) should not have
# their tool replaced by an older one - and on Apple Silicon that "replacement"
# would fail anyway because brew's /opt/homebrew/bin shadows /usr/local/bin.
#
# A leading 'v' is stripped from both sides, because tools disagree about it
# ('helm version --short' emits it, 'kubectl' does not) and sort -V would
# otherwise treat "v3.14.0" as textually greater than "4.2.3" - the leading 'v'
# sorts after any digit.
#
# Uses sort -V, which is portable across macOS and modern Linux.
version_ge() {
  [ -z "$1" ] && return 1
  [ -z "$2" ] && return 0
  local have="${1#v}" want="${2#v}"
  # If sorting the two versions numerically puts <want> first, then <have>
  # >= <want>. `printf '%s\n%s\n' | sort -V | head -1` returns the smaller.
  local smallest
  smallest="$(printf '%s\n%s\n' "$have" "$want" | sort -V | head -n 1)"
  [ "$smallest" = "$want" ]
}

# Block until Docker daemon responds or timeout.

# ---------------------------------------------------------------------------
# Tool installers
# ---------------------------------------------------------------------------

# tool_version <name> - the installed version without a leading "v", or "".
tool_version() {
  # A missing tool must read as "" rather than fail: under pipefail the failed
  # pipeline would otherwise abort the whole script.
  command -v "$1" >/dev/null 2>&1 || return 0
  case "$1" in
    kubectl) kubectl version --client 2>/dev/null | sed -n 's/^Client Version: v\{0,1\}//p' ;;
    helm) helm version --short 2>/dev/null | sed 's/^v\([^+]*\).*/\1/' ;;
    k3d) k3d version 2>/dev/null | sed -n 's/^k3d version v\([^ -]*\).*/\1/p' ;;
    kind) kind version 2>/dev/null | sed -n 's/^kind v\([^ ]*\).*/\1/p' ;;
  esac || true
}

# tool_min / tool_pin <name> - the lowest accepted version, and the version
# downloaded when the installed one is missing or older (config/versions.env).
tool_min() {
  case "$1" in
    kubectl) echo "$KUBECTL_MIN_VERSION" ;;
    helm) echo "$HELM_MIN_VERSION" ;;
    k3d) echo "$K3D_MIN_VERSION" ;;
    kind) echo "$KIND_MIN_VERSION" ;;
  esac
}
tool_pin() {
  case "$1" in
    kubectl) echo "$KUBECTL_VERSION" ;;
    helm) echo "$HELM_VERSION" ;;
    k3d) echo "$K3D_VERSION" ;;
    kind) echo "$KIND_VERSION" ;;
  esac
}

# download_tool <name> <version> - fetch a static binary into INSTALL_DIR.
download_tool() {
  local name="$1" v="$2" tmp
  tmp="$(mktemp -d)"
  case "$name" in
    kubectl) curl -fsSLo "$tmp/kubectl" "https://dl.k8s.io/release/v${v}/bin/${OS}/${ARCH}/kubectl" ;;
    k3d) curl -fsSLo "$tmp/k3d" "https://github.com/k3d-io/k3d/releases/download/v${v}/k3d-${OS}-${ARCH}" ;;
    kind) curl -fsSLo "$tmp/kind" "https://github.com/kubernetes-sigs/kind/releases/download/v${v}/kind-${OS}-${ARCH}" ;;
    helm)
      curl -fsSLo "$tmp/helm.tar.gz" "https://get.helm.sh/helm-v${v}-${OS}-${ARCH}.tar.gz"
      tar -xzf "$tmp/helm.tar.gz" -C "$tmp"
      mv "$tmp/${OS}-${ARCH}/helm" "$tmp/helm"
      ;;
  esac
  chmod +x "$tmp/$name"
  ensure_install_dir
  mv "$tmp/$name" "$INSTALL_DIR/$name"
  rm -rf "$tmp"
}

# ensure_tool <name> - leave a new-enough tool alone; otherwise install one
# (Homebrew on macOS, a pinned download into INSTALL_DIR elsewhere) and verify
# the one now on PATH is new enough.
ensure_tool() {
  local name="$1" min pin have
  min="$(tool_min "$name")"
  pin="$(tool_pin "$name")"
  echo -e "${YELLOW}Checking ${name} (minimum v${min})...${NC}"
  have="$(tool_version "$name")"
  if version_ge "$have" "$min"; then
    echo -e "${GREEN}${name} v${have} is installed${NC}"
    return 0
  fi
  if [ -n "$have" ]; then
    echo -e "${YELLOW}${name} v${have} is older than v${min} - installing a newer one${NC}"
  fi

  if [ "$OS" = "darwin" ]; then
    local formula="$name"
    [ "$name" = kubectl ] && formula=kubernetes-cli
    _install_homebrew
    if brew list --formula "$formula" >/dev/null 2>&1; then
      brew upgrade "$formula"
    else
      brew install "$formula"
    fi
  else
    echo "Downloading ${name} v${pin} for ${OS}/${ARCH} into ${INSTALL_DIR}..."
    download_tool "$name" "$pin"
  fi

  hash -r
  have="$(tool_version "$name")"
  if version_ge "$have" "$min"; then
    echo -e "${GREEN}${name} v${have} installed${NC}"
    return 0
  fi
  # Another, older copy earlier on PATH is shadowing the one just installed.
  echo -e "${RED}ERROR: the ${name} on PATH ($(command -v "$name")) is v${have:-unknown}, older than v${min}.${NC}" >&2
  echo -e "${YELLOW}  Remove or upgrade that copy, or put ${INSTALL_DIR} earlier on PATH, then re-run.${NC}" >&2
  exit 1
}

# user_bin_notice - tell the user to add INSTALL_DIR to their shell's PATH when
# a tool landed there, so kubectl works in their own terminal too.
user_bin_notice() {
  [ "$OS" = "darwin" ] && return 0
  ls "$INSTALL_DIR"/kubectl "$INSTALL_DIR"/helm "$INSTALL_DIR"/k3d "$INSTALL_DIR"/kind >/dev/null 2>&1 || return 0
  case ":${ORIGINAL_PATH:-}:" in
    *":$INSTALL_DIR:"*) return 0 ;;
  esac
  echo
  echo -e "${YELLOW}Tools were installed into ${INSTALL_DIR}, which is not on your PATH.${NC}"
  echo "labctl finds them anyway; to use kubectl yourself, add this to your ~/.bashrc or ~/.zshrc:"
  echo "  export PATH=\"${INSTALL_DIR}:\$PATH\""
}

# ---------------------------------------------------------------------------
# Container runtime - Colima (macOS) or Docker Engine (Linux)
# ---------------------------------------------------------------------------

# macOS: ensure Homebrew is present.
_install_homebrew() {
  if command -v brew &>/dev/null; then
    echo -e "${GREEN}Homebrew already installed${NC}"
    return 0
  fi
  echo "Installing Homebrew (this may take a few minutes)..."
  NONINTERACTIVE=1 /bin/bash -c \
    "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  # Activate brew in the current shell - path differs between Apple Silicon and Intel.
  if [ -x /opt/homebrew/bin/brew ]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
  elif [ -x /usr/local/bin/brew ]; then
    eval "$(/usr/local/bin/brew shellenv)"
  fi
  echo -e "${GREEN}Homebrew installed${NC}"
}

# macOS: install Colima + Docker CLI, then start the VM at the lab's size.
install_colima() {
  echo -e "${YELLOW}Setting up Colima (macOS container runtime)...${NC}"

  if docker info &>/dev/null; then
    echo -e "${GREEN}Docker is already running${NC}"
    return 0
  fi
  if ! command -v colima &>/dev/null; then
    _install_homebrew
    echo "Installing colima and the docker CLI via Homebrew..."
    brew install colima docker docker-buildx
  fi
  link_buildx
  ensure_docker_running || exit 1
}

# link_buildx makes Homebrew's buildx visible to the docker CLI. Without it
# every app build prints the legacy-builder deprecation warning. Docker Desktop
# ships its own buildx, so an existing plugin is left alone.
link_buildx() {
  command -v brew &>/dev/null || return 0
  local plugin="$HOME/.docker/cli-plugins/docker-buildx" src
  [ -e "$plugin" ] && return 0
  src="$(brew --prefix)/opt/docker-buildx/bin/docker-buildx"
  if [ ! -x "$src" ]; then
    brew install docker-buildx >/dev/null 2>&1 || return 0
  fi
  mkdir -p "$HOME/.docker/cli-plugins"
  ln -sfn "$src" "$plugin"
}

# Linux: detect distro ID from /etc/os-release.
_linux_distro() {
  if [ -f /etc/os-release ]; then
    # shellcheck source=/dev/null
    . /etc/os-release
    echo "${ID:-unknown}"
  else
    echo "unknown"
  fi
}

# Linux Debian/Ubuntu family - Docker's official apt repo.
_docker_apt() {
  local distro="$1"
  echo "Installing Docker Engine via apt (${distro})..."
  sudo apt-get update -qq
  sudo apt-get install -y -qq ca-certificates curl gnupg lsb-release
  sudo install -m 0755 -d /etc/apt/keyrings
  curl -fsSL "https://download.docker.com/linux/${distro}/gpg" |
    sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  sudo chmod a+r /etc/apt/keyrings/docker.gpg
  local codename
  codename="$(. /etc/os-release && echo "${VERSION_CODENAME:-}")"
  [ -z "$codename" ] && codename="$(lsb_release -cs 2>/dev/null || echo "")"
  printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/%s %s stable\n' \
    "$(dpkg --print-architecture)" "$distro" "$codename" |
    sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
  sudo apt-get update -qq
  sudo apt-get install -y -qq \
    docker-ce docker-ce-cli containerd.io \
    docker-buildx-plugin docker-compose-plugin
}

# Linux RHEL/CentOS/Fedora/Rocky/Alma family - Docker's official rpm repo.
_docker_rpm() {
  local repo_distro="$1" # centos | fedora | rhel
  echo "Installing Docker Engine via dnf/yum (${repo_distro})..."
  local pm="yum"
  command -v dnf &>/dev/null && pm="dnf"
  sudo "$pm" install -y "${pm}-plugins-core" 2>/dev/null ||
    sudo "$pm" install -y yum-utils 2>/dev/null || true
  sudo "$pm" config-manager \
    --add-repo "https://download.docker.com/linux/${repo_distro}/docker-ce.repo"
  sudo "$pm" install -y \
    docker-ce docker-ce-cli containerd.io \
    docker-buildx-plugin docker-compose-plugin
}

# Linux: install Docker Engine natively using the host package manager.
install_docker_linux() {
  echo -e "${YELLOW}Installing Docker Engine (Linux)...${NC}"

  if command -v docker &>/dev/null && docker info &>/dev/null; then
    echo -e "${GREEN}Docker Engine already installed and running${NC}"
    return 0
  fi
  # A docker that exists but cannot be used (Docker Desktop's WSL shim with
  # integration off, or a stale docker-group session) must not trigger a
  # second, conflicting install.
  local problem
  if ! problem="$(docker_access_problem)"; then
    echo -e "${RED}ERROR: ${problem}${NC}" >&2
    exit 1
  fi
  # On WSL, Docker Desktop or Rancher Desktop that is merely stopped looks like
  # "no docker at all" from inside the distro: its CLI shim disappears too.
  # SNOWOPS_NATIVE_DOCKER=1 installs Docker Engine in the distro regardless.
  local app
  if is_wsl && [ "${SNOWOPS_NATIVE_DOCKER:-}" != "1" ] && docker_cli_missing && app="$(windows_docker_app)"; then
    echo -e "${RED}ERROR: ${app} is installed on Windows but not running.${NC}" >&2
    echo "  Start ${app}, make sure its WSL Integration is enabled for '${WSL_DISTRO_NAME:-this distro}'," >&2
    echo "  then reopen this terminal and re-run 'labctl init'." >&2
    echo "  To use Docker Engine inside this distro instead, keep ${app} stopped (or uninstall it)" >&2
    echo "  and run: SNOWOPS_NATIVE_DOCKER=1 labctl init" >&2
    exit 1
  fi
  if command -v docker &>/dev/null && is_wsl; then
    echo -e "${YELLOW}A docker CLI is installed but no daemon answers.${NC}"
  fi

  local distro
  distro="$(_linux_distro)"

  case "$distro" in
    ubuntu | debian | linuxmint | pop | elementary | kali | raspbian)
      _docker_apt "$distro"
      ;;
    fedora)
      _docker_rpm "fedora"
      ;;
    rhel | centos | rocky | almalinux)
      _docker_rpm "centos"
      ;;
    amzn)
      # Amazon Linux 2 / 2023 ships Docker in its own repo.
      sudo yum install -y docker
      ;;
    arch | manjaro | endeavouros)
      sudo pacman -Sy --noconfirm docker
      ;;
    alpine)
      sudo apk add --no-cache docker
      ;;
    *)
      echo -e "${RED}ERROR: Unsupported Linux distribution '${distro}'.${NC}" >&2
      echo "Install Docker manually: https://docs.docker.com/engine/install/" >&2
      exit 1
      ;;
  esac

  # Enable and start the Docker service.
  if command -v systemctl &>/dev/null && systemctl list-units --type=service &>/dev/null; then
    sudo systemctl enable docker
    sudo systemctl start docker
  elif command -v service &>/dev/null; then
    sudo service docker start
    if is_wsl; then
      echo -e "${YELLOW}WSL is running without systemd, so Docker will not start by itself after 'wsl --shutdown'.${NC}"
      echo "  Either run 'sudo service docker start' in each new session, or enable systemd:"
      echo "  add '[boot]' and 'systemd=true' to /etc/wsl.conf, then 'wsl --shutdown' in PowerShell."
    fi
  fi

  # Add the current user to the docker group for non-root access. The group
  # only applies to new login sessions, so this session cannot use Docker yet;
  # stop and tell the user what to do next.
  local current_user="${USER:-$(id -un)}"
  if ! id -nG "$current_user" 2>/dev/null | grep -qw docker; then
    sudo usermod -aG docker "$current_user"
    echo
    echo -e "${GREEN}Docker is installed and '$current_user' was added to the docker group.${NC}"
    if is_wsl; then
      echo -e "${YELLOW}Next: run 'wsl --shutdown' in PowerShell, reopen this terminal, then re-run 'labctl init'.${NC}"
    else
      echo -e "${YELLOW}Next: log out and back in (or run 'newgrp docker'), then re-run 'labctl init'.${NC}"
    fi
    exit 1
  fi

  wait_for_docker 60 || exit 1
  echo -e "${GREEN}Docker Engine installed and running${NC}"
}

# Public entry point - routes to the right runtime for the current OS.
install_docker() {
  if [ "$OS" = "darwin" ]; then
    install_colima
  else
    install_docker_linux
  fi
}

# ---------------------------------------------------------------------------
# Profile groups
# ---------------------------------------------------------------------------

install_common() {
  echo -e "${GREEN}========== Installing Common Tools ==========${NC}"
  ensure_tool kubectl
  echo -e "${GREEN}========== Common Tools Complete ==========${NC}\n"
}

install_k3d_profile() {
  echo -e "${GREEN}========== Installing K3D Profile ==========${NC}"
  install_common
  install_docker # Colima on macOS; Docker Engine on Linux
  ensure_tool k3d
  ensure_tool helm
  echo -e "${GREEN}========== K3D Profile Complete ==========${NC}\n"
}

install_kind_profile() {
  echo -e "${GREEN}========== Installing kind Profile ==========${NC}"
  install_common
  install_docker # Colima on macOS; Docker Engine on Linux
  ensure_tool kind
  ensure_tool helm
  echo -e "${GREEN}========== kind Profile Complete ==========${NC}\n"
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

show_help() {
  cat <<EOF
Usage: setup-tools.sh [PROFILE]

Detected: OS=${OS}, ARCH=${ARCH}

Profiles:
  k3d     kubectl + colima/docker + k3d + helm    (local cluster - the golden path)
  kind    kubectl + colima/docker + kind + helm   (headless; used by CI)
  common  kubectl only
  all     all of the above

Container runtime installed per OS:
  macOS   → Colima (lightweight Docker VM via Homebrew)
  Linux   → Docker Engine (native; distro auto-detected)

Examples:
  ./setup-tools.sh k3d
  ./setup-tools.sh kind
  make setup-tools PROFILE=k3d
EOF
}

main() {
  local profile="${1:-k3d}"

  printf "${GREEN}╔════════════════════════════════════════════╗\n"
  printf "║  Setup Tools - Profile: %-6s (%s/%s)\n" "$profile" "$OS" "$ARCH"
  printf "╚════════════════════════════════════════════╝\n\n${NC}"

  case "$profile" in
    k3d) install_k3d_profile ;;
    kind) install_kind_profile ;;
    common) install_common ;;
    all)
      install_k3d_profile
      install_kind_profile
      ;;
    help | --help | -h)
      show_help
      exit 0
      ;;
    *)
      echo -e "${RED}Error: unknown profile '$profile'${NC}" >&2
      show_help
      exit 1
      ;;
  esac

  user_bin_notice
  echo -e "${GREEN}Setup complete!${NC}"
  maybe_wsl_notice
}

main "$@"
