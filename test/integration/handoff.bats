#!/usr/bin/env bats
# ─────────────────────────────────────────────────────────────────────────────
# Integration: the live account switch (`cleat account <name>` on a box that has
# a live Claude session) against REAL Docker.
#
# The unit suite proves the docker ARGUMENTS and the in-box grammar are right
# against a stub. Only this file can prove the four things the live switch
# actually rests on inside a real container:
#
#   1. an environment variable set on ONE `docker exec -d` process is readable
#      by the shipped in-box probe running under a SECOND `docker exec`, through
#      the box's real /proc. Every classification hangs off CLEAT_EXEC_ID being
#      seen across execs (handover 1.12).
#   2. the relaunch wrapper from `exec_claude` really returns 143 when its Claude
#      takes SIGTERM, through `runuser` and a real interactive `docker exec -it`.
#      143 is the exit code the terminal-1 loop keys the reopen on (handover 1.3,
#      6.2). A shell that folded 143 into 0, or `runuser` that swallowed it,
#      would silently break the reopen and no stub can see it.
#   3. a live switch stops a real in-box Claude and stages the new login on the
#      host: the fake log gets TERM, the host staged file holds b, the pin is b
#      and the ticket reads `ready` (handover 9.4 test 3).
#   4. a live switch moves a box from the shared login to a named account and
#      back: the pin appears then disappears, the staged file holds b then is
#      absent, b's store keeps the harvest (handover 9.4 test 4).
#
# THESE CANNOT RUN FROM INSIDE A CLEAT BOX ON macOS, and that is structural: the
# box's /tmp is not the Mac's, so every file bind under $TEST_TEMP becomes a
# directory and the container refuses to start. CI's test-integration job runs
# them on a Linux runner, which is where they are green. The lab end-to-end
# script (/tmp/acct-inv/lab/handoff_e2e.sh) exercises the same shipped probe and
# terminate against REAL Claude Code 2.1.270 in a pty, which no CI box has.
#
# Skipped if docker is unavailable.
# ─────────────────────────────────────────────────────────────────────────────

load "../setup"

setup_file() {
  if ! command -v docker &>/dev/null; then
    skip "docker not available"
  fi
  if ! docker info &>/dev/null; then
    skip "docker daemon not reachable"
  fi
  local repo_root _build_log
  repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  _build_log="$(docker build -q -t cleat -f "$repo_root/docker/Dockerfile" "$repo_root/docker/" 2>&1)" || {
    echo "# docker build failed, nothing below was tested:" >&3
    echo "$_build_log" | sed 's/^/#   /' >&3
    skip "could not build cleat image"
  }
}

# The PATH the CLI passes on every exec. `runuser` keeps the caller's env, but a
# box's own login shell is not sourced for a `-d` exec, so name it explicitly or
# `bash` and the fixtures below are not found.
INT_BOX_PATH="/home/coder/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# A UUID that both the in-box session file and the host transcript use, so the
# classification's sid check (4.2 row 6) resolves to a real <sid>.jsonl.
INT_SID="d7b73579-51d2-42e8-9307-367515a5160d"

setup() {
  _common_setup
  INT_PROJECT="$TEST_TEMP/int-handoff"
  mkdir -p "$INT_PROJECT"
  export XDG_CONFIG_HOME="$TEST_TEMP/xdg"
  mkdir -p "$XDG_CONFIG_HOME/cleat"
  INT_CNAME="cleat-inthb-$(date +%s)-$$"
  export INT_CNAME
  INT_MARKER_PIDS=()
}

teardown() {
  # Kill any host "marker owner" sleeps this test left holding a .attached.<pid>.
  local p
  for p in "${INT_MARKER_PIDS[@]:-}"; do
    [[ -n "$p" ]] && kill "$p" 2>/dev/null || true
  done
  docker rm -f "$INT_CNAME" >/dev/null 2>&1 || true
  local default_name
  default_name="$(int_cname 2>/dev/null)"
  if [[ -n "$default_name" ]]; then
    docker ps -aq --filter "name=^${default_name}" 2>/dev/null | while read -r _c; do
      [[ -n "$_c" ]] && docker rm -f "$_c" >/dev/null 2>&1 || true
    done
  fi
  _common_teardown
}

