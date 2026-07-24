#!/usr/bin/env bats
load "../setup"

setup() {
  _common_setup
  use_docker_stub
  source_cli

  # Override config paths to use test temp directory
  CLEAT_CONFIG_DIR="$TEST_TEMP/cleat-config"
  CLEAT_GLOBAL_CONFIG="$CLEAT_CONFIG_DIR/config"
  CLEAT_GLOBAL_ENV="$CLEAT_CONFIG_DIR/env"
  _first_run_tip_file="$CLEAT_CONFIG_DIR/.tip-shown"
  mkdir -p "$CLEAT_CONFIG_DIR"
}

teardown() { _common_teardown; }

# ── _read_caps_from_file ───────────────────────────────────────────────────

@test "read_caps: returns empty for missing file" {
  run _read_caps_from_file "$TEST_TEMP/nonexistent"
  assert_success
  assert_output ""
}

@test "read_caps: reads caps from [caps] section" {
  cat > "$TEST_TEMP/config" << 'EOF'
[caps]
git
env
EOF
  run _read_caps_from_file "$TEST_TEMP/config"
  assert_success
  assert_line --index 0 "git"
  assert_line --index 1 "env"
}

@test "read_caps: ignores lines outside [caps] section" {
  cat > "$TEST_TEMP/config" << 'EOF'
# some comment
random_line
[caps]
git
[other]
not_a_cap
EOF
  run _read_caps_from_file "$TEST_TEMP/config"
  assert_success
  assert_output "git"
  refute_output --partial "random_line"
  refute_output --partial "not_a_cap"
}

@test "read_caps: skips comments and empty lines in [caps]" {
  cat > "$TEST_TEMP/config" << 'EOF'
[caps]
# this is a comment
git

env
EOF
  run _read_caps_from_file "$TEST_TEMP/config"
  assert_success
  assert_line --index 0 "git"
  assert_line --index 1 "env"
}

@test "read_caps: handles whitespace around cap names" {
  cat > "$TEST_TEMP/config" << 'EOF'
[caps]
  git
  env
EOF
  run _read_caps_from_file "$TEST_TEMP/config"
  assert_success
  assert_line --index 0 "git"
  assert_line --index 1 "env"
}

@test "read_caps: handles CRLF line endings" {
  printf '[caps]\r\ngit\r\nssh\r\n' > "$TEST_TEMP/config"
  run _read_caps_from_file "$TEST_TEMP/config"
  assert_success
  assert_line --index 0 "git"
  assert_line --index 1 "ssh"
}

@test "read_caps: reads the last cap when the file has NO trailing newline" {
  # The exact shape of a hand-edited .cleat that dropped its last cap before the
  # fix: `printf '[caps]\nenv'` with no final newline.
  printf '[caps]\nenv' > "$TEST_TEMP/config"
  run _read_caps_from_file "$TEST_TEMP/config"
  assert_success
  assert_output "env"
}

@test "read_caps: reads the last cap with CRLF AND no trailing newline" {
  printf '[caps]\r\ngit\r\nenv' > "$TEST_TEMP/config"
  run _read_caps_from_file "$TEST_TEMP/config"
  assert_success
  assert_line --index 0 "git"
  assert_line --index 1 "env"
}

@test "read_caps: a no-newline final line is still filtered if it's a comment" {
  # The trailing-line fallback must not start emitting comments/blank lines.
  printf '[caps]\ngit\n# trailing comment no newline' > "$TEST_TEMP/config"
  run _read_caps_from_file "$TEST_TEMP/config"
  assert_success
  assert_output "git"
  refute_output --partial "comment"
}

@test "read_caps: a no-newline final line outside [caps] is ignored" {
  printf '[caps]\ngit\n[other]\nnot_a_cap' > "$TEST_TEMP/config"
  run _read_caps_from_file "$TEST_TEMP/config"
  assert_success
  assert_output "git"
  refute_output --partial "not_a_cap"
}

@test "write_caps: preserves sections from CRLF file" {
  printf '[other]\r\nsomething\r\n[caps]\r\ngit\r\n' > "$TEST_TEMP/config"
  _write_caps_to_file "$TEST_TEMP/config" ssh
  run _read_caps_from_file "$TEST_TEMP/config"
  assert_output "ssh"
}

# ── _write_caps_to_file ───────────────────────────────────────────────────

@test "write_caps: creates file with [caps] section" {
  _write_caps_to_file "$TEST_TEMP/config" git env
  run cat "$TEST_TEMP/config"
  assert_output --partial "[caps]"
  assert_output --partial "git"
  assert_output --partial "env"
}

@test "write_caps: creates parent directories" {
  _write_caps_to_file "$TEST_TEMP/deep/nested/config" git
  run cat "$TEST_TEMP/deep/nested/config"
  assert_output --partial "[caps]"
  assert_output --partial "git"
}

@test "write_caps: preserves non-caps sections" {
  cat > "$TEST_TEMP/config" << 'EOF'
[other]
something
[caps]
git
EOF
  _write_caps_to_file "$TEST_TEMP/config" env
  run cat "$TEST_TEMP/config"
  assert_output --partial "[other]"
  assert_output --partial "something"
  assert_output --partial "[caps]"
  assert_output --partial "env"
  refute_output --partial "git"
}

