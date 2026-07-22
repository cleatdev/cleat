#!/usr/bin/env bats
# ─────────────────────────────────────────────────────────────────────────────
# [setup] provisioning: unit tests (concept/16).
#
# Coverage:
#   1. Parser (_read_setup_from_file): section extraction, the INI hazard
#   2. Builder (_build_setup_payload / _setup_payload_hash): framing, path
#      validation, box replace semantics, hash stability
#   3. Trust store rows: the 4-column [setup] extension to the trust file
#      (_trust_record / _trust_lookup / _trust_lookup_setup / _trust_remove)
#   4. _resolve_setup_trust: every consent path (opt-in, TTY, non-TTY,
#      readonly, session cache, hash-bound cache)
#   5. _setup_trust_prompt: preview rendering, truncation, sanitization
#   6. _maybe_run_setup: the executor (marker, force, TOCTOU, failure)
#   7. Integration: config-fingerprint discipline, the 4 session-verb call
#      sites, and the kit overlay's provisioning note
#   8. cmd_setup: the explicit verb (--show, run mode, arg validation)
#   9. _warn_unknown_cleat_sections: the [setup]/[kits] scope hints
#  10. cmd_trust: the [setup] extension to the trust-recording verb
#  11. _sanitize_repo_str: the terminal-injection guard
#
# Skipped as duplicate of existing coverage (see report):
#   - cmd_trust: "file with neither caps nor setup" is already covered by
#     trust.bats's "cmd_trust: fails when .cleat has no capabilities" (same
#     code path, same partial-match text "no capabilities").
# ─────────────────────────────────────────────────────────────────────────────
load "../setup"

setup() {
  _common_setup
  use_docker_stub
  source_cli

  # Isolate every config-derived dir under TEST_TEMP (they're derived from
  # CLEAT_CONFIG_DIR at source time, before we repoint it here).
  CLEAT_CONFIG_DIR="$TEST_TEMP/cleat-config"
  CLEAT_GLOBAL_CONFIG="$CLEAT_CONFIG_DIR/config"
  CLEAT_GLOBAL_ENV="$CLEAT_CONFIG_DIR/env"
  CLEAT_RUN_DIR="$CLEAT_CONFIG_DIR/run"
  CLEAT_KITS_DIR="$CLEAT_CONFIG_DIR/kits"
  CLEAT_BOXES_DIR="$CLEAT_CONFIG_DIR/boxes"
  CLEAT_PROJECTS_DIR="$CLEAT_CONFIG_DIR/projects"
  CLEAT_TRUST_FILE="$CLEAT_CONFIG_DIR/trust"
  mkdir -p "$CLEAT_CONFIG_DIR"

  # [setup] trust is a separate consent class from project-caps trust
  # (concept/16). _common_setup exports CLEAT_TRUST_PROJECT=1 so unrelated
  # suites auto-trust caps; unset it here so [setup]'s own default-deny is
  # never masked, and re-export it only in the tests that specifically want
  # the caps side of the story.
  unset CLEAT_TRUST_PROJECT

  # Quiet the session-flow machinery unrelated to [setup] (group 7 drives
  # cmd_run/cmd_start/cmd_resume/cmd_claude directly).
  _host_clip_cmd() { echo ""; }
  check_for_update() { true; }
  check_drift() { true; }
  _resolve_config_drift() { true; }
  show_first_run_tip() { true; }

  mkdir -p "$TEST_TEMP/project"
  cd "$TEST_TEMP/project"
  PROJECT="$TEST_TEMP/project"
  CNAME="$(container_name_for "$PROJECT")"
}

teardown() { _common_teardown; }

# Helper: build the real [setup] payload for (project, box) and record it as
# trusted through the actual hash pipeline (mirrors what resolve_caps /
# _resolve_setup_trust do), printing the hash. Executor tests use this so a
# "trusted" scenario is driven by a genuine trust-file row, never merely by
# poking the _SETUP_DECLARED/_SETUP_TRUSTED globals.
_th_record_setup() {
  local project="$1" box="${2:-main}"
  local payload hash
  payload="$(_build_setup_payload "$project" "$box")"
  hash="$(_setup_payload_hash "$payload")"
  _trust_record "$project" "$(_trust_lookup "$project" "$box")" "$box" "$hash"
  printf '%s' "$hash"
}

# ── 1. Parser: _read_setup_from_file ────────────────────────────────────────

@test "read_setup: reads [setup] lines in order" {
  local f="$TEST_TEMP/proj/.cleat"
  mkdir -p "$TEST_TEMP/proj"
  printf '[setup]\nsudo apt-get update\nsudo apt-get install -y jq\n' > "$f"
  run _read_setup_from_file "$f"
  assert_success
  assert_output $'sudo apt-get update\nsudo apt-get install -y jq'
}

@test "read_setup: lines outside [setup] are excluded" {
  local f="$TEST_TEMP/proj/.cleat"
  mkdir -p "$TEST_TEMP/proj"
  printf '[caps]\ngit\n[setup]\necho hi\n[resources]\nmemory = 4g\n' > "$f"
  run _read_setup_from_file "$f"
  assert_output "echo hi"
}

@test "read_setup: comments and blank lines are skipped" {
  local f="$TEST_TEMP/proj/.cleat"
  mkdir -p "$TEST_TEMP/proj"
  printf '[setup]\n# a comment\n\necho hi\n' > "$f"
  run _read_setup_from_file "$f"
  assert_output "echo hi"
}

@test "read_setup: CRLF line endings are stripped" {
  local f="$TEST_TEMP/proj/.cleat"
  mkdir -p "$TEST_TEMP/proj"
  printf '[setup]\r\necho hi\r\n' > "$f"
  run _read_setup_from_file "$f"
  assert_output "echo hi"
}

@test "read_setup: leading and trailing whitespace is trimmed" {
  local f="$TEST_TEMP/proj/.cleat"
  mkdir -p "$TEST_TEMP/proj"
  printf '[setup]\n   echo hi   \n' > "$f"
  run _read_setup_from_file "$f"
  assert_output "echo hi"
}

@test "read_setup: the final line is read even with no trailing newline" {
  local f="$TEST_TEMP/proj/.cleat"
  mkdir -p "$TEST_TEMP/proj"
  printf '[setup]\necho first\necho last-no-newline' > "$f"
  run _read_setup_from_file "$f"
  assert_output $'echo first\necho last-no-newline'
}

@test "read_setup: any [x] line ends the section, including an INI-hazard test-command line" {
  local f="$TEST_TEMP/proj/.cleat"
  mkdir -p "$TEST_TEMP/proj"
  printf '[setup]\necho one\n[ -f /tmp/x ]\necho two\n' > "$f"
  run _read_setup_from_file "$f"
  assert_output "echo one"
  refute_output --partial "echo two"
}

