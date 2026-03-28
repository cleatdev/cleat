#!/usr/bin/env bats
# Tests for docker/clip — the clipboard shim used inside containers

load "../setup"

CLIP="$PROJECT_ROOT/docker/clip"

setup() {
  _common_setup
  CLIP_TEST="$TEST_TEMP/clip_env"
  mkdir -p "$CLIP_TEST/tmp/cleat-clip"

  # Create a test wrapper that overrides paths but uses real logic
  cat > "$CLIP_TEST/test-clip" << WRAPPER
#!/bin/bash
set -euo pipefail
BRIDGE="$CLIP_TEST/tmp/cleat-clip"
SOCK="$CLIP_TEST/tmp/clip.sock"
MAX_PAYLOAD=102400
self="clip"
WRAPPER
  tail -n +19 "$CLIP" >> "$CLIP_TEST/test-clip"
  chmod +x "$CLIP_TEST/test-clip"
}

teardown() { _common_teardown; }

# ── File bridge (primary method) ───────────────────────────────────────────

@test "copies stdin to clipboard via file bridge" {
  touch "$CLIP_TEST/tmp/cleat-clip/.host-ready"
  echo "hello world" | "$CLIP_TEST/test-clip"
  assert_equal "$(cat "$CLIP_TEST/tmp/cleat-clip/clipboard")" "hello world"
}

@test "copies arguments to clipboard" {
  touch "$CLIP_TEST/tmp/cleat-clip/.host-ready"
  "$CLIP_TEST/test-clip" "some text"
  assert_equal "$(cat "$CLIP_TEST/tmp/cleat-clip/clipboard")" "some text"
}

@test "concatenates multiple arguments with spaces" {
  touch "$CLIP_TEST/tmp/cleat-clip/.host-ready"
  "$CLIP_TEST/test-clip" "hello" "world"
  assert_equal "$(cat "$CLIP_TEST/tmp/cleat-clip/clipboard")" "hello world"
}

@test "rejects empty input with error" {
  touch "$CLIP_TEST/tmp/cleat-clip/.host-ready"
  run bash -c 'echo -n "" | "'"$CLIP_TEST/test-clip"'"'
  assert_failure
  assert_output --partial "nothing to copy"
}

@test "atomic write — no leftover temp files" {
  touch "$CLIP_TEST/tmp/cleat-clip/.host-ready"
  echo "atomic" | "$CLIP_TEST/test-clip"
  local leftovers
  leftovers=$(ls "$CLIP_TEST/tmp/cleat-clip"/.clipboard.* 2>/dev/null | wc -l)
  [[ "$leftovers" -eq 0 ]]  || return 1
}

@test "truncates data exceeding MAX_PAYLOAD" {
  touch "$CLIP_TEST/tmp/cleat-clip/.host-ready"

  # Use a small-payload wrapper to test truncation
  cat > "$CLIP_TEST/small-clip" << WRAPPER
#!/bin/bash
set -euo pipefail
BRIDGE="$CLIP_TEST/tmp/cleat-clip"
SOCK="$CLIP_TEST/tmp/clip.sock"
MAX_PAYLOAD=50
self="clip"
tmpfile="\$(mktemp /tmp/clip.XXXXXX)"
trap 'rm -f "\$tmpfile"' EXIT
head -c "\$MAX_PAYLOAD" > "\$tmpfile"
[ -s "\$tmpfile" ] || exit 1
if [ -f "\$BRIDGE/.host-ready" ]; then
  cp "\$tmpfile" "\$BRIDGE/.clipboard.\$\$"
  mv "\$BRIDGE/.clipboard.\$\$" "\$BRIDGE/clipboard"
  exit 0
fi
WRAPPER
  chmod +x "$CLIP_TEST/small-clip"

  python3 -c "print('A' * 100, end='')" | "$CLIP_TEST/small-clip"
  local size
  size=$(wc -c < "$CLIP_TEST/tmp/cleat-clip/clipboard")
  [[ "$size" -eq 50 ]]  || return 1
}

# ── Fallback behavior ──────────────────────────────────────────────────────

@test "fails with message when no bridge, socket, or tty" {
  rm -f "$CLIP_TEST/tmp/cleat-clip/.host-ready"
  run bash -c 'echo "test" | setsid "'"$CLIP_TEST/test-clip"'" 2>&1 </dev/null'
  assert_failure
}

# ── Shim compatibility ─────────────────────────────────────────────────────

@test "xsel -o exits 0 (paste not supported, but doesn't break tools)" {
  ln -sf "$CLIP" "$CLIP_TEST/xsel"
  run "$CLIP_TEST/xsel" -o
  assert_success
  assert_output ""
}

@test "xsel --output exits 0" {
  ln -sf "$CLIP" "$CLIP_TEST/xsel"
  run "$CLIP_TEST/xsel" --output
  assert_success
}

@test "xclip -o exits 0" {
  ln -sf "$CLIP" "$CLIP_TEST/xclip"
  run "$CLIP_TEST/xclip" -o
  assert_success
}

@test "xsel with non-output flags still tries to copy" {
  ln -sf "$CLIP" "$CLIP_TEST/xsel"
  # -bi are not -o or --output, so should attempt copy (and fail without bridge)
  run bash -c 'echo "test" | setsid "'"$CLIP_TEST/xsel"'" -bi 2>&1 </dev/null'
  assert_failure
}
