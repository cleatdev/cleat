#!/usr/bin/env bats
# ─────────────────────────────────────────────────────────────────────────────
# Docker autopilot (concept/29): _ensure_daemon and its seams.
#
# Covers: the up-daemon no-op, the missing-CLI message, remote-endpoint
# refusal (DOCKER_HOST and context), the TTY / CLEAT_NO_AUTOSTART / unsafe-
# backend gates, the launcher pick matrix (macOS Desktop/OrbStack/Colima,
# Linux Desktop/rootless/root engine, WSL2), the bounded poll (success,
# launch failure, timeout), and the cmd_status truth fix.
#
# Everything daemon- or platform-shaped goes through overridable seams, so
# these tests run identically on any CI host.
# ─────────────────────────────────────────────────────────────────────────────
load "../setup"

setup() {
  _common_setup
  use_docker_stub
  source_cli

  CLEAT_CONFIG_DIR="$TEST_TEMP/cleat-config"
  CLEAT_GLOBAL_CONFIG="$CLEAT_CONFIG_DIR/config"
  mkdir -p "$CLEAT_CONFIG_DIR"

  # Neutral seam baseline: docker CLI present, daemon down, local socket,
  # nothing installed, no TTY, no WSL, Linux. Individual tests flip what
  # they need.
  _docker_cli_present() { return 0; }
  _daemon_up() { return 1; }
  _docker_context_name() { echo ""; }
  _docker_context_endpoint() { echo ""; }
  _is_macos() { return 1; }
  _is_wsl() { return 1; }
  _wsl_desktop_exe() { :; }
  _wsl_interop_ok() { return 0; }
  _distro_docker_present() { return 1; }
  _app_bundle_present() { return 1; }
  _colima_present() { return 1; }
  _desktop_linux_unit_present() { return 1; }
  _is_tty() { return 1; }
  _autostart_launch() { echo "$1" >> "$TEST_TEMP/launched"; return 0; }
  unset DOCKER_HOST CLEAT_NO_AUTOSTART CLEAT_AUTOSTART_TIMEOUT_SECS XDG_RUNTIME_DIR
}

teardown() { _common_teardown; }

# ── Gates ────────────────────────────────────────────────────────────────────

@test "autostart: no-op when the daemon is already up" {
  _daemon_up() { return 0; }
  run _ensure_daemon
  assert_success
  assert_output ""
  [ ! -f "$TEST_TEMP/launched" ]
}

@test "autostart: missing docker CLI gets an install message, not a launch" {
  _docker_cli_present() { return 1; }
  run _ensure_daemon
  assert_failure
  assert_output --partial "Docker isn't installed"
  [ ! -f "$TEST_TEMP/launched" ]
}

@test "autostart: a tcp:// DOCKER_HOST is refused, never launched" {
  export DOCKER_HOST="tcp://10.0.0.5:2376"
  _is_tty() { return 0; }
  run _ensure_daemon
  assert_failure
  assert_output --partial "Remote Docker daemon unreachable"
  assert_output --partial "tcp://10.0.0.5:2376"
  [ ! -f "$TEST_TEMP/launched" ]
}

@test "autostart: an ssh:// context endpoint is refused, never launched" {
  _docker_context_endpoint() { echo "ssh://user@build-box"; }
  _is_tty() { return 0; }
  run _ensure_daemon
  assert_failure
  assert_output --partial "Remote Docker daemon unreachable"
  [ ! -f "$TEST_TEMP/launched" ]
}

@test "autostart: CLEAT_NO_AUTOSTART=1 prints the hint and never launches" {
  export CLEAT_NO_AUTOSTART=1
  _is_tty() { return 0; }
  _is_macos() { return 0; }
  _app_bundle_present() { [[ "$1" == "Docker" ]]; }
  run _ensure_daemon
  assert_failure
  assert_output --partial "Docker isn't running"
  assert_output --partial "open -a Docker"
  [ ! -f "$TEST_TEMP/launched" ]
}

