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
  _resolve_config_drift() { true; }
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
  [[ -d "$CLEAT_RUN_DIR/${cname}/hooks" ]] || return 1
  rmdir "$CLEAT_RUN_DIR/${cname}/hooks" 2>/dev/null || true
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

@test "_is_docker_desktop: matches under set -o pipefail (no SIGPIPE false-negative), regression v0.16.2" {
  # The old `docker info | grep -q` form was SIGPIPE-fragile under `set -o
  # pipefail` (which the real binary runs): when grep -q matches it exits and
  # closes the pipe, the still-writing `docker info` dies of SIGPIPE (141), and
  # pipefail then reports the WHOLE pipeline as failed, even though it matched.
  # Under memory pressure `docker info` is slow with lots left to write when grep
  # bails, so the race tips to "failed" exactly when the Docker-Desktop-only VM
  # advisory needs to fire, the on-start "give Docker more memory" steps silently
  # vanished (observed on a real Mac, v0.16.1). The fix reads just the
  # OperatingSystem field via --format (no pipe).
  #
  # We encode the failure mode deterministically (real SIGPIPE delivery is a
  # timing race): the mock answers --format cleanly, but a PLAIN `docker info`
  # emits the matching OS line and then exits 141, exactly what a SIGPIPE'd
  # `docker info` does once a downstream grep -q closes the pipe. Under pipefail
  # the fixed (--format) code returns 0; the reverted (grep) code returns 141.
  local mock_dir="$TEST_TEMP/mock-docker-sigpipe"
  mkdir -p "$mock_dir"
  cat > "$mock_dir/docker" << 'SCRIPT'
#!/usr/bin/env bash
case "$*" in
  *--format*)
    # The field query the fixed code uses: clean success.
    echo "Docker Desktop"
    exit 0
    ;;
  info)
    # Plain `docker info` (the old grep path): emit the matching line, then exit
    # 141: what a SIGPIPE'd `docker info` does. pipefail surfaces this 141 even
    # though grep -q matched (exit 0).
    echo " Operating System: Docker Desktop"
    exit 141
    ;;
esac
exit 0
SCRIPT
  chmod +x "$mock_dir/docker"
  # Reproduce the real binary's strict mode for this call: source_cli strips it.
  set -o pipefail
  PATH="$mock_dir:$PATH" _is_docker_desktop
  local rc=$?
  set +o pipefail
  [[ "$rc" -eq 0 ]] || { echo "is_docker_desktop returned $rc under pipefail (SIGPIPE false-negative)"; return 1; }
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
  local overlay="$CLEAT_RUN_DIR/${cname}/settings/settings.json"
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

  rm -rf "$CLEAT_RUN_DIR/${cname}/settings" "$CLEAT_RUN_DIR/${cname}/hooks"
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

  local overlay="$CLEAT_RUN_DIR/${cname}/settings/settings.json"
  # Matcher should be preserved
  run jq -r '.hooks.PostToolUse[0].matcher' "$overlay"
  assert_output "Bash|Write"

  # Command should be replaced
  run jq -r '.hooks.PostToolUse[0].hooks[0].command' "$overlay"
  assert_output "cat >> /var/log/cleat/events.jsonl"

  rm -rf "$CLEAT_RUN_DIR/${cname}/settings" "$CLEAT_RUN_DIR/${cname}/hooks"
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

  local overlay="$CLEAT_RUN_DIR/${cname}/settings/settings.json"
  [[ -f "$overlay" ]] || return 1

  run jq -r '.permissions.allow[0]' "$overlay"
  assert_output "Bash(*)"

  run jq -r '.hooks // "none"' "$overlay"
  assert_output "none"

  rm -rf "$CLEAT_RUN_DIR/${cname}/settings"
}

@test "run: overlay works when settings.json is empty" {
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project"

  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"
  run cmd_run "$TEST_TEMP/project"
  assert_success

  local overlay="$CLEAT_RUN_DIR/${cname}/settings/settings.json"
  [[ -f "$overlay" ]] || return 1
  run cat "$overlay"
  assert_output "{}"

  rm -rf "$CLEAT_RUN_DIR/${cname}/settings" "$CLEAT_RUN_DIR/${cname}/hooks"
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

  local overlay="$CLEAT_RUN_DIR/${cname}/settings/settings.json"
  if [[ -f "$overlay" ]]; then
    run cat "$overlay"
    assert_output "{}"
  fi

  rm -rf "$CLEAT_RUN_DIR/${cname}/settings" "$CLEAT_RUN_DIR/${cname}/hooks"
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
  local overlay="$CLEAT_RUN_DIR/${cname}/settings/project-settings.json"
  run jq -r '.hooks.PostToolUse[0].hooks[0].command' "$overlay"
  assert_output "cat >> /var/log/cleat/events.jsonl"

  # Non-hook fields should be preserved
  run jq -r '.permissions.allow[0]' "$overlay"
  assert_output "Read"

  rm -rf "$CLEAT_RUN_DIR/${cname}/settings" "$CLEAT_RUN_DIR/${cname}/hooks"
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
  local overlay="$CLEAT_RUN_DIR/${cname}/settings/project-settings.json"
  run jq -r '.permissions.allow[0]' "$overlay"
  assert_output "Read"

  rm -rf "$CLEAT_RUN_DIR/${cname}/settings" "$CLEAT_RUN_DIR/${cname}/hooks"
}

@test "run: skips project overlay for files that don't exist on host" {
  # Regression: writing empty {} and mounting for missing files fails on
  # macOS Docker Desktop virtiofs (can't create target file at bind-mount
  # target inside another bind mount). Only mount files that exist.
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project/.claude"
  # .claude/ exists but neither settings.json nor settings.local.json

  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"
  run cmd_run "$TEST_TEMP/project"
  assert_success

  # Should NOT mount overlays for missing files
  run assert_docker_run_lacks "$cname" "/workspace/.claude/settings.json"
  assert_success
  run assert_docker_run_lacks "$cname" "/workspace/.claude/settings.local.json"
  assert_success

  # Overlay files should not be created for missing host files
  [[ ! -f "$CLEAT_RUN_DIR/${cname}/settings/project-settings.json" ]] || {
    echo "project-settings.json overlay should not exist for missing host file"
    return 1
  }

  rm -rf "$CLEAT_RUN_DIR/${cname}/settings" "$CLEAT_RUN_DIR/${cname}/hooks"
}

@test "run: mounts only existing overlay files when one of two exists" {
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project/.claude"
  # Only settings.local.json exists, settings.json does not
  echo '{"permissions":{"allow":["Read"]}}' > "$TEST_TEMP/project/.claude/settings.local.json"

  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"
  run cmd_run "$TEST_TEMP/project"
  assert_success

  # Existing file is mounted
  run assert_docker_run_has "$cname" "settings.local.json:/workspace/.claude/settings.local.json"
  assert_success
  # Missing file is not mounted
  run assert_docker_run_lacks "$cname" "/workspace/.claude/settings.json"
  assert_success

  rm -rf "$CLEAT_RUN_DIR/${cname}/settings" "$CLEAT_RUN_DIR/${cname}/hooks"
}

@test "run: skips project overlay when no .claude/ directory" {
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project"
  # No .claude/ directory at all

  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"
  run cmd_run "$TEST_TEMP/project"
  assert_success

  # Should NOT mount project overlays (would create .claude/ as root on host)
  run assert_docker_run_lacks "$cname" "/workspace/.claude/settings.json"
  assert_success
  run assert_docker_run_lacks "$cname" "/workspace/.claude/settings.local.json"
  assert_success

  rm -rf "$CLEAT_RUN_DIR/${cname}/settings" "$CLEAT_RUN_DIR/${cname}/hooks"
}

@test "run: strips hooks from project settings overlay when hooks OFF" {
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project/.claude"
  cat > "$TEST_TEMP/project/.claude/settings.json" << 'EOF'
{"hooks":{"PostToolUse":[{"hooks":[{"type":"command","command":"my-hook"}]}]},"permissions":{"allow":["Read"]}}
EOF
  cat > "$CLEAT_GLOBAL_CONFIG" << 'EOF'
[caps]
git
EOF

  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"
  run cmd_run "$TEST_TEMP/project"
  assert_success

  # Project settings overlay SHOULD be mounted (to strip hooks)
  run assert_docker_run_has "$cname" "/workspace/.claude/settings.json"
  assert_success

  # Overlay must have hooks stripped but preserve other fields
  local overlay="$CLEAT_RUN_DIR/${cname}/settings/project-settings.json"
  if command -v jq &>/dev/null; then
    run jq -e '.hooks // empty | length > 0' "$overlay"
    assert_failure  # hooks should be gone
    run jq -r '.permissions.allow[0]' "$overlay"
    assert_output "Read"
  fi

  rm -rf "$CLEAT_RUN_DIR/${cname}/settings"
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
  # Retargeted: _RESOLVED_PROJECT still has to be set (the project overlay and
  # the project-hook advisory both read it), but it no longer decides whether
  # the bridge starts. Hook COMMANDS come from the host settings file alone,
  # because the two project files live inside the read-write /workspace mount.
  # What is still proven here is that the project resolves, which is what this
  # test was written for.
  mkdir -p "${HOME}/.claude"
  printf '{"hooks":{"PostToolUse":[{"hooks":[{"type":"command","command":"echo"}]}]}}\n' > "${HOME}/.claude/settings.json"
  run _has_host_hooks
  assert_success
}

# ── cmd_claude refreshes project-level overlays ────────────────────────

@test "claude: refreshes project overlay when hooks added after creation" {
  mkdir -p "$TEST_TEMP/project/.claude"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"

  # Simulate overlay dir from original cmd_run (no hooks at creation time)
  local overlay_dir="$CLEAT_RUN_DIR/${cname}/settings"
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

  rm -rf "$overlay_dir" "$CLEAT_RUN_DIR/${cname}/hooks"
}

# ── Resume refreshes project-level overlays ────────────────────────────

@test "resume: refreshes project-level settings overlay when hooks ON" {
  mkdir -p "$TEST_TEMP/project/.claude"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"

  # Simulate an existing overlay directory (created by original cmd_run)
  local overlay_dir="$CLEAT_RUN_DIR/${cname}/settings"
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

  rm -rf "$overlay_dir" "$CLEAT_RUN_DIR/${cname}/hooks"
}

