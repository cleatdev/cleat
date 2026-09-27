#!/usr/bin/env bats
# ── Egress interface: what the editor offers and what arrives ticked ─────────
#
# EGRESS-SPEC.md section 6. One predicate, _egress_pretick_class_ok, decides
# whether a class may arrive ticked: 1 for unaudited before anything else, 0
# only for contained, 2 for every other class. The two named exceptions,
# apt-debian and apt-image-extras, may override a 2 and never a 1.
load "../setup"
setup() {
  _common_setup
  # The stub, never the host's daemon: a session-marker read runs docker inspect.
  use_docker_stub
  source_cli
  PROJECT="$TEST_TEMP/proj"
  mkdir -p "$PROJECT"
  # A clean project, never the repo's own checkout: its git remote is evidence.
  cd "$PROJECT"
}
teardown() { _common_teardown; }

_trusted_setup_project() {
  printf '[setup]\necho hi\n' > "$PROJECT/.cleat"
  CLEAT_TRUST_SETUP=1 resolve_caps "$PROJECT" >/dev/null 2>&1
  unset CLEAT_TRUST_SETUP
}

@test "egress ui: a class C pack arrives unticked" {
  : > "$PROJECT/requirements.txt"
  run _egress_detect_packs "$PROJECT"
  assert_output "pypi suggested"
  run _egress_pretick_class_ok shared
  assert_equal "$status" 2
  run _egress_pretick_class_ok "open tenancy"
  assert_equal "$status" 2
  run _egress_pretick_class_ok contained
  assert_success
}

@test "egress ui: an unaudited pack is never pre ticked" {
  # A named exception whose class a maintainer cleared stays unticked: the
  # exception may override a 2 and never a 1.
  _trusted_setup_project
  eval "_real_catalogue() $(declare -f _egress_pack_catalogue | sed 1d)"
  _egress_pack_catalogue() {
    # awk, not sed: BSD sed reads \t in a pattern as a literal t.
    _real_catalogue | awk -F'\t' 'BEGIN { OFS = "\t" } $1 == "apt-debian" { $3 = "unaudited" } { print }'
  }
  run _egress_pack_class apt-debian
  assert_output "unaudited"
  run _egress_detect_packs "$PROJECT"
  assert_output --partial "apt-debian suggested"
  refute_output --partial "apt-debian ticked"
  run _egress_pretick_class_ok unaudited
  assert_equal "$status" 1
}

@test "egress ui: a named exception may override a shared class" {
  _trusted_setup_project
  run _egress_pack_class apt-debian
  assert_output "C"
  run _egress_detect_packs "$PROJECT"
  assert_output --partial "apt-debian ticked"
}

@test "egress ui: the default tick needs contained and a pack" {
  run _egress_default_tick contained github
  assert_success
  run _egress_default_tick contained ""
  assert_failure
  run _egress_default_tick shared github
  assert_failure
  run _egress_default_tick unaudited github
  assert_failure
}

# ── The editor (6.1, 6.4) ────────────────────────────────────────────────────

# A scripted key stream. The reader runs in a command substitution, so its
# position lives in a file. When the stream runs out it answers QUIT, so a
# test can never spin.
_keys() {
  printf '%s\n' "$@" > "$TEST_TEMP/keys"
  echo 0 > "$TEST_TEMP/kp"
  _read_keypress() {
    local n
    n="$(cat "$TEST_TEMP/kp")"
    echo $(( n + 1 )) > "$TEST_TEMP/kp"
    sed -n "$(( n + 1 ))p" "$TEST_TEMP/keys" | grep . || echo QUIT
  }
}
# A terminal of <n> rows. eval, because inside a nested definition $1 is the
# inner function's own argument, which is empty.
_rows_of() { eval "_term_rows() { echo $1; }"; _term_cols() { echo 110; }; }
_row_index() { _egress_editor_rows | grep -nxF -- "$1" | cut -d: -f1 | awk '{ print $1 - 1 }'; }
_downs() { local i; for ((i = 0; i < $1; i++)); do printf 'DOWN '; done; }

@test "egress measure: 26 packs on a 24 row terminal give a page of 2, not 26" {
  _rows_of 24
  _egress_measure 26
  run echo "$_EG_PAGE"
  assert_output "2"
}

@test "egress measure: 2 packs in a 50 row window give a page of 2, not 28" {
  _rows_of 50
  _egress_measure 2
  run echo "$_EG_PAGE"
  assert_output "2"
}

@test "egress measure: a 22 row terminal refuses the TUI and the text picker runs" {
  _rows_of 22
  run _egress_measure 26
  assert_failure
  mkdir -p "$CLEAT_CONFIG_DIR"
  _keys QUIT
  run _egress_editor "" <<< "q"
  assert_success
  assert_output --partial "(typed)"
}

@test "egress draw: a saturated page draws one line fewer than the terminal has rows" {
  _rows_of 24
  _egress_editor_load ""
  _egress_measure 26
  run bash -c 'wc -l' < <(_egress_draw 0)
  assert_output --regexp '^ *23$'
  _rows_of 40
  _egress_measure 26
  run bash -c 'wc -l' < <(_egress_draw 5)
  assert_output --regexp '^ *39$'
}

@test "egress ui: the editor cache agrees with the catalogue helpers for every pack" {
  # The cache is built in one pass for speed. It must say exactly what the
  # per-pack helpers say, or the editor draws a class the catalogue does not.
  # The reference helpers loop over the catalogue once per pack, which bats'
  # DEBUG trap makes ten times slower, so the trap is off for this test.
  trap - DEBUG
  _egress_editor_cache
  local p i n=0
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    i="$(_egress_cache_ix "$p")"
    assert_equal "${_EGC_HOSTS[i]}" "$(_egress_pack_hosts "$p")"
    assert_equal "${_EGC_CNT[i]}" "$(_egress_pack_hosts "$p" | grep -c . || true)"
    assert_equal "${_EGC_FLAGS[i]}" "$(_egress_pack_flags "$p")"
    assert_equal "${_EGC_WORD[i]}" "$(_egress_class_word "$(_egress_pack_class "$p")" "$(_egress_pack_flags "$p")")"
    n=$((n + 1))
  done < <(_egress_pack_ids)
  assert_equal "$n" "${#_EGC_P[@]}"
  assert_equal "$_EGC_IDS" "$(_egress_pack_ids)"
}

@test "egress draw: the detail pane is always _EGRESS_PANE_LINES lines" {
  _egress_editor_load ""
  local r
  for r in mode core pack:apt-debian pack:github host:docs.rs "$_EGRESS_ROW_ADD" "$_EGRESS_ROW_SAVE"; do
    run bash -c 'wc -l' < <(_egress_pane "$r")
    assert_output --regexp "^ *${_EGRESS_PANE_LINES}\$"
  done
}

@test "egress draw: a pane text longer than the pane is cut, never drawn past it" {
  _egress_pane_text() { local i; for i in 1 2 3 4 5 6 7 8 9; do echo "pane line $i"; done; }
  run bash -c 'wc -l' < <(_egress_pane mode)
  assert_output --regexp "^ *${_EGRESS_PANE_LINES}\$"
  run _egress_pane mode
  assert_output --partial "pane line ${_EGRESS_PANE_LINES}"
  refute_output --partial "pane line $((_EGRESS_PANE_LINES + 1))"
}

@test "egress ui: a label carrying a newline draws one physical row" {
  _rows_of 24
  _egress_editor_load ""
  _egress_measure 26
  _EGE_FILTER=$'a\nb'
  _EGE_BOX=$'x\ny'
  local lines
  lines="$(_egress_draw 0 | wc -l | tr -d ' ')"
  assert_equal "$lines" "$(( 10 + _EG_PAGE + 5 + 6 ))"
}

