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

# _do_build now refuses when $REPO_DIR/docker is missing, which is the real
# state of a Homebrew keg on macOS before 12.3. A sourced test gets a REPO_DIR
# derived from the temp copy of the script, so tests that mean to reach the
# BUILD need a context planted first, the way a git install has one.
_with_build_context() {
  REPO_DIR="$TEST_TEMP/repo"
  mkdir -p "$REPO_DIR/docker"
  : > "$REPO_DIR/docker/Dockerfile"
}

@test "build: creates image when none exists" {
  _with_build_context
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
  _with_build_context
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
  _with_build_context
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
  assert_output --partial "Sessions preserved"
  # The teachable disk note: the box layer is freed but the image + cache remain.
  assert_output --partial "cleat storage"
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

@test "login: execs claude as coder with full PATH" {
  mkdir -p "$TEST_TEMP/project"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"
  mock_docker_ps "$cname"

  run cmd_login "$TEST_TEMP/project"
  assert_success
  # v0.13.1: must wait for the UID remap before exec, so the login never runs
  # as the stale image uid and writes auth that the real uid can't own. The
  # exact subcommand is pinned by the v1.4.3 regression test.
  run assert_docker_exec_has "id -u coder"
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

@test "status: flags a second cleat install shadowing this one" {
  # Two installs is a state you cannot see from the inside: a bare `cleat`
  # silently resolves to whichever comes first on PATH.
  mkdir -p "$TEST_TEMP/project"
  _find_cleat_installs() {
    printf '%s\t%s\n' "/opt/homebrew/bin/cleat" "/opt/homebrew/Cellar/cleat/1.4.0/libexec/bin/cleat"
    printf '%s\t%s\n' "$HOME/.local/bin/cleat" "$HOME/.cleat/bin/cleat"
  }
  run cmd_status "$TEST_TEMP/project"
  assert_output --partial "2 installs found"
  assert_output --partial "/opt/homebrew/bin/cleat"
  assert_output --partial "Homebrew"
  assert_output --partial "$HOME/.local/bin/cleat"
  assert_output --partial "git"
}

@test "status: says nothing about installs when there is only one" {
  # This is a warning, not a stat: a healthy machine prints no Install line.
  mkdir -p "$TEST_TEMP/project"
  _find_cleat_installs() { printf '%s\t%s\n' "/usr/local/bin/cleat" "$HOME/.cleat/bin/cleat"; }
  run cmd_status "$TEST_TEMP/project"
  assert_success
  refute_output --partial "installs found"
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

@test "status: a box positional is a BOX, not a phantom project" {
  # The dispatch forwarded the positional into cmd_status's project slot, so
  # `cleat status feat-a` resolved a project literally named "feat-a" and
  # printed a confident, entirely phantom project line.
  cd "$TEST_TEMP"
  local here="$PWD"
  run main status feat-a
  assert_success
  # Checked on the Project LINE with colours stripped: the raw output carries
  # ANSI resets between the label and the value, so a --partial on the rendered
  # string silently never matches and the test cannot fail.
  local line
  line="$(printf '%s\n' "$output" | sed 's/\x1b\[[0-9;]*m//g' | grep 'Project:' | head -1)"
  [[ "$line" == *"$here"* ]] \
    || { echo "status reported a phantom project: $line"; return 1; }
}

@test "status: an invalid box positional is refused, not treated as a path" {
  cd "$TEST_TEMP"
  run main status "Bad Name"
  assert_failure
  assert_output --partial "Invalid box name"
}

# ── Local build needs a docker context, which a packaged install may not have ──

@test "build: refuses with an actionable message when there is no docker context" {
  # On macOS before 12.3 `readlink -f` does not resolve the invoking symlink,
  # so REPO_DIR falls back to the symlink's parent, which for a Homebrew keg is
  # the PREFIX rather than the keg. This path is reached at SESSION START, not
  # just from `cleat rebuild`, because every image acquisition is
  # `_do_pull || _do_build`, so a raw docker error about a context that does not
  # exist would be the first thing a brew user sees when a pull fails.
  REPO_DIR="$TEST_TEMP/no-context"
  mkdir -p "$REPO_DIR"
  _is_brew_managed() { return 1; }

  run _do_build
  assert_failure
  assert_output --partial "No local build context"
  assert_output --partial "cleat build"
  # And it never reaches docker with a bogus context.
  run cat "$DOCKER_CALLS"
  refute_output --partial "build"
}

@test "build: points a keg at brew reinstall, a git install at neither" {
  REPO_DIR="$TEST_TEMP/no-context"
  mkdir -p "$REPO_DIR"
  _is_brew_managed() { return 0; }

  run _do_build
  assert_failure
  assert_output --partial "brew reinstall cleatdev/tap/cleat"
}

@test "build: still builds normally when the context is there" {
  # Control: the guard must not block the ordinary git install.
  _with_build_context

  run _do_build
  refute_output --partial "No local build context"
}

# ── shell / login teardown: the bridge file sweep ────────────────────────────
# Both verbs sweep .browser-open on exit through the same helper the session
# uses: age-gated only while a sibling session is alive, unconditional when
# nobody is left to claim it.

@test "shell: teardown keeps a FRESH pending login URL while a sibling session is alive" {
  mkdir -p "$TEST_TEMP/project"
  local cname; cname="$(container_name_for "$TEST_TEMP/project")"
  mock_docker_ps "$cname"
  local clip="$CLEAT_RUN_DIR/$cname/clip"; mkdir -p "$clip"
  printf '%s' "https://claude.ai/oauth?redirect_uri=x" > "$clip/.browser-open"
  # FRESH means "written in the last five seconds", measured in WALL CLOCK, and
  # everything cmd_shell/cmd_login does before the teardown counts against it.
  # On a loaded machine that window closes mid-test and the file is swept as
  # stale, which is what this test would then report as a swallowed login URL.
  # Pin the age instead of racing it: the behaviour under test is the sibling
  # check, not the clock.
  _path_mtime() { date +%s; }
  # And stub the watcher. It polls every 0.5s and CLAIMS the bridge file, which
  # consumes it, so under load a real one wins the race against teardown and the
  # test reports a swallowed URL that the teardown never touched. It has to stay
  # alive, because teardown kills the pid it recorded.
  _browser_watcher() { sleep 30; }
  sleep 30 &
  local sib=$!
  touch "$clip/.watcher.$sib"
  run cmd_shell "$TEST_TEMP/project"
  kill "$sib" 2>/dev/null || true; wait "$sib" 2>/dev/null || true
  assert_success
  [ -f "$clip/.browser-open" ] || { echo "shell teardown swallowed a sibling's pending login URL"; return 1; }
}

@test "shell: teardown removes a fresh bridge file when no session is alive" {
  mkdir -p "$TEST_TEMP/project"
  local cname; cname="$(container_name_for "$TEST_TEMP/project")"
  mock_docker_ps "$cname"
  local clip="$CLEAT_RUN_DIR/$cname/clip"; mkdir -p "$clip"
  printf '%s' "https://claude.ai/oauth?redirect_uri=x" > "$clip/.browser-open"
  run cmd_shell "$TEST_TEMP/project"
  assert_success
  [ ! -e "$clip/.browser-open" ] || { echo "a solo shell left a URL for the next session to open"; return 1; }
}

@test "login: teardown keeps a FRESH pending login URL while a sibling session is alive" {
  mkdir -p "$TEST_TEMP/project"
  local cname; cname="$(container_name_for "$TEST_TEMP/project")"
  mock_docker_ps "$cname"
  local clip="$CLEAT_RUN_DIR/$cname/clip"; mkdir -p "$clip"
  printf '%s' "https://claude.ai/oauth?redirect_uri=x" > "$clip/.browser-open"
  # FRESH means "written in the last five seconds", measured in WALL CLOCK, and
  # everything cmd_shell/cmd_login does before the teardown counts against it.
  # On a loaded machine that window closes mid-test and the file is swept as
  # stale, which is what this test would then report as a swallowed login URL.
  # Pin the age instead of racing it: the behaviour under test is the sibling
  # check, not the clock.
  _path_mtime() { date +%s; }
  # And stub the watcher. It polls every 0.5s and CLAIMS the bridge file, which
  # consumes it, so under load a real one wins the race against teardown and the
  # test reports a swallowed URL that the teardown never touched. It has to stay
  # alive, because teardown kills the pid it recorded.
  _browser_watcher() { sleep 30; }
  sleep 30 &
  local sib=$!
  touch "$clip/.watcher.$sib"
  run cmd_login "$TEST_TEMP/project"
  kill "$sib" 2>/dev/null || true; wait "$sib" 2>/dev/null || true
  assert_success
  [ -f "$clip/.browser-open" ] || { echo "login teardown swallowed a sibling's pending login URL"; return 1; }
}

@test "login: teardown removes a fresh bridge file when no session is alive" {
  mkdir -p "$TEST_TEMP/project"
  local cname; cname="$(container_name_for "$TEST_TEMP/project")"
  mock_docker_ps "$cname"
  local clip="$CLEAT_RUN_DIR/$cname/clip"; mkdir -p "$clip"
  printf '%s' "https://claude.ai/oauth?redirect_uri=x" > "$clip/.browser-open"
  run cmd_login "$TEST_TEMP/project"
  assert_success
  [ ! -e "$clip/.browser-open" ] || { echo "a solo login left a URL for the next session to open"; return 1; }
}

@test "shell: caps an oversized watcher log before spawning its browser watcher" {
  mkdir -p "$TEST_TEMP/project"
  local cname; cname="$(container_name_for "$TEST_TEMP/project")"
  mock_docker_ps "$cname"
  _host_open_cmd() { echo "true"; }
  local clip="$CLEAT_RUN_DIR/$cname/clip"; mkdir -p "$clip"
  head -c 1200000 /dev/zero | tr '\0' 'x' > "$clip/.watcher-log"
  run cmd_shell "$TEST_TEMP/project"
  assert_success
  local sz; sz="$(wc -c < "$clip/.watcher-log" | tr -d '[:space:]')"
  [ "$sz" -lt 1048576 ] || { echo "cleat shell never capped the watcher log: $sz bytes"; return 1; }
}

@test "login: caps an oversized watcher log before spawning its browser watcher" {
  mkdir -p "$TEST_TEMP/project"
  local cname; cname="$(container_name_for "$TEST_TEMP/project")"
  mock_docker_ps "$cname"
  _host_open_cmd() { echo "true"; }
  local clip="$CLEAT_RUN_DIR/$cname/clip"; mkdir -p "$clip"
  head -c 1200000 /dev/zero | tr '\0' 'x' > "$clip/.watcher-log"
  run cmd_login "$TEST_TEMP/project"
  assert_success
  local sz; sz="$(wc -c < "$clip/.watcher-log" | tr -d '[:space:]')"
  [ "$sz" -lt 1048576 ] || { echo "cleat login never capped the watcher log: $sz bytes"; return 1; }
}

# ── the uid the host user IS inside a container ─────────────────────────────
#
# Cleat tells the box which uid to run as so the agent's files come back owned
# by the person who started it. A user-namespaced engine (rootless Docker,
# Docker Desktop for Linux) maps the host user to container uid 0 and the host's
# subuids to 1, 2, 3..., so the host's own number picks a subuid there instead
# of the user. These pin the measured answer being used, not the host's number.

int_uidmap_write() {   # helper: plant a measured answer for this engine
  # The measurement is Linux-only (macOS keeps the host's own ids), so a test
  # that plants one is testing the Linux path. Say so, or the macOS shards
  # would take the gate and never read the plant.
  _is_macos() { return 1; }
  mkdir -p "$CLEAT_CONFIG_DIR/state"
  local ep; ep="$(_docker_context_endpoint)"
  printf '%s\t%s\t%s\t%s\n' "${DOCKER_HOST:-${DOCKER_CONTEXT:-default}}" \
    "${ep:--}" "$(id -u)" "$1" > "$CLEAT_CONFIG_DIR/state/uidmap"
}

@test "uid map: a namespaced engine gets the in-namespace identity, not the host's number" {
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project"
  int_uidmap_write "0 0"
  local cname; cname="$(container_name_for "$TEST_TEMP/project")"

  run cmd_run "$TEST_TEMP/project"
  assert_success
  run assert_docker_run_has "$cname" "HOST_UID=0"
  assert_success
  run assert_docker_run_has "$cname" "HOST_GID=0"
  assert_success
}

@test "uid map: an identity engine still gets the host's own ids" {
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project"
  int_uidmap_write "4242 4243"
  local cname; cname="$(container_name_for "$TEST_TEMP/project")"

  run cmd_run "$TEST_TEMP/project"
  assert_success
  run assert_docker_run_has "$cname" "HOST_UID=4242"
  assert_success
  run assert_docker_run_has "$cname" "HOST_GID=4243"
  assert_success
}

@test "uid map: a measurement for another host user is not trusted" {
  # The cache line carries the engine and the uid it was measured for. A line
  # from a different user (a shared machine, a su) must be re-measured, never
  # applied, or one user's box would run as another's mapping.
  # Well formed in every other way, so the uid field is the only thing that can
  # reject it. A malformed line would fail for the wrong reason.
  mkdir -p "$CLEAT_CONFIG_DIR/state"
  printf '%s\t-\t999999\t0 0\n' "${DOCKER_HOST:-${DOCKER_CONTEXT:-default}}" \
    > "$CLEAT_CONFIG_DIR/state/uidmap"
  run _box_identity_cached
  assert_failure
}

@test "uid map: with nothing measured it falls back to the host's own ids" {
  rm -f "$CLEAT_CONFIG_DIR/state/uidmap"
  run _box_uid
  assert_success
  assert_output "$(id -u)"
  run _box_gid
  assert_success
  assert_output "$(id -g)"
}

@test "uid map: the remap wait is satisfied by the uid the box was told to use" {
  # It compared the HOST's uid against the box's, which on a namespaced engine
  # are the same number while the mapping is wrong: a false green that hid every
  # rootless failure. The function returns 0 on every path (it is fail-open), so
  # the behaviour to pin is WHEN it stops: it must accept the box reporting 0
  # once, not poll its full 50 rounds waiting for a number that never comes.
  int_uidmap_write "0 0"
  mock_docker_inspect "HOST_UID=0"
  # The box reports the uid it was told to use. Every poll answers 0.
  local shim="$TEST_TEMP/exec-reports-zero.sh"
  cat > "$shim" <<'SH'
#!/usr/bin/env bash
echo 0
SH
  chmod +x "$shim"
  export DOCKER_STUB_EXEC_SCRIPT="$shim"
  : > "$DOCKER_CALLS"
  _wait_for_coder_remap "cleat-whatever"
  local polls
  polls="$(grep -c '^docker exec ' "$DOCKER_CALLS" || true)"
  [ "$polls" -eq 1 ] || { echo "polled $polls times, expected 1"; return 1; }
}

@test "uid map: a box created under the old mapping is told to recreate" {
  # Its uid is frozen in Config.Env and the config fingerprint ignores
  # cleat-injected env, so nothing else would ever mention it. On a namespaced
  # engine that box cannot edit the project or reach its account, and none of
  # those symptoms name the cause.
  int_uidmap_write "0 0"
  mock_docker_inspect "HOST_UID=1001"   # what the box was told at create
  local shim="$TEST_TEMP/exec-reports-old.sh"
  cat > "$shim" <<'SH'
#!/usr/bin/env bash
echo 1001
SH
  chmod +x "$shim"
  export DOCKER_STUB_EXEC_SCRIPT="$shim"
  run _wait_for_coder_remap "cleat-whatever"
  assert_success
  assert_output --partial "runs as uid 1001"
  assert_output --partial "cleat rm"
}

@test "uid map: a box on the right mapping says nothing" {
  int_uidmap_write "0 0"
  mock_docker_inspect "HOST_UID=0"      # created under the mapping now in force
  local shim="$TEST_TEMP/exec-reports-right.sh"
  cat > "$shim" <<'SH'
#!/usr/bin/env bash
echo 0
SH
  chmod +x "$shim"
  export DOCKER_STUB_EXEC_SCRIPT="$shim"
  run _wait_for_coder_remap "cleat-whatever"
  assert_success
  refute_output --partial "cleat rm"
}

@test "uid map: the measurement is taken from a container and cached" {
  # The engine is asked what uid it shows for a directory the host user owns.
  # One container, then never again: the answer is written where the source-time
  # IS_SANDBOX decision can read it without touching the daemon.
  rm -f "$CLEAT_CONFIG_DIR/state/uidmap"
  image_exists() { return 0; }
  docker() { case "$1" in run) echo "0 0" ;; *) return 0 ;; esac; }
  run _box_identity_probe
  assert_success
  assert_output "0 0"
  run _box_identity_cached
  assert_success
  assert_output "0 0"
}

@test "uid map: an unreadable measurement is refused, not guessed at" {
  # A garbled answer must never become a uid. Anything but two numbers falls
  # back to the host's own ids, which is what every non-namespaced engine wants.
  rm -f "$CLEAT_CONFIG_DIR/state/uidmap"
  image_exists() { return 0; }
  docker() { case "$1" in run) echo "Cannot connect to the Docker daemon" ;; *) return 0 ;; esac; }
  run _box_identity_probe
  assert_failure
  [ ! -f "$CLEAT_CONFIG_DIR/state/uidmap" ] || { echo "cached a garbled measurement"; return 1; }
  run _box_uid
  assert_success
  assert_output "$(id -u)"
}

