#!/usr/bin/env bats
# Live account switch: the in-box half (probe and terminate) and the bounded
# exec that runs it. The verbs are always exercised by rendering the shipped
# closure (_handoff_box_script) and running the TEXT, so a test proves exactly
# what ships. No test hands the real /proc to a verb: fake roots for the
# portable tests, a filtered proc view for the Linux ones. See concept/44.

load "../setup"
load "../lib/handoff_helpers"

setup() {
  _common_setup
  use_docker_stub
  source_cli
  _has_unicode() { return 1; }
  # Plain text, so an assertion on a refusal line is not split by a bold span
  # around a box name or a command word.
  BOLD=''; DIM=''; RESET=''; RED=''; GREEN=''; YELLOW=''; AMBER=''; BLUE=''; CYAN=''; UNDERLINE=''
  hb_reset_pids
  BH="$TEST_TEMP/box"        # the box's HOME
  PV="$TEST_TEMP/pv"         # the proc root handed to a verb (fake or a view)
  mkdir -p "$BH/.claude/sessions" "$PV"
  SID="d7b73579-1111-2222-3333-444455556666"
  EXECID="deadbeef1234cafe"
  # Host-only state the switch and the attach gate read lives under the run dir.
  # Pinned into TEST_TEMP so no test touches the developer's real config.
  CLEAT_ACCOUNTS_DIR="$TEST_TEMP/home/.config/cleat/accounts"
  CLEAT_BOX_ACCOUNTS_DIR="$TEST_TEMP/home/.config/cleat/box-accounts"
  CLEAT_RUN_DIR="$TEST_TEMP/home/.config/cleat/run"
  CLEAT_PROJECTS_DIR="$TEST_TEMP/home/.config/cleat/projects"
  mkdir -p "$CLEAT_ACCOUNTS_DIR" "$CLEAT_BOX_ACCOUNTS_DIR" "$CLEAT_RUN_DIR" "$CLEAT_PROJECTS_DIR"
  CN="cleat-hbm2-01"
  mkdir -p "$CLEAT_RUN_DIR/$CN"
  # A credential blob for the tests that stage an account through the switch.
  _m2_cred() {
    printf '{"claudeAiOauth":{"accessToken":"a","refreshToken":"r","expiresAt":%s,"subscriptionType":"max"}}\n' "${1:-1789003600000}"
  }
  _m2_mk_account() {
    mkdir -p "$CLEAT_ACCOUNTS_DIR/$1"; chmod 700 "$CLEAT_ACCOUNTS_DIR/$1"
    _m2_cred > "$CLEAT_ACCOUNTS_DIR/$1/.credentials.json"; chmod 600 "$CLEAT_ACCOUNTS_DIR/$1/.credentials.json"
  }
  # No test reaches a real Anthropic host.
  curl() { cat >/dev/null 2>&1; return 7; }
}
teardown() { hb_teardown_pids; _common_teardown; }

# ── probe (portable, fake roots) ────────────────────────────────────────────

@test "box probe reports a live session with its status exec id store and sid" {
  hb_fake_proc "$PV" 4242 "claude --continue" 5551234 R \
    "CLEAT_EXEC_ID=$EXECID" "CLAUDE_SECURESTORAGE_CONFIG_DIR=$BH/.cleat-auth"
  hb_session "$BH" 4242 idle procStart=5551234 sessionId="$SID"
  run hb_run_box probe "$BH" "$PV"
  assert_success
  assert_line "hb	1"
  assert_line "args	ok"
  assert_output --partial "$(printf 'claude\t4242 5551234 idle none interactive %s named %s' "$EXECID" "$SID")"
  assert_line "end	ok"
}

@test "box probe ignores a session file whose process start time does not match" {
  hb_fake_proc "$PV" 4242 "claude" 5551234 R "CLEAT_EXEC_ID=$EXECID"
  hb_session "$BH" 4242 idle procStart=9999999 sessionId="$SID"
  run hb_run_box probe "$BH" "$PV"
  assert_success
  refute_output --partial "$(printf 'claude\t')"
  assert_line "orphan	4242"
}

@test "box probe reports a Claude process with no session file as an orphan" {
  hb_fake_proc "$PV" 700 "claude --continue" 111 R
  hb_fake_proc "$PV" 701 "claude auth login" 222 R
  run hb_run_box probe "$BH" "$PV"
  assert_success
  assert_line "orphan	700"
  assert_line "orphan	701"
}

@test "box probe judges processes by executable and never by a claude word in the arguments" {
  hb_fake_proc "$PV" 810 "rg claude" 1 R                                             # a ripgrep pattern
  hb_fake_proc "$PV" 811 "node /home/coder/app/server.js" 1 R                        # a dev server
  hb_fake_proc "$PV" 812 "/home/coder/.local/bin/cleat account" 1 R                  # the cleat wrapper
  hb_fake_proc "$PV" 813 "/home/coder/.local/share/claude/versions/2.1.270 --continue" 1 R  # a real claude
  run hb_run_box probe "$BH" "$PV"
  assert_success
  assert_line "orphan	813"
  refute_output --partial "orphan	810"
  refute_output --partial "orphan	811"
  refute_output --partial "orphan	812"
}

@test "box probe reads an unreadable environment as unreadable and never as none" {
  hb_fake_proc_env_dir "$PV" 4242 "claude" 5551234
  hb_session "$BH" 4242 idle procStart=5551234 sessionId="$SID"
  run hb_run_box probe "$BH" "$PV"
  assert_success
  assert_output --partial "$(printf 'claude\t4242 5551234 idle none interactive unreadable unreadable %s' "$SID")"
  refute_output --partial "interactive none"
}

@test "box probe reads two exec ids in one environment as many" {
  hb_fake_proc "$PV" 4242 "claude" 5551234 R "CLEAT_EXEC_ID=aaaa1111bbbb" "CLEAT_EXEC_ID=cccc2222dddd"
  hb_session "$BH" 4242 busy procStart=5551234 sessionId="$SID"
  run hb_run_box probe "$BH" "$PV"
  assert_success
  assert_output --partial "$(printf 'claude\t4242 5551234 busy none interactive many default %s' "$SID")"
}

@test "box probe maps an unknown status to unknown" {
  hb_fake_proc "$PV" 4242 "claude" 5551234 R "CLEAT_EXEC_ID=$EXECID"
  hb_session "$BH" 4242 frobnicate procStart=5551234 sessionId="$SID"
  run hb_run_box probe "$BH" "$PV"
  assert_success
  assert_output --partial "$(printf 'claude\t4242 5551234 unknown none interactive %s default %s' "$EXECID" "$SID")"
}

@test "box probe reports a shell snapshot process under the exec id it inherited" {
  hb_fake_snapshot_proc "$PV" 900 "CLEAT_EXEC_ID=eeee3333ffff"
  hb_fake_snapshot_proc "$PV" 901       # unreadable leg: no environ entries
  rm -f "$PV/901/environ"; mkdir -p "$PV/901/environ"
  run hb_run_box probe "$BH" "$PV"
  assert_success
  assert_line "shell	eeee3333ffff"
  assert_line "shell	unreadable"
}

# ── the shipped closure ─────────────────────────────────────────────────────

@test "box script defines every box helper and runs under an empty environment" {
  hb_render_box
  # every _hb_* function of the sourced CLI is in the rendered script
  local fn
  for fn in $(declare -F | awk '{print $3}' | grep '^_hb_'); do
    grep -q "^${fn} ()" "$TEST_TEMP/box.sh" || fail "closure is missing ${fn}"
  done
  # a listed name unset makes the render refuse rather than ship half a script
  if ( unset -f _hb_scan; _handoff_box_script >/dev/null 2>&1 ); then
    fail "the render succeeded with _hb_scan unset"
  fi
  # runs under env -i: no host global, and no function reaches a missing command
  local cnf log="$TEST_TEMP/cnf.log"; : > "$log"
  cnf="command_not_found_handle() { echo \"CNF:\$1\" >> \"$log\"; return 127; }"
  local combined; combined="$(printf '%s\n%s\n' "$cnf" "$(cat "$TEST_TEMP/box.sh")")"
  run env -i bash -c "$combined" cleat-hb probe relative /nope
  assert_line "hb	1"
  assert_line "args	bad"
  run env -i bash -c "$combined" cleat-hb terminate relative x named 8 8 1
  assert_line "args	bad"
  [ ! -s "$log" ] || fail "a box function reached an undefined command: $(cat "$log")"
}

