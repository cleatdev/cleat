#!/usr/bin/env bats
# ── Egress configuration: the policy reader, the writer, containment ─────────
#
# EGRESS-SPEC.md 4.2 and 5.1 to 5.4. The policy is a section of the GLOBAL
# config only. These tests drive the shipped readers through _egress_read_file,
# the raw key counter that sees the empty values the shared reader drops, the
# writer that rewrites [egress] and keeps everything else, and the refusals
# that keep a policy out of the cage.
load "../setup"
setup() {
  _common_setup
  source_cli
  mkdir -p "$CLEAT_CONFIG_DIR"
  CONF="$CLEAT_GLOBAL_CONFIG"
}
teardown() { _common_teardown; }

# ── The reader and the raw counter (4.2) ────────────────────────────────────

@test "egress config: the policy is read from the [egress] section of the global config" {
  printf '[caps]\nenabled = gh\n[egress]\nmode = strict\nallow = a.example\nallow = b.example\npack = github\ndeny = c.example\n' > "$CONF"
  _egress_read_file "$CONF" egress
  run printf '%s|%s|%s|%s|end' "$_m_mode" "$_e_vals" "$_p_vals" "$_d_vals"
  assert_output "strict|a.example
b.example
|github
|c.example
|end"
}

@test "egress config: an empty deny line refuses to start" {
  printf '[egress]\nmode = strict\ndeny =\n' > "$CONF"
  run _egress_read_file "$CONF" egress
  assert_failure
  assert_output --partial "Empty deny line"
  # And beside a real deny, which is the case a -ne compare would also catch.
  printf '[egress]\nmode = strict\ndeny = a.example\ndeny =\n' > "$CONF"
  run _egress_read_file "$CONF" egress
  assert_failure
  assert_output --partial "Empty deny line"
}

@test "egress config: the raw key counter counts an empty value" {
  printf '[egress]\ndeny = a.example\ndeny =\ndeny = b.example\n' > "$CONF"
  run _egress_raw_key_count "$CONF" egress deny
  assert_output "3"
}

@test "egress config: the raw key counter ignores a commented deny line" {
  printf '[egress]\n# deny = a.example\n  #deny =\ndeny = b.example\n' > "$CONF"
  run _egress_raw_key_count "$CONF" egress deny
  assert_output "1"
}

@test "egress config: the raw key counter ignores a deny line in another section" {
  printf '[browser]\ndeny = x\n[egress]\ndeny = b.example\n[caps]\ndeny = y\n' > "$CONF"
  run _egress_raw_key_count "$CONF" egress deny
  assert_output "1"
}

@test "egress config: the raw key counter and the reader agree on BOM, CRLF and case" {
  # The fixture the spec measured: BOM, CRLF, a comment, an indented line, a
  # bare word, a capitalised key, a real value, an empty value, a neighbour.
  printf '\357\273\277[egress]\r\n# deny = c.example\r\n  deny = i.example\r\ndeny\r\nDeny = x.example\r\ndeny = r.example\r\ndeny =\r\n[other]\r\ndeny = n.example\r\n' > "$CONF"
  run _egress_raw_key_count "$CONF" egress deny
  assert_output "3"
  run _read_section_all_from_file "$CONF" egress deny
  assert_output "i.example
r.example"
}

@test "egress config: a missing file counts zero and reads as absent" {
  run _egress_raw_key_count "$TEST_TEMP/nope" egress deny
  assert_output "0"
  _egress_read_file "$TEST_TEMP/nope" egress
  run echo "$_m_mode"
  assert_output "absent"
}

@test "egress config: two mode lines are a hard config error" {
  printf '[egress]\nmode = strict\nmode = strict\n' > "$CONF"
  run _egress_read_file "$CONF" egress
  assert_failure
  assert_output --partial "More than one mode line"
}

@test "egress config: two mode lines name both values in the error" {
  printf '[egress]\nmode = strict\nmode = open\n' > "$CONF"
  run _egress_read_file "$CONF" egress
  assert_failure
  assert_output --partial "strict, open"
}

@test "egress config: an empty mode refuses to start" {
  printf '[egress]\nallow = a.example\nmode =\n' > "$CONF"
  run _egress_read_file "$CONF" egress
  assert_failure
  assert_output --partial "Empty mode line"
}

@test "egress config: an unknown mode refuses and echoes it sanitized" {
  printf '[egress]\nmode = permissive\n' > "$CONF"
  run _egress_read_file "$CONF" egress
  assert_failure
  assert_output --partial "Unknown egress mode"
  assert_output --partial "permissive"
}

@test "egress config: one mode line resolves to that value" {
  local m
  for m in strict open off; do
    printf '[egress]\nmode = %s\n' "$m" > "$CONF"
    _egress_read_file "$CONF" egress
    run echo "$_m_mode"
    assert_output "$m"
  done
}

@test "egress config: a bare [egress] header reads as absent" {
  printf '[egress]\n' > "$CONF"
  _egress_read_file "$CONF" egress
  run echo "$_m_mode|$_e_vals$_p_vals$_d_vals"
  assert_output "absent|"
}

