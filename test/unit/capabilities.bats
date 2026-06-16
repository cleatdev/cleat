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

# ── git capability: docker run mounts ────────────────────────────────────

@test "git cap: mounts ~/.gitconfig read-only when enabled" {
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project"
  touch "$HOME/.gitconfig"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"

  cat > "$CLEAT_GLOBAL_CONFIG" << 'EOF'
[caps]
git
EOF

  run cmd_run "$TEST_TEMP/project"
  assert_success
  run assert_docker_run_has "$cname" ".gitconfig:/home/coder/.gitconfig:ro"
  assert_success
}

@test "git cap: skips gitconfig mount when ~/.gitconfig doesn't exist" {
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"

  local orig_home="$HOME"
  HOME="$TEST_TEMP/fakehome"
  mkdir -p "$HOME"

  cat > "$CLEAT_GLOBAL_CONFIG" << 'EOF'
[caps]
git
EOF

  run cmd_run "$TEST_TEMP/project"
  assert_success
  run assert_docker_run_lacks "$cname" ".gitconfig:/home/coder/.gitconfig"
  assert_success

  HOME="$orig_home"
}

@test "git cap: does not mount ssh keys" {
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project"
  mkdir -p "$HOME/.ssh"
  touch "$HOME/.gitconfig"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"

  cat > "$CLEAT_GLOBAL_CONFIG" << 'EOF'
[caps]
git
EOF

  run cmd_run "$TEST_TEMP/project"
  assert_success
  run assert_docker_run_lacks "$cname" ".ssh:/home/coder/.ssh"
  assert_success
}

@test "no git cap: does not mount gitconfig" {
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project"
  touch "$HOME/.gitconfig"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"

  run cmd_run "$TEST_TEMP/project"
  assert_success
  run assert_docker_run_lacks "$cname" ".gitconfig:/home/coder/.gitconfig"
  assert_success
}

# ── ssh capability: docker run mounts ────────────────────────────────────

@test "ssh cap: mounts ~/.ssh read-only when enabled" {
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project"
  mkdir -p "$HOME/.ssh"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"

  cat > "$CLEAT_GLOBAL_CONFIG" << 'EOF'
[caps]
ssh
EOF

  run cmd_run "$TEST_TEMP/project"
  assert_success
  run assert_docker_run_has "$cname" ".ssh:/home/coder/.ssh:ro"
  assert_success
}

@test "ssh cap: skips ssh mount when ~/.ssh doesn't exist" {
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"

  local orig_home="$HOME"
  HOME="$TEST_TEMP/fakehome"
  mkdir -p "$HOME"

  cat > "$CLEAT_GLOBAL_CONFIG" << 'EOF'
[caps]
ssh
EOF

  run cmd_run "$TEST_TEMP/project"
  assert_success
  run assert_docker_run_lacks "$cname" ".ssh:/home/coder/.ssh"
  assert_success

  HOME="$orig_home"
}

@test "ssh cap: does not mount gitconfig" {
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project"
  touch "$HOME/.gitconfig"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"

  cat > "$CLEAT_GLOBAL_CONFIG" << 'EOF'
[caps]
ssh
EOF

  run cmd_run "$TEST_TEMP/project"
  assert_success
  run assert_docker_run_lacks "$cname" ".gitconfig:/home/coder/.gitconfig"
  assert_success
}

@test "no ssh cap: does not mount ssh keys" {
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project"
  mkdir -p "$HOME/.ssh"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"

  run cmd_run "$TEST_TEMP/project"
  assert_success
  run assert_docker_run_lacks "$cname" ".ssh:/home/coder/.ssh"
  assert_success
}

