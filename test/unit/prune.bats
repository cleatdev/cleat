#!/usr/bin/env bats
# `cleat prune` + the on-start Docker pressure check. Observed live before
# this existed: 217 dangling images (~120 GB; every drift rebuild orphaned a
# 1.5-2.5 GB build) plus four superseded ghcr version tags nothing ever
# removed. Prune deletes ONLY cleat-owned image bloat: dangling
# sh.cleat.version images and non-current ghcr.io/cleatdev/cleat tags. Boxes
# (even exited, they're resumable sessions) and other projects' images are
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
  # The dangling id resolves via docker image inspect: stub returns nothing,
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
# Every pull/build/rebuild orphans the image it replaces (1.5-2.5 GB): the
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

# ── Docker Desktop memory advisory (a comfortable default VM for parallel work) ─
# A box and a worktree are the same thing here (one session, one ~4g ceiling) so
# the advisory sizes the VM with comfortable headroom: a 16 GiB default (room for
# several sessions to spike near their ceiling at once, NOT a session cap), capped
# at half the host's RAM. It fires while the VM is below that, names the concrete
# memory to set + the click-path + the machine's safe max, and recurs daily (no
# once-ever stamp) until fixed. Host RAM unknown → an absolute 8 GiB floor.
# Docker-Desktop-only (a native engine's VM is the host).

@test "pressure: advises a concrete VM size + click-path + safe max when the VM is too small" {
  _is_tty() { return 0; }
  _cleat_prunable_stats() { printf '0\t0'; }            # no bloat
  _docker_vm_memory() { echo "8589934592"; }            # 8 GiB VM
  _host_total_memory() { echo "34359738368"; }          # 32 GiB Mac → rec 16, max ~24
  _running_memory_limits_sum() { echo "0"; }            # no overload
  _is_docker_desktop() { return 0; }
  run _maybe_check_docker_pressure
  assert_success
  assert_output --partial "Docker VM memory is"
  assert_output --partial "16 GB"          # recommended (the comfortable default target)
  assert_output --partial "24 GB"          # safe max (~3/4 of the 32 GB host)
  assert_output --partial "Resources"      # the click-path
  assert_output --partial "Swap"
  assert_output --partial "VirtioFS"
}

@test "pressure: the VM advisory is an amber warning, not a neutral blue note (it's crucial)" {
  _is_tty() { return 0; }
  _cleat_prunable_stats() { printf '0\t0'; }
  _docker_vm_memory() { echo "8589934592"; }
  _host_total_memory() { echo "34359738368"; }
  _running_memory_limits_sum() { echo "0"; }
  _is_docker_desktop() { return 0; }
  run _maybe_check_docker_pressure
  assert_success
  # Render the amber `!` marker from the sourced AMBER var (real ESC bytes, not
  # the literal "\033…" string) and assert the rendered output carries it.
  local amber_bang; amber_bang="$(printf '%b!' "$AMBER")"
  assert_output --partial "$amber_bang"    # warn marker (amber !), not the blue info ▸
}

@test "pressure: a blank line follows the VM advisory (separates it from the news/bring-up)" {
  _is_tty() { return 0; }
  _cleat_prunable_stats() { printf '0\t0'; }
  _docker_vm_memory() { echo "8589934592"; }
  _host_total_memory() { echo "34359738368"; }
  _running_memory_limits_sum() { echo "0"; }
  _is_docker_desktop() { return 0; }
  # $(...) strips only the FINAL newline, so the trailing `echo ""` survives as a
  # blank line immediately before SENTINEL. Dropping it makes VirtioFS abut SENTINEL.
  local out cls
  out="$( { _maybe_check_docker_pressure; printf 'SENTINEL\n'; } )"
  cls="$(printf '%s\n' "$out" | awk '
    /^SENTINEL$/ { print (p ~ /^[[:space:]]*$/ ? "BLANK" : "NOTBLANK"); f=1; exit }
    { p=$0 }
    END { if (!f) print "NOTFOUND" }')"
  run echo "$cls"
  assert_output "BLANK"
}

