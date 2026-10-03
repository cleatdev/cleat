# egress-release.d/40-long.sh: sitting 3: 3.0 to 3.5 (Docker Desktop quit, sleep, the night, the final cleanup).
#
# A part of egress-release.sh. Sourced, never run. It holds only function definitions, reg calls
# and comments: nothing else runs at source time. One function per step, named st_ plus the id
# with . and - turned into _, registered in scenario order with
#   reg ID SITTING KIND CLASS FUNC "TITLE"
# The steps, their checks and their re-entry rules are DESIGN.md section 6.2. A helper this part
# needs that the library lacks is written here, prefixed with the part's number (p40_).
#
# Every expected string below was read in the candidate first (bin/cleat, docker/ or
# docker/gateway/ at ac6ee85) and carries its source line. Where the script departs from the
# scenario, or the code and the scenario differ, the comment says so:
#   - 3.1a asks for one message in Claude Code. 3.1d, 3.1e, 3.2 and 3.3a reopen eg-restart with
#     cleat resume, which reopens the newest conversation (bin/cleat:22993 to 23012) and, with no
#     conversation at all, opens no session (Claude Code's own "No conversation found"). A resume
#     that finds none is a NOTE, never a FAIL. Its checks still run.
#   - 3.1b, 3.1e, 3.2 and 3.4dd: the session in T1 ends by itself when the engine goes. What T1
#     printed is read back (typed and auto mode) or asked (human mode). No /exit is asked unless
#     Claude Code still shows in T1. F5 (ac6ee85): that session end never says "Out of memory.
#     The box hit its memory ceiling" (_maybe_explain_oom, bin/cleat:20351, now prints it only
#     for a box still running after a 137 or one Docker marks OOMKilled). It is a FAIL tagged (F5)
#     read from T1's session-end region, or a question whose n is a FAIL in human mode.
#   - 3.1c computes the status row it expects from Docker's state read just before and just after
#     cleat egress status: the daemon may start the gateway again between egread and status.
#   - 3.1-down runs only while Docker Desktop is quit (sim and a Docker that answers: SKIP).
#   - 3.3a and 3.4ev read the sleep assertions up to three times (the human turns keep-awake off
#     in between). Something still holding sleep after that is a FAIL, as the scenario requires.
#   - 3.3b reads the probe log until two requests followed the sleep (at most three minutes after
#     the wake). It compares the box's stamps with the wake through the VM clock offset egread
#     measured after the wake. The wake comes from pmset's log, else from your answer. Any gap of
#     five minutes or more counts as the sleep's (DarkWakes may cut one sleep into several gaps).
#   - 3.4ev clones with GIT_TERMINAL_PROMPT=0 and ssh in batch mode, so a credential prompt fails
#     at once instead of stopping a background job. You can then clone by hand.
#   - 3.4am waits in place until the night has lasted MT_MIN_NIGHT_HOURS (d goes on early, which
#     is a FAIL) and prints every 000 minute beside the sleep windows of a longer pmset read than
#     the scenario's tail -40, so you judge them with the windows in front of you.
#   - 3.5 offers only the transcript directories whose names cleat itself derives for the test
#     projects (_derive_project_session_key, bin/cleat:761), never a glob match of another project.
#     Every delete question has two good answers, so each is a choose with keep first.
#   - 3.4b-ev and 3.4b-am record lab-b's state word alone (ok, re-login or signed out,
#     _account_auth_state bin/cleat:29054). The account list stays out of the transcript (cl -q).
#     3.4b-am offers to wait until MT_MIN_NIGHT_HOURS have passed since the gateway stopped.
#   - 3.2 lists the VM processes from full command lines (ps -axo pid=,command=), not the
#     scenario's ps -axco: macOS -c cuts a name at 16 characters (com.docker.virtu).
#   - 3.4ev records the packs by name and counts typed hosts (a host can name an organisation).
#     The full list stays in kv night.packs, private like night.repo.
#   - 3.5 offers the debug files of every test session (the ids are the transcript file names),
#     not only the two 2.25 named.
#   - 3.3b and 3.4lid read the sleep from pmset's last 400 lines, not 40: DarkWakes can push the
#     Clamshell Sleep line out of 40. Sleeps and windows are recorded in UTC, like the probe log.
#   - 3.4am asks nothing when the probe log holds no 000 (a PASS) and fails an empty probe log.
#
# Helpers (p40_): p40_is_int, p40_projects, p40_cd, p40_ask, p40_ask_record, p40_up, p40_dk_up,
# p40_live, p40_running, p40_nfail, p40_egread, p40_rd, p40_403, p40_reach, p40_order, p40_case,
# p40_state_check, p40_has, p40_row_for, p40_capture_launch, p40_ask_lines, p40_no_conversation,
# p40_launch, p40_need_live, p40_end_session, p40_tail_text, p40_join, p40_quit_end,
# p40_policy_vals, p40_keepawake, p40_probe_start, p40_awk_epoch, p40_probe_eval, p40_kv_of,
# p40_health_sum, p40_pm_windows, p40_win_text, p40_sleep_len, p40_classify_000, p40_acct_names,
# p40_acct_state, p40_night_secs, p40_epoch_utc, p40_vm_choices. Then pipelines run only through
# run_cmd or val (or a wait_for condition): p40_docker_info, p40_probe_count, p40_probe_has_line,
# p40_probe_tail, p40_probe_all, p40_pm_log, p40_vm_procs, p40_serving, p40_gw_count,
# p40_vol_count, p40_hostfiles, p40_session_key, p40_realcfg_count, p40_night_done,
# p40_since_done.

# ---------------------------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------------------------

p40_is_int() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac; return 0; }

# p40_projects: the test projects of DESIGN 6.3 (the scenario's 3.5 list plus eg-contain and eg-other).
p40_projects() {
  printf '%s\n' eg-default eg-pull eg-smoke eg-refuse eg-check eg-setup eg-lock eg-fork eg-old eg-spec4 \
    eg-core eg-rerun eg-rm eg-sweep eg-sweep2 eg-sweep3 eg-restart eg-night eg-stale eg-contain eg-other
}

# p40_cd PROJ [make]: into $P/PROJ. make: mkdir -p first. A dry run makes it inside its own home.
p40_cd() {
  local d="$P/$1"
  if [ "${2:-}" = make ] || [ "${DRY:-0}" = 1 ]; then mkdir -p "$d" || fatal "cannot create $d"; fi
  [ -d "$d" ] || step_abort "no project $d: run the step that makes it first"
  cd "$d" || step_abort "cannot cd to $d"
}

# p40_ask, p40_ask_record: ask and ask_record asked again while the answer is r (rc 5 records
# nothing, so a repeat must never end the question). The rc of the last answer.
p40_ask() { local r=0; while :; do ask "$@"; r=$?; [ "$r" = 5 ] || return "$r"; done; }
p40_ask_record() { local r=0; while :; do ask_record "$@"; r=$?; [ "$r" = 5 ] || return "$r"; done; }

# The state reads a step branches on. In a dry run each gives the answer its caller passes as
# DRYRC (default 1, "no"), so the dry walk goes down the branch that does the most.
p40_docker_info() { command docker info > /dev/null 2>&1; }
p40_dk_up() { [ "${DRY:-0}" = 1 ] && return "${1:-1}"; mt__probe 30 p40_docker_info; }
p40_live() { [ "${DRY:-0}" = 1 ] && return "${2:-1}"; mt__probe 90 box_claude_live "$1"; }
p40_running() { [ "${DRY:-0}" = 1 ] && return "${2:-1}"; mt__probe 60 box_running "$1"; }
# p40_up PROJ: the box is up, from Docker (no dry answer: callers abort on a no).
p40_up() { [ "${DRY:-0}" = 1 ] && return 0; mt__probe 60 box_running "$1"; }

# p40_nfail: the failures recorded so far in this attempt.
p40_nfail() { awk -F'\t' '$2 == "FAIL" || $2 == "TIMEOUT" || $2 == "HUMAN-FAIL" { n++ } END { print n + 0 }' "$STEP_DIR/checks.tsv" 2>/dev/null; }

# p40_egread PROJ: the scenario's egread. P40_RN is the reading's number (kv read.N.*), empty in a
# dry run or when nothing was recorded.
p40_egread() {
  local before after
  before=$(kv_get read.last 0)
  run_cmd -t 300 -n "egread $1" -- egread "$1"
  P40_RN=""
  [ "${DRY:-0}" = 1 ] && return 0
  after=$(kv_get read.last 0)
  if p40_is_int "$after" && [ "$after" != "$before" ]; then
    P40_RN="$after"
  else
    check_note "egread $1 recorded no reading"
  fi
  return 0
}
# p40_rd KEY: a field of the last p40_egread (box.exit, gw.started, vol.created, relay.again...).
p40_rd() { [ -n "${P40_RN:-}" ] || return 0; kv_get "read.$P40_RN.$1" ""; }

# p40_403 [FILE]: the denial of example.org, head and body, exactly as 1.3a quotes it.
p40_403() {
  local f="${1:-$OUT}"
  expect_contains "the 403 status line" "HTTP/1.1 403 cleat egress: example.org is not on the allowlist" "$f"   # gateway.py:197,230
  expect_contains "X-Cleat-Reason: policy" "X-Cleat-Reason: policy" "$f"                                      # gateway.py:236
  expect_contains "the body's first sentence" "cleat egress: example.org is not on the allowlist." "$f"       # gateway.py:219
  expect_contains "the body says it is not an outage" "This is a Cleat policy decision, not a network outage and not an" "$f"   # gateway.py:186
  expect_contains "the body says it is not an authentication failure" "authentication failure." "$f"          # gateway.py:187
  expect_contains "the body names the fix" "Ask the user to run: cleat egress allow example.org" "$f"        # gateway.py:202
}
# p40_reach PROJ: steps 5 and 6 again: 200 from example.com, then the 403 and its body.
p40_reach() {
  local code=""
  val code -t 60 -- bget "$1" https://example.com/
  expect_eq "bget $1 https://example.com/ answers 200 (step 5)" "$code" 200
  run_cmd -t 60 -- bconnect "$1" example.org:443
  p40_403
}

# p40_order PROJ [KEPT]: the scenario's docker inspect of the gateway and the box (the gateway
# first): the gateway started before the box. KEPT: the StartedAt the gateway must still hold.
p40_order() {
  local proj="$1" kept="${2:-}" g="" c="" gs="" cs="" r=""
  val g -t 60 -- gw "$proj"
  val c -t 60 -- cn "$proj"
  P40_GS=""
  if [ "${DRY:-0}" != 1 ] && { [ -z "$g" ] || [ -z "$c" ]; }; then
    check_fail "the gateway and the box of $proj exist" "both" "gateway '${g:-none}', box '${c:-none}'"
    return 1
  fi
  dk -t 60 -- inspect -f '{{.Name}} {{.State.StartedAt}}' "$g" "$c"
  gs=$(awk -v n="/$g" '$1 == n { print $2; exit }' "$OUT" 2>/dev/null)
  cs=$(awk -v n="/$c" '$1 == n { print $2; exit }' "$OUT" 2>/dev/null)
  P40_GS="$gs"
  if [ "${DRY:-0}" = 1 ]; then
    expect_eq "the gateway started before the box" "" ""
    return 0
  fi
  record_value "$STEP_ID.order" "gateway $gs, box $cs" "both start times (the gateway first)"
  r=$(iso_cmp "$gs" "$cs")
  case "$r" in
    lt) check_pass "the gateway started before the box" "gateway $gs, box $cs" ;;
    *) check_fail "the gateway started before the box" "the gateway's StartedAt earlier" "gateway ${gs:-unread}, box ${cs:-unread} (${r:-unreadable})" ;;
  esac
  if [ -n "$kept" ]; then
    expect_eq "the gateway the daemon started again is kept (its StartedAt did not move)" "$gs" "$kept"
  fi
  return 0
}

# p40_case: the reading P40_RN as the scenario's two cases. w4: the box at exit 255 (the VM went
# before the containers stopped). clean: both stopped and the box not at 255. Else other.
p40_case() {
  local bx bex gr
  bx=$(p40_rd box.running); bex=$(p40_rd box.exit); gr=$(p40_rd gw.running)
  if [ "$bex" = 255 ]; then printf 'w4\n'
  elif [ "$bx" = false ] && [ "$gr" = false ]; then printf 'clean\n'
  else printf 'other\n'; fi
}

# p40_state_check PROJ: cleat egress status names the state Docker holds now. The rows expected
# are computed from Docker's state read just before and just after the status call (the daemon
# can start a gateway in between, so either reading's row is accepted then).
p40_state_check() {
  local proj="$1" s1="" s2="" b1=1 b2=1 f="" w1="" w2="" bdown=1
  val s1 -t 60 -- gw_state "$proj"
  run_cmd -q -t 60 -- box_running "$proj"; b1=$RC
  cl -- egress status
  f="$OUT"
  val s2 -t 60 -- gw_state "$proj"
  run_cmd -q -t 60 -- box_running "$proj"; b2=$RC
  first_lines 6 "$f"
  record_value "$STEP_ID.status" "$(p40_join "$OUT")" "cleat egress status, first 6 lines"
  w1=$(p40_row_for "$s1" "$b1"); w2=$(p40_row_for "$s2" "$b2")
  if [ "${DRY:-0}" = 1 ]; then
    expect_contains "status names the state" "Gateway"
    return 0
  fi
  if [ "$b1" = 0 ] || [ "$b2" = 0 ]; then bdown=0; fi
  if [ "$bdown" = 1 ]; then
    expect_not_contains "never Gateway healthy while the box is down" "Gateway healthy"   # bin/cleat:14647
  fi
  if [ "$w1" = "$w2" ]; then
    expect_contains "status names the state Docker holds (${s2%% *}, box $( [ "$b2" = 0 ] && printf running || printf stopped))" "$w2"
  else
    check_note "the state changed during cleat egress status ($s1 then $s2): either row is accepted"
    if p40_has "$w1" || p40_has "$w2"; then
      check_pass "status names one of the two states Docker held" "$w1 or $w2"
    else
      check_fail "status names one of the two states Docker held" "$w1 or $w2" "$(awk 'NF' "$OUT" | head -n 3 | tr '\n' ' ')"
    fi
  fi
  return 0
}
p40_has() { LC_ALL=C grep -q -F -e "$1" "$OUT" 2>/dev/null; }
# p40_row_for GWSTATE BOXRC: the status row for a gateway state (gw_state's first word) and the
# box (BOXRC 0 running). bin/cleat:14642 to 14688 (_egress_status_gateway_row).
p40_row_for() {
  local s="${1%% *}" b="$2"
  case "$s" in
    running)
      if [ "$b" = 0 ]; then printf '%s' "Gateway healthy"                                     # bin/cleat:14647
      else printf '%s' "! Gateway orphaned      running, but its box is not"; fi ;;          # bin/cleat:14680
    exited|created|dead)
      if [ "$b" = 0 ]; then printf '%s' "x Gateway stopped       exited, "                   # bin/cleat:14666
      else printf '%s' "○ Gateway stopped       its box is stopped too"; fi ;;              # bin/cleat:14675
    restarting) printf '%s' "Gateway" ;;
    *) printf '%s' "x Gateway missing       no gateway container for this box" ;;          # bin/cleat:14685
  esac
}

