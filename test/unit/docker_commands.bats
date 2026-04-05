#!/usr/bin/env bats
load "../setup"
setup() {
  _common_setup
  use_docker_stub
  source_cli
  _host_clip_cmd() { echo ""; }
  check_for_update() { true; }
}
teardown() { _common_teardown; }

# ── build / rebuild ─────────────────────────────────────────────────────────

@test "build: creates image when none exists" {
  run cmd_build
  assert_success
  run docker_build_calls
  assert_output --partial "-t cleat"
  assert_output --partial "docker/Dockerfile"
}

@test "build: skips when image already exists" {
  mock_docker_images "cleat"
  run cmd_build
  assert_success
  assert_output --partial "Image ready (cached)"
}

@test "rebuild: always builds with --no-cache" {
  run cmd_rebuild
  run docker_build_calls
  assert_output --partial "--no-cache"
  assert_output --partial "docker/Dockerfile"
}

# ── run: container creation ─────────────────────────────────────────────────

@test "run: creates container with correct name, mounts, env, and limits" {
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"

  run cmd_run "$TEST_TEMP/project"
  assert_success

  # All assertions use fail() which works even under set +e
  run assert_docker_run_has "$cname" "--name $cname"
  assert_success
  run assert_docker_run_has "$cname" "$TEST_TEMP/project:/workspace"
  assert_success
  run assert_docker_run_has "$cname" ".claude:/home/coder/.claude"
  assert_success
  run assert_docker_run_has "$cname" "/tmp/cleat-clip"
  assert_success
  run assert_docker_run_has "$cname" "HOST_UID="
  assert_success
  run assert_docker_run_has "$cname" "HOST_GID="
  assert_success
  run assert_docker_run_has "$cname" "HOME=/home/coder"
  assert_success
  run assert_docker_run_has "$cname" "--memory 8g"
  assert_success
  run assert_docker_run_has "$cname" "--pids-limit 1024"
  assert_success
  run assert_docker_run_has "$cname" "-it"
  assert_success
}

@test "run: docker run failure is handled (spinner not orphaned)" {
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project"
  export DOCKER_EXIT_CODE=1  # docker run will fail

  run cmd_run "$TEST_TEMP/project"
  assert_failure
  assert_output --partial "Container failed to start"
}

@test "run: fails for nonexistent project directory" {
  mock_docker_images "cleat"
  run cmd_run "/nonexistent/project"
  assert_failure
  assert_output --partial "does not exist"
}

@test "run: fails for broken symlink" {
  mock_docker_images "cleat"
  ln -sf "$TEST_TEMP/nonexistent" "$TEST_TEMP/broken-link"
  run cmd_run "$TEST_TEMP/broken-link"
  assert_failure
  assert_output --partial "does not exist"
}

@test "run: warns and skips when container already running" {
  mkdir -p "$TEST_TEMP/project"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"
  mock_docker_ps "$cname"

  run cmd_run "$TEST_TEMP/project"
  assert_success
  assert_output --partial "already running"
}

@test "run: removes stopped container before creating new one" {
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"
  mock_docker_ps_a "$cname"

  run cmd_run "$TEST_TEMP/project"
  assert_success
  run docker_calls
  assert_output --partial "docker rm $cname"
}

@test "run: auto-builds image if missing" {
  mkdir -p "$TEST_TEMP/project"
  run cmd_run "$TEST_TEMP/project"
  run docker_build_calls
  assert_output --partial "docker build"
}

@test "run: mounts .claude.json only when it exists" {
  # Skip if .claude.json is a bind mount (can't be temporarily removed)
  if [[ -f "${HOME}/.claude.json" ]] && ! mv "${HOME}/.claude.json" "${HOME}/.claude.json.bak" 2>/dev/null; then
    skip ".claude.json is a bind mount, can't test conditional mount"
  fi

  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"

  run cmd_run "$TEST_TEMP/project"
  run assert_docker_run_lacks "$cname" ".claude.json:/home/coder/.claude.json"
  assert_success

  # Restore if we moved it
  [[ -f "${HOME}/.claude.json.bak" ]] && mv "${HOME}/.claude.json.bak" "${HOME}/.claude.json" || true
}

@test "run: handles project path with spaces" {
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/my project"
  run cmd_run "$TEST_TEMP/my project"
  assert_success
}

# ── stop ────────────────────────────────────────────────────────────────────

@test "stop: stops running container and suggests resume" {
  mkdir -p "$TEST_TEMP/project"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"
  mock_docker_ps "$cname"

  run cmd_stop "$TEST_TEMP/project"
  assert_success
  assert_output --partial "Session ended"
  assert_output --partial "cleat resume"
}

@test "stop: no-op when container not running" {
  mkdir -p "$TEST_TEMP/project"
  run cmd_stop "$TEST_TEMP/project"
  assert_success
  assert_output --partial "not running"
}

# ── rm ──────────────────────────────────────────────────────────────────────

