#!/usr/bin/env bats
# Boxes — per-box runtime behavior in cmd_run (see concept/20-boxes.md).
# Phase 3: per-box session state + the sh.cleat.box container label.
#
# These drive cmd_run with the box set via the session-scoped _BOX global
# (exactly as the dispatch sets it). bats `run` forks a subshell that inherits
# _BOX from the test shell, so cmd_run sees the box we set here.
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

@test "box run: a named box creates a -<box> suffixed container" {
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project"
  _BOX="az"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project" az)"
  [[ "$cname" == *-az ]] || { echo "cname=$cname"; return 1; }

  run cmd_run "$TEST_TEMP/project"
  assert_success
  run assert_docker_run_has "$cname" "--name $cname"
  assert_success
}

@test "box run: the docker run carries the sh.cleat.box label" {
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project"
  _BOX="az"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project" az)"

  run cmd_run "$TEST_TEMP/project"
  assert_success
  run assert_docker_run_has "$cname" "sh.cleat.box=az"
  assert_success
}

@test "box run: the default (main) box labels sh.cleat.box=main" {
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project"
  # _BOX defaults to "main" via the sourced top-level assignment.
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"

  run cmd_run "$TEST_TEMP/project"
  assert_success
  run assert_docker_run_has "$cname" "sh.cleat.box=main"
  assert_success
}

@test "box run: a named box gets its own session overlay dir (not the default's)" {
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project"
  _BOX="az"
  local cname key
  cname="$(container_name_for "$TEST_TEMP/project" az)"
  key="$(_derive_project_session_key "$TEST_TEMP/project" az)"
  [[ "$key" == *-az ]] || { echo "key=$key"; return 1; }

  run cmd_run "$TEST_TEMP/project"
  assert_success
  # The per-project session overlay source must be keyed by the BOX key
  # (<basename>-<hash>-az), so the az box never shares sessions with main.
  run assert_docker_run_has "$cname" "${key}:/home/coder/.claude/projects/-workspace"
  assert_success
}

@test "box run: the default box session overlay is byte-identical to legacy (no -main)" {
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project"
  local cname legacy_key
  cname="$(container_name_for "$TEST_TEMP/project")"
  legacy_key="$(basename "$TEST_TEMP/project" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g')-$(echo -n "$TEST_TEMP/project" | _md5 | head -c 8)"

  run cmd_run "$TEST_TEMP/project"
  assert_success
  run assert_docker_run_has "$cname" "${legacy_key}:/home/coder/.claude/projects/-workspace"
  assert_success
  # It must NOT carry a -main-suffixed session key.
  run assert_docker_run_lacks "$cname" "${legacy_key}-main"
  assert_success
}

@test "box run: two boxes on one project get distinct session keys and containers" {
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project"

  _BOX="az"
  run cmd_run "$TEST_TEMP/project"
  assert_success

  _BOX="dev"
  run cmd_run "$TEST_TEMP/project"
  assert_success

  local az_cname dev_cname az_key dev_key
  az_cname="$(container_name_for "$TEST_TEMP/project" az)"
  dev_cname="$(container_name_for "$TEST_TEMP/project" dev)"
  az_key="$(_derive_project_session_key "$TEST_TEMP/project" az)"
  dev_key="$(_derive_project_session_key "$TEST_TEMP/project" dev)"
  [[ "$az_cname" != "$dev_cname" ]] || return 1
  [[ "$az_key" != "$dev_key" ]] || return 1
  run assert_docker_run_has "$az_cname" "--name $az_cname"
  assert_success
  run assert_docker_run_has "$dev_cname" "--name $dev_cname"
  assert_success
}