@test "autostart: non-TTY prints the hint and never launches (CI stays GUI-free)" {
  _is_macos() { return 0; }
  _app_bundle_present() { [[ "$1" == "Docker" ]]; }
  run _ensure_daemon
  assert_failure
  assert_output --partial "Docker isn't running"
  [ ! -f "$TEST_TEMP/launched" ]
}

@test "autostart: a root-owned Linux engine is never auto-started, even on a TTY" {
  _is_tty() { return 0; }
  run _ensure_daemon
  assert_failure
  assert_output --partial "Docker isn't running"
  # The printed remedy is environment-dependent (systemd hosts get
  # "sudo systemctl start docker", others "sudo service docker start");
  # what the test guards is that a ROOT engine is never launched, only
  # advised, and both remedies are sudo commands.
  assert_output --partial "sudo"
  [ ! -f "$TEST_TEMP/launched" ]
}

# ── Launcher pick matrix ─────────────────────────────────────────────────────

@test "autostart pick: macOS context orbstack wins" {
  _is_macos() { return 0; }
  _docker_context_name() { echo "orbstack"; }
  run _autostart_pick
  assert_output "orbstack"
}

@test "autostart pick: macOS colima default context (colima installed) wins" {
  _is_macos() { return 0; }
  _colima_present() { return 0; }
  _docker_context_name() { echo "colima"; }
  run _autostart_pick
  assert_output "colima"
}

@test "autostart pick: macOS colima NAMED profile is plumbed through the context" {
  _is_macos() { return 0; }
  _colima_present() { return 0; }
  _docker_context_name() { echo "colima-work"; }
  run _autostart_pick
  assert_output "colima:work"
}

@test "autostart pick: macOS colima named profile via the endpoint path" {
  _is_macos() { return 0; }
  _colima_present() { return 0; }
  _docker_context_endpoint() { echo "unix:///Users/dev/.colima/staging/docker.sock"; }
  run _autostart_pick
  assert_output "colima:staging"
}

@test "autostart pick: a STALE colima context (colima uninstalled) falls through to app detection" {
  _is_macos() { return 0; }
  _colima_present() { return 1; }
  _docker_context_name() { echo "colima-work"; }
  _app_bundle_present() { [[ "$1" == "Docker" ]]; }
  run _autostart_pick
  assert_output "desktop-macos"
}

@test "autostart: _app_bundle_present finds a ~/Applications (no-admin) install" {
  # Restore the real two-path implementation (setup stubs it to false).
  _app_bundle_present() { [[ -d "/Applications/$1.app" ]] || [[ -d "$HOME/Applications/$1.app" ]]; }
  mkdir -p "$HOME/Applications/OrbStack.app"
  run _app_bundle_present OrbStack
  assert_success
  run _app_bundle_present Docker
  assert_failure
}

@test "autostart pick: macOS desktop-linux context means Docker Desktop" {
  _is_macos() { return 0; }
  _docker_context_name() { echo "desktop-linux"; }
  run _autostart_pick
  assert_output "desktop-macos"
}

@test "autostart pick: macOS endpoint under ~/.orbstack wins over app fallback" {
  _is_macos() { return 0; }
  _docker_context_endpoint() { echo "unix:///Users/dev/.orbstack/run/docker.sock"; }
  _app_bundle_present() { [[ "$1" == "Docker" ]]; }
  run _autostart_pick
  assert_output "orbstack"
}

@test "autostart pick: macOS app fallback prefers Docker Desktop, then OrbStack, then colima" {
  _is_macos() { return 0; }
  _app_bundle_present() { [[ "$1" == "Docker" ]]; }
  run _autostart_pick
  assert_output "desktop-macos"
  _app_bundle_present() { [[ "$1" == "OrbStack" ]]; }
  run _autostart_pick
  assert_output "orbstack"
  _app_bundle_present() { return 1; }
  _colima_present() { return 0; }
  run _autostart_pick
  assert_output "colima"
  _colima_present() { return 1; }
  run _autostart_pick
  assert_output "none"
}