@test "egress picker: the add row is reachable by arrow keys alone" {
  mkdir -p "$CLEAT_CONFIG_DIR"
  _rows_of 30
  _egress_editor_load ""
  local add save
  add="$(_row_index "$_EGRESS_ROW_ADD")"
  _keys $(_downs "$add") ENTER $(_downs 5) ENTER
  run _egress_picker_tui "" <<< $'docs.rs\ny'
  assert_success
  run _read_section_all_from_file "$CLEAT_GLOBAL_CONFIG" egress allow
  assert_output "docs.rs"
}

@test "egress picker: the filter row shows the active filter" {
  _rows_of 30
  _egress_editor_load ""
  local f
  f="$(_row_index "$_EGRESS_ROW_FILTER")"
  _keys $(_downs "$f") ENTER QUIT
  run _egress_picker_tui "" <<< "apt"
  assert_output --partial "[/] filter               apt"
  assert_output --partial "showing 1-3 of 3"
}

@test "egress picker: an unknown key is ignored, not a cancel" {
  _rows_of 30
  _keys OTHER OTHER DOWN QUIT
  run _egress_picker_tui ""
  assert_success
  run grep -c "Nothing saved" <<< "$output"
  assert_output "1"
  run cat "$TEST_TEMP/kp"
  assert_output "4"
}

@test "egress picker: the save row is the only path that writes" {
  mkdir -p "$CLEAT_CONFIG_DIR"
  _rows_of 30
  _keys DOWN DOWN SPACE RIGHT QUIT
  run _egress_picker_tui ""
  assert_success
  [ ! -e "$CLEAT_GLOBAL_CONFIG" ] || { cat "$CLEAT_GLOBAL_CONFIG"; return 1; }
}

@test "egress picker: space ticks a pack and the save writes it" {
  mkdir -p "$CLEAT_CONFIG_DIR"
  _rows_of 30
  _egress_editor_load ""
  local gh save
  gh="$(_row_index pack:github)"
  save="$(_row_index "$_EGRESS_ROW_SAVE")"
  _keys $(_downs "$gh") SPACE $(_downs $(( save - gh ))) ENTER
  run _egress_picker_tui "" <<< "y"
  assert_success
  run _egress_section_canon "$CLEAT_GLOBAL_CONFIG"
  assert_output "mode = strict
pack = github"
}

@test "egress picker: a refused capability pack cannot be ticked" {
  _egress_editor_load ""
  _egress_toggle pack:containers
  run _egress_is_ticked containers
  assert_failure
}

@test "egress picker: left and right turn the mode ring, a box's ring starts at inherit" {
  _egress_editor_load ""
  _egress_mode_step 1
  run echo "$_EGE_MODE"
  assert_output "open"
  _egress_mode_step 1
  _egress_mode_step 1
  run echo "$_EGE_MODE"
  assert_output "strict"
  _egress_mode_step -1
  run echo "$_EGE_MODE"
  assert_output "off"
  _EGE_BOX=main
  _EGE_MODE=inherit
  _egress_mode_step 1
  run echo "$_EGE_MODE"
  assert_output "strict"
}

@test "egress picker: enter on a pack opens its action screen and tick ticks it" {
  _rows_of 30
  _egress_editor_load ""
  local go
  go="$(_row_index pack:go)"
  _keys $(_downs "$go") ENTER ENTER QUIT
  run _egress_picker_tui ""
  assert_output --partial "  > tick"
}

@test "egress picker: a host typed in the wrong shape is refused with the reason and no lost typing" {
  _egress_editor_load ""
  run _egress_add_prompt <<< $'*.acme.internal\nhttps://Docs.RS/\nhttp://deb.debian.org:80\nuser@git.acme.internal/repo\ndocs.rs'
  assert_success
  assert_output --partial "No wildcards"
  assert_output --partial "Did you mean:  docs.rs"
  assert_output --partial "Port 80 carries no ClientHello"
  assert_output --partial "No userinfo and no path"
  assert_output --partial "added just now"
}

# ── Pre-ticks in the editor (6.4) ────────────────────────────────────────────

@test "egress pretick: a setup section ticks apt-debian and names the exception" {
  _trusted_setup_project
  cd "$PROJECT"
  _egress_editor_load ""
  run _egress_is_ticked apt-debian
  assert_success
  run _egress_pack_note apt-debian
  assert_output "exception, audited 2026-09-21"
}

@test "egress pretick: an untrusted setup section suggests apt-debian and does not tick it" {
  printf '[setup]\necho hi\n' > "$PROJECT/.cleat"
  cd "$PROJECT"
  _egress_editor_load ""
  run _egress_is_ticked apt-debian
  assert_failure
  run _egress_pack_note apt-debian
  assert_output "suggested, not ticked"
}

@test "egress pretick: a git remote does not tick the githubusercontent object hosts" {
  mkdir -p "$PROJECT/.git"
  printf '[remote "origin"]\n\turl = https://github.com/acme/app\n' > "$PROJECT/.git/config"
  cd "$PROJECT"
  _egress_editor_load ""
  run _egress_is_ticked github
  assert_success
  run _egress_is_ticked github-objects
  assert_failure
}

@test "egress pretick: a policy that already carries a pack is never re-detected" {
  mkdir -p "$PROJECT/.git" "$CLEAT_CONFIG_DIR"
  printf '[remote "origin"]\n\turl = https://github.com/acme/app\n' > "$PROJECT/.git/config"
  printf '[egress]\nmode = strict\npack = npm\n' > "$CLEAT_GLOBAL_CONFIG"
  cd "$PROJECT"
  _egress_editor_load ""
  run _egress_is_ticked github
  assert_failure
}

# ── The save screen (6.4 Screen 5) ───────────────────────────────────────────

@test "egress save: the applies-now line matches the mode transition" {
  mkdir -p "$CLEAT_CONFIG_DIR"
  _EGRESS_ENFORCING=0
  _egress_editor_load ""
  run _egress_save_screen 1
  assert_success
  assert_output --partial "Saved. Enforcement lands in a later release. Nothing is filtered today."
}

@test "egress save: the diff names both setup exceptions with their audit date" {
  mkdir -p "$CLEAT_CONFIG_DIR"
  _trusted_setup_project
  cd "$PROJECT"
  _egress_editor_load ""
  run _egress_save_screen 1
  assert_output --partial "apt-debian is on a shared edge"
  assert_output --partial "apt-image-extras covers the two apt sources"
  assert_output --partial "measured $(_egress_catalogue_records | awk -F'\t' '$1 == "apt-debian" { sub(/^.*, /, "", $5); print $5 }')"
  assert_output --partial "Detected from files in this project, which the agent can edit."
}

@test "egress save: answering no writes nothing" {
  mkdir -p "$CLEAT_CONFIG_DIR"
  _egress_editor_load ""
  run _egress_save_screen 0 <<< "n"
  assert_failure
  [ ! -e "$CLEAT_GLOBAL_CONFIG" ] || { echo "a declined save wrote"; return 1; }
}

@test "egress save: a box editor writes the box's own file with no mode of its own" {
  mkdir -p "$CLEAT_CONFIG_DIR"
  printf '[egress]\nmode = strict\n' > "$CLEAT_GLOBAL_CONFIG"
  cd "$PROJECT"
  _set_box main
  _egress_editor_load main
  _EGE_HOSTS="extra.example"
  run _egress_save_screen 1
  assert_success
  run cat "$_EGE_FILE"
  assert_output "[egress]
allow = extra.example"
  run cat "$CLEAT_GLOBAL_CONFIG"
  assert_output "[egress]
mode = strict"
}

