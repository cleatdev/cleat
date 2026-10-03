# egress-release.d/31-full-b.sh: sitting 2: 2.15 to 2.23.
#
# A part of egress-release.sh. Sourced, never run. It holds only function definitions, reg calls
# and comments: nothing else runs at source time. One function per step, named st_ plus the id
# with . and - turned into _, registered in scenario order with
#   reg ID SITTING KIND CLASS FUNC "TITLE"
# The steps, their checks and their re-entry rules are DESIGN.md section 6.2 (2.15 to 2.23). The
# FULL scenario is EGRESS-RELEASE-TEST.md (the authority), 2.15 to 2.23 at lines 1252 to 1883.
# A helper this part needs that the library lacks is written here, prefixed with the part's
# number (p31_). Every expected string was read in the candidate first (bin/cleat, docker/ or
# docker/gateway/ at ac6ee85) and carries its source line.
#
# Where the code and the scenario or the design differ, the code wins and the comment says so:
#   - 2.19: the scenario's seq-400 storm prints %{http_code} = 000 for every CONNECT the gateway
#     refuses with 403 (curl 7.88 in the box image reports 000 for a tunnel the proxy denied,
#     measured). The step runs the verbatim command, counts refused lines as 403 OR 000 and
#     judges the storm by the gateway's own denied counter (gw-admin counts) rising by at least
#     390, the relay exited count unchanged and a 200 afterwards.
#   - 2.21a: `grep -c 'Only these hosts are reachable'` counts 0 (the strict fragment wraps the
#     sentence, bin/cleat:3466-3467). The step checks `these hosts are reachable, on port 443:`
#     (DESIGN section 8 item 1). A scenario defect, now fixed there: 2.21 a greps the same words.
#   - 2.21a rebind-filtered: `cleat egress log --refused` lists security codes only. The
#     upstream code is not one (bin/cleat:12559-12562, 13914). The step then reads the upstream rows in
#     the full log and checks --refused holds no row for the two names.
#   - 2.23: the security row of the SNI refusal names the SNI (example.org), not the CONNECT
#     target (gateway.py:417 and 834-836). The rebind-filtered block therefore names example.org,
#     where the scenario says api.anthropic.com.
#   - 2.15h and 2.21e's T3 commands run inside the editor's expect program with xp_host, at the
#     same point in the sequence (DESIGN section 8 item 7). 2.21e's pkill is anchored on the
#     cleat process's own argv, so it can never reach the expect driver or the stty wrapper,
#     whose argv also hold the words "bin/cleat egress main". 3.4b's T3 is the one real third
#     terminal.
#   - 2.21e: the box editor's rows depend on how many hosts the global policy holds, so the step
#     walks the list one key at a time and a reactive rule presses space the moment the cursor
#     sits on example.com (bin/cleat:16190-16221 draws that row).
#   - 2.16a and 2.16b (rd-2b): the scenario's `bxr eg-smoke kill PID` fails in the box ("exec:
#     kill: executable file not found", rc 127): the image has no kill binary, only the shell's
#     builtin. p31_box_kill runs `sh -c 'kill "$@"'` as root in the box. An expect_rc shows a
#     kill that did not land. A scenario defect (EGRESS-RELEASE-TEST.md lines 1403 and 1420).
#   - 2.15i: F2 (ac6ee85). The validation met npm failing EACCES on ~/.npm on every host uid but
#     1000: the image's Claude Code install step runs npm as the build user, so ~/.npm belonged
#     to uid 1000. docker/entrypoint.sh now chowns it to the host uid (docker/entrypoint.sh:94).
#     npm view must return a version. An EACCES on ~/.npm is a FAIL tagged (F2), a regression of
#     that fix. The diagnostic still runs as evidence (p31_npm_cache_diag): the owner and the
#     same npm view with a cache the box user owns, which goes through the relay.
#   - Launches the code refuses before Claude opens (2.17b, 2.17c's start, 2.20b, 2.20c, 2.20d's ssh
#     start) run on the script's own pty through clt, the same "on a terminal" with no human (4.19).
#   - 2.20: the docker capability lives in the isolated global config between 2.20a and 2.20d. A
#     step after 2.20d that finds it still on (2.20d skipped or cut) turns it off first, since
#     every caged launch would refuse otherwise. 2.20b and 2.20c turn it on again when a resume
#     finds it off.
#
# Helpers (p31_): p31_is_int, p31_cd, p31_smoke_load, p31_fork_load, p31_vfile, p31_kvf,
# p31_launch, p31_t1_free, p31_exit, p31_need_live, p31_need_up, p31_need_idle, p31_ed_begin,
# p31_ed_quit, p31_docker_on, p31_docker_off, p31_docker_need, p31_drop_pack, p31_box_file_drop,
# p31_restore_strict, p31_pin_restore, p31_add_allow, p31_maxwidth, p31_first_after,
# p31_rawseq, p31_stty_part, p31_box_live_check, plus pipelines run only through run_cmd or val:
# p31_relay_last_pid, p31_relay_after_exit, p31_exited_count, p31_again_count, p31_log_counts,
# p31_shim_sum, p31_kill9_relay, p31_curl_proxy, p31_gw_rc, p31_dig, p31_storm, p31_traffic,
# p31_denied_count, p31_names_count, p31_ls_paths, p31_py23, p31_pin_grep, p31_cfg_has,
# p31_policy_bytes_match, p31_pyerr, p31_box_kill, p31_npm_owner, p31_npm_tmpcache and p31_npm_cache_diag (a
# step helper, not a pipeline).

# ---------------------------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------------------------

p31_is_int() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac; return 0; }
# A line that ends in a bare x.y.z version (npm view's answer), after at most a spinner glyph.
p31_semver_ere() { printf '%s' '(^|[^[:alnum:]@. ])[0-9]+\.[0-9]+\.[0-9]+[[:space:]]*$'; }

# p31_cd PROJ [make]: into $P/PROJ. make: mkdir -p first. A dry run makes it inside its own home.
p31_cd() {
  local d="$P/$1"
  if [ "${2:-}" = make ] || [ "${DRY:-0}" = 1 ]; then mkdir -p "$d" || fatal "cannot create $d"; fi
  [ -d "$d" ] || step_abort "no project $d: run the step that makes it first"
  cd "$d" || step_abort "cannot cd to $d"
}

# p31_smoke_load: eg-smoke's box, socket volume, gateway and box hash, from Docker now, into
# SM_CN SM_VOL SM_GW SM_BH and kv. Aborts when there is no box (sitting 1 did not run). An empty
# value never overwrites kv: 2.21b reads the gateway's name after off removed it.
p31_smoke_load() {
  SM_CN=""; SM_VOL=""; SM_GW=""; SM_BH=""
  val SM_CN -t 60 -- cn eg-smoke
  val SM_VOL -t 60 -- vol eg-smoke
  val SM_GW -t 60 -- gw eg-smoke
  SM_BH="${SM_GW#cleat-gw-}"
  if [ "${DRY:-0}" != 1 ] && [ -z "$SM_CN" ]; then
    step_abort "no eg-smoke box: run sitting 1 (--only 1.2b) first"
  fi
  [ -n "$SM_CN" ] && kv_set eg-smoke.cn "$SM_CN"
  [ -n "$SM_VOL" ] && kv_set eg-smoke.vol "$SM_VOL"
  [ -n "$SM_GW" ] && kv_set eg-smoke.gw "$SM_GW"
  [ -n "$SM_GW" ] && kv_set eg-smoke.bh "$SM_BH"
  return 0
}

# p31_fork_load: eg-fork's box and gateway, into FK_CN FK_GW (empty when no box).
p31_fork_load() {
  FK_CN=""; FK_GW=""
  val FK_CN -t 60 -- cn eg-fork
  val FK_GW -t 60 -- gw eg-fork
  return 0
}

# p31_vfile VALUE: VALUE into a file of the step dir, its path in P31_VF, for a check that reads a
# file. Never a process substitution: a check tests [ -f ] and reads its file twice.
p31_vfile() {
  P31_VN=$(( ${P31_VN:-0} + 1 ))
  P31_VF="${STEP_DIR:-$RUN}/p31-value-$P31_VN.txt"
  printf '%s\n' "$1" > "$P31_VF"
}

# p31_kvf "a=1 b=2" KEY: the value of KEY in a one-line summary (none when absent).
p31_kvf() {
  local w
  for w in $1; do
    case "$w" in "$2="*) printf '%s' "${w#*=}"; return 0 ;; esac
  done
  printf 'none'
}

# p31_t1_free: T1 holds no Claude session from an earlier step (a resume after a break). A session
# still open in the project T1 last ran in is ended first, so nothing is typed into Claude Code.
p31_t1_free() {
  local prev
  [ "${DRY:-0}" = 1 ] && return 0
  prev=$(kv_get t1.proj "")
  [ -n "$prev" ] || return 0
  [ -d "$P/$prev" ] || return 0
  if run_cmd -q -t 90 -- box_claude_live "$prev"; then
    check_note "T1 still holds a Claude session in $prev: it ends first"
    p31_exit "$prev" "free-$prev"
  fi
  return 0
}

# p31_launch [--answer TAG=ANS]... PROJ CMD TAG [SPEC...]: [T1 launch CMD in PROJ] (DESIGN 6.2
# notation). The --answer options go to T1's answerer (a recreate prompt a launch must say y to).
# rc: t_wait_launch's.
p31_launch() {
  local proj cmd tag r
  local ans=()
  while [ "${1:-}" = --answer ]; do ans[${#ans[@]}]="--answer"; ans[${#ans[@]}]="$2"; shift 2; done
  proj="$1"; cmd="$2"; tag="$3"
  shift 3
  t_ensure t1
  p31_t1_free
  t_run t1 "$proj" "$cmd" ${ans[@]+"${ans[@]}"}
  t_wait_launch t1 "$proj" 600
  r=$?
  case "$r" in
    0) check_pass "Claude Code opened in T1 ($cmd in $proj)" ;;
    1) check_fail "Claude Code opened in T1 ($cmd in $proj)" "a live Claude Code session" "the command ended without Claude Code" ;;
    2) check_skip "Claude Code opened in T1 ($cmd in $proj)" "skipped at the wait"; return 2 ;;
    *) check_fail "Claude Code opened in T1 within 600 s ($cmd in $proj)" "a live Claude Code session" "timed out" ;;
  esac
  if [ $# -gt 0 ]; then
    local s pos=0
    for s in "$@"; do case "$s" in +*|~*) pos=1 ;; esac; done
    # rd-2b: "never printed" checks alone pass on an empty or wrong capture (2.17d's W5 check is
    # one). The summary's Egress row anchors them: every launch these steps make is caged.
    [ "$pos" = 1 ] || set -- "+Egress:" "$@"
    if t_capture t1 "$tag"; then t_region launch; fi
    t_checks_or_ask "$tag" "$@"
  fi
  return "$r"
}

# p31_exit PROJ TAG [SPEC...]: [T1 exit PROJ], then the session-end region against the specs.
# rc 0 after a session ended, 1 when none was open, else t_wait_exit's.
p31_exit() {
  local proj="$1" tag="$2" live=1 r
  shift 2
  run_cmd -q -t 90 -- box_claude_live "$proj" || live=0
  t_wait_exit t1 "$proj" 600
  r=$?
  if [ "$live" = 0 ]; then
    check_note "T1: no Claude session was open in $proj"
    return 1
  fi
  [ $# -gt 0 ] || return "$r"
  if t_capture t1 "$tag"; then
    t_region end
    if [ "${DRY:-0}" != 1 ] && [ ! -s "$OUT" ]; then
      if t_is_auto; then
        check_skip "the session-end report in T1" "T1 simulated: the session ended with Ctrl-C, so no session-end report"
      else
        check_fail "T1 printed the session-end line" "Session ended. Resume with: cleat resume" "not in T1's text"   # bin/cleat:20274
      fi
      return "$r"
    fi
  fi
  t_checks_or_ask "$tag" "$@"
  return "$r"
}

# p31_need_live PROJ TAG: Claude Code live in PROJ, resumed in T1 when it is not.
p31_need_live() {
  if run_cmd -q -t 90 -- box_claude_live "$1"; then return 0; fi
  check_note "Claude Code is not open in $1: T1 resumes it first"
  p31_launch "$1" "cleat resume" "$2"
}
# p31_need_up PROJ TAG: the box runs, with or without Claude. A box found stopped is resumed first.
p31_need_up() {
  if run_cmd -q -t 60 -- box_running "$1"; then return 0; fi
  check_note "the $1 box is not running (a break since the step before): T1 resumes it first"
  p31_launch "$1" "cleat resume" "$2"
}
# p31_need_idle PROJ TAG: the box runs with no Claude session (2.17's start state): a stopped box
# is resumed in T1 and the session ended, an open session is ended. Never cleat run here.
p31_need_idle() {
  if run_cmd -q -t 60 -- box_running "$1"; then
    if run_cmd -q -t 90 -- box_claude_live "$1"; then p31_exit "$1" "idle-$2"; fi
    return 0
  fi
  check_note "the $1 box is not running (a break since the step before): T1 resumes it, then /exit"
  p31_launch "$1" "cleat resume" "$2"
  p31_exit "$1" "idle-$2"
  return 0
}
# p31_box_live_check PROJ STARTED: Claude still live in PROJ and the box's StartedAt still STARTED
# (read at the top of the step, so a resume earlier in the run never reads as a restart).
p31_box_live_check() {
  local proj="$1" want="$2" bs
  if run_cmd -q -t 90 -- box_claude_live "$proj"; then
    check_pass "T1's Claude session in $proj never dropped"
  else
    check_fail "T1's Claude session in $proj never dropped" "Claude Code still live" "no Claude process in the box"
  fi
  val bs -t 60 -- box_started "$proj"
  expect_eq "the box never restarted (StartedAt as at the top of the step)" "$bs" "$want"
}

# ---- the docker capability of the isolated global config (2.20) ----
# p31_docker_on: rc 0 when [caps] of $CFG/config holds docker.
p31_docker_on() {
  [ -f "$CFG/config" ] || return 1
  LC_ALL=C awk '
    { l = $0; sub(/\r$/, "", l); gsub(/^[ \t]+|[ \t]+$/, "", l) }
    l ~ /^\[.*\]$/ { in_caps = (l == "[caps]"); next }
    in_caps && l == "docker" { f = 1 }
    END { exit (f ? 0 : 1) }' "$CFG/config"
}
# p31_docker_off: the docker capability off before a caged launch (a skipped or cut 2.20d).
p31_docker_off() {
  [ "${DRY:-0}" = 1 ] && return 0
  p31_docker_on || return 0
  check_note "the docker capability is still on in the run's global config (2.20d did not finish): cleat config --disable docker first"
  cl -- config --disable docker
  return 0
}
# p31_docker_need: 2.20b and 2.20c need it on. A resume that finds it off turns it on again.
p31_docker_need() {
  [ "${DRY:-0}" = 1 ] && return 0
  p31_docker_on && return 0
  check_note "the docker capability is off (an earlier attempt or 2.20d ran): cleat config --enable docker first, as 2.20a does"
  cl -- config --enable docker
  return 0
}
# p31_docker_cleanup: 2.20a's cleanup. Only a 2.20a that did not reach its end turns docker off:
# 2.20b and 2.20c need it on.
p31_docker_cleanup() {
  [ "$(kv_get step20a.done 0)" = 1 ] && return 0
  p31_docker_on || return 0
  ( cd "$P/eg-lock" 2>/dev/null && cl -q -- config --disable docker ) || true
  return 0
}

# p31_cfg_has ERE: a line of the run's global config matches ERE.
p31_cfg_has() { [ -f "$CFG/config" ] && LC_ALL=C grep -q -E -e "$1" "$CFG/config"; }
# p31_drop_pack PACK: a cleanup. cleat egress deny PACK, only while the global policy lists it:
# a deny of a pack the file does not list denies every host of it instead (bin/cleat:14226-14236).
p31_drop_pack() {
  p31_cfg_has "^[[:space:]]*pack[[:space:]]*=[[:space:]]*$1[[:space:]]*\$" || return 0
  ( cd "$P/eg-smoke" 2>/dev/null && cl -q -- egress deny "$1" ) || true
  return 0
}
# p31_box_file_drop: a cleanup. eg-smoke's own egress file goes (cleat egress main --inherit --yes)
# when a cut 2.21e left it.
p31_box_file_drop() {
  local c
  c=$(kv_get eg-smoke.cn "")
  [ -n "$c" ] && [ -f "$CFG/egress-boxes/$c" ] || return 0
  ( cd "$P/eg-smoke" 2>/dev/null && cl -q -- egress main --inherit --yes ) || true
  return 0
}
# p31_restore_strict: if 2.21d left the global mode open, set it back to strict by hand.
p31_restore_strict() {
  if [ -f "$CFG/config" ] && LC_ALL=C grep -q -E '^[[:space:]]*mode[[:space:]]*=[[:space:]]*open[[:space:]]*$' "$CFG/config"; then
    file_edit "$CFG/config" 's/^\([[:space:]]*mode[[:space:]]*=[[:space:]]*\)open[[:space:]]*$/\1strict/'
  fi
  return 0
}
# p31_pin_restore: restore the pin backup while the live pin still reads rev 0 (2.22 cut short).
p31_pin_restore() {
  local bak="$SCRATCH/mt-pin.bak"
  if [ -f "$bak" ] && [ -f "$CFG/egress-pins/global" ] && LC_ALL=C grep -q '^catalogue_rev = 0$' "$CFG/egress-pins/global"; then
    cat "$bak" > "$CFG/egress-pins/global" 2>/dev/null || true
  fi
  return 0
}
# p31_add_allow FILE LINE: LINE right under the [egress] header, the bytes a hand edit adds (awk,
# the same inode, as file_edit keeps it).
p31_add_allow() {
  local f="$1" t
  t="${f%/*}/.mt-edit.$$"
  if LC_ALL=C awk -v add="$2" '{ print } !d && $0 == "[egress]" { print add; d = 1 }' "$f" > "$t"; then
    cat "$t" > "$f"
  fi
  rm -f "$t"
}

# p31_maxwidth [FILE]: the widest line in FILE (or $OUT) in columns, UTF-8 continuation bytes dropped.
p31_maxwidth() {
  local f="${1:-$OUT}"
  [ -f "$f" ] || { printf '0'; return 0; }
  LC_ALL=C tr -d '\200-\277' < "$f" 2>/dev/null | awk '{ if (length($0) > m) m = length($0) } END { print m + 0 }'
}
# p31_first_after FILE TEXT: the first non-blank line after the first line holding TEXT.
p31_first_after() {
  MT_T="$2" LC_ALL=C awk 'BEGIN { t = ENVIRON["MT_T"] } on && NF { print; exit } index($0, t) { on = 1 }' "$1"
}
# p31_stty_part FILE: the stty -a block the --wrap-stty wrapper printed after the TUI.
p31_stty_part() { awk '/speed [0-9]+ baud/ { on = 1 } on { print } /__MT_TTY_END__/ { exit }' "$1"; }
# p31_rawseq RAW: which cursor sequence came last (h shown, l hidden).
p31_rawseq() {
  LC_ALL=C awk 'BEGIN { RS = "\033" } NR > 1 {
      if (substr($0, 1, 5) == "[?25h") last = "h"
      else if (substr($0, 1, 5) == "[?25l") last = "l"
    }
    END { printf "last25=%s\n", (last == "" ? "none" : last) }' "$1"
}

