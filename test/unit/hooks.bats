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

# ── Hooks event mount ──────────────────────────────────────────────────

@test "run: mounts event forwarding directory when hooks enabled" {
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
  rmdir "/tmp/cleat-hooks-${cname}" 2>/dev/null || true
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

# ── Host connectivity ───────────────────────────────────────────────────

@test "run: adds --add-host when not Docker Desktop" {
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"
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
  _is_docker_desktop() { return 0; }

  run cmd_run "$TEST_TEMP/project"
  assert_success
  run assert_docker_run_lacks "$cname" "--add-host"
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

# ── _is_docker_desktop ──────────────────────────────────────────────────

@test "_is_docker_desktop: true when docker info shows Docker Desktop" {
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

# ── Settings overlay: hooks ON (forwarder) ──────────────────────────────

@test "run: overlay replaces hook commands with event forwarder when hooks ON" {
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project"

  # Create host settings with user hooks
  mkdir -p "${HOME}/.claude"
  cat > "${HOME}/.claude/settings.json" << 'EOF'
{"permissions":{"allow":["Bash(*)"]},"hooks":{"Stop":[{"hooks":[{"type":"command","command":"osascript -e 'display notification'"}]}]}}
EOF

  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"
  run cmd_run "$TEST_TEMP/project"
  assert_success

  # The overlay should have forwarder command, not the original
  local overlay="/tmp/cleat-settings-${cname}/settings.json"
  [[ -f "$overlay" ]] || return 1

  # Should keep permissions
  run jq -r '.permissions.allow[0]' "$overlay"
  assert_output "Bash(*)"

  # Should have hooks (not stripped) but with forwarder command
  run jq -r '.hooks.Stop[0].hooks[0].command' "$overlay"
  assert_output "cat >> /var/log/cleat/events.jsonl"

  # Forwarder hooks should be async
  run jq -r '.hooks.Stop[0].hooks[0].async' "$overlay"
  assert_output "true"

  rm -rf "/tmp/cleat-settings-${cname}" "/tmp/cleat-hooks-${cname}"
}

@test "run: overlay preserves matchers when replacing commands" {
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project"

  mkdir -p "${HOME}/.claude"
  cat > "${HOME}/.claude/settings.json" << 'EOF'
{"hooks":{"PostToolUse":[{"matcher":"Bash|Write","hooks":[{"type":"command","command":"my-linter"}]}]}}
EOF

  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"
  run cmd_run "$TEST_TEMP/project"
  assert_success

  local overlay="/tmp/cleat-settings-${cname}/settings.json"
  # Matcher should be preserved
  run jq -r '.hooks.PostToolUse[0].matcher' "$overlay"
  assert_output "Bash|Write"

  # Command should be replaced
  run jq -r '.hooks.PostToolUse[0].hooks[0].command' "$overlay"
  assert_output "cat >> /var/log/cleat/events.jsonl"

  rm -rf "/tmp/cleat-settings-${cname}" "/tmp/cleat-hooks-${cname}"
}

# ── Settings overlay: hooks OFF (strip) ─────────────────────────────────

@test "run: overlay strips hooks when hooks cap disabled" {
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project"
  cat > "$CLEAT_GLOBAL_CONFIG" << 'EOF'
[caps]
git
EOF

  mkdir -p "${HOME}/.claude"
  cat > "${HOME}/.claude/settings.json" << 'EOF'
{"permissions":{"allow":["Bash(*)"]},"hooks":{"Stop":[{"hooks":[{"type":"command","command":"osascript"}]}]}}
EOF

  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"
  run cmd_run "$TEST_TEMP/project"
  assert_success

  local overlay="/tmp/cleat-settings-${cname}/settings.json"
  [[ -f "$overlay" ]] || return 1

  run jq -r '.permissions.allow[0]' "$overlay"
  assert_output "Bash(*)"

  run jq -r '.hooks // "none"' "$overlay"
  assert_output "none"

  rm -rf "/tmp/cleat-settings-${cname}"
}

@test "run: overlay works when settings.json is empty" {
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project"

  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"
  run cmd_run "$TEST_TEMP/project"
  assert_success

  local overlay="/tmp/cleat-settings-${cname}/settings.json"
  [[ -f "$overlay" ]] || return 1
  run cat "$overlay"
  assert_output "{}"

  rm -rf "/tmp/cleat-settings-${cname}" "/tmp/cleat-hooks-${cname}"
}

@test "run: overlay falls back to empty {} when jq unavailable" {
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project"
  mkdir -p "${HOME}/.claude"
  echo '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"osascript"}]}]}}' \
    > "${HOME}/.claude/settings.json"

  local real_path="$PATH"
  local fake_bin="$TEST_TEMP/fake-bin"
  mkdir -p "$fake_bin"
  PATH="$fake_bin:$MOCK_BIN"
  command() {
    if [[ "$1" == "-v" && "$2" == "jq" ]]; then return 1; fi
    builtin command "$@"
  }

  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"
  run cmd_run "$TEST_TEMP/project"

  PATH="$real_path"
  unset -f command

  local overlay="/tmp/cleat-settings-${cname}/settings.json"
  if [[ -f "$overlay" ]]; then
    run cat "$overlay"
    assert_output "{}"
  fi

  rm -rf "/tmp/cleat-settings-${cname}" "/tmp/cleat-hooks-${cname}"
}

# ── Project-level hook overlay ──────────────────────────────────────────

@test "run: overlays project settings.json with forwarder when hooks ON" {
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project/.claude"
  cat > "$TEST_TEMP/project/.claude/settings.json" << 'EOF'
{"hooks":{"PostToolUse":[{"hooks":[{"type":"command","command":"my-project-hook"}]}]},"permissions":{"allow":["Read"]}}
EOF

  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"
  run cmd_run "$TEST_TEMP/project"
  assert_success

  # Project settings should be overlaid at /workspace/.claude/settings.json
  run assert_docker_run_has "$cname" "settings.json:/workspace/.claude/settings.json"
  assert_success

  # Overlay should contain forwarder command, not the original hook command
  local overlay="/tmp/cleat-settings-${cname}/project-settings.json"
  run jq -r '.hooks.PostToolUse[0].hooks[0].command' "$overlay"
  assert_output "cat >> /var/log/cleat/events.jsonl"

  # Non-hook fields should be preserved
  run jq -r '.permissions.allow[0]' "$overlay"
  assert_output "Read"

  rm -rf "/tmp/cleat-settings-${cname}" "/tmp/cleat-hooks-${cname}"
}

@test "run: always mounts project overlay even when no hooks yet" {
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project/.claude"
  echo '{"permissions":{"allow":["Read"]}}' > "$TEST_TEMP/project/.claude/settings.json"

  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"
  run cmd_run "$TEST_TEMP/project"
  assert_success

  # Overlay should be mounted even though file has no hooks
  run assert_docker_run_has "$cname" "settings.json:/workspace/.claude/settings.json"
  assert_success

  # Overlay should be a copy of the original (no hooks to replace)
  local overlay="/tmp/cleat-settings-${cname}/project-settings.json"
  run jq -r '.permissions.allow[0]' "$overlay"
  assert_output "Read"

  rm -rf "/tmp/cleat-settings-${cname}" "/tmp/cleat-hooks-${cname}"
}

@test "run: mounts empty overlay for missing project settings files" {
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project"
  # No .claude/ directory at all

  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"
  run cmd_run "$TEST_TEMP/project"
  assert_success

  # Both overlays should be mounted
  run assert_docker_run_has "$cname" "settings.json:/workspace/.claude/settings.json"
  assert_success
  run assert_docker_run_has "$cname" "settings.local.json:/workspace/.claude/settings.local.json"
  assert_success

  # Both should be empty JSON
  run cat "/tmp/cleat-settings-${cname}/project-settings.json"
  assert_output "{}"
  run cat "/tmp/cleat-settings-${cname}/project-settings.local.json"
  assert_output "{}"

  rm -rf "/tmp/cleat-settings-${cname}" "/tmp/cleat-hooks-${cname}"
}

@test "run: does not overlay project settings when hooks OFF" {
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project/.claude"
  cat > "$TEST_TEMP/project/.claude/settings.json" << 'EOF'
{"hooks":{"PostToolUse":[{"hooks":[{"type":"command","command":"my-hook"}]}]}}
EOF
  cat > "$CLEAT_GLOBAL_CONFIG" << 'EOF'
[caps]
git
EOF

  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"
  run cmd_run "$TEST_TEMP/project"
  assert_success

  # Should NOT mount project settings overlay
  run assert_docker_run_lacks "$cname" "/workspace/.claude/settings.json"
  assert_success

  rm -rf "/tmp/cleat-settings-${cname}"
}

# ── cmd_claude sets _RESOLVED_PROJECT for hooks ────────────────────────

@test "claude: sets _RESOLVED_PROJECT so project hooks are found" {
  mkdir -p "$TEST_TEMP/project/.claude"
  cat > "$TEST_TEMP/project/.claude/settings.json" << 'EOF'
{"hooks":{"PostToolUse":[{"hooks":[{"type":"command","command":"my-hook"}]}]}}
EOF
  mkdir -p "${HOME}/.claude"
  echo '{}' > "${HOME}/.claude/settings.json"

  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"
  mock_docker_ps "$cname"

  # Stub exec_claude so we don't hit real docker exec
  exec_claude() { return 0; }

  _RESOLVED_PROJECT=""
  cmd_claude "$TEST_TEMP/project"

  # _RESOLVED_PROJECT must point to the project so hooks bridge finds hooks
  [[ "$_RESOLVED_PROJECT" == "$TEST_TEMP/project" ]] || {
    echo "_RESOLVED_PROJECT='$_RESOLVED_PROJECT' expected '$TEST_TEMP/project'"
    return 1
  }
  # Verify project hooks are discoverable
  run _has_host_hooks
  assert_success
}

# ── cmd_claude refreshes project-level overlays ────────────────────────

@test "claude: refreshes project overlay when hooks added after creation" {
  mkdir -p "$TEST_TEMP/project/.claude"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"

  # Simulate overlay dir from original cmd_run (no hooks at creation time)
  local overlay_dir="/tmp/cleat-settings-${cname}"
  mkdir -p "$overlay_dir"
  echo '{}' > "$overlay_dir/settings.json"
  echo '{}' > "$overlay_dir/project-settings.json"
  echo '{}' > "$overlay_dir/project-settings.local.json"

  # User adds hooks after container was created
  cat > "$TEST_TEMP/project/.claude/settings.local.json" << 'EOF'
{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"osascript -e 'display notification'"}]}]}}
EOF

  mock_docker_ps "$cname"
  exec_claude() { return 0; }

  cmd_claude "$TEST_TEMP/project"

  # Overlay should now have forwarder
  run jq -r '.hooks.Stop[0].hooks[0].command' "$overlay_dir/project-settings.local.json"
  assert_output "cat >> /var/log/cleat/events.jsonl"

  rm -rf "$overlay_dir" "/tmp/cleat-hooks-${cname}"
}

