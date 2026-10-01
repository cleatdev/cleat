#!/usr/bin/env bats
# ── Egress interface: what the editor offers and what arrives ticked ─────────
#
# EGRESS-SPEC.md section 6. One predicate, _egress_pretick_class_ok, decides
# whether a class may arrive ticked: 1 for unaudited before anything else, 0
# only for contained, 2 for every other class. The two named exceptions,
# apt-debian and apt-image-extras, may override a 2 and never a 1.
load "../setup"
load "../lib/egress_fixtures"
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

# A scripted key stream. The config editor reads keys through _read_keypress
# in a command substitution, so the position lives in a file. The egress
# editor reads through _egress_key in its own shell, from the same stream.
# When the stream runs out it answers QUIT, so a test can never spin.
_keys() {
  printf '%s\n' "$@" > "$TEST_TEMP/keys"
  echo 0 > "$TEST_TEMP/kp"
  _read_keypress() {
    local n
    n="$(cat "$TEST_TEMP/kp")"
    echo $(( n + 1 )) > "$TEST_TEMP/kp"
    sed -n "$(( n + 1 ))p" "$TEST_TEMP/keys" | grep . || echo QUIT
  }
  _egress_key() { _KEY="$(_read_keypress)"; }
}
# A window of <rows> rows and 110 columns, or <cols>. eval, because inside a
# nested definition $1 is the inner function's own argument, which is empty.
_rows_of() { eval "_term_rows() { echo $1; }; _term_cols() { echo ${2:-110}; }"; }
_row_index() { _egress_editor_rows | grep -nxF -- "$1" | cut -d: -f1 | awk '{ print $1 - 1 }'; }
_downs() { local i; for ((i = 0; i < $1; i++)); do printf 'DOWN '; done; }
_ups() { local i; for ((i = 0; i < $1; i++)); do printf 'UP '; done; }
# A frame as plain text: every escape out and each glyph one ASCII character,
# because some awks count bytes.
_plainw() {
  sed $'s/\033\\[[0-9;?]*[A-Za-z]//g' | sed 's/▸/>/g; s/✔/v/g; s/·/./g; s/‹/</g; s/›/>/g; s/…/~/g; s/✘/x/g; s/↑/^/g; s/↓/v/g; s/←/</g; s/→/>/g; s/⏎/E/g'
}
_widest() { _plainw | awk '{ if (length($0) > m) m = length($0) } END { print m + 0 }'; }
# The most lines any page of a paged review printed.
_review_page_max() {
  local rest="$1" page m=0 n
  while :; do
    page="${rest%%$'\033[H\033[2J'*}"
    n="$(printf '%s' "$page" | grep -c '')"
    if [ "$n" -gt "$m" ]; then m="$n"; fi
    [ "$page" = "$rest" ] && break
    rest="${rest#*$'\033[H\033[2J'}"
  done
  echo "$m"
}
# The engine the editor probes, validated, so no warning line takes a row.
_validated() { _egress_editor_engine() { _EGE_ENGINE=desktop-macos; }; }

@test "egress measure: 26 packs on a 24 row terminal give a page of 6, not 26" {
  _rows_of 24
  _egress_term_now
  _EG_E=0
  _EGE_NHOST=0
  _egress_measure 26
  run echo "$_EG_PAGE"
  assert_output "6"
}

@test "egress measure: 2 packs in a 50 row window give a page of 2, not 33" {
  _rows_of 50
  _egress_term_now
  _EG_E=0
  _EGE_NHOST=0
  _egress_measure 2
  run echo "$_EG_PAGE"
  assert_output "2"
}

@test "egress measure: a 21 row terminal refuses the TUI and the text picker runs" {
  _EG_E=0
  _EGE_NHOST=0
  _rows_of 21
  _egress_term_now
  run _egress_measure 26
  assert_failure
  _rows_of 22
  _egress_term_now
  run _egress_measure 26
  assert_success
  # And it still holds the editor once the first host is added, so adding
  # one never drops to the typed picker.
  _EGE_NHOST=1
  run _egress_measure 26
  assert_success
  # With a host row, 21 rows are too few as well.
  _rows_of 21
  _egress_term_now
  run _egress_measure 26
  assert_failure
  _EGE_NHOST=0
  mkdir -p "$CLEAT_CONFIG_DIR"
  _rows_of 21
  _keys QUIT
  run _egress_editor "" <<< "q"
  assert_success
  assert_output --partial "(typed, what every box may reach)"
  refute_output --partial $'\033[?1049h'
  run _plain "$output"
  assert_output --partial "Mode strict (only the hosts ticked below)"
}

@test "egress measure: a window narrower than 60 columns runs the typed picker" {
  _EG_E=0
  _EGE_NHOST=0
  _rows_of 40 59
  _egress_term_now
  run _egress_measure 26
  assert_failure
  _rows_of 40 60
  _egress_term_now
  run _egress_measure 26
  assert_success
  mkdir -p "$CLEAT_CONFIG_DIR"
  _rows_of 40 59
  _keys QUIT
  run _egress_editor "" <<< "q"
  assert_output --partial "(typed, what every box may reach)"
}

@test "egress measure: host rows give way to pack rows in a short window" {
  _EG_E=0
  _EGE_NHOST=5
  _rows_of 22
  _egress_term_now
  _egress_measure 26
  run echo "$_EG_HV $_EG_PAGE"
  assert_output "1 3"
  _rows_of 40
  _egress_term_now
  _egress_measure 26
  run echo "$_EG_HV"
  assert_output "3"
}

@test "egress draw: a saturated page draws one line fewer than the terminal has rows" {
  _rows_of 24
  _egress_editor_load ""
  _egress_measure
  run bash -c 'wc -l' < <(_egress_draw 0)
  assert_output --regexp '^ *23$'
  _rows_of 40
  _egress_term_now
  _egress_measure
  run bash -c 'wc -l' < <(_egress_draw 5)
  assert_output --regexp '^ *39$'
  # With host rows and the engine line, the page gives way and the frame keeps
  # its height.
  mkdir -p "$CLEAT_CONFIG_DIR"
  printf '[egress]\nmode = strict\nallow = a.example.com\nallow = b.example.com\nallow = c.example.com\nallow = d.example.com\n' > "$CLEAT_GLOBAL_CONFIG"
  _rows_of 24
  _egress_editor_load ""
  _egress_measure
  run bash -c 'wc -l' < <(_egress_draw 0)
  assert_output --regexp '^ *23$'
  # A pack's hosts, scrolled in a short window, keep the same height.
  _validated
  _rows_of 18
  _egress_editor_load ""
  _egress_ix_of docs
  _egress_hosts_open "$_EGX"
  run bash -c 'wc -l' < <(_egress_draw)
  assert_output --regexp '^ *17$'
}

@test "egress draw: the frame is the same height whichever row the cursor is on" {
  trap - DEBUG
  mkdir -p "$CLEAT_CONFIG_DIR"
  printf '[egress]\nmode = strict\npack = npm\nallow = docs.rs\ndeny = api.github.com\n' > "$CLEAT_GLOBAL_CONFIG"
  _rows_of 30
  _egress_editor_load ""
  _egress_measure
  local i n want=""
  i=0
  while [ "$i" -lt "${#_EGR[@]}" ]; do
    n="$(_egress_draw "$i" | wc -l | tr -d ' ')"
    [ -n "$want" ] || want="$n"
    assert_equal "$n" "$want"
    i=$((i + 1))
  done
  assert_equal "$want" 29
}

@test "egress draw: every frame starts at the top left and clears what is below it" {
  _rows_of 30
  _egress_editor_load ""
  _egress_measure
  _egress_frame_build 0
  run printf '%s' "${_EGF:0:3}"
  assert_output $'\033[H'
  run printf '%s' "${_EGF: -3}"
  assert_output $'\033[J'
}

@test "egress ui: the editor cache agrees with the catalogue helpers for every pack" {
  # The cache is built in one pass for speed. It must say exactly what the
  # per-pack helpers say, or the editor draws a class the catalogue does not.
  # The reference helpers loop over the catalogue once per pack, which bats'
  # DEBUG trap makes ten times slower, so the trap is off for this test.
  trap - DEBUG
  _egress_editor_cache
  local p i n=0 k
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    i="$(_egress_cache_ix "$p")"
    assert_equal "${_EGC_HOSTS[i]}" "$(_egress_pack_hosts "$p")"
    assert_equal "${_EGC_ALL[i]}" "$(_egress_pack_hosts "$p" all)"
    assert_equal "${_EGC_CNT[i]}" "$(_egress_pack_hosts "$p" | grep -c . || true)"
    assert_equal "${_EGC_FLAGS[i]}" "$(_egress_pack_flags "$p")"
    assert_equal "${_EGC_WORD[i]}" "$(_egress_class_word "$(_egress_pack_class "$p")" "$(_egress_pack_flags "$p")")"
    # The editor's risk is the class word in plain words.
    _egress_risk_of "${_EGC_WORD[i]}"
    assert_equal "${_EGC_RISK[i]}" "$_EGK"
    # Every pack says what it is for.
    _egress_pack_purpose "$p"
    assert_not_equal "$_EGT" ""
    assert_equal "${_EGC_PURP[i]}" "$_EGT"
    n=$((n + 1))
  done < <(_egress_pack_ids)
  assert_equal "$n" "${#_EGC_P[@]}"
  assert_equal "$_EGC_IDS" "$(_egress_pack_ids)"
  # And every host's own risk is its catalogue word.
  k=0
  while [ "$k" -lt "${#_EGK_H[@]}" ]; do
    _egress_risk_of "$(_egress_host_word "${_EGK_H[k]}")"
    assert_equal "${_EGK_R[k]}" "$_EGK"
    k=$((k + 1))
  done
}

@test "egress draw: the detail pane is always _EGRESS_PANE_LINES lines" {
  _egress_editor_load ""
  local r
  for r in mode "$_EGRESS_ROW_FILTER" pack:apt-debian pack:github pack:containers pack:github-objects host:docs.rs "$_EGRESS_ROW_ADD"; do
    run bash -c 'wc -l' < <(_egress_pane_text "$r")
    assert_output --regexp "^ *${_EGRESS_PANE_LINES}\$"
  done
}

@test "egress draw: a pane line longer than the width is cut with an ellipsis and the pane stays 4 lines" {
  _rows_of 30 80
  _egress_editor_load ""
  _egress_measure
  local long
  long="$(printf 'x%.0s' $(seq 1 200))"
  _egress_pane_set() { _EGP=("$long" "! $long" "✘ $long" ""); }
  run _widest < <(_egress_draw 0)
  assert [ "$output" -lt 80 ]
  run bash -c 'wc -l' < <(_egress_draw 0)
  assert_output --regexp '^ *29$'
  run _plain "$(_egress_draw 0)"
  assert_output --partial "x…"
}

@test "egress ui: a label carrying a newline draws one physical row" {
  # The box name is cleaned when the editor loads it, and a filter only ever
  # arrives through the find prompt, which reads one line.
  mkdir -p "$CLEAT_CONFIG_DIR"
  _rows_of 24
  _egress_editor_load $'x\ny'
  _egress_measure
  _egress_filter_prompt <<< $'a\nb' >/dev/null
  run printf '%s' "$_EGE_FILTER"
  assert_output "a"
  local lines
  lines="$(_egress_draw 0 | wc -l | tr -d ' ')"
  assert_equal "$lines" "$(( _EGRESS_CHROME_LINES - 1 + _EGRESS_PANE_LINES + _EG_PAGE + _EG_HV + _EG_E ))"
}

@test "egress draw: no drawn line is wider than the terminal, so the redraw never drifts" {
  # Hundreds of frames: bats' own DEBUG trap on every command would make this
  # ten times slower, so it is off here, as in the cache test.
  trap - DEBUG
  local c r frames i
  mkdir -p "$CLEAT_CONFIG_DIR"
  printf '[egress]\nmode = strict\npack = npm\nallow = a-rather-long-host-name-for-the-host-column.example.com\ndeny = api.github.com\n' > "$CLEAT_GLOBAL_CONFIG"
  for c in 80 78 77 60; do
    _rows_of 60 "$c"
    _egress_editor_load ""
    _egress_measure
    # Every row's frame, and every listed pack's hosts.
    frames=""
    i=0
    while [ "$i" -lt "${#_EGR[@]}" ]; do
      frames+="$(_egress_draw "$i")"$'\n'
      i=$((i + 1))
    done
    for r in containers atlassian npm huggingface aws; do
      _egress_ix_of "$r"
      _egress_hosts_open "$_EGX"
      frames+="$(_egress_draw)"$'\n'
      _EG_SCREEN=list
    done
    run _widest <<< "$frames"
    assert [ "$output" -lt "$c" ]
  done
  # A box editor with a long box name stays inside the width too.
  _rows_of 60 80
  _egress_editor_load "a-box-with-a-rather-long-name-for-this-screen"
  _egress_measure
  run _widest < <(_egress_draw 1)
  assert [ "$output" -lt 80 ]
}

@test "egress draw: a risk word keeps its colour after the cut" {
  _rows_of 60 120
  _egress_editor_load ""
  _egress_measure
  run bash -c 'cat' < <(_egress_draw 1)
  assert_output --partial "$(printf '%b' "$AMBER")! reaches other sites"
  assert_output --partial "$(printf '%b' "$AMBER")! anyone can upload"
  refute_output --partial '\033'
}

@test "egress draw: every risky pack row carries its risk word and no safe row does" {
  _rows_of 60 120
  _egress_editor_load ""
  _egress_measure
  local i ix p line
  _egress_frame_build 0
  i=0
  while [ "$i" -lt "${#_EGO[@]}" ]; do
    ix="${_EGO[i]}"
    p="${_EGC_P[ix]}"
    line="$(printf '%s\n' "$_EGF" | _plainw | grep -E "^ {2,4}(> )?\[.\] $p +" || true)"
    case "${_EGC_WORD[ix]}" in
      shared) assert_equal "${line##* ! }" "reaches other sites" ;;
      "open tenancy") assert_equal "${line##* ! }" "anyone can upload" ;;
      unaudited) assert_equal "${line##* ! }" "not checked" ;;
      *)
        case "$line" in *" ! "*) fail "a safe pack carries a risk word: $line" ;; esac ;;
    esac
    i=$((i + 1))
  done
}

@test "egress draw: the mode row names what the mode does for every ring value" {
  trap - DEBUG
  _rows_of 40
  mkdir -p "$CLEAT_CONFIG_DIR"
  printf '[egress]\nmode = strict\n' > "$CLEAT_GLOBAL_CONFIG"
  local m
  _egress_editor_load ""
  _egress_measure
  for m in strict open off; do
    _EGE_MODE="$m"
    run _plain "$(_egress_draw 5)"
    case "$m" in
      strict) assert_output --partial "Mode    strict     (only the hosts ticked below)" ;;
      open) assert_output --partial "Mode    open       (per box only, not saved here)" ;;
      off) assert_output --partial "Mode    off        (no control for new boxes)" ;;
    esac
  done
  _egress_editor_load main
  _egress_measure
  for m in inherit strict open off; do
    _EGE_MODE="$m"
    run _plain "$(_egress_draw 0)"
    case "$m" in
      inherit) assert_output --partial "Mode  ‹ inherit ›  (same as every box: strict)" ;;
      strict) assert_output --partial "Mode  ‹ strict ›   (only the hosts ticked below)" ;;
      open) assert_output --partial "Mode  ‹ open ›     (any host until it stops, logged)" ;;
      off) assert_output --partial "Mode  ‹ off ›      (no control: any host, any port)" ;;
    esac
  done
}

