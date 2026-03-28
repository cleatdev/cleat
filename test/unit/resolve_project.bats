#!/usr/bin/env bats
load "../setup"
setup()    { _common_setup; source_cli; }
teardown() { _common_teardown; }

@test "defaults to PWD when no argument" {
  assert_equal "$(resolve_project)" "$PWD"
}

@test "defaults to PWD for empty string" {
  assert_equal "$(resolve_project "")" "$PWD"
}

@test "resolves directory to absolute path" {
  mkdir -p "$TEST_TEMP/subdir"
  local result
  result="$(cd "$TEST_TEMP" && resolve_project "subdir")"
  assert_equal "$result" "$TEST_TEMP/subdir"
}

@test "returns non-directory path as-is" {
  assert_equal "$(resolve_project "/nonexistent/foo")" "/nonexistent/foo"
}

@test "resolves . to current directory" {
  mkdir -p "$TEST_TEMP/dir"
  local result
  result="$(cd "$TEST_TEMP/dir" && resolve_project ".")"
  assert_equal "$result" "$TEST_TEMP/dir"
}

@test "resolves .. to parent directory" {
  mkdir -p "$TEST_TEMP/parent/child"
  local result
  result="$(cd "$TEST_TEMP/parent/child" && resolve_project "..")"
  assert_equal "$result" "$TEST_TEMP/parent"
}

@test "handles spaces in path" {
  mkdir -p "$TEST_TEMP/path with spaces"
  local result
  result="$(resolve_project "$TEST_TEMP/path with spaces")"
  assert_equal "$result" "$TEST_TEMP/path with spaces"
}

@test "returns broken symlink as-is (not a directory)" {
  ln -sf "$TEST_TEMP/nonexistent" "$TEST_TEMP/broken-link"
  assert_equal "$(resolve_project "$TEST_TEMP/broken-link")" "$TEST_TEMP/broken-link"
}
