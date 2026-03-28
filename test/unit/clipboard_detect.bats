#!/usr/bin/env bats

load "../setup"

setup() {
  _common_setup
  source_cli
}

teardown() { _common_teardown; }

@test "_host_clip_cmd returns empty when no clipboard tool available" {
  local empty_path="$TEST_TEMP/empty_bin"
  mkdir -p "$empty_path"
  local result
  result="$(PATH="$empty_path" _host_clip_cmd)"
  assert_equal "$result" ""
}

@test "_host_clip_cmd prefers pbcopy when available" {
  mkdir -p "$TEST_TEMP/bin"
  echo '#!/bin/sh' > "$TEST_TEMP/bin/pbcopy" && chmod +x "$TEST_TEMP/bin/pbcopy"
  local result
  result="$(PATH="$TEST_TEMP/bin" _host_clip_cmd)"
  assert_equal "$result" "pbcopy"
}

@test "_host_clip_cmd falls back to xclip when no pbcopy" {
  mkdir -p "$TEST_TEMP/bin"
  echo '#!/bin/sh' > "$TEST_TEMP/bin/xclip" && chmod +x "$TEST_TEMP/bin/xclip"
  local result
  result="$(PATH="$TEST_TEMP/bin" _host_clip_cmd)"
  assert_equal "$result" "xclip -selection clipboard"
}

@test "_host_clip_cmd falls back to xsel when no pbcopy or xclip" {
  mkdir -p "$TEST_TEMP/bin"
  echo '#!/bin/sh' > "$TEST_TEMP/bin/xsel" && chmod +x "$TEST_TEMP/bin/xsel"
  local result
  result="$(PATH="$TEST_TEMP/bin" _host_clip_cmd)"
  assert_equal "$result" "xsel --clipboard"
}

@test "_host_clip_cmd falls back to wl-copy as last option" {
  mkdir -p "$TEST_TEMP/bin"
  echo '#!/bin/sh' > "$TEST_TEMP/bin/wl-copy" && chmod +x "$TEST_TEMP/bin/wl-copy"
  local result
  result="$(PATH="$TEST_TEMP/bin" _host_clip_cmd)"
  assert_equal "$result" "wl-copy"
}
