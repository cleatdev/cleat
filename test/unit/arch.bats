#!/usr/bin/env bats
# Architecture awareness. The prebuilt GHCR image was amd64-only for every
# release through v0.15.1, so Apple Silicon users who pulled it ran every box
# under emulation, slow, and the documented trigger for node segfaults and
# garbled TTYs (Docker calls amd64-on-arm "best effort"). The CLI must:
#   - pin pulls to the daemon's architecture (a wrong single-arch manifest
#     then fails loudly into the native local-build fallback),
#   - refuse to reuse a cached image of the wrong arch (treat as missing),
#   - fail OPEN whenever the daemon or image arch can't be determined.

load "../setup"

setup() {
  _common_setup
  use_docker_stub
  source_cli
}

teardown() { _common_teardown; }

# ── _image_arch_ok decision logic ────────────────────────────────────────────

@test "arch: _image_arch_ok passes when image matches the daemon" {
  _daemon_arch() { echo "arm64"; }
  _image_arch() { echo "arm64"; }
  run _image_arch_ok "cleat"
  assert_success
}

@test "arch: _image_arch_ok fails when the image would run emulated" {
  _daemon_arch() { echo "arm64"; }
  _image_arch() { echo "amd64"; }
  run _image_arch_ok "cleat"
  assert_failure
}

@test "arch: _image_arch_ok fails open when the daemon arch is unknown" {
  _daemon_arch() { echo ""; }
  _image_arch() { echo "amd64"; }
  run _image_arch_ok "cleat"
  assert_success
}

@test "arch: _image_arch_ok fails open when the image arch is unknown" {
  _daemon_arch() { echo "arm64"; }
  _image_arch() { echo ""; }
  run _image_arch_ok "cleat"
  assert_success
}

# ── pull pinning ─────────────────────────────────────────────────────────────

@test "arch: pull pins --platform to the daemon arch" {
  _daemon_arch() { echo "arm64"; }
  export DOCKER_PULL_EXIT_CODE=0
  run _do_pull
  assert_success
  run grep "^docker pull --platform linux/arm64 " "$DOCKER_CALLS"
  assert_success
}

@test "arch: pull reports the pulled arch" {
  _daemon_arch() { echo "arm64"; }
  export DOCKER_PULL_EXIT_CODE=0
  run _do_pull
  assert_success
  assert_output --partial "arm64"
}

@test "arch: pull omits --platform when the daemon arch is unknown" {
  _daemon_arch() { echo ""; }
  export DOCKER_PULL_EXIT_CODE=0
  run _do_pull
  assert_success
  run grep "^docker pull --platform" "$DOCKER_CALLS"
  assert_failure
  run grep "^docker pull " "$DOCKER_CALLS"
  assert_success
}

# ── cache short-circuit ──────────────────────────────────────────────────────

@test "arch: an arch-mismatched cached prebuilt does not short-circuit the pull" {
  # An amd64 ghcr image cached before multi-arch publishing must not be
  # retagged into service on an arm64 daemon: the platform-pinned pull
  # replaces it with the native half of the (re-published) manifest.
  mock_docker_image_cached "${REGISTRY_BASE}:v${VERSION}"
  _daemon_arch() { echo "arm64"; }
  _image_arch() { echo "amd64"; }
  export DOCKER_PULL_EXIT_CODE=0
  run _do_pull
  assert_success
  refute_output --partial "cached v"
  run grep "^docker pull " "$DOCKER_CALLS"
  assert_success
}

@test "arch: an arch-matching cached prebuilt short-circuits without network" {
  mock_docker_image_cached "${REGISTRY_BASE}:v${VERSION}"
  _daemon_arch() { echo "arm64"; }
  _image_arch() { echo "arm64"; }
  run _do_pull
  assert_success
  assert_output --partial "cached v"
  run grep "^docker pull " "$DOCKER_CALLS"
  assert_failure
}

# ── acquisition gates ────────────────────────────────────────────────────────
# These drive the REAL gate (_image_arch_ok composed from the two probes) so
# they also pin the user-facing explanation of why the image is re-fetched:
# _warn_image_emulated builds its message from the same probes.

@test "arch: cmd_run re-acquires a wrong-arch image and says why" {
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project"
  _daemon_arch() { echo "arm64"; }
  _image_arch() { echo "amd64"; }
  _do_pull() { echo "PULL_CALLED"; }
  run cmd_run "$TEST_TEMP/project"
  assert_success
  assert_output --partial "PULL_CALLED"
  assert_output --partial "fetching a native image"
  refute_output --partial "(cached)"
}

@test "arch: cmd_build re-acquires a wrong-arch image and says why" {
  mock_docker_images "cleat"
  _daemon_arch() { echo "arm64"; }
  _image_arch() { echo "amd64"; }
  _do_pull() { echo "PULL_CALLED"; }
  run cmd_build
  assert_success
  assert_output --partial "PULL_CALLED"
  assert_output --partial "fetching a native image"
  refute_output --partial "(cached)"
}

@test "arch: cmd_build reuses a matching-arch image" {
  mock_docker_images "cleat"
  _image_arch_ok() { return 0; }
  _do_pull() { echo "PULL_CALLED"; }
  run cmd_build
  assert_success
  assert_output --partial "(cached)"
  refute_output --partial "PULL_CALLED"
}

# ── status surfacing ─────────────────────────────────────────────────────────
# An emulated image is the documented trigger for node crashes and garbled
# TTYs: `cleat status` must say so loudly, and must NOT cry wolf on a
# native image.

@test "arch: status flags an emulated image and promises a native re-fetch" {
  mkdir -p "$TEST_TEMP/project"
  mock_docker_images "cleat"
  _image_arch() { echo "amd64"; }
  _daemon_arch() { echo "arm64"; }
  run cmd_status "$TEST_TEMP/project"
  assert_success
  assert_output --partial "EMULATED on arm64"
  assert_output --partial "next start fetches native"
}

@test "arch: status shows a native image without the emulation warning" {
  mkdir -p "$TEST_TEMP/project"
  mock_docker_images "cleat"
  _image_arch() { echo "arm64"; }
  _daemon_arch() { echo "arm64"; }
  run cmd_status "$TEST_TEMP/project"
  assert_success
  assert_output --partial "(arm64, "
  refute_output --partial "EMULATED"
}