# ---- the editor's program pieces (2.15h, 2.21d, 2.21e) ----
# p31_ed_begin: a new program that waits for the editor's first frame (it ends with ESC [ J).
p31_ed_begin() {
  xp_new
  xp_wait open 'Cleat egress' 120
  xp_wait f0 '\x1b\[J' 30
}
# p31_ed_quit: Esc on the list cancels after a second: Nothing saved, then the end.
p31_ed_quit() { xp_send "<esc>"; xp_wait nothing 'Nothing saved' 20; xp_eof 30; }

# ---- pipelines, run only through run_cmd or val ----
# The last relay pid in the box's shim log (the one 2.16a kills).
p31_relay_last_pid() { bx "$1" sed -n 's/.*relay started pid=//p' /tmp/cleat-egress-shim.log | tail -n 1; }
# FILE: the pid of the first "relay started" after the last "relay exited rc=143" (empty: none).
p31_relay_after_exit() {
  LC_ALL=C awk '/relay exited rc=143/ { seen = 1; pid = ""; next }
    seen && pid == "" && /relay started pid=/ { p = $0; sub(/.*relay started pid=/, "", p); sub(/[^0-9].*$/, "", p); pid = p }
    END { print pid }' "$1"
}
p31_exited_count() { bx "$1" grep -c 'relay exited' /tmp/cleat-egress-shim.log; }
p31_again_count()  { bx "$1" grep -c 'supervisor started again in place' /tmp/cleat-egress-shim.log; }
# PROJ: bash's fork retry and give-up lines, the supervisor restarts and the relay starts, over
# the whole relay log, on one line. Read when the hold is over.
p31_log_counts() {
  bx "$1" cat /tmp/cleat-egress-shim.log | LC_ALL=C awk '
    /fork: retry/ { r++; next }
    /fork: Resource temporarily unavailable/ { g++; next }
    /supervisor started again in place/ { a++; next }
    /relay started pid=/ { s++; p = $0; sub(/.*relay started pid=/, "", p); sub(/[^0-9].*$/, "", p); last = p }
    END { printf "retry=%d giveup=%d again=%d started=%d lastrelay=%s\n", r + 0, g + 0, a + 0, s + 0, (last == "" ? "none" : last) }'
}
# A one-line summary of the relay processes: sup (plain supervisors), again (--again supervisors),
# beats (heartbeat loops), socat (listener and tunnels), relay (the pid the --beats loop watches),
# suppid (the supervisor, plain or --again), beatspid (the heartbeat loop). A pipeline of a shell
# is a fork with the same command line for an instant, so the oldest (lowest) pid of each kind is
# the one named.
p31_shim_sum() {
  shimpids "$1" | LC_ALL=C awk '
    / --beats / { beats++; if (bp == "" || $1 + 0 < bp + 0) { bp = $1; s = $0; sub(/.* --beats /, "", s); split(s, a, " "); relay = a[1] }; next }
    / --beat $/ || / --beat$/ { next }
    /\/usr\/local\/bin\/cleat-egress-shim --again/ { again++; if (sp == "" || $1 + 0 < sp + 0) sp = $1; next }
    /\/usr\/local\/bin\/cleat-egress-shim/ { sup++; if (sp == "" || $1 + 0 < sp + 0) sp = $1; next }
    /socat -T 900/ { socat++ }
    END { printf "sup=%d again=%d beats=%d socat=%d relay=%s suppid=%s beatspid=%s\n", sup + 0, again + 0, beats + 0, socat + 0, (relay == "" ? "none" : relay), (sp == "" ? "none" : sp), (bp == "" ? "none" : bp) }'
}
# Every relay process killed in ONE exec, as the scenario's kill -9 $(shimpids ...) does: one at a
# time, the supervisor could start a new relay between two of them.
p31_kill9_relay() {
  local pids
  pids=$(shimpids "$1" | awk '{ print $1 }' | tr '\n' ' ')
  [ -n "${pids// /}" ] || { echo "no relay process to kill"; return 1; }
  echo "kill -9 $pids"
  # shellcheck disable=SC2086
  p31_box_kill "$1" -9 $pids
}
# p31_box_kill PROJ [KILL ARGS...]: kill run by a shell in the box, as root. The box image has no
# kill binary (rd-2b: docker exec ... kill is "executable file not found", rc 127), so the
# scenario's bxr eg-smoke kill PID never reaches the process. The shell's builtin does.
p31_box_kill() {
  local proj="$1"
  shift
  bxr "$proj" sh -c 'kill "$@"' sh "$@"
}
# curl from inside the box straight at the relay socket (2.16b): the code and the error.
p31_curl_proxy() { bx "$1" curl -sS -o /dev/null -w '%{http_code}\n' --max-time "${3:-10}" -x http://127.0.0.1:3128 "$2"; }
# The gateway's State.Status and RestartCount on one line, read with docker inspect.
p31_gw_rc() { docker inspect -f '{{.State.Status}} {{.RestartCount}}' "$1"; }
# dig +short of two sslip names, or an alpine nslookup fallback when dig is missing.
p31_dig() {
  if command -v dig > /dev/null 2>&1; then
    dig +short "$1" "$2"
  else
    echo "dig is missing: alpine nslookup instead"
    docker run --rm alpine nslookup "$1" 2>/dev/null
    docker run --rm alpine nslookup "$2" 2>/dev/null
  fi
  return 0
}
# 2.19's storm, verbatim: seq 400 parallel CONNECTs through the relay, from inside the box, as its user.
p31_storm() {
  bx "$1" bash -c 'seq 400 | xargs -P 400 -I{} curl -s -o /dev/null -w "%{http_code}\n" --max-time 30 -x http://127.0.0.1:3128 https://example.org/ | sort | uniq -c'
}
# 2.18b's background traffic, verbatim: one connection a second into the relay, no fork, as the box user.
p31_traffic() {
  docker exec -d -u coder "$(cn "$1")" python3 -c 'import socket,time
while True:
    try: socket.create_connection(("127.0.0.1",3128),timeout=2).close()
    except Exception: pass
    time.sleep(1)'
}
# The gateway's counters now (gw-admin counts prints "ok counts <allowed> <denied>").
p31_denied_count() { gwadm "$1" counts; }
p31_names_count() { docker ps -a --format '{{.Names}}' | LC_ALL=C grep -E -e "$1" | awk 'END { print NR + 0 }'; }
p31_ls_paths() { ls "$@" 2>&1; return 0; }
# 2.23's Python CONNECT-then-handshake check, read with a heredoc on stdin.
p31_py23() { docker exec -i -u coder "$1" python3 -; }
p31_pin_grep() { LC_ALL=C grep "$1" "$2"; }
# p31_policy_bytes_match GW FILE: docker cp the gateway's policy out as tar, extract, cmp to FILE.
p31_policy_bytes_match() {
  if docker cp "$1":/etc/cleat-egress/policy.json - | tar -xOf - | cmp -s - "$2"; then
    echo "bytes match"
  else
    echo "bytes differ"
  fi
}
# p31_pyerr FILE: the last non-blank line of a Python traceback (the error itself).
p31_pyerr() { [ -f "$1" ] && awk 'NF { l = $0 } END { print l }' "$1"; }
# The box's npm cache directory: its owner, the box user's uid and whether that user can write it.
p31_npm_owner() { bx "$1" sh -c 'printf "owner=%s user=%s " "$(stat -c %u /home/coder/.npm 2>/dev/null || echo none)" "$(id -u)"; if [ -w /home/coder/.npm ]; then echo writable; else echo not-writable; fi'; }
# npm view through the relay with a cache the box user owns, then that cache removed.
p31_npm_tmpcache() { bx "$1" sh -c 'npm view left-pad version --cache /tmp/mt-npmc; r=$?; rm -rf /tmp/mt-npmc; exit $r'; }

# p31_npm_cache_diag: 2.15i's npm failed with EACCES on /home/coder/.npm, the old behaviour F2
# fixed. rd-2b measured why on 68f1153: the image's Claude Code install step (docker/Dockerfile,
# curl https://claude.ai/install.sh run as coder) runs npm, which makes ~/.npm owned by the build
# uid 1000. The entrypoint did not chown ~/.npm. ac6ee85's entrypoint does
# (docker/entrypoint.sh:94). The step FAILs on it (F2). This only adds the evidence, so the human
# does not chase the relay: the owner, then the same npm with a cache the box user owns, which
# goes through the relay.
p31_npm_cache_diag() {
  local own
  val own -t 60 -- p31_npm_owner eg-smoke
  record_value step15i.npm_cache "$own" "the box's ~/.npm: its owner, the box user's uid, writable or not"
  run_cmd -e -t 180 -- p31_npm_tmpcache eg-smoke
  expect_match "the same npm view through the relay with a cache the box user owns returns a version (the fault is the cache, not the relay)" "$(p31_semver_ere)" "$OUT"
  case "$own" in
    *not-writable*)
      # In-box paths written out in full: the report's redaction turns a ~/ path into ~/<path>.
      warn "F2 regressed: /home/coder/.npm is not the box user's ($own). ac6ee85's entrypoint chowns it to the host uid (docker/entrypoint.sh:94): is the cleat image this tree's (egimg)?" ;;
  esac
  return 0
}

# ---------------------------------------------------------------------------------------------
# 2.15-pre: a running caged box with a session
# ---------------------------------------------------------------------------------------------
st_2_15_pre() {
  local bs
  p31_cd eg-smoke
  p31_smoke_load
  p31_docker_off
  p31_need_live eg-smoke resume-2.15
  val bs -t 60 -- box_started eg-smoke
  record_value step15.box_started "$bs" "eg-smoke's StartedAt at the top of 2.15"
}

# ---------------------------------------------------------------------------------------------
# 2.15a Listing (EXTRA)
# ---------------------------------------------------------------------------------------------
st_2_15a() {
  p31_cd eg-smoke
  cl -- egress packs
  first_lines 3
  expect_contains "the packs header, both legs" "Egress packs (classes measured 2026-09-21, both protocol legs)"   # bin/cleat:14325
  clt -T 300 -- egress --list
  expect_match "the --list Mode line" '^  Mode: +(strict|open|off) '                                              # bin/cleat:14290-14294
  expect_contains "--list names the config file it is set by" "Set by:   ~/mt-egress-xdg/cleat/config [egress]"      # bin/cleat:14297,14312
  cl -- help
  grep_lines 'egress'
  expect_contains "help names the egress verb and its default-off note" "egress  [box]        Hosts a box may reach (off by default, no box = every box)"   # bin/cleat:36009
  cl -- egress status
  grep_lines 'Hosts:|Allowed:|Session:'
  expect_match "the Hosts row names example.com by name (W10)" '^  Hosts: +.*example\.com'                          # bin/cleat:14530
  expect_not_match "no row reads Pinned:" '^ *Pinned:'
}

# ---------------------------------------------------------------------------------------------
# 2.15b A reload never replaces the gateway
# ---------------------------------------------------------------------------------------------
st_2_15b() {
  local before after dig1 dig2 n bs0
  p31_cd eg-smoke
  p31_smoke_load
  p31_need_live eg-smoke resume-2.15b
  val bs0 -t 60 -- box_started eg-smoke
  # W10's Hosts row. The scenario reads it in 2.15 a, an EXTRA, yet 5.4 needs W10 confirmed and
  # 2.15 a is its only site for that row. A default run (gates only) never runs 2.15 a. Once 3.5
  # has removed eg-smoke it cannot. So the gate reads the same two rows, before the allow below
  # adds docs.rs to them. 2.15 a keeps its own reads for a run with --extras.
  cl -- egress status
  grep_lines 'Hosts:|Pinned:'
  record_value step15.hosts_row "$(LC_ALL=C grep -E -m 1 '^  Hosts:' "$OUT" 2>/dev/null | sed 's/^ *//')" "cleat egress status's Hosts row before the allow (W10)"
  expect_match "the Hosts row names example.com by name (W10, the 2.15 a read)" '^  Hosts: +.*example\.com'        # bin/cleat:14530
  expect_not_match "no row reads Pinned: (W10, the 2.15 a read)" '^ *Pinned:'
  val before -t 60 -- docker inspect -f '{{.Id}} {{.RestartCount}}' "$SM_GW"
  printf '%s\n' "$before" > "$SCRATCH/mt-gw-before.txt"
  record_value step15b.gw_before "$before" "the gateway Id and RestartCount before the reload"
  clt -T 300 -- egress allow docs.rs
  expect_match "allow docs.rs ends: its gateway reloaded" 'Applied to cleat-eg-smoke-[0-9a-f]{8}: its gateway reloaded\.'   # bin/cleat:13129
  clt -T 300 -- egress test docs.rs
  expect_contains "test docs.rs: v allow" "v allow   docs.rs:443"                 # bin/cleat:14003
  expect_contains "test docs.rs: via a host you allowed" "via a host you allowed"  # bin/cleat:14014
  run_cmd -e -t 60 -- bget eg-smoke https://docs.rs/
  expect_line "docs.rs answers 200 now" "200"
  val after -t 60 -- docker inspect -f '{{.Id}} {{.RestartCount}}' "$SM_GW"
  if [ "${DRY:-0}" = 1 ]; then check_pass "same gateway, no restart (dry)"
  elif [ -n "$after" ] && [ "$after" = "$before" ]; then check_pass "same gateway, no restart" "$after"
  else check_fail "a reload never replaces the gateway" "$before" "$after"; fi
  record_value step15b.same "$after" "the gateway Id and RestartCount after (equal means no restart)"
  val dig1 -t 60 -- gwadm eg-smoke policy-digest
  run_cmd -t 60 -- p31_pin_grep '"digest"' "$CFG/egress-rendered/$SM_BH/policy.json"
  dig2=$(LC_ALL=C sed -n 's/.*"digest": *"\([^"]*\)".*/\1/p' "$OUT" 2>/dev/null | head -n 1)
  dig1="${dig1#ok policy-digest }"
  record_value step15b.digest "$dig1 vs $dig2" "the gateway digest and the rendered digest"
  if [ "${DRY:-0}" = 1 ]; then check_pass "the digests match (dry)"
  else
    p31_vfile "$dig1"
    expect_match "the gateway digest is v1:<16 hex>" '^v1:[0-9a-f]{16}$' "$P31_VF"
    expect_eq "the gateway digest equals the rendered policy's" "$dig1" "$dig2"
  fi
  val n -t 60 -- bx eg-smoke grep -c docs.rs /home/coder/.claude/CLAUDE.md
  expect_num "the in-box network fragment names docs.rs (no restart)" "${n:-0}" eq 1
  p31_box_live_check eg-smoke "$bs0"
}

