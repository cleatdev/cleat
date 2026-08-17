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
  # on the host: this is the v0.6.5 bug.
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
  # Satisfy the global settings overlay (unrelated to v0.6.5): the host file
  # must exist for virtiofs to accept the nested mount. See stub_validation
  # note at end of file for the separate global-overlay issue.
  echo '{}' > "$HOME/.claude/settings.json"

  mkdir -p "$TEST_TEMP/project/.claude"
  # .claude/ exists but neither settings.json nor settings.local.json:
  # the exact v0.6.5 trigger condition.

  cd "$TEST_TEMP/project"
  run _portable_timeout 5 env \
    PATH="$MOCK_BIN:$PATH" \
    HOME="$HOME" \
    XDG_CONFIG_HOME="$XDG_CONFIG_HOME" \
    DOCKER_CALLS="$DOCKER_CALLS" \
    DOCKER_MOCK_DIR="$DOCKER_MOCK_DIR" \
    DOCKER_STUB_SIMULATE_VIRTIOFS=1 \
    "$CLI" start

  # With the v0.6.5 fix, the project overlay is never mounted for missing
  # files, so virtiofs simulation has nothing to reject.
  refute_output --partial "outside of rootfs"
}

# ─────────────────────────────────────────────────────────────────────────────
# FINDING (fixed 2026-07-10): The global settings overlay mounts
#   $settings_overlay_dir/settings.json → /home/coder/.claude/settings.json
# while simultaneously mounting
#   $HOME/.claude → /home/coder/.claude
# On macOS Docker Desktop virtiofs, if $HOME/.claude/settings.json doesn't
# exist on the host, the nested mount fails. This test documented the open
# finding for a long time ("until this is fixed, the test confirms the stub
# correctly identifies the issue"); the integration suite run against a real
# macOS daemon reproduced it on 2026-07-10 and cmd_run now pre-creates the
# target as '{}' next to the history.jsonl touch. The test below now asserts
# the FIX at the real-binary e2e layer; the canonical mutation-anchored guard
# is "regression v1.1.1: fresh host without ~/.claude/settings.json" in
# regressions.bats, and the stub's own rejection machinery stays covered by
# the synthetic "rejects nested bind-mount when target file missing" test.
# ─────────────────────────────────────────────────────────────────────────────

