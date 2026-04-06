#!/usr/bin/env bats
load "../setup"
setup() {
  _common_setup
  use_docker_stub
  source_cli
}
teardown() { _common_teardown; }

@test "version: outputs cleat and semver" {
  run cmd_version
  assert_output --partial "cleat"
  assert_output --partial "v${VERSION}"
  [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]  || return 1
}

@test "version: prints current version" {
  run cmd_version
  assert_output --partial "v${VERSION}"
}

# ── check_for_update ────────────────────────────────────────────────────────

@test "update check: skips for non-git installs" {
  REPO_DIR="$TEST_TEMP"  # no .git
  run check_for_update
  assert_success
  assert_output ""
}

@test "update check: silent when cached version matches" {
  mkdir -p "$TEST_TEMP/.git"
  REPO_DIR="$TEST_TEMP"
  UPDATE_CHECK_FILE="$TEST_TEMP/.update_check"
  echo "$(date +%s) ${VERSION}" > "$UPDATE_CHECK_FILE"

  run check_for_update
  assert_success
  assert_output ""
}

@test "update check: shows banner with versions when update available" {
  mkdir -p "$TEST_TEMP/.git"
  REPO_DIR="$TEST_TEMP"
  UPDATE_CHECK_FILE="$TEST_TEMP/.update_check"
  echo "$(date +%s) 99.0.0" > "$UPDATE_CHECK_FILE"

  run check_for_update
  assert_output --partial "Update available"
  assert_output --partial "v${VERSION}"
  assert_output --partial "v99.0.0"
  assert_output --partial "cleat update"
}

@test "update check: no banner when local version is newer than remote" {
  mkdir -p "$TEST_TEMP/.git"
  REPO_DIR="$TEST_TEMP"
  UPDATE_CHECK_FILE="$TEST_TEMP/.update_check"
  echo "$(date +%s) 0.0.1" > "$UPDATE_CHECK_FILE"

  run check_for_update
  assert_success
  assert_output ""
}

@test "update check: banner box borders are aligned" {
  mkdir -p "$TEST_TEMP/.git"
  REPO_DIR="$TEST_TEMP"
  UPDATE_CHECK_FILE="$TEST_TEMP/.update_check"
  echo "$(date +%s) 99.0.0" > "$UPDATE_CHECK_FILE"

  run check_for_update
  # Strip ANSI codes and measure display width of │-delimited content lines
  local clean
  clean=$(echo "$output" | sed 's/\x1b\[[0-9;]*m//g')
  # All lines containing │ should have the same display width
  local lengths
  lengths=$(echo "$clean" | grep '│' | LC_ALL=C awk '{ gsub(/[^\x00-\x7f]/, "X"); print length }' | sort -u)
  local count
  count=$(echo "$lengths" | wc -l | tr -d ' ')
  [[ "$count" -eq 1 ]] || { echo "Unequal box line lengths:"; echo "$clean" | grep '│'; return 1; }
}

@test "update check: handles corrupted cache gracefully" {
  mkdir -p "$TEST_TEMP/.git"
  REPO_DIR="$TEST_TEMP"
  UPDATE_CHECK_FILE="$TEST_TEMP/.update_check"

  # Create git stub for the refresh
  mkdir -p "$TEST_TEMP/bin"
  printf '#!/bin/sh\necho "abc refs/tags/v%s"' "$VERSION" > "$TEST_TEMP/bin/git"
  chmod +x "$TEST_TEMP/bin/git"
  export PATH="$TEST_TEMP/bin:$PATH"

  echo "garbage data here" > "$UPDATE_CHECK_FILE"
  run check_for_update
  assert_success
}

@test "update check: refreshes stale cache (>24h old)" {
  mkdir -p "$TEST_TEMP/.git"
  REPO_DIR="$TEST_TEMP"
  UPDATE_CHECK_FILE="$TEST_TEMP/.update_check"

  mkdir -p "$TEST_TEMP/bin"
  printf '#!/bin/sh\necho "abc refs/tags/v%s"' "$VERSION" > "$TEST_TEMP/bin/git"
  chmod +x "$TEST_TEMP/bin/git"
  export PATH="$TEST_TEMP/bin:$PATH"

  local old_ts=$(( $(date +%s) - 200000 ))
  echo "$old_ts ${VERSION}" > "$UPDATE_CHECK_FILE"

  run check_for_update
  assert_success

  # Timestamp should be updated
  local new_ts
  new_ts=$(awk 'NR==1 {print $1}' "$UPDATE_CHECK_FILE")
  [[ "$new_ts" -gt "$old_ts" ]]  || return 1
}

@test "update check: does NOT refresh fresh cache (<24h old)" {
  mkdir -p "$TEST_TEMP/.git"
  REPO_DIR="$TEST_TEMP"
  UPDATE_CHECK_FILE="$TEST_TEMP/.update_check"

  local fresh_ts=$(( $(date +%s) - 1 ))
  echo "$fresh_ts ${VERSION}" > "$UPDATE_CHECK_FILE"

  run check_for_update
  assert_success

  # Timestamp should NOT change
  local stored_ts
  stored_ts=$(awk 'NR==1 {print $1}' "$UPDATE_CHECK_FILE")
  assert_equal "$stored_ts" "$fresh_ts"
}