# ---------------------------------------------------------------------------------------------
# 2.15c A hand edit, then reload (EXTRA)
# ---------------------------------------------------------------------------------------------
st_2_15c() {
  local pre=0
  p31_cd eg-smoke
  p31_smoke_load
  # A hand edit adds allow = crates.io under [egress], the same bytes a person would type.
  if p31_cfg_has '^[[:space:]]*allow[[:space:]]*=[[:space:]]*crates\.io[[:space:]]*$'; then
    pre=1
    check_note "allow = crates.io is already in the config (an earlier attempt)"
  elif [ "${DRY:-0}" != 1 ]; then
    [ -f "$CFG/config" ] || step_abort "no $CFG/config: sitting 1 writes it"
    p31_add_allow "$CFG/config" "allow = crates.io"
    p31_cfg_has '^allow = crates\.io$' || step_abort "the hand edit did not land in $CFG/config"
    check_note "added allow = crates.io under [egress] by hand (awk, the same bytes)"
  fi
  kv_set crates.added 1
  cl -- egress status
  grep_lines 'Mode:'
  if [ "$pre" = 1 ] && LC_ALL=C grep -q 'live, read from the gateway' "$OUT" 2>/dev/null; then
    check_note "the gateway already enforces the hand edit (an earlier attempt reloaded it): the differ checks are skipped"
  else
    expect_contains "the saved policy differs from the gateway's" "saved. The gateway enforces a different policy: cleat egress reload" "$OUT"   # bin/cleat:14502
    clt -T 300 -- egress test crates.io
    expect_contains "test crates.io: the saved policy says allow" "! The saved policy says allow. The gateway enforces a different policy:  cleat egress reload" "$OUT"   # bin/cleat:14027
  fi
  clt -T 300 -- egress reload
  expect_match "reload: box main reloaded, now enforces strict" 'Box main reloaded: its gateway now enforces strict, [0-9]+ hosts\.'   # bin/cleat:13097
  cl -- egress status
  grep_lines 'Mode:'
  expect_contains "Mode now live, read from the gateway" "live, read from the gateway"   # bin/cleat:14500
}

# ---------------------------------------------------------------------------------------------
# 2.15d The policy bind on macOS
# ---------------------------------------------------------------------------------------------
st_2_15d() {
  local dirm filem own uid gid err
  p31_cd eg-smoke
  p31_smoke_load
  # docker cp to stdout is tar: extract its one file and cmp it to the rendered bytes.
  run_cmd -t 120 -- p31_policy_bytes_match "$SM_GW" "$CFG/egress-rendered/$SM_BH/policy.json"
  expect_contains "the gateway's bound policy equals the rendered bytes" "bytes match"
  if [ "${DRY:-0}" != 1 ]; then
    dirm=$(file_mode "$CFG/egress-rendered/$SM_BH" 2>/dev/null)
    filem=$(file_mode "$CFG/egress-rendered/$SM_BH/policy.json" 2>/dev/null)
    expect_eq "the rendered policy dir is 755" "$dirm" "755"
    expect_eq "policy.json is 644" "$filem" "644"
  else
    check_pass "the rendered policy dir is 755 and policy.json is 644 (dry)"
  fi
  val own -t 60 -- docker exec "$SM_GW" python3 -c "import os; s=os.stat('/etc/cleat-egress/policy.json'); print(s.st_uid, oct(s.st_mode))"
  record_value step15d.owner "$own" "the owner and mode as the gateway sees policy.json"
  run_cmd -e -t 60 -- docker exec "$SM_GW" python3 -c "open('/etc/cleat-egress/policy.json','a')"
  record_value step15d.open_root "$(p31_pyerr "$ERR") (rc $RC)" "root's open of the bound policy (the error line)"
  uid=$(id -u); gid=$(id -g)
  run_cmd -e -t 60 -- docker exec -u "$uid:$gid" "$SM_GW" python3 -c "open('/etc/cleat-egress/policy.json','a')"
  record_value step15d.open_uid "$(p31_pyerr "$ERR") (rc $RC)" "the open as uid $uid (the error line)"
  # Whichever exec is the file's owner must fail read-only. The owner line tells which.
  if [ "${DRY:-0}" = 1 ]; then
    check_pass "the owner's open hits a read-only file system (dry)"
  else
    case "$own" in
      "0 "*) err=$(kv_get step15d.open_root "") ;;
      *) err=$(kv_get step15d.open_uid "") ;;
    esac
    case "$err" in
      *"[Errno 30] Read-only file system"*) check_pass "the owner's open hits a read-only file system" "$err" ;;   # the gateway binds the policy read-only
      *) check_fail "the owner's open hits a read-only file system" "[Errno 30] Read-only file system" "${err:-no error line} (owner line: $own)" ;;
    esac
  fi
  printf 'x\n' > "$SCRATCH/mt-x"
  on_cleanup "safe_rm $(printf '%q' "$SCRATCH/mt-x")"
  dk -e -t 60 -- cp "$SCRATCH/mt-x" "$SM_GW":/etc/cleat-egress/policy.json
  expect_rc "the daemon refuses the docker cp into the read-only bind" '!0'
  record_value step15d.cp "$(awk 'NF { print; exit }' "$ERR" 2>/dev/null) (rc $RC)" "the docker cp error"
  safe_rm "$SCRATCH/mt-x"
}

# ---------------------------------------------------------------------------------------------
# 2.15e .Source on a symlinked path (EXTRA)
# ---------------------------------------------------------------------------------------------
st_2_15e() {
  local src resolved
  # The real Docker validation runs from inside a Linux box on the maintainer's Docker Desktop. Its
  # /tmp is not the Mac's, and that walk never bind-mounts /tmp (DESIGN section 9, rd-2b). The Mac
  # run never sets MT_SIM_HOST, so this never fires there.
  if [ "${DRY:-0}" != 1 ] && mt__host_sim; then
    step_skip "validation run (MT_SIM_HOST): no /tmp bind mount from inside a box. rd-2b ran the same commands on a symlinked path by hand"
  fi
  on_cleanup "egv_rm egv-src"
  egv_rm egv-src
  egv_create egv-src -v /tmp:/x alpine true
  dk -- inspect -f '{{range .Mounts}}{{.Source}}{{end}}' egv-src
  src=$(head -n 1 "$OUT" 2>/dev/null)
  record_value step15e.source "$src" "docker inspect .Source of a /tmp bind"
  val resolved -t 30 -- sh -c 'cd -P /tmp && pwd'
  record_value step15e.resolved "$resolved" "the resolved physical path of /tmp (/private/tmp on a Mac)"
  check_pass "recorded .Source and the resolved /tmp path (this step records, it does not judge)"
  egv_rm egv-src
}

# ---------------------------------------------------------------------------------------------
# 2.15f The policy language (EXTRA)
# ---------------------------------------------------------------------------------------------
st_2_15f() {
  local c
  p31_cd eg-smoke
  p31_smoke_load
  printf '[egress]\nmode = off\n' > .cleat
  on_cleanup "rm -f $(printf '%q' "$P/eg-smoke/.cleat")"
  xshell eg-smoke --answer trust-caps=n
  expect_contains "the box session says the [egress] section is ignored" "! Section [egress] in .cleat is ignored (egress policy is global: cleat egress)"   # bin/cleat:5676
  cl -- egress status
  grep_lines 'Mode:'
  expect_match "the policy stays strict" '^  Mode: +strict'
  rm -f "$P/eg-smoke/.cleat"
  # The config inside a folder a box can write refuses to launch.
  p31_cd eg-contain make
  on_cleanup "safe_rm $(printf '%q' "$P/eg-contain")"
  clt --xdg "$P/eg-contain/.cfg" -T 300 -- egress allow example.com
  record_value step15f.allow "$(LC_ALL=C grep -m 1 'Saved to' "$OUT" 2>/dev/null)" "the allow into the contained config"
  clt --xdg "$P/eg-contain/.cfg" -T 600 -- run
  expect_rc "the contained-config run refuses, rc 1" 1
  expect_contains "the config is inside a folder a box can write" "✖ The Cleat config directory is inside a folder a box can write: ~/mt-egress/eg-contain"   # bin/cleat:9795
  val c -t 60 -- p31_names_count '^cleat-eg-contain-'
  expect_eq "no eg-contain container was created" "${c:-}" "0"
  if [ "${DRY:-0}" != 1 ] && [ "${c:-0}" != 0 ]; then
    check_note "a container was created after all: cleat rm removes it before the folder goes"
    clt --xdg "$P/eg-contain/.cfg" -T 300 -- rm
  fi
  cd "$P" 2>/dev/null || true
  safe_rm "$P/eg-contain"
}

# ---------------------------------------------------------------------------------------------
# 2.15g The widening notice
# ---------------------------------------------------------------------------------------------
st_2_15g() {
  local added n want
  p31_cd eg-smoke
  p31_smoke_load
  # What arrived since the box last launched, as status names it (bin/cleat:14551): b's
  # docs.rs, plus c's crates.io when the hand edit ran. Read now, so a resume counts what is there.
  cl -- egress status
  added=$(LC_ALL=C sed -n 's/^ *Added since this box last launched: *//p' "$OUT" 2>/dev/null | head -n 1)
  record_value step15g.added "${added:-none}" "the hosts added since eg-smoke last launched (status)"
  n=0
  if [ -n "$added" ]; then n=$(printf '%s\n' "$added" | awk -F', ' '{ print NF }'); fi
  if [ "${DRY:-0}" = 1 ]; then n=1; added=docs.rs; fi
  if [ "$n" = 1 ]; then want="+1 host added since the last launch.  cleat egress status"; else want="+$n hosts added since the last launch.  cleat egress status"; fi   # bin/cleat:12345
  if [ "${DRY:-0}" != 1 ] && [ -n "$added" ]; then
    case ", $added," in
      *", docs.rs,"*) check_pass "docs.rs (allowed in b) is among the hosts added since the launch" "$added" ;;
      *) check_fail "docs.rs (allowed in b) is among the hosts added since the launch" "docs.rs" "$added" ;;
    esac
    if [ "$(kv_get crates.added 0)" = 1 ]; then
      case ", $added," in *", crates.io,"*) : ;; *) check_note "crates.io is not among them: the hand edit of c predates the last launch" ;; esac
    fi
  fi
  p31_exit eg-smoke exit-2.15g-1
  if [ "$n" -gt 0 ] 2>/dev/null; then
    p31_launch eg-smoke "cleat resume" relaunch-2.15g "$want"
  else
    check_skip "the first resume prints the added line" "status names no host added since the last launch: a relaunch already ate the notice (re-entry)"
    p31_launch eg-smoke "cleat resume" relaunch-2.15g
  fi
  p31_exit eg-smoke exit-2.15g-2
  p31_launch eg-smoke "cleat resume" relaunch2-2.15g "-added since the last launch"
}

# ---------------------------------------------------------------------------------------------
# 2.15h Two terminals
# ---------------------------------------------------------------------------------------------
st_2_15h() {
  local hrc
  p31_cd eg-smoke
  p31_smoke_load
  # A save the refusal failed to stop would leave rust in the global policy: take it out again.
  on_cleanup "p31_drop_pack rust"
  p31_ed_begin
  # T3: x.example denied in another terminal while this editor is open, so the save refuses.
  xp_host "cd \"\$P/eg-smoke\" && cleat egress deny x.example"
  # Find a pack, rust, tick it, then save: the save meets the change from the other terminal.
  xp_send "<down>"; xp_wait fh '\x1b\[J' 20
  xp_send "<space>"; xp_wait findp 'Find a pack >' 20
  xp_send "rust"
  xp_wait typed 'Find a pack >(\x1b\[[0-9;]*m)* rust' 10
  xp_send "<enter>"; xp_wait ff '\x1b\[J' 20
  xp_sleep 200
  xp_snap found
  xp_send "<space>"; xp_wait ft '\x1b\[J' 20
  xp_sleep 200
  xp_snap ticked
  xp_send "<enter>"
  xp_wait saveq 'Save\? \[Y/n\]' 60
  xp_sleep 300
  xp_send "y<enter>"
  xp_wait changed 'policy changed in another terminal' 30
  xp_eof 30
  clt --prog -n h-editor -T 300 --answer eg-save-yn=manual -- egress
  hrc=$(xstatus host.1.rc)
  if [ "${DRY:-0}" != 1 ]; then
    expect_eq "T3's cleat egress deny x.example ran (rc 0)" "${hrc:-none}" "0"
  fi
  expect_contains "T3's deny saved" "Saved to "   # bin/cleat:14258
  expect_contains "the save sees the change and writes nothing" "✖ The policy changed in another terminal.  Nothing was written."   # bin/cleat:9716,9755
  expect_contains "it says to re-run" "Re-run to see the current policy."   # bin/cleat:9717,9756
  local o="$OUT"
  xsnap ticked
  expect_match "rust was ticked in the editor before the save" '▸ \[✔\] rust '   # bin/cleat:16144-16162
  OUT="$o"
  cl -- egress status
  grep_lines 'Packs:'
  expect_not_match "rust was not saved into the packs" '(^|[ ,])rust(,|$| )'
  check_note "the deny of x.example stays and is harmless (a deny never shows in --list)"
}

# ---------------------------------------------------------------------------------------------
# 2.15i Real tool traffic (EXTRA)
# ---------------------------------------------------------------------------------------------
st_2_15i() {
  local rc1 rc2 rc3 rc4
  p31_cd eg-smoke
  p31_smoke_load
  p31_need_up eg-smoke resume-2.15i
  # npm leaves the policy at the end of a cut step too, only while the policy lists it.
  on_cleanup "p31_drop_pack npm"
  clt -T 300 -- egress allow npm
  expect_match "allow npm saves the pack" '^ +pack npm$'   # bin/cleat:14222
  xshell eg-smoke -- \
    "git ls-remote https://github.com/cleatdev/cleat HEAD" \
    "npm view left-pad version" \
    "npm view left-pad version --registry https://registry.yarnpkg.com/" \
    "git ls-remote https://gitlab.com/gitlab-org/gitlab.git HEAD"
  rc1=$(xsh_rc 1); rc2=$(xsh_rc 2); rc3=$(xsh_rc 3); rc4=$(xsh_rc 4)
  xsh_out 1
  expect_match "git over the github pack: a sha and HEAD" '[0-9a-f]{40}[[:space:]]+HEAD' "$OUT"
  record_value step15i.git "$(awk 'NF { print; exit }' "$OUT" 2>/dev/null) (rc ${rc1:-none})" "git ls-remote through the github pack"
  xsh_out 2
  # On a terminal npm draws a spinner and erases it with ESC [1G ESC [0K, which the cleaner drops,
  # so the version can follow a spinner glyph on its line (rd-2b saw "\npm error ..."). The line
  # ends in the bare version: no letter, @, dot or space just before it (p31_semver_ere). Only the
  # EACCES check below carries (F2): an npm that fails for another reason is not F2's old behaviour.
  expect_match "npm view left-pad returns a version number" "$(p31_semver_ere)" "$OUT"
  record_value step15i.npm "$(awk 'NF { print; exit }' "$OUT" 2>/dev/null) (rc ${rc2:-none})" "npm view left-pad version"
  if [ "${DRY:-0}" = 1 ]; then
    expect_not_match "npm never fails EACCES on /home/coder/.npm (F2)" 'EACCES.*/home/coder/\.npm|/home/coder/\.npm.*EACCES'
  elif LC_ALL=C grep -q 'EACCES' "$OUT" 2>/dev/null && LC_ALL=C grep -q '/home/coder/\.npm' "$OUT" 2>/dev/null; then
    check_fail "npm never fails EACCES on /home/coder/.npm (F2)" "no EACCES on /home/coder/.npm: the entrypoint hands it to the box user" "$(LC_ALL=C grep -m 1 'EACCES' "$OUT" 2>/dev/null)"
    p31_npm_cache_diag
  elif [ -z "$rc2" ]; then
    # No end marker: npm never finished, so its silence is no reading of F2 (and no pass of it).
    check_note "npm did not finish in the box shell: no EACCES reading at 2.15i"
  else
    check_pass "npm never fails EACCES on /home/coder/.npm (F2)"
  fi
  xsh_out 3
  record_value step15i.yarn "$(LC_ALL=C grep -m 1 -i -E -e 'err|403|denied|cleat egress' "$OUT" 2>/dev/null) (rc ${rc3:-none})" "the yarn registry failure"
  if [ "${DRY:-0}" != 1 ]; then
    if p31_is_int "$rc3"; then expect_num "the yarn registry sub-tick is refused (nonzero)" "$rc3" ne 0
    else check_fail "the yarn registry sub-tick is refused (nonzero)" "a nonzero exit" "no result within 180 s"; fi
  fi
  xsh_out 4
  record_value step15i.gitlab "$(LC_ALL=C grep -m 1 -i -E -e '403|denied|cleat egress|fatal' "$OUT" 2>/dev/null) (rc ${rc4:-none})" "the gitlab failure"
  if [ "${DRY:-0}" != 1 ]; then
    if p31_is_int "$rc4"; then expect_num "gitlab over https is refused (nonzero)" "$rc4" ne 0
    else check_fail "gitlab over https is refused (nonzero)" "a nonzero exit" "no result within 180 s"; fi
  fi
  expect_contains "git reports a 403 from the proxy" "403" "$OUT"
  clt -T 300 -- egress deny npm
  expect_contains "deny npm takes the pack out" "pack npm removed"   # bin/cleat:14225
}

