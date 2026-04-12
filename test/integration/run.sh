#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Integration test runner.
#
# Runs test/integration/*.bats against a real Docker daemon. Skips cleanly
# if Docker is unavailable. Not invoked by test.sh — run manually or via CI.
#
# Usage:
#   test/integration/run.sh              # run all *.bats in this dir
#   test/integration/run.sh env.bats     # run one file
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BATS="$REPO_ROOT/test/bats/bin/bats"

if ! command -v docker &>/dev/null; then
  echo "docker not found — skipping integration tests" >&2
  exit 0
fi

if ! docker info &>/dev/null; then
  echo "docker daemon not responding — skipping integration tests" >&2
  exit 0
fi

if [[ $# -gt 0 ]]; then
  exec "$BATS" "$SCRIPT_DIR/$1"
fi

exec "$BATS" "$SCRIPT_DIR"/*.bats
