#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Mutation test for the regression registry.
#
# For each historical bug recorded in test/unit/regressions.bats, this script
# applies a sed mutation to bin/cleat that reintroduces the bug, then runs
# the guarding test and verifies the test FAILS. A test that passes against
# the mutated source is worthless: it doesn't catch the bug it claims to.
#
# This is the "verify 3 times" layer for the regression registry:
#   1. The test passes on the current (fixed) code
#   2. The test fails when the fix is reverted (this script)
#   3. The test does not cause false positives in the full suite
#
# Usage: test/mutation_regressions.sh [filter]
#   filter: optional substring to select a subset of mutations by name
#
# Exit: 0 if every tested mutation is caught; 1 otherwise.
#
# BSD-sed caveat: this is designed to be GNU+BSD portable, and the Linux CI leg
# (GNU sed) runs it green at 0 missed / 0 skipped. On BSD sed (macOS) ~8 older
# entries currently MISS or SKIP because their seds lean on GNU-sed behaviour
# (e.g. the `a\` append syntax and some `\[...\]` patterns differ). CI therefore
# gates this harness on Linux only. If you run it on a Mac, expect those few
# false MISSED/SKIPPED lines; making every sed BSD-portable is a tracked follow-up.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CLI="$REPO_ROOT/bin/cleat"
INSTALLER="$REPO_ROOT/install.sh"
BATS="$REPO_ROOT/test/bats/bin/bats"
REGRESSIONS="$REPO_ROOT/test/unit/regressions.bats"
UPGRADE_BATS="$REPO_ROOT/test/unit/upgrade_claude.bats"
CLAUDE_BATS="$REPO_ROOT/test/unit/claude_update_check.bats"
RUN_DIR_BATS="$REPO_ROOT/test/unit/run_dir.bats"
VERSION_BATS="$REPO_ROOT/test/unit/version.bats"
TERMINAL_UX_BATS="$REPO_ROOT/test/unit/terminal_ux.bats"
BOX_NAME_BATS="$REPO_ROOT/test/unit/box_name.bats"
CONTAINER_NAME_BATS="$REPO_ROOT/test/unit/container_name.bats"
BOXES_BATS="$REPO_ROOT/test/unit/boxes.bats"
BOX_HARDENING_BATS="$REPO_ROOT/test/unit/box_hardening.bats"
DOCKER_CAP_BATS="$REPO_ROOT/test/unit/docker_cap.bats"
BROWSER_BRIDGE_BATS="$REPO_ROOT/test/unit/browser_bridge.bats"
WHATS_NEW_BATS="$REPO_ROOT/test/unit/whats_new.bats"
INSTALL_NOTICE_BATS="$REPO_ROOT/test/unit/install_notice.bats"
CAPABILITIES_BATS="$REPO_ROOT/test/unit/capabilities.bats"
EXEC_CLAUDE_BATS="$REPO_ROOT/test/unit/exec_claude.bats"
INIT_RECREATE_BATS="$REPO_ROOT/test/unit/init_recreate_check.bats"
ARCH_BATS="$REPO_ROOT/test/unit/arch.bats"
RESOURCES_BATS="$REPO_ROOT/test/unit/resources.bats"
PRUNE_BATS="$REPO_ROOT/test/unit/prune.bats"
CLAUDE_JSON_BATS="$REPO_ROOT/test/unit/claude_json.bats"
CREDENTIALS_BATS="$REPO_ROOT/test/unit/credentials.bats"
START_RESUME_BATS="$REPO_ROOT/test/unit/start_resume.bats"
IDLE_SWEEP_BATS="$REPO_ROOT/test/unit/idle_sweep.bats"
IMAGE_REBUILD_BATS="$REPO_ROOT/test/unit/image_rebuild_check.bats"
TRUST_BATS="$REPO_ROOT/test/unit/trust.bats"
DOCKER_COMMANDS_BATS="$REPO_ROOT/test/unit/docker_commands.bats"
KITS_BATS="$REPO_ROOT/test/unit/kits.bats"
AUTOSTART_BATS="$REPO_ROOT/test/unit/autostart.bats"
SMOKE_BATS="$REPO_ROOT/test/unit/smoke.bats"
CLIPBOARD_BRIDGE_BATS="$REPO_ROOT/test/unit/clipboard_bridge.bats"
HOOKS_BATS="$REPO_ROOT/test/unit/hooks.bats"
PROVISION_BATS="$REPO_ROOT/test/unit/provision.bats"
DOCKER_GATE_BATS="$REPO_ROOT/test/unit/docker_gate.bats"
CONFIG_BATS="$REPO_ROOT/test/unit/config.bats"
NUKE_BATS="$REPO_ROOT/test/unit/nuke.bats"
HUMAN_SIZE_BATS="$REPO_ROOT/test/unit/human_size.bats"
DISK_GATE_BATS="$REPO_ROOT/test/unit/disk_gate.bats"
STORAGE_BATS="$REPO_ROOT/test/unit/storage.bats"
UPDATE_BATS="$REPO_ROOT/test/unit/update.bats"
INSTALLER_BATS="$REPO_ROOT/test/unit/installer.bats"
INT_LIFECYCLE_BATS="$REPO_ROOT/test/integration/lifecycle.bats"
SETUP_BASH="$REPO_ROOT/test/setup.bash"
ENTRYPOINT="$REPO_ROOT/docker/entrypoint.sh"
ENTRYPOINT_BATS="$REPO_ROOT/test/unit/entrypoint.bats"
OPENBRIDGE="$REPO_ROOT/docker/open-bridge"
CLIP_DAEMON="$REPO_ROOT/docker/clip-daemon"
CLIP_SHIM="$REPO_ROOT/docker/clip"
TEST_SH="$REPO_ROOT/test.sh"
BACKUP="/tmp/cleat-regression-mutation-backup-$$"
INSTALLER_BACKUP="/tmp/cleat-regression-mutation-installer-backup-$$"
ENTRYPOINT_BACKUP="/tmp/cleat-regression-mutation-entrypoint-backup-$$"
OPENBRIDGE_BACKUP="/tmp/cleat-regression-mutation-openbridge-backup-$$"
CLIP_DAEMON_BACKUP="/tmp/cleat-regression-mutation-clipdaemon-backup-$$"
CLIP_SHIM_BACKUP="/tmp/cleat-regression-mutation-clipshim-backup-$$"
TEST_SH_BACKUP="/tmp/cleat-regression-mutation-testsh-backup-$$"
INT_LIFECYCLE_BACKUP="/tmp/cleat-regression-mutation-intlifecycle-backup-$$"
SETUP_BASH_BACKUP="/tmp/cleat-regression-mutation-setupbash-backup-$$"

BOLD=$'\033[1m'
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[0;33m'
DIM=$'\033[2m'
RESET=$'\033[0m'

# Mutual exclusion, taken BEFORE the backups and BEFORE the cleanup trap. Both
# of those WRITE the nine tracked files this lock exists to protect, so a run
# that is correctly refused must not have reached them.
_CLEAT_TEST_LOCK_ROOT="$REPO_ROOT"
. "$REPO_ROOT/test/lib/testlock.sh"
_take_test_lock "the mutation harness"

cleanup() {
  [[ -f "$BACKUP" ]] && cp "$BACKUP" "$CLI"
  [[ -f "$INSTALLER_BACKUP" ]] && cp "$INSTALLER_BACKUP" "$INSTALLER"
  [[ -f "$ENTRYPOINT_BACKUP" ]] && cp "$ENTRYPOINT_BACKUP" "$ENTRYPOINT"
  [[ -f "$OPENBRIDGE_BACKUP" ]] && cp "$OPENBRIDGE_BACKUP" "$OPENBRIDGE"
  [[ -f "$CLIP_DAEMON_BACKUP" ]] && cp "$CLIP_DAEMON_BACKUP" "$CLIP_DAEMON"
  [[ -f "$CLIP_SHIM_BACKUP" ]] && cp "$CLIP_SHIM_BACKUP" "$CLIP_SHIM"
  [[ -f "$TEST_SH_BACKUP" ]] && cp "$TEST_SH_BACKUP" "$TEST_SH"
  [[ -f "$INT_LIFECYCLE_BACKUP" ]] && cp "$INT_LIFECYCLE_BACKUP" "$INT_LIFECYCLE_BATS"
  [[ -f "$SETUP_BASH_BACKUP" ]] && cp "$SETUP_BASH_BACKUP" "$SETUP_BASH"
  rm -f "$BACKUP" "$INSTALLER_BACKUP" "$ENTRYPOINT_BACKUP" \
        "$OPENBRIDGE_BACKUP" "$CLIP_DAEMON_BACKUP" "$CLIP_SHIM_BACKUP" "$TEST_SH_BACKUP" \
        "$INT_LIFECYCLE_BACKUP" "$SETUP_BASH_BACKUP"
}
trap cleanup EXIT INT TERM

cp "$CLI" "$BACKUP"
cp "$INSTALLER" "$INSTALLER_BACKUP"
cp "$ENTRYPOINT" "$ENTRYPOINT_BACKUP"
cp "$OPENBRIDGE" "$OPENBRIDGE_BACKUP"
cp "$CLIP_DAEMON" "$CLIP_DAEMON_BACKUP"
cp "$CLIP_SHIM" "$CLIP_SHIM_BACKUP"
cp "$TEST_SH" "$TEST_SH_BACKUP"
cp "$INT_LIFECYCLE_BATS" "$INT_LIFECYCLE_BACKUP"
cp "$SETUP_BASH" "$SETUP_BASH_BACKUP"
filter="${1:-}"

# Run a mutation: apply sed, run one regression test by filter, expect failure.
# Target file defaults to $CLI; pass $INSTALLER (or any other path) to mutate
# a companion script. Returns 0 if mutation caught, 1 if missed, 2 if skipped.
run_mutation() {
  local name="$1" test_filter="$2" sed_file="$3" target="${4:-$CLI}" test_file="${5:-$REGRESSIONS}" backup
  if [[ "$target" == "$INSTALLER" ]]; then
    backup="$INSTALLER_BACKUP"
  elif [[ "$target" == "$ENTRYPOINT" ]]; then
    backup="$ENTRYPOINT_BACKUP"
  elif [[ "$target" == "$OPENBRIDGE" ]]; then
    backup="$OPENBRIDGE_BACKUP"
  elif [[ "$target" == "$CLIP_DAEMON" ]]; then
    backup="$CLIP_DAEMON_BACKUP"
  elif [[ "$target" == "$CLIP_SHIM" ]]; then
    backup="$CLIP_SHIM_BACKUP"
  elif [[ "$target" == "$TEST_SH" ]]; then
    backup="$TEST_SH_BACKUP"
  elif [[ "$target" == "$INT_LIFECYCLE_BATS" ]]; then
    backup="$INT_LIFECYCLE_BACKUP"
  elif [[ "$target" == "$SETUP_BASH" ]]; then
    backup="$SETUP_BASH_BACKUP"
  else
    backup="$BACKUP"
  fi

  cp "$backup" "$target"

  # Apply the sed script. Use `-i.bak` which is portable across GNU sed
  # (Linux) and BSD sed (macOS). BSD sed's `-i` requires an explicit
  # backup extension; GNU sed accepts it too.
  if ! sed -i.bak -f "$sed_file" "$target" 2>/dev/null; then
    rm -f "$target.bak"
    echo "${YELLOW}~ $name: SKIPPED${RESET} ${DIM}(sed failed)${RESET}"
    return 2
  fi
  rm -f "$target.bak"

  # Verify the mutation produced a change
  if cmp -s "$target" "$backup"; then
    echo "${YELLOW}~ $name: SKIPPED${RESET} ${DIM}(no change after mutation)${RESET}"
    return 2
  fi

  # Verify the mutated file still parses. A `.bats` file is not valid bash
  # (`@test "x" { ... }` is bats syntax that bash rejects at the closing brace),
  # so the check cannot apply there: bats parses those itself at run time.
  case "$target" in
    *.bats) : ;;
    *)
      if ! bash -n "$target" 2>/dev/null; then
        echo "${YELLOW}~ $name: SKIPPED${RESET} ${DIM}(mutation caused syntax error)${RESET}"
        return 2
      fi
      ;;
  esac

  # A filter that matches NOTHING runs zero tests, and bats exits 0 for that, so
  # the mutation reads as MISSED when in fact it was never tested. It has
  # happened twice: a test gets renamed and its filter silently stops matching.
  # Check the count against the PRISTINE source, before judging the mutation.
  local _planned
  _planned="$("$BATS" --count --filter "$test_filter" "$test_file" 2>/dev/null || echo 0)"
  case "$_planned" in ''|*[!0-9]*) _planned=0 ;; esac
  if [[ "$_planned" -eq 0 ]]; then
    echo "${RED}✖ $name: NO MATCH${RESET} ${DIM}(filter '$test_filter' matches no test in ${test_file##*/})${RESET}"
    return 1
  fi

  # Run only the target test; expect it to FAIL
  if "$BATS" --filter "$test_filter" "$test_file" </dev/null >/dev/null 2>&1; then
    echo "${RED}✖ $name: MISSED${RESET} ${DIM}(test passed against mutated code)${RESET}"
    return 1
  else
    echo "${GREEN}✔ $name: CAUGHT${RESET}"
    return 0
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Mutation definitions. Each uses a temp sed file to avoid shell quoting hell.
# ─────────────────────────────────────────────────────────────────────────────

SED_TMP="$(mktemp)"


trap 'cleanup; rm -f "$SED_TMP"; _drop_test_lock' EXIT INT TERM

total=0
caught=0
missed=0
skipped=0
declare -a missed_names=()

try() {
  local name="$1" test_filter="$2" target="${3:-$CLI}" test_file="${4:-$REGRESSIONS}"
  if [[ -n "$filter" && "$name" != *"$filter"* ]]; then
    return
  fi
  total=$((total + 1))
  local rc=0
  run_mutation "$name" "$test_filter" "$SED_TMP" "$target" "$test_file" || rc=$?
  case "$rc" in
    0) caught=$((caught + 1)) ;;
    1) missed=$((missed + 1)); missed_names+=("$name → $test_filter") ;;
    2) skipped=$((skipped + 1)) ;;
  esac
}

echo "${BOLD}Running regression mutations${RESET}"
echo ""

# v0.5.1: cmd_claude must set _RESOLVED_PROJECT
cat > "$SED_TMP" << 'SED'
/^cmd_claude()/,/^}$/{
  /_RESOLVED_PROJECT="\$project"/d
}
SED
try "v0.5.1_resolved_project" "cmd_claude sets _RESOLVED_PROJECT"

# v0.5.1: hook overlay must replace command, not strip. Break it by replacing
# the forwarder path with something no test checks for.
cat > "$SED_TMP" << 'SED'
s|cat >> /var/log/cleat/events.jsonl|/bin/true|g
SED
try "v0.5.1_hook_replace" "hook overlay replaces command with forwarder"

# v0.6.0 + v0.6.5: both guards must hold. Break BOTH the -d dir check and
# the -f file skip so the overlay is mounted even when neither exists.
cat > "$SED_TMP" << 'SED'
s|if \[\[ -d "\$_workspace/.claude" \]\]; then|if true; then|
/\[\[ -f "\$pf" \]\] || continue/d
SED
try "v0.6.0_claude_guard" "skip project overlay when .claude/ missing"

# v0.6.1: _browser_watcher must remove stale bridge file at startup. The
# sweep is age-gated since the 2026-07-11 round (an if-block ending in fi),
# so the range runs comment through fi: an end anchor on the rm line alone
# would leave the range unterminated and gut the file (silent SKIPPED).
cat > "$SED_TMP" << 'SED'
/^  # Remove any URL left over from a previous session, and any debounce$/,/^  fi$/d
SED
try "v0.6.1_browser_stale" "browser bridge removes stale file"

# v0.6.2: docker run failure must surface docker stderr
cat > "$SED_TMP" << 'SED'
s|\[\[ -s "\$_docker_err" \]\] && error "\${DIM}\$(cat "\$_docker_err")\${RESET}"|true|
SED
try "v0.6.2_stderr_error" "docker run failure surfaces docker stderr"

# v0.6.2: cmd_run must wipe stale overlay dir
cat > "$SED_TMP" << 'SED'
s|rm -rf "\$settings_overlay_dir"|true|
SED
try "v0.6.2_stale_overlay" "cmd_run wipes stale settings overlay"

# v0.6.2: summary block must collapse $HOME to ~ (not show '~' literally)
cat > "$SED_TMP" << 'SED'
s|display_path="\${project/#\$HOME/\$_tilde}"|display_path="'~'\${project#\$HOME}"|
SED
try "v0.6.2_tilde" "summary block shows ~ without quotes"

# v0.6.3: exec_claude must pass _RESOLVED_ENV_ARGS to docker exec
cat > "$SED_TMP" << 'SED'
/^exec_claude()/,/^}$/{
  /"\${_RESOLVED_ENV_ARGS\[@\]+/d
}
SED
try "v0.6.3_exec_claude_env" "exec_claude passes resolved env args"

# v0.6.3: cmd_shell must call resolve_env_args. Replace the call with a
# no-op so the function signature is preserved but env resolution is skipped.
cat > "$SED_TMP" << 'SED'
/^cmd_shell()/,/^}$/{
  s|resolve_env_args "\$project"|true|
}
SED
try "v0.6.3_shell_resolve" "cmd_shell resolves env args"

# v0.6.3: cmd_shell must set full PATH (use CLAUDE_ENV, not hardcoded HOME only)
cat > "$SED_TMP" << 'SED'
/^cmd_shell()/,/^}$/{
  s|"\${CLAUDE_ENV\[@\]}"|-e HOME=/home/coder|
}
SED
try "v0.6.3_shell_path" "cmd_shell sets PATH with /home/coder/.local/bin"

# v0.6.3: cmd_login must call resolve_env_args. Replace with no-op.
cat > "$SED_TMP" << 'SED'
/^cmd_login()/,/^}$/{
  s|resolve_env_args "\$project"|true|
}
SED
try "v0.6.3_login_resolve" "cmd_login resolves env args"

# v0.6.3: _parse_env_file must read last line without trailing newline
# (use # as delimiter to avoid shell pipe in pattern)
cat > "$SED_TMP" << 'SED'
s#while IFS= read -r line || \[\[ -n "\$line" \]\]; do#while IFS= read -r line; do#
SED
try "v0.6.3_parse_env_last" "_parse_env_file reads last line"

# v0.6.4: _auth_callback_proxy must try TCP6 first. Remove the 6 so the
# call becomes pure TCP (the pre-fix behavior).
cat > "$SED_TMP" << 'SED'
s|TCP6\\\\:localhost|TCP\\\\:localhost|
SED
try "v0.6.4_tcp6_first" "tries TCP6 before TCP"

# v0.6.4: socat must use -,ignoreeof to prevent stdin EOF propagation
cat > "$SED_TMP" << 'SED'
s|-,ignoreeof|-|g
SED
try "v0.6.4_ignoreeof" "uses ignoreeof on stdin"

# v0.6.5: cmd_run must skip overlay mount when host file doesn't exist
cat > "$SED_TMP" << 'SED'
/\[\[ -f "\$pf" \]\] || continue/d
SED
try "v0.6.5_skip_missing" "cmd_run skips overlay mount for missing"

# v0.6.5: cmd_run must force-remove partial container on failure
cat > "$SED_TMP" << 'SED'
/docker rm -f "\$cname" > \/dev\/null 2>&1 || true/d
SED
try "v0.6.5_cleanup_fail" "cmd_run cleans up partial container"

# v0.8.0: per-project session overlay must be present in docker run
cat > "$SED_TMP" << 'SED'
/project_session_key=/d
/project_session_dir=/d
/mkdir -p "\$project_session_dir"/d
/mkdir -p "\${HOME}\/.claude\/projects\/-workspace"/d
/\$project_session_dir.*projects\/-workspace/d
SED
try "v0.8.0_session_isolation" "session overlay mount isolates projects"

# v0.8.0: history.jsonl must be overlaid per-project. Remove the history mount.
cat > "$SED_TMP" << 'SED'
/history\.jsonl:\/home\/coder\/\.claude\/history\.jsonl/d
SED
try "v0.8.0_history_isolation" "history.jsonl overlay isolates per-project history"

# bash-3.2: grep guard must catch associative arrays
cat > "$SED_TMP" << 'SED'
1a\
local -A _illegal_bash4=()
SED
try "bash32_assoc_array" "no associative arrays"

# bash-3.2: grep guard must catch readarray (syntactically valid form)
cat > "$SED_TMP" << 'SED'
1a\
_never_run() { readarray -t arr < /dev/null; }
SED
try "bash32_readarray" "no readarray or mapfile"

# v0.9.2: installer spin_stop must use %b (not %s) so escape sequences
# embedded in ok_msg/fail_msg render instead of printing literal \033.
cat > "$SED_TMP" << 'SED'
/^spin_stop()/,/^}$/{
  s|%b|%s|g
}
SED
try "v0.9.2_spin_stop_pct_b" "installer spin_stop renders escapes and clears line" "$INSTALLER"

# v0.9.2: installer spin_stop must emit \r\033[K (not just \r) to clear the
# rest of a longer spinner line before writing a shorter success message.
cat > "$SED_TMP" << 'SED'
/^spin_stop()/,/^}$/{
  s|\\r\\033\[K|\\r|g
}
SED
try "v0.9.2_spin_stop_line_clear" "installer spin_stop renders escapes and clears line" "$INSTALLER"

# v0.9.2: cmd_run must call _do_pull before falling back to _do_build so
# first-run users get the GHCR prebuilt image instead of a 2-5 min local build.
cat > "$SED_TMP" << 'SED'
s#_do_pull || _do_build#_do_build#
SED
try "v0.9.2_cmd_run_pull_first" "cmd_run attempts pull before building on first run"

# v0.9.2: REGISTRY_IMAGE must be derived from $VERSION, not hardcoded to
# :latest. Revert to :latest and confirm the version-match guard fails.
cat > "$SED_TMP" << 'SED'
s|^REGISTRY_IMAGE=.*|REGISTRY_IMAGE="${REGISTRY_BASE}:latest"|
SED
try "v0.9.2_registry_tag_latest" "registry image tag matches CLI version"

# v0.9.2: bin/cleat's spin_stop must emit \r\033[K (not just \r) to clear
# the rest of a longer spinner line before writing a shorter success message.
cat > "$SED_TMP" << 'SED'
/^spin_stop()/,/^}$/{
  s|\\r\\033\[K|\\r|g
}
SED
try "v0.9.2_cli_spin_stop_line_clear" "bin/cleat spin_stop clears line before writing"

# v0.10.0: docker must be in KNOWN_CAPS. Remove it, guard test should fail.
cat > "$SED_TMP" << 'SED'
s|^KNOWN_CAPS=(git ssh env hooks gh docker)$|KNOWN_CAPS=(git ssh env hooks gh)|
SED
try "v0.10.0_docker_in_known_caps" "docker listed in KNOWN_CAPS"

# v0.10.0: docker cap must mount the host docker socket when active. Neutralise
# the socket mount (replace with a no-op, NOT delete: the line sits inside an
# if/elif so deleting it leaves an empty then-body syntax error); the regression
# guard for socket mount should fail.
cat > "$SED_TMP" << 'SED'
s|mount_args+=(-v "\$_host_dsock:/var/run/docker.sock")|:|
SED
try "v0.10.0_docker_cap_socket_mount" "docker cap mounts host socket"

# vnext: the docker cap must bind the socket resolved from DOCKER_HOST / the
# active context, NOT a hard-coded /var/run/docker.sock. Hard-code it back; the
# rootless-socket test (expecting /run/user/<uid>) should fail.
cat > "$SED_TMP" << 'SED'
s|mount_args+=(-v "\$_host_dsock:/var/run/docker.sock")|mount_args+=(-v /var/run/docker.sock:/var/run/docker.sock)|
SED
try "vnext_docker_cap_engine_aware_sock" "host-local rootless daemon binds" "$CLI" "$CAPABILITIES_BATS"

# vnext: the missing-socket GUARD. A resolved socket that is not live must NOT be
# bound, because a missing bind SOURCE makes the engine create a directory on the
# host at that path. Bypass the liveness check; the missing-socket test should
# fail as a phantom mount reappears.
cat > "$SED_TMP" << 'SED'
s/_host_sock_is_live "\$_host_dsock"/true/
SED
try "vnext_docker_cap_sock_liveness_guard" "missing socket is NOT mounted" "$CLI" "$CAPABILITIES_BATS"

# vnext: a VM-backed daemon (Docker Desktop / Colima / OrbStack) must bind the
# in-VM /var/run/docker.sock, NOT the host context path the VM cannot bind
# (that regressed the fix's first cut). Make the VM branch use the host path;
# the VM-daemon test should fail.
cat > "$SED_TMP" << 'SED'
s|mount_args+=(-v /var/run/docker.sock:/var/run/docker.sock)|mount_args+=(-v "\$_host_dsock:/var/run/docker.sock")|
SED
try "vnext_docker_cap_vm_daemon_sock" "VM-backed daemon" "$CLI" "$CAPABILITIES_BATS"

# vnext: Lima-backed engines on LINUX (Colima ~/.colima, Rancher Desktop ~/.rd,
# plain Lima ~/.lima) are VM-backed but report host-local (not macOS, not Docker
# Desktop), so _docker_pool_is_vm detects them by their socket under $HOME. One
# mutation per engine so a per-pattern break cannot slip through a green suite.
cat > "$SED_TMP" << 'SED'
s#"\$HOME"/\.colima/\*|##
SED
try "vnext_docker_pool_colima" "Colima on Linux is detected as a VM" "$CLI" "$CAPABILITIES_BATS"

cat > "$SED_TMP" << 'SED'
s#"\$HOME"/\.rd/\*|##
SED
try "vnext_docker_pool_rancher" "Rancher Desktop" "$CLI" "$CAPABILITIES_BATS"

cat > "$SED_TMP" << 'SED'
s#|"\$HOME"/\.lima/\*##
SED
try "vnext_docker_pool_lima" "plain Lima" "$CLI" "$CAPABILITIES_BATS"

# vnext: the VM-detection case must be ANCHORED to $HOME, not a bare */.colima/*
# substring, or a host-local socket that merely contains such a segment (e.g.
# unix:///opt/.rd/docker.sock) is misrouted to the guardless in-VM bind (phantom
# host-directory risk). Un-anchor it; the incidental-path test should fail.
cat > "$SED_TMP" << 'SED'
s#"\$HOME"/\.colima/\*|"\$HOME"/\.rd/\*|"\$HOME"/\.lima/\*#*/.colima/*|*/.rd/*|*/.lima/*#
SED
try "vnext_docker_pool_home_anchor" "incidental .rd segment NOT under HOME" "$CLI" "$CAPABILITIES_BATS"

# vnext: _resolve_host_docker_sock must strip a trailing slash so an env-file
# DOCKER_HOST like 'unix:///var/run/docker.sock/' still binds the real socket.
# Stop stripping it; the trailing-slash test should fail.
cat > "$SED_TMP" << 'SED'
s#"\${_p%/}"#"$_p"#
SED
try "vnext_docker_cap_trailing_slash" "a trailing slash on DOCKER_HOST" "$CLI" "$CAPABILITIES_BATS"

# vnext: a TLS remote (tcp://…:2376) must warn that client certs are not
# forwarded into the cage. Stop flagging TLS; the TLS-warn test should fail.
cat > "$SED_TMP" << 'SED'
s#tcp://\*:2376) _tls=1 ;;#tcp://*:2376) _tls="" ;;#
SED
try "vnext_docker_cap_tls_warn" "a TLS remote" "$CLI" "$CAPABILITIES_BATS"

# vnext: TLS must be flagged off DOCKER_TLS_VERIFY too, not only the :2376 port
# convention. Neutralize that signal; the DOCKER_TLS_VERIFY warn test should fail.
cat > "$SED_TMP" << 'SED'
s#\[ -n "\${DOCKER_TLS_VERIFY:-}" \] && _tls=1#:#
SED
try "vnext_docker_cap_tls_verify_env" "DOCKER_TLS_VERIFY set warns" "$CLI" "$CAPABILITIES_BATS"

# vnext: a LOOPBACK tcp DOCKER_HOST is a host-local daemon, so the cap must bind
# the host socket, never forward 127.0.0.1 (which inside the box is the box).
# Through v1.4.2 that config got the socket bind. Remove the loopback branch; the
# loopback bind test should fail.
cat > "$SED_TMP" << 'SED'
/^_endpoint_is_loopback()/,/^}$/ s#^    127\.0\.0\.1|localhost) return 0 ;;#    NOMATCH_LOOPBACK) return 0 ;;#
SED
try "vnext_docker_cap_loopback_binds_socket" "loopback tcp DOCKER_HOST binds the host socket" "$CLI" "$CAPABILITIES_BATS"

# vnext: loopback detection must not swallow a ROUTABLE tcp daemon (that would
# bind a local socket for a genuinely remote engine). Make every tcp endpoint
# look like loopback; the routable-remote test should fail.
cat > "$SED_TMP" << 'SED'
/^_endpoint_is_loopback()/,/^}$/ s#^  return 1$#  return 0#
SED
try "vnext_docker_cap_loopback_not_overbroad" "routable tcp daemon is still treated as remote" "$CLI" "$CAPABILITIES_BATS"

# vnext: DOCKER_HOST must win over the active docker context for the socket
# source. Drop DOCKER_HOST from the precedence; the DOCKER_HOST-wins test fails.
cat > "$SED_TMP" << 'SED'
s#_docker_ep="\${DOCKER_HOST:-\$(_docker_context_endpoint)}"#_docker_ep="$(_docker_context_endpoint)"#
SED
try "vnext_docker_cap_docker_host_wins" "DOCKER_HOST wins over the context" "$CLI" "$CAPABILITIES_BATS"

# v0.10.0: docker cap must add a host-path identity mount + workdir so
# $(pwd) inside Cleat resolves to a host-valid path. Remove the identity
# mount; the path-remapping guard should fail.
cat > "$SED_TMP" << 'SED'
/mount_args+=(-v "\$_workspace:\$_workspace")/d
SED
try "v0.10.0_docker_cap_identity_mount" "docker cap mounts project at host path with workdir"

# v0.10.0: workspace trust must default-deny project .cleat caps in non-TTY
# contexts when no opt-in is provided. Remove the trust gate so project
# caps are applied unconditionally (the supply-chain regression guard
# should fail).
cat > "$SED_TMP" << 'SED'
s|if _resolve_project_trust "\$project" "\$trust_mode"; then|if true; then|
SED
try "v0.10.0_trust_default_deny" "skips project .cleat caps"

# v0.10.0: cmd_status must call resolve_caps with readonly mode so it
# never prompts. Remove the readonly argument and the "status never
# prompts" guard should fail.
cat > "$SED_TMP" << 'SED'
/# Resolve caps for display only/,/resolve_caps.*readonly/{
  s|resolve_caps "\$project" readonly|resolve_caps "\$project"|
}
SED
try "v0.10.0_status_readonly_trust" "cmd_status never prompts for trust"

# v0.10.0: the trust hash must be over the *canonical* cap list, not the
# raw .cleat file. If the hash includes comments/whitespace, comment
# edits trigger re-approval churn. Replace canonical hashing with raw
# file hashing and the hash-stability guard should fail.
cat > "$SED_TMP" << 'SED'
/^_hash_cleat_caps\(\)/,/^}$/{
  s|caps="\$(_read_caps_from_file "\$path" "\$box" \| _canonical_caps)"|caps="$(cat "$path")"|
}
SED
try "v0.10.0_trust_hash_canonical" "trust hash is over canonical caps"

# v0.10.0: _md5 on Linux uses md5sum which appends "  -" (stdin filename)
# after the hash. The `awk '{print $1}'` strip in _hash_cleat_caps must
# remain so the trust file stores pure hex. Removing it reintroduces the
# junk suffix and the hex-only guard should fail. Use `#` as sed
# delimiter since the source line contains many `|` characters.
cat > "$SED_TMP" << 'SED'
/^_hash_cleat_caps()/,/^}$/{
  s#| awk .*##
}
SED
try "v0.10.0_trust_hash_hex_strip" "trust hash is pure hex"

# v0.10.0: cleat resume after cleat rm must auto-create the container
# (not error out) so --continue can resume from the host-side session
# dir. Replace the cmd_run call with a plain `exit 1` and the regression
# test should fail (assert_success on cmd_resume).
cat > "$SED_TMP" << 'SED'
s#cmd_run "\$project"#exit 1#
SED
try "v0.10.0_resume_auto_creates" "cleat resume after cleat rm creates container"

# v0.10.0: cmd_rm must not touch the per-project session dir under
# ~/.claude/projects/. Append, inside cmd_rm only, an rm that clobbers the
# whole projects dir; the "leaves session dir untouched" regression test should
# fail. (Anchored on the per-container runtime-dir cleanup, which replaced the
# old /tmp cleanup lines when runtime state moved off /tmp.)
cat > "$SED_TMP" << 'SED'
/^cmd_rm()/,/^}$/{
  /rm -rf "\$CLEAT_RUN_DIR\/\${cname}"/a\
    rm -rf "${HOME}/.claude/projects" 2>/dev/null || true
}
SED
try "v0.10.0_cmd_rm_preserves_sessions" "cmd_rm leaves per-project session dir untouched"

# v0.10.0: docker cap must overlay the session dir at the host-path-
# encoded key (so Claude's host-path-derived session dir maps to the
# per-project overlay). Remove the second session-dir overlay under
# the docker cap and the guard should fail.
cat > "$SED_TMP" << 'SED'
/mount_args+=(-v "\${project_session_dir}:\/home\/coder\/\.claude\/projects\/\${_host_project_key}")/d
SED
try "v0.10.0_docker_cap_session_overlay" "docker cap overlays session dir at host-path key"

# v0.10.1: _do_pull must short-circuit when the version-tagged prebuilt
# image is already on disk. Force the cache check to always-false so
# every call hits the network, then fails (DOCKER_PULL_EXIT_CODE=1 in
# tests), then falls back to a local build: exactly what the regression
# test forbids.
# (pattern updated when the cache condition grew the arch check: see vnext_pull_cache_arch)
cat > "$SED_TMP" << 'SED'
s|if docker image inspect "\$target_image" > /dev/null 2>&1 \&\& _image_arch_ok "\$target_image"; then|if false; then|
SED
try "v0.10.1_pull_local_cache_short_circuit" "_do_pull reuses locally cached prebuilt without network call"

# v0.10.1: when the cache hit fires but `docker tag` silently fails,
# _do_pull must fall through to the network pull instead of returning
# success. Mutate the inner tag-success guard to unconditional truth so
# the success branch always fires regardless of the tag's exit code:
# the hardening regression test should fail (no fall-through warning,
# no network pull attempt).
cat > "$SED_TMP" << 'SED'
s|if docker tag "\$target_image" "\$IMAGE_NAME" > /dev/null 2>&1; then|if true; then|
SED
try "v0.10.1_pull_cache_tag_failure_fallthrough" "_do_pull falls through to network pull when cache-hit tag fails"

# v0.12.1: drift detection now prompts to recreate (interactive). Mutate
# cmd_start to drop the _resolve_config_drift call. Without it, drift
# silently goes undetected and users keep hitting the stale-cap container.
# The regression spy in regressions.bats should fail to set DRIFT_CALLED.
cat > "$SED_TMP" << 'SED'
/^cmd_start()/,/^}$/{
  /_resolve_config_drift "\$cname" "\$project"/d
}
SED
try "v0.12.1_drift_recreate_wired" "cmd_start invokes _resolve_config_drift"

# v0.12.1: the drift recreate prompt must interpret ANSI escapes. The prompt
# now routes through the shared _ask_yn helper, so mutate ITS `echo -en` back to
# `echo -n`: $BOLD/$RESET would then print as literal `\033[...]` strings. The
# regression test (pipes "y" into _resolve_config_drift) asserts no such literal
# appears, and this guards every prompt that uses _ask_yn, not just this one.
cat > "$SED_TMP" << 'SED'
s|echo -en "    ${_prompt}"|echo -n "    ${_prompt}"|
SED
try "v0.12.1_drift_prompt_ansi" "drift recreate prompt interprets ANSI escapes"