@test "read_setup: the section resumes when a second [setup] header appears" {
  local f="$TEST_TEMP/proj/.cleat"
  mkdir -p "$TEST_TEMP/proj"
  printf '[setup]\nline1\n[caps]\ngit\n[setup]\nline2\n' > "$f"
  run _read_setup_from_file "$f"
  assert_output $'line1\nline2'
}

@test "read_setup: a missing file returns empty at rc 0" {
  run _read_setup_from_file "$TEST_TEMP/nope/.cleat"
  assert_success
  assert_output ""
}

@test "read_setup: [Setup] is case-sensitive and not recognized as a header" {
  local f="$TEST_TEMP/proj/.cleat"
  mkdir -p "$TEST_TEMP/proj"
  printf '[Setup]\necho hi\n' > "$f"
  run _read_setup_from_file "$f"
  assert_output ""
}

# ── 2. Builder: _build_setup_payload / _setup_payload_hash ─────────────────

@test "build_setup_payload: inline-only [setup] lines are emitted verbatim, in order" {
  printf '[setup]\nsudo apt-get update\nsudo apt-get install -y jq\n' > "$PROJECT/.cleat"
  run _build_setup_payload "$PROJECT" main
  assert_success
  assert_output $'sudo apt-get update\nsudo apt-get install -y jq'
}

@test "build_setup_payload: a script directive inlines the file's bytes between begin/end markers, leading ./ stripped" {
  printf '#!/bin/sh\necho provisioning\n' > "$PROJECT/provision.sh"
  printf '[setup]\nscript ./provision.sh\n' > "$PROJECT/.cleat"
  run _build_setup_payload "$PROJECT" main
  assert_success
  assert_output --partial "# cleat setup: begin script provision.sh"
  assert_output --partial "echo provisioning"
  assert_output --partial "# cleat setup: end script provision.sh"
  refute_output --partial "begin script ./provision.sh"
}

@test "build_setup_payload: inline and script directives interleave in file order" {
  printf 'echo two-content\n' > "$PROJECT/two.sh"
  printf '[setup]\necho one\nscript ./two.sh\necho three\n' > "$PROJECT/.cleat"
  local payload
  payload="$(_build_setup_payload "$PROJECT" main)"
  run awk '
    /^echo one$/{a=NR}
    /begin script two.sh/{b=NR}
    /^echo two-content$/{c=NR}
    /end script two.sh/{d=NR}
    /^echo three$/{e=NR}
    END{exit !(a && b && c && d && e && a<b && b<c && c<d && d<e)}
  ' <<< "$payload"
  assert_success
}

@test "build_setup_payload: a script path with spaces is inlined correctly" {
  printf 'echo spaced\n' > "$PROJECT/my script.sh"
  printf '[setup]\nscript ./my script.sh\n' > "$PROJECT/.cleat"
  run _build_setup_payload "$PROJECT" main
  assert_success
  assert_output --partial "begin script my script.sh"
  assert_output --partial "echo spaced"
}

@test "build_setup_payload: an absolute script path is refused" {
  printf '[setup]\nscript /etc/hostname\n' > "$PROJECT/.cleat"
  run _build_setup_payload "$PROJECT" main
  assert_failure
  assert_output --partial "must be project-relative"
}

@test "build_setup_payload: a script path containing '..' is refused" {
  printf '[setup]\nscript ../evil.sh\n' > "$PROJECT/.cleat"
  run _build_setup_payload "$PROJECT" main
  assert_failure
  assert_output --partial "may not contain '..'"
}

@test "build_setup_payload: a script directive of just './' resolves to an empty path and is refused" {
  printf '[setup]\nscript ./\n' > "$PROJECT/.cleat"
  run _build_setup_payload "$PROJECT" main
  assert_failure
  assert_output --partial "empty script path"
}

@test "build_setup_payload: a missing script file is refused" {
  printf '[setup]\nscript ./nope.sh\n' > "$PROJECT/.cleat"
  run _build_setup_payload "$PROJECT" main
  assert_failure
  assert_output --partial "script not found"
}

@test "build_setup_payload: a symlinked script file is refused" {
  printf 'echo real\n' > "$PROJECT/real.sh"
  ln -s "$PROJECT/real.sh" "$PROJECT/link.sh"
  printf '[setup]\nscript ./link.sh\n' > "$PROJECT/.cleat"
  run _build_setup_payload "$PROJECT" main
  assert_failure
  assert_output --partial "may not be a symlink"
}

@test "build_setup_payload: a script reached through a symlinked parent directory escaping the project root is refused" {
  mkdir -p "$TEST_TEMP/outside"
  printf 'echo outside\n' > "$TEST_TEMP/outside/file.sh"
  ln -s "$TEST_TEMP/outside" "$PROJECT/linkdir"
  printf '[setup]\nscript ./linkdir/file.sh\n' > "$PROJECT/.cleat"
  run _build_setup_payload "$PROJECT" main
  assert_failure
  assert_output --partial "escapes the project directory"
}

@test "build_setup_payload: no [setup] section, or no .cleat at all, yields empty stdout at rc 0" {
  run _build_setup_payload "$PROJECT" main
  assert_success
  assert_output ""
  printf '[caps]\ngit\n' > "$PROJECT/.cleat"
  run _build_setup_payload "$PROJECT" main
  assert_success
  assert_output ""
}

@test "build_setup_payload: a box's .cleat.<box> [setup] fully replaces .cleat's, it never merges" {
  printf '[setup]\necho from-main\n' > "$PROJECT/.cleat"
  printf '[setup]\necho from-dev\n' > "$PROJECT/.cleat.dev"
  run _build_setup_payload "$PROJECT" dev
  assert_success
  assert_output "echo from-dev"
  refute_output --partial "from-main"
}

@test "setup_payload_hash: stable for an identical payload, changes on any inline edit" {
  local h1 h2 h3
  h1="$(_setup_payload_hash "echo one")"
  h2="$(_setup_payload_hash "echo one")"
  [[ "$h1" == "$h2" ]] || { echo "unstable: $h1 vs $h2"; return 1; }
  h3="$(_setup_payload_hash "echo one!")"
  [[ "$h1" != "$h3" ]] || { echo "an inline edit didn't change the hash"; return 1; }
}

