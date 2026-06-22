#!/usr/bin/env bats
# Direct tests for _version_ge: dotted-numeric ">=" with any prerelease/build
# suffix stripped. It classifies a pre-stamping image's content from the version
# it was built at (_maybe_prompt_image_rebuild legacy inference), so the compare
# MUST be per-field NUMERIC (sort -t. -k1,1n -k2,2n -k3,3n), never lexical: a
# lexical sort misranks 0.16.10 vs 0.16.3 and 0.9.0 vs 0.16.3, which would
# misclassify an image and either skip a needed refresh or nag a current one.

load "../setup"

setup() { _common_setup; source_cli; }
teardown() { _common_teardown; }

# ── load-bearing: per-field NUMERIC, not lexical ──────────────────────────────

@test "_version_ge: 0.16.10 >= 0.16.3 (multi-digit field, numeric not lexical)" {
  run _version_ge 0.16.10 0.16.3
  assert_success
}

@test "_version_ge: 0.9.0 is NOT >= 0.16.3 (field-2 numeric: 9 < 16)" {
  run _version_ge 0.9.0 0.16.3
  assert_failure
}

@test "_version_ge: 1.0.0 >= 0.16.3 (major bump)" {
  run _version_ge 1.0.0 0.16.3
  assert_success
}

# ── equality and the just-below boundary ──────────────────────────────────────

@test "_version_ge: equal versions are >=" {
  run _version_ge 0.16.3 0.16.3
  assert_success
}

@test "_version_ge: 0.16.2 is NOT >= 0.16.3 (one patch below the anchor)" {
  run _version_ge 0.16.2 0.16.3
  assert_failure
}

# ── suffix handling (prerelease/build stripped before compare) ────────────────

@test "_version_ge: a prerelease suffix is stripped, so X.Y.Z-rc1 equals X.Y.Z" {
  run _version_ge 0.16.3-rc1 0.16.3
  assert_success
}

@test "_version_ge: a build suffix on the right side is stripped too" {
  run _version_ge 0.16.3 0.16.3+build7
  assert_success
}
