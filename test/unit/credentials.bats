#!/usr/bin/env bats
# ── macOS Keychain → box OAuth credential bridge ──────────────────────────────
#
# macOS keeps Claude Code's OAuth login in the login Keychain, NOT in
# ~/.claude/.credentials.json. The box only sees the mounted ~/.claude dir, so a
# freshly-auth'd host still re-prompted inside the box ("Auth shared" was a lie
# on macOS). _seed_macos_credentials materializes the Keychain blob into the
# file Claude reads on Linux, but only when the box has no token yet (never
# clobbering a fresher in-box token, and never running on Linux hosts where the
# file already exists). See bin/cleat (_is_macos / _macos_keychain_credentials /
# _seed_macos_credentials).
load "../setup"

setup() {
  _common_setup
  use_docker_stub
  source_cli
  CRED="${HOME}/.claude/.credentials.json"
  # A realistic credential blob (we treat it opaquely — written verbatim).
  BLOB='{"claudeAiOauth":{"accessToken":"sk-ant-oat01-abc","refreshToken":"rt-xyz","expiresAt":1234567890,"scopes":["user:inference"],"subscriptionType":"max"}}'
}
teardown() { _common_teardown; }

# ── _is_macos ─────────────────────────────────────────────────────────────────

@test "is_macos: true under a darwin OSTYPE" {
  OSTYPE="darwin24"
  run _is_macos
  assert_success
}

@test "is_macos: false under a linux OSTYPE" {
  OSTYPE="linux-gnu"
  # uname here is the test host (Linux); both signals must be non-darwin.
  run _is_macos
  assert_failure
}

# ── _macos_keychain_credentials ──────────────────────────────────────────────

@test "keychain: reads the blob from the primary service name" {
  local bin="$TEST_TEMP/kc-bin"; mkdir -p "$bin"
  cat > "$bin/security" <<EOF
#!/usr/bin/env bash
# Emit the blob only for the primary service; fail otherwise.
if [[ "\$*" == *"Claude Code-credentials"* ]]; then printf '%s' '$BLOB'; exit 0; fi
exit 44
EOF
  chmod +x "$bin/security"
  PATH="$bin:$PATH" run _macos_keychain_credentials
  assert_success
  assert_output "$BLOB"
}

@test "keychain: falls back to the legacy 'Claude Code' service name" {
  local bin="$TEST_TEMP/kc-bin"; mkdir -p "$bin"
  cat > "$bin/security" <<EOF
#!/usr/bin/env bash
# Primary fails (errSecItemNotFound); only the legacy name has it.
if [[ "\$*" == *"Claude Code-credentials"* ]]; then exit 44; fi
if [[ "\$*" == *"Claude Code"* ]]; then printf '%s' '$BLOB'; exit 0; fi
exit 44
EOF
  chmod +x "$bin/security"
  PATH="$bin:$PATH" run _macos_keychain_credentials
  assert_success
  assert_output "$BLOB"
}

@test "keychain: returns failure when security is absent" {
  # No `security` on PATH (Linux test host) → command -v guard fails.
  run _macos_keychain_credentials
  assert_failure
}

@test "keychain: returns failure when the item is not found (empty output)" {
  local bin="$TEST_TEMP/kc-bin"; mkdir -p "$bin"
  printf '#!/usr/bin/env bash\nexit 44\n' > "$bin/security"
  chmod +x "$bin/security"
  PATH="$bin:$PATH" run _macos_keychain_credentials
  assert_failure
}

# ── _seed_macos_credentials ──────────────────────────────────────────────────

@test "seed: writes the keychain blob into ~/.claude/.credentials.json on macOS" {
  _is_macos() { return 0; }
  _macos_keychain_credentials() { printf '%s' "$BLOB"; }
  rm -f "$CRED"
  _seed_macos_credentials
  [[ -f "$CRED" ]] || { echo "creds file not created"; return 1; }
  run cat "$CRED"
  assert_output "$BLOB"
  [[ "$_SEEDED_CREDS" == "1" ]] || { echo "_SEEDED_CREDS not set"; return 1; }
}

@test "seed: the written creds file is mode 600 (token must not be world-readable)" {
  _is_macos() { return 0; }
  _macos_keychain_credentials() { printf '%s' "$BLOB"; }
  rm -f "$CRED"
  _seed_macos_credentials
  local mode
  mode="$(stat -c '%a' "$CRED" 2>/dev/null || stat -f '%Lp' "$CRED" 2>/dev/null)"
  assert_equal "$mode" "600"
}

@test "seed: never clobbers an existing (possibly fresher) in-box token" {
  _is_macos() { return 0; }
  _macos_keychain_credentials() { printf '%s' "$BLOB"; }   # keychain has a DIFFERENT token
  mkdir -p "${HOME}/.claude"
  printf '%s' '{"claudeAiOauth":{"accessToken":"IN-BOX-FRESH"}}' > "$CRED"
  _seed_macos_credentials
  run cat "$CRED"
  assert_output --partial "IN-BOX-FRESH"
  refute_output --partial "sk-ant-oat01-abc"
}

@test "seed: no-op off macOS (Linux keeps its existing dir-mounted creds file)" {
  _is_macos() { return 1; }
  _macos_keychain_credentials() { printf '%s' "$BLOB"; }   # would be used if it ran
  rm -f "$CRED"
  _seed_macos_credentials
  [[ ! -f "$CRED" ]] || { echo "must not write a creds file off macOS"; return 1; }
}

@test "seed: silent no-op when the keychain has nothing" {
  _is_macos() { return 0; }
  _macos_keychain_credentials() { return 1; }
  rm -f "$CRED"
  run _seed_macos_credentials
  assert_success
  [[ ! -f "$CRED" ]] || { echo "must not create an empty creds file"; return 1; }
}

@test "seed: refuses to write a non-JSON-object blob (never poison the creds file)" {
  _is_macos() { return 0; }
  _macos_keychain_credentials() { printf '%s' 'errSecInteractionNotAllowed'; }
  rm -f "$CRED"
  _seed_macos_credentials
  [[ ! -f "$CRED" ]] || { echo "wrote a non-JSON creds file"; return 1; }
}

@test "seed: leaves no .tmp file behind on the reject path" {
  _is_macos() { return 0; }
  _macos_keychain_credentials() { printf '%s' 'not json'; }
  rm -f "$CRED"
  _seed_macos_credentials
  run bash -c "ls ${HOME}/.claude/.credentials.json.tmp.* 2>/dev/null | wc -l | tr -d ' '"
  assert_output "0"
}
