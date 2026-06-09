#!/usr/bin/env bats
# Tests for the on-start Claude Code update check:
#   _claude_remote_version       — fetch the newest released version for a channel
#   _maybe_prompt_claude_update  — on interactive start, offer a durable upgrade
#                                  when the image's bundled Claude Code is stale
load "../setup"

setup() {
  _common_setup
  use_docker_stub
  source_cli
  # Never touch the real repo's cache file.
  CLAUDE_CHECK_FILE="$TEST_TEMP/.claude_update_check"
  # Decision logic is what we test here, not image_exists itself.
  image_exists() { return 0; }
  # Record any upgrade invocation (and the channel it was given) instead of
  # actually running docker.
  _upgrade_claude_image() { echo "UPGRADE_CALLED channel=$1"; return 0; }
}

teardown() { _common_teardown; }

# ── _claude_remote_version ───────────────────────────────────────────────────

@test "remote version: returns the injected fake (tests never hit the network)" {
  CLEAT_FAKE_REMOTE_CLAUDE="2.1.149"
  run _claude_remote_version latest
  assert_success
  assert_output "2.1.149"
}

@test "remote version: parses a bare version from curl" {
  unset CLEAT_FAKE_REMOTE_CLAUDE
  curl() { printf '2.1.149'; }
  run _claude_remote_version stable
  assert_success
  assert_output "2.1.149"
}

@test "remote version: rejects an HTML/error page (returns empty)" {
  unset CLEAT_FAKE_REMOTE_CLAUDE
  curl() { printf '<html><body>error</body></html>'; }
  run _claude_remote_version latest
  assert_success
  assert_output ""
}

@test "remote version: takes only the first line (ignores trailing content)" {
  unset CLEAT_FAKE_REMOTE_CLAUDE
  curl() { printf '2.1.149\nMALICIOUS=1\n'; }
  run _claude_remote_version latest
  assert_success
  assert_output "2.1.149"
}

@test "remote version: rejects a semver with trailing junk on the same line" {
  unset CLEAT_FAKE_REMOTE_CLAUDE
  # A leading semver followed by garbage (e.g. injected ANSI/script) must NOT
  # pass through to the terminal display or the cache — the guard is anchored.
  curl() { printf '2.1.149; rm -rf ~'; }
  run _claude_remote_version latest
  assert_success
  assert_output ""
}

# ── _maybe_prompt_claude_update: guards ──────────────────────────────────────

@test "startup check: silent when non-interactive (no TTY)" {
  # _is_tty is false under bats (output captured), so do NOT override it.
  CLEAT_FORCE_CLAUDE_CHECK=1
  CLEAT_FAKE_REMOTE_CLAUDE="2.1.149"
  _image_claude_version() { echo "2.1.40"; }
  run _maybe_prompt_claude_update
  assert_success
  refute_output --partial "New Claude Code available"
  refute_output --partial "UPGRADE_CALLED"
}

@test "startup check: skipped when opted out via CLEAT_NO_CLAUDE_UPDATE_CHECK" {
  _is_tty() { return 0; }
  CLEAT_NO_CLAUDE_UPDATE_CHECK=1
  CLEAT_FORCE_CLAUDE_CHECK=1
  CLEAT_FAKE_REMOTE_CLAUDE="2.1.149"
  _image_claude_version() { echo "2.1.40"; }
  run _maybe_prompt_claude_update
  assert_success
  refute_output --partial "New Claude Code available"
  refute_output --partial "UPGRADE_CALLED"
}

@test "startup check: throttled to once per interval (recent check skips)" {
  _is_tty() { return 0; }
  CLEAT_FAKE_REMOTE_CLAUDE="2.1.149"
  _image_claude_version() { echo "2.1.40"; }
  # A check that happened just now must suppress another for the interval.
  echo "$(date +%s) 2.1.149" > "$CLAUDE_CHECK_FILE"
  run _maybe_prompt_claude_update
  assert_success
  refute_output --partial "New Claude Code available"
  refute_output --partial "UPGRADE_CALLED"
}

@test "startup check: a stale check (past the interval) is not throttled" {
  _is_tty() { return 0; }
  CLEAT_FAKE_REMOTE_CLAUDE="2.1.149"
  _image_claude_version() { echo "2.1.40"; }
  # Paired with "recent check skips" above, this brackets CLAUDE_CHECK_INTERVAL
  # (600s / 10 min): a check older than the window must proceed (not throttled),
  # so bumping the interval to a large value — which would silently stop periodic
  # re-checks — breaks this test. No CLEAT_FORCE_CLAUDE_CHECK here: the throttle
  # path itself is under test, not bypassed.
  local old_ts=$(( $(date +%s) - 660 ))   # just past the 10-min window
  echo "$old_ts 2.1.149" > "$CLAUDE_CHECK_FILE"
  run _maybe_prompt_claude_update <<< "n"
  assert_success
  assert_output --partial "New Claude Code available"
}

