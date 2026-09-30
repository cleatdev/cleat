#!/usr/bin/env bats
# ── Egress catalogue: packs, classes, flags and the evidence pre-ticks ───────
#
# EGRESS-SPEC.md section 7 and the pre-tick rule of 6.4. The catalogue is baked
# into bin/cleat as one tab-delimited record per (pack, host). These tests read
# it through the same functions the editor will, and hold the published copy,
# EGRESS-CATALOGUE.md, to it row for row.
load "../setup"
load "../lib/egress_fixtures"
setup() {
  _common_setup
  # The stub, never the host's daemon: a session-marker read runs docker inspect.
  use_docker_stub
  source_cli
  PUBLISHED="$BATS_TEST_DIRNAME/../../EGRESS-CATALOGUE.md"
  PROJECT="$TEST_TEMP/proj"
  mkdir -p "$PROJECT"
}
teardown() { _common_teardown; }

# A project whose [setup] section host trust has approved, through the real
# trust path rather than by setting its globals.
_trusted_setup_project() {
  printf '[setup]\necho hi\n' > "$PROJECT/.cleat"
  CLEAT_TRUST_SETUP=1 resolve_caps "$PROJECT" >/dev/null 2>&1
  unset CLEAT_TRUST_SETUP
}

# One field of the first record for a host: 3 class, 4 flags, 5 legs, 6 cert.
# Reads to the end rather than exiting at the match: an early exit closes the
# pipe on the records' printf, which some runners report as a write error.
_field() { _egress_catalogue_records | awk -F'\t' -v h="$1" -v f="$2" '$2 == h && !d { print $f; d = 1 }'; }

# ── Records (7.1) ────────────────────────────────────────────────────────────

@test "egress catalogue: a pack row carries one class and an audit date" {
  local bad=""
  local pack host cls flags legs cert why
  while IFS=$'\t' read -r pack host cls flags legs cert why; do
    case "$cls" in A|B|C|unaudited) ;; *) bad+="$host: class $cls"$'\n' ;; esac
    case "$legs" in
      "h1+h2, 2026-"[0-9][0-9]-[0-9][0-9]|"h1 only, no h2 offered, 2026-"[0-9][0-9]-[0-9][0-9]) ;;
      unaudited) [ "$cls" = unaudited ] || bad+="$host: unaudited legs with class $cls"$'\n' ;;
      *) bad+="$host: legs $legs"$'\n' ;;
    esac
    [ -n "$why" ] || bad+="$host: no purpose"$'\n'
    case "$host" in
      *"{"*) [ "$cert" = - ] || bad+="$host: a template with a certificate"$'\n' ;;
      *) case "$cert" in [0-9A-F][0-9A-F]:*) ;; *) bad+="$host: cert $cert"$'\n' ;; esac ;;
    esac
  done < <(_egress_catalogue_records)
  run printf '%s' "$bad"
  assert_output ""
  run bash -c 'wc -l' < <(_egress_catalogue_records)
  assert_output --regexp '^ *83$'
}

@test "egress catalogue: an unclassified host renders as unaudited" {
  run _egress_class_word "Z" "-"
  assert_output "unaudited"
  run _egress_class_word "" "-"
  assert_output "unaudited"
  _egress_pack_catalogue() {
    printf 'probe\tprobe.example\tX\t-\th1+h2, 2026-09-21\t00:11\tA crafted record\n'
  }
  run _egress_host_word probe.example
  assert_output "unaudited"
  refute_output "contained"
  run _egress_pack_class probe
  assert_output "unaudited"
}

@test "egress catalogue: every host in every pack is lowercase dot-separated and wildcard-free" {
  local bad="" pack host rest filled
  while IFS=$'\t' read -r pack host rest; do
    case "$host" in
      *"{"*)
        # A parameterised host: one {name} the user fills, the rest a real name.
        case "$host" in
          *"{"*"{"*|*"}"*"}"*) bad+="$host: two placeholders"$'\n'; continue ;;
        esac
        filled="$(printf '%s' "$host" | sed 's/{[a-z][a-z]*}/x/')"
        [ "$(_egress_valid_host "$filled")" = "$filled" ] || bad+="$host"$'\n'
        case ",$(_field "$host" 4)," in *,parameterised,*) ;; *) bad+="$host: not flagged parameterised"$'\n' ;; esac ;;
      *) [ "$(_egress_valid_host "$host")" = "$host" ] || bad+="$host"$'\n' ;;
    esac
  done < <(_egress_catalogue_records)
  run printf '%s' "$bad"
  assert_output ""
}

@test "egress catalogue: an open tenancy row is never auto-ticked" {
  # huggingface.co is Class B by the letter and open tenancy by the flag.
  run _field huggingface.co 3
  assert_output "B"
  run _egress_host_word huggingface.co
  assert_output "open tenancy"
  run _egress_pretick_class_ok "$(_egress_class_word "$(_egress_pack_class huggingface)" "$(_egress_pack_flags huggingface)")"
  assert_failure
}

@test "egress catalogue: two hosts sharing a cert fingerprint tick together" {
  run _egress_cert_siblings api.github.com
  assert_output "api.github.com
codeload.github.com"
  run _egress_cert_siblings github.com
  assert_output "github.com"
}