# ── Resume refreshes project-level overlays ────────────────────────────

@test "resume: refreshes project-level settings overlay when hooks ON" {
  mkdir -p "$TEST_TEMP/project/.claude"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"

  # Simulate an existing overlay directory (created by original cmd_run)
  local overlay_dir="/tmp/cleat-settings-${cname}"
  mkdir -p "$overlay_dir"
  echo '{}' > "$overlay_dir/settings.json"

  # User adds hooks to project settings.local.json after container was created
  cat > "$TEST_TEMP/project/.claude/settings.local.json" << 'EOF'
{"hooks":{"PostToolUse":[{"hooks":[{"type":"command","command":"my-new-hook"}]}]}}
EOF

  mock_docker_ps "$cname"

  # Stub exec_claude so we don't hit real docker exec
  exec_claude() { return 0; }

  cmd_resume "$TEST_TEMP/project"

  # Project overlay should now exist with forwarder
  local project_overlay="$overlay_dir/project-settings.local.json"
  [[ -f "$project_overlay" ]] || {
    echo "Project overlay not created at $project_overlay"
    return 1
  }
  # Overlay should have forwarder command, not original
  run jq -r '.hooks.PostToolUse[0].hooks[0].command' "$project_overlay"
  assert_output "cat >> /var/log/cleat/events.jsonl"

  rm -rf "$overlay_dir" "/tmp/cleat-hooks-${cname}"
}

