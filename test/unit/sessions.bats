#!/usr/bin/env bats
# `cleat sessions`: list, rename and delete Claude Code's per-conversation
# transcripts for this project+box.
#
# The Claude Code terminal CLI has no way to delete ONE conversation (only
# `claude project purge`, which takes a whole project, and an age-based sweep),
# and cleat already owns the directory the transcripts land in. See
# concept/43-session-management.md.
#
# Most of what is tested here is refusal. The session directory also holds the
# user's auto-memory, cleat's own bind-mounted history.jsonl and whatever
# scratch directories agents made, so every guard that keeps a delete inside the
# strict UUID allowlist earns a test and a mutation entry.

load "../setup"

setup() {
  _common_setup
  use_docker_stub
  source_cli
  _has_unicode() { return 1; }
  SDIR="$TEST_TEMP/home/.claude/projects/proj-deadbeef"
  mkdir -p "$SDIR"
  # The trash is host-only, outside the session dir the box mounts.
  TRASH="$CLEAT_CONFIG_DIR/session-trash/proj-deadbeef"
}
teardown() { _common_teardown; }

U1="11111111-1111-2222-3333-444444444444"
U2="22222222-1111-2222-3333-444444444444"

# A session with a transcript and, optionally, a title record.
_mk_session() {
  local uuid="$1" title="${2:-}"
  {
    printf '{"type":"mode","mode":"normal","sessionId":"%s"}\n' "$uuid"
    printf '{"type":"user","message":{"role":"user","content":"hi"},"sessionId":"%s"}\n' "$uuid"
    if [[ -n "$title" ]]; then
      printf '{"type":"custom-title","customTitle":"%s","sessionId":"%s"}\n' "$title" "$uuid"
    fi
  } > "$SDIR/${uuid}.jsonl"
}

_tui_keys() {   # last arg is the over-read fallback, so a buggy loop cannot hang the suite
  printf '%s\n' "$@" > "$TEST_TEMP/keys"
  _read_keypress() {
    local f="$TEST_TEMP/keys" k
    k="$(head -n1 "$f" 2>/dev/null)"
    tail -n +2 "$f" > "$f.rest" 2>/dev/null && mv "$f.rest" "$f" 2>/dev/null
    [ -n "$k" ] && echo "$k" || echo QUIT
  }
}

# ── the UUID allowlist ─────────────────────────────────────────────────────

@test "sessions: accepts a real session uuid" {
  run _sessions_is_uuid "$U1"
  assert_success
}

@test "sessions: rejects history (the file that shares the directory)" {
  run _sessions_is_uuid "history"
  assert_failure
}

@test "sessions: rejects an uppercase uuid" {
  run _sessions_is_uuid "AAAAAAAA-1111-2222-3333-444444444444"
  assert_failure
}

@test "sessions: rejects a uuid with a path traversal glued on" {
  run _sessions_is_uuid "../../etc/passwd"
  assert_failure
}

@test "sessions: rejects a short hex string" {
  run _sessions_is_uuid "deadbeef"
  assert_failure
}

# ── the scan ───────────────────────────────────────────────────────────────

@test "sessions: scan lists a session" {
  _mk_session "$U1"
  run _sessions_scan "$SDIR"
  assert_success
  assert_output --partial "$U1"
}

@test "sessions: scan never lists history.jsonl" {
  _mk_session "$U1"
  printf '{"display":"/model","sessionId":"x"}\n' > "$SDIR/history.jsonl"
  run _sessions_scan "$SDIR"
  assert_success
  refute_output --partial "history"
}

@test "sessions: scan ignores the auto-memory directory and agent scratch" {
  _mk_session "$U1"
  mkdir -p "$SDIR/memory" "$SDIR/hero-work"
  echo "keep me" > "$SDIR/memory/MEMORY.md"
  run _sessions_scan "$SDIR"
  assert_success
  refute_output --partial "memory"
  refute_output --partial "hero-work"
}

@test "sessions: scan of an empty directory prints nothing" {
  run _sessions_scan "$SDIR"
  assert_success
  assert_output ""
}

@test "sessions: scan of a missing directory prints nothing and succeeds" {
  run _sessions_scan "$TEST_TEMP/nope"
  assert_success
  assert_output ""
}

@test "sessions: scan is sorted newest first" {
  _mk_session "$U1"
  _mk_session "$U2"
  touch -t 202001010000 "$SDIR/${U1}.jsonl"
  run _sessions_scan_sorted "$SDIR"
  assert_success
  [[ "$(printf '%s\n' "$output" | head -1)" == *"$U2"* ]]
}

# ── title resolution ───────────────────────────────────────────────────────

@test "sessions: title comes from a custom-title record" {
  _mk_session "$U1" "my session"
  run _sessions_title_for "$SDIR" "$U1"
  assert_output "my session"
}

@test "sessions: the LAST custom-title record wins" {
  _mk_session "$U1" "first"
  printf '{"type":"custom-title","customTitle":"second","sessionId":"%s"}\n' "$U1" >> "$SDIR/${U1}.jsonl"
  run _sessions_title_for "$SDIR" "$U1"
  assert_output "second"
}

@test "sessions: a transcript custom-title beats a disagreeing sidecar" {
  _mk_session "$U1" "from transcript"
  mkdir -p "$SDIR/$U1"
  printf '{"customTitle":"from sidecar"}\n' > "$SDIR/$U1/custom-title.json"
  run _sessions_title_for "$SDIR" "$U1"
  assert_output "from transcript"
}

@test "sessions: the sidecar is used when the transcript has no title" {
  _mk_session "$U1"
  mkdir -p "$SDIR/$U1"
  printf '{"customTitle":"from sidecar"}\n' > "$SDIR/$U1/custom-title.json"
  run _sessions_title_for "$SDIR" "$U1"
  assert_output "from sidecar"
}

@test "sessions: ai-title is used when there is no custom title" {
  _mk_session "$U1"
  printf '{"type":"ai-title","aiTitle":"Generated name","sessionId":"%s"}\n' "$U1" >> "$SDIR/${U1}.jsonl"
  run _sessions_title_for "$SDIR" "$U1"
  assert_output "Generated name"
}

@test "sessions: a custom title outranks an ai-title in the same file" {
  _mk_session "$U1"
  printf '{"type":"ai-title","aiTitle":"Generated name","sessionId":"%s"}\n' "$U1" >> "$SDIR/${U1}.jsonl"
  printf '{"type":"custom-title","customTitle":"Mine","sessionId":"%s"}\n' "$U1" >> "$SDIR/${U1}.jsonl"
  run _sessions_title_for "$SDIR" "$U1"
  assert_output "Mine"
}

@test "sessions: lastPrompt is the fallback below ai-title" {
  _mk_session "$U1"
  printf '{"type":"last-prompt","lastPrompt":"run the thing","sessionId":"%s"}\n' "$U1" >> "$SDIR/${U1}.jsonl"
  run _sessions_title_for "$SDIR" "$U1"
  assert_output "run the thing"
}

@test "sessions: a session with nothing to name it lists as (no title)" {
  _mk_session "$U1"
  run _sessions_title_for "$SDIR" "$U1"
  assert_output "(no title)"
}

@test "sessions: a title past the tail window is not read" {
  # The scan reads a fixed window so a 118 MB transcript costs the same as a
  # small one. A record buried behind more than that window must not be found.
  _mk_session "$U1" "buried"
  head -c 200000 /dev/zero | tr '\0' 'x' | sed 's/^/{"pad":"/; s/$/"}/' >> "$SDIR/${U1}.jsonl"
  run _sessions_title_for "$SDIR" "$U1"
  assert_output "(no title)"
}

@test "sessions: a torn final record is dropped, not rendered" {
  # The host and a running box share this inode, so a window can cut a record
  # mid-string. No closing quote means no match, and the next source answers.
  _mk_session "$U1"
  printf '{"type":"ai-title","aiTitle":"good","sessionId":"%s"}\n' "$U1" >> "$SDIR/${U1}.jsonl"
  printf '{"type":"custom-title","customTitle":"torn' >> "$SDIR/${U1}.jsonl"
  run _sessions_title_for "$SDIR" "$U1"
  assert_output "good"
}

@test "sessions: an escaped quote inside a title survives extraction" {
  _mk_session "$U1"
  printf '{"type":"custom-title","customTitle":"say \\"hi\\" now","sessionId":"%s"}\n' "$U1" >> "$SDIR/${U1}.jsonl"
  run _sessions_title_for "$SDIR" "$U1"
  assert_output 'say "hi" now'
}

@test "sessions: an escaped backslash before an n is not turned into a newline" {
  # A global replace of \n would make C:\new two lines. The unescaper walks
  # left to right precisely so it cannot.
  _mk_session "$U1"
  printf '{"type":"custom-title","customTitle":"C:\\\\new","sessionId":"%s"}\n' "$U1" >> "$SDIR/${U1}.jsonl"
  run _sessions_title_for "$SDIR" "$U1"
  assert_output 'C:\new'
  [ "${#lines[@]}" -eq 1 ]
}

# ── render safety ──────────────────────────────────────────────────────────

@test "sessions: a newline in a title cannot split the row" {
  run _sessions_safe_str "$(printf 'one\ntwo')"
  assert_success
  assert_output "onetwo"
  [ "${#lines[@]}" -eq 1 ]
}

@test "sessions: an escape byte is stripped from a title" {
  run _sessions_safe_str "$(printf 'a\033[31mred')"
  assert_success
  refute_output --partial "$(printf '\033')"
}

@test "sessions: a carriage return is stripped so a row cannot overwrite another" {
  run _sessions_safe_str "$(printf 'real\rFAKE')"
  assert_success
  assert_output "realFAKE"
}

@test "sessions: a UTF-8 title survives sanitizing" {
  # The counter-test to _sanitize_repo_str, which strips \200-\237 and would
  # eat continuation bytes.
  run _sessions_safe_str "héllo → 日本"
  assert_success
  assert_output "héllo → 日本"
}

# ── the viewport ───────────────────────────────────────────────────────────
#
# The frame is page + 3 physical lines (rows, counter, blank, hint) and the page
# is min(terminal rows - chrome, total), floored at 1. Tests pin the geometry by
# overriding _term_rows/_term_cols rather than by exporting LINES, because
# ncurses use_env makes an exported LINES override the real ioctl and the helper
# deliberately does not consult it.

_draw_lines() {   # physical line count of a draw, blanks included
  # bats' ${#lines[@]} DROPS empty lines: `run printf 'a\n\n\nb\n'` reports 2,
  # not 4. A frame that emitted a stray blank would therefore pass every
  # line-count test while walking the block down the screen on each keypress,
  # which is the one rendering bug that actually matters here.
  "$@" > "$TEST_TEMP/frame.out" 2>/dev/null
  wc -l < "$TEST_TEMP/frame.out" | tr -d ' '
}

_mk_rows() {   # $1 = how many rows to write into the rowfile
  local n="$1" i=0
  : > "$TEST_TEMP/rows"
  while [[ $i -lt $n ]]; do
    printf '%s\t%s\t%08d-1111-2222-3333-444444444444\trow %s\n' "1789000000" "1024" "$i" "$i" >> "$TEST_TEMP/rows"
    i=$(( i + 1 ))
  done
}

_pin_geom() { _term_rows() { echo "${1:-24}"; }; _term_cols() { echo "${2:-100}"; }; }

@test "sessions: the frame is page + 3 lines for a short list" {
  _term_rows() { echo 24; }; _term_cols() { echo 100; }
  _mk_rows 3
  run _sessions_picker_draw 0 0 "$TEST_TEMP/rows"
  assert_success
  # 3 sessions fit well inside 24-8=16, so the page is the list itself.
  [ "$(_draw_lines _sessions_picker_draw 0 0 "$TEST_TEMP/rows")" -eq 6 ]
}

@test "sessions: the frame fills the terminal height when the list is longer" {
  _term_rows() { echo 24; }; _term_cols() { echo 100; }
  _mk_rows 40
  run _sessions_picker_draw 0 0 "$TEST_TEMP/rows"
  assert_success
  # 24 rows - 8 of chrome = a 16-row viewport, + counter + blank + hint.
  [ "$(_draw_lines _sessions_picker_draw 0 0 "$TEST_TEMP/rows")" -eq 19 ]
}

@test "sessions: a taller terminal gets a taller viewport" {
  _term_rows() { echo 50; }; _term_cols() { echo 100; }
  _mk_rows 60
  run _sessions_picker_draw 0 0 "$TEST_TEMP/rows"
  assert_success
  [ "$(_draw_lines _sessions_picker_draw 0 0 "$TEST_TEMP/rows")" -eq 45 ]
}