@test "egress picker: a keypress forks nothing and calls docker nothing" {
  trap - DEBUG
  # The first editor ran about 300 processes and 3 docker calls on every key,
  # which was its lag. The real loop runs over every row kind, both editors,
  # with a DEBUG trap armed from its first key. It records any command
  # substitution, any command run in a child process (a subshell, a pipeline,
  # a process substitution) and any command that is not a builtin, a keyword
  # or a function. BASHPID marks a child on bash 4 and later, BASH_SUBSHELL
  # the rest on 3.2. The stub's call log records docker.
  mkdir -p "$CLEAT_CONFIG_DIR"
  printf '[egress]\nmode = strict\npack = github\npack = npm\nallow = docs.rs\ndeny = api.github.com\n' > "$CLEAT_GLOBAL_CONFIG"
  local words box log="$TEST_TEMP/forks" me i n
  words=" $(compgen -b | tr '\n' ' ') $(compgen -k | tr '\n' ' ') (( [[ "
  me="${BASHPID:-}"
  : > "$log"
  _fd_trap() {
    if [ "$BASH_SUBSHELL" -gt 0 ] || { [ -n "$me" ] && [ "${BASHPID:-$me}" != "$me" ]; }; then
      printf 'child: %s\n' "$BASH_COMMAND" >> "$log"
      return 0
    fi
    case "${BASH_COMMAND//'$(('/}" in *'$('*|*'`'*|*'<('*|*'>('*|*' | '*) printf 'subst: %s\n' "$BASH_COMMAND" >> "$log" ;; esac
    local w="${BASH_COMMAND%% *}"
    case "$w" in *=*) return 0 ;; esac
    declare -F "$w" >/dev/null 2>&1 && return 0
    case "$words" in *" $w "*) return 0 ;; esac
    printf 'external: %s\n' "$BASH_COMMAND" >> "$log"
  }
  _rows_of 30
  for box in "" main; do
    # The keys: the ring both ways, then every row. A pack is ticked and
    # unticked and its hosts opened, keyed and left, a host row is ticked
    # twice. Find and Add are passed by, since a prompt may fork.
    _egress_editor_load "$box"
    K=(RIGHT RIGHT RIGHT RIGHT LEFT LEFT LEFT LEFT OTHER DOWN)
    n="${#_EGR[@]}"
    # Every pack row is walked in the global editor. The box editor keys
    # every third, which still meets each kind of row (on, off, no default
    # host, a part to type) at a third of the cost.
    i=2
    while [ "$i" -lt "$n" ]; do
      case "${_EGR[i]}" in
        pack:*)
          if [ -z "$box" ] || [ $(( i % 3 )) = 0 ]; then
            K+=(SPACE LEFT SPACE LEFT RIGHT DOWN SPACE SPACE UP LEFT DOWN)
          else
            K+=(DOWN)
          fi ;;
        host:*) K+=(SPACE SPACE DOWN) ;;
      esac
      i=$((i + 1))
    done
    for i in $(seq 1 $(( n + 2 ))); do K+=(UP); done
    K+=(QUIT)
    KI=0
    _egress_key() {
      if [ "$KI" = 0 ]; then
        : > "$DOCKER_CALLS"
        set -T
        trap '_fd_trap' DEBUG
      fi
      _KEY="${K[$KI]:-QUIT}"
      KI=$((KI + 1))
    }
    # A prompt the walk lands on answers end of input.
    _egress_picker_tui "$box" > "$TEST_TEMP/frames" < /dev/null
    trap - DEBUG
    set +T
    run cat "$log"
    assert_output ""
    run cat "$DOCKER_CALLS"
    assert_output ""
    assert [ "$KI" -gt 30 ]
  done
}

@test "egress picker: the engine is probed once per editor, never per draw" {
  _rows_of 30
  local once
  : > "$DOCKER_CALLS"
  _egress_editor_load ""
  once="$(wc -l < "$DOCKER_CALLS" | tr -d ' ')"
  assert [ "$once" -gt 0 ]
  : > "$DOCKER_CALLS"
  _keys DOWN DOWN SPACE DOWN RIGHT LEFT UP LEFT RIGHT DOWN DOWN SPACE QUIT
  run _egress_picker_tui ""
  assert_success
  run bash -c 'wc -l < "$1" | tr -d " "' _ "$DOCKER_CALLS"
  assert_output "$once"
}

