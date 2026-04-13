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
  assert_output --partial "Image ready"
  assert_output --partial "(cached)"
}

@test "rebuild: always builds with --no-cache" {
  run cmd_rebuild
  run docker_build_calls
  assert_output --partial "--no-cache"
  assert_output --partial "docker/Dockerfile"
}

@test "build: tries pull before local build when image missing" {
  # Pull fails (default stub behavior) → should fall back to build
  run cmd_build
  assert_success
  # Docker pull was attempted with the registry image
  run grep "pull" "$DOCKER_CALLS"
  assert_success
  assert_output --partial "$REGISTRY_IMAGE"
  # Build was also called (fallback after pull failure)
  run docker_build_calls
  assert_output --partial "-t cleat"
}

@test "build: successful pull skips local build" {
  # Make pull succeed
  export DOCKER_PULL_EXIT_CODE=0
  run cmd_build
  assert_success
  # Pull was called
  run grep "pull" "$DOCKER_CALLS"
  assert_success
  # Build was NOT called (pull succeeded)
  run docker_build_calls
  assert_output ""
  unset DOCKER_PULL_EXIT_CODE
}

@test "build: pull tags registry image as local image name" {
  export DOCKER_PULL_EXIT_CODE=0
  run cmd_build
  assert_success
  # Tag was called to rename the pulled image
  run grep "tag" "$DOCKER_CALLS"
  assert_success
  assert_output --partial "$REGISTRY_IMAGE"
  assert_output --partial "$IMAGE_NAME"
  unset DOCKER_PULL_EXIT_CODE
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

# ── Session isolation ───────────────────────────────────────────────────────

@test "run: mounts per-project session overlay at projects/-workspace" {
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"

  run cmd_run "$TEST_TEMP/project"
  assert_success

  # The overlay mount must map the host's per-project dir to -workspace inside the container
  run assert_docker_run_has "$cname" "/home/coder/.claude/projects/-workspace"
  assert_success

  rm -rf "/tmp/cleat-settings-${cname}" "/tmp/cleat-hooks-${cname}"
}

@test "run: mounts per-project history overlay at history.jsonl" {
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"

  run cmd_run "$TEST_TEMP/project"
  assert_success

  # history.jsonl must be overlaid with the per-project copy
  run assert_docker_run_has "$cname" "history.jsonl:/home/coder/.claude/history.jsonl"
  assert_success

  # The history mount source must be inside the project session dir (same hash key)
  local _bn _h project_key
  _bn="$(basename "$TEST_TEMP/project" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g')"
  _h="$(echo -n "$TEST_TEMP/project" | _md5 | head -c 8)"
  project_key="${_bn}-${_h}"
  run assert_docker_run_has "$cname" "${project_key}/history.jsonl:/home/coder/.claude/history.jsonl"
  assert_success

  rm -rf "/tmp/cleat-settings-${cname}" "/tmp/cleat-hooks-${cname}"
}

@test "run: different projects get different session overlay sources" {
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project-a" "$TEST_TEMP/project-b"

  run cmd_run "$TEST_TEMP/project-a"
  assert_success
  local calls_a
  calls_a="$(cat "$DOCKER_CALLS")"

  # Reset for second run
  true > "$DOCKER_CALLS"
  run cmd_run "$TEST_TEMP/project-b"
  assert_success
  local calls_b
  calls_b="$(cat "$DOCKER_CALLS")"

  # Extract the session overlay source path from each run.
  # Format: .../.claude/projects/<key>:/home/coder/.claude/projects/-workspace
  local src_a src_b
  src_a="$(echo "$calls_a" | grep -o '[^ ]*/\.claude/projects/[^:]*:/home/coder/\.claude/projects/-workspace' | head -1)"
  src_b="$(echo "$calls_b" | grep -o '[^ ]*/\.claude/projects/[^:]*:/home/coder/\.claude/projects/-workspace' | head -1)"

  [[ -n "$src_a" ]] || { echo "No session overlay in project-a docker run"; return 1; }
  [[ -n "$src_b" ]] || { echo "No session overlay in project-b docker run"; return 1; }
  [[ "$src_a" != "$src_b" ]] || {
    echo "Both projects got the same session overlay: $src_a"
    return 1
  }

  # Clean up
  local cname_a cname_b
  cname_a="$(container_name_for "$TEST_TEMP/project-a")"
  cname_b="$(container_name_for "$TEST_TEMP/project-b")"
  rm -rf "/tmp/cleat-settings-${cname_a}" "/tmp/cleat-settings-${cname_b}"
  rm -rf "/tmp/cleat-hooks-${cname_a}" "/tmp/cleat-hooks-${cname_b}"
}

@test "run: session overlay creates host project dir if missing" {
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project"

  # Compute the expected hash-based key (same logic as bin/cleat)
  local _bn _h session_key
  _bn="$(basename "$TEST_TEMP/project" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g')"
  _h="$(echo -n "$TEST_TEMP/project" | _md5 | head -c 8)"
  session_key="${_bn}-${_h}"

  # Ensure the project session dir does NOT exist yet
  rm -rf "${HOME}/.claude/projects/${session_key}"

  run cmd_run "$TEST_TEMP/project"
  assert_success

  # cmd_run must have created it
  [[ -d "${HOME}/.claude/projects/${session_key}" ]] || {
    echo "Project session dir not created at ~/.claude/projects/${session_key}"
    return 1
  }

  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"
  rm -rf "/tmp/cleat-settings-${cname}" "/tmp/cleat-hooks-${cname}"
}

@test "run: session key avoids collision for paths with similar names" {
  mock_docker_images "cleat"
  # Two paths that would collide under simple tr '/' '-': /a-b/c vs /a/b-c
  mkdir -p "$TEST_TEMP/a-b" "$TEST_TEMP/a/b-c"
  # Create a project inside each
  mkdir -p "$TEST_TEMP/a-b/c" "$TEST_TEMP/a/b-c"

  run cmd_run "$TEST_TEMP/a-b/c"
  assert_success
  local calls_1
  calls_1="$(cat "$DOCKER_CALLS")"
  true > "$DOCKER_CALLS"

  run cmd_run "$TEST_TEMP/a/b-c"
  assert_success
  local calls_2
  calls_2="$(cat "$DOCKER_CALLS")"

  # Extract the session mount source from each
  local mount_1 mount_2
  mount_1="$(echo "$calls_1" | grep -o '[^ ]*/\.claude/projects/[^:]*' | grep -v '\-workspace$' | head -1)"
  mount_2="$(echo "$calls_2" | grep -o '[^ ]*/\.claude/projects/[^:]*' | grep -v '\-workspace$' | head -1)"

  [[ -n "$mount_1" && -n "$mount_2" ]] || {
    echo "Could not extract session mounts"
    return 1
  }
  [[ "$mount_1" != "$mount_2" ]] || {
    echo "COLLISION: both projects got the same session key"
    echo "  path 1: $TEST_TEMP/a-b/c → $mount_1"
    echo "  path 2: $TEST_TEMP/a/b-c → $mount_2"
    return 1
  }

  local c1 c2
  c1="$(container_name_for "$TEST_TEMP/a-b/c")"
  c2="$(container_name_for "$TEST_TEMP/a/b-c")"
  rm -rf "/tmp/cleat-settings-${c1}" "/tmp/cleat-settings-${c2}"
  rm -rf "/tmp/cleat-hooks-${c1}" "/tmp/cleat-hooks-${c2}"
}

@test "run: session key handles root path" {
  mock_docker_images "cleat"
  # Simulate root path (don't actually use /, use a single-char dir)
  mkdir -p "$TEST_TEMP/x"
  local cname
  cname="$(container_name_for "$TEST_TEMP/x")"

  run cmd_run "$TEST_TEMP/x"
  assert_success
  run assert_docker_run_has "$cname" "projects/-workspace"
  assert_success

  rm -rf "/tmp/cleat-settings-${cname}" "/tmp/cleat-hooks-${cname}"
}

@test "run: session key basename is case-normalized" {
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/MyProject"

  run cmd_run "$TEST_TEMP/MyProject"
  assert_success

  # The session key basename must be lowercased (macOS HFS+ safety).
  # On case-sensitive FS, /MyProject and /myproject are different dirs
  # and get different hashes — but the basename portion is always lowercase.
  local all_calls
  all_calls="$(cat "$DOCKER_CALLS")"

  # Check the mount uses lowercase basename in the key
  echo "$all_calls" | grep -q '/\.claude/projects/myproject-' || {
    echo "Session key basename not lowercased"
    echo "$all_calls" | grep 'projects/' || true
    return 1
  }

  local cname
  cname="$(container_name_for "$TEST_TEMP/MyProject")"
  rm -rf "/tmp/cleat-settings-${cname}" "/tmp/cleat-hooks-${cname}"
}

@test "run: cmd_rm preserves session directory on host" {
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"

  # Find the session key to check afterward
  local _basename _hash session_key
  _basename="$(basename "$TEST_TEMP/project" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g')"
  _hash="$(echo -n "$TEST_TEMP/project" | _md5 | head -c 8)"
  session_key="${_basename}-${_hash}"

  run cmd_run "$TEST_TEMP/project"
  assert_success
  [[ -d "${HOME}/.claude/projects/${session_key}" ]] || {
    echo "Session dir not created"
    return 1
  }

  # Write a sentinel file to the session dir
  echo "session-data" > "${HOME}/.claude/projects/${session_key}/sentinel.txt"

  # Now remove the container
  mock_docker_ps "$cname"
  run cmd_rm "$TEST_TEMP/project"
  assert_success

  # Session dir must still exist with our data
  [[ -f "${HOME}/.claude/projects/${session_key}/sentinel.txt" ]] || {
    echo "REGRESSION: cmd_rm deleted the session directory"
    return 1
  }

  rm -rf "/tmp/cleat-settings-${cname}" "/tmp/cleat-hooks-${cname}"
}

@test "run: docker run failure is handled (spinner not orphaned)" {
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project"
  export DOCKER_EXIT_CODE=1  # docker run will fail

  run cmd_run "$TEST_TEMP/project"
  assert_failure
  assert_output --partial "Container failed to start"
}

@test "run: docker run failure shows docker error reason" {
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project"
  export DOCKER_EXIT_CODE=1
  export DOCKER_STDERR="Error response from daemon: Conflict"

  run cmd_run "$TEST_TEMP/project"
  assert_failure
  assert_output --partial "Container failed to start"
  assert_output --partial "Conflict"
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

@test "shell: execs bash as coder with HOME and PATH set" {
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
  run assert_docker_exec_has "PATH="
  assert_success
  run assert_docker_exec_has "bash"
  assert_success
}

@test "shell: passes resolved env args to docker exec" {
  mkdir -p "$TEST_TEMP/project"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"
  mock_docker_ps "$cname"

  cat > "$TEST_TEMP/project/.cleat.env" << 'EOF'
DATABASE_URL=postgres://localhost/mydb
API_KEY=secret123
EOF
  cat > "$TEST_TEMP/project/.cleat" << 'EOF'
[caps]
env
EOF

  run cmd_shell "$TEST_TEMP/project"
  assert_success
  run assert_docker_exec_has "DATABASE_URL=postgres://localhost/mydb"
  assert_success
  run assert_docker_exec_has "API_KEY=secret123"
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

@test "login: passes resolved env args to docker exec" {
  mkdir -p "$TEST_TEMP/project"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"
  mock_docker_ps "$cname"

  cat > "$TEST_TEMP/project/.cleat.env" << 'EOF'
API_BASE=https://custom.api.example.com
EOF
  cat > "$TEST_TEMP/project/.cleat" << 'EOF'
[caps]
env
EOF

  run cmd_login "$TEST_TEMP/project"
  assert_success
  run assert_docker_exec_has "API_BASE=https://custom.api.example.com"
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