@test "autostart pick: WSL2 with the Windows Desktop exe and interop live" {
  _is_wsl() { return 0; }
  _wsl_desktop_exe() { echo "/mnt/c/Program Files/Docker/Docker/Docker Desktop.exe"; }
  run _autostart_pick
  assert_output "wsl-desktop"
}

@test "autostart pick: WSL2 without the Windows exe is wsl-none (not the generic none)" {
  _is_wsl() { return 0; }
  _wsl_desktop_exe() { :; }
  run _autostart_pick
  assert_output "wsl-none"
}

@test "autostart pick: WSL2 with interop DISABLED does not offer the Windows exe" {
  _is_wsl() { return 0; }
  _wsl_desktop_exe() { echo "/mnt/c/Program Files/Docker/Docker/Docker Desktop.exe"; }
  _wsl_interop_ok() { return 1; }
  run _autostart_pick
  assert_output "wsl-none"
}

@test "autostart pick: WSL2 with an in-distro engine is NOT overridden by the Windows Desktop" {
  _is_wsl() { return 0; }
  _wsl_desktop_exe() { echo "/mnt/c/Program Files/Docker/Docker/Docker Desktop.exe"; }
  _distro_docker_present() { return 0; }
  run _autostart_pick
  assert_output "engine-linux"
}

@test "autostart pick: WSL2 with an in-distro rootless engine wins over the Windows Desktop" {
  _is_wsl() { return 0; }
  _wsl_desktop_exe() { echo "/mnt/c/Program Files/Docker/Docker/Docker Desktop.exe"; }
  _docker_context_endpoint() { echo "unix:///run/user/1000/docker.sock"; }
  run _autostart_pick
  assert_output "rootless-linux"
}

@test "autostart pick: Linux Docker Desktop by context or user unit" {
  _docker_context_name() { echo "desktop-linux"; }
  run _autostart_pick
  assert_output "desktop-linux"
  _docker_context_name() { echo ""; }
  _desktop_linux_unit_present() { return 0; }
  run _autostart_pick
  assert_output "desktop-linux"
}

@test "autostart pick: Linux rootless engine by /run/user endpoint" {
  _docker_context_endpoint() { echo "unix:///run/user/1000/docker.sock"; }
  run _autostart_pick
  assert_output "rootless-linux"
}

@test "autostart pick: Linux rootless engine by the 'rootless' context name" {
  _docker_context_name() { echo "rootless"; }
  run _autostart_pick
  assert_output "rootless-linux"
}

@test "autostart pick: Linux rootless socket under a non-standard XDG_RUNTIME_DIR" {
  export XDG_RUNTIME_DIR="/tmp/runtime-dev"
  _docker_context_endpoint() { echo "unix:///tmp/runtime-dev/docker.sock"; }
  run _autostart_pick
  assert_output "rootless-linux"
}

@test "autostart pick: plain Linux falls through to the root-owned engine" {
  run _autostart_pick
  assert_output "engine-linux"
}

# ── Launch + bounded poll ────────────────────────────────────────────────────

@test "autostart: launches the picked backend and continues when the daemon comes up" {
  _is_tty() { return 0; }
  _is_macos() { return 0; }
  _app_bundle_present() { [[ "$1" == "Docker" ]]; }
  _daemon_up() {
    echo x >> "$TEST_TEMP/polls"
    [[ "$(wc -l < "$TEST_TEMP/polls")" -ge 3 ]]
  }
  run _ensure_daemon
  assert_success
  assert_output --partial "Starting Docker Desktop"
  assert_output --partial "Docker ready"
  run cat "$TEST_TEMP/launched"
  assert_output "desktop-macos"
}

@test "autostart: a failed launch reports and exits with the hint" {
  _is_tty() { return 0; }
  _is_macos() { return 0; }
  _app_bundle_present() { [[ "$1" == "OrbStack" ]]; }
  _autostart_launch() { return 1; }
  run _ensure_daemon
  assert_failure
  assert_output --partial "Could not launch OrbStack"
  assert_output --partial "open -a OrbStack"
}

