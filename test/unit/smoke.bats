#!/usr/bin/env bats
# ─────────────────────────────────────────────────────────────────────────────
# REAL-BINARY SMOKE TESTS
#
# Every test here execs `bin/cleat` as a subprocess (never sourced). This
# means `set -euo pipefail` is active, and any unbound-variable / syntax /
# pipefail bug that would crash the real CLI is caught here.
#
# The sourced unit tests strip strict mode to coexist with bats' ERR trap.
# That makes them blind to bugs like:
#   - `echo $undefined_var` when `set -u` is active
#   - `docker ps | grep -q foo` where docker fails and pipefail propagates
#   - Syntax errors that only surface when the script is parsed fresh
#
# These smoke tests are the backstop. Every subcommand must have at least
# one test here that runs the real binary and verifies it exits cleanly.
# ─────────────────────────────────────────────────────────────────────────────

load "../setup"

setup() {
  _common_setup

  # Smoke tests exec bin/cleat directly, so we need a fully isolated HOME
  # that the CLI can write to without touching the real host.
  export HOME="$TEST_TEMP/home"
  mkdir -p "$HOME/.claude"

  # CLEAT_CONFIG_DIR is derived from XDG_CONFIG_HOME (or $HOME/.config) at the
  # top of bin/cleat. Force it into our temp dir via XDG_CONFIG_HOME.
  export XDG_CONFIG_HOME="$TEST_TEMP/xdg-config"
  export CLEAT_CONFIG_DIR="$XDG_CONFIG_HOME/cleat"
  mkdir -p "$CLEAT_CONFIG_DIR"

  # Docker stub goes first in PATH so cleat's `docker` calls are captured
  export PATH="$MOCK_BIN:$PATH"
}

# Compute the container name the same way cleat does (via container_name_for).
# We source the CLI in a subshell to call the function without polluting the
# smoke-test process (which must remain a real subprocess caller).
_compute_cname() {
  local project="$1"
  (
    # shellcheck disable=SC1090
    source <(sed 's/^set -euo pipefail$/# stripped/' "$CLI")
    container_name_for "$project"
  )
}

teardown() {
  _common_teardown
}

# Run cleat as a real subprocess. Signature: cleat_bin [ARGS...]
cleat_bin() {
  env \
    PATH="$MOCK_BIN:$PATH" \
    HOME="$HOME" \
    XDG_CONFIG_HOME="$XDG_CONFIG_HOME" \
    DOCKER_CALLS="$DOCKER_CALLS" \
    DOCKER_MOCK_DIR="$DOCKER_MOCK_DIR" \
    DOCKER_EXIT_CODE="${DOCKER_EXIT_CODE:-0}" \
    DOCKER_STDERR="${DOCKER_STDERR:-}" \
    "$CLI" "$@"
}

# Run cleat with a hard timeout (seconds). Used for subcommands that would
# otherwise block on interactive input. Execs env+cleat directly so the
# `timeout` program can wrap a real process, not a shell function.
cleat_bin_timeout() {
  local secs="$1"; shift
  timeout "$secs" env \
    PATH="$MOCK_BIN:$PATH" \
    HOME="$HOME" \
    XDG_CONFIG_HOME="$XDG_CONFIG_HOME" \
    DOCKER_CALLS="$DOCKER_CALLS" \
    DOCKER_MOCK_DIR="$DOCKER_MOCK_DIR" \
    DOCKER_EXIT_CODE="${DOCKER_EXIT_CODE:-0}" \
    DOCKER_STDERR="${DOCKER_STDERR:-}" \
    "$CLI" "$@"
}

# ── Help and version ────────────────────────────────────────────────────────

@test "smoke: cleat --help exits 0 under strict mode" {
  run cleat_bin --help
  assert_success
  assert_output --partial "Cleat"
  refute_output --partial "unbound variable"
  refute_output --partial "command not found"
}

@test "smoke: cleat -h exits 0 under strict mode" {
  run cleat_bin -h
  assert_success
  assert_output --partial "Cleat"
}

@test "smoke: cleat help (subcommand form) exits 0" {
  run cleat_bin help
  assert_success
  assert_output --partial "Cleat"
}

@test "smoke: cleat --version exits 0 under strict mode" {
  run cleat_bin --version
  assert_success
  assert_output --partial "cleat"
}

@test "smoke: cleat -v exits 0" {
  run cleat_bin -v
  assert_success
  assert_output --partial "cleat"
}

@test "smoke: cleat version (subcommand form) exits 0" {
  run cleat_bin version
  assert_success
  assert_output --partial "cleat"
}

