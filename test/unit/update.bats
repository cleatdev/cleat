#!/usr/bin/env bats
load "../setup"

setup() {
  _common_setup
  use_docker_stub

  mkdir -p "$TEST_TEMP/bin"
  cat > "$TEST_TEMP/bin/git" << 'GITSTUB'
#!/usr/bin/env bash
echo "git $*" >> "${GIT_CALLS:-/dev/null}"
case "$*" in
  *ls-remote*) echo "${GIT_LS_REMOTE_OUTPUT:-}" ;;
  *fetch*)
    [[ "${GIT_FETCH_FAIL:-}" == "1" ]] && exit 1
    exit 0 ;;
  *checkout*)
    [[ "${GIT_CHECKOUT_FAIL:-}" == "1" ]] && exit 1
    exit 0 ;;
  *)  exit 0 ;;
esac
GITSTUB
  chmod +x "$TEST_TEMP/bin/git"
  export PATH="$TEST_TEMP/bin:$PATH"
  GIT_CALLS="$TEST_TEMP/git_calls"
  export GIT_CALLS
  touch "$GIT_CALLS"
  source_cli
}

teardown() { _common_teardown; }

@test "update: fails if not a git installation" {
  REPO_DIR="$TEST_TEMP"
  run cmd_update
  assert_failure
  assert_output --partial "not a git installation"
}

@test "update: reports already up to date" {
  mkdir -p "$TEST_TEMP/.git"
  REPO_DIR="$TEST_TEMP"
  UPDATE_CHECK_FILE="$TEST_TEMP/.update_check"
  export GIT_LS_REMOTE_OUTPUT="abc123	refs/tags/v${VERSION}"

  run cmd_update
  assert_success
  assert_output --partial "Already on the latest version"
}

@test "update: fails when no remote tags exist" {
  mkdir -p "$TEST_TEMP/.git"
  REPO_DIR="$TEST_TEMP"
  UPDATE_CHECK_FILE="$TEST_TEMP/.update_check"
  export GIT_LS_REMOTE_OUTPUT=""

  run cmd_update
  assert_failure
  assert_output --partial "No tags found"
}

@test "update: checks out new version and clears cache" {
  mkdir -p "$TEST_TEMP/.git"
  REPO_DIR="$TEST_TEMP"
  UPDATE_CHECK_FILE="$TEST_TEMP/.update_check"
  echo "12345 old" > "$UPDATE_CHECK_FILE"
  export GIT_LS_REMOTE_OUTPUT="abc123	refs/tags/v99.0.0"

  run cmd_update
  assert_success
  assert_output --partial "99.0.0"
  assert_output --partial "cleat rebuild"

  # Git checkout was called
  run cat "$GIT_CALLS"
  assert_output --partial "checkout"

  # Cache file cleared
  [[ ! -f "$UPDATE_CHECK_FILE" ]]  || return 1
}

@test "update: fails gracefully on fetch error" {
  mkdir -p "$TEST_TEMP/.git"
  REPO_DIR="$TEST_TEMP"
  export GIT_FETCH_FAIL=1

  run cmd_update
  assert_failure
  assert_output --partial "Failed to fetch"
}

@test "update: fails gracefully on checkout error" {
  mkdir -p "$TEST_TEMP/.git"
  REPO_DIR="$TEST_TEMP"
  UPDATE_CHECK_FILE="$TEST_TEMP/.update_check"
  export GIT_LS_REMOTE_OUTPUT="abc123	refs/tags/v99.0.0"
  export GIT_CHECKOUT_FAIL=1

  run cmd_update
  assert_failure
  assert_output --partial "Failed to checkout"
}

@test "update: tries docker pull after git update" {
  mkdir -p "$TEST_TEMP/.git"
  REPO_DIR="$TEST_TEMP"
  UPDATE_CHECK_FILE="$TEST_TEMP/.update_check"
  echo "12345 old" > "$UPDATE_CHECK_FILE"
  export GIT_LS_REMOTE_OUTPUT="abc123	refs/tags/v99.0.0"

  run cmd_update
  assert_success

  # Docker pull was attempted with the version-matched registry image
  # (v99.0.0 is the new tag cmd_update just checked out).
  run grep "pull" "$DOCKER_CALLS"
  assert_success
  assert_output --partial "${REGISTRY_BASE}:v99.0.0"
}

@test "update: shows rebuild hint when pull fails" {
  mkdir -p "$TEST_TEMP/.git"
  REPO_DIR="$TEST_TEMP"
  UPDATE_CHECK_FILE="$TEST_TEMP/.update_check"
  echo "12345 old" > "$UPDATE_CHECK_FILE"
  export GIT_LS_REMOTE_OUTPUT="abc123	refs/tags/v99.0.0"
  # Pull fails (default stub behavior)

  run cmd_update
  assert_success
  assert_output --partial "cleat rebuild"
}

@test "update: skips rebuild hint when pull succeeds" {
  mkdir -p "$TEST_TEMP/.git"
  REPO_DIR="$TEST_TEMP"
  UPDATE_CHECK_FILE="$TEST_TEMP/.update_check"
  echo "12345 old" > "$UPDATE_CHECK_FILE"
  export GIT_LS_REMOTE_OUTPUT="abc123	refs/tags/v99.0.0"
  export DOCKER_PULL_EXIT_CODE=0

  run cmd_update
  assert_success
  # Should show the pulled-image success line, not the rebuild hint.
  assert_output --partial "pulled v99.0.0"
  refute_output --partial "cleat rebuild"

  unset DOCKER_PULL_EXIT_CODE
}
