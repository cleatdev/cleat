#!/usr/bin/env bats

load "../setup"

setup() {
  _common_setup
}

teardown() { _common_teardown; }

# ── Bash compatibility (rule 12) ──────────────────────────────────────────

@test "source: no associative arrays (local -A / declare -A)" {
  # local -A and declare -A require bash 4.0+; macOS ships bash 3.2
  run grep -n 'local -A\|declare -A' "$CLI"
  assert_failure  # grep returns 1 = no matches
}

@test "source: no readarray or mapfile" {
  run grep -n 'readarray\|mapfile' "$CLI"
  assert_failure
}

@test "source: no pipe stderr (|&)" {
  run grep -n '|&' "$CLI"
  assert_failure
}

# ── Strict mode (rule 13) ─────────────────────────────────────────────────
# These run the actual binary, not sourced, to catch set -euo pipefail issues.

@test "strict mode: cleat --help runs without error" {
  run bash "$CLI" --help
  assert_success
}

@test "strict mode: cleat --version runs without error" {
  run bash "$CLI" --version
  assert_success
}

@test "strict mode: cleat with no args shows help or starts (exits cleanly)" {
  # Without docker, this will fail at the docker check — but it should
  # get past argument parsing and global flag handling without set -u errors.
  # We check that it does NOT die with "unbound variable".
  run bash "$CLI" 2>&1
  refute_output --partial "unbound variable"
}

@test "strict mode: cleat start with no args does not hit unbound variable" {
  run bash "$CLI" start 2>&1
  refute_output --partial "unbound variable"
}
