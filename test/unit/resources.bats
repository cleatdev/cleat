#!/usr/bin/env bats
# Per-box resource limits. The old fixed `--memory 8g` EXCEEDED the default
# Docker Desktop VM (7.75 GiB), so the per-box ceiling never bound: a runaway
# process swap-thrashed the whole VM and froze every concurrent session at
# once (observed live: 1 GiB VM swap 78% consumed, 7 kernel OOM kills). The
# limit is now resolved per box — project [resources] > global [resources] >
# a VM-derived default clamped to [2g, 8g] — and swap is pinned to the same
# value so a runaway box OOMs inside its own cgroup.

load "../setup"

setup() {
  _common_setup
  use_docker_stub
  source_cli
  CLEAT_CONFIG_DIR="$TEST_TEMP/cleat-config"
  CLEAT_GLOBAL_CONFIG="$CLEAT_CONFIG_DIR/config"
  mkdir -p "$CLEAT_CONFIG_DIR"
  PROJECT="$TEST_TEMP/project"
  mkdir -p "$PROJECT"
}

teardown() { _common_teardown; }

# ── [resources] parsing ──────────────────────────────────────────────────────

@test "resources: reads memory from the [resources] section" {
  printf '[caps]\ngit\n\n[resources]\nmemory = 4g\n' > "$PROJECT/.cleat"
  run _read_resource_from_file "$PROJECT/.cleat" memory
  assert_output "4g"
}

@test "resources: tolerates CRLF, comments, and missing spaces around =" {
  printf '[resources]\r\n# heap for big builds\r\nmemory=3g\r\n' > "$PROJECT/.cleat"
  run _read_resource_from_file "$PROJECT/.cleat" memory
  assert_output "3g"
}

@test "resources: ignores keys outside the [resources] section" {
  printf '[caps]\nmemory = 6g\n' > "$PROJECT/.cleat"
  run _read_resource_from_file "$PROJECT/.cleat" memory
  assert_output ""
}

@test "resources: missing file yields nothing" {
  run _read_resource_from_file "$PROJECT/.does-not-exist" memory
  assert_success
  assert_output ""
}

# ── resolution precedence ────────────────────────────────────────────────────

@test "resources: project config wins over global config" {
  printf '[resources]\nmemory = 3g\n' > "$PROJECT/.cleat"
  printf '[resources]\nmemory = 6g\n' > "$CLEAT_GLOBAL_CONFIG"
  run resolve_box_memory "$PROJECT"
  assert_output "3g"
}

@test "resources: a box file replaces the project file (least-privilege shape)" {
  printf '[resources]\nmemory = 6g\n' > "$PROJECT/.cleat"
  printf '[resources]\nmemory = 3g\n' > "$PROJECT/.cleat.dev"
  run resolve_box_memory "$PROJECT" "dev"
  assert_output "3g"
}

@test "resources: global config applies when the project has none" {
  printf '[resources]\nmemory = 5g\n' > "$CLEAT_GLOBAL_CONFIG"
  run resolve_box_memory "$PROJECT"
  assert_output "5g"
}

@test "resources: no config falls back to the VM-derived default" {
  _docker_vm_memory() { echo ""; }
  run resolve_box_memory "$PROJECT"
  assert_output "2g"
}

@test "resources: an invalid project value falls through to the global value" {
  printf '[resources]\nmemory = lots\n' > "$PROJECT/.cleat"
  printf '[resources]\nmemory = 4g\n' > "$CLEAT_GLOBAL_CONFIG"
  run resolve_box_memory "$PROJECT"
  assert_output --partial "4g"
  assert_output --partial "Ignoring invalid memory"
}

@test "resources: a project value above 8g is clamped (untrusted repo config)" {
  # .cleat ships with the repo: a hostile project must not be able to
  # re-introduce VM-wide overcommit. The user's own global config is not
  # capped.
  printf '[resources]\nmemory = 999g\n' > "$PROJECT/.cleat"
  run resolve_box_memory "$PROJECT"
  assert_output "8g"
}

@test "resources: a global value above 8g is honored as-is" {
  printf '[resources]\nmemory = 12g\n' > "$CLEAT_GLOBAL_CONFIG"
  run resolve_box_memory "$PROJECT"
  assert_output "12g"
}

@test "resources: zero is rejected as invalid" {
  printf '[resources]\nmemory = 0\n' > "$PROJECT/.cleat"
  _docker_vm_memory() { echo ""; }
  run resolve_box_memory "$PROJECT"
  assert_output --partial "2g"
  assert_output --partial "Ignoring invalid memory"
}

