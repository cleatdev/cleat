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
  # `r` dispatches to cmd_resume, which after v0.10.0 creates the container
  # when none exists (sessions persist on host). Verify the alias reaches
  # cmd_resume by checking for its distinctive output line.
  mock_docker_images "cleat"
  run main r
  assert_success
  assert_output --partial "creating fresh"

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

# ── Global flags: --cap, --env, --env-file ──────────────────────────────────

@test "parse_global_flags: extracts --cap flag" {
  parse_global_flags --cap git start
  [[ ${#_CLI_CAPS[@]} -eq 1 ]]
  [[ "${_CLI_CAPS[0]}" == "git" ]]
  [[ ${#_REMAINING_ARGS[@]} -eq 1 ]]
  [[ "${_REMAINING_ARGS[0]}" == "start" ]]
}

@test "parse_global_flags: extracts multiple --cap flags" {
  parse_global_flags --cap git --cap env start
  [[ ${#_CLI_CAPS[@]} -eq 2 ]]
  [[ "${_CLI_CAPS[0]}" == "git" ]]
  [[ "${_CLI_CAPS[1]}" == "env" ]]
}

@test "parse_global_flags: extracts --env KEY=VALUE" {
  parse_global_flags --env FOO=bar start
  [[ ${#_CLI_ENVS[@]} -eq 1 ]]
  [[ "${_CLI_ENVS[0]}" == "FOO=bar" ]]
}

@test "parse_global_flags: extracts --env bare KEY" {
  parse_global_flags --env MY_VAR start
  [[ ${#_CLI_ENVS[@]} -eq 1 ]]
  [[ "${_CLI_ENVS[0]}" == "MY_VAR" ]]
}

@test "parse_global_flags: extracts --env-file path" {
  parse_global_flags --env-file /tmp/test.env start
  [[ ${#_CLI_ENV_FILES[@]} -eq 1 ]]
  [[ "${_CLI_ENV_FILES[0]}" == "/tmp/test.env" ]]
}

@test "parse_global_flags: mixed flags and commands" {
  parse_global_flags --cap git --env TOKEN=abc --env-file /tmp/e.env resume /some/path
  [[ ${#_CLI_CAPS[@]} -eq 1 ]]
  [[ ${#_CLI_ENVS[@]} -eq 1 ]]
  [[ ${#_CLI_ENV_FILES[@]} -eq 1 ]]
  [[ ${#_REMAINING_ARGS[@]} -eq 2 ]]
  [[ "${_REMAINING_ARGS[0]}" == "resume" ]]
  [[ "${_REMAINING_ARGS[1]}" == "/some/path" ]]
}

@test "parse_global_flags: --cap without value fails" {
  run parse_global_flags --cap
  assert_failure
  assert_output --partial "Missing capability name"
}

@test "parse_global_flags: --env without value fails" {
  run parse_global_flags --env
  assert_failure
  assert_output --partial "Missing value"
}

@test "parse_global_flags: --env-file without value fails" {
  run parse_global_flags --env-file
  assert_failure
  assert_output --partial "Missing path"
}

@test "parse_global_flags: --cap rejects unknown capability" {
  run parse_global_flags --cap foobar start
  assert_failure
  assert_output --partial "Unknown capability"
}

@test "parse_global_flags: no flags passes everything through" {
  parse_global_flags start /my/project
  [[ ${#_CLI_CAPS[@]} -eq 0 ]]
  [[ ${#_CLI_ENVS[@]} -eq 0 ]]
  [[ ${#_CLI_ENV_FILES[@]} -eq 0 ]]
  [[ ${#_REMAINING_ARGS[@]} -eq 2 ]]
}

@test "config command: reachable via main" {
  # Ensure 'config' is dispatched properly
  CLEAT_CONFIG_DIR="$TEST_TEMP/cleat-config"
  CLEAT_GLOBAL_CONFIG="$CLEAT_CONFIG_DIR/config"
  mkdir -p "$CLEAT_CONFIG_DIR"
  run main config --list
  assert_success
  assert_output --partial "Capabilities"
}

@test "help: shows CAPABILITIES section" {
  run cmd_help
  assert_success
  assert_output --partial "CAPABILITIES"
  assert_output --partial "config"
  assert_output --partial "--enable"
}

@test "help: shows FLAGS section" {
  run cmd_help
  assert_success
  assert_output --partial "FLAGS"
  assert_output --partial "--cap"
  assert_output --partial "--env"
  assert_output --partial "--env-file"
}
