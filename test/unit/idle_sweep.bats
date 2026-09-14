#!/usr/bin/env bats
# ── Idle-session sweep ────────────────────────────────────────────────────────
#
# Closing a terminal ends the foreground `docker exec` but leaves the container
# running, still reserving its memory ceiling. A day of closed-terminal boxes
# can over-commit the Docker VM. The sweep stops boxes that are PROVABLY safe to
# stop, on every interactive start, and NEVER a box that is working unattended
# (the "leave it running, walk away" promise): the liveness gate (no Claude
# process) can only be false AFTER the terminal closed and claude exited.
#
# Safety design under test:
#   - _box_has_live_agent: a Claude process (judged by its executable, never a
#       substring, so a leftover node dev server is not one) => skip (attached
#       OR working). Fails SAFE: unreadable/empty `docker top`, or one with no
#       command column, is treated as "live".
#   - grace window: only boxes idle past the window are eligible; unknown age
#       (mtime 0) is skipped (never stop on an unknown clock).
#   - self exclusion: never stops the box being launched.
# See bin/cleat (_box_has_live_agent / _sweep_idle_boxes / _maybe_sweep_idle_boxes).

load "../setup"

setup() {
  _common_setup
  use_docker_stub
  source_cli
  CLEAT_RUN_DIR="$TEST_TEMP/run"
  mkdir -p "$CLEAT_RUN_DIR"
}
teardown() { _common_teardown; }

# ── _box_has_live_agent ──────────────────────────────────────────────────────

@test "live_agent: TRUE when a claude process is in docker top" {
  docker() { [[ "$1" == "top" ]] && printf 'UID PID CMD\n501 1 bash\n501 2 node /home/coder/.local/share/claude/versions/2.1.195/cli.js\n'; return 0; }
  run _box_has_live_agent some-box
  assert_success
}

@test "live_agent: FALSE for a detached box (only docker-init/su/bash)" {
  docker() { [[ "$1" == "top" ]] && printf 'UID PID CMD\nroot 1 /sbin/docker-init -- /entrypoint.sh bash\nroot 2 su -s /bin/bash coder -c bash\n501 3 bash\n'; return 0; }
  run _box_has_live_agent some-box
  assert_failure
}

# Every shape a running Claude really takes must keep reading live. The first is
# copied from /proc on a box running Claude Code 2.1.270 under exec_claude. The
# daemon row is how Claude runs its background-agent daemon (process.execPath,
# the versioned binary). The node rows are an npm install, shebang flags first.
@test "live_agent: TRUE for every process shape a running Claude takes" {
  local cmd
  for cmd in \
    'claude --dangerously-skip-permissions --continue' \
    '/home/coder/.local/bin/claude -p summarise' \
    '/home/coder/.local/share/claude/versions/2.1.270 daemon run --origin transient' \
    'node --no-warnings --enable-source-maps /usr/local/bin/claude' \
    '/usr/local/bin/node /usr/local/lib/node_modules/@anthropic-ai/claude-code/cli.js'; do
    docker() { [[ "$1" == "top" ]] && printf 'UID PID PPID C STIME TTY TIME CMD\n501 1 0 0 09:14 ? 00:00:00 /sbin/docker-init -- /entrypoint.sh bash\n501 7 1 0 09:15 pts/0 00:00:03 %s\n' "$cmd"; return 0; }
    run _box_has_live_agent some-box
    assert_success
  done
}