@test "box script rendered by this bash runs under every other bash on the machine" {
  hb_render_box
  hb_fake_proc "$PV" 4242 "claude" 5551234 R "CLEAT_EXEC_ID=$EXECID"
  hb_session "$BH" 4242 idle procStart=5551234 sessionId="$SID"
  local seen="" b rp
  for b in /bin/bash "$(command -v bash)" /opt/homebrew/bin/bash /usr/local/bin/bash; do
    [ -x "$b" ] || continue
    rp="$(readlink -f "$b" 2>/dev/null || echo "$b")"
    case " $seen " in *" $rp "*) continue ;; esac
    seen="$seen $rp"
    "$b" -n "$TEST_TEMP/box.sh" || fail "$b failed to parse the closure"
    run "$b" -c "$(cat "$TEST_TEMP/box.sh")" cleat-hb probe "$BH" "$PV"
    assert_success
    assert_line "hb	1"
    assert_line "end	ok"
    assert_output --partial "$(printf 'claude\t4242 5551234 idle')"
  done
  [ -n "$seen" ] || skip "no bash binary found to test"
}

@test "box terminate refuses malformed arguments before it touches anything" {
  # non-UUID sid
  run hb_run_box_raw terminate "$BH" "$PV" named 8 8 1 4242 5551234 NOTAUUID "$EXECID" idle
  assert_line "args	bad"; assert_line "end	abort"; refute_output --partial "lock"
  # pid 0 (would signal a process group)
  run hb_run_box_raw terminate "$BH" "$PV" named 8 8 1 0 5551234 "$SID" "$EXECID" idle
  assert_line "args	bad"; refute_output --partial "lock"
  # pid -1
  run hb_run_box_raw terminate "$BH" "$PV" named 8 8 1 -1 5551234 "$SID" "$EXECID" idle
  assert_line "args	bad"; refute_output --partial "lock"
  # wrong count: N says 2, only one tuple
  run hb_run_box_raw terminate "$BH" "$PV" named 8 8 2 4242 5551234 "$SID" "$EXECID" idle
  assert_line "args	bad"; refute_output --partial "lock"
  # unknown EXPECT
  run hb_run_box_raw terminate "$BH" "$PV" named 8 8 1 4242 5551234 "$SID" "$EXECID" whenever
  assert_line "args	bad"; refute_output --partial "lock"
}

# ── the bounded exec (portable, docker overridden) ──────────────────────────

@test "handoff exec bound returns non zero when docker outlives the timeout" {
  # The exec chain keeps one pid start to finish, so the pid the runaway sleep
  # records is exactly the client pid _handoff_docker_exec backgrounds and must
  # kill. No BASHPID (bash 3.2) and no ps (this box ships none) are needed.
  docker() { exec bash -c "echo \$\$ > '$TEST_TEMP/dockerpid'; exec sleep 6"; }
  local out="$TEST_TEMP/exec.out"
  run _handoff_docker_exec cleat-box 1 "$out" probe "$BH" "$PV"
  assert_equal "$status" 124
  local dp; dp="$(cat "$TEST_TEMP/dockerpid" 2>/dev/null || echo)"
  [ -n "$dp" ] || fail "the runaway docker client never recorded its pid"
  kill -0 "$dp" 2>/dev/null && fail "the runaway docker client was left alive (pid $dp)"
  return 0
}

@test "handoff exec bound stops a runaway output at the byte cap" {
  _HANDOFF_OUT_MAX_BYTES=100
  docker() { head -c 5000 /dev/zero | tr '\0' 'x'; exec sleep 6; }
  local out="$TEST_TEMP/exec.out"
  run _handoff_docker_exec cleat-box 20 "$out" probe "$BH" "$PV"
  assert_equal "$status" 124
}

# ── terminate against real processes (Linux only) ───────────────────────────

@test "box terminate signals only the targets and waits for them to exit" {
  hb_require_linux
  hb_spawn_claude exits "$SID" "$EXECID" idle; local t1="$HB_PID" r1="$HB_RS"
  hb_spawn_claude exits "aaaaaaaa-1111-2222-3333-444455556666" "0011223344ff" idle
  local t2="$HB_PID" r2="$HB_RS"
  # a marked NON-claude bystander must never be signalled
  ( export HB_TEST_MARK="$TEST_TEMP"; exec -a bystander bash -c 'while :; do sleep 0.05; done' ) </dev/null >/dev/null 2>&1 3>&- &
  local bys=$!; echo "$bys" >> "$TEST_TEMP/hb_pids"
  while [ ! -e "/proc/$bys" ]; do :; done
  hb_proc_view "$PV"
  run hb_run_box terminate "$BH" "$PV" default 8 8 2 \
    "$t1" "$r1" "$SID" "$EXECID" idle \
    "$t2" "$r2" "aaaaaaaa-1111-2222-3333-444455556666" "0011223344ff" idle
  assert_success
  assert_line "recheck	ok"
  assert_line "pid	$t1 exited"
  assert_line "pid	$t2 exited"
  assert_line "end	ok"
  kill -0 "$bys" 2>/dev/null || fail "the bystander was signalled"
}

@test "box terminate waits for a refresh lock Claude holds and changes nothing when it outlasts the wait" {
  hb_require_linux
  mkdir -p "$BH/.claude/.oauth_refresh.lock"    # a fresh lock Claude holds
  hb_spawn_claude exits "$SID" "$EXECID" idle; local t1="$HB_PID" r1="$HB_RS"
  hb_proc_view "$PV"
  run hb_run_box terminate "$BH" "$PV" default 1 8 1 "$t1" "$r1" "$SID" "$EXECID" idle
  assert_success
  assert_line "lock	timeout"
  assert_line "end	abort"
  refute_output --partial "recheck"
  kill -0 "$t1" 2>/dev/null || fail "the target was stopped despite the lock timeout"
}

@test "box terminate removes a refresh lock only when it is older than the Claude stale bound" {
  hb_require_linux
  # leg A: a lock aged past the stale bound is reclaimed
  local lock="$BH/.claude/.oauth_refresh.lock"
  mkdir -p "$lock"; touch -d "61 seconds ago" "$lock"
  hb_spawn_claude exits "$SID" "$EXECID" idle; local t1="$HB_PID" r1="$HB_RS"
  hb_proc_view "$PV"
  run hb_run_box terminate "$BH" "$PV" default 1 8 1 "$t1" "$r1" "$SID" "$EXECID" idle
  assert_success
  assert_line "lock	ok"
  # leg B: a lock younger than the bound is left alone
  mkdir -p "$lock"; touch -d "59 seconds ago" "$lock"
  hb_spawn_claude exits "$SID" "$EXECID" idle; local t2="$HB_PID" r2="$HB_RS"
  hb_proc_view "$PV"
  run hb_run_box terminate "$BH" "$PV" default 1 8 1 "$t2" "$r2" "$SID" "$EXECID" idle
  assert_success
  assert_line "lock	timeout"
}

@test "box terminate aborts before any signal when a status changed or a session opened" {
  hb_require_linux
  hb_spawn_claude exits "$SID" "$EXECID" idle; local t1="$HB_PID" r1="$HB_RS"
  # an orphan: a second live claude that is not a target
  hb_spawn_claude exits "bbbbbbbb-1111-2222-3333-444455556666" "99887766aabb" idle
  local b="$HB_PID"
  hb_proc_view "$PV"
  run hb_run_box terminate "$BH" "$PV" default 8 8 1 "$t1" "$r1" "$SID" "$EXECID" idle
  assert_success
  assert_line "recheck	changed"
  assert_line "end	abort"
  refute_output --partial "pid	$t1"
  kill -0 "$t1" 2>/dev/null || fail "the target was signalled despite the recheck change"
  kill -0 "$b" 2>/dev/null || fail "the orphan was signalled"
}

