#!/usr/bin/env bats
# The on-start Docker-config GATE (_maybe_gate_on_docker_config): the single place
# Cleat deliberately blocks the launch. Field report that drove it: a user ran
# degraded for a long time because the non-blocking undersized-VM advisory "just
# blinked" past on start, then reported Cleat as slow when asked. So when a genuine
# Docker CONFIG error is detected (undersized VM memory, or default/disabled swap),
# the interactive launch now HOLDS on a keypress so the warning can't scroll by
# unread. It must stay OFF the "walk away" pillar: interactive-only (stdin AND
# stdout a terminal), escape-hatchable (CLEAT_NO_DOCKER_GATE=1), fail-open on EOF,
# and it must NEVER fire on the transient overload notice (a `cleat stop` fixes
# that, not a Docker settings change). See concept/21.

load "../setup"

setup() {
  _common_setup
  use_docker_stub
  source_cli
  PRESSURE_CHECK_FILE="$TEST_TEMP/pressure_check"
}

teardown() { _common_teardown; }

# ── the gate in isolation ────────────────────────────────────────────────────

@test "gate: silent when nothing armed it (a healthy Docker never blocks)" {
  _is_interactive() { return 0; }
  _DOCKER_GATE_PENDING=0
  run _maybe_gate_on_docker_config <<< ""
  assert_success
  assert_output ""
  refute_output --partial "not tuned"
}

@test "gate: armed + interactive → prints the banner, the reason, and holds for Enter" {
  _is_interactive() { return 0; }
  _DOCKER_GATE_PENDING=1
  _DOCKER_GATE_SUMMARY="Docker VM memory is 8 GB (aim for 16 GB)."
  run _maybe_gate_on_docker_config <<< ""
  assert_success
  assert_output --partial "Docker is not tuned for Cleat"
  assert_output --partial "Docker VM memory is 8 GB (aim for 16 GB)."
  assert_output --partial "Press"
  assert_output --partial "Enter"
}

@test "gate: WSL2 downgrades the hold (elastic VM memory, advisory printed above)" {
  # WSL2 memory is elastic, so a hard hold on an "undersized" WSL VM is a likely
  # false alarm. The .wslconfig-correct advisory already printed; skip only the hold.
  _is_interactive() { return 0; }
  _is_wsl() { return 0; }
  _DOCKER_GATE_PENDING=1
  _DOCKER_GATE_SUMMARY="Docker VM memory is 8 GB (aim for 16 GB)."
  run _maybe_gate_on_docker_config <<< ""
  assert_success
  refute_output --partial "Docker is not tuned for Cleat"
}

@test "vm fix: WSL names .wslconfig, not the Docker Desktop slider" {
  _is_wsl() { return 0; }
  run _print_docker_vm_fix 17179869184 16
  assert_output --partial ".wslconfig"
  assert_output --partial "wsl --shutdown"
  refute_output --partial "Settings"
}

@test "vm fix: non-WSL names the Docker Desktop Settings slider" {
  _is_wsl() { return 1; }
  run _print_docker_vm_fix 17179869184 16
  assert_output --partial "Settings"
  refute_output --partial ".wslconfig"
}

@test "gate: NON-interactive never blocks even when armed (the walk-away pillar)" {
  # This is the load-bearing guarantee: cron / a pipe / CI must sail straight
  # through, so the gate keys off _is_interactive (stdin AND stdout a terminal),
  # not _is_tty (stdout alone). With no terminal, the banner never prints and the
  # read is never reached, so nothing can hang.
  _is_interactive() { return 1; }
  _DOCKER_GATE_PENDING=1
  _DOCKER_GATE_SUMMARY="Docker VM memory is 8 GB (aim for 16 GB)."
  run _maybe_gate_on_docker_config < /dev/null
  assert_success
  assert_output ""
  refute_output --partial "not tuned"
}

@test "gate: CLEAT_NO_DOCKER_GATE=1 skips the hold even when armed + interactive" {
  # The escape hatch keeps the printed advisory above but does not hold the launch,
  # for someone who runs cleat interactively yet has accepted their Docker setup.
  _is_interactive() { return 0; }
  _DOCKER_GATE_PENDING=1
  _DOCKER_GATE_SUMMARY="Docker VM memory is 8 GB (aim for 16 GB)."
  CLEAT_NO_DOCKER_GATE=1 run _maybe_gate_on_docker_config <<< ""
  assert_success
  assert_output ""
  refute_output --partial "not tuned"
}

@test "gate: fail-open on EOF, armed + interactive but no input does not hang, returns 0" {
  # A redirected/empty stdin (read hits EOF) must fall through via `|| true`, never
  # hang and never abort. The banner still prints (the user saw it); the launch
  # continues.
  _is_interactive() { return 0; }
  _DOCKER_GATE_PENDING=1
  _DOCKER_GATE_SUMMARY="Docker swap is disabled (aim for ≥ 2 GB)."
  run _maybe_gate_on_docker_config < /dev/null
  assert_success
  assert_output --partial "Docker is not tuned for Cleat"
}

