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

@test "nuke: no global 'docker image prune'; build cache still cleared" {
  mock_docker_ps_a "cleat-foo-abc12345"
  mock_docker_images "cleat"
  _run_nuke_with_input "nuke"
  assert_success
  run docker_calls
  refute_output --partial "docker image prune"
  assert_output --partial "docker builder prune -f"
}

@test "nuke: confirm discloses the shared build cache and drops the false volumes claim" {
  _run_nuke_with_input "no"
  refute_output --partial "and volumes"
  assert_output --partial "shared Docker build cache"
}

@test "nuke: a fork marker whose copy survives is kept, not orphaned" {
  # nuke removes containers, images and build cache. It deliberately does NOT
  # remove fork workspace copies, because a copy can hold the only version of
  # hours of agent work. But the marker lived in the boxes dir that nuke wipes,
  # so the copy came back orphaned AND unmarked, and the next
  # `cleat start <box> --fork` read it as a fresh fork, re-copied, and rm -rf'd
  # the surviving copy first. Silent destruction by a command that never
  # claimed to touch it.
  mkdir -p "$CLEAT_FORKS_DIR/cleat-keep-11112222-main"
  echo "uncommitted" > "$CLEAT_FORKS_DIR/cleat-keep-11112222-main/WIP.txt"
  _fork_mark "cleat-keep-11112222-main"
  run cmd_nuke <<< "nuke"
  assert_success
  [ -f "$CLEAT_FORKS_DIR/cleat-keep-11112222-main/WIP.txt" ]
  [ -f "$(_fork_marker_file "cleat-keep-11112222-main")" ]
}

@test "nuke: a fork marker with no surviving copy is not resurrected" {
  # The other half: only markers backed by a real copy come back.
  _fork_mark "cleat-gone-33334444-main"
  run cmd_nuke <<< "nuke"
  assert_success
  [ ! -e "$(_fork_marker_file "cleat-gone-33334444-main")" ]
}

@test "nuke: a closed stdin aborts instead of dying under strict mode" {
  # `read -rp` with no fallback returns non-zero at EOF, which under the CLI's
  # set -e killed the command mid-prompt rather than treating "no answer" as
  # the safe answer.
  run bash -c 'set -euo pipefail; export PATH="'"$MOCK_BIN"':$PATH"; source "'"$CLI"'"; cmd_nuke < /dev/null'
  assert_success
  assert_output --partial "Aborted"
}
