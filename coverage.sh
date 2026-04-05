#!/usr/bin/env bash
set -euo pipefail

# coverage.sh — Generate code coverage report for bin/cleat via Docker
# Builds a lightweight container with kcov + bats, runs all tests,
# and outputs coverage to ./coverage/ on the host.
#
# Usage:
#   ./coverage.sh              # HTML + Cobertura + JSON
#   ./coverage.sh --open       # Generate and open HTML report
#   ./coverage.sh --summary    # Print summary only (no HTML open)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE_NAME="cleat-coverage"
COVERAGE_DIR="$SCRIPT_DIR/coverage"
OPEN_REPORT=false

for arg in "$@"; do
  case "$arg" in
    --open)    OPEN_REPORT=true ;;
    --summary) ;;
    --help|-h)
      echo "Usage: ./coverage.sh [--open] [--summary]"
      echo ""
      echo "  --open     Open HTML report in browser after generation"
      echo "  --summary  Print coverage summary (default)"
      exit 0
      ;;
    *)
      echo "Unknown option: $arg" >&2
      exit 1
      ;;
  esac
done

# ── Colors ────────────────────────────────────────────────────────────────
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

# ── Preflight ─────────────────────────────────────────────────────────────
if ! command -v docker &>/dev/null; then
  error "Docker is required but not installed."
  exit 1
fi

echo ""
echo -e "${BOLD}${CYAN}  ┌─────────────────────────────────────────┐${RESET}"
echo -e "${BOLD}${CYAN}  │   Cleat Coverage Report                 │${RESET}"
echo -e "${BOLD}${CYAN}  └─────────────────────────────────────────┘${RESET}"
echo ""

# ── Build coverage image ──────────────────────────────────────────────────
info "Building coverage image..."

docker build -q -t "$IMAGE_NAME" -f - "$SCRIPT_DIR" <<'DOCKERFILE'
FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    bash \
    jq \
    git \
    cmake \
    g++ \
    pkg-config \
    libdw-dev \
    libelf-dev \
    libcurl4-openssl-dev \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Build kcov from source
RUN git clone --depth 1 https://github.com/SimonKagstrom/kcov.git /tmp/kcov && \
    cd /tmp/kcov && mkdir build && cd build && \
    cmake .. -DCMAKE_INSTALL_PREFIX=/usr/local && \
    make -j$(nproc) && make install && \
    rm -rf /tmp/kcov

WORKDIR /workspace
DOCKERFILE

success "Coverage image ready"

# ── Run tests with kcov ───────────────────────────────────────────────────
info "Running tests with coverage instrumentation..."

rm -rf "$COVERAGE_DIR"
mkdir -p "$COVERAGE_DIR"

# Ensure bats submodules are available
if [[ ! -f "$SCRIPT_DIR/test/bats/bin/bats" ]]; then
  git -C "$SCRIPT_DIR" submodule update --init --recursive
fi

docker run --rm \
  -v "$SCRIPT_DIR":/workspace:ro \
  -v "$COVERAGE_DIR":/output \
  "$IMAGE_NAME" \
  bash -c '
    # Copy repo to writable location (kcov needs write access to source dir)
    cp -a /workspace /tmp/cleat
    cd /tmp/cleat

    # Run kcov with bats
    kcov --include-path=/tmp/cleat/bin/cleat /output \
      test/bats/bin/bats test/unit/*.bats > /dev/null 2>&1

    # Fix output permissions to match host user
    chmod -R a+rX /output
  '

# ── Find and display results ──────────────────────────────────────────────
COV_DATA=""
for d in "$COVERAGE_DIR"/bats "$COVERAGE_DIR"/bats.*; do
  if [[ -f "$d/coverage.json" ]]; then
    COV_DATA="$d"
    break
  fi
done

echo ""

if [[ -n "$COV_DATA" ]]; then
  pct=$(jq -r '.percent_covered' "$COV_DATA/coverage.json")
  covered=$(jq -r '.covered_lines' "$COV_DATA/coverage.json")
  total_lines=$(jq -r '.total_lines' "$COV_DATA/coverage.json")

  # Color the percentage based on value
  pct_int="${pct%.*}"
  if [[ "$pct_int" -ge 75 ]]; then
    pct_color="$GREEN"
  elif [[ "$pct_int" -ge 50 ]]; then
    pct_color="$YELLOW"
  else
    pct_color="$RED"
  fi

  success "Coverage report generated"
  echo ""
  echo -e "  ${BOLD}Coverage:${RESET}  ${pct_color}${pct}%${RESET} ${DIM}(${covered}/${total_lines} lines)${RESET}"
  echo ""
  echo -e "  ${DIM}Reports:${RESET}"
  echo -e "    ${DIM}HTML:${RESET}       ${COV_DATA}/index.html"
  echo -e "    ${DIM}Cobertura:${RESET}  ${COV_DATA}/cobertura.xml"
  echo -e "    ${DIM}Codecov:${RESET}    ${COV_DATA}/codecov.json"
  echo -e "    ${DIM}SonarQube:${RESET}  ${COV_DATA}/sonarqube.xml"
  echo -e "    ${DIM}JSON:${RESET}       ${COV_DATA}/coverage.json"

  if $OPEN_REPORT; then
    echo ""
    if command -v open &>/dev/null; then
      open "$COV_DATA/index.html"
      info "Opened in browser"
    elif command -v xdg-open &>/dev/null; then
      xdg-open "$COV_DATA/index.html"
      info "Opened in browser"
    else
      info "Open ${BOLD}${COV_DATA}/index.html${RESET} in your browser"
    fi
  fi
else
  error "Coverage data not found."
  exit 1
fi

echo ""
