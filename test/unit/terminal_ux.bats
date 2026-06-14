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
  _resolve_config_drift() { true; }
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
  hash="$(printf '%s' "$project_path" | _md5 2>/dev/null | head -c 8)"
  local expected_cname="cleat-${dir_name}-${hash}"

  # Create settings overlay dir so stale-mount check doesn't trigger
  mkdir -p "$CLEAT_RUN_DIR/${expected_cname}/settings"
  echo '{}' > "$CLEAT_RUN_DIR/${expected_cname}/settings/settings.json"

  # Mock docker: image exists, container exists (stopped), start fails, run fails
  # Both start and run fail so the test verifies failure handling regardless
  # of whether the CLI takes the interactive recovery path (macOS TTY) or not.
  cat > "$TEST_TEMP/strict-bin/docker" << MOCK
#!/bin/bash
echo "docker \$*" >> "$TEST_TEMP/strict-docker-calls"
# Match \`-a\` as a separate flag, not a substring. The previous \`*-a*\` glob
# matched container names with hex hashes starting with 'a' (e.g. \`-a8c2...\`),
# making \`docker ps\` (without \`-a\`) appear to find the container and the
# cleat happy-path success-flow run instead of the start-failure recovery
# we're trying to test. Resulted in ~1/16 macOS CI flakes.
case "\$1" in
  images) echo "cleat" ;;
  ps)
    case " \$* " in
      *" -a "*|*" --all "*) echo "$expected_cname" ;;
      *) ;;
    esac
    ;;
  start) exit 1 ;;
  run) exit 125 ;;
  info) echo "Server Version: 24.0.0" ;;
  *) ;;
esac
MOCK
  chmod +x "$TEST_TEMP/strict-bin/docker"

  # Run actual binary — set -euo pipefail is active.
  # Redirect stdin from /dev/null to ensure non-interactive mode
  # (macOS CI runners may report TTY=true, triggering interactive recovery).
  cd "$TEST_TEMP/strict-project"
  run env PATH="$TEST_TEMP/strict-bin:$PATH" \
    HOME="$TEST_TEMP" \
    XDG_CONFIG_HOME="$TEST_TEMP/strict-config" \
    bash "$CLI" start < /dev/null

  # Must fail with proper message (spin_stop was reached, not set -e abort)
  assert_failure
  assert_output --partial "Container failed to start"
  rm -rf "$CLEAT_RUN_DIR/${expected_cname}/settings"
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

@test "summary block: without docker cap, project maps to /workspace" {
  ACTIVE_CAPS=(git)
  run _print_summary_block "cleat-test-12345678" "$HOME/my-project"
  assert_output --partial "~/my-project"
  assert_output --partial "/workspace"
  refute_output --partial "same path"
}

@test "summary block: with docker cap, project shows host path (not /workspace)" {
  # The docker cap mounts the project at its host path and sets workdir there,
  # so the container's cwd IS the host path — /workspace would be a lie.
  ACTIVE_CAPS=(docker)
  run _print_summary_block "cleat-test-12345678" "$HOME/my-project"
  assert_output --partial "~/my-project"
  assert_output --partial "(same path, sandboxed)"
  refute_output --partial "→${RESET} /workspace"
  refute_output --partial " /workspace"
}

@test "summary block: shows capabilities when active" {
  ACTIVE_CAPS=(git ssh)
  run _print_summary_block "cleat-test-12345678" "$TEST_TEMP/project"
  assert_output --partial "Caps:"
  assert_output --partial "git, ssh"
}

# ── Warning color: amber (256-color 214), not plain yellow ───────────────────

@test "warn: the ! marker renders in amber (xterm-256 color 214)" {
  run warn "caution: something happened"
  assert_output --partial "38;5;214"
  assert_output --partial "caution: something happened"
}

