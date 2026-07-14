#!/usr/bin/env bats
# ─────────────────────────────────────────────────────────────────────────────
# Integration: full container lifecycle against REAL Docker.
#
# These tests are the backstop for platform bugs. They use the real cleat
# binary against a real Docker daemon and verify end-to-end behavior.
#
# Skipped if docker is unavailable.
# ─────────────────────────────────────────────────────────────────────────────

load "../setup"

setup_file() {
  if ! command -v docker &>/dev/null; then
    skip "docker not available"
  fi
  if ! docker info &>/dev/null; then
    skip "docker daemon not reachable"
  fi

  # Build the image once for all tests in this file
  local repo_root
  repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  docker build -q -t cleat -f "$repo_root/docker/Dockerfile" "$repo_root/docker/" >/dev/null 2>&1 || {
    skip "could not build cleat image"
  }
}

setup() {
  _common_setup
  INT_PROJECT="$TEST_TEMP/int-project"
  mkdir -p "$INT_PROJECT"

  # Use a unique container name so tests don't collide
  INT_CNAME="cleat-int-$(date +%s)-$$"
  export INT_CNAME
}

teardown() {
  # Best-effort cleanup of any container created by this test
  docker rm -f "$INT_CNAME" >/dev/null 2>&1 || true
  # Also remove the default cleat-named container if any
  local default_name
  default_name="$(bash -c "source <(sed 's/^set -euo pipefail/#/' '$CLI'); container_name_for '$INT_PROJECT'" 2>/dev/null)"
  [[ -n "$default_name" ]] && docker rm -f "$default_name" >/dev/null 2>&1 || true
  # Remove any box containers for this project (main cname is the prefix).
  if [[ -n "$default_name" ]]; then
    docker ps -aq --filter "name=^${default_name}" 2>/dev/null | while read -r _c; do
      [[ -n "$_c" ]] && docker rm -f "$_c" >/dev/null 2>&1 || true
    done
  fi
  _common_teardown
}

# ── Smoke: cleat --help works on the real binary ────────────────────────────

@test "integration: cleat --help runs against real system" {
  run "$CLI" --help
  assert_success
  assert_output --partial "Cleat"
}

# ── v0.6.5 regression: fresh container creation works on real Docker ─────────
# This is the test that would have caught v0.6.5 at integration level. On
# macOS Docker Desktop, this test would fail without the fix because the
# virtiofs nested bind-mount would error. On Linux, it passes even without
# the fix (Docker creates stub files on the host). The test is valuable on
# macOS runners and as documentation.

@test "integration: cleat run with .claude/ but no settings.json creates container" {
  mkdir -p "$INT_PROJECT/.claude"
  # Intentionally no settings.json or settings.local.json

  # Enable hooks cap so the project overlay code path runs
  export XDG_CONFIG_HOME="$TEST_TEMP/xdg"
  mkdir -p "$XDG_CONFIG_HOME/cleat"
  cat > "$XDG_CONFIG_HOME/cleat/config" << 'EOF'
[caps]
hooks
EOF

  cd "$INT_PROJECT"
  run "$CLI" run
  assert_success
  refute_output --partial "outside of rootfs"
  refute_output --partial "Container failed to start"
}

# ── v0.6.3 end-to-end: .cleat.env values visible inside shell ───────────────
# This is the test that would have caught the v0.6.3 env passthrough bug.
# Unit tests can verify the docker command is correctly built, but only an
# integration test can verify the value actually reaches the container process.

@test "integration: .cleat.env DATABASE_URL is visible via cleat shell" {
  cat > "$INT_PROJECT/.cleat.env" << 'EOF'
DATABASE_URL=postgres://integration-test/db
EOF
  cat > "$INT_PROJECT/.cleat" << 'EOF'
[caps]
env
EOF

  # Start a container for this project. Real docker.
  cd "$INT_PROJECT"
  run "$CLI" run
  assert_success

  # Non-interactive shell: feed a command to cleat shell via stdin
  local cname
  cname="$(bash -c "source <(sed 's/^set -euo pipefail/#/' '$CLI'); container_name_for '$INT_PROJECT'")"
  run docker exec "$cname" printenv DATABASE_URL
  assert_success
  assert_output "postgres://integration-test/db"
}

