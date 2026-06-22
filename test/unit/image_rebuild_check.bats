#!/usr/bin/env bats
# Tests for the on-start image-content drift prompt (_maybe_prompt_image_rebuild).
#
# The prompt is keyed to IMAGE CONTENT, not the CLI version. Each image carries a
# sh.cleat.image-spec integer (_IMAGE_SPEC_VERSION at build/publish time); the CLI
# prompts only when the local image's spec is STRICTLY OLDER than the spec it
# ships. A version-only release (no docker/ change) leaves the spec untouched, so
# it never nags, the whole point of the scheme.
#
# Pre-stamping images (built before sh.cleat.image-spec existed) carry no spec
# label. Their content is inferred from the version they were built at against
# _IMAGE_SPEC_INTRO_VERSION: at/after the intro is today's content (spec 1) and is
# silent; older is offered a refresh. An image with neither label is left alone.
#
# On accept it PULLS the released multi-arch image for this version, falling back
# to a local build only when the prebuilt image isn't published.

load "../setup"

setup() {
  _common_setup
  use_docker_stub
  source_cli

  # Decision logic is what we test, not image_exists / acquisition / docker.
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
  # Tests pin both knobs explicitly so they don't drift as the maintainer bumps
  # the real _IMAGE_SPEC_VERSION over time.
  _IMAGE_SPEC_VERSION=5
  _IMAGE_SPEC_INTRO_VERSION="0.16.3"
  # Default: no spec label and no version label unless a test sets them, so the
  # base case is fail-open (nothing to compare).
  _image_spec_version() { echo ""; }
  _image_cleat_version() { echo ""; }
}

teardown() { _common_teardown; }

# ── guards ───────────────────────────────────────────────────────────────────

@test "rebuild prompt: silent on a non-interactive non-TTY run" {
  _image_spec_version() { echo "1"; }   # older than spec 5
  # Do NOT override _is_tty: false under bats.
  run _maybe_prompt_image_rebuild "cleat-x-12345678"
  assert_success
  refute_output --partial "PULL_CALLED"
  refute_output --partial "BUILD_CALLED"
  refute_output --partial "out of date"
}

@test "rebuild prompt: silent when no image exists" {
  _is_tty() { return 0; }
  image_exists() { return 1; }
  _image_spec_version() { echo "1"; }
  run _maybe_prompt_image_rebuild "cleat-x-12345678"
  assert_success
  refute_output --partial "out of date"
}

# ── spec path: explicit sh.cleat.image-spec label ─────────────────────────────

@test "rebuild prompt: silent when the image spec matches the CLI spec" {
  _is_tty() { return 0; }
  _image_spec_version() { echo "5"; }   # == _IMAGE_SPEC_VERSION
  run _maybe_prompt_image_rebuild "cleat-x-12345678" <<< "y"
  assert_success
  refute_output --partial "out of date"
  refute_output --partial "PULL_CALLED"
}

@test "rebuild prompt: does NOT nag when the image spec is NEWER than the CLI" {
  _is_tty() { return 0; }
  _image_spec_version() { echo "9"; }   # a dev image pulled ahead of the CLI
  run _maybe_prompt_image_rebuild "cleat-x-12345678" <<< "y"
  assert_success
  refute_output --partial "out of date"
  refute_output --partial "PULL_CALLED"
  refute_output --partial "BUILD_CALLED"
}

@test "rebuild prompt: PROMPTS when the image spec is older than the CLI" {
  _is_tty() { return 0; }
  _image_spec_version() { echo "2"; }   # < _IMAGE_SPEC_VERSION (5)
  run _maybe_prompt_image_rebuild "cleat-x-12345678" <<< "n"
  assert_success
  assert_output --partial "out of date"
}

@test "rebuild prompt: a malformed spec label fails open and never nags" {
  _is_tty() { return 0; }
  _image_spec_version() { echo "not-a-number"; }
  run _maybe_prompt_image_rebuild "cleat-x-12345678" <<< "y"
  assert_success
  refute_output --partial "out of date"
  refute_output --partial "PULL_CALLED"
}

@test "rebuild prompt: an older leading-zero spec label prompts with no octal stderr leak" {
  # 08/09 are invalid octal: a bare integer test would print "value too great
  # for base" to stderr on the otherwise-silent start path. Base-10 forcing keeps
  # the comparison correct (8 < 9 prompts) and clean.
  _is_tty() { return 0; }
  _IMAGE_SPEC_VERSION=9
  _image_spec_version() { echo "08"; }
  run _maybe_prompt_image_rebuild "cleat-x-12345678" <<< "n"
  assert_success
  assert_output --partial "out of date"
  refute_output --partial "value too great"
}

@test "rebuild prompt: a newer leading-zero spec label stays silent with no octal stderr leak" {
  _is_tty() { return 0; }
  _IMAGE_SPEC_VERSION=5
  _image_spec_version() { echo "08"; }   # base-10 8, newer than 5
  run _maybe_prompt_image_rebuild "cleat-x-12345678" <<< "y"
  assert_success
  refute_output --partial "out of date"
  refute_output --partial "value too great"
  refute_output --partial "PULL_CALLED"
}

# ── legacy path: no spec label, content inferred from the build version ───────

