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

# ── inspect fixtures: one answer per container and per --format ─────────────
# The shipped arm prints one blob for every inspect, whatever the container or
# the format, so no test could build "NetworkMode right, CapDrop wrong". The
# inspect/ directory opts a test into per-container, per-format answers.

@test "stub: inspect --format returns the field named, per container" {
  mock_docker_inspect_field cleat-a '{{.HostConfig.NetworkMode}}' none
  mock_docker_inspect_field cleat-a '{{json .HostConfig.CapDrop}}' '["ALL"]'
  mock_docker_inspect_field cleat-b '{{.HostConfig.NetworkMode}}' bridge
  mock_docker_inspect_field cleat-b '{{json .HostConfig.CapDrop}}' 'null'

  run run_docker_stub inspect --format '{{json .HostConfig.CapDrop}}' cleat-a
  assert_success
  assert_output '["ALL"]'
  run run_docker_stub inspect --format '{{.HostConfig.NetworkMode}}' cleat-b
  assert_success
  assert_output "bridge"
  run run_docker_stub inspect --format '{{.HostConfig.NetworkMode}}' cleat-a
  assert_success
  assert_output "none"
  run run_docker_stub inspect --format '{{json .HostConfig.CapDrop}}' cleat-b
  assert_success
  assert_output "null"

  # A value renders the way the daemon prints it: `\n` expands, so a
  # {{println}} template answers one line per element, a JSON escape stays as
  # written, and an empty value is a declared answer rather than a missing one.
  local env='{{range .Config.Env}}{{println .}}{{end}}'
  mock_docker_inspect_field cleat-a "$env" 'PATH=/usr/bin\nHOST_UID=501'
  mock_docker_inspect_field cleat-a '{{json .Config.Labels}}' '{"k":"a\\b \\u00e9"}'
  run run_docker_stub inspect cleat-a --format '{{json .Config.Labels}}'
  assert_success
  assert_output '{"k":"a\\b \\u00e9"}'
  # A raw newline would split the record, so the helper refuses it.
  run mock_docker_inspect_field cleat-a "$env" "$(printf 'A\nB')"
  assert_failure
  mock_docker_inspect_field cleat-b "$env" ''
  run run_docker_stub inspect cleat-a --format "$env"
  assert_success
  assert_line --index 0 "PATH=/usr/bin"
  assert_line --index 1 "HOST_UID=501"
  run run_docker_stub inspect cleat-b --format "$env"
  assert_success
  assert_output ""
  # A record on a final line with no newline still answers.
  printf '{{.State.Running}}\ttrue' > "$DOCKER_MOCK_DIR/inspect/cleat-c"
  run run_docker_stub inspect --format '{{.State.Running}}' cleat-c
  assert_success
  assert_output "true"
}

@test "stub: inspect falls back to inspect_output when no fixture directory exists" {
  # Every shipped reader of the blob depends on this: no inspect/ directory,
  # so the answer is the blob, byte for byte, whatever was asked.
  printf 'line one\n{"Mounts":[]}\n' > "$DOCKER_MOCK_DIR/inspect_output"
  local want
  want="$(cat "$DOCKER_MOCK_DIR/inspect_output")"
  run run_docker_stub inspect --format '{{.HostConfig.NetworkMode}}' cleat-a
  assert_success
  assert_output "$want"
  run run_docker_stub inspect cleat-b
  assert_success
  assert_output "$want"
  run run_docker_stub inspect --type container -f '{{.Image}}' x y
  assert_success
  assert_output "$want"
  # `run` strips trailing newlines, so compare one answer as raw bytes too.
  run_docker_stub inspect --format '{{.HostConfig.NetworkMode}}' cleat-a > "$TEST_TEMP/got"
  run cmp "$TEST_TEMP/got" "$DOCKER_MOCK_DIR/inspect_output"
  assert_success
  run test -e "$DOCKER_MOCK_DIR/inspect"
  assert_failure
}