@test "pressure: a blank line PRECEDES the advisory section (own block, not flush against the update/restart lines above)" {
  # Regression (v0.16.x, from image.png): the advisory printed immediately after
  # the auto-update "Restarting with the new version..." line with no gap, so it
  # read as part of that block. The section must open with its own leading blank.
  _is_tty() { return 0; }
  _cleat_prunable_stats() { printf '0\t0'; }
  _docker_vm_memory() { echo "8589934592"; }            # 8 GiB VM
  _host_total_memory() { echo "34359738368"; }          # 32 GiB Mac
  _running_memory_limits_sum() { echo "0"; }
  _is_docker_desktop() { return 0; }
  # $(...) strips only TRAILING newlines, so a leading `echo ""` survives as an
  # empty first line. Drop it and the warn becomes line 1 (NOTBLANK).
  local out first
  out="$(_maybe_check_docker_pressure)"
  first="$(printf '%s\n' "$out" | sed -n '1p')"
  run echo "first=[$first]"
  assert_output "first=[]"
  # ...and the advisory itself is still present on a later line (proves line 1 is
  # a real leading separator, not an empty run).
  run echo "$out"
  assert_output --partial "Docker VM memory is"
}

@test "pressure: the VM fix names the REAL Docker Desktop panels (Resources → Advanced for memory/swap, Virtual Machine Options for VirtioFS)" {
  # Regression (v0.16.x, from docker-1.png / docker-2.png): the old text sent
  # users to "Settings → Resources → Memory" for everything. Memory + Swap live
  # under Resources → Advanced (Resource Allocation); VirtioFS file sharing is a
  # separate panel under General → Virtual Machine Options.
  _is_tty() { return 0; }
  _cleat_prunable_stats() { printf '0\t0'; }
  _docker_vm_memory() { echo "8589934592"; }
  _host_total_memory() { echo "34359738368"; }
  _running_memory_limits_sum() { echo "0"; }
  _is_docker_desktop() { return 0; }
  run _maybe_check_docker_pressure
  assert_success
  assert_output --partial "Resources → Advanced"        # memory + swap panel
  assert_output --partial "Memory limit"
  assert_output --partial "Swap"
  assert_output --partial "Virtual Machine Options"      # file-sharing panel (General)
  assert_output --partial "VirtioFS"
}

@test "pressure: recommendation is capped at half the host RAM on a smaller machine" {
  _is_tty() { return 0; }
  _cleat_prunable_stats() { printf '0\t0'; }
  _docker_vm_memory() { echo "4294967296"; }            # 4 GiB VM
  _host_total_memory() { echo "17179869184"; }          # 16 GiB Mac → rec = half = 8, max ~12
  _running_memory_limits_sum() { echo "0"; }
  _is_docker_desktop() { return 0; }
  run _maybe_check_docker_pressure
  assert_success
  assert_output --partial "8 GB"           # recommended = half of a 16 GB host (not the 16 GB target)
  assert_output --partial "12 GB"          # safe max (~3/4 of 16 GB)
}

@test "pressure: no advisory when the VM already meets the recommendation" {
  _is_tty() { return 0; }
  _cleat_prunable_stats() { printf '0\t0'; }
  _docker_vm_memory() { echo "8589934592"; }            # 8 GiB VM
  _host_total_memory() { echo "17179869184"; }          # 16 GiB Mac → rec = half = 8 GiB (met)
  _running_memory_limits_sum() { echo "0"; }
  _is_docker_desktop() { return 0; }
  run _maybe_check_docker_pressure
  assert_success
  refute_output --partial "Docker VM memory is"
}

@test "pressure: no advisory for a VM at/above the 16 GiB target even on a huge host" {
  _is_tty() { return 0; }
  _cleat_prunable_stats() { printf '0\t0'; }
  _docker_vm_memory() { echo "17179869184"; }           # 16 GiB VM (meets the 4-session target)
  _host_total_memory() { echo "137438953472"; }         # 128 GiB host (half is huge, but target is met)
  _running_memory_limits_sum() { echo "0"; }
  _is_docker_desktop() { return 0; }
  run _maybe_check_docker_pressure
  assert_success
  refute_output --partial "Docker VM memory is"
}

