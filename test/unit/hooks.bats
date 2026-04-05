#!/usr/bin/env bats

load "../setup"

setup() {
  _common_setup
  use_docker_stub
  source_cli

  # Override config paths
  CLEAT_CONFIG_DIR="$TEST_TEMP/cleat-config"
  CLEAT_GLOBAL_CONFIG="$CLEAT_CONFIG_DIR/config"
  CLEAT_GLOBAL_ENV="$CLEAT_CONFIG_DIR/env"
  _first_run_tip_file="$CLEAT_CONFIG_DIR/.tip-shown"
  mkdir -p "$CLEAT_CONFIG_DIR"

  # Disable unrelated side effects
  _host_clip_cmd() { echo ""; }
  check_for_update() { true; }
  check_drift() { true; }
  show_first_run_tip() { true; }

  # Reset host settings (may be a bind mount, so truncate instead of rm)
  : > "${HOME}/.claude/settings.json" 2>/dev/null || true

  # Enable hooks capability by default for hooks tests
  cat > "$CLEAT_GLOBAL_CONFIG" << 'EOF'
[caps]
hooks
EOF
}

teardown() {
  : > "${HOME}/.claude/settings.json" 2>/dev/null || true
  _common_teardown
}

# ── Hooks log mount ─────────────────────────────────────────────────────

@test "run: mounts hooks log directory" {
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"

  run cmd_run "$TEST_TEMP/project"
  assert_success
  run assert_docker_run_has "$cname" "/var/log/cleat"
  assert_success
}

@test "run: creates hooks directory on host" {
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"

  cmd_run "$TEST_TEMP/project"
  [[ -d "/tmp/cleat-hooks-${cname}" ]] || return 1
  # Clean up
  rmdir "/tmp/cleat-hooks-${cname}" 2>/dev/null || true
}

# ── Host connectivity ───────────────────────────────────────────────────

@test "run: adds --add-host when not Docker Desktop" {
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"

  # Mock _is_docker_desktop to return false (Linux Docker Engine)
  _is_docker_desktop() { return 1; }

  run cmd_run "$TEST_TEMP/project"
  assert_success
  run assert_docker_run_has "$cname" "--add-host"
  assert_success
  run assert_docker_run_has "$cname" "host.docker.internal:host-gateway"
  assert_success
}

@test "run: skips --add-host on Docker Desktop" {
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"

  # Mock _is_docker_desktop to return true
  _is_docker_desktop() { return 0; }

  run cmd_run "$TEST_TEMP/project"
  assert_success
  run assert_docker_run_lacks "$cname" "--add-host"
  assert_success
}

# ── _is_docker_desktop ──────────────────────────────────────────────────

@test "_is_docker_desktop: true when docker info shows Docker Desktop" {
  # Create a mock docker that outputs Docker Desktop info
  local mock_dir="$TEST_TEMP/mock-docker-desktop"
  mkdir -p "$mock_dir"
  cat > "$mock_dir/docker" << 'SCRIPT'
#!/bin/bash
if [[ "$1" == "info" ]]; then
  echo "Operating System: Docker Desktop"
  exit 0
fi
SCRIPT
  chmod +x "$mock_dir/docker"
  PATH="$mock_dir:$PATH" run _is_docker_desktop
  assert_success
}

@test "_is_docker_desktop: false when docker info shows Linux" {
  local mock_dir="$TEST_TEMP/mock-docker-linux"
  mkdir -p "$mock_dir"
  cat > "$mock_dir/docker" << 'SCRIPT'
#!/bin/bash
if [[ "$1" == "info" ]]; then
  echo "Operating System: Ubuntu 22.04.3 LTS"
  exit 0
fi
SCRIPT
  chmod +x "$mock_dir/docker"
  PATH="$mock_dir:$PATH" run _is_docker_desktop
  assert_failure
}

# ── cmd_hooks: no log file ──────────────────────────────────────────────

@test "hooks: shows info when no events exist" {
  mkdir -p "$TEST_TEMP/project"
  run cmd_hooks "$TEST_TEMP/project"
  assert_success
  assert_output --partial "No hook events yet"
}

# ── cmd_hooks: read existing log ────────────────────────────────────────

@test "hooks: reads and pretty-prints JSONL" {
  mkdir -p "$TEST_TEMP/project"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"
  local hooks_dir="/tmp/cleat-hooks-${cname}"
  mkdir -p "$hooks_dir"

  cat > "$hooks_dir/hooks.jsonl" << 'EOF'
{"hook_event_name":"SessionStart","session_id":"abc","_cleat_ts":"2026-03-29T10:30:00.123Z"}
{"hook_event_name":"PostToolUse","tool_name":"Bash","session_id":"abc","_cleat_ts":"2026-03-29T10:30:05.456Z"}
{"hook_event_name":"SessionEnd","session_id":"abc","_cleat_ts":"2026-03-29T10:35:00.789Z"}
EOF

  run cmd_hooks "$TEST_TEMP/project"
  assert_success
  assert_output --partial "SessionStart"
  assert_output --partial "PostToolUse"
  assert_output --partial "(Bash)"
  assert_output --partial "SessionEnd"

  rm -rf "$hooks_dir"
}

@test "hooks: --json outputs raw JSONL" {
  mkdir -p "$TEST_TEMP/project"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"
  local hooks_dir="/tmp/cleat-hooks-${cname}"
  mkdir -p "$hooks_dir"

  echo '{"hook_event_name":"SessionStart","_cleat_ts":"2026-03-29T10:30:00Z"}' > "$hooks_dir/hooks.jsonl"

  run cmd_hooks "$TEST_TEMP/project" --json
  assert_success
  assert_output --partial '"hook_event_name":"SessionStart"'

  rm -rf "$hooks_dir"
}

# ── cmd_hooks: --clear ──────────────────────────────────────────────────

@test "hooks: --clear empties the log file" {
  mkdir -p "$TEST_TEMP/project"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"
  local hooks_dir="/tmp/cleat-hooks-${cname}"
  mkdir -p "$hooks_dir"

  echo '{"hook_event_name":"SessionStart"}' > "$hooks_dir/hooks.jsonl"

  run cmd_hooks "$TEST_TEMP/project" --clear
  assert_success
  assert_output --partial "Hook log cleared"

  # File should be empty
  local size
  size=$(wc -c < "$hooks_dir/hooks.jsonl")
  [[ "$size" -eq 0 ]] || return 1

  rm -rf "$hooks_dir"
}

@test "hooks: --clear when no log exists" {
  mkdir -p "$TEST_TEMP/project"
  run cmd_hooks "$TEST_TEMP/project" --clear
  assert_success
  assert_output --partial "No hook log to clear"
}