@test "stub: inspect refuses an undeclared container by name" {
  printf 'BLOB\n' > "$DOCKER_MOCK_DIR/inspect_output"
  mock_docker_inspect_field cleat-a '{{.State.Running}}' true
  run run_docker_stub inspect --format '{{.State.Running}}' cleat-b
  assert_failure 1
  assert_output "Error: No such object: cleat-b"
  # A missing name sets rc 1 without suppressing the answers around it.
  run run_docker_stub inspect --format '{{.State.Running}}' cleat-b cleat-a
  assert_failure 1
  assert_line --index 0 "Error: No such object: cleat-b"
  assert_line --index 1 "true"
  refute_output --partial "BLOB"
  # An empty name is a name no container has, and no name at all is a usage
  # error, never a successful empty read.
  run run_docker_stub inspect --format '{{.State.Running}}' ""
  assert_failure 1
  assert_output "Error: No such object: "
  run run_docker_stub inspect --format '{{.State.Running}}'
  assert_failure 1
  assert_output --partial "requires at least 1 argument"
}

@test "stub: inspect refuses an undeclared format" {
  printf 'BLOB\n' > "$DOCKER_MOCK_DIR/inspect_output"
  mock_docker_inspect_field cleat-a '{{.State.Running}}' true
  run run_docker_stub inspect --format '{{.State.Status}}' cleat-a
  assert_failure 1
  assert_output "Error: no fixture for container cleat-a and format: {{.State.Status}}"
  # No --format is its own format, __raw__, and it is not declared either.
  run run_docker_stub inspect cleat-a
  assert_failure 1
  assert_output "Error: no fixture for container cleat-a and format: __raw__"
}

@test "stub: inspect accepts the container name before and after the format flag" {
  mock_docker_inspect_field cleat-a '{{.HostConfig.Memory}}' 8589934592
  mock_docker_inspect_field cleat-b '{{.HostConfig.Memory}}' 4294967296
  mock_docker_inspect_field cleat-a __raw__ '[{"Id":"a"}]'

  run run_docker_stub inspect cleat-a --format '{{.HostConfig.Memory}}'
  assert_success
  assert_output "8589934592"
  run run_docker_stub inspect --format '{{.HostConfig.Memory}}' cleat-a
  assert_success
  assert_output "8589934592"
  run run_docker_stub inspect --format='{{.HostConfig.Memory}}' cleat-a
  assert_success
  assert_output "8589934592"
  run run_docker_stub inspect -f '{{.HostConfig.Memory}}' cleat-a
  assert_success
  assert_output "8589934592"
  run run_docker_stub inspect cleat-a
  assert_success
  assert_output '[{"Id":"a"}]'
  # Several names on one line answer in argv order, as _container_image_ids and
  # _running_memory_limits_sum pass them.
  run run_docker_stub inspect --format '{{.HostConfig.Memory}}' cleat-b cleat-a
  assert_success
  assert_output "$(printf '4294967296\n8589934592')"
  # Any other flag is outside the closed set and refuses like a daemon would.
  run run_docker_stub inspect --type container --format '{{.HostConfig.Memory}}' cleat-a
  assert_failure 125
  assert_output --partial "unsupported docker inspect flag in fixture mode: --type"
}

@test "stub: inspect answers repeated records in order and repeats the last" {
  local h='{{.State.Health.Status}}' r='{{.State.Running}}'
  mock_docker_inspect_field cleat-gw-a "$h" starting
  mock_docker_inspect_field cleat-gw-a "$r" true
  mock_docker_inspect_field cleat-gw-a "$h" starting
  mock_docker_inspect_field cleat-gw-a "$h" healthy
  # The second format is read between the health polls, the way a caller reads
  # labels and running state first. It must not move the health cursor.
  local want=(starting true starting true healthy true healthy healthy) got=() i fmt
  for i in 0 1 2 3 4 5 6 7; do
    fmt="$h"
    case "$i" in 1|3|5) fmt="$r" ;; esac
    run run_docker_stub inspect --format "$fmt" cleat-gw-a
    assert_success
    got+=("$output")
  done
  assert_equal "${got[*]}" "${want[*]}"
}

# ── volume, cp and create arms ──────────────────────────────────────────────

@test "stub: docker volume ls returns volume_ls_output" {
  run run_docker_stub volume ls --filter label=sh.cleat.role=egress-sock --format '{{.Name}}'
  assert_success
  assert_output ""
  printf 'cleat-gw-aaaa-sock\ncleat-gw-bbbb-sock\n' > "$DOCKER_MOCK_DIR/volume_ls_output"
  run run_docker_stub volume ls --filter label=sh.cleat.role=egress-sock --format '{{.Name}}'
  assert_success
  assert_output "$(printf 'cleat-gw-aaaa-sock\ncleat-gw-bbbb-sock')"
}

