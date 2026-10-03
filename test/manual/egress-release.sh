#!/bin/bash
#
# egress-release.sh: the egress control release test, driven step by step on the Mac.
#
# It runs every check a command can make and asks you only for what a person must do or judge:
# a Claude Code session, a key pass, a browser sign-in, a lid. Each step is recorded by a stable
# id in a run directory, so a run spans days and survives a quit, a Ctrl-C, a crash or an edit of
# this script. The scenario it follows is EGRESS-RELEASE-TEST.md (the authority). The design is the
# release-test notes' DESIGN.md.
#
# THE SAFETY MODEL
#   1. Test state only. Every test project lives under ~/mt-egress, every cleat call uses the
#      isolated config ~/mt-egress-xdg (or ~/mt-egress-xdg-up). Your ~/.config/cleat is only read,
#      to prove it gained no [egress] section.
#   2. Nothing global. cleat stop-all, nuke, clean, prune and docker prune never run. docker rm,
#      stop, kill, tag and rmi run only through fenced helpers that accept test objects alone.
#   3. Every delete is fenced: the physical path must lie inside the test's own places.
#   4. The candidate is guarded: before every step HEAD must be the certified commit, the tracked
#      tree clean and no test lock held. Only the script's own files (this file and
#      egress-release.d/) may change mid-run, committed or not: a script fix changes no code under
#      test. The script never commits, pushes or tags.
#   5. A running run is immune to edits: each invocation copies this file and its parts into the
#      run directory and runs the copy. An edit applies at the next invocation.
#
# USING IT
#   ./egress-release.sh --preflight     go or no-go, changes nothing (under a minute)
#   ./egress-release.sh                 start a new run (or show the current one)
#   ./egress-release.sh --resume        continue the current run where it stopped
#   ./egress-release.sh --status        every step: PASS, FAIL, SKIP, ERROR, pending
#   ./egress-release.sh --report        a redacted report to paste into a chat
#   ./egress-release.sh --help          every flag and every override
#
# Exit codes: 0 done (or stopped at a sitting boundary), 1 a refusal or NO-GO, 2 usage,
# 3 stopped by the stop rule, 10 saved and quit (q), 130 Ctrl-C.

mt_usage() {
  cat <<'MT__USAGE_EOF'
Usage: ./egress-release.sh [flags]

The egress control release test on the Mac. Run it in Terminal.app (T2). It opens T1 itself
when osascript may control Terminal, otherwise it tells you what to type there.

Flags
  --help                 this text
  --list                 the steps: id, sitting, kind, class, part, status, title
  --preflight            the go or no-go table. Changes nothing. Exit 0 all GO or WARN, 1 a NO-GO
  --status               each step's status in the current run (or --run ID)
  --report               write report.md in the run dir (redacted) and print it
  --new                  start a new run. Refused while objects of an earlier attempt exist
  --resume               continue the current run at its first unfinished step
  --run ID               use run ID instead of the current one
  --sitting N            only sitting N (0, 1, 2, 3, 5). Alone it means --resume --sitting N
  --only ID[,ID]         run exactly these steps, as new attempts (globs allowed: --only '2.24*')
  --from ID              run every selected step from ID on, finished ones included
  --skip GLOB[,GLOB]     record SKIP for these steps without running them
  --extras               include the EXTRA steps (default: release gates only)
  --dry-run              walk the selection without touching Docker, cleat or the Mac
  --override-stop-rule   let sitting 2 start although a sitting 1 gate failed (recorded)

Overrides (every one has a default: the Mac run needs none)
  MT_WT               the candidate checkout (default: the checkout holding this script)
  MT_BASH             the bash cleat runs under (default /bin/bash)
  MT_IMAGE            the box image name (default cleat)
  MT_EXPECT_ENGINE    the engine kind the run must read (default desktop-macos)
  MT_NO_HOST_CONTROL  1: never osascript, networksetup, pmset or open. Those become your steps
  MT_SIM_HOST         1 (with MT_NO_HOST_CONTROL=1): simulate Docker Desktop quit, Wi-Fi, lid
  MT_ANSWERS          a file of scripted answers (GLOB ANSWER [NOTE] per line). Nothing reads the terminal
  MT_ANSWERS_DEFAULT  the answer no line matches (default s)
  MT_T1_AUTO          1: T1 and T3 are simulated by a background expect driver
  MT_T1_TYPE          0: never type into T1 with osascript
  MT_MIN_SLEEP_MINS   3.3's minimum sleep (default 60)
  MT_MIN_NIGHT_HOURS  3.4's minimum span (default 8)
  MT_RESULTS          where run directories live (default ~/mt-egress-results)

Exit codes: 0 done, 1 refusal or NO-GO, 2 usage, 3 stop rule, 10 saved and quit, 130 Ctrl-C.
MT__USAGE_EOF
}

mt__die() { printf '%s\n' "$*" >&2; exit 1; }
mt__usage_err() { printf 'egress-release.sh: %s\n' "$*" >&2; printf 'See ./egress-release.sh --help\n' >&2; exit 2; }

# ---------------------------------------------------------------------------------------------
# Run directory, lock, run.env
# ---------------------------------------------------------------------------------------------

mt__current_id() {
  local c="$MT_RESULTS/current" p
  [ -e "$c" ] || return 1
  p=$(cd -P "$c" 2>/dev/null && pwd -P) || return 1
  printf '%s\n' "${p##*/}"
}
mt__set_current() {
  local tmp="$MT_RESULTS/.current.$$"
  rm -f "$tmp"
  ln -s "$1" "$tmp" || return 1
  if ! mv -fh "$tmp" "$MT_RESULTS/current" 2>/dev/null; then
    mv -fT "$tmp" "$MT_RESULTS/current" 2>/dev/null || { rm -f "$tmp"; ln -sfn "$1" "$MT_RESULTS/current"; }
  fi
  rm -f "$tmp"
}
mt__lock_take() {
  local d="$RUN/lock" opid ohost ostart me
  me=$(uname -n 2>/dev/null)
  if mkdir "$d" 2>/dev/null; then
    printf '%s %s %s\n' "$$" "$me" "$(date -u +%s)" > "$d/owner"
    return 0
  fi
  read -r opid ohost ostart < "$d/owner" 2>/dev/null
  if [ "${opid:-}" = "$$" ]; then return 0; fi
  # Alive means a process with that pid that is this script. After a reboot or a crash the pid
  # may belong to anything else, which holds no lock.
  if [ -n "${opid:-}" ] && [ "${ohost:-}" = "$me" ] && kill -0 "$opid" 2>/dev/null \
     && ps -o command= -p "$opid" 2>/dev/null | grep -q -e 'egress-release'; then
    mt__die "Run $RUNID is in use by process $opid on this machine (since $(mt__epoch_fmt "${ostart:-0}" '+%Y-%m-%d %H:%M') UTC). One invocation at a time: wait for it to end, or end it (kill $opid). A lock it leaves behind goes with: rm -rf \"$d\""
  fi
  if [ -n "${ohost:-}" ] && [ "$ohost" != "$me" ]; then
    mt__die "Run $RUNID is locked by $ohost (process ${opid:-?}). If no run is active there, remove $d and try again."
  fi
  printf 'Taking over the lock of run %s from process %s, which is gone.\n' "$RUNID" "${opid:-unknown}"
  printf '%s %s %s\n' "$$" "$me" "$(date -u +%s)" > "$d/owner"
}
mt__lock_release() {
  local d="${RUN:-}/lock" opid rest
  [ -n "${RUN:-}" ] && [ -f "$d/owner" ] || return 0
  read -r opid rest < "$d/owner" 2>/dev/null
  if [ "${opid:-}" = "$$" ]; then rm -f "$d/owner"; rmdir "$d" 2>/dev/null; fi
  return 0
}
mt__env_was_set() {
  case " $MT__ENVSET " in *" $1 "*) return 0 ;; esac
  return 1
}
mt__runenv_write() {
  local v
  : > "$RUN/run.env"
  for v in $MT__PINNED; do
    eval "mt__runenv_set \"$v\" \"\${$v:-}\""
  done
  mt__runenv_set cand_sha "$(GIT_OPTIONAL_LOCKS=0 git -C "$MT_WT" rev-parse HEAD 2>/dev/null)"
  mt__runenv_set created "$(utc_stamp)"
  mt__runenv_set override_stop_rule "$MT__F_OVERRIDE"
}
mt__runenv_check() {
  local v rec now
  for v in $MT__PINNED; do
    mt__runenv_has "$v" || continue
    rec=$(mt__runenv_get "$v")
    if mt__env_was_set "$v"; then
      eval "now=\"\${$v:-}\""
      if [ "$now" != "$rec" ]; then
        mt__die "This run was started with $v=$rec. This invocation says ${now:-an empty value}. Unset it or pass the same value."
      fi
    fi
  done
}
mt__runenv_load() {
  local v rec
  for v in $MT__PINNED; do
    mt__runenv_has "$v" || continue
    rec=$(mt__runenv_get "$v")
    eval "$v=\$rec"
  done
}
mt__new_run() {
  local id n=0 left
  left=$(mt__leftovers)
  if [ -n "$left" ]; then
    printf 'An earlier attempt left test objects behind:\n%s\n' "$left" >&2
    if id=$(mt__current_id 2>/dev/null); then
      mt__die "Fix: ./egress-release.sh --only 3.5 --run $id   (or remove them as 3.5 lists, never a gateway you cannot place)"
    fi
    mt__die "No earlier run is left in $MT_RESULTS to clean them up. Fix: remove them by hand as 3.5 of the scenario lists (never a gateway you cannot place), then run --new again."
  fi
  mkdir -p "$MT_RESULTS" || mt__die "Cannot create $MT_RESULTS"
  while :; do
    id=$(date -u +%Y%m%d-%H%M%S)
    [ -e "$MT_RESULTS/$id" ] || break
    n=$((n + 1)); [ "$n" -lt 5 ] || mt__die "Cannot make a new run id in $MT_RESULTS"
    sleep 1
  done
  RUNID="$id"; RUN="$MT_RESULTS/$id"
  mkdir -p "$RUN/code" "$RUN/steps" "$RUN/scratch" "$RUN/t" || mt__die "Cannot create $RUN"
  chmod 700 "$RUN"
  mt__runenv_write
  printf '%s\n' "$MT__RES_HEADER" > "$RUN/results.tsv"
  : > "$RUN/kv"
  : > "$RUN/readings.txt"
  mt__set_current "$id"
  printf 'New run %s in %s\n' "$RUNID" "$RUN"
}
# Objects an earlier attempt may have left (5.2 item 11, the part a new run refuses on).
# [files]: the host paths only (preflight, when Docker does not answer).
mt__leftovers() {
  local P0="$HOME/mt-egress" E0="$HOME/mt-egress-xdg" U0="$HOME/mt-egress-xdg-up"
  [ -e "$P0" ] && printf '  %s\n' "$P0"
  [ -e "$E0" ] && printf '  %s\n' "$E0"
  [ -e "$U0" ] && printf '  %s\n' "$U0"
  [ "${1:-}" = files ] && return 0
  command -v docker > /dev/null 2>&1 || return 0
  MT__CMDDIR="${MT__TMPD:-$MT_RESULTS}"
  mt__probe 30 docker ps -a --filter "name=^cleat-eg-" --format '{{.Names}}' && [ -s "$MT__PROBE_OUT" ] && sed 's/^/  container /' "$MT__PROBE_OUT"
  mt__probe 30 docker ps -a --filter label=sh.cleat.role=gateway --format '{{.Names}}' && [ -s "$MT__PROBE_OUT" ] && sed 's/^/  gateway /' "$MT__PROBE_OUT"
  mt__probe 30 docker volume ls -q --filter label=sh.cleat.role=egress-sock && [ -s "$MT__PROBE_OUT" ] && sed 's/^/  socket volume /' "$MT__PROBE_OUT"
  mt__probe 30 docker image inspect "$MT_IMAGE:mt-spec6" --format '{{.Id}}' && printf '  image %s:mt-spec6\n' "$MT_IMAGE"
  return 0
}

