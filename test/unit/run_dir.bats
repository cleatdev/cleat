#!/usr/bin/env bats
# Tests for the persistent per-container runtime dir ($CLEAT_RUN_DIR/<cname>/).
# The settings overlay, clipboard bridge, and hook spool used to live under
# /tmp, where macOS file rotation / reboots deleted the container's bind-mount
# sources and forced a recreate (discarding the writable layer). They now live
# under the persistent config dir so a plain `cleat` can resume instead.
load "../setup"

setup() {
  _common_setup
  use_docker_stub
  source_cli
}

teardown() { _common_teardown; }

_cname_for() { container_name_for "$1"; }

# ── Relocation: bind sources live under CLEAT_RUN_DIR, never /tmp ────────────

@test "run dir: lives under the cleat config dir, not the legacy /tmp scheme" {
  # In production CLEAT_CONFIG_DIR is ~/.config/cleat (persistent); in the test
  # sandbox HOME itself is a mktemp dir under /tmp, so assert the structural
  # invariant rather than a literal /tmp prefix.
  [[ "$CLEAT_RUN_DIR" == "$CLEAT_CONFIG_DIR/run" ]]
  [[ "$CLEAT_RUN_DIR" == *"/cleat/run" ]]
  # Never the old flat per-container /tmp scheme.
  [[ "$CLEAT_RUN_DIR" != *"/cleat-settings-"* ]]
}

@test "run: settings overlay is mounted from CLEAT_RUN_DIR, not /tmp" {
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project"
  local cname; cname="$(_cname_for "$TEST_TEMP/project")"

  run cmd_run "$TEST_TEMP/project"
  assert_success
  run assert_docker_run_has "$cname" "$CLEAT_RUN_DIR/${cname}/settings/settings.json:/home/coder/.claude/settings.json"
  assert_success

  # No settings/hooks bind source under /tmp anymore.
  run docker_calls
  refute_output --partial "/tmp/cleat-settings-"
  refute_output --partial "/tmp/cleat-hooks-"
}

@test "run: clipboard bridge source is under CLEAT_RUN_DIR (target stays /tmp/cleat-clip)" {
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project"
  local cname; cname="$(_cname_for "$TEST_TEMP/project")"

  run cmd_run "$TEST_TEMP/project"
  assert_success
  # Host SOURCE moved; container TARGET (/tmp/cleat-clip) is unchanged.
  run assert_docker_run_has "$cname" "$CLEAT_RUN_DIR/${cname}/clip:/tmp/cleat-clip"
  assert_success
}

@test "run: hooks spool source is under CLEAT_RUN_DIR when hooks cap active" {
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project"
  local cname; cname="$(_cname_for "$TEST_TEMP/project")"
  # Force the hooks mount branch.
  cap_is_active() { [[ "$1" == "hooks" ]]; }

  run cmd_run "$TEST_TEMP/project"
  assert_success
  run assert_docker_run_has "$cname" "$CLEAT_RUN_DIR/${cname}/hooks:/var/log/cleat"
  assert_success
}

@test "run: actually creates the per-container dir on the host" {
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project"
  local cname; cname="$(_cname_for "$TEST_TEMP/project")"

  run cmd_run "$TEST_TEMP/project"
  assert_success
  [[ -d "$CLEAT_RUN_DIR/${cname}/settings" ]] || return 1
}

# ── Migration: pre-move containers (mounts under /tmp) force a recreate ───────

@test "intact check: false when the new-layout overlay dir is absent (migration)" {
  # A container created before the move has no dir under CLEAT_RUN_DIR, so the
  # check must report not-intact → cmd_start recreates it into the new layout.
  # The end-to-end recreate (cmd_start → docker rm + cmd_run, refuting docker
  # start) is proven in start_resume.bats: "stale mounts auto-recreate
  # container after reboot".
  run _settings_overlay_intact "cleat-old-12345678"
  assert_failure
}

@test "intact check: settings-only scope, a missing clip/hooks sibling does not force recreate" {
  # The check guards only the settings overlay (file mounts, which fail hard if
  # the source vanishes). clip/ and hooks/ are dir mounts that Docker
  # auto-recreates, so a vanished sibling must NOT trigger a recreate. This
  # asymmetry is intentional: see concept/18-runtime-state.md.
  local cname="cleat-siblings-12345678"
  mkdir -p "$CLEAT_RUN_DIR/${cname}/settings"
  echo '{}' > "$CLEAT_RUN_DIR/${cname}/settings/settings.json"
  # Note: no clip/ or hooks/ sibling exists.
  printf '%s\n' "$CLEAT_RUN_DIR/${cname}/settings/settings.json" > "$DOCKER_MOCK_DIR/inspect_output"

  run _settings_overlay_intact "$cname"
  assert_success
}

