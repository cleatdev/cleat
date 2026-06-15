#!/usr/bin/env bats
# Boxes: per-box runtime behavior in cmd_run (see concept/20-boxes.md).
# Phase 3: per-box session state + the sh.cleat.box container label.
#
# These drive cmd_run with the box set via the session-scoped _BOX global
# (exactly as the dispatch sets it). bats `run` forks a subshell that inherits
# _BOX from the test shell, so cmd_run sees the box we set here.
load "../setup"
setup() {
  _common_setup
  use_docker_stub
  source_cli
  _host_clip_cmd() { echo ""; }
  check_for_update() { true; }
  check_drift() { true; }
  _resolve_config_drift() { true; }
}
teardown() { _common_teardown; }

@test "box run: a named box creates a -<box> suffixed container" {
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project"
  _BOX="az"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project" az)"
  [[ "$cname" == *-az ]] || { echo "cname=$cname"; return 1; }

  run cmd_run "$TEST_TEMP/project"
  assert_success
  run assert_docker_run_has "$cname" "--name $cname"
  assert_success
}

@test "box run: the docker run carries the sh.cleat.box label" {
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project"
  _BOX="az"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project" az)"

  run cmd_run "$TEST_TEMP/project"
  assert_success
  run assert_docker_run_has "$cname" "sh.cleat.box=az"
  assert_success
}

@test "box run: the default (main) box labels sh.cleat.box=main" {
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project"
  # _BOX defaults to "main" via the sourced top-level assignment.
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"

  run cmd_run "$TEST_TEMP/project"
  assert_success
  run assert_docker_run_has "$cname" "sh.cleat.box=main"
  assert_success
}

@test "box run: a named box gets its own session overlay dir (not the default's)" {
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project"
  _BOX="az"
  local cname key
  cname="$(container_name_for "$TEST_TEMP/project" az)"
  key="$(_derive_project_session_key "$TEST_TEMP/project" az)"
  [[ "$key" == *-az ]] || { echo "key=$key"; return 1; }

  run cmd_run "$TEST_TEMP/project"
  assert_success
  # The per-project session overlay source must be keyed by the BOX key
  # (<basename>-<hash>-az), so the az box never shares sessions with main.
  run assert_docker_run_has "$cname" "${key}:/home/coder/.claude/projects/-workspace"
  assert_success
}

@test "box run: the default box session overlay is byte-identical to legacy (no -main)" {
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project"
  local cname legacy_key
  cname="$(container_name_for "$TEST_TEMP/project")"
  legacy_key="$(basename "$TEST_TEMP/project" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g')-$(echo -n "$TEST_TEMP/project" | _md5 | head -c 8)"

  run cmd_run "$TEST_TEMP/project"
  assert_success
  run assert_docker_run_has "$cname" "${legacy_key}:/home/coder/.claude/projects/-workspace"
  assert_success
  # It must NOT carry a -main-suffixed session key.
  run assert_docker_run_lacks "$cname" "${legacy_key}-main"
  assert_success
}

@test "box run: two boxes on one project get distinct session keys and containers" {
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project"

  _BOX="az"
  run cmd_run "$TEST_TEMP/project"
  assert_success

  _BOX="dev"
  run cmd_run "$TEST_TEMP/project"
  assert_success

  local az_cname dev_cname az_key dev_key
  az_cname="$(container_name_for "$TEST_TEMP/project" az)"
  dev_cname="$(container_name_for "$TEST_TEMP/project" dev)"
  az_key="$(_derive_project_session_key "$TEST_TEMP/project" az)"
  dev_key="$(_derive_project_session_key "$TEST_TEMP/project" dev)"
  [[ "$az_cname" != "$dev_cname" ]] || return 1
  [[ "$az_key" != "$dev_key" ]] || return 1
  run assert_docker_run_has "$az_cname" "--name $az_cname"
  assert_success
  run assert_docker_run_has "$dev_cname" "--name $dev_cname"
  assert_success
}

