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

  # Disable clipboard and update check for cmd_ tests
  _host_clip_cmd() { echo ""; }
  check_for_update() { true; }
  check_drift() { true; }
  show_first_run_tip() { true; }
}

teardown() { _common_teardown; }

# ── Bash compatibility (rule 12) ──────────────────────────────────────────

@test "source: no associative arrays (local -A / declare -A)" {
  # local -A and declare -A require bash 4.0+; macOS ships bash 3.2
  run grep -n 'local -A\|declare -A' "$CLI"
  assert_failure  # grep returns 1 = no matches
}

@test "source: no readarray or mapfile" {
  run grep -n 'readarray\|mapfile' "$CLI"
  assert_failure
}

@test "source: no pipe stderr (|&)" {
  run grep -n '|&' "$CLI"
  assert_failure
}

@test "source: all docker commands in spin contexts use || rc protection" {
  # Regression guard: docker start/run/build followed by > /dev/null must
  # use || rc=$? to prevent set -e from orphaning the spinner.
  # Without this, a failed docker command kills the script and the disowned
  # spinner keeps writing to the terminal forever.
  local unsafe
  unsafe=$(grep -n 'docker \(start\|run -d\|build\) ' "$CLI" \
    | grep '/dev/null' \
    | grep -v '|| ' \
    | grep -v '^ *#' || true)
  if [[ -n "$unsafe" ]]; then
    echo "Docker commands missing || rc=\$? protection (spinner orphan risk):" >&2
    echo "$unsafe" >&2
    return 1
  fi
}

# ── Strict mode (rule 13) ─────────────────────────────────────────────────
# These run the actual binary, not sourced, to catch set -euo pipefail issues.

@test "strict mode: docker start failure exits cleanly under set -e" {
  # Runs the ACTUAL binary (not sourced) to verify set -euo pipefail
  # does not orphan the spinner when docker start fails.
  mkdir -p "$TEST_TEMP/strict-project" "$TEST_TEMP/strict-bin" "$TEST_TEMP/strict-config"

  # Compute the exact container name the CLI will generate
  local project_path="$TEST_TEMP/strict-project"
  local dir_name
  dir_name="$(basename "$project_path" | tr '[:upper:]' '[:lower:]')"
  local hash
  hash="$(printf '%s' "$project_path" | md5sum 2>/dev/null | head -c 8)"
  local expected_cname="cleat-${dir_name}-${hash}"

  # Mock docker: image exists, container exists (stopped), start fails
  cat > "$TEST_TEMP/strict-bin/docker" << MOCK
#!/bin/bash
case "\$1" in
  images) echo "cleat" ;;
  ps)
    case "\$*" in
      *-a*) echo "$expected_cname" ;;
      *) ;;
    esac
    ;;
  start) exit 1 ;;
  info) echo "Server Version: 24.0.0" ;;
  *) ;;
esac
MOCK
  chmod +x "$TEST_TEMP/strict-bin/docker"

  # Run actual binary — set -euo pipefail is active
  run env PATH="$TEST_TEMP/strict-bin:$PATH" \
    HOME="$TEST_TEMP" \
    XDG_CONFIG_HOME="$TEST_TEMP/strict-config" \
    bash "$CLI" start "$TEST_TEMP/strict-project"

  # Must fail with proper message (spin_stop was reached, not set -e abort)
  assert_failure
  assert_output --partial "Container failed to start"
}

@test "strict mode: cleat --help runs without error" {
  run bash "$CLI" --help
  assert_success
}

@test "strict mode: cleat --version runs without error" {
  run bash "$CLI" --version
  assert_success
}

@test "strict mode: cleat with no args shows help or starts (exits cleanly)" {
  # Without docker, this will fail at the docker check — but it should
  # get past argument parsing and global flag handling without set -u errors.
  # We check that it does NOT die with "unbound variable".
  run bash "$CLI" 2>&1
  refute_output --partial "unbound variable"
}

@test "strict mode: cleat start with no args does not hit unbound variable" {
  run bash "$CLI" start 2>&1
  refute_output --partial "unbound variable"
}

