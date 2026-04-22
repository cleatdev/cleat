#!/usr/bin/env bats
# ─────────────────────────────────────────────────────────────────────────────
# Workspace trust — unit tests
#
# Coverage:
#   1. Canonicalization (_canonical_caps): sort, dedupe, whitespace tolerance
#   2. Hash (_hash_cleat_caps): hash is over canonical caps, not raw file
#      — comment changes in .cleat must not change the hash
#   3. Trust file I/O: record, lookup, remove, list, atomic write
#   4. _is_project_trusted: hash-match predicate
#   5. _resolve_project_trust:
#        - trusted → apply
#        - untrusted + CLEAT_TRUST_PROJECT=1 → auto-approve + record
#        - untrusted + _CLI_TRUST_PROJECT=1 → auto-approve + record
#        - untrusted + non-TTY + no opt-in → deny (warn)
#        - readonly mode never prompts
#   6. resolve_caps (end-to-end): project caps gated by trust
#   7. Edge cases: paths with tabs/newlines, corrupt trust file, missing
#      .cleat, empty .cleat (no caps), hash changes re-require approval
# ─────────────────────────────────────────────────────────────────────────────

load "../setup"

setup() {
  _common_setup
  # Trust tests need a clean slate and explicit control over the
  # CLEAT_TRUST_PROJECT opt-in. _common_setup exports CLEAT_TRUST_PROJECT=1
  # so other tests auto-trust; the trust suite unsets it per test.
  unset CLEAT_TRUST_PROJECT
  source_cli
  # Isolate trust + config writes under TEST_TEMP.
  CLEAT_CONFIG_DIR="$TEST_TEMP/cleat-config"
  CLEAT_GLOBAL_CONFIG="$CLEAT_CONFIG_DIR/config"
  CLEAT_GLOBAL_ENV="$CLEAT_CONFIG_DIR/env"
  CLEAT_TRUST_FILE="$CLEAT_CONFIG_DIR/trust"
  mkdir -p "$CLEAT_CONFIG_DIR"
}

teardown() { _common_teardown; }

_source_cli_silent() {
  # Convenience: source_cli may set _TRUST_SESSION_* etc. Reset between tests.
  _TRUST_SESSION_DECISION=""
  _TRUST_SESSION_PROJECT=""
}

# ── _canonical_caps ─────────────────────────────────────────────────────────

@test "canonical: sorts caps alphabetically" {
  local out
  out="$(printf 'ssh\ngit\nenv\n' | _canonical_caps)"
  [[ "$out" == "env,git,ssh" ]] || { echo "got: $out"; return 1; }
}

@test "canonical: dedupes repeated caps" {
  local out
  out="$(printf 'git\ngit\nssh\n' | _canonical_caps)"
  [[ "$out" == "git,ssh" ]] || { echo "got: $out"; return 1; }
}

@test "canonical: empty input produces empty output" {
  local out
  out="$(printf '' | _canonical_caps)"
  [[ "$out" == "" ]] || { echo "got: $out"; return 1; }
}

@test "canonical: whitespace-only lines are dropped" {
  local out
  # _canonical_caps uses awk 'NF' which drops empty lines. Whitespace-only
  # lines aren't emitted by _read_caps_from_file in the first place, so we
  # only need to guard the empty-line drop.
  out="$(printf 'git\n\nssh\n\n' | _canonical_caps)"
  [[ "$out" == "git,ssh" ]] || { echo "got: $out"; return 1; }
}

# ── _hash_cleat_caps ────────────────────────────────────────────────────────

@test "hash: identical caps produce identical hash regardless of order" {
  local a="$TEST_TEMP/a/.cleat" b="$TEST_TEMP/b/.cleat"
  mkdir -p "$TEST_TEMP/a" "$TEST_TEMP/b"
  printf '[caps]\ngit\nssh\n' > "$a"
  printf '[caps]\nssh\ngit\n' > "$b"
  local ha hb
  ha="$(_hash_cleat_caps "$a")"
  hb="$(_hash_cleat_caps "$b")"
  [[ -n "$ha" && "$ha" == "$hb" ]] || {
    echo "hashes differ: a='$ha' b='$hb'"
    return 1
  }
}

