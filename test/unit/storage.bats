#!/usr/bin/env bats
# `cleat storage`: a read-only, cross-OS breakdown of the shared Docker store.
# Honest attribution (cleat images + boxes vs shared build cache vs other
# projects), a cap-relative fill bar, and engine-correct host-space guidance.
# Read-only by construction: docker system df runs on demand here, never on the
# start path, and nothing is ever deleted.

load "../setup"

setup() {
  _common_setup
  use_docker_stub
  source_cli
  _has_unicode() { return 1; }
  _disk_help_kind() { echo desktop; }
  _cleat_prunable_stats() { printf '3\t7168'; }   # ~7 GB reclaimable cleat images
}
teardown() { _common_teardown; }

_stub_storage_docker() {
  # One docker() override covering the three read shapes cmd_storage issues.
  docker() {
    case "$*" in
      *"system df"*)
        printf 'Images\t36.34GB\t20.71GB (57%%)\nContainers\t0.9GB\t0.9GB (100%%)\nLocal Volumes\t6.1GB\t6.1GB (100%%)\nBuild Cache\t7.8GB\t5.4GB (69%%)\n' ;;
      *"images"*) printf 'aaa\naaa\nbbb\n' ;;   # dedup -> 2 images
      *"ps -a"*)  printf 'cleat-foo\ncleat-bar\n' ;;
      *) : ;;
    esac
  }
}

@test "storage: refuses when the daemon is down" {
  _daemon_up() { return 1; }
  run cmd_storage
  assert_failure
  assert_output --partial "not running"
}

@test "storage: renders the fill bar with the cap-relative percent" {
  _daemon_up() { return 0; }
  _storage_fill() { echo "31457280 62914560 50"; }   # 30 / 60 GB, 50%
  _stub_storage_docker
  run cmd_storage
  assert_success
  assert_output --partial "Docker storage"
  assert_output --partial "50% full"
  assert_output --partial "30 GB"
  assert_output --partial "60 GB"
}

@test "storage: shows the three honest groups and both levers" {
  _daemon_up() { return 0; }
  _storage_fill() { echo "31457280 62914560 50"; }
  _stub_storage_docker
  run cmd_storage
  assert_success
  assert_output --partial "On disk"
  assert_output --partial "Build cache (shared)"
  assert_output --partial "Cleat's share"
  assert_output --partial "Cleat can reclaim"
  assert_output --partial "cleat prune"
  assert_output --partial "cleat prune --cache"
  assert_output --partial "all projects"
  assert_output --partial "Other projects hold the rest"
}

@test "storage: counts cleat images deduped by id and boxes by name" {
  _daemon_up() { return 0; }
  _storage_fill() { echo "31457280 62914560 50"; }
  _stub_storage_docker
  run cmd_storage
  assert_success
  # 3 image rows, two share an id -> 2 unique images, 2 boxes
  assert_output --partial "2 images, 2 boxes"
}

@test "storage: degrades gracefully when no box is up to read fill" {
  _daemon_up() { return 0; }
  _storage_fill() { echo ""; }
  _stub_storage_docker
  run cmd_storage
  assert_success
  assert_output --partial "start a box to read live fill"
  # the category table still renders (it needs no running container)
  assert_output --partial "On disk"
}

# The closing two lines are ONE paragraph: where the rest of the disk went, then
# how to get space back. They must share the 2-space prose indent and sit on
# consecutive lines. Elsewhere (advisory, gate, ENOSPC) the same lever keeps the
# 4-space notice indent, so the shared helper has to take the indent, not pick one.
@test "storage: the closing lever lines up with the prose above it, no blank between" {
  _daemon_up() { return 0; }
  _storage_fill() { echo "31457280 62914560 50"; }
  _stub_storage_docker
  run cmd_storage
  assert_success
  local plain prev_i i=0 found=0
  while IFS= read -r plain; do
    plain="$(printf '%s' "$plain" | sed $'s/\033\\[[0-9;]*m//g')"
    case "$plain" in
      "  Other projects hold the rest"*) prev_i=$i ;;
      "  Docker Desktop: reclaim with"*)
        [[ -n "${prev_i:-}" && $i -eq $((prev_i + 1)) ]] || {
          echo "lever at line $i, prose at line ${prev_i:-none}: want consecutive"; return 1; }
        found=1 ;;
    esac
    i=$((i + 1))
  done <<< "$output"
  [[ $found -eq 1 ]] || { echo "lever line not found at a 2-space indent"; return 1; }
}

@test "storage: the shared lever keeps its 4-space indent in notice blocks" {
  local plain
  plain="$(_disk_lever_short desktop | sed $'s/\033\\[[0-9;]*m//g')"
  case "$plain" in
    "    Docker Desktop: reclaim with"*) : ;;
    *) echo "want a 4-space default indent, got: [$plain]"; return 1 ;;
  esac
}

@test "storage: engine footer follows the kind (Colima names its resize command)" {
  _daemon_up() { return 0; }
  _disk_help_kind() { echo colima; }
  _storage_fill() { echo "31457280 62914560 50"; }
  _stub_storage_docker
  run cmd_storage
  assert_success
  assert_output --partial "colima start --disk"
}

# ── the real _storage_fill parse (seam exercised, not overridden) ────────────

@test "storage fill: real seam parses used/total/pct from a running box df" {
  _running_cleat_boxes() { echo "cleat-x"; }
  docker() { printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\noverlay 62914560 31457280 31457280 50%% /\n'; }
  run _storage_fill
  assert_output "31457280 62914560 50"
}

@test "storage fill: silent when no box is up and no image exists" {
  _running_cleat_boxes() { :; }
  image_exists() { return 1; }
  run _storage_fill
  assert_success
  assert_output ""
}

# ── _fmt_gb decimal branches ─────────────────────────────────────────────────

@test "fmt_gb: sub-10 GB uses one decimal" {
  run _fmt_gb 7516192768
  assert_output "7.0 GB"
}

@test "fmt_gb: 10 GB or more uses no decimals" {
  run _fmt_gb 32212254720
  assert_output "30 GB"
}