# ---------------------------------------------------------------------------------------------
# Loading the parts
# ---------------------------------------------------------------------------------------------

mt__load() {
  # DIR: bash -n every file, then source the library and the parts in name order
  local d="$1" f err
  for f in "$d/egress-release.d/00-lib.sh" "$d"/egress-release.d/[1-9][0-9]-*.sh; do
    [ -f "$f" ] || continue
    if ! err=$("$BASH" -n "$f" 2>&1); then
      printf 'A syntax error in %s:\n%s\nNothing ran. Fix the file and run the same command again.\n' "${f##*/}" "$err" >&2
      exit 1
    fi
  done
  [ -f "$d/egress-release.d/00-lib.sh" ] || mt__die "No library at $d/egress-release.d/00-lib.sh"
  MT__PART=00-lib.sh
  # shellcheck source=/dev/null
  . "$d/egress-release.d/00-lib.sh"
  for f in "$d"/egress-release.d/[1-9][0-9]-*.sh; do
    [ -f "$f" ] || continue
    MT__PART="${f##*/}"
    # shellcheck source=/dev/null
    . "$f"
    mt__reg_check_funcs "$MT__PART"
  done
  MT__PART=""
  if [ -n "$MT__REG_ERRORS" ]; then
    printf 'The step registry has errors:\n%s' "$MT__REG_ERRORS" >&2
    exit 1
  fi
}

# ---------------------------------------------------------------------------------------------
# Selection
# ---------------------------------------------------------------------------------------------

mt__glob_match() {
  # ID GLOBS (comma separated)
  local id="$1" g IFS=,
  set -f
  for g in $2; do
    # shellcheck disable=SC2254
    case "$id" in $g) set +f; return 0 ;; esac
  done
  set +f
  return 1
}
mt__selected() {
  local i="$1"
  if [ -n "$MT__F_SITTING" ] && [ "${R_SIT[$i]}" != "$MT__F_SITTING" ]; then return 1; fi
  if [ -n "$MT__F_ONLY" ]; then mt__glob_match "${R_ID[$i]}" "$MT__F_ONLY"; return; fi
  if [ "${R_CLASS[$i]}" = extra ] && [ "$MT__F_EXTRAS" != 1 ]; then return 1; fi
  if [ -n "$MT__F_FROM" ] && [ "$i" -lt "$MT__FROM_I" ]; then return 1; fi
  return 0
}
mt__check_selection_args() {
  local g i hit
  if [ -n "$MT__F_FROM" ]; then
    MT__FROM_I=$(mt__reg_index "$MT__F_FROM") || mt__usage_err "--from: no step $MT__F_FROM"
  fi
  if [ -n "$MT__F_ONLY" ]; then
    local IFS=,
    set -f
    for g in $MT__F_ONLY; do
      hit=0; i=0
      while [ "$i" -lt "${#R_ID[@]}" ]; do
        # shellcheck disable=SC2254
        case "${R_ID[$i]}" in $g) hit=1 ;; esac
        i=$((i + 1))
      done
      [ "$hit" = 1 ] || { set +f; mt__usage_err "--only: no step matches $g"; }
    done
    set +f
  fi
}

# ---------------------------------------------------------------------------------------------
# Views: --list, --status
# ---------------------------------------------------------------------------------------------

mt__list() {
  local i st
  printf '%-12s %-3s %-7s %-6s %-14s %-11s %s\n' ID SIT KIND CLASS PART STATUS TITLE
  i=0
  while [ "$i" -lt "${#R_ID[@]}" ]; do
    st="${S_STATUS[$i]:-}"
    printf '%-12s %-3s %-7s %-6s %-14s %-11s %s\n' "${R_ID[$i]}" "${R_SIT[$i]}" "${R_KIND[$i]}" "${R_CLASS[$i]}" "${R_PART[$i]}" "${st:--}" "${R_TITLE[$i]}"
    i=$((i + 1))
  done
  [ "${#R_ID[@]}" -gt 0 ] || printf '(no steps registered yet)\n'
}
mt__fmt_epoch() {
  [ -n "$1" ] || { printf '%s' '-'; return 0; }
  mt__epoch_fmt "$1" '+%m-%d %H:%M'
}
mt__status() {
  local sit i st shown cnt
  printf 'Run %s%s  candidate %s\n' "$RUNID" "$( [ "$(mt__current_id 2>/dev/null)" = "$RUNID" ] && printf ' (current)')" "$(kv_get cand.short "$(mt__runenv_get cand_sha | cut -c1-7)")"
  for sit in 0 1 2 3 5; do
    shown=0
    cnt=$(mt__sitting_counts "$sit")
    i=0
    while [ "$i" -lt "${#R_ID[@]}" ]; do
      if [ "${R_SIT[$i]}" = "$sit" ] && { [ -z "$MT__F_SITTING" ] || [ "$MT__F_SITTING" = "$sit" ]; }; then
        if [ "$shown" = 0 ]; then printf '\nSitting %s: %s\n' "$sit" "$cnt"; shown=1; fi
        st="${S_STATUS[$i]}"
        if [ "$st" = pending ] && [ "${R_CLASS[$i]}" = extra ] && [ "$MT__F_EXTRAS" != 1 ]; then st=extra; fi
        printf '  %-12s %-11s %3s  %-11s  %s\n' "${R_ID[$i]}" "$st" "${S_ATT[$i]}" "$(mt__fmt_epoch "${S_END[$i]}")" "${R_TITLE[$i]}"
      fi
      i=$((i + 1))
    done
  done
  printf '\nremoved: %s\n' "${MT__RES_REMOVED:-none}"
  printf 'changed since pass: %s\n' "$(mt__changed_since_pass)"
}
mt__sitting_counts() {
  local i p=0 f=0 s=0 e=0 o=0 n=0
  i=0
  while [ "$i" -lt "${#R_ID[@]}" ]; do
    if [ "${R_SIT[$i]}" = "$1" ] && { [ "${S_STATUS[$i]}" != pending ] || mt__selected "$i"; }; then
      case "${S_STATUS[$i]}" in
        PASS) p=$((p + 1)) ;; FAIL) f=$((f + 1)) ;; SKIP) s=$((s + 1)) ;; ERROR) e=$((e + 1)) ;;
        pending) n=$((n + 1)) ;; *) o=$((o + 1)) ;;
      esac
    fi
    i=$((i + 1))
  done
  printf '%s pass, %s fail, %s error, %s skip, %s unfinished, %s pending' "$p" "$f" "$e" "$s" "$o" "$n"
}
mt__unfinished() {
  # rc 0 when a selected gate step is not terminal
  local i=0
  while [ "$i" -lt "${#R_ID[@]}" ]; do
    if mt__selected "$i" && ! mt__is_terminal "${S_STATUS[$i]}"; then return 0; fi
    i=$((i + 1))
  done
  return 1
}
mt__resume_cmd() {
  local r="" f=""
  [ "$(mt__current_id 2>/dev/null)" = "$RUNID" ] || r=" --run $RUNID"
  # rd-2b: this invocation's selection goes along. A resume without --extras passes over every
  # EXTRA after the cut without a word. A dropped --skip runs what was meant to be skipped.
  [ "${MT__F_EXTRAS:-0}" != 1 ] || f=" --extras"
  [ -z "${MT__F_SKIP:-}" ] || f="$f --skip '$MT__F_SKIP'"
  printf 'cd %s && ./egress-release.sh --resume%s%s' "${MT__REPO_DIR:-$MT__SCRIPT_DIR}" "$f" "$r"
}
# mt__rest_hint ID: when this invocation ran a list (--only) or a range (--from) and ID was cut, the
# command that runs the rest of it. --resume alone runs ID again, then goes on to the next unfinished
# step of the run, so the later steps of the list keep the results they had before this invocation.
mt__rest_hint() {
  local id="$1" i ids="" r="" f=""
  [ -n "$MT__F_ONLY$MT__F_FROM" ] || return 0
  i=$(mt__reg_index "$id") || return 0
  [ "$(mt__current_id 2>/dev/null)" = "$RUNID" ] || r=" --run $RUNID"
  [ -z "$MT__F_SKIP" ] || f=" --skip '$MT__F_SKIP'"
  while [ "$i" -lt "${#R_ID[@]}" ]; do
    if mt__selected "$i"; then ids="${ids:+$ids,}${R_ID[$i]}"; fi
    i=$((i + 1))
  done
  # Nothing selected after ID: --resume alone finishes the list.
  case "$ids" in *,*) ;; *) return 0 ;; esac
  if [ -n "$MT__F_FROM" ]; then
    [ "$MT__F_EXTRAS" != 1 ] || f="$f --extras"
    [ -z "$MT__F_SITTING" ] || f="$f --sitting $MT__F_SITTING"
    printf '%s runs %s again, then goes on to the next unfinished step. The steps after %s keep their earlier results.\n' "--resume" "$id" "$id"
    printf 'To run every step from %s on again instead:  cd %s && ./egress-release.sh --from %s%s%s\n' "$id" "${MT__REPO_DIR:-$MT__SCRIPT_DIR}" "$id" "$f" "$r"
    return 0
  fi
  printf '%s runs %s again, then goes on to the next unfinished step. The rest of this --only list keeps its earlier results.\n' "--resume" "$id"
  printf 'To finish the list instead:  cd %s && ./egress-release.sh --only %s%s%s\n' "${MT__REPO_DIR:-$MT__SCRIPT_DIR}" "$ids" "$f" "$r"
}

# ---------------------------------------------------------------------------------------------
# A step
# ---------------------------------------------------------------------------------------------

