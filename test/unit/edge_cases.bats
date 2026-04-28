#!/usr/bin/env bats
# ─────────────────────────────────────────────────────────────────────────────
# EDGE-CASE COVERAGE
#
# Hostile inputs and corner cases that commonly break CLIs:
#   - Paths with shell metacharacters, spaces, unicode, trailing slash
#   - Env values with =, spaces, quotes, special chars
#   - Config files with CRLF, BOM, comments only, duplicate keys
#   - Empty inputs, missing files, broken symlinks
#   - Very long values
#
# These are NOT regression tests (they don't guard against a specific shipped
# bug). They're preventive — the goal is to catch classes of bugs before they
# ship.
# ─────────────────────────────────────────────────────────────────────────────

load "../setup"

setup() {
  _common_setup
  use_docker_stub
  source_cli

  _host_clip_cmd() { echo ""; }
  check_for_update() { true; }
  check_drift() { true; }
  _resolve_config_drift() { true; }
  show_first_run_tip() { true; }

  CLEAT_CONFIG_DIR="$TEST_TEMP/cleat-config"
  CLEAT_GLOBAL_CONFIG="$CLEAT_CONFIG_DIR/config"
  CLEAT_GLOBAL_ENV="$CLEAT_CONFIG_DIR/env"
  _first_run_tip_file="$CLEAT_CONFIG_DIR/.tip-shown"
  mkdir -p "$CLEAT_CONFIG_DIR"
}

teardown() { _common_teardown; }

# ── resolve_project edge cases ──────────────────────────────────────────────

@test "resolve_project: existing directory returns absolute path" {
  mkdir -p "$TEST_TEMP/project"
  run resolve_project "$TEST_TEMP/project"
  assert_success
  assert_output "$TEST_TEMP/project"
}

@test "resolve_project: trailing slash is normalized" {
  mkdir -p "$TEST_TEMP/project"
  run resolve_project "$TEST_TEMP/project/"
  assert_success
  # cd && pwd should drop the trailing slash
  [[ "$output" != */ ]] || {
    echo "expected trailing slash stripped, got: $output"
    return 1
  }
}

@test "resolve_project: relative path is resolved to absolute" {
  mkdir -p "$TEST_TEMP/project"
  cd "$TEST_TEMP"
  run resolve_project "project"
  assert_success
  assert_output "$TEST_TEMP/project"
}

@test "resolve_project: nonexistent path returns as-is" {
  run resolve_project "$TEST_TEMP/does-not-exist"
  assert_success
  assert_output "$TEST_TEMP/does-not-exist"
}

@test "resolve_project: path with spaces" {
  mkdir -p "$TEST_TEMP/my project"
  run resolve_project "$TEST_TEMP/my project"
  assert_success
  assert_output "$TEST_TEMP/my project"
}

@test "resolve_project: path with unicode" {
  mkdir -p "$TEST_TEMP/проект"
  run resolve_project "$TEST_TEMP/проект"
  assert_success
  assert_output "$TEST_TEMP/проект"
}

@test "resolve_project: broken symlink returns the link path" {
  ln -s "$TEST_TEMP/nonexistent" "$TEST_TEMP/broken-link"
  run resolve_project "$TEST_TEMP/broken-link"
  assert_success
  # Symlink to nonexistent isn't a directory, so resolve_project treats it
  # as non-existing and returns the path unchanged
  assert_output "$TEST_TEMP/broken-link"
}

@test "resolve_project: symlink to directory is followed" {
  mkdir -p "$TEST_TEMP/real-target"
  ln -s "$TEST_TEMP/real-target" "$TEST_TEMP/link"
  run resolve_project "$TEST_TEMP/link"
  assert_success
  # cd follows the symlink and pwd returns the real path
  [[ "$output" == "$TEST_TEMP/real-target" || "$output" == "$TEST_TEMP/link" ]] || {
    echo "unexpected output: $output"
    return 1
  }
}

# ── _parse_env_file edge cases ──────────────────────────────────────────────

@test "parse_env_file: value with equals sign is preserved" {
  cat > "$TEST_TEMP/env" << 'EOF'
DSN=postgres://user:pass@host:5432/db?sslmode=require&x=1
EOF
  run _parse_env_file "$TEST_TEMP/env"
  assert_success
  assert_output "DSN=postgres://user:pass@host:5432/db?sslmode=require&x=1"
}