@test "ssh cap: SSH agent forwarding when SSH_AUTH_SOCK is a socket" {
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"

  cat > "$CLEAT_GLOBAL_CONFIG" << 'EOF'
[caps]
ssh
EOF
  local sock_path="$TEST_TEMP/ssh-test.sock"
  # Create a real Unix socket. Use nc -lU if available, fall back to python3.
  if command -v nc &>/dev/null && nc -h 2>&1 | grep -q '\-U'; then
    nc -lU "$sock_path" &
    local sock_pid=$!
  elif command -v python3 &>/dev/null; then
    python3 -c "
import socket, sys, time
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.bind(sys.argv[1])
s.listen(1)
time.sleep(30)
" "$sock_path" &
    local sock_pid=$!
  else
    skip "No tool available to create Unix socket"
  fi
  # Wait for the socket file to appear
  for _i in 1 2 3 4 5; do [[ -S "$sock_path" ]] && break; sleep 0.1; done
  [[ -S "$sock_path" ]] || { kill "$sock_pid" 2>/dev/null; skip "Socket creation timed out"; }

  SSH_AUTH_SOCK="$sock_path"

  run cmd_run "$TEST_TEMP/project"
  assert_success
  run assert_docker_run_has "$cname" "SSH_AUTH_SOCK=/tmp/ssh-agent.sock"
  assert_success
  run assert_docker_run_has "$cname" "$sock_path:/tmp/ssh-agent.sock"
  assert_success

  kill "$sock_pid" 2>/dev/null || true
  unset SSH_AUTH_SOCK
}

@test "ssh cap: no SSH forwarding when SSH_AUTH_SOCK unset" {
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"

  cat > "$CLEAT_GLOBAL_CONFIG" << 'EOF'
[caps]
ssh
EOF
  unset SSH_AUTH_SOCK

  run cmd_run "$TEST_TEMP/project"
  assert_success
  run assert_docker_run_lacks "$cname" "SSH_AUTH_SOCK"
  assert_success
}

@test "ssh cap: no SSH forwarding when SSH_AUTH_SOCK is not a socket" {
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"

  cat > "$CLEAT_GLOBAL_CONFIG" << 'EOF'
[caps]
ssh
EOF
  SSH_AUTH_SOCK="$TEST_TEMP/not-a-socket"
  touch "$SSH_AUTH_SOCK"

  run cmd_run "$TEST_TEMP/project"
  assert_success
  run assert_docker_run_lacks "$cname" "SSH_AUTH_SOCK"
  assert_success

  unset SSH_AUTH_SOCK
}

@test "git+ssh caps together: mounts both gitconfig and ssh" {
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project"
  mkdir -p "$HOME/.ssh"
  touch "$HOME/.gitconfig"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"

  cat > "$CLEAT_GLOBAL_CONFIG" << 'EOF'
[caps]
git
ssh
EOF

  run cmd_run "$TEST_TEMP/project"
  assert_success
  run assert_docker_run_has "$cname" ".gitconfig:/home/coder/.gitconfig:ro"
  assert_success
  run assert_docker_run_has "$cname" ".ssh:/home/coder/.ssh:ro"
  assert_success
}

# ── gh capability: docker run mounts ─────────────────────────────────────

@test "gh cap: mounts ~/.config/gh read-write when enabled" {
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"

  cat > "$CLEAT_GLOBAL_CONFIG" << 'EOF'
[caps]
gh
EOF

  run cmd_run "$TEST_TEMP/project"
  assert_success
  # Read-write (no :ro) so `gh auth login` writes tokens back to host
  run assert_docker_run_has "$cname" ".config/gh:/home/coder/.config/gh"
  assert_success
  # Must NOT have :ro flag
  run assert_docker_run_lacks "$cname" ".config/gh:/home/coder/.config/gh:ro"
  assert_success
}

@test "gh cap: creates ~/.config/gh if missing" {
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"

  local orig_home="$HOME"
  HOME="$TEST_TEMP/fakehome"
  mkdir -p "$HOME"

  cat > "$CLEAT_GLOBAL_CONFIG" << 'EOF'
[caps]
gh
EOF

  run cmd_run "$TEST_TEMP/project"
  assert_success
  # Dir should be created by cmd_run
  [[ -d "$HOME/.config/gh" ]] || {
    echo "~/.config/gh was not created"
    return 1
  }
  run assert_docker_run_has "$cname" ".config/gh:/home/coder/.config/gh"
  assert_success

  HOME="$orig_home"
}

