#!/usr/bin/env bats
# Tests for latest_remote_tag() — git tag parsing and version sorting

load "../setup"

setup() {
  _common_setup

  # Create a fake git stub that returns controlled ls-remote output
  mkdir -p "$TEST_TEMP/bin"
  GIT_LS_REMOTE_OUTPUT=""
  export GIT_LS_REMOTE_OUTPUT

  cat > "$TEST_TEMP/bin/git" << 'GITSTUB'
#!/usr/bin/env bash
case "$*" in
  *ls-remote*) echo -n "${GIT_LS_REMOTE_OUTPUT:-}" ;;
  *)           exit 0 ;;
esac
GITSTUB
  chmod +x "$TEST_TEMP/bin/git"
  export PATH="$TEST_TEMP/bin:$PATH"

  source_cli
}

teardown() { _common_teardown; }

@test "latest_remote_tag returns empty when no tags exist" {
  GIT_LS_REMOTE_OUTPUT=""
  # The pipeline in latest_remote_tag fails (grep finds nothing) under set -e,
  # so we use run to capture the exit code
  run latest_remote_tag
  assert_output ""
}

@test "latest_remote_tag extracts version from v-prefixed tag" {
  GIT_LS_REMOTE_OUTPUT="abc123	refs/tags/v0.1.0"
  local result
  result="$(latest_remote_tag)"
  assert_equal "$result" "0.1.0"
}

@test "latest_remote_tag extracts version from non-prefixed tag" {
  GIT_LS_REMOTE_OUTPUT="abc123	refs/tags/0.2.0"
  local result
  result="$(latest_remote_tag)"
  assert_equal "$result" "0.2.0"
}

@test "latest_remote_tag returns highest version when multiple exist" {
  GIT_LS_REMOTE_OUTPUT="aaa	refs/tags/v0.1.0
bbb	refs/tags/v0.2.0
ccc	refs/tags/v0.10.0
ddd	refs/tags/v0.3.0
eee	refs/tags/v1.0.0"

  local result
  result="$(latest_remote_tag)"
  assert_equal "$result" "1.0.0"
}

@test "latest_remote_tag handles mixed v-prefix and non-prefix" {
  GIT_LS_REMOTE_OUTPUT="aaa	refs/tags/v0.1.0
bbb	refs/tags/0.5.0
ccc	refs/tags/v0.3.0"

  local result
  result="$(latest_remote_tag)"
  assert_equal "$result" "0.5.0"
}

@test "latest_remote_tag ignores non-semver tags" {
  GIT_LS_REMOTE_OUTPUT="aaa	refs/tags/v0.1.0
bbb	refs/tags/release-candidate
ccc	refs/tags/v0.2.0-beta
ddd	refs/tags/v0.3.0"

  local result
  result="$(latest_remote_tag)"
  assert_equal "$result" "0.3.0"
}

@test "latest_remote_tag sorts numerically not lexically" {
  # Lexical sort would put 9 after 10; numeric sort gets it right
  GIT_LS_REMOTE_OUTPUT="aaa	refs/tags/v0.9.0
bbb	refs/tags/v0.10.0"

  local result
  result="$(latest_remote_tag)"
  assert_equal "$result" "0.10.0"
}
