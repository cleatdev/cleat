#!/usr/bin/env bats
# Boxes: adversarial hardening (see concept/20-boxes.md).
# Hostile inputs, format-boundary edges, and the seams between the new box code
# and the existing trust/caps system. These are the release-blocker hunters.
load "../setup"
setup() {
  _common_setup
  use_docker_stub
  source_cli
  _host_clip_cmd() { echo ""; }
  check_for_update() { true; }
  check_drift() { true; }
  _resolve_config_drift() { true; }
}
teardown() { _common_teardown; }

# ── Box-name validation: control chars & boundaries ─────────────────────────

@test "harden: box name rejects an embedded newline" {
  run _validate_box_name "$(printf 'a\nb')"
  assert_failure
}

@test "harden: box name rejects a trailing newline" {
  # Use $'...' (command substitution would strip the trailing newline).
  local b=$'az\n'
  run _validate_box_name "$b"
  assert_failure
}

@test "harden: box name rejects an embedded tab" {
  run _validate_box_name "$(printf 'a\tb')"
  assert_failure
}

@test "harden: box name rejects a high-bit / unicode char" {
  run _validate_box_name "café"
  assert_failure
}

@test "harden: 'main' is itself a valid box name (the default)" {
  run _validate_box_name "main"
  assert_success
}

# ── Description safety: never executed, never interpreted ───────────────────

@test "harden: a description with shell metacharacters is never executed" {
  mkdir -p "$TEST_TEMP/project"; cd "$TEST_TEMP/project"
  local marker="$TEST_TEMP/PWNED"
  cmd_describe az "\$(touch '$marker'); \`touch '$marker'\`; a&b|c;" >/dev/null
  [[ ! -e "$marker" ]] || { echo "description text was executed!"; return 1; }
  run cmd_describe az
  assert_output --partial '$(touch'
}

@test "harden: a description with backslash escapes is shown LITERALLY (no echo -e mangling)" {
  mkdir -p "$TEST_TEMP/project"; cd "$TEST_TEMP/project"
  cmd_describe az 'col\t1 \033[31mRED end' >/dev/null
  run cmd_describe az
  # The literal backslash sequences must survive display, not become a tab or
  # a real ANSI escape.
  assert_output --partial '\t'
  assert_output --partial '\033'
}

@test "harden: a description is shown LITERALLY in cleat status too" {
  mkdir -p "$TEST_TEMP/project"
  local cname; cname="$(container_name_for "$TEST_TEMP/project" main)"
  _box_desc_write "$cname" 'wipe\033[2J tab\t end $(x)'
  run cmd_status "$TEST_TEMP/project"
  assert_output --partial '\033'
  assert_output --partial '\t'
  assert_output --partial '$(x)'
}

@test "harden: an empty description argument is accepted without crashing" {
  mkdir -p "$TEST_TEMP/project"; cd "$TEST_TEMP/project"
  run cmd_describe az ""
  assert_success
}

# ── Per-box caps boundary: replace-with-nothing & non-cap content ───────────

@test "harden: an empty .cleat.<box> REPLACES with nothing (no project caps)" {
  mkdir -p "$TEST_TEMP/project"
  printf '[caps]\ngit\ndocker\n' > "$TEST_TEMP/project/.cleat"
  : > "$TEST_TEMP/project/.cleat.locked"     # exists but empty
  _BOX="locked"
  resolve_caps "$TEST_TEMP/project"
  run cap_is_active git;    assert_failure   # NOT inherited from .cleat
  run cap_is_active docker; assert_failure
}

@test "harden: a comment-only .cleat.<box> yields no caps" {
  mkdir -p "$TEST_TEMP/project"
  printf '[caps]\ndocker\n' > "$TEST_TEMP/project/.cleat"
  printf '# nothing enabled here\n' > "$TEST_TEMP/project/.cleat.locked"
  _BOX="locked"
  resolve_caps "$TEST_TEMP/project"
  run cap_is_active docker; assert_failure
}

@test "harden: an underscore box name resolves its own cap file" {
  mkdir -p "$TEST_TEMP/project"
  printf '[caps]\ngit\n'    > "$TEST_TEMP/project/.cleat"
  printf '[caps]\ndocker\n' > "$TEST_TEMP/project/.cleat.my_box"
  _BOX="my_box"
  resolve_caps "$TEST_TEMP/project"
  run cap_is_active docker; assert_success
  run cap_is_active git;    assert_failure
}

# ── Per-box trust boundary: mixed legacy/3-col format ───────────────────────

@test "harden: recording a named box preserves a legacy 2-col (main) row" {
  mkdir -p "$(dirname "$CLEAT_TRUST_FILE")"
  printf '%s\t%s\n' "$TEST_TEMP/project" "legacyhash" > "$CLEAT_TRUST_FILE"
  _trust_record "$TEST_TEMP/project" "azhash" az
  run _trust_lookup "$TEST_TEMP/project" main
  assert_output "legacyhash"
  run _trust_lookup "$TEST_TEMP/project" az
  assert_output "azhash"
}

@test "harden: recording main supersedes a legacy 2-col row (no leftover)" {
  mkdir -p "$(dirname "$CLEAT_TRUST_FILE")"
  printf '%s\t%s\n' "/p" "oldhash" > "$CLEAT_TRUST_FILE"
  _trust_record "/p" "newhash" main
  run _trust_lookup "/p" main
  assert_output "newhash"
  run grep "oldhash" "$CLEAT_TRUST_FILE"
  assert_failure   # the legacy hash is gone, not duplicated
}