@test "setup_payload_hash: changes when only the referenced script file's content changes" {
  printf 'echo v1\n' > "$PROJECT/provision.sh"
  printf '[setup]\nscript ./provision.sh\n' > "$PROJECT/.cleat"
  local payload1 h1
  payload1="$(_build_setup_payload "$PROJECT" main)"
  h1="$(_setup_payload_hash "$payload1")"
  printf 'echo v2\n' > "$PROJECT/provision.sh"
  local payload2 h2
  payload2="$(_build_setup_payload "$PROJECT" main)"
  h2="$(_setup_payload_hash "$payload2")"
  [[ "$h1" != "$h2" ]] || { echo "hash unchanged after the script file's content changed"; return 1; }
}

# ── 3. Trust store rows ─────────────────────────────────────────────────────

@test "trust store: 3-arg _trust_record writes an exact path TAB box TAB hash row" {
  _trust_record "/fake/proj" "capshash1" "main"
  local row expected
  row="$(awk -F'\t' '$1=="/fake/proj"' "$CLEAT_TRUST_FILE")"
  expected="$(printf '/fake/proj\tmain\tcapshash1')"
  [[ "$row" == "$expected" ]] || { echo "got: $row"; return 1; }
}

@test "trust store: 4-arg _trust_record writes path/box/capshash/setuphash, and _trust_lookup reads col3 back" {
  _trust_record "/fake/proj" "capshash1" "main" "setuphash1"
  local row expected
  row="$(awk -F'\t' '$1=="/fake/proj"' "$CLEAT_TRUST_FILE")"
  expected="$(printf '/fake/proj\tmain\tcapshash1\tsetuphash1')"
  [[ "$row" == "$expected" ]] || { echo "got: $row"; return 1; }
  run _trust_lookup "/fake/proj" "main"
  assert_output "capshash1"
}

@test "trust store: a 4-col row with an empty caps hash writes '-' in col3" {
  _trust_record "/fake/proj" "" "main" "setuphash1"
  local row expected
  row="$(awk -F'\t' '$1=="/fake/proj"' "$CLEAT_TRUST_FILE")"
  expected="$(printf '/fake/proj\tmain\t-\tsetuphash1')"
  [[ "$row" == "$expected" ]] || { echo "got: $row"; return 1; }
}

@test "trust store: _trust_lookup_setup is empty for a legacy 3-col row" {
  _trust_record "/fake/proj" "capshash1" "main"
  run _trust_lookup_setup "/fake/proj" "main"
  assert_output ""
}

@test "trust store: approving caps through the real trust-approval path preserves an existing col4" {
  printf '[caps]\ndocker\n' > "$PROJECT/.cleat"
  _trust_record "$PROJECT" "" main "priorsetuphash"
  export CLEAT_TRUST_PROJECT=1
  resolve_caps "$PROJECT" >/dev/null 2>&1
  run _trust_lookup_setup "$PROJECT" main
  assert_output "priorsetuphash"
}

@test "trust store: _trust_remove drops a 4-col row entirely" {
  _trust_record "/fake/proj" "capshash1" "main" "setuphash1"
  _trust_remove "/fake/proj" "main"
  run _trust_lookup "/fake/proj" "main"
  assert_output ""
  run _trust_lookup_setup "/fake/proj" "main"
  assert_output ""
}

@test "trust store: CLEAT_TRUST_PROJECT=1 auto-approval of a caps-only file never creates a col4" {
  printf '[caps]\ndocker\n' > "$PROJECT/.cleat"
  export CLEAT_TRUST_PROJECT=1
  resolve_caps "$PROJECT" >/dev/null 2>&1
  local cols
  cols="$(awk -F'\t' -v p="$PROJECT" '$1==p {print NF}' "$CLEAT_TRUST_FILE")"
  [[ "$cols" == "3" ]] || { echo "expected 3 columns, got $cols"; return 1; }
}

@test "trust store: interactive caps-approval preserves an existing [setup] col4" {
  printf '[caps]\ndocker\n\n[setup]\necho hi\n' > "$PROJECT/.cleat"
  local setup_hash
  setup_hash="$(_th_record_setup "$PROJECT" main)"
  unset CLEAT_TRUST_PROJECT
  _is_tty() { return 0; }
  resolve_caps "$PROJECT" <<< "y" >/dev/null 2>&1
  run _trust_lookup_setup "$PROJECT" main
  assert_output "$setup_hash"
}

@test "trust store: a per-box setup hash is not visible to the main box" {
  _trust_record "/p" "" dev "devhash"
  run _trust_lookup_setup "/p" main
  assert_output ""
  run _trust_lookup_setup "/p" dev
  assert_output "devhash"
}

# ── 4. _resolve_setup_trust ─────────────────────────────────────────────────

@test "resolve_setup_trust: a caps-only file never declares [setup]" {
  printf '[caps]\ngit\n' > "$PROJECT/.cleat"
  export CLEAT_TRUST_PROJECT=1
  resolve_caps "$PROJECT" >/dev/null 2>&1
  [[ "$_SETUP_DECLARED" == "0" ]] || { echo "declared=$_SETUP_DECLARED"; return 1; }
}

@test "resolve_setup_trust: non-TTY with no opt-in warns 'skipped in non-interactive' and stays untrusted" {
  printf '[setup]\necho hi\n' > "$PROJECT/.cleat"
  _is_tty() { return 1; }
  run resolve_caps "$PROJECT"
  assert_success
  assert_output --partial "skipped in non-interactive"
  resolve_caps "$PROJECT" >/dev/null 2>&1
  [[ "$_SETUP_TRUSTED" == "0" ]] || { echo "trusted=$_SETUP_TRUSTED"; return 1; }
}

@test "resolve_setup_trust: CLEAT_TRUST_SETUP=1 auto-trusts and records the row (col3 '-' when caps-less)" {
  printf '[setup]\necho hi\n' > "$PROJECT/.cleat"
  export CLEAT_TRUST_SETUP=1
  resolve_caps "$PROJECT" >/dev/null 2>&1
  [[ "$_SETUP_TRUSTED" == "1" ]] || { echo "trusted=$_SETUP_TRUSTED"; return 1; }
  # NOTE: not `assert_output "-"`: bats-assert treats a bare "-" as its
  # --stdin flag, not a literal expected value, so compare directly.
  local col3
  col3="$(_trust_lookup "$PROJECT" main)"
  [[ "$col3" == "-" ]] || { echo "got: $col3"; return 1; }
}

@test "resolve_setup_trust: the --trust-setup flag variable (_CLI_TRUST_SETUP) auto-trusts the same way" {
  printf '[setup]\necho hi\n' > "$PROJECT/.cleat"
  _CLI_TRUST_SETUP=1
  resolve_caps "$PROJECT" >/dev/null 2>&1
  [[ "$_SETUP_TRUSTED" == "1" ]] || { echo "trusted=$_SETUP_TRUSTED"; return 1; }
  run _trust_lookup_setup "$PROJECT" main
  refute_output ""
  _CLI_TRUST_SETUP=0
}