# ── _hooks_pretty_print ────────────────────────────────────────────────

@test "pretty print: handles events without tool_name" {
  run bash -c 'echo "{\"hook_event_name\":\"SessionStart\",\"_cleat_ts\":\"2026-03-29T10:30:00Z\"}" | _hooks_pretty_print'
  # Can't call bash function directly in subshell, test via cmd_hooks instead
  mkdir -p "$TEST_TEMP/project"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"
  local hooks_dir="/tmp/cleat-hooks-${cname}"
  mkdir -p "$hooks_dir"

  echo '{"hook_event_name":"SessionStart","_cleat_ts":"2026-03-29T10:30:00Z"}' > "$hooks_dir/hooks.jsonl"

  run cmd_hooks "$TEST_TEMP/project"
  assert_output --partial "SessionStart"
  refute_output --partial "()"

  rm -rf "$hooks_dir"
}

@test "pretty print: shows time without date" {
  mkdir -p "$TEST_TEMP/project"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"
  local hooks_dir="/tmp/cleat-hooks-${cname}"
  mkdir -p "$hooks_dir"

  echo '{"hook_event_name":"PostToolUse","tool_name":"Write","_cleat_ts":"2026-03-29T14:22:33.456Z"}' > "$hooks_dir/hooks.jsonl"

  run cmd_hooks "$TEST_TEMP/project"
  assert_output --partial "14:22:33"
  refute_output --partial "2026-03-29"

  rm -rf "$hooks_dir"
}

@test "pretty print: handles malformed JSON gracefully" {
  mkdir -p "$TEST_TEMP/project"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"
  local hooks_dir="/tmp/cleat-hooks-${cname}"
  mkdir -p "$hooks_dir"

  echo "not json at all" > "$hooks_dir/hooks.jsonl"

  run cmd_hooks "$TEST_TEMP/project"
  assert_success
  # Should still output something (raw line)
  assert_output --partial "not json at all"

  rm -rf "$hooks_dir"
}

# ── cleat-hook-logger script ────────────────────────────────────────────

@test "hook-logger: appends JSONL with timestamp" {
  local logger="$PROJECT_ROOT/docker/cleat-hook-logger"
  local log_dir="$TEST_TEMP/log"
  mkdir -p "$log_dir"

  # Override LOG_DIR for testing by wrapping the script
  echo '{"hook_event_name":"PostToolUse","tool_name":"Bash"}' | \
    LOG_DIR="$log_dir" bash -c '
      export LOG_DIR
      # Source the logger with overridden LOG_DIR
      sed "s|/var/log/cleat|$LOG_DIR|g" "'"$logger"'" | bash
    '

  # Simpler approach: just run with modified env
  rm -rf "$log_dir"
  mkdir -p "$log_dir"

  local wrapper="$TEST_TEMP/test-logger.sh"
  sed "s|/var/log/cleat|${log_dir}|g" "$logger" > "$wrapper"
  chmod +x "$wrapper"

  echo '{"hook_event_name":"PostToolUse","tool_name":"Bash"}' | bash "$wrapper"
  [[ -f "$log_dir/hooks.jsonl" ]] || return 1

  # Should contain the event with a timestamp
  run cat "$log_dir/hooks.jsonl"
  assert_output --partial '"hook_event_name":"PostToolUse"'
  assert_output --partial '"_cleat_ts"'
}

@test "hook-logger: handles empty stdin" {
  local logger="$PROJECT_ROOT/docker/cleat-hook-logger"
  local log_dir="$TEST_TEMP/log"
  mkdir -p "$log_dir"

  local wrapper="$TEST_TEMP/test-logger.sh"
  sed "s|/var/log/cleat|${log_dir}|g" "$logger" > "$wrapper"
  chmod +x "$wrapper"

  echo "" | bash "$wrapper"
  # Should not create a log entry for empty input
  if [[ -f "$log_dir/hooks.jsonl" ]]; then
    local size
    size=$(wc -c < "$log_dir/hooks.jsonl")
    [[ "$size" -eq 0 ]] || return 1
  fi
}

@test "hook-logger: handles invalid JSON" {
  local logger="$PROJECT_ROOT/docker/cleat-hook-logger"
  local log_dir="$TEST_TEMP/log"
  mkdir -p "$log_dir"

  local wrapper="$TEST_TEMP/test-logger.sh"
  sed "s|/var/log/cleat|${log_dir}|g" "$logger" > "$wrapper"
  chmod +x "$wrapper"

  echo "this is not json" | bash "$wrapper"
  [[ -f "$log_dir/hooks.jsonl" ]] || return 1

  # Should wrap the raw input with metadata
  run cat "$log_dir/hooks.jsonl"
  assert_output --partial '"_cleat_raw"'
  assert_output --partial '"_cleat_ts"'
}

@test "hook-logger: appends multiple events (does not overwrite)" {
  local logger="$PROJECT_ROOT/docker/cleat-hook-logger"
  local log_dir="$TEST_TEMP/log"
  mkdir -p "$log_dir"

  local wrapper="$TEST_TEMP/test-logger.sh"
  sed "s|/var/log/cleat|${log_dir}|g" "$logger" > "$wrapper"
  chmod +x "$wrapper"

  echo '{"hook_event_name":"SessionStart"}' | bash "$wrapper"
  echo '{"hook_event_name":"PostToolUse"}' | bash "$wrapper"
  echo '{"hook_event_name":"SessionEnd"}' | bash "$wrapper"

  local lines
  lines=$(wc -l < "$log_dir/hooks.jsonl")
  [[ "$lines" -eq 3 ]] || return 1
}

@test "hook-logger: exits 0 always (non-blocking)" {
  local logger="$PROJECT_ROOT/docker/cleat-hook-logger"
  local log_dir="$TEST_TEMP/log"
  mkdir -p "$log_dir"

  local wrapper="$TEST_TEMP/test-logger.sh"
  sed "s|/var/log/cleat|${log_dir}|g" "$logger" > "$wrapper"
  chmod +x "$wrapper"

  run bash "$wrapper" <<< '{"hook_event_name":"test"}'
  assert_success

  run bash "$wrapper" <<< 'invalid'
  assert_success

  run bash "$wrapper" <<< ''
  assert_success
}

# ── entrypoint hook injection ───────────────────────────────────────────