@test "stub virtiofs e2e: cleat start succeeds without a host ~/.claude/settings.json (target pre-created)" {
  export DOCKER_STUB_SIMULATE_VIRTIOFS=1
  # Deliberately do NOT create $HOME/.claude/settings.json: a fresh host that
  # never ran native claude.
  mkdir -p "$TEST_TEMP/project"
  cat > "$XDG_CONFIG_HOME/cleat/config" << 'EOF'
[caps]
hooks
EOF

  cd "$TEST_TEMP/project"
  run _portable_timeout 5 env \
    PATH="$MOCK_BIN:$PATH" \
    HOME="$HOME" \
    XDG_CONFIG_HOME="$XDG_CONFIG_HOME" \
    DOCKER_CALLS="$DOCKER_CALLS" \
    DOCKER_MOCK_DIR="$DOCKER_MOCK_DIR" \
    DOCKER_STUB_SIMULATE_VIRTIOFS=1 \
    "$CLI" start

  refute_output --partial "outside of rootfs"
  assert_output --partial "Container started"
  # The pre-created target is valid JSON, inert for native claude.
  run cat "$HOME/.claude/settings.json"
  assert_output "{}"
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
# container name contains '-a' (e.g. `cleat-project-a1b2c3d4`, ~1/16 of
# random hashes start with 'a'), routing plain `docker ps` calls to
# ps_a_output and breaking the is_running / container_exists distinction.
# This pinned pair of tests guards the token-bounded match in the stub.

@test "stub ps routing: docker ps without -a returns ps_output even when filter contains '-a' substring" {
  printf 'this-is-ps-output\n'    > "$DOCKER_MOCK_DIR/ps_output"
  printf 'this-is-ps-a-output\n'  > "$DOCKER_MOCK_DIR/ps_a_output"
  # Container name with embedded '-a': used to flake when the hash started with 'a'.
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

# ── The suite and the mutation harness must never run at once ───────────────
# The harness rewrites nine tracked files in place. Anything reading or
# EXECUTING them meanwhile fails for reasons unrelated to any change, and the
# harness reports false MISSED against source someone else restored. Both
# happened for real, including ACROSS MACHINES: a run inside a Cleat box and a
# run on the host share the bind-mounted checkout but not /tmp, which is why
# the lock lives in the repo. See test/lib/testlock.sh.

_lock_lib() { printf '%s\n' "$PROJECT_ROOT/test/lib/testlock.sh"; }

@test "lock: the suite refuses while the harness holds it" {
  export _CLEAT_TEST_LOCK_DIR="$TEST_TEMP/lock"
  mkdir -p "$_CLEAT_TEST_LOCK_DIR"
  echo "the mutation harness host $(hostname) pid $$ at $(date +%s)" > "$_CLEAT_TEST_LOCK_DIR/owner"

  run "$PROJECT_ROOT/test.sh"
  assert_failure
  assert_output --partial "holds the test lock"
  assert_output --partial "the mutation harness"
}

@test "lock: the harness refuses while the suite holds it, WITHOUT writing anything" {
  # The refusal path must run before the backups and before the cleanup trap.
  # Both of those cp over the nine tracked files, so a refused harness that
  # reached them would perform the very write the lock exists to prevent.
  export _CLEAT_TEST_LOCK_DIR="$TEST_TEMP/lock"
  mkdir -p "$_CLEAT_TEST_LOCK_DIR"
  echo "the test suite host $(hostname) pid $$ at $(date +%s)" > "$_CLEAT_TEST_LOCK_DIR/owner"

  local before after
  before="$(cat "$CLI" | cksum)"
  run "$PROJECT_ROOT/test/mutation_regressions.sh"
  after="$(cat "$CLI" | cksum)"
  assert_failure
  assert_output --partial "holds the test lock"
  [[ "$before" == "$after" ]] || { echo "the refused harness rewrote bin/cleat"; return 1; }
}

@test "lock: a holder on ANOTHER machine is obeyed, never pid-probed" {
  # pid 1 is alive here, but it belongs to a different host. Probing our own
  # pid table for someone else's pid is how a container stomps a host run.
  export _CLEAT_TEST_LOCK_DIR="$TEST_TEMP/lock"
  mkdir -p "$_CLEAT_TEST_LOCK_DIR"
  echo "the mutation harness host some-other-box pid 1 at $(date +%s)" > "$_CLEAT_TEST_LOCK_DIR/owner"

  run "$PROJECT_ROOT/test.sh"
  assert_failure
  assert_output --partial "some-other-box"
}

@test "lock: a half-written lock is treated as HELD, not stale" {
  # The winner creates the directory and only then writes the owner record. A
  # reader arriving in that window must wait. Treating an unreadable record as
  # stale is a race BOTH runners win.
  export _CLEAT_TEST_LOCK_DIR="$TEST_TEMP/lock"
  mkdir -p "$_CLEAT_TEST_LOCK_DIR"   # no owner file yet

  run "$PROJECT_ROOT/test.sh"
  assert_failure
  assert_output --partial "holds the test lock"
}

@test "lock: a clock running backwards does not expire a live lock" {
  # A container hours behind its host was observed in this project. A negative
  # age must read as fresh, or one machine steals the other's live lock.
  export _CLEAT_TEST_LOCK_DIR="$TEST_TEMP/lock"
  mkdir -p "$_CLEAT_TEST_LOCK_DIR"
  echo "the mutation harness host some-other-box pid 1 at $(( $(date +%s) + 86400 ))" \
    > "$_CLEAT_TEST_LOCK_DIR/owner"

  run "$PROJECT_ROOT/test.sh"
  assert_failure
  assert_output --partial "holds the test lock"
}

@test "lock: an aged-out holder is taken over, on any host" {
  export _CLEAT_TEST_LOCK_DIR="$TEST_TEMP/lock"
  export _CLEAT_TEST_LOCK_STALE_SECS=1
  mkdir -p "$_CLEAT_TEST_LOCK_DIR"
  echo "the mutation harness host some-other-box pid 1 at 1000" > "$_CLEAT_TEST_LOCK_DIR/owner"

  run bash -c 'source "$1"; _take_test_lock "the test suite"; cat "$_CLEAT_TEST_LOCK_DIR/owner"' \
    _ "$(_lock_lib)"
  assert_success
  assert_output --partial "the test suite"
  refute_output --partial "some-other-box"
}

@test "lock: a dead holder on THIS machine is taken over" {
  export _CLEAT_TEST_LOCK_DIR="$TEST_TEMP/lock"
  mkdir -p "$_CLEAT_TEST_LOCK_DIR"
  echo "the mutation harness host $(hostname) pid 999999 at $(date +%s)" > "$_CLEAT_TEST_LOCK_DIR/owner"

  run bash -c 'source "$1"; _take_test_lock "the test suite"; cat "$_CLEAT_TEST_LOCK_DIR/owner"' \
    _ "$(_lock_lib)"
  assert_success
  refute_output --partial "999999"
}

@test "lock: only the owning process releases it" {
  # pid 42 must not release pid 4242's lock, and a foreign host's identical pid
  # must not release ours.
  export _CLEAT_TEST_LOCK_DIR="$TEST_TEMP/lock"
  mkdir -p "$_CLEAT_TEST_LOCK_DIR"
  echo "the test suite host some-other-box pid $$ at $(date +%s)" > "$_CLEAT_TEST_LOCK_DIR/owner"

  run bash -c 'source "$1"; _drop_test_lock; test -d "$_CLEAT_TEST_LOCK_DIR" && echo STILL_HELD' \
    _ "$(_lock_lib)"
  assert_output --partial "STILL_HELD"
}

@test "lock: concurrent takers never both win" {
  # The regression that made the first implementation useless: rm -rf followed
  # by mkdir has no atomicity, so every racer removed and every racer recreated.
  export _CLEAT_TEST_LOCK_DIR="$TEST_TEMP/lock"
  export _CLEAT_TEST_LOCK_STALE_SECS=1
  local lib winners=0 i
  lib="$(_lock_lib)"
  for i in 1 2 3 4 5 6 7 8 9 10; do
    rm -rf "$_CLEAT_TEST_LOCK_DIR"
    mkdir -p "$_CLEAT_TEST_LOCK_DIR"
    echo "stale host some-other-box pid 1 at 1000" > "$_CLEAT_TEST_LOCK_DIR/owner"
    local out
    out="$( { bash -c 'source "$1"; _take_test_lock a >/dev/null 2>&1 && echo WON' _ "$lib" & \
              bash -c 'source "$1"; _take_test_lock b >/dev/null 2>&1 && echo WON' _ "$lib" & \
              wait; } 2>/dev/null )"
    local n
    n="$(printf '%s\n' "$out" | grep -c WON || true)"
    (( n > 1 )) && winners=$(( winners + 1 ))
  done
  [[ "$winners" -eq 0 ]] || { echo "both racers acquired the lock in $winners of 10 rounds"; return 1; }
}