# ── Phase 4: per-box capabilities (.cleat.<box> REPLACES .cleat) ─────────────

@test "box caps: .cleat.<box> REPLACES .cleat, a box can have FEWER caps" {
  # This is the least-privilege guarantee: a dev box denied docker even though
  # the project default (.cleat) grants it.
  mkdir -p "$TEST_TEMP/project"
  printf '[caps]\ngit\ndocker\n' > "$TEST_TEMP/project/.cleat"
  printf '[caps]\ngit\n'         > "$TEST_TEMP/project/.cleat.dev"
  _BOX="dev"
  resolve_caps "$TEST_TEMP/project"
  run cap_is_active git;    assert_success
  run cap_is_active docker; assert_failure   # NOT inherited from .cleat
}

@test "box caps: a box file can REPLACE with MORE caps than .cleat" {
  mkdir -p "$TEST_TEMP/project"
  printf '[caps]\ngit\n'         > "$TEST_TEMP/project/.cleat"
  printf '[caps]\ngit\ndocker\n' > "$TEST_TEMP/project/.cleat.az"
  _BOX="az"
  resolve_caps "$TEST_TEMP/project"
  run cap_is_active git;    assert_success
  run cap_is_active docker; assert_success
}

@test "box caps: a named box with no .cleat.<box> falls back to .cleat" {
  mkdir -p "$TEST_TEMP/project"
  printf '[caps]\ngit\nssh\n' > "$TEST_TEMP/project/.cleat"
  _BOX="scratch"
  resolve_caps "$TEST_TEMP/project"
  run cap_is_active git; assert_success
  run cap_is_active ssh; assert_success
}

@test "box caps: the main box always reads .cleat, ignoring any .cleat.<box>" {
  mkdir -p "$TEST_TEMP/project"
  printf '[caps]\ngit\n'    > "$TEST_TEMP/project/.cleat"
  printf '[caps]\ndocker\n' > "$TEST_TEMP/project/.cleat.az"
  _BOX="main"
  resolve_caps "$TEST_TEMP/project"
  run cap_is_active git;    assert_success
  run cap_is_active docker; assert_failure
}

@test "box caps: global config still unions into every box (documented caveat)" {
  mkdir -p "$TEST_TEMP/project"
  CLEAT_GLOBAL_CONFIG="$TEST_TEMP/global-config"
  printf '[caps]\ngh\n'  > "$CLEAT_GLOBAL_CONFIG"
  printf '[caps]\ngit\n' > "$TEST_TEMP/project/.cleat.dev"
  _BOX="dev"
  resolve_caps "$TEST_TEMP/project"
  run cap_is_active git; assert_success   # from .cleat.dev
  run cap_is_active gh;  assert_success   # from global, unions in
}

# ── Phase 4: per-box env files (.cleat.<box>.env REPLACES .cleat.env) ────────

@test "box env: .cleat.<box>.env is used and .cleat.env is NOT leaked to it" {
  mkdir -p "$TEST_TEMP/project"
  printf '[caps]\nenv\n'    > "$TEST_TEMP/project/.cleat.az"
  printf 'AZ_TOKEN=secret\n' > "$TEST_TEMP/project/.cleat.az.env"
  printf 'DEV_ONLY=1\n'      > "$TEST_TEMP/project/.cleat.env"
  _BOX="az"
  resolve_caps "$TEST_TEMP/project"
  resolve_env_args "$TEST_TEMP/project"
  local joined="${_RESOLVED_ENV_ARGS[*]}"
  [[ "$joined" == *"AZ_TOKEN=secret"* ]] || { echo "missing AZ_TOKEN: $joined"; return 1; }
  [[ "$joined" != *"DEV_ONLY=1"* ]]      || { echo "az must NOT see .cleat.env: $joined"; return 1; }
}

