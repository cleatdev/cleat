#!/usr/bin/env bats
# ─────────────────────────────────────────────────────────────────────────────
# Integration: what the BUILT image does, against REAL Docker.
#
# Asserted on the image, never on the Dockerfile text, which would be a source
# grep. Unlike its siblings, a failed build FAILS this file rather than
# skipping it: every likely mistake in the https switch (a wrong path, the sed
# placed before ca-certificates is installed) surfaces as a failed build, and a
# skip reads as green. Only a missing docker or an unreachable daemon skips.
#
# Tagged apart from the image cleat runs, so this never replaces a user's own.
# ─────────────────────────────────────────────────────────────────────────────

load "../setup"

IMAGE_TEST_TAG="cleat-imagetest"

setup_file() {
  if ! command -v docker &>/dev/null; then
    skip "docker not available"
  fi
  if ! docker info &>/dev/null; then
    skip "docker daemon not reachable"
  fi
  local repo_root _build_log
  repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  _build_log="$(docker build -q -t "$IMAGE_TEST_TAG" -f "$repo_root/docker/Dockerfile" "$repo_root/docker/" 2>&1)" || {
    echo "# docker build failed:" >&3
    echo "$_build_log" | sed 's/^/#   /' >&3
    false
  }
}

teardown_file() {
  docker rmi "$IMAGE_TEST_TAG" >/dev/null 2>&1 || true
}

setup() { _common_setup; }
teardown() { _common_teardown; }

# One root shell in a throwaway container of the built image, entrypoint
# bypassed, nothing mounted.
_in_image() {
  docker run --rm --user root --entrypoint /bin/bash "$IMAGE_TEST_TAG" -c "$1"
}

@test "image: every Debian apt source is https" {
  run _in_image 'cat /etc/apt/sources.list.d/*.sources /etc/apt/sources.list.d/*.list 2>/dev/null | grep -E "^(URIs:|deb )"'
  assert_success
  assert_output --partial "URIs: https://deb.debian.org/debian"
  assert_output --partial "URIs: https://deb.debian.org/debian-security"
  refute_output --partial "http://"
}

@test "image: apt-get update fetches every Debian suite over https with no extra packages" {
  # apt-get update exits 0 even when every source fails to fetch, so the proof
  # is the fetched index and the absence of a fetch failure, never the rc.
  run _in_image 'apt-get update 2>&1; echo "--lists--"; ls /var/lib/apt/lists/; echo "--https--"; dpkg -s apt-transport-https >/dev/null 2>&1 && echo extra || echo none'
  assert_output --partial "https://deb.debian.org/debian bookworm InRelease"
  assert_output --partial "https://deb.debian.org/debian-security bookworm-security InRelease"
  refute_output --partial "http://deb.debian.org"
  refute_output --partial "Failed to fetch"
  refute_output --regexp "(^|[[:space:]])Err:"
  assert_output --partial "deb.debian.org_debian_dists_bookworm_InRelease"
  assert_output --partial "deb.debian.org_debian-security_dists_bookworm-security_InRelease"
  assert_line "none"
}
