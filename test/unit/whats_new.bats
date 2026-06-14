#!/usr/bin/env bats
# ── _maybe_show_release_highlight (bounded on-start release highlight) ─────────
#
# A TTY-only, non-blocking note shown for the first RELEASE_HIGHLIGHT_MAX_SHOWS
# launches after VERSION changes, then quiet for that version. Bounded
# repetition, not once and not forever: people miss a one-time note, but a
# forever-repeating one trains the eye to skip the startup block (where the
# actionable drift/update/security notices also live). It never prompts and
# never touches the network. State is "<version> <count>" in
# $LAST_SEEN_VERSION_FILE; _is_tty is false under bats (output is captured), so
# tests that exercise the visible path force it true.
load "../setup"
setup() {
  _common_setup
  use_docker_stub
  source_cli
  REPO_DIR="$TEST_TEMP"
  LAST_SEEN_VERSION_FILE="$TEST_TEMP/.last_seen_version"
  # The shipped copy is written for the current VERSION; keep them in sync so the
  # visible-path tests fire. The stale-guard test overrides this to a mismatch.
  RELEASE_HIGHLIGHT_VERSION="$VERSION"
  # Pin the cap so these tests don't drift if the shipped default changes.
  RELEASE_HIGHLIGHT_MAX_SHOWS=3
}
teardown() { _common_teardown; }

@test "whats-new: shows on a fresh install (no state file), recording count 1" {
  _is_tty() { return 0; }
  run _maybe_show_release_highlight
  assert_success
  assert_output --partial "New in v0.14.0"
  assert_output --partial "Boxes"
  run cat "$LAST_SEEN_VERSION_FILE"
  assert_output "$VERSION 1"
}

@test "whats-new: copy carries the try-command and the version-anchored changelog link" {
  _is_tty() { return 0; }
  run _maybe_show_release_highlight
  assert_success
  assert_output --partial "cleat start dev"
  # Anchored to the feature's release section (#v0.14.0), not the bare changelog
  # page — the /changelog page IDs each release by its version.
  assert_output --partial "cleat.sh/changelog#v0.14.0"
}

@test "whats-new: the changelog link is a clickable OSC 8 hyperlink in supporting terminals" {
  _is_tty() { return 0; }
  _supports_osc8() { return 0; }   # e.g. iTerm2 / VS Code / WezTerm
  run _maybe_show_release_highlight
  assert_success
  # OSC 8 link target is the full https URL (the visible label can be the short form).
  assert_output --partial "$(printf '\033]8;;https://cleat.sh/changelog#v0.14.0\033\\')"
}

@test "whats-new: the try-command and changelog sit on their own lines, not crammed onto the prose" {
  # The cramped layout tacked "Try: cleat start dev · cleat.sh/changelog" onto
  # the end of the description line. They now each get a labelled line. Falsify
  # the run-on layout: the line that holds the try-command must not also hold the
  # prose tail, and the changelog must not share the try-command's line.
  _is_tty() { return 0; }
  local out; out="$(_maybe_show_release_highlight)"
  local try_line cl_line
  try_line="$(printf '%s\n' "$out" | grep -F 'cleat start dev')"
  cl_line="$(printf '%s\n' "$out" | grep -F 'cleat.sh/changelog')"
  # The try-command is not buried in the prose sentence.
  printf '%s' "$try_line" | grep -qF "reaches the other" \
    && { echo "try-command crammed onto the prose line"; return 1; } || true
  # The changelog link is on its own line, not appended after the try-command.
  printf '%s' "$cl_line" | grep -qF 'cleat start dev' \
    && { echo "changelog crammed onto the try-command line"; return 1; } || true
}

@test "whats-new: a trailing blank separates the highlight from the bring-up block" {
  _is_tty() { return 0; }
  # The highlight owns its own separation from the bring-up that follows, so the
  # bring-up needs no leading blank of its own. Append a sentinel: $(...) strips
  # only the FINAL newline, so the trailing `echo ""` survives as an empty line
  # immediately before SENTINEL. Dropping it makes the 'changelog' line sit right
  # against SENTINEL — falsifiable.
  local out
  out="$( { _maybe_show_release_highlight; printf 'SENTINEL\n'; } )"
  local cls
  cls="$(printf '%s\n' "$out" | awk '
    /^SENTINEL$/ { print (p ~ /^[[:space:]]*$/ ? "BLANK" : "NOTBLANK"); f=1; exit }
    { p=$0 }
    END { if (!f) print "NOTFOUND" }
  ')"
  run echo "$cls"
  assert_output "BLANK"
}

