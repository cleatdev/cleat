#!/usr/bin/env bats
# ── Egress configuration: the policy reader, the writer, containment ─────────
#
# EGRESS-SPEC.md 4.2 and 5.1 to 5.4. The policy is a section of the GLOBAL
# config only. These tests drive the shipped readers through _egress_read_file,
# the raw key counter that sees the empty values the shared reader drops, the
# writer that rewrites [egress] and keeps everything else, and the refusals
# that keep a policy out of the cage.
load "../setup"
load "../lib/egress_fixtures"
setup() {
  _common_setup
  # The stub, never the host's daemon: a session-marker read runs docker inspect.
  use_docker_stub
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

# ── Resolution (5.1, 5.4) ────────────────────────────────────────────────────

CORE="api.anthropic.com
claude.ai
claude.com
code.claude.com
platform.claude.com"

@test "egress config: no egress section anywhere resolves to the feature off" {
  printf '[caps]\nenabled = gh\n' > "$CONF"
  _egress_resolve cleat-app-1234abcd
  run echo "$_EG_MODE $_EG_WHY"
  assert_output "off absent"
}

@test "egress config: a bare [egress] header is the feature off" {
  printf '[egress]\n' > "$CONF"
  _egress_resolve cleat-app-1234abcd
  run echo "$_EG_MODE $_EG_WHY"
  assert_output "off header"
}

@test "egress config: allow lines with no mode refuse to start" {
  printf '[egress]\nallow = a.example\n' > "$CONF"
  run _egress_resolve cleat-app-1234abcd
  assert_failure
  assert_output --partial "lists hosts but no mode"
  printf '[egress]\npack = github\n' > "$CONF"
  run _egress_resolve cleat-app-1234abcd
  assert_failure
  printf '[egress]\ndeny = a.example\n' > "$CONF"
  run _egress_resolve cleat-app-1234abcd
  assert_failure
}

@test "egress config: strict with no entries is the core pack and nothing else" {
  printf '[egress]\nmode = strict\n' > "$CONF"
  _egress_resolve cleat-app-1234abcd
  run echo "$_EG_MODE $_EG_WHY"
  assert_output "strict global"
  run echo "$_EG_HOSTS"
  assert_output "$CORE"
}

@test "egress config: packs expand to their default hosts, allows add and denies subtract" {
  printf '[egress]\nmode = strict\npack = github\nallow = Registry.NPMjs.org.\nallow = extra.example\ndeny = uploads.github.com\ndeny = extra.example\n' > "$CONF"
  _egress_resolve cleat-app-1234abcd
  run echo "$_EG_HOSTS"
  assert_output "api.anthropic.com
api.github.com
claude.ai
claude.com
code.claude.com
codeload.github.com
github.com
platform.claude.com
registry.npmjs.org"
}

@test "egress config: the core pack can never be denied away" {
  printf '[egress]\nmode = strict\ndeny = api.anthropic.com\n' > "$CONF"
  _egress_resolve cleat-app-1234abcd
  run echo "$_EG_HOSTS"
  assert_output "$CORE"
}

@test "egress config: open and off resolve to themselves" {
  printf '[egress]\nmode = open\n' > "$CONF"
  _egress_resolve cleat-app-1234abcd
  run echo "$_EG_MODE"
  assert_output "open"
  printf '[egress]\nmode = off\nallow = a.example\n' > "$CONF"
  _egress_resolve cleat-app-1234abcd
  run echo "$_EG_MODE $_EG_WHY"
  assert_output "off global"
}

@test "egress config: an invalid allow is dropped with a warning and the launch continues" {
  printf '[egress]\nmode = strict\nallow = 1.2.3.4\nallow = ok.example\n' > "$CONF"
  run _egress_resolve cleat-app-1234abcd
  assert_success
  assert_output --partial "not a host name: 1.2.3.4"
  assert_output --partial "IP_LITERAL"
  _egress_resolve cleat-app-1234abcd >/dev/null
  run echo "$_EG_HOSTS"
  assert_output --partial "ok.example"
  refute_output --partial "1.2.3.4"
}

@test "egress config: an empty allow line is dropped with a warning and the launch continues" {
  printf '[egress]\nmode = strict\nallow =\nallow = ok.example\n' > "$CONF"
  run _egress_resolve cleat-app-1234abcd
  assert_success
  assert_output --partial "Ignored an empty allow line"
}

@test "egress config: an invalid deny refuses to start" {
  printf '[egress]\nmode = strict\ndeny = not a host\n' > "$CONF"
  run _egress_resolve cleat-app-1234abcd
  assert_failure
  assert_output --partial "A deny entry"
  assert_output --partial "would widen"
}

@test "egress config: an unknown pack refuses to start" {
  printf '[egress]\nmode = strict\npack = githubb\n' > "$CONF"
  run _egress_resolve cleat-app-1234abcd
  assert_failure
  assert_output --partial "Unknown egress pack"
  assert_output --partial "githubb"
}

@test "egress config: an unknown key inside egress warns once" {
  printf '[egress]\nmode = strict\ndeni = a.example\ndeni = b.example\n' > "$CONF"
  run _egress_resolve cleat-app-1234abcd
  assert_output --partial "Unknown key"
  assert_output --partial "deni"
  # Two resolutions in one process print it once.
  _EG_WARNED_KEY_FILES=""
  local out
  out="$( { _egress_resolve cleat-app-1234abcd; _egress_resolve cleat-app-1234abcd; } 2>&1 )"
  run grep -c "Unknown key" <<< "$out"
  assert_output "1"
}

@test "egress config: a per-box allow overrides a global deny" {
  printf '[egress]\nmode = strict\ndeny = x.example\n' > "$CONF"
  mkdir -p "$CLEAT_CONFIG_DIR/egress-boxes"
  printf '[egress]\nallow = x.example\n' > "$CLEAT_CONFIG_DIR/egress-boxes/cleat-app-1234abcd"
  _egress_resolve cleat-app-1234abcd
  run echo "$_EG_HOSTS"
  assert_output --partial "x.example"
}

@test "egress config: a per-box deny subtracts after the per-box allows" {
  printf '[egress]\nmode = strict\nallow = a.example\n' > "$CONF"
  mkdir -p "$CLEAT_CONFIG_DIR/egress-boxes"
  printf '[egress]\nallow = b.example\ndeny = a.example\ndeny = b.example\n' > "$CLEAT_CONFIG_DIR/egress-boxes/cleat-app-1234abcd"
  _egress_resolve cleat-app-1234abcd
  run echo "$_EG_HOSTS"
  assert_output "$CORE"
}

@test "egress config: a per-box mode replaces the global mode" {
  printf '[egress]\nmode = strict\n' > "$CONF"
  mkdir -p "$CLEAT_CONFIG_DIR/egress-boxes"
  printf '[egress]\nmode = off\n' > "$CLEAT_CONFIG_DIR/egress-boxes/cleat-app-1234abcd"
  _egress_resolve cleat-app-1234abcd
  run echo "$_EG_MODE $_EG_WHY"
  assert_output "off perbox"
  # And it can cage a box the global section leaves off.
  printf '[egress]\nmode = off\n' > "$CONF"
  printf '[egress]\nmode = strict\n' > "$CLEAT_CONFIG_DIR/egress-boxes/cleat-app-1234abcd"
  _egress_resolve cleat-app-1234abcd
  run echo "$_EG_MODE $_EG_WHY"
  assert_output "strict perbox"
}

@test "egress config: a per-box file with no mode keeps the global mode" {
  printf '[egress]\nmode = strict\n' > "$CONF"
  mkdir -p "$CLEAT_CONFIG_DIR/egress-boxes"
  printf '[egress]\nallow = b.example\n' > "$CLEAT_CONFIG_DIR/egress-boxes/cleat-app-1234abcd"
  _egress_resolve cleat-app-1234abcd
  run echo "$_EG_MODE $_EG_WHY"
  assert_output "strict global"
}

@test "egress config: a fork does not read the parent box's per-box policy" {
  printf '[egress]\nmode = strict\n' > "$CONF"
  mkdir -p "$CLEAT_CONFIG_DIR/egress-boxes"
  printf '[egress]\nallow = parent-only.example\n' > "$CLEAT_CONFIG_DIR/egress-boxes/cleat-app-1234abcd"
  _egress_resolve cleat-app-1234abcd-review
  run echo "$_EG_HOSTS"
  refute_output --partial "parent-only.example"
}

@test "egress config: a per-box path that is a directory refuses" {
  printf '[egress]\nmode = strict\n' > "$CONF"
  mkdir -p "$CLEAT_CONFIG_DIR/egress-boxes/cleat-app-1234abcd"
  run _egress_resolve cleat-app-1234abcd
  assert_failure
  assert_output --partial "Refusing to write policy to a directory"
}

@test "egress config: a project cleat file cannot widen the policy" {
  printf '[egress]\nmode = strict\n' > "$CONF"
  mkdir -p "$TEST_TEMP/proj"
  printf '[egress]\nmode = strict\nallow = evil.example\n' > "$TEST_TEMP/proj/.cleat"
  _RESOLVED_PROJECT="$TEST_TEMP/proj"
  _egress_resolve cleat-proj-1234abcd
  run echo "$_EG_HOSTS"
  refute_output --partial "evil.example"
}

# ── The session marker (5.1 step 6) ─────────────────────────────────────────

@test "egress config: a live session marker turns strict into open" {
  printf '[egress]\nmode = strict\n' > "$CONF"
  mkdir -p "$CLEAT_CONFIG_DIR/egress-boxes"
  printf '2026-09-25T10:00:00.1Z\n' > "$CLEAT_CONFIG_DIR/egress-boxes/cleat-app-1234abcd.session"
  mock_docker_inspect_field cleat-app-1234abcd '{{if .State.Running}}{{.State.StartedAt}}{{end}}' '2026-09-25T10:00:00.1Z'
  _egress_resolve cleat-app-1234abcd
  run echo "$_EG_MODE $_EG_WHY"
  assert_output "open session"
}

@test "egress config: a marker whose start differs is removed and resolves strict" {
  printf '[egress]\nmode = strict\n' > "$CONF"
  mkdir -p "$CLEAT_CONFIG_DIR/egress-boxes"
  printf '2026-09-25T10:00:00.1Z\n' > "$CLEAT_CONFIG_DIR/egress-boxes/cleat-app-1234abcd.session"
  mock_docker_inspect_field cleat-app-1234abcd '{{if .State.Running}}{{.State.StartedAt}}{{end}}' '2026-09-25T11:00:00.1Z'
  _egress_resolve cleat-app-1234abcd
  run echo "$_EG_MODE"
  assert_output "strict"
  [ ! -e "$CLEAT_CONFIG_DIR/egress-boxes/cleat-app-1234abcd.session" ] || { echo "stale marker kept"; return 1; }
}

@test "egress config: a marker on a stopped box is removed" {
  printf '[egress]\nmode = strict\n' > "$CONF"
  mkdir -p "$CLEAT_CONFIG_DIR/egress-boxes"
  printf '2026-09-25T10:00:00.1Z\n' > "$CLEAT_CONFIG_DIR/egress-boxes/cleat-app-1234abcd.session"
  mock_docker_inspect_field cleat-app-1234abcd '{{if .State.Running}}{{.State.StartedAt}}{{end}}' ''
  _egress_resolve cleat-app-1234abcd
  run echo "$_EG_MODE"
  assert_output "strict"
  [ ! -e "$CLEAT_CONFIG_DIR/egress-boxes/cleat-app-1234abcd.session" ] || { echo "marker kept"; return 1; }
}

@test "egress config: a session marker never turns off into open" {
  printf '[egress]\nmode = off\n' > "$CONF"
  mkdir -p "$CLEAT_CONFIG_DIR/egress-boxes"
  printf '2026-09-25T10:00:00.1Z\n' > "$CLEAT_CONFIG_DIR/egress-boxes/cleat-app-1234abcd.session"
  mock_docker_inspect_field cleat-app-1234abcd '{{if .State.Running}}{{.State.StartedAt}}{{end}}' '2026-09-25T10:00:00.1Z'
  _egress_resolve cleat-app-1234abcd
  run echo "$_EG_MODE"
  assert_output "off"
}

@test "egress config: a linked session marker is never read" {
  printf '[egress]\nmode = strict\n' > "$CONF"
  mkdir -p "$CLEAT_CONFIG_DIR/egress-boxes"
  printf '2026-09-25T10:00:00.1Z\n' > "$TEST_TEMP/elsewhere"
  ln -s "$TEST_TEMP/elsewhere" "$CLEAT_CONFIG_DIR/egress-boxes/cleat-app-1234abcd.session"
  mock_docker_inspect_field cleat-app-1234abcd '{{if .State.Running}}{{.State.StartedAt}}{{end}}' '2026-09-25T10:00:00.1Z'
  _egress_resolve cleat-app-1234abcd
  run echo "$_EG_MODE"
  assert_output "strict"
  # Refused before any read: not even the box is asked.
  run grep -c 'inspect' "$DOCKER_CALLS"
  assert_output "0"
}

# ── The policy digest (5.6) ─────────────────────────────────────────────────

@test "egress config: the policy digest is the one the gateway computes" {
  # Vectors computed with the gateway's own formula (docker/gateway/gateway.py).
  run _egress_policy_digest strict "$CORE"
  assert_output "v1:b204c63413ecaad3"
  run _egress_policy_digest open "$CORE"
  assert_output "v1:52a5e335a198bc6a"
  run _egress_policy_digest strict "$CORE
registry.npmjs.org"
  assert_output "v1:ec731f0536661183"
}

@test "egress config: the policy digest ignores host order and duplicates" {
  run _egress_policy_digest strict "platform.claude.com
claude.ai
api.anthropic.com
code.claude.com
claude.com
claude.ai"
  assert_output "v1:b204c63413ecaad3"
}

@test "egress config: a degraded md5 is detected" {
  run _egress_md5_ok
  assert_success
  mkdir -p "$TEST_TEMP/bare-bin"
  PATH="$TEST_TEMP/bare-bin" run _egress_md5_ok
  assert_failure
}

# ── The default (1.1, 11.3) ─────────────────────────────────────────────────

# A launch driven end to end through the stub: a fresh project, no container.
_default_launch() {
  _host_clip_cmd() { echo ""; }
  check_for_update() { true; }
  check_drift() { true; }
  _resolve_config_drift() { true; }
  mkdir -p "$TEST_TEMP/project"
  CN="$(container_name_for "$TEST_TEMP/project")"
  run cmd_start "$TEST_TEMP/project"
}

@test "egress default: no egress section means the box is created with a normal network" {
  rm -f "$CONF"
  [ ! -e "$_EGRESS_BOXES_DIR/$CN" ]
  _default_launch
  assert_success
  local launched="$output" runline
  # Positives first: negatives alone hold when nothing is created at all.
  run grep -F "{{.HostConfig.NetworkMode}}" "$DOCKER_CALLS"
  assert_failure
  run docker_run_line_for "$CN"
  assert_success
  [ -n "$output" ]
  runline="$output"
  run sed $'s/\033\\[[0-9;]*m//g' <<< "$launched"
  assert_output --partial "Egress:     off  ·  full network egress"
  refute_output --partial "saved, not enforced"
  # Then the negatives.
  [[ "$runline" != *"--network"* ]]
  [[ "$runline" != *"--volumes-from"* ]]
  [[ "$runline" != *"cleat-gw-"* ]]
  run grep -E '^docker (run|create) .*cleat-gw-' "$DOCKER_CALLS"
  assert_failure
  run grep -E '^docker volume create' "$DOCKER_CALLS"
  assert_failure
  run grep -E '^docker network' "$DOCKER_CALLS"
  assert_failure
  run grep -E '^docker (image inspect|pull) .*cleat-gw' "$DOCKER_CALLS"
  assert_failure
  run grep -E 'HTTPS_PROXY=|http_proxy=|NO_PROXY=' "$DOCKER_CALLS"
  assert_failure
  # Nothing of a caged box: no dropped capability, no egress label, no socket
  # mount, no gateway exec or copy, no rendered policy on the host.
  local no
  for no in --cap-drop sh.cleat.egress-hash sh.cleat.egress-engine sh.cleat.role /run/cleat-egress; do
    [[ "$runline" != *"$no"* ]]
  done
  run grep -E '^docker exec .*cleat-gw-' "$DOCKER_CALLS"
  assert_failure
  run grep -E '^docker cp ' "$DOCKER_CALLS"
  assert_failure
  [ ! -e "$CLEAT_CONFIG_DIR/egress-rendered" ]
}

@test "egress config: the rendered policy dir does not collide with the egress config path" {
  # $CLEAT_CONFIG_DIR/egress is reserved as no path at all (5.4): the rendered
  # policy lives in its own suffixed directory.
  mock_egress_caged_launch
  mkdir -p "$TEST_TEMP/project"
  CN="$(container_name_for "$TEST_TEMP/project")"
  egress_box_names
  mock_docker_images "cleat"
  caged_box
  _default_launch
  assert_success
  [ -f "$(_egress_policy_dir "$CN")/policy.json" ]
  [ ! -e "$CLEAT_CONFIG_DIR/egress" ]
}

@test "egress default: a saved policy launches the same box and says it is not enforced" {
  printf '[egress]\nmode = strict\n' > "$CONF"
  _default_launch
  assert_success
  run sed $'s/\033\\[[0-9;]*m//g' <<< "$output"
  assert_output --partial "saved, not enforced in this"
  run grep -F "{{.HostConfig.NetworkMode}}" "$DOCKER_CALLS"
  assert_failure
  run docker_run_line_for "$CN"
  [[ "$output" != *"--network"* ]]
}

@test "egress config: the resolved digest is recorded outside every mount source" {
  printf '[egress]\nmode = strict\n' > "$CONF"
  _default_launch
  assert_success
  local ledger src line a
  ledger="$(_egress_ledger_path "$CN")"
  [ -f "$ledger" ]
  run docker_run_line_for "$CN"
  line="$output"
  set -f
  local prev=""
  for a in $line; do
    if [ "$prev" = "-v" ]; then
      src="${a%%:*}"
      case "$ledger/" in "$src"/*)
        echo "ledger $ledger is under the mount source $src" >&2
        set +f
        return 1 ;;
      esac
    fi
    prev="$a"
  done
  set +f
}