# v0.12.3: _settings_overlay_intact must also verify that each bind source
# inside the overlay dir is a regular file, not just that the dir exists.
# Mutate the per-file check out of the helper so it falls back to the old
# dir-only behavior. With the per-file guard removed, cmd_start no longer
# auto-recreates on partial rotation: it would fall through to
# `docker start` and the regression test's recreate assertions would fail.
cat > "$SED_TMP" << 'SED'
/^_settings_overlay_intact()/,/^}$/{
  /\[\[ -f "\$src" \]\] || return 1/d
}
SED
try "v0.12.3_overlay_intact_per_file_check" "cmd_start auto-recreates when overlay dir survives but a file is missing"

# ── upgrade-claude hardening (tested against upgrade_claude.bats) ────────────

# Channel validation must reject anything but stable/latest/semver. Neuter the
# regex guard so a shell-injection channel would slip through; the rejection
# test must then fail.
cat > "$SED_TMP" << 'SED'
s|if \[\[ ! "\$channel" =~ \$_semver \]\]; then|if false; then|
SED
try "upgrade_claude_channel_validation" "rejects a shell-injection channel without running anything" "$CLI" "$UPGRADE_BATS"

# The in-container install must run under pipefail, or a failed `curl` feeds
# empty input to bash (exit 0) and an unchanged image gets committed. Strip
# the `set -euo pipefail;` prefix and the guard test must fail.
cat > "$SED_TMP" << 'SED'
s|set -euo pipefail; ||
SED
# Filter is a regex matched against the test name: keep it free of the name's
# literal parentheses, which would otherwise be interpreted as a regex group
# and fail to match (selecting zero tests, which bats reports as success).
try "upgrade_claude_install_pipefail" "install command enables pipefail" "$CLI" "$UPGRADE_BATS"

# The commit must restore CMD ["bash"]; without it the committed image would
# re-run the installer instead of staying alive. Drop the --change flag.
cat > "$SED_TMP" << 'SED'
s|--change 'CMD \["bash"\]' ||
SED
try "upgrade_claude_commit_cmd_restore" "commits the result back over the working image" "$CLI" "$UPGRADE_BATS"

# ── Claude auto-update permission fix (entrypoint.sh) ────────────────────────

# The entrypoint must chown ~/.local after the UID remap, or the runtime user
# can't write the Claude Code binary store and `claude update` fails with
# EACCES. Delete the chown line; the entrypoint regression test must then fail.
cat > "$SED_TMP" << 'SED'
/chown -R "\$HOST_UID:\$HOST_GID" \/home\/coder\/\.local/d
SED
try "claude_update_local_chown" "chowns ~/.local" "$ENTRYPOINT" "$ENTRYPOINT_BATS"

# ── On-start Claude update check (bin/cleat, tested vs claude_update_check) ───

# The prompt must fire only when the remote version is strictly newer. Neuter
# the "already current" short-circuit so it would nag even when the image
# already runs the remote version; the equal-version test must then fail.
# Use `#` as the sed delimiter: the pattern contains `||`, which would
# otherwise be read as the `s|...|` delimiter and break the expression.
cat > "$SED_TMP" << 'SED'
s#\[\[ "\$remote" != "\$local_v" \]\] || return 0#[[ "$remote" != "$local_v" ]] || true#
SED
try "claude_check_strictly_newer" "no prompt when the image already runs the remote version" "$CLI" "$CLAUDE_BATS"

# CLEAT_CLAUDE_CHANNEL is user-controlled and is interpolated into a URL and
# the in-container shell command, so a non-stable/latest/semver value must be
# replaced with the safe default. Drop the fallback so a malicious channel
# would pass through; the injection-guard test must then fail.
# `#` delimiter again: the pattern contains `||`.
cat > "$SED_TMP" << 'SED'
s#\[\[ "\$channel" =~ \$_semver \]\] || channel="latest"#:#
SED
try "claude_check_channel_injection" "malicious CLEAT_CLAUDE_CHANNEL falls back to latest" "$CLI" "$CLAUDE_BATS"

# The check must never run in a non-interactive context (it would block scripts
# on a prompt). Remove the TTY guard; the "silent when non-interactive" test
# must then fail.
cat > "$SED_TMP" << 'SED'
/^  _is_tty || return 0$/d
SED
try "claude_check_tty_only" "silent when non-interactive" "$CLI" "$CLAUDE_BATS"

# ── Persistent per-container run dir (bin/cleat, tested vs run_dir.bats) ──────

# The settings overlay must mount from the persistent $CLEAT_RUN_DIR, not /tmp
# (where macOS rotation deletes the source and forces a recreate). Revert the
# overlay dir to the old /tmp scheme; the relocation test must then fail.
cat > "$SED_TMP" << 'SED'
s#local settings_overlay_dir="\$CLEAT_RUN_DIR/\${cname}/settings"#local settings_overlay_dir="/tmp/cleat-settings-${cname}"#g
SED
try "run_dir_settings_relocated" "settings overlay is mounted from CLEAT_RUN_DIR" "$CLI" "$RUN_DIR_BATS"

# The stale-mount check must look at the new-layout dir so pre-move containers
# (mounts under /tmp) and broken overlays force a recreate. Point it back at
# /tmp; the "intact when present" test must then fail (new-layout dir unseen).
cat > "$SED_TMP" << 'SED'
s#local overlay_dir="\$CLEAT_RUN_DIR/\${cname}/settings"#local overlay_dir="/tmp/cleat-settings-${cname}"#
SED
try "run_dir_intact_uses_new_path" "true when overlay dir" "$CLI" "$RUN_DIR_BATS"

# cmd_clean must prune orphaned run dirs (containers gone). Neuter the
# orphan test so nothing is pruned; the prune test must then fail.
cat > "$SED_TMP" << 'SED'
s#if ! container_exists "\$_cn"; then#if false; then#
SED
try "run_dir_clean_prunes_orphans" "prunes orphaned run dirs but keeps live" "$CLI" "$RUN_DIR_BATS"

# cmd_nuke must wipe the whole persistent run dir (it no longer self-cleans via
# /tmp rotation). Remove the wipe; the nuke test must then fail.
cat > "$SED_TMP" << 'SED'
/rm -rf "\$CLEAT_RUN_DIR" 2>\/dev\/null || true/d
SED
try "run_dir_nuke_wipes_all" "wipes the entire CLEAT_RUN_DIR" "$CLI" "$RUN_DIR_BATS"

# The clipboard bridge source must move too (parity with settings). Revert it to
# /tmp; the clip relocation test must then fail.
cat > "$SED_TMP" << 'SED'
s#local clip_dir="\$CLEAT_RUN_DIR/\${cname}/clip"#local clip_dir="/tmp/cleat-clip-${cname}"#
SED
try "run_dir_clip_relocated" "clipboard bridge source is under CLEAT_RUN_DIR" "$CLI" "$RUN_DIR_BATS"

# The hook spool source must move too. Revert it to /tmp; the hooks relocation
# test must then fail.
cat > "$SED_TMP" << 'SED'
s#local hooks_dir="\$CLEAT_RUN_DIR/\${cname}/hooks"#local hooks_dir="/tmp/cleat-hooks-${cname}"#
SED
try "run_dir_hooks_relocated" "hooks spool source is under CLEAT_RUN_DIR" "$CLI" "$RUN_DIR_BATS"

# cmd_clean's prune report must use if/fi, not `[[ ]] &&`: the latter makes the
# function (last statement in main) exit 1 on a successful run with 0 orphans.
# Revert to the `&&` form; the "exits 0 with nothing to prune" test must fail.
cat > "$SED_TMP" << 'SED'
s#if \[\[ \$_pruned -gt 0 \]\]; then info "Pruned \${_pruned} orphaned runtime dir(s)."; fi#[[ $_pruned -gt 0 ]] \&\& info "Pruned ${_pruned} orphaned runtime dir(s)."#
SED
try "run_dir_clean_exit_code" "exits 0 on a successful run with nothing to prune" "$CLI" "$RUN_DIR_BATS"

# v0.13.0: the container must mount the per-project isolated .claude.json, not
# the shared host file. Revert to the old host-file mount; the regression test
# (which asserts the bind source is the per-project store, never ~/.claude.json)
# must fail.
cat > "$SED_TMP" << 'SED'
s#mount_args+=(-v "\$project_claude_json:/home/coder/.claude.json")#mount_args+=(-v "${HOME}/.claude.json:/home/coder/.claude.json")#
SED
try "v0.13.0_claude_json_isolation" "container mounts an isolated .claude.json"

# v0.13.0: the summary "Project:" row must tell the truth under the docker cap
# (host path "(same path, sandboxed)", not "→ /workspace"). Revert the docker
# branch to the /workspace form; the regression test must fail.
cat > "$SED_TMP" << 'SED'
s#${display_path} ${DIM}(same path, sandboxed)${RESET}#${display_path} ${DIM}→${RESET} /workspace#
SED
try "v0.13.0_project_row_docker_cap" "summary Project row is truthful under the docker cap"

# v0.13.0: _ask_yn must treat a read FAILURE (EOF / redirected stdin) as DECLINE,
# not empty (which callers read as the [Y/n] default of yes). Revert to the old
# empty-on-EOF behavior; the EOF-decline test must fail.
cat > "$SED_TMP" << 'SED'
s#read -r _reply || { printf -v "$_var" '%s' 'n'; return 0; }#read -r _reply || _reply=""#
SED
try "v0.13.0_ask_yn_eof_declines" "EOF / redirected stdin yields decline" "$CLI" "$TERMINAL_UX_BATS"

# v0.13.0: the CLI self-update must skip a dirty/dev tree (else it nags
# "Update failed" every launch). Drop the guard; the dirty-tree skip test fails.
# Neutered rather than DELETED: the guard now sits inside the git-channel `if`,
# and deleting the only line of a then-block is a syntax error, which the
# harness reports as SKIPPED (no verdict) instead of a verdict.
cat > "$SED_TMP" << 'SED'
s@    _repo_is_clean || return 0@    :@
SED
try "v0.13.0_cli_update_skips_dirty_tree" "skips entirely on a dirty/dev tree" "$CLI" "$VERSION_BATS"

# v0.13.0: _apply_cli_update must check out the v-prefixed tag (latest_remote_tag
# returns a bare X.Y.Z; tags are vX.Y.Z). Drop the prefix; the real-git apply
# test (which asserts `checkout v9.9.9`) must fail.
cat > "$SED_TMP" << 'SED'
s#checkout "v${target}"#checkout "${target}"#
SED
try "v0.13.0_apply_checkout_v_prefix" "_apply_cli_update checks out v<tag>" "$CLI" "$VERSION_BATS"

# v0.13.0: the open-bridge shim must guard its stdin `cat` read behind a tty
# check, else an interactive `open` (and `./test.sh` on a terminal) blocks
# forever. Remove the guard; the regression test that greps for `[ ! -t 0 ]`
# in the shim must fail.
cat > "$SED_TMP" << 'SED'
s/ && \[ ! -t 0 \]//
SED
try "v0.13.0_openbridge_tty_guard" "open-bridge does not read stdin when fd0 is a tty" "$OPENBRIDGE" "$REGRESSIONS"

# v0.13.0: the test runner must feed bats stdin from /dev/null so an
# interactive run can't hang on a test that reads fd0. Drop the redirect; the
# regression test that greps test.sh for `</dev/null` on the bats call must
# fail. (Delete the token rather than rewriting the tail; a `&` in the sed
# replacement would expand to the whole match and leave `</dev/null` behind.)
cat > "$SED_TMP" << 'SED'
s#"\$f" </dev/null#"\$f"#
SED
try "v0.13.0_testsh_stdin_isolation" "test runner isolates bats stdin from the terminal" "$TEST_SH" "$REGRESSIONS"

# v0.13.0: the sandbox-break warning (`warn_sandbox`) must render its whole
# line in amber, not just the `!`, so the docker-socket caution matches the
# sandbox cap. Revert it to the marker-only form; the terminal_ux test that
# asserts the amber code runs straight into the message must fail.
cat > "$SED_TMP" << 'SED'
s|\${AMBER}! \$1\${RESET}|\${AMBER}!\${RESET} \$1|
SED
try "v0.13.0_warn_sandbox_full_amber" "the whole line is amber, matching the sandbox cap" "$CLI" "$TERMINAL_UX_BATS"

# v0.13.1: the session env must disable Claude's launch-time auto-updater
# (the freeze). Drop the flag from CLAUDE_ENV; the regression test that asserts
# the session exec carries DISABLE_AUTOUPDATER=1 must fail.
cat > "$SED_TMP" << 'SED'
s| -e DISABLE_AUTOUPDATER=1||
SED
try "v0.13.1_disable_autoupdater" "session env disables Claude's launch-time auto-updater"

# v0.13.1: exec_claude must wait for the entrypoint UID remap before launching.
# Delete the call; the test that asserts a `id -u coder` probe was issued fails.
cat > "$SED_TMP" << 'SED'
/_wait_for_coder_remap "\$cname"/d
SED
try "v0.13.1_remap_wait" "session waits for the UID remap before launching"

# v0.13.1: clip-daemon must use a per-uid runtime dir (CLEAT_CLIP_DIR), not the
# shared /tmp/clip.sock. Revert it to a fixed path; the test that points it at a
# per-uid dir and checks the socat bind path must fail.
cat > "$SED_TMP" << 'SED'
s|"\${CLEAT_CLIP_DIR:-/tmp/cleat-run-\$(id -u)}"|"/tmp/cleat-run-mutant"|
SED
try "v0.13.1_clip_per_uid_dir" "clip-daemon uses a per-uid runtime dir" "$CLIP_DAEMON" "$REGRESSIONS"

# v0.13.1: the clip shim must resolve the SAME per-uid socket as clip-daemon.
# Revert it to the legacy /tmp/clip.sock; the path-consistency test must fail.
cat > "$SED_TMP" << 'SED'
s|SOCK="\${CLEAT_CLIP_DIR:-/tmp/cleat-run-\$(id -u)}/clip.sock"|SOCK="/tmp/clip.sock"|
SED
try "v0.13.1_clip_shim_sock_path" "clip shim and clip-daemon resolve the SAME socket path" "$CLIP_SHIM" "$REGRESSIONS"

# v0.13.1: the entrypoint must clear stale clip runtime files (as root) before
# dropping to coder. Delete the cleanup line; the entrypoint test that asserts
# the removal must fail.
cat > "$SED_TMP" << 'SED'
/rm -rf \/tmp\/cleat-run-/d
SED
try "v0.13.1_entrypoint_clip_cleanup" "clears stale clipboard runtime files before dropping to coder" "$ENTRYPOINT" "$ENTRYPOINT_BATS"

# boxes: the default/"main" box session key MUST stay byte-identical to the
# legacy <basename>-<hash8> key. Drop the `main` exemption in the helper so the
# default box would gain a "-main" suffix; the byte-identity test must fail.
# (Folding a suffix into the default would orphan every user's session history.)
cat > "$SED_TMP" << 'SED'
s| && "\$box" != "main"||
SED
try "boxes_default_session_key_byte_identical" "the 'main' box is byte-identical to the default" "$CLI" "$BOX_NAME_BATS"

# boxes: the default/"main" box CONTAINER NAME must stay byte-identical to the
# legacy cleat-<dir>-<hash8> (no -main suffix on disk). Drop the `main` exemption
# inside container_name_for so the default would gain a "-main" suffix; the
# byte-identity test must fail. (Folding a suffix would orphan every existing
# container.)
cat > "$SED_TMP" << 'SED'
/^container_name_for()/,/^}$/{
  s| && "\$box" != "main"||
}
SED
try "boxes_main_container_name_byte_identical" "the 'main' box is byte-identical to the no-box name" "$CLI" "$CONTAINER_NAME_BATS"

# boxes: cmd_run must thread the active box into the session key so two boxes
# over one workspace get SEPARATE Claude sessions/.claude.json (the cross-box
# bleed/corruption guard). Drop the box arg at the call site so every box falls
# back to the default key; the per-box session-overlay test must fail.
cat > "$SED_TMP" << 'SED'
s|_derive_project_session_key "\$project" "\$box"|_derive_project_session_key "\$project"|
SED
try "boxes_session_key_threads_box" "a named box gets its own session overlay dir" "$CLI" "$BOXES_BATS"

# boxes: a named box's caps come from .cleat.<box> (REPLACE, not merge), which
# is what enables least privilege (a box with FEWER caps than the project
# default). Make _project_caps_file return .cleat for a named box instead of
# .cleat.<box>; the dev box would then inherit .cleat's docker cap and the
# replace-not-merge test must fail.
cat > "$SED_TMP" << 'SED'
/^_scoped_section()/,/^}$/{
  s|    printf 'box.%s.%s' "\$box" "\$kind"|    printf '%s' "\$kind"|
}
SED
try "boxes_caps_file_replace_not_merge" "a box can have FEWER caps" "$CLI" "$BOXES_BATS"

# boxes: a box description must actually persist to its host-side file (so it
# survives stop/resume/recreate). Make _box_desc_write drop the text to
# /dev/null; the set/show round-trip test must fail.
cat > "$SED_TMP" << 'SED'
/^_box_desc_write()/,/^}$/{
  s|> "\$(_box_desc_file "\$cname")"|> /dev/null|
}
SED
try "boxes_desc_persists" "set then show round-trips the description" "$CLI" "$BOXES_BATS"

# boxes: a box description is user-controlled text and must be printed as DATA
# (printf %s), never through echo -e, which would interpret backslash escapes /
# ANSI in the text. Turn the %s back into %b so the text is interpreted; the
# "shown LITERALLY in cleat status" hardening test must fail.
cat > "$SED_TMP" << 'SED'
s|%b%s%b|%b%b%b|
SED
try "boxes_desc_printed_as_data" "shown LITERALLY in cleat status" "$CLI" "$BOX_HARDENING_BATS"

# boxes: `cleat rm <box>` must remove the box's host-side description
# unconditionally (even for a box that was only ever describe'd, never started).
# Delete the unconditional removal; the rm-without-container test must fail.
cat > "$SED_TMP" << 'SED'
/_box_desc_remove "\$cname"/d
SED
try "boxes_rm_removes_desc_unconditional" "removes the description even when no container existed" "$CLI" "$BOX_HARDENING_BATS"

# boxes: cmd_status must confirm a candidate's /workspace mount source IS this
# project (guards the cross-project hash-substring collision). Drop the check;
# a sibling project's container would then surface as a phantom box.
cat > "$SED_TMP" << 'SED'
/\[\[ "\$_src" == "\$project" || "\$_src" == "\$(_fork_dir "\$_n")" \]\] || continue/d
SED
try "boxes_status_mount_source_guard" "ignores a container whose /workspace mount is a different project" "$CLI" "$BOXES_BATS"

# fork-storm: clip-daemon must give socat an inactivity timeout (-T) so a hung
# clipboard handler can't accumulate and exhaust the container's PIDs. Strip the
# -T; the regression test that asserts socat receives `-T 5` must fail.
cat > "$SED_TMP" << 'SED'
s| -T "\$IDLE_TIMEOUT"||
SED
try "clip_daemon_socat_idle_timeout" "socat an inactivity timeout" "$CLIP_DAEMON" "$REGRESSIONS"

# docker-cap: each session exec must re-resolve the socket group (self-heal) so
# a long-running container survives a Docker Desktop socket-GID change. Delete
# the _ensure_docker_access calls; the cleat-shell self-heal test must fail.
cat > "$SED_TMP" << 'SED'
/_ensure_docker_access "\$cname"/d
SED
try "docker_cap_session_self_heal" "cleat shell self-heals the socket group" "$CLI" "$DOCKER_CAP_BATS"

# boxes/efficiency: cmd_ps reads the workspace path as the TRAILING field of one
# combined inspect (box|running|path) and extracts it with `${rest#*|}`
# (remove-up-to-FIRST '|') precisely so a literal '|' in the path survives. Flip
# it to `##*|` (greedy, remove-up-to-LAST) and a piped path is truncated to its
# tail; the "literal '|' survives" test must fail.
cat > "$SED_TMP" << 'SED'
s~rest#\*|}~rest##*|}~
SED
try "boxes_ps_path_pipe_robust" "literal '|' in the project path survives" "$CLI" "$BOXES_BATS"

# boxes/efficiency: cmd_status must reuse State.Running from its single
# discovery inspect rather than re-probing each named box with
# is_running/container_exists. Drop the pre-resolved running arg at the call
# site; the named box then re-probes (and, in the test setup, mis-reports as
# stopped), so the "running state comes from the discovery inspect" test fails.
cat > "$SED_TMP" << 'SED'
s|_status_box_row "\$_b" "\$_n" "\$_running"|_status_box_row "$_b" "$_n"|
SED
try "boxes_status_running_from_inspect" "running state comes from the discovery inspect" "$CLI" "$BOXES_BATS"

# v0.15.0: _browser_claim_url must CONSUME the bridge file (atomic rename), so
# only one of several racing watchers opens a given URL. Swap the consuming `mv`
# for a non-consuming `cp`: the file persists, a second watcher claims the same
# URL too, and the "consumes each URL once" regression then fails.
cat > "$SED_TMP" << 'SED'
s|mv "\$bridge_file" "\$claim"|cp "\$bridge_file" "\$claim"|
SED
try "v0.15.0_browser_consume_once" "browser bridge consumes each URL once"

# v0.15.0: _browser_watcher must self-exit when its run dir is removed, so an
# orphan from a crashed session stops re-opening URLs instead of spinning
# forever. Delete the clip_dir-gone guard: the orphan-cleanup test then sees the
# watcher keep running after rm and fails.
cat > "$SED_TMP" << 'SED'
/\[ -d "\$clip_dir" \] || { _bw_cleanup; exit 0; }/d
SED
try "v0.15.0_watcher_orphan_exit" "self-exits when its run dir is removed" "$CLI" "$BROWSER_BRIDGE_BATS"

# v0.15.0: the release highlight shows for a BOUNDED number of launches
# (RELEASE_HIGHLIGHT_MAX_SHOWS) then goes quiet, not forever. Delete the cap
# check so it shows on every launch: the "first 3 launches, then goes silent"
# test then sees output on the 4th launch and fails.
cat > "$SED_TMP" << 'SED'
/"\$shown" -ge "\$RELEASE_HIGHLIGHT_MAX_SHOWS"/d
SED
try "v0.15.0_highlight_bounded_cap" "first 3 launches" "$CLI" "$WHATS_NEW_BATS"

# The release-highlight headline must announce the correct version. At the 1.0.0
# milestone the highlight's editorial version equals VERSION, so the old
# hardcoded-vs-${VERSION} distinction is unobservable; this instead guards that
# the copy literally says the right version. Corrupt the version in the headline:
# the "fresh install" test (which pins "New in v1.4.0") then fails.
cat > "$SED_TMP" << 'SED'
s/New in v1.4.0/New in v9.9.9/
SED
try "v0.15.0_highlight_label_frozen" "fresh install" "$CLI" "$WHATS_NEW_BATS"

# v1.4.0: the release highlight also announces the Homebrew channel. Corrupt the
# Homebrew support line so the "fresh install" test's Homebrew assertion fails,
# proving the brew line is actually guarded rather than only present.
cat > "$SED_TMP" << 'SED'
s/Homebrew is now a first-class install/Homebrew support landed/
SED
try "v1.4.0_highlight_brew_line" "fresh install" "$CLI" "$WHATS_NEW_BATS"

# v1.4.1: the on-start second-install notice. All three seds are range-scoped to
# the function body so they cannot touch the byte-identical status Install block
# (a different function) or any other function's identical guard line.
# M1: relax the ">1 install" condition so the notice fires on a single install.
cat > "$SED_TMP" << 'SED'
/^_maybe_warn_multiple_installs()/,/^}$/ s/(( _count > 1 ))/(( _count > 0 ))/
SED
try "v1.4.1_install_notice_count_gt1" "silent when there is exactly one install" "$CLI" "$INSTALL_NOTICE_BATS"

# M2: drop the CLEAT_NO_INSTALL_CHECK kill switch so it is ignored.
cat > "$SED_TMP" << 'SED'
/^_maybe_warn_multiple_installs()/,/^}$/ { /CLEAT_NO_INSTALL_CHECK/d }
SED
try "v1.4.1_install_notice_killswitch" "respects the CLEAT_NO_INSTALL_CHECK kill switch" "$CLI" "$INSTALL_NOTICE_BATS"

# M3: drop THIS notice's TTY gate (range-scoped, not the global _is_tty guard
# every other on-start notice shares) so it runs on a non-TTY.
cat > "$SED_TMP" << 'SED'
/^_maybe_warn_multiple_installs()/,/^}$/ { /_is_tty || return 0/d }
SED
try "v1.4.1_install_notice_tty_only" "silent on a non-interactive" "$CLI" "$INSTALL_NOTICE_BATS"

# v1.4.2: RELEASE_HIGHLIGHT_VERSION must equal VERSION or the on-start highlight
# is silently disabled (the v1.4.1 miss). Corrupt the gate to a stale value: the
# source-lockstep regression test reads both real constants from bin/cleat, sees
# them differ, and fails, proving it guards the constant.
cat > "$SED_TMP" << 'SED'
s/^RELEASE_HIGHLIGHT_VERSION="[^"]*"/RELEASE_HIGHLIGHT_VERSION="0.0.0"/
SED
try "v1.4.2_highlight_gate_lockstep" "RELEASE_HIGHLIGHT_VERSION ships in lockstep with VERSION" "$CLI" "$REGRESSIONS"

# v0.15.0: the config-drift notice must be plain text, not a bordered
# _notice_box. Mutate the non-TTY drift line's `info` back to `_notice_box`:
# the box border returns and the "plain text, not a box" regression test trips
# on the "┌" it refutes.
cat > "$SED_TMP" << 'SED'
s|info "\(.*Recreate to apply.*\)|_notice_box "\1|
SED
try "v0.15.0_drift_notice_plain_text" "config-drift notice is plain text"

# v0.15.0: the image-rebuild notice must not open with a stray blank line.
# Re-add the `echo ""` (inline, before the info) so the notice is preceded by a
# newline again: the "no leading blank line" regression test then trips.
cat > "$SED_TMP" << 'SED'
s|info "Cleat image is out of date|echo ""; info "Cleat image is out of date|
SED
try "v0.15.0_rebuild_notice_no_leading_blank" "image-rebuild notice has no leading blank line"

# v0.15.0: the config fingerprint must NOT depend on the CLI version, or every
# release fires a false "caps or env keys differ" drift notice on unchanged
# containers. Re-fold version into the hash (inline, before the sha256sum line):
# the "version bump alone does not trigger config drift" regression then sees the
# two hashes diverge across a version change and fails.
cat > "$SED_TMP" << 'SED'
s|if command -v sha256sum|fingerprint_input+="version:\${VERSION}"; if command -v sha256sum|
SED
try "v0.15.0_fingerprint_excludes_version" "version bump alone does not trigger config drift"

# v0.15.0: caps are sorted before hashing so cap order can't drift the print.
# Drop the cap `| sort`: (git ssh) and (ssh git) then hash differently and the
# "stable regardless of cap order" test fails.
cat > "$SED_TMP" << 'SED'
s#ACTIVE_CAPS\[@\]}" | sort#ACTIVE_CAPS[@]}"#
SED
try "v0.15.0_fingerprint_cap_sort" "stable regardless of cap order" "$CLI" "$CAPABILITIES_BATS"

# v0.15.0: env keys are sorted INSIDE compute_config_fingerprint (not trusting
# the caller's arg order). Drop the env `| sort`: a reordered arg list then
# drifts the hash and the "stable regardless of env-arg order" test fails.
cat > "$SED_TMP" << 'SED'
s#"\$_ekeys" | sort#"\$_ekeys"#
SED
try "v0.15.0_fingerprint_env_sort" "stable regardless of env-arg order" "$CLI" "$CAPABILITIES_BATS"

# v0.15.0: env VALUES are excluded from the fingerprint (only keys matter), so a
# value change never forces a recreate. Hash the full KEY=VALUE instead of the
# key: a value change then drifts the hash and the "ignores env values" test fails.
cat > "$SED_TMP" << 'SED'
s|_ekeys+="${arg%%=\*}"|_ekeys+="${arg}"|
SED
try "v0.15.0_fingerprint_ignores_values" "ignores env values" "$CLI" "$CAPABILITIES_BATS"

# v0.15.0: CLAUDE_CHECK_INTERVAL (10-min cadence) must be pinned on the STALE
# side: a check past the window proceeds. Bump it to a huge value (which would
# silently stop periodic re-checks): the "stale check ... is not throttled" test
# then sees the prompt suppressed and fails.
cat > "$SED_TMP" << 'SED'
s/CLAUDE_CHECK_INTERVAL=600/CLAUDE_CHECK_INTERVAL=6000/
SED
try "v0.15.0_claude_check_interval_pinned" "a stale check" "$CLI" "$CLAUDE_BATS"