@test "box terminate stops a busy target running a background shell only when the expect is now" {
  hb_require_linux
  # A busy target with a background command: a shell-snapshot process carrying
  # the session's own exec id sits beside it in the proc view.
  hb_spawn_claude exits "$SID" "$EXECID" busy; local t1="$HB_PID" r1="$HB_RS"
  hb_proc_view "$PV"
  hb_fake_snapshot_proc "$PV" 900 "CLEAT_EXEC_ID=$EXECID"
  # expect=now: the session's own shell line is exempt, so the recheck passes and
  # the busy target is stopped. This is the path the host classify opens with
  # --now (spec 4.2 row 9), unreachable until the classify reorder.
  run hb_run_box terminate "$BH" "$PV" default 8 8 1 "$t1" "$r1" "$SID" "$EXECID" now
  assert_success
  assert_line "recheck	ok"
  assert_line "pid	$t1 exited"
  assert_line "end	ok"
  # expect=idle: the same shell line is not exempt, so the recheck aborts before
  # any signal and the target is left running.
  local PV2="$TEST_TEMP/pv2"; mkdir -p "$PV2"
  hb_spawn_claude exits "$SID" "$EXECID" idle; local t2="$HB_PID" r2="$HB_RS"
  hb_proc_view "$PV2"
  hb_fake_snapshot_proc "$PV2" 901 "CLEAT_EXEC_ID=$EXECID"
  run hb_run_box terminate "$BH" "$PV2" default 8 8 1 "$t2" "$r2" "$SID" "$EXECID" idle
  assert_success
  assert_line "recheck	changed"
  assert_line "end	abort"
  kill -0 "$t2" 2>/dev/null || fail "the target was signalled despite the non-exempt shell line"
}

@test "box terminate never kills a target that ignores SIGTERM" {
  hb_require_linux
  hb_spawn_claude ignores "$SID" "$EXECID" idle; local t1="$HB_PID" r1="$HB_RS"
  hb_proc_view "$PV"
  run hb_run_box terminate "$BH" "$PV" default 8 1 1 "$t1" "$r1" "$SID" "$EXECID" idle
  assert_success
  assert_line "pid	$t1 alive"
  assert_line "end	abort"
  kill -0 "$t1" 2>/dev/null || fail "a target that ignores SIGTERM was killed anyway"
}

@test "box terminate releases its lock on abort on success and on TERM" {
  hb_require_linux
  local lock="$BH/.claude/.oauth_refresh.lock"
  # on success
  hb_spawn_claude exits "$SID" "$EXECID" idle; local t1="$HB_PID" r1="$HB_RS"
  hb_proc_view "$PV"
  run hb_run_box terminate "$BH" "$PV" default 8 8 1 "$t1" "$r1" "$SID" "$EXECID" idle
  assert_line "end	ok"
  [ ! -e "$lock" ] || fail "the lock survived a clean finish"
  # on abort (target survives SIGTERM)
  hb_spawn_claude ignores "$SID" "$EXECID" idle; local t2="$HB_PID" r2="$HB_RS"
  hb_proc_view "$PV"
  run hb_run_box terminate "$BH" "$PV" default 8 1 1 "$t2" "$r2" "$SID" "$EXECID" idle
  assert_line "end	abort"
  [ ! -e "$lock" ] || fail "the lock survived an abort"
  # t2 ignored SIGTERM, so it is still live: reap it before the next phase, or
  # it reads as an orphan in the view and aborts phase three at the recheck.
  kill -KILL "$t2" 2>/dev/null || true
  while kill -0 "$t2" 2>/dev/null; do sleep 0.01; done
  # on TERM to the verb itself, mid kill-wait, while it holds the lock
  rm -rf "$PV"; mkdir -p "$PV"
  hb_spawn_claude ignores "aaaaaaaa-1111-2222-3333-444455556666" "0011223344ff" idle
  local t3="$HB_PID" r3="$HB_RS"
  hb_proc_view "$PV"
  hb_render_box
  bash -c "$(cat "$TEST_TEMP/box.sh")" cleat-hb terminate "$BH" "$PV" default 8 8 1 \
    "$t3" "$r3" "aaaaaaaa-1111-2222-3333-444455556666" "0011223344ff" idle \
    </dev/null >/dev/null 2>&1 3>&- &
  local vpid=$!
  local w=0
  while [ ! -e "$lock" ] && [ $w -lt 200 ]; do sleep 0.02; w=$(( w + 1 )); done
  [ -e "$lock" ] || fail "the verb never took the lock"
  kill -TERM "$vpid" 2>/dev/null || true
  wait "$vpid" 2>/dev/null || true
  [ ! -e "$lock" ] || fail "the lock survived a SIGTERM to the verb"
}

# ── host state and the attach gate (M2) ─────────────────────────────────────

@test "handoff id ok accepts 12 to 32 lowercase hex and rejects everything else" {
  _handoff_id_ok "deadbeef1234" || fail "12 hex rejected"
  _handoff_id_ok "deadbeef1234cafe0011223344ff5566" || fail "32 hex rejected"
  run _handoff_id_ok "deadbeef123"        ; assert_failure   # 11, too short
  run _handoff_id_ok "deadbeef1234cafe0011223344ff55667" ; assert_failure  # 33
  run _handoff_id_ok "DEADBEEF1234"       ; assert_failure   # uppercase
  run _handoff_id_ok "deadbeefzzzz"       ; assert_failure   # non-hex
  run _handoff_id_ok ""                   ; assert_failure   # empty
  # the generator always lands inside the accepted range
  local id; id="$(_exec_claude_new_exec_id)"
  _handoff_id_ok "$id" || fail "the generated exec id ($id) is not accepted"
}

@test "handoff marker read parses claude and shell and fails closed to shell" {
  hb_marker "$CN" 111 "kind=claude exec=deadbeef1234cafe"
  _handoff_marker_read "$CLEAT_RUN_DIR/$CN/.attached.111"
  assert_equal "$_HM_KIND" "claude"; assert_equal "$_HM_EXEC" "deadbeef1234cafe"
  hb_marker "$CN" 112 "kind=claude exec="
  _handoff_marker_read "$CLEAT_RUN_DIR/$CN/.attached.112"
  assert_equal "$_HM_KIND" "claude"; assert_equal "$_HM_EXEC" ""
  hb_marker "$CN" 113 "kind=shell"
  _handoff_marker_read "$CLEAT_RUN_DIR/$CN/.attached.113"
  assert_equal "$_HM_KIND" "shell"
  # an older cleat's empty marker, and any garbage, read as shell (fail closed)
  hb_marker "$CN" 114 ""
  _handoff_marker_read "$CLEAT_RUN_DIR/$CN/.attached.114"; assert_equal "$_HM_KIND" "shell"
  hb_marker "$CN" 115 "kind=claude exec=nothex"
  _handoff_marker_read "$CLEAT_RUN_DIR/$CN/.attached.115"; assert_equal "$_HM_KIND" "shell"
}

@test "handoff ticket parser rejects a malformed ticket and never signals a bad pid" {
  local d="$CLEAT_RUN_DIR/$CN"; mkdir -p "$d"
  # a good ticket parses
  _handoff_ticket_write "$CN" "deadbeef1234cafe" requested "$SID" work
  _handoff_ticket_read "$d/.handoff.deadbeef1234cafe" || fail "a valid ticket was rejected"
  assert_equal "$_HT_STATE" "requested"; assert_equal "$_HT_TO" "work"
  # by=1 (init) is rejected, so kill -0 never targets a process group or init
  printf 'v=1\nstate=requested\nby=1\nat=%s\nsid=%s\nto=work\n' "$(date +%s)" "$SID" > "$d/.handoff.bad0"
  run _handoff_ticket_read "$d/.handoff.bad0"; assert_failure
  # by=0 rejected
  printf 'v=1\nstate=requested\nby=0\nat=%s\nsid=%s\nto=work\n' "$(date +%s)" "$SID" > "$d/.handoff.bad1"
  run _handoff_ticket_read "$d/.handoff.bad1"; assert_failure
  # a non-uuid sid rejected
  printf 'v=1\nstate=requested\nby=%s\nat=%s\nsid=not-a-uuid\nto=work\n' "$$" "$(date +%s)" > "$d/.handoff.bad2"
  run _handoff_ticket_read "$d/.handoff.bad2"; assert_failure
  # an at far in the future rejected
  printf 'v=1\nstate=requested\nby=%s\nat=%s\nsid=%s\nto=work\n' "$$" "$(( $(date +%s) + 3600 ))" "$SID" > "$d/.handoff.bad3"
  run _handoff_ticket_read "$d/.handoff.bad3"; assert_failure
  # a wrong version and an unknown state rejected
  printf 'v=2\nstate=requested\nby=%s\nat=%s\nsid=%s\nto=work\n' "$$" "$(date +%s)" "$SID" > "$d/.handoff.bad4"
  run _handoff_ticket_read "$d/.handoff.bad4"; assert_failure
  printf 'v=1\nstate=nonsense\nby=%s\nat=%s\nsid=%s\nto=work\n' "$$" "$(date +%s)" "$SID" > "$d/.handoff.bad5"
  run _handoff_ticket_read "$d/.handoff.bad5"; assert_failure
}

