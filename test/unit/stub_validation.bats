#!/usr/bin/env bats
# ─────────────────────────────────────────────────────────────────────────────
# Docker stub validation tests.
#
# These verify the hardened docker stub actually rejects malformed commands
# when strict modes are enabled. Each test turns on a specific strict mode
# and runs a real cleat invocation that should be caught by the validator.
#
# This adds a second level of defense: if cleat ever generates a malformed
# docker command in a future version, these tests will catch it even if the
# code-level tests don't, because the stub itself refuses to accept it.
# ─────────────────────────────────────────────────────────────────────────────

load "../setup"

setup() {
  _common_setup
  export HOME="$TEST_TEMP/home"
  mkdir -p "$HOME/.claude"
  export XDG_CONFIG_HOME="$TEST_TEMP/xdg-config"
  mkdir -p "$XDG_CONFIG_HOME/cleat"
  export PATH="$MOCK_BIN:$PATH"
  printf '' > "$DOCKER_MOCK_DIR/ps_output"
  printf '' > "$DOCKER_MOCK_DIR/ps_a_output"
  printf 'cleat\n' > "$DOCKER_MOCK_DIR/images_output"
}

teardown() {
  _common_teardown
}

# Helper: run a mutated docker command through the stub directly
run_docker_stub() {
  env \
    DOCKER_CALLS="$DOCKER_CALLS" \
    DOCKER_MOCK_DIR="$DOCKER_MOCK_DIR" \
    DOCKER_STUB_STRICT="${DOCKER_STUB_STRICT:-}" \
    DOCKER_STUB_SIMULATE_VIRTIOFS="${DOCKER_STUB_SIMULATE_VIRTIOFS:-}" \
    "$MOCK_BIN/docker" "$@"
}

# ── Strict mode: bind mount source must exist ──────────────────────────────

@test "stub strict: rejects docker run -v with nonexistent source" {
  export DOCKER_STUB_STRICT=1
  run run_docker_stub run -v "/nonexistent/path:/workspace" test-image
  assert_failure
  assert_output --partial "bind source path does not exist"
}

@test "stub strict: accepts docker run -v with existing source" {
  export DOCKER_STUB_STRICT=1
  mkdir -p "$TEST_TEMP/src"
  run run_docker_stub run -v "$TEST_TEMP/src:/workspace" test-image
  assert_success
}

@test "stub strict: accepts docker run -v with :ro flag" {
  export DOCKER_STUB_STRICT=1
  mkdir -p "$TEST_TEMP/src"
  run run_docker_stub run -v "$TEST_TEMP/src:/workspace:ro" test-image
  assert_success
}

@test "stub strict: rejects unknown mount flag" {
  export DOCKER_STUB_STRICT=1
  mkdir -p "$TEST_TEMP/src"
  run run_docker_stub run -v "$TEST_TEMP/src:/workspace:totally-bogus" test-image
  assert_failure
  assert_output --partial "unknown flag"
}

@test "stub strict: rejects relative destination path" {
  export DOCKER_STUB_STRICT=1
  mkdir -p "$TEST_TEMP/src"
  run run_docker_stub run -v "$TEST_TEMP/src:relative/dest" test-image
  assert_failure
  assert_output --partial "destination path must be absolute"
}

@test "stub strict: accepts named volumes (non-absolute source)" {
  export DOCKER_STUB_STRICT=1
  run run_docker_stub run -v "my-named-volume:/data" test-image
  assert_success
}

# ── virtiofs simulation: mount target inside bind mount must exist on host ──

@test "stub virtiofs: rejects nested bind-mount when target file missing on host" {
  export DOCKER_STUB_SIMULATE_VIRTIOFS=1
  mkdir -p "$TEST_TEMP/project/.claude"
  echo '{}' > "$TEST_TEMP/overlay.json"
  # /workspace bind-mounted from $TEST_TEMP/project, overlay mounted to
  # /workspace/.claude/settings.json, but .claude/settings.json doesn't exist
  # on the host — this is the v0.6.5 bug.
  run run_docker_stub run \
    -v "$TEST_TEMP/project:/workspace" \
    -v "$TEST_TEMP/overlay.json:/workspace/.claude/settings.json" \
    test-image
  assert_failure
  assert_output --partial "outside of rootfs"
}

@test "stub virtiofs: accepts nested bind-mount when target file exists on host" {
  export DOCKER_STUB_SIMULATE_VIRTIOFS=1
  mkdir -p "$TEST_TEMP/project/.claude"
  echo '{}' > "$TEST_TEMP/project/.claude/settings.json"
  echo '{}' > "$TEST_TEMP/overlay.json"
  run run_docker_stub run \
    -v "$TEST_TEMP/project:/workspace" \
    -v "$TEST_TEMP/overlay.json:/workspace/.claude/settings.json" \
    test-image
  assert_success
}

@test "stub virtiofs: accepts non-nested bind mounts" {
  export DOCKER_STUB_SIMULATE_VIRTIOFS=1
  mkdir -p "$TEST_TEMP/project"
  echo '{}' > "$TEST_TEMP/overlay.json"
  run run_docker_stub run \
    -v "$TEST_TEMP/project:/workspace" \
    -v "$TEST_TEMP/overlay.json:/etc/something-not-under-workspace" \
    test-image
  assert_success
}

# ── End-to-end: virtiofs simulation catches the v0.6.5 regression ─────────
# This is the critical test: if v0.6.5 is reverted in bin/cleat, this test
# must fail because the stub simulates the actual macOS failure mode.