# v0.15.0: CLAUDE_ENV is the fixed env forced into every session; its key set
# must stay exactly {HOME, DISABLE_AUTOUPDATER, PATH, TERM} (+ COLORTERM when
# the host has one) so no other host state leaks in. Inject an extra var: the
# "injects exactly" test sees a stray key and fails. (TERM itself became a
# deliberate entry when terminfo forwarding shipped; the canary is LANG now.)
cat > "$SED_TMP" << 'SED'
s|CLAUDE_ENV=(-e HOME=/home/coder|CLAUDE_ENV=(-e LANG=C -e HOME=/home/coder|
SED
try "v0.15.0_session_env_exact_set" "injects exactly" "$CLI" "$EXEC_CLAUDE_BATS"

# v0.15.1: the bring-up block is one contiguous coloured group: the cached
# "Image ready" line must NOT carry a leading blank (a rebuild's "Image rebuilt"
# flows straight into it). Re-add the `echo ""` in front: the "no leading blank"
# terminal_ux test then sees Image-ready pushed to line 2 and fails.
cat > "$SED_TMP" << 'SED'
s|success "Image ready \${RESET}\${DIM}(cached)"|echo ""; &|
SED
try "v0.15.1_image_ready_no_leading_blank" "opens the bring-up with no leading blank" "$CLI" "$TERMINAL_UX_BATS"

# v0.15.1: the release highlight ends with a trailing blank so it owns its own
# separation from the bring-up that follows. Delete that trailing echo "" (the
# one after the changelog line, before the _ONSTART_GAP_OPEN flag): the "trailing
# blank separates the highlight" test then sees the changelog line abut the
# sentinel and fails. (Anchor updated v0.16.4 when the comment changed.)
cat > "$SED_TMP" << 'SED'
/# pressure block follows\./{n;d;}
SED
try "v0.15.1_highlight_trailing_blank" "trailing blank separates the highlight" "$CLI" "$WHATS_NEW_BATS"

# v0.15.1: a stopped container whose baked-in bind source has vanished (the
# macOS SSH agent socket rotates every reboot) must be recreated, not handed to
# `docker start` (which aborts with an opaque OCI error). Neuter the missing-
# source check so it always reports present: the rotated-SSH-socket regression
# then sees `docker start` instead of a recreate and fails.
cat > "$SED_TMP" << 'SED'
s#\[\[ -e "\$src" \]\] || return 1#true#
SED
try "v0.15.1_bind_sources_vanished_recreates" "rotated SSH-agent socket after reboot recreates"

# v0.15.1: the entrypoint must chown ~/.cache after the UID remap so the Claude
# installer can mkdir its staging dir. Drop the chown: the "chowns ~/.cache"
# entrypoint test then no longer sees it logged and fails.
cat > "$SED_TMP" << 'SED'
/chown -R "\$HOST_UID:\$HOST_GID" \/home\/coder\/.cache/d
SED
try "v0.15.1_entrypoint_cache_chown" "chowns ~/.cache" "$ENTRYPOINT" "$ENTRYPOINT_BATS"

# vnext: the entrypoint must chown the shell rc files after the UID remap, or a
# [setup] payload that appends to ~/.bashrc or ~/.profile (rustup, the dotnet
# install script) dies with EACCES under `bash -e` on every non-1000 host.
# Drop .bashrc from the chown list: the "shell rc files" test must fail.
# Delete the line outright (a rename to .bashrc-nope would still satisfy a
# --partial match on the prefix, and the real bug was an ABSENT chown anyway).
# The remaining continuations stay syntactically valid.
cat > "$SED_TMP" << 'SED'
/^  \/home\/coder\/\.bashrc \\$/d
SED
try "vnext_entrypoint_rc_chown" "shell rc files" "$ENTRYPOINT" "$ENTRYPOINT_BATS"

# vnext: ~/.config must be chowned too, or `mkdir ~/.config/<tool>` is EACCES.
# Drop just the operand, leaving `... .bash_logout \` + `2>/dev/null || true`,
# which is still a valid command.
cat > "$SED_TMP" << 'SED'
s@^  /home/coder/\.config 2>/dev/null@  2>/dev/null@
SED
try "vnext_entrypoint_config_chown" "create its config dir" "$ENTRYPOINT" "$ENTRYPOINT_BATS"

# vnext: that .config chown must stay NON-recursive. The gh cap bind-mounts the
# host's ~/.config/gh over the subdirectory, so a -R rewrites the ownership of
# the user's real host files. Make it recursive: the non-recursive test fails.
cat > "$SED_TMP" << 'SED'
s@^chown "\$HOST_UID:\$HOST_GID" \\$@chown -R "$HOST_UID:$HOST_GID" \\@
SED
try "vnext_entrypoint_config_not_recursive" "NON-recursively" "$ENTRYPOINT" "$ENTRYPOINT_BATS"

# vnext: boxes must be created with --init (tini as PID 1) or `su` leaves
# zombies unreaped until the pids cap wedges the box. Drop the flag: the
# regression test asserting the recorded docker run contains --init fails.
cat > "$SED_TMP" << 'SED'
/^    --init \\$/d
SED
try "vnext_init_reaper" "containers are created with --init"

# vnext: the session script must exit with CLAUDE's status, not the
# clip-daemon wait's 0. Strip the rc capture/propagation: the test asserting
# the script exits with claude's rc fails.
cat > "$SED_TMP" << 'SED'
/_CLAUDE_RC/d
SED
try "vnext_claude_exit_code" "exit code survives clip-daemon cleanup"

# vnext: docker exec stderr must surface on failure, not vanish. Revert to
# the pre-fix 2>/dev/null: the stderr-surfacing test fails.
cat > "$SED_TMP" << 'SED'
s|2>"\$_exec_err"|2>/dev/null|
SED
try "vnext_exec_stderr" "stderr surfaces when the session fails"

# vnext: the terminal must be restored after every interactive session exec
# (raw mode / alt screen / mouse tracking survive a crashed claude). Drop the
# restore calls: the restore regression test fails.
cat > "$SED_TMP" << 'SED'
/^  _restore_terminal$/d
SED
try "vnext_restore_terminal" "restores terminal state after docker exec"

# vnext: the clean-exit cursor-up erase must be TTY-gated so pipes stay
# clean (and a masked crash can't have its evidence deleted). Make it
# unconditional again: the piped-output test fails.
cat > "$SED_TMP" << 'SED'
s|_is_tty && printf|printf|
SED
try "vnext_clean_end_erase_tty_gated" "no cursor-up erase into a pipe"

# vnext: the reaper-drift prompt must recognize an existing init reaper via
# HostConfig "Init":true. Break the detection so every box looks pre-init:
# the "silent when the box already has an init reaper" test fails.
cat > "$SED_TMP" << 'SED'
s|"Init":true|"Init":NEVERTRUE|
SED
try "vnext_init_detect_true" "already has an init reaper" "$CLI" "$INIT_RECREATE_BATS"

# vnext: cmd_start/cmd_resume must actually consult the reaper-drift check.
# Delete the call sites: the call-site test fails.
cat > "$SED_TMP" << 'SED'
/_maybe_prompt_init_recreate "\$cname"/d
SED
try "vnext_init_recreate_callsite" "cmd_start consults the reaper-drift check" "$CLI" "$INIT_RECREATE_BATS"

# vnext: pulls must be pinned to the daemon arch so a wrong single-arch
# manifest fails loudly into the local-build fallback. Drop the pin: the
# --platform test fails.
cat > "$SED_TMP" << 'SED'
/platform_args=(--platform/d
SED
try "vnext_pull_platform_pin" "pull pins --platform to the daemon arch" "$CLI" "$ARCH_BATS"

# vnext: an arch-mismatched cached ghcr image must not short-circuit the
# pull (it would put the emulated image back into service). Drop the arch
# check from the cache condition: the mismatch test fails.
cat > "$SED_TMP" << 'SED'
s|&& _image_arch_ok "\$target_image"||
SED
try "vnext_pull_cache_arch" "cached prebuilt does not short-circuit" "$CLI" "$ARCH_BATS"

# vnext: _image_arch_ok must compare image arch to daemon arch, not merely
# check non-emptiness. Gut the comparison: the emulation test fails.
cat > "$SED_TMP" << 'SED'
s|\[\[ "\$have" == "\$want" \]\]|[[ -n "$have" ]]|
SED
try "vnext_arch_compare" "fails when the image would run emulated" "$CLI" "$ARCH_BATS"

# vnext: cmd_run must treat a wrong-arch image as missing. Neutralize the
# gate: the cmd_run re-acquire test fails.
cat > "$SED_TMP" << 'SED'
s|elif ! _image_arch_ok; then|elif false; then|
SED
try "vnext_run_arch_gate" "cmd_run re-acquires a wrong-arch image" "$CLI" "$ARCH_BATS"

# vnext: cmd_build must treat a wrong-arch image as missing. Neutralize the
# gate: the cmd_build re-acquire test fails.
cat > "$SED_TMP" << 'SED'
s|if _image_arch_ok; then|if true; then|
SED
try "vnext_build_arch_gate" "cmd_build re-acquires a wrong-arch image" "$CLI" "$ARCH_BATS"

# vnext: the per-box memory limit must come from resolve_box_memory, not a
# hardcoded 8g that exceeds whole Docker Desktop VMs. Re-hardcode it: the
# wiring test (configured 3g must reach docker run) fails.
cat > "$SED_TMP" << 'SED'
s|--memory "\$box_memory"|--memory 8g|
SED
try "vnext_memory_resolved" "configured memory limit reaches docker run" "$CLI" "$RESOURCES_BATS"

# vnext: swap must be pinned to the memory limit (a runaway box OOMs in its
# own cgroup instead of thrashing VM swap). Drop the pin: the wiring test
# asserting --memory-swap fails.
cat > "$SED_TMP" << 'SED'
/--memory-swap "\$box_memory"/d
SED
try "vnext_memory_swap_pinned" "swap pinned equal" "$CLI" "$RESOURCES_BATS"

# vnext: project-supplied memory must be clamped to 8g (untrusted repo
# config can't re-introduce overcommit). Raise the clamp out of reach: the
# clamp test fails.
cat > "$SED_TMP" << 'SED'
s|> 8589934592|> 999999999999999|
SED
try "vnext_memory_project_clamp" "above 8g is clamped" "$CLI" "$RESOURCES_BATS"

# vnext: resources must be part of the config fingerprint so a changed limit
# surfaces the drift notice. Drop them: the fingerprint test fails.
cat > "$SED_TMP" << 'SED'
/resources:memory=/d
SED
try "vnext_memory_fingerprint" "memory changes the fingerprint" "$CLI" "$RESOURCES_BATS"

# vnext: sessions must pin node's heap to the box's real budget. Drop the
# pin: the heap test fails.
cat > "$SED_TMP" << 'SED'
/NODE_OPTIONS=--max-old-space-size/d
SED
try "vnext_node_heap_pin" "pins node's heap" "$CLI" "$RESOURCES_BATS"

# vnext: the VM-derived default must be a quarter of the VM (clamped), not
# the whole of it. Break the divisor: the scaling test (24 GiB VM → 6g, which
# is strictly between the 4g floor and 8g cap) sees 8g (24 → capped) and fails.
cat > "$SED_TMP" << 'SED'
s|vm_bytes / 4 / 1073741824|vm_bytes / 1073741824|
SED
try "vnext_memory_default_quarter" "default scales with a bigger VM" "$CLI" "$RESOURCES_BATS"

# 2026-06-14: the default ceiling is floored at 4g (a 1M-context session is too
# tight at 2g). Defeat the floor (small VMs fall through to the raw quarter, 2g):
# the "floored at 4g" test sees 2g and fails.
cat > "$SED_TMP" << 'SED'
s|quarter_gb < 4|quarter_gb < 0|
SED
try "bugfix_memory_floor_4g" "floored at 4g" "$CLI" "$RESOURCES_BATS"

# vnext: prune must never remove the CURRENT version's prebuilt tag. Drop
# the guard: the "never the current version" test fails.
cat > "$SED_TMP" << 'SED'
/\[\[ "\$tag" == "\${REGISTRY_BASE}:v\${VERSION}" \]\] \&\& continue/d
SED
try "vnext_prune_keeps_current" "never the current version" "$CLI" "$PRUNE_BATS"

# vnext: the pressure check must offer the prune when bloat passes the
# threshold. Push the threshold out of reach: the offer test fails.
cat > "$SED_TMP" << 'SED'
s|_PRESSURE_BLOAT_MB_THRESHOLD=5120|_PRESSURE_BLOAT_MB_THRESHOLD=99999999|
SED
try "vnext_pressure_bloat_threshold" "offers prune when bloat passes" "$CLI" "$PRUNE_BATS"

# vnext: the overload notice must compare promised limits to the VM size.
# Invert the comparison out of existence: the overcommit warning test fails.
cat > "$SED_TMP" << 'SED'
s|(( sum_gb > vm_gb ))|(( sum_gb > vm_gb * 1000 ))|
SED
try "vnext_pressure_overcommit" "warns when running limits overcommit" "$CLI" "$PRUNE_BATS"

# vnext: TERM must be forwarded into sessions (docker exec -t doesn't
# propagate the terminal type; a terminfo mismatch corrupts keys/colors).
# Drop the forward: the pinned key-set test fails.
cat > "$SED_TMP" << 'SED'
/CLAUDE_ENV+=(-e "TERM=/d
SED
try "vnext_term_forwarded" "injects exactly" "$CLI" "$EXEC_CLAUDE_BATS"

# vnext: the routine auto-GC after pull/build/rebuild is what keeps daily
# drift rebuilds from accreting ~120 GB of orphans. Delete all four silent
# call sites: the marker-file auto-GC tests fail.
cat > "$SED_TMP" << 'SED'
/cmd_prune > \/dev\/null 2>&1 || true/d
SED
try "vnext_autogc_callsites" "auto-GC" "$CLI" "$PRUNE_BATS"

# vnext: prune's dangling query must stay label-scoped to cleat-owned
# images; unscoped it deletes EVERY project's dangling images. Strip the
# label filter: the ownership-filters test fails.
cat > "$SED_TMP" << 'SED'
s| -f label=sh.cleat.version||
SED
try "vnext_prune_label_filter" "queries docker with the cleat ownership filters" "$CLI" "$PRUNE_BATS"

# vnext: prune's tag query must stay scoped to the cleat registry repo.
# Unscope it: the ownership-filters test fails.
cat > "$SED_TMP" << 'SED'
s|docker images "\$REGISTRY_BASE" --format|docker images --format|
SED
try "vnext_prune_repo_scope" "queries docker with the cleat ownership filters" "$CLI" "$PRUNE_BATS"

# vnext: main()'s session-launching verbs must reach the pressure check.
# Delete the call site: the marker test fails.
cat > "$SED_TMP" << 'SED'
/^    _maybe_check_docker_pressure$/d
SED
try "vnext_pressure_main_callsite" "session-launching commands consult the pressure check" "$CLI" "$PRUNE_BATS"

# vnext: status must flag an EMULATED image (arch mismatch), not a native
# one. Flip the comparison: both status-arch tests fail.
cat > "$SED_TMP" << 'SED'
s|"\$iarch" != "\$darch"|"$iarch" == "$darch"|
SED
try "vnext_status_emulated" "status flags an emulated image" "$CLI" "$ARCH_BATS"

# vnext: the user-facing reason for a wrong-arch re-fetch must be printed at
# the acquisition gates. Delete the call sites: the gate tests fail.
cat > "$SED_TMP" << 'SED'
/^    _warn_image_emulated$/d
SED
try "vnext_warn_emulated_callsites" "re-acquires a wrong-arch image and says why" "$CLI" "$ARCH_BATS"

# vnext: status must surface a positive zombie count. Invert the gate: the
# zombie-status test fails.
cat > "$SED_TMP" << 'SED'
s|(( _zombies > 0 ))|(( _zombies < 0 ))|
SED
try "vnext_status_zombie_gate" "status surfaces the unreaped-zombie count" "$CLI" "$INIT_RECREATE_BATS"

# vnext: cmd_resume must consult the reaper-drift check independently of
# cmd_start (resume is the verb that revives pre---init boxes). Delete only
# the resume call site: the resume call-site test fails.
cat > "$SED_TMP" << 'SED'
/^cmd_resume() {$/,/^}$/{
  /_maybe_prompt_init_recreate "\$cname"/d
}
SED
try "vnext_resume_init_recreate_callsite" "cmd_resume consults the reaper-drift check" "$CLI" "$INIT_RECREATE_BATS"

# vnext: status's own VM-overcommit line (distinct from the on-start warn).
# Push the comparison out of reach: the status overcommit test fails.
cat > "$SED_TMP" << 'SED'
s|(( _sum_gb > _vm_gb ))|(( _sum_gb > _vm_gb * 1000 ))|
SED
try "vnext_status_overcommit_line" "flags an overcommitted VM" "$CLI" "$PRUNE_BATS"

# v0.16.4: status's VM size must ROUND like the advisory (a 16 GB slider reads
# ~15.6 GiB), never floor to a misleading 15. Revert the rounded display to a floor:
# the "rounded to the slider, not floored" status test sees "15 GB VM".
cat > "$SED_TMP" << 'SED'
s@_vm_gb="$(_docker_vm_display_gb "$_vm_bytes")"@_vm_gb="$(( _vm_bytes / 1073741824 ))"@
SED
try "vnext_status_vm_size_rounds" "rounded to the slider, not floored" "$CLI" "$PRUNE_BATS"

# vnext: an Exited (255) box is a Docker restart, not a crash; ps must say
# so. Delete the hint: the ps hint test fails.
cat > "$SED_TMP" << 'SED'
/Docker restarted; resume with: cleat resume/d
SED
try "vnext_ps_restart_hint" "box gets the Docker-restarted resume hint" "$CLI" "$DOCKER_COMMANDS_BATS"

# vnext: zero-spelling memory values must be rejected ("00g" → --memory 0 is
# UNLIMITED in docker, a project-clamp bypass). Accept zero: the 00g test fails.
cat > "$SED_TMP" << 'SED'
s@(( 10#\$n > 0 )) || return 1@(( 10#$n >= 0 )) || return 1@
s@  (( _b >= 6291456 ))@  true@
SED
try "vnext_memory_zero_guard" "zero-spellings like 00g are rejected" "$CLI" "$RESOURCES_BATS"

# vnext: the per-suffix digit caps keep the byte conversion inside int64; an
# overflowed product wraps past the 8g clamp. Loosen the g-cap: the
# overflowing-value test fails.
cat > "$SED_TMP" << 'SED'
s|\[\[ \${#n} -le 9 \]\]|[[ \${#n} -le 99 ]]|
SED
try "vnext_memory_overflow_guard" "64-bit-overflowing suffixed value is rejected" "$CLI" "$RESOURCES_BATS"

# vnext: a configured cpus limit must reach docker run. Drop the wiring:
# the cpus docker-run test fails.
cat > "$SED_TMP" << 'SED'
s|cpu_args=(--cpus "\$box_cpus")|cpu_args=()|
SED
try "vnext_cpus_run_wiring" "cpus limit reaches docker run" "$CLI" "$RESOURCES_BATS"

# vnext: a project cpus above the daemon's cores must clamp (dockerd ERRORS
# on --cpus > NCPU, so an untrusted .cleat could abort the start). Echo the
# raw value instead: the clamp test fails.
cat > "$SED_TMP" << 'SED'
s|echo "\$ncpu"|echo "$v"|
SED
try "vnext_cpus_project_clamp" "above the daemon.s cores is clamped" "$CLI" "$RESOURCES_BATS"

# vnext: zero cpus must be rejected (docker reads 0 as no limit). Accept
# zero: the zero-cpus test fails.
cat > "$SED_TMP" << 'SED'
s|(( 10#\$digits > 0 ))|(( 10#$digits >= 0 ))|
SED
try "vnext_cpus_zero_guard" "zero cpus is rejected" "$CLI" "$RESOURCES_BATS"

# vnext: cpus must be part of the config fingerprint (limits are set at
# docker run; drift must surface). Drop it: the cpus fingerprint test fails.
cat > "$SED_TMP" << 'SED'
/resources:cpus=/d
SED
try "vnext_cpus_fingerprint" "cpus changes the fingerprint" "$CLI" "$RESOURCES_BATS"

# vnext: COLORTERM must be forwarded when (and only when) the host sets it.
# Make the condition never true: the COLORTERM subprocess test fails.
cat > "$SED_TMP" << 'SED'
s|-n "\${COLORTERM:-}"|-n ""|
SED
try "vnext_colorterm_forward" "COLORTERM is forwarded only when the host sets it" "$CLI" "$EXEC_CLAUDE_BATS"

# vnext: the TERM fallback value is part of the contract (a box with no
# terminfo match garbles keys). Change it: the fallback test fails.
cat > "$SED_TMP" << 'SED'
s|xterm-256color|dumb|
SED
try "vnext_term_fallback_value" "TERM falls back to xterm-256color" "$CLI" "$EXEC_CLAUDE_BATS"

# vnext: capture ORDER in the session script: moving _CLAUDE_RC=$? after the
# daemon kill re-masks crashes with the kill's rc. Re-capture after the kill:
# the executed-script propagation test fails.
cat > "$SED_TMP" << 'SED'
s|kill "\$_MY_CLIP_DAEMON" 2>/dev/null$|kill "$_MY_CLIP_DAEMON" 2>/dev/null; _CLAUDE_RC=$?|
SED
try "vnext_claude_rc_order" "propagates a crashed claude.s exit code when executed" "$CLI" "$REGRESSIONS"

# vnext: a second spin() must reap the first frame loop (two \r loops
# interleave into garbage). Drop the nested guard: the double-spin test fails.
cat > "$SED_TMP" << 'SED'
/\[\[ -n "\${_SPIN_PID:-}" \]\] && _cleanup_spin/d
SED
try "vnext_spin_nested_guard" "second spin stops the first frame loop" "$CLI" "$TERMINAL_UX_BATS"

# vnext: the frame loop must exit on its own when its parent dies without
# spin_stop. Make it loop forever: the orphan-spinner test fails.
cat > "$SED_TMP" << 'SED'
s|while kill -0 "\$_spin_parent" 2>/dev/null; do|while true; do|
SED
try "vnext_spin_parent_liveness" "frame loop exits on its own" "$CLI" "$TERMINAL_UX_BATS"

# vnext: cmd_shell and cmd_login run their own interactive exec and must
# restore the terminal independently. Delete both call sites: the shell and
# login restore tests fail.
cat > "$SED_TMP" << 'SED'
/^cmd_shell() {$/,/^}$/{
  /_restore_terminal/d
}
/^cmd_login() {$/,/^}$/{
  /_restore_terminal/d
}
SED
try "vnext_shell_login_restore" "restores the terminal after the interactive exec" "$CLI" "$TERMINAL_UX_BATS"

# vnext: the same-URL debounce window is what folds a TUI click's double
# open-shim fire into one tab. Disable the window: the dedup test fails.
cat > "$SED_TMP" << 'SED'
s|_BROWSER_DEBOUNCE_SECS=2|_BROWSER_DEBOUNCE_SECS=-1|
SED
try "vnext_browser_debounce_window" "repeat of the same URL inside the window is deduped" "$CLI" "$BROWSER_BRIDGE_BATS"

# vnext: the watcher must actually consult the debounce before opening.
# Bypass the consult: the watcher-consults test fails.
cat > "$SED_TMP" << 'SED'
s|if _browser_recently_opened "\$clip_dir" "\$url"; then|if false; then|
SED
try "vnext_browser_debounce_callsite" "watcher consults the debounce before opening" "$CLI" "$BROWSER_BRIDGE_BATS"

# vnext: the debounce claim must be ATOMIC. mkdir fails (EEXIST) for all but one
# racer; mkdir -p succeeds for every racer, so concurrent watchers would each
# "win" and open the same URL N times (the one-click-two-tabs bug). Swap in -p:
# the concurrent-open test fails.
cat > "$SED_TMP" << 'SED'
s|mkdir "\$lock" 2>/dev/null|mkdir -p "\$lock" 2>/dev/null|
SED
try "vnext_browser_debounce_atomic" "open one URL exactly once" "$CLI" "$BROWSER_BRIDGE_BATS"

# vnext: a watcher whose cleat process died without the cleanup trap must
# stop polling (leaked watchers are one tab PER crashed session). Drop the
# liveness check: the orphan-watcher test fails.
cat > "$SED_TMP" << 'SED'
s|kill -0 "\$_bw_parent" 2>/dev/null \|\| { _bw_cleanup; exit 0; }|true|
SED
try "vnext_browser_watcher_liveness" "watcher self-exits when its spawning cleat process dies" "$CLI" "$BROWSER_BRIDGE_BATS"

# vnext: an orphaned clipboard watcher must never write a dead session's box
# clipboard over the host clipboard. Drop the choke-point check: the
# orphan-copy test fails.
cat > "$SED_TMP" << 'SED'
s|kill -0 "\$_cw_parent" 2>/dev/null \|\| exit 0|true|
SED
try "vnext_clipboard_watcher_liveness" "never copies" "$CLI" "$CLIPBOARD_BRIDGE_BATS"

# v1.2.5: the clipboard watcher's startup sweep must only remove a STALE
# leftover payload (age-gated, like the browser bridge's sweep). The age
# gate was later restructured onto a $leftover_age variable (to also cover
# the negative-age case below), so the old sed matching the inline
# "_path_mtime ... -gt 5" expression no longer lands. Push the threshold out
# to effectively never (a file would need to sit for ~317 years before the
# gate fires), which restores the pre-fix bug: the fresh watcher's poll loop
# sees the leftover payload as new and redelivers a previous session's
# clipboard to the host.
cat > "$SED_TMP" << 'SED'
s|"\$leftover_age" -gt 5|"\$leftover_age" -gt 9999999999|
SED
try "v1.2.5_clipboard_startup_sweep" "never redelivers a previous session" "$CLI" "$REGRESSIONS"

# v1.2.5 (hardening): a backward host clock step makes a leftover's mtime
# sit ahead of now, so age is negative and "-gt 5" alone never fires. Drop
# the "|| [ ... -lt 0 ]" branch: the sweep only catches a positive age
# again, so a future-dated leftover is redelivered.
cat > "$SED_TMP" << 'SED'
s|\[ "\$leftover_age" -gt 5 \] \|\| \[ "\$leftover_age" -lt 0 \]|\[ "\$leftover_age" -gt 5 \]|
SED
try "v1.2.5_clipboard_negative_age_sweep" "future-dated leftover" "$CLI" "$REGRESSIONS"

# v1.2.5 (hardening): a claim stranded by a watcher killed between rename
# and delivery must be swept at startup, same as the leftover payload.
# Short-circuit the loop body to an unconditional `continue`, making the
# stranded-claim sweep a no-op.
cat > "$SED_TMP" << 'SED'
s|\[ -f "\$stale_claim" \] \|\| continue|continue|
SED
try "v1.2.5_clipboard_stranded_claim_sweep" "never redelivers a previous session" "$CLI" "$REGRESSIONS"

# v1.2.5 (hardening): the claim file must live OUTSIDE the .clipboard.*
# namespace, since every session's exit sweep clears that namespace
# unconditionally and would delete a sibling's in-flight claim. Regress the
# claim name back into that namespace.
cat > "$SED_TMP" << 'SED'
s|\.claim\.\$\$\.\${RANDOM}|.clipboard.claim.\$\$.\${RANDOM}|
SED
try "v1.2.5_clipboard_claim_namespace" "cleanup namespace" "$CLI" "$CLIPBOARD_BRIDGE_BATS"

# v1.2.5: _do_copy must CONSUME the payload (atomic rename), so a delivered
# copy no longer exists on disk for a later session's watcher to replay.
# Swap the consuming `mv` for a non-consuming `cat > claim`: delivery still
# works (the clip command still gets the bytes), but the source file
# survives, so the "consumes the payload" assertion fails.
cat > "$SED_TMP" << 'SED'
s|mv "\$clip_dir/clipboard" "\$claim" 2>/dev/null \|\| return 0|cat "\$clip_dir/clipboard" > "\$claim" 2>/dev/null \|\| return 0|
SED
try "v1.2.5_clipboard_consume_on_read" "consumes the payload" "$CLI" "$CLIPBOARD_BRIDGE_BATS"

# v1.2.5: on hosts with inotify-tools/fswatch, _cleanup_session's plain kill
# never reaches the watcher's blocking child, so it (and inotifywait under
# it) survive as an orphan. Drop the pkill -P step that kills it directly.
# Registered only where inotifywait exists: without it (stock macOS, the
# macOS CI leg) the polling fallback has no blocking child and no observable
# defect, so the paired regression test skips, and a skipped test reads as a
# missed mutation (seen live on the v1.2.5 macOS CI run).
if command -v inotifywait >/dev/null 2>&1; then
cat > "$SED_TMP" << 'SED'
s|pkill -P "\$_CLIP_WATCHER_PID" 2>/dev/null \|\| true|true|
SED
try "v1.2.5_cleanup_watcher_child_kill" "reaps a watcher" "$CLI" "$REGRESSIONS"
fi

# vnext: an orphaned hook bridge must exit BEFORE processing late events
# (host hooks for a dead session). Drop the loop-top check: the orphan-bridge
# test fails.
cat > "$SED_TMP" << 'SED'
s|kill -0 "\$_hb_parent" 2>/dev/null \|\| { _hook_bridge_cleanup; exit 0; }|true|
SED
try "vnext_hook_bridge_liveness" "orphaned bridge exits without executing late events" "$CLI" "$HOOKS_BATS"

# ── 2026-06 bugfix round (s1/s2 screenshots) ─────────────────────────────────

# The container is always a native install, so the per-project .claude.json must
# force installMethod=native (the host value/absence would otherwise leak in and
# `claude doctor` warns "install method is unknown"). Flip it to "unknown": the
# claude_json test sees the wrong value and fails.
cat > "$SED_TMP" << 'SED'
s|installMethod: "native"|installMethod: "unknown"|
SED
try "bugfix_installmethod_native" "forces installMethod=native even when" "$CLI" "$CLAUDE_JSON_BATS"

# macOS keychain → box credential seed must actually write the file. Neuter the
# move: the "writes the keychain blob" test sees no creds file and fails.
cat > "$SED_TMP" << 'SED'
s|mv -f "\$tmp" "\$cred" 2>/dev/null|false|
SED
try "bugfix_keychain_seed_write" "writes the keychain blob" "$CLI" "$CREDENTIALS_BATS"

# Seeding must NEVER clobber a still-valid in-box token (the box refreshes its
# own; concept/23). Drop the file-valid early return: the "never clobbers" test
# sees its valid token overwritten by the fresher Keychain blob.
cat > "$SED_TMP" << 'SED'
/(( file_exp > now_ms )) && return 0/d
SED
try "bugfix_keychain_no_clobber" "never clobbers an existing" "$CLI" "$CREDENTIALS_BATS"

# Seeding must validate the blob is a JSON object (never write an error string
# into the creds file). Force the validation true: the "refuses a non-JSON"
# test sees a poisoned creds file written and fails.
cat > "$SED_TMP" << 'SED'
s|if \$ok; then|if true; then|
SED
try "bugfix_keychain_validate_json" "refuses to write a non-JSON-object blob" "$CLI" "$CREDENTIALS_BATS"

# Seeding is macOS-only (Linux already has the file via the dir mount). Make the
# call site ignore the OS gate: the "no-op off macOS" test sees a file written.
cat > "$SED_TMP" << 'SED'
s#_is_macos || return 0#true || return 0#
SED
try "bugfix_keychain_macos_guard" "no-op off macOS" "$CLI" "$CREDENTIALS_BATS"

# _is_macos's OSTYPE signal must actually match darwin. Break the glob: with the
# uname fallback forced to Linux in the test, the OSTYPE-only detection fails.
cat > "$SED_TMP" << 'SED'
s|darwin\*|nope*|
SED
try "bugfix_is_macos_ostype" "true under a darwin OSTYPE" "$CLI" "$CREDENTIALS_BATS"

# An outdated image is refreshed by PULLING the released image for this version
# (download), not the old unconditional local rebuild. Revert to cmd_rebuild:
# the accept-path test sees no PULL_CALLED and fails.
cat > "$SED_TMP" << 'SED'
s#_do_pull "\$VERSION" || _do_build#cmd_rebuild#
SED
try "bugfix_image_outdated_pulls" "PULLS this version on accept" "$CLI" "$IMAGE_REBUILD_BATS"

# The refresh prompt is keyed to IMAGE CONTENT: it fires only when the local
# image's spec is STRICTLY OLDER than the CLI's _IMAGE_SPEC_VERSION. Flip the
# comparison direction: an older-content image no longer prompts, so the
# older-spec test sees no notice and fails.
cat > "$SED_TMP" << 'SED'
s|10#$stored_spec < 10#$_IMAGE_SPEC_VERSION|10#$stored_spec > 10#$_IMAGE_SPEC_VERSION|
SED
try "vnext_image_spec_older_prompts" "PROMPTS when the image spec is older than the CLI" "$CLI" "$IMAGE_REBUILD_BATS"

# A pre-stamping image at/after the content intro version carries today's
# content (spec 1) and must stay silent at cutover. Mutate the inferred spec to
# 0 so such an image looks older than the CLI: the recreate-free-cutover test
# sees a spurious notice and fails.
cat > "$SED_TMP" << 'SED'
s|      stored_spec=1|      stored_spec=0|
SED
try "vnext_image_spec_legacy_intro" "a pre-stamping image at the intro version stays silent" "$CLI" "$IMAGE_REBUILD_BATS"

# The spec comparison forces base 10 so a leading-zero label (08/09) can't leak
# an invalid-octal arithmetic error to stderr. Revert to a bare integer test:
# the leading-zero test sees the "value too great for base" stderr and fails.
cat > "$SED_TMP" << 'SED'
s|(( 10#$stored_spec < 10#$_IMAGE_SPEC_VERSION ))|[[ "$stored_spec" -lt "$_IMAGE_SPEC_VERSION" ]]|
SED
try "vnext_image_spec_base10" "an older leading-zero spec label prompts with no octal stderr leak" "$CLI" "$IMAGE_REBUILD_BATS"

# The caps reader must keep a final line with no trailing newline (else a
# hand-edited .cleat ending in a cap silently drops it: no trust prompt, cap
# never applied). Revert the `|| [[ -n "$line" ]]` fallback INSIDE
# _read_caps_from_file only (range-scoped so _parse_env_file is untouched): the
# no-trailing-newline regression test then sees an empty read and fails.
cat > "$SED_TMP" << 'SED'
/^_read_caps_from_file()/,/^}/ s#while IFS= read -r line || \[\[ -n "\$line" \]\]; do#while IFS= read -r line; do#
SED
try "vnext_caps_reader_no_trailing_newline" "caps reader keeps a final line" "$CLI" "$REGRESSIONS"

# Same class for the section reader (serves [resources] and [kits]; the
# _read_resource_from_file wrapper delegates here): a hand-edited .cleat
# ending in `memory = 8g` with no trailing newline must still apply the
# ceiling. Revert the `|| [[ -n "$line" ]]` fallback INSIDE
# _read_section_from_file only (range-scoped so the caps/env readers are
# untouched): the [resources] no-trailing-newline regression test then sees
# an empty read and fails.
cat > "$SED_TMP" << 'SED'
/^_read_section_from_file()/,/^}/ s#while IFS= read -r line || \[\[ -n "\$line" \]\]; do#while IFS= read -r line; do#
SED
try "vnext_resources_reader_no_trailing_newline" "resources. reader keeps a final line" "$CLI" "$REGRESSIONS"

# The workspace-trust prompt MUST default-deny: only an explicit yes grants an
# untrusted project's caps. Flip the catch-all branch to return 0 (approve) so
# empty/EOF input would auto-trust: the "empty answer defaults to DENY" test then
# sees success instead of failure and fails. Scoped to _trust_prompt only.
cat > "$SED_TMP" << 'SED'
/^_trust_prompt()/,/^}/ s#\*) return 1 ;;#*) return 0 ;;#
SED
try "vnext_trust_prompt_default_deny" "empty answer defaults to DENY" "$CLI" "$TRUST_BATS"

# OOM guidance fires on exit 137 (SIGKILL, the kernel OOM-killer's signature).
# Break the 137 arm: the "infers OOM from exit 137" test sees no guidance.
cat > "$SED_TMP" << 'SED'
s|"\$rc" == "137"|"\$rc" == "138"|
SED
try "bugfix_oom_exit137_signal" "infers OOM from exit 137" "$CLI" "$EXEC_CLAUDE_BATS"

# OOM guidance also fires on the cgroup OOM flag (State.OOMKilled). Break that
# arm: the "explains an OOM flagged by the container" test sees no guidance.
cat > "$SED_TMP" << 'SED'
s|"\$oomkilled" == "true"|"\$oomkilled" == "nope"|
SED
try "bugfix_oom_oomkilled_signal" "explains an OOM flagged by the container" "$CLI" "$EXEC_CLAUDE_BATS"

# The advisory sizes the VM to a comfortable 16 GiB default target. Shrink the
# target so a too-small VM looks fine: the "advises a concrete VM size" test sees
# no advisory and fails.
cat > "$SED_TMP" << 'SED'
s|_PRESSURE_TARGET_VM_GB=16|_PRESSURE_TARGET_VM_GB=2|
SED
try "bugfix_advisory_target_sessions" "advises a concrete VM size" "$CLI" "$PRUNE_BATS"

# The recommendation is capped at HALF the host's RAM (don't recommend a VM the
# machine can't back). Drop the cap so it ignores the host: the "capped at half
# the host RAM" test sees the 16g target instead of the 8g half and fails.
cat > "$SED_TMP" << 'SED'
/(( half < rec )) && rec=\$half/d
SED
try "bugfix_advisory_half_host_cap" "capped at half the host RAM" "$CLI" "$PRUNE_BATS"

# When host RAM is unknown, the advisory falls back to an absolute 8 GiB floor
# (compared in whole rounded GB since v0.16.4). Force that floor to 0: the
# host-unknown fallback test sees no advisory.
cat > "$SED_TMP" << 'SED'
s|vm_gb < _PRESSURE_VM_ADVISORY_BYTES / 1073741824|vm_gb < 0|
SED
try "bugfix_advisory_fallback_floor" "falls back to an 8 GiB floor" "$CLI" "$PRUNE_BATS"

# The undersized-VM advisory is Docker-Desktop-only (a native engine has no
# resizable VM). Neuter the `elif $is_dd` gate: the "off Docker Desktop" test
# sees the advisory fire.
cat > "$SED_TMP" << 'SED'
s|elif \$is_dd; then|elif true; then|
SED
try "bugfix_advisory_desktop_gate" "no advisory off Docker Desktop" "$CLI" "$PRUNE_BATS"

# The overload notice must ALSO print the concrete grow-the-VM fix, not just the
# terse warning. Delete the fix call: the overload test loses the click-path.
cat > "$SED_TMP" << 'SED'
/_print_docker_vm_fix "\$host_bytes" "\$rec_gb"/d
SED
try "bugfix_advisory_overload_howto" "STILL prints the grow-the-VM fix" "$CLI" "$PRUNE_BATS"

# The fix names the machine's safe max (~3/4 of host RAM). Zero it out: the
# "concrete VM size + safe max" test no longer sees the 24 GB max and fails.
cat > "$SED_TMP" << 'SED'
s|host_bytes \* 3 / 4|host_bytes * 0|
SED
try "bugfix_advisory_safe_max" "advises a concrete VM size" "$CLI" "$PRUNE_BATS"

# The VM advisory must be an amber WARNING (crucial), not a neutral blue info
# note. Revert it to info: the amber-marker test loses the amber `!` and fails.
cat > "$SED_TMP" << 'SED'
s|warn "Docker VM memory is|info "Docker VM memory is|
SED
try "bugfix_advisory_amber" "amber warning" "$CLI" "$PRUNE_BATS"

# The pressure block owns ONE trailing blank (when it printed any notice) so it
# doesn't abut the news / bring-up. Neuter the `echo ""` in the `if $printed`
# block: the "blank line follows" test sees the content abut the sentinel.
cat > "$SED_TMP" << 'SED'
/if \$printed; then/{
n
s/echo ""/:/
}
SED
try "bugfix_advisory_trailing_blank" "blank line follows the VM advisory" "$CLI" "$PRUNE_BATS"

# The release highlight's changelog link is on its own labelled line. Delete it:
# the "version-anchored changelog link" test loses the link entirely.
cat > "$SED_TMP" << 'SED'
/Changelog:/d
SED
try "bugfix_highlight_changelog_line" "version-anchored changelog link" "$CLI" "$WHATS_NEW_BATS"

# That changelog link must deep-link to this release's section (#v1.2.0),
# not the bare page. Strip the anchor: the "version-anchored" test fails.
cat > "$SED_TMP" << 'SED'
s|cleat.sh/changelog#v1.4.0|cleat.sh/changelog|
SED
try "bugfix_highlight_changelog_anchor" "version-anchored changelog link" "$CLI" "$WHATS_NEW_BATS"

# _hyperlink must emit a real OSC 8 sequence in supporting terminals. Force the
# fallback branch: the "wraps text in an OSC 8 sequence" test loses the escapes.
cat > "$SED_TMP" << 'SED'
s|if _supports_osc8; then|if false; then|
SED
try "bugfix_hyperlink_osc8" "wraps text in an OSC 8 sequence" "$CLI" "$TERMINAL_UX_BATS"

# The fallback must print the full URL (autodetect-clickable), not the short
# label. Swap it to the label: the "falls back to the bare URL" test fails.
cat > "$SED_TMP" << 'SED'
s|printf '%s' "$url"|printf '%s' "$text"|
SED
try "bugfix_hyperlink_fallback" "falls back to the bare URL" "$CLI" "$TERMINAL_UX_BATS"

# OSC 8 must never be emitted to a non-TTY (no escapes into pipes). Drop the TTY
# guard in _supports_osc8: the "never emitted to a non-TTY" test then succeeds.
cat > "$SED_TMP" << 'SED'
s#_is_tty || return 1#true#
SED
try "bugfix_osc8_tty_guard" "never emitted to a non-TTY" "$CLI" "$TERMINAL_UX_BATS"

# The OSC 8 capability allow-list must actually match known terminals. Break the
# iTerm.app entry: the "detected for known terminals" test fails.
cat > "$SED_TMP" << 'SED'
s#iTerm.app#nope.app#
SED
try "bugfix_osc8_allowlist" "detected for known terminals" "$CLI" "$TERMINAL_UX_BATS"

# _host_total_memory must scale kB in bash, not `awk '{print $2 * 1024}'` (which
# emits scientific notation for real RAM sizes → fails ^[0-9]+$ → host treated as
# unknown). Revert to the awk multiply: the plain-integer test fails.
cat > "$SED_TMP" << 'SED'
s|print $2; exit|print $2 * 1024; exit|
SED
try "bugfix_host_mem_awk_integer" "reads /proc/meminfo as a plain integer" "$CLI" "$RESOURCES_BATS"

# A non-numeric running-limits sum must NOT abort the pressure check before the
# undersized-VM advisory (v0.16.1 folded the old standalone guard into the
# overload if). Re-add a hard `|| return 0` after the sum read: the advisory is
# skipped on a non-numeric sum and the regression test fails.
cat > "$SED_TMP" << 'SED'
s#sum="$(_running_memory_limits_sum)"#&; [[ "$sum" =~ ^[0-9]+$ ]] || return 0#
SED
try "bugfix_pressure_sum_guard_folded" "non-numeric running-limits sum" "$CLI" "$PRUNE_BATS"

# v0.16.2: _is_docker_desktop must read the OperatingSystem field via --format,
# NOT `docker info | grep -q`. The piped form is SIGPIPE-fragile under pipefail
# (grep -q closes the pipe, docker info dies 141, pipefail surfaces the 141 even
# on a match), which silently killed the Docker-Desktop-only VM advisory under
# load. Revert it to the grep pipeline: the pipefail regression test returns 141.
cat > "$SED_TMP" << 'SED'
/^_is_docker_desktop()/,/^}$/{
  s#os="\$(docker info --format.*#docker info 2>/dev/null | grep -q "Operating System:.*Docker Desktop"#
  /== \*"Docker Desktop"\*/d
  /local os$/d
}
SED
try "bugfix_is_docker_desktop_pipefail" "pipefail" "$CLI" "$HOOKS_BATS"

# v0.16.2: on a host that can't grow the VM (recommended ≤ current, e.g. a 7 GB
# VM on an 8 GB Mac), the overload notice must steer to fewer sessions, NOT print
# a Docker Desktop target smaller than the current VM. Force the grow branch
# always: the starved-host test then sees the (wrong) Settings click-path.
cat > "$SED_TMP" << 'SED'
s|if \$is_dd && (( rec_gb > vm_gb )); then|if true; then|
SED
try "bugfix_overload_starved_steer" "steers to fewer sessions" "$CLI" "$PRUNE_BATS"

# v0.16.2: the release highlight must guarantee one blank line above the news
# even when no on-start notice preceded it. Drop the leading-blank: the "opens
# its own blank line" test sees the news sit flush against what's above it.
cat > "$SED_TMP" << 'SED'
s#\[\[ "\${_ONSTART_GAP_OPEN:-0}" == "1" \]\] || echo ""#true#
SED
try "bugfix_highlight_leading_blank" "opens its own blank line above" "$CLI" "$WHATS_NEW_BATS"

# v0.16.2: but it must NOT double the blank when a notice already opened the gap.
# Make the leading blank unconditional: the "does NOT add a second blank" test
# sees two blanks above the news.
cat > "$SED_TMP" << 'SED'
s#\[\[ "\${_ONSTART_GAP_OPEN:-0}" == "1" \]\] || echo ""#echo ""#
SED
try "bugfix_highlight_no_double_blank" "does NOT add a second blank" "$CLI" "$WHATS_NEW_BATS"

# v0.16.2: the pressure block must flag _ONSTART_GAP_OPEN after printing its
# trailing blank, so the highlight knows the gap is open. Drop the flag: the
# highlight adds its own blank and the end-to-end test sees a double gap.
cat > "$SED_TMP" << 'SED'
s#_ONSTART_GAP_OPEN=1#:#
SED
try "bugfix_pressure_gap_flag" "exactly one blank separates a real preceding" "$CLI" "$WHATS_NEW_BATS"

# v0.16.x: the pressure section must open with its own LEADING blank (before the
# first notice) so the advisory lands in its own block, not flush against the
# auto-update "Restarting..." line above it (image.png). Since v0.16.4 the
# advisory owns that blank unconditionally (a bare `echo ""` above the undersized
# warn), so neuter THAT: the "blank line PRECEDES" test (VM-only, no prune) sees
# the warn on line 1.
cat > "$SED_TMP" << 'SED'
/if $bad; then/{
n
s@echo ""@:@
}
SED
try "bugfix_pressure_leading_blank" "blank line PRECEDES the advisory section" "$CLI" "$PRUNE_BATS"

# v0.16.x: the VM fix must name the REAL Docker Desktop panels. Memory + Swap are
# under Resources → Advanced (docker-2.png). Revert to the old bare "Resources →
# Memory": the "REAL Docker Desktop panels" test loses the "Resources → Advanced"
# path.
cat > "$SED_TMP" << 'SED'
s|Resources → Advanced|Resources → Memory|
SED
try "bugfix_vm_fix_memory_panel" "REAL Docker Desktop panels" "$CLI" "$PRUNE_BATS"

# v0.16.x: VirtioFS file sharing is a SEPARATE panel under General → Virtual
# Machine Options (docker-1.png), not Resources. Strip that path: the same test
# loses the "Virtual Machine Options" assertion.
cat > "$SED_TMP" << 'SED'
s|General → Virtual Machine Options|Resources|
SED
try "bugfix_vm_fix_sharing_panel" "REAL Docker Desktop panels" "$CLI" "$PRUNE_BATS"

# vnext: the undersized-VM advisory must show on EVERY start (an invalid config
# surfaces until fixed), NOT once a day. Re-gate the 2b branch on the daily stamp:
# with a fresh stamp the "shows on EVERY start" test sees no advisory and fails.
cat > "$SED_TMP" << 'SED'
s|elif \$is_dd; then|elif \$is_dd \&\& \$bloat_due; then|
SED
try "vnext_undersized_every_start" "shows on EVERY start" "$CLI" "$PRUNE_BATS"

# vnext: the "Docker tuned" line must defer to a warning the pressure check already
# showed this run (no warning+confirmation contradiction). Drop the guard: the
# defers-to-a-warning test sees the confirmation leak through.
cat > "$SED_TMP" << 'SED'
/\[\[ "\${_VM_ADVISORY_SHOWN:-0}" == "1" \]\] && return 0/d
SED
try "vnext_ready_defers_to_warning" "defers to a warning" "$CLI" "$PRUNE_BATS"

# vnext: the positive "Docker tuned" confirmation must fire ONLY when the VM is
# adequately sized (the exact inverse of the 2b undersized test), never for an
# undersized VM. Neuter the host-known adequacy gate so an undersized VM would
# also print: the "silent when the VM is undersized" test sees the confirmation.
cat > "$SED_TMP" << 'SED'
s@(( vm_gb < rec_gb )) && return 0@:@
SED
try "vnext_ready_adequacy_gate" "silent when the VM is undersized" "$CLI" "$PRUNE_BATS"

# vnext: main()'s session-launching verbs must reach the readiness confirmation.
# Delete the call: the announce-on-start test fails.
cat > "$SED_TMP" << 'SED'
/^    _maybe_announce_docker_ready$/d
SED
try "vnext_ready_main_callsite" "session-launching commands announce docker readiness" "$CLI" "$PRUNE_BATS"

# v0.16.x: the clean-session-end reclaim sequence must clear the line success()
# writes on (a trailing \033[2K), so stale bytes a heavily-used terminal left on
# that row can't survive past "cleat resume". Drop the trailing clear: the
# "clears the success line" regression test loses the second \033[2K.
cat > "$SED_TMP" << 'SED'
s|\\r\\n\\033\[2K'|\\r\\n'|
SED
try "bugfix_session_end_line_clear" "clears the success line so stale terminal bytes" "$CLI" "$REGRESSIONS"

# v0.16.4: the config fingerprint must read CONFIGURED memory, never the
# VM-derived default. Revert to resolve_box_memory: the unconfigured box's hash
# moves with the (mocked) VM size again and the "resizing the VM does not trigger
# config drift" regression fails.
cat > "$SED_TMP" << 'SED'
s|resources:memory=$(_configured_box_memory|resources:memory=$(resolve_box_memory|
SED
try "vnext_fingerprint_configured_memory" "resizing the Docker VM does not trigger" "$CLI" "$REGRESSIONS"

# v0.16.4: the fingerprint must read CONFIGURED cpus, never the daemon-clamped
# value. Revert to resolve_box_cpus: a configured cpus above the core count gets
# clamped to the (mocked) NCPU, so changing the core count drifts the hash and the
# "configured cpus above the cores does NOT drift" test fails.
cat > "$SED_TMP" << 'SED'
s|resources:cpus=$(_configured_box_cpus|resources:cpus=$(resolve_box_cpus|
SED
try "vnext_fingerprint_configured_cpus" "above the cores does NOT drift the fingerprint" "$CLI" "$RESOURCES_BATS"

# v0.16.4: the stored config-hash must carry the storage-format prefix (v2:) so a
# formula change is detectable. Drop the prefix at stamping: the "stores
# config-hash label" test (which pins sh.cleat.config-hash=v2:) fails.
cat > "$SED_TMP" << 'SED'
s|config_hash="v${_CONFIG_FP_VERSION}:|config_hash="|
SED
try "vnext_config_hash_v2_prefix" "stores config-hash label on container" "$CLI" "$CAPABILITIES_BATS"

# v0.16.4: a legacy (pre-v2) or unprefixed hash can't be reconstructed, so it must
# NOT be treated as drift (the false-recreate-on-upgrade bug). Delete the
# format-version gate: a legacy hash now mismatches the current and prompts, so the
# "legacy (pre-v2) config-hash is never nagged" regression fails.
cat > "$SED_TMP" << 'SED'
/\[\[ "\$stored_hash" == "v\${_CONFIG_FP_VERSION}:"\* \]\] || return 0/d
SED
try "vnext_drift_legacy_grandfather" "legacy" "$CLI" "$REGRESSIONS"

# v0.16.4: the drift message must name resources too (configured [resources] can
# drift), not just "caps or env keys". Revert to the old wording: the "message
# names caps/env/resources" test loses "resource limits" and fails.
cat > "$SED_TMP" << 'SED'
s|its capabilities, environment, or resource limits differ from your current setup|caps or env keys differ from the running setup|
SED
try "vnext_drift_message_resources" "message names caps" "$CLI" "$CAPABILITIES_BATS"

# v0.16.4: the swap advisory must fire when configured swap is below the target.
# Defeat the threshold (compare against 0, never true): the "low swap shows the
# swap advisory" test sees the all-clear instead and fails.
cat > "$SED_TMP" << 'SED'
s|swap_bytes < _SWAP_ADVISORY_BYTES|swap_bytes < 0|
SED
try "vnext_swap_advisory_branch" "low swap shows the swap advisory" "$CLI" "$PRUNE_BATS"

# v0.16.4: _docker_vm_swap_bytes must convert the settings file's MiB value to
# bytes. Break the conversion (× 1): the "reads SwapMiB from settings-store" test
# expects 1073741824 but sees 1024 and fails.
cat > "$SED_TMP" << 'SED'
s|mib \* 1048576|mib \* 1|
SED
try "vnext_swap_detect_mib" "reads SwapMiB from settings-store" "$CLI" "$PRUNE_BATS"

# v0.16.4: the Claude-update prompt block must close with a trailing blank so the
# bring-up doesn't sit flush against "Claude Code upgraded". Delete the blank that
# follows the "# neither blank." anchor: the "fired Claude-update prompt closes
# with a trailing blank" regression fails.
cat > "$SED_TMP" << 'SED'
/# neither blank\./{
n
d
}
SED
try "vnext_blank_after_claude_upgrade" "Claude-update prompt closes with a trailing blank" "$CLI" "$REGRESSIONS"

# v0.16.4 hardening: swap MiB→bytes must force base-10 (10#). A leading-zero value
# (08/09) is invalid octal and aborts the arithmetic under set -e. Revert 10#$mib
# to $mib: the "leading-zero value is read as base-10" test loses 8388608 (empty).
cat > "$SED_TMP" << 'SED'
s|10#$mib|$mib|
SED
try "vnext_swap_base10" "leading-zero value is read as base-10" "$CLI" "$PRUNE_BATS"

# v0.16.4 hardening: the swap shortfall is reported in floored GB, never _human_bytes
# (which rounds 1.5 GB up to "2 GB" and contradicts the "set Swap ≥ 2 GB" step).
# Make the GB display round UP: the "sub-2GB swap is not rounded UP" test sees "2 GB".
cat > "$SED_TMP" << 'SED'
s|swap_bytes / 1073741824 )) GB|(swap_bytes + 1073741823) / 1073741824 )) GB|
SED
try "vnext_swap_floor_display" "sub-2GB swap is not rounded UP" "$CLI" "$PRUNE_BATS"

# v0.16.4 hardening: the release highlight owns a trailing blank, so it must flag
# _ONSTART_GAP_OPEN (else the next on-start line doubles the blank). Delete the flag
# set after the highlight's trailing blank: the "firing the highlight opens the gap"
# test sees the flag stay 0.
cat > "$SED_TMP" << 'SED'
/# pressure block follows\./{
n
n
d
}
SED
try "vnext_highlight_opens_gap" "firing the highlight opens the gap" "$CLI" "$WHATS_NEW_BATS"

# v0.16.4 hardening: the fingerprint's configured-memory resolver must read the
# GLOBAL config when the project declares nothing. Neuter the global read (point it
# at /dev/null): the "configured memory: falls back to the global config" test
# loses its 12g result. (Also touches resolve_box_memory, but the harness runs only
# the filtered test.)
cat > "$SED_TMP" << 'SED'
s|_read_resource_from_file "$CLEAT_GLOBAL_CONFIG" memory|_read_resource_from_file /dev/null memory|
SED
try "vnext_configured_global_memory" "configured memory: falls back to the global" "$CLI" "$RESOURCES_BATS"

# v0.16.4: the Docker VM size must ROUND to the nearest GB, not floor. `docker info`
# reports the kernel's MemTotal (~15.6 GiB for a 16 GB slider), which flooring turned
# into a misleading "15 GB" and a false undersized warning. Revert the +0.5 GiB
# round-up to +0: _vm_gb_rounded floors again and the "rounds to the slider" regression
# reads 15 for a 16 GB slider and fails.
cat > "$SED_TMP" << 'SED'
s|b + 536870912|b + 0|
SED
try "vnext_vm_gb_rounds_slider" "rounds to the slider" "$CLI" "$REGRESSIONS"

# v0.16.4 hardening: _vm_gb_rounded must force base-10 (10#$b) so a digit-only value
# with a leading zero is not aborted as invalid octal under set -e. Revert 10#$b to
# $b: the zero-padded assertion in the "rounds to the slider" regression reads empty.
cat > "$SED_TMP" << 'SED'
s|10#$b|$b|
SED
try "vnext_vm_gb_base10" "rounds to the slider" "$CLI" "$REGRESSIONS"

# v0.16.4: the undersized test must compare WHOLE rounded GB, never raw bytes, else
# a 16 GB slider's ~15.6 GiB trips the exact-16-GiB byte threshold even though its
# rounded display reads 16 (the self-contradiction). Revert the GB compare to bytes:
# the "not flagged undersized" test sees the warning fire and fails.
cat > "$SED_TMP" << 'SED'
s|vm_gb < rec_gb|vm_bytes < rec_gb * 1073741824|
SED
try "vnext_pressure_compares_gb" "not flagged undersized" "$CLI" "$PRUNE_BATS"

# v0.16.4: the VM advisory must own a blank line above it even when the prune notice
# already printed (each on-start notice is separated). Revert the unconditional
# separator before the undersized warn to `$printed || echo ""`: with prune fired,
# printed=true suppresses it and the "separated by a blank line" regression sees the
# advisory flush under PRUNE_DONE.
cat > "$SED_TMP" << 'SED'
/if $bad; then/{
n
s@echo ""@$printed || echo ""@
}
SED
try "vnext_prune_advisory_blank" "separated by a blank line" "$CLI" "$REGRESSIONS"

# v0.16.5: the displayed VM size must PREFER the configured Docker Desktop slider
# (MemoryMiB) over the kernel's MemTotal, which a 24 GB slider under-reports to
# ~23.4 GiB and rounds to 23. Disable the prefer-configured branch (never taken)
# so it always falls back to rounding MemTotal: the 24 GB slider reads 23 and the
# "displays as 24 GB, not 23" regression fails.
cat > "$SED_TMP" << 'SED'
s|cfg > 0|cfg > 999999|
SED
try "vnext_vm_display_prefers_slider" "24 GB Docker Desktop slider" "$CLI" "$REGRESSIONS"

# v0.16.5: _docker_vm_configured_gb must read the MEMORY slider (memoryMiB), not
# some other key. Point the grep anchor at swapmib instead: the settings-store
# read returns the swap value, so "reads MemoryMiB from settings-store" reads 2
# (the 2048 MiB swap) instead of 24 and fails.
cat > "$SED_TMP" << 'SED'
s|"memorymib"|"swapmib"|
SED
try "vnext_vm_configured_reads_memorymib" "reads MemoryMiB from settings-store" "$CLI" "$PRUNE_BATS"

# v0.16.5: the link double-open fix. On an interactive terminal the bridge must
# DEFER a plain link (the terminal opens the click itself). Flip the defer to an
# open: the plain link opens a second tab and the "does not re-open a plain link"
# regression fails.
cat > "$SED_TMP" << 'SED'
s|return 1  # plain link, terminal owns it|return 0  # plain link, terminal owns it|
SED
try "vnext_bridge_defers_plain_link" "does not re-open a plain link" "$CLI" "$REGRESSIONS"

# v0.16.5: CLEAT_BROWSER_BRIDGE must default to the safe "auto" policy. Change the
# fallback to "always": an unset var no longer reads "auto" and the "defaults to
# auto when unset" test fails.
cat > "$SED_TMP" << 'SED'
s|printf 'auto' ;;|printf 'always' ;;|
SED
try "vnext_bridge_mode_default_auto" "defaults to auto when unset" "$CLI" "$BROWSER_BRIDGE_BATS"

# v0.16.5: the configured slider must ROUND MiB->GB (via _vm_gb_rounded), not
# truncate, so a non-1024-aligned MemoryMiB reports the slider the user set
# (7936 -> 8) instead of under-reporting (7) and re-tripping the undersized nag.
# Revert the settings path to the old truncating arithmetic: the 7936->8 test reads 7.
cat > "$SED_TMP" << 'SED'
s@_vm_gb_rounded "$(( 10#$mib \* 1048576 ))"@printf '%s' "$(( 10#$mib \* 1048576 / 1073741824 ))"@
SED
try "vnext_vm_configured_rounds" "non-1024-aligned MemoryMiB rounds to nearest" "$CLI" "$PRUNE_BATS"

# v0.16.5: the configured slider must scale MiB->bytes (* 1048576) before rounding.
# Drop the multiplier: _vm_gb_rounded sees raw MiB and a 24576 slider reads ~0, so
# "reads MemoryMiB from settings-store" no longer reads 24.
cat > "$SED_TMP" << 'SED'
s@10#$mib \* 1048576@10#$mib@
SED
try "vnext_vm_configured_mib_scale" "reads MemoryMiB from settings-store" "$CLI" "$PRUNE_BATS"

# v0.16.5: the overload trigger must compare in the SAME whole-GB unit it prints
# (sum_gb > vm_gb), never raw bytes, or a slider that rounds above MemTotal makes
# the warning fire while reading "promised 24 of 24". Revert to the byte compare:
# the "never contradicts itself" test sees the self-contradicting line and fails.
cat > "$SED_TMP" << 'SED'
s|sum_gb > vm_gb|sum > vm_bytes|
SED
try "vnext_overload_compares_gb" "never contradicts itself" "$CLI" "$PRUNE_BATS"

# v0.16.5: cmd_login must pass host_opens_clicks=0 (the login watcher only ever
# sees a programmatically launched auth URL, never a clicked link). Flip it to 1:
# a non-loopback console auth URL would be deferred to a terminal that never opens
# it, so the "passes host_opens_clicks=0" test sees 1 and fails.
cat > "$SED_TMP" << 'SED'
s|"$_login_bridge_mode" "0" >>|"$_login_bridge_mode" "1" >>|
SED
try "vnext_login_opens_auth" "passes host_opens_clicks=0" "$CLI" "$HOOKS_BATS"

# v0.16.5: CLEAT_BROWSER_BRIDGE=off must suppress every browser open. Flip the off
# branch to open: the "off mode opens nothing" test sees a tab open and fails.
cat > "$SED_TMP" << 'SED'
s|off)    return 1 ;;|off)    return 0 ;;|
SED
try "vnext_bridge_off_suppresses" "off mode opens nothing" "$CLI" "$BROWSER_BRIDGE_BATS"

# v0.16.5: cmd_login's off-mode message must differ from the auto-open promise.
# Invert the mode test so off prints "open automatically": the off-message test,
# which asserts the CLEAT_BROWSER_BRIDGE=off manual-open line, fails.
cat > "$SED_TMP" << 'SED'
s|"$_login_bridge_mode" = off|"$_login_bridge_mode" != off|
SED
try "vnext_login_off_message" "off mode prints the manual-open message" "$CLI" "$HOOKS_BATS"

# v0.16.5: an auth URL (localhost OAuth callback) must ALWAYS open via the bridge,
# even on an interactive terminal, so cleat login works. Flip the is_auth gate to
# defer: the "auto OPENS an auth URL even on an interactive" test fails.
cat > "$SED_TMP" << 'SED'
s|return 0            # auth URL: the bridge owns it|return 1            # auth URL: the bridge owns it|
SED
try "vnext_bridge_auth_always_opens" "OPENS an auth URL even on an interactive" "$CLI" "$BROWSER_BRIDGE_BATS"

# ── 2026-06-27 bugfix round (img: 25 GB advisory + fresh-project login) ───────

# AUTH (token): a host re-login leaves the shared .credentials.json expired; a
# fresh box must re-seed from the fresher, valid Keychain instead of dropping to
# login. Make the file-token always look still-valid: the re-seed never fires and
# the "re-seeds when EXPIRED" test sees the stale token survive.
cat > "$SED_TMP" << 'SED'
s|(( file_exp > now_ms )) && return 0|(( file_exp > 0 )) \&\& return 0|
SED
try "bugfix_token_reseed_expired" "re-seeds when the file token is EXPIRED" "$CLI" "$CREDENTIALS_BATS"

# AUTH (token): the re-seed must NOT overwrite from a Keychain token that is
# itself expired. Drop the kc-still-valid clause: the "does NOT re-seed from a
# Keychain token that is itself expired" test sees the stale file clobbered.
cat > "$SED_TMP" << 'SED'
s|(( kc_exp > file_exp && kc_exp > now_ms ))|(( kc_exp > file_exp ))|
SED
try "bugfix_token_reseed_kc_valid" "does NOT re-seed from a Keychain token that is itself expired" "$CLI" "$CREDENTIALS_BATS"

# AUTH (token): _oauth_expires_at must surface the parsed ms epoch. Break the
# print so it never returns the number: the extraction test fails.
cat > "$SED_TMP" << 'SED'
s|\[\[ "\$n" =~ \^\[0-9\]+\$ \]\] && printf '%s' "\$n"|printf '%s' "BROKEN"|
SED
try "bugfix_oauth_expires_extract" "extracts the ms epoch" "$CLI" "$CREDENTIALS_BATS"

# AUTH (onboarding): a fresh project must be born with a /workspace block so a
# newer bundled Claude does not re-run first-run/onboarding. Empty the seeded
# defaults: the "seeds /workspace trust + onboarding + bypass" test fails.
cat > "$SED_TMP" << 'SED'
s|{hasTrustDialogAccepted:true, hasCompletedProjectOnboarding:true, bypassPermissionsModeAccepted:true}|{}|
SED
try "bugfix_claudejson_workspace_seed" "seeds /workspace trust" "$CLI" "$CLAUDE_JSON_BATS"

# AUTH (onboarding): onboarding must be forced complete inside the cage. Drop the
# force: the "forces hasCompletedOnboarding=true even when the host file lacks it"
# test sees the key absent.
cat > "$SED_TMP" << 'SED'
/+ { hasCompletedOnboarding: true }/d
SED
try "bugfix_claudejson_force_onboarding" "forces hasCompletedOnboarding=true even when the host file lacks it" "$CLI" "$CLAUDE_JSON_BATS"

# GB: the status overcommit line must trigger and display in the SAME whole-GB
# unit. Revert the trigger to raw bytes vs MemTotal: a sum in the (MemTotal,
# slider) band fires while printing a smaller-than-VM number, and the
# "never contradicts itself" status test sees "overcommitted" appear.
cat > "$SED_TMP" << 'SED'
s|(( _sum_gb > _vm_gb ))|(( _limit_sum > _vm_bytes ))|
SED
try "bugfix_status_overcommit_unit" "the overcommit line never contradicts itself" "$CLI" "$PRUNE_BATS"

# GB: the overload notice must name the running-session COUNT. Push the count
# guard out of reach so it falls back to the generic "Running sessions": the
# "names the running-session COUNT" test no longer sees "5 sessions still running".
cat > "$SED_TMP" << 'SED'
s|(( _n_boxes > 0 ))|(( _n_boxes > 999999 ))|
SED
try "bugfix_overload_names_count" "names the running-session COUNT" "$CLI" "$PRUNE_BATS"

# GB: the count pluralization must NOT embed a command substitution in a plain
# assignment (the sub exits 1 on the singular case, aborting `cleat start` under
# set -e). Reintroduce the unsafe inline form: the strict-mode n==1 regression
# test aborts before REACHED_END_OK.
cat > "$SED_TMP" << 'SED'
s|(( _n_boxes != 1 )) && _s="s"|_s="$( (( _n_boxes != 1 )) \&\& printf s )"|
SED
try "bugfix_overload_count_set_e" "set-e abort start with exactly ONE" "$CLI" "$REGRESSIONS"

# IDLE SWEEP: a box with a live claude/node agent must NEVER be stopped (autonomy:
# unattended work). Drop the liveness skip: the "NEVER stops a box with a live
# agent" test sees a working box stopped.
cat > "$SED_TMP" << 'SED'
/_box_has_live_agent "\$name" && continue/d
SED
try "bugfix_idle_liveness_gate" "NEVER stops a box with a live agent" "$CLI" "$IDLE_SWEEP_BATS"

# IDLE SWEEP: the box being launched must be excluded. Drop the self check: the
# "never stops the box being launched" test sees the self box stopped.
cat > "$SED_TMP" << 'SED'
/\[\[ "\$name" == "\$self" \]\] && continue/d
SED
try "bugfix_idle_self_exclusion" "never stops the box being launched" "$CLI" "$IDLE_SWEEP_BATS"

# IDLE SWEEP: a box detached inside the grace window must be left alone. Drop the
# grace check: the "leaves a recently-detached box alone" test sees it stopped.
cat > "$SED_TMP" << 'SED'
/(( now - age < grace_secs )) && continue/d
SED
try "bugfix_idle_grace_window" "leaves a recently-detached box alone" "$CLI" "$IDLE_SWEEP_BATS"

# IDLE SWEEP: a box with an unknown activity clock (mtime 0) must be skipped,
# never stopped on a guess. Weaken the guard to accept 0: the "skips a box with
# unknown age" test sees it stopped.
cat > "$SED_TMP" << 'SED'
s|(( age > 0 ))|(( age >= 0 ))|
SED
try "bugfix_idle_unknown_age" "skips a box with unknown age" "$CLI" "$IDLE_SWEEP_BATS"

# ── 2026-07-07 login regressions (code-paste flow + cross-box identity) ──────

# BRIDGE: a code-paste login URL (redirect_uri on console.anthropic.com, no
# loopback port) must classify as auth in the watcher. Gut the classification:
# is_auth stays 0, the interactive auto session defers the login URL, and the
# "code-paste login URL ... still auto-opens" regression test sees no open.
cat > "$SED_TMP" << 'SED'
s|_is_auth_url "$url" && _is_auth=1|:|
SED
try "bugfix_codepaste_url_is_auth" "still auto-opens in an interactive session" "$CLI" "$REGRESSIONS"

# BRIDGE: _is_auth_url must match a redirect_uri= that arrives after & (every
# real authorize URL). Kill the &-alternative: the truth-table test's code-paste
# URL no longer classifies and "classifies as auth" fails.
cat > "$SED_TMP" << 'SED'
s|\*\\&redirect_uri=\*) return 0 ;;|__nomatch__) return 0 ;;|
SED
try "bugfix_is_auth_url_amp_param" "console callback, no loopback" "$CLI" "$BROWSER_BRIDGE_BATS"

# BROWSER ENV: the box must be created with BROWSER pointing at the open shim
# (claude 2.1.191+ invokes no opener on a display-less Linux without it). Drop
# the -e line: the "created with BROWSER pointing at the open shim" test fails.
cat > "$SED_TMP" << 'SED'
\|-e "BROWSER=/usr/local/bin/open-bridge"|d
SED
try "bugfix_browser_env_at_create" "BROWSER pointing at the open shim" "$CLI" "$REGRESSIONS"

# BROWSER AT EXEC: docker exec inherits the container's Config.Env, frozen at
# create, so a box created before v1.1.1 never sees the create-time -e BROWSER
# and login stays on the manual code-paste flow forever (real-hardware report
# 2026-07-11). Delete ONLY the exec-time CLAUDE_ENV entry (create-time -e
# stays, exactly the pre-fix state): the "attaching to a box created before
# v1.1.1" regression loses BROWSER on the recorded exec line.
cat > "$SED_TMP" << 'SED'
\|^CLAUDE_ENV+=(-e "BROWSER=/usr/local/bin/open-bridge")$|d
SED
try "vnext_browser_exec_env" "still gets BROWSER at exec time" "$CLI" "$REGRESSIONS"

# BROWSER PER EXEC SITE: the heal rests on CLAUDE_ENV riding all three exec
# sites. A refactor that swaps the array on ONE site for hand-built -e entries
# keeps HOME, a .local/bin PATH, and TERM (so every older assertion stays
# green) while silently losing BROWSER there: standalone `cleat shell` or
# `cleat login` on a pre-v1.1.1 box drops back to code-paste. One mutation per
# site; only the per-site BROWSER assertion can catch each.
cat > "$SED_TMP" << 'SED'
/^cmd_shell()/,/^}$/{
  s|"\${CLAUDE_ENV\[@\]}"|-e HOME=/home/coder -e PATH=/home/coder/.local/bin:/usr/local/bin:/usr/bin:/bin -e TERM=xterm|
}
SED
try "vnext_browser_shell_env" "execs bash as coder" "$CLI" "$DOCKER_COMMANDS_BATS"

cat > "$SED_TMP" << 'SED'
/^cmd_login()/,/^}$/{
  s|"\${CLAUDE_ENV\[@\]}"|-e HOME=/home/coder -e PATH=/home/coder/.local/bin:/usr/local/bin:/usr/bin:/bin -e TERM=xterm|
}
SED
try "vnext_browser_login_env" "runs claude login as coder" "$CLI" "$DOCKER_COMMANDS_BATS"

# BRIDGE STARTUP AGE GATE: the watcher's startup sweep must only remove a
# STALE leftover bridge file. Reverting the gate to always-true (age > -1 is
# unconditional) restores the pre-fix swallow: a watcher starting moments
# after claude wrote a login URL deletes it before any sibling watcher's poll
# can claim it, stranding that login.
cat > "$SED_TMP" << 'SED'
s|)) -gt 5 \]|)) -gt -1 ]|
SED
try "vnext_bridge_startup_age_gate" "keeps a FRESH pending URL" "$CLI" "$BROWSER_BRIDGE_BATS"