@test "harden: trust is independent per box in a mixed-format file" {
  mkdir -p "$(dirname "$CLEAT_TRUST_FILE")"
  _trust_record "/p" "h-main" main
  _trust_record "/p" "h-az" az
  _trust_record "/p" "h-dev" dev
  run _trust_lookup "/p" main;  assert_output "h-main"
  run _trust_lookup "/p" az;    assert_output "h-az"
  run _trust_lookup "/p" dev;   assert_output "h-dev"
  run _trust_lookup "/p" ghost; assert_output ""
}

@test "harden: removing one box's trust leaves the others intact" {
  mkdir -p "$(dirname "$CLEAT_TRUST_FILE")"
  _trust_record "/p" "h-main" main
  _trust_record "/p" "h-az" az
  _trust_remove "/p" az
  run _trust_lookup "/p" az;   assert_output ""
  run _trust_lookup "/p" main; assert_output "h-main"
}

# ── Flag & config hardening ─────────────────────────────────────────────────

@test "harden: --desc with no value errors out" {
  run parse_global_flags --desc
  assert_failure
  assert_output --partial "Missing text after --desc"
}

@test "harden: cleat config rejects an invalid box name" {
  mkdir -p "$TEST_TEMP/project"; cd "$TEST_TEMP/project"
  run cmd_config "Bad/Box" --enable git
  assert_failure
  assert_output --partial "Invalid box name"
}

@test "harden: cleat clean prunes a box description whose container is gone" {
  mkdir -p "$TEST_TEMP/project"
  local cname; cname="$(container_name_for "$TEST_TEMP/project" ghost)"
  _box_desc_write "$cname" "orphan"
  [[ -f "$(_box_desc_file "$cname")" ]] || return 1
  container_exists() { return 1; }   # nothing exists → it's an orphan
  image_exists() { return 1; }
  run cmd_clean
  assert_success
  [[ ! -f "$(_box_desc_file "$cname")" ]] || { echo "orphan desc not pruned"; return 1; }
}

@test "harden: container name for a 31-char box stays within 63 chars" {
  local p result box
  p="/home/user/$(printf 'd%.0s' {1..40})"
  box="$(printf 'b%.0s' {1..31})"
  result="$(container_name_for "$p" "$box")"
  [[ ${#result} -le 63 ]] || { echo "len=${#result}: $result"; return 1; }
  [[ "$result" =~ -[0-9a-f]{8}-b{31}$ ]] || { echo "got: $result"; return 1; }
}

# ── Env summary is box-aware (review finding C) ─────────────────────────────

@test "harden: env summary reflects the box's .cleat.<box>.env, not .cleat.env" {
  mkdir -p "$TEST_TEMP/project"
  CLEAT_GLOBAL_ENV="$TEST_TEMP/noenv"
  printf '[caps]\nenv\n'        > "$TEST_TEMP/project/.cleat.az"
  printf 'AZ_ONE=1\nAZ_TWO=2\n' > "$TEST_TEMP/project/.cleat.az.env"
  printf 'X=9\n'                > "$TEST_TEMP/project/.cleat.env"
  _BOX="az"
  resolve_caps "$TEST_TEMP/project"
  run _env_summary "$TEST_TEMP/project"
  assert_output --partial ".cleat.az.env"
  assert_output --partial "2 from"
  refute_output --partial "from .cleat.env"
}

@test "harden: inline env summary is box-aware too" {
  mkdir -p "$TEST_TEMP/project"
  CLEAT_GLOBAL_ENV="$TEST_TEMP/noenv"
  printf '[caps]\nenv\n' > "$TEST_TEMP/project/.cleat.az"
  printf 'AZ_ONE=1\n'    > "$TEST_TEMP/project/.cleat.az.env"
  _BOX="az"
  resolve_caps "$TEST_TEMP/project"
  run _env_summary_inline "$TEST_TEMP/project"
  assert_output --partial ".cleat.az.env"
}

# ── Description lifecycle (review findings D, E, G) ──────────────────────────

@test "harden: cleat rm <box> removes the description even when no container existed" {
  mkdir -p "$TEST_TEMP/project"
  local cname; cname="$(container_name_for "$TEST_TEMP/project" az)"
  _box_desc_write "$cname" "described but never started"
  [[ -f "$(_box_desc_file "$cname")" ]] || return 1
  _BOX="az"
  run cmd_rm "$TEST_TEMP/project"
  assert_success
  [[ ! -f "$(_box_desc_file "$cname")" ]] || { echo "desc leaked on rm"; return 1; }
}

@test "harden: cleat stop-all removes a box's description along with its container" {
  mkdir -p "$TEST_TEMP/project"
  local cname; cname="$(container_name_for "$TEST_TEMP/project" az)"
  _box_desc_write "$cname" "az box notes"
  [[ -f "$(_box_desc_file "$cname")" ]] || return 1
  printf '%s\n' "$cname" > "$DOCKER_MOCK_DIR/ps_a_output"   # stop-all sees it
  container_exists() { return 1; }                          # ...then it's gone
  run cmd_stop_all
  assert_success
  [[ ! -f "$(_box_desc_file "$cname")" ]] || { echo "stop-all left the desc orphaned"; return 1; }
}

@test "harden: a multi-line description is stored as a single collapsed line" {
  mkdir -p "$TEST_TEMP/project"
  local cname; cname="$(container_name_for "$TEST_TEMP/project" az)"
  _box_desc_write "$cname" "$(printf 'line one\nline two\nline three')"
  local lines; lines="$(wc -l < "$(_box_desc_file "$cname")" | tr -d ' ')"
  [[ "$lines" -eq 1 ]] || { echo "expected 1 line, got $lines"; return 1; }
  run _box_desc_read "$cname"
  assert_output --partial "line one line two line three"
}