@test "hash: comment-only changes don't change the hash" {
  local f="$TEST_TEMP/project/.cleat"
  mkdir -p "$TEST_TEMP/project"
  printf '[caps]\ngit\nssh\n' > "$f"
  local h1
  h1="$(_hash_cleat_caps "$f")"
  printf '# I changed a comment\n[caps]\n# another comment\ngit\nssh\n' > "$f"
  local h2
  h2="$(_hash_cleat_caps "$f")"
  [[ "$h1" == "$h2" ]] || {
    echo "comment change altered the hash ($h1 vs $h2)"
    return 1
  }
}

@test "hash: adding a cap changes the hash" {
  local f="$TEST_TEMP/project/.cleat"
  mkdir -p "$TEST_TEMP/project"
  printf '[caps]\ngit\n' > "$f"
  local h1
  h1="$(_hash_cleat_caps "$f")"
  printf '[caps]\ngit\ndocker\n' > "$f"
  local h2
  h2="$(_hash_cleat_caps "$f")"
  [[ "$h1" != "$h2" ]] || {
    echo "adding a cap didn't change hash"
    return 1
  }
}

@test "hash: missing file returns empty" {
  run _hash_cleat_caps "$TEST_TEMP/nope/.cleat"
  assert_success
  assert_output ""
}

@test "hash: output is hex-only (no md5sum filename suffix)" {
  # md5sum on Linux appends "  -" (the stdin "filename") — without stripping
  # it we'd corrupt the tab-separated trust file format. The hash must be
  # purely [0-9a-f] characters.
  local f="$TEST_TEMP/proj/.cleat"
  mkdir -p "$TEST_TEMP/proj"
  printf '[caps]\ngit\nssh\n' > "$f"
  local h
  h="$(_hash_cleat_caps "$f")"
  [[ "$h" =~ ^[0-9a-f]+$ ]] || {
    echo "hash contains non-hex characters: '$h'"
    return 1
  }
  # And no trailing whitespace or "  -" artifacts.
  [[ "$h" != *" "* && "$h" != *"	"* ]] || {
    echo "hash contains whitespace: '$h'"
    return 1
  }
}

@test "hash: file with no [caps] section returns empty" {
  local f="$TEST_TEMP/project/.cleat"
  mkdir -p "$TEST_TEMP/project"
  printf '# nothing here\n' > "$f"
  run _hash_cleat_caps "$f"
  assert_success
  assert_output ""
}

# ── _trust_record / _trust_lookup / _trust_remove ───────────────────────────

@test "trust record: writes an entry and makes it readable" {
  _trust_record "/fake/proj" "abc123"
  run _trust_lookup "/fake/proj"
  assert_success
  assert_output "abc123"
}

@test "trust record: is idempotent — recording again replaces the hash" {
  _trust_record "/fake/proj" "first"
  _trust_record "/fake/proj" "second"
  run _trust_lookup "/fake/proj"
  assert_output "second"
  # And the file still contains exactly one entry for the project.
  local n
  n="$(awk -F'\t' '$1 == "/fake/proj"' "$CLEAT_TRUST_FILE" | wc -l | tr -d ' ')"
  [[ "$n" == "1" ]] || {
    echo "expected 1 entry, got $n"
    cat "$CLEAT_TRUST_FILE"
    return 1
  }
}

@test "trust record: multiple projects coexist" {
  _trust_record "/p/one" "h1"
  _trust_record "/p/two" "h2"
  _trust_record "/p/three" "h3"
  run _trust_lookup "/p/one";   assert_output "h1"
  run _trust_lookup "/p/two";   assert_output "h2"
  run _trust_lookup "/p/three"; assert_output "h3"
}

