#!/usr/bin/env bats
# ── _maybe_show_release_highlight (one-time on-start release highlight) ────────
#
# A TTY-only, non-blocking note shown ONCE after VERSION changes, then never
# again for that version. It never prompts and never touches the network. The
# state lives in $LAST_SEEN_VERSION_FILE; _is_tty is false under bats (output is
# captured), so tests that exercise the visible path force it true.
load "../setup"
setup() {
  _common_setup
  use_docker_stub
  source_cli
  REPO_DIR="$TEST_TEMP"
  LAST_SEEN_VERSION_FILE="$TEST_TEMP/.last_seen_version"
  # The shipped copy is written for the current VERSION; keep them in sync so the
  # visible-path tests fire. The stale-guard test overrides this back to a mismatch.
  RELEASE_HIGHLIGHT_VERSION="$VERSION"
}
teardown() { _common_teardown; }

@test "whats-new: shows once on a fresh install (no state file)" {
  _is_tty() { return 0; }
  run _maybe_show_release_highlight
  assert_success
  assert_output --partial "New in v${VERSION}"
  assert_output --partial "Boxes"
  # Records the version so it never shows again.
  run cat "$LAST_SEEN_VERSION_FILE"
  assert_output "$VERSION"
}

@test "whats-new: copy carries the try-command and the changelog link" {
  _is_tty() { return 0; }
  run _maybe_show_release_highlight
  assert_success
  assert_output --partial "cleat start dev"
  assert_output --partial "cleat.sh/changelog"
}

@test "whats-new: silent when already shown for this version" {
  _is_tty() { return 0; }
  echo "$VERSION" > "$LAST_SEEN_VERSION_FILE"
  run _maybe_show_release_highlight
  assert_success
  assert_output ""
}

@test "whats-new: shows once after an upgrade (older version recorded)" {
  _is_tty() { return 0; }
  echo "0.0.1" > "$LAST_SEEN_VERSION_FILE"
  run _maybe_show_release_highlight
  assert_success
  assert_output --partial "New in v${VERSION}"
  run cat "$LAST_SEEN_VERSION_FILE"
  assert_output "$VERSION"
}

@test "whats-new: STALE GUARD — silent when highlight copy is for another version" {
  _is_tty() { return 0; }
  RELEASE_HIGHLIGHT_VERSION="0.0.0"   # copy not refreshed for this VERSION
  run _maybe_show_release_highlight
  assert_success
  assert_output ""
  # Must NOT record anything — a future matching release still shows once.
  [[ ! -f "$LAST_SEEN_VERSION_FILE" ]]  || return 1
}

@test "whats-new: silent on a non-interactive (non-TTY) run" {
  # Do NOT override _is_tty — under bats it is false. Scripts/pipes see nothing.
  run _maybe_show_release_highlight
  assert_success
  assert_output ""
  [[ ! -f "$LAST_SEEN_VERSION_FILE" ]]  || return 1
}

@test "whats-new: shows only once across two consecutive launches" {
  _is_tty() { return 0; }
  run _maybe_show_release_highlight
  assert_output --partial "New in v${VERSION}"
  # Second launch (same version) is silent.
  run _maybe_show_release_highlight
  assert_success
  assert_output ""
}

@test "whats-new: self-heals a corrupted state file" {
  _is_tty() { return 0; }
  printf 'garbage\nlines\n' > "$LAST_SEEN_VERSION_FILE"
  run _maybe_show_release_highlight
  assert_success
  assert_output --partial "New in v${VERSION}"
  # Rewrites it cleanly so it won't show again.
  run cat "$LAST_SEEN_VERSION_FILE"
  assert_output "$VERSION"
}

@test "whats-new: never reads stdin (would block on a real TTY)" {
  _is_tty() { return 0; }
  # Feed a sentinel on stdin; a non-blocking function must leave it unconsumed.
  # An accidental `read` would swallow SENTINEL and this would fail — falsifiable,
  # unlike asserting on a "[Y/n]" string the function can never emit.
  local rest=""
  { _maybe_show_release_highlight >/dev/null; rest=$(cat); } <<< "SENTINEL"
  assert_equal "$rest" "SENTINEL"
}

@test "whats-new: records the version BEFORE printing (Ctrl-C safe)" {
  _is_tty() { return 0; }
  # Stub the first visible line to assert the state file is ALREADY written when
  # output begins. Moving the write after the print (a plausible refactor) makes
  # this fail — pinning the "record before print" invariant.
  info() { [[ "$(cat "$LAST_SEEN_VERSION_FILE" 2>/dev/null)" == "$VERSION" ]] || echo "ORDER_VIOLATION"; }
  run _maybe_show_release_highlight
  assert_success
  refute_output --partial "ORDER_VIOLATION"
}

@test "whats-new: silent (no permanent nag) when the state can't be persisted" {
  _is_tty() { return 0; }
  # Read-only install dir: the record can't be written, so it must NOT print —
  # otherwise the note would re-show on every single launch.
  echo "0.0.1" > "$LAST_SEEN_VERSION_FILE"   # stale, older version
  chmod 0444 "$LAST_SEEN_VERSION_FILE"
  run _maybe_show_release_highlight
  chmod 0644 "$LAST_SEEN_VERSION_FILE" 2>/dev/null || true
  assert_success
  assert_output ""
}

@test "whats-new: treats the first whitespace field as the seen version" {
  _is_tty() { return 0; }
  # A state file with trailing tokens must still count as "seen" (awk picks $1).
  # Mutating `print $1` → `print $0` makes last_seen != VERSION → it would show.
  printf '%s extra trailing tokens\n' "$VERSION" > "$LAST_SEEN_VERSION_FILE"
  run _maybe_show_release_highlight
  assert_success
  assert_output ""
}