@test "no gh cap: does not mount gh config" {
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project"
  mkdir -p "$HOME/.config/gh"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"

  run cmd_run "$TEST_TEMP/project"
  assert_success
  run assert_docker_run_lacks "$cname" ".config/gh:/home/coder/.config/gh"
  assert_success
}

# ── docker capability: docker run mounts ──────────────────────────────────
#
# Design rationale: concept/15-docker-capability.md. Opt-in only. When active,
# the host docker socket is mounted (sibling containers), the project is
# bind-mounted at its HOST path (in addition to /workspace) so `$(pwd)`
# returns a host-valid path inside the container, and workdir is set to that
# host path. Also exports CLEAT_HOST_PROJECT for scripts.

@test "docker cap: mounts /var/run/docker.sock when enabled" {
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"

  cat > "$CLEAT_GLOBAL_CONFIG" << 'EOF'
[caps]
docker
EOF

  run cmd_run "$TEST_TEMP/project"
  assert_success
  run assert_docker_run_has "$cname" "/var/run/docker.sock:/var/run/docker.sock"
  assert_success
}

@test "docker cap: bind-mounts project at its host path (identity mount)" {
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"

  cat > "$CLEAT_GLOBAL_CONFIG" << 'EOF'
[caps]
docker
EOF

  run cmd_run "$TEST_TEMP/project"
  assert_success
  # Project path mounted at its host path inside the container, so
  # $(pwd), `.`, and absolute host paths all resolve on the host daemon.
  run assert_docker_run_has "$cname" "$TEST_TEMP/project:$TEST_TEMP/project"
  assert_success
}

@test "docker cap: keeps /workspace mount alongside host-path mount" {
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"

  cat > "$CLEAT_GLOBAL_CONFIG" << 'EOF'
[caps]
docker
EOF

  run cmd_run "$TEST_TEMP/project"
  assert_success
  # /workspace still valid, preserves existing muscle memory
  run assert_docker_run_has "$cname" "$TEST_TEMP/project:/workspace"
  assert_success
}

@test "docker cap: sets workdir to host path and exports CLEAT_HOST_PROJECT" {
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"

  cat > "$CLEAT_GLOBAL_CONFIG" << 'EOF'
[caps]
docker
EOF

  run cmd_run "$TEST_TEMP/project"
  assert_success
  run assert_docker_run_has "$cname" "--workdir $TEST_TEMP/project"
  assert_success
  run assert_docker_run_has "$cname" "CLEAT_HOST_PROJECT=$TEST_TEMP/project"
  assert_success
}

@test "no docker cap: does not mount docker socket or set host workdir" {
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"

  run cmd_run "$TEST_TEMP/project"
  assert_success
  run assert_docker_run_lacks "$cname" "/var/run/docker.sock"
  assert_success
  run assert_docker_run_lacks "$cname" "--workdir $TEST_TEMP/project"
  assert_success
  run assert_docker_run_lacks "$cname" "CLEAT_HOST_PROJECT="
  assert_success
}

@test "docker cap: via --cap flag (session-only) mounts socket" {
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"

  _CLI_CAPS=(docker)

  run cmd_run "$TEST_TEMP/project"
  assert_success
  run assert_docker_run_has "$cname" "/var/run/docker.sock:/var/run/docker.sock"
  assert_success
  run assert_docker_run_has "$cname" "$TEST_TEMP/project:$TEST_TEMP/project"
  assert_success
}

@test "docker cap: description mentions sandbox-break tradeoff" {
  # The cap picker describes every capability; docker's description must be
  # honest about the security tradeoff so users know what they're opting in to.
  run _cap_description docker
  assert_success
  assert_output --partial "breaks sandbox"
}

@test "docker cap + git cap together: both mounts present" {
  # Combining caps shouldn't have any cross-interaction. docker mount and
  # git mount should both appear in docker run args.
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project"
  touch "$HOME/.gitconfig"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"

  cat > "$CLEAT_GLOBAL_CONFIG" << 'EOF'
[caps]
git
docker
EOF

  run cmd_run "$TEST_TEMP/project"
  assert_success
  run assert_docker_run_has "$cname" "/var/run/docker.sock:/var/run/docker.sock"
  assert_success
  run assert_docker_run_has "$cname" ".gitconfig:/home/coder/.gitconfig:ro"
  assert_success
}