@test "gate: banner degrades to an ASCII rule off a UTF-8 locale (no mojibake)" {
  _is_interactive() { return 0; }
  _has_unicode() { return 1; }   # e.g. LANG=C
  _DOCKER_GATE_PENDING=1
  _DOCKER_GATE_SUMMARY="Docker VM memory is 8 GB (aim for 16 GB)."
  run _maybe_gate_on_docker_config <<< ""
  assert_success
  assert_output --partial "===="
  refute_output --partial "────"
}

# ── detection arms (and does NOT arm) the gate ───────────────────────────────

@test "gate: an undersized VM in the pressure check arms _DOCKER_GATE_PENDING" {
  # Drive the real detector, then inspect the global it must set. Called bare (not
  # `run`, which subshells and would drop the mutation); output is redirected and
  # the summary asserted separately.
  _is_tty() { return 0; }
  _cleat_prunable_stats() { printf '0\t0'; }
  _docker_vm_memory() { echo "8589934592"; }     # 8 GiB VM (undersized)
  _host_total_memory() { echo "34359738368"; }   # 32 GiB host → recommends 16
  _running_memory_limits_sum() { echo "0"; }
  _is_docker_desktop() { return 0; }
  _DOCKER_GATE_PENDING=0
  _maybe_check_docker_pressure >/dev/null 2>&1 <<< ""
  assert_equal "$_DOCKER_GATE_PENDING" "1"
  assert_equal "$_DOCKER_GATE_SUMMARY" "Docker VM memory is 8 GB (aim for 16 GB)."
}

@test "gate: the transient OVERLOAD notice never arms the gate" {
  # Overload (running ceilings exceed the VM) is a runtime state a `cleat stop`
  # resolves, not a Docker settings change. It warns, but it must NOT hold the
  # launch, or every over-subscribed start would block on something the user
  # can't fix in Docker Desktop. Call bare (not command-substitution, which
  # subshells and would drop the mutation this test inspects) and capture to a file.
  _is_tty() { return 0; }
  _cleat_prunable_stats() { printf '0\t0'; }
  _docker_vm_memory() { echo "17179869184"; }     # 16 GiB VM (sized right)
  _host_total_memory() { echo "34359738368"; }    # 32 GiB host → target 16, met
  _running_memory_limits_sum() { echo "34359738368"; }  # 32 GiB of ceilings > VM
  _running_cleat_box_count() { echo "8"; }
  _is_docker_desktop() { return 0; }
  PRESSURE_CHECK_FILE="$TEST_TEMP/pressure_overload"   # fresh → bloat_due true
  _DOCKER_GATE_PENDING=0
  _maybe_check_docker_pressure >"$TEST_TEMP/overload.txt" 2>&1 <<< ""
  # The overload warning did fire (proving the branch ran)...
  run grep -q "still running" "$TEST_TEMP/overload.txt"
  assert_success
  # ...but the gate stayed disarmed.
  assert_equal "$_DOCKER_GATE_PENDING" "0"
}

@test "gate: low swap in the ready-announce arms the gate with a swap reason" {
  _is_tty() { return 0; }
  _docker_vm_memory() { echo "17179869184"; }     # 16 GiB VM (memory is fine)
  _host_total_memory() { echo "34359738368"; }    # 32 GiB host → target met
  _docker_vm_swap_bytes() { echo "1073741824"; }  # 1 GiB swap (below the 2 GiB target)
  _docker_pool_is_vm() { return 0; }
  _DOCKER_GATE_PENDING=0
  _maybe_announce_docker_ready >/dev/null 2>&1
  assert_equal "$_DOCKER_GATE_PENDING" "1"
  assert_equal "$_DOCKER_GATE_SUMMARY" "Docker swap is only 1 GB (aim for ≥ 2 GB)."
}

@test "gate: a well-tuned VM with healthy swap arms nothing (announce stays a nod)" {
  _is_tty() { return 0; }
  _docker_vm_memory() { echo "17179869184"; }     # 16 GiB VM
  _host_total_memory() { echo "34359738368"; }    # 32 GiB host → target met
  _docker_vm_swap_bytes() { echo "4294967296"; }  # 4 GiB swap (healthy)
  _docker_pool_is_vm() { return 0; }
  _DOCKER_GATE_PENDING=0
  _maybe_announce_docker_ready >"$TEST_TEMP/tuned.txt" 2>&1
  run grep -q "Docker tuned for Cleat" "$TEST_TEMP/tuned.txt"
  assert_success
  assert_equal "$_DOCKER_GATE_PENDING" "0"
}

# ── the interactive predicate itself ─────────────────────────────────────────

@test "gate: _is_interactive is false without an interactive stdin (guards against always-true)" {
  # The gate's walk-away guarantee rests on _is_interactive being FALSE off a
  # terminal. Under this ttyless harness the real predicate returns false, so this
  # pins it against the pillar-breaking regression where someone makes it always
  # true (return 0 / true), which would block unattended launches. (A ttyless test
  # can't distinguish `[[ -t 0 && -t 1 ]]` from `[[ -t 1 ]]`; that narrower drop is
  # guarded by the source comment on the definition.) Do NOT stub _is_interactive.
  run _is_interactive </dev/null
  assert_failure
}