@test "handoff pending counts a live ready ticket as reopening and excludes one already back in the probe set" {
  # A ready ticket a terminal has not yet consumed means the box is still
  # reopening a session from an earlier switch, so a fresh command must not act.
  # Once that session is live again under the same id the reopen is done, and
  # the ticket must stop reading as pending, or a second switch would refuse a
  # reopen that already finished.
  hb_marker "$CN" "$$" "kind=claude exec=$EXECID"
  _handoff_ticket_write "$CN" "$EXECID" ready "$SID" default
  # No probe has run, so the caller's live set is empty: the unconsumed ready
  # ticket of a live exec is still reopening.
  _HO_SID=()
  run _handoff_tickets_pending "$CN"
  assert_success
  # The session is back in the probe's live set under the same id: the reopen
  # completed, so the ticket no longer counts as pending.
  _HO_SID=("$SID")
  run _handoff_tickets_pending "$CN"
  assert_failure
}

@test "handoff refuses under the lock while a session in another terminal is still starting" {
  _m2_mk_account work
  # a fresh, live kind=claude marker is a session coming up: R-starting, no change
  hb_marker "$CN" "$$" "kind=claude exec="
  run _account_switch_locked work mybox "$CN" "$TEST_TEMP/proj"
  assert_failure
  assert_output --partial "A Claude session is starting in mybox"
  # the same marker 200 s in the past is not "starting", so no R-starting
  local mk="$CLEAT_RUN_DIR/$CN/.attached.$$" M
  M="$(_path_mtime "$mk")"
  _HB_NOW=$(( M + 200 )); _handoff_now() { echo "$_HB_NOW"; }
  run _account_switch_locked work mybox "$CN" "$TEST_TEMP/proj"
  refute_output --partial "A Claude session is starting"
  unset -f _handoff_now
  # a dead-pid marker is not live, so it never counts as starting either
  rm -f "$CLEAT_RUN_DIR/$CN"/.attached.*
  hb_marker "$CN" "$(hb_dead_pid)" "kind=claude exec="
  run _account_switch_locked work mybox "$CN" "$TEST_TEMP/proj"
  refute_output --partial "A Claude session is starting"
}

@test "handoff refuses a switch between the shared login and an account while a cleat shell is open" {
  _m2_mk_account work
  _m2_mk_account other
  hb_marker "$CN" "$$" "kind=shell"
  # shared -> named refuses (box is on the shared login, no pin)
  run _account_switch_locked work mybox "$CN" "$TEST_TEMP/proj"
  assert_failure
  assert_output --partial "has a cleat shell open in another terminal"
  # named -> shared refuses too
  _box_account_write "$CN" work "sesskey1"
  run _account_switch_locked default mybox "$CN" "$TEST_TEMP/proj"
  assert_failure
  assert_output --partial "has a cleat shell open in another terminal"
  # an unparseable marker counts as a shell (fails closed)
  rm -f "$CLEAT_RUN_DIR/$CN"/.attached.*
  hb_marker "$CN" "$$" "left by an older cleat"
  _box_account_remove "$CN"
  run _account_switch_locked work mybox "$CN" "$TEST_TEMP/proj"
  assert_failure
  assert_output --partial "has a cleat shell open in another terminal"
  # named -> named is not a shared<->named move, so the shell never blocks it
  _box_account_write "$CN" work "sesskey1"
  run _account_switch_locked other mybox "$CN" "$TEST_TEMP/proj"
  refute_output --partial "has a cleat shell open"
}

@test "handoff writes the identity flag before the pin moves and clears it after the drop" {
  _m2_mk_account work
  local proj="/work/proj-h9"
  local key; key="$(_derive_project_session_key "$proj" mybox)"
  mkdir -p "$CLEAT_PROJECTS_DIR/$key"
  local flag="$CLEAT_PROJECTS_DIR/$key/claude.json.identity-stale"
  # capture whether the flag exists at the moment the pin is written (H9)
  _account_release_staged_locked() { return 0; }
  _account_exists() { return 0; }
  _account_sync_in_locked() { return 0; }
  _box_account_write() { [[ -e "$flag" ]] && : > "$TEST_TEMP/flag_at_pin"; return 0; }
  run _account_switch_locked work mybox "$CN" "$proj"
  assert_success
  [ -e "$TEST_TEMP/flag_at_pin" ] || fail "the identity flag was not written before the pin moved"
  [ -e "$flag" ] || fail "H9 left no identity flag"
  # the identity step clears the flag after a drop that succeeds
  _box_claude_live() { return 1; }
  _claude_json_drop_identity() { return 0; }
  _account_invalidate_identity_key "$key" "$CN"
  [ ! -e "$flag" ] || fail "the flag was not cleared after a successful drop"
  # but a drop deferred to a live box (rc 3) keeps the flag for the box to finish
  : > "$flag"
  _box_claude_live() { return 0; }
  run _account_invalidate_identity_key "$key" "$CN"
  assert_equal "$status" 3
  [ -e "$flag" ] || fail "a live drop wrongly cleared the flag"
}

@test "an attach refuses while this box is switching and the account lock stays busy" {
  _m2_mk_account work
  _box_account_write "$CN" work
  _host_clip_cmd() { echo ""; }
  _ACCOUNT_LOCK_WAIT_S=0
  hb_lock_plant "$(hb_lock_live_record)"

  # exec_claude: a requested ticket of this box with a live writer -> R-switching
  _handoff_ticket_write "$CN" "$EXECID" requested "$SID" work
  # If the final exit did harvest here, the switch holds the lock so it would
  # come back busy. Make that deterministic, so the test proves the harvest is
  # SKIPPED on the switching path rather than relying on there being no staged
  # file to harvest.
  _account_sync_out() { return "$_ACCOUNT_LOCK_BUSY"; }
  run exec_claude "$CN" --dangerously-skip-permissions
  assert_failure
  assert_output --partial "is switching accounts in another terminal"
  assert_output --partial "Run cleat again in a moment"
  # No session ran, so the final exit must not harvest and must not print the
  # busy "was not saved" line, which would contradict "Nothing was changed"
  # printed just above (the other terminal's switch owns the harvest).
  refute_output --partial "was not saved"
  unset -f _account_sync_out
  run grep -c "docker exec" "$DOCKER_CALLS"
  refute_output --partial "runuser -u coder -- claude"

  # busy with no requested ticket is P2's fail-safe: the attach goes on
  rm -f "$CLEAT_RUN_DIR/$CN"/.handoff.*
  run exec_claude "$CN" --dangerously-skip-permissions
  refute_output --partial "is switching accounts in another terminal"
  assert_output --partial "starts with the login it already has"

  # cmd_shell: the same gate, with its own retry line
  mkdir -p "$TEST_TEMP/project"
  local scn; scn="$(container_name_for "$TEST_TEMP/project")"
  mock_docker_ps "$scn"
  _host_open_cmd() { echo ""; }
  _handoff_ticket_write "$scn" "$EXECID" requested "$SID" work
  run cmd_shell "$TEST_TEMP/project"
  assert_failure
  assert_output --partial "is switching accounts in another terminal"
  assert_output --partial "Run cleat shell again in a moment"
}

# ── resume carry: the 1M size rule (M3, tests 43 and 44) ─────────────────────

@test "carry uses the conversation size as 1M evidence" {
  # No [1m] usage key, but the last real assistant turn summed past the standard
  # window, so it must have run with 1M. _resume_model_carry adds the suffix.
  local f="$TEST_TEMP/big.jsonl"
  printf '{"type":"assistant","message":{"role":"assistant","model":"claude-opus-5","usage":{"input_tokens":10,"cache_creation_input_tokens":40000,"cache_read_input_tokens":210000}}}\n' > "$f"
  run _resume_model_carry "$f"
  assert_success
  assert_output "claude-opus-5[1m]"
  # A conversation that fits the standard window gets no [1m] from its size.
  local s="$TEST_TEMP/small.jsonl"
  printf '{"type":"assistant","message":{"role":"assistant","model":"claude-opus-5","usage":{"input_tokens":10,"cache_creation_input_tokens":100,"cache_read_input_tokens":5000}}}\n' > "$s"
  run _resume_model_carry "$s"
  assert_success
  assert_output ""
}