# The handoff this primitive has to serve stops claude and relaunches it from
# the same session wrapper, whose `bash -c` script text names claude. Reading
# that wrapper as Claude would make "Claude is gone" unprovable.
@test "live_agent: FALSE once claude exited, even with cleat's session wrapper still up" {
  docker() { [[ "$1" == "top" ]] && printf '%s\n' 'UID PID PPID C STIME TTY TIME CMD' \
    '501 1 0 0 09:14 ? 00:00:00 /sbin/docker-init -- /entrypoint.sh bash' \
    '501 9 0 0 09:15 pts/0 00:00:00 runuser -u coder -- bash -c ?      clip-daemon &?      claude "$@"?      _CLAUDE_RC=$?? _ --dangerously-skip-permissions' \
    '501 10 9 0 09:15 pts/0 00:00:00 bash -c ?      clip-daemon &?      claude "$@"?      _CLAUDE_RC=$?? _ --dangerously-skip-permissions' \
    '501 11 10 0 09:15 pts/0 00:00:00 /bin/bash /usr/local/bin/clip-daemon' \
    '501 12 1 0 09:15 ? 00:00:00 [claude] <defunct>'; return 0; }
  run _box_has_live_agent some-box
  assert_failure
}

@test "live_agent: reads the COMMAND column of a busybox ps layout" {
  docker() { [[ "$1" == "top" ]] && printf 'PID   USER     TIME  COMMAND\n    1 root      0:00 /sbin/docker-init -- /entrypoint.sh bash\n    7 501       0:04 node /workspace/node_modules/.bin/vite --host\n'; return 0; }
  run _box_has_live_agent some-box
  assert_failure
  docker() { [[ "$1" == "top" ]] && printf 'PID   USER     TIME  COMMAND\n    1 root      0:00 /sbin/docker-init -- /entrypoint.sh bash\n    8 501       0:09 claude -p summarise\n'; return 0; }
  run _box_has_live_agent some-box
  assert_success
}

# Ragged and hostile rows. The bare `node` REPL is the bash 3.2 trap (a `for w
# in "$@"` over no arguments reads as unbound under set -u). The short row, the
# blank line and the tab-separated row are what a ps layout can hand back. The
# lookalikes are a third-party CLI whose name starts with claude and a script
# named claude.js, neither of which is Claude Code.
@test "live_agent: FALSE for ragged rows, a bare node REPL and a claude lookalike" {
  docker() { [[ "$1" == "top" ]] && printf '%s\n' \
    'UID PID PPID C STIME TTY TIME CMD' \
    '501 1 0 0 09:14 ? 00:00:00 /sbin/docker-init -- /entrypoint.sh bash' \
    '501 2' \
    '' \
    '501 3 0 0 09:14 ? 00:00:00 node' \
    '501 4 0 0 09:14 ? 00:00:00 node -e require("claude")' \
    '501 5 0 0 09:14 ? 00:00:00 node --max-old-space-size=4096 dist/server.js' \
    '501 6 0 0 09:14 ? 00:00:00 claude-monitor --watch' \
    '501 7 0 0 09:14 ? 00:00:00 /opt/tools/claude.js --serve' \
    '501 8 0 0 09:14 ? 00:00:00 [claude] <defunct>'; return 0; }
  run _box_has_live_agent some-box
  assert_failure
}

# The positive control for the row above: the SAME ragged table with one real
# Claude appended must read live, so the test above proves narrowness and not
# that the reader gave up on a ragged table.
@test "live_agent: TRUE when a real claude sits below ragged rows" {
  docker() { [[ "$1" == "top" ]] && printf '%s\n' \
    'UID PID PPID C STIME TTY TIME CMD' \
    '501 2' \
    '' \
    '501 3 0 0 09:14 ? 00:00:00 node' \
    '501 6 0 0 09:14 ? 00:00:00 claude-monitor --watch' \
    '501 9 0 0 09:15 pts/0 00:00:09 claude --dangerously-skip-permissions'; return 0; }
  run _box_has_live_agent some-box
  assert_success
}

@test "live_agent: SAFE (assumes live) when docker top has no command column" {
  docker() { [[ "$1" == "top" ]] && printf 'PROCESS LIST\nnode /workspace/node_modules/.bin/vite --host\n'; return 0; }
  run _box_has_live_agent some-box
  assert_success
}

@test "live_agent: SAFE (assumes live) when docker top is unreadable" {
  docker() { return 1; }   # daemon hiccup
  run _box_has_live_agent some-box
  assert_success
}

