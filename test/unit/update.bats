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

@test "update: refuses to self-update a Homebrew install" {
  # The detector has its own tests below; here we lock the BRANCH: a
  # brew-managed cleat must refuse before any git or docker work, and must
  # never print the curl re-install hint (which on an Intel Mac would symlink
  # over Homebrew's own bin).
  mkdir -p "$TEST_TEMP/.git"
  REPO_DIR="$TEST_TEMP"
  UPDATE_CHECK_FILE="$TEST_TEMP/.update_check"
  export GIT_LS_REMOTE_OUTPUT="abc123	refs/tags/v99.0.0"
  _is_brew_managed() { return 0; }

  run cmd_update
  assert_failure
  assert_output --partial "Installed via Homebrew"
  assert_output --partial "brew upgrade cleatdev/tap/cleat"
  refute_output --partial "not a git installation"
  refute_output --partial "install.sh"

  # No network, no checkout, no image pull: the refusal is total.
  run cat "$GIT_CALLS"
  refute_output --partial "fetch"
  refute_output --partial "checkout"
  run cat "$DOCKER_CALLS"
  refute_output --partial "pull"
}

@test "update: _is_brew_managed detects a keg through the bin symlink" {
  # No INSTALL_RECEIPT.json here on purpose: this test must depend on the
  # Cellar path segment alone, so breaking that pattern cannot be masked by
  # the receipt walk (which the separate receipt test covers).
  mkdir -p "$TEST_TEMP/hb/Cellar/cleat/9.9.9/libexec/bin" "$TEST_TEMP/hb/bin"
  : > "$TEST_TEMP/hb/Cellar/cleat/9.9.9/libexec/bin/cleat"
  ln -s "../Cellar/cleat/9.9.9/libexec/bin/cleat" "$TEST_TEMP/hb/bin/cleat"

  # Probe the SYMLINK: that is what BASH_SOURCE holds for a brew install.
  run _is_brew_managed "$TEST_TEMP/hb/bin/cleat"
  assert_success
}

@test "update: _is_brew_managed detects a keg receipt above the binary" {
  # Second signal, independent of the path spelling: the keg root's receipt.
  mkdir -p "$TEST_TEMP/keg/cleat/9.9.9/libexec/bin"
  : > "$TEST_TEMP/keg/cleat/9.9.9/libexec/bin/cleat"
  echo '{}' > "$TEST_TEMP/keg/cleat/9.9.9/INSTALL_RECEIPT.json"

  run _is_brew_managed "$TEST_TEMP/keg/cleat/9.9.9/libexec/bin/cleat"
  assert_success
}

@test "update: _is_brew_managed is false for the curl install symlink shape" {
  # The Intel-Mac collision: /usr/local/bin is Homebrew's bin AND install.sh's
  # symlink target. Only the resolved physical path can tell them apart, so a
  # symlink in a brew-shaped directory pointing at ~/.cleat is NOT brew.
  mkdir -p "$TEST_TEMP/usr-local-bin" "$TEST_TEMP/.cleat/bin"
  : > "$TEST_TEMP/.cleat/bin/cleat"
  ln -s "$TEST_TEMP/.cleat/bin/cleat" "$TEST_TEMP/usr-local-bin/cleat"

  run _is_brew_managed "$TEST_TEMP/usr-local-bin/cleat"
  assert_failure
}

@test "update: _is_brew_managed is false for a plain regular file" {
  mkdir -p "$TEST_TEMP/plain/bin"
  : > "$TEST_TEMP/plain/bin/cleat"

  run _is_brew_managed "$TEST_TEMP/plain/bin/cleat"
  assert_failure
}

@test "update: _resolve_physical_path follows a relative symlink chain" {
  mkdir -p "$TEST_TEMP/hb/Cellar/cleat/9.9.9/libexec/bin" "$TEST_TEMP/hb/bin"
  : > "$TEST_TEMP/hb/Cellar/cleat/9.9.9/libexec/bin/cleat"
  ln -s "../Cellar/cleat/9.9.9/libexec/bin/cleat" "$TEST_TEMP/hb/bin/cleat"

  local want
  want="$(cd "$TEST_TEMP/hb/Cellar/cleat/9.9.9/libexec/bin" && pwd -P)/cleat"

  run _resolve_physical_path "$TEST_TEMP/hb/bin/cleat"
  assert_success
  assert_output "$want"
}

@test "update: _resolve_physical_path resolves through directories with spaces" {
  mkdir -p "$TEST_TEMP/h b/Cellar/cleat/9.9.9/libexec/bin" "$TEST_TEMP/h b/bin"
  : > "$TEST_TEMP/h b/Cellar/cleat/9.9.9/libexec/bin/cleat"
  ln -s "../Cellar/cleat/9.9.9/libexec/bin/cleat" "$TEST_TEMP/h b/bin/cleat"

  local want
  want="$(cd "$TEST_TEMP/h b/Cellar/cleat/9.9.9/libexec/bin" && pwd -P)/cleat"

  run _resolve_physical_path "$TEST_TEMP/h b/bin/cleat"
  assert_success
  assert_output "$want"

  run _is_brew_managed "$TEST_TEMP/h b/bin/cleat"
  assert_success
}

@test "update: _resolve_physical_path returns an unresolvable path unchanged" {
  # A deleted or never-created path (what BASH_SOURCE holds for a sourced
  # copy) must come back verbatim, not empty: callers pattern-match it.
  run _resolve_physical_path "$TEST_TEMP/gone/cleat"
  assert_success
  assert_output "$TEST_TEMP/gone/cleat"
}

@test "update: _resolve_physical_path survives a symlink cycle" {
  # A cycle must be capped, not walked forever. Run it in a timed subprocess
  # so a broken cap fails the test instead of hanging the whole suite.
  ln -s "$TEST_TEMP/loop-b" "$TEST_TEMP/loop-a"
  ln -s "$TEST_TEMP/loop-a" "$TEST_TEMP/loop-b"

  local cli_copy="$TEST_TEMP/cleat-cycle.sh"
  sed 's/^set -euo pipefail$/: # stripped for this subshell/' "$CLI" > "$cli_copy"

  run _portable_timeout 10 bash -c 'source "$1"; _resolve_physical_path "$2"' \
    _ "$cli_copy" "$TEST_TEMP/loop-a"
  assert_success
  assert_output --partial "$TEST_TEMP/loop-"
}

@test "update: the on-start prompt stays silent for an install with no git tree" {
  # The Homebrew shape relies on this gate: a keg has no .git, so the on-start
  # self-update offer must never fire there (it would git-checkout inside the
  # keg). Stronger than version.bats' shallow check: here a NEWER release is
  # cached and the TTY is forced, so only the .git gate keeps it quiet.
  REPO_DIR="$TEST_TEMP"  # deliberately no .git
  UPDATE_CHECK_FILE="$TEST_TEMP/.update_check"
  export CLEAT_FORCE_UPDATE_CHECK=1
  export GIT_LS_REMOTE_OUTPUT="abc123	refs/tags/v99.0.0"
  _is_tty() { return 0; }
  _repo_is_clean() { return 0; }
  _apply_cli_update() { echo "APPLY_CALLED"; return 0; }
  _reexec_cli() { echo "REEXEC_CALLED"; }

  run _maybe_prompt_cli_update <<< "n"
  assert_success
  assert_output ""

  # The gate returns before the throttle file is even written.
  run test -f "$UPDATE_CHECK_FILE"
  assert_failure
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