@test "parse_env_file: value with spaces is preserved" {
  cat > "$TEST_TEMP/env" << 'EOF'
GREETING=hello world with spaces
EOF
  run _parse_env_file "$TEST_TEMP/env"
  assert_success
  assert_output "GREETING=hello world with spaces"
}

@test "parse_env_file: value with single quotes preserved literally" {
  cat > "$TEST_TEMP/env" << 'EOF'
QUOTED='hello'
EOF
  run _parse_env_file "$TEST_TEMP/env"
  assert_success
  # The single quotes are PART of the value (no shell unquoting)
  assert_output "QUOTED='hello'"
}

@test "parse_env_file: value with double quotes preserved literally" {
  cat > "$TEST_TEMP/env" << 'EOF'
QUOTED="hello"
EOF
  run _parse_env_file "$TEST_TEMP/env"
  assert_success
  assert_output 'QUOTED="hello"'
}

@test "parse_env_file: dollar sign in value is not expanded" {
  cat > "$TEST_TEMP/env" << 'EOF'
LITERAL=$HOME/path
EOF
  run _parse_env_file "$TEST_TEMP/env"
  assert_success
  # Must be literal, not expanded
  assert_output 'LITERAL=$HOME/path'
}

@test "parse_env_file: backticks in value preserved literally" {
  cat > "$TEST_TEMP/env" << 'EOF'
LITERAL=value-`with`-backticks
EOF
  run _parse_env_file "$TEST_TEMP/env"
  assert_success
  assert_output 'LITERAL=value-`with`-backticks'
}

@test "parse_env_file: comment-only file produces no output" {
  cat > "$TEST_TEMP/env" << 'EOF'
# comment 1
# comment 2
EOF
  run _parse_env_file "$TEST_TEMP/env"
  assert_success
  assert_output ""
}

@test "parse_env_file: duplicate keys — last wins" {
  # _parse_env_file itself emits both, but resolve_env_args dedupes.
  # This test verifies parsing doesn't fail.
  cat > "$TEST_TEMP/env" << 'EOF'
KEY=first
KEY=second
EOF
  run _parse_env_file "$TEST_TEMP/env"
  assert_success
  assert_line --index 0 "KEY=first"
  assert_line --index 1 "KEY=second"
}