@test "resources: zero-spellings like 00g are rejected (docker reads 0 as unlimited)" {
  # "00g" slipped past the old `!= "0"` check, and --memory 0 is UNLIMITED in
  # docker — an untrusted .cleat could spell zero to bypass the 8g clamp.
  printf '[resources]\nmemory = 00g\n' > "$PROJECT/.cleat"
  _docker_vm_memory() { echo ""; }
  run resolve_box_memory "$PROJECT"
  assert_output --partial "2g"
  assert_output --partial "Ignoring invalid memory"
}

@test "resources: leading zeros are not parsed as octal" {
  # Bare $((08 * …)) is an octal parse error that would kill the CLI under
  # set -e. "08g" must validate, convert, and clamp exactly like "8g".
  printf '[resources]\nmemory = 08g\n' > "$PROJECT/.cleat"
  run resolve_box_memory "$PROJECT"
  assert_output "08g"
}

@test "resources: a 64-bit-overflowing suffixed value is rejected, not wrapped past the clamp" {
  # 99999999999g overflows int64 in the bytes conversion; the wrapped product
  # compares small (or negative) and used to sail past the 8g project clamp —
  # then dockerd rejected it and the start aborted with an opaque error.
  printf '[resources]\nmemory = 99999999999g\n' > "$PROJECT/.cleat"
  _docker_vm_memory() { echo ""; }
  run resolve_box_memory "$PROJECT"
  assert_output --partial "2g"
  assert_output --partial "Ignoring invalid memory"
}

@test "resources: a 64-bit-overflowing raw-byte value is rejected" {
  printf '[resources]\nmemory = 18446744073709551616\n' > "$PROJECT/.cleat"   # 2^64
  _docker_vm_memory() { echo ""; }
  run resolve_box_memory "$PROJECT"
  assert_output --partial "2g"
  assert_output --partial "Ignoring invalid memory"
}

@test "resources: the 8g project clamp also binds raw-byte values" {
  printf '[resources]\nmemory = 10737418240\n' > "$PROJECT/.cleat"   # 10 GiB in bytes
  run resolve_box_memory "$PROJECT"
  assert_output "8g"
}

# ── VM-derived default ───────────────────────────────────────────────────────

@test "resources: default is a quarter of the VM, floored at 2g" {
  _docker_vm_memory() { echo "8589934592"; }   # 8 GiB VM → quarter = 2g
  run _default_box_memory
  assert_output "2g"
}

@test "resources: default scales with a bigger VM" {
  _docker_vm_memory() { echo "17179869184"; }  # 16 GiB VM → 4g
  run _default_box_memory
  assert_output "4g"
}

@test "resources: default is capped at 8g on huge VMs" {
  _docker_vm_memory() { echo "68719476736"; }  # 64 GiB VM → quarter 16g → cap
  run _default_box_memory
  assert_output "8g"
}

@test "resources: unknown VM size falls back to 2g" {
  _docker_vm_memory() { echo "garbage"; }
  run _default_box_memory
  assert_output "2g"
}

# ── cpus ─────────────────────────────────────────────────────────────────────
# CPU has NO default limit: it's work-conserving (an idle core costs nothing,
# the scheduler balances competing boxes), unlike memory which is held. The
# limit exists for users who want a box pinned below the machine — and a
# project-supplied value is clamped to the daemon's core count because dockerd
# ERRORS on --cpus above NCPU (an untrusted .cleat must not abort the start).

@test "resources: reads cpus from the project [resources] section" {
  printf '[resources]\ncpus = 2\n' > "$PROJECT/.cleat"
  run resolve_box_cpus "$PROJECT"
  assert_output "2"
}

@test "resources: cpus accepts decimal values" {
  printf '[resources]\ncpus = 1.5\n' > "$PROJECT/.cleat"
  run resolve_box_cpus "$PROJECT"
  assert_output "1.5"
}

@test "resources: no cpus config means no limit" {
  run resolve_box_cpus "$PROJECT"
  assert_success
  assert_output ""
}

@test "resources: an invalid project cpus falls through to the global value" {
  printf '[resources]\ncpus = fast\n' > "$PROJECT/.cleat"
  printf '[resources]\ncpus = 2\n' > "$CLEAT_GLOBAL_CONFIG"
  run resolve_box_cpus "$PROJECT"
  assert_output --partial "2"
  assert_output --partial "Ignoring invalid cpus"
}