@test "sessions: a very short terminal still draws a usable frame" {
  # 6 rows cannot hold the chrome, so the viewport floors at one row rather
  # than going negative and breaking the redraw arithmetic.
  _term_rows() { echo 6; }; _term_cols() { echo 100; }
  _mk_rows 40
  run _sessions_picker_draw 0 0 "$TEST_TEMP/rows"
  assert_success
  [ "$(_draw_lines _sessions_picker_draw 0 0 "$TEST_TEMP/rows")" -eq 4 ]
}

@test "sessions: an empty list still draws a well-formed frame" {
  _term_rows() { echo 24; }; _term_cols() { echo 100; }
  : > "$TEST_TEMP/rows"
  run _sessions_picker_draw 0 0 "$TEST_TEMP/rows"
  assert_success
  [ "$(_draw_lines _sessions_picker_draw 0 0 "$TEST_TEMP/rows")" -eq 4 ]
}

@test "sessions: the frame never blanks a line before rewriting it" {
  # This is the blink. \033[2K erases the whole line and leaves it empty until
  # the replacement text arrives, so there was always one blank row on screen
  # during a redraw. \033[K after the text clears only the tail of a line that
  # has already been overwritten.
  _term_rows() { echo 24; }; _term_cols() { echo 100; }
  _mk_rows 5
  run _sessions_picker_draw 0 0 "$TEST_TEMP/rows"
  assert_success
  refute_output --partial "$(printf '\033')[2K"
}

@test "sessions: every frame line ends with an erase-to-end-of-line" {
  _term_rows() { echo 24; }; _term_cols() { echo 100; }
  _mk_rows 5
  run _sessions_picker_draw 0 0 "$TEST_TEMP/rows"
  assert_success
  local l
  for l in "${lines[@]}"; do
    [[ "$l" == *"$(printf '\033')[K" ]]
  done
}

@test "sessions: a long title is truncated to the terminal width" {
  _term_rows() { echo 24; }; _term_cols() { echo 80; }
  local long
  long="$(printf 'L%.0s' $(seq 1 400))"
  printf '1789000000\t1024\t%s\t%s\n' "$U1" "$long" > "$TEST_TEMP/rows"
  run _sessions_picker_draw 0 0 "$TEST_TEMP/rows"
  assert_success
  # ${#s} counts BYTES in the C locale, and the cursor and the ellipsis are
  # 3-byte characters painting ONE column each. Fold them to one byte so this
  # measures display width and not storage.
  local plain
  plain="$(printf '%s' "${lines[0]}" | sed 's/'"$(printf '\033')"'\[[0-9;]*[mK]//g; s/▸/>/g; s/…/./g')"
  [ "${#plain}" -le 80 ]
}

@test "sessions: a long title is truncated at a narrow terminal too" {
  _term_rows() { echo 24; }; _term_cols() { echo 40; }
  local long
  long="$(printf 'L%.0s' $(seq 1 400))"
  printf '1789000000\t1024\t%s\t%s\n' "$U1" "$long" > "$TEST_TEMP/rows"
  run _sessions_picker_draw 0 0 "$TEST_TEMP/rows"
  assert_success
  local plain
  plain="$(printf '%s' "${lines[0]}" | sed 's/'"$(printf '\033')"'\[[0-9;]*[mK]//g; s/▸/>/g; s/…/./g')"
  [ "${#plain}" -le 40 ]
}

@test "sessions: the frame costs no subprocesses once the rows are loaded" {
  # The blink was 115 forks per frame. A shim on PATH that would be picked up by
  # any stray fork proves the hot path is pure bash now.
  _term_rows() { echo 24; }; _term_cols() { echo 100; }
  _mk_rows 10
  _sessions_load_rows "$TEST_TEMP/rows"
  _sessions_measure "$_SESS_N"
  local before after
  date()  { echo "FORKED-DATE"; }
  sed()   { echo "FORKED-SED"; }
  awk()   { echo "FORKED-AWK"; }
  run _sessions_frame 0 0 "$_SESS_PAGE" "$_SESS_COLS" "$_SESS_N"
  assert_success
  refute_output --partial "FORKED"
}

# ── geometry helpers ───────────────────────────────────────────────────────

@test "sessions: _term_size falls back to 24 80 with no terminal" {
  command() { return 1; }
  run _term_size
  assert_output "24 80"
}

@test "sessions: _term_size rejects a zero size from an unsized pty" {
  stty() { echo "0 0"; }
  command() { return 1; }
  run _term_size
  assert_output "24 80"
}

@test "sessions: _term_size rejects a leading-zero value" {
  # A leading zero reaches (( )) as octal and would kill the binary under set -e.
  stty() { echo "024 080"; }
  command() { return 1; }
  run _term_size
  assert_output "24 80"
}

@test "sessions: _term_size prefers the live stty reading over tput" {
  # tput is poisoned by an exported LINES (ncurses use_env), so a resize would
  # never be seen if tput came first.
  stty() { echo "44 133"; }
  run _term_size
  assert_output "44 133"
}

@test "sessions: _term_rows and _term_cols clamp a tiny terminal" {
  stty() { echo "2 10"; }
  run _term_rows
  assert_output "5"
  run _term_cols
  assert_output "40"
}

@test "sessions: _term_rows and _term_cols clamp an enormous terminal" {
  stty() { echo "9000 9000"; }
  run _term_rows
  assert_output "200"
  run _term_cols
  assert_output "200"
}

# ── resize and the cursor clamp ────────────────────────────────────────────

@test "sessions: the viewport shrinks with the terminal" {
  _term_cols() { echo 100; }
  _term_rows() { echo 30; }
  _sessions_measure 50
  [ "$_SESS_PAGE" -eq 22 ]
  _term_rows() { echo 14; }
  _sessions_measure 50
  [ "$_SESS_PAGE" -eq 6 ]
}

@test "sessions: the viewport never exceeds the number of sessions" {
  _term_cols() { echo 100; }
  _term_rows() { echo 60; }
  _sessions_measure 4
  [ "$_SESS_PAGE" -eq 4 ]
}

@test "sessions: a shrunk viewport pulls the cursor back into view" {
  # The dangerous case. Without the clamp a window shrink leaves the cursor
  # below the last drawn row: the highlight is gone, and Enter then opens the
  # delete screen for a session the user never saw selected.
  _term_cols() { echo 100; }
  _term_rows() { echo 30; }
  _sessions_measure 50
  _SESS_CURSOR=21
  _SESS_OFFSET=0
  _sessions_clamp 50
  [ "$_SESS_CURSOR" -lt $(( _SESS_OFFSET + _SESS_PAGE )) ]
  _term_rows() { echo 14; }
  _sessions_measure 50
  _sessions_clamp 50
  [ "$_SESS_CURSOR" -ge "$_SESS_OFFSET" ]
  [ "$_SESS_CURSOR" -lt $(( _SESS_OFFSET + _SESS_PAGE )) ]
}

@test "sessions: a grown viewport never leaves the offset past the end" {
  _term_cols() { echo 100; }
  _term_rows() { echo 14; }
  _sessions_measure 20
  _SESS_CURSOR=19
  _SESS_OFFSET=14
  _sessions_clamp 20
  _term_rows() { echo 40; }
  _sessions_measure 20
  _sessions_clamp 20
  [ "$_SESS_OFFSET" -ge 0 ]
  [ $(( _SESS_OFFSET + _SESS_PAGE )) -le 20 ]
}

@test "sessions: the clamp holds the invariant under a resize fuzz" {
  _term_cols() { echo 100; }
  local total=27 h i=0
  _SESS_CURSOR=0
  _SESS_OFFSET=0
  while [[ $i -lt 60 ]]; do
    h=$(( 6 + (i * 7) % 40 ))
    eval "_term_rows() { echo $h; }"
    _sessions_measure "$total"
    _SESS_CURSOR=$(( (i * 13) % total ))
    _sessions_clamp "$total"
    [ "$_SESS_OFFSET" -ge 0 ]
    [ "$_SESS_CURSOR" -ge "$_SESS_OFFSET" ]
    [ "$_SESS_CURSOR" -lt $(( _SESS_OFFSET + _SESS_PAGE )) ]
    [ "$_SESS_CURSOR" -lt "$total" ]
    i=$(( i + 1 ))
  done
}

@test "sessions: a resize marks the geometry dirty and a measure clears it" {
  _term_cols() { echo 100; }; _term_rows() { echo 24; }
  _SESS_GEOM_DIRTY=1
  _sessions_measure 5
  [ "$_SESS_GEOM_DIRTY" -eq 0 ]
}

# ── the action screen ──────────────────────────────────────────────────────

@test "sessions: the action screen draws a constant line count at every width" {
  local w c n
  for w in 30 40 57 80 120; do
    for c in 0 1 2; do
      run _sessions_action_draw "$c" "$w"
      assert_success
      # A LITERAL 4, not $_SESSIONS_ACTION_LINES: reading the constant out of
      # the code under test makes the assertion agree with whatever it says.
      [ "$(_draw_lines _sessions_action_draw "$c" "$w")" -eq 4 ]
    done
  done
}

@test "sessions: the action screen never exceeds the terminal width" {
  # Its widest row is 57 columns. Below that every row wrapped into two physical
  # lines while the reposition moved up four logical ones, so the menu walked
  # down the screen exactly the way an over-wide list row does.
  local w widest
  for w in 30 40 57 80; do
    widest="$(_sessions_action_draw 0 "$w" | sed 's/'"$(printf '\033')"'\[[0-9;]*[mK]//g; s/▸/>/g; s/…/./g' | awk '{ if (length($0) > m) m = length($0) } END { print m + 0 }')"
    [ "$widest" -le "$w" ]
  done
}

# ── id resolution ──────────────────────────────────────────────────────────

@test "sessions: a full uuid resolves" {
  _mk_session "$U1"
  run _sessions_resolve_id "$SDIR" "$U1"
  assert_success
  assert_output "$U1"
}

@test "sessions: an 8-character prefix resolves" {
  _mk_session "$U1"
  run _sessions_resolve_id "$SDIR" "11111111"
  assert_success
  assert_output "$U1"
}

@test "sessions: a prefix shorter than 8 is refused" {
  # Not a convenience limit. A short prefix is how you delete the wrong
  # conversation, and the list is re-sorted by mtime so there is no stable
  # short name to fall back on.
  _mk_session "$U1"
  run _sessions_resolve_id "$SDIR" "1111"
  assert_failure
}

@test "sessions: an ambiguous prefix is refused rather than guessed" {
  _mk_session "aaaaaaaa-1111-2222-3333-444444444444"
  _mk_session "aaaaaaaa-1111-2222-3333-555555555555"
  run _sessions_resolve_id "$SDIR" "aaaaaaaa"
  assert_failure
}

@test "sessions: a non-hex id is refused" {
  _mk_session "$U1"
  run _sessions_resolve_id "$SDIR" "../../etc/passwd"
  assert_failure
}

@test "sessions: history is never resolvable as an id" {
  printf 'x\n' > "$SDIR/history.jsonl"
  run _sessions_resolve_id "$SDIR" "history.jsonl"
  assert_failure
}

# ── physical containment ───────────────────────────────────────────────────

@test "sessions: containment accepts a transcript in the key dir" {
  _mk_session "$U1"
  run _sessions_path_under_key "$SDIR/${U1}.jsonl" "$SDIR"
  assert_success
}

@test "sessions: containment refuses a traversal out of the key dir" {
  # The victim must be a REAL sibling of the key dir. Pointing at a path that
  # does not exist would make this pass on the `cd -P` failure instead of on
  # the parent comparison, which is the guard being tested.
  mkdir -p "$SDIR/../victim"
  : > "$SDIR/../victim/prize"
  run _sessions_path_under_key "$SDIR/../victim/prize" "$SDIR"
  assert_failure
}

@test "sessions: containment refuses a symlink" {
  : > "$TEST_TEMP/elsewhere"
  ln -s "$TEST_TEMP/elsewhere" "$SDIR/${U1}.jsonl"
  run _sessions_path_under_key "$SDIR/${U1}.jsonl" "$SDIR"
  assert_failure
}

@test "sessions: containment refuses history.jsonl by name" {
  : > "$SDIR/history.jsonl"
  run _sessions_path_under_key "$SDIR/history.jsonl" "$SDIR"
  assert_failure
}

@test "sessions: containment refuses a relative path" {
  run _sessions_path_under_key "${U1}.jsonl" "$SDIR"
  assert_failure
}