# IDENTITY: keys absent from BOTH the host file and this project's copy must
# fall through to the newest sibling box that holds a login. Revert to the
# host//proj rule: the "inherits identity from the newest sibling box" build
# test and the cmd_start regression both lose the oauthAccount.
cat > "$SED_TMP" << 'SED'
s|$proj\[.\] // $sib\[.\]|$proj[.]|
SED
try "bugfix_identity_sibling_fallback" "inherits identity from the newest sibling box" "$CLI" "$CLAUDE_JSON_BATS"

# IDENTITY: cmd_start of a STOPPED box must rebuild its claude.json first
# (docker start re-resolves the bind source; without the refresh only a full
# recreate picks up a login done in another box). Drop the refresh call INSIDE
# cmd_start only: the "carries the login in" regression test (which drives
# cmd_start) finds no oauthAccount.
cat > "$SED_TMP" << 'SED'
/^cmd_start()/,/^}$/{
  /_refresh_project_claude_json "\$project" "\$box"/d
}
SED
try "bugfix_identity_refresh_start" "carries the login in" "$CLI" "$REGRESSIONS"

# IDENTITY: cmd_resume must do the SAME refresh (the resume entrypoint is a
# distinct call site; deleting only it slips past the cmd_start test). Drop the
# refresh call INSIDE cmd_resume only: the "folds an in-box login" resume test
# finds no oauthAccount.
cat > "$SED_TMP" << 'SED'
/^cmd_resume()/,/^}$/{
  /_refresh_project_claude_json "\$project" "\$box"/d
}
SED
try "bugfix_identity_refresh_resume" "folds an in-box login" "$CLI" "$START_RESUME_BATS"

# IDENTITY: attaching to a RUNNING box must heal a logged-out claude.json in
# place (liveness-gated; the bind mount pins the inode, so the start/create
# rebuilds cannot reach it). Drop the exec_claude call: the "running
# logged-out box heals" regression test sees the poisoned flag stay false.
cat > "$SED_TMP" << 'SED'
/_refresh_attached_claude_json "\$cname" "\${_RESOLVED_PROJECT:-}" "\${_BOX:-main}"/d
SED
try "bugfix_identity_attach_heal" "running logged-out box heals" "$CLI" "$REGRESSIONS"

# IDENTITY: the attach-heal gate must key on hasCompletedOnboarding ALONE. Add
# back the oauthAccount clause: an onboarded API-key box (no oauthAccount) then
# fails the gate and runs the pipeline + docker probe on every attach, so the
# "onboarded API-key box short-circuits" test sees the probe fire.
cat > "$SED_TMP" << 'SED'
s|jq -e '\.hasCompletedOnboarding == true' "\$f" >/dev/null 2>&1 \&\& return 0|jq -e '(.hasCompletedOnboarding == true) and has("oauthAccount")' "$f" >/dev/null 2>\&1 \&\& return 0|
SED
try "bugfix_attach_heal_gate_onboarding" "onboarded API-key box" "$CLI" "$EXEC_CLAUDE_BATS"

# IDENTITY: the claude.json merge base must be proj-then-host so a box-only
# top-level key (e.g. user-scoped mcpServers) survives the rebuild that now
# re-runs on every start/resume/attach. Revert the base to host-only: the
# "box-only top-level key survives the rebuild" test sees mcpServers dropped.
cat > "$SED_TMP" << 'SED'
s|(\$proj + \$host)|$host|
SED
try "bugfix_claudejson_preserves_box_keys" "box-only top-level key survives" "$CLI" "$CLAUDE_JSON_BATS"

# BROWSER ENV ORDERING: the shim -e BROWSER must precede the user [env] args so
# docker's last-wins lets a .cleat BROWSER= override the shim. Move the shim
# line to AFTER _RESOLVED_ENV_ARGS: the ordering test sees the user override
# lose.
cat > "$SED_TMP" << 'SED'
/-e "BROWSER=\/usr\/local\/bin\/open-bridge" \\/d
s|"\${_RESOLVED_ENV_ARGS\[@\]+"\${_RESOLVED_ENV_ARGS\[@\]}"}" \\|"${_RESOLVED_ENV_ARGS[@]+"${_RESOLVED_ENV_ARGS[@]}"}" \\\n    -e "BROWSER=/usr/local/bin/open-bridge" \\|
SED
try "bugfix_browser_env_ordering" "BROWSER shim is passed before user env" "$CLI" "$DOCKER_COMMANDS_BATS"

# BRIDGE LOG: a deferred URL must be logged (a silent defer is what made the
# regression hard to diagnose). Garble the defer log string (deleting the line
# would leave an empty else): the "auto mode does NOT re-open a plain link"
# test no longer finds the "deferring URL to terminal" line.
cat > "$SED_TMP" << 'SED'
s|deferring URL to terminal|silently dropping URL|
SED
try "bugfix_browser_defer_logged" "does NOT re-open a plain link" "$CLI" "$BROWSER_BRIDGE_BATS"

# SETTINGS-MASK TARGET PRE-CREATE: a fresh host without ~/.claude/settings.json
# must still create a box on macOS (VirtioFS rejects a nested file mount whose
# target is missing inside the parent bind's source). Remove the pre-create:
# the virtiofs-simulated cmd_run fails.
cat > "$SED_TMP" << 'SED'
\|echo '{}' > "${HOME}/.claude/settings.json"|d
SED
try "bugfix_settings_mask_target_precreate" "fresh host without" "$CLI" "$REGRESSIONS"

# KIT RO MASKS: the two kit overlay mounts must be read-only. :ro is
# load-bearing twice (concept/34): it keeps the copied mask from becoming an
# agent-writable scratch that regen clobbers, and it closes the in-box write
# channel to the host's user-level CLAUDE.md/agents. Drop :ro from both: the
# mount test no longer finds the read-only flags.
cat > "$SED_TMP" << 'SED'
s|/kit/CLAUDE.md:/home/coder/.claude/CLAUDE.md:ro|/kit/CLAUDE.md:/home/coder/.claude/CLAUDE.md|
s|/kit/agents:/home/coder/.claude/agents:ro|/kit/agents:/home/coder/.claude/agents|
s|/kit/commands:/home/coder/.claude/commands:ro|/kit/commands:/home/coder/.claude/commands|
s|/kit/skills:/home/coder/.claude/skills:ro|/kit/skills:/home/coder/.claude/skills|
s|:/home/coder/.claude/plugins:ro|:/home/coder/.claude/plugins|
SED
try "kits_ro_masks" "cmd_run mounts every kit mask read-only" "$CLI" "$KITS_BATS"