# ── --cap CLI flag ─────────────────────────────────────────────────────────

@test "--cap flag: enables cap for session without config" {
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project"
  mkdir -p "$HOME/.ssh"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"

  # Use --cap ssh via _CLI_CAPS
  _CLI_CAPS=(ssh)

  run cmd_run "$TEST_TEMP/project"
  assert_success
  run assert_docker_run_has "$cname" ".ssh:/home/coder/.ssh:ro"
  assert_success
}

# ── env capability: env file parsing ───────────────────────────────────────

@test "parse_env_file: returns empty for missing file" {
  run _parse_env_file "$TEST_TEMP/nonexistent"
  assert_success
  assert_output ""
}

@test "parse_env_file: reads KEY=VALUE entries" {
  cat > "$TEST_TEMP/envfile" << 'EOF'
FOO=bar
BAZ=qux
EOF
  run _parse_env_file "$TEST_TEMP/envfile"
  assert_success
  assert_line --index 0 "FOO=bar"
  assert_line --index 1 "BAZ=qux"
}

@test "parse_env_file: skips comments and empty lines" {
  cat > "$TEST_TEMP/envfile" << 'EOF'
# comment
FOO=bar

# another comment
BAZ=qux
EOF
  run _parse_env_file "$TEST_TEMP/envfile"
  assert_success
  assert_line --index 0 "FOO=bar"
  assert_line --index 1 "BAZ=qux"
}

@test "parse_env_file: resolves bare KEY from host env" {
  export TEST_CLEAT_VAR="hello"
  cat > "$TEST_TEMP/envfile" << 'EOF'
TEST_CLEAT_VAR
EOF
  run _parse_env_file "$TEST_TEMP/envfile"
  assert_success
  assert_output "TEST_CLEAT_VAR=hello"
  unset TEST_CLEAT_VAR
}

@test "parse_env_file: skips bare KEY when not set on host" {
  unset NONEXISTENT_CLEAT_VAR 2>/dev/null || true
  cat > "$TEST_TEMP/envfile" << 'EOF'
NONEXISTENT_CLEAT_VAR
EOF
  run _parse_env_file "$TEST_TEMP/envfile"
  assert_success
  assert_output ""
}

@test "parse_env_file: skips bare KEY with invalid variable name" {
  cat > "$TEST_TEMP/envfile" << 'EOF'
123INVALID
my-var
MY VARIABLE
_VALID_KEY
EOF
  export _VALID_KEY="yes"
  run _parse_env_file "$TEST_TEMP/envfile"
  assert_success
  # Only _VALID_KEY should resolve. The others have invalid variable names
  assert_output "_VALID_KEY=yes"
  unset _VALID_KEY
}

@test "parse_env_file: handles values with = sign" {
  cat > "$TEST_TEMP/envfile" << 'EOF'
DATABASE_URL=postgres://user:pass@host:5432/db
EOF
  run _parse_env_file "$TEST_TEMP/envfile"
  assert_success
  assert_output "DATABASE_URL=postgres://user:pass@host:5432/db"
}

@test "parse_env_file: handles CRLF line endings" {
  printf 'FOO=bar\r\nBAZ=qux\r\n' > "$TEST_TEMP/envfile"
  run _parse_env_file "$TEST_TEMP/envfile"
  assert_success
  assert_line --index 0 "FOO=bar"
  assert_line --index 1 "BAZ=qux"
}

@test "parse_env_file: reads last line without trailing newline" {
  printf 'FOO=bar\nBAZ=qux' > "$TEST_TEMP/envfile"
  run _parse_env_file "$TEST_TEMP/envfile"
  assert_success
  assert_line --index 0 "FOO=bar"
  assert_line --index 1 "BAZ=qux"
}

@test "parse_env_file: skips empty key (=VALUE line)" {
  cat > "$TEST_TEMP/envfile" << 'EOF'
=should_skip
VALID=ok
EOF
  run _parse_env_file "$TEST_TEMP/envfile"
  assert_success
  assert_output "VALID=ok"
}

# ── env capability: docker run args ────────────────────────────────────────

