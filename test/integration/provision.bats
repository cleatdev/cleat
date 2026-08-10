#!/usr/bin/env bats
# ─────────────────────────────────────────────────────────────────────────────
# Integration: [setup] provisioning (concept/16) against REAL Docker.
#
# Unit tests (test/unit/provision.bats) cover every consent path and the
# docker-command shape with the mock stub. Only an integration test can prove
# the payload actually executes for real inside a freshly created box: a real
# file lands on disk, as the real `coder` user, and the run-once marker is
# left behind.
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
  INT_PROJECT="$TEST_TEMP/int-setup-project"
  mkdir -p "$INT_PROJECT"
  INT_CNAME=""
}

teardown() {
  if [[ -n "$INT_CNAME" ]]; then
    docker rm -f "$INT_CNAME" >/dev/null 2>&1 || true
  fi
  "$CLI" untrust "$INT_PROJECT" >/dev/null 2>&1 || true
  _common_teardown
}

@test "integration: [setup] provisioning runs for real on a freshly created box" {
  # Caps-less .cleat: only [setup], nothing to approve on the caps side.
  cat > "$INT_PROJECT/.cleat" << 'EOF'
[setup]
printf ok > /tmp/provisioned.txt
EOF

  cd "$INT_PROJECT"
  export CLEAT_TRUST_SETUP=1
  run "$CLI" run
  assert_success

  INT_CNAME="$(cli_call container_name_for '$INT_PROJECT')"

  # The provisioning command actually ran, as coder, inside the real box.
  run docker exec "$INT_CNAME" cat /tmp/provisioned.txt
  assert_success
  assert_output "ok"

  # The run-once marker was left behind (non-empty: it holds the payload hash).
  run docker exec "$INT_CNAME" cat /home/coder/.cleat-setup-applied
  assert_success
  refute_output ""
}
