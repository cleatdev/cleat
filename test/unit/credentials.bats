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
  # A realistic credential blob (we treat it opaquely, written verbatim).
  BLOB='{"claudeAiOauth":{"accessToken":"sk-ant-oat01-abc","refreshToken":"rt-xyz","expiresAt":1234567890,"scopes":["user:inference"],"subscriptionType":"max"}}'
}
teardown() { _common_teardown; }

# ── _is_macos ─────────────────────────────────────────────────────────────────
# Two signals: OSTYPE or `uname -s`. These tests override `uname` so they assert
# the same result on a Linux OR a macOS CI host (the real macOS runner's uname is
# Darwin, which would otherwise leak into the "false" case).

@test "is_macos: true under a darwin OSTYPE (OSTYPE signal alone, regardless of host)" {
  uname() { echo "Linux"; }   # prove OSTYPE alone is enough; don't rely on the host
  OSTYPE="darwin24"
  run _is_macos
  assert_success
}

@test "is_macos: true via the uname fallback when OSTYPE is not darwin" {
  uname() { echo "Darwin"; }
  OSTYPE="linux-gnu"
  run _is_macos
  assert_success
}

@test "is_macos: false when neither OSTYPE nor uname is darwin" {
  uname() { echo "Linux"; }   # host-independent; a macOS runner's uname must not leak in
  OSTYPE="linux-gnu"
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

@test "seed: never clobbers an existing, still-valid in-box token (even if the Keychain is fresher)" {
  _is_macos() { return 0; }
  # In-box token is still VALID; the Keychain's is even fresher. The box refreshes
  # its own long-lived token (concept/23), so a valid file is never overwritten.
  _macos_keychain_credentials() { printf '%s' '{"claudeAiOauth":{"accessToken":"KC-EVEN-FRESHER","expiresAt":9000000000}}'; }
  mkdir -p "${HOME}/.claude"
  printf '%s' '{"claudeAiOauth":{"accessToken":"IN-BOX-VALID","expiresAt":5000000000}}' > "$CRED"
  _CLEAT_NOW_S=2000000 _seed_macos_credentials   # now_ms 2e9: file (5e9) valid, kc (9e9) fresher
  run cat "$CRED"
  assert_output --partial "IN-BOX-VALID"
  refute_output --partial "KC-EVEN-FRESHER"
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

# ── _oauth_expires_at ────────────────────────────────────────────────────────

@test "oauth_expires_at: extracts the ms epoch from a credential blob" {
  local r
  r="$(printf '%s' '{"claudeAiOauth":{"accessToken":"x","expiresAt":1719000000000,"scopes":["a"]}}' | _oauth_expires_at)"
  assert_equal "$r" "1719000000000"
}

@test "oauth_expires_at: empty when there is no expiresAt" {
  local r
  r="$(printf '%s' '{"claudeAiOauth":{"accessToken":"x"}}' | _oauth_expires_at)"
  assert_equal "$r" ""
}

# ── _seed_macos_credentials: expiresAt-aware re-seed (host re-login propagation) ─
# A host re-login rotates the Keychain token and invalidates the file's now-stale
# refresh token. A freshly-created box that has never refreshed reads that dead
# token and drops to an interactive LOGIN. The re-seed closes that gap WITHOUT
# ever clobbering a still-valid (possibly fresher) in-box token. now is pinned
# via _CLEAT_NOW_S (=2,000,000 s -> now_ms 2,000,000,000).

@test "seed: re-seeds when the file token is EXPIRED and the Keychain has a fresher one" {
  _is_macos() { return 0; }
  EXPIRED='{"claudeAiOauth":{"accessToken":"STALE-FILE","expiresAt":1000000000}}'
  FRESH='{"claudeAiOauth":{"accessToken":"FRESH-KC","refreshToken":"new","expiresAt":3000000000}}'
  _macos_keychain_credentials() { printf '%s' "$FRESH"; }
  mkdir -p "${HOME}/.claude"
  printf '%s' "$EXPIRED" > "$CRED"
  _CLEAT_NOW_S=2000000 _seed_macos_credentials
  run cat "$CRED"
  assert_output --partial "FRESH-KC"
  refute_output --partial "STALE-FILE"
  [[ "$_SEEDED_CREDS" == "1" ]] || { echo "_SEEDED_CREDS not set on re-seed"; return 1; }
}

@test "seed: does NOT clobber an expired file when the Keychain token is older" {
  _is_macos() { return 0; }
  EXPIRED='{"claudeAiOauth":{"accessToken":"STALE-FILE","expiresAt":1500000000}}'
  OLDER_KC='{"claudeAiOauth":{"accessToken":"OLDER-KC","expiresAt":1200000000}}'
  _macos_keychain_credentials() { printf '%s' "$OLDER_KC"; }
  mkdir -p "${HOME}/.claude"
  printf '%s' "$EXPIRED" > "$CRED"
  _CLEAT_NOW_S=2000000 _seed_macos_credentials
  run cat "$CRED"
  assert_output --partial "STALE-FILE"
  refute_output --partial "OLDER-KC"
}

@test "seed: does NOT re-seed from a Keychain token that is itself expired" {
  _is_macos() { return 0; }
  EXPIRED='{"claudeAiOauth":{"accessToken":"STALE-FILE","expiresAt":1000000000}}'
  NEWER_BUT_EXPIRED='{"claudeAiOauth":{"accessToken":"KC-EXPIRED","expiresAt":1800000000}}'
  _macos_keychain_credentials() { printf '%s' "$NEWER_BUT_EXPIRED"; }
  mkdir -p "${HOME}/.claude"
  printf '%s' "$EXPIRED" > "$CRED"
  _CLEAT_NOW_S=2000000 _seed_macos_credentials
  run cat "$CRED"
  assert_output --partial "STALE-FILE"
  refute_output --partial "KC-EXPIRED"
}

@test "seed: keeps the file when the Keychain blob has no parseable expiry" {
  _is_macos() { return 0; }
  EXPIRED='{"claudeAiOauth":{"accessToken":"STALE-FILE","expiresAt":1000000000}}'
  _macos_keychain_credentials() { printf '%s' '{"claudeAiOauth":{"accessToken":"NOEXP-KC"}}'; }
  mkdir -p "${HOME}/.claude"
  printf '%s' "$EXPIRED" > "$CRED"
  _CLEAT_NOW_S=2000000 _seed_macos_credentials
  run cat "$CRED"
  assert_output --partial "STALE-FILE"
  refute_output --partial "NOEXP-KC"
}

@test "seed: keeps a file token that has no parseable expiry (cannot prove it stale)" {
  _is_macos() { return 0; }
  _macos_keychain_credentials() { printf '%s' "$BLOB"; }
  mkdir -p "${HOME}/.claude"
  printf '%s' '{"claudeAiOauth":{"accessToken":"NOEXP-FILE"}}' > "$CRED"
  _CLEAT_NOW_S=2000000 _seed_macos_credentials
  run cat "$CRED"
  assert_output --partial "NOEXP-FILE"
  refute_output --partial "sk-ant-oat01-abc"
}
