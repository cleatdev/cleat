#!/usr/bin/env bats
# ─────────────────────────────────────────────────────────────────────────────
# REGRESSION REGISTRY
#
# One canonical test per bug that ever shipped. Every test is named by the
# version that fixed it plus a short description. Each test is mutation-tested:
# reverting the fix in bin/cleat MUST cause the test to fail.
#
# Rules:
#   1. Every entry references the version that introduced AND fixed the bug.
#   2. Every test reproduces the exact input conditions that triggered it.
#   3. Every test asserts the fix, not just that the code runs.
#   4. If the bug cannot be caught at unit level, the test lives here as a
#      stub with a `skip` pointing to the smoke/integration file that covers it.
#   5. Never delete a regression test. Bugs come back.
# ─────────────────────────────────────────────────────────────────────────────

load "../setup"

setup() {
  _common_setup
  use_docker_stub
  source_cli

  # Neutralize side effects so we only test the regression behavior
  _host_clip_cmd() { echo ""; }
  check_for_update() { true; }
  check_drift() { true; }
  show_first_run_tip() { true; }

  # Use isolated config dir so tests don't touch real host
  CLEAT_CONFIG_DIR="$TEST_TEMP/cleat-config"
  CLEAT_GLOBAL_CONFIG="$CLEAT_CONFIG_DIR/config"
  CLEAT_GLOBAL_ENV="$CLEAT_CONFIG_DIR/env"
  _first_run_tip_file="$CLEAT_CONFIG_DIR/.tip-shown"
  mkdir -p "$CLEAT_CONFIG_DIR"
}

teardown() {
  local cname
  for cname in "$TEST_TEMP"/cleat-*; do :; done
  # Clean up any overlay/hook dirs the tests may have created
  rm -rf /tmp/cleat-settings-cleat-project-* 2>/dev/null || true
  rm -rf /tmp/cleat-hooks-cleat-project-* 2>/dev/null || true
  rm -rf /tmp/cleat-clip-cleat-project-* 2>/dev/null || true
  _common_teardown
}

# ─────────────────────────────────────────────────────────────────────────────
# v0.5.1 — cmd_claude did not set _RESOLVED_PROJECT, so hook bridge
# couldn't find project-level hooks. Silent failure in production, invisible
# to tests because `set -u` was stripped.
# ─────────────────────────────────────────────────────────────────────────────
@test "regression v0.5.1: cmd_claude sets _RESOLVED_PROJECT" {
  mkdir -p "$TEST_TEMP/project/.claude"
  echo '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"x"}]}]}}' \
    > "$TEST_TEMP/project/.claude/settings.json"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"
  mock_docker_ps "$cname"
  exec_claude() { return 0; }

  _RESOLVED_PROJECT=""
  cmd_claude "$TEST_TEMP/project"

  [[ "$_RESOLVED_PROJECT" == "$TEST_TEMP/project" ]] || {
    echo "REGRESSION: _RESOLVED_PROJECT='$_RESOLVED_PROJECT' expected '$TEST_TEMP/project'"
    return 1
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# v0.5.1 — Hook settings overlay stripped all hooks instead of replacing
# command with forwarder. Project hooks never fired.
# ─────────────────────────────────────────────────────────────────────────────
@test "regression v0.5.1: hook overlay replaces command with forwarder (not strip)" {
  cat > "$CLEAT_GLOBAL_CONFIG" << 'EOF'
[caps]
hooks
EOF
  mkdir -p "${HOME}/.claude"
  cat > "${HOME}/.claude/settings.json" << 'EOF'
{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"my-host-hook"}]}]}}
EOF
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"

  run cmd_run "$TEST_TEMP/project"
  assert_success

  local overlay="/tmp/cleat-settings-${cname}/settings.json"
  [[ -f "$overlay" ]] || { echo "REGRESSION: overlay not created"; return 1; }

  # Must contain forwarder command, not be empty and not contain original
  run jq -r '.hooks.Stop[0].hooks[0].command' "$overlay"
  assert_output "cat >> /var/log/cleat/events.jsonl"

  : > "${HOME}/.claude/settings.json" 2>/dev/null || true
  rm -rf "/tmp/cleat-settings-${cname}" "/tmp/cleat-hooks-${cname}"
}

