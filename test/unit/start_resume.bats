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

@test "start: full flow — builds, runs, execs with --dangerously-skip-permissions" {
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
  mkdir -p "/tmp/cleat-settings-${cname}"
  echo '{}' > "/tmp/cleat-settings-${cname}/settings.json"

  run cmd_start "$TEST_TEMP/project"
  assert_output --partial "Container started"
  run docker_calls
  assert_output --partial "docker start $cname"
  rm -rf "/tmp/cleat-settings-${cname}"
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
  assert_output --partial "No container for this project — creating fresh"
  # docker run was invoked (container creation happened).
  run grep "^docker run" "$DOCKER_CALLS"
  assert_success

  rm -rf "/tmp/cleat-settings-${cname}" "/tmp/cleat-hooks-${cname}"
}

@test "resume: restarts stopped container with --continue" {
  mkdir -p "$TEST_TEMP/project"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"
  is_running() { return 1; }  # container exists but NOT running
  mock_docker_ps_a "$cname"
  mkdir -p "/tmp/cleat-settings-${cname}"
  echo '{}' > "/tmp/cleat-settings-${cname}/settings.json"

  run cmd_resume "$TEST_TEMP/project"
  assert_output --partial "Session resumed"
  run assert_docker_exec_has "--continue"
  assert_success
  run assert_docker_exec_has "--dangerously-skip-permissions"
  assert_success
  rm -rf "/tmp/cleat-settings-${cname}"
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
  mkdir -p "/tmp/cleat-settings-${cname}"
  echo '{}' > "/tmp/cleat-settings-${cname}/settings.json"
  export DOCKER_EXIT_CODE=1  # docker start will fail

  run cmd_start "$TEST_TEMP/project"
  assert_failure
  assert_output --partial "Container failed to start"
  rm -rf "/tmp/cleat-settings-${cname}"
}

@test "start: docker start failure shows docker error and recovery hint" {
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"
  is_running() { return 1; }
  mock_docker_ps_a "$cname"
  mkdir -p "/tmp/cleat-settings-${cname}"
  echo '{}' > "/tmp/cleat-settings-${cname}/settings.json"
  export DOCKER_EXIT_CODE=1
  export DOCKER_STDERR="Error response from daemon: network bridge not found"

  run cmd_start "$TEST_TEMP/project"
  assert_failure
  assert_output --partial "Container failed to start"
  assert_output --partial "network bridge not found"
  assert_output --partial "cleat rm"
  rm -rf "/tmp/cleat-settings-${cname}"
}

@test "resume: docker start failure shows helpful error with reason" {
  mkdir -p "$TEST_TEMP/project"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"
  is_running() { return 1; }
  mock_docker_ps_a "$cname"
  mkdir -p "/tmp/cleat-settings-${cname}"
  echo '{}' > "/tmp/cleat-settings-${cname}/settings.json"
  export DOCKER_EXIT_CODE=1
  export DOCKER_STDERR="Error response from daemon: OCI runtime create failed"

  run cmd_resume "$TEST_TEMP/project"
  assert_failure
  assert_output --partial "Container failed to start"
  assert_output --partial "OCI runtime create failed"
  assert_output --partial "cleat rm"
  rm -rf "/tmp/cleat-settings-${cname}"
}

@test "start: stale mounts auto-recreate container after reboot" {
  # After host reboot, /tmp is cleared — settings overlay dir is gone.
  # cmd_start should detect this and silently recreate instead of failing.
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"
  is_running() { return 1; }
  mock_docker_ps_a "$cname"
  # Do NOT create settings overlay dir — simulates post-reboot state

  run cmd_start "$TEST_TEMP/project"
  assert_success
  assert_output --partial "Recreating container"
  assert_output --partial "host paths changed"
  # Should have removed old container and created new one via docker run
  run docker_calls
  assert_output --partial "docker rm -f $cname"
  assert_output --partial "docker run"
  refute_output --partial "docker start $cname"
  rm -rf "/tmp/cleat-settings-${cname}" "/tmp/cleat-clip-${cname}"
}

@test "resume: stale mounts show clear error directing to cleat start" {
  # After reboot, resume can't fix stale mounts — tell user to recreate.
  mkdir -p "$TEST_TEMP/project"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"
  is_running() { return 1; }
  mock_docker_ps_a "$cname"
  # Do NOT create settings overlay dir — simulates post-reboot state

  run cmd_resume "$TEST_TEMP/project"
  assert_failure
  assert_output --partial "stale"
  assert_output --partial "rebooted"
  assert_output --partial "cleat"
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
