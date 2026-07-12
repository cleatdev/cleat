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
  _resolve_config_drift() { true; }
  show_first_run_tip() { true; }

  # Use isolated config dir so tests don't touch real host
  CLEAT_CONFIG_DIR="$TEST_TEMP/cleat-config"
  CLEAT_GLOBAL_CONFIG="$CLEAT_CONFIG_DIR/config"
  CLEAT_GLOBAL_ENV="$CLEAT_CONFIG_DIR/env"
  _first_run_tip_file="$CLEAT_CONFIG_DIR/.tip-shown"
  mkdir -p "$CLEAT_CONFIG_DIR"
}

teardown() {
  rm -rf $CLEAT_RUN_DIR/cleat-project-*/settings 2>/dev/null || true
  rm -rf $CLEAT_RUN_DIR/cleat-project-*/hooks 2>/dev/null || true
  rm -rf $CLEAT_RUN_DIR/cleat-project-*/clip 2>/dev/null || true
  _common_teardown
}

# ─────────────────────────────────────────────────────────────────────────────
# v0.13.0: the startup summary's "Project:" row always claimed the project was
# mounted at "→ /workspace". That's a lie under the docker cap: that cap mounts
# the project at its HOST path and sets the container workdir there (so $(pwd)
# and `docker run -v $(pwd)` resolve on the host daemon, see the docker-cap
# mount block). The row now branches: host path "(same path, sandboxed)" under
# the docker cap, "→ /workspace" otherwise.
# ─────────────────────────────────────────────────────────────────────────────
@test "regression v0.13.0: summary Project row is truthful under the docker cap" {
  ACTIVE_CAPS=(docker)
  run _print_summary_block "cleat-x-12345678" "$HOME/proj"
  assert_output --partial "(same path, sandboxed)"
  refute_output --partial " /workspace"
}

# ─────────────────────────────────────────────────────────────────────────────
# v0.13.0: Claude greeted users with "Configuration Error / The configuration
# file at /home/coder/.claude.json contains invalid JSON ... Unexpected EOF" at
# startup, intermittently. Root cause: Cleat mounted the single host
# ~/.claude.json WHOLE and READ-WRITE into every container. Since every
# container runs at CWD /workspace, parallel/interrupted Claude writes to the
# same shared host file truncated it, and all projects also shared
# projects["/workspace"] (trust/MCP/allowedTools bled across unrelated repos).
#
# Fix: build a per-project, persistent ~/.claude.json (host global keys as base
# + this project's own /workspace block) and mount THAT. The container never
# writes the host file, so the corruption race and the bleed are gone by
# construction. The regression guard: the container's .claude.json bind SOURCE
# must be the per-project store, never the shared host file.
# ─────────────────────────────────────────────────────────────────────────────
@test "regression v0.13.0: container mounts an isolated .claude.json, not the shared host file" {
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project"
  echo '{"oauthAccount":{"emailAddress":"a@b.com"}}' > "${HOME}/.claude.json"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"

  run cmd_run "$TEST_TEMP/project"

  # A .claude.json is mounted onto the canonical container path…
  run assert_docker_run_has "$cname" ":/home/coder/.claude.json"
  assert_success
  # …from the per-project store, NOT the shared host file (the bug).
  run assert_docker_run_has "$cname" "cleat/projects/"
  assert_success
  run assert_docker_run_lacks "$cname" "${HOME}/.claude.json:/home/coder/.claude.json"
  assert_success
}

# ─────────────────────────────────────────────────────────────────────────────
# v0.5.1: cmd_claude did not set _RESOLVED_PROJECT, so hook bridge
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
  # Container must also "exist" so cmd_claude's drift-recreate fallback
  # doesn't run cmd_run (which would mask a missing _RESOLVED_PROJECT assignment).
  mock_docker_ps_a "$cname"
  exec_claude() { return 0; }

  _RESOLVED_PROJECT=""
  cmd_claude "$TEST_TEMP/project"

  [[ "$_RESOLVED_PROJECT" == "$TEST_TEMP/project" ]] || {
    echo "REGRESSION: _RESOLVED_PROJECT='$_RESOLVED_PROJECT' expected '$TEST_TEMP/project'"
    return 1
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# v0.5.1: Hook settings overlay stripped all hooks instead of replacing
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

  local overlay="$CLEAT_RUN_DIR/${cname}/settings/settings.json"
  [[ -f "$overlay" ]] || { echo "REGRESSION: overlay not created"; return 1; }

  # Must contain forwarder command, not be empty and not contain original
  run jq -r '.hooks.Stop[0].hooks[0].command' "$overlay"
  assert_output "cat >> /var/log/cleat/events.jsonl"

  : > "${HOME}/.claude/settings.json" 2>/dev/null || true
  rm -rf "$CLEAT_RUN_DIR/${cname}/settings" "$CLEAT_RUN_DIR/${cname}/hooks"
}

# ─────────────────────────────────────────────────────────────────────────────
# v0.6.0: Hook bridge replayed old events on every start. Any events left
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
# v0.6.0: Project overlay created .claude/ as root on host when directory
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

  rm -rf "$CLEAT_RUN_DIR/${cname}/settings" "$CLEAT_RUN_DIR/${cname}/hooks"
}

# ─────────────────────────────────────────────────────────────────────────────
# v0.6.1: Browser bridge pre-initialized last_ts with the current file's
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
# v0.6.2: docker run/start failures were shown as "Container failed to
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
  rm -rf "$CLEAT_RUN_DIR/${cname}/settings" "$CLEAT_RUN_DIR/${cname}/hooks"
}

# ─────────────────────────────────────────────────────────────────────────────
# v0.6.2: Settings overlay directory was not cleaned on cmd_run after rm,
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
  local overlay_dir="$CLEAT_RUN_DIR/${cname}/settings"
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

  rm -rf "$overlay_dir" "$CLEAT_RUN_DIR/${cname}/hooks"
}

# ─────────────────────────────────────────────────────────────────────────────
# v0.6.2: Quoted tilde in summary block showed '~' literally instead of
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
# v0.6.3: exec_claude called docker exec with only HOME and PATH. Env vars
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
# v0.6.3: cmd_shell didn't call resolve_env_args and didn't pass env to
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
# v0.6.3: cmd_shell used only `-e HOME=/home/coder` and did not pass PATH.
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
# v0.6.3: cmd_login didn't call resolve_env_args. Custom API endpoints or
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
# v0.6.3: _parse_env_file used `while read -r line` without `|| [[ -n $line ]]`,
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
# v0.6.3: Env summary line was omitted when a .cleat.env existed but had
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
# v0.6.4: OAuth callback proxy used socat default TCP (127.0.0.1) but
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
# v0.6.4: socat stdin EOF propagated to TCP side, killing the read before
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
# v0.6.4: Proxy gave up silently on EADDRINUSE. Fix: retry the bind in a loop.
# ─────────────────────────────────────────────────────────────────────────────
@test "regression v0.6.4: _auth_callback_proxy retries bind on EADDRINUSE" {
  local body
  body="$(declare -f _auth_callback_proxy)"
  [[ -n "$body" ]] || { echo "REGRESSION: _auth_callback_proxy function missing"; return 1; }

  # Must have a retry loop, look for a bind attempt counter or loop construct
  # referencing the port. Accept any of: for i in ..., while [[ $attempt ...
  echo "$body" | grep -qE '(attempt|retry|for .* in .* 30|while .* attempt)' || {
    echo "REGRESSION: bind retry loop missing from _auth_callback_proxy"
    return 1
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# v0.6.4: `Connection: keep-alive` header made upstream server keep the
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
# v0.6.5: cmd_run wrote empty {} overlay and bind-mounted to
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
  [[ ! -f "$CLEAT_RUN_DIR/${cname}/settings/project-settings.json" ]] || {
    echo "REGRESSION: empty overlay file created for non-existent host file"
    return 1
  }
  [[ ! -f "$CLEAT_RUN_DIR/${cname}/settings/project-settings.local.json" ]] || {
    echo "REGRESSION: empty overlay file created for non-existent host file"
    return 1
  }

  rm -rf "$CLEAT_RUN_DIR/${cname}/settings" "$CLEAT_RUN_DIR/${cname}/hooks"
}

# ─────────────────────────────────────────────────────────────────────────────
# v0.6.5: docker run failure could leave a partial container that collided
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
  rm -rf "$CLEAT_RUN_DIR/${cname}/settings" "$CLEAT_RUN_DIR/${cname}/hooks"
}

# ─────────────────────────────────────────────────────────────────────────────
# v0.6.3: --env, --env-file, --cap global flags only applied to start/run/
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
# v0.6.3: cmd_login had the same bug as cmd_shell.
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
# Stale-mount detection: after macOS reboot /tmp is cleared and SSH agent
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
  rm -rf "$CLEAT_RUN_DIR/${cname}/settings" 2>/dev/null || true

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

  rm -rf "$CLEAT_RUN_DIR/${cname}/settings" "$CLEAT_RUN_DIR/${cname}/hooks"
}

# ─────────────────────────────────────────────────────────────────────────────
# Update cache corruption: check_for_update read a non-numeric last_check
# from a corrupted cache file and passed it directly to an arithmetic
# expression. Under set -u, bash treats `(( garbage ... ))` as an unbound
# variable reference and aborts the CLI. Discovered during strict-mode
# hardening in the test suite (April 2026). Fix: validate last_check is
# a non-negative integer before the arithmetic.
# ─────────────────────────────────────────────────────────────────────────────
# ─────────────────────────────────────────────────────────────────────────────
# latest_remote_tag: must numerically sort semver versions.
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
  # Only v0.6.5 and v0.7.0 are strict X.Y.Z, v0.7.0 wins
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
  # non-zero under pipefail (grep non-match), callers handle this via `|| true`.
  # The important part is the OUTPUT contract, not the exit code.
  run latest_remote_tag
  assert_output ""
}

