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

# ── _read_bounded / _path_size ──────────────────────────────────────────────

@test "_read_bounded: prints the byte window from an offset, capped at the limit" {
  printf '0123456789' > "$TEST_TEMP/f"
  run _read_bounded "$TEST_TEMP/f" 100
  assert_output "0123456789"
  run _read_bounded "$TEST_TEMP/f" 100 4
  assert_output "3456789"
  run _read_bounded "$TEST_TEMP/f" 3
  assert_output "012"
  run _read_bounded "$TEST_TEMP/f" 3 4
  assert_output "345"
  run _read_bounded "$TEST_TEMP/f" 100 11
  assert_success
  assert_output ""
}

@test "_read_bounded: a FIFO, a link to a device and a missing path read as nothing at once" {
  # Refused by the -f gate before a read starts, so no bound is spent on them.
  # The stand-in makes a read that did start visible.
  _run_bounded() { echo "READ $*"; }
  mkfifo "$TEST_TEMP/fifo"
  ln -s /dev/zero "$TEST_TEMP/zero"
  run _read_bounded "$TEST_TEMP/fifo" 100
  assert_success
  assert_output ""
  run _read_bounded "$TEST_TEMP/zero" 100 5
  assert_success
  assert_output ""
  run _read_bounded "$TEST_TEMP/missing" 100
  assert_success
  assert_output ""
  # A regular file does reach the read, which is what makes the empty output
  # above mean refused.
  printf 'x' > "$TEST_TEMP/reg"
  run _read_bounded "$TEST_TEMP/reg" 100
  assert_output --partial "READ"
}

@test "_read_bounded: returns 0 under errexit and pipefail when its reader stops early" {
  # The binary runs under set -euo pipefail. A reader that stops early (grep -q,
  # a break) SIGPIPEs the producer, and that status must not stand for the
  # pipeline's or end the caller. Both branches, in a fresh strict shell.
  head -c 600000 /dev/zero | tr '\0' 'x' > "$TEST_TEMP/big"
  local fns; fns="$(declare -f _read_bounded _run_bounded _bounded_argv)"
  run bash -c "$fns
    _BOX_FILE_READ_SECS=5
    set -euo pipefail
    _read_bounded '$TEST_TEMP/big' 1048576 | head -c 1 >/dev/null
    echo \"head=\${PIPESTATUS[0]}\"
    _read_bounded '$TEST_TEMP/big' 1048576 7 | head -c 1 >/dev/null
    echo \"tail=\${PIPESTATUS[0]}\""
  assert_success
  assert_output $'head=0\ntail=0'
}

@test "_path_size: sizes a regular file and reads a FIFO, a device link or a missing path as 0" {
  printf 'hello' > "$TEST_TEMP/reg"
  mkfifo "$TEST_TEMP/fifo"
  ln -s /dev/zero "$TEST_TEMP/zero"
  run _path_size "$TEST_TEMP/reg"
  assert_output "5"
  # In a bounded shell, so a size read that opened the FIFO fails the test
  # rather than hanging it.
  run _portable_timeout 5 bash -c "$(declare -f _path_size); _path_size '$TEST_TEMP/fifo'" 3>&-
  assert_success
  assert_output "0"
  run _path_size "$TEST_TEMP/zero"
  assert_output "0"
  run _path_size "$TEST_TEMP/missing"
  assert_output "0"
}