@test "egress catalogue: every flag token in the shipped catalogue is in the closed set" {
  run _egress_catalogue_records
  assert_success
  local t bad=""
  for t in $(_egress_catalogue_records | cut -f4 | tr ',' '\n' | LC_ALL=C sort -u); do
    [ "$t" = - ] && continue
    case " $_EGRESS_FLAG_TOKENS " in *" $t "*) ;; *) bad+="$t " ;; esac
  done
  run echo "$bad"
  assert_output ""
  # A crafted tenth token is refused, never read with the token dropped.
  _egress_pack_catalogue() {
    printf 'probe\tprobe.example\tB\topen-tenancyy\th1+h2, 2026-09-21\t00:11\tA crafted record\n'
  }
  run _egress_catalogue_records
  assert_failure
  assert_output --partial 'catalogue: unknown flag token "open-tenancyy" on probe/probe.example'
}

@test "egress catalogue: a record's flags follow the closed set's order" {
  local bad="" f t last rank
  while IFS= read -r f; do
    [ "$f" = - ] && continue
    last=0
    for t in $(printf '%s' "$f" | tr ',' ' '); do
      rank=0
      for x in $_EGRESS_FLAG_TOKENS; do rank=$((rank + 1)); [ "$x" = "$t" ] && break; done
      [ "$rank" -gt "$last" ] || bad+="$f "
      last=$rank
    done
  done < <(_egress_catalogue_records | cut -f4)
  run echo "$bad"
  assert_output ""
}

# ── The core pack (7.2) ──────────────────────────────────────────────────────

@test "egress catalogue: the core pack holds exactly five hosts" {
  run _egress_pack_hosts claude all
  assert_output "api.anthropic.com
claude.ai
claude.com
platform.claude.com
code.claude.com"
  local h
  for h in api.anthropic.com claude.ai claude.com platform.claude.com code.claude.com; do
    run _field "$h" 4
    assert_output "core,locked"
  done
}

@test "egress catalogue: the core pack carries an audit date" {
  local h
  for h in $(_egress_pack_hosts claude all); do
    run _field "$h" 5
    assert_output "h1+h2, 2026-09-21"
  done
}

# ── The packs (7.4) ──────────────────────────────────────────────────────────

@test "egress catalogue: the catalogue defines 26 packs beside the locked core" {
  run bash -c 'wc -l' < <(_egress_pack_ids)
  assert_output --regexp '^ *27$'
  run bash -c 'head -1' < <(_egress_pack_ids)
  assert_output "claude"
}

@test "egress catalogue: each pack's class is its weakest default host" {
  # The summary column of 7.4, derived rather than stored.
  local p want
  for p in claude:B github:B github-objects:C github-raw:C gitlab:B atlassian:B \
           azure-devops:B aws:B gcp:C npm:B pypi:C apt-debian:C apt-image-extras:B \
           apt-ubuntu:A debian-mirror:A dotnet:B astral:B azure-cli:B go:B rust:C ruby:C \
           maven:B containers:C homebrew:C huggingface:B playwright:A docs:C; do
    want="${p#*:}"
    run _egress_pack_class "${p%%:*}"
    assert_output "$want"
  done
}

@test "egress catalogue: apt-image-extras covers every apt source the image configures" {
  run _egress_pack_hosts apt-image-extras all
  assert_output --partial "download.docker.com"
  assert_output --partial "cli.github.com"
}

@test "egress catalogue: ticking apt-debian pre-ticks apt-image-extras but not its sub-tick" {
  _trusted_setup_project
  run _egress_detect_packs "$PROJECT"
  assert_output --partial "apt-debian ticked"
  assert_output --partial "apt-image-extras ticked"
  run _egress_pack_hosts apt-image-extras
  assert_output "download.docker.com"
}

@test "egress catalogue: cli.github.com is a sub-tick and never arrives ticked" {
  run _egress_pack_hosts apt-image-extras
  refute_output --partial "cli.github.com"
  run _field cli.github.com 4
  assert_output "default,sub-tick,open-tenancy"
  run _egress_host_word cli.github.com
  assert_output "open tenancy"
}

@test "egress catalogue: the setup pretick resolves to apt-debian and not the mirror" {
  _trusted_setup_project
  run _egress_detect_packs "$PROJECT"
  assert_output --partial "apt-debian ticked"
  refute_output --partial "debian-mirror"
}

@test "egress catalogue: an untrusted setup section only suggests the apt packs" {
  printf '[setup]\necho hi\n' > "$PROJECT/.cleat"
  run _egress_detect_packs "$PROJECT"
  assert_output "apt-debian suggested
apt-image-extras suggested"
}

@test "egress catalogue: debian-mirror carries the no-security flag" {
  run _field debian.osuosl.org 4
  assert_output "no-security"
  run _egress_pack_class debian-mirror
  assert_output "A"
}

@test "egress catalogue: the github pretick excludes the githubusercontent object hosts" {
  mkdir -p "$PROJECT/.git"
  printf '[remote "origin"]\n\turl = git@github.com:acme/app.git\n' > "$PROJECT/.git/config"
  run _egress_detect_packs "$PROJECT"
  assert_output "github ticked"
  run _egress_pack_hosts github all
  assert_output "github.com
api.github.com
codeload.github.com
uploads.github.com"
}

