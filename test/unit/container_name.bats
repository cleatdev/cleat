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