@test "live_agent: SAFE (assumes live) when docker top is empty" {
  docker() { printf ''; return 0; }
  run _box_has_live_agent some-box
  assert_success
}

# ── _running_cleat_boxes / _running_cleat_box_count ──────────────────────────

@test "running_cleat_boxes: lists names from the label-filtered ps" {
  mock_docker_ps $'cleat-foo-11111111\ncleat-bar-22222222'
  run _running_cleat_boxes
  assert_line "cleat-foo-11111111"
  assert_line "cleat-bar-22222222"
}

@test "running_cleat_box_count: counts running cleat boxes" {
  mock_docker_ps $'cleat-foo-11111111\ncleat-bar-22222222\ncleat-baz-33333333'
  run _running_cleat_box_count
  assert_output "3"
}

@test "running_cleat_box_count: zero when none are running" {
  mock_docker_ps ''
  run _running_cleat_box_count
  assert_output "0"
}

# ── _sweep_idle_boxes ────────────────────────────────────────────────────────

@test "sweep: stops an idle, detached box past the grace window" {
  _running_cleat_boxes() { printf '%s\n' "cleat-idle-11111111"; }
  _box_has_live_agent() { return 1; }     # no agent running
  _path_mtime() { echo 1000; }            # ancient mtime (real now is ~1.7e9)
  mock_docker_inspect 5368709120          # 5 GiB ceiling
  run _sweep_idle_boxes "" 1800
  assert_success
  assert_output --partial "Stopped 1 idle session"
  run grep -F "docker stop cleat-idle-11111111" "$DOCKER_CALLS"
  assert_success
}

@test "sweep: NEVER stops a box with a live agent (unattended work is protected)" {
  _running_cleat_boxes() { printf '%s\n' "cleat-working-11111111"; }
  _box_has_live_agent() { return 0; }     # agent IS running
  _path_mtime() { echo 1000; }            # old enough, but liveness wins
  run _sweep_idle_boxes "" 1800
  assert_success
  refute_output --partial "Stopped"
  run grep -F "docker stop" "$DOCKER_CALLS"
  assert_failure
}

@test "sweep: leaves a recently-detached box alone (inside the grace window)" {
  _running_cleat_boxes() { printf '%s\n' "cleat-recent-11111111"; }
  _box_has_live_agent() { return 1; }
  _path_mtime() { echo "$(( $(date +%s) - 60 ))"; }   # detached 60s ago
  run _sweep_idle_boxes "" 1800
  refute_output --partial "Stopped"
  run grep -F "docker stop" "$DOCKER_CALLS"
  assert_failure
}

@test "sweep: skips a box with unknown age (mtime 0), never stops on an unknown clock" {
  _running_cleat_boxes() { printf '%s\n' "cleat-noage-11111111"; }
  _box_has_live_agent() { return 1; }
  _path_mtime() { echo 0; }
  run _sweep_idle_boxes "" 1800
  refute_output --partial "Stopped"
  run grep -F "docker stop" "$DOCKER_CALLS"
  assert_failure
}

@test "sweep: never stops the box being launched (self exclusion)" {
  _running_cleat_boxes() { printf '%s\n' "cleat-self-11111111"; }
  _box_has_live_agent() { return 1; }     # would be eligible if not self
  _path_mtime() { echo 1000; }
  run _sweep_idle_boxes "cleat-self-11111111" 1800
  refute_output --partial "Stopped"
  run grep -F "docker stop" "$DOCKER_CALLS"
  assert_failure
}

@test "sweep: stops multiple idle boxes in one call and sums freed memory" {
  _running_cleat_boxes() { printf '%s\n' "cleat-a-11111111" "cleat-b-22222222"; }
  _box_has_live_agent() { return 1; }
  _path_mtime() { echo 1000; }
  mock_docker_inspect 5368709120          # 5 GiB each
  run _sweep_idle_boxes "" 1800
  assert_output --partial "Stopped 2 idle sessions"
  assert_output --partial "freed 10 GB"
  run grep -E "docker stop .*cleat-a-11111111.*cleat-b-22222222" "$DOCKER_CALLS"
  assert_success
}