# KIT COMMANDS MASK MOUNT: the third :ro mask (slash commands) must be present,
# or a caged agent can plant a host-user-level command native claude runs.
# Drop the commands mount entirely: the mask-mount test loses it.
cat > "$SED_TMP" << 'SED'
/-v "\$CLEAT_RUN_DIR\/\${cname}\/kit\/commands:\/home\/coder\/\.claude\/commands:ro"/d
SED
try "kits_commands_mask_mount" "cmd_run mounts every kit mask read-only" "$CLI" "$KITS_BATS"

# KIT COMMANDS PASS-THROUGH: the box must still READ the user's own slash
# commands (the mask seeds a copy). Break the copy: the pass-through test no
# longer finds the user's command in the overlay.
cat > "$SED_TMP" << 'SED'
s|        cp -R "$_cm/." "$kit_dir/commands/$_cmb/" 2>/dev/null \|\| true|        true|
s|        cp "$_cm" "$kit_dir/commands/$_cmb" 2>/dev/null \|\| true|        true|
SED
try "kits_commands_passthrough" "pass-through-copies the user's slash commands" "$CLI" "$KITS_BATS"

# KIT SKILLS MASK MOUNT: ~/.claude/skills is an AUTO-LOAD plugin source, so a
# planted skill runs with no user action at all (strictly worse than a slash
# command, which needs the user to type it). Drop the mount: the mask test
# loses it.
cat > "$SED_TMP" << 'SED'
/-v "\$CLEAT_RUN_DIR\/\${cname}\/kit\/skills:\/home\/coder\/\.claude\/skills:ro"/d
SED
try "kits_skills_mask_mount" "cmd_run mounts every kit mask read-only" "$CLI" "$KITS_BATS"

# KIT PLUGINS MASK MOUNT: an enabled plugin's payload and the marketplace git
# checkout are both host-executed. Drop the self-mask: the mask test loses it.
cat > "$SED_TMP" << 'SED'
/-v "\${HOME}\/\.claude\/plugins:\/home\/coder\/\.claude\/plugins:ro"/d
SED
try "kits_plugins_mask_mount" "cmd_run mounts every kit mask read-only" "$CLI" "$KITS_BATS"

# KIT SKILLS PASS-THROUGH: the box must still READ the user's own skills.
# Neutralize the recursive copy: the pass-through test finds nothing.
cat > "$SED_TMP" << 'SED'
s|cp -R "$_sk/." "$kit_dir/skills/$_skb/" 2>/dev/null \|\| true|true|
SED
try "kits_skills_passthrough" "pass-through-copies the user's skills" "$CLI" "$KITS_BATS"

# KIT SKILLS NESTED SYMLINK: the recursive copy must NOT dereference. Restore
# -L: a skill symlinking ~/.ssh materializes real key bytes into the overlay
# the cage reads, and the no-deref test finds them.
cat > "$SED_TMP" << 'SED'
s|cp -R "$_sk/." "$kit_dir/skills/$_skb/"|cp -RL "$_sk/." "$kit_dir/skills/$_skb/"|
SED
try "kits_skills_no_deref_nested" "symlink inside a skill is not dereferenced" "$CLI" "$KITS_BATS"

# KIT SKILLS MODE NORMALIZE: a 0500 skill dir copies through at 0500 and the
# NEXT regen's rm dies EPERM, aborting the start under strict mode. Drop the
# chmod: the read-only-skill regen test fails.
cat > "$SED_TMP" << 'SED'
/chmod -R u+rwX "\$kit_dir\/skills"/d
SED
try "kits_skills_readonly_regen" "read-only dir inside a skill does not abort" "$CLI" "$KITS_BATS"

# KIT SKILLS OVERLAY SELF-HEAL: a SYMLINK at the overlay skills path is not
# caught by -f, and the clear loop would then delete files in the link's TARGET
# directory. Drop the -L half: the replaced-not-followed test fails.
cat > "$SED_TMP" << 'SED'
s|\[\[ -L "$kit_dir/skills" \|\| -f "$kit_dir/skills" \]\]|[[ -f "$kit_dir/skills" ]]|
SED
try "kits_skills_overlay_symlink_heal" "symlink at the skills overlay path itself is replaced" "$CLI" "$KITS_BATS"

# KIT SKILLS MASK TARGET: VirtioFS rejects a nested mount whose target is
# missing inside the parent bind source. Drop skills from the mkdir: the
# pre-create test fails.
cat > "$SED_TMP" << 'SED'
s|"${HOME}/.claude/skills" "${HOME}/.claude/plugins"$|"${HOME}/.claude/agents"|
SED
try "kits_skills_mask_target_precreate" "generates the overlay and pre-creates the host targets" "$CLI" "$KITS_BATS"

# KIT SKILLS RECREATE NOTE: a box created before the skills mask keeps the host
# surface writable and must be told. Drop skills from the advisory list: the
# missing-skills-mask note test fails.
cat > "$SED_TMP" << 'SED'
s|/home/coder/.claude/commands /home/coder/.claude/skills \\|/home/coder/.claude/commands \\|
SED
try "kits_skills_recreate_note" "box missing the skills mask gets the recreate note" "$CLI" "$KITS_BATS"

# CONTAINMENT PROJECTS MASK: without the generated parent, the HOST's
# ~/.claude/projects passes through the base rw mount and every other project's
# transcript is readable. Drop the mount: the mask test loses it.
cat > "$SED_TMP" << 'SED'
/-v "\$home_overlay\/projects:\/home\/coder\/\.claude\/projects:ro"/d
SED
try "containment_projects_mask" "cmd_run masks the projects dir with a generated parent" "$CLI" "$KITS_BATS"

# CONTAINMENT PRIVATE DIRS: file-history alone held 185 MB of other projects'
# file snapshots. Empty the registry: the per-box backing test finds no mounts.
cat > "$SED_TMP" << 'SED'
s|^_CLAUDE_PRIVATE_DIRS=.*|_CLAUDE_PRIVATE_DIRS=""|
SED
try "containment_private_dirs" "cross-project dirs are backed by this box" "$CLI" "$KITS_BATS"

# CONTAINMENT KEY SCOPE: the generated parent must hold ONLY this project's
# keys. Seed it from the host's projects dir instead: the scope test sees more.
cat > "$SED_TMP" << 'SED'
s|  mkdir -p "$home_dir/projects/-workspace"|  mkdir -p "$home_dir/projects/-workspace"; cp -R "${HOME}/.claude/projects/." "$home_dir/projects/" 2>/dev/null \|\| true|
SED
try "containment_key_scope" "generated projects parent holds only this project" "$CLI" "$KITS_BATS"

# CONTAINMENT STALE KEY PRUNE: a key from a previous project path must not
# linger as a mountpoint the box no longer owns. Drop the prune loop's rmdir.
cat > "$SED_TMP" << 'SED'
s|      \*) rmdir "$_k" 2>/dev/null \|\| true ;;|      *) : ;;|
SED
try "containment_stale_key_prune" "regen prunes a session key the box no longer owns" "$CLI" "$KITS_BATS"

# CONTAINMENT VIRTIOFS TARGETS: a nested mount whose target is missing inside
# the parent bind source fails on macOS. Drop the pre-create loop.
cat > "$SED_TMP" << 'SED'
/    mkdir -p "\${HOME}\/\.claude\/\$_p" 2>\/dev\/null || true/d
SED
try "containment_virtiofs_targets" "host mask targets are pre-created for virtiofs" "$CLI" "$KITS_BATS"

# CONTAINMENT SELF HEAL: a symlink where an overlay dir belongs would make the
# box write through to the link's target. Drop the -L half of the self-heal.
cat > "$SED_TMP" << 'SED'
s|\[\[ -L "$home_dir/$_d" \|\| -f "$home_dir/$_d" \]\]|[[ -f "$home_dir/$_d" ]]|
SED
try "containment_overlay_self_heal" "wrong-type overlay entry is self-healed" "$CLI" "$KITS_BATS"

# CONTAINMENT REGRESSION: the transcripts of every other project must not be
# reachable. Restore the host projects mount: the regression test fails.
cat > "$SED_TMP" << 'SED'
s|-v "$home_overlay/projects:/home/coder/.claude/projects:ro"|-v "${HOME}/.claude/projects:/home/coder/.claude/projects"|
SED
try "containment_no_cross_project_read" "cannot read another project" "$CLI" "$REGRESSIONS"

# CONTAINMENT HOOKS: ~/.claude/hooks is the one containment entry whose leak is
# host EXECUTION, not just disclosure: the hooks capability runs the user's hook
# commands on the host, and those commands conventionally name a script under
# that dir. Drop it from the private list and the host dir rides the read-write
# base mount again, so a caged agent can overwrite the script the host runs.
cat > "$SED_TMP" << 'SED'
s@ sessions tasks jobs hooks"@ sessions tasks jobs"@
SED
try "containment_host_hooks_dir" "cannot plant a host hook script" "$CLI" "$REGRESSIONS"

# HOOK BRIDGE JQ INJECTION: the forwarded event name is agent-controlled. Put it
# back into the jq PROGRAM instead of passing it as --arg data, and a crafted
# event name synthesizes its own hook entry, giving the box bash -c on the host.
cat > "$SED_TMP" << 'SED'
s@^.*--arg ev.*$@    hook_entries="$(jq -c ".hooks.\\"$event_name\\" // [] | .[]" "$settings" 2>/dev/null)" || continue@
SED
try "hook_bridge_event_name_is_data" "cannot inject a jq program" "$CLI" "$REGRESSIONS"

FORK_BATS="$REPO_ROOT/test/unit/fork.bats"

# FORK SYMLINK DEREF: the copy must NOT follow symlinks. Add -L and a project
# containing keys -> ~/.ssh materialises real key bytes into the cage's copy.
cat > "$SED_TMP" << 'SED'
s@_FORK_CP_FLAGS="-R -d --reflink=auto"@_FORK_CP_FLAGS="-RL --reflink=auto"@
s@_FORK_CP_FLAGS="-R -d"@_FORK_CP_FLAGS="-RL"@
s@_FORK_CP_FLAGS="-Rc"@_FORK_CP_FLAGS="-RLc"@
SED
try "fork_no_symlink_deref" "symlink inside the project is copied as a symlink" "$CLI" "$FORK_BATS"

# FORK CP ARM SELECTION: the flags must come from the cp BINARY, never from the
# OS. Break the GNU case label and a GNU host falls down the BSD arm, which is
# exactly the Homebrew-coreutils-on-macOS breakage the probe exists to prevent.
cat > "$SED_TMP" << 'SED'
s@"GNU coreutils"@"NEVER MATCHES THIS"@
SED
try "fork_cp_arm_selection" "cp flags from a" "$CLI" "$FORK_BATS"

# FORK CP HARDLINKS: -d keeps hardlinks inside the tree shared, so a pnpm store
# is not multiplied by every fork. Dropping it is silent: copies still work.
cat > "$SED_TMP" << 'SED'
s@_FORK_CP_FLAGS="-R -d --reflink=auto"@_FORK_CP_FLAGS="-R --reflink=auto"@
s@_FORK_CP_FLAGS="-R -d"@_FORK_CP_FLAGS="-R"@
SED
try "fork_cp_gnu_hardlinks" "cp flags from a GNU binary" "$CLI" "$FORK_BATS"

# FORK CP REFLINK: --reflink=auto is why forking a large repo is usable at all.
# Dropping it degrades to a full byte copy with every test still passing.
cat > "$SED_TMP" << 'SED'
s@_FORK_CP_FLAGS="-R -d --reflink=auto"@_FORK_CP_FLAGS="-R -d"@
SED
try "fork_cp_gnu_reflink" "cp flags from a GNU binary" "$CLI" "$FORK_BATS"

# FORK CP CLONEFILE: the BSD half of the same property. -c is what makes a fork
# on APFS near-instant and near-free.
cat > "$SED_TMP" << 'SED'
s@_FORK_CP_FLAGS="-Rc"@_FORK_CP_FLAGS="-R"@
SED
try "fork_cp_bsd_clone" "cp flags from a BSD binary" "$CLI" "$FORK_BATS"

# FORK CP CLONE PROBE: the BSD arm must PROBE for -c, not assume it. FreeBSD cp
# has no -c at all and macOS predating clonefile rejects it, so assuming it
# fails every fork there. Short-circuit the probe so -c is assumed: the
# no-clonefile arm gets -Rc instead of -R, and its probe log stays empty.
cat > "$SED_TMP" << 'SED'
s@if mkdir -p "$_p/s"@if true || mkdir -p "$_p/s"@
SED
try "fork_cp_clone_probed_not_assumed" "cp flags from a BSD binary" "$CLI" "$FORK_BATS"

# FORK CP PROBE CLEANUP: the probe writes a scratch tree under the fork root.
# Drop the cleanup and every cleat invocation on a BSD host leaves a .cpprobe
# directory behind, filling the fork root.
cat > "$SED_TMP" << 'SED'
s@  rm -rf "$_p" 2>/dev/null || true@  :@
SED
try "fork_cp_probe_cleanup" "clone probe leaves nothing behind" "$CLI" "$FORK_BATS"

# FORK WORKSPACE SWAP: the whole feature is this one mount. Point it back at
# the live tree and the fork box edits the real repo.
cat > "$SED_TMP" << 'SED'
s|    -v "$_workspace":/workspace|    -v "$project":/workspace|
SED
try "fork_workspace_mount" "cmd_run mounts the copy at workspace" "$CLI" "$FORK_BATS"

# FORK DOCKER CAP: with the docker cap the box also gets the workspace at its
# host path. Restore $project there and a fork box gets the REAL tree back.
cat > "$SED_TMP" << 'SED'
s|    mount_args+=(-v "$_workspace:$_workspace")|    mount_args+=(-v "$project:$project")|
SED
try "fork_docker_cap_real_tree" "docker cap exposes the copy" "$CLI" "$FORK_BATS"

# FORK MISSING COPY: a fork box whose copy vanished must REFUSE. Fall back to
# the live tree instead and the box silently edits the real repo, with a
# success message.
#
# This property has TWO layers, so the mutation removes both. The preflight runs
# first (and now runs in cmd_run too, so `cleat run --fork` cannot destroy a
# plain box), and the check inside cmd_run is the backstop for a copy that
# vanishes between the preflight and the moment the mount is built. Dropping
# only one used to leave the other standing, which reported MISSED and would
# have read as a broken test rather than as defence in depth.
cat > "$SED_TMP" << 'SED'
/^  _fork_preflight "$cname" recreate$/d
s@if \[\[ ! -d "$_fork_path" \]\]; then@if false; then@
SED
try "fork_missing_copy_refuses" "copy is missing refuses" "$CLI" "$FORK_BATS"

# FORK RUN PREFLIGHT: `cleat run <box> --fork` reaches cmd_run without the
# preflight cmd_start does first, and cmd_run's container_exists branch is a
# plain `docker rm`. Without the preflight here the flag DESTROYS an existing
# plain box's writable layer and rebuilds it on a copy. Delete only the cmd_run
# call (the first of the three, by line order) and that test goes red while the
# start and resume paths stay intact.
cat > "$SED_TMP" << 'SED'
/^cmd_run() {/,/^}$/{
  /^  _fork_preflight "\$cname" recreate$/d
}
SED
try "fork_run_preflight" "run refuses the flag on an existing plain box" "$CLI" "$FORK_BATS"

# FORK SESSION KEY: under the docker cap the container cd's into the workspace
# HOST path, so Claude Code derives its session key from the fork COPY. Key the
# generated mountpoint off the live project instead and the box looks for a key
# that does not exist, under a :ro parent it cannot create: sessions and memory
# silently stop persisting. Shipped broken, found on a real host run.
cat > "$SED_TMP" << 'SED'
s@_generate_home_overlay "$cname" "$_workspace"@_generate_home_overlay "$cname" "$project"@
SED
try "fork_session_key_mountpoint" "session key follows the copy" "$CLI" "$FORK_BATS"

# FORK SESSION MOUNT: the other half. The writable session dir must be mounted
# at the same workspace-derived key, or the mountpoint exists and stays empty.
cat > "$SED_TMP" << 'SED'
s@_host_project_key="$(_claude_session_key "$_workspace")"@_host_project_key="$(_claude_session_key "$project")"@
SED
try "fork_session_key_mount" "session key follows the copy" "$CLI" "$FORK_BATS"

# FORK SESSION KEY DOTS: Claude Code encodes BOTH / and . as a dash. Replacing
# only slashes matched for a dotless project path, so this hid, but the DEFAULT
# fork root is ~/.config/cleat/forks: drop the dot half and every fork box under
# the docker cap looks for a session dir that was never created, under a :ro
# parent it cannot create one in. Silent loss of sessions and memory.
cat > "$SED_TMP" << 'SED'
s@LC_ALL=C sed 's/\[^A-Za-z0-9\]/-/g'@LC_ALL=C sed 's|/|-|g'@
SED
try "fork_session_key_dots" "replaces dots as well as slashes" "$CLI" "$FORK_BATS"

# FORK CONFIG SECTION: [fork] must be a KNOWN section. Drop it from the project
# allow-list and every launch of a project using `exclude = node_modules` warns
# that its own config section is unknown and ignored.
cat > "$SED_TMP" << 'SED'
s@caps|resources|setup|fork) continue@caps|resources|setup) continue@
SED
try "fork_section_is_known" "fork. is known in a project" "$CLI" "$REPO_ROOT/test/unit/provision.bats"

# FORK HEAL NOTICE ONCE: cmd_start and cmd_run both preflight. Drop the
# once-per-process guard and the heal line prints twice, as it did on the host.
cat > "$SED_TMP" << 'SED'
/^  \[\[ -n "$_FORK_PREFLIGHT_DONE" \]\] && return 0$/d
SED
try "fork_preflight_once" "heal notice prints once" "$CLI" "$FORK_BATS"

# FORK RM TREE CONTAINMENT: _fork_rm_tree is an `rm -rf` on a path built from a
# container name and a user-configurable root. Make the containment check always
# pass and it will delete whatever it is handed. Scoped with a line range so the
# identical guard in _fork_copy_tree keeps its own mutation.
# Anchored on the error string, NOT on a line range: the first version of this
# entry used `2600,2620s@...@`, and inserting a helper 100 lines above silently
# moved _fork_rm_tree out of that window, so the sed became a no-op and the
# entry reported SKIPPED instead of failing loudly. Content anchors survive
# refactors; line ranges do not.
cat > "$SED_TMP" << 'SED'
s@    \*) error "Refusing to delete outside@    ZZ) error "Refusing to delete outside@
s@  if ! _fork_path_under_root "$target"; then@  if false; then@
SED
try "fork_rm_tree_containment" "refuses a target outside the fork root" "$CLI" "$FORK_BATS"

# FORK RM TREE SYMLINK: rm -rf on a symlinked copy follows it out of the fork
# root, so the containment check above passes while real host files die.
cat > "$SED_TMP" << 'SED'
s@  if \[\[ -L "$target" \]\]; then@  if false; then@
SED
try "fork_rm_tree_symlink" "refuses a symlinked copy" "$CLI" "$FORK_BATS"

# FORK RM LIVE BOX: rm and refresh must refuse while the container exists. It
# has the copy bind-mounted at /workspace, so replacing or deleting it hands the
# agent a half tree mid-session with no warning.
cat > "$SED_TMP" << 'SED'
s@      if container_exists "$cname"; then@      if false; then@
SED
try "fork_rm_refuses_live_box" "refuses while the box still exists" "$CLI" "$FORK_BATS"

# FORK PRUNE SELECTIVITY: prune must skip copies whose container still exists.
# Neuter the skip and it deletes the workspace of a live box.
cat > "$SED_TMP" << 'SED'
s@        container_exists "$cname" && continue@        false && continue@
SED
try "fork_prune_keeps_live" "keeps copies that still have a box" "$CLI" "$FORK_BATS"

# FORK SUMMARY PROJECT LINE: a fork box must not be printed as though the live
# project were mounted. Drop the fork branch and it falls back to the docker-cap
# line, which is what shipped: "Project: ~/proj (same path, sandboxed)" directly
# above a Fork line naming a different directory.
cat > "$SED_TMP" << 'SED'
s@      echo -e "  ${DIM}Project:${RESET}    ${display_path} ${DIM}(not mounted, this box works on a copy)${RESET}"@      :@
SED
try "fork_summary_project_not_mounted" "does not claim the project is mounted" "$CLI" "$FORK_BATS"

# FORK SUMMARY MOUNT TARGET: with the Project line no longer carrying the mount,
# the Fork line must. Neuter the branch and the summary never says where the
# copy is mounted at all.
cat > "$SED_TMP" << 'SED'
s@        _where="${DIM}(same path, sandboxed)${RESET}"@        _where=""@
s@        _where="${DIM}→${RESET} /workspace"@        _where=""@
SED
try "fork_summary_mount_target" "fork line points at workspace" "$CLI" "$FORK_BATS"

# FORK RUN SETS THE REQUEST: `cleat fork run` is only a real alias for
# `run --fork` if it sets the flag. Drop it and the verb quietly builds a PLAIN
# box on the live tree, which is the worst possible failure for this feature:
# the user asked for isolation by name and did not get it.
cat > "$SED_TMP" << 'SED'
/^      _FORK_REQUESTED=true$/d
SED
try "fork_run_sets_request" "mounts the copy at workspace, exactly like" "$CLI" "$FORK_BATS"

# FORK START LAUNCHES CLAUDE: `run` is create-only, so routing `fork start` to
# cmd_run hands the user a box and drops them at their shell. That confusion is
# exactly why both verbs exist.
cat > "$SED_TMP" << 'SED'
s@      if \[\[ "$sub" == "start" \]\]; then@      if false; then@
SED
try "fork_start_launches" "launches Claude rather than only creating" "$CLI" "$FORK_BATS"

# FORK RUN VALIDATES THE BOX: routing through _set_box is what gives this verb
# the same name validation and stray-argument refusal as every other box-aware
# verb. Hand-parsing it would let `cleat fork run "Bad Name"` through.
cat > "$SED_TMP" << 'SED'
/^      _set_box "$@"$/d
SED
try "fork_run_validates_box" "routes through _set_box" "$CLI" "$FORK_BATS"

SMOKE_BATS="$REPO_ROOT/test/unit/smoke.bats"

# CURSOR ESCAPES OFF A PIPE: `tput cnorm` writes to STDOUT whether or not stdout
# is a terminal. Ungate it and every command ends with a cursor-restore sequence
# on stdout, which is invisible to a human and fatal to
# `cd "$(cleat fork path feat-a)"`. Found on a host run 2026-07-31.
cat > "$SED_TMP" << 'SED'
s@_cursor_show() { _is_tty @_cursor_show() { true @
SED
try "cursor_escapes_off_a_pipe" "no cursor escapes reach stdout" "$CLI" "$SMOKE_BATS"

# HEAL NOTICE NEEDS SOMETHING TO HEAL: a fork marker outlives its box, so a
# leftover one made a brand-new `cleat fork start` open with "Fork workspace is
# missing, recreating it" when it was a first create. Ungate it and that returns.
# Anchored on a unique comment line rather than an absolute range, because a
# numeric range silently stops matching when anything above it moves.
cat > "$SED_TMP" << 'SED'
/path makes the copy anyway, so say nothing and let "Workspace copied"/,+4s@if container_exists "$cname"; then@if true; then@
SED
try "fork_heal_notice_needs_a_box" "first create does not announce a heal" "$CLI" "$FORK_BATS"

# STALE MARKER SWEEP REACHABLE: the sweep must be counted BEFORE the early
# return, because "no orphan copies" is exactly the state stale markers live in.
# Restore the copies-only early return and the sweep becomes dead code.
cat > "$SED_TMP" << 'SED'
s@      if \[\[ "$count" -eq 0 && "$stale" -eq 0 \]\]; then@      if [[ "$count" -eq 0 ]]; then@
SED
try "fork_prune_stale_markers" "clears a stale marker" "$CLI" "$FORK_BATS"

# FORK EXCLUDE SAFETY: an absolute or traversing exclude must be refused, or a
# .cleat in a cloned repo can delete outside the fork.
cat > "$SED_TMP" << 'SED'
s@warn "Ignoring unsafe \[fork\] exclude: $e"; continue@:@
SED
try "fork_exclude_path_safety" "traversing exclude is refused" "$CLI" "$FORK_BATS"

# FORK EXCLUDE PRUNE: excludes must actually be removed from the copy.
cat > "$SED_TMP" << 'SED'
s@    rm -rf "$_parent/$(basename "$_target")"@    :@
SED
try "fork_exclude_prune" "configured excludes are pruned" "$CLI" "$FORK_BATS"

# FORK STATUS DISCOVERY: a fork box mounts the forks path, so status must match
# it too or every fork box vanishes from Boxes.
cat > "$SED_TMP" << 'SED'
s@ || "$_src" == "$(_fork_dir "$_n")"@@
SED
try "fork_status_discovery" "a fork box is listed by cleat status" "$CLI" "$FORK_BATS"

# FORK SOURCE FORM: "$src/." into a created dst is the only form that survives
# a PROJECT ROOT that is itself a symlink. `cp ... "$src" "$dst"` copies the
# LINK, so the fork becomes an alias for the live tree and the feature voids.
cat > "$SED_TMP" << 'SED'
s@cp $cpflags "$src/." "$tmp/"@cp $cpflags "$src" "$tmp"@
SED
try "fork_source_form_symlink_root" "symlinked project root produces a real copy" "$CLI" "$FORK_BATS"

# FORK DEST GUARD: the copy must never rm -rf outside the forks dir, whatever
# the caller passes.
cat > "$SED_TMP" << 'SED'
s@    \*) error "Refusing to write a fork outside@    ignoreme) error "Refusing to write a fork outside@
s@  if ! _fork_path_under_root "$dst"; then@  if false; then@
SED
try "fork_dest_outside_guard" "refuses a destination outside the forks dir" "$CLI" "$FORK_BATS"

# FORK COPY LOCK: two concurrent --fork runs must not both rm -rf and copy into
# the same destination.
cat > "$SED_TMP" << 'SED'
s@  if ! mkdir "$lock" 2>/dev/null; then@  if false; then@
SED
try "fork_copy_lock" "second concurrent copy is refused" "$CLI" "$FORK_BATS"

# FORK PREFLIGHT ON RESUME: cmd_resume only re-checks bind sources when the
# container is STOPPED, so a RUNNING fork box whose copy was deleted reached
# exec_claude and reported success on an empty workspace. Drop the preflight
# call from cmd_resume: the running-box refusal test fails.
cat > "$SED_TMP" << 'SED'
/^  _fork_preflight "\$cname"/d
SED
try "fork_preflight_first_verb" "resume refuses when the copy is gone even if the box is running" "$CLI" "$FORK_BATS"

# FORK PREFLIGHT REFUSAL: with the marker set and the copy gone, and no --fork,
# the only safe answer is to refuse. Turn the refusal into a pass and a fork box
# silently comes up on whatever Docker leaves at the mount point.
cat > "$SED_TMP" << 'SED'
s@  error "This box is a fork but its workspace copy is missing."@  return 0@
SED
try "fork_preflight_refuses" "resume refuses when the copy is gone even if the box is running" "$CLI" "$FORK_BATS"

# FORK PREFLIGHT HEAL: an explicit --fork must rebuild rather than refuse. The
# mount is baked at create, so healing requires dropping the container.
cat > "$SED_TMP" << 'SED'
s@    docker rm -f "$cname" > /dev/null 2>&1 || true@    :@
s@    info "Fork workspace is missing, recreating it"@    error "no heal"; exit 1@
SED
try "fork_preflight_heals" "explicit fork flag heals a running box" "$CLI" "$FORK_BATS"

# FORK ROOT OVERRIDE: a project on another volume gets a full byte copy unless
# the fork root moves with it, because copy-on-write only works within a volume.
cat > "$SED_TMP" << 'SED'
s@  d="$(_read_section_from_file "$CLEAT_GLOBAL_CONFIG" fork dir 2>/dev/null || true)"@  d=""@
SED
try "fork_root_override" "global config fork dir moves the root" "$CLI" "$FORK_BATS"

# FORK ROOT ABSOLUTE ONLY: a relative fork root would resolve against whatever
# directory cleat happened to be run from.
cat > "$SED_TMP" << 'SED'
s@      /?\*) printf '%s\\n' "${d%/}"; return 0 ;;@      *) printf '%s\\n' "${d%/}"; return 0 ;;@
SED
try "fork_root_absolute_only" "relative fork dir is refused" "$CLI" "$FORK_BATS"

# FORK AGE FLOOR: a copy taken this second must read "just now", not empty. An
# empty age silently drops the whole Fork line from the summary.
cat > "$SED_TMP" << 'SED'
s@  (( delta < 0 )) \&\& delta=0@  (( delta < 1 )) \&\& return 0@
SED
try "fork_age_floor" "fresh copy reads as just now" "$CLI" "$FORK_BATS"

# FORK SUMMARY LINE: a fork box shows Project: <the real path>, which is where
# edits do NOT go. Without the Fork line the output is actively misleading.
cat > "$SED_TMP" << 'SED'
/^    if _box_is_fork "\$cname"; then$/,/^    fi$/d
SED
try "fork_summary_line" "summary names the copy and its age" "$CLI" "$FORK_BATS"

# FORK MARKER SURVIVES PRUNING: cleat rm <box> removes the container and KEEPS
# the copy, so the marker legitimately outlives its container. Prune it and the
# next run re-binds the LIVE tree, then --fork deletes the retained copy.
cat > "$SED_TMP" << 'SED'
s@      case "$_bf" in \*.fork) continue ;; esac@      _bcn="${_bcn%.fork}"@
SED
try "fork_marker_survives_prune" "stop-all keeps a fork marker whose container is already gone" "$CLI" "$FORK_BATS"

# FORK ROOT WARN TO STDERR: warn writes to stdout and every _fork_root caller is
# a command substitution, so without >&2 the warning TEXT becomes the fork root
# and is handed to mkdir, cp, rm -rf and mv as a relative path.
cat > "$SED_TMP" << 'SED'
s@      \*) warn "Ignoring \[fork\] dir, not an absolute path: $d" >&2 ;;@      *) warn "Ignoring [fork] dir, not an absolute path: $d" ;;@
SED
try "fork_root_warn_stderr" "relative fork dir is refused and falls back" "$CLI" "$FORK_BATS"

# FORK FLAG ON A PLAIN BOX: --fork on an existing non-fork box did nothing at
# all, so a user who forgot the flag and re-ran with it kept the live tree.
cat > "$SED_TMP" << 'SED'
s@    if \[\[ "${_FORK_REQUESTED:-false}" == true \]\] \&\& container_exists "$cname"; then@    if false; then@
SED
try "fork_flag_on_plain_box" "flag on an existing plain box refuses" "$CLI" "$FORK_BATS"

# FORK HEAL SCOPE: healing drops the container so the create path rebuilds it.
# shell and claude have no create path, so healing there destroys a live box.
cat > "$SED_TMP" << 'SED'
s@ \&\& "$can_recreate" == "recreate" \]\]; then@ ]]; then@
SED
try "fork_heal_scope" "shell never force-removes a box while healing" "$CLI" "$FORK_BATS"

# FORK EXCLUDE ROOT: `exclude = .` resolves to the fork root itself. rm refuses
# it on its own, so the arm is belt-and-braces for deletion; what it actually
# buys is a named reason instead of a raw rm error, and skipping a doomed rm.
# The mutation therefore targets the message, which is the real contribution.
cat > "$SED_TMP" << 'SED'
s@names the workspace root@names something else entirely@
SED
try "fork_exclude_root" "exclude naming the workspace root is refused" "$CLI" "$FORK_BATS"

# KIT USER-FIRST MERGE: the merged CLAUDE.md must carry the user's own global
# content, first and byte-for-byte. Drop the user-content copy (truncate
# instead): the merge test no longer sees the user's line at the top.
cat > "$SED_TMP" << 'SED'
s|cat "${HOME}/.claude/CLAUDE.md" > "$kit_dir/CLAUDE.md"|: > "$kit_dir/CLAUDE.md"|
SED
try "kits_user_content_first" "merged CLAUDE.md keeps user content first" "$CLI" "$KITS_BATS"

# KIT PRE-KIT GATE: enabling a kit on a box created before the feature (no
# mask mounts baked in) must offer a rebuild, never silently "enable" a kit
# the box would ignore. Disable the gate: the rebuild-offer test sees the
# normal confirm screen instead.
cat > "$SED_TMP" << 'SED'
s|if container_exists "$cname" \&\& ! _container_has_kit_mounts "$cname"; then|if false; then|
SED
try "kits_prekit_rebuild_gate" "offers a rebuild and declining changes nothing" "$CLI" "$KITS_BATS"

# KIT MODEL SANITIZER: a [kits] model override is written into agent YAML
# frontmatter, so it must be a bare model token; anything else falls back to
# the default. Drop the token check (accept any non-empty value): the
# injection-guard test sees the hostile value emitted verbatim.
cat > "$SED_TMP" << 'SED'
s|&& "$v" =~ ^\[A-Za-z0-9._-]+\$ ||
SED
try "kits_model_sanitizer" "injection guard" "$CLI" "$KITS_BATS"

# KIT CONFIG WRITER PRESERVATION: _write_kits_to_file must carry every line
# outside [kits] (the user's [caps] and [resources]) into the rewritten file.
# Drop the preserved-content emit (scoped to that function; the caps writer
# has an identical line): the preserve test loses git/ssh and 8g.
cat > "$SED_TMP" << 'SED'
/^_write_kits_to_file()/,/^}/ s|printf '%s' "$preserved"|:|
SED
try "kits_writer_preserves_config" "preserves .caps. and .resources" "$CLI" "$KITS_BATS"

# AUTOPILOT EXIT-CODE GATE: daemon-down detection must be the `docker info`
# exit code, never a stderr string match (the "Cannot connect" text is
# version- and locale-dependent). Swap the gate for a string match: against
# the silent up-daemon stub the string never appears, autopilot misreads "up"
# as "down", and the no-op smoke test sees "Docker isn't running".
cat > "$SED_TMP" << 'SED'
s#^  docker info > /dev/null 2>&1$#  docker info 2>/dev/null | grep -q "Cannot connect to the Docker daemon"#
SED
try "autostart_exit_code_gate" "no-op when the daemon is up" "$CLI" "$SMOKE_BATS"

# AUTOPILOT REMOTE GUARD: a tcp:// (or ssh://) endpoint must refuse to launch
# a local app. Break the tcp match: the refusal test falls through to the
# generic hint path and loses the "Remote Docker daemon unreachable" message.
cat > "$SED_TMP" << 'SED'
s|tcp://\*|zzz://*|
SED
try "autostart_remote_guard" "tcp:// DOCKER_HOST is refused" "$CLI" "$AUTOSTART_BATS"

# AUTOPILOT TIMEOUT IS AN ERROR: a daemon that never comes up must exit
# non-zero within the bounded deadline. Flip every exit in _ensure_daemon to
# success: the timeout test's assert_failure fails.
cat > "$SED_TMP" << 'SED'
/^_ensure_daemon()/,/^}$/ s|exit 1|exit 0|
SED
try "autostart_timeout_exits_nonzero" "never-up daemon exits non-zero" "$CLI" "$AUTOSTART_BATS"

# AUTOPILOT KILL SWITCH: CLEAT_NO_AUTOSTART=1 must suppress the launch.
# Disable the check: the opt-out test sees a recorded launch.
cat > "$SED_TMP" << 'SED'
s|\[\[ "${CLEAT_NO_AUTOSTART:-}" == "1" \]\]|false|
SED
try "autostart_kill_switch" "CLEAT_NO_AUTOSTART=1 prints the hint" "$CLI" "$AUTOSTART_BATS"

# INSTALL CONSENT DEFAULT-NO: installing Docker is privileged and system-
# mutating; declining (or EOF) must run nothing. Force the consent checks
# open: the declining test sees a recorded install.
cat > "$SED_TMP" << 'SED'
s|if \[\[ "$yn" != \[yY\]\* \]\]; then|if false; then|
SED
try "install_consent_default_no" "Linux declining the install runs nothing" "$CLI" "$AUTOSTART_BATS"

# INSTALL TTY GATE: CI and scripts must never be prompted to install
# software. Remove the gate: the non-TTY test loses its one-line hint and
# gets a prompt instead.
cat > "$SED_TMP" << 'SED'
s|if \[\[ "${CLEAT_NO_AUTOSTART:-}" == "1" \]\] \|\| ! _is_tty; then|if false; then|
SED
try "install_tty_gate" "non-TTY prints the per-OS command" "$CLI" "$AUTOSTART_BATS"