# ---- T1 and T3 ----
# p40_capture_launch T TAG: OUT is T's capture narrowed to the launch region. rc 1 when T cannot
# be read back (human mode, a typed mode that dropped), or when Terminal's history lost the launch
# summary (Claude Code can clear the scrollback when it draws): the human is asked then.
p40_capture_launch() {
  t_have_capture || return 1
  t_capture "$1" "$2" || return 1
  t_region launch
  if [ "$(t_mode)" = typed ] && [ "${DRY:-0}" != 1 ] && ! LC_ALL=C grep -q 'Egress:' "$OUT" 2>/dev/null; then
    check_note "the history of $1 holds no Egress: line after the command (Claude Code may have cleared the scrollback when it drew): asked instead"
    return 1
  fi
  return 0
}
# p40_ask_lines TAG T SPEC...: the one question t_checks_or_ask asks without a capture, for T.
p40_ask_lines() {
  local tag="$1" T="$2" s yes="" no=""
  shift 2
  for s in "$@"; do
    case "$s" in
      +*) yes="$yes${yes:+
}${s#+}" ;;
      \~*) yes="$yes${yes:+
}(a line like) ${s#\~}" ;;
      -*) no="$no${no:+
}${s#-}" ;;
    esac
  done
  [ -z "$yes" ] || yes="$T printed these lines:
$yes"
  [ -z "$no" ] || no="$T printed none of these:
$no"
  p40_ask "$tag" "$T" "Read what $T printed when the command started, before Claude Code opened." "$yes${yes:+${no:+
}}$no" "Did $T print exactly that?"
}
# p40_no_conversation T: rc 0 when the cleat resume that just ended in T opened no Claude because
# Claude Code found no conversation to continue. Read from T when it can be, else asked.
p40_no_conversation() {
  local t="$1" T r=0
  T=$(printf '%s' "$t" | tr 'a-z' 'A-Z')
  if t_have_capture; then
    if t_capture "$t" resume-end && [ -f "$OUT" ] && LC_ALL=C grep -q -i -e 'no conversation found' "$OUT"; then
      return 0
    fi
    [ "$(t_mode)" = typed ] || return 1
  fi
  p40_ask_record noconv "$T" "Read what $T printed after cleat resume, below its summary." "Did it end on Claude Code's own words No conversation found to continue, with no Claude session opened?"
  r=$?
  [ "$r" = 0 ]
}
# p40_launch T PROJ CMD TAG SECS [SPEC...]: [T launch CMD in PROJ] (DESIGN 6.2 notation): the run,
# the wait for Claude Code, then the launch region against the specs (+ printed, - never, ~ ERE).
# P40_LRC is t_wait_launch's code: 0 live, 1 ended without Claude, 2 skipped, 3 timed out.
p40_launch() {
  local t="$1" proj="$2" cmd="$3" tag="$4" secs="$5" T
  shift 5
  T=$(printf '%s' "$t" | tr 'a-z' 'A-Z')
  P40_LRC=0
  t_ensure "$t"
  t_run "$t" "$proj" "$cmd"
  t_front "$t"
  t_wait_launch "$t" "$proj" "$secs"
  P40_LRC=$?
  case "$P40_LRC" in
    0) check_pass "Claude Code opened in $T ($cmd in $proj)" ;;
    1)
      if [ "$cmd" = "cleat resume" ] && p40_no_conversation "$t"; then
        check_note "$cmd in $proj found no conversation to reopen (Claude Code's own No conversation found): no Claude session. The box and its gateway are up and the checks go on"
      else
        check_fail "Claude Code opened in $T ($cmd in $proj)" "a live Claude Code in the box" "the command ended without opening Claude"
      fi ;;
    2) check_note "the wait for Claude Code in $T was skipped ($cmd in $proj)" ;;
    *) check_fail "Claude Code opened in $T ($cmd in $proj)" "a live Claude Code within $secs s" "no Claude Code after $secs s" ;;
  esac
  [ $# -gt 0 ] || return 0
  if p40_capture_launch "$t" "$tag"; then
    t_checks_or_ask "$tag" "$@"
  else
    p40_ask_lines "$tag" "$T" "$@"
  fi
  return 0
}
# p40_need_live PROJ TAG: Claude Code live in PROJ, resumed in T1 when it is not.
p40_need_live() {
  if p40_live "$1"; then return 0; fi
  check_note "Claude Code is not open in $1: T1 resumes it first"
  p40_launch t1 "$1" "cleat resume" "$2" 600 "-Egress refused"
}
# p40_end_report PROJ KEY: T1's session in PROJ ended with Docker up, its session-end report read
# for the relay advisory (W3, the four lines 2.16c reads). KEY names the capture and the reading.
p40_end_report() {
  local proj="$1" key="$2"
  if ! p40_live "$proj" 0; then
    check_note "Claude Code is not open in $proj: no session-end report to read (W3 rests on status alone)"
    return 0
  fi
  t_wait_exit t1 "$proj" 600
  kv_set "$key.ended" "$(utc_stamp)"
  if t_have_capture && t_capture t1 "$key"; then
    t_region end
    if [ "${DRY:-0}" != 1 ] && [ ! -s "$OUT" ]; then
      if t_is_auto; then
        check_skip "the session-end report in T1" "T1 simulated: the session ended with Ctrl-C, so no session-end report"
      else
        check_fail "T1 printed the session-end line" "Session ended. Resume with: cleat resume" "not in T1's text"   # bin/cleat:20274
      fi
      return 0
    fi
    record_value "$key" "$(p40_tail_text "$OUT" 8)" "T1's session-end report (the last lines)"
  fi
  t_checks_or_ask "$key" \
    "+! Shim not listening  the in-box relay has not been heard from" \
    "+If requests fail, they fail before they reach the policy." \
    "+This is not a policy denial." \
    "+Fix:  cleat egress restart --shim"   # bin/cleat:11464-11467
  return 0
}
# p40_end_session T PROJ: Claude Code in PROJ ended through T (the human types /exit, auto mode
# sends Ctrl-C). Nothing when no session runs there.
p40_end_session() {
  if ! p40_live "$2"; then return 0; fi
  check_note "Claude Code still runs in $2: its session ends first"
  t_wait_exit "$1" "$2" 600
  return 0
}
# p40_tail_text FILE N: the last N lines of FILE that hold text, redacted, on one line.
p40_tail_text() { awk 'NF' "$1" 2>/dev/null | tail -n "$2" | redact | p40_join; }
# p40_join [FILE]: the lines that hold text (FILE, else stdin), leading blanks cut, joined by " | ".
p40_join() { awk 'NF { sub(/^[ \t]+/, ""); printf "%s%s", (k++ ? " | " : ""), $0 } END { if (k) print "" }' ${1+"$1"} 2>/dev/null; }
# p40_shim_read: cleat egress status's Gateway and Shim rows into OUT, the moment the read started
# into P40_SR_AT (host epoch) and P40_SR_L (1 when the rows say Shim listening, else 0).
p40_shim_read() {
  P40_SR_AT=$(epoch_now)
  cl -- egress status
  grep_lines 'Gateway|Shim'
  P40_SR_L=0
  if LC_ALL=C grep -q '● Shim listening' "$OUT" 2>/dev/null; then P40_SR_L=1; fi   # bin/cleat:14698
  return 0
}
# p40_quit_end PROJ KEY: after a quit (or a killed VM), T1's session ended by itself. What T1
# printed is recorded as KEY (typed and auto mode), or the human says (human mode). An egress
# session-end report is not expected (the daemon was down when it would have read the gateway).
# F5: no "Out of memory" there. It is read from the session-end region (from the last "Session
# ended" or "Claude exited with code N", t_region end), or from the whole capture when T1 printed
# neither line. The whole phrase is matched, which a night task's own output would not print. A
# capture that holds no text is no reading: the human is asked, so F5 never passes on nothing.
p40_quit_end() {
  local proj="$1" key="$2" cap=""
  say "T1's session ends by itself now that the engine is gone. If Claude Code still shows in T1 after a few seconds, type /exit there."
  [ "${DRY:-0}" = 1 ] || sleep 5
  t_wait_exit t1 "$proj" 300
  if t_have_capture && t_capture t1 "$key" && { [ "${DRY:-0}" = 1 ] || LC_ALL=C grep -q '[^[:space:]]' "$OUT" 2>/dev/null; }; then
    cap="$OUT"
    record_value "$key" "$(p40_tail_text "$OUT" 8)" "what T1 printed when its session ended (the last lines)"
    if [ "${DRY:-0}" != 1 ] && LC_ALL=C grep -q -E -e 'denied by egress policy this session|refused this session|were refused (because|by the gateway)|was refused (because|by the gateway)|Shim not listening' "$OUT"; then
      check_note "T1 printed an egress report at the session end, which the scenario does not expect with the daemon down: $(LC_ALL=C grep -E -m 1 -e 'denied by egress policy|refused|Shim not listening' "$OUT")"   # bin/cleat:20667, 20682 to 20688, 11464
    fi
    t_region end
    if [ "${DRY:-0}" != 1 ] && [ ! -s "$OUT" ]; then
      check_note "T1 printed no Session ended or Claude exited line: F5 reads the whole capture"
      OUT="$cap"
    fi
    expect_not_contains "T1's session end does not say Out of memory: the box stopped, it met no memory ceiling (F5)" "Out of memory. The box hit its memory ceiling"   # bin/cleat:20371, from _maybe_explain_oom (20351) only for a box still running
  else
    if t_have_capture; then check_note "T1's text could not be read back (none came): its session end is asked"; fi
    p40_ask_record "$key" T1 "Read what T1 printed when its session ended (after the last Claude Code screen)." "Did it end with a short error or an exit code and no egress report (no denied hosts, no Shim not listening)?"
    p40_ask "$key-oom" T1 "Read the same lines once more." "No line reads Out of memory. The box hit its memory ceiling: the box was stopped, it met no memory ceiling" "Did T1's session end without an Out of memory line? n is a FAIL, the old behaviour (F5)"
  fi
  return 0
}

# ---- sleep assertions ----
# p40_policy_vals KEY: the values of "KEY = VALUE" lines in the [egress] section of the test config.
p40_policy_vals() {
  [ -f "$CFG/config" ] || return 0
  awk -v k="$1" '/^\[/ { s = ($0 == "[egress]"); next } s && $1 == k && $2 == "=" { print $3 }' "$CFG/config" 2>/dev/null
}
# p40_keepawake KEY: both system-wide sleep counts at 0 and no holder, read up to three times
# (the human turns keep-awake off in between). Recorded as KEY.
p40_keepawake() {
  local key="$1" n=0 r=0
  while :; do
    n=$((n + 1))
    if host_can || [ "${DRY:-0}" = 1 ]; then
      pm_assertions
    else
      # pm_assertions would ask with ask, whose n is a FAIL before the human could act on it.
      say_do Mac "In a terminal on the Mac run:
  pmset -g assertions | grep -E '^ +(PreventUserIdleSystemSleep|PreventSystemSleep) '
  pmset -g assertions | grep -E 'pid [0-9]+\(' | grep -E 'PreventUserIdleSystemSleep|PreventSystemSleep'"
      choose pm-read "Do both counts read 0, with no line from the second command?" "y=both 0 and no line" "n=a count is not 0, or a process holds sleep"
      PM_IDLE="?"; PM_SYS="?"; PM_HOLDERS=""
      if [ "$CHOICE" = y ]; then
        PM_IDLE=0; PM_SYS=0
      else
        read_line pm-holders "Which processes hold it (names only, from the second command)?" PM_HOLDERS
        [ -n "$PM_HOLDERS" ] || PM_HOLDERS="unnamed"
      fi
    fi
    if [ "${PM_IDLE:-?}" = 0 ] && [ "${PM_SYS:-?}" = 0 ] && [ -z "${PM_HOLDERS:-}" ]; then
      check_pass "keep-awake is off: both counts read 0 and nothing holds sleep"
      record_value "$key" "PreventUserIdleSystemSleep 0 PreventSystemSleep 0, no holder" "sleep assertions"
      return 0
    fi
    if [ "$n" -ge 3 ]; then
      record_value "$key" "PreventUserIdleSystemSleep ${PM_IDLE:-?} PreventSystemSleep ${PM_SYS:-?}, held by ${PM_HOLDERS:-unknown}" "sleep assertions"
      check_fail "keep-awake is off: both counts read 0 and nothing holds sleep" "both 0, no holder" "PreventUserIdleSystemSleep ${PM_IDLE:-?}, PreventSystemSleep ${PM_SYS:-?}, held by ${PM_HOLDERS:-unknown}"
      return 1
    fi
    p40_ask keepawake Mac "Something holds the Mac awake: PreventUserIdleSystemSleep ${PM_IDLE:-?}, PreventSystemSleep ${PM_SYS:-?}, held by ${PM_HOLDERS:-unknown}.
Turn off keep-awake utilities (Amphetamine, caffeinate) and anything else that holds sleep.
Answer y and the script reads the counts again." "both counts at 0 and no holder" "Is keep-awake off now?"
    r=$?
    case "$r" in
      0) ;;
      *) check_fail "keep-awake is off: both counts read 0 and nothing holds sleep" "both 0, no holder" "still held (${PM_HOLDERS:-unknown}) and not turned off"
         return 1 ;;
    esac
  done
}