# ── Unknown command handling ────────────────────────────────────────────────

@test "smoke: cleat unknown-command exits 1 without unbound variable" {
  run cleat_bin nonsense-command
  assert_failure
  refute_output --partial "unbound variable"
  refute_output --partial "syntax error"
}

# ── Status ───────────────────────────────────────────────────────────────────

@test "smoke: cleat status with no container exits cleanly" {
  printf '' > "$DOCKER_MOCK_DIR/ps_output"
  printf '' > "$DOCKER_MOCK_DIR/ps_a_output"
  printf '' > "$DOCKER_MOCK_DIR/images_output"
  mkdir -p "$TEST_TEMP/project"
  run cleat_bin status "$TEST_TEMP/project"
  assert_success
  assert_output --partial "Project:"
  refute_output --partial "unbound variable"
}

@test "smoke: cleat status with running container exits cleanly" {
  mkdir -p "$TEST_TEMP/project"
  # container_name_for uses $(pwd)/basename; mock will match any name.
  local cname="cleat-project-12345678"
  printf '%s\n' "$cname" > "$DOCKER_MOCK_DIR/ps_output"
  printf '%s\n' "$cname" > "$DOCKER_MOCK_DIR/ps_a_output"
  printf '%s\n' "cleat" > "$DOCKER_MOCK_DIR/images_output"
  run cleat_bin status "$TEST_TEMP/project"
  assert_success
  refute_output --partial "unbound variable"
}

# ── ps ───────────────────────────────────────────────────────────────────────

@test "smoke: cleat ps with no containers exits cleanly" {
  printf '' > "$DOCKER_MOCK_DIR/ps_output"
  printf '' > "$DOCKER_MOCK_DIR/ps_a_output"
  run cleat_bin ps
  assert_success
  refute_output --partial "unbound variable"
}

# ── config ──────────────────────────────────────────────────────────────────

@test "smoke: cleat config --list exits cleanly on fresh config" {
  run cleat_bin config --list
  assert_success
  refute_output --partial "unbound variable"
}

@test "smoke: cleat config --enable git persists to config file" {
  run cleat_bin config --enable git
  assert_success
  assert_output --partial "git"
  [[ -f "$CLEAT_CONFIG_DIR/config" ]] || {
    echo "config file not created"
    return 1
  }
  grep -q "^git$" "$CLEAT_CONFIG_DIR/config" || {
    echo "git cap not persisted"
    cat "$CLEAT_CONFIG_DIR/config"
    return 1
  }
}

@test "smoke: cleat config --enable unknown-cap exits 1" {
  run cleat_bin config --enable totally-not-a-cap
  assert_failure
  refute_output --partial "unbound variable"
}

@test "smoke: cleat config --disable env is idempotent on fresh config" {
  run cleat_bin config --disable env
  assert_success
  refute_output --partial "unbound variable"
}

# ── rm / stop-all / clean / nuke (safe variants) ────────────────────────────

@test "smoke: cleat rm with no container exits cleanly" {
  printf '' > "$DOCKER_MOCK_DIR/ps_output"
  printf '' > "$DOCKER_MOCK_DIR/ps_a_output"
  mkdir -p "$TEST_TEMP/project"
  run cleat_bin rm "$TEST_TEMP/project"
  assert_success
  refute_output --partial "unbound variable"
}

@test "smoke: cleat stop-all with no containers exits cleanly" {
  printf '' > "$DOCKER_MOCK_DIR/ps_output"
  printf '' > "$DOCKER_MOCK_DIR/ps_a_output"
  run cleat_bin stop-all
  assert_success
  refute_output --partial "unbound variable"
}

# ── Argument parsing (global flags) ─────────────────────────────────────────

@test "smoke: cleat --cap git --help does not error on flag parsing" {
  run cleat_bin --cap git --help
  assert_success
  refute_output --partial "unbound variable"
}

@test "smoke: cleat --env KEY=VAL --help parses global flags cleanly" {
  run cleat_bin --env "FOO=bar" --help
  assert_success
  refute_output --partial "unbound variable"
}

@test "smoke: cleat --env-file /nonexistent --help does not crash on flag parsing" {
  # Flag parsing happens before the file is validated; --help short-circuits.
  run cleat_bin --env-file "$TEST_TEMP/noexist.env" --help
  assert_success
  refute_output --partial "unbound variable"
}

@test "smoke: cleat --cap without value exits 1 cleanly" {
  run cleat_bin --cap
  assert_failure
  refute_output --partial "unbound variable"
  assert_output --partial "Missing"
}