# ── _maybe_prompt_claude_update: version comparison ──────────────────────────

@test "startup check: prompts and upgrades on 'yes' when remote is newer" {
  _is_tty() { return 0; }
  CLEAT_FORCE_CLAUDE_CHECK=1
  CLEAT_FAKE_REMOTE_CLAUDE="2.1.149"
  _image_claude_version() { echo "2.1.40"; }
  run _maybe_prompt_claude_update <<< "y"
  assert_success
  assert_output --partial "New Claude Code available"
  assert_output --partial "UPGRADE_CALLED channel=latest"
}

@test "startup check: an empty answer (Enter) defaults to yes and upgrades" {
  _is_tty() { return 0; }
  CLEAT_FORCE_CLAUDE_CHECK=1
  CLEAT_FAKE_REMOTE_CLAUDE="2.1.149"
  _image_claude_version() { echo "2.1.40"; }
  run _maybe_prompt_claude_update <<< ""
  assert_success
  assert_output --partial "UPGRADE_CALLED channel=latest"
}

@test "startup check: 'no' does not upgrade (and records the check)" {
  _is_tty() { return 0; }
  CLEAT_FORCE_CLAUDE_CHECK=1
  CLEAT_FAKE_REMOTE_CLAUDE="2.1.149"
  _image_claude_version() { echo "2.1.40"; }
  run _maybe_prompt_claude_update <<< "n"
  assert_success
  assert_output --partial "New Claude Code available"
  refute_output --partial "UPGRADE_CALLED"
  # The check was recorded so a flaky/declined run won't nag every start.
  run cat "$CLAUDE_CHECK_FILE"
  assert_output --partial "2.1.149"
}

@test "startup check: no prompt when the image already runs the remote version" {
  _is_tty() { return 0; }
  CLEAT_FORCE_CLAUDE_CHECK=1
  CLEAT_FAKE_REMOTE_CLAUDE="2.1.40"
  _image_claude_version() { echo "2.1.40"; }
  run _maybe_prompt_claude_update <<< "y"
  assert_success
  refute_output --partial "New Claude Code available"
  refute_output --partial "UPGRADE_CALLED"
}

@test "startup check: never nags to downgrade (image newer than channel)" {
  _is_tty() { return 0; }
  CLEAT_FORCE_CLAUDE_CHECK=1
  CLEAT_FAKE_REMOTE_CLAUDE="2.1.10"
  _image_claude_version() { echo "2.1.40"; }
  run _maybe_prompt_claude_update <<< "y"
  assert_success
  refute_output --partial "New Claude Code available"
  refute_output --partial "UPGRADE_CALLED"
}

@test "startup check: offline (no remote version) falls through silently" {
  _is_tty() { return 0; }
  CLEAT_FORCE_CLAUDE_CHECK=1
  _claude_remote_version() { return 0; }   # simulate network failure
  _image_claude_version() { echo "2.1.40"; }
  run _maybe_prompt_claude_update <<< "y"
  assert_success
  refute_output --partial "New Claude Code available"
  refute_output --partial "UPGRADE_CALLED"
}

# ── _maybe_prompt_claude_update: channel injection guard ─────────────────────

@test "startup check: malicious CLEAT_CLAUDE_CHANNEL falls back to latest" {
  _is_tty() { return 0; }
  CLEAT_FORCE_CLAUDE_CHECK=1
  CLEAT_CLAUDE_CHANNEL='2.1.0; rm -rf ~'
  CLEAT_FAKE_REMOTE_CLAUDE="2.1.149"
  _image_claude_version() { echo "2.1.40"; }
  run _maybe_prompt_claude_update <<< "y"
  assert_success
  # The injected string must never reach _upgrade_claude_image; it is replaced
  # by the safe default.
  assert_output --partial "UPGRADE_CALLED channel=latest"
  refute_output --partial "rm -rf"
}

@test "startup check: honors a valid CLEAT_CLAUDE_CHANNEL=stable" {
  _is_tty() { return 0; }
  CLEAT_FORCE_CLAUDE_CHECK=1
  CLEAT_CLAUDE_CHANNEL=stable
  CLEAT_FAKE_REMOTE_CLAUDE="2.1.149"
  _image_claude_version() { echo "2.1.40"; }
  run _maybe_prompt_claude_update <<< "y"
  assert_success
  assert_output --partial "UPGRADE_CALLED channel=stable"
  assert_output --partial "(stable)"
}