# Verify the caller (check_for_update) correctly handles latest_remote_tag
# returning non-zero with empty output. This is the production contract.
@test "regression: _maybe_prompt_cli_update handles empty latest_remote_tag output" {
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
  # Force TTY so the check actually reaches the cache/version logic (the prompt
  # is TTY-gated); empty cached_version must then yield no prompt and no crash.
  _is_tty() { return 0; }

  run _maybe_prompt_cli_update
  assert_success
  refute_output --partial "update available"
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

@test "regression: _maybe_prompt_cli_update survives corrupted cache under strict mode" {
  REPO_DIR="$TEST_TEMP"
  UPDATE_CHECK_FILE="$TEST_TEMP/.update_check"
  mkdir -p "$TEST_TEMP/.git"

  # Create a git stub that returns the current version (so the refresh yields a
  # non-newer version → no prompt → no blocking read while we hammer the guard).
  mkdir -p "$TEST_TEMP/bin"
  printf '#!/bin/sh\necho "abc refs/tags/v%s"' "$VERSION" > "$TEST_TEMP/bin/git"
  chmod +x "$TEST_TEMP/bin/git"
  export PATH="$TEST_TEMP/bin:$PATH"
  # Force TTY so the non-numeric-last_check arithmetic guard is actually
  # exercised (it lives past the TTY gate).
  _is_tty() { return 0; }

  # Write several flavors of corrupted cache content. Each one must not
  # crash the preflight under set -uo pipefail.
  local garbage
  for garbage in \
    "garbage data here" \
    "" \
    "not-a-number v1.0.0" \
    "-1 $VERSION"
  do
    echo "$garbage" > "$UPDATE_CHECK_FILE"
    run _maybe_prompt_cli_update
    assert_success
  done
}

# ─────────────────────────────────────────────────────────────────────────────
# Startup-fatal regressions: these check the real binary runs cleanly under
# strict mode (set -euo pipefail). Tests that only source the CLI can't see
# unbound-variable or pipefail errors that kill the process in production.
# ─────────────────────────────────────────────────────────────────────────────
# Helper: exec the real cleat binary with mock docker in PATH. Preserves the
# parent PATH so /usr/bin/env can find bash. This is the harness that catches
# strict-mode (set -euo pipefail) bugs that sourced tests cannot see.
#
# NOTE: cleat derives CLEAT_CONFIG_DIR from $XDG_CONFIG_HOME:-$HOME/.config/cleat
# at startup. There's no CLEAT_CONFIG_DIR env override. We must set
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
  run _run_cleat --help
  assert_success
  assert_output --partial "Cleat"
}

@test "regression strict-mode: cleat --version exits 0 under set -euo pipefail" {
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
# v0.8.0: Per-project session isolation. Without the overlay mount, all
# containers write sessions to ~/.claude/projects/-workspace/ on the host,
# mixing histories across projects. The fix mounts a per-project directory
# at /home/coder/.claude/projects/-workspace inside each container.
# ─────────────────────────────────────────────────────────────────────────────
@test "regression v0.8.0: session overlay mount isolates projects" {
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"

  run cmd_run "$TEST_TEMP/project"
  assert_success

  # Must have the per-project overlay mount
  run assert_docker_run_has "$cname" "projects/-workspace"
  assert_success

  # The mount source must include the project-specific hash key
  local _bn _h project_key
  _bn="$(basename "$TEST_TEMP/project" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g')"
  _h="$(echo -n "$TEST_TEMP/project" | _md5 | head -c 8)"
  project_key="${_bn}-${_h}"
  run assert_docker_run_has "$cname" "${project_key}:/home/coder/.claude/projects/-workspace"
  assert_success

  rm -rf "$CLEAT_RUN_DIR/${cname}/settings" "$CLEAT_RUN_DIR/${cname}/hooks"
}

# ─────────────────────────────────────────────────────────────────────────────
# v0.8.0: When hooks cap is OFF, project-level settings with hooks were
# NOT overlaid. Claude Code saw the raw host hook commands (like osascript)
# via the workspace bind mount and tried to run them inside the container.
# Fix: always overlay project settings, strip hooks when OFF, replace with
# forwarder when ON.
# ─────────────────────────────────────────────────────────────────────────────
@test "regression v0.8.0: project hooks stripped when hooks cap OFF" {
  # Hooks cap is OFF for this test
  cat > "$CLEAT_GLOBAL_CONFIG" << 'EOF'
[caps]
git
EOF
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project/.claude"
  cat > "$TEST_TEMP/project/.claude/settings.local.json" << 'EOF'
{"hooks":{"PreToolUse":[{"hooks":[{"type":"command","command":"osascript -e 'display notification'"}]}]},"permissions":{"allow":["Read"]}}
EOF

  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"
  run cmd_run "$TEST_TEMP/project"
  assert_success

  # The overlay must be mounted even when hooks cap is OFF
  run assert_docker_run_has "$cname" "settings.local.json:/workspace/.claude/settings.local.json"
  assert_success

  # The overlay must NOT contain the original hook command
  local overlay="$CLEAT_RUN_DIR/${cname}/settings/project-settings.local.json"
  [[ -f "$overlay" ]] || { echo "Overlay file missing"; return 1; }

  # Hooks must be stripped (not present at all)
  if command -v jq &>/dev/null; then
    run jq -e '.hooks // empty | length > 0' "$overlay"
    assert_failure  # hooks should be gone
  fi

  # Non-hook fields must be preserved
  if command -v jq &>/dev/null; then
    run jq -r '.permissions.allow[0]' "$overlay"
    assert_output "Read"
  fi

  rm -rf "$CLEAT_RUN_DIR/${cname}/settings" "$CLEAT_RUN_DIR/${cname}/hooks"
}

# ─────────────────────────────────────────────────────────────────────────────
# Hook bridge safety: hooks execute untrusted commands from user config
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
# Missing-tool fallbacks: every optional dependency (jq, socat, python3,
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
  REPO_DIR="$TEST_TEMP"
  # No .git directory
  _is_tty() { return 0; }
  run _maybe_prompt_cli_update
  assert_success
  assert_output ""
}