@test "env cap: passes env vars from global env file to docker run" {
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"

  cat > "$CLEAT_GLOBAL_CONFIG" << 'EOF'
[caps]
env
EOF
  cat > "$CLEAT_GLOBAL_ENV" << 'EOF'
MY_TOKEN=secret123
EOF

  run cmd_run "$TEST_TEMP/project"
  assert_success
  run assert_docker_run_has "$cname" "MY_TOKEN=secret123"
  assert_success
}

@test "env cap: passes env vars from project .cleat.env" {
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"

  cat > "$CLEAT_GLOBAL_CONFIG" << 'EOF'
[caps]
env
EOF
  cat > "$TEST_TEMP/project/.cleat.env" << 'EOF'
PROJECT_VAR=hello
EOF

  run cmd_run "$TEST_TEMP/project"
  assert_success
  run assert_docker_run_has "$cname" "PROJECT_VAR=hello"
  assert_success
}

@test "no env cap: ignores env files even when present" {
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"

  # env cap NOT enabled, but files exist
  cat > "$CLEAT_GLOBAL_ENV" << 'EOF'
SHOULD_NOT_APPEAR=true
EOF

  run cmd_run "$TEST_TEMP/project"
  assert_success
  run assert_docker_run_lacks "$cname" "SHOULD_NOT_APPEAR"
  assert_success
}

@test "env cap: project env overrides global env (last wins)" {
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"

  cat > "$CLEAT_GLOBAL_CONFIG" << 'EOF'
[caps]
env
EOF
  cat > "$CLEAT_GLOBAL_ENV" << 'EOF'
SHARED_KEY=global_value
EOF
  cat > "$TEST_TEMP/project/.cleat.env" << 'EOF'
SHARED_KEY=project_value
EOF

  run cmd_run "$TEST_TEMP/project"
  assert_success
  run assert_docker_run_has "$cname" "SHARED_KEY=project_value"
  assert_success
}

# ── --env and --env-file flags ─────────────────────────────────────────────

@test "--env flag: passes KEY=VALUE without env cap" {
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"

  _CLI_ENVS=("MY_FLAG=value")

  run cmd_run "$TEST_TEMP/project"
  assert_success
  run assert_docker_run_has "$cname" "MY_FLAG=value"
  assert_success
}

@test "--env flag: inherits bare KEY from host" {
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"

  export CLI_ENV_TEST_VAR="inherited"
  _CLI_ENVS=("CLI_ENV_TEST_VAR")

  run cmd_run "$TEST_TEMP/project"
  assert_success
  run assert_docker_run_has "$cname" "CLI_ENV_TEST_VAR=inherited"
  assert_success
  unset CLI_ENV_TEST_VAR
}

@test "--env-file flag: loads from specified file without env cap" {
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"

  cat > "$TEST_TEMP/custom.env" << 'EOF'
CUSTOM_VAR=from_file
EOF
  _CLI_ENV_FILES=("$TEST_TEMP/custom.env")

  run cmd_run "$TEST_TEMP/project"
  assert_success
  run assert_docker_run_has "$cname" "CUSTOM_VAR=from_file"
  assert_success
}

@test "--env-file flag: fails for nonexistent file" {
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project"

  _CLI_ENV_FILES=("$TEST_TEMP/nonexistent.env")

  run cmd_run "$TEST_TEMP/project"
  assert_failure
  assert_output --partial "Env file not found"
}

# ── Docker labels ──────────────────────────────────────────────────────────

@test "run: stores config-hash label on container" {
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"

  run cmd_run "$TEST_TEMP/project"
  assert_success
  # Stored with the storage-format prefix (v2:) so a later formula change is
  # detectable instead of mistaken for real drift. See _CONFIG_FP_VERSION.
  run assert_docker_run_has "$cname" "sh.cleat.config-hash=v2:"
  assert_success
}

@test "run: stores version label on container" {
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"

  run cmd_run "$TEST_TEMP/project"
  assert_success
  run assert_docker_run_has "$cname" "sh.cleat.version=$VERSION"
  assert_success
}