@test "pressure: the undersized-VM advisory shows on EVERY start, never throttled" {
  # An invalid VM config must surface until it's fixed, not once a day. Even with a
  # FRESH daily stamp (which throttles the bloat/overload halves) the undersized
  # advisory still fires. Mutation-verified (re-gate 2b on bloat_due and this
  # fails). Same position, same text as before, only the cadence changed.
  _is_tty() { return 0; }
  _cleat_prunable_stats() { printf '0\t0'; }
  _docker_vm_memory() { echo "8589934592"; }
  _host_total_memory() { echo "34359738368"; }
  _running_memory_limits_sum() { echo "0"; }
  _is_docker_desktop() { return 0; }
  echo "$(date +%s)" > "$PRESSURE_CHECK_FILE"            # fresh stamp → bloat/overload throttled
  run _maybe_check_docker_pressure
  assert_output --partial "Docker VM memory is"          # ...undersized advisory still shows
  run _maybe_check_docker_pressure                        # again, immediately, stamp still fresh
  assert_output --partial "Docker VM memory is"          # ...and again: every start, until set
}

@test "pressure: the overload notice stays throttled (daily, not every start)" {
  # Overload is transient (a promise > VM compares ceilings, not usage) so it
  # keeps the daily cadence: a FRESH stamp suppresses it. This is the deliberate
  # contrast to the undersized advisory above, which is NOT throttled.
  _is_tty() { return 0; }
  _cleat_prunable_stats() { printf '0\t0'; }
  _docker_vm_memory() { echo "8589934592"; }            # 8 GiB VM
  _host_total_memory() { echo "34359738368"; }
  _running_memory_limits_sum() { echo "42949672960"; }  # 40 GiB promised → overloaded
  _is_docker_desktop() { return 0; }
  echo "$(date +%s)" > "$PRESSURE_CHECK_FILE"            # fresh stamp → overload throttled this run
  run _maybe_check_docker_pressure
  refute_output --partial "promised"                     # overload notice held back...
  assert_output --partial "Docker VM memory is"          # ...but the undersized advisory still shows
}

@test "pressure: falls back to an 8 GiB floor (no host-specific max) when host RAM is unknown" {
  _is_tty() { return 0; }
  _cleat_prunable_stats() { printf '0\t0'; }
  _docker_vm_memory() { echo "7800000000"; }            # ~7.3 GiB, under the 8 GiB fallback
  _host_total_memory() { echo ""; }                      # host RAM unreadable
  _running_memory_limits_sum() { echo "0"; }
  _is_docker_desktop() { return 0; }
  run _maybe_check_docker_pressure
  assert_success
  assert_output --partial "Docker VM memory is"
  assert_output --partial "16 GB"                         # falls back to the target
  refute_output --partial "max ≈"                         # no host-specific max when host unknown
  refute_output --partial "of your"                       # no "of your N GB" when host unknown
}

@test "pressure: no advisory off Docker Desktop (native engine has no resizable VM)" {
  _is_tty() { return 0; }
  _cleat_prunable_stats() { printf '0\t0'; }
  _docker_vm_memory() { echo "8589934592"; }
  _host_total_memory() { echo "34359738368"; }
  _running_memory_limits_sum() { echo "0"; }
  _is_docker_desktop() { return 1; }                    # native Linux engine
  run _maybe_check_docker_pressure
  assert_success
  refute_output --partial "Docker VM memory is"
}

@test "pressure: overload takes precedence but STILL prints the grow-the-VM fix" {
  _is_tty() { return 0; }
  _cleat_prunable_stats() { printf '0\t0'; }
  _docker_vm_memory() { echo "8589934592"; }            # small AND overcommitted
  _host_total_memory() { echo "34359738368"; }
  _running_memory_limits_sum() { echo "42949672960"; }  # 40 GiB promised
  _is_docker_desktop() { return 0; }
  run _maybe_check_docker_pressure
  assert_success
  assert_output --partial "promised 40 GB"
  assert_output --partial "Resources"           # the how-to is appended to the overload notice
  assert_output --partial "Stop a session"       # the overload (2a) lead-in
  refute_output --partial "Each box/worktree"    # but NOT the 2b undersized-VM lead-in (overload returns first)
}