@test "resolve_setup_trust: a stored hash matching the current payload trusts silently, with no prompt" {
  printf '[setup]\necho hi\n' > "$PROJECT/.cleat"
  _th_record_setup "$PROJECT" main >/dev/null
  _is_tty() { return 0; }
  run resolve_caps "$PROJECT" <<< "n"
  assert_success
  refute_output --partial "wants to run"
  resolve_caps "$PROJECT" <<< "n" >/dev/null 2>&1
  [[ "$_SETUP_TRUSTED" == "1" ]] || { echo "trusted=$_SETUP_TRUSTED"; return 1; }
}

@test "resolve_setup_trust: a stale stored hash triggers the re-prompt wording, declining it stays untrusted" {
  printf '[setup]\necho one\n' > "$PROJECT/.cleat"
  _th_record_setup "$PROJECT" main >/dev/null
  printf '[setup]\necho one\necho two\n' > "$PROJECT/.cleat"
  _is_tty() { return 0; }
  run resolve_caps "$PROJECT" <<< "n"
  assert_success
  assert_output --partial "changed since you approved"
  resolve_caps "$PROJECT" <<< "n" >/dev/null 2>&1
  [[ "$_SETUP_TRUSTED" == "0" ]] || { echo "trusted=$_SETUP_TRUSTED"; return 1; }
}

@test "resolve_setup_trust: a TTY accept trusts and records the trust row" {
  printf '[setup]\necho hi\n' > "$PROJECT/.cleat"
  _is_tty() { return 0; }
  run resolve_caps "$PROJECT" <<< "y"
  assert_success
  assert_output --partial "Run this project's setup commands?"
  resolve_caps "$PROJECT" <<< "y" >/dev/null 2>&1
  [[ "$_SETUP_TRUSTED" == "1" ]] || { echo "trusted=$_SETUP_TRUSTED"; return 1; }
  run _trust_lookup_setup "$PROJECT" main
  refute_output ""
}

@test "resolve_setup_trust: a TTY decline (or empty answer) warns 'not approved' and records nothing" {
  printf '[setup]\necho hi\n' > "$PROJECT/.cleat"
  _is_tty() { return 0; }
  run resolve_caps "$PROJECT" <<< "n"
  assert_output --partial "skipped, not approved"
  run resolve_caps "$PROJECT" <<< ""
  assert_output --partial "skipped, not approved"
  resolve_caps "$PROJECT" <<< "n" >/dev/null 2>&1
  [[ "$_SETUP_TRUSTED" == "0" ]] || return 1
  run _trust_lookup_setup "$PROJECT" main
  assert_output ""
}

@test "resolve_setup_trust: readonly mode never prompts, warns, or trusts" {
  printf '[setup]\necho hi\n' > "$PROJECT/.cleat"
  _is_tty() { return 0; }  # even if TTY, readonly must stay silent
  run resolve_caps "$PROJECT" readonly
  assert_success
  refute_output --partial "wants to run"
  refute_output --partial "skipped"
  resolve_caps "$PROJECT" readonly >/dev/null 2>&1
  [[ "$_SETUP_TRUSTED" == "0" ]] || return 1
}

@test "resolve_setup_trust: the session cache avoids a second prompt within one process" {
  printf '[setup]\necho hi\n' > "$PROJECT/.cleat"
  _is_tty() { return 0; }
  resolve_caps "$PROJECT" <<< "y" >/dev/null 2>&1
  [[ "$_SETUP_TRUSTED" == "1" ]] || return 1
  local second
  second="$(resolve_caps "$PROJECT" 2>&1)"
  [[ "$second" != *"wants to run"* ]] || { echo "re-prompted: $second"; return 1; }
}

@test "resolve_setup_trust: a declined [setup] is not re-prompted in the same process (rejected session cache)" {
  printf '[setup]\necho hi\n' > "$PROJECT/.cleat"
  unset CLEAT_TRUST_SETUP
  _is_tty() { return 0; }
  resolve_caps "$PROJECT" <<< "n" >/dev/null 2>&1
  [[ "$_SETUP_TRUSTED" == "0" ]] || { echo "trusted=$_SETUP_TRUSTED"; return 1; }
  local second
  second="$(resolve_caps "$PROJECT" 2>&1)"
  [[ "$second" != *"wants to run"* ]] || { echo "re-prompted: $second"; return 1; }
  [[ "$second" != *"skipped, not approved"* ]] || { echo "re-warned: $second"; return 1; }
}

@test "resolve_setup_trust: rewriting [setup] mid-process invalidates the hash-bound session cache" {
  printf '[setup]\necho hi\n' > "$PROJECT/.cleat"
  export CLEAT_TRUST_SETUP=1
  resolve_caps "$PROJECT" >/dev/null 2>&1
  [[ "$_SETUP_TRUSTED" == "1" ]] || return 1
  unset CLEAT_TRUST_SETUP
  printf '[setup]\necho hi\necho again\n' > "$PROJECT/.cleat"
  _is_tty() { return 1; }
  resolve_caps "$PROJECT" >/dev/null 2>&1
  [[ "$_SETUP_TRUSTED" == "0" ]] || { echo "stale cache leaked trust"; return 1; }
}

@test "resolve_setup_trust: CLEAT_TRUST_PROJECT=1 auto-trusts caps but never [setup]" {
  printf '[caps]\ndocker\n\n[setup]\necho hi\n' > "$PROJECT/.cleat"
  export CLEAT_TRUST_PROJECT=1
  _is_tty() { return 1; }
  resolve_caps "$PROJECT" >/dev/null 2>&1
  cap_is_active docker || { echo "docker cap missing"; return 1; }
  [[ "$_SETUP_TRUSTED" == "0" ]] || { echo "setup unexpectedly trusted"; return 1; }
}

@test "resolve_setup_trust: an invalid [setup] script directive never blocks caps resolution" {
  printf '[caps]\ndocker\n\n[setup]\nscript /etc/hostname\n' > "$PROJECT/.cleat"
  export CLEAT_TRUST_PROJECT=1
  run resolve_caps "$PROJECT"
  assert_success
  assert_output --partial "must be project-relative"
  resolve_caps "$PROJECT" >/dev/null 2>&1
  [[ "$_SETUP_DECLARED" == "0" ]] || { echo "declared=$_SETUP_DECLARED"; return 1; }
  cap_is_active docker || { echo "docker cap missing; ACTIVE_CAPS=${ACTIVE_CAPS[*]+${ACTIVE_CAPS[*]}}"; return 1; }
}

# ── 5. Prompt rendering: _setup_trust_prompt ────────────────────────────────