# ── The typed picker ────────────────────────────────────────────────────────

@test "egress typed picker: ticks, adds, sets the mode and saves on done" {
  mkdir -p "$CLEAT_CONFIG_DIR"
  run _egress_picker_text "" <<< $'npm\ndocs.rs\nmode off\nmode strict\ndone'
  assert_success
  run _egress_section_canon "$CLEAT_GLOBAL_CONFIG"
  assert_output "mode = strict
pack = npm
allow = docs.rs"
}

@test "egress ring: landing on open in the global editor does not write mode open" {
  mkdir -p "$CLEAT_CONFIG_DIR"
  run _egress_picker_text "" <<< $'mode open\ndone'
  assert_output --partial "Open is per box and per session"
  run _egress_section_canon "$CLEAT_GLOBAL_CONFIG"
  assert_output "mode = strict"
  # The drawn ring: open shows its two lines and a save keeps the mode before it.
  _egress_editor_load ""
  _egress_mode_step 1
  [ "$_EGE_MODE" = open ]
  run _egress_pane_text mode
  assert_output --partial "cleat egress open <box>"
  assert_output --partial "keeps mode strict"
  run _egress_save_screen 1
  assert_success
  run _egress_section_canon "$CLEAT_GLOBAL_CONFIG"
  assert_output "mode = strict"
}

@test "egress ring: landing on off does not write a policy on a default answer" {
  mkdir -p "$CLEAT_CONFIG_DIR"
  printf '[egress]\nmode = strict\npack = npm\n' > "$CLEAT_GLOBAL_CONFIG"
  _egress_editor_load ""
  _egress_mode_step -1
  [ "$_EGE_MODE" = off ]
  # Enter, even from the typed form's done, never turns it off.
  run _egress_save_screen 1 <<< ""
  assert_failure
  assert_output --partial "Turn it off? [y/N]"
  refute_output --partial "Allowed   9 hosts"
  refute_output --partial "port 443 only"
  run _egress_section_canon "$CLEAT_GLOBAL_CONFIG"
  assert_output "mode = strict
pack = npm"
  # And nothing claims Saved before the answer.
  run _egress_save_screen 1 <<< "n"
  refute_output --partial "Saved."
  run _egress_save_screen 1 <<< "y"
  assert_success
  run _egress_section_canon "$CLEAT_GLOBAL_CONFIG"
  assert_output "mode = off
pack = npm"
}

@test "egress typed picker: q and end of input save nothing" {
  mkdir -p "$CLEAT_CONFIG_DIR"
  run _egress_picker_text "" <<< $'npm\nq'
  assert_success
  [ ! -e "$CLEAT_GLOBAL_CONFIG" ] || return 1
  _EGE_FILE=""
  run _egress_picker_text "" <<< $'npm'
  assert_success
  [ ! -e "$CLEAT_GLOBAL_CONFIG" ] || return 1
}

@test "egress typed picker: a bad host is refused with its reason" {
  run _egress_picker_text "" <<< $'1.2.3.4\nq'
  assert_output --partial "An IP address is never allowed"
}

# ── The verbs (6.2) ──────────────────────────────────────────────────────────

@test "egress ui: an unknown flag is an error, not a box name" {
  run cmd_egress --frobnicate
  assert_failure
  assert_output --partial "Unknown flag"
}

@test "egress ui: an empty positional list does not trip set -u" {
  run bash -c 'set -euo pipefail; source "$1"; set -euo pipefail; cmd_egress status < /dev/null' _ "$CLI"
  assert_success
}

@test "egress allow: with no policy it writes mode strict with the entries" {
  mkdir -p "$CLEAT_CONFIG_DIR"
  run cmd_egress allow npm docs.rs
  assert_success
  assert_output --partial "the policy was off"
  run _egress_section_canon "$CLEAT_GLOBAL_CONFIG"
  assert_output "mode = strict
pack = npm
allow = docs.rs"
}

@test "egress deny: with no policy it writes nothing and exits 1" {
  run cmd_egress deny docs.rs
  assert_failure
  assert_output --partial "nothing to deny"
  [ ! -e "$CLEAT_GLOBAL_CONFIG" ] || return 1
}

@test "egress allow: an invalid argument writes nothing at all" {
  mkdir -p "$CLEAT_CONFIG_DIR"
  run cmd_egress allow npm 'not a host'
  assert_failure
  [ ! -e "$CLEAT_GLOBAL_CONFIG" ] || return 1
}

@test "egress allow and deny take each other's names off the list" {
  mkdir -p "$CLEAT_CONFIG_DIR"
  cmd_egress allow a.example >/dev/null
  cmd_egress deny a.example >/dev/null
  run _egress_section_canon "$CLEAT_GLOBAL_CONFIG"
  assert_output "mode = strict
deny = a.example"
  cmd_egress allow a.example >/dev/null
  run _egress_section_canon "$CLEAT_GLOBAL_CONFIG"
  assert_output "mode = strict
allow = a.example"
}

@test "egress deny: a pack the file never listed denies its hosts, and the core refuses" {
  mkdir -p "$CLEAT_CONFIG_DIR"
  printf '[egress]\nmode = strict\n' > "$CLEAT_GLOBAL_CONFIG"
  run cmd_egress deny npm
  assert_success
  run _read_section_all_from_file "$CLEAT_GLOBAL_CONFIG" egress deny
  assert_output "registry.npmjs.org"
  run cmd_egress deny claude
  assert_failure
  run cmd_egress deny api.anthropic.com
  assert_failure
}

@test "egress ui: --inherit removes the per-box file and its pin and nothing else" {
  mkdir -p "$CLEAT_CONFIG_DIR/egress-boxes" "$CLEAT_CONFIG_DIR/egress-pins"
  printf '[egress]\nmode = strict\n' > "$CLEAT_GLOBAL_CONFIG"
  cd "$PROJECT"
  local cname
  cname="$(container_name_for "$PROJECT" main)"
  printf '[egress]\nallow = extra.example\n' > "$CLEAT_CONFIG_DIR/egress-boxes/$cname"
  printf '[pin]\n' > "$CLEAT_CONFIG_DIR/egress-pins/$cname"
  printf '[pin]\n' > "$CLEAT_CONFIG_DIR/egress-pins/global"
  run cmd_egress main --inherit < /dev/null
  assert_success
  [ ! -e "$CLEAT_CONFIG_DIR/egress-boxes/$cname" ] || { echo "file kept"; return 1; }
  [ ! -e "$CLEAT_CONFIG_DIR/egress-pins/$cname" ] || { echo "pin kept"; return 1; }
  [ -e "$CLEAT_CONFIG_DIR/egress-pins/global" ] || { echo "global pin removed"; return 1; }
  run cat "$CLEAT_GLOBAL_CONFIG"
  assert_output "[egress]
mode = strict"
}

@test "egress ui: --inherit on a pipe refuses when removing the file widens the box" {
  mkdir -p "$CLEAT_CONFIG_DIR/egress-boxes"
  printf '[egress]\nmode = open\n' > "$CLEAT_GLOBAL_CONFIG"
  cd "$PROJECT"
  local cname
  cname="$(container_name_for "$PROJECT" main)"
  printf '[egress]\nmode = strict\n' > "$CLEAT_CONFIG_DIR/egress-boxes/$cname"
  run cmd_egress main --inherit < /dev/null
  assert_failure
  assert_output --partial "would widen"
  [ -e "$CLEAT_CONFIG_DIR/egress-boxes/$cname" ] || return 1
  run cmd_egress main --inherit --yes < /dev/null
  assert_success
  [ ! -e "$CLEAT_CONFIG_DIR/egress-boxes/$cname" ] || return 1
}

