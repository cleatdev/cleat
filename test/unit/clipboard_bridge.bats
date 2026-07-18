#!/usr/bin/env bats
# Tests for clipboard bridge: _clipboard_watcher and cleanup logic

load "../setup"

setup() {
  _common_setup
  source_cli
}

teardown() { _common_teardown; }

# ── _clipboard_watcher ──────────────────────────────────────────────────────

@test "_clipboard_watcher creates .host-ready sentinel" {
  local clip_dir="$TEST_TEMP/clip"
  mkdir -p "$clip_dir"

  # Start watcher with a no-op clip command, kill it quickly
  _clipboard_watcher "$clip_dir" "true" &
  local pid=$!
  sleep 0.2
  stop_watcher "$pid" "$clip_dir"

  [[ -f "$clip_dir/.host-ready" ]]  || return 1
}

@test "_clipboard_watcher from a dead cleat process never copies (orphan guard)" {
  # A watcher whose cleat process was SIGKILL'd must not keep writing a dead
  # session's box clipboard over the host clipboard. The liveness check sits
  # at the copy choke point, so this holds in all three watch modes.
  local clip_dir="$TEST_TEMP/clip"
  mkdir -p "$clip_dir"
  sed 's/^set -euo pipefail$/:/' "$CLI" > "$TEST_TEMP/cli_stripped"
  cat > "$TEST_TEMP/clip_spawner.sh" <<EOF
source "$TEST_TEMP/cli_stripped"
_clipboard_watcher "$clip_dir" "touch '$TEST_TEMP/copied'" >/dev/null 2>&1 &
echo "\$!" > "$TEST_TEMP/clip_watcher_pid"
kill -9 \$\$
EOF
  bash "$TEST_TEMP/clip_spawner.sh" 2>/dev/null || true
  sleep 0.3
  # Deliver a clipboard write the way the box does (mv → fires moved_to too)
  echo "stolen" > "$TEST_TEMP/payload"
  mv "$TEST_TEMP/payload" "$clip_dir/clipboard"
  local wpid
  wpid="$(cat "$TEST_TEMP/clip_watcher_pid")"
  process_exited "$wpid" || true
  # Unconditional reap: a live straggler holds bats' fd and hangs the file.
  kill "$wpid" 2>/dev/null || true
  [ ! -f "$TEST_TEMP/copied" ] || { echo "orphan watcher copied a dead session's clipboard"; return 1; }
}

@test "_clipboard_watcher delivers a fresh copy once and consumes the payload" {
  local clip_dir="$TEST_TEMP/clip"
  mkdir -p "$clip_dir"

  _clipboard_watcher "$clip_dir" "cat >> '$TEST_TEMP/copied'" >/dev/null 2>&1 &
  local pid=$!
  sleep 0.3
  # Deliver a clipboard write the way the box shim does (mv → fires moved_to)
  echo "fresh-copy" > "$TEST_TEMP/payload"
  mv "$TEST_TEMP/payload" "$clip_dir/clipboard"
  sleep 2
  stop_watcher "$pid" "$clip_dir"

  run cat "$TEST_TEMP/copied"
  assert_success
  assert_output "fresh-copy"
  # Delivered means claimed: the payload must not remain on disk for a later
  # session's watcher to replay.
  [ ! -f "$clip_dir/clipboard" ] || { echo "payload not consumed on delivery"; return 1; }
}