# A hangup (T2's window closed, Terminal quit) reaches the whole foreground group. tee ignores it
# (below). Both traps ignore PIPE: a write to a pipe whose reader is gone fails instead of killing
# the step before its cleanups (wifi_on after wifi_off) have run.
mt__step_exit() {
  local rc=$?
  trap '' INT TERM HUP PIPE
  trap - EXIT
  mt__kill_job
  mt__run_cleanups "$STEP_DIR"
  exit "$rc"
}
mt__step_int() {
  trap '' INT TERM HUP PIPE
  printf '\nInterrupted: stopping what runs and running the step'"'"'s cleanups.\n'
  : > "$STEP_DIR/.interrupted"
  mt__kill_job
  exit 130
}
# mt__derive DIR RC: MT__D_ST, MT__D_NOTE, MT__D_NCHK, MT__D_NFAIL.
mt__derive() {
  local d="$1" rc="$2" endnote="" diag counts np
  [ -f "$d/.end" ] && endnote=$(cut -f2- "$d/.end" | head -1)
  diag=$(cat "$d/transcript.txt" "$d"/cmd-*.raw "$d"/cmd-*.rawerr "$d"/probe.raw "$d"/probe.rawerr 2>/dev/null \
    | LC_ALL=C awk -v p="$MT__SCRIPT_DIR/" 'index($0, p) == 1 && / line [0-9]+: / { print; n++; if (n >= 3) exit }')
  counts=$(awk -F'\t' '{ n++ } $2 == "FAIL" || $2 == "TIMEOUT" || $2 == "HUMAN-FAIL" { f++; if (first == "") first = $3 }
      $2 == "PASS" || $2 == "HUMAN-PASS" || $2 == "VALUE" { p++ }
      END { printf "%d\t%d\t%d\t%s\n", n, f, p, first }' "$d/checks.tsv" 2>/dev/null)
  [ -n "$counts" ] || counts=$(printf '0\t0\t0\t')
  MT__D_NCHK=$(printf '%s' "$counts" | cut -f1); MT__D_NFAIL=$(printf '%s' "$counts" | cut -f2)
  np=$(printf '%s' "$counts" | cut -f3)
  MT__D_NOTE=""
  if [ "$rc" = 130 ] || [ -f "$d/.interrupted" ]; then MT__D_ST=INTERRUPTED; MT__D_NOTE="interrupted (Ctrl-C)"; return 0; fi
  if [ "$rc" = 10 ]; then MT__D_ST=INTERRUPTED; MT__D_NOTE="${endnote:-quit}"; return 0; fi
  if [ -n "$diag" ]; then
    MT__D_ST=ERROR
    MT__D_NOTE="bash: $(printf '%s' "$diag" | head -1 | sed "s|^$MT__SCRIPT_DIR/||")"
    return 0
  fi
  case "$rc" in
    0)
      if [ "${MT__D_NFAIL:-0}" -gt 0 ]; then MT__D_ST=FAIL; MT__D_NOTE="$MT__D_NFAIL of $MT__D_NCHK checks failed: $(printf '%s' "$counts" | cut -f4)"
      elif [ "${np:-0}" -gt 0 ]; then MT__D_ST=PASS
      else MT__D_ST=SKIP; MT__D_NOTE="nothing was checked"; fi
      [ "${DRY:-0}" = 1 ] && { MT__D_ST=DRY; MT__D_NOTE="dry run"; } ;;
    3) MT__D_ST=FAIL; MT__D_NOTE="aborted: $endnote" ;;
    4) MT__D_ST=SKIP; MT__D_NOTE="$endnote" ;;
    *) MT__D_ST=ERROR
       MT__D_NOTE="${endnote:-$(LC_ALL=C grep -v '^[[:space:]]*$' "$d/transcript.txt" 2>/dev/null | tail -n 1)}"
       MT__D_NOTE="rc $rc: $MT__D_NOTE" ;;
  esac
}
mt__dur() {
  local s="$1"
  printf '%dm%02ds' $((s / 60)) $((s % 60))
}
mt__run_step() {
  local i="$1" id func att dir start rc hash t1
  id="${R_ID[$i]}"; func="${R_FUNC[$i]}"
  while :; do
    att=$(( ${S_ATT[$i]:-0} + 1 ))
    dir="$RUN/steps/$id/a$att"
    mkdir -p "$dir"
    hash=$(mt__hash "$func")
    start=$(epoch_now)
    mt__res_append "$id" "$att" STARTED "$start" "" "$hash" "steps/$id/a$att/transcript.txt" ""
    S_ATT[$i]=$att; S_LASTATT[$i]=$att; S_STATUS[$i]=STARTED
    MT__CUR_I=$i; MT__CUR_ID=$id; MT__CUR_ATT=$att; MT__CUR_DIR=$dir; MT__CUR_START=$start; MT__CUR_HASH=$hash; MT__CUR_OPEN=1
    printf '\n%s==== [%s] %s  (%s, %s, attempt %s) ====%s\n' "$MT__C_BOLD" "$id" "${R_TITLE[$i]}" "${R_CLASS[$i]}" "${R_KIND[$i]}" "$att" "$MT__C_RESET"
    (
      set -u
      STEP_ID="$id"; STEP_DIR="$dir"; ATTEMPT="$att"; STEP_TITLE="${R_TITLE[$i]}"
      MT__JOBPID=""; MT__WDPID=""; MT__BGPIDS=""; MT__IN_JOB=0; HOSTACT=""
      RC=0; OUT=""; ERR=""; RAW=""; CMDREF=""; TIMEDOUT=0
      trap 'mt__step_exit' EXIT
      trap 'mt__step_int' INT TERM HUP
      cd "$HOME" || exit 1
      "$func"
      exit 0
    ) 2>&1 | ( trap '' INT HUP; exec tee -a "$dir/transcript.txt" )
    rc=${PIPESTATUS[0]}
    mt__derive "$dir" "$rc"
    t1=$(epoch_now)
    if [ "$MT__D_ST" = INTERRUPTED ] && [ "$rc" != 10 ]; then mt__main_int; fi
    mt__res_append "$id" "$att" "$MT__D_ST" "$start" "$t1" "$hash" "steps/$id/a$att/transcript.txt" "$MT__D_NOTE"
    MT__CUR_OPEN=0
    S_STATUS[$i]="$MT__D_ST"; S_HASH[$i]="$hash"; S_END[$i]="$t1"; S_NOTE[$i]="$MT__D_NOTE"
    [ -n "${S_START[$i]:-}" ] || S_START[$i]="$start"
    # 5.5 writes report.md while it runs, so that copy lists 5.5 itself as STARTED (a cut step to
    # a reader) and counts it under Other. Written again now that 5.5 has its result, in a subshell
    # (report_write reloads the results into the arrays this loop still uses).
    if [ "$id" = 5.5 ] && [ "${DRY:-0}" != 1 ] && [ -f "$RUN/report.md" ]; then
      case "$MT__D_ST" in PASS|FAIL) ( report_write "$RUN/report.md" ) > /dev/null 2>&1 || : ;; esac
    fi
    case "$MT__D_ST" in
      PASS|DRY) printf '%s[%s] %s  %s checks  %s%s\n' "$MT__C_GREEN" "$id" "$MT__D_ST" "$MT__D_NCHK" "$(mt__dur $((t1 - start)))" "$MT__C_RESET" ;;
      FAIL)
        printf '%s[%s] FAIL  %s%s\n' "$MT__C_RED" "$id" "$MT__D_NOTE" "$MT__C_RESET"
        awk -F'\t' '$2 == "FAIL" || $2 == "TIMEOUT" || $2 == "HUMAN-FAIL" { print "      " $3 }' "$dir/checks.tsv" 2>/dev/null ;;
      SKIP) printf '[%s] SKIP  %s\n' "$id" "$MT__D_NOTE" ;;
      *) printf '%s[%s] %s  %s%s\n' "$MT__C_AMBER" "$id" "$MT__D_ST" "$MT__D_NOTE" "$MT__C_RESET" ;;
    esac
    case "$MT__D_ST" in
      INTERRUPTED)
        printf '\nSaved at %s (%s). Resume with:  %s\n' "$id" "$MT__D_NOTE" "$(mt__resume_cmd)"
        mt__rest_hint "$id"
        exit 10 ;;
      ERROR)
        if [ "${DRY:-0}" = 1 ]; then return 0; fi
        printf '\nThe step crashed. The last 30 lines of its transcript:\n'
        tail -n 30 "$dir/transcript.txt" | sed 's/^/  | /'
        printf 'Transcript: %s\n' "$dir/transcript.txt"
        if [ -f "$dir/cleanups" ]; then printf 'Cleanups it registered (all ran unless listed below):\n'; sed 's/^/  /' "$dir/cleanups"; mt__cleanup_pending "$dir" | sed 's/^/  NOT RUN: /'; fi
        MT__ASK_ID="$id"
        choose error "What now?" "r=run it again now, from its start" "s=skip it (recorded SKIP)" "q=quit (it stays ERROR)"
        MT__ASK_ID=""
        case "$CHOICE" in
          r) continue ;;
          s) mt__res_append "$id" "$att" SKIP "$start" "$(epoch_now)" "$hash" "steps/$id/a$att/transcript.txt" "skipped after ERROR"
             S_STATUS[$i]=SKIP; S_NOTE[$i]="skipped after ERROR"
             return 0 ;;
          *) printf 'Resume with:  %s\n' "$(mt__resume_cmd)"; exit 1 ;;
        esac ;;
      FAIL)
        if [ "${R_SIT[$i]}" = 1 ] && [ "${R_CLASS[$i]}" = gate ] && [ "$(mt__runenv_get override_stop_rule)" != 1 ] && [ "${DRY:-0}" != 1 ]; then
          mt__stop_rule_msg
          MT__ASK_ID="$id"
          choose stop-rule "Stop now, or finish sitting 1 for more evidence (the run still stops before sitting 2)?" "q=stop now" "c=finish sitting 1"
          MT__ASK_ID=""
          [ "$CHOICE" = c ] || exit 3
        fi
        return 0 ;;
    esac
    return 0
  done
}
mt__stop_rule_hit() {
  local i=0
  while [ "$i" -lt "${#R_ID[@]}" ]; do
    if [ "${R_SIT[$i]}" = 1 ] && [ "${R_CLASS[$i]}" = gate ]; then
      case "${S_STATUS[$i]}" in FAIL|ERROR) return 0 ;; esac
      [ "${S_STATUS[$i]}" = SKIP ] && [ "${S_NOTE[$i]}" = "skipped after ERROR" ] && return 0
    fi
    i=$((i + 1))
  done
  return 1
}
mt__stop_rule_msg() {
  local i=0
  printf '\n%sStop rule: a FAIL in sitting 1 ends the run. Report it and wait for a fix.%s\n' "$MT__C_RED" "$MT__C_RESET"
  while [ "$i" -lt "${#R_ID[@]}" ]; do
    if [ "${R_SIT[$i]}" = 1 ] && [ "${R_CLASS[$i]}" = gate ]; then
      case "${S_STATUS[$i]}" in FAIL|ERROR|SKIP) [ "${S_STATUS[$i]}" = SKIP ] && [ "${S_NOTE[$i]}" != "skipped after ERROR" ] || printf '  %s %s: %s\n' "${R_ID[$i]}" "${S_STATUS[$i]}" "${S_NOTE[$i]}" ;; esac
    fi
    i=$((i + 1))
  done
  printf 'Then: ./egress-release.sh --report\n'
}
mt__sitting_summary() {
  local sit="$1" i=0
  printf '\n%s==== Sitting %s: %s ====%s\n' "$MT__C_BOLD" "$sit" "$(mt__sitting_counts "$sit")" "$MT__C_RESET"
  while [ "$i" -lt "${#R_ID[@]}" ]; do
    if [ "${R_SIT[$i]}" = "$sit" ]; then
      case "${S_STATUS[$i]}" in FAIL|ERROR) printf '  %s %s: %s\n' "${R_ID[$i]}" "${S_STATUS[$i]}" "${S_NOTE[$i]}" ;; esac
    fi
    i=$((i + 1))
  done
}
# mt__boundary FROM TO: the summary, the stop rule and the question before the next sitting.
mt__boundary() {
  local from="$1" to="$2" warn=""
  mt__sitting_summary "$from"
  [ "${DRY:-0}" = 1 ] && return 0
  if [ "$to" -ge 2 ] && [ "$to" -le 3 ] && mt__stop_rule_hit && [ "$(mt__runenv_get override_stop_rule)" != 1 ]; then
    mt__stop_rule_msg
    exit 3
  fi
  if [ "$to" = 3 ]; then
    warn=" Sitting 3 quits Docker Desktop, which ends every session on this Mac, your daily boxes included. Keep-awake must be off for 3.3 and 3.4$( [ -n "${MT__CAFF_PID:-}" ] && printf ' (the script'"'"'s own caffeinate stops by itself before 3.0)')."
  fi
  MT__ASK_ID="sitting-$to"
  choose next-sitting "Sitting $from is done. Go on to sitting $to?$warn" "y=go on" "q=stop here (resume later)"
  MT__ASK_ID=""
  if [ "$CHOICE" = q ]; then
    printf 'Stopped before sitting %s. Resume with:  %s\n' "$to" "$(mt__resume_cmd)"
    exit 0
  fi
}