@test "egress picker: the add row is reachable by arrow keys alone" {
  mkdir -p "$CLEAT_CONFIG_DIR"
  _rows_of 30
  _egress_editor_load ""
  local add
  add="$(_row_index "$_EGRESS_ROW_ADD")"
  _keys $(_downs "$add") SPACE ENTER
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
  _keys $(_downs "$f") SPACE QUIT
  run _egress_picker_tui "" <<< "APT"
  run _plain "$output"
  assert_output --partial "[/] Find a pack           apt"
  assert_output --partial "Packs matching \"apt\" (space ticks)"
  assert_output --partial "3 of 26"
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

@test "egress picker: q and escape write nothing, whatever was ticked" {
  mkdir -p "$CLEAT_CONFIG_DIR"
  _rows_of 30
  _keys DOWN DOWN SPACE RIGHT DOWN SPACE LEFT QUIT
  run _egress_picker_tui ""
  assert_success
  assert_output --partial "Nothing saved."
  run test -e "$CLEAT_GLOBAL_CONFIG"
  assert_failure
  # Esc ends the editor itself, before the stream could run out.
  _keys ESC DOWN DOWN
  run _egress_picker_tui ""
  assert_output --partial "Nothing saved."
  run cat "$TEST_TEMP/kp"
  assert_output "1"
  run test -e "$CLEAT_GLOBAL_CONFIG"
  assert_failure
}

@test "egress picker: enter reviews and saves from any row" {
  trap - DEBUG
  # The maintainer's rule: enter saves from every row, as cleat config does.
  mkdir -p "$CLEAT_CONFIG_DIR"
  _rows_of 30
  _egress_editor_load ""
  local gh r n
  gh="$(_row_index pack:github)"
  for r in mode "$_EGRESS_ROW_FILTER" pack:npm "$_EGRESS_ROW_ADD"; do
    rm -f "$CLEAT_GLOBAL_CONFIG"
    _egress_editor_load ""
    n="$(_row_index "$r")"
    _keys $(_downs "$gh") SPACE $(_ups 60) $(_downs "$n") ENTER
    run _egress_picker_tui "" <<< "y"
    assert_success
    run _egress_section_canon "$CLEAT_GLOBAL_CONFIG"
    assert_output "mode = strict
pack = github"
  done
  # And from a pack's hosts.
  rm -f "$CLEAT_GLOBAL_CONFIG"
  _keys $(_downs "$gh") SPACE RIGHT ENTER
  run _egress_picker_tui "" <<< "y"
  run _egress_section_canon "$CLEAT_GLOBAL_CONFIG"
  assert_output "mode = strict
pack = github"
}

@test "egress picker: space ticks a pack and the save writes it" {
  mkdir -p "$CLEAT_CONFIG_DIR"
  _rows_of 30
  _egress_editor_load ""
  local gh
  gh="$(_row_index pack:github)"
  _keys $(_downs "$gh") SPACE ENTER
  run _egress_picker_tui "" <<< "y"
  assert_success
  run _egress_section_canon "$CLEAT_GLOBAL_CONFIG"
  assert_output "mode = strict
pack = github"
}

@test "egress picker: the containers pack ticks like any pack, for pulls without a Docker daemon" {
  # It once needed the docker cap, which egress control refuses, so it could
  # never be ticked. A registry pull needs no daemon (skopeo, crane, oras).
  # With the cap the host daemon pulls, outside the box's egress anyway.
  mkdir -p "$CLEAT_CONFIG_DIR"
  _rows_of 60
  _egress_editor_load ""
  _egress_measure
  run _plain "$(_egress_draw 0)"
  assert_output --regexp "\[·\] containers +skopeo, crane and oras +! anyone can upload"
  refute_output --partial "docker cap"
  _egress_toggle pack:containers
  run _egress_is_ticked containers
  assert_success
  # From its hosts too: space on a host that comes with it ticks the pack.
  _egress_toggle pack:containers
  _egress_ix_of containers
  _egress_hosts_open "$_EGX"
  _KEY=SPACE
  _egress_tui_key
  run _egress_is_ticked containers
  assert_success
  _EG_SCREEN=list
  # And from the typed picker, which saves it.
  _egress_editor_load ""
  run _egress_picker_text "" <<< $'containers\ndone\ny'
  refute_output --partial "docker cap"
  run _egress_section_canon "$CLEAT_GLOBAL_CONFIG"
  assert_output --partial "pack = containers"
}

@test "egress picker: a pack with no default host cannot be ticked as a pack" {
  mkdir -p "$CLEAT_CONFIG_DIR"
  _rows_of 40
  _egress_editor_load ""
  _egress_toggle pack:github-objects
  run _egress_is_ticked github-objects
  assert_failure
  # Space on its row opens its hosts, to pick one by one.
  _egress_cursor_to pack:github-objects
  _KEY=SPACE
  _egress_tui_key
  run echo "$_EG_SCREEN"
  assert_output "hosts"
  run _egress_picker_text "" <<< $'github-objects\nq'
  assert_output --partial "github-objects has no host that comes with it."
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
  _egress_editor_load main
  run echo "$_EGE_MODE"
  assert_output "inherit"
  _egress_mode_step 1
  run echo "$_EGE_MODE"
  assert_output "strict"
}

@test "egress picker: left and right do nothing off the mode row" {
  _rows_of 30
  _egress_editor_load ""
  _egress_cursor_to pack:github
  _KEY=LEFT
  _egress_tui_key
  run echo "$_EGE_MODE $_EG_SCREEN"
  assert_output "strict list"
  _egress_cursor_to "$_EGRESS_ROW_ADD"
  _KEY=RIGHT
  _egress_tui_key
  run echo "$_EGE_MODE $_EG_SCREEN"
  assert_output "strict list"
  _EG_CUR=0
  _KEY=LEFT
  _egress_tui_key
  run echo "$_EGE_MODE"
  assert_output "off"
}

@test "egress picker: right on a pack opens its hosts and space there ticks the pack" {
  _rows_of 30
  _egress_editor_load ""
  local go
  go="$(_row_index pack:go)"
  _keys $(_downs "$go") RIGHT SPACE QUIT
  run _egress_picker_tui ""
  run _plain "$output"
  assert_output --partial "go (go get and go mod)"
  assert_output --partial "comes with the pack"
  assert_output --partial "[✔] proxy.golang.org"
  # q on the hosts goes back to the list, and a second q leaves.
  _keys $(_downs "$go") RIGHT QUIT QUIT
  run _egress_picker_tui ""
  run grep -c "Nothing saved" <<< "$output"
  assert_output "1"
}

@test "egress picker: a host added on its own from a pack's hosts is saved as a host of yours" {
  mkdir -p "$CLEAT_CONFIG_DIR"
  _rows_of 30
  _egress_editor_load ""
  local npm
  npm="$(_row_index pack:npm)"
  _keys $(_downs "$npm") RIGHT DOWN SPACE ENTER
  run _egress_picker_tui "" <<< "y"
  run _egress_section_canon "$CLEAT_GLOBAL_CONFIG"
  assert_output "mode = strict
allow = registry.yarnpkg.com"
}

@test "egress picker: a named site is saved as an exact allow and a dot is refused" {
  mkdir -p "$CLEAT_CONFIG_DIR"
  _rows_of 30
  _egress_editor_load ""
  _egress_ix_of atlassian
  _egress_hosts_open "$_EGX"
  _EG_HCUR=$(( ${#_EGH[@]} - 1 ))
  run printf '%s' "${_EGH[$_EG_HCUR]}"
  assert_output "tpl:{site}.atlassian.net"
  _egress_fill_prompt <<< $'acme.evil.com\n-acme\nAcme' > "$TEST_TEMP/out"
  run _plain "$(cat "$TEST_TEMP/out")"
  assert_output --partial "Only letters, digits and dashes, like acme."
  assert_output --partial "A name cannot start or end with a dash."
  run printf '%s' "$_EGE_HOSTS"
  assert_output "acme.atlassian.net"
  run printf '%s' "$_EG_SCREEN ${_EGR[$_EG_CUR]}"
  assert_output "list host:acme.atlassian.net"
}

@test "egress picker: a host typed in the wrong shape is refused with the reason and no lost typing" {
  _rows_of 30
  _egress_editor_load ""
  _egress_add_prompt <<< $'*.acme.internal\nhttps://Docs.RS/\nhttp://deb.debian.org:80\nuser@git.acme.internal/repo\ndocs.rs' > "$TEST_TEMP/out"
  run _plain "$(cat "$TEST_TEMP/out")"
  assert_output --partial "No wildcards"
  assert_output --partial "Did you mean:  docs.rs"
  assert_output --partial "Port 80 carries no ClientHello"
  assert_output --partial "No userinfo and no path"
  run printf '%s' "$_EGE_HOSTS"
  assert_output "docs.rs"
}

@test "egress picker: a prompt draws inside the frame, never under it" {
  _rows_of 30
  _egress_editor_load ""
  _egress_measure
  _egress_add_prompt <<< $'*.bad\ndocs.rs' > "$TEST_TEMP/out"
  # Everything written is a frame: it starts at the top left, and nothing is
  # printed after the last one.
  run head -c 3 "$TEST_TEMP/out"
  assert_output $'\033[H'
  run _plain "$(cat "$TEST_TEMP/out")"
  assert_output --partial "  Add a host > "
  # The line is drawn again on the frame's last line after every key. Only
  # there, with the cursor left after what is typed.
  run sort -u < <(grep -ao $'\033''\[[0-9]*;1H' "$TEST_TEMP/out")
  assert_output $'\033[29;1H'
}

@test "egress picker: Esc goes back from every prompt and changes nothing" {
  # Each prompt gets Esc, then more typing two seconds later, well after Esc
  # has had its second. The prompt must be gone by then and leave that typing
  # unread, so end of input cannot stand in for Esc. fd 7: bats owns fd 3.
  mkdir -p "$CLEAT_CONFIG_DIR"
  _rows_of 30
  _egress_editor_load ""
  _egress_measure
  local rest rc
  # Add a host: what was typed is dropped.
  rc=0
  exec 7< <(printf 'docs.rs\033'; sleep 2; printf 'later.example.com\n')
  _egress_add_prompt <&7 > "$TEST_TEMP/out.add" || rc=$?
  IFS= read -r rest <&7 || true
  exec 7<&-
  assert_equal "$rc" 1
  assert_equal "$rest" "later.example.com"
  run printf '%s' "$_EGE_HOSTS"
  assert_output ""
  run printf '%s' "$_EG_PROMPT"
  assert_output ""
  # Find a pack: the filter stays as it was.
  _EGE_FILTER=git
  _egress_rows_build
  exec 7< <(printf 'npm\033'; sleep 2; printf 'later\n')
  _egress_filter_prompt <&7 > "$TEST_TEMP/out.find"
  IFS= read -r rest <&7 || true
  exec 7<&-
  assert_equal "$rest" "later"
  run printf '%s' "$_EGE_FILTER"
  assert_output "git"
  _EGE_FILTER=""
  _egress_rows_build
  # The part in braces: no host, still on the pack's hosts.
  _egress_ix_of atlassian
  _egress_hosts_open "$_EGX"
  _EG_HCUR=$(( ${#_EGH[@]} - 1 ))
  rc=0
  exec 7< <(printf 'acme\033'; sleep 2; printf 'later\n')
  _egress_fill_prompt <&7 > "$TEST_TEMP/out.fill" || rc=$?
  IFS= read -r rest <&7 || true
  exec 7<&-
  assert_equal "$rc" 1
  assert_equal "$rest" "later"
  run printf '%s|%s' "$_EGE_HOSTS" "$_EG_SCREEN"
  assert_output "|hosts"
  # Each prompt says so.
  local f
  for f in add find fill; do
    run _plain "$(cat "$TEST_TEMP/out.$f")"
    assert_output --partial "Esc goes back."
  done
}

@test "egress picker: Esc in the add prompt goes back to the list and the editor carries on" {
  mkdir -p "$CLEAT_CONFIG_DIR"
  _rows_of 30
  _egress_editor_load ""
  local add
  add="$(_row_index "$_EGRESS_ROW_ADD")"
  # The keys after the prompt come from the list: the prompt reads its own
  # line from stdin, which goes on after Esc has had its second.
  _keys $(_downs "$add") SPACE UP QUIT
  run _egress_picker_tui "" < <(printf 'docs.rs\033'; sleep 2; printf 'x\n')
  assert_success
  run _plain "$output"
  refute_output --partial "Added"
  assert_output --partial "Nothing saved."
}

@test "egress picker: Esc twice is Esc while Esc with an arrow or a letter types nothing" {
  mkdir -p "$CLEAT_CONFIG_DIR"
  _rows_of 30
  _egress_editor_load ""
  _egress_measure
  local rest rc=0
  # Esc twice goes back. What is typed later stays unread.
  exec 7< <(printf 'docs.rs\033\033'; sleep 2; printf 'x\n')
  _egress_add_prompt <&7 > "$TEST_TEMP/out" || rc=$?
  IFS= read -r rest <&7 || true
  exec 7<&-
  assert_equal "$rc" 1
  assert_equal "$rest" "x"
  run printf '%s' "$_EGE_HOSTS"
  assert_output ""
  # Esc then an arrow inside Esc's second is how some terminals send
  # Option+Down. It is read whole and types nothing: no stray B.
  _egress_add_prompt < <(printf 'docs.rs\033\033[B\n') > "$TEST_TEMP/out"
  run printf '%s' "$_EGE_HOSTS"
  assert_output "docs.rs"
  _egress_editor_load ""
  # Option+Left in Terminal.app sends ESC b. It moves nothing here and must
  # not close the prompt, though no second byte follows within the second:
  # bash 3.2 threw away the b and read it as Esc.
  exec 7< <(printf 'docs.r\033b'; sleep 2; printf 's\n')
  _egress_add_prompt <&7 > "$TEST_TEMP/out"
  exec 7<&-
  run printf '%s' "$_EGE_HOSTS"
  assert_output "docs.rs"
}

@test "egress picker: the key reader tells Esc from arrows, chords and longer sequences" {
  local s want
  for s in $'\e[A:UP' $'\eOA:UP' $'\e[B:DOWN' $'\eOB:DOWN' $'\e[C:RIGHT' $'\eOC:RIGHT' $'\e[D:LEFT' $'\eOD:LEFT' $'\e:ESC' $'\eb:OTHER' $'\e[3~:OTHER' $'\e[1;5C:OTHER' $'\e\e[B:OTHER' $'\e\e:ESC'; do
    want="${s##*:}"
    _egress_key <<< "${s%:*}"
    assert_equal "$_KEY" "$want"
  done
  # A longer sequence is read to its end: the key after it is the next key.
  _egress_key < <(printf '\033[3~q')
  assert_equal "$_KEY" OTHER
  { _egress_key; _egress_key; } < <(printf '\033[3~q')
  assert_equal "$_KEY" QUIT
}

@test "egress picker: a key that is not plain ASCII shows as ? and is never dropped from the line" {
  mkdir -p "$CLEAT_CONFIG_DIR"
  _rows_of 30 60
  _egress_editor_load ""
  _egress_measure
  # A paste of bücher.de must not become bcher.de.
  _egress_add_prompt < <(printf 'b\303\274cher.de\n') > "$TEST_TEMP/out" || true
  run printf '%s' "$_EGE_HOSTS"
  assert_output ""
  run _plain "$(cat "$TEST_TEMP/out")"
  assert_output --partial "Only plain ASCII can be typed here."
  assert_output --regexp "Add a host > b\?+cher\.de"
  # Wide characters never widen the line past the window.
  local o
  _egress_add_prompt < <(printf '%s\033' "$(printf '例%.0s' $(seq 1 40))") > "$TEST_TEMP/out" || true
  # The frame is drawn twice, when the prompt opens and when the refusal
  # first shows, not once a byte: a long paste stays cheap, which bash 3.2
  # needs.
  run grep -o $'\033\\[H' "$TEST_TEMP/out"
  assert_equal "${#lines[@]}" 2
  # A refusal draws the frame again from the top left, so split there too.
  o="$(cat "$TEST_TEMP/out")"
  o="${o//$'\033[29;1H'/$'\n'}"
  run _widest < <(_plainw <<< "${o//$'\033[H'/$'\n'}")
  assert [ "$output" -lt 60 ]
}

@test "egress picker: a prompt holds 253 characters, shows the cursor while typing and hides it after" {
  _rows_of 30
  _egress_editor_load ""
  _egress_measure
  _egress_prompt_line "Add a host >" < <(printf '%s\n' "$(printf 'a%.0s' $(seq 1 300))") > "$TEST_TEMP/out"
  assert_equal "${#_EG_IN}" 253
  run grep -c $'\033\\[?25h' "$TEST_TEMP/out"
  assert_output "1"
  run tail -c 6 "$TEST_TEMP/out"
  assert_output $'\033[?25l'
}

@test "egress picker: a resize while typing ends the prompt when the window is too small and redraws it when not" {
  mkdir -p "$CLEAT_CONFIG_DIR"
  _rows_of 30
  _egress_editor_load ""
  _egress_measure
  # The resize arrives after the second key, while the prompt waits for the
  # third: the check after that key must see it.
  eval "$(declare -f _egress_prompt_echo | sed '1s/_egress_prompt_echo/_eg_echo_real/')"
  _EG_NECHO=0
  _EG_TO=15
  _egress_prompt_echo() {
    _EG_NECHO=$((_EG_NECHO + 1))
    if [ "$_EG_NECHO" = 3 ]; then
      _EG_WINCH=1
      eval "_egress_term_now() { _EG_ROWS=$_EG_TO; _EG_RAWCOLS=110; }"
    fi
    _eg_echo_real
  }
  local rc=0
  _egress_add_prompt < <(printf 'docs.rs\n') > "$TEST_TEMP/out" || rc=$?
  assert_equal "$rc" 1
  run printf '%s' "$_EGE_HOSTS"
  assert_output ""
  # Grown to 40 rows: the frame is drawn again and the line moves to its
  # last row. The name goes in.
  _egress_term_now() { _EG_ROWS=30; _EG_RAWCOLS=110; }
  _egress_term_now
  _egress_measure
  _EG_NECHO=0
  _EG_TO=40
  _egress_add_prompt < <(printf 'docs.rs\n') > "$TEST_TEMP/out"
  run printf '%s' "$_EGE_HOSTS"
  assert_output "docs.rs"
  run grep -c $'\033\\[39;1H' "$TEST_TEMP/out"
  refute_output "0"
}

@test "egress picker: a prompt edits its line a key at a time" {
  mkdir -p "$CLEAT_CONFIG_DIR"
  _rows_of 30
  local in
  # Backspace (both bytes), Ctrl-U, arrows and longer key sequences, a tab.
  for in in 'docs.rx\177s' 'docs.rt\bs' 'junk\025docs.rs' 'do\033[Dcs\033[3~.rs\033[1;5C' 'do\tcs.\033OArs' 'docs.r\033bs'; do
    _egress_editor_load ""
    _egress_measure
    _egress_add_prompt < <(printf "$in\n") > "$TEST_TEMP/out"
    run printf '%s' "$_EGE_HOSTS"
    assert_output "docs.rs"
  done
  # Ctrl-D on an empty line goes back, on a typed one it is ignored.
  _egress_editor_load ""
  _egress_measure
  _egress_add_prompt < <(printf '\004docs.rs\n') > "$TEST_TEMP/out" || true
  run printf '%s' "$_EGE_HOSTS"
  assert_output ""
  _egress_add_prompt < <(printf 'docs\004.rs\n') > "$TEST_TEMP/out"
  run printf '%s' "$_EGE_HOSTS"
  assert_output "docs.rs"
}

@test "egress picker: a long typed line keeps its end in view and never wraps" {
  mkdir -p "$CLEAT_CONFIG_DIR"
  local c long o
  long="$(printf 'a%.0s' $(seq 1 150)).example.com"
  for c in 60 80; do
    _rows_of 30 "$c"
    _egress_editor_load ""
    _egress_measure
    _egress_add_prompt < <(printf '%s\033' "$long") > "$TEST_TEMP/out" || true
    # Each redraw of the line, one per row.
    o="$(cat "$TEST_TEMP/out")"
    run _plainw <<< "${o##*$'\033[29;1H'}"
    assert_output --regexp "Add a host > ~a+\.example\.com$"
    run _widest < <(_plainw <<< "${o//$'\033[29;1H'/$'\n'}")
    assert [ "$output" -lt "$c" ]
  done
}

@test "egress picker: typing in a prompt forks nothing" {
  _rows_of 30
  _egress_editor_load ""
  _egress_measure
  local words log="$TEST_TEMP/forks"
  words=" $(compgen -b | tr '\n' ' ') $(compgen -k | tr '\n' ' ') (( [[ "
  : > "$log"
  _fd_trap() {
    case "${BASH_COMMAND//'$(('/}" in *'$('*|*'`'*|*'<('*|*'>('*|*' | '*) printf 'subst: %s\n' "$BASH_COMMAND" >> "$log" ;; esac
    local w="${BASH_COMMAND%% *}"
    case "$w" in *=*) return 0 ;; esac
    declare -F "$w" >/dev/null 2>&1 && return 0
    case "$words" in *" $w "*) return 0 ;; esac
    printf 'external: %s\n' "$BASH_COMMAND" >> "$log"
  }
  printf 'docs.rx\177s\033[Dz\025docs.rs\n' > "$TEST_TEMP/in"
  set -T
  trap '_fd_trap' DEBUG
  _egress_prompt_line "Add a host >" < "$TEST_TEMP/in" > "$TEST_TEMP/out"
  trap - DEBUG
  set +T
  run cat "$log"
  assert_output ""
  run printf '%s' "$_EG_IN"
  assert_output "docs.rs"
}

@test "egress draw: one blank line always sits over the footer, however full the pane" {
  mkdir -p "$CLEAT_CONFIG_DIR"
  printf '[egress]\nmode = strict\npack = npm\nallow = docs.rs\n' > "$CLEAT_GLOBAL_CONFIG"
  _rows_of 40
  local box i out ix
  for box in "" main; do
    _egress_editor_load "$box"
    _egress_measure
    i=0
    while [ "$i" -lt "${#_EGR[@]}" ]; do
      out+="$(_egress_draw "$i")"$'\n'
      i=$((i + 1))
    done
    for ix in "${_EGO[@]}"; do
      _egress_hosts_open "$ix"
      out+="$(_egress_draw)"$'\n'
      _EG_SCREEN=list
    done
  done
  # The line over every "On save:" is blank, even under a full pane (the mode
  # row's is).
  run awk '/On save:/ { n++; if (prev !~ /^[[:space:]]*$/) bad++ } { prev = $0 } END { print n + 0, bad + 0 }' < <(_plainw <<< "$out")
  assert_output --regexp "^[1-9][0-9]* 0$"
}

@test "egress picker: the review has a screen of its own and a no brings the list back" {
  mkdir -p "$CLEAT_CONFIG_DIR"
  _rows_of 30
  _egress_editor_load ""
  local gh
  gh="$(_row_index pack:github)"
  _keys $(_downs "$gh") SPACE ENTER QUIT
  run _egress_picker_tui "" <<< "n"
  local drawn="$output"
  run _plain "$drawn"
  assert_output --partial "Save what every box may reach?"
  assert_output --partial "Not saved. Your changes are still here."
  assert_output --partial "Nothing saved."
  # The review is drawn on a cleared screen, not under the list: once when the
  # editor took the screen and once for the review.
  run grep -c $'\033\\[H\033\\[2J' <<< "$drawn"
  assert_output "2"
  run test -e "$CLEAT_GLOBAL_CONFIG"
  assert_failure
}

@test "egress picker: a refused save stays on screen until a key, then the list comes back" {
  mkdir -p "$CLEAT_CONFIG_DIR"
  printf '[egress]\nmode = strict\npack = npm\n' > "$CLEAT_GLOBAL_CONFIG"
  _EGRESS_ENFORCING=1
  _validated
  _daemon_up() { return 0; }
  _egress_label_read() { _EG_LABEL_SET=1; return 0; }
  is_running() { return 1; }
  _set_box main
  _rows_of 30
  # The q after the refusal is the wait's key, not a cancel: the editor
  # goes back to the list and reads once more before the stream runs out.
  _keys RIGHT RIGHT ENTER QUIT
  run _egress_picker_tui main
  run _plain "$output"
  assert_output --partial "is not running"
  assert_output --partial "Press any key to go back."
  run cat "$TEST_TEMP/kp"
  assert_output "5"
}

@test "egress picker: the editor takes the alternate screen and gives it back" {
  _rows_of 30
  _keys DOWN QUIT
  run _egress_picker_tui ""
  assert_output --partial $'\033[?1049h'
  assert_output --partial $'\033[?1049l'
  # The last thing written is outside it.
  run _plain "${output##*$'\033[?1049l'}"
  assert_output --partial "Nothing saved."
}

@test "egress picker: an interrupt restores the cursor, echo and the screen" {
  _rows_of 30
  _tui_echo_restore() { echo "ECHO RESTORED"; }
  _egress_key() { sh -c 'kill -INT $PPID'; sleep 1; _KEY=QUIT; }
  run _egress_picker_tui ""
  assert_equal "$status" 130
  assert_output --partial "ECHO RESTORED"
  run _plain "${output##*$'\033[?25h'}"
  refute_output --partial "Cleat egress"
  run grep -c $'\033\\[?1049l' <<< "$output"
  assert_output "1"
}

@test "egress picker: the editor key reader decodes every sequence as _read_keypress does" {
  local s want
  for s in $'\e[A' $'\e[B' $'\e[C' $'\e[D' $'\eOA' $'\eOB' $'\eOC' $'\eOD' $'\e[5~' $'\e[1;5C' $'\eb' $'\e\e' $'\e\e[B' $'\e' ' ' 'q' 'Q' 'x'; do
    want="$(printf '%s' "$s" | _read_keypress)"
    _KEY=""
    _egress_key < <(printf '%s' "$s")
    assert_equal "$_KEY" "$want"
  done
  _egress_key < <(printf '\n')
  assert_equal "$_KEY" "ENTER"
  # End of input is a cancel here, never enter: enter saves.
  _egress_key < /dev/null
  assert_equal "$_KEY" "QUIT"
}

@test "egress picker: the editor never opens when a save would be refused" {
  # The maintainer's rule: no editor for a save the writer would refuse. One
  # message names the capability, where it is on and the command.
  _EGRESS_ENFORCING=1
  mkdir -p "$CLEAT_CONFIG_DIR" "$PROJECT"
  cd "$PROJECT"
  printf '[caps]\ndocker\n' > "$CLEAT_GLOBAL_CONFIG"
  _keys QUIT
  run _egress_editor ""
  assert_failure
  refute_output --partial $'\033[?1049h'
  run _plain "$output"
  assert_output --partial "Egress control cannot be saved while the docker capability is on."
  assert_output --partial "hands the box your Docker daemon"
  assert_output --partial "It is on in your global config. Turn it off:  cleat config --disable docker"
  # A trusted project's own caps, and a box's own section.
  printf '[caps]\ngit\n' > "$CLEAT_GLOBAL_CONFIG"
  printf '[caps]\nssh\n[box.api.caps]\nhooks\n' > "$PROJECT/.cleat"
  _CLI_TRUST_PROJECT=1
  run _egress_editor ""
  assert_failure
  run _plain "$output"
  assert_output --partial "It is on in this project's .cleat. Turn it off:  cleat config --project --disable ssh"
  _set_box api
  run _egress_editor api
  assert_failure
  run _plain "$output"
  assert_output --partial "It is on for box api in this project's .cleat. Turn it off:  cleat config api --disable hooks"
  # main's own section replaces [caps] for main, so it is the one named.
  printf '[caps]\ngit\n[box.main.caps]\ndocker\n' > "$PROJECT/.cleat"
  _set_box main
  run _egress_editor ""
  assert_failure
  run _plain "$output"
  assert_output --partial "It is on for box main in this project's .cleat. Turn it off:  cleat config main --disable docker"
  # With no such capability it opens.
  printf '[caps]\ngit\n' > "$PROJECT/.cleat"
  _set_box main
  run _egress_editor ""
  assert_success
  assert_output --partial $'\033[?1049h'
}

@test "egress picker: the config row's off opens the editor even under a refused capability" {
  # Off is never refused, and the row that turns egress off must not be the
  # one door a capability closes.
  _EGRESS_ENFORCING=1
  _validated
  mkdir -p "$CLEAT_CONFIG_DIR" "$PROJECT"
  cd "$PROJECT"
  printf '[caps]\ndocker\n[egress]\nmode = strict\npack = npm\n' > "$CLEAT_GLOBAL_CONFIG"
  _egress_caged_boxes() { :; }
  _rows_of 30
  _keys ENTER
  run _egress_picker_tui "" off <<< "y"
  assert_success
  run _egress_section_canon "$CLEAT_GLOBAL_CONFIG"
  assert_output "mode = off
pack = npm"
}

# ── What a box shows and gets (M20) ──────────────────────────────────────────

@test "egress box: the box editor shows the global packs ticked for every box" {
  mkdir -p "$CLEAT_CONFIG_DIR"
  printf '[egress]\nmode = strict\npack = github\npack = npm\nallow = docs.rs\n' > "$CLEAT_GLOBAL_CONFIG"
  _rows_of 30
  _egress_editor_load main
  _egress_measure
  run _plain "$(_egress_draw 0)"
  assert_output --regexp "\[✔\] github +git, gh and tarballs +every box"
  assert_output --regexp "\[✔\] npm +npm, pnpm and yarn +every box"
  assert_output --partial "[✔] docs.rs"
  assert_output --partial "(same as every box: strict)"
  assert_output --partial "On save: 11 hosts allowed"
}

@test "egress box: the save count equals the resolved count, box and global" {
  trap - DEBUG
  mkdir -p "$CLEAT_CONFIG_DIR" "$_EGRESS_BOXES_DIR"
  local cn
  cn="$(_egress_target_cname main)"
  _counted() {
    _egress_resolve "$1"
    printf '%s\n' "$_EG_HOSTS" | grep -c .
  }
  printf '[egress]\nmode = strict\npack = github\npack = npm\nallow = docs.rs\n' > "$CLEAT_GLOBAL_CONFIG"
  _egress_editor_load main
  assert_equal "$_EGE_COUNT" 11
  assert_equal "$_EGE_COUNT" "$(_counted "$cn")"
  printf '[egress]\nmode = strict\npack = github\npack = npm\nallow = docs.rs\ndeny = api.github.com\n' > "$CLEAT_GLOBAL_CONFIG"
  _egress_editor_load main
  assert_equal "$_EGE_COUNT" 10
  # Unticking npm in the box: 9, and the resolver agrees after the save.
  _egress_toggle pack:npm
  assert_equal "$_EGE_COUNT" 9
  _egress_save_screen 1 >/dev/null
  assert_equal "$(_counted "$cn")" 9
  # A global pack that shares a host with the box's own: the shared host
  # stays, the other goes.
  rm -f "${_EGRESS_BOXES_DIR:?}/${cn:?}"
  printf '[egress]\nmode = strict\npack = dotnet\n' > "$CLEAT_GLOBAL_CONFIG"
  printf '[egress]\npack = azure-cli\n' > "$_EGRESS_BOXES_DIR/$cn"
  _egress_editor_load main
  assert_equal "$_EGE_COUNT" 7
  _egress_toggle pack:dotnet
  assert_equal "$_EGE_COUNT" 6
  _egress_save_screen 1 >/dev/null
  assert_equal "$(_counted "$cn")" 6
  # The global editor counts its own blocks.
  printf '[egress]\nmode = strict\npack = github\ndeny = api.github.com\n' > "$CLEAT_GLOBAL_CONFIG"
  _egress_editor_load ""
  assert_equal "$_EGE_COUNT" 8
  assert_equal "$_EGE_COUNT" "$(_counted "")"
}

@test "egress box: unticking an inherited pack denies only hosts no other tick provides" {
  trap - DEBUG
  mkdir -p "$CLEAT_CONFIG_DIR" "$_EGRESS_BOXES_DIR"
  local cn
  cn="$(_egress_target_cname main)"
  printf '[egress]\nmode = strict\npack = dotnet\npack = azure-cli\n' > "$CLEAT_GLOBAL_CONFIG"
  _egress_editor_load main
  _sorted() { printf '%s\n' "$1" | LC_ALL=C sort; }
  _egress_toggle pack:dotnet
  run _sorted "$_EGE_DENIES"
  assert_output "dot.net"
  run _egress_is_ticked azure-cli
  assert_success
  # Then azure-cli: now nothing else brings packages.microsoft.com.
  _egress_toggle pack:azure-cli
  run _sorted "$_EGE_DENIES"
  assert_output "dot.net
packages.microsoft.com"
  # dotnet back on brings packages.microsoft.com with it. azure-cli stays
  # off for this box, as the user left it, with nothing of its own to block.
  _egress_toggle pack:dotnet
  run printf '%s' "$_EGE_DENIES"
  assert_output ""
  run _egress_is_ticked azure-cli
  assert_failure
  assert_equal "$_EGE_COUNT" 7
  # A box whose file already blocks a pack's own hosts shows it off, and a
  # save it did not touch writes the blocks back as they were.
  printf '[egress]\ndeny = dot.net\ndeny = packages.microsoft.com\n' > "$_EGRESS_BOXES_DIR/$cn"
  _egress_editor_load main
  run _egress_is_ticked dotnet
  assert_failure
  run _egress_is_ticked azure-cli
  assert_failure
  _egress_host_add extra.example.com
  _egress_save_screen 1 >/dev/null
  run _egress_section_canon "$_EGRESS_BOXES_DIR/$cn"
  assert_output "deny = dot.net
deny = packages.microsoft.com
allow = extra.example.com"
  # Unticking the host an off pack was relying on blocks it again (the
  # review said the pack was off, so the file says so too).
  rm -f "${_EGRESS_BOXES_DIR:?}/${cn:?}"
  printf '[egress]\nmode = strict\npack = homebrew\n' > "$CLEAT_GLOBAL_CONFIG"
  printf '[egress]\nallow = ghcr.io\n' > "$_EGRESS_BOXES_DIR/$cn"
  _egress_editor_load main
  _egress_toggle pack:homebrew
  _egress_toggle host:ghcr.io
  _egress_save_screen 1 >/dev/null
  _egress_resolve "$cn"
  run _egress_in_list ghcr.io "$_EG_HOSTS"
  assert_failure
}

@test "egress box: no row or key changes the core" {
  mkdir -p "$CLEAT_CONFIG_DIR"
  printf '[egress]\nmode = strict\ndeny = claude.ai\n' > "$CLEAT_GLOBAL_CONFIG"
  _egress_editor_load ""
  assert_equal "$_EGE_COUNT" 5
  run _egress_editor_rows
  refute_output --partial "pack:claude"
  refute_output --partial "host:api.anthropic.com"
  _egress_toggle pack:claude
  assert_equal "$_EGE_COUNT" 5
  assert_equal "$_EGE_PACKS" ""
  _egress_resolve ""
  run printf '%s\n' "$_EG_HOSTS"
  assert_output --partial "claude.ai"
}

@test "egress box: a block of the user's own on a ticked pack's host shows as its own row" {
  mkdir -p "$CLEAT_CONFIG_DIR" "$_EGRESS_BOXES_DIR"
  local cn
  cn="$(_egress_target_cname main)"
  printf '[egress]\nmode = strict\npack = dotnet\npack = azure-cli\n' > "$CLEAT_GLOBAL_CONFIG"
  printf '[egress]\npack = azure-cli\ndeny = dot.net\ndeny = packages.microsoft.com\n' > "$_EGRESS_BOXES_DIR/$cn"
  _egress_editor_load main
  # dotnet reads as off for this box through dot.net. packages.microsoft.com
  # is azure-cli's only host: that block is the user's, and it shows.
  run _egress_is_ticked dotnet
  assert_failure
  run _egress_editor_rows
  assert_output --partial "host:packages.microsoft.com"
  run _egress_pack_note azure-cli
  assert_output "One of its hosts is blocked, in the hosts below."
  _egress_resolve "$cn"
  run bash -c 'printf "%s\n" "$1" | grep -c .' _ "$_EG_HOSTS"
  assert_output "$_EGE_COUNT"
}

@test "egress box: a host every box blocks that the box's own pack brings back is no blocked row" {
  mkdir -p "$CLEAT_CONFIG_DIR" "$_EGRESS_BOXES_DIR"
  local cn
  cn="$(_egress_target_cname main)"
  printf '[egress]\nmode = strict\ndeny = registry.npmjs.org\n' > "$CLEAT_GLOBAL_CONFIG"
  printf '[egress]\npack = npm\n' > "$_EGRESS_BOXES_DIR/$cn"
  _egress_editor_load main
  run _egress_editor_rows
  refute_output --partial "host:registry.npmjs.org"
  assert_equal "$_EGE_COUNT" 6
  # Without the box's own npm, every box's block shows, and holds.
  rm -f "${_EGRESS_BOXES_DIR:?}/${cn:?}"
  _egress_editor_load main
  run _egress_editor_rows
  assert_output --partial "host:registry.npmjs.org"
}

@test "egress box: a pack with no default host already in the file shows ticked and can be unticked" {
  mkdir -p "$CLEAT_CONFIG_DIR"
  printf '[egress]\nmode = strict\npack = github-objects\n' > "$CLEAT_GLOBAL_CONFIG"
  _rows_of 40
  _egress_editor_load ""
  _egress_measure
  run _plain "$(_egress_draw 0)"
  assert_output --regexp "\[✔\] github-objects"
  _egress_toggle pack:github-objects
  run printf '%s' "$_EGE_PACKS"
  assert_output ""
  # And, off again, it never ticks back.
  _egress_toggle pack:github-objects
  run printf '%s' "$_EGE_PACKS"
  assert_output ""
}

@test "egress box: host values count as the resolver reads them, and one that is no host goes back as it was" {
  trap - DEBUG
  mkdir -p "$CLEAT_CONFIG_DIR" "$_EGRESS_BOXES_DIR"
  local cn
  cn="$(_egress_target_cname main)"
  printf '[egress]\nmode = strict\npack = npm\n' > "$CLEAT_GLOBAL_CONFIG"
  printf '[egress]\ndeny = Registry.npmjs.org\nallow = Docs.RS.\nallow = not_a_host\n' > "$_EGRESS_BOXES_DIR/$cn"
  _egress_editor_load main
  _egress_resolve "$cn" >/dev/null 2>&1
  run bash -c 'printf "%s\n" "$1" | grep -c .' _ "$_EG_HOSTS"
  assert_output "$_EGE_COUNT"
  # The block, read as the resolver reads it, turns npm off for this box.
  run _egress_is_ticked npm
  assert_failure
  run _egress_editor_rows
  assert_output --partial "host:docs.rs"
  refute_output --partial "not_a_host"
  _egress_host_add extra.example.com
  _egress_save_screen 1 >/dev/null
  run _read_section_all_from_file "$_EGRESS_BOXES_DIR/$cn" egress allow
  assert_output --partial "not_a_host"
  assert_output --partial "docs.rs"
  # A value carrying a control sequence is no host: it is never drawn.
  printf '[egress]\nmode = strict\nallow = a\033[2Jb.example.com\nallow = ok.example.com\n' > "$CLEAT_GLOBAL_CONFIG"
  _rows_of 30
  _egress_editor_load ""
  _egress_measure
  _egress_frame_build 0
  run printf '%s' "$_EGF"
  refute_output --partial $'\033[2J'
  assert_equal "$_EGE_COUNT" 6
}

@test "egress save: a pack unticked for a box is named once" {
  mkdir -p "$CLEAT_CONFIG_DIR" "$_EGRESS_BOXES_DIR"
  local cn
  cn="$(_egress_target_cname main)"
  printf '[egress]\nmode = strict\npack = npm\n' > "$CLEAT_GLOBAL_CONFIG"
  printf '[egress]\npack = npm\n' > "$_EGRESS_BOXES_DIR/$cn"
  _egress_editor_load main
  _egress_toggle pack:npm
  run _egress_save_screen 1
  run _plain "$output"
  assert_output --partial "Removed   npm, off for this box only"
  refute_output --partial "npm and npm"
}

@test "egress save: a box that follows every box into off asks, default no" {
  # Stepping a box with a mode of its own back to inherit, while every box
  # is off, turns it off: the off confirmation asks, never Save? [Y/n].
  mkdir -p "$CLEAT_CONFIG_DIR" "$_EGRESS_BOXES_DIR"
  local cn
  cn="$(_egress_target_cname main)"
  printf '[egress]\nmode = off\npack = github\n' > "$CLEAT_GLOBAL_CONFIG"
  printf '[egress]\nmode = strict\n' > "$_EGRESS_BOXES_DIR/$cn"
  cp "$_EGRESS_BOXES_DIR/$cn" "$TEST_TEMP/before"
  # A box that exists and was made with no cage: off needs no recreate, and
  # the line after the save must not say it refuses to start.
  container_exists() { return 0; }
  _egress_label_read() { _EG_LABEL_SET=0; return 0; }
  _egress_editor_load main
  _egress_mode_step -1
  run echo "$_EGE_MODE"
  assert_output "inherit"
  run _egress_save_screen 0 <<< ""
  assert_failure
  assert_output --partial "Turn it off? [y/N]"
  refute_output --partial "Save? [Y/n]"
  run cmp "$_EGRESS_BOXES_DIR/$cn" "$TEST_TEMP/before"
  assert_success
  run _egress_save_screen 0 <<< "y"
  assert_success
  refute_output --partial "refuses to start"
  run cat "$_EGRESS_BOXES_DIR/$cn"
  assert_output "[egress]"
}

@test "egress save: a box that follows every box into open asks, default no" {
  mkdir -p "$CLEAT_CONFIG_DIR" "$_EGRESS_BOXES_DIR"
  local cn
  cn="$(_egress_target_cname main)"
  printf '[egress]\nmode = open\n' > "$CLEAT_GLOBAL_CONFIG"
  printf '[egress]\nmode = strict\n' > "$_EGRESS_BOXES_DIR/$cn"
  _egress_editor_load main
  _egress_mode_step -1
  run _egress_save_screen 0 <<< ""
  assert_failure
  assert_output --partial "will reach any host, as every box does"
  assert_output --partial "Save? [y/N]"
  run cat "$_EGRESS_BOXES_DIR/$cn"
  assert_output --partial "mode = strict"
}

@test "egress review: a review longer than the window is shown a page at a time" {
  _rows_of 12
  _egress_editor_load ""
  _EG_TUI=1
  _EG_ROWS=12
  local text i
  text=""
  for i in $(seq 1 20); do text+="line $i"$'\n'; done
  _keys OTHER OTHER
  run _egress_review_show "$text"
  assert_success
  assert_output --partial "More below: any key goes on, q goes back."
  assert_output --partial "line 1"
  assert_output --partial "line 20"
  # No page is taller than the window less the question's rows.
  run _review_page_max "$output"
  assert [ "$output" -le 10 ]
  # q on a page is a no.
  _keys QUIT
  run _egress_review_show "$text"
  assert_failure
  refute_output --partial "line 20"
  _EG_TUI=0
}

@test "egress draw: the global editor on a policy saved as open says every box is open" {
  mkdir -p "$CLEAT_CONFIG_DIR"
  printf '[egress]\nmode = open\npack = github\n' > "$CLEAT_GLOBAL_CONFIG"
  _rows_of 30
  _egress_editor_load ""
  _egress_measure
  run _plain "$(_egress_draw 0)"
  assert_output --partial "(any host for every box, logged)"
  assert_output --partial "On save: keeps open, any host for every box"
  assert_output --partial "cleat egress open --always set this."
  refute_output --partial "per box only"
}

@test "egress draw: a box's open session, a caged box under off and a box that cannot open say so" {
  trap - DEBUG
  mkdir -p "$CLEAT_CONFIG_DIR"
  printf '[egress]\nmode = strict\npack = github\n' > "$CLEAT_GLOBAL_CONFIG"
  _EGRESS_ENFORCING=1
  _validated
  _daemon_up() { return 0; }
  _egress_label_read() { _EG_LABEL_SET=1; return 0; }
  is_running() { return 1; }
  _egress_session_marker_valid() { return 0; }
  _rows_of 30
  _egress_editor_load main
  _egress_measure
  run _plain "$(_egress_draw 0)"
  assert_output --partial "(open until it stops, then same as every box: strict)"
  assert_output --partial "This box is open for this session: cleat egress open."
  _EGE_MODE=open
  run _plain "$(_egress_draw 3)"
  assert_output --partial "On save: already open until it stops"
  _egress_save_plan
  run echo "$_EGS_PLAN"
  assert_output "write"
  # No session, and the box stopped: the reason is on the status line.
  _egress_session_marker_valid() { return 1; }
  _egress_editor_load main
  _egress_measure
  _EGE_MODE=open
  run _plain "$(_egress_draw 3)"
  assert_output --partial "On save: cannot open: box main is not running"
  # Every box off, and this box made with a cage.
  printf '[egress]\nmode = off\npack = github\n' > "$CLEAT_GLOBAL_CONFIG"
  _egress_editor_load main
  _egress_measure
  run _plain "$(_egress_draw 0)"
  assert_output --partial "It was made with a cage, so it refuses to start"
}

@test "egress draw: at 60 columns no pane line of a pack, a mode or a tool row is cut" {
  trap - DEBUG
  mkdir -p "$CLEAT_CONFIG_DIR"
  _trusted_setup_project
  cd "$PROJECT"
  _rows_of 60 60
  local box r i
  for box in "" main; do
    _egress_editor_load "$box"
    _egress_measure
    i=0
    while [ "$i" -lt "${#_EGR[@]}" ]; do
      r="${_EGR[i]}"
      case "$r" in host:*) i=$((i + 1)); continue ;; esac
      _egress_pane_set "$r" "${_EGRI[i]}"
      _EGF=""
      _egress_pane_lines
      run _plain "$_EGF"
      refute_output --partial "…"
      i=$((i + 1))
    done
    for r in inherit strict open off; do
      if [ -z "$box" ] && [ "$r" = inherit ]; then continue; fi
      _EGE_MODE="$r"
      _egress_pane_set mode
      _EGF=""
      _egress_pane_lines
      run _plain "$_EGF"
      refute_output --partial "…"
    done
  done
}

@test "egress picker: a refused host names the rule in words, never a reason code" {
  local h
  for h in foo_bar.com a..b.com "exa mple.com" "$(printf 'x%.0s' $(seq 1 260)).com"; do
    run _egress_add_refusal "$h"
    refute_output --regexp "[A-Z_]{6,}"
  done
  run _egress_add_refusal "exa mple.com"
  assert_output --partial "No spaces"
  run _egress_add_refusal foo_bar.com
  assert_output --partial "Each part between dots is letters, digits and dashes."
}

@test "egress picker: a resize during a prompt ends it when the window no longer holds the editor" {
  _rows_of 30
  _egress_editor_load ""
  _egress_measure
  _EG_WINCH=1
  _egress_term_now() { _EG_ROWS=15; _EG_RAWCOLS=80; }
  run _egress_add_prompt <<< "docs.rs"
  assert_failure
  refute_output --partial "Add a host >"
}

@test "egress picker: at the top level Ctrl-C only exits and the exit gives the terminal back" {
  # On bash 4 and later an INT trap runs inside the key reader, which puts
  # back its echo-off state after the trap: a restore in the trap was undone.
  # So the interrupt only exits and the EXIT trap restores, after the reader.
  run bash -c 'source "$1"; _egress_tui_enter >/dev/null; trap -p INT; trap -p EXIT' _ "$CLI"
  assert_output --partial "trap -- 'exit 130' SIGINT"
  assert_output --partial "_egress_tui_exit"
}

@test "egress picker: the key reader itself runs no subprocess" {
  local words log="$TEST_TEMP/forks" s
  words=" $(compgen -b | tr '\n' ' ') $(compgen -k | tr '\n' ' ') (( [[ "
  : > "$log"
  _fd_trap() {
    case "${BASH_COMMAND//'$(('/}" in *'$('*|*'`'*|*'<('*|*'>('*|*' | '*) printf 'subst: %s\n' "$BASH_COMMAND" >> "$log" ;; esac
    local w="${BASH_COMMAND%% *}"
    case "$w" in *=*) return 0 ;; esac
    declare -F "$w" >/dev/null 2>&1 && return 0
    case "$words" in *" $w "*) return 0 ;; esac
    printf 'external: %s\n' "$BASH_COMMAND" >> "$log"
  }
  for s in x q $'\e[B' $'\eOA' $'\eb' $'\e\e[B' $'\e[1;5C'; do
    set -T
    trap '_fd_trap' DEBUG
    _egress_key <<< "$s"
    trap - DEBUG
    set +T
  done
  run cat "$log"
  assert_output ""
}