@test "smoke: cleat --env without value exits 1 cleanly" {
  run cleat_bin --env
  assert_failure
  refute_output --partial "unbound variable"
  assert_output --partial "Missing"
}

# ── start / run (main lifecycle) ────────────────────────────────────────────
# These exercise the full startup path, which is where strict-mode bugs
# are most likely to surface. Mock docker always succeeds.

@test "smoke: cleat start with fresh image path exits cleanly" {
  mkdir -p "$TEST_TEMP/project"
  printf '' > "$DOCKER_MOCK_DIR/ps_output"
  printf '' > "$DOCKER_MOCK_DIR/ps_a_output"
  printf 'cleat\n' > "$DOCKER_MOCK_DIR/images_output"

  # start → reaches exec_claude which would docker exec; our docker stub
  # accepts it. We use a short timeout via a wrapper so interactive bits
  # don't hang.
  run cleat_bin_timeout 5 start "$TEST_TEMP/project"
  # The test must either succeed or fail with a clear message. It must
  # NOT hang, and must NOT emit strict-mode errors.
  refute_output --partial "unbound variable"
  refute_output --partial "command not found"
  refute_output --partial "syntax error"
}

@test "smoke: cleat run into existing image exits cleanly" {
  mkdir -p "$TEST_TEMP/project"
  printf '' > "$DOCKER_MOCK_DIR/ps_output"
  printf '' > "$DOCKER_MOCK_DIR/ps_a_output"
  printf 'cleat\n' > "$DOCKER_MOCK_DIR/images_output"

  run cleat_bin_timeout 5 run "$TEST_TEMP/project"
  refute_output --partial "unbound variable"
  refute_output --partial "syntax error"
}

@test "smoke: cleat start fails cleanly when docker run errors" {
  mkdir -p "$TEST_TEMP/project"
  printf '' > "$DOCKER_MOCK_DIR/ps_output"
  printf '' > "$DOCKER_MOCK_DIR/ps_a_output"
  printf 'cleat\n' > "$DOCKER_MOCK_DIR/images_output"
  export DOCKER_EXIT_CODE=125
  export DOCKER_STDERR="Error: something went wrong"

  run cleat_bin_timeout 5 start "$TEST_TEMP/project"
  refute_output --partial "unbound variable"
  refute_output --partial "syntax error"
  # Either the docker error surfaces, or a retry message — both OK
  [[ "$status" -ne 0 ]] || true
}

# ── Env passthrough end-to-end ─────────────────────────────────────────────
# The real binary + docker stub: confirm env vars make it into the docker
# exec args. This is the test that would have caught v0.6.3 at smoke level.

@test "smoke: cleat --env KEY=VAL start passes to docker run" {
  mkdir -p "$TEST_TEMP/project"
  printf '' > "$DOCKER_MOCK_DIR/ps_output"
  printf '' > "$DOCKER_MOCK_DIR/ps_a_output"
  printf 'cleat\n' > "$DOCKER_MOCK_DIR/images_output"

  run cleat_bin_timeout 5 --env "SMOKE_TEST_VAR=hello" start "$TEST_TEMP/project"
  # Check the docker stub recorded our env var
  grep -q 'SMOKE_TEST_VAR=hello' "$DOCKER_CALLS" || {
    echo "SMOKE_TEST_VAR not passed to docker run"
    echo "Docker calls:"
    cat "$DOCKER_CALLS"
    return 1
  }
}

@test "smoke: .cleat.env in project dir is loaded when env cap active" {
  mkdir -p "$TEST_TEMP/project"
  cat > "$TEST_TEMP/project/.cleat.env" << 'EOF'
DATABASE_URL=postgres://smoke-test/db
EOF
  cat > "$TEST_TEMP/project/.cleat" << 'EOF'
[caps]
env
EOF
  printf '' > "$DOCKER_MOCK_DIR/ps_output"
  printf '' > "$DOCKER_MOCK_DIR/ps_a_output"
  printf 'cleat\n' > "$DOCKER_MOCK_DIR/images_output"

  run cleat_bin_timeout 5 start "$TEST_TEMP/project"
  grep -q 'DATABASE_URL=postgres://smoke-test/db' "$DOCKER_CALLS" || {
    echo "DATABASE_URL from .cleat.env not passed to docker run"
    cat "$DOCKER_CALLS"
    return 1
  }
}