@test "setup_trust_prompt: payload lines are shown in the preview" {
  run _setup_trust_prompt "$PROJECT" "echo hello-preview" 1 <<< "n"
  assert_output --partial "echo hello-preview"
}

@test "setup_trust_prompt: payloads over 15 lines truncate with a '+N more' note and a --show pointer" {
  local payload
  payload="$(printf 'line%d\n' $(seq 1 20))"
  run _setup_trust_prompt "$PROJECT" "$payload" 20 <<< "n"
  assert_output --partial "+5 more"
  assert_output --partial "cleat setup --show"
}

@test "setup_trust_prompt: the declared command count appears in the prompt" {
  run _setup_trust_prompt "$PROJECT" "echo hi" 4 <<< "n"
  assert_output --partial "4 command(s)"
}

@test "setup_trust_prompt: re-prompt wording appears once a prior approval (col4) exists" {
  _trust_record "$PROJECT" "" main "priorhash"
  run _setup_trust_prompt "$PROJECT" "echo hi" 1 <<< "n"
  assert_output --partial "changed since you approved"
}

@test "setup_trust_prompt: a raw ESC byte never reaches output; a literal backslash sequence stays literal text" {
  local payload esc
  payload="$(printf 'echo hi\n\x1bBADESC\n\\033[8m\n')"
  esc="$(printf '\x1b')"
  run _setup_trust_prompt "$PROJECT" "$payload" 3 <<< "n"
  # The rendered prompt legitimately contains OTHER raw ESC bytes (the
  # CLI's own BOLD/DIM/RESET color codes), so a blanket refute of any ESC
  # byte would false-fail; check the specific injected sequence instead.
  assert_output --partial "BADESC"
  refute_output --partial "${esc}BADESC"
  assert_output --partial "033"
}

# ── 6. Executor: _maybe_run_setup ───────────────────────────────────────────

@test "maybe_run_setup: no-op when undeclared, untrusted, or the container isn't running" {
  printf '[setup]\necho hi\n' > "$PROJECT/.cleat"

  # Case 1: nothing declared.
  _SETUP_DECLARED=0; _SETUP_TRUSTED=0
  run _maybe_run_setup "$CNAME" "$PROJECT" main
  assert_success
  run docker_exec_calls
  refute_output --partial "bash -e /home/coder/.cleat-setup.run"

  # Case 2: declared but untrusted.
  _SETUP_DECLARED=1; _SETUP_TRUSTED=0
  run _maybe_run_setup "$CNAME" "$PROJECT" main
  assert_success
  run docker_exec_calls
  refute_output --partial "bash -e /home/coder/.cleat-setup.run"

  # Case 3: declared, genuinely trusted, but the container isn't running.
  _th_record_setup "$PROJECT" main >/dev/null
  _SETUP_DECLARED=1; _SETUP_TRUSTED=1
  is_running() { return 1; }
  run _maybe_run_setup "$CNAME" "$PROJECT" main
  assert_success
  run docker_exec_calls
  refute_output --partial "bash -e /home/coder/.cleat-setup.run"
}

@test "maybe_run_setup: execution is gated on the trust file's stored hash, not merely on the caller's flags" {
  printf '[setup]\necho hi\n' > "$PROJECT/.cleat"
  # Deliberately no _th_record_setup call: no real approval was ever
  # recorded for this payload's hash. Poking the flags alone must not be
  # enough to make the payload run.
  _SETUP_DECLARED=1; _SETUP_TRUSTED=1
  mock_docker_ps "$CNAME"
  run _maybe_run_setup "$CNAME" "$PROJECT" main
  assert_success
  assert_output --partial "changed since it was approved"
  run docker_exec_calls
  refute_output --partial "bash -e /home/coder/.cleat-setup.run"
}

@test "maybe_run_setup: trusted with no run-once marker executes the payload as coder" {
  printf '[setup]\necho hi\n' > "$PROJECT/.cleat"
  _th_record_setup "$PROJECT" main >/dev/null
  _SETUP_DECLARED=1; _SETUP_TRUSTED=1
  mock_docker_ps "$CNAME"
  run _maybe_run_setup "$CNAME" "$PROJECT" main
  assert_success
  run assert_docker_exec_has "-e HOME=/home/coder -w /workspace"
  assert_success
  run assert_docker_exec_has "runuser -u coder -- bash -e /home/coder/.cleat-setup.run"
  assert_success
}

@test "maybe_run_setup: a run-once marker matching the current hash skips re-execution" {
  printf '[setup]\necho hi\n' > "$PROJECT/.cleat"
  local hash
  hash="$(_th_record_setup "$PROJECT" main)"
  _SETUP_DECLARED=1; _SETUP_TRUSTED=1
  mock_docker_ps "$CNAME"
  docker() {
    if [[ "$1" == "exec" ]]; then
      local a
      for a in "$@"; do
        [[ "$a" == "/home/coder/.cleat-setup-applied" ]] && { printf '%s' "$hash"; return 0; }
      done
    fi
    command docker "$@"
  }
  run _maybe_run_setup "$CNAME" "$PROJECT" main
  assert_success
  run docker_exec_calls
  refute_output --partial "bash -e /home/coder/.cleat-setup.run"
}

@test "maybe_run_setup: a run-once marker for a different hash re-executes" {
  printf '[setup]\necho hi\n' > "$PROJECT/.cleat"
  _th_record_setup "$PROJECT" main >/dev/null
  _SETUP_DECLARED=1; _SETUP_TRUSTED=1
  mock_docker_ps "$CNAME"
  docker() {
    if [[ "$1" == "exec" ]]; then
      local a
      for a in "$@"; do
        [[ "$a" == "/home/coder/.cleat-setup-applied" ]] && { printf 'stale-marker'; return 0; }
      done
    fi
    command docker "$@"
  }
  run _maybe_run_setup "$CNAME" "$PROJECT" main
  assert_success
  run assert_docker_exec_has "runuser -u coder -- bash -e /home/coder/.cleat-setup.run"
  assert_success
}

@test "maybe_run_setup: the force flag re-runs even when the marker already matches, without querying it" {
  printf '[setup]\necho hi\n' > "$PROJECT/.cleat"
  _th_record_setup "$PROJECT" main >/dev/null
  _SETUP_DECLARED=1; _SETUP_TRUSTED=1
  mock_docker_ps "$CNAME"
  run _maybe_run_setup "$CNAME" "$PROJECT" main 1
  assert_success
  run assert_docker_exec_has "runuser -u coder -- bash -e /home/coder/.cleat-setup.run"
  assert_success
  run docker_exec_calls
  refute_output --partial "cat /home/coder/.cleat-setup-applied"
}