# Grace gate against the REAL filesystem (no _path_mtime mock), so the run-dir
# mtime anchor is actually exercised. exec_claude / _cleanup_session re-stamp the
# run dir on attach/detach, so its mtime is the time since the box last had a
# session; the sweep stats THAT dir.
@test "sweep (real mtime): stops a box whose run dir is older than the grace" {
  _running_cleat_boxes() { printf '%s\n' "cleat-old-11111111"; }
  _box_has_live_agent() { return 1; }
  mock_docker_inspect 5368709120
  mkdir -p "$CLEAT_RUN_DIR/cleat-old-11111111"
  touch -t 200001010000 "$CLEAT_RUN_DIR/cleat-old-11111111"   # year 2000: far past any grace
  run _sweep_idle_boxes "" 1800
  assert_output --partial "Stopped 1 idle session"
  run grep -F "docker stop cleat-old-11111111" "$DOCKER_CALLS"
  assert_success
}

@test "sweep (real mtime): leaves a box whose run dir was just stamped (within grace)" {
  _running_cleat_boxes() { printf '%s\n' "cleat-fresh-22222222"; }
  _box_has_live_agent() { return 1; }
  mkdir -p "$CLEAT_RUN_DIR/cleat-fresh-22222222"
  touch "$CLEAT_RUN_DIR/cleat-fresh-22222222"                 # now: inside the grace window
  run _sweep_idle_boxes "" 1800
  refute_output --partial "Stopped"
  run grep -F "docker stop" "$DOCKER_CALLS"
  assert_failure
}

@test "sweep: a live box and an idle box together => only the idle one stops" {
  _running_cleat_boxes() { printf '%s\n' "cleat-live-11111111" "cleat-idle-22222222"; }
  _box_has_live_agent() { [[ "$1" == "cleat-live-11111111" ]]; }   # live ONLY for the first
  _path_mtime() { echo 1000; }
  mock_docker_inspect 5368709120
  run _sweep_idle_boxes "" 1800
  assert_output --partial "Stopped 1 idle session"
  run grep -F "docker stop cleat-idle-22222222" "$DOCKER_CALLS"
  assert_success
  run grep -F "cleat-live-11111111" "$DOCKER_CALLS"
  assert_failure   # the live box is never touched, not even inspected for stop
}

# ── _maybe_sweep_idle_boxes (the on-start wrapper) ───────────────────────────

@test "maybe_sweep: no-op off a TTY (never on a pipe or in cron)" {
  _is_tty() { return 1; }
  _sweep_idle_boxes() { echo "SWEEP RAN"; }
  run _maybe_sweep_idle_boxes
  refute_output --partial "SWEEP RAN"
}

@test "maybe_sweep: no-op when CLEAT_NO_IDLE_SWEEP=1" {
  _is_tty() { return 0; }
  _sweep_idle_boxes() { echo "SWEEP RAN"; }
  CLEAT_NO_IDLE_SWEEP=1 run _maybe_sweep_idle_boxes
  refute_output --partial "SWEEP RAN"
}

@test "maybe_sweep: passes the launching box's cname as self (so it is excluded)" {
  _is_tty() { return 0; }
  container_name_for() { echo "cleat-SELF-CNAME"; }
  _sweep_idle_boxes() { echo "self=$1 grace=$2"; }
  run _maybe_sweep_idle_boxes dev
  assert_output --partial "self=cleat-SELF-CNAME"
}

@test "maybe_sweep: default grace is 30 minutes (1800s)" {
  _is_tty() { return 0; }
  container_name_for() { echo "cleat-x"; }
  _sweep_idle_boxes() { echo "grace=$2"; }
  run _maybe_sweep_idle_boxes
  assert_output --partial "grace=1800"
}

