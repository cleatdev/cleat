#!/usr/bin/env bats
# ── Egress hostnames (_egress_valid_host) ────────────────────────────────────
#
# The host-side half of EGRESS-SPEC.md 4.3b. One normalizer, used when a policy
# file is read, when a row is ticked and when the policy is written, and the
# same rules as the gateway's normalize_host. test/fixtures/egress_hosts.tsv is
# the one table both implementations are held to: if they disagreed, a host a
# user allows would never match the name the gateway sees.
load "../setup"
setup() {
  _common_setup
  source_cli
  TABLE="$BATS_TEST_DIRNAME/../fixtures/egress_hosts.tsv"
}
teardown() { _common_teardown; }

@test "egress hostname: the host validator agrees with the shared normalization table" {
  local line input want got rc bad="" n=0
  # Split by hand: tab is IFS whitespace, so `read` would drop the empty
  # input of the first column.
  while IFS= read -r line; do
    case "$line" in \#*) continue ;; esac
    input="${line%%$'\t'*}"
    want="${line#*$'\t'}"
    want="${want%%$'\t'*}"
    n=$((n + 1))
    got="$(_egress_valid_host "$input")" && rc=0 || rc=1
    if [[ "$want" == !* ]]; then
      _egress_valid_host "$input" >/dev/null || true
      if [[ "$rc" -eq 0 || "!$_EG_HOST_REASON" != "$want" ]]; then
        bad+="  [$input] wanted $want, got rc=$rc ${got:-!$_EG_HOST_REASON}"$'\n'
      fi
    elif [[ "$rc" -ne 0 || "$got" != "$want" ]]; then
      bad+="  [$input] wanted $want, got rc=$rc ${got:-}"$'\n'
    fi
  done < "$TABLE"
  run printf '%s' "$bad"
  assert_output ""
  # The table is not vacuous: it has rows for every reason.
  [ "$n" -ge 40 ] || { echo "only $n rows read"; return 1; }
}

@test "egress hostname: uppercase and one trailing dot fold to the name a client sends" {
  run _egress_valid_host "DEB.Debian.ORG."
  assert_success
  assert_output "deb.debian.org"
}

@test "egress hostname: a suffix of an allowed name is its own name, never a match" {
  run _egress_valid_host "github.com.evil.tld"
  assert_success
  assert_output "github.com.evil.tld"
}

@test "egress hostname: a bracket anywhere is refused so no value reads back as a section" {
  run _egress_valid_host "[egress]"
  assert_failure
  assert_output ""
  _egress_valid_host "a]b.example" >/dev/null || true
  run echo "$_EG_HOST_REASON"
  assert_output "BAD_CHARS"
}

@test "egress hostname: an inline comment is part of the value and refused" {
  run _egress_valid_host "github.com # main"
  assert_failure
}

@test "egress hostname: a U-label is refused and its A-label accepted" {
  run _egress_valid_host "ex$(printf '\303\244')mple.com"
  assert_failure
  run _egress_valid_host "xn--exmple-cua.com"
  assert_success
  assert_output "xn--exmple-cua.com"
}

@test "egress hostname: byte length is counted in bytes under a UTF-8 locale" {
  # 254 bytes of ASCII is too long. A 128-character name of two-byte letters is
  # 256 bytes and must not pass as 128 characters.
  local long=""
  local i
  for i in $(seq 1 128); do long+=$(printf '\303\244'); done
  LC_ALL=C.UTF-8 _egress_valid_host "$long.example" >/dev/null || true
  run echo "$_EG_HOST_REASON"
  assert_output "TOO_LONG"
}