# Leave nothing in the box that could be mistaken for a Claude session. The
# probe judges what is RUNNING, so a stray fake or shim from an earlier test
# makes the next switch refuse with "could not tell what the session is doing",
# which is a true statement about a box the test did not mean to create.
int_clean_box() {
  local cname="$1"
  docker exec "$cname" runuser -u coder -- bash -c '
    [ -s /workspace/.shim-pid ] && kill -KILL "$(cat /workspace/.shim-pid)" 2>/dev/null
    [ -s /workspace/.fake-pid ] && kill -KILL "$(cat /workspace/.fake-pid)" 2>/dev/null
    pkill -KILL -f "fake-claude" 2>/dev/null
    pkill -KILL -f "shim-bin/claude" 2>/dev/null
    rm -rf /workspace/.shim-bin /workspace/.shim-pid /workspace/.wrapper.sh
    exit 0' >/dev/null 2>&1 || true
}

# Print the self-contained in-box closure exactly as the shipped host renders it
# (declare -p the stale bound, declare -f every _hb_* and its helpers, then the
# entry call). If any listed name were unset the CLI would refuse and this fails.
render_box_script() {
  cli_call _handoff_box_script
}

# Write the fake Claude into the box. It writes its own sessions/<pid>.json with
# the REAL procStart (field 22 of /proc/<pid>/stat), traps TERM to unlink the
# file, appends TERM to /workspace/.fake-log and exits 143, so it reproduces a
# clean Claude shutdown that _hb_terminate can observe.
write_fake_claude() {
  local cname="$1"
  docker exec -i "$cname" runuser -u coder -- bash -c 'cat > /workspace/.fake-claude.sh' <<'FAKE'
#!/usr/bin/env bash
set -u
SDIR="$HOME/.claude/sessions"
mkdir -p "$SDIR"
PID=$$
RAW="$(cat "/proc/$PID/stat")"
REST="${RAW##*) }"
set -- $REST
PS="${20}"
SID="${FAKE_SID:?fake claude needs FAKE_SID}"
printf '{"pid":%s,"sessionId":"%s","procStart":"%s","version":"2.1.270","kind":"interactive","entrypoint":"cli","status":"idle"}\n' \
  "$PID" "$SID" "$PS" > "$SDIR/$PID.json"
_term() { rm -f "$SDIR/$PID.json" 2>/dev/null || true; printf 'TERM %s\n' "$PID" >> /workspace/.fake-log; exit 143; }
trap _term TERM
printf 'UP %s\n' "$PID" >> /workspace/.fake-log
while :; do sleep 0.2; done
FAKE
}

# Start the fake Claude detached, carrying the exec id and the named store dir,
# with argv0 `claude` so the in-box scan classifies it by executable (B17).
start_fake_claude() {
  local cname="$1" execid="$2" sid="$3"
  docker exec -d \
    -e CLEAT_EXEC_ID="$execid" \
    -e CLAUDE_SECURESTORAGE_CONFIG_DIR=/home/coder/.cleat-auth \
    -e FAKE_SID="$sid" \
    -e PATH="$INT_BOX_PATH" \
    "$cname" runuser -u coder -- bash -c 'exec -a claude bash /workspace/.fake-claude.sh'
}

# Wait until the fake Claude has written its session file (bounded).
wait_fake_session() {
  local cname="$1" i
  for i in $(seq 1 50); do
    if docker exec "$cname" runuser -u coder -- bash -c 'ls /home/coder/.claude/sessions/[0-9]*.json >/dev/null 2>&1'; then
      return 0
    fi
    sleep 0.2
  done
  return 1
}