# ---------------------------------------------------------------------------------------------
# 2.16 The relay
# ---------------------------------------------------------------------------------------------
st_2_16a() {
  local rp sum0 sum1 sum2 bs np sp0
  p31_cd eg-smoke
  p31_smoke_load
  p31_need_live eg-smoke resume-2.16a
  val bs -t 60 -- box_started eg-smoke
  kv_set step16.box_started "$bs"
  val sum0 -t 60 -- p31_shim_sum eg-smoke
  if [ "${DRY:-0}" != 1 ] && { [ "$(p31_kvf "$sum0" sup)" != 1 ] || [ "$(p31_kvf "$sum0" beats)" != 1 ]; }; then
    # A heartbeat in flight shows a copy for an instant: read once more.
    sleep 2
    val sum0 -t 60 -- p31_shim_sum eg-smoke
  fi
  record_value step16a.shim_before "$sum0" "the relay processes before the kill"
  val rp -t 60 -- p31_relay_last_pid eg-smoke
  record_value step16a.relay_pid "$rp" "the relay pid to kill (the last relay started line)"
  sp0=$(p31_kvf "$sum0" suppid)
  if [ "${DRY:-0}" != 1 ]; then
    p31_is_int "$rp" || step_abort "no relay started line in eg-smoke's relay log: the relay never ran"
    expect_eq "one plain supervisor before the kill" "$(p31_kvf "$sum0" sup)" "1"
    expect_eq "one heartbeat loop before the kill" "$(p31_kvf "$sum0" beats)" "1"
    expect_eq "the heartbeat loop names the last relay started" "$(p31_kvf "$sum0" relay)" "$rp"
    expect_eq "no supervisor reads --again" "$(p31_kvf "$sum0" again)" "0"
  fi
  run_cmd -t 60 -- p31_box_kill eg-smoke "$rp"
  expect_rc "the relay got the TERM (the shell's kill in the box, rc 0)" 0
  [ "${DRY:-0}" = 1 ] || sleep 3
  run_cmd -t 60 -- shimlog eg-smoke 4
  expect_contains "the relay exited rc=143" "relay exited rc=143"   # docker/cleat-egress-shim:142
  np=$(p31_relay_after_exit "$OUT")
  record_value step16a.relay_new "${np:-none}" "the relay started after the exit"
  if [ "${DRY:-0}" != 1 ]; then
    if p31_is_int "$np" && [ "$np" != "$rp" ]; then check_pass "a new relay started after it" "pid $np"
    else check_fail "a new relay started after it" "relay started pid=<n> after the exit line" "${np:-none}"; fi
  fi
  run_cmd -e -t 60 -- bget eg-smoke https://example.com/
  expect_line "the healed relay answers 200" "200"
  val sum1 -t 60 -- p31_shim_sum eg-smoke
  record_value step16a.shim_after "$sum1" "the relay processes after the heal"
  if [ "${DRY:-0}" != 1 ]; then
    expect_eq "the same supervisor pid" "$(p31_kvf "$sum1" suppid)" "$sp0"
    expect_eq "its heartbeat loop names the new relay" "$(p31_kvf "$sum1" relay)" "${np:-none}"
    expect_eq "no supervisor reads --again" "$(p31_kvf "$sum1" again)" "0"
    if [ "$(p31_kvf "$sum1" beats)" = 1 ]; then
      check_pass "one heartbeat loop for the new relay" "$sum1"
    else
      check_note "$(p31_kvf "$sum1" beats) heartbeat loops: a heartbeat in flight can show a copy for an instant, so they are read again"
      sleep 3
      val sum2 -t 60 -- p31_shim_sum eg-smoke
      record_value step16a.shim_again "$sum2" "the relay processes a few seconds later"
      expect_eq "one heartbeat loop a few seconds later (two that stay are the failure)" "$(p31_kvf "$sum2" beats)" "1"
    fi
  fi
  cl -- egress status
  grep_lines 'Shim'
  expect_contains "status reads Shim listening" "● Shim listening"   # bin/cleat:14698
}

st_2_16b() {
  local pids i secs="" turned="" gwbad="" stamp rows t ka
  p31_cd eg-smoke
  p31_smoke_load
  p31_need_live eg-smoke resume-2.16b
  ka=$(epoch_now)
  kv_set step16.kill_at "$ka"
  val pids -t 60 -- shimpids eg-smoke
  record_value step16b.pids "$(printf '%s' "$pids" | awk '{ print $1 }' | tr '\n' ' ')" "the relay processes killed"
  record_value step16b.kill_at "$(date -u +%T) UTC" "the kill, as the scenario's date +%T"
  run_cmd -t 60 -- p31_kill9_relay eg-smoke
  expect_rc "kill -9 of every relay process ran (rc 0)" 0
  [ "${DRY:-0}" = 1 ] || sleep 1
  run_cmd -t 60 -- shimpids eg-smoke
  expect_eq "no relay process is left" "$(awk 'NF { n++ } END { print n + 0 }' "$OUT" 2>/dev/null)" "0"
  run_cmd -e -t 30 -- p31_curl_proxy eg-smoke https://example.com/ 10
  expect_line "the request gets 000" "000"
  expect_contains "curl cannot connect to the relay" "curl: (7) Failed to connect to 127.0.0.1 port 3128" "$ERR"
  if ! t_is_auto; then
    say_do T1 "Ask Claude Code anything now, while the script reads status for about two minutes.
It fails with its own network errors. Nothing in the session points at the fix (residual 22).
Do not type /exit yet: 2.16c ends the session and reads its report."
  fi
  i=1
  while [ "$i" -le 10 ]; do
    t=$(epoch_now); stamp=$(date -u +%T)
    cl -t 120 -- egress status
    grep_lines 'Gateway|Shim'
    rows=$(tr '\n' '|' < "$OUT" 2>/dev/null)
    record_value "step16b.read$i" "$stamp $rows" "read $i, $((t - ka)) s after the kill"
    if [ "${DRY:-0}" != 1 ] && ! LC_ALL=C grep -q '● Gateway healthy' "$OUT"; then gwbad="$gwbad $i"; fi
    if [ "${DRY:-0}" = 1 ] || LC_ALL=C grep -q -E -e '! Shim not listening +last seen [0-9]+[mhd]?[0-9]*[smh] ago, no heartbeat since' "$OUT"; then
      turned="$i"
      secs=$((t - ka))
      expect_match "the row reads last seen 1m<n>s ago, no heartbeat since" '! Shim not listening +last seen 1m[0-9]+s ago, no heartbeat since'   # bin/cleat:14707,14402
      break
    fi
    if [ "${DRY:-0}" != 1 ] && LC_ALL=C grep -q '● Shim listening' "$OUT" && [ $((t - ka)) -gt 150 ]; then
      check_fail "the silent failure: Shim listening more than 150 s after the kill while requests fail" "! Shim not listening" "Shim listening at $((t - ka)) s"
      break
    fi
    i=$((i + 1))
    if [ "$i" -le 10 ] && [ "${DRY:-0}" != 1 ]; then sleep 15; fi
  done
  if [ -n "$turned" ]; then
    record_value step16b.secs "$secs" "seconds from the kill to the turned row"
    expect_num "the row turned within 150 s of the kill (the silent failure bound)" "$secs" le 150
    # The scenario's one read after the turn (DESIGN section 8 item 5): the gateway row once more.
    if [ "${DRY:-0}" != 1 ]; then
      sleep 15
      cl -t 120 -- egress status
      grep_lines 'Gateway|Shim'
      record_value step16b.read_after "$(date -u +%T) $(tr '\n' '|' < "$OUT" 2>/dev/null)" "one read after the row turned"
      LC_ALL=C grep -q '● Gateway healthy' "$OUT" || gwbad="$gwbad after"
    fi
  else
    check_fail "the relay row turned within ten reads" "! Shim not listening    last seen 1m<n>s ago" "never in 10 reads"
  fi
  if [ -z "$gwbad" ]; then check_pass "the gateway read ● Gateway healthy in every read"; else check_fail "the gateway read ● Gateway healthy in every read" "● Gateway healthy" "not in read(s)$gwbad"; fi
  cl -- status
  grep_lines_after 'Egress:' 2
  expect_contains "cleat status names the shim under Egress" "! shim not listening (not a denial)  cleat egress restart --shim"   # bin/cleat:14631
  record_value step16b.status_line "$(LC_ALL=C grep -m 1 'shim not listening' "$OUT" 2>/dev/null)" "the cleat status line"
  if [ "${DRY:-0}" != 1 ]; then
    LC_ALL=C grep 'shim not listening' "$OUT" > "$OUT.shimline" 2>/dev/null
    expect_num "the cleat status shim line fits 80 columns" "$(p31_maxwidth "$OUT.shimline")" le 80
  fi
  ask_record claude-dead T1 "If you have not yet: ask Claude Code anything now in T1." "Did it fail with its own network errors, with nothing in the session pointing at the fix (residual 22)?"
}

st_2_16c() {
  local alive bs f
  p31_cd eg-smoke
  p31_smoke_load
  # Re-entry: a box that stopped since 2.16b starts a fresh relay. A relay that answers again
  # means 2.16b's dead state is gone too. Either way 2.16b runs again first.
  if [ "${DRY:-0}" != 1 ] && ! run_cmd -q -t 60 -- box_running eg-smoke; then
    step_abort "the eg-smoke box stopped since 2.16b, so its relay starts afresh: run --only 2.16b first, then 2.16c"
  fi
  run_cmd -q -t 60 -- shimpids eg-smoke
  alive=$(awk 'NF { n++ } END { print n + 0 }' "$OUT" 2>/dev/null)
  if [ "${DRY:-0}" != 1 ] && [ "${alive:-0}" -gt 0 ]; then
    step_abort "the relay is listening again: run --only 2.16b first, then 2.16c"
  fi
  # A session must end here for its report. After a break, T1 resumes one first (the gate prints
  # the advisory at that launch. The report repeats it at the end).
  p31_need_live eg-smoke resume-2.16c
  p31_exit eg-smoke end-2.16c \
    "+! Shim not listening  the in-box relay has not been heard from" \
    "+If requests fail, they fail before they reach the policy." \
    "+This is not a policy denial." \
    "+Fix:  cleat egress restart --shim"   # bin/cleat:11464-11467
  if [ "${DRY:-0}" != 1 ] && t_have_capture && [ -s "$OUT" ]; then
    f="$OUT"
    # The region starts at its anchor line (t_region end): Session ended, or Claude exited with code N.
    p31_vfile "$(LC_ALL=C awk 'NR > 1 && NF { print; exit }' "$f")"
    expect_contains "the session-end report opens with the relay advisory" "! Shim not listening" "$P31_VF"
    LC_ALL=C grep -F -e 'Shim not listening  the in-box relay' -e 'If requests fail, they fail before' -e 'This is not a policy denial.' -e 'Fix:  cleat egress restart --shim' "$f" > "$f.four" 2>/dev/null
    expect_num "the four advisory lines fit 80 columns" "$(p31_maxwidth "$f.four")" le 80
    record_value step16c.report "$(tr '\n' '|' < "$f" 2>/dev/null | cut -c1-400)" "the session-end report as printed"
  fi
  xshell eg-smoke
  expect_contains "cleat shell: the advisory before the shell" "! Shim not listening  the in-box relay has not been heard from" "$OUT"
  expect_contains "cleat shell: requests fail before the policy" "If requests fail, they fail before they reach the policy." "$OUT"
  expect_contains "cleat shell: not a policy denial" "This is not a policy denial." "$OUT"
  expect_contains "cleat shell: the fix is restart --shim" "Fix:  cleat egress restart --shim" "$OUT"
  if [ "${DRY:-0}" != 1 ]; then
    if xwaited shell-prompt; then check_pass "the shell opens anyway"; else check_fail "the shell opens anyway" "a box shell prompt" "no prompt"; fi
  fi
  clt -T 300 -- egress restart --shim
  expect_contains "the in-box relay answered" "✔ The in-box relay answered."   # bin/cleat:13327
  run_cmd -e -t 60 -- bget eg-smoke https://example.com/
  expect_line "the healed request: 200" "200"
  cl -- status
  grep_lines_after 'Egress:' 2
  expect_not_contains "cleat status: no shim line now" "shim not listening"
  val bs -t 60 -- box_started eg-smoke
  expect_eq "the box never restarted" "$bs" "$(kv_get step16.box_started "$bs")"
}

# ---------------------------------------------------------------------------------------------
# 2.17 More gateway failures
# ---------------------------------------------------------------------------------------------
st_2_17_pre() {
  p31_cd eg-smoke
  p31_smoke_load
  if run_cmd -q -t 90 -- box_claude_live eg-smoke; then
    p31_exit eg-smoke exit-2.17pre
  elif ! run_cmd -q -t 60 -- box_running eg-smoke; then
    # Never cleat run here: on a stopped box it removes the container.
    p31_launch eg-smoke "cleat resume" resume-2.17pre
    p31_exit eg-smoke exit-2.17pre
  else
    check_note "eg-smoke is already running with no session"
  fi
  if [ "${DRY:-0}" = 1 ]; then check_pass "eg-smoke runs with no session for 2.17 (dry)"; return 0; fi
  if run_cmd -q -t 60 -- box_running eg-smoke && ! run_cmd -q -t 90 -- box_claude_live eg-smoke; then
    check_pass "eg-smoke runs with no session for 2.17"
  else
    check_fail "eg-smoke runs with no session for 2.17" "running, no Claude" "not running or Claude still open"
  fi
}

st_2_17a() {
  local i line r0 n0 healthy=""
  p31_cd eg-smoke
  p31_smoke_load
  p31_need_idle eg-smoke resume-2.17a
  val r0 -t 30 -- p31_gw_rc "$SM_GW"
  n0="${r0##* }"
  p31_is_int "$n0" || n0=0
  gw_hardkill eg-smoke
  i=1
  while [ "$i" -le 8 ]; do
    val line -t 30 -- docker inspect -f '{{.State.Status}} health={{.State.Health.Status}} restarts={{.RestartCount}}' "$SM_GW"
    record_value "step17a.read$i" "$(date -u +%T) $line" "the gateway after the crash, read $i"
    case "$line" in *health=healthy*) [ -n "$healthy" ] || healthy="$i" ;; esac
    [ "${DRY:-0}" = 1 ] || sleep 1
    i=$((i + 1))
  done
  if [ "${DRY:-0}" != 1 ]; then
    p31_vfile "$line"
    expect_match "Docker restarted the gateway once (restarts $n0 + 1)" "restarts=$((n0 + 1))\$" "$P31_VF"
    if [ -n "$healthy" ]; then check_pass "healthy again within the 8 reads" "read $healthy"
    else check_fail "healthy again within the 8 reads" "health=healthy" "$line"; fi
  fi
  cl -- egress status
  grep_lines 'Gateway|Shim'
  if [ "${DRY:-0}" != 1 ] && LC_ALL=C grep -q 'never seen by this gateway' "$OUT"; then
    check_note "the relay row reads never seen by this gateway (expected for up to 30 s after a restart)"
  fi
  cl -- status
  grep_lines_after 'Egress:' 1
  expect_not_match "cleat status: the Egress row alone" '^[[:space:]]+(!|x) '
}

