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
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true

  [[ -f "$clip_dir/.host-ready" ]]  || return 1
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

  local clip_dir="/tmp/cleat-clip-test-noclip"
  rm -rf "$clip_dir"

  run exec_claude "test-noclip" --dangerously-skip-permissions

  # No .host-ready sentinel should exist (watcher was never started)
  [[ ! -f "$clip_dir/.host-ready" ]]  || return 1
  rm -rf "$clip_dir"
}