@test "egress picker: a save leaves the full screen first, so what it did stays on the screen" {
  mkdir -p "$CLEAT_CONFIG_DIR"
  _rows_of 30
  _egress_editor_load ""
  local gh
  gh="$(_row_index pack:github)"
  _keys $(_downs "$gh") SPACE ENTER
  run _egress_picker_tui "" <<< "y"
  assert_success
  assert_output --partial $'\033[?1049l'
  run _plain "${output##*$'\033[?1049l'}"
  assert_output --partial "Saved to"
  # Nothing changed: the note is outside the full screen too.
  _keys ENTER
  run _egress_picker_tui ""
  assert_output --partial $'\033[?1049l'
  run _plain "${output##*$'\033[?1049l'}"
  assert_output --partial "Nothing to save."
}

@test "egress picker: a resize to a window too small runs the typed picker on the normal screen" {
  mkdir -p "$CLEAT_CONFIG_DIR"
  _rows_of 30
  _keys DOWN DOWN SPACE OTHER DOWN
  _egress_key() {
    _KEY="$(_read_keypress)"
    if [ "$_KEY" = OTHER ]; then _rows_of 15; _EG_WINCH=1; fi
  }
  run _egress_picker_tui "" <<< "q"
  local drawn="$output"
  run _plain "${drawn##*$'\033[?1049l'}"
  assert_output --partial "(typed, what every box may reach)"
  # The tick made on the full screen carried over.
  assert_output --regexp "\[✔\] github"
  run grep -c $'\033\\[?1049l' <<< "$drawn"
  assert_output "1"
}

