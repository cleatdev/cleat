#!/usr/bin/env bats
# Tests for the on-start reaper-drift prompt (_maybe_prompt_init_recreate):
# boxes created before Cleat passed --init have `su` as PID 1, which never
# reaps re-parented children — zombies accumulate until the pids cap wedges
# the box (fork() fails; the attached session freezes mid-keystroke). On
# start, offer to recreate such boxes so they pick up --init. Mirrors the
# image-version drift prompt (image_rebuild_check.bats): TTY-only, once per
# process, fail-open on inspect errors.

load "../setup"

setup() {
  _common_setup
  use_docker_stub
  source_cli

  # Decision logic is what we test. Default: container exists, not running.
  container_exists() { return 0; }
  is_running() { return 1; }
  # Fresh guard per test (the real global persists once set).
  _INIT_RECREATE_PROMPTED=0
}

teardown() { _common_teardown; }

# ── guards ───────────────────────────────────────────────────────────────────

@test "init recreate: silent on a non-interactive (non-TTY) run" {
  mock_docker_inspect '{"PidsLimit":4096}'
  # Do NOT override _is_tty — false under bats.
  run _maybe_prompt_init_recreate "cleat-x-12345678"
  assert_success
  refute_output --partial "zombie reaper"
}

@test "init recreate: silent when the container does not exist" {
  _is_tty() { return 0; }
  container_exists() { return 1; }
  mock_docker_inspect '{"PidsLimit":4096}'
  run _maybe_prompt_init_recreate "cleat-x-12345678"
  assert_success
  refute_output --partial "zombie reaper"
}

@test "init recreate: silent when the box already has an init reaper" {
  _is_tty() { return 0; }
  mock_docker_inspect '{"Init":true,"PidsLimit":4096}'
  run _maybe_prompt_init_recreate "cleat-x-12345678"
  assert_success
  refute_output --partial "zombie reaper"
}

@test "init recreate: silent when docker inspect returns nothing (fail-open)" {
  _is_tty() { return 0; }
  # No inspect_output mocked — the stub prints nothing. A start must never be
  # blocked by an inspect hiccup.
  run _maybe_prompt_init_recreate "cleat-x-12345678"
  assert_success
  refute_output --partial "zombie reaper"
}

# ── prompt + action ──────────────────────────────────────────────────────────

@test "init recreate: prompts for a pre-init box and recreates on accept" {
  _is_tty() { return 0; }
  mock_docker_inspect '{"Init":null,"PidsLimit":4096}'
  run _maybe_prompt_init_recreate "cleat-x-12345678" <<< "y"
  assert_success
  assert_output --partial "zombie reaper"
  run grep "^docker rm -f cleat-x-12345678" "$DOCKER_CALLS"
  assert_success
}

@test "init recreate: an explicit Init:false also counts as pre-init" {
  _is_tty() { return 0; }
  mock_docker_inspect '{"Init":false,"PidsLimit":4096}'
  run _maybe_prompt_init_recreate "cleat-x-12345678" <<< "n"
  assert_success
  assert_output --partial "zombie reaper"
}

@test "init recreate: empty answer defaults to yes" {
  _is_tty() { return 0; }
  mock_docker_inspect '{"Init":null}'
  run _maybe_prompt_init_recreate "cleat-x-12345678" <<< ""
  assert_success
  run grep "^docker rm -f cleat-x-12345678" "$DOCKER_CALLS"
  assert_success
}

@test "init recreate: declining keeps the container" {
  _is_tty() { return 0; }
  mock_docker_inspect '{"Init":null}'
  run _maybe_prompt_init_recreate "cleat-x-12345678" <<< "n"
  assert_success
  assert_output --partial "zombie reaper"
  run grep "^docker rm" "$DOCKER_CALLS"
  assert_failure
}

@test "init recreate: a running box is stopped before removal on accept" {
  _is_tty() { return 0; }
  is_running() { return 0; }
  mock_docker_inspect '{"Init":false}'
  run _maybe_prompt_init_recreate "cleat-x-12345678" <<< "y"
  assert_success
  run grep "^docker stop cleat-x-12345678" "$DOCKER_CALLS"
  assert_success
  run grep "^docker rm -f cleat-x-12345678" "$DOCKER_CALLS"
  assert_success
}

@test "init recreate: accept removes the box run dir" {
  _is_tty() { return 0; }
  mock_docker_inspect '{"Init":null}'
  mkdir -p "$CLEAT_RUN_DIR/cleat-x-12345678"
  run _maybe_prompt_init_recreate "cleat-x-12345678" <<< "y"
  assert_success
  [ ! -d "$CLEAT_RUN_DIR/cleat-x-12345678" ]
}

@test "init recreate: prompts at most once per process" {
  _is_tty() { return 0; }
  mock_docker_inspect '{"Init":null}'
  _maybe_prompt_init_recreate "cleat-x-12345678" <<< "n" > /dev/null 2>&1 || true
  run _maybe_prompt_init_recreate "cleat-x-12345678" <<< "n"
  assert_success
  refute_output --partial "zombie reaper"
}

# ── call site ────────────────────────────────────────────────────────────────

@test "init recreate: cmd_start consults the reaper-drift check" {
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"
  is_running() { return 0; }
  mock_docker_ps_a "$cname"
  _resolve_config_drift() { true; }
  _maybe_prompt_image_rebuild() { true; }
  _maybe_prompt_init_recreate() { echo "INIT_DRIFT_CHECKED"; }
  run cmd_start "$TEST_TEMP/project"
  assert_success
  assert_output --partial "INIT_DRIFT_CHECKED"
}

@test "init recreate: cmd_resume consults the reaper-drift check" {
  # `cleat resume` is the verb that revives an old box after days idle —
  # exactly the box most likely to predate --init. The check must run on this
  # path independently of cmd_start.
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"
  is_running() { return 0; }
  mock_docker_ps_a "$cname"
  _resolve_config_drift() { true; }
  _maybe_prompt_image_rebuild() { true; }
  _maybe_prompt_init_recreate() { echo "INIT_DRIFT_CHECKED"; }
  run cmd_resume "$TEST_TEMP/project"
  assert_success
  assert_output --partial "INIT_DRIFT_CHECKED"
}

# ── status surfacing ──────────────────────────────────────────────────────────
# The zombie count is the early warning for the pre---init wedge: surface it
# while it's a number, not a frozen session — and stay quiet when it's zero
# or the probe came back empty (daemon hiccup).

@test "init recreate: status surfaces the unreaped-zombie count for a running box" {
  mkdir -p "$TEST_TEMP/project"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"
  is_running() { return 0; }
  _box_zombie_count() { echo "3"; }
  run cmd_status "$TEST_TEMP/project"
  assert_success
  assert_output --partial "3 unreaped"
  assert_output --partial "cleat rm && cleat"
}

@test "init recreate: no zombie line when the count is zero" {
  mkdir -p "$TEST_TEMP/project"
  is_running() { return 0; }
  _box_zombie_count() { echo "0"; }
  run cmd_status "$TEST_TEMP/project"
  assert_success
  refute_output --partial "unreaped"
}

@test "init recreate: an empty zombie probe stays silent (fail-open)" {
  mkdir -p "$TEST_TEMP/project"
  is_running() { return 0; }
  _box_zombie_count() { echo ""; }
  run cmd_status "$TEST_TEMP/project"
  assert_success
  refute_output --partial "unreaped"
}
