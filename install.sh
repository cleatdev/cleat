#!/usr/bin/env bash
set -euo pipefail

REPO="https://github.com/cleatdev/cleat.git"
INSTALL_DIR="$HOME/.cleat"
BIN_NAME="cleat"
LOCAL_MODE=false
FORCE=false

# Parse flags
for arg in "$@"; do
  case "$arg" in
    --local) LOCAL_MODE=true ;;
    --force) FORCE=true ;;
    --help|-h)
      echo "Usage: install.sh [--local] [--force]"
      echo ""
      echo "  --local    Install from current directory (dev mode)"
      echo "             Without --local: clones from GitHub"
      echo "  --force    Replace a cleat already installed at another path"
      echo "             (never a Homebrew keg: run brew uninstall first)"
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
echo -e "${BOLD}${CYAN}  ┌───────────────────────────────────────────┐${RESET}"
echo -e "${BOLD}${CYAN}  │   Cleat                                   │${RESET}"
echo -e "${BOLD}${CYAN}  │   Give the agent a cage, not your keys.   │${RESET}"
echo -e "${BOLD}${CYAN}  │   Unattended, not unguarded.              │${RESET}"
echo -e "${BOLD}${CYAN}  └───────────────────────────────────────────┘${RESET}"
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

# Resolve a symlink chain to the physical file. Plain readlink in a loop, not
# `readlink -f`, which BSD did not have usably before macOS 12.3. Mirrors
# _resolve_physical_path in bin/cleat. A relative target resolves against the
# LINK's own directory, which is the case that matters here: Homebrew's prefix
# symlink is relative (`../Cellar/cleat/<version>/bin/cleat`).
resolve_physical() {
  local p="${1:-}" target hops=0
  while [ -L "$p" ] && [ "$hops" -lt 40 ]; do
    target="$(readlink "$p" 2>/dev/null)" || break
    [ -n "$target" ] || break
    case "$target" in
      /*) p="$target" ;;
      *)  p="$(dirname "$p")/$target" ;;
    esac
    hops=$((hops + 1))
  done
  printf '%s\n' "$p"
}

# Every cleat executable reachable on this machine, as "<bin path>\t<physical
# path>" lines: each PATH entry, then the fixed locations an installer can
# write to even when they are NOT on PATH. That last part is the point. A
# Homebrew prefix is invisible to a shell that never ran `brew shellenv`, and
# a fresh ~/.local/bin usually is not on PATH yet either, so a PATH-only scan
# would report a clean machine while a second cleat sits right there.
find_cleat_installs() {
  local dirs seen="" d p phys
  dirs="$(printf '%s' "${PATH:-}" | tr ':' '\n')
/usr/local/bin
${HOME:-}/.local/bin
/opt/homebrew/bin
/home/linuxbrew/.linuxbrew/bin"
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    p="$d/cleat"
    [ -x "$p" ] || continue
    case "$seen" in *"[$p]"*) continue ;; esac
    seen="$seen[$p]"
    phys="$(resolve_physical "$p")"
    printf '%s\t%s\n' "$p" "$phys"
  done <<< "$dirs"
}

# Where this run will land the symlink. Mirrors the BIN_DIR choice made inside
# the local and remote branches below (writable /usr/local/bin, else sudo to
# the same place, else ~/.local/bin). Computed up front so the one-install
# check knows which path counts as "ours", i.e. a re-install rather than a
# second one. Keep in step with those two branches if either ever changes.
pick_bin_dir() {
  if [ -w "/usr/local/bin" ]; then
    echo "/usr/local/bin"
  elif command -v sudo &>/dev/null; then
    echo "/usr/local/bin"
  else
    echo "$HOME/.local/bin"
  fi
}

# One cleat per machine. A second one at a different bin path means PATH order
# decides which runs, and the loser is invisible until it bites: a stale
# version that "fixes itself" after a shell restart, an update that appears to
# do nothing. Writing the SAME path we already own is a re-install, not a
# second install, so it is always allowed (that is the documented upgrade path
# and the --local to official switch).
#
# A Homebrew keg is never overridable, with or without --force: replacing
# brew's symlink leaves brew tracking an install it no longer owns. A regular
# file is not overridable either, since that is somebody's own copy of the
# script rather than a link this installer created.
refuse_other_installs() {
  local ours="$1" p phys brews="" links="" files=""
  while IFS="$(printf '\t')" read -r p phys; do
    [ -n "$p" ] || continue
    [ "$p" = "$ours" ] && continue
    case "$phys" in
      */Cellar/*) brews="${brews}${p}
"; continue ;;
    esac
    if [ -L "$p" ]; then
      links="${links}${p}
"
    else
      files="${files}${p}
"
    fi
  done <<< "$(find_cleat_installs)"

  if [ -n "$brews" ]; then
    error "cleat is already installed by Homebrew."
    print_install_list "$brews"
    echo -e "    ${DIM}Installing over it would leave you on a copy brew does not track.${RESET}"
    echo -e "    ${DIM}Just updating? ${BOLD}brew upgrade cleatdev/tap/cleat${RESET}"
    echo ""
    echo -e "    ${DIM}Switching to this installer? Run both lines:${RESET}"
    echo -e "      ${BOLD}brew uninstall cleatdev/tap/cleat${RESET}"
    echo -e "      ${BOLD}curl -fsSL https://cleat.sh/install | bash${RESET}"
    echo -e "    ${DIM}Nothing is lost: config, boxes, trust and sessions live outside the install.${RESET}"
    exit 1
  fi
  if [ -n "$files" ]; then
    error "cleat is already installed elsewhere on this machine."
    print_install_list "$files"
    echo -e "    ${DIM}That is a real file, not a symlink, so this installer will not remove it.${RESET}"
    echo -e "    ${DIM}Delete it yourself, then re-run.${RESET}"
    exit 1
  fi
  [ -n "$links" ] || return 0

  if [ "$FORCE" != true ]; then
    error "cleat is already installed elsewhere on this machine."
    print_install_list "$links"
    echo -e "    ${DIM}Two installs mean PATH order decides which one runs.${RESET}"
    echo -e "    ${DIM}Replace it by re-running with ${BOLD}--force${RESET}${DIM}, or remove it and re-run.${RESET}"
    echo -e "    ${DIM}Piped form: ${BOLD}curl -fsSL https://cleat.sh/install | bash -s -- --force${RESET}"
    exit 1
  fi

  while IFS= read -r p; do
    [ -n "$p" ] || continue
    warn "Replacing the install at ${BOLD}${p}${RESET}"
    if [ -w "$(dirname "$p")" ]; then
      rm -f "$p"
    else
      sudo rm -f "$p"
    fi
  done <<< "$links"
}

print_install_list() {
  local line
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    echo -e "    ${BOLD}${line}${RESET}"
  done <<< "$1"
}

refuse_other_installs "$(pick_bin_dir)/cleat"

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
  echo -e "  ${DIM}Local dev install: changes to ${SCRIPT_DIR}/bin/cleat take effect immediately.${RESET}"
  echo -e "  ${DIM}Switch to official release: ${BOLD}./install.sh${RESET}${DIM} (without --local)${RESET}"
  exit 0
fi

# ── Remote mode: install from GitHub ───────────────────────────────────────

# Detect existing installation via symlink. The target is resolved rather than
# tested as written: a relative link (`../foo/bin/cleat`) would otherwise be
# checked against this script's working directory and silently miss.
for check_path in /usr/local/bin/cleat "$HOME/.local/bin/cleat"; do
  if [ -L "$check_path" ]; then
    link_target="$(resolve_physical "$check_path")"
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