@test "egress picker: a resize signal is measured at the next key" {
  mkdir -p "$CLEAT_CONFIG_DIR"
  _rows_of 30
  _keys DOWN WINCH DOWN QUIT
  _egress_key() {
    _KEY="$(_read_keypress)"
    if [ "$_KEY" = WINCH ]; then _rows_of 40; sh -c 'kill -WINCH $PPID'; _KEY=OTHER; fi
  }
  _egress_picker_tui "" > "$TEST_TEMP/frames"
  assert_equal "$_EG_ROWS" 40
}

@test "egress picker: an exit from inside the editor gives the terminal back, and the caller's exit trap" {
  # Strict mode can end the editor anywhere. The EXIT trap it sets restores
  # the screen, the cursor and echo, then runs the trap the caller had.
  run bash -c 'source "$1"; trap "echo CALLER-EXIT" EXIT; _egress_tui_enter >/dev/null; false' _ "$CLI"
  assert_failure
  assert_output --partial $'\033[?1049l'
  assert_output --partial "CALLER-EXIT"
  # A clean leave puts the caller's trap back as it was.
  run bash -c 'source "$1"; trap "echo CALLER-EXIT" EXIT; _egress_tui_enter >/dev/null; _egress_tui_leave >/dev/null; trap -p EXIT; trap - EXIT' _ "$CLI"
  assert_output --partial "echo CALLER-EXIT"
  refute_output --partial "_egress_tui_exit"
}

@test "egress picker: the config row's off door opens the editor under a refused capability, and a strict save from it is refused" {
  _EGRESS_ENFORCING=1
  _validated
  mkdir -p "$CLEAT_CONFIG_DIR" "$PROJECT"
  cd "$PROJECT"
  printf '[caps]\ndocker\n[egress]\nmode = strict\npack = npm\n' > "$CLEAT_GLOBAL_CONFIG"
  cp "$CLEAT_GLOBAL_CONFIG" "$TEST_TEMP/before"
  _egress_caged_boxes() { :; }
  _egress_have_tty() { return 0; }
  _rows_of 30
  # The ring back to strict and a pack ticked: the save is the writer's to
  # refuse, and nothing is written.
  _keys RIGHT DOWN DOWN SPACE ENTER OTHER QUIT
  run _egress_config_handoff off
  run _plain "$output"
  assert_output --partial "Egress control cannot be saved while the docker capability is on."
  assert_output --partial "Press any key to go back."
  run cmp "$CLEAT_GLOBAL_CONFIG" "$TEST_TEMP/before"
  assert_success
  # Off itself goes through.
  _keys ENTER
  run _egress_config_handoff off <<< "y"
  run _egress_section_canon "$CLEAT_GLOBAL_CONFIG"
  assert_output "mode = off
pack = npm"
}

@test "egress ring: a caged box's off save keeps the ticks the review showed" {
  status_caged
  _egress_on_terminal() { return 0; }
  cmd_run() { echo "cmd_run" >> "$DOCKER_CALLS"; }
  _egress_teardown() { return 0; }
  _account_wipe_run_dir() { :; }
  _egress_editor_load main
  _egress_toggle pack:npm
  _EGE_MODE=off
  run _egress_save_screen 1 <<< "y"
  assert_success
  run _egress_section_canon "$_EGRESS_BOXES_DIR/$CN"
  assert_output "mode = off
pack = npm"
}

@test "egress ring: done in the typed editor never answers the open for you" {
  status_caged
  _egress_on_terminal() { return 0; }
  mock_docker_inspect_field "$CN" '{{if .State.Running}}{{.State.StartedAt}}{{end}}' "2026-09-28T09:00:00Z"
  _egress_apply_mode() { return 0; }
  _egress_editor_load main
  _EGE_MODE=open
  run _egress_save_screen 1 <<< ""
  assert_failure
  assert_output --partial "Open egress for this box until it stops? [y/N]"
  run test -e "$_EGRESS_BOXES_DIR/$CN.session"
  assert_failure
}

@test "egress draw: no catalogue class word is drawn anywhere in the editor" {
  # The class words stay in cleat egress packs and --list. The editor says
  # the same in plain words (the maintainer's rule 5). Hundreds of frames, so
  # bats' own DEBUG trap is off, as in the cache test.
  trap - DEBUG
  mkdir -p "$CLEAT_CONFIG_DIR"
  printf '[egress]\nmode = strict\nallow = x.example.com\ndeny = api.github.com\n' > "$CLEAT_GLOBAL_CONFIG"
  _rows_of 60
  local box i out="" ix
  for box in "" main; do
    _egress_editor_load "$box"
    _egress_measure
    i=0
    while [ "$i" -lt "${#_EGR[@]}" ]; do
      out+="$(_egress_draw "$i")"
      i=$((i + 1))
    done
    for ix in "${_EGO[@]}"; do
      _egress_hosts_open "$ix"
      _EG_HCUR=0
      while [ "$_EG_HCUR" -lt "${#_EGH[@]}" ]; do
        out+="$(_egress_draw)"
        _EG_HCUR=$((_EG_HCUR + 1))
      done
      _EG_SCREEN=list
    done
  done
  # A review that adds one pack of every risk.
  _egress_editor_load ""
  _egress_toggle pack:pypi
  _egress_toggle pack:github-raw
  _egress_host_add unchecked.example.com
  out+="$(_egress_save_review 0 <<< "n" 2>&1 || true)"
  run _plain "$out"
  refute_output --regexp "contained|open tenancy|single origin|unaudited|[^a-z]shared"
}

@test "egress picker: the editor opens under a refused capability when what it loads is off" {
  # The refusal before the editor opens is for a save that would be refused.
  # A box whose own mode is off, or every box off, saves its lists freely:
  # only turning it on is refused, at the review.
  _EGRESS_ENFORCING=1
  _validated
  mkdir -p "$CLEAT_CONFIG_DIR" "$PROJECT" "$_EGRESS_BOXES_DIR"
  cd "$PROJECT"
  printf '[caps]\ndocker\n[egress]\nmode = strict\n' > "$CLEAT_GLOBAL_CONFIG"
  printf '[egress]\nmode = off\n' > "$_EGRESS_BOXES_DIR/$(_egress_target_cname main)"
  _set_box main
  _rows_of 30
  _keys QUIT
  run _egress_editor main
  assert_success
  assert_output --partial $'\033[?1049h'
  printf '[caps]\ndocker\n[egress]\nmode = off\n' > "$CLEAT_GLOBAL_CONFIG"
  _keys QUIT
  run _egress_editor ""
  assert_success
  assert_output --partial $'\033[?1049h'
  # With no policy anywhere the editor is for turning it on: refused.
  printf '[caps]\ndocker\n' > "$CLEAT_GLOBAL_CONFIG"
  run _egress_editor ""
  assert_failure
}

@test "egress save: leaving open for strict says what the box had" {
  mkdir -p "$CLEAT_CONFIG_DIR"
  printf '[egress]\nmode = open\npack = npm\n' > "$CLEAT_GLOBAL_CONFIG"
  _egress_editor_load ""
  _egress_mode_step -1
  run _egress_save_screen 0 <<< "n"
  run _plain "$output"
  assert_output --partial "Was any host, each one logged."
  refute_output --partial "Was no control"
}

@test "egress ui: a save with nothing to change after the config row turned egress on is no cancel" {
  mkdir -p "$CLEAT_CONFIG_DIR"
  _egress_have_tty() { return 0; }
  _rows_of 30
  _keys ENTER
  run _egress_config_handoff on
  run _plain "$output"
  assert_output --partial "Nothing to save."
  assert_output --partial "Egress control is on with the Claude Code hosts only."
  refute_output --partial "Cancelled."
}

# ── Pre-ticks in the editor (6.4) ────────────────────────────────────────────

@test "egress pretick: a setup section ticks apt-debian and names the exception" {
  _trusted_setup_project
  cd "$PROJECT"
  _egress_editor_load ""
  run _egress_is_ticked apt-debian
  assert_success
  run _egress_pack_note apt-debian
  assert_output "Ticked for [setup], Debian's one security source."
}

@test "egress pretick: an untrusted setup section suggests apt-debian and does not tick it" {
  printf '[setup]\necho hi\n' > "$PROJECT/.cleat"
  cd "$PROJECT"
  _egress_editor_load ""
  run _egress_is_ticked apt-debian
  assert_failure
  run _egress_pack_note apt-debian
  assert_output "Suggested: this project has a [setup] section."
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
  run _egress_pack_note github
  assert_output "Ticked for you: this project has a GitHub remote."
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
  : > "$PROJECT/package.json"
  cd "$PROJECT"
  _egress_editor_load ""
  run _egress_save_screen 1
  run _plain "$output"
  assert_output --partial "apt-debian and apt-image-extras were ticked for your trusted [setup]"
  assert_output --partial "section, a file the agent can edit."
  assert_output --partial "checked $(_egress_catalogue_records | awk -F'\t' '$1 == "apt-debian" { sub(/^.*, /, "", $5); print $5 }')."
  assert_output --partial "npm was ticked from files in this project too."
  assert_output --partial "! apt-debian also reaches other sites on the same server."
}

@test "egress save: answering no writes nothing" {
  mkdir -p "$CLEAT_CONFIG_DIR"
  _egress_editor_load ""
  run _egress_save_screen 0 <<< "n"
  assert_failure
  run test -e "$CLEAT_GLOBAL_CONFIG"
  assert_failure
}

@test "egress save: nothing changed saves nothing and says so" {
  mkdir -p "$CLEAT_CONFIG_DIR" "$_EGRESS_BOXES_DIR"
  printf '[egress]\nmode = strict\npack = npm\n' > "$CLEAT_GLOBAL_CONFIG"
  cp "$CLEAT_GLOBAL_CONFIG" "$TEST_TEMP/before"
  _egress_editor_load ""
  run _egress_save_screen 1
  assert_failure
  assert_output --partial "Nothing to save."
  run cmp "$CLEAT_GLOBAL_CONFIG" "$TEST_TEMP/before"
  assert_success
  # A box with no file of its own gets none for nothing.
  _egress_editor_load main
  run _egress_save_screen 1
  assert_output --partial "Nothing to save."
  run test -e "$_EGE_FILE"
  assert_failure
}

@test "egress save: a box editor writes the box's own file with no mode of its own" {
  mkdir -p "$CLEAT_CONFIG_DIR"
  printf '[egress]\nmode = strict\n' > "$CLEAT_GLOBAL_CONFIG"
  cd "$PROJECT"
  _set_box main
  _egress_editor_load main
  _egress_host_add extra.example
  run _egress_save_screen 1
  assert_success
  run cat "$_EGE_FILE"
  assert_output "[egress]
allow = extra.example"
  run cat "$CLEAT_GLOBAL_CONFIG"
  assert_output "[egress]
mode = strict"
}

@test "egress save: a deny the editor loaded survives its save" {
  mkdir -p "$CLEAT_CONFIG_DIR"
  printf '[egress]\nmode = strict\npack = github\ndeny = api.github.com\n' > "$CLEAT_GLOBAL_CONFIG"
  _egress_editor_load ""
  _egress_toggle pack:npm
  run _egress_save_screen 1
  assert_success
  run _egress_section_canon "$CLEAT_GLOBAL_CONFIG"
  assert_output "mode = strict
pack = github
pack = npm
deny = api.github.com"
}

@test "egress save: a successful save moves the baseline" {
  mkdir -p "$CLEAT_CONFIG_DIR"
  printf '[egress]\nmode = strict\n' > "$CLEAT_GLOBAL_CONFIG"
  _egress_editor_load ""
  _egress_toggle pack:npm
  _egress_save_screen 1 >/dev/null
  # A second save from the same editor is not taken for another terminal's.
  _egress_toggle pack:go
  run _egress_save_screen 1
  assert_success
  refute_output --partial "changed in another terminal"
  run _egress_section_canon "$CLEAT_GLOBAL_CONFIG"
  assert_output "mode = strict
pack = go
pack = npm"
}