# ── whitespace: exactly one blank above the banner ───────────────────────────

@test "gate: exactly one blank line above the banner in the undersized end-to-end" {
  # Wired as main() calls them. The pressure advisory + release highlight each own
  # a trailing blank and set _ONSTART_GAP_OPEN, so the gate must NOT add its own
  # leading blank here, or a double blank opens above the amber banner.
  _is_tty() { return 0; }
  _is_interactive() { return 0; }
  _cleat_prunable_stats() { printf '0\t0'; }
  _docker_vm_memory() { echo "8589934592"; }      # 8 GiB VM (undersized)
  _host_total_memory() { echo "34359738368"; }    # 32 GiB host
  _running_memory_limits_sum() { echo "0"; }
  _is_docker_desktop() { return 0; }
  PRESSURE_CHECK_FILE="$TEST_TEMP/ws_pc"
  _ONSTART_GAP_OPEN=0
  { _maybe_check_docker_pressure; _maybe_show_release_highlight; _maybe_announce_docker_ready; _maybe_gate_on_docker_config; } \
    >"$TEST_TEMP/ws.txt" 2>&1 <<< ""
  # Look two lines up from the banner title: the line directly above is the rule
  # (non-blank), the one above THAT is the single leading gap. If it is blank AND
  # the line above it is non-blank, the gap is exactly one line (SINGLE). If both
  # are blank, the gate doubled it (DOUBLE).
  run awk '
    /Docker is not tuned for Cleat/ {
      print (prev2 ~ /^[[:space:]]*$/) ? "GAP_BLANK" : "GAP_NONBLANK"
      print (prev3 ~ /^[[:space:]]*$/) ? "DOUBLE" : "SINGLE"
      f=1; exit
    }
    { prev3=prev2; prev2=prev; prev=$0 } END { if (!f) print "NOTFOUND" }' "$TEST_TEMP/ws.txt"
  assert_line "GAP_BLANK"
  assert_line "SINGLE"
}

@test "gate: exactly one blank line above the banner in the low-swap end-to-end" {
  # The swap advisory prints content with no trailing blank, so it closes the gap
  # and the gate must open its OWN single blank (never flush against the fix line).
  _is_tty() { return 0; }
  _is_interactive() { return 0; }
  _cleat_prunable_stats() { printf '0\t0'; }
  _docker_vm_memory() { echo "17179869184"; }     # 16 GiB VM (memory fine)
  _host_total_memory() { echo "34359738368"; }
  _running_memory_limits_sum() { echo "0"; }
  _docker_vm_swap_bytes() { echo "1073741824"; }  # 1 GiB swap (low)
  _docker_pool_is_vm() { return 0; }
  _is_docker_desktop() { return 0; }
  PRESSURE_CHECK_FILE="$TEST_TEMP/ws2_pc"
  _ONSTART_GAP_OPEN=0
  { _maybe_check_docker_pressure; _maybe_show_release_highlight; _maybe_announce_docker_ready; _maybe_gate_on_docker_config; } \
    >"$TEST_TEMP/ws2.txt" 2>&1 <<< ""
  run awk '
    /Docker is not tuned for Cleat/ {
      print (prev2 ~ /^[[:space:]]*$/) ? "GAP_BLANK" : "GAP_NONBLANK"
      print (prev3 ~ /^[[:space:]]*$/) ? "DOUBLE" : "SINGLE"
      f=1; exit
    }
    { prev3=prev2; prev2=prev; prev=$0 } END { if (!f) print "NOTFOUND" }' "$TEST_TEMP/ws2.txt"
  assert_line "GAP_BLANK"
  assert_line "SINGLE"
}

# ── end-to-end wiring ────────────────────────────────────────────────────────

@test "gate: undersized VM flows advisory → gate in one on-start sequence" {
  # The two functions wired as main() calls them: the pressure advisory arms the
  # gate, then the gate re-states the reason and holds. Proves the flag survives
  # across the calls and the gate reads what the advisory set.
  _is_tty() { return 0; }
  _is_interactive() { return 0; }
  _cleat_prunable_stats() { printf '0\t0'; }
  _docker_vm_memory() { echo "8589934592"; }      # 8 GiB VM (undersized)
  _host_total_memory() { echo "34359738368"; }    # 32 GiB host
  _running_memory_limits_sum() { echo "0"; }
  _is_docker_desktop() { return 0; }
  { _maybe_check_docker_pressure; _maybe_gate_on_docker_config; } >"$TEST_TEMP/e2e.txt" 2>&1 <<< ""
  run grep -q "Tight for parallel sessions" "$TEST_TEMP/e2e.txt"        # the advisory
  assert_success
  run grep -q "Docker is not tuned for Cleat" "$TEST_TEMP/e2e.txt"      # the gate banner
  assert_success
  run grep -qF "Docker VM memory is 8 GB (aim for 16 GB)." "$TEST_TEMP/e2e.txt"  # the reason
  assert_success
}