@test "egress ui: --inherit on a pipe refuses when a per-box deny kept a host out" {
  mkdir -p "$CLEAT_CONFIG_DIR/egress-boxes"
  printf '[egress]\nmode = strict\npack = npm\n' > "$CLEAT_GLOBAL_CONFIG"
  cd "$PROJECT"
  local cname
  cname="$(container_name_for "$PROJECT" main)"
  printf '[egress]\ndeny = registry.npmjs.org\n' > "$CLEAT_CONFIG_DIR/egress-boxes/$cname"
  run cmd_egress main --inherit < /dev/null
  assert_failure
}

@test "egress ui: --inherit on a pipe runs when removing the file narrows the box" {
  mkdir -p "$CLEAT_CONFIG_DIR/egress-boxes"
  printf '[egress]\nmode = strict\n' > "$CLEAT_GLOBAL_CONFIG"
  cd "$PROJECT"
  local cname
  cname="$(container_name_for "$PROJECT" main)"
  printf '[egress]\nallow = extra.example\n' > "$CLEAT_CONFIG_DIR/egress-boxes/$cname"
  run cmd_egress main --inherit < /dev/null
  assert_success
}

@test "egress status: the browser residual row prints the session cap and the origin count" {
  mkdir -p "$CLEAT_CONFIG_DIR"
  printf '[egress]\nmode = strict\n' > "$CLEAT_GLOBAL_CONFIG"
  unset CLEAT_BROWSER_ORIGINS CLEAT_BROWSER_BRIDGE
  run cmd_egress status
  assert_output --partial "<= 30 per session, <= 2048 bytes, 19 listed origins"
  CLEAT_BROWSER_BRIDGE=always run cmd_egress status
  assert_output --partial "<= 30 per session, <= 8192 bytes"
}

@test "egress status: the browser residual row points at cleat browser origins" {
  mkdir -p "$CLEAT_CONFIG_DIR"
  printf '[egress]\nmode = strict\n' > "$CLEAT_GLOBAL_CONFIG"
  run cmd_egress status
  assert_output --partial "cleat browser origins"
}

@test "egress status: the auth mount is named as a channel no policy reaches" {
  mkdir -p "$CLEAT_CONFIG_DIR"
  printf '[egress]\nmode = strict\n' > "$CLEAT_GLOBAL_CONFIG"
  run cmd_egress status
  assert_output --partial "/home/coder/.cleat-auth"
  assert_output --partial "refresh token"
}

@test "egress status: a saved policy says it is not enforced, in two lines" {
  mkdir -p "$CLEAT_CONFIG_DIR"
  _EGRESS_ENFORCING=0
  printf '[egress]\nmode = strict\npack = pypi\n' > "$CLEAT_GLOBAL_CONFIG"
  run cmd_egress status
  assert_output --partial "Policy saved. Enforcement lands in a later release."
  assert_output --partial "not yet been validated against a real Claude Code session"
  assert_output --partial "pypi.org (shared)"
}

@test "egress list: a box's list says which file set the mode" {
  mkdir -p "$CLEAT_CONFIG_DIR/egress-boxes"
  printf '[egress]\nmode = strict\n' > "$CLEAT_GLOBAL_CONFIG"
  cd "$PROJECT"
  printf '[egress]\nmode = open\n' > "$CLEAT_CONFIG_DIR/egress-boxes/$(container_name_for "$PROJECT" main)"
  run cmd_egress main --list
  assert_output --partial "Egress for box main"
  assert_output --partial "Mode:     open"
  assert_output --partial "own file"
}

# ── The second door: the Egress row in cleat config (6.8) ────────────────────

_ncaps() { echo "${#KNOWN_CAPS[@]}"; }

@test "egress ui: the config editor offers an egress row in global scope" {
  mkdir -p "$CLEAT_CONFIG_DIR"
  _box_scope=""
  _keys QUIT
  run _config_picker_tui "$CLEAT_GLOBAL_CONFIG" global ""
  assert_output --partial "capabilities + resources + egress"
  assert_output --partial "Egress"
  assert_output --partial "off      new boxes reach your whole network"
}

@test "egress ui: the config editor never offers egress in project scope" {
  printf '[caps]\ngit\n' > "$PROJECT/.cleat"
  local b
  for b in "" review; do
    _box_scope="$b"
    _keys QUIT
    run _config_picker_tui "$PROJECT/.cleat" project "$PROJECT"
    refute_output --partial "Egress"
    refute_output --partial "+ egress"
  done
}

@test "egress ui: a project cleat carrying an egress section prints the ignored note" {
  printf '[egress]\nmode = open\n' > "$PROJECT/.cleat"
  _box_scope=""
  _keys QUIT
  run _config_picker_tui "$PROJECT/.cleat" project "$PROJECT"
  assert_output --partial "This file's [egress] section is ignored. Egress policy is global: cleat egress"
  run _config_picker_text "$PROJECT/.cleat" project "$PROJECT" <<< "q"
  assert_output --partial "This file's [egress] section is ignored"
  printf '[caps]\ngit\n' > "$PROJECT/.cleat"
  run _config_picker_text "$PROJECT/.cleat" project "$PROJECT" <<< "q"
  refute_output --partial "is ignored"
}

@test "egress ui: turning egress on from the config editor writes mode strict and no other key" {
  mkdir -p "$CLEAT_CONFIG_DIR"
  printf '[caps]\ngit\n' > "$CLEAT_GLOBAL_CONFIG"
  _box_scope=""
  _keys $(_downs $(( $(_ncaps) + 2 ))) SPACE ENTER
  run _config_picker_tui "$CLEAT_GLOBAL_CONFIG" global ""
  assert_success
  assert_output --partial "Egress control is on, with the Claude Code hosts and nothing else."
  run _egress_section_canon "$CLEAT_GLOBAL_CONFIG"
  assert_output "mode = strict"
  run _read_caps_from_file "$CLEAT_GLOBAL_CONFIG"
  assert_output "git"
}

@test "egress ui: turning egress on from the config editor hands off to the egress flow" {
  mkdir -p "$CLEAT_CONFIG_DIR"
  _box_scope=""
  _egress_have_tty() { return 0; }
  _egress_picker_tui() { echo "EDITOR box=[$1] mode=[$2]"; _EGE_SAVED=1; }
  _keys $(_downs $(( $(_ncaps) + 2 ))) SPACE ENTER
  run _config_picker_tui "$CLEAT_GLOBAL_CONFIG" global ""
  assert_output --partial "EDITOR box=[] mode=[]"
  refute_output --partial "[y/N]"
  refute_output --partial "Cancelled. Egress control is on"
}

@test "egress ui: cancelling the editor after the handoff leaves the core pack policy in place" {
  mkdir -p "$CLEAT_CONFIG_DIR"
  _box_scope=""
  _egress_have_tty() { return 0; }
  _egress_picker_tui() { _EGE_SAVED=0; }
  _keys $(_downs $(( $(_ncaps) + 2 ))) SPACE ENTER
  run _config_picker_tui "$CLEAT_GLOBAL_CONFIG" global ""
  assert_output --partial "Cancelled. Egress control is on with the Claude Code hosts only."
  run _egress_section_canon "$CLEAT_GLOBAL_CONFIG"
  assert_output "mode = strict"
}