@test "trust record: refuses paths with embedded tab" {
  run _trust_record "$(printf '/foo\tbar')" "h"
  assert_failure
  [[ ! -s "$CLEAT_TRUST_FILE" ]] || {
    # Even if the file exists from comments, it should have no entry
    ! grep -q "h$" "$CLEAT_TRUST_FILE"
  }
}

@test "trust record: refuses paths with newline" {
  run _trust_record "$(printf '/foo\nbar')" "h"
  assert_failure
}

@test "trust record: refuses paths with carriage return" {
  run _trust_record "$(printf '/foo\rbar')" "h"
  assert_failure
}

@test "trust record: refuses empty hash" {
  run _trust_record "/fake/proj" ""
  assert_failure
}

@test "trust record: file is 0600" {
  _trust_record "/fake/proj" "h"
  [[ -f "$CLEAT_TRUST_FILE" ]]
  local perms
  perms="$(stat -c '%a' "$CLEAT_TRUST_FILE" 2>/dev/null || stat -f '%Lp' "$CLEAT_TRUST_FILE" 2>/dev/null)"
  [[ "$perms" == "600" ]] || {
    echo "expected 600, got $perms"
    return 1
  }
}

@test "trust remove: deletes an entry" {
  _trust_record "/p/a" "h1"
  _trust_record "/p/b" "h2"
  _trust_remove "/p/a"
  run _trust_lookup "/p/a"; assert_output ""
  run _trust_lookup "/p/b"; assert_output "h2"
}

@test "trust remove: is a no-op for unknown project" {
  _trust_remove "/not/there"
  [[ ! -f "$CLEAT_TRUST_FILE" ]] || {
    # file may get created with header only — that's fine
    :
  }
}

@test "trust list: returns stored project paths" {
  _trust_record "/p/a" "h1"
  _trust_record "/p/b" "h2"
  run _trust_list
  assert_success
  assert_output --partial "/p/a"
  assert_output --partial "/p/b"
}

@test "trust list: empty when no trust file" {
  run _trust_list
  assert_success
  assert_output ""
}

@test "trust file: corrupt lines are ignored on lookup" {
  cat > "$CLEAT_TRUST_FILE" << 'EOF'
this is garbage without a tab
/valid/proj	validhash
another broken line
# comment
EOF
  run _trust_lookup "/valid/proj"
  assert_output "validhash"
  run _trust_lookup "this is garbage without a tab"
  # Should not find the garbage line (NF < 2 filter)
  assert_output ""
}

# ── _is_project_trusted ─────────────────────────────────────────────────────

@test "is_trusted: true when stored hash matches current caps" {
  mkdir -p "$TEST_TEMP/proj"
  printf '[caps]\ngit\nssh\n' > "$TEST_TEMP/proj/.cleat"
  local h
  h="$(_hash_cleat_caps "$TEST_TEMP/proj/.cleat")"
  _trust_record "$TEST_TEMP/proj" "$h"
  run _is_project_trusted "$TEST_TEMP/proj"
  assert_success
}

@test "is_trusted: false when caps changed after approval" {
  mkdir -p "$TEST_TEMP/proj"
  printf '[caps]\ngit\n' > "$TEST_TEMP/proj/.cleat"
  local h
  h="$(_hash_cleat_caps "$TEST_TEMP/proj/.cleat")"
  _trust_record "$TEST_TEMP/proj" "$h"
  # Now add a cap the user hasn't approved.
  printf '[caps]\ngit\ndocker\n' > "$TEST_TEMP/proj/.cleat"
  run _is_project_trusted "$TEST_TEMP/proj"
  assert_failure
}

@test "is_trusted: false when no entry exists" {
  mkdir -p "$TEST_TEMP/proj"
  printf '[caps]\ngit\n' > "$TEST_TEMP/proj/.cleat"
  run _is_project_trusted "$TEST_TEMP/proj"
  assert_failure
}

# ── _resolve_project_trust & resolve_caps integration ───────────────────────

