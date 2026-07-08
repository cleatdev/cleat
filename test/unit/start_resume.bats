#!/usr/bin/env bats
load "../setup"
setup() {
  _common_setup
  use_docker_stub
  source_cli
  _host_clip_cmd() { echo ""; }
  check_for_update() { true; }
  check_drift() { true; }
  _resolve_config_drift() { true; }
}
teardown() { _common_teardown; }

@test "start: full flow: builds, runs, execs with --dangerously-skip-permissions" {
  mkdir -p "$TEST_TEMP/project"
  run cmd_start "$TEST_TEMP/project"
  assert_success
  run docker_build_calls
  assert_output --partial "docker build"
  run docker_run_calls
  assert_output --partial "docker run"
  run assert_docker_exec_has "--dangerously-skip-permissions"
  assert_success
}

@test "start: restarts stopped container instead of creating new" {
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"
  is_running() { return 1; }  # container exists but NOT running
  mock_docker_ps_a "$cname"
  # Settings overlay must exist or stale-mount check triggers recreation
  mkdir -p "$CLEAT_RUN_DIR/${cname}/settings"
  echo '{}' > "$CLEAT_RUN_DIR/${cname}/settings/settings.json"

  run cmd_start "$TEST_TEMP/project"
  assert_output --partial "Container started"
  run docker_calls
  assert_output --partial "docker start $cname"
  rm -rf "$CLEAT_RUN_DIR/${cname}/settings"
}

@test "start: skips build when image exists" {
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project"
  run cmd_start "$TEST_TEMP/project"
  run docker_build_calls
  refute_output --partial "docker build"
}

@test "start: does not re-run if container already running" {
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"
  mock_docker_ps "$cname"
  mock_docker_ps_a "$cname"

  run cmd_start "$TEST_TEMP/project"
  run docker_run_calls
  refute_output --partial "docker run"
}

@test "resume: creates container when none exists and continues" {
  # Session files live on the host and survive cleat rm, so cleat resume
  # now auto-creates a fresh container instead of erroring out. Claude is
  # launched with --continue so the user picks up where they left off.
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"

  run cmd_resume "$TEST_TEMP/project"
  assert_success
  assert_output --partial "No container for this project. Creating fresh"
  # docker run was invoked (container creation happened).
  run grep "^docker run" "$DOCKER_CALLS"
  assert_success

  rm -rf "$CLEAT_RUN_DIR/${cname}/settings" "$CLEAT_RUN_DIR/${cname}/hooks"
}

@test "resume: restarts stopped container with --continue" {
  mkdir -p "$TEST_TEMP/project"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"
  is_running() { return 1; }  # container exists but NOT running
  mock_docker_ps_a "$cname"
  mkdir -p "$CLEAT_RUN_DIR/${cname}/settings"
  echo '{}' > "$CLEAT_RUN_DIR/${cname}/settings/settings.json"

  run cmd_resume "$TEST_TEMP/project"
  assert_output --partial "Session resumed"
  run assert_docker_exec_has "--continue"
  assert_success
  run assert_docker_exec_has "--dangerously-skip-permissions"
  assert_success
  rm -rf "$CLEAT_RUN_DIR/${cname}/settings"
}

@test "resume: folds an in-box login from another box into a stopped box (login once, every box)" {
  # cmd_resume must refresh the per-project claude.json before docker start,
  # exactly like cmd_start, so a login done in another box carries in on resume
  # too. Without the cmd_resume-side call this assertion fails while every other
  # test stays green (the cmd_start test cannot see a resume-only regression).
  mkdir -p "$TEST_TEMP/project"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"
  is_running() { return 1; }
  mock_docker_ps_a "$cname"
  mkdir -p "$CLEAT_RUN_DIR/${cname}/settings"
  echo '{}' > "$CLEAT_RUN_DIR/${cname}/settings/settings.json"
  rm -f "${HOME}/.claude.json"
  mkdir -p "$CLEAT_PROJECTS_DIR/box-login-elsewhere"
  echo '{"oauthAccount":{"emailAddress":"resume@login.dev"},"userID":"ur"}' > "$CLEAT_PROJECTS_DIR/box-login-elsewhere/claude.json"
  local key
  key="$(_derive_project_session_key "$TEST_TEMP/project" "main")"
  mkdir -p "$CLEAT_PROJECTS_DIR/$key"
  echo '{"projects":{}}' > "$CLEAT_PROJECTS_DIR/$key/claude.json"

  run cmd_resume "$TEST_TEMP/project"
  assert_output --partial "Session resumed"
  run jq -r '.oauthAccount.emailAddress' "$CLEAT_PROJECTS_DIR/$key/claude.json"
  assert_output "resume@login.dev"
  rm -rf "$CLEAT_RUN_DIR/${cname}/settings"
}

@test "resume: attaches to running container without restarting" {
  mkdir -p "$TEST_TEMP/project"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"
  mock_docker_ps "$cname"
  mock_docker_ps_a "$cname"

  run cmd_resume "$TEST_TEMP/project"
  run docker_calls
  refute_output --partial "docker start"
  run assert_docker_exec_has "--continue"
  assert_success
}

@test "start: docker start failure does not orphan spinner (set -e safe)" {
  # Regression test: when docker start fails under set -euo pipefail,
  # the spinner must be stopped and not left running in the background.
  # The actual binary runs with set -e (unlike sourced tests).
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"
  is_running() { return 1; }
  mock_docker_ps_a "$cname"
  mkdir -p "$CLEAT_RUN_DIR/${cname}/settings"
  echo '{}' > "$CLEAT_RUN_DIR/${cname}/settings/settings.json"
  export DOCKER_EXIT_CODE=1  # docker start will fail

  run cmd_start "$TEST_TEMP/project"
  assert_failure
  assert_output --partial "Container failed to start"
  rm -rf "$CLEAT_RUN_DIR/${cname}/settings"
}