@test "egress ui: clearing the config egress row opens the editor with the mode ring on off" {
  mkdir -p "$CLEAT_CONFIG_DIR"
  printf '[egress]\nmode = strict\npack = npm\n' > "$CLEAT_GLOBAL_CONFIG"
  _box_scope=""
  _egress_have_tty() { return 0; }
  _egress_picker_tui() { echo "EDITOR box=[$1] mode=[$2]"; }
  _keys $(_downs $(( $(_ncaps) + 2 ))) SPACE ENTER
  run _config_picker_tui "$CLEAT_GLOBAL_CONFIG" global ""
  assert_output --partial "Turning egress control off. Confirm on the next screen."
  assert_output --partial "EDITOR box=[] mode=[off]"
  # Off writes nothing itself.
  run _egress_section_canon "$CLEAT_GLOBAL_CONFIG"
  assert_output "mode = strict
pack = npm"
}

@test "egress ui: an untouched config egress row hands off nothing" {
  mkdir -p "$CLEAT_CONFIG_DIR"
  printf '[egress]\nmode = strict\n' > "$CLEAT_GLOBAL_CONFIG"
  _box_scope=""
  _keys ENTER
  run _config_picker_tui "$CLEAT_GLOBAL_CONFIG" global ""
  refute_output --partial "Egress control is on"
  refute_output --partial "Turning egress control off"
}

@test "egress ui: an egress section that does not resolve cannot be flipped from the config row" {
  mkdir -p "$CLEAT_CONFIG_DIR"
  printf '[egress]\nallow = a.example\n' > "$CLEAT_GLOBAL_CONFIG"
  _box_scope=""
  run _egress_config_row_state
  assert_output --partial "x|invalid"
  _keys $(_downs $(( $(_ncaps) + 2 ))) SPACE ENTER
  run _config_picker_tui "$CLEAT_GLOBAL_CONFIG" global ""
  refute_output --partial "Egress control is on"
  run cat "$CLEAT_GLOBAL_CONFIG"
  assert_output "[egress]
allow = a.example"
}

@test "egress ui: the config text picker prints the egress state and writes nothing" {
  mkdir -p "$CLEAT_CONFIG_DIR"
  _box_scope=""
  run _config_picker_text "$CLEAT_GLOBAL_CONFIG" global "" <<< $'egress\nq'
  assert_success
  run grep -c "Egress: off (new boxes reach your whole network).  Turn it on with: cleat egress" <<< "$output"
  assert_output "2"
  [ ! -e "$CLEAT_GLOBAL_CONFIG" ] || { cat "$CLEAT_GLOBAL_CONFIG"; return 1; }
}

@test "egress ui: the config egress row renders the resolved counts" {
  mkdir -p "$CLEAT_CONFIG_DIR"
  printf '[egress]\nmode = strict\npack = npm\npack = github\nallow = docs.rs\n' > "$CLEAT_GLOBAL_CONFIG"
  run _egress_config_row_state
  assert_output "1|strict   11 hosts, 3 packs.  cleat egress edits the list"
  printf '[egress]\nmode = open\n' > "$CLEAT_GLOBAL_CONFIG"
  run _egress_config_row_state
  assert_output "1|open     every TLS host allowed and every one logged"
}

@test "egress ui: the config global block grows by exactly two physical lines" {
  local without with
  without="$(_config_picker_draw 0 "" default all 0 0 "" 0 "" | wc -l | tr -d ' ')"
  with="$(_config_picker_draw 0 "" default all 0 0 "" 1 "0|off" | wc -l | tr -d ' ')"
  assert_equal "$(( with - without ))" "2"
  # And the TUI budgets exactly what the draw adds, or its blind cursor-up
  # overshoots by the difference on every redraw.
  assert_equal "$_EGRESS_CONFIG_ROW_LINES" "$(( with - without ))"
}

@test "egress ui: the generate row carries the cursor below the egress row" {
  local n
  n="$(_ncaps)"
  run _config_picker_draw $(( n + 3 )) "" default all 1 0 "" 1 "0|off"
  run grep -c '▸' <<< "$output"
  assert_output "1"
  run _config_picker_draw $(( n + 3 )) "" default all 1 0 "" 1 "0|off"
  run grep '▸' <<< "$output"
  assert_output --partial "Also write these to this project's .cleat"
  run _config_row_kind $(( n + 2 )) 1
  assert_output "egress"
  run _config_row_kind $(( n + 3 )) 1
  assert_output "gen"
  run _config_row_kind $(( n + 2 ))
  assert_output "gen"
}

@test "egress: two box names are too many arguments" {
  run cmd_egress one two
  assert_failure
  assert_output --partial "Too many arguments"
  run cmd_egress status one two
  assert_failure
  assert_output --partial "Too many arguments"
}

# ── The widening ledger (5.2) and its summary sub-line (6.7) ────────────────

_plain() { printf '%s' "$1" | sed $'s/\033\\[[0-9;]*m//g'; }

@test "egress ui: a first launch with no recorded digest prints no widening sub-line" {
  local cn
  cn="$(container_name_for "$PROJECT" main)"
  printf '[egress]\nmode = strict\nallow = docs.rs\n' > "$CLEAT_GLOBAL_CONFIG"
  run _egress_summary_row "$cn"
  assert_success
  refute_output --partial "since the last launch"
  run grep -c '^host ' "$(_egress_ledger_path "$cn")"
  refute_output "0"
}

@test "egress ui: a policy that widened since the last launch is named in the summary" {
  local cn
  cn="$(container_name_for "$PROJECT" main)"
  printf '[egress]\nmode = strict\n' > "$CLEAT_GLOBAL_CONFIG"
  _egress_summary_row "$cn" >/dev/null
  printf '[egress]\nmode = strict\nallow = docs.rs\nallow = crates.io\n' > "$CLEAT_GLOBAL_CONFIG"
  # Status names the hosts the summary only counts, and reading it spends nothing.
  run cmd_egress status main
  assert_success
  run _plain "$output"
  assert_output --partial "Added since this box last launched: crates.io, docs.rs"
  run _egress_summary_row "$cn"
  run _plain "$output"
  assert_output --partial "2 hosts added since the last launch.  cleat egress status"
  # The launch that showed it recorded it, so the next one is quiet.
  run _egress_summary_row "$cn"
  refute_output --partial "since the last launch"
}

@test "egress ui: a move to open since the last launch is named in the summary" {
  local cn
  cn="$(container_name_for "$PROJECT" main)"
  printf '[egress]\nmode = strict\n' > "$CLEAT_GLOBAL_CONFIG"
  _egress_summary_row "$cn" >/dev/null
  printf '[egress]\nmode = open\n' > "$CLEAT_GLOBAL_CONFIG"
  run _egress_summary_row "$cn"
  run _plain "$output"
  assert_output --partial "mode widened to open since the last launch."
  refute_output --partial "added since"
  run _egress_summary_row "$cn"
  refute_output --partial "since the last launch"
}

@test "egress ui: a narrowing since the last launch is silent" {
  local cn
  cn="$(container_name_for "$PROJECT" main)"
  printf '[egress]\nmode = open\nallow = docs.rs\n' > "$CLEAT_GLOBAL_CONFIG"
  _egress_summary_row "$cn" >/dev/null
  printf '[egress]\nmode = strict\nallow = docs.rs\n' > "$CLEAT_GLOBAL_CONFIG"
  run _egress_summary_row "$cn"
  refute_output --partial "since the last launch"
  printf '[egress]\nmode = strict\n' > "$CLEAT_GLOBAL_CONFIG"
  run _egress_summary_row "$cn"
  refute_output --partial "since the last launch"
  run cmd_egress status main
  refute_output --partial "Added since"
}