@test "egress save: the writer refuses inherit for the global config, and so does the typed picker" {
  mkdir -p "$CLEAT_CONFIG_DIR"
  run _write_egress_to_file "$CLEAT_GLOBAL_CONFIG" inherit "npm" "" ""
  assert_failure
  assert_output --partial "Refusing to write an egress policy without a mode"
  run test -e "$CLEAT_GLOBAL_CONFIG"
  assert_failure
  run _egress_picker_text "" <<< $'mode inherit\nq'
  assert_output --partial "Only a box can inherit."
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

@test "egress typed picker: -name drops a pack or a host" {
  mkdir -p "$CLEAT_CONFIG_DIR"
  printf '[egress]\nmode = strict\npack = npm\npack = go\nallow = docs.rs\n' > "$CLEAT_GLOBAL_CONFIG"
  run _egress_picker_text "" <<< $'-npm\n-docs.rs\ndone'
  assert_success
  run _egress_section_canon "$CLEAT_GLOBAL_CONFIG"
  assert_output "mode = strict
pack = go"
}

@test "egress ring: landing on open in the global editor does not write mode open" {
  mkdir -p "$CLEAT_CONFIG_DIR"
  run _egress_picker_text "" <<< $'mode open\ndone'
  assert_output --partial "Open is per box and per session"
  run _egress_section_canon "$CLEAT_GLOBAL_CONFIG"
  assert_output "mode = strict"
  # The drawn ring: open says it is set per box, and a save keeps the mode
  # the editor loaded.
  _egress_editor_load ""
  _egress_toggle pack:npm
  _egress_mode_step 1
  run echo "$_EGE_MODE"
  assert_output "open"
  run _egress_pane_text mode
  assert_output --partial "cleat egress open <box>"
  assert_output --partial "Saving here keeps mode strict."
  run _egress_save_screen 1
  assert_success
  run _egress_section_canon "$CLEAT_GLOBAL_CONFIG"
  assert_output "mode = strict
pack = npm"
}

@test "egress ring: a box's own off asks and writes nothing on a default answer" {
  # A box file turned off for a box that is not caged (none exists yet) has no
  # recreate to run, so the save asks here, and Enter means no.
  mkdir -p "$CLEAT_CONFIG_DIR"
  printf '[egress]\nmode = strict\npack = npm\n' > "$CLEAT_GLOBAL_CONFIG"
  _egress_editor_load main
  _EGE_MODE=off
  run _egress_save_screen 1 <<< ""
  assert_failure
  assert_output --partial "Turn it off? [y/N]"
  run test -e "$_EGE_FILE"
  assert_failure
  run _egress_save_screen 1 <<< "y"
  assert_success
  run _egress_section_canon "$_EGE_FILE"
  assert_output --partial "mode = off"
}

@test "egress ring: landing on off does not write a policy on a default answer" {
  mkdir -p "$CLEAT_CONFIG_DIR"
  printf '[egress]\nmode = strict\npack = npm\n' > "$CLEAT_GLOBAL_CONFIG"
  _egress_editor_load ""
  _egress_mode_step -1
  run echo "$_EGE_MODE"
  assert_output "off"
  # Enter, even from the typed form's done, never turns it off. Under live
  # enforcement the question is the global off confirmation of 6.6.
  run _egress_save_screen 1 <<< ""
  assert_failure
  assert_output --partial "Turn egress control off for every new box? [y/N]"
  refute_output --partial "Allowed"
  run _egress_section_canon "$CLEAT_GLOBAL_CONFIG"
  assert_output "mode = strict
pack = npm"
  # And nothing claims Saved before the answer.
  run _egress_save_screen 1 <<< "n"
  refute_output --partial "Saved"
  run _egress_save_screen 1 <<< "y"
  assert_success
  run _egress_section_canon "$CLEAT_GLOBAL_CONFIG"
  assert_output "mode = off
pack = npm"
}

@test "egress ring: an off save keeps the ticks the review showed" {
  mkdir -p "$CLEAT_CONFIG_DIR"
  printf '[egress]\nmode = strict\npack = npm\n' > "$CLEAT_GLOBAL_CONFIG"
  _egress_editor_load ""
  _egress_toggle pack:go
  _egress_host_add docs.rs
  _EGE_MODE=off
  run _egress_save_screen 1 <<< "y"
  assert_success
  run _egress_section_canon "$CLEAT_GLOBAL_CONFIG"
  assert_output "mode = off
pack = go
pack = npm
allow = docs.rs"
}

@test "egress typed picker: q and end of input save nothing" {
  mkdir -p "$CLEAT_CONFIG_DIR"
  run _egress_picker_text "" <<< $'npm\nq'
  assert_success
  run test -e "$CLEAT_GLOBAL_CONFIG"
  assert_failure
  _EGE_FILE=""
  run _egress_picker_text "" <<< $'npm'
  assert_success
  run test -e "$CLEAT_GLOBAL_CONFIG"
  assert_failure
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

@test "egress status: the auth mount is enumerated as an uncovered channel" {
  mkdir -p "$CLEAT_CONFIG_DIR"
  printf '[egress]\nmode = strict\n' > "$CLEAT_GLOBAL_CONFIG"
  run cmd_egress status
  assert_output --partial "/home/coder/.cleat-auth"
  assert_output --partial "refresh token"
  # And with no policy at all: the channels print in every state.
  rm -f "$CLEAT_GLOBAL_CONFIG"
  run cmd_egress status
  assert_output --partial "Not covered by egress policy"
  assert_output --partial "/home/coder/.cleat-auth"
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
  [[ " $_EGRESS_SNI_SUBCODES " != *" handshake-flood "* ]] || fail "handshake-flood is listed as an sni subcode"
  [[ " $_EGRESS_REASON_CODES " == *" handshake-flood "* ]] || fail "handshake-flood is not a reason code"
  # Exactly the three security codes, and no other code is one.
  local c
  # One run per code: a command negated with ! never stops a test, so a loop
  # of them would check only the last code.
  local c n=0
  for c in $_EGRESS_REASON_CODES; do
    run _egress_log_is_security_code "$c"
    case "$c" in
      sni|handshake-flood|address) assert_success ;;
      *) assert_failure ;;
    esac
    n=$((n + 1))
  done
  assert_equal "$n" 7
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
  trap - DEBUG
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
  _egress_measure
  _egress_toggle pack:npm
  out+="$(_egress_save_screen 1 2>&1)"
  out+="$(_egress_draw 0 2>&1)"
  _EGE_MODE=open
  out+="$(_egress_pane_text mode 2>&1)"
  _egress_editor_load main
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
  _egress_measure
  run _egress_draw 0
  assert_success
  run _plain "$output"
  assert_output --partial "! A caged box will not start on this engine: Docker Engine"
  run _egress_save_screen 1
  assert_success
  run _plain "$output"
  assert_output --partial "Saved. Boxes on this machine will refuse to start until you switch engine or run"
  assert_output --partial "cleat egress off"
  # A validated engine needs no line, and the list gets the row back.
  _egress_engine_kind() { printf desktop-macos; }
  _egress_editor_load ""
  _egress_measure
  run _plain "$(_egress_draw 0)"
  refute_output --partial "A caged box will not start"
  refute_output --partial "Docker is not running"
  assert_equal "$_EG_E" 0
}

# ── cleat egress status (9.3) ───────────────────────────────────────────────

# A caged box, running, with a healthy gateway, as status reads it: its
# inspect fields, the gateway's admin answers and its ps status line.
status_caged() {
  _EGRESS_ENFORCING=1
  _daemon_up() { return 0; }
  _egress_engine_kind() { printf desktop-macos; }
  mkdir -p "$CLEAT_CONFIG_DIR" "$PROJECT"
  printf '[egress]\nmode = strict\npack = pypi\n' > "$CLEAT_GLOBAL_CONFIG"
  cd "$PROJECT"
  CN="$(container_name_for "$PROJECT" main)"
  egress_box_names
  use_gw_admin_stub
  caged_box
  container_exists() { return 0; }
  is_running() { return 0; }
  mock_docker_inspect_field "$GW" '{{.RestartCount}}|{{.State.OOMKilled}}|{{.Config.Image}}' "0|false|$_GATEWAY_IMAGE"
  mock_docker_inspect_field "$GW" '{{.RestartCount}}|{{.State.OOMKilled}}' "3|true"
  mock_docker_ps_filter "Up 4 hours (healthy)" "name=^${GW}$"
  mock_gw_admin counts "ok counts 1284 3"
  mock_gw_admin path_ok "ok path_ok true"
  mkdir -p "$DOCKER_MOCK_DIR/gwadmin"
}
plain_status() { run cmd_egress status; run _plain "$output"; }

@test "egress status: a caged box shows its gateway, relay, policy and counters" {
  status_caged
  plain_status
  assert_output --partial "● Gateway healthy       $GW   up 4 hours   0 restarts"
  assert_output --partial "● Shim listening        127.0.0.1:3128 inside the box   last seen 3s ago"
  assert_output --partial "Mode:      strict  ·  live, read from the gateway"
  assert_output --partial "Box:       $CN   network=none  cap-drop=NET_RAW  verified"
  assert_output --partial "Socket:    $VOL   /run/cleat-egress/proxy.sock   ro in box"
  assert_output --partial "Session:   1,284 allowed · 3 denied    cleat egress log"
  assert_output --partial "Not covered by egress policy"
  assert_output --partial "run on the host, outside this"
  # Read host-side only: never a command in the box.
  run grep -c "^docker exec $CN\b\|^docker exec -[a-z]* [^ ]* $CN " "$DOCKER_CALLS"
  assert_output "0"
}

@test "egress status: status counts hosts from the resolved set and not from a literal" {
  status_caged
  _egress_resolve "$CN"
  local n
  n="$(printf '%s\n' "$_EG_HOSTS" | grep -c .)"
  plain_status
  assert_output --partial "Allowed:   $n hosts, port 443 only"
  printf '[egress]\nmode = strict\npack = pypi\nallow = docs.example.test\n' > "$CLEAT_GLOBAL_CONFIG"
  plain_status
  assert_output --partial "Allowed:   $(( n + 1 )) hosts, port 443 only"
  assert_output --partial "Pinned:    docs.example.test"
}

@test "egress status: the allowed count comes from the counters and not from the log" {
  status_caged
  mock_gw_admin counts "ok counts 7 0"
  mkdir -p "$DOCKER_MOCK_DIR/cp/$GW"
  printf '2026-09-26T10:00:00Z code=policy sub=- origin=box host=x.example port=443 trunc=0\n' > "$DOCKER_MOCK_DIR/cp/$GW/denials.log"
  plain_status
  assert_output --partial "Session:   7 allowed · 0 denied"
}

@test "egress status: a gateway enforcing a stale policy names reload and never rm" {
  status_caged
  mock_gw_admin policy-digest "ok policy-digest v1:0000000000000000"
  plain_status
  assert_output --partial "The gateway enforces a different policy: cleat egress reload"
  refute_output --partial "cleat rm"
}

@test "egress status: each gateway state has its own row, and every anomaly says it is not a policy denial" {
  status_caged
  gw_row() { run _egress_status_gateway_row "$CN" "$GW" "$1"; run _plain "$output"; }
  gw_row missing
  assert_output --partial "x Gateway missing       no gateway container for this box"
  assert_output --partial "This is not a policy denial."
  assert_output --partial "Fix:  cleat egress restart"
  gw_row displaced
  assert_output --partial "x Gateway displaced"
  assert_output --partial "This is not a policy denial."
  gw_row stopped
  assert_output --partial "x Gateway stopped       exited, 3 restarts, out of memory"
  assert_output --partial "This is not a policy denial."
  assert_output --partial "should not run out of memory"
  is_running() { return 1; }
  gw_row stopped
  assert_output --partial "○ Gateway stopped       its box is stopped too"
  assert_output --partial "Fix:  cleat start"
  gw_row orphaned
  assert_output --partial "! Gateway orphaned"
  assert_output --partial "Not a policy denial."
  # A gateway from an older pin says so and names the one remedy.
  is_running() { return 0; }
  rm -rf "$DOCKER_MOCK_DIR/inspect"
  caged_box
  mock_docker_inspect_field "$GW" '{{.RestartCount}}|{{.State.OOMKilled}}|{{.Config.Image}}' "0|false|ghcr.io/cleatdev/cleat-gw@sha256:old"
  gw_row healthy
  assert_output --partial "superseded by this cleat: cleat egress restart"
}

@test "egress status: status on a box with no policy names both ways to turn it on" {
  mkdir -p "$CLEAT_CONFIG_DIR"
  rm -f "$CLEAT_GLOBAL_CONFIG"
  plain_status
  assert_output --partial "○ Egress control is off for this box"
  assert_output --partial "Turn it on:   cleat egress      the editor"
  assert_output --partial "cleat config      the Egress row"
}

@test "egress status: status on a box with no policy runs no engine probe" {
  _EGRESS_ENFORCING=1
  mkdir -p "$CLEAT_CONFIG_DIR"
  rm -f "$CLEAT_GLOBAL_CONFIG"
  _egress_info_probe() { echo probed >> "$TEST_TEMP/probed"; }
  _egress_version_probe() { echo probed >> "$TEST_TEMP/probed"; }
  run cmd_egress status
  assert_success
  [ ! -e "$TEST_TEMP/probed" ]
  run grep -c "^docker info" "$DOCKER_CALLS"
  assert_output "0"
}

@test "egress status: the hooks escape prints a claim void row in status" {
  status_caged
  rm -rf "$DOCKER_MOCK_DIR/inspect"
  F_HOOKS=1 caged_box
  plain_status
  assert_output --partial "! The claim is void for this box   CLEAT_EGRESS_ALLOW_HOOKS=1 was set at create time"
  assert_output --partial "Drop the flag and recreate to restore it:  cleat rm && cleat"
  # With the box's own egress file, the recreate goes through a launch.
  mkdir -p "$_EGRESS_BOXES_DIR"
  printf '[egress]\nallow = docs.example.test\n' > "$_EGRESS_BOXES_DIR/$CN"
  plain_status
  assert_output --partial "Drop the flag and recreate to restore it:  cleat start on a terminal, then accept the recreate"
}

@test "egress status: a box without the hooks escape prints no claim void row" {
  status_caged
  plain_status
  refute_output --partial "claim is void"
  refute_output --partial "Claim cannot be verified"
}

@test "egress status: status on a box created under an older gateway spec says the claim cannot be verified" {
  status_caged
  rm -rf "$DOCKER_MOCK_DIR/inspect"
  F_HOOKS=1 caged_box
  _GATEWAY_SPEC_VERSION=$(( _GATEWAY_SPEC_VERSION + 1 ))
  plain_status
  assert_output --partial "! Claim cannot be verified    this box was created by an older cleat"
  refute_output --partial "claim is void"
}

@test "egress status: open mode status never uses the word allowlist and names the log, not a boundary" {
  status_caged
  printf '[egress]\nmode = open\n' > "$CLEAT_GLOBAL_CONFIG"
  mock_gw_admin policy-digest "ok policy-digest $(current_digest)"
  plain_status
  assert_output --partial "! Open egress: every TLS host is allowed and every destination is logged."
  assert_output --partial "This is a log, not a boundary."
  refute_output --partial "allowlist"
}

@test "egress status: status exits 0 on a refused engine, with the gateway down and with Docker down" {
  status_caged
  _egress_engine_kind() { printf engine-linux; }
  plain_status
  assert_success
  assert_output --partial "x Egress control is not available on Docker Engine on Linux (rootful)"
  assert_output --partial "cleat egress off"
  refute_output --partial "Gateway healthy"
  _egress_engine_kind() { printf desktop-macos; }
  container_exists() { [ "$1" != "$GW" ]; }
  plain_status
  assert_success
  assert_output --partial "x Gateway missing"
  _daemon_up() { return 1; }
  plain_status
  assert_success
  assert_output --partial "○ Docker is not running, so the gateway cannot be asked."
}

