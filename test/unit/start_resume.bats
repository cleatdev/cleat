#!/usr/bin/env bats
load "../setup"
setup() {
  _common_setup
  use_docker_stub
  source_cli
  _host_clip_cmd() { echo ""; }
  check_for_update() { true; }
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

  run cmd_start "$TEST_TEMP/project"
  assert_output --partial "Container started"
  run docker_calls
  assert_output --partial "docker start $cname"
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

@test "resume: fails when no container exists" {
  mkdir -p "$TEST_TEMP/project"
  run cmd_resume "$TEST_TEMP/project"
  assert_failure
  assert_output --partial "No container found"
}

@test "resume: restarts stopped container with --continue" {
  mkdir -p "$TEST_TEMP/project"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"
  is_running() { return 1; }  # container exists but NOT running
  mock_docker_ps_a "$cname"

  run cmd_resume "$TEST_TEMP/project"
  assert_output --partial "Session resumed"
  run assert_docker_exec_has "--continue"
  assert_success
  run assert_docker_exec_has "--dangerously-skip-permissions"
  assert_success
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
  export DOCKER_EXIT_CODE=1  # docker start will fail

  run cmd_start "$TEST_TEMP/project"
  assert_failure
  assert_output --partial "Container failed to start"
}

@test "resume: docker start failure shows helpful error" {
  mkdir -p "$TEST_TEMP/project"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"
  is_running() { return 1; }
  mock_docker_ps_a "$cname"
  export DOCKER_EXIT_CODE=1  # docker start will fail

  run cmd_resume "$TEST_TEMP/project"
  assert_failure
  assert_output --partial "Container failed to start"
}

@test "no arguments to main defaults to start" {
  mock_docker_images "cleat"
  run bash -c '
    export DOCKER_PS_OUTPUT="" DOCKER_PS_A_OUTPUT="" DOCKER_IMAGES_OUTPUT="cleat"
    export DOCKER_CALLS="'"$DOCKER_CALLS"'" PATH="'"$MOCK_BIN"':$PATH"
    source "'"$CLI"'"
    _host_clip_cmd() { echo ""; }
    check_for_update() { true; }
    main
  '
  run docker_run_calls
  assert_output --partial "docker run"
}
