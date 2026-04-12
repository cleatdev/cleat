#!/usr/bin/env bats
load "../setup"
setup()    { _common_setup; source_cli; }
teardown() { _common_teardown; }

@test "produces cleat-<dirname>-<hash> format" {
  local result
  result="$(container_name_for "/home/user/my-project")"
  [[ "$result" =~ ^cleat-my-project-[0-9a-f]{8}$ ]]  || return 1
}

@test "lowercases dirname" {
  local result
  result="$(container_name_for "/home/user/MyProject")"
  [[ "$result" == cleat-myproject-* ]]  || return 1
}

@test "replaces non-alphanumeric chars with hyphens" {
  local result
  result="$(container_name_for "/home/user/my_project.v2")"
  [[ "$result" == cleat-my-project-v2-* ]]  || return 1
}

@test "is deterministic — same input always same output" {
  local a b
  a="$(container_name_for "/home/user/project")"
  b="$(container_name_for "/home/user/project")"
  assert_equal "$a" "$b"
}

@test "different absolute paths with same dirname produce different names" {
  local a b
  a="$(container_name_for "/home/alice/app")"
  b="$(container_name_for "/home/bob/app")"
  [[ "$a" != "$b" ]]  || return 1
}

@test "handles spaces in path" {
  local result
  result="$(container_name_for "/home/user/my project")"
  [[ "$result" =~ ^cleat-my-project-[0-9a-f]{8}$ ]]  || return 1
}

@test "handles root path" {
  local result
  result="$(container_name_for "/")"
  [[ "$result" =~ ^cleat-.*-[0-9a-f]{8}$ ]]  || return 1
}

@test "hash is always exactly 8 hex chars regardless of input" {
  for path in "/" "/a" "/very/long/deeply/nested/path/to/project"; do
    local result hash
    result="$(container_name_for "$path")"
    hash="${result##*-}"
    [[ ${#hash} -eq 8 ]]  || return 1
    [[ "$hash" =~ ^[0-9a-f]{8}$ ]]  || return 1
  done
}

@test "container name never exceeds Docker's 63-char limit" {
  # Create a path with a very long directory name (80+ chars)
  local long_dir
  long_dir="$(printf 'a%.0s' {1..80})"
  local result
  result="$(container_name_for "/home/user/${long_dir}")"
  [[ ${#result} -le 63 ]]  || return 1
  # Verify it still has the expected format
  [[ "$result" =~ ^cleat-.*-[0-9a-f]{8}$ ]]  || return 1
}

@test "truncated name doesn't end with trailing dash" {
  # Create a name that after truncation would end with a dash
  # 48 chars of 'a' followed by a dash — truncation at 48 should strip the trailing dash
  local dir_name
  dir_name="$(printf 'a%.0s' {1..47})-b"
  local result
  result="$(container_name_for "/home/user/${dir_name}")"
  # Extract the middle part (between cleat- and -hash)
  local middle="${result#cleat-}"
  middle="${middle%-????????}"
  [[ "$middle" != *- ]]  || return 1
}

# ── Shell metacharacter handling ────────────────────────────────────────────
# Paths that contain shell metacharacters must not break container_name_for
# or leak through as Docker container names. Docker rejects names with most
# special chars, so we sanitize to [a-z0-9-] and rely on the hash for unique
# identification.

@test "handles path with dollar sign" {
  local result
  result="$(container_name_for "/tmp/my\$project")"
  [[ "$result" =~ ^cleat-[a-z0-9-]+-[0-9a-f]{8}$ ]]  || return 1
  # No $ should appear in the name
  [[ "$result" != *\$* ]]  || return 1
}

@test "handles path with ampersand" {
  local result
  result="$(container_name_for "/tmp/my&proj")"
  [[ "$result" =~ ^cleat-[a-z0-9-]+-[0-9a-f]{8}$ ]]  || return 1
  [[ "$result" != *\&* ]]  || return 1
}

@test "handles path with semicolons and pipes" {
  local result
  result="$(container_name_for "/tmp/my;pro|j")"
  [[ "$result" =~ ^cleat-[a-z0-9-]+-[0-9a-f]{8}$ ]]  || return 1
  [[ "$result" != *\;* ]]  || return 1
  [[ "$result" != *\|* ]]  || return 1
}

@test "handles path with backticks and quotes" {
  local result
  result="$(container_name_for "/tmp/my\`proj'x\"")"
  [[ "$result" =~ ^cleat-[a-z0-9-]+-[0-9a-f]{8}$ ]]  || return 1
  [[ "$result" != *\`* ]]  || return 1
  [[ "$result" != *\'* ]]  || return 1
  [[ "$result" != *\"* ]]  || return 1
}

@test "handles path with parentheses and braces" {
  local result
  result="$(container_name_for "/tmp/my(proj){x}")"
  [[ "$result" =~ ^cleat-[a-z0-9-]+-[0-9a-f]{8}$ ]]  || return 1
}

@test "handles path with unicode characters" {
  local result
  result="$(container_name_for "/tmp/прожект")"
  [[ "$result" =~ ^cleat-[a-z0-9-]+-[0-9a-f]{8}$ ]]  || return 1
  # All chars should be ASCII after sanitization
  [[ "$result" =~ ^[a-z0-9-]+$ ]]  || return 1
}

@test "handles empty basename (path ending with /)" {
  # `basename /tmp/project/` → `project`, same as `/tmp/project`
  local a b
  a="$(container_name_for "/tmp/myproj")"
  b="$(container_name_for "/tmp/myproj/")"
  # Hash is computed from full path (with or without trailing slash), so
  # these produce DIFFERENT hashes. The dir_name portion is the same.
  [[ "${a%-*}" == "${b%-*}" ]] || {
    echo "dirname portion should match (got $a vs $b)"
    return 1
  }
}

@test "path is a single char" {
  local result
  result="$(container_name_for "/")"
  [[ "$result" =~ ^cleat-.*-[0-9a-f]{8}$ ]]  || return 1
  [[ ${#result} -le 63 ]]  || return 1
}

@test "path with only special chars produces valid name" {
  local result
  result="$(container_name_for "/tmp/\$\$\$\$")"
  [[ "$result" =~ ^cleat-[a-z0-9-]+-[0-9a-f]{8}$ ]]  || return 1
}