@test "carry skips synthetic and API error records when it reads the size" {
  # At a usage limit the LAST assistant record is the synthetic rate-limit error
  # with zero usage. The size reader must skip it and read the real turn before.
  local f="$TEST_TEMP/limit.jsonl"
  {
    printf '{"type":"assistant","message":{"role":"assistant","model":"claude-opus-5","usage":{"input_tokens":10,"cache_creation_input_tokens":40000,"cache_read_input_tokens":210000}}}\n'
    printf '{"type":"assistant","isApiErrorMessage":true,"error":"rate_limit","message":{"role":"assistant","model":"<synthetic>","usage":{"input_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}\n'
  } > "$f"
  run _resume_last_usage_tokens "$f"
  assert_success
  assert_output "$(printf 'claude-opus-5\t250010')"
}

# ── terminal 2: classification, copy and orchestration (M4) ─────────────────
# These drive _account_handoff and _handoff_classify with the box exec faked by
# overriding _handoff_docker_exec: it writes a canned probe or terminate capture
# and returns a chosen code, so the whole host half runs with no daemon. A live
# attach marker is the test process itself ($$), so the marker-liveness checks
# pass without spawning anything.

t2_prep() {
  T2_PROJ="$TEST_TEMP/proj"; mkdir -p "$T2_PROJ"; _BOX=main
  T2_SDIR="$(_sessions_key_dir "$T2_PROJ" main)"; mkdir -p "$T2_SDIR"
  : > "$T2_SDIR/$SID.jsonl"
  mkdir -p "$CLEAT_PROJECTS_DIR/$(_derive_project_session_key "$T2_PROJ" main)"
  hb_marker "$CN" "$$" "kind=claude exec=$EXECID"
  _handoff_settle_pause() { :; }
}

# t2_exec PROBE_BODY [TERM_TEXT] [RC]: fake the box exec. PROBE_BODY is the lines
# between `args ok` and `end ok`.
t2_exec() {
  T2_PROBE="$(printf 'hb\t1\nargs\tok\n%s\nend\tok\n' "$1")"
  T2_TERM="${2:-}"; T2_RC="${3:-0}"
  _handoff_docker_exec() {
    local out="$3" verb="$4"
    case "$verb" in
      probe)     printf '%s' "$T2_PROBE" > "$out" ;;
      terminate) printf '%s' "$T2_TERM"  > "$out" ;;
    esac
    return "$T2_RC"
  }
}

# t2_rec PID PS STATUS WAITING STORE [EXEC] [SID]: one claude probe record.
t2_rec() {
  printf 'claude\t%s %s %s %s interactive %s %s %s' \
    "${1:-4242}" "${2:-5551}" "${3:-idle}" "${4:-none}" "${6:-$EXECID}" "${5:-named}" "${7:-$SID}"
}

# t2_term_ok [PID]: a clean terminate capture (one target exited).
t2_term_ok() { printf 'hb\t1\nargs\tok\nlock\tok\nrecheck\tok\npid\t%s exited\nscan\tok\nend\tok\n' "${1:-4242}"; }

t2_named_box() { _m2_mk_account old; _m2_mk_account work; _box_account_write "$CN" old; }

# ── classification (fixture records, portable) ──────────────────────────────

@test "handoff classify lets an idle relaunchable session go" {
  t2_prep; t2_named_box
  t2_exec "$(t2_rec 4242 5551 idle none named)"
  _handoff_probe "$CN"; _handoff_classify "$CN" 0 "$T2_PROJ" work
  assert_equal "$_HO_VERDICT" ok
  assert_equal "$_HO_N" 1
  assert_equal "${_HO_EXPECT[0]}" idle
}

@test "handoff classify refuses a turn in flight and lets it go only with now" {
  t2_prep; t2_named_box
  t2_exec "$(t2_rec 4242 5551 busy none named)"
  _handoff_probe "$CN"; _handoff_classify "$CN" 0 "$T2_PROJ" work
  assert_equal "$_HO_VERDICT" R1
  _handoff_probe "$CN"; _handoff_classify "$CN" 1 "$T2_PROJ" work
  assert_equal "$_HO_VERDICT" ok
  assert_equal "${_HO_EXPECT[0]}" now
}

@test "handoff classify refuses a permission prompt and a non permission question with its own reason" {
  t2_prep; t2_named_box
  t2_exec "$(t2_rec 4242 5551 waiting permission-prompt named)"
  _handoff_probe "$CN"; _handoff_classify "$CN" 0 "$T2_PROJ" work
  assert_equal "$_HO_VERDICT" R2p
  t2_exec "$(t2_rec 4242 5551 waiting input-needed named)"
  _handoff_probe "$CN"; _handoff_classify "$CN" 0 "$T2_PROJ" work
  assert_equal "$_HO_VERDICT" R2q
}

@test "handoff classify refuses background shell commands even with now" {
  t2_prep; t2_named_box
  t2_exec "$(printf '%s\nshell\tcccc2222dddd' "$(t2_rec 4242 5551 idle none named)")"
  _handoff_probe "$CN"; _handoff_classify "$CN" 1 "$T2_PROJ" work
  assert_equal "$_HO_VERDICT" R3
}

@test "handoff classify refuses a session with a shell status" {
  t2_prep; t2_named_box
  t2_exec "$(t2_rec 4242 5551 shell none named)"
  _handoff_probe "$CN"; _handoff_classify "$CN" 1 "$T2_PROJ" work
  assert_equal "$_HO_VERDICT" R3
}

@test "handoff classify lets a busy session with a background shell line through with now" {
  t2_prep; t2_named_box
  # A busy turn running a background command shows a shell line under the
  # session's own exec id, alongside the busy record.
  t2_exec "$(printf '%s\nshell\t%s' "$(t2_rec 4242 5551 busy none named)" "$EXECID")"
  # Without --now the busy turn refuses (offering --now), not the shell refusal.
  _handoff_probe "$CN"; _handoff_classify "$CN" 0 "$T2_PROJ" work
  assert_equal "$_HO_VERDICT" R1
  # With --now the session's own shell line is not a refusal: it is restarted,
  # and the target carries expect=now so the box recheck exempts the shell line.
  _handoff_probe "$CN"; _handoff_classify "$CN" 1 "$T2_PROJ" work
  assert_equal "$_HO_VERDICT" ok
  assert_equal "${_HO_EXPECT[0]}" now
  # A shell line under a different exec id still refuses, even with --now.
  t2_exec "$(printf '%s\nshell\tdddd4444eeee' "$(t2_rec 4242 5551 busy none named)")"
  _handoff_probe "$CN"; _handoff_classify "$CN" 1 "$T2_PROJ" work
  assert_equal "$_HO_VERDICT" R3
}

@test "handoff classify refuses a session with no exec id or a dead marker" {
  t2_prep; t2_named_box
  # a session whose exec id has no live marker (marker pid is dead)
  rm -f "$CLEAT_RUN_DIR/$CN"/.attached.*
  hb_marker "$CN" "$(hb_dead_pid)" "kind=claude exec=$EXECID"
  t2_exec "$(t2_rec 4242 5551 idle none named)"
  _handoff_probe "$CN"; _handoff_classify "$CN" 0 "$T2_PROJ" work
  assert_equal "$_HO_VERDICT" R4
  # a shell marker (kind=shell) is not a claude attach
  rm -f "$CLEAT_RUN_DIR/$CN"/.attached.*
  hb_marker "$CN" "$$" "kind=shell"
  _handoff_probe "$CN"; _handoff_classify "$CN" 0 "$T2_PROJ" work
  assert_equal "$_HO_VERDICT" R4
}

@test "handoff classify refuses an orphan Claude process" {
  t2_prep; t2_named_box
  t2_exec "$(printf '%s\norphan\t700' "$(t2_rec 4242 5551 idle none named)")"
  _handoff_probe "$CN"; _handoff_classify "$CN" 0 "$T2_PROJ" work
  assert_equal "$_HO_VERDICT" R4
}

@test "handoff classify refuses two processes sharing an exec id" {
  t2_prep; t2_named_box
  t2_exec "$(printf '%s\n%s' "$(t2_rec 4242 5551 idle none named)" "$(t2_rec 4243 5552 idle none named)")"
  _handoff_probe "$CN"; _handoff_classify "$CN" 0 "$T2_PROJ" work
  assert_equal "$_HO_VERDICT" R4
}

@test "handoff classify refuses a store that does not match the pin" {
  t2_prep; t2_named_box
  t2_exec "$(t2_rec 4242 5551 idle none default)"
  _handoff_probe "$CN"; _handoff_classify "$CN" 0 "$T2_PROJ" work
  assert_equal "$_HO_VERDICT" R4
}