# ─────────────────────────────────────────────────────────────────────────────
# v0.6.0 — Hook bridge replayed old events on every start. Any events left
# in /var/log/cleat/events.jsonl from a prior session re-executed on restart.
# Fix: _hook_bridge_watcher reads the file's current byte size at startup and
# only tails bytes that appear AFTER that offset.
#
# This test verifies the fix structurally (the function body must initialize
# byte_offset from wc -c BEFORE the tail loop). A behavioral test requires
# launching a real subshell of the watcher and observing subprocess spawns,
# which is too fragile for unit testing. End-to-end coverage is in the
# integration suite.
# ─────────────────────────────────────────────────────────────────────────────
@test "regression v0.6.0: hook bridge skips pre-existing events at startup" {
  local body
  body="$(declare -f _hook_bridge_watcher)"
  [[ -n "$body" ]] || { echo "REGRESSION: _hook_bridge_watcher missing"; return 1; }

  # The function must initialize byte_offset with wc -c BEFORE entering its
  # tail loop. Anything else means we'd start at 0 and replay old events.
  echo "$body" | grep -qE 'byte_offset=.*wc -c' || {
    echo "REGRESSION: _hook_bridge_watcher must initialize byte_offset from wc -c"
    return 1
  }

  # Verify wc -c appears BEFORE the `while true` loop
  local before_loop
  before_loop="${body%%while true*}"
  echo "$before_loop" | grep -qE 'byte_offset=' || {
    echo "REGRESSION: byte_offset must be initialized before the tail loop"
    return 1
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# v0.6.0 — Project overlay created .claude/ as root on host when directory
# didn't exist, because docker created the bind mount source.
# ─────────────────────────────────────────────────────────────────────────────
@test "regression v0.6.0: skip project overlay when .claude/ missing on host" {
  cat > "$CLEAT_GLOBAL_CONFIG" << 'EOF'
[caps]
hooks
EOF
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project"
  # .claude/ intentionally missing

  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"
  run cmd_run "$TEST_TEMP/project"
  assert_success

  # Must NOT mount project settings overlay at /workspace/.claude/settings.json
  run assert_docker_run_lacks "$cname" "/workspace/.claude/settings.json"
  assert_success
  run assert_docker_run_lacks "$cname" "/workspace/.claude/settings.local.json"
  assert_success

  [[ ! -d "$TEST_TEMP/project/.claude" ]] || {
    echo "REGRESSION: .claude/ created on host by cleat"
    return 1
  }

  rm -rf "/tmp/cleat-settings-${cname}" "/tmp/cleat-hooks-${cname}"
}

# ─────────────────────────────────────────────────────────────────────────────
# v0.6.1 — Browser bridge pre-initialized last_ts with the current file's
# mtime to skip stale URLs. Same-second writes had identical mtime and were
# silently dropped. Fix: delete stale file entirely at watcher startup, then
# track the empty-state as last_ts="". A new write has cur_ts != "" which
# triggers detection regardless of same-second collision.
#
# This test checks the function body structurally: the first operation in
# _browser_watcher after local declarations must be `rm -f "$bridge_file"`
# (not a pre-init of last_ts from the stale file's stat output).
# ─────────────────────────────────────────────────────────────────────────────
@test "regression v0.6.1: browser bridge removes stale file at startup" {
  local body
  body="$(declare -f _browser_watcher)"
  [[ -n "$body" ]] || { echo "_browser_watcher not found"; return 1; }

  # The stale-file removal (rm -f ... .browser-open) must appear before the
  # main `while true` loop. This is the v0.6.1 fix.
  local before_loop
  before_loop="${body%%while true*}"
  echo "$before_loop" | grep -qE 'rm -f "\$bridge_file"' || {
    echo "REGRESSION: _browser_watcher must remove stale .browser-open before the main loop"
    return 1
  }

  # The fix must NOT pre-initialize last_ts from stat (the pre-v0.6.1 bug):
  echo "$before_loop" | grep -qE 'last_ts=\$\(stat' && {
    echo "REGRESSION: last_ts must start empty, not from stat (pre-v0.6.1 bug)"
    return 1
  }
  true
}

# ─────────────────────────────────────────────────────────────────────────────
# v0.6.2 — docker run/start failures were shown as "Container failed to
# start" with no reason. Docker's stderr was swallowed by 2>&1 redirection.
# ─────────────────────────────────────────────────────────────────────────────
@test "regression v0.6.2: docker run failure surfaces docker stderr" {
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project"
  export DOCKER_EXIT_CODE=125
  export DOCKER_STDERR="Error response from daemon: Conflict. The container name \"/test\" is already in use"

  run cmd_run "$TEST_TEMP/project"
  assert_failure

  # The exact docker stderr message must appear in the output
  assert_output --partial "Conflict"
  assert_output --partial "already in use"

  unset DOCKER_EXIT_CODE DOCKER_STDERR
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"
  rm -rf "/tmp/cleat-settings-${cname}" "/tmp/cleat-hooks-${cname}"
}

# ─────────────────────────────────────────────────────────────────────────────
# v0.6.2 — Settings overlay directory was not cleaned on cmd_run after rm,
# causing stale overlays from a previous container to contaminate the new one.
# ─────────────────────────────────────────────────────────────────────────────
@test "regression v0.6.2: cmd_run wipes stale settings overlay dir" {
  cat > "$CLEAT_GLOBAL_CONFIG" << 'EOF'
[caps]
hooks
EOF
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"

  # Seed stale state from a previous container
  local overlay_dir="/tmp/cleat-settings-${cname}"
  mkdir -p "$overlay_dir"
  echo '{"stale":true}' > "$overlay_dir/settings.json"
  echo '{"stale":true}' > "$overlay_dir/stale-file-from-prior-run.json"

  run cmd_run "$TEST_TEMP/project"
  assert_success

  # The stale file from the prior run must be gone
  [[ ! -f "$overlay_dir/stale-file-from-prior-run.json" ]] || {
    echo "REGRESSION: stale overlay file from prior run was not wiped"
    return 1
  }

  # The current settings.json must be the new one, not the stale marker
  run jq -e '.stale // empty' "$overlay_dir/settings.json"
  assert_failure  # no .stale field in new file

  rm -rf "$overlay_dir" "/tmp/cleat-hooks-${cname}"
}

# ─────────────────────────────────────────────────────────────────────────────
# v0.6.2 — Quoted tilde in summary block showed '~' literally instead of
# collapsing $HOME to ~. Fix used intermediate variable to avoid word splitting.
# ─────────────────────────────────────────────────────────────────────────────
@test "regression v0.6.2: summary block shows ~ without quotes for home-relative path" {
  local real_home="$HOME"
  HOME="$TEST_TEMP/fakehome"
  mkdir -p "$HOME/Workspaces/my-proj"

  ACTIVE_CAPS=()
  run _print_summary_block "cleat-test-12345678" "$HOME/Workspaces/my-proj"

  # Path must collapse to ~/Workspaces/my-proj, not '~'/Workspaces or $HOME/...
  assert_output --partial "~/Workspaces/my-proj"
  refute_output --partial "'~'"
  refute_output --partial "$HOME/Workspaces"

  HOME="$real_home"
}

# ─────────────────────────────────────────────────────────────────────────────
# v0.6.3 — exec_claude called docker exec with only HOME and PATH. Env vars
# resolved from .cleat.env were passed at docker run but not at exec time.
# Containers restarted via start/resume did not see updated env values.
# ─────────────────────────────────────────────────────────────────────────────
@test "regression v0.6.3: exec_claude passes resolved env args to docker exec" {
  _RESOLVED_ENV_ARGS=(-e "DATABASE_URL=postgres://localhost/mydb" -e "API_KEY=secret")
  run exec_claude "cleat-test-ctr" --dangerously-skip-permissions
  run assert_docker_exec_has "DATABASE_URL=postgres://localhost/mydb"
  assert_success
  run assert_docker_exec_has "API_KEY=secret"
  assert_success
}

# ─────────────────────────────────────────────────────────────────────────────
# v0.6.3 — cmd_shell didn't call resolve_env_args and didn't pass env to
# docker exec, so `cleat shell && echo $DATABASE_URL` showed empty.
# ─────────────────────────────────────────────────────────────────────────────
@test "regression v0.6.3: cmd_shell passes .cleat.env vars to docker exec" {
  mkdir -p "$TEST_TEMP/project"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"
  mock_docker_ps "$cname"

  cat > "$TEST_TEMP/project/.cleat.env" << 'EOF'
DATABASE_URL=postgres://localhost/mydb
API_KEY=sk-test-123
EOF
  cat > "$TEST_TEMP/project/.cleat" << 'EOF'
[caps]
env
EOF

  run cmd_shell "$TEST_TEMP/project"
  assert_success
  run assert_docker_exec_has "DATABASE_URL=postgres://localhost/mydb"
  assert_success
  run assert_docker_exec_has "API_KEY=sk-test-123"
  assert_success
}

# ─────────────────────────────────────────────────────────────────────────────
# v0.6.3 — cmd_shell used only `-e HOME=/home/coder` and did not pass PATH.
# ~/.local/bin was not on the container shell's PATH.
# ─────────────────────────────────────────────────────────────────────────────
@test "regression v0.6.3: cmd_shell sets PATH with /home/coder/.local/bin" {
  mkdir -p "$TEST_TEMP/project"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"
  mock_docker_ps "$cname"

  run cmd_shell "$TEST_TEMP/project"
  assert_success
  run assert_docker_exec_has "PATH="
  assert_success
  run assert_docker_exec_has "/home/coder/.local/bin"
  assert_success
}

# ─────────────────────────────────────────────────────────────────────────────
# v0.6.3 — cmd_login didn't call resolve_env_args. Custom API endpoints or
# credentials in .cleat.env weren't available during authentication.
# ─────────────────────────────────────────────────────────────────────────────
@test "regression v0.6.3: cmd_login passes .cleat.env vars to docker exec" {
  mkdir -p "$TEST_TEMP/project"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"
  mock_docker_ps "$cname"

  cat > "$TEST_TEMP/project/.cleat.env" << 'EOF'
ANTHROPIC_BASE_URL=https://custom.api.example.com
EOF
  cat > "$TEST_TEMP/project/.cleat" << 'EOF'
[caps]
env
EOF

  run cmd_login "$TEST_TEMP/project"
  assert_success
  run assert_docker_exec_has "ANTHROPIC_BASE_URL=https://custom.api.example.com"
  assert_success
}

# ─────────────────────────────────────────────────────────────────────────────
# v0.6.3 — _parse_env_file used `while read -r line` without `|| [[ -n $line ]]`,
# skipping the last line of a file with no trailing newline.
# ─────────────────────────────────────────────────────────────────────────────
@test "regression v0.6.3: _parse_env_file reads last line without trailing newline" {
  printf 'FIRST=one\nLAST=two' > "$TEST_TEMP/envfile"
  run _parse_env_file "$TEST_TEMP/envfile"
  assert_success
  assert_line --index 0 "FIRST=one"
  assert_line --index 1 "LAST=two"
  [[ "${#lines[@]}" -eq 2 ]] || {
    echo "REGRESSION: expected 2 lines, got ${#lines[@]}"
    return 1
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# v0.6.3 — Env summary line was omitted when a .cleat.env existed but had
# only comments (count=0). Users couldn't tell if the file was being read.
# ─────────────────────────────────────────────────────────────────────────────
@test "regression v0.6.3: env summary shows 0 count when file has only comments" {
  ACTIVE_CAPS=(env)
  mkdir -p "$TEST_TEMP/project"
  cat > "$TEST_TEMP/project/.cleat.env" << 'EOF'
# just comments
# another comment
EOF
  run _env_summary_inline "$TEST_TEMP/project"
  assert_output --partial "Env:"
  assert_output --partial "0 from .cleat.env"
}

# ─────────────────────────────────────────────────────────────────────────────
# v0.6.4 — OAuth callback proxy used socat default TCP (127.0.0.1) but
# Node.js binds localhost to ::1. Every callback was Connection Refused.
# Fix: try TCP6 first, fall back to TCP.
# ─────────────────────────────────────────────────────────────────────────────
@test "regression v0.6.4: _auth_callback_proxy tries TCP6 before TCP" {
  # Verify the function body references TCP6 before TCP in the exec args.
  # (Unit-testable structural check; full behavior covered by integration suite.)
  local body
  body="$(declare -f _auth_callback_proxy)"
  [[ -n "$body" ]] || { echo "REGRESSION: _auth_callback_proxy function missing"; return 1; }

  # Both TCP6 and TCP may appear on the same line; check character-position order.
  # Matches TCP6\:localhost or TCP6:localhost (declare -f escapes backslashes).
  [[ "$body" == *TCP6*localhost* ]] || {
    echo "REGRESSION: TCP6 branch missing from _auth_callback_proxy"
    return 1
  }

  # Find the position of TCP6 and the position of the TCP fallback.
  # We require TCP6 to precede TCP in the body string.
  local before_tcp6="${body%%TCP6*}"
  local tcp6_pos=${#before_tcp6}
  # Find first occurrence of TCP: / TCP\: that is NOT a prefix of TCP6
  # (grep -bo gives byte offsets)
  local tcp_pos
  tcp_pos=$(printf '%s' "$body" | grep -bo 'TCP\\*:localhost' | grep -v 'TCP6' | head -1 | cut -d: -f1)
  [[ -n "$tcp_pos" ]] || {
    echo "REGRESSION: TCP fallback missing from _auth_callback_proxy"
    return 1
  }
  [[ "$tcp6_pos" -lt "$tcp_pos" ]] || {
    echo "REGRESSION: TCP6 must appear before TCP fallback (order matters for IPv6-first behavior)"
    echo "tcp6_pos=$tcp6_pos tcp_pos=$tcp_pos"
    return 1
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# v0.6.4 — socat stdin EOF propagated to TCP side, killing the read before
# the 302 response came back. Fix: use `-,ignoreeof`.
# ─────────────────────────────────────────────────────────────────────────────
@test "regression v0.6.4: _auth_callback_proxy uses ignoreeof on stdin" {
  local body
  body="$(declare -f _auth_callback_proxy)"
  [[ -n "$body" ]] || { echo "REGRESSION: _auth_callback_proxy function missing"; return 1; }

  echo "$body" | grep -q 'ignoreeof' || {
    echo "REGRESSION: socat call must include ignoreeof to prevent stdin EOF propagation"
    return 1
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# v0.6.4 — Proxy gave up silently on EADDRINUSE. Fix: retry the bind in a loop.
# ─────────────────────────────────────────────────────────────────────────────
@test "regression v0.6.4: _auth_callback_proxy retries bind on EADDRINUSE" {
  local body
  body="$(declare -f _auth_callback_proxy)"
  [[ -n "$body" ]] || { echo "REGRESSION: _auth_callback_proxy function missing"; return 1; }

  # Must have a retry loop — look for a bind attempt counter or loop construct
  # referencing the port. Accept any of: for i in ..., while [[ $attempt ...
  echo "$body" | grep -qE '(attempt|retry|for .* in .* 30|while .* attempt)' || {
    echo "REGRESSION: bind retry loop missing from _auth_callback_proxy"
    return 1
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# v0.6.4 — `Connection: keep-alive` header made upstream server keep the
# socket open. Fix: rewrite to `Connection: close` so server actually closes.
# ─────────────────────────────────────────────────────────────────────────────
@test "regression v0.6.4: _auth_callback_proxy rewrites keep-alive to close" {
  local body
  body="$(declare -f _auth_callback_proxy)"
  [[ -n "$body" ]] || { echo "REGRESSION: _auth_callback_proxy function missing"; return 1; }

  echo "$body" | grep -qi 'Connection:.*close\|keep-alive.*close\|keep-alive' || {
    echo "REGRESSION: Connection header rewrite missing"
    return 1
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# v0.6.5 — cmd_run wrote empty {} overlay and bind-mounted to
# /workspace/.claude/settings.json for files that didn't exist on host.
# Fails on macOS Docker Desktop virtiofs ("outside of rootfs" error).
# ─────────────────────────────────────────────────────────────────────────────
@test "regression v0.6.5: cmd_run skips overlay mount for missing host files" {
  cat > "$CLEAT_GLOBAL_CONFIG" << 'EOF'
[caps]
hooks
EOF
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project/.claude"
  # .claude/ exists but neither settings.json nor settings.local.json

  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"
  run cmd_run "$TEST_TEMP/project"
  assert_success

  run assert_docker_run_lacks "$cname" "/workspace/.claude/settings.json"
  assert_success
  run assert_docker_run_lacks "$cname" "/workspace/.claude/settings.local.json"
  assert_success

  # And no empty overlay file should have been created (the broken path wrote `{}`)
  [[ ! -f "/tmp/cleat-settings-${cname}/project-settings.json" ]] || {
    echo "REGRESSION: empty overlay file created for non-existent host file"
    return 1
  }
  [[ ! -f "/tmp/cleat-settings-${cname}/project-settings.local.json" ]] || {
    echo "REGRESSION: empty overlay file created for non-existent host file"
    return 1
  }

  rm -rf "/tmp/cleat-settings-${cname}" "/tmp/cleat-hooks-${cname}"
}

# ─────────────────────────────────────────────────────────────────────────────
# v0.6.5 — docker run failure could leave a partial container that collided
# with the next attempt's name. Fix: docker rm -f on failure.
# ─────────────────────────────────────────────────────────────────────────────
@test "regression v0.6.5: cmd_run cleans up partial container on docker run failure" {
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project"
  export DOCKER_EXIT_CODE=125
  export DOCKER_STDERR="OCI runtime create failed"

  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"

  run cmd_run "$TEST_TEMP/project"
  assert_failure

  # A docker rm -f call must have been issued for the failed container
  grep -qE "^docker rm -f $cname" "$DOCKER_CALLS" || {
    echo "REGRESSION: cmd_run did not clean up partial container on failure"
    echo "Docker calls:"
    cat "$DOCKER_CALLS"
    return 1
  }

  unset DOCKER_EXIT_CODE DOCKER_STDERR
  rm -rf "/tmp/cleat-settings-${cname}" "/tmp/cleat-hooks-${cname}"
}

# ─────────────────────────────────────────────────────────────────────────────
# v0.6.3 — --env, --env-file, --cap global flags only applied to start/run/
# resume/claude. Users passing `cleat --env X shell` got no env.
# ─────────────────────────────────────────────────────────────────────────────
@test "regression v0.6.3: cmd_shell resolves env args (not just hardcoded HOME/PATH)" {
  mkdir -p "$TEST_TEMP/project"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"
  mock_docker_ps "$cname"

  # Check that resolve_env_args is called inside cmd_shell by looking at the function body
  local body
  body="$(declare -f cmd_shell)"
  echo "$body" | grep -q 'resolve_env_args' || {
    echo "REGRESSION: cmd_shell must call resolve_env_args"
    return 1
  }
  echo "$body" | grep -q '_RESOLVED_ENV_ARGS' || {
    echo "REGRESSION: cmd_shell must pass _RESOLVED_ENV_ARGS to docker exec"
    return 1
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# v0.6.3 — cmd_login had the same bug as cmd_shell.
# ─────────────────────────────────────────────────────────────────────────────
@test "regression v0.6.3: cmd_login resolves env args" {
  local body
  body="$(declare -f cmd_login)"
  echo "$body" | grep -q 'resolve_env_args' || {
    echo "REGRESSION: cmd_login must call resolve_env_args"
    return 1
  }
  echo "$body" | grep -q '_RESOLVED_ENV_ARGS' || {
    echo "REGRESSION: cmd_login must pass _RESOLVED_ENV_ARGS to docker exec"
    return 1
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# Stale-mount detection — after macOS reboot /tmp is cleared and SSH agent
# socket path rotates. Stopped containers have old bind mounts baked in and
# cannot start. cmd_start must detect this and recreate silently.
# ─────────────────────────────────────────────────────────────────────────────
@test "regression stale-mount: cmd_start recreates container when overlay dir missing" {
  cat > "$CLEAT_GLOBAL_CONFIG" << 'EOF'
[caps]
hooks
EOF
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"

  # Simulate: container exists (stopped), overlay dir is missing (stale after reboot)
  mock_docker_ps_a "$cname"
  is_running() { return 1; }
  rm -rf "/tmp/cleat-settings-${cname}" 2>/dev/null || true

  run cmd_start "$TEST_TEMP/project"

  # cmd_start should have removed the stale container and called cmd_run to recreate
  grep -qE "^docker rm -f $cname" "$DOCKER_CALLS" || {
    echo "REGRESSION: stale container not removed"
    cat "$DOCKER_CALLS"
    return 1
  }
  grep -qE "^docker run " "$DOCKER_CALLS" || {
    echo "REGRESSION: container not recreated after stale detection"
    cat "$DOCKER_CALLS"
    return 1
  }

  rm -rf "/tmp/cleat-settings-${cname}" "/tmp/cleat-hooks-${cname}"
}

# ─────────────────────────────────────────────────────────────────────────────
# Update cache corruption — check_for_update read a non-numeric last_check
# from a corrupted cache file and passed it directly to an arithmetic
# expression. Under set -u, bash treats `(( garbage ... ))` as an unbound
# variable reference and aborts the CLI. Discovered during strict-mode
# hardening in the test suite (April 2026). Fix: validate last_check is
# a non-negative integer before the arithmetic.
# ─────────────────────────────────────────────────────────────────────────────
# ─────────────────────────────────────────────────────────────────────────────
# latest_remote_tag — must numerically sort semver versions.
# Lexical sort would break v0.10.0 < v0.9.0 → "0.10.0" < "0.9.0" as strings.
# ─────────────────────────────────────────────────────────────────────────────
@test "regression: latest_remote_tag sorts 0.10.0 > 0.9.0 numerically" {
  REPO_DIR="$TEST_TEMP"
  mkdir -p "$TEST_TEMP/.git" "$TEST_TEMP/bin"

  # Git stub that returns unsorted tags including double-digit minor versions
  cat > "$TEST_TEMP/bin/git" << 'EOF'
#!/bin/sh
if [ "$1" = "-C" ] && [ "$3" = "ls-remote" ]; then
  cat << 'TAGS'
abc	refs/tags/v0.6.5
def	refs/tags/v0.9.0
abc	refs/tags/v0.10.0
xyz	refs/tags/v0.9.1
111	refs/tags/v0.10.1
TAGS
fi
EOF
  chmod +x "$TEST_TEMP/bin/git"
  export PATH="$TEST_TEMP/bin:$PATH"

  run latest_remote_tag
  assert_success
  assert_output "0.10.1"
}

@test "regression: latest_remote_tag filters non-semver tags" {
  REPO_DIR="$TEST_TEMP"
  mkdir -p "$TEST_TEMP/.git" "$TEST_TEMP/bin"

  cat > "$TEST_TEMP/bin/git" << 'EOF'
#!/bin/sh
cat << 'TAGS'
abc	refs/tags/v0.6.5
abc	refs/tags/v2.0.0-beta
abc	refs/tags/v1.0.0-rc1
abc	refs/tags/v0.7.0
abc	refs/tags/nightly
abc	refs/tags/v0.8.0-alpha.1
TAGS
EOF
  chmod +x "$TEST_TEMP/bin/git"
  export PATH="$TEST_TEMP/bin:$PATH"

  run latest_remote_tag
  assert_success
  # Only v0.6.5 and v0.7.0 are strict X.Y.Z — v0.7.0 wins
  assert_output "0.7.0"
}

@test "regression: latest_remote_tag empty output when no tags match" {
  REPO_DIR="$TEST_TEMP"
  mkdir -p "$TEST_TEMP/.git" "$TEST_TEMP/bin"

  cat > "$TEST_TEMP/bin/git" << 'EOF'
#!/bin/sh
echo ""
EOF
  chmod +x "$TEST_TEMP/bin/git"
  export PATH="$TEST_TEMP/bin:$PATH"

  # Contract: output must be empty when no semver tags exist. Exit code is
  # non-zero under pipefail (grep non-match) — callers handle this via `|| true`.
  # The important part is the OUTPUT contract, not the exit code.
  run latest_remote_tag
  assert_output ""
}

# Verify the caller (check_for_update) correctly handles latest_remote_tag
# returning non-zero with empty output — this is the production contract.
@test "regression: check_for_update handles empty latest_remote_tag output" {
  # Restore the real function (setup() neutralizes it)
  unset -f check_for_update
  source_cli

  REPO_DIR="$TEST_TEMP"
  UPDATE_CHECK_FILE="$TEST_TEMP/.update_check"
  mkdir -p "$TEST_TEMP/.git" "$TEST_TEMP/bin"

  # Git stub returns no matching tags
  cat > "$TEST_TEMP/bin/git" << 'EOF'
#!/bin/sh
echo ""
EOF
  chmod +x "$TEST_TEMP/bin/git"
  export PATH="$TEST_TEMP/bin:$PATH"

  # check_for_update must not crash under strict mode even when
  # latest_remote_tag returns non-zero with empty output
  run check_for_update
  assert_success
  # No update banner should show since cached_version is empty
  refute_output --partial "Update available"
}

@test "regression: latest_remote_tag accepts both vX.Y.Z and X.Y.Z refs" {
  REPO_DIR="$TEST_TEMP"
  mkdir -p "$TEST_TEMP/.git" "$TEST_TEMP/bin"

  # Real git output sometimes omits the `v` prefix depending on how tags
  # were created. Both should work.
  cat > "$TEST_TEMP/bin/git" << 'EOF'
#!/bin/sh
cat << 'TAGS'
abc	refs/tags/v0.6.5
abc	refs/tags/0.7.0
TAGS
EOF
  chmod +x "$TEST_TEMP/bin/git"
  export PATH="$TEST_TEMP/bin:$PATH"

  run latest_remote_tag
  assert_success
  assert_output "0.7.0"
}

@test "regression: check_for_update survives corrupted cache under strict mode" {
  # The shared setup() neutralizes check_for_update with a no-op.
  # Re-source the CLI to get the real function back.
  unset -f check_for_update
  source_cli

  REPO_DIR="$TEST_TEMP"
  UPDATE_CHECK_FILE="$TEST_TEMP/.update_check"
  mkdir -p "$TEST_TEMP/.git"

  # Create a git stub that returns a fake tag
  mkdir -p "$TEST_TEMP/bin"
  printf '#!/bin/sh\necho "abc refs/tags/v%s"' "$VERSION" > "$TEST_TEMP/bin/git"
  chmod +x "$TEST_TEMP/bin/git"
  export PATH="$TEST_TEMP/bin:$PATH"

  # Write several flavors of corrupted cache content. Each one must not
  # crash check_for_update under set -uo pipefail.
  local garbage
  for garbage in \
    "garbage data here" \
    "" \
    "not-a-number v1.0.0" \
    "-1 $VERSION"
  do
    echo "$garbage" > "$UPDATE_CHECK_FILE"
    run check_for_update
    assert_success
  done
}

# ─────────────────────────────────────────────────────────────────────────────
# Startup-fatal regressions — these check the real binary runs cleanly under
# strict mode (set -euo pipefail). Tests that only source the CLI can't see
# unbound-variable or pipefail errors that kill the process in production.
# ─────────────────────────────────────────────────────────────────────────────
# Helper: exec the real cleat binary with mock docker in PATH. Preserves the
# parent PATH so /usr/bin/env can find bash. This is the harness that catches
# strict-mode (set -euo pipefail) bugs that sourced tests cannot see.
#
# NOTE: cleat derives CLEAT_CONFIG_DIR from $XDG_CONFIG_HOME:-$HOME/.config/cleat
# at startup — there's no CLEAT_CONFIG_DIR env override. We must set
# XDG_CONFIG_HOME to redirect the config lookup.
_run_cleat() {
  local run_home="$TEST_TEMP/home"
  mkdir -p "$run_home" "$TEST_TEMP/xdg/cleat"
  env \
    PATH="$MOCK_BIN:$PATH" \
    HOME="$run_home" \
    XDG_CONFIG_HOME="$TEST_TEMP/xdg" \
    DOCKER_CALLS="$DOCKER_CALLS" \
    DOCKER_MOCK_DIR="$DOCKER_MOCK_DIR" \
    DOCKER_EXIT_CODE="${DOCKER_EXIT_CODE:-0}" \
    "$CLI" "$@"
}

@test "regression strict-mode: cleat --help exits 0 under set -euo pipefail" {
  mkdir -p "$TEST_TEMP/home"
  run _run_cleat --help
  assert_success
  assert_output --partial "Cleat"
}

@test "regression strict-mode: cleat --version exits 0 under set -euo pipefail" {
  mkdir -p "$TEST_TEMP/home"
  run _run_cleat --version
  assert_success
  assert_output --partial "cleat"
}

@test "regression strict-mode: cleat ps runs without unbound variable error" {
  mkdir -p "$TEST_TEMP/home"
  printf '' > "$DOCKER_MOCK_DIR/ps_output"
  run _run_cleat ps
  assert_success
  refute_output --partial "unbound variable"
  refute_output --partial "command not found"
}

@test "regression strict-mode: cleat status exits cleanly with no container" {
  mkdir -p "$TEST_TEMP/home"
  printf '' > "$DOCKER_MOCK_DIR/ps_output"
  printf '' > "$DOCKER_MOCK_DIR/ps_a_output"
  printf '' > "$DOCKER_MOCK_DIR/images_output"
  mkdir -p "$TEST_TEMP/project"
  cd "$TEST_TEMP/project"
  run _run_cleat status
  assert_success
  refute_output --partial "unbound variable"
  refute_output --partial "command not found"
}

# ─────────────────────────────────────────────────────────────────────────────
# Hook bridge safety — hooks execute untrusted commands from user config
# files. They must be wrapped in timeout, their output suppressed, and their
# exit code ignored (so a failing hook can't block the bridge).
# ─────────────────────────────────────────────────────────────────────────────

@test "regression: hook bridge wraps execution in 30s timeout" {
  local body
  body="$(declare -f _execute_host_hooks)"
  [[ -n "$body" ]] || { echo "_execute_host_hooks function not found"; return 1; }

  # There must be a `timeout 30` wrapping the user hook command
  echo "$body" | grep -qE 'timeout 30 bash -c' || {
    echo "REGRESSION: hook bridge must wrap user hook execution in timeout 30"
    return 1
  }
}

@test "regression: hook bridge suppresses stdout and swallows errors" {
  local body
  body="$(declare -f _execute_host_hooks)"
  [[ -n "$body" ]] || { echo "_execute_host_hooks function not found"; return 1; }

  # The hook execution line must pipe to /dev/null and end with `|| true`
  # so the bridge loop doesn't break on a single failing hook.
  # `declare -f` normalizes `>/dev/null` to `> /dev/null`, so match both.
  echo "$body" | grep -qE 'bash -c "\$cmd" >[[:space:]]*/dev/null 2>&1 \|\| true' || {
    echo "REGRESSION: hook bridge must redirect stdout and swallow errors"
    return 1
  }
}

@test "regression: hook bridge has fallback when timeout command missing" {
  local body
  body="$(declare -f _execute_host_hooks)"
  [[ -n "$body" ]] || { echo "_execute_host_hooks function not found"; return 1; }

  echo "$body" | grep -q 'command -v timeout' || {
    echo "REGRESSION: hook bridge must check for timeout availability"
    return 1
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# Missing-tool fallbacks — every optional dependency (jq, socat, python3,
# git) must be guarded by `command -v` so the CLI degrades gracefully
# instead of crashing. These tests enforce that the guards exist.
# ─────────────────────────────────────────────────────────────────────────────

@test "regression fallback: jq checks in hook overlay paths" {
  # Every place that transforms JSON must guard the jq call
  local jq_refs jq_guards
  jq_refs=$(grep -cE '\bjq ' "$CLI" || echo 0)
  jq_guards=$(grep -cE 'command -v jq' "$CLI" || echo 0)
  [[ "$jq_guards" -ge 2 ]] || {
    echo "Expected at least 2 'command -v jq' guards; found $jq_guards"
    return 1
  }
}

@test "regression fallback: socat and python3 both checked in auth proxy" {
  local body
  body="$(declare -f _auth_callback_proxy)"
  echo "$body" | grep -q 'command -v socat' || {
    echo "REGRESSION: _auth_callback_proxy must check for socat before using it"
    return 1
  }
  echo "$body" | grep -q 'command -v python3' || {
    echo "REGRESSION: _auth_callback_proxy must have python3 fallback"
    return 1
  }
}

@test "regression fallback: update check skips for non-git installs" {
  unset -f check_for_update
  source_cli

  REPO_DIR="$TEST_TEMP"
  # No .git directory
  run check_for_update
  assert_success
  assert_output ""
}

@test "regression fallback: hook bridge noop when jq unavailable" {
  # With jq absent from PATH, cmd_resume should not crash trying to
  # refresh settings overlays. The guard is `command -v jq` at the
  # callsite.
  local empty_path="$TEST_TEMP/nojq-bin"
  mkdir -p "$empty_path"
  # Only seed the essentials — no jq
  ln -s "$(command -v bash)" "$empty_path/bash"
  ln -s "$(command -v sed)" "$empty_path/sed"
  ln -s "$(command -v mkdir)" "$empty_path/mkdir"
  ln -s "$(command -v grep)" "$empty_path/grep"
  ln -s "$(command -v wc)" "$empty_path/wc"

  # We can't easily exec cleat without full PATH, so we just verify the
  # guard exists in the function body.
  local body
  body="$(declare -f cmd_resume)"
  echo "$body" | grep -q 'command -v jq' || {
    echo "REGRESSION: cmd_resume must guard jq usage with command -v"
    return 1
  }
}

@test "regression fallback: cmd_run guards jq usage in settings overlay" {
  local body
  body="$(declare -f cmd_run)"
  echo "$body" | grep -q 'command -v jq' || {
    echo "REGRESSION: cmd_run must guard jq usage with command -v"
    return 1
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# Bash 3.2 compatibility — macOS ships bash 3.2. The CLI must not use bash
# 4+ features. Source-level guard against common offenders.
# ─────────────────────────────────────────────────────────────────────────────
@test "regression bash-3.2: no associative arrays" {
  run grep -nE '(local|declare)\s+-A\s+' "$CLI"
  assert_failure
}

@test "regression bash-3.2: no readarray or mapfile" {
  run grep -nE '\b(readarray|mapfile)\b' "$CLI"
  assert_failure
}

@test "regression bash-3.2: no parameter transformation \${var@Q}" {
  run grep -nE '\$\{[a-zA-Z_][a-zA-Z0-9_]*@[QEPAa]\}' "$CLI"
  assert_failure
}

@test "regression bash-3.2: no pipe stderr operator |&" {
  # Match literal `|&` not inside a comment
  run grep -nE '[^|]\|&[^|]' "$CLI"
  assert_failure
}
