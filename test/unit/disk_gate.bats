#!/usr/bin/env bats
# The two-tier disk-fill advisory + gate (_maybe_gate_on_disk_fill), the engine
# classifier (_disk_help_kind), the fill reader (_read_container_disk_use), and
# the per-engine lever copy (_disk_lever_short). Keyed on cap-relative Use% AND a
# low-free floor, so a 95%-full 1.8 TB disk with 90 GB free never fires. Fully
# fail-soft off a TTY or on an unreadable fill.

load "../setup"

setup() {
  _common_setup
  use_docker_stub
  source_cli
  DISK_CHECK_FILE="$TEST_TEMP/disk_check"
  DISK_CHECK_INTERVAL=86400
  # Defaults: TTY yes, non-interactive (no hold read), unicode off, cleat has
  # some reclaimable images, a known engine kind.
  _is_tty() { return 0; }
  _is_interactive() { return 1; }
  _has_unicode() { return 1; }
  _cleat_prunable_stats() { printf '3\t7168'; }   # ~7 GB reclaimable images
  # Deterministic engine (desktop) for the gate/advisory copy WITHOUT shadowing
  # the real _disk_help_kind the classifier tests below exercise.
  _is_docker_desktop() { return 0; }
}
teardown() { _common_teardown; }

# avail_kb for N GB = N * 1048576.

@test "disk check: silent below the advisory band" {
  _read_container_disk_use() { echo "70 524288000"; }   # 70%, ~500 GB free
  run _maybe_gate_on_disk_fill "cleat-x"
  assert_success
  assert_output ""
}

@test "disk advisory: fires in the 85-94 band with low free" {
  _read_container_disk_use() { echo "88 5242880"; }      # 88%, 5 GB free
  run _maybe_gate_on_disk_fill "cleat-x"
  assert_success
  assert_output --partial "88% full"
  assert_output --partial "cleat storage"
  assert_output --partial "cleat prune"
  refute_output --partial "almost full"
}

@test "disk advisory: the low-free floor suppresses a high pct with lots free" {
  _read_container_disk_use() { echo "88 94371840"; }     # 88%, 90 GB free
  run _maybe_gate_on_disk_fill "cleat-x"
  assert_success
  assert_output ""
}

@test "disk gate: the low-free floor suppresses 96% with 90 GB free (the 1.8 TB Mac)" {
  _read_container_disk_use() { echo "96 94371840"; }     # 96%, 90 GB free
  run _maybe_gate_on_disk_fill "cleat-x"
  assert_success
  assert_output ""
}

@test "disk gate: fires the amber banner at 96% with low free" {
  _read_container_disk_use() { echo "96 2097152"; }      # 96%, 2 GB free
  run _maybe_gate_on_disk_fill "cleat-x"
  assert_success
  assert_output --partial "almost full"
  assert_output --partial "96% full"
  assert_output --partial "about to fail"
}

@test "disk gate: honest copy when cleat has nothing to reclaim" {
  _cleat_prunable_stats() { printf '0\t0'; }
  _read_container_disk_use() { echo "97 1048576"; }      # 97%, 1 GB free
  run _maybe_gate_on_disk_fill "cleat-x"
  assert_success
  assert_output --partial "not the bulk here"
  refute_output --partial "Cleat can reclaim ~"
}

@test "disk gate: shows the hold prompt when interactive" {
  _is_interactive() { return 0; }
  _read_container_disk_use() { echo "98 1048576"; }
  run _maybe_gate_on_disk_fill "cleat-x" < /dev/null
  assert_success
  assert_output --partial "Press"
  assert_output --partial "CLEAT_NO_DISK_GATE=1"
  assert_output --partial "leaves the box running"
}

@test "disk gate: CLEAT_NO_DISK_GATE=1 keeps the banner but skips the hold" {
  _is_interactive() { return 0; }
  export CLEAT_NO_DISK_GATE=1
  _read_container_disk_use() { echo "98 1048576"; }
  run _maybe_gate_on_disk_fill "cleat-x"
  assert_success
  assert_output --partial "almost full"
  refute_output --partial "Press "
}

@test "disk check: silent off a TTY (pipe / CI)" {
  _is_tty() { return 1; }
  _read_container_disk_use() { echo "99 1048576"; }
  run _maybe_gate_on_disk_fill "cleat-x"
  assert_success
  assert_output ""
}

@test "disk check: silent on an unreadable fill" {
  _read_container_disk_use() { echo ""; }
  run _maybe_gate_on_disk_fill "cleat-x"
  assert_success
  assert_output ""
}

@test "disk check: silent on an empty box name" {
  _read_container_disk_use() { echo "99 1048576"; }
  run _maybe_gate_on_disk_fill ""
  assert_success
  assert_output ""
}

@test "disk advisory: daily-throttled by its own stamp" {
  _read_container_disk_use() { echo "88 5242880"; }
  echo "$(date +%s)" > "$DISK_CHECK_FILE"
  run _maybe_gate_on_disk_fill "cleat-x"
  assert_success
  assert_output ""
}