# INSTALL DOWNLOAD-THEN-RUN: the engine script must be downloaded to a file
# and run from it, never a blind curl-pipe-sh. Regress to the pipe: the
# consent test's recorded commands show "| sh" and lose the "-o".
cat > "$SED_TMP" << 'SED'
s#_install_run curl -fsSL https://get.docker.com -o "$script"#_install_run sh -c "curl -fsSL https://get.docker.com | sh"#
SED
try "install_download_then_run" "downloads the script to a file" "$CLI" "$AUTOSTART_BATS"

# INSTALL PRIVATE TEMP DIR (F01): the Linux install must stage the script in an
# unguessable mktemp -d dir, never a predictable /tmp/cleat-get-docker.$$ file
# fed to sudo (local root TOCTOU). Revert to the predictable path: the recorded
# curl target shows cleat-get-docker., failing the F01 assertions.
cat > "$SED_TMP" << 'SED'
s#mktemp -d "${TMPDIR:-/tmp}/cleat-docker.XXXXXX"#echo "${TMPDIR:-/tmp}/cleat-get-docker.$$"#
SED
try "install_mktemp_private_dir" "downloads the script to a file" "$CLI" "$AUTOSTART_BATS"

# AUTOPILOT unix:// FALL-THROUGH (F30): on every real machine the endpoint is a
# unix socket, so unix:// MUST fall through the remote-refusal gate to the
# launcher. Widen the case to *://* (the easy refactor slip): a unix:// endpoint
# is then misread as remote and autopilot dies on every user's machine.
cat > "$SED_TMP" << 'SED'
s|tcp://\*|*://*|
SED
try "autostart_unix_not_remote" "unix:// context endpoint is NOT treated as remote" "$CLI" "$AUTOSTART_BATS"

# KIT cmd_start REGEN (F31): the bare `cleat` (start) path must regenerate the
# kit overlay for existing boxes, or host CLAUDE.md/agents edits and kit updates
# freeze at create. Neuter the call in cmd_start only.
cat > "$SED_TMP" << 'SED'
/^cmd_start()/,/^}$/ s|_generate_kit_overlay "\$cname"|true|
SED
try "kits_cmd_start_regen" "cmd_start refreshes the kit overlay" "$CLI" "$KITS_BATS"

# KIT _kit_apply REGEN (F34): enabling on an existing mounted box must rewrite
# the overlay immediately (cleat claude/shell have no regen hook). Neuter the
# call in _kit_apply only.
cat > "$SED_TMP" << 'SED'
/^_kit_apply()/,/^}$/ s|_generate_kit_overlay "\$cname"|true|
SED
try "kits_apply_regen" "regenerates the overlay immediately" "$CLI" "$KITS_BATS"

# KIT COLLISION BY NAME (F13/F27): a user agent declaring the same frontmatter
# `name` as a kit agent must suppress the kit's (Claude dispatches by name;
# two same-named agents defeat the read-only guarantee). Break the name guard:
# the kit agent is copied anyway and two agents claim the same name.
cat > "$SED_TMP" << 'SED'
s|"\$_user_names" == \*" \$_kn "\*|false|
SED
try "kits_collision_by_name" "user agent with the SAME NAME" "$CLI" "$KITS_BATS"

# KIT WRITER STRICT-MODE (F35): _write_kits_to_file must return 0 on the
# both-default path, or the text picker dies under set -e on `done`. Append a
# trailing test that is false when both models are default, reproducing the
# original silent-death return code.
cat > "$SED_TMP" << 'SED'
/^_write_kits_to_file()/,/^}$/ s|  \} > "\$file.cleat-tmp.\$\$" && mv -f "\$file.cleat-tmp.\$\$" "\$file" |  } > "$file"; [[ "$worker" != "$_KIT_DEFAULT_MODEL" ]] |
SED
try "kits_writer_strict_return" "DEFAULT models survives" "$CLI" "$SMOKE_BATS"

# COMMANDS PASS-THROUGH DEREFERENCE: dotfile-repo users symlink their slash
# commands; a copied symlink dangles inside the box. Revert -RL to -R: the
# deref test finds a symlink in the overlay and fails.
cat > "$SED_TMP" << 'SED'
s|        cp "$_cm" "$kit_dir/commands/$_cmb" 2>/dev/null|        cp -P "$_cm" "$kit_dir/commands/$_cmb" 2>/dev/null|
SED
try "kits_commands_deref" "dereferences symlinked commands" "$CLI" "$KITS_BATS"

# OVERLAY CLEAR GUARD: -e alone skips dangling symlinks, so a deleted host
# command copied as a symlink lingers in the box forever. Drop the -L half of
# the guard: the dangling-clear test fails.
cat > "$SED_TMP" << 'SED'
s#|| -L "$_f" ##
SED
try "kits_clear_dangling" "dangling symlink in the commands overlay" "$CLI" "$KITS_BATS"

# PRE-MASK RECREATE NOTE: a box missing any of the three masks must say so.
# Drop the commands mask from the checked list: a two-mask box goes silent
# and the advisory test fails.
cat > "$SED_TMP" << 'SED'
/^_maybe_note_missing_kit_masks()/,/^}$/ s# /home/coder/.claude/commands##
SED
try "kits_mask_advisory" "missing the commands mask gets the recreate note" "$CLI" "$KITS_BATS"

# PRE-MASK NOTE WIRING: the note must actually run on the session path.
# Delete the call sites: the cmd_start wiring test fails.
cat > "$SED_TMP" << 'SED'
/^  _maybe_note_missing_kit_masks "$cname"$/d
SED
try "kits_mask_advisory_wiring" "cmd_start surfaces the recreate note" "$CLI" "$KITS_BATS"

# MASK TARGET GUARD: a broken symlink at a mask target must be refused with a
# clear remedy, not a raw mkdir trace. Neutralize the guard: the create dies
# on the raw mkdir error without the message and the test fails.
cat > "$SED_TMP" << 'SED'
/^_ensure_kit_mask_targets()/,/^}$/ s#-L "$_t" && ! -e "$_t"#-n ""#
SED
try "kits_mask_target_guard" "broken symlink at ~/.claude/commands" "$CLI" "$KITS_BATS"

# HOST MEMORY STRICT TAIL: _host_total_memory must return rc 0 on a garbled
# MemTotal (its doc contract: empty on any failure). Reintroduce the tail
# `[[ ]] &&` list: rc 1 escapes to the strict-mode callers and the garbled
# meminfo test fails.
cat > "$SED_TMP" << 'SED'
s#if \[\[ "$kb" =~ \^\[0-9\]+\$ \]\]; then#[[ "$kb" =~ ^[0-9]+$ ]] \&\& if true; then#
SED
try "vnext_host_memory_strict_tail" "garbled meminfo" "$CLI" "$RESOURCES_BATS"

# v1.2.0 ROOT HOST: sessions on a root host must ride IS_SANDBOX=1 (claude
# refuses --dangerously-skip-permissions under uid 0). Mutate the injected
# value: upstream only recognizes exactly 1, so the assert on the exact value
# must fail.
cat > "$SED_TMP" << 'SED'
s|IS_SANDBOX=1|IS_SANDBOX=0|g
SED
try "v1.2.0_root_is_sandbox_value" "root host rides IS_SANDBOX"

# v1.2.0 ROOT HOST scope: invert the uid gate so non-root hosts get the flag
# and root hosts lose it. Both halves of the regression test fail.
cat > "$SED_TMP" << 'SED'
s|"$(id -u)" == "0" ]]; then|"$(id -u)" != "0" ]]; then|
SED
try "v1.2.0_root_is_sandbox_gate" "root host rides IS_SANDBOX"

# ENGINE-AWARE POOL NOUN: a native Linux engine must never be called a VM.
# Collapse the predicate to always-VM (flip the host-local fall-through return):
# the native ready test fails.
cat > "$SED_TMP" << 'SED'
/^_docker_pool_is_vm()/,/^}$/ s|^  return 1$|  return 0|
SED
try "vnext_pool_noun_predicate" "native Linux engine reads ready" "$CLI" "$PRUNE_BATS"

# HEADROOM FLOOR: a small native host must not claim "room for many parallel
# sessions". Zero the floor so every size claims headroom: the small-host test
# (which refutes the claim at 4 GB) fails.
cat > "$SED_TMP" << 'SED'
s|vm_gb >= _PRESSURE_VM_ADVISORY_BYTES / 1073741824|vm_gb >= 0|
SED
try "vnext_pool_headroom_floor" "small native host states its size" "$CLI" "$PRUNE_BATS"

# OVERLOAD NOUN: the native overload warning names the host's RAM. Force the
# VM wording unconditionally: the native overload test fails.
cat > "$SED_TMP" << 'SED'
s#if _is_macos || $is_dd; then pool_vm=true; fi#pool_vm=true#
SED
try "vnext_pool_overload_noun" "native-engine overload names the host" "$CLI" "$PRUNE_BATS"

# ── 2026-07-12 kit scout frontmatter fix ─────────────────────────────────────
# Reintroduce the colon-space in the scout description's unquoted YAML scalar
# (the exact v1.2.0 text): the frontmatter goes invalid and Claude Code drops
# the scout agent silently. The plain-scalar regression check must fail.
cat > "$SED_TMP" << 'SED'
s|Use for all exploration. It finds|Use for all exploration: finding|
SED
try "v1.2.0_kit_scout_frontmatter_colon" "kit agent frontmatter stays parseable"

# WORKFLOW ROUTING: the fragment must route implementation stages to the
# worker agentType, not the planner. Rename the routed role: the routing
# assertion fails.
cat > "$SED_TMP" << 'SED'
s|agentType: 'worker' on implementation stages|the worker agent on implementation stages|
SED
try "vnext_kit_fragment_workflow_routing" "fragment routes workflow stages" "$CLI" "$KITS_BATS"

# BUILT-IN AGENT BAN: worker/scout must be the ONLY subagents dispatched, not
# merely preferred. Soften the ban to a preference: the ban assertion fails.
cat > "$SED_TMP" << 'SED'
s|are the only subagents you dispatch|are the preferred subagents|
SED
try "vnext_kit_fragment_builtin_ban" "bans built-in agents" "$CLI" "$KITS_BATS"

# LOUD KIT FAILURE: a missing worker/scout must be reported, never silently
# worked around. Flip the guidance to silent workaround: the loud-failure
# assertion fails.
cat > "$SED_TMP" << 'SED'
s|kit is broken instead of quietly working around it|kit is broken, so quietly work around it|
SED
try "vnext_kit_fragment_loud_failure" "loud kit failure" "$CLI" "$KITS_BATS"

# SINGLE-FILE TRIGGER: the dispatch trigger must cover a sizable change
# within one file, not just huge ones. Reword the trigger: the sizable
# single-file assertion fails.
cat > "$SED_TMP" << 'SED'
s|multi-file, or a sizable|multi-file, or a huge|
SED
try "vnext_kit_fragment_singlefile_trigger" "sizable single-file work" "$CLI" "$KITS_BATS"

# SCOUT-LOCATES CARVE-OUT: even a judgment read must have scout locate the
# code first, not skip straight to reading it. Drop the scout-locates step:
# the carve-out assertion fails.
cat > "$SED_TMP" << 'SED'
s|have scout locate it, then read the located code yourself|read it yourself|
SED
try "vnext_kit_fragment_scout_locates" "locating on scout" "$CLI" "$KITS_BATS"

# WORKER TOOL PIN: the worker agent must be pinned to Read, Edit, Write,
# Grep, Glob, Bash, not a narrower toolset. Collapse the pin to Bash only:
# the tool-pin assertion fails.
cat > "$SED_TMP" << 'SED'
s|tools: Read, Edit, Write, Grep, Glob, Bash|tools: Bash|
SED
try "vnext_kit_worker_tools_pin" "tool-pinned to executor tools" "$CLI" "$KITS_BATS"

# ── vnext plan-big-execute-small payload additions ───────────────────────────
# ERROR HANDLING: a dispatch that errors out must be re-dispatched unchanged,
# never quietly absorbed into the main loop. Flip the guidance to silent
# absorption: the errored-dispatch assertion fails.
cat > "$SED_TMP" << 'SED'
s|re-dispatch the same chunk unchanged|quietly do the chunk yourself|
SED
try "vnext_kit_fragment_error_redispatch" "errored dispatches" "$CLI" "$KITS_BATS"

# PREMISE VERIFICATION: the plan must be built from scout's verified findings,
# not from memory. Invert the guidance: the premise-verification assertion
# fails.
cat > "$SED_TMP" << 'SED'
s|Plan from scout's findings, not from memory|Plan from memory, not from scout's findings|
SED
try "vnext_kit_fragment_premise_verify" "premise verification" "$CLI" "$KITS_BATS"

# DISPATCH CRAFT: chunks should be fewer and larger, not many and small (every
# dispatch pays a fixed overhead). Reverse the sizing advice: the dispatch
# craft assertion fails.
cat > "$SED_TMP" << 'SED'
s|Prefer fewer, larger chunks|Prefer many small chunks|
SED
try "vnext_kit_fragment_dispatch_craft" "dispatch craft" "$CLI" "$KITS_BATS"

# SEQUENTIAL DISPATCH: workers are dispatched one at a time; parallel dispatch
# scrambled briefs and clobbered files in two recorded incidents (upstream
# issues #64080, #68080, #64095 unfixed). Restore the old parallel permission:
# the sequential-dispatch assertions fail.
cat > "$SED_TMP" << 'SED'
s|one at a time. Dispatch,|one at a time or in|
s|review, then dispatch the next. Never launch several workers in one|parallel when independent. Review results as they arrive and|
s|message; parallel dispatch has scrambled briefs and clobbered files.|batch further chunks freely.|
SED
try "vnext_kit_fragment_sequential_dispatch" "workers sequentially" "$CLI" "$KITS_BATS"

# WORKER REPORT STATUS: the worker's report must open with a status (done as
# dispatched, done with deviations, partial, or blocked). Reword the opening:
# the report-status assertion fails.
cat > "$SED_TMP" << 'SED'
s|Open the report with a status|Give a quick status|
SED
try "vnext_kit_worker_report_status" "report opens with a status" "$CLI" "$KITS_BATS"

# CONFIRM SCREEN SCOUT CONTRACT: the confirm screen must scope the scout's
# read-only claim to "by contract", not state it as a bare, unscoped fact.
# "read-only by contract" is a unique string in bin/cleat (verified), so
# dropping the qualifier cannot collide with any other occurrence.
cat > "$SED_TMP" << 'SED'
s|read-only by contract|read-only|
SED
try "vnext_kit_confirm_scout_contract" "read-only claim to contract" "$CLI" "$KITS_BATS"

# COLLISION POLICY NOTE: when a user agent shadows a kit agent, the warning
# must say the kit's policy still steers the user's agent (its model and
# tools apply, not the kit's). Drop that line: the policy-note assertion
# fails.
cat > "$SED_TMP" << 'SED'
/its model and tools apply/d
SED
try "vnext_kit_collision_policy_note" "kit policy steers" "$CLI" "$KITS_BATS"

# USAGE VERIFICATION NOTE: `kit show` must tell the user how to verify
# delegation actually happened (check /usage after a heavy session). Reword
# the prompt: the usage-verification assertion fails.
cat > "$SED_TMP" << 'SED'
s|Verify it is routing|Confirm it works|
SED
try "vnext_kit_show_usage_note" "usage verification note" "$CLI" "$KITS_BATS"

# ── 2026-07-13 picker keypress decode fix ────────────────────────────────────
# RIGHT ARROW DECODE: \e[C must decode as RIGHT, not ESC. Reverting the
# branch to ESC recreates the bug where a stray right-arrow closed both TUI
# pickers outright (their event loops treat ESC as cancel).
cat > "$SED_TMP" << 'SED'
s|"\[C") echo "RIGHT" ;;|"[C") echo "ESC" ;;|
SED
try "v1.2.0_keypress_right_not_esc" "never cancel the pickers"

# UNKNOWN ESCAPE SEQUENCES: any unrecognized sequence (PgUp \e[5~, PgDn,
# Home, End, F-keys) must decode as OTHER, not ESC. Mapping the wildcard
# case back to ESC recreates the same picker-closing bug for every key the
# reader doesn't otherwise know.
cat > "$SED_TMP" << 'SED'
s|\*)    echo "OTHER" ;;|*)    echo "ESC" ;;|
SED
try "v1.2.0_keypress_unknown_not_esc" "never cancel the pickers"

# REVERSE MODEL RING: _kit_prev_model must step to the PREVIOUS stock choice
# (i - 1), not the next one. Flipping the arithmetic makes LEFT behave like
# RIGHT: the reverse-cycle assertions fail.
cat > "$SED_TMP" << 'SED'
s|echo "\${_KIT_MODEL_CHOICES\[\$((i - 1))\]}"|echo "\${_KIT_MODEL_CHOICES\[\$((i + 1))\]}"|
SED
try "vnext_kit_prev_model_reverse" "reverse model cycle" "$CLI" "$KITS_BATS"

# BOX NOTES REACH THE BOX: the overlay must append the clipboard-bridge notes
# after the user's content. Silence the append: the v0.1.0 regression test
# (notes actually reach the box CLAUDE.md) must fail.
cat > "$SED_TMP" << 'SED'
s|    _box_notes_claude_md$|    :|
SED
try "v0.1.0_box_notes_compose" "box notes actually reach the box"

# BOX NOTES LOCKSTEP: the heredoc must stay byte-identical to the image's
# docker/CLAUDE.md bake. Weaken the read-back rule in the heredoc only: the
# byte-identity guard test must fail.
cat > "$SED_TMP" << 'SED'
s|Do NOT try to verify clipboard contents after copying.|Verify clipboard contents after copying.|
SED
try "vnext_box_notes_image_lockstep" "byte-identical to the image" "$CLI" "$KITS_BATS"

# PANE FIT: every kit description must fold into the picker's fixed detail
# pane. Shrink the pane below the flagship description's height: the fit
# guard must fail (a silent truncation would eat the pitch's closing lines).
cat > "$SED_TMP" << 'SED'
s|_KIT_PANE_LINES=7|_KIT_PANE_LINES=3|
SED
try "vnext_kit_pane_fits" "fits the picker detail pane" "$CLI" "$KITS_BATS"

# ── [setup] provisioning (concept/16) ────────────────────────────────────────

# SANITIZER STRIP: _sanitize_repo_str must strip control bytes (ESC/BEL/DEL)
# before repo-controlled text ever reaches echo -e. Drop the tr -d stage: the
# strip-bytes assertion must fail.
cat > "$SED_TMP" << 'SED'
/^_sanitize_repo_str()/,/^}$/{
s/ | LC_ALL=C tr -d '\\000-\\010\\013-\\037\\177\\200-\\237'//
}
SED
try "vnext_setup_sanitize_strip_ctrl" "strips raw ESC, BEL, and DEL bytes" "$CLI" "$PROVISION_BATS"

# SANITIZER BACKSLASH DOUBLING: _sanitize_repo_str must double every
# backslash so a literal `\033`-style sequence stays literal text once
# echo -e sees it. Drop the doubling stage: the doubles-backslashes
# assertion must fail.
cat > "$SED_TMP" << 'SED'
/^_sanitize_repo_str()/,/^}$/{
s@ | sed 's/\\\\/\\\\\\\\/g'@@
}
SED
try "vnext_setup_sanitize_double_backslash" "doubles backslashes" "$CLI" "$PROVISION_BATS"

# EXECUTOR RC GATE: _maybe_run_setup must only write the run-once marker and
# report success when the payload's own exit code is 0. Force the success
# branch unconditionally: a failing payload would still get the marker and
# "Setup applied", so the failure-path assertions must fail.
cat > "$SED_TMP" << 'SED'
/^_maybe_run_setup()/,/^}$/{
s/if \[\[ \$rc -eq 0 \]\]; then/if true; then/
}
SED
try "vnext_setup_exec_rc_gate" "records the exit code" "$CLI" "$PROVISION_BATS"

# RUN-ONCE MARKER: a marker matching the current hash must skip
# re-execution. Delete the equality short-circuit: the payload re-runs every
# time, so the skip assertion must fail.
cat > "$SED_TMP" << 'SED'
/^_maybe_run_setup()/,/^}$/{
/\[\[ "\$marker" == "\$hash" \]\] && return 0/d
}
SED
try "vnext_setup_marker_noop" "skips re-execution" "$CLI" "$PROVISION_BATS"

# TOCTOU CLOSE: _maybe_run_setup rebuilds and re-hashes the payload from disk
# right before running it, refusing to run when that fresh hash doesn't
# match what was approved. Neutralize the guard: a [setup] rewritten between
# approval and exec would run anyway, so the stale-skip assertion must fail.
cat > "$SED_TMP" << 'SED'
/^_maybe_run_setup()/,/^}$/{
s/\[\[ "\$hash" == "\$stored" \]\] || {/true || {/
}
SED
try "vnext_setup_toctou_guard" "rewritten after approval" "$CLI" "$PROVISION_BATS"

# CONSENT CLASS SEPARATION: _resolve_setup_trust's opt-in check must read
# CLEAT_TRUST_SETUP, never CLEAT_TRUST_PROJECT (a separate consent class,
# concept/16). Swap the variable: CLEAT_TRUST_PROJECT=1 alone would then
# also auto-trust [setup], so the "never [setup]" assertion must fail.
cat > "$SED_TMP" << 'SED'
/^_resolve_setup_trust()/,/^}$/{
s/\${CLEAT_TRUST_SETUP:-}/\${CLEAT_TRUST_PROJECT:-}/
}
SED
try "vnext_setup_optin_var_swap" "auto-trusts caps but never" "$CLI" "$PROVISION_BATS"

# ABSOLUTE PATH REJECTED: _build_setup_payload must refuse a `script` path
# that starts with `/`. Drop the check: the absolute-path assertion must
# fail.
cat > "$SED_TMP" << 'SED'
/^        case "\$path" in$/,/^        esac$/d
SED
try "vnext_setup_abs_path_reject" "absolute script path is refused" "$CLI" "$PROVISION_BATS"

# PARENT ESCAPE REJECTED: _build_setup_payload must refuse a `script` path
# containing '..'. Drop the check: the dotdot-path assertion must fail.
cat > "$SED_TMP" << 'SED'
/^        case "\/\$path\/" in$/,/^        esac$/d
SED
try "vnext_setup_dotdot_reject" "script path containing" "$CLI" "$PROVISION_BATS"

# SYMLINK REJECTED: _build_setup_payload must refuse a `script` path that is
# itself a symlink. Drop the check: the symlinked-file assertion must fail.
cat > "$SED_TMP" << 'SED'
/^        if \[\[ -L "\$full" \]\]; then$/,/^        fi$/d
SED
try "vnext_setup_symlink_reject" "symlinked script file" "$CLI" "$PROVISION_BATS"

# NO SILENT PARTIAL RUNS: the staged payload must execute under `bash -e`, so
# one failing command aborts the rest instead of silently running the
# remaining lines. Drop -e: the exec-line assertion must fail.
cat > "$SED_TMP" << 'SED'
s/runuser -u coder -- bash -e "\$runfile"/runuser -u coder -- bash "$runfile"/
SED
try "vnext_setup_exec_no_errexit" "executes the payload as coder" "$CLI" "$PROVISION_BATS"

# DEFAULT-DENY PROMPT: _setup_trust_prompt must only approve on an explicit
# y/Y; empty/EOF/no all decline. Widen the accept case to match everything:
# the empty-answer/decline assertions must fail.
cat > "$SED_TMP" << 'SED'
/^_setup_trust_prompt()/,/^}$/{
s/\[yY\]\*) return 0 ;;/*) return 0 ;;/
}
SED
try "vnext_setup_prompt_default_deny" "warns 'not approved' and records nothing" "$CLI" "$PROVISION_BATS"

# TRUST ROW SHAPE: a 3-arg _trust_record call (caps-only approval) must keep
# the legacy 3-column row byte-identical, never growing a 4th column.
# Corrupt the 3-column printf: the exact-format regression must fail.
cat > "$SED_TMP" << 'SED'
s@printf '%s\\t%s\\t%s\\n' "\$project" "\$box" "\$hash"@printf '%s\\t%s\\t%s\\t-\\n' "\$project" "\$box" "\$hash"@
SED
try "vnext_setup_trust_record_3col" "keep the exact 3-column format"

# CR GAP: _sanitize_repo_str's stripped control-byte range must include
# carriage return (0x0d), otherwise a repo-controlled [setup] payload line
# can rewind the terminal cursor and overwrite what the consent preview
# already showed. Reintroduce the old gap by splitting the \013-\037 range
# back into \013\014\016-\037 (skipping \015, octal for CR): the CR-neutralize
# regression must fail.
cat > "$SED_TMP" << 'SED'
/^_sanitize_repo_str()/,/^}$/{
s/\\013-\\037/\\013\\014\\016-\\037/
}
SED
try "v1.2.5_setup_sanitize_cr_gap" "neutralizes a carriage return" "$CLI" "$REGRESSIONS"

# INTERACTIVE CAPS-APPROVAL COL4: the interactive-accept branch of
# _resolve_project_trust must pass the existing [setup] hash through as
# _trust_record's 4th arg, so approving caps at the TTY prompt never drops a
# prior setup approval. Drop the 4th arg on that specific call (anchored on
# its own comment so the CLEAT_TRUST_PROJECT=1 opt-in branch above, which
# shares the identical call shape, is left untouched): the col4-preservation
# assertion must fail.
cat > "$SED_TMP" << 'SED'
/see the opt-in branch/,/_trust_record/{
s/_trust_record "\$project" "\$hash" "\$box" "\$(_trust_lookup_setup "\$project" "\$box")" || true/_trust_record "\$project" "\$hash" "\$box" || true/
}
SED
try "vnext_trust_interactive_col4_preserve" "interactive caps-approval" "$CLI" "$PROVISION_BATS"

# ── Box-aware trust/untrust ──────────────────────────────────────────────────

# DISAMBIGUATION: _trust_target decides box-vs-path purely by syntax (a '/'
# makes it a path), so a lone valid box name is ALWAYS that box even when a
# same-named directory exists (keeps trust/untrust symmetric over time). Widen
# the path test to match everything: a lone box name would then resolve as a
# path (box main), so the "lone valid box name is a box even when a same-named
# dir exists" assertion must fail.
cat > "$SED_TMP" << 'SED'
/^_trust_target()/,/^}$/{
s@if \[\[ "\$a1" == \*/\* \]\]; then@if [[ "\$a1" == \* ]]; then@
}
SED
try "vnext_trust_target_slash_is_path" "a lone valid box name is a box even when" "$CLI" "$PROVISION_BATS"

# CONTROL-CHAR GUARD: _trust_target must refuse a project path with an embedded
# tab/newline/CR before the tab-delimited print, mirroring _trust_record, so a
# tab can't split wrong in the caller and slip past that guard. Delete the
# guard: the "project path containing a tab is refused" assertion must fail.
cat > "$SED_TMP" << 'SED'
/^_trust_target()/,/^}$/{
/Refusing to trust a project path containing control characters/d
}
SED
try "vnext_trust_target_ctrl_char_guard" "project path containing a tab is refused" "$CLI" "$PROVISION_BATS"

# PER-BOX STALENESS MARKER: cmd_trust --list must flip a box row from green to
# yellow when its .cleat.<box> hash no longer matches what was approved. Force
# the comparison to never trip (equal hash): every row stays green, so the
# "flips green to yellow" assertion (which needs the yellow marker after an
# edit) must fail.
cat > "$SED_TMP" << 'SED'
s@if \[\[ -f "\$_cf" && -n "\$_cur" && "\$_stored" != "\$_cur" \]\]; then@if [[ -f "$_cf" \&\& -n "$_cur" \&\& "$_stored" == "$_cur" ]]; then@
SED
try "vnext_trust_list_box_staleness" "flips green to yellow when its" "$CLI" "$PROVISION_BATS"

# PER-BOX TRUST ROW: `cleat trust <box>` must record under the named box, so
# the row is byte-identical to what the box-start prompt writes. Pin the box to
# main on cmd_trust's 4-col record: the byte-identity assertion must fail.
cat > "$SED_TMP" << 'SED'
s@_trust_record "\$project" "\$hash" "\$box" "\$setup_hash" || exit 1@_trust_record "\$project" "\$hash" main "\$setup_hash" || exit 1@
SED
try "vnext_trust_box_record_box" "byte-identical row the box-start prompt" "$CLI" "$PROVISION_BATS"

# PER-BOX UNTRUST SCOPE: `cleat untrust <box>` must remove only that box's row.
# Drop the box arg so it defaults to main: untrusting a box would then clear the
# main row instead, so the "removes only that box's row" assertion must fail.
cat > "$SED_TMP" << 'SED'
s@_trust_remove "\$project" "\$box"@_trust_remove "\$project"@
SED
try "vnext_untrust_box_scope" "removes only that box" "$CLI" "$PROVISION_BATS"

# DOCKER-CONFIG GATE (concept/21): the single place Cleat deliberately blocks the
# launch. Five load-bearing behaviors, each mutation-proved.

# 1. INTERACTIVE-ONLY (the walk-away pillar). Drop the _is_interactive guard so a
#    non-interactive run would reach the read/banner: the "never blocks off a
#    terminal" test must then fail (the banner leaks into piped output).
cat > "$SED_TMP" << 'SED'
s@  _is_interactive || return 0@  :@
SED
try "vnext_docker_gate_interactive_only" "NON-interactive never blocks" "$CLI" "$DOCKER_GATE_BATS"

# 2. PENDING GUARD. Remove the "only when armed" guard so a healthy Docker (no
#    advisory armed the gate) would still print the banner: the silent-when-unarmed
#    test must fail.
cat > "$SED_TMP" << 'SED'
s@\[\[ "\${_DOCKER_GATE_PENDING:-0}" == "1" \]\] || return 0@:@
SED
try "vnext_docker_gate_pending_guard" "silent when nothing armed" "$CLI" "$DOCKER_GATE_BATS"

# 3. ESCAPE HATCH. Break the CLEAT_NO_DOCKER_GATE comparison so the opt-out no
#    longer skips the hold: the "escape hatch skips the hold" test must fail.
cat > "$SED_TMP" << 'SED'
s@"\${CLEAT_NO_DOCKER_GATE:-}" == "1"@"\${CLEAT_NO_DOCKER_GATE:-}" == "off"@
SED
try "vnext_docker_gate_escape_hatch" "skips the hold" "$CLI" "$DOCKER_GATE_BATS"

# 4. UNDERSIZED ARMS. Disarm the gate flag so an undersized VM would NOT hold the
#    launch: the "undersized VM arms the gate" test must fail.
cat > "$SED_TMP" << 'SED'
s@_DOCKER_GATE_PENDING=1@_DOCKER_GATE_PENDING=0@
SED
try "vnext_docker_gate_undersized_arms" "undersized VM in the pressure check arms" "$CLI" "$DOCKER_GATE_BATS"

# 5. SWAP ARMS. Same disarm, proved through the low-swap path in the ready-announce:
#    a default-swap VM would not hold the launch, so its arming test must fail.
cat > "$SED_TMP" << 'SED'
s@_DOCKER_GATE_PENDING=1@_DOCKER_GATE_PENDING=0@
SED
try "vnext_docker_gate_swap_arms" "low swap in the ready-announce arms" "$CLI" "$DOCKER_GATE_BATS"

# 6. INTERACTIVE PREDICATE not-always-true. Rewrite the _is_interactive definition
#    to a bare `true` (the pillar-breaking "always interactive" regression that
#    would block unattended launches): the unstubbed-predicate test must fail.
cat > "$SED_TMP" << 'SED'
s@_is_interactive() { \[\[ -t 0 && -t 1 \]\]; }@_is_interactive() { true; }@
SED
try "vnext_docker_gate_is_interactive_not_always_true" "_is_interactive is false without an interactive stdin" "$CLI" "$DOCKER_GATE_BATS"

# 7. OVERLOAD MUST NOT ARM. Inject an arm into the transient-overload branch (2a):
#    the "OVERLOAD never arms the gate" test must then fail, proving it is effective.
cat > "$SED_TMP" << 'SED'
s@_who="\${_n_boxes} session\${_s} still running"@&; _DOCKER_GATE_PENDING=1@
SED
try "vnext_docker_gate_overload_no_arm" "transient OVERLOAD notice never arms" "$CLI" "$DOCKER_GATE_BATS"

# 8. BANNER LEADING BLANK. Revert the gate's gap-aware leading blank to an
#    unconditional `echo ""`: the undersized end-to-end doubles the blank above the
#    amber banner, so the "exactly one blank" test must fail.
cat > "$SED_TMP" << 'SED'
s@\[\[ "\${_ONSTART_GAP_OPEN:-0}" == "1" \]\] || echo ""@echo ""@
SED
try "vnext_docker_gate_banner_leading_blank" "one blank line above the banner in the undersized" "$CLI" "$DOCKER_GATE_BATS"

# ─────────────────────────────────────────────────────────────────────────────
# .cleat EDITOR (cleat config: capabilities + resources). Eleven load-bearing
# behaviors of the resources writer, the value-cycle ring, the direct-mode
# --memory/--cpus flags, the text-picker resource grammar, and the generate
# project-.cleat gate. Each mutation reintroduces a specific bug the review round
# flagged and proves the guarding test catches it.
# ─────────────────────────────────────────────────────────────────────────────

# 1. RESOURCES WRITER SECTION HEADER. Drop the `[resources]` header so the writer
#    emits bare key lines: the "writes memory and cpus" test (asserts the header at
#    line 0) must fail.
cat > "$SED_TMP" << 'SED'
s@      echo "\[$_sec\]"@      echo "# nope"@
SED
try "vnext_config_resources_writer_section" "write_resources: writes memory and cpus" "$CLI" "$CONFIG_BATS"

# 2. CAPS WRITER NEWLINE GUARD. Revert the `|| [[ -n "$line" ]]` guard in
#    _write_caps_to_file so a project .cleat whose last [setup] line lacks a
#    trailing newline loses that line: the regression test must fail.
cat > "$SED_TMP" << 'SED'
/^_write_caps_to_file()/,/^}$/ s@read -r line || \[\[ -n "\$line" \]\]@read -r line@
SED
try "vnext_config_caps_writer_newline_guard" "caps writer keeps a no-trailing-newline" "$CLI" "$REGRESSIONS"

# 3. RESOURCES WRITER NEWLINE GUARD. Same guard, in _write_resources_to_file: a
#    no-trailing-newline final [setup] line must survive a resources write.
cat > "$SED_TMP" << 'SED'
/^_write_resources_to_file()/,/^}$/ s@read -r line || \[\[ -n "\$line" \]\]@read -r line@
SED
try "vnext_config_resources_writer_newline_guard" "final line with NO trailing newline survives" "$CLI" "$CONFIG_BATS"

# 4. CYCLE NEXT. Neutralize the +1 step so "next" returns the current value: the
#    "next advances through the memory ring" test (default -> 4g) must fail.
cat > "$SED_TMP" << 'SED'
s@\$(((i + 1) % m))@$(((i + 0) % m))@
SED
try "vnext_config_cycle_next" "cycle: next advances through the memory ring" "$CLI" "$CONFIG_BATS"

# 5. CYCLE CUSTOM DEDUP. Always append the custom pin so a value equal to a ring
#    stop double-appears: the "does not double-append" test must fail.
cat > "$SED_TMP" << 'SED'
s@\$_dup || ring+=("\$custom")@ring+=("$custom")@
SED
try "vnext_config_cycle_custom_dedup" "does not double-append" "$CLI" "$CONFIG_BATS"

# 6. ROW-KIND DISPATCH. Mislabel the memory row as a cap so a resource cursor would
#    index KNOWN_CAPS: the row_kind mapping test must fail.
cat > "$SED_TMP" << 'SED'
s@    echo "mem"@    echo "cap:git"@
SED
try "vnext_config_row_kind" "row_kind: caps map to" "$CLI" "$CONFIG_BATS"

# 7. DIRECT-MODE RESOURCE KEY. Route --memory into the cpus key so the memory value
#    never lands: the "config --memory: sets the global memory limit" test must fail.
cat > "$SED_TMP" << 'SED'
s@then cur_mem="\$write_val"; else cur_cpus="\$write_val"@then cur_cpus="$write_val"; else cur_cpus="$write_val"@
SED
try "vnext_config_memory_direct_write" "config --memory: sets the global memory limit" "$CLI" "$CONFIG_BATS"