@test "sessions: containment refuses a nested path two levels down" {
  # Both objects a session owns sit exactly one level under the key dir, so
  # parent-must-BE-root is the right test, not parent-is-somewhere-below.
  mkdir -p "$SDIR/sub"
  : > "$SDIR/sub/${U1}.jsonl"
  run _sessions_path_under_key "$SDIR/sub/${U1}.jsonl" "$SDIR"
  assert_failure
}

# ── the live gate ──────────────────────────────────────────────────────────

@test "sessions: a down daemon refuses the write rather than assuming idle" {
  # "A delete must never run on a probe that cannot answer." A down daemon
  # cannot say whether the box is running.
  _daemon_up() { return 1; }
  run _sessions_live_gate "cleat-x" "main"
  assert_failure
  assert_output --partial "Docker is not responding"
}

@test "sessions: a box with a live agent refuses the write" {
  _daemon_up() { return 0; }
  container_exists() { return 0; }
  is_running() { return 0; }
  _box_has_live_agent() { return 0; }
  run _sessions_live_gate "cleat-x" "main"
  assert_failure
  assert_output --partial "live Claude session"
}

@test "sessions: a stopped box passes the live gate" {
  _daemon_up() { return 0; }
  container_exists() { return 0; }
  is_running() { return 1; }
  _box_has_live_agent() { return 0; }
  run _sessions_live_gate "cleat-x" "main"
  assert_success
}

@test "sessions: no container at all passes the live gate" {
  _daemon_up() { return 0; }
  container_exists() { return 1; }
  run _sessions_live_gate "cleat-x" "main"
  assert_success
}

# ── delete ─────────────────────────────────────────────────────────────────

_pass_gates() {
  _daemon_up() { return 0; }
  container_exists() { return 1; }
  CLEAT_RUN_DIR="$TEST_TEMP/run"
}

@test "sessions: delete moves the transcript AND its sidecar to the trash" {
  # The sidecar holds subagent transcripts and tool results and is several
  # times larger than the transcript, so a .jsonl-only delete would silently
  # leave most of the bytes behind.
  _pass_gates
  _mk_session "$U1" "doomed"
  mkdir -p "$SDIR/$U1/subagents"
  echo "payload" > "$SDIR/$U1/subagents/a.jsonl"
  run _sessions_do_delete "$SDIR" "$U1" "$TEST_TEMP/proj" "main" "cleat-x" 1
  assert_success
  [ ! -e "$SDIR/${U1}.jsonl" ]
  [ ! -e "$SDIR/$U1" ]
  [ -f "$TRASH/"*"-$U1/${U1}.jsonl" ]
  [ -f "$TRASH/"*"-$U1/$U1/subagents/a.jsonl" ]
}

@test "sessions: delete is a move, not an unlink" {
  _pass_gates
  _mk_session "$U1" "doomed"
  run _sessions_do_delete "$SDIR" "$U1" "$TEST_TEMP/proj" "main" "cleat-x" 1
  assert_success
  run cat "$TRASH/"*"-$U1/${U1}.jsonl"
  assert_output --partial "doomed"
}

@test "sessions: delete takes a box session's per-box session-env with it" {
  # session-env is a per-box private dir, because the host's own Claude Code
  # runs the hook env files in it. A box session's copy therefore lives under
  # the run dir, and a delete that looked only at the host path left it behind.
  _pass_gates
  _mk_session "$U1"
  mkdir -p "$CLEAT_RUN_DIR/cleat-x/home/session-env/$U1"
  echo "box env" > "$CLEAT_RUN_DIR/cleat-x/home/session-env/$U1/sessionstart-hook-0.sh"
  run _sessions_do_delete "$SDIR" "$U1" "$TEST_TEMP/proj" "main" "cleat-x" 1
  assert_success
  [ ! -e "$CLEAT_RUN_DIR/cleat-x/home/session-env/$U1" ] || { echo "the per-box session-env was left behind"; return 1; }
  run grep -rl "box env" "$TRASH"
  assert_success
}

@test "sessions: delete leaves the auto-memory and history.jsonl alone" {
  _pass_gates
  _mk_session "$U1"
  mkdir -p "$SDIR/memory"
  echo "PRECIOUS" > "$SDIR/memory/MEMORY.md"
  printf '{"display":"/model"}\n' > "$SDIR/history.jsonl"
  run _sessions_do_delete "$SDIR" "$U1" "$TEST_TEMP/proj" "main" "cleat-x" 1
  assert_success
  run cat "$SDIR/memory/MEMORY.md"
  assert_output "PRECIOUS"
  [ -f "$SDIR/history.jsonl" ]
}

@test "sessions: delete leaves a sibling session alone" {
  _pass_gates
  _mk_session "$U1"
  _mk_session "$U2" "keep me"
  run _sessions_do_delete "$SDIR" "$U1" "$TEST_TEMP/proj" "main" "cleat-x" 1
  assert_success
  [ -f "$SDIR/${U2}.jsonl" ]
}

@test "sessions: delete refuses a symlinked transcript and touches the target" {
  _pass_gates
  echo "VICTIM" > "$TEST_TEMP/victim"
  ln -s "$TEST_TEMP/victim" "$SDIR/${U1}.jsonl"
  run _sessions_do_delete "$SDIR" "$U1" "$TEST_TEMP/proj" "main" "cleat-x" 1
  assert_failure
  run cat "$TEST_TEMP/victim"
  assert_output "VICTIM"
}

@test "sessions: delete refuses when the daemon cannot answer, even with --yes" {
  # --yes skips the PROMPT. It must never skip a gate: this is the flag that
  # turned a bad probe into mass deletion in the 2026-07-31 fork-prune incident.
  _daemon_up() { return 1; }
  _mk_session "$U1"
  run _sessions_do_delete "$SDIR" "$U1" "$TEST_TEMP/proj" "main" "cleat-x" 1
  assert_failure
  [ -f "$SDIR/${U1}.jsonl" ]
}

@test "sessions: delete refuses when a live agent holds the box, even with --yes" {
  _daemon_up() { return 0; }
  container_exists() { return 0; }
  is_running() { return 0; }
  _box_has_live_agent() { return 0; }
  _mk_session "$U1"
  run _sessions_do_delete "$SDIR" "$U1" "$TEST_TEMP/proj" "main" "cleat-x" 1
  assert_failure
  [ -f "$SDIR/${U1}.jsonl" ]
}

@test "sessions: delete with no tty and no --yes discloses and deletes nothing" {
  _pass_gates
  _is_interactive() { return 1; }
  _mk_session "$U1" "safe"
  run _sessions_do_delete "$SDIR" "$U1" "$TEST_TEMP/proj" "main" "cleat-x" 0
  assert_success
  assert_output --partial "Nothing was deleted"
  assert_output --partial "--yes"
  [ -f "$SDIR/${U1}.jsonl" ]
}

@test "sessions: a declined confirmation deletes nothing" {
  _pass_gates
  _is_interactive() { return 0; }
  _ask_yn() { printf -v "$1" '%s' 'n'; }
  _mk_session "$U1"
  run _sessions_do_delete "$SDIR" "$U1" "$TEST_TEMP/proj" "main" "cleat-x" 0
  assert_success
  assert_output --partial "Kept."
  [ -f "$SDIR/${U1}.jsonl" ]
}

@test "sessions: a bare Enter at the confirmation deletes nothing" {
  # The prompt is [y/N]: empty must mean no. _ask_yn also yields "n" on EOF.
  _pass_gates
  _is_interactive() { return 0; }
  _ask_yn() { printf -v "$1" '%s' ''; }
  _mk_session "$U1"
  run _sessions_do_delete "$SDIR" "$U1" "$TEST_TEMP/proj" "main" "cleat-x" 0
  assert_success
  [ -f "$SDIR/${U1}.jsonl" ]
}

@test "sessions: the confirmation names the immutable id, not just the title" {
  # A hostile title must not be able to decide which row the user thinks they
  # are confirming.
  _pass_gates
  _is_interactive() { return 0; }
  _ask_yn() { printf -v "$1" '%s' 'n'; }
  _mk_session "$U1" "innocent"
  run _sessions_do_delete "$SDIR" "$U1" "$TEST_TEMP/proj" "main" "cleat-x" 0
  assert_output --partial "11111111"
}

@test "sessions: a transcript that changed since the scan aborts the delete" {
  _pass_gates
  _mk_session "$U1"
  _is_interactive() { return 0; }
  _ask_yn() {
    printf -v "$1" '%s' 'y'
    printf '{"type":"user"}\n' >> "$SDIR/${U1}.jsonl"
    touch -t 203001010000 "$SDIR/${U1}.jsonl"
  }
  run _sessions_do_delete "$SDIR" "$U1" "$TEST_TEMP/proj" "main" "cleat-x" 0
  assert_failure
  assert_output --partial "changed while you were deciding"
  [ -f "$SDIR/${U1}.jsonl" ]
}

# ── restore ────────────────────────────────────────────────────────────────

@test "sessions: restore puts the transcript and its sidecar back" {
  _pass_gates
  _mk_session "$U1" "oops"
  mkdir -p "$SDIR/$U1"
  echo "payload" > "$SDIR/$U1/custom-title.json"
  _sessions_do_delete "$SDIR" "$U1" "$TEST_TEMP/proj" "main" "cleat-x" 1
  run _sessions_restore "$SDIR" "$U1"
  assert_success
  [ -f "$SDIR/${U1}.jsonl" ]
  [ -f "$SDIR/$U1/custom-title.json" ]
}

@test "sessions: restore refuses to clobber a session that came back" {
  _pass_gates
  _mk_session "$U1" "old"
  _sessions_do_delete "$SDIR" "$U1" "$TEST_TEMP/proj" "main" "cleat-x" 1
  _mk_session "$U1" "new"
  _sessions_restore "$SDIR" "$U1" || true
  run cat "$SDIR/${U1}.jsonl"
  assert_output --partial "new"
}

@test "sessions: restore fails when there is nothing in the trash" {
  run _sessions_restore "$SDIR" "$U1"
  assert_failure
}

@test "sessions: the trash sweep drops entries past the window" {
  mkdir -p "$TRASH/1-$U1"
  : > "$TRASH/1-$U1/x"
  run _sessions_trash_sweep "$SDIR"
  assert_success
  [ ! -d "$TRASH/1-$U1" ]
}

@test "sessions: the trash sweep keeps a fresh entry" {
  mkdir -p "$TRASH/$(date +%s)-$U1"
  run _sessions_trash_sweep "$SDIR"
  assert_success
  [ -d "$TRASH/$(date +%s)-$U1" ] || [ -d "$TRASH/"*"-$U1" ]
}

@test "sessions: the trash sweep ignores anything not named epoch-uuid" {
  mkdir -p "$TRASH/not-a-session"
  run _sessions_trash_sweep "$SDIR"
  assert_success
  [ -d "$TRASH/not-a-session" ]
}

# ── title validation ───────────────────────────────────────────────────────

@test "sessions: an ordinary title is accepted" {
  run _sessions_title_ok "My session 2"
  assert_success
}

@test "sessions: an empty title is refused" {
  run _sessions_title_ok ""
  assert_failure
}

@test "sessions: a 64-character title is accepted and 65 is refused" {
  run _sessions_title_ok "$(printf 'a%.0s' $(seq 1 64))"
  assert_success
  run _sessions_title_ok "$(printf 'a%.0s' $(seq 1 65))"
  assert_failure
}

@test "sessions: a double quote in a title is refused" {
  # Escaping is not attempted. bash 3.2 has no JSON encoder and jq is optional,
  # so a whitelist is the only way to guarantee the appended record is valid.
  run _sessions_title_ok 'say "hi"'
  assert_failure
}

@test "sessions: a backslash in a title is refused" {
  run _sessions_title_ok 'back\slash'
  assert_failure
}

@test "sessions: a newline in a title is refused" {
  # The injection that matters: a newline would let a title append a second,
  # forged record to the user's own transcript.
  run _sessions_title_ok "$(printf 'one\ntwo')"
  assert_failure
}

@test "sessions: a control byte in a title is refused" {
  run _sessions_title_ok "$(printf 'a\033[31m')"
  assert_failure
}

@test "sessions: a non-ASCII title is refused" {
  run _sessions_title_ok "héllo"
  assert_failure
}

@test "sessions: leading and trailing spaces are refused" {
  run _sessions_title_ok " lead"
  assert_failure
  run _sessions_title_ok "trail "
  assert_failure
}

# ── rename ─────────────────────────────────────────────────────────────────