@test "disk gate: NOT throttled, fires even with a fresh stamp" {
  _read_container_disk_use() { echo "97 1048576"; }
  echo "$(date +%s)" > "$DISK_CHECK_FILE"
  run _maybe_gate_on_disk_fill "cleat-x"
  assert_success
  assert_output --partial "almost full"
}

# ── _disk_help_kind classifier ───────────────────────────────────────────────

@test "disk kind: Docker Desktop wins first (any OS)" {
  _is_docker_desktop() { return 0; }
  run _disk_help_kind
  assert_output "desktop"
}

@test "disk kind: OrbStack on macOS" {
  _is_docker_desktop() { return 1; }
  _is_macos() { return 0; }
  _autostart_pick() { echo orbstack; }
  run _disk_help_kind
  assert_output "orbstack"
}

@test "disk kind: Colima (named profile) on macOS" {
  _is_docker_desktop() { return 1; }
  _is_macos() { return 0; }
  _autostart_pick() { echo "colima:work"; }
  run _disk_help_kind
  assert_output "colima"
}

@test "disk kind: native Linux host" {
  _is_docker_desktop() { return 1; }
  _is_macos() { return 1; }
  _is_wsl() { return 1; }
  _docker_endpoint_is_remote() { return 1; }
  run _disk_help_kind
  assert_output "linux-host"
}

@test "disk kind: WSL in-distro is its own kind, not linux-host" {
  _is_docker_desktop() { return 1; }
  _is_macos() { return 1; }
  _is_wsl() { return 0; }
  run _disk_help_kind
  assert_output "wsl"
}

@test "disk kind: a remote endpoint degrades to generic" {
  _is_docker_desktop() { return 1; }
  _is_macos() { return 1; }
  _is_wsl() { return 1; }
  _docker_endpoint_is_remote() { return 0; }
  run _disk_help_kind
  assert_output "generic"
}

# ── _disk_lever_short per-engine copy ────────────────────────────────────────

@test "disk lever: desktop names the slider PATH, never a version-drifting label" {
  run _disk_lever_short desktop
  assert_output --partial "Settings"
  assert_output --partial "Resources"
  assert_output --partial "Advanced"
  assert_output --partial "cleat prune --cache"
  refute_output --partial "Disk usage limit"
  refute_output --partial "Disk image size"
}

@test "disk lever: orbstack has no slider" {
  run _disk_lever_short orbstack
  assert_output --partial "no size slider"
  refute_output --partial "Settings"
}

@test "disk lever: colima names the disk-resize command and fstrim" {
  run _disk_lever_short colima
  assert_output --partial "colima start --disk"
  assert_output --partial "fstrim"
}

@test "disk lever: linux-host says immediate free, no slider" {
  run _disk_lever_short linux-host
  assert_output --partial "immediately"
  refute_output --partial "slider"
}

@test "disk lever: wsl names set-sparse" {
  run _disk_lever_short wsl
  assert_output --partial "set-sparse"
}

@test "disk lever: generic has no host-specific advice" {
  run _disk_lever_short generic
  assert_output --partial "docker system df"
  refute_output --partial "slider"
}

# ── _read_container_disk_use parses the shared-store fill ─────────────────────

@test "disk read: parses Use% and avail from the root row, skipping the header" {
  docker() { printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\noverlay 62914560 59768832 3145728 95%% /\n'; }
  run _read_container_disk_use "cleat-x"
  assert_output "95 3145728"
}

@test "disk read: silent on an empty box name" {
  run _read_container_disk_use ""
  assert_success
  assert_output ""
}

# ── gate free-floor distinguishes from the advisory floor ────────────────────

@test "disk gate: 96% with 20 GB free is advisory-only, not a hold" {
  _read_container_disk_use() { echo "96 20971520"; }   # 96%, 20 GB free
  run _maybe_gate_on_disk_fill "cleat-x"
  assert_success
  assert_output --partial "96% full"
  refute_output --partial "almost full"
}

# ── WSL wins even under Docker Desktop (the WSL2 backend has no disk slider) ──

@test "disk kind: WSL wins even under Docker Desktop (WSL2 backend)" {
  _is_wsl() { return 0; }
  _is_docker_desktop() { return 0; }
  run _disk_help_kind
  assert_output "wsl"
}

# ── ENOSPC backstop (box too full to start) ──────────────────────────────────

@test "disk ENOSPC backstop: explains a full-store bring-up failure" {
  local errfile="$TEST_TEMP/dockerr"
  printf 'docker: write /var/lib/docker/overlay2/x: no space left on device.\n' > "$errfile"
  run _maybe_explain_enospc "$errfile"
  assert_success
  assert_output --partial "is full"
  assert_output --partial "could not start"
  assert_output --partial "cleat prune --cache"
}

@test "disk ENOSPC backstop: silent on a non-space docker error" {
  local errfile="$TEST_TEMP/dockerr"
  printf 'docker: some other error.\n' > "$errfile"
  run _maybe_explain_enospc "$errfile"
  assert_success
  assert_output ""
}

@test "disk ENOSPC backstop: silent on a missing file" {
  run _maybe_explain_enospc "$TEST_TEMP/does-not-exist"
  assert_success
  assert_output ""
}