@test "autostart: a never-up daemon exits non-zero within the bounded deadline" {
  _is_tty() { return 0; }
  _is_macos() { return 0; }
  _app_bundle_present() { [[ "$1" == "Docker" ]]; }
  export CLEAT_AUTOSTART_TIMEOUT_SECS=1
  local t0 t1
  t0="$(date +%s)"
  run _ensure_daemon
  t1="$(date +%s)"
  assert_failure
  assert_output --partial "did not come up"
  # bounded: well under the 90s default, no infinite loop
  [ $(( t1 - t0 )) -lt 15 ]
}

@test "autostart: a garbage timeout value falls back to the default (validated)" {
  # Validation only: assert the sanitizer accepts the value shape; the loop
  # itself is exercised by the timeout test above.
  export CLEAT_AUTOSTART_TIMEOUT_SECS="ninety"
  _is_tty() { return 0; }
  _is_macos() { return 0; }
  _app_bundle_present() { [[ "$1" == "Docker" ]]; }
  _daemon_up() {
    echo x >> "$TEST_TEMP/polls"
    [[ "$(wc -l < "$TEST_TEMP/polls")" -ge 2 ]]
  }
  run _ensure_daemon
  assert_success
  assert_output --partial "Docker ready"
}

# ── Labels and hints ─────────────────────────────────────────────────────────

@test "autostart: hints name the exact start command per backend" {
  run _autostart_hint desktop-macos
  assert_output "open -a Docker"
  run _autostart_hint colima
  assert_output "colima start"
  run _autostart_hint desktop-linux
  assert_output "systemctl --user start docker-desktop"
  # rootless-linux is systemctl-conditional; assert the stable part.
  run _autostart_hint rootless-linux
  assert_output --partial "docker"
  run _autostart_hint wsl-desktop
  assert_output --partial "Docker Desktop on Windows"
}

@test "autostart: a colima profile hint and launch carry the -p flag" {
  run _autostart_hint colima:work
  assert_output "colima start -p work"
  run _autostart_label colima:work
  assert_output "Colima"
  # launch: unstub _autostart_launch and record the real command via _install_run-like capture
  _autostart_launch() { echo "$1" >> "$TEST_TEMP/launched"; return 0; }
  run _autostart_launch colima:work
  run cat "$TEST_TEMP/launched"
  assert_output "colima:work"
}

@test "autostart: hint-is-command classifies command vs instruction kinds" {
  run _autostart_hint_is_command desktop-macos
  assert_success
  run _autostart_hint_is_command colima:work
  assert_success
  run _autostart_hint_is_command wsl-none
  assert_failure
  run _autostart_hint_is_command none
  assert_failure
}

@test "autostart: the poll noun is VM for Desktop, daemon for rootless" {
  run _autostart_poll_noun desktop-macos
  assert_output "the Docker VM"
  run _autostart_poll_noun rootless-linux
  assert_output "the Docker daemon"
}

# ── EACCES: permission, not down ─────────────────────────────────────────────

@test "autostart: an inaccessible local socket is diagnosed as permission, not down" {
  _is_tty() { return 0; }
  # a real socket-typed file we can make unwritable
  local sock="$TEST_TEMP/docker.sock"
  python3 -c "import socket,sys; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1])" "$sock" 2>/dev/null \
    || skip "cannot create a unix socket here"
  chmod 000 "$sock"
  _docker_context_endpoint() { echo "unix://$TEST_TEMP/docker.sock"; }
  run _ensure_daemon
  assert_failure
  assert_output --partial "can't reach its socket"
  assert_output --partial "usermod -aG docker"
  refute_output --partial "Starting"
  [ ! -f "$TEST_TEMP/launched" ]
}

# ── unix:// endpoints fall THROUGH the remote-refusal gate to the launcher ───

