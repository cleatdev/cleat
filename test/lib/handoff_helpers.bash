#!/usr/bin/env bash
# Shared helpers for the live-account-switch tests (handoff.bats and the two
# Linux-only regressions R-b and R-c). The in-box verbs are always exercised by
# rendering _handoff_box_script and running the TEXT as a subprocess, so what a
# test proves is exactly what ships. No test ever hands the real /proc to a
# verb: fake roots for the portable tests, a filtered proc VIEW (symlinks to the
# marked pids this test spawned) for the Linux ones.

# hb_reset_pids: the file the spawn helpers and teardown track owned pids in.
hb_reset_pids() { : > "$TEST_TEMP/hb_pids"; }

# hb_require_linux: skip a test that needs real processes and /proc off Linux.
hb_require_linux() {
  [[ "$(uname -s)" == "Linux" && -r /proc/self/stat ]] || \
    skip "real-process terminate path: Linux with /proc only (CI covers the box leg, handover 8.2)"
}

# hb_fake_proc DIR PID "ARGV..." STARTTIME [STATE] [ENV...]
# A fake <DIR>/<PID> with stat (state word 1 after the comm, start time field
# 22), cmdline (ARGV word-split, NUL-terminated) and environ (ENV NUL-joined).
hb_fake_proc() {
  local dir="$1" pid="$2" argv="$3" start="$4" state="${5:-R}"
  local env_args=(); [[ $# -ge 6 ]] && env_args=("${@:6}")
  local p="$dir/$pid" mid="" i w comm first
  mkdir -p "$p"
  set -- $argv; first="$1"; comm="${first##*/}"; [[ ${#comm} -le 15 ]] || comm="${comm:0:15}"
  for i in $(seq 1 18); do mid="$mid 0"; done
  printf '%s (%s) %s%s %s 0 0 0\n' "$pid" "$comm" "$state" "$mid" "$start" > "$p/stat"
  : > "$p/cmdline"
  for w in $argv; do printf '%s\0' "$w" >> "$p/cmdline"; done
  : > "$p/environ"
  [[ ${#env_args[@]} -gt 0 ]] && for w in "${env_args[@]}"; do printf '%s\0' "$w" >> "$p/environ"; done
  return 0
}

# hb_fake_proc_env_dir DIR PID "ARGV..." STARTTIME: like hb_fake_proc but the
# environ is a DIRECTORY, the "cannot read the environment" case.
hb_fake_proc_env_dir() {
  local dir="$1" pid="$2" argv="$3" start="$4"
  hb_fake_proc "$dir" "$pid" "$argv" "$start" R
  rm -f "$dir/$pid/environ"; mkdir -p "$dir/$pid/environ"
}

# hb_fake_snapshot_proc DIR PID [ENV...]: a bash whose argv sources a Claude
# shell snapshot (the tool/background-command shell).
hb_fake_snapshot_proc() {
  local dir="$1" pid="$2"; shift 2
  local p="$dir/$pid" mid="" i w
  mkdir -p "$p"
  for i in $(seq 1 18); do mid="$mid 0"; done
  printf '%s (bash) R%s 90000 0 0 0\n' "$pid" "$mid" > "$p/stat"
  : > "$p/cmdline"
  printf 'bash\0-c\0source /home/coder/.claude/shell-snapshots/snapshot-bash-1-abc.sh\0' > "$p/cmdline"
  : > "$p/environ"
  for w in "$@"; do printf '%s\0' "$w" >> "$p/environ"; done
}

# hb_session HOME PID STATUS [KEY=VALUE...]: a session file in Claude's field
# order under HOME/.claude/sessions. procStart defaults empty (set it to the
# fake proc's start time to make the session live).
hb_session() {
  local home="$1" pid="$2" status="$3"; shift 3
  local sid="d7b73579-1111-2222-3333-444455556666" ps="" kind="interactive" waiting="" kv k v
  for kv in "$@"; do
    k="${kv%%=*}"; v="${kv#*=}"
    case "$k" in
      sessionId) sid="$v" ;;
      procStart) ps="$v" ;;
      kind) kind="$v" ;;
      waitingFor) waiting="$v" ;;
    esac
  done
  mkdir -p "$home/.claude/sessions"
  local json="{\"pid\":$pid,\"sessionId\":\"$sid\",\"procStart\":\"$ps\",\"version\":\"2.1.270\",\"kind\":\"$kind\",\"entrypoint\":\"cli\",\"status\":\"$status\""
  [[ -n "$waiting" ]] && json="$json,\"waitingFor\":\"$waiting\""
  json="$json}"
  printf '%s' "$json" > "$home/.claude/sessions/$pid.json"
}

# hb_proc_view DIR: symlink DIR/<pid> -> /proc/<pid> for every pid whose environ
# carries this test's mark. Never the box's own real claude.
hb_proc_view() {
  local dir="$1" p pid
  mkdir -p "$dir"
  for p in /proc/[0-9]*; do
    pid="${p##*/}"
    [[ -r "$p/environ" ]] || continue
    if tr '\0' '\n' < "$p/environ" 2>/dev/null | grep -qxF "HB_TEST_MARK=$TEST_TEMP"; then
      ln -sfn "$p" "$dir/$pid"
    fi
  done
}

# hb_spawn_claude MODE SID EXECID STATUS: start a real marked `claude` process
# (argv0 claude), writing its own live session file with its real procStart.
# MODE: exits (TERM removes the file, exits 143), ignores (TERM ignored) or
# spawns (TERM starts a second marked claude, links it into HB_PROC_VIEW, then
# exits 143). The caller may pre-set HB_STORE, HB_LOCK, HB_LOCKREC and
# HB_PROC_VIEW. Sets HB_PID and HB_RS. Every spawned pid lands in hb_pids.
hb_spawn_claude() {
  local mode="$1" sid="$2" execid="$3" status="$4"
  local sf="${BH:-$HOME}/.claude/sessions"; mkdir -p "$sf"
  local info="$TEST_TEMP/hb_info.$$.$RANDOM"; : > "$info"
  cat > "$TEST_TEMP/hb_child.sh" <<'CHILD'
RS=$(sed 's/.*) //' "/proc/$$/stat" | awk '{print $20}')
printf '{"pid":%s,"sessionId":"%s","procStart":"%s","version":"2.1.270","kind":"interactive","entrypoint":"cli","status":"%s"}' "$$" "$HB_SID" "$RS" "$HB_STATUS" > "$HB_SF/$$.json"
printf '%s %s\n' "$$" "$RS" > "$HB_INFO"
_hb_on_term() {
  if [ -n "${HB_LOCKREC:-}" ]; then
    if [ -d "${HB_LOCK:-/hb_no_lock}" ]; then echo yes > "$HB_LOCKREC"; else echo no > "$HB_LOCKREC"; fi
  fi
  if [ "$HB_TERMMODE" = spawns ]; then
    ( exec -a claude bash -c 'while :; do sleep 0.05; done' ) &
    np=$!
    echo "$np" >> "$HB_PIDS"
    while [ ! -e "/proc/$np" ]; do :; done
    [ -n "${HB_PROC_VIEW:-}" ] && ln -sf "/proc/$np" "$HB_PROC_VIEW/$np"
  fi
  rm -f "$HB_SF/$$.json"
  exit 143
}
if [ "$HB_TERMMODE" = ignores ]; then trap '' TERM; else trap _hb_on_term TERM; fi
while :; do sleep 0.05; done
CHILD
  (
    export HB_SID="$sid" HB_STATUS="$status" HB_SF="$sf" HB_INFO="$info" \
           HB_TERMMODE="$mode" HB_TEST_MARK="$TEST_TEMP" CLEAT_EXEC_ID="$execid" \
           HB_PIDS="$TEST_TEMP/hb_pids"
    [ -n "${HB_STORE:-}" ] && export CLAUDE_SECURESTORAGE_CONFIG_DIR="$HB_STORE"
    [ -n "${HB_LOCK:-}" ] && export HB_LOCK
    [ -n "${HB_LOCKREC:-}" ] && export HB_LOCKREC
    [ -n "${HB_PROC_VIEW:-}" ] && export HB_PROC_VIEW
    exec -a claude bash "$TEST_TEMP/hb_child.sh"
  ) </dev/null >/dev/null 2>&1 3>&- &
  local waited=0
  while [ ! -s "$info" ] && [ $waited -lt 300 ]; do sleep 0.02; waited=$(( waited + 1 )); done
  HB_PID=""; HB_RS=""
  [ -s "$info" ] && read -r HB_PID HB_RS < "$info"
  [ -n "$HB_PID" ] && echo "$HB_PID" >> "$TEST_TEMP/hb_pids"
}

# hb_render_box: write the shipped closure to $TEST_TEMP/box.sh.
hb_render_box() { _handoff_box_script > "$TEST_TEMP/box.sh"; }

# hb_run_box_raw VERB ARGS...: render and run the closure with no owner guard.
# Used only by the argument-validation test, which passes bad pids on purpose
# and never reaches a signal.
hb_run_box_raw() {
  hb_render_box || { echo "render failed"; return 70; }
  bash -c "$(cat "$TEST_TEMP/box.sh")" cleat-hb "$@" 3>&-
}

# hb_run_box VERB ARGS...: hb_run_box_raw, but for terminate it first refuses
# any target pid that is a LIVE process this test did not spawn, so a test bug
# can never SIGTERM an unrelated process.
hb_run_box() {
  local verb="$1"
  if [[ "$verb" == "terminate" ]]; then
    local args=("$@") i=7 p
    while [[ $i -lt ${#args[@]} ]]; do
      p="${args[$i]}"
      if [[ "$p" =~ ^[1-9][0-9]*$ ]] && kill -0 "$p" 2>/dev/null; then
        if ! grep -qxF "$p" "$TEST_TEMP/hb_pids" 2>/dev/null; then
          echo "hb_run_box: refusing terminate of live pid $p not spawned by this test"
          return 99
        fi
      fi
      i=$(( i + 5 ))
    done
  fi
  hb_run_box_raw "$@"
}

# ── host-state helpers (markers, tickets, the account lock) ──────────────────
# These back the M2 tests: the attach marker and handoff ticket a switch in one
# terminal and an attach in another read, and a planted account lock a busy path
# needs. All host-only, under $CLEAT_RUN_DIR/<cname>, never in the box.

# hb_marker CNAME PID CONTENT: write a host-only .attached.<pid> marker.
hb_marker() {
  mkdir -p "$CLEAT_RUN_DIR/$1" 2>/dev/null || true
  printf '%s\n' "$3" > "$CLEAT_RUN_DIR/$1/.attached.$2"
}

# hb_dead_pid: a pid that is certainly dead (spawned, then reaped), for a marker
# or ticket whose owner has gone. Self-cleaning, needs no teardown.
hb_dead_pid() {
  local p
  sleep 0.01 &
  p=$!
  wait "$p" 2>/dev/null || true
  echo "$p"
}

# hb_lock_live_record: an account-lock owner record naming this live test
# process, so a planted lock reads as held by a living owner (never stale).
hb_lock_live_record() { printf 'host %s pid %s at %s' "${HOSTNAME:-unknown}" "$$" "$(date +%s)"; }

# hb_lock_plant RECORD: plant a held account-lock dir with an owner record, so
# _account_lock (with _ACCOUNT_LOCK_WAIT_S=0) returns busy at once.
hb_lock_plant() {
  mkdir -p "$CLEAT_ACCOUNTS_DIR/.lock" 2>/dev/null || true
  printf '%s\n' "$1" > "$CLEAT_ACCOUNTS_DIR/.lock/owner"
}

# hb_teardown_pids: SIGKILL every owned pid still carrying this test's mark.
hb_teardown_pids() {
  local pid
  [[ -f "$TEST_TEMP/hb_pids" ]] || return 0
  while read -r pid; do
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    if [[ -r "/proc/$pid/environ" ]] && \
       tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null | grep -qxF "HB_TEST_MARK=$TEST_TEMP"; then
      kill -KILL "$pid" 2>/dev/null || true
    fi
  done < "$TEST_TEMP/hb_pids"
}