@test "box env: falls back to .cleat.env when no .cleat.<box>.env exists" {
  mkdir -p "$TEST_TEMP/project"
  printf '[caps]\nenv\n' > "$TEST_TEMP/project/.cleat.az"
  printf 'SHARED=yes\n'  > "$TEST_TEMP/project/.cleat.env"
  _BOX="az"
  resolve_caps "$TEST_TEMP/project"
  resolve_env_args "$TEST_TEMP/project"
  local joined="${_RESOLVED_ENV_ARGS[*]}"
  [[ "$joined" == *"SHARED=yes"* ]] || { echo "missing SHARED: $joined"; return 1; }
}

# ── Phase 4: per-box trust ──────────────────────────────────────────────────

@test "box trust: .cleat.<box> and .cleat hash to different trust values" {
  mkdir -p "$TEST_TEMP/project"
  printf '[caps]\ngit\n'    > "$TEST_TEMP/project/.cleat"
  printf '[caps]\ndocker\n' > "$TEST_TEMP/project/.cleat.az"
  local main_hash az_hash
  main_hash="$(_hash_cleat_caps "$TEST_TEMP/project/.cleat")"
  az_hash="$(_hash_cleat_caps "$TEST_TEMP/project/.cleat.az")"
  [[ -n "$main_hash" && "$main_hash" != "$az_hash" ]] || return 1
}

@test "box trust: trusting main does not trust the az box" {
  mkdir -p "$TEST_TEMP/project"
  printf '[caps]\ngit\n'    > "$TEST_TEMP/project/.cleat"
  printf '[caps]\ndocker\n' > "$TEST_TEMP/project/.cleat.az"
  _trust_record "$TEST_TEMP/project" "$(_hash_cleat_caps "$TEST_TEMP/project/.cleat")" main
  _BOX="main"; run _is_project_trusted "$TEST_TEMP/project"; assert_success
  _BOX="az";   run _is_project_trusted "$TEST_TEMP/project"; assert_failure
}

@test "box trust: a legacy two-column trust row is read as the main box" {
  mkdir -p "$TEST_TEMP/project"
  printf '[caps]\ngit\n' > "$TEST_TEMP/project/.cleat"
  local h; h="$(_hash_cleat_caps "$TEST_TEMP/project/.cleat")"
  mkdir -p "$(dirname "$CLEAT_TRUST_FILE")"
  printf '%s\t%s\n' "$TEST_TEMP/project" "$h" > "$CLEAT_TRUST_FILE"
  _BOX="main"; run _is_project_trusted "$TEST_TEMP/project"; assert_success
}

# ── Phase 5: listing (status enumerates the project's boxes) ────────────────

@test "box status: always lists the main box, even with no container" {
  mkdir -p "$TEST_TEMP/project"
  run cmd_status "$TEST_TEMP/project"
  assert_success
  assert_output --partial "Boxes:"
  assert_output --partial "main"
}

@test "box status: lists a named box via the sh.cleat.box label + workspace mount" {
  mkdir -p "$TEST_TEMP/project"
  local az_cname
  az_cname="$(container_name_for "$TEST_TEMP/project" az)"
  printf '%s\n' "$az_cname" > "$DOCKER_MOCK_DIR/ps_a_output"
  printf 'az|true|%s\n' "$TEST_TEMP/project" > "$DOCKER_MOCK_DIR/inspect_output"
  run cmd_status "$TEST_TEMP/project"
  assert_success
  assert_output --partial "az"
}