# 8. --LIST RESOURCES BLOCK. Rename the Resources header so --list stops printing it:
#    the "shows the Resources block with configured values" test must fail.
cat > "$SED_TMP" << 'SED'
s@\${BOLD}Resources\${RESET}"@${BOLD}Zzz${RESET}"@
SED
try "vnext_config_list_shows_resources" "shows the Resources block with configured values" "$CLI" "$CONFIG_BATS"

# 9. TEXT-PICKER RESOURCE PARSE. Make the memory keyword a no-op on the stored value
#    (keep the confirmation): the "memory keyword with a space sets the value" test,
#    which reads the value back, must fail.
cat > "$SED_TMP" << 'SED'
s@mem="\$_v"@mem="$mem"@
SED
try "vnext_config_text_resource_parse" "memory keyword with a space sets the value" "$CLI" "$CONFIG_BATS"

# 10. GENERATE NO-OP GUARD. Break the "nothing selected" short-circuit so an empty
#     selection would still prompt/write: the no-op test must fail.
cat > "$SED_TMP" << 'SED'
s|\${#caps\[@\]} -eq 0|${#caps[@]} -eq 9|
SED
try "vnext_config_generate_noop_guard" "nothing selected is a no-op" "$CLI" "$CONFIG_BATS"

# 11. GENERATE $HOME REFUSAL. Drop $HOME from the refusal list so `cleat config` run
#     from $HOME would drop a stray ./.cleat: the "refuses to write in" test must fail.
cat > "$SED_TMP" << 'SED'
s@""|"/"|"\$HOME")@""|"/")@
SED
try "vnext_config_generate_refuse_home" "refuses to write in" "$CLI" "$CONFIG_BATS"

# 12. LOAD-RESOURCE CUSTOM PIN. Blank the second (custom-pin) field for an off-ring
#     value so a hand-set 16g is no longer reachable in the TUI cycle: the
#     _config_load_resource off-ring test (and the round-trip) must fail.
cat > "$SED_TMP" << 'SED'
s@"\$v" "\$v"@"$v" ""@
SED
try "vnext_config_load_resource_custom_pin" "off-ring value is returned as its own custom pin" "$CLI" "$CONFIG_BATS"

# 13. DRAW LINE-COUNT INVARIANT. Turn the Resources group header echo into a no-op so
#     the draw emits one fewer physical line than the tui's draw_lines constant expects
#     (a redraw desync): the "emits exactly ncaps+5 lines" test must fail.
cat > "$SED_TMP" << 'SED'
s@  echo -e "  \${DIM}Resources\${RESET}@  : "  ${DIM}Resources${RESET}@
SED
try "vnext_config_draw_line_count" "emits exactly ncaps" "$CLI" "$CONFIG_BATS"

# 14. ENV SCAFFOLD GUARD. Break the env-cap match in the editor save path so enabling
#     env no longer offers to scaffold .cleat.env: the offer test must fail.
cat > "$SED_TMP" << 'SED'
s@\*,env,\*)@*,envXX,*)@
SED
try "vnext_config_env_scaffold_offer" "enabling env offers to scaffold" "$CLI" "$CONFIG_BATS"

# WATCHER TERMINAL SAFETY. Every host-side watcher redirects its stdout+stderr
# to a per-box .watcher-log so a fork-starved watcher's "fork: Resource
# temporarily unavailable" never corrupts the Claude Code TUI. Strip the
# redirect from the clipboard watcher spawn: the watcher's stderr leaks onto the
# caller's fd 2 and the log is never created, so the regression test fails.
cat > "$SED_TMP" << 'SED'
s|_clipboard_watcher "\$_CLIP_DIR" "\$clip_cmd" >>"\$_CLIP_DIR/.watcher-log" 2>&1 &|_clipboard_watcher "$_CLIP_DIR" "$clip_cmd" \&|
SED
try "watcher_fd2_redirect" "watchers redirect fork-error stderr"

# PRUNE OFFER EXCLUDES REFERENCED IMAGES (the 1.png over-count bug). The offer
# count must skip images a container still pins (docker rmi, no -f, keeps them),
# or it promises a prune that removes nothing. Drop the dangling-image filter:
# a pinned dangling build is counted again, so the "not counted" test fails.
cat > "$SED_TMP" << 'SED'
s@_image_referenced_by_container "\$id" "\$referenced" && continue@:@
SED
try "vnext_prune_skip_referenced_dangling" "referenced by a container is not counted" "$CLI" "$PRUNE_BATS"

# Same guard, the superseded-tag loop: drop it and the "all bloat pinned" offer
# scenario counts the pinned tags, so the offer fires and the suppression test fails.
cat > "$SED_TMP" << 'SED'
s@_image_referenced_by_container "\$tag" "\$referenced" && continue@:@
SED
try "vnext_prune_skip_referenced_tag" "no prune offer when all bloat is pinned" "$CLI" "$PRUNE_BATS"

# HOST FORK-EXHAUSTION DIAGNOSTIC. When the host runs out of process slots, the
# watcher log carries "fork: Resource temporarily unavailable" and Cleat explains
# it once. Break the pattern match so a real fork error is not recognized: the
# "explains a fork error" test fails.
cat > "$SED_TMP" << 'SED'
s@grep -q "Resource temporarily unavailable"@grep -q "NEVER_MATCH_SENTINEL"@
SED
try "vnext_fork_diag_pattern" "explains a fork error logged this session" "$CLI" "$EXEC_CLAUDE_BATS"

# The diagnostic must read only THIS session's slice of the log (from the start
# offset), or a stale error from a past session re-triggers it every run. Drop
# the offset so it scans the whole log: the "ignores a PRIOR session" test fails.
cat > "$SED_TMP" << 'SED'
s@tail -c "+\$(( off + 1 ))"@tail -c "+1"@
SED
try "vnext_fork_diag_offset" "ignores a fork error from a PRIOR session" "$CLI" "$EXEC_CLAUDE_BATS"

# WATCHER LOG CAP. The per-box watcher log has no other sweeper, so an oversized
# one is truncated on session start. Raise the threshold out of reach so a big
# log is never capped: the "oversized log is truncated" test fails.
cat > "$SED_TMP" << 'SED'
s@(( sz > 1048576 ))@(( sz > 999999999999 ))@
SED
try "vnext_watcher_log_cap" "oversized log is truncated" "$CLI" "$EXEC_CLAUDE_BATS"

# WATCHER LOG CAP: BSD wc padding. macOS `wc -c` emits a space-padded count, so
# the size must be de-padded before the numeric guard or it drops to 0 (defeating
# the cap and the offset). Drop the `tr` strip: the padded count fails the regex
# and the "BSD wc padding is stripped" test fails.
cat > "$SED_TMP" << 'SED'
/^_cap_watcher_log()/,/^}$/ s@ | tr -d '\[:space:\]'@@
SED
try "vnext_watcher_log_bsd_wc" "BSD wc padding is stripped" "$CLI" "$EXEC_CLAUDE_BATS"

# FORK ADVISORY PLACEMENT. The session-end fork advisory must be emitted after the
# rc==0 reclaim (which erases the line above it). Delete the call: the advisory
# never prints, so the "emitted AFTER the session-end reclaim" test fails.
cat > "$SED_TMP" << 'SED'
/_maybe_explain_fork_exhaustion "\$_watcher_log" "\$_watcher_log_off"/d
SED
try "vnext_fork_advisory_placement" "advisory is emitted AFTER the session-end" "$CLI" "$EXEC_CLAUDE_BATS"

# PRUNE FORMAT STRINGS. The container-reference set resolves via `{{.Image}}` and
# a candidate via `{{.Id}}`; a wrong field silently reintroduces the over-count.
# Mutate the format field in each seam and the format-aware-stub tests fail.
cat > "$SED_TMP" << 'SED'
/^_container_image_ids()/,/^}$/ s@{{.Image}}@{{.Names}}@
SED
try "vnext_prune_container_image_field" "_container_image_ids resolves via" "$CLI" "$PRUNE_BATS"

cat > "$SED_TMP" << 'SED'
/^_image_id_of()/,/^}$/ s@{{.Id}}@{{.Size}}@
SED
try "vnext_prune_image_id_field" "_image_id_of resolves a ref via" "$CLI" "$PRUNE_BATS"

# SHARED SIZE PARSER. Every reclaimable number flows through h2b(). Break the GB
# multiplier and "36.34GB" no longer resolves to its byte count: the parser
# fixture fails. (The %.0f and LC_ALL=C guards are platform-specific and are
# covered by dedicated skip-guarded tests, not this both-legs mutation set.)
cat > "$SED_TMP" << 'SED'
s@m = 1073741824@m = 1@
SED
try "vnext_size_parser_gb_multiplier" "bare GB" "$CLI" "$HUMAN_SIZE_BATS"

# DISK GATE THRESHOLD. Push the hard-gate percent out of reach and a 96%-full
# disk no longer holds the launch (it falls back to the advisory), so the
# "fires the amber banner" test fails.
cat > "$SED_TMP" << 'SED'
s@_DISK_GATE_PCT=95@_DISK_GATE_PCT=200@
SED
try "vnext_disk_gate_pct" "fires the amber banner" "$CLI" "$DISK_GATE_BATS"

# DISK ADVISORY THRESHOLD. Push the advisory percent out of reach and the 88%
# band goes silent, so the "fires in the 85-94 band" test fails.
cat > "$SED_TMP" << 'SED'
s@_DISK_ADVISORY_PCT=85@_DISK_ADVISORY_PCT=200@
SED
try "vnext_disk_advisory_pct" "fires in the 85-94 band" "$CLI" "$DISK_GATE_BATS"

# DISK LOW-FREE FLOOR. Raise the advisory free floor to infinity and a high pct
# with lots of free space fires anyway: the "low-free floor suppresses" test fails.
cat > "$SED_TMP" << 'SED'
s@_DISK_ADVISORY_FREE_GB=25@_DISK_ADVISORY_FREE_GB=100000@
SED
try "vnext_disk_advisory_free_floor" "the low-free floor suppresses a high pct with lots free" "$CLI" "$DISK_GATE_BATS"

# WSL IS A THIRD DISK CATEGORY. Disable the WSL carve-out and an in-distro WSL
# engine falls into the native-Linux branch, so the "WSL in-distro is its own
# kind" test fails.
cat > "$SED_TMP" << 'SED'
s@_is_wsl && { echo wsl@false \&\& { echo wsl@
SED
try "vnext_disk_kind_wsl" "WSL in-distro is its own kind" "$CLI" "$DISK_GATE_BATS"

# PRUNE --CACHE RECLAIM. Drop the build-cache reclaim call and --cache no longer
# runs `docker builder prune`, so the "clears the shared build cache" test fails.
cat > "$SED_TMP" << 'SED'
s@_prune_build_cache "\$assume_yes"@:@
SED
try "vnext_prune_cache_call" "clears the shared build cache after a yes" "$CLI" "$PRUNE_BATS"

# PRUNE --CACHE DEFAULT-NO. Neutralize the No branch and a declined prompt prunes
# anyway (the global default-yes trap this design forbids), so the "default No
# leaves the cache untouched" test fails.
cat > "$SED_TMP" << 'SED'
s@info "Left the build cache in place."; return 0@:@
SED
try "vnext_prune_cache_default_no" "default No leaves the cache untouched" "$CLI" "$PRUNE_BATS"

# NUKE BUILD CACHE. Remove nuke's build-cache sweep and the "build cache still
# cleared" test fails (the narrowed dangling-image loop stays, but the shared
# cache is no longer reclaimed).
cat > "$SED_TMP" << 'SED'
s@docker builder prune -f > /dev/null 2>&1 || true@:@
SED
try "vnext_nuke_build_cache" "build cache still cleared" "$CLI" "$NUKE_BATS"

# STORAGE IMAGE DEDUP. Stop accumulating the seen-id set and a multi-tagged image
# is counted per tag, so the "counts cleat images deduped by id" test fails.
cat > "$SED_TMP" << 'SED'
s@seen="\$seen\$id "@:@
SED
try "vnext_storage_dedup" "counts cleat images deduped by id" "$CLI" "$STORAGE_BATS"

# STORAGE FILL PARSE. The real _storage_fill awk (used=$3 total=$2 pct=$5) is seam-
# overridden in most tests; the real-seam test pins it. Swap the used/total fields
# and the "real seam parses" test fails.
cat > "$SED_TMP" << 'SED'
s@print \$3" "\$2" "p@print \$2" "\$3" "p@
SED
try "vnext_storage_fill_fields" "storage fill: real seam parses" "$CLI" "$STORAGE_BATS"

# ENOSPC BACKSTOP. Break the out-of-space match and a full-store bring-up failure
# gets no friendly guidance: the "explains a full-store bring-up failure" test fails.
cat > "$SED_TMP" << 'SED'
s@no space left|ENOSPC@NEVER_MATCH_SENTINEL@
SED
try "vnext_enospc_backstop" "explains a full-store bring-up failure" "$CLI" "$DISK_GATE_BATS"

# DISK READ AVAIL FIELD. _read_container_disk_use must emit avail ($4), not used
# ($3), or the free-GB gate math is wrong. The "parses Use% and avail" test fails.
cat > "$SED_TMP" << 'SED'
s@print p" "\$4@print p" "\$3@
SED
try "vnext_disk_read_avail_field" "parses Use% and avail from the root row" "$CLI" "$DISK_GATE_BATS"

# DISK GATE FREE FLOOR. Raise the gate free floor out of reach and a 96%-full disk
# with 20 GB free (safe) holds the launch: the "advisory-only, not a hold" test fails.
cat > "$SED_TMP" << 'SED'
s@_DISK_GATE_FREE_GB=10@_DISK_GATE_FREE_GB=100000@
SED
try "vnext_disk_gate_free_floor" "96% with 20 GB free is advisory-only, not a hold" "$CLI" "$DISK_GATE_BATS"

# WSL DISK KIND ORDER. WSL must be classified BEFORE Docker Desktop (its store is a
# vhdx, not a Desktop slider). Drop the return so WSL+DD falls through to desktop:
# the "WSL wins even under Docker Desktop" test fails.
cat > "$SED_TMP" << 'SED'
s@_is_wsl && { echo wsl; return 0; }@_is_wsl \&\& { echo wsl; }@
SED
try "vnext_disk_kind_wsl_order" "WSL wins even under Docker Desktop" "$CLI" "$DISK_GATE_BATS"

# WSL MEMORY-GATE DOWNGRADE. WSL2 memory is elastic, so the config gate must NOT
# hold there. Delete the downgrade and the WSL launch holds: the "WSL2 downgrades
# the hold" test fails.
cat > "$SED_TMP" << 'SED'
/_is_wsl && return 0/d
SED
try "vnext_wsl_gate_downgrade" "WSL2 downgrades the hold" "$CLI" "$DOCKER_GATE_BATS"

# WSL VM-FIX COPY. On WSL the memory fix is .wslconfig, not the Settings slider.
# Disable the WSL branch (scoped to the function) and it prints the wrong slider:
# the "wslconfig, not" test fails.
cat > "$SED_TMP" << 'SED'
/^_print_docker_vm_fix()/,/^}$/ s@if _is_wsl; then@if false; then@
SED
try "vnext_wsl_vm_fix_copy" "wslconfig, not" "$CLI" "$DOCKER_GATE_BATS"

# PRUNE --CACHE 0B. A 0B reclaim must report "No reclaimable build cache", not a
# "Reclaimed 0B" success. Drop the 0B guard and the "reports no reclaimable cache"
# test fails.
cat > "$SED_TMP" << 'SED'
s@ && "\$reclaimed" != "0B"@@
SED
try "vnext_prune_cache_zero" "0B reclaimed reports no reclaimable cache" "$CLI" "$PRUNE_BATS"

# STORAGE CLOSING-LEVER INDENT. cmd_storage passes a 2-space indent so the lever
# lines up with the prose line above it. Drop the argument (back to the 4-space
# notice default) and the "lines up with the prose above it" test must fail.
cat > "$SED_TMP" << 'SED'
s@_disk_lever_short "\$kind" "  "@_disk_lever_short "$kind"@
SED
try "vnext_storage_lever_indent" "lines up with the prose above it" "$CLI" "$STORAGE_BATS"

# LEVER INDENT DEFAULT. The shared lever must still default to the 4-space notice
# indent for the advisory/gate/ENOSPC callers. Force the default to 2 spaces and
# the "keeps its 4-space indent" test must fail.
cat > "$SED_TMP" << 'SED'
s@local i="\${2:-    }"@local i="${2:-  }"@
SED
try "vnext_lever_indent_default" "keeps its 4-space indent" "$CLI" "$STORAGE_BATS"

# CPU RING FROM THE DAEMON. The picker must never offer more cores than the
# daemon reports. Ignore the real core count and fall back to the static ring:
# the "never offers more cores than the machine has" test must fail.
cat > "$SED_TMP" << 'SED'
s@  ncpu="\$(_daemon_ncpu)"@  ncpu=""@
SED
try "vnext_config_cpu_ring_detect" "never offers more cores than the machine has" "$CLI" "$CONFIG_BATS"

# CPU RING ENDS ON THE CORE COUNT. Drop the exact-core-count final stop so a
# 24-core machine tops out at 16: the "built from the daemon's real core count"
# test must fail.
cat > "$SED_TMP" << 'SED'
s@  printf '%s %s' "\$out" "\$ncpu"@  printf '%s' "$out"@
SED
try "vnext_config_cpu_ring_last_stop" "built from the daemon" "$CLI" "$CONFIG_BATS"

# MEMORY RING CLIMBS TO THE VM. Force global scope down the project path so the
# ring stops at 8g on a 24 GB VM (the old fixed ceiling): the "climbs in real
# stops to the VM size" test must fail.
cat > "$SED_TMP" << 'SED'
s@  if \[\[ "\$scope" == "project" \]\]; then@  if [[ "$scope" != "" ]]; then@
SED
try "vnext_config_mem_ring_vm" "climbs in real stops to the VM size" "$CLI" "$CONFIG_BATS"

# PROJECT RING RESPECTS THE RUNTIME CLAMP. Let project scope climb like global.
# The picker would then offer a value resolve_box_memory silently cuts: the
# "project scope stops at the runtime clamp" test must fail.
cat > "$SED_TMP" << 'SED'
s@  if \[\[ "\$scope" == "project" \]\]; then@  if [[ "$scope" == "nope" ]]; then@
SED
try "vnext_config_mem_ring_project_cap" "project scope stops at the runtime clamp" "$CLI" "$CONFIG_BATS"

# MEMORY WARNING TIERS. Collapse the whole-VM tier into the milder half-VM one so
# a ceiling equal to the entire VM no longer warns: the "top tier warns at the
# whole VM" test must fail.
cat > "$SED_TMP" << 'SED'
s@&& (( gb >= vm_gb )); then@\&\& (( gb >= vm_gb * 99 )); then@
SED
try "vnext_config_mem_note_top_tier" "top tier warns at the whole VM" "$CLI" "$CONFIG_BATS"

# MEMORY NOTE IS TWO LINES ALWAYS. Drop the reserved padding so a value below the
# first tier emits nothing and the picker's redraw math desyncs: the "always
# exactly two lines" test must fail.
cat > "$SED_TMP" << 'SED'
s@case "\$v" in ""|default) printf '\\n\\n'; return 0 ;; esac@case "$v" in ""|default) return 0 ;; esac@
SED
try "vnext_config_mem_note_two_lines" "always exactly two lines" "$CLI" "$CONFIG_BATS"

# WHOLE-VM TIER VS THE 8 GB FLOOR. The whole-VM note must be tested BEFORE the
# project-cap floor, or an 8 GB Docker VM (the Desktop default) makes 8g the
# whole VM with a silent picker and a loud save. Put the floor back in front and
# the "whole-VM tier fires even at the project cap" test must fail.
cat > "$SED_TMP" << 'SED'
s@  if \[\[ "\$vm_gb" =~ \^\[0-9\]+\$ \]\] && (( vm_gb >= 1 )) && (( gb >= vm_gb )); then@  if [[ "$vm_gb" =~ ^[0-9]+$ ]] \&\& (( vm_gb >= 1 )) \&\& (( gb >= vm_gb )) \&\& (( gb > _PROJECT_MEM_CAP_GB )); then@
SED
try "vnext_config_mem_note_whole_vm_floor" "whole-VM tier fires even at the project cap" "$CLI" "$CONFIG_BATS"

# TEXT-MODE VM SIZE. The non-TTY picker must thread the VM size into the save
# path. Drop it and a piped whole-VM ceiling saves in silence: the "whole-VM
# ceiling still prints the warning off a terminal" test must fail.
cat > "$SED_TMP" << 'SED'
s@  vm_gb="\$(_config_vm_gb)"@  vm_gb=""@
SED
try "vnext_config_text_vm_gb" "whole-VM ceiling still prints the warning off a terminal" "$CLI" "$CONFIG_BATS"

# ─────────────────────────────────────────────────────────────────────────────
# 2026-07-31 hardening pass
# ─────────────────────────────────────────────────────────────────────────────

# FORK PRUNE DAEMON GATE: container_exists is a false negative against a
# stopped daemon, so without this gate prune reads every live box as an orphan
# and deletes every workspace copy on the machine. The worst defect the fork
# feature has had. Remove the gate and the refusal test must fail.
cat > "$SED_TMP" << 'SED'
s@      if ! _daemon_up; then@      if false; then@
SED
try "fork_prune_daemon_gate" "prune refuses to delete anything when the daemon" "$CLI" "$FORK_BATS"

# FORK PHYSICAL CONTAINMENT: the textual "$root"/?* test passes for a path whose
# '..' components resolve anywhere on the host. Disable the physical resolver
# and `cleat fork rm` deletes outside the fork root again.
cat > "$SED_TMP" << 'SED'
s@^_fork_path_under_root() {@_fork_path_under_root() { return 0;@
SED
try "fork_physical_containment" "tree delete refuses a path that only textually" "$CLI" "$FORK_BATS"

# FORK COPY PHYSICAL CONTAINMENT: same guard on the write side, which rm -rf's
# its destination before moving the staged copy into place.
cat > "$SED_TMP" << 'SED'
s@  if ! _fork_path_under_root "$dst"; then@  if false; then@
SED
try "fork_copy_physical_containment" "tree copy refuses a destination that only" "$CLI" "$FORK_BATS"

# FORK VERB BOX VALIDATION: path/rm/refresh must route the positional through
# _set_box like every other box-aware verb. Read it raw and an unvalidated name
# flows into container_name_for, _fork_dir and then rm -rf.
cat > "$SED_TMP" << 'SED'
/^      # Routed through _set_box, exactly like start|run above/,/^      _set_box "\$@"$/{
  /^      _set_box "\$@"$/d
}
SED
try "fork_verb_box_validation" "rm refuses a box name that walks out of the fork" "$CLI" "$FORK_BATS"

# FORK SIZE PIPEFAIL: du prints a valid total AND exits non-zero when it cannot
# descend. Move the `|| true` back outside the pipeline and one unreadable
# directory makes a real copy report 0 KB under the CLI's pipefail.
cat > "$SED_TMP" << 'SED'
s@  out="$( { du -sk "$d" 2>/dev/null || true; } | tail -1 )" || out=""@  out="$(du -sk "$d" 2>/dev/null | tail -1)" || out=""@
SED
try "fork_size_pipefail" "unreadable subdirectory does not make a copy report" "$CLI" "$FORK_BATS"

# FORK MARKER DEAD END: `cleat fork rm` must clear a marker whose copy is gone.
# Without it both documented exits are closed and the box is unstartable.
cat > "$SED_TMP" << 'SED'
s@        if \[\[ "$sub" == "rm" \]\] && _box_is_fork "$cname"; then@        if false; then@
SED
try "fork_rm_clears_stale_marker" "rm drops a fork marker whose copy is already" "$CLI" "$FORK_BATS"

# FORK INTERRUPTED COPY: the staging tree is a dotfile, so nothing listed or
# reclaimed it. Skip the sweep and the leak returns.
cat > "$SED_TMP" << 'SED'
s@        kill -0 "$_pid" 2>/dev/null && continue@        continue@
SED
try "fork_partial_copy_sweep" "prune reclaims an interrupted copy" "$CLI" "$FORK_BATS"

# SESSION KEY FULL ENCODING: Claude Code encodes every non-alphanumeric as a
# dash (measured against 2.1.220). Narrow it back to / and . and every
# snake_case project silently loses its sessions under the docker cap.
cat > "$SED_TMP" << 'SED'
s@LC_ALL=C sed 's/\[^A-Za-z0-9\]/-/g'@LC_ALL=C sed 's|[/.]|-|g'@
SED
try "session_key_all_nonalnum" "session key replaces EVERY non-alphanumeric" "$CLI" "$FORK_BATS"

# CONFIG WRITER HEADER PARITY: every reader trims the header before matching.
# Match it untrimmed in the writer and an indented section is duplicated rather
# than replaced, leaving a disabled capability active.
cat > "$SED_TMP" << 'SED'
/^_write_caps_to_file()/,/^}$/{
  s@      if \[\[ "$_h" == "\[$_sec\]" \]\]; then@      if [[ "$line" == "[$_sec]" ]]; then@
}
SED
try "caps_writer_header_trim" "an indented .caps. header is replaced" "$CLI" "$CONFIG_BATS"

cat > "$SED_TMP" << 'SED'
/^_write_resources_to_file()/,/^}$/{
  s@      if \[\[ "$_h" == "\[$_sec\]" \]\]; then@      if [[ "$line" == "[$_sec]" ]]; then@
}
SED
try "resources_writer_header_trim" "an indented .resources. header is replaced" "$CLI" "$CONFIG_BATS"

cat > "$SED_TMP" << 'SED'
s@      if \[\[ "$_h" == "\[kits\]" \]\]; then@      if [[ "$line" == "[kits]" ]]; then@
SED
try "kits_writer_header_trim" "an indented .kits. header is replaced" "$CLI" "$KITS_BATS"

# CONFIG READER READABILITY: an unreadable .cleat reached the redirect and
# killed every command in the project with a raw bash error.
cat > "$SED_TMP" << 'SED'
s@^  \[\[ -r "$file" \]\] || return 0$@  [[ -f "$file" ]] || return 0@
SED
try "config_reader_unreadable" "an unreadable file yields nothing instead of crashing the CLI" "$CLI" "$CONFIG_BATS"

# ENV NAME VALIDATION: a bare --env NAME is expanded with ${!NAME}, a hard bash
# error on a non-identifier, and it fired only after the image was built.
cat > "$SED_TMP" << 'SED'
s@        if \[\[ "$2" != \*=\* \]\] && ! \[\[ "$2" =~ \^\[A-Za-z_\]\[A-Za-z0-9_\]\*\$ \]\]; then@        if false; then@
SED
try "env_bare_key_validation" "invalid variable name is refused up front" "$CLI" "$REPO_ROOT/test/unit/argument_parsing.bats"

# FORK SESSION PREFLIGHTS: `cleat fork start|run` is documented as the same
# command as `cleat start <box> --fork`, so it must get the same preflights.
cat > "$SED_TMP" << 'SED'
s#        start|run) _do_preflight=1; _preflight_args=("\${@:2}") ;;#        start|run) : ;;#
SED
try "fork_verb_session_preflight" "fork run reaches the session preflights" "$CLI" "$FORK_BATS"


# NUKE KEEPS FORK MARKERS: nuke wipes the boxes dir, which holds the .fork
# markers, but deliberately keeps the workspace copies. Drop the re-mark and a
# surviving copy comes back unmarked, so the next --fork rm -rf's it.
cat > "$SED_TMP" << 'SED'
s@      _fork_mark "$_nc"@      :@
SED
try "nuke_keeps_fork_markers" "fork marker whose copy survives is kept" "$CLI" "$REPO_ROOT/test/unit/nuke.bats"

# FORK ROOT OWNERSHIP: the fork root is user-settable, so only cleat-named
# directories are workspace copies. Drop the filter and prune deletes anything
# one level under a hand-set [fork] dir.
cat > "$SED_TMP" << 'SED'
s@      cleat-?\*) : ;;@      *) : ;;@
SED
try "fork_root_ownership_filter" "prune ignores a directory that is not a cleat" "$CLI" "$FORK_BATS"

# ── 2026-07-31 hardening pass, batch 2 ──────────────────────────────────────

# HOOK WINDOW BOUND: the spool read must be bounded to the size already
# sampled, or bytes written during the read are replayed and their hook runs a
# SECOND time (a deploy, a commit, a notification: a real side effect).
cat > "$SED_TMP" << 'SED'
s@  \[\[ "$size" -gt "$offset" \]\] || return 1@  [[ "$size" -gt "$offset" ]] || return 1; size=$(( size + 999 ))@
SED
try "hook_window_bounded" "read window is bounded to the size already sampled" "$CLI" "$HOOKS_BATS"

# HOOK WINDOW REWIND: a truncated spool must rewind, or the bridge silently
# stops running the user's hooks for the rest of the session.
cat > "$SED_TMP" << 'SED'
s@  \[\[ "$size" -lt "$offset" \]\] && offset=0@  :@
SED
try "hook_window_rewind" "truncated spool rewinds instead of killing" "$CLI" "$HOOKS_BATS"

# HOOK CONCURRENCY BOUND: the spool line count is chosen by the caged side, so
# an unbounded subshell per line turns it into a host process count.
cat > "$SED_TMP" << 'SED'
s@^_HOOK_BRIDGE_MAX_CONCURRENT=8$@_HOOK_BRIDGE_MAX_CONCURRENT=0@
SED
try "hook_concurrency_bound" "concurrency is bounded so a spool flood" "$CLI" "$HOOKS_BATS"

# TRUST HASH BEFORE PROMPT: hashing after the answer records a .cleat the user
# never saw, so an agent can rewrite it while the prompt is on screen.
cat > "$SED_TMP" << 'SED'
/# Hash BEFORE the prompt, from the same read that produced the caps we are/,/^    hash="\$(_hash_cleat_caps "\$caps_file" "\$box")"$/{
  /^    hash="\$(_hash_cleat_caps "\$caps_file" "\$box")"$/d
}
SED
try "trust_hash_before_prompt" "recorded hash is the one the user was shown" "$CLI" "$TRUST_BATS"

# KIT COMMANDS SYMLINK: -L dereferences at every depth, materializing real host
# secret bytes inside the cage.
cat > "$SED_TMP" << 'SED'
s@        cp -R "$_cm/." "$kit_dir/commands/$_cmb/" 2>/dev/null || true@        cp -RL "$_cm/." "$kit_dir/commands/$_cmb/" 2>/dev/null || true@
SED
try "kit_commands_no_deref" "nested in a command dir is copied as a link" "$CLI" "$KITS_BATS"

# DESKTOP SETTINGS ENGINE GATE: the settings path survives uninstalling Docker
# Desktop, so without this a dead config describes the live engine.
cat > "$SED_TMP" << 'SED'
s@  _is_docker_desktop || return 0@  :@
SED
try "desktop_settings_engine_gate" "leftover Desktop settings file is ignored" "$CLI" "$REPO_ROOT/test/unit/docker_gate.bats"

# ATOMIC CONFIG WRITE: truncate-then-write destroys the preserved [setup] block
# if anything fails part way.
cat > "$SED_TMP" << 'SED'
s@  } > "$file.cleat-tmp.$$" && mv -f "$file.cleat-tmp.$$" "$file" || {@  } > "$file" || {@
SED
try "config_write_atomic" "replaced by rename, never truncated in place" "$CLI" "$CONFIG_BATS"

# SHELL ATTACH MARKER: without it the idle sweep stops a box the user is
# sitting in, because a shell runs bash and so does a detached box.
cat > "$SED_TMP" << 'SED'
s@    _box_has_attached_session "$name" && continue@    :@
SED
try "sweep_respects_attached_shell" "attached box survives a real sweep pass" "$CLI" "$REPO_ROOT/test/unit/idle_sweep.bats"

# STALE ATTACH MARKER: a marker from a killed session must not pin the box.
cat > "$SED_TMP" << 'SED'
s@      rm -f "$m" 2>/dev/null || true@      :@
SED
try "sweep_stale_marker_cleaned" "marker from a dead session does not pin" "$CLI" "$REPO_ROOT/test/unit/idle_sweep.bats"

# PERSISTED CLAUDE.JSON HEAL: the host file had a corruption guard, the project
# copy had none, so a truncated one broke the box on every later start.
cat > "$SED_TMP" << 'SED'
s@    if \[\[ -f "$proj_src" && -s "$proj_src" \]\] && ! _looks_like_json_object "$proj_src"; then@    if false; then@
SED
try "claude_json_persisted_heal" "corrupt PERSISTED project copy is backed up" "$CLI" "$REPO_ROOT/test/unit/claude_json.bats"

# TRUST PATH ESCAPES: awk -v processes escapes in the VALUE, so a path with a
# backslash never matched its own trust record.
cat > "$SED_TMP" << 'SED'
s@  CLEAT_AWK_P="$project" CLEAT_AWK_B="$box" awk -F'\\t' '@  awk -F'\\t' -v p="$project" -v b="$box" '@
SED
try "trust_path_backslash" "path containing a backslash escape still matches" "$CLI" "$TRUST_BATS"

# SETUP SCRIPT TAB: a tab after the directive fell through and was executed as
# a shell command instead of being read as a script.
cat > "$SED_TMP" << 'SED'
s@      "script "\*|"script	"\*)@      "script "*)@
SED
try "setup_script_tab_directive" "tab after the script directive is still a script" "$CLI" "$REPO_ROOT/test/unit/provision.bats"

# MEMORY FLOOR: dockerd refuses under 6 MB, so a forgotten suffix aborted
# docker run instead of failing validation.
cat > "$SED_TMP" << 'SED'
s@  (( _b >= 6291456 ))@  true@
SED
try "memory_dockerd_floor" "below dockerd.s 6 MB floor is rejected" "$CLI" "$REPO_ROOT/test/unit/resources.bats"

# NUKE STDIN: read with no fallback dies under set -e at EOF.
cat > "$SED_TMP" << 'SED'
s@  read -rp "  Type 'nuke' to confirm: " confirm || confirm=""@  read -rp "  Type '"'"'nuke'"'"' to confirm: " confirm@
SED
try "nuke_stdin_fallback" "closed stdin aborts instead of dying" "$CLI" "$REPO_ROOT/test/unit/nuke.bats"

# STATUS BOX POSITIONAL: forwarded into cmd_status's PROJECT slot, so
# `cleat status feat-a` reported a phantom project.
cat > "$SED_TMP" << 'SED'
s@  if \[\[ -n "$_arg" && ! -d "$_arg" \]\]; then@  if false; then@
SED
try "status_box_positional" "box positional is a BOX, not a phantom project" "$CLI" "$REPO_ROOT/test/unit/docker_commands.bats"

# CONFIG BOM: an editor's BOM voided the first section in silence.
cat > "$SED_TMP" << 'SED'
s@    line="${line#$'\\xef\\xbb\\xbf'}"   # UTF-8 BOM, silently voided the first section@    :@
SED
try "config_bom_strip" "UTF-8 BOM does not void the first section" "$CLI" "$CONFIG_BATS"

# BOX-AWARE FORK EXCLUDES: a named box's caps came from .cleat.<box> while its
# [fork] excludes were read from .cleat.
cat > "$SED_TMP" << 'SED'
s@"$(_scoped_section "$_exfile" "$box" fork)" exclude@fork exclude@
SED
try "fork_excludes_box_aware" "excludes come from its own" "$CLI" "$FORK_BATS"

# WRITER BOM HYGIENE: the readers strip a BOM, the writers did not, so a BOM'd
# .cleat still duplicated its section on write and left a "disabled" cap active.
cat > "$SED_TMP" << 'SED'
s@      line="${line#$'\\xef\\xbb\\xbf'}"   # UTF-8 BOM, same hygiene as the readers@      :@
SED
try "writer_bom_strip" "BOM.d file is replaced, not duplicated" "$CLI" "$CONFIG_BATS"

# ── per-box sections ────────────────────────────────────────────────────────
PBS_BATS="$REPO_ROOT/test/unit/per_box_sections.bats"

# DECLARED REPLACES: fall back to the bare section when the box declares one and
# a locked-down box silently runs with the project's full capability set.
cat > "$SED_TMP" << 'SED'
s@  if \[\[ -n "$box" \]\] && _cleat_section_present "$file" "box.${box}.${kind}"; then@  if false; then@
SED
try "pbs_declared_replaces" "declared caps section REPLACES" "$CLI" "$PBS_BATS"