# ── _has_unicode ──────────────────────────────────────────────────────────

@test "_has_unicode: true when LANG contains UTF-8" {
  LANG="en_US.UTF-8" LC_ALL="" LC_CTYPE=""
  run _has_unicode
  assert_success
}

@test "_has_unicode: true when LC_ALL contains utf8" {
  LANG="" LC_ALL="C.utf8" LC_CTYPE=""
  run _has_unicode
  assert_success
}

@test "_has_unicode: true when LC_CTYPE contains UTF-8" {
  LANG="" LC_ALL="" LC_CTYPE="en_US.UTF-8"
  run _has_unicode
  assert_success
}

@test "_has_unicode: false when no locale has UTF-8" {
  LANG="C" LC_ALL="" LC_CTYPE=""
  run _has_unicode
  assert_failure
}

@test "_has_unicode: false when all locale vars empty" {
  LANG="" LC_ALL="" LC_CTYPE=""
  run _has_unicode
  assert_failure
}

# ── spin/spin_stop non-TTY fallback ─────────────────────────────────────

@test "spin: non-TTY falls back to info line" {
  # Tests run in a pipe (non-TTY), so spin should fall back to info
  run spin "Building image..."
  assert_success
  assert_output --partial "Building image..."
}

@test "spin_stop: non-TTY success prints checkmark" {
  _SPIN_PID=""
  run spin_stop 0 "Image ready"
  assert_success
  assert_output --partial "Image ready"
}

@test "spin_stop: non-TTY failure prints error" {
  _SPIN_PID=""
  run spin_stop 1 "Image ready" "Build failed"
  assert_success
  assert_output --partial "Build failed"
}

@test "spin_stop: custom fail message differs from ok message" {
  _SPIN_PID=""
  run spin_stop 1 "All good" "Something broke"
  assert_output --partial "Something broke"
  refute_output --partial "All good"
}

@test "spin_stop: fail message defaults to ok message" {
  _SPIN_PID=""
  run spin_stop 1 "Operation"
  assert_output --partial "Operation"
}

# ── _cleanup_spin ─────────────────────────────────────────────────────────

@test "_cleanup_spin: safe when no spinner running" {
  _SPIN_PID=""
  run _cleanup_spin
  assert_success
}

# ── _print_summary_block ─────────────────────────────────────────────────

@test "summary block: shows container name" {
  ACTIVE_CAPS=()
  run _print_summary_block "cleat-myapp-12345678" ""
  assert_output --partial "Container:"
  assert_output --partial "cleat-myapp-12345678"
}

@test "summary block: shows project path with ~ substitution" {
  ACTIVE_CAPS=()
  run _print_summary_block "cleat-test-12345678" "$HOME/my-project"
  assert_output --partial "Project:"
  assert_output --partial "~/my-project"
  assert_output --partial "/workspace"
}

@test "summary block: shows capabilities when active" {
  ACTIVE_CAPS=(git ssh)
  run _print_summary_block "cleat-test-12345678" "$TEST_TEMP/project"
  assert_output --partial "Caps:"
  assert_output --partial "git, ssh"
}

@test "summary block: omits Caps line when no capabilities" {
  ACTIVE_CAPS=()
  run _print_summary_block "cleat-test-12345678" "$TEST_TEMP/project"
  refute_output --partial "Caps:"
}

@test "summary block: omits Project line when project is empty" {
  ACTIVE_CAPS=()
  run _print_summary_block "cleat-test-12345678" ""
  assert_output --partial "Container:"
  refute_output --partial "Project:"
}

# ── _env_summary_inline ──────────────────────────────────────────────────

@test "env summary inline: shows count from global env file" {
  ACTIVE_CAPS=(env)
  cat > "$CLEAT_GLOBAL_ENV" << 'EOF'
FOO=bar
BAZ=qux
EOF
  run _env_summary_inline ""
  assert_output --partial "Env:"
  assert_output --partial "2 from ~/.config/cleat/env"
}