@test "stub: docker volume inspect answers per volume and refuses an undeclared one" {
  printf '{"blob":true}\n' > "$DOCKER_MOCK_DIR/volume_inspect_output"
  run run_docker_stub volume inspect --format '{{json .Labels}}' cleat-gw-anything-sock
  assert_success
  assert_output '{"blob":true}'
  mock_docker_volume_inspect_field cleat-gw-aaaa-sock '{{json .Labels}}' '{"sh.cleat.gateway-for":"aaaa"}'
  run run_docker_stub volume inspect --format '{{json .Labels}}' cleat-gw-aaaa-sock
  assert_success
  assert_output '{"sh.cleat.gateway-for":"aaaa"}'
  run run_docker_stub volume inspect --format '{{json .Labels}}' cleat-gw-bbbb-sock
  assert_failure 1
  assert_output "Error: No such volume: cleat-gw-bbbb-sock"
}

@test "stub: docker volume rm honours DOCKER_VOLUME_EXIT_CODE" {
  export DOCKER_STUB_STRICT=1
  run run_docker_stub volume create cleat-gw-aaaa-sock
  assert_success
  export DOCKER_VOLUME_EXIT_CODE=1
  run run_docker_stub volume rm cleat-gw-aaaa-sock
  assert_failure 1
  # The rm failed, so the volume is still live and a run may mount it.
  unset DOCKER_VOLUME_EXIT_CODE
  run run_docker_stub run -v cleat-gw-aaaa-sock:/run/cleat-egress:ro test-image
  assert_success
  run run_docker_stub volume rm cleat-gw-aaaa-sock
  assert_success
}

@test "stub: strict mode rejects a cleat-gw volume that is not live" {
  export DOCKER_STUB_STRICT=1
  # Never created.
  run run_docker_stub run -v cleat-gw-never-sock:/run/cleat-egress:ro test-image
  assert_failure 125
  assert_output --partial "named volume is not live in this test: cleat-gw-never-sock"
  # Created, then removed before the run: the teardown-ordering shape.
  run run_docker_stub volume create cleat-gw-gone-sock
  assert_success
  run run_docker_stub volume rm cleat-gw-gone-sock
  assert_success
  run run_docker_stub run -v cleat-gw-gone-sock:/run/cleat-egress:ro test-image
  assert_failure 125
  assert_output --partial "not live in this test: cleat-gw-gone-sock"
  # A create that failed never made the volume.
  export DOCKER_VOLUME_EXIT_CODE=1
  run run_docker_stub volume create cleat-gw-failed-sock
  assert_failure 1
  unset DOCKER_VOLUME_EXIT_CODE
  run run_docker_stub run -v cleat-gw-failed-sock:/run/cleat-egress:ro test-image
  assert_failure 125
  assert_output --partial "not live in this test: cleat-gw-failed-sock"
  # So did one that failed under the global exit code.
  export DOCKER_EXIT_CODE=1
  run run_docker_stub volume create cleat-gw-global-sock
  assert_failure 1
  export DOCKER_EXIT_CODE=0
  run run_docker_stub run -v cleat-gw-global-sock:/run/cleat-egress:ro test-image
  assert_failure 125
  assert_output --partial "not live in this test: cleat-gw-global-sock"
  # Created and still there, with the name before or after the flags.
  run run_docker_stub volume create --label sh.cleat.role=egress-sock cleat-gw-live-sock
  assert_success
  run run_docker_stub run -v cleat-gw-live-sock:/run/cleat-egress:ro test-image
  assert_success
  run run_docker_stub volume create cleat-gw-first-sock --label sh.cleat.role=egress-sock
  assert_success
  run run_docker_stub run --volume=cleat-gw-first-sock:/run/cleat-egress:ro test-image
  assert_success
}

@test "stub: docker cp still fails under the global DOCKER_EXIT_CODE" {
  run run_docker_stub cp "$TEST_TEMP/x" cleat-a:/tmp/x
  assert_success
  export DOCKER_EXIT_CODE=1 DOCKER_STDERR="Error: No such container: cleat-a"
  run run_docker_stub cp "$TEST_TEMP/x" cleat-a:/tmp/x
  assert_failure 1
  assert_output "Error: No such container: cleat-a"
  export DOCKER_CP_EXIT_CODE=3
  run run_docker_stub cp "$TEST_TEMP/x" cleat-a:/tmp/x
  assert_failure 3
}