@test "regression fallback: hook bridge noop when jq unavailable" {
  # With jq absent from PATH, cmd_resume should not crash trying to
  # refresh settings overlays. The guard is `command -v jq` at the
  # callsite.
  local empty_path="$TEST_TEMP/nojq-bin"
  mkdir -p "$empty_path"
  # Only seed the essentials, no jq
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
# v0.8.0: Per-project history isolation. The base ~/.claude mount shares
# history.jsonl across all containers, so arrow-up in Claude shows commands
# from other projects. Fix: overlay history.jsonl with a per-project copy
# from the same session directory used for projects/-workspace.
# ─────────────────────────────────────────────────────────────────────────────
@test "regression v0.8.0: history.jsonl overlay isolates per-project history" {
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"

  run cmd_run "$TEST_TEMP/project"
  assert_success

  # The docker run must include a history.jsonl bind mount targeting the container path
  run assert_docker_run_has "$cname" "history.jsonl:/home/coder/.claude/history.jsonl"
  assert_success

  # The source must be inside the per-project session dir (not the global one)
  local _bn _h project_key
  _bn="$(basename "$TEST_TEMP/project" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g')"
  _h="$(echo -n "$TEST_TEMP/project" | _md5 | head -c 8)"
  project_key="${_bn}-${_h}"
  run assert_docker_run_has "$cname" "${project_key}/history.jsonl:/home/coder/.claude/history.jsonl"
  assert_success

  rm -rf "$CLEAT_RUN_DIR/${cname}/settings" "$CLEAT_RUN_DIR/${cname}/hooks"
}

# ─────────────────────────────────────────────────────────────────────────────
# Bash 3.2 compatibility: macOS ships bash 3.2. The CLI must not use bash
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

# ─────────────────────────────────────────────────────────────────────────────
# Writing style: no em dashes anywhere. They read as AI-authored, so the project
# bans them repo-wide (see root CLAUDE.md). Source-level guard on the shipped CLI
# and its runtime scripts: an em dash in any of them fails the suite. Replace one
# with a period, comma, colon, or parentheses; never a bare hyphen. The pattern
# below is the literal em-dash character (no \u escape, which bash 3.2 lacks).
# ─────────────────────────────────────────────────────────────────────────────
@test "regression style: bin/cleat contains no em dashes" {
  run grep -n "—" "$CLI"
  assert_failure
}

@test "regression style: shipped scripts contain no em dashes" {
  run grep -rn "—" \
    "$PROJECT_ROOT/install.sh" \
    "$PROJECT_ROOT/coverage.sh" \
    "$PROJECT_ROOT/docker/entrypoint.sh" \
    "$PROJECT_ROOT/docker/open-bridge" \
    "$PROJECT_ROOT/docker/clip" \
    "$PROJECT_ROOT/docker/clip-daemon"
  assert_failure
}

# ─────────────────────────────────────────────────────────────────────────────
# v0.9.2: installer spin_stop printed literal \033 escape sequences and
# left trailing chars from longer spinner lines (e.g. "Pinned to v0.9.1est
# release..."). Root causes:
#   1. printf "%s" passes backslash escapes through unchanged; ok_msg/fail_msg
#      callers embed ${BOLD}...${RESET}, so users saw literal \033[1m.
#   2. \r alone rewinds the cursor but doesn't clear the rest of the line, so
#      a shorter success message left the tail of the spinner text visible.
# Fix: use %b to interpret escapes in the arg, and \r\033[K to clear the line.
# ─────────────────────────────────────────────────────────────────────────────
@test "regression v0.9.2: installer spin_stop renders escapes and clears line" {
  # install.sh runs outside the CLI. Per test rule 7, extract the relevant
  # pieces into a harness script and run it directly with _is_tty forced on.
  local harness="$TEST_TEMP/spin_stop_harness.sh"
  {
    echo '#!/usr/bin/env bash'
    echo '_is_tty() { true; }'
    echo '_SPIN_PID=""'
    sed -n '/^BOLD=/,/^RESET=/p' "$PROJECT_ROOT/install.sh"
    sed -n '/^spin_stop()/,/^}$/p' "$PROJECT_ROOT/install.sh"
    echo 'spin_stop 0 "Downloaded to ${BOLD}/tmp/.cleat${RESET}"'
  } > "$harness"

  run bash "$harness"
  assert_success

  # Message content must appear.
  assert_output --partial "Downloaded to"
  assert_output --partial "/tmp/.cleat"

  # Bug 1: with %s, the arg's \033 is passed through literally. The fix uses
  # %b which interprets it into a real ESC byte, so the 4-char sequence
  # backslash-zero-three-three must not appear in the output.
  refute_output --partial '\033'

  # Bug 2: the output must contain the CR + "clear to EOL" byte sequence so
  # a shorter success line fully replaces a longer spinner line.
  local clear_seq
  clear_seq=$'\r\033[K'
  [[ "$output" == *"$clear_seq"* ]] || {
    echo "REGRESSION: spin_stop output missing \\r\\033[K line-clear prefix"
    return 1
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# v0.9.2: first-run path in cmd_run called _do_build directly, skipping the
# remote pull entirely. Users got a 2-5 min local build on every clean install
# even though ghcr.io/cleatdev/cleat was already publishing matching images.
# The pull path only fired from `cleat build`, which no one types on first run.
# Fix: cmd_run's missing-image branch now calls `_do_pull || _do_build`.
# ─────────────────────────────────────────────────────────────────────────────
@test "regression v0.9.2: cmd_run attempts pull before building on first run" {
  # No image exists yet, mimic a clean install.
  mock_docker_images ""
  mkdir -p "$TEST_TEMP/project"

  run cmd_run "$TEST_TEMP/project"
  assert_success

  # docker pull must have been called (the new first-run path).
  run grep '^docker pull ' "$DOCKER_CALLS"
  assert_success
  assert_output --partial "$REGISTRY_BASE"

  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"
  rm -rf "$CLEAT_RUN_DIR/${cname}/settings" "$CLEAT_RUN_DIR/${cname}/hooks"
}

# ─────────────────────────────────────────────────────────────────────────────
# v0.9.2: REGISTRY_IMAGE was hardcoded to ":latest", ignoring the installed
# CLI's VERSION. The moment GHCR holds a newer tag than the installed CLI,
# :latest pulls an image the CLI wasn't tested against. Concept doc
# (14-v090-execution-plan.md) explicitly requires version tag matching.
# Fix: REGISTRY_IMAGE is derived from $VERSION at load time.
# ─────────────────────────────────────────────────────────────────────────────
@test "regression v0.9.2: registry image tag matches CLI version" {
  # REGISTRY_IMAGE should end with :v${VERSION}, not :latest or anything else.
  [[ "$REGISTRY_IMAGE" == "${REGISTRY_BASE}:v${VERSION}" ]] || {
    echo "REGRESSION: REGISTRY_IMAGE='$REGISTRY_IMAGE' does not match v${VERSION}"
    return 1
  }
  # And the pull command in _do_pull must go against that version-tagged URL.
  mock_docker_images ""
  mkdir -p "$TEST_TEMP/project"
  run cmd_run "$TEST_TEMP/project"
  assert_success

  run grep '^docker pull ' "$DOCKER_CALLS"
  assert_success
  assert_output --partial ":v${VERSION}"
  refute_output --partial ":latest"

  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"
  rm -rf "$CLEAT_RUN_DIR/${cname}/settings" "$CLEAT_RUN_DIR/${cname}/hooks"
}

# ─────────────────────────────────────────────────────────────────────────────
# v0.9.2: bin/cleat's spin_stop also used \r without \033[K, so a shorter
# success message left the tail of the longer spinner line visible. Example:
# "Starting container..." (21 chars) overwritten by "Container started"
# (17 chars) produced "Container startedr..." with the leftover "r..." in
# the spinner's dim color. Same bug as install.sh, different file.
# ─────────────────────────────────────────────────────────────────────────────
@test "regression v0.9.2: bin/cleat spin_stop clears line before writing" {
  # Extract color vars + spin_stop from bin/cleat into an isolated harness,
  # force _is_tty true, and call spin_stop with a shorter success message.
  local harness="$TEST_TEMP/cleat_spin_stop_harness.sh"
  {
    echo '#!/usr/bin/env bash'
    echo '_is_tty() { true; }'
    echo '_has_unicode() { true; }'
    echo '_SPIN_PID=""'
    sed -n "/^BOLD='/,/^RESET='/p" "$CLI"
    sed -n '/^spin_stop()/,/^}$/p' "$CLI"
    echo 'spin_stop 0 "Container started"'
  } > "$harness"

  run bash "$harness"
  assert_success
  assert_output --partial "Container started"

  # Output must contain CR + "clear to EOL" so a shorter success line fully
  # replaces a longer spinner line.
  local clear_seq
  clear_seq=$'\r\033[K'
  [[ "$output" == *"$clear_seq"* ]] || {
    echo "REGRESSION: bin/cleat spin_stop output missing \\r\\033[K line-clear prefix"
    return 1
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# v0.10.0: docker capability. The headline feature: opt-in access to the
# host Docker daemon so users can test docker-based apps (compose, exec,
# build) without leaving the sandbox. Full design in
# concept/15-docker-capability.md.
#
# The three invariants that must hold:
#   1. `docker` is in KNOWN_CAPS (so config --list/--enable work)
#   2. When the cap is active, /var/run/docker.sock is mounted
#   3. When active, project is also mounted at its host path with workdir
#      set there (so $(pwd) in Cleat == $(pwd) on host, the path-remapping
#      ergonomic fix)
# ─────────────────────────────────────────────────────────────────────────────

@test "regression v0.10.0: docker listed in KNOWN_CAPS" {
  # Guards against accidental removal during cap-list refactors.
  local found=0
  for cap in "${KNOWN_CAPS[@]}"; do
    if [[ "$cap" == "docker" ]]; then found=1; fi
  done
  [[ $found -eq 1 ]] || {
    echo "REGRESSION: docker missing from KNOWN_CAPS (${KNOWN_CAPS[*]})"
    return 1
  }
}

@test "regression v0.10.0: docker cap mounts host socket" {
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"

  cat > "$CLEAT_GLOBAL_CONFIG" << 'EOF'
[caps]
docker
EOF

  run cmd_run "$TEST_TEMP/project"
  assert_success
  run assert_docker_run_has "$cname" "/var/run/docker.sock:/var/run/docker.sock"
  assert_success

  rm -rf "$CLEAT_RUN_DIR/${cname}/settings" "$CLEAT_RUN_DIR/${cname}/hooks"
}

@test "regression v0.10.0: docker cap mounts project at host path with workdir" {
  # This is the path-remapping fix: inside Cleat, /workspace and the host
  # path both point to the same project, and workdir is set to the host
  # path so $(pwd) returns something the host daemon can find.
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"

  cat > "$CLEAT_GLOBAL_CONFIG" << 'EOF'
[caps]
docker
EOF

  run cmd_run "$TEST_TEMP/project"
  assert_success
  run assert_docker_run_has "$cname" "$TEST_TEMP/project:$TEST_TEMP/project"
  assert_success
  run assert_docker_run_has "$cname" "--workdir $TEST_TEMP/project"
  assert_success

  rm -rf "$CLEAT_RUN_DIR/${cname}/settings" "$CLEAT_RUN_DIR/${cname}/hooks"
}

@test "regression v0.10.0: docker cap off leaves baseline mounts unchanged" {
  # Docker cap is opt-in; enabling other caps must not accidentally add the
  # socket or host-path mount.
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project"
  mkdir -p "$HOME/.ssh"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"

  cat > "$CLEAT_GLOBAL_CONFIG" << 'EOF'
[caps]
ssh
gh
EOF

  run cmd_run "$TEST_TEMP/project"
  assert_success
  run assert_docker_run_lacks "$cname" "/var/run/docker.sock"
  assert_success
  run assert_docker_run_lacks "$cname" "--workdir"
  assert_success

  rm -rf "$CLEAT_RUN_DIR/${cname}/settings" "$CLEAT_RUN_DIR/${cname}/hooks"
}

# ─────────────────────────────────────────────────────────────────────────────
# v0.10.0: workspace trust. A project's .cleat file lives in the repo and is
# untrusted input. Applying its caps without user approval was the original
# supply-chain footgun (any repo could silently enable ssh/gh/docker on
# clone+run). Workspace trust closes that: project caps require approval
# via prompt, --trust-project flag, CLEAT_TRUST_PROJECT=1 env, or a stored
# approval whose hash still matches the current .cleat caps.
#
# Core invariants:
#   1. Non-interactive + no opt-in → project caps are DROPPED (default-deny)
#   2. Hash is over canonical caps, not raw file: comment edits don't
#      require re-approval
#   3. Global config + --cap CLI flags are never gated (user's own input)
#   4. cleat status never prompts (readonly mode)
#   5. Trust file refuses paths with tab/newline (format corruption)
# ─────────────────────────────────────────────────────────────────────────────

@test "regression v0.10.0: non-TTY + no opt-in skips project .cleat caps" {
  # The supply-chain protection: a malicious repo's .cleat with docker
  # can't silently activate in scripted/CI contexts.
  unset CLEAT_TRUST_PROJECT
  mkdir -p "$TEST_TEMP/proj"
  printf '[caps]\ndocker\n' > "$TEST_TEMP/proj/.cleat"
  _is_tty() { return 1; }

  resolve_caps "$TEST_TEMP/proj" >/dev/null 2>&1
  cap_is_active docker && {
    echo "REGRESSION: docker cap leaked from untrusted .cleat in non-TTY mode"
    return 1
  }
  return 0
}

@test "regression v0.10.0: global config is never gated by trust" {
  # The trust check applies only to project-level .cleat files. The user's
  # own global config must continue to work without any approval flow.
  unset CLEAT_TRUST_PROJECT
  mkdir -p "$TEST_TEMP/proj"
  touch "$HOME/.gitconfig"
  cat > "$CLEAT_GLOBAL_CONFIG" << 'EOF'
[caps]
git
EOF
  _is_tty() { return 1; }
  resolve_caps "$TEST_TEMP/proj" >/dev/null 2>&1
  cap_is_active git || {
    echo "REGRESSION: global config cap was dropped"
    return 1
  }
}

@test "regression v0.10.0: trust hash is over canonical caps (comment-edit safe)" {
  mkdir -p "$TEST_TEMP/proj"
  printf '[caps]\ngit\nssh\n' > "$TEST_TEMP/proj/.cleat"
  local h1 h2
  h1="$(_hash_cleat_caps "$TEST_TEMP/proj/.cleat")"
  # Rewrite the file with comments and reordered caps. Same cap set.
  printf '# this is a comment\n[caps]\nssh\n# another comment\ngit\n' > "$TEST_TEMP/proj/.cleat"
  h2="$(_hash_cleat_caps "$TEST_TEMP/proj/.cleat")"
  [[ -n "$h1" && "$h1" == "$h2" ]] || {
    echo "REGRESSION: comment/order-only .cleat changes altered the trust hash"
    echo "h1=$h1 h2=$h2"
    return 1
  }
}

@test "regression v0.10.0: trust file refuses control chars in project path" {
  # Tab/newline would corrupt the field- and line-oriented trust file.
  run _trust_record "$(printf '/foo\tbar')" "hash"
  assert_failure
  run _trust_record "$(printf '/foo\nbar')" "hash"
  assert_failure
}

@test "regression v0.10.0: trust hash is pure hex (md5sum junk stripped)" {
  # `md5sum` on Linux appends "  -" (the stdin "filename") after the hash.
  # Without stripping, the stored trust hash contains spaces and "-", which
  # corrupts the tab-separated trust file and breaks lookup. The hash in
  # _hash_cleat_caps must be piped through `awk '{print $1}'` (or
  # equivalent) so only hex survives.
  mkdir -p "$TEST_TEMP/proj"
  printf '[caps]\ngit\nssh\n' > "$TEST_TEMP/proj/.cleat"
  local h
  h="$(_hash_cleat_caps "$TEST_TEMP/proj/.cleat")"
  [[ "$h" =~ ^[0-9a-f]+$ ]] || {
    echo "REGRESSION: trust hash contains non-hex chars: '$h'"
    return 1
  }
}

@test "regression v0.10.0: cleat resume after cleat rm creates container and continues" {
  # cleat rm preserves sessions on the host: they live at
  # ~/.claude/projects/<key>/ and aren't touched by cmd_rm. But before
  # this fix, cleat resume errored out with "No container found" when
  # the container was gone, so the user couldn't actually pick up their
  # session without doing `cleat start` (which launches fresh, without
  # --continue). Now cmd_resume auto-creates the container and exec_claude
  # fires --continue so Claude resumes from the persisted host files.
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"

  run cmd_resume "$TEST_TEMP/project"
  assert_success

  # docker run happened: container was created fresh, not errored.
  run grep "^docker run " "$DOCKER_CALLS"
  assert_success
  assert_output --partial "--name $cname"

  rm -rf "$CLEAT_RUN_DIR/${cname}/settings" "$CLEAT_RUN_DIR/${cname}/hooks"
}

@test "regression v0.10.0: cmd_rm leaves per-project session dir untouched" {
  # The host session dir at ~/.claude/projects/<key>/ must survive cmd_rm
  # so `cleat resume` (which now auto-creates a fresh container) can
  # --continue from those files.
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project"
  mock_docker_ps_a "$(container_name_for "$TEST_TEMP/project")"

  # Compute the session dir path the way bin/cleat does.
  local _bn _h project_key session_dir
  _bn="$(basename "$TEST_TEMP/project" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g')"
  _h="$(echo -n "$TEST_TEMP/project" | _md5 | head -c 8)"
  project_key="${_bn}-${_h}"
  session_dir="${HOME}/.claude/projects/${project_key}"

  mkdir -p "$session_dir"
  echo '{"session":"data"}' > "$session_dir/session-abc.jsonl"

  run cmd_rm "$TEST_TEMP/project"
  assert_success

  [[ -f "$session_dir/session-abc.jsonl" ]] || {
    echo "REGRESSION: cmd_rm deleted the per-project session dir"
    return 1
  }
  local content
  content="$(cat "$session_dir/session-abc.jsonl")"
  [[ "$content" == '{"session":"data"}' ]] || {
    echo "REGRESSION: session content mangled by cmd_rm"
    return 1
  }
}

@test "regression v0.10.0: docker cap overlays session dir at host-path key" {
  # With docker cap active, workdir is the host path, so Claude encodes
  # its session dir from that path ('/a/b' → 'projects/-a-b/') instead
  # of the v0.8.0-assumed 'projects/-workspace/'. Without a second
  # overlay, sessions would split between two host dirs (one per-project,
  # one in the base ~/.claude/projects/<host-path-encoded>/). The docker
  # cap block must mount the per-project session dir at the host-path key
  # so sessions always land in the same place regardless of workdir.
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"

  cat > "$CLEAT_GLOBAL_CONFIG" << 'EOF'
[caps]
docker
EOF

  run cmd_run "$TEST_TEMP/project"
  assert_success

  # Host-path key is the project path with slashes replaced by dashes.
  local host_key="${TEST_TEMP//\//-}-project"
  run assert_docker_run_has "$cname" ":/home/coder/.claude/projects/${host_key}"
  assert_success

  rm -rf "$CLEAT_RUN_DIR/${cname}/settings" "$CLEAT_RUN_DIR/${cname}/hooks"
}

@test "regression v0.10.0: cmd_status never prompts for trust" {
  # cleat status is read-only. Any trust prompt from it would surprise users
  # and could deadlock scripts that pipe through status.
  unset CLEAT_TRUST_PROJECT
  mkdir -p "$TEST_TEMP/proj"
  printf '[caps]\ndocker\n' > "$TEST_TEMP/proj/.cleat"
  _is_tty() { return 0; }
  mock_docker_images ""
  run cmd_status "$TEST_TEMP/proj"
  assert_success
  refute_output --partial "Trust this project"
  refute_output --partial "Project .cleat"
}

# ─────────────────────────────────────────────────────────────────────────────
# v0.10.1: _do_pull always issued a `docker pull` against GHCR, even when
# the version-tagged image was already on disk. A transient registry/network
# error there (offline, GHCR hiccup, auth blip) returned non-zero from
# `docker pull`, which the caller treated as "image unavailable" and fell
# back to a 2-5 min local build, even though the prebuilt image was
# sitting in the local image store waiting to be reused.
# Fix: short-circuit at the top of _do_pull. If `docker image inspect
# ${REGISTRY_BASE}:v${target_version}` succeeds, retag locally and return
# without any network call.
# ─────────────────────────────────────────────────────────────────────────────
@test "regression v0.10.1: _do_pull reuses locally cached prebuilt without network call" {
  # Registry-tagged image is on disk but no `cleat` alias. Pull would fail
  # by default (DOCKER_PULL_EXIT_CODE=1), so if _do_pull touched the
  # network it would fall back to a local build, both forbidden here.
  mock_docker_image_cached "$REGISTRY_IMAGE"
  mkdir -p "$TEST_TEMP/project"

  run cmd_run "$TEST_TEMP/project"
  assert_success

  run grep '^docker pull ' "$DOCKER_CALLS"
  assert_failure

  run docker_build_calls
  assert_output ""

  # The cached registry tag was aliased to the local IMAGE_NAME.
  run grep '^docker tag ' "$DOCKER_CALLS"
  assert_success
  assert_output --partial "$REGISTRY_IMAGE"
  assert_output --partial "$IMAGE_NAME"

  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"
  rm -rf "$CLEAT_RUN_DIR/${cname}/settings" "$CLEAT_RUN_DIR/${cname}/hooks"
}

# ─────────────────────────────────────────────────────────────────────────────
# v0.10.1 hardening: the cache short-circuit must not declare success when
# `docker tag` silently fails. Without the fall-through guard, a tag failure
# would leave no `cleat` alias on disk while _do_pull returned 0; the next
# image_exists() check would say "missing" and the user would be back to a
# local build the next time they ran `cleat start`. The guard re-checks
# image_exists() after the tag and falls through to the pull path on
# failure, preserving the GHCR-first contract even when the local image
# store is in a degraded state.
# ─────────────────────────────────────────────────────────────────────────────
@test "regression v0.10.1: _do_pull falls through to network pull when cache-hit tag fails" {
  # Registry-tagged image is on disk, but `docker tag` fails (simulating
  # disk full / permission / etc.). _do_pull must not falsely claim
  # success. It must fall through to the existing pull path. Pull is
  # made to succeed so we can prove the fall-through fired (otherwise
  # we'd land in _do_build and the assertion below would be ambiguous).
  mock_docker_image_cached "$REGISTRY_IMAGE"
  export DOCKER_TAG_EXIT_CODE=1
  export DOCKER_PULL_EXIT_CODE=0

  run cmd_build
  assert_success

  # The fall-through warning must be visible to the user.
  assert_output --partial "could not be tagged"

  # Network pull was attempted (proves we fell through past the cache hit).
  run grep '^docker pull ' "$DOCKER_CALLS"
  assert_success
  assert_output --partial "$REGISTRY_IMAGE"

  unset DOCKER_TAG_EXIT_CODE DOCKER_PULL_EXIT_CODE
}

# ─────────────────────────────────────────────────────────────────────────────
# v0.12.1: `cleat config --enable hooks && cleat` did nothing useful: the
# existing container kept its old mount set (no /var/log/cleat), so hooks
# silently never fired. Drift was detected but the response was a static
# "Run: cleat rm && cleat" notice, invisible to most users.
#
# Fix: cmd_start / cmd_resume / cmd_claude now call _resolve_config_drift
# early, before any docker operation, so a drifted TTY session prompts the
# user to recreate. Without the wiring, the existing capabilities.bats unit
# tests for _resolve_config_drift still pass. This regression pins the
# wiring itself.
# ─────────────────────────────────────────────────────────────────────────────
@test "regression v0.12.1: cmd_start invokes _resolve_config_drift before docker ops" {
  mkdir -p "$TEST_TEMP/project"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"
  mock_docker_images "cleat"
  mock_docker_ps_a "$cname"
  is_running() { return 1; }
  exec_claude() { return 0; }

  # Settings overlay must exist or the unrelated stale-mount path fires
  mkdir -p "$CLEAT_RUN_DIR/${cname}/settings"
  echo '{}' > "$CLEAT_RUN_DIR/${cname}/settings/settings.json"

  # Sentinel: set by the spy below if the wiring is intact
  DRIFT_CALLED=0
  _resolve_config_drift() { DRIFT_CALLED=1; }

  cmd_start "$TEST_TEMP/project"

  [[ "$DRIFT_CALLED" == "1" ]] || {
    echo "REGRESSION: cmd_start did not call _resolve_config_drift"
    return 1
  }
}

# v0.12.1 shipped the drift recreate prompt with `echo -n` instead of
# `echo -en`, so ${BOLD}/${RESET} printed as literal `\033[1m`/`\033[0m`
# instead of being interpreted as ANSI escape sequences. The user saw a
# garbled prompt: `Recreate \033[1mcleat-foo\033[0m now? [Y/n]`.
@test "regression v0.12.1: drift recreate prompt interprets ANSI escapes" {
  run bash -c '
    source "'"$CLI"'"
    container_exists() { return 0; }
    _container_config_hash() { echo "v2:old"; }   # current format, so drift is compared (v0.16.4)
    compute_config_fingerprint() { echo "new"; }
    _is_tty() { return 0; }
    is_running() { return 1; }
    export DOCKER_CALLS="'"$DOCKER_CALLS"'" PATH="'"$MOCK_BIN"':$PATH"
    echo "y" | _resolve_config_drift "cleat-foo" ""
  '
  assert_success
  # Bug present → output contains the 7-char literal sequence.
  # Fix in place → those characters appear only as the actual ESC byte + `[1m`,
  # so the literal substring isn't found.
  refute_output --partial '\033[1m'
  refute_output --partial '\033[0m'
}

# ─────────────────────────────────────────────────────────────────────────────
# v0.12.3: `cleat start` aborted with an opaque OCI runtime error
# ("not a directory: Are you trying to mount a directory onto a file...")
# when the settings-overlay dir survived but a specific file inside was
# missing. The pre-fix stale-mount check only verified `[[ -d $overlay_dir ]]`,
# so the partial-rotation state slipped past the gate, fell through to
# `docker start`, and let Docker auto-create the missing bind source as a
# directory, which then failed to mount onto the file destination inside
# the container. Reported in the wild after a long session: user declined
# the drift recreate prompt, container start failed with the OCI error,
# leaving them stuck.
#
# Fix: _settings_overlay_intact also enumerates the container's bind
# sources via `docker inspect` and verifies each one inside the overlay
# dir is a regular file before docker start. When any source is missing
# or the wrong type, cmd_start auto-recreates (the alternative is the
# same opaque failure they hit in production).
# ─────────────────────────────────────────────────────────────────────────────
@test "regression v0.12.3: cmd_start auto-recreates when overlay dir survives but a file is missing" {
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"
  is_running() { return 1; }
  mock_docker_ps_a "$cname"

  # Overlay dir survives with settings.json, but the container's mount set
  # still references project-settings.local.json which was rotated out.
  # This is the exact partial-rotation state the dir-only check missed.
  local overlay_dir="$CLEAT_RUN_DIR/${cname}/settings"
  mkdir -p "$overlay_dir"
  echo '{}' > "$overlay_dir/settings.json"
  # docker inspect must report both sources so the helper can spot the
  # missing one. The mock returns this for ALL inspect calls in this test,
  # fine because _container_config_hash isn't on the cmd_start path
  # under the bypassed _resolve_config_drift in setup().
  mock_docker_inspect "${overlay_dir}/settings.json
${overlay_dir}/project-settings.local.json"

  run cmd_start "$TEST_TEMP/project"
  assert_success
  assert_output --partial "Recreating container"
  assert_output --partial "host paths changed"
  run docker_calls
  assert_output --partial "docker rm -f $cname"
  assert_output --partial "docker run"
  refute_output --partial "docker start $cname"

  rm -rf "$overlay_dir" "$CLEAT_RUN_DIR/${cname}/clip"
}

# ── v0.13.0: `./test.sh` must not hang on an interactive terminal ────────────
# The open-bridge shim (installed in the container as open/xdg-open) read fd0
# via `cat` when invoked with no URL. The open-bridge "rejects empty input" test
# in hooks.bats runs it with an empty arg; when `./test.sh` is run in a terminal
# (stdin = TTY, inherited through bats), `cat` blocked forever and the whole
# suite hung at the hooks file. Two complementary guards below.

@test "regression v0.13.0: open-bridge does not read stdin when fd0 is a tty" {
  # Root-cause fix lives in the shipped shim: it must guard the `cat` read behind
  # a "not a terminal" check so an interactive `open`/`xdg-open` with no argument
  # (and the empty-input test) falls through to usage instead of blocking. A pipe
  # is still consumed because a pipe is not a tty.
  local script="$PROJECT_ROOT/docker/open-bridge"
  [[ -f "$script" ]] || { echo "open-bridge shim missing"; return 1; }
  grep -qE '\[ *! -t 0 *\]' "$script" || {
    echo "open-bridge reads stdin without a tty guard; interactive use can hang"
    return 1
  }
}

@test "regression v0.13.0: test runner isolates bats stdin from the terminal" {
  # Defense in depth: the per-file loop must run bats with stdin from /dev/null
  # so any future test that reads fd0 gets EOF (matching CI) instead of blocking
  # on the developer's terminal.
  local runner="$PROJECT_ROOT/test.sh"
  [[ -f "$runner" ]] || { echo "test.sh missing"; return 1; }
  grep -qE '"\$BATS" "\$f".*</dev/null' "$runner" || {
    echo "test.sh runs bats without </dev/null; interactive ./test.sh can hang"
    return 1
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# v0.13.1: two bugs surfaced when the v0.13.0 upgrade forced a container
# recreate on a macOS host (host uid 501, image-baked coder uid 1000):
#
#   (A) FREEZE: v0.13.0 made ~/.local writable, re-enabling Claude Code's
#       launch-time self-updater, which hangs the TUI under `docker exec -it` on
#       a fresh container. Fix: disable it via DISABLE_AUTOUPDATER=1 in the
#       session env: cleat owns Claude's version (image + `cleat upgrade-claude`).
#
#   (B) CLIP EPERM STORM: `docker exec ... runuser -u coder` could fire before
#       the entrypoint finished remapping coder 1000→501, so clip-daemon stamped
#       /tmp/clip.* as uid 1000; later 501 sessions couldn't unlink them from the
#       sticky /tmp. Fixes: wait for the remap before exec, AND give clip-daemon a
#       per-uid runtime dir so two uids can never collide on one socket.
# ─────────────────────────────────────────────────────────────────────────────

@test "regression v0.13.1: session env disables Claude's launch-time auto-updater" {
  # The freeze cause was Claude's in-container self-updater running at launch.
  # Cleat manages Claude's version itself, so the session must pass
  # DISABLE_AUTOUPDATER=1 to claude.
  _host_open_cmd() { echo ""; }
  run exec_claude "test-ctr" --dangerously-skip-permissions
  assert_success
  run assert_docker_exec_has "DISABLE_AUTOUPDATER=1"
  assert_success
}

@test "regression v0.13.1: session waits for the UID remap before launching" {
  # The wrong-uid / clip-EPERM cause was the session exec racing the entrypoint's
  # /etc/passwd remap. exec_claude must probe `id -u coder` in the container
  # before launching, so clip-daemon and claude never run as the stale image uid.
  _host_open_cmd() { echo ""; }
  run exec_claude "test-ctr" --dangerously-skip-permissions
  assert_success
  run assert_docker_exec_has "id -u coder"
  assert_success
}

@test "regression v0.13.1: clip-daemon uses a per-uid runtime dir, not shared /tmp/clip.sock" {
  # Stale, foreign-owned /tmp/clip.sock in the sticky /tmp was the wedge. The
  # daemon must honor CLEAT_CLIP_DIR (a per-uid dir) for its socket so two uids
  # can never collide. Stub socat so we observe the bind path without listening.
  local rundir="$TEST_TEMP/clip-run"
  local stubs="$TEST_TEMP/clipd-stubs"; mkdir -p "$stubs" "$rundir"
  local socat_log="$TEST_TEMP/socat-args.log"; : > "$socat_log"
  printf '#!/bin/sh\necho "$@" >> "%s"\nexit 0\n' "$socat_log" > "$stubs/socat"
  chmod +x "$stubs/socat"
  run env PATH="$stubs:$PATH" CLEAT_CLIP_DIR="$rundir" bash "$PROJECT_ROOT/docker/clip-daemon"
  run cat "$socat_log"
  assert_output --partial "$rundir/clip.sock"
}

@test "regression: clip-daemon passes socat an inactivity timeout (-T) so hung handlers can't exhaust PIDs" {
  # A client that connects but never sends/closes left a handler hung on
  # `head -c` forever; accumulated hung handlers were the fork-storm. The
  # listener must carry socat's -T inactivity timeout.
  local rundir="$TEST_TEMP/clip-run"
  local stubs="$TEST_TEMP/clipd-stubs"; mkdir -p "$stubs" "$rundir"
  local socat_log="$TEST_TEMP/socat-args.log"; : > "$socat_log"
  printf '#!/bin/sh\necho "$@" >> "%s"\nexit 0\n' "$socat_log" > "$stubs/socat"
  chmod +x "$stubs/socat"
  run env PATH="$stubs:$PATH" CLEAT_CLIP_DIR="$rundir" bash "$PROJECT_ROOT/docker/clip-daemon"
  run cat "$socat_log"
  assert_output --partial "-T 5"
}

@test "regression v0.13.1: clip shim and clip-daemon resolve the SAME socket path" {
  # The OSC52 fallback only works if `clip` connects to the exact socket
  # clip-daemon binds. Both derive it from CLEAT_CLIP_DIR / the per-uid dir; a
  # divergence (e.g. one left at /tmp/clip.sock) silently breaks paste. Evaluate
  # the real assignment lines from each shipped script and compare.
  local daemon_sock clip_sock
  daemon_sock="$(CLEAT_CLIP_DIR=/probe bash -c 'eval "$(grep -E "^(RUNDIR|SOCK)=" "'"$PROJECT_ROOT/docker/clip-daemon"'")"; printf %s "$SOCK"')"
  clip_sock="$(CLEAT_CLIP_DIR=/probe bash -c 'eval "$(grep -E "^SOCK=" "'"$PROJECT_ROOT/docker/clip"'")"; printf %s "$SOCK"')"
  assert_equal "$daemon_sock" "/probe/clip.sock"
  assert_equal "$clip_sock" "/probe/clip.sock"
  assert_equal "$clip_sock" "$daemon_sock"
}

@test "regression v0.15.0: browser bridge consumes each URL once (no per-watcher duplicate opens)" {
  # A session that dies without its cleanup trap (crash / SIGKILL / closed
  # terminal) orphans its disowned _browser_watcher. The next session on the same
  # cname reuses the clip dir and starts ANOTHER watcher, so N watchers each open
  # every URL → one in-container `open` produced N host tabs. The fix consumes
  # the bridge file with an atomic rename: exactly one watcher claims each URL.
  local bridge="$TEST_TEMP/.browser-open"
  printf '%s\n' "https://example.com/oauth" > "$bridge"
  # Two watchers racing the same bridge file (orphan + current).
  run _browser_claim_url "$bridge"
  assert_success
  assert_output --partial "https://example.com/oauth"
  # The second watcher must find nothing: one tab, not two.
  run _browser_claim_url "$bridge"
  assert_failure
}

# v0.15.0: the config-drift notice shipped as a cyan-bordered _notice_box with
# blank-line padding. It now renders as plain text in the "New in v…" style (no
# box, no empty lines), per the maintainer's startup-output taste. The bug we
# guard against is the bordered box returning. Exercises the non-TTY branch
# (no prompt) so the whole notice is in captured output; mutating that branch's
# `info` back to `_notice_box` reintroduces the border and trips the refutes.
@test "regression v0.15.0: config-drift notice is plain text, not a box" {
  run bash -c '
    source "'"$CLI"'"
    container_exists() { return 0; }
    _container_config_hash() { echo "v2:old"; }   # current format, so drift is compared (v0.16.4)
    compute_config_fingerprint() { echo "new"; }
    _is_tty() { return 1; }
    _resolve_config_drift "cleat-foo" ""
  '
  assert_success
  assert_output --partial "Config changed"
  assert_output --partial "cleat-foo"
  refute_output --partial "┌"
  refute_output --partial "└"
  refute_output --partial "│"
}

# v0.15.0: the image-rebuild prompt opened with a stray `echo ""`, leaving a
# blank line between the preceding "✔ Removed …" (drift recreate) and the
# notice, visible in the wild on a drift→rebuild startup. The leading blank is
# gone; the notice is now the first byte of output. Command substitution strips
# trailing newlines but PRESERVES a leading one, so re-adding `echo ""` makes
# $out start with a newline and trips the guard.
@test "regression v0.15.0: image-rebuild notice has no leading blank line" {
  _is_tty() { return 0; }
  image_exists() { return 0; }
  # Pre-stamping image older than the content intro → prompt fires.
  _image_spec_version() { echo ""; }
  _image_cleat_version() { echo "0.0.1"; }
  cmd_rebuild() { :; }
  container_exists() { return 1; }
  is_running() { return 1; }
  _REBUILD_PROMPTED=0
  local out
  out="$(_maybe_prompt_image_rebuild "cleat-x-12345678" <<< "n" 2>&1)"
  [[ "$out" == *"out of date"* ]] \
    || { echo "notice missing: $out"; return 1; }
  [[ "$out" != $'\n'* ]] \
    || { echo "REGRESSION: leading blank line before rebuild notice"; return 1; }
}

@test "regression v0.15.0: version bump alone does not trigger config drift" {
  # The config fingerprint must depend ONLY on caps + env keys, never the CLI
  # version. Folding version in made every release fire a false "caps or env
  # keys differ" drift notice on existing containers whose setup was untouched,
  # with a remedy (recreate from the same image) that fixes nothing for a
  # version change. Version drift is _maybe_prompt_image_rebuild's job.
  run bash -c '
    source "'"$CLI"'"
    ACTIVE_CAPS=(git env)
    _RESOLVED_ENV_ARGS=(-e "FOO=bar")
    VERSION="0.14.0"; h1="$(compute_config_fingerprint)"
    VERSION="0.15.0"; h2="$(compute_config_fingerprint)"
    [[ "$h1" == "$h2" ]] || { echo "DRIFTED: $h1 vs $h2" >&2; exit 1; }
    echo "STABLE"
  '
  assert_success
  assert_output --partial "STABLE"
}

@test "regression: caps reader keeps a final line that lacks a trailing newline" {
  # A hand-edited .cleat ending in a capability with no trailing newline
  # (printf '[caps]\nenv') silently dropped that last cap: _read_caps_from_file
  # looped with a bare `while IFS= read -r line` and no `|| [[ -n "$line" ]]`, so
  # the unterminated final line was lost. The project's requested cap was never
  # seen, so no trust prompt fired and the cap never applied (and the box drifted
  # because it had been created when the cap still applied). Fix mirrors
  # _parse_env_file. Reproduce the exact input: env on the last line, no newline.
  printf '[caps]\nenv' > "$TEST_TEMP/.cleat"
  run _read_caps_from_file "$TEST_TEMP/.cleat"
  assert_success
  [[ "$output" == *"env"* ]] \
    || { echo "REGRESSION: last capability dropped from a no-trailing-newline .cleat"; return 1; }
}

@test "regression: [resources] reader keeps a final line that lacks a trailing newline" {
  # Same class as the caps-reader bug: _read_resource_from_file looped with a
  # bare `while IFS= read -r line` and no `|| [[ -n "$line" ]]`, so a hand-edited
  # .cleat ending in `memory = 8g` with no trailing newline silently dropped the
  # configured ceiling and the box fell back to the VM-derived default. The
  # header comment even claimed "Same parsing hygiene as [caps]", which was false.
  printf '[resources]\nmemory = 8g' > "$TEST_TEMP/.cleat"
  run _read_resource_from_file "$TEST_TEMP/.cleat" memory
  assert_success
  [[ "$output" == "8g" ]] \
    || { echo "REGRESSION: configured ceiling dropped from a no-trailing-newline [resources]"; return 1; }
}

@test "regression v0.15.1: rotated SSH-agent socket after reboot recreates instead of failing to start" {
  # macOS launchd regenerates the SSH agent socket directory
  # (…/com.apple.launchd.XXXX/Listeners) on every reboot, so SSH_AUTH_SOCK
  # rotates. A stopped ssh-cap container has the OLD path baked into its mount
  # spec; `docker start` re-mounts it and aborts with an opaque OCI error:
  #   error mounting "…/Listeners" to rootfs at "/tmp/ssh-agent.sock" …
  #   not a directory. cmd_start must detect the vanished bind source up front
  # and recreate (the settings overlay alone never caught it).
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"
  is_running() { return 1; }
  mock_docker_ps_a "$cname"
  # Settings overlay intact, so the OTHER stale-check passes …
  mkdir -p "$CLEAT_RUN_DIR/${cname}/settings"
  echo '{}' > "$CLEAT_RUN_DIR/${cname}/settings/settings.json"
  # … but the rotated SSH-agent socket source is gone.
  mock_docker_inspect "$(printf 'bind|%s\nbind|%s\n' \
    "$TEST_TEMP/project" "$TEST_TEMP/run/com.apple.launchd.GONE/Listeners")"

  run cmd_start "$TEST_TEMP/project"
  assert_success
  assert_output --partial "Recreating container"
  run docker_calls
  assert_output --partial "docker rm -f $cname"
  assert_output --partial "docker run"
  refute_output --partial "docker start $cname"
  rm -rf "$CLEAT_RUN_DIR/${cname}/settings" "$CLEAT_RUN_DIR/${cname}/clip"
}

@test "regression: containers are created with --init so PID 1 reaps zombies" {
  # Without --init, PID 1 inside the box is `su`, which never wait()s on
  # re-parented children. Orphans from agent subshells accumulate as zombies
  # until the box hits --pids-limit: fork() fails, node aborts mid-frame, and
  # the attached terminal freezes (observed live: a 2-day box wedged at the
  # pids cap with ~900 zombie bash procs). --init makes docker's bundled tini
  # PID 1, which reaps everything and forwards SIGTERM (so `cleat stop` no
  # longer burns its full timeout and SIGKILLs, the historical fleet all
  # shows Exited(137) for this reason).
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"
  run cmd_run "$TEST_TEMP/project"
  assert_success
  run assert_docker_run_has "$cname" "--init"
  assert_success
}

@test "regression: claude's exit code survives clip-daemon cleanup in the session script" {
  # The session script used to end with `kill/wait $_MY_CLIP_DAEMON`, so the
  # `bash -c` exit status was the daemon wait's 0, masking a crashed claude
  # (SIGSEGV=139, SIGABRT=134) as a clean session end, whose rc==0 branch then
  # ERASED the crash message bash had just printed. The script must capture
  # claude's status and exit with it.
  run exec_claude "test-ctr" --dangerously-skip-permissions
  run assert_docker_exec_has 'claude "$@"'
  assert_success
  run assert_docker_exec_has 'exit "$_CLAUDE_RC"'
  assert_success
}

@test "regression: the session script propagates a crashed claude's exit code when executed" {
  # The text-pin above can't catch a capture-ORDER regression: moving
  # _CLAUDE_RC=$? after the daemon kill re-masks crashes with the kill's 0.
  # So capture the ACTUAL script sent to docker exec and run it with a
  # SIGSEGV-ing claude stub: the wrapper must exit 139, not 0.
  local script_file="$TEST_TEMP/inner_script"
  docker() {
    if [[ "$1" == "exec" ]]; then
      local arg prev=""
      for arg in "$@"; do
        if [[ "$prev" == "-c" && "$arg" == *"clip-daemon &"* ]]; then
          printf '%s' "$arg" > "$script_file"
        fi
        prev="$arg"
      done
      return 0
    fi
    command docker "$@"
  }
  run exec_claude "test-ctr" --dangerously-skip-permissions
  [ -s "$script_file" ] || { echo "session script not captured"; return 1; }
  mkdir -p "$TEST_TEMP/fakebin"
  printf '#!/usr/bin/env bash\nexit 139\n' > "$TEST_TEMP/fakebin/claude"
  printf '#!/usr/bin/env bash\nsleep 30\n' > "$TEST_TEMP/fakebin/clip-daemon"
  chmod +x "$TEST_TEMP/fakebin/claude" "$TEST_TEMP/fakebin/clip-daemon"
  run env PATH="$TEST_TEMP/fakebin:$PATH" CLEAT_CLIP_DIR="$TEST_TEMP" \
    bash "$script_file" --dangerously-skip-permissions
  assert_failure 139
}

@test "regression: docker exec stderr surfaces when the session fails" {
  # Host-side docker errors ('exec failed: resource temporarily unavailable'
  # during fork lockup, daemon connection resets) were thrown away by
  # 2>/dev/null, leaving the user with a corrupted terminal and zero
  # diagnostics. On a non-zero exit they must be shown.
  _wait_for_coder_remap() { true; }
  _ensure_docker_access() { true; }
  export DOCKER_STDERR="exec failed: resource temporarily unavailable"
  export DOCKER_EXIT_CODE=1
  run exec_claude "test-ctr" --dangerously-skip-permissions
  assert_output --partial "exited with code 1"
  assert_output --partial "resource temporarily unavailable"
}

@test "regression: interactive session restores terminal state after docker exec" {
  # A hard-dying claude (SIGSEGV under amd64 emulation, fork lockup) leaves
  # the host terminal in raw mode with alt-screen/mouse-tracking on, every
  # keystroke and scroll sprays escape garbage until a manual `reset`.
  # exec_claude must always run the terminal-restore path after the exec.
  _restore_terminal() { echo "RESTORE_TERMINAL_CALLED"; }
  run exec_claude "test-ctr" --dangerously-skip-permissions
  assert_output --partial "RESTORE_TERMINAL_CALLED"
}

@test "regression: clean session end emits no cursor-up erase into a pipe" {
  # The rc==0 branch unconditionally printed '\033[A\033[2K' (cursor-up +
  # erase-line) even when stdout was not a terminal, corrupting piped/captured
  # output, and after a masked crash it deleted the crash evidence itself.
  # The erase is cosmetic TTY furniture: it must be TTY-gated.
  run exec_claude "test-ctr" --dangerously-skip-permissions
  assert_output --partial "Session ended"
  refute_output --partial $'\033[A'
}

@test "regression: clean session end clears the success line so stale terminal bytes can't survive" {
  # Observed on a heavily-used terminal: a stray hash tail ("e001861") trailed
  # the "cleat resume" message. Cause: the reclaim sequence moved up, erased the
  # line ABOVE, dropped back down, then success() wrote from column 0 WITHOUT
  # clearing to end-of-line, so stale bytes already on that row survived past
  # the message. Fix: clear the destination line too (a trailing \033[2K after
  # the \r\n). Force TTY so the (TTY-gated) sequence is actually emitted.
  _is_tty() { return 0; }
  run exec_claude "test-ctr" --dangerously-skip-permissions
  assert_success
  assert_output --partial "Session ended"
  # Erase the reclaimed line above, drop down, AND clear the success line.
  assert_output --partial $'\033[A\033[2K\r\n\033[2K'
}

@test "regression v0.16.4: resizing the Docker VM does not trigger config drift" {
  # The fingerprint folded in resolve_box_memory, whose default is a quarter of
  # the Docker VM clamped to [4g,8g]. So nudging the Docker memory slider, or a
  # CLI release that retunes that formula (the 2g→4g floor change in v0.16.1),
  # moved the hash and fired a false "config changed, recreate?" on a box the
  # user never touched. The fingerprint now reads CONFIGURED resources only, so
  # an unconfigured box hashes the same no matter the VM size or CLI version.
  run bash -c '
    source "'"$CLI"'"
    ACTIVE_CAPS=(git env); _RESOLVED_ENV_ARGS=(-e "FOO=bar")
    proj="'"$TEST_TEMP"'/vmproj"; mkdir -p "$proj"
    CLEAT_GLOBAL_CONFIG="'"$TEST_TEMP"'/no-such-config"
    _docker_vm_memory() { echo "$(( 7 * 1073741824 ))"; }
    h1="$(compute_config_fingerprint "$proj")"
    _docker_vm_memory() { echo "$(( 48 * 1073741824 ))"; }
    h2="$(compute_config_fingerprint "$proj")"
    [[ "$h1" == "$h2" ]] || { echo "DRIFTED: $h1 vs $h2" >&2; exit 1; }
    echo "STABLE"
  '
  assert_success
  assert_output --partial "STABLE"
}

@test "regression v0.16.4: a legacy (pre-v2) config-hash is never nagged to recreate" {
  # Containers created before the v0.16.4 fingerprint format carry a bare hash
  # whose inputs we can't reconstruct (old formula, unknown VM size at creation).
  # The upgrade to v0.16.4 must NOT prompt them to recreate (the exact false
  # positive being fixed): only current-format (v2:) hashes are compared, anything
  # else is left untouched until its next genuine recreate.
  run bash -c '
    source "'"$CLI"'"
    container_exists() { return 0; }
    _container_config_hash() { echo "0123456789abcdef"; }   # bare legacy hash, no v2: prefix
    compute_config_fingerprint() { echo "anything-different"; }
    _is_tty() { return 0; }
    echo "y" | _resolve_config_drift "cleat-foo" ""
  '
  assert_success
  refute_output --partial "Config changed"
}

@test "regression v0.16.4: a fired Claude-update prompt closes with a trailing blank" {
  # After "Claude Code upgraded", the bring-up (Container started …) printed flush
  # against the confirmation. The prompt opens with a blank line, so it must also
  # close with one, but only when it actually fired (a throttled/no-op start prints
  # neither). SENTINEL stands in for the bring-up; the blank must survive before it.
  run bash -c '
    source "'"$CLI"'"
    _is_tty() { return 0; }
    image_exists() { return 0; }
    _upgrade_claude_image() { echo "UPGRADE_CALLED"; return 0; }
    CLAUDE_CHECK_FILE="'"$TEST_TEMP"'/.cuc"
    CLEAT_FORCE_CLAUDE_CHECK=1
    CLEAT_FAKE_REMOTE_CLAUDE="2.1.149"
    _image_claude_version() { echo "2.1.40"; }
    out="$( _maybe_prompt_claude_update <<< "y"; printf "SENTINEL\n" )"
    last="$(printf "%s\n" "$out" | tail -2 | head -1)"
    [[ -z "$last" ]] || { echo "NO TRAILING BLANK; last=[$last]" >&2; exit 1; }
    echo "BLANK_OK"
  '
  assert_success
  assert_output --partial "BLANK_OK"
}

@test "regression v0.16.4: the Docker VM size rounds to the slider, not the kernel's reported floor" {
  # img_1.png: a 16 GB Docker Desktop slider is reported by `docker info` as the
  # guest kernel's MemTotal (~15.6 GiB; the kernel reserves some at boot). Flooring
  # that printed a misleading "15 GB" and false-positived the undersized advisory on
  # a VM that was sized right. Rounding to the nearest GB recovers the slider's 16;
  # a genuine 15 GB slider (~14.6 GiB) still rounds to 15, so the two stay distinct.
  run bash -c '
    source "'"$CLI"'"
    [[ "$(_vm_gb_rounded 16750372454)" == "16" ]] || { echo "16 GB slider misread as $(_vm_gb_rounded 16750372454)" >&2; exit 1; }
    [[ "$(_vm_gb_rounded 15676000000)" == "15" ]] || { echo "15 GB slider misread" >&2; exit 1; }
    [[ "$(_vm_gb_rounded 8589934592)"  == "8"  ]] || { echo "8 GiB exact misread" >&2; exit 1; }
    # A digit-only value with a leading zero must read base-10, not abort as octal.
    [[ "$(_vm_gb_rounded 016750372454)" == "16" ]] || { echo "zero-padded value misread as [$(_vm_gb_rounded 016750372454)]" >&2; exit 1; }
    echo "ROUNDS_OK"
  '
  assert_success
  assert_output --partial "ROUNDS_OK"
}

@test "regression v0.16.4: the prune notice and the VM advisory are separated by a blank line" {
  # img_1.png: on a daily check both the bloat→prune prompt and the undersized-VM
  # advisory fire. They ran flush ("Pruned N images." directly above "Docker VM
  # memory is ..."). The advisory must own a blank line above it even when an earlier
  # notice already printed (the old `$printed || echo ""` suppressed that separator).
  run bash -c '
    source "'"$CLI"'"
    PRESSURE_CHECK_FILE="'"$TEST_TEMP"'/regr-pressure-nostamp"; rm -f "$PRESSURE_CHECK_FILE"
    _is_tty() { return 0; }
    _cleat_prunable_stats() { printf "7\t8192"; }     # bloat → prune offered (stamp absent → due)
    _docker_vm_memory() { echo "8589934592"; }        # 8 GiB VM (undersized)
    _host_total_memory() { echo "34359738368"; }      # 32 GiB Mac
    _running_memory_limits_sum() { echo "0"; }
    _is_docker_desktop() { return 0; }
    cmd_prune() { echo "PRUNE_DONE"; }
    out="$(_maybe_check_docker_pressure <<< "y")"
    before="$(printf "%s\n" "$out" | grep -B1 "Docker VM memory is" | head -1)"
    [[ -z "${before// /}" ]] || { echo "NOT SEPARATED; line above=[$before]" >&2; exit 1; }
    echo "SEPARATED_OK"
  '
  assert_success
  assert_output --partial "SEPARATED_OK"
}

@test "regression v0.16.5: a 24 GB Docker Desktop slider displays as 24 GB, not 23" {
  # img: "Docker tuned for Cleat (23 GB VM ...)" while the slider was set to 24. The
  # guest kernel's MemTotal for a 24 GB VM lands ~23.4 GiB (the kernel reserve grows
  # with VM size), and round-to-nearest reads that as 23, indistinguishable from a
  # genuine 23 GB slider. The configured slider value (MemoryMiB) must drive the
  # display. Revert _docker_vm_display_gb to _vm_gb_rounded and this reads 23.
  run bash -c '
    source "'"$CLI"'"
    cfg="$(_DD_MEMORY_MIB=24576 _docker_vm_display_gb 25125558681)"   # ~23.4 GiB MemTotal
    [[ "$cfg" == "24" ]] || { echo "24 GB slider displayed as [$cfg]" >&2; exit 1; }
    # The disambiguation MemTotal alone cannot make: rounding ~23.4 GiB reads 23.
    [[ "$(_vm_gb_rounded 25125558681)" == "23" ]] || { echo "expected the rounded MemTotal to read 23" >&2; exit 1; }
    # No settings and no override falls back to rounding the MemTotal.
    fb="$(_DD_SETTINGS_DIR="'"$TEST_TEMP"'/no-dd" _docker_vm_display_gb 17179869184)"
    [[ "$fb" == "16" ]] || { echo "fallback misread 16 GiB as [$fb]" >&2; exit 1; }
    echo "SLIDER_OK"
  '
  assert_success
  assert_output --partial "SLIDER_OK"
}

@test "regression v0.16.5: the bridge does not re-open a plain link the terminal already opened" {
  # The link double-open (a 2nd tab ~0.5s later): the host terminal opens a clicked
  # URL itself AND the in-container open shim writes the bridge, so the watcher
  # opened it a second time. On an interactive terminal the bridge must DEFER plain
  # links. Drop the host_opens_clicks gate and this opens (the duplicate returns).
  run bash -c '
    source "'"$CLI"'"
    # auto + interactive terminal + plain link -> defer (rc 1).
    if _browser_should_open auto 1 0; then echo "PLAIN OPENED (duplicate)" >&2; exit 1; fi
    # auto + interactive + auth URL -> still opens (the bridge owns login URLs).
    _browser_should_open auto 1 1 || { echo "auth URL wrongly deferred" >&2; exit 1; }
    # auto + no terminal + plain -> opens (nothing else will).
    _browser_should_open auto 0 0 || { echo "plain link wrongly deferred off a TTY" >&2; exit 1; }
    echo "NO_DUP_OK"
  '
  assert_success
  assert_output --partial "NO_DUP_OK"
}

@test "regression v1.1.0: overload notice does not set-e abort start with exactly ONE running session" {
  # The session-count pluralization `session$( (( n != 1 )) && printf s )` in a
  # PLAIN assignment returns exit 1 when n==1 (the && short-circuits the sub),
  # which under the CLI's `set -euo pipefail` aborted the start/resume/run path
  # before launching the box. Strict mode is LIVE here because we source the RAW
  # CLI (not source_cli, which strips set -e). Reverting the fix re-crashes this
  # (the assertions after the assignment are never reached).
  run bash -c '
    source "'"$CLI"'"
    PRESSURE_CHECK_FILE=/dev/null
    _is_tty() { return 0; }
    _cleat_prunable_stats() { printf "0\t0"; }
    _docker_vm_memory() { echo 8589934592; }            # 8 GiB VM
    _running_memory_limits_sum() { echo 42949672960; }  # 40 GiB -> overloaded
    _running_cleat_box_count() { echo 1; }              # the singular case
    _host_total_memory() { echo 34359738368; }
    _is_docker_desktop() { return 1; }
    _maybe_check_docker_pressure
    echo "REACHED_END_OK"
  '
  assert_success
  assert_output --partial "1 session still running"
  assert_output --partial "REACHED_END_OK"
}

# ─────────────────────────────────────────────────────────────────────────────
# 2026-07-07 login regressions (in-box code-paste flow + cross-box identity)
# ─────────────────────────────────────────────────────────────────────────────

# 2026-07-07 hardening: _is_auth was keyed on the loopback port, so any OAuth
# authorize URL WITHOUT a localhost callback (Claude's code-paste login URL,
# gh-auth-style flows) classified as a PLAIN link and, in an interactive
# session (auto mode, host_opens_clicks=1), was deferred to a terminal that
# never opens programmatically emitted URLs: a stranded login. Claude 2.1.x
# hands its opener only the loopback URL today (the primary regression was the
# missing $BROWSER, see the next test), but a non-loopback authorize URL
# reaching the bridge must never strand a login again.
@test "regression v1.1.1: code-paste login URL (no loopback callback) still auto-opens in an interactive session" {
  local dir="$TEST_TEMP/clip"; mkdir -p "$dir"
  _auth_callback_proxy() { :; }   # must not be reached: there is no port
  cat > "$TEST_TEMP/fake_open" <<SCRIPT
#!/usr/bin/env bash
echo "\$1" >> "$TEST_TEMP/opened.log"
SCRIPT
  chmod +x "$TEST_TEMP/fake_open"
  # _extract_callback_port is intentionally NOT mocked: the URL has no
  # loopback callback, and the watcher must open it anyway.
  _browser_watcher "$dir" "$TEST_TEMP/fake_open" "mybox" "auto" "1" >/dev/null 2>&1 &
  local wpid=$!
  sleep 0.7
  printf '%s' "https://claude.ai/oauth/authorize?code=true&client_id=abc&redirect_uri=https%3A%2F%2Fconsole.anthropic.com%2Foauth%2Fcode%2Fcallback&scope=user" > "$dir/.browser-open"
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    [ -f "$TEST_TEMP/opened.log" ] && break
    sleep 0.5
  done
  kill "$wpid" 2>/dev/null || true
  wait "$wpid" 2>/dev/null || true
  [ -f "$TEST_TEMP/opened.log" ] || { echo "code-paste login URL was deferred; in-session login never reaches a browser"; return 1; }
  run cat "$TEST_TEMP/opened.log"
  assert_output --partial "console.anthropic.com"
}

# Claude Code 2.1.191+ refuses to invoke ANY opener on a display-less Linux
# system unless \$BROWSER is set, and its login drops to the manual code-paste
# flow: the open shim never fired, so the bridge never even saw the login URL.
# Creating the box with BROWSER pointing at the shim flips both gates (URLs
# open through the bridge, and the hands-free loopback login returns).
@test "regression v1.1.1: container is created with BROWSER pointing at the open shim" {
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"

  run cmd_run "$TEST_TEMP/project"
  assert_success
  run assert_docker_run_has "$cname" "BROWSER=/usr/local/bin/open-bridge"
  assert_success
}

# The v1.1.1 fix above only lands at CREATE: docker exec inherits the
# container's Config.Env, frozen at create time, so a box created before
# v1.1.1 never sees that -e BROWSER and claude 2.1.191+ still drops to the
# manual code-paste login on every /login, forever. Nothing ever nags a
# recreate (the config fingerprint deliberately excludes cleat-injected env),
# so long-lived boxes stayed broken across releases; reported on real
# hardware 2026-07-11. Every session exec must therefore carry BROWSER
# itself, healing existing boxes with no recreate.
@test "regression: attaching to a box created before v1.1.1 still gets BROWSER at exec time" {
  # exec_claude alone, no cmd_run first: the recorded exec is the ONLY place
  # BROWSER can come from, exactly like a pre-v1.1.1 container's frozen env.
  run exec_claude "prev111-ctr" --dangerously-skip-permissions
  run assert_docker_exec_has "prev111-ctr"
  assert_success
  run assert_docker_exec_has "BROWSER=/usr/local/bin/open-bridge"
  assert_success
}

# An in-box login writes oauthAccount only into THAT box's per-project
# claude.json; the host file never learns it. After a logout wiped the shared
# credentials, the user logged in again in one box, opened a second terminal,
# and was asked to log in AGAIN: the other box's claude.json had no
# oauthAccount (the login gate) even though the shared .credentials.json was
# fresh. Starting a stopped box must fold the newest sibling login in.
@test "regression v1.1.1: starting a stopped box after an in-box login elsewhere carries the login in" {
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"
  is_running() { return 1; }   # container exists but is NOT running
  mock_docker_ps_a "$cname"
  mkdir -p "$CLEAT_RUN_DIR/${cname}/settings"
  echo '{}' > "$CLEAT_RUN_DIR/${cname}/settings/settings.json"
  rm -f "${HOME}/.claude.json"   # the host never logs in
  # the login happened inside ANOTHER box
  mkdir -p "$CLEAT_PROJECTS_DIR/box-elsewhere"
  echo '{"oauthAccount":{"emailAddress":"inbox@login.dev"},"userID":"u9"}' > "$CLEAT_PROJECTS_DIR/box-elsewhere/claude.json"
  # this box's copy predates that login (the logout wiped its oauthAccount)
  local key
  key="$(_derive_project_session_key "$TEST_TEMP/project" "main")"
  mkdir -p "$CLEAT_PROJECTS_DIR/$key"
  echo '{"projects":{}}' > "$CLEAT_PROJECTS_DIR/$key/claude.json"

  run cmd_start "$TEST_TEMP/project"
  assert_output --partial "Container started"
  run jq -r '.oauthAccount.emailAddress' "$CLEAT_PROJECTS_DIR/$key/claude.json"
  assert_output "inbox@login.dev"
  rm -rf "$CLEAT_RUN_DIR/${cname}/settings"
}

# An in-box /logout leaves hasCompletedOnboarding:false in that box's live
# bind-mounted ~/.claude.json (and deletes the shared credentials). Claude
# 2.1.x gates its startup login/onboarding screen on that flag ALONE, and
# cleat re-forced it only at container (re)create, so every new session in the
# still-running box demanded a login again, even after a fresh login elsewhere
# had restored the shared credentials. Attaching must heal the file in place
# (same inode: the bind mount pins it) when no live agent is in the box.
@test "regression v1.1.1: attaching to a running logged-out box heals its claude.json in place" {
  local cname="heal-ctr"
  _RESOLVED_PROJECT="$TEST_TEMP/project"
  mkdir -p "$_RESOLVED_PROJECT"
  local key
  key="$(_derive_project_session_key "$_RESOLVED_PROJECT" "main")"
  mkdir -p "$CLEAT_PROJECTS_DIR/$key"
  local f="$CLEAT_PROJECTS_DIR/$key/claude.json"
  echo '{"hasCompletedOnboarding":false,"projects":{}}' > "$f"
  # the identity to inherit lives in a sibling box (where the user logged in)
  mkdir -p "$CLEAT_PROJECTS_DIR/box-elsewhere2"
  echo '{"oauthAccount":{"emailAddress":"heal@login.dev"}}' > "$CLEAT_PROJECTS_DIR/box-elsewhere2/claude.json"
  rm -f "${HOME}/.claude.json"
  _box_has_live_agent() { return 1; }   # no claude/node running in the box

  local inode_before inode_after
  inode_before="$(ls -i "$f" | awk '{print $1}')"
  run exec_claude "$cname" --dangerously-skip-permissions
  inode_after="$(ls -i "$f" | awk '{print $1}')"

  run jq -r '.hasCompletedOnboarding' "$f"
  assert_output "true"
  run jq -r '.oauthAccount.emailAddress' "$f"
  assert_output "heal@login.dev"
  [ "$inode_before" = "$inode_after" ] || { echo "inode changed: the bind-mounted file was swapped, the running box would keep reading the old one"; return 1; }
}

# ─────────────────────────────────────────────────────────────────────────────
# v1.1.1 (latent since the settings mask): a fresh host that never ran native
# claude has no ~/.claude/settings.json, and on macOS Docker Desktop the
# settings mask (a FILE bind nested inside the ~/.claude bind) fails with an
# opaque OCI "outside of rootfs" error when its target is missing inside the
# parent bind's source (VirtioFS cannot create files at nested bind targets).
# Every developer machine masked the bug because the file existed; the
# integration suite run against a real macOS daemon (2026-07-10) exposed it.
# The fix pre-creates the target as '{}' (valid JSON, inert for native
# claude), exactly like the history.jsonl touch above it in cmd_run.
@test "regression v1.1.1: fresh host without ~/.claude/settings.json can create a box under virtiofs" {
  export DOCKER_STUB_SIMULATE_VIRTIOFS=1
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project"
  rm -f "$HOME/.claude/settings.json"

  run cmd_run "$TEST_TEMP/project"
  assert_success

  # The pre-created target must be valid JSON so native claude still parses it.
  run cat "$HOME/.claude/settings.json"
  assert_output "{}"
}

# ─────────────────────────────────────────────────────────────────────────────
# v1.2.0: on a root-only host (a stock VPS image, `sudo cleat`) the
# entrypoint's uid remap makes the box user uid 0, and claude hard-refuses
# --dangerously-skip-permissions under uid 0 (its root/sudo guard,
# anthropics/claude-code#9184), so every session died at launch with "Claude
# exited with code 1" right after a green bring-up. IS_SANDBOX=1 is upstream's
# own bypass for sandboxed containers (their reference devcontainer sets it).
# It must ride CLAUDE_ENV (every exec, like the BROWSER heal) so existing root
# boxes heal on their next session, and must stay OUT of the env on non-root
# hosts so an ordinary box's environment is unchanged.
@test "regression v1.2.0: root host rides IS_SANDBOX=1 on every session exec, non-root stays clean" {
  # CLAUDE_ENV is built at SOURCE time from `id -u`, so both branches must be
  # exercised in fresh subprocesses with a shimmed id (a shell function beats
  # the PATH binary inside command substitution), same technique as the
  # COLORTERM test in exec_claude.bats.
  local stripped="$TEST_TEMP/cli_stripped_rootenv"
  sed 's/^set -euo pipefail$/:/' "$CLI" > "$stripped"
  run bash -c "id() { echo 0; }; source '$stripped'; printf '%s\n' \"\${CLAUDE_ENV[@]}\""
  assert_success
  assert_output --partial "IS_SANDBOX=1"
  run bash -c "id() { echo 501; }; source '$stripped'; printf '%s\n' \"\${CLAUDE_ENV[@]}\""
  assert_success
  refute_output --partial "IS_SANDBOX"
}