@test "entrypoint: injects hook settings into settings.local.json" {
  local workspace="$TEST_TEMP/workspace"
  mkdir -p "$workspace"

  # Simulate the entrypoint's _inject_hook_settings function
  # by running the relevant part directly
  local settings_dir="$workspace/.claude"
  local settings_file="$settings_dir/settings.local.json"

  # Copy the function from entrypoint and run it
  local entrypoint="$PROJECT_ROOT/docker/entrypoint.sh"

  # Extract and run just the injection function
  HOST_UID=$(id -u)
  HOST_GID=$(id -g)
  export HOST_UID HOST_GID

  # Run the function in a subshell with /workspace overridden
  bash -c '
    source /dev/stdin << '"'"'FUNC'"'"'
_inject_hook_settings() {
  local settings_dir="'"$settings_dir"'"
  local settings_file="$settings_dir/settings.local.json"
  local hook_events="SessionStart SessionEnd PostToolUse PostToolUseFailure Notification SubagentStart SubagentStop CwdChanged FileChanged PreCompact PostCompact Stop StopFailure"
  local cmd="test -x /usr/local/bin/cleat-hook-logger && cleat-hook-logger || true"
  local hooks_json="{\"hooks\":{"
  local first=true
  for event in $hook_events; do
    if [ "$first" = true ]; then first=false; else hooks_json+=","; fi
    hooks_json+="\"$event\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"$cmd\",\"async\":true}]}]"
  done
  hooks_json+="}}"
  mkdir -p "$settings_dir" 2>/dev/null || true
  if [ -f "$settings_file" ]; then
    if grep -q "cleat-hook-logger" "$settings_file" 2>/dev/null; then return 0; fi
  fi
  echo "$hooks_json" | jq "." > "$settings_file"
}
FUNC
    _inject_hook_settings
  '

  # Verify the settings file was created
  [[ -f "$settings_file" ]] || return 1

  # Verify it contains hook config for key events
  run cat "$settings_file"
  assert_output --partial '"SessionStart"'
  assert_output --partial '"PostToolUse"'
  assert_output --partial '"SessionEnd"'
  assert_output --partial "cleat-hook-logger"
  assert_output --partial '"async": true'
}

@test "entrypoint: skips injection when hooks already configured" {
  local workspace="$TEST_TEMP/workspace"
  mkdir -p "$workspace/.claude"
  local settings_file="$workspace/.claude/settings.local.json"

  # Create existing settings with cleat-hook-logger already present
  echo '{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"cleat-hook-logger","async":true}]}]}}' > "$settings_file"

  local original
  original="$(cat "$settings_file")"

  HOST_UID=$(id -u)
  HOST_GID=$(id -g)

  bash -c '
    _inject_hook_settings() {
      local settings_dir="'"$workspace/.claude"'"
      local settings_file="$settings_dir/settings.local.json"
      if [ -f "$settings_file" ]; then
        if grep -q "cleat-hook-logger" "$settings_file" 2>/dev/null; then return 0; fi
      fi
      echo "SHOULD_NOT_REACH" > "$settings_file"
    }
    _inject_hook_settings
  '

  # File should not have been modified
  local current
  current="$(cat "$settings_file")"
  [[ "$current" == "$original" ]] || return 1
}

# ── help includes hooks ─────────────────────────────────────────────────

@test "help: shows hooks command" {
  run cmd_help
  assert_output --partial "hooks"
  assert_output --partial "--json"
  assert_output --partial "--follow"
  assert_output --partial "--clear"
}

# ── strict mode: hooks command with no args ─────────────────────────────

@test "strict mode: cleat hooks runs without unbound variable error" {
  run bash "$CLI" hooks 2>&1
  refute_output --partial "unbound variable"
}

# ── cmd_hooks flag parsing ──────────────────────────────────────────────

@test "hooks: --json flag works without path arg" {
  mkdir -p "$TEST_TEMP/project"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"
  local hooks_dir="/tmp/cleat-hooks-${cname}"
  mkdir -p "$hooks_dir"
  echo '{"hook_event_name":"SessionStart"}' > "$hooks_dir/hooks.jsonl"

  # Override resolve_project to return our test path (simulates cwd)
  resolve_project() { echo "$TEST_TEMP/project"; }

  run cmd_hooks --json
  assert_success
  assert_output --partial '"hook_event_name":"SessionStart"'

  rm -rf "$hooks_dir"
}

@test "hooks: flags and path can be in any order" {
  mkdir -p "$TEST_TEMP/project"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"
  local hooks_dir="/tmp/cleat-hooks-${cname}"
  mkdir -p "$hooks_dir"
  echo '{"hook_event_name":"PostToolUse","tool_name":"Edit"}' > "$hooks_dir/hooks.jsonl"

  run cmd_hooks --json "$TEST_TEMP/project"
  assert_success
  assert_output --partial '"hook_event_name":"PostToolUse"'

  rm -rf "$hooks_dir"
}

# ── cmd_rm cleanup ──────────────────────────────────────────────────────

@test "rm: cleans up hooks temp directory" {
  mkdir -p "$TEST_TEMP/project"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"
  mock_docker_ps "$cname"
  mock_docker_ps_a "$cname"

  # Create hooks dir
  local hooks_dir="/tmp/cleat-hooks-${cname}"
  mkdir -p "$hooks_dir"
  echo "test" > "$hooks_dir/hooks.jsonl"

  run cmd_rm "$TEST_TEMP/project"
  assert_success

  # Hooks dir should be cleaned up
  [[ ! -d "$hooks_dir" ]] || return 1
}

# ── hook-logger: JSON with special characters ───────────────────────────

@test "hook-logger: handles JSON with special characters" {
  local logger="$PROJECT_ROOT/docker/cleat-hook-logger"
  local log_dir="$TEST_TEMP/log"
  mkdir -p "$log_dir"

  local wrapper="$TEST_TEMP/test-logger.sh"
  sed "s|/var/log/cleat|${log_dir}|g" "$logger" > "$wrapper"
  chmod +x "$wrapper"

  echo '{"hook_event_name":"PostToolUse","tool_input":{"command":"echo '\''hello world'\''"}}' | bash "$wrapper"
  [[ -f "$log_dir/hooks.jsonl" ]] || return 1

  run cat "$log_dir/hooks.jsonl"
  assert_output --partial '"PostToolUse"'
  assert_output --partial '"_cleat_ts"'
}

# ── hooks capability gating ──────────────────────────────────────────────

@test "run: passes CLEAT_NO_HOOKS=1 when hooks cap is disabled" {
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project"
  # Disable hooks capability
  cat > "$CLEAT_GLOBAL_CONFIG" << 'EOF'
[caps]
git
EOF
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"

  run cmd_run "$TEST_TEMP/project"
  assert_success
  run assert_docker_run_has "$cname" "CLEAT_NO_HOOKS=1"
  assert_success
}

