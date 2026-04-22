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
  # Uses `runuser -u coder` rather than `docker exec --user coder` so that
  # supplementary groups from /etc/group are loaded via initgroups(3).
  # Required for the docker capability (host socket group membership).
  run assert_docker_exec_has "runuser -u coder"
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

@test "passes resolved env args to docker exec" {
  _RESOLVED_ENV_ARGS=(-e "DATABASE_URL=postgres://localhost/mydb" -e "SECRET=abc")
  run exec_claude "test-ctr" --dangerously-skip-permissions
  run assert_docker_exec_has "DATABASE_URL=postgres://localhost/mydb"
  assert_success
  run assert_docker_exec_has "SECRET=abc"
  assert_success
}

@test "handles empty resolved env args without error" {
  _RESOLVED_ENV_ARGS=()
  run exec_claude "test-ctr" --dangerously-skip-permissions
  assert_success
  run assert_docker_exec_has "test-ctr"
  assert_success
}

@test "env args with special characters are preserved" {
  _RESOLVED_ENV_ARGS=(-e "DSN=postgres://user:p@ss@host/db?opt=1&x=2")
  run exec_claude "test-ctr" --dangerously-skip-permissions
  run assert_docker_exec_has "DSN=postgres://user:p@ss@host/db?opt=1&x=2"
  assert_success
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