@test "env summary inline: shows count from project env file" {
  ACTIVE_CAPS=(env)
  mkdir -p "$TEST_TEMP/project"
  cat > "$TEST_TEMP/project/.cleat.env" << 'EOF'
MY_VAR=value
EOF
  run _env_summary_inline "$TEST_TEMP/project"
  assert_output --partial "Env:"
  assert_output --partial "1 from .cleat.env"
}

@test "env summary inline: shows both counts" {
  ACTIVE_CAPS=(env)
  cat > "$CLEAT_GLOBAL_ENV" << 'EOF'
FOO=bar
EOF
  mkdir -p "$TEST_TEMP/project"
  cat > "$TEST_TEMP/project/.cleat.env" << 'EOF'
MY_VAR=value
OTHER=val
EOF
  run _env_summary_inline "$TEST_TEMP/project"
  assert_output --partial "1 from ~/.config/cleat/env"
  assert_output --partial "2 from .cleat.env"
}

@test "env summary inline: silent when env cap not active" {
  ACTIVE_CAPS=()
  cat > "$CLEAT_GLOBAL_ENV" << 'EOF'
FOO=bar
EOF
  run _env_summary_inline ""
  assert_output ""
}

@test "env summary inline: silent when no env files exist" {
  ACTIVE_CAPS=(env)
  run _env_summary_inline "$TEST_TEMP/nonexistent"
  assert_output ""
}

# ── Canonical startup messages ────────────────────────────────────────────

@test "start: outputs Auth shared message" {
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project"
  run cmd_start "$TEST_TEMP/project"
  assert_success
  assert_output --partial "Auth shared"
}

@test "start: outputs Claude launched message" {
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project"
  run cmd_start "$TEST_TEMP/project"
  assert_success
  assert_output --partial "Claude launched"
}

@test "start: outputs summary block with container name" {
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"
  run cmd_start "$TEST_TEMP/project"
  assert_success
  assert_output --partial "Container:"
  assert_output --partial "$cname"
}

@test "start: outputs Image ready cached when image exists" {
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"
  mock_docker_ps "$cname"
  mock_docker_ps_a "$cname"
  run cmd_start "$TEST_TEMP/project"
  assert_success
  assert_output --partial "Image ready (cached)"
}

@test "resume: outputs summary block with container name" {
  mkdir -p "$TEST_TEMP/project"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"
  mock_docker_ps "$cname"
  mock_docker_ps_a "$cname"
  run cmd_resume "$TEST_TEMP/project"
  assert_success
  assert_output --partial "Container:"
  assert_output --partial "$cname"
}

@test "resume: outputs summary block with caps when active" {
  mkdir -p "$TEST_TEMP/project"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"
  mock_docker_ps "$cname"
  mock_docker_ps_a "$cname"
  cat > "$CLEAT_GLOBAL_CONFIG" << 'EOF'
[caps]
git
ssh
EOF
  run cmd_resume "$TEST_TEMP/project"
  assert_success
  assert_output --partial "Caps:"
  assert_output --partial "git, ssh"
}

# ── cmd_stop canonical message ────────────────────────────────────────────

@test "stop: outputs canonical exit message" {
  mkdir -p "$TEST_TEMP/project"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"
  mock_docker_ps "$cname"
  run cmd_stop "$TEST_TEMP/project"
  assert_success
  assert_output --partial "Session ended"
  assert_output --partial "cleat resume"
}

# ── exec_claude clean exit ────────────────────────────────────────────────

@test "exec_claude: exit 0 shows session ended message" {
  _host_clip_cmd() { echo ""; }
  export DOCKER_EXIT_CODE=0
  run exec_claude "test-ctr" --dangerously-skip-permissions
  assert_output --partial "Session ended"
  assert_output --partial "cleat resume"
}

@test "exec_claude: exit 130 (Ctrl-C) shows no message" {
  _host_clip_cmd() { echo ""; }
  export DOCKER_EXIT_CODE=130
  run exec_claude "test-ctr" --dangerously-skip-permissions
  refute_output --partial "Session ended"
  refute_output --partial "exited with code"
}