@test "uid map: a box on the wrong mapping is not polled for five seconds first" {
  # Its uid is frozen at create and the entrypoint re-reads that same value on
  # every restart, so no number of polls can converge. Waiting anyway put a five
  # second stall at the front of every session before saying anything.
  int_uidmap_write "0 0"
  mock_docker_inspect "HOST_UID=1001"
  local shim="$TEST_TEMP/exec-never-converges.sh"
  cat > "$shim" <<'SH'
#!/usr/bin/env bash
echo 1001
SH
  chmod +x "$shim"
  export DOCKER_STUB_EXEC_SCRIPT="$shim"
  : > "$DOCKER_CALLS"
  run _wait_for_coder_remap "cleat-whatever"
  assert_success
  local polls
  polls="$(grep -c '^docker exec ' "$DOCKER_CALLS" || true)"
  [ "$polls" -eq 0 ] || { echo "polled $polls times, expected none"; return 1; }
  assert_output --partial "cleat rm"
}

@test "uid map: DOCKER_HOST decides the key, the way docker itself resolves it" {
  # Docker reads DOCKER_HOST first and the context second. Filing a measurement
  # the other way round names it after something that did not choose the daemon,
  # so a measurement taken against one engine gets applied to another.
  export DOCKER_HOST="unix:///run/user/1001/docker.sock"
  export DOCKER_CONTEXT="desktop-linux"
  run _uid_map_key
  assert_success
  assert_output "unix:///run/user/1001/docker.sock"
}