@test "egress ui: the ledger is never written through a link" {
  local cn d
  cn="$(container_name_for "$PROJECT" main)"
  d="$(dirname "$(_egress_ledger_path "$cn")")"
  mkdir -p "$(dirname "$d")" "$TEST_TEMP/elsewhere"
  ln -s "$TEST_TEMP/elsewhere" "$d"
  printf '[egress]\nmode = strict\n' > "$CLEAT_GLOBAL_CONFIG"
  run _egress_summary_row "$cn"
  assert_success
  run ls -A "$TEST_TEMP/elsewhere"
  assert_output ""
  rm -f "$d"
  mkdir -p "$d"
  ln -s "$TEST_TEMP/elsewhere/target" "$d/resolved-digest"
  : > "$TEST_TEMP/elsewhere/target"
  _egress_ledger_read "$cn"
  [ "$_EGL_SET" = 0 ]
}

@test "egress ui: with no policy the summary reads off and records nothing" {
  local cn
  cn="$(container_name_for "$PROJECT" main)"
  run _egress_summary_row "$cn"
  run _plain "$output"
  assert_output "  Egress:     off  ·  full network egress"
  [ ! -e "$(_egress_ledger_path "$cn")" ]
}

# ── cleat egress audit (7.1, 4.4a) ──────────────────────────────────────────

# A fetch seam answering by the Host header sent. OWN is the host's page,
# REF the probe origin's. FOREIGN_ANSWER is what the host returns for the
# foreign Host header. H2 is the version the h2 leg negotiates, or "fail".
_audit_stub() {
  OWN="${OWN:-200|1.1|93.184.215.14|nginx|1256|aaaaaaaaaaaa|Example Docs}"
  REF="${REF:-200|1.1|151.101.0.193|Varnish|5120|bbbbbbbbbbbb|Imgur: The magic of the Internet}"
  REFUSAL="421|1.1|93.184.215.14|nginx|0|d41d8cd98f00|"
  FOREIGN_ANSWER="${FOREIGN_ANSWER:-$REFUSAL}"
  H2="${H2:-2}"
  _egress_audit_have_curl() { return 0; }
  export AUDIT_LOG="$TEST_TEMP/audit.calls"
  : > "$AUDIT_LOG"
  _egress_audit_fetch() {
    echo "$1 $2 $3" >> "$AUDIT_LOG"
    local v=1.1
    if [ "$3" = h2 ]; then
      [ "$H2" = fail ] && return 1
      v="$H2"
    fi
    if [ "$1" = imgur.com ]; then printf '%s\n' "$REF"; return 0; fi
    [ -n "${OWN_FAILS:-}" ] && return 1
    case "$2" in
      imgur.com) printf '%s\n' "$FOREIGN_ANSWER" | awk -F'|' -v v="$v" 'BEGIN{OFS="|"} {$2=v; print}' ;;
      nonexistent.invalid) printf '%s\n' "$REFUSAL" ;;
      *) printf '%s\n' "$OWN" | awk -F'|' -v v="$v" 'BEGIN{OFS="|"} {$2=v; print}' ;;
    esac
  }
  _egress_audit_cert() { printf 'AB:CD:EF\ndocs.example.test\n*.example.test\nwww.example.test\n'; }
}

_seed_denial() {                         # <host>
  mkdir -p "$CLEAT_RUN_DIR/cleat-seed-1234/egress"
  printf '2026-09-26T00:00:00.000Z code=policy sub=- origin=box host=%s port=443 trunc=0\n' "$1" \
    > "$CLEAT_RUN_DIR/cleat-seed-1234/egress/denials.log"
}

@test "egress audit: the denial match is case and trailing dot blind and reads no link" {
  _seed_denial Exfil.Attacker.Example.
  run _egress_denial_origin exfil.attacker.example
  assert_output "box"
  run _egress_denial_origin other.example
  assert_output ""
  rm -f "$CLEAT_RUN_DIR/cleat-seed-1234/egress/denials.log"
  printf 'x host=exfil.attacker.example\n' > "$TEST_TEMP/elsewhere.log"
  ln -s "$TEST_TEMP/elsewhere.log" "$CLEAT_RUN_DIR/cleat-seed-1234/egress/denials.log"
  run _egress_denial_origin exfil.attacker.example
  assert_output ""
  run _egress_origin_gate exfil.attacker.example
  assert_success
}

@test "egress audit: a host that refuses a foreign Host header is contained" {
  _audit_stub
  run cmd_egress audit docs.example.test < /dev/null
  output="$(_plain "$output")"
  assert_success
  assert_output --partial "Verdict:  contained"
  assert_output --partial "h1+h2"
  assert_output --partial "Printed, not saved"
  [ "$(grep -c 'docs.example.test imgur.com' "$AUDIT_LOG")" = 2 ]
  [ "$(grep -c 'docs.example.test www.example.test' "$AUDIT_LOG")" = 2 ]
  [ "$(grep -c 'docs.example.test nonexistent.invalid' "$AUDIT_LOG")" = 2 ]
}

@test "egress audit: a foreign origin's page on either protocol is shared" {
  _audit_stub
  FOREIGN_ANSWER="404|1.1|93.184.215.14|Varnish|5120|bbbbbbbbbbbb|Imgur: The magic of the Internet"
  run cmd_egress audit docs.example.test < /dev/null
  output="$(_plain "$output")"
  assert_success
  assert_output --partial "shared"
  assert_output --partial "another origin's page"
  refute_output --partial "Verdict:  contained"
}

@test "egress audit: the foreign title alone is enough, the status never is" {
  _audit_stub
  FOREIGN_ANSWER="500|1.1|93.184.215.14|x|77|cccccccccccc|Imgur: The magic of the Internet"
  run cmd_egress audit docs.example.test < /dev/null
  output="$(_plain "$output")"
  assert_output --partial "shared"
  run _egress_audit_same_page "301|1.1|a|s|0|d41d8cd98f00|" "302|1.1|b|t|0|d41d8cd98f00|"
  assert_failure
  run _egress_audit_same_page "200|1.1|a|s|10|abc|" "200|1.1|b|t|10|abc|"
  assert_success
}

@test "egress audit: a stranger's page for a foreign Host needs a person" {
  _audit_stub
  FOREIGN_ANSWER="200|1.1|93.184.215.14|nginx|900|dddddddddddd|Welcome to someone else"
  run cmd_egress audit docs.example.test < /dev/null
  output="$(_plain "$output")"
  assert_success
  assert_output --partial "Verdict:  unaudited"
  assert_output --partial "needs a person"
}

@test "egress audit: an edge with no HTTP/2 is audited on h1 alone and says so" {
  _audit_stub
  H2=1.1
  run cmd_egress audit docs.example.test < /dev/null
  output="$(_plain "$output")"
  assert_output --partial "Verdict:  contained"
  assert_output --partial "h1 only, no h2 offered"
  [ "$(grep -c 'docs.example.test imgur.com' "$AUDIT_LOG")" = 1 ]
}

@test "egress audit: a failed HTTP/2 request is never contained" {
  _audit_stub
  H2=fail
  run cmd_egress audit docs.example.test < /dev/null
  output="$(_plain "$output")"
  assert_output --partial "Verdict:  unaudited"
  assert_output --partial "HTTP/2 request failed"
}

@test "egress audit: with no probe origin nothing can be called contained" {
  _audit_stub
  REF=" "
  _egress_audit_fetch_real="$(declare -f _egress_audit_fetch)"
  eval "_egress_stub_inner() ${_egress_audit_fetch_real#*\(\)}"
  _egress_audit_fetch() { [ "$1" = imgur.com ] && return 1; _egress_stub_inner "$@"; }
  run cmd_egress audit docs.example.test < /dev/null
  output="$(_plain "$output")"
  assert_output --partial "Verdict:  unaudited"
  assert_output --partial "did not answer"
}