@test "pressure: overload off Docker Desktop warns without the (inapplicable) Docker Desktop steps" {
  _is_tty() { return 0; }
  _cleat_prunable_stats() { printf '0\t0'; }
  _docker_vm_memory() { echo "8589934592"; }
  _host_total_memory() { echo "34359738368"; }
  _running_memory_limits_sum() { echo "42949672960"; }
  _is_docker_desktop() { return 1; }                    # native engine, no slider
  run _maybe_check_docker_pressure
  assert_success
  assert_output --partial "promised 40 GB"
  refute_output --partial "Resources"        # no Docker Desktop click-path on a native engine
}

@test "pressure: overload on a host that can't grow the VM steers to fewer sessions, not a smaller VM target" {
  # The real-Mac case (v0.16.1): 8 GB Mac, 4 sessions × 4g promised = 16 GB, a
  # 7 GB Docker VM. The VM is already ~7/8 of host RAM (past the safe max), so
  # "give Docker more memory → set it to <rec>" is wrong (rec = half of 8 = 4 GB,
  # SMALLER than the current 7 GB). When the recommended size isn't bigger than
  # the current VM, the honest fix is to reduce demand, not resize the VM.
  _is_tty() { return 0; }
  _cleat_prunable_stats() { printf '0\t0'; }
  _docker_vm_memory() { echo "7516192768"; }            # 7 GiB VM
  _host_total_memory() { echo "8589934592"; }           # 8 GiB Mac → rec = half = 4 GiB (< the VM)
  _running_memory_limits_sum() { echo "17179869184"; }  # 16 GiB promised (4 × 4g)
  _is_docker_desktop() { return 0; }                    # Docker Desktop, but can't grow
  run _maybe_check_docker_pressure
  assert_success
  assert_output --partial "promised 16 GB"
  assert_output --partial "of your"                      # names the real host RAM …
  assert_output --partial "8 GB"                         # … the 8 GB Mac
  assert_output --partial "Run fewer sessions"           # reduce demand …
  assert_output --partial "[resources] memory"           # … or lower a box's own ceiling
  # Must NOT tell the user to set the VM to a number it already exceeds.
  refute_output --partial "Settings"
  refute_output --partial "Apply & restart"
}