st_2_17b() {
  p31_cd eg-smoke
  p31_smoke_load
  p31_need_idle eg-smoke resume-2.17b
  gw_rm eg-smoke
  cl -- egress status
  grep_lines 'Gateway'
  expect_contains "status: the gateway is missing" "x Gateway missing       no gateway container for this box"   # bin/cleat:14685
  clt -T 300 -- egress restart
  expect_contains "egress restart heals it" "✔ Box main's gateway restarted and healthy."   # bin/cleat:13295
}

st_2_17c() {
  p31_cd eg-smoke
  p31_smoke_load
  p31_need_idle eg-smoke resume-2.17c-pre
  clt -T 300 -- stop
  gw_rm eg-smoke
  # A start that does not refuse launches Claude Code on this pty and holds it until the idle
  # timeout: 60 s is ample for a refusal, which prints at once.
  clt -t 60 -T 300 -- start
  # rd-2b: a stopped box whose recorded bind sources are not all present is recreated, not
  # started (bin/cleat:22766, "host paths changed"). The recreate makes a new gateway, so the
  # refusal under test never runs. Named, so a FAIL below says why.
  expect_not_contains "the stopped box was started in place, not recreated" "Recreating container (host paths changed)"   # bin/cleat:22786
  expect_rc "start on a box with no gateway refuses, rc 1" 1
  expect_contains "the refusal: its gateway is missing" "✖ Egress refused box main: its gateway is missing, so it has no egress at all."   # bin/cleat:11264
  expect_contains "the fix is cleat egress restart" "Fix:  cleat egress restart"
  expect_not_contains "the refusal comes before Claude Code starts" "Session ended. Resume with"
  clt -T 300 -- egress restart
  expect_contains "egress restart readies the gateway" "▸ Box main's gateway is ready. Start the box:  cleat start"   # bin/cleat:13298
  p31_launch eg-smoke "cleat start" start-2.17c
  p31_exit eg-smoke exit-2.17c
}

st_2_17d() {
  local pause t0 t1
  p31_cd eg-smoke
  p31_smoke_load
  p31_need_idle eg-smoke resume-2.17d-pre
  box_rawstop eg-smoke
  cl -- egress status
  first_lines 5
  expect_match "status: the gateway is orphaned" '! Gateway orphaned +running, but its box is not'   # bin/cleat:14680
  expect_contains "its fix names start or egress restart" "Fix:  cleat start      or   cleat egress restart"   # bin/cleat:14683
  # The relay's last heartbeat must be stale (more than 90 s old) before the resume (the
  # scenario's sleep 120). A bare sleep, so it is interruptible and the stub walk can shorten it.
  if [ "${DRY:-0}" != 1 ]; then
    say ">>> Waiting 120 s so the orphaned gateway's last heartbeat reads stale. Do not resume yet."
    sleep 120
  fi
  if ! t_is_auto; then say ">>> T1 resumes now. A pause of up to about 10 s before the summary is expected, not a hang."; fi
  t0=$(epoch_now)
  # W5 is the plain start against the orphaned gateway: a recreate (bin/cleat:22786) makes a new
  # gateway and proves nothing, so it is a FAIL here too (rd-2b).
  p31_launch eg-smoke "cleat resume" resume-2.17d "-Shim not listening" "-Recreating container (host paths changed)"
  t1=$(epoch_now)
  pause=$((t1 - t0))
  record_value step17d.pause "$pause" "seconds from the resume to Claude live (the gate may wait for the new relay)"
  [ "${DRY:-0}" = 1 ] || sleep 10
  cl -- egress status
  grep_lines 'Shim'
  if [ "${DRY:-0}" = 1 ]; then
    check_pass "status reads Shim listening after the resume (dry)"
  elif LC_ALL=C grep -q '● Shim listening' "$OUT"; then
    check_pass "status reads Shim listening after the resume (W5)"
  elif LC_ALL=C grep -q 'Shim not listening' "$OUT"; then
    run_cmd -t 60 -- shimlog eg-smoke 20
    record_value step17d.shimlog "$(tr '\n' '|' < "$OUT" 2>/dev/null)" "the relay never came up: the shim log"
    check_fail "the relay came up at the resume" "● Shim listening" "status says Shim not listening"
  else
    check_fail "status reads Shim after the resume" "● Shim listening" "no Shim row read"
  fi
  p31_exit eg-smoke exit-2.17d
}

st_2_17e() {
  local c1 c2
  p31_cd eg-smoke
  p31_smoke_load
  p31_need_idle eg-smoke resume-2.17e
  wifi_off
  if ! host_effective; then
    wifi_on
    step_skip "Wi-Fi was not really cut (simulated or skipped), so the upstream rows cannot show"
  fi
  run_cmd -e -t 60 -- bget eg-smoke https://api.anthropic.com/
  c1=$(head -n 1 "$OUT" 2>/dev/null)
  expect_line "the first request with Wi-Fi off: 000" "000"
  expect_contains "a TLS alert error (curl: (35))" "curl: (35)" "$ERR"
  record_value step17e.get1 "$c1 $(head -n 1 "$ERR" 2>/dev/null)" "the first request with Wi-Fi off"
  run_cmd -e -t 60 -- bget eg-smoke https://api.anthropic.com/
  c2=$(head -n 1 "$OUT" 2>/dev/null)
  expect_line "the second request with Wi-Fi off: 000" "000"
  record_value step17e.get2 "$c2 $(head -n 1 "$ERR" 2>/dev/null)" "the second request with Wi-Fi off"
  wifi_on
  cl -- egress log
  expect_contains "the log reads the upstream words (W10)" "allowed, but the name did not resolve, or none of its addresses from the last 60 seconds answered"   # bin/cleat:12551
  expect_match "an api.anthropic.com row carries them" 'x denied +api\.anthropic\.com:443 +allowed, but the name did not resolve'   # bin/cleat:13939
  record_value step17e.rows "$(LC_ALL=C grep 'api.anthropic.com:443' "$OUT" 2>/dev/null | tail -n 3 | tr '\n' '|')" "e's rows as printed"
}

# ---------------------------------------------------------------------------------------------
# 2.18 Fork exhaustion
# ---------------------------------------------------------------------------------------------
# p31_fork_up: a fresh eg-fork box (cleat rm first when one is left), its relay up.
p31_fork_up() {
  local k=0 s
  p31_fork_load
  if [ "${DRY:-0}" != 1 ] && [ -n "$FK_CN" ]; then
    check_note "an eg-fork box is left: cleat rm first"
    clt -T 300 -- rm
  fi
  clt -T 900 -- run
  p31_fork_load
  [ "${DRY:-0}" = 1 ] || [ -n "$FK_CN" ] || step_abort "cleat run made no eg-fork box"
  # The relay beats within seconds of the start: wait for its heartbeat loop before noting pids.
  while [ "${DRY:-0}" != 1 ] && [ "$k" -lt 15 ]; do
    val s -t 60 -- p31_shim_sum eg-fork
    [ "$(p31_kvf "$s" beats)" = 1 ] && break
    sleep 2
    k=$((k + 1))
  done
  return 0
}
# p31_fork_reads TAG: 8 reads 30 s apart from the hold. P31_FR_LISTEN: the seconds from the hold's
# end to the first post-hold read that says listening, or "never". P31_FR_IN: rc of the window
# rule (0 when listening came back within the read after the hold's end plus 30 s).
p31_fork_reads() {
  local tag="$1" hold_at="$2" hold_end i t stamp rows first=""
  hold_end=$((hold_at + 125))
  P31_FR_LISTEN=never; P31_FR_IN=1
  i=1
  while [ "$i" -le 8 ]; do
    [ "${DRY:-0}" = 1 ] || sleep 30
    t=$(epoch_now); stamp=$(date -u +%T)
    cl -t 120 -- egress status
    grep_lines 'Gateway|Shim'
    rows=$(tr '\n' '|' < "$OUT" 2>/dev/null)
    record_value "$tag.read$i" "$stamp $rows" "read $i, $((t - hold_at)) s after the hold began (from the host: exec into the box fails during the hold)"
    if [ "$t" -ge "$hold_end" ]; then
      if [ "$P31_FR_LISTEN" = never ] && LC_ALL=C grep -q '● Shim listening' "$OUT"; then
        P31_FR_LISTEN=$((t - hold_end))
        # In time: no later than the first read at least 30 s after the hold's end.
        if [ -z "$first" ]; then P31_FR_IN=0; fi
      fi
      if [ -z "$first" ] && [ "$t" -ge $((hold_end + 30)) ]; then first="$t"; fi
    fi
    i=$((i + 1))
  done
  return 0
}

st_2_18a() {
  local sum0 sum1 relay0 bp0 cnt retry giveup again code="" hold_at
  p31_cd eg-fork make
  p31_fork_up
  val sum0 -t 60 -- p31_shim_sum eg-fork
  record_value step18a.shim_before "$sum0" "the supervisor, loop and socat pids before the exhauster"
  relay0=$(p31_kvf "$sum0" relay); bp0=$(p31_kvf "$sum0" beatspid)
  run_cmd -t 60 -- egexhaust eg-fork
  hold_at=$(epoch_now)
  kv_set step18a.hold_at "$hold_at"
  record_value step18a.hold "$(date -u +%T) UTC" "the hold began (the scenario's date +%T)"
  p31_fork_reads step18a "$hold_at"
  record_value step18a.listen "$P31_FR_LISTEN" "seconds from the hold's end to Shim listening"
  run_cmd -t 60 -- shimlog eg-fork 40
  record_value step18a.log "$(tr '\n' '|' < "$OUT" 2>/dev/null | cut -c1-400)" "the relay log after the hold (shimlog 40)"
  val cnt -t 60 -- p31_log_counts eg-fork
  record_value step18a.fork "$cnt" "bash's fork retry and give-up lines, restarts and relay starts over the whole relay log"
  retry=$(p31_kvf "$cnt" retry); giveup=$(p31_kvf "$cnt" giveup); again=$(p31_kvf "$cnt" again)
  val sum1 -t 60 -- p31_shim_sum eg-fork
  record_value step18a.shim_after "$sum1" "the relay processes after the hold"
  run_cmd -e -t 60 -- bget eg-fork https://api.anthropic.com/
  code=$(head -n 1 "$OUT" 2>/dev/null)
  record_value step18a.code "$code" "the request after the hold (an HTTP answer, never 000)"
  if [ "${DRY:-0}" = 1 ]; then
    check_pass "fork exhaustion a: give-up and the loop lives on (dry)"
    return 0
  fi
  if ! p31_is_int "$giveup" || { [ "$giveup" = 0 ] && [ "$again" = 0 ]; }; then
    check_fail "the exhauster held the box (a give-up or a restart line)" "bash's give-up line" "$cnt: inconclusive, the run proves nothing"
    return 0
  fi
  expect_num "bash's fork: retry lines" "$retry" ge 1
  expect_num "at least one give-up line (fork: Resource temporarily unavailable, no retry)" "$giveup" ge 1
  if [ "$again" -gt 0 ] 2>/dev/null; then
    check_note "the relay log also holds $again supervisor restart lines: a heartbeat slipped through as the hold began (not a failure, recorded)"
  fi
  if [ "$(p31_kvf "$sum1" relay)" = "$relay0" ]; then
    expect_eq "the same heartbeat loop pid after the hold" "$(p31_kvf "$sum1" beatspid)" "$bp0"
    expect_eq "still --beats with the same relay pid" "$(p31_kvf "$sum1" relay)" "$relay0"
  else
    check_note "the relay changed over the hold ($sum0 -> $sum1): a heartbeat slipped through, the listener forked and ended (variant b lines)"
  fi
  if [ "$(p31_kvf "$sum1" beats)" = 0 ] || [ "$P31_FR_LISTEN" = never ]; then
    check_fail "the heartbeat loop lives on and status reads Shim listening again (W2)" "● Shim listening, one --beats loop" "$sum1, listening $P31_FR_LISTEN"
    say ">>> W2 failure: healing with cleat egress restart --shim. Record the log and hold the tag."
    clt -T 300 -- egress restart --shim
  elif [ "$P31_FR_IN" = 0 ]; then
    check_pass "● Shim listening again within about 30 s of the hold's end, no restart --shim" "$P31_FR_LISTEN s"
  else
    check_fail "● Shim listening again within about 30 s of the hold's end" "the first read 30 s after the hold's end" "$P31_FR_LISTEN s"
  fi
  case "$code" in 000|"") check_fail "the request gets an HTTP answer after the hold (never 000)" "an HTTP code" "${code:-nothing}" ;; *) check_pass "the request gets an HTTP answer after the hold" "$code" ;; esac
}

st_2_18b() {
  local sum0 sum1 sp0 relay0 cnt again started last code="" hold_at
  p31_cd eg-fork make
  # The box goes at the end, also when the step is cut (its exhauster and traffic with it).
  on_cleanup "( cd $(printf '%q' "$P/eg-fork") && cl -q -- rm >/dev/null 2>&1 ) || true"
  p31_fork_up
  val sum0 -t 60 -- p31_shim_sum eg-fork
  record_value step18b.shim_before "$sum0" "the supervisor pid before the traffic and the exhauster"
  sp0=$(p31_kvf "$sum0" suppid); relay0=$(p31_kvf "$sum0" relay)
  run_cmd -t 60 -- p31_traffic eg-fork
  run_cmd -t 60 -- egexhaust eg-fork
  hold_at=$(epoch_now)
  kv_set step18b.hold_at "$hold_at"
  record_value step18b.hold "$(date -u +%T) UTC" "the hold began (the scenario's date +%T)"
  p31_fork_reads step18b "$hold_at"
  record_value step18b.listen "$P31_FR_LISTEN" "seconds from the hold's end to Shim listening"
  run_cmd -t 60 -- shimlog eg-fork 40
  record_value step18b.log "$(tr '\n' '|' < "$OUT" 2>/dev/null | cut -c1-400)" "the relay log after the hold (shimlog 40)"
  val cnt -t 60 -- p31_log_counts eg-fork
  record_value step18b.fork "$cnt" "give-up, restart and relay start lines over the whole relay log"
  started=$(p31_kvf "$cnt" started); last=$(p31_kvf "$cnt" lastrelay)
  val sum1 -t 60 -- p31_shim_sum eg-fork
  record_value step18b.shim_after "$sum1" "the relay processes after the hold"
  run_cmd -e -t 60 -- bget eg-fork https://api.anthropic.com/
  code=$(head -n 1 "$OUT" 2>/dev/null)
  record_value step18b.code "$code" "the request after the hold"
  val again -t 60 -- p31_again_count eg-fork
  record_value step18b.again "${again:-none}" "supervisor started again in place (the scenario's grep -c), about one per 15 s of the hold"
  if [ "${DRY:-0}" = 1 ]; then
    check_pass "fork exhaustion b: the supervisor started itself again (dry)"
  elif [ "$(p31_kvf "$cnt" giveup)" = 0 ] && [ "${again:-0}" = 0 ]; then
    check_fail "the exhauster held the box (a give-up or a restart line)" "supervisor started again in place" "$cnt: inconclusive, the run proves nothing"
  else
    expect_num "at least one supervisor started again in place (W2)" "${again:-0}" ge 1
    if p31_is_int "$started" && [ "$started" -ge 2 ] && [ "$last" != "$relay0" ]; then
      check_pass "a new relay started once the pids freed" "relay started pid=$last"
    else
      check_fail "a new relay started once the pids freed" "a relay started line after the hold" "$cnt"
    fi
    expect_eq "the same supervisor pid" "$(p31_kvf "$sum1" suppid)" "$sp0"
    expect_eq "the supervisor now reads --again <n>" "$(p31_kvf "$sum1" again)" "1"
    expect_eq "one --beats loop" "$(p31_kvf "$sum1" beats)" "1"
    expect_eq "the --beats loop names the new relay" "$(p31_kvf "$sum1" relay)" "$last"
    expect_num "the listener socat runs" "$(p31_kvf "$sum1" socat)" ge 1
    if [ "$P31_FR_LISTEN" = never ]; then
      check_fail "status reads ● Shim listening again without restart --shim" "● Shim listening" "never after the hold"
    else
      check_pass "status reads ● Shim listening again without restart --shim" "$P31_FR_LISTEN s after the hold's end"
    fi
    case "$code" in 000|"") check_fail "the request gets an HTTP answer after the hold (never 000)" "an HTTP code" "${code:-nothing}" ;; *) check_pass "the request gets an HTTP answer after the hold" "$code" ;; esac
    if [ "$(p31_kvf "$sum1" socat)" = 0 ] || [ "$P31_FR_LISTEN" = never ]; then
      if [ "${again:-0}" -ge 4 ] 2>/dev/null; then
        check_note "four or more quick restarts and no relay: the bound on quick ends fired (it should only fire for want of memory)"
      fi
      say ">>> W2 failure: healing with cleat egress restart --shim. Record the log and hold the tag."
      run_cmd -t 60 -- shimlog eg-fork 40
      clt -T 300 -- egress restart --shim
    fi
  fi
  clt -T 300 -- rm
}

