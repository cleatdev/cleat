#!/usr/bin/env bats
#
# Per-project ~/.claude.json isolation (_build_project_claude_json).
#
# Cleat builds an isolated, persistent per-project .claude.json instead of
# mounting the shared host file into every container. This file guards the two
# bugs that drove the change:
#   1. Corruption: concurrent containers truncating the shared host file
#      (Claude's "Configuration Error / Unexpected EOF").
#   2. Cross-project bleed: every container runs at /workspace, so they all
#      shared projects["/workspace"] (trust / MCP / allowedTools approvals).

load "../setup"

setup() {
  _common_setup
  use_docker_stub
  source_cli

  CLEAT_CONFIG_DIR="$TEST_TEMP/cleat-config"
  CLEAT_PROJECTS_DIR="$CLEAT_CONFIG_DIR/projects"
  mkdir -p "$CLEAT_PROJECTS_DIR"

  HOST_JSON="${HOME}/.claude.json"
  OUT="$CLEAT_PROJECTS_DIR/proj-a/claude.json"
}

teardown() { _common_teardown; }

# ── global keys come from the host ──────────────────────────────────────────

@test "build: global identity keys are taken fresh from the host file" {
  echo '{"oauthAccount":{"emailAddress":"real@b.com"},"userID":"u1","hasCompletedOnboarding":true}' > "$HOST_JSON"

  _build_project_claude_json "$OUT"

  run jq -r '.oauthAccount.emailAddress' "$OUT"
  assert_output "real@b.com"
  run jq -r '.userID' "$OUT"
  assert_output "u1"
  run jq -r '.hasCompletedOnboarding' "$OUT"
  assert_output "true"
}

@test "build: host global value wins over a stale persisted copy" {
  echo '{"oauthAccount":{"emailAddress":"current@b.com"}}' > "$HOST_JSON"
  mkdir -p "$(dirname "$OUT")"
  echo '{"oauthAccount":{"emailAddress":"STALE@old.com"}}' > "$OUT"

  _build_project_claude_json "$OUT"

  run jq -r '.oauthAccount.emailAddress' "$OUT"
  assert_output "current@b.com"
}

@test "build: host's own real-path projects are preserved" {
  echo '{"projects":{"/Users/m/foo":{"allowedTools":["HostTool"]}}}' > "$HOST_JSON"

  _build_project_claude_json "$OUT"

  run jq -r '.projects["/Users/m/foo"].allowedTools[0]' "$OUT"
  assert_output "HostTool"
}

# ── per-project /workspace block ────────────────────────────────────────────

@test "build: the project's own /workspace block persists across rebuilds" {
  echo '{"oauthAccount":{"emailAddress":"real@b.com"}}' > "$HOST_JSON"
  mkdir -p "$(dirname "$OUT")"
  # Simulate Claude having written approvals into the persisted per-project file.
  echo '{"projects":{"/workspace":{"hasTrustDialogAccepted":true,"allowedTools":["Bash"]}}}' > "$OUT"

  _build_project_claude_json "$OUT"

  run jq -r '.projects["/workspace"].hasTrustDialogAccepted' "$OUT"
  assert_output "true"
  run jq -r '.projects["/workspace"].allowedTools[0]' "$OUT"
  assert_output "Bash"
  # …and the fresh host global is merged in alongside it.
  run jq -r '.oauthAccount.emailAddress' "$OUT"
  assert_output "real@b.com"
}

@test "build: one project's /workspace approvals do NOT bleed into another" {
  echo '{"oauthAccount":{"emailAddress":"real@b.com"}}' > "$HOST_JSON"
  local out_a="$CLEAT_PROJECTS_DIR/proj-a/claude.json"
  local out_b="$CLEAT_PROJECTS_DIR/proj-b/claude.json"
  mkdir -p "$(dirname "$out_a")"
  echo '{"projects":{"/workspace":{"hasTrustDialogAccepted":true}}}' > "$out_a"

  # Building project B (with no prior state) must not inherit A's approval.
  _build_project_claude_json "$out_b"

  run jq -r '.projects["/workspace"].hasTrustDialogAccepted // "absent"' "$out_b"
  assert_output "absent"
}

# ── fresh machine: onboarding done inside a container sticks ─────────────────