# ---- the probe loop (egprobe) and its log ----
# p40_probe_count PROJ: how many processes in the box carry the probe loop's command line.
p40_probe_count() {
  bxr "$1" bash -c 'n=0; for p in /proc/[0-9]*; do [ "${p#/proc/}" = "$$" ] && continue; c=$(tr "\0" " " < "$p/cmdline" 2>/dev/null); case "$c" in *egress-probe.log*) n=$((n + 1)) ;; esac; done; echo "$n"'
}
p40_probe_has_line() { bx "$1" test -s /tmp/egress-probe.log; }
p40_probe_tail() { bx "$1" tail -n "$2" /tmp/egress-probe.log; }
p40_probe_all() { bx "$1" cat /tmp/egress-probe.log; }
# p40_probe_start PROJ: egprobe, once (a second loop would log every minute twice), then the
# first line of the log within 90 s.
p40_probe_start() {
  local n=""
  val n -t 60 -- p40_probe_count "$1"
  if p40_is_int "$n" && [ "$n" -gt 0 ]; then
    check_note "a probe loop already runs in $1 ($n processes): not started again"
  else
    run_cmd -t 60 -- egprobe "$1"
    expect_rc "egprobe $1 started the probe loop" 0
  fi
  if wait_for probe-line "" --auto --timeout 90 --every 5 -- p40_probe_has_line "$1"; then
    check_pass "the probe log /tmp/egress-probe.log has its first line"
  else
    check_fail "the probe log /tmp/egress-probe.log has its first line" "a line within 90 s" "none"
  fi
}
# p40_awk_epoch: the awk function p40_ep(STAMP) -> epoch seconds for YYYY-MM-DD[T ]HH:MM:SS with an
# optional fraction and Z or a +-HHMM offset (the box's date, Docker and pmset). "" when unreadable.
p40_awk_epoch() {
  cat <<'P40_AWK_EOF'
function p40_dfc(y, m, d,   era, yoe, doy, doe) {
  y -= (m <= 2)
  if (y >= 0) era = int(y / 400); else era = -int((399 - y) / 400)
  yoe = y - era * 400
  doy = int((153 * (m + (m > 2 ? -3 : 9)) + 2) / 5) + d - 1
  doe = yoe * 365 + int(yoe / 4) - int(yoe / 100) + doy
  return era * 146097 + doe - 719468
}
function p40_ep(s,   e, rest, sign, z) {
  if (s !~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9][T ][0-9][0-9]:[0-9][0-9]:[0-9][0-9]/) return ""
  e = p40_dfc(substr(s, 1, 4) + 0, substr(s, 6, 2) + 0, substr(s, 9, 2) + 0) * 86400 + substr(s, 12, 2) * 3600 + substr(s, 15, 2) * 60 + substr(s, 18, 2)
  rest = substr(s, 20)
  sub(/^\.[0-9]+/, "", rest)
  sub(/^ +/, "", rest)
  if (rest == "" || substr(rest, 1, 1) == "Z") return e
  sign = substr(rest, 1, 1)
  if (sign != "+" && sign != "-") return e
  z = substr(rest, 2, 5)
  gsub(/:/, "", z)
  if (z !~ /^[0-9][0-9][0-9][0-9]/) return e
  z = substr(z, 1, 4)
  if (sign == "+") return e - (substr(z, 1, 2) * 3600 + substr(z, 3, 2) * 60)
  return e + (substr(z, 1, 2) * 3600 + substr(z, 3, 2) * 60)
}
P40_AWK_EOF
}
# p40_probe_eval FILE WAKEVM: the probe log after a sleep. WAKEVM is the wake in the box's clock
# (epoch), empty when unknown (the first request after the largest gap stands for it). Prints
# key=value lines: n, gap (largest gap in s), gapfrom, gapto, post (requests from the gap's end
# on), late (000 later than a minute after the wake), latelist, first (the first request after
# the gap), last (the last request).
p40_probe_eval() {
  awk -v wake="${2:-}" "$(p40_awk_epoch)"'
    NF >= 2 { e = p40_ep($1); if (e == "") next; n++; ep[n] = e; st[n] = $1; cd[n] = $2 }
    END {
      gi = 0; gap = 0
      for (i = 2; i <= n; i++) if (ep[i] - ep[i - 1] > gap) { gap = ep[i] - ep[i - 1]; gi = i }
      w = (wake != "" ? wake + 0 : (gi ? ep[gi] : (n ? ep[1] : 0)))
      late = 0; ll = ""
      for (i = 1; i <= n; i++) if (cd[i] == "000" && ep[i] > w + 60) { late++; if (late <= 10) ll = ll (ll == "" ? "" : ", ") st[i] }
      printf "n=%d\ngap=%.0f\n", n, gap
      printf "gapfrom=%s\ngapto=%s\n", (gi ? st[gi - 1] : ""), (gi ? st[gi] : "")
      printf "post=%d\n", (gi ? n - gi + 1 : 0)
      printf "late=%d\nlatelist=%s\n", late, ll
      printf "first=%s\n", (gi ? st[gi] " " cd[gi] : "")
      printf "last=%s\n", (n ? st[n] " " cd[n] : "")
    }' "$1" 2>/dev/null
}
# p40_kv_of TEXT KEY: the value of KEY= in key=value lines.
p40_kv_of() { printf '%s\n' "$1" | awk -v k="$2" 'index($0, k "=") == 1 { print substr($0, length(k) + 2); exit }'; }
# p40_health_sum FILE: the gateway's health log JSON as entries, failing ones, first and last start.
p40_health_sum() {
  awk '{ s = s $0 } END {
      n = gsub(/"ExitCode":/, "&", s); z = gsub(/"ExitCode":0[,}]/, "&", s)
      f = ""; l = ""; t = s
      while (match(t, /"Start":"[^"]*"/)) { v = substr(t, RSTART + 9, RLENGTH - 10); if (f == "") f = v; l = v; t = substr(t, RSTART + RLENGTH) }
      printf "%d probes, %d failing, first %s, last %s\n", n, n - z, (f == "" ? "none" : f), (l == "" ? "none" : l)
    }' "$1" 2>/dev/null
}

# ---- pmset: the sleep and its windows ----
p40_pm_log() { pmset -g log | grep -E 'Entering Sleep|Wake from' | tail -n "$1"; }
# p40_pm_windows FILE: every sleep window in pmset lines: "START END DARKWAKES START-STAMP|END-STAMP"
# (epochs, END "-" while it lasts). A window opens at any Entering Sleep while awake and closes at
# the first Wake from that is not a DarkWake. DarkWakes in between are maintenance wakes.
p40_pm_windows() {
  awk "$(p40_awk_epoch)"'
    { e = p40_ep(substr($0, 1, 25)); if (e == "") next
      if ($0 ~ /DarkWake from/) { if (asleep) dw++; next }
      if ($0 ~ /Entering Sleep/) { if (!asleep) { asleep = 1; st = e; ss = substr($0, 1, 25); dw = 0 } next }
      if ($0 ~ /Wake from/) { if (asleep) { printf "%.0f %.0f %d %s|%s\n", st, e, dw, ss, substr($0, 1, 25); asleep = 0 } next }
    }
    END { if (asleep) printf "%.0f - %d %s|still asleep\n", st, dw, ss }' "$1" 2>/dev/null
}
# p40_win_text FILE [SINCE]: the windows of p40_pm_windows as "START to END UTC (D DarkWakes)",
# those that began at most an hour before SINCE (epoch) or later. UTC like the probe log's
# stamps, so the two read side by side (pmset prints local time).
p40_win_text() {
  local since="${2:-0}" ws we wd rest
  p40_is_int "$since" || since=0
  [ -f "$1" ] || return 0
  while read -r ws we wd rest; do
    p40_is_int "$ws" || continue
    [ "$ws" -ge $((since - 3600)) ] || continue
    if p40_is_int "$we"; then
      printf '%s to %s UTC (%s DarkWakes)\n' "$(p40_epoch_utc "$ws" s)" "$(p40_epoch_utc "$we" s)" "$wd"
    else
      printf '%s UTC to now, still asleep (%s DarkWakes)\n' "$(p40_epoch_utc "$ws" s)" "$wd"
    fi
  done < "$1"
}
# p40_sleep_len MIN AFTER LABEL ACT: the sleep that began after AFTER (epoch) lasted MIN minutes
# or more. ACT is the lid's HOSTACT: sim and skipped make the length a SKIP. Sets P40_SLEEP
# ("START to END, M min, D DarkWakes") and P40_WAKE (the wake, host epoch, empty when unknown).
p40_sleep_len() {
  local min="$1" after="$2" label="$3" act="$4" w="" ws="" we="" wd="" mins="" txt=""
  P40_SLEEP=""; P40_WAKE=""
  if [ "${DRY:-0}" = 1 ]; then
    pm_sleep_log "$after"
    expect_num "$label lasted at least $min minutes (pmset)" "" ge "$min"
    return 0
  fi
  case "$act" in real|human) ;; *) check_skip "$label lasted at least $min minutes" "host action $act"; return 0 ;; esac
  if host_can; then
    # The library's pm_sleep_log reads the last 40 lines, as the scenario does. A long sleep with
    # many DarkWakes pushes its Entering Sleep line out of them, so 400 lines are parsed here.
    PM_SLEEP_START=""; PM_SLEEP_END=""; PM_SLEEP_MINS=""; PM_DARKWAKES=""
    run_cmd -t 300 -n "pmset sleep log" -- p40_pm_log 400
    pm_parse_sleep "$OUT" "$after"
    mins="${PM_SLEEP_MINS:-}"
    if [ -n "$mins" ]; then
      ws=$(iso_to_epoch "$PM_SLEEP_START"); we=$(iso_to_epoch "$PM_SLEEP_END")
      if p40_is_int "$ws" && p40_is_int "$we"; then
        P40_SLEEP="$(p40_epoch_utc "$ws" s) to $(p40_epoch_utc "$we" s) UTC, $mins min, ${PM_DARKWAKES:-0} DarkWakes"
      else
        P40_SLEEP="$PM_SLEEP_START to $PM_SLEEP_END, $mins min, ${PM_DARKWAKES:-0} DarkWakes"
      fi
      P40_WAKE="$we"
    else
      # No Clamshell or Software sleep after AFTER: any sleep window that began after it.
      w=$(p40_pm_windows "$OUT" | awk -v a="$after" '$1 + 0 >= a - 120 && $2 != "-" { print; exit }')
      if [ -n "$w" ]; then
        ws=$(printf '%s' "$w" | awk '{ print $1 }'); we=$(printf '%s' "$w" | awk '{ print $2 }'); wd=$(printf '%s' "$w" | awk '{ print $3 }')
        if p40_is_int "$ws" && p40_is_int "$we"; then
          mins=$(( (we - ws) / 60 ))
          P40_SLEEP="$(p40_epoch_utc "$ws" s) to $(p40_epoch_utc "$we" s) UTC, $mins min, $wd DarkWakes"
          P40_WAKE="$we"
          check_note "pmset shows no Clamshell or Software Sleep after the question, but another sleep: $P40_SLEEP"
        fi
      fi
    fi
    if [ -n "$P40_SLEEP" ]; then
      record_value "$STEP_ID.sleep" "$P40_SLEEP" "$label (pmset)"
      expect_num "$label lasted at least $min minutes (pmset)" "$mins" ge "$min"
      return 0
    fi
    check_note "pmset's log shows no finished sleep after the question: asked instead"
  fi
  say_do Mac "In a terminal on the Mac run:
  pmset -g log | grep -E 'Entering Sleep|Wake from' | tail -40
The sleep starts at the Entering Sleep line for Clamshell Sleep or Software Sleep and ends at the
first Wake from line that is not a DarkWake. DarkWake lines in between are maintenance wakes."
  p40_ask "sleep-len" Mac "Read the sleep that began when you closed the lid." "a sleep of at least $min minutes" "Did it last at least $min minutes?"
  read_line sleep-read "For the record: the Entering Sleep time, the Wake from time and the number of DarkWake lines between them" txt
  P40_SLEEP="${txt:-not read}"
  record_value "$STEP_ID.sleep" "$P40_SLEEP" "$label (read by you)"
  return 0
}
# p40_classify_000 PROBEFILE WINDOWSFILE DELTA: each 000 request of the night beside the sleep
# windows. DELTA is the box clock minus the host clock (s). Prints one line per 000 request and a
# last line "outside=N".
p40_classify_000() {
  awk -v d="${3:-0}" -v wf="$2" "$(p40_awk_epoch)"'
    BEGIN { while ((getline l < wf) > 0) { split(l, a, " "); k++; ws[k] = a[1]; we[k] = a[2] } }
    $2 == "000" {
      e = p40_ep($1); if (e == "") next
      h = e - d; where = ""
      for (i = 1; i <= k; i++) {
        if (h >= ws[i] && (we[i] == "-" || h <= we[i])) { where = "inside a sleep"; break }
        if (we[i] != "-" && h > we[i] && h <= we[i] + 60) { where = sprintf("%d s after a wake", h - we[i]); break }
      }
      if (where == "") { where = "OUTSIDE every sleep and the minute after its wake"; out++ }
      printf "  %s  000  %s\n", $1, where
    }
    END { printf "outside=%d\n", out + 0 }' "$1" 2>/dev/null
}

# ---- accounts ----
# p40_acct_names FILE: the account names of cleat account list (bin/cleat:32659: three spaces, a
# mark or a space, a space, the name). The shared row "default" is left out.
p40_acct_names() {
  LC_ALL=C awk '
    substr($0, 1, 5) == "     " && substr($0, 6, 1) != " " { if ($1 != "default") print $1; next }
    substr($0, 1, 3) == "   " && substr($0, 4, 1) != " " && NF >= 2 { if ($2 != "default") print $2 }' "$1" 2>/dev/null
}
# p40_acct_state FILE NAME: the state word of NAME's row (ok, re-login, signed out: bin/cleat:29054).
p40_acct_state() {
  LC_ALL=C awk -v n="$2" '{ for (i = 1; i < NF; i++) if ($i == n) { s = $(i + 1); if (s == "signed" && $(i + 2) == "out") s = "signed out"; print s; exit } }' "$1" 2>/dev/null
}

# ---- the night ----
# p40_night_secs: seconds since the evening's reading (kv night.start), empty when unknown.
p40_night_secs() {
  local s now
  s=$(kv_get night.start "")
  p40_is_int "$s" || return 0
  now=$(epoch_now)
  p40_is_int "$now" || return 0
  printf '%s\n' $((now - s))
}
p40_night_done() { local s; s=$(p40_night_secs); p40_is_int "$s" && [ "$s" -ge "$1" ]; }
# p40_since_done KEY SECS: SECS or more have passed since the epoch kv KEY holds.
p40_since_done() {
  local s now
  s=$(kv_get "$1" ""); now=$(epoch_now)
  p40_is_int "$s" && p40_is_int "$now" && [ $((now - s)) -ge "$2" ]
}

# ---- 3.2: Docker Desktop's VM process ----
# p40_vm_procs: "PID NAME" for each process whose executable is the VM of one of the three VM
# managers. Not the scenario's ps -axco: macOS -c prints the accounting name, cut at 16
# characters, so com.docker.virtualization reads com.docker.virtu there and its grep misses the
# Apple Virtualization framework. The full command line keeps the whole name, which is also what
# host_kill_vm checks before it kills.
p40_vm_procs() {
  ps -axo pid=,command= | awk '{ n = $2; sub(/.*\//, "", n)
    if (n ~ /^com\.docker\.(krun|virtualization)$/ || n ~ /^qemu-system/) print $1, n }'
}
# p40_vm_choices FILE: the choose options "PID=NAME", the one matching the VM manager 0.3 recorded first.
p40_vm_choices() {
  local want=""
  case "$(kv_get dd.vmm "")" in
    *[Vv][Mm][Mm]*) want=com.docker.krun ;;
    *[Vv]irtuali*) want=com.docker.virtualization ;;
    *[Qq][Ee][Mm][Uu]*) want=qemu-system ;;
  esac
  awk -v w="$want" '$1 ~ /^[0-9]+$/ && NF >= 2 { line = $1 "=" $2; if (w != "" && index($2, w) == 1) print line; else rest[++k] = line }
    END { for (i = 1; i <= k; i++) print rest[i] }' "$1" 2>/dev/null
}

# ---- docker and file pipelines (through run_cmd or val only) ----
p40_serving() { docker logs --timestamps "$1" 2>&1 | grep serving; }
p40_gw_count() { docker ps -a --filter label=sh.cleat.role=gateway -q | wc -l | tr -d ' '; }
p40_vol_count() { docker volume ls -q --filter label=sh.cleat.role=egress-sock | wc -l | tr -d ' '; }
# p40_hostfiles: the entries of the four host-file directories egobjs lists, as DIR/ENTRY.
p40_hostfiles() {
  local d e
  for d in egress-rendered egress-boxes egress-pins egress-notices; do
    [ -d "$CFG/$d" ] || continue
    for e in "$CFG/$d"/* "$CFG/$d"/.[!.]*; do
      [ -e "$e" ] || [ -L "$e" ] || continue
      printf '%s/%s\n' "$d" "${e##*/}"
    done
  done
  return 0
}
# p40_session_key PROJ: the transcript directory name cleat derives for the project's main box.
p40_session_key() {
  "$MT_BASH" -c '. "$1/bin/cleat" >/dev/null 2>&1 || exit 1; _derive_project_session_key "$(resolve_project "$2")" main' _ "$MT_WT" "$P/$1" 2>/dev/null
}
p40_realcfg_count() {
  [ -f "$HOME/.config/cleat/config" ] || { echo 0; return 0; }
  awk '/^\[egress\]/ { n++ } END { print n + 0 }' "$HOME/.config/cleat/config"
}