@test "warn_sandbox: the whole line is amber, matching the sandbox cap" {
  # A sandbox-break warning must read as loud as the docker cap: the message
  # text — not just the `!` — is amber. The substring asserts the amber code is
  # immediately followed by the marker AND message with no reset between them
  # (the bug: warn-style output resets the color right after `!`).
  run warn_sandbox "Docker socket mounted — container can create host-level processes"
  assert_output --partial "214m! Docker socket mounted"
}

@test "caps: the sandbox row renders in amber, matching the warning color" {
  ACTIVE_CAPS=(git docker)   # two categories → labeled block with a sandbox row
  run _print_caps "  " "Caps:" "       "
  assert_output --partial "sandbox:"
  assert_output --partial "38;5;214"
  assert_output --partial "(breaks isolation)"
}

@test "caps: the mount row is NOT amber (stays green)" {
  ACTIVE_CAPS=(git ssh)   # mount-only → single green row
  run _print_caps "  " "Caps:" "       "
  refute_output --partial "38;5;214"
}

@test "caps: a sandbox-only (single-category) row is also amber" {
  ACTIVE_CAPS=(docker)   # sandbox-only → single-line collapsed form
  run _print_caps "  " "Caps:" "       "
  assert_output --partial "38;5;214"
  assert_output --partial "docker"
}

# ── Aligned Y/n prompt helper ────────────────────────────────────────────────

@test "ask_yn: question is indented under the headline text, not at the margin" {
  run _ask_yn _discard "Rebuild the image now? [Y/n] " <<< "y"
  # Four-space indent aligns the question under an info()/warn() headline's text.
  assert_output --partial "    Rebuild the image now? [Y/n] "
}

@test "ask_yn: reads the answer into the named variable" {
  local answer=""
  _ask_yn answer "Proceed? [Y/n] " <<< "n" >/dev/null
  assert_equal "$answer" "n"
}

@test "ask_yn: a real Enter (empty line) stays empty so callers apply the [Y/n] default" {
  local answer="sentinel"
  _ask_yn answer "Proceed? [Y/n] " <<< "" >/dev/null
  assert_equal "$answer" ""
}