# ---------------------------------------------------------------------------------------------
# Interrupts and exit
# ---------------------------------------------------------------------------------------------

mt__main_int() {
  trap '' INT TERM HUP
  local pend="" cut=""
  if [ "${MT__CUR_OPEN:-0}" = 1 ]; then
    cut="$MT__CUR_ID"
    mt__res_append "$MT__CUR_ID" "$MT__CUR_ATT" INTERRUPTED "$MT__CUR_START" "$(epoch_now)" "$MT__CUR_HASH" "steps/$MT__CUR_ID/a$MT__CUR_ATT/transcript.txt" "interrupted (Ctrl-C)"
    MT__CUR_OPEN=0
    pend=$(mt__cleanup_pending "$MT__CUR_DIR" | awk 'END { print NR + 0 }')
    if [ "$pend" = 0 ]; then
      printf '\nInterrupted in %s (attempt %s). Its cleanups ran. Transcript: %s\n' "$MT__CUR_ID" "$MT__CUR_ATT" "$MT__CUR_DIR/transcript.txt"
    else
      printf '\nInterrupted in %s (attempt %s). %s of its cleanups did not run: --resume offers them. Transcript: %s\n' "$MT__CUR_ID" "$MT__CUR_ATT" "$pend" "$MT__CUR_DIR/transcript.txt"
    fi
  else
    printf '\nInterrupted.\n'
  fi
  printf 'Resume with:  %s\n' "$(mt__resume_cmd)"
  [ -z "$cut" ] || mt__rest_hint "$cut"
  exit 130
}
mt__main_exit() {
  local rc=$?
  trap - EXIT
  [ -n "${MT__STTY:-}" ] && { stty "$MT__STTY" < /dev/tty; } 2>/dev/null
  [ -z "${MT__CAFF_PID:-}" ] || kill -TERM "$MT__CAFF_PID" 2>/dev/null
  if [ -n "${RUN:-}" ] && [ -n "${INV:-}" ] && [ -d "$RUN" ] && [ "${DRY:-0}" != 1 ]; then
    printf 'inv %s end %s rc=%s\n' "$INV" "$(date -u '+%Y-%m-%d %H:%M:%S')" "$rc" >> "$RUN/invocations.log" 2>/dev/null
  fi
  mt__lock_release
  [ -n "${MT__TMPD:-}" ] && [ -d "$MT__TMPD" ] && rm -rf "${MT__TMPD:?}"
  exit "$rc"
}

# ---------------------------------------------------------------------------------------------
# Resume: the cleanup journal, changed code, the resume question
# ---------------------------------------------------------------------------------------------

mt__resume_prelude() {
  # MODE: the cleanup journal always, the changed-code question in resume mode only
  local mode="$1" i d pend
  i=0
  while [ "$i" -lt "${#R_ID[@]}" ]; do
    case "${S_STATUS[$i]}" in
      STARTED|INTERRUPTED|ERROR)
        d="$RUN/steps/${R_ID[$i]}/a${S_LASTATT[$i]}"
        pend=$(mt__cleanup_pending "$d")
        if [ -n "$pend" ]; then
          printf '\n%s (attempt %s) was cut before these cleanups ran:\n' "${R_ID[$i]}" "${S_LASTATT[$i]}"
          printf '%s\n' "$pend" | cut -f2- | sed 's/^/  /'
          MT__ASK_ID="${R_ID[$i]}"
          choose pending-cleanup "Run them now?" "y=run them now" "n=leave them"
          MT__ASK_ID=""
          if [ "$CHOICE" = y ]; then
            ( STEP_ID="${R_ID[$i]}"; STEP_DIR="$d"; STEP_TITLE="${R_TITLE[$i]}"; ATTEMPT="${S_LASTATT[$i]}"; mt__run_cleanups "$d" )
          fi
        fi ;;
    esac
    i=$((i + 1))
  done
  [ "$mode" = resume ] || return 0
  local now keepall=0
  i=0
  while [ "$i" -lt "${#R_ID[@]}" ]; do
    if [ "${S_STATUS[$i]}" = PASS ] && mt__selected "$i" && [ -n "${S_HASH[$i]}" ]; then
      now=$(mt__hash "${R_FUNC[$i]}")
      if [ "$now" != "${S_HASH[$i]}" ]; then
        if [ "$keepall" = 1 ]; then
          CHOICE=n
          printf '%s passed with different code: the pass is kept (a).\n' "${R_ID[$i]}"
        else
          printf '\n%s passed with different code (hash %s, now %s).\n' "${R_ID[$i]}" "${S_HASH[$i]}" "$now"
          printf 'Running it again happens at its own place in the order. A step run out of order checks its own\npreconditions and may fail on state a later step changed.\n'
          MT__ASK_ID="${R_ID[$i]}"
          choose --default n rerun-changed "Run ${R_ID[$i]} again?" "n=keep the pass" "y=run it again" "a=keep this pass and every other changed one"
          MT__ASK_ID=""
        fi
        case "$CHOICE" in
          y)
            mt__res_append "${R_ID[$i]}" "${S_ATT[$i]}" RESET "$(epoch_now)" "$(epoch_now)" "${S_HASH[$i]}" "" "code changed since the pass"
            S_STATUS[$i]=RESET ;;
          *)
            [ "$CHOICE" = a ] && keepall=1
            mt__keep_pass "$i" "$now" ;;
        esac
      fi
    fi
    i=$((i + 1))
  done
}
# mt__keep_pass I HASH: the pass of step I stands under its changed code. Its PASS line is written
# again with the new hash (its own attempt, times and transcript), so the same edit is not asked
# about at the next resume. A later edit is asked about again.
mt__keep_pass() {
  local i="$1" now="$2" id line t0 t1 trn
  id="${R_ID[$i]}"
  line=$(LC_ALL=C awk -F'\t' -v id="$id" 'NR > 1 && $2 == id && $4 == "PASS" { l = $5 "\t" $6 "\t" $8 } END { print l }' "$RUN/results.tsv" 2>/dev/null)
  t0=$(printf '%s' "$line" | cut -f1); t1=$(printf '%s' "$line" | cut -f2); trn=$(printf '%s' "$line" | cut -f3)
  mt__res_append "$id" "${S_LASTATT[$i]}" PASS "$t0" "$t1" "$now" "$trn" "the pass is kept: its code changed since (was ${S_HASH[$i]})"
  S_HASH[$i]="$now"
}

# ---------------------------------------------------------------------------------------------
# The loop
# ---------------------------------------------------------------------------------------------

