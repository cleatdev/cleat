#!/usr/bin/env bats
load "../setup"
setup() {
  _common_setup
  use_docker_stub
  source_cli
}
teardown() { _common_teardown; }

_run_nuke_with_input() {
  local input="$1"
  run bash -c '
    export DOCKER_CALLS="'"$DOCKER_CALLS"'"
    export DOCKER_MOCK_DIR="'"$DOCKER_MOCK_DIR"'"
    export DOCKER_EXIT_CODE=0
    export PATH="'"$MOCK_BIN"':$PATH"
    source "'"$CLI"'"
    echo "'"$input"'" | cmd_nuke
  '
}

@test "nuke: aborts when user types anything other than 'nuke'" {
  _run_nuke_with_input "no"
  assert_output --partial "Aborted"
}

@test "nuke: rejects uppercase NUKE" {
  _run_nuke_with_input "NUKE"
  assert_output --partial "Aborted"
}

@test "nuke: rejects empty input" {
  _run_nuke_with_input ""
  assert_output --partial "Aborted"
}

@test "nuke: proceeds on exact 'nuke' and removes everything" {
  mock_docker_ps_a "cleat-foo-abc12345"
  mock_docker_images "cleat"

  _run_nuke_with_input "nuke"
  assert_success
  assert_output --partial "Nuked"
  run docker_calls
  assert_output --partial "docker rm -f cleat-foo-abc12345"
  assert_output --partial "docker rmi -f cleat"
  assert_output --partial "docker builder prune"
}

@test "nuke: reassures user that project files and auth are safe" {
  _run_nuke_with_input "nuke"
  assert_output --partial "safe"
  assert_output --partial "cleat start"
}
