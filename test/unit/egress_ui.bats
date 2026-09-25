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