@test "egress catalogue: every host on the 71:F1 certificate renders open tenancy" {
  local h n=0
  for h in $(_egress_cert_siblings raw.githubusercontent.com); do
    n=$((n + 1))
    run _egress_host_word "$h"
    assert_output "open tenancy"
  done
  [ "$n" -eq 6 ] || { echo "the certificate group has $n names, not 6"; return 1; }
}

@test "egress catalogue: the published catalogue file matches the shipped table row for row" {
  local want got
  # The flags too: the published column is each token in backticks.
  want="$(_egress_catalogue_records | while IFS=$'\t' read -r p h c f l cert why; do
    fl=""
    [ "$f" = - ] || fl="\`${f//,/\` \`}\`"
    printf '%s|%s|%s|%s|%s\n' "$p" "$h" "$(_egress_class_word "$c" "$f")" "$fl" "$l"
  done)"
  got="$(grep '^| `' "$PUBLISHED" | awk -F' [|] ' '{
    p=$1; sub(/^[|] /, "", p); gsub(/`/, "", p); h=$2; gsub(/`/, "", h);
    f=$4; sub(/^ +/, "", f); sub(/ +$/, "", f);
    l=$5; sub(/ [|]$/, "", l); print p "|" h "|" $3 "|" f "|" l }')"
  run diff <(printf '%s\n' "$want") <(printf '%s\n' "$got")
  assert_success
  assert_output ""
  run grep -c 'https://github.com/cleatdev/cleat/issues' "$PUBLISHED"
  assert_output "1"
}

# ── Evidence pre-ticks (6.4) ─────────────────────────────────────────────────

@test "egress catalogue: evidence ticks a contained pack and only suggests a shared one" {
  : > "$PROJECT/package.json"
  : > "$PROJECT/go.mod"
  : > "$PROJECT/requirements.txt"
  : > "$PROJECT/Cargo.toml"
  run _egress_detect_packs "$PROJECT"
  assert_output "npm ticked
go ticked
pypi suggested
rust suggested"
}

@test "egress catalogue: a project with no evidence pre-ticks nothing" {
  run _egress_detect_packs "$PROJECT"
  assert_output ""
  run _egress_detect_packs ""
  assert_output ""
}

@test "egress catalogue: a linked git config is never read for evidence" {
  mkdir -p "$PROJECT/.git"
  printf '[remote "origin"]\n\turl = https://github.com/acme/app\n' > "$TEST_TEMP/elsewhere"
  ln -s "$TEST_TEMP/elsewhere" "$PROJECT/.git/config"
  run _egress_detect_packs "$PROJECT"
  refute_output --partial "github"
}

@test "egress catalogue: a remote that only mentions github elsewhere in its URL is not evidence" {
  mkdir -p "$PROJECT/.git"
  local u
  for u in https://gitlab.com/acme/github.com/x https://gitlab.com/github.com:x \
           git@gitlab.com:acme/github.com.git https://github.com.evil.example/acme/app; do
    printf '[remote "origin"]\n\turl = %s\n' "$u" > "$PROJECT/.git/config"
    run _egress_detect_packs "$PROJECT"
    refute_output --partial "github"
  done
}

@test "egress catalogue: every spelling of a github remote is evidence" {
  mkdir -p "$PROJECT/.git"
  local u
  for u in https://github.com/acme/app https://GitHub.com/acme/app.git git@github.com:acme/app.git \
           ssh://git@github.com:22/acme/app.git https://user:tok@github.com/acme/app github.com:acme/app; do
    printf '[core]\n\tbare = false\n[remote "origin"]\n\turl = %s\n' "$u" > "$PROJECT/.git/config"
    run _egress_detect_packs "$PROJECT"
    assert_output "github ticked"
  done
}

@test "egress catalogue: a parameterised host is never in a pack's default set" {
  run _egress_pack_hosts atlassian
  refute_output --partial "{site}"
  run _egress_pack_hosts aws
  assert_output "sts.amazonaws.com
s3.amazonaws.com"
  run _egress_pack_hosts aws all
  assert_output --partial "sts.{region}.amazonaws.com"
}

@test "egress catalogue: an unaudited default host makes the whole pack unaudited" {
  _egress_pack_catalogue() {
    printf 'probe\ta.example\tB\t-\th1+h2, 2026-09-21\t00:11\tOne\n'
    printf 'probe\tb.example\tunaudited\t-\tunaudited\t00:22\tTwo\n'
    printf 'probe\tc.example\tA\t-\th1+h2, 2026-09-21\t00:33\tThree\n'
  }
  run _egress_pack_class probe
  assert_output "unaudited"
}

@test "egress catalogue: a pack's flags are the union in the closed-set order" {
  run _egress_pack_flags containers
  assert_output "open-tenancy"
  run _egress_pack_flags github-objects
  assert_output "sub-tick,open-tenancy"
  run _egress_pack_flags claude
  assert_output "core,locked"
  run _egress_pack_flags github
  assert_output ""
}

@test "egress catalogue: a host with no certificate is its own only sibling" {
  run _egress_cert_siblings "{site}.atlassian.net"
  assert_output "{site}.atlassian.net"
}

