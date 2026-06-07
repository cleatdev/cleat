#!/usr/bin/env bats
load "../setup"
setup() {
  _common_setup
  use_docker_stub
  source_cli
  # The CLI self-update prompt skips a dirty/dev tree (real git would fail the
  # checkout). The tests use a fake `.git`, so default the cleanliness check to
  # "clean" here; the dedicated dirty-tree test overrides it back to dirty.
  _repo_is_clean() { return 0; }
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

# ── _maybe_prompt_cli_update (interactive CLI self-update preflight) ──────────
#
# TTY-only prompt that, when a newer released Cleat exists, offers to update and
# re-exec as that version. _is_tty is false under bats (output captured), so
# tests that exercise the prompt force it true. _apply_cli_update and _reexec_cli
# are overridden so no git checkout or process re-exec actually happens.

@test "cli update: skips for non-git installs" {
  REPO_DIR="$TEST_TEMP"  # no .git
  _is_tty() { return 0; }
  run _maybe_prompt_cli_update
  assert_success
  assert_output ""
}

@test "cli update: does nothing on a non-interactive (non-TTY) run" {
  # The real guard: scripts/pipes never get a prompt and never hit the network.
  mkdir -p "$TEST_TEMP/.git"
  REPO_DIR="$TEST_TEMP"
  UPDATE_CHECK_FILE="$TEST_TEMP/.update_check"
  echo "$(date +%s) 99.0.0" > "$UPDATE_CHECK_FILE"
  # Do NOT override _is_tty — under bats it is false.
  _apply_cli_update() { echo "APPLY_CALLED"; return 0; }
  _reexec_cli() { echo "REEXEC_CALLED"; }

  run _maybe_prompt_cli_update
  assert_success
  assert_output ""
  refute_output --partial "APPLY_CALLED"
}

@test "cli update: opt-out env disables the prompt" {
  mkdir -p "$TEST_TEMP/.git"
  REPO_DIR="$TEST_TEMP"
  UPDATE_CHECK_FILE="$TEST_TEMP/.update_check"
  echo "$(date +%s) 99.0.0" > "$UPDATE_CHECK_FILE"
  _is_tty() { return 0; }
  export CLEAT_NO_UPDATE_CHECK=1

  run _maybe_prompt_cli_update <<< "y"
  assert_success
  refute_output --partial "update available"
}

@test "cli update: silent when cached version matches" {
  mkdir -p "$TEST_TEMP/.git"
  REPO_DIR="$TEST_TEMP"
  UPDATE_CHECK_FILE="$TEST_TEMP/.update_check"
  echo "$(date +%s) ${VERSION}" > "$UPDATE_CHECK_FILE"
  _is_tty() { return 0; }

  run _maybe_prompt_cli_update
  assert_success
  assert_output ""
}

@test "cli update: prompts with versions when a newer release is available" {
  mkdir -p "$TEST_TEMP/.git"
  REPO_DIR="$TEST_TEMP"
  UPDATE_CHECK_FILE="$TEST_TEMP/.update_check"
  echo "$(date +%s) 99.0.0" > "$UPDATE_CHECK_FILE"
  _is_tty() { return 0; }
  _apply_cli_update() { echo "APPLY_CALLED v=$1"; return 0; }
  _reexec_cli() { echo "REEXEC_CALLED"; }

  run _maybe_prompt_cli_update <<< "n"
  assert_success
  assert_output --partial "Cleat update available"
  assert_output --partial "v${VERSION}"
  assert_output --partial "v99.0.0"
  # Declined → no update applied, no re-exec.
  refute_output --partial "APPLY_CALLED"
  refute_output --partial "REEXEC_CALLED"
}

@test "cli update: accepting applies the update and re-execs the new version" {
  mkdir -p "$TEST_TEMP/.git"
  REPO_DIR="$TEST_TEMP"
  UPDATE_CHECK_FILE="$TEST_TEMP/.update_check"
  echo "$(date +%s) 99.0.0" > "$UPDATE_CHECK_FILE"
  _is_tty() { return 0; }
  _apply_cli_update() { echo "APPLY_CALLED v=$1"; return 0; }
  _reexec_cli() { echo "REEXEC_CALLED"; }

  run _maybe_prompt_cli_update <<< "y"
  assert_success
  assert_output --partial "APPLY_CALLED v=99.0.0"
  assert_output --partial "REEXEC_CALLED"
}

@test "cli update: empty answer defaults to yes (applies + re-execs)" {
  mkdir -p "$TEST_TEMP/.git"
  REPO_DIR="$TEST_TEMP"
  UPDATE_CHECK_FILE="$TEST_TEMP/.update_check"
  echo "$(date +%s) 99.0.0" > "$UPDATE_CHECK_FILE"
  _is_tty() { return 0; }
  _apply_cli_update() { echo "APPLY_CALLED v=$1"; return 0; }
  _reexec_cli() { echo "REEXEC_CALLED"; }

  run _maybe_prompt_cli_update <<< ""
  assert_success
  assert_output --partial "APPLY_CALLED"
  assert_output --partial "REEXEC_CALLED"
}

@test "cli update: a failed apply does NOT re-exec and continues on the current version" {
  mkdir -p "$TEST_TEMP/.git"
  REPO_DIR="$TEST_TEMP"
  UPDATE_CHECK_FILE="$TEST_TEMP/.update_check"
  echo "$(date +%s) 99.0.0" > "$UPDATE_CHECK_FILE"
  _is_tty() { return 0; }
  _apply_cli_update() { return 1; }
  _reexec_cli() { echo "REEXEC_CALLED"; }

  run _maybe_prompt_cli_update <<< "y"
  assert_success
  refute_output --partial "REEXEC_CALLED"
  assert_output --partial "Update failed"
}

@test "cli update: no prompt when local version is newer than remote" {
  mkdir -p "$TEST_TEMP/.git"
  REPO_DIR="$TEST_TEMP"
  UPDATE_CHECK_FILE="$TEST_TEMP/.update_check"
  echo "$(date +%s) 0.0.1" > "$UPDATE_CHECK_FILE"
  _is_tty() { return 0; }
  _apply_cli_update() { echo "APPLY_CALLED"; return 0; }
  _reexec_cli() { echo "REEXEC_CALLED"; }

  run _maybe_prompt_cli_update
  assert_success
  refute_output --partial "update available"
  refute_output --partial "APPLY_CALLED"
}

@test "cli update: handles corrupted cache gracefully" {
  mkdir -p "$TEST_TEMP/.git"
  REPO_DIR="$TEST_TEMP"
  UPDATE_CHECK_FILE="$TEST_TEMP/.update_check"

  # Git stub for the refresh returns the current version (so no prompt fires).
  mkdir -p "$TEST_TEMP/bin"
  printf '#!/bin/sh\necho "abc refs/tags/v%s"' "$VERSION" > "$TEST_TEMP/bin/git"
  chmod +x "$TEST_TEMP/bin/git"
  export PATH="$TEST_TEMP/bin:$PATH"
  _is_tty() { return 0; }

  echo "garbage data here" > "$UPDATE_CHECK_FILE"
  run _maybe_prompt_cli_update
  assert_success
}

# These two tests bracket UPDATE_CHECK_INTERVAL (600s / 10 min). A cache just
# PAST the window must refresh; one just INSIDE it must not. The 60s margins on
# each side keep them non-flaky while still pinning the constant: bumping it back
# to 86400 breaks the "stale → refresh" test (660 < 86400), and dropping it to
# 300 or 60 breaks the "fresh → no refresh" test (540 ≥ 300).
@test "cli update: refreshes stale cache (>10min old)" {
  mkdir -p "$TEST_TEMP/.git"
  REPO_DIR="$TEST_TEMP"
  UPDATE_CHECK_FILE="$TEST_TEMP/.update_check"

  mkdir -p "$TEST_TEMP/bin"
  printf '#!/bin/sh\necho "abc refs/tags/v%s"' "$VERSION" > "$TEST_TEMP/bin/git"
  chmod +x "$TEST_TEMP/bin/git"
  export PATH="$TEST_TEMP/bin:$PATH"
  _is_tty() { return 0; }

  local old_ts=$(( $(date +%s) - 660 ))   # just past the 10-min window
  echo "$old_ts ${VERSION}" > "$UPDATE_CHECK_FILE"

  run _maybe_prompt_cli_update
  assert_success
  local new_ts
  new_ts=$(awk 'NR==1 {print $1}' "$UPDATE_CHECK_FILE")
  [[ "$new_ts" -gt "$old_ts" ]]  || return 1
}

@test "cli update: does NOT refresh fresh cache (<10min old)" {
  mkdir -p "$TEST_TEMP/.git"
  REPO_DIR="$TEST_TEMP"
  UPDATE_CHECK_FILE="$TEST_TEMP/.update_check"
  _is_tty() { return 0; }

  local fresh_ts=$(( $(date +%s) - 540 ))   # just inside the 10-min window
  echo "$fresh_ts ${VERSION}" > "$UPDATE_CHECK_FILE"

  run _maybe_prompt_cli_update
  assert_success
  local stored_ts
  stored_ts=$(awk 'NR==1 {print $1}' "$UPDATE_CHECK_FILE")
  assert_equal "$stored_ts" "$fresh_ts"
}

# ── hardening: dirty tree, declined-version suppression, EOF, apply, re-exec ──

@test "cli update: skips entirely on a dirty/dev tree (no nag-then-fail loop)" {
  mkdir -p "$TEST_TEMP/.git"
  REPO_DIR="$TEST_TEMP"
  UPDATE_CHECK_FILE="$TEST_TEMP/.update_check"
  echo "$(date +%s) 99.0.0" > "$UPDATE_CHECK_FILE"
  _is_tty() { return 0; }
  _repo_is_clean() { return 1; }   # uncommitted changes present
  _apply_cli_update() { echo "APPLY_CALLED"; return 0; }
  _reexec_cli() { echo "REEXEC_CALLED"; }

  run _maybe_prompt_cli_update <<< "y"
  assert_success
  refute_output --partial "update available"
  refute_output --partial "APPLY_CALLED"
}

@test "cli update: does not re-prompt for a version already declined" {
  mkdir -p "$TEST_TEMP/.git"
  REPO_DIR="$TEST_TEMP"
  UPDATE_CHECK_FILE="$TEST_TEMP/.update_check"
  # field 3 = declined version, equal to the cached newer version
  echo "$(date +%s) 99.0.0 99.0.0" > "$UPDATE_CHECK_FILE"
  _is_tty() { return 0; }
  _apply_cli_update() { echo "APPLY_CALLED"; return 0; }

  run _maybe_prompt_cli_update <<< "y"
  assert_success
  refute_output --partial "update available"
  refute_output --partial "APPLY_CALLED"
}

@test "cli update: declining records the version so it stops nagging" {
  mkdir -p "$TEST_TEMP/.git"
  REPO_DIR="$TEST_TEMP"
  UPDATE_CHECK_FILE="$TEST_TEMP/.update_check"
  echo "$(date +%s) 99.0.0" > "$UPDATE_CHECK_FILE"
  _is_tty() { return 0; }
  _apply_cli_update() { echo "APPLY_CALLED"; return 0; }
  _reexec_cli() { echo "REEXEC_CALLED"; }

  run _maybe_prompt_cli_update <<< "n"
  assert_success
  assert_output --partial "Cleat update available"
  # The declined version is persisted in field 3 so the next launch stays quiet.
  run awk 'NR==1 {print $3}' "$UPDATE_CHECK_FILE"
  assert_output "99.0.0"
}

@test "cli update: re-exec replays the ORIGINAL argv to the new CLI" {
  # Shadow the `exec` builtin with a function so we capture instead of replacing
  # the process; exit before the in-process fallback runs.
  _CLEAT_ORIG_ARGV=(run /some/proj --json)
  exec() { echo "EXEC $*"; exit 0; }

  run _reexec_cli
  assert_success
  assert_output --partial "run /some/proj --json"
}

@test "cli update: _apply_cli_update checks out v<tag> and invalidates the caches" {
  mkdir -p "$TEST_TEMP/.git" "$TEST_TEMP/bin"
  REPO_DIR="$TEST_TEMP"
  UPDATE_CHECK_FILE="$TEST_TEMP/.update_check"; echo x > "$UPDATE_CHECK_FILE"
  CLAUDE_CHECK_FILE="$TEST_TEMP/.claude_update_check"; echo x > "$CLAUDE_CHECK_FILE"
  cat > "$TEST_TEMP/bin/git" << 'EOF'
#!/bin/sh
echo "$@" >> "$GIT_LOG"
exit 0
EOF
  chmod +x "$TEST_TEMP/bin/git"
  export PATH="$TEST_TEMP/bin:$PATH" GIT_LOG="$TEST_TEMP/git.log"

  run _apply_cli_update 9.9.9
  assert_success
  grep -q "checkout v9.9.9" "$TEST_TEMP/git.log" \
    || { echo "checkout v9.9.9 not invoked:"; cat "$TEST_TEMP/git.log"; return 1; }
  [[ ! -f "$UPDATE_CHECK_FILE" ]] || { echo "update cache not invalidated"; return 1; }
  [[ ! -f "$CLAUDE_CHECK_FILE" ]] || { echo "claude cache not invalidated"; return 1; }
}

@test "cli update: _apply_cli_update returns nonzero when the checkout fails" {
  mkdir -p "$TEST_TEMP/.git" "$TEST_TEMP/bin"
  REPO_DIR="$TEST_TEMP"
  cat > "$TEST_TEMP/bin/git" << 'EOF'
#!/bin/sh
case "$*" in *checkout*) exit 1 ;; *) exit 0 ;; esac
EOF
  chmod +x "$TEST_TEMP/bin/git"
  export PATH="$TEST_TEMP/bin:$PATH"

  run _apply_cli_update 9.9.9
  assert_failure
}