# A JSON credential with a fixed refreshToken. Two accounts written with the
# SAME token are "same grant": harvest absorbs the outgoing login by token match
# (_account_staged_absorbed) and never makes the profile network call CI lacks.
write_cred() {
  local path="$1" access="$2" refresh="$3"
  mkdir -p "$(dirname "$path")"
  printf '{"claudeAiOauth":{"accessToken":"%s","refreshToken":"%s","expiresAt":%s,"scopes":["user:inference"],"subscriptionType":"max"}}\n' \
    "$access" "$refresh" "$(( ($(date +%s) + 31536000) * 1000 ))" > "$path"
  chmod 600 "$path"
}

# Hold a .attached.<pid> marker owned by a live HOST pid (so kill -0 sees it),
# with the content the classification requires: kind=claude exec=<id>.
write_marker() {
  local cname="$1" execid="$2" rd
  rd="$XDG_CONFIG_HOME/cleat/run/$cname"
  mkdir -p "$rd"
  sleep 600 &
  local sp=$!
  INT_MARKER_PIDS+=("$sp")
  printf 'kind=claude exec=%s\n' "$execid" > "$rd/.attached.$sp"
}

@test "integration: the box probe reads another exec environment through docker exec" {
  cd "$INT_PROJECT"
  run "$CLI" run
  assert_success
  local cname script execid
  cname="$(int_cname)"
  execid="cafe1234beef"

  write_fake_claude "$cname"
  start_fake_claude "$cname" "$execid" "$INT_SID"
  wait_fake_session "$cname" || { echo "# fake claude never wrote its session file" >&3; false; }

  # The load-bearing claim: an id set on the -d exec above is read back by the
  # SHIPPED probe running under a SECOND docker exec, through the box's /proc.
  script="$(render_box_script)"
  [ -n "$script" ]
  run docker exec "$cname" runuser -u coder -- bash -c "$script" cleat-hb probe /home/coder /proc
  assert_success
  assert_output --partial "$execid"
  # One claude session, named store (CLAUDE_SECURESTORAGE_CONFIG_DIR was set),
  # its sid, and the grammar's terminators.
  assert_output --partial "claude	"
  assert_output --partial " interactive $execid named $INT_SID"
  assert_output --partial "end	ok"
}

