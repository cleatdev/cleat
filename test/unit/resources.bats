#!/usr/bin/env bats
# Per-box resource limits. The old fixed `--memory 8g` EXCEEDED the default
# Docker Desktop VM (7.75 GiB), so the per-box ceiling never bound: a runaway
# process swap-thrashed the whole VM and froze every concurrent session at
# once (observed live: 1 GiB VM swap 78% consumed, 7 kernel OOM kills). The
# limit is now resolved per box (project [resources] > global [resources] >
# a VM-derived default clamped to [4g, 8g]) and swap is pinned to the same
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

@test "resources: reads memory when the file has NO trailing newline" {
  # A hand-edited .cleat ending in `memory = 8g` with no final newline silently
  # dropped the ceiling before the fix (read returns non-zero at EOF), so the
  # box fell back to the VM-derived default instead of the configured limit.
  printf '[resources]\nmemory = 8g' > "$PROJECT/.cleat"
  run _read_resource_from_file "$PROJECT/.cleat" memory
  assert_success
  assert_output "8g"
}

@test "resources: reads cpus when the file has NO trailing newline" {
  printf '[resources]\ncpus = 2' > "$PROJECT/.cleat"
  run _read_resource_from_file "$PROJECT/.cleat" cpus
  assert_success
  assert_output "2"
}

