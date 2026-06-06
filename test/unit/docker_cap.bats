#!/usr/bin/env bats
# Docker capability — per-session socket-access self-heal + dead-socket recovery
# guidance (see concept/15-docker-capability.md). The entrypoint resolves the
# socket group once at start; a Docker Desktop restart can change the socket GID
# under a long-running container, and a bare `docker exec` never re-runs the
# entrypoint — so each session exec re-resolves it as root before dropping to
# coder. These tests exercise that runtime path (the entrypoint's own copy of
# the logic is covered by the real-Docker integration test).
load "../setup"
setup() {
  _common_setup
  use_docker_stub
  source_cli
  CLEAT_CONFIG_DIR="$TEST_TEMP/cleat-config"
  CLEAT_GLOBAL_CONFIG="$CLEAT_CONFIG_DIR/config"
  CLEAT_GLOBAL_ENV="$CLEAT_CONFIG_DIR/env"
  mkdir -p "$CLEAT_CONFIG_DIR"
  _host_clip_cmd() { echo ""; }
  check_for_update() { true; }
  check_drift() { true; }
  _resolve_config_drift() { true; }
}
teardown() { _common_teardown; }

@test "docker-cap heal: _ensure_docker_access is a no-op when the docker cap is off" {
  ACTIVE_CAPS=()
  run _ensure_docker_access "cleat-fake-12345678"
  assert_success
  run grep -c 'docker exec' "$DOCKER_CALLS"
  assert_output "0"
}

@test "docker-cap heal: re-resolves the socket group (root exec) when the cap is on" {
  ACTIVE_CAPS=(docker)
  run _ensure_docker_access "cleat-fake-12345678"
  assert_success
  run assert_docker_exec_has "groupmod"
  assert_success
  run assert_docker_exec_has "usermod -aG"
  assert_success
}

@test "docker-cap heal: the heal exec runs as root (-u 0) on the right container" {
  ACTIVE_CAPS=(docker)
  run _ensure_docker_access "cleat-target-abcdef12"
  assert_success
  run assert_docker_exec_has "exec -u 0 cleat-target-abcdef12"
  assert_success
}

@test "docker-cap heal: a dead socket (root probe fails) prints recovery guidance" {
  ACTIVE_CAPS=(docker)
  local stubs="$TEST_TEMP/deadsock"; mkdir -p "$stubs"
  # docker stub: succeed on the heal exec, FAIL on `docker version` (dead socket)
  printf '#!/bin/sh\ncase " $* " in *" version"*) exit 1 ;; *) exit 0 ;; esac\n' > "$stubs/docker"
  chmod +x "$stubs/docker"
  PATH="$stubs:$PATH" run _ensure_docker_access "cleat-fake-12345678"
  assert_output --partial "cleat stop && cleat resume"
}

@test "docker-cap heal: a live socket (probe OK) prints NO recovery guidance" {
  ACTIVE_CAPS=(docker)
  run _ensure_docker_access "cleat-fake-12345678"
  assert_success
  refute_output --partial "cleat stop && cleat resume"
}

@test "docker-cap heal: cleat shell self-heals the socket group when the cap is active" {
  mkdir -p "$TEST_TEMP/project"
  printf '[caps]\ndocker\n' > "$CLEAT_GLOBAL_CONFIG"
  local cname; cname="$(container_name_for "$TEST_TEMP/project")"
  mock_docker_ps "$cname"; mock_docker_ps_a "$cname"
  run cmd_shell "$TEST_TEMP/project"
  run assert_docker_exec_has "usermod -aG"
  assert_success
}

@test "docker-cap heal: cleat shell does NOT self-heal when the docker cap is off" {
  mkdir -p "$TEST_TEMP/project"
  : > "$CLEAT_GLOBAL_CONFIG"
  local cname; cname="$(container_name_for "$TEST_TEMP/project")"
  mock_docker_ps "$cname"; mock_docker_ps_a "$cname"
  run cmd_shell "$TEST_TEMP/project"
  run grep -c 'usermod' "$DOCKER_CALLS"
  assert_output "0"
}