# ── Section registration (4.2) ──────────────────────────────────────────────

@test "egress config: a project cleat section is ignored with a named warning" {
  mkdir -p "$TEST_TEMP/proj"
  printf '[egress]\nmode = open\n[box.review.egress]\nmode = off\n' > "$TEST_TEMP/proj/.cleat"
  run _warn_unknown_cleat_sections "$TEST_TEMP/proj/.cleat" project
  assert_output --partial "Section [egress] in .cleat is ignored"
  assert_output --partial "egress policy is global"
  assert_output --partial "cleat egress"
  assert_output --partial "Section [box.review.egress] in .cleat is ignored"
  refute_output --partial "Unknown section"
}

@test "egress config: the global config accepts an egress section silently" {
  printf '[egress]\nmode = strict\n' > "$CONF"
  run _warn_unknown_cleat_sections "$CONF" global
  assert_output ""
}

# ── The writer (5.3) ────────────────────────────────────────────────────────

@test "egress config: the writer preserves every other section" {
  printf '[caps]\nenabled = gh\n\n[resources]\nmemory = 4g\n[kits]\nplanner = x\n[fork]\ndir = /tmp/f\n[browser]\norigin = a.example\n[egress]\nmode = open\nallow = old.example\n' > "$CONF"
  run _write_egress_to_file "$CONF" strict "github" "" "new.example"
  assert_success
  run cat "$CONF"
  assert_output "[caps]
enabled = gh

[resources]
memory = 4g
[kits]
planner = x
[fork]
dir = /tmp/f
[browser]
origin = a.example
[egress]
mode = strict
pack = github
allow = new.example"
}

@test "egress config: the writer emits canonical order, sorted and deduped" {
  run _write_egress_to_file "$CONF" strict $'pk2\npk1' $'z.example\na.example\nz.example' $'b.example\na.example\nb.example'
  assert_success
  run cat "$CONF"
  assert_output "[egress]
mode = strict
pack = pk1
pack = pk2
deny = a.example
deny = z.example
allow = a.example
allow = b.example"
}

@test "egress config: an indented egress header is replaced not duplicated" {
  printf '[caps]\nenabled = gh\n  [egress]  \r\nmode = open\nallow = old.example\n' > "$CONF"
  run _write_egress_to_file "$CONF" strict "" "" "new.example"
  assert_success
  run grep -c 'egress' "$CONF"
  assert_output "1"
  run _egress_section_canon "$CONF"
  assert_output "mode = strict
allow = new.example"
}

@test "egress config: a BOM-prefixed config does not lose its first section" {
  printf '\357\273\277[caps]\nenabled = gh\n' > "$CONF"
  run _write_egress_to_file "$CONF" strict "" "" ""
  assert_success
  run _read_section_all_from_file "$CONF" caps enabled
  assert_output "gh"
  run head -c 3 "$CONF"
  refute_output $'\357\273\277'
}

@test "egress config: a BOM before the egress header itself is still the egress header" {
  printf '\357\273\277[egress]\nmode = open\nallow = old.example\n[caps]\nenabled = gh\n' > "$CONF"
  run _write_egress_to_file "$CONF" strict "" "" "new.example"
  assert_success
  run grep -c '^\[egress\]' "$CONF"
  assert_output "1"
  run _egress_section_canon "$CONF"
  assert_output "mode = strict
allow = new.example"
}

@test "egress config: a final section with no trailing newline survives" {
  printf '[egress]\nmode = off\n[fork]\ndir = /tmp/f' > "$CONF"
  run _write_egress_to_file "$CONF" strict "" "" ""
  assert_success
  run _read_section_all_from_file "$CONF" fork dir
  assert_output "/tmp/f"
}

@test "egress config: a write-nothing path does not kill a strict-mode caller" {
  # No lists at all: every optional block is skipped, and a skipped block must
  # not make the redirected compound return 1 under set -e.
  run bash -c 'set -euo pipefail; source "$1"; set -euo pipefail
    _write_egress_to_file "$2" off "" "" ""
    echo survived' _ "$CLI" "$CONF"
  assert_success
  assert_output --partial "survived"
}

@test "egress config: an empty egress header is still emitted once mode is set" {
  run _write_egress_to_file "$CONF" strict "" "" ""
  assert_success
  run cat "$CONF"
  assert_output "[egress]
mode = strict"
}

@test "egress config: the writer keeps comments and unknown keys inside egress" {
  printf '[egress]\n# why this is strict\nmode = open\ndeni = typo.example\n' > "$CONF"
  run _write_egress_to_file "$CONF" strict "" "" ""
  assert_success
  run cat "$CONF"
  assert_output "[egress]
# why this is strict
deni = typo.example
mode = strict"
}

@test "egress config: the writer refuses a missing or unknown mode" {
  run _write_egress_to_file "$CONF" "" "" "" "a.example"
  assert_failure
  run _write_egress_to_file "$CONF" permissive "" "" "a.example"
  assert_failure
  [ ! -e "$CONF" ] || { echo "a refused write created the file"; return 1; }
}

