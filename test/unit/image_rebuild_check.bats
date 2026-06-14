#!/usr/bin/env bats
# Tests for the on-start image-version drift prompt (_maybe_prompt_image_rebuild):
# when the local image was built by an OLDER Cleat than the running CLI, offer to
# update it (and recreate this project's container) before starting — mirroring
# the Claude-update and config-drift prompts. Replaces the old static notice box.
# On accept it PULLS the released multi-arch image for this version (a fast
# download of the exact tested setup), falling back to a local build only when
# the prebuilt image isn't published — not the old unconditional local rebuild.

load "../setup"

setup() {
  _common_setup
  use_docker_stub
  source_cli

  # Decision logic is what we test — not image_exists / acquisition / docker.
  image_exists() { return 0; }
  # The acquisition chain on accept is `_do_pull "$VERSION" || _do_build`. Mock
  # both halves so we can assert pull-is-tried-first and the build fallback.
  _do_pull() { echo "PULL_CALLED $*"; return 0; }
  _do_build() { echo "BUILD_CALLED"; }
  # Default: no existing container (accept path skips the rm block).
  container_exists() { return 1; }
  is_running() { return 1; }
  # Fresh guard per test (the real global persists once set).
  _REBUILD_PROMPTED=0
}

teardown() { _common_teardown; }

# ── guards ───────────────────────────────────────────────────────────────────

@test "rebuild prompt: silent on a non-interactive (non-TTY) run" {
  _image_cleat_version() { echo "0.0.1"; }   # older than VERSION
  # Do NOT override _is_tty — false under bats.
  run _maybe_prompt_image_rebuild "cleat-x-12345678"
  assert_success
  refute_output --partial "PULL_CALLED"
  refute_output --partial "BUILD_CALLED"
  refute_output --partial "outdated"
}

@test "rebuild prompt: silent when no image exists" {
  _is_tty() { return 0; }
  image_exists() { return 1; }
  _image_cleat_version() { echo "0.0.1"; }
  run _maybe_prompt_image_rebuild "cleat-x-12345678"
  assert_success
  refute_output --partial "outdated"
}

@test "rebuild prompt: silent when image version matches the CLI" {
  _is_tty() { return 0; }
  _image_cleat_version() { echo "$VERSION"; }
  run _maybe_prompt_image_rebuild "cleat-x-12345678"
  assert_success
  refute_output --partial "outdated"
}

@test "rebuild prompt: does NOT nag when the image is NEWER than the CLI" {
  _is_tty() { return 0; }
  _image_cleat_version() { echo "99.0.0"; }   # newer than VERSION
  run _maybe_prompt_image_rebuild "cleat-x-12345678" <<< "y"
  assert_success
  refute_output --partial "PULL_CALLED"
  refute_output --partial "BUILD_CALLED"
  refute_output --partial "outdated"
}

# ── prompt + action ───────────────────────────────────────────────────────────

@test "rebuild prompt: shows the drift and PULLS this version on accept" {
  _is_tty() { return 0; }
  _image_cleat_version() { echo "0.0.1"; }
  run _maybe_prompt_image_rebuild "cleat-x-12345678" <<< "y"
  assert_success
  assert_output --partial "Cleat image is outdated"
  assert_output --partial "v0.0.1"
  assert_output --partial "v${VERSION}"
  # Pulls the prebuilt image for THIS version — a download, not a local rebuild.
  assert_output --partial "PULL_CALLED ${VERSION}"
  refute_output --partial "BUILD_CALLED"
}

@test "rebuild prompt: falls back to a local build when the pull fails (unpublished version)" {
  _is_tty() { return 0; }
  _image_cleat_version() { echo "0.0.1"; }
  _do_pull() { echo "PULL_CALLED $*"; return 1; }   # prebuilt image not available
  run _maybe_prompt_image_rebuild "cleat-x-12345678" <<< "y"
  assert_success
  assert_output --partial "PULL_CALLED ${VERSION}"
  assert_output --partial "BUILD_CALLED"
}

@test "rebuild prompt: empty answer defaults to yes" {
  _is_tty() { return 0; }
  _image_cleat_version() { echo "0.0.1"; }
  run _maybe_prompt_image_rebuild "cleat-x-12345678" <<< ""
  assert_success
  assert_output --partial "PULL_CALLED"
}

@test "rebuild prompt: declining does NOT acquire a new image" {
  _is_tty() { return 0; }
  _image_cleat_version() { echo "0.0.1"; }
  run _maybe_prompt_image_rebuild "cleat-x-12345678" <<< "n"
  assert_success
  assert_output --partial "Cleat image is outdated"
  refute_output --partial "PULL_CALLED"
  refute_output --partial "BUILD_CALLED"
}

@test "rebuild prompt: on accept, an existing container is removed so it recreates" {
  _is_tty() { return 0; }
  _image_cleat_version() { echo "0.0.1"; }
  container_exists() { return 0; }
  is_running() { return 1; }

  run _maybe_prompt_image_rebuild "cleat-x-12345678" <<< "y"
  assert_success
  assert_output --partial "PULL_CALLED"
  run docker_calls
  assert_output --partial "rm -f cleat-x-12345678"
}

@test "rebuild prompt: on accept, the container's stale run-dir is wiped" {
  _is_tty() { return 0; }
  _image_cleat_version() { echo "0.0.1"; }
  container_exists() { return 0; }
  is_running() { return 1; }
  # A leftover overlay/clip/hooks dir must be cleared so the recreated container
  # doesn't bind a stale source.
  mkdir -p "$CLEAT_RUN_DIR/cleat-x-12345678/settings"
  echo '{}' > "$CLEAT_RUN_DIR/cleat-x-12345678/settings/settings.json"

  _maybe_prompt_image_rebuild "cleat-x-12345678" <<< "y" >/dev/null
  [[ ! -d "$CLEAT_RUN_DIR/cleat-x-12345678" ]] \
    || { echo "REGRESSION: run-dir not removed on rebuild-recreate"; return 1; }
}

@test "rebuild prompt: runs at most once per process" {
  _is_tty() { return 0; }
  _image_cleat_version() { echo "0.0.1"; }

  _maybe_prompt_image_rebuild "cleat-x-12345678" <<< "n" >/dev/null
  # Second call in the same process must short-circuit (guard set).
  run _maybe_prompt_image_rebuild "cleat-x-12345678" <<< "n"
  assert_success
  refute_output --partial "outdated"
}
