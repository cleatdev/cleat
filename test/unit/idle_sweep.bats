#!/usr/bin/env bats
# ── Idle-session sweep ────────────────────────────────────────────────────────
#
# Closing a terminal ends the foreground `docker exec` but leaves the container
# running, still reserving its memory ceiling. A day of closed-terminal boxes
# can over-commit the Docker VM. The sweep stops boxes that are PROVABLY safe to
# stop, on every interactive start, and NEVER a box that is working unattended
# (the "leave it running, walk away" promise): the liveness gate (no claude/node
# process) can only be false AFTER the terminal closed and claude exited.
#
# Safety design under test:
#   - _box_has_live_agent: a claude/node process => skip (attached OR working).
#       Fails SAFE: unreadable/empty `docker top` is treated as "live".
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

@test "live_agent: TRUE when a claude/node process is in docker top" {
  docker() { [[ "$1" == "top" ]] && printf 'UID PID CMD\n501 1 bash\n501 2 node /home/coder/.local/share/claude/versions/2.1.195/cli.js\n'; return 0; }
  run _box_has_live_agent some-box
  assert_success
}

@test "live_agent: FALSE for a detached box (only docker-init/su/bash)" {
  docker() { [[ "$1" == "top" ]] && printf 'UID PID CMD\nroot 1 /sbin/docker-init -- /entrypoint.sh bash\nroot 2 su -s /bin/bash coder -c bash\n501 3 bash\n'; return 0; }
  run _box_has_live_agent some-box
  assert_failure
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