@test "box status: lists a named box even when the project dir name is long (regression)" {
  # container_name_for re-truncates the dir segment per box, so a named box's
  # name is NOT prefixed by the main cname. Discovery must key on the invariant
  # hash + mount source, not the prefix. (Confirmed bug from the adversarial review.)
  local longdir proj az_cname main_cname
  longdir="this-is-a-very-long-project-directory-name-that-exceeds-budget"
  proj="$TEST_TEMP/$longdir"
  mkdir -p "$proj"
  az_cname="$(container_name_for "$proj" az)"
  main_cname="$(container_name_for "$proj" main)"
  # Only meaningful if truncation actually diverges (az not under main's prefix).
  [[ "$az_cname" == "${main_cname}-"* ]] && skip "dir too short to exercise truncation divergence"
  printf '%s\n' "$az_cname" > "$DOCKER_MOCK_DIR/ps_a_output"
  printf 'az|true|%s\n' "$proj" > "$DOCKER_MOCK_DIR/inspect_output"
  run cmd_status "$proj"
  assert_success
  assert_output --partial "az"
}

@test "box status: ignores a container whose /workspace mount is a different project" {
  # Even if a sibling project's container name embeds this project's hash, the
  # mount-source check rejects it: no cross-project phantom box.
  mkdir -p "$TEST_TEMP/project"
  local hash
  hash="$(echo -n "$TEST_TEMP/project" | _md5 | head -c 8)"
  printf '%s\n' "cleat-sibling-${hash}-zzz-99999999" > "$DOCKER_MOCK_DIR/ps_a_output"
  printf 'zzz|true|/some/other/project\n' > "$DOCKER_MOCK_DIR/inspect_output"
  run cmd_status "$TEST_TEMP/project"
  assert_success
  refute_output --partial "zzz"
}

@test "box status: ignores container names that don't carry the project hash" {
  mkdir -p "$TEST_TEMP/project"
  printf '%s\n' "cleat-other-99999999-zzz" > "$DOCKER_MOCK_DIR/ps_a_output"
  run cmd_status "$TEST_TEMP/project"
  assert_success
  refute_output --partial "zzz"
}

@test "box status: a named box's running state comes from the discovery inspect, not a re-probe" {
  # Efficiency: the named-box loop must reuse State.Running from its one
  # discovery inspect instead of calling is_running/container_exists again.
  # Proof: `docker ps` (non -a) lists ONLY main, so a fresh is_running(az) probe
  # would report az as NOT running → "stopped". The az row must still read
  # "running" (from the inspect), which is only possible if the re-probe is
  # skipped. If the optimization regresses, az shows "stopped" and this fails.
  mkdir -p "$TEST_TEMP/project"
  local main_cname az_cname
  main_cname="$(container_name_for "$TEST_TEMP/project" main)"
  az_cname="$(container_name_for "$TEST_TEMP/project" az)"
  printf '%s\n' "$main_cname" > "$DOCKER_MOCK_DIR/ps_output"
  printf '%s\n' "$az_cname"   > "$DOCKER_MOCK_DIR/ps_a_output"
  printf 'az|true|%s\n' "$TEST_TEMP/project" > "$DOCKER_MOCK_DIR/inspect_output"
  run cmd_status "$TEST_TEMP/project"
  assert_success
  assert_output --partial "az"
  refute_output --partial "stopped"
}

@test "box ps: shows the box column from the sh.cleat.box label" {
  local cname="cleat-proj-abcdef12-az"
  printf '%s\t%s\n' "$cname" "Up 1 minute" > "$DOCKER_MOCK_DIR/ps_a_output"
  # cmd_ps does ONE combined inspect per row: box|running|workspace-source.
  printf 'az|true|%s\n' "$TEST_TEMP/project" > "$DOCKER_MOCK_DIR/inspect_output"
  run cmd_ps
  assert_success
  assert_output --partial "box: az"
}

