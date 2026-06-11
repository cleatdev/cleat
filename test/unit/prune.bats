#!/usr/bin/env bats
# `cleat prune` + the on-start Docker pressure check. Observed live before
# this existed: 217 dangling images (~120 GB) — every drift rebuild orphaned a
# 1.5-2.5 GB build — plus four superseded ghcr version tags nothing ever
# removed. Prune deletes ONLY cleat-owned image bloat: dangling
# sh.cleat.version images and non-current ghcr.io/cleatdev/cleat tags. Boxes
# (even exited — they're resumable sessions) and other projects' images are
# never touched. The pressure check is the out-of-the-box path: a daily,
# TTY-only prompt that offers the prune when bloat passes ~5 GB, plus a
# notice when running containers' memory limits overcommit the VM.

load "../setup"

setup() {
  _common_setup
  use_docker_stub
  source_cli
  PRESSURE_CHECK_FILE="$TEST_TEMP/pressure_check"
}

teardown() { _common_teardown; }

# ── cmd_prune ────────────────────────────────────────────────────────────────

@test "prune: removes superseded prebuilt tags but never the current version" {
  _prebuilt_image_tags() {
    printf '%s\t%s\n' \
      "${REGISTRY_BASE}:v0.12.2" "1.05GB" \
      "${REGISTRY_BASE}:v${VERSION}" "1.05GB" \
      "${REGISTRY_BASE}:v0.14.0" "1.04GB"
  }
  _dangling_cleat_images() { :; }
  run cmd_prune
  assert_success
  run grep "^docker rmi ${REGISTRY_BASE}:v0.12.2" "$DOCKER_CALLS"
  assert_success
  run grep "^docker rmi ${REGISTRY_BASE}:v0.14.0" "$DOCKER_CALLS"
  assert_success
  run grep "^docker rmi ${REGISTRY_BASE}:v${VERSION}" "$DOCKER_CALLS"
  assert_failure
}

@test "prune: removes dangling cleat-labeled images by id" {
  _prebuilt_image_tags() { :; }
  _dangling_cleat_images() { printf 'aaa111\nbbb222\n'; }
  run cmd_prune
  assert_success
  assert_output --partial "Pruned 2 stale cleat images"
  run grep "^docker rmi aaa111" "$DOCKER_CALLS"
  assert_success
  run grep "^docker rmi bbb222" "$DOCKER_CALLS"
  assert_success
}

@test "prune: reports when there is nothing to do" {
  _prebuilt_image_tags() { :; }
  _dangling_cleat_images() { :; }
  run cmd_prune
  assert_success
  assert_output --partial "Nothing to prune"
  run grep "^docker rmi" "$DOCKER_CALLS"
  assert_failure
}

@test "prune: never stops or removes containers" {
  _prebuilt_image_tags() { printf '%s\t1GB\n' "${REGISTRY_BASE}:v0.12.2"; }
  _dangling_cleat_images() { printf 'aaa111\n'; }
  run cmd_prune
  assert_success
  run grep -E "^docker (rm|stop) " "$DOCKER_CALLS"
  assert_failure
}

@test "prune: an image kept by docker (in use) is counted, not forced" {
  _prebuilt_image_tags() { printf '%s\t1GB\n' "${REGISTRY_BASE}:v0.12.2"; }
  _dangling_cleat_images() { :; }
  export DOCKER_EXIT_CODE=1   # rmi refuses (image in use)
  run cmd_prune
  assert_success
  assert_output --partial "kept (still referenced by a container)"
  run grep -- "-f" "$DOCKER_CALLS"
  assert_failure
}

# ── prunable stats ───────────────────────────────────────────────────────────

@test "prune stats: sums dangling builds and superseded tags, skips current" {
  _dangling_cleat_images() { printf 'aaa111\n'; }
  # The dangling id resolves via docker image inspect — stub returns nothing,
  # so only the tag sizes count here: 1.5GB + skipped current = 1536 MB.
  _prebuilt_image_tags() {
    printf '%s\t%s\n' \
      "${REGISTRY_BASE}:v0.12.2" "1.5GB" \
      "${REGISTRY_BASE}:v${VERSION}" "1.05GB"
  }
  run _cleat_prunable_stats
  assert_output "$(printf '2\t1536')"
}