@test "uid map: a measurement taken against another daemon is re-measured" {
  # Same key, repointed endpoint: the number was true of a different engine.
  _is_macos() { return 1; }
  mkdir -p "$CLEAT_CONFIG_DIR/state"
  printf '%s\t%s\t%s\t%s\n' "${DOCKER_HOST:-${DOCKER_CONTEXT:-default}}" \
    "unix:///somewhere/else.sock" "$(id -u)" "0 0" > "$CLEAT_CONFIG_DIR/state/uidmap"
  image_exists() { return 0; }
  docker() { case "$1" in run) echo "4242 4243" ;; *) return 0 ;; esac; }
  run _box_identity
  assert_success
  assert_output "4242 4243"
}

@test "uid map: a corrupt measurement is refused rather than handed to the box" {
  # A half-written or hand-edited line must never become a HOST_UID: that is the
  # exact failure this code exists to prevent.
  mkdir -p "$CLEAT_CONFIG_DIR/state"
  local key; key="${DOCKER_HOST:-${DOCKER_CONTEXT:-default}}"
  printf '%s\t-\t%s\t%s\n' "$key" "$(id -u)" "notanumber 0" > "$CLEAT_CONFIG_DIR/state/uidmap"
  run _box_identity_cached
  assert_failure
  printf '%s\t-\t%s\t%s\n' "$key" "$(id -u)" "4242" > "$CLEAT_CONFIG_DIR/state/uidmap"
  run _box_identity_cached
  assert_failure
}

