#!/usr/bin/env bats
# Boxes: named per-project sandboxes (see concept/20-boxes.md).
# Phase 1: box-name validation + per-project/box session-key derivation.
load "../setup"
setup()    { _common_setup; source_cli; }
teardown() { _common_teardown; }

# ── _validate_box_name ──────────────────────────────────────────────────────

@test "box name: accepts a simple lowercase name" {
  run _validate_box_name "az"
  assert_success
}

@test "box name: accepts digits, dashes, and underscores" {
  run _validate_box_name "dev-2_x"
  assert_success
}

@test "box name: accepts a single character" {
  run _validate_box_name "a"
  assert_success
}

@test "box name: accepts 31 characters (the maximum)" {
  run _validate_box_name "$(printf 'a%.0s' {1..31})"
  assert_success
}

@test "box name: rejects 32 characters (over the maximum)" {
  run _validate_box_name "$(printf 'a%.0s' {1..32})"
  assert_failure
}

@test "box name: rejects the empty string" {
  run _validate_box_name ""
  assert_failure
}

@test "box name: rejects uppercase" {
  run _validate_box_name "Az"
  assert_failure
}

@test "box name: rejects a leading dash" {
  run _validate_box_name "-az"
  assert_failure
}

@test "box name: rejects a leading underscore" {
  run _validate_box_name "_az"
  assert_failure
}

@test "box name: rejects a slash (paths are not box names)" {
  run _validate_box_name "a/b"
  assert_failure
}

@test "box name: rejects an absolute path" {
  run _validate_box_name "/home/user/proj"
  assert_failure
}

@test "box name: rejects a dot" {
  run _validate_box_name "a.b"
  assert_failure
}

@test "box name: rejects a space" {
  run _validate_box_name "a b"
  assert_failure
}

@test "box name: rejects shell metacharacters" {
  run _validate_box_name 'a$b'
  assert_failure
  run _validate_box_name 'a;b'
  assert_failure
  run _validate_box_name 'a&b'
  assert_failure
}

# ── _derive_project_session_key ─────────────────────────────────────────────

@test "session key: default (no box) is <basename>-<hash8>" {
  local key
  key="$(_derive_project_session_key "/home/user/my-project")"
  [[ "$key" =~ ^my-project-[0-9a-f]{8}$ ]] || { echo "got: $key"; return 1; }
}

@test "session key: default box equals the legacy inline derivation byte-for-byte" {
  # Upgrade-safety invariant: existing users' session history and per-project
  # .claude.json live under <basename>-<hash8>. The helper's no-box output MUST
  # match that exact formula, or every user loses their history on upgrade.
  local project="/home/user/proj"
  local legacy expected
  legacy="$(basename "$project" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g')-$(echo -n "$project" | _md5 | head -c 8)"
  expected="$(_derive_project_session_key "$project")"
  assert_equal "$expected" "$legacy"
}

@test "session key: the 'main' box is byte-identical to the default" {
  # `cleat start main` must resolve to the exact same session state as `cleat`
  # and `cleat start`. main IS the default box, never a -main suffix on disk.
  local project="/home/user/proj"
  assert_equal "$(_derive_project_session_key "$project" main)" "$(_derive_project_session_key "$project")"
}

@test "session key: a named box appends -<box>" {
  local project="/home/user/proj"
  local base named
  base="$(_derive_project_session_key "$project")"
  named="$(_derive_project_session_key "$project" az)"
  assert_equal "$named" "${base}-az"
}

@test "session key: different boxes on one project produce different keys" {
  local project="/home/user/proj"
  [[ "$(_derive_project_session_key "$project" az)" != "$(_derive_project_session_key "$project" dev)" ]] || return 1
}

@test "session key: a named box differs from the default box" {
  local project="/home/user/proj"
  [[ "$(_derive_project_session_key "$project" az)" != "$(_derive_project_session_key "$project")" ]] || return 1
}

@test "session key: same project + box is deterministic" {
  local project="/home/user/proj"
  assert_equal "$(_derive_project_session_key "$project" az)" "$(_derive_project_session_key "$project" az)"
}

# ── _set_box (dispatch box resolution) ──────────────────────────────────────

@test "set box: an empty arg sets _BOX to main" {
  _set_box ""
  assert_equal "$_BOX" "main"
}

@test "set box: a valid name sets _BOX" {
  _set_box "az"
  assert_equal "$_BOX" "az"
}

@test "set box: explicit 'main' sets _BOX to main" {
  _set_box "main"
  assert_equal "$_BOX" "main"
}

@test "set box: an invalid name errors and exits non-zero" {
  run _set_box "Bad/Name"
  assert_failure
  assert_output --partial "Invalid box name"
}

@test "set box: a path is rejected as an invalid box name" {
  run _set_box "/home/user/proj"
  assert_failure
  assert_output --partial "Invalid box name"
}