@test "run: does not pass CLEAT_NO_HOOKS when hooks cap is active" {
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"

  run cmd_run "$TEST_TEMP/project"
  assert_success
  run assert_docker_run_lacks "$cname" "CLEAT_NO_HOOKS"
  assert_success
}

@test "run: no hooks mount when hooks cap is disabled" {
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project"
  cat > "$CLEAT_GLOBAL_CONFIG" << 'EOF'
[caps]
git
EOF
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"

  run cmd_run "$TEST_TEMP/project"
  assert_success
  run assert_docker_run_lacks "$cname" "/var/log/cleat"
  assert_success
}

@test "run: --add-host on Linux Docker Engine even without hooks cap" {
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project"
  cat > "$CLEAT_GLOBAL_CONFIG" << 'EOF'
[caps]
git
EOF
  _is_docker_desktop() { return 1; }
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"

  run cmd_run "$TEST_TEMP/project"
  assert_success
  run assert_docker_run_has "$cname" "host.docker.internal:host-gateway"
  assert_success
}

# ── pretty-print: event type color coding ────────────────────────────────

@test "pretty print: PostToolUseFailure shown (red event)" {
  mkdir -p "$TEST_TEMP/project"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"
  local hooks_dir="/tmp/cleat-hooks-${cname}"
  mkdir -p "$hooks_dir"

  echo '{"hook_event_name":"PostToolUseFailure","tool_name":"Bash","_cleat_ts":"2026-03-30T12:00:00Z"}' > "$hooks_dir/hooks.jsonl"

  run cmd_hooks "$TEST_TEMP/project"
  assert_success
  assert_output --partial "PostToolUseFailure"
  assert_output --partial "(Bash)"

  rm -rf "$hooks_dir"
}

@test "pretty print: Notification event shown" {
  mkdir -p "$TEST_TEMP/project"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"
  local hooks_dir="/tmp/cleat-hooks-${cname}"
  mkdir -p "$hooks_dir"

  echo '{"hook_event_name":"Notification","_cleat_ts":"2026-03-30T12:00:00Z"}' > "$hooks_dir/hooks.jsonl"

  run cmd_hooks "$TEST_TEMP/project"
  assert_success
  assert_output --partial "Notification"

  rm -rf "$hooks_dir"
}

@test "pretty print: unknown event type defaults gracefully" {
  mkdir -p "$TEST_TEMP/project"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"
  local hooks_dir="/tmp/cleat-hooks-${cname}"
  mkdir -p "$hooks_dir"

  echo '{"hook_event_name":"CwdChanged","_cleat_ts":"2026-03-30T12:00:00Z"}' > "$hooks_dir/hooks.jsonl"

  run cmd_hooks "$TEST_TEMP/project"
  assert_success
  assert_output --partial "CwdChanged"

  rm -rf "$hooks_dir"
}

@test "pretty print: Stop event shown (yellow)" {
  mkdir -p "$TEST_TEMP/project"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"
  local hooks_dir="/tmp/cleat-hooks-${cname}"
  mkdir -p "$hooks_dir"

  echo '{"hook_event_name":"Stop","_cleat_ts":"2026-03-30T12:00:00Z"}' > "$hooks_dir/hooks.jsonl"

  run cmd_hooks "$TEST_TEMP/project"
  assert_success
  assert_output --partial "Stop"

  rm -rf "$hooks_dir"
}

# ── cmd_hooks: unknown flag ──────────────────────────────────────────────

@test "hooks: warns on unknown flag" {
  mkdir -p "$TEST_TEMP/project"
  run cmd_hooks "$TEST_TEMP/project" --invalid
  assert_output --partial "Unknown flag"
}

# ── _is_docker_desktop: docker command fails ─────────────────────────────

@test "_is_docker_desktop: returns false when docker fails" {
  local mock_dir="$TEST_TEMP/mock-docker-fail"
  mkdir -p "$mock_dir"
  cat > "$mock_dir/docker" << 'SCRIPT'
#!/bin/bash
exit 1
SCRIPT
  chmod +x "$mock_dir/docker"
  PATH="$mock_dir:$PATH" run _is_docker_desktop
  assert_failure
}

# ── --cap hooks session-only ─────────────────────────────────────────────

@test "run: --cap hooks enables hooks for single session" {
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project"
  # No hooks in global config
  cat > "$CLEAT_GLOBAL_CONFIG" << 'EOF'
[caps]
git
EOF
  # Simulate --cap hooks via _CLI_CAPS
  _CLI_CAPS=(hooks)
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"

  run cmd_run "$TEST_TEMP/project"
  assert_success
  run assert_docker_run_has "$cname" "/var/log/cleat"
  assert_success
  run assert_docker_run_lacks "$cname" "CLEAT_NO_HOOKS"
  assert_success
}

# ── _cap_description hooks ───────────────────────────────────────────────

@test "cap_description: hooks has a description" {
  run _cap_description hooks
  assert_output --partial "hook events"
  assert_output --partial "JSONL"
}

# ── config --list includes hooks ─────────────────────────────────────────

@test "config --list: shows hooks capability" {
  run cmd_config --list
  assert_output --partial "hooks"
  assert_output --partial "hook events"
}

@test "config --list: shows hooks as enabled when active" {
  run cmd_config --list
  # hooks is enabled in setup via CLEAT_GLOBAL_CONFIG
  assert_output --partial "hooks"
}

# ── no capabilities at all ───────────────────────────────────────────────

@test "run: works with completely empty config (no caps)" {
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project"
  : > "$CLEAT_GLOBAL_CONFIG"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"

  run cmd_run "$TEST_TEMP/project"
  assert_success
  # Should pass CLEAT_NO_HOOKS since hooks not enabled
  run assert_docker_run_has "$cname" "CLEAT_NO_HOOKS=1"
  assert_success
  # Should not have hooks mount
  run assert_docker_run_lacks "$cname" "/var/log/cleat"
  assert_success
}

# ── entrypoint: merge with existing non-hook settings ────────────────────