# ---------------------------------------------------------------------------------------------
# 2.19 The storm (EXTRA)
# ---------------------------------------------------------------------------------------------
st_2_19() {
  local before after c0 c1 d0 d1 refused total code=""
  p31_cd eg-smoke
  p31_smoke_load
  p31_need_idle eg-smoke resume-2.19
  val before -t 60 -- p31_exited_count eg-smoke
  val c0 -t 60 -- p31_denied_count eg-smoke
  run_cmd -t 180 -- p31_storm eg-smoke
  # "<count> <code>" rows. A CONNECT the gateway refused reads 000 in the box's curl (7.88), not
  # 403 (header comment): count 403 OR 000 as refused, the gateway's counter decides.
  refused=$(LC_ALL=C awk '$2 == 403 || $2 == "000" { n += $1 } END { print n + 0 }' "$OUT" 2>/dev/null)
  total=$(LC_ALL=C awk '{ n += $1 } END { print n + 0 }' "$OUT" 2>/dev/null)
  record_value step19.codes "$(tr '\n' '|' < "$OUT" 2>/dev/null)" "the uniq -c of the 400 codes"
  run_cmd -t 60 -- shimlog eg-smoke 5
  val after -t 60 -- p31_exited_count eg-smoke
  val c1 -t 60 -- p31_denied_count eg-smoke
  record_value step19.denied "$c0 -> $c1" "the gateway's counters before and after (ok counts <allowed> <denied>)"
  run_cmd -t 60 -- docker stats --no-stream "$SM_GW"
  record_value step19.stats "$(tr '\n' '|' < "$OUT" 2>/dev/null)" "docker stats of the gateway (notes only, never published)"
  run_cmd -e -t 60 -- bget eg-smoke https://example.com/
  code=$(head -n 1 "$OUT" 2>/dev/null)
  if [ "${DRY:-0}" = 1 ]; then
    check_pass "the storm is refused and the relay keeps working (dry)"
  else
    expect_num "almost every line is a refusal (403, or 000 for a denied tunnel: >= 390 of $total)" "${refused:-0}" ge 390
    d0="${c0##* }"; d1="${c1##* }"
    if p31_is_int "$d0" && p31_is_int "$d1"; then
      expect_num "the gateway denied almost every CONNECT (its denied counter rose by >= 390)" "$((d1 - d0))" ge 390
    else
      check_fail "the gateway's denied counter was read" "ok counts <allowed> <denied>" "$c0 -> $c1"
    fi
    expect_eq "no new relay exited during the storm" "$after" "$before"
    expect_eq "the request after the storm works: 200" "$code" "200"
  fi
}

# ---------------------------------------------------------------------------------------------
# 2.20 Interlocks and refusals (W1)
# ---------------------------------------------------------------------------------------------
st_2_20a() {
  local st box
  p31_cd eg-lock make
  kv_set step20a.done 0
  on_cleanup "p31_docker_cleanup"
  # Re-entry: an earlier attempt left docker on, so the caged create would refuse.
  p31_docker_off
  if [ "${DRY:-0}" = 1 ] || ! run_cmd -q -t 60 -- box_running eg-lock; then
    clt -T 900 -- run
  else
    check_note "the eg-lock box is already running (an earlier attempt): no cleat run"
  fi
  val box -t 60 -- cn eg-lock
  [ "${DRY:-0}" = 1 ] || [ -n "$box" ] || step_abort "cleat run made no eg-lock box"
  clt -T 300 -- config --enable docker
  expect_rc "cleat config --enable docker is accepted, rc 0" 0
  expect_not_match "config --enable docker says nothing about egress or the policy" '[Ee]gress|policy'
  clt -T 300 -- egress
  expect_rc "the editor refuses to open, rc 1" 1
  expect_contains "the editor: cannot be saved while docker is on" "✖ Egress control cannot be saved while the docker capability is on."   # bin/cleat:17671
  expect_contains "the editor: docker reaches every network" "docker hands the box your Docker daemon, which reaches every network."   # bin/cleat:17678
  expect_contains "the editor: turn it off in the global config" "It is on in your global config. Turn it off:  cleat config --disable docker"   # bin/cleat:17683
  clt -T 300 -- egress allow example.net
  expect_rc "the writer refuses too, rc 1" 1
  expect_contains "the writer: the same first line" "✖ Egress control cannot be saved while the docker capability is on." "$OUT"
  expect_contains "the writer: docker reaches every network" "docker hands the box your Docker daemon, which reaches every network." "$OUT"
  expect_contains "the writer: turn it off in the global config" "It is on in your global config. Turn it off:  cleat config --disable docker" "$OUT"
  cl --
  expect_rc "off a terminal, the launch refuses, rc 1" 1
  expect_match "off a terminal: Config changed, recreate to apply" 'Config changed since cleat-eg-lock-[0-9a-f]{8} was created\. Recreate to apply: cleat rm && cleat'   # bin/cleat:6896
  expect_contains "off a terminal: the docker interlock refusal" "✖ Egress refused box main: the docker capability hands the box the Docker daemon, which reaches every network."   # bin/cleat:11986
  expect_contains "off a terminal: the fix names the capability and cleat egress off" "Fix:  turn the capability off (cleat config), or cleat egress off for this box"
  val st -t 60 -- docker inspect -f '{{.State.Status}} {{.HostConfig.NetworkMode}}' "$box"
  expect_eq "the box is still there, on none" "$st" "running none"
  kv_set step20a.done 1
}

st_2_20b() {
  local box st gst
  p31_cd eg-lock
  p31_docker_need
  if [ "${DRY:-0}" != 1 ] && ! run_cmd -q -t 60 -- box_running eg-lock; then
    step_abort "the eg-lock box is not running: run --only 2.20a first"
  fi
  # The scenario's T1 cleat, refused before Claude opens: the script's own pty (DESIGN 4.19).
  clt --rule w1 'Recreate \S+ now\? \[Y/n\]' 'n<enter>' -T 300 --
  expect_rc "on a terminal the launch refuses, rc 1" 1
  expect_contains "the docker refusal on a terminal" "✖ Egress refused box main: the docker capability hands the box the Docker daemon, which reaches every network." "$OUT"
  expect_contains "the same fix line" "Fix:  turn the capability off (cleat config), or cleat egress off for this box" "$OUT"   # bin/cleat:11986-11987
  expect_order "the refusal prints before any Config changed since line (W1)" "Egress refused box main: the docker capability hands the box the Docker daemon" "Config changed since"
  expect_order "the refusal prints before any Recreate prompt (W1)" "Egress refused box main: the docker capability hands the box the Docker daemon" "Recreate"
  if [ "${DRY:-0}" != 1 ]; then expect_num "no recreate prompt fired (W1 held)" "$(xfired w1)" eq 0; fi
  val box -t 60 -- cn eg-lock
  if [ "${DRY:-0}" != 1 ]; then
    p31_vfile "$box"
    expect_match "the box is still listed" '^cleat-eg-lock-[0-9a-f]{8}$' "$P31_VF"
  fi
  val st -t 60 -- docker inspect -f '{{.State.Status}} {{.HostConfig.NetworkMode}}' "$box"
  expect_eq "the box is running none" "$st" "running none"
  val gst -t 60 -- gw_state eg-lock
  expect_match "its gateway is still running" '^running '
}

st_2_20c() {
  local box st
  p31_cd eg-lock
  p31_docker_need
  val box -t 60 -- cn eg-lock
  [ "${DRY:-0}" = 1 ] || [ -n "$box" ] || step_abort "no eg-lock box: run --only 2.20a first"
  clt -T 300 -- stop
  clt --rule w1 'Recreate \S+ now\? \[Y/n\]' 'n<enter>' -T 300 --
  expect_rc "cleat on the stopped box refuses, rc 1" 1
  expect_contains "the docker refusal" "✖ Egress refused box main: the docker capability hands the box the Docker daemon, which reaches every network." "$OUT"
  expect_contains "the same fix line" "Fix:  turn the capability off (cleat config), or cleat egress off for this box" "$OUT"   # bin/cleat:11986-11987
  expect_order "the refusal first, before any Recreate prompt" "Egress refused box main: the docker capability hands the box the Docker daemon" "Recreate"
  if [ "${DRY:-0}" != 1 ]; then expect_num "no recreate prompt fired (start)" "$(xfired w1)" eq 0; fi
  # cleat run on a stopped box removes it before it creates it again. It asks nothing.
  clt --rule w1 'Recreate \S+ now\? \[Y/n\]' 'n<enter>' -T 300 -- run
  expect_rc "cleat run on the stopped box refuses too, rc 1" 1
  expect_contains "the same docker refusal" "✖ Egress refused box main: the docker capability hands the box the Docker daemon, which reaches every network." "$OUT"
  if [ "${DRY:-0}" != 1 ]; then expect_num "no recreate prompt fired (run)" "$(xfired w1)" eq 0; fi
  val st -t 60 -- docker inspect -f '{{.State.Status}} {{.HostConfig.NetworkMode}}' "$box"
  expect_eq "the box is exited none, kept" "$st" "exited none"
}

st_2_20d() {
  local id id2 st box
  p31_cd eg-lock
  clt -T 300 -- config --disable docker
  if [ "${DRY:-0}" != 1 ] && p31_docker_on; then step_abort "cleat config --disable docker left docker on"; fi
  val id -t 60 -- box_id eg-lock
  [ "${DRY:-0}" = 1 ] || [ -n "$id" ] || step_abort "no eg-lock box: run --only 2.20a first"
  kv_set step20d.box_id "$id"
  p31_launch eg-lock "cleat" launch-2.20d "-Recreate" "-Config changed since"
  val id2 -t 60 -- box_id eg-lock
  expect_eq "nothing was recreated (the box id is unchanged)" "$id2" "$id"
  p31_exit eg-lock exit-2.20d
  clt --rule w1 'Recreate \S+ now\? \[Y/n\]' 'n<enter>' -T 300 -- --cap ssh start
  expect_rc "cap ssh start refuses, rc 1" 1
  expect_contains "the ssh refusal" "✖ Egress refused box main: the ssh capability mounts your agent, which signs for anything and can reach nothing under a policy."   # bin/cleat:11991
  expect_order "the ssh refusal before any Recreate prompt" "the ssh capability mounts your agent" "Recreate"
  if [ "${DRY:-0}" != 1 ]; then expect_num "no recreate prompt fired (ssh)" "$(xfired w1)" eq 0; fi
  clt -T 300 -- --cap ssh shell
  expect_rc "cap ssh shell refuses, rc 1" 1
  expect_contains "the ssh shell refusal" "the ssh capability mounts your agent, which signs for anything and can reach nothing under a policy." "$OUT"
  clt -T 300 -- --cap hooks shell
  expect_rc "cap hooks shell refuses, rc 1" 1
  expect_contains "the hooks refusal" "the hooks capability runs host commands at times the box picks, which no policy governs."   # bin/cleat:11996
  xshell eg-lock
  expect_rc "cleat shell with no extra cap opens, rc 0" 0
  val box -t 60 -- cn eg-lock
  val st -t 60 -- docker inspect -f '{{.State.Status}} {{.HostConfig.NetworkMode}}' "$box"
  expect_eq "the box is running none" "$st" "running none"
  val id2 -t 60 -- box_id eg-lock
  expect_eq "the caged box is the one 2.20a made (never removed by a refusal)" "$id2" "$id"
}

st_2_20_hooks() {
  p31_cd eg-lock
  p31_docker_off
  # The escape passes the create's own checks, so the recreate prompt still comes: answer it Y.
  p31_launch --answer recreate=y eg-lock "CLEAT_EGRESS_ALLOW_HOOKS=1 cleat --cap hooks" launch-2.20hooks \
    "~Config changed since cleat-eg-lock-[0-9a-f]{8} was created: its capabilities, environment, or resource limits differ from your current setup" \
    "~Recreate cleat-eg-lock-[0-9a-f]{8} now\? \[Y/n\]" \
    "+Egress:     strict, claim void  ·  " \
    "+! hooks runs your host commands with box-supplied stdin"   # bin/cleat:6843-6863, 12328, 12338
  cl -- egress status
  first_lines 3
  expect_contains "status opens with the claim-void line" "! The claim is void for this box   CLEAT_EGRESS_ALLOW_HOOKS=1 was set at create time"   # bin/cleat:14384
  # The claim-void block of the session-end report prints even with nothing denied (bin/cleat:20629-20632).
  p31_exit eg-lock end-2.20hooks \
    "+! The claim is void for this box   CLEAT_EGRESS_ALLOW_HOOKS=1 was set at create time" \
    "+A host hook runs host commands at times the box picks." \
    "+Drop the flag and recreate to restore it:  cleat rm && cleat"   # bin/cleat:14384-14386
  clt -T 300 -- shell
  expect_rc "cleat shell with no cap refuses the hooks box, rc 1" 1
  expect_contains "the refusal names the escape" "it was created with CLEAT_EGRESS_ALLOW_HOOKS=1 and the hooks capability, and this launch does not have both."   # bin/cleat:11859
  clt -T 300 -- rm
  expect_match "cleat rm removes it" 'Removed cleat-eg-lock-[0-9a-f]{8}\.'   # bin/cleat:23064
}