@test "stub: docker create is validated in strict mode" {
  export DOCKER_STUB_STRICT=1
  run run_docker_stub create -v /nonexistent/path:/x test-image
  assert_failure 125
  assert_output --partial "bind source path does not exist: /nonexistent/path"
  run run_docker_stub create --name gw -v cleat-gw-never-sock:/run/cleat-egress test-image
  assert_failure 125
  assert_output --partial "not live in this test: cleat-gw-never-sock"
  mkdir -p "$TEST_TEMP/src"
  run run_docker_stub create --name gw -v "$TEST_TEMP/src:/x:ro" test-image
  assert_success
  export DOCKER_CREATE_EXIT_CODE=1
  run run_docker_stub create --name gw -v "$TEST_TEMP/src:/x:ro" test-image
  assert_failure 1
}

# ── The run-line helpers select one container's line, by --name ─────────────

@test "stub: assert_docker_run_has picks the line named by the container, not the last matching line" {
  # A named box's container name extends the default box's, so a substring
  # match on the default name also selects the named box, created later.
  local main="cleat-project-12345678" dev="cleat-project-12345678-dev"
  run run_docker_stub run -d --name "$main" --memory 8g test-image
  run run_docker_stub run -d --name "$dev" --memory 4g test-image
  run assert_docker_run_has "$main" "--memory 8g"
  assert_success
  run assert_docker_run_lacks "$main" "--memory 4g"
  assert_success
  run assert_docker_run_has "$dev" "--memory 4g"
  assert_success
}

@test "stub: assert_docker_run_lacks fails when no run line names the container" {
  run run_docker_stub run -d --name cleat-other-12345678 test-image
  run assert_docker_run_lacks cleat-never-created "--privileged"
  assert_failure
  assert_output "No docker run call found for container 'cleat-never-created'"
  # The way to prove a container was never created.
  run docker_run_line_for cleat-never-created
  assert_success
  assert_output ""
}

# ── The suite and the mutation harness must never run at once ───────────────
# The harness rewrites ten tracked files in place. Anything reading or
# EXECUTING them meanwhile fails for reasons unrelated to any change, and the
# harness reports false MISSED against source someone else restored. Both
# happened for real, including ACROSS MACHINES: a run inside a Cleat box and a
# run on the host share the bind-mounted checkout but not /tmp, which is why
# the lock lives in the repo. See test/lib/testlock.sh.

_lock_lib() { printf '%s\n' "$PROJECT_ROOT/test/lib/testlock.sh"; }

# Law L7: every entry runs against pristine targets, whatever ran before it.
# Restoring only the file about to be mutated left each mutation on disk for
# every later entry, so a result depended on registry order and on the shard.
@test "harness: an entry never observes an earlier entry's mutation" {
  cat > "$TEST_TEMP/registry" << 'EOF'
cat > "$SED_TMP" << 'SED'
s/pristine/mutated/
SED
try "first" "probe" "$SETUP_BASH" "$REPO_ROOT/test/unit/probe.bats"
try "second" "probe" "$INSTALLER" "$REPO_ROOT/test/unit/probe.bats"
EOF
  mutation_harness_tree "$TEST_TEMP/registry"
  export HARNESS_OBS="$TEST_TEMP/obs" _CLEAT_TEST_LOCK_DIR="$TEST_TEMP/harness/.lock"
  run env -u MUTATION_SHARD_TOTAL -u MUTATION_SHARD_INDEX \
    "$TEST_TEMP/harness/test/mutation_regressions.sh"
  assert_success
  run cat "$HARNESS_OBS"
  assert_output "$(printf '%s\n' 'mutated test/setup.bash' 'pristine install.sh' \
    'pristine test/setup.bash' 'mutated install.sh')"
  run cat "$TEST_TEMP/harness/test/setup.bash" "$TEST_TEMP/harness/install.sh"
  assert_output "$(printf '%s\n' 'pristine test/setup.bash' 'pristine install.sh')"
}

