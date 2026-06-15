#!/usr/bin/env bats
# Tests for `cleat upgrade-claude`: re-runs the official installer in a
# throwaway container from the current image and commits the result back,
# durably upgrading the bundled Claude Code without a full rebuild.
load "../setup"

setup() {
  _common_setup
  use_docker_stub
  source_cli
}

teardown() { _common_teardown; }

# ── Channel handling ────────────────────────────────────────────────────────

@test "upgrade-claude: defaults to the 'latest' channel" {
  mock_docker_images "cleat"   # image_exists → true
  mock_docker_ps_a ""          # no container for this project

  run cmd_upgrade_claude
  assert_success
  run assert_docker_run_has "cleat-claude-upgrade" "install.sh"
  assert_success
  run assert_docker_run_has "cleat-claude-upgrade" "bash -s -- latest"
  assert_success
}

@test "upgrade-claude: passes through an explicit channel" {
  mock_docker_images "cleat"
  mock_docker_ps_a ""

  run cmd_upgrade_claude stable
  assert_success
  run assert_docker_run_has "cleat-claude-upgrade" "bash -s -- stable"
  assert_success
}

@test "upgrade-claude: passes through a pinned version" {
  mock_docker_images "cleat"
  mock_docker_ps_a ""

  run cmd_upgrade_claude 2.1.156
  assert_success
  run assert_docker_run_has "cleat-claude-upgrade" "bash -s -- 2.1.156"
  assert_success
}

@test "upgrade-claude: accepts a prerelease version suffix" {
  mock_docker_images "cleat"
  mock_docker_ps_a ""

  run cmd_upgrade_claude 2.1.0-rc.1
  assert_success
  run assert_docker_run_has "cleat-claude-upgrade" "bash -s -- 2.1.0-rc.1"
  assert_success
}

# ── Consolidated success line ────────────────────────────────────────────────

@test "upgrade-claude: folds the version delta into a single success line" {
  mock_docker_images "cleat"
  mock_docker_ps_a ""
  # Stateful stub: first call (before) → old version, second (after) → new.
  local seq="$TEST_TEMP/iclaude.seq"
  echo 0 > "$seq"
  _image_claude_version() {
    local n; n="$(cat "$seq")"; echo $((n + 1)) > "$seq"
    if [[ "$n" -eq 0 ]]; then echo "2.1.156"; else echo "2.1.161"; fi
  }

  run cmd_upgrade_claude latest
  assert_success
  # One consolidated row, not a green check followed by a separate version line.
  assert_output --partial "Claude Code upgraded (2.1.156 → 2.1.161)"
  refute_output --partial "▸ Claude Code 2.1.156"
}

@test "upgrade-claude: success line reports no-change when version is identical" {
  mock_docker_images "cleat"
  mock_docker_ps_a ""
  _image_claude_version() { echo "2.1.161"; }   # before == after

  run cmd_upgrade_claude latest
  assert_success
  assert_output --partial "already at 2.1.161 (no change)"
}

# ── Input validation / injection hardening ──────────────────────────────────

@test "upgrade-claude: rejects a bogus channel before touching docker" {
  mock_docker_images "cleat"
  mock_docker_ps_a ""

  run cmd_upgrade_claude bogus
  assert_failure
  assert_output --partial "Invalid version"
  run docker_run_calls
  refute_output --partial "install.sh"
}

@test "upgrade-claude: rejects a shell-injection channel without running anything" {
  mock_docker_images "cleat"
  mock_docker_ps_a ""

  run cmd_upgrade_claude '2.1.0; rm -rf ~'
  assert_failure
  assert_output --partial "Invalid version"
  run docker_run_calls
  refute_output --partial "install.sh"
}

@test "upgrade-claude: rejects channels with metacharacters" {
  mock_docker_images "cleat"
  mock_docker_ps_a ""

  for bad in 'latest|x' '$(whoami)' '`id`' '../etc' 'a b' '1.2'; do
    run cmd_upgrade_claude "$bad"
    assert_failure
    assert_output --partial "Invalid version"
  done
}

# ── Install command hardening ───────────────────────────────────────────────

@test "upgrade-claude: install command enables pipefail (curl failure can't pass silently)" {
  mock_docker_images "cleat"
  mock_docker_ps_a ""

  run cmd_upgrade_claude
  assert_success
  run assert_docker_run_has "cleat-claude-upgrade" "set -euo pipefail"
  assert_success
}

@test "upgrade-claude: install command verifies the binary before commit" {
  mock_docker_images "cleat"
  mock_docker_ps_a ""

  run cmd_upgrade_claude
  assert_success
  run assert_docker_run_has "cleat-claude-upgrade" "readlink -f /home/coder/.local/bin/claude"
  assert_success
}

# ── Commit ──────────────────────────────────────────────────────────────────

@test "upgrade-claude: commits the result back over the working image" {
  mock_docker_images "cleat"
  mock_docker_ps_a ""

  run cmd_upgrade_claude
  assert_success
  run docker_calls
  assert_output --partial "commit"
  # CMD must be restored on commit or the long-running container would re-run
  # the installer instead of staying alive.
  assert_output --partial 'CMD ["bash"]'
}

# ── Image bootstrap ─────────────────────────────────────────────────────────

@test "upgrade-claude: builds an image first when none exists" {
  mock_docker_ps_a ""
  # Model reality: the image is absent on the first check, then present after
  # the build (the post-build guard must see it exist).
  _IMG_SEEN=0
  image_exists() { _IMG_SEEN=$((_IMG_SEEN + 1)); [[ $_IMG_SEEN -ge 2 ]]; }

  run cmd_upgrade_claude
  assert_success
  run docker_build_calls
  assert_output --partial "docker build"
}

@test "upgrade-claude: aborts if no image exists even after build/pull" {
  mock_docker_ps_a ""
  image_exists() { return 1; }   # image never materializes (pathological)

  run cmd_upgrade_claude
  assert_failure
  assert_output --partial "No"
  assert_output --partial "image available"
}

# ── Failure paths ───────────────────────────────────────────────────────────

@test "upgrade-claude: installer failure aborts without committing" {
  mock_docker_images "cleat"
  mock_docker_ps_a ""
  export DOCKER_RUN_EXIT_CODE=1   # the install `docker run` fails

  run cmd_upgrade_claude
  assert_failure
  assert_output --partial "Upgrade failed"
  # Must NOT commit a half-broken image.
  run docker_calls
  refute_output --partial "docker commit"
}

@test "upgrade-claude: commit failure surfaces as an error" {
  mock_docker_images "cleat"
  mock_docker_ps_a ""
  export DOCKER_COMMIT_EXIT_CODE=1   # install succeeds, commit fails

  run cmd_upgrade_claude
  assert_failure
  assert_output --partial "Upgrade failed"
}

# ── Container recreate ──────────────────────────────────────────────────────

@test "upgrade-claude: notes manual recreate when a container exists (non-TTY)" {
  mock_docker_images "cleat"
  mock_docker_ps_a "cleat-myproj-12345678"

  container_name_for() { echo "cleat-myproj-12345678"; }
  container_exists() { [[ "$1" == "cleat-myproj-12345678" ]]; }

  run cmd_upgrade_claude
  assert_success
  assert_output --partial "to use the new Claude Code"
}

@test "upgrade-claude: cleans up a leftover temp container before running" {
  mock_docker_images "cleat"
  mock_docker_ps_a ""

  run cmd_upgrade_claude
  assert_success
  # The throwaway container is removed both before (self-heal) and after.
  run docker_calls
  assert_output --partial "rm -f cleat-claude-upgrade"
}