@test "egress status: a label with no policy, and a policy with no label, name their remedies" {
  status_caged
  rm -f "$CLEAT_GLOBAL_CONFIG"
  plain_status
  assert_output --partial "x Box main was created under an egress policy that no longer resolves."
  assert_output --partial "Fix:  cleat egress off"
  printf '[egress]\nmode = strict\n' > "$CLEAT_GLOBAL_CONFIG"
  rm -rf "$DOCKER_MOCK_DIR/inspect"
  F_HASH="" caged_box
  plain_status
  assert_output --partial "x This box was created without egress control"
  assert_output --partial "cleat rm && cleat"
  container_exists() { return 1; }
  plain_status
  assert_output --partial "○ No box yet. Its gateway is created with it on the next launch."
}

@test "egress status: a volume holding a third name is flagged, a silent gateway is not" {
  status_caged
  plain_status
  refute_output --partial "holds something besides"
  printf 'denials.log\nproxy.sock\npolicy.json\n' > "$DOCKER_MOCK_DIR/gwadmin/manifest"
  plain_status
  assert_output --partial "! The socket volume holds something besides the socket and the denial log."
  : > "$DOCKER_MOCK_DIR/gwadmin/manifest"
  plain_status
  refute_output --partial "holds something besides"
}

@test "egress status: the cleat status egress row reads off with no policy and runs no probe" {
  _EGRESS_ENFORCING=1
  mkdir -p "$CLEAT_CONFIG_DIR" "$PROJECT"
  rm -f "$CLEAT_GLOBAL_CONFIG"
  _egress_info_probe() { echo probed >> "$TEST_TEMP/probed"; }
  run _egress_status_summary_row "cleat-proj-00000000"
  run _plain "$output"
  assert_output "  Egress:    off  ·  full network egress"
  [ ! -e "$TEST_TEMP/probed" ]
  run grep -c "^docker" "$DOCKER_CALLS"
  assert_output "0"
  # cleat status itself carries the row.
  run cmd_status "$PROJECT"
  run _plain "$output"
  assert_output --partial "Egress:    off  ·  full network egress"
  [ ! -e "$TEST_TEMP/probed" ]
}

@test "egress status: the cleat status egress row says an open box is a log, not a boundary" {
  mkdir -p "$CLEAT_CONFIG_DIR"
  printf '[egress]\nmode = open\n' > "$CLEAT_GLOBAL_CONFIG"
  run _egress_status_summary_row "cleat-proj-00000000"
  run _plain "$output"
  assert_output --partial "open  ·  every TLS host allowed and logged, a log, not a boundary"
  printf '[egress]\nmode = strict\n' > "$CLEAT_GLOBAL_CONFIG"
  run _egress_status_summary_row "cleat-proj-00000000"
  run _plain "$output"
  assert_output "  Egress:    strict  ·  5 hosts, 1 pack"
  # A policy that does not parse leaves the status screen standing.
  printf '[egress]\nmode = strict\ndeny =\n' > "$CLEAT_GLOBAL_CONFIG"
  run _egress_status_summary_row "cleat-proj-00000000"
  assert_success
  run _plain "$output"
  assert_output --partial "the policy does not parse"
}

@test "egress status: the cleat status egress row names a gateway that is not serving" {
  status_caged
  container_exists() { [ "$1" != "$GW" ]; }
  run _egress_status_summary_row "$CN"
  run _plain "$output"
  assert_output --partial "! gateway missing. This is not a policy denial."
}

# ── cleat egress why, log and test (6.2, 9.3) ───────────────────────────────

# A caged box with a gateway whose denial log holds <rows>, as docker cp copies
# it out, with a saved mark at the start of the log.
why_box() {                              # <rows>
  status_caged
  mkdir -p "$DOCKER_MOCK_DIR/cp/$GW" "$CLEAT_RUN_DIR/$CN/egress"
  printf '%b' "${1:-}" > "$DOCKER_MOCK_DIR/cp/$GW/denials.log"
  printf '1:0\n' > "$CLEAT_RUN_DIR/$CN/egress/denials-mark"
  mock_gw_admin log-state "ok log-state 1 0"
}
plain() { run _plain "$output"; }

@test "egress why: an argument the host validator rejects is read as a package name" {
  why_box
  run cmd_egress why left-pad
  assert_success
  plain
  assert_output --partial "? left-pad is not a hostname, so this reads as a package name."
  assert_output --partial "npm    registry.npmjs.org"
  refute_output --partial "Denied"
  refute_output --partial "Allowed"
}

@test "egress why: a name that is both a host and a package prints both answers" {
  why_box
  run cmd_egress why zope.interface
  assert_success
  plain
  assert_output --partial "x Denied   zope.interface:443"
  assert_output --partial "? zope.interface is also a package name."
  # A host the catalogue ships is a host only.
  run cmd_egress why download.docker.com
  plain
  refute_output --partial "package name"
}

@test "egress why: the package answer reads the denial window and dials nothing" {
  why_box '2026-09-26T10:00:00Z code=policy sub=- origin=box host=registry.npmjs.org port=443 trunc=0\n'
  local real
  real="$(declare -f _egress_denials_window)"
  eval "${real/_egress_denials_window/_egress_denials_window_real}"
  _egress_denials_window() { echo x >> "$TEST_TEMP/windows"; _egress_denials_window_real "$@"; }
  mkdir -p "$TEST_TEMP/bin"
  printf '#!/bin/sh\necho dialled >> "%s/dialled"\n' "$TEST_TEMP" > "$TEST_TEMP/bin/curl"
  chmod +x "$TEST_TEMP/bin/curl"
  PATH="$TEST_TEMP/bin:$PATH" run cmd_egress why left-pad
  assert_success
  plain
  assert_output --partial "1 denials this session"
  run wc -l < "$TEST_TEMP/windows"
  [ "$(printf '%s' "$output" | tr -d ' ')" = 1 ]
  [ ! -e "$TEST_TEMP/dialled" ]
  run grep -c "^docker run" "$DOCKER_CALLS"
  assert_output "0"
  # The installer with denials sorts first.
  run cmd_egress why left-pad
  plain
  run bash -c 'printf "%s\n" "$1" | grep -m1 -E "^    [a-z]+ +[a-z]"' _ "$output"
  assert_output --partial "npm"
}

@test "egress why: an allowed host names its pack, and the core pack is always on" {
  why_box
  run cmd_egress why pypi.org
  plain
  assert_output --partial "v Allowed  pypi.org:443"
  assert_output --partial "via pack  pypi   2 hosts, shared"
  run cmd_egress why api.anthropic.com
  plain
  assert_output --partial "via the core pack claude, always on"
}

@test "egress why: a host in a shared pack gives the command under a caution" {
  why_box
  run cmd_egress why deb.debian.org
  plain
  assert_output --partial "! Allowing apt-debian lets the box reach any tenant behind that terminator"
  assert_output --partial "Allow anyway:     cleat egress allow apt-debian"
  run cmd_egress why github.com
  plain
  assert_output --partial "Allow it:         cleat egress allow github"
  refute_output --partial "Allow anyway"
}

@test "egress why: port 80 is never allowable" {
  why_box
  run cmd_egress why deb.debian.org:80
  plain
  assert_output --partial "x Denied   deb.debian.org:80"
  assert_output --partial "Cleat never allows port 80 in any mode."
  assert_output --partial "apt reaches the same mirror over https"
  refute_output --partial "cleat egress allow"
  run cmd_egress why example.test:8443
  plain
  assert_output --partial "Only port 443 is allowed, in every mode."
}

@test "egress why: a refused handshake is never offered as an allow" {
  why_box '2026-09-26T10:00:05Z code=sni sub=sni-mismatch origin=box host=paste.example port=443 trunc=0\n2026-09-26T10:00:06Z code=address sub=- origin=box host=metadata.example port=443 trunc=0\n'
  run cmd_egress why paste.example
  plain
  assert_output --partial "x Refused  paste.example:443"
  assert_output --partial "not a policy denial"
  assert_output --partial "Your policy did not cause this."
  assert_output --partial "cleat egress log --refused"
  refute_output --partial "cleat egress allow paste.example"
  refute_output --partial "Allow it:"
  refute_output --partial "Allow anyway:"
  run cmd_egress why metadata.example
  plain
  assert_output --partial "private, loopback or link-local"
  refute_output --partial "cleat egress allow metadata.example"
  refute_output --partial "Allow it:"
}

@test "egress why: works with the gateway stopped and with Docker down" {
  why_box '2026-09-26T10:00:00Z code=policy sub=- origin=box host=x.example port=443 trunc=0\n'
  container_exists() { [ "$1" != "$GW" ]; }
  run cmd_egress why x.example
  assert_success
  plain
  assert_output --partial "x Denied   x.example:443"
  assert_output --partial "The gateway is not serving right now (missing). This is not a policy denial."
  _daemon_up() { return 1; }
  run cmd_egress why x.example
  assert_success
  plain
  assert_output --partial "x Denied   x.example:443"
  refute_output --partial "Seen "
}

@test "egress log: --refused shows the three security codes and no policy rows" {
  why_box '2026-09-26T10:00:00Z code=policy sub=- origin=box host=a.example port=443 trunc=0\n2026-09-26T10:00:01Z code=port sub=- origin=box host=b.example port=80 trunc=0\n2026-09-26T10:00:02Z code=sni sub=sni-mismatch origin=box host=c.example port=443 trunc=0\n2026-09-26T10:00:03Z code=handshake-flood sub=- origin=box host=d.example port=443 trunc=0\n2026-09-26T10:00:04Z code=address sub=- origin=box host=e.example port=443 trunc=0\n'
  mkdir -p "$DOCKER_MOCK_DIR/logs"
  printf '2026-09-26T10:00:00Z allow host=pypi.org port=443 trunc=0\n' > "$DOCKER_MOCK_DIR/logs/$GW"
  run cmd_egress log --refused
  assert_success
  plain
  assert_output --partial "x refused   c.example:443   sni sni-mismatch"
  assert_output --partial "x refused   d.example:443   handshake-flood"
  assert_output --partial "x refused   e.example:443   address"
  refute_output --partial "a.example"
  refute_output --partial "b.example"
  refute_output --partial "allowed"
}

@test "egress log: plain log shows allowed and denied rows in time order" {
  why_box '2026-09-26T10:00:02Z code=policy sub=- origin=box host=a.example port=443 trunc=0\n2026-09-26T10:00:04Z code=port sub=- origin=box host=b.example port=80 trunc=1\n'
  mkdir -p "$DOCKER_MOCK_DIR/logs"
  printf '2026-09-26T10:00:03Z allow host=pypi.org port=443 trunc=0\n2026-09-26T10:00:01Z allow host=api.anthropic.com port=443 trunc=0\n' > "$DOCKER_MOCK_DIR/logs/$GW"
  run cmd_egress log
  assert_success
  plain
  run bash -c 'printf "%s\n" "$1" | grep -E "^  2026" | awk "{print \$1, \$3, \$4}"' _ "$output"
  assert_output "2026-09-26T10:00:01Z allowed api.anthropic.com:443
2026-09-26T10:00:02Z denied a.example:443
2026-09-26T10:00:03Z allowed pypi.org:443
2026-09-26T10:00:04Z denied b.example:80"
  run cmd_egress log
  plain
  assert_output --partial "b.example:80   not port 443, which is never allowed in any mode   (cut or altered)"
  assert_output --partial "4 rows."
}

@test "egress log: works with the gateway stopped" {
  why_box '2026-09-26T10:00:02Z code=policy sub=- origin=box host=a.example port=443 trunc=0\n'
  is_running() { [ "$1" = "$CN" ]; }
  run cmd_egress log
  assert_success
  plain
  assert_output --partial "x denied    a.example:443"
}

@test "egress log: a down daemon is a daemon error, and a missing gateway says so" {
  why_box
  _daemon_up() { return 1; }
  run cmd_egress log
  assert_failure
  plain
  assert_output --partial "Docker is not running, so the gateway's log cannot be read."
  refute_output --partial "Egress refused"
  _daemon_up() { return 0; }
  container_exists() { [ "$1" != "$GW" ]; }
  run cmd_egress log
  assert_failure
  plain
  assert_output --partial "x Gateway missing"
  # No policy and no label: nothing is logged, and that is not an error.
  rm -f "$CLEAT_GLOBAL_CONFIG"
  rm -rf "$DOCKER_MOCK_DIR/inspect"
  run cmd_egress log
  assert_success
  plain
  assert_output --partial "Egress control is off for box main, so nothing is logged."
}

@test "egress log: an allowed connection is never written to the shared volume" {
  # An allow is the gateway's stdout. A line shaped like one in the denial
  # copy is not a denial row, and nothing renders it as one.
  why_box '2026-09-26T10:00:00Z allow host=pypi.org port=443 trunc=0\n'
  _egress_denials_copy "$CN"
  run _egress_denials_rows "$CLEAT_RUN_DIR/$CN/egress/denials.log" 0
  assert_output ""
}

@test "egress test: asks the gateway matcher and prints the pack beside the verdict" {
  why_box
  mock_gw_admin match "ok match allow"
  run cmd_egress test pypi.org
  assert_success
  plain
  assert_output --partial "v allow   pypi.org:443   the gateway's matcher, box main"
  assert_output --partial "via pack pypi (shared)"
  run grep -c "^docker exec $GW /usr/local/bin/gw-admin match pypi.org" "$DOCKER_CALLS"
  assert_output "1"
  mock_gw_admin match "ok match deny policy"
  run cmd_egress test github.com
  assert_failure
  plain
  assert_output --partial "x deny    github.com:443"
  assert_output --partial "Allow it:  cleat egress allow github"
}

@test "egress test: an invalid host refuses before any admin call" {
  why_box
  : > "$DOCKER_CALLS"
  run cmd_egress test 'bad_host!'
  assert_failure
  run grep -c "gw-admin" "$DOCKER_CALLS"
  assert_output "0"
}

@test "egress test: a gateway that is not healthy says it is not a policy denial" {
  why_box
  container_exists() { [ "$1" != "$GW" ]; }
  run cmd_egress test pypi.org
  assert_failure
  plain
  assert_output --partial "This is not a policy denial."
  run grep -c "gw-admin match" "$DOCKER_CALLS"
  assert_output "0"
}

@test "egress test: a saved allow the gateway denies names reload" {
  why_box
  mock_gw_admin match "ok match deny policy"
  run cmd_egress test pypi.org
  assert_failure
  plain
  assert_output --partial "The saved policy says allow. The gateway enforces a different policy:  cleat egress reload"
}

@test "egress test: off says every host is reachable and exits 0" {
  mkdir -p "$CLEAT_CONFIG_DIR"
  rm -f "$CLEAT_GLOBAL_CONFIG"
  run cmd_egress test pypi.org
  assert_success
  plain
  assert_output --partial "every host is reachable and nothing checks it"
}

@test "egress save: under enforcement the final line names what the save does" {
  status_caged
  _egress_editor_engine() { _EGE_ENGINE=desktop-macos; }
  # A running caged box: the global save reaches it now.
  mock_docker_ps_filter "$CN" "label=sh.cleat.egress-hash"
  _egress_editor_load ""
  # A change to the file that leaves the resolved policy as the gateway has it.
  _egress_host_add pypi.org
  run _egress_save_screen 1
  run _plain "$output"
  assert_output --partial "Applied to $CN: its gateway reloaded."
  assert_output --partial "Applies immediately. No restart, no rebuild."
  # No box running: the next box takes it.
  mock_docker_ps_filter "" "label=sh.cleat.egress-hash"
  _egress_editor_load ""
  _egress_host_add files.pythonhosted.org
  run _egress_save_screen 1
  run _plain "$output"
  assert_output --partial "Applies to the next box you start."
  refute_output --partial "recreates"
  refute_output --partial "Enforcement lands"
}