# ---------------------------------------------------------------------------------------------
# 3.0 Sitting 3 starts
# ---------------------------------------------------------------------------------------------
# Re-entry: reads only.
st_3_0() {
  run_cmd -t 60 -- egcheck
  expect_contains "egcheck: the tracked tree is clean" "tree: clean"
  expect_not_contains "egcheck: no test lock in the worktree" "test lock held"
  run_cmd -t 600 -- egimg
  expect_contains "egimg: the relay is this tree's" "relay: this tree's"
  expect_contains "egimg: the entrypoint is this tree's" "entrypoint: this tree's"
  if [ "${DRY:-0}" != 1 ] && { ! LC_ALL=C grep -q "relay: this tree's" "$OUT" || ! LC_ALL=C grep -q "entrypoint: this tree's" "$OUT"; }; then
    step_abort "the $MT_IMAGE image was not built from this tree. Never go on with it: ./egress-release.sh --only 0.5"
  fi
  hdr "The test policy sitting 3 runs under (2.27d leaves it strict, example.com allowed)"
  if [ "${DRY:-0}" = 1 ] || { [ "$(p40_policy_vals mode | tail -n 1)" = strict ] && p40_policy_vals allow | LC_ALL=C grep -q -x -e example.com; }; then
    check_pass "the test policy is strict and allows example.com" "$CFG/config"
  else
    check_fail "the test policy is strict and allows example.com" "mode = strict, allow = example.com in the [egress] section of $CFG/config" "mode $(p40_policy_vals mode | tail -n 1 | sed 's/^$/none/')"
    choose policy-not-ready "Sitting 3 needs the policy 2.27d leaves (strict, example.com allowed). Stop here and run ./egress-release.sh --only 2.27d first?" "q=stop here" "c=go on anyway"
    if [ "$CHOICE" = q ]; then say "Stopped. Fix the policy, then: ./egress-release.sh --resume"; exit 10; fi
  fi
  hdr "Sitting 3: the long runs"
  say "This sitting quits Docker Desktop more than once (3.1b, 3.1e, 3.4dd). Each quit ends every"
  say "session on this Mac, your daily boxes included."
  say "Keep-awake utilities (Amphetamine included) must be off for 3.3 and 3.4. No external display"
  say "may be attached when you close the lid: a lid closed on power with a display attached keeps"
  say "the Mac awake."
  say "3.3 sleeps the Mac for at least $MT_MIN_SLEEP_MINS minutes. The night (3.4) lasts at least"
  say "$MT_MIN_NIGHT_HOURS hours from the evening reading, with one lid sleep in it."
  return 0
}

# ---------------------------------------------------------------------------------------------
# 3.1a Step 14: the box and the before reading
# ---------------------------------------------------------------------------------------------
# Re-entry: a session already open in eg-restart is kept. The before reading is taken again.
st_3_1a() {
  local g="" n=""
  choose daily-save "The next step quits Docker Desktop, which ends every session on this Mac, your daily boxes included. Is your work saved in every daily box?" "y=saved, go on" "q=stop here and resume later"
  if [ "$CHOICE" = q ]; then
    say "Stopped before anything changed. Save your daily work, then: ./egress-release.sh --resume"
    exit 10
  fi
  p40_cd eg-restart make
  if p40_live eg-restart; then
    check_note "Claude Code already runs in eg-restart (an earlier attempt opened it): not launched again"
  else
    p40_launch t1 eg-restart cleat launch-3.1a 900 \
      "+Egress:     strict  ·  " "-Egress refused" "-Shim not listening"   # bin/cleat:12332, 11781, 11464
  fi
  p40_ask_record hello-3.1 T1 "In Claude Code in T1, send exactly this message:
reply with just ok" "Did Claude answer? (3.1d and 3.1e reopen this conversation with cleat resume)"
  hdr "The before reading (T2: egread eg-restart)"
  p40_egread eg-restart
  kv_set step14.before.read "$P40_RN"
  kv_set step14.before.vol.created "$(p40_rd vol.created)"
  kv_set step14.before.vol.labels "$(p40_rd vol.labels)"
  kv_set step14.before.box.started "$(p40_rd box.started)"
  kv_set step14.before.gw.started "$(p40_rd gw.started)"
  record_value step14.before "gateway running=$(p40_rd gw.running) health=$(p40_rd gw.health) started=$(p40_rd gw.started) | box running=$(p40_rd box.running) started=$(p40_rd box.started) | volume created=$(p40_rd vol.created) labels=$(p40_rd vol.labels)" "both containers and the socket volume before the quit"
  expect_eq "the box runs before the quit" "$(p40_rd box.running)" true
  expect_eq "its gateway runs before the quit" "$(p40_rd gw.running)" true
  expect_eq "its gateway is healthy before the quit" "$(p40_rd gw.health)" healthy
  val g -t 60 -- gw eg-restart
  if [ -n "$g" ]; then
    run_cmd -t 60 -- p40_serving "$g"
    n=$(awk 'END { print NR + 0 }' "$OUT" 2>/dev/null)
    kv_set step14.serving.before "$n"
    record_value step14.serving.before "$n" "the gateway's serving lines before the quit (one per start)"   # gateway.py:1159
  else
    check_fail "the gateway of eg-restart exists" "a gateway" "gw printed nothing"
  fi
  return 0
}

# ---------------------------------------------------------------------------------------------
# 3.1b Step 14: Docker Desktop quit
# ---------------------------------------------------------------------------------------------
# Re-entry: Docker already down means the quit of an earlier attempt stands. Up: the session is
# reopened when it is gone, then Docker Desktop quits again.
st_3_1b() {
  local how=""
  p40_cd eg-restart
  if p40_dk_up 0; then
    p40_need_live eg-restart resume-3.1b
    kv_set step14.quit_at "$(utc_stamp)"
    record_value step14.quit_at "$(kv_get step14.quit_at "")" "the quit time, UTC"
    dd_quit eg-restart
    how="${HOSTACT:-}"
    kv_set step14.quit.how "$how"
    if [ "$how" = skipped ]; then step_abort "Docker Desktop was not quit. Run 3.1b again when it can be: ./egress-release.sh --resume"; fi
    p40_quit_end eg-restart step14.t1-end
    say "Docker Desktop stays quit until 3.1c reopens it. Leave it quit, even if you stop the script"
    say "here: ./egress-release.sh --resume goes on with Docker Desktop quit."
  else
    how=$(kv_get step14.quit.how human)
    check_note "Docker does not answer: the quit of an earlier attempt stands (quit at $(kv_get step14.quit_at unknown))"
    [ -n "$(kv_get step14.quit_at "")" ] || kv_set step14.quit_at "$(utc_stamp)"
    kv_has step14.t1-end || p40_quit_end eg-restart step14.t1-end
  fi
  if [ "$how" = sim ]; then
    check_skip "docker info fails after the quit" "host action sim: the box and its gateway were stopped instead"
  elif p40_dk_up 1; then
    check_fail "docker info fails after the quit" "Docker Desktop down" "docker info still answers"
  else
    check_pass "docker info fails after the quit"
  fi
  return 0
}

# ---------------------------------------------------------------------------------------------
# 3.1-down Step 14: while Docker is down (EXTRA)
# ---------------------------------------------------------------------------------------------
# Re-entry: runs again as long as Docker Desktop is quit.
st_3_1_down() {
  p40_cd eg-restart
  if p40_dk_up 1; then
    step_skip "Docker answers: this step runs only while Docker Desktop is quit, between 3.1b and 3.1c"
  fi
  dd_wait_down 30 || step_skip "Docker did not read as down (${HOSTACT:-no host action})"
  clt -T 300 --env CLEAT_NO_AUTOSTART=1 --
  expect_rc "CLEAT_NO_AUTOSTART=1 cleat exits non-zero" '!0'
  expect_contains "it says Docker is not running" "✖ Docker isn't running."   # bin/cleat:1987
  expect_not_contains "never Egress refused" "Egress refused"
  cl -- egress status
  first_lines 2
  expect_contains "egress status: Docker is not running" "○ Docker is not running, so the gateway cannot be asked."   # bin/cleat:14471
  return 0
}

# ---------------------------------------------------------------------------------------------
# 3.1c Step 14: reopen, read before any cleat command (W4)
# ---------------------------------------------------------------------------------------------
# Re-entry: a Docker that already answers is the reopen of an earlier attempt, read now. A box
# that runs again means a cleat command ran since: the readings before it are gone (abort).
st_3_1c() {
  local how="" g="" vol="" c="" n="" nb="" kase="" s="" quit="" fin="" d="" a="" b="" bc="" bl="" vc="" vl=""
  p40_cd eg-restart
  if [ "${DRY:-0}" != 1 ] && [ -z "$(kv_get step14.quit_at "")" ]; then step_abort "no quit was recorded: run 3.1b first"; fi
  how=$(kv_get step14.quit.how "")
  if p40_dk_up 1; then
    if p40_running eg-restart 1; then
      step_abort "the eg-restart box runs again, so the readings before any cleat command are gone. Quit Docker Desktop again: ./egress-release.sh --only 3.1b,3.1c, then --resume"
    fi
    if [ "$how" = sim ]; then
      dd_open
      kv_set step14.reopen_at "$(utc_stamp)"
    else
      check_note "Docker already answers: it was reopened before this attempt. The readings are taken now, still before any cleat command"
    fi
  else
    dd_open
    [ "${HOSTACT:-}" = skipped ] && step_abort "Docker Desktop was not reopened. Run 3.1c again once it is: ./egress-release.sh --resume"
    kv_set step14.reopen_at "$(utc_stamp)"
  fi
  # A reopen time from an earlier quit and reopen (3.1b run again, Docker Desktop opened by hand)
  # is not this reopen's: the time is taken now.
  case "$(iso_cmp "$(kv_get step14.quit_at "")" "$(kv_get step14.reopen_at "")")" in
    lt|eq) ;;
    *) [ "${DRY:-0}" = 1 ] || check_note "no reopen time after the last quit was recorded (Docker Desktop was opened outside this step): the time is taken now"
       kv_set step14.reopen_at "$(utc_stamp)" ;;
  esac
  record_value step14.reopen_at "$(kv_get step14.reopen_at "")" "the reopen time, UTC"

  hdr "Both containers before any cleat command (W4)"
  p40_egread eg-restart
  kv_set step14.reopen.read "$P40_RN"
  for s in gw.running gw.exit gw.restarts gw.started gw.finished box.running box.exit box.started box.finished; do
    kv_set "step14.reopen.$s" "$(p40_rd "$s")"
  done
  record_value step14.reopen "gateway running=$(p40_rd gw.running) exit=$(p40_rd gw.exit) restarts=$(p40_rd gw.restarts) started=$(p40_rd gw.started) finished=$(p40_rd gw.finished) | box running=$(p40_rd box.running) exit=$(p40_rd box.exit) started=$(p40_rd box.started) finished=$(p40_rd box.finished)" "both containers as read before any cleat command"
  val g -t 60 -- gw eg-restart
  val vol -t 60 -- vol eg-restart
  val c -t 60 -- cn eg-restart
  if [ -n "$g" ]; then
    run_cmd -t 60 -- p40_serving "$g"
    n=$(awk 'END { print NR + 0 }' "$OUT" 2>/dev/null)
    nb=$(kv_get step14.serving.before "")
    record_value step14.serving "$n lines (before the quit: ${nb:-not read}): $(awk '{ print $1 }' "$OUT" 2>/dev/null | p40_join)" "the gateway's serving lines, one per start"   # gateway.py:1159
  else
    check_fail "the gateway of eg-restart still exists after the reopen" "a gateway" "gw printed nothing"
  fi
  if [ -n "$vol" ]; then
    dk -t 120 -- run --rm -v "$vol:/v:ro" alpine ls -la /v
    if [ "$(p40_rd gw.running)" = true ]; then
      record_value step14.sock "not observable, gateway restarted by the daemon" "proxy.sock after the reopen"
    else
      s="proxy.sock $(awk '$NF == "proxy.sock" { f = 1 } END { print (f ? "present" : "absent") }' "$OUT" 2>/dev/null), denials.log $(awk '$NF == "denials.log" { f = 1 } END { print (f ? "present" : "absent") }' "$OUT" 2>/dev/null)"
      record_value step14.sock "$s" "the socket volume's files after the reopen (the ls the scenario runs)"
    fi
  else
    check_fail "the socket volume of eg-restart still exists after the reopen" "a volume" "vol printed nothing"
  fi

  hdr "Which case: clean, or W4 (the VM went before the containers stopped)"
  kase=$(p40_case)
  [ "${DRY:-0}" = 1 ] && kase=clean
  kv_set step14.case "$kase"
  record_value step14.case "$kase" "the case this quit left (clean or w4)"
  quit=$(kv_get step14.quit_at "")
  case "$kase" in
    clean)
      fin=$(p40_rd gw.finished)
      d=""
      if [ -n "$fin" ] && [ -n "$quit" ]; then
        a=$(iso_to_epoch "$fin"); b=$(iso_to_epoch "$quit")
        if p40_is_int "$a" && p40_is_int "$b"; then d=$((a - b)); fi
      fi
      record_value step14.clean "gateway exit=$(p40_rd gw.exit), finished ${d:-?} s after the quit time | box exit=$(p40_rd box.exit)" "the clean case"
      [ "$(p40_rd gw.exit)" = 0 ] || [ "${DRY:-0}" = 1 ] || check_note "the gateway stopped with exit $(p40_rd gw.exit), not 0 (its SIGTERM handler, 81 ms on 2026-09-26)" ;;
    w4)
      # Started again by the daemon: a StartedAt after the quit. The reopen time is taken once
      # docker info answers (or after your answer), which can be later than that start.
      s=""
      if [ "$(p40_rd gw.running)" = true ]; then
        s=$(iso_cmp "$quit" "$(p40_rd gw.started)")
      fi
      record_value step14.w4 "box exit=255 | gateway running=$(p40_rd gw.running) exit=$(p40_rd gw.exit) started=$(p40_rd gw.started) ($( [ "$s" = lt ] && printf 'started again after the quit' || printf 'not started again')) | serving lines ${n:-?}, before ${nb:-?}" "the W4 case" ;;
    *)
      check_note "neither the clean case nor W4: box running=$(p40_rd box.running) exit=$(p40_rd box.exit), gateway running=$(p40_rd gw.running) exit=$(p40_rd gw.exit). Recorded as it is" ;;
  esac

  hdr "What status says (T2: cleat egress status | head -6)"
  p40_state_check eg-restart
  cl -- status
  grep_lines_after 'Egress:' 1
  record_value step14.status-row "$(p40_join "$OUT")" "the Egress row of cleat status and the line under it"
  cl -- ps
  expect_not_match "cleat ps lists no gateway as a box" '^ +[^ ]+ +cleat-gw-'   # bin/cleat:23456 (a gateway is not a box)
  if [ -n "$c" ]; then
    s="$OUT"
    grep_lines_after "$c" 1 "$s"
    record_value step14.ps "$(p40_join "$OUT")" "eg-restart's row in cleat ps"
    if [ "$kase" = w4 ]; then
      expect_contains "cleat ps annotates the 255 exit" "Docker restarted; resume with: cleat resume" "$s"   # bin/cleat:23439
    fi
  fi

  hdr "The socket volume (W6): created and labels unchanged"
  bc=$(kv_get step14.before.vol.created ""); bl=$(kv_get step14.before.vol.labels "")
  vc=$(p40_rd vol.created); vl=$(p40_rd vol.labels)
  if [ -z "$bc" ] && [ "${DRY:-0}" != 1 ]; then
    check_fail "the volume's created and labels from 3.1a" "a before reading" "none: run 3.1a first"
  else
    expect_eq "the socket volume's CreatedAt is unchanged (W6)" "$vc" "$bc"
    expect_eq "the socket volume's labels are unchanged (W6)" "$vl" "$bl"
  fi
  rec_row 14 "Quit with a session open, read before any cleat command: case $kase (box exit $(p40_rd box.exit), gateway running=$(p40_rd gw.running) exit=$(p40_rd gw.exit) restarts=$(p40_rd gw.restarts)), serving lines ${n:-?} (before ${nb:-?}), $(kv_get step14.sock "proxy.sock not read"), volume CreatedAt and labels $( [ "$vc" = "$bc" ] && [ "$vl" = "$bl" ] && printf unchanged || printf CHANGED), status named the state ($(p40_nfail) failed checks in 3.1c)."
  return 0
}