@test "start: docker start failure shows docker error and recovery hint" {
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"
  is_running() { return 1; }
  mock_docker_ps_a "$cname"
  mkdir -p "$CLEAT_RUN_DIR/${cname}/settings"
  echo '{}' > "$CLEAT_RUN_DIR/${cname}/settings/settings.json"
  export DOCKER_EXIT_CODE=1
  export DOCKER_STDERR="Error response from daemon: network bridge not found"

  run cmd_start "$TEST_TEMP/project"
  assert_failure
  assert_output --partial "Container failed to start"
  assert_output --partial "network bridge not found"
  assert_output --partial "cleat rm"
  rm -rf "$CLEAT_RUN_DIR/${cname}/settings"
}

@test "resume: docker start failure shows helpful error with reason" {
  mkdir -p "$TEST_TEMP/project"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"
  is_running() { return 1; }
  mock_docker_ps_a "$cname"
  mkdir -p "$CLEAT_RUN_DIR/${cname}/settings"
  echo '{}' > "$CLEAT_RUN_DIR/${cname}/settings/settings.json"
  export DOCKER_EXIT_CODE=1
  export DOCKER_STDERR="Error response from daemon: OCI runtime create failed"

  run cmd_resume "$TEST_TEMP/project"
  assert_failure
  assert_output --partial "Container failed to start"
  assert_output --partial "OCI runtime create failed"
  assert_output --partial "cleat rm"
  rm -rf "$CLEAT_RUN_DIR/${cname}/settings"
}

@test "start: stale mounts auto-recreate container after reboot" {
  # After host reboot, /tmp is cleared: settings overlay dir is gone.
  # cmd_start should detect this and silently recreate instead of failing.
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"
  is_running() { return 1; }
  mock_docker_ps_a "$cname"
  # Do NOT create settings overlay dir, simulates post-reboot state

  run cmd_start "$TEST_TEMP/project"
  assert_success
  assert_output --partial "Recreating container"
  assert_output --partial "host paths changed"
  # Should have removed old container and created new one via docker run
  run docker_calls
  assert_output --partial "docker rm -f $cname"
  assert_output --partial "docker run"
  refute_output --partial "docker start $cname"
  rm -rf "$CLEAT_RUN_DIR/${cname}/settings" "$CLEAT_RUN_DIR/${cname}/clip"
}

@test "resume: stale mounts auto-recreate and continue (sessions live on host)" {
  # After paths rotate (reboot, partial /tmp cleanup, SSH-socket rotation),
  # resume can't docker-start the stale container, but sessions live on the
  # host, so it recreates transparently and continues with --continue instead
  # of erroring out and dead-ending the user.
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"
  is_running() { return 1; }
  mock_docker_ps_a "$cname"
  # Do NOT create settings overlay dir, simulates post-reboot state

  run cmd_resume "$TEST_TEMP/project"
  assert_success
  assert_output --partial "Recreating container"
  assert_output --partial "host paths changed"
  run docker_calls
  assert_output --partial "docker rm -f $cname"
  assert_output --partial "docker run"
  refute_output --partial "docker start $cname"
  run assert_docker_exec_has "--continue"
  assert_success
  rm -rf "$CLEAT_RUN_DIR/${cname}/settings" "$CLEAT_RUN_DIR/${cname}/clip"
}

# ── _container_bind_sources_present (vanished bind-source detection) ──────────
# Detects when a baked-in bind-mount source no longer exists on the host, so the
# caller can recreate instead of letting `docker start` abort with an opaque OCI
# "not a directory" error. The headline trigger is the macOS SSH agent socket,
# whose launchd path rotates on every reboot.

@test "bind-sources: present when every bind source exists on the host" {
  touch "$TEST_TEMP/sock"
  mock_docker_inspect "$(printf 'bind|%s\nbind|%s\n' "$TEST_TEMP" "$TEST_TEMP/sock")"
  run _container_bind_sources_present "cleat-x"
  assert_success
}

@test "bind-sources: stale when a bind source has vanished (rotated SSH socket)" {
  # The launchd SSH-agent socket dir is regenerated each reboot, so the recorded
  # source path no longer resolves on the host.
  mock_docker_inspect "$(printf 'bind|%s\nbind|%s\n' \
    "$TEST_TEMP" "$TEST_TEMP/run/com.apple.launchd.GONE/Listeners")"
  run _container_bind_sources_present "cleat-x"
  assert_failure
}

@test "bind-sources: ignores non-bind mounts (volumes/tmpfs have no host source)" {
  # A volume Source under docker's internal dir won't exist on the host, but a
  # non-bind mount must NEVER be treated as a vanished source.
  mock_docker_inspect "$(printf 'volume|%s\ntmpfs|\n' "/var/lib/docker/volumes/x/_data")"
  run _container_bind_sources_present "cleat-x"
  assert_success
}

@test "no arguments to main defaults to start" {
  mock_docker_images "cleat"
  run bash -c '
    export DOCKER_PS_OUTPUT="" DOCKER_PS_A_OUTPUT="" DOCKER_IMAGES_OUTPUT="cleat"
    export DOCKER_CALLS="'"$DOCKER_CALLS"'" PATH="'"$MOCK_BIN"':$PATH"
    source "'"$CLI"'"
    _host_clip_cmd() { echo ""; }
    check_for_update() { true; }
    check_drift() { true; }
    _resolve_config_drift() { true; }
    main
  '
  run docker_run_calls
  assert_output --partial "docker run"
}