@test "write_caps: empty list produces no [caps] section" {
  _write_caps_to_file "$TEST_TEMP/config"
  run cat "$TEST_TEMP/config"
  refute_output --partial "[caps]"
}

# ── resolve_caps ────────────────────────────────────────────────────────────

@test "resolve_caps: empty when no config exists" {
  resolve_caps "$TEST_TEMP/project"
  [[ ${#ACTIVE_CAPS[@]} -eq 0 ]]
}

@test "resolve_caps: reads from global config" {
  cat > "$CLEAT_GLOBAL_CONFIG" << 'EOF'
[caps]
git
EOF
  resolve_caps "$TEST_TEMP/project"
  [[ ${#ACTIVE_CAPS[@]} -eq 1 ]]
  [[ "${ACTIVE_CAPS[0]}" == "git" ]]
}

@test "resolve_caps: unions global and project configs" {
  cat > "$CLEAT_GLOBAL_CONFIG" << 'EOF'
[caps]
git
EOF
  mkdir -p "$TEST_TEMP/project"
  cat > "$TEST_TEMP/project/.cleat" << 'EOF'
[caps]
env
EOF
  resolve_caps "$TEST_TEMP/project"
  [[ ${#ACTIVE_CAPS[@]} -eq 2 ]]
  # Both git and env should be present
  local has_git=false has_env=false
  for cap in "${ACTIVE_CAPS[@]}"; do
    [[ "$cap" == "git" ]] && has_git=true
    [[ "$cap" == "env" ]] && has_env=true
  done
  $has_git && $has_env
}

@test "resolve_caps: deduplicates caps present in both files" {
  cat > "$CLEAT_GLOBAL_CONFIG" << 'EOF'
[caps]
git
EOF
  mkdir -p "$TEST_TEMP/project"
  cat > "$TEST_TEMP/project/.cleat" << 'EOF'
[caps]
git
env
EOF
  resolve_caps "$TEST_TEMP/project"
  # Should have exactly 2, not 3
  [[ ${#ACTIVE_CAPS[@]} -eq 2 ]]
}

@test "resolve_caps: includes CLI --cap flags" {
  _CLI_CAPS=(git)
  resolve_caps "$TEST_TEMP/project"
  [[ ${#ACTIVE_CAPS[@]} -eq 1 ]]
  [[ "${ACTIVE_CAPS[0]}" == "git" ]]
}

@test "resolve_caps: CLI caps don't duplicate config caps" {
  cat > "$CLEAT_GLOBAL_CONFIG" << 'EOF'
[caps]
git
EOF
  _CLI_CAPS=(git env)
  resolve_caps "$TEST_TEMP/project"
  [[ ${#ACTIVE_CAPS[@]} -eq 2 ]]
}

# ── cap_is_active ───────────────────────────────────────────────────────────

@test "cap_is_active: true when cap is in ACTIVE_CAPS" {
  ACTIVE_CAPS=(git env)
  run cap_is_active git
  assert_success
}

@test "cap_is_active: false when cap is not in ACTIVE_CAPS" {
  ACTIVE_CAPS=(git)
  run cap_is_active env
  assert_failure
}

@test "cap_is_active: false when ACTIVE_CAPS is empty" {
  ACTIVE_CAPS=()
  run cap_is_active git
  assert_failure
}

# ── cmd_config --list ──────────────────────────────────────────────────────

@test "config --list: shows all capabilities with status markers" {
  cat > "$CLEAT_GLOBAL_CONFIG" << 'EOF'
[caps]
git
EOF
  run cmd_config --list
  assert_success
  assert_output --partial "git"
  assert_output --partial "env"
  assert_output --partial "Capabilities"
}

# ── cmd_config --enable / --disable ────────────────────────────────────────

@test "config --enable: enables a capability" {
  run cmd_config --enable git
  assert_success
  assert_output --partial "git enabled"

  run _read_caps_from_file "$CLEAT_GLOBAL_CONFIG"
  assert_output "git"
}

@test "config --enable: enables multiple caps sequentially" {
  cmd_config --enable git
  cmd_config --enable env
  run _read_caps_from_file "$CLEAT_GLOBAL_CONFIG"
  assert_line --index 0 "git"
  assert_line --index 1 "env"
}

@test "config --enable: idempotent, enabling twice doesn't duplicate" {
  cmd_config --enable git
  cmd_config --enable git
  local count
  count=$(_read_caps_from_file "$CLEAT_GLOBAL_CONFIG" | wc -l)
  [[ "$count" -eq 1 ]]
}

@test "config --disable: removes a capability" {
  cmd_config --enable git
  cmd_config --enable env
  run cmd_config --disable git
  assert_success
  assert_output --partial "git disabled"

  run _read_caps_from_file "$CLEAT_GLOBAL_CONFIG"
  assert_output "env"
}

@test "config --enable: rejects unknown capability" {
  run cmd_config --enable foobar
  assert_failure
  assert_output --partial "Unknown capability"
}

@test "config --disable: missing name shows error" {
  run cmd_config --disable
  assert_failure
  assert_output --partial "Missing capability name"
}

# ── cmd_config --project ───────────────────────────────────────────────────

@test "config --project --enable: writes to .cleat in current directory" {
  cd "$TEST_TEMP"
  run cmd_config --project --enable git
  assert_success
  run _read_caps_from_file "$TEST_TEMP/.cleat"
  assert_output "git"
}

# ── .cleat.env scaffolding ─────────────────────────────────────────────────

@test "config --enable env: scaffolds .cleat.env when missing" {
  cd "$TEST_TEMP"
  run cmd_config --enable env
  assert_success
  [[ -f "$TEST_TEMP/.cleat.env" ]]
  run cat "$TEST_TEMP/.cleat.env"
  assert_output --partial "project environment variables"
  assert_output --partial "KEY=VALUE"
}

@test "config --enable env: does not overwrite existing .cleat.env" {
  cd "$TEST_TEMP"
  echo "MY_VAR=test" > "$TEST_TEMP/.cleat.env"
  cmd_config --enable env
  run cat "$TEST_TEMP/.cleat.env"
  assert_output "MY_VAR=test"
}

# ── Interactive text fallback ─────────────────────────────────────────────

@test "config text: non-TTY falls back to text mode" {
  run _config_picker_text "$CLEAT_GLOBAL_CONFIG" "global" <<< "done"
  assert_success
  assert_output --partial "Capabilities"
  assert_output --partial "Saved"
}

@test "config text: toggle and save writes to config" {
  run _config_picker_text "$CLEAT_GLOBAL_CONFIG" "global" <<< $'git\ndone'
  assert_success
  assert_output --partial "git enabled"
  run _read_caps_from_file "$CLEAT_GLOBAL_CONFIG"
  assert_output "git"
}

@test "config text: q cancels without saving" {
  run _config_picker_text "$CLEAT_GLOBAL_CONFIG" "global" <<< $'git\nq'
  assert_success
  assert_output --partial "Cancelled"
  # Should not have saved
  run _read_caps_from_file "$CLEAT_GLOBAL_CONFIG"
  assert_output ""
}

@test "config text: unknown cap shows warning" {
  run _config_picker_text "$CLEAT_GLOBAL_CONFIG" "global" <<< $'foobar\nq'
  assert_success
  assert_output --partial "Unknown capability"
}

@test "config text: toggle on then off" {
  run _config_picker_text "$CLEAT_GLOBAL_CONFIG" "global" <<< $'ssh\nssh\ndone'
  assert_success
  assert_output --partial "ssh enabled"
  assert_output --partial "ssh disabled"
  run _read_caps_from_file "$CLEAT_GLOBAL_CONFIG"
  assert_output ""
}

# ── TUI picker draw ──────────────────────────────────────────────────────

@test "config draw: shows checkmark for enabled cap" {
  run _config_picker_draw 0 "git,env"
  assert_output --partial "git"
  assert_output --partial "env"
}

@test "config draw: shows pointer on cursor row" {
  run _config_picker_draw 2 ""
  # Row 2 is env, should have the pointer
  assert_output --partial "▸"
}

@test "config draw: shows all capabilities" {
  run _config_picker_draw 0 ""
  assert_output --partial "git"
  assert_output --partial "ssh"
  assert_output --partial "env"
  assert_output --partial "hooks"
}

# ── Keypress reader ───────────────────────────────────────────────────────

@test "_read_keypress: space returns SPACE" {
  local result
  result="$(_read_keypress <<< " ")"
  [[ "$result" == "SPACE" ]] || { echo "got: $result"; return 1; }
}

@test "_read_keypress: q returns QUIT" {
  local result
  result="$(printf 'q' | _read_keypress)"
  [[ "$result" == "QUIT" ]] || { echo "got: $result"; return 1; }
}

@test "_read_keypress: enter returns ENTER" {
  local result
  result="$(_read_keypress <<< "")"
  [[ "$result" == "ENTER" ]] || { echo "got: $result"; return 1; }
}

@test "_read_keypress: up arrow returns UP" {
  local result
  result="$(printf '\033[A' | _read_keypress)"
  [[ "$result" == "UP" ]] || { echo "got: $result"; return 1; }
}

@test "_read_keypress: down arrow returns DOWN" {
  local result
  result="$(printf '\033[B' | _read_keypress)"
  [[ "$result" == "DOWN" ]] || { echo "got: $result"; return 1; }
}

@test "_read_keypress: bare escape returns ESC" {
  local result
  result="$(printf '\033' | _read_keypress)"
  [[ "$result" == "ESC" ]] || { echo "got: $result"; return 1; }
}

# ── _write_resources_to_file ───────────────────────────────────────────────

@test "write_resources: writes memory and cpus" {
  _write_resources_to_file "$TEST_TEMP/config" 4g 2
  run cat "$TEST_TEMP/config"
  assert_line --index 0 "[resources]"
  assert_output --partial "memory = 4g"
  assert_output --partial "cpus = 2"
}

@test "write_resources: omits an unset key" {
  _write_resources_to_file "$TEST_TEMP/config" 8g ""
  run cat "$TEST_TEMP/config"
  assert_output --partial "memory = 8g"
  refute_output --partial "cpus ="
}

@test "write_resources: both unset writes no [resources] section" {
  : > "$TEST_TEMP/config"
  _write_resources_to_file "$TEST_TEMP/config" "" ""
  run cat "$TEST_TEMP/config"
  refute_output --partial "[resources]"
}

@test "write_resources: sentinels default/all clear their keys" {
  _write_resources_to_file "$TEST_TEMP/config" default all
  run cat "$TEST_TEMP/config"
  refute_output --partial "[resources]"
  refute_output --partial "default"
  refute_output --partial "all"
}

@test "write_resources: preserves [caps] and [setup], replaces only [resources]" {
  printf '[caps]\ngit\n\n[setup]\nscript boot.sh\n\n[resources]\nmemory = 2g\n' > "$TEST_TEMP/config"
  _write_resources_to_file "$TEST_TEMP/config" 6g ""
  run cat "$TEST_TEMP/config"
  assert_output --partial "[caps]"
  assert_output --partial "git"
  assert_output --partial "[setup]"
  assert_output --partial "script boot.sh"
  assert_output --partial "memory = 6g"
  refute_output --partial "memory = 2g"
}

@test "write_resources: a CRLF [resources] header is replaced, not duplicated" {
  printf '[resources]\r\nmemory = 2g\r\n' > "$TEST_TEMP/config"
  _write_resources_to_file "$TEST_TEMP/config" 8g 4
  run grep -c '^\[resources\]$' "$TEST_TEMP/config"
  assert_output "1"
}

@test "write_resources: a [setup] final line with NO trailing newline survives" {
  # The pre-fix caps writer dropped a no-trailing-newline last line; the resources
  # writer must never corrupt a hand-edited [setup] the same way.
  printf '[setup]\nscript build.sh' > "$TEST_TEMP/config"   # NO trailing newline
  _write_resources_to_file "$TEST_TEMP/config" 4g ""
  run cat "$TEST_TEMP/config"
  assert_output --partial "script build.sh"
  assert_output --partial "memory = 4g"
}

# ── _config_cycle_value ────────────────────────────────────────────────────

@test "cycle: next advances through the memory ring" {
  run _config_cycle_value next default "" "${_CONFIG_MEM_CHOICES[@]}"
  assert_output "4g"
}

@test "cycle: next wraps from the last stop back to the sentinel" {
  run _config_cycle_value next 8g "" "${_CONFIG_MEM_CHOICES[@]}"
  assert_output "default"
}

@test "cycle: prev wraps from the sentinel to the last stop" {
  run _config_cycle_value prev default "" "${_CONFIG_MEM_CHOICES[@]}"
  assert_output "8g"
}

@test "cycle: a hand-set custom value stays reachable after the last stop" {
  run _config_cycle_value next 8g 16g "${_CONFIG_MEM_CHOICES[@]}"
  assert_output "16g"
}

@test "cycle: a custom value equal to a ring stop does not double-append" {
  # custom=4g is already a preset, so cycling off 8g must land on the sentinel,
  # not on a duplicate 4g stop.
  run _config_cycle_value next 8g 4g "${_CONFIG_MEM_CHOICES[@]}"
  assert_output "default"
}

@test "cycle: an off-ring current lands on the first stop" {
  run _config_cycle_value next 99g "" "${_CONFIG_MEM_CHOICES[@]}"
  assert_output "default"
}

# ── machine-sized resource rings ───────────────────────────────────────────
# The picker must offer what THIS Docker can honour: never more cores than the
# daemon reports (dockerd errors above NCPU), never less memory headroom than
# the VM actually has (the fixed 8g ceiling hid 24 GB VMs).

@test "mem ring: global scope climbs in real stops to the VM size" {
  _docker_vm_memory() { echo $(( 24 * 1073741824 )); }
  _docker_vm_configured_gb() { echo 24; }
  run _config_mem_choices global
  assert_success
  assert_output "default 4g 6g 8g 12g 16g 24g"
}

@test "mem ring: the last stop is the VM size even off the ladder" {
  _docker_vm_memory() { echo $(( 10 * 1073741824 )); }
  _docker_vm_configured_gb() { echo 10; }
  run _config_mem_choices global
  assert_success
  assert_output "default 4g 6g 8g 10g"
}

@test "mem ring: project scope stops at the runtime clamp" {
  _docker_vm_memory() { echo $(( 64 * 1073741824 )); }
  _docker_vm_configured_gb() { echo 64; }
  run _config_mem_choices project
  assert_success
  assert_output "default 4g 6g 8g"
}

# The clamp the ring stops at and the clamp resolve_box_memory applies are two
# separate constants in the source. If they drift, the picker offers a project
# value the box silently will not get. This is the cross-check.
@test "config: project ring stops at the runtime clamp" {
  local last cfg
  _docker_vm_memory() { echo $(( 64 * 1073741824 )); }
  _docker_vm_configured_gb() { echo 64; }
  last="$(_config_mem_choices project)"
  last="${last##* }"
  cfg="$TEST_TEMP/proj/.cleat"
  mkdir -p "$TEST_TEMP/proj"
  printf '[resources]\nmemory = %s\n' "$last" > "$cfg"
  run resolve_box_memory "$TEST_TEMP/proj" main
  assert_success
  assert_output "$last"
}

@test "mem ring: an unsizeable VM falls back to the static ring" {
  _docker_vm_memory() { echo ""; }
  _docker_vm_configured_gb() { echo ""; }
  run _config_mem_choices global
  assert_success
  assert_output "default 4g 6g 8g"
}

@test "cpu ring: built from the daemon's real core count" {
  _daemon_ncpu() { echo 24; }
  run _config_cpu_choices
  assert_success
  assert_output "all 1 2 4 8 16 24"
}

@test "cpu ring: never offers more cores than the machine has" {
  _daemon_ncpu() { echo 4; }
  run _config_cpu_choices
  assert_success
  assert_output "all 1 2 4"
}

@test "cpu ring: a single-core daemon still gets a usable ring" {
  _daemon_ncpu() { echo 1; }
  run _config_cpu_choices
  assert_success
  assert_output "all 1"
}

@test "cpu ring: an unknown core count falls back to the static ring" {
  _daemon_ncpu() { echo ""; }
  run _config_cpu_choices
  assert_success
  assert_output "all 1 2 4 8"
}

# ── graduated memory warnings ──────────────────────────────────────────────
# Escalating, because a ceiling reads as free until a box grows into it. The
# note is ALWAYS two lines so the picker's redraw math stays constant.

@test "mem note: silent at or below the project cap" {
  run _config_mem_note 8g 24
  assert_success
  assert_output ""
}

@test "mem note: a mild note above the cap but well under the VM" {
  run _config_mem_note 12g 64
  assert_success
  assert_output --partial "not a reservation"
  refute_output --partial "warning:"
}

@test "mem note: escalates past half the VM" {
  run _config_mem_note 16g 24
  assert_success
  assert_output --partial "over half the 24 GB Docker VM"
  refute_output --partial "warning:"
}

@test "mem note: the top tier warns at the whole VM" {
  run _config_mem_note 24g 24
  assert_success
  assert_output --partial "warning:"
  assert_output --partial "the whole Docker VM"
}

@test "mem note: always exactly two lines at every tier" {
  local v
  for v in default 8g 12g 16g 24g 48g; do
    n="$(_config_mem_note "$v" 24 | wc -l | tr -d ' ')"
    [[ "$n" -eq 2 ]] || { echo "$v produced $n lines, want 2"; return 1; }
  done
}

@test "mem note: an unknown VM size still notes above the cap" {
  run _config_mem_note 16g ""
  assert_success
  assert_output --partial "not a reservation"
}

# On a Docker Desktop VM left at its 8 GB default, 8g is BOTH the ring's top
# stop and the whole VM. The picker note and the save-time block must agree:
# with the 8 GB floor checked first the picker said nothing and then ENTER
# printed the full amber paragraph.
@test "mem note: the whole-VM tier fires even at the project cap on a small VM" {
  run _config_mem_note 8g 8
  assert_success
  assert_output --partial "warning:"
  assert_output --partial "the whole Docker VM"
}

@test "mem note: picker note and save warning agree on a small VM" {
  local note_fires block_fires
  note_fires=0; block_fires=0
  _config_mem_note 8g 8 | grep -q 'warning:' && note_fires=1
  [[ -n "$(_config_mem_warn_block 8g 8)" ]] && block_fires=1
  [[ "$note_fires" -eq "$block_fires" ]] || {
    echo "disagreement: note=$note_fires block=$block_fires"; return 1; }
  # and both stay silent one step below the whole VM
  note_fires=0; block_fires=0
  _config_mem_note 4g 8 | grep -q 'warning:' && note_fires=1
  [[ -n "$(_config_mem_warn_block 4g 8)" ]] && block_fires=1
  [[ "$note_fires" -eq 0 && "$block_fires" -eq 0 ]] || {
    echo "should both be silent: note=$note_fires block=$block_fires"; return 1; }
}

# The derived default on a small VM is 4g. That is not a choice the user made,
# so it must not nag: the two milder tiers stay behind the 8 GB floor.
@test "mem note: a 4g default on a 6 GB VM stays quiet" {
  run _config_mem_note 4g 6
  assert_success
  assert_output ""
}

@test "mem warn block: the full reason only at the whole-VM tier" {
  run _config_mem_warn_block 16g 24
  assert_success
  assert_output ""
  run _config_mem_warn_block 24g 24
  assert_success
  assert_output --partial "OOM killer"
}

# ── _config_row_kind ───────────────────────────────────────────────────────

@test "row_kind: caps map to cap:<name>, then mem, then cpus, then gen" {
  run _config_row_kind 0; assert_output "cap:git"
  run _config_row_kind 5; assert_output "cap:docker"
  run _config_row_kind 6; assert_output "mem"
  run _config_row_kind 7; assert_output "cpus"
  run _config_row_kind 8; assert_output "gen"
}

# ── draw: resource + generate rows ─────────────────────────────────────────

@test "config draw: renders the Resources group with memory and cpus values" {
  run _config_picker_draw 0 "" 4g 2 0 0
  assert_output --partial "Resources"
  assert_output --partial "memory"
  assert_output --partial "4g"
  assert_output --partial "cpus"
}

@test "config draw: shows chevrons on the cursored resource row" {
  run _config_picker_draw 6 "" 4g all 0 0
  assert_output --partial "‹ 4g ›"
}

@test "config draw: the generate row appears only when show_gen=1" {
  run _config_picker_draw 0 "" default all 1 0
  assert_output --partial "this project's .cleat"
  run _config_picker_draw 0 "" default all 0 0
  refute_output --partial "this project's .cleat"
}

# ── cmd_config --memory / --cpus (direct mode) ─────────────────────────────

@test "config --memory: sets the global memory limit" {
  run cmd_config --memory 4g
  assert_success
  run _read_resource_from_file "$CLEAT_GLOBAL_CONFIG" memory
  assert_output "4g"
}

@test "config --cpus: sets the global cpus limit and preserves memory" {
  cmd_config --memory 4g
  run cmd_config --cpus 2
  assert_success
  run _read_resource_from_file "$CLEAT_GLOBAL_CONFIG" memory
  assert_output "4g"
  run _read_resource_from_file "$CLEAT_GLOBAL_CONFIG" cpus
  assert_output "2"
}

@test "config --memory default: clears the key" {
  cmd_config --memory 4g
  run cmd_config --memory default
  assert_success
  run _read_resource_from_file "$CLEAT_GLOBAL_CONFIG" memory
  assert_output ""
}

@test "config --memory: rejects an invalid value" {
  run cmd_config --memory lots
  assert_failure
  assert_output --partial "Invalid memory value"
}

@test "config --cpus: rejects a zero value" {
  run cmd_config --cpus 0
  assert_failure
  assert_output --partial "Invalid cpus value"
}

@test "config --memory: a missing value is an error, not a silent clear" {
  run cmd_config --memory
  assert_failure
  assert_output --partial "Missing value"
}

@test "config --project --memory: writes to .cleat and preserves [caps]" {
  cd "$TEST_TEMP"
  cmd_config --project --enable git
  run cmd_config --project --memory 8g
  assert_success
  run cat "$TEST_TEMP/.cleat"
  assert_output --partial "[caps]"
  assert_output --partial "git"
  assert_output --partial "memory = 8g"
}

@test "config <box> --memory: writes to the box file" {
  cd "$TEST_TEMP"
  run cmd_config dev --memory 4g
  assert_success
  run _read_resource_from_file "$TEST_TEMP/.cleat.dev" memory
  assert_output "4g"
}

# ── cmd_config --list: resources ───────────────────────────────────────────

@test "config --list: shows the Resources block with configured values" {
  printf '[resources]\nmemory = 6g\ncpus = 2\n' > "$CLEAT_GLOBAL_CONFIG"
  run cmd_config --list
  assert_success
  assert_output --partial "Resources"
  assert_output --partial "6g"
  assert_output --partial "2"
}

@test "config --list: shows default markers when resources are unset" {
  run cmd_config --list
  assert_success
  assert_output --partial "Resources"
  assert_output --partial "default"
  assert_output --partial "all"
}

# ── text picker: resources + generate + EOF ────────────────────────────────

@test "config text: memory keyword with a space sets the value" {
  run _config_picker_text "$CLEAT_GLOBAL_CONFIG" "global" "" <<< $'memory 6g\ndone'
  assert_success
  assert_output --partial "memory set to 6g"
  run _read_resource_from_file "$CLEAT_GLOBAL_CONFIG" memory
  assert_output "6g"
}

# Text mode types a size rather than cycling a ring, so it can name anything.
# It must carry the VM size into the save path or a piped whole-VM ceiling is
# written in total silence (the TUI and direct mode both warn).
@test "config text: a whole-VM ceiling still prints the warning off a terminal" {
  _docker_vm_memory() { echo $(( 24 * 1073741824 )); }
  _docker_vm_configured_gb() { echo 24; }
  run _config_picker_text "$CLEAT_GLOBAL_CONFIG" "global" "" <<< $'memory 24g\ndone'
  assert_success
  assert_output --partial "entire Docker VM"
  assert_output --partial "OOM killer"
}

@test "config text: project scope states the 8 GB cap" {
  run _config_picker_text "$TEST_TEMP/.cleat" "project" "$TEST_TEMP" <<< "q"
  assert_success
  assert_output --partial "caps memory at 8 GB"
}

@test "config text: memory keyword tolerates spaces around = (mirrors the file)" {
  run _config_picker_text "$CLEAT_GLOBAL_CONFIG" "global" "" <<< $'memory = 4g\ndone'
  assert_success
  run _read_resource_from_file "$CLEAT_GLOBAL_CONFIG" memory
  assert_output "4g"
}

@test "config text: cpus keyword sets the value" {
  run _config_picker_text "$CLEAT_GLOBAL_CONFIG" "global" "" <<< $'cpus 2\ndone'
  assert_success
  run _read_resource_from_file "$CLEAT_GLOBAL_CONFIG" cpus
  assert_output "2"
}

@test "config text: a bad resource value warns specifically, not 'Unknown capability'" {
  run _config_picker_text "$CLEAT_GLOBAL_CONFIG" "global" "" <<< $'memory lots\nq'
  assert_success
  assert_output --partial "Not a memory value"
  refute_output --partial "Unknown capability"
}

@test "config text: a genuinely unknown word still warns Unknown capability" {
  run _config_picker_text "$CLEAT_GLOBAL_CONFIG" "global" "" <<< $'wobble\nq'
  assert_success
  assert_output --partial "Unknown capability"
}

@test "config text: EOF cancels cleanly instead of looping" {
  run _config_picker_text "$CLEAT_GLOBAL_CONFIG" "global" "" < /dev/null
  assert_success
  assert_output --partial "Cancelled"
}

@test "config text: project keyword generates ./.cleat when confirmed" {
  cd "$TEST_TEMP"
  run _config_picker_text "$CLEAT_GLOBAL_CONFIG" "global" "$TEST_TEMP" <<< $'git\nproject\ndone\ny'
  assert_success
  assert_output --partial "Wrote"
  run _read_caps_from_file "$TEST_TEMP/.cleat"
  assert_output "git"
}

@test "config text: project keyword is inert in project scope" {
  run _config_picker_text "$TEST_TEMP/.cleat" "project" "$TEST_TEMP" <<< $'project\nq'
  assert_success
  assert_output --partial "only applies to the global config"
}

# ── _generate_project_cleat ────────────────────────────────────────────────

@test "generate: a fresh .cleat gets the friendly header" {
  local d="$TEST_TEMP/fresh"
  _generate_project_cleat "$d" 4g 2 git
  run cat "$d/.cleat"
  assert_output --partial "Cleat project config"
  assert_output --partial "[caps]"
  assert_output --partial "git"
  assert_output --partial "memory = 4g"
}

@test "generate: an existing .cleat keeps [setup] byte-for-byte, no header added" {
  local d="$TEST_TEMP/existing"
  mkdir -p "$d"
  # A [setup] line containing a bracket token must not be mistaken for a section.
  printf '[setup]\nscript [ -f flag ] && ./boot.sh\n' > "$d/.cleat"
  _generate_project_cleat "$d" 8g "" docker
  run cat "$d/.cleat"
  assert_output --partial 'script [ -f flag ] && ./boot.sh'
  assert_output --partial "docker"
  assert_output --partial "memory = 8g"
  refute_output --partial "Cleat project config"
}

# ── _config_generate_project (confirm gate) ────────────────────────────────

@test "generate confirm: nothing selected is a no-op, writes no file" {
  local d="$TEST_TEMP/nada"
  mkdir -p "$d"
  run _config_generate_project "$d" "" ""
  assert_success
  assert_output --partial "Nothing to write"
  [[ ! -f "$d/.cleat" ]]
}

@test "generate confirm: refuses to write in \$HOME" {
  run _config_generate_project "$HOME" 4g "" git
  assert_success
  assert_output --partial "Not writing .cleat"
  [[ ! -f "$HOME/.cleat" ]]
}

@test "generate confirm: docker is called out and a declined write leaves no file" {
  local d="$TEST_TEMP/decline"
  mkdir -p "$d"
  run _config_generate_project "$d" 4g "" git docker <<< "n"
  assert_success
  assert_output --partial "full host control once trusted"
  assert_output --partial "Skipped"
  [[ ! -f "$d/.cleat" ]]
}

@test "generate confirm: an approved write lands the caps and resources" {
  local d="$TEST_TEMP/approve"
  mkdir -p "$d"
  run _config_generate_project "$d" 4g 2 git <<< "y"
  assert_success
  assert_output --partial "Wrote"
  run _read_caps_from_file "$d/.cleat"
  assert_output "git"
  run _read_resource_from_file "$d/.cleat" memory
  assert_output "4g"
}

# ── _config_load_resource (the custom-pin derivation the TUI relies on) ─────
# The second (tab-delimited) field is the "custom pin": a hand-set value NOT on
# the preset ring, which _config_cycle_value folds back in so it stays reachable.
# The TUI is the only consumer, so these direct tests are the only guard.

@test "load_resource: an off-ring value is returned as its own custom pin" {
  printf '[resources]\nmemory = 16g\n' > "$TEST_TEMP/config"
  run _config_load_resource "$TEST_TEMP/config" memory default
  assert_output $'16g\t16g'
}

@test "load_resource: an on-ring value has an empty custom pin" {
  printf '[resources]\nmemory = 8g\n' > "$TEST_TEMP/config"
  run _config_load_resource "$TEST_TEMP/config" memory default
  # field 1 = 8g, field 2 (custom) = empty
  [[ "${output%%$'\t'*}" == "8g" ]] || { echo "field1: ${output%%$'\t'*}"; return 1; }
  [[ "${output#*$'\t'}" == "" ]] || { echo "field2 not empty: ${output#*$'\t'}"; return 1; }
}

@test "load_resource: an unset value maps to the sentinel with no custom pin" {
  : > "$TEST_TEMP/config"
  run _config_load_resource "$TEST_TEMP/config" memory default
  [[ "${output%%$'\t'*}" == "default" ]] || { echo "field1: ${output%%$'\t'*}"; return 1; }
  [[ "${output#*$'\t'}" == "" ]] || { echo "field2: ${output#*$'\t'}"; return 1; }
}

@test "load_resource: a decimal off-ring cpus keeps its custom pin" {
  printf '[resources]\ncpus = 1.5\n' > "$TEST_TEMP/config"
  run _config_load_resource "$TEST_TEMP/config" cpus all
  assert_output $'1.5\t1.5'
}

@test "load_resource: an off-ring value stays reachable through a full cycle round-trip" {
  # End-to-end: load derives the pin, cycle keeps it reachable. This is what
  # protects a hand-set 16g in the editor. prev (not next) is the distinguishing
  # direction: 16g is the ring's last stop, so next wraps to the sentinel in both
  # the correct and a pin-dropped world, but prev only reaches 16g if the pin survives.
  printf '[resources]\nmemory = 16g\n' > "$TEST_TEMP/config"
  local pair mem custom
  pair="$(_config_load_resource "$TEST_TEMP/config" memory default)"
  mem="${pair%%$'\t'*}"; custom="${pair#*$'\t'}"
  run _config_cycle_value prev "$mem" "$custom" "${_CONFIG_MEM_CHOICES[@]}"
  assert_output "8g"
}

# ── draw redraw invariant (line count = the tui's draw_lines formula) ───────
# The TUI's cursor-up math uses draw_lines = ncaps+7 (+2 with the generate row).
# It MUST equal the physical lines _config_picker_draw emits, or every keypress
# desyncs the redraw. These pin the draw side of that invariant. The +7 (was +5)
# is the always-two-line memory note area added with the VM-sized memory ring.

@test "config draw: emits exactly ncaps+7 lines in project scope" {
  local n
  n="$(_config_picker_draw 0 "" default all 0 0 | wc -l | tr -d ' ')"
  [[ "$n" -eq $(( ${#KNOWN_CAPS[@]} + 7 )) ]] || { echo "got $n, want $(( ${#KNOWN_CAPS[@]} + 7 ))"; return 1; }
}

@test "config draw: emits exactly ncaps+9 lines with the generate row (global scope)" {
  local n
  n="$(_config_picker_draw 0 "" default all 1 0 | wc -l | tr -d ' ')"
  [[ "$n" -eq $(( ${#KNOWN_CAPS[@]} + 9 )) ]] || { echo "got $n, want $(( ${#KNOWN_CAPS[@]} + 9 ))"; return 1; }
}

# The note area is RESERVED, not conditional: the count must not move when the
# memory value crosses a warning tier, or the redraw desyncs exactly when the
# user is arrowing through the big values. This is the invariant that makes the
# two constants above safe.
@test "config draw: line count is identical at every memory warning tier" {
  local base warned danger
  base="$(_config_picker_draw 0 "" default all 0 0 24 | wc -l | tr -d ' ')"
  warned="$(_config_picker_draw 0 "" 16g all 0 0 24 | wc -l | tr -d ' ')"
  danger="$(_config_picker_draw 0 "" 24g all 0 0 24 | wc -l | tr -d ' ')"
  [[ "$base" -eq "$warned" && "$base" -eq "$danger" ]] || {
    echo "line counts drifted: default=$base 16g=$warned 24g=$danger"; return 1; }
}

@test "config draw: renders the top-tier memory warning inline" {
  run _config_picker_draw 0 "" 24g all 0 0 24
  assert_success
  assert_output --partial "the whole Docker VM"
}

@test "config draw: no memory note at or below the project cap" {
  run _config_picker_draw 0 "" 8g all 0 0 24
  assert_success
  refute_output --partial "note:"
  refute_output --partial "warning:"
}

# ── env scaffolding via the editor save path ───────────────────────────────

@test "config editor: enabling env offers to scaffold .cleat.env on save" {
  run _config_picker_text "$CLEAT_GLOBAL_CONFIG" "global" "$TEST_TEMP" <<< $'env\ndone\ny'
  assert_success
  assert_output --partial "Create .cleat.env"
  [[ -f "$TEST_TEMP/.cleat.env" ]] || { echo ".cleat.env not created"; return 1; }
}

@test "config editor: an existing .cleat.env is left untouched, no re-offer" {
  echo "FOO=bar" > "$TEST_TEMP/.cleat.env"
  run _config_picker_text "$CLEAT_GLOBAL_CONFIG" "global" "$TEST_TEMP" <<< $'env\ndone'
  assert_success
  refute_output --partial "Create .cleat.env"
  run cat "$TEST_TEMP/.cleat.env"
  assert_output "FOO=bar"
}