@test "resume: copies project settings as-is when hooks removed" {
  mkdir -p "$TEST_TEMP/project/.claude"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"

  # Simulate overlay dir with old forwarder
  local overlay_dir="/tmp/cleat-settings-${cname}"
  mkdir -p "$overlay_dir"
  echo '{}' > "$overlay_dir/settings.json"
  echo '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"cat >> /var/log/cleat/events.jsonl"}]}]}}' \
    > "$overlay_dir/project-settings.local.json"

  # User removed hooks, file now has only permissions
  echo '{"permissions":{"allow":["Read"]}}' > "$TEST_TEMP/project/.claude/settings.local.json"

  mock_docker_ps "$cname"
  exec_claude() { return 0; }

  cmd_resume "$TEST_TEMP/project"

  # Overlay should be a copy with no hooks
  run jq -r '.permissions.allow[0]' "$overlay_dir/project-settings.local.json"
  assert_output "Read"
  run jq -e '.hooks // empty | length > 0' "$overlay_dir/project-settings.local.json"
  assert_failure

  rm -rf "$overlay_dir" "/tmp/cleat-hooks-${cname}"
}

# ── Settings overlay mount ordering ─────────────────────────────────────

@test "run: settings overlay mounts on top of ~/.claude" {
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project"
  mkdir -p "${HOME}/.claude"
  echo '{}' > "${HOME}/.claude/settings.json"

  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"
  run cmd_run "$TEST_TEMP/project"
  assert_success

  run assert_docker_run_has "$cname" ".claude:/home/coder/.claude"
  assert_success
  run assert_docker_run_has "$cname" "settings.json:/home/coder/.claude/settings.json"
  assert_success

  rm -rf "/tmp/cleat-settings-${cname}" "/tmp/cleat-hooks-${cname}"
}

