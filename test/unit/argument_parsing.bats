#!/usr/bin/env bats
load "../setup"
setup() {
  _common_setup
  use_docker_stub
  source_cli
}
teardown() { _common_teardown; }

@test "help: -h, --help, and help all work" {
  for flag in help -h --help; do
    run main $flag
    assert_success
    assert_output --partial "USAGE"
  done
}

@test "version: -v, --version, and version all work" {
  for flag in version -v --version; do
    run main $flag
    assert_success
    assert_output --partial "$VERSION"
  done
}

@test "aliases: r → resume, sh → shell, st → status" {
  run main r
  assert_failure
  assert_output --partial "No container found"

  run main sh
  assert_failure
  assert_output --partial "not running"

  run main st
  assert_success
  assert_output --partial "Project:"
}

@test "unknown command: exits 1 with error and help" {
  run main foobar
  assert_failure
  assert_output --partial "Unknown command: foobar"
  assert_output --partial "USAGE"
}
