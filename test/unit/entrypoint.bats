#!/usr/bin/env bats
# Tests for docker/entrypoint.sh: the runtime UID/GID remap and the ownership
# fixups that follow it. Per the project rule for scripts that run outside the
# CLI, we execute entrypoint.sh directly with the privileged commands stubbed
# (chown/sed/usermod/id/su), so we can assert behavior without root or a real
# container.
load "../setup"
load "../lib/egress_shim"

setup() { _common_setup; }
teardown() {
  if [ -n "${SHIM_DIR:-}" ]; then _shim_stop; fi
  _common_teardown
}

# Run entrypoint.sh with a host UID that differs from the image's build UID
# (1000), which forces the remap path, and with `chown` stubbed to record every
# call. The other privileged commands are harmless no-ops; the final `exec su`
# is replaced by a stub that exits 0.
#
# The egress branch's commands are stubbed for EVERY test, so a runner that is
# root (the WSL2 leg) never writes the real /etc. mountpoint answers
# $MOUNTPOINT_RC (default 1, an uncaged box) for /run/cleat-egress only. sed,
# chown and runuser also append to one ORDER_LOG, so a test can read their order.
# With RUNUSER_HOLD set the runuser stub stays up like the real supervisor,
# until that file exists or 3 s pass, then records `runuser end`.
_run_entrypoint() {
  local stubs="$TEST_TEMP/stubs"
  mkdir -p "$stubs"
  CHOWN_LOG="$TEST_TEMP/chown.log"; : > "$CHOWN_LOG"; export CHOWN_LOG
  RM_LOG="$TEST_TEMP/rm.log"; : > "$RM_LOG"; export RM_LOG
  TEE_LOG="$TEST_TEMP/tee.log"; : > "$TEE_LOG"; export TEE_LOG
  GIT_LOG="$TEST_TEMP/git.log"; : > "$GIT_LOG"; export GIT_LOG
  MKDIR_LOG="$TEST_TEMP/mkdir.log"; : > "$MKDIR_LOG"; export MKDIR_LOG
  RUNUSER_LOG="$TEST_TEMP/runuser.log"; rm -f "$RUNUSER_LOG"; export RUNUSER_LOG
  ORDER_LOG="$TEST_TEMP/order.log"; : > "$ORDER_LOG"; export ORDER_LOG
  MOUNTPOINT_RC="${MOUNTPOINT_RC:-1}"; export MOUNTPOINT_RC
  RUNUSER_HOLD="${RUNUSER_HOLD:-}"; export RUNUSER_HOLD

  printf '#!/bin/sh\necho "$@" >> "$CHOWN_LOG"\necho "chown $*" >> "$ORDER_LOG"\nexit 0\n' > "$stubs/chown"
  printf '#!/bin/sh\necho 1000\nexit 0\n'                 > "$stubs/id"
  printf '#!/bin/sh\necho "sed $*" >> "$ORDER_LOG"\nexit 0\n' > "$stubs/sed"
  printf '#!/bin/sh\nfor a; do last="$a"; done\n[ "$last" = /run/cleat-egress ] || exit 1\nexit "$MOUNTPOINT_RC"\n' > "$stubs/mountpoint"
  printf '#!/bin/sh\nexec 3>&-\necho "runuser $*" >> "$ORDER_LOG"\necho "$@" >> "$RUNUSER_LOG"\n[ -n "$RUNUSER_HOLD" ] || exit 0\ni=0\nwhile [ ! -e "$RUNUSER_HOLD" ] && [ "$i" -lt 30 ]; do sleep 0.1; i=$((i + 1)); done\necho "runuser end" >> "$ORDER_LOG"\nexit 0\n' > "$stubs/runuser"
  printf '#!/bin/sh\necho "== $*" >> "$TEE_LOG"\ncat >> "$TEE_LOG"\nexit 0\n' > "$stubs/tee"
  printf '#!/bin/sh\necho "$@" >> "$GIT_LOG"\nexit 0\n'   > "$stubs/git"
  printf '#!/bin/sh\necho "$@" >> "$MKDIR_LOG"\nexit 0\n' > "$stubs/mkdir"
  printf '#!/bin/sh\nexit 0\n'                            > "$stubs/usermod"
  printf '#!/bin/sh\nexit 0\n'                            > "$stubs/groupadd"
  printf '#!/bin/sh\nexit 0\n'                            > "$stubs/getent"
  printf '#!/bin/sh\nexit 0\n'                            > "$stubs/stat"
  printf '#!/bin/sh\necho "su NODE_OPTIONS=${NODE_OPTIONS-unset}" >> "$ORDER_LOG"\nexit 0\n' > "$stubs/su"
  # Stub `rm` so the entrypoint's stale-runtime cleanup is observable AND can't
  # touch the real /tmp during tests (the dev box may have a live clip socket).
  printf '#!/bin/sh\necho "$@" >> "$RM_LOG"\nexit 0\n'    > "$stubs/rm"
  chmod +x "$stubs"/*

  local entrypoint="$BATS_TEST_DIRNAME/../../docker/entrypoint.sh"
  run env PATH="$stubs:$PATH" HOST_UID=501 HOST_GID=501 CHOWN_LOG="$CHOWN_LOG" RM_LOG="$RM_LOG" \
    bash "$entrypoint"
}

# The relay launch is backgrounded, so its record can land after the
# entrypoint returns. Waits up to 5 s for it.
_await_runuser() {
  local i=0
  while [ ! -s "$RUNUSER_LOG" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
}

@test "entrypoint: chowns ~/.local so the runtime user can run claude update" {
  _run_entrypoint
  assert_success
  run cat "$CHOWN_LOG"
  # The native updater writes the launcher symlink + versioned binaries under
  # ~/.local; without this chown the remapped user hits EACCES.
  assert_output --partial "/home/coder/.local"
}

@test "entrypoint: still chowns ~/.claude (auth/sessions) after the remap" {
  _run_entrypoint
  run cat "$CHOWN_LOG"
  assert_output --partial "/home/coder/.claude"
}

@test "entrypoint: chowns ~/.cache so the Claude installer can stage downloads" {
  _run_entrypoint
  assert_success
  run cat "$CHOWN_LOG"
  # The native installer stages each build under ~/.cache/claude/staging before
  # moving it into ~/.local. Baked owned by the build UID and not host-mounted,
  # so without this chown the remapped runtime user hits
  #   EACCES: permission denied, mkdir '/home/coder/.cache/claude/staging/...'
  # and `cleat upgrade-claude` / the on-start update prompt fail.
  assert_output --partial "/home/coder/.cache"
}

@test "entrypoint: chowns the shell rc files so a setup payload can put a tool on PATH" {
  _run_entrypoint
  assert_success
  run cat "$CHOWN_LOG"
  # The rc files come from useradd's skel owned by the build UID (1000) and are
  # not host-mounted, so before this every host whose UID is not 1000 (i.e.
  # every macOS host) got EACCES appending to them. Every provisioning tool that
  # puts itself on PATH does exactly that: rustup amends ~/.profile, the dotnet
  # install script appends to ~/.bashrc. A [setup] payload runs `bash -e`, so
  # that EACCES aborted the whole payload. Reproduced in Docker on a 501:20 host.
  assert_output --partial "/home/coder/.bashrc"
  assert_output --partial "/home/coder/.profile"
}

@test "entrypoint: chowns ~/.config so a tool can create its config dir" {
  _run_entrypoint
  assert_success
  run cat "$CHOWN_LOG"
  # Built as 1000 (the Dockerfile mkdirs .config/gh), not host-mounted at this
  # level, so `mkdir ~/.config/<tool>` was EACCES after the remap.
  assert_output --partial "/home/coder/.config"
}

@test "entrypoint: chowns ~/.config NON-recursively so the gh mount keeps host ownership" {
  _run_entrypoint
  assert_success
  # The gh capability bind-mounts the host's ~/.config/gh over the subdirectory.
  # A recursive chown would rewrite the ownership of the user's REAL host files,
  # so the .config chown must never gain -R. Chowning the parent alone is what
  # lets the runtime user create new entries alongside the mount. This is the
  # assertion a future "tidy the chowns into one -R" refactor must trip over.
  local line
  line="$(grep -- '/home/coder/.config' "$CHOWN_LOG" | head -1)"
  [[ -n "$line" ]] || { echo "no chown recorded for /home/coder/.config"; return 1; }
  case "$line" in
    *-R*) echo "chown of ~/.config is recursive, which rewrites the host's ~/.config/gh: $line"; return 1 ;;
  esac
}

@test "entrypoint: clears stale clipboard runtime files before dropping to coder" {
  # v0.13.1: a hard-killed prior session can leave a foreign-owned clip socket in
  # the sticky /tmp (it survives docker stop/start). As root, the entrypoint must
  # remove it so the next clip-daemon starts clean: otherwise the runtime user
  # can't unlink it and clip-daemon spews EPERM every launch.
  _run_entrypoint
  assert_success
  run cat "$RM_LOG"
  assert_output --partial "/tmp/clip.sock"
}

@test "entrypoint: rejects a non-numeric HOST_UID" {
  local stubs="$TEST_TEMP/stubs"
  mkdir -p "$stubs"
  printf '#!/bin/sh\nexit 0\n' > "$stubs/su"
  chmod +x "$stubs"/*
  local entrypoint="$BATS_TEST_DIRNAME/../../docker/entrypoint.sh"
  run env PATH="$stubs:$PATH" HOST_UID="0; rm -rf /" HOST_GID=501 bash "$entrypoint"
  assert_failure
  assert_output --partial "must be numeric"
}

# ── The egress relay in a caged box (EGRESS-SPEC.md 8.6, concept/46) ─────────

@test "entrypoint: starts the egress relay as coder when the socket volume is mounted" {
  MOUNTPOINT_RC=0 _run_entrypoint
  assert_success
  _await_runuser
  run cat "$RUNUSER_LOG"
  assert_output "-u coder -- /usr/local/bin/cleat-egress-shim"
}

@test "entrypoint: starts no relay and writes no proxy file without the socket volume" {
  _run_entrypoint
  assert_success
  # The proxy files are written in the foreground, so empty now is empty.
  run cat "$TEE_LOG" "$GIT_LOG" "$MKDIR_LOG"
  assert_output ""
  # The launch is backgrounded: give a wrongly started one time to land.
  sleep 0.5
  [ ! -e "$RUNUSER_LOG" ]
  run cat "$RM_LOG"
  refute_output --partial "cleat-egress-shim"
}

@test "entrypoint: clears a stale relay lock and hands the relay log to coder without following a link" {
  MOUNTPOINT_RC=0 _run_entrypoint
  assert_success
  run cat "$RM_LOG"
  assert_output --partial "-f /tmp/cleat-egress-shim.lock"
  run cat "$CHOWN_LOG"
  assert_output --partial "-h 501:501 /tmp/cleat-egress-shim.log"
}

@test "entrypoint: the relay starts after the uid remap" {
  # Before the remap, runuser -u coder would resolve coder to the build uid and
  # the relay would reach the socket as someone the host never chose. The
  # launch is backgrounded, so its own record could race a later sed. The
  # relay's log is handed over in the foreground just before it, which pins
  # the block's place.
  MOUNTPOINT_RC=0 _run_entrypoint
  assert_success
  _await_runuser
  run awk '/^sed .*\/etc\/passwd/ { s = NR } /^chown -h .*cleat-egress-shim[.]log/ { l = NR } /^runuser / { r = NR } END { print (s > 0 && l > s && r > s) ? "ordered" : "s=" s " l=" l " r=" r }' "$ORDER_LOG"
  assert_output "ordered"
}

@test "entrypoint: a caged box gets every ownership fixup while its relay keeps running" {
  # The relay is set up before the ownership fixups. Its supervisor never
  # exits, so a launch that held the script up would leave every fixup undone
  # on any host whose uid is not the image's 1000. Here the relay stays up
  # until the script is over.
  _run_entrypoint
  assert_success
  local plain i=0
  plain="$(cat "$CHOWN_LOG")"
  RUNUSER_HOLD="$TEST_TEMP/relay.release" MOUNTPOINT_RC=0 _run_entrypoint
  assert_success
  touch "$TEST_TEMP/relay.release"
  while ! grep -q '^runuser end$' "$ORDER_LOG" && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
  # The script reached su while the relay was still up.
  run awk '/^runuser end$/ { e = NR } /^su / { s = NR } END { print (s > 0 && e > s) ? "ordered" : "e=" e " s=" s }' "$ORDER_LOG"
  assert_output "ordered"
  # Every fixup an uncaged box gets, with the same remapped ids. The relay's
  # own log is the one extra.
  run grep -v -F -- "-h 501:501 /tmp/cleat-egress-shim.log" "$CHOWN_LOG"
  assert_output "$plain"
}

@test "entrypoint: the relay is set up before the recursive chowns" {
  # chown -R walks the whole bind-mounted ~/.claude. On a large one it can
  # outlast the gate's ten second wait for a first heartbeat. The gate then
  # names a relay that is only late. The relay's own log is handed over just
  # before it starts, in the foreground, so its place is deterministic.
  MOUNTPOINT_RC=0 _run_entrypoint
  assert_success
  run awk '/^chown -h .*cleat-egress-shim[.]log/ { l = NR } /^chown -R .*\/home\/coder\/[.]claude$/ { c = NR } END { print (l > 0 && c > l) ? "ordered" : "l=" l " c=" c }' "$ORDER_LOG"
  assert_output "ordered"
}

@test "entrypoint: a caged box gets proxy config for apt, npm, pip and git" {
  MOUNTPOINT_RC=0 _run_entrypoint
  assert_success
  run cat "$TEE_LOG"
  assert_output "== /etc/apt/apt.conf.d/99cleat-egress-proxy
Acquire::https::Proxy \"http://127.0.0.1:3128\";
Acquire::http::Proxy \"http://127.0.0.1:3128\";
== /etc/xdg/pip/pip.conf
[global]
proxy = http://127.0.0.1:3128
== /usr/local/etc/npmrc
https-proxy=http://127.0.0.1:3128
proxy=http://127.0.0.1:3128"
  run cat "$GIT_LOG"
  assert_output "config --system http.proxy http://127.0.0.1:3128"
  run cat "$MKDIR_LOG"
  assert_output "-p /etc/xdg/pip /usr/local/etc"
}

@test "entrypoint: a caged box never rewrites the apt sources or sets NODE_OPTIONS" {
  # The sources were switched to https in the image. Box root can edit them
  # anyway, so rewriting them here would claim a protection that is not there.
  # The runner's own NODE_OPTIONS (a Claude Code session sets one) is not ours.
  unset NODE_OPTIONS
  MOUNTPOINT_RC=0 _run_entrypoint
  assert_success
  run cat "$TEE_LOG" "$ORDER_LOG" "$GIT_LOG"
  refute_output --partial "sources"
  # exec_claude sets the heap size per exec. A value here would reach every
  # shell the box starts and could only disagree with it.
  run grep '^su ' "$ORDER_LOG"
  assert_output "su NODE_OPTIONS=unset"
  run cat "$TEE_LOG"
  refute_output --partial "node-options"
}

# ── The relay supervisor itself (docker/cleat-egress-shim) ──────────────────
# The helpers that run it live in test/lib/egress_shim.bash.

@test "egress shim: relays loopback 3128 into the proxy socket with bounded children" {
  _shim_setup
  _shim_start
  _shim_await "$SOCAT_LOG" '^listen'
  _shim_stop
  run grep '^listen' "$SOCAT_LOG"
  assert_output --partial "-T 900 TCP-LISTEN:3128,fork,max-children=128,backlog=256,reuseaddr,bind=127.0.0.1 UNIX-CONNECT:$SHIM_SOCK"
  # It never writes where the gateway's socket lives.
  run ls -A "$SHIM_DIR/run-egress"
  assert_output ""
}

@test "egress shim: a relay that dies is started again" {
  _shim_setup
  SOCAT_HOLD=0 SOCAT_RC=1 _shim_start
  _shim_await "$SOCAT_LOG" '^listen' 2
  _shim_await "$SHIM_LOG" 'relay exited rc=1'
  _shim_stop
  run grep -c '^listen' "$SOCAT_LOG"
  [ "$output" -ge 2 ]
  run cat "$SHIM_LOG"
  assert_output --partial "relay started pid="
  assert_output --partial "relay exited rc=1"
}

@test "egress shim: the heartbeat asks for the reserved target and never as a selftest" {
  _shim_setup
  _shim_start
  _shim_await "$SOCAT_LOG" '^beat'
  _shim_stop
  # One beat or more, each the same 79 bytes: compare the first.
  run head -c 79 "$BEAT_LOG"
  assert_output "$(printf 'CONNECT cleat-gateway.invalid:443 HTTP/1.1\r\nHost: cleat-gateway.invalid:443\r\n\r\n')"
  run grep -ci 'selftest' "$BEAT_LOG"
  assert_output "0"
  run grep -m1 '^beat' "$SOCAT_LOG"
  assert_output --partial " - TCP:127.0.0.1:3128"
  run head -1 "$TIMEOUT_LOG"
  assert_output --partial "3 socat - TCP:127.0.0.1:3128"
}

@test "egress shim: a second supervisor exits while one holds the lock" {
  _shim_setup
  FLOCK_RC=1 _shim_run_bounded
  run echo "$SHIM_RC"
  assert_output "0"
  run cat "$FLOCK_LOG"
  assert_output "-n 9"
  [ ! -e "$SOCAT_LOG" ]
  [ ! -e "$SHIM_LOG" ]
}

@test "egress shim: neither the relay nor the heartbeat inherits the lock descriptor" {
  # A relay holding fd 9 would outlive a dead supervisor and keep the lock, so
  # every later start would exit as already running with nothing supervising.
  _shim_setup
  _shim_start
  _shim_await "$SOCAT_LOG" '^listen'
  _shim_await "$SOCAT_LOG" '^beat'
  _shim_stop
  run grep -c 'fd9=open' "$SOCAT_LOG"
  assert_output "0"
  run grep -c '^listen fd9=closed' "$SOCAT_LOG"
  [ "$output" -ge 1 ]
  run grep -c '^beat fd9=closed' "$SOCAT_LOG"
  [ "$output" -ge 1 ]
}

@test "egress shim: --beat sends one heartbeat and takes no lock" {
  _shim_setup
  _shim_run_bounded --beat
  run echo "$SHIM_RC"
  assert_output "0"
  run grep -c '^beat' "$SOCAT_LOG"
  assert_output "1"
  run grep -c '^listen' "$SOCAT_LOG"
  assert_output "0"
  [ ! -e "$FLOCK_LOG" ]
  [ ! -e "$SHIM_LOCK" ]
}

@test "egress shim: a log past 1 MiB is emptied before the relay starts" {
  # socat logs a line per failed connection while the gateway is down.
  _shim_setup
  head -c 1048577 /dev/zero | tr '\0' x > "$SHIM_LOG"
  _shim_start
  _shim_await "$SHIM_LOG" 'relay started'
  _shim_stop
  run wc -c < "$SHIM_LOG"
  [ "$(printf '%s' "$output" | tr -d ' ')" -lt 1000 ]
  # A log at the cap is left alone.
  head -c 1048576 /dev/zero | tr '\0' x > "$SHIM_LOG"
  _shim_start
  _shim_await "$SHIM_LOG" 'relay started'
  _shim_stop
  run wc -c < "$SHIM_LOG"
  [ "$(printf '%s' "$output" | tr -d ' ')" -gt 1048576 ]
}

@test "egress shim: a stop signal still ends the supervisor and its heartbeat loop for good" {
  # Both start themselves again from an EXIT trap, which bash runs on a signal
  # too. TERM must still end them and never start them again.
  local sup beats i=0 sup_left=no beats_left=no
  _shim_setup
  SOCAT_HOLD=30 _shim_start
  _shim_await "$SOCAT_LOG" '^listen'
  _shim_await "$SOCAT_LOG" '^beat'
  sup="$(cat "$SHIM_DIR/sup.pid")"
  beats="$(cat "$TIMEOUT_LOG.ppid")"
  kill -TERM "$beats" "$sup"
  while { kill -0 "$sup" || kill -0 "$beats"; } 2>/dev/null && [ "$i" -lt 30 ]; do
    sleep 0.1; i=$((i + 1))
  done
  kill -0 "$sup" 2>/dev/null && sup_left=yes
  kill -0 "$beats" 2>/dev/null && beats_left=yes
  _shim_stop
  run echo "supervisor $sup_left, heartbeat loop $beats_left"
  assert_output "supervisor no, heartbeat loop no"
  run grep -c 'started again in place' "$SHIM_LOG"
  assert_output "0"
}

@test "egress shim: the fourth quick end in a row is the last one, never a spin" {
  # A fork that fails at once is never retried by bash, so a supervisor that
  # started itself again after every end could spin. USR1 ends it the way a
  # failed fork does, through its EXIT trap, well inside five seconds each time.
  local sup n i=0 left=no
  _shim_setup
  SOCAT_HOLD=30 _shim_start
  sup="$(cat "$SHIM_DIR/sup.pid")"
  for n in 1 2 3; do
    _shim_await "$SOCAT_LOG" '^listen' "$n"
    kill -USR1 "$sup"
    _shim_await "$SHIM_LOG" 'started again in place' "$n"
  done
  _shim_await "$SOCAT_LOG" '^listen' 4
  kill -USR1 "$sup"
  while kill -0 "$sup" 2>/dev/null && [ "$i" -lt 30 ]; do sleep 0.1; i=$((i + 1)); done
  kill -0 "$sup" 2>/dev/null && left=yes
  _shim_stop
  run echo "supervisor left: $left"
  assert_output "supervisor left: no"
  run grep -c 'started again in place' "$SHIM_LOG"
  assert_output "3"
}

@test "egress shim: a heartbeat loop carries its count of quick ends through each restart and stops at the fourth" {
  # The heartbeat loop starts itself again the way the supervisor does, so it
  # has the same bound. Its count rides on its command line from one shell to
  # the next. Dropped there, a loop whose fork fails at once restarts forever.
  # Each restart is awaited until the new shell beats, so its trap is set.
  local sup beats relay n c i=0 left=no sup_left=no
  _shim_setup
  SOCAT_HOLD=30 _shim_start
  _shim_await "$SOCAT_LOG" '^beat'
  sup="$(cat "$SHIM_DIR/sup.pid")"
  beats="$(cat "$TIMEOUT_LOG.ppid")"
  relay="$(head -1 "$SOCAT_LOG.pids")"
  for n in 1 2 3; do
    kill -USR1 "$beats"
    _shim_await_cmdline "$beats" "--beats $relay $n"
    c="$(grep -c '^beat' "$SOCAT_LOG")" || c=0
    _shim_await "$SOCAT_LOG" '^beat' "$((c + 1))"
  done
  kill -USR1 "$beats"
  while kill -0 "$beats" 2>/dev/null && [ "$i" -lt 30 ]; do sleep 0.1; i=$((i + 1)); done
  kill -0 "$beats" 2>/dev/null && left=yes
  kill -0 "$sup" 2>/dev/null && sup_left=yes
  _shim_stop
  run echo "heartbeat loop left: $left"
  assert_output "heartbeat loop left: no"
  # Only the loop stopped. Its supervisor still holds the lock.
  run echo "supervisor left: $sup_left"
  assert_output "supervisor left: yes"
}

@test "egress shim: an end after five seconds starts the count of quick ends again" {
  # Only quick ends in a row stop a shell. Without the reset, the fourth pid
  # exhaustion in a box's life, hours apart, would stop its relay for good.
  local sup n line
  _shim_setup
  SOCAT_HOLD=30 _shim_start
  sup="$(cat "$SHIM_DIR/sup.pid")"
  for n in 1 2 3; do
    _shim_await "$SOCAT_LOG" '^listen' "$n"
    kill -USR1 "$sup"
    _shim_await "$SHIM_LOG" 'started again in place' "$n"
  done
  _shim_await "$SOCAT_LOG" '^listen' 4
  # SECONDS counts whole seconds, so 5.5 s is past five whatever the start.
  sleep 5.5
  kill -USR1 "$sup"
  _shim_await "$SHIM_LOG" 'started again in place' 4
  _shim_await_cmdline "$sup" "--again 0"
  line="$(_shim_cmdline "$sup")"
  _shim_stop
  run echo "$line"
  assert_output "bash $SHIM --again 0"
  run grep -c 'started again in place' "$SHIM_LOG"
  assert_output "4"
}