@test "egress catalogue: the evidence table only ever suggests pypi and rust, whatever their class" {
  # Even a pypi or rust measured contained is shown as a suggestion: the
  # evidence table says so on its own, not only through the class predicate.
  eval "_real_catalogue() $(declare -f _egress_pack_catalogue | sed 1d)"
  _egress_pack_catalogue() {
    _real_catalogue | awk -F'\t' 'BEGIN { OFS = "\t" } $1 == "pypi" || $1 == "rust" { $3 = "B"; $4 = "-" } { print }'
  }
  run _egress_pack_class pypi
  assert_output "B"
  : > "$PROJECT/requirements.txt"
  : > "$PROJECT/Cargo.toml"
  run _egress_detect_packs "$PROJECT"
  assert_output "pypi suggested
rust suggested"
}

# ── The pin (7.5) ────────────────────────────────────────────────────────────

@test "egress pin: bumping the catalogue rev alone does not change the pin digest" {
  local pinned before after
  pinned="$(printf 'api.anthropic.com B\nclaude.ai B\n')"
  before="$(_egress_pin_digest "$pinned")"
  _EGRESS_CATALOGUE_REV=99
  # The shipped expansion gains a host, but the pinned expansion is what the
  # digest hashes, and nothing re-pinned it.
  after="$(_egress_pin_digest "$pinned")"
  assert_equal "$after" "$before"
  assert_equal "$before" "v1:012a9448696213e5"
}

@test "egress pin: the pin digest ignores the order the hosts arrive in" {
  run _egress_pin_digest "$(printf 'claude.ai B\napi.anthropic.com B\nclaude.ai B\n')"
  assert_output "v1:012a9448696213e5"
}

@test "egress pin: re-pinning at a new rev changes the digest" {
  local before after
  before="$(_egress_pin_digest "$(printf 'api.anthropic.com B\nclaude.ai B\n')")"
  after="$(_egress_pin_digest "$(printf 'api.anthropic.com B\nclaude.ai B\nnew.example B\n')")"
  [ "$before" != "$after" ] || { echo "a re-pin with a new host kept the digest"; return 1; }
}

@test "egress pin: a deny that removes nothing effective does not change the digest" {
  printf '[egress]\nmode = strict\npack = npm\n' > "$CLEAT_GLOBAL_CONFIG"
  _egress_resolve cleat-app-1234abcd
  local a="$_EG_HOSTS"
  printf '[egress]\nmode = strict\npack = npm\ndeny = never-allowed.example\n' > "$CLEAT_GLOBAL_CONFIG"
  _egress_resolve cleat-app-1234abcd
  assert_equal "$(_egress_policy_digest strict "$_EG_HOSTS")" "$(_egress_policy_digest strict "$a")"
}

@test "egress pin: a class move with no host move changes the digest" {
  local b c
  b="$(_egress_pin_digest "raw.githubusercontent.com B")"
  c="$(_egress_pin_digest "raw.githubusercontent.com C")"
  [ "$b" != "$c" ] || { echo "a class move kept the digest"; return 1; }
}

_pin_fixture() {
  mkdir -p "$CLEAT_CONFIG_DIR/egress-pins"
  PIN="$CLEAT_CONFIG_DIR/egress-pins/global"
  _egress_write_pin "$PIN" 1 2026-09-21 v1:0000000000000000 "$@"
  SHIPPED="$TEST_TEMP/shipped"
}

@test "egress pin: a class downgrade holds and is named on the launch summary" {
  _pin_fixture "raw.githubusercontent.com B" "api.anthropic.com B"
  printf 'raw.githubusercontent.com C\napi.anthropic.com B\n' > "$SHIPPED"
  run _egress_pin_diff "$PIN" "$SHIPPED"
  assert_output "weakened	raw.githubusercontent.com	B	C"
  run _egress_pin_summary "$(_egress_pin_diff "$PIN" "$SHIPPED")"
  assert_output "1 host you allowed is now shared: raw.githubusercontent.com. Run cleat egress review."
}

@test "egress pin: a newly set open tenancy flag is a downgrade" {
  _pin_fixture "huggingface.co B"
  printf 'huggingface.co B open-tenancy\n' > "$SHIPPED"
  run _egress_pin_diff "$PIN" "$SHIPPED"
  assert_output "weakened	huggingface.co	B	B open-tenancy"
  run _egress_pin_summary "$output"
  assert_output "1 host you allowed is now open tenancy: huggingface.co. Run cleat egress review."
}

@test "egress pin: a class upgrade applies with no summary line" {
  _pin_fixture "debian.osuosl.org B"
  printf 'debian.osuosl.org A\n' > "$SHIPPED"
  run _egress_pin_diff "$PIN" "$SHIPPED"
  assert_output "strengthened	debian.osuosl.org	B	A"
  run _egress_pin_summary "$output"
  assert_output ""
}

@test "egress pin: additions are held and named by pack, removals are counted" {
  _pin_fixture "github.com B" "api.github.com B" "gone.example B" "gone2.example C"
  printf 'github.com B\napi.github.com B\ncodeload.github.com B\nuploads.github.com B\nregistry.npmjs.org B\n' > "$SHIPPED"
  run _egress_pin_summary "$(_egress_pin_diff "$PIN" "$SHIPPED")"
  assert_output '2 new hosts in pack "github" held. Run cleat egress review.
1 new host in pack "npm" held. Run cleat egress review.
2 hosts left the packs you use and no longer reach the box.'
}

@test "egress pin: an unchanged expansion diffs to nothing" {
  _pin_fixture "github.com B" "claude.ai B"
  printf 'claude.ai B\ngithub.com B\n' > "$SHIPPED"
  run _egress_pin_diff "$PIN" "$SHIPPED"
  assert_output ""
}