# ── ownership filters (no seam overrides) ────────────────────────────────────
# The seams are overridden everywhere else, so this is the ONE test that pins
# the real queries: the label filter and the repo scope ARE the enforcement of
# "other projects' images are never touched" on a destructive command.

@test "prune: queries docker with the cleat ownership filters" {
  run cmd_prune
  assert_success
  run grep "^docker images -f dangling=true -f label=sh.cleat.version -q" "$DOCKER_CALLS"
  assert_success
  run grep "^docker images ${REGISTRY_BASE} --format" "$DOCKER_CALLS"
  assert_success
}

# ── routine auto-GC after image acquisition ──────────────────────────────────
# Every pull/build/rebuild orphans the image it replaces (1.5-2.5 GB) — the
# silent prune at those call sites is what keeps daily drift rebuilds from
# accreting the ~120 GB observed live. The call sites redirect stdout/stderr
# to /dev/null, so the spy must leave a marker FILE, not output.

@test "auto-GC: a successful non-TTY pull runs the routine prune" {
  cmd_prune() { touch "$TEST_TEMP/gc_called"; }
  export DOCKER_PULL_EXIT_CODE=0
  run _do_pull
  assert_success
  [ -f "$TEST_TEMP/gc_called" ]
}

@test "auto-GC: a successful TTY pull runs the routine prune" {
  cmd_prune() { touch "$TEST_TEMP/gc_called"; }
  _is_tty() { return 0; }
  export DOCKER_PULL_EXIT_CODE=0
  run _do_pull
  assert_success
  [ -f "$TEST_TEMP/gc_called" ]
}

@test "auto-GC: a local build runs the routine prune" {
  cmd_prune() { touch "$TEST_TEMP/gc_called"; }
  run _do_build
  assert_success
  [ -f "$TEST_TEMP/gc_called" ]
}

@test "auto-GC: cmd_rebuild runs the routine prune" {
  cmd_prune() { touch "$TEST_TEMP/gc_called"; }
  run cmd_rebuild
  assert_success
  [ -f "$TEST_TEMP/gc_called" ]
}

@test "auto-GC: a failed pull does not prune" {
  cmd_prune() { touch "$TEST_TEMP/gc_called"; }
  export DOCKER_PULL_EXIT_CODE=1
  run _do_pull
  assert_failure
  [ ! -f "$TEST_TEMP/gc_called" ]
}

# ── on-start pressure check ──────────────────────────────────────────────────

@test "pressure: silent on a non-TTY run" {
  _cleat_prunable_stats() { printf '9\t99999'; }
  run _maybe_check_docker_pressure
  assert_success
  refute_output --partial "stale cleat images"
}

@test "pressure: offers prune when bloat passes the threshold, prunes on accept" {
  _is_tty() { return 0; }
  _cleat_prunable_stats() { printf '7\t8192'; }
  _docker_vm_memory() { echo ""; }
  cmd_prune() { echo "PRUNE_CALLED"; }
  run _maybe_check_docker_pressure <<< "y"
  assert_success
  assert_output --partial "7 stale cleat images"
  assert_output --partial "PRUNE_CALLED"
}

@test "pressure: declining skips the prune" {
  _is_tty() { return 0; }
  _cleat_prunable_stats() { printf '7\t8192'; }
  _docker_vm_memory() { echo ""; }
  cmd_prune() { echo "PRUNE_CALLED"; }
  run _maybe_check_docker_pressure <<< "n"
  assert_success
  refute_output --partial "PRUNE_CALLED"
}

@test "pressure: silent below the bloat threshold" {
  _is_tty() { return 0; }
  _cleat_prunable_stats() { printf '2\t1024'; }
  _docker_vm_memory() { echo ""; }
  run _maybe_check_docker_pressure
  assert_success
  refute_output --partial "stale cleat images"
}

