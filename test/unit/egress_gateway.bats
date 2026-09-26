#!/usr/bin/env bats
# The egress gateway's lifecycle (EGRESS-SPEC.md 8): its image, its creation
# beside a caged box, teardown and stop at every removal and stop site, the
# idle sweep and the volumes it owns.
load "../setup"

setup() {
  _common_setup
  use_docker_stub
  source_cli
  _BOX=main
}
teardown() { _common_teardown; }

# ── The image (8.0) ─────────────────────────────────────────────────────────

@test "egress: the gateway image reference is a digest and never a tag" {
  [[ "$_GATEWAY_IMAGE" =~ ^ghcr\.io/cleatdev/cleat-gw@sha256:[0-9a-f]{64}$ ]]
}

@test "egress: a present gateway image produces no pull" {
  printf '%s\n' "$_GATEWAY_IMAGE" > "$DOCKER_MOCK_DIR/cached_images"
  run _egress_gateway_image_ensure
  assert_success
  assert_output ""
  run grep -c '^docker pull' "$DOCKER_CALLS"
  assert_output "0"
}

@test "egress: a missing gateway image is pulled once, pinned to the daemon's architecture" {
  _daemon_arch() { printf arm64; }
  export DOCKER_PULL_EXIT_CODE=0
  run _egress_gateway_image_ensure
  assert_success
  run grep -c '^docker pull' "$DOCKER_CALLS"
  assert_output "1"
  run grep -F -- "docker pull --platform linux/arm64 $_GATEWAY_IMAGE" "$DOCKER_CALLS"
  assert_success
}

@test "egress: a missing gateway image refuses the launch and names the image" {
  export DOCKER_PULL_EXIT_CODE=1
  run _egress_gateway_image_ensure
  assert_failure
  assert_output --partial "could not be pulled: $_GATEWAY_IMAGE"
  assert_output --partial "This is not a policy denial."
}

@test "egress: the gateway image pull shows one line off a terminal and a forced pull pulls a present image" {
  export DOCKER_PULL_EXIT_CODE=0
  run _egress_gateway_image_ensure
  assert_success
  assert_output --partial "Pulling the egress gateway image"
  run bash -c 'printf "%s\n" "$1" | grep -c .' _ "$output"
  assert_output "1"
  printf '%s\n' "$_GATEWAY_IMAGE" > "$DOCKER_MOCK_DIR/cached_images"
  : > "$DOCKER_CALLS"
  run _egress_gateway_image_ensure force
  assert_success
  run grep -c '^docker pull' "$DOCKER_CALLS"
  assert_output "1"
}