@test "egress pin: the pin file is its own canonical form" {
  _pin_fixture "zeta.example B" "alpha.example C" "alpha.example C"
  run cat "$PIN"
  assert_output "[pin]
catalogue_rev = 1
pinned_at = 2026-09-21
digest = v1:0000000000000000
host = alpha.example C
host = zeta.example B"
  run _read_section_from_file "$PIN" pin catalogue_rev
  assert_output "1"
}

@test "egress pin: the pin writer refuses a pin path that is a symlink to a directory" {
  mkdir -p "$TEST_TEMP/victim" "$CLEAT_CONFIG_DIR/egress-pins"
  ln -s "$TEST_TEMP/victim" "$CLEAT_CONFIG_DIR/egress-pins/global"
  run _egress_write_pin "$CLEAT_CONFIG_DIR/egress-pins/global" 1 2026-09-21 v1:0 "a.example B"
  assert_failure
  run ls -A "$TEST_TEMP/victim"
  assert_output ""
}

@test "egress pin: the pin writer accepts a pin path that is a symlink to a regular file" {
  mkdir -p "$CLEAT_CONFIG_DIR/egress-pins"
  : > "$TEST_TEMP/pinfile"
  ln -s "$TEST_TEMP/pinfile" "$CLEAT_CONFIG_DIR/egress-pins/global"
  run _egress_write_pin "$CLEAT_CONFIG_DIR/egress-pins/global" 1 2026-09-21 v1:0 "a.example B"
  assert_success
  run _read_section_all_from_file "$CLEAT_CONFIG_DIR/egress-pins/global" pin host
  assert_output "a.example B"
}

@test "egress pin: a class key carries open tenancy when the flag is set" {
  run _egress_pin_class_key huggingface.co
  assert_output "B open-tenancy"
  run _egress_pin_class_key github.com
  assert_output "B"
  run _egress_pin_class_key not-in-the-catalogue.example
  assert_output "unaudited"
}

# ── The pin, wired (7.5) ────────────────────────────────────────────────────
# The launch writes the pin, the resolution reads it and never writes it, and
# review is the only way a held addition gets in. Rev 1 holds nothing, so
# these tests bump the rev in the sourced environment, the way a later
# release would.

# A caged box of this project under a strict policy, its gateway answering the
# digest of whatever the resolution is when caged_box runs.
pin_box() {
  mock_egress_caged_launch
  mkdir -p "$TEST_TEMP/project"
  cd "$TEST_TEMP/project"
  CN="$(container_name_for "$TEST_TEMP/project" main)"
  egress_box_names
  container_exists() { return 0; }
  is_running() { return 0; }
  _RESOLVED_PROJECT="$TEST_TEMP/project"
  GPIN="$CLEAT_CONFIG_DIR/egress-pins/global"
}

# The pin a user accepted earlier: the core pack and the github pack as the
# catalogue has them, less any host named in $PIN_MISSING, at rev 1.
old_pin() {
  local lines="" h
  for h in $(_egress_pack_hosts claude all) $(_egress_pack_hosts github); do
    case " ${PIN_MISSING:-} " in *" $h "*) continue ;; esac
    lines+="$h $(_egress_pin_class_key "$h")"$'\n'
  done
  lines+="${PIN_EXTRA:-}"
  local args=() l
  while IFS= read -r l; do [ -n "$l" ] && args+=("$l"); done <<< "$lines"
  _egress_write_pin "$GPIN" 1 2026-09-01 "$(_egress_pin_digest "$lines")" "${args[@]}"
}

@test "egress pin: the first launch under a policy writes the pin at the shipped rev" {
  pin_box
  printf '[egress]\nmode = strict\npack = github\nallow = typed.example\n' > "$CLEAT_GLOBAL_CONFIG"
  caged_box
  [ ! -e "$GPIN" ]
  _egress_require "$CN" claude
  assert_equal "$_EG_CAGED" 1
  assert_equal "$_EG_PIN_NOTE" first
  run _read_section_from_file "$GPIN" pin catalogue_rev
  assert_output "$_EGRESS_CATALOGUE_REV"
  run _read_section_from_file "$GPIN" pin pinned_at
  assert_output "$(date +%Y-%m-%d)"
  # The packs' hosts with their class keys, never the host the user typed.
  local want
  want="$(_egress_pin_lines "$(printf '%s\n' $(_egress_pack_hosts claude all) $(_egress_pack_hosts github) | LC_ALL=C sort -u)")"
  run _read_section_all_from_file "$GPIN" pin host
  assert_output "$want"
  refute_output --partial "typed.example"
  run _read_section_from_file "$GPIN" pin digest
  assert_output "$(_egress_pin_digest "$want")"
  run bash -c 'ls -l "$1" | cut -c1-10' _ "$GPIN"
  assert_output "-rw-------"
  # The next launch, a new process, finds it and says nothing.
  cp "$GPIN" "$TEST_TEMP/before"
  _EG_PIN_NOTE_CN=""
  _egress_require "$CN" claude
  assert_equal "$_EG_PIN_NOTE" ""
  run cmp "$GPIN" "$TEST_TEMP/before"
  assert_success
}