@test "maybe_sweep: honors CLEAT_IDLE_GRACE_MINS override" {
  _is_tty() { return 0; }
  container_name_for() { echo "cleat-x"; }
  _sweep_idle_boxes() { echo "grace=$2"; }
  CLEAT_IDLE_GRACE_MINS=10 run _maybe_sweep_idle_boxes
  assert_output --partial "grace=600"
}

@test "maybe_sweep: skips entirely for a malformed invocation (extra positional)" {
  _is_tty() { return 0; }
  _sweep_idle_boxes() { echo "SWEEP RAN"; }   # _set_box will reject the extra arg
  run _maybe_sweep_idle_boxes dev extra
  refute_output --partial "SWEEP RAN"
}

@test "maybe_sweep: skips entirely for an invalid box name" {
  _is_tty() { return 0; }
  _sweep_idle_boxes() { echo "SWEEP RAN"; }
  run _maybe_sweep_idle_boxes 'bad name!'
  refute_output --partial "SWEEP RAN"
}

@test "sweep: a box with an open cleat shell is never stopped" {
  # A shell session runs bash, and _box_has_live_agent deliberately does not
  # count bash as live because a DETACHED box runs bash too. cmd_shell also
  # never stamped the run dir, so the sweep measured idleness from the last
  # CLAUDE session and stopped the container out from under someone sitting at
  # its prompt.
  mkdir -p "$CLEAT_RUN_DIR/cleat-a-11112222-main"
  : > "$CLEAT_RUN_DIR/cleat-a-11112222-main/.attached.$$"
  run _box_has_attached_session "cleat-a-11112222-main"
  assert_success
}

@test "sweep: a marker from a dead session does not pin the box forever" {
  # Otherwise a crashed or killed shell would make the box permanently
  # unsweepable, which is the opposite failure.
  mkdir -p "$CLEAT_RUN_DIR/cleat-b-33334444-main"
  : > "$CLEAT_RUN_DIR/cleat-b-33334444-main/.attached.999999"
  run _box_has_attached_session "cleat-b-33334444-main"
  assert_failure
  [ ! -e "$CLEAT_RUN_DIR/cleat-b-33334444-main/.attached.999999" ] \
    || { echo "stale marker was not cleaned up"; return 1; }
}

@test "sweep: a box with no attach marker is still sweepable" {
  mkdir -p "$CLEAT_RUN_DIR/cleat-c-55556666-main"
  run _box_has_attached_session "cleat-c-55556666-main"
  assert_failure
}

@test "sweep: an attached box survives a real sweep pass" {
  # Asserted on the DOCKER CALL, not on the summary line: the sweep reports a
  # count, never the names, so output alone cannot tell whether this box was
  # stopped.
  mkdir -p "$CLEAT_RUN_DIR/cleat-att-11112222-main"
  : > "$CLEAT_RUN_DIR/cleat-att-11112222-main/.attached.$$"
  touch -t 200001010000 "$CLEAT_RUN_DIR/cleat-att-11112222-main" 2>/dev/null || true
  _running_cleat_boxes() { echo "cleat-att-11112222-main"; }
  _box_has_live_agent() { return 1; }
  _sweep_idle_boxes "" 1
  run grep -c "^docker stop .*cleat-att-11112222-main" "$DOCKER_CALLS"
  assert_output "0"
}

@test "sweep: an UNattached idle box is still stopped" {
  # The other half. Without it the test above would pass even if the sweep
  # had been disabled entirely.
  mkdir -p "$CLEAT_RUN_DIR/cleat-idle-11112222-main"
  touch -t 200001010000 "$CLEAT_RUN_DIR/cleat-idle-11112222-main" 2>/dev/null || true
  _running_cleat_boxes() { echo "cleat-idle-11112222-main"; }
  _box_has_live_agent() { return 1; }
  _sweep_idle_boxes "" 1
  run grep -c "^docker stop .*cleat-idle-11112222-main" "$DOCKER_CALLS"
  refute_output "0"
}