@test "build: with no host file, onboarding identity falls back to the persisted copy" {
  rm -f "$HOST_JSON"
  mkdir -p "$(dirname "$OUT")"
  echo '{"oauthAccount":{"emailAddress":"onboarded@b.com"},"hasCompletedOnboarding":true}' > "$OUT"

  _build_project_claude_json "$OUT"

  run jq -r '.oauthAccount.emailAddress' "$OUT"
  assert_output "onboarded@b.com"
  run jq -r '.hasCompletedOnboarding' "$OUT"
  assert_output "true"
}

@test "build: with neither host nor persisted file, output is valid empty JSON" {
  rm -f "$HOST_JSON"
  rm -f "$OUT"

  _build_project_claude_json "$OUT"

  [[ -f "$OUT" ]]
  run jq -e . "$OUT"
  assert_success
}

# ── installMethod (container is always a native install) ────────────────────
# The container's Claude is the native installer build, but this file is rebuilt
# from the host every run and shadows the installMethod the installer wrote at
# image-build time. Without forcing it, `claude doctor` warns "native
# installation but config install method is unknown". See bin/cleat comment.

@test "build: forces installMethod=native even when the host file has none" {
  echo '{"oauthAccount":{"emailAddress":"x@y.z"}}' > "$HOST_JSON"
  _build_project_claude_json "$OUT"
  run jq -r '.installMethod' "$OUT"
  assert_output "native"
}

@test "build: forces installMethod=native over a different host value (e.g. homebrew)" {
  # The host might be a Homebrew/npm install; the CONTAINER is always native, so
  # the host's value must not leak in. Mutating the forced value breaks this.
  echo '{"installMethod":"homebrew","oauthAccount":{"emailAddress":"x@y.z"}}' > "$HOST_JSON"
  _build_project_claude_json "$OUT"
  run jq -r '.installMethod' "$OUT"
  assert_output "native"
}

@test "build: installMethod=native with no host file at all" {
  rm -f "$HOST_JSON" "$OUT"
  _build_project_claude_json "$OUT"
  run jq -r '.installMethod' "$OUT"
  assert_output "native"
}

# ── corruption guard (Decision 3) ───────────────────────────────────────────

@test "build: a corrupt host file is backed up, left untouched, and never feeds the build" {
  printf '{"oauthAccount": {' > "$HOST_JSON"   # truncated, invalid JSON
  mkdir -p "$(dirname "$OUT")"
  echo '{"hasCompletedOnboarding":true}' > "$OUT"

  run _build_project_claude_json "$OUT"
  assert_success
  assert_output --partial "backed up to"

  # Backup created, original left exactly as-is (not reset to {}).
  [[ -f "${HOST_JSON}.bak" ]]
  run cat "$HOST_JSON"
  assert_output '{"oauthAccount": {'

  # The built file is still valid and kept the persisted state.
  run jq -e . "$OUT"
  assert_success
  run jq -r '.hasCompletedOnboarding' "$OUT"
  assert_output "true"
}

@test "build: never writes invalid JSON to the output file" {
  echo '{"a":1}' > "$HOST_JSON"
  _build_project_claude_json "$OUT"
  run jq -e . "$OUT"
  assert_success
}

@test "build: leaves no .tmp file behind" {
  echo '{"a":1}' > "$HOST_JSON"
  _build_project_claude_json "$OUT"
  run bash -c "ls $(dirname "$OUT")/*.tmp.* 2>/dev/null | wc -l | tr -d ' '"
  assert_output "0"
}

# ── malformed shapes (valid JSON but not an object) ─────────────────────────

@test "build: a valid-JSON-but-non-object host file is treated as corrupt, not crashed on" {
  # A JSON array/string passes `jq empty` but would crash the object merge.
  printf '["not","an","object"]' > "$HOST_JSON"
  mkdir -p "$(dirname "$OUT")"
  echo '{"hasCompletedOnboarding":true}' > "$OUT"

  run _build_project_claude_json "$OUT"
  assert_success
  assert_output --partial "backed up to"

  [[ -f "${HOST_JSON}.bak" ]]
  # Output is a valid object that kept the persisted project state.
  run jq -e 'type=="object"' "$OUT"
  assert_success
  run jq -r '.hasCompletedOnboarding' "$OUT"
  assert_output "true"
}