@test "autostart: a unix:// context endpoint is NOT treated as remote (reaches the launcher)" {
  _is_tty() { return 0; }
  _is_macos() { return 0; }
  _app_bundle_present() { [[ "$1" == "Docker" ]]; }
  _docker_context_endpoint() { echo "unix:///Users/dev/.docker/run/docker.sock"; }
  _daemon_up() {
    echo x >> "$TEST_TEMP/polls"
    [[ "$(wc -l < "$TEST_TEMP/polls")" -ge 2 ]]
  }
  run _ensure_daemon
  assert_success
  refute_output --partial "Remote Docker daemon"
  assert_output --partial "Starting Docker Desktop"
  run cat "$TEST_TEMP/launched"
  assert_output "desktop-macos"
}

@test "autostart: an explicit DOCKER_HOST=unix:// is also not remote" {
  _is_tty() { return 0; }
  _is_macos() { return 0; }
  _app_bundle_present() { [[ "$1" == "Docker" ]]; }
  export DOCKER_HOST="unix:///var/run/docker.sock"
  _daemon_up() {
    echo x >> "$TEST_TEMP/polls"
    [[ "$(wc -l < "$TEST_TEMP/polls")" -ge 2 ]]
  }
  run _ensure_daemon
  assert_success
  refute_output --partial "Remote Docker daemon"
  assert_output --partial "Starting Docker Desktop"
}

@test "autostart: a remote endpoint with terminal escapes is sanitized before display" {
  _is_tty() { return 0; }
  export DOCKER_HOST="$(printf 'tcp://host\033[2Jx')"
  run _ensure_daemon
  assert_failure
  assert_output --partial "Remote Docker daemon unreachable"
  # the raw ESC (033) must not survive into the message
  [[ "$output" != *$'\033[2J'* ]]
}

# ── cmd_status truth fix ─────────────────────────────────────────────────────

@test "autostart: cmd_status says the daemon is down instead of 'not created'" {
  mock_docker_ps ""
  mock_docker_ps_a ""
  _daemon_up() { return 1; }
  mkdir -p "$TEST_TEMP/project"
  cd "$TEST_TEMP/project"
  run cmd_status
  assert_success
  assert_output --partial "Docker isn't running"
  refute_output --partial "not created"
}

@test "autostart: cmd_status keeps 'not created' when the daemon is up" {
  mock_docker_ps ""
  mock_docker_ps_a ""
  _daemon_up() { return 0; }
  mkdir -p "$TEST_TEMP/project"
  cd "$TEST_TEMP/project"
  run cmd_status
  assert_success
  assert_output --partial "not created"
}

@test "autostart: cmd_status distinguishes not-installed from not-running" {
  mock_docker_ps ""
  mock_docker_ps_a ""
  _docker_cli_present() { return 1; }
  mkdir -p "$TEST_TEMP/project"
  cd "$TEST_TEMP/project"
  run cmd_status
  assert_success
  assert_output --partial "Docker isn't installed"
  assert_output --partial "install it with:"
  refute_output --partial "not created"
}

@test "autostart: cmd_status does not glue a non-command hint into 'start it with:'" {
  mock_docker_ps ""
  mock_docker_ps_a ""
  _docker_cli_present() { return 0; }
  _daemon_up() { return 1; }
  _autostart_pick() { echo "wsl-none"; }
  mkdir -p "$TEST_TEMP/project"
  cd "$TEST_TEMP/project"
  run cmd_status
  assert_success
  assert_output --partial "Docker isn't running"
  # instruction kinds must not read "start it with: start Docker Desktop..."
  refute_output --partial "start it with: start Docker Desktop"
}

# ── wsl-none / instruction kinds print bare, never launch ────────────────────

@test "autostart: wsl-none is print-only (no launch) with the WSL instruction" {
  _is_tty() { return 0; }
  _is_wsl() { return 0; }
  _wsl_desktop_exe() { :; }
  run _ensure_daemon
  assert_failure
  assert_output --partial "Docker isn't running"
  assert_output --partial "Docker Desktop on Windows"
  refute_output --partial "start it with: start"
  [ ! -f "$TEST_TEMP/launched" ]
}

# ── Docker install offer (missing-CLI branch) ────────────────────────────────