@test "integration: the relaunch wrapper returns 143 when its Claude takes SIGTERM" {
  # The exact inner wrapper exec_claude runs (clip-daemon, `claude "$@"`, capture
  # its rc, kill the daemon, `exit "$rc"`) with `claude` a shim that traps TERM
  # and exits 143. The wrapper runs under a real interactive `docker exec -it`,
  # itself under a host `script -qec` pty so `-it` has a terminal, and `script
  # -e` returns the child's exit code. If runuser, the wrapper or docker exec
  # folded 143 into 0 or 130, the terminal-1 loop would never reopen the
  # conversation, and no stub can see that.
  command -v script >/dev/null 2>&1 || skip "script(1) not available on this host"
  cd "$INT_PROJECT"
  run "$CLI" run
  assert_success
  local cname i
  cname="$(int_cname)"

  # The wrapper, byte for byte from exec_claude's inner `bash -c` body.
  docker exec -i "$cname" runuser -u coder -- bash -c 'cat > /workspace/.wrapper.sh' <<'WRAP'
clip-daemon &
_MY_CLIP_DAEMON=$!
for i in 1 2 3 4 5; do [ -S "${CLEAT_CLIP_DIR:-/tmp/cleat-run-$(id -u)}/clip.sock" ] && break; sleep 0.1; done
claude "$@"
_CLAUDE_RC=$?
kill "$_MY_CLIP_DAEMON" 2>/dev/null
wait "$_MY_CLIP_DAEMON" 2>/dev/null
exit "$_CLAUDE_RC"
WRAP

  # A `claude` on PATH that records its own pid and exits 143 on SIGTERM.
  # Into a directory of its own, put AHEAD of the real one on PATH. It used to
  # be written over /home/coder/.local/bin/claude, which is a symlink into the
  # installed bundle: a newer image makes that target unwritable, so the write
  # failed with "Permission denied" and the test could not run at all.
  # Shadowing is also closer to the thing under test, since the wrapper
  # resolves `claude` through PATH.
  docker exec "$cname" runuser -u coder -- mkdir -p /workspace/.shim-bin
  docker exec -i "$cname" runuser -u coder -- bash -c 'cat > /workspace/.shim-bin/claude && chmod +x /workspace/.shim-bin/claude' <<'SHIM'
#!/usr/bin/env bash
trap 'exit 143' TERM
echo $$ > /workspace/.shim-pid
while :; do sleep 0.2; done
SHIM

  # Run the interactive exec under a host pty, in the background, so we can TERM
  # the shim and then read the exit code `script -e` propagated.
  cat > "$TEST_TEMP/run-wrapper.sh" <<EOF
script -qec "docker exec -it -e PATH=/workspace/.shim-bin:$INT_BOX_PATH $cname runuser -u coder -- bash /workspace/.wrapper.sh --resume x" /dev/null
echo "WRAP_RC=\$?" > "$TEST_TEMP/wrap-rc"
EOF
  bash "$TEST_TEMP/run-wrapper.sh" &
  local runpid=$!

  # Wait for the shim to record its pid, then SIGTERM it (as _hb_terminate does).
  for i in $(seq 1 100); do
    docker exec "$cname" test -s /workspace/.shim-pid 2>/dev/null && break
    sleep 0.2
  done
  docker exec "$cname" runuser -u coder -- bash -c 'kill -TERM "$(cat /workspace/.shim-pid)"' || true

  wait "$runpid" 2>/dev/null || true
  run cat "$TEST_TEMP/wrap-rc"
  assert_success
  assert_output --partial "WRAP_RC=143"

  # Leave the box as this test found it. The shim is a process called `claude`
  # that survives its own SIGTERM handler's race, and its pid file and PATH
  # directory outlive the test, so the NEXT test's probe saw a second Claude in
  # the box and refused the switch it was there to prove. This test could not
  # leak before, because writing the shim failed outright.
  docker exec "$cname" runuser -u coder -- bash -c '
    [ -s /workspace/.shim-pid ] && kill -KILL "$(cat /workspace/.shim-pid)" 2>/dev/null
    pkill -KILL -f "/workspace/.shim-bin/claude" 2>/dev/null
    rm -rf /workspace/.shim-bin /workspace/.shim-pid /workspace/.wrapper.sh
    exit 0' || true
}

@test "integration: a live switch stops a fake Claude in a real box and stages the new login on the host" {
  cd "$INT_PROJECT"
  run "$CLI" run
  assert_success
  local cname key execid
  cname="$(int_cname)"
  int_clean_box "$cname"
  execid="d00dfeed1234"
  key="$(cli_call _derive_project_session_key "$INT_PROJECT" main)"

  # Two named accounts on the SAME grant (harvest absorbs, no network).
  write_cred "$XDG_CONFIG_HOME/cleat/accounts/a/.credentials.json" "acc-a-token" "shared-refresh"
  write_cred "$XDG_CONFIG_HOME/cleat/accounts/b/.credentials.json" "acc-b-TOKEN"  "shared-refresh"
  mkdir -p "$XDG_CONFIG_HOME/cleat/accounts/a" "$XDG_CONFIG_HOME/cleat/accounts/b"

  # Pin the box to a and stage a into it, so the box's outgoing login == a.
  run cli_call _box_account_write "$cname" a "$key"
  assert_success
  run cli_call _account_sync_in "$cname"
  assert_success

  # A host transcript so the sid resolves under the session key dir (4.2 row 6).
  mkdir -p "$HOME/.claude/projects/$key"
  printf '{"type":"user","sessionId":"%s"}\n' "$INT_SID" > "$HOME/.claude/projects/$key/$INT_SID.jsonl"

  write_fake_claude "$cname"
  start_fake_claude "$cname" "$execid" "$INT_SID"
  wait_fake_session "$cname" || { echo "# fake claude never wrote its session file" >&3; false; }
  write_marker "$cname" "$execid"

  # The switch: assume_yes=1, now=0, against the real daemon.
  run cli_call _account_handoff b main "$cname" "$INT_PROJECT" 1 0
  assert_success

  # The fake Claude took TERM.
  run docker exec "$cname" cat /workspace/.fake-log
  assert_success
  assert_output --partial "TERM"

  # The host staged b into the box store (b's distinctive token).
  run docker exec "$cname" cat /home/coder/.cleat-auth/.credentials.json
  assert_success
  assert_output --partial "acc-b-TOKEN"

  # The pin is b.
  run cli_call _box_account_read "$cname"
  assert_success
  assert_output "b"

  # The ticket reads ready (terminal 1 keys the reopen on this).
  run cat "$XDG_CONFIG_HOME/cleat/run/$cname/.handoff.$execid"
  assert_success
  assert_output --partial "state=ready"
  assert_output --partial "to=b"
  assert_output --partial "sid=$INT_SID"
}