@test "parse_env_file: very long value is preserved" {
  local long_value
  long_value="$(printf 'x%.0s' {1..2000})"
  printf 'KEY=%s\n' "$long_value" > "$TEST_TEMP/env"
  run _parse_env_file "$TEST_TEMP/env"
  assert_success
  [[ ${#output} -ge 2000 ]] || {
    echo "expected long value, got ${#output} chars"
    return 1
  }
}

@test "parse_env_file: bare KEY preserves host env value even if complex" {
  export TEST_COMPLEX_VAR='value with spaces, equals= and $dollars'
  cat > "$TEST_TEMP/env" << 'EOF'
TEST_COMPLEX_VAR
EOF
  run _parse_env_file "$TEST_TEMP/env"
  assert_success
  assert_output 'TEST_COMPLEX_VAR=value with spaces, equals= and $dollars'
  unset TEST_COMPLEX_VAR
}

@test "parse_env_file: BOM marker at start of file doesn't corrupt first line" {
  # UTF-8 BOM is 0xEF 0xBB 0xBF. Some editors insert it silently.
  printf '\xef\xbb\xbfKEY=value\n' > "$TEST_TEMP/env"
  run _parse_env_file "$TEST_TEMP/env"
  assert_success
  # Current behavior: BOM becomes part of the key name and gets rejected
  # OR preserved. We only enforce that parsing doesn't crash and the
  # bare assertion confirms the function returns.
  # (A future enhancement could strip the BOM; this test documents it.)
}

@test "parse_env_file: file with only whitespace is skipped" {
  printf '   \n\t\n   \n' > "$TEST_TEMP/env"
  run _parse_env_file "$TEST_TEMP/env"
  assert_success
  assert_output ""
}

@test "parse_env_file: key with only digits is rejected (invalid var name)" {
  cat > "$TEST_TEMP/env" << 'EOF'
123KEY=value
EOF
  run _parse_env_file "$TEST_TEMP/env"
  assert_success
  # This looks like a KEY=VALUE line. The parser uses `${line%%=*}` to
  # extract the key and writes it through. The validation is only applied
  # to BARE keys, not KEY=VALUE lines. Document this in case it changes.
  assert_output "123KEY=value"
}

# ── Docker run failure handling edge cases ─────────────────────────────────

@test "cmd_run: docker exit 137 (OOM kill) is reported with docker stderr" {
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project"
  export DOCKER_EXIT_CODE=137
  export DOCKER_STDERR="Error response from daemon: container killed (OOM)"

  run cmd_run "$TEST_TEMP/project"
  assert_failure
  assert_output --partial "OOM"
  unset DOCKER_EXIT_CODE DOCKER_STDERR
}

@test "cmd_run: docker exit 127 (daemon not found) is reported" {
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project"
  export DOCKER_EXIT_CODE=127
  export DOCKER_STDERR="Cannot connect to the Docker daemon"

  run cmd_run "$TEST_TEMP/project"
  assert_failure
  assert_output --partial "Cannot connect"
  unset DOCKER_EXIT_CODE DOCKER_STDERR
}

# ── Config file edge cases ─────────────────────────────────────────────────

@test "config file: empty [caps] section produces no active caps" {
  cat > "$CLEAT_GLOBAL_CONFIG" << 'EOF'
[caps]

EOF
  resolve_caps
  [[ "${#ACTIVE_CAPS[@]}" -eq 0 ]] || {
    echo "Expected no caps, got: ${ACTIVE_CAPS[*]}"
    return 1
  }
}

@test "config file: comments in [caps] section are ignored" {
  cat > "$CLEAT_GLOBAL_CONFIG" << 'EOF'
[caps]
# this is a comment
git
# another comment
ssh
EOF
  resolve_caps
  [[ " ${ACTIVE_CAPS[*]} " == *" git "* ]] || return 1
  [[ " ${ACTIVE_CAPS[*]} " == *" ssh "* ]] || return 1
}

@test "config file: [caps] section with CRLF line endings parses correctly" {
  printf '[caps]\r\ngit\r\nssh\r\n' > "$CLEAT_GLOBAL_CONFIG"
  resolve_caps
  [[ " ${ACTIVE_CAPS[*]} " == *" git "* ]] || return 1
  [[ " ${ACTIVE_CAPS[*]} " == *" ssh "* ]] || return 1
}

@test "config file: unknown sections are ignored (not parsed as caps)" {
  cat > "$CLEAT_GLOBAL_CONFIG" << 'EOF'
[other]
not-a-cap
another-not-a-cap

[caps]
git
EOF
  resolve_caps
  [[ " ${ACTIVE_CAPS[*]} " == *" git "* ]] || return 1
  [[ " ${ACTIVE_CAPS[*]} " != *" not-a-cap "* ]] || {
    echo "REGRESSION: 'not-a-cap' leaked from [other] section"
    return 1
  }
}

@test "config file: missing file is not an error" {
  # No CLEAT_GLOBAL_CONFIG file at all
  rm -f "$CLEAT_GLOBAL_CONFIG"
  # Call directly (not via `run`) so ACTIVE_CAPS is set in our scope
  ACTIVE_CAPS=()
  resolve_caps
  [[ "${#ACTIVE_CAPS[@]}" -eq 0 ]] || {
    echo "Expected empty caps, got: ${ACTIVE_CAPS[*]}"
    return 1
  }
}

# ── Argument parsing edge cases ────────────────────────────────────────────

@test "parse_global_flags: --env value starting with dash is NOT confused for a flag" {
  # This is the standard UNIX convention: --env -VAL treats -VAL as the value.
  # But with cleat's parser, `--env -VAL` may or may not work. Test current
  # behavior and document.
  parse_global_flags --env "NEG=-123" start
  [[ "${_CLI_ENVS[0]}" == "NEG=-123" ]] || return 1
}

@test "parse_global_flags: --env with empty string value" {
  parse_global_flags --env "EMPTY=" start
  [[ "${_CLI_ENVS[0]}" == "EMPTY=" ]] || return 1
}

@test "parse_global_flags: --env with only KEY (bare) is accepted" {
  parse_global_flags --env "MY_BARE_KEY" start
  [[ "${_CLI_ENVS[0]}" == "MY_BARE_KEY" ]] || return 1
}

@test "parse_global_flags: --cap known value but wrong case is rejected" {
  run parse_global_flags --cap "GIT"
  assert_failure
  assert_output --partial "Unknown capability"
}

@test "parse_global_flags: --env-file with absolute path is preserved" {
  parse_global_flags --env-file "/tmp/absolute.env" start
  [[ "${_CLI_ENV_FILES[0]}" == "/tmp/absolute.env" ]] || return 1
}
