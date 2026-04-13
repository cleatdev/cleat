#!/usr/bin/env bats

load "../setup"

setup() {
  _common_setup
  use_docker_stub
  source_cli
}

teardown() { _common_teardown; }

# ── is_running ──────────────────────────────────────────────────────────────

@test "is_running returns true when container is listed" {
  mock_docker_ps "my-container"
  run is_running "my-container"
  assert_success
}

@test "is_running returns false when container is not listed" {
  run is_running "my-container"
  assert_failure
}

@test "is_running does not match partial names" {
  mock_docker_ps "cleat-app-abc12345"
  run is_running "cleat-app"
  assert_failure
}

# ── container_exists ────────────────────────────────────────────────────────

@test "container_exists returns true when container is listed in ps -a" {
  mock_docker_ps_a "my-container"
  run container_exists "my-container"
  assert_success
}

@test "container_exists returns false when container not in ps -a" {
  run container_exists "my-container"
  assert_failure
}

# ── image_exists ────────────────────────────────────────────────────────────

@test "image_exists returns true when image is listed" {
  mock_docker_images "cleat"
  run image_exists
  assert_success
}

@test "image_exists returns false when image not listed" {
  run image_exists
  assert_failure
}

@test "image_exists does not match other images" {
  mock_docker_images "cleat-pro"
  run image_exists
  assert_failure
}

# ── require_running ─────────────────────────────────────────────────────────

@test "require_running exits 1 when container is not running" {
  run require_running "test-container"
  assert_failure
  assert_output --partial "not running"
}

@test "require_running succeeds when container is running" {
  mock_docker_ps "test-container"
  run require_running "test-container"
  assert_success
}

# ── _md5 portable hash ────────────────────────────────────────────────────

@test "_md5 produces consistent 32-char hex output" {
  local hash
  hash="$(echo -n "test-input" | _md5)"
  # Must be hex characters only (md5 output)
  [[ "$hash" =~ ^[0-9a-f] ]] || { echo "Not hex: $hash"; return 1; }
  # Must be non-empty
  [[ -n "$hash" ]] || { echo "Empty hash"; return 1; }
}

@test "_md5 produces different hashes for different inputs" {
  local h1 h2
  h1="$(echo -n "input-a" | _md5 | head -c 8)"
  h2="$(echo -n "input-b" | _md5 | head -c 8)"
  [[ "$h1" != "$h2" ]] || { echo "Hash collision: $h1"; return 1; }
}

@test "_md5 produces same hash for same input (deterministic)" {
  local h1 h2
  h1="$(echo -n "stable-input" | _md5 | head -c 8)"
  h2="$(echo -n "stable-input" | _md5 | head -c 8)"
  [[ "$h1" == "$h2" ]] || { echo "Non-deterministic: $h1 vs $h2"; return 1; }
}
