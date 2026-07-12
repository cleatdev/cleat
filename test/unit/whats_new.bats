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
  assert_output --partial "New in v1.2.0"
  # "Kits" carries the cyan accent, so it is wrapped in color codes; assert the
  # accent word and the contiguous tail separately rather than the split phrase.
  assert_output --partial "Kits"
  assert_output --partial "one command enables a tuned Claude team"
  run cat "$LAST_SEEN_VERSION_FILE"
  assert_output "$VERSION 1"
}

@test "whats-new: copy carries the version-anchored changelog link" {
  _is_tty() { return 0; }
  run _maybe_show_release_highlight
  assert_success
  # Anchored to this release's section (#v1.2.0), not the bare changelog page:
  # the /changelog page IDs each release by its version.
  assert_output --partial "cleat.sh/changelog#v1.2.0"
}

@test "whats-new: the changelog link is a clickable OSC 8 hyperlink in supporting terminals" {
  _is_tty() { return 0; }
  _supports_osc8() { return 0; }   # e.g. iTerm2 / VS Code / WezTerm
  run _maybe_show_release_highlight
  assert_success
  # OSC 8 link target is the full https URL (the visible label can be the short form).
  assert_output --partial "$(printf '\033]8;;https://cleat.sh/changelog#v1.2.0\033\\')"
}

@test "whats-new: the changelog link sits on its own line, not crammed onto the prose" {
  # The link gets its own labelled "Changelog:" line below the news, so it stays
  # scannable and the URL is unmistakable. Falsify a run-on layout: the changelog
  # line must not also carry the headline or a support-prose sentence.
  _is_tty() { return 0; }
  local out cl_line; out="$(_maybe_show_release_highlight)"
  cl_line="$(printf '%s\n' "$out" | grep -F 'cleat.sh/changelog')"
  printf '%s' "$cl_line" | grep -qF "New in v1.2.0" \
    && { echo "changelog crammed onto the headline line"; return 1; } || true
  printf '%s' "$cl_line" | grep -qF "off in one command" \
    && { echo "changelog crammed onto a support line"; return 1; } || true
}