@test "build: stores version label on image" {
  run cmd_build
  assert_success
  run docker_build_calls
  assert_output --partial "sh.cleat.version=$VERSION"
}

@test "rebuild: stores version label on image" {
  run cmd_rebuild
  run docker_build_calls
  assert_output --partial "sh.cleat.version=$VERSION"
}

# ── Config fingerprint ─────────────────────────────────────────────────────

@test "fingerprint: changes when caps change" {
  ACTIVE_CAPS=()
  _RESOLVED_ENV_ARGS=()
  local hash1
  hash1="$(compute_config_fingerprint)"

  ACTIVE_CAPS=(git)
  local hash2
  hash2="$(compute_config_fingerprint)"

  [[ "$hash1" != "$hash2" ]]
}

@test "fingerprint: changes when env keys change" {
  ACTIVE_CAPS=(env)
  _RESOLVED_ENV_ARGS=(-e "FOO=bar")
  local hash1
  hash1="$(compute_config_fingerprint)"

  _RESOLVED_ENV_ARGS=(-e "FOO=bar" -e "BAZ=qux")
  local hash2
  hash2="$(compute_config_fingerprint)"

  [[ "$hash1" != "$hash2" ]]
}

@test "fingerprint: stable with same config" {
  ACTIVE_CAPS=(git env)
  _RESOLVED_ENV_ARGS=(-e "FOO=bar")
  local hash1 hash2
  hash1="$(compute_config_fingerprint)"
  hash2="$(compute_config_fingerprint)"
  [[ "$hash1" == "$hash2" ]]
}

@test "fingerprint: stable regardless of cap order" {
  # Caps are sorted before hashing, so (git ssh) and (ssh git) must match.
  # Without the sort, a reordered cap list would fire a false drift notice.
  _RESOLVED_ENV_ARGS=()
  ACTIVE_CAPS=(git ssh); local h1; h1="$(compute_config_fingerprint)"
  ACTIVE_CAPS=(ssh git); local h2; h2="$(compute_config_fingerprint)"
  [[ "$h1" == "$h2" ]]
}

@test "fingerprint: stable regardless of env-arg order" {
  # Env keys are sorted INSIDE compute_config_fingerprint, so a different arg
  # order (refactor, new env source) can't drift the hash. Guards against the
  # false "caps or env keys differ" notice on an otherwise-unchanged setup.
  ACTIVE_CAPS=(env)
  _RESOLVED_ENV_ARGS=(-e "FOO=1" -e "BAR=2"); local h1; h1="$(compute_config_fingerprint)"
  _RESOLVED_ENV_ARGS=(-e "BAR=2" -e "FOO=1"); local h2; h2="$(compute_config_fingerprint)"
  [[ "$h1" == "$h2" ]]
}

@test "fingerprint: ignores env values (only keys matter)" {
  # Env VALUES are deliberately excluded: they're passed at exec time, not baked
  # into the container, so a value change must NOT force a recreate.
  ACTIVE_CAPS=(env)
  _RESOLVED_ENV_ARGS=(-e "FOO=old"); local h1; h1="$(compute_config_fingerprint)"
  _RESOLVED_ENV_ARGS=(-e "FOO=new"); local h2; h2="$(compute_config_fingerprint)"
  [[ "$h1" == "$h2" ]]
}

# ── Config drift resolution ────────────────────────────────────────────────
#
# _resolve_config_drift is the interactive fix path users hit after
# `cleat config --enable <cap>` followed by `cleat`. The goal is to detect
# the cap change, prompt to recreate, and clean up so the caller's existing
# "no container" branch (cmd_run) rebuilds with the new caps.

@test "_resolve_config_drift: no-op when container does not exist" {
  run bash -c '
    source "'"$CLI"'"
    container_exists() { return 1; }
    _resolve_config_drift "cleat-foo" ""
  '
  assert_success
  refute_output --partial "Config changed"
}

@test "_resolve_config_drift: no-op when hashes match" {
  run bash -c '
    source "'"$CLI"'"
    container_exists() { return 0; }
    _container_config_hash() { echo "v2:abc123"; }
    compute_config_fingerprint() { echo "abc123"; }
    _resolve_config_drift "cleat-foo" ""
  '
  assert_success
  refute_output --partial "Config changed"
}