# ---------------------------------------------------------------------------------------------
# 3.1d Step 14: resume
# ---------------------------------------------------------------------------------------------
# Re-entry: a session already open again (an earlier attempt resumed it) is kept: its launch
# lines are not read again, the rest runs.
st_3_1d() {
  local kept="" kase="" r="" s=""
  p40_cd eg-restart
  kase=$(kv_get step14.case "")
  if p40_live eg-restart; then
    check_note "Claude Code already runs in eg-restart: an earlier attempt resumed it. Its launch lines are not read again"
  else
    p40_launch t1 eg-restart "cleat resume" resume-3.1d 600 \
      "+Session resumed" "-Shim not listening" "-Egress refused"   # bin/cleat:22989, 11464 and 14707, 11781 (12040: its gateway is not healthy)
  fi
  [ "$kase" = w4 ] && [ "$(kv_get step14.reopen.gw.running "")" = true ] && kept=$(kv_get step14.reopen.gw.started "")
  p40_order eg-restart "$kept"
  if [ "$kase" = clean ] && [ "${DRY:-0}" != 1 ] && [ -n "$P40_GS" ]; then
    r=$(iso_cmp "$(kv_get step14.reopen_at "")" "$P40_GS")
    if [ "$r" = lt ]; then check_pass "the resume started the gateway again after the reopen" "$P40_GS"
    else check_fail "the resume started the gateway again after the reopen" "a StartedAt after $(kv_get step14.reopen_at "")" "$P40_GS"; fi
  fi
  p40_egread eg-restart
  record_value step14.resume "relay started=$(p40_rd relay.started) exited=$(p40_rd relay.exited) again=$(p40_rd relay.again) | path_ok $(p40_rd path_ok) | last_shim_seen $(p40_rd last_shim_seen)" "the relay after the resume"
  expect_eq "path_ok true after the resume" "$(p40_rd path_ok)" true
  p40_reach eg-restart
  s="gateway first"
  [ -n "$kept" ] && s="the gateway the daemon started kept"
  rec_row 14 "Resume after the reopen: $s, $( [ "$(p40_nfail)" = 0 ] && printf 'no relay advisory, 200 and the 403 body' || printf '%s failed checks (see 3.1d)' "$(p40_nfail)")."
  return 0
}

# ---------------------------------------------------------------------------------------------
# 3.1e Step 14: a second quit, cleat starts Docker Desktop
# ---------------------------------------------------------------------------------------------
# Re-entry: Docker already down means the second quit of an earlier attempt stands, the resume
# runs. Up with the box resumed already: the quit runs again.
st_3_1e() {
  local how=""
  p40_cd eg-restart
  if p40_dk_up 0; then
    p40_need_live eg-restart resume-3.1e-pre
    kv_set step14.quit2_at "$(utc_stamp)"
    record_value step14.quit2_at "$(kv_get step14.quit2_at "")" "the second quit time, UTC"
    dd_quit eg-restart
    how="${HOSTACT:-}"
    kv_set step14.quit2.how "$how"
    if [ "$how" = skipped ]; then step_abort "Docker Desktop was not quit. Run 3.1e again when it can be: ./egress-release.sh --resume"; fi
    p40_quit_end eg-restart step14.t1-end2
  else
    how=$(kv_get step14.quit2.how human)
    check_note "Docker does not answer: the second quit of an earlier attempt stands"
  fi
  hdr "Do not open Docker Desktop yourself: cleat resume starts it"
  if [ "$how" = sim ]; then
    check_skip "cleat resume printed the autostart lines" "host action sim: Docker never went down"
    p40_launch t1 eg-restart "cleat resume" autostart-3.1e 900 \
      "-Shim not listening" "-Egress refused"                                    # bin/cleat:11464 and 14707, 11781
  else
    p40_launch t1 eg-restart "cleat resume" autostart-3.1e 900 \
      "+! Docker isn't running. Starting Docker Desktop..." "+✔ Docker ready" "-Shim not listening" "-Egress refused"   # bin/cleat:1996 (label 1635), 2036, 11464, 11781
    if t_have_capture && [ -f "$OUT" ]; then
      record_value step14.autostart "$(LC_ALL=C grep -E -e 'Docker isn.t running|Docker ready' "$OUT" 2>/dev/null | p40_join)" "the autostart lines T1 printed"
    fi
  fi
  p40_order eg-restart
  p40_egread eg-restart
  record_value step14.quit2.after "gateway health=$(p40_rd gw.health) exit=$(p40_rd gw.exit) restarts=$(p40_rd gw.restarts) | box exit=$(p40_rd box.exit) | relay started=$(p40_rd relay.started) exited=$(p40_rd relay.exited) again=$(p40_rd relay.again) | path_ok $(p40_rd path_ok)" "both containers and the relay after the autostarted resume"
  p40_reach eg-restart
  rec_row 14 "Second quit, cleat resume started Docker Desktop$( [ "$how" = sim ] && printf ' (simulated)'): $( [ "$(p40_nfail)" = 0 ] && printf 'autostart lines, gateway first, no relay advisory, 200 and the 403 body' || printf '%s failed checks (see 3.1e)' "$(p40_nfail)")."
  return 0
}