@test "rebuild prompt: a pre-stamping image at the intro version stays silent" {
  # The migration guarantee: an image built at the last content change carries
  # today's content (spec 1). With the CLI also at spec 1, the cutover to this
  # scheme forces NO recreate. (Pin the CLI to spec 1 to model the cutover.)
  _is_tty() { return 0; }
  _IMAGE_SPEC_VERSION=1
  _image_spec_version() { echo ""; }            # pre-stamping image
  _image_cleat_version() { echo "0.16.3"; }     # == _IMAGE_SPEC_INTRO_VERSION
  run _maybe_prompt_image_rebuild "cleat-x-12345678" <<< "y"
  assert_success
  refute_output --partial "out of date"
  refute_output --partial "PULL_CALLED"
}

@test "rebuild prompt: a pre-stamping image newer than the intro stays silent" {
  _is_tty() { return 0; }
  _IMAGE_SPEC_VERSION=1
  _image_spec_version() { echo ""; }
  _image_cleat_version() { echo "0.16.5"; }     # > intro, same content
  run _maybe_prompt_image_rebuild "cleat-x-12345678" <<< "y"
  assert_success
  refute_output --partial "out of date"
  refute_output --partial "PULL_CALLED"
}

@test "rebuild prompt: a pre-stamping image older than the intro is offered a refresh" {
  _is_tty() { return 0; }
  _IMAGE_SPEC_VERSION=1
  _image_spec_version() { echo ""; }
  _image_cleat_version() { echo "0.16.2"; }     # < intro: genuinely older content
  run _maybe_prompt_image_rebuild "cleat-x-12345678" <<< "n"
  assert_success
  assert_output --partial "out of date"
}

@test "rebuild prompt: a pre-stamping image far older than the intro is offered a refresh" {
  _is_tty() { return 0; }
  _IMAGE_SPEC_VERSION=1
  _image_spec_version() { echo ""; }
  _image_cleat_version() { echo "0.0.1"; }
  run _maybe_prompt_image_rebuild "cleat-x-12345678" <<< "n"
  assert_success
  assert_output --partial "out of date"
}

@test "rebuild prompt: a pre-stamping legacy image is still refreshed under a later CLI spec" {
  # Guards the false-negative the design review flagged: a legacy image must not
  # be grandfathered forever. With the CLI now at spec 7 and a label-less image
  # whose version maps to spec 1, the gap is detected and a refresh is offered.
  _is_tty() { return 0; }
  _IMAGE_SPEC_VERSION=7
  _image_spec_version() { echo ""; }
  _image_cleat_version() { echo "0.16.5"; }     # >= intro: inferred spec 1 < 7
  run _maybe_prompt_image_rebuild "cleat-x-12345678" <<< "n"
  assert_success
  assert_output --partial "out of date"
}

@test "rebuild prompt: an image with neither spec nor version label fails open" {
  _is_tty() { return 0; }
  _image_spec_version() { echo ""; }
  _image_cleat_version() { echo ""; }
  run _maybe_prompt_image_rebuild "cleat-x-12345678" <<< "y"
  assert_success
  refute_output --partial "out of date"
  refute_output --partial "PULL_CALLED"
}

# ── prompt + action ───────────────────────────────────────────────────────────

@test "rebuild prompt: shows the drift and PULLS this version on accept" {
  _is_tty() { return 0; }
  _image_spec_version() { echo "1"; }   # older content
  run _maybe_prompt_image_rebuild "cleat-x-12345678" <<< "y"
  assert_success
  assert_output --partial "out of date"
  assert_output --partial "v${VERSION}"
  # Pulls the prebuilt image for THIS version: a download, not a local rebuild.
  assert_output --partial "PULL_CALLED ${VERSION}"
  refute_output --partial "BUILD_CALLED"
}

@test "rebuild prompt: falls back to a local build when the pull fails" {
  _is_tty() { return 0; }
  _image_spec_version() { echo "1"; }
  _do_pull() { echo "PULL_CALLED $*"; return 1; }   # prebuilt image not available
  run _maybe_prompt_image_rebuild "cleat-x-12345678" <<< "y"
  assert_success
  assert_output --partial "PULL_CALLED ${VERSION}"
  assert_output --partial "BUILD_CALLED"
}

@test "rebuild prompt: empty answer defaults to yes" {
  _is_tty() { return 0; }
  _image_spec_version() { echo "1"; }
  run _maybe_prompt_image_rebuild "cleat-x-12345678" <<< ""
  assert_success
  assert_output --partial "PULL_CALLED"
}

@test "rebuild prompt: declining does NOT acquire a new image" {
  _is_tty() { return 0; }
  _image_spec_version() { echo "1"; }
  run _maybe_prompt_image_rebuild "cleat-x-12345678" <<< "n"
  assert_success
  assert_output --partial "out of date"
  refute_output --partial "PULL_CALLED"
  refute_output --partial "BUILD_CALLED"
}

@test "rebuild prompt: on accept, an existing container is removed so it recreates" {
  _is_tty() { return 0; }
  _image_spec_version() { echo "1"; }
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
  _image_spec_version() { echo "1"; }
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
  _image_spec_version() { echo "1"; }

  _maybe_prompt_image_rebuild "cleat-x-12345678" <<< "n" >/dev/null
  # Second call in the same process must short-circuit (guard set).
  run _maybe_prompt_image_rebuild "cleat-x-12345678" <<< "n"
  assert_success
  refute_output --partial "out of date"
}