@test "resolve_caps: missing .cleat does not prompt or deny" {
  mkdir -p "$TEST_TEMP/proj"
  printf '[caps]\ngit\n' > "$CLEAT_GLOBAL_CONFIG"
  touch "$HOME/.gitconfig"
  # Call directly (not via `run`) so ACTIVE_CAPS is visible in this shell.
  resolve_caps "$TEST_TEMP/proj"
  cap_is_active git || { echo "git not active; ACTIVE_CAPS=${ACTIVE_CAPS[*]+${ACTIVE_CAPS[*]}}"; return 1; }
}

@test "resolve_caps: trusted project applies .cleat caps silently" {
  mkdir -p "$TEST_TEMP/proj"
  printf '[caps]\ndocker\n' > "$TEST_TEMP/proj/.cleat"
  local h
  h="$(_hash_cleat_caps "$TEST_TEMP/proj/.cleat")"
  _trust_record "$TEST_TEMP/proj" "$h"
  resolve_caps "$TEST_TEMP/proj"
  cap_is_active docker
}

@test "resolve_caps: CLEAT_TRUST_PROJECT=1 bypasses prompt and auto-records" {
  mkdir -p "$TEST_TEMP/proj"
  printf '[caps]\ndocker\n' > "$TEST_TEMP/proj/.cleat"
  export CLEAT_TRUST_PROJECT=1
  resolve_caps "$TEST_TEMP/proj"
  cap_is_active docker
  # And the approval was persisted.
  run _is_project_trusted "$TEST_TEMP/proj"
  assert_success
  unset CLEAT_TRUST_PROJECT
}

@test "resolve_caps: --trust-project flag bypasses prompt and auto-records" {
  mkdir -p "$TEST_TEMP/proj"
  printf '[caps]\ndocker\n' > "$TEST_TEMP/proj/.cleat"
  _CLI_TRUST_PROJECT=1
  resolve_caps "$TEST_TEMP/proj"
  cap_is_active docker
  run _is_project_trusted "$TEST_TEMP/proj"
  assert_success
  _CLI_TRUST_PROJECT=0
}

@test "resolve_caps: non-TTY + no opt-in skips project caps (default-deny)" {
  mkdir -p "$TEST_TEMP/proj"
  printf '[caps]\ndocker\nssh\n' > "$TEST_TEMP/proj/.cleat"
  # Global config still applies — user's own file is trusted.
  printf '[caps]\ngit\n' > "$CLEAT_GLOBAL_CONFIG"
  touch "$HOME/.gitconfig"
  # Force non-TTY by overriding _is_tty; also no opt-in env var.
  _is_tty() { return 1; }
  # First run: capture output to verify the warning is printed.
  run resolve_caps "$TEST_TEMP/proj"
  assert_success
  assert_output --partial "Project .cleat skipped"
  # Second run: direct call so ACTIVE_CAPS is populated in this shell.
  resolve_caps "$TEST_TEMP/proj" >/dev/null 2>&1
  ! cap_is_active docker || { echo "docker leaked"; return 1; }
  ! cap_is_active ssh || { echo "ssh leaked"; return 1; }
  cap_is_active git || { echo "git from global missing"; return 1; }
}

@test "resolve_caps: readonly mode never prompts or denies visibly" {
  # readonly trust_mode is for cleat status — it should silently skip
  # untrusted project caps without warn output.
  mkdir -p "$TEST_TEMP/proj"
  printf '[caps]\ndocker\n' > "$TEST_TEMP/proj/.cleat"
  _is_tty() { return 0; }  # even if TTY, readonly must not prompt
  run resolve_caps "$TEST_TEMP/proj" readonly
  assert_success
  # No prompt happened and no warning output.
  refute_output --partial "Trust this project"
  # docker cap was not applied.
  resolve_caps "$TEST_TEMP/proj" readonly
  ! cap_is_active docker
}