@test "maybe_run_setup: a successful run writes the marker and prints 'Setup applied'" {
  printf '[setup]\necho hi\n' > "$PROJECT/.cleat"
  _th_record_setup "$PROJECT" main >/dev/null
  _SETUP_DECLARED=1; _SETUP_TRUSTED=1
  mock_docker_ps "$CNAME"
  run _maybe_run_setup "$CNAME" "$PROJECT" main
  assert_success
  assert_output --partial "Setup applied"
  run assert_docker_exec_has "tee /home/coder/.cleat-setup-applied"
  assert_success
}

@test "maybe_run_setup: a failing payload warns, skips the marker, and records the exit code" {
  printf '[setup]\nexit 5\n' > "$PROJECT/.cleat"
  _th_record_setup "$PROJECT" main >/dev/null
  _SETUP_DECLARED=1; _SETUP_TRUSTED=1
  mock_docker_ps "$CNAME"
  docker() {
    [[ "$1" == "exec" && "$*" == *"bash -e /home/coder/.cleat-setup.run"* ]] && return 5
    command docker "$@"
  }
  _maybe_run_setup "$CNAME" "$PROJECT" main > "$TEST_TEMP/out.txt" 2>&1
  local rc=$?
  run cat "$TEST_TEMP/out.txt"
  assert_output --partial "Setup failed with exit code 5"
  [[ "$rc" == "0" ]] || { echo "unexpected outer rc: $rc"; return 1; }
  [[ "$_SETUP_LAST_RC" == "5" ]] || { echo "got _SETUP_LAST_RC=$_SETUP_LAST_RC"; return 1; }
  run docker_exec_calls
  refute_output --partial "tee /home/coder/.cleat-setup-applied"
}

@test "maybe_run_setup: [setup] rewritten after approval but before execution is skipped, never run stale" {
  printf '[setup]\necho hi\n' > "$PROJECT/.cleat"
  _th_record_setup "$PROJECT" main >/dev/null
  _SETUP_DECLARED=1; _SETUP_TRUSTED=1
  mock_docker_ps "$CNAME"
  # Simulate an in-box (or racing) edit between approval and this exec.
  printf '[setup]\necho hi\necho a-late-addition\n' > "$PROJECT/.cleat"
  run _maybe_run_setup "$CNAME" "$PROJECT" main
  assert_success
  assert_output --partial "changed since it was approved"
  run docker_exec_calls
  refute_output --partial "bash -e /home/coder/.cleat-setup.run"
}

# ── 7. Integration points ───────────────────────────────────────────────────

@test "integration: adding or editing [setup] never changes the config fingerprint (no-recreate guarantee)" {
  printf '[caps]\ngit\n' > "$PROJECT/.cleat"
  export CLEAT_TRUST_PROJECT=1
  resolve_caps "$PROJECT"
  resolve_env_args "$PROJECT"
  local h1
  h1="$(compute_config_fingerprint "$PROJECT")"

  printf '[caps]\ngit\n\n[setup]\necho hello\n' > "$PROJECT/.cleat"
  resolve_caps "$PROJECT"
  resolve_env_args "$PROJECT"
  local h2
  h2="$(compute_config_fingerprint "$PROJECT")"
  [[ "$h1" == "$h2" ]] || { echo "adding [setup] changed the fingerprint"; return 1; }

  printf '[caps]\ngit\n\n[setup]\necho different-now\necho more\n' > "$PROJECT/.cleat"
  resolve_caps "$PROJECT"
  resolve_env_args "$PROJECT"
  local h3
  h3="$(compute_config_fingerprint "$PROJECT")"
  [[ "$h1" == "$h3" ]] || { echo "editing [setup] changed the fingerprint"; return 1; }
}

@test "integration: cmd_run's tail applies [setup] on a fresh create" {
  printf '[setup]\necho hi\n' > "$PROJECT/.cleat"
  export CLEAT_TRUST_SETUP=1
  _is_tty() { return 1; }
  is_running() {
    [[ "$1" == "$CNAME" ]] || return 1
    grep -q -- "--name $CNAME" "$DOCKER_CALLS" 2>/dev/null
  }
  run cmd_run "$PROJECT"
  assert_success
  run assert_docker_exec_has "runuser -u coder -- bash -e /home/coder/.cleat-setup.run"
  assert_success
}

@test "integration: cmd_start's tail applies [setup]" {
  printf '[setup]\necho hi\n' > "$PROJECT/.cleat"
  export CLEAT_TRUST_SETUP=1
  _is_tty() { return 1; }
  mock_docker_images "cleat"
  mock_docker_ps "$CNAME"
  mock_docker_ps_a "$CNAME"
  run cmd_start "$PROJECT"
  assert_success
  run assert_docker_exec_has "runuser -u coder -- bash -e /home/coder/.cleat-setup.run"
  assert_success
}

@test "integration: cmd_resume's tail applies [setup]" {
  printf '[setup]\necho hi\n' > "$PROJECT/.cleat"
  export CLEAT_TRUST_SETUP=1
  _is_tty() { return 1; }
  mock_docker_images "cleat"
  mock_docker_ps "$CNAME"
  mock_docker_ps_a "$CNAME"
  run cmd_resume "$PROJECT"
  assert_success
  run assert_docker_exec_has "runuser -u coder -- bash -e /home/coder/.cleat-setup.run"
  assert_success
}

@test "integration: cmd_claude applies [setup] before attaching" {
  printf '[setup]\necho hi\n' > "$PROJECT/.cleat"
  export CLEAT_TRUST_SETUP=1
  _is_tty() { return 1; }
  mock_docker_ps "$CNAME"
  mock_docker_ps_a "$CNAME"
  run cmd_claude "$PROJECT"
  assert_success
  run assert_docker_exec_has "runuser -u coder -- bash -e /home/coder/.cleat-setup.run"
  assert_success
}

@test "integration: the kit overlay CLAUDE.md gains the box-provisioning [setup] guidance on a vanilla box" {
  _generate_kit_overlay "$CNAME"
  run cat "$CLEAT_RUN_DIR/$CNAME/kit/CLAUDE.md"
  assert_output --partial "Cleat box provisioning"
  assert_output --partial "[setup]"
  assert_output --partial "sudo apt-get install"
}

# ── 8. cmd_setup verb ────────────────────────────────────────────────────────

@test "cmd_setup --help: exits 0 with usage" {
  run cmd_setup --help
  assert_success
  assert_output --partial "Usage: cleat setup"
}

@test "cmd_setup: an unknown flag is an error" {
  run cmd_setup --bogus
  assert_failure
  assert_output --partial "Unknown setup option"
}

@test "cmd_setup: an invalid box name errors with the naming hint" {
  run cmd_setup "BAD_BOX!"
  assert_failure
  assert_output --partial "Invalid box name"
  assert_output --partial "Box names:"
}