@test "stub virtiofs e2e: cleat start succeeds with v0.6.5 fix (project overlay skipped)" {
  export DOCKER_STUB_SIMULATE_VIRTIOFS=1
  cat > "$XDG_CONFIG_HOME/cleat/config" << 'EOF'
[caps]
hooks
EOF
  # Satisfy the global settings overlay (unrelated to v0.6.5) — the host file
  # must exist for virtiofs to accept the nested mount. See stub_validation
  # note at end of file for the separate global-overlay issue.
  echo '{}' > "$HOME/.claude/settings.json"

  mkdir -p "$TEST_TEMP/project/.claude"
  # .claude/ exists but neither settings.json nor settings.local.json —
  # the exact v0.6.5 trigger condition.

  run _portable_timeout 5 env \
    PATH="$MOCK_BIN:$PATH" \
    HOME="$HOME" \
    XDG_CONFIG_HOME="$XDG_CONFIG_HOME" \
    DOCKER_CALLS="$DOCKER_CALLS" \
    DOCKER_MOCK_DIR="$DOCKER_MOCK_DIR" \
    DOCKER_STUB_SIMULATE_VIRTIOFS=1 \
    "$CLI" start "$TEST_TEMP/project"

  # With the v0.6.5 fix, the project overlay is never mounted for missing
  # files, so virtiofs simulation has nothing to reject.
  refute_output --partial "outside of rootfs"
}

# ─────────────────────────────────────────────────────────────────────────────
# FINDING: The global settings overlay at line 1362 of bin/cleat has the
# same structural risk as v0.6.5. It mounts
#   $settings_overlay_dir/settings.json → /home/coder/.claude/settings.json
# while simultaneously mounting
#   $HOME/.claude → /home/coder/.claude
# On macOS Docker Desktop virtiofs, if $HOME/.claude/settings.json doesn't
# exist on the host, the nested mount will fail. This only affects brand-new
# installs that have never run Claude Code. The virtiofs stub catches it;
# see the test below which intentionally omits the host file.
# ─────────────────────────────────────────────────────────────────────────────

@test "stub virtiofs: finding — global overlay fails when ~/.claude/settings.json missing" {
  export DOCKER_STUB_SIMULATE_VIRTIOFS=1
  # Deliberately do NOT create $HOME/.claude/settings.json
  mkdir -p "$TEST_TEMP/project"
  cat > "$XDG_CONFIG_HOME/cleat/config" << 'EOF'
[caps]
hooks
EOF

  run _portable_timeout 5 env \
    PATH="$MOCK_BIN:$PATH" \
    HOME="$HOME" \
    XDG_CONFIG_HOME="$XDG_CONFIG_HOME" \
    DOCKER_CALLS="$DOCKER_CALLS" \
    DOCKER_MOCK_DIR="$DOCKER_MOCK_DIR" \
    DOCKER_STUB_SIMULATE_VIRTIOFS=1 \
    "$CLI" start "$TEST_TEMP/project"

  # This test documents the finding: when $HOME/.claude/settings.json does
  # not exist, cleat currently mounts an overlay over it anyway, which would
  # fail on real macOS virtiofs. Until this is fixed, the test confirms the
  # stub correctly identifies the issue.
  assert_output --partial "outside of rootfs"
}

# ── DOCKER_STUB_STRICT doesn't break default tests ─────────────────────────

@test "stub permissive (default): silently accepts missing bind source" {
  unset DOCKER_STUB_STRICT DOCKER_STUB_SIMULATE_VIRTIOFS
  run run_docker_stub run -v "/nonexistent:/workspace" test-image
  assert_success
}

# ── ps / ps -a routing: token-bounded match for `-a` flag ───────────────────
#
# A naive `[[ "$*" == *"-a"* ]]` substring match falsely fires when the
# container name contains '-a' (e.g. `cleat-project-a1b2c3d4` — ~1/16 of
# random hashes start with 'a'), routing plain `docker ps` calls to
# ps_a_output and breaking the is_running / container_exists distinction.
# This pinned pair of tests guards the token-bounded match in the stub.

@test "stub ps routing: docker ps without -a returns ps_output even when filter contains '-a' substring" {
  printf 'this-is-ps-output\n'    > "$DOCKER_MOCK_DIR/ps_output"
  printf 'this-is-ps-a-output\n'  > "$DOCKER_MOCK_DIR/ps_a_output"
  # Container name with embedded '-a' — used to flake when the hash started with 'a'.
  run run_docker_stub ps --filter 'name=^cleat-project-a1b2c3d4$' --format '{{.Names}}'
  assert_success
  assert_output "this-is-ps-output"
  refute_output --partial "ps-a-output"
}

@test "stub ps routing: docker ps -a returns ps_a_output" {
  printf 'this-is-ps-output\n'    > "$DOCKER_MOCK_DIR/ps_output"
  printf 'this-is-ps-a-output\n'  > "$DOCKER_MOCK_DIR/ps_a_output"
  run run_docker_stub ps -a --filter 'name=^cleat-project-a1b2c3d4$' --format '{{.Names}}'
  assert_success
  assert_output "this-is-ps-a-output"
}

@test "stub ps routing: docker ps --all returns ps_a_output" {
  printf 'this-is-ps-output\n'    > "$DOCKER_MOCK_DIR/ps_output"
  printf 'this-is-ps-a-output\n'  > "$DOCKER_MOCK_DIR/ps_a_output"
  run run_docker_stub ps --all --filter 'name=^cleat-project-12345678$' --format '{{.Names}}'
  assert_success
  assert_output "this-is-ps-a-output"
}