# ---------------------------------------------------------------------------------------------
# 3.2 Step 14: the unclean half (EXTRA, destructive)
# ---------------------------------------------------------------------------------------------
# Re-entry: runs again from the start (it kills the VM again).
st_3_2() {
  local pid="" name="" o="" kase="" kept=""
  local opts=()
  if ! host_can && [ "${DRY:-0}" != 1 ]; then
    step_skip "3.2 kills Docker Desktop's VM process: it needs host control on the Mac"
  fi
  p40_cd eg-restart
  p40_need_live eg-restart resume-3.2-pre
  run_cmd -t 30 -- p40_vm_procs
  record_value step14.unclean.procs "$(awk 'NF { print $1 " " $2 }' "$OUT" 2>/dev/null | p40_join)" "the VM processes ps lists"
  while IFS= read -r o; do
    [ -n "$o" ] && opts[${#opts[@]}]="$o"
  done <<P40_EOF
$(p40_vm_choices "$OUT")
P40_EOF
  [ "${DRY:-0}" = 1 ] && opts[${#opts[@]}]="0=com.docker.krun"
  [ "${#opts[@]}" -gt 0 ] || step_abort "ps lists no com.docker.krun, com.docker.virtualization or qemu-system process"
  choose vm-pid "Which process runs the VM? The first one matches the VM manager 0.3 recorded ($(kv_get dd.vmm unknown))." ${opts[@]+"${opts[@]}"} "s=skip this step (nothing is killed)"
  [ "$CHOICE" = s ] && step_skip "you chose not to kill the VM"
  pid="$CHOICE"
  name=""
  for o in ${opts[@]+"${opts[@]}"}; do [ "${o%%=*}" = "$pid" ] && name="${o#*=}"; done
  choose kill-vm "Kill PID $pid ($name)? It kills every box on this Mac, your daily boxes included." "n=do not kill it (the step is skipped)" "y=kill it"
  [ "${DRY:-0}" = 1 ] && CHOICE=y
  [ "$CHOICE" = y ] || step_skip "the VM was not killed"
  kv_set step14.unclean.at "$(utc_stamp)"
  record_value step14.unclean.killed "$name" "the process killed"
  if [ "${DRY:-0}" = 1 ]; then say "  [dry] kill -9 $pid"; else host_kill_vm "$pid"; fi
  say "Docker Desktop usually starts its engine again by itself. If it shows an error about its VM"
  say "instead, use the Restart it offers (or Restart in the whale menu). Do not run any cleat command."
  dd_wait_down 180 || check_note "Docker kept answering after the kill"
  if ! dd_wait_up 120; then dd_open || step_abort "Docker Desktop did not come back"; fi
  hdr "Before any cleat command: egread, then cleat egress status"
  p40_egread eg-restart
  record_value step14.unclean "gateway running=$(p40_rd gw.running) exit=$(p40_rd gw.exit) restarts=$(p40_rd gw.restarts) started=$(p40_rd gw.started) | box running=$(p40_rd box.running) exit=$(p40_rd box.exit)" "both containers after the VM was killed"
  kase=$(p40_case)
  [ "$kase" = w4 ] || [ "${DRY:-0}" = 1 ] || check_note "the inferred unclean case reads box exit 255: this box reads exit $(p40_rd box.exit)"
  # The resume must keep a gateway the daemon started again (W5): its StartedAt may not move.
  kept=""
  [ "$(p40_rd gw.running)" = true ] && kept=$(p40_rd gw.started)
  p40_state_check eg-restart
  p40_quit_end eg-restart step14.unclean.t1-end
  p40_launch t1 eg-restart "cleat resume" resume-3.2 600 "-Shim not listening" "-Egress refused"   # bin/cleat:11464 and 14707, 11781
  p40_order eg-restart "$kept"
  rec_row 14 "Unclean half (the VM process killed): box exit $(p40_rd box.exit), gateway running=$(p40_rd gw.running) restarts=$(p40_rd gw.restarts), $( [ "$(p40_nfail)" = 0 ] && printf 'status named the state, the resume kept the gateway and printed no relay advisory' || printf '%s failed checks (see 3.2)' "$(p40_nfail)")."
  return 0
}

# ---------------------------------------------------------------------------------------------
# 3.3a Step 11: before the sleep
# ---------------------------------------------------------------------------------------------
# Re-entry: a probe loop already running is kept. The before reading is taken again.
st_3_3a() {
  local g=""
  p40_cd eg-restart
  p40_need_live eg-restart resume-3.3a
  p40_keepawake step11.keepawake
  p40_probe_start eg-restart
  p40_egread eg-restart
  kv_set step11.before "$P40_RN"
  record_value step11.before.read "gateway health=$(p40_rd gw.health) restarts=$(p40_rd gw.restarts) | path_ok $(p40_rd path_ok) | last_shim_seen $(p40_rd last_shim_seen) | host clock $(p40_rd host_clock), VM clock $(p40_rd vm_clock)" "before the sleep"
  val g -t 60 -- gw eg-restart
  kv_set step11.gw "$g"
  return 0
}

# ---------------------------------------------------------------------------------------------
# 3.3b Step 11: the sleep and the reads after it
# ---------------------------------------------------------------------------------------------
# Re-entry: the sleep is asked for again (a reading after a wake the script did not see is no
# reading of this sleep).
st_3_3b() {
  local min="${MT_MIN_SLEEP_MINS:-60}" g="" act="" asked="" back="" hj="" delta="" a="" b="" wake="" wakevm="" ev="" k=0 now="" st1="" lat="" first="" reads="" r="" e="" sec="" firstl="" latenot="" rd=""
  p40_is_int "$min" || min=60
  p40_cd eg-restart
  p40_up eg-restart || step_abort "the eg-restart box is not running: run 3.3a first"
  val g -t 60 -- gw eg-restart
  [ -n "$g" ] || step_abort "eg-restart has no gateway: run 3.3a first"
  if p40_is_int "$(kv_get step11.before "")" || [ "${DRY:-0}" = 1 ]; then :; else check_note "3.3a recorded no before reading"; fi
  say "The sleep: close the lid with no external display attached, or use Apple menu, Sleep."
  say "Answer the question below only after the Mac has slept at least $min minutes and woke again."
  lid_sleep "$min"
  act="${HOSTACT:-}"
  asked=$(kv_get "$STEP_ID.asked_at" ""); back=$(kv_get "$STEP_ID.back_at" "")

  hdr "At once: the gateway's health log (the last five probes roll over in about 75 s)"
  dk -t 60 -- inspect -f '{{json .State.Health.Log}}' "$g"
  hj="$OUT"
  record_value step11.health "$(p40_health_sum "$hj")" "the health probes right after the wake"
  kv_set step11.health.json "$(head -c 3000 "$hj" 2>/dev/null)"
  # The relay row read at once as well, before pmset's log (slow to parse): the pass is "listening
  # within a minute of wake", so every read keeps its time (P40_SR_AT) and the seconds from the
  # wake are worked out once pmset has given the wake.
  hdr "At once: the relay row"
  p40_shim_read
  reads="$P40_SR_AT:$P40_SR_L"

  hdr "The sleep (pmset)"
  p40_sleep_len "$min" "${asked:-0}" "the sleep" "$act"
  wake="${P40_WAKE:-}"
  if [ -z "$wake" ]; then
    wake="$back"
    check_note "the wake is taken as the moment you answered (no pmset reading): checks against it are lenient"
  fi

  hdr "egread, then status twice a minute apart"
  p40_egread eg-restart
  a=$(iso_to_epoch "$(p40_rd vm_clock)"); b=$(iso_to_epoch "$(p40_rd host_clock)")
  if p40_is_int "$a" && p40_is_int "$b"; then delta=$((a - b)); fi
  record_value step11.clock "VM $(p40_rd vm_clock) UTC against host $(p40_rd host_clock) UTC (${delta:-?} s)" "the VM clock against the host clock after the wake"
  p40_shim_read
  reads="$reads $P40_SR_AT:$P40_SR_L"
  st1=$(p40_join "$OUT")
  record_value step11.status1 "$st1" "status right after the wake"
  [ "${DRY:-0}" = 1 ] || sleep 60
  p40_shim_read
  reads="$reads $P40_SR_AT:$P40_SR_L"
  if [ "${DRY:-0}" != 1 ] && [ "$P40_SR_L" != 1 ] && p40_is_int "$wake"; then
    now=$(epoch_now)
    if p40_is_int "$now" && [ $((now - wake)) -lt 125 ]; then
      a=$((125 - (now - wake)))
      [ "$a" -le 125 ] || a=125
      check_note "not listening yet $((now - wake)) s after the wake: read again two minutes after it"
      sleep "$a"
      p40_shim_read
      reads="$reads $P40_SR_AT:$P40_SR_L"
    fi
  fi
  record_value step11.status2 "$(p40_join "$OUT")" "status a minute later"
  expect_contains "the gateway is healthy after the wake" "● Gateway healthy"   # bin/cleat:14647
  expect_contains "the relay reads listening after the wake" "● Shim listening"   # bin/cleat:14698
  # Within a minute of the wake (the scenario's pass): shown by a listening read at 60 s or less,
  # disproven by a read at 60 s or more that was not listening. A first read that came later than a
  # minute and already listened shows neither: a NOTE says so. Not listening two minutes after the
  # wake is the FAIL of the check above.
  if p40_is_int "$wake"; then
    for r in $reads; do
      e="${r%%:*}"
      p40_is_int "$e" || continue
      sec=$((e - wake))
      [ "$sec" -ge 0 ] || sec=0
      rd="$rd${rd:+, }${sec} s $( [ "${r#*:}" = 1 ] && printf listening || printf 'not listening')"
      if [ "${r#*:}" = 1 ]; then [ -n "$firstl" ] || firstl="$sec"
      elif [ "$sec" -ge 60 ]; then latenot="$sec"; fi
    done
  fi
  record_value step11.relay_secs "${firstl:-never} (reads after the wake: ${rd:-no wake time})" "seconds from the wake to the first read of Shim listening"
  if [ "${DRY:-0}" = 1 ]; then
    expect_num "the relay reads listening within a minute of the wake (s)" "" le 60
  elif [ -z "$wake" ]; then
    check_note "no wake time: whether the relay listened within a minute of it cannot be read"
  elif [ -n "${P40_WAKE:-}" ] && [ -n "$firstl" ] && [ "$firstl" -le 60 ]; then
    check_pass "the relay reads listening within a minute of the wake" "$firstl s"
  elif [ -n "$latenot" ]; then
    # also against the moment you answered: it is never earlier than the wake
    check_fail "the relay reads listening within a minute of the wake" "Shim listening by 60 s" "not listening $latenot s after the wake (reads: $rd)"
  elif [ -z "${P40_WAKE:-}" ]; then
    # the moment you answered is later than the wake: seconds from it would flatter the relay
    check_note "no pmset wake time: the relay first read listening ${firstl:-never} s after your answer, which is later than the wake. Within a minute of the wake cannot be read"
  elif [ -n "$firstl" ]; then
    check_note "the first read came $firstl s after the wake and already listened: within a minute is neither shown nor disproven"
  fi
  if [ -z "$firstl" ]; then lat="never in two minutes"
  elif [ -n "${P40_WAKE:-}" ]; then lat="$firstl s after the wake"
  else lat="$firstl s after the answer (no pmset wake)"; fi

  hdr "The probe log across the sleep (T2: bx eg-restart tail -n 90 /tmp/egress-probe.log)"
  if p40_is_int "$wake" && p40_is_int "$delta"; then wakevm=$((wake + delta)); elif p40_is_int "$wake"; then wakevm="$wake"; fi
  k=0
  while :; do
    run_cmd -t 60 -- p40_probe_tail eg-restart 90
    ev=$(p40_probe_eval "$OUT" "$wakevm")
    [ "${DRY:-0}" = 1 ] && break
    a=$(p40_kv_of "$ev" post)
    if p40_is_int "$a" && [ "$a" -ge 2 ]; then break; fi
    now=$(epoch_now)
    if ! p40_is_int "$wake" || ! p40_is_int "$now" || [ $((now - wake)) -ge 180 ] || [ "$k" -ge 20 ]; then break; fi
    k=$((k + 1))
    sleep 10
  done
  record_value step11.probe "largest gap $(p40_kv_of "$ev" gap) s ($(p40_kv_of "$ev" gapfrom) to $(p40_kv_of "$ev" gapto)), $(p40_kv_of "$ev" post) requests from its end on, first after it $(p40_kv_of "$ev" first), last $(p40_kv_of "$ev" last)" "the probe log across the sleep"
  first=$(p40_kv_of "$ev" first)
  if [ "${DRY:-0}" = 1 ]; then
    expect_num "requests after the sleep" "" ge 1
  else
    expect_num "the probe logged requests again after the sleep" "$(p40_kv_of "$ev" post)" ge 1
    a=$(p40_kv_of "$ev" late)
    if p40_is_int "$a" && [ "$a" = 0 ]; then
      check_pass "no 000 later than a minute after the wake"
    else
      check_fail "no 000 later than a minute after the wake" "none" "$a: $(p40_kv_of "$ev" latelist)"
    fi
    case "$act" in
      real|human)
        # Awake, the probe logs a line every 60 to 80 s. A gap of five minutes or more is the box
        # suspended. DarkWakes may cut a long sleep into several gaps, so no single gap must span it.
        a=$(p40_kv_of "$ev" gap)
        if p40_is_int "$a" && [ "$a" -ge 300 ]; then
          check_pass "the probe log has a gap for the sleep" "$a s"
        else
          check_fail "the probe log has a gap for the sleep" "a gap of at least 300 s" "largest gap ${a:-none} s (the VM clock read ${delta:-?} s from the host after the wake)"
        fi ;;
      *) check_skip "the probe log has a gap for the sleep" "host action ${act:-unknown}" ;;
    esac
  fi

  hdr "Steps 5 and 6 after the wake"
  p40_reach eg-restart
  rec_row 11 "Slept ${P40_SLEEP:-length not read}. First request after the wake: ${first:-none}. 000 after the first minute: $(p40_kv_of "$ev" late). Relay listening $lat. Health after the wake: $(kv_get step11.health "not read"). VM clock ${delta:-?} s from the host. $( [ "$(p40_nfail)" = 0 ] && printf '200 and the 403 body as before.' || printf '%s failed checks (see 3.3b).' "$(p40_nfail)")"
  return 0
}

# ---------------------------------------------------------------------------------------------
# 3.4ev Step 15: the evening
# ---------------------------------------------------------------------------------------------
# Re-entry: the clone this run made is kept, the allow is written again (the same lines), a
# session already open in eg-night is kept, a probe loop already running is kept. The night
# starts again at this attempt's reading.
# p40_epoch_utc EPOCH [s]: the time in UTC to the minute (s: to the second). BSD date -r, else GNU -d.
p40_epoch_utc() {
  local f='+%Y-%m-%d %H:%M'
  [ "${2:-}" = s ] && f='+%Y-%m-%d %H:%M:%S'
  date -u -r "$1" "$f" 2>/dev/null || date -u -d "@$1" "$f" 2>/dev/null || printf '%s' "$1"
}
st_3_4ev() {
  local repo="" packs="" w="" now="" h="" half="" kept=0 named="" nhost=0 k=0 prev="" desc=""
  h="${MT_MIN_NIGHT_HOURS:-8}"; p40_is_int "$h" || h=8
  half="${MT_MIN_SLEEP_MINS:-60}"; p40_is_int "$half" || half=60
  half=$((half / 2))
  p40_end_session t1 eg-restart
  # The clone an earlier attempt made is kept, so its repository is not asked again.
  if [ "${DRY:-0}" != 1 ] && [ -d "$P/eg-night/.git" ] && [ "$(kv_get night.cloned "")" = "$P/eg-night" ]; then kept=1; fi
  if [ "$kept" = 0 ]; then
    read_line repo "A repository you work on, as a URL or a local path. A fresh clone of it goes to ~/mt-egress/eg-night (never an existing project path):" repo
    repo="${repo#"${repo%%[![:space:]]*}"}"; repo="${repo%"${repo##*[![:space:]]}"}"
    [ -n "$repo" ] || step_abort "no repository given"
    kv_set night.repo "$repo"
    # A local path typed as ~/... (git clone expands no tilde).
    case "$repo" in "~/"*) repo="$HOME/${repo#"~/"}" ;; esac
  fi
  prev=$(kv_get night.packs "")
  read_line packs "The packs (or hosts) its work needs, separated by spaces, for example: github npm${prev:+
Press Enter alone to keep what an earlier attempt allowed: $prev}" packs
  packs="${packs#"${packs%%[![:space:]]*}"}"; packs="${packs%"${packs##*[![:space:]]}"}"
  [ -n "$packs" ] || packs="$prev"
  [ -n "$packs" ] || step_abort "no packs given: run 3.4ev again and name what the work needs (cleat egress packs lists them)"
  if printf '%s' "$packs" | LC_ALL=C grep -q -e '[^a-z0-9. -]'; then
    step_abort "packs and hosts are lowercase letters, digits, dots and dashes, separated by spaces: $packs"
  fi
  kv_set night.packs "$packs"
  # The record names packs only. A typed host can name an organisation, so it is counted.
  for w in $packs; do
    case "$w" in *.*) nhost=$((nhost + 1)) ;; *) named="$named${named:+ }$w" ;; esac
  done
  P40_NIGHT_ALLOW="${named:-no pack}$( [ "$nhost" -gt 0 ] && printf ' and %s typed host(s)' "$nhost")"
  record_value night.allow "$P40_NIGHT_ALLOW" "what the night's work was allowed (packs by name, typed hosts counted)"

  hdr "A fresh clone in ~/mt-egress/eg-night"
  if [ -e "$P/eg-night" ] && [ "${DRY:-0}" != 1 ]; then
    if [ "$kept" = 1 ]; then
      check_note "eg-night is the clone an earlier attempt made: kept"
    else
      choose night-dir "~/mt-egress/eg-night exists and this run did not clone it. Is it a fresh clone you made for this run (no box ever ran there)?" "n=no: stop here (remove it, then run 3.4ev again)" "y=yes, a fresh clone of my own: use it"
      [ "$CHOICE" = y ] || step_abort "~/mt-egress/eg-night exists and is not this run's clone: remove it, then ./egress-release.sh --only 3.4ev"
      kv_set night.cloned "$P/eg-night"
    fi
  else
    run_cmd -t 1800 -n "git clone" -- env GIT_TERMINAL_PROMPT=0 "GIT_SSH_COMMAND=${GIT_SSH_COMMAND:-ssh -o BatchMode=yes}" git clone -- "$repo" "$P/eg-night"
    if [ "$RC" != 0 ]; then
      choose clone-failed "The clone failed (above): a credential prompt cannot run here. Clone it yourself in another terminal into ~/mt-egress/eg-night (a fresh clone), then answer y." "n=stop here" "y=it is cloned into ~/mt-egress/eg-night"
      [ "$CHOICE" = y ] || step_abort "the clone failed: clone it into ~/mt-egress/eg-night by hand, then ./egress-release.sh --only 3.4ev"
    fi
    kv_set night.cloned "$P/eg-night"
  fi
  if [ "${DRY:-0}" != 1 ] && [ ! -d "$P/eg-night/.git" ]; then step_abort "~/mt-egress/eg-night holds no git checkout"; fi
  p40_cd eg-night

  hdr "T2: cleat egress allow $packs"
  # shellcheck disable=SC2086
  clt -T 300 -- egress allow $packs
  if ! expect_rc "cleat egress allow exits 0" 0 && [ "${DRY:-0}" != 1 ]; then
    # Nothing ran in eg-night yet: a night under the wrong policy would cost the whole night.
    step_abort "cleat egress allow saved nothing (its message is above: a name that is not a pack or a host, or a capability that rules egress out). Fix what it names, then ./egress-release.sh --only 3.4ev"
  fi
  expect_contains "the policy was saved" "✔ Saved to "                                       # bin/cleat:14258
  expect_contains "in the test config" "mt-egress-xdg/cleat/config"
  expect_match "the policy reads strict, port 443 only" 'Now strict, [0-9]+ hosts allowed, port 443 only\.'   # bin/cleat:14265
  for w in $packs; do
    k=$((k + 1))
    case "$w" in *.*) desc="the allow names typed host $k" ;; *) desc="the allow names the pack $w" ;; esac
    expect_match "$desc" "^ +(pack )?$(printf '%s' "$w" | sed 's/\./\\./g')\$"   # bin/cleat:14222 (pack), 14242 (host), printed at 14260
  done

  if p40_live eg-night; then
    check_note "Claude Code already runs in eg-night (an earlier attempt opened it): not launched again"
  else
    p40_launch t1 eg-night cleat launch-3.4ev 900 \
      "+Egress:     strict  ·  " "-Egress refused" "-Shim not listening"   # bin/cleat:12332, 11781, 11464
  fi
  p40_ask_record long-task T1 "Give Claude Code in T1 a long task on this repository, one you would normally leave running overnight.
Leave T1 attached all night: the idle sweep never touches an attached session." "Did Claude start on it?"

  hdr "T2: egprobe eg-night, egread eg-night, the sleep assertions"
  # The box's probe log outlives a night run again (the box and /tmp/egress-probe.log stay): 3.4am
  # counts only the lines from here on.
  kv_set night.probe.from "$(epoch_now)"
  p40_probe_start eg-night
  p40_egread eg-night
  now=$(epoch_now)
  kv_set night.start "$now"
  # A new night needs its own morning quit. 3.4dd skips the quit when night.dd.done equals
  # night.dd.reopen_at (its own resume after a cut), so a night run again (--only or --from 3.4ev)
  # would read an earlier night's quit as this one's and never quit Docker Desktop.
  kv_del night.dd.done
  kv_del night.dd.reopen_at
  kv_del night.dd.quit_at
  kv_del night.dd.how
  kv_set night.read "$P40_RN"
  kv_set night.vol.created "$(p40_rd vol.created)"
  kv_set night.vol.labels "$(p40_rd vol.labels)"
  record_value night.start.utc "$(utc_stamp)" "the night starts at the evening reading (UTC)"
  record_value night.evening "gateway health=$(p40_rd gw.health) restarts=$(p40_rd gw.restarts) | path_ok $(p40_rd path_ok) | volume created=$(p40_rd vol.created) labels=$(p40_rd vol.labels) | relay started=$(p40_rd relay.started) exited=$(p40_rd relay.exited) again=$(p40_rd relay.again) | allow rows $(p40_rd allow_rows)" "the evening reading"
  expect_eq "the gateway is healthy in the evening" "$(p40_rd gw.health)" healthy
  w="keep-awake off"
  p40_keepawake night.keepawake || w="something held sleep (see 3.4ev)"
  rec_row 15 "Evening: started $(utc_stamp) UTC on a fresh clone, allowed $P40_NIGHT_ALLOW, $w, a probe a minute from inside the box."
  hdr "What comes next"
  say "3.4lid asks you to close the lid for at least $half minutes, with a reading just before and right after."
  if p40_is_int "$now"; then
    say "Then 3.4am waits for the morning: at least $h hours from now, until $(p40_epoch_utc $((now + h * 3600))) UTC."
  fi
  say "If this terminal closes, ./egress-release.sh --resume goes on where it stopped."
  return 0
}

# ---------------------------------------------------------------------------------------------
# 3.4b-ev The stale credential, evening (EXTRA)
# ---------------------------------------------------------------------------------------------
# Re-entry: the pin is written again, a session already open in T3 is kept, the gateway is
# stopped again (a stopped one is a NOTE).
st_3_4b_ev() {
  local st="" s=""
  t_is_auto && step_skip "T1 simulated: no Claude login without a human (3.4b needs the second login from 2.25d)"
  p40_cd eg-stale make
  cl -q -- account list
  if [ "${DRY:-0}" != 1 ] && ! p40_acct_names "$OUT" | LC_ALL=C grep -q -x -e lab-b; then
    step_skip "the test config holds no lab-b login (2.25d makes it): 3.4b needs it"
  fi
  hdr "T2: cleat account lab-b (pin this box to the second login)"
  clt -T 300 -- account lab-b
  expect_rc "cleat account lab-b exits 0" 0
  if p40_live eg-stale; then
    check_note "Claude Code already runs in eg-stale: not launched again"
  else
    p40_launch t3 eg-stale cleat launch-3.4b 900 "-Egress refused"   # bin/cleat:11781
  fi
  p40_ask_record hello-t3 T3 "In Claude Code in T3, send exactly this message:
reply with just ok" "Did Claude answer?"
  t_wait_exit t3 eg-stale 600
  if p40_up eg-stale; then check_pass "the box keeps running after /exit, with its staged login"; else check_fail "the box keeps running after /exit" "running" "stopped"; fi
  hdr "T2: docker stop of eg-stale's gateway (the box stays up with no gateway)"
  gw_stop eg-stale
  val s -t 60 -- gw_state eg-stale
  case "$s" in
    exited*|"<dry:"*) check_pass "eg-stale's gateway is stopped" "$s" ;;
    *) check_fail "eg-stale's gateway is stopped" "exited" "${s:-no gateway}" ;;
  esac
  if p40_up eg-stale; then check_pass "the box still runs with no gateway"; else check_fail "the box still runs with no gateway" "running" "stopped"; fi
  cl -q -- account list
  st=$(p40_acct_state "$OUT" lab-b)
  record_value night.stale.ev "${st:-not listed}" "how lab-b reads in the evening (its state word only)"
  kv_set night.stale.start "$(epoch_now)"
  return 0
}