@test "cmd_setup: no .cleat reports 'No [setup] section' and exits 0" {
  run cmd_setup
  assert_success
  assert_output --partial "No [setup] section"
}

@test "cmd_setup: a broken script directive reports 'Project [setup] is invalid' and exits 1" {
  printf '[setup]\nscript /etc/hostname\n' > "$PROJECT/.cleat"
  run cmd_setup
  assert_failure
  assert_output --partial "Project [setup] is invalid"
}

@test "cmd_setup --show: prints Source/Commands/Hash/Trust/Marker and the payload, pending before approval and approved after" {
  printf '[setup]\necho hi\n' > "$PROJECT/.cleat"
  run cmd_setup --show
  assert_success
  assert_output --partial "Source:"
  assert_output --partial "Commands:"
  assert_output --partial "Hash:"
  assert_output --partial "Trust:"
  assert_output --partial "Marker:"
  assert_output --partial "pending approval"
  assert_output --partial "echo hi"

  # --show never records trust: readonly resolve_caps must leave the trust
  # store untouched even after we've displayed it.
  run _trust_lookup_setup "$PROJECT" main
  assert_output ""

  # Approve for real, then confirm --show reflects it.
  export CLEAT_TRUST_SETUP=1
  _is_tty() { return 1; }
  resolve_caps "$PROJECT" >/dev/null 2>&1
  unset CLEAT_TRUST_SETUP
  run cmd_setup --show
  assert_success
  assert_output --partial "approved"
  refute_output --partial "pending approval"
}

@test "cmd_setup --show: reports 'unknown (box not running)' when the box is down" {
  printf '[setup]\necho hi\n' > "$PROJECT/.cleat"
  _th_record_setup "$PROJECT" main >/dev/null
  run cmd_setup --show
  assert_success
  assert_output --partial "unknown (box not running)"
}

@test "cmd_setup --show: reports 'applied' when the in-box marker matches" {
  printf '[setup]\necho hi\n' > "$PROJECT/.cleat"
  local hash
  hash="$(_th_record_setup "$PROJECT" main)"
  mock_docker_ps "$CNAME"
  docker() {
    if [[ "$1" == "exec" ]]; then
      local a
      for a in "$@"; do
        [[ "$a" == "/home/coder/.cleat-setup-applied" ]] && { printf '%s' "$hash"; return 0; }
      done
    fi
    command docker "$@"
  }
  run cmd_setup --show
  assert_success
  assert_output --partial "Marker:"
  assert_output --partial "applied"
  refute_output --partial "not applied"
}

@test "cmd_setup --show: reports 'not applied' when the in-box marker differs" {
  printf '[setup]\necho hi\n' > "$PROJECT/.cleat"
  _th_record_setup "$PROJECT" main >/dev/null
  mock_docker_ps "$CNAME"
  docker() {
    if [[ "$1" == "exec" ]]; then
      local a
      for a in "$@"; do
        [[ "$a" == "/home/coder/.cleat-setup-applied" ]] && { printf 'stale-marker'; return 0; }
      done
    fi
    command docker "$@"
  }
  run cmd_setup --show
  assert_success
  assert_output --partial "not applied"
}

@test "cmd_setup: <box> --show reads the box's .cleat.<box>" {
  printf '[setup]\necho from-main\n' > "$PROJECT/.cleat"
  printf '[setup]\necho from-dev-unique\n' > "$PROJECT/.cleat.dev"
  run cmd_setup dev --show
  assert_success
  assert_output --partial ".cleat.dev"
  assert_output --partial "echo from-dev-unique"
  refute_output --partial "from-main"
}

@test "cmd_setup: run mode on a stopped box requires the box to be running" {
  printf '[setup]\necho hi\n' > "$PROJECT/.cleat"
  run cmd_setup
  assert_failure
  assert_output --partial "is not running"
}

@test "cmd_setup: run mode on an untrusted [setup] refuses with 'not approved'" {
  printf '[setup]\necho hi\n' > "$PROJECT/.cleat"
  mock_docker_ps "$CNAME"
  _is_tty() { return 1; }
  run cmd_setup
  assert_failure
  assert_output --partial "not approved"
}

@test "cmd_setup: run mode on a trusted [setup] executes with force and exits 0" {
  printf '[setup]\necho hi\n' > "$PROJECT/.cleat"
  mock_docker_ps "$CNAME"
  export CLEAT_TRUST_SETUP=1
  _is_tty() { return 1; }
  run cmd_setup
  assert_success
  run assert_docker_exec_has "runuser -u coder -- bash -e /home/coder/.cleat-setup.run"
  assert_success
}

@test "cmd_setup: a failing payload propagates its real exit code" {
  printf '[setup]\nexit 7\n' > "$PROJECT/.cleat"
  mock_docker_ps "$CNAME"
  export CLEAT_TRUST_SETUP=1
  _is_tty() { return 1; }
  docker() {
    [[ "$1" == "exec" && "$*" == *"bash -e /home/coder/.cleat-setup.run"* ]] && return 7
    command docker "$@"
  }
  run cmd_setup
  assert_failure 7
}

# ── 9. Warner: _warn_unknown_cleat_sections ─────────────────────────────────

@test "warn_unknown_sections: an unknown [foo] section in .cleat warns by name; known sections stay silent" {
  printf '[caps]\ngit\n[resources]\nmemory = 4g\n[setup]\necho hi\n[foo]\nbar\n' > "$PROJECT/.cleat"
  export CLEAT_TRUST_PROJECT=1
  run resolve_caps "$PROJECT"
  assert_output --partial "Unknown section [foo]"
  refute_output --partial "Unknown section [caps]"
  refute_output --partial "Unknown section [resources]"
  refute_output --partial "Unknown section [setup]"
}

@test "warn_unknown_sections: [kits] in a project .cleat gets the global-only hint" {
  printf '[kits]\nworker = sonnet\n' > "$PROJECT/.cleat"
  export CLEAT_TRUST_PROJECT=1
  run resolve_caps "$PROJECT"
  assert_output --partial "Section [kits] in .cleat is ignored"
  assert_output --partial "global config only"
}

@test "warn_unknown_sections: [setup] in the global config gets the project-only hint" {
  printf '[setup]\necho hi\n' > "$CLEAT_GLOBAL_CONFIG"
  run resolve_caps "$PROJECT"
  assert_output --partial "Section [setup] in the global config is ignored"
  assert_output --partial "project-only"
}

@test "warn_unknown_sections: [kits] in the global config is silent" {
  printf '[kits]\nworker = sonnet\n' > "$CLEAT_GLOBAL_CONFIG"
  run resolve_caps "$PROJECT"
  refute_output --partial "Unknown section"
  refute_output --partial "is ignored"
}