@test "intact check: true when overlay dir + mounted source file exist" {
  local cname="cleat-new-12345678"
  mkdir -p "$CLEAT_RUN_DIR/${cname}/settings"
  echo '{}' > "$CLEAT_RUN_DIR/${cname}/settings/settings.json"
  # docker inspect (stubbed) reports the container's bind sources.
  printf '%s\n' "$CLEAT_RUN_DIR/${cname}/settings/settings.json" > "$DOCKER_MOCK_DIR/inspect_output"

  run _settings_overlay_intact "$cname"
  assert_success
}

@test "intact check: false when a mounted overlay source file is missing" {
  local cname="cleat-broken-12345678"
  mkdir -p "$CLEAT_RUN_DIR/${cname}/settings"   # dir exists...
  # ...but the container's recorded bind source no longer does.
  printf '%s\n' "$CLEAT_RUN_DIR/${cname}/settings/settings.json" > "$DOCKER_MOCK_DIR/inspect_output"

  run _settings_overlay_intact "$cname"
  assert_failure
}

# ── Lifecycle: stop preserves; rm removes own; nuke wipes all ────────────────

@test "stop: preserves the run dir (so resume can reuse the container)" {
  mkdir -p "$TEST_TEMP/project"
  local cname; cname="$(_cname_for "$TEST_TEMP/project")"
  mock_docker_ps "$cname"          # running
  mkdir -p "$CLEAT_RUN_DIR/${cname}/settings"

  run cmd_stop "$TEST_TEMP/project"
  assert_success
  [[ -d "$CLEAT_RUN_DIR/${cname}" ]] || return 1
}

@test "rm: removes this container's run dir" {
  mkdir -p "$TEST_TEMP/project"
  local cname; cname="$(_cname_for "$TEST_TEMP/project")"
  mock_docker_ps ""                # not running
  mock_docker_ps_a "$cname"        # exists
  mkdir -p "$CLEAT_RUN_DIR/${cname}/settings"

  run cmd_rm "$TEST_TEMP/project"
  assert_success
  [[ ! -d "$CLEAT_RUN_DIR/${cname}" ]] || return 1
}

@test "rm: leaves OTHER containers' run dirs untouched" {
  mkdir -p "$TEST_TEMP/project"
  local cname; cname="$(_cname_for "$TEST_TEMP/project")"
  mock_docker_ps ""
  mock_docker_ps_a "$cname"
  mkdir -p "$CLEAT_RUN_DIR/${cname}/settings"
  mkdir -p "$CLEAT_RUN_DIR/cleat-other-99999999/settings"

  run cmd_rm "$TEST_TEMP/project"
  assert_success
  [[ -d "$CLEAT_RUN_DIR/cleat-other-99999999" ]] || return 1
}

@test "nuke: wipes the entire CLEAT_RUN_DIR" {
  mock_docker_ps_a ""
  mkdir -p "$CLEAT_RUN_DIR/cleat-a-11111111/settings"
  mkdir -p "$CLEAT_RUN_DIR/cleat-b-22222222/clip"

  run bash -c '
    export DOCKER_CALLS="'"$DOCKER_CALLS"'"
    export DOCKER_MOCK_DIR="'"$DOCKER_MOCK_DIR"'"
    export PATH="'"$MOCK_BIN"':$PATH"
    export HOME="'"$HOME"'"
    source "'"$CLI"'"
    echo "nuke" | cmd_nuke
  '
  assert_success
  [[ ! -d "$CLEAT_RUN_DIR" ]] || return 1
}

# ── clean: prune orphaned run dirs, keep live ones ───────────────────────────

@test "clean: prunes orphaned run dirs but keeps live containers'" {
  mock_docker_images "cleat"
  mkdir -p "$CLEAT_RUN_DIR/cleat-live-aaaa1111/settings"
  mkdir -p "$CLEAT_RUN_DIR/cleat-orphan-bbbb2222/settings"
  # Only the live container still exists.
  container_exists() { [[ "$1" == "cleat-live-aaaa1111" ]]; }

  run cmd_clean
  assert_success
  [[ -d "$CLEAT_RUN_DIR/cleat-live-aaaa1111" ]] || return 1
  [[ ! -d "$CLEAT_RUN_DIR/cleat-orphan-bbbb2222" ]] || return 1
}

@test "clean: reports how many orphaned dirs were pruned" {
  mock_docker_images "cleat"
  mkdir -p "$CLEAT_RUN_DIR/cleat-orphan-bbbb2222/settings"
  container_exists() { return 1; }   # nothing exists → orphan

  run cmd_clean
  assert_success
  assert_output --partial "Pruned 1 orphaned runtime dir"
}

@test "clean: exits 0 on a successful run with nothing to prune" {
  # Regression: the prune block must not leave a false exit status. With 0
  # orphans the report test is false; a `[[ ]] &&` tail would make cmd_clean
  # (the last statement in main) exit 1 on success. Use an empty-but-present
  # run dir so the loop runs zero times and _pruned stays 0.
  mock_docker_images "cleat"
  mkdir -p "$CLEAT_RUN_DIR"
  run cmd_clean
  assert_success
}