@test "integration: a live switch moves a box from the shared login to a named account and back" {
  cd "$INT_PROJECT"
  run "$CLI" run
  assert_success
  local cname key execid
  cname="$(int_cname)"
  int_clean_box "$cname"
  execid="beadfeed5678"
  key="$(cli_call _derive_project_session_key "$INT_PROJECT" main)"

  write_cred "$XDG_CONFIG_HOME/cleat/accounts/b/.credentials.json" "acc-b-ONLY" "b-refresh"

  # Box starts on the shared login (no pin). The in-box session must then read
  # the DEFAULT store, so the fake Claude runs WITHOUT the named store dir.
  run cli_call _box_account_read "$cname"
  assert_output "default"

  mkdir -p "$HOME/.claude/projects/$key"
  printf '{"type":"user","sessionId":"%s"}\n' "$INT_SID" > "$HOME/.claude/projects/$key/$INT_SID.jsonl"

  write_fake_claude "$cname"
  # Shared-login session: no CLAUDE_SECURESTORAGE_CONFIG_DIR, so store=default.
  docker exec -d -e CLEAT_EXEC_ID="$execid" -e FAKE_SID="$INT_SID" -e PATH="$INT_BOX_PATH" \
    "$cname" runuser -u coder -- bash -c 'exec -a claude bash /workspace/.fake-claude.sh'
  wait_fake_session "$cname" || { echo "# fake claude never wrote its session file" >&3; false; }
  write_marker "$cname" "$execid"

  # Shared -> named b.
  run cli_call _account_handoff b main "$cname" "$INT_PROJECT" 1 0
  assert_success
  run cli_call _box_account_read "$cname"
  assert_output "b"
  run docker exec "$cname" cat /home/coder/.cleat-auth/.credentials.json
  assert_success
  assert_output --partial "acc-b-ONLY"

  # Retire the first session's marker: its exec id is no longer in any probe, so
  # left live it would read as a Claude "starting" and the next switch would
  # refuse with R-starting.
  local p
  for p in "${INT_MARKER_PIDS[@]:-}"; do [[ -n "$p" ]] && kill "$p" 2>/dev/null || true; done
  INT_MARKER_PIDS=()
  rm -f "$XDG_CONFIG_HOME/cleat/run/$cname"/.attached.* 2>/dev/null || true

  # Now named b -> back to the shared login. A fresh live session on b's store.
  execid="beadfeed9abc"
  start_fake_claude "$cname" "$execid" "$INT_SID"
  wait_fake_session "$cname" || { echo "# fake claude never wrote its session file" >&3; false; }
  write_marker "$cname" "$execid"

  run cli_call _account_handoff default main "$cname" "$INT_PROJECT" 1 0
  assert_success
  # The pin is gone (back on the shared login).
  run cli_call _box_account_read "$cname"
  assert_output "default"
  # The box-writable staged file is removed with the pin.
  run docker exec "$cname" bash -c 'test -e /home/coder/.cleat-auth/.credentials.json && echo present || echo absent'
  assert_success
  assert_output "absent"
  # b's own store kept the harvested login.
  run cat "$XDG_CONFIG_HOME/cleat/accounts/b/.credentials.json"
  assert_success
  assert_output --partial "acc-b"
}