@test "egress pin: a box with its own file pins on its own" {
  pin_box
  mkdir -p "$_EGRESS_BOXES_DIR"
  printf '[egress]\nallow = own.example\n' > "$_EGRESS_BOXES_DIR/$CN"
  run _egress_pin_file "$CN"
  assert_output "$CLEAT_CONFIG_DIR/egress-pins/$CN"
  run _egress_pin_file cleat-other-12345678
  assert_output "$GPIN"
  run _egress_pin_file ""
  assert_output "$GPIN"
  caged_box
  _egress_require "$CN" claude
  [ -f "$CLEAT_CONFIG_DIR/egress-pins/$CN" ]
  [ ! -e "$GPIN" ]
}

@test "egress pin: at the shipped rev a pin changes nothing the resolution gives" {
  pin_box
  printf '[egress]\nmode = strict\npack = github\n' > "$CLEAT_GLOBAL_CONFIG"
  _egress_resolve "$CN"
  local bare="$_EG_HOSTS"
  # A pin missing a host at the same rev: the difference is the user's own.
  PIN_MISSING="uploads.github.com" old_pin
  _egress_resolve "$CN"
  assert_equal "$_EG_HOSTS" "$bare"
  assert_equal "$_EG_HELD" ""
  assert_equal "$_EG_PIN_DIFF" ""
}

@test "egress pin: a pack host added after the pin is held out of the resolution" {
  pin_box
  printf '[egress]\nmode = strict\npack = github\n' > "$CLEAT_GLOBAL_CONFIG"
  PIN_MISSING="uploads.github.com" old_pin
  _EGRESS_CATALOGUE_REV=2
  _egress_resolve "$CN"
  run printf '%s\n' "$_EG_HOSTS"
  refute_line "uploads.github.com"
  assert_line "github.com"
  assert_equal "$_EG_HELD" "uploads.github.com"
  run printf '%s' "$_EG_PIN_DIFF"
  assert_output "added	uploads.github.com	-	B"
  # What the gateway is asked to enforce is the pinned expansion.
  _egress_render_policy "$CN" "$_EG_MODE" "$_EG_HOSTS"
  run cat "$(_egress_policy_dir "$CN")/policy.json"
  refute_output --partial "uploads.github.com"
  assert_output --partial '"github.com"'
}

@test "egress pin: an addition the user allows by name is not held" {
  pin_box
  printf '[egress]\nmode = strict\npack = github\nallow = uploads.github.com\n' > "$CLEAT_GLOBAL_CONFIG"
  PIN_MISSING="uploads.github.com" old_pin
  _EGRESS_CATALOGUE_REV=2
  _egress_resolve "$CN"
  run printf '%s\n' "$_EG_HOSTS"
  assert_line "uploads.github.com"
  assert_equal "$_EG_HELD" ""
  assert_equal "$_EG_PIN_DIFF" ""
}

@test "egress pin: a held launch runs on the pinned hosts and rewrites nothing" {
  pin_box
  printf '[egress]\nmode = strict\npack = github\n' > "$CLEAT_GLOBAL_CONFIG"
  PIN_MISSING="uploads.github.com" old_pin
  _EGRESS_CATALOGUE_REV=2
  caged_box
  cp "$GPIN" "$TEST_TEMP/before"
  _egress_require "$CN" claude </dev/null
  assert_equal "$_EG_CAGED" 1
  run cmp "$GPIN" "$TEST_TEMP/before"
  assert_success
  run _egress_summary_pin_lines
  assert_output --partial '1 new host in pack "github" held. Run cleat egress review.'
}

@test "egress pin: a moved rev with nothing held re-pins and counts the removals" {
  pin_box
  printf '[egress]\nmode = strict\npack = github\n' > "$CLEAT_GLOBAL_CONFIG"
  PIN_EXTRA=$'gone.example B\n' old_pin
  _EGRESS_CATALOGUE_REV=2
  caged_box
  _egress_require "$CN" claude
  assert_equal "$_EG_CAGED" 1
  run _read_section_from_file "$GPIN" pin catalogue_rev
  assert_output "2"
  run _read_section_all_from_file "$GPIN" pin host
  refute_output --partial "gone.example"
  run _egress_summary_pin_lines
  assert_output --partial "1 host left the packs you use and no longer reaches the box."
  refute_output --partial "held"
}

@test "egress pin: a user's own new pack at the shipped rev re-pins silently" {
  pin_box
  old_pin
  printf '[egress]\nmode = strict\npack = github\npack = npm\n' > "$CLEAT_GLOBAL_CONFIG"
  caged_box
  _egress_require "$CN" claude
  assert_equal "$_EG_CAGED" 1
  assert_equal "$_EG_PIN_NOTE" ""
  run _read_section_all_from_file "$GPIN" pin host
  assert_output --partial "registry.npmjs.org"
  run _egress_summary_pin_lines
  assert_output ""
}

@test "egress pin: a held Claude host refuses a strict launch and names review" {
  pin_box
  printf '[egress]\nmode = strict\npack = github\n' > "$CLEAT_GLOBAL_CONFIG"
  PIN_MISSING="code.claude.com" old_pin
  _EGRESS_CATALOGUE_REV=2
  caged_box
  run _egress_require "$CN" claude
  assert_failure
  assert_output --partial "this release adds a Claude host that its pin holds for review"
  assert_output --partial "cleat egress review"
  # Open reaches every host, so nothing a pin holds can starve it.
  printf '[egress]\nmode = open\npack = github\n' > "$CLEAT_GLOBAL_CONFIG"
  rm -rf "$DOCKER_MOCK_DIR/inspect"
  caged_box
  _egress_require "$CN" claude
  assert_equal "$_EG_CAGED" 1
}