@test "egress save: a first global policy names every box that will refuse" {
  _EGRESS_ENFORCING=1
  _daemon_up() { return 0; }
  _egress_engine_kind() { printf desktop-macos; }
  _egress_editor_engine() { _EGE_ENGINE=desktop-macos; }
  mkdir -p "$CLEAT_CONFIG_DIR"
  printf 'cleat-a-11111111\ncleat-b-22222222\ncleat-c-33333333\ncleat-gw-0123456789ab\n' > "$DOCKER_MOCK_DIR/ps_a_output"
  local fmt='{{range $k, $v := .Config.Labels}}{{if eq $k "sh.cleat.role"}}ROLE={{$v}}{{end}}{{end}}|{{range $k, $v := .Config.Labels}}{{if eq $k "sh.cleat.egress-hash"}}HASH{{end}}{{end}}|{{range .Mounts}}{{if eq .Destination "/workspace"}}{{.Source}}{{end}}{{end}}|{{index .Config.Labels "sh.cleat.box"}}'
  mock_docker_inspect_field cleat-a-11111111 "$fmt" "||/work/a|main"
  # A named box's row names that box, whatever box this verb is for.
  mock_docker_inspect_field cleat-b-22222222 "$fmt" "||/work/b|api"
  # A box already caged, and a gateway, are not in the list.
  mock_docker_inspect_field cleat-c-33333333 "$fmt" "|HASH|/work/c|main"
  mock_docker_inspect_field cleat-gw-0123456789ab "$fmt" "ROLE=gateway|||"
  _egress_editor_load ""
  run _egress_save_screen 1
  run _plain "$output"
  assert_output --partial "2 boxes were created without egress control. Each refuses to start"
  assert_output --partial "cleat-a-11111111   cleat rm && cleat   /work/a"
  assert_output --partial "cleat-b-22222222   cleat rm api && cleat start api   /work/b"
  refute_output --partial "cleat-c-33333333"
  refute_output --partial "cleat-gw-0123456789ab"
  refute_output --partial "Applies"
}

@test "egress writer: a policy write refuses a box with the ssh capability and names the way out" {
  _EGRESS_ENFORCING=1
  mkdir -p "$CLEAT_CONFIG_DIR" "$PROJECT"
  cd "$PROJECT"
  printf '[caps]\nssh\n' > "$CLEAT_GLOBAL_CONFIG"
  run cmd_egress allow docs.example.test
  assert_failure
  run _plain "$output"
  assert_output --partial "Egress control cannot be saved while the ssh capability is on."
  assert_output --partial "ssh mounts your SSH agent"
  assert_output --partial "It is on in your global config. Turn it off:  cleat config --disable ssh"
  # Nothing was written.
  run _egress_section_canon "$CLEAT_GLOBAL_CONFIG"
  assert_output ""
  # No policy result, no refusal: a deny that leaves egress off is fine.
  _EGRESS_ENFORCING=0
  run cmd_egress allow docs.example.test
  assert_success
}

@test "egress ring: open in the box editor writes the session marker and not the per-box file" {
  status_caged
  _egress_on_terminal() { return 0; }
  mock_docker_inspect_field "$CN" '{{if .State.Running}}{{.State.StartedAt}}{{end}}' "2026-09-28T09:00:00Z"
  # The reload itself is the apply-mode tests'. Here: what the ring writes.
  _egress_apply_mode() { echo "apply $1 $2" >> "$TEST_TEMP/applied"; return 0; }
  _egress_editor_load main
  _EGE_MODE=open
  run _egress_save_screen 0 <<< $'y\ny'
  run _plain "$output"
  assert_output --partial "Open for this session only. See below."
  assert_output --partial "! Open egress, this session only"
  [ -f "$_EGRESS_BOXES_DIR/$CN.session" ]
  run cat "$TEST_TEMP/applied"
  assert_output "apply $CN open"
  # With no edits there is no file of its own to write, and none is made.
  run test -e "$_EGRESS_BOXES_DIR/$CN"
  assert_failure
  # With an edit, the file keeps the mode it had and never says open.
  rm -f "${_EGRESS_BOXES_DIR:?}/${CN:?}.session" "${TEST_TEMP:?}/applied"
  _egress_editor_load main
  _egress_host_add extra.example.com
  _EGE_MODE=open
  run _egress_save_screen 0 <<< $'y\ny'
  run cat "$_EGRESS_BOXES_DIR/$CN"
  assert_output "[egress]
allow = extra.example.com"
}

@test "egress ring: done in the typed editor never answers the recreate or the open for you" {
  status_caged
  _egress_on_terminal() { return 0; }
  cmd_run() { echo "cmd_run" >> "$DOCKER_CALLS"; }
  _egress_editor_load main
  _EGE_MODE=off
  # The typed editor's done passes 1: that answers Save and nothing else.
  run _egress_save_screen 1 <<< ""
  run _plain "$output"
  assert_output --partial "This recreates the box. See below."
  assert_output --partial "Turn egress control off and recreate the box? [y/N]"
  assert_output --partial "Not changed."
  run grep -cE "^docker rm|^cmd_run" "$DOCKER_CALLS"
  assert_output "0"
}

@test "egress ui: the hooks escape prints claim void in the launch summary row" {
  # 9.3: a box created under the hooks escape carries hooks=1 in its create
  # hash, and every surface that names the claim says it is void.
  mock_egress_caged_launch
  CN=cleat-proj-12345678
  egress_box_names
  F_HOOKS=1 caged_box
  ACTIVE_CAPS=(hooks)
  run _egress_summary_row "$CN"
  run _plain "$output"
  assert_output --partial "Egress:     strict, claim void  ·  5 hosts, 1 pack"
  assert_output --partial "              ! hooks runs your host commands with box-supplied stdin"
  # The same box made without the escape: the claim stands.
  rm -rf "$DOCKER_MOCK_DIR/inspect"
  caged_box
  ACTIVE_CAPS=()
  run _egress_summary_row "$CN"
  run _plain "$output"
  assert_output --partial "Egress:     strict  ·  5 hosts, 1 pack"
  refute_output --partial "claim void"
  refute_output --partial "! hooks"
}

# ── The session-end egress report (9.5) ─────────────────────────────────────

# A caged box whose gateway's denial log holds <rows>, and the log-state the
# gateway answers now.
report_box() {                           # <rows> [state]
  status_caged
  mkdir -p "$DOCKER_MOCK_DIR/cp/$GW"
  printf '%b' "${1:-}" > "$DOCKER_MOCK_DIR/cp/$GW/denials.log"
  mock_gw_admin log-state "ok log-state ${2:-1 0}"
}
deny_row() { printf '2026-09-28T14:31:0%sZ code=%s sub=%s origin=box host=%s port=%s trunc=0\\n' "$1" "$2" "${4:--}" "$3" "${5:-443}"; }

@test "egress report: the session end report reads only the bytes appended during the session" {
  local before
  before="$(deny_row 1 policy old1.example)$(deny_row 2 policy old2.example)"
  report_box "$before$(deny_row 3 policy sentry.io)"
  local off
  off="$(printf '%b' "$before" | wc -c | tr -d ' ')"
  run _maybe_report_egress_denials "$CN" 1 "$off"
  assert_success
  run _plain "$output"
  assert_output --partial "! 1 destination was denied by egress policy this session"
  assert_output --partial "sentry.io"
  refute_output --partial "old1.example"
  refute_output --partial "old2.example"
}

@test "egress report: the session end report shows at most three denied hosts and counts the rest" {
  report_box "$(deny_row 1 policy registry.npmjs.org)$(deny_row 2 policy registry.yarnpkg.com)$(deny_row 3 policy sentry.io)$(deny_row 4 policy four.example)$(deny_row 5 policy five.example)$(deny_row 6 policy sentry.io)"
  run _maybe_report_egress_denials "$CN" 1 0
  assert_success
  run _plain "$output"
  # Five distinct hosts, counted here, never read from the log.
  assert_output --partial "! 5 destinations were denied by egress policy this session"
  assert_output --regexp "registry\.npmjs\.org, registry\.yarnpkg\.com +pack npm   contained"
  assert_output --regexp "sentry\.io +no pack      unaudited"
  refute_output --partial "four.example"
  assert_output --partial "      and 2 more"
  assert_output --partial "cleat egress log     every denial with timestamps"
  # fix is a later release: no remedy names a verb that does not exist.
  refute_output --partial "cleat egress fix"
}

@test "egress report: a refused handshake is reported separately and is never offered as a fix" {
  report_box "$(deny_row 7 sni raw.pastebin.example sni-mismatch)$(deny_row 8 policy sentry.io)"
  run _maybe_report_egress_denials "$CN" 1 0
  assert_success
  run _plain "$output"
  assert_output --partial "✖ 1 connection was refused because the handshake did not match the tunnel"
  assert_output --regexp "raw\.pastebin\.example +14:31:07"
  assert_output --partial "Your policy did not cause this.       cleat egress log --refused"
  assert_output --partial "! 1 destination was denied by egress policy this session"
  # The refused host is never in the policy list and never beside allow.
  run bash -c 'printf "%s\n" "$1" | sed -n "/destination/,\$p"' _ "$(_plain "$output")"
  refute_output --partial "raw.pastebin.example"
  run _maybe_report_egress_denials "$CN" 1 0
  refute_output --partial "allow"
  # Anything but sni is the gateway's own checks.
  report_box "$(deny_row 1 address internal.example)$(deny_row 2 sni a.example sni-mismatch)"
  run _maybe_report_egress_denials "$CN" 1 0
  run _plain "$output"
  assert_output --partial "✖ 2 connections were refused by the gateway's own checks, not your policy"
  refute_output --partial "destination"
}

@test "egress report: port refusals are counted on their own line" {
  report_box "$(deny_row 1 port a.example - 80)$(deny_row 2 port b.example - 22)"
  run _maybe_report_egress_denials "$CN" 1 0
  run _plain "$output"
  assert_output --partial "! 2 connections on a port other than 443 were refused this session"
  report_box "$(deny_row 1 policy sentry.io)$(deny_row 2 port a.example - 80)"
  run _maybe_report_egress_denials "$CN" 1 0
  run _plain "$output"
  assert_output --partial "! 1 destination was denied by egress policy this session"
  assert_output --partial "      1 connection on a port other than 443 was refused."
}

@test "egress report: a truncated host is never looked up and says so" {
  report_box '2026-09-28T14:31:01Z code=policy sub=- origin=box host=registry.npmjs.org port=443 trunc=1\n'
  _egress_host_pack() { echo "looked up" >> "$TEST_TEMP/lookups"; }
  run _maybe_report_egress_denials "$CN" 1 0
  run _plain "$output"
  assert_output --regexp "registry\.npmjs\.org \(truncated\) +no pack"
  [ ! -f "$TEST_TEMP/lookups" ]
}

@test "egress report: the session end report is silent with nothing to say or no mark" {
  report_box ""
  : > "$DOCKER_CALLS"
  run _maybe_report_egress_denials "$CN" 1 0
  assert_success
  assert_output ""
  # No mark: a window without its start would re-report earlier sessions.
  report_box "$(deny_row 1 policy sentry.io)"
  : > "$DOCKER_CALLS"
  run _maybe_report_egress_denials "$CN" "" 0
  assert_output ""
  run grep -c "^docker cp" "$DOCKER_CALLS"
  assert_output "0"
}

@test "egress report: the hooks escape prints the claim void line with nothing else to report" {
  report_box ""
  rm -rf "$DOCKER_MOCK_DIR/inspect"
  F_HOOKS=1 caged_box
  run _maybe_report_egress_denials "$CN" 1 0
  assert_success
  run _plain "$output"
  assert_output --partial "! The claim is void for this box"
  refute_output --partial "destination"
  # And first, above anything denied.
  report_box "$(deny_row 1 policy sentry.io)"
  rm -rf "$DOCKER_MOCK_DIR/inspect"
  F_HOOKS=1 caged_box
  run _maybe_report_egress_denials "$CN" 1 0
  run _plain "$output"
  local v d
  v="$(printf '%s\n' "$output" | grep -n "claim is void" | cut -d: -f1)"
  d="$(printf '%s\n' "$output" | grep -n "destination was denied" | cut -d: -f1)"
  [ -n "$v" ]
  [ -n "$d" ]
  [ "$v" -lt "$d" ]
}

# ── Review fixes: what status, open and the editor say ─────────────────────

@test "egress status: cleat status stays quiet for a caged box stopped normally and names an uncaged one" {
  status_caged
  is_running() { return 1; }
  run _egress_status_summary_row "$CN"
  run _plain "$output"
  assert_output --partial "Egress:    strict"
  refute_output --partial "gateway"
  refute_output --partial "!"
  # A box with no label under a policy has no cage, and says so.
  rm -rf "$DOCKER_MOCK_DIR/inspect"
  F_HASH="" caged_box
  run _egress_status_summary_row "$CN"
  run _plain "$output"
  assert_output --partial "x created without egress control, so it has no cage."
  assert_output --partial "cleat rm && cleat"
}

@test "egress status: a box its own file turned off names that file and never the global remedies" {
  status_caged
  mkdir -p "$_EGRESS_BOXES_DIR"
  printf '[egress]\nmode = off\n' > "$_EGRESS_BOXES_DIR/$CN"
  rm -rf "$DOCKER_MOCK_DIR/inspect"
  F_HASH="" caged_box
  run _egress_status_render "$CN"
  run _plain "$output"
  assert_output --partial "Egress control is off for this box, by its own file"
  assert_output --partial "Other boxes follow the global policy."
  assert_output --partial "cleat egress main --inherit"
  refute_output --partial "every box on this machine has today"
  refute_output --partial "the Egress row, which opens the same editor"
  _egress_engine_kind() { printf engine-linux; }
  run _egress_status_render "$CN"
  run _plain "$output"
  assert_output --partial "This engine is not validated"
}

@test "egress open: --always and the config row refuse a box with the docker capability, and write nothing" {
  _EGRESS_ENFORCING=1
  _daemon_up() { return 0; }
  _egress_engine_kind() { printf desktop-macos; }
  mkdir -p "$CLEAT_CONFIG_DIR"
  printf '[caps]\ndocker\n' > "$CLEAT_GLOBAL_CONFIG"
  cp "$CLEAT_GLOBAL_CONFIG" "$TEST_TEMP/before"
  run cmd_egress_open_always 1
  assert_failure
  run _plain "$output"
  assert_output --partial "docker hands the box your Docker daemon"
  run cmp "$CLEAT_GLOBAL_CONFIG" "$TEST_TEMP/before"
  assert_success
  run _egress_config_enable
  assert_failure
  run _plain "$output"
  assert_output --partial "docker hands the box your Docker daemon"
  run cmp "$CLEAT_GLOBAL_CONFIG" "$TEST_TEMP/before"
  assert_success
}

@test "egress open: --always says the global policy is open and what a refused engine means" {
  _EGRESS_ENFORCING=1
  _daemon_up() { return 0; }
  _egress_engine_kind() { printf desktop-macos; }
  _egress_apply_now() { :; }
  mkdir -p "$CLEAT_CONFIG_DIR"
  run cmd_egress_open_always 1
  assert_success
  run _plain "$output"
  assert_output --partial "The global policy is open until you change it."
  assert_output --partial "A box with a mode of its own keeps it."
  refute_output --partial "Every box is open"
  refute_output --partial "refuse to start until you switch engine"
  _egress_engine_kind() { printf engine-linux; }
  run cmd_egress_open_always 1
  run _plain "$output"
  assert_output --partial "Boxes on this machine will refuse to start until you switch engine or run cleat egress off."
}

@test "egress save: an off save on an unvalidated engine warns of no refusal" {
  _EGRESS_ENFORCING=1
  _egress_editor_engine() { _EGE_ENGINE=engine-linux; }
  _daemon_up() { return 0; }
  mkdir -p "$CLEAT_CONFIG_DIR"
  printf '[egress]\nmode = strict\n' > "$CLEAT_GLOBAL_CONFIG"
  _EGE_BOX=main
  run _egress_save_consequence off
  refute_output --partial "refuse to start"
  run _egress_save_consequence strict
  assert_output --partial "refuse to start"
}

@test "egress notices: the origin reader survives a byte a UTF-8 tr would refuse" {
  # A tr that refuses a high byte outside the C locale, as BSD tr does in a
  # UTF-8 one. A Latin-1 branch name in .git/config is enough to meet it.
  mkdir -p "$TEST_TEMP/bsdtr" "$PROJECT/.git"
  cat > "$TEST_TEMP/bsdtr/tr" <<'SH'
#!/usr/bin/env bash
if [ "${LC_ALL:-}" != C ]; then
  if LC_ALL=C grep -q $'[\x80-\xff]'; then echo "tr: Illegal byte sequence" >&2; exit 1; fi
fi
exec /usr/bin/tr "$@"
SH
  chmod +x "$TEST_TEMP/bsdtr/tr"
  printf '[branch "caf\xe9"]\n\tremote = origin\n[remote "origin"]\n\turl = git@github.com:o/r.git\n' > "$PROJECT/.git/config"
  PATH="$TEST_TEMP/bsdtr:$PATH" LANG=en_US.UTF-8 run _egress_origin_is_ssh "$PROJECT"
  assert_equal "$status" 0
  refute_output --partial "Illegal byte"
}
