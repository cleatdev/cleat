#!/usr/bin/env bats
load "../setup"
setup() {
  _common_setup
  use_docker_stub
  source_cli
  _host_clip_cmd() { echo ""; }
}
teardown() { _common_teardown; }

@test "execs into correct container as coder with -it" {
  run exec_claude "test-ctr" --dangerously-skip-permissions
  run assert_docker_exec_has "test-ctr"
  assert_success
  run assert_docker_exec_has "--user coder"
  assert_success
  run assert_docker_exec_has "docker exec -it"
  assert_success
}

@test "forwards all arguments to claude inside container" {
  run exec_claude "test-ctr" --dangerously-skip-permissions --continue
  run assert_docker_exec_has "--dangerously-skip-permissions"
  assert_success
  run assert_docker_exec_has "--continue"
  assert_success
}

@test "sets HOME and PATH env vars" {
  run exec_claude "test-ctr" --dangerously-skip-permissions
  run assert_docker_exec_has "HOME=/home/coder"
  assert_success
  run assert_docker_exec_has "PATH="
  assert_success
}

@test "creates clipboard bridge directory" {
  run exec_claude "my-ctr" --dangerously-skip-permissions
  run test -d "/tmp/cleat-clip-my-ctr"
  assert_success
  rm -rf "/tmp/cleat-clip-my-ctr"
}

@test "exit 0 and 130 (Ctrl-C) produce no warning" {
  for code in 0 130; do
    export DOCKER_EXIT_CODE=$code
    run exec_claude "test-ctr" --dangerously-skip-permissions
    refute_output --partial "exited with code"
  done
}

@test "unexpected exit code warns user" {
  export DOCKER_EXIT_CODE=42
  run exec_claude "test-ctr" --dangerously-skip-permissions
  assert_output --partial "exited with code 42"
}