# EMPTY IS A VALUE: treat a declared-but-empty section as absent and the
# lockdown box inherits everything instead of getting nothing.
cat > "$SED_TMP" << 'SED'
s@^    \[\[ "$line" == "$want" \]\] && return 0$@    [[ "$line" == "$want" ]] \&\& [[ "$(sed -n "/^\\[/,\$p" "$file" | sed -n 2p)" != "" ]] \&\& return 0@
SED
try "pbs_empty_is_a_value" "EMPTY caps section means zero caps" "$CLI" "$PBS_BATS"

# RESOURCES ARE PER KEY: make the resource read section-level and declaring
# memory silently un-declares the inherited cpus.
cat > "$SED_TMP" << 'SED'
s@    \[\[ -n "$_v" \]\] && { printf '%s\\n' "$_v"; return 0; }@    printf '%s\\n' "$_v"; return 0;@
SED
try "pbs_resources_per_key" "resources resolve per KEY" "$CLI" "$PBS_BATS"

# HASH IS PER BOX: default the box and every box hashes as main, so editing one
# box re-prompts all of them and cmd_trust reports a permanent false change.
cat > "$SED_TMP" << 'SED'
s@  local path="$1" box="${2?_hash_cleat_caps needs a box}"@  local path="$1" box="${2:-main}"@
SED
try "pbs_hash_requires_box" "caps hash refuses to guess a box" "$CLI" "$PBS_BATS"

# MATERIALIZE: without it, enabling one cap on an inheriting box leaves the box
# with ONLY that cap, the same silent strip the per-box files caused.
cat > "$SED_TMP" << 'SED'
s@    done < <(_read_caps_from_file "$config_file" "$_box_scope")@    done < <(_read_caps_from_file "$config_file" "")@
SED
try "pbs_editor_materializes" "adds to ITS set, not the project" "$CLI" "$PBS_BATS"

# NEVER VANISH: an omitted section means absent means inherit, so an emptied
# box section would escalate a locked box to the project's full cap set.
cat > "$SED_TMP" << 'SED'
s@    elif \[\[ "$_sec" != "caps" && "${_WRITE_EMPTY_SECTION:-0}" == "1" \]\]; then@    elif false; then@
SED
try "pbs_empty_section_kept" "keeps the header, never removes it" "$CLI" "$PBS_BATS"

# DELETE ON EQUAL: without it a no-op edit silently pins the box to today's
# project caps forever and no verb undoes it.
cat > "$SED_TMP" << 'SED'
s@  if \[\[ "$sec" == box.\* && -n "$_mine" && "$_mine" == "$_inherited" \]\]; then@  if false; then@
SED
try "pbs_delete_on_equal" "restores inheritance" "$CLI" "$PBS_BATS"

# EDITOR TARGETS .cleat: writing a per-box FILE is what stripped the box.
cat > "$SED_TMP" << 'SED'
s@    config_file="${project}/.cleat"\n    _warn_legacy_box_file@    config_file="${project}/.cleat.$box"\n    _warn_legacy_box_file@
SED
cat > "$SED_TMP" << 'SED'
/^    _warn_legacy_box_file "\$project" "\$box"$/{x;s@^@@;x;}
s@^    config_file="\${project}/.cleat"$@    config_file="${project}/.cleat.${box:-main}"@
SED
try "pbs_editor_one_file" "writes a section, never a new file" "$CLI" "$PBS_BATS"

# LEGACY FILE ANNOUNCED: a leftover .cleat.<box> changes a box's capabilities in
# either direction, so it must never be silent.
cat > "$SED_TMP" << 'SED'
s@  warn "${BOLD}.cleat.${box}${RESET} is no longer read@  true "@
SED
try "pbs_legacy_announced" "leftover .cleat..box. is announced" "$CLI" "$PBS_BATS"

# WARNER KNOWS THE KINDS: accept any box.*.* and a typo'd kind is silently
# accepted forever, which is a box running the wrong configuration.
cat > "$SED_TMP" << 'SED'
s@              caps|resources|setup|fork)@              caps|resources|setup|fork|capss)@
SED
try "pbs_warner_kind" "typo.d box name or kind still warns" "$CLI" "$PBS_BATS"

# GLOBAL REFUSAL: box names are per project, so a global [box.x.*] would apply
# to every project with a box of that name.
cat > "$SED_TMP" << 'SED'
s@          box.\*)@          boxZZ.*)@
SED
try "pbs_warner_global" "refused in the GLOBAL config" "$CLI" "$PBS_BATS"

# PICKER SCOPING: the direct flags scoped and the interactive picker did not, so
# a box edit made through the TUI granted the capability to EVERY box.
cat > "$SED_TMP" << 'SED'
s#  _config_write_caps_scoped "$config_file" "$_esec_caps" "$_ebox" #  _write_caps_to_file "$config_file" #
SED
try "pbs_picker_scoped" "picker scopes a box.s save" "$CLI" "$PBS_BATS"

# PICKER RESOURCES: same, for the resources half.
cat > "$SED_TMP" << 'SED'
s@  _WRITE_RES_SECTION="$_esec_res" _write_resources_to_file "$config_file" "$mem_w" "$cpu_w"@  _write_resources_to_file "$config_file" "$mem_w" "$cpu_w"@
SED
try "pbs_picker_resources_scoped" "picker scopes resources too" "$CLI" "$PBS_BATS"

# EDITOR WRITES WHERE READERS READ: `cleat config main` wrote [caps] while the
# readers honoured [box.main.caps], a silent no-op that also granted it widely.
cat > "$SED_TMP" << 'SED'
s@  if _cleat_section_present "$file" "box.${box}.${kind}"; then@  if false; then@
SED
try "pbs_editor_section_rule" "main-box edit writes where main actually reads" "$CLI" "$PBS_BATS"

# LOCKDOWN SURVIVES: delete-on-equal must not fire on an EMPTY set, or the box
# inherits whatever the project gains later.
cat > "$SED_TMP" << 'SED'
s@  if \[\[ "$sec" == box.\* && -n "$_mine" && "$_mine" == "$_inherited" \]\]; then@  if [[ "$sec" == box.* \&\& "$_mine" == "$_inherited" ]]; then@
SED
try "pbs_lockdown_survives" "declared-empty lockdown survives an edit" "$CLI" "$PBS_BATS"

# ENV SIDECAR: the legacy warning told the user to move their SECRETS file into
# the committed .cleat.
cat > "$SED_TMP" << 'SED'
s@  \[\[ "$box" != "env" \]\] || return 0@  :@
SED
try "pbs_legacy_skips_env" "env sidecar is never mistaken" "$CLI" "$PBS_BATS"

# LEGACY WARNED ON EVERY VERB: warning only from cmd_config meant a session verb
# ran the box with different caps than the leftover file declared, silently.
cat > "$SED_TMP" << 'SED'
s@  \[\[ -n "$project" \]\] && _warn_legacy_box_file "$project" "$box"@  :@
SED
try "pbs_legacy_on_session_verb" "announced on a session verb" "$CLI" "$PBS_BATS"

# NO-OP PROJECT EDIT: delete-on-equal is only meaningful for a per-box section.
# On the bare [caps] the "inherited" set IS the set being written, so it fired
# on every no-op project edit and wiped the section outright.
cat > "$SED_TMP" << 'SED'
s@  if \[\[ "$sec" == box.\* && -n "$_mine" && "$_mine" == "$_inherited" \]\]; then@  if [[ -n "$_mine" \&\& "$_mine" == "$_inherited" ]]; then@
SED
try "pbs_noop_keeps_project_caps" "no-op edit of box main never deletes" "$CLI" "$PBS_BATS"

# PICKER LOADS SCOPED: it writes back whatever it loaded, so loading the
# project's number clears the box's own declared ceiling.
cat > "$SED_TMP" << 'SED'
s@  v="$(_read_section_from_file "$file" "$_lsec" "$key" || true)"@  v="$(_read_resource_from_file "$file" "$key" || true)"@
SED
try "pbs_picker_loads_scoped" "picker loads a box.s OWN declared resources" "$CLI" "$PBS_BATS"

# TRUST SUBJECT: with one file per project the box name is the only thing
# separating two consent decisions, so a bare "Project .cleat" is ambiguous.
cat > "$SED_TMP" << 'SED'
s@    printf '.cleat \[box.%s.%s\]' "$box" "$kind"@    printf '.cleat'@
SED
try "pbs_trust_names_section" "prompt names the box and the section" "$CLI" "$PBS_BATS"

# PROJECT EDIT NO-OP: editing [caps] while main declares its own changes nothing
# for main, and a bare success reads as if it did.
cat > "$SED_TMP" << 'SED'
s@    if _cleat_section_present "$file" "box.main.caps"; then@    if false; then@
SED
try "pbs_project_edit_warns" "warns when main declares its own" "$CLI" "$PBS_BATS"

# COMPAT NOTE: an older Cleat reads a per-box REDUCTION as the permissive
# project section, so the file itself should say which version understands it.
cat > "$SED_TMP" << 'SED'
s@  _config_note_sections_version "$file"@  :@
SED
try "pbs_compat_note" "first box section adds a compatibility note" "$CLI" "$PBS_BATS"

# WRITER CHANNEL HYGIENE: _WRITE_SECTION and friends are function parameters
# carried in globals. Read from the inherited environment, a stray value in the
# user's shell silently redirects which section a config edit lands in.
cat > "$SED_TMP" << 'SED'
s@^_WRITE_SECTION=""$@_WRITE_SECTION="${_WRITE_SECTION:-}"@
SED
try "pbs_writer_channel_hygiene" "ambient _WRITE_SECTION cannot redirect" "$CLI" "$PBS_BATS"

# LIST SHOWS THE SOURCE: a box view that prints only values is indistinguishable
# from the project's own, and the difference decides whether a later project
# edit reaches that box.
cat > "$SED_TMP" << 'SED'
s@    if \[\[ -n "$_box_scope" \]\]; then\n      _cleat_section_present@    if false; then\n      _cleat_section_present@
SED
cat > "$SED_TMP" << 'SED'
s@ ${DIM}(declared)${RESET}@@g
s@ ${DIM}(inherited)${RESET}@@g
s@ ${DIM}(declared by ${_box_scope})${RESET}@@g
s@ ${DIM}(inherited from the project)${RESET}@@g
SED
try "pbs_list_shows_source" "marks each box value as declared or inherited" "$CLI" "$PBS_BATS"

# PICKER LOAD USES THE WRITER'S SECTION: reading box.<box>.resources
# unconditionally broke box `main`, whose writer targets the bare [resources]:
# the load found nothing, the picker showed "default", and a no-op save DELETED
# the project's [resources].
cat > "$SED_TMP" << 'SED'
s@  _lsec="$(_config_section_for "$file" "$_lbox" resources)"@  _lsec="box.${_lbox}.resources"@
SED
try "pbs_picker_load_section" "no-op picker save on main never deletes" "$CLI" "$PBS_BATS"

# BREW GUARD WIRED: unwired, a Homebrew install falls into the generic no-git
# branch, whose curl re-install hint symlinks over Homebrew's own bin on an
# Intel Mac and orphans the keg. Neutered rather than deleted: dropping the
# `if` line alone leaves a dangling `fi` and the harness would skip it as a
# syntax error instead of judging it.
cat > "$SED_TMP" << 'SED'
s@if _is_brew_managed.*then@if false; then@
SED
try "vnext_brew_guard_wired" "refuses to self-update a Homebrew install" "$CLI" "$UPDATE_BATS"

# CELLAR PATTERN: the keg is recognised by the physical file living under a
# Cellar path segment. Point that pattern at something no path ever contains
# and every real brew install reads as a plain git checkout again.
cat > "$SED_TMP" << 'SED'
s@    \*/Cellar/\*) return 0 ;;@    */NeverAHomebrewCellar/*) return 0 ;;@
SED
try "vnext_brew_guard_cellar_pattern" "detects a keg through the bin symlink" "$CLI" "$UPDATE_BATS"

# ON-START PROMPT GATE: the .git test alone does not exclude a keg. Where
# `readlink -f` is missing (macOS before 12.3) REPO_DIR resolves to the
# Homebrew PREFIX, and /opt/homebrew IS Homebrew's own git repo, so the offer
# fires and its `git checkout v<tag>` lands inside brew's checkout. Drop the
# brew probe and only the .git gate is left, which passes there.
# Shares its sed with vnext_brew_install_self_guard on purpose: one edit,
# two independent tests that must each catch it. Here the consequence is that
# the on-start offer stops recognising a keg and falls through to the .git
# branch, which on the pre-12.3 leg is Homebrew's own repository.
cat > "$SED_TMP" << 'SED'
s@if _is_brew_managed "\${BASH_SOURCE\[0\]}"; then@if false; then@
SED
try "vnext_brew_prompt_gate" "routed to brew, never to git" "$CLI" "$UPDATE_BATS"

# PREFIX SYMLINK GUARD: /usr/local/bin is Homebrew's bin on an Intel Mac, so
# `cleat uninstall` deletes brew's own symlink there and leaves brew believing
# cleat is installed while the command is gone from PATH. Same line guards
# `cleat install` from replacing it.
cat > "$SED_TMP" << 'SED'
s@if _is_brew_managed "$target/cleat"; then@if false; then@
SED
try "vnext_brew_bin_target_guard" "refuses to remove a Homebrew symlink from the target dir" "$CLI" "$UPDATE_BATS"

# SELF GUARD ON INSTALL: a keg already has its symlink in the prefix, and
# re-linking from inside the Cellar points the name at a tree brew does not
# track. Narrower than vnext_brew_guard_wired: this neuters only the
# BASH_SOURCE self-checks, not the target checks.
cat > "$SED_TMP" << 'SED'
s@if _is_brew_managed "\${BASH_SOURCE\[0\]}"; then@if false; then@
SED
try "vnext_brew_install_self_guard" "install: refuses when the running cleat is a Homebrew keg" "$CLI" "$UPDATE_BATS"

# UPDATE DELEGATES TO BREW: with brew reachable, `cleat update` on a keg runs
# the upgrade rather than printing it. Skip the call and the user is back to
# copying a command by hand, which is the whole friction the handoff removes.
cat > "$SED_TMP" << 'SED'
s@if ! _brew_delegate upgrade cleatdev/tap/cleat; then@if true; then@
SED
try "vnext_brew_update_delegates" "hands a Homebrew install to brew upgrade" "$CLI" "$UPDATE_BATS"

# DELEGATION EXECS: `brew upgrade` deletes the keg this script is being read
# from, and bash reads a script incrementally, so the process image must be
# replaced rather than the script left reading its own deleted file. Drop the
# exec and control returns into a file that no longer exists.
cat > "$SED_TMP" << 'SED'
s|  exec brew "$@"|  brew "$@"|
SED
try "vnext_brew_delegate_exec" "_brew_delegate execs brew and never returns" "$CLI" "$UPDATE_BATS"

# UNINSTALL CONSENT GATE: `brew uninstall` removes the whole keg, so the
# handoff is terminal-only and asks first. Open the gate and an unattended
# `cleat uninstall` (a script, CI, a wrapper) deletes someone's install with
# no human in the loop.
cat > "$SED_TMP" << 'SED'
s@if _is_interactive && _brew_present; then@if true; then@
SED
try "vnext_brew_uninstall_consent_gate" "never prompts a keg without a terminal" "$CLI" "$UPDATE_BATS"

# EXECFAIL BEFORE THE HANDOFF: without it a failed exec kills the shell at
# 126/127, so the printed-command fallback is unreachable in the very case it
# is written for (brew removed or unrunnable between the check and the call).
cat > "$SED_TMP" << 'SED'
s@  shopt -s execfail 2>/dev/null || true@  :@
SED
try "vnext_brew_delegate_execfail" "survives an exec that cannot run brew" "$CLI" "$UPDATE_BATS"

# INSTALLER TAKEOVER: the guard covers the CLI verbs, but the command on the
# homepage is install.sh, and /usr/local/bin is Homebrew's own bin on an Intel
# Mac. Without this refusal the most advertised command in the project silently
# replaces a brew user's symlink with a tree brew does not track.
cat > "$SED_TMP" << 'SED'
s@    \*/Cellar/\*)@    */NeverAHomebrewCellar/*)@
SED
try "vnext_brew_installer_takeover" "refuses when Homebrew owns a cleat elsewhere" "$INSTALLER" "$INSTALLER_BATS"

# ONE INSTALL PER MACHINE, CLI SIDE: without the check `cleat install` happily
# adds a second cleat at another bin path, and from then on PATH order decides
# which one runs while the loser stays invisible.
cat > "$SED_TMP" << 'SED'
s@  _refuse_other_installs "$target/cleat" "$force" || exit 1@  :@
SED
try "vnext_one_install_wired" "refuses when another install exists elsewhere" "$CLI" "$UPDATE_BATS"

# FORCE MUST NEVER OVERRIDE A KEG: every other conflict is a symlink this tool
# created, but replacing brew's leaves brew tracking an install it no longer
# owns. Let force through here and --force silently orphans a keg.
cat > "$SED_TMP" << 'SED'
s@  if \[\[ -n "$brews" \]\]; then@  if false; then@
SED
try "vnext_one_install_force_brew" "never lets force override a keg" "$CLI" "$UPDATE_BATS"

# FIXED LOCATIONS ARE SCANNED, NOT JUST PATH: a Homebrew prefix is invisible to
# a shell that never ran `brew shellenv`, and a fresh ~/.local/bin is usually
# not on PATH either. Drop them and the scan reports a clean machine while a
# second cleat sits right there.
cat > "$SED_TMP" << 'SED'
s@^\${HOME:-}/.local/bin$@@
SED
try "vnext_one_install_fixed_locations" "sees a fixed location that is not on PATH" "$CLI" "$UPDATE_BATS"

# ONE INSTALL PER MACHINE, INSTALLER SIDE: this is the command on the homepage,
# so an unguarded run is the most likely way anyone ends up with two cleats.
cat > "$SED_TMP" << 'SED'
s@^refuse_other_installs "$(pick_bin_dir)/cleat"$@:@
SED
try "vnext_one_install_installer" "refuses a second install at another path" "$INSTALLER" "$INSTALLER_BATS"

# STATE LIVES OUTSIDE THE INSTALL TREE: a Homebrew keg is deleted and recreated
# by every `brew upgrade`, so in-tree throttles reset and every declined version
# is forgotten on each upgrade. Switching install channels lost the same state.
cat > "$SED_TMP" << 'SED'
s@^CLEAT_STATE_DIR="$CLEAT_CONFIG_DIR/state"$@CLEAT_STATE_DIR="$REPO_DIR"@
SED
try "vnext_state_out_of_tree" "the update and highlight files default under the config dir" "$CLI" "$UPDATE_BATS"

# MIGRATION CARRIES THE OLD STATE: without it, upgrading into this version
# re-nags about a release the user already declined and re-shows notices.
cat > "$SED_TMP" << 'SED'
s@    cp "$old" "$new" 2>/dev/null || true@    :@
SED
try "vnext_state_migration" "migrates a file left in the old in-tree location" "$CLI" "$UPDATE_BATS"

# THE SWITCH RESCUE: someone moving from a pre-1.4 script install straight to a
# keg never launches the old install again, so without the second source their
# state sits orphaned in ~/.cleat and the channel switch loses the very memory
# the relocation exists to preserve.
cat > "$SED_TMP" << 'SED'
s@  for root in "$REPO_DIR" "${HOME:-}/.cleat"; do@  for root in "$REPO_DIR"; do@
SED
try "vnext_state_switch_rescue" "rescues state from a script install after a switch" "$CLI" "$UPDATE_BATS"

# THE RESCUE IS COPY-ONLY: ~/.cleat can still belong to a LIVE install, so the
# rescue pass must never unlink it. Running a working copy from a checkout,
# which is what every Cleat developer does, would otherwise consume the
# installed cleat's throttle and declined-version memory.
cat > "$SED_TMP" << 'SED'
s@      if \[\[ "$root" == "$REPO_DIR" && -f "$new" \]\]; then@      if true; then@
SED
try "vnext_state_rescue_copy_only" "the script-install rescue copies but never deletes" "$CLI" "$UPDATE_BATS"

# AND ONLY AFTER THE COPY LANDED: a destination that cannot be written turns a
# failed move into outright data loss if the unlink runs anyway.
cat > "$SED_TMP" << 'SED'
s@      if \[\[ "$root" == "$REPO_DIR" && -f "$new" \]\]; then@      if [[ "$root" == "$REPO_DIR" ]]; then@
SED
try "vnext_state_unlink_after_copy" "a failed copy never unlinks the original" "$CLI" "$UPDATE_BATS"

# ONE VERSION SOURCE FOR BOTH CHANNELS: a keg has no repo to ask, so forcing
# `origin` makes the lookup fail there and a brew user is never told a release
# exists. This is what keeps the on-start offer identical on both channels.
cat > "$SED_TMP" << 'SED'
s@  \[\[ -d "$REPO_DIR/.git" \]\] && _remote="origin"@  _remote="origin"@
SED
try "vnext_update_remote_source" "latest_remote_tag asks the public URL when there is no repo" "$CLI" "$UPDATE_BATS"

# KEG ROUTES TO BREW: mis-route the channel and the on-start offer tries to
# `git checkout` a tag inside whatever REPO_DIR resolved to, which for a keg on
# Apple Silicon is Homebrew's own repository.
cat > "$SED_TMP" << 'SED'
s@    _channel="brew"@    _channel="git"@
SED
try "vnext_update_channel_brew" "a keg is offered the update and upgraded through brew" "$CLI" "$UPDATE_BATS"

# NO BREW MEANS NO OFFER: without brew the upgrade cannot be applied, so
# prompting only interrupts a launch with something the user cannot act on.
cat > "$SED_TMP" << 'SED'
s@    _brew_present || return 0@    :@
SED
try "vnext_update_brew_present_gate" "a keg with no brew on PATH is never offered anything" "$CLI" "$UPDATE_BATS"

# THE DIRTY-TREE GUARD IS GIT-ONLY: it exists to avoid an auto `git checkout`
# onto uncommitted work. Apply it to a keg, which has no working tree, and the
# offer is silenced there forever.
cat > "$SED_TMP" << 'SED'
s@  if \[\[ "$_channel" == "git" \]\]; then@  if true; then@
SED
try "vnext_update_keg_dirty_tree" "a keg offer is not blocked by a dirty working tree" "$CLI" "$UPDATE_BATS"

# THE UPGRADE CLEARS ITS CACHES: leave them and the new keg is judged against
# the old version's cached answer on the next launch.
cat > "$SED_TMP" << 'SED'
s@  rm -f "$UPDATE_CHECK_FILE" "$CLAUDE_CHECK_FILE" 2>/dev/null || true@  :@
SED
try "vnext_brew_apply_clears_cache" "upgrades the formula and clears the caches" "$CLI" "$UPDATE_BATS"

# A LOCAL BUILD NEEDS A CONTEXT: on macOS before 12.3 `readlink -f` does not
# resolve the invoking symlink, so REPO_DIR is the Homebrew PREFIX rather than
# the keg and $REPO_DIR/docker does not exist. Every image acquisition is
# `_do_pull || _do_build`, so without this check a failed pull ends a SESSION
# START in a raw docker error about a build context that was never there.
cat > "$SED_TMP" << 'SED'
s@  if \[\[ ! -f "$REPO_DIR/docker/Dockerfile" \]\]; then@  if false; then@
SED
try "vnext_build_needs_context" "refuses with an actionable message when there is no docker context" "$CLI" "$DOCKER_COMMANDS_BATS"

# APP BUNDLE TEST SEAM: $HOME is sandboxed in tests but /Applications is not, so
# an absent-app assertion depended on the developer's machine not having the app
# installed. Green on Linux and CI, red on a Mac with Docker Desktop. Hardcode
# the system path again and the system-install test fails.
cat > "$SED_TMP" << 'SED'
s@  local _sys="${_APP_DIR_SYSTEM:-/Applications}"@  local _sys="/nonexistent-Applications"@
SED
try "autostart_app_dir_seam" "finds a system /Applications install" "$CLI" "$REPO_ROOT/test/unit/autostart.bats"

# FORK GUARDS RESOLVE BOTH SIDES: comparing a physically-resolved project
# against a LOGICAL fork root made both recursion guards no-ops wherever the
# path crosses a symlink, which on macOS is everything under /tmp and
# /var/folders. The copy then recursed into itself: a disk-filling loop.
cat > "$SED_TMP" << 'SED'
s@    _fr_phys="$(_phys_or_best "$_froot")"@    _fr_phys="$_froot"@
SED
try "fork_root_inside_symlinked" "a fork root inside the project is refused THROUGH" "$CLI" "$FORK_BATS"

cat > "$SED_TMP" << 'SED'
s@    _pp="$(_phys_or_best "$project")"@    _pp="$project"@
SED
try "fork_of_fork_symlinked" "forking a fork is refused THROUGH" "$CLI" "$FORK_BATS"

# CLIPBOARD SYMLINK READ-THROUGH: the delivery redirect follows a symlink even
# though the mv that precedes it does not. Drop the post-rename check and a box
# can name any host file and have the host's own watcher pipe it into the host
# clipboard.
cat > "$SED_TMP" << 'SED'
/^    if \[ -L "[$]claim" \]; then$/,/^    fi$/d
SED
try "clip_symlink_read_through" "a symlinked clipboard payload is never read through" "$CLI" "$REGRESSIONS"

# CLIPBOARD SYMLINK STARTUP SWEEP: kill the -L branch and a planted link falls
# through to the [ -f ] age gate, which dereferences. A fresh link is inside the
# grace window, so it survives startup and waits to be delivered.
cat > "$SED_TMP" << 'SED'
s@  if \[ -L "[$]clip_dir/clipboard" \]; then@  if [ -L "/nonexistent-never-matches" ]; then@
SED
try "clip_symlink_startup_sweep" "a symlink planted before startup is swept" "$CLI" "$REGRESSIONS"

# CLAIM INSIDE THE BIND MOUNT: put the claim back in the shared dir and the box
# can swap it for a symlink in the window between the rename and the read, which
# is the race the move out of the mount exists to remove.
cat > "$SED_TMP" << 'SED'
s@local claim="[$]claim_dir/@local claim="$clip_dir/@
SED
try "clip_claim_outside_mount" "the clipboard claim is renamed out of the box-visible dir" "$CLI" "$REGRESSIONS"

CLIPIMG_BATS="$REPO_ROOT/test/unit/clipimg.bats"

# SHIM TOKEN: Claude Code greps the check leg's stdout for
# image/(png|jpeg|jpg|gif|webp|bmp). Print anything else and the grep misses,
# so the save leg never runs and paste silently does nothing.
cat > "$SED_TMP" << 'SED'
s@^echo "image/png"$@echo "png"@
SED
try "clipimg_check_token" "a served image makes the check leg report" "$CLI" "$CLIPIMG_BATS"

# SHIM CONSUME-ON-READ: leave the cache in place and the same image attaches
# again on the next paste, whatever the user actually copied.
cat > "$SED_TMP" << 'SED'
s@^    rm -f "[$]D/cache.png" 2>/dev/null$@    :@
SED
try "clipimg_consume_on_read" "the save leg emits the cached bytes and consumes" "$CLI" "$CLIPIMG_BATS"

# SERVE VALIDATION: drop the magic-byte and size gate and whatever the reader
# produced is delivered, so text-shaped bytes could reach Claude Code as an
# image.
cat > "$SED_TMP" << 'SED'
s@  if \[ -z "[$]kind" \] || \[ "[$]size" -eq 0 \] || \[ "[$]size" -gt "[$]_CLIPIMG_MAX_BYTES" \]; then@  if false; then@
SED
try "clipimg_serve_validates" "a non-image payload is refused as a miss" "$CLI" "$CLIPIMG_BATS"

# SERVE DONE SIGNAL: skip the in.done delivery and the shim never learns the
# answer arrived, so it waits out its full timeout on every paste.
cat > "$SED_TMP" << 'SED'
s@  docker cp "[$]done" "[$]cname:[$]_CLIPIMG_BOX_DIR/in.done" >/dev/null 2>&1@  :@
SED
try "clipimg_serve_done_signal" "delivered as in.png then in.done" "$CLI" "$CLIPIMG_BATS"

# WATCHER CONSUMES REQUEST: serve without the atomic mv-claim and the request is
# never consumed, so the shim never gets its liveness signal and the watcher
# re-serves every tick.
cat > "$SED_TMP" << 'SED'
s@    if mv "[$]req" "[$]req.claimed" 2>/dev/null; then@    if [ -e "$req" ]; then@
SED
try "clipimg_watcher_consumes" "consumes the request marker and serves once" "$CLI" "$CLIPIMG_BATS"

# LOCK TRAP: drop the shim's signal trap and a paste killed mid-flight strands
# the lock DIRECTORY, wedging every later paste (the .host-ready latch class).
cat > "$SED_TMP" << 'SED'
/trap .rm -f "[$]REQ" 2>.dev.null; rmdir "[$]LOCK"/d
SED
try "clipimg_lock_trap" "a signal mid-paste releases the lock" "$CLI" "$CLIPIMG_BATS"

# LOCK SWEEP: SIGKILL cannot be trapped, so the host watcher must sweep a stale
# lock. Remove the sweep and a killed shim's lock wedges paste across sessions.
cat > "$SED_TMP" << 'SED'
s@      rmdir "[$]lock" 2>/dev/null || true@      :@
SED
try "clipimg_lock_sweep" "sweeps a stale lock a killed shim left" "$CLI" "$CLIPIMG_BATS"

# LOCK SWEEP AGE GATE: sweep without the age gate and a LIVE lock is yanked from
# a running paste.
cat > "$SED_TMP" << 'SED'
s@))" -gt 10 \]; then@))" -gt -100000 ]; then@
SED
try "clipimg_lock_sweep_age" "never sweeps a fresh" "$CLI" "$CLIPIMG_BATS"

# BOUNDED READ: remove the kill and a slow host read runs unbounded, so a late
# delivery is attached by the next paste as a stale wrong image.
cat > "$SED_TMP" << 'SED'
s@    if \[ "[$]_rn" -ge 16 \]; then kill "[$]_rpid" 2>/dev/null; break; fi@    :@
SED
try "clipimg_read_bounded" "a slow host read is bounded" "$CLI" "$CLIPIMG_BATS"

# CLEAR AFTER LOCK: clear before taking the lock and a losing second press wipes
# the winner's in-flight in.png.
cat > "$SED_TMP" << 'SED'
s@^mkdir "[$]LOCK" 2>/dev/null || exit 1@rm -f "$D/in.png" "$D/in.done" "$D/cache.png" 2>/dev/null; mkdir "$LOCK" 2>/dev/null || exit 1@
SED
try "clipimg_clear_after_lock" "does not delete the winner" "$CLI" "$CLIPIMG_BATS"

# ATOMIC CLAIM RESIDUE: leave the .claimed rename behind and the shared dir fills
# with residue the sweeps do not match.
cat > "$SED_TMP" << 'SED'
s@      rm -f "[$]req.claimed" 2>/dev/null || true@      :@
SED
try "clipimg_claim_residue" "leaves no residue" "$CLI" "$CLIPIMG_BATS"

# SHIM DROP PATH: land the shim anywhere but ahead of xclip on PATH and native
# ctrl+v never reaches it.
cat > "$SED_TMP" << 'SED'
s@  docker cp "[$]tmp" "[$]cname:[$]_CLIPIMG_SHIM_PATH" >/dev/null 2>&1@  docker cp "$tmp" "$cname:/tmp/wrong-path" >/dev/null 2>&1@
SED
try "clipimg_shim_drop_path" "copies the shim to .local/bin ahead of the real" "$CLI" "$CLIPIMG_BATS"

# SHIM EMPTY ANSWER: the host answers a miss with an empty in.png. Treat that as
# a hit and the check leg reports an image that does not exist, so the save leg
# hands Claude Code zero bytes.
cat > "$SED_TMP" << 'SED'
s@^\[ -s "[$]D/in.png" \] || exit 1$@:@
SED
try "clipimg_empty_is_miss" "empty answer is a miss" "$CLI" "$CLIPIMG_BATS"

# HOST-READY LATCH: go back to testing a watcher marker's mere existence. A
# crashed session's marker then holds .host-ready on forever, the box keeps
# taking the file-bridge path with nobody listening, and every copy is silently
# swept instead of falling back to OSC 52.
cat > "$SED_TMP" << 'SED'
s@    kill -0 "[$]pid" 2>/dev/null || rm -f "[$]m" 2>/dev/null || true@    :@
SED
try "watcher_marker_liveness" "a dead session's watcher marker never latches" "$CLI" "$REGRESSIONS"

# BROWSER BRIDGE SYMLINK READ-THROUGH: the same shape as the clipboard payload
# path, in the consumer that `cat`s the claim. Drop the guard and a planted link
# has the host read any file it names and hand the contents to the URL opener.
# Removes the WHOLE defence, both the pre-check and the post-rename check.
# Deleting either one alone leaves the other covering the property, so a
# single-guard mutation reads as MISSED when the test is in fact fine. The
# post-rename check defends a race and cannot be isolated in a test.
cat > "$SED_TMP" << 'SED'
/^  if \[ -L "[$]bridge_file" \]; then$/,/^  fi$/d
/^  if \[ -L "[$]claim" \]; then$/,/^  fi$/d
SED
try "browser_symlink_read_through" "a symlinked browser-bridge file is never read through" "$CLI" "$REGRESSIONS"

# BROWSER CLAIM DIR: ignore the caller's claim directory and the claim goes back
# beside the bridge file, inside the box's bind mount, where it can be swapped
# between the rename and the cat.
cat > "$SED_TMP" << 'SED'
s@  \[ -n "[$]claim_dir" \] || claim_dir="[$](dirname "[$]bridge_file")"@  claim_dir="$(dirname "$bridge_file")"@
SED
try "browser_claim_dir_honoured" "the browser claim honours a claim dir outside the mount" "$CLI" "$REGRESSIONS"

# INTEGRATION NAME QUOTING: reintroduce the single-quoted path argument in a
# real integration call site. The literal text gets hashed, so the computed
# container name no longer matches the container cleat created, and every
# assertion downstream fails with "No such container". The source guard must
# see it without a Docker daemon anywhere in the loop.
cat > "$SED_TMP" << 'SED'
s@  cname="$(int_cname)"@  cname="$(cli_call container_name_for '$INT_PROJECT')"@
SED
try "int_cname_single_quoted_arg" "no cli_call argument is single-quoted" "$INT_LIFECYCLE_BATS" "$REGRESSIONS"

# INT_CNAME BOGUS-NAME GATE: drop the sanity gate and a name that still holds an
# unexpanded variable sails through to `docker exec`, where the error names a
# missing container instead of the quoting bug that produced the name.
cat > "$SED_TMP" << 'SED'
s@    ''|\*'[$]'\*|\*\[\[:space:\]\]\*)@    __never_matches__)@
SED
try "int_cname_bogus_gate" "int_cname refuses a name carrying an unexpanded" "$SETUP_BASH" "$REGRESSIONS"

# INT_CNAME EXPANSION: quote the helper's own argument and every integration
# test inherits the bug the helper exists to prevent.
cat > "$SED_TMP" << 'SED'
s@    name="$(cli_call container_name_for "$INT_PROJECT")" || return 1@    name="$(cli_call container_name_for '"'"'$INT_PROJECT'"'"')" || return 1@
SED
try "int_cname_expands_path" "int_cname derives the name from the real project path" "$SETUP_BASH" "$REGRESSIONS"

# INT_CNAME BOX THREADING: swallow the box argument and two boxes resolve to the
# same container name, which quietly turns the two-box isolation test into a
# test of one box against itself.
cat > "$SED_TMP" << 'SED'
s@    name="$(cli_call container_name_for "$INT_PROJECT" "$box")" || return 1@    name="$(cli_call container_name_for "$INT_PROJECT")" || return 1@
SED
try "int_cname_threads_box" "int_cname threads a box name through" "$SETUP_BASH" "$REGRESSIONS"

echo ""
echo "${BOLD}Mutation test summary${RESET}"
echo "  Total:   $total"
echo "  Caught:  ${GREEN}$caught${RESET}"
echo "  Missed:  ${RED}$missed${RESET}"
echo "  Skipped: ${YELLOW}$skipped${RESET}"

if [[ $missed -gt 0 ]]; then
  echo ""
  echo "${RED}${BOLD}Ineffective regression tests (test passed despite mutation):${RESET}"
  for n in "${missed_names[@]}"; do
    echo "  - $n"
  done
  exit 1
fi

exit 0