# ── _do_build output suppression ──────────────────────────────────────────

@test "build: docker output is not printed to user" {
  # The mock docker stub outputs "docker build ..." to DOCKER_CALLS file
  # but _do_build should capture stdout/stderr and not leak it
  run _do_build
  assert_success
  # Output should only contain our own messages, not docker build output
  assert_output --partial "Image ready"
  refute_output --partial "docker build"
}

@test "build: failure shows error message" {
  export DOCKER_EXIT_CODE=1
  run _do_build
  assert_failure
  assert_output --partial "Image build failed"
}

# ── cmd_run output suppression ────────────────────────────────────────────

@test "run: outputs Container started on success" {
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project"
  run cmd_run "$TEST_TEMP/project"
  assert_success
  assert_output --partial "Container started"
}

@test "run: outputs Image ready when building" {
  mkdir -p "$TEST_TEMP/project"
  run cmd_run "$TEST_TEMP/project"
  assert_success
  assert_output --partial "Image ready"
}

# ── rebuild output ───────────────────────────────────────────────────────

@test "rebuild: outputs Image rebuilt on success" {
  run cmd_rebuild
  assert_success
  assert_output --partial "Image rebuilt"
  refute_output --partial "docker build"
}

@test "rebuild: failure shows error message" {
  export DOCKER_EXIT_CODE=1
  run cmd_rebuild
  assert_failure
  assert_output --partial "Image build failed"
}

# ── header function ──────────────────────────────────────────────────────

@test "header: prints branded banner" {
  run header
  assert_output --partial "Cleat"
  assert_output --partial "Run anything. Break nothing."
}

# ── info/success/warn/error prefix functions ─────────────────────────────

@test "info: prints with blue arrow prefix" {
  run info "test message"
  assert_output --partial "test message"
}

@test "success: prints with checkmark" {
  run success "done"
  assert_output --partial "done"
}

@test "warn: prints with exclamation" {
  run warn "caution"
  assert_output --partial "caution"
}

@test "error: prints with cross" {
  run error "failed"
  assert_output --partial "failed"
}

# ── exec_claude non-zero exit ────────────────────────────────────────────

@test "exec_claude: non-zero non-130 exit shows warning with code" {
  _host_clip_cmd() { echo ""; }
  export DOCKER_EXIT_CODE=1
  run exec_claude "test-ctr" --dangerously-skip-permissions
  assert_output --partial "exited with code 1"
}

# ── resume canonical messages ────────────────────────────────────────────

@test "resume: outputs Session resumed message" {
  mkdir -p "$TEST_TEMP/project"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"
  mock_docker_ps "$cname"
  mock_docker_ps_a "$cname"
  run cmd_resume "$TEST_TEMP/project"
  assert_success
  assert_output --partial "Session resumed"
}

# ── start with env summary in full flow ──────────────────────────────────

@test "start: outputs Env summary when env cap active" {
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project"
  cat > "$CLEAT_GLOBAL_CONFIG" << 'EOF'
[caps]
env
EOF
  cat > "$CLEAT_GLOBAL_ENV" << 'EOF'
FOO=bar
BAZ=qux
EOF
  run cmd_start "$TEST_TEMP/project"
  assert_success
  assert_output --partial "Env:"
  assert_output --partial "2 from ~/.config/cleat/env"
}

# ── docker output suppression: no docker noise leaks ─────────────────────

@test "start: no docker noise in output" {
  mkdir -p "$TEST_TEMP/project"
  run cmd_start "$TEST_TEMP/project"
  assert_success
  refute_output --partial "docker build"
  refute_output --partial "docker run"
  refute_output --partial "docker start"
}

@test "stop: docker stop output is suppressed" {
  mkdir -p "$TEST_TEMP/project"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"
  mock_docker_ps "$cname"
  run cmd_stop "$TEST_TEMP/project"
  assert_success
  refute_output --partial "docker stop"
}