@test "handoff classify refuses a session id without a transcript in this project" {
  t2_prep; t2_named_box
  rm -f "$T2_SDIR/$SID.jsonl"
  t2_exec "$(t2_rec 4242 5551 idle none named)"
  _handoff_probe "$CN"; _handoff_classify "$CN" 0 "$T2_PROJ" work
  assert_equal "$_HO_VERDICT" R4
}

@test "handoff classify refuses an unknown status and a failed probe" {
  t2_prep; t2_named_box
  t2_exec "$(t2_rec 4242 5551 frobnicate none named)"
  _handoff_probe "$CN"; _handoff_classify "$CN" 0 "$T2_PROJ" work
  assert_equal "$_HO_VERDICT" R5
}

@test "handoff classify refuses a conversation in the compaction band with no 1M evidence" {
  t2_prep; t2_named_box
  # A realistic last real turn: a normal nested assistant record with role, model
  # and usage, summing to 195000, inside the band [187000, 200000] and below the
  # window. No [1m] key, so the model carry is empty and H7 does not fire. cleat
  # cannot prove it ran with 1M, and reopening in the standard window would
  # compact it, so R7.
  printf '{"type":"assistant","message":{"role":"assistant","model":"claude-opus-5","usage":{"input_tokens":10,"cache_creation_input_tokens":40000,"cache_read_input_tokens":154990}}}\n' > "$T2_SDIR/$SID.jsonl"
  t2_exec "$(t2_rec 4242 5551 idle none named)"
  _handoff_probe "$CN"; _handoff_classify "$CN" 0 "$T2_PROJ" work
  assert_equal "$_HO_VERDICT" R7
}

@test "handoff classify does not refuse just below the compaction band floor" {
  t2_prep; t2_named_box
  # 186999, one token below the floor (STD_WINDOW - COMPACT_BUFFER = 187000):
  # there is still room to compact, so the standard window is safe and no R7.
  printf '{"type":"assistant","message":{"role":"assistant","model":"claude-opus-5","usage":{"input_tokens":10,"cache_creation_input_tokens":40000,"cache_read_input_tokens":146989}}}\n' > "$T2_SDIR/$SID.jsonl"
  t2_exec "$(t2_rec 4242 5551 idle none named)"
  _handoff_probe "$CN"; _handoff_classify "$CN" 0 "$T2_PROJ" work
  assert_equal "$_HO_VERDICT" ok
}

@test "handoff classify refuses right at the compaction band floor" {
  t2_prep; t2_named_box
  # Exactly 187000, the floor: at or above it the reopen could compact, so R7.
  printf '{"type":"assistant","message":{"role":"assistant","model":"claude-opus-5","usage":{"input_tokens":10,"cache_creation_input_tokens":40000,"cache_read_input_tokens":146990}}}\n' > "$T2_SDIR/$SID.jsonl"
  t2_exec "$(t2_rec 4242 5551 idle none named)"
  _handoff_probe "$CN"; _handoff_classify "$CN" 0 "$T2_PROJ" work
  assert_equal "$_HO_VERDICT" R7
}

@test "handoff classify does not refuse above the window because H7 carries 1M" {
  t2_prep; t2_named_box
  # 200001, above the standard window: H7 makes the model carry non-empty
  # (<model>[1m]), so the reopen carries 1M instead of refusing. No R7.
  printf '{"type":"assistant","message":{"role":"assistant","model":"claude-opus-5","usage":{"input_tokens":10,"cache_creation_input_tokens":40000,"cache_read_input_tokens":159991}}}\n' > "$T2_SDIR/$SID.jsonl"
  run _resume_model_carry "$T2_SDIR/$SID.jsonl"
  assert_output "claude-opus-5[1m]"
  t2_exec "$(t2_rec 4242 5551 idle none named)"
  _handoff_probe "$CN"; _handoff_classify "$CN" 0 "$T2_PROJ" work
  assert_equal "$_HO_VERDICT" ok
}

@test "handoff classify never refuses on context size when the size cannot be read" {
  t2_prep; t2_named_box
  : > "$T2_SDIR/$SID.jsonl"
  t2_exec "$(t2_rec 4242 5551 idle none named)"
  _handoff_probe "$CN"; _handoff_classify "$CN" 0 "$T2_PROJ" work
  assert_equal "$_HO_VERDICT" ok
}

@test "handoff classify refuses a live handoff to an account with no working login" {
  t2_prep; _m2_mk_account old; _box_account_write "$CN" old
  # target 'work' does not exist
  t2_exec "$(t2_rec 4242 5551 idle none named)"
  _handoff_probe "$CN"; _handoff_classify "$CN" 0 "$T2_PROJ" work
  assert_equal "$_HO_VERDICT" R6
}

@test "handoff classify lets the weekly limit question through only when the transcript confirms a limit" {
  t2_prep; t2_named_box
  # dialog open but no rate-limit record: not the limit question, so refused
  t2_exec "$(t2_rec 4242 5551 waiting dialog-open named)"
  _handoff_probe "$CN"; _handoff_classify "$CN" 0 "$T2_PROJ" work
  assert_equal "$_HO_VERDICT" R2q
  # the same dialog with a 429 as the last conversation record goes through
  printf '{"type":"assistant","isApiErrorMessage":true,"error":"rate_limit","message":{"role":"assistant","model":"claude-opus-5","usage":{"input_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}\n' > "$T2_SDIR/$SID.jsonl"
  _handoff_probe "$CN"; _handoff_classify "$CN" 0 "$T2_PROJ" work
  assert_equal "$_HO_VERDICT" ok
  assert_equal "${_HO_EXPECT[0]}" limitq
}

@test "handoff classify refuses while a session in another terminal is still starting" {
  t2_prep; t2_named_box
  # a second live marker with an exec id no probe record carries: row 8a
  hb_marker "$CN" "$$" "kind=claude exec=aaaa1111bbbb2222"
  t2_exec "$(t2_rec 4242 5551 idle none named)"
  _handoff_probe "$CN"; _handoff_classify "$CN" 0 "$T2_PROJ" work
  assert_equal "$_HO_VERDICT" R22
}

# ── disclosure copy ─────────────────────────────────────────────────────────

@test "handoff disclosure states the loss and the prompt cache cost before it acts" {
  t2_prep; t2_named_box
  t2_exec "$(t2_rec 4242 5551 idle none named)" "$(t2_term_ok)"
  _is_interactive() { return 0; }
  _ask_yn() { printf -v "$1" '%s' 'y'; }
  run _account_handoff work main "$CN" "$T2_PROJ" 0 0
  assert_success
  assert_output --partial "main has a live Claude session in another terminal (idle)."
  assert_output --partial "Handing it over to work restarts it there and reopens the same conversation."
  assert_output --partial "Anything typed there but not sent is lost."
  assert_output --partial "Any background agent or monitor it runs in this box stops with it."
  assert_output --partial "may read the whole conversation again without a prompt cache. That can use a large share of work's usage."
}

@test "handoff disclosure names the permission mode a session was in" {
  t2_prep; t2_named_box
  printf '{"type":"permission-mode","permissionMode":"plan"}\n' > "$T2_SDIR/$SID.jsonl"
  t2_exec "$(t2_rec 4242 5551 idle none named)" "$(t2_term_ok)"
  _account_handoff work main "$CN" "$T2_PROJ" 1 0 >/dev/null 2>&1 || true
  # render the disclosure directly for the plan-mode line
  _handoff_probe "$CN"; _handoff_classify "$CN" 0 "$T2_PROJ" work
  run _handoff_say_disclosure main work
  assert_output --partial "It was in plan mode. Check its mode there after it reopens."
}

@test "handoff disclosure says at its usage limit for a weekly limit question" {
  t2_prep; t2_named_box
  printf '{"type":"assistant","isApiErrorMessage":true,"error":"rate_limit","message":{"role":"assistant","model":"claude-opus-5","usage":{"input_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}\n' > "$T2_SDIR/$SID.jsonl"
  t2_exec "$(t2_rec 4242 5551 waiting dialog-open named)"
  _handoff_probe "$CN"; _handoff_classify "$CN" 0 "$T2_PROJ" work
  _HO_NOW_FLAG=0
  run _handoff_say_disclosure main work
  assert_output --partial "has a live Claude session in another terminal (at its usage limit)."
}

# ── orchestration ───────────────────────────────────────────────────────────