# ── defensive: stray directory where the output file should be ──────────────

@test "build: replaces a stray directory at the output path with a regular file" {
  echo '{"userID":"u1"}' > "$HOST_JSON"
  # Simulate Docker having auto-created the bind source as a directory.
  mkdir -p "$OUT/oops"

  _build_project_claude_json "$OUT"

  [[ -f "$OUT" ]]
  run jq -r '.userID' "$OUT"
  assert_output "u1"
}

# ── degraded path: no jq available ──────────────────────────────────────────

@test "build: with no jq, falls back to host seed and still produces a valid file" {
  echo '{"userID":"u1"}' > "$HOST_JSON"
  rm -f "$OUT"
  # Shadow jq with a PATH that has none of it.
  local nojq="$TEST_TEMP/nojq-bin"
  mkdir -p "$nojq"
  for t in bash cat cp mv mkdir rm dirname echo tr; do
    ln -sf "$(command -v "$t")" "$nojq/$t" 2>/dev/null || true
  done

  PATH="$nojq" run _build_project_claude_json "$OUT"
  assert_success
  [[ -f "$OUT" ]]
  run cat "$OUT"
  assert_output --partial '"userID"'
}

@test "build: with no jq and no host file, still produces an empty valid file" {
  rm -f "$HOST_JSON" "$OUT"
  local nojq="$TEST_TEMP/nojq-bin"
  mkdir -p "$nojq"
  for t in bash cat cp mv mkdir rm dirname echo tr; do
    ln -sf "$(command -v "$t")" "$nojq/$t" 2>/dev/null || true
  done

  PATH="$nojq" run _build_project_claude_json "$OUT"
  assert_success
  [[ -f "$OUT" ]]
}

@test "build: with no jq, a truncated host file is caught and NOT copied into the container" {
  # The dominant corruption mode (truncated write → "Unexpected EOF"). Without
  # jq the pure-bash heuristic must still catch it so it can't be propagated.
  printf '{"oauthAccount": {' > "$HOST_JSON"
  rm -f "$OUT"
  local nojq="$TEST_TEMP/nojq-bin"
  mkdir -p "$nojq"
  for t in bash cat cp mv mkdir rm dirname echo tr; do
    ln -sf "$(command -v "$t")" "$nojq/$t" 2>/dev/null || true
  done

  PATH="$nojq" run _build_project_claude_json "$OUT"
  assert_success
  assert_output --partial "backed up to"
  [[ -f "${HOST_JSON}.bak" ]]
  # The corrupt content must NOT have been copied into the mounted file.
  run cat "$OUT"
  refute_output --partial 'oauthAccount'
}

@test "build: with no jq, a truncated host file falls back to the persisted copy" {
  printf '{"truncated' > "$HOST_JSON"
  mkdir -p "$(dirname "$OUT")"
  echo '{"hasCompletedOnboarding":true}' > "$OUT"   # prior good per-project copy
  local nojq="$TEST_TEMP/nojq-bin"
  mkdir -p "$nojq"
  for t in bash cat cp mv mkdir rm dirname echo tr; do
    ln -sf "$(command -v "$t")" "$nojq/$t" 2>/dev/null || true
  done

  PATH="$nojq" run _build_project_claude_json "$OUT"
  assert_success
  # Prior good copy is kept (corruption did not overwrite it).
  run cat "$OUT"
  assert_output --partial 'hasCompletedOnboarding'
}

# ── the pure-bash heuristic itself ──────────────────────────────────────────

@test "looks_like_json_object: accepts objects, rejects truncation and non-objects" {
  printf '{"a":1}\n'        > "$TEST_TEMP/ok.json"        && _looks_like_json_object "$TEST_TEMP/ok.json"
  printf '   \n {"a":1}  '  > "$TEST_TEMP/ws.json"        && _looks_like_json_object "$TEST_TEMP/ws.json"
  printf '{"a": {'          > "$TEST_TEMP/trunc.json"     && ! _looks_like_json_object "$TEST_TEMP/trunc.json"
  printf '[1,2,3]'          > "$TEST_TEMP/arr.json"       && ! _looks_like_json_object "$TEST_TEMP/arr.json"
  printf ''                 > "$TEST_TEMP/empty.json"     && ! _looks_like_json_object "$TEST_TEMP/empty.json"
}