@test "whats-new: shows the first 3 launches, then goes silent" {
  _is_tty() { return 0; }
  local i
  for i in 1 2 3; do
    run _maybe_show_release_highlight
    assert_success
    assert_output --partial "New in v"
  done
  # 4th launch: cap reached → silent, count pinned at the cap.
  run _maybe_show_release_highlight
  assert_success
  assert_output ""
  run cat "$LAST_SEEN_VERSION_FILE"
  assert_output "$VERSION 3"
}

@test "whats-new: increments the shown count on each visible launch" {
  _is_tty() { return 0; }
  _maybe_show_release_highlight >/dev/null
  run cat "$LAST_SEEN_VERSION_FILE"; assert_output "$VERSION 1"
  _maybe_show_release_highlight >/dev/null
  run cat "$LAST_SEEN_VERSION_FILE"; assert_output "$VERSION 2"
}

@test "whats-new: silent once the cap is already recorded" {
  _is_tty() { return 0; }
  echo "$VERSION $RELEASE_HIGHLIGHT_MAX_SHOWS" > "$LAST_SEEN_VERSION_FILE"
  run _maybe_show_release_highlight
  assert_success
  assert_output ""
}

@test "whats-new: an upgrade resets the counter (old version past the cap → shows)" {
  _is_tty() { return 0; }
  echo "0.0.1 9" > "$LAST_SEEN_VERSION_FILE"   # different version, well past the cap
  run _maybe_show_release_highlight
  assert_success
  assert_output --partial "New in v"
  run cat "$LAST_SEEN_VERSION_FILE"
  assert_output "$VERSION 1"
}

@test "whats-new: STALE GUARD — silent when highlight copy is for another version" {
  _is_tty() { return 0; }
  RELEASE_HIGHLIGHT_VERSION="0.0.0"   # copy not refreshed for this VERSION
  run _maybe_show_release_highlight
  assert_success
  assert_output ""
  # Must NOT record anything — a future matching release still shows.
  [[ ! -f "$LAST_SEEN_VERSION_FILE" ]]  || return 1
}

@test "whats-new: silent on a non-interactive (non-TTY) run" {
  # Do NOT override _is_tty — under bats it is false. Scripts/pipes see nothing.
  run _maybe_show_release_highlight
  assert_success
  assert_output ""
  [[ ! -f "$LAST_SEEN_VERSION_FILE" ]]  || return 1
}

@test "whats-new: self-heals a corrupted state file" {
  _is_tty() { return 0; }
  printf 'garbage\nlines\n' > "$LAST_SEEN_VERSION_FILE"
  run _maybe_show_release_highlight
  assert_success
  assert_output --partial "New in v"
  # Rewrites it cleanly as a fresh count.
  run cat "$LAST_SEEN_VERSION_FILE"
  assert_output "$VERSION 1"
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

@test "whats-new: records the bumped count BEFORE printing (Ctrl-C / under-count safe)" {
  _is_tty() { return 0; }
  # Stub the first visible line to assert the state file ALREADY holds the bumped
  # count when output begins. Moving the write after the print (a plausible
  # refactor) makes this fail — pinning the "record before print" invariant.
  info() { [[ "$(cat "$LAST_SEEN_VERSION_FILE" 2>/dev/null)" == "$VERSION 1" ]] || echo "ORDER_VIOLATION"; }
  run _maybe_show_release_highlight
  assert_success
  refute_output --partial "ORDER_VIOLATION"
}

@test "whats-new: silent (no permanent nag) when the state can't be persisted" {
  _is_tty() { return 0; }
  # Read-only install dir: the bumped count can't be written, so it must NOT
  # print — otherwise the note would re-show on every single launch.
  echo "0.0.1 0" > "$LAST_SEEN_VERSION_FILE"   # stale, older version
  chmod 0444 "$LAST_SEEN_VERSION_FILE"
  run _maybe_show_release_highlight
  chmod 0644 "$LAST_SEEN_VERSION_FILE" 2>/dev/null || true
  assert_success
  assert_output ""
}

@test "whats-new: parses \$1 as version and \$2 as count (trailing tokens ignored)" {
  _is_tty() { return 0; }
  # A count below the cap with trailing junk must still show and bump correctly.
  # Mutating `print \$2+0` → `print \$0` would mis-read the count and break this.
  printf '%s 1 extra trailing tokens\n' "$VERSION" > "$LAST_SEEN_VERSION_FILE"
  run _maybe_show_release_highlight
  assert_success
  assert_output --partial "New in v"
  run cat "$LAST_SEEN_VERSION_FILE"
  assert_output "$VERSION 2"
}

@test "whats-new: a non-numeric count is treated as zero (shows, records 1)" {
  _is_tty() { return 0; }
  printf '%s xyz\n' "$VERSION" > "$LAST_SEEN_VERSION_FILE"
  run _maybe_show_release_highlight
  assert_success
  assert_output --partial "New in v"
  run cat "$LAST_SEEN_VERSION_FILE"
  assert_output "$VERSION 1"
}