@test "handoff probes nothing when the account is already selected" {
  t2_prep; _m2_mk_account work; _box_account_write "$CN" work
  local probed=0
  _handoff_docker_exec() { probed=1; return 0; }
  run _account_handoff work main "$CN" "$T2_PROJ" 0 0
  assert_success
  assert_output --partial "main is already on account work"
  assert_equal "$probed" 0
  [ ! -e "$CLEAT_ACCOUNTS_DIR/.lock" ]
}

@test "handoff writes requested tickets before the signalling exec and ready only after the pin moved" {
  t2_prep; t2_named_box
  T2_TICKET_AT_TERM=""
  t2_exec "$(t2_rec 4242 5551 idle none named)" "$(t2_term_ok)"
  _handoff_docker_exec() {
    local out="$3" verb="$4"
    case "$verb" in
      probe) printf '%s' "$T2_PROBE" > "$out" ;;
      terminate)
        # the requested ticket must exist, and no ready ticket yet
        if [ -f "$CLEAT_RUN_DIR/$CN/.handoff.$EXECID" ] && grep -q 'state=requested' "$CLEAT_RUN_DIR/$CN/.handoff.$EXECID"; then
          printf 'requested\n' > "$TEST_TEMP/tk_at_term"
        fi
        printf '%s' "$T2_TERM" > "$out"
        ;;
    esac
    return 0
  }
  _is_interactive() { return 0; }; _ask_yn() { printf -v "$1" '%s' 'y'; }
  run _account_handoff work main "$CN" "$T2_PROJ" 1 0
  assert_success
  assert_output --partial "is now on account work"
  run cat "$TEST_TEMP/tk_at_term"; assert_output "requested"
  run cat "$CLEAT_RUN_DIR/$CN/.handoff.$EXECID"
  assert_output --partial "state=ready"
  assert_output --partial "to=work"
  run _box_account_read "$CN"; assert_output "work"
}

@test "handoff changes nothing and writes no ticket when the question is answered no" {
  t2_prep; t2_named_box
  t2_exec "$(t2_rec 4242 5551 idle none named)" "$(t2_term_ok)"
  _is_interactive() { return 0; }
  _ask_yn() { printf -v "$1" '%s' 'n'; }
  run _account_handoff work main "$CN" "$T2_PROJ" 0 0
  assert_success
  assert_output --partial "Kept. main stays on account old"
  run _box_account_read "$CN"; assert_output "old"
  [ ! -e "$CLEAT_RUN_DIR/$CN/.handoff.$EXECID" ]
  [ ! -e "$CLEAT_ACCOUNTS_DIR/.lock" ]
}

@test "handoff prints the cost lines before it acts" {
  t2_prep; t2_named_box
  t2_exec "$(t2_rec 4242 5551 idle none named)" "$(t2_term_ok)"
  _handoff_docker_exec() {
    local out="$3" verb="$4"
    case "$verb" in
      probe) printf '%s' "$T2_PROBE" > "$out" ;;
      terminate) printf 'DISC=%s\n' "${_HANDOFF_DISCLOSED:-0}" > "$TEST_TEMP/disc_at_term"; printf '%s' "$T2_TERM" > "$out" ;;
    esac
    return 0
  }
  _is_interactive() { return 0; }; _ask_yn() { printf -v "$1" '%s' 'y'; }
  run _account_handoff work main "$CN" "$T2_PROJ" 1 0
  assert_success
  run cat "$TEST_TEMP/disc_at_term"; assert_output "DISC=1"
}

@test "handoff refuses without a terminal after the cost lines unless yes is given" {
  t2_prep; t2_named_box
  t2_exec "$(t2_rec 4242 5551 idle none named)" "$(t2_term_ok)"
  _is_interactive() { return 1; }
  run _account_handoff work main "$CN" "$T2_PROJ" 0 0
  assert_failure
  assert_output --partial "main has a live Claude session in another terminal"
  assert_output --partial "Re-run with --yes to hand it over without a question."
  run _box_account_read "$CN"; assert_output "old"
  # with --yes it goes
  run _account_handoff work main "$CN" "$T2_PROJ" 1 0
  assert_success
  assert_output --partial "is now on account work"
}

@test "handoff takes the account lock after the question and never before" {
  t2_prep; t2_named_box
  t2_exec "$(t2_rec 4242 5551 idle none named)" "$(t2_term_ok)"
  _is_interactive() { return 0; }
  _ask_yn() { printf -v "$1" '%s' 'n'; }
  run _account_handoff work main "$CN" "$T2_PROJ" 0 0
  assert_success
  # answering no returned before any lock was ever taken
  [ ! -e "$CLEAT_ACCOUNTS_DIR/.lock" ]
}

@test "handoff changes nothing and writes no ticket when the account lock is busy" {
  t2_prep; t2_named_box
  t2_exec "$(t2_rec 4242 5551 idle none named)" "$(t2_term_ok)"
  _ACCOUNT_LOCK_WAIT_S=0
  hb_lock_plant "$(hb_lock_live_record)"
  run _account_handoff work main "$CN" "$T2_PROJ" 1 0
  assert_failure
  assert_output --partial "Another cleat command is changing accounts right now."
  run _box_account_read "$CN"; assert_output "old"
  [ ! -e "$CLEAT_RUN_DIR/$CN/.handoff.$EXECID" ]
}

@test "handoff refuses under the lock when the pin changed during the question" {
  t2_prep; t2_named_box
  t2_exec "$(t2_rec 4242 5551 idle none named)" "$(t2_term_ok)"
  _is_interactive() { return 0; }
  # the answer races a switch that repins the box before the lock is taken
  _ask_yn() { _box_account_write "$CN" other; printf -v "$1" '%s' 'y'; }
  run _account_handoff work main "$CN" "$T2_PROJ" 0 0
  assert_failure
  assert_output --partial "changed while you were answering"
  run _box_account_read "$CN"; assert_output "other"
}

@test "handoff refuses a live switch with a cleat shell open before it signals the session" {
  t2_prep; t2_named_box
  # a live cleat shell marker (kind=shell) alongside the live claude marker: a
  # named to shared move with a shell open must refuse under the lock BEFORE the
  # terminate exec, never stop the live session first.
  sleep 30 & local sp=$!
  hb_marker "$CN" "$sp" "kind=shell"
  t2_exec "$(t2_rec 4242 5551 idle none named)" "$(t2_term_ok)"
  # record every box exec so the test can prove the terminate never ran
  local calls="$TEST_TEMP/exec_calls"; : > "$calls"
  _handoff_docker_exec() {
    local out="$3" verb="$4"; printf '%s\n' "$verb" >> "$calls"
    case "$verb" in
      probe)     printf '%s' "$T2_PROBE" > "$out" ;;
      terminate) printf '%s' "$T2_TERM"  > "$out" ;;
    esac
    return 0
  }
  run _account_handoff default main "$CN" "$T2_PROJ" 1 0
  kill "$sp" 2>/dev/null || true
  assert_failure
  assert_output --partial "has a cleat shell open in another terminal"
  # the live session was never signalled: the terminate exec did not run
  run grep -c terminate "$calls"; assert_output "0"
  # and the box stays on the old account
  run _box_account_read "$CN"; assert_output "old"
}

@test "handoff refuses and reopens every session including the survivor on the old account when one target survives" {
  t2_prep; t2_named_box
  local EXEC2="cafe5678babe9012" SID2="aaaaaaaa-1111-2222-3333-444455556666"
  : > "$T2_SDIR/$SID2.jsonl"
  # a second live marker with its own live pid for the survivor session
  sleep 30 & local p2=$!
  hb_marker "$CN" "$p2" "kind=claude exec=$EXEC2"
  local body; body="$(printf '%s\n%s' \
    "$(t2_rec 4242 5551 idle none named "$EXECID" "$SID")" \
    "$(t2_rec 4243 5552 idle none named "$EXEC2" "$SID2")")"
  local term; term="$(printf 'hb\t1\nargs\tok\nlock\tok\nrecheck\tok\npid\t4242 exited\npid\t4243 alive\nend\tabort\n')"
  t2_exec "$body" "$term"
  run _account_handoff work main "$CN" "$T2_PROJ" 1 0
  kill "$p2" 2>/dev/null || true
  assert_failure
  # the wait named is the real kill wait (8 s), not a stale value
  assert_output --partial "did not stop within 8 seconds"
  run _box_account_read "$CN"; assert_output "old"
  # the target that DID exit gets a ready ticket for the old account
  run cat "$CLEAT_RUN_DIR/$CN/.handoff.$EXECID"
  assert_output --partial "state=ready"
  assert_output --partial "to=old"
  # the survivor gets a ready ticket for the old account too (4.4 row 27): its
  # own terminal 1 reopens it there once it finally stops
  run cat "$CLEAT_RUN_DIR/$CN/.handoff.$EXEC2"
  assert_output --partial "state=ready"
  assert_output --partial "to=old"
}