@test "egress pin: a pin that cannot be written refuses the launch" {
  pin_box
  mkdir -p "$TEST_TEMP/victim" "$CLEAT_CONFIG_DIR/egress-pins"
  ln -s "$TEST_TEMP/victim" "$GPIN"
  caged_box
  run _egress_require "$CN" claude
  assert_failure
  assert_output --partial "cleat could not write its egress pin"
  run ls -A "$TEST_TEMP/victim"
  assert_output ""
}

@test "egress pin: a comparison that cannot be made refuses rather than widening" {
  pin_box
  printf '[egress]\nmode = strict\npack = github\n' > "$CLEAT_GLOBAL_CONFIG"
  PIN_MISSING="uploads.github.com" old_pin
  _EGRESS_CATALOGUE_REV=2
  caged_box
  TMPDIR="$TEST_TEMP/no-such-dir" _egress_resolve "$CN"
  assert_equal "$_EG_PIN_BROKEN" 1
  TMPDIR="$TEST_TEMP/no-such-dir" run _egress_require "$CN" claude
  assert_failure
  assert_output --partial "could not compare its egress pin"
}

@test "egress pin: status names the held hosts" {
  pin_box
  printf '[egress]\nmode = strict\npack = github\n' > "$CLEAT_GLOBAL_CONFIG"
  PIN_MISSING="uploads.github.com" PIN_EXTRA="" old_pin
  # A host the pin accepted at a stronger class than the catalogue gives now.
  sed -i.bak 's/^host = github.com B$/host = github.com A/' "$GPIN"
  _EGRESS_CATALOGUE_REV=2
  caged_box
  run _egress_status_render "$CN"
  assert_success
  run _plain "$output"
  assert_output --partial "Held:      github.com (now contained), uploads.github.com (new)"
  assert_output --partial "cleat egress review"
  # Open holds nothing back from the box, so status claims nothing is held.
  printf '[egress]\nmode = open\npack = github\n' > "$CLEAT_GLOBAL_CONFIG"
  run _egress_status_render "$CN"
  run _plain "$output"
  refute_output --partial "Held:"
}

@test "egress review: nothing held says so and writes nothing" {
  pin_box
  printf '[egress]\nmode = strict\npack = github\n' > "$CLEAT_GLOBAL_CONFIG"
  run _egress_cmd_review "$CN" 0 </dev/null
  assert_success
  assert_output --partial "Nothing is held. There is no pin yet"
  [ ! -e "$GPIN" ]
  old_pin
  cp "$GPIN" "$TEST_TEMP/before"
  run _egress_cmd_review "$CN" 0 </dev/null
  assert_success
  assert_output --partial "Nothing is held. Pinned at catalogue rev 1 on 2026-09-01."
  run cmp "$GPIN" "$TEST_TEMP/before"
  assert_success
}

@test "egress review: a pipe without --yes refuses" {
  pin_box
  printf '[egress]\nmode = strict\npack = github\n' > "$CLEAT_GLOBAL_CONFIG"
  PIN_MISSING="uploads.github.com" old_pin
  _EGRESS_CATALOGUE_REV=2
  cp "$GPIN" "$TEST_TEMP/before"
  run _egress_cmd_review "$CN" 0 </dev/null
  assert_failure
  run _plain "$output"
  assert_output --partial "+ uploads.github.com   pack github"
  assert_output --partial "needs a terminal"
  assert_output --partial "cleat egress review --yes"
  run cmp "$GPIN" "$TEST_TEMP/before"
  assert_success
}

@test "egress review: accepting re-pins rev, date, digest and hosts in one write" {
  pin_box
  printf '[egress]\nmode = strict\npack = github\n' > "$CLEAT_GLOBAL_CONFIG"
  PIN_MISSING="uploads.github.com" old_pin
  _EGRESS_CATALOGUE_REV=2
  eval "_real_write_pin() $(declare -f _egress_write_pin | sed 1d)"
  _egress_write_pin() { echo write >> "$TEST_TEMP/writes"; _real_write_pin "$@"; }
  _egress_apply_now() { echo "apply [$1]" >> "$TEST_TEMP/applied"; }
  run _egress_cmd_review "$CN" 1 </dev/null
  assert_success
  assert_output --partial "Re-pinned at catalogue rev 2."
  run cat "$TEST_TEMP/writes"
  assert_output "write"
  run _read_section_from_file "$GPIN" pin catalogue_rev
  assert_output "2"
  run _read_section_from_file "$GPIN" pin pinned_at
  assert_output "$(date +%Y-%m-%d)"
  local want
  want="$(_egress_pin_lines "$(printf '%s\n' $(_egress_pack_hosts claude all) $(_egress_pack_hosts github) | LC_ALL=C sort -u)")"
  run _read_section_all_from_file "$GPIN" pin host
  assert_output "$want"
  run _read_section_from_file "$GPIN" pin digest
  assert_output "$(_egress_pin_digest "$want")"
  # The machine's pin reaches every running caged box.
  run cat "$TEST_TEMP/applied"
  assert_output "apply []"
  # And the host is in the resolution now.
  _egress_resolve "$CN"
  assert_equal "$_EG_HELD" ""
  run printf '%s\n' "$_EG_HOSTS"
  assert_line "uploads.github.com"
}