@test "rm: stops running container then removes it" {
  mkdir -p "$TEST_TEMP/project"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"
  mock_docker_ps "$cname"
  mock_docker_ps_a "$cname"

  run cmd_rm "$TEST_TEMP/project"
  assert_success
  run docker_calls
  assert_output --partial "docker stop $cname"
  assert_output --partial "docker rm $cname"
}

@test "rm: no-op when no container exists" {
  mkdir -p "$TEST_TEMP/project"
  run cmd_rm "$TEST_TEMP/project"
  assert_success
  assert_output --partial "No container to remove"
}

# ── shell ───────────────────────────────────────────────────────────────────

@test "shell: requires running container" {
  mkdir -p "$TEST_TEMP/project"
  run cmd_shell "$TEST_TEMP/project"
  assert_failure
  assert_output --partial "not running"
}

@test "shell: execs bash as coder with HOME set" {
  mkdir -p "$TEST_TEMP/project"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"
  mock_docker_ps "$cname"

  run cmd_shell "$TEST_TEMP/project"
  assert_success
  run assert_docker_exec_has "--user coder"
  assert_success
  run assert_docker_exec_has "HOME=/home/coder"
  assert_success
  run assert_docker_exec_has "bash"
  assert_success
}

# ── login ───────────────────────────────────────────────────────────────────

@test "login: requires running container" {
  mkdir -p "$TEST_TEMP/project"
  run cmd_login "$TEST_TEMP/project"
  assert_failure
  assert_output --partial "not running"
}

@test "login: runs claude login as coder with full PATH" {
  mkdir -p "$TEST_TEMP/project"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"
  mock_docker_ps "$cname"

  run cmd_login "$TEST_TEMP/project"
  assert_success
  run assert_docker_exec_has "claude login"
  assert_success
  run assert_docker_exec_has "--user coder"
  assert_success
  run assert_docker_exec_has ".local/bin"
  assert_success
}

# ── logs ────────────────────────────────────────────────────────────────────

@test "logs: requires running container" {
  mkdir -p "$TEST_TEMP/project"
  run cmd_logs "$TEST_TEMP/project"
  assert_failure
}

@test "logs: follows container logs" {
  mkdir -p "$TEST_TEMP/project"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"
  mock_docker_ps "$cname"
  run cmd_logs "$TEST_TEMP/project"
  run docker_calls
  assert_output --partial "docker logs -f $cname"
}

# ── claude ──────────────────────────────────────────────────────────────────

@test "claude: requires running container" {
  mkdir -p "$TEST_TEMP/project"
  run cmd_claude "$TEST_TEMP/project"
  assert_failure
}

@test "claude: launches with --dangerously-skip-permissions" {
  mkdir -p "$TEST_TEMP/project"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"
  mock_docker_ps "$cname"
  run cmd_claude "$TEST_TEMP/project"
  run assert_docker_exec_has "--dangerously-skip-permissions"
  assert_success
}

# ── stop-all / clean ───────────────────────────────────────────────────────

@test "stop-all: stops and removes all cleat containers" {
  mock_docker_ps_a $'cleat-a-111\ncleat-b-222'
  run cmd_stop_all
  assert_success
  run docker_calls
  assert_output --partial "docker stop cleat-a-111"
  assert_output --partial "docker rm cleat-a-111"
}

@test "clean: removes image" {
  mock_docker_images "cleat"
  run cmd_clean
  assert_output --partial "Image removed"
}

# ── status ──────────────────────────────────────────────────────────────────

@test "status: shows not-created when no container" {
  mkdir -p "$TEST_TEMP/project"
  run cmd_status "$TEST_TEMP/project"
  assert_output --partial "not created"
}

@test "status: shows stopped when container exists but not running" {
  mkdir -p "$TEST_TEMP/project"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"
  # Explicitly: container exists but is NOT running
  is_running() { return 1; }
  mock_docker_ps_a "$cname"
  run cmd_status "$TEST_TEMP/project"
  assert_output --partial "stopped"
}

@test "status: shows running when container is up" {
  mkdir -p "$TEST_TEMP/project"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"
  mock_docker_ps "$cname"
  mock_docker_ps_a "$cname"
  run cmd_status "$TEST_TEMP/project"
  assert_output --partial "running"
}

# ── ps / help ───────────────────────────────────────────────────────────────

@test "ps: shows empty message" {
  run cmd_ps
  assert_output --partial "No containers found"
}

@test "help: shows all sections" {
  run cmd_help
  assert_output --partial "Run anything. Break nothing."
  assert_output --partial "QUICK START"
  assert_output --partial "LIFECYCLE"
}

# ── install / uninstall ─────────────────────────────────────────────────────

@test "install/uninstall: creates and removes symlink" {
  local target="$TEST_TEMP/bin"
  mkdir -p "$target"
  ln -sf "$CLI" "$target/cleat"
  run test -L "$target/cleat"
  assert_success
  rm "$target/cleat"
  run test -L "$target/cleat"
  assert_failure
}