# The steps that may start with Docker Desktop quit. 3.1b is one: a --resume into it after its
# quit (a q or Ctrl-C at the session-end question) finds the daemon down. Its own code reads that
# as the earlier quit standing.
MT__DOWN_OK="3.1b 3.1-down 3.1c 3.1e 3.2 3.4dd"
# Keep-awake through sittings 0 to 2. A Mac that idle-sleeps in a long command (0.5's rebuild, a
# bats run) pauses the script's watchdogs but not the expect driver's wall clock. A sleeping
# Docker VM stalls whatever ran in it. caffeinate -i holds an idle-sleep assertion for as long as
# this invocation lives. Sitting 3 needs no assertion held (3.3 and 3.4 sleep the Mac and read
# pmset), so it stops before the first step of sitting 3 and is never started again there.
MT__CAFF_PID=""; MT__CAFF_SAID=0
mt__caff_start() {
  if [ -n "$MT__CAFF_PID" ] && kill -0 "$MT__CAFF_PID" 2>/dev/null; then return 0; fi
  MT__CAFF_PID=""
  [ "${IS_MACOS:-0}" = 1 ] || return 0
  if host_can && command -v caffeinate > /dev/null 2>&1; then
    caffeinate -i -w "$$" < /dev/null > /dev/null 2>&1 &
    MT__CAFF_PID=$!
    [ "$MT__CAFF_SAID" = 1 ] || printf 'The Mac is kept awake while the script runs (caffeinate -i, pid %s), until sitting 3.\n' "$MT__CAFF_PID"
  elif [ "$MT__CAFF_SAID" != 1 ]; then
    printf '%sKeep the Mac awake through sittings 0 to 2 (Amphetamine, or caffeinate -i in another terminal): a Mac that sleeps during a long command ends it as a timeout. Turn it off before sitting 3.%s\n' "$MT__C_AMBER" "$MT__C_RESET"
  fi
  MT__CAFF_SAID=1
  return 0
}
mt__caff_stop() {
  [ -n "${MT__CAFF_PID:-}" ] || return 0
  kill -TERM "$MT__CAFF_PID" 2>/dev/null
  { wait "$MT__CAFF_PID"; } 2>/dev/null
  MT__CAFF_PID=""
  return 0
}
mt__loop() {
  local mode="$1" i n id st last_sit="" first_run=1 img_checked2=0 img_checked3=0 after_clean=0 walked=0 errors=0 mt__rs
  n=${#R_ID[@]}
  i=0
  while [ "$i" -lt "$n" ]; do
    if ! mt__selected "$i"; then i=$((i + 1)); continue; fi
    id="${R_ID[$i]}"; st="${S_STATUS[$i]}"
    if [ "$mode" = resume ] && mt__is_terminal "$st"; then i=$((i + 1)); continue; fi
    if [ -n "$last_sit" ] && [ "${R_SIT[$i]}" -gt "$last_sit" ]; then mt__boundary "$last_sit" "${R_SIT[$i]}"; fi
    last_sit="${R_SIT[$i]}"
    if [ -n "$MT__F_SKIP" ] && mt__glob_match "$id" "$MT__F_SKIP"; then
      mt__res_append "$id" "$(( ${S_ATT[$i]:-0} + 1 ))" SKIP "$(epoch_now)" "$(epoch_now)" "" "" "skipped by --skip"
      S_ATT[$i]=$(( ${S_ATT[$i]:-0} + 1 )); S_STATUS[$i]=SKIP; S_NOTE[$i]="skipped by --skip"
      printf '[%s] SKIP  skipped by --skip\n' "$id"
      i=$((i + 1)); continue
    fi
    # the stop rule holds sittings 2 and 3. The sign-off (5) may still write its record and decision.
    if [ "${R_SIT[$i]}" -ge 2 ] && [ "${R_SIT[$i]}" -le 3 ] && [ "${DRY:-0}" != 1 ] && mt__stop_rule_hit && [ "$(mt__runenv_get override_stop_rule)" != 1 ]; then
      mt__stop_rule_msg
      exit 3
    fi
    if [ "$mode" = resume ] && [ "${DRY:-0}" != 1 ]; then
      case "$st" in
        STARTED|INTERRUPTED|ERROR)
          MT__ASK_ID="$id"
          if [ "$st" = STARTED ]; then mt__rs="$id was cut while it ran (no result was written)"
          else mt__rs="$id ended $st last time ($(mt__oneline "${S_NOTE[$i]:-no note}" 120))"; fi
          choose resume-step "$mt__rs. Run it again from its start?" "r=run it again" "s=skip it (recorded SKIP)" "q=quit"
          MT__ASK_ID=""
          case "$CHOICE" in
            s) mt__res_append "$id" "${S_LASTATT[$i]}" SKIP "$(epoch_now)" "$(epoch_now)" "${S_HASH[$i]}" "" "skipped on resume"
               S_STATUS[$i]=SKIP; S_NOTE[$i]="skipped on resume"
               i=$((i + 1)); continue ;;
            q) printf 'Resume with:  %s\n' "$(mt__resume_cmd)"; exit 10 ;;
          esac ;;
      esac
    fi
    if [ "${DRY:-0}" != 1 ]; then
      if [ "${R_SIT[$i]}" -le 2 ]; then mt__caff_start; else mt__caff_stop; fi
      MT__CMDDIR="$RUN/main/inv-$INV"; mkdir -p "$MT__CMDDIR"
      if ! guard_candidate; then exit 1; fi
      if [ "$first_run" = 1 ]; then mt__first_checks "$id" || exit 1; first_run=0; fi
      if { [ "${R_SIT[$i]}" = 2 ] && [ "$img_checked2" = 0 ]; } || { [ "${R_SIT[$i]}" = 3 ] && [ "$img_checked3" = 0 ]; } || [ "$after_clean" = 1 ]; then
        [ "${R_SIT[$i]}" = 2 ] && img_checked2=1
        [ "${R_SIT[$i]}" = 3 ] && img_checked3=1
        after_clean=0
        if ! guard_image; then exit 1; fi
      fi
    else
      if ! guard_candidate > "$RUN/.guard" 2>&1; then printf '[dry] guard_candidate would stop the run here:\n'; sed 's/^/  /' "$RUN/.guard"; fi
    fi
    mt__run_step "$i"
    walked=$((walked + 1))
    [ "${S_STATUS[$i]}" = ERROR ] && errors=$((errors + 1))
    [ "$id" = 2.24-clean ] && after_clean=1
    i=$((i + 1))
  done
  MT__WALKED=$walked; MT__ERRORS=$errors
  [ -n "$last_sit" ] && mt__sitting_summary "$last_sit"
  if [ "$n" = 0 ]; then printf '\nNo steps are registered yet.\n'
  elif [ "$walked" = 0 ]; then printf '\nNothing to run: every selected step is finished. See --status or --report.\n'; fi
  return 0
}
# The cheap checks before the first step of an invocation.
mt__first_checks() {
  local id="$1" rec now
  if ! mt__probe 20 docker info; then
    case " $MT__DOWN_OK " in
      *" $id "*) ;;
      *)
        case "$id" in
          5.*)
            # the sign-off reads the run's own files and gh: it never needs Docker
            printf 'Docker does not answer. The sign-off does not need it.\n' ;;
          *)
            printf 'Docker does not answer.\n'
            wait_for docker-up "Start Docker Desktop and wait for the engine." --auto --timeout 600 --every 3 -- mt__docker_up || { printf 'Docker never answered. Start Docker Desktop, then resume.\n'; return 1; } ;;
        esac ;;
    esac
  fi
  rec=$(kv_get realcfg.egress "")
  if [ -n "$rec" ] && [ -f "$HOME/.config/cleat/config" ]; then
    now=$(grep -c '^\[egress\]' "$HOME/.config/cleat/config" 2>/dev/null)
    if [ "${now:-0}" -gt "$rec" ]; then
      printf 'Your real config gained an [egress] section (%s, was %s at 0.4). The run stops: find what wrote it.\n' "$now" "$rec"
      return 1
    fi
  fi
  return 0
}

# ---------------------------------------------------------------------------------------------
# --preflight
# ---------------------------------------------------------------------------------------------

