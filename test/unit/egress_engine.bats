#!/usr/bin/env bats
# The engine gate (EGRESS-SPEC.md 10): _egress_engine_kind reads two probes and
# the host, and names one token. A positive allowlist: every signal of an arm
# must hold, and anything the probes cannot read refuses.
load "../setup"

setup() {
  _common_setup
  use_docker_stub
  source_cli
  unset DOCKER_HOST
  _docker_context_endpoint() { printf 'unix:///var/run/docker.sock'; }
  _is_macos() { return 1; }
  _is_wsl() { return 1; }
  _egress_host_kernel() { printf '6.8.0-45-generic'; }
  _egress_host_node() { printf 'buildhost'; }
  # A rootful Docker Engine on this Linux host, every arm B signal holding.
  INFO_OS="Ubuntu 24.04.1 LTS"
  INFO_NAME="buildhost"
  INFO_OST="linux"
  INFO_ROOT="/var/lib/docker"
  INFO_KERN="6.8.0-45-generic"
  INFO_SEC="name=apparmor,name=seccomp,profile=builtin,name=cgroupns,"
  VER_PLAT="Docker Engine - Community"
  VER_API="1.47"
  _egress_info_probe() { printf '%s|%s|27.3.1|%s|%s|%s|%s\n' "$INFO_OS" "$INFO_NAME" "$INFO_OST" "$INFO_ROOT" "$INFO_KERN" "$INFO_SEC"; }
  _egress_version_probe() { printf '%s|%s\n' "$VER_PLAT" "$VER_API"; }
}
teardown() { _common_teardown; }

desktop() {
  INFO_OS="Docker Desktop"
  INFO_NAME="docker-desktop"
  INFO_KERN="6.10.14-linuxkit"
  VER_PLAT="Docker Desktop 4.87.0 (236836)"
}

@test "egress engine: rootful Docker Engine on the Linux host is engine-linux" {
  run _egress_engine_kind
  assert_output "engine-linux"
}

@test "egress engine: Docker Desktop splits by host into macOS, Windows and Linux" {
  desktop
  _is_macos() { return 0; }
  run _egress_engine_kind
  assert_output "desktop-macos"
  _is_macos() { return 1; }
  _is_wsl() { return 0; }
  run _egress_engine_kind
  assert_output "desktop-windows"
  _is_wsl() { return 1; }
  run _egress_engine_kind
  assert_output "desktop-linux"
}

@test "egress engine: arm A takes exact values, never a string that merely contains them" {
  desktop
  _is_macos() { return 0; }
  INFO_OS="Docker Desktop Edge"
  run _egress_engine_kind
  assert_output "unknown"
  desktop
  INFO_NAME="docker-desktop-2"
  run _egress_engine_kind
  assert_output "unknown"
  desktop
  VER_PLAT="Docker Engine - Community"
  run _egress_engine_kind
  assert_output "unknown"
}

@test "egress engine: the endpoint decides before anything else" {
  desktop
  _is_macos() { return 0; }
  _docker_context_endpoint() { printf 'npipe:////./pipe/dockerDesktopLinuxEngine'; }
  run _egress_engine_kind
  assert_output "npipe-endpoint"
  _docker_context_endpoint() { printf 'tcp://10.0.0.5:2376'; }
  run _egress_engine_kind
  assert_output "remote-endpoint"
  _docker_context_endpoint() { printf 'ssh://builder@10.0.0.5'; }
  run _egress_engine_kind
  assert_output "remote-endpoint"
  _docker_context_endpoint() { printf ''; }
  DOCKER_HOST="tcp://10.0.0.5:2376" run _egress_engine_kind
  assert_output "remote-endpoint"
}

@test "egress engine: the API floor is 1.41, compared as integers" {
  local v
  for v in 1.40 1.9 0.99 x 1.4a "" 1.; do
    VER_API="$v"
    run _egress_engine_kind
    assert_output "api-too-old"
  done
  for v in 1.41 1.100 2.0; do
    VER_API="$v"
    run _egress_engine_kind
    assert_output "engine-linux"
  done
}

@test "egress engine: a Windows containers daemon refuses" {
  INFO_OST="windows"
  run _egress_engine_kind
  assert_output "windows-containers"
}

@test "egress engine: a Docker Engine answering on macOS or inside WSL refuses" {
  _is_macos() { return 0; }
  run _egress_engine_kind
  assert_output "vm-backend"
  _is_macos() { return 1; }
  _is_wsl() { return 0; }
  run _egress_engine_kind
  assert_output "wsl-in-distro"
}