@test "_resolve_config_drift: non-TTY prints warning notice and continues" {
  run bash -c '
    source "'"$CLI"'"
    container_exists() { return 0; }
    _container_config_hash() { echo "v2:old"; }
    compute_config_fingerprint() { echo "new"; }
    _is_tty() { return 1; }
    _resolve_config_drift "cleat-foo" ""
  '
  assert_success
  assert_output --partial "Config changed"
  assert_output --partial "cleat rm && cleat"
  # Plain text now, not a bordered _notice_box.
  refute_output --partial "┌"
}

@test "_resolve_config_drift: message names caps/env/resources (not just caps or env)" {
  # v0.16.4: explicitly-configured [resources] can drift too, so the message must
  # not claim only "caps or env keys" changed (the old, misleading wording).
  run bash -c '
    source "'"$CLI"'"
    container_exists() { return 0; }
    _container_config_hash() { echo "v2:old"; }
    compute_config_fingerprint() { echo "new"; }
    _is_tty() { return 0; }
    echo "n" | _resolve_config_drift "cleat-foo" ""
  '
  assert_output --partial "resource limits"
  refute_output --partial "caps or env keys"
}

@test "_resolve_config_drift: TTY + accept removes the container" {
  run bash -c '
    source "'"$CLI"'"
    container_exists() { return 0; }
    _container_config_hash() { echo "v2:old"; }
    compute_config_fingerprint() { echo "new"; }
    _is_tty() { return 0; }
    is_running() { return 1; }
    export DOCKER_CALLS="'"$DOCKER_CALLS"'" PATH="'"$MOCK_BIN"':$PATH"
    echo "y" | _resolve_config_drift "cleat-foo" ""
  '
  assert_success
  assert_output --partial "Removed"
  run cat "$DOCKER_CALLS"
  assert_output --partial "rm -f cleat-foo"
}

@test "_resolve_config_drift: TTY + decline keeps the container" {
  run bash -c '
    source "'"$CLI"'"
    container_exists() { return 0; }
    _container_config_hash() { echo "v2:old"; }
    compute_config_fingerprint() { echo "new"; }
    _is_tty() { return 0; }
    is_running() { return 1; }
    export DOCKER_CALLS="'"$DOCKER_CALLS"'" PATH="'"$MOCK_BIN"':$PATH"
    echo "n" | _resolve_config_drift "cleat-foo" ""
  '
  assert_success
  assert_output --partial "Skipped"
  run cat "$DOCKER_CALLS"
  refute_output --partial "rm -f cleat-foo"
}

@test "_resolve_config_drift: legacy hash (no version prefix) is never nagged" {
  # A container created before the v0.16.4 fingerprint format carries a bare hash
  # we can't reconstruct. Treating a mismatch against it as drift was the source
  # of the false recreate on a CLI upgrade, so legacy hashes are left alone: the
  # box keeps working and adopts the current format on its next real recreate.
  run bash -c '
    source "'"$CLI"'"
    container_exists() { return 0; }
    _container_config_hash() { echo "deadbeef0badf00d"; }
    compute_config_fingerprint() { echo "totally-different"; }
    _is_tty() { return 0; }
    echo "y" | _resolve_config_drift "cleat-foo" ""
  '
  assert_success
  refute_output --partial "Config changed"
}

@test "_resolve_config_drift: a newer/unknown format prefix is also left alone" {
  # Only the EXACT current format (v2:) is comparable; a v3:/v99: hash from a
  # future CLI must not be mistaken for drift by an older binary.
  run bash -c '
    source "'"$CLI"'"
    container_exists() { return 0; }
    _container_config_hash() { echo "v99:whatever"; }
    compute_config_fingerprint() { echo "abc123"; }
    _is_tty() { return 0; }
    echo "y" | _resolve_config_drift "cleat-foo" ""
  '
  assert_success
  refute_output --partial "Config changed"
}