@test "pressure: warns when running limits overcommit the VM" {
  _is_tty() { return 0; }
  _cleat_prunable_stats() { printf '0\t0'; }
  _docker_vm_memory() { echo "8589934592"; }            # 8 GiB VM
  _running_memory_limits_sum() { echo "42949672960"; }  # 40 GiB promised
  run _maybe_check_docker_pressure
  assert_success
  assert_output --partial "promised 40 GB"
  assert_output --partial "8 GB"
}

@test "pressure: silent when limits fit the VM" {
  _is_tty() { return 0; }
  _cleat_prunable_stats() { printf '0\t0'; }
  _docker_vm_memory() { echo "8589934592"; }
  _running_memory_limits_sum() { echo "4294967296"; }
  run _maybe_check_docker_pressure
  assert_success
  refute_output --partial "promised"
}

@test "pressure: throttled to once per interval" {
  _is_tty() { return 0; }
  _cleat_prunable_stats() { printf '7\t8192'; }
  _docker_vm_memory() { echo ""; }
  cmd_prune() { echo "PRUNE_CALLED"; }
  _maybe_check_docker_pressure <<< "n" > /dev/null 2>&1 || true
  run _maybe_check_docker_pressure <<< "n"
  assert_success
  refute_output --partial "stale cleat images"
}

@test "pressure: a stale throttle stamp re-arms the check" {
  _is_tty() { return 0; }
  _cleat_prunable_stats() { printf '7\t8192'; }
  _docker_vm_memory() { echo ""; }
  cmd_prune() { echo "PRUNE_CALLED"; }
  echo "100" > "$PRESSURE_CHECK_FILE"   # epoch-ancient
  run _maybe_check_docker_pressure <<< "n"
  assert_success
  assert_output --partial "stale cleat images"
}

# ── main() wiring ────────────────────────────────────────────────────────────
# The check only protects users if the session-launching verbs actually reach
# it. Spy with a marker file: parts of main run with output captured.

@test "pressure: session-launching commands consult the pressure check" {
  _maybe_prompt_cli_update() { true; }
  _maybe_show_release_highlight() { true; }
  _maybe_check_docker_pressure() { touch "$TEST_TEMP/pressure_checked"; }
  _set_box() { true; }
  cmd_start() { true; }
  run main start
  assert_success
  [ -f "$TEST_TEMP/pressure_checked" ]
}

@test "pressure: read-only commands skip the pressure check" {
  _maybe_prompt_cli_update() { true; }
  _maybe_show_release_highlight() { true; }
  _maybe_check_docker_pressure() { touch "$TEST_TEMP/pressure_checked"; }
  cmd_ps() { true; }
  run main ps
  assert_success
  [ ! -f "$TEST_TEMP/pressure_checked" ]
}

# ── cmd_status VM budget line ────────────────────────────────────────────────
# Distinct from the on-start warn above: status renders its own overcommit
# line so the state is visible on demand, not just once a day.

@test "status: flags an overcommitted VM with the promised/actual sizes" {
  mkdir -p "$TEST_TEMP/project"
  _docker_vm_memory() { echo "8589934592"; }            # 8 GiB VM
  _running_memory_limits_sum() { echo "42949672960"; }  # 40 GiB promised
  run cmd_status "$TEST_TEMP/project"
  assert_success
  assert_output --partial "overcommitted"
  assert_output --partial "promised 40 GB of a 8 GB VM"
}

@test "status: no VM line when the running limits fit" {
  mkdir -p "$TEST_TEMP/project"
  _docker_vm_memory() { echo "8589934592"; }
  _running_memory_limits_sum() { echo "4294967296"; }
  run cmd_status "$TEST_TEMP/project"
  assert_success
  refute_output --partial "overcommitted"
}

# ── sum helper ───────────────────────────────────────────────────────────────

@test "pressure: limits sum is 0 with no running containers" {
  run _running_memory_limits_sum
  assert_output "0"
}