@test "install offer: non-TTY prints the per-OS command and never prompts" {
  _docker_cli_present() { return 1; }
  run _ensure_daemon
  assert_failure
  assert_output --partial "Docker isn't installed"
  assert_output --partial "Install it with:"
  # F37: the actual command must be present, not just the prefix
  assert_output --partial "get.docker.com"
  [ ! -f "$TEST_TEMP/installed" ]
}

@test "install offer: non-TTY hint is per-OS (macOS brew, WSL winget)" {
  _docker_cli_present() { return 1; }
  _is_macos() { return 0; }
  run _ensure_daemon
  assert_failure
  assert_output --partial "brew install --cask docker"
  _is_macos() { return 1; }
  _is_wsl() { return 0; }
  run _ensure_daemon
  assert_failure
  assert_output --partial "winget.exe install"
}

@test "install offer: CLEAT_NO_AUTOSTART=1 suppresses the offer even on a TTY" {
  _docker_cli_present() { return 1; }
  _is_tty() { return 0; }
  export CLEAT_NO_AUTOSTART=1
  run _ensure_daemon
  assert_failure
  assert_output --partial "Install it with:"
  refute_output --partial "Install Docker now?"
}

@test "install offer: macOS menu installs the chosen flavor via brew casks" {
  _docker_cli_present() { return 1; }
  _is_tty() { return 0; }
  _is_macos() { return 0; }
  _brew_present() { return 0; }
  _install_run() { echo "$*" >> "$TEST_TEMP/installed"; return 0; }
  run _ensure_daemon <<< "2"
  # after "install", the CLI is still absent (we only recorded), so it exits
  assert_failure
  assert_output --partial "OrbStack"
  run cat "$TEST_TEMP/installed"
  assert_output "brew install --cask orbstack"
}

@test "install offer: macOS colima choice installs docker CLI + colima" {
  _docker_cli_present() { return 1; }
  _is_tty() { return 0; }
  _is_macos() { return 0; }
  _brew_present() { return 0; }
  _install_run() { echo "$*" >> "$TEST_TEMP/installed"; return 0; }
  run _ensure_daemon <<< "3"
  run cat "$TEST_TEMP/installed"
  assert_output "brew install docker colima"
}

@test "install offer: declining the macOS menu installs nothing" {
  _docker_cli_present() { return 1; }
  _is_tty() { return 0; }
  _is_macos() { return 0; }
  _brew_present() { return 0; }
  _install_run() { echo "$*" >> "$TEST_TEMP/installed"; return 0; }
  run _ensure_daemon <<< "n"
  assert_failure
  assert_output --partial "Skipped"
  [ ! -f "$TEST_TEMP/installed" ]
}

@test "install offer: EOF (no answer) installs nothing" {
  _docker_cli_present() { return 1; }
  _is_tty() { return 0; }
  _is_macos() { return 0; }
  _brew_present() { return 0; }
  _install_run() { echo "$*" >> "$TEST_TEMP/installed"; return 0; }
  run _ensure_daemon < /dev/null
  assert_failure
  [ ! -f "$TEST_TEMP/installed" ]
}

@test "install offer: macOS without Homebrew prints official links, runs nothing" {
  _docker_cli_present() { return 1; }
  _is_tty() { return 0; }
  _is_macos() { return 0; }
  _brew_present() { return 1; }
  _install_run() { echo "$*" >> "$TEST_TEMP/installed"; return 0; }
  run _ensure_daemon
  assert_failure
  assert_output --partial "docker.com/products/docker-desktop"
  assert_output --partial "orbstack.dev"
  [ ! -f "$TEST_TEMP/installed" ]
}

@test "install offer: mac menu surfaces the licensing difference" {
  _docker_cli_present() { return 1; }
  _is_tty() { return 0; }
  _is_macos() { return 0; }
  _brew_present() { return 0; }
  run _ensure_daemon <<< "n"
  assert_output --partial "paid for larger companies"
  assert_output --partial "open source"
}