mt__pf() {
  # CHECK STATUS DETAIL [FIX]
  printf '%-22s %-6s %s\n' "$1" "$2" "$3"
  [ -n "${4:-}" ] && printf '%-22s %-6s fix: %s\n' "" "" "$4"
  case "$2" in NO-GO) MT__PF_NOGO=$((MT__PF_NOGO + 1)) ;; WARN) MT__PF_WARN=$((MT__PF_WARN + 1)) ;; esac
  return 0
}
mt__ver_ge() {
  # A B: version A >= B (major.minor)
  awk -v a="$1" -v b="$2" 'BEGIN { split(a, x, "."); split(b, y, "."); if (x[1] + 0 != y[1] + 0) exit !(x[1] + 0 > y[1] + 0); exit !(x[2] + 0 >= y[2] + 0) }'
}
mt__preflight() {
  local v t f dev iface pw idle sys os kind eng api head want anc a miss=0 dirty left un av sz cols loc rc dok=0 s3 rsha
  MT__PF_NOGO=0; MT__PF_WARN=0
  printf '%-22s %-6s %s\n' CHECK STATUS DETAIL
  # 1 bash
  v=$("$MT_BASH" -c 'printf "%s" "$BASH_VERSION"' 2>/dev/null)
  case "$v" in 3.2.57*) mt__pf "1 bash" GO "$MT_BASH $v" ;; *) mt__pf "1 bash" NO-GO "$MT_BASH ${v:-does not run}" "This run needs the Mac's stock /bin/bash 3.2.57" ;; esac
  # 2 expect
  if command -v expect > /dev/null 2>&1; then
    v=$(expect -v 2>/dev/null | awk '{ print $3 }')
    if mt__ver_ge "${v:-0}" 5.45; then mt__pf "2 expect" GO "expect $v"; else mt__pf "2 expect" WARN "expect ${v:-unknown}, below 5.45"; fi
  else
    mt__pf "2 expect" NO-GO "expect is missing" "macOS ships /usr/bin/expect. If it is gone: brew install expect"
  fi
  # 3 osascript and Automation
  if [ "${MT_NO_HOST_CONTROL:-}" = 1 ]; then
    mt__pf "3 automation" GO "host control off (MT_NO_HOST_CONTROL=1)"
  elif [ "$IS_MACOS" != 1 ]; then
    mt__pf "3 automation" WARN "not macOS: no osascript probe"
  elif ! command -v osascript > /dev/null 2>&1; then
    mt__pf "3 automation" NO-GO "osascript is missing" "set MT_NO_HOST_CONTROL=1 to run the host actions by hand"
  else
    # Terminal only. The one event the run sends Docker Desktop is quit, which macOS never asks
    # consent for (activate, open, open location and quit are exempt). A probe of Docker would
    # guard a permission the run does not need. A Don't Allow there would read as a NO-GO.
    a=Terminal
    mt__probe 60 osascript -e 'tell application "Terminal" to get name of front window'
    rc=$?
    f=$(cat "${MT__PROBE_OUT%.out}.err" 2>/dev/null | head -1)
    if [ "$rc" = 0 ]; then mt__pf "3 automation $a" GO "osascript may control $a"
    elif [ "$rc" = 124 ]; then mt__pf "3 automation $a" NO-GO "no answer in 60 s" "a permission dialog is open: answer it, then run --preflight again"
    else
      case "$f" in
        *-1743*) mt__pf "3 automation $a" NO-GO "not allowed" "System Settings, Privacy and Security, Automation, Terminal: tick Terminal, then run --preflight again" ;;
        *) mt__pf "3 automation $a" GO "consent given ($(mt__oneline "$f" 60))" ;;
      esac
    fi
    mt__pf "3 automation Docker" INFO "not needed: the run only quits Docker Desktop, which needs no consent"
    [ "${MT_T1_TYPE:-1}" = 0 ] && mt__pf "3 T1 typing" GO "off (MT_T1_TYPE=0): you type in T1"
    # T1 typing finds T2 (this terminal) by its tty among Terminal's tabs to bring it back to the
    # front. In another terminal app T2 is never raised: every T1 question then waits behind T1.
    if [ "${TERM_PROGRAM:-}" != Apple_Terminal ]; then
      mt__pf "3 T2 terminal" WARN "this runs in ${TERM_PROGRAM:-an unknown terminal}, not Terminal.app" "run the script in Terminal.app, so each T1 question brings it back to the front"
    fi
  fi
  # 4 networksetup
  if host_can && command -v networksetup > /dev/null 2>&1; then
    mt__probe 30 networksetup -listallhardwareports
    dev=$(awk '/^Hardware Port: Wi-Fi/ { f = 1; next } f && /^Device:/ { print $2; exit }' "$MT__PROBE_OUT")
    if [ -z "$dev" ]; then
      mt__pf "4 wi-fi" WARN "no Wi-Fi port" "1.2-pull and 2.17e will ask you to cut the network by hand"
    else
      iface=$(route -n get default 2>/dev/null | awk '/interface:/ { print $2 }')
      mt__probe 15 networksetup -getairportpower "$dev"
      pw=$(cat "$MT__PROBE_OUT")
      if [ -n "$iface" ] && [ "$iface" != "$dev" ]; then
        mt__pf "4 wi-fi" WARN "Wi-Fi is $dev, the default route uses $iface" "Wi-Fi off will not cut the network: unplug $iface for 1.2-pull and 2.17e"
      else
        case "$pw" in *Off*) mt__pf "4 wi-fi" WARN "$dev is powered off" ;; *) mt__pf "4 wi-fi" GO "$dev, default route ${iface:-unknown}" ;; esac
      fi
    fi
  else
    mt__pf "4 wi-fi" WARN "no host control: Wi-Fi steps are yours"
  fi
  # 5 pmset. Sittings 0 to 2 want the Mac awake (a sleep mid-command reads as a timeout), sitting 3
  # wants nothing held (3.3 and 3.4 sleep it). The next step of the current run decides which.
  s3=0
  if v=$(mt__current_id 2>/dev/null); then
    t=$(mt__pf_current_step)
    [ "$t" != "the next pending" ] || t=$(mt__pf_first_unrecorded "$MT_RESULTS/$v/results.tsv")
    case "$t" in 3.*) s3=1 ;; esac
  fi
  if host_can && command -v pmset > /dev/null 2>&1; then
    mt__probe 60 pmset -g assertions
    idle=$(awk '/^Assertion status system-wide/ { f = 1; next } f && /^[^ \t]/ { f = 0 } f && $1 == "PreventUserIdleSystemSleep" { print $2 }' "$MT__PROBE_OUT")
    sys=$(awk '/^Assertion status system-wide/ { f = 1; next } f && /^[^ \t]/ { f = 0 } f && $1 == "PreventSystemSleep" { print $2 }' "$MT__PROBE_OUT")
    if [ "$s3" = 1 ]; then
      if [ "${idle:-0}" = 0 ] && [ "${sys:-0}" = 0 ]; then mt__pf "5 sleep" GO "no sleep assertion held (sitting 3 needs none)"
      else mt__pf "5 sleep" WARN "PreventUserIdleSystemSleep ${idle:-?}, PreventSystemSleep ${sys:-?}" "sitting 3 needs both at 0: turn keep-awake utilities off before 3.3"; fi
    elif [ "${idle:-0}" != 0 ] || [ "${sys:-0}" != 0 ]; then
      mt__pf "5 sleep" GO "keep-awake held (PreventUserIdleSystemSleep ${idle:-?}): right for sittings 0 to 2. Turn it off before sitting 3"
    elif command -v caffeinate > /dev/null 2>&1; then
      mt__pf "5 sleep" GO "nothing held now: the script keeps the Mac awake itself (caffeinate -i) through sittings 0 to 2"
    else
      mt__pf "5 sleep" WARN "nothing keeps the Mac awake" "keep it awake through sittings 0 to 2 (Amphetamine), turn it off before sitting 3"
    fi
  elif [ "$s3" = 1 ]; then
    mt__pf "5 sleep" WARN "no host control: you read pmset yourself in sitting 3" "turn keep-awake utilities off before 3.3"
  else
    mt__pf "5 sleep" WARN "no host control: the script cannot keep the Mac awake" "keep it awake through sittings 0 to 2 yourself (Amphetamine, or caffeinate -i), turn it off before sitting 3"
  fi
  # 6 Docker
  if mt__probe 20 docker info --format '{{.OperatingSystem}}'; then
    dok=1
    os=$(cat "$MT__PROBE_OUT")
    case "$os" in
      "Docker Desktop"*) mt__pf "6 docker" GO "$os" ;;
      *) mt__pf "6 docker" NO-GO "the engine is $os" "this run needs Docker Desktop" ;;
    esac
    mt__probe 20 docker version --format '{{.Server.Version}} {{.Server.APIVersion}}'
    eng=$(awk '{ print $1 }' "$MT__PROBE_OUT"); api=$(awk '{ print $2 }' "$MT__PROBE_OUT")
    if mt__ver_ge "${eng:-0}" 20.10 && mt__ver_ge "${api:-0}" 1.41; then mt__pf "6 engine" GO "Engine $eng, API $api"
    else mt__pf "6 engine" NO-GO "Engine ${eng:-?}, API ${api:-?}" "egress needs Engine 20.10 and API 1.41 or later"; fi
    mt__probe 60 egkind
    kind=$(tr -d '[:space:]' < "$MT__PROBE_OUT")
    if [ "$kind" = "$MT_EXPECT_ENGINE" ]; then mt__pf "6 engine kind" GO "$kind"
    else mt__pf "6 engine kind" NO-GO "egkind reads ${kind:-nothing}" "this run expects $MT_EXPECT_ENGINE"; fi
  else
    mt__pf "6 docker" NO-GO "docker info does not answer" "start Docker Desktop"
  fi
  # 7 the candidate
  head=$(GIT_OPTIONAL_LOCKS=0 git -C "$MT_WT" rev-parse HEAD 2>/dev/null)
  # The candidate is ac6ee85 (on 68f1153, cbb4297 and 2a831dc). GO for ac6ee85 itself and for
  # ac6ee85 plus the script: later commits that touch only test/manual/egress-release.sh and
  # test/manual/egress-release.d/ (cand_plus_script). GO too for the commit the current run
  # certified at 0.1, with or without such commits on it. Any other later commit asks at 0.1.
  for anc in 2a831dc cbb4297 68f1153 ac6ee85; do
    GIT_OPTIONAL_LOCKS=0 git -C "$MT_WT" merge-base --is-ancestor "$anc" HEAD 2>/dev/null || miss=$((miss + 1))
  done
  if [ "$miss" -gt 0 ]; then mt__pf "7 candidate" NO-GO "HEAD ${head:-?} lacks $miss of 2a831dc cbb4297 68f1153 ac6ee85" "MT_WT is not the candidate"
  else
    want=$(GIT_OPTIONAL_LOCKS=0 git -C "$MT_WT" rev-parse 'ac6ee85^{commit}' 2>/dev/null)
    if [ "$head" = "$want" ]; then mt__pf "7 candidate" GO "HEAD ac6ee85 on $(GIT_OPTIONAL_LOCKS=0 git -C "$MT_WT" rev-parse --abbrev-ref HEAD 2>/dev/null)"
    elif cand_plus_script "$MT_WT" ac6ee85 > /dev/null 2>&1; then
      mt__pf "7 candidate" GO "HEAD $(printf '%s' "$head" | cut -c1-7): ac6ee85 plus the script, on $(GIT_OPTIONAL_LOCKS=0 git -C "$MT_WT" rev-parse --abbrev-ref HEAD 2>/dev/null)"
    elif [ -n "$head" ] && [ "$(mt__pf_run_kv cand.sha)" = "$head" ]; then
      mt__pf "7 candidate" GO "HEAD $(printf '%s' "$head" | cut -c1-7), a later commit the current run certified at 0.1"
    elif rsha=$(mt__pf_run_kv cand.sha) && [ -n "$rsha" ] && cand_plus_script "$MT_WT" "$rsha" > /dev/null 2>&1; then
      # A script fix on the commit 0.1 certified in place of ac6ee85: the guard lets the run go on.
      mt__pf "7 candidate" GO "HEAD $(printf '%s' "$head" | cut -c1-7): $(printf '%s' "$rsha" | cut -c1-7), which the current run certified at 0.1, plus the script"
    else mt__pf "7 candidate" WARN "HEAD $(printf '%s' "$head" | cut -c1-7) is a later commit on ac6ee85 that changes more than the script" "0.1 will ask you to name this commit"; fi
  fi
  dirty=$(cand_tracked_dirty)
  if [ -n "$dirty" ]; then
    mt__pf "7 tracked tree" NO-GO "tracked changes in $MT_WT: $(printf '%s\n' "$dirty" | head -n 3 | tr '\n' ' ')" "commit or restore first"
  else
    mt__pf "7 tracked tree" GO "clean"
  fi
  if [ -e "$MT_WT/bin/cleat-unvalidated" ] || [ -e "$MT_WT/bin/cleat-nogw" ]; then
    case "$(mt__pf_current_step)" in
      2.1|2.24h) mt__pf "7 throwaway copies" WARN "bin/cleat-unvalidated or bin/cleat-nogw present (the current run is inside that step)" ;;
      *) mt__pf "7 throwaway copies" NO-GO "bin/cleat-unvalidated or bin/cleat-nogw present" "remove them" ;;
    esac
  fi
  un=$(git_dirty_untracked | grep -v -e '^?? bin/cleat-unvalidated$' -e '^?? bin/cleat-nogw$')
  if [ -n "$un" ]; then mt__pf "7 untracked" WARN "$(printf '%s' "$un" | awk 'END { print NR }') untracked: $(printf '%s' "$un" | head -3 | tr '\n' ' ')"; fi
  # 8 image name
  v=$(sed -n 's/^IMAGE_NAME="\(.*\)"$/\1/p' "$MT_WT/bin/cleat" | head -1)
  if [ "$v" = "$MT_IMAGE" ]; then mt__pf "8 image name" GO "$v"; else mt__pf "8 image name" NO-GO "the candidate builds ${v:-?}, MT_IMAGE is $MT_IMAGE" "MT_IMAGE must match the candidate's IMAGE_NAME"; fi
  # 9 the gateway image
  # Rows 9 to 11 ask Docker: a daemon that does not answer (row 6) is not asked again, so a hung
  # one cannot stretch the preflight to minutes or read as "nothing left".
  if [ -z "$GWIMG" ]; then
    mt__pf "9 gateway image" NO-GO "no _GATEWAY_IMAGE in bin/cleat" "MT_WT is not the candidate"
  elif [ "$dok" = 0 ]; then
    mt__pf "9 gateway image" WARN "not checked: Docker does not answer (row 6)"
  elif mt__probe 60 docker buildx imagetools inspect "$GWIMG"; then
    mt__pf "9 gateway image" GO "$(printf '%s' "$GWIMG" | cut -c1-60)... resolves"
  elif mt__probe 60 docker manifest inspect "$GWIMG"; then
    mt__pf "9 gateway image" GO "resolves (docker manifest inspect, no buildx)"
  else
    mt__pf "9 gateway image" NO-GO "the digest does not resolve" "check the network and ghcr.io"
  fi
  # 10 disk
  av=$(df -k "$HOME" 2>/dev/null | awk 'NR == 2 { print $4 }')
  if mt__is_int "$av" && [ "$av" -lt 15728640 ]; then mt__pf "10 disk host" WARN "$((av / 1048576)) GB free under $HOME"
  else mt__pf "10 disk host" GO "$(( ${av:-0} / 1048576 )) GB free"; fi
  if [ "$dok" = 0 ]; then
    mt__pf "10 disk VM" WARN "not measured: Docker does not answer (row 6)"
  elif mt__probe 20 docker image inspect alpine --format '{{.Id}}'; then
    mt__probe 60 docker run --rm alpine df -k /
    sz=$(awk 'NR == 2 { print $4 }' "$MT__PROBE_OUT")
    if mt__is_int "$sz" && [ "$sz" -lt 15728640 ]; then mt__pf "10 disk VM" WARN "$((sz / 1048576)) GB free in the Docker VM" "2.24 pulls about 1 GB, 0.5 rebuilds: free some space"
    else mt__pf "10 disk VM" GO "$(( ${sz:-0} / 1048576 )) GB free in the Docker VM"; fi
  else
    mt__pf "10 disk VM" WARN "not measured (no alpine image, preflight pulls nothing)"
  fi
  # 11 leftovers
  if [ "$dok" = 1 ]; then left=$(mt__leftovers); else left=$(mt__leftovers files); fi
  if [ -z "$left" ] && [ "$dok" = 0 ]; then mt__pf "11 leftovers" WARN "no test directory left. Containers, gateways and volumes not checked: Docker does not answer (row 6)"
  elif [ -z "$left" ]; then mt__pf "11 leftovers" GO "none"
  elif [ "$MT__F_RESUME" = 1 ] || [ -n "$MT__F_RUN" ]; then mt__pf "11 leftovers" GO "test objects present, owned by the run you resume"
  elif v=$(mt__current_id 2>/dev/null) && ! LC_ALL=C awk -F'\t' '$2 == "3.5" && $4 ~ /^(PASS|FAIL|SKIP)$/ { f = 1 } END { exit !f }' "$MT_RESULTS/$v/results.tsv" 2>/dev/null; then
    mt__pf "11 leftovers" GO "test objects present, owned by run $v (3.5 has not run yet)"
  elif [ -n "$v" ]; then mt__pf "11 leftovers" NO-GO "an earlier attempt left: $(printf '%s' "$left" | tr '\n' ' ' | cut -c1-200)" "./egress-release.sh --only 3.5 --run $v, or remove them as 3.5 lists"
  else mt__pf "11 leftovers" NO-GO "an earlier attempt left: $(printf '%s' "$left" | tr '\n' ' ' | cut -c1-200)" "no earlier run is left to clean them up: remove them by hand as 3.5 of the scenario lists"; fi
  if [ "$dok" = 1 ] && mt__probe 20 docker image inspect ghcr.io/cleatdev/cleat:v1.5.4 --format '{{.Id}}'; then mt__pf "11 v1.5.4 image" WARN "ghcr.io/cleatdev/cleat:v1.5.4 is present (rule 3's refresh target)"; fi
  if [ -f "$HOME/mt-eg-env.sh" ]; then
    mt__env_render "$MT__TMPD/env.want"
    if cmp -s "$MT__TMPD/env.want" "$HOME/mt-eg-env.sh"; then mt__pf "11 env file" GO "~/mt-eg-env.sh is what 0.2 writes"
    else mt__pf "11 env file" WARN "~/mt-eg-env.sh differs from what 0.2 writes (0.2 overwrites it)"; fi
  fi
  # 12 test lock
  if [ -e "$MT_WT/.test-suite.lock" ]; then mt__pf "12 test lock" NO-GO "$MT_WT/.test-suite.lock exists" "a suite or the harness runs in the checkout: wait, or read .test-suite.lock/owner and remove a stale lock"
  else mt__pf "12 test lock" GO "none"; fi
  # 13 terminal
  if cols=$( { stty size < /dev/tty; } 2>/dev/null ); then
    cols="${cols##* }"
    if mt__is_int "$cols" && [ "$cols" -lt 80 ]; then mt__pf "13 terminal" WARN "$cols columns, fewer than 80"; else mt__pf "13 terminal" GO "${cols} columns"; fi
  elif [ -n "${MT_ANSWERS:-}" ]; then
    mt__pf "13 terminal" GO "no terminal, MT_ANSWERS answers"
  else
    mt__pf "13 terminal" NO-GO "no terminal" "run it in Terminal.app"
  fi
  # 14 locale
  loc="${LC_ALL:-}${LC_CTYPE:-}${LANG:-}"
  case "$loc" in *[Uu][Tt][Ff]-8*|*[Uu][Tt][Ff]8*) mt__pf "14 locale" GO "UTF-8" ;; *) mt__pf "14 locale" WARN "no UTF-8 locale" "2.13's paste check expects a UTF-8 locale (Terminal.app sets one by default)" ;; esac
  # 15 real config
  v=0
  [ -f "$HOME/.config/cleat/config" ] && v=$(grep -c '^\[egress\]' "$HOME/.config/cleat/config" 2>/dev/null)
  if [ "${v:-0}" = 0 ]; then mt__pf "15 real config" GO "no [egress] section"
  else mt__pf "15 real config" NO-GO "your real config holds $v [egress] section(s)" "your real config holds a policy: this run must start without one"; fi
  # 16 tools
  dirty=""
  [ "$(id -u)" = 0 ] && dirty="root "
  command -v git > /dev/null 2>&1 || dirty="${dirty}no-git "
  command -v curl > /dev/null 2>&1 || dirty="${dirty}no-curl "
  if [ -z "$dirty" ]; then mt__pf "16 user and tools" GO "not root, git and curl present"; else mt__pf "16 user and tools" NO-GO "$dirty" "run as yourself with git and curl installed"; fi
  # 17 run state
  if v=$(mt__current_id 2>/dev/null); then
    t=$(mt__pf_current_step)
    [ "$t" != "the next pending" ] || t=$(mt__pf_first_unrecorded "$MT_RESULTS/$v/results.tsv")
    mt__pf "17 run" INFO "current run $v, next step $t"
  else
    mt__pf "17 run" INFO "no run yet"
  fi
  printf '\n%s NO-GO, %s WARN. %s\n' "$MT__PF_NOGO" "$MT__PF_WARN" "$( [ "$MT__PF_NOGO" = 0 ] && printf 'GO.' || printf 'Fix the NO-GO rows first.')"
  [ "$MT__PF_NOGO" = 0 ]
}
# mt__pf_run_kv KEY: KEY from the current run's kv file (empty when there is no run or no key).
mt__pf_run_kv() {
  local id f
  id=$(mt__current_id 2>/dev/null) || return 0
  f="$MT_RESULTS/$id/kv"
  [ -f "$f" ] || return 0
  LC_ALL=C awk -F'\t' -v k="$1" '$1 == k { v = substr($0, length(k) + 2) } END { if (v != "__mt_deleted__") print v }' "$f" 2>/dev/null
  return 0
}
# mt__pf_first_unrecorded RESULTS: the first registered step whose last result is not PASS, FAIL or
# SKIP (an EXTRA too: a resume without --extras passes over it).
mt__pf_first_unrecorded() {
  local fin i=0
  fin=" $(awk -F'\t' 'NR > 1 { st[$2] = $4 } END { for (k in st) if (st[k] ~ /^(PASS|FAIL|SKIP)$/) printf "%s ", k }' "$1" 2>/dev/null)"
  while [ "$i" -lt "${#R_ID[@]}" ]; do
    case "$fin" in
      *" ${R_ID[$i]} "*) ;;
      *) printf '%s%s' "${R_ID[$i]}" "$( [ "${R_CLASS[$i]}" = extra ] && printf ' (EXTRA)')"; return 0 ;;
    esac
    i=$((i + 1))
  done
  printf 'none: every step has a result'
}
mt__pf_current_step() {
  # the current run's first unfinished gate, without loading it for real
  local id f
  id=$(mt__current_id 2>/dev/null) || { printf 'none'; return 0; }
  f="$MT_RESULTS/$id/results.tsv"
  [ -f "$f" ] || { printf 'the first'; return 0; }
  awk -F'\t' 'NR > 1 { st[$2] = $4; if (!($2 in seen)) { seen[$2] = 1; o[++n] = $2 } }
    END { for (i = 1; i <= n; i++) if (st[o[i]] !~ /^(PASS|FAIL|SKIP)$/) { print o[i]; exit } print "the next pending" }' "$f"
}