@test "egress review: declining writes nothing" {
  pin_box
  printf '[egress]\nmode = strict\npack = github\n' > "$CLEAT_GLOBAL_CONFIG"
  PIN_MISSING="uploads.github.com" old_pin
  _EGRESS_CATALOGUE_REV=2
  cp "$GPIN" "$TEST_TEMP/before"
  _egress_on_terminal() { return 0; }
  _egress_apply_now() { echo applied >> "$TEST_TEMP/applied"; }
  run _egress_cmd_review "$CN" 0 <<< "n"
  assert_success
  assert_output --partial "Nothing changed. They stay held."
  run cmp "$GPIN" "$TEST_TEMP/before"
  assert_success
  [ ! -f "$TEST_TEMP/applied" ]
  # An empty answer is a no: accepting widens.
  run _egress_cmd_review "$CN" 0 <<< ""
  run cmp "$GPIN" "$TEST_TEMP/before"
  assert_success
  run _egress_cmd_review "$CN" 0 <<< "y"
  assert_success
  run _read_section_from_file "$GPIN" pin catalogue_rev
  assert_output "2"
}

@test "egress review: a box's own pin applies to that box alone" {
  pin_box
  printf '[egress]\nmode = strict\npack = github\n' > "$CLEAT_GLOBAL_CONFIG"
  mkdir -p "$_EGRESS_BOXES_DIR"
  printf '[egress]\nallow = own.example\n' > "$_EGRESS_BOXES_DIR/$CN"
  GPIN="$CLEAT_CONFIG_DIR/egress-pins/$CN" PIN_MISSING="uploads.github.com" old_pin
  _EGRESS_CATALOGUE_REV=2
  _egress_apply_now() { echo "apply [$1]" >> "$TEST_TEMP/applied"; }
  run _egress_cmd_review "$CN" 1 </dev/null
  assert_success
  run cat "$TEST_TEMP/applied"
  assert_output "apply [$CN]"
  [ ! -e "$CLEAT_CONFIG_DIR/egress-pins/global" ]
}

@test "egress review: a weakened host shows both classes and its residual" {
  pin_box
  printf '[egress]\nmode = strict\npack = github-raw\n' > "$CLEAT_GLOBAL_CONFIG"
  PIN_EXTRA=$'raw.githubusercontent.com B\n' old_pin
  printf '[egress]\nmode = strict\npack = github\npack = github-raw\n' > "$CLEAT_GLOBAL_CONFIG"
  _EGRESS_CATALOGUE_REV=2
  run _egress_cmd_review "$CN" 0 </dev/null
  run _plain "$output"
  assert_output --partial "! raw.githubusercontent.com   contained -> open tenancy   measured h1+h2, 2026-09-21"
  assert_output --partial "the operator serves content its users upload"
}

@test "egress pin: a box's own file never releases what the machine's pin holds" {
  pin_box
  printf '[egress]\nmode = strict\npack = github\n' > "$CLEAT_GLOBAL_CONFIG"
  PIN_MISSING="uploads.github.com" old_pin
  _EGRESS_CATALOGUE_REV=2
  # A box file that only narrows.
  mkdir -p "$_EGRESS_BOXES_DIR"
  printf '[egress]\ndeny = some.example\n' > "$_EGRESS_BOXES_DIR/$CN"
  _egress_resolve "$CN"
  assert_equal "$_EG_HELD" "uploads.github.com"
  run printf '%s\n' "$_EG_HOSTS"
  refute_line "uploads.github.com"
  # Its first own pin is the machine's, at the old rev, holding the same.
  caged_box
  _egress_require "$CN" claude
  assert_equal "$_EG_CAGED" 1
  local bpin="$CLEAT_CONFIG_DIR/egress-pins/$CN"
  run _read_section_from_file "$bpin" pin catalogue_rev
  assert_output "1"
  run _read_section_all_from_file "$bpin" pin host
  refute_output --partial "uploads.github.com"
  refute_output --partial "some.example"
  assert_equal "$_EG_PIN_NOTE" ""
  # Review reads the same pin.
  run _egress_cmd_review "$CN" 0 </dev/null
  run _plain "$output"
  assert_output --partial "+ uploads.github.com"
}

@test "egress pin: what a launch's first gate saw survives its second gate" {
  pin_box
  printf '[egress]\nmode = strict\npack = github\n' > "$CLEAT_GLOBAL_CONFIG"
  PIN_EXTRA=$'gone.example B\n' old_pin
  _EGRESS_CATALOGUE_REV=2
  caged_box
  # cmd_run's gate re-pins, then cmd_start's own gate finds the new pin.
  _egress_require "$CN" run
  _egress_resolve "$CN"
  rm -rf "$DOCKER_MOCK_DIR/inspect" "$DOCKER_MOCK_DIR/gwadmin"
  use_gw_admin_stub
  caged_box
  _egress_require "$CN" start
  run _egress_summary_pin_lines
  assert_output --partial "1 host left the packs you use and no longer reaches the box."
  # Another box starts over.
  _egress_pin_launch cleat-other-12345678
  run _egress_summary_pin_lines
  refute_output --partial "left the packs"
}