@test "warn_unknown_sections: fires at most once per file per process" {
  printf '[foo]\nbar\n' > "$PROJECT/.cleat"
  export CLEAT_TRUST_PROJECT=1
  local out
  out="$(resolve_caps "$PROJECT" 2>&1; resolve_caps "$PROJECT" 2>&1)"
  local n
  n="$(printf '%s\n' "$out" | grep -c "Unknown section \[foo\]")"
  [[ "$n" == "1" ]] || { echo "expected 1 warning, got $n"; return 1; }
}

@test "warn_unknown_sections: a raw ESC byte in a section name is sanitized before rendering" {
  local esc
  esc="$(printf '\x1b')"
  printf '[%sfoo]\nbar\n' "$esc" > "$PROJECT/.cleat"
  export CLEAT_TRUST_PROJECT=1
  run resolve_caps "$PROJECT"
  # The warn() line legitimately carries OTHER raw ESC bytes (the CLI's own
  # AMBER/DIM/RESET color codes), so a blanket refute of any ESC byte would
  # false-fail; check the specific injected byte next to the section name.
  assert_output --partial "Unknown section [foo]"
  refute_output --partial "${esc}foo"
}

# ── 10. cmd_trust extension ──────────────────────────────────────────────────

@test "cmd_trust: caps + [setup] records a 4-col row and prints both approval lines" {
  printf '[caps]\ndocker\n\n[setup]\necho one\necho two\n' > "$PROJECT/.cleat"
  run cmd_trust
  assert_success
  assert_output --partial "Approved caps: docker"
  assert_output --partial "Approved setup: 2 command(s)"
  local cols
  cols="$(awk -F'\t' -v p="$PROJECT" '$1==p {print NF}' "$CLEAT_TRUST_FILE")"
  [[ "$cols" == "4" ]] || { echo "expected 4 columns, got $cols"; return 1; }
}

@test "cmd_trust: a setup-only file trusts with '-' in col3 and prints no caps line" {
  printf '[setup]\necho hi\n' > "$PROJECT/.cleat"
  run cmd_trust
  assert_success
  assert_output --partial "Approved setup: 1 command(s)"
  refute_output --partial "Approved caps:"
  # NOTE: not `assert_output "-"`: bats-assert treats a bare "-" as its
  # --stdin flag, not a literal expected value, so compare directly.
  local col3
  col3="$(_trust_lookup "$PROJECT" main)"
  [[ "$col3" == "-" ]] || { echo "got: $col3"; return 1; }
}

@test "cmd_trust: a caps-only file keeps the legacy 3-col row and prints no setup line" {
  printf '[caps]\ngit\n' > "$PROJECT/.cleat"
  run cmd_trust
  assert_success
  assert_output --partial "Approved caps: git"
  refute_output --partial "Approved setup:"
  local cols
  cols="$(awk -F'\t' -v p="$PROJECT" '$1==p {print NF}' "$CLEAT_TRUST_FILE")"
  [[ "$cols" == "3" ]] || { echo "expected 3 columns, got $cols"; return 1; }
}

@test "cmd_trust: an invalid [setup] warns 'not approved' but still records the caps" {
  printf '[caps]\ndocker\n\n[setup]\nscript /etc/hostname\n' > "$PROJECT/.cleat"
  run cmd_trust
  assert_success
  assert_output --partial "invalid, not approved"
  assert_output --partial "Approved caps: docker"
}

# ── 11. Sanitizer: _sanitize_repo_str ───────────────────────────────────────

@test "sanitize_repo_str: strips raw ESC, BEL, and DEL bytes" {
  local input esc bel del got
  esc="$(printf '\x1b')"; bel="$(printf '\x07')"; del="$(printf '\x7f')"
  input="a${esc}b${bel}c${del}d"
  got="$(_sanitize_repo_str "$input")"
  [[ "$got" == "abcd" ]] || { echo "got: $got"; return 1; }
}

@test "sanitize_repo_str: keeps tab characters" {
  local input tab got
  tab="$(printf '\t')"
  input="a${tab}b"
  got="$(_sanitize_repo_str "$input")"
  [[ "$got" == "a${tab}b" ]] || { echo "got: $got"; return 1; }
}

@test "sanitize_repo_str: doubles backslashes" {
  run _sanitize_repo_str 'a\b\c'
  assert_output 'a\\b\\c'
}

@test "sanitize_repo_str: leaves normal text untouched" {
  run _sanitize_repo_str "plain text, nothing special 123"
  assert_output "plain text, nothing special 123"
}

@test "print_caps: sanitizes an injected control sequence in the single-category caps line" {
  local cap esc
  esc="$(printf '\x1b')"
  cap="$(printf '\x1bBADESC\\033TAIL')"
  ACTIVE_CAPS=("$cap")
  run _print_caps "  " "Caps:" "      "
  # The rendered line legitimately contains OTHER raw ESC bytes (the CLI's
  # own color codes), so check the specific injected sequence, not any ESC.
  assert_output --partial "BADESC"
  refute_output --partial "${esc}BADESC"
  assert_output --partial "033"
}

@test "print_caps: sanitizes the mount row when caps split into mount and sandbox categories" {
  local cap esc
  esc="$(printf '\x1b')"
  cap="$(printf '\x1bBADESC\\033TAIL')"
  ACTIVE_CAPS=("docker" "$cap")
  run _print_caps "  " "Caps:" "      "
  assert_output --partial "mount:"
  assert_output --partial "sandbox:"
  assert_output --partial "BADESC"
  refute_output --partial "${esc}BADESC"
  assert_output --partial "033"
}

@test "cmd_status: sanitizes an injected control sequence in the caps display" {
  local cap esc
  esc="$(printf '\x1b')"
  cap="$(printf '\x1bBADESC\\033TAIL')"
  printf '[caps]\n%s\n' "$cap" > "$PROJECT/.cleat"
  local h
  h="$(_hash_cleat_caps "$PROJECT/.cleat")"
  _trust_record "$PROJECT" "$h" main
  run cmd_status "$PROJECT"
  assert_output --partial "BADESC"
  refute_output --partial "${esc}BADESC"
  assert_output --partial "033"
}

@test "cmd_trust: sanitizes an injected control sequence in the Approved caps line" {
  local cap esc
  esc="$(printf '\x1b')"
  cap="$(printf '\x1bBADESC\\033TAIL')"
  printf '[caps]\n%s\n' "$cap" > "$PROJECT/.cleat"
  run cmd_trust
  assert_success
  assert_output --partial "BADESC"
  refute_output --partial "${esc}BADESC"
  assert_output --partial "033"
}