@test "ask_yn: EOF / redirected stdin yields decline (n), never empty default-yes" {
  # cleat start </dev/null, wrappers, tmux respawn: stdout may be a TTY while
  # stdin is EOF. read fails -> must decline, NOT return empty (which callers
  # treat as the default yes and would silently run a destructive action).
  local answer="sentinel"
  _ask_yn answer "Proceed? [Y/n] " </dev/null >/dev/null
  assert_equal "$answer" "n"
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

@test "env summary inline: shows line with 0 count when file exists but has only comments" {
  ACTIVE_CAPS=(env)
  mkdir -p "$TEST_TEMP/project"
  cat > "$TEST_TEMP/project/.cleat.env" << 'EOF'
# only comments
# GH_TOKEN
EOF
  run _env_summary_inline "$TEST_TEMP/project"
  assert_output --partial "Env:"
  assert_output --partial "0 from .cleat.env"
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

@test "start: prints docker-cap security warning when cap is active" {
  # The docker cap is the only one that can escape the sandbox, so startup
  # prints a loud warning line when it's on. Silent when off.
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project"

  cat > "$CLEAT_GLOBAL_CONFIG" << 'EOF'
[caps]
docker
EOF

  run cmd_start "$TEST_TEMP/project"
  assert_success
  assert_output --partial "Docker socket mounted"
}

@test "start: does NOT print docker warning when cap is off" {
  # The baseline launch must stay quiet — no sandbox-break warning unless
  # the user has explicitly opted in to the docker cap.
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project"

  run cmd_start "$TEST_TEMP/project"
  assert_success
  refute_output --partial "Docker socket mounted"
}

@test "resume: prints docker-cap security warning when cap is active" {
  # cleat resume launches Claude attached to an existing container. If the
  # cap is active, the warning must print here too — users should never
  # hit Claude with a host-socket-mounted container silently.
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"
  mock_docker_ps "$cname"
  mock_docker_ps_a "$cname"

  cat > "$CLEAT_GLOBAL_CONFIG" << 'EOF'
[caps]
docker
EOF

  run cmd_resume "$TEST_TEMP/project"
  assert_success
  assert_output --partial "Docker socket mounted"

  rm -rf "$CLEAT_RUN_DIR/${cname}/settings"
}

@test "resume: does NOT print docker warning when cap is off" {
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"
  mock_docker_ps "$cname"
  mock_docker_ps_a "$cname"

  run cmd_resume "$TEST_TEMP/project"
  assert_success
  refute_output --partial "Docker socket mounted"

  rm -rf "$CLEAT_RUN_DIR/${cname}/settings"
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
  assert_output --partial "Image ready"
  assert_output --partial "(cached)"
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

@test "run: the cached Image-ready line opens the bring-up with no leading blank" {
  # The bring-up block must be one contiguous coloured group so a rebuild's
  # "Image rebuilt" flows straight into "Image ready (cached)". A stray leading
  # blank here would split that group (and double up with the release
  # highlight's own trailing blank). So Image-ready must be the FIRST line
  # cmd_run prints — not preceded by a blank. Re-adding `echo ""` pushes it to
  # line 2 and trips this test.
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project"
  run cmd_run "$TEST_TEMP/project"
  assert_success
  assert_output --partial "Image ready"
  local cls
  cls="$(printf '%s\n' "$output" | awk '
    /Image ready/ && /\(cached\)/ { print (NR==1 ? "FIRST" : "NOTFIRST"); f=1; exit }
    END { if (!f) print "NOTFOUND" }
  ')"
  run echo "$cls"
  assert_output "FIRST"
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

# ── terminal restore call sites ───────────────────────────────────────────
# exec_claude's restore is pinned by a regression test; shell and login run
# their own interactive `docker exec` and must restore independently — a
# crashed TUI in either leaves the same raw-mode/mouse-tracking garbage.

@test "shell: restores the terminal after the interactive exec" {
  mkdir -p "$TEST_TEMP/project"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"
  mock_docker_ps "$cname"
  _wait_for_coder_remap() { true; }
  _ensure_docker_access() { true; }
  _restore_terminal() { echo "RESTORE_TERMINAL_CALLED"; }
  run cmd_shell "$TEST_TEMP/project"
  assert_success
  assert_output --partial "RESTORE_TERMINAL_CALLED"
}

@test "login: restores the terminal after the interactive exec" {
  mkdir -p "$TEST_TEMP/project"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"
  mock_docker_ps "$cname"
  _wait_for_coder_remap() { true; }
  _ensure_docker_access() { true; }
  _host_open_cmd() { echo ""; }
  _restore_terminal() { echo "RESTORE_TERMINAL_CALLED"; }
  run cmd_login "$TEST_TEMP/project"
  assert_success
  assert_output --partial "RESTORE_TERMINAL_CALLED"
}

# ── spinner hardening (TTY mode) ──────────────────────────────────────────
# Bats is never a TTY, so these run a harness script that forces _is_tty.
# Two guards: a second spin() must reap the first frame loop (two \r loops
# interleave into garbage), and a loop whose parent died without spin_stop
# (SIGKILL, hard crash) must exit on its own instead of spamming the prompt.

@test "spin: a second spin stops the first frame loop before starting its own" {
  sed 's/^set -euo pipefail$/:/' "$CLI" > "$TEST_TEMP/cli_stripped"
  cat > "$TEST_TEMP/spin_twice.sh" <<EOF
source "$TEST_TEMP/cli_stripped"
_is_tty() { return 0; }
spin "one" > /dev/null
first=\$_SPIN_PID
spin "two" > /dev/null
if kill -0 "\$first" 2>/dev/null; then
  echo "FIRST_LOOP_STILL_RUNNING"
  spin_stop 0 "x" > /dev/null
  exit 1
fi
spin_stop 0 "x" > /dev/null
echo "FIRST_LOOP_REAPED"
EOF
  run bash "$TEST_TEMP/spin_twice.sh"
  assert_success
  assert_output --partial "FIRST_LOOP_REAPED"
}

@test "spin: the frame loop exits on its own when its parent dies without spin_stop" {
  sed 's/^set -euo pipefail$/:/' "$CLI" > "$TEST_TEMP/cli_stripped"
  cat > "$TEST_TEMP/spin_orphan.sh" <<EOF
source "$TEST_TEMP/cli_stripped"
_is_tty() { return 0; }
spin "x" > /dev/null
echo "\$_SPIN_PID" > "$TEST_TEMP/spin_pid"
kill -9 \$\$
EOF
  bash "$TEST_TEMP/spin_orphan.sh" > /dev/null 2>&1 || true
  local spid dead=0
  spid="$(cat "$TEST_TEMP/spin_pid")"
  process_exited "$spid" && dead=1
  # Unconditional reap: a live straggler holds bats' fd and hangs the file.
  kill "$spid" 2>/dev/null || true
  [ "$dead" = 1 ] || { echo "spinner loop outlived its dead parent"; return 1; }
}

# ── Terminal hyperlinks (OSC 8) ───────────────────────────────────────────────
# Clickable links where the terminal supports OSC 8 (iTerm2, VS Code, WezTerm,
# Ghostty, kitty, GNOME/VTE), a bare clickable URL everywhere else. Conservative
# allow-list so an unknown terminal / multiplexer never gets escape garbage.

@test "osc8: detected for known terminals via TERM_PROGRAM" {
  _is_tty() { return 0; }
  for prog in iTerm.app vscode WezTerm ghostty Hyper Tabby rio; do
    TERM_PROGRAM="$prog" run _supports_osc8
    assert_success
  done
}

@test "osc8: detected via kitty / wezterm / vte env when TERM_PROGRAM is unset" {
  _is_tty() { return 0; }
  unset TERM_PROGRAM
  ( KITTY_WINDOW_ID=1 run _supports_osc8; assert_success )
  ( WEZTERM_PANE=0 run _supports_osc8; assert_success )
  ( VTE_VERSION=6003 run _supports_osc8; assert_success )
}

@test "osc8: NOT detected for Apple Terminal or an unknown terminal" {
  _is_tty() { return 0; }
  unset KITTY_WINDOW_ID WEZTERM_PANE VTE_VERSION
  TERM_PROGRAM="Apple_Terminal" run _supports_osc8
  assert_failure
  TERM_PROGRAM="" run _supports_osc8
  assert_failure
}

@test "osc8: an old VTE (<5000) is not treated as capable" {
  _is_tty() { return 0; }
  unset TERM_PROGRAM KITTY_WINDOW_ID WEZTERM_PANE
  VTE_VERSION=4002 run _supports_osc8
  assert_failure
}

@test "osc8: never emitted to a non-TTY (no escapes into pipes)" {
  _is_tty() { return 1; }   # piped / redirected
  TERM_PROGRAM="iTerm.app" run _supports_osc8
  assert_failure
}

@test "hyperlink: wraps text in an OSC 8 sequence when supported" {
  _supports_osc8() { return 0; }
  run _hyperlink "https://cleat.sh/x" "click me"
  assert_success
  # OSC 8 opener with the URL, the visible text, and the closer — real ESC bytes.
  assert_output --partial "$(printf '\033]8;;https://cleat.sh/x\033\\')"
  assert_output --partial "click me"
  assert_output --partial "$(printf '\033]8;;\033\\')"
}

@test "hyperlink: falls back to the bare URL (clickable via autodetect) when unsupported" {
  _supports_osc8() { return 1; }
  run _hyperlink "https://cleat.sh/x" "click me"
  assert_success
  assert_output "https://cleat.sh/x"          # the full URL, not the short text
  refute_output --partial "$(printf '\033]8;;')"   # no OSC 8 escapes
}