# ---------------------------------------------------------------------------------------------
# 3.4lid Step 15: around the lid sleep
# ---------------------------------------------------------------------------------------------
# Re-entry: both readings and the sleep are taken again.
st_3_4lid() {
  local half="" g="" act="" asked="" br="" ar="" p5=""
  half="${MT_MIN_SLEEP_MINS:-60}"
  p40_is_int "$half" || half=60
  half=$((half / 2))
  p40_cd eg-night
  p40_up eg-night || step_abort "the eg-night box is not running: run 3.4ev first"
  val g -t 60 -- gw eg-night
  [ -n "$g" ] || step_abort "eg-night has no gateway: run 3.4ev first"
  hdr "Just before you close the lid: egread eg-night"
  p40_egread eg-night
  kv_set lid.before "$P40_RN"
  br=$(p40_rd allow_rows)
  record_value lid.before.read "gateway health=$(p40_rd gw.health) | allow rows ${br:-?} | relay exited=$(p40_rd relay.exited) again=$(p40_rd relay.again)" "just before the lid sleep"
  lid_sleep "$half"
  act="${HOSTACT:-}"
  asked=$(kv_get "$STEP_ID.asked_at" "")
  hdr "Right after the wake, in this order"
  dk -t 60 -- inspect -f '{{json .State.Health.Log}}' "$g"
  record_value lid.health "$(p40_health_sum "$OUT")" "the health probes right after the wake"
  kv_set lid.health.json "$(head -c 3000 "$OUT" 2>/dev/null)"
  p40_egread eg-night
  kv_set lid.after "$P40_RN"
  ar=$(p40_rd allow_rows)
  run_cmd -t 60 -- p40_probe_tail eg-night 5
  p5=$(p40_join "$OUT")
  record_value lid.probe "$p5" "the last five requests after the wake"
  record_value lid.tunnels "allow rows ${br:-?} before, ${ar:-?} after" "the tunnel count across the sleep"
  p40_sleep_len "$half" "${asked:-0}" "the lid sleep" "$act"
  say "Next, 3.4am asks how to wait for the morning. Answer w and leave this terminal open: it goes on by itself."
  rec_row 15 "Lid sleep: ${P40_SLEEP:-length not read}. Allow rows ${br:-?} before and ${ar:-?} after. Health after the wake: $(kv_get lid.health "not read"). Requests after the wake: ${p5:-none}."
  return 0
}

# ---------------------------------------------------------------------------------------------
# 3.4am Step 15: the morning
# ---------------------------------------------------------------------------------------------
# Re-entry: every morning read is taken again (nothing here changes the box).
st_3_4am() {
  local h="" need=0 secs="" end="" f="" probe="" n000="" delta="" a="" b="" vc="" vl="" table="" outn="" wins="" w3="" nf=0 from="" old=0 d=0
  h="${MT_MIN_NIGHT_HOURS:-8}"
  p40_is_int "$h" || h=8
  need=$((h * 3600))
  secs=$(p40_night_secs)
  if [ -z "$secs" ] && [ "${DRY:-0}" != 1 ]; then step_abort "no evening reading: run 3.4ev first"; fi
  if p40_is_int "$secs" && [ "$secs" -lt "$need" ]; then
    end=$(p40_epoch_utc $(( $(kv_get night.start 0) + need )))
    choose night-early "The night has lasted $((secs / 3600))h$(printf '%02d' $(((secs % 3600) / 60)))m of $h hours (enough at $end UTC). What now?" \
      "w=wait here until then (d during the wait goes on early, which is a FAIL)" "q=save and quit, resume after $end UTC" "g=go on now (recorded as a FAIL: under $h hours)"
    case "$CHOICE" in
      q) say "Saved. Resume after $end UTC with: ./egress-release.sh --resume"; exit 10 ;;
      w) wait_for night-wait "Nothing to do: the script goes on by itself at $end UTC. Press d to go on early (a FAIL)." --auto --timeout $((need - secs + 600)) --every 60 -- p40_night_done "$need" ;;
    esac
    secs=$(p40_night_secs)
  fi
  record_value night.hours "$( p40_is_int "$secs" && printf '%sh%02dm' $((secs / 3600)) $(((secs % 3600) / 60)) || printf 'unknown')" "the night so far (from the evening reading)"
  expect_num "the night lasted at least $h hours (in seconds)" "$secs" ge "$need"
  p40_cd eg-night

  hdr "The morning reads, before the Docker Desktop quit"
  p40_egread eg-night
  kv_set night.am.read "$P40_RN"
  clt -T 300 -- egress status
  f="$OUT"
  record_value night.status "$(p40_join "$f" | cut -c1-600)" "cleat egress status in the morning"
  expect_match "status names the gateway's state" 'Gateway (healthy|stopped|orphaned|displaced|missing)'   # bin/cleat:14647 to 14685
  if [ "${DRY:-0}" = 1 ] || LC_ALL=C grep -q 'Gateway healthy' "$f"; then
    expect_match "a healthy gateway shows its relay row" 'Shim (listening|not listening)' "$f"           # bin/cleat:14698, 14707
    expect_contains "the relay is alive in the morning" "● Shim listening" "$f"                         # bin/cleat:14698
  else
    check_note "the gateway is not healthy in the morning: status names it ($(LC_ALL=C grep -E -m 1 -e 'Gateway' "$f"))"
  fi
  expect_eq "ok path_ok true" "$(p40_rd path_ok)" true
  vc=$(p40_rd vol.created); vl=$(p40_rd vol.labels)
  expect_eq "the socket volume's CreatedAt is unchanged since the evening (W6)" "$vc" "$(kv_get night.vol.created "")"
  expect_eq "the socket volume's labels are unchanged since the evening (W6)" "$vl" "$(kv_get night.vol.labels "")"
  record_value night.relay "started=$(p40_rd relay.started) exited=$(p40_rd relay.exited) again=$(p40_rd relay.again) | last_shim_seen $(p40_rd last_shim_seen) | gateway restarts $(p40_rd gw.restarts)" "the relay over the night (respawns show in exited and again)"
  a=$(iso_to_epoch "$(p40_rd vm_clock)"); b=$(iso_to_epoch "$(p40_rd host_clock)")
  if p40_is_int "$a" && p40_is_int "$b"; then delta=$((a - b)); fi

  hdr "Minutes without egress (the probe log)"
  run_cmd -q -t 120 -- p40_probe_all eg-night
  probe="$STEP_DIR/probe-night.txt"
  cp "$OUT" "$probe" 2>/dev/null || : > "$probe"
  # Lines from before this night's evening (an earlier night, or an earlier attempt of 3.4ev, in
  # the same box) are left out. The box's clock is put on the host's with the delta read above,
  # less 90 s for the drift of the box's clock over the night.
  from=$(kv_get night.probe.from "")
  if [ "${DRY:-0}" != 1 ] && p40_is_int "$from"; then
    d="$delta"
    p40_is_int "${d#-}" || d=0
    if awk -v from="$((from + d - 90))" "$(p40_awk_epoch)"'NF >= 2 { e = p40_ep($1); if (e != "" && e < from + 0) next } { print }' "$probe" > "$probe.night" 2>/dev/null; then
      old=$(( $(awk 'NF >= 2 { n++ } END { print n + 0 }' "$probe") - $(awk 'NF >= 2 { n++ } END { print n + 0 }' "$probe.night") ))
    else
      old=0
    fi
    if [ "$old" -gt 0 ]; then
      check_note "$old probe lines from before this night's evening (an earlier night or attempt in the same box) are left out"
      mv -f "$probe.night" "$probe"
    else
      rm -f "$probe.night"
    fi
  fi
  n000=$(awk '$2 == "000" { n++ } END { print n + 0 }' "$probe")
  record_value night.000 "$n000" "minutes without egress (000 lines in the probe log)"
  record_value night.probe.tail "$(tail -n 5 "$probe" | p40_join)" "the last five requests"
  wins="$STEP_DIR/sleep-windows.txt"
  : > "$wins"
  if host_can || [ "${DRY:-0}" = 1 ]; then
    pm_sleep_log
    record_value night.lastsleep "${PM_SLEEP_START:-none} to ${PM_SLEEP_END:-none}, ${PM_SLEEP_MINS:-?} min, ${PM_DARKWAKES:-0} DarkWakes" "the last sleep in pmset's log (tail -40)"
    run_cmd -q -t 300 -- p40_pm_log 400
    p40_pm_windows "$OUT" > "$wins"
  else
    say_do Mac "In a terminal on the Mac run (it can take a while):
  pmset -g log | grep -E 'Entering Sleep|Wake from' | tail -40
DarkWake lines are maintenance wakes inside a sleep."
  fi
  record_value night.sleeps "$(p40_win_text "$wins" "$(kv_get night.start 0)" | p40_join)" "the sleep windows of the night (pmset)"
  table=$(p40_classify_000 "$probe" "$wins" "${delta:-0}")
  outn=$(printf '%s\n' "$table" | awk -F= '/^outside=/ { print $2 }')
  record_value night.000.outside "${outn:-?}" "000 minutes outside every sleep and the minute after its wake"
  table=$(printf '%s\n' "$table" | grep -v '^outside=' | head -n 40)
  if [ -s "$wins" ]; then
    a="Sleep windows from pmset:
$(p40_win_text "$wins" "$(kv_get night.start 0)" | tail -n 15 | sed 's/^/  /')"
    b="${n000} minutes of 000 in all, ${outn:-?} of them outside every sleep and its first minute:"
  else
    a="No sleep window was read here: hold the 000 minutes against the pmset log you just ran
(pmset prints your local time, the probe log UTC)."
    b="${n000} minutes of 000 in all:"
  fi
  if [ "${DRY:-0}" != 1 ] && [ "$(awk 'NF >= 2 { n++ } END { print n + 0 }' "$probe")" = 0 ]; then
    check_fail "the probe log holds the night's requests" "a line a minute since the evening" "no line: the probe loop of 3.4ev did not run all night"
  elif [ "${DRY:-0}" != 1 ] && [ "$n000" = 0 ]; then
    check_pass "no minute without egress all night (no 000 in the probe log)"
  else
    p40_ask night-judge T2 "Read the minutes without egress beside the sleeps of the night (all times UTC).
The box's clock reads ${delta:-?} s from the host's.
$a" "$b
${table:-  (none)}" "Do the 000 minutes fall only inside a sleep or the first minute after a wake?"
  fi
  kv_set night.end "$(epoch_now)"
  # W3: a relay that went silent overnight must be named by the morning's status (read above) and
  # by T1's session-end report. 3.4dd's quit ends the session with the daemon down, when no report
  # can print. The quit also clears the dead relay. So the session ends here first, Docker up.
  if [ "${DRY:-0}" = 1 ] || { LC_ALL=C grep -q 'Gateway healthy' "$f" && ! LC_ALL=C grep -q '● Shim listening' "$f"; }; then
    hdr "The relay is silent this morning: T1's session-end report must name it (W3)"
    nf=$(p40_nfail)
    p40_end_report eg-night night.w3-end
    if [ "$(p40_nfail)" = "$nf" ]; then w3=" The relay was silent in the morning: status and T1's session-end report named it (W3)."
    else w3=" The relay was silent in the morning: status named it, T1's session-end report did not pass (see 3.4am)."; fi
  fi
  rec_row 15 "Morning after $(kv_get night.hours "?"): path_ok $(p40_rd path_ok), the socket volume $( [ "$vc" = "$(kv_get night.vol.created "")" ] && [ "$vl" = "$(kv_get night.vol.labels "")" ] && printf 'unchanged' || printf 'CHANGED'), relay started $(p40_rd relay.started) exited $(p40_rd relay.exited) again $(p40_rd relay.again), gateway restarts $(p40_rd gw.restarts), $n000 minutes of 000 (${outn:-?} outside a sleep window and its first minute).$w3"
  return 0
}

# ---------------------------------------------------------------------------------------------
# 3.4b-am The stale credential, morning (EXTRA)
# ---------------------------------------------------------------------------------------------
# Re-entry: a box already removed is a SKIP (the evening's half did not run, or the rm did).
st_3_4b_am() {
  local c="" st="" ev="" s="" now="" h="" end=""
  h="${MT_MIN_NIGHT_HOURS:-8}"; p40_is_int "$h" || h=8
  t_is_auto && step_skip "T1 simulated: no Claude login without a human"
  val c -t 60 -- cn eg-stale
  [ -n "$c" ] || [ "${DRY:-0}" = 1 ] || step_skip "no eg-stale box: 3.4b-ev did not run, or its box is removed"
  s=$(kv_get night.stale.start "")
  now=$(epoch_now)
  # The access token lives about eight hours: the rm must come after that. 3.4b-ev stopped the
  # gateway after the evening reading, so the night's end can come a little short of it.
  if p40_is_int "$s" && p40_is_int "$now" && [ $((now - s)) -lt $((h * 3600)) ]; then
    end=$(p40_epoch_utc $((s + h * 3600)))
    choose stale-early "The gateway of eg-stale stopped $(( (now - s) / 60 )) minutes ago, under $h hours (reached at $end UTC). The access token may not have expired yet. What now?" \
      "w=wait here until then (d during the wait goes on early)" "g=go on now (noted)"
    if [ "$CHOICE" = w ]; then
      wait_for stale-wait "Nothing to do: the script goes on by itself at $end UTC." --auto --timeout $((h * 3600 - (now - s) + 300)) --every 30 -- p40_since_done night.stale.start $((h * 3600))
    fi
    now=$(epoch_now)
  fi
  if p40_is_int "$s" && p40_is_int "$now"; then
    record_value night.stale.hours "$(( (now - s) / 3600 ))h$(printf '%02d' $(( ((now - s) % 3600) / 60 )))m" "time since the gateway stopped"
    [ $((now - s)) -ge $((h * 3600)) ] || check_note "fewer than $h hours since the gateway stopped: the access token may not have expired yet"
  fi
  p40_cd eg-stale
  clt -T 300 -- rm
  expect_rc "cleat rm exits 0" 0
  expect_contains "cleat rm removed the eg-stale box" "Removed $c."   # bin/cleat:23064
  cl -q -- account list
  st=$(p40_acct_state "$OUT" lab-b)
  ev=$(kv_get night.stale.ev "")
  record_value night.stale.am "${st:-not listed}" "how lab-b reads in the morning, after the rm (its state word only)"
  case "$st" in
    re-login|"signed out") check_note "lab-b reads $st after the rm (in the evening: ${ev:-not read}): the residual 3.4b describes" ;;
  esac
  return 0
}

