# The relay supervisor (docker/cleat-egress-shim), run for real: shared by
# test/unit/entrypoint.bats and test/unit/regressions.bats. Loaded after
# ../setup.
#
# Executed from a copy with its three paths moved into $TEST_TEMP (rule 7),
# with socat, timeout and flock stubbed: none of them exist on the macOS legs.
# The socat stub is a listener unless its first argument is `-`, the heartbeat.
# Both record whether fd 9, the lock, is open in them. A listener holds for
# $SOCAT_HOLD seconds (default 3) and exits $SOCAT_RC, so every stub ends on
# its own. Every supervisor is started with fd 3 closed so bats never waits on
# it, and teardown kills it.

_shim_setup() {
  SHIM_DIR="$TEST_TEMP/shim"; mkdir -p "$SHIM_DIR/bin" "$SHIM_DIR/run-egress"
  SHIM="$SHIM_DIR/cleat-egress-shim"
  SHIM_LOG="$SHIM_DIR/shim.log"; SHIM_LOCK="$SHIM_DIR/shim.lock"
  SHIM_SOCK="$SHIM_DIR/run-egress/proxy.sock"
  sed -e "s#^LOG=.*#LOG=$SHIM_LOG#" -e "s#^LOCK=.*#LOCK=$SHIM_LOCK#" -e "s#^SOCK=.*#SOCK=$SHIM_SOCK#" \
    "$BATS_TEST_DIRNAME/../../docker/cleat-egress-shim" > "$SHIM"
  SOCAT_LOG="$SHIM_DIR/socat.log"; BEAT_LOG="$SHIM_DIR/beat.log"
  FLOCK_LOG="$SHIM_DIR/flock.log"; TIMEOUT_LOG="$SHIM_DIR/timeout.log"
  export SOCAT_LOG BEAT_LOG FLOCK_LOG TIMEOUT_LOG
  cat > "$SHIM_DIR/bin/socat" <<'SH'
#!/usr/bin/env bash
if { : >&9; } 2>/dev/null; then fd9=open; else fd9=closed; fi
if [ "$1" = - ]; then
  echo "beat fd9=$fd9 $*" >> "$SOCAT_LOG"
  cat >> "$BEAT_LOG"
  exit 0
fi
echo "listen fd9=$fd9 $*" >> "$SOCAT_LOG"
echo "$$" >> "$SOCAT_LOG.pids"
sleep "${SOCAT_HOLD:-3}"
exit "${SOCAT_RC:-0}"
SH
  cat > "$SHIM_DIR/bin/timeout" <<'SH'
#!/usr/bin/env bash
echo "$*" >> "$TIMEOUT_LOG"
echo "$PPID" > "$TIMEOUT_LOG.ppid"
shift
exec "$@"
SH
  cat > "$SHIM_DIR/bin/flock" <<'SH'
#!/usr/bin/env bash
echo "$*" >> "$FLOCK_LOG"
exit "${FLOCK_RC:-0}"
SH
  chmod +x "$SHIM_DIR/bin/"*
}

# The supervisor leads a process group of its own (job control in the
# subshell), so a stop ends its relay, its heartbeat loop and their sleeps with
# it. Killing the supervisor alone left the loop beating after the test, and
# once teardown deleted the stubs it ran the host's real socat.
_shim_start() {
  ( set -m
    PATH="$SHIM_DIR/bin:$PATH" bash "$SHIM" </dev/null >/dev/null 2>&1 3>&- &
    echo $! > "$SHIM_DIR/sup.pid" )
}

# Ends the whole group and waits up to 3 s for it to be gone. A group still
# alive then is killed outright and fails the test. A supervisor that outlived
# TERM once outlived its test, then teardown deleted its stubs and it ran the
# host's real socat on 127.0.0.1:3128 for good.
_shim_stop() {
  local pid i=0
  pid="$(cat "$SHIM_DIR/sup.pid" 2>/dev/null)" || return 0
  case "$pid" in ""|*[!0-9]*) return 0 ;; esac
  kill -TERM -- "-$pid" 2>/dev/null || kill "$pid" 2>/dev/null || true
  while kill -0 -- "-$pid" 2>/dev/null; do
    if [ "$i" -ge 30 ]; then
      kill -KILL -- "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
      i=0
      while kill -0 -- "-$pid" 2>/dev/null && [ "$i" -lt 20 ]; do sleep 0.1; i=$((i + 1)); done
      echo "the shim's process group $pid outlived its stop"
      return 1
    fi
    sleep 0.1; i=$((i + 1))
  done
  return 0
}

# Runs the shim to its end in at most 3 s, rc in SHIM_RC. One still running
# then (a supervisor that should have exited) is killed and reads as hung, so
# a broken script fails its test instead of hanging the suite and the harness.
_shim_run_bounded() {
  local pid i=0
  PATH="$SHIM_DIR/bin:$PATH" bash "$SHIM" "$@" </dev/null >/dev/null 2>&1 3>&- &
  pid=$!
  while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 30 ]; do sleep 0.1; i=$((i + 1)); done
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    SHIM_RC=hung
    return 0
  fi
  SHIM_RC=0
  wait "$pid" || SHIM_RC=$?
}

# Waits up to 5 s for <file> to hold at least <n> lines matching <pattern>.
_shim_await() {
  local file="$1" pattern="$2" n="${3:-1}" i=0 c
  while [ "$i" -lt 50 ]; do
    c="$(grep -c -- "$pattern" "$file" 2>/dev/null)" || true
    [ "${c:-0}" -ge "$n" ] && return 0
    sleep 0.1; i=$((i + 1))
  done
  return 0
}

# The command line of <pid>, its arguments joined by single spaces: what ps
# and a scan of /proc show a person. /proc on Linux and WSL2, ps on macOS.
_shim_cmdline() {
  if [ -r "/proc/$1/cmdline" ]; then
    tr '\0' ' ' < "/proc/$1/cmdline"
  else
    ps -ww -o args= -p "$1"
  fi | sed 's/[[:space:]]*$//'
}

# Waits up to 5 s for the command line of <pid> to contain <text>.
_shim_await_cmdline() {
  local pid="$1" text="$2" i=0
  while [ "$i" -lt 50 ]; do
    case "$(_shim_cmdline "$pid" 2>/dev/null)" in *"$text"*) return 0 ;; esac
    sleep 0.1; i=$((i + 1))
  done
  return 0
}
