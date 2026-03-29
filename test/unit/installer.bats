#!/usr/bin/env bats
load "../setup"

setup() {
  _common_setup

  # Create a fake cleat repo in TEST_TEMP
  FAKE_REPO="$TEST_TEMP/fake-cleat"
  mkdir -p "$FAKE_REPO/bin"
  cat > "$FAKE_REPO/bin/cleat" << 'CLIEOF'
#!/usr/bin/env bash
VERSION="0.4.0"
echo "cleat v$VERSION"
CLIEOF
  chmod +x "$FAKE_REPO/bin/cleat"

  # Copy installer into fake repo (it uses BASH_SOURCE to find bin/cleat)
  cp "$PROJECT_ROOT/install.sh" "$FAKE_REPO/install.sh"

  # Override BIN_DIR to a writable temp location (avoid needing sudo)
  FAKE_BIN="$TEST_TEMP/bin"
  mkdir -p "$FAKE_BIN"
}

teardown() { _common_teardown; }

# ── --help ────────────────────────────────────────────────────────────────

@test "installer: --help shows usage" {
  run bash "$FAKE_REPO/install.sh" --help
  assert_success
  assert_output --partial "Usage:"
  assert_output --partial "--local"
}

# ── unknown flag ──────────────────────────────────────────────────────────

@test "installer: unknown flag exits 1" {
  run bash "$FAKE_REPO/install.sh" --bogus
  assert_failure
  assert_output --partial "Unknown option"
}

# ── --local: happy path ──────────────────────────────────────────────────

@test "installer --local: creates symlink to local bin/cleat" {
  # Patch the installer to use our writable BIN_DIR
  local patched="$TEST_TEMP/install_patched.sh"
  sed 's|BIN_DIR="/usr/local/bin"|BIN_DIR="'"$FAKE_BIN"'"|' "$FAKE_REPO/install.sh" > "$patched"
  cp "$patched" "$FAKE_REPO/install.sh"

  run bash "$FAKE_REPO/install.sh" --local
  assert_success
  assert_output --partial "Using local source"
  assert_output --partial "v0.4.0"
  assert_output --partial "Linked"

  # Verify symlink exists and points to the right place
  [[ -L "$FAKE_BIN/cleat" ]]
  local target
  target="$(readlink "$FAKE_BIN/cleat")"
  [[ "$target" == "$FAKE_REPO/bin/cleat" ]]
}

@test "installer --local: symlink is absolute path" {
  local patched="$TEST_TEMP/install_patched.sh"
  sed 's|BIN_DIR="/usr/local/bin"|BIN_DIR="'"$FAKE_BIN"'"|' "$FAKE_REPO/install.sh" > "$patched"
  cp "$patched" "$FAKE_REPO/install.sh"

  bash "$FAKE_REPO/install.sh" --local >/dev/null 2>&1
  local target
  target="$(readlink "$FAKE_BIN/cleat")"
  # Must be absolute (starts with /)
  [[ "$target" == /* ]]
}

@test "installer --local: shows dev install message" {
  local patched="$TEST_TEMP/install_patched.sh"
  sed 's|BIN_DIR="/usr/local/bin"|BIN_DIR="'"$FAKE_BIN"'"|' "$FAKE_REPO/install.sh" > "$patched"
  cp "$patched" "$FAKE_REPO/install.sh"

  run bash "$FAKE_REPO/install.sh" --local
  assert_output --partial "Local dev install"
  assert_output --partial "take effect immediately"
  assert_output --partial "without --local"
}

# ── --local: error case ──────────────────────────────────────────────────

@test "installer --local: fails when bin/cleat missing" {
  rm "$FAKE_REPO/bin/cleat"
  run bash "$FAKE_REPO/install.sh" --local
  assert_failure
  assert_output --partial "bin/cleat not found"
}

# ── --local: overwrite existing symlink ──────────────────────────────────

@test "installer --local: overwrites existing symlink" {
  local patched="$TEST_TEMP/install_patched.sh"
  sed 's|BIN_DIR="/usr/local/bin"|BIN_DIR="'"$FAKE_BIN"'"|' "$FAKE_REPO/install.sh" > "$patched"
  cp "$patched" "$FAKE_REPO/install.sh"

  # Create an existing symlink pointing somewhere else
  ln -sf "/tmp/old-cleat" "$FAKE_BIN/cleat"

  run bash "$FAKE_REPO/install.sh" --local
  assert_success

  local target
  target="$(readlink "$FAKE_BIN/cleat")"
  [[ "$target" == "$FAKE_REPO/bin/cleat" ]]
}