# ---------------------------------------------------------------------------------------------
# 3.4dd Step 15: Docker Desktop quit and reopen
# ---------------------------------------------------------------------------------------------
# Re-entry: Docker already down means the quit stands. A box that runs again after the reopen
# means the resume of an earlier attempt ran: the post-resume reads run again.
st_3_4dd() {
  local how="" kase="" kept="" resumed=0 live=0
  p40_cd eg-night
  if p40_dk_up 0; then
    if p40_running eg-night 0 && [ -n "$(kv_get night.dd.reopen_at "")" ] && [ "$(kv_get night.dd.done "")" = "$(kv_get night.dd.reopen_at "")" ]; then
      resumed=1
      check_note "the quit, the reopen and the resume of an earlier attempt stand: the reads after the resume run again"
    else
      # No session (3.4am ended it for the W3 report, or it was gone): the quit ends none, and
      # T1's text is not this quit's.
      if p40_live eg-night 0; then live=1; else check_note "Claude Code is not open in eg-night: the quit ends no session"; fi
      kv_set night.dd.quit_at "$(utc_stamp)"
      record_value night.dd.quit_at "$(kv_get night.dd.quit_at "")" "the morning quit time, UTC"
      dd_quit eg-night
      how="${HOSTACT:-}"
      kv_set night.dd.how "$how"
      if [ "$how" = skipped ]; then step_abort "Docker Desktop was not quit. Run 3.4dd again when it can be: ./egress-release.sh --resume"; fi
      [ "$live" = 0 ] || p40_quit_end eg-night night.t1-end
    fi
  else
    how=$(kv_get night.dd.how human)
    check_note "Docker does not answer: the quit of an earlier attempt stands"
  fi
  if [ "$resumed" = 0 ]; then
    how=$(kv_get night.dd.how "$how")
    if p40_dk_up 1; then
      [ "$how" = sim ] && dd_open
    else
      dd_open
      [ "${HOSTACT:-}" = skipped ] && step_abort "Docker Desktop was not reopened. Run 3.4dd again once it is: ./egress-release.sh --resume"
    fi
    kv_set night.dd.reopen_at "$(utc_stamp)"
    record_value night.dd.reopen_at "$(kv_get night.dd.reopen_at "")" "the reopen time, UTC"
    hdr "After the reopen, before any cleat command (exec lines fail while the box is stopped)"
    p40_egread eg-night
    kase=$(p40_case)
    [ "${DRY:-0}" = 1 ] && kase=clean
    kv_set night.dd.case "$kase"
    # The scenario expects the states 3.1 recorded: a different case is worth its own line in the record.
    if [ "${DRY:-0}" != 1 ] && [ -n "$(kv_get step14.case "")" ] && [ "$kase" != "$(kv_get step14.case "")" ]; then
      check_note "this quit left the $kase case, 3.1c's left the $(kv_get step14.case "") case"
    fi
    record_value night.dd.reopen "case $kase | box running=$(p40_rd box.running) exit=$(p40_rd box.exit) | gateway running=$(p40_rd gw.running) exit=$(p40_rd gw.exit) started=$(p40_rd gw.started) restarts=$(p40_rd gw.restarts)" "both containers after the reopen (the box's exit code and the gateway's StartedAt, never the gateway's exit code alone)"
    [ "$kase" = w4 ] && [ "$(p40_rd gw.running)" = true ] && kept=$(p40_rd gw.started)
    kv_set night.dd.kept "$kept"
    kv_set night.dd.box.running "$(p40_rd box.running)"
    p40_state_check eg-night
    p40_launch t1 eg-night "cleat resume" resume-3.4dd 600 "-Shim not listening" "-Egress refused"   # bin/cleat:11464 and 14707, 11781
    kv_set night.dd.done "$(kv_get night.dd.reopen_at "")"
  else
    kase=$(kv_get night.dd.case "")
    kept=$(kv_get night.dd.kept "")
  fi
  p40_order eg-night "$kept"
  p40_egread eg-night
  record_value night.dd.after "gateway health=$(p40_rd gw.health) restarts=$(p40_rd gw.restarts) | path_ok $(p40_rd path_ok) | relay started=$(p40_rd relay.started) exited=$(p40_rd relay.exited) again=$(p40_rd relay.again) | volume created=$(p40_rd vol.created)" "after the resume"
  expect_eq "path_ok true after the resume" "$(p40_rd path_ok)" true
  expect_eq "the socket volume's CreatedAt is unchanged since the evening (W6)" "$(p40_rd vol.created)" "$(kv_get night.vol.created "")"
  expect_eq "the socket volume's labels are unchanged since the evening (W6)" "$(p40_rd vol.labels)" "$(kv_get night.vol.labels "")"
  rec_row 15 "Morning Docker Desktop quit and reopen: case ${kase:-?} (3.1c: $(kv_get step14.case "not run")), $( [ "$(kv_get night.dd.box.running "")" = false ] && printf 'the box stayed stopped until cleat resume' || printf 'the box read running=%s after the reopen' "$(kv_get night.dd.box.running "?")"), $( [ -n "$kept" ] && printf 'the gateway the daemon started was kept' || printf 'the gateway started before the box'). Night from $(p40_epoch_utc "$(kv_get night.start 0)") to $(p40_epoch_utc "$(kv_get night.end 0)") UTC ($(kv_get night.hours "?")). $( [ "$(p40_nfail)" = 0 ] && printf 'No relay advisory at the resume.' || printf '%s failed checks in 3.4dd.' "$(p40_nfail)")"
  return 0
}

# ---------------------------------------------------------------------------------------------
# 3.5 Final cleanup
# ---------------------------------------------------------------------------------------------
# Re-entry: every part is idempotent (a box already removed, a directory already gone).
st_3_5() {
  local d="" c="" left="" f="" sw="" bad="" exp="" key="" night="" others="" n=0 sid="" a="" allow="" t="" sids=""
  local trans=() dbg=()
  hdr "Sessions still open end first"
  for d in $(p40_projects); do
    if p40_live "$d"; then
      case "$d" in eg-stale) t_wait_exit t3 "$d" 600 ;; *) t_wait_exit t1 "$d" 600 ;; esac
    fi
  done

  hdr "cleat rm in every test project that still has a box"
  for d in $(p40_projects); do
    val c -t 60 -- cn "$d"
    [ -n "$c" ] || continue
    p40_cd "$d" make
    clt -T 300 -- rm
    expect_contains "cleat rm removed the $d box" "Removed $c."   # bin/cleat:23064
  done
  cd "$HOME" || fatal "cannot cd to HOME"
  left=""
  for d in $(p40_projects); do
    val c -t 60 -- cn "$d"
    [ -n "$c" ] && [ "${DRY:-0}" != 1 ] && left="$left $d"
  done
  expect_eq "no test project still has a box (every cn prints nothing)" "${left# }" ""

  hdr "egobjs: no gateway, no socket volume, the host files"
  run_cmd -t 60 -- egobjs
  f="$OUT"
  expect_eq "no gateway is left" "$(awk '/^-- gateways:/ { s = 1; next } /^-- / { s = 0 } s && NF { n++ } END { print n + 0 }' "$f" 2>/dev/null)" 0
  expect_eq "no socket volume is left" "$(awk '/^-- socket volumes:/ { s = 1; next } /^-- / { s = 0 } s && NF { n++ } END { print n + 0 }' "$f" 2>/dev/null)" 0
  val sw -t 60 -- cn_name eg-sweep
  run_cmd -t 30 -- p40_hostfiles
  exp=""; bad=""
  while IFS= read -r a; do
    [ -n "$a" ] || continue
    case "$a" in
      egress-pins/global) ;;
      egress-notices/"$sw"|egress-pins/"$sw")
        [ -n "$sw" ] || { bad="$bad $a"; continue; }
        exp="$exp $a" ;;
      *) bad="$bad $a" ;;
    esac
  done < "$OUT"
  if [ -n "$exp" ]; then
    record_value final.sweep-files "${exp# }" "the files 2.28b's raw removal of the eg-sweep box left (expected, removed now)"
    for a in $exp; do safe_rm "$CFG/$a"; done
  fi
  expect_eq "nothing else is left under the host files (egress-pins/global stays)" "${bad# }" ""

  hdr "cleat account list: the test logins"
  p40_cd eg-restart make
  cl -q -- account list
  a=$(p40_acct_names "$OUT" | tr '\n' ' ')
  # Only the scenario's two names are recorded: any other is a name you chose, so it is counted.
  t=""; n=0
  for c in $a; do
    case "$c" in lab-a|lab-b) t="$t${t:+ }$c" ;; *) n=$((n + 1)) ;; esac
  done
  record_value final.accounts "${t:-neither lab-a nor lab-b}$( [ "$n" -gt 0 ] && printf ' plus %s other' "$n")" "the accounts in the test config"
  [ "$n" = 0 ] || check_note "the test config holds $n account(s) the scenario does not name (deleted with ~/mt-egress-xdg below)"
  cd "$HOME" || fatal "cannot cd to HOME"

  hdr "The test projects' Claude Code transcripts"
  for d in $(p40_projects); do
    key=""
    val key -t 60 -- p40_session_key "$d"
    case "$key" in "$d"-????????) ;; *) [ "${DRY:-0}" = 1 ] || check_note "no transcript key for $d (got ${key:-nothing})"; continue ;; esac
    [ -d "$HOME/.claude/projects/$key" ] || continue
    if [ "$d" = eg-night ]; then night="$HOME/.claude/projects/$key"; else trans[${#trans[@]}]="$HOME/.claude/projects/$key"; fi
  done
  for d in $(p40_projects); do
    for a in "$HOME/.claude/projects/$d"-????????; do
      [ -d "$a" ] || continue
      case " ${trans[*]+${trans[*]}} $night " in *" $a "*) ;; *) others="$others ${a##*/}" ;; esac
    done
  done
  [ -z "$others" ] || check_note "directories named like a test project but not derived from ~/mt-egress (kept, not offered):$others"
  record_value final.transcripts "$(( ${#trans[@]} + $( [ -n "$night" ] && printf 1 || printf 0 ) ))" "test transcript directories under ~/.claude/projects"
  # The debug files of the test sessions, read before any transcript goes: Claude Code names a
  # session's debug log after its id, which is its transcript's file name (2.25 reads
  # ~/.claude/debug/<id>.txt). Plus the two 2.25 sessions by the ids 2.25 recorded.
  sids=""
  for a in ${trans[@]+"${trans[@]}"} ${night:+"$night"}; do
    for f in "$a"/*.jsonl; do
      [ -f "$f" ] || continue
      sid="${f##*/}"; sids="$sids ${sid%.jsonl}"
    done
  done
  sids="$sids $(kv_get acct.sid.c "") $(kv_get acct.sid.d "")"
  for sid in $sids; do
    case "$sid" in ''|*[!A-Za-z0-9_-]*) continue ;; esac
    f="$HOME/.claude/debug/$sid.txt"
    [ -f "$f" ] || continue
    case " ${dbg[*]+${dbg[*]}} " in *" $f "*) continue ;; esac
    dbg[${#dbg[@]}]="$f"
  done
  if [ "${#trans[@]}" -gt 0 ]; then
    say "The test projects' transcripts (cleat rm keeps them on purpose):"
    for a in "${trans[@]}"; do say "  ${a/#$HOME/~}"; done
    choose del-transcripts "Delete these ${#trans[@]} test transcript directories? (eg-night's is asked next)" "n=keep them" "y=delete them"
    if [ "$CHOICE" = y ]; then
      allow=$(kv_get cleanup.allow "")
      for a in "${trans[@]}"; do allow="$allow $a"; done
      kv_set cleanup.allow "${allow# }"
      for a in "${trans[@]}"; do safe_rm "$a"; done
      check_pass "the test transcripts are deleted" "${#trans[@]} directories"
    else
      check_note "the test transcripts are kept (${#trans[@]} directories)"
    fi
  fi
  if [ -n "$night" ]; then
    choose del-night "Delete eg-night's transcripts too (the overnight run's work on your repository)?" "n=keep them" "y=delete them"
    if [ "$CHOICE" = y ]; then
      kv_set cleanup.allow "$(kv_get cleanup.allow "") $night"
      safe_rm "$night"
      check_pass "eg-night's transcripts are deleted"
    else
      check_note "eg-night's transcripts are kept"
    fi
  fi

  hdr "The debug files of the test sessions"
  if [ "${#dbg[@]}" -gt 0 ]; then
    t=""
    [ -z "$night" ] || t=" (eg-night's included, whatever you chose for its transcripts)"
    choose del-debug "Delete the ${#dbg[@]} debug files of the test sessions in ~/.claude/debug$t?" "n=keep them" "y=delete them"
    if [ "$CHOICE" = y ]; then
      allow=$(kv_get cleanup.allow "")
      for a in "${dbg[@]}"; do allow="$allow $a"; done
      kv_set cleanup.allow "${allow# }"
      for a in "${dbg[@]}"; do safe_rm "$a"; done
      check_pass "the test debug files are deleted" "${#dbg[@]} files"
    else
      check_note "the test debug files are kept"
    fi
  else
    check_note "no debug file of a test session to delete"
  fi

  hdr "The test directories, the env file and the scratch files"
  safe_rm "$P" "$EGX" "$UPX" "$ENVF"
  for a in mt-int-b.tap mt-gw-before.txt mt-pin.bak mt-w12 mt-upx-config mt-egobjs-before.txt cleat-v154 mt-x; do
    safe_rm "$SCRATCH/$a"
  done
  safe_rm "$CLEAT_UNVAL" "$CLEAT_NOGW"
  if [ "${DRY:-0}" != 1 ]; then
    for a in "$P" "$EGX" "$UPX" "$ENVF"; do
      if [ -e "$a" ]; then check_fail "removed: ${a/#$HOME/~}" "gone" "still there"; else check_pass "removed: ${a/#$HOME/~}"; fi
    done
  fi
  run_cmd -t 60 -- git_dirty_untracked
  expect_eq "git status --short prints nothing (no throwaway copy of 2.1 or 2.24h is left)" "$(awk 'NF' "$OUT" 2>/dev/null | head -n 5 | tr '\n' ' ')" ""

  hdr "The released v1.5.4 image (2.24's cleanup may have left it)"
  if dk -q -t 60 -- image inspect ghcr.io/cleatdev/cleat:v1.5.4 --format '{{.Id}}' && [ "${DRY:-0}" != 1 ]; then
    img_rm ghcr.io/cleatdev/cleat:v1.5.4 || check_note "ghcr.io/cleatdev/cleat:v1.5.4 could not be removed (a container may use it): left as it is"
  else
    [ "${DRY:-0}" = 1 ] && img_rm ghcr.io/cleatdev/cleat:v1.5.4
    check_note "ghcr.io/cleatdev/cleat:v1.5.4 is not present"
  fi

  hdr "Your real config and the egress objects"
  val n -t 30 -- p40_realcfg_count
  expect_eq "your real ~/.config/cleat/config holds no [egress] section (still 0)" "$n" 0
  val n -t 60 -- p40_gw_count
  expect_eq "no gateway container (docker ps -a --filter label=sh.cleat.role=gateway)" "$n" 0
  val n -t 60 -- p40_vol_count
  expect_eq "no socket volume (docker volume ls --filter label=sh.cleat.role=egress-sock)" "$n" 0

  hdr "Left on purpose and two reminders"
  say "Left on purpose: the gateway image (the release pins it) and $MT_IMAGE:latest at spec 6,"
  say "which your daily v1.5.4 cleat accepts. Never cleat nuke to clean up."
  say "~/mt-egress-readings.txt stays until the record is written (5.5 asks)."
  say "Turn your keep-awake utility back on."
  return 0
}

# ---------------------------------------------------------------------------------------------
# The registry (DESIGN 6.1)
# ---------------------------------------------------------------------------------------------
reg 3.0 3 auto gate st_3_0 "Sitting 3 starts: egcheck, egimg"
reg 3.1a 3 mixed gate st_3_1a "Step 14: the box and the before reading"
reg 3.1b 3 mixed gate st_3_1b "Step 14: Docker Desktop quit"
reg 3.1-down 3 expect extra st_3_1_down "Step 14: while Docker is down"
reg 3.1c 3 mixed gate st_3_1c "Step 14: reopen, read before any cleat command (W4)"
reg 3.1d 3 mixed gate st_3_1d "Step 14: resume"
reg 3.1e 3 mixed gate st_3_1e "Step 14: a second quit, cleat starts Docker Desktop"
reg 3.2 3 human extra st_3_2 "Step 14: the unclean half"
reg 3.3a 3 mixed gate st_3_3a "Step 11: before the sleep"
reg 3.3b 3 human gate st_3_3b "Step 11: the sleep and the reads after it"
reg 3.4ev 3 mixed gate st_3_4ev "Step 15: the evening"
reg 3.4b-ev 3 mixed extra st_3_4b_ev "The stale credential: evening"
reg 3.4lid 3 human gate st_3_4lid "Step 15: around the lid sleep"
reg 3.4am 3 mixed gate st_3_4am "Step 15: the morning"
reg 3.4b-am 3 auto extra st_3_4b_am "The stale credential: morning"
reg 3.4dd 3 mixed gate st_3_4dd "Step 15: Docker Desktop quit and reopen"
reg 3.5 3 mixed gate st_3_5 "Final cleanup"
