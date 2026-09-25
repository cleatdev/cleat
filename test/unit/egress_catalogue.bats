#!/usr/bin/env bats
# ── Egress catalogue: packs, classes, flags and the evidence pre-ticks ───────
#
# EGRESS-SPEC.md section 7 and the pre-tick rule of 6.4. The catalogue is baked
# into bin/cleat as one tab-delimited record per (pack, host). These tests read
# it through the same functions the editor will, and hold the published copy,
# EGRESS-CATALOGUE.md, to it row for row.
load "../setup"
setup() {
  _common_setup
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
_field() { _egress_catalogue_records | awk -F'\t' -v h="$1" -v f="$2" '$2 == h { print $f; exit }'; }

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
  assert_output --regexp '^ *82$'
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
  want="$(_egress_catalogue_records | while IFS=$'\t' read -r p h c f l cert why; do
    printf '%s|%s|%s|%s\n' "$p" "$h" "$(_egress_class_word "$c" "$f")" "$l"
  done)"
  got="$(grep '^| `' "$PUBLISHED" | awk -F' [|] ' '{
    p=$1; sub(/^[|] /, "", p); gsub(/`/, "", p); h=$2; gsub(/`/, "", h);
    l=$5; sub(/ [|]$/, "", l); print p "|" h "|" $3 "|" l }')"
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
  assert_output "open-tenancy,requires-cap"
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