@test "egress engine: rootless refuses by its security option and by its socket" {
  INFO_SEC="name=seccomp,profile=builtin,name=rootless,name=cgroupns,"
  run _egress_engine_kind
  assert_output "rootless"
  INFO_SEC="name=seccomp,"
  _docker_context_endpoint() { printf 'unix:///run/user/1000/docker.sock'; }
  run _egress_engine_kind
  assert_output "rootless"
}

@test "egress engine: an endpoint under HOME is a VM backend and an empty HOME refuses" {
  _docker_context_endpoint() { printf 'unix://%s/.colima/default/docker.sock' "$HOME"; }
  run _egress_engine_kind
  assert_output "vm-backend"
  _docker_context_endpoint() { printf 'unix://%s/.orbstack/run/docker.sock' "$HOME"; }
  run _egress_engine_kind
  assert_output "vm-backend"
  _docker_context_endpoint() { printf 'unix:///var/run/docker.sock'; }
  HOME="/" run _egress_engine_kind
  assert_output "unknown"
  HOME="" run _egress_engine_kind
  assert_output "unknown"
}

@test "egress engine: a data root under /mnt refuses" {
  INFO_ROOT="/mnt/wsl/docker-desktop-data"
  run _egress_engine_kind
  assert_output "unknown"
}

@test "egress engine: a kernel that is not the host's is a VM" {
  INFO_KERN="6.1.0-lima"
  run _egress_engine_kind
  assert_output "vm-backend"
  INFO_KERN=""
  run _egress_engine_kind
  assert_output "vm-backend"
}

@test "egress engine: a daemon named for another host refuses, short names compared case-insensitively" {
  INFO_NAME="4f2b9c0d1e3a"
  run _egress_engine_kind
  assert_output "unknown"
  INFO_NAME="BuildHost.example.test"
  run _egress_engine_kind
  assert_output "engine-linux"
  _egress_host_node() { printf 'buildhost.lan'; }
  INFO_NAME="buildhost"
  run _egress_engine_kind
  assert_output "engine-linux"
  INFO_NAME=""
  _egress_host_node() { printf ''; }
  run _egress_engine_kind
  assert_output "unknown"
}

@test "egress engine: probes that answer nothing are unknown" {
  _egress_info_probe() { return 1; }
  run _egress_engine_kind
  assert_output "unknown"
  _egress_info_probe() { printf 'x|y|z|linux|/var/lib/docker|k|\n'; }
  _egress_version_probe() { return 1; }
  run _egress_engine_kind
  assert_output "unknown"
}

@test "egress engine: the validated set ships as desktop macos and engine linux" {
  [ "$_EGRESS_VALIDATED_ENGINES" = "desktop-macos engine-linux" ]
  run _egress_engine_validated desktop-macos
  assert_success
  run _egress_engine_validated engine-linux
  assert_success
  local k
  for k in desktop-windows desktop-linux rootless vm-backend unknown engine desktop "" "desktop-macos engine-linux"; do
    run _egress_engine_validated "$k"
    assert_failure
  done
}

@test "egress engine: no environment variable widens the validated set" {
  run env _EGRESS_VALIDATED_ENGINES="desktop-windows" CLEAT_EGRESS_VALIDATED_ENGINES="desktop-windows" \
    bash -c 'source "$1"; _egress_engine_validated desktop-windows' _ "$CLI"
  assert_failure
}

@test "egress engine: an allowlisted but unvalidated engine refuses and names the checklist" {
  run _egress_engine_refusal desktop-windows
  assert_output --partial "not validated on this Docker engine yet"
  assert_output --partial "Docker Desktop on Windows"
  assert_output --partial "docs/egress-validation.md"
  assert_output --partial "cleat egress off"
  refute_output --partial "cleat egress open"
}

@test "egress engine: a refused engine names both ways forward" {
  run _egress_engine_refusal vm-backend
  assert_output --partial "not available on this Docker engine"
  assert_output --partial "Switch to a supported engine"
  assert_output --partial "cleat egress off"
  assert_output --partial "Windows through WSL2 is not validated yet"
  refute_output --partial "cleat egress open"
}

@test "egress engine: the Needed line follows the validated set" {
  run _egress_engine_refusal rootless
  assert_output --partial "Needed:  Docker Desktop on macOS, or Docker Engine on Linux (rootful)"
  _EGRESS_VALIDATED_ENGINES="desktop-macos"
  run _egress_engine_refusal rootless
  assert_output --partial "Needed:  Docker Desktop on macOS"
  refute_output --partial "Docker Engine on Linux"
  run _egress_engine_refusal engine-linux
  assert_output --partial "not validated on this Docker engine yet"
  assert_output --partial "validated on Docker Desktop on macOS."
}