# ── Boxes (concept/20-boxes.md): two boxes over one live workspace ──────────

@test "integration: two boxes are distinct containers sharing one /workspace; describe never recreates" {
  cd "$INT_PROJECT"
  local main_cname az_cname
  main_cname="$(bash -c "source <(sed 's/^set -euo pipefail/#/' '$CLI'); container_name_for '$INT_PROJECT' main")"
  az_cname="$(bash -c "source <(sed 's/^set -euo pipefail/#/' '$CLI'); container_name_for '$INT_PROJECT' az")"

  run "$CLI" run
  assert_success
  run "$CLI" run az
  assert_success

  # Two distinct, really-existing containers for this one project.
  [[ "$main_cname" != "$az_cname" ]] || { echo "names collided"; return 1; }
  docker inspect "$main_cname" >/dev/null 2>&1 || { echo "main container missing"; return 1; }
  docker inspect "$az_cname"   >/dev/null 2>&1 || { echo "az container missing"; return 1; }

  # Both bind-mount the SAME host path at /workspace: the live shared tree.
  local m_src a_src
  m_src="$(docker inspect "$main_cname" --format '{{range .Mounts}}{{if eq .Destination "/workspace"}}{{.Source}}{{end}}{{end}}')"
  a_src="$(docker inspect "$az_cname"   --format '{{range .Mounts}}{{if eq .Destination "/workspace"}}{{.Source}}{{end}}{{end}}')"
  [[ -n "$m_src" && "$m_src" == "$a_src" ]] || { echo "workspace mounts differ: '$m_src' vs '$a_src'"; return 1; }

  # The az box carries the sh.cleat.box label.
  run docker inspect "$az_cname" --format '{{index .Config.Labels "sh.cleat.box"}}'
  assert_output "az"

  # `cleat describe` must NOT recreate the container (host-side metadata): the
  # writable layer (e.g. an `az login`) must survive. Verify the container ID
  # is unchanged across a describe.
  local before after
  before="$(docker inspect --format '{{.Id}}' "$az_cname")"
  "$CLI" describe az "cloud box" >/dev/null
  after="$(docker inspect --format '{{.Id}}' "$az_cname")"
  [[ "$before" == "$after" ]] || { echo "describe recreated the container!"; return 1; }

  docker rm -f "$main_cname" "$az_cname" >/dev/null 2>&1 || true
}

# ── Docker capability (concept/15): coder reaches the host daemon; heal is safe ──

@test "integration: docker cap, coder reaches the daemon, and the self-heal is idempotent" {
  cd "$INT_PROJECT"
  run "$CLI" --cap docker run
  assert_success
  local cname
  cname="$(bash -c "source <(sed 's/^set -euo pipefail/#/' '$CLI'); container_name_for '$INT_PROJECT'")"

  # The entrypoint adds coder to the socket's owning group at container start so
  # coder can reach the mounted /var/run/docker.sock. Against a freshly started
  # real container the daemon side can take a moment to become reachable, so poll
  # a few seconds before asserting: a single 0ms probe raced container startup
  # and flaked in CI. This still fails hard (with diagnostics) if coder genuinely
  # cannot connect; it only tolerates the sub-second startup settle.
  local ok=""
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    if docker exec "$cname" runuser -u coder -- docker version >/dev/null 2>&1; then ok=1; break; fi
    sleep 0.5
  done
  if [ -z "$ok" ]; then
    echo "DIAG host-sock:  $(stat -c '%g %U:%G %a' /var/run/docker.sock 2>&1)"
    echo "DIAG in-sock:    $(docker exec "$cname" stat -c '%g %U:%G %a' /var/run/docker.sock 2>&1)"
    echo "DIAG coder-id:   $(docker exec "$cname" id coder 2>&1)"
    echo "DIAG runuser-id: $(docker exec "$cname" runuser -u coder -- id 2>&1)"
    echo "DIAG as-root:    $(docker exec "$cname" docker version 2>&1 | tail -2)"
    echo "DIAG as-coder:   $(docker exec "$cname" runuser -u coder -- docker version 2>&1 | tail -2)"
  fi

  # coder can talk to the host daemon through the mounted /var/run/docker.sock.
  run docker exec "$cname" runuser -u coder -- docker version
  assert_success

  # The per-exec self-heal must be idempotent: re-running it on an already-OK
  # container keeps coder's access working (doesn't strip the group / break it).
  bash -c "source <(sed 's/^set -euo pipefail/#/' '$CLI'); _heal_docker_sock '$cname'"
  run docker exec "$cname" runuser -u coder -- docker version
  assert_success

  docker rm -f "$cname" >/dev/null 2>&1 || true
}