@test "resources: zero cpus is rejected (docker reads 0 as no limit)" {
  printf '[resources]\ncpus = 0.0\n' > "$PROJECT/.cleat"
  run resolve_box_cpus "$PROJECT"
  assert_output --partial "Ignoring invalid cpus"
}

@test "resources: a project cpus above the daemon's cores is clamped" {
  printf '[resources]\ncpus = 64\n' > "$PROJECT/.cleat"
  _daemon_ncpu() { echo "8"; }
  run resolve_box_cpus "$PROJECT"
  assert_output "8"
}

@test "resources: a project cpus within the core count passes through" {
  printf '[resources]\ncpus = 2\n' > "$PROJECT/.cleat"
  _daemon_ncpu() { echo "8"; }
  run resolve_box_cpus "$PROJECT"
  assert_output "2"
}

@test "resources: the user's global cpus is not clamped" {
  printf '[resources]\ncpus = 64\n' > "$CLEAT_GLOBAL_CONFIG"
  _daemon_ncpu() { echo "8"; }
  run resolve_box_cpus "$PROJECT"
  assert_output "64"
}

@test "resources: unknown core count passes the project value through (fail open)" {
  printf '[resources]\ncpus = 64\n' > "$PROJECT/.cleat"
  _daemon_ncpu() { echo ""; }
  run resolve_box_cpus "$PROJECT"
  assert_output "64"
}

# ── container creation wiring ────────────────────────────────────────────────

@test "resources: a configured memory limit reaches docker run, swap pinned equal" {
  mock_docker_images "cleat"
  printf '[resources]\nmemory = 3g\n' > "$PROJECT/.cleat"
  local cname
  cname="$(container_name_for "$PROJECT")"
  run cmd_run "$PROJECT"
  assert_success
  run assert_docker_run_has "$cname" "--memory 3g"
  assert_success
  run assert_docker_run_has "$cname" "--memory-swap 3g"
  assert_success
}

@test "resources: a configured cpus limit reaches docker run" {
  mock_docker_images "cleat"
  printf '[resources]\ncpus = 2\n' > "$PROJECT/.cleat"
  local cname
  cname="$(container_name_for "$PROJECT")"
  run cmd_run "$PROJECT"
  assert_success
  run assert_docker_run_has "$cname" "--cpus 2"
  assert_success
}

@test "resources: no --cpus on docker run when unconfigured" {
  mock_docker_images "cleat"
  local cname
  cname="$(container_name_for "$PROJECT")"
  run cmd_run "$PROJECT"
  assert_success
  run assert_docker_run_lacks "$cname" "--cpus"
  assert_success
}

# ── drift fingerprint ────────────────────────────────────────────────────────

@test "resources: changing the memory limit changes the config fingerprint" {
  ACTIVE_CAPS=()
  _RESOLVED_ENV_ARGS=()
  resolve_box_memory() { echo "2g"; }
  local before after
  before="$(compute_config_fingerprint "$PROJECT")"
  resolve_box_memory() { echo "4g"; }
  after="$(compute_config_fingerprint "$PROJECT")"
  [ "$before" != "$after" ]
}

@test "resources: changing the cpus limit changes the config fingerprint" {
  ACTIVE_CAPS=()
  _RESOLVED_ENV_ARGS=()
  resolve_box_memory() { echo "2g"; }
  resolve_box_cpus() { echo "2"; }
  local before after
  before="$(compute_config_fingerprint "$PROJECT")"
  resolve_box_cpus() { echo "4"; }
  after="$(compute_config_fingerprint "$PROJECT")"
  [ "$before" != "$after" ]
}

# ── node heap pin ────────────────────────────────────────────────────────────

@test "resources: session pins node's heap to 60% of the box memory limit" {
  _host_clip_cmd() { echo ""; }
  _wait_for_coder_remap() { true; }
  _ensure_docker_access() { true; }
  mock_docker_inspect "2147483648"   # 2 GiB box limit → 60% = 1228 MB
  run exec_claude "test-ctr" --dangerously-skip-permissions
  run assert_docker_exec_has "NODE_OPTIONS=--max-old-space-size=1228"
  assert_success
}

@test "resources: no heap pin when the box has no memory limit" {
  _host_clip_cmd() { echo ""; }
  _wait_for_coder_remap() { true; }
  _ensure_docker_access() { true; }
  mock_docker_inspect "0"
  run exec_claude "test-ctr" --dangerously-skip-permissions
  run bash -c "grep 'NODE_OPTIONS' '$DOCKER_CALLS'"
  assert_failure
}