# ---------------------------------------------------------------------------------------------
# 2.21 Open and off
# ---------------------------------------------------------------------------------------------
st_2_21a() {
  local n1 n2 box
  p31_cd eg-smoke
  p31_smoke_load
  p31_docker_off
  run_cmd -t 120 -- p31_dig 10-0-0-1.sslip.io 169-254-169-254.sslip.io
  if LC_ALL=C grep -q 'dig is missing' "$OUT" 2>/dev/null; then check_note "dig is missing on this Mac: an alpine nslookup answered instead"; fi
  if [ "${DRY:-0}" != 1 ] && ! LC_ALL=C grep -q -E '(^|[^0-9])(10\.0\.0\.1|169\.254\.169\.254)([^0-9]|$)' "$OUT"; then
    kv_set rebind.filtered yes
    check_note "rebind-filtered: the resolver returned no private answer (DNS-rebinding protection), so the rows read upstream, not address"
  else
    kv_set rebind.filtered no
  fi
  record_value step21a.rebind "$(kv_get rebind.filtered no)" "whether the sslip.io names were rebind-filtered"
  p31_need_live eg-smoke resume-2.21a
  clt --answer eg-open=y -T 300 -- egress open
  if [ "${DRY:-0}" != 1 ] && LC_ALL=C grep -q 'is already open until it stops' "$OUT"; then
    check_note "box main is already open for this session (an earlier attempt): the confirmation is not shown again"
  else
    expect_contains "the confirmation: still refused in open mode" "Still refused in open mode:" "$OUT"   # bin/cleat:13373
    expect_contains "still refused: plaintext http" "plaintext http          nothing on port 80 can be verified" "$OUT"   # bin/cleat:13374
    expect_contains "still refused: IP literals" "IP literals             a name is required, always" "$OUT"   # bin/cleat:13375
    expect_contains "still refused: private space" "private space           private, loopback and link-local addresses," "$OUT"   # bin/cleat:13376
    expect_contains "still refused: cloud metadata" "cloud metadata          169.254.169.254 and the rest of link-local" "$OUT"   # bin/cleat:13378
    expect_contains "still refused: raw sockets and DNS" "raw sockets and DNS     the box still has no route off this machine" "$OUT"   # bin/cleat:13379
    expect_contains "open succeeds for box main until it stops" "✔ Open for box main until it stops. Every destination is logged:  cleat egress log"   # bin/cleat:13468
  fi
  val n1 -t 60 -- bx eg-smoke grep -c 'There is no host allowlist in this session' /home/coder/.claude/CLAUDE.md
  expect_num "the in-box fragment says open" "${n1:-0}" eq 1   # bin/cleat:3447
  run_cmd -e -t 60 -- bget eg-smoke https://example.org/
  expect_line "example.org answers 200 now" "200"
  cl -- egress log
  grep_lines 'v allowed   example\.org:443'
  expect_match "the log records the allowed destination" 'v allowed   example\.org:443'   # bin/cleat:13929
  run_cmd -t 60 -- bconnect eg-smoke example.org:80
  first_lines 1
  expect_contains "port 80 is refused" "HTTP/1.1 403 cleat egress: port 80 is not allowed for example.org"   # gateway.py:208
  run_cmd -t 60 -- bconnect eg-smoke 1.1.1.1:443
  first_lines 1
  expect_contains "an IP literal is refused" "HTTP/1.1 403 cleat egress: 1.1.1.1 is not a name the allowlist can hold"   # gateway.py:204
  run_cmd -e -t 60 -- bget eg-smoke https://10-0-0-1.sslip.io/
  expect_line "a name on a private address is refused at connect (000)" "000"
  run_cmd -e -t 60 -- bget eg-smoke https://169-254-169-254.sslip.io/
  expect_line "cloud metadata, link-local is refused (000)" "000"
  cl -- egress log --refused
  grep_lines ' refused '
  if [ "$(kv_get rebind.filtered no)" = yes ]; then
    expect_not_match "rebind-filtered: --refused holds no row for the sslip.io names (upstream is not a security code)" 'sslip\.io'   # bin/cleat:12559-12562
    cl -- egress log
    expect_match "the 10-0-0-1 row reads upstream" 'x denied +10-0-0-1\.sslip\.io:443 +allowed, but the name did not resolve'   # bin/cleat:13939
    expect_match "the 169-254 row reads upstream" 'x denied +169-254-169-254\.sslip\.io:443 +allowed, but the name did not resolve'
  else
    expect_match "the refused log holds the 10-0-0-1 row" 'x refused +10-0-0-1\.sslip\.io:443 +address'   # bin/cleat:13937
    expect_match "the refused log holds the 169-254 row" 'x refused +169-254-169-254\.sslip\.io:443 +address'
  fi
  cl -- egress status
  first_lines 3
  expect_contains "status: open egress until box main stops" "! Open egress: every TLS host is allowed and every destination is logged, until box main stops."   # bin/cleat:14464
  p31_exit eg-smoke exit-2.21a
  run_cmd -e -t 60 -- bget eg-smoke https://example.org/
  expect_line "open outlives the session (still 200 after exit): open lasts until the container stops" "200"
  clt -T 300 -- stop
  p31_launch eg-smoke "cleat resume" resume2-2.21a
  run_cmd -t 60 -- bconnect eg-smoke example.org:443
  first_lines 1
  expect_contains "after a stop, strict is back: the 403" "HTTP/1.1 403 cleat egress: example.org is not on the allowlist"   # gateway.py:197,230
  val n2 -t 60 -- bx eg-smoke grep -c 'these hosts are reachable, on port 443:' /home/coder/.claude/CLAUDE.md
  expect_num "the strict fragment is back (section 8: the full sentence wraps, so grep the second line)" "${n2:-0}" eq 1   # bin/cleat:3467
  p31_exit eg-smoke exit2-2.21a
}

st_2_21b() {
  local nm code box gwold already=0
  p31_cd eg-smoke
  p31_smoke_load
  p31_docker_off
  gwold=$(kv_get eg-smoke.gw "")
  box="$SM_CN"
  if run_cmd -q -t 90 -- box_claude_live eg-smoke; then p31_exit eg-smoke exit-2.21b-pre; fi
  # Re-entry: off already ran (no cage, the box's own file says off).
  if [ "${DRY:-0}" != 1 ] && [ -f "$CFG/egress-boxes/$box" ] && LC_ALL=C grep -q '^mode = off$' "$CFG/egress-boxes/$box"; then
    val nm -t 60 -- box_netmode eg-smoke
    if [ "$nm" != none ]; then already=1; fi
  fi
  # c's marker: its drop is still to come after this off.
  kv_set step21c.dropped 0
  if [ "$already" = 1 ]; then
    check_note "egress control is already off for box main (an earlier attempt): the confirmation is not shown again"
  else
    clt --answer eg-off-box=y -T 900 -- egress off
    expect_contains "the off confirmation: the recreate discards the container's writable layer" "own filesystem is not: anything installed inside it since it was" "$OUT"   # bin/cleat:13544-13545
    expect_contains "the off confirmation: no network can be given later" "A box created with no network of its own cannot be given one later." "$OUT"   # bin/cleat:13547
    expect_contains "off recreates the box with a normal network" "✔ Box main recreated with a normal network. Egress control stays off for it:  cleat egress main turns it back on."   # bin/cleat:13648
  fi
  val nm -t 60 -- box_netmode eg-smoke
  [ "${DRY:-0}" = 1 ] || [ -n "$nm" ] || nm="no box"
  expect_ne "the box NetworkMode is not none" "$nm" "none"
  record_value step21b.netmode "$nm" "the box's network after off"
  val box -t 60 -- cn eg-smoke
  run_cmd -e -t 60 -- docker exec -u coder "$box" curl -sS -o /dev/null -w '%{http_code}\n' https://example.org/
  code=$(head -n 1 "$OUT" 2>/dev/null)
  expect_eq "a direct request with no proxy at all: 200" "$code" "200"
  run_cmd -t 60 -- cat "$CFG/egress-boxes/$box"
  expect_contains "the box's own file holds [egress]" "[egress]" "$OUT"
  expect_contains "the box's own file sets mode = off" "mode = off" "$OUT"
  run_cmd -t 60 -- egobjs
  if [ -n "$gwold" ]; then
    expect_not_contains "egobjs: no gateway or socket volume for eg-smoke" "$gwold" "$OUT"
  elif [ "${DRY:-0}" != 1 ]; then
    check_fail "egobjs: no gateway or socket volume for eg-smoke" "the gateway's name from before the off" "kv eg-smoke.gw is empty"
  fi
  cl -- egress status
  first_lines 2
  expect_contains "status: egress is off for this box by its own file" "○ Egress control is off for this box, by its own file"   # bin/cleat:14435
}

st_2_21c() {
  local nm box state=normal
  p31_cd eg-smoke
  p31_smoke_load
  p31_docker_off
  box="$SM_CN"
  # Re-entry: the drop or the recreate already ran.
  if [ "${DRY:-0}" != 1 ] && [ ! -f "$CFG/egress-boxes/$box" ]; then
    val nm -t 60 -- box_netmode eg-smoke
    if [ "$nm" = none ]; then state=finished; else state=dropped; fi
  fi
  case "$state" in
    finished)
      # Caged with no file of its own: c finished in an earlier attempt, or b never ran.
      if [ "$(kv_get step21c.dropped 0)" = 1 ]; then
        check_note "box main is already caged again (an earlier attempt finished c)"
        expect_eq "the box is caged, NetworkMode none" "$nm" "none"
        return 0
      fi
      step_abort "box main is caged and has no egress file of its own: run --only 2.21b first (off), then 2.21c" ;;
    dropped)
      check_note "the box's own file is already dropped (an earlier attempt): the recreate is what is left" ;;
    *)
      clt --answer eg-drop=y -T 300 -- egress main --inherit
      expect_contains "the inherit: box main inherits the global policy" "✔ Box main now inherits the global egress policy."   # bin/cleat:14790
      expect_contains "it refuses to start until recreated (W9)" "Box main was created without egress control and refuses to start until" "$OUT"   # bin/cleat:13218
      expect_contains "the recreate words (W9)" "it is recreated:  cleat rm && cleat" "$OUT"   # bin/cleat:13219
      expect_contains "it is running, so it keeps its full network (W9)" "It is running, so it keeps its full network until it stops." "$OUT"   # bin/cleat:13201
      expect_contains "a session already open in it is not caged (W9)" "A session already open in it is not caged." "$OUT"   # bin/cleat:13208
      kv_set step21c.dropped 1
      ;;
  esac
  p31_launch --answer recreate=y eg-smoke "cleat" launch-2.21c \
    "~Config changed since cleat-eg-smoke-[0-9a-f]{8} was created: it has no egress cage, and your egress policy needs one" \
    "~Recreate cleat-eg-smoke-[0-9a-f]{8} now\? \[Y/n\]" \
    "-Refresh the image"   # bin/cleat:6845,6863
  if [ "${DRY:-0}" != 1 ] && t_have_capture && [ -s "$OUT" ]; then
    expect_count "it asks once: exactly one Recreate prompt" 'Recreate cleat-eg-smoke-[0-9a-f]{8} now\? \[Y/n\]' eq 1
  fi
  p31_smoke_load
  val nm -t 60 -- box_netmode eg-smoke
  expect_eq "the box is caged again, NetworkMode none" "$nm" "none"
  p31_exit eg-smoke exit-2.21c
}

st_2_21d() {
  p31_cd eg-smoke
  p31_smoke_load
  p31_docker_off
  on_cleanup "p31_restore_strict"
  clt --answer eg-open-always=y -T 300 -- egress open --always
  expect_contains "the question" "Open egress for every box until you change it? [y/N]" "$OUT"   # bin/cleat:13481
  expect_contains "the global policy is open until you change it" "✔ The global policy is open until you change it. Every destination is logged."   # bin/cleat:13489
  p31_launch eg-smoke "cleat resume" relaunch-2.21d "+Egress:     open  ·  every TLS host allowed, every host logged"   # bin/cleat:12317,12324
  p31_exit eg-smoke exit-2.21d
  # Undo it from the editor: Mode row left to strict, enter, y.
  p31_ed_begin
  xp_send "<left>"; xp_wait fm '\x1b\[J' 20
  xp_sleep 200
  xp_snap mode
  xp_send "<enter>"
  xp_wait saveq 'Save\? \[Y/n\]' 60
  xp_sleep 300
  xp_send "y<enter>"
  xp_wait saved 'Saved to ' 60
  xp_eof 60
  clt --prog -n d-undo -T 300 --answer eg-save-yn=manual -- egress
  expect_contains "the undo saved" "Saved to "   # bin/cleat:17462
  cl -- egress --list
  grep_lines 'Mode:'
  expect_match "the global policy reads strict again (allow never changes an open mode)" '^  Mode: +strict'
}

st_2_21e() {
  local n box o i
  p31_cd eg-smoke
  p31_smoke_load
  p31_docker_off
  box="$SM_CN"
  p31_need_up eg-smoke resume-2.21e
  if run_cmd -q -t 90 -- box_claude_live eg-smoke; then p31_exit eg-smoke exit-2.21e-pre; fi
  # A cut attempt can leave the box's own file and npm in the policy.
  on_cleanup "p31_box_file_drop"
  on_cleanup "p31_drop_pack npm"
  if [ "${DRY:-0}" != 1 ] && [ -f "$CFG/egress-boxes/$box" ]; then
    check_note "an earlier attempt left box main's own egress file: it is dropped first"
    cl -- egress main --inherit --yes
  fi
  clt -T 300 -- egress allow npm
  cl -- egress status
  grep_lines 'Allowed:'
  n=$(LC_ALL=C sed -n 's/^  Allowed: *\([0-9][0-9]*\).*/\1/p' "$OUT" 2>/dev/null | head -n 1)
  [ "${DRY:-0}" = 1 ] && n=7
  record_value step21e.allowed "${n:-unknown}" "N: the hosts box main resolves to (status Allowed:)"

  # The box editor: read the ticks and the count, untick example.com, save y. The rows depend on
  # how many hosts the global policy holds, so the walk goes one key at a time to the last row and
  # a rule presses space once, the moment the cursor sits on example.com (its tick still a ✔).
  p31_ed_begin
  xp_sleep 200
  xp_snap frame
  xp_rule excom '▸(\x1b\[[0-9;]*m)* \[(\x1b\[[0-9;]*m)*✔(\x1b\[[0-9;]*m)*\] (\x1b\[[0-9;]*m)*example\.com ' '<space>' 1
  i=1
  while [ "$i" -le 80 ]; do
    xp_send "<down>"
    xp_wait "dn$i" '\x1b\[J' 20
    i=$((i + 1))
  done
  xp_sleep 300
  xp_send "<enter>"
  xp_wait saveq 'Save what box main may reach\?' 60
  xp_wait saveq2 'Save\? \[Y/n\]' 30
  xp_sleep 300
  xp_send "y<enter>"
  xp_wait saved 'Saved to ' 60
  xp_eof 60
  clt --prog -n e-boxeditor -T 600 --answer eg-save-yn=manual -- egress main
  o="$OUT"
  if [ "${DRY:-0}" != 1 ]; then expect_num "example.com was found and unticked under Hosts" "$(xfired excom)" eq 1; fi
  expect_contains "the review asks what box main may reach" "Save what box main may reach?" "$o"   # bin/cleat:17367
  expect_match "the save writes box main's own file" 'Saved to .*egress-boxes/cleat-eg-smoke-[0-9a-f]{8}' "$o"   # bin/cleat:17462
  expect_match "the running box takes it now" 'Applied to cleat-eg-smoke-[0-9a-f]{8}: its gateway reloaded\.' "$o"   # bin/cleat:13129
  xsnap frame
  expect_match "the box editor title names box main" '\(what box main may reach\)'   # bin/cleat:16028
  expect_match "github shows ticked (the global policy ticks it)" '\[✔\] github '   # bin/cleat:16144-16162
  expect_match "npm shows ticked (the global policy ticks it)" '\[✔\] npm '
  if p31_is_int "$n"; then
    expect_match "the On save count matches N ($n)" "On save: $n hosts allowed"   # bin/cleat:16321,16350-16352
  else
    check_fail "the On save count matches N" "a number from status Allowed:" "${n:-nothing}"
  fi
  record_value step21e.frame "$(LC_ALL=C grep -E 'github|npm|On save' "$OUT" 2>/dev/null | tr '\n' '|')" "the ticks and the count the box editor showed"
  OUT="$o"

  clt -T 300 -- egress test example.com
  expect_rc "test example.com for box main: rc 1" 1
  expect_contains "it reads x deny for box main" "x deny    example.com:443   the gateway's matcher, box main"   # bin/cleat:14021
  run_cmd -t 60 -- cat "$CFG/egress-boxes/$box"
  expect_contains "the box's own file: example.com kept apart as a block" "deny = example.com" "$OUT"
  record_value step21e.boxfile "$(tr '\n' '|' < "$OUT" 2>/dev/null | cut -c1-200)" "the box's own file after the box-editor save"
  clt -T 300 -- egress deny --box main registry.npmjs.org
  expect_contains "the block inside a pack the global policy ticks is saved" "registry.npmjs.org denied"   # bin/cleat:14250
  clt -T 300 -- egress test registry.npmjs.org
  expect_rc "test registry.npmjs.org for box main: rc 1" 1
  expect_contains "it reads x deny for box main" "x deny    registry.npmjs.org:443   the gateway's matcher, box main"   # bin/cleat:14021
  cl -- egress --list
  grep_lines 'registry\.npmjs\.org'
  expect_count "the global policy still allows registry.npmjs.org" 'registry\.npmjs\.org' eq 1

  # Read the npm row and the Hosts block, then Esc. With registry.npmjs.org blocked for this box
  # the npm row is no longer among the first rows of the packs pane (rd-2b: the snapshot held
  # github, github-objects and github-raw), so "Find a pack" brings it up, as 2.15h finds rust.
  # Esc on the list cancels whether a filter is set or not (bin/cleat:17052-17056).
  p31_ed_begin
  xp_sleep 200
  xp_snap rows
  xp_send "<down>"; xp_wait fh '\x1b\[J' 20
  xp_send "<space>"; xp_wait findp 'Find a pack >' 20
  xp_send "npm"
  xp_wait typed 'Find a pack >(\x1b\[[0-9;]*m)* npm' 10
  xp_send "<enter>"; xp_wait ff '\x1b\[J' 20
  xp_sleep 200
  xp_snap npmrow
  p31_ed_quit
  clt --prog -n e-rows -T 300 -- egress main
  expect_contains "Esc on the box editor: Nothing saved" "▸ Nothing saved."   # bin/cleat:17056
  o="$OUT"
  xsnap rows
  record_value step21e.hosts "$(LC_ALL=C sed -n '/Hosts (space ticks)/,/Add a host/p' "$OUT" 2>/dev/null | tr '\n' '|')" "the Hosts block"
  xsnap npmrow
  expect_match "Find a pack shows the npm row" '\] npm '   # bin/cleat:16070,16144-16162
  record_value step21e.npmrow "$(LC_ALL=C grep -E '\] npm ' "$OUT" 2>/dev/null | head -n 1)" "the npm row with registry.npmjs.org blocked for this box"
  OUT="$o"
  clt --answer eg-drop=y -T 300 -- egress main --inherit
  expect_contains "the box's own file is dropped" "✔ Box main now inherits the global egress policy."   # bin/cleat:14790
  clt -T 300 -- egress deny npm
  expect_contains "deny npm takes the pack out" "pack npm removed"   # bin/cleat:14225

  # The mode: the box editor's open goes through cleat egress open and the session marker.
  p31_ed_begin
  xp_send "<right>"; xp_wait fr1 '\x1b\[J' 20
  xp_send "<right>"; xp_wait fr2 '\x1b\[J' 20
  xp_sleep 200
  xp_snap mode
  xp_send "<enter>"
  xp_wait opensession 'Open for this session only\.' 60
  # bin/cleat:13468 prints the box name in bold: the wait reads the plain words after it (rd-2b).
  xp_wait opened 'until it stops\. Every destination is logged' 120
  xp_eof 60
  clt --prog -n e-open -T 600 --answer eg-open=y -- egress main
  o="$OUT"
  expect_contains "the review reads Open for this session only." "Open for this session only." "$o"   # bin/cleat:17313
  expect_contains "it asks default no" "Open egress for this box until it stops? [y/N]" "$o"   # bin/cleat:17315
  expect_contains "the yes opens box main until it stops" "✔ Open for box main until it stops." "$o"   # bin/cleat:13468
  xsnap mode
  expect_match "the Mode row reads open" 'Mode +‹ open ›'   # bin/cleat:16055
  OUT="$o"
  run_cmd -t 30 -- p31_ls_paths "$CFG/egress-boxes/"
  expect_line "the session marker: cleat-eg-smoke-<8 hex>.session, as cleat egress open writes" "$box.session"   # bin/cleat:13348
  record_value step21e.marker "$(tr '\n' ' ' < "$OUT" 2>/dev/null)" "ls of egress-boxes after the open"
  clt -T 300 -- stop
  p31_launch eg-smoke "cleat resume" resume2-2.21e
  p31_exit eg-smoke exit-2.21e
  run_cmd -t 60 -- bconnect eg-smoke example.org:443
  first_lines 1
  expect_contains "the box is up again and strict: the 403" "HTTP/1.1 403 cleat egress: example.org is not on the allowlist"   # gateway.py:197,230

  # Last: Esc, then Ctrl-C mid-screen, then the optional TERM from another terminal.
  p31_ed_begin
  p31_ed_quit
  clt --prog -n e-esc -T 300 -- egress main
  expect_contains "Esc: Nothing saved" "▸ Nothing saved."   # bin/cleat:17056
  record_value step21e.exit_esc "rc $RC" "the Esc exit"
  p31_ed_begin
  xp_send "<ctrl-c>"
  xp_wait end '__MT_TTY_END__ rc=' 30
  xp_eof 15
  clt --prog -n e-ctrlc --wrap-stty -T 300 -- egress main
  record_value step21e.exit_ctrlc "$(LC_ALL=C sed -n 's/.*__MT_TTY_END__ rc=\([0-9]*\).*/\1/p' "$OUT" 2>/dev/null | head -n 1)" "cleat's exit code after Ctrl-C"
  o="$RAW"
  run_cmd -q -t 30 -- p31_stty_part "$OUT"
  expect_match "Ctrl-C: the terminal echoes again (stty: echo)" '(^|[[:space:]])echo([[:space:]]|$)'
  expect_not_match "Ctrl-C: echo is not off" '(^|[[:space:]])-echo([[:space:]]|$)'
  expect_match "Ctrl-C: the terminal is line-buffered again (stty: icanon)" '(^|[[:space:]])icanon([[:space:]]|$)'
  run_cmd -q -t 30 -- p31_rawseq "$o"
  expect_contains "Ctrl-C: the cursor is visible (the last cursor sequence is ESC [?25h)" "last25=h"
  # T3's pkill -TERM, anchored on the cleat process's own argv (header comment).
  p31_ed_begin
  xp_host "pkill -TERM -f '^$MT_BASH $MT_WT/bin/cleat egress main\$'"
  xp_wait end '__MT_TTY_END__ rc=' 30
  xp_eof 15
  clt --prog -n e-term --wrap-stty -T 300 -- egress main
  record_value step21e.exit_term "$(LC_ALL=C sed -n 's/.*__MT_TTY_END__ rc=\([0-9]*\).*/\1/p' "$OUT" 2>/dev/null | head -n 1)" "cleat's exit code after the TERM"
  if [ "${DRY:-0}" != 1 ] && [ "$(xstatus host.1.rc)" != 0 ]; then
    check_note "the optional pkill found no cleat egress main process (rc $(xstatus host.1.rc)): the TERM case is not measured"
  else
    o="$RAW"
    run_cmd -q -t 30 -- p31_stty_part "$OUT"
    expect_match "TERM: the terminal echoes again (stty: echo)" '(^|[[:space:]])echo([[:space:]]|$)'
    expect_match "TERM: the terminal is line-buffered again (stty: icanon)" '(^|[[:space:]])icanon([[:space:]]|$)'
    run_cmd -q -t 30 -- p31_rawseq "$o"
    expect_contains "TERM: the cursor is visible again" "last25=h"
  fi
}