@test "sessions: rename appends a custom-title record to the transcript" {
  _mk_session "$U1"
  run _sessions_rename_write "$SDIR" "$U1" "renamed"
  assert_success
  run tail -1 "$SDIR/${U1}.jsonl"
  assert_output '{"type":"custom-title","customTitle":"renamed","sessionId":"'"$U1"'"}'
}

@test "sessions: the appended record is compact, matching Claude's own writer" {
  # A space after a colon would still parse, but the transcript is a vendor
  # format and cleat should be indistinguishable from the vendor inside it.
  _mk_session "$U1"
  _sessions_rename_write "$SDIR" "$U1" "renamed"
  run tail -1 "$SDIR/${U1}.jsonl"
  refute_output --partial '": "'
}

@test "sessions: rename writes the sidecar too" {
  # A sidecar-only write is silently shadowed by an in-transcript record, and a
  # transcript-only write leaves the two stores disagreeing. Write both.
  _mk_session "$U1"
  _sessions_rename_write "$SDIR" "$U1" "renamed"
  run cat "$SDIR/$U1/custom-title.json"
  assert_output --partial '"customTitle":"renamed"'
}

@test "sessions: rename shows up in the next scan" {
  _mk_session "$U1" "before"
  _sessions_rename_write "$SDIR" "$U1" "after"
  run _sessions_title_for "$SDIR" "$U1"
  assert_output "after"
}

@test "sessions: rename adds a newline first when the file lacks one" {
  printf '{"type":"mode","sessionId":"%s"}' "$U1" > "$SDIR/${U1}.jsonl"
  _sessions_rename_write "$SDIR" "$U1" "renamed"
  run wc -l < "$SDIR/${U1}.jsonl"
  [ "$(printf '%s' "$output" | tr -d ' ')" = "2" ]
}

@test "sessions: rename leaves the transcript mtime alone" {
  # --continue and the /resume picker both order by transcript mtime, so an
  # unrestored rename would silently change which conversation resumes next.
  _mk_session "$U1"
  touch -t 202001010000 "$SDIR/${U1}.jsonl"
  local before
  before="$(_path_mtime "$SDIR/${U1}.jsonl")"
  _sessions_rename_write "$SDIR" "$U1" "renamed"
  run _path_mtime "$SDIR/${U1}.jsonl"
  assert_output "$before"
}

@test "sessions: rename refuses a live box" {
  _daemon_up() { return 0; }
  container_exists() { return 0; }
  is_running() { return 0; }
  _box_has_live_agent() { return 0; }
  _mk_session "$U1"
  run _sessions_do_rename "$SDIR" "$U1" "main" "cleat-x" "nope"
  assert_failure
  run _sessions_title_for "$SDIR" "$U1"
  assert_output "(no title)"
}

@test "sessions: rename refuses a bad title and writes nothing" {
  _pass_gates
  _mk_session "$U1"
  run _sessions_do_rename "$SDIR" "$U1" "main" "cleat-x" 'bad"title'
  assert_failure
  assert_output --partial "Not a usable title"
  run _sessions_title_for "$SDIR" "$U1"
  assert_output "(no title)"
}

@test "sessions: rename with no title and no tty refuses instead of prompting" {
  _pass_gates
  _is_interactive() { return 1; }
  _mk_session "$U1"
  run _sessions_do_rename "$SDIR" "$U1" "main" "cleat-x" ""
  assert_failure
  assert_output --partial "--title"
}

@test "sessions: every line of a renamed transcript is still valid JSON" {
  _mk_session "$U1"
  _sessions_rename_write "$SDIR" "$U1" "still valid"
  run awk '{ if ($0 !~ /^\{.*\}$/) { print "BAD: " $0; exit 1 } }' "$SDIR/${U1}.jsonl"
  assert_success
}

# ── the picker loop ────────────────────────────────────────────────────────

@test "sessions: q cancels the picker" {
  _mk_session "$U1"
  printf '1\t1\t%s\tone\n' "$U1" > "$TEST_TEMP/rows"
  _tui_keys QUIT
  run _sessions_picker_tui "$SDIR" "$TEST_TEMP/proj" "main" "cleat-x" "$TEST_TEMP/rows" 1
  assert_success
  assert_output --partial "Cancelled."
}

@test "sessions: an unknown key is a no-op and does not close the picker" {
  # Every printable key except q collapses to OTHER, and OTHER must fall
  # through to a redraw. Mapping it to cancel is the v1.2.0 bug.
  _mk_session "$U1"
  printf '1\t1\t%s\tone\n' "$U1" > "$TEST_TEMP/rows"
  _tui_keys OTHER OTHER QUIT
  run _sessions_picker_tui "$SDIR" "$TEST_TEMP/proj" "main" "cleat-x" "$TEST_TEMP/rows" 1
  assert_success
  [ "$(printf '%s\n' "$output" | grep -c "Cancelled.")" -eq 1 ]
}

@test "sessions: Enter opens the action screen and q there cancels" {
  _mk_session "$U1" "pick me"
  printf '1\t1\t%s\tpick me\n' "$U1" > "$TEST_TEMP/rows"
  _tui_keys ENTER QUIT
  run _sessions_picker_tui "$SDIR" "$TEST_TEMP/proj" "main" "cleat-x" "$TEST_TEMP/rows" 1
  assert_success
  assert_output --partial "pick me"
  assert_output --partial "Cancelled."
}

@test "sessions: the action screen's third row cancels" {
  _mk_session "$U1"
  printf '1\t1\t%s\tone\n' "$U1" > "$TEST_TEMP/rows"
  _tui_keys ENTER DOWN DOWN ENTER
  run _sessions_picker_tui "$SDIR" "$TEST_TEMP/proj" "main" "cleat-x" "$TEST_TEMP/rows" 1
  assert_success
  assert_output --partial "Cancelled."
  [ -f "$SDIR/${U1}.jsonl" ]
}

@test "sessions: the action screen can delete the selected session" {
  _pass_gates
  _is_interactive() { return 0; }
  _ask_yn() { printf -v "$1" '%s' 'y'; }
  _mk_session "$U1"
  printf '1\t1\t%s\tone\n' "$U1" > "$TEST_TEMP/rows"
  _tui_keys ENTER DOWN ENTER
  run _sessions_picker_tui "$SDIR" "$TEST_TEMP/proj" "main" "cleat-x" "$TEST_TEMP/rows" 1
  assert_success
  [ ! -f "$SDIR/${U1}.jsonl" ]
}

@test "sessions: the cursor cannot leave the list" {
  _mk_session "$U1"
  printf '1\t1\t%s\tone\n' "$U1" > "$TEST_TEMP/rows"
  _tui_keys UP UP DOWN DOWN QUIT
  run _sessions_picker_tui "$SDIR" "$TEST_TEMP/proj" "main" "cleat-x" "$TEST_TEMP/rows" 1
  assert_success
  assert_output --partial "Cancelled."
}

@test "sessions: the text fallback lists without a tty and offers the verbs" {
  printf '1\t1\t%s\tone\n' "$U1" > "$TEST_TEMP/rows"
  run _sessions_picker_text "$TEST_TEMP/rows" 1
  assert_success
  assert_output --partial "11111111"
  assert_output --partial "cleat session rm"
}

# ── terminal state ─────────────────────────────────────────────────────────
#
# The picker suppresses the terminal's own echo for its key loops, because any
# key byte arriving while the loop is not inside `read` is echoed by the tty and
# lands in the middle of the frame as `^[[B`. Restoring is the part that has to
# be right: a cleat that exits leaving the terminal unable to echo what you type
# would be a worse bug than the one being fixed.

@test "sessions: echo-off saves the whole termios state, not just a flag" {
  # Restoring with a bare `stty echo` would discard every other setting the
  # user had. The saved value is what `stty -g` returned.
  _is_tty() { return 0; }
  stty() { case "$1" in -g) echo "SAVED-STATE" ;; *) echo "stty $*" >> "$TEST_TEMP/stty.log" ;; esac; }
  _tui_echo_off
  [ "$_SESS_STTY" = "SAVED-STATE" ]
  run cat "$TEST_TEMP/stty.log"
  assert_output --partial "stty -echo"
}

@test "sessions: echo-restore puts the saved state back verbatim" {
  _is_tty() { return 0; }
  _SESS_STTY="SAVED-STATE"
  stty() { echo "stty $*" >> "$TEST_TEMP/stty.log"; }
  _tui_echo_restore
  run cat "$TEST_TEMP/stty.log"
  assert_output --partial "stty SAVED-STATE"
  # Cleared, so a second restore cannot re-apply a stale state.
  [ -z "$_SESS_STTY" ]
}

@test "sessions: echo-restore falls back to plain echo when nothing was saved" {
  # Belt and braces: if the save failed, the terminal must still end up usable.
  _is_tty() { return 0; }
  _SESS_STTY=""
  stty() { echo "stty $*" >> "$TEST_TEMP/stty.log"; }
  _tui_echo_restore
  run cat "$TEST_TEMP/stty.log"
  assert_output --partial "stty echo"
}

@test "sessions: echo handling is a no-op without a terminal" {
  _is_tty() { return 1; }
  stty() { echo "CALLED" >> "$TEST_TEMP/stty.log"; }
  _tui_echo_off
  _tui_echo_restore
  [ ! -f "$TEST_TEMP/stty.log" ]
}

# ── the narrow-terminal fallback ───────────────────────────────────────────

@test "sessions: a terminal too narrow for a row is refused the picker" {
  # Below the minimum every row would wrap into two physical lines while the
  # redraw moves up one, walking the block down the screen. A plain list is the
  # honest answer, not a broken picker.
  _term_size() { echo "24 30"; }
  run _sessions_too_narrow
  assert_success
}

@test "sessions: an ordinary terminal gets the picker" {
  _term_size() { echo "24 80"; }
  run _sessions_too_narrow
  assert_failure
}

@test "sessions: the narrow check reads the raw width, not the clamped one" {
  # _term_cols floors at 40 for the renderer's benefit, so asking IT whether the
  # terminal is narrow can never answer yes.
  _term_size() { echo "24 20"; }
  run _sessions_too_narrow
  assert_success
  run _term_cols
  assert_output "40"
}

@test "sessions: the minimum width is the row layout's own budget" {
  # 34 columns of fixed matter plus a title worth reading. If this constant
  # drops below the fixed matter the picker renders rows it cannot fit.
  [ "$_SESSIONS_MIN_COLS" -ge 35 ]
}

# ── the metadata columns ───────────────────────────────────────────────────

@test "sessions: a frame that shrank erases the taller frame's leftover tail" {
  # The new frame is shorter, so the previous frame's last rows are still
  # painted below it with nothing to clear them. The cursor sits exactly on
  # that leftover, so erase from there down. Only on an actual shrink, because
  # erase-to-end-of-screen is the one sequence here that can flash.
  _mk_rows 40
  _term_cols() { echo 100; }
  # 30 rows on the first measure, 14 on every one after: a real shrink.
  # The counter is file-backed because _term_rows is called through a command
  # substitution, so a shell variable would increment in the subshell and be
  # lost, leaving every call answering 30 and the test passing for no reason.
  : > "$TEST_TEMP/hcalls"
  _term_rows() {
    echo x >> "$TEST_TEMP/hcalls"
    if [[ "$(wc -l < "$TEST_TEMP/hcalls" | tr -d ' ')" -le 1 ]]; then echo 30; else echo 14; fi
  }
  _tui_keys DOWN QUIT
  run _sessions_picker_tui "$SDIR" "$TEST_TEMP/proj" "main" "cleat-x" "$TEST_TEMP/rows" 40
  assert_success
  assert_output --partial "$(printf '\033')[J"
}

@test "sessions: a frame that did not shrink does not erase to end of screen" {
  _mk_rows 40
  _term_cols() { echo 100; }
  _term_rows() { echo 24; }
  _tui_keys DOWN QUIT
  run _sessions_picker_tui "$SDIR" "$TEST_TEMP/proj" "main" "cleat-x" "$TEST_TEMP/rows" 40
  assert_success
  refute_output --partial "$(printf '\033')[J"
}

# ── hardening: defects found by adversarial audit ──────────────────────────

@test "sessions: rename refuses a symlinked transcript and never writes the target" {
  # The delete path always checked containment; the rename path did not, and a
  # rename APPENDS. A <uuid>.jsonl symlink planted from inside the box (that
  # directory is mounted read-write into the container by design) would have
  # made the host append a record to whatever it pointed at, then restore the
  # victim's mtime so nothing looked disturbed.
  _pass_gates
  echo "VICTIM" > "$TEST_TEMP/victim"
  ln -s "$TEST_TEMP/victim" "$SDIR/${U1}.jsonl"
  run _sessions_do_rename "$SDIR" "$U1" "main" "cleat-x" "pwned"
  assert_failure
  run cat "$TEST_TEMP/victim"
  assert_output "VICTIM"
}