@test "uid map: the measurement never puts the credential store in a container" {
  # $CLEAT_CONFIG_DIR holds the account credential store. Learning a number is
  # no reason to mount it anywhere, so the probe binds a dedicated empty dir.
  rm -f "$CLEAT_CONFIG_DIR/state/uidmap"
  mock_docker_images "cleat"
  : > "$DOCKER_CALLS"
  _box_identity_probe || true
  local line
  line="$(grep '^docker run' "$DOCKER_CALLS" | grep 'cleat-uidmap' | head -1)"
  [ -n "$line" ] || { echo "no probe run recorded"; return 1; }
  [[ "$line" == *"state/uidprobe:/cleat-uidmap:ro"* ]] || { echo "probe did not bind its own dir: $line"; return 1; }
  [[ "$line" != *"$CLEAT_CONFIG_DIR:/cleat-uidmap"* ]] || { echo "probe mounted the config root"; return 1; }
}

@test "uid map: a macOS host keeps its own ids and never measures" {
  # The inversion is a Linux user namespace. Every macOS engine runs the daemon
  # in a VM whose share layer already presents your files as yours, and your own
  # uid is what all of them have always run on. Measuring there bought nothing
  # and cost a container run through the VM per launch, which took CI's Colima
  # leg from 21 minutes to a timeout. Even a planted namespaced answer must not
  # reach a macOS box, and nothing may be measured.
  _is_macos() { return 0; }
  mkdir -p "$CLEAT_CONFIG_DIR/state"
  printf '%s\t-\t%s\t0 0\n' "${DOCKER_HOST:-${DOCKER_CONTEXT:-default}}" "$(id -u)" \
    > "$CLEAT_CONFIG_DIR/state/uidmap"
  mock_docker_images "cleat"
  : > "$DOCKER_CALLS"
  run _box_identity
  assert_success
  assert_output "$(id -u) $(id -g)"
  run grep -c 'cleat-uidmap' "$DOCKER_CALLS"
  assert_output "0"
}