@test "resources: first value wins on a duplicate key" {
  printf '[resources]\nmemory = 4g\nmemory = 8g\n' > "$PROJECT/.cleat"
  run _read_resource_from_file "$PROJECT/.cleat" memory
  assert_success
  assert_output "4g"
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
  # docker: an untrusted .cleat could spell zero to bypass the 8g clamp.
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
  # compares small (or negative) and used to sail past the 8g project clamp,
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

@test "resources: default is a quarter of the VM, floored at 4g" {
  _docker_vm_memory() { echo "8589934592"; }   # 8 GiB VM → quarter 2g → floor 4g
  run _default_box_memory
  assert_output "4g"
}

@test "resources: default scales with a bigger VM (between floor and cap)" {
  _docker_vm_memory() { echo "25769803776"; }  # 24 GiB VM → quarter 6g (strictly 4<6<8)
  run _default_box_memory
  assert_output "6g"
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

# ── host RAM detection (_host_total_memory) ──────────────────────────────────
# Exercises the REAL Linux /proc/meminfo path (not a function override): reading
# MemTotal must yield a plain integer of bytes. `awk '{print $2 * 1024}'` would
# emit scientific notation (e.g. 3.36e+10) for real RAM sizes, which fails the
# ^[0-9]+$ check every consumer uses → host RAM silently treated as unknown.

@test "resources: _host_total_memory reads /proc/meminfo as a plain integer of bytes" {
  uname() { echo "Linux"; }   # force the /proc/meminfo branch regardless of CI host OS
  local mi="$TEST_TEMP/meminfo"
  printf 'MemTotal:       32910736 kB\nMemFree:         1048576 kB\n' > "$mi"
  _MEMINFO_FILE="$mi" run _host_total_memory
  assert_success
  # Plain integer (no sci-notation), and exactly kB * 1024.
  [[ "$output" =~ ^[0-9]+$ ]] || { echo "not a plain integer: '$output'"; return 1; }
  assert_output "33700593664"
}

@test "resources: _host_total_memory is empty when meminfo is unreadable" {
  uname() { echo "Linux"; }
  _MEMINFO_FILE="$TEST_TEMP/does-not-exist"
  run _host_total_memory
  assert_success
  assert_output ""
}

# ── cpus ─────────────────────────────────────────────────────────────────────
# CPU has NO default limit: it's work-conserving (an idle core costs nothing,
# the scheduler balances competing boxes), unlike memory which is held. The
# limit exists for users who want a box pinned below the machine, and a
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

# ── configured-resource resolvers (fingerprint-only) ─────────────────────────
#
# _configured_box_memory / _configured_box_cpus read DECLARED config only, never
# the VM-derived default or the daemon clamp, so the fingerprint can't move when
# the VM is resized or the CLI's default formula changes (the v0.16.4 false-recreate fix).

@test "configured memory: empty when nothing is declared" {
  run _configured_box_memory "$PROJECT" main
  assert_success
  assert_output ""
}

@test "configured memory: returns the project [resources] value" {
  printf '[resources]\nmemory = 4g\n' > "$PROJECT/.cleat"
  run _configured_box_memory "$PROJECT" main
  assert_output "4g"
}

@test "configured memory: clamps a project value over 8g (matches resolve_box_memory)" {
  printf '[resources]\nmemory = 32g\n' > "$PROJECT/.cleat"
  run _configured_box_memory "$PROJECT" main
  assert_output "8g"
}

@test "configured memory: ignores an invalid project value (no drift on a typo)" {
  printf '[resources]\nmemory = lots\n' > "$PROJECT/.cleat"
  run _configured_box_memory "$PROJECT" main
  assert_success
  assert_output ""
}

@test "configured cpus: empty when nothing is declared" {
  run _configured_box_cpus "$PROJECT" main
  assert_success
  assert_output ""
}

@test "configured cpus: returns the configured value WITHOUT the daemon clamp" {
  # resolve_box_cpus clamps to the core count; the fingerprint variant must NOT,
  # so resizing the VM's cores can't drift the hash of a box that declared cpus.
  printf '[resources]\ncpus = 64\n' > "$PROJECT/.cleat"
  _daemon_ncpu() { echo "4"; }
  run _configured_box_cpus "$PROJECT" main
  assert_output "64"
}

@test "configured memory: falls back to the global config (uncapped, matching resolve_box_memory)" {
  rm -f "$PROJECT/.cleat"                                  # nothing at project level
  printf '[resources]\nmemory = 12g\n' > "$CLEAT_GLOBAL_CONFIG"
  run _configured_box_memory "$PROJECT" main
  assert_output "12g"                                      # global is read AND not clamped to 8g
}

@test "configured cpus: falls back to the global config value" {
  rm -f "$PROJECT/.cleat"
  printf '[resources]\ncpus = 6\n' > "$CLEAT_GLOBAL_CONFIG"
  run _configured_box_cpus "$PROJECT" main
  assert_output "6"
}

# ── drift fingerprint ────────────────────────────────────────────────────────

@test "resources: changing configured [resources] memory changes the fingerprint" {
  ACTIVE_CAPS=()
  _RESOLVED_ENV_ARGS=()
  printf '[resources]\nmemory = 2g\n' > "$PROJECT/.cleat"
  local before after
  before="$(compute_config_fingerprint "$PROJECT")"
  printf '[resources]\nmemory = 4g\n' > "$PROJECT/.cleat"
  after="$(compute_config_fingerprint "$PROJECT")"
  [ "$before" != "$after" ]
}

@test "resources: changing configured [resources] cpus changes the fingerprint" {
  ACTIVE_CAPS=()
  _RESOLVED_ENV_ARGS=()
  printf '[resources]\ncpus = 2\n' > "$PROJECT/.cleat"
  local before after
  before="$(compute_config_fingerprint "$PROJECT")"
  printf '[resources]\ncpus = 4\n' > "$PROJECT/.cleat"
  after="$(compute_config_fingerprint "$PROJECT")"
  [ "$before" != "$after" ]
}

@test "resources: resizing the Docker VM does NOT change the fingerprint (unconfigured box)" {
  # THE v0.16.4 FIX. With the old code (resolve_box_memory in the fingerprint) a
  # 7 GiB VM hashed memory=4g and a 40 GiB VM hashed memory=8g, so a memory-slider
  # change fired a false "config changed, recreate?" on an untouched box. The
  # fingerprint now reads configured-only, so an unconfigured box is VM-invariant.
  ACTIVE_CAPS=()
  _RESOLVED_ENV_ARGS=()
  rm -f "$PROJECT/.cleat"
  local small large
  _docker_vm_memory() { echo "$(( 7 * 1073741824 ))"; }
  small="$(compute_config_fingerprint "$PROJECT")"
  _docker_vm_memory() { echo "$(( 40 * 1073741824 ))"; }
  large="$(compute_config_fingerprint "$PROJECT")"
  [ "$small" == "$large" ]
}

@test "resources: the daemon core count does NOT change the fingerprint (unconfigured box)" {
  ACTIVE_CAPS=()
  _RESOLVED_ENV_ARGS=()
  rm -f "$PROJECT/.cleat"
  local few many
  _daemon_ncpu() { echo "2"; }
  few="$(compute_config_fingerprint "$PROJECT")"
  _daemon_ncpu() { echo "32"; }
  many="$(compute_config_fingerprint "$PROJECT")"
  [ "$few" == "$many" ]
}

@test "resources: a configured cpus above the cores does NOT drift the fingerprint when cores change" {
  # resolve_box_cpus clamps a configured value to the daemon's core count, so if
  # the fingerprint used IT, a VM core-count change would drift a box that
  # declared cpus. The configured-only variant keeps the declared value, so the
  # hash stays put. This is the cpus half of the v0.16.4 decoupling.
  ACTIVE_CAPS=()
  _RESOLVED_ENV_ARGS=()
  printf '[resources]\ncpus = 64\n' > "$PROJECT/.cleat"
  local few many
  _daemon_ncpu() { echo "4"; }
  few="$(compute_config_fingerprint "$PROJECT")"
  _daemon_ncpu() { echo "8"; }
  many="$(compute_config_fingerprint "$PROJECT")"
  [ "$few" == "$many" ]
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