@test "box ps: one combined inspect per row (no per-field re-inspect / extra ps)" {
  # Efficiency contract: cmd_ps must read box label, running state AND the
  # workspace path from a SINGLE inspect per container, not 2 inspects + a ps.
  local cname="cleat-proj-abcdef12-az"
  printf '%s\t%s\n' "$cname" "Up 1 minute" > "$DOCKER_MOCK_DIR/ps_a_output"
  printf 'az|true|%s\n' "$TEST_TEMP/project" > "$DOCKER_MOCK_DIR/inspect_output"
  : > "$DOCKER_CALLS"
  cmd_ps >/dev/null
  local n_inspect n_ps
  n_inspect="$(grep -c '^docker inspect ' "$DOCKER_CALLS" || true)"
  # The only allowed `docker ps` is the single outer list; no per-row ps for colour.
  n_ps="$(grep -c '^docker ps ' "$DOCKER_CALLS" || true)"
  [[ "$n_inspect" -eq 1 ]] || { echo "expected exactly 1 inspect, got $n_inspect"; cat "$DOCKER_CALLS"; return 1; }
  [[ "$n_ps" -eq 1 ]]      || { echo "expected exactly 1 ps, got $n_ps"; cat "$DOCKER_CALLS"; return 1; }
}

@test "box ps: a literal '|' in the project path survives the combined-inspect parse" {
  # Field order is box|running|path precisely so a '|' in the path (legal on
  # disk) lands in the trailing field and is shown verbatim, not truncated.
  local cname="cleat-proj-abcdef12"
  printf '%s\t%s\n' "$cname" "Up 1 minute" > "$DOCKER_MOCK_DIR/ps_a_output"
  printf 'main|true|/home/me/weird|dir\n' > "$DOCKER_MOCK_DIR/inspect_output"
  run cmd_ps
  assert_success
  assert_output --partial "/home/me/weird|dir"
}

# ── Phase 6: box descriptions (host-side, never recreates) ──────────────────

@test "box describe: set then show round-trips the description" {
  mkdir -p "$TEST_TEMP/project"
  cd "$TEST_TEMP/project"
  cmd_describe az "cloud box - az login lives here" >/dev/null
  run cmd_describe az
  assert_success
  assert_output --partial "cloud box - az login lives here"
}

@test "box describe: setting a description makes NO docker calls (never recreates)" {
  mkdir -p "$TEST_TEMP/project"
  cd "$TEST_TEMP/project"
  : > "$DOCKER_CALLS"
  cmd_describe az "prod deploys only" >/dev/null
  run grep -E '^docker (run|rm|create|commit)' "$DOCKER_CALLS"
  assert_failure   # no such calls recorded → grep fails → describe never touched docker
}

@test "box describe: --desc at start writes the box description" {
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project"
  _CLI_DESC="untrusted PR review"; _CLI_DESC_SET=1
  _BOX="dev"
  run cmd_run "$TEST_TEMP/project"
  assert_success
  local cname; cname="$(container_name_for "$TEST_TEMP/project" dev)"
  run _box_desc_read "$cname"
  assert_output --partial "untrusted PR review"
}

@test "box describe: cleat rm removes the box description" {
  mkdir -p "$TEST_TEMP/project"
  local cname; cname="$(container_name_for "$TEST_TEMP/project" az)"
  _box_desc_write "$cname" "temporary"
  [[ -f "$(_box_desc_file "$cname")" ]] || return 1
  mock_docker_ps_a "$cname"
  _BOX="az"
  run cmd_rm "$TEST_TEMP/project"
  assert_success
  [[ ! -f "$(_box_desc_file "$cname")" ]] || { echo "desc not removed by cleat rm"; return 1; }
}

@test "box describe: a recreate (cmd_run) preserves the description" {
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project"
  local cname; cname="$(container_name_for "$TEST_TEMP/project" az)"
  _box_desc_write "$cname" "survives recreate"
  _BOX="az"
  run cmd_run "$TEST_TEMP/project"
  assert_success
  run _box_desc_read "$cname"
  assert_output --partial "survives recreate"
}

@test "box describe: a set description is shown in cleat status" {
  mkdir -p "$TEST_TEMP/project"
  local cname; cname="$(container_name_for "$TEST_TEMP/project" main)"
  _box_desc_write "$cname" "the main box notes"
  run cmd_status "$TEST_TEMP/project"
  assert_success
  assert_output --partial "the main box notes"
}