@test "resume: copies project settings as-is when hooks removed" {
  mkdir -p "$TEST_TEMP/project/.claude"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"

  # Simulate overlay dir with old forwarder
  local overlay_dir="$CLEAT_RUN_DIR/${cname}/settings"
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

  rm -rf "$overlay_dir" "$CLEAT_RUN_DIR/${cname}/hooks"
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

  rm -rf "$CLEAT_RUN_DIR/${cname}/settings" "$CLEAT_RUN_DIR/${cname}/hooks"
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

@test "cap_description: hooks names the host settings file and not project hooks" {
  # The bridge runs commands from ~/.claude/settings.json alone. The two project
  # files sit inside the read-write /workspace mount and never supply a host
  # command, so a description promising "(global + project)" tells the user a
  # project hook will run on their host when it will not.
  run _cap_description hooks
  assert_output --partial "hooks"
  assert_output --partial "host"
  assert_output --partial "~/.claude/settings.json"
  refute_output --partial "project"
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

  local hooks_dir="$CLEAT_RUN_DIR/${cname}/hooks"
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

  local settings_dir="$CLEAT_RUN_DIR/${cname}/settings"
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

@test "_has_host_hooks: FALSE when only a project settings.json has hooks" {
  # Inverted, deliberately, and this is the escalation the inversion closes:
  # both project files sit inside the read-write /workspace mount, so a command
  # read from one is a command the box can write. Verified in the spec by
  # running the old function: event one ran the user's own hook, the file was
  # rewritten the way a box writes through /workspace, and event two executed
  # the rewritten command on the HOST.
  mkdir -p "${HOME}/.claude"
  echo '{}' > "${HOME}/.claude/settings.json"
  mkdir -p "$TEST_TEMP/project/.claude"
  cat > "$TEST_TEMP/project/.claude/settings.json" << 'EOF'
{"hooks":{"PostToolUse":[{"hooks":[{"type":"command","command":"echo"}]}]}}
EOF
  _RESOLVED_PROJECT="$TEST_TEMP/project"
  run _has_host_hooks
  assert_failure
  # And it is named rather than ignored in silence.
  run _hook_project_files_with_hooks
  assert_output --partial ".claude/settings.json"
}

@test "_has_host_hooks: FALSE when only a project settings.local.json has hooks" {
  # The sharper half: settings.local.json is a file Claude Code ITSELF writes
  # during ordinary operation, which is why this is split by origin rather than
  # gated by a consent prompt. See concept/16.
  mkdir -p "${HOME}/.claude"
  echo '{}' > "${HOME}/.claude/settings.json"
  mkdir -p "$TEST_TEMP/project/.claude"
  cat > "$TEST_TEMP/project/.claude/settings.local.json" << 'EOF'
{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo"}]}]}}
EOF
  _RESOLVED_PROJECT="$TEST_TEMP/project"
  run _has_host_hooks
  assert_failure
  run _hook_project_files_with_hooks
  assert_output --partial ".claude/settings.local.json"
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

@test "_hook_bridge_watcher: skips pre-existing events in log file" {
  mkdir -p "$TEST_TEMP/hooks"
  local hooks_file="$TEST_TEMP/hooks/events.jsonl"
  local processed="$TEST_TEMP/processed"

  # Pre-existing events from a previous session
  echo '{"hook_event_name":"Stop","_cleat_ts":"old1"}' > "$hooks_file"
  echo '{"hook_event_name":"Stop","_cleat_ts":"old2"}' >> "$hooks_file"

  # Override execution to log which events are processed
  _execute_host_hook_bg() { echo "$1" >> "$processed"; }

  # Provide settings files for the watcher
  _RESOLVED_PROJECT="$TEST_TEMP"
  mkdir -p "${HOME}/.claude"
  echo '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"true"}]}]}}' \
    > "${HOME}/.claude/settings.json"

  # Start watcher in background
  _hook_bridge_watcher "$hooks_file" &
  local pid=$!
  sleep 0.3

  # Append a new event
  echo '{"hook_event_name":"Stop","_cleat_ts":"new1"}' >> "$hooks_file"
  sleep 1

  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null || true

  # New event should have been processed
  [[ -f "$processed" ]] || { echo "No events processed at all"; return 1; }
  grep -q "new1" "$processed" || { echo "New event not processed"; return 1; }

  # Old events must NOT have been processed
  if grep -q "old" "$processed"; then
    echo "Old events replayed (regression)"; return 1
  fi
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

# A PATH holding only the named tools, so a test can take timeout(1) away the
# way a stock macOS does. Anything a test needs by name must be listed.
_hk_tool_farm() {
  local farm="$1" t p; shift
  mkdir -p "$farm"
  for t in "$@"; do
    p="$(command -v "$t" 2>/dev/null)" || continue
    ln -sf "$p" "$farm/$t"
  done
}

@test "_execute_host_hooks: the per-event bound holds on a host with no timeout(1)" {
  # A stock macOS ships no timeout(1), and the hook ran bare there, so a hook
  # given 2s ran for as long as it liked. perl's alarm is the fallback. The
  # hook never exits on its own, so only the bound can end it in time.
  command -v jq >/dev/null 2>&1 || skip "the bridge needs jq on the host"
  local farm="$TEST_TEMP/notimeout"
  _hk_tool_farm "$farm" bash jq grep touch sleep perl
  [ -x "$farm/perl" ] || skip "perl is not on this host"
  local settings="$TEST_TEMP/host-settings.json" marker="$TEST_TEMP/bounded-hook-started"
  cat > "$settings" << EOF
{"hooks":{"PreToolUse":[{"hooks":[{"type":"command","command":"touch $marker; exec sleep 15"}]}]}}
EOF
  _hook_timeout_for() { printf '2'; }
  local t0=$SECONDS
  PATH="$farm" _execute_host_hooks '{"hook_event_name":"PreToolUse","tool_name":"Bash"}' "$settings" 3>&-
  local took=$(( SECONDS - t0 ))
  [ -f "$marker" ] || { echo "the hook never ran"; return 1; }
  [ "$took" -le 9 ] || { echo "a hook bounded at 2s ran for ${took}s"; return 1; }
}

@test "_execute_host_hooks: the bound falls back to gtimeout when there is no timeout(1) or perl" {
  # Homebrew's coreutils installs timeout(1) as gtimeout. The stand-in here
  # records that it was chosen and bounds with perl by absolute path, so the
  # PATH the helper searches has neither timeout nor perl on it.
  command -v jq >/dev/null 2>&1 || skip "the bridge needs jq on the host"
  local real_perl; real_perl="$(command -v perl 2>/dev/null)" || skip "perl is not on this host"
  local farm="$TEST_TEMP/gtimeoutonly"
  _hk_tool_farm "$farm" bash jq grep touch sleep
  cat > "$farm/gtimeout" << EOF
#!$(command -v bash)
: > "$TEST_TEMP/gtimeout.used"
exec "$real_perl" -e 'alarm shift @ARGV; exec { \$ARGV[0] } @ARGV or exit 127' "\$@"
EOF
  chmod +x "$farm/gtimeout"
  local settings="$TEST_TEMP/host-settings.json" marker="$TEST_TEMP/bounded-hook-started"
  cat > "$settings" << EOF
{"hooks":{"PreToolUse":[{"hooks":[{"type":"command","command":"touch $marker; exec sleep 15"}]}]}}
EOF
  _hook_timeout_for() { printf '2'; }
  local t0=$SECONDS
  PATH="$farm" _execute_host_hooks '{"hook_event_name":"PreToolUse","tool_name":"Bash"}' "$settings" 3>&-
  local took=$(( SECONDS - t0 ))
  [ -f "$marker" ] || { echo "the hook never ran"; return 1; }
  [ -f "$TEST_TEMP/gtimeout.used" ] || { echo "gtimeout was not chosen"; return 1; }
  [ "$took" -le 9 ] || { echo "a hook bounded at 2s ran for ${took}s"; return 1; }
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

@test "_hook_bridge_cleanup: kills all tracked children and clears the list" {
  # Test the function's CONTRACT: it signals every tracked PID and empties the
  # tracking array, not kernel reaping timing. The old version spawned real
  # `sleep`s, disowned them, then asserted they were gone; but disowned children
  # become zombies that `kill -0` reports as alive until the kernel reaps them,
  # and `_hook_bridge_cleanup`'s own `wait` can't reap a disowned (non-job) PID.
  # Under full-suite load that race flaked. Recording kill targets is
  # deterministic and load-independent.
  local _killed="$TEST_TEMP/killed.log"; : > "$_killed"
  # Override the builtin to record signals instead of sending them. cleanup's
  # subsequent `wait <fake-pid>` is a fast no-op ("not a child").
  kill() { printf '%s\n' "$*" >> "$_killed"; }

  _HOOK_BRIDGE_CHILDREN=(4242 4243)
  _hook_bridge_cleanup

  grep -q '4242' "$_killed" || { echo "pid1 was not signalled"; return 1; }
  grep -q '4243' "$_killed" || { echo "pid2 was not signalled"; return 1; }
  [[ ${#_HOOK_BRIDGE_CHILDREN[@]} -eq 0 ]] || return 1
}

# ── Resume refreshes overlay ─────────────────────────────────────────────

@test "resume: refreshes overlay with forwarder when hooks ON" {
  mkdir -p "$TEST_TEMP/project"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"
  mock_docker_ps "$cname"
  mock_docker_ps_a "$cname"

  local overlay_dir="$CLEAT_RUN_DIR/${cname}/settings"
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

  local overlay_dir="$CLEAT_RUN_DIR/${cname}/settings"
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

@test "exec_claude: cleans up a STALE browser-open file on exit" {
  _host_clip_cmd() { echo ""; }
  _host_open_cmd() { echo ""; }
  export DOCKER_EXIT_CODE=0
  mkdir -p "$CLEAT_RUN_DIR/test-cleanup/clip"
  touch "$CLEAT_RUN_DIR/test-cleanup/clip/.browser-open"
  # -t is the portable form: GNU touch has -d, BSD touch does not.
  touch -t 202001010000 "$CLEAT_RUN_DIR/test-cleanup/clip/.browser-open"

  _CLIP_DIR="$CLEAT_RUN_DIR/test-cleanup/clip"
  run exec_claude "test-cleanup" --dangerously-skip-permissions

  [[ ! -f "$CLEAT_RUN_DIR/test-cleanup/clip/.browser-open" ]] || return 1
  rm -rf "$CLEAT_RUN_DIR/test-cleanup/clip"
}

@test "exec_claude: teardown keeps a FRESH browser-open file for a sibling session" {
  # Teardown used to rm the bridge file unconditionally, which swallowed a URL
  # a CONCURRENT session had just written and stranded that login. Startup was
  # age-gated for exactly this reason; teardown now matches it.
  _host_clip_cmd() { echo ""; }
  _host_open_cmd() { echo ""; }
  export DOCKER_EXIT_CODE=0
  mkdir -p "$CLEAT_RUN_DIR/test-cleanup2/clip"
  printf '%s' "https://claude.ai/oauth?redirect_uri=x" > "$CLEAT_RUN_DIR/test-cleanup2/clip/.browser-open"
  # A live SIBLING session: its .watcher.<pid> marker survives the dead-marker
  # sweep only while that pid is alive, so back it with a real process.
  sleep 30 &
  local sib=$!
  touch "$CLEAT_RUN_DIR/test-cleanup2/clip/.watcher.$sib"

  _CLIP_DIR="$CLEAT_RUN_DIR/test-cleanup2/clip"
  run exec_claude "test-cleanup2" --dangerously-skip-permissions
  kill "$sib" 2>/dev/null || true; wait "$sib" 2>/dev/null || true

  [[ -f "$CLEAT_RUN_DIR/test-cleanup2/clip/.browser-open" ]] || return 1
  rm -rf "$CLEAT_RUN_DIR/test-cleanup2/clip"
}

@test "exec_claude: a solo session's teardown removes even a fresh browser-open" {
  # With no live sibling there is nobody left to claim it, and leaving it
  # behind would hand it to the NEXT session on this box, which would open the
  # previous session's URL. So it goes unconditionally, as it always did.
  _host_clip_cmd() { echo ""; }
  _host_open_cmd() { echo ""; }
  export DOCKER_EXIT_CODE=0
  mkdir -p "$CLEAT_RUN_DIR/test-cleanup4/clip"
  printf '%s' "https://claude.ai/oauth?redirect_uri=x" > "$CLEAT_RUN_DIR/test-cleanup4/clip/.browser-open"

  _CLIP_DIR="$CLEAT_RUN_DIR/test-cleanup4/clip"
  run exec_claude "test-cleanup4" --dangerously-skip-permissions

  [[ ! -e "$CLEAT_RUN_DIR/test-cleanup4/clip/.browser-open" ]] || return 1
  rm -rf "$CLEAT_RUN_DIR/test-cleanup4/clip"
}

@test "exec_claude: teardown drops a SYMLINKED browser-open regardless of age" {
  _host_clip_cmd() { echo ""; }
  _host_open_cmd() { echo ""; }
  export DOCKER_EXIT_CODE=0
  mkdir -p "$CLEAT_RUN_DIR/test-cleanup3/clip"
  printf 'keep me\n' > "$TEST_TEMP/link-target"
  ln -s "$TEST_TEMP/link-target" "$CLEAT_RUN_DIR/test-cleanup3/clip/.browser-open"

  _CLIP_DIR="$CLEAT_RUN_DIR/test-cleanup3/clip"
  run exec_claude "test-cleanup3" --dangerously-skip-permissions

  [ ! -L "$CLEAT_RUN_DIR/test-cleanup3/clip/.browser-open" ] || return 1
  [ -f "$TEST_TEMP/link-target" ] || return 1          # target untouched
  rm -rf "$CLEAT_RUN_DIR/test-cleanup3/clip"
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
  sed -i.bak "s|MARKER_PATH|$marker|" "$mock_open" && rm -f "$mock_open.bak"
  chmod +x "$mock_open"

  _browser_watcher "$clip_dir" "$mock_open" &
  local watcher_pid=$!
  sleep 0.3

  # Retargeted for the browser destination gate: the fixture host moved onto
  # the shipped allowlist. What this test protects is unchanged. An origin the
  # gate refuses can never reach the opener, so the old fixture would have made
  # the assertion pass for the wrong reason.
  printf 'https://claude.ai/oauth/authorize?redirect_uri=https%%3A%%2F%%2Fconsole.anthropic.com%%2Fcb' > "$clip_dir/.browser-open"
  sleep 1

  kill "$watcher_pid" 2>/dev/null || true
  wait "$watcher_pid" 2>/dev/null || true

  [[ -f "$marker" ]] || return 1
  run cat "$marker"
  assert_output "https://claude.ai/oauth/authorize?redirect_uri=https%3A%2F%2Fconsole.anthropic.com%2Fcb"
}

@test "browser watcher: skips pre-existing URL from previous session" {
  local clip_dir="$TEST_TEMP/clip"
  local marker="$TEST_TEMP/browser-should-not-open-old"
  mkdir -p "$clip_dir"

  # Simulate a leftover URL from a previous session. A real one is minutes to
  # days old, and the startup sweep is age-gated (a FRESH file is a live URL a
  # sibling watcher is about to claim, see browser_bridge.bats), so the
  # leftover must be demonstrably stale to be swept.
  # Retargeted for the browser destination gate: the fixture host moved onto
  # the shipped allowlist. What this test protects is unchanged. An origin the
  # gate refuses can never reach the opener, so the old fixture would have made
  # the assertion pass for the wrong reason.
  printf 'https://claude.ai/old?redirect_uri=https%%3A%%2F%%2Fconsole.anthropic.com%%2Fcb' > "$clip_dir/.browser-open"
  touch -t 202001010000 "$clip_dir/.browser-open"

  local mock_open="$TEST_TEMP/mock-open-old"
  cat > "$mock_open" << 'SCRIPT'
#!/bin/bash
echo "$1" >> MARKER_PATH
SCRIPT
  sed -i.bak "s|MARKER_PATH|$marker|" "$mock_open" && rm -f "$mock_open.bak"
  chmod +x "$mock_open"

  _browser_watcher "$clip_dir" "$mock_open" &
  local watcher_pid=$!
  sleep 1

  # Write a new URL (touch to ensure timestamp changes)
  # Retargeted for the browser destination gate: the fixture host moved onto
  # the shipped allowlist. What this test protects is unchanged. An origin the
  # gate refuses can never reach the opener, so the old fixture would have made
  # the assertion pass for the wrong reason.
  printf 'https://claude.ai/new?redirect_uri=https%%3A%%2F%%2Fconsole.anthropic.com%%2Fcb' > "$clip_dir/.browser-open"
  touch "$clip_dir/.browser-open"
  sleep 1.5

  kill "$watcher_pid" 2>/dev/null || true
  wait "$watcher_pid" 2>/dev/null || true

  # New URL should have been opened
  [[ -f "$marker" ]] || { echo "No URLs opened at all"; return 1; }
  grep -q "claude.ai/new" "$marker" || { echo "New URL not opened"; return 1; }

  # Old URL should NOT have been opened
  if grep -q "old-session" "$marker"; then
    echo "Old URL was replayed (regression)"; return 1
  fi
}

@test "browser watcher: opens new URL even when written in same second as stale file" {
  local clip_dir="$TEST_TEMP/clip"
  local marker="$TEST_TEMP/browser-same-second"
  mkdir -p "$clip_dir"

  # Simulate a leftover URL from a previous session (stale mtime: the startup
  # sweep is age-gated and only removes a demonstrably old file)
  # Retargeted for the browser destination gate: the fixture host moved onto
  # the shipped allowlist. What this test protects is unchanged. An origin the
  # gate refuses can never reach the opener, so the old fixture would have made
  # the assertion pass for the wrong reason.
  printf 'https://claude.ai/stale?redirect_uri=https%%3A%%2F%%2Fconsole.anthropic.com%%2Fcb' > "$clip_dir/.browser-open"
  touch -t 202001010000 "$clip_dir/.browser-open"

  local mock_open="$TEST_TEMP/mock-open-same-second"
  cat > "$mock_open" << 'SCRIPT'
#!/bin/bash
echo "$1" >> MARKER_PATH
SCRIPT
  sed -i.bak "s|MARKER_PATH|$marker|" "$mock_open" && rm -f "$mock_open.bak"
  chmod +x "$mock_open"

  # Start watcher: the stale file exists at startup
  _browser_watcher "$clip_dir" "$mock_open" &
  local watcher_pid=$!
  sleep 0.3

  # Write a new URL immediately (no touch to force timestamp change)
  # Retargeted for the browser destination gate: the fixture host moved onto
  # the shipped allowlist. What this test protects is unchanged. An origin the
  # gate refuses can never reach the opener, so the old fixture would have made
  # the assertion pass for the wrong reason.
  printf 'https://claude.ai/fresh?redirect_uri=https%%3A%%2F%%2Fconsole.anthropic.com%%2Fcb' > "$clip_dir/.browser-open"
  sleep 1.5

  kill "$watcher_pid" 2>/dev/null || true
  wait "$watcher_pid" 2>/dev/null || true

  # New URL must have been opened (regression: same-second write was missed)
  [[ -f "$marker" ]] || { echo "URL not opened, same-second regression"; return 1; }
  run cat "$marker"
  assert_output --partial "claude.ai/fresh"

  # Stale URL must NOT have been opened
  if grep -q "stale.example.com" "$marker"; then
    echo "Stale URL was replayed"; return 1
  fi
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

  # Feed /dev/null on fd0: the shim only reads stdin when fd0 is not a tty, but
  # be explicit so this test can never block when run directly in a terminal.
  run bash "$wrapper" "" </dev/null
  assert_failure
}

@test "open-bridge: forwards a URL piped on stdin (non-tty)" {
  local bridge="$TEST_TEMP/clip"
  mkdir -p "$bridge"
  local script="$PROJECT_ROOT/docker/open-bridge"

  local wrapper="$TEST_TEMP/test-open-bridge.sh"
  sed "s|/tmp/cleat-clip|${bridge}|g" "$script" > "$wrapper"
  chmod +x "$wrapper"

  # No URL arg → the shim reads it from stdin because the pipe is not a tty.
  run bash -c "printf '%s' 'https://example.com/piped' | '$wrapper'"
  assert_success
  [[ -f "$bridge/.browser-open" ]] || return 1
  run cat "$bridge/.browser-open"
  assert_output "https://example.com/piped"
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

# The port here is chosen by the CAGED side and decides which HOST port the
# callback proxy binds, so the parser is a trust boundary, not a convenience.

@test "_extract_callback_port: rejects a redirect_uri whose host is not loopback" {
  # `*localhost:*` matched a substring ANYWHERE in the value, so this made the
  # host bind 9999 for a destination the box picked.
  local url="https://x.example/a?redirect_uri=http%3A%2F%2Fevil.example%2F%3Fnext%3Dlocalhost%3A9999"
  run _extract_callback_port "$url"
  assert_failure
}

@test "_extract_callback_port: rejects a userinfo host that hides the real destination" {
  local url="https://x.example/a?redirect_uri=http%3A%2F%2Flocalhost%3A9999%40evil.example%2F"
  run _extract_callback_port "$url"
  assert_failure
}

@test "_extract_callback_port: rejects a hostname that merely starts with localhost" {
  local url="https://x.example/a?redirect_uri=http%3A%2F%2Flocalhost.evil.example%3A9999%2Fcb"
  run _extract_callback_port "$url"
  assert_failure
}

@test "_extract_callback_port: rejects port 0" {
  run _extract_callback_port "https://x/a?redirect_uri=http%3A%2F%2Flocalhost%3A0%2Fcb"
  assert_failure
}

@test "_extract_callback_port: rejects a privileged port" {
  run _extract_callback_port "https://x/a?redirect_uri=http%3A%2F%2Flocalhost%3A80%2Fcb"
  assert_failure
}

@test "_extract_callback_port: rejects a port above 65535" {
  # socat truncates modulo 65536 and python3 raises OverflowError, so the two
  # backends disagree about what this even means.
  run _extract_callback_port "https://x/a?redirect_uri=http%3A%2F%2Flocalhost%3A65536%2Fcb"
  assert_failure
}

@test "_extract_callback_port: rejects a leading-zero port" {
  # 04000 is deliberate: bash reads a leading zero as OCTAL, and 0080 is
  # invalid octal so it errors out and gets rejected anyway. 04000 parses
  # cleanly to 2048 and lands in range, so only the explicit arm stops it.
  run _extract_callback_port "https://x/a?redirect_uri=http%3A%2F%2Flocalhost%3A04000%2Fcb"
  assert_failure
  run _extract_callback_port "https://x/a?redirect_uri=http%3A%2F%2Flocalhost%3A0080%2Fcb"
  assert_failure
}

@test "_extract_callback_port: rejects an oversized URL" {
  local pad; pad="$(head -c 5000 /dev/zero | tr "\0" "A")"
  run _extract_callback_port "https://x/a?redirect_uri=http%3A%2F%2Flocalhost%3A5555%2Fcb&pad=$pad"
  assert_failure
}

@test "_extract_callback_port: accepts LOCALHOST case-insensitively" {
  run _extract_callback_port "https://x/a?redirect_uri=http%3A%2F%2FLOCALHOST%3A5555%2Fcb"
  assert_success
  assert_output "5555"
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
  # $4 is the readiness marker the real backends touch on a successful bind.
  # Without it the watcher defers rather than opening, which is the correct new
  # behaviour and has its own test in browser_bridge.bats.
  _auth_callback_proxy() {
    echo "$1 $2 $3" > "$proxy_marker"
    [ -n "${4:-}" ] && : > "$4"
    sleep 5
  }

  _port_in_use() { return 1; }
  _browser_watcher "$clip_dir" "$mock_open" "test-container" &
  local watcher_pid=$!
  sleep 0.3

  # Retargeted for the browser destination gate: the fixture host moved onto
  # the shipped allowlist. What this test protects is unchanged. An origin the
  # gate refuses can never reach the opener, so the old fixture would have made
  # the assertion pass for the wrong reason.
  printf 'https://claude.ai/login?redirect_uri=http%%3A%%2F%%2Flocalhost%%3A34063%%2Fcallback&state=abc' > "$clip_dir/.browser-open"
  sleep 1.5

  kill "$watcher_pid" 2>/dev/null || true
  wait "$watcher_pid" 2>/dev/null || true

  [[ -f "$marker" ]] || { echo "URL was not opened in browser"; return 1; }
  [[ -f "$proxy_marker" ]] || { echo "Callback proxy was not started"; return 1; }
  run cat "$proxy_marker"
  assert_output "34063 test-container $clip_dir/.proxy-log"
}

@test "_auth_callback_proxy: writes diagnostic start line to log file" {
  local log_file="$TEST_TEMP/proxy-diag.log"
  # Stub tools lookup so neither socat nor python3 branch executes, we only
  # want to verify the start-of-run diagnostic is emitted.
  command() {
    if [[ "$1" == "-v" ]]; then return 1; fi
    builtin command "$@"
  }

  _auth_callback_proxy 12345 fake-container "$log_file"

  [[ -f "$log_file" ]] || { echo "proxy log not written"; return 1; }
  run cat "$log_file"
  assert_output --partial "starting: port=12345 container=fake-container"
  assert_output --partial "FAILED: neither socat nor python3 available on host"
}

@test "browser watcher: writes diagnostic log with extracted port" {
  local clip_dir="$TEST_TEMP/clip-log"
  local marker="$TEST_TEMP/browser-opened-log"
  mkdir -p "$clip_dir"

  local mock_open="$TEST_TEMP/mock-open-log"
  printf '#!/bin/bash\necho "$1" > %s\n' "$marker" > "$mock_open"
  chmod +x "$mock_open"

  # Stub proxy: succeed silently
  _auth_callback_proxy() { :; }

  _port_in_use() { return 1; }
  _browser_watcher "$clip_dir" "$mock_open" "test-container" &
  local watcher_pid=$!
  sleep 0.3

  # Retargeted for the browser destination gate: the fixture host moved onto
  # the shipped allowlist. What this test protects is unchanged. An origin the
  # gate refuses can never reach the opener, so the old fixture would have made
  # the assertion pass for the wrong reason.
  printf 'https://claude.ai/login?redirect_uri=http%%3A%%2F%%2Flocalhost%%3A49152%%2Fcallback&state=xyz' > "$clip_dir/.browser-open"
  sleep 1.5

  kill "$watcher_pid" 2>/dev/null || true
  wait "$watcher_pid" 2>/dev/null || true

  [[ -f "$clip_dir/.proxy-log" ]] || { echo "proxy log was not created"; return 1; }
  run cat "$clip_dir/.proxy-log"
  assert_output --partial "extracted callback port=49152"
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

  _port_in_use() { return 1; }
  _browser_watcher "$clip_dir" "$mock_open" "test-container" &
  local watcher_pid=$!
  sleep 0.3

  # Retargeted for the browser destination gate: the fixture host moved onto
  # the shipped allowlist. What this test protects is unchanged. An origin the
  # gate refuses can never reach the opener, so the old fixture would have made
  # the assertion pass for the wrong reason.
  printf 'https://claude.ai/docs' > "$clip_dir/.browser-open"
  sleep 1

  kill "$watcher_pid" 2>/dev/null || true
  wait "$watcher_pid" 2>/dev/null || true

  # The open assertion inverted with B3: a plain link off a terminal defers
  # now, because nobody is watching the browser during an unattended run. What
  # this test protects is the proxy, and that is unchanged: a URL with no
  # redirect_uri must never make the host bind a port.
  [[ ! -f "$marker" ]] || { echo "a plain link was opened with no terminal attached"; return 1; }
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

  # Retargeted onto an allowlisted auth URL. This test is about the two-argument
  # SIGNATURE still working, not about the destination, and a plain link at an
  # unallowlisted origin can no longer reach the opener to prove anything.
  _extract_callback_port() { echo "1455"; return 0; }
  _auth_callback_proxy() { [ -n "${4:-}" ] && : > "$4"; sleep 5; }
  _port_in_use() { return 1; }
  printf 'https://claude.ai/page?redirect_uri=http%%3A%%2F%%2Flocalhost%%3A1455%%2Fcb' > "$clip_dir/.browser-open"
  sleep 1.5

  kill "$watcher_pid" 2>/dev/null || true
  wait "$watcher_pid" 2>/dev/null || true

  [[ -f "$marker" ]] || return 1
  run cat "$marker"
  assert_output "https://claude.ai/page?redirect_uri=http%3A%2F%2Flocalhost%3A1455%2Fcb"
}


# ── payload validation ──────────────────────────────────────────────────────
#
# The event JSON a host hook receives on stdin is written by the CAGED side, so
# every field in it is attacker-chosen. These pin the six properties adopted
# from Claude Code's own container-session posture.

_ev() {   # build one spool line. $1 = event name, rest = extra jq assignments
  local ev="$1"; shift
  printf '{"hook_event_name":"%s","transcript_path":"/home/coder/.claude/projects/-workspace/abc.jsonl","cwd":"/workspace"%s}' "$ev" "$*"
}

@test "hook payload: the required transcript_path becomes a sentinel, never a drop" {
  # C1, and it is fatal if missed. transcript_path is REQUIRED on every event
  # and in a box it lives under /home/coder/.claude/projects/-workspace/, which
  # is never inside /workspace. A naive "every path must resolve inside the
  # project" rule fails EVERY event, and the capability becomes a no-op with a
  # counter.
  run _hook_translate_event "$(_ev PreToolUse)" "/Users/you/proj"
  assert_success
  assert_output --partial "transcript-is-inside-the-box"
  assert_output --partial '"cwd":"/Users/you/proj"'
}

@test "hook payload: cwd and file_path are translated to the host's own paths" {
  run _hook_translate_event "$(_ev PreToolUse ',"tool_input":{"file_path":"/workspace/src/a.ts"}')" "/Users/you/proj"
  assert_success
  assert_output --partial '"file_path":"/Users/you/proj/src/a.ts"'
}

@test "hook payload: a path outside the workspace drops the event" {
  # Property 5: the default is refuse, not sanitise. This is the class that
  # costs real money, a host path outside every mount.
  run _hook_translate_event "$(_ev PreToolUse ',"tool_input":{"file_path":"/etc/passwd"}')" "/Users/you/proj"
  assert_failure
  run _hook_translate_event "$(_ev PreToolUse ',"tool_input":{"file_path":"/Users/you/.ssh/id_rsa"}')" "/Users/you/proj"
  assert_failure
}

@test "hook payload: a traversal that lands back inside is still refused" {
  run _hook_translate_path "/workspace/../../etc/passwd" "/Users/you/proj"
  assert_failure
  run _hook_translate_path "/workspace/./a" "/Users/you/proj"
  assert_failure
  run _hook_translate_path "/workspace//a" "/Users/you/proj"
  assert_failure
}

@test "hook payload: leading or trailing whitespace is refused even with the right prefix" {
  # A value that already carries the workspace prefix is the only place this
  # arm is reachable, which is why the upstream ~ $ % backtick prefixes are not
  # repeated: the prefix requirement already refuses those.
  local bad
  for bad in " /workspace/a" "/workspace/a " "  /workspace/a  "; do
    run _hook_translate_path "$bad" "/Users/you/proj"
    assert_failure
  done
  # For an absolute field the prefix requirement covers the rest. A relative
  # field has no prefix, so it restates them (the event-level test below).
  for bad in "~/secrets" '$HOME/x' '%PATH%' '`id`' '!!' '=x' "relative/path"; do
    run _hook_translate_path "$bad" "/Users/you/proj"
    assert_failure
  done
}

@test "hook payload: a control character or a backslash is refused" {
  run _hook_translate_path "$(printf '/workspace/a\tb')" "/Users/you/proj"
  assert_failure
  run _hook_translate_path '/workspace/a\b' "/Users/you/proj"
  assert_failure
}

@test "hook payload: a fork box translates to the COPY, never the origin tree" {
  # C2. In a fork box the workspace is the copy and the project is the origin.
  # Translating to the project would point the user's host hook at the origin
  # working tree from inside a fork box, cancelling the isolation the fork
  # feature sells.
  run _hook_translate_event "$(_ev PreToolUse ',"tool_input":{"file_path":"/workspace/src/a.ts"}')" "/Users/you/.config/cleat/forks/proj-abc-feat"
  assert_success
  assert_output --partial '"file_path":"/Users/you/.config/cleat/forks/proj-abc-feat/src/a.ts"'
  refute_output --partial '"file_path":"/Users/you/proj/'
}

@test "hook payload: a docker-cap box's host-absolute paths still validate" {
  # C4 in the brief's numbering: with the docker cap on, the box mounts
  # "$_workspace:$_workspace" and sets --workdir to it, so events already carry
  # host-absolute paths. A /workspace-prefix-only rule breaks every hook there.
  run _hook_translate_path "/Users/you/proj/src/a.ts" "/Users/you/proj"
  assert_success
  assert_output "/Users/you/proj/src/a.ts"
  run _hook_translate_path "/Users/you/proj" "/Users/you/proj"
  assert_success
}

@test "hook payload: a sibling directory with the same prefix is not inside it" {
  run _hook_translate_path "/Users/you/proj-evil/x" "/Users/you/proj"
  assert_failure
  # The on-disk check draws the same line for itself.
  run _hook_path_inside "/Users/you/proj-evil/x" "/Users/you/proj"
  assert_failure
}

@test "hook payload: a file in a directory that does not exist yet still validates" {
  # The obvious design canonicalises both sides with `cd -P ... pwd -P`, which
  # needs the parent to EXIST, so a PreToolUse for a new file in a new directory
  # resolves to nothing and a formatter silently stops firing for exactly the
  # new-file case. The on-disk check walks up to the nearest existing ancestor.
  run _hook_translate_path "/workspace/src/new/dir/file.ts" "/Volumes/ext/Code/proj"
  assert_success
  assert_output "/Volumes/ext/Code/proj/src/new/dir/file.ts"
}

# A real workspace on disk, with a real directory beside it that the box must
# not be able to reach. Echoes the workspace path.
_ws_on_disk() {
  mkdir -p "$TEST_TEMP/ws/src" "$TEST_TEMP/outside"
  printf 'TOP-SECRET\n' > "$TEST_TEMP/outside/secret"
  printf 'x\n' > "$TEST_TEMP/ws/src/a.ts"
  printf '%s' "$TEST_TEMP/ws"
}

@test "hook payload: a symlink planted in the workspace cannot aim a path outside it" {
  # F06. The workspace is mounted read-write, so the box can plant a link, and a
  # prefix rewrite alone turned /workspace/evil/secret into a well-spelled
  # in-project path that opens a host file: a Read hook exfiltrated TOP-SECRET
  # and a Write hook formatted a file outside the workspace.
  local ws; ws="$(_ws_on_disk)"
  ln -s "$TEST_TEMP/outside" "$ws/evil"
  ln -s ../outside "$ws/rel"
  ln -s ../outside/secret "$ws/leaf"
  run _hook_translate_path "/workspace/evil/secret" "$ws"
  assert_failure
  run _hook_translate_path "/workspace/rel/secret" "$ws"
  assert_failure
  run _hook_translate_path "/workspace/leaf" "$ws"
  assert_failure
  # A new file under the planted link lands outside too.
  run _hook_translate_path "/workspace/evil/new-file" "$ws"
  assert_failure
  # The docker-cap spelling gets the same check.
  run _hook_translate_path "$ws/evil/secret" "$ws"
  assert_failure
  # And the control: a real file and a new file inside still validate.
  run _hook_translate_path "/workspace/src/a.ts" "$ws"
  assert_success
  assert_output "$ws/src/a.ts"
  run _hook_translate_path "/workspace/src/brand/new.ts" "$ws"
  assert_success
  assert_output "$ws/src/brand/new.ts"
}

@test "hook payload: a dangling or looping symlink is refused, even one aimed inside" {
  # Upstream's own rule: a component that is a symlink resolving to nothing is
  # refused, because the box still chooses where it will point when the hook
  # writes through it.
  local ws; ws="$(_ws_on_disk)"
  ln -s "$ws/not-there-yet" "$ws/dangling"
  run _hook_translate_path "/workspace/dangling" "$ws"
  assert_failure
  # A loop must be refused, not spun on. Bounded by a watchdog so a regression
  # fails here instead of hanging the suite.
  ln -s b "$ws/a"
  ln -s a "$ws/b"
  local out="$TEST_TEMP/loop.out" pid i=0
  ( if _hook_translate_path "/workspace/a/x" "$ws" >/dev/null 2>&1; then echo accepted; else echo refused; fi > "$out" ) &
  pid=$!
  while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null
    echo "a symlink loop hung the path check"; return 1
  fi
  wait "$pid" 2>/dev/null || true
  run cat "$out"
  assert_output "refused"
}

@test "hook payload: the on-disk walk never climbs a dot segment it could not resolve" {
  # A missing tail is appended to the nearest existing directory as written, so
  # a `..` in it would climb out of the workspace in the string while the
  # string still starts with the workspace.
  local ws; ws="$(_ws_on_disk)"
  run _hook_physical_path "$ws/missing/../../outside/secret"
  assert_failure
  run _hook_physical_path "$ws/missing/./x"
  assert_failure
  _hook_physical_path "$ws/missing/x"
  [ "$_HOOK_PHYS" = "$(cd -P "$ws" && pwd -P)/missing/x" ] || { echo "walk gave $_HOOK_PHYS"; return 1; }
}

@test "hook payload: a project reached through a symlink still validates on disk" {
  # C3: resolve_project is logical, so the workspace Cleat hands the bridge can
  # be ~/Code/proj while the files live under /Volumes/ext/Code/proj. The
  # physical path never starts with that spelling. The same directory is found
  # by device and inode instead, which also covers a different-case spelling of
  # one directory on APFS. The hook still receives the project's own spelling.
  mkdir -p "$TEST_TEMP/real/proj/src"
  printf 'x\n' > "$TEST_TEMP/real/proj/src/a.ts"
  ln -s "$TEST_TEMP/real" "$TEST_TEMP/Code"
  local ws="$TEST_TEMP/Code/proj"
  run _hook_translate_path "/workspace/src/a.ts" "$ws"
  assert_success
  assert_output "$ws/src/a.ts"
  run _hook_translate_path "/workspace/src/new.ts" "$ws"
  assert_success
}

@test "hook payload: a path walking more than the bound of missing components is refused" {
  # Upstream walks at most 64 components or links for one path. Unbounded, a
  # box-chosen value sets how long the bridge spends on it.
  local ws; ws="$(_ws_on_disk)"
  local deep="/workspace" i=0
  while [ "$i" -lt 70 ]; do deep="$deep/d"; i=$((i + 1)); done
  run _hook_translate_path "$deep" "$ws"
  assert_failure
  run _hook_translate_path "/workspace/d/d/d/d/d/d/d/d/d/d" "$ws"
  assert_success
}

@test "hook payload: a tool_input nested past the walk depth is refused" {
  # A path hidden deeper than the walk looks would otherwise pass unjudged.
  local deep ok
  deep="$(printf '[%.0s' $(seq 1 20))\"/etc/passwd\"$(printf ']%.0s' $(seq 1 20))"
  run _hook_translate_event "$(_ev PreToolUse ",\"tool_input\":{\"a\":$deep}")" "/Users/you/proj"
  assert_failure
  ok="$(printf '[%.0s' $(seq 1 10))\"x\"$(printf ']%.0s' $(seq 1 10))"
  run _hook_translate_event "$(_ev PreToolUse ",\"tool_input\":{\"a\":$ok}")" "/Users/you/proj"
  assert_success
}

@test "hook payload: more path fields than upstream's ceiling drops the event" {
  # Claude Code judges at most 256 paths for one event. Past that, the box
  # would choose how long the bridge spends on one line. The cwd counts, so
  # this event holds four.
  _HOOK_PATHS_MAX=3
  run _hook_translate_event "$(_ev PreToolUse ',"tool_name":"mcp__x__y","tool_input":{"paths":["/workspace/a","/workspace/b","/workspace/c"]}')" "/Users/you/proj"
  assert_failure
  _HOOK_PATHS_MAX=4
  run _hook_translate_event "$(_ev PreToolUse ',"tool_name":"mcp__x__y","tool_input":{"paths":["/workspace/a","/workspace/b","/workspace/c"]}')" "/Users/you/proj"
  assert_success
}

@test "hook payload: filenames past the list cap are nulled without being judged" {
  # A megabyte of line lists some 200,000 names. Each judged entry walks the
  # disk, so only the first _HOOK_LIST_MAX are judged and the rest are nulled.
  _HOOK_LIST_MAX=2
  eval "_tv_real() $(declare -f _hook_translate_value | tail -n +2)"
  _hook_translate_value() { printf 'x\n' >> "$TEST_TEMP/judged"; _tv_real "$@"; }
  run _hook_translate_event "$(_ev PostToolUse ',"tool_name":"Glob","tool_input":{"pattern":"*"},"tool_response":{"filenames":["/workspace/a","/workspace/b","/workspace/c","/etc/passwd"]}')" "/Users/you/proj"
  assert_success
  assert_output --partial '"filenames":["/Users/you/proj/a","/Users/you/proj/b",null,null]'
  run wc -l < "$TEST_TEMP/judged"
  assert_output --regexp '^ *2$'
  # The same cap holds for each tool_calls entry of a batch.
  run _hook_translate_event "$(_ev PostToolBatch ',"tool_calls":[{"tool_name":"Glob","tool_input":{"pattern":"*"},"tool_response":{"filenames":["/workspace/a","/workspace/b","/etc/passwd"]}}]')" "/Users/you/proj"
  assert_success
  assert_output --partial '"filenames":["/Users/you/proj/a","/Users/you/proj/b",null]'
}

@test "hook payload: every path-shaped tool_input field is checked, not just file_path" {
  # F08. Only four fields were translated, so Grep and Glob path, LSP filePath,
  # an Agent cwd and every MCP tool's path argument reached the host hook as any
  # absolute host path the box liked.
  run _hook_translate_event "$(_ev PreToolUse ',"tool_name":"Grep","tool_input":{"pattern":"k","path":"/Users/you/.ssh"}')" "/Users/you/proj"
  assert_failure
  run _hook_translate_event "$(_ev PreToolUse ',"tool_name":"LSP","tool_input":{"operation":"hover","filePath":"/Users/you/.zshrc"}')" "/Users/you/proj"
  assert_failure
  run _hook_translate_event "$(_ev PreToolUse ',"tool_name":"Agent","tool_input":{"prompt":"x","cwd":"/etc"}')" "/Users/you/proj"
  assert_failure
  run _hook_translate_event "$(_ev PreToolUse ',"tool_name":"mcp__fs__read","tool_input":{"options":{"source_dir":"/etc"}}')" "/Users/you/proj"
  assert_failure
  # The control: the same fields inside the workspace are translated.
  run _hook_translate_event "$(_ev PreToolUse ',"tool_name":"Grep","tool_input":{"pattern":"/etc/passwd","path":"/workspace/src"}')" "/Users/you/proj"
  assert_success
  assert_output --partial '"path":"/Users/you/proj/src"'
  # A non-path key is free text and is left alone, however path-like.
  assert_output --partial '"pattern":"/etc/passwd"'
}

@test "hook payload: each tool_calls entry of a batch is checked" {
  run _hook_translate_event "$(_ev PostToolBatch ',"tool_calls":[{"tool_name":"Read","tool_input":{"file_path":"/workspace/a.ts"}},{"tool_name":"Write","tool_input":{"file_path":"/etc/passwd"}}]')" "/Users/you/proj"
  assert_failure
  run _hook_translate_event "$(_ev PostToolBatch ',"tool_calls":[{"tool_name":"Read","tool_input":{"file_path":"/workspace/a.ts"}}]')" "/Users/you/proj"
  assert_success
  assert_output --partial '"file_path":"/Users/you/proj/a.ts"'
}

@test "hook payload: a Read response's file.filePath outside the workspace drops the event" {
  run _hook_translate_event "$(_ev PostToolUse ',"tool_name":"Read","tool_input":{"file_path":"/workspace/a.ts"},"tool_response":{"type":"text","file":{"filePath":"/etc/passwd","content":"x"}}')" "/Users/you/proj"
  assert_failure
  run _hook_translate_event "$(_ev PostToolUse ',"tool_name":"Read","tool_input":{"file_path":"/workspace/a.ts"},"tool_response":{"type":"text","file":{"filePath":"/workspace/a.ts","content":"x"}}')" "/Users/you/proj"
  assert_success
  assert_output --partial '"filePath":"/Users/you/proj/a.ts"'
}

@test "hook payload: a response list entry that does not map is nulled, never passed on" {
  # filenames[] and file.outputDir are informational, so one bad entry does not
  # cost the user the whole event. It is not handed over either.
  run _hook_translate_event "$(_ev PostToolUse ',"tool_name":"Glob","tool_input":{"pattern":"*"},"tool_response":{"filenames":["/workspace/a.ts","/etc/passwd"],"numFiles":2}')" "/Users/you/proj"
  assert_success
  assert_output --partial '"filenames":["/Users/you/proj/a.ts",null]'
  refute_output --partial "/etc/passwd"
  run _hook_translate_event "$(_ev PostToolUse ',"tool_name":"Read","tool_response":{"file":{"filePath":"/workspace/a.pdf","outputDir":"/Users/you/.ssh"}}')" "/Users/you/proj"
  assert_success
  assert_output --partial '"outputDir":null'
  refute_output --partial ".ssh"
}

@test "hook payload: a relative path field is kept, and still has to land inside" {
  # Grep and Glob accept a relative path. The value is kept as written and
  # judged from the translated cwd, which is the directory the hook runs in.
  local ws; ws="$(_ws_on_disk)"
  run _hook_translate_event "$(_ev PreToolUse ',"tool_name":"Grep","tool_input":{"pattern":"k","path":"./src"}')" "$ws"
  assert_success
  assert_output --partial '"path":"./src"'
  run _hook_translate_event "$(_ev PreToolUse ',"tool_name":"Grep","tool_input":{"pattern":"k","path":"../outside"}')" "$ws"
  assert_failure
  # The segment rules apply even where the value would land back inside.
  run _hook_translate_event "$(_ev PreToolUse ',"tool_name":"Grep","tool_input":{"pattern":"k","path":"src/../src"}')" "$ws"
  assert_failure
  run _hook_translate_event "$(_ev PreToolUse ',"tool_name":"Grep","tool_input":{"pattern":"k","path":"src//a.ts"}')" "$ws"
  assert_failure
  # A relative value through a planted link escapes like an absolute one did.
  ln -s "$TEST_TEMP/outside" "$ws/evil"
  run _hook_translate_event "$(_ev PreToolUse ',"tool_name":"Grep","tool_input":{"pattern":"k","path":"evil/secret"}')" "$ws"
  assert_failure
}

@test "hook payload: a relative path field is refused for a whole-value reject" {
  # Property 4. An absolute field gets these for free from its prefix
  # requirement. A relative field has no prefix, so without its own arms a
  # Grep path of ~/.ssh or $HOME/x reached the hook as written, for a later
  # consumer to expand.
  local ws bad; ws="$(_ws_on_disk)"
  for bad in "~/.ssh" '$HOME/x' '%PATH%' '`id`' '!x' '=x' " src" "src "; do
    run _hook_translate_event "$(jq -cn --arg p "$bad" '{hook_event_name:"PreToolUse",cwd:"/workspace",tool_name:"Grep",tool_input:{pattern:"k",path:$p}}')" "$ws"
    assert_failure
  done
  # The control: the same field, plainly relative and inside.
  run _hook_translate_event "$(jq -cn '{hook_event_name:"PreToolUse",cwd:"/workspace",tool_name:"Grep",tool_input:{pattern:"k",path:"src"}}')" "$ws"
  assert_success
  assert_output --partial '"path":"src"'
}

@test "hook payload: a cwd that is not a directory here makes the workspace the hook's directory" {
  # The hook runs in its event's cwd, so a cwd that cannot be entered would
  # cost the event. Upstream falls back to its launch directory. Cleat falls
  # back to the workspace and tells the hook so. Relative paths are judged there.
  local ws; ws="$(_ws_on_disk)"
  run _hook_translate_event "$(jq -cn '{hook_event_name:"Stop",cwd:"/workspace/gone"}')" "$ws"
  assert_success
  assert_output --partial "\"cwd\":\"$ws\""
}

@test "hook payload: an empty workspace judges nothing inside it" {
  # With no workspace every absolute path started with the empty string, so a
  # relative value on an event with no cwd was judged inside.
  run _hook_translate_event '{"hook_event_name":"PreToolUse","tool_name":"Grep","tool_input":{"pattern":"k","path":"src"}}' ""
  assert_failure
}

@test "hook payload: a URL field that holds a URL is not judged as a path" {
  run _hook_translate_event "$(_ev PreToolUse ',"tool_name":"WebFetch","tool_input":{"url":"https://example.com/a:b","prompt":"x"}')" "/Users/you/proj"
  assert_success
  assert_output --partial '"url":"https://example.com/a:b"'
  # The same key holding a host path is a path.
  run _hook_translate_event "$(_ev PreToolUse ',"tool_name":"mcp__x__get","tool_input":{"url":"/etc/passwd"}')" "/Users/you/proj"
  assert_failure
}

@test "hook payload: container-only response fields are left as they are" {
  # Bash rawOutputPath and persistedOutputPath and Agent outputFile name paths
  # inside the box. No host hook can open them, and dropping on them would cost
  # the user every PostToolUse hook for a long Bash command.
  run _hook_translate_event "$(_ev PostToolUse ',"tool_name":"Bash","tool_input":{"command":"ls"},"tool_response":{"stdout":"","persistedOutputPath":"/home/coder/.claude/projects/-workspace/t/tool-results/x.txt"}')" "/Users/you/proj"
  assert_success
  assert_output --partial '"persistedOutputPath":"/home/coder/.claude/projects/-workspace/t/tool-results/x.txt"'
}

@test "hook payload: a line holding two JSON values is refused" {
  # F18. Every jq pass reads the first value of its input, so the first object
  # was validated and the hook received both documents on stdin.
  run _hook_translate_event '{"hook_event_name":"Stop","cwd":"/workspace"} {"x":1}' "/Users/you/proj"
  assert_failure
  run _hook_translate_event '"x" {"hook_event_name":"Stop","cwd":"/workspace"}' "/Users/you/proj"
  assert_failure
  run _hook_translate_event '{"hook_event_name":"Stop","cwd":"/workspace"}' "/Users/you/proj"
  assert_success
}

# A UTF-8 locale, DISCOVERED rather than hardcoded: Linux ships C.utf8 and
# macOS en_US.UTF-8, and a wrong name makes setlocale fall back to C silently,
# which would compare C against C and pass no matter what the code does.
_utf8_locale() {
  locale -a 2>/dev/null | grep -iE '\.(utf-?8)$' | head -1 || true
}

@test "hook payload: a colon, a format character or a line separator is refused in any locale" {
  # F19. Only empty, dot, backslash and [[:cntrl:]] were refused, and
  # [[:cntrl:]] depends on the locale: U+2028 was accepted under C and refused
  # under C.UTF-8, and U+202E, U+200B and U+FEFF were accepted under both.
  local loc bad
  local utf8; utf8="$(_utf8_locale)"
  for loc in C $utf8; do
    LC_ALL="$loc"
    for bad in "/workspace/a:b" \
      "$(printf '/workspace/a\342\200\256b')" \
      "$(printf '/workspace/a\342\200\213b')" \
      "$(printf '/workspace/a\357\273\277b')" \
      "$(printf '/workspace/a\342\200\250b')" \
      "$(printf '/workspace/a\342\200\251b')" \
      "$(printf '/workspace/a\302\205b')"; do
      run _hook_translate_path "$bad" "/Users/you/proj"
      assert_failure
    done
    # The control: an accented name and a space are ordinary.
    run _hook_translate_path "$(printf '/workspace/My Project/caf\303\251.ts')" "/Users/you/proj"
    assert_success
  done
}

@test "hook payload: the character rule never judges the host workspace path itself" {
  # A host project folder may hold a colon. Only the part the box wrote is
  # judged, or every event from such a project would drop.
  run _hook_translate_path "/workspace/src/a.ts" "/Users/you/10:30 notes"
  assert_success
  assert_output "/Users/you/10:30 notes/src/a.ts"
}

@test "hook payload: agent_transcript_path becomes the sentinel too" {
  # F35. The second transcript field names a container path exactly like the
  # first, and nothing proved it was replaced.
  run _hook_translate_event "$(_ev SubagentStop ',"agent_transcript_path":"/home/coder/.claude/projects/-workspace/agent-1.jsonl"')" "/Users/you/proj"
  assert_success
  assert_output --partial '"agent_transcript_path":"/cleat/transcript-is-inside-the-box"'
  refute_output --partial "agent-1.jsonl"
}

@test "hook payload: every translated path field drops when it leaves the workspace" {
  # F35. Only tool_input.file_path had a refusal test, so reverting the drop for
  # cwd, notebook_path or tool_response.filePath left the suite green.
  run _hook_translate_event '{"hook_event_name":"Stop","transcript_path":"/t","cwd":"/etc"}' "/Users/you/proj"
  assert_failure
  run _hook_translate_event "$(_ev PreToolUse ',"tool_name":"NotebookEdit","tool_input":{"notebook_path":"/etc/x.ipynb"}')" "/Users/you/proj"
  assert_failure
  run _hook_translate_event "$(_ev PostToolUse ',"tool_name":"Write","tool_response":{"filePath":"/etc/passwd"}')" "/Users/you/proj"
  assert_failure
  # The control: all three inside are translated.
  run _hook_translate_event "$(_ev PostToolUse ',"tool_name":"NotebookEdit","tool_input":{"notebook_path":"/workspace/n.ipynb"},"tool_response":{"filePath":"/workspace/w.ts"}')" "/Users/you/proj"
  assert_success
  assert_output --partial '"cwd":"/Users/you/proj"'
  assert_output --partial '"notebook_path":"/Users/you/proj/n.ipynb"'
  assert_output --partial '"filePath":"/Users/you/proj/w.ts"'
}

@test "hook payload: the event name is bounded and charset-checked, never a roster" {
  # A hardcoded roster means the next Claude Code release silently stops running
  # the user's hook for a new event. concept/11 lists 25 names, 2.1.258 ships 33.
  run _hook_event_name_ok "SomeFutureEventName"
  assert_success
  run _hook_event_name_ok "PreToolUse"
  assert_success
  run _hook_event_name_ok 'X" // [{"hooks":[{"type":"command"}]}] // "'
  assert_failure
  run _hook_event_name_ok ""
  assert_failure
  run _hook_event_name_ok "$(printf 'a%.0s' $(seq 1 100))"
  assert_failure
}

@test "hook payload: an oversized line is dropped rather than processed" {
  # The spool is box-written, so the length of one event was the box's to
  # choose, and Cleat had no size cap anywhere in the bridge.
  run _hook_translate_event "$(_ev PreToolUse)" "/Users/you/proj"
  assert_success
  _HOOK_LINE_MAX=50
  run _hook_translate_event "$(_ev PreToolUse)" "/Users/you/proj"
  assert_failure
}

@test "hook payload: the shipped line cap is 1044480 bytes, exactly" {
  # Claude Code's own per-line cap for the same channel. The test above shrinks
  # the cap to watch it work, so nothing pinned the value a real box meets. A
  # line of exactly the cap passes and one byte more is dropped.
  local base n pad
  base="$(_ev PreToolUse ',"pad":""')"
  n=$(( 1044480 - ${#base} ))
  pad="$(printf '%*s' "$n" '' | tr ' ' a)"
  run _hook_translate_event "$(_ev PreToolUse ",\"pad\":\"${pad}\"")" "/Users/you/proj"
  assert_success
  run _hook_translate_event "$(_ev PreToolUse ",\"pad\":\"${pad}a\"")" "/Users/you/proj"
  assert_failure
}

@test "hook payload: the timeout is per event, not a flat 30 seconds" {
  run _hook_timeout_for PreToolUse
  assert_output "15"
  run _hook_timeout_for PostToolUse
  assert_output "15"
  run _hook_timeout_for UserPromptSubmit
  assert_output "30"
  run _hook_timeout_for Stop
  assert_output "120"
  run _hook_timeout_for SubagentStop
  assert_output "120"
  run _hook_timeout_for SomethingNew
  assert_output "30"
}

# ── the command source ──────────────────────────────────────────────────────

@test "hook source: a command defined only in a project settings file does not run" {
  # The escalation this closes, verified in the spec by running the function:
  # event one ran the user's own hook, the box rewrote the file the way a box
  # writes through /workspace, and event two executed the rewritten command on
  # the HOST. Both project files live inside that mount.
  mkdir -p "$TEST_TEMP/project/.claude" "$HOME/.claude"
  printf '{"hooks":{"PreToolUse":[{"hooks":[{"type":"command","command":"touch %s/BOX-CHOSEN"}]}]}}\n' \
    "$TEST_TEMP" > "$TEST_TEMP/project/.claude/settings.json"
  cp "$TEST_TEMP/project/.claude/settings.json" "$TEST_TEMP/project/.claude/settings.local.json"
  _RESOLVED_PROJECT="$TEST_TEMP/project"
  run _has_host_hooks
  assert_failure
}

@test "hook source: the host settings file is the one that runs" {
  mkdir -p "$HOME/.claude"
  printf '{"hooks":{"PreToolUse":[{"hooks":[{"type":"command","command":"touch %s/USER-OWN"}]}]}}\n' \
    "$TEST_TEMP" > "$HOME/.claude/settings.json"
  run _has_host_hooks
  assert_success
  _execute_host_hooks '{"hook_event_name":"PreToolUse"}' "$HOME/.claude/settings.json"
  [ -f "$TEST_TEMP/USER-OWN" ] || { echo "the user's own host hook did not run"; return 1; }
}

@test "hook source: a project file that defines hooks is named rather than ignored in silence" {
  mkdir -p "$TEST_TEMP/project/.claude"
  printf '{"hooks":{"PreToolUse":[{"hooks":[{"type":"command","command":"true"}]}]}}\n' \
    > "$TEST_TEMP/project/.claude/settings.json"
  _RESOLVED_PROJECT="$TEST_TEMP/project"
  run _hook_project_files_with_hooks
  assert_success
  assert_output --partial ".claude/settings.json"
}

@test "hook warning: a session that will run a host hook says what that means" {
  # EGRESS-SPEC H4. The docker cap has had its amber line since it shipped. The
  # hooks cap is the same class, a command outside the cage that the box's
  # activity triggers, and a real `--cap hooks start` printed nothing about it.
  command -v jq >/dev/null 2>&1 || skip "the bridge needs jq on the host"
  _host_open_cmd() { echo ""; }
  export DOCKER_EXIT_CODE=0
  printf '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"true"}]}]}}\n' > "$HOME/.claude/settings.json"
  ACTIVE_CAPS=(hooks)
  run exec_claude "test-h4-on" --dangerously-skip-permissions
  assert_output --partial "Host hooks enabled. The box chooses when they run and what is on their stdin."
  # Amber, the way the docker line renders, not a plain warn.
  assert_output --partial "214m! Host hooks enabled"
}

@test "hook warning: the advisory survives the session-end reclaim" {
  # The reclaim at a clean exit is cursor-up plus erase, meant for claude's
  # leftover line. Every caller prints a blank line before exec_claude, so that
  # blank is what it should eat. The advisory printed after it, became the last
  # line and was erased: it showed for the length of the session, then vanished
  # from the scrollback the moment claude exited. Found on a Mac, 2026-09-18.
  command -v jq >/dev/null 2>&1 || skip "the bridge needs jq on the host"
  _host_open_cmd() { echo ""; }
  export DOCKER_EXIT_CODE=0
  printf '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"true"}]}]}}\n' > "$HOME/.claude/settings.json"
  ACTIVE_CAPS=(hooks)
  run exec_claude "test-h4-keep" --dangerously-skip-permissions
  assert_output --partial "Host hooks enabled"
  local LF=$'\n'
  # A blank line sits between the pre-launch notices and the session output, so
  # the reclaim erases the blank and the advisory stays in the scrollback.
  # Asserted on $output rather than on `lines`, because bats drops empty
  # elements from that array, which is exactly what hid this.
  [[ "$output" == *"$LF$LF"* ]]
  local tail_after_blank="${output##*"$LF$LF"}"
  case "$tail_after_blank" in
    *"Session ended"*) : ;;
    *) printf 'no blank line before the session output\n' >&2; return 1 ;;
  esac
}

@test "hook warning: no host hook configured, no warning" {
  # A cap with nothing to run executes nothing on the host, so the line would
  # warn about a command that does not exist.
  command -v jq >/dev/null 2>&1 || skip "the bridge needs jq on the host"
  _host_open_cmd() { echo ""; }
  export DOCKER_EXIT_CODE=0
  : > "$HOME/.claude/settings.json"
  ACTIVE_CAPS=(hooks)
  run exec_claude "test-h4-off" --dangerously-skip-permissions
  refute_output --partial "Host hooks enabled"
}

# ── the matcher ─────────────────────────────────────────────────────────────

@test "hook matcher: a multi-line tool_name cannot satisfy an anchored matcher" {
  # grep matches per LINE, so "Write\nBash" satisfied ^Bash$ while every other
  # field of the payload described a Write. Anchoring was not a constraint.
  mkdir -p "$HOME/.claude"
  printf '{"hooks":{"PreToolUse":[{"matcher":"^Bash$","hooks":[{"type":"command","command":"touch %s/MATCHED"}]}]}}\n' \
    "$TEST_TEMP" > "$HOME/.claude/settings.json"
  _execute_host_hooks "$(printf '{"hook_event_name":"PreToolUse","tool_name":"Write\\nBash"}')" "$HOME/.claude/settings.json"
  [ ! -f "$TEST_TEMP/MATCHED" ] || { echo "a multi-line tool_name satisfied an anchored matcher"; return 1; }
  # And the honest single-line case still matches.
  _execute_host_hooks '{"hook_event_name":"PreToolUse","tool_name":"Bash"}' "$HOME/.claude/settings.json"
  [ -f "$TEST_TEMP/MATCHED" ] || { echo "an anchored matcher stopped matching its own tool"; return 1; }
}

# ── the drop log ────────────────────────────────────────────────────────────

@test "hook drops: the log lives outside every box-writable mount and every run dir" {
  # Not the clip dir (box-writable) and not the per-box run dir, which every
  # cleat rm, recreate and nuke removes. The box can INDUCE that removal:
  # [resources] in a project .cleat is read with no trust gate, feeds the config
  # fingerprint, and the recreate prompt it produces defaults to yes.
  _hook_drop_log "payload" '{"hook_event_name":"X"}'
  [ -f "$CLEAT_STATE_DIR/hook-drops.log" ] || { echo "the drop log was not written where it survives a teardown"; return 1; }
  run cat "$CLEAT_STATE_DIR/hook-drops.log"
  assert_output --partial "DROPPED-EVENT"
  case "$CLEAT_STATE_DIR" in
    *"/run/"*) echo "the drop log is inside a per-box run dir"; return 1 ;;
  esac
}

@test "hook drops: a forged event cannot inject a log line or a terminal escape" {
  _hook_drop_log "payload" "$(printf 'x\nDROPPED-EVENT\tforged\tline\n\033[2J')"
  run cat "$CLEAT_STATE_DIR/hook-drops.log"
  refute_output --partial $'\033[2J'
  [ "$(grep -c DROPPED-EVENT "$CLEAT_STATE_DIR/hook-drops.log")" -eq 1 ] || {
    echo "a forged payload wrote a second log line"; return 1; }
}

@test "hook drops: the summary says nothing when nothing was dropped" {
  # concept/21 forbids the nag.
  local log="$TEST_TEMP/hook-drops.log"; : > "$log"
  run _maybe_report_hook_drops "$log" 0
  assert_success
  assert_output ""
}

@test "hook drops: the summary counts only this session" {
  local log="$TEST_TEMP/hook-drops.log"
  printf 'ts\t%s\tjson\tbox-a\tmd5\t0\told\n' "$_HOOK_DROP_MARK" > "$log"
  local off; off="$(wc -c < "$log" | tr -d ' ')"
  run _maybe_report_hook_drops "$log" "$off" "box-a"
  assert_output ""
  printf 'ts\t%s\tjson\tbox-a\tmd5\t9\tnew\n' "$_HOOK_DROP_MARK" >> "$log"
  run _maybe_report_hook_drops "$log" "$off" "box-a"
  # The count sits between bold escapes, and BOLD itself carries a 1, so a bare
  # "1" matched whatever the count was. The escapes go first, with a $'...'
  # literal because BSD sed has no \x1b.
  local plain
  plain="$(printf '%s' "$output" | sed $'s/\033\\[[0-9;]*m//g')"
  run printf '%s' "$plain"
  assert_output --partial "Dropped 1 hook event from the box"
}

@test "hook drops: the summary counts only this box's drops" {
  # F20. The log is per install and two boxes can run sessions at once, so a
  # byte offset alone counted the other session's drops as this one's.
  local log="$TEST_TEMP/hook-drops.log"
  printf 'ts\t%s\tpath\tbox-a\tmd5\t0\tmine\n' "$_HOOK_DROP_MARK" > "$log"
  printf 'ts\t%s\tpath\tbox-b\tmd5\t0\ttheirs\n' "$_HOOK_DROP_MARK" >> "$log"
  printf 'ts\t%s\tpath\tbox-b\tmd5\t9\ttheirs\n' "$_HOOK_DROP_MARK" >> "$log"
  run _maybe_report_hook_drops "$log" 0 "box-a"
  assert_output --partial "hook event from the box"
  refute_output --partial "hook events"
}

@test "hook drops: the summary blames a path only when every drop named one" {
  # An oversized or malformed line did not name a path, and the notice said
  # every drop had.
  local log="$TEST_TEMP/hook-drops.log"
  printf 'ts\t%s\tpath\tbox-a\tmd5\t0\tp\n' "$_HOOK_DROP_MARK" > "$log"
  run _maybe_report_hook_drops "$log" 0 "box-a"
  assert_output --partial "named a path this machine could not map"
  printf 'ts\t%s\tsize\tbox-a\tmd5\t9\ts\n' "$_HOOK_DROP_MARK" >> "$log"
  run _maybe_report_hook_drops "$log" 0 "box-a"
  assert_output --partial "failed validation"
  refute_output --partial "named a path"
}

@test "hook runs: a forged tool name cannot inject a log row or a terminal escape" {
  _hook_run_log '{"hook_event_name":"PreToolUse","tool_name":"Write\nRAN-EVENT\tforged\u001b[2J"}' "line" "box-a" "0"
  run cat "$CLEAT_STATE_DIR/hook-runs.log"
  refute_output --partial $'\033[2J'
  [ "$(grep -c RAN-EVENT "$CLEAT_STATE_DIR/hook-runs.log")" -eq 1 ] || {
    echo "a forged tool name wrote a second log row"; return 1; }
}

@test "hook runs: the log is moved aside once it passes its cap" {
  # It grows with every tool call, unlike the drop log, so it must not grow
  # without bound.
  _HOOK_RUN_LOG_MAX=200
  _HOOK_RUN_LOG_EVERY=1
  local i=0
  while [ "$i" -lt 12 ]; do
    _hook_run_log '{"hook_event_name":"Stop"}' "line $i" "box-a" "$i"
    i=$((i + 1))
  done
  [ -f "$CLEAT_STATE_DIR/hook-runs.log.1" ] || { echo "the run log was never rotated"; return 1; }
  local sz; sz="$(wc -c < "$CLEAT_STATE_DIR/hook-runs.log" | tr -d '[:space:]')"
  [ "$sz" -le 400 ] || { echo "the run log grew past its cap: $sz bytes"; return 1; }
}

# ── cmd_login: browser bridge ───────────────────────────────────────────

@test "cmd_login: starts browser watcher when open command available" {
  is_running() { return 0; }
  require_running() { true; }

  local bw_marker="$TEST_TEMP/login-bw-started"
  _browser_watcher() {
    echo "$1 $2 $3" > "$bw_marker"
    # Trap BEFORE forking: cmd_login's kill can land before a later trap line
    # registers, and the default TERM disposition would end this function and
    # orphan the sleep. The orphan inherits bats' output pipes and stalls the
    # file for the full 60s (and can hold the CI step open past its timeout).
    # Detaching the sleep's stdio is the second belt: even a lost race then
    # holds nothing.
    local pid=""
    trap 'kill "$pid" 2>/dev/null; exit 0' TERM
    sleep 60 >/dev/null 2>&1 3>&- &
    pid=$!
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

@test "cmd_login: passes host_opens_clicks=0 so the auth URL always opens (never deferred)" {
  # Regression (v0.16.5): the login watcher only ever sees the auth URL claude
  # login launches programmatically (not a link the user clicked), so the terminal
  # won't open it. If cmd_login passed host_opens_clicks=1, a non-loopback console
  # auth URL (is_auth=0) would be DEFERRED to a terminal that never opens it, and
  # nothing would open despite the "browser will open automatically" promise.
  is_running() { return 0; }
  require_running() { true; }
  local bw_args="$TEST_TEMP/login-bw-args"
  _browser_watcher() {
    echo "$5" > "$bw_args"          # the host_opens_clicks argument
    local pid=""
    trap 'kill "$pid" 2>/dev/null; exit 0' TERM
    sleep 60 >/dev/null 2>&1 3>&- &
    pid=$!
    wait $pid
  }
  _host_open_cmd() { echo "true"; }
  export DOCKER_EXIT_CODE=0

  run cmd_login "$TEST_TEMP"
  [[ "$(cat "$bw_args" 2>/dev/null)" == "0" ]] || { echo "login passed host_opens_clicks=[$(cat "$bw_args" 2>/dev/null)], expected 0"; return 1; }
}

@test "cmd_login: off mode prints the manual-open message, not the auto-open promise" {
  is_running() { return 0; }
  require_running() { true; }
  _browser_watcher() {
    local pid=""
    trap 'kill "$pid" 2>/dev/null; exit 0' TERM
    sleep 60 >/dev/null 2>&1 3>&- &
    pid=$!
    wait $pid
  }
  _host_open_cmd() { echo "true"; }
  export DOCKER_EXIT_CODE=0
  export CLEAT_BROWSER_BRIDGE=off

  run cmd_login "$TEST_TEMP"
  assert_output --partial "CLEAT_BROWSER_BRIDGE=off"
  refute_output --partial "open automatically"
}

@test "cmd_login: default mode promises the browser opens automatically" {
  is_running() { return 0; }
  require_running() { true; }
  _browser_watcher() {
    local pid=""
    trap 'kill "$pid" 2>/dev/null; exit 0' TERM
    sleep 60 >/dev/null 2>&1 3>&- &
    pid=$!
    wait $pid
  }
  _host_open_cmd() { echo "true"; }
  export DOCKER_EXIT_CODE=0
  unset CLEAT_BROWSER_BRIDGE

  run cmd_login "$TEST_TEMP"
  assert_output --partial "open automatically"
  refute_output --partial "CLEAT_BROWSER_BRIDGE=off"
}

@test "cmd_login: cleans up browser watcher even when login fails" {
  is_running() { return 0; }
  require_running() { true; }

  local bw_started="$TEST_TEMP/login-bw-started2"
  local bw_killed="$TEST_TEMP/login-bw-killed2"
  _browser_watcher() {
    touch "$bw_started"
    # Kill the backgrounded sleep inside the trap (like the success-path test
    # above). Leaving it orphaned keeps the `run` output pipe open for the full
    # 60s, turning a fast assertion into a 60s stall. Trap first, stdio
    # detached: see the first cmd_login mock.
    local pid=""
    trap "touch '$bw_killed'; kill \"\$pid\" 2>/dev/null; exit 0" TERM
    sleep 60 >/dev/null 2>&1 3>&- &
    pid=$!
    wait "$pid"
  }
  _host_open_cmd() { echo "true"; }
  export DOCKER_EXIT_CODE=1

  run cmd_login "$TEST_TEMP"
  [[ -f "$bw_started" ]] || { echo "Browser watcher not started"; return 1; }
  sleep 0.3
  [[ -f "$bw_killed" ]] || { echo "Browser watcher not killed after login failure"; return 1; }
}

@test "hook bridge: an event naming a path outside the workspace never reaches a hook" {
  # End to end through the real watcher loop: validation runs BEFORE anything is
  # dispatched, and a failure drops the event rather than sanitising it.
  mkdir -p "$HOME/.claude"
  cat > "$HOME/.claude/settings.json" <<EOF
{"hooks":{"PreToolUse":[{"hooks":[{"type":"command","command":"touch $TEST_TEMP/hook_ran"}]}]}}
EOF
  # The workspace exists, as a real one always does, so a hook that got past
  # validation would have a directory to run in.
  mkdir -p "$TEST_TEMP/project"
  local hooks_file="$TEST_TEMP/events.jsonl"
  : > "$hooks_file"
  _hook_bridge_watcher "$hooks_file" "$TEST_TEMP/project" >/dev/null 2>&1 &
  local bpid=$!
  sleep 0.7
  printf '{"hook_event_name":"PreToolUse","transcript_path":"/home/coder/.claude/projects/-workspace/a.jsonl","cwd":"/workspace","tool_input":{"file_path":"/Users/you/.ssh/id_rsa"}}\n' >> "$hooks_file"
  sleep 1.5
  kill "$bpid" 2>/dev/null || true
  wait "$bpid" 2>/dev/null || true
  [ ! -f "$TEST_TEMP/hook_ran" ] || { echo "a hook ran on an event naming a host path outside the workspace"; return 1; }
  # And it was recorded where a teardown cannot reach it.
  run cat "$CLEAT_STATE_DIR/hook-drops.log"
  assert_output --partial "DROPPED-EVENT"
}

@test "hook bridge: a valid event still reaches the hook, with its paths translated" {
  # The other half, and the one that stops the capability becoming a no-op with
  # a counter: a well-formed event carrying the REQUIRED transcript_path must
  # run, and the hook must see the host's own path rather than /workspace.
  mkdir -p "$HOME/.claude" "$TEST_TEMP/project"
  cat > "$HOME/.claude/settings.json" <<EOF
{"hooks":{"PreToolUse":[{"hooks":[{"type":"command","command":"cat > $TEST_TEMP/hook_stdin"}]}]}}
EOF
  local hooks_file="$TEST_TEMP/events.jsonl"
  : > "$hooks_file"
  _hook_bridge_watcher "$hooks_file" "$TEST_TEMP/project" >/dev/null 2>&1 &
  local bpid=$!
  sleep 0.7
  printf '{"hook_event_name":"PreToolUse","transcript_path":"/home/coder/.claude/projects/-workspace/a.jsonl","cwd":"/workspace","tool_input":{"file_path":"/workspace/src/a.ts"}}\n' >> "$hooks_file"
  local i
  for i in 1 2 3 4 5 6; do
    [ -s "$TEST_TEMP/hook_stdin" ] && break
    sleep 0.5
  done
  kill "$bpid" 2>/dev/null || true
  wait "$bpid" 2>/dev/null || true
  [ -s "$TEST_TEMP/hook_stdin" ] || { echo "a valid event never reached the hook"; return 1; }
  run cat "$TEST_TEMP/hook_stdin"
  assert_output --partial "$TEST_TEMP/project/src/a.ts"
  refute_output --partial '"file_path":"/workspace/src/a.ts"'
  assert_output --partial "transcript-is-inside-the-box"
}

@test "hook bridge: a command defined only in a project settings file never runs through the bridge" {
  # End to end. The escalation: event one runs the user's own hook, the box
  # rewrites the project settings file through /workspace, event two runs the
  # rewritten command on the HOST.
  mkdir -p "$HOME/.claude" "$TEST_TEMP/project/.claude"
  echo '{}' > "$HOME/.claude/settings.json"
  cat > "$TEST_TEMP/project/.claude/settings.json" <<EOF
{"hooks":{"PreToolUse":[{"hooks":[{"type":"command","command":"touch $TEST_TEMP/BOX_CHOSE_THIS"}]}]}}
EOF
  _RESOLVED_PROJECT="$TEST_TEMP/project"
  local hooks_file="$TEST_TEMP/events.jsonl"
  : > "$hooks_file"
  _hook_bridge_watcher "$hooks_file" "$TEST_TEMP/project" >/dev/null 2>&1 &
  local bpid=$!
  sleep 0.7
  printf '{"hook_event_name":"PreToolUse","transcript_path":"/home/coder/.claude/projects/-workspace/a.jsonl","cwd":"/workspace"}\n' >> "$hooks_file"
  sleep 1.5
  kill "$bpid" 2>/dev/null || true
  wait "$bpid" 2>/dev/null || true
  [ ! -f "$TEST_TEMP/BOX_CHOSE_THIS" ] || { echo "a command from a file inside /workspace ran on the host"; return 1; }
}

@test "hook bridge: an orphaned bridge exits without executing late events" {
  # A bridge whose cleat process was SIGKILL'd must not keep running HOST
  # hooks for a dead session. Liveness is checked BEFORE event processing, so
  # an event arriving after the parent died is never executed.
  mkdir -p "$HOME/.claude"
  cat > "$HOME/.claude/settings.json" <<EOF
{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"touch $TEST_TEMP/hook_ran"}]}]}}
EOF
  local hooks_file="$TEST_TEMP/events.jsonl"
  : > "$hooks_file"
  sed 's/^set -euo pipefail$/:/' "$CLI" > "$TEST_TEMP/cli_stripped"
  cat > "$TEST_TEMP/hb_spawner.sh" <<EOF
source "$TEST_TEMP/cli_stripped"
_hook_bridge_watcher "$hooks_file" >/dev/null 2>&1 &
echo "\$!" > "$TEST_TEMP/hb_pid"
kill -9 \$\$
EOF
  bash "$TEST_TEMP/hb_spawner.sh" 2>/dev/null || true
  sleep 0.2
  echo '{"hook_event_name":"Stop"}' >> "$hooks_file"
  local bpid dead=0
  bpid="$(cat "$TEST_TEMP/hb_pid")"
  process_exited "$bpid" && dead=1
  # Unconditional reap: a live straggler holds bats' fd and hangs the file.
  kill "$bpid" 2>/dev/null || true
  [ "$dead" = 1 ] || { echo "bridge outlived its dead parent"; return 1; }
  [ ! -f "$TEST_TEMP/hook_ran" ] || { echo "orphan bridge executed a hook"; return 1; }
}

# ── bridge robustness, 2026-07-31 ───────────────────────────────────────────
#
# None of these change WHETHER or WHICH hooks run. Enabling the capability is
# the user's decision to run their own hooks on their own machine and that is
# untouched. These are bugs inside that decision.

@test "hook bridge: concurrency is bounded so a spool flood cannot fork-bomb the host" {
  # The spool is bind-mounted read-write into the box, so the caged side
  # chooses the line count. One unbounded background subshell per line turned
  # that into a host process count.
  [ -n "$_HOOK_BRIDGE_MAX_CONCURRENT" ]
  [ "$_HOOK_BRIDGE_MAX_CONCURRENT" -gt 0 ]
  [ "$_HOOK_BRIDGE_MAX_CONCURRENT" -le 32 ]

  # with the ceiling already occupied, a new spawn waits rather than piling on
  _HOOK_BRIDGE_MAX_CONCURRENT=2
  _HOOK_BRIDGE_CHILDREN=()
  sleep 5 & _HOOK_BRIDGE_CHILDREN+=("$!")
  local held1=$!
  sleep 5 & _HOOK_BRIDGE_CHILDREN+=("$!")
  local held2=$!
  run _hook_bridge_live_count
  assert_output "2"
  kill "$held1" "$held2" 2>/dev/null || true
}

@test "hook bridge: the live count ignores children that already exited" {
  _HOOK_BRIDGE_CHILDREN=()
  true & _HOOK_BRIDGE_CHILDREN+=("$!")
  wait "$!" 2>/dev/null || true
  run _hook_bridge_live_count
  assert_output "0"
}

@test "hook bridge: a truncated spool rewinds instead of killing the bridge" {
  # byte_offset only ever grew, so once the box truncated events.jsonl the
  # "is there more" test could never be true again and the user's hooks
  # silently stopped running for the rest of the session.
  run _hook_bridge_window 500 120
  assert_success
  assert_output "1 120"
}

@test "hook bridge: the read window is bounded to the size already sampled" {
  # tail read to the LIVE eof, which the box can push past the sampled size
  # mid-read. byte_offset was then set to the older size, so everything written
  # during the read was replayed and its hook ran twice.
  run _hook_bridge_window 100 150
  assert_success
  assert_output "101 50"
}

@test "hook bridge: nothing new means no read at all" {
  run _hook_bridge_window 100 100
  assert_failure
  assert_output ""
}

@test "hook bridge: a fresh spool is read from its first byte" {
  run _hook_bridge_window 0 42
  assert_success
  assert_output "1 42"
}

@test "_extract_callback_port: keeps the top of the range at 65535" {
  run _extract_callback_port "https://x/a?redirect_uri=http%3A%2F%2Flocalhost%3A65535%2Fcb"
  assert_success
  assert_output "65535"
}

@test "_extract_callback_port: rejects a non-numeric port" {
  run _extract_callback_port "https://x/a?redirect_uri=http%3A%2F%2Flocalhost%3Aabcd%2Fcb"
  assert_failure
}

@test "_extract_callback_port: still accepts a full Claude Code authorize URL" {
  # Characterization: the shape the real login actually emits must survive
  # every rule added above it.
  local url="https://claude.ai/oauth/authorize?code=true&client_id=9d1c250a&response_type=code&redirect_uri=http%3A%2F%2Flocalhost%3A54545%2Fcallback&scope=org%3Acreate_api_key+user%3Aprofile&code_challenge=abc&code_challenge_method=S256&state=xyz"
  run _extract_callback_port "$url"
  assert_success
  assert_output "54545"
}

@test "_extract_callback_port: a code-paste authorize URL still yields no proxy port" {
  # The code-paste flow has no loopback callback, so it must return 1 and the
  # login falls through to the printed code. This is unchanged behavior.
  local url="https://console.anthropic.com/oauth/authorize?redirect_uri=https%3A%2F%2Fconsole.anthropic.com%2Foauth%2Fcode%2Fcallback&state=x"
  run _extract_callback_port "$url"
  assert_failure
}

@test "hook bridge: a symlinked event spool is dropped instead of read through" {
  # wc -c on a link to a fifo or /dev/zero never returns, wedging the bridge
  # with no signal. [[ -f ]] dereferences, so the link test has to come first.
  local spool="$TEST_TEMP/events.jsonl"
  ln -s /dev/zero "$spool"
  _hb_parent=$$
  _portable_timeout 5 bash -c "true"     # ensure the helper exists before use
  _hook_bridge_watcher "$spool" >/dev/null 2>&1 &
  local hpid=$!
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    [ ! -L "$spool" ] && break
    sleep 0.3
  done
  kill "$hpid" 2>/dev/null || true; wait "$hpid" 2>/dev/null || true
  [ ! -L "$spool" ] || { echo "the planted spool symlink survived"; return 1; }
}

@test "_extract_callback_port: rejects userinfo placed before a loopback host" {
  run _extract_callback_port "https://x.example/a?redirect_uri=http%3A%2F%2Fuser%40localhost%3A9999%2F"
  assert_failure
}

@test "_extract_callback_port: a path-less redirect_uri ending in a query still parses" {
  # The authority ends at the first '/', '?' or '#'. Claude Code always sends
  # a /callback path, but the old substring parser accepted this shape too.
  run _extract_callback_port "https://x/a?redirect_uri=http%3A%2F%2Flocalhost%3A5555%3Fq%3D1"
  assert_success
  assert_output "5555"
}

@test "hook bridge: a FIFO planted as the spool is dropped instead of blocking the bridge" {
  # A FIFO is not a regular file, so the wait loop used to sit out its full
  # 30s and the bridge silently never started.
  local spool="$TEST_TEMP/events.jsonl"
  mkfifo "$spool"
  _hb_parent=$$
  _hook_bridge_watcher "$spool" >/dev/null 2>&1 &
  local hpid=$!
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    [ ! -p "$spool" ] && break
    sleep 0.4
  done
  kill "$hpid" 2>/dev/null || true; wait "$hpid" 2>/dev/null || true
  [ ! -p "$spool" ] || { echo "the planted FIFO survived"; return 1; }
}

@test "hook bridge: a spool swapped for a symlink mid-session stops the bridge" {
  # The startup guards cannot see a link planted between two polls of a live
  # bridge, and wc -c through one to /dev/zero never returns.
  local spool="$TEST_TEMP/events.jsonl"
  : > "$spool"
  _hb_parent=$$
  _hook_bridge_watcher "$spool" >/dev/null 2>&1 &
  local hpid=$!
  sleep 1.2
  # A regular file, deliberately NOT /dev/zero: reading through a link to a
  # character device never returns, so a mutated guard would leave a blocked
  # `wc` holding this test's pipe open and hang the whole run.
  printf 'planted\n' > "$TEST_TEMP/spool-target"
  rm -f "$spool"; ln -s "$TEST_TEMP/spool-target" "$spool"
  process_exited "$hpid" || { echo "bridge kept running against a swapped spool"; kill -9 "$hpid" 2>/dev/null; return 1; }
  [ ! -L "$spool" ] || { echo "the swapped link survived"; return 1; }
  run cat "$TEST_TEMP/spool-target"
  assert_output "planted"
}

@test "hook bridge: a spool line is read no further than one byte past the cap" {
  # F17. The cap was checked after `read -r line` had buffered the whole line,
  # so the box chose how much host memory one line cost: 256 MB of line peaked
  # the bridge at 1.7 GB.
  _HOOK_LINE_MAX=64
  local big; big="$(printf 'a%.0s' $(seq 1 300))"
  printf '%s\n%s\n' "$big" '{"n":2}' \
    | { while _hook_read_chunk; do printf '%s\n' "$_HOOK_CHUNK_LEN"; done; } > "$TEST_TEMP/chunks"
  run cat "$TEST_TEMP/chunks"
  assert_output "$(printf '65\n65\n65\n65\n40\n7')"
}

@test "hook bridge: the line cap counts bytes, not characters, under a UTF-8 locale" {
  # A 95-byte line of 55 characters passed a 60-byte cap under C.UTF-8.
  local utf8; utf8="$(_utf8_locale)"
  [ -n "$utf8" ] || skip "no UTF-8 locale available on this host"
  LC_ALL="$utf8"
  _HOOK_LINE_MAX=64
  local wide; wide="$(printf '\303\251%.0s' $(seq 1 40))"
  run _hook_line_fits "$wide"
  assert_failure
  printf '%s\n' "$wide" | { _hook_read_chunk; printf '%s\n' "$_HOOK_CHUNK_LEN"; } > "$TEST_TEMP/len"
  run cat "$TEST_TEMP/len"
  assert_output "65"
}

# Run the real bridge for box-a over a spool, append $2 (already newline
# terminated), and wait until the hook in the host settings has written
# $TEST_TEMP/hook_stdin. $1 = what the spool holds before the bridge starts.
# Both may end in a `_` that is dropped, so a caller's trailing newline survives
# the command substitution that built it.
_bridge_run_lines() {
  local hooks_file="$TEST_TEMP/events.jsonl" bpid i
  printf '%s' "${1%_}" > "$hooks_file"
  _hook_bridge_watcher "$hooks_file" "$TEST_TEMP/project" "box-a" >/dev/null 2>&1 &
  bpid=$!
  sleep 0.7
  printf '%s' "${2%_}" >> "$hooks_file"
  for i in 1 2 3 4 5 6; do
    [ -s "$TEST_TEMP/hook_stdin" ] && break
    sleep 0.5
  done
  kill "$bpid" 2>/dev/null || true
  wait "$bpid" 2>/dev/null || true
}

# A host settings file whose hook for event $1 appends its stdin to hook_stdin.
_host_hook_appends() {
  mkdir -p "$HOME/.claude" "$TEST_TEMP/project"
  printf '{"hooks":{"%s":[{"hooks":[{"type":"command","command":"cat >> %s/hook_stdin"}]}]}}\n' \
    "$1" "$TEST_TEMP" > "$HOME/.claude/settings.json"
}

@test "hook bridge: an oversized line is dropped once and the event after it still runs" {
  _host_hook_appends Stop
  _HOOK_LINE_MAX=256
  local big; big="$(printf 'a%.0s' $(seq 1 2000))"
  _bridge_run_lines "" "$(printf '{"hook_event_name":"Stop","pad":"%s"}\n{"hook_event_name":"Stop","n":2}\n_' "$big")"
  run cat "$TEST_TEMP/hook_stdin"
  assert_output --partial '"n":2'
  refute_output --partial "aaaa"
  run awk -F '\t' -v m="$_HOOK_DROP_MARK" '$2 == m { print $3 }' "$CLEAT_STATE_DIR/hook-drops.log"
  assert_output "size"
}

@test "hook bridge: a spool rewritten while an oversized line is discarded runs its first event" {
  # The discard of an oversized line is carried across polls, because one line
  # can span two read windows. A spool that shrinks starts over, and the
  # discard has to start over with it, or the first real event of the new
  # spool is thrown away as the old line's tail with no drop row at all.
  _host_hook_appends Stop
  _HOOK_LINE_MAX=256
  local hooks_file="$TEST_TEMP/events.jsonl" bpid i
  : > "$hooks_file"
  _hook_bridge_watcher "$hooks_file" "$TEST_TEMP/project" "box-a" >/dev/null 2>&1 &
  bpid=$!
  sleep 0.7
  # No newline: the line is still going when the spool is replaced.
  printf '{"hook_event_name":"Stop","pad":"%s' "$(printf 'a%.0s' $(seq 1 2000))" >> "$hooks_file"
  for i in $(seq 1 20); do
    [ -s "$CLEAT_STATE_DIR/hook-drops.log" ] && break
    sleep 0.25
  done
  printf '{"hook_event_name":"Stop","n":2}\n' > "$hooks_file"
  for i in $(seq 1 12); do
    [ -s "$TEST_TEMP/hook_stdin" ] && break
    sleep 0.5
  done
  kill "$bpid" 2>/dev/null || true
  wait "$bpid" 2>/dev/null || true
  run awk -F '\t' -v m="$_HOOK_DROP_MARK" '$2 == m { print $3 }' "$CLEAT_STATE_DIR/hook-drops.log"
  assert_output "size"
  run cat "$TEST_TEMP/hook_stdin"
  assert_output --partial '"n":2'
}

@test "hook bridge: a hook directory that leaves the workspace before it is entered is refused" {
  # The hook's directory was judged when the event was translated. The box can
  # swap it for a link before the hook starts, so it is entered with cd -P and
  # judged again from where it landed, never by name.
  local ws; ws="$(_ws_on_disk)"
  ln -s "$TEST_TEMP/outside" "$ws/swapped"
  _enter_and_pwd() { _hook_enter_run_dir "$1" "$2" && pwd -P; }
  run _enter_and_pwd "$ws/swapped" "$ws"
  assert_failure
  run _enter_and_pwd "$ws/src" "$ws"
  assert_success
  assert_output "$(cd -P "$ws/src" && pwd -P)"
  # An empty directory is refused rather than left to `cd ""`, which bash 3.2
  # treats as staying where the bridge already is.
  _enter_from_ws() { cd "$ws" && _enter_and_pwd "" "$ws"; }
  run _enter_from_ws
  assert_failure
}

@test "hook drops: each row names its reason, box, spool line md5 and offset" {
  # F20. Every drop was logged with the constant reason `payload` and nothing
  # tying it to a box or to a line in the spool.
  _host_hook_appends Stop
  local l1='{"hook_event_name":"PreToolUse","tool_input":{"file_path":"/etc/passwd"}}'
  local l2='{"hook_event_name":"bad name"}'
  local l3='{"hook_event_name":"Stop"'
  local l4='{"hook_event_name":"Stop"}'
  _bridge_run_lines "" "$(printf '%s\n%s\n%s\n%s\n_' "$l1" "$l2" "$l3" "$l4")"
  local h1 h2 h3
  h1="$(printf '%s' "$l1" | _md5)"; h1="${h1%% *}"
  h2="$(printf '%s' "$l2" | _md5)"; h2="${h2%% *}"
  h3="$(printf '%s' "$l3" | _md5)"; h3="${h3%% *}"
  run awk -F '\t' -v m="$_HOOK_DROP_MARK" '$2 == m { print $3, $4, $5, $6 }' "$CLEAT_STATE_DIR/hook-drops.log"
  assert_output "$(printf 'path box-a %s 0\nname box-a %s %s\njson box-a %s %s' \
    "$h1" "$h2" "$(( ${#l1} + 1 ))" "$h3" "$(( ${#l1} + ${#l2} + 2 ))")"
}

@test "hook runs: an event handed to the hooks is logged with its box, event, tool, md5 and offset" {
  # F20. Only drops were recorded, so nothing could say which box event ran a
  # hook.
  _host_hook_appends PreToolUse
  local l1='{"hook_event_name":"PreToolUse","tool_name":"Write","cwd":"/workspace","tool_input":{"file_path":"/workspace/a.ts"}}'
  _bridge_run_lines "$(printf 'earlier\n_')" "$(printf '%s\n_' "$l1")"
  local h1; h1="$(printf '%s' "$l1" | _md5)"; h1="${h1%% *}"
  run awk -F '\t' -v m="$_HOOK_RUN_MARK" '$2 == m { print $3, $4, $5, $6, $7 }' "$CLEAT_STATE_DIR/hook-runs.log"
  assert_output "box-a PreToolUse Write $h1 8"
}

@test "_hook_bridge_watcher: waits for a spool that arrives late" {
  # It gave up after 30 seconds, and the spool only exists once the box fires
  # its FIRST event. A user who reads the screen and types a prompt is past
  # that, so the bridge had exited and the whole session ran with no host hooks
  # and no message. Found on a real Mac, 2026-09-18. The sleep stub makes the
  # wait long without making the test slow.
  mkdir -p "$TEST_TEMP/late"
  local hooks_file="$TEST_TEMP/late/events.jsonl"
  local processed="$TEST_TEMP/late-processed"
  _execute_host_hook_bg() { echo "$1" >> "$processed"; }
  _RESOLVED_PROJECT="$TEST_TEMP"
  mkdir -p "${HOME}/.claude"
  echo '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"true"}]}]}}' \
    > "${HOME}/.claude/settings.json"

  # 120 waits, four times the old bound, each one cheap.
  sleep() { command sleep 0.005; }
  ( _hook_bridge_watcher "$hooks_file" ) &
  local pid=$!
  command sleep 0.5
  # The spool appears empty first, exactly as the box creates it, then carries
  # its first event.
  : > "$hooks_file"
  command sleep 0.5
  echo '{"hook_event_name":"Stop","_cleat_ts":"late1"}' >> "$hooks_file"
  command sleep 1.5
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null || true
  unset -f sleep

  [[ -f "$processed" ]] || { echo "the bridge gave up before the spool arrived"; return 1; }
  grep -q "late1" "$processed" || { echo "the late event was never forwarded"; return 1; }
}

@test "exec_claude: the hook spool exists before claude starts" {
  # Nothing should depend on the box creating it first.
  command -v jq >/dev/null 2>&1 || skip "the bridge needs jq on the host"
  _host_open_cmd() { echo ""; }
  export DOCKER_EXIT_CODE=0
  printf '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"true"}]}]}}\n' > "$HOME/.claude/settings.json"
  ACTIVE_CAPS=(hooks)
  run exec_claude "test-spool" --dangerously-skip-permissions
  assert_success
  run test -f "$CLEAT_RUN_DIR/test-spool/hooks/events.jsonl"
  assert_success

  # A link planted by the box is never followed: the host file it points at
  # keeps its contents and the spool is not created through it.
  local victim="$TEST_TEMP/victim.txt"
  printf 'KEEP\n' > "$victim"
  rm -f "$CLEAT_RUN_DIR/test-spool2/hooks/events.jsonl" 2>/dev/null || true
  mkdir -p "$CLEAT_RUN_DIR/test-spool2/hooks"
  ln -s "$victim" "$CLEAT_RUN_DIR/test-spool2/hooks/events.jsonl"
  run exec_claude "test-spool2" --dangerously-skip-permissions
  run cat "$victim"
  assert_output "KEEP"
}
