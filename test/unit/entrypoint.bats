#!/usr/bin/env bats
# Tests for docker/entrypoint.sh — the runtime UID/GID remap and the ownership
# fixups that follow it. Per the project rule for scripts that run outside the
# CLI, we execute entrypoint.sh directly with the privileged commands stubbed
# (chown/sed/usermod/id/su), so we can assert behavior without root or a real
# container.
load "../setup"

setup() { _common_setup; }
teardown() { _common_teardown; }

# Run entrypoint.sh with a host UID that differs from the image's build UID
# (1000), which forces the remap path, and with `chown` stubbed to record every
# call. The other privileged commands are harmless no-ops; the final `exec su`
# is replaced by a stub that exits 0.
_run_entrypoint() {
  local stubs="$TEST_TEMP/stubs"
  mkdir -p "$stubs"
  CHOWN_LOG="$TEST_TEMP/chown.log"; : > "$CHOWN_LOG"; export CHOWN_LOG
  RM_LOG="$TEST_TEMP/rm.log"; : > "$RM_LOG"; export RM_LOG

  printf '#!/bin/sh\necho "$@" >> "$CHOWN_LOG"\nexit 0\n' > "$stubs/chown"
  printf '#!/bin/sh\necho 1000\nexit 0\n'                 > "$stubs/id"
  printf '#!/bin/sh\nexit 0\n'                            > "$stubs/sed"
  printf '#!/bin/sh\nexit 0\n'                            > "$stubs/usermod"
  printf '#!/bin/sh\nexit 0\n'                            > "$stubs/groupadd"
  printf '#!/bin/sh\nexit 0\n'                            > "$stubs/getent"
  printf '#!/bin/sh\nexit 0\n'                            > "$stubs/stat"
  printf '#!/bin/sh\nexit 0\n'                            > "$stubs/su"
  # Stub `rm` so the entrypoint's stale-runtime cleanup is observable AND can't
  # touch the real /tmp during tests (the dev box may have a live clip socket).
  printf '#!/bin/sh\necho "$@" >> "$RM_LOG"\nexit 0\n'    > "$stubs/rm"
  chmod +x "$stubs"/*

  local entrypoint="$BATS_TEST_DIRNAME/../../docker/entrypoint.sh"
  run env PATH="$stubs:$PATH" HOST_UID=501 HOST_GID=501 CHOWN_LOG="$CHOWN_LOG" RM_LOG="$RM_LOG" \
    bash "$entrypoint"
}

@test "entrypoint: chowns ~/.local so the runtime user can run claude update" {
  _run_entrypoint
  assert_success
  run cat "$CHOWN_LOG"
  # The native updater writes the launcher symlink + versioned binaries under
  # ~/.local; without this chown the remapped user hits EACCES.
  assert_output --partial "/home/coder/.local"
}

@test "entrypoint: still chowns ~/.claude (auth/sessions) after the remap" {
  _run_entrypoint
  run cat "$CHOWN_LOG"
  assert_output --partial "/home/coder/.claude"
}

@test "entrypoint: chowns ~/.cache so the Claude installer can stage downloads" {
  _run_entrypoint
  assert_success
  run cat "$CHOWN_LOG"
  # The native installer stages each build under ~/.cache/claude/staging before
  # moving it into ~/.local. Baked owned by the build UID and not host-mounted,
  # so without this chown the remapped runtime user hits
  #   EACCES: permission denied, mkdir '/home/coder/.cache/claude/staging/...'
  # and `cleat upgrade-claude` / the on-start update prompt fail.
  assert_output --partial "/home/coder/.cache"
}

@test "entrypoint: clears stale clipboard runtime files before dropping to coder" {
  # v0.13.1: a hard-killed prior session can leave a foreign-owned clip socket in
  # the sticky /tmp (it survives docker stop/start). As root, the entrypoint must
  # remove it so the next clip-daemon starts clean — otherwise the runtime user
  # can't unlink it and clip-daemon spews EPERM every launch.
  _run_entrypoint
  assert_success
  run cat "$RM_LOG"
  assert_output --partial "/tmp/clip.sock"
}

@test "entrypoint: rejects a non-numeric HOST_UID" {
  local stubs="$TEST_TEMP/stubs"
  mkdir -p "$stubs"
  printf '#!/bin/sh\nexit 0\n' > "$stubs/su"
  chmod +x "$stubs"/*
  local entrypoint="$BATS_TEST_DIRNAME/../../docker/entrypoint.sh"
  run env PATH="$stubs:$PATH" HOST_UID="0; rm -rf /" HOST_GID=501 bash "$entrypoint"
  assert_failure
  assert_output --partial "must be numeric"
}