@test "sessions: an absurd age cannot push a full row past the terminal width" {
  # printf '%-9s' pads to nine and never truncates to it, so a 1998-or-earlier
  # mtime renders "20707d ago" (ten) and every row is one column too wide. With
  # a SHORT title the row still fits, which is how this hid: the title has to
  # fill the remaining budget for the overflow to show.
  local long
  long="$(printf 'L%.0s' $(seq 1 400))"
  printf '1\t1024\t%s\t%s\n' "$U1" "$long" > "$TEST_TEMP/rows"
  _term_rows() { echo 24; }; _term_cols() { echo 60; }
  run _sessions_picker_draw 0 0 "$TEST_TEMP/rows"
  assert_success
  local plain
  plain="$(printf '%s' "${lines[0]}" | sed 's/'"$(printf '\033')"'\[[0-9;]*[mK]//g; s/▸/>/g; s/…/./g')"
  [ "${#plain}" -le 60 ]
}

@test "sessions: an absurd size cannot push a row past the terminal width either" {
  local long
  long="$(printf 'L%.0s' $(seq 1 400))"
  printf '1789000000\t999999999999\t%s\t%s\n' "$U1" "$long" > "$TEST_TEMP/rows"
  _term_rows() { echo 24; }; _term_cols() { echo 60; }
  run _sessions_picker_draw 0 0 "$TEST_TEMP/rows"
  assert_success
  local plain
  plain="$(printf '%s' "${lines[0]}" | sed 's/'"$(printf '\033')"'\[[0-9;]*[mK]//g; s/▸/>/g; s/…/./g')"
  [ "${#plain}" -le 60 ]
}

@test "sessions: the sidecar title is read through the same window as the transcript" {
  # The sidecar is written inside the box, so an unbounded read here is an
  # in-box agent's lever on host memory. The transcript was windowed and this
  # was not.
  _mk_session "$U1"
  mkdir -p "$SDIR/$U1"
  {
    printf '{"pad":"'
    head -c 200000 /dev/zero | tr '\0' 'x'
    printf '","customTitle":"buried"}\n'
  } > "$SDIR/$U1/custom-title.json"
  run _sessions_title_for "$SDIR" "$U1"
  assert_success
  refute_output "buried"
}

@test "sessions: a symlinked sidecar title file is refused, not followed" {
  _mk_session "$U1"
  mkdir -p "$SDIR/$U1"
  printf '{"customTitle":"from elsewhere"}\n' > "$TEST_TEMP/elsewhere.json"
  ln -s "$TEST_TEMP/elsewhere.json" "$SDIR/$U1/custom-title.json"
  run _sessions_title_for "$SDIR" "$U1"
  assert_success
  refute_output "from elsewhere"
}

@test "sessions: a symlinked trash directory is refused" {
  # A symlink at the trash would relocate a deleted session somewhere else
  # while the delete reported success. Every source path is contained, and so
  # is the target, even though the trash is now outside every mount.
  mkdir -p "$TEST_TEMP/outside" "${TRASH%/*}"
  ln -s "$TEST_TEMP/outside" "$TRASH"
  run _sessions_trash_dir "$SDIR"
  assert_failure
}

@test "sessions: a delete refuses rather than trashing through a symlinked trash" {
  _pass_gates
  _mk_session "$U1" "doomed"
  mkdir -p "$TEST_TEMP/outside" "${TRASH%/*}"
  ln -s "$TEST_TEMP/outside" "$TRASH"
  run _sessions_do_delete "$SDIR" "$U1" "$TEST_TEMP/proj" "main" "cleat-x" 1
  assert_failure
  # The transcript stays put and nothing lands outside the session directory.
  [ -f "$SDIR/${U1}.jsonl" ]
  [ -z "$(ls -A "$TEST_TEMP/outside")" ]
}