# ── --cap hooks session-only ────────────────────────────────────────────

@test "run: --cap hooks enables hooks for single session" {
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project"
  cat > "$CLEAT_GLOBAL_CONFIG" << 'EOF'
[caps]
git
EOF
  _CLI_CAPS=(hooks)
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"

  run cmd_run "$TEST_TEMP/project"
  assert_success
  run assert_docker_run_has "$cname" "/var/log/cleat"
  assert_success
}

# ── No CLEAT_NO_HOOKS env var (removed) ─────────────────────────────────

@test "run: does not pass CLEAT_NO_HOOKS env var" {
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"

  run cmd_run "$TEST_TEMP/project"
  assert_success
  run assert_docker_run_lacks "$cname" "CLEAT_NO_HOOKS"
  assert_success
}

@test "run: no CLEAT_NO_HOOKS even when hooks disabled" {
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
  run assert_docker_run_lacks "$cname" "CLEAT_NO_HOOKS"
  assert_success
}

# ── _cap_description ────────────────────────────────────────────────────

@test "cap_description: hooks describes host hook execution" {
  run _cap_description hooks
  assert_output --partial "hooks"
  assert_output --partial "host"
}

# ── config --list includes hooks ─────────────────────────────────────────

@test "config --list: shows hooks capability" {
  run cmd_config --list
  assert_output --partial "hooks"
}

# ── No capabilities at all ──────────────────────────────────────────────

@test "run: works with completely empty config (no caps)" {
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project"
  : > "$CLEAT_GLOBAL_CONFIG"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"

  run cmd_run "$TEST_TEMP/project"
  assert_success
  run assert_docker_run_lacks "$cname" "/var/log/cleat"
  assert_success
}

# ── cmd_rm cleanup ──────────────────────────────────────────────────────