# ---------------------------------------------------------------------------------------------
# 2.22 Held hosts and review (EXTRA)
# ---------------------------------------------------------------------------------------------
st_2_22() {
  local bak
  p31_cd eg-smoke
  p31_smoke_load
  p31_docker_off
  bak="$SCRATCH/mt-pin.bak"
  # Re-entry: the live pin still reads rev 0 from an earlier attempt: the backup goes back first.
  if [ "${DRY:-0}" != 1 ] && [ -f "$bak" ] && [ -f "$CFG/egress-pins/global" ] && LC_ALL=C grep -q '^catalogue_rev = 0$' "$CFG/egress-pins/global"; then
    check_note "an earlier attempt left the pin at rev 0: mt-pin.bak goes back first"
    cat "$bak" > "$CFG/egress-pins/global" 2>/dev/null || true
  fi
  p31_need_up eg-smoke resume-2.22
  if run_cmd -q -t 90 -- box_claude_live eg-smoke; then p31_exit eg-smoke exit-2.22-pre; fi
  on_cleanup "p31_drop_pack npm"
  clt -T 300 -- egress allow npm
  # cleat shell, exit at once: the gate re-pins silently at rev 1.
  xshell eg-smoke --answer trust-caps=n
  run_cmd -t 60 -- p31_pin_grep registry.npmjs.org "$CFG/egress-pins/global"
  expect_match "the pin names registry.npmjs.org" '^host = registry\.npmjs\.org '
  record_value step22.pin "$(head -n 1 "$OUT" 2>/dev/null)" "the pin line for registry.npmjs.org"
  if [ "${DRY:-0}" != 1 ]; then
    LC_ALL=C grep -q '^catalogue_rev = 1$' "$CFG/egress-pins/global" || step_abort "the pin does not read catalogue_rev = 1: the edit below would do nothing"
    cp "$CFG/egress-pins/global" "$bak" || step_abort "cannot back up the pin to $bak"
    on_cleanup "p31_pin_restore"
    file_edit "$CFG/egress-pins/global" 's/^catalogue_rev = 1$/catalogue_rev = 0/'
    file_edit "$CFG/egress-pins/global" '/^host = registry.npmjs.org /d'
  fi
  p31_launch eg-smoke "cleat" launch-2.22 "+1 new host in pack \"npm\" held. Run cleat egress review."   # bin/cleat:10702
  cl -- egress status
  grep_lines_after 'Held:' 1
  expect_match "the status Held row names registry.npmjs.org (new)" 'Held: +registry\.npmjs\.org \(new\)'   # bin/cleat:14752
  run_cmd -t 60 -- bconnect eg-smoke registry.npmjs.org:443
  first_lines 1
  expect_match "the held host is refused: a 403" '^HTTP/1\.1 403 '   # gateway.py:230
  cl -- egress review
  expect_contains "review on a pipe refuses, needs a terminal" "cleat egress review widens what boxes may reach, so it needs a terminal."   # bin/cleat:13043
  expect_rc "review on a pipe: rc 1" 1
  clt --answer eg-review=y -T 300 -- egress review
  expect_match "review lists the held host and its pack" '\+ +registry\.npmjs\.org +pack npm'   # bin/cleat:13030
  expect_contains "it asks default no" "Accept these and re-pin? [y/N]"   # bin/cleat:13047
  expect_contains "review re-pins at rev 1" "✔ Re-pinned at catalogue rev 1."   # bin/cleat:13054
  run_cmd -e -t 60 -- bget eg-smoke https://registry.npmjs.org/
  expect_line "registry.npmjs.org answers 200 after the re-pin" "200"
  clt -T 300 -- egress deny npm
  expect_contains "deny npm takes the pack out" "pack npm removed"   # bin/cleat:14225
  p31_exit eg-smoke exit-2.22
}

# ---------------------------------------------------------------------------------------------
# 2.23 The session-end report in full (EXTRA)
# ---------------------------------------------------------------------------------------------
st_2_23() {
  local box pyf rebind specs
  p31_cd eg-smoke
  p31_smoke_load
  p31_docker_off
  rebind=$(kv_get rebind.filtered "")
  if [ -z "$rebind" ]; then
    # 2.21a did not run in this run: the same dig, read again.
    run_cmd -t 120 -- p31_dig 10-0-0-1.sslip.io 169-254-169-254.sslip.io
    if [ "${DRY:-0}" != 1 ] && ! LC_ALL=C grep -q -E '(^|[^0-9])10\.0\.0\.1([^0-9]|$)' "$OUT"; then rebind=yes; else rebind=no; fi
    kv_set rebind.filtered "$rebind"
  fi
  record_value step23.rebind "$rebind" "whether the sslip.io names were rebind-filtered"
  on_cleanup "( cd $(printf '%q' "$P/eg-smoke") && cl -q -- egress deny 10-0-0-1.sslip.io >/dev/null 2>&1 ) || true"
  p31_launch eg-smoke "cleat" launch-2.23
  run_cmd -e -t 60 -- bget eg-smoke https://example.org/
  run_cmd -e -t 60 -- bget eg-smoke https://sentry.io/
  run_cmd -t 60 -- bconnect eg-smoke example.com:8443
  first_lines 1
  record_value step23.port "$(head -n 1 "$OUT" 2>/dev/null)" "the port-8443 CONNECT (a non-443 refusal)"
  clt -T 300 -- egress allow 10-0-0-1.sslip.io
  run_cmd -e -t 60 -- bget eg-smoke https://10-0-0-1.sslip.io/
  # The scenario's Python: CONNECT api.anthropic.com (200), then a TLS handshake for example.org.
  pyf="$SCRATCH/mt-23.py"
  cat > "$pyf" <<'PY'
import socket, ssl
s = socket.create_connection(("127.0.0.1", 3128), timeout=10)
s.sendall(b"CONNECT api.anthropic.com:443 HTTP/1.1\r\nHost: api.anthropic.com:443\r\n\r\n")
print(s.recv(4096).split(b"\r\n")[0].decode())
try:
    ssl.create_default_context().wrap_socket(s, server_hostname="example.org"); print("HANDSHAKE COMPLETED: FAIL")
except ssl.SSLError as e:
    print("refused:", e.reason)
PY
  on_cleanup "safe_rm $(printf '%q' "$pyf")"
  val box -t 60 -- cn eg-smoke
  run_cmd -i "$pyf" -t 60 -- p31_py23 "$box"
  expect_contains "the tunnel to api.anthropic.com is established" "HTTP/1.1 200 Connection Established" "$OUT"
  expect_contains "the SNI-mismatch handshake is refused" "refused: TLSV1_ALERT_ACCESS_DENIED" "$OUT"
  expect_not_contains "the handshake never completes" "HANDSHAKE COMPLETED" "$OUT"
  # The report (bin/cleat:20654-20720). The security rows print the host and the time, the policy
  # rows the host and its pack: a host followed by HH:MM:SS is a security row.
  if [ "$rebind" = yes ]; then
    p31_exit eg-smoke end-2.23 \
      "+✖ 1 connection was refused because the handshake did not match the tunnel" \
      "+Your policy did not cause this.       cleat egress log --refused" \
      "~! [0-9]+ destinations were denied by egress policy this session" \
      "+1 connection on a port other than 443 was refused." \
      "+cleat egress log     every denial with timestamps"
  else
    if t_have_capture; then
      specs="~^ +example\\.org +[0-9]{2}:[0-9]{2}:[0-9]{2}\$"
    else
      specs="+example.org (the SNI refusal row, with the time)"
    fi
    p31_exit eg-smoke end-2.23 \
      "+✖ 2 connections were refused by the gateway's own checks, not your policy" \
      "+10-0-0-1.sslip.io" \
      "$specs" \
      "+Your policy did not cause this.       cleat egress log --refused" \
      "~! [0-9]+ destinations were denied by egress policy this session" \
      "+1 connection on a port other than 443 was refused." \
      "+cleat egress log     every denial with timestamps"
  fi
  record_value step23.report "$(tr '\n' '|' < "$OUT" 2>/dev/null | cut -c1-400)" "the session-end report as printed"
  clt -T 300 -- egress deny 10-0-0-1.sslip.io
}

# ---------------------------------------------------------------------------------------------
# The registry, in scenario order
# ---------------------------------------------------------------------------------------------
reg 2.15-pre   2 mixed  gate  st_2_15_pre   "A running caged box with a session"
reg 2.15a      2 expect extra st_2_15a      "Listing"
reg 2.15b      2 expect gate  st_2_15b      "A reload never replaces the gateway"
reg 2.15c      2 expect extra st_2_15c      "A hand edit, then reload"
reg 2.15d      2 auto   gate  st_2_15d      "The policy bind on macOS"
reg 2.15e      2 auto   extra st_2_15e      ".Source on a symlinked path"
reg 2.15f      2 expect extra st_2_15f      "The policy language"
reg 2.15g      2 mixed  gate  st_2_15g      "The widening notice"
reg 2.15h      2 expect gate  st_2_15h      "Two terminals"
reg 2.15i      2 expect extra st_2_15i      "Real tool traffic"
reg 2.16a      2 auto   gate  st_2_16a      "The relay: one death heals"
reg 2.16b      2 mixed  gate  st_2_16b      "The relay: a dead supervisor is named"
reg 2.16c      2 mixed  gate  st_2_16c      "The relay: report, shell, --shim heal"
reg 2.17-pre   2 mixed  gate  st_2_17_pre   "A running box, no session"
reg 2.17a      2 auto   extra st_2_17a      "A crash Docker restarts"
reg 2.17b      2 expect extra st_2_17b      "The gateway removed, box running"
reg 2.17c      2 mixed  extra st_2_17c      "The gateway removed, box stopped"
reg 2.17d      2 mixed  gate  st_2_17d      "An orphan, then a resume (W5)"
reg 2.17e      2 mixed  gate  st_2_17e      "The host loses its network (W10)"
reg 2.18a      2 auto   gate  st_2_18a      "Fork exhaustion, no traffic (W2)"
reg 2.18b      2 auto   gate  st_2_18b      "Fork exhaustion, traffic (W2)"
reg 2.19       2 auto   extra st_2_19       "The storm without exhaustion"
reg 2.20a      2 expect gate  st_2_20a      "Interlocks: the docker cap, off a terminal"
reg 2.20b      2 expect gate  st_2_20b      "Interlocks on a terminal, box running (W1)"
reg 2.20c      2 expect gate  st_2_20c      "Interlocks on a terminal, box stopped (W1)"
reg 2.20d      2 mixed  gate  st_2_20d      "ssh and hooks"
reg 2.20-hooks 2 mixed  extra st_2_20_hooks "Claim void, the hooks escape"
reg 2.21a      2 mixed  gate  st_2_21a      "Open for one session"
reg 2.21b      2 expect gate  st_2_21b      "Off for one box"
reg 2.21c      2 mixed  gate  st_2_21c      "Back on (W9)"
reg 2.21d      2 mixed  extra st_2_21d      "Open for every box"
reg 2.21e      2 mixed  gate  st_2_21e      "The box editor"
reg 2.22       2 mixed  extra st_2_22       "Held hosts and review"
reg 2.23       2 mixed  extra st_2_23       "The session-end report in full"