@test "pressure: a non-numeric running-limits sum does not abort the VM advisory" {
  # v0.16.1 folded v0.16.0's standalone `[[ $sum =~ ^[0-9]+$ ]] || return 0` into
  # the overload `if`. A non-numeric/empty sum must therefore NOT overload AND
  # must NOT abort the whole check: the undersized-VM advisory still fires.
  _is_tty() { return 0; }
  _cleat_prunable_stats() { printf '0\t0'; }
  _docker_vm_memory() { echo "8589934592"; }            # 8 GiB VM (undersized)
  _host_total_memory() { echo "34359738368"; }          # 32 GiB host
  _running_memory_limits_sum() { echo ""; }             # non-numeric / unknown
  _is_docker_desktop() { return 0; }
  run _maybe_check_docker_pressure
  assert_success
  assert_output --partial "Docker VM memory is"   # 2b advisory still reached
  refute_output --partial "promised"              # overload must NOT fire on a non-numeric sum
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

# ── on-start "Docker tuned" confirmation ─────────────────────────────────────
# The positive, every-start counterpart to the advisory: a correctly sized Docker
# VM earns one green line directly above the bring-up ("Image ready"). It is the
# exact inverse of the 2b undersized test, so the two are complementary, never
# both, never contradictory, and unlike the warning it is NOT daily-gated.

@test "ready: confirms a well-sized VM with its size and parallel headroom" {
  _is_tty() { return 0; }
  _docker_vm_memory() { echo "17179869184"; }           # 16 GiB VM
  _host_total_memory() { echo "34359738368"; }          # 32 GiB host → rec 16 (met)
  run _maybe_announce_docker_ready
  assert_success
  assert_output --partial "Docker tuned for Cleat"
  assert_output --partial "16 GB"
  assert_output --partial "many parallel sessions"      # no count: a number reads as a cap
  refute_output --partial "~4"                          # never promise a specific session count
}

@test "ready: silent when the VM is undersized (the warning covers that)" {
  _is_tty() { return 0; }
  _docker_vm_memory() { echo "8589934592"; }            # 8 GiB VM
  _host_total_memory() { echo "34359738368"; }          # 32 GiB host → rec 16 (NOT met)
  run _maybe_announce_docker_ready
  assert_success
  refute_output --partial "Docker tuned for Cleat"
}

@test "ready: silent on a non-TTY run" {
  _docker_vm_memory() { echo "17179869184"; }
  _host_total_memory() { echo "34359738368"; }
  run _maybe_announce_docker_ready
  assert_success
  refute_output --partial "Docker tuned"
}

@test "ready: defers to a warning the pressure check already showed (no contradiction)" {
  # The overload notice can fire even on an adequately sized VM (lots running). If
  # it did, _VM_ADVISORY_SHOWN is set and the "tuned" line must stay silent, so a
  # warning and a confirmation never both appear. Mutation-verified.
  _is_tty() { return 0; }
  _docker_vm_memory() { echo "17179869184"; }           # adequate VM (would otherwise confirm)
  _host_total_memory() { echo "34359738368"; }
  _VM_ADVISORY_SHOWN=1                                   # pressure check flagged the VM this run
  run _maybe_announce_docker_ready
  assert_success
  refute_output --partial "Docker tuned"
}

@test "ready: shows on every start, not throttled like the daily check" {
  _is_tty() { return 0; }
  _docker_vm_memory() { echo "17179869184"; }
  _host_total_memory() { echo "34359738368"; }
  run _maybe_announce_docker_ready
  assert_output --partial "Docker tuned for Cleat"
  run _maybe_announce_docker_ready                       # immediately again
  assert_output --partial "Docker tuned for Cleat"       # still shows: no throttle
}

@test "ready: uses the 8 GiB floor when host RAM is unknown" {
  _is_tty() { return 0; }
  _host_total_memory() { echo ""; }                      # host RAM unreadable
  _docker_vm_memory() { echo "8589934592"; }             # exactly 8 GiB → meets floor
  run _maybe_announce_docker_ready
  assert_success
  assert_output --partial "Docker tuned for Cleat"
}

@test "ready: silent under the 8 GiB floor when host RAM is unknown" {
  _is_tty() { return 0; }
  _host_total_memory() { echo ""; }
  _docker_vm_memory() { echo "7800000000"; }             # ~7.3 GiB, under the floor
  run _maybe_announce_docker_ready
  assert_success
  refute_output --partial "Docker tuned"
}

@test "ready: a blank PRECEDES the confirmation but none follows (sticks to Image ready)" {
  _is_tty() { return 0; }
  _docker_vm_memory() { echo "17179869184"; }
  _host_total_memory() { echo "34359738368"; }
  _ONSTART_GAP_OPEN=0
  # SENTINEL stands in for the bring-up's "Image ready" line. $(...) strips only
  # the FINAL newline, so a leading `echo ""` survives as line 1 and any trailing
  # blank would survive between the confirmation and SENTINEL.
  local out first after
  out="$( { _maybe_announce_docker_ready; printf 'SENTINEL\n'; } )"
  first="$(printf '%s\n' "$out" | sed -n '1p')"
  run echo "first=[$first]"
  assert_output "first=[]"                               # one leading blank (own section)
  after="$(printf '%s\n' "$out" | grep -A1 'Docker tuned for Cleat' | tail -1)"
  run echo "$after"
  assert_output "SENTINEL"                               # no blank between it and the bring-up
}

@test "ready: no leading blank when an earlier notice already opened the gap" {
  _is_tty() { return 0; }
  _docker_vm_memory() { echo "17179869184"; }
  _host_total_memory() { echo "34359738368"; }
  _ONSTART_GAP_OPEN=1                                    # advisory/highlight already spaced
  local out first
  out="$(_maybe_announce_docker_ready)"
  first="$(printf '%s\n' "$out" | sed -n '1p')"
  run echo "$first"
  assert_output --partial "Docker tuned for Cleat"       # confirmation IS line 1, no extra blank
}

@test "ready: session-launching commands announce docker readiness" {
  _maybe_prompt_cli_update() { true; }
  _maybe_check_docker_pressure() { true; }
  _maybe_show_release_highlight() { true; }
  _maybe_announce_docker_ready() { touch "$TEST_TEMP/ready_announced"; }
  _set_box() { true; }
  cmd_start() { true; }
  run main start
  assert_success
  [ -f "$TEST_TEMP/ready_announced" ]
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