@test "egress config: a concurrent policy edit refuses rather than overwriting" {
  printf '[egress]\nmode = strict\n' > "$CONF"
  # The other terminal saves between this writer's read and its rename. The
  # canon read is the seam: its second call is the pre-rename re-read.
  local calls="$TEST_TEMP/canon_calls"
  : > "$calls"
  eval "_real_canon() $(declare -f _egress_section_canon | sed 1d)"
  _egress_section_canon() {
    echo x >> "$TEST_TEMP/canon_calls"
    if [ "$(wc -l < "$TEST_TEMP/canon_calls")" -eq 2 ]; then
      printf '[egress]\nmode = strict\ndeny = other.example\n' > "$CLEAT_GLOBAL_CONFIG"
    fi
    _real_canon "$@"
  }
  run _write_egress_to_file "$CONF" strict "" "" "mine.example"
  assert_failure
  assert_output --partial "The policy changed in another terminal"
  run _egress_section_canon "$CONF"
  assert_output "mode = strict
deny = other.example"
  run bash -c 'ls "$1".cleat-tmp.* 2>/dev/null | wc -l' _ "$CONF"
  assert_output --regexp '^ *0$'
}

@test "egress config: a cosmetic change in another terminal does not refuse" {
  printf '[egress]\nallow = b.example\nmode = strict\nallow = a.example\n' > "$CONF"
  eval "_real_canon() $(declare -f _egress_section_canon | sed 1d)"
  _egress_section_canon() {
    printf '# reordered\n[egress]\nmode = strict\nallow = a.example\nallow = b.example\n' > "$CLEAT_GLOBAL_CONFIG"
    _real_canon "$@"
  }
  run _write_egress_to_file "$CONF" strict "" "" $'a.example\nb.example\nc.example'
  assert_success
}

# ── Containment and the directory target (5.2) ──────────────────────────────

@test "egress config: a policy path that is a symlink to a directory is refused rather than silently vanishing" {
  mkdir -p "$TEST_TEMP/victim"
  ln -s "$TEST_TEMP/victim" "$CONF"
  run _write_egress_to_file "$CONF" strict "" "" "a.example"
  assert_failure
  assert_output --partial "Refusing to write policy to a directory"
  run ls -A "$TEST_TEMP/victim"
  assert_output ""
}

@test "egress config: the first write to an absent config succeeds" {
  rm -rf "$CLEAT_CONFIG_DIR"
  run _write_egress_to_file "$CONF" strict "" "" "a.example"
  assert_success
  run _read_section_all_from_file "$CONF" egress allow
  assert_output "a.example"
}

@test "egress config: a policy path that is a symlink to a regular file is written" {
  printf '[caps]\nenabled = gh\n' > "$TEST_TEMP/dotfiles-config"
  ln -s "$TEST_TEMP/dotfiles-config" "$CONF"
  run _write_egress_to_file "$CONF" strict "" "" "a.example"
  assert_success
  run _read_section_all_from_file "$CONF" egress allow
  assert_output "a.example"
  run _read_section_all_from_file "$CONF" caps enabled
  assert_output "gh"
}

@test "egress config: the writer replaces a symlinked config rather than writing through it" {
  # The tmp-and-rename is a symlink control: a link planted over the config
  # to some other file must not have that file rewritten.
  printf 'export SECRET=1\n' > "$TEST_TEMP/shell-rc"
  ln -s "$TEST_TEMP/shell-rc" "$CONF"
  run _write_egress_to_file "$CONF" strict "" "" "a.example"
  assert_success
  run cat "$TEST_TEMP/shell-rc"
  assert_output "export SECRET=1"
  [ ! -L "$CONF" ] || { echo "the write went through the link"; return 1; }
}

@test "egress config: a config dir inside the workspace refuses to enable a policy" {
  run _egress_config_is_containable "$HOME"
  assert_failure
  assert_output --partial "inside a folder a box can write"
  mkdir -p "$TEST_TEMP/proj"
  run _egress_config_is_containable "$TEST_TEMP/proj"
  assert_success
  assert_output ""
}

@test "egress config: the config dir itself as a workspace refuses" {
  run _egress_config_is_containable "$CLEAT_CONFIG_DIR"
  assert_failure
}

@test "egress config: any other read-write bind source is checked too" {
  mkdir -p "$TEST_TEMP/proj"
  run _egress_config_is_containable "$TEST_TEMP/proj" "$HOME/.config"
  assert_failure
}

@test "egress config: a symlinked component on the path to the config dir refuses" {
  mkdir -p "$TEST_TEMP/real-config"
  mv "$HOME/.config" "$TEST_TEMP/real-config/.config" 2>/dev/null || mkdir -p "$TEST_TEMP/real-config/.config/cleat"
  ln -s "$TEST_TEMP/real-config/.config" "$HOME/.config"
  mkdir -p "$TEST_TEMP/proj"
  run _egress_config_is_containable "$TEST_TEMP/proj"
  assert_failure
  assert_output --partial "reached through a symlink"
}