@test "_resolve_config_drift: absent config-hash label is a no-op" {
  run bash -c '
    source "'"$CLI"'"
    container_exists() { return 0; }
    _container_config_hash() { echo ""; }
    compute_config_fingerprint() { echo "abc123"; }
    _is_tty() { return 0; }
    echo "y" | _resolve_config_drift "cleat-foo" ""
  '
  assert_success
  refute_output --partial "Config changed"
}

# ── Caps categorization (mount / sandbox) ──────────────────────────────────
#
# Active caps display groups by behavior, same UI on the landing page.
# These tests pin the category mapping and the renderer's behavior so a
# refactor that drops a cap from its category, or breaks the multi-line
# layout, fails loudly. The visual is part of the brand: it teaches users
# that the docker cap is sandbox-breaking.

@test "_cap_category: mount caps are mount" {
  local cap
  for cap in git ssh env hooks gh; do
    run _cap_category "$cap"
    assert_success
    assert_output "mount"
  done
}

@test "_cap_category: docker is sandbox" {
  run _cap_category docker
  assert_success
  assert_output "sandbox"
}

@test "_caps_bucket_active: splits ACTIVE_CAPS by category" {
  ACTIVE_CAPS=(git docker ssh)
  _caps_bucket_active
  [[ "${_CAPS_MOUNT[*]}"   == "git ssh" ]] || { echo "mount: ${_CAPS_MOUNT[*]}"; return 1; }
  [[ "${_CAPS_SANDBOX[*]}" == "docker" ]]  || { echo "sandbox: ${_CAPS_SANDBOX[*]}"; return 1; }
}

@test "_print_caps: silent when ACTIVE_CAPS is empty" {
  ACTIVE_CAPS=()
  run _print_caps
  assert_output ""
}

@test "_print_caps: single-line form when only mount caps" {
  # Only one category active → legacy single-line layout, no per-category block.
  ACTIVE_CAPS=(git ssh env hooks)
  run _print_caps
  assert_output --partial "Caps:"
  assert_output --partial "git, ssh, env, hooks"
  refute_output --partial "mount:"
  refute_output --partial "sandbox:"
}

@test "_print_caps: single-line form when only docker (sandbox)" {
  ACTIVE_CAPS=(docker)
  run _print_caps
  assert_output --partial "Caps:"
  assert_output --partial "docker"
  refute_output --partial "sandbox:"
}

@test "_print_caps: multi-line block when both categories active" {
  ACTIVE_CAPS=(git docker)
  run _print_caps
  assert_output --partial "Caps:"
  assert_output --partial "mount:"
  assert_output --partial "sandbox:"
  assert_output --partial "(breaks isolation)"
}

@test "_print_summary_block: renders categorized caps when categories span" {
  ACTIVE_CAPS=(git docker)
  run _print_summary_block "cleat-test-12345678" "$TEST_TEMP/project"
  assert_output --partial "Caps:"
  assert_output --partial "mount:"
  assert_output --partial "sandbox:"
  assert_output --partial "git"
  assert_output --partial "docker"
}

@test "_print_summary_block: renders single-line caps when only mount" {
  ACTIVE_CAPS=(git ssh)
  run _print_summary_block "cleat-test-12345678" "$TEST_TEMP/project"
  assert_output --partial "Caps:"
  assert_output --partial "git, ssh"
  refute_output --partial "mount:"
}

# ── Startup output ─────────────────────────────────────────────────────────

@test "startup: prints active caps" {
  ACTIVE_CAPS=(git env)
  run _print_startup_caps
  assert_output --partial "Caps:"
  assert_output --partial "git, env"
}

@test "startup: silent when no caps" {
  ACTIVE_CAPS=()
  run _print_startup_caps
  assert_output ""
}

# ── Status shows caps ─────────────────────────────────────────────────────

@test "status: shows active capabilities" {
  mkdir -p "$TEST_TEMP/project"
  cat > "$CLEAT_GLOBAL_CONFIG" << 'EOF'
[caps]
git
EOF
  run cmd_status "$TEST_TEMP/project"
  assert_output --partial "git"
  assert_output --partial "Caps:"
}

@test "status: shows 'none' when no caps enabled" {
  mkdir -p "$TEST_TEMP/project"
  run cmd_status "$TEST_TEMP/project"
  assert_output --partial "none"
}