@test "egress audit: an unreachable host exits 1" {
  _audit_stub
  OWN_FAILS=1
  run cmd_egress audit docs.example.test < /dev/null
  output="$(_plain "$output")"
  assert_failure
  assert_output --partial "Could not reach docs.example.test"
}

@test "egress audit: a name that is not a host refuses before any dial" {
  _audit_stub
  local bad
  for bad in "https://docs.rs/" "10.0.0.1" "*.example.com" "docs.rs:443" ""; do
    run cmd_egress audit "$bad" < /dev/null
    assert_failure
  done
  run cat "$AUDIT_LOG"
  assert_output ""
  run cmd_egress audit one.example two.example < /dev/null
  output="$(_plain "$output")"
  assert_failure
  assert_output --partial "one host at a time"
}

@test "egress audit: an address the gateway refuses is named" {
  _audit_stub
  OWN="200|1.1|192.168.1.20|nginx|1256|aaaaaaaaaaaa|Example Docs"
  run cmd_egress audit docs.example.test < /dev/null
  output="$(_plain "$output")"
  assert_output --partial "private or special: the gateway refuses to dial it"
  OWN="200|1.1|2606:4700::6810:85e5|cloudflare|1256|aaaaaaaaaaaa|Example Docs"
  run cmd_egress audit docs.example.test < /dev/null
  output="$(_plain "$output")"
  assert_output --partial "IPv6: the gateway dials IPv4 only"
  local a
  # Every range the gateway refuses, at both edges, plus what it does not dial
  # at all: IPv6, and anything that is not four plain decimal octets.
  for a in 0.0.0.0 0.255.255.255 10.0.0.0 10.255.255.255 100.64.0.0 100.127.255.255 \
           127.0.0.1 169.254.169.254 172.16.0.0 172.31.255.255 192.0.0.1 192.0.2.10 \
           192.88.99.1 192.168.0.1 198.18.0.0 198.19.255.255 198.51.100.7 203.0.113.9 \
           224.0.0.1 239.255.255.255 240.0.0.1 255.255.255.255 ::ffff:10.0.0.1 ::FFFF:198.18.0.1 \
           ::1 fd00::1 2606:4700::1111 010.0.0.1 1.2.3 1.2.3.4.5 256.1.1.1 bogus ""; do
    run _egress_address_special "$a"
    assert_success
  done
  for a in 93.184.215.14 9.255.255.255 11.0.0.0 100.63.255.255 100.128.0.0 172.15.255.255 \
           172.32.0.0 192.0.1.255 192.0.3.0 192.88.98.255 192.169.0.0 198.17.255.255 198.20.0.0 \
           198.51.99.255 203.0.112.255 223.255.255.255 ::ffff:93.184.215.14 1.1.1.1; do
    run _egress_address_special "$a"
    assert_failure
  done
}

@test "egress audit: the neighbour is a certificate name that is neither the host nor a wildcard" {
  run _egress_audit_neighbour docs.example.test $'docs.example.test\n*.example.test\nwww.example.test'
  assert_output "www.example.test"
  run _egress_audit_neighbour docs.example.test $'docs.example.test\n*.example.test'
  assert_output ""
}

@test "egress audit: nothing is written to the policy" {
  _audit_stub
  printf '[egress]\nmode = strict\n' > "$CLEAT_GLOBAL_CONFIG"
  local before
  before="$(cat "$CLEAT_GLOBAL_CONFIG")"
  run cmd_egress audit docs.example.test < /dev/null
  output="$(_plain "$output")"
  assert_success
  [ "$(cat "$CLEAT_GLOBAL_CONFIG")" = "$before" ]
  [ ! -e "$_EGRESS_PINS_DIR/global" ] || false
}

@test "egress audit: certificate names are cut to host name characters before use" {
  mkdir -p "$TEST_TEMP/sslbin"
  cat > "$TEST_TEMP/sslbin/openssl" <<'SH'
#!/usr/bin/env bash
case "$1" in
  s_client) printf -- '-----BEGIN CERTIFICATE-----\nAAAA\n-----END CERTIFICATE-----\n' ;;
  x509)
    case " $* " in
      *" -fingerprint "*) printf 'sha256 Fingerprint=AB:CD\033[31m:EF\n' ;;
      *) printf 'DNS:good.example.test, DNS:bad\033]0;owned\007.example.test, DNS:*.example.test\n' ;;
    esac ;;
esac
SH
  chmod +x "$TEST_TEMP/sslbin/openssl"
  PATH="$TEST_TEMP/sslbin:$PATH" run _egress_audit_cert docs.example.test
  assert_success
  assert_output "AB:CD31:EF
good.example.test
*.example.test"
}

@test "egress audit: a machine with no curl is told so and nothing is dialled" {
  _audit_stub
  _egress_audit_have_curl() { return 1; }
  run cmd_egress audit docs.example.test < /dev/null
  assert_failure
  assert_output --partial "needs curl"
  run cat "$AUDIT_LOG"
  assert_output ""
}

@test "egress audit: a catalogue host prints the published class beside the verdict" {
  _audit_stub
  run cmd_egress audit github.com < /dev/null
  output="$(_plain "$output")"
  assert_output --partial "The catalogue lists it as contained."
  run cmd_egress audit docs.example.test < /dev/null
  output="$(_plain "$output")"
  refute_output --partial "The catalogue lists it"
}

@test "egress draw: no drawn line is wider than the terminal, so the redraw never drifts" {
  local c longest
  _EGE_BOX=""
  for c in 80 60; do
    _rows_of 60
    eval "_term_cols() { echo $c; }"
    _egress_editor_load ""
    _egress_measure 26
    longest="$(_egress_draw 1 | sed $'s/\033\\[[0-9;]*[A-Za-z]//g' | awk '{ if (length($0) > m) m = length($0) } END { print m + 0 }')"
    [ "$longest" -lt "$c" ]
    # Every pack's detail pane too, the containers pane among them.
    local r
    for r in pack:containers pack:docs pack:huggingface pack:atlassian core mode; do
      longest="$(_egress_pane "$r" | sed $'s/\033\\[[0-9;]*[A-Za-z]//g' | awk '{ if (length($0) > m) m = length($0) } END { print m + 0 }')"
      [ "$longest" -lt "$c" ]
    done
  done
  # A box editor with a long box name stays inside the width too.
  eval "_term_cols() { echo 80; }"
  _egress_editor_load "a-box-with-a-rather-long-name-for-this-screen"
  _egress_measure 26
  longest="$(_egress_draw 1 | sed $'s/\033\\[[0-9;]*[A-Za-z]//g' | awk '{ if (length($0) > m) m = length($0) } END { print m + 0 }')"
  [ "$longest" -lt 80 ]
}

@test "egress draw: a class word keeps its colour after the cut" {
  _rows_of 60
  eval "_term_cols() { echo 120; }"
  _egress_editor_load ""
  _egress_measure 26
  run bash -c 'cat' < <(_egress_draw 1)
  assert_output --partial "$(printf '%b' "$AMBER")shared"
  refute_output --partial '\033'
}

@test "egress audit: a stranger's page with no title still needs a person" {
  _audit_stub
  FOREIGN_ANSWER="200|1.1|93.184.215.14|AmazonS3|412|eeeeeeeeeeee|"
  run cmd_egress audit docs.example.test < /dev/null
  output="$(_plain "$output")"
  assert_output --partial "Verdict:  unaudited"
  refute_output --partial "Verdict:  contained"
}

