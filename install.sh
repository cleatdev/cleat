#!/usr/bin/env bash
set -euo pipefail

REPO="https://github.com/cleatdev/cleat.git"
INSTALL_DIR="$HOME/.cleat"
BIN_NAME="cleat"
LOCAL_MODE=false

# Parse flags
for arg in "$@"; do
  case "$arg" in
    --local) LOCAL_MODE=true ;;
    --help|-h)
      echo "Usage: install.sh [--local]"
      echo ""
      echo "  --local    Install from current directory (dev mode)"
      echo "             Without --local: clones from GitHub"
      exit 0
      ;;
    *)
      echo "Unknown option: $arg (try --help)" >&2
      exit 1
      ;;
  esac
done

# Colors
BOLD='\033[1m'
DIM='\033[2m'
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
RESET='\033[0m'

info()    { echo -e "  ${BLUE}▸${RESET} $1"; }
success() { echo -e "  ${GREEN}✔${RESET} $1"; }
warn()    { echo -e "  ${YELLOW}!${RESET} $1"; }
error()   { echo -e "  ${RED}✖${RESET} $1"; }

# ── Spinner ────────────────────────────────────────────────────────────────
_SPIN_PID=""

_is_tty() { [[ -t 1 ]]; }

_has_unicode() {
  local lang="${LANG:-}${LC_ALL:-}${LC_CTYPE:-}"
  [[ "$lang" == *UTF-8* ]] || [[ "$lang" == *utf8* ]]
}