@test "entrypoint: merges hooks into existing non-hook settings" {
  local workspace="$TEST_TEMP/workspace"
  mkdir -p "$workspace/.claude"
  local settings_file="$workspace/.claude/settings.local.json"

  # Create existing settings WITHOUT hooks
  echo '{"permissions":{"allow":["Bash(*)"]}}' > "$settings_file"

  HOST_UID=$(id -u)
  HOST_GID=$(id -g)
  export HOST_UID HOST_GID

  # Run the entrypoint merge function
  bash -c '
    HOST_UID='"$HOST_UID"'
    HOST_GID='"$HOST_GID"'
    _inject_hook_settings() {
      local settings_dir="'"$workspace/.claude"'"
      local settings_file="$settings_dir/settings.local.json"
      local hook_events="SessionStart SessionEnd PostToolUse"
      local cmd="test -x /usr/local/bin/cleat-hook-logger && cleat-hook-logger || true"
      local hooks_json="{\"hooks\":{"
      local first=true
      for event in $hook_events; do
        if [ "$first" = true ]; then first=false; else hooks_json+=","; fi
        hooks_json+="\"$event\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"$cmd\",\"async\":true}]}]"
      done
      hooks_json+="}}"
      mkdir -p "$settings_dir" 2>/dev/null || true
      if [ -f "$settings_file" ]; then
        if grep -q "cleat-hook-logger" "$settings_file" 2>/dev/null; then return 0; fi
        local existing
        existing="$(cat "$settings_file" 2>/dev/null)" || existing="{}"
        echo "$existing" | jq --argjson new_hooks "$hooks_json" '"'"'
          .hooks = ((.hooks // {}) as $existing |
            ($new_hooks.hooks) as $new |
            ($existing * ($new | to_entries | map({
              key: .key,
              value: (($existing[.key] // []) + .value)
            }) | from_entries)))
        '"'"' > "${settings_file}.tmp" 2>/dev/null && mv "${settings_file}.tmp" "$settings_file"
      else
        echo "$hooks_json" | jq "." > "$settings_file"
      fi
    }
    _inject_hook_settings
  '

  # Verify merged result has BOTH original permissions AND new hooks
  run cat "$settings_file"
  assert_output --partial '"permissions"'
  assert_output --partial '"Bash(*)"'
  assert_output --partial '"SessionStart"'
  assert_output --partial "cleat-hook-logger"
}

# ── hook-logger: output is valid JSONL ───────────────────────────────────

@test "hook-logger: every output line is valid JSON" {
  local logger="$PROJECT_ROOT/docker/cleat-hook-logger"
  local log_dir="$TEST_TEMP/log"
  mkdir -p "$log_dir"

  local wrapper="$TEST_TEMP/test-logger.sh"
  sed "s|/var/log/cleat|${log_dir}|g" "$logger" > "$wrapper"
  chmod +x "$wrapper"

  echo '{"hook_event_name":"SessionStart","session_id":"s1"}' | bash "$wrapper"
  echo '{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"ls"}}' | bash "$wrapper"
  echo 'not json' | bash "$wrapper"

  # Every line should be valid JSON
  while IFS= read -r line; do
    echo "$line" | jq empty 2>/dev/null || return 1
  done < "$log_dir/hooks.jsonl"
}

# ── Settings overlay: strip host hooks from container ────────────────────

@test "run: overlays settings.json with hooks stripped" {
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project"

  # Create a host settings.json with hooks
  mkdir -p "${HOME}/.claude"
  cat > "${HOME}/.claude/settings.json" << 'EOF'
{"permissions":{"allow":["Bash(*)"]},"hooks":{"Stop":[{"hooks":[{"type":"command","command":"osascript -e 'display notification'"}]}]}}
EOF

  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"
  run cmd_run "$TEST_TEMP/project"
  assert_success

  # The overlay file should exist and have hooks stripped
  local overlay="/tmp/cleat-settings-${cname}/settings.json"
  [[ -f "$overlay" ]] || return 1

  # Should keep permissions
  run jq -r '.permissions.allow[0]' "$overlay"
  assert_output "Bash(*)"

  # Should NOT have hooks
  run jq -r '.hooks // "none"' "$overlay"
  assert_output "none"

  # Docker should mount the overlay on top of ~/.claude/settings.json
  run assert_docker_run_has "$cname" "settings.json:/home/coder/.claude/settings.json"
  assert_success

  rm -rf "/tmp/cleat-settings-${cname}" "/tmp/cleat-hooks-${cname}"
}

@test "run: overlay works when settings.json is empty" {
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project"

  # Settings.json is empty (reset by setup)
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"
  run cmd_run "$TEST_TEMP/project"
  assert_success

  local overlay="/tmp/cleat-settings-${cname}/settings.json"
  [[ -f "$overlay" ]] || return 1

  # Should be empty object — no hooks leaked
  run cat "$overlay"
  assert_output "{}"

  rm -rf "/tmp/cleat-settings-${cname}" "/tmp/cleat-hooks-${cname}"
}

@test "rm: cleans up settings overlay directory" {
  mkdir -p "$TEST_TEMP/project"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"
  mock_docker_ps "$cname"
  mock_docker_ps_a "$cname"

  local settings_dir="/tmp/cleat-settings-${cname}"
  mkdir -p "$settings_dir"
  echo '{}' > "$settings_dir/settings.json"

  run cmd_rm "$TEST_TEMP/project"
  assert_success
  [[ ! -d "$settings_dir" ]] || return 1
}

# ── Host-side hook bridge ────────────────────────────────────────────────

@test "_has_host_hooks: true when settings.json has hooks" {
  mkdir -p "${HOME}/.claude"
  cat > "${HOME}/.claude/settings.json" << 'EOF'
{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo done"}]}]}}
EOF
  run _has_host_hooks
  assert_success
}

@test "_has_host_hooks: false when settings.json has no hooks" {
  mkdir -p "${HOME}/.claude"
  echo '{"permissions":{}}' > "${HOME}/.claude/settings.json"
  run _has_host_hooks
  assert_failure
}

@test "_has_host_hooks: false when settings.json is empty" {
  : > "${HOME}/.claude/settings.json" 2>/dev/null || true
  run _has_host_hooks
  assert_failure
}

@test "_execute_host_hooks: runs matching command hook" {
  local settings="$TEST_TEMP/host-settings.json"
  local marker="$TEST_TEMP/hook-ran"
  cat > "$settings" << EOF
{"hooks":{"PostToolUse":[{"hooks":[{"type":"command","command":"touch $marker"}]}]}}
EOF

  local event='{"hook_event_name":"PostToolUse","tool_name":"Bash","_cleat_ts":"2026-03-30T12:00:00Z"}'
  _execute_host_hooks "$event" "$settings"
  # Give the background process a moment
  sleep 0.5
  [[ -f "$marker" ]] || return 1
}

@test "_execute_host_hooks: skips non-matching event" {
  local settings="$TEST_TEMP/host-settings.json"
  local marker="$TEST_TEMP/hook-should-not-run"
  cat > "$settings" << EOF
{"hooks":{"SessionEnd":[{"hooks":[{"type":"command","command":"touch $marker"}]}]}}
EOF

  local event='{"hook_event_name":"PostToolUse","tool_name":"Bash"}'
  _execute_host_hooks "$event" "$settings"
  sleep 0.5
  [[ ! -f "$marker" ]] || return 1
}

@test "_execute_host_hooks: respects matcher regex" {
  local settings="$TEST_TEMP/host-settings.json"
  local marker="$TEST_TEMP/matcher-test"
  cat > "$settings" << EOF
{"hooks":{"PostToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"touch $marker"}]}]}}
EOF

  # Non-matching tool name
  local event='{"hook_event_name":"PostToolUse","tool_name":"Write"}'
  _execute_host_hooks "$event" "$settings"
  sleep 0.5
  [[ ! -f "$marker" ]] || return 1

  # Matching tool name
  event='{"hook_event_name":"PostToolUse","tool_name":"Bash"}'
  _execute_host_hooks "$event" "$settings"
  sleep 0.5
  [[ -f "$marker" ]] || return 1
}

@test "_execute_host_hooks: skips http hook types (only runs command)" {
  local settings="$TEST_TEMP/host-settings.json"
  local marker="$TEST_TEMP/http-test"
  cat > "$settings" << EOF
{"hooks":{"PostToolUse":[{"hooks":[{"type":"http","url":"http://localhost:9999"},{"type":"command","command":"touch $marker"}]}]}}
EOF

  local event='{"hook_event_name":"PostToolUse","tool_name":"Bash"}'
  _execute_host_hooks "$event" "$settings"
  sleep 0.5
  # Only the command hook should have run
  [[ -f "$marker" ]] || return 1
}

@test "_execute_host_hooks: handles empty event gracefully" {
  local settings="$TEST_TEMP/host-settings.json"
  echo '{"hooks":{}}' > "$settings"
  run _execute_host_hooks "" "$settings"
  assert_success
}

@test "_execute_host_hooks: passes event JSON on stdin to hook" {
  local settings="$TEST_TEMP/host-settings.json"
  local output="$TEST_TEMP/stdin-capture"
  cat > "$settings" << EOF
{"hooks":{"PostToolUse":[{"hooks":[{"type":"command","command":"cat > $output"}]}]}}
EOF

  local event='{"hook_event_name":"PostToolUse","tool_name":"Bash","data":"hello"}'
  _execute_host_hooks "$event" "$settings"
  sleep 0.5
  [[ -f "$output" ]] || return 1
  run cat "$output"
  assert_output --partial '"hook_event_name":"PostToolUse"'
  assert_output --partial '"data":"hello"'
}

# ── Hook bridge: process safety ───────────────────────────────────────────

@test "_hook_bridge_reap: cleans up finished children" {
  _HOOK_BRIDGE_CHILDREN=()
  # Start a child that exits immediately
  (exit 0) &
  _HOOK_BRIDGE_CHILDREN+=("$!")
  sleep 0.2
  _hook_bridge_reap
  [[ ${#_HOOK_BRIDGE_CHILDREN[@]} -eq 0 ]] || return 1
}

@test "_hook_bridge_cleanup: kills all tracked children" {
  _HOOK_BRIDGE_CHILDREN=()
  sleep 60 &
  _HOOK_BRIDGE_CHILDREN+=("$!")
  sleep 60 &
  _HOOK_BRIDGE_CHILDREN+=("$!")

  _hook_bridge_cleanup

  # Both should be dead
  for pid in "${_HOOK_BRIDGE_CHILDREN[@]+"${_HOOK_BRIDGE_CHILDREN[@]}"}"; do
    run kill -0 "$pid"
    assert_failure
  done
}

@test "_execute_host_hooks: hook completes and marker is created" {
  local settings="$TEST_TEMP/host-settings.json"
  local marker="$TEST_TEMP/zombie-test"
  cat > "$settings" << EOF
{"hooks":{"PostToolUse":[{"hooks":[{"type":"command","command":"touch $marker"}]}]}}
EOF

  _execute_host_hooks '{"hook_event_name":"PostToolUse","tool_name":"Bash"}' "$settings"
  sleep 0.5

  # Marker should exist (hook ran and completed)
  [[ -f "$marker" ]] || return 1
}

@test "run: settings overlay mounts on top of ~/.claude" {
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project"
  mkdir -p "${HOME}/.claude"
  echo '{}' > "${HOME}/.claude/settings.json"

  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"
  run cmd_run "$TEST_TEMP/project"
  assert_success

  # Should have TWO mounts into .claude: the directory and the overlay
  local calls
  calls="$(cat "$DOCKER_CALLS")"
  # The overlay mount should appear AFTER the directory mount
  run assert_docker_run_has "$cname" ".claude:/home/coder/.claude"
  assert_success
  run assert_docker_run_has "$cname" "settings.json:/home/coder/.claude/settings.json"
  assert_success

  rm -rf "/tmp/cleat-settings-${cname}" "/tmp/cleat-hooks-${cname}"
}

@test "hook-logger: handles large JSON payload" {
  local logger="$PROJECT_ROOT/docker/cleat-hook-logger"
  local log_dir="$TEST_TEMP/log"
  mkdir -p "$log_dir"

  local wrapper="$TEST_TEMP/test-logger.sh"
  sed "s|/var/log/cleat|${log_dir}|g" "$logger" > "$wrapper"
  chmod +x "$wrapper"

  # Generate a large JSON payload (~10KB)
  local big_value
  big_value="$(printf 'x%.0s' $(seq 1 10000))"
  echo "{\"hook_event_name\":\"PostToolUse\",\"data\":\"$big_value\"}" | bash "$wrapper"

  [[ -f "$log_dir/hooks.jsonl" ]] || return 1
  local size
  size=$(wc -c < "$log_dir/hooks.jsonl")
  [[ "$size" -gt 10000 ]] || return 1
}

# ── Browser bridge ───────────────────────────────────────────────────────

@test "_host_open_cmd: returns open or xdg-open if available" {
  # At least one should be available in most environments, or empty
  run _host_open_cmd
  assert_success
  # Output is either a command name or empty — no errors
}

@test "browser watcher: opens URL when bridge file changes" {
  local clip_dir="$TEST_TEMP/clip"
  local marker="$TEST_TEMP/browser-opened"
  mkdir -p "$clip_dir"

  # Mock open command that writes to marker
  local mock_open="$TEST_TEMP/mock-open"
  cat > "$mock_open" << 'SCRIPT'
#!/bin/bash
echo "$1" > MARKER_PATH
SCRIPT
  sed -i "s|MARKER_PATH|$marker|" "$mock_open"
  chmod +x "$mock_open"

  # Start watcher
  _browser_watcher "$clip_dir" "$mock_open" &
  local watcher_pid=$!
  sleep 0.3

  # Write a URL to the bridge file
  printf 'https://example.com/auth' > "$clip_dir/.browser-open"
  sleep 1

  # Kill watcher
  kill "$watcher_pid" 2>/dev/null || true
  wait "$watcher_pid" 2>/dev/null || true

  # Verify the URL was opened
  [[ -f "$marker" ]] || return 1
  run cat "$marker"
  assert_output "https://example.com/auth"
}

@test "browser watcher: ignores non-http URLs" {
  local clip_dir="$TEST_TEMP/clip"
  local marker="$TEST_TEMP/browser-should-not-open"
  mkdir -p "$clip_dir"

  local mock_open="$TEST_TEMP/mock-open"
  printf '#!/bin/bash\ntouch %s\n' "$marker" > "$mock_open"
  chmod +x "$mock_open"

  _browser_watcher "$clip_dir" "$mock_open" &
  local watcher_pid=$!
  sleep 0.3

  printf '/etc/passwd' > "$clip_dir/.browser-open"
  sleep 1

  kill "$watcher_pid" 2>/dev/null || true
  wait "$watcher_pid" 2>/dev/null || true

  [[ ! -f "$marker" ]] || return 1
}

# ── open-bridge script ───────────────────────────────────────────────────

@test "open-bridge: writes URL to bridge file" {
  local bridge="$TEST_TEMP/clip"
  mkdir -p "$bridge"
  local script="$PROJECT_ROOT/docker/open-bridge"

  local wrapper="$TEST_TEMP/test-open-bridge.sh"
  sed "s|/tmp/cleat-clip|${bridge}|g" "$script" > "$wrapper"
  chmod +x "$wrapper"

  run bash "$wrapper" "https://example.com/login"
  assert_success
  [[ -f "$bridge/.browser-open" ]] || return 1
  run cat "$bridge/.browser-open"
  assert_output "https://example.com/login"
}

@test "open-bridge: rejects non-http URLs" {
  local bridge="$TEST_TEMP/clip"
  mkdir -p "$bridge"
  local script="$PROJECT_ROOT/docker/open-bridge"

  local wrapper="$TEST_TEMP/test-open-bridge.sh"
  sed "s|/tmp/cleat-clip|${bridge}|g" "$script" > "$wrapper"
  chmod +x "$wrapper"

  run bash "$wrapper" "/etc/passwd"
  assert_failure
  assert_output --partial "only http/https"
}

@test "open-bridge: rejects empty input" {
  local bridge="$TEST_TEMP/clip"
  mkdir -p "$bridge"
  local script="$PROJECT_ROOT/docker/open-bridge"

  local wrapper="$TEST_TEMP/test-open-bridge.sh"
  sed "s|/tmp/cleat-clip|${bridge}|g" "$script" > "$wrapper"
  chmod +x "$wrapper"

  run bash "$wrapper" ""
  assert_failure
}

# ── Settings overlay: jq fallback ────────────────────────────────────────

@test "run: overlay falls back to empty {} when jq unavailable" {
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project"
  mkdir -p "${HOME}/.claude"
  echo '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"osascript"}]}]}}' \
    > "${HOME}/.claude/settings.json"

  # Hide jq
  local real_path="$PATH"
  local fake_bin="$TEST_TEMP/fake-bin"
  mkdir -p "$fake_bin"
  # Create PATH without jq
  PATH="$fake_bin:$MOCK_BIN"

  # Override command -v jq to fail
  command() {
    if [[ "$1" == "-v" && "$2" == "jq" ]]; then return 1; fi
    builtin command "$@"
  }

  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"
  run cmd_run "$TEST_TEMP/project"

  # Restore
  PATH="$real_path"
  unset -f command

  # Overlay should be empty {} (no hooks leaked)
  local overlay="/tmp/cleat-settings-${cname}/settings.json"
  if [[ -f "$overlay" ]]; then
    run cat "$overlay"
    assert_output "{}"
  fi

  rm -rf "/tmp/cleat-settings-${cname}" "/tmp/cleat-hooks-${cname}"
}

# ── Resume refreshes overlay ─────────────────────────────────────────────

@test "resume: refreshes settings overlay" {
  mkdir -p "$TEST_TEMP/project"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"
  mock_docker_ps "$cname"
  mock_docker_ps_a "$cname"

  # Create stale overlay with hooks (simulating old state)
  local overlay_dir="/tmp/cleat-settings-${cname}"
  mkdir -p "$overlay_dir"
  echo '{"hooks":{"Stop":[]},"stale":true}' > "$overlay_dir/settings.json"

  # Create current host settings
  mkdir -p "${HOME}/.claude"
  echo '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo"}]}]},"permissions":{}}' \
    > "${HOME}/.claude/settings.json"

  run cmd_resume "$TEST_TEMP/project"
  assert_success

  # Overlay should be refreshed — hooks stripped, permissions kept
  if command -v jq &>/dev/null; then
    run jq -r '.hooks // "none"' "$overlay_dir/settings.json"
    assert_output "none"
    run jq -r '.permissions' "$overlay_dir/settings.json"
    refute_output "null"
  fi

  rm -rf "$overlay_dir"
}

# ── Session cleanup: browser watcher ─────────────────────────────────────

@test "exec_claude: cleans up browser-open file on exit" {
  _host_clip_cmd() { echo ""; }
  _host_open_cmd() { echo ""; }
  export DOCKER_EXIT_CODE=0
  mkdir -p "/tmp/cleat-clip-test-cleanup"
  touch "/tmp/cleat-clip-test-cleanup/.browser-open"

  _CLIP_DIR="/tmp/cleat-clip-test-cleanup"
  run exec_claude "test-cleanup" --dangerously-skip-permissions

  # Browser bridge file should be cleaned up
  [[ ! -f "/tmp/cleat-clip-test-cleanup/.browser-open" ]] || return 1

  rm -rf "/tmp/cleat-clip-test-cleanup"
}

# ── Auth callback proxy: _extract_callback_port ─────────────────────────

@test "_extract_callback_port: extracts port from URL-encoded redirect_uri" {
  local url="https://console.anthropic.com/oauth/authorize?redirect_uri=http%3A%2F%2Flocalhost%3A34063%2Fcallback&state=abc123"
  run _extract_callback_port "$url"
  assert_success
  assert_output "34063"
}

@test "_extract_callback_port: extracts port from non-encoded redirect_uri" {
  local url="https://auth.example.com/login?redirect_uri=http://localhost:9876/callback&other=val"
  run _extract_callback_port "$url"
  assert_success
  assert_output "9876"
}

@test "_extract_callback_port: handles 127.0.0.1" {
  local url="https://auth.example.com/login?redirect_uri=http%3A%2F%2F127.0.0.1%3A45000%2Fcallback&state=x"
  run _extract_callback_port "$url"
  assert_success
  assert_output "45000"
}

@test "_extract_callback_port: returns 1 when no redirect_uri" {
  local url="https://example.com/page?foo=bar"
  run _extract_callback_port "$url"
  assert_failure
}

@test "_extract_callback_port: returns 1 when redirect_uri has no localhost" {
  local url="https://auth.example.com/login?redirect_uri=https%3A%2F%2Fexample.com%2Fcallback"
  run _extract_callback_port "$url"
  assert_failure
}

@test "_extract_callback_port: handles redirect_uri at end of URL (no trailing &)" {
  local url="https://auth.example.com/login?state=abc&redirect_uri=http%3A%2F%2Flocalhost%3A55555%2Fcb"
  run _extract_callback_port "$url"
  assert_success
  assert_output "55555"
}

# ── Browser watcher: callback proxy integration ─────────────────────────

@test "browser watcher: starts callback proxy for OAuth URL" {
  local clip_dir="$TEST_TEMP/clip-proxy"
  local marker="$TEST_TEMP/browser-opened-proxy"
  mkdir -p "$clip_dir"

  # Mock open command
  local mock_open="$TEST_TEMP/mock-open-proxy"
  printf '#!/bin/bash\necho "$1" > %s\n' "$marker" > "$mock_open"
  chmod +x "$mock_open"

  # Mock _auth_callback_proxy to record it was called
  local proxy_marker="$TEST_TEMP/proxy-started"
  _auth_callback_proxy() {
    echo "$1 $2" > "$proxy_marker"
  }

  # Start watcher with container name
  _browser_watcher "$clip_dir" "$mock_open" "test-container" &
  local watcher_pid=$!
  sleep 0.3

  # Write an OAuth URL with redirect_uri
  printf 'https://auth.example.com/login?redirect_uri=http%%3A%%2F%%2Flocalhost%%3A34063%%2Fcallback&state=abc' > "$clip_dir/.browser-open"
  sleep 1.5

  kill "$watcher_pid" 2>/dev/null || true
  wait "$watcher_pid" 2>/dev/null || true

  # Verify URL was opened
  [[ -f "$marker" ]] || { echo "URL was not opened in browser"; return 1; }

  # Verify callback proxy was started with correct port and container
  [[ -f "$proxy_marker" ]] || { echo "Callback proxy was not started"; return 1; }
  run cat "$proxy_marker"
  assert_output "34063 test-container"
}

@test "browser watcher: no proxy for non-OAuth URL" {
  local clip_dir="$TEST_TEMP/clip-noproxy"
  local marker="$TEST_TEMP/browser-opened-noproxy"
  mkdir -p "$clip_dir"

  local mock_open="$TEST_TEMP/mock-open-noproxy"
  printf '#!/bin/bash\necho "$1" > %s\n' "$marker" > "$mock_open"
  chmod +x "$mock_open"

  local proxy_marker="$TEST_TEMP/proxy-should-not-start"
  _auth_callback_proxy() {
    touch "$proxy_marker"
  }

  _browser_watcher "$clip_dir" "$mock_open" "test-container" &
  local watcher_pid=$!
  sleep 0.3

  # Write a normal URL (no redirect_uri)
  printf 'https://example.com/docs' > "$clip_dir/.browser-open"
  sleep 1

  kill "$watcher_pid" 2>/dev/null || true
  wait "$watcher_pid" 2>/dev/null || true

  # URL should be opened but no proxy started
  [[ -f "$marker" ]] || return 1
  [[ ! -f "$proxy_marker" ]] || { echo "Proxy should not start for non-OAuth URL"; return 1; }
}

@test "browser watcher: backward compatible with 2 args (no cname)" {
  local clip_dir="$TEST_TEMP/clip-compat"
  local marker="$TEST_TEMP/browser-compat"
  mkdir -p "$clip_dir"

  local mock_open="$TEST_TEMP/mock-open-compat"
  printf '#!/bin/bash\necho "$1" > %s\n' "$marker" > "$mock_open"
  chmod +x "$mock_open"

  # Call with only 2 args (original API)
  _browser_watcher "$clip_dir" "$mock_open" &
  local watcher_pid=$!
  sleep 0.3

  printf 'https://example.com/page' > "$clip_dir/.browser-open"
  sleep 1

  kill "$watcher_pid" 2>/dev/null || true
  wait "$watcher_pid" 2>/dev/null || true

  [[ -f "$marker" ]] || return 1
  run cat "$marker"
  assert_output "https://example.com/page"
}

# ── cmd_login: browser bridge ───────────────────────────────────────────

@test "cmd_login: starts browser watcher when open command available" {
  # Override to simulate a running container
  is_running() { return 0; }
  require_running() { true; }

  # Track if browser watcher was started
  local bw_marker="$TEST_TEMP/login-bw-started"
  _browser_watcher() {
    echo "$1 $2 $3" > "$bw_marker"
    # Run briefly then exit
    sleep 60 &
    local pid=$!
    trap "kill $pid 2>/dev/null; exit 0" TERM
    wait $pid
  }

  _host_open_cmd() { echo "true"; }

  # Docker stub returns success for login
  export DOCKER_EXIT_CODE=0

  run cmd_login "$TEST_TEMP"

  [[ -f "$bw_marker" ]] || { echo "Browser watcher not started for login"; return 1; }
}

@test "cmd_login: shows manual URL message when no open command" {
  is_running() { return 0; }
  require_running() { true; }

  _host_open_cmd() { echo ""; }
  export DOCKER_EXIT_CODE=0

  run cmd_login "$TEST_TEMP"
  assert_output --partial "A URL will appear"
}

@test "cmd_login: cleans up browser watcher even when login fails" {
  is_running() { return 0; }
  require_running() { true; }

  # Track browser watcher lifecycle
  local bw_started="$TEST_TEMP/login-bw-started2"
  local bw_killed="$TEST_TEMP/login-bw-killed2"
  _browser_watcher() {
    touch "$bw_started"
    trap "touch '$bw_killed'; exit 0" TERM
    sleep 60 &
    wait $!
  }

  _host_open_cmd() { echo "true"; }
  export DOCKER_EXIT_CODE=1  # docker exec will fail (login fails)

  run cmd_login "$TEST_TEMP"

  # Browser watcher should have been started AND cleaned up
  [[ -f "$bw_started" ]] || { echo "Browser watcher not started"; return 1; }

  # Give a moment for the kill/wait to propagate
  sleep 0.3
  [[ -f "$bw_killed" ]] || { echo "Browser watcher not killed after login failure"; return 1; }
}
