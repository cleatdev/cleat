#!/usr/bin/env bats
load "../setup"

setup() {
  _common_setup

  # Create a fake cleat repo in TEST_TEMP
  FAKE_REPO="$TEST_TEMP/fake-cleat"
  mkdir -p "$FAKE_REPO/bin"
  cat > "$FAKE_REPO/bin/cleat" << 'CLIEOF'
#!/usr/bin/env bash
VERSION="0.5.0"
echo "cleat v$VERSION"
CLIEOF
  chmod +x "$FAKE_REPO/bin/cleat"

  # Copy installer into fake repo (it uses BASH_SOURCE to find bin/cleat)
  cp "$PROJECT_ROOT/install.sh" "$FAKE_REPO/install.sh"

  # Override BIN_DIR to a writable temp location (avoid needing sudo)
  FAKE_BIN="$TEST_TEMP/bin"
  mkdir -p "$FAKE_BIN"
}

# Patch installer to use test-local paths (writable BIN_DIR + custom INSTALL_DIR)
_patch_installer() {
  local install_dir="${1:-$TEST_TEMP/dot-cleat}"
  local patched="$FAKE_REPO/install.sh"
  sed -i "s|BIN_DIR=\"/usr/local/bin\"|BIN_DIR=\"$FAKE_BIN\"|" "$patched"
  sed -i "s|INSTALL_DIR=\"\$HOME/.cleat\"|INSTALL_DIR=\"$install_dir\"|" "$patched"
}

# Create a fake git repo at a path with a tagged bin/cleat
_create_fake_install() {
  local dir="$1" tag="${2:-v0.5.0}"
  mkdir -p "$dir/bin"
  cp "$FAKE_REPO/bin/cleat" "$dir/bin/cleat"
  chmod +x "$dir/bin/cleat"
  git -C "$dir" init --quiet
  git -C "$dir" add -A
  git -C "$dir" commit -m "init" --quiet
  git -C "$dir" tag "$tag"
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
  assert_output --partial "v0.5.0"
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

# ── Remote mode: update existing installation ────────────────────────────

@test "installer remote: update shows success when checkout works" {
  local install_dir="$TEST_TEMP/dot-cleat"
  _create_fake_install "$install_dir" "v0.5.0"
  _patch_installer "$install_dir"

  run bash "$FAKE_REPO/install.sh"
  assert_success
  assert_output --partial "Updated to v0.5.0"
  assert_output --partial "Ready!"
}

@test "installer remote: update with no tags shows warning" {
  local install_dir="$TEST_TEMP/dot-cleat"
  mkdir -p "$install_dir/bin"
  cp "$FAKE_REPO/bin/cleat" "$install_dir/bin/cleat"
  chmod +x "$install_dir/bin/cleat"
  git -C "$install_dir" init --quiet
  git -C "$install_dir" add -A
  git -C "$install_dir" commit -m "init" --quiet
  # No tags — latest_tag_local returns empty
  _patch_installer "$install_dir"

  run bash "$FAKE_REPO/install.sh"
  assert_success
  assert_output --partial "No tags found"
}

@test "installer remote: update with failed checkout shows error" {
  local install_dir="$TEST_TEMP/dot-cleat"
  _create_fake_install "$install_dir" "v0.5.0"
  _patch_installer "$install_dir"

  # Break checkout by making git checkout always fail
  local fake_git="$TEST_TEMP/fake-git-bin"
  mkdir -p "$fake_git"
  cat > "$fake_git/git" << 'GITEOF'
#!/usr/bin/env bash
# Pass through everything except checkout
for arg in "$@"; do
  if [[ "$arg" == "checkout" ]]; then
    exit 1
  fi
done
exec /usr/bin/git "$@"
GITEOF
  chmod +x "$fake_git/git"

  run env PATH="$fake_git:$PATH" bash "$FAKE_REPO/install.sh"
  assert_failure
  assert_output --partial "Failed to checkout"
}

@test "installer remote: non-git directory shows error" {
  local install_dir="$TEST_TEMP/dot-cleat"
  mkdir -p "$install_dir/bin"
  # Directory exists but no .git
  _patch_installer "$install_dir"

  run bash "$FAKE_REPO/install.sh"
  assert_failure
  assert_output --partial "not a git repository"
}

@test "installer remote: spinner never orphaned on update failure" {
  local install_dir="$TEST_TEMP/dot-cleat"
  _create_fake_install "$install_dir" "v0.5.0"
  _patch_installer "$install_dir"

  # Make checkout fail
  local fake_git="$TEST_TEMP/fake-git-bin"
  mkdir -p "$fake_git"
  cat > "$fake_git/git" << 'GITEOF'
#!/usr/bin/env bash
for arg in "$@"; do
  if [[ "$arg" == "checkout" ]]; then
    exit 1
  fi
done
exec /usr/bin/git "$@"
GITEOF
  chmod +x "$fake_git/git"

  run env PATH="$fake_git:$PATH" bash "$FAKE_REPO/install.sh"
  # Must show a proper error message, not end mid-spinner
  assert_output --partial "Failed to checkout"
  # No raw spinner frames in final output (spinner was cleaned up)
  refute_output --partial "⠋"
  refute_output --partial "⠼"
}