@test "sessions: trashed items outside the key dir do not collide with the sidecar" {
  # Six of the ten delete-set paths end in a bare <uuid>. A flat basename made
  # the first land as a directory and every later one get moved INSIDE it, so
  # the bytes were buried rather than trashed and restore could never find them.
  _pass_gates
  _mk_session "$U1"
  mkdir -p "$SDIR/$U1"; echo "sidecar" > "$SDIR/$U1/marker"
  mkdir -p "$HOME/.claude/session-env/$U1"; echo "env" > "$HOME/.claude/session-env/$U1/marker"
  run _sessions_do_delete "$SDIR" "$U1" "$TEST_TEMP/proj" "main" "cleat-x" 1
  assert_success
  # The sidecar keeps its own name, because that is what restore looks for.
  [ -f "$TRASH/"*"-$U1/$U1/marker" ]
  # The session-env copy must be a SIBLING of the sidecar, not buried inside it.
  # Asserting only that both markers exist proves nothing: under the collision
  # both DO exist, one nested in the other, which is the bug.
  local nested
  nested="$(find "$TRASH" -path "*/$U1/$U1/*" -name marker | wc -l | tr -d ' ')"
  [ "$nested" -eq 0 ]
  local siblings
  siblings="$(find "$TRASH" -mindepth 2 -maxdepth 3 -name marker | wc -l | tr -d ' ')"
  [ "$siblings" -eq 2 ]
}

@test "sessions: restore refuses an ambiguous prefix instead of picking one" {
  # Same rule the delete path follows. A restore that silently picks one of two
  # conversations is the same class of mistake as a delete that does.
  local A="aaaaaaaa-1111-2222-3333-444444444444"
  local B="aaaaaaaa-1111-2222-3333-555555555555"
  mkdir -p "$TRASH/100-$A" "$TRASH/200-$B"
  run _sessions_restore_resolve "$SDIR" "aaaaaaaa"
  [ "$status" -eq 4 ]
}

@test "sessions: restore still resolves an unambiguous prefix" {
  mkdir -p "$TRASH/100-$U1"
  run _sessions_restore_resolve "$SDIR" "11111111"
  assert_success
  assert_output "$U1"
}

@test "sessions: a huge title cannot scroll the delete confirmation off screen" {
  # The frame clamps the title to the row budget; the line-oriented echo sites
  # did not, so a long title wrapped and pushed the line naming the session id
  # and its size off an 80x24 screen. That is the line a user reads before
  # answering a destructive prompt.
  _pass_gates
  _is_interactive() { return 0; }
  _ask_yn() { printf -v "$1" '%s' 'n'; }
  _term_cols() { echo 80; }
  local long
  long="$(printf 'T%.0s' $(seq 1 3000))"
  _mk_session "$U1" "$long"
  run _sessions_do_delete "$SDIR" "$U1" "$TEST_TEMP/proj" "main" "cleat-x" 0
  assert_success
  # Every rendered line fits one row, so the headline stays on screen.
  local l plain
  for l in "${lines[@]}"; do
    plain="$(printf '%s' "$l" | sed 's/'"$(printf '\033')"'\[[0-9;]*[mK]//g; s/…/./g')"
    [ "${#plain}" -le 80 ]
  done
}

@test "sessions: the loop moves up exactly as many lines as the frame wrote" {
  # THE invariant. If the cursor-up count and the frame's physical line count
  # ever disagree, the block walks down the screen one row per keypress and
  # leaves stale frames behind. Every other viewport test checks one side of
  # this; nothing checked that the two agree.
  _mk_rows 40
  _term_cols() { echo 100; }
  _term_rows() { echo 24; }
  _tui_keys DOWN DOWN QUIT
  _sessions_picker_tui "$SDIR" "$TEST_TEMP/proj" "main" "cleat-x" "$TEST_TEMP/rows" 40 \
    > "$TEST_TEMP/tui.out" 2>&1
  # Split the stream on each cursor-up. Every chunk before one is a frame, so
  # its newline count must equal the number that cursor-up moves back.
  run awk '
    BEGIN { RS = "\033\\[[0-9]+A"; }
    { n = gsub(/\n/, "\n"); frames[NR] = n }
    END { for (i = 1; i < NR; i++) print frames[i] }
  ' "$TEST_TEMP/tui.out"
  assert_success
  # Pull the declared move counts out in order and compare pairwise.
  local moves
  moves="$(grep -o "$(printf '\033')\[[0-9]*A" "$TEST_TEMP/tui.out" | tr -cd '0-9\n' | head -20)"
  [ -n "$moves" ]
  local i=0
  for m in $moves; do
    i=$(( i + 1 ))
    # Frame i wrote ${lines[i-1]} newlines; move i goes up $m.
    [ "$m" -eq "${lines[$(( i - 1 ))]}" ]
  done
  [ "$i" -ge 2 ]
}

@test "sessions: a stray blank line in the frame is caught, not silently counted" {
  # Proves _draw_lines does what the other line-count tests rely on. bats'
  # lines[] would report the same number with or without the blank.
  _mk_rows 3
  _term_cols() { echo 100; }; _term_rows() { echo 24; }
  local real
  real="$(_draw_lines _sessions_picker_draw 0 0 "$TEST_TEMP/rows")"
  _sessions_frame_with_blank() { _sessions_picker_draw "$@"; printf '\n'; }
  local extra
  extra="$(_draw_lines _sessions_frame_with_blank 0 0 "$TEST_TEMP/rows")"
  [ "$extra" -eq $(( real + 1 )) ]
}

@test "sessions: narrowing the window mid-session leaves the picker cleanly" {
  # The launch gate only runs at launch. A window narrowed below the layout's
  # minimum while the picker is open would otherwise keep drawing rows that
  # wrap, and a wrapped row walks the block one row per keypress with no way
  # to recover the origin.
  _mk_rows 20
  : > "$TEST_TEMP/wcalls"
  _term_size() {
    echo x >> "$TEST_TEMP/wcalls"
    # Three reads per measure (rows, cols, the narrow test), so staying wide
    # for exactly three keeps the OUTER redraw gate happy and narrows only on
    # the key loop's own re-measure. Without that split this test passes off
    # the redraw gate and pins nothing here.
    if [[ "$(wc -l < "$TEST_TEMP/wcalls" | tr -d ' ')" -le 3 ]]; then echo "24 100"; else echo "24 30"; fi
  }
  _tui_keys DOWN QUIT
  run _sessions_picker_tui "$SDIR" "$TEST_TEMP/proj" "main" "cleat-x" "$TEST_TEMP/rows" 20
  assert_success
  # The frame was drawn first, which is what proves the key loop got there.
  assert_output --partial "⏎ rename or delete"
  assert_output --partial "too narrow"
}

@test "sessions: the frame forks nothing per row, not even a printf" {
  # The record claims 0 forks per frame. A $(printf ...) for the metadata
  # columns is a command substitution, so it forked once PER ROW and quietly
  # undid most of the rewrite. printf -v into a plain variable is bash 3.2 safe.
  _mk_rows 16
  _term_rows() { echo 24; }; _term_cols() { echo 100; }
  _sessions_load_rows "$TEST_TEMP/rows"
  _sessions_measure "$_SESS_N"
  # Count printf calls that are NOT `printf -v`. `printf -v` assigns in the
  # current shell and forks nothing; a `$(printf ...)` is a command
  # substitution and forks. The frame should make exactly ONE non-`-v` call:
  # the single write that emits the whole frame.
  : > "$TEST_TEMP/pcalls"
  printf() {
    if [ "${1:-}" != "-v" ]; then echo "cmd" >> "$TEST_TEMP/pcalls"; fi
    command printf "$@"
  }
  _sessions_frame 0 0 "$_SESS_PAGE" "$_SESS_COLS" "$_SESS_N" > /dev/null
  unset -f printf
  [ "$(wc -l < "$TEST_TEMP/pcalls" | tr -d ' ')" -eq 1 ]
}

@test "sessions: the frame normalises a hostile offset instead of aborting" {
  # A negative offset reaches an array subscript, which aborts the shell on
  # bash 3.2 and silently renders the wrong rows on bash 5.
  _mk_rows 5
  _term_rows() { echo 24; }; _term_cols() { echo 100; }
  _sessions_load_rows "$TEST_TEMP/rows"
  # A negative offset must be clamped to 0, so the first drawn row is row 0.
  # On bash 5 a negative subscript silently indexes from the END of the array,
  # so asserting only "it did not crash" proves nothing: check the content.
  run _sessions_frame -3 -7 5 100 5
  assert_success
  [[ "${lines[0]}" == *"row 0"* ]]
  run _sessions_frame "" "" "" "" ""
  assert_success
}

@test "sessions: a failure during the row load still restores the terminal" {
  # The window between `stty -echo` and the trap going up was not theoretical:
  # the load shells out to du and date, and under set -e a failing pipeline in
  # there exited the CLI with the terminal unable to echo. The EXIT trap has to
  # be armed in the same breath as the echo-off, not after the load.
  _is_tty() { return 0; }
  : > "$TEST_TEMP/stty.log"
  stty() {
    case "$1" in
      -g) echo "SAVED" ;;
      *)  echo "stty $*" >> "$TEST_TEMP/stty.log" ;;
    esac
  }
  # A real `exit`, not a `return`: test/setup.bash strips `set -euo pipefail`
  # when it sources the CLI, so a non-zero return would simply carry on and the
  # restore would happen through the ordinary empty-list path instead. Only an
  # exit proves the EXIT trap is what put the terminal back.
  _sessions_load_rows() { exit 7; }
  run _sessions_picker_tui "$SDIR" "$TEST_TEMP/proj" "main" "cleat-x" "$TEST_TEMP/rows" 1
  [ "$status" -eq 7 ]
  run cat "$TEST_TEMP/stty.log"
  assert_output --partial "stty SAVED"
}

@test "sessions: an empty list restores the terminal and clears its traps" {
  _is_tty() { return 0; }
  : > "$TEST_TEMP/stty.log"
  stty() { case "$1" in -g) echo "SAVED" ;; *) echo "stty $*" >> "$TEST_TEMP/stty.log" ;; esac; }
  : > "$TEST_TEMP/rows"
  run _sessions_picker_tui "$SDIR" "$TEST_TEMP/proj" "main" "cleat-x" "$TEST_TEMP/rows" 0
  assert_success
  run cat "$TEST_TEMP/stty.log"
  assert_output --partial "stty SAVED"
}

# ── staying in the tool ────────────────────────────────────────────────────
#
# The first cut of this feature ended the verb on every action: rename one
# session and you were back at a shell prompt, with the list you were reading
# gone. Everything below pins the second pass, where an action redraws the list
# you were already on and leaves the cursor where it was.
#
# "Did it come back?" is asserted by counting the frame's hint line, which is
# printed exactly once per frame and by nothing else.

# Counts LIST frames. Deliberately not "↑/↓ move", which the action screen's
# own hint carries too: counting that made a picker that exits after one rename
# look like a picker that came back.
_hint_count() { printf '%s\n' "$output" | grep -c "⏎ rename or delete"; }

# Widest line of a draw, in COLUMNS. Every multibyte glyph the frame can print
# is folded to one ASCII byte first: awk's length() counts bytes under the C
# locale the suite runs in, so measuring the raw output would report the hint
# line as half again as wide as it paints. BSD sed has no \x1b either, hence the
# $'...' literal for the escape.
_widest_col() {
  sed $'s/\033\\[[0-9;]*[A-Za-z]//g' "$1" \
    | sed 's/↑/^/g; s/↓/v/g; s/⏎/E/g; s/→/>/g; s/←/</g; s/…/./g; s/▸/>/g; s/·/./g' \
    | awk '{ n = length($0); if (n > m) m = n } END { print m + 0 }'
}

_mk_trashed() {   # $1 = uuid, $2 = stamp, $3 = title
  local uuid="$1" stamp="${2:-1789000000}" title="${3:-}"
  mkdir -p "$TRASH/${stamp}-${uuid}"
  {
    printf '{"type":"user","message":{"role":"user","content":"hi"},"sessionId":"%s"}\n' "$uuid"
    if [[ -n "$title" ]]; then
      printf '{"type":"custom-title","customTitle":"%s","sessionId":"%s"}\n' "$title" "$uuid"
    fi
  } > "$TRASH/${stamp}-${uuid}/${uuid}.jsonl"
}

@test "sessions: a rename redraws the list instead of ending the verb" {
  _pass_gates
  _is_interactive() { return 0; }
  _mk_session "$U1" "before"
  _mk_session "$U2" "other"
  printf '1\t1\t%s\tbefore\n2\t1\t%s\tother\n' "$U1" "$U2" > "$TEST_TEMP/rows"
  _tui_keys ENTER ENTER QUIT
  run _sessions_picker_tui "$SDIR" "$TEST_TEMP/proj" "main" "cleat-x" "$TEST_TEMP/rows" 2 <<< "renamed"
  assert_success
  [ "$(_hint_count)" -ge 2 ]
}

@test "sessions: a rename updates the row it came back to" {
  _pass_gates
  _is_interactive() { return 0; }
  _mk_session "$U1" "before"
  printf '1\t1\t%s\tbefore\n' "$U1" > "$TEST_TEMP/rows"
  _tui_keys ENTER ENTER QUIT
  run _sessions_picker_tui "$SDIR" "$TEST_TEMP/proj" "main" "cleat-x" "$TEST_TEMP/rows" 1 <<< "after"
  assert_success
  run cat "$TEST_TEMP/rows"
  assert_output --partial "after"
  refute_output --partial "before"
}

@test "sessions: a delete redraws the remaining list rather than leaving" {
  _pass_gates
  _is_interactive() { return 0; }
  _ask_yn() { printf -v "$1" '%s' 'y'; }
  _mk_session "$U1" "goes"
  _mk_session "$U2" "stays"
  printf '1\t1\t%s\tgoes\n2\t1\t%s\tstays\n' "$U1" "$U2" > "$TEST_TEMP/rows"
  _tui_keys ENTER DOWN ENTER QUIT
  run _sessions_picker_tui "$SDIR" "$TEST_TEMP/proj" "main" "cleat-x" "$TEST_TEMP/rows" 2
  assert_success
  [ "$(_hint_count)" -ge 2 ]
  assert_output --partial "stays"
}

@test "sessions: a delete drops the row from the list it comes back to" {
  _pass_gates
  _is_interactive() { return 0; }
  _ask_yn() { printf -v "$1" '%s' 'y'; }
  _mk_session "$U1"
  _mk_session "$U2"
  printf '1\t1\t%s\tone\n2\t1\t%s\ttwo\n' "$U1" "$U2" > "$TEST_TEMP/rows"
  _tui_keys ENTER DOWN ENTER QUIT
  run _sessions_picker_tui "$SDIR" "$TEST_TEMP/proj" "main" "cleat-x" "$TEST_TEMP/rows" 2
  assert_success
  run cat "$TEST_TEMP/rows"
  refute_output --partial "$U1"
  assert_output --partial "$U2"
}

@test "sessions: the header is reprinted under an action's receipt" {
  _pass_gates
  _is_interactive() { return 0; }
  _ask_yn() { printf -v "$1" '%s' 'y'; }
  _mk_session "$U1"
  _mk_session "$U2"
  printf '1\t1\t%s\tone\n2\t1\t%s\ttwo\n' "$U1" "$U2" > "$TEST_TEMP/rows"
  _tui_keys ENTER DOWN ENTER QUIT
  run _sessions_picker_tui "$SDIR" "$TEST_TEMP/proj" "main" "cleat-x" "$TEST_TEMP/rows" 2
  assert_success
  assert_output --partial "Claude sessions"
}

@test "sessions: q after an action does not claim the run was cancelled" {
  _pass_gates
  _is_interactive() { return 0; }
  _ask_yn() { printf -v "$1" '%s' 'y'; }
  _mk_session "$U1"
  _mk_session "$U2"
  printf '1\t1\t%s\tone\n2\t1\t%s\ttwo\n' "$U1" "$U2" > "$TEST_TEMP/rows"
  _tui_keys ENTER DOWN ENTER QUIT
  run _sessions_picker_tui "$SDIR" "$TEST_TEMP/proj" "main" "cleat-x" "$TEST_TEMP/rows" 2
  assert_success
  refute_output --partial "Cancelled."
}

@test "sessions: backing out of the action screen says nothing and redraws" {
  _mk_session "$U1"
  printf '1\t1\t%s\tone\n' "$U1" > "$TEST_TEMP/rows"
  _tui_keys ENTER QUIT QUIT
  run _sessions_picker_tui "$SDIR" "$TEST_TEMP/proj" "main" "cleat-x" "$TEST_TEMP/rows" 1
  assert_success
  # Exactly one Cancelled, and it is the picker's own, not the action screen's.
  [ "$(printf '%s\n' "$output" | grep -c "Cancelled.")" -eq 1 ]
  [ "$(_hint_count)" -ge 2 ]
}

@test "sessions: the action back-out walks back over its own three header lines" {
  # It erases from the list frame's origin, which is _SESSIONS_ACTION_HEAD
  # lines above where the key loop parks. A wrong number here leaves a copy of
  # the menu above the redrawn list, or eats the header.
  run _sessions_action_backout
  assert_success
  printf '%s' "$output" | cat -v | grep -q '\^\[\[3A'
  printf '%s' "$output" | cat -v | grep -q '\^\[\[J'
}

# ── the trash view ─────────────────────────────────────────────────────────

@test "sessions: the right arrow opens the trash view" {
  _mk_session "$U1"
  _mk_trashed "$U2" 1789000000 "deleted one"
  printf '1\t1\t%s\tone\n' "$U1" > "$TEST_TEMP/rows"
  _tui_keys RIGHT QUIT
  run _sessions_picker_tui "$SDIR" "$TEST_TEMP/proj" "main" "cleat-x" "$TEST_TEMP/rows" 1
  assert_success
  assert_output --partial "⏎ restore"
  assert_output --partial "deleted one"
}

@test "sessions: the left arrow does nothing on the live list" {
  _mk_session "$U1"
  _mk_trashed "$U2"
  printf '1\t1\t%s\tone\n' "$U1" > "$TEST_TEMP/rows"
  _tui_keys LEFT QUIT
  run _sessions_picker_tui "$SDIR" "$TEST_TEMP/proj" "main" "cleat-x" "$TEST_TEMP/rows" 1
  assert_success
  refute_output --partial "⏎ restore"
}

@test "sessions: the left arrow comes back from the trash to the sessions" {
  _mk_session "$U1" "live one"
  _mk_trashed "$U2" 1789000000 "dead one"
  printf '1\t1\t%s\tlive one\n' "$U1" > "$TEST_TEMP/rows"
  _tui_keys RIGHT LEFT QUIT
  run _sessions_picker_tui "$SDIR" "$TEST_TEMP/proj" "main" "cleat-x" "$TEST_TEMP/rows" 1
  assert_success
  assert_output --partial "⏎ rename or delete"
  assert_output --partial "live one"
}

@test "sessions: the trash view restores the selected session" {
  _mk_trashed "$U1" 1789000000 "bring me back"
  : > "$TEST_TEMP/rows"
  printf '1\t1\t%s\tkeeper\n' "$U2" > "$TEST_TEMP/rows"
  _mk_session "$U2"
  _tui_keys RIGHT ENTER QUIT
  run _sessions_picker_tui "$SDIR" "$TEST_TEMP/proj" "main" "cleat-x" "$TEST_TEMP/rows" 1
  assert_success
  assert_output --partial "Restored"
  [ -f "$SDIR/${U1}.jsonl" ]
}

@test "sessions: a restored session is back in the live list" {
  _mk_session "$U2"
  _mk_trashed "$U1" 1789000000 "back again"
  printf '1\t1\t%s\tkeeper\n' "$U2" > "$TEST_TEMP/rows"
  _tui_keys RIGHT ENTER LEFT QUIT
  run _sessions_picker_tui "$SDIR" "$TEST_TEMP/proj" "main" "cleat-x" "$TEST_TEMP/rows" 1
  assert_success
  run cat "$TEST_TEMP/rows"
  assert_output --partial "$U1"
  assert_output --partial "$U2"
}

@test "sessions: Enter on an empty trash does not close the picker" {
  _mk_session "$U1"
  printf '1\t1\t%s\tone\n' "$U1" > "$TEST_TEMP/rows"
  _tui_keys RIGHT ENTER QUIT
  run _sessions_picker_tui "$SDIR" "$TEST_TEMP/proj" "main" "cleat-x" "$TEST_TEMP/rows" 1
  assert_success
  assert_output --partial "The trash is empty"
  refute_output --partial "Restored"
}

@test "sessions: deleting the last session shows the trash rather than leaving" {
  _pass_gates
  _is_interactive() { return 0; }
  _ask_yn() { printf -v "$1" '%s' 'y'; }
  _mk_session "$U1" "the only one"
  printf '1\t1\t%s\tthe only one\n' "$U1" > "$TEST_TEMP/rows"
  _tui_keys ENTER DOWN ENTER QUIT
  run _sessions_picker_tui "$SDIR" "$TEST_TEMP/proj" "main" "cleat-x" "$TEST_TEMP/rows" 1
  assert_success
  assert_output --partial "Showing the trash"
  assert_output --partial "⏎ restore"
}

@test "sessions: an empty list with an empty trash says so and leaves" {
  : > "$TEST_TEMP/rows"
  run _sessions_picker_tui "$SDIR" "$TEST_TEMP/proj" "main" "cleat-x" "$TEST_TEMP/rows" 0
  assert_success
  assert_output --partial "No sessions left in this project."
}

# ── the trash scan ─────────────────────────────────────────────────────────

@test "sessions: the trash scan emits one row per trashed session" {
  _mk_trashed "$U1" 1789000000 "gone"
  run _sessions_trash_scan "$SDIR"
  assert_success
  assert_output --partial "$U1"
  assert_output --partial "gone"
}

@test "sessions: the trash scan dates a row by when it was deleted" {
  _mk_trashed "$U1" 1700000000 "old delete"
  run _sessions_trash_scan "$SDIR"
  assert_success
  [ "$(printf '%s' "$output" | cut -f1)" = "1700000000" ]
}

@test "sessions: the trash scan ignores anything not named epoch-uuid" {
  mkdir -p "$TRASH/not-a-session" "$TRASH/abc-$U1" \
           "$TRASH/100-notauuid"
  run _sessions_trash_scan "$SDIR"
  assert_success
  assert_output ""
}

@test "sessions: the trash scan is newest deletion first" {
  _mk_trashed "$U1" 100 "older"
  _mk_trashed "$U2" 200 "newer"
  run _sessions_trash_scan_sorted "$SDIR"
  assert_success
  [ "$(printf '%s\n' "$output" | head -1 | cut -f3)" = "$U2" ]
}

@test "sessions: the trash scan of a missing trash prints nothing" {
  run _sessions_trash_scan "$SDIR"
  assert_success
  assert_output ""
}

@test "sessions: the trash scan refuses a symlinked trash directory" {
  mkdir -p "$TEST_TEMP/outside/1-$U1" "${TRASH%/*}"
  ln -s "$TEST_TEMP/outside" "$TRASH"
  run _sessions_trash_scan "$SDIR"
  assert_success
  assert_output ""
}

@test "sessions: the trash count counts only real entries" {
  _mk_trashed "$U1" 100
  _mk_trashed "$U2" 200
  # not-a-session is rejected by the uuid check, 100-notauuid by the uuid check
  # too, and abc-<uuid> ONLY by the stamp check. All three are needed or one of
  # the two guards can be removed without the count moving.
  mkdir -p "$TRASH/not-a-session" "$TRASH/100-notauuid" \
           "$TRASH/abc-$U1"
  : > "$TRASH/a-file"
  run _sessions_trash_count "$SDIR"
  assert_success
  assert_output "2"
}

@test "sessions: the trash count is zero with no trash at all" {
  run _sessions_trash_count "$SDIR"
  assert_success
  assert_output "0"
}

# ── the counter and hint lines ─────────────────────────────────────────────

@test "sessions: the trash view names itself on the counter line" {
  _term_rows() { echo 24; }; _term_cols() { echo 100; }
  _mk_rows 1
  _SESS_VIEW="trash"
  run _sessions_picker_draw 0 0 "$TEST_TEMP/rows"
  assert_success
  assert_output --partial "Trash: 1 item, kept 30 days"
}

@test "sessions: the trash view pluralises and pages" {
  _term_rows() { echo 12; }; _term_cols() { echo 100; }
  _mk_rows 20
  _SESS_VIEW="trash"
  run _sessions_picker_draw 0 0 "$TEST_TEMP/rows"
  assert_success
  assert_output --partial "Trash: 1-4 of 20"
}

@test "sessions: an empty trash view says so on the counter line" {
  _term_rows() { echo 24; }; _term_cols() { echo 100; }
  : > "$TEST_TEMP/rows"
  _SESS_VIEW="trash"
  run _sessions_picker_draw 0 0 "$TEST_TEMP/rows"
  assert_success
  assert_output --partial "The trash is empty"
}

@test "sessions: the live view advertises the trash only when it holds something" {
  _term_rows() { echo 24; }; _term_cols() { echo 100; }
  _mk_rows 2
  _SESS_VIEW="live"
  _SESS_TRASH_N=0
  run _sessions_picker_draw 0 0 "$TEST_TEMP/rows"
  assert_success
  refute_output --partial "→ trash"
  _SESS_TRASH_N=3
  run _sessions_picker_draw 0 0 "$TEST_TEMP/rows"
  assert_success
  assert_output --partial "→ trash (3)"
}

@test "sessions: the hint line names the action the view actually performs" {
  _term_rows() { echo 24; }; _term_cols() { echo 100; }
  _mk_rows 1
  _SESS_VIEW="live"
  run _sessions_picker_draw 0 0 "$TEST_TEMP/rows"
  assert_output --partial "⏎ rename or delete"
  refute_output --partial "⏎ restore"
  _SESS_VIEW="trash"
  run _sessions_picker_draw 0 0 "$TEST_TEMP/rows"
  assert_output --partial "⏎ restore"
  refute_output --partial "⏎ rename or delete"
}

@test "sessions: neither hint line is wider than the picker's own minimum" {
  # _SESSIONS_MIN_COLS is the width below which the picker refuses to draw,
  # so a hint wider than that wraps on the narrowest SUPPORTED terminal, and a
  # wrapped line walks the whole block down the screen one row per keypress.
  _term_rows() { echo 24; }; _term_cols() { echo "$_SESSIONS_MIN_COLS"; }
  _mk_rows 1
  local v widest
  for v in live trash; do
    _SESS_VIEW="$v"
    _SESS_TRASH_N=9
    _sessions_picker_draw 0 0 "$TEST_TEMP/rows" > "$TEST_TEMP/frame.out" 2>/dev/null
    widest="$(_widest_col "$TEST_TEMP/frame.out")"
    [ "$widest" -le "$_SESSIONS_MIN_COLS" ] || { echo "view $v drew $widest columns"; return 1; }
  done
}

@test "sessions: the view does not change the frame's height" {
  _term_rows() { echo 24; }; _term_cols() { echo 100; }
  _mk_rows 3
  _SESS_VIEW="live"
  [ "$(_draw_lines _sessions_picker_draw 0 0 "$TEST_TEMP/rows")" -eq 6 ]
  _SESS_VIEW="trash"
  [ "$(_draw_lines _sessions_picker_draw 0 0 "$TEST_TEMP/rows")" -eq 6 ]
}

# ── folding an action into the cached rows ─────────────────────────────────

@test "sessions: a delete is folded out of the cached rows" {
  printf '1\t1\t%s\tone\n2\t1\t%s\ttwo\n' "$U1" "$U2" > "$TEST_TEMP/rows"
  _SESS_ACTED="delete"
  run _sessions_row_apply "$TEST_TEMP/rows" "$U1"
  assert_success
  run cat "$TEST_TEMP/rows"
  refute_output --partial "$U1"
  assert_output --partial "$U2"
}

@test "sessions: a rename is folded into the cached rows without moving them" {
  printf '9\t7\t%s\tbefore\n1\t1\t%s\ttwo\n' "$U1" "$U2" > "$TEST_TEMP/rows"
  _SESS_ACTED="rename"
  _SESS_ACTED_TITLE="after"
  run _sessions_row_apply "$TEST_TEMP/rows" "$U1"
  assert_success
  run head -1 "$TEST_TEMP/rows"
  # Fields 1-3 untouched, only the title replaced: a rename keeps the mtime, so
  # the sort order must not move either.
  assert_output "$(printf '9\t7\t%s\tafter' "$U1")"
}

@test "sessions: nothing is folded in when no action ran" {
  printf '1\t1\t%s\tone\n' "$U1" > "$TEST_TEMP/rows"
  _SESS_ACTED=""
  run _sessions_row_apply "$TEST_TEMP/rows" "$U1"
  assert_success
  run cat "$TEST_TEMP/rows"
  assert_output --partial "$U1"
}

@test "sessions: folding in clears the marker so it cannot be applied twice" {
  printf '1\t1\t%s\tone\n2\t1\t%s\ttwo\n' "$U1" "$U2" > "$TEST_TEMP/rows"
  _SESS_ACTED="delete"
  _sessions_row_apply "$TEST_TEMP/rows" "$U1"
  [ -z "$_SESS_ACTED" ]
  _sessions_row_apply "$TEST_TEMP/rows" "$U2"
  run cat "$TEST_TEMP/rows"
  assert_output --partial "$U2"
}

@test "sessions: a restored session is inserted in its sorted position" {
  _mk_session "$U1"
  # One row in the future and one at the epoch, so the restored session's real
  # mtime has to land BETWEEN them. Appending it would leave it third, which is
  # what a missing sort actually does.
  printf '9999999999\t1\t%s\tnewer\n1\t1\t%s\toldest\n' "$U2" "$U2" > "$TEST_TEMP/rows"
  run _sessions_row_insert "$TEST_TEMP/rows" "$SDIR" "$U1"
  assert_success
  [ "$(sed -n 1p "$TEST_TEMP/rows" | cut -f3)" = "$U2" ]
  [ "$(sed -n 2p "$TEST_TEMP/rows" | cut -f3)" = "$U1" ]
  [ "$(sed -n 3p "$TEST_TEMP/rows" | cut -f3)" = "$U2" ]
}

@test "sessions: inserting a session that is not there fails and writes nothing" {
  printf '1\t1\t%s\tone\n' "$U2" > "$TEST_TEMP/rows"
  run _sessions_row_insert "$TEST_TEMP/rows" "$SDIR" "$U1"
  assert_failure
  run cat "$TEST_TEMP/rows"
  refute_output --partial "$U1"
}

# ── the restore action ─────────────────────────────────────────────────────

@test "sessions: the restore action puts the transcript back and marks the run" {
  _mk_trashed "$U1" 1789000000 "restore me"
  _sessions_do_restore "$SDIR" "$U1"
  [ -f "$SDIR/${U1}.jsonl" ]
  [ "$_SESS_ACTED" = "restore" ]
  run _sessions_do_restore "$SDIR" "$U2"
  assert_failure
}

@test "sessions: the trash view shows a session deleted in the same run" {
  # The trash rows are cached like the live ones, so a delete has to mark them
  # stale. Without that the user deletes something, presses the arrow, and the
  # trash looks empty.
  _pass_gates
  _is_interactive() { return 0; }
  _ask_yn() { printf -v "$1" '%s' 'y'; }
  _mk_session "$U1" "delete me"
  _mk_session "$U2" "keep me"
  printf '1\t1\t%s\tdelete me\n2\t1\t%s\tkeep me\n' "$U1" "$U2" > "$TEST_TEMP/rows"
  # Visit the empty trash FIRST so its rows are cached. Without that the very
  # first visit rescans anyway and a missing invalidation is invisible.
  _tui_keys RIGHT LEFT ENTER DOWN ENTER RIGHT QUIT
  run _sessions_picker_tui "$SDIR" "$TEST_TEMP/proj" "main" "cleat-x" "$TEST_TEMP/rows" 2
  assert_success
  assert_output --partial "⏎ restore"
  # The COUNTER, not the title: the title is also in the list above and in the
  # delete receipt, so asserting on it passes whether or not the trash rescanned.
  assert_output --partial "Trash: 1 item"
}

@test "sessions: the restore action prints a receipt naming the session" {
  _mk_trashed "$U1" 1789000000 "restore me"
  run _sessions_do_restore "$SDIR" "$U1"
  assert_success
  assert_output --partial "Restored"
  assert_output --partial "${U1:0:8}"
}

@test "sessions: the restore action refuses when there is nothing to restore" {
  run _sessions_do_restore "$SDIR" "$U1"
  assert_failure
  assert_output --partial "Could not restore"
}

@test "sessions: the restore action never overwrites a session that came back" {
  _mk_session "$U1" "the live one"
  _mk_trashed "$U1" 1789000000 "the trashed one"
  _sessions_do_restore "$SDIR" "$U1" || true
  run _sessions_title_for "$SDIR" "$U1"
  assert_output "the live one"
}

# ── action markers ─────────────────────────────────────────────────────────

@test "sessions: a rename marks what it changed for the list to fold in" {
  _pass_gates
  _mk_session "$U1"
  _sessions_do_rename "$SDIR" "$U1" "main" "cleat-x" "picked name"
  [ "$_SESS_ACTED" = "rename" ]
  [ "$_SESS_ACTED_TITLE" = "picked name" ]
}

@test "sessions: a refused rename marks nothing" {
  _pass_gates
  _mk_session "$U1"
  _sessions_do_rename "$SDIR" "$U1" "main" "cleat-x" 'bad"title' || true
  [ -z "$_SESS_ACTED" ]
}

@test "sessions: a delete marks what it changed for the list to fold in" {
  _pass_gates
  _is_interactive() { return 0; }
  _ask_yn() { printf -v "$1" '%s' 'y'; }
  _mk_session "$U1"
  _sessions_do_delete "$SDIR" "$U1" "$TEST_TEMP/proj" "main" "cleat-x" 1
  [ "$_SESS_ACTED" = "delete" ]
}

@test "sessions: a delete that was declined marks nothing" {
  _pass_gates
  _is_interactive() { return 0; }
  _ask_yn() { printf -v "$1" '%s' 'n'; }
  _mk_session "$U1"
  _sessions_do_delete "$SDIR" "$U1" "$TEST_TEMP/proj" "main" "cleat-x" 0
  [ -z "$_SESS_ACTED" ]
}

# ── the header ─────────────────────────────────────────────────────────────

@test "sessions: the header is exactly the four lines the viewport budgets for" {
  _term_cols() { echo 100; }
  [ "$(_draw_lines _sessions_header "$SDIR" "$TEST_TEMP/myproject" "main")" -eq 4 ]
}

@test "sessions: the header truncates a path too long for the terminal" {
  _term_cols() { echo 40; }
  local deep="$TEST_TEMP/aaaaaaaaaaaaaaaaaaaa/bbbbbbbbbbbbbbbbbbbb/cccccccccccccccccccc/dddddddddddddddddddd"
  _sessions_header "$deep" "$TEST_TEMP/myproject" "main" > "$TEST_TEMP/frame.out"
  run cat "$TEST_TEMP/frame.out"
  assert_output --partial "…"
  [ "$(_widest_col "$TEST_TEMP/frame.out")" -le 40 ]
}

@test "sessions: the header names a non-default box" {
  _term_cols() { echo 100; }
  run _sessions_header "$SDIR" "$TEST_TEMP/myproject" "feat"
  assert_success
  assert_output --partial "myproject / feat"
}

# ── cleat session trash ───────────────────────────────────────────────────

@test "sessions: cleat session trash lists what was deleted" {
  _pass_gates
  resolve_project() { echo "$TEST_TEMP/proj"; }
  _sessions_key_dir() { echo "$SDIR"; }
  container_name_for() { echo "cleat-x"; }
  _mk_trashed "$U1" 1789000000 "deleted thing"
  run cmd_sessions trash
  assert_success
  assert_output --partial "Trashed sessions"
  assert_output --partial "deleted thing"
  assert_output --partial "cleat session restore"
}

@test "sessions: cleat session trash says so when there is nothing in it" {
  _pass_gates
  resolve_project() { echo "$TEST_TEMP/proj"; }
  _sessions_key_dir() { echo "$SDIR"; }
  container_name_for() { echo "cleat-x"; }
  run cmd_sessions trash
  assert_success
  assert_output --partial "The trash is empty."
}

@test "sessions: cleat session trash takes no id" {
  _pass_gates
  resolve_project() { echo "$TEST_TEMP/proj"; }
  _sessions_key_dir() { echo "$SDIR"; }
  container_name_for() { echo "cleat-x"; }
  run cmd_sessions trash
  assert_success
  refute_output --partial "Which session?"
}

@test "sessions: the text fallback points at the trash when it holds something" {
  _mk_trashed "$U1" 1789000000 "gone"
  printf '1\t1\t%s\tone\n' "$U2" > "$TEST_TEMP/rows"
  run _sessions_picker_text "$TEST_TEMP/rows" 1 "$SDIR"
  assert_success
  assert_output --partial "1 in the trash"
  assert_output --partial "cleat session trash"
}

@test "sessions: the text fallback stays quiet about an empty trash" {
  printf '1\t1\t%s\tone\n' "$U2" > "$TEST_TEMP/rows"
  run _sessions_picker_text "$TEST_TEMP/rows" 1 "$SDIR"
  assert_success
  refute_output --partial "in the trash"
}

# ── the terminal state across a view switch ────────────────────────────────

@test "sessions: switching views does not poison the saved terminal state" {
  # The picker re-arms the terminal once per list screen and a view switch
  # breaks back to it WITHOUT restoring first, because nothing was printed. A
  # second `stty -g` there would save the already echo-off state as the
  # original, and the user would be left with a terminal that cannot echo.
  _is_tty() { return 0; }
  : > "$TEST_TEMP/stty.log"
  stty() {
    case "$1" in
      -g)
        if [ -f "$TEST_TEMP/echo.off" ]; then echo "NOECHO"; else echo "ORIGINAL"; fi ;;
      -echo)
        : > "$TEST_TEMP/echo.off"
        echo "stty $*" >> "$TEST_TEMP/stty.log" ;;
      *)
        echo "stty $*" >> "$TEST_TEMP/stty.log" ;;
    esac
  }
  _mk_session "$U1"
  _mk_trashed "$U2" 1789000000 "gone"
  printf '1\t1\t%s\tone\n' "$U1" > "$TEST_TEMP/rows"
  _tui_keys RIGHT LEFT RIGHT QUIT
  run _sessions_picker_tui "$SDIR" "$TEST_TEMP/proj" "main" "cleat-x" "$TEST_TEMP/rows" 1
  assert_success
  run cat "$TEST_TEMP/stty.log"
  assert_output --partial "stty ORIGINAL"
  refute_output --partial "stty NOECHO"
}

@test "sessions: a window narrowed during an action leaves before drawing a wrapped frame" {
  # The key loop refuses a too-narrow window, but the window can be narrowed
  # while a rename prompt is waiting for input, so the REDRAW has to refuse too.
  # Asserted by proving no key was ever read: the key loop's own gate would
  # print the same message one keypress later and pass this for the wrong
  # reason.
  _mk_session "$U1"
  printf '1\t1\t%s\tone\n' "$U1" > "$TEST_TEMP/rows"
  _sessions_too_narrow() { return 0; }
  _read_keypress() { : > "$TEST_TEMP/keyread"; echo QUIT; }
  run _sessions_picker_tui "$SDIR" "$TEST_TEMP/proj" "main" "cleat-x" "$TEST_TEMP/rows" 1
  assert_success
  assert_output --partial "Window too narrow"
  [ ! -f "$TEST_TEMP/keyread" ]
}

@test "sessions: deleting a session another window already deleted is refused, not reported as done" {
  # The old path created the trash entry, moved nothing into it, and reported
  # success. The row then sat in the trash view for thirty days restoring
  # nothing.
  _pass_gates
  _is_interactive() { return 0; }
  _ask_yn() { printf -v "$1" '%s' 'y'; }
  _mk_session "$U1"
  # The confirm has already happened; the other window deletes it here.
  _sessions_path_under_key() { return 0; }
  _path_mtime() { echo 1234; }
  rm -f "$SDIR/${U1}.jsonl"
  run _sessions_do_delete "$SDIR" "$U1" "$TEST_TEMP/proj" "main" "cleat-x" 1
  assert_failure
  assert_output --partial "already gone"
  [ -z "$(ls -A "$TRASH" 2>/dev/null)" ]
}

@test "sessions: an empty trash entry is never left behind" {
  _pass_gates
  _mk_session "$U1"
  rm -f "$SDIR/${U1}.jsonl"
  run _sessions_trash "$SDIR" "$U1" "$TEST_TEMP/proj" "cleat-x"
  [ "$status" -eq 3 ]
  [ -z "$(ls -A "$TRASH" 2>/dev/null)" ]
}

@test "session titles: one invalid byte does not kill the picker" {
  # The sanitiser ended in an unpinned sed. BSD sed under a UTF-8 LC_CTYPE
  # refuses a byte sequence that is not valid UTF-8 and exits non-zero, so a
  # single bad byte in a model-written title took the whole list down on a Mac.
  local bad
  bad="$(printf 'ok\xff\xfetitle')"
  LC_ALL=en_US.UTF-8 run _sessions_safe_str "$bad"
  assert_success
  assert_output --partial "ok"
  assert_output --partial "title"

  # A real backslash is still doubled for the echo -e that renders it.
  run _sessions_safe_str 'a\b'
  assert_success
  assert_output 'a\\b'
}

@test "session rename: a link planted at the temp path is never written through" {
  # Both temp paths were $$-named, and this directory is the box's own session
  # tree, mounted read-write. A predictable name is one the box can pre-create
  # as a link to any host file the user can write.
  local sdir="$TEST_TEMP/projects/-workspace"
  local uuid="11111111-2222-4333-8444-555555555555"
  mkdir -p "$sdir/$uuid"
  printf '{"type":"summary"}\n' > "$sdir/$uuid.jsonl"
  local victim="$TEST_TEMP/host-secret.txt"
  printf 'KEEP\n' > "$victim"
  # The two names the old code used.
  ln -s "$victim" "$sdir/.cleat-mtime.$$" 2>/dev/null || true
  ln -s "$victim" "$sdir/$uuid/.custom-title.json.$$" 2>/dev/null || true

  local before
  before="$(stat -c %Y "$victim" 2>/dev/null || stat -f %m "$victim" 2>/dev/null)"
  # Old enough that a stamp through the link is visible.
  touch -t 202001010101 "$victim"
  before="$(stat -c %Y "$victim" 2>/dev/null || stat -f %m "$victim" 2>/dev/null)"

  run _sessions_rename_write "$sdir" "$uuid" "renamed"
  run cat "$victim"
  assert_output "KEEP"
  # Not stamped either: `touch -r` through a planted link would have moved the
  # host file's mtime, twice.
  local after
  after="$(stat -c %Y "$victim" 2>/dev/null || stat -f %m "$victim" 2>/dev/null)"
  assert_equal "$after" "$before"
  # And the rename still did its job.
  run cat "$sdir/$uuid.jsonl"
  assert_output --partial "renamed"
}

@test "sessions: a trash left inside the session dir is carried out to the host-only trash" {
  # Before the trash moved out of the session dir, it lived in <key>/.cleat-trash.
  # Its real entries move out. A link, a stray name and an entry that would
  # overwrite one already in the new trash do not, and the old dir is gone.
  mkdir -p "$SDIR/.cleat-trash/100-$U1" "$SDIR/.cleat-trash/300-$U2" "$TRASH/300-$U2" \
    "$SDIR/.cleat-trash/not-a-session" "$SDIR/.cleat-trash/abc-$U1" \
    "$SDIR/.cleat-trash/100-notauuid" "$TEST_TEMP/outside/keep"
  echo "old" > "$SDIR/.cleat-trash/100-$U1/${U1}.jsonl"
  echo "legacy duplicate" > "$SDIR/.cleat-trash/300-$U2/${U2}.jsonl"
  echo "already here" > "$TRASH/300-$U2/${U2}.jsonl"
  ln -s "$TEST_TEMP/outside" "$SDIR/.cleat-trash/200-$U2"
  run _sessions_trash_count "$SDIR"
  assert_output "2"
  run cat "$TRASH/100-$U1/${U1}.jsonl"
  assert_output "old"
  run cat "$TRASH/300-$U2/${U2}.jsonl"
  assert_output "already here"
  run test -e "$TRASH/300-$U2/300-$U2"
  assert_failure
  run ls -A "$TRASH"
  assert_output "$(printf '%s\n' "100-$U1" "300-$U2")"
  run test -e "$SDIR/.cleat-trash"
  assert_failure
  run test -d "$TEST_TEMP/outside/keep"
  assert_success
}

@test "sessions: a session dir with no key gets no trash" {
  run _sessions_trash_dir "$HOME/.claude/projects/.."
  assert_failure
  run _sessions_trash_dir "$HOME/.claude/projects/"
  assert_failure
}

@test "sessions: restore never renames onto a link planted at the session name" {
  # The session dir is the box's own mount, so it can plant a link at the name
  # a restore is about to write, dangling or not.
  mkdir -p "$TRASH/100-$U1" "$TEST_TEMP/outside"
  echo "back" > "$TRASH/100-$U1/${U1}.jsonl"
  ln -s "$TEST_TEMP/outside/nowhere" "$SDIR/${U1}.jsonl"
  run _sessions_restore "$SDIR" "$U1"
  assert_failure
  run test -L "$SDIR/${U1}.jsonl"
  assert_success
  run ls -A "$TEST_TEMP/outside"
  assert_output ""
  run cat "$TRASH/100-$U1/${U1}.jsonl"
  assert_output "back"
}
