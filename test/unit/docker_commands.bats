#!/usr/bin/env bats
load "../setup"
setup() {
  _common_setup
  use_docker_stub
  source_cli
  _host_clip_cmd() { echo ""; }
  check_for_update() { true; }
  check_drift() { true; }
  _resolve_config_drift() { true; }
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

@test "build: skips network pull when registry image is already cached locally" {
  # Registry-tagged image present on disk, but no `cleat` alias yet, mimics
  # a host where the prebuilt image exists (manual pull, leftover from prior
  # nuke, etc.) but cleat hasn't aliased it. The pull stub fails by default
  # (DOCKER_PULL_EXIT_CODE=1), so if _do_pull tried the network it would
  # fall back to a local build.
  mock_docker_image_cached "$REGISTRY_IMAGE"

  run cmd_build
  assert_success
  assert_output --partial "Image ready"
  assert_output --partial "cached v${VERSION}"

  # No network call.
  run grep '^docker pull ' "$DOCKER_CALLS"
  assert_failure

  # No local build either: the cached image was reused.
  run docker_build_calls
  assert_output ""

  # The registry image was retagged as the local IMAGE_NAME.
  run grep '^docker tag ' "$DOCKER_CALLS"
  assert_success
  assert_output --partial "$REGISTRY_IMAGE"
  assert_output --partial "$IMAGE_NAME"
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
  # Default memory in the test env: VM size unknown via the stub → the 2g
  # floor. Swap is pinned to the same value so a runaway box OOMs inside its
  # own cgroup instead of thrashing the VM's swap (see resources.bats).
  run assert_docker_run_has "$cname" "--memory 2g"
  assert_success
  run assert_docker_run_has "$cname" "--memory-swap 2g"
  assert_success
  run assert_docker_run_has "$cname" "--pids-limit 4096"
  assert_success
  # --init is asserted by its regression test in regressions.bats (one test
  # per behavior, rule 3).
  run assert_docker_run_has "$cname" "-it"
  assert_success
}

@test "run: BROWSER shim is passed before user env so a .cleat BROWSER wins" {
  # The shim BROWSER default must sit BEFORE the user's [env] args on the docker
  # run line: docker's last -e wins, so a user's .cleat BROWSER= overrides the
  # shim only if the shim comes first. This pins the ordering the comment relies
  # on (assert_docker_run_has is substring-only and cannot see position).
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project"
  printf '[caps]\nenv\n'             > "$TEST_TEMP/project/.cleat"
  printf 'BROWSER=/custom/browser\n' > "$TEST_TEMP/project/.cleat.env"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"

  run cmd_run "$TEST_TEMP/project"
  assert_success
  local line before_shim before_user
  line="$(grep 'docker run' "$DOCKER_CALLS" | head -1)"
  [[ "$line" == *"BROWSER=/usr/local/bin/open-bridge"* ]] || { echo "shim BROWSER absent"; return 1; }
  [[ "$line" == *"BROWSER=/custom/browser"* ]] || { echo "user BROWSER absent"; return 1; }
  before_shim="${line%%BROWSER=/usr/local/bin/open-bridge*}"
  before_user="${line%%BROWSER=/custom/browser*}"
  [ "${#before_shim}" -lt "${#before_user}" ] || { echo "shim BROWSER not before user BROWSER; the .cleat override would lose"; return 1; }
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

  rm -rf "$CLEAT_RUN_DIR/${cname}/settings" "$CLEAT_RUN_DIR/${cname}/hooks"
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

  rm -rf "$CLEAT_RUN_DIR/${cname}/settings" "$CLEAT_RUN_DIR/${cname}/hooks"
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
  rm -rf "$CLEAT_RUN_DIR/${cname_a}/settings" "$CLEAT_RUN_DIR/${cname_b}/settings"
  rm -rf "$CLEAT_RUN_DIR/${cname_a}/hooks" "$CLEAT_RUN_DIR/${cname_b}/hooks"
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
  rm -rf "$CLEAT_RUN_DIR/${cname}/settings" "$CLEAT_RUN_DIR/${cname}/hooks"
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
  rm -rf "$CLEAT_RUN_DIR/${c1}/settings" "$CLEAT_RUN_DIR/${c2}/settings"
  rm -rf "$CLEAT_RUN_DIR/${c1}/hooks" "$CLEAT_RUN_DIR/${c2}/hooks"
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

  rm -rf "$CLEAT_RUN_DIR/${cname}/settings" "$CLEAT_RUN_DIR/${cname}/hooks"
}

@test "run: session key basename is case-normalized" {
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/MyProject"

  run cmd_run "$TEST_TEMP/MyProject"
  assert_success

  # The session key basename must be lowercased (macOS HFS+ safety).
  # On case-sensitive FS, /MyProject and /myproject are different dirs
  # and get different hashes, but the basename portion is always lowercase.
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
  rm -rf "$CLEAT_RUN_DIR/${cname}/settings" "$CLEAT_RUN_DIR/${cname}/hooks"
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

  rm -rf "$CLEAT_RUN_DIR/${cname}/settings" "$CLEAT_RUN_DIR/${cname}/hooks"
}

@test "run: cmd_rm preserves the per-project .claude.json store (approvals survive recreate)" {
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project"
  echo '{"oauthAccount":{"emailAddress":"a@b.com"}}' > "${HOME}/.claude.json"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"

  local _basename _hash key store
  _basename="$(basename "$TEST_TEMP/project" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g')"
  _hash="$(echo -n "$TEST_TEMP/project" | _md5 | head -c 8)"
  key="${_basename}-${_hash}"
  store="$CLEAT_PROJECTS_DIR/${key}/claude.json"

  run cmd_run "$TEST_TEMP/project"
  assert_success
  [[ -f "$store" ]] || { echo "store not created at $store"; return 1; }

  # Simulate Claude having recorded a per-project approval into the store.
  local with_approval
  with_approval="$(jq '.projects["/workspace"].hasTrustDialogAccepted = true' "$store")"
  echo "$with_approval" > "$store"

  mock_docker_ps "$cname"
  run cmd_rm "$TEST_TEMP/project"
  assert_success

  # The store (and the approval in it) must survive cleat rm.
  [[ -f "$store" ]] || { echo "REGRESSION: cmd_rm deleted the per-project store"; return 1; }
  run jq -r '.projects["/workspace"].hasTrustDialogAccepted' "$store"
  assert_output "true"
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

@test "run: mounts an isolated per-project .claude.json, never the shared host file" {
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project"
  echo '{"oauthAccount":{"emailAddress":"a@b.com"}}' > "${HOME}/.claude.json"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"

  run cmd_run "$TEST_TEMP/project"

  # The container always gets a .claude.json mounted onto the canonical path…
  run assert_docker_run_has "$cname" ":/home/coder/.claude.json"
  assert_success
  # …but the SOURCE must be the per-project store, never the shared host file.
  run assert_docker_run_has "$cname" "$HOME/.config/cleat/projects/"
  assert_success
  run assert_docker_run_lacks "$cname" "$HOME/.claude.json:/home/coder/.claude.json"
  assert_success
}

@test "run: mounts an isolated .claude.json even with no host file (fresh machine)" {
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project"
  rm -f "${HOME}/.claude.json"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"

  run cmd_run "$TEST_TEMP/project"
  run assert_docker_run_has "$cname" ":/home/coder/.claude.json"
  assert_success
}

@test "run: .claude.json bind source exists at docker-run time under strict stub (virtiofs safety)" {
  # macOS Docker Desktop (virtiofs) requires a bind-mount SOURCE to exist as a
  # real file before docker run, or it silently creates a directory and the
  # file→file mount fails with an opaque OCI error. The strict stub rejects any
  # -v whose source is missing, so a clean cmd_run proves every source (incl.
  # the per-project .claude.json) was materialized first. Test the fresh-machine
  # case (no host file) since that's where the old code mounted nothing at all.
  export DOCKER_STUB_STRICT=1
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project"
  rm -f "${HOME}/.claude.json"

  run cmd_run "$TEST_TEMP/project"
  assert_success
  refute_output --partial "bind source path does not exist"
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
  # v0.13.1: must wait for the entrypoint UID remap before exec, so the shell
  # never opens as the stale image uid (same race as the session launch).
  run assert_docker_exec_has "id -u coder"
  assert_success
  run assert_docker_exec_has "runuser -u coder"
  assert_success
  run assert_docker_exec_has "HOME=/home/coder"
  assert_success
  run assert_docker_exec_has "PATH="
  assert_success
  run assert_docker_exec_has "bash"
  assert_success
  # BROWSER must ride the shell exec too: an in-shell `claude /login` on a box
  # created before v1.1.1 (frozen Config.Env, no BROWSER) otherwise drops to
  # the code-paste flow. Pinned per exec site: a refactor that swaps
  # CLAUDE_ENV for hand-built -e entries here would keep every other
  # assertion green while silently losing this.
  run assert_docker_exec_has "BROWSER=/usr/local/bin/open-bridge"
  assert_success
}

@test "shell: starts a browser watcher so in-shell logins reach the host" {
  # $BROWSER in the box points at the open shim, so `claude /login` run from a
  # cleat shell emits its URL through the bridge file. Without a watcher the
  # URL goes nowhere and a loopback login waits forever on its callback.
  mkdir -p "$TEST_TEMP/project"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"
  mock_docker_ps "$cname"
  _host_open_cmd() { echo "fake-open"; }
  _browser_watcher() { printf '%s %s %s %s %s' "$1" "$2" "$3" "$4" "$5" > "$TEST_TEMP/bw_args"; }

  run cmd_shell "$TEST_TEMP/project"
  assert_success
  [ -f "$TEST_TEMP/bw_args" ] || { echo "cmd_shell started no browser watcher; an in-shell login has no bridge"; return 1; }
  run cat "$TEST_TEMP/bw_args"
  assert_output --partial "$cname"
  assert_output --partial "auto"
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
  # v0.13.1: must wait for the UID remap before exec, so `claude login` never
  # runs as the stale image uid and writes auth that the real uid can't own.
  run assert_docker_exec_has "id -u coder"
  assert_success
  run assert_docker_exec_has "claude login"
  assert_success
  run assert_docker_exec_has "runuser -u coder"
  assert_success
  run assert_docker_exec_has ".local/bin"
  assert_success
  # BROWSER must ride the login exec: `cleat login` is the primary login path
  # for a box created before v1.1.1 (frozen Config.Env, no BROWSER), and
  # without it claude 2.1.191+ never fires the open shim. Pinned per exec
  # site, same rationale as the shell test above.
  run assert_docker_exec_has "BROWSER=/usr/local/bin/open-bridge"
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

@test "status: overcommit line names the VM on a VM-backed engine" {
  mkdir -p "$TEST_TEMP/project"
  _docker_vm_memory() { echo "8589934592"; }             # 8 GiB pool
  _running_memory_limits_sum() { echo "42949672960"; }   # 40 GiB of ceilings
  _docker_pool_is_vm() { return 0; }
  run cmd_status "$TEST_TEMP/project"
  assert_output --partial "VM memory:"
  assert_output --partial "reserve 40 GB of ceilings on a 8 GB VM"
}

@test "status: overcommit line names the host on a native engine (no VM exists)" {
  mkdir -p "$TEST_TEMP/project"
  _docker_vm_memory() { echo "8589934592"; }
  _running_memory_limits_sum() { echo "42949672960"; }
  _docker_pool_is_vm() { return 1; }                     # native Linux engine
  run cmd_status "$TEST_TEMP/project"
  assert_output --partial "Host memory:"
  assert_output --partial "reserve 40 GB of ceilings on a 8 GB host"
  refute_output --partial "GB VM"
}

# ── ps / help ───────────────────────────────────────────────────────────────

@test "ps: shows empty message" {
  run cmd_ps
  assert_output --partial "No containers found"
}

@test "ps: an Exited (255) box gets the Docker-restarted resume hint" {
  # Exit 255 is the Docker-restart signature (the VM died under the box):
  # without the hint a healthy, resumable box reads as a crash.
  printf 'cleat-proj-12345678\tExited (255) 2 hours ago\n' > "$DOCKER_MOCK_DIR/ps_a_output"
  run cmd_ps
  assert_success
  assert_output --partial "Docker restarted; resume with: cleat resume"
}

@test "ps: a normally-exited box gets no restart hint" {
  printf 'cleat-proj-12345678\tExited (0) 2 hours ago\n' > "$DOCKER_MOCK_DIR/ps_a_output"
  run cmd_ps
  assert_success
  refute_output --partial "Docker restarted"
}

@test "help: shows all sections" {
  run cmd_help
  assert_output --partial "Give the agent a cage, not your keys."
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