@test "harness: a backup that vanished mid-run stops the run before any mutation" {
  cat > "$TEST_TEMP/registry" << 'EOF'
cat > "$SED_TMP" << 'SED'
s/pristine/mutated/
SED
rm -f "$INSTALLER_BACKUP"
try "orphan" "probe" "$INSTALLER" "$REPO_ROOT/test/unit/probe.bats"
EOF
  mutation_harness_tree "$TEST_TEMP/registry"
  export HARNESS_OBS="$TEST_TEMP/obs" _CLEAT_TEST_LOCK_DIR="$TEST_TEMP/harness/.lock"
  run env -u MUTATION_SHARD_TOTAL -u MUTATION_SHARD_INDEX \
    "$TEST_TEMP/harness/test/mutation_regressions.sh"
  assert_failure 2
  assert_output --partial "the backup of install.sh is gone"
  run cat "$TEST_TEMP/harness/install.sh"
  assert_output "pristine install.sh"
}

@test "harness: an entry whose target has no backup is refused, not mutated" {
  cat > "$TEST_TEMP/registry" << 'EOF'
cat > "$SED_TMP" << 'SED'
s/pristine/mutated/
SED
try "stray" "probe" "$REPO_ROOT/test/unit/probe.bats" "$REPO_ROOT/test/unit/probe.bats"
EOF
  mutation_harness_tree "$TEST_TEMP/registry"
  export HARNESS_OBS="$TEST_TEMP/obs" _CLEAT_TEST_LOCK_DIR="$TEST_TEMP/harness/.lock"
  cp "$TEST_TEMP/harness/test/unit/probe.bats" "$TEST_TEMP/probe.before"
  run env -u MUTATION_SHARD_TOTAL -u MUTATION_SHARD_INDEX \
    "$TEST_TEMP/harness/test/mutation_regressions.sh"
  assert_failure 1
  assert_output --partial "stray: NOT A TARGET"
  run cmp "$TEST_TEMP/probe.before" "$TEST_TEMP/harness/test/unit/probe.bats"
  assert_success
}