# ---------------------------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------------------------

mt_main() {
  set -u
  local v mode
  MT__ENVSET=""
  for v in MT_WT MT_BASH MT_IMAGE MT_EXPECT_ENGINE MT_NO_HOST_CONTROL MT_SIM_HOST MT_ANSWERS MT_ANSWERS_DEFAULT MT_T1_AUTO MT_T1_TYPE MT_MIN_SLEEP_MINS MT_MIN_NIGHT_HOURS; do
    eval "[ \"\${$v+x}\" = x ]" && MT__ENVSET="$MT__ENVSET $v"
  done
  MT__SELF="${BASH_SOURCE[0]}"
  case "$MT__SELF" in /*) ;; *) MT__SELF="$PWD/$MT__SELF" ;; esac
  MT__SCRIPT_DIR=$(cd "$(dirname "$MT__SELF")" && pwd) || mt__die "Cannot find the script's directory"
  [ "${MT__KEEP_PATH:-}" = 1 ] || PATH="/bin:/usr/bin:/usr/sbin:/sbin:$PATH"
  MT__F_HELP=0; MT__F_LIST=0; MT__F_PRE=0; MT__F_STATUS=0; MT__F_REPORT=0; MT__F_NEW=0; MT__F_RESUME=0
  MT__F_RUN=""; MT__F_SITTING=""; MT__F_ONLY=""; MT__F_FROM=""; MT__F_SKIP=""; MT__F_EXTRAS=0; MT__F_DRY=0; MT__F_OVERRIDE=0
  MT__ARGV=("$@")
  while [ $# -gt 0 ]; do
    case "$1" in
      --help|-h) MT__F_HELP=1; shift ;;
      --list) MT__F_LIST=1; shift ;;
      --preflight) MT__F_PRE=1; shift ;;
      --status) MT__F_STATUS=1; shift ;;
      --report) MT__F_REPORT=1; shift ;;
      --new) MT__F_NEW=1; shift ;;
      --resume) MT__F_RESUME=1; shift ;;
      --run) [ $# -ge 2 ] || mt__usage_err "--run needs a run id"; MT__F_RUN="$2"; shift 2 ;;
      --sitting)
        [ $# -ge 2 ] || mt__usage_err "--sitting needs 0, 1, 2, 3 or 5"
        case "$2" in 0|1|2|3|5) ;; *) mt__usage_err "--sitting needs 0, 1, 2, 3 or 5, not $2" ;; esac
        MT__F_SITTING="$2"; shift 2 ;;
      --only) [ $# -ge 2 ] || mt__usage_err "--only needs step ids"; MT__F_ONLY="$2"; shift 2 ;;
      --from) [ $# -ge 2 ] || mt__usage_err "--from needs a step id"; MT__F_FROM="$2"; shift 2 ;;
      --skip) [ $# -ge 2 ] || mt__usage_err "--skip needs step globs"; MT__F_SKIP="$2"; shift 2 ;;
      --extras) MT__F_EXTRAS=1; shift ;;
      --dry-run) MT__F_DRY=1; shift ;;
      --override-stop-rule) MT__F_OVERRIDE=1; shift ;;
      *) mt__usage_err "unknown argument: $1" ;;
    esac
  done
  if [ "$MT__F_HELP" = 1 ]; then mt_usage; exit 0; fi
  [ "$(( MT__F_LIST + MT__F_PRE + MT__F_STATUS + MT__F_REPORT + MT__F_DRY ))" -le 1 ] || mt__usage_err "--list, --preflight, --status, --report and --dry-run go alone"
  [ -z "$MT__F_ONLY" ] || [ -z "$MT__F_FROM" ] || mt__usage_err "--only and --from conflict: choose one"
  [ "$MT__F_NEW" = 0 ] || [ "$MT__F_RESUME" = 0 ] || mt__usage_err "--new and --resume conflict"
  [ "$MT__F_NEW" = 0 ] || [ -z "$MT__F_RUN" ] || mt__usage_err "--new makes its own run id: drop --run"
  [ "$MT__F_DRY" = 0 ] || [ "$(( MT__F_NEW + MT__F_RESUME ))" = 0 ] || mt__usage_err "--dry-run makes its own run dir: drop --new and --resume"
  [ "$(id -u)" != 0 ] || mt__die "Refusing to run as root."
  [ -t 1 ] && MT__COLOR=1
  MT__COLOR="${MT__COLOR:-0}"
  export MT__COLOR

  if [ -n "${MT__INV:-}" ]; then mt__main_copy; exit $?; fi

  MT__TMPD=$(mktemp -d "${TMPDIR:-/tmp}/mt-egress.XXXXXX") || mt__die "Cannot make a temporary directory"
  trap 'mt__main_exit' EXIT
  MT__CODE_DIR="$MT__TMPD/code"; mkdir -p "$MT__CODE_DIR"
  RUN="$MT__TMPD/run"; mkdir -p "$RUN"; RUNID=none; INV=0; DRY=0
  mt__load "$MT__SCRIPT_DIR"
  mt_resolve_overrides
  [ -f "$MT_WT/bin/cleat" ] || mt__die "MT_WT=$MT_WT holds no bin/cleat. Set MT_WT to the candidate checkout."
  GIT_OPTIONAL_LOCKS=0 git -C "$MT_WT" rev-parse --is-inside-work-tree > /dev/null 2>&1 || mt__die "MT_WT=$MT_WT is not a git work tree."
  v=$("$MT_BASH" -c 'printf "%s" "$BASH_VERSION"' 2>/dev/null)
  [ -n "$v" ] || mt__die "MT_BASH=$MT_BASH does not run or prints no version."
  mt_lib_init
  MT__CMDDIR="$MT__TMPD/cmd"; mkdir -p "$MT__CMDDIR"

  if [ "$MT__F_LIST" = 1 ]; then
    mt__view_run_resolve quiet && mt__res_load
    [ -n "${S_STATUS+x}" ] || mt__res_load_empty
    mt__list
    exit 0
  fi
  if [ "$MT__F_PRE" = 1 ]; then mt__preflight; exit $?; fi
  if [ "$MT__F_DRY" = 1 ]; then mt__dry; exit $?; fi
  if [ "$MT__F_STATUS" = 1 ] || [ "$MT__F_REPORT" = 1 ]; then
    mt__view_run_resolve || exit 1
    mt_lib_init
    mt__res_load
    if [ "$MT__F_STATUS" = 1 ]; then mt__status; exit 0; fi
    report_write "$RUN/report.md"
    cat "$RUN/report.md"
    printf '\n(written to %s)\n' "$RUN/report.md"
    exit 0
  fi

  # A run-touching invocation: resolve the run, lock it, check run.env, copy the code, re-exec.
  local cur=""
  cur=$(mt__current_id 2>/dev/null) || cur=""
  mode=""
  if [ "$MT__F_NEW" = 1 ]; then mode=new
  elif [ -n "$MT__F_RUN" ]; then mode=run
  elif [ "$MT__F_RESUME" = 1 ] || [ -n "$MT__F_ONLY" ] || [ -n "$MT__F_FROM" ] || [ -n "$MT__F_SITTING" ]; then mode=current
  elif [ -z "$cur" ]; then mode=new
  else mode=show
  fi
  case "$mode" in
    new)
      mt__new_run ;;
    run|current)
      if [ "$mode" = run ]; then RUNID="$MT__F_RUN"; else RUNID="$cur"; fi
      [ -n "$RUNID" ] || mt__die "There is no run to resume. Start one with: ./egress-release.sh --new"
      RUN="$MT_RESULTS/$RUNID"
      [ -d "$RUN" ] && [ -f "$RUN/results.tsv" ] || mt__die "No run $RUNID in $MT_RESULTS."
      ;;
    show)
      RUNID="$cur"; RUN="$MT_RESULTS/$RUNID"
      mt__runenv_load
      mt_lib_init
      mt__res_load
      mt__status
      if mt__unfinished; then
        printf '\nThis run is not finished. Continue it with:  ./egress-release.sh --resume\n'
      else
        printf '\nThis run is finished. Start another with:  ./egress-release.sh --new\n'
      fi
      exit 1 ;;
  esac
  mt__lock_take
  mt__runenv_check
  if [ "$MT__F_OVERRIDE" = 1 ] && [ "$(mt__runenv_get override_stop_rule)" != 1 ]; then mt__runenv_set override_stop_rule 1; fi
  local k=1 d f
  while [ -e "$RUN/code/inv-$k" ]; do k=$((k + 1)); done
  d="$RUN/code/inv-$k"
  mkdir -p "$d/egress-release.d" || mt__die "Cannot write $d"
  cp "$MT__SCRIPT_DIR/egress-release.sh" "$d/egress-release.sh" || mt__die "Cannot copy the script into $d"
  for f in "$MT__SCRIPT_DIR"/egress-release.d/*.sh; do cp "$f" "$d/egress-release.d/" || mt__die "Cannot copy $f"; done
  chmod 0555 "$d/egress-release.sh" "$d"/egress-release.d/*.sh
  MT__INV=$k; MT__REPO_DIR="$MT__SCRIPT_DIR"; MT__RUN="$RUN"
  export MT__INV MT__REPO_DIR MT__RUN
  [ -n "${MT__TMPD:-}" ] && rm -rf "${MT__TMPD:?}"
  trap - EXIT
  exec "$BASH" "$d/egress-release.sh" ${MT__ARGV[@]+"${MT__ARGV[@]}"}
}
mt__res_load_empty() {
  local i=0
  S_STATUS=(); S_ATT=(); S_NOTE=()
  while [ "$i" -lt "${#R_ID[@]}" ]; do S_STATUS[$i]=""; S_ATT[$i]=0; S_NOTE[$i]=""; i=$((i + 1)); done
}
mt__view_run_resolve() {
  # sets RUN and RUNID for --status, --report, --list (quiet: no error when there is none)
  local id
  if [ -n "$MT__F_RUN" ]; then id="$MT__F_RUN"; else id=$(mt__current_id 2>/dev/null) || id=""; fi
  if [ -z "$id" ] || [ ! -f "$MT_RESULTS/$id/results.tsv" ]; then
    [ "${1:-}" = quiet ] && return 1
    printf 'No run %s in %s.\n' "${id:-yet}" "$MT_RESULTS" >&2
    return 1
  fi
  RUNID="$id"; RUN="$MT_RESULTS/$id"
  mt__runenv_load
  return 0
}
mt__dry() {
  local stamp t0 t1 prompts checks
  stamp=$(date -u +%Y%m%d-%H%M%S)
  mkdir -p "$MT_RESULTS" || mt__die "Cannot create $MT_RESULTS"
  RUNID="dry-$stamp"; RUN="$MT_RESULTS/$RUNID"; INV=1; DRY=1
  mkdir -p "$RUN/code/inv-1" "$RUN/steps" || mt__die "Cannot create $RUN"
  MT__CODE_DIR="$RUN/code/inv-1"
  mt__runenv_write
  printf '%s\n' "$MT__RES_HEADER" > "$RUN/results.tsv"
  : > "$RUN/kv"; : > "$RUN/readings.txt"
  mt_lib_init
  mt__answers_load
  mt__check_selection_args
  mt__res_load
  MT__CMDDIR="$RUN/main/inv-1"; mkdir -p "$MT__CMDDIR"
  trap 'mt__main_int' INT TERM HUP
  t0=$(epoch_now)
  printf 'Dry run in %s: nothing outside it is written, no Docker, cleat, expect or host control.\n' "$RUN"
  mt__loop only
  t1=$(epoch_now)
  prompts=$(cat "$RUN"/steps/*/a*/transcript.txt 2>/dev/null | grep -c '^---- \[')
  checks=$(cat "$RUN"/steps/*/a*/checks.tsv 2>/dev/null | awk 'END { print NR + 0 }')
  printf '\nDry run done: %s steps walked, %s ERROR, %s prompts printed, %s checks listed, %s.\n' "${MT__WALKED:-0}" "${MT__ERRORS:-0}" "${prompts:-0}" "$checks" "$(mt__dur $((t1 - t0)))"
  printf 'Results: %s/results.tsv\n' "$RUN"
  [ "${MT__ERRORS:-0}" = 0 ]
}
# The copy: everything a run does, from its own files.
mt__main_copy() {
  local mode d
  RUN="$MT__RUN"; RUNID="${RUN##*/}"; INV="$MT__INV"; DRY=0
  MT_RESULTS="${RUN%/*}"
  MT__REPO_DIR="${MT__REPO_DIR:-$MT__SCRIPT_DIR}"
  MT__CODE_DIR="$MT__SCRIPT_DIR"
  trap 'mt__main_exit' EXIT
  local opid rest
  read -r opid rest < "$RUN/lock/owner" 2>/dev/null
  [ "${opid:-}" = "$$" ] || mt__die "The run's lock is not held by this process. Run the script from the repo, not from the run dir."
  mt__load "$MT__SCRIPT_DIR"
  mt__runenv_load
  mt_resolve_overrides
  mt_lib_init
  MT__CMDDIR="$RUN/main/inv-$INV"; mkdir -p "$MT__CMDDIR"
  MT__STTY=$( { stty -g < /dev/tty; } 2>/dev/null ) || MT__STTY=""
  # T2 is the terminal this invocation runs in, read again every time: a resume the next day runs
  # in another window. Typed mode raises T2 by this tty and never types into a tab that holds it.
  MT__T2TTY=$(mt__t_my_tty)
  {
    printf 'inv %s start %s argv:' "$INV" "$(utc_stamp)"
    printf ' %s' ${MT__ARGV[@]+"${MT__ARGV[@]}"}
    printf ' code:'
    for d in "$MT__SCRIPT_DIR/egress-release.sh" "$MT__SCRIPT_DIR"/egress-release.d/*.sh; do printf ' %s=%s' "${d##*/}" "$(cksum < "$d" | awk '{ print $1 }')"; done
    printf '\n'
  } >> "$RUN/invocations.log"
  mt__answers_load
  mt__check_selection_args
  trap 'mt__main_int' INT TERM HUP
  mt__res_load
  mode=resume
  [ -n "$MT__F_ONLY" ] && mode=only
  [ -n "$MT__F_FROM" ] && mode=from
  printf 'Run %s, invocation %s, candidate %s. T1: %s.\n' "$RUNID" "$INV" "$(GIT_OPTIONAL_LOCKS=0 git -C "$MT_WT" rev-parse --short HEAD 2>/dev/null)" "$(t_mode)"
  mt__resume_prelude "$mode"
  mt__loop "$mode"
  if mt__unfinished; then
    printf '\nSome selected steps are not finished. See --status. Resume with:  %s\n' "$(mt__resume_cmd)"
  else
    printf '\nEvery selected step is finished. ./egress-release.sh --report writes the report.\n'
  fi
  return 0
}

mt_main "$@"; exit $?