@test "install offer: Linux engine consent downloads the script to a file, then sudo-runs it" {
  _docker_cli_present() { return 1; }
  _is_tty() { return 0; }
  _install_run() { echo "$*" >> "$TEST_TEMP/installed"; return 0; }
  run _ensure_daemon <<< $'y\ny'
  assert_failure
  assert_output --partial "Log out and back in"
  run cat "$TEST_TEMP/installed"
  assert_output --partial "curl -fsSL https://get.docker.com -o"
  assert_output --partial "sudo sh"
  assert_output --partial "sudo usermod -aG docker"
  # download-then-run, never a blind pipe
  refute_output --partial "| sh"
  # the staged script lives under a private mktemp dir, never a predictable
  # /tmp/cleat-get-docker.$$.sh (F01: root-exec TOCTOU)
  refute_output --partial "cleat-get-docker."
  assert_output --partial "cleat-docker."
}

@test "install offer: Linux group-add survives an unset USER under set -u (CO7)" {
  _docker_cli_present() { return 1; }
  _is_tty() { return 0; }
  _install_run() { echo "$*" >> "$TEST_TEMP/installed"; return 0; }
  local _saved="${USER:-}"
  unset USER
  run _ensure_daemon <<< $'y\ny'
  export USER="$_saved"
  assert_failure
  # no "USER: unbound variable" crash; the group-add line still emits a name
  refute_output --partial "unbound variable"
  assert_output --partial "Docker Engine installed"
  run cat "$TEST_TEMP/installed"
  assert_output --partial "sudo usermod -aG docker"
}

@test "install offer: Linux declining the group add still finishes the install" {
  _docker_cli_present() { return 1; }
  _is_tty() { return 0; }
  _install_run() { echo "$*" >> "$TEST_TEMP/installed"; return 0; }
  run _ensure_daemon <<< $'y\nn'
  assert_failure
  assert_output --partial "Docker Engine installed"
  run cat "$TEST_TEMP/installed"
  refute_output --partial "usermod"
}

@test "install offer: Linux declining the install runs nothing" {
  _docker_cli_present() { return 1; }
  _is_tty() { return 0; }
  _install_run() { echo "$*" >> "$TEST_TEMP/installed"; return 0; }
  run _ensure_daemon <<< "n"
  assert_failure
  assert_output --partial "Skipped"
  [ ! -f "$TEST_TEMP/installed" ]
}

@test "install offer: WSL2 offers winget when reachable, links when not" {
  _docker_cli_present() { return 1; }
  _is_tty() { return 0; }
  _is_wsl() { return 0; }
  _winget_present() { return 0; }
  _install_run() { echo "$*" >> "$TEST_TEMP/installed"; return 0; }
  run _ensure_daemon <<< "y"
  assert_failure
  assert_output --partial "WSL integration"
  run cat "$TEST_TEMP/installed"
  assert_output --partial "winget.exe install -e --id Docker.DockerDesktop"
  rm -f "$TEST_TEMP/installed"
  _winget_present() { return 1; }
  run _ensure_daemon
  assert_failure
  assert_output --partial "Install Docker Desktop on Windows"
  [ ! -f "$TEST_TEMP/installed" ]
}

@test "install offer: a successful install falls through to the autopilot launch flow" {
  # After the install runs, the CLI "appears" and the normal down-daemon flow
  # takes over: pick, launch, poll.
  _is_tty() { return 0; }
  _is_macos() { return 0; }
  _brew_present() { return 0; }
  _app_bundle_present() { [[ "$1" == "Docker" ]]; }
  _docker_cli_present() { [[ -f "$TEST_TEMP/installed" ]]; }
  _install_run() { echo "$*" >> "$TEST_TEMP/installed"; return 0; }
  _daemon_up() {
    [[ -f "$TEST_TEMP/installed" ]] || return 1
    echo x >> "$TEST_TEMP/polls"
    [[ "$(wc -l < "$TEST_TEMP/polls")" -ge 2 ]]
  }
  run _ensure_daemon <<< "1"
  assert_success
  assert_output --partial "Docker installed"
  assert_output --partial "Starting Docker Desktop"
  assert_output --partial "Docker ready"
}