@test "harness: MUTATION_MAX_SKIPPED fails a run whose sed matched nothing" {
  cat > "$TEST_TEMP/registry" << 'EOF'
cat > "$SED_TMP" << 'SED'
s/no-such-line/never/
SED
try "stale" "probe" "$INSTALLER" "$REPO_ROOT/test/unit/probe.bats"
EOF
  mutation_harness_tree "$TEST_TEMP/registry"
  export HARNESS_OBS="$TEST_TEMP/obs" _CLEAT_TEST_LOCK_DIR="$TEST_TEMP/harness/.lock"
  # Unset, a skip reads as it always has: reported, not failed.
  run env -u MUTATION_SHARD_TOTAL -u MUTATION_SHARD_INDEX -u MUTATION_MAX_SKIPPED \
    "$TEST_TEMP/harness/test/mutation_regressions.sh"
  assert_success
  assert_output --partial "stale: SKIPPED"
  run env -u MUTATION_SHARD_TOTAL -u MUTATION_SHARD_INDEX MUTATION_MAX_SKIPPED=0 \
    "$TEST_TEMP/harness/test/mutation_regressions.sh"
  assert_failure 1
  assert_output --partial "  - stale"
  run env -u MUTATION_SHARD_TOTAL -u MUTATION_SHARD_INDEX MUTATION_MAX_SKIPPED=1 \
    "$TEST_TEMP/harness/test/mutation_regressions.sh"
  assert_success
  run env -u MUTATION_SHARD_TOTAL -u MUTATION_SHARD_INDEX MUTATION_MAX_SKIPPED=none \
    "$TEST_TEMP/harness/test/mutation_regressions.sh"
  assert_failure 2
}

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
  # Both of those cp over the ten tracked files, so a refused harness that
  # reached them would perform the very write the lock exists to prevent. A
  # content checksum cannot see a restore that writes the same bytes back, so
  # the ten targets are backdated and the check is that none of them moved.
  : > "$TEST_TEMP/registry"
  mutation_harness_tree "$TEST_TEMP/registry"
  local h="$TEST_TEMP/harness" f targets=()
  for f in bin/cleat install.sh docker/entrypoint.sh docker/open-bridge docker/clip-daemon \
    docker/clip test.sh test/integration/lifecycle.bats test/setup.bash \
    test/fixtures/mock_bin/docker; do
    touch -t 200001010000 "$h/$f"
    targets+=("$h/$f")
  done
  touch -t 200001010001 "$TEST_TEMP/marker"
  export _CLEAT_TEST_LOCK_DIR="$TEST_TEMP/lock"
  mkdir -p "$_CLEAT_TEST_LOCK_DIR"
  echo "the test suite host $(hostname) pid $$ at $(date +%s)" > "$_CLEAT_TEST_LOCK_DIR/owner"

  run "$h/test/mutation_regressions.sh"
  assert_failure
  assert_output --partial "holds the test lock"
  run find "${targets[@]}" -newer "$TEST_TEMP/marker"
  assert_success
  assert_output ""
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
    local out dd="$TEST_TEMP/lockdone"
    rm -rf "$dd"; mkdir -p "$dd"
    # The two takers start with their natural, slight stagger, so the atomic
    # mv-reclaim of the seeded stale lock contends one-at-a-time (forcing perfect
    # simultaneity instead surfaces a rarer reclaim TOCTOU where the loser mv's
    # away the winner's just-created fresh lock). The hazard on a slow runner
    # (macOS bash 3.2) is the other direction: the winner's pid dies microseconds
    # after it acquires, so the loser's same-host kill -0 probe finds a dead
    # holder and takes over a lock nobody really holds, and both print WON. Fix:
    # the winner HOLDS until the loser has finished its attempt. Each racer drops
    # a .done marker from an EXIT trap (the loser leaves via _tl_refuse's exit,
    # so win or lose the marker lands), and the winner waits for that marker
    # before releasing, so the loser always probes a LIVE holder and refuses. A
    # genuine double-win still surfaces: both block in the hold, neither exits,
    # both time out having already printed WON.
    out="$( {
      bash -c 'source "$1"; m="$2/$3.done"; trap "touch \"\$m\"" EXIT; if _take_test_lock "$3" >/dev/null 2>&1; then echo WON; t=0; while [ "$(ls "$2"/*.done 2>/dev/null | wc -l | tr -d " ")" -lt 1 ] && [ "$t" -lt 300 ]; do sleep 0.02; t=$(( t + 1 )); done; _drop_test_lock; fi' _ "$lib" "$dd" a &
      bash -c 'source "$1"; m="$2/$3.done"; trap "touch \"\$m\"" EXIT; if _take_test_lock "$3" >/dev/null 2>&1; then echo WON; t=0; while [ "$(ls "$2"/*.done 2>/dev/null | wc -l | tr -d " ")" -lt 1 ] && [ "$t" -lt 300 ]; do sleep 0.02; t=$(( t + 1 )); done; _drop_test_lock; fi' _ "$lib" "$dd" b &
      wait
    } 2>/dev/null )"
    local n
    n="$(printf '%s\n' "$out" | grep -c WON || true)"
    (( n > 1 )) && winners=$(( winners + 1 ))
  done
  [[ "$winners" -eq 0 ]] || { echo "both racers acquired the lock in $winners of 10 rounds"; return 1; }
}

# ── DOCKER_STUB_EXEC_SCRIPT (M3): the stub runs a script for `docker exec` ────

@test "stub exec script receives the argv and prints its stdout" {
  cat > "$TEST_TEMP/es.sh" <<'SH'
#!/usr/bin/env bash
printf 'ARGV:%s\n' "$*"
SH
  chmod +x "$TEST_TEMP/es.sh"
  export DOCKER_STUB_EXEC_SCRIPT="$TEST_TEMP/es.sh"
  run docker exec mybox echo hello
  assert_success
  assert_output --partial "ARGV:exec mybox echo hello"
}

@test "stub exec script receives stdin and returns its exit code" {
  cat > "$TEST_TEMP/es.sh" <<'SH'
#!/usr/bin/env bash
in="$(cat)"
printf 'STDIN:%s\n' "$in"
exit 42
SH
  chmod +x "$TEST_TEMP/es.sh"
  export DOCKER_STUB_EXEC_SCRIPT="$TEST_TEMP/es.sh"
  run bash -c 'printf "%s" "payload42" | docker exec mybox cat'
  assert_output --partial "STDIN:payload42"
  assert_equal "$status" 42
}

# ── Stage three arms: ps per filter, logs, cp out of a container ────────────