# ── Base image (concept/14): ships the expected Node major ───────────────────

@test "integration: base image ships Node 24" {
  cd "$INT_PROJECT"
  run "$CLI" run
  assert_success
  local cname
  cname="$(bash -c "source <(sed 's/^set -euo pipefail/#/' '$CLI'); container_name_for '$INT_PROJECT'")"
  run docker exec "$cname" node --version
  assert_success
  [[ "$output" == v24* ]] || { echo "expected Node 24, got: $output"; return 1; }
}

# ── Kits (concept/34): merged read-only view in the box, host untouched ──────
# Only an integration test can prove the three load-bearing claims at once:
# the mask is truly read-only from inside the cage (mount-level, even as
# root), the merge is what Claude actually reads, and a `kit off` lands in a
# RUNNING container without a restart (the inode-stable in-place rewrite).

@test "integration: kitted box sees the merged view read-only; host untouched; kit off lands live" {
  cd "$INT_PROJECT"
  local cname
  cname="$(bash -c "source <(sed 's/^set -euo pipefail/#/' '$CLI'); container_name_for '$INT_PROJECT'")"

  # Host global memory + a personal agent that must survive the merge.
  echo "MY GLOBAL RULES" > "$HOME/.claude/CLAUDE.md"
  mkdir -p "$HOME/.claude/agents"
  echo "mine" > "$HOME/.claude/agents/my-agent.md"

  # Enable the kit (piped confirm), then create the box.
  run bash -c "echo y | '$CLI' kit plan-big-execute-small"
  assert_success
  run "$CLI" run
  assert_success

  # Inside the box: user content first, then box notes, kit section appended.
  run docker exec "$cname" head -1 /home/coder/.claude/CLAUDE.md
  assert_output "MY GLOBAL RULES"
  run docker exec "$cname" cat /home/coder/.claude/CLAUDE.md
  assert_output --partial "Cleat box notes"
  assert_output --partial "Cleat kit: plan-big-execute-small"

  # Agents: the user's own beside the kit's.
  run docker exec "$cname" ls /home/coder/.claude/agents
  assert_output --partial "my-agent.md"
  assert_output --partial "kit-worker.md"

  # All three instruction-surface masks are read-only from inside the cage,
  # even as root: memory, subagents, AND slash commands.
  run docker exec "$cname" sh -c 'echo pwned >> /home/coder/.claude/CLAUDE.md'
  assert_failure
  run docker exec "$cname" sh -c 'echo pwned > /home/coder/.claude/agents/evil.md'
  assert_failure
  run docker exec "$cname" sh -c 'echo pwned > /home/coder/.claude/commands/evil.md'
  assert_failure

  # The host is untouched: no kit content in the real ~/.claude.
  run cat "$HOME/.claude/CLAUDE.md"
  assert_output "MY GLOBAL RULES"
  [ ! -e "$HOME/.claude/agents/kit-worker.md" ]

  # `kit off` regenerates in place: the RUNNING container's bind (same inode)
  # drops the kit section immediately, no restart. The box notes remain: they
  # ride every composed CLAUDE.md, kit or not.
  run bash -c "'$CLI' kit off"
  assert_success
  run docker exec "$cname" head -1 /home/coder/.claude/CLAUDE.md
  assert_output "MY GLOBAL RULES"
  run docker exec "$cname" cat /home/coder/.claude/CLAUDE.md
  refute_output --partial "Cleat kit:"
  assert_output --partial "Cleat box notes"
  run docker exec "$cname" ls /home/coder/.claude/agents
  refute_output --partial "kit-worker.md"

  docker rm -f "$cname" >/dev/null 2>&1 || true
}