@test "rm: cleans up hooks temp directory" {
  mkdir -p "$TEST_TEMP/project"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"
  mock_docker_ps "$cname"
  mock_docker_ps_a "$cname"

  local hooks_dir="/tmp/cleat-hooks-${cname}"
  mkdir -p "$hooks_dir"
  echo "test" > "$hooks_dir/events.jsonl"

  run cmd_rm "$TEST_TEMP/project"
  assert_success
  [[ ! -d "$hooks_dir" ]] || return 1
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

@test "_has_host_hooks: true when global settings.json has hooks" {
  mkdir -p "${HOME}/.claude"
  cat > "${HOME}/.claude/settings.json" << 'EOF'
{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo done"}]}]}}
EOF
  run _has_host_hooks
  assert_success
}

@test "_has_host_hooks: true when project settings.json has hooks" {
  mkdir -p "${HOME}/.claude"
  echo '{}' > "${HOME}/.claude/settings.json"
  mkdir -p "$TEST_TEMP/project/.claude"
  cat > "$TEST_TEMP/project/.claude/settings.json" << 'EOF'
{"hooks":{"PostToolUse":[{"hooks":[{"type":"command","command":"echo"}]}]}}
EOF
  _RESOLVED_PROJECT="$TEST_TEMP/project"
  run _has_host_hooks
  assert_success
}

@test "_has_host_hooks: true when project settings.local.json has hooks" {
  mkdir -p "${HOME}/.claude"
  echo '{}' > "${HOME}/.claude/settings.json"
  mkdir -p "$TEST_TEMP/project/.claude"
  cat > "$TEST_TEMP/project/.claude/settings.local.json" << 'EOF'
{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo"}]}]}}
EOF
  _RESOLVED_PROJECT="$TEST_TEMP/project"
  run _has_host_hooks
  assert_success
}

@test "_has_host_hooks: false when no settings have hooks" {
  mkdir -p "${HOME}/.claude"
  echo '{"permissions":{}}' > "${HOME}/.claude/settings.json"
  _RESOLVED_PROJECT="$TEST_TEMP/no-hooks"
  run _has_host_hooks
  assert_failure
}

@test "_has_host_hooks: false when settings.json is empty" {
  : > "${HOME}/.claude/settings.json" 2>/dev/null || true
  _RESOLVED_PROJECT="$TEST_TEMP/no-hooks"
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
  sleep 0.5
  [[ -f "$marker" ]] || return 1
}

@test "_execute_host_hooks: runs hooks from multiple settings files" {
  local global="$TEST_TEMP/global-settings.json"
  local project="$TEST_TEMP/project-settings.json"
  local marker1="$TEST_TEMP/global-hook-ran"
  local marker2="$TEST_TEMP/project-hook-ran"
  cat > "$global" << EOF
{"hooks":{"PostToolUse":[{"hooks":[{"type":"command","command":"touch $marker1"}]}]}}
EOF
  cat > "$project" << EOF
{"hooks":{"PostToolUse":[{"hooks":[{"type":"command","command":"touch $marker2"}]}]}}
EOF

  local event='{"hook_event_name":"PostToolUse","tool_name":"Bash"}'
  _execute_host_hooks "$event" "$global" "$project"
  sleep 0.5
  [[ -f "$marker1" ]] || { echo "global hook did not run"; return 1; }
  [[ -f "$marker2" ]] || { echo "project hook did not run"; return 1; }
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

  for pid in "${_HOOK_BRIDGE_CHILDREN[@]+"${_HOOK_BRIDGE_CHILDREN[@]}"}"; do
    run kill -0 "$pid"
    assert_failure
  done
}

# ── Resume refreshes overlay ─────────────────────────────────────────────

@test "resume: refreshes overlay with forwarder when hooks ON" {
  mkdir -p "$TEST_TEMP/project"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"
  mock_docker_ps "$cname"
  mock_docker_ps_a "$cname"

  local overlay_dir="/tmp/cleat-settings-${cname}"
  mkdir -p "$overlay_dir"
  echo '{"stale":true}' > "$overlay_dir/settings.json"

  mkdir -p "${HOME}/.claude"
  echo '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo"}]}]},"permissions":{}}' \
    > "${HOME}/.claude/settings.json"

  run cmd_resume "$TEST_TEMP/project"
  assert_success

  if command -v jq &>/dev/null; then
    # Should have hooks with forwarder, not stripped
    run jq -r '.hooks.Stop[0].hooks[0].command' "$overlay_dir/settings.json"
    assert_output "cat >> /var/log/cleat/events.jsonl"
  fi

  rm -rf "$overlay_dir"
}

@test "resume: refreshes overlay with hooks stripped when hooks OFF" {
  mkdir -p "$TEST_TEMP/project"
  cat > "$CLEAT_GLOBAL_CONFIG" << 'EOF'
[caps]
git
EOF
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"
  mock_docker_ps "$cname"
  mock_docker_ps_a "$cname"

  local overlay_dir="/tmp/cleat-settings-${cname}"
  mkdir -p "$overlay_dir"
  echo '{"stale":true}' > "$overlay_dir/settings.json"

  mkdir -p "${HOME}/.claude"
  echo '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo"}]}]},"permissions":{}}' \
    > "${HOME}/.claude/settings.json"

  run cmd_resume "$TEST_TEMP/project"
  assert_success

  if command -v jq &>/dev/null; then
    run jq -r '.hooks // "none"' "$overlay_dir/settings.json"
    assert_output "none"
  fi

  rm -rf "$overlay_dir"
}

# ── Regression: no entrypoint hook injection ─────────────────────────────

@test "entrypoint: does not inject hooks into project directory" {
  # The entrypoint should not create or modify .claude/settings.local.json
  local entrypoint="$PROJECT_ROOT/docker/entrypoint.sh"
  # Verify entrypoint has no reference to inject_hook_settings or cleat-hook-logger
  run grep -c "inject_hook_settings\|cleat-hook-logger" "$entrypoint"
  assert_output "0"
}

@test "entrypoint: does not reference CLEAT_NO_HOOKS" {
  local entrypoint="$PROJECT_ROOT/docker/entrypoint.sh"
  run grep -c "CLEAT_NO_HOOKS" "$entrypoint"
  assert_output "0"
}

# ── Regression: no cleat hooks command ───────────────────────────────────

@test "help: does not show hooks command" {
  run cmd_help
  refute_output --partial "View hook events"
  refute_output --partial "--follow"
  refute_output --partial "--clear"
}

@test "strict mode: cleat hooks shows unknown command" {
  run bash "$CLI" hooks 2>&1
  refute_output --partial "unbound variable"
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

  [[ ! -f "/tmp/cleat-clip-test-cleanup/.browser-open" ]] || return 1
  rm -rf "/tmp/cleat-clip-test-cleanup"
}

# ── Browser bridge ───────────────────────────────────────────────────────

@test "_host_open_cmd: returns open or xdg-open if available" {
  run _host_open_cmd
  assert_success
}

@test "browser watcher: opens URL when bridge file changes" {
  local clip_dir="$TEST_TEMP/clip"
  local marker="$TEST_TEMP/browser-opened"
  mkdir -p "$clip_dir"

  local mock_open="$TEST_TEMP/mock-open"
  cat > "$mock_open" << 'SCRIPT'
#!/bin/bash
echo "$1" > MARKER_PATH
SCRIPT
  sed -i "s|MARKER_PATH|$marker|" "$mock_open"
  chmod +x "$mock_open"

  _browser_watcher "$clip_dir" "$mock_open" &
  local watcher_pid=$!
  sleep 0.3

  printf 'https://example.com/auth' > "$clip_dir/.browser-open"
  sleep 1

  kill "$watcher_pid" 2>/dev/null || true
  wait "$watcher_pid" 2>/dev/null || true

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

# ── Auth callback proxy ──────────────────────────────────────────────────

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

  local mock_open="$TEST_TEMP/mock-open-proxy"
  printf '#!/bin/bash\necho "$1" > %s\n' "$marker" > "$mock_open"
  chmod +x "$mock_open"

  local proxy_marker="$TEST_TEMP/proxy-started"
  _auth_callback_proxy() {
    echo "$1 $2" > "$proxy_marker"
  }

  _browser_watcher "$clip_dir" "$mock_open" "test-container" &
  local watcher_pid=$!
  sleep 0.3

  printf 'https://auth.example.com/login?redirect_uri=http%%3A%%2F%%2Flocalhost%%3A34063%%2Fcallback&state=abc' > "$clip_dir/.browser-open"
  sleep 1.5

  kill "$watcher_pid" 2>/dev/null || true
  wait "$watcher_pid" 2>/dev/null || true

  [[ -f "$marker" ]] || { echo "URL was not opened in browser"; return 1; }
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

  printf 'https://example.com/docs' > "$clip_dir/.browser-open"
  sleep 1

  kill "$watcher_pid" 2>/dev/null || true
  wait "$watcher_pid" 2>/dev/null || true

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
  is_running() { return 0; }
  require_running() { true; }

  local bw_marker="$TEST_TEMP/login-bw-started"
  _browser_watcher() {
    echo "$1 $2 $3" > "$bw_marker"
    sleep 60 &
    local pid=$!
    trap "kill $pid 2>/dev/null; exit 0" TERM
    wait $pid
  }
  _host_open_cmd() { echo "true"; }
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

  local bw_started="$TEST_TEMP/login-bw-started2"
  local bw_killed="$TEST_TEMP/login-bw-killed2"
  _browser_watcher() {
    touch "$bw_started"
    trap "touch '$bw_killed'; exit 0" TERM
    sleep 60 &
    wait $!
  }
  _host_open_cmd() { echo "true"; }
  export DOCKER_EXIT_CODE=1

  run cmd_login "$TEST_TEMP"
  [[ -f "$bw_started" ]] || { echo "Browser watcher not started"; return 1; }
  sleep 0.3
  [[ -f "$bw_killed" ]] || { echo "Browser watcher not killed after login failure"; return 1; }
}