spin() {
  local msg="$1"
  if ! _is_tty; then
    info "$msg"
    return
  fi
  local frames
  if _has_unicode; then
    frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
  else
    frames=('-' '\' '|' '/')
  fi
  command -v tput &>/dev/null && tput civis 2>/dev/null
  (
    local i=0
    while true; do
      printf "\r  ${BLUE}%s${RESET} %s" "${frames[$i]}" "$msg"
      i=$(( (i + 1) % ${#frames[@]} ))
      sleep 0.08
    done
  ) &
  _SPIN_PID=$!
  disown "$_SPIN_PID" 2>/dev/null
}

spin_stop() {
  local code="$1" ok_msg="$2" fail_msg="${3:-$2}"
  if [[ -n "$_SPIN_PID" ]]; then
    kill "$_SPIN_PID" 2>/dev/null || true
    wait "$_SPIN_PID" 2>/dev/null || true
    _SPIN_PID=""
    { command -v tput &>/dev/null && tput cnorm 2>/dev/null; } || true
  fi
  if ! _is_tty; then
    [[ "$code" -eq 0 ]] && success "$ok_msg" || error "$fail_msg"
    return
  fi
  if [[ "$code" -eq 0 ]]; then
    printf "\r\033[K  ${GREEN}✔${RESET} %b\n" "$ok_msg"
  else
    printf "\r\033[K  ${RED}✖${RESET} %b\n" "$fail_msg"
  fi
}

_cleanup_spin() {
  if [[ -n "${_SPIN_PID:-}" ]]; then
    kill "$_SPIN_PID" 2>/dev/null || true
    wait "$_SPIN_PID" 2>/dev/null || true
    _SPIN_PID=""
  fi
  { command -v tput &>/dev/null && tput cnorm 2>/dev/null; } || true
}
trap _cleanup_spin EXIT

# ── Header ─────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${CYAN}  ┌─────────────────────────────────────────┐${RESET}"
echo -e "${BOLD}${CYAN}  │   Cleat — Run anything. Break nothing.  │${RESET}"
echo -e "${BOLD}${CYAN}  └─────────────────────────────────────────┘${RESET}"
echo ""

# Check dependencies
if ! command -v git &>/dev/null; then
  error "git is required but not installed."
  exit 1
fi

if ! command -v docker &>/dev/null; then
  warn "Docker is not installed. You'll need it before running cleat."
  echo -e "    ${DIM}https://docs.docker.com/get-docker/${RESET}"
  echo ""
fi

# Validate HOME is set and is an absolute path
if [[ -z "${HOME:-}" ]] || [[ "$HOME" != /* ]]; then
  error "HOME must be set to an absolute path."
  exit 1
fi

# ── Local mode: install from current directory ─────────────────────────────
if $LOCAL_MODE; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

  if [[ ! -f "$SCRIPT_DIR/bin/cleat" ]]; then
    error "bin/cleat not found in ${BOLD}${SCRIPT_DIR}${RESET}"
    echo -e "    ${DIM}Run this from the cleat repo root directory.${RESET}"
    exit 1
  fi

  chmod +x "$SCRIPT_DIR/bin/cleat"
  LOCAL_SOURCE="$SCRIPT_DIR/bin/cleat"

  # Read version from local source
  local_version=$(grep -m1 '^VERSION=' "$LOCAL_SOURCE" | cut -d'"' -f2)
  success "Using local source ${DIM}(v${local_version:-dev})${RESET}"

  # Symlink to PATH
  BIN_DIR="/usr/local/bin"
  if [ -w "$BIN_DIR" ]; then
    ln -sf "$LOCAL_SOURCE" "$BIN_DIR/$BIN_NAME"
    success "Linked ${BOLD}$BIN_NAME${RESET} → ${DIM}${LOCAL_SOURCE}${RESET}"
  elif command -v sudo &>/dev/null; then
    info "Needs sudo to symlink to $BIN_DIR"
    sudo ln -sf "$LOCAL_SOURCE" "$BIN_DIR/$BIN_NAME"
    success "Linked ${BOLD}$BIN_NAME${RESET} → ${DIM}${LOCAL_SOURCE}${RESET}"
  else
    BIN_DIR="$HOME/.local/bin"
    mkdir -p -m 0755 "$BIN_DIR"
    ln -sf "$LOCAL_SOURCE" "$BIN_DIR/$BIN_NAME"
    success "Linked ${BOLD}$BIN_NAME${RESET} → ${DIM}${LOCAL_SOURCE}${RESET}"
    if [[ ":$PATH:" != *":$BIN_DIR:"* ]]; then
      warn "Add $BIN_DIR to your PATH:"
      echo -e "    ${DIM}export PATH=\"\$HOME/.local/bin:\$PATH\"${RESET}"
    fi
  fi

  echo ""
  echo -e "  ${DIM}Local dev install — changes to ${SCRIPT_DIR}/bin/cleat take effect immediately.${RESET}"
  echo -e "  ${DIM}Switch to official release: ${BOLD}./install.sh${RESET}${DIM} (without --local)${RESET}"
  exit 0
fi

# ── Remote mode: install from GitHub ───────────────────────────────────────

# Detect existing installation via symlink
for check_path in /usr/local/bin/cleat "$HOME/.local/bin/cleat"; do
  if [ -L "$check_path" ]; then
    link_target="$(readlink "$check_path" 2>/dev/null || true)"
    if [[ -n "$link_target" ]]; then
      link_dir="$(dirname "$link_target")"
      if [ "$link_dir" != "$INSTALL_DIR" ] && [ -f "$link_target" ]; then
        warn "Found existing installation at ${BOLD}${link_dir}${RESET}"
        echo -e "    ${DIM}The symlink will be updated to point to ${INSTALL_DIR}${RESET}"
        echo ""
        break
      fi
    fi
  fi
done

# Resolve the latest semver tag from a repo (local clone or ls-remote for fresh installs)
latest_tag_from_remote() {
  git ls-remote --tags --refs "$1" 2>/dev/null \
    | awk '{print $2}' \
    | sed 's|refs/tags/v\{0,1\}||' \
    | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' \
    | sort -t. -k1,1n -k2,2n -k3,3n \
    | tail -1
}

latest_tag_local() {
  git -C "$1" tag -l 2>/dev/null \
    | sed 's/^v//' \
    | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' \
    | sort -t. -k1,1n -k2,2n -k3,3n \
    | tail -1
}

# Clone or update
if [ -d "$INSTALL_DIR" ] && [ ! -L "$INSTALL_DIR" ]; then
  if [ -d "$INSTALL_DIR/.git" ]; then
    spin "Updating existing installation..."
    fetch_rc=0
    git -C "$INSTALL_DIR" fetch --tags --force --quiet 2>/dev/null || fetch_rc=$?
    if [[ $fetch_rc -ne 0 ]]; then
      git -C "$INSTALL_DIR" remote set-url origin "$REPO"
      git -C "$INSTALL_DIR" fetch --tags --force --quiet 2>/dev/null || fetch_rc=$?
      if [[ $fetch_rc -ne 0 ]]; then
        spin_stop 1 "" "Failed to fetch updates"
        error "Check your internet connection."
        exit 1
      fi
    fi
    local_tag=$(latest_tag_local "$INSTALL_DIR" || true)
    if [[ -n "$local_tag" ]]; then
      checkout_rc=0
      git -C "$INSTALL_DIR" checkout "v${local_tag}" --quiet 2>/dev/null || checkout_rc=$?
      if [[ $checkout_rc -eq 0 ]]; then
        spin_stop 0 "Updated to v${local_tag}"
      else
        spin_stop 1 "" "Failed to checkout v${local_tag}"
        exit 1
      fi
    else
      spin_stop 0 "Up to date"
      warn "No tags found. Staying on current version."
    fi
  else
    error "$INSTALL_DIR exists but is not a git repository."
    echo -e "    ${DIM}Remove it and retry: rm -rf $INSTALL_DIR${RESET}"
    exit 1
  fi
elif [ -e "$INSTALL_DIR" ]; then
  error "$INSTALL_DIR exists but is not a directory. Remove it and retry."
  exit 1
else
  # Determine the latest tag before cloning
  latest_tag=$(latest_tag_from_remote "$REPO" || true)

  spin "Downloading Cleat..."
  clone_rc=0
  git clone "$REPO" "$INSTALL_DIR" --quiet 2>/dev/null || clone_rc=$?
  spin_stop "$clone_rc" "Downloaded to ${BOLD}$INSTALL_DIR${RESET}" "Download failed"
  if [[ $clone_rc -ne 0 ]]; then
    exit 1
  fi

  if [[ -n "$latest_tag" ]]; then
    spin "Checking out latest release..."
    checkout_rc=0
    git -C "$INSTALL_DIR" checkout "v${latest_tag}" --quiet 2>/dev/null || checkout_rc=$?
    if [[ $checkout_rc -eq 0 ]]; then
      spin_stop 0 "Pinned to v${latest_tag}"
    else
      spin_stop 1 "" "Failed to checkout v${latest_tag}"
      warn "Using latest commit on main instead."
    fi
  else
    warn "No release tags found. Using latest commit on main."
  fi
fi

# Verify the expected file exists and is a regular file
if [ ! -f "$INSTALL_DIR/bin/cleat" ] || [ -L "$INSTALL_DIR/bin/cleat" ]; then
  error "Expected file bin/cleat not found or is a symlink. Installation may be corrupt."
  exit 1
fi

chmod +x "$INSTALL_DIR/bin/cleat"

# Symlink to PATH
BIN_DIR="/usr/local/bin"
if [ -w "$BIN_DIR" ]; then
  ln -sf "$INSTALL_DIR/bin/cleat" "$BIN_DIR/$BIN_NAME"
  echo ""
  success "Installed ${BOLD}$BIN_NAME${RESET} to $BIN_DIR"
elif command -v sudo &>/dev/null; then
  info "Needs sudo to symlink to $BIN_DIR"
  sudo ln -sf "$INSTALL_DIR/bin/cleat" "$BIN_DIR/$BIN_NAME"
  echo ""
  success "Installed ${BOLD}$BIN_NAME${RESET} to $BIN_DIR"
else
  # Fallback to ~/.local/bin
  BIN_DIR="$HOME/.local/bin"
  mkdir -p -m 0755 "$BIN_DIR"
  ln -sf "$INSTALL_DIR/bin/cleat" "$BIN_DIR/$BIN_NAME"
  echo ""
  success "Installed ${BOLD}$BIN_NAME${RESET} to $BIN_DIR"
  if [[ ":$PATH:" != *":$BIN_DIR:"* ]]; then
    warn "Add $BIN_DIR to your PATH:"
    echo -e "    ${DIM}export PATH=\"\$HOME/.local/bin:\$PATH\"${RESET}"
  fi
fi

echo ""
echo -e "  ${GREEN}Ready!${RESET} Run this in any project directory:"
echo ""
echo -e "    ${BOLD}cd ~/your-project${RESET}"
echo -e "    ${BOLD}cleat${RESET}"
echo ""
echo -e "  ${DIM}First run builds the Docker image (~2 min), then you're in.${RESET}"