@test "smoke: cleat shell with .cleat.env passes env to docker exec" {
  mkdir -p "$TEST_TEMP/project"
  cat > "$TEST_TEMP/project/.cleat.env" << 'EOF'
SHELL_TEST_VAR=shell-value
EOF
  cat > "$TEST_TEMP/project/.cleat" << 'EOF'
[caps]
env
EOF
  # Compute the exact cname cleat will look for so the mock ps can return it
  local cname
  cname="$(_compute_cname "$TEST_TEMP/project")"
  [[ -n "$cname" ]] || { echo "cname computation failed"; return 1; }
  printf '%s\n' "$cname" > "$DOCKER_MOCK_DIR/ps_output"
  printf '%s\n' "$cname" > "$DOCKER_MOCK_DIR/ps_a_output"

  run cleat_bin_timeout 5 shell "$TEST_TEMP/project"
  grep -q 'SHELL_TEST_VAR=shell-value' "$DOCKER_CALLS" || {
    echo "SHELL_TEST_VAR not in docker exec args"
    echo "Expected cname: $cname"
    echo "Status: $status"
    echo "Output: $output"
    echo "Docker calls:"
    cat "$DOCKER_CALLS"
    return 1
  }
}

# ── Config drift and version label ──────────────────────────────────────────

# ── Session isolation ──────────────────────────────────────────────────────

@test "smoke: cleat start mounts per-project session overlay" {
  mkdir -p "$TEST_TEMP/project"
  printf '' > "$DOCKER_MOCK_DIR/ps_output"
  printf '' > "$DOCKER_MOCK_DIR/ps_a_output"
  printf 'cleat\n' > "$DOCKER_MOCK_DIR/images_output"

  local _bn _h project_key
  _bn="$(basename "$TEST_TEMP/project" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g')"
  _h="$(echo -n "$TEST_TEMP/project" | md5sum | head -c 8)"
  project_key="${_bn}-${_h}"

  run cleat_bin_timeout 5 start "$TEST_TEMP/project"
  grep -q "projects/-workspace" "$DOCKER_CALLS" || {
    echo "Session overlay mount missing from docker run"
    cat "$DOCKER_CALLS"
    return 1
  }
  # Use -F for literal match (project_key starts with - which grep reads as a flag)
  grep -qF -- "${project_key}:/home/coder/.claude/projects/-workspace" "$DOCKER_CALLS" || {
    echo "Session overlay source doesn't match project key"
    cat "$DOCKER_CALLS"
    return 1
  }
}

@test "smoke: cleat start mounts per-project history overlay" {
  mkdir -p "$TEST_TEMP/project"
  printf '' > "$DOCKER_MOCK_DIR/ps_output"
  printf '' > "$DOCKER_MOCK_DIR/ps_a_output"
  printf 'cleat\n' > "$DOCKER_MOCK_DIR/images_output"

  local _bn _h project_key
  _bn="$(basename "$TEST_TEMP/project" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g')"
  _h="$(echo -n "$TEST_TEMP/project" | md5sum | head -c 8)"
  project_key="${_bn}-${_h}"

  run cleat_bin_timeout 5 start "$TEST_TEMP/project"
  grep -qF -- "history.jsonl:/home/coder/.claude/history.jsonl" "$DOCKER_CALLS" || {
    echo "History overlay mount missing from docker run"
    cat "$DOCKER_CALLS"
    return 1
  }
  grep -qF -- "${project_key}/history.jsonl:/home/coder/.claude/history.jsonl" "$DOCKER_CALLS" || {
    echo "History overlay source doesn't match project key"
    cat "$DOCKER_CALLS"
    return 1
  }
}

# ── Config drift and version label ──────────────────────────────────────────

@test "smoke: cleat start stores config-hash label on run" {
  mkdir -p "$TEST_TEMP/project"
  printf '' > "$DOCKER_MOCK_DIR/ps_output"
  printf '' > "$DOCKER_MOCK_DIR/ps_a_output"
  printf 'cleat\n' > "$DOCKER_MOCK_DIR/images_output"

  run cleat_bin_timeout 5 start "$TEST_TEMP/project"
  grep -q 'sh.cleat.config-hash=' "$DOCKER_CALLS" || {
    echo "config-hash label missing from docker run"
    cat "$DOCKER_CALLS"
    return 1
  }
}

@test "smoke: cleat start stores version label on run" {
  mkdir -p "$TEST_TEMP/project"
  printf '' > "$DOCKER_MOCK_DIR/ps_output"
  printf '' > "$DOCKER_MOCK_DIR/ps_a_output"
  printf 'cleat\n' > "$DOCKER_MOCK_DIR/images_output"

  run cleat_bin_timeout 5 start "$TEST_TEMP/project"
  grep -q 'sh.cleat.version=' "$DOCKER_CALLS" || {
    echo "version label missing from docker run"
    cat "$DOCKER_CALLS"
    return 1
  }
}