@test "egress audit: the probe origin is never audited against itself" {
  _audit_stub
  run cmd_egress audit imgur.com < /dev/null
  assert_failure
  assert_output --partial "cannot audit itself"
  run cat "$AUDIT_LOG"
  assert_output ""
}

@test "egress ui: a launch under off leaves no record for the next launch to widen from" {
  local cn
  cn="$(container_name_for "$PROJECT" main)"
  printf '[egress]\nmode = strict\n' > "$CLEAT_GLOBAL_CONFIG"
  _egress_summary_row "$cn" >/dev/null
  printf '[egress]\nmode = off\n' > "$CLEAT_GLOBAL_CONFIG"
  _egress_summary_row "$cn" >/dev/null
  [ ! -e "$(_egress_ledger_path "$cn")" ]
  printf '[egress]\nmode = open\n' > "$CLEAT_GLOBAL_CONFIG"
  run _egress_summary_row "$cn"
  refute_output --partial "since the last launch"
}

@test "egress: --inherit drops a box file that does not parse, and stands alone" {
  local cn
  cn="$(container_name_for "$PROJECT" main)"
  mkdir -p "$_EGRESS_BOXES_DIR"
  printf '[egress]\nmode = strict\nmode = open\n' > "$_EGRESS_BOXES_DIR/$cn"
  run cmd_egress main --inherit < /dev/null
  assert_failure
  assert_output --partial "does not parse"
  [ -e "$_EGRESS_BOXES_DIR/$cn" ]
  run cmd_egress main --inherit --yes < /dev/null
  assert_success
  [ ! -e "$_EGRESS_BOXES_DIR/$cn" ]
  # A verb that reads never deletes on the side.
  printf '[egress]\nallow = docs.rs\n' > "$_EGRESS_BOXES_DIR/$cn"
  run cmd_egress status main --inherit < /dev/null
  assert_failure
  assert_output --partial "stands alone"
  [ -e "$_EGRESS_BOXES_DIR/$cn" ]
  run cmd_egress main --list --inherit < /dev/null
  assert_failure
  [ -e "$_EGRESS_BOXES_DIR/$cn" ]
  run cmd_egress --box= status < /dev/null
  assert_failure
  assert_output --partial "needs a box name"
}

@test "egress: allow under open says every host is allowed, and enable names what it kept" {
  printf '[egress]\nmode = open\n' > "$CLEAT_GLOBAL_CONFIG"
  run cmd_egress allow docs.rs < /dev/null
  output="$(_plain "$output")"
  assert_output --partial "Now open: every TLS host is allowed"
  refute_output --partial "port 443 only"
  printf '[egress]\nmode = off\npack = npm\n' > "$CLEAT_GLOBAL_CONFIG"
  run _egress_config_enable
  assert_output --partial "the packs and hosts already saved"
  refute_output --partial "and nothing else"
  printf '[egress]\nmode = off\n' > "$CLEAT_GLOBAL_CONFIG"
  run _egress_config_enable
  assert_output --partial "and nothing else"
}

# ── Stage three: the verbs, the reason registry, truthful copy ──────────────

@test "egress ui: a verb flag given to another verb is an error" {
  local pair verb flag owner
  for pair in "status --refused log" "log --shim restart" "open --pull restart" "restart --always open" "why --refused log"; do
    set -- $pair
    verb="$1"; flag="$2"; owner="$3"
    run cmd_egress "$verb" "$flag"
    assert_failure
    run sed $'s/\033\\[[0-9;]*m//g' <<< "$output"
    assert_output --partial "$flag belongs to cleat egress $owner."
  done
}

@test "egress ui: why and test need their argument and take at most a box after it" {
  run cmd_egress why
  assert_failure
  assert_output --partial "Which host or package?"
  run cmd_egress test
  assert_failure
  assert_output --partial "Which host?"
  run cmd_egress why github.com main extra
  assert_failure
  assert_output --partial "Too many arguments"
}

@test "egress ui: fix and tighten name what works today" {
  local v
  for v in fix tighten; do
    run cmd_egress "$v"
    assert_failure
    run sed $'s/\033\\[[0-9;]*m//g' <<< "$output"
    assert_output --partial "cleat egress $v lands in a later release."
    assert_output --partial "cleat egress why <host>"
  done
}

@test "egress ui: the sni subcode list is closed at six and handshake flood is not one of them" {
  run bash -c 'set -f; set -- $1; echo $#' _ "$_EGRESS_SNI_SUBCODES"
  assert_output "6"
  [[ " $_EGRESS_SNI_SUBCODES " != *" handshake-flood "* ]]
  [[ " $_EGRESS_REASON_CODES " == *" handshake-flood "* ]]
  # Exactly the three security codes, and no other code is one.
  local c
  for c in $_EGRESS_REASON_CODES; do
    case "$c" in
      sni|handshake-flood|address) _egress_log_is_security_code "$c" ;;
      *) ! _egress_log_is_security_code "$c" ;;
    esac
  done
}

@test "egress ui: a reason code a newer gateway sends prints as itself" {
  run _egress_reason_text "future-code"
  assert_output "future-code"
  run _egress_reason_text $'bad\033[31mcode'
  refute_output --partial $'\033'
  # sni and gateway name no command. gateway says it is not a denial.
  run _egress_reason_text sni
  refute_output --partial "cleat "
  run _egress_reason_text gateway
  assert_output --partial "This is not a policy denial."
}

@test "egress ui: with enforcement live no surface says it lands later" {
  _EGRESS_ENFORCING=1
  _egress_editor_engine() { _EGE_ENGINE=desktop-macos; }
  mkdir -p "$CLEAT_CONFIG_DIR"
  printf '[egress]\nmode = strict\npack = pypi\n' > "$CLEAT_GLOBAL_CONFIG"
  local out=""
  out+="$(cmd_egress status 2>&1)"
  out+="$(cmd_egress --list 2>&1)"
  out+="$(_egress_help 2>&1)"
  out+="$(cmd_help 2>&1)"
  _rows_of 40
  _egress_editor_load ""
  _egress_measure 26
  out+="$(_egress_save_screen 1 2>&1)"
  out+="$(_egress_draw 0 2>&1)"
  _EGE_RING_BACK=strict
  _EGE_MODE=open
  out+="$(_egress_pane_text mode 2>&1)"
  out+="$(_egress_config_enable 2>&1)"
  run printf '%s' "$out"
  refute_output --partial "lands with enforcement"
  refute_output --partial "land with enforcement"
  refute_output --partial "Enforcement lands"
  refute_output --partial "not enforced yet"
  refute_output --partial "Nothing is filtered today"
  refute_output --partial "nothing is filtered yet"
  # The unmeasured-core line stays until the maintainer's measurement.
  assert_output --partial "not yet been validated against a real Claude Code session"
}

@test "egress require: the editor still opens on a refused engine" {
  # Policy is portable: a user may write one here to run elsewhere. Only a
  # launch refuses, and the editor says so on its engine line.
  _EGRESS_ENFORCING=1
  _daemon_up() { return 0; }
  _egress_engine_kind() { printf engine-linux; }
  mkdir -p "$CLEAT_CONFIG_DIR"
  _rows_of 40
  _egress_editor_load ""
  _egress_measure 26
  run _egress_draw 0
  assert_success
  assert_output --partial "Engine   not validated, a caged box will not start here: Docker Engine"
  run _egress_save_screen 1
  assert_success
  assert_output --partial "a box under this policy will not start here"
  assert_output --partial "cleat egress off"
  # A validated engine says a save applies at the next launch.
  _EGE_ENGINE=""
  _egress_engine_kind() { printf desktop-macos; }
  run _egress_draw 0
  assert_output --partial "Engine   validated, a save applies at the next launch: Docker Desktop"
}