@test "handoff never moves the pin when terminate did not end ok" {
  t2_prep; t2_named_box
  t2_exec "$(t2_rec 4242 5551 idle none named)" "$(printf 'hb\t1\nargs\tok\nlock\tok\nrecheck\tok\npid\t4242 exited\nscan\tok\nend\tabort\n')"
  run _account_handoff work main "$CN" "$T2_PROJ" 1 0
  assert_failure
  run _box_account_read "$CN"; assert_output "old"
  refute_output --partial "is now on account work"
}

@test "handoff stops writing when another command took the account lock over" {
  t2_prep; t2_named_box
  T2_PROBE="$(printf 'hb\t1\nargs\tok\n%s\nend\tok\n' "$(t2_rec 4242 5551 idle none named)")"
  T2_TERM="$(t2_term_ok)"
  _handoff_docker_exec() {
    local out="$3" verb="$4"
    case "$verb" in
      probe) printf '%s' "$T2_PROBE" > "$out" ;;
      terminate) printf 'host other pid 999999 at 1\n' > "$CLEAT_ACCOUNTS_DIR/.lock/owner"; printf '%s' "$T2_TERM" > "$out" ;;
    esac
    return 0
  }
  run _account_handoff work main "$CN" "$T2_PROJ" 1 0
  assert_failure
  assert_output --partial "Another cleat command took over while main was switching."
  run _box_account_read "$CN"; assert_output "old"
}

@test "handoff ignores Ctrl-C from the lock through the exec" {
  t2_prep; t2_named_box
  T2_PROBE="$(printf 'hb\t1\nargs\tok\n%s\nend\tok\n' "$(t2_rec 4242 5551 idle none named)")"
  T2_TERM="$(t2_term_ok)"
  _handoff_docker_exec() {
    local out="$3" verb="$4"
    case "$verb" in
      probe) printf '%s' "$T2_PROBE" > "$out" ;;
      terminate) trap -p INT > "$TEST_TEMP/inttrap"; printf '%s' "$T2_TERM" > "$out" ;;
    esac
    return 0
  }
  run _account_handoff work main "$CN" "$T2_PROJ" 1 0
  assert_success
  run cat "$TEST_TEMP/inttrap"
  assert_output --partial "''"
}

@test "handoff writes the ready ticket before it captures meta" {
  t2_prep; t2_named_box
  t2_exec "$(t2_rec 4242 5551 idle none named)" "$(t2_term_ok)"
  _account_capture_meta() {
    if [ -f "$CLEAT_RUN_DIR/$CN/.handoff.$EXECID" ] && grep -q 'state=ready' "$CLEAT_RUN_DIR/$CN/.handoff.$EXECID"; then
      printf 'ready\n' > "$TEST_TEMP/ready_at_meta"
    fi
    return 0
  }
  run _account_handoff work main "$CN" "$T2_PROJ" 1 0
  assert_success
  run cat "$TEST_TEMP/ready_at_meta"; assert_output "ready"
}

@test "handoff reopens only the sessions that stopped" {
  t2_prep; t2_named_box
  # the one target died on its own before the signal: reported gone, not exited
  t2_exec "$(t2_rec 4242 5551 idle none named)" "$(printf 'hb\t1\nargs\tok\nlock\tok\nrecheck\tok\npid\t4242 gone\nscan\tok\nend\tok\n')"
  run _account_handoff work main "$CN" "$T2_PROJ" 1 0
  assert_success
  assert_output --partial "is now on account work"
  # a gone session never ended on this login, so it is not asked to reopen
  [ ! -e "$CLEAT_RUN_DIR/$CN/.handoff.$EXECID" ]
}

@test "handoff going to the shared login unpins the box and reopens on the shared login" {
  t2_prep; _m2_mk_account old; _box_account_write "$CN" old
  t2_exec "$(t2_rec 4242 5551 idle none named)" "$(t2_term_ok)"
  run _account_handoff default main "$CN" "$T2_PROJ" 1 0
  assert_success
  assert_output --partial "is back on your shared login"
  assert_output --partial "reopening on your shared login"
  run _box_account_read "$CN"; assert_output "default"
  run cat "$CLEAT_RUN_DIR/$CN/.handoff.$EXECID"
  assert_output --partial "to=default"
}

# ── golden copy ─────────────────────────────────────────────────────────────

hb_render_copy() {
  # Every user-visible handoff line, colours off, into stdout. The order is
  # fixed so the fixture is stable. Sample account names: main (box), b, a. The
  # accounts dir is pinned to a placeholder so the fixture does not carry the
  # test's random temp path (R14 quotes it).
  local CLEAT_ACCOUNTS_DIR="/home/you/.config/cleat/accounts"
  _HO_N=1; _HO_STATUS=(idle); _HO_WAIT=(none); _HO_LIMIT=(0); _HO_MODE=(""); _HO_VER=(""); _HO_TARGET_PLAN=""; _HO_NOW_FLAG=0
  echo "# disclosure, one idle session"
  _handoff_say_disclosure main b
  echo "# disclosure, at a usage limit, with now, a busy and a plan mode and pro and an old version"
  _HO_N=1; _HO_STATUS=(busy); _HO_WAIT=(none); _HO_LIMIT=(1); _HO_MODE=(plan); _HO_VER=(2.1.999); _HO_TARGET_PLAN=pro; _HO_NOW_FLAG=1
  _handoff_say_disclosure main b
  echo "# disclosure, two sessions"
  _HO_N=2; _HO_STATUS=(idle idle); _HO_WAIT=(none none); _HO_LIMIT=(0 0); _HO_MODE=("" ""); _HO_VER=("" ""); _HO_TARGET_PLAN=""; _HO_NOW_FLAG=0
  _handoff_say_disclosure main b
  echo "# refusals"
  local id
  for id in R1 R2p R2q R3 R6 R7 R9 R11 R12 R13 R14 R16 R18 R19 R20 R21 R22; do
    _handoff_say_refusal "$id" main b
  done
  _handoff_say_refusal R15 main b
  echo "# results"
  _handoff_say_result S1 main b
  _handoff_say_result S1d main
  _handoff_say_result S3 main b
  _handoff_say_result S3m main b 2
  _handoff_say_result S4r main
  _handoff_say_result Q2 main a
  echo "# warnings"
  for id in W1 W2 W3 W4 W34second W5 W6 W7 W10; do
    _handoff_say_warn "$id" main a b
  done
  _handoff_say_warn W11 main a held-01
  echo "# confirmations"
  for id in C1 C1b C2 C2b C3 C4 C8 C9; do
    _handoff_say_confirm "$id" b
  done
  _handoff_say_confirm C5 b 2
  _handoff_say_confirm C6 b 3 1
  _handoff_say_confirm C7 b
  _handoff_say_confirm W6b b 1 a
  echo "# shared-login phrasings"
  _handoff_say_disclosure main default
  _handoff_say_result S1d main
  _handoff_say_result S3 main default
  _handoff_say_warn W1 main default default
}

@test "handoff copy matches the golden file" {
  local got="$TEST_TEMP/copy.txt"
  hb_render_copy > "$got"
  if [[ "${CLEAT_UPDATE_GOLDEN:-}" == 1 ]]; then cp "$got" "$BATS_TEST_DIRNAME/../fixtures/handoff_copy.txt"; fi
  run diff -u "$BATS_TEST_DIRNAME/../fixtures/handoff_copy.txt" "$got"
  assert_success
}

@test "handoff copy has no em dash no semicolon and no comma and" {
  local got="$TEST_TEMP/copy.txt"
  hb_render_copy > "$got"
  run grep -nP '\x{2014}' "$got"; assert_failure
  run grep -nF ';' "$got"; assert_failure
  run grep -nF ', and ' "$got"; assert_failure
}

@test "handoff classify refuses a non interactive session kind" {
  t2_prep; t2_named_box
  # a bg/daemon kind is not an interactive session cleat can reopen
  t2_exec "$(printf 'claude\t4242 5551 idle none bg %s named %s' "$EXECID" "$SID")"
  _handoff_probe "$CN"; _handoff_classify "$CN" 0 "$T2_PROJ" work
  assert_equal "$_HO_VERDICT" R4
}