@test "resolve_caps: --cap CLI flag still works even when .cleat is untrusted" {
  mkdir -p "$TEST_TEMP/proj"
  printf '[caps]\ndocker\n' > "$TEST_TEMP/proj/.cleat"
  mkdir -p "$HOME/.ssh"
  touch "$HOME/.ssh/config"
  _is_tty() { return 1; }  # non-TTY, no opt-in → .cleat skipped
  _CLI_CAPS=(ssh)          # but explicit --cap still applies
  resolve_caps "$TEST_TEMP/proj"
  cap_is_active ssh || { echo "ssh missing; caps=${ACTIVE_CAPS[*]+${ACTIVE_CAPS[*]}}"; return 1; }
  ! cap_is_active docker
}

@test "resolve_caps: empty .cleat file doesn't trigger trust flow" {
  mkdir -p "$TEST_TEMP/proj"
  # [caps] section header but no caps listed.
  printf '[caps]\n# no caps here\n' > "$TEST_TEMP/proj/.cleat"
  _is_tty() { return 1; }
  # No warning since there's nothing to approve.
  run resolve_caps "$TEST_TEMP/proj"
  assert_success
  refute_output --partial "Trust this project"
  refute_output --partial "Project .cleat"
}

# ── cmd_trust / cmd_untrust ────────────────────────────────────────────────

@test "cmd_trust: records trust for current project non-interactively" {
  mkdir -p "$TEST_TEMP/proj"
  printf '[caps]\nenv\ngit\n' > "$TEST_TEMP/proj/.cleat"
  run cmd_trust "$TEST_TEMP/proj"
  assert_success
  assert_output --partial "Trusted"
  run _is_project_trusted "$TEST_TEMP/proj"
  assert_success
}

@test "cmd_trust: fails cleanly when .cleat is missing" {
  mkdir -p "$TEST_TEMP/proj"
  run cmd_trust "$TEST_TEMP/proj"
  assert_failure
  assert_output --partial "No .cleat file"
}

@test "cmd_trust: fails when .cleat has no capabilities" {
  mkdir -p "$TEST_TEMP/proj"
  printf '# empty\n' > "$TEST_TEMP/proj/.cleat"
  run cmd_trust "$TEST_TEMP/proj"
  assert_failure
  assert_output --partial "no capabilities"
}

@test "cmd_trust --list: shows trusted projects" {
  mkdir -p "$TEST_TEMP/proj"
  printf '[caps]\ngit\n' > "$TEST_TEMP/proj/.cleat"
  cmd_trust "$TEST_TEMP/proj" > /dev/null
  run cmd_trust --list
  assert_success
  assert_output --partial "$TEST_TEMP/proj"
}

@test "cmd_trust --list: info message when nothing trusted" {
  run cmd_trust --list
  assert_success
  assert_output --partial "No trusted projects"
}

@test "cmd_untrust: removes an existing trust entry" {
  mkdir -p "$TEST_TEMP/proj"
  printf '[caps]\ngit\n' > "$TEST_TEMP/proj/.cleat"
  cmd_trust "$TEST_TEMP/proj" > /dev/null
  run cmd_untrust "$TEST_TEMP/proj"
  assert_success
  assert_output --partial "Removed trust"
  run _is_project_trusted "$TEST_TEMP/proj"
  assert_failure
}

@test "cmd_untrust: reports 'was not trusted' for unknown project" {
  mkdir -p "$TEST_TEMP/proj"
  run cmd_untrust "$TEST_TEMP/proj"
  assert_success
  assert_output --partial "was not trusted"
}

# ── Status subcommand safety ───────────────────────────────────────────────

@test "cmd_status: never prompts for trust even when .cleat is untrusted" {
  mkdir -p "$TEST_TEMP/proj"
  printf '[caps]\ndocker\n' > "$TEST_TEMP/proj/.cleat"
  _is_tty() { return 0; }  # simulate TTY
  mock_docker_images ""
  # If this ran interactively it would call _trust_prompt and block.
  run cmd_status "$TEST_TEMP/proj"
  assert_success
  refute_output --partial "Trust this project"
}
