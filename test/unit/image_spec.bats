#!/usr/bin/env bats
# Tripwire: the Docker image build inputs and _IMAGE_SPEC_VERSION must move
# together. This is a deliberate change-detector (like the em-dash and bash-4
# source guards in regressions.bats), NOT a "feature exists" source grep.
#
# The on-start refresh prompt (_maybe_prompt_image_rebuild) only fires when the
# local image's content spec is older than _IMAGE_SPEC_VERSION. If someone edits
# a file that lands in the image (entrypoint, clip/clip-daemon, open-bridge,
# CLAUDE.md, the Dockerfile, a pinned base) but forgets to bump
# _IMAGE_SPEC_VERSION, users would never be offered the fixed image. This test
# fails the moment the build inputs change, forcing a conscious decision: bump
# the spec (real image change) or just update the recorded hash (cosmetic).
# See concept/24-image-spec-versioning.md.

load "../setup"

setup() {
  _common_setup
  source_cli
  DOCKER_DIR="$BATS_TEST_DIRNAME/../../docker"
}

teardown() { _common_teardown; }

# The exact set of files the Dockerfile bakes into the image, in a FIXED order
# so the hash is deterministic across platforms (never rely on find/ls order).
# The Dockerfile is included, so a COPY/structural change trips this too.
_image_inputs_hash() {
  local docker_dir="$1"
  local f paths=()
  for f in Dockerfile clip clip-daemon entrypoint.sh open-bridge CLAUDE.md; do
    paths+=("$docker_dir/$f")
  done
  if command -v sha256sum >/dev/null 2>&1; then
    cat "${paths[@]}" | sha256sum | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then
    cat "${paths[@]}" | shasum -a 256 | cut -d' ' -f1
  else
    cat "${paths[@]}" | openssl dgst -sha256 | sed 's/.*= //'
  fi
}

@test "image spec: build inputs match the recorded hash for this _IMAGE_SPEC_VERSION" {
  local expected="2aecd64569eff24ddfa5c9b959936cafd63b9fc3c8593f20ecd9aa7d0d181209"
  local actual
  actual="$(_image_inputs_hash "$DOCKER_DIR")"
  [[ "$actual" == "$expected" ]] || {
    printf '%s\n' \
      "Docker image build inputs changed." \
      "  expected: $expected" \
      "  actual:   $actual" \
      "" \
      "If this changes the built image, BUMP _IMAGE_SPEC_VERSION in bin/cleat by" \
      "one (so users are offered the refreshed image), then set the expected hash" \
      "above to the actual value. If the change is purely cosmetic and does not" \
      "affect the image, just update the hash. See concept/24-image-spec-versioning.md."
    return 1
  }
}

@test "image spec: the docker build context contains exactly the hashed files" {
  # A new or removed file in docker/ must trip this wire even if the Dockerfile
  # reference is subtle, so the input set can't silently drift from the hash.
  local expected actual
  expected="$(printf '%s\n' CLAUDE.md Dockerfile clip clip-daemon entrypoint.sh open-bridge | sort)"
  actual="$(cd "$DOCKER_DIR" && ls -1A | sort)"
  [[ "$actual" == "$expected" ]] || {
    printf '%s\n' \
      "docker/ contents changed:" \
      "$actual" \
      "" \
      "If a file was added or removed, update _image_inputs_hash and the hash" \
      "test, and bump _IMAGE_SPEC_VERSION. See concept/24-image-spec-versioning.md."
    return 1
  }
}

@test "image spec: _IMAGE_SPEC_VERSION is a positive integer" {
  [[ "$_IMAGE_SPEC_VERSION" =~ ^[1-9][0-9]*$ ]] \
    || { echo "_IMAGE_SPEC_VERSION must be a positive integer, got: $_IMAGE_SPEC_VERSION"; return 1; }
}

@test "image spec: _IMAGE_SPEC_INTRO_VERSION is a dotted X.Y.Z version" {
  [[ "$_IMAGE_SPEC_INTRO_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || { echo "_IMAGE_SPEC_INTRO_VERSION must look like X.Y.Z, got: $_IMAGE_SPEC_INTRO_VERSION"; return 1; }
}
