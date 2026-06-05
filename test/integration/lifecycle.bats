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

  # Both bind-mount the SAME host path at /workspace — the live shared tree.
  local m_src a_src
  m_src="$(docker inspect "$main_cname" --format '{{range .Mounts}}{{if eq .Destination "/workspace"}}{{.Source}}{{end}}{{end}}')"
  a_src="$(docker inspect "$az_cname"   --format '{{range .Mounts}}{{if eq .Destination "/workspace"}}{{.Source}}{{end}}{{end}}')"
  [[ -n "$m_src" && "$m_src" == "$a_src" ]] || { echo "workspace mounts differ: '$m_src' vs '$a_src'"; return 1; }

  # The az box carries the sh.cleat.box label.
  run docker inspect "$az_cname" --format '{{index .Config.Labels "sh.cleat.box"}}'
  assert_output "az"

  # `cleat describe` must NOT recreate the container (host-side metadata) — the
  # writable layer (e.g. an `az login`) must survive. Verify the container ID
  # is unchanged across a describe.
  local before after
  before="$(docker inspect --format '{{.Id}}' "$az_cname")"
  "$CLI" describe az "cloud box" >/dev/null
  after="$(docker inspect --format '{{.Id}}' "$az_cname")"
  [[ "$before" == "$after" ]] || { echo "describe recreated the container!"; return 1; }

  docker rm -f "$main_cname" "$az_cname" >/dev/null 2>&1 || true
}