@test "whats-new: a trailing blank separates the highlight from the bring-up block" {
  _is_tty() { return 0; }
  # The highlight owns its own separation from the bring-up that follows, so the
  # bring-up needs no leading blank of its own. Append a sentinel: $(...) strips
  # only the FINAL newline, so the trailing `echo ""` survives as an empty line
  # immediately before SENTINEL. Dropping it makes the 'changelog' line sit right
  # against SENTINEL (falsifiable).
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

@test "whats-new: opens its own blank line above the news when nothing preceded it" {
  # The bug (v0.16.1): the news leaned on the Docker pressure advisory's trailing
  # blank for separation. When that advisory was silent OR its fix block was gated
  # out, the "New in …" line sat flush against whatever was above it (the shell
  # prompt, or a warning). With no preceding on-start notice (_ONSTART_GAP_OPEN
  # unset/0) the highlight must open the gap itself.
  _is_tty() { return 0; }
  _ONSTART_GAP_OPEN=0
  local out; out="$( { printf 'TOP\n'; _maybe_show_release_highlight; } )"
  printf '%s\n' "$out" | awk '
    /New in v/ { print (prev ~ /^[[:space:]]*$/ ? "BLANK" : "FLUSH"); f=1; exit }
    { prev=$0 } END { if (!f) print "NOTFOUND" }' > "$TEST_TEMP/lead.txt"
  run cat "$TEST_TEMP/lead.txt"
  assert_output "BLANK"
}

@test "whats-new: does NOT add a second blank when an on-start notice already opened the gap" {
  # The flip side: when a preceding notice (the Docker pressure block) already
  # printed its own trailing blank it sets _ONSTART_GAP_OPEN=1, and the highlight
  # must NOT add a second: exactly one blank above the news, never two.
  _is_tty() { return 0; }
  _ONSTART_GAP_OPEN=1
  # PREV, one blank (the notice's), then the highlight.
  local out; out="$( { printf 'PREV\n'; printf '\n'; _maybe_show_release_highlight; } )"
  printf '%s\n' "$out" | awk '
    /New in v/ { print (prev2 ~ /^[[:space:]]*$/ ? "DOUBLE" : "SINGLE"); f=1; exit }
    { prev2=prev; prev=$0 } END { if (!f) print "NOTFOUND" }' > "$TEST_TEMP/dbl.txt"
  run cat "$TEST_TEMP/dbl.txt"
  assert_output "SINGLE"
}

@test "whats-new: firing the highlight opens the gap so the next on-start line doesn't double the blank" {
  # The highlight owns a trailing blank, so it must flag _ONSTART_GAP_OPEN like the
  # pressure block does. Without it, a post-upgrade start with a well-sized VM
  # (pressure check silent) doubled the blank before the "Docker tuned"/swap line.
  # Call directly (not `run`) so the global mutation is observable in this shell.
  _is_tty() { return 0; }
  _ONSTART_GAP_OPEN=0
  _maybe_show_release_highlight >/dev/null
  [ "$_ONSTART_GAP_OPEN" = "1" ]
}

@test "whats-new: a silent highlight does NOT open the gap" {
  # If the highlight printed nothing (cap reached), it must not claim a gap it
  # never opened, or the next line would skip a leading blank it actually needs.
  _is_tty() { return 0; }
  echo "$VERSION $RELEASE_HIGHLIGHT_MAX_SHOWS" > "$LAST_SEEN_VERSION_FILE"
  _ONSTART_GAP_OPEN=0
  _maybe_show_release_highlight >/dev/null
  [ "$_ONSTART_GAP_OPEN" = "0" ]
}

@test "whats-new: exactly one blank separates a real preceding pressure advisory from the news" {
  # End-to-end of the on-start sequence: an undersized-VM advisory, then the
  # highlight: the two functions wired as main() calls them. The advisory's
  # trailing blank + the gap flag must yield ONE blank above "New in", not zero
  # (flush) and not two (double). This is the user-visible bug from img.png.
  _is_tty() { return 0; }
  _cleat_prunable_stats() { printf '0\t0'; }
  _docker_vm_memory() { echo "8589934592"; }            # 8 GiB VM (undersized)
  _host_total_memory() { echo "34359738368"; }          # 32 GiB host
  _running_memory_limits_sum() { echo "0"; }
  _is_docker_desktop() { return 0; }
  PRESSURE_CHECK_FILE="$TEST_TEMP/pressure_check"
  local out; out="$( { _maybe_check_docker_pressure; _maybe_show_release_highlight; } )"
  printf '%s\n' "$out" | awk '
    /New in v/ {
      print (prev  ~ /^[[:space:]]*$/ ? "ONE_BLANK" : "FLUSH")
      print (prev2 ~ /^[[:space:]]*$/ ? "DOUBLE" : "SINGLE")
      f=1; exit
    }
    { prev2=prev; prev=$0 } END { if (!f) print "NOTFOUND" }' > "$TEST_TEMP/sep.txt"
  run cat "$TEST_TEMP/sep.txt"
  assert_line "ONE_BLANK"
  assert_line "SINGLE"
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

@test "whats-new: STALE GUARD, silent when highlight copy is for another version" {
  _is_tty() { return 0; }
  RELEASE_HIGHLIGHT_VERSION="0.0.0"   # copy not refreshed for this VERSION
  run _maybe_show_release_highlight
  assert_success
  assert_output ""
  # Must NOT record anything: a future matching release still shows.
  [[ ! -f "$LAST_SEEN_VERSION_FILE" ]]  || return 1
}

@test "whats-new: silent on a non-interactive (non-TTY) run" {
  # Do NOT override _is_tty, under bats it is false. Scripts/pipes see nothing.
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
  # An accidental `read` would swallow SENTINEL and this would fail, falsifiable,
  # unlike asserting on a "[Y/n]" string the function can never emit.
  local rest=""
  { _maybe_show_release_highlight >/dev/null; rest=$(cat); } <<< "SENTINEL"
  assert_equal "$rest" "SENTINEL"
}

@test "whats-new: records the bumped count BEFORE printing (Ctrl-C / under-count safe)" {
  _is_tty() { return 0; }
  # Stub the first visible line to assert the state file ALREADY holds the bumped
  # count when output begins. Moving the write after the print (a plausible
  # refactor) makes this fail, pinning the "record before print" invariant.
  info() { [[ "$(cat "$LAST_SEEN_VERSION_FILE" 2>/dev/null)" == "$VERSION 1" ]] || echo "ORDER_VIOLATION"; }
  run _maybe_show_release_highlight
  assert_success
  refute_output --partial "ORDER_VIOLATION"
}

@test "whats-new: silent (no permanent nag) when the state can't be persisted" {
  _is_tty() { return 0; }
  # Read-only install dir: the bumped count can't be written, so it must NOT
  # print: otherwise the note would re-show on every single launch.
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
