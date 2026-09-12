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
  [ -f "$SDIR/.cleat-trash/"*"-$U1/${U1}.jsonl" ]
  [ -f "$SDIR/.cleat-trash/"*"-$U1/$U1/subagents/a.jsonl" ]
}

@test "sessions: delete is a move, not an unlink" {
  _pass_gates
  _mk_session "$U1" "doomed"
  run _sessions_do_delete "$SDIR" "$U1" "$TEST_TEMP/proj" "main" "cleat-x" 1
  assert_success
  run cat "$SDIR/.cleat-trash/"*"-$U1/${U1}.jsonl"
  assert_output --partial "doomed"
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
  mkdir -p "$SDIR/.cleat-trash/1-$U1"
  : > "$SDIR/.cleat-trash/1-$U1/x"
  run _sessions_trash_sweep "$SDIR"
  assert_success
  [ ! -d "$SDIR/.cleat-trash/1-$U1" ]
}

@test "sessions: the trash sweep keeps a fresh entry" {
  mkdir -p "$SDIR/.cleat-trash/$(date +%s)-$U1"
  run _sessions_trash_sweep "$SDIR"
  assert_success
  [ -d "$SDIR/.cleat-trash/$(date +%s)-$U1" ] || [ -d "$SDIR/.cleat-trash/"*"-$U1" ]
}

@test "sessions: the trash sweep ignores anything not named epoch-uuid" {
  mkdir -p "$SDIR/.cleat-trash/not-a-session"
  run _sessions_trash_sweep "$SDIR"
  assert_success
  [ -d "$SDIR/.cleat-trash/not-a-session" ]
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
  assert_output --partial "cleat sessions rm"
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
  _sessions_echo_off
  [ "$_SESS_STTY" = "SAVED-STATE" ]
  run cat "$TEST_TEMP/stty.log"
  assert_output --partial "stty -echo"
}

@test "sessions: echo-restore puts the saved state back verbatim" {
  _is_tty() { return 0; }
  _SESS_STTY="SAVED-STATE"
  stty() { echo "stty $*" >> "$TEST_TEMP/stty.log"; }
  _sessions_echo_restore
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
  _sessions_echo_restore
  run cat "$TEST_TEMP/stty.log"
  assert_output --partial "stty echo"
}

@test "sessions: echo handling is a no-op without a terminal" {
  _is_tty() { return 1; }
  stty() { echo "CALLED" >> "$TEST_TEMP/stty.log"; }
  _sessions_echo_off
  _sessions_echo_restore
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
  # .cleat-trash sits in a tree the box mounts read-write, so a symlink there
  # would relocate a deleted session outside the session directory while the
  # delete reported success. Every source path is contained; so is the target.
  mkdir -p "$TEST_TEMP/outside"
  ln -s "$TEST_TEMP/outside" "$SDIR/.cleat-trash"
  run _sessions_trash_dir "$SDIR"
  assert_failure
}

@test "sessions: a delete refuses rather than trashing through a symlinked trash" {
  _pass_gates
  _mk_session "$U1" "doomed"
  mkdir -p "$TEST_TEMP/outside"
  ln -s "$TEST_TEMP/outside" "$SDIR/.cleat-trash"
  run _sessions_do_delete "$SDIR" "$U1" "$TEST_TEMP/proj" "main" "cleat-x" 1
  assert_failure
  # The transcript stays put and nothing lands outside the session directory.
  [ -f "$SDIR/${U1}.jsonl" ]
  [ -z "$(ls -A "$TEST_TEMP/outside")" ]
}

@test "sessions: trashed items outside the key dir do not collide with the sidecar" {
  # Five of the nine delete-set paths end in a bare <uuid>. A flat basename made
  # the first land as a directory and every later one get moved INSIDE it, so
  # the bytes were buried rather than trashed and restore could never find them.
  _pass_gates
  _mk_session "$U1"
  mkdir -p "$SDIR/$U1"; echo "sidecar" > "$SDIR/$U1/marker"
  mkdir -p "$HOME/.claude/session-env/$U1"; echo "env" > "$HOME/.claude/session-env/$U1/marker"
  run _sessions_do_delete "$SDIR" "$U1" "$TEST_TEMP/proj" "main" "cleat-x" 1
  assert_success
  # The sidecar keeps its own name, because that is what restore looks for.
  [ -f "$SDIR/.cleat-trash/"*"-$U1/$U1/marker" ]
  # The session-env copy must be a SIBLING of the sidecar, not buried inside it.
  # Asserting only that both markers exist proves nothing: under the collision
  # both DO exist, one nested in the other, which is the bug.
  local nested
  nested="$(find "$SDIR/.cleat-trash" -path "*/$U1/$U1/*" -name marker | wc -l | tr -d ' ')"
  [ "$nested" -eq 0 ]
  local siblings
  siblings="$(find "$SDIR/.cleat-trash" -mindepth 2 -maxdepth 3 -name marker | wc -l | tr -d ' ')"
  [ "$siblings" -eq 2 ]
}

@test "sessions: restore refuses an ambiguous prefix instead of picking one" {
  # Same rule the delete path follows. A restore that silently picks one of two
  # conversations is the same class of mistake as a delete that does.
  local A="aaaaaaaa-1111-2222-3333-444444444444"
  local B="aaaaaaaa-1111-2222-3333-555555555555"
  mkdir -p "$SDIR/.cleat-trash/100-$A" "$SDIR/.cleat-trash/200-$B"
  run _sessions_restore_resolve "$SDIR" "aaaaaaaa"
  [ "$status" -eq 4 ]
}

@test "sessions: restore still resolves an unambiguous prefix" {
  mkdir -p "$SDIR/.cleat-trash/100-$U1"
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
    if [[ "$(wc -l < "$TEST_TEMP/wcalls" | tr -d ' ')" -le 2 ]]; then echo "24 100"; else echo "24 30"; fi
  }
  _tui_keys DOWN QUIT
  run _sessions_picker_tui "$SDIR" "$TEST_TEMP/proj" "main" "cleat-x" "$TEST_TEMP/rows" 20
  assert_success
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