@test "stub: docker ps answers per filter and falls back to ps_output when no filter fixture exists" {
  mock_docker_ps_filter "cleat-gw-aaaaaaaaaaaa" "label=sh.cleat.role=gateway"
  printf '%s\n' "cleat-box-1" > "$DOCKER_MOCK_DIR/ps_output"
  run run_docker_stub ps --filter label=sh.cleat.role=gateway --format '{{.Names}}'
  assert_success
  assert_output "cleat-gw-aaaaaaaaaaaa"
  run run_docker_stub ps --filter=label=sh.cleat.role=gateway
  assert_output "cleat-gw-aaaaaaaaaaaa"
  # Another filter, or none, reads the shipped files.
  run run_docker_stub ps --filter label=sh.cleat.version --format '{{.Names}}'
  assert_output "cleat-box-1"
  run run_docker_stub ps
  assert_output "cleat-box-1"
}

@test "stub: docker ps honours DOCKER_PS_EXIT_CODE" {
  printf '%s\n' "cleat-box-1" > "$DOCKER_MOCK_DIR/ps_output"
  DOCKER_PS_EXIT_CODE=1 run env DOCKER_PS_EXIT_CODE=1 DOCKER_CALLS="$DOCKER_CALLS" DOCKER_MOCK_DIR="$DOCKER_MOCK_DIR" "$MOCK_BIN/docker" ps
  assert_failure 1
  assert_output ""
}

@test "stub: docker logs prints the fixture for its container" {
  mkdir -p "$DOCKER_MOCK_DIR/logs"
  printf 'allow host=a.example\n' > "$DOCKER_MOCK_DIR/logs/cleat-gw-bbbbbbbbbbbb"
  run run_docker_stub logs --since 10m cleat-gw-bbbbbbbbbbbb
  assert_output "allow host=a.example"
  run run_docker_stub logs cleat-other
  assert_output ""
  printf 'any\n' > "$DOCKER_MOCK_DIR/logs_output"
  run run_docker_stub logs cleat-other
  assert_output "any"
}

@test "stub: docker cp out of a container writes the fixture" {
  mkdir -p "$DOCKER_MOCK_DIR/cp/cleat-gw-cccccccccccc" "$TEST_TEMP/dest"
  printf 'row\n' > "$DOCKER_MOCK_DIR/cp/cleat-gw-cccccccccccc/denials.log"
  run run_docker_stub cp cleat-gw-cccccccccccc:/run/cleat-egress/denials.log "$TEST_TEMP/dest/copy.log"
  assert_success
  run cat "$TEST_TEMP/dest/copy.log"
  assert_output "row"
  run run_docker_stub cp cleat-gw-cccccccccccc:/run/cleat-egress/denials.log "$TEST_TEMP/dest"
  run cat "$TEST_TEMP/dest/denials.log"
  assert_output "row"
}

@test "stub: docker cp with no fixture writes nothing" {
  mkdir -p "$TEST_TEMP/dest"
  run run_docker_stub cp cleat-gw-dddddddddddd:/run/cleat-egress/denials.log "$TEST_TEMP/dest/copy.log"
  assert_success
  [ ! -e "$TEST_TEMP/dest/copy.log" ]
  run grep -c '^docker cp cleat-gw-dddddddddddd' "$DOCKER_CALLS"
  assert_output "1"
}

@test "setup: assert_docker_exec_has with a container ignores another container's exec" {
  printf 'docker exec cleat-gw-eeeeeeeeeeee /usr/local/bin/gw-admin path_ok\ndocker exec -it -e HTTPS_PROXY=x cleat-demo-12345678 runuser -u coder\n' > "$DOCKER_CALLS"
  run assert_docker_exec_has cleat-demo-12345678 "HTTPS_PROXY=x"
  assert_success
  run assert_docker_exec_has cleat-demo-12345678 "gw-admin"
  assert_failure
  run assert_docker_exec_has cleat-gw-eeeeeeeeeeee "gw-admin path_ok"
  assert_success
  # The one-argument form is unchanged.
  run assert_docker_exec_has "gw-admin"
  assert_success
}

@test "setup: assert_docker_exec_has with a container fails when that container has no exec" {
  printf 'docker exec cleat-demo-12345678 true\n' > "$DOCKER_CALLS"
  run assert_docker_exec_has cleat-demo-1234 "true"
  assert_failure
  assert_output --partial "no docker exec recorded for container 'cleat-demo-1234'"
}
