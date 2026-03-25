#!/usr/bin/env bash
set -euo pipefail

REPO="https://github.com/cleatdev/cleat.git"
INSTALL_DIR="$HOME/.cleat"
BIN_NAME="cleat"

# Colors
BOLD='\033[1m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
RED='\033[0;31m'
DIM='\033[2m'
RESET='\033[0m'

info()    { echo -e "  ${BLUE}>${RESET} $1"; }
success() { echo -e "  ${GREEN}+${RESET} $1"; }
warn()    { echo -e "  ${YELLOW}!${RESET} $1"; }
error()   { echo -e "  ${RED}x${RESET} $1"; }

echo ""
echo -e "${BOLD}${CYAN}  Cleat - Installer${RESET}"
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
    info "Updating existing installation..."
    git -C "$INSTALL_DIR" fetch --tags --force --quiet 2>/dev/null || {
      warn "Fetch failed. Resetting remote and retrying..."
      git -C "$INSTALL_DIR" remote set-url origin "$REPO"
      git -C "$INSTALL_DIR" fetch --tags --force --quiet || {
        error "Failed to fetch updates. Check your internet connection."
        exit 1
      }
    }
    local_tag=$(latest_tag_local "$INSTALL_DIR")
    if [[ -n "$local_tag" ]]; then
      info "Checking out v${local_tag}..."
      git -C "$INSTALL_DIR" checkout "v${local_tag}" --quiet 2>/dev/null
      success "Updated to v${local_tag}."
    else
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
  latest_tag=$(latest_tag_from_remote "$REPO")

  info "Downloading Cleat..."
  git clone "$REPO" "$INSTALL_DIR" --quiet
  success "Downloaded to ${BOLD}$INSTALL_DIR${RESET}"

  if [[ -n "$latest_tag" ]]; then
    info "Checking out v${latest_tag}..."
    git -C "$INSTALL_DIR" checkout "v${latest_tag}" --quiet 2>/dev/null
    success "Pinned to stable release v${latest_tag}."
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
  success "Installed ${BOLD}$BIN_NAME${RESET} to $BIN_DIR"
elif command -v sudo &>/dev/null; then
  info "Needs sudo to symlink to $BIN_DIR"
  sudo ln -sf "$INSTALL_DIR/bin/cleat" "$BIN_DIR/$BIN_NAME"
  success "Installed ${BOLD}$BIN_NAME${RESET} to $BIN_DIR"
else
  # Fallback to ~/.local/bin
  BIN_DIR="$HOME/.local/bin"
  mkdir -p -m 0755 "$BIN_DIR"
  ln -sf "$INSTALL_DIR/bin/cleat" "$BIN_DIR/$BIN_NAME"
  success "Installed ${BOLD}$BIN_NAME${RESET} to $BIN_DIR"
  if [[ ":$PATH:" != *":$BIN_DIR:"* ]]; then
    warn "Add $BIN_DIR to your PATH:"
    echo -e "    ${DIM}export PATH=\"\$HOME/.local/bin:\$PATH\"${RESET}"
    echo ""
  fi
fi

echo ""
echo -e "  ${GREEN}Ready!${RESET} Run this in any project directory:"
echo ""
echo -e "    ${BOLD}cd ~/your-project${RESET}"
echo -e "    ${BOLD}cleat${RESET}"
echo ""
echo -e "  ${DIM}First run builds the Docker image (~2 min), then you're in.${RESET}"
echo ""