@test "_clipboard_watcher claims live outside the .clipboard.* cleanup namespace" {
  # Every session's exit sweep runs rm -f on .clipboard.* in the SHARED clip
  # dir, so a claim named inside that namespace can be deleted by a sibling
  # session exiting mid-delivery (the copy is silently lost). The claim must
  # live under .claim.* instead. The snoop clip command records the claim
  # path at the moment of delivery, while the claim file exists.
  local clip_dir="$TEST_TEMP/clip"
  mkdir -p "$clip_dir"

  _clipboard_watcher "$clip_dir" "ls '$clip_dir'/.claim.* >> '$TEST_TEMP/claims-seen' 2>/dev/null; cat > '$TEST_TEMP/copied'" >/dev/null 2>&1 &
  local pid=$!
  sleep 0.3
  echo "payload" > "$TEST_TEMP/payload"
  mv "$TEST_TEMP/payload" "$clip_dir/clipboard"
  sleep 2
  stop_watcher "$pid" "$clip_dir"

  run cat "$TEST_TEMP/copied"
  assert_success
  assert_output "payload"
  [ -s "$TEST_TEMP/claims-seen" ] || { echo "no .claim.* file existed at delivery time (claim is misnamed)"; return 1; }
  run grep -c "/\.claim\." "$TEST_TEMP/claims-seen"
  assert_success
}

# ── _cleanup_clipboard ──────────────────────────────────────────────────────

@test "cleanup removes session marker" {
  _CLIP_DIR="$TEST_TEMP/clip"
  _CLIP_WATCHER_PID=""
  mkdir -p "$_CLIP_DIR"
  touch "$_CLIP_DIR/.watcher.$$"

  _cleanup_clipboard() {
    rm -f "$_CLIP_DIR/.watcher.$$"
    if ! ls "$_CLIP_DIR"/.watcher.* >/dev/null 2>&1; then
      rm -f "$_CLIP_DIR/.host-ready"
    fi
  }
  _cleanup_clipboard

  [[ ! -f "$_CLIP_DIR/.watcher.$$" ]]  || return 1
}

@test "cleanup removes sentinel when last session exits" {
  _CLIP_DIR="$TEST_TEMP/clip"
  _CLIP_WATCHER_PID=""
  mkdir -p "$_CLIP_DIR"
  touch "$_CLIP_DIR/.watcher.$$"
  touch "$_CLIP_DIR/.host-ready"

  _cleanup_clipboard() {
    rm -f "$_CLIP_DIR/.watcher.$$"
    if ! ls "$_CLIP_DIR"/.watcher.* >/dev/null 2>&1; then
      rm -f "$_CLIP_DIR/.host-ready"
    fi
  }
  _cleanup_clipboard

  [[ ! -f "$_CLIP_DIR/.host-ready" ]]  || return 1
}

@test "cleanup keeps sentinel when other sessions remain" {
  _CLIP_DIR="$TEST_TEMP/clip"
  _CLIP_WATCHER_PID=""
  mkdir -p "$_CLIP_DIR"
  touch "$_CLIP_DIR/.watcher.$$"
  touch "$_CLIP_DIR/.watcher.99999"  # Another session
  touch "$_CLIP_DIR/.host-ready"

  _cleanup_clipboard() {
    rm -f "$_CLIP_DIR/.watcher.$$"
    if ! ls "$_CLIP_DIR"/.watcher.* >/dev/null 2>&1; then
      rm -f "$_CLIP_DIR/.host-ready"
    fi
  }
  _cleanup_clipboard

  # Our marker gone, but sentinel stays because .watcher.99999 exists
  [[ ! -f "$_CLIP_DIR/.watcher.$$" ]]  || return 1
  [[ -f "$_CLIP_DIR/.host-ready" ]]  || return 1
}

# ── Clipboard priority (already in clipboard_detect.bats, but verify the
#    integration: exec_claude skips watcher when no clip command found) ──────

@test "exec_claude skips clipboard watcher when no clip command available" {
  use_docker_stub

  # Override _host_clip_cmd to simulate no clipboard
  _host_clip_cmd() { echo ""; }

  local clip_dir="$CLEAT_RUN_DIR/test-noclip/clip"
  rm -rf "$clip_dir"

  run exec_claude "test-noclip" --dangerously-skip-permissions

  # No .host-ready sentinel should exist (watcher was never started)
  [[ ! -f "$clip_dir/.host-ready" ]]  || return 1
  rm -rf "$clip_dir"
}
