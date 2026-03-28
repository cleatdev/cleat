#!/usr/bin/env bash
# Shared test setup — sourced by every .bats file

# Paths
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$TEST_DIR/.." && pwd)"

# Load bats helpers (absolute paths so they work from any .bats location)
load "$TEST_DIR/test_helper/bats-support/load"
load "$TEST_DIR/test_helper/bats-assert/load"

CLI="$PROJECT_ROOT/bin/cleat"

_common_setup() {
  TEST_TEMP="$(mktemp -d)"
  export TEST_TEMP

  MOCK_BIN="$TEST_DIR/fixtures/mock_bin"
  export MOCK_BIN

  # Docker stub records calls here
  DOCKER_CALLS="$TEST_TEMP/docker_calls"
  export DOCKER_CALLS
  touch "$DOCKER_CALLS"

  # File-based mock responses (more reliable than env vars across subshells)
  DOCKER_MOCK_DIR="$TEST_TEMP/docker_mock"
  export DOCKER_MOCK_DIR
  mkdir -p "$DOCKER_MOCK_DIR"
  rm -f "$DOCKER_MOCK_DIR"/* 2>/dev/null || true
  export DOCKER_EXIT_CODE=0

  # Reset function overrides to default (nothing running/existing)
  _MOCK_PS_MATCH=""
  _MOCK_PS_A_MATCH=""
}

_common_teardown() {
  rm -rf "$TEST_TEMP"
}

# Source the CLI (without running main)
# The CLI has `set -euo pipefail` at line 2.  We strip it before sourcing
# because it clobbers bats' internal ERR trap (which bats needs to detect
# test failures).  The CLI functions don't need `-e` to be defined — they
# handle errors with explicit `exit 1` / `return` in their own logic.
# We keep pipefail OFF to avoid flaky failures in pipeline-based helpers
# like `is_running` which use `docker ps ... | grep -q ...`.
source_cli() {
  local _cli_tmp
  _cli_tmp=$(mktemp)
  sed 's/^set -euo pipefail$/# [stripped for testing]/' "$CLI" > "$_cli_tmp"
  source "$_cli_tmp"
  rm -f "$_cli_tmp"
}

# Enable the docker stub by prepending MOCK_BIN to PATH
use_docker_stub() {
  export PATH="$MOCK_BIN:$PATH"
}

# Set mock docker responses by overriding the CLI's check functions directly.
# This avoids all file/env/subshell race conditions.
_MOCK_PS_MATCH=""
_MOCK_PS_A_MATCH=""

mock_docker_ps() {
  _MOCK_PS_MATCH="$1"
  # Override the function AND write the file (for commands that call docker directly)
  is_running() {
    [[ "$1" == "$_MOCK_PS_MATCH" ]]
  }
  printf '%s\n' "$1" > "$DOCKER_MOCK_DIR/ps_output"
}

mock_docker_ps_a() {
  _MOCK_PS_A_MATCH="$1"
  container_exists() {
    [[ "$1" == "$_MOCK_PS_A_MATCH" ]]
  }
  printf '%s\n' "$1" > "$DOCKER_MOCK_DIR/ps_a_output"
}

mock_docker_images() {
  if [[ "$1" == "$IMAGE_NAME" ]]; then
    image_exists() { return 0; }
  else
    image_exists() { return 1; }
  fi
  printf '%s\n' "$1" > "$DOCKER_MOCK_DIR/images_output"
}

mock_docker_inspect() {
  printf '%s\n' "$1" > "$DOCKER_MOCK_DIR/inspect_output"
}

# Read all recorded docker calls
docker_calls() {
  cat "$DOCKER_CALLS"
}

# Read only specific docker subcommands from recorded calls
docker_run_calls() {
  grep "^docker run " "$DOCKER_CALLS" || true
}

docker_exec_calls() {
  grep "^docker exec " "$DOCKER_CALLS" || true
}

docker_build_calls() {
  grep "^docker build " "$DOCKER_CALLS" || true
}

# Assert that a docker run call for a given container contains a substring.
# These use echo+exit instead of fail/return, so they work under set +e.
# Usage: run assert_docker_run_has "container-name" "--memory 8g"
#        assert_success
assert_docker_run_has() {
  local cname="$1" needle="$2"
  local run_line
  run_line="$(grep "^docker run " "$DOCKER_CALLS" | grep "$cname" | tail -1)"
  if [[ -z "$run_line" ]]; then
    echo "No docker run call found for container '$cname'" >&2
    exit 1
  fi
  if [[ "$run_line" != *"$needle"* ]]; then
    echo "docker run for '$cname' missing '$needle'" >&2
    echo "Actual: $run_line" >&2
    exit 1
  fi
}

assert_docker_run_lacks() {
  local cname="$1" needle="$2"
  local run_line
  run_line="$(grep "^docker run " "$DOCKER_CALLS" | grep "$cname" | tail -1)"
  if [[ -n "$run_line" ]] && [[ "$run_line" == *"$needle"* ]]; then
    echo "docker run for '$cname' should not contain '$needle'" >&2
    exit 1
  fi
}

assert_docker_exec_has() {
  local needle="$1"
  # Docker exec calls span multiple lines (bash -c with heredoc).
  # Read the entire DOCKER_CALLS file and search for needle.
  local all_calls
  all_calls="$(cat "$DOCKER_CALLS")"
  if [[ "$all_calls" != *"$needle"* ]]; then
    echo "docker exec missing '$needle'" >&2
    echo "Actual calls:" >&2
    grep "^docker exec" "$DOCKER_CALLS" >&2 || true
    exit 1
  fi
}
