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

@test "config --enable: idempotent — enabling twice doesn't duplicate" {
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
