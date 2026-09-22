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
HANDOFF_BATS="$REPO_ROOT/test/unit/handoff.bats"
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
SESSIONS_BATS="$REPO_ROOT/test/unit/sessions.bats"
ACCOUNTS_BATS="$REPO_ROOT/test/unit/accounts.bats"
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
/^_browser_watcher()/,/^}$/{
  s|_browser_sweep_stale_bridge "\$clip_dir"|:|
}
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
try "v0.6.4_tcp6_first" "forwards TCP6 first with ignoreeof"

# v0.6.4: socat must use -,ignoreeof to prevent stdin EOF propagation
cat > "$SED_TMP" << 'SED'
s|-\\\\,ignoreeof|-|g
SED
try "v0.6.4_ignoreeof" "forwards TCP6 first with ignoreeof"

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
s|^KNOWN_CAPS=(git ssh env hooks gh docker unsafe-rm)$|KNOWN_CAPS=(git ssh env hooks gh unsafe-rm)|
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
# The 127/8 numeric arm serves 127.0.0.1 (and the whole block). Kill its
# return; the loopback-bind test (tcp://127.0.0.1) should fail.
cat > "$SED_TMP" << 'SED'
s#;; \*) return 0 ;; esac#;; *) : ;; esac#
SED
try "vnext_docker_cap_loopback_binds_socket" "loopback tcp DOCKER_HOST binds the host socket" "$CLI" "$CAPABILITIES_BATS"

# The localhost arm is its own case branch (DNS name, matched lowercased).
# Kill it; the case-insensitive LOCALHOST test should fail.
cat > "$SED_TMP" << 'SED'
/^_endpoint_is_loopback()/,/^}$/ s#^    localhost) return 0 ;;#    NOMATCH_LOOPBACK) return 0 ;;#
SED
try "vnext_docker_cap_loopback_localhost_arm" "LOCALHOST is loopback" "$CLI" "$CAPABILITIES_BATS"

# The numeric guard keeps a DNS name like 127.0.0.1.example.com REMOTE. Break
# the guard so any 127.* string counts as loopback; the lookalike test fails.
cat > "$SED_TMP" << 'SED'
s#\*\[!0-9\.\]\*) ;;#NOMATCH_NUM) ;;#
SED
try "vnext_docker_cap_loopback_numeric_guard" "starts with 127" "$CLI" "$CAPABILITIES_BATS"

# The IPv6 [::1] arm. Kill it; the IPv6 loopback test should fail.
cat > "$SED_TMP" << 'SED'
s#"tcp://\["\*)#"NOMATCH_V6")#
SED
try "vnext_docker_cap_loopback_ipv6_arm" "cap: IPv6 loopback" "$CLI" "$CAPABILITIES_BATS"

# The loopback branch may bind /var/run/docker.sock ONLY when it is live: a
# missing source would let the daemon materialise a phantom host directory.
# Bypass the guard; the loopback-without-socket warn test should fail.
cat > "$SED_TMP" << 'SED'
s#&& _host_sock_is_live /var/run/docker.sock; then#\&\& true; then#
SED
try "vnext_docker_cap_loopback_liveness_guard" "with no host socket warns" "$CLI" "$CAPABILITIES_BATS"

# vnext unsafe-rm: the guard cap must NOT be grantable from a project .cleat (the
# caged agent can write it). Stop stripping it from project caps; the
# project-ignored test should fail.
cat > "$SED_TMP" << 'SED'
s@grep -vx 'unsafe-rm' || true@cat@
SED
try "vnext_unsafe_rm_project_stripped" "unsafe-rm from a project" "$CLI" "$CAPABILITIES_BATS"

# vnext unsafe-rm: --cap unsafe-rm must inject the PermissionRequest hook into the
# box settings overlay. Neutralise the injection; the overlay-hook test fails.
cat > "$SED_TMP" << 'SED'
s@_inject_unsafe_rm_hook "\$settings_overlay_dir/settings.json"@:@
SED
try "vnext_unsafe_rm_hook_injected" "writes the delete-allow hook" "$CLI" "$CAPABILITIES_BATS"




# vnext unsafe-rm: the hook must answer ONLY when the command actually removes
# something, so it can never blanket-approve an unrelated permission ask. Drop
# the saw_rm gate; the removes-nothing test should fail.
cat > "$SED_TMP" << 'SED'
s@^if saw_rm:@if True:@
SED
try "vnext_unsafe_rm_requires_a_removal" "refuses when the command removes nothing" "$CLI" "$CAPABILITIES_BATS"

# vnext unsafe-rm: cmd_resume rewrites settings.json from the host file, so it
# must RE-INJECT the hook or the cap silently dies after the first resume. The
# 8-space indent targets the resume call only, not the one in cmd_run.
cat > "$SED_TMP" << 'SED'
s@^        _inject_unsafe_rm_hook @        : @
SED
try "vnext_unsafe_rm_hook_survives_resume" "SURVIVES a resume" "$CLI" "$CAPABILITIES_BATS"

# The empty/root-HOME guard in _docker_pool_is_vm: without it an empty HOME
# degenerates the Lima anchor to /.colima/* and reopens the over-match. Remove
# the guard; the empty-HOME predicate test should fail.
cat > "$SED_TMP" << 'SED'
s#case "\${HOME:-}" in ""|/) return 1 ;; esac#:#
SED
try "vnext_docker_pool_empty_home_guard" "empty HOME never turns" "$CLI" "$CAPABILITIES_BATS"

# The two direct predicate arms of _docker_pool_is_vm, locked via the prune
# VM-advisory tests that drive them through the real derivation.
cat > "$SED_TMP" << 'SED'
/^_docker_pool_is_vm()/,/^}$/ s#^  _is_macos && return 0$#  :#
SED
try "vnext_docker_pool_macos_arm" "macOS keeps the VM wording" "$CLI" "$PRUNE_BATS"

cat > "$SED_TMP" << 'SED'
/^_docker_pool_is_vm()/,/^}$/ s#^  _is_docker_desktop && return 0$#  :#
SED
try "vnext_docker_pool_desktop_arm" "confirms a well-sized VM" "$CLI" "$PRUNE_BATS"

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
# old /tmp cleanup lines when runtime state moved off /tmp, and which became
# _account_wipe_run_dir when named accounts made the wipe harvest first.)
cat > "$SED_TMP" << 'SED'
/^cmd_rm()/,/^}$/{
  /_account_wipe_run_dir "\${cname}"/a\
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
# re-run the installer instead of staying alive. Drop the --change flag. It
# lives in the _commit_changes array (the label re-stamp made it one), so the
# match must not depend on a trailing space.
cat > "$SED_TMP" << 'SED'
s|--change 'CMD \["bash"\]'||
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
# /tmp rotation). Remove the wipe; the nuke test must then fail. The wipe became
# _nuke_wipe_dir when the account store earned a guard, so the sed follows it.
# It sits inside the account-lock check since the lock landed, so the wipe is
# replaced with a no-op (a delete would leave an empty then-branch).
cat > "$SED_TMP" << 'SED'
s/^      _nuke_wipe_dir "[$]CLEAT_RUN_DIR"$/      :/
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
# the "fresh install" test (which pins "New in v1.5.0") then fails.
cat > "$SED_TMP" << 'SED'
s/New in v1.5.0/New in v9.9.9/
SED
try "v0.15.0_highlight_label_frozen" "fresh install" "$CLI" "$WHATS_NEW_BATS"

# The release highlight announces the live account switch, the line a user at a
# usage limit needs. Corrupt it so the "fresh install" test's assertion fails,
# proving the line is guarded rather than only present.
cat > "$SED_TMP" << 'SED'
/^_maybe_show_release_highlight()/,/^}$/ s/Out of usage mid-run?/Out of tokens?/
SED
try "vnext_highlight_account_switch_line" "fresh install" "$CLI" "$WHATS_NEW_BATS"

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
s|cleat.sh/changelog#v1.5.0|cleat.sh/changelog|
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
# Retargeted: the destination gate rewrote the auto branch, so the old comment
# the sed anchored on is gone. The property is unchanged.
cat > "$SED_TMP" << 'SED'
s|        return 1 ;;                               # plain link: the terminal, or nobody|        return 0 ;;|
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

# AUTH (token): _oauth_expires_at must surface the parsed ms epoch. Its digits
# are validated in _json_flat_num. Refuse every value there: the extraction test
# sees nothing.
cat > "$SED_TMP" << 'SED'
/^_json_flat_num()/,/^}$/{
  s/^  \[\[ "[$]hit" =~ [$]re \]\] || return 1$/  return 1/
}
SED
try "bugfix_oauth_expires_extract" "extracts the ms epoch" "$CLI" "$CREDENTIALS_BATS"

# vnext and v1.4.3: the credential expiry is the Claude login's own
# (claudeAiOauth.expiresAt). Restore the whole-blob last match. Claude Code
# writes mcpOAuth after claudeAiOauth once an MCP login follows a Claude login,
# so every newest-wins decision reads an MCP server's expiry. A refresh is not
# harvested, staging overwrites a fresher box login and a dead login beside a
# live MCP token polls usage. The macOS re-seed puts an older Keychain login over
# a box-refreshed one or takes an expired one on the strength of its MCP entry.
cat > "$SED_TMP" << 'SED'
/^_oauth_expires_at()/,/^}$/{
  s/^  _json_flat_num "[$](_json_flat_object claudeAiOauth)" expiresAt || true$/  grep -iEo '"expiresat"[[:space:]]*:[[:space:]]*[0-9]+' | grep -Eo '[0-9]+' | tail -1 || true/
}
SED
try "vnext_account_expiry_claude_login" "newest-wins reads the Claude login expiry"
try "vnext_account_expiry_claude_login_order" "reads the Claude login whichever side of mcpOAuth" "$CLI" "$CREDENTIALS_BATS"
try "vnext_account_expiry_claude_login_usage" "usage is never polled on an expired login because an MCP token" "$CLI" "$ACCOUNTS_BATS"
try "v1.4.3_seed_expiry_claude_login" "re-seed keeps a box-refreshed login when an expired MCP login"
try "v1.4.3_seed_expiry_claude_login_dead" "re-seeds a dead Claude login even when a live MCP login follows it" "$CLI" "$CREDENTIALS_BATS"
try "v1.4.3_seed_expiry_claude_login_keychain" "never re-seeds from an expired Keychain login on the strength of its MCP entry" "$CLI" "$CREDENTIALS_BATS"

# The isolated object must be flat. A greedy match swallows a nested object and
# reads whatever expiresAt sits inside it.
cat > "$SED_TMP" << 'SED'
/^_json_flat_object()/,/^}$/{
  s/[[][{][]](.*)[*][[][}][]]/[{].*[}]/
}
SED
try "vnext_json_flat_object_flat_only" "empty when the Claude login cannot be isolated" "$CLI" "$CREDENTIALS_BATS"

# A brace inside a string is text. Match the object as any run of non-braces
# and it ends inside the access token, so the reader loses the fields after it.
cat > "$SED_TMP" << 'SED'
/^_json_flat_object()/,/^}$/{
  s/[[][{][]](.*)[*][[][}][]]/[{][^{}]*[}]/
}
SED
try "vnext_json_flat_object_brace_in_string" "prints the login object alone or nothing when the key is ambiguous" "$CLI" "$CREDENTIALS_BATS"

# The key twice, flat or nested, is ambiguous. Drop the refusal: two flat copies
# print both and a nested second copy prints the first as if it were the login.
cat > "$SED_TMP" << 'SED'
/^_json_flat_object()/,/^}$/{
  /^  case "[$]hit" in ''|[*][$]'.n'[*]) return 0 ;; esac$/d
}
SED
try "vnext_json_flat_object_single_key" "prints the login object alone or nothing when the key is ambiguous" "$CLI" "$CREDENTIALS_BATS"

# Line breaks are whitespace between JSON tokens. Without the fold a
# pretty-printed credential reads as no login at all.
cat > "$SED_TMP" << 'SED'
/^_json_flat_object()/,/^}$/{
  s/LC_ALL=C tr '\\000\\r\\n' '   ' 2>[/]dev[/]null/cat/
}
SED
try "vnext_json_flat_object_folds_newlines" "reads the Claude login whichever side of mcpOAuth" "$CLI" "$CREDENTIALS_BATS"

# A leading zero is octal in bash arithmetic, so a box-planted 0800 printed an
# arithmetic error on the host terminal at every attach.
cat > "$SED_TMP" << 'SED'
/^_json_flat_num()/,/^}$/{
  /^  case "[$]v" in 0?[*]) return 1 ;; esac$/d
}
SED
try "vnext_json_flat_num_leading_zero" "empty when the Claude login cannot be isolated" "$CLI" "$CREDENTIALS_BATS"

# More than 15 digits can wrap in 64-bit arithmetic and read as any expiry.
cat > "$SED_TMP" << 'SED'
/^_json_flat_num()/,/^}$/{
  /^  \[\[ [$]{#v} -le 15 \]\] || return 1$/d
}
SED
try "vnext_json_flat_num_digit_cap" "empty when the Claude login cannot be isolated" "$CLI" "$CREDENTIALS_BATS"

# The staged copy is box-writable and its expiry is read before any size check.
cat > "$SED_TMP" << 'SED'
/^_account_cred_expiry()/,/^}$/{
  s/head -c "[$]_ACCOUNT_CRED_MAX_BYTES" "[$]f"/head -c 999999999 "$f"/
}
SED
try "vnext_account_expiry_size_cap" "a credential file past the size cap never reads as a live login" "$CLI" "$ACCOUNTS_BATS"

# v1.4.3: the seed runs bare in exec_claude under set -e. A redirect read of an
# unreadable shared credential fails the assignment and aborts the launch.
cat > "$SED_TMP" << 'SED'
/^_seed_macos_credentials()/,/^}$/{
  s/^    file_exp="[$](head -c .*$/    file_exp="$(_oauth_expires_at < "$cred" 2>\/dev\/null)"/
}
SED
try "v1.4.3_seed_unreadable_no_abort" "an unreadable shared credential file does not abort the macOS launch"

# v1.4.3: ~/.claude is mounted read-write into every box. Bring back the
# guessable pid temp name: a planted symlink there receives the Keychain login.
cat > "$SED_TMP" << 'SED'
/^_seed_macos_credentials()/,/^}$/{
  s/^  tmp="[$](mktemp .*$/  tmp="${cred}.tmp.$$"/
}
SED
try "v1.4.3_seed_temp_mktemp" "macOS seed never writes the token through a planted temp symlink"

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

# IDLE SWEEP: a box with a live claude agent must NEVER be stopped (autonomy:
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
# Retargeted: the watcher now classifies the CLEANED copy, the bytes it opens,
# rather than the raw claim. The property is unchanged.
cat > "$SED_TMP" << 'SED'
s|_is_auth_url "$_clean_url" && _is_auth=1|:|
SED
try "bugfix_codepaste_url_is_auth" "still auto-opens in an interactive session" "$CLI" "$REGRESSIONS"

# BRIDGE: _is_auth_url must match a redirect_uri= that arrives after & (every
# real authorize URL). Retargeted: the function now cuts the fragment first and
# matches on `$q` rather than `$1`, and the arms return nothing rather than 0.
# The property is unchanged, and the code-paste URL is still what proves it.
# Retargeted again: the arms live in _is_auth_url_shape, which _is_auth_url
# calls after the origin check.
cat > "$SED_TMP" << 'SED'
/^_is_auth_url_shape()/,/^}$/{
  s@^    \*\\?redirect_uri=\*|\*\\&redirect_uri=\*) ;;$@    *\\?redirect_uri=*) ;;@
}
SED
try "bugfix_is_auth_url_amp_param" "the code-paste flow still classifies as auth" "$CLI" "$BROWSER_BRIDGE_BATS"

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
try "vnext_browser_login_env" "execs claude as coder with full PATH" "$CLI" "$DOCKER_COMMANDS_BATS"

# BRIDGE STARTUP AGE GATE: the watcher's startup sweep must only remove a
# STALE leftover bridge file. Reverting the gate to always-true (age > -1 is
# unconditional) restores the pre-fix swallow: a watcher starting moments
# after claude wrote a login URL deletes it before any sibling watcher's poll
# can claim it, stranding that login.
cat > "$SED_TMP" << 'SED'
s|))" -gt 5 \]|))" -gt -1 ]|
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
s|\[\[ "$(id -u)" == "0" \]\]|[[ "$(id -u)" != "0" ]]|
SED
try "v1.2.0_root_is_sandbox_gate" "root host rides IS_SANDBOX"

# v1.5.1 NAMESPACED ENGINE: the box identity must be the uid the host user IS
# inside a container, not the host's own number. Revert it at the create site:
# a measured mapping of 0 stops reaching the box and the agent runs as a subuid
# that owns nothing, which is the whole rootless breakage.
cat > "$SED_TMP" << 'SED'
s|-e "HOST_UID=$_bx_uid"|-e "HOST_UID=$(id -u)"|
SED
try "v1.5.1_box_identity_uid" "namespaced engine gets the in-namespace identity" "$CLI" "$DOCKER_COMMANDS_BATS"

cat > "$SED_TMP" << 'SED'
s|-e "HOST_GID=$_bx_gid"|-e "HOST_GID=$(id -g)"|
SED
try "v1.5.1_box_identity_gid" "namespaced engine gets the in-namespace identity" "$CLI" "$DOCKER_COMMANDS_BATS"

# v1.5.1 CACHE SCOPE: a measurement carries the engine and the host uid it was
# taken for. Trust any line regardless of who measured it and one user's box
# runs as another user's mapping.
cat > "$SED_TMP" << 'SED'
s@  \[ "$h" = "$(id -u)" \] || return 1@  :@
SED
try "v1.5.1_box_identity_cache_scope" "measurement for another host user is not trusted" "$CLI" "$DOCKER_COMMANDS_BATS"

# v1.5.1 FALSE GREEN: the remap wait must compare the uid the box was TOLD to
# use. Comparing the host's own number matches while the mapping is wrong,
# which is what hid every rootless failure.
cat > "$SED_TMP" << 'SED'
s|  want="$(_box_uid)"|  want="$(id -u)"|
SED
try "v1.5.1_remap_wait_compares_box_uid" "remap wait is satisfied" "$CLI" "$DOCKER_COMMANDS_BATS"

# v1.5.1 IS_SANDBOX on a namespaced engine: drop the second disjunct and every
# session on such an engine dies at launch, because claude refuses
# --dangerously-skip-permissions under uid 0. NOTE the bare `||` below: in BRE
# a backslashed pipe is GNU alternation, so escaping it matches a single space
# and rewrites half the file instead.
cat > "$SED_TMP" << 'SED'
s@ || \[\[ "$(_box_uid_cached_only 2>/dev/null)" == "0" \]\]@@
SED
try "v1.5.1_is_sandbox_namespaced" "box that will run as uid 0 rides IS_SANDBOX"

# v1.5.1 STALE BOX: a box created before the mapping was measured must be named
# and told to recreate. Silence it and the user chases unrelated symptoms.
cat > "$SED_TMP" << 'SED'
s|  if \[ -n "$got" \] && \[ "$got" != "$want" \]; then|  if false; then|
SED
try "v1.5.1_stale_box_advisory" "box created under the old mapping is told to recreate" "$CLI" "$DOCKER_COMMANDS_BATS"

# v1.5.1 CACHE KEY: docker resolves DOCKER_HOST before the context. Reading them
# the other way files a measurement under a name that did not choose the daemon.
cat > "$SED_TMP" << 'SED'
s|"${DOCKER_HOST:-${DOCKER_CONTEXT:-default}}"|"${DOCKER_CONTEXT:-${DOCKER_HOST:-default}}"|
SED
try "v1.5.1_uid_map_key_precedence" "DOCKER_HOST decides the key" "$CLI" "$DOCKER_COMMANDS_BATS"

# v1.5.1 ENDPOINT: a number measured against one daemon must not be applied to
# another that happens to share the key.
cat > "$SED_TMP" << 'SED'
s|\[ "$(_box_identity_cached_endpoint)" != "$(_uid_map_endpoint_field)" \]|false|
SED
try "v1.5.1_uid_map_endpoint_revalidated" "measurement taken against another daemon" "$CLI" "$DOCKER_COMMANDS_BATS"

# v1.5.1 CACHE VALIDATION: a corrupt line must re-measure, never become a uid.
cat > "$SED_TMP" << 'SED'
s|  case "$u" in ''\|\*\[!0123456789\]\*) return 1 ;; esac|  :|
SED
try "v1.5.1_uid_map_cache_validated" "corrupt measurement is refused" "$CLI" "$DOCKER_COMMANDS_BATS"

# v1.5.1 PROBE SCOPE: the credential store must never be mounted into a
# container just to learn a number.
cat > "$SED_TMP" << 'SED'
s|-v "$probe:/cleat-uidmap:ro"|-v "$CLEAT_CONFIG_DIR:/cleat-uidmap:ro"|
SED
try "v1.5.1_uid_probe_scope" "never puts the credential store in a container" "$CLI" "$DOCKER_COMMANDS_BATS"

# v1.5.1 DOOMED POLL: a box whose frozen uid can never converge must not cost
# five seconds at the front of every session.
cat > "$SED_TMP" << 'SED'
s|  if \[ -n "$told" \] && \[ "$told" != "$want" \]; then|  if false; then|
SED
try "v1.5.1_remap_skips_doomed_poll" "not polled for five seconds first" "$CLI" "$DOCKER_COMMANDS_BATS"

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
s@ && mv "[$]req" "[$]req.claimed" 2>/dev/null; then@; then@
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

# ═════════════════════════════════════════════════════════════════════════════
# vnext: ports and host-bridge hardening
# ═════════════════════════════════════════════════════════════════════════════

# The clip dir is mounted rw into the box, so every host-side path it can plant
# a symlink at needs a guard. `>>` and `[ -f ]` both follow links.
cat > "$SED_TMP" << 'SED'
/^_browser_watcher()/,/^}$/{
  s|_drop_unless_regular "\$clip_dir/\.proxy-log"|:|
}
SED
try "vnext_proxy_log_symlink" "cannot append to a host file through a planted proxy log symlink"

cat > "$SED_TMP" << 'SED'
/_cap_watcher_log "\$clip_dir\/\.proxy-log" >\/dev\/null/d
SED
try "vnext_proxy_log_symlink_at_start" "a symlink present at watcher start is dropped too" "$CLI" "$BROWSER_BRIDGE_BATS"

# A URL with an embedded newline forged whole log lines.
cat > "$SED_TMP" << 'SED'
s@tr -d '\[:cntrl:\]'@cat@
SED
try "vnext_proxy_log_sanitize" "a URL carrying a newline cannot forge its own log line" "$CLI" "$BROWSER_BRIDGE_BATS"

cat > "$SED_TMP" << 'SED'
/_cap_watcher_log "\$clip_dir\/\.proxy-log" >\/dev\/null/d
SED
try "vnext_proxy_log_cap" "an oversized log is capped at watcher start" "$CLI" "$BROWSER_BRIDGE_BATS"

# The drop must be narrow: only a symlink, only an oversized file.
cat > "$SED_TMP" << 'SED'
/^_drop_unless_regular()/,/^}$/{
  s@if \[ -L "\$p" \]; then@if true; then@
}
SED
try "vnext_proxy_log_drop_not_overbroad" "a real log is never dropped, only a symlink is" "$CLI" "$BROWSER_BRIDGE_BATS"

cat > "$SED_TMP" << 'SED'
/^_cap_watcher_log()/,/^}$/{
  s|_drop_unless_regular "\$log"|:|
}
SED
try "vnext_cap_log_symlink" "cap watcher log does not truncate a host file through a symlink"

# socat's EXEC address does no shell parsing, so the forward never worked.
# Real socat drives these two. Registered only where socat exists: without it
# the paired test skips, and a skipped test reads as a missed mutation (the
# inotifywait precedent below). CI installs socat on every Linux leg.
if command -v socat >/dev/null 2>&1; then
cat > "$SED_TMP" << 'SED'
s@"SYSTEM:docker exec@"EXEC:sh -c 'docker exec@
s@TCP\\\\:localhost\\\\:${port}"@TCP\\\\:localhost\\\\:${port}'"@
SED
try "vnext_socat_system_address" "actually forwards, it is not an EXEC no-op"

# Unescaped colons end a SYSTEM: parameter early: the box received
# `socat -,ignoreeof TCP6` and the IPv4 fallback vanished. The argv-strict stub
# refuses that shape.
cat > "$SED_TMP" << 'SED'
s@TCP6\\\\:localhost\\\\:@TCP6:localhost:@
s@TCP\\\\:localhost\\\\:@TCP:localhost:@
SED
try "vnext_socat_colon_escape" "actually forwards, it is not an EXEC no-op"
fi

# The backend must be a BACKGROUND child or bash defers the trap and the
# loopback port stays bound past session end.
cat > "$SED_TMP" << 'SED'
/2>>"\${log_file:-\/dev\/null}" &$/ s@ &$@@
SED
try "vnext_proxy_backend_background" "a TERM takes the backend down and frees the port" "$CLI" "$BROWSER_BRIDGE_BATS"

cat > "$SED_TMP" << 'SED'
s@ && kill "\$_acp_child" 2>\/dev\/null@@
SED
try "vnext_proxy_trap_kills_child" "a TERM takes the backend down and frees the port" "$CLI" "$BROWSER_BRIDGE_BATS"

# The parser decides which HOST port a caged value makes the host bind.
cat > "$SED_TMP" << 'SED'
/^_extract_callback_port()/,/^}$/{
  s@    localhost|127\.0\.0\.1) ;;@    *) ;;@
}
SED
try "vnext_callback_port_host" "rejects a hostname that merely starts with localhost" "$CLI" "$HOOKS_BATS"

cat > "$SED_TMP" << 'SED'
/\[ "\$port" -ge 1024 \] && \[ "\$port" -le 65535 \] || return 1/d
SED
try "vnext_callback_port_range" "rejects a privileged port" "$CLI" "$HOOKS_BATS"

cat > "$SED_TMP" << 'SED'
/\[ "\${#url}" -le 4096 \] || return 1/d
SED
try "vnext_callback_port_length" "rejects an oversized URL" "$CLI" "$HOOKS_BATS"

cat > "$SED_TMP" << 'SED'
/^_extract_callback_port()/,/^}$/{
  /^    0\*) return 1 ;;$/d
}
SED
try "vnext_callback_port_leading_zero" "rejects a leading-zero port" "$CLI" "$HOOKS_BATS"

# Only an auth URL may make the host bind a box-named port.
cat > "$SED_TMP" << 'SED'
s@ && \[ "\$_is_auth" = 1 \]@@
SED
try "vnext_proxy_auth_gate" "a deferred plain link never binds a host port" "$CLI" "$BROWSER_BRIDGE_BATS"

# The image watcher polls 4x a second for the life of every session.
cat > "$SED_TMP" << 'SED'
s@{ \[ -e "\$req" \] || \[ -L "\$req" \]; } && @@
SED
try "vnext_clipimg_idle_fork" "an idle tick never forks an mv" "$CLI" "$CLIPIMG_BATS"

cat > "$SED_TMP" << 'SED'
s@{ \[ -e "\$req" \] || \[ -L "\$req" \]; } && mv@{ false; } \&\& mv@
SED
try "vnext_clipimg_guard_not_overstrict" "a present request is still claimed" "$CLI" "$CLIPIMG_BATS"

cat > "$SED_TMP" << 'SED'
/^_clipimg_watcher()/,/^}$/{
  s|if \[ -L "\$lock" \]; then|if false; then|
}
SED
try "vnext_image_lock_symlink" "a symlinked image lock is dropped, not followed" "$CLI" "$CLIPIMG_BATS"

cat > "$SED_TMP" << 'SED'
s|_drop_unless_regular "\$clip_dir/\.host-ready"|:|
SED
try "vnext_host_ready_symlink" "host-ready sentinel is replaced"

# wc -c on a link to a character device never returns.
cat > "$SED_TMP" << 'SED'
s@^    _drop_unless_regular "\$hooks_file"$@    :@
SED
try "vnext_hook_spool_symlink" "a symlinked event spool is dropped instead of read through" "$CLI" "$HOOKS_BATS"

cat > "$SED_TMP" << 'SED'
s@^    _drop_unless_regular "\$hooks_file"$@    :@
SED
try "vnext_hook_spool_fifo" "a FIFO planted as the spool is dropped" "$CLI" "$HOOKS_BATS"

cat > "$SED_TMP" << 'SED'
s@if \[ -L "\$hooks_file" \] || { \[ -e "\$hooks_file" \] && \[ ! -f "\$hooks_file" \]; }; then@if false; then@
SED
try "vnext_hook_spool_midsession" "swapped for a symlink mid-session" "$CLI" "$HOOKS_BATS"

# REUSEPORT let a box-named port co-bind a live host service.
cat > "$SED_TMP" << 'SED'
s@srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)@srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)@
SED
try "vnext_proxy_no_reuseport" "does not co-bind an occupied loopback port"

# The documented 100KB clipboard cap has to hold on the HOST too.
cat > "$SED_TMP" << 'SED'
/if \[ "\$_sz" -gt "\$_CLIP_MAX_PAYLOAD" \]; then/,+6d
SED
try "vnext_clip_host_cap" "the host caps an oversized payload at the documented 100KB" "$CLI" "$CLIPBOARD_BRIDGE_BATS"

# Teardown must not swallow a live sibling session's pending login URL.
cat > "$SED_TMP" << 'SED'
s@ && \[ "\$(( \$(date +%s) - \$(_path_mtime "\$bridge_file") ))" -gt 5 \]@@
SED
try "vnext_bridge_sweep_age_gate" "keeps a fresh bridge file for a sibling session" "$CLI" "$BROWSER_BRIDGE_BATS"

cat > "$SED_TMP" << 'SED'
/^_browser_sweep_stale_bridge()/,/^}$/{
  s@if \[ -L "\$bridge_file" \]; then@if false; then@
}
SED
try "vnext_bridge_sweep_symlink" "removes a symlink regardless of age" "$CLI" "$BROWSER_BRIDGE_BATS"

# Every loopback spelling must classify as loopback, and nothing else may.
cat > "$SED_TMP" << 'SED'
s@        ::1|0:0:0:0:0:0:0:1) return 0 ;;@        ::1) return 0 ;;@
SED
try "vnext_ipv6_loopback_expanded" "every loopback spelling is recognised" "$CLI" "$CAPABILITIES_BATS"

cat > "$SED_TMP" << 'SED'
/^_endpoint_is_loopback()/,/^}$/{
  s@          case "\${_v6##\*:}" in \*\[!0-9.\]\*) ;; \*) return 0 ;; esac@          return 0@
}
SED
try "vnext_ipv6_loopback_not_overbroad" "a wildcard or routable IPv6 address stays remote" "$CLI" "$CAPABILITIES_BATS"

# The live --add-host had three tests and no mutation. Pin it before the dead
# helper beside it was deleted, so nothing can quietly ship a no-op there.
cat > "$SED_TMP" << 'SED'
s@host_args+=(--add-host "host.docker.internal:host-gateway")@host_args+=(--label "sh.cleat.nohostgw=1")@
SED
try "vnext_add_host_present" "adds --add-host when not Docker Desktop" "$CLI" "$HOOKS_BATS"

cat > "$SED_TMP" << 'SED'
s@  if ! _is_docker_desktop 2>\/dev\/null; then@  if _is_docker_desktop 2>\/dev\/null; then@
SED
try "vnext_add_host_desktop_gate" "adds --add-host when not Docker Desktop" "$CLI" "$HOOKS_BATS"

# ── verification pass: the second round ──────────────────────────────────────

# Both backends are backgrounded. The socat line was pinned; this pins python.
cat > "$SED_TMP" << 'SED'
/^_auth_callback_proxy()/,/^}$/{
  s|<<'PYEOF' &$|<<'PYEOF'|
}
SED
try "vnext_proxy_python_background" "takes the python backend down too" "$CLI" "$BROWSER_BRIDGE_BATS"

if command -v python3 >/dev/null 2>&1; then
cat > "$SED_TMP" << 'SED'
s|req_data = req_data.replace(b"Connection: keep-alive", b"Connection: close      ")|req_data = req_data|
SED
try "v0.6.4_keepalive_rewrite" "rewrites keep-alive to close before forwarding"
fi

cat > "$SED_TMP" << 'SED'
s@\[\[ \$socat_rc -eq 1 \]\] || break@break@
SED
try "v0.6.4_bind_retry" "retries a busy bind"

# Any shape that is not a regular file is dropped, not just a symlink.
cat > "$SED_TMP" << 'SED'
/^_drop_unless_regular()/,/^}$/{
  s|elif \[ -e "\$p" \] && \[ ! -f "\$p" \]; then|elif false; then|
}
SED
try "vnext_drop_fifo_proxy_log" "a FIFO planted mid-session is dropped" "$CLI" "$BROWSER_BRIDGE_BATS"
cat > "$SED_TMP" << 'SED'
/^_drop_unless_regular()/,/^}$/{
  s|elif \[ -e "\$p" \] && \[ ! -f "\$p" \]; then|elif false; then|
}
SED
try "vnext_drop_fifo_host_ready" "drops a FIFO planted at .host-ready" "$CLI" "$CLIPBOARD_BRIDGE_BATS"
cat > "$SED_TMP" << 'SED'
/^_drop_unless_regular()/,/^}$/{
  s|elif \[ -e "\$p" \] && \[ ! -f "\$p" \]; then|elif false; then|
}
SED
try "vnext_drop_fifo_cap_log" "drops a FIFO instead of leaving it" "$CLI" "$EXEC_CLAUDE_BATS"

cat > "$SED_TMP" << 'SED'
/^_clipimg_watcher()/,/^}$/{
  s|elif \[ -e "\$lock" \] && \[ ! -d "\$lock" \]; then|elif false; then|
}
SED
try "vnext_image_lock_file" "a regular file planted as the image lock" "$CLI" "$CLIPIMG_BATS"

# A directory named `clipboard` used to kill the watcher under set -e.
cat > "$SED_TMP" << 'SED'
/if \[ ! -f "\$claim" \]; then/,+3d
SED
try "vnext_clip_claim_regular_only" "a directory planted as the payload" "$CLI" "$CLIPBOARD_BRIDGE_BATS"

# Teardown sweeps: all three sites, and the liveness gate itself.
cat > "$SED_TMP" << 'SED'
s|_browser_teardown_bridge "\${_CLIP_DIR:?}"|rm -f "${_CLIP_DIR:?}/.browser-open"|
SED
try "vnext_teardown_session_site" "teardown keeps a FRESH browser-open file for a sibling session" "$CLI" "$HOOKS_BATS"
cat > "$SED_TMP" << 'SED'
s|_browser_teardown_bridge "\$_shell_clip_dir"|rm -f "$_shell_clip_dir/.browser-open"|
SED
try "vnext_teardown_shell_site" "shell: teardown keeps a FRESH" "$CLI" "$DOCKER_COMMANDS_BATS"
cat > "$SED_TMP" << 'SED'
s|_browser_teardown_bridge "\$_login_clip_dir"|rm -f "$_login_clip_dir/.browser-open"|
SED
try "vnext_teardown_login_site" "login: teardown keeps a FRESH" "$CLI" "$DOCKER_COMMANDS_BATS"
cat > "$SED_TMP" << 'SED'
/^_browser_teardown_bridge()/,/^}$/{
  s|if ls "\$dir"/.watcher.\* >/dev/null 2>&1; then|if true; then|
}
SED
try "vnext_teardown_solo_unconditional" "teardown removes even a fresh browser-open" "$CLI" "$HOOKS_BATS"

# cleat shell and cleat login cap the watcher log before spawning, as the
# session always did.
cat > "$SED_TMP" << 'SED'
/_cap_watcher_log "\$_shell_clip_dir\/\.watcher-log" >\/dev\/null/d
SED
try "vnext_shell_caps_watcher_log" "shell: caps an oversized watcher log" "$CLI" "$DOCKER_COMMANDS_BATS"
cat > "$SED_TMP" << 'SED'
/_cap_watcher_log "\$_login_clip_dir\/\.watcher-log" >\/dev\/null/d
SED
try "vnext_login_caps_watcher_log" "login: caps an oversized watcher log" "$CLI" "$DOCKER_COMMANDS_BATS"

# The authority ends at '/', '?' or '#'.
cat > "$SED_TMP" << 'SED'
s|authority="\${authority%%\[/?#\]\*}"|authority="${authority%%/*}"|
SED
try "vnext_callback_authority_terminators" "a path-less redirect_uri ending in a query" "$CLI" "$HOOKS_BATS"

# The second userinfo form rides the host check.
cat > "$SED_TMP" << 'SED'
/^_extract_callback_port()/,/^}$/{
  s@    localhost|127\.0\.0\.1) ;;@    *) ;;@
}
SED
try "vnext_callback_port_userinfo_before_host" "rejects userinfo placed before a loopback host" "$CLI" "$HOOKS_BATS"

cat > "$SED_TMP" << 'SED'
s|      case "\$_v6" in \*"\]"\*) ;; \*) return 1 ;; esac     # unclosed bracket|      :|
SED
try "vnext_ipv6_unclosed_bracket" "an unclosed bracket is malformed" "$CLI" "$CAPABILITIES_BATS"

cat > "$SED_TMP" << 'SED'
s|\$open_cmd "\$_clean_url"|$open_cmd "$url"|
SED
try "vnext_opener_clean_url" "the opener never receives a control character" "$CLI" "$BROWSER_BRIDGE_BATS"

cat > "$SED_TMP" << 'SED'
s|if \[ -n "\$_busy" \]; then|if [ -n "" ]; then|
SED
try "vnext_pkg_lock_named" "a busy package manager is named instead" "$CLI" "$REGRESSIONS"

cat > "$SED_TMP" << 'SED'
s|comm="\${comm##\*/}"|comm="$comm"|
SED
try "vnext_pkg_probe_basename" "probe matches a command name" "$CLI" "$REGRESSIONS"

cat > "$SED_TMP" << 'SED'
s|if ! command -v jq >/dev/null 2>&1; then|if false; then|
SED
try "vnext_jqless_empty_settings" "jq-less host gets empty project settings" "$CLI" "$REGRESSIONS"

cat > "$SED_TMP" << 'SED'
s|cap_is_active hooks 2>/dev/null && ! command -v jq >/dev/null 2>&1; then|cap_is_active hooks 2>/dev/null \&\& false; then|
SED
try "vnext_jqless_hooks_notice" "says so on a host with no jq" "$CLI" "$REGRESSIONS"

# vnext: the clipboard POLL branch must fire on any planted shape, not just a
# regular file. With -f a planted DIRECTORY is skipped, lingers in the shared
# dir and swallows every later copy, because `mv payload clipboard` then moves
# the payload INSIDE it. Only the poll branch had this hole; inotify and fswatch
# fire on the event, not the shape, which is why the test was green when written
# on a host that had inotifywait. Revert to -f; the planted-directory test fails.
cat > "$SED_TMP" << 'SED'
s@|| \[ -e "\$clip_dir/clipboard" \]@|| [ -f "$clip_dir/clipboard" ]@
SED
try "vnext_clip_poll_drops_directory" "directory planted as the payload" "$CLI" "$CLIPBOARD_BRIDGE_BATS"

# vnext: _derive_project_session_key must pin the locale, like _claude_session_key
cat > "$SED_TMP" << 'SED'
/^_derive_project_session_key()/,/^}$/{
  s/| LC_ALL=C tr /| tr /
  s/| LC_ALL=C sed /| sed /
}
SED
try "vnext_session_key_locale_pin" "session key is derived under a pinned C locale"

# ── cleat sessions (concept/43) ────────────────────────────────────────────
# Every mutation here reverts one guard that keeps a delete inside the strict
# UUID allowlist. The session directory also holds the user's auto-memory and
# cleat's own bind-mounted history.jsonl, so a missed guard is data loss.

# The UUID allowlist is what stops history.jsonl, memory/ and agent scratch
# directories from being treated as sessions.
cat > "$SED_TMP" << 'SED'
/^_sessions_is_uuid()/,/^}$/{
  s/    \*) return 1 ;;/    *) return 0 ;;/
}
SED
try "vnext_sessions_uuid_allowlist" "scan never lists history.jsonl" "$CLI" "$SESSIONS_BATS"

# history.jsonl is asserted by name on top of the UUID test, because it is
# cleat's own file and a live bind source for every running box.
cat > "$SED_TMP" << 'SED'
/^_sessions_path_under_key()/,/^}$/{
  s/  case "\$base" in ''|\.|\.\.|history\.jsonl) return 1 ;; esac/  case "$base" in ''|.|..) return 1 ;; esac/
}
SED
try "vnext_sessions_history_excluded" "containment refuses history.jsonl by name" "$CLI" "$SESSIONS_BATS"

# Textual prefix alone is not containment: it cannot resolve '..'.
cat > "$SED_TMP" << 'SED'
/^_sessions_path_under_key()/,/^}$/{
  s/^  \[\[ "\$parent_p" == "\$root_p" \]\]/  return 0/
}
SED
try "vnext_sessions_physical_parent" "containment refuses a traversal out of the key dir" "$CLI" "$SESSIONS_BATS"

# A symlinked transcript would let a delete reach any file on the host.
cat > "$SED_TMP" << 'SED'
/^_sessions_path_under_key()/,/^}$/{
  /\[\[ -L "\$target" \]\] && return 1/d
}
SED
try "vnext_sessions_symlink_refused" "containment refuses a symlink" "$CLI" "$SESSIONS_BATS"

# The sidecar directory is most of a session's bytes, and holds its subagent
# transcripts. Deleting only the .jsonl leaks it and lies about the reclaim.
cat > "$SED_TMP" << 'SED'
/^_sessions_delete_set()/,/^}$/{
  /printf '%s\\n' "\${sdir}\/\${uuid}"$/d
}
SED
try "vnext_sessions_deletes_sidecar" "delete moves the transcript AND its sidecar" "$CLI" "$SESSIONS_BATS"

# A down daemon cannot say whether the box is running, so it must refuse.
cat > "$SED_TMP" << 'SED'
/^_sessions_live_gate()/,/^}$/{
  s/^  if ! _daemon_up; then/  if false; then/
}
SED
try "vnext_sessions_daemon_gate" "down daemon refuses the write" "$CLI" "$SESSIONS_BATS"

# A box with a live agent is still appending to the transcript.
cat > "$SED_TMP" << 'SED'
/^_sessions_live_gate()/,/^}$/{
  s/^  if container_exists "\$cname" \&\& is_running "\$cname" \&\& _box_has_live_agent "\$cname"; then/  if false; then/
}
SED
try "vnext_sessions_live_agent_gate" "live agent refuses the write" "$CLI" "$SESSIONS_BATS"

# Without the tty check, a pipe satisfies the confirmation.
cat > "$SED_TMP" << 'SED'
/^_sessions_do_delete()/,/^}$/{
  s/^    if ! _is_interactive; then/    if false; then/
}
SED
try "vnext_sessions_noninteractive_skip" "no tty and no --yes discloses and deletes nothing" "$CLI" "$SESSIONS_BATS"

# Delete must be a move into the trash, never an unlink.
cat > "$SED_TMP" << 'SED'
/^_sessions_trash()/,/^}$/{
  s/^    if ! mv "\$p" "\$target" 2>\/dev\/null; then/    if ! rm -rf "$p"; then/
}
SED
try "vnext_sessions_trash_not_unlink" "delete is a move, not an unlink" "$CLI" "$SESSIONS_BATS"

# A rename that moves the mtime changes which conversation resumes next.
cat > "$SED_TMP" << 'SED'
/^_sessions_rename_write()/,/^}$/{
  /touch -r "\$stamp" "\$f" 2>\/dev\/null \|\| true/d
}
SED
try "vnext_sessions_rename_keeps_mtime" "rename leaves the transcript mtime alone" "$CLI" "$SESSIONS_BATS"

# The title whitelist is the only thing stopping a forged record.
cat > "$SED_TMP" << 'SED'
/^_sessions_title_ok()/,/^)$/{
  /\*\[\\"\\\\\]\*)  return 1 ;;/d
}
SED
try "vnext_sessions_title_whitelist" "a backslash in a title is refused" "$CLI" "$SESSIONS_BATS"

# The viewport must be sized from the terminal, not from a constant.
cat > "$SED_TMP" << 'SED'
s/^_SESSIONS_CHROME_LINES=8$/_SESSIONS_CHROME_LINES=4/
SED
try "vnext_sessions_chrome_budget" "frame fills the terminal height when the list is longer" "$CLI" "$SESSIONS_BATS"

# The viewport must never be taller than the list.
cat > "$SED_TMP" << 'SED'
/^_sessions_measure()/,/^}$/{
  s/^  if \[\[ "\$total" -lt "\$avail" \]\]; then/  if false; then/
}
SED
try "vnext_sessions_page_fits_list" "viewport never exceeds the number of sessions" "$CLI" "$SESSIONS_BATS"

# Erasing a line BEFORE its replacement text is the blink.
cat > "$SED_TMP" << 'SED'
/^_sessions_frame()/,/^}$/{
  s|buf="\${buf}\${line}.033\[K.n"|buf="${buf}\\033[2K${line}\\n"|
}
SED
try "vnext_sessions_no_leading_erase" "frame never blanks a line before rewriting" "$CLI" "$SESSIONS_BATS"

# The cursor clamp is what stops a shrink leaving the highlight off-screen,
# with ENTER still armed over a row the user cannot see.
cat > "$SED_TMP" << 'SED'
/^_sessions_clamp()/,/^}$/{
  s/^  (( _SESS_OFFSET < _SESS_CURSOR - _SESS_PAGE + 1 )) && _SESS_OFFSET=.*/  :/
}
SED
try "vnext_sessions_cursor_clamp" "shrunk viewport pulls the cursor back into view" "$CLI" "$SESSIONS_BATS"

# stty must be read before tput: an exported LINES poisons tput via use_env and
# would freeze the viewport at its launch size.
cat > "$SED_TMP" << 'SED'
/^_term_size()/,/^}$/{
  s|^  sz="\$(stty size 2>/dev/null .. true)"|  sz=""|
}
SED
try "vnext_sessions_stty_first" "_term_size prefers the live stty reading" "$CLI" "$SESSIONS_BATS"

# A zero or leading-zero size must not reach (( )).
cat > "$SED_TMP" << 'SED'
/^_term_size()/,/^}$/{
  s/case "\$rows" in ..|0\*|\*\[!0-9\]\*) rows="" ;; esac/case "$rows" in ""|*[!0-9]*) rows="" ;; esac/
  s/case "\$cols" in ..|0\*|\*\[!0-9\]\*) cols="" ;; esac/case "$cols" in ""|*[!0-9]*) cols="" ;; esac/
}
SED
try "vnext_sessions_zero_size_rejected" "_term_size rejects a zero size" "$CLI" "$SESSIONS_BATS"

# The action screen must be width-managed or it walks on a narrow terminal.
cat > "$SED_TMP" << 'SED'
/^_sessions_action_draw()/,/^}$/{
  /\[\[ \${#desc} -gt \$room \]\] && desc=/d
}
SED
try "vnext_sessions_action_width" "action screen never exceeds the terminal width" "$CLI" "$SESSIONS_BATS"

# Without truncation a long title wraps, the frame emits more physical lines
# than the reposition moves up, and the block walks down the screen.
cat > "$SED_TMP" << 'SED'
/^_sessions_frame()/,/^}$/{
  /\[\[ \${#t} -gt \$rm \]\] && t=/d
}
SED
try "vnext_sessions_row_truncated" "a long title is truncated to the terminal width" "$CLI" "$SESSIONS_BATS"

# A title is model-written text drawn on the host terminal.
cat > "$SED_TMP" << 'SED'
/^_sessions_safe_str()/,/^}$/{
  s@^  v="[$](printf .%s. "[$]1" | LC_ALL=C tr -d ..000-.037.177.)"$@  v="$1"@
}
SED
try "vnext_sessions_title_sanitized" "a newline in a title cannot split the row" "$CLI" "$SESSIONS_BATS"

# A short prefix is how you delete the wrong conversation.
cat > "$SED_TMP" << 'SED'
/^_sessions_id_shape()/,/^}$/{
  s/^  \[\[ \${#1} -ge 8 \]\] || return 3/  [[ ${#1} -ge 1 ]] || return 3/
}
SED
try "vnext_sessions_id_min_length" "a prefix shorter than 8 is refused" "$CLI" "$SESSIONS_BATS"

# An ambiguous prefix must refuse, never pick the first match.
cat > "$SED_TMP" << 'SED'
/^_sessions_resolve_id()/,/^}$/{
  s/^    \*) for m in "\${matches\[@\]}"; do printf '%s\\n' "\$m"; done; return 4 ;;/    *) printf '%s' "${matches[0]}"; return 0 ;;/
}
SED
try "vnext_sessions_ambiguous_refused" "an ambiguous prefix is refused rather than guessed" "$CLI" "$SESSIONS_BATS"

# The transcript record is the one the picker reads; a sidecar-only write is
# silently shadowed.
cat > "$SED_TMP" << 'SED'
/^_sessions_rename_write()/,/^}$/{
  /printf '{"type":"custom-title","customTitle":"%s","sessionId":"%s"}\\n' "\$title" "\$uuid" >> "\$f" || return 1/d
}
SED
try "vnext_sessions_rename_writes_record" "rename appends a custom-title record" "$CLI" "$SESSIONS_BATS"

# A bare `stty echo` on restore discards every other terminal setting.
cat > "$SED_TMP" << 'SED'
/^_tui_echo_restore()/,/^}$/{
  s/stty "\$_SESS_STTY"/stty echo/
}
SED
try "vnext_sessions_echo_full_state" "echo-restore puts the saved state back verbatim" "$CLI" "$SESSIONS_BATS"

# Echo must actually be turned off, or held arrows print into the frame.
cat > "$SED_TMP" << 'SED'
/^_tui_echo_off()/,/^}$/{
  /stty -echo 2>\/dev\/null .. true/d
}
SED
try "vnext_tui_echo_off" "echo-off saves the whole termios state" "$CLI" "$SESSIONS_BATS"

# A narrow terminal must fall back to the text list, not render wrapping rows.
cat > "$SED_TMP" << 'SED'
s/^_SESSIONS_MIN_COLS=40$/_SESSIONS_MIN_COLS=1/
SED
try "vnext_sessions_min_cols_gate" "terminal too narrow for a row is refused" "$CLI" "$SESSIONS_BATS"

# The narrow check must read the RAW width; _term_cols floors at 40 and so can
# never report a narrower terminal.
cat > "$SED_TMP" << 'SED'
/^_sessions_too_narrow()/,/^}$/{
  s|^  c="\$(_term_size)"|  c="$(_term_cols)"|
  /c="\${c#\* }"/d
}
SED
try "vnext_sessions_narrow_raw_width" "narrow check reads the raw width" "$CLI" "$SESSIONS_BATS"

# A frame that shrank leaves the taller frame's tail painted below it.
cat > "$SED_TMP" << 'SED'
/^_sessions_picker_tui()/,/^}$/{
  s/printf .\\033\[J./:/
}
SED
try "vnext_sessions_shrink_erase" "frame that shrank erases the taller frame" "$CLI" "$SESSIONS_BATS"

# A rename APPENDS, so it needs the same containment guard a delete has.
cat > "$SED_TMP" << 'SED'
/^_sessions_do_rename()/,/^}$/{
  s/^  if ! _sessions_path_under_key "\${sdir}\/\${uuid}.jsonl" "\$sdir"; then/  if false; then/
}
SED
try "vnext_sessions_rename_containment" "rename refuses a symlinked transcript" "$CLI" "$SESSIONS_BATS"

# printf pads to nine but does not truncate to it, so a 10-character age or
# size pushes every row one column past the terminal and wraps it.
cat > "$SED_TMP" << 'SED'
s/%-9.9s %9.9s/%-9s %9s/g
SED
try "vnext_sessions_meta_col_clamp" "absurd age cannot push a full row past" "$CLI" "$SESSIONS_BATS"

# The sidecar is written inside the box, so an unbounded read is a lever on
# host memory.
cat > "$SED_TMP" << 'SED'
/^_sessions_title_for()/,/^}$/{
  s/head -c "\$_SESSIONS_TITLE_WINDOW" "\${sdir}\/\${uuid}\/custom-title.json"/cat "${sdir}\/${uuid}\/custom-title.json"/
}
SED
try "vnext_sessions_sidecar_window" "sidecar title is read through the same window" "$CLI" "$SESSIONS_BATS"

# A symlinked sidecar must be refused, not followed.
cat > "$SED_TMP" << 'SED'
/^_sessions_title_for()/,/^}$/{
  s/ \&\& \[\[ ! -L "\${sdir}\/\${uuid}\/custom-title.json" \]\]//
}
SED
try "vnext_sessions_sidecar_symlink" "symlinked sidecar title file is refused" "$CLI" "$SESSIONS_BATS"

# The trash DESTINATION needs containment too, not only the sources.
cat > "$SED_TMP" << 'SED'
/^_sessions_trash_dir()/,/^}$/{
  s/^  if \[\[ -L "\$d" \]\]; then/  if false; then/
}
SED
try "vnext_sessions_trash_symlink" "symlinked trash directory is refused" "$CLI" "$SESSIONS_BATS"

# A poisoned trash must REFUSE the delete, not report success.
cat > "$SED_TMP" << 'SED'
/^_sessions_do_delete()/,/^}$/{
  s/^  if \[\[ \$_trc -eq 2 \]\]; then/  if false; then/
}
SED
try "vnext_sessions_trash_refusal_fails" "delete refuses rather than trashing through" "$CLI" "$SESSIONS_BATS"

# Five delete-set paths end in a bare <uuid>; a flat basename buries them.
cat > "$SED_TMP" << 'SED'
/^_sessions_trash()/,/^}$/{
  s/^        target="\${dest}\/ext\${idx}-\${base}" ;;/        target="${dest}\/${base}" ;;/
}
SED
try "vnext_sessions_trash_namespace" "trashed items outside the key dir do not collide" "$CLI" "$SESSIONS_BATS"

# Restore must refuse an ambiguous prefix, like every other id path. Turning
# the refusal status into success is exactly the old behaviour: pick one.
cat > "$SED_TMP" << 'SED'
/^_sessions_restore_resolve()/,/^}$/{
  s/done; return 4 ;;/done; return 0 ;;/
}
SED
try "vnext_sessions_restore_ambiguous" "restore refuses an ambiguous prefix" "$CLI" "$SESSIONS_BATS"

# The line-oriented render sites must clamp the title to one row.
cat > "$SED_TMP" << 'SED'
s/_sessions_safe_title "\$title"/_sessions_safe_str "$title"/
SED
try "vnext_sessions_confirm_title_clamp" "huge title cannot scroll the delete confirmation" "$CLI" "$SESSIONS_BATS"

# The cursor-up count must equal the frame's physical line count, or the block
# walks down the screen one row per keypress.
cat > "$SED_TMP" << 'SED'
/^_sessions_picker_tui()/,/^}$/{
  s/^    block=\$(( _SESS_PAGE + 3 ))/    block=$(( _SESS_PAGE + 2 ))/
}
SED
try "vnext_sessions_updown_balance" "loop moves up exactly as many lines" "$CLI" "$SESSIONS_BATS"

# A $(printf ...) per row is a fork per row, which is most of what the redraw
# rewrite removed.
cat > "$SED_TMP" << 'SED'
/^_sessions_frame()/,/^}$/{
  s/^      printf -v meta /      meta=$(printf /
  s/"\${_SESS_SIZE\[\$n\]}"$/"${_SESS_SIZE[$n]}")/
}
SED
try "vnext_sessions_frame_no_fork" "frame forks nothing per row" "$CLI" "$SESSIONS_BATS"

# A window narrowed mid-session must leave the picker, not draw wrapping rows.
# Six spaces: the KEY LOOP's gate. The one at four is the redraw's, guarded by
# vnext_sessions_narrow_on_redraw.
cat > "$SED_TMP" << 'SED'
/^_sessions_picker_tui()/,/^}$/{
  s/^      if \[\[ "\$_SESS_NARROW" == "1" \]\]; then$/      if false; then/
}
SED
try "vnext_sessions_narrow_midsession" "narrowing the window mid-session leaves" "$CLI" "$SESSIONS_BATS"

# The frame must normalise hostile numbers rather than index an array with them.
cat > "$SED_TMP" << 'SED'
/^_sessions_frame()/,/^}$/{
  s/^  (( offset < 0 )) \&\& offset=0/  :/
}
SED
try "vnext_sessions_frame_offset_guard" "frame normalises a hostile offset" "$CLI" "$SESSIONS_BATS"

# The restore trap must be armed WITH the echo-off, before the row load can
# fail under set -e and exit with the terminal unable to echo.
cat > "$SED_TMP" << 'SED'
/^_sessions_picker_tui()/,/^}$/{
  /trap ._tui_echo_restore; _cursor_show. EXIT/d
}
SED
try "vnext_sessions_echo_exit_trap" "failure during the row load still restores" "$CLI" "$SESSIONS_BATS"

# The mtime re-check closes the window between reading the list and confirming.
cat > "$SED_TMP" << 'SED'
/^_sessions_do_delete()/,/^}$/{
  s/^  if \[\[ "\$mt_now" != "\$mt_before" \]\]; then/  if false; then/
}
SED
try "vnext_sessions_toctou_guard" "a transcript that changed since the scan aborts" "$CLI" "$SESSIONS_BATS"

# ── staying in the tool, the trash view, and the cached rows ───────────────
#
# Everything below guards the second pass over `cleat sessions`: an action
# redraws the list you were on instead of ending the verb, the trash is a
# second view of the same picker, and the row cache is folded rather than
# rescanned.

# Ending the verb on an action is the bug this pass fixed. Turning the loop's
# break back into a return puts it straight back.
cat > "$SED_TMP" << 'SED'
/^_sessions_picker_tui()/,/^}$/{
  s/^          break ;;$/          return 0 ;;/
}
SED
try "vnext_sessions_stays_open" "a rename redraws the list instead of ending the verb" "$CLI" "$SESSIONS_BATS"

# Backing out of the action screen must NOT count as an action: it printed
# nothing, so the picker redraws in place and a later q is still a cancel.
cat > "$SED_TMP" << 'SED'
/^_sessions_action_tui()/,/^}$/{
  s/^          return 1$/          return 0/
  s/^        return 1 ;;$/        return 0 ;;/
}
SED
try "vnext_sessions_backout_is_not_an_action" "backing out of the action screen says nothing" "$CLI" "$SESSIONS_BATS"

# The back-out walks up over exactly the three lines this screen printed above
# its menu. A wrong count leaves a copy of the menu above the redrawn list.
cat > "$SED_TMP" << 'SED'
/^_sessions_action_backout()/,/^}$/{
  s/%dA' "[$]_SESSIONS_ACTION_HEAD"/%dA' 2/
}
SED
try "vnext_sessions_backout_walk" "the action back-out walks back over its own three header lines" "$CLI" "$SESSIONS_BATS"

# The header is part of the viewport budget, so it is reprinted under every
# receipt. Without it the list redraws with no idea what it is listing.
cat > "$SED_TMP" << 'SED'
/^_sessions_picker_tui()/,/^}$/{
  s/^            _sessions_header "[$]sdir" "[$]project" "[$]box"$/            :/
  s/^              _sessions_header "[$]sdir" "[$]project" "[$]box"$/              :/
}
SED
try "vnext_sessions_header_reprint" "the header is reprinted under an action" "$CLI" "$SESSIONS_BATS"

# A delete must leave the cached rows, or the list comes back still showing a
# conversation that is now in the trash.
cat > "$SED_TMP" << 'SED'
/^_sessions_row_apply()/,/^}$/{
  s/'[$]3 != u'/'1'/
}
SED
try "vnext_sessions_fold_delete" "a delete is folded out of the cached rows" "$CLI" "$SESSIONS_BATS"

# A rename must replace the title in place and touch nothing else, because the
# mtime is restored by the writer and the sort order therefore cannot move.
cat > "$SED_TMP" << 'SED'
/^_sessions_row_apply()/,/^}$/{
  s/{ [$]4 = t }/{ }/
}
SED
try "vnext_sessions_fold_rename" "a rename is folded into the cached rows" "$CLI" "$SESSIONS_BATS"

# A restored session goes back in its sorted position, not on the end.
cat > "$SED_TMP" << 'SED'
/^_sessions_row_insert()/,/^}$/{
  s/| sort -t .*-k1,1rn >/| cat >/
}
SED
try "vnext_sessions_insert_sorted" "a restored session is inserted in its sorted position" "$CLI" "$SESSIONS_BATS"

# The restore path has to put the row back into the LIVE list, or switching
# back shows a session that is no longer in the trash and not in the list.
cat > "$SED_TMP" << 'SED'
/^_sessions_picker_tui()/,/^}$/{
  s/^              _sessions_row_insert "[$]rowfile" "[$]sdir" "[$]uuid" || true$/              :/
}
SED
try "vnext_sessions_restore_rejoins" "a restored session is back in the live list" "$CLI" "$SESSIONS_BATS"

# The trash rows are cached too, so a delete has to mark them stale.
cat > "$SED_TMP" << 'SED'
/^_sessions_picker_tui()/,/^}$/{
  s/^              \[\[ "[$]{_SESS_ACTED:-}" == "delete" \]\] && trash_stale=1$/              :/
}
SED
try "vnext_sessions_trash_stale" "the trash view shows a session deleted in the same run" "$CLI" "$SESSIONS_BATS"

# Only <epoch>-<uuid> is a trash entry. Dropping the stamp check lets any
# directory whose tail happens to be a uuid be listed as a deleted session.
cat > "$SED_TMP" << 'SED'
/^_sessions_trash_scan()/,/^}$/{
  s/^    case "[$]stamp" in ''|\*\[!0-9\]\*) continue ;; esac$/    :/
}
SED
try "vnext_sessions_trash_scan_stamp" "the trash scan ignores anything not named epoch-uuid" "$CLI" "$SESSIONS_BATS"

# And dropping the uuid check lets a stamped directory of anything be listed.
cat > "$SED_TMP" << 'SED'
/^_sessions_trash_scan()/,/^}$/{
  s/^    _sessions_is_uuid "[$]uuid" || continue$/    :/
}
SED
try "vnext_sessions_trash_scan_uuid" "the trash scan ignores anything not named epoch-uuid" "$CLI" "$SESSIONS_BATS"

# The age column in the trash is how long ago it was DELETED, which is also how
# long is left before the sweep takes it. The transcript's own mtime is not it.
cat > "$SED_TMP" << 'SED'
/^_sessions_trash_scan()/,/^}$/{
  s/"[$]stamp" "[$]kb"/"0" "$kb"/
}
SED
try "vnext_sessions_trash_scan_stamp_column" "the trash scan dates a row by when it was deleted" "$CLI" "$SESSIONS_BATS"

# The count decides whether the live list advertises the trash at all, so it
# has to count exactly what the scan would list.
cat > "$SED_TMP" << 'SED'
/^_sessions_trash_count()/,/^}$/{
  s/^      case "[$]{base%%-\*}" in ''|\*\[!0-9\]\*) continue ;; esac$/      :/
}
SED
try "vnext_sessions_trash_count_stamp" "the trash count counts only real entries" "$CLI" "$SESSIONS_BATS"

cat > "$SED_TMP" << 'SED'
/^_sessions_trash_count()/,/^}$/{
  s/^      _sessions_is_uuid "[$]{base#\*-}" || continue$/      :/
}
SED
try "vnext_sessions_trash_count_uuid" "the trash count counts only real entries" "$CLI" "$SESSIONS_BATS"

# The counter line is the only place the view names itself.
cat > "$SED_TMP" << 'SED'
/^_sessions_frame()/,/^}$/{
  s/^  if \[\[ "[$]_SESS_VIEW" == "trash" \]\]; then$/  if false; then/
}
SED
try "vnext_sessions_counter_view" "the trash view names itself on the counter line" "$CLI" "$SESSIONS_BATS"

# An empty trash is nothing to offer, and the affordance appearing at zero is
# how a reader learns a key that does nothing useful.
cat > "$SED_TMP" << 'SED'
/^_sessions_frame()/,/^}$/{
  s/^    if \[\[ "[$]{_SESS_TRASH_N:-0}" -gt 0 \]\]; then$/    if true; then/
}
SED
try "vnext_sessions_trash_affordance" "the live view advertises the trash only when it holds something" "$CLI" "$SESSIONS_BATS"

# The hint has to name the action the view actually performs: Enter deletes in
# one and restores in the other.
cat > "$SED_TMP" << 'SED'
/^_sessions_frame()/,/^}$/{
  s/⏎ restore  ← back/⏎ rename or delete/
}
SED
try "vnext_sessions_hint_view" "the hint line names the action the view actually performs" "$CLI" "$SESSIONS_BATS"

# The hint line is already as wide as the picker's own minimum, which is why
# the trash is advertised on the counter line instead. One more word here and
# every row of the narrowest supported terminal wraps.
cat > "$SED_TMP" << 'SED'
/^_sessions_frame()/,/^}$/{
  s/⏎ rename or delete  q close/⏎ rename or delete  → trash  q close/
}
SED
try "vnext_sessions_hint_width" "neither hint line is wider than the picker" "$CLI" "$SESSIONS_BATS"

# The arrow keys are directional on purpose: the trash is to the right of the
# sessions and nowhere else.
cat > "$SED_TMP" << 'SED'
s/^        RIGHT)$/        RIGHT|LEFT)/
SED
try "vnext_sessions_arrow_direction" "the left arrow does nothing on the live list" "$CLI" "$SESSIONS_BATS"

# Deleting the last session must not drop the user at a shell prompt with an
# undo command to retype. The trash is the only place it can be got back from.
cat > "$SED_TMP" << 'SED'
/^_sessions_picker_tui()/,/^}$/{
  s/^      if \[\[ "[$]{_SESS_TRASH_N:-0}" -gt 0 \]\]; then$/      if false; then/
}
SED
try "vnext_sessions_last_delete_shows_trash" "deleting the last session shows the trash rather than leaving" "$CLI" "$SESSIONS_BATS"

# Both markers exist so the picker can fold an action into its rows. Without
# them every action either rescans or shows a stale list.
cat > "$SED_TMP" << 'SED'
/^_sessions_do_rename()/,/^}$/{
  s/^    _SESS_ACTED="rename"$/    :/
}
SED
try "vnext_sessions_rename_marker" "a rename marks what it changed" "$CLI" "$SESSIONS_BATS"

cat > "$SED_TMP" << 'SED'
/^_sessions_do_delete()/,/^}$/{
  s/^  _SESS_ACTED="delete"$/  :/
}
SED
try "vnext_sessions_delete_marker" "a delete marks what it changed" "$CLI" "$SESSIONS_BATS"

cat > "$SED_TMP" << 'SED'
/^_sessions_do_restore()/,/^}$/{
  s/^  if _sessions_restore "[$]sdir" "[$]uuid"; then$/  if false; then/
}
SED
try "vnext_sessions_restore_action" "the restore action puts the transcript back" "$CLI" "$SESSIONS_BATS"

# The non-TTY path is the one place a deleted session could be invisible.
cat > "$SED_TMP" << 'SED'
/^_sessions_picker_text()/,/^}$/{
  s/^    if \[\[ "[$]tn" -gt 0 \]\]; then$/    if false; then/
}
SED
try "vnext_sessions_text_trash_note" "the text fallback points at the trash when it holds something" "$CLI" "$SESSIONS_BATS"

# And `cleat session trash` is how the ids get read without a terminal.
cat > "$SED_TMP" << 'SED'
s/^    trash)     sub="trash"; shift ;;$/    trashx)    sub="trash"; shift ;;/
SED
try "vnext_sessions_trash_subcommand" "cleat session trash lists what was deleted" "$CLI" "$SESSIONS_BATS"

# The picker re-arms the terminal once per list screen and a view switch breaks
# back to it without restoring first, so saving the termios state twice records
# the already echo-off state as the original and leaves the user unable to type.
cat > "$SED_TMP" << 'SED'
/^_tui_echo_off()/,/^}$/{
  s/^  if \[\[ -z "[$]{_SESS_STTY:-}" \]\]; then$/  if true; then/
}
SED
try "vnext_tui_echo_off_idempotent" "switching views does not poison the saved terminal state" "$CLI" "$SESSIONS_BATS"

# A window can be narrowed while a rename prompt is waiting for a line of
# input, so the redraw refuses as well as the key loop.
cat > "$SED_TMP" << 'SED'
/^_sessions_picker_tui()/,/^}$/{
  s/^    if \[\[ "[$]_SESS_NARROW" == "1" \]\]; then$/    if false; then/
}
SED
try "vnext_sessions_narrow_on_redraw" "a window narrowed during an action leaves before drawing" "$CLI" "$SESSIONS_BATS"

# ── cleat account ──────────────────────────────────────────────────────────
#
# Every guard below is silent when it breaks: a login that vanishes, a token
# written world-readable, a switch that the Mac quietly undoes eight hours
# later. None of them announce themselves, which is exactly why they each earn
# a mutation rather than only a test.

# The whole feature IS this env var. Without it a pinned box reads the shared
# store and the switch is a no-op that reports success.
# Retargeted for M3: the account block moved from exec_claude into
# _exec_claude_prepare_account (O3), so the applier call is now `|| true`.
# Protected before: the store-env application in exec_claude's account block.
cat > "$SED_TMP" << 'SED'
/^_exec_claude_prepare_account()/,/^}$/{
  s@^  _account_apply_exec_env "[$]cname" || true$@  :@
}
SED
try "vnext_account_env_var" "a pinned box gets the credential store env var" "$CLI" "$ACCOUNTS_BATS"

# And the default sentinel must set NOTHING, or every box that never runs the
# verb is a silent migration.
cat > "$SED_TMP" << 'SED'
/^_account_apply_exec_env()/,/^}$/{
  s@^  \[\[ "[$]acct" != "[$]_ACCOUNT_DEFAULT" \]\] .. return 0$@  :@
}
SED
try "vnext_account_default_sets_nothing" "an unpinned box gets no credential store env var" "$CLI" "$ACCOUNTS_BATS"

# The macOS seed compares token EXPIRY and never identity, so leaving it armed
# for a pinned box restores the Keychain's account about eight hours later.
# Retargeted for M3: the seed guard moved into _exec_claude_prepare_account (O3)
# and keys on _EC_PINNED (the login the exec really gets), not _pinned_account.
# Protected before: the seed's default-only guard in exec_claude's account block.
cat > "$SED_TMP" << 'SED'
s/^  if \[\[ "[$]_EC_PINNED" == "[$]_ACCOUNT_DEFAULT" \]\]; then$/  if true; then/
SED
try "vnext_account_seed_skipped" "a pinned box skips the macOS Keychain seed" "$CLI" "$ACCOUNTS_BATS"

# No mount, no store: /login would create it inside the container filesystem
# where cleat rm destroys it.
cat > "$SED_TMP" << 'SED'
s|^    -v "[$]CLEAT_RUN_DIR/[$]{cname}/auth:[$]{_ACCOUNT_BOX_DIR}"$|    -v "/dev/null:/dev/null"|
SED
try "vnext_account_mount" "the per-box auth directory is mounted into the container" "$CLI" "$ACCOUNTS_BATS"

# A missing bind SOURCE makes Docker create a directory at the target. That is
# the failure that once broke git host-wide.
cat > "$SED_TMP" << 'SED'
s/^  mkdir -p "[$]_auth_dir"$/  :/
SED
try "vnext_account_mount_source" "the per-box auth directory is created before any docker run" "$CLI" "$ACCOUNTS_BATS"

# A wipe that does not harvest throws away a token the account has no other
# copy of, and lands the user back on /login.
cat > "$SED_TMP" << 'SED'
/^_account_wipe_run_dir()/,/^}$/{
  s@^  _account_sync_out_locked "[$]cname" .. rc=[$]?$@  :@
}
SED
try "vnext_account_wipe_harvests" "wiping a box run dir harvests first" "$CLI" "$ACCOUNTS_BATS"

# Newest wins, keyed on expiresAt. Flipping the comparison silently downgrades
# the stored credential to an older one on every attach.
cat > "$SED_TMP" << 'SED'
/^_account_harvest_from()/,/^}$/{
  s/^  if \[\[ "[$]be" -le "[$]se" \]\]; then$/  if [[ "$be" -ge "$se" ]]; then/
}
SED
try "vnext_account_harvest_newest_wins" "harvesting never replaces a newer stored credential" "$CLI" "$ACCOUNTS_BATS"

cat > "$SED_TMP" << 'SED'
/^_account_sync_in_locked()/,/^}$/{
  s@^    elif _account_staged_absorbed "[$]snap" "[$]store_cred"; then$@    elif false; then@
}
SED
try "vnext_account_stage_newest_wins" "staging never overwrites a newer credential the box refreshed" "$CLI" "$ACCOUNTS_BATS"

# An account with no credential IS the clean scope. The attach no longer clears
# a staged file on an empty store (it can be the only copy of a login made in
# the box), so the switch's own drop is the one thing that keeps the account
# being LEFT out of the new account's store.
cat > "$SED_TMP" << 'SED'
/^_account_switch_locked()/,/^}$/{
  s@^  if \[\[ "[$]current" != "[$]acct" \]\]; then$@  if false; then@
}
SED
try "vnext_account_clean_scope" "switching from a logged-in account to a new one leaves nothing staged" "$CLI" "$ACCOUNTS_BATS"

# A credential at the host default umask is readable by anything on the machine
# and it is live for weeks. BOTH mechanisms are removed here on purpose: the
# umask subshell and the chmod each produce 0600 on their own, so removing
# either alone is invisible. What the test pins is the outcome.
cat > "$SED_TMP" << 'SED'
/^_account_write_file_0600()/,/^}$/{
  s#umask 077#umask 022#
  s#^  chmod 600 "[$]tmp" 2>/dev/null .. true$#  :#
  s#^  tmp="[$](mktemp .*#  tmp="${dest}.tmp.$$"#
}
SED
try "vnext_account_cred_mode" "a new store is 0700 and its credential 0600" "$CLI" "$ACCOUNTS_BATS"

# Claude Code's store opens with O_NOFOLLOW and reports "no credentials" on a
# symlink, so this failure is silent in both directions.
cat > "$SED_TMP" << 'SED'
/^_account_dir_ok()/,/^}$/{
  s/^  \[\[ -L "[$]d" \]\] && return 1$/  :/
}
SED
try "vnext_account_symlink_store" "a symlinked store is refused, not followed" "$CLI" "$ACCOUNTS_BATS"

# Removing a login is removing a refresh token with weeks of life in it, and
# the way it gets removed is a typo in a picker.
cat > "$SED_TMP" << 'SED'
/^_account_trash()/,/^}$/{
  s#^  mv "[$]CLEAT_ACCOUNTS_DIR/[$]acct" "[$]dest" 2>/dev/null .. return 1$#  rm -rf "${CLEAT_ACCOUNTS_DIR:?}/${acct}" 2>/dev/null; mkdir -p "$dest"#
}
SED
try "vnext_account_trash_not_delete" "removing an account moves it to the trash" "$CLI" "$ACCOUNTS_BATS"

# A running session takes only part of a login change, so a switch under one is
# refused. Dropping the gate lets the swap through.
cat > "$SED_TMP" << 'SED'
s@^  if _daemon_up .*_box_has_live_agent "[$]cname"; then$@  if false; then@
SED
try "vnext_account_live_gate" "switching refuses while the box has a live Claude session" "$CLI" "$ACCOUNTS_BATS"

# A box that predates the mount must be told to recreate, not left to create
# the store inside the container where cleat rm destroys it.
cat > "$SED_TMP" << 'SED'
s/^  _account_box_ready "[$]cname" || ready=[$]?$/  ready=0/
SED
try "vnext_account_mount_probe" "a box that predates the auth mount is told to recreate" "$CLI" "$ACCOUNTS_BATS"

# Rule one: a refresh MAY rotate the refresh token, so polling a parked account
# for display could revoke a credential held elsewhere.
cat > "$SED_TMP" << 'SED'
/^_account_usage_fetch()/,/^}$/{
  s/^  \[\[ "[$]exp" -gt [$](( now \* 1000 )) \]\] || return 1$/  :/
}
SED
try "vnext_account_never_poll_parked" "usage is never polled for an account whose token has expired" "$CLI" "$ACCOUNTS_BATS"

# Without skip_spend the response carries real billing figures, which have no
# business in a picker.
cat > "$SED_TMP" << 'SED'
s|^_ACCOUNT_USAGE_URL="https://api.anthropic.com/api/oauth/usage?skip_spend=1"$|_ACCOUNT_USAGE_URL="https://api.anthropic.com/api/oauth/usage"|
SED
try "vnext_account_skip_spend" "the usage request carries skip_spend" "$CLI" "$ACCOUNTS_BATS"

# argv is visible in ps on a shared host.
cat > "$SED_TMP" << 'SED'
/^_account_usage_curl()/,/^}$/{
  s#^  printf 'silent.*#  curl -sS --max-time 3 -H "Authorization: Bearer $tok" "$_ACCOUNT_USAGE_URL" 2>/dev/null || true#
  s#^    "[$]tok" "[$]_ACCOUNT_USAGE_URL".*#  :#
}
SED
try "vnext_account_token_off_argv" "never the token on argv" "$CLI" "$ACCOUNTS_BATS"

# The subcommand words are reserved before the switch form is parsed, so an
# account called `rm` could be created and then never selected again.
cat > "$SED_TMP" << 'SED'
s/^    list|rename|rm|delete|restore|trash|held|adopt|off|help) return 1 ;;$/    zzzunused) return 1 ;;/
SED
try "vnext_account_reserved_names" "refuses the subcommand words as names" "$CLI" "$ACCOUNTS_BATS"

# Without the pin rewrite every box pinned to the old name silently falls back
# to the shared store at its next attach, which reads as being logged out.
cat > "$SED_TMP" << 'SED'
/^_account_rename_locked()/,/^}$/{
  s/^    _box_account_write "[$]b" "[$]new" .*$/    :/
}
SED
try "vnext_account_rename_follows_pins" "renaming moves the store and every pin follows it" "$CLI" "$ACCOUNTS_BATS"

# resets_at is an absolute future instant, so it stays true while the
# percentage goes stale. Showing the old percentage after it elapsed would be
# the one invented figure in the feature.
cat > "$SED_TMP" << 'SED'
/^_account_usage_render()/,/^}$/{
  s/^    if \[\[ "[$]fr" -gt 0 \&\& "[$]fr" -le "[$]now" \]\]; then$/    if false; then/
}
SED
try "vnext_account_window_reset" "a window whose reset time has passed says so" "$CLI" "$ACCOUNTS_BATS"

# A hand-edited pin holding something that is not a usable name must fall back
# to the shared store, not reach a path join.
cat > "$SED_TMP" << 'SED'
/^_box_account_read()/,/^}$/{
  s/^    if _validate_account_name "[$]v"; then$/    if true; then/
}
SED
try "vnext_account_pin_validated" "a hand-edited pin that is not a usable name falls back" "$CLI" "$ACCOUNTS_BATS"

# The verb is SINGULAR, matching kit, fork, config and account. The plural and
# the short form stay as aliases because they are what fingers type.
cat > "$SED_TMP" << 'SED'
s/^    session|sessions|ses) cmd_sessions "[$]@" ;;$/    sessions|ses) cmd_sessions "$@" ;;/
SED
try "vnext_session_verb_singular" "cleat session with no sessions exits cleanly" "$CLI" "$SMOKE_BATS"

cat > "$SED_TMP" << 'SED'
s/^    session|sessions|ses) cmd_sessions "[$]@" ;;$/    session) cmd_sessions "$@" ;;/
SED
try "vnext_session_verb_aliases" "the plural and the short form still reach the session verb" "$CLI" "$SMOKE_BATS"

# ── what the adversarial pass found ────────────────────────────────────────
#
# Every one of these was live in a green suite. They are here because each is
# SILENT when it breaks: a login that disappears, a token written where anyone
# can read it, a percentage shown as current when it is hours old.

# A switch stages in force mode. Newest-wins is only valid WITHIN an account,
# so without force the staged file (the account being LEFT, usually the fresher
# one) stayed put and was later harvested into the account just switched TO.
# Since the attach path checks identity too (v150_attach_identity_before_expiry)
# that half is now caught twice over, so this entry rides on what force ALONE
# still does: replace a staged path the box planted, which a plain attach
# deliberately refuses to overwrite blind.
cat > "$SED_TMP" << 'SED'
/^_account_switch_locked()/,/^}$/{
  s@^  if \[\[ "[$]current" != "[$]acct" \]\]; then$@  if false; then@
}
SED
try "vnext_account_switch_swaps_credential" "switching replaces a symlink the box planted" "$CLI" "$ACCOUNTS_BATS"

# The identity of the account being switched TO must not come from a project
# file that still holds the OUTGOING account. The capture reads no project file
# at all now, so the mutation re-adds the read and hands it the file.
cat > "$SED_TMP" << 'SED'
/^_account_capture_meta()/,/^}$/{
  s#^  _account_exists "[$]acct" .. return 0$#  _account_exists "$acct" || return 0; [[ -f "${2:-}" ]] \&\& _account_meta_set "$acct" who "$(grep -o '"emailAddress":"[^"]*"' "$2" | cut -d'"' -f4)"#
}
/^_account_switch_meta()/,/^}$/{
  s#^  _account_capture_meta "[$]acct" .. true$#  _account_capture_meta "$acct" "$CLEAT_PROJECTS_DIR/$(_derive_project_session_key "$project" "$box")/claude.json" || true#
}
SED
try "vnext_account_no_identity_bleed" "switching to a new account does not stamp it" "$CLI" "$ACCOUNTS_BATS"

# A glob must never decide identity: a dash is legal inside an account name.
cat > "$SED_TMP" << 'SED'
/^_account_restore_locked()/,/^}$/{
  s@"[$]{base#[*]-}" == "[$]acct"@"$base" == *-"$acct"@
}
SED
try "vnext_account_restore_exact_name" "restore does not resurrect a different account" "$CLI" "$ACCOUNTS_BATS"

# "Newer" alone must not earn an overwrite of the only host copy: the source is
# a directory the box mounts read-write.
cat > "$SED_TMP" << 'SED'
/^_account_harvest_from()/,/^}$/{
  s#^  _account_cred_plausible "[$]snap" .. return 1$#  :#
}
SED
try "vnext_account_harvest_plausible" "a box cannot destroy a stored credential" "$CLI" "$ACCOUNTS_BATS"

cat > "$SED_TMP" << 'SED'
/^_account_harvest_from()/,/^}$/{
  s#^  \[\[ "[$]be" -le [$](( now_ms + 7776000000 )) \]\] .. return 1$#  :#
}
SED
try "vnext_account_harvest_expiry_sane" "a harvest is refused when the expiry is further out" "$CLI" "$ACCOUNTS_BATS"

# A credential the box wrote is read into a shell variable, so it is capped.
cat > "$SED_TMP" << 'SED'
/^_account_write_file_0600()/,/^}$/{
  s#^  \[\[ -z "[$]src" \]\] .. _account_cred_sane_size "[$]src" .. return 1$#  :#
}
SED
try "vnext_account_cred_size_cap" "an oversized credential file is never read" "$CLI" "$ACCOUNTS_BATS"

# mkdir -p creates the PARENT at the host umask.
cat > "$SED_TMP" << 'SED'
/^_account_ensure_dir()/,/^}$/{
  s#^  chmod 700 "[$]CLEAT_ACCOUNTS_DIR" 2>/dev/null .. true$#  :#
}
SED
try "vnext_account_parent_mode" "the accounts directory itself is not world-readable" "$CLI" "$ACCOUNTS_BATS"

# cmd_clean was the one wipe in the file that skipped the harvest.
cat > "$SED_TMP" << 'SED'
/^cmd_clean()/,/^}$/{
  s#^        _account_wipe_run_dir "[$]_cn"$#        rm -rf "$_d" 2>/dev/null || true#
}
SED
try "vnext_account_clean_harvests" "cleat clean harvests before it prunes" "$CLI" "$ACCOUNTS_BATS"

# A wipe after a FAILED harvest must not delete the thing the harvest was
# protecting. A real login in the staged file keeps auth/ for the next session
# end to retry.
cat > "$SED_TMP" << 'SED'
/^_account_wipe_run_dir()/,/^}$/{
  s#^        keep_auth=1$#        :#
}
SED
try "vnext_account_wipe_keeps_unharvested" "a failed harvest leaves the staged credential" "$CLI" "$ACCOUNTS_BATS"

# After the trash the store path is gone, so the harvest has to come first.
cat > "$SED_TMP" << 'SED'
/^_account_do_remove()/,/^}$/{
  s#^    if ! _account_release_staged_locked "[$]b"; then$#    if false; then#
}
SED
try "vnext_account_remove_harvests_first" "removing an account harvests every pinned box" "$CLI" "$ACCOUNTS_BATS"

# /login is the one command whose whole job is to WRITE a credential.
cat > "$SED_TMP" << 'SED'
/^_account_apply_exec_env()/,/^}$/{
  s#^  CLAUDE_ENV+=(-e "CLAUDE_SECURESTORAGE_CONFIG_DIR=[$]{_ACCOUNT_BOX_DIR}")$#  :#
}
SED
try "vnext_account_login_override" "cleat login carries the credential store override" "$CLI" "$ACCOUNTS_BATS"

# Never point Claude at a store the container does not have.
cat > "$SED_TMP" << 'SED'
/^_account_apply_exec_env()/,/^}$/{
  s#^  if \[\[ [$]ready -eq 1 \]\]; then$#  if false; then#
}
SED
try "vnext_account_no_mount_no_env" "a box with no auth mount is never pointed" "$CLI" "$ACCOUNTS_BATS"

# docker exec needs a RUNNING container; inspect reads a stopped one.
cat > "$SED_TMP" << 'SED'
/^_account_box_ready()/,/^}$/{
  s#^  docker inspect .*#  docker exec "$cname" test -d "$_ACCOUNT_BOX_DIR" >/dev/null 2>\&1 || return 1#
  s#^    | grep -qx "[$]_ACCOUNT_BOX_DIR" .. return 1$#  :#
}
SED
try "vnext_account_probe_stopped_box" "the mount probe reads a STOPPED box" "$CLI" "$ACCOUNTS_BATS"

# Going back to the shared login is still a credential swap.
cat > "$SED_TMP" << 'SED'
/^_account_do_switch()/,/^}$/{
  s#^    if _daemon_up .*_box_has_live_agent "[$]cname"; then$#    if false; then#
}
SED
try "vnext_account_default_live_gate" "going back to the shared login respects the live-session gate" "$CLI" "$ACCOUNTS_BATS"

# Non-empty is not the same as usable: a logout leaves the file in place.
cat > "$SED_TMP" << 'SED'
/^_account_cred_plausible()/,/^}$/{
  s#^  \[\[ -n "[$]at" \&\& -n "[$]rt" \]\]$#  return 0#
}
SED
try "vnext_account_emptied_cred" "an emptied shared credential is not reported as logged in" "$CLI" "$ACCOUNTS_BATS"

# _age_from_delta already ends in the word.
cat > "$SED_TMP" << 'SED'
s#^      \*) d2="last used [$](_age_from_delta [$](( now - last )))" ;;$#      *) d2="last used $(_age_from_delta $(( now - last ))) ago" ;;#
SED
try "vnext_account_no_double_ago" "an age is never printed with the word ago twice" "$CLI" "$ACCOUNTS_BATS"

# The pane clamps from the right, so a trailing stamp is the first thing cut.
cat > "$SED_TMP" << 'SED'
/^_account_usage_render()/,/^}$/{
  s#^    out="last known [$]{out} (as of [$](_age_from_delta [$](( now - at ))))"$#    out="${out} (as of $(_age_from_delta $(( now - at ))))"#
}
SED
try "vnext_account_stale_marker_survives" "a stale usage snapshot says so even when" "$CLI" "$ACCOUNTS_BATS"

# A silently cut name creates a NEW empty account when it is retyped.
cat > "$SED_TMP" << 'SED'
/^_accounts_frame()/,/^}$/{
  s#^        printf -v meta '%s %-10.10s' "[$]{nm:0:12}…" "[$]{_ACCT_AUTH\[[$]n\]}"$#        printf -v meta '%-13.13s %-10.10s' "$nm" "${_ACCT_AUTH[$n]}"#
}
SED
try "vnext_account_name_truncation_visible" "an account name too wide for its column" "$CLI" "$ACCOUNTS_BATS"

# A pane clamped by character count wraps on CJK, and a wrapped line walks the
# whole block down the screen.
cat > "$SED_TMP" << 'SED'
/^_accounts_frame()/,/^}$/{
  s#^  case "[$]d1" in \*\[!\\ -~\]\*) if _has_unicode; then d1room=[$](( droom / 2 )); (( d1room < 1 )) \&\& d1room=1; fi ;; esac$#  :#
}
SED
try "vnext_account_detail_wide_chars" "a wide-character detail line is budgeted" "$CLI" "$ACCOUNTS_BATS"

# The back-out walks up a FIXED three lines.
cat > "$SED_TMP" << 'SED'
/^_accounts_action_tui()/,/^}$/{
  s@^  who="[$](_sessions_safe_title "[$]who")"$@  who="$who"@
}
SED
try "vnext_account_action_who_clamped" "the action screen clamps a long email" "$CLI" "$ACCOUNTS_BATS"

# A pinned box must not be re-stamped with the host account identity. Three
# parts cooperate (the overlay list, the del, the sibling gate) and only the
# OUTCOME is observable, so the mutation removes the two that can carry the
# host copy through.
cat > "$SED_TMP" << 'SED'
s#^        | (if [$]pinned then del(.oauthAccount).*$#        | .#
s#^        + ( (if [$]pinned then \["userID","lastOnboardingVersion"\]$#        + ( (if false then ["userID","lastOnboardingVersion"]#
SED
try "vnext_account_identity_split" "a pinned box is not re-stamped" "$CLI" "$ACCOUNTS_BATS"

# The sibling gate sits BEHIND the del, so its effect on the output is masked.
# What it does observably is stop a pinned box READING other projects' files at
# all, which is what the test watches.
cat > "$SED_TMP" << 'SED'
/^_build_project_claude_json()/,/^}$/{
  s#^    if \[\[ [$]_bpj_pinned -eq 0 \]\]; then$#    if true; then#
}
SED
try "vnext_account_sibling_pin_filter" "a pinned box does not even read a sibling" "$CLI" "$ACCOUNTS_BATS"

# A trash entry that holds nothing reports success and restores nothing.
cat > "$SED_TMP" << 'SED'
/^_sessions_trash()/,/^}$/{
  s#^  if \[\[ [$]moved -eq 0 \]\]; then$#  if false; then#
}
SED
try "vnext_sessions_no_phantom_trash" "an empty trash entry is never left behind" "$CLI" "$SESSIONS_BATS"

# ── what the completeness critic found ─────────────────────────────────────

# `docker top` fails on a STOPPED container and _box_has_live_agent maps any
# failure to "live", so without is_running every stopped box read as live. That
# is the normal steady state: the idle sweep stops boxes by itself.
cat > "$SED_TMP" << 'SED'
/^_account_do_switch()/,/^}$/{
  s@ \&\& is_running "[$]cname"@@
}
SED
try "vnext_account_stopped_not_live" "a merely STOPPED box is not mistaken" "$CLI" "$ACCOUNTS_BATS"

cat > "$SED_TMP" << 'SED'
/^_account_remove_live_gate()/,/^}$/{
  s@ \&\& is_running "[$]b"@@
}
SED
try "vnext_account_remove_stopped_ok" "removing is not wedged by one stale stopped box" "$CLI" "$ACCOUNTS_BATS"

# Who an account is comes from the server's profile answer, read with the flat
# reader on every host. macOS base has no jq: a reader that needed it named no
# account there.
cat > "$SED_TMP" << 'SED'
/^_account_profile_parse()/,/^}$/{
  s@^  \[\[ -n "[$]acct" \]\] .. return 1$@  command -v jq \&>/dev/null || return 1; [[ -n "$acct" ]] || return 1@
}
SED
try "vnext_account_jqless_identity" "identity is captured on a host with no jq" "$CLI" "$ACCOUNTS_BATS"

# vnext: every credential reader is scoped to claudeAiOauth. Read the whole
# file instead and keep the last match of a key: Claude writes mcpOAuth after
# claudeAiOauth once an MCP login follows a Claude login, so the reader returns
# an MCP server's token. The usage poll sends it to api.anthropic.com. A blanked
# login beside a live MCP entry reads as plausible and signed in. A jq-less host
# harvests it over the good store. The regressions loop both key orders,
# so a first-match reader fails them too.
cat > "$SED_TMP" << 'SED'
/^_account_cred_str()/,/^}$/{
  s/| _json_flat_object claudeAiOauth)/| cat)/
}
/^_json_flat_str()/,/^}$/{
  /^  case "[$]hit" in ''|[*][$]'.n'[*]) return 1 ;; esac$/d
  s/^  \[\[ -n "[$]hit" \]\] || return 1$/  hit="$(printf '%s\\n' "$hit" | tail -1)"/
}
SED
try "vnext_account_reader_scope" "the usage poll sends the account"
try "vnext_account_reader_scope_harvest" "a jq-less host does not harvest a blanked login over a good store"
try "vnext_account_reader_scope_readers" "a reader scoped to claudeAiOauth never returns a coresident MCP token" "$CLI" "$ACCOUNTS_BATS"
try "vnext_account_reader_scope_signed_out" "a blanked login beside a live MCP entry reads as signed out" "$CLI" "$ACCOUNTS_BATS"

# vnext: a key twice in the login is two answers. Drop only that refusal and
# the reader prints both copies run together as one token.
cat > "$SED_TMP" << 'SED'
/^_json_flat_str()/,/^}$/{
  s/^  case "[$]hit" in ''|[*][$]'.n'[*]) return 1 ;; esac$/  case "$hit" in '') return 1 ;; esac/
}
SED
try "vnext_json_flat_str_single_match" "a reader scoped to claudeAiOauth never returns a coresident MCP token" "$CLI" "$ACCOUNTS_BATS"

# vnext: the bearer goes into a curl config that takes one directive per line,
# out of a store harvested from a directory the box can write. Drop the charset
# guard and a token holding a quote or a folded newline reaches curl.
cat > "$SED_TMP" << 'SED'
/^_account_access_token()/,/^}$/{
  /^  _account_token_ok "[$]tok" || return 1$/d
}
SED
try "vnext_account_token_charset" "an access token outside the base64url alphabet is refused" "$CLI" "$ACCOUNTS_BATS"

# A refused switch must leave NO pin file: _box_account_read sanitises, so a
# junk one on disk is invisible to the obvious assertion but not to
# _account_pinned_boxes.
cat > "$SED_TMP" << 'SED'
/^_account_do_switch()/,/^}$/{
  s@^  if ! _validate_account_name "[$]acct"; then$@  if false; then@
}
SED
try "vnext_account_refused_switch_no_pin" "a refused switch leaves no pin file" "$CLI" "$ACCOUNTS_BATS"

# Another box may have refreshed the stored credential since this one last ran,
# so the staging is not only a switch-time step.
cat > "$SED_TMP" << 'SED'
/^_account_apply_exec_env()/,/^}$/{
  s@^  _account_sync_in "[$]cname" .. _si=[$]?$@  :@
}
SED
try "vnext_account_attach_restages" "every attach re-stages the stored credential" "$CLI" "$ACCOUNTS_BATS"

# cmd_nuke promises "your ~/.claude auth is safe" and then removes four state
# directories. The accounts tree being a SIBLING of all four is a directory
# layout, not a guard, so this is the guard.
cat > "$SED_TMP" << 'SED'
/^_nuke_wipe_dir()/,/^}$/{
  s@^  if _account_store_is_under "[$]dir"; then$@  if false; then@
}
SED
try "vnext_account_nuke_guard" "a wipe that would reach the account store is refused" "$CLI" "$ACCOUNTS_BATS"

# And the guard has to refuse the store and NOTHING else, or nuke stops doing
# its job.
cat > "$SED_TMP" << 'SED'
/^_account_store_is_under()/,/^}$/{
  s@^  return 1$@  return 0@
}
SED
try "vnext_account_nuke_guard_narrow" "an ordinary state directory is still wiped" "$CLI" "$ACCOUNTS_BATS"

# A prefix test without the slash would protect .../accounts-old forever.
cat > "$SED_TMP" << 'SED'
/^_account_store_is_under()/,/^}$/{
  s@^    \[\[ "[$]d" == "[$]dir"/\* \]\] \&\& return 0$@    [[ "$d" == "$dir"* ]] \&\& return 0@
}
SED
try "vnext_account_nuke_guard_prefix" "a directory that merely shares a prefix is not protected" "$CLI" "$ACCOUNTS_BATS"

# vnext_account_no_identity_from_unused_box and
# vnext_account_identity_still_captured guarded a gate on the capture's
# claude.json read ("did the box run as this account"). The read is gone, so
# the gate is too: see vnext_account_capture_no_project_file. Both tests stay as
# guards ("capture never reads a project file", "an account the box did run as
# still gets its identity captured").

# "Auth shared" on a pinned box contradicts the Account row printed under it.
cat > "$SED_TMP" << 'SED'
/^_print_auth_line()/,/^}$/{
  s@^  if \[\[ -n "[$]{1:-}" \&\& "[$]acct" != "[$]_ACCOUNT_DEFAULT" \]\]; then$@  if false; then@
}
SED
try "vnext_account_auth_line" "the launch summary does not call a pinned box" "$CLI" "$ACCOUNTS_BATS"

cat > "$SED_TMP" << 'SED'
/^_print_auth_line()/,/^}$/{
  s@^  if \[\[ -n "[$]{1:-}" \&\& "[$]acct" != "[$]_ACCOUNT_DEFAULT" \]\]; then$@  if true; then@
}
SED
try "vnext_account_auth_line_default" "an unpinned box still says its auth is shared" "$CLI" "$ACCOUNTS_BATS"

# The two refresh paths passed the container name and the CREATE path did not,
# so a box created while pinned got the right credential with the host account
# name stamped on it, which is what /usage shows inside the box.
cat > "$SED_TMP" << 'SED'
s@^  _build_project_claude_json "[$]project_claude_json" "" "[$]cname"$@  _build_project_claude_json "$project_claude_json"@
SED
try "vnext_account_create_path_identity" "a box CREATED while pinned is not stamped" "$CLI" "$ACCOUNTS_BATS"

# Claude shows the account email from oauthAccount in the per-project
# claude.json and nowhere else, and a COMPLETE one freezes it for 24 hours
# because profileFetchedAt lives inside that object. The start rebuild never
# reaches a RUNNING box, so the switch has to invalidate it itself.
cat > "$SED_TMP" << 'SED'
/^_account_switch_identity()/,/^}$/{
  s@^  \[\[ "[$]current" != "[$]acct" \]\] && { _account_invalidate_identity "[$]project" "[$]box" "[$]cname" || _id_rc=[$]?; }$@  :@
}
SED
try "vnext_account_switch_invalidates_identity" "switching drops the identity the box is carrying" "$CLI" "$ACCOUNTS_BATS"

cat > "$SED_TMP" << 'SED'
/^_account_switch_identity()/,/^}$/{
  s@^    _account_invalidate_identity "[$]project" "[$]box" "[$]cname" || _id_rc=[$]?$@    :@
}
SED
try "vnext_account_unpin_invalidates_identity" "unpinning drops it too" "$CLI" "$ACCOUNTS_BATS"

# An atomic rename swaps the inode out from under a running container, which is
# why the stopped-box rebuild refuses to touch one at all.
cat > "$SED_TMP" << 'SED'
/^_claude_json_drop_identity()/,/^}$/{
  s@^  _write_in_place "[$]tmp" "[$]f" || rc=1$@  mv -f "$tmp" "$f" 2>/dev/null || rc=1@
}
SED
try "vnext_account_identity_inplace" "the identity delete keeps the file" "$CLI" "$ACCOUNTS_BATS"

# Two guards cooperate and only the OUTCOME is observable, so the mutation
# removes both: the refusal in the delete and the one in the writer.
cat > "$SED_TMP" << 'SED'
/^_claude_json_drop_identity()/,/^}$/{
  s@^  \[\[ -L "[$]f" \]\] && return 0$@  :@
}
/^_write_in_place()/,/^}$/{
  s@ && ! -L "[$]dst"@@
}
SED
try "vnext_account_identity_symlink" "the identity delete refuses a symlinked store" "$CLI" "$ACCOUNTS_BATS"

# The box's claude.json is a single-file bind mount, so it is rewritten in
# place. A truncating write leaves it empty until the bytes land, and Claude
# Code reads it there: a starting session stops on "Configuration error" and a
# running one writes its cached identity back over the edit.
cat > "$SED_TMP" << 'SED'
/^_write_in_place()/,/^}$/{
  s@^  cat "[$]src" 1<> "[$]dst" 2>/dev/null$@  cat "$src" > "$dst" 2>/dev/null@
}
SED
try "vnext_account_identity_no_truncate" "identity delete never empties claude"
try "v1.4.3_attach_heal_no_truncate" "attach heal never empties claude"

# Without the pad a shorter rewrite leaves the old file's tail behind it, which
# is broken JSON rather than an empty file.
cat > "$SED_TMP" << 'SED'
/^_write_in_place()/,/^}$/{
  s@^  if (( new < old )); then$@  if (( new < 0 )); then@
}
SED
try "vnext_account_identity_pad" "identity delete never empties claude"

# The switch's own live gate runs seconds before the identity delete, with a
# harvest, a staging and a usage poll in between.
cat > "$SED_TMP" << 'SED'
/^_account_invalidate_identity_key()/,/^}$/{
  s@^  if \[\[ -n "[$]cname" \]\] && _box_claude_live "[$]cname"; then$@  if false; then@
}
SED
try "vnext_account_identity_live_at_write" "starts during an account switch"

# The heal's first live check runs before a rebuild that scans every sibling
# project, which can take seconds.
cat > "$SED_TMP" << 'SED'
/^_refresh_attached_claude_json()/,/^}$/{
  s@^     && ! _box_has_live_agent "[$]cname"; then$@     \&\& true; then@
}
SED
try "v1.4.3_attach_heal_recheck_live" "asks for a live Claude again"

# `cleat account rm` unpins boxes in other projects. Without this it left the
# removed account's email in every one of them.
cat > "$SED_TMP" << 'SED'
/^_account_do_remove()/,/^}$/{
  s@^      _account_invalidate_identity_key "[$]key" "[$]b" || true$@      :@
}
SED
try "vnext_account_remove_invalidates_identity" "removing an account drops the identity its pinned boxes carry"

# The pin's second line is the only link from a container name back to the
# per-project file the box binds.
cat > "$SED_TMP" << 'SED'
/^_account_switch_locked()/,/^}$/{
  s@^  _box_account_write "[$]cname" "[$]acct" "[$](_derive_project_session_key "[$]project" "[$]box")" @  _box_account_write "$cname" "$acct" @
}
SED
try "vnext_account_pin_records_key" "removing an account drops the identity its pinned boxes carry"

cat > "$SED_TMP" << 'SED'
/^_account_rename_locked()/,/^}$/{
  s@^    _box_account_write "[$]b" "[$]new" "[$](_box_account_key "[$]b" || true)" || true$@    _box_account_write "$b" "$new" || true@
}
SED
try "vnext_account_rename_keeps_key" "a renamed account still drops its boxes" "$CLI" "$ACCOUNTS_BATS"

# The pin file is hand-editable and its second line is joined into a path.
cat > "$SED_TMP" << 'SED'
/^_account_session_key_ok()/,/^}$/{
  s@^  local _key_re=.*$@  local _key_re='.'@
}
SED
try "vnext_account_pin_key_one_segment" "a hand-edited pin key never reaches outside the projects store" "$CLI" "$ACCOUNTS_BATS"

# An in-box login lands only in that box's per-project file, so an unpinned box
# takes the newest sibling that has one. A pinned sibling holds a named
# account's identity and nothing inside the file says whose it is.
cat > "$SED_TMP" << 'SED'
/^_newest_sibling_identity()/,/^}$/{
  s@^    \[\[ "[$]pinned" == \*":[$]{k}:"\* \]\] && continue$@    :@
}
SED
try "vnext_account_sibling_skips_pinned" "inherits a pinned sibling"

# The rc-3 notice reads a variable that is only set when the delete was
# actually skipped, so both branches have to declare it.
cat > "$SED_TMP" << 'SED'
/^_account_switch_identity()/,/^}$/{
  s@^  local _id_rc=0$@  :@
}
SED
try "vnext_account_switch_id_rc_declared" "account switch drops a stored identity" "$CLI" "$SMOKE_BATS"

# Claude guards the usage cache against cross-account reuse with an accountUuid
# comparison against oauthAccount, which a pinned box has removed.
cat > "$SED_TMP" << 'SED'
s@ | del(.cachedUsageUtilization) else . end)@ else . end)@
SED
try "vnext_account_usage_cache_dropped" "a pinned box does not inherit the shared usage cache" "$CLI" "$ACCOUNTS_BATS"

# ── the identity drop on a host with no jq ──────────────────────────────────
#
# The box's own jq does the transform as a stdin-to-stdout filter and the host
# still makes the only write. What the host cannot finish right then (no jq and
# no running box) is flagged next to the file, and the next launch clears it.

# The pinned del lives inside the jq program, so the no-jq branch of the
# builder has nothing to offer but the flag.
cat > "$SED_TMP" << 'SED'
/^_build_project_claude_json()/,/^}$/{
  s@^      : > "[$]{out}.identity-stale" 2>/dev/null || true$@      :@
}
SED
try "vnext_account_nojq_builder_flags" "a box created pinned on a jq-less host does not launch with the host account"

# A stopped box cannot be asked for its jq, so the switch leaves the job for
# the launch instead of dropping it. Retargeted with the live-switch work: the
# switch now flags identity in TWO places on this jq-less path. H9 added
# _handoff_flag_identity_stale, which runs first under the lock before the pin
# moves, and _account_invalidate_identity_key still writes the flag when the
# drop cannot finish. Removing either alone leaves the other to carry the flag,
# so both must go to reproduce the pre-fix bug where the launch never clears the
# old account name. (The invalidate-key line is the sole writer on the account
# rm path, where H9 does not run; that path is guarded by its own entries.)
cat > "$SED_TMP" << 'SED'
/^_account_switch_locked()/,/^}$/{
  /_handoff_flag_identity_stale "[$]project" "[$]box"/d
}
/^_account_invalidate_identity_key()/,/^}$/{
  s@^    : > "[$]{f}.identity-stale" 2>/dev/null || true$@    :@
}
SED
try "vnext_account_nojq_switch_flags" "clears the named account from a stopped box put back on the shared login"

# The launch is the one moment that has both the flag and a running box, and it
# is the last one before Claude reads the file.
cat > "$SED_TMP" << 'SED'
/^_refresh_attached_claude_json()/,/^}$/{
  s@^  _claude_json_clear_stale_identity "[$]cname" "[$]f" "[$]box"$@  :@
}
SED
try "vnext_account_nojq_launch_clears" "clears the old account from a box switched while stopped"

# Without the in-box filter a jq-less host cannot edit the file at all.
cat > "$SED_TMP" << 'SED'
/^_claude_json_drop_identity()/,/^}$/{
  s@^    { \[\[ -n "[$]cname" \]\] && _daemon_up && is_running "[$]cname"; } || return 1$@    return 1@
}
SED
try "vnext_account_nojq_inbox_filter" "clears the old account at the switch when the box is running"

# A delete under a live Claude Code makes it refuse its own later saves of that
# file, and its cached copy lands back on top of the edit.
cat > "$SED_TMP" << 'SED'
/^_claude_json_clear_stale_identity()/,/^}$/{
  s@^  if ! _box_has_live_agent "[$]cname" && _claude_json_drop_identity@  if _claude_json_drop_identity@
}
SED
try "vnext_account_nojq_live_gate" "never edits the file under a live Claude"

# A box created before the auth mount keeps its pin and the attach falls back
# to the shared login, so anything that REPORTS the account has to ask the same
# question the attach does or it names an account the box is not using.
cat > "$SED_TMP" << 'SED'
/^_account_effective()/,/^}$/{
  s@^  if \[\[ [$]ready -eq 1 \]\]; then$@  if false; then@
}
SED
try "vnext_account_effective_demotes" "a pin the box cannot honour reports as the shared login" "$CLI" "$ACCOUNTS_BATS"

# And "cannot tell" must not demote: a box that does not exist yet gets the
# mount from the next docker run.
cat > "$SED_TMP" << 'SED'
/^_account_effective()/,/^}$/{
  s@^  if \[\[ [$]ready -eq 1 \]\]; then$@  if [[ $ready -ne 0 ]]; then@
}
SED
try "vnext_account_effective_cannot_tell" "cannot-tell is not demotion" "$CLI" "$ACCOUNTS_BATS"

# docker commit writes a fresh config, so the upgraded image loses the labels
# the rebuild prompt reads. It fails open, so the cost is silent: a genuine
# spec bump can never reach that user again.
cat > "$SED_TMP" << 'SED'
/^_upgrade_claude_image()/,/^}$/{
  s@^    \[\[ -n "[$]_lbl_spec" \]\] && _commit_changes+=(--change "LABEL sh.cleat.image-spec=[$]{_lbl_spec}")$@    :@
  s@^    \[\[ -n "[$]_lbl_ver" \]\] && _commit_changes+=(--change "LABEL sh.cleat.version=[$]{_lbl_ver}")$@    :@
}
SED
try "vnext_claude_upgrade_keeps_labels" "the Claude image upgrade keeps the image" "$CLI" "$ACCOUNTS_BATS"

# And an image that never carried a label must not gain a fabricated one.
cat > "$SED_TMP" << 'SED'
/^_upgrade_claude_image()/,/^}$/{
  s@^    \[\[ -n "[$]_lbl_spec" \]\] @    true @
  s@^    \[\[ -n "[$]_lbl_ver" \]\] @    true @
}
SED
try "vnext_claude_upgrade_no_fake_labels" "an unlabelled image does not gain a fabricated" "$CLI" "$ACCOUNTS_BATS"

# ── the account trash view ──────────────────────────────────────────────────

# A dash is legal inside an account name, so a glob would match `<stamp>-my-work`
# when scanning for `work`. The scan splits on the stamp for the same reason
# _account_restore does: a glob must never decide identity here.
cat > "$SED_TMP" << 'SED'
/^_account_trash_scan()/,/^}$/{
  s@^    _validate_account_name "[$]name" || continue$@    :@
}
SED
try "vnext_account_trash_scan_validates" "the trash scan skips what it cannot name" "$CLI" "$ACCOUNTS_BATS"

# The count has to agree with the scan. A count that included a hand-made
# directory would advertise a trash the view then draws as empty.
cat > "$SED_TMP" << 'SED'
/^_account_trash_count()/,/^}$/{
  s@^      _validate_account_name "[$]{base#\*-}" || continue$@      :@
}
SED
try "vnext_account_trash_count_agrees" "the trash count counts exactly what the scan counts" "$CLI" "$ACCOUNTS_BATS"

# A count that fell through to an error prints nothing where the frame expects
# a number, and `[[ "" -gt 0 ]]` is a strict-mode error rather than a false.
cat > "$SED_TMP" << 'SED'
/^_account_trash_count()/,/^}$/{
  s@^  tdir="[$](_account_trash_dir)" || { printf .0.; return 0; }$@  tdir="$(_account_trash_dir)" || return 1@
}
SED
try "vnext_account_trash_count_symlink" "the trash count is zero when the trash is a symlink" "$CLI" "$ACCOUNTS_BATS"

# Nothing in the trash can be the active account. A marked row would draw the
# green dot against an account no box can possibly be using.
cat > "$SED_TMP" << 'SED'
/^_accounts_load_trash_rows()/,/^}$/{
  s@^    _ACCT_MARK\[[$]_ACCT_N\]=0$@    _ACCT_MARK[$_ACCT_N]=1@
}
SED
try "vnext_account_trash_never_marked" "the trash rows carry the name, the email and when" "$CLI" "$ACCOUNTS_BATS"

# A removed account keeps its meta file, which is the only thing that can say
# whose login it was. Reading it by NAME looks in the live directory, which is
# exactly where a removed account is not.
cat > "$SED_TMP" << 'SED'
/^_accounts_load_trash_rows()/,/^}$/{
  s@_account_meta_get_at "[$]dir" who@_account_meta_get "$name" who@
}
SED
try "vnext_account_trash_meta_by_dir" "the trash rows carry the name, the email and when" "$CLI" "$ACCOUNTS_BATS"

# The trash is reached with the right arrow. Without the handler the view is
# unreachable and the only way back to a removed account is to retype a command.
cat > "$SED_TMP" << 'SED'
/^_accounts_picker_tui()/,/^}$/{
  s@^          if \[\[ "[$]view" == "live" \]\]; then$@          if false; then@
}
SED
try "vnext_account_trash_right_opens" "the picker crosses to the trash and restores from it" "$CLI" "$ACCOUNTS_BATS"

# And the left arrow comes back. Without it the trash is a one-way door and the
# live list can only be reached by closing the picker.
cat > "$SED_TMP" << 'SED'
/^_accounts_picker_tui()/,/^}$/{
  s@^          if \[\[ "[$]view" == "trash" && "[$]trash_forced" != "1" \]\]; then$@          if false; then@
}
SED
try "vnext_account_trash_left_returns" "left comes back to the live list without acting" "$CLI" "$ACCOUNTS_BATS"

# Pressing Enter on an empty trash must not end the verb. Without the guard the
# restore runs against an empty name and the picker closes on a keypress that
# means nothing.
cat > "$SED_TMP" << 'SED'
/^_accounts_picker_tui()/,/^}$/{
  s@^            if ! _validate_account_name "[$]pick"; then$@            if false; then@
}
SED
try "vnext_account_trash_enter_empty" "enter on an empty trash does not close the picker" "$CLI" "$ACCOUNTS_BATS"

# Removing the last account leaves only the sentinel row. Dropping out to a
# shell prompt there strands the account in a trash the user has not been told
# about.
cat > "$SED_TMP" << 'SED'
/^_accounts_picker_tui()/,/^}$/{
  s@^      if \[\[ "[$]{_ACCT_TRASH_N:-0}" -gt 0 \]\]; then$@      if false; then@
}
SED
try "vnext_account_trash_shown_when_empty" "removing the last account shows the trash instead" "$CLI" "$ACCOUNTS_BATS"

# The counter line is the only place the trash is advertised in the picker.
cat > "$SED_TMP" << 'SED'
/^_accounts_frame()/,/^}$/{
  s@^    count="→ trash ([$]{_ACCT_TRASH_N})"$@    count=""@
}
SED
try "vnext_account_trash_advertised" "the live frame advertises the trash only when there" "$CLI" "$ACCOUNTS_BATS"

# And the trash view says what it is and how long it keeps things.
cat > "$SED_TMP" << 'SED'
/^_accounts_frame()/,/^}$/{
  s@^      count="Trash: 1 account, kept [$]{_ACCOUNTS_TRASH_DAYS} days"$@      count=""@
}
SED
try "vnext_account_trash_counter" "the trash view says restore and says how to get back" "$CLI" "$ACCOUNTS_BATS"

# The non-TTY path is the one place a removed account could be invisible.
cat > "$SED_TMP" << 'SED'
/^_accounts_picker_text()/,/^}$/{
  s@^  if \[\[ "[$]tn" -gt 0 \]\]; then$@  if false; then@
}
SED
try "vnext_account_trash_text_pointer" "the plain list points at the trash when something" "$CLI" "$ACCOUNTS_BATS"

# ── the account lock, the read-once snapshot and the refusal copy ───────────

# vnext: an attach that had read pin a staged a's login over the b a concurrent
# switch had just staged (5 in 100 natural runs). The attach waits for the lock.
cat > "$SED_TMP" << 'SED'
/^_account_sync_in()/,/^}$/{
  s/^  _account_with_lock _account_sync_in_locked "[$]1"$/  _account_sync_in_locked "$1"/
}
SED
try "vnext_account_lock_attach" "an attach cannot stage the old account"

# vnext: the switch holds the lock from its pin read to the staging, or a
# session-end harvest writes an older generation over the one it harvested.
cat > "$SED_TMP" << 'SED'
/^_account_switch_locked()/,/^}$/{
  s/^  if ! _account_lock; then$/  if false; then/
}
SED
try "vnext_account_lock_switch" "a session-end harvest cannot write the new account"

# The hold runs on through the unpin, the pin write and the staging. Let go
# after the harvest and an attach stages the old account under the new pin.
cat > "$SED_TMP" << 'SED'
/^_account_switch_locked()/,/^}$/{
  s/^  elif ! _account_release_staged_locked "[$]cname"; then$/  elif ! { _account_release_staged_locked "$cname" \&\& _account_unlock; }; then/
  s/^  _account_unlock$/  :/
}
SED
try "vnext_account_lock_switch_holds_to_staging" "an attach during the unpin and staging of a switch waits"

# vnext: the session-end harvest holds it too, or it writes the credential it
# checked over what a switch harvested and staged meanwhile.
cat > "$SED_TMP" << 'SED'
/^_account_sync_out()/,/^}$/{
  s/^  _account_with_lock _account_sync_out_locked "[$]1"$/  _account_sync_out_locked "$1"/
}
SED
try "vnext_account_lock_harvest" "a session-end harvest cannot write the new account"

# vnext: the live switch writes the store only while it still owns the lock. If
# the ownership check does not compare the on-disk owner with the record this
# shell wrote, a lock stolen by another command still reads as ours.
cat > "$SED_TMP" << 'SED'
/^_account_lock_owned()/,/^}$/{
  s/^  \[\[ "[$]owner" == "[$]_ACCOUNT_LOCK_OWNER" \]\] || return 1$/  :/
}
SED
try "vnext_account_lock_owned" "lock ownership reads true only while this shell still holds it" "$CLI" "$ACCOUNTS_BATS"

# vnext: rename moves the store before it rewrites the pins, so an attach in
# between found no store and deleted the staged login.
cat > "$SED_TMP" << 'SED'
s/^_account_rename() { _account_with_lock _account_rename_locked "[$]@"; }$/_account_rename() { _account_rename_locked "$@"; }/
SED
try "vnext_account_lock_rename" "an attach during a rename stages from the renamed store"

# vnext: remove holds it from the pinned-box read to the unpin, so no box is
# left pinned to a store that is already in the trash.
cat > "$SED_TMP" << 'SED'
/^_account_do_remove()/,/^}$/{
  s/^  if ! _account_lock; then$/  if false; then/
}
SED
try "vnext_account_lock_remove" "a box pinned while its account is being removed"

# vnext: the harvest decides and writes from ONE copy of a file the box can
# rewrite at any moment. Hand it the box path again and a blank or a symlink to
# a host file that lands after the checks reaches the store.
cat > "$SED_TMP" << 'SED'
/^_account_sync_out_locked()/,/^}$/{
  s/_account_harvest_from "[$]acct" "[$]cname" "[$]snap"/_account_harvest_from "$acct" "$cname" "$box_cred"/
}
SED
try "vnext_account_harvest_one_read" "a harvest writes only the bytes it checked"

# vnext: a lock timeout never falls through to an unlocked write.
cat > "$SED_TMP" << 'SED'
/^_account_lock()/,/^}$/{
  s/^    if \[\[ [$]polls -ge [$]max \]\]; then return "[$]_ACCOUNT_LOCK_BUSY"; fi$/    if [[ $polls -ge $max ]]; then return 0; fi/
}
SED
try "vnext_account_lock_no_fallthrough" "a switch that cannot take the account lock changes nothing"

# Every locked action releases the lock, or every later attach waits out the timeout.
cat > "$SED_TMP" << 'SED'
/^_account_with_lock()/,/^}$/{
  s/^  _account_unlock$/  :/
}
SED
try "vnext_account_lock_released" "every locked action releases the account lock" "$CLI" "$ACCOUNTS_BATS"

# A lock whose owner exited (a Ctrl-C inside a locked section) is taken over.
cat > "$SED_TMP" << 'SED'
/^_account_lock_is_stale()/,/^}$/{
  s/^  return 0$/  return 1/
}
SED
try "vnext_account_lock_dead_owner" "a lock whose owner has exited is taken over" "$CLI" "$ACCOUNTS_BATS"

# A lock with no owner record yet belongs to a winner a moment from writing it.
cat > "$SED_TMP" << 'SED'
/^_account_lock_is_stale()/,/^}$/{
  s/^    if \[\[ [$]age -gt [$]_ACCOUNT_LOCK_GRACE_S \]\]; then return 0; fi$/    return 0/
}
SED
try "vnext_account_lock_grace_honoured" "a lock with no owner record yet is honoured" "$CLI" "$ACCOUNTS_BATS"

# One that stays record-less past the grace period was killed in that moment.
cat > "$SED_TMP" << 'SED'
/^_account_lock_is_stale()/,/^}$/{
  s/^    if \[\[ [$]age -gt [$]_ACCOUNT_LOCK_GRACE_S \]\]; then return 0; fi$/    return 1/
}
SED
try "vnext_account_lock_grace_expires" "a lock with no owner record yet is honoured" "$CLI" "$ACCOUNTS_BATS"

# A pid recycled after a reboot must not wedge every account command.
cat > "$SED_TMP" << 'SED'
/^_account_lock_is_stale()/,/^}$/{
  s/^  if \[\[ [$]age -gt [$]_ACCOUNT_LOCK_STALE_S \]\]; then return 0; fi$/  :/
}
SED
try "vnext_account_lock_age_bound" "a lock past the age bound is taken over" "$CLI" "$ACCOUNTS_BATS"

# A live owner is waited on, never robbed.
cat > "$SED_TMP" << 'SED'
/^_account_lock_is_stale()/,/^}$/{
  /^  kill -0 "[$]o_pid" 2>\/dev\/null && return 1$/d
  /^  ps -p "[$]o_pid" >\/dev\/null 2>&1 && return 1$/d
}
SED
try "vnext_account_lock_live_owner" "a lock held by a live process is waited on" "$CLI" "$ACCOUNTS_BATS"

# Another machine's pid cannot be probed from this one, so age alone decides.
cat > "$SED_TMP" << 'SED'
/^_account_lock_is_stale()/,/^}$/{
  s/^  \[\[ "[$]o_host" == "[$]{HOSTNAME:-unknown}" \]\] .. return 1$/  :/
}
SED
try "vnext_account_lock_foreign_host" "a lock held by a live process is waited on" "$CLI" "$ACCOUNTS_BATS"

# The steal re-checks what it moved aside and gives back a lock that changed hands.
cat > "$SED_TMP" << 'SED'
/^_account_lock()/,/^}$/{
  s/^        if \[\[ "[$]captured" == "[$]owner" \]\]; then$/        if true; then/
}
SED
try "vnext_account_lock_steal_recheck" "a steal gives back a lock that changed hands" "$CLI" "$ACCOUNTS_BATS"

# A release only ever removes its own lock.
cat > "$SED_TMP" << 'SED'
/^_account_unlock()/,/^}$/{
  s/^  \[\[ -n "[$]_ACCOUNT_LOCK_OWNER" && "[$]owner" == "[$]_ACCOUNT_LOCK_OWNER" \]\] .. return 0$/  :/
}
SED
try "vnext_account_unlock_own_only" "releasing never removes a lock another process now holds" "$CLI" "$ACCOUNTS_BATS"

# Something this CLI did not create at the lock path is refused at once, never
# polled for the whole wait.
cat > "$SED_TMP" << 'SED'
/^_account_lock()/,/^}$/{
  s/^    if \[\[ -L "[$]lock" \]\] .. { .*; then$/    if false; then/
}
SED
try "vnext_account_lock_symlink" "something this CLI did not create at the lock path" "$CLI" "$ACCOUNTS_BATS"

# A wipe that cannot take the lock keeps the staged credential.
cat > "$SED_TMP" << 'SED'
/^_account_wipe_run_dir()/,/^}$/{
  s/^      warn "Kept the staged login for .*another cleat command.*/      rm -rf "${CLEAT_RUN_DIR:?}\/${cname}" 2>\/dev\/null || true/
}
SED
try "vnext_account_wipe_busy_keeps" "a wipe that cannot take the account lock keeps the staged credential" "$CLI" "$ACCOUNTS_BATS"

# An unpinned box has no login to lose, so its wipe never waits on the lock or
# keeps a stale run dir because of it.
cat > "$SED_TMP" << 'SED'
/^_account_wipe_run_dir()/,/^}$/{
  s/^  if \[\[ ! -e "[$]pin" && ! -L "[$]pin" \]\]; then$/  if false; then/
}
SED
try "vnext_account_unpinned_wipe_no_lock" "wipe takes no lock and removes everything" "$CLI" "$ACCOUNTS_BATS"

# A session end that cannot take the lock says the refreshed login was not saved.
cat > "$SED_TMP" << 'SED'
/^_maybe_report_account_harvest_busy()/,/^}$/{
  s/^  \[\[ "[$]{1:-0}" -eq [$]_ACCOUNT_LOCK_BUSY \]\] .. return 0$/  return 0/
}
SED
try "vnext_account_session_busy_says" "a session that cannot take the account lock touches neither" "$CLI" "$ACCOUNTS_BATS"

# And says it after the clean-exit reclaim. Printed straight after the terminal
# is restored, its last line was the one the reclaim's cursor-up erased.
cat > "$SED_TMP" << 'SED'
/^exec_claude()/,/^}$/{
  s/^  _restore_terminal$/  _restore_terminal; _maybe_report_account_harvest_busy "$_harvest"/
  /^  _maybe_report_account_harvest_busy "[$]_harvest"$/d
}
SED
try "vnext_account_session_busy_after_reclaim" "the session-end busy note comes after the reclaim" "$CLI" "$ACCOUNTS_BATS"

# nuke harvests every pinned box before it wipes the run dir. A harvest that
# cannot take the lock keeps the dir instead of falling through to the wipe.
cat > "$SED_TMP" << 'SED'
/^cmd_nuke()/,/^}$/{
  s/^    _account_release_all .. _rel=[$]?$/    :/
}
SED
try "vnext_account_nuke_busy_keeps" "a nuke that cannot take the account lock keeps the run dir" "$CLI" "$ACCOUNTS_BATS"

# And that harvest takes the lock at all, or it never reports busy.
cat > "$SED_TMP" << 'SED'
/^_account_release_all()/,/^}$/{
  s/^  _account_with_lock _account_release_all_locked$/  _account_release_all_locked/
}
SED
try "vnext_account_sync_out_all_locks" "a nuke that cannot take the account lock keeps the run dir" "$CLI" "$ACCOUNTS_BATS"

# rename and restore map a busy lock to the busy copy. Dropped, a restore says
# the account is not in the trash and a rename says it could not rename.
cat > "$SED_TMP" << 'SED'
/^_account_do_rename()/,/^}$/{
  s/^  if \[\[ [$]rc -eq [$]_ACCOUNT_LOCK_BUSY \]\]; then$/  if false; then/
}
SED
try "vnext_account_rename_busy_says" "rename and restore that cannot take the account lock say so" "$CLI" "$ACCOUNTS_BATS"

cat > "$SED_TMP" << 'SED'
/^_account_do_restore()/,/^}$/{
  s/^  if \[\[ [$]rc -eq [$]_ACCOUNT_LOCK_BUSY \]\]; then$/  if false; then/
}
SED
try "vnext_account_restore_busy_says" "rename and restore that cannot take the account lock say so" "$CLI" "$ACCOUNTS_BATS"

# And an attach that cannot take it says the box starts on the login it has.
cat > "$SED_TMP" << 'SED'
/^_account_apply_exec_env()/,/^}$/{
  s/^  elif \[\[ [$]_si -eq [$]_ACCOUNT_LOCK_BUSY \]\]; then$/  elif false; then/
}
SED
try "vnext_account_attach_busy_says" "a session that cannot take the account lock touches neither" "$CLI" "$ACCOUNTS_BATS"

# The top-of-verb harvest that cannot take the lock stops the verb, instead of
# letting it wait out the timeout a second time.
cat > "$SED_TMP" << 'SED'
/^cmd_account()/,/^}$/{
  s/^  if \[\[ [$]_harvest -eq [$]_ACCOUNT_LOCK_BUSY && "[$]sub" != "list" && "[$]sub" != "trash" && "[$]sub" != "held" \]\]; then$/  if false; then/
}
SED
try "vnext_account_verb_busy_stops" "a verb that cannot take the account lock changes nothing" "$CLI" "$ACCOUNTS_BATS"

# The plain list changes nothing, so it still draws while the lock is held.
cat > "$SED_TMP" << 'SED'
/^cmd_account()/,/^}$/{
  s/ && "[$]sub" != "list" && / \&\& /
}
SED
try "vnext_account_verb_busy_list_draws" "a verb that cannot take the account lock changes nothing" "$CLI" "$ACCOUNTS_BATS"

# A pin rewrite is temp and rename. An empty pin reads as the shared login to
# every reader that does not take the lock.
cat > "$SED_TMP" << 'SED'
/^_box_account_write()/,/^}$/{
  s/^  printf '%s\\n' "[$]acct" > "[$]tmp" .*/  printf '%s\\n' "$acct" > "$f" || return 1/
  s/^  mv -f "[$]tmp" "[$]f" .*/  :/
}
SED
try "vnext_account_pin_atomic" "a pin rewrite never shows a reader an empty pin" "$CLI" "$ACCOUNTS_BATS"

# A locked body calling a locking wrapper nests instead of timing out on itself.
cat > "$SED_TMP" << 'SED'
/^_account_lock()/,/^}$/{
  s/^  if \[\[ [$]_ACCOUNT_LOCK_DEPTH -gt 0 \]\]; then$/  if false; then/
}
SED
try "vnext_account_lock_reentrant" "a locked body that calls a locking wrapper nests" "$CLI" "$ACCOUNTS_BATS"

# mkdir -p creates the pin directory at the host umask, which listed every
# container name and its account to other local users.
cat > "$SED_TMP" << 'SED'
/^_box_account_write()/,/^}$/{
  s/^  chmod 700 "[$]CLEAT_BOX_ACCOUNTS_DIR" 2>\/dev\/null .. true$/  :/
}
SED
try "vnext_account_pin_dir_mode" "the pin directory is not readable by other users" "$CLI" "$ACCOUNTS_BATS"

# The snapshot opens the file once and checks again that the path is not a
# symlink. Without that second check a symlink swapped in after the first one
# has the host read the file it points at. Retargeted when the check moved into
# _fd_holds_path (the -ef reader never matched on macOS, see
# v150_snapshot_inode_not_ef).
cat > "$SED_TMP" << 'SED'
/^_account_snapshot_cred()/,/^}$/{
  s@^         _fd_holds_path 3 "[$]src" || exit 1$@         : || exit 1@
}
SED
try "vnext_account_snapshot_relink" "a snapshot refuses a symlink swapped in after the regular-file check" "$CLI" "$ACCOUNTS_BATS"

# vnext: the refusal said Claude Code notices a swap and undoes it, which
# 2.1.270 does not do. Put the old copy back in the shared printer.
cat > "$SED_TMP" << 'SED'
/^_account_live_refusal()/,/^}$/{
  s@Claude Code only takes a login change in full when it starts[.]@Swapping the credential under a running session is noticed and undone.@
}
SED
try "vnext_account_live_refusal_copy" "live-session refusal never claims Claude Code undoes"

# The unpin gate re-inlined past the printer with the old copy.
cat > "$SED_TMP" << 'SED'
/^_account_do_switch()/,/^}$/{
  s@^      _account_live_refusal "\(.*\)"$@      error "\1"; echo -e "    ${DIM}Exit it first. Swapping the credential under a running session is noticed and undone.${RESET}"@
}
SED
try "vnext_account_live_refusal_default" "live-session refusal never claims Claude Code undoes"

# The remove gate loses its reason, which is what it printed before.
cat > "$SED_TMP" << 'SED'
/^_account_remove_live_gate()/,/^}$/{
  s@^      _account_live_refusal "\(A box pinned to .*\)"$@      error "\1"; echo -e "    ${DIM}Exit it first.${RESET}"@
}
SED
try "vnext_account_live_refusal_remove" "live-session refusal never claims Claude Code undoes"

# vnext: account rm asked about live sessions only before its question, which
# can stay on screen indefinitely. Drop the second asking.
cat > "$SED_TMP" << 'SED'
/^_account_do_remove()/,/^}$/{
  /_ask_yn ans/,/^}$/{
    s/^  _account_remove_live_gate "[$]acct" .. return 1$/  :/
  }
}
SED
try "vnext_account_rm_regates_after_prompt" "account rm asks again whether a session is live after its question"

# And the boxes pinned while the question was open are read again under the
# lock, or one stays pinned to a store in the trash.
cat > "$SED_TMP" << 'SED'
/^_account_do_remove()/,/^}$/{
  /^  if ! _account_lock; then$/,/^}$/{
    /^  pinned="[$](_account_pinned_boxes "[$]acct")"$/d
  }
}
SED
try "vnext_account_rm_rereads_pins" "a box pinned while rm waits at its prompt is unpinned too" "$CLI" "$ACCOUNTS_BATS"

# vnext: the usage poll (up to 3 s) ran between the switch's harvest and its
# staging. Put it back before the harvest.
cat > "$SED_TMP" << 'SED'
/^_account_switch_locked()/,/^}$/{
  s@^  elif ! _account_release_staged_locked "[$]cname"; then$@  elif ! { _account_usage_fetch "$current" >/dev/null 2>\&1; _account_release_staged_locked "$cname"; }; then@
}
SED
try "vnext_account_switch_usage_after_stage" "a switch finishes staging before it waits on the usage API"

# vnext: a harvest that finished after `cleat account rm` in another terminal
# ran mkdir -p on the store and put the account back, so restore refused. Put
# the creating call back.
cat > "$SED_TMP" << 'SED'
/^_account_write_cred()/,/^}$/{
  s/^  _account_exists "[$]acct" .. return 1$/  _account_ensure_dir "$acct" || return 1/
}
SED
try "vnext_account_harvest_never_creates" "a session-end harvest that loses the race with account rm"

# The decline has to be a failure, or the wipe deletes the only copy of what
# the box refreshed.
cat > "$SED_TMP" << 'SED'
/^_account_write_cred()/,/^}$/{
  s/^  _account_exists "[$]acct" .. return 1$/  _account_exists "$acct" || return 0/
}
SED
try "vnext_account_gone_store_declines" "a harvest for an account that is gone creates nothing" "$CLI" "$ACCOUNTS_BATS"

# The usage poll records its numbers after a network wait. Those writes must
# not recreate a store removed meanwhile.
cat > "$SED_TMP" << 'SED'
/^_account_meta_set()/,/^}$/{
  s/^  _account_exists "[$]acct" .. return 1$/  _account_ensure_dir "$acct" || return 1/
}
SED
try "vnext_account_meta_never_creates" "a usage poll that outlives account rm" "$CLI" "$ACCOUNTS_BATS"

# vnext: the attach deleted the staged file whenever the account store was
# empty, which lost a /login made in the box that nothing had harvested and
# signed out the Claude running on it. Put the delete back.
cat > "$SED_TMP" << 'SED'
/^_account_sync_in_locked()/,/^}$/{
  s@^      _account_sync_out_locked "[$]cname" .. true$@      rm -f "$box_cred" 2>/dev/null || true@
}
SED
try "vnext_account_empty_store_keeps_login" "an unharvested login in a pinned box survives the next attach"

# After that harvest nothing is staged back, so the file a live session reads
# keeps its inode.
cat > "$SED_TMP" << 'SED'
/^_account_sync_in_locked()/,/^}$/{
  s@^    return 0$@    :@
}
SED
try "vnext_account_empty_store_no_restage" "an unharvested login in a pinned box survives the next attach"

# A pin to a store that is gone, or to a symlink where a store should be, stages
# nothing over the box's login.
cat > "$SED_TMP" << 'SED'
/^_account_sync_in_locked()/,/^}$/{
  s@^  _account_exists "[$]acct" .. return 0$@  true@
}
SED
try "vnext_account_missing_store_untouched" "an attach pinned to a missing account keeps the staged login" "$CLI" "$ACCOUNTS_BATS"

# ── every deleter keeps what the harvest did not take ──────────────────────

# vnext: a declined harvest returned 0, the same as "the store holds it", and
# every deleter then removed a login no store had. Collapse status 3 into 0.
cat > "$SED_TMP" << 'SED'
/^_account_harvest_from()/,/^}$/{
  s/^    return 3$/    return 0/
}
SED
try "vnext_account_declined_status" "cleat rm keeps a staged login its account store does not have"

# The wipe holds a login the store does not have before it deletes.
cat > "$SED_TMP" << 'SED'
/^_account_wipe_run_dir()/,/^}$/{
  s/^      _account_hold_staged_locked "[$]cname" .. keep_auth=1$/      :/
}
SED
try "vnext_account_wipe_holds_declined" "cleat rm keeps a staged login its account store does not have"

# A wipe that cannot take the lock still holds a journal before the rest of the
# run dir goes.
cat > "$SED_TMP" << 'SED'
/^_account_wipe_run_dir()/,/^}$/{
  s/^    _account_hold_run_extras "[$]cname" .. return 0$/    :/
}
SED
try "vnext_journal_busy_wipe_holds" "a wipe that cannot take the account lock keeps the staged credential" "$CLI" "$ACCOUNTS_BATS"

# The same refusal through the real binary under strict mode.
cat > "$SED_TMP" << 'SED'
/^cmd_clean()/,/^}$/{
  s/^  if ! _daemon_up; then$/  if false; then/
}
SED
try "v1.4.3_clean_refuses_blind_daemon_smoke" "cleat clean with the daemon down removes no box state" "$CLI" "$SMOKE_BATS"

# The one choke point before a switch, a remove or nuke deletes a staged file.
cat > "$SED_TMP" << 'SED'
/^_account_release_staged_locked()/,/^}$/{
  s/^  _account_hold_staged_locked "[$]cname"$/  return 0/
}
SED
try "vnext_account_release_holds" "switching accounts keeps a refreshed login whose harvest failed"

cat > "$SED_TMP" << 'SED'
/^_account_switch_locked()/,/^}$/{
  s/^  elif ! _account_release_staged_locked "[$]cname"; then$/  elif ! { _account_sync_out_locked "$cname" || true; }; then/
}
SED
try "vnext_account_switch_releases" "switching accounts keeps a refreshed login whose harvest failed"

cat > "$SED_TMP" << 'SED'
/^_account_switch_locked()/,/^}$/{
  s/^    if ! _account_release_staged_locked "[$]cname"; then$/    if ! { _account_sync_out_locked "$cname" || true; }; then/
}
SED
try "vnext_account_unpin_releases" "going back to the shared login keeps a staged login its account does not have"

cat > "$SED_TMP" << 'SED'
/^_account_do_remove()/,/^}$/{
  s/^    if ! _account_release_staged_locked "[$]b"; then$/    if ! { _account_sync_out_locked "$b" || true; }; then/
}
SED
try "vnext_account_remove_releases" "removing an account keeps a staged login it does not have"

cat > "$SED_TMP" << 'SED'
/^_account_release_all_locked()/,/^}$/{
  s/^    _account_release_staged_locked "[$]base" .. rc=1$/    _account_sync_out_locked "$base" || true/
}
SED
try "vnext_account_nuke_releases" "nuke keeps a staged login its account does not have"

# A login that cannot be kept stops the switch, the unpin and the remove.
cat > "$SED_TMP" << 'SED'
/^_account_hold()/,/^}$/{
  s/^  hdir="[$](_account_held_dir)" || return 1$/  hdir="$(_account_held_dir)" || return 0/
}
SED
try "vnext_account_switch_refuses_unkept" "a switch that cannot keep the outgoing login changes nothing" "$CLI" "$ACCOUNTS_BATS"

# The store's own login is not worth a held copy.
cat > "$SED_TMP" << 'SED'
/^_account_staged_absorbed()/,/^}$/{
  s/^  \[\[ -n "[$]srt" && "[$]brt" == "[$]srt" \]\]$/  false/
}
SED
try "vnext_account_absorbed_no_noise" "a staged login the store already holds is wiped with no held copy" "$CLI" "$ACCOUNTS_BATS"

# A link in the box's auth dir is never read into the held logins. All three
# refusals go, or the snapshot's own check stands in for the one under test.
cat > "$SED_TMP" << 'SED'
/^_account_keepable_snapshot()/,/^}$/{
  s/^  \[\[ -f "[$]f" && ! -L "[$]f" \]\] || return 1$/  [[ -f "$f" ]] || return 1/
}
/^_account_snapshot_cred()/,/^}$/{
  s/^  \[\[ -f "[$]src" && ! -L "[$]src" \]\] || return 1$/  [[ -f "$src" ]] || return 1/
  s/^         \[\[ ! -L "[$]src" && "[$]src" -ef \/dev\/fd\/3 \]\] || exit 1$/         :/
}
SED
try "vnext_account_hold_refuses_symlink" "a symlinked staged credential is never copied into the held logins" "$CLI" "$ACCOUNTS_BATS"
try "vnext_journal_skips_links" "leftover files skips links" "$CLI" "$ACCOUNTS_BATS"

# auth/ swapped for a link to a host directory is not read through either.
cat > "$SED_TMP" << 'SED'
/^_account_hold_run_extras()/,/^}$/{
  s/^    \[\[ "[$]{f%\/\*}" == "[$]auth" && -L "[$]auth" \]\] && continue$/    :/
}
SED
try "vnext_journal_skips_linked_auth" "leftover files skips links" "$CLI" "$ACCOUNTS_BATS"

# No harvest looks at an unpinned box, so its staged file is held by release.
cat > "$SED_TMP" << 'SED'
/^_account_release_staged_locked()/,/^}$/{
  s/^  if \[\[ "[$](_box_account_read "[$]cname")" != "[$]_ACCOUNT_DEFAULT" \]\]; then$/  if true; then/
}
SED
try "vnext_account_release_unpinned_orphan" "switching an unpinned box keeps a login left in its auth dir" "$CLI" "$ACCOUNTS_BATS"

# A refused staged file that is not a login does not keep auth/ forever.
cat > "$SED_TMP" << 'SED'
/^_account_wipe_run_dir()/,/^}$/{
  s/^      elif \[\[ [$]src -ne 1 \]\]; then$/      else/
}
SED
try "vnext_account_wipe_drops_junk" "a wipe does not keep a staged file that is not a credential" "$CLI" "$ACCOUNTS_BATS"

# vnext: a wipe knew about one file. A journal in the run dir died with it.
cat > "$SED_TMP" << 'SED'
/^_account_wipe_run_dir()/,/^}$/{
  s/^  if ! _account_hold_run_extras "[$]cname"; then$/  if false; then/
}
SED
try "vnext_journal_wipe_holds" "credential journal left in a box auth dir"

cat > "$SED_TMP" << 'SED'
/^_account_wipe_run_dir()/,/^}$/{
  s/^    if ! _account_hold_run_extras "[$]cname"; then$/    if false; then/
}
SED
try "vnext_journal_unpinned_wipe_holds" "credential journal left in a box auth dir"

# Every journal name starts with a dot and a bare glob skips it.
cat > "$SED_TMP" << 'SED'
/^_account_hold_run_extras()/,/^}$/{
  s#^  for f in .*; do$#  for f in "$rd"/* "$auth"/*; do#
}
SED
try "vnext_journal_dotfiles" "credential journal left in a box auth dir"

# nuke looked only at pinned boxes before it removed every run dir.
cat > "$SED_TMP" << 'SED'
/^_account_hold_all_run_extras()/,/^}$/{
  s/^    _account_hold_run_extras "[$]{d##\*\/}" .. rc=1$/    :/
}
SED
try "vnext_journal_nuke_every_run_dir" "cleat nuke keeps a credential journal"

# An unpinned box has no harvest, so its staged file is not skipped as owned.
cat > "$SED_TMP" << 'SED'
/^_account_hold_run_extras()/,/^}$/{
  s/^    owned=""$/    :/
}
SED
try "vnext_journal_unpinned_staged" "cleat nuke keeps a credential journal"

# A wipe that could not keep a login deletes nothing, pinned or not.
cat > "$SED_TMP" << 'SED'
/^_account_wipe_run_dir()/,/^}$/{
  /^  if ! _account_hold_run_extras "[$]cname"; then$/,/^  fi$/{
    s/^    return 0$/    :/
  }
}
SED
try "vnext_journal_wipe_deletes_nothing" "a wipe that cannot keep a credential journal deletes nothing"

cat > "$SED_TMP" << 'SED'
/^_account_wipe_run_dir()/,/^}$/{
  /^    if ! _account_hold_run_extras "[$]cname"; then$/,/^    fi$/{
    s/^      return 0$/      :/
  }
}
SED
try "vnext_journal_wipe_deletes_nothing_unpinned" "a wipe that cannot keep a credential journal deletes nothing"

# The attach staged the store over a login the store did not have. The guard is
# the first line of a multi-line `if`, so neutralise that line to `if false \`
# and let the `&& ...` continuation ride, which disables the whole hold branch.
cat > "$SED_TMP" << 'SED'
/^_account_sync_in_locked()/,/^}$/{
  s@^    if \[\[ [$]_held_by_harvest -eq 0 \]\] && _account_cred_keepable "[$]snap" \\@    if false \\@
}
SED
try "vnext_account_attach_holds_unabsorbed" "an attach keeps a login the store does not have"

# v1.4.3: cleat clean pruned every box with the daemon down.
cat > "$SED_TMP" << 'SED'
/^cmd_clean()/,/^}$/{
  s/^  if ! _daemon_up; then$/  if false; then/
}
SED
try "v1.4.3_clean_refuses_blind_daemon" "cleat clean with Docker down removes no box state"

# The held logins are credentials: 0700 directory, 0600 files, no links.
cat > "$SED_TMP" << 'SED'
/^_account_hold()/,/^}$/{
  s/^  chmod 700 "[$]hdir" 2>\/dev\/null .. true$/  :/
}
SED
try "vnext_account_held_dir_mode" "held logins are 0600 in a 0700 directory" "$CLI" "$ACCOUNTS_BATS"

cat > "$SED_TMP" << 'SED'
/^_account_held_dir()/,/^}$/{
  s/^  \[\[ -L "[$]d" \]\] && return 1$/  :/
}
SED
try "vnext_account_held_symlink" "held logins are 0600 in a 0700 directory" "$CLI" "$ACCOUNTS_BATS"

cat > "$SED_TMP" << 'SED'
/^_account_trash_sweep()/,/^}$/{
  s/^  hdir="[$](_account_held_dir)" .. hdir=""$/  hdir=""/
}
SED
try "vnext_account_held_sweep" "held logins are swept after the trash window" "$CLI" "$ACCOUNTS_BATS"

cat > "$SED_TMP" << 'SED'
/^_accounts_picker_text()/,/^}$/{
  s/^  _account_held_line "  "$/  :/
}
SED
try "vnext_account_held_listed" "held logins are listed with where they were headed" "$CLI" "$ACCOUNTS_BATS"

cat > "$SED_TMP" << 'SED'
/^_accounts_held_text()/,/^}$/{
  s/^    echo -e "      [$]{DIM}[$]{where}[$]{RESET}"$/    :/
}
SED
try "vnext_account_held_says_where" "held logins are listed with where they were headed" "$CLI" "$ACCOUNTS_BATS"

cat > "$SED_TMP" << 'SED'
/^_accounts_frame()/,/^}$/{
  s/^  if \[\[ "[$]_ACCT_VIEW" != "trash" && "[$]{_ACCT_HELD_N:-0}" -gt 0 \]\]; then$/  if false; then/
}
SED
try "vnext_account_held_counter" "the live frame advertises held logins" "$CLI" "$ACCOUNTS_BATS"

# adopt is the recovery, so it never loses a login either.
cat > "$SED_TMP" << 'SED'
/^_account_adopt_locked()/,/^}$/{
  s/^      _account_hold "[$]store" "[$]name" "" replaced-by-adopt \\$/      : \\/
}
SED
try "vnext_account_adopt_exchange" "adopting into an existing account holds the credential it replaces" "$CLI" "$ACCOUNTS_BATS"

cat > "$SED_TMP" << 'SED'
/^_account_adopt_locked()/,/^}$/{
  s/^    _account_ensure_dir "[$]name" .. return 2$/    return 2/
}
SED
try "vnext_account_adopt_creates" "a held login adopted under a new name becomes that account" "$CLI" "$ACCOUNTS_BATS"

cat > "$SED_TMP" << 'SED'
s/^    list|rename|rm|delete|restore|trash|held|adopt|off|help) return 1 ;;$/    list|rename|rm|delete|restore|trash|off|help) return 1 ;;/
SED
try "vnext_account_reserved_held_adopt" "refuses the subcommand words as names" "$CLI" "$ACCOUNTS_BATS"

# adopt swapped only the store file. A box pinned to the account wrote its
# fresher staged copy of the old login back at the next session end. Every
# pinned box is released before the store is replaced...
cat > "$SED_TMP" << 'SED'
/^_account_adopt_locked()/,/^}$/{
  s/^    if ! _account_release_staged_locked "[$]b"; then$/    if false; then/
}
SED
try "vnext_account_adopt_releases_pinned" "a login adopted into an account a box is pinned to survives the next harvest"

# ...and its staged copy is signed out of the account once the adopted login is
# written (the box's own MCP logins stay, see _account_strip_staged).
cat > "$SED_TMP" << 'SED'
/^_account_adopt_locked()/,/^}$/{
  s/^    _account_strip_staged "[$]b"$/    :/
}
SED
try "vnext_account_adopt_unstages_pinned" "a login adopted into an account a box is pinned to survives the next harvest"

# A pinned box whose login cannot be kept stops the adopt before any write.
cat > "$SED_TMP" << 'SED'
/^_account_adopt_locked()/,/^}$/{
  s/^      return 3$/      continue/
}
SED
try "vnext_account_adopt_refuses_unkept_pinned" "an adopt that cannot keep a pinned box" "$CLI" "$ACCOUNTS_BATS"

# A live session on a pinned box would lose its staged login under it.
cat > "$SED_TMP" << 'SED'
/^_account_do_adopt()/,/^}$/{
  s/^  _account_remove_live_gate "[$]name" .. return 1$/  :/
}
SED
try "vnext_account_adopt_live_gate" "whose pinned box has a live session changes nothing" "$CLI" "$ACCOUNTS_BATS"

# The adopted login's identity replaces the old one, blanks included.
cat > "$SED_TMP" << 'SED'
/^_account_adopt_locked()/,/^}$/{
  s/^      if \[\[ -n "[$]v" .. [$]created -eq 0 \]\]; then$/      if [[ -n "$v" ]]; then/
}
SED
try "vnext_account_adopt_identity_cleared" "an adopted login carries its own identity" "$CLI" "$ACCOUNTS_BATS"

# And the replaced login is held under the identity it was saved with.
cat > "$SED_TMP" << 'SED'
/^_account_adopt_locked()/,/^}$/{
  s/^        "[$](_account_meta_get "[$]name" who 2>\/dev\/null .. true)" \\$/        "" \\/
}
SED
try "vnext_account_adopt_replaced_identity" "an adopted login carries its own identity" "$CLI" "$ACCOUNTS_BATS"

# The held login is only removed once the store write has landed.
cat > "$SED_TMP" << 'SED'
/^_account_adopt_locked()/,/^}$/{
  /if ! _account_write_cred "[$]name" "[$]cred"; then/,/^  fi$/{
    s/^    return 2$/    :/
  }
}
SED
try "vnext_account_adopt_keeps_on_failed_write" "an adopt whose store write fails keeps the held login" "$CLI" "$ACCOUNTS_BATS"

# An attach that could not hold the login it would replace stages nothing...
cat > "$SED_TMP" << 'SED'
/^_account_sync_in_locked()/,/^}$/{
  /if ! _account_hold_box "[$]snap" "[$]acct" "[$]cname" unsaved; then/,/^      fi$/{
    s/^        return 1$/        :/
  }
}
SED
try "vnext_account_attach_refuses_unkept" "an attach that cannot keep the login it would replace" "$CLI" "$ACCOUNTS_BATS"

# ...and says so, or the box runs as someone else in silence.
cat > "$SED_TMP" << 'SED'
/^_account_apply_exec_env()/,/^}$/{
  s/^  elif \[\[ [$]_si -ne 0 && [$]_ACCOUNT_STAGE_UNKEPT -eq 1 \]\]; then$/  elif false; then/
}
SED
try "vnext_account_attach_unkept_warns" "an attach that cannot keep the login it would replace" "$CLI" "$ACCOUNTS_BATS"

cat > "$SED_TMP" << 'SED'
/^_account_switch_locked()/,/^}$/{
  s/^    if \[\[ [$]_ACCOUNT_STAGE_UNKEPT -eq 1 \]\]; then$/    if false; then/
}
SED
try "vnext_account_reselect_names_unkept" "an attach that cannot keep the login it would replace" "$CLI" "$ACCOUNTS_BATS"

# nuke keeps the run dir on any failure to keep a login, not only on a busy lock.
cat > "$SED_TMP" << 'SED'
/^cmd_nuke()/,/^}$/{
  s/^    if \[\[ [$]_rel -eq 0 \]\]; then$/    if [[ $_rel -ne $_ACCOUNT_LOCK_BUSY ]]; then/
}
SED
try "vnext_account_nuke_keeps_unkept" "nuke keeps the run dir when a login in it cannot be kept" "$CLI" "$ACCOUNTS_BATS"

cat > "$SED_TMP" << 'SED'
/^_account_release_all_locked()/,/^}$/{
  s/^  _account_hold_all_run_extras .. rc=1$/  _account_hold_all_run_extras || true/
}
SED
try "vnext_account_nuke_extras_unkept" "nuke keeps the run dir when a login in it cannot be kept" "$CLI" "$ACCOUNTS_BATS"

cat > "$SED_TMP" << 'SED'
/^_account_release_all_locked()/,/^}$/{
  s/^    _account_release_staged_locked "[$]base" .. rc=1$/    _account_release_staged_locked "$base" || true/
}
SED
try "vnext_account_nuke_pinned_unkept" "nuke keeps the run dir when a login in it cannot be kept" "$CLI" "$ACCOUNTS_BATS"

# A copy that cannot be taken is a login that cannot be kept, never junk.
cat > "$SED_TMP" << 'SED'
/^_account_keepable_snapshot()/,/^}$/{
  s/^  snap="[$](_account_snapshot_cred "[$]f")" || return 2$/  snap="$(_account_snapshot_cred "$f")" || return 1/
}
SED
try "vnext_account_snapshot_failure_kept" "a login whose copy cannot be taken is never deleted" "$CLI" "$ACCOUNTS_BATS"

cat > "$SED_TMP" << 'SED'
/^_account_hold_staged_locked()/,/^}$/{
  s/^  if \[\[ [$]src -ne 0 \]\]; then return 1; fi$/  if [[ $src -ne 0 ]]; then return 0; fi/
}
SED
try "vnext_account_hold_staged_snapshot_failure" "a login whose copy cannot be taken is never deleted" "$CLI" "$ACCOUNTS_BATS"

# ── identity-verified harvest ───────────────────────────────────────────────

# A newer login is written over the pinned store only when the server names the
# recorded account. A mismatch is held, never harvested.
cat > "$SED_TMP" << 'SED'
/^_account_harvest_from()/,/^}$/{
  s/^    if \[\[ "[$]uuid" != "[$]rec" \]\]; then$/    if false; then/
}
SED
try "vnext_account_harvest_identity_mismatch" "a login for another account is never harvested over the pinned credential"

# First use trusts the server, but not over a different email the account shows.
cat > "$SED_TMP" << 'SED'
/^_account_harvest_from()/,/^}$/{
  s/^    if \[\[ -n "[$]known" \]\] && ! _account_same_email "[$]known" "[$]who"; then$/    if false; then/
}
SED
try "vnext_account_harvest_first_use_email" "first use never records a login whose email differs"

# A store with no recorded uuid was only ever taken on trust. Its first verified
# harvest holds the store's own login before writing over it...
cat > "$SED_TMP" << 'SED'
/^_account_harvest_from()/,/^}$/{
  s/^    if _account_cred_keepable "[$]store_cred"; then$/    if false; then/
}
SED
try "vnext_account_harvest_first_use_holds_store" "a first verified harvest holds the login it writes over"

# ...and writes nothing when that login cannot be kept.
cat > "$SED_TMP" << 'SED'
/^_account_harvest_from()/,/^}$/{
  s/^        "[$](_account_meta_get "[$]acct" org 2>\/dev\/null .. true)" .. return 1$/        "$(_account_meta_get "$acct" org 2>\/dev\/null || true)" || true/
}
SED
try "vnext_account_harvest_first_use_hold_unkept" "a first verified harvest holds the login it writes over"

# A login the server cannot vouch for (401, offline, 5xx) writes nothing.
cat > "$SED_TMP" << 'SED'
/^_account_harvest_from()/,/^}$/{
  s/^  ident="[$](_account_cred_identity "[$]snap")" || return 3$/  ident="$(_account_cred_identity "$snap")" || { _account_write_cred "$acct" "$snap"; return $?; }/
}
SED
try "vnext_account_harvest_cannot_tell" "a harvest the server cannot vouch for writes nothing"

# A switch holds that unverified login before it deletes the staged file.
cat > "$SED_TMP" << 'SED'
/^_account_release_staged_locked()/,/^}$/{
  s/^    case "[$]rc" in 0|2) return 0 ;; esac$/    case "$rc" in 0|2|3) return 0 ;; esac/
}
SED
try "vnext_account_switch_holds_unverified" "switching away holds a staged login nobody could verify"

# The capture never reads the box's project file for identity. The mutation
# re-adds the read and hands it the file for the account being left.
cat > "$SED_TMP" << 'SED'
/^_account_capture_meta()/,/^}$/{
  s#^  _account_exists "[$]acct" .. return 0$#  _account_exists "$acct" || return 0; [[ -f "${2:-}" ]] \&\& _account_meta_set "$acct" who "$(grep -o '"emailAddress":"[^"]*"' "$2" | cut -d'"' -f4)"#
}
/^_account_switch_meta()/,/^}$/{
  s#^  _account_capture_meta "[$]current" .. true$#  _account_capture_meta "$current" "$CLEAT_PROJECTS_DIR/$(_derive_project_session_key "$project" "$box")/claude.json" || true#
}
SED
try "vnext_account_capture_no_project_file" "switching away never stamps the account with the email in the box project file"

# The same grant is recognised with no request.
cat > "$SED_TMP" << 'SED'
/^_account_harvest_from()/,/^}$/{
  s/^  if _account_staged_absorbed "[$]snap" "[$]store_cred"; then$/  if false; then/
}
SED
try "vnext_account_harvest_fast_path" "an unchanged refresh token is harvested without asking the server" "$CLI" "$ACCOUNTS_BATS"

# The same grant is the Claude login's refresh token, never an MCP entry both
# files share.
cat > "$SED_TMP" << 'SED'
/^_account_staged_absorbed()/,/^}$/{
  s@^  srt="[$](_account_cred_str "[$]2" refreshToken 2>/dev/null .. true)"$@  srt="$(grep -o '"refreshToken":"[^"]*"' "$2" | head -n1)"@
  s@^  brt="[$](_account_cred_str "[$]1" refreshToken 2>/dev/null .. true)"$@  brt="$(grep -o '"refreshToken":"[^"]*"' "$1" | head -n1)"@
}
SED
try "vnext_account_fast_path_scoped" "an MCP login both files share never stands in" "$CLI" "$ACCOUNTS_BATS"

# A dead access token is never sent.
cat > "$SED_TMP" << 'SED'
/^_account_cred_identity()/,/^}$/{
  s/^  \[\[ "[$]exp" -gt "[$]now_ms" \]\] || return 3$/  :/
}
SED
try "vnext_account_identity_expired_token" "an expired access token is never sent to the server" "$CLI" "$ACCOUNTS_BATS"

# Any answer but 200 is "cannot tell", whatever its body says.
cat > "$SED_TMP" << 'SED'
/^_account_cred_identity()/,/^}$/{
  s/^  \[\[ "[$]code" == "200" \]\] .. return 3$/  :/
}
SED
try "vnext_account_identity_status_code" "a harvest the server cannot vouch for writes nothing"

# The account object is the only one in the answer.
cat > "$SED_TMP" << 'SED'
/^_json_flat_object()/,/^}$/{
  s/^  case "[$]hit" in ''|\*[$]'\\n'\*) return 0 ;; esac$/  case "$hit" in '') return 0 ;; esac/
}
SED
try "vnext_account_profile_single_match" "the profile reader refuses a shape it does not know" "$CLI" "$ACCOUNTS_BATS"

# The organisation's own empty objects are folded before it is read.
cat > "$SED_TMP" << 'SED'
/^_account_profile_parse()/,/^}$/{
  s@/:null/g'@/:{}/g'@
}
SED
try "vnext_account_profile_org_fold" "identity is captured on a host with no jq" "$CLI" "$ACCOUNTS_BATS"

# One held entry per box, account and reason, the newest.
cat > "$SED_TMP" << 'SED'
/^_account_hold()/,/^}$/{
  s/^    \[\[ -n "[$]uuid" && -n "[$]cname" \]\] || continue$/    continue/
}
SED
try "vnext_account_held_dedupe" "a box that keeps refreshing a foreign login keeps one held entry" "$CLI" "$ACCOUNTS_BATS"

# Only generations of the same verified account fold. A third account's login
# from the same box is its own entry.
cat > "$SED_TMP" << 'SED'
/^_account_hold()/,/^}$/{
  s/^    \[\[ "[$](_account_meta_get_at "[$]d" uuid 2>\/dev\/null .. true)" == "[$]uuid" \]\] .. continue$/    :/
}
SED
try "vnext_account_held_dedupe_uuid_scope" "a box that keeps refreshing a foreign login keeps one held entry" "$CLI" "$ACCOUNTS_BATS"

# Bytes already proven foreign are not sent to the server again.
cat > "$SED_TMP" << 'SED'
/^_account_harvest_from()/,/^}$/{
  s/^  _account_held_has "[$]cname" "[$]snap" other-account && return 2$/  :/
}
SED
try "vnext_account_held_not_reasked" "a login already held as another account is not sent to the server again" "$CLI" "$ACCOUNTS_BATS"

# The session end says so.
cat > "$SED_TMP" << 'SED'
/^exec_claude()/,/^}$/{
  s/^  if \[\[ [$]_harvest -eq 2 \]\]; then$/  if false; then/
}
SED
try "vnext_account_held_notice_wired" "session end says so when the login the box used belongs to another account" "$CLI" "$EXEC_CLAUDE_BATS"

# The notice names this box's entry, never a newer one another box held.
cat > "$SED_TMP" << 'SED'
/^_account_held_notice()/,/^}$/{
  s/^    \[\[ -z "[$]f_id" && "[$]box" == "[$]cname" && "[$]reason" == "other-account" \]\] .. continue$/    [[ -z "$f_id" \&\& "$reason" == "other-account" ]] || continue/
}
SED
try "vnext_account_held_notice_box" "session end says so when the login the box used belongs to another account" "$CLI" "$EXEC_CLAUDE_BATS"

# adopt never saves one verified person's login over another's account.
cat > "$SED_TMP" << 'SED'
/^_account_adopt_locked()/,/^}$/{
  s/^    if \[\[ -n "[$]huuid" && -n "[$]auuid" && "[$]huuid" != "[$]auuid" \]\]; then$/    if false; then/
}
SED
try "vnext_account_adopt_identity_conflict" "adopt refuses a login verified as a different person" "$CLI" "$ACCOUNTS_BATS"

# An entry nobody verified never clears the identity of the account it joins.
cat > "$SED_TMP" << 'SED'
/^_account_adopt_locked()/,/^}$/{
  s/^  if \[\[ -n "[$]huuid" .. [$]created -eq 1 \]\]; then$/  if true; then/
}
SED
try "vnext_account_adopt_unverified_keeps_identity" "a login nobody verified adopted back into its account keeps the account verified"

# ── single-rename, key-scoped staging ──────────────────────────────────────

# vnext: a switch staged with `rm -f` and renamed the new login in only later,
# about 25 ms with no credential file at all. A Claude the live gate missed
# answered "Not logged in" into it. The same removal erased the box's own MCP
# login, so the one mutation is tried against both tests.
cat > "$SED_TMP" << 'SED'
/^_account_switch_locked()/,/^}$/{
  s@^  if ! _account_sync_in_locked "[$]cname" "[$]stage_mode"; then$@  rm -f "$(_account_box_auth_dir "$cname")/.credentials.json" 2>/dev/null || true; if ! _account_sync_in_locked "$cname" "$stage_mode"; then@
}
SED
try "vnext_account_switch_no_file_gap" "a switch never leaves the box without a credential file"
try "vnext_account_switch_no_file_gap_mcp" "switching a box to another account keeps its own MCP login"

# Nothing is removed before the staging, so a staging that fails leaves the old
# login in place and the pin has to go back with it.
cat > "$SED_TMP" << 'SED'
/^_account_switch_locked()/,/^}$/{
  s/^      _box_account_write "[$]cname" "[$]current" .*$/      :/
}
SED
try "vnext_account_switch_failed_stage_repins" "a switch that cannot stage puts the pin back on the account it left" "$CLI" "$ACCOUNTS_BATS"

cat > "$SED_TMP" << 'SED'
/^_account_switch_locked()/,/^}$/{
  s/^      _box_account_remove "[$]cname"$/      :/
}
SED
try "vnext_account_switch_failed_stage_unpins" "a switch from the shared login that cannot stage leaves the box unpinned" "$CLI" "$ACCOUNTS_BATS"

# A rename onto a directory moves the temp INTO it and reports success.
cat > "$SED_TMP" << 'SED'
/^_account_write_file_0600()/,/^}$/{
  s/^  \[\[ -d "[$]dest" \]\] && return 1$/  :/
}
SED
try "vnext_account_stage_refuses_directory" "a switch from the shared login that cannot stage leaves the box unpinned" "$CLI" "$ACCOUNTS_BATS"

# A symlink the box planted at its own staged path must not block a switch.
cat > "$SED_TMP" << 'SED'
/^_account_sync_in_locked()/,/^}$/{
  s/^        rm -f "[$]box_cred" 2>\/dev\/null .. true$/        :/
}
SED
try "vnext_account_switch_drops_symlink" "switching replaces a symlink the box planted" "$CLI" "$ACCOUNTS_BATS"

# vnext: staging copied the whole store over the box's file, erasing an MCP
# server login made inside the box. Without the base it is a projection again.
cat > "$SED_TMP" << 'SED'
/^_account_sync_in_locked()/,/^}$/{
  s/^  _account_write_file_0600 "[$]store_cred" "[$]box_cred" "[$]snap" .. rc=1$/  _account_write_file_0600 "$store_cred" "$box_cred" || rc=1/
}
SED
try "vnext_account_stage_keeps_box_keys" "an MCP server login made inside a pinned box survives the next attach"

# vnext: the harvest copied the whole box file into the store, so one box's MCP
# tokens reached the account and every other box pinned to it.
cat > "$SED_TMP" << 'SED'
/^_account_write_file_0600()/,/^}$/{
  s/_account_cred_merge "[$]base" "[$]src" > "[$]tmp"/cat "$src" > "$tmp"/
}
SED
try "vnext_account_store_only_account_keys" "never reaches the account store or another box"

# A store write carries the login the readers found. A login nested one level
# down projected to {} and was written over the account's only copy.
cat > "$SED_TMP" << 'SED'
/^_account_write_file_0600()/,/^}$/{
  s/^  if \[\[ -n "[$]src" && -z "[$]base" && .*; then$/  if false; then/
}
SED
try "vnext_account_store_write_keeps_login" "a harvest never writes a store without the login it read" "$CLI" "$ACCOUNTS_BATS"

# A switch to an account with no login strips the account's keys and keeps the
# rest. Removing the file took the box's MCP login with it.
cat > "$SED_TMP" << 'SED'
/^_account_sync_in_locked()/,/^}$/{
  s@^    if \[\[ "[$](_account_cred_merge "[$]snap" "" 2>/dev/null .. true)" != "{}" \]\]; then$@    if false; then@
}
SED
try "vnext_account_force_empty_keeps_box_keys" "switching to an account with no login signs the box out but keeps its MCP login" "$CLI" "$ACCOUNTS_BATS"

# The merge output goes into a box or a store, so it never reads through a link.
cat > "$SED_TMP" << 'SED'
/^_account_cred_merge()/,/^}$/{
  s/^  \[\[ -L "[$]base" .. -L "[$]src" \]\] && return 1$/  :/
}
SED
try "vnext_account_merge_refuses_symlink" "the credential merge refuses to read through a symlink" "$CLI" "$ACCOUNTS_BATS"

# The splitter fails closed on bytes after a value instead of copying them.
cat > "$SED_TMP" << 'SED'
/^_ACCOUNT_MERGE_AWK='$/,/^}'$/{
  s/^      if (done && index(" \\t\\r\\n", c) == 0) return 0$/      if (0) return 0/
}
SED
try "vnext_account_merge_fails_closed" "a box file the splitter cannot read is replaced by the account" "$CLI" "$ACCOUNTS_BATS"

# A jq-only branch that behaves differently is exactly the drift jq-optional forbids.
cat > "$SED_TMP" << 'SED'
/^_account_cred_merge()/,/^}$/{
  s/^  local base="[$]1" src="[$]2" have_src=1$/  local base="$1" src="$2" have_src=1; command -v jq >\/dev\/null 2>\&1 \&\& base=/
}
SED
try "vnext_account_merge_same_without_jq" "staging by key writes the same bytes with and without jq" "$CLI" "$ACCOUNTS_BATS"

# An equal expiry rewrote the same login on every attach, moving the file under
# any session running in the box.
cat > "$SED_TMP" << 'SED'
/^_account_sync_in_locked()/,/^}$/{
  s/ && \[\[ "[$]bobj" != "[$]sobj" \]\]; }/ \&\& true; }/
}
SED
try "vnext_account_attach_skips_identical" "an attach does not rewrite a staged login that already matches the store" "$CLI" "$ACCOUNTS_BATS"

# A held login is the bytes it was found in. A projection loses the box's MCP
# login and never matches the dedupe's byte compare.
cat > "$SED_TMP" << 'SED'
/^_account_hold()/,/^}$/{
  s/^  if ! _account_copy_whole_0600 "[$]src"/  if ! _account_write_file_0600 "$src"/
}
SED
try "vnext_account_held_copy_whole" "a held login keeps every key the box had" "$CLI" "$ACCOUNTS_BATS"

# ── the browser destination gate ────────────────────────────────────────────

# Userinfo must be REJECTED, never stripped. https://claude.ai@evil.example/ has
# the attacker's host to the RIGHT of the @, so ${authority%%@*} hands back the
# name they chose.
# The delimiter cannot be @ here: the pattern contains one, which is the whole
# point of the guard.
cat > "$SED_TMP" << 'SED'
/^_bridge_url_host()/,/^}$/{
  s|case "$authority" in \*@\*) return 1 ;; esac|authority="${authority%%@*}"|
}
SED
try "vnext_bridge_userinfo_rejected" "userinfo is rejected, never stripped" "$CLI" "$BROWSER_BRIDGE_BATS"

# One charset rule kills a percent-encoded authority, a backslash, an
# underscore and every non-ASCII confusable in the same pass.
cat > "$SED_TMP" << 'SED'
/^_bridge_url_host()/,/^}$/{
  s@^  case "[$]authority" in \*\[!A-Za-z0-9.:-\]\*) return 1 ;; esac$@  :@
}
SED
try "vnext_bridge_authority_charset" "an authority byte outside the charset is refused" "$CLI" "$BROWSER_BRIDGE_BATS"

# claude.ai. resolves and is a different string from the list entry claude.ai.
cat > "$SED_TMP" << 'SED'
/^_bridge_url_host()/,/^}$/{
  s@^  case "[$]host" in .\*|\*.|\*..\*|-\*|\*-) return 1 ;; esac$@  :@
}
SED
try "vnext_bridge_dotted_host" "a trailing dot is a different string for the same name" "$CLI" "$BROWSER_BRIDGE_BATS"

# A scheme is case-insensitive by RFC 3986 and HTTPS:// is a real thing a tool
# emits. Without the fold it is simply refused, and the login it carries dies.
cat > "$SED_TMP" << 'SED'
/^_bridge_url_host()/,/^}$/{
  s@^  scheme="[$](printf .%s. "[$]scheme" | tr .A-Z. .a-z.)"$@  :@
}
SED
try "vnext_bridge_scheme_case" "folds case, because DNS does" "$CLI" "$BROWSER_BRIDGE_BATS"

# Exact membership, never a suffix. A `*claude.ai` pattern also matches
# `evilclaude.ai`, which is how an origin allowlist usually fails.
cat > "$SED_TMP" << 'SED'
/^_bridge_origin_allowed()/,/^}$/{
  s@^    \[ "[$]host" = "[$]entry" \] && return 0$@    case "$host" in *"$entry") return 0 ;; esac@
}
SED
try "vnext_bridge_exact_match" "a near miss is not a match" "$CLI" "$BROWSER_BRIDGE_BATS"

# CLEAT_BROWSER_ORIGINS APPENDS. A user who sets it to add one origin must not
# silently lose claude.ai and break their own login.
cat > "$SED_TMP" << 'SED'
/^_bridge_origins_effective()/,/^}$/{
  s@^  for o in [$]_BROWSER_ORIGINS; do$@  for o in ${CLEAT_BROWSER_ORIGINS:+}; do@
}
SED
try "vnext_bridge_origins_append" "CLEAT_BROWSER_ORIGINS APPENDS, it never replaces" "$CLI" "$BROWSER_BRIDGE_BATS"

# A malformed env entry is dropped, never treated as a wildcard. Retargeted when
# the three copied case blocks became _bridge_entry_host: the entry is used raw
# instead of parsed.
cat > "$SED_TMP" << 'SED'
/^_bridge_origins_from_env()/,/^}$/{
  s@^    h="[$](_bridge_entry_host "[$]e" 2>/dev/null)" || h=""$@    h="$e"@
}
SED
try "vnext_bridge_bad_entry_dropped" "a malformed entry is dropped, never treated as a wildcard" "$CLI" "$BROWSER_BRIDGE_BATS"

# Claude Code 2.1.270 opens its claude.ai login on claude.com and its Console
# login on platform.claude.com. Without either host the hands-free login is
# refused in every mode. One mutation per host, each against its own test.
cat > "$SED_TMP" << 'SED'
/^_BROWSER_ORIGINS=/{
  s@ claude[.]com platform[.]claude[.]com @ platform.claude.com @
}
SED
try "vnext_bridge_origin_claude_com" "the claude.ai login Claude Code opens today" "$CLI" "$BROWSER_BRIDGE_BATS"

cat > "$SED_TMP" << 'SED'
/^_BROWSER_ORIGINS=/{
  s@ platform[.]claude[.]com @ @
}
SED
try "vnext_bridge_origin_platform_claude_com" "the Console login Claude Code opens today" "$CLI" "$BROWSER_BRIDGE_BATS"

# cleat browser allow kept "everything after the word origin" for each existing
# line, which is ` = host`, and wrote it back behind another `origin = `. Only
# the newest origin survived.
cat > "$SED_TMP" << 'SED'
/^_bridge_origin_write()/,/^}$/{
  s@^              existing+="[$]_v"[$]'\\n'$@              existing+="${_h#origin}"$'\\n'@
}
SED
try "vnext_bridge_allow_keeps_earlier" "cleat browser allow keeps every origin added before it" "$CLI" "$BROWSER_BRIDGE_BATS"

# CLEAT_BROWSER_ORIGINS is split with globbing off. The watcher runs in the
# project folder the box writes, so `*.example.com` expanded against a planted
# file name. The second mutation leaves globbing off for the caller.
cat > "$SED_TMP" << 'SED'
/^_bridge_origins_from_env()/,/^}$/{
  s@^  set -f$@  :@
}
SED
try "vnext_bridge_env_split_noglob" "a wildcard entry is never expanded against the working directory" "$CLI" "$BROWSER_BRIDGE_BATS"

cat > "$SED_TMP" << 'SED'
/^_bridge_origins_from_env()/,/^}$/{
  s@^  \[ "[$]_glob_off" = 1 \] || set +f$@  :@
}
SED
try "vnext_bridge_env_split_glob_restored" "a wildcard entry is never expanded against the working directory" "$CLI" "$BROWSER_BRIDGE_BATS"

# A host that ends in a number is an IPv4 address to a browser. 2130706433,
# 0x7f000001 and 0177.0.0.1 are all 127.0.0.1, and the text ranges missed them.
cat > "$SED_TMP" << 'SED'
/^_bridge_host_is_local()/,/^}$/{
  s@^  _bridge_ipv4_noncanonical "[$]1" && return 0$@  :@
}
SED
try "vnext_bridge_ipv4_noncanonical_refused" "an IPv4 address written as one number" "$CLI" "$BROWSER_BRIDGE_BATS"

# Only a plain dotted quad falls through to the ranges. A label with a leading
# zero is octal to a browser, so 0177.0.0.1 must not count as plain.
cat > "$SED_TMP" << 'SED'
/^_bridge_ipv4_noncanonical()/,/^}$/{
  s@^      \[0-9\]|\[1-9\]\[0-9\]|1\[0-9\]\[0-9\]|2\[0-4\]\[0-9\]|25\[0-5\]) ;;$@      [0-9]*) ;;@
}
SED
try "vnext_bridge_ipv4_leading_zero" "an IPv4 address written as one number" "$CLI" "$BROWSER_BRIDGE_BATS"

# An entry carrying :// is a URL whatever the case of its scheme. Matching only
# a lower-case http(s) prefix made HTTPS://x a bare host named `https`.
cat > "$SED_TMP" << 'SED'
/^_bridge_entry_host()/,/^}$/{
  s@^    \*://\*) _bridge_url_host "[$]1" ;;$@    http://*|https://*) _bridge_url_host "$1" ;;@
}
SED
try "vnext_bridge_entry_host_scheme_case" "an upper-case scheme is a scheme and a non-http one is refused" "$CLI" "$BROWSER_BRIDGE_BATS"

# Loopback and private space are refused on the authority that is OPENED. What
# it removes is a cookie-bearing authenticated navigation into a host service.
cat > "$SED_TMP" << 'SED'
/^_bridge_dest_allowed()/,/^}$/{
  s@^  _bridge_host_is_local "[$]host" && return 1$@  :@
}
SED
try "vnext_bridge_loopback_denied" "loopback and private space are refused on the opened URL" "$CLI" "$BROWSER_BRIDGE_BATS"

# Origins come from the GLOBAL config only. /workspace/.cleat is a file the
# caged agent edits as ordinary work, and an allowlist it can write is not one.
cat > "$SED_TMP" << 'SED'
/^_bridge_origins_from_config()/,/^}$/{
  s@_read_section_all_from_file "[$]CLEAT_GLOBAL_CONFIG" browser origin@_read_section_all_from_file "${_RESOLVED_PROJECT:-.}/.cleat" browser origin@
}
SED
try "vnext_bridge_origins_global_only" "the GLOBAL config adds an origin, the project .cleat never does" "$CLI" "$BROWSER_BRIDGE_BATS"

# Auth requires an allowlisted origin. Without it the substring `redirect_uri=`
# alone took the auto branch's early return, before the terminal was consulted.
cat > "$SED_TMP" << 'SED'
/^_is_auth_url()/,/^}$/{
  s@^  _bridge_dest_allowed "[$]url" || return 1$@  :@
}
SED
try "vnext_bridge_auth_needs_origin" "an unallowlisted origin is never auth" "$CLI" "$BROWSER_BRIDGE_BATS"

# The fragment is cut FIRST. A fragment is never sent to the server, so a
# redirect_uri there is not part of an OAuth request.
# Retargeted: the shape checks moved into _is_auth_url_shape, so the watcher
# can ask whether a refused URL would have opened with its origin listed.
cat > "$SED_TMP" << 'SED'
/^_is_auth_url_shape()/,/^}$/{
  s@^  local q="[$]{url%%#\*}"$@  local q="$url"@
}
SED
try "vnext_bridge_auth_query_only" "a fragment-borne redirect_uri is not auth" "$CLI" "$BROWSER_BRIDGE_BATS"

# The destination is the one thing nothing else in the policy can substitute for.
cat > "$SED_TMP" << 'SED'
/^_browser_should_open()/,/^}$/{
  s@^        \[ "[$]dest_ok" = 1 \] || return 1            # not on the list: never open$@        :@
}
SED
try "vnext_bridge_policy_dest" "auto never opens an unallowlisted destination" "$CLI" "$BROWSER_BRIDGE_BATS"

# Off a terminal a plain link defers. That window is cleat login, a pipe, cron
# and nohup: nobody is watching the browser, and it is the exfil primitive.
cat > "$SED_TMP" << 'SED'
/^_browser_should_open()/,/^}$/{
  s@^        return 1 ;;                               # plain link: the terminal, or nobody$@        [ "$host_opens_clicks" = 1 ] \&\& return 1; return 0 ;;@
}
SED
try "vnext_bridge_unattended_defers" "auto defers a plain link, terminal or not" "$CLI" "$BROWSER_BRIDGE_BATS"

# The callback proxy is gated on the destination. It is the only mechanism in
# Cleat that makes the host bind a box-chosen port, and it ran in every mode.
cat > "$SED_TMP" << 'SED'
/^_browser_watcher()/,/^}$/{
  s@^        if \[ -n "[$]cname" \] && \[ "[$]_is_auth" = 1 \] && \[ "[$]_dest_ok" = 1 \]; then$@        if [ -n "$cname" ]; then@
}
/^_is_auth_url()/,/^}$/{
  s@^  _bridge_dest_allowed "[$]url" || return 1$@  :@
}
SED
try "vnext_bridge_proxy_gated" "the callback proxy does not bind for an unallowlisted origin" "$CLI" "$BROWSER_BRIDGE_BATS"

# The decision is taken on the bytes that are OPENED. Stripping control
# characters rewrites an authority, so a policy reading the raw claim and an
# opener reading the cleaned copy disagree about where the browser is going.
cat > "$SED_TMP" << 'SED'
/^_browser_watcher()/,/^}$/{
  s@^        if _bridge_dest_allowed "[$]_clean_url"; then _dest_ok=1; fi$@        if _bridge_dest_allowed "$url"; then _dest_ok=1; fi@
}
SED
try "vnext_bridge_gate_on_clean_url" "the gate reads the bytes that are OPENED" "$CLI" "$BROWSER_BRIDGE_BATS"

# A port a host service already holds cannot be bound, and opening the browser
# anyway aims it at THAT service with the host's cookies.
cat > "$SED_TMP" << 'SED'
/^_browser_watcher()/,/^}$/{
  s@^            if _port_in_use "[$]cb_port"; then$@            if false; then@
}
SED
try "vnext_bridge_port_in_use" "a callback port a host service already holds opens nothing" "$CLI" "$BROWSER_BRIDGE_BATS"

# A proxy that never binds must never fall through to opening.
cat > "$SED_TMP" << 'SED'
/^_browser_watcher()/,/^}$/{
  s@^              if \[ ! -f "[$]_bw_ready" \]; then$@              if false; then@
}
SED
try "vnext_bridge_bind_before_open" "a proxy that never binds opens nothing" "$CLI" "$BROWSER_BRIDGE_BATS"

# The refusal carries a marker the foreground greps for. Without it the denial
# exists only in a log inside the box's own clip dir, which the box can rewrite.
# Retargeted: the read is an anchored pattern now rather than `grep -F`, so the
# sed matches the line by its start. The property is unchanged.
cat > "$SED_TMP" << 'SED'
/^_maybe_report_blocked_opens()/,/^}$/{
  s@^  lines="[$](tail -c .*$@  lines="" || return 0@
}
SED
try "vnext_bridge_blocked_reported" "names the URL, the bare origin and the command that allows it" "$CLI" "$BROWSER_BRIDGE_BATS"

# Only THIS session. Without the offset a refusal from an earlier run re-fires
# on every launch, which is the nagging concept/21 forbids.
cat > "$SED_TMP" << 'SED'
/^_maybe_report_blocked_opens()/,/^}$/{
  s@tail -c "+[$](( off + 1 ))" "[$]log"@cat "$log"@
}
SED
try "vnext_bridge_blocked_this_session" "only this session, never a previous one" "$CLI" "$BROWSER_BRIDGE_BATS"

# The log is box-written, so everything printed from it is sanitized first.
cat > "$SED_TMP" << 'SED'
/^_maybe_report_blocked_opens()/,/^}$/{
  s@^    url="[$](_sanitize_repo_str "[$]url")"$@    :@
}
SED
try "vnext_bridge_blocked_sanitized" "a forged log line cannot inject terminal control bytes" "$CLI" "$BROWSER_BRIDGE_BATS"

# The claim read is bounded. The box picks the file's size.
cat > "$SED_TMP" << 'SED'
/^_browser_claim_url()/,/^}$/{
  s@^  head -c 8192 "[$]claim" 2>/dev/null || true$@  cat "$claim" 2>/dev/null || true@
}
SED
try "vnext_bridge_claim_bounded" "the claim read is bounded" "$CLI" "$BROWSER_BRIDGE_BATS"

# ── refusal reporting, 2026-09-13 ───────────────────────────────────────────

# cleat shell runs the browser watcher, so a login from the shell can be
# refused. Without the report the refusal lives only in the box's own log.
cat > "$SED_TMP" << 'SED'
/^cmd_shell()/,/^}$/{
  /_maybe_report_blocked_opens "[$]_shell_clip_dir\/.proxy-log"/d
}
SED
try "vnext_refusal_shell_reports" "cleat shell reports a browser open the gate refused" "$CLI" "$REGRESSIONS"

# cleat login promises the browser will open. A refused origin must say why not.
cat > "$SED_TMP" << 'SED'
/^cmd_login()/,/^}$/{
  /_maybe_report_blocked_opens "[$]_login_clip_dir\/.proxy-log"/d
}
SED
try "vnext_refusal_login_reports" "cleat login reports a browser open the gate refused" "$CLI" "$REGRESSIONS"

# Only this shell's window of the log. Offset 0 re-reports a refusal from an
# earlier session on every shell, which is the nag concept/21 forbids.
cat > "$SED_TMP" << 'SED'
/^cmd_shell()/,/^}$/{
  s@ "[$]_shell_proxy_off"$@ 0@
}
SED
try "vnext_refusal_shell_offset" "cleat shell reports a browser open the gate refused" "$CLI" "$REGRESSIONS"

cat > "$SED_TMP" << 'SED'
/^cmd_login()/,/^}$/{
  s@ "[$]_login_proxy_off"$@ 0@
}
SED
try "vnext_refusal_login_offset" "cleat login reports a browser open the gate refused" "$CLI" "$REGRESSIONS"

# The URL is everything after the FIRST url=. The last one sat inside a
# return_url= parameter and printed a truncated URL.
cat > "$SED_TMP" << 'SED'
/^_maybe_report_blocked_opens()/,/^}$/{
  s@^    url="[$]{rest#\* url=}"$@    url="${l##*url=}"@
}
SED
try "vnext_refusal_first_url" "carrying return_url" "$CLI" "$REGRESSIONS"

# Revert to the old origin read, the LAST origin= on the line: a trailing
# origin= in the query names the host the allow line prints.
cat > "$SED_TMP" << 'SED'
/^_maybe_report_blocked_opens()/,/^}$/{
  s@^    origin="[$](_bridge_url_host "[$]url" 2>/dev/null)" || origin=""$@    origin="${l##*origin=}"; origin="${origin%% *}"@
}
SED
try "vnext_refusal_first_origin" "carrying return_url" "$CLI" "$REGRESSIONS"

# The origin is re-derived from the URL, never read from the box-writable
# field, so the allow line always names the host of the URL printed above it.
cat > "$SED_TMP" << 'SED'
/^_maybe_report_blocked_opens()/,/^}$/{
  s@^    origin="[$](_bridge_url_host "[$]url" 2>/dev/null)" || origin=""$@    origin="${rest%% *}"@
}
SED
try "vnext_refusal_origin_from_url" "never the logged origin field" "$CLI" "$BROWSER_BRIDGE_BATS"

# Only a line the watcher shaped counts, anchored on its first byte. Unanchored,
# a URL carrying the whole line shape forges a refusal naming any host.
cat > "$SED_TMP" << 'SED'
/^_maybe_report_blocked_opens()/,/^}$/{
  s@grep "^\[\[]browser-watcher@grep "[[]browser-watcher@
}
SED
try "vnext_refusal_anchored" "marker text inside a URL is never read as a refusal" "$CLI" "$REGRESSIONS"

# A refusal is recorded only for a URL listing its origin would have opened.
# Without the shape check a plain link and a loopback URL printed an allow line
# that could never make them open.
cat > "$SED_TMP" << 'SED'
/^_browser_watcher()/,/^}$/{
  s@ && _is_auth_url_shape "[$]_clean_url"; then$@; then@
}
SED
try "vnext_refusal_auth_shape_only" "a plain link or a loopback URL is never reported as blocked" "$CLI" "$REGRESSIONS"

# cleat browser allow refuses a loopback host, so the report never prints it.
cat > "$SED_TMP" << 'SED'
/^_maybe_report_blocked_opens()/,/^}$/{
  s@^    elif _bridge_host_is_local "[$]origin"; then$@    elif false; then@
}
SED
try "vnext_refusal_loopback_no_allow" "a loopback login gets no allow line" "$CLI" "$BROWSER_BRIDGE_BATS"

# A local host parses but never opens, so the listing puts it under ignored.
cat > "$SED_TMP" << 'SED'
/^_bridge_origins_from_env()/,/^}$/{
  s@^    \[ -n "[$]h" \] && _bridge_host_is_local "[$]h" && h=""$@    :@
}
SED
try "vnext_refusal_env_local_bad" "is listed as ignored, never as accepted" "$CLI" "$BROWSER_BRIDGE_BATS"

cat > "$SED_TMP" << 'SED'
/^_bridge_origins_from_config()/,/^}$/{
  s@^    \[ -n "[$]h" \] && _bridge_host_is_local "[$]h" && h=""$@    :@
}
SED
try "vnext_refusal_config_local_bad" "is listed as ignored, never as accepted" "$CLI" "$BROWSER_BRIDGE_BATS"

# ── channel 3: the ~/.claude root ───────────────────────────────────────────

# Every instruction surface is mounted :ro. Without the mount the box creates a
# file at the root that a later session, or the host's own uncaged Claude Code,
# reads as configuration or as hooks. No capability, no prompt, no egress.
cat > "$SED_TMP" << 'SED'
s@^    mount_args+=(-v "[$]home_overlay/instr/[$]_id:/home/coder/.claude/[$]_id:ro")$@    :@
SED
try "vnext_instr_surfaces_masked" "every instruction surface at the ~/.claude root is mounted read-only" "$CLI" "$KITS_BATS"

# Read-only, not read-write. A writable mask is not a mask.
cat > "$SED_TMP" << 'SED'
s@^    mount_args+=(-v "[$]home_overlay/instr/[$]_id:/home/coder/.claude/[$]_id:ro")$@    mount_args+=(-v "$home_overlay/instr/$_id:/home/coder/.claude/$_id")@
SED
try "vnext_instr_surfaces_readonly" "every instruction surface at the ~/.claude root is mounted read-only" "$CLI" "$KITS_BATS"

# A JSON placeholder is `{}` and not an empty file: the reader that would choke
# on an invalid one is the user's OWN Claude Code. The placeholder moved into
# _claude_instr_placeholder, which both the host target and the overlay use.
cat > "$SED_TMP" << 'SED'
/^_claude_instr_placeholder()/,/^}$/{
  s@^    [*][.]json)           printf '{}\\n' ;;$@    *.json)           : ;;@
}
SED
try "vnext_instr_json_placeholder" "the host targets are created inert" "$CLI" "$KITS_BATS"

# An existing host file is never replaced. Its content is the user's.
cat > "$SED_TMP" << 'SED'
/^_ensure_kit_mask_targets()/,/^}$/{
  s@^    \[\[ -e "[$]{HOME}/.claude/[$]_p" || -L "[$]{HOME}/.claude/[$]_p" \]\] && continue$@    :@
}
SED
try "vnext_instr_keeps_existing" "the host targets are created inert" "$CLI" "$KITS_BATS"

# A box that predates the masks is told. A mount change fires no config-drift
# prompt, so this advisory is the only signal an existing box gets.
cat > "$SED_TMP" << 'SED'
/^_maybe_note_missing_kit_masks()/,/^}$/{
  s@^    if ! printf .%s.n. "[$]dests" | grep -qx "/home/coder/.claude/[$]_instr"; then$@    if false; then@
}
SED
try "vnext_instr_recreate_note" "a box missing the instruction-surface masks is told" "$CLI" "$KITS_BATS"

# The containment source guard itself: --privileged voids every other boundary
# in the product in one word.
cat > "$SED_TMP" << 'SED'
s@^  docker run -d \\$@  docker run -d --privileged \\@
SED
try "vnext_never_privileged" "docker run never carries" "$CLI" "$REGRESSIONS"

# ── channel 3, batch 2: the rest of the vendor deny list ────────────────────

# session-env/<id>/ holds hook env files the HOST's Claude Code runs ahead of its
# next Bash command. Back on the shared host dir, a box drops one into a live
# host session.
cat > "$SED_TMP" << 'SED'
s@^_CLAUDE_PRIVATE_DIRS="\(.*\) session-env \(.*\)"$@_CLAUDE_PRIVATE_DIRS="\1 \2"@
SED
try "vnext_ch3_private_session_env" "session-env, daemon and seed-admin are per-box" "$CLI" "$REGRESSIONS"

# daemon/dispatch/ is watched by the host daemon, and an exec-mode job names a
# command its worker spawns.
cat > "$SED_TMP" << 'SED'
s@^_CLAUDE_PRIVATE_DIRS="\(.*\) daemon \(.*\)"$@_CLAUDE_PRIVATE_DIRS="\1 \2"@
SED
try "vnext_ch3_private_daemon" "session-env, daemon and seed-admin are per-box" "$CLI" "$REGRESSIONS"

# seed-admin/ is where the host stages git metadata and then runs git.
cat > "$SED_TMP" << 'SED'
s@^_CLAUDE_PRIVATE_DIRS="\(.*\) seed-admin \(.*\)"$@_CLAUDE_PRIVATE_DIRS="\1 \2"@
SED
try "vnext_ch3_private_seed_admin" "session-env, daemon and seed-admin are per-box" "$CLI" "$REGRESSIONS"

# Claude Code refuses a group-writable seed-admin. Under umask 002 the host
# target created for the mask would be one.
cat > "$SED_TMP" << 'SED'
/^_ensure_kit_mask_targets()/,/^}$/{
  /^    chmod go-w "[$]{HOME}\/.claude\/[$]_p" 2>\/dev\/null || true$/d
}
SED
try "vnext_ch3_private_dir_mode_host" "never group or other writable, even under umask 002" "$CLI" "$KITS_BATS"

# And the same for the per-box overlay the box's own Claude Code checks.
cat > "$SED_TMP" << 'SED'
/^_generate_home_overlay()/,/^}$/{
  /^    chmod go-w "[$]home_dir\/[$]_d" 2>\/dev\/null || true$/d
}
SED
try "vnext_ch3_private_dir_mode_overlay" "never group or other writable, even under umask 002" "$CLI" "$KITS_BATS"

# ~/.claude/local is the npm-local launcher the host's claude alias runs.
cat > "$SED_TMP" << 'SED'
s@^\(_CLAUDE_INSTR_DIRS=".*\) local"$@\1"@
SED
try "vnext_ch3_instr_local" "the npm-local install and daemon.json are masked read-only" "$CLI" "$REGRESSIONS"

# daemon.json is the background daemon's worker config.
cat > "$SED_TMP" << 'SED'
s@^\(_CLAUDE_INSTR_FILES=".*\) daemon[.]json"$@\1"@
SED
try "vnext_ch3_instr_daemon_json" "the npm-local install and daemon.json are masked read-only" "$CLI" "$REGRESSIONS"

# A box that predates session-env, daemon and seed-admin as per-box dirs is told.
cat > "$SED_TMP" << 'SED'
/^_maybe_note_missing_kit_masks()/,/^}$/{
  s@^    if ! printf .%s.n. "[$]dests" | grep -qx "/home/coder/.claude/[$]_priv"; then$@    if false; then@
}
SED
try "vnext_ch3_private_recreate_note" "missing the per-box session-env, daemon and seed-admin dirs is told" "$CLI" "$KITS_BATS"

# A box session's hook env files now live in the per-box dir, so a delete has
# to take that copy too.
cat > "$SED_TMP" << 'SED'
/^_sessions_delete_set()/,/^}$/{
  /home\/session-env\//d
}
SED
try "vnext_ch3_delete_box_session_env" "delete takes a box session" "$CLI" "$SESSIONS_BATS"

# The user's own rules, themes, workflows and output styles reach the box as a
# read-only copy. Drop the copy and they are blanked again.
cat > "$SED_TMP" << 'SED'
/^_generate_instr_overlay()/,/^}$/{
  s@^    cp -R "[$]_src/[.]" "[$]_dst/" 2>/dev/null || true$@    :@
}
SED
try "vnext_ch3_passthrough_dirs" "user-level rules and keybindings reach the box read-only" "$CLI" "$REGRESSIONS"

# And keybindings.json and loop.md, the two file surfaces it reads.
cat > "$SED_TMP" << 'SED'
/^_generate_instr_overlay()/,/^}$/{
  s@^      cat "[$]_src" > "[$]_dst" 2>/dev/null || true$@      _claude_instr_placeholder "$_i" > "$_dst"@
}
SED
try "vnext_ch3_passthrough_files" "user-level rules and keybindings reach the box read-only" "$CLI" "$REGRESSIONS"

# The overlay dir is a bind source. Replacing it strands a running box on the
# old inode.
cat > "$SED_TMP" << 'SED'
/^_generate_instr_overlay()/,/^}$/{
  s@^    mkdir -p "[$]_dst"$@    rm -rf "$_dst"; mkdir -p "$_dst"@
}
SED
try "vnext_ch3_instr_dir_in_place" "a host edit reaches the overlay in place" "$CLI" "$KITS_BATS"

# The same for a file surface.
cat > "$SED_TMP" << 'SED'
/^_generate_instr_overlay()/,/^}$/{
  s@^      cat "[$]_src" > "[$]_dst" 2>/dev/null || true$@      rm -f "$_dst"; cat "$_src" > "$_dst"@
}
SED
try "vnext_ch3_instr_file_in_place" "a host edit reaches the overlay in place" "$CLI" "$KITS_BATS"

# The copies ride the start refresh.
cat > "$SED_TMP" << 'SED'
/^cmd_start()/,/^}$/{
  /^    _generate_instr_overlay "[$]cname"$/d
}
SED
try "vnext_ch3_instr_start_refresh" "cmd_start refreshes the copies" "$CLI" "$KITS_BATS"

# And the resume refresh.
cat > "$SED_TMP" << 'SED'
/^cmd_resume()/,/^}$/{
  /^    _generate_instr_overlay "[$]cname"$/d
}
SED
try "vnext_ch3_instr_resume_refresh" "cmd_resume refreshes the copies too" "$CLI" "$KITS_BATS"

# A symlinked surface dir is not followed. A released box could have planted one.
cat > "$SED_TMP" << 'SED'
/^_generate_instr_overlay()/,/^}$/{
  s@^    \[\[ -d "[$]_src" && ! -L "[$]_src" \]\] || continue$@    [[ -d "$_src" ]] || continue@
}
SED
try "vnext_ch3_instr_dir_no_follow" "the copy follows no symlink at any depth" "$CLI" "$KITS_BATS"

# Nested links, FIFOs and sockets are dropped from the copy.
cat > "$SED_TMP" << 'SED'
/^_generate_instr_overlay()/,/^}$/{
  /^    find "[$]_dst" ! -type d ! -type f -exec rm -f {} + 2>\/dev\/null || true$/d
}
SED
try "vnext_ch3_instr_prune_links" "the copy follows no symlink at any depth" "$CLI" "$KITS_BATS"

# A symlinked file surface is not followed either.
cat > "$SED_TMP" << 'SED'
/^_generate_instr_overlay()/,/^}$/{
  s@\[\[ -f "[$]_src" && ! -L "[$]_src" \]\]@[[ -f "$_src" ]]@
}
SED
try "vnext_ch3_instr_file_no_follow" "the copy follows no symlink at any depth" "$CLI" "$KITS_BATS"

# keybindings.json needs a bindings array. A bare `{}` is a parse_error to its
# loader.
cat > "$SED_TMP" << 'SED'
/^_claude_instr_placeholder()/,/^}$/{
  s@^    keybindings[.]json) printf '{"bindings":\[\]}\\n' ;;$@    keybindings.json) printf '{}\\n' ;;@
}
SED
try "vnext_ch3_keybindings_placeholder" "keybindings.json placeholder is one Claude Code" "$CLI" "$REGRESSIONS"

# The bare `{}` an earlier build wrote on the host is repaired.
cat > "$SED_TMP" << 'SED'
/^_ensure_kit_mask_targets()/,/^}$/{
  s@^    _claude_instr_placeholder keybindings[.]json > "[$]_kb" 2>/dev/null || true$@    :@
}
SED
try "vnext_ch3_keybindings_repair" "an earlier build" "$CLI" "$KITS_BATS"

# A regular file at an instruction-surface dir target is refused. Skipped, it
# still reached docker run as an opaque "not a directory".
cat > "$SED_TMP" << 'SED'
/^_ensure_kit_mask_targets()/,/^}$/{
  s@^  for _t in [$]_CLAUDE_PRIVATE_DIRS [$]_CLAUDE_INSTR_DIRS; do$@  for _t in $_CLAUDE_PRIVATE_DIRS; do@
}
SED
try "vnext_ch3_refuse_instr_dir_file" "a regular file where an instruction-surface dir belongs is refused" "$CLI" "$REGRESSIONS"

# The same refusal covers the per-box state dirs.
cat > "$SED_TMP" << 'SED'
/^_ensure_kit_mask_targets()/,/^}$/{
  s@^  for _t in [$]_CLAUDE_PRIVATE_DIRS [$]_CLAUDE_INSTR_DIRS; do$@  for _t in $_CLAUDE_INSTR_DIRS; do@
}
SED
try "vnext_ch3_refuse_private_dir_file" "a regular file where a per-box state dir belongs is refused" "$CLI" "$KITS_BATS"

# A directory at an instruction-surface FILE target is refused.
cat > "$SED_TMP" << 'SED'
/^_ensure_kit_mask_targets()/,/^}$/{
  s@^  for _t in [$]_CLAUDE_INSTR_FILES; do$@  for _t in ; do@
}
SED
try "vnext_ch3_refuse_instr_file_dir" "a directory where an instruction-surface file belongs is refused" "$CLI" "$KITS_BATS"

# A broken symlink at an instruction-surface target is refused and kept.
cat > "$SED_TMP" << 'SED'
/^_ensure_kit_mask_targets()/,/^}$/{
  s@^  for _t in [$]_CLAUDE_PRIVATE_DIRS [$]_CLAUDE_INSTR_DIRS [$]_CLAUDE_INSTR_FILES; do$@  for _t in ; do@
}
SED
try "vnext_ch3_refuse_instr_broken_link" "a broken symlink at an instruction-surface target is refused" "$CLI" "$KITS_BATS"

# The refusal has to stop cmd_run. Left to set -e, a caller in a conditional
# would switch it off and docker run would go ahead.
cat > "$SED_TMP" << 'SED'
/^cmd_run()/,/^}$/{
  s@^  _ensure_kit_mask_targets || exit 1$@  _ensure_kit_mask_targets@
}
SED
try "vnext_ch3_cmd_run_stops_on_refusal" "a regular file where an instruction-surface dir belongs is refused" "$CLI" "$REGRESSIONS"

# A second writable bind of the host's ~/.claude sidesteps every mask while every
# per-name test stays green. The mount-shape guard is what sees it.
cat > "$SED_TMP" << 'SED'
s@^    -v "[$]{HOME}/.claude/plugins:/home/coder/.claude/plugins:ro"$@    -v "${HOME}/.claude/plugins:/home/coder/.claude/plugins:ro" -v "${HOME}/.claude:/home/coder/.claude/routines-new"@
SED
try "vnext_claude_root_alias_mount" "no writable mount under the box" "$CLI" "$KITS_BATS"

# A writable source inside the host's ~/.claude that is not this project's own
# session dir, here under the docker cap.
cat > "$SED_TMP" << 'SED'
s@^    mount_args+=(-v "[$]{project_session_dir}:/home/coder/.claude/projects/[$]{_host_project_key}")$@    mount_args+=(-v "${HOME}/.claude/projects:/home/coder/.claude/projects/${_host_project_key}")@
SED
try "vnext_ch3_foreign_rw_source" "the docker cap adds only its host-path session key" "$CLI" "$KITS_BATS"

# ~/.claude/.config.json cannot be masked, so a host that has one is told.
cat > "$SED_TMP" << 'SED'
/^  _maybe_note_host_global_config$/d
SED
try "vnext_ch3_cfgjson_note" "cmd_start names a" "$CLI" "$KITS_BATS"

# One that appears during a session is reported when it ends.
cat > "$SED_TMP" << 'SED'
/^exec_claude()/,/^}$/{
  /^  _maybe_report_host_global_config_appeared "[$]_cfgjson_before"$/d
}
SED
try "vnext_ch3_cfgjson_appeared" "a file that appears during a session is reported" "$CLI" "$KITS_BATS"

# And only one that was NOT there when the session began.
cat > "$SED_TMP" << 'SED'
/^exec_claude()/,/^}$/{
  s@^  _host_global_config_present && _cfgjson_before=1$@  :@
}
SED
try "vnext_ch3_cfgjson_before" "a file already there when the session began" "$CLI" "$KITS_BATS"

# ── the hook bridge: source, payload and matcher ────────────────────────────

# The hook COMMAND comes from the host settings file alone. Both project files
# sit inside the read-write /workspace mount, so a command read from one is a
# command the box can write: event one runs the user's hook, the box rewrites
# the file, event two runs the rewritten command on the HOST.
cat > "$SED_TMP" << 'SED'
/^_has_host_hooks()/,/^}$/{
  s@^  \[\[ -s "[$]_HOOK_HOST_SETTINGS" \]\] || return 1$@  [[ -s "${_RESOLVED_PROJECT:-.}/.claude/settings.json" ]] \&\& return 0@
}
SED
try "vnext_hook_host_settings_only" "FALSE when only a project settings.json has hooks" "$CLI" "$HOOKS_BATS"

# And the bridge dispatches against that one file, not a list of three.
cat > "$SED_TMP" << 'SED'
/^_hook_bridge_watcher()/,/^}$/{
  s@^  \[\[ -s "[$]_HOOK_HOST_SETTINGS" \]\] && settings_files+=("[$]_HOOK_HOST_SETTINGS")$@  settings_files+=("${_RESOLVED_PROJECT:-.}/.claude/settings.json")@
}
SED
try "vnext_hook_bridge_one_source" "a command defined only in a project settings file never runs" "$CLI" "$HOOKS_BATS"

# A project file that defines hooks is NAMED. Silence there reads as "my hooks
# broke" and sends the user hunting in the wrong place.
cat > "$SED_TMP" << 'SED'
/^_hook_project_files_with_hooks()/,/^}$/{
  s|jq -e ..hooks // empty . length > 0. "[$]f" >/dev/null 2>&1 .. continue|continue|
}
SED
try "vnext_hook_project_named" "a project file that defines hooks is named rather than ignored" "$CLI" "$HOOKS_BATS"

# transcript_path is REQUIRED on every event and lives outside /workspace, so
# validating it instead of replacing it drops EVERY event and the capability
# becomes a no-op with a counter. This is the one that is fatal if missed.
cat > "$SED_TMP" << 'SED'
s|if has("transcript_path") then .transcript_path = [$]sent|if has("transcript_path") then .transcript_path = .transcript_path|
SED
try "vnext_hook_transcript_sentinel" "the required transcript_path becomes a sentinel" "$CLI" "$HOOKS_BATS"

# A path outside the workspace drops the event. The default is refuse, and this
# is the harm class that costs real money: a host path outside every mount.
cat > "$SED_TMP" << 'SED'
/^_HOOK_JQ_CANDS=/,/^'$/{
  s@^      else _hwalk(false; false; 0) | .c = (.c // "D")$@      else _hwalk(false; false; 0) | .c = (.c // "N")@
}
SED
try "vnext_hook_outside_workspace_drops" "a path outside the workspace drops the event" "$CLI" "$HOOKS_BATS"

# A traversal is refused rather than normalised away.
cat > "$SED_TMP" << 'SED'
/^_hook_translate_path_to()/,/^}$/{
  s@^    \*//\*|\*/./\*|\*/../\*|\*/.|\*/..|.|..) return 1 ;;$@    __nomatch__) return 1 ;;@
}
SED
try "vnext_hook_traversal_refused" "a traversal that lands back inside is still refused" "$CLI" "$HOOKS_BATS"

# The whole-value rejects, each a value some later consumer expands.
cat > "$SED_TMP" << 'SED'
/^_hook_translate_path_to()/,/^}$/{
  s@^    \[\[:space:\]\]\*|\*\[\[:space:\]\]) return 1 ;;$@    __nomatch__) return 1 ;;@
}
SED
try "vnext_hook_value_rejects" "leading or trailing whitespace is refused even with the right prefix" "$CLI" "$HOOKS_BATS"

# Translation targets the WORKSPACE. For a fork box that is the copy, and
# targeting the project would point the user's host hook at the ORIGIN tree
# from inside a fork box, cancelling the isolation the fork feature sells.
# Drops the fork branch exec_claude computes the workspace with.
cat > "$SED_TMP" << 'SED'
/^exec_claude()/,/^}$/{
  s@^      _hb_ws="[$](_fork_dir "[$]cname")"$@      :@
}
SED
try "vnext_hook_fork_workspace" "hook bridge the COPY, not the origin tree" "$CLI" "$REGRESSIONS"

# The bridge used to be handed cmd_run's `local _workspace`, which no caller of
# exec_claude still has in scope. Under the real binary's set -u the spawn died
# on "unbound variable", so the hooks cap was dead in every session. Only a
# real-binary test sees it: the sourced suites strip strict mode.
cat > "$SED_TMP" << 'SED'
/^      _hook_bridge_watcher "[$]hooks_file" "[$]_hb_ws" /{
  s@"[$]_hb_ws"@"$_workspace"@
}
SED
try "vnext_hook_bridge_workspace_unbound" "cap hooks start runs a host hook through a live bridge" "$CLI" "$SMOKE_BATS"

# A docker-cap box's events already carry host-absolute paths, and a
# /workspace-prefix-only rule breaks every hook there.
cat > "$SED_TMP" << 'SED'
/^_hook_translate_path_to()/,/^}$/{
  s@^      "[$]ws"/\*) rest=.*$@      __nomatch__) ;;@
}
SED
try "vnext_hook_host_absolute_ok" "a docker-cap box's host-absolute paths still validate" "$CLI" "$HOOKS_BATS"

# A sibling directory sharing the prefix is not inside it. The on-disk check
# owns that boundary: the translation's own prefix arm only picks the shape.
cat > "$SED_TMP" << 'SED'
/^_hook_phys_inside()/,/^}$/{
  s@^    "[$]ws"|"[$]ws"/\*) return 0 ;;$@    "$ws"|"$ws"*) return 0 ;;@
}
SED
try "vnext_hook_sibling_prefix" "a sibling directory with the same prefix is not inside it" "$CLI" "$HOOKS_BATS"

# The event name is bounded and charset-checked. Without it a crafted name is
# handed to jq, which is the injection the --arg fix already closed once.
cat > "$SED_TMP" << 'SED'
/^_hook_event_name_ok()/,/^}$/{
  s@^  case "[$]n" in \*\[!A-Za-z0-9_-\]\*) return 1 ;; esac$@  :@
}
SED
try "vnext_hook_event_charset" "the event name is bounded and charset-checked" "$CLI" "$HOOKS_BATS"

# One spool line is box-sized, and there was no size cap anywhere in the bridge.
cat > "$SED_TMP" << 'SED'
/^_hook_translate_event_to()/,/^}$/{
  s@^  _hook_line_fits "[$]line" || return 2$@  :@
}
SED
try "vnext_hook_line_cap" "an oversized line is dropped rather than processed" "$CLI" "$HOOKS_BATS"

# The timeout is per event. A flat number is wrong in both directions.
cat > "$SED_TMP" << 'SED'
/^_hook_timeout_for()/,/^}$/{
  s@^    Stop|SubagentStop)      printf .120. ;;$@    Stop|SubagentStop)      printf '30' ;;@
}
SED
try "vnext_hook_per_event_timeout" "the timeout is per event, not a flat 30 seconds" "$CLI" "$HOOKS_BATS"

# grep matched per LINE, so "Write\nBash" satisfied an anchored ^Bash$ while
# every other field of the payload described a Write.
cat > "$SED_TMP" << 'SED'
/^_execute_host_hooks()/,/^}$/{
  s@^        case "[$]tool_name" in@        case "__nomatch__" in@
}
SED
try "vnext_hook_matcher_single_line" "a multi-line tool_name cannot satisfy an anchored matcher" "$CLI" "$HOOKS_BATS"

# The drop log lives where a teardown cannot reach it. The box can INDUCE a
# recreate: [resources] in a project .cleat is read with no trust gate.
cat > "$SED_TMP" << 'SED'
/^_hook_drop_log()/,/^}$/{
  s@^  f="[$]CLEAT_STATE_DIR/hook-drops.log"$@  f="$CLEAT_RUN_DIR/hook-drops.log"@
}
SED
try "vnext_hook_drop_log_location" "the log lives outside every box-writable mount" "$CLI" "$HOOKS_BATS"

# Everything written from the line is box-authored, so it is collapsed to one
# line and sanitized first. Otherwise a forged payload writes its own log rows.
cat > "$SED_TMP" << 'SED'
/^_hook_drop_log()/,/^}$/{
  s|_safe="[$](printf .%s. "[$]{line:0:200}" .*tr .*)"|_safe="${line:0:200}"|
}
SED
try "vnext_hook_drop_log_onelined" "a forged event cannot inject a log line" "$CLI" "$HOOKS_BATS"

# The sanitize is the other half. tr in _sanitize_repo_str deliberately KEEPS
# tab and newline (they are field separators elsewhere), so the collapse above
# handles those and this handles the escape byte.
cat > "$SED_TMP" << 'SED'
/^_hook_drop_log()/,/^}$/{
  /_safe="[$](_sanitize_repo_str "[$]_safe")"/d
}
SED
try "vnext_hook_drop_log_sanitized" "a forged event cannot inject a log line" "$CLI" "$HOOKS_BATS"

# Validation runs BEFORE anything is dispatched, and a failure drops.
cat > "$SED_TMP" << 'SED'
/^_hook_bridge_watcher()/,/^}$/{
  s@^        _hook_translate_event_to "[$]line" "[$]_hb_ws" 2>/dev/null || _ev_rc=[$]?$@        _HOOK_EV_OUT="$line" _HOOK_EV_DIR="$_hb_ws"@
}
SED
try "vnext_hook_validate_before_dispatch" "an event naming a path outside the workspace never reaches a hook" "$CLI" "$HOOKS_BATS"

# B6: at most six host opens a minute. Raising the constant lets the seventh
# through, which is the exact count the watcher test drives.
cat > "$SED_TMP" << 'SED'
s/^_BROWSER_RATE_PER_MIN=6$/_BROWSER_RATE_PER_MIN=7/
SED
try "vnext_b6_rate_per_min" "a seventh open inside a minute is refused" "$CLI" "$BROWSER_BRIDGE_BATS"

# B6: and thirty a session.
cat > "$SED_TMP" << 'SED'
s/^_BROWSER_RATE_PER_SESSION=30$/_BROWSER_RATE_PER_SESSION=31/
SED
try "vnext_b6_rate_per_session" "thirty opens is the ceiling for one session" "$CLI" "$BROWSER_BRIDGE_BATS"

# B6: the minute is a window. A lifetime count would strand a later login.
cat > "$SED_TMP" << 'SED'
s/^_BROWSER_RATE_WINDOW_SECS=60$/_BROWSER_RATE_WINDOW_SECS=600/
SED
try "vnext_b6_rate_window" "an open older than the minute stops counting" "$CLI" "$BROWSER_BRIDGE_BATS"

# B6: the watcher consults the cap before it opens. Right constants in a helper
# nobody calls are not a cap.
cat > "$SED_TMP" << 'SED'
/^_browser_watcher()/,/^}$/{
  s/if _browser_rate_take "[$]_bw_ledger" "[$]_bw_opens"; then/if true; then/
}
SED
try "vnext_b6_rate_wired" "a seventh open inside a minute is refused" "$CLI" "$BROWSER_BRIDGE_BATS"

# B6: the minute ledger lives outside the bind mount, or the box empties it.
cat > "$SED_TMP" << 'SED'
/^_browser_watcher()/,/^}$/{
  s|_bw_ledger="[$]_bw_claim_dir/.opens"|_bw_ledger="$clip_dir/.opens"|
}
SED
try "vnext_b6_ledger_outside_mount" "a seventh open inside a minute is refused" "$CLI" "$BROWSER_BRIDGE_BATS"

# B6: a leading-zero entry is refused before arithmetic reads it as octal.
cat > "$SED_TMP" << 'SED'
/^_browser_rate_take()/,/^}$/{
  s/in ''|0[*]|/in ''|/
}
SED
try "vnext_b6_ledger_octal" "a malformed or future ledger entry neither counts nor breaks the count" "$CLI" "$BROWSER_BRIDGE_BATS"

# B6: an entry from the future is dropped, or a stepped-back clock holds the
# window shut for as long as the step.
cat > "$SED_TMP" << 'SED'
/^_browser_rate_take()/,/^}$/{
  /\[ "[$]line" -le "[$]now" \] || continue/d
}
SED
try "vnext_b6_ledger_future" "a malformed or future ledger entry neither counts nor breaks the count" "$CLI" "$BROWSER_BRIDGE_BATS"

# B6: the watcher's own open count reaches the helper and grows. Without the
# increment the session cap never closes, and it is the only cap left when the
# claim dir falls back into the mount.
cat > "$SED_TMP" << 'SED'
/^_browser_watcher()/,/^}$/{
  /_bw_opens=[$](( _bw_opens + 1 ))/d
}
SED
try "vnext_b6_session_count_wired" "counts its own opens toward the session cap" "$CLI" "$BROWSER_BRIDGE_BATS"

# B6: and the count is what is passed, not a literal.
cat > "$SED_TMP" << 'SED'
/^_browser_watcher()/,/^}$/{
  s/_browser_rate_take "[$]_bw_ledger" "[$]_bw_opens"/_browser_rate_take "$_bw_ledger" 0/
}
SED
try "vnext_b6_session_count_passed" "counts its own opens toward the session cap" "$CLI" "$BROWSER_BRIDGE_BATS"

# B6: a capped open carries the marker the session-end report reads.
cat > "$SED_TMP" << 'SED'
/^_browser_watcher()/,/^}$/{
  s/[$]{_BROWSER_CAPPED_MARK} limit=/rate cap reached limit=/
}
SED
try "vnext_b6_capped_marker_written" "counts its own opens toward the session cap" "$CLI" "$BROWSER_BRIDGE_BATS"

# B6: every caller of the refusal report gets the capped opens too. Without the
# call a capped login is a browser that never opened, with nothing on screen.
cat > "$SED_TMP" << 'SED'
/^_maybe_report_blocked_opens()/,/^}$/{
  /^  _maybe_report_capped_opens "[$]log" "[$]off"$/d
}
SED
try "vnext_b6_capped_reported" "names the URL the cap held back and how many" "$CLI" "$BROWSER_BRIDGE_BATS"

# B6: only this session's capped opens.
cat > "$SED_TMP" << 'SED'
/^_maybe_report_capped_opens()/,/^}$/{
  s@tail -c "+[$](( off + 1 ))" "[$]log"@cat "$log"@
}
SED
try "vnext_b6_capped_this_session" "capped report: only this session" "$CLI" "$BROWSER_BRIDGE_BATS"

# B6: the logged URL is box-authored, so it is sanitized before it is printed.
cat > "$SED_TMP" << 'SED'
/^_maybe_report_capped_opens()/,/^}$/{
  s@^    url="[$](_sanitize_repo_str "[$]url")"$@    :@
}
SED
try "vnext_b6_capped_sanitized" "a forged line cannot inject terminal control bytes or a heading" "$CLI" "$BROWSER_BRIDGE_BATS"

# B6: only a line the watcher shaped counts, anchored on its first byte.
cat > "$SED_TMP" << 'SED'
/^_maybe_report_capped_opens()/,/^}$/{
  s@grep "^\[\[]browser-watcher@grep "[[]browser-watcher@
}
SED
try "vnext_b6_capped_anchored" "a forged line cannot inject terminal control bytes or a heading" "$CLI" "$BROWSER_BRIDGE_BATS"

# B7: the launch summary names a bridge mode that turns the destination check off.
cat > "$SED_TMP" << 'SED'
/^_print_summary_block()/,/^}$/{
  /always) echo -e .*Browser:/d
}
SED
try "vnext_b7_summary_always" "names the browser bridge when always turns the destination check off" "$CLI" "$TERMINAL_UX_BATS"

# B7: and off.
cat > "$SED_TMP" << 'SED'
/^_print_summary_block()/,/^}$/{
  /off) *echo -e .*Browser:/d
}
SED
try "vnext_b7_summary_off" "names the browser bridge when it is off" "$CLI" "$TERMINAL_UX_BATS"

# H4: a session that runs a host hook prints the amber line the docker cap gets.
cat > "$SED_TMP" << 'SED'
/^exec_claude()/,/^}$/{
  /warn_sandbox "Host hooks enabled/d
}
SED
try "vnext_h4_host_hooks_warning" "a session that will run a host hook says what that means" "$CLI" "$HOOKS_BATS"

# ── the hook bridge: on-disk containment, the full field set, the bounded read,
# one JSON value, the character rule and the visibility logs (batch 6) ─────────

# F06: the rewrite is checked where it lands on disk. Without it a link planted
# in the read-write workspace aims a well-spelled path at any host file.
cat > "$SED_TMP" << 'SED'
/^_hook_translate_path_to()/,/^}$/{
  /^  _hook_path_inside "[$]out" "[$]ws" || return 1$/d
}
SED
try "vnext_hook_symlink_containment" "a symlink planted in the workspace cannot aim a path outside it" "$CLI" "$HOOKS_BATS"

# F06: a link that resolves to nothing is refused, as upstream refuses it.
cat > "$SED_TMP" << 'SED'
/^_hook_physical_path()/,/^}$/{
  s@^      \[ -e "[$]p" \] || return 1$@      :@
}
SED
try "vnext_hook_dangling_link_refused" "a dangling or looping symlink is refused" "$CLI" "$HOOKS_BATS"

# F06: a project reached through a symlink is found by device and inode.
cat > "$SED_TMP" << 'SED'
/^_hook_phys_inside()/,/^}$/{
  s@^    \[ "[$]a" -ef "[$]ws" \] && return 0$@    :@
}
SED
try "vnext_hook_symlinked_project_ef" "a project reached through a symlink still validates on disk" "$CLI" "$HOOKS_BATS"

# F06: the walk is bounded, as upstream bounds it.
cat > "$SED_TMP" << 'SED'
s/^_HOOK_WALK_MAX=64$/_HOOK_WALK_MAX=6400/
SED
try "vnext_hook_walk_bound" "more than the bound of missing components is refused" "$CLI" "$HOOKS_BATS"

# F06: a dot segment in a missing tail is refused, never appended to a prefix.
cat > "$SED_TMP" << 'SED'
/^_hook_physical_path()/,/^}$/{
  s@^    case "[$]base" in ''|.|..) return 1 ;; esac$@    :@
}
SED
try "vnext_hook_walk_dot_segment" "never climbs a dot segment it could not resolve" "$CLI" "$HOOKS_BATS"

# F08: every path-shaped tool_input string is a candidate, not four named fields.
cat > "$SED_TMP" << 'SED'
/^_HOOK_JQ_CANDS=/,/^'$/{
  s@^      else _hwalk(false; false; 0) | .c = (.c // "D")$@      else empty@
}
SED
try "vnext_hook_input_walk" "every path-shaped tool_input field is checked" "$CLI" "$HOOKS_BATS"

# F08: each tool_calls entry of a PostToolBatch gets the same walk.
cat > "$SED_TMP" << 'SED'
/^_HOOK_JQ_CANDS=/,/^'$/{
  s@^  (if (.tool_calls | type) == "array" then@  (if false then@
}
SED
try "vnext_hook_tool_calls_walk" "each tool_calls entry of a batch is checked" "$CLI" "$HOOKS_BATS"

# F08: a Read response's file.filePath drops the event, it is not nulled.
cat > "$SED_TMP" << 'SED'
/^_HOOK_JQ_CANDS=/,/^'$/{
  s@{c: "D", p: \["file", "filePath"\]@{c: "N", p: ["file", "filePath"]@
}
SED
try "vnext_hook_response_file_filepath" "filePath outside the workspace drops the event" "$CLI" "$HOOKS_BATS"

# F08: a filenames entry that does not map is nulled rather than passed on.
cat > "$SED_TMP" << 'SED'
/^_HOOK_JQ_CANDS=/,/^'$/{
  s@^  (if (.filenames | type) == "array" then@  (if false then@
}
SED
try "vnext_hook_response_filenames_null" "a response list entry that does not map is nulled" "$CLI" "$HOOKS_BATS"

# F08: and so is a file.outputDir.
cat > "$SED_TMP" << 'SED'
/^_HOOK_JQ_CANDS=/,/^'$/{
  s@^  (if (.file | type) == "object" and (.file.outputDir | type) == "string" then@  (if false then@
}
SED
try "vnext_hook_response_outputdir_null" "a response list entry that does not map is nulled" "$CLI" "$HOOKS_BATS"

# F08: a relative value is kept but must still land inside from the cwd.
cat > "$SED_TMP" << 'SED'
/^_hook_relative_ok()/,/^}$/{
  s@^  _hook_path_inside "[$]{base%/}[$]norm" "[$]ws"$@  true@
}
SED
try "vnext_hook_relative_containment" "a relative path field is kept, and still has to land inside" "$CLI" "$HOOKS_BATS"

# F08: and it keeps the segment rules even where it lands back inside.
cat > "$SED_TMP" << 'SED'
/^_hook_relative_ok()/,/^}$/{
  s@^      ''|..) return 1 ;;$@      __nomatch__) return 1 ;;@
}
SED
try "vnext_hook_relative_segments" "a relative path field is kept, and still has to land inside" "$CLI" "$HOOKS_BATS"

# F08: a URL key holding a real URL is not judged as a path.
cat > "$SED_TMP" << 'SED'
/^_HOOK_JQ_CANDS=/,/^'$/{
  s@(if [$]u and _hurl then empty else {p: \[[$]k\], v: .} end)@({p: [$k], v: .})@
}
SED
try "vnext_hook_url_value_skipped" "a URL field that holds a URL is not judged as a path" "$CLI" "$HOOKS_BATS"

# F08: nesting past the walk depth is refused, not left unjudged.
cat > "$SED_TMP" << 'SED'
/^_HOOK_JQ_CANDS=/,/^'$/{
  s@^  elif [$]d > 16 then@  elif false then@
}
SED
try "vnext_hook_depth_refused" "a tool_input nested past the walk depth is refused" "$CLI" "$HOOKS_BATS"

# F08: at most upstream's 256 path fields are judged for one event.
cat > "$SED_TMP" << 'SED'
/^_hook_translate_event_to()/,/^}$/{
  s@^  \[ "[$]n" -le "[$]_HOOK_PATHS_MAX" \] || return 5$@  :@
}
SED
try "vnext_hook_paths_ceiling" "more path fields than upstream" "$CLI" "$HOOKS_BATS"

# F17: the read itself stops one byte past the cap.
cat > "$SED_TMP" << 'SED'
/^_hook_read_chunk()/,/^}$/{
  s@read -r -n "[$](( _HOOK_LINE_MAX + 1 ))" _l@read -r _l@
}
SED
try "vnext_hook_read_bounded" "read no further than one byte past the cap" "$CLI" "$HOOKS_BATS"

# F17: and it counts bytes under a UTF-8 locale.
cat > "$SED_TMP" << 'SED'
/^_hook_read_chunk()/,/^}$/{
  s@^  _c="[$](LC_ALL=C$@  _c="$(:@
}
SED
try "vnext_hook_read_bytes" "counts bytes, not characters" "$CLI" "$HOOKS_BATS"

# F17: so does the size check on a line handed to validation directly.
cat > "$SED_TMP" << 'SED'
/^_hook_line_fits() ($/,/^)$/{
  s@^  LC_ALL=C$@  :@
}
SED
try "vnext_hook_line_fits_bytes" "counts bytes, not characters" "$CLI" "$HOOKS_BATS"

# F17: an oversized line is logged once and its tail is discarded, not read as
# a line of its own.
cat > "$SED_TMP" << 'SED'
/^_hook_bridge_watcher()/,/^}$/{
  s@^          _hb_skip=1$@          :@
}
SED
try "vnext_hook_oversize_skip" "an oversized line is dropped once and the event after it still runs" "$CLI" "$HOOKS_BATS"

# F18: the line holds exactly one JSON value, an object.
cat > "$SED_TMP" << 'SED'
/^_hook_translate_event_to()/,/^}$/{
  /jq -e -n '\[inputs\] | length == 1/d
}
SED
try "vnext_hook_single_json_value" "a line holding two JSON values is refused" "$CLI" "$HOOKS_BATS"

# F19: colon, format characters and line separators, judged by jq.
cat > "$SED_TMP" << 'SED'
/^_hook_segment_chars_ok()/,/^}$/{
  s@^  \[ "[$](printf '%s' "[$]1" | jq -Rs .*$@  true@
}
SED
try "vnext_hook_segment_chars_jq" "a colon, a format character or a line separator is refused in any locale" "$CLI" "$HOOKS_BATS"

# F19: only the part the box wrote is judged by character.
cat > "$SED_TMP" << 'SED'
/^_hook_translate_path_to()/,/^}$/{
  s@_hook_segment_chars_ok "[$]rest" || return 1@_hook_segment_chars_ok "$out" || return 1@
}
SED
try "vnext_hook_chars_rest_only" "never judges the host workspace path itself" "$CLI" "$HOOKS_BATS"

# F20: each drop row names its own reason, not a constant.
cat > "$SED_TMP" << 'SED'
/^_hook_bridge_watcher()/,/^}$/{
  s@_hook_drop_log "[$](_hook_drop_reason "[$]_ev_rc")"@_hook_drop_log "payload"@
}
SED
try "vnext_hook_drop_reason_logged" "each row names its reason, box, spool line md5 and offset" "$CLI" "$HOOKS_BATS"

# F20: the box.
cat > "$SED_TMP" << 'SED'
/^_hook_drop_log()/,/^}$/{
  s@^    "[$]cname" \\$@    "" \\@
}
SED
try "vnext_hook_drop_box_logged" "each row names its reason, box, spool line md5 and offset" "$CLI" "$HOOKS_BATS"

# F20: the md5 of the raw spool line.
cat > "$SED_TMP" << 'SED'
/^_hook_drop_log()/,/^}$/{
  s@^    "[$](_hook_line_md5 "[$]line")" \\$@    "" \\@
}
SED
try "vnext_hook_drop_md5_logged" "each row names its reason, box, spool line md5 and offset" "$CLI" "$HOOKS_BATS"

# F20: the byte offset, which counts each line's newline.
cat > "$SED_TMP" << 'SED'
/^_hook_bridge_watcher()/,/^}$/{
  s@_hb_pos=[$](( _hb_pos + _HOOK_CHUNK_LEN + 1 ))@_hb_pos=$(( _hb_pos + _HOOK_CHUNK_LEN ))@
}
SED
try "vnext_hook_drop_offset_logged" "each row names its reason, box, spool line md5 and offset" "$CLI" "$HOOKS_BATS"

# F20: an event handed to the hooks is logged, not only a refused one.
cat > "$SED_TMP" << 'SED'
/^_hook_bridge_watcher()/,/^}$/{
  /^        _hook_run_log "[$]_HOOK_EV_OUT"/d
}
SED
try "vnext_hook_run_logged" "an event handed to the hooks is logged" "$CLI" "$HOOKS_BATS"

# F20: the run log's tool name is box-authored and sanitized.
cat > "$SED_TMP" << 'SED'
/^_hook_run_log()/,/^}$/{
  s@^  tool="[$](_sanitize_repo_str "[$]{tool:0:64}")"$@  tool="${tool:0:64}"@
}
SED
try "vnext_hook_run_log_sanitized" "a forged tool name cannot inject a log row" "$CLI" "$HOOKS_BATS"

# F20: the run log grows with every tool call, so it is moved aside past a cap.
cat > "$SED_TMP" << 'SED'
/^_hook_run_log()/,/^}$/{
  s@^      mv -f "[$]f" "[$]f.1" 2>/dev/null || true$@      :@
}
SED
try "vnext_hook_run_log_rotated" "the log is moved aside once it passes its cap" "$CLI" "$HOOKS_BATS"

# F20: the end-of-session summary counts this box's rows only.
cat > "$SED_TMP" << 'SED'
/^_maybe_report_hook_drops()/,/^}$/{
  s@[$]2 == m && [$]4 == c {@$2 == m {@
}
SED
try "vnext_hook_report_per_box" "the summary counts only this box" "$CLI" "$HOOKS_BATS"

# F20: and blames a path only when every counted row is a path refusal.
cat > "$SED_TMP" << 'SED'
/^_maybe_report_hook_drops()/,/^}$/{
  s@if ([$]3 == "path") p++@p++@
}
SED
try "vnext_hook_report_path_wording" "the summary blames a path only when every drop named one" "$CLI" "$HOOKS_BATS"

# F20: the real start path hands the bridge its box.
cat > "$SED_TMP" << 'SED'
s@_hook_bridge_watcher "[$]hooks_file" "[$]_hb_ws" "[$]cname" @_hook_bridge_watcher "$hooks_file" "$_hb_ws" @
SED
try "vnext_hook_bridge_given_box" "a hooks session reports this box" "$CLI" "$SMOKE_BATS"

# F20: and asks the report for that box.
cat > "$SED_TMP" << 'SED'
s@_maybe_report_hook_drops "[$]_hook_drop_log_path" "[$]_hook_drop_off" "[$]cname"@_maybe_report_hook_drops "$_hook_drop_log_path" "$_hook_drop_off"@
SED
try "vnext_hook_report_given_box" "a hooks session reports this box" "$CLI" "$SMOKE_BATS"

# F35: the second transcript field is replaced too.
cat > "$SED_TMP" << 'SED'
s|if has("agent_transcript_path") then .agent_transcript_path = [$]sent|if has("agent_transcript_path") then .agent_transcript_path = .agent_transcript_path|
SED
try "vnext_hook_agent_transcript_sentinel" "agent_transcript_path becomes the sentinel too" "$CLI" "$HOOKS_BATS"

# F35: a cwd outside the workspace drops the event.
cat > "$SED_TMP" << 'SED'
/^_hook_translate_event_to()/,/^}$/{
  s@^        _hook_translate_path_to "[$]val" "[$]ws" || return 5$@        _hook_translate_path_to "$val" "$ws" || _HOOK_TP_OUT="$val"@
}
SED
try "vnext_hook_cwd_outside_drops" "every translated path field drops when it leaves the workspace" "$CLI" "$HOOKS_BATS"

# F35: so does a tool_input notebook_path.
cat > "$SED_TMP" << 'SED'
/^_HOOK_JQ_CANDS=/,/^'$/{
  s@^      else _hwalk(false; false; 0) | .c = (.c // "D")$@      else _hwalk(false; false; 0) | .c = (.c // "N")@
}
SED
try "vnext_hook_notebook_outside_drops" "every translated path field drops when it leaves the workspace" "$CLI" "$HOOKS_BATS"

# F35: and a tool_response filePath.
cat > "$SED_TMP" << 'SED'
/^_HOOK_JQ_CANDS=/,/^'$/{
  s@{c: "D", p: \["filePath"\]@{c: "N", p: ["filePath"]@
}
SED
try "vnext_hook_response_filepath_outside_drops" "every translated path field drops when it leaves the workspace" "$CLI" "$HOOKS_BATS"

# ── the hook bridge, second review of batch 6 ────────────────────────────────

# R6-1: the hook runs in the directory its relative paths were judged from.
# Without it the hook starts wherever cleat was launched, and a relative path
# judged inside /workspace/sub opens through a link the box planted at the root.
cat > "$SED_TMP" << 'SED'
/^_execute_host_hook_bg()/,/^}$/{
  s@^    if ! _hook_enter_run_dir "[$]run_dir" "[$]ws"; then$@    if false; then@
}
SED
try "vnext_hook_run_from_cwd" "a relative hook path is opened from the directory it was judged in" "$CLI" "$REGRESSIONS"

# R6-1: in a fork box that directory is the copy. Handing the hook the project,
# the origin tree, is the C2 mistake again.
cat > "$SED_TMP" << 'SED'
/^_hook_bridge_watcher()/,/^}$/{
  s@_execute_host_hook_bg "[$]_HOOK_EV_OUT" "[$]_HOOK_EV_DIR"@_execute_host_hook_bg "$_HOOK_EV_OUT" "${_RESOLVED_PROJECT:-$_HOOK_EV_DIR}"@
}
SED
try "vnext_hook_fork_run_from_copy" "hook runs in the copy, so a relative path opens the copy" "$CLI" "$REGRESSIONS"

# R6-1: the directory is judged again from where cd -P landed, not by name.
cat > "$SED_TMP" << 'SED'
/^_hook_enter_run_dir()/,/^}$/{
  s@^  _hook_phys_inside "[$]PWD" "[$]ws"$@  true@
}
SED
try "vnext_hook_run_dir_recheck" "a hook directory that leaves the workspace before it is entered" "$CLI" "$HOOKS_BATS"

# R6-1: a cwd that is not a directory here falls back to the workspace, which
# is then both the hook's directory and the base for relative paths.
cat > "$SED_TMP" << 'SED'
/^_hook_translate_event_to()/,/^}$/{
  s@^        \[ -d "[$]base" \] || base="[$]ws"$@        :@
}
SED
try "vnext_hook_cwd_missing_fallback" "a cwd that is not a directory here makes the workspace" "$CLI" "$HOOKS_BATS"

# R6-1: an empty workspace is a prefix of every absolute path.
cat > "$SED_TMP" << 'SED'
/^_hook_phys_inside()/,/^}$/{
  s@^  \[ -n "[$]a" \] && \[ -n "[$]ws" \] || return 1$@  :@
}
SED
try "vnext_hook_empty_workspace" "an empty workspace judges nothing inside it" "$CLI" "$HOOKS_BATS"

# R6-2: a relative path field has no prefix to require, so the upstream prefix
# rejects are its only guard.
cat > "$SED_TMP" << 'SED'
/^_hook_relative_ok()/,/^}$/{
  s@^    '~'\*|'[$]'\*|'%'\*|'`'\*|'!'\*|'='\*) return 1 ;;$@    __nomatch__) return 1 ;;@
}
SED
try "vnext_hook_relative_value_rejects" "a relative path field is refused for a whole-value reject" "$CLI" "$HOOKS_BATS"

# R6-2: and so is its leading or trailing whitespace arm.
cat > "$SED_TMP" << 'SED'
/^_hook_relative_ok()/,/^}$/{
  s@^    \[\[:space:\]\]\*|\*\[\[:space:\]\]) return 1 ;;$@    __nomatch__) return 1 ;;@
}
SED
try "vnext_hook_relative_whitespace" "a relative path field is refused for a whole-value reject" "$CLI" "$HOOKS_BATS"

# R6-3: filenames entries are left out of the path-field ceiling.
cat > "$SED_TMP" << 'SED'
/^_hook_translate_event_to()/,/^}$/{
  s@(map(select(.c != "L")) | length | tostring)@(length | tostring)@
}
SED
try "vnext_hook_list_uncounted" "a Grep over more files than the path-field ceiling keeps its event" "$CLI" "$REGRESSIONS"

# R6-3: their cost is bounded instead. Only the first entries are judged.
cat > "$SED_TMP" << 'SED'
/^_HOOK_JQ_CANDS=/,/^'$/{
  s@select((.value | type) == "string" and .key < [$]lmax)@select((.value | type) == "string")@
}
SED
try "vnext_hook_list_cap_judged" "filenames past the list cap are nulled without being judged" "$CLI" "$HOOKS_BATS"

# R6-3: and the rest are nulled, never passed on unjudged.
cat > "$SED_TMP" << 'SED'
/^_HOOK_JQ_CANDS=/,/^'$/{
  s@if .key >= [$]lmax and@if false and@
}
SED
try "vnext_hook_list_cap_nulled" "filenames past the list cap are nulled without being judged" "$CLI" "$HOOKS_BATS"

# R6-3: in each tool_calls entry of a batch too.
cat > "$SED_TMP" << 'SED'
/^_hook_translate_event_to()/,/^}$/{
  s@^      | (if (.tool_calls | type) == "array" then .tool_calls |= map(if type == "object" then _hlistcap else . end) else . end)$@      | .@
}
SED
try "vnext_hook_list_cap_batch" "filenames past the list cap are nulled without being judged" "$CLI" "$HOOKS_BATS"

# R6-4: a spool that shrinks resets a discard in progress.
cat > "$SED_TMP" << 'SED'
/^_hook_bridge_watcher()/,/^}$/{
  s@^    \[ "[$]file_size" -lt "[$]byte_offset" \] && _hb_skip=0$@    :@
}
SED
try "vnext_hook_oversize_skip_rewind" "a spool rewritten while an oversized line is discarded" "$CLI" "$HOOKS_BATS"

# ── the host matrix: no timeout(1), and both loopbacks ──────────────────────

# F26: a stock macOS has no timeout(1). perl's alarm is the arm that bounds it,
# so without that arm the socat wait and the hook both run bare there. One
# entry per call site, each against its own test.
cat > "$SED_TMP" << 'SED'
/^_bounded_argv()/,/^}$/{
  /^  elif command -v perl >\/dev\/null 2>&1; then$/d
  /^    _BOUNDED_ARGV=(perl -e /d
}
SED
try "vnext_bounded_perl_arm_socat" "the socat wait stays bounded on a host with no timeout" "$CLI" "$BROWSER_BRIDGE_BATS"

cat > "$SED_TMP" << 'SED'
/^_bounded_argv()/,/^}$/{
  /^  elif command -v perl >\/dev\/null 2>&1; then$/d
  /^    _BOUNDED_ARGV=(perl -e /d
}
SED
try "vnext_bounded_perl_arm_hook" "the per-event bound holds on a host with no timeout" "$CLI" "$HOOKS_BATS"

# perl has to EXEC the command. Waiting on it as a child leaves the pid the
# proxy holds on perl, so the alarm ends perl and orphans socat on the port.
cat > "$SED_TMP" << 'SED'
/^_bounded_argv()/,/^}$/{
  s|exec { [$]ARGV\[0\] } @ARGV or exit 127|system { $ARGV[0] } @ARGV; exit 127|
}
SED
try "vnext_bounded_perl_execs" "the socat wait stays bounded on a host with no timeout" "$CLI" "$BROWSER_BRIDGE_BATS"

# Homebrew's coreutils names it gtimeout.
cat > "$SED_TMP" << 'SED'
/^_bounded_argv()/,/^}$/{
  /^  elif command -v gtimeout >\/dev\/null 2>&1; then$/d
  /^    _BOUNDED_ARGV=(gtimeout "[$]1")$/d
}
SED
try "vnext_bounded_gtimeout_arm" "the bound falls back to gtimeout when there is no timeout" "$CLI" "$HOOKS_BATS"

# The call sites. socat back to bare, and the hook back to bare.
cat > "$SED_TMP" << 'SED'
/^_auth_callback_proxy()/,/^}$/{
  s@^      [$]{_BOUNDED_ARGV.*} socat "TCP-LISTEN@      socat "TCP-LISTEN@
}
SED
try "vnext_bounded_socat_site" "the socat wait stays bounded on a host with no timeout" "$CLI" "$BROWSER_BRIDGE_BATS"

cat > "$SED_TMP" << 'SED'
/^_execute_host_hooks()/,/^}$/{
  s@^        echo "[$]event_json" | _run_bounded "[$]_hto" bash -c "[$]cmd"@        echo "$event_json" | bash -c "$cmd"@
}
SED
try "vnext_bounded_hook_site" "the per-event bound holds on a host with no timeout" "$CLI" "$HOOKS_BATS"

# The two hook regressions that were source greps, now behaviour. The default
# arm: the hook back to bare holds it past its bound on any host.
cat > "$SED_TMP" << 'SED'
/^_execute_host_hooks()/,/^}$/{
  s@^        echo "[$]event_json" | _run_bounded "[$]_hto" bash -c "[$]cmd"@        echo "$event_json" | bash -c "$cmd"@
}
SED
try "vnext_bounded_hook_default_arm" "hook bridge wraps execution in a timeout" "$CLI" "$REGRESSIONS"

# A bound that only runs the hook when timeout(1) exists drops it everywhere
# else. The hook must still run, bare, with nothing to bound it.
cat > "$SED_TMP" << 'SED'
/^_execute_host_hooks()/,/^}$/{
  s@^        echo "[$]event_json" | _run_bounded "[$]_hto" bash -c "[$]cmd"@        command -v timeout >/dev/null 2>\&1 \&\& echo "$event_json" | timeout "$_hto" bash -c "$cmd"@
}
SED
try "vnext_bounded_hook_runs_unbounded" "hook bridge has fallback when timeout command missing" "$CLI" "$REGRESSIONS"

# One wait both backends read. The python leg had its own 300.
if command -v python3 >/dev/null 2>&1; then
cat > "$SED_TMP" << 'SED'
/^_auth_callback_proxy()/,/^}$/{
  s@^srv[.]settimeout(wait_secs)$@srv.settimeout(300)@
}
SED
try "vnext_acp_wait_python_shared" "the python backend waits the same _ACP_WAIT_SECS as socat" "$CLI" "$BROWSER_BRIDGE_BATS"

# F27: the busy-port probe asks both loopbacks. Registered only where the paired
# test can run: a skipped test reads as a missed mutation.
cat > "$SED_TMP" << 'SED'
/^_port_in_use()/,/^}$/{
  s@^  for _lo in 127[.]0[.]0[.]1 ::1; do$@  for _lo in ::1; do@
}
SED
try "vnext_port_probe_ipv4_leg" "holds the port, and the port is free once it goes" "$CLI" "$BROWSER_BRIDGE_BATS"

if python3 -c 'import socket; socket.socket(socket.AF_INET6).bind(("::1", 0))' >/dev/null 2>&1; then
cat > "$SED_TMP" << 'SED'
/^_port_in_use()/,/^}$/{
  s@^  for _lo in 127[.]0[.]0[.]1 ::1; do$@  for _lo in 127.0.0.1; do@
}
SED
try "vnext_port_probe_ipv6_leg" "alone holds the port too" "$CLI" "$BROWSER_BRIDGE_BATS"
fi
fi

# ── test quality: guards that had a test but no entry, or neither ───────────

# The project .cleat is a file the caged agent edits, so an ADDED project read
# is as bad as a replaced global one. Two shapes, one per way a regression
# would find the file: the resolved project, and the working directory.
cat > "$SED_TMP" << 'SED'
/^_bridge_origins_effective()/,/^}$/{
  s@^  _bridge_origins_from_config ok$@  _bridge_origins_from_config ok; _read_section_all_from_file "${_RESOLVED_PROJECT:-.}/.cleat" browser origin@
}
SED
try "vnext_bridge_origins_no_project_read" "the GLOBAL config adds an origin" "$CLI" "$BROWSER_BRIDGE_BATS"

cat > "$SED_TMP" << 'SED'
/^_bridge_origins_effective()/,/^}$/{
  s@^  _bridge_origins_from_config ok$@  _bridge_origins_from_config ok; _read_section_all_from_file "$PWD/.cleat" browser origin@
}
SED
try "vnext_bridge_origins_no_cwd_read" "the GLOBAL config adds an origin" "$CLI" "$BROWSER_BRIDGE_BATS"

# [browser] is a known section in the global config, where origins live.
cat > "$SED_TMP" << 'SED'
/^_warn_unknown_cleat_sections()/,/^}$/{
  /^          browser) continue ;;$/d
}
SED
try "vnext_browser_section_known_global" "a browser section in the global config" "$CLI" "$PROVISION_BATS"

# And in a project .cleat it says where origins go, not merely "unknown".
cat > "$SED_TMP" << 'SED'
/^_warn_unknown_cleat_sections()/,/^}$/{
  s@^          browser)$@          __nobrowser__)@
}
SED
try "vnext_browser_section_project_warns" "says origins are global" "$CLI" "$PROVISION_BATS"

# The watcher opens nothing until a backend writes the ready file. One entry per
# backend, each against the test that drives that backend for real.
cat > "$SED_TMP" << 'SED'
/^_auth_callback_proxy()/,/^}$/{
  s@^        kill -0 "[$]_acp_child" 2>/dev/null && : > "[$]ready_file" 2>/dev/null || true$@        true@
}
SED
try "vnext_proxy_ready_socat" "the socat backend signals readiness" "$CLI" "$BROWSER_BRIDGE_BATS"

# The value a real login meets, not only the site that reads it.
cat > "$SED_TMP" << 'SED'
s@^_ACP_WAIT_SECS=300$@_ACP_WAIT_SECS=3000@
SED
try "vnext_acp_wait_300" "the socat wait is bounded at 300 seconds" "$CLI" "$BROWSER_BRIDGE_BATS"

# The session calls both end-of-session reports and hands each the offset it
# captured before the session, not the start of the file.
cat > "$SED_TMP" << 'SED'
/^exec_claude()/,/^}$/{
  /^  _maybe_report_blocked_opens "[$]_CLIP_DIR\/.proxy-log" "[$]_proxy_log_off"$/d
}
SED
try "vnext_session_end_reports_blocked" "a refusal written during the session is reported" "$CLI" "$EXEC_CLAUDE_BATS"

cat > "$SED_TMP" << 'SED'
/^exec_claude()/,/^}$/{
  /^  _maybe_report_hook_drops "[$]_hook_drop_log_path" /d
}
SED
try "vnext_session_end_reports_hook_drops" "a hook drop written during the session" "$CLI" "$EXEC_CLAUDE_BATS"

cat > "$SED_TMP" << 'SED'
/^exec_claude()/,/^}$/{
  s@^  _proxy_log_off="[$](_cap_watcher_log "[$]_CLIP_DIR/.proxy-log")"$@  _proxy_log_off=0@
}
SED
try "vnext_session_end_proxy_log_offset" "a refusal from an earlier session is not repeated" "$CLI" "$EXEC_CLAUDE_BATS"

cat > "$SED_TMP" << 'SED'
/^exec_claude()/,/^}$/{
  s@^    _hook_drop_off="[$](wc -c < "[$]_hook_drop_log_path" .*$@    _hook_drop_off=0@
}
SED
try "vnext_session_end_hook_drop_offset" "a hook drop written during the session" "$CLI" "$EXEC_CLAUDE_BATS"

# --privileged assembled on the session exec, where no text guard can see it.
# Retargeted for M3: the session docker exec now sits inside the relaunch loop,
# so it carries four leading spaces instead of two. Same line, same guard.
cat > "$SED_TMP" << 'SED'
/^exec_claude()/,/^}$/{
  s|^    docker exec -it "[$]{CLAUDE_ENV\[@\]}" \\$|    docker exec -it "--priv""ileged" "${CLAUDE_ENV[@]}" \\|
}
SED
try "vnext_never_privileged_exec" "the session docker exec never carries" "$CLI" "$REGRESSIONS"

# The shipped origin list is pinned in both directions: a host dropped and a
# host added.
cat > "$SED_TMP" << 'SED'
s@^app[.]terraform[.]io sentry[.]io gitlab[.]com"$@app.terraform.io sentry.io"@
SED
try "vnext_bridge_list_pinned_drop" "the shipped list is exactly the catalogued set" "$CLI" "$BROWSER_BRIDGE_BATS"

cat > "$SED_TMP" << 'SED'
s@^app[.]terraform[.]io sentry[.]io gitlab[.]com"$@app.terraform.io sentry.io gitlab.com login.example.com"@
SED
try "vnext_bridge_list_pinned_add" "the shipped list is exactly the catalogued set" "$CLI" "$BROWSER_BRIDGE_BATS"

# The decoded redirect_uri has to parse, so userinfo there is not auth.
cat > "$SED_TMP" << 'SED'
/^_is_auth_url_shape()/,/^}$/{
  s@^  _bridge_url_host "[$]dec" >/dev/null 2>&1 || return 1$@  :@
}
SED
try "vnext_bridge_redirect_authority_parse" "whose authority does not parse" "$CLI" "$BROWSER_BRIDGE_BATS"

# cleat browser allow refuses a loopback or private host.
cat > "$SED_TMP" << 'SED'
/^cmd_browser()/,/^}$/{
  s@^  if _bridge_host_is_local "[$]host"; then$@  if false; then@
}
SED
try "vnext_bridge_allow_refuses_local" "cleat browser allow refuses a loopback host" "$CLI" "$BROWSER_BRIDGE_BATS"

# The refusal row itself. The reader and the shape check have entries, the
# writer did not.
cat > "$SED_TMP" << 'SED'
/^_browser_watcher()/,/^}$/{
  s@^        elif \[ "[$]_dest_ok" != 1 \] && \[ "[$]bridge_mode" != "off" \] && _is_auth_url_shape "[$]_clean_url"; then$@        elif false; then@
}
SED
try "vnext_bridge_blocked_writer" "an unallowlisted origin is refused and never opened" "$CLI" "$BROWSER_BRIDGE_BATS"

# The shipped hook line cap, exactly: one byte more is dropped, the cap itself
# passes.
cat > "$SED_TMP" << 'SED'
s@^_HOOK_LINE_MAX=1044480$@_HOOK_LINE_MAX=1048576@
SED
try "vnext_hook_line_cap_value_up" "the shipped line cap is" "$CLI" "$HOOKS_BATS"

cat > "$SED_TMP" << 'SED'
s@^_HOOK_LINE_MAX=1044480$@_HOOK_LINE_MAX=1044479@
SED
try "vnext_hook_line_cap_value_down" "the shipped line cap is" "$CLI" "$HOOKS_BATS"

# The drop summary prints the count it read. A bare "1" in the assertion
# matched the bold escape, so any count passed.
cat > "$SED_TMP" << 'SED'
/^_maybe_report_hook_drops()/,/^}$/{
  s@^  \[ "[$]n" -gt 0 \] || return 0$@  [ "$n" -gt 0 ] || return 0; n=7@
}
SED
try "vnext_hook_drop_count" "the summary counts only this session" "$CLI" "$HOOKS_BATS"

# And only this session's rows.
cat > "$SED_TMP" << 'SED'
/^_maybe_report_hook_drops()/,/^}$/{
  s@tail -c "+[$](( off + 1 ))" "[$]log"@cat "$log"@
}
SED
try "vnext_hook_drops_report_offset" "the summary counts only this session" "$CLI" "$HOOKS_BATS"

# The character rule's control and backslash members, each alone.
cat > "$SED_TMP" << 'SED'
/^_hook_segment_chars_ok()/,/^}$/{
  s@\\\\p{Cc}@@
}
SED
try "vnext_hook_seg_cntrl" "a control character or a backslash is refused" "$CLI" "$HOOKS_BATS"

cat > "$SED_TMP" << 'SED'
/^_hook_segment_chars_ok()/,/^}$/{
  s@\\\\\\\\:]@:]@
}
SED
try "vnext_hook_seg_backslash" "a control character or a backslash is refused" "$CLI" "$HOOKS_BATS"

# The regressions guard on the instruction-surface lists, which kits.bats cannot
# give: it loops over the constant, so a shrunk list stays green there.
cat > "$SED_TMP" << 'SED'
s@^_CLAUDE_INSTR_DIRS="workflows routines rules output-styles themes @_CLAUDE_INSTR_DIRS="workflows routines rules output-styles @
SED
try "vnext_instr_dirs_no_shrink" "every instruction surface is masked over the box" "$CLI" "$REGRESSIONS"

cat > "$SED_TMP" << 'SED'
s@^\(_CLAUDE_INSTR_FILES="scheduled_tasks[.]json launch[.]json loop[.]md\) keybindings[.]json @\1 @
SED
try "vnext_instr_files_no_shrink" "every instruction surface is masked over the box" "$CLI" "$REGRESSIONS"

# Registered only where python3 runs the paired tests: a skipped test reads as
# a missed mutation.
if command -v python3 >/dev/null 2>&1; then
cat > "$SED_TMP" << 'SED'
/^_auth_callback_proxy()/,/^}$/{
  s@^        with open(ready_file, 'w') as f: f.write('1')$@        pass@
}
SED
try "vnext_proxy_ready_python" "the python backend signals readiness" "$CLI" "$BROWSER_BRIDGE_BATS"

# The probe in both directions against a real listener: never busy, and busy
# on a port nothing holds.
cat > "$SED_TMP" << 'SED'
/^_port_in_use()/,/^}$/{
  s@^    _run_bounded 2 bash -c "exec 9<>/dev/tcp/[$]{_lo}/[$]{port}" 2>/dev/null && return 0$@    :@
}
SED
try "vnext_port_probe_never_busy" "holds the port, and the port is free once it goes" "$CLI" "$BROWSER_BRIDGE_BATS"

cat > "$SED_TMP" << 'SED'
/^_port_in_use()/,/^}$/{
  s@^  return 1$@  return 0@
}
SED
try "vnext_port_probe_closed_is_free" "holds the port, and the port is free once it goes" "$CLI" "$BROWSER_BRIDGE_BATS"
fi

# The hooks cap description promised "(global + project)" long after the bridge
# stopped reading project settings files, so `cleat config` told the user a
# project hook would run on their host. Restore the old wording.
cat > "$SED_TMP" << 'SED'
/^_cap_description()/,/^}$/{
  s@^    hooks)  echo "Run the hooks in ~/[.]claude/settings[.]json on the host" ;;$@    hooks)  echo "Run your Claude Code hooks on the host (global + project)" ;;@
}
SED
try "vnext_hooks_cap_description_host_file" "cap_description: hooks names the host settings file" "$CLI" "$HOOKS_BATS"

# ── v1.4.3: `cleat login` never signed anyone in ────────────────────────────

# Claude Code has no top-level `login` subcommand, so the bare word became the
# first PROMPT of an interactive session.
cat > "$SED_TMP" << 'SED'
/^cmd_login() {$/,/^}$/{
  s|runuser -u coder -- claude auth login|runuser -u coder -- claude login|
}
SED
try "v1.4.3_login_auth_subcommand" "cleat login runs claude auth login"

# A login into a pinned box must be carried to the account. Without the harvest
# it stayed in the box and the next attach's staging deleted it.
cat > "$SED_TMP" << 'SED'
/^cmd_login() {$/,/^}$/{
  /_account_sync_out "\$cname"/d
}
SED
try "v1.4.3_login_harvests" "cleat login on a pinned box saves the login into the account"

# The closing line must name the store the login really went to, never a fixed
# claim about the shared one.
cat > "$SED_TMP" << 'SED'
/^cmd_login() {$/,/^}$/{
  s#_account_apply_exec_env "\$cname" || _login_acct="\$_ACCOUNT_DEFAULT"#_account_apply_exec_env "$cname" || true; _login_acct="$_ACCOUNT_DEFAULT"#
}
SED
try "v1.4.3_login_names_account" "cleat login on a pinned box saves the login into the account"

# Exit 0 with an empty account store is not a saved login.
cat > "$SED_TMP" << 'SED'
/^cmd_login() {$/,/^}$/{
  s#_login_harvest -eq 0 && "\$(_account_auth_state "\$_login_acct")" != "signed out"#_login_harvest -eq 0#
}
SED
try "v1.4.3_login_unsaved_warns" "never reports a login saved that did not reach"

# A failed login must exit non-zero.
cat > "$SED_TMP" << 'SED'
/^cmd_login() {$/,/^}$/{
  s#\[\[ \$login_rc -eq 0 \]\] || return "\$login_rc"#[[ $login_rc -eq 0 ]] || return 0#
}
SED
try "v1.4.3_login_failure_rc" "a failed cleat login exits non-zero"

# The destination gate must allow the hosts Claude Code actually authorizes at.
cat > "$SED_TMP" << 'SED'
s|^_BROWSER_ORIGINS="claude.ai claude.com platform.claude.com console.anthropic.com$|_BROWSER_ORIGINS="claude.ai console.anthropic.com|
SED
try "vnext_browser_claude_authorize_origin" "the Claude authorize URL opens through the browser bridge"

# A login made inside `cleat shell` is harvested when the shell exits.
cat > "$SED_TMP" << 'SED'
/^cmd_shell() {$/,/^}$/{
  /_account_sync_out "\$cname" || true/d
}
SED
try "vnext_account_shell_harvests" "a login made in cleat shell on a pinned box is harvested" "$CLI" "$ACCOUNTS_BATS"

# A login the harvest held as another account's is reported, never reported as
# saved and never reported as merely "did not reach".
cat > "$SED_TMP" << 'SED'
/^cmd_login() {$/,/^}$/{
  s#^  elif \[\[ \$_login_harvest -eq 2 \]\]; then$#  elif false; then#
}
SED
try "vnext_login_held_notice" "cleat login says so when the browser signed in as another account" "$CLI" "$ACCOUNTS_BATS"

# A busy account lock is named rather than reported as a login that missed.
cat > "$SED_TMP" << 'SED'
/^cmd_login() {$/,/^}$/{
  s#^  elif \[\[ \$_login_harvest -eq \$_ACCOUNT_LOCK_BUSY \]\]; then$#  elif false; then#
}
SED
try "vnext_login_busy_notice" "cleat login says so when the harvest could not take the account lock" "$CLI" "$ACCOUNTS_BATS"

# The recreate hint names the box that needs recreating, not main.
cat > "$SED_TMP" << 'SED'
/^_account_apply_exec_env() {$/,/^}$/{
  s#cleat rm \${_BOX:-main}#cleat rm#
}
SED
try "vnext_account_no_mount_hint_box" "names its own box in the recreate hint" "$CLI" "$ACCOUNTS_BATS"

# v1.4.3: cmd_resume passed --continue, which reopens the newest conversation even
# when a live Claude in another terminal of the same box has it open. The pick
# must exclude live ids.
cat > "$SED_TMP" << 'SED'
/^_resume_pick_session()/,/^}$/{
  /case "[$]live" in [*]"[$]uuid"[*]) continue ;; esac/d
}
SED
try "v1.4.3_resume_skips_live_conversation" "resume does not reopen a conversation that is open in another terminal"

# v1.4.3: the resolved id must reach Claude. Reverting the argv to --continue
# reintroduces the wrong conversation.
cat > "$SED_TMP" << 'SED'
/^cmd_resume()/,/^}$/{
  s|_resume_args=(--resume "[$]_sid")|_resume_args=(--continue)|
}
SED
try "v1.4.3_resume_names_conversation" "resume does not reopen a conversation that is open in another terminal"

# v1.4.3: Claude Code restores the bare model id on resume, so a default-model
# conversation lost the 1M beta. Dropping the carry reintroduces it.
cat > "$SED_TMP" << 'SED'
/^cmd_resume()/,/^}$/{
  /_resume_args+=(--model "[$]_model")/d
}
SED
try "v1.4.3_resume_carries_1m" "resume keeps the 1M context the conversation ran on"

# ── the live-agent primitive judges the executable ───────────────────────────

# v1.4.3: _box_has_live_agent grepped the whole `docker top` output for
# claude|node, so a leftover Vite server kept a detached box out of the idle
# sweep forever. Put the whole-line grep back in front of the column reader.
cat > "$SED_TMP" << 'SED'
/^_box_has_live_agent()/,/^}$/{
  s@^  {$@  grep -qiE 'claude|node' <<< "$top"; return; {@
}
SED
try "v143_live_agent_whole_line_grep" "a leftover node dev server" "$CLI" "$REGRESSIONS"

# The same revert judged by the REAL binary under set -euo pipefail, which is
# the only place the column reader's arrays and slices actually run strict.
cat > "$SED_TMP" << 'SED'
/^_box_has_live_agent()/,/^}$/{
  s@^  {$@  grep -qiE 'claude|node' <<< "$top"; return; {@
}
SED
try "v143_live_agent_strict_mode_dev_server" "only leftover is a dev server" "$CLI" "$SMOKE_BATS"

# Node alone is not Claude. This is the case the maintainer hit: cleat account
# refused with "main has a live Claude session" over a dev server.
cat > "$SED_TMP" << 'SED'
/^_is_claude_argv()/,/^}$/{
  s@^    node|\*/node|nodejs|\*/nodejs) ;;$@    node|*/node|nodejs|*/nodejs) return 0 ;;@
}
SED
try "vnext_account_dev_server_not_live" "only node process is a dev server" "$CLI" "$REGRESSIONS"

# The executable is matched by name, never by substring: a plugin's LSP server
# under ~/.claude/plugins is not Claude.
cat > "$SED_TMP" << 'SED'
/^_is_claude_argv()/,/^}$/{
  s@^    claude|\*/claude|\*/claude/versions/\*) return 0 ;;$@    *claude*) return 0 ;;@
}
SED
try "v143_live_agent_argv0_not_substring" "a leftover node dev server" "$CLI" "$REGRESSIONS"

# Only the command column is judged: on a Linux host whose user is called
# claude, the UID column is not a process.
cat > "$SED_TMP" << 'SED'
/^_box_has_live_agent()/,/^}$/{
  s#_is_claude_argv "[$]{f\[@\]:[$]col}"#_is_claude_argv "${f[@]}"#
}
SED
try "v143_live_agent_command_column_only" "a leftover node dev server" "$CLI" "$REGRESSIONS"

# A layout with no command column is unreadable, and unreadable means live.
cat > "$SED_TMP" << 'SED'
/^_box_has_live_agent()/,/^}$/{
  s@^    (( col >= 0 )) || return 0 @    (( col >= 0 )) || return 1 @
}
SED
try "v143_live_agent_unknown_layout_is_live" "no command column" "$CLI" "$IDLE_SWEEP_BATS"

# A node row is Claude only when its first non-option argument is a Claude
# entry point. Judging the options too would miss `node --no-warnings claude`.
cat > "$SED_TMP" << 'SED'
/^_is_claude_argv()/,/^}$/{
  s@^      -\*) ;;$@      -*) return 1 ;;@
}
SED
try "v143_live_agent_node_skips_options" "every process shape a running Claude takes" "$CLI" "$IDLE_SWEEP_BATS"

# The executable name is matched WHOLE. A prefix match reads a third-party CLI
# called claude-monitor as a live session.
cat > "$SED_TMP" << 'SED'
/^_is_claude_argv()/,/^}$/{
  s@^    claude|\*/claude|\*/claude/versions/\*) return 0 ;;$@    claude*|*/claude*) return 0 ;;@
}
SED
try "v143_live_agent_argv0_matched_whole" "ragged rows" "$CLI" "$IDLE_SWEEP_BATS"

# v1.4.3: the kit note said a STOPPED box had a live session, because docker
# top fails on one and the note lacked is_running.
cat > "$SED_TMP" << 'SED'
/^_kit_apply()/,/^}$/{
  s@^  if container_exists "[$]cname" \&\& is_running "[$]cname" \&\& _box_has_live_agent "[$]cname"; then$@  if container_exists "$cname" \&\& _box_has_live_agent "$cname"; then@
}
SED
try "v143_kit_note_stopped_box" "enabling a kit on a stopped box" "$CLI" "$REGRESSIONS"

# vnext: two boxes on one account. The attach held the box that fell behind a
# sibling's refresh, because the rotated refresh token made its staged file
# look like a login the account does not have.
cat > "$SED_TMP" << 'SED'
/^_account_sync_in_locked()/,/^}$/{
  s@^       && ! _account_staged_superseded "[$]acct" "[$]snap"; then@       ; then@
}
SED
try "vnext_account_generation_attach_hold" "a box staged on a generation its account already replaced" "$CLI" "$REGRESSIONS"

# The same login through the release path, which every switch, remove and nuke
# takes: a generation the account moved past is not an unsaved login.
cat > "$SED_TMP" << 'SED'
/^_account_harvest_from()/,/^}$/{
  /_account_staged_superseded/d
}
SED
try "vnext_account_generation_release_hold" "a box staged on a generation its account already replaced" "$CLI" "$REGRESSIONS"

# Nothing recognises a generation the store never wrote down.
cat > "$SED_TMP" << 'SED'
/^_account_write_cred()/,/^}$/{
  /_account_seen_add/d
}
SED
try "vnext_account_generation_recorded" "a box staged on a generation its account already replaced" "$CLI" "$REGRESSIONS"

# vnext: a lock that cannot be MADE was polled for the full timeout, at every
# attach and again at every session end.
cat > "$SED_TMP" << 'SED'
/^_account_lock()/,/^}$/{
  s@^    if \[\[ ! -e "[$]lock" && ! -L "[$]lock" \]\]; then@    if false; then@
}
SED
try "vnext_account_lock_unwritable_no_wait" "a lock that cannot be made fails at once" "$CLI" "$REGRESSIONS"

# And it named another cleat command rather than the directory it cannot write.
cat > "$SED_TMP" << 'SED'
/^_account_busy_msg()/,/^}$/{
  s@^  if \[\[ "[$]{_ACCOUNT_LOCK_UNWRITABLE:-0}" -eq 1 \]\]; then@  if false; then@
}
SED
try "vnext_account_lock_unwritable_message" "a lock that cannot be made fails at once" "$CLI" "$REGRESSIONS"

# The same at the session end, where a pinned box meets it twice a session.
cat > "$SED_TMP" << 'SED'
/^_maybe_report_account_harvest_busy()/,/^}$/{
  s@^  if \[\[ "[$]{_ACCOUNT_LOCK_UNWRITABLE:-0}" -eq 1 \]\]; then@  if false; then@
}
SED
try "vnext_account_lock_unwritable_harvest_message" "a lock that cannot be made fails at once" "$CLI" "$REGRESSIONS"

# vnext: the session-end harvest waits on the network. Ahead of the restore it
# froze the terminal in Claude's raw mode for the whole timeout.
cat > "$SED_TMP" << 'SED'
/^exec_claude()/,/^}$/{
  s@^  _restore_terminal$@  local _harvest=0; _account_sync_out "$cname" || _harvest=$?; _restore_terminal@
  s@^  _account_sync_out "[$]cname" || _harvest=[$]?$@  :@
}
SED
try "vnext_session_end_harvest_after_restore" "the session-end harvest runs only after the terminal is back" "$CLI" "$REGRESSIONS"

# ─────────────────────────────────────────────────────────────────────────────
# vnext: the live account switch, the in-box half (probe and terminate) and the
# bounded exec. Anchors point at the function that actually holds the code, not
# the handover's advisory column: the procstart compare lives in
# _hb_session_record, and the two REG entries anchor _hb_terminate. See
# concept/44 and test/unit/handoff.bats.
# ─────────────────────────────────────────────────────────────────────────────

# probe must skip a session file whose process start time no longer matches.
cat > "$SED_TMP" << 'SED'
/^_hb_session_record()/,/^}$/{
  s@\[\[ -n "[$]ps" && "[$]ps" == "[$]start" \]\] || return 1@[[ -n "$ps" ]] || return 1@
}
SED
try "vnext_handoff_probe_procstart" "start time does not match" "$CLI" "$HANDOFF_BATS"

# probe judges a process by its executable, never by a claude word in its args.
cat > "$SED_TMP" << 'SED'
/^_hb_scan()/,/^}$/{
  s#if _is_claude_argv "[$]{words\[@\]}"; then#if printf "%s" "${words[*]}" | grep -q claude; then#
}
SED
try "vnext_handoff_probe_argv_rule" "by executable and never by a claude word" "$CLI" "$HANDOFF_BATS"

# an unreadable environment reads as unreadable, never as zero entries (none).
cat > "$SED_TMP" << 'SED'
/^_hb_env_value()/,/^}$/{
  s@if \[\[ -d "[$]f" \]\] || \[\[ ! -r "[$]f" \]\]; then printf 'unreadable'; return 0; fi@if [[ -d "$f" ]] || [[ ! -r "$f" ]]; then printf '0 '; return 0; fi@
}
SED
try "vnext_handoff_probe_environ_unreadable" "unreadable environment" "$CLI" "$HANDOFF_BATS"

# probe reports the shell-snapshot processes of a session.
cat > "$SED_TMP" << 'SED'
/^_hb_scan()/,/^}$/{
  s@if \[\[ [$]found_shell -eq 1 \]\]; then@if false; then@
}
SED
try "vnext_handoff_probe_shell_line" "shell snapshot process under the exec id" "$CLI" "$HANDOFF_BATS"

# terminate refuses malformed arguments before it touches anything.
cat > "$SED_TMP" << 'SED'
/^_hb_args_ok()/,/^}$/{
  s@  local verb="[$]1"; shift@  local verb="$1"; shift; return 0@
}
SED
try "vnext_handoff_terminate_args" "malformed arguments" "$CLI" "$HANDOFF_BATS"

# terminate holds Claude's refresh lock across the signal (REG: R-b).
cat > "$SED_TMP" << 'SED'
/^_hb_terminate()/,/^}$/{
  s@if _hb_lock_take "[$]lock" "[$]lockwait" "[$]_HB_CLAUDE_LOCK_STALE_S"; then@if true; then@
}
SED
try "vnext_handoff_refresh_lock_hold" "holds the outgoing refresh lock across the signal" "$CLI" "$REGRESSIONS"

# a refresh lock is reclaimed only when it is older than Claude's stale bound.
cat > "$SED_TMP" << 'SED'
/^_hb_lock_take()/,/^}$/{
  s@if \[\[ [$](( now - mt )) -gt [$]stale \]\]; then@if true; then@
}
SED
try "vnext_handoff_refresh_lock_stale_rule" "older than the Claude stale bound" "$CLI" "$HANDOFF_BATS"

# the recheck's outside scan aborts on any new session, orphan or stray shell.
cat > "$SED_TMP" << 'SED'
/^_hb_recheck()/,/^}$/{
  s@scanout="[$](_hb_scan "[$]home" "[$]proc" "[$]skip")"@scanout=""@
}
SED
try "vnext_handoff_outside_scan" "a status changed or a session opened" "$CLI" "$HANDOFF_BATS"

# the box recheck exempts a busy --now target's own background shell line: break
# the exemption and the now leg's recheck aborts instead of passing.
cat > "$SED_TMP" << 'SED'
/^_hb_recheck()/,/^}$/{
  s@"[$]{_HBT_EXPECT\[[$]j\]}" == now@"${_HBT_EXPECT[$j]}" == xnow@
}
SED
try "vnext_handoff_recheck_now_shell_exempt" "only when the expect is now" "$CLI" "$HANDOFF_BATS"

# the final scan under the lock aborts over a Claude that started after the kill (REG: R-c).
cat > "$SED_TMP" << 'SED'
/^_hb_terminate()/,/^}$/{
  s@  if \[\[ [$]fchanged -eq 1 \]\]; then@  if false; then@
}
SED
try "vnext_handoff_final_scan" "never stages over a Claude that started after the kill" "$CLI" "$REGRESSIONS"

# a target that outlives the kill wait is never SIGKILLed.
cat > "$SED_TMP" << 'SED'
/^_hb_terminate()/,/^}$/{
  s@kill -TERM@kill -KILL@
}
SED
try "vnext_handoff_never_sigkill" "ignores SIGTERM" "$CLI" "$HANDOFF_BATS"

# the lock is released on every exit of the verb. The EXIT trap is the observable
# cleanup for the abort paths, which return without an explicit rmdir (the signal
# traps add bash 3.2 coverage, where EXIT does not fire on a signal, and the exit
# codes; on bash 5 EXIT masks them, so the harness catches this via the EXIT trap).
cat > "$SED_TMP" << 'SED'
/^_hb_terminate()/,/^}$/{
  /trap _hb_cleanup EXIT/d
}
SED
try "vnext_handoff_lock_release_on_term" "releases its lock on abort on success and on TERM" "$CLI" "$HANDOFF_BATS"

# the bounded exec stops a docker client that outlives its timeout.
cat > "$SED_TMP" << 'SED'
/^_handoff_docker_exec()/,/^}$/{
  /if \[\[ [$](( SECONDS - start )) -ge [$]bound \]\]; then stopped=1; break; fi/d
}
SED
try "vnext_handoff_exec_bound" "docker outlives the timeout" "$CLI" "$HANDOFF_BATS"

# the bounded exec stops a runaway output at the byte cap.
cat > "$SED_TMP" << 'SED'
/^_handoff_docker_exec()/,/^}$/{
  s@if \[\[ [$]size -gt [$]_HANDOFF_OUT_MAX_BYTES \]\]; then stopped=1; break; fi@if false; then stopped=1; break; fi@
}
SED
try "vnext_handoff_exec_output_cap" "runaway output at the byte cap" "$CLI" "$HANDOFF_BATS"

# ─────────────────────────────────────────────────────────────────────────────
# vnext: the live switch host state, the attach gate, the offline-path refusals
# and the H9 flag order (M2). See test/unit/handoff.bats, the R-e regression and
# the account-rm test in accounts.bats. Anchors point at the function that holds
# the code.
# ─────────────────────────────────────────────────────────────────────────────

# the attach gate refuses only when a requested ticket of this box is still live.
cat > "$SED_TMP" << 'SED'
/^_account_attach_gate()/,/^}$/{
  s@_handoff_tickets_requested_live "[$]1"@false@
}
SED
try "vnext_handoff_gate_requested_live" "an attach refuses while this box is switching" "$CLI" "$HANDOFF_BATS"

# exec_claude takes the account gate before it reads the pin (the default-pin gap).
cat > "$SED_TMP" << 'SED'
/^exec_claude()/,/^}$/{
  s@if ! _account_attach_gate "[$]cname" "[$]{_BOX:-main}" cleat; then@if false; then@
}
SED
try "vnext_handoff_exec_gate_before_pin" "waits for the account lock before it reads the pin" "$CLI" "$REGRESSIONS"

# cmd_shell takes the account gate before it reads the pin, too.
cat > "$SED_TMP" << 'SED'
/^cmd_shell()/,/^}$/{
  s@if ! _account_attach_gate "[$]cname" "[$]box" "cleat shell"; then@if false; then@
}
SED
try "vnext_handoff_shell_gate_before_pin" "waits for the account lock before it reads the pin" "$CLI" "$REGRESSIONS"

# the offline switch refuses under its lock while a session is still starting.
cat > "$SED_TMP" << 'SED'
/^_account_switch_locked()/,/^}$/{
  s@_handoff_starting_markers "[$]cname"@false@
}
SED
try "vnext_handoff_offline_starting" "a session in another terminal is still starting" "$CLI" "$HANDOFF_BATS"

# "starting" is bounded by age: a stale kind=claude marker (a crashed session
# whose pid was reused, or one that never cleaned up) is NOT a session coming
# up, so it must not block the switch. Removing the age check makes the 200 s
# marker in the "still starting" test count as starting and refuse.
cat > "$SED_TMP" << 'SED'
/^_handoff_starting_markers()/,/^}$/{
  /\[\[ [$]age -ge 0 && [$]age -le [$]_HANDOFF_STARTING_MAX_S \]\] || continue/d
}
SED
try "vnext_handoff_starting_age_bound" "a session in another terminal is still starting" "$CLI" "$HANDOFF_BATS"

# the offline switch refuses a shared<->named move while a cleat shell is open.
cat > "$SED_TMP" << 'SED'
/^_account_switch_locked()/,/^}$/{
  s@_handoff_shell_open "[$]cname"@false@
}
SED
try "vnext_handoff_offline_shellopen" "while a cleat shell is open" "$CLI" "$HANDOFF_BATS"

# H9: the identity flag is written before the pin moves.
cat > "$SED_TMP" << 'SED'
/^_account_switch_locked()/,/^}$/{
  /_handoff_flag_identity_stale "[$]project" "[$]box"/d
}
SED
try "vnext_handoff_h9_flag_before_pin" "writes the identity flag before the pin moves" "$CLI" "$HANDOFF_BATS"

# the identity drop clears the flag it satisfied (only in _account_invalidate_identity_key).
cat > "$SED_TMP" << 'SED'
/^_account_invalidate_identity_key()/,/^}$/{
  s@rm -f "[$]{f}.identity-stale" 2>/dev/null || true@:@
}
SED
try "vnext_handoff_h9_flag_clear" "writes the identity flag before the pin moves" "$CLI" "$HANDOFF_BATS"

# cleat account rm refuses while a pinned box is reopening a session.
cat > "$SED_TMP" << 'SED'
/^_account_do_remove()/,/^}$/{
  s@if _handoff_tickets_pending "[$]b"; then@if false; then@
}
SED
try "vnext_handoff_rm_reopening" "a pinned box is reopening a session" "$CLI" "$ACCOUNTS_BATS"

# a live ready ticket whose session is already back in the caller's probe set
# is NOT still reopening: the exclusion stops a fresh switch refusing a reopen
# that already finished. Drop the probe-set check so a completed reopen still
# reads as pending.
cat > "$SED_TMP" << 'SED'
/^_handoff_tickets_pending()/,/^}$/{
  s@\[\[ [$]in_probe -eq 0 \]\] && return 0@return 0@
}
SED
try "vnext_handoff_pending_sid_live" "excludes one already back in the probe set" "$CLI" "$HANDOFF_BATS"

# a ticket by=1 is rejected, so kill -0 never targets init or a process group.
cat > "$SED_TMP" << 'SED'
/^_handoff_ticket_read()/,/^}$/{
  s@"[$]_HT_BY" != "1"@1@
}
SED
try "vnext_handoff_ticket_by_not_one" "rejects a malformed ticket" "$CLI" "$HANDOFF_BATS"

# an exec id shorter than 12 hex is refused (marker and ticket id validation).
cat > "$SED_TMP" << 'SED'
/^_handoff_id_ok()/,/^}$/{
  s@-ge 12@-ge 0@
}
SED
try "vnext_handoff_id_len" "handoff id ok accepts 12 to 32" "$CLI" "$HANDOFF_BATS"

# an invalid exec id in a marker fails closed to shell, never claude.
cat > "$SED_TMP" << 'SED'
/^_handoff_marker_read()/,/^}$/{
  s@_handoff_id_ok "[$]id"@true@
}
SED
try "vnext_handoff_marker_failclosed" "marker read parses claude and shell" "$CLI" "$HANDOFF_BATS"

# ── M3: terminal 1 relaunch loop, resume carry, cmd_resume pick ──────────────

# H7: a conversation past the standard window is 1M even with no [1m] key. Break
# the size threshold so the size evidence never fires.
cat > "$SED_TMP" << 'SED'
/^_resume_model_carry()/,/^}$/{
  s@-gt [$]_HANDOFF_STD_WINDOW_TOKENS@-gt 999999999999@
}
SED
try "vnext_handoff_carry_size" "conversation size as 1M evidence" "$CLI" "$HANDOFF_BATS"

# The size reader must skip the synthetic rate-limit record and API-error
# records. Drop both skips so the synthetic last record is read (and rejected).
cat > "$SED_TMP" << 'SED'
/^_resume_last_usage_tokens()/,/^}$/{
  /isApiErrorMessage/d
  /"model":"claude-/d
}
SED
try "vnext_handoff_carry_skips_synthetic" "skips synthetic and API error records" "$CLI" "$HANDOFF_BATS"

# A relaunch names the session id, never --continue (a sibling conversation).
cat > "$SED_TMP" << 'SED'
/^exec_claude()/,/^}$/{
  s@_EC_ARGS=(--dangerously-skip-permissions --resume "[$]_ec_sid")@_EC_ARGS=(--dangerously-skip-permissions --continue)@
}
SED
try "vnext_handoff_resume_not_continue" "never reopens another conversation of the same box" "$CLI" "$REGRESSIONS"

# Only exit 143 with a ticket reopens: break the rc gate so any exit reopens.
cat > "$SED_TMP" << 'SED'
/^exec_claude()/,/^}$/{
  s@\[\[ [$]rc -ne 143 \]\]@false@
}
SED
try "vnext_handoff_rc_gate" "ignores a ready ticket when Claude exited on its own" "$CLI" "$EXEC_CLAUDE_BATS"

# A dead requested-ticket writer ends the wait at once. Drop the check so it
# keeps waiting (and prints the T0 line the immediate end suppresses).
cat > "$SED_TMP" << 'SED'
/^_handoff_t1_await()/,/^}$/{
  s@if ! kill -0 "[$]_HT_BY" 2>/dev/null; then _HANDOFF_T1_STATE=unfinished; break; fi@:@
}
SED
try "vnext_handoff_dead_writer" "requested ticket writer died" "$CLI" "$EXEC_CLAUDE_BATS"

# T0 prints once while the ticket reads requested. Drop the print.
cat > "$SED_TMP" << 'SED'
/^_handoff_t1_await()/,/^}$/{
  s@if \[\[ [$]said -eq 0 \]\]; then said=1; _handoff_say T0 "[$]_HT_TO"; fi@:@
}
SED
try "vnext_handoff_t0_line" "waiting while the ticket reads requested" "$CLI" "$EXEC_CLAUDE_BATS"

# Typeahead is drained before a relaunch. Drop the call.
cat > "$SED_TMP" << 'SED'
/^exec_claude()/,/^}$/{
  /_handoff_drain_typeahead$/d
}
SED
try "vnext_handoff_drain" "drains typeahead" "$CLI" "$EXEC_CLAUDE_BATS"

# The store variable drops as a -e PAIR. Skip one element, leaving a bare -e.
cat > "$SED_TMP" << 'SED'
/^_claude_env_drop_store()/,/^}$/{
  s@i=$(( i + 2 )); continue@i=$(( i + 1 )); continue@
}
SED
try "vnext_handoff_env_pair" "store variable and its e flag as a pair" "$CLI" "$EXEC_CLAUDE_BATS"

# The macOS seed runs only for a shared-login exec. Drop the guard.
cat > "$SED_TMP" << 'SED'
/^_exec_claude_prepare_account()/,/^}$/{
  s@if \[\[ "[$]_EC_PINNED" == "[$]_ACCOUNT_DEFAULT" \]\]; then@if true; then@
}
SED
try "vnext_handoff_seed_default_only" "seed only before a relaunch onto the shared" "$CLI" "$EXEC_CLAUDE_BATS"

# Cleanup and harvest run only at the final exit, never between the signal and
# the relaunch. Add a per-iteration harvest so it runs between the two execs.
cat > "$SED_TMP" << 'SED'
/^exec_claude()/,/^}$/{
  s@ 2>"[$]_exec_err" || rc=[$]?$@ 2>"$_exec_err" || rc=$?; _account_sync_out "$cname" || true@
}
SED
try "vnext_handoff_cleanup_final_only" "cleanup and harvest never run between" "$CLI" "$REGRESSIONS"

# Code 143 is hidden only when a ticket explains it. Hide it always.
cat > "$SED_TMP" << 'SED'
/^exec_claude()/,/^}$/{
  s@elif \[\[ [$]rc -ne 130 \]\]; then@elif [[ $rc -ne 130 \&\& $rc -ne 143 ]]; then@
}
SED
try "vnext_handoff_rc143_ticket_only" "hides code 143 only when a ticket explains it" "$CLI" "$EXEC_CLAUDE_BATS"

# An exec id is stamped only for the fixed relaunchable argv shapes. Accept any.
cat > "$SED_TMP" << 'SED'
/^_exec_claude_argv_relaunchable()/,/^}$/{
  s@^  \[\[ "[$]{1:-}" == "--dangerously-skip-permissions" \]\] || return 1$@  return 0@
}
SED
try "vnext_handoff_fixed_argv" "fixed argument shapes" "$CLI" "$EXEC_CLAUDE_BATS"

# The exec id is placed AFTER the user env args, so a .cleat.env cannot forge
# it. Emit it before CLAUDE_ENV (and thus before the user env args).
cat > "$SED_TMP" << 'SED'
/^exec_claude()/,/^}$/{
  s#^    docker exec -it "[$]{CLAUDE_ENV\[@\]}" \\$#    docker exec -it "${_ec_extra[@]+"${_ec_extra[@]}"}" "${CLAUDE_ENV[@]}" \\#
}
SED
try "vnext_handoff_exec_id_after_env" "fixed argument shapes" "$CLI" "$EXEC_CLAUDE_BATS"

# The wait re-arms the flag trap so Ctrl-C sets the flag (not cleanup). Drop it.
cat > "$SED_TMP" << 'SED'
/^_handoff_t1_await()/,/^}$/{
  /trap ._EC_INT=1. INT TERM HUP/d
}
SED
try "vnext_handoff_wait_flag_trap" "stopped waiting line" "$CLI" "$EXEC_CLAUDE_BATS"

# The terminal is restored before the final harvest (the harvest can wait on a
# network call). Move the harvest ahead of the restore: add one before the
# restore and neutralise the real one, which lives in the note-guarded case arm.
cat > "$SED_TMP" << 'SED'
/^exec_claude()/,/^}$/{
  s@^  _restore_terminal$@  _account_sync_out "$cname" || _harvest=$?; _restore_terminal@
  s@^    \*) _account_sync_out "[$]cname" || _harvest=[$]? ;;$@    *) : ;;@
}
SED
try "vnext_handoff_restore_before_harvest" "restores the terminal before the final harvest" "$CLI" "$EXEC_CLAUDE_BATS"

# The reopen after a switch suppresses Claude Code's resume-from-summary dialog,
# so a typed continue lands in the conversation instead of picking an option.
# Drop the minutes threshold from the reopen.
cat > "$SED_TMP" << 'SED'
/^exec_claude()/,/^}$/{
  s@^      _ec_extra+=(-e "CLAUDE_CODE_RESUME_THRESHOLD_MINUTES=[$][{]_HANDOFF_RESUME_THRESHOLD_MIN[}]")$@      :@
}
SED
try "vnext_handoff_dialog_minutes_on_reopen" "suppresses the resume dialog on the reopen only" "$CLI" "$EXEC_CLAUDE_BATS"

# The token threshold is set too, so a rename of either variable still leaves
# the reopen transparent. Drop it.
cat > "$SED_TMP" << 'SED'
/^exec_claude()/,/^}$/{
  s@^      _ec_extra+=(-e "CLAUDE_CODE_RESUME_TOKEN_THRESHOLD=[$][{]_HANDOFF_RESUME_TOKEN_THRESHOLD[}]")$@      :@
}
SED
try "vnext_handoff_dialog_tokens_on_reopen" "suppresses the resume dialog on the reopen only" "$CLI" "$EXEC_CLAUDE_BATS"

# Only the reopen. An ordinary launch keeps Claude Code's own resume behaviour.
# Ride the minutes threshold on every exec.
cat > "$SED_TMP" << 'SED'
/^exec_claude()/,/^}$/{
  s@^    _ec_extra=()$@    _ec_extra=(-e "CLAUDE_CODE_RESUME_THRESHOLD_MINUTES=${_HANDOFF_RESUME_THRESHOLD_MIN}")@
  s@_ec_extra=(-e "CLEAT_EXEC_ID=[$][{]_ec_id[}]")@_ec_extra+=(-e "CLEAT_EXEC_ID=${_ec_id}")@
}
SED
try "vnext_handoff_dialog_reopen_only" "suppresses the resume dialog on the reopen only" "$CLI" "$EXEC_CLAUDE_BATS"

# A small threshold does not suppress anything: the dialog's own default is 70.
cat > "$SED_TMP" << 'SED'
s@^_HANDOFF_RESUME_THRESHOLD_MIN=5256000 @_HANDOFF_RESUME_THRESHOLD_MIN=70 @
SED
try "vnext_handoff_dialog_minutes_large" "suppresses the resume dialog on the reopen only" "$CLI" "$EXEC_CLAUDE_BATS"

# The consumed ticket is matched on by AND at before removal. Match anything.
cat > "$SED_TMP" << 'SED'
/^exec_claude()/,/^}$/{
  s@\[\[ "[$]{_HT_BY}:[$]{_HT_AT}" == "[$]_ec_used" \]\]@true@
}
SED
try "vnext_handoff_consumed_ticket" "consumed ticket when the relaunched session returns" "$CLI" "$EXEC_CLAUDE_BATS"

# T-landed fires when the settled pin equals the ticket's target. Drop it.
cat > "$SED_TMP" << 'SED'
/^exec_claude()/,/^}$/{
  s@if \[\[ -n "[$]_ec_to" && "[$]_ec_pin" == "[$]_ec_to" \]\]; then@if false; then@
}
SED
try "vnext_handoff_t_landed" "names the account it landed on" "$CLI" "$EXEC_CLAUDE_BATS"

# A ready ticket on a stopped box ends with T-boxstopped. Drop the check.
cat > "$SED_TMP" << 'SED'
/^exec_claude()/,/^}$/{
  s@if ! is_running "[$]cname"; then _ec_note=boxstopped; break; fi@:@
}
SED
try "vnext_handoff_box_stopped" "box stopped line when the box is gone" "$CLI" "$EXEC_CLAUDE_BATS"

# cmd_resume adds the reopening sids to its live set. Drop them.
cat > "$SED_TMP" << 'SED'
/^cmd_resume()/,/^}$/{
  s@_reopening="[$](_handoff_reopening_sids "[$]cname")"@_reopening=""@
}
SED
try "vnext_handoff_resume_pick_pending" "skips a conversation that is reopening" "$CLI" "$START_RESUME_BATS"


# ── M4: terminal 2 classification, copy and orchestration ────────────────────

# Row 9: an orphan Claude process refuses.
cat > "$SED_TMP" << 'SED'
/^_handoff_classify()/,/^}$/{
  /Row 9: any orphan/{n;d}
}
SED
try "vnext_handoff_refuses_orphan" "refuses an orphan Claude process" "$CLI" "$HANDOFF_BATS"

# Row 10: a kind other than interactive refuses.
cat > "$SED_TMP" << 'SED'
/^_handoff_classify()/,/^}$/{
  /Row 10: a kind other/{n;d}
}
SED
try "vnext_handoff_kind" "non interactive session kind" "$CLI" "$HANDOFF_BATS"

# Row 12: two records sharing one exec id refuse.
cat > "$SED_TMP" << 'SED'
/^_handoff_classify()/,/^}$/{
  /Row 12: two records/{n;d}
}
SED
try "vnext_handoff_duplicate_id" "sharing an exec id" "$CLI" "$HANDOFF_BATS"

# Row 13: an exec id with no live attach marker refuses.
cat > "$SED_TMP" << 'SED'
/^_handoff_classify()/,/^}$/{
  /Row 13: an exec id/{n;d}
}
SED
try "vnext_handoff_marker" "no exec id or a dead marker" "$CLI" "$HANDOFF_BATS"

# Row 14: a store that does not match the pin refuses.
cat > "$SED_TMP" << 'SED'
/^_handoff_classify()/,/^}$/{
  /Row 14: a store that/{n;n;d}
}
SED
try "vnext_handoff_store" "store that does not match the pin" "$CLI" "$HANDOFF_BATS"

# Row 15: a sid with no transcript in this project refuses.
cat > "$SED_TMP" << 'SED'
/^_handoff_classify()/,/^}$/{
  s@_handoff_sid_has_transcript "[$]sdir" "[$]sid"@true@
}
SED
try "vnext_handoff_sid" "session id without a transcript" "$CLI" "$HANDOFF_BATS"

# Row 16: a status cleat does not know refuses (fail closed).
cat > "$SED_TMP" << 'SED'
/^_handoff_classify()/,/^}$/{
  s@busy|shell|idle|waiting) : ;; [*]) _HO_VERDICT=R5; return 0@busy|shell|idle|waiting) : ;; *) :@
}
SED
try "vnext_handoff_unknown_status" "refuses an unknown status" "$CLI" "$HANDOFF_BATS"

# Row 18: a shell line refuses (the for loop right after the Row 18 comment).
cat > "$SED_TMP" << 'SED'
/^_handoff_classify()/,/^}$/{
  /Row 18: background shell/{n;d}
}
SED
try "vnext_handoff_shell_line_refuses" "refuses background shell commands even with now" "$CLI" "$HANDOFF_BATS"

# Row 18: a shell status refuses (the while loop two lines after the comment).
cat > "$SED_TMP" << 'SED'
/^_handoff_classify()/,/^}$/{
  /Row 18: background shell/{n;n;d}
}
SED
try "vnext_handoff_shell_status_refuses" "refuses a session with a shell status" "$CLI" "$HANDOFF_BATS"

# Row 18 exception (spec 4.2 row 9): a busy target's own shell line is let
# through by --now, so the box recheck's now exemption covers it. Neutering the
# helper to always refuse means the busy --now session no longer passes.
cat > "$SED_TMP" << 'SED'
/^_handoff_shell_line_ok()/,/^}$/{
  s@local sline="[$]1" now="[$]2" n="[$]3" i=0@local sline="[$]1" now="[$]2" n="[$]3" i=0; return 1@
}
SED
try "vnext_handoff_now_shell_exception" "background shell line through with now" "$CLI" "$HANDOFF_BATS"

# Row 19: a turn in flight refuses without --now.
cat > "$SED_TMP" << 'SED'
/^_handoff_classify()/,/^}$/{
  s@== busy ]] && { _HO_VERDICT=R1; return 0; }@== busy ]] \&\& { :; }@
}
SED
try "vnext_handoff_busy" "refuses a turn in flight" "$CLI" "$HANDOFF_BATS"

# Row 20: a non-permission question gets its own reason (R2q, not R2p).
cat > "$SED_TMP" << 'SED'
/^_handoff_classify()/,/^}$/{
  s@_HO_VERDICT=R2q@_HO_VERDICT=R2p@
}
SED
try "vnext_handoff_question" "non permission question" "$CLI" "$HANDOFF_BATS"

# Row 20: a dialog is the limit question only when the transcript confirms it.
cat > "$SED_TMP" << 'SED'
/^_handoff_classify()/,/^}$/{
  s@dialog-open &&.*== 1 \]\] && lq=yes@dialog-open ]] \&\& lq=yes@
}
SED
try "vnext_handoff_limit_tail_required" "weekly limit question through only when the transcript confirms" "$CLI" "$HANDOFF_BATS"

# Row 22: a conversation in the compaction band with no 1M evidence refuses.
cat > "$SED_TMP" << 'SED'
/^_handoff_classify()/,/^}$/{
  s@_HO_VERDICT=R7@_HO_VERDICT=xR7@
}
SED
try "vnext_handoff_context_band" "in the compaction band with no 1M" "$CLI" "$HANDOFF_BATS"

# D9: the disclosure names the permission mode a session was in.
cat > "$SED_TMP" << 'SED'
/^_handoff_say_disclosure()/,/^}$/{
  /plan|acceptEdits|auto|dontAsk)/d
}
SED
try "vnext_handoff_permission_mode_line" "names the permission mode a session was in" "$CLI" "$HANDOFF_BATS"

# The disclosure prints before the box exec.
cat > "$SED_TMP" << 'SED'
/^_account_handoff()/,/^}$/{
  /_handoff_say_disclosure "[$]box" "[$]acct"/d
}
SED
try "vnext_handoff_disclosure_before_act" "cost lines before it acts" "$CLI" "$HANDOFF_BATS"

# The account lock is taken after the question, never before.
cat > "$SED_TMP" << 'SED'
/^_account_handoff()/,/^}$/{
  s@_handoff_say_disclosure "[$]box" "[$]acct"@_account_lock || true; _handoff_say_disclosure "$box" "$acct"@
}
SED
try "vnext_handoff_lock_after_question" "takes the account lock after the question" "$CLI" "$HANDOFF_BATS"

# The pin is re-read under the lock, so a switch that raced the question is not lost.
cat > "$SED_TMP" << 'SED'
/^_account_handoff()/,/^}$/{
  s@"[$]old2" != "[$]old"@1 -eq 2@
}
SED
try "vnext_handoff_pin_reread" "the pin changed during the question" "$CLI" "$HANDOFF_BATS"

# Row 19 on the live path: an open cleat shell refuses before the terminate exec.
cat > "$SED_TMP" << 'SED'
/^_account_handoff()/,/^}$/{
  s@_handoff_shell_open "[$]cname"@false@
}
SED
try "vnext_handoff_live_shellopen_before_terminate" "cleat shell open before it signals" "$CLI" "$HANDOFF_BATS"

# The requested tickets are written before the signalling exec.
cat > "$SED_TMP" << 'SED'
/^_account_handoff()/,/^}$/{
  /_handoff_ticket_write.*requested/d
}
SED
try "vnext_handoff_tickets_before_markers" "requested tickets before the signalling exec" "$CLI" "$HANDOFF_BATS"

# Every write after a docker call is guarded by _account_lock_owned.
cat > "$SED_TMP" << 'SED'
/^_account_handoff()/,/^}$/{
  s@if ! _account_lock_owned; then@if false; then@
}
SED
try "vnext_handoff_lock_owned" "another command took the account lock over" "$CLI" "$HANDOFF_BATS"

# The pin only moves when the terminate ended ok.
cat > "$SED_TMP" << 'SED'
/^_account_handoff()/,/^}$/{
  s@"[$]_PT_END" != ok@1 -eq 2@
}
SED
try "vnext_handoff_stage_needs_end_ok" "never moves the pin when terminate did not end ok" "$CLI" "$HANDOFF_BATS"

# A survivor keeps the box on the old login, and the exited targets reopen there.
cat > "$SED_TMP" << 'SED'
/^_account_handoff()/,/^}$/{
  /_handoff_write_ready "[$]cname" "[$]old"/d
}
SED
try "vnext_handoff_survivor_ready" "one target survives" "$CLI" "$HANDOFF_BATS"

# Ctrl-C is recorded from the lock through the exec (the trap is set).
cat > "$SED_TMP" << 'SED'
/^_account_handoff()/,/^}$/{
  s@^  _handoff_int_flag_trap$@  :@
}
SED
try "vnext_handoff_int_before_exec" "records Ctrl-C from the lock through the exec" "$CLI" "$HANDOFF_BATS"

# Ctrl-C is not restored before the exec (the flag trap holds).
cat > "$SED_TMP" << 'SED'
/^_handoff_int_flag_trap()/{
  s@trap '_HO_INT=1' INT@trap - INT@
}
SED
try "vnext_handoff_int_during_exec" "records Ctrl-C from the lock through the exec" "$CLI" "$HANDOFF_BATS"

# The ready ticket is written before the meta capture.
cat > "$SED_TMP" << 'SED'
/^_account_handoff()/,/^}$/{
  /_handoff_write_ready "[$]cname" "[$]acct"/d
}
SED
try "vnext_handoff_ready_before_meta" "ready ticket before it captures meta" "$CLI" "$HANDOFF_BATS"

# Only the exited or surviving sessions get a ready ticket, never a gone one.
cat > "$SED_TMP" << 'SED'
/^_handoff_write_ready()/,/^}$/{
  s@case "[$]_PT_EXITED[$]_PT_ALIVE" in@case "$_PT_EXITED$_PT_ALIVE$_PT_GONE" in@
}
SED
try "vnext_handoff_reopening_only_exited" "reopens only the sessions that stopped" "$CLI" "$HANDOFF_BATS"

# A switching or cancelled exit ran no session on this box, so the final exit
# must not harvest: doing so returns _ACCOUNT_LOCK_BUSY (the switch holds the
# lock) and prints a "was not saved" line contradicting "Nothing was changed".
cat > "$SED_TMP" << 'SED'
/^exec_claude()/,/^}$/{
  s@^    switching|cancelled) : ;;$@    switching|cancelled) _account_sync_out "$cname" || _harvest=$? ;;@
}
SED
try "vnext_handoff_switching_no_harvest" "switching and the account lock stays busy" "$CLI" "$HANDOFF_BATS"

# The router sends a running mounted box with a live agent to the live switch.
cat > "$SED_TMP" << 'SED'
/^_account_do_switch()/,/^}$/{
  s@if _account_box_ready "[$]cname"; then@if false; then@
}
SED
try "vnext_handoff_route_live_mounted" "routes the switch to the live handoff" "$CLI" "$ACCOUNTS_BATS"

# ── v1.5.0 release fixes ───────────────────────────────────────────────────

# v1.5.0: a non-ASCII project folder keeps the key v1.4.3 gave it under a UTF-8
# locale while that session directory exists. Dropping the adoption re-keys it.
cat > "$SED_TMP" << 'SED'
/^_derive_project_session_key()/,/^}$/{
  /_basename="[$]_legacy"/d
}
SED
try "v150_session_key_legacy_adopt" "keeps its pre-pin session key on upgrade"

# v1.5.0: a symlink in the projects store is never adopted as the legacy key.
cat > "$SED_TMP" << 'SED'
/^_derive_project_session_key()/,/^}$/{
  s/ && ! -L "[$][{]HOME[}]\/[.]claude\/projects\/[$][{]_legacy[}]-[$][{]_hash[}][$][{]_suffix[}]"//
}
SED
try "v150_session_key_legacy_no_symlink" "symlinked legacy session directory is never adopted"

# v1.5.0: cmd_start refreshes the settings overlays, so a declined drift cannot
# leave the unsafe-rm hook live with no red guard line.
cat > "$SED_TMP" << 'SED'
/^cmd_start()/,/^}$/{
  /_refresh_settings_overlays "[$]cname" "[$]project"/d
}
SED
try "v150_start_refreshes_settings_overlay" "plain cleat drops a stale unsafe-rm hook"

# v1.5.0: a stopped box re-creates its nested mount targets before docker start.
cat > "$SED_TMP" << 'SED'
/^cmd_start()/,/^}$/{
  /_ensure_host_mount_targets "[$]cname"/d
}
SED
try "v150_start_mount_targets" "cmd_start re-creates vanished mount targets"

cat > "$SED_TMP" << 'SED'
/^cmd_resume()/,/^}$/{
  /_ensure_host_mount_targets "[$]cname"/d
}
SED
try "v150_resume_mount_targets" "cmd_resume re-creates vanished mount targets"

# v1.5.0: unpin, account rm and account adopt sign the staged file out of the
# account only, keeping the box's own MCP logins. Back to deleting the file.
cat > "$SED_TMP" << 'SED'
/^_account_strip_staged()/,/^}$/{
  s/^  if \[\[ -f "[$]box_cred" && ! -L "[$]box_cred" \]\] && snap=.*; then$/  if false; then/
}
SED
try "v150_account_strip_keeps_mcp" "own MCP login in the staged file" "$CLI" "$ACCOUNTS_BATS"

cat > "$SED_TMP" << 'SED'
/^_account_switch_locked()/,/^}$/{
  s/^    _account_strip_staged "[$]cname"$/    rm -f "$(_account_box_auth_dir "$cname")\/.credentials.json"/
}
SED
try "v150_account_unpin_keeps_mcp" "unpinning keeps the box's own MCP login" "$CLI" "$ACCOUNTS_BATS"

cat > "$SED_TMP" << 'SED'
/^_account_do_remove()/,/^}$/{
  s/^    _account_strip_staged "[$]b"$/    rm -f "$(_account_box_auth_dir "$b")\/.credentials.json"/
}
SED
try "v150_account_rm_keeps_mcp" "account rm keeps the unpinned box's own MCP login" "$CLI" "$ACCOUNTS_BATS"

cat > "$SED_TMP" << 'SED'
/^_account_adopt_locked()/,/^}$/{
  s/^    _account_strip_staged "[$]b"$/    rm -f "$(_account_box_auth_dir "$b")\/.credentials.json"/
}
SED
try "v150_account_adopt_keeps_mcp" "account adopt keeps a pinned box's own MCP login" "$CLI" "$ACCOUNTS_BATS"

# v1.5.0: the stale-identity flag is skipped when its directory does not exist,
# so no raw redirect error prints above the switch's success line.
cat > "$SED_TMP" << 'SED'
/^_handoff_flag_identity_stale()/,/^}$/{
  /^  \[\[ -d "[$][{]f%\/[*][}]" \]\] || return 0$/d
}
SED
try "v150_identity_stale_flag_needs_dir" "flagging a stale identity on a never-started box prints nothing"

# v1.5.0: the reopening check runs after the first probe, so a ticket whose
# session is already back in the live set does not refuse a second switch.
cat > "$SED_TMP" << 'SED'
/^_account_handoff()/,/^}$/{
  s@^  # Row 6/7: probe[.]$@  if _handoff_tickets_pending "$cname"; then _handoff_say_refusal R18 "$box" "$acct"; return 1; fi@
}
SED
try "v150_handoff_pending_after_probe" "second switch through once the reopened session is back" "$CLI" "$HANDOFF_BATS"

# v1.5.0: the live switch traps Ctrl-C as a flag, never an ignore, so a child
# blocked on a FIFO the box swapped in dies on Ctrl-C instead of holding the lock.
cat > "$SED_TMP" << 'SED'
/^_handoff_int_flag_trap()/{
  s@trap '_HO_INT=1' INT@trap '' INT@
}
SED
try "v150_handoff_int_flag_not_ignore" "Ctrl-C trap still kills a child blocked on a FIFO" "$CLI" "$HANDOFF_BATS"

# v1.5.0: a jq-less host passes a hook-free project settings file through. Every
# file becoming {} again loses its permissions, env and model.
cat > "$SED_TMP" << 'SED'
s@^        if LC_ALL=C grep -q -e hooks -e '[\]\\u' "[$]pf" 2>/dev/null; then$@        if true; then@
SED
try "v150_jqless_hookfree_passthrough" "jq-less host passes a hook-free project settings file through"

# v1.5.0: a hooks key spelled with a JSON escape still counts as hooks.
cat > "$SED_TMP" << 'SED'
s@^        if LC_ALL=C grep -q -e hooks -e '[\]\\u' "[$]pf" 2>/dev/null; then$@        if LC_ALL=C grep -q -e hooks "$pf" 2>/dev/null; then@
SED
try "v150_jqless_escaped_hooks_key" "jq-less host warns when a project settings file with hooks is emptied"

# v1.5.0: the pre-mask recreate note names a named box, so `cleat rm` never
# removes main by following it.
cat > "$SED_TMP" << 'SED'
/^_maybe_note_missing_kit_masks()/,/^}$/{
  s@^    _fix="cleat rm [$][{]_b[}] && cleat start [$][{]_b[}]"$@    :@
}
SED
try "v150_mask_note_names_box" "pre-mask recreate note names the box"

# v1.5.0: the account-mount remedy prints `cleat start <box>`, never the
# non-command `cleat <box>`.
cat > "$SED_TMP" << 'SED'
s@then [$][{]BOLD[}]cleat start [$][{]box[}][$][{]RESET[}][$][{]DIM[}], and it takes effect[.]@then ${BOLD}cleat ${box}${RESET}${DIM}, and it takes effect.@
SED
try "v150_account_mount_remedy_start" "recreate remedy for a box without the account mount is a real command" "$CLI" "$ACCOUNTS_BATS"

# v1.5.0: the launch auth line reports the account in effect, not the pin.
cat > "$SED_TMP" << 'SED'
/^_print_auth_line()/,/^}$/{
  s@acct="[$](_account_effective "[$][{]1:-[}]" 2>/dev/null)" || acct="[$]_ACCOUNT_DEFAULT"@acct="$(_box_account_read "${1:-}")"@
}
SED
try "v150_auth_line_effective_account" "pinned box without the account mount says its auth is shared" "$CLI" "$ACCOUNTS_BATS"

# v1.5.0: `cleat config --project --enable unsafe-rm` is refused, never reported
# as enabled for a cap resolve_caps strips.
cat > "$SED_TMP" << 'SED'
/^cmd_config()/,/^}$/{
  s@^    if \[\[ "[$]action" == "enable" && "[$]cap_name" == "unsafe-rm" && "[$]scope" == "project" \]\]; then$@    if false; then@
}
SED
try "v150_config_project_unsafe_rm_refused" "unsafe-rm is refused for a project or a box" "$CLI" "$CONFIG_BATS"

# v1.5.0: generate never stamps unsafe-rm into a project .cleat.
cat > "$SED_TMP" << 'SED'
/^_config_generate_project()/,/^}$/{
  s@case "[$]_gc" in unsafe-rm) ;; [*]) caps+=("[$]_gc") ;; esac@caps+=("$_gc")@
}
SED
try "v150_config_generate_drops_unsafe_rm" "unsafe-rm is never stamped into a project" "$CLI" "$CONFIG_BATS"

# v1.5.0: a project-scope editor save drops unsafe-rm.
cat > "$SED_TMP" << 'SED'
/^_config_editor_save()/,/^}$/{
  s@^    if \[\[ "[$]cap" == unsafe-rm && "[$]scope" == project \]\]; then$@    if false; then@
}
SED
try "v150_config_editor_save_drops_unsafe_rm" "project-scope save drops unsafe-rm" "$CLI" "$CONFIG_BATS"

# v1.5.0: the resume live-session probe is bounded on a host with no timeout(1).
cat > "$SED_TMP" << 'SED'
/^_box_live_session_ids()/,/^}$/{
  s@out="[$](_run_bounded "[$]_RESUME_PROBE_BOUND_S" docker exec@out="$($(command -v timeout >/dev/null 2>\&1 \&\& echo timeout 8) docker exec@
}
SED
try "v150_resume_probe_bounded_without_timeout" "stalled box answer is bounded on a host with no timeout" "$CLI" "$START_RESUME_BATS"

# v1.5.0: `cleat browser allow` persists a host that is only in the env var.
cat > "$SED_TMP" << 'SED'
/^cmd_browser()/,/^}$/{
  s@if _bridge_origin_persisted "[$]host"; then@if _bridge_origin_allowed "$host"; then@
}
SED
try "v150_browser_allow_persists_env_host" "persists a host that is only in the env var" "$CLI" "$BROWSER_BRIDGE_BATS"

# v1.5.0: the project unsafe-rm warning prints once per file per run.
cat > "$SED_TMP" << 'SED'
/^resolve_caps()/,/^}$/{
  s@^          [*]"|[$]caps_file|"[*]) ;;$@          *"|$caps_file|NEVER"*) ;;@
}
SED
try "v150_project_unsafe_rm_warn_once" "project unsafe-rm warning prints once per launch" "$CLI" "$CAPABILITIES_BATS"

# v1.5.0: the reopen line escapes the stored account name before echo -e.
cat > "$SED_TMP" << 'SED'
/^_handoff_say_t1()/,/^}$/{
  /^      who="[$](_sessions_safe_str "[$]who")"$/d
}
SED
try "v150_reopen_line_escapes_who" "reopen line renders a stored account name without interpreting escapes" "$CLI" "$HANDOFF_BATS"

# v1.5.0: `cleat account rm` refuses while a pinned box has a cleat shell open,
# the same move the switch refuses.
cat > "$SED_TMP" << 'SED'
/^_account_do_remove()/,/^}$/{
  s@^    if _handoff_shell_open "[$]b"; then$@    if false; then@
}
SED
try "v150_account_rm_refuses_shell_open" "account rm refuses while a pinned box has a cleat shell open" "$CLI" "$ACCOUNTS_BATS"

# v1.5.0: an unwritable accounts directory is named as such, never reported as
# another cleat command, at the login, the attach and the run-dir wipe.
cat > "$SED_TMP" << 'SED'
/^cmd_login()/,/^}$/{
  s@^  elif \[\[ [$]_login_harvest -eq [$]_ACCOUNT_LOCK_BUSY && "[$]{_ACCOUNT_LOCK_UNWRITABLE:-0}" -eq 1 \]\]; then$@  elif false; then@
}
SED
try "v150_unwritable_accounts_login_message" "cleat login names an unwritable accounts directory" "$CLI" "$ACCOUNTS_BATS"

cat > "$SED_TMP" << 'SED'
/^_account_apply_exec_env()/,/^}$/{
  s@^  if \[\[ [$]_si -eq [$]_ACCOUNT_LOCK_BUSY && "[$]{_ACCOUNT_LOCK_UNWRITABLE:-0}" -eq 1 \]\]; then$@  if false; then@
}
SED
try "v150_unwritable_accounts_attach_message" "an attach names an unwritable accounts directory" "$CLI" "$ACCOUNTS_BATS"

cat > "$SED_TMP" << 'SED'
/^_account_wipe_run_dir()/,/^}$/{
  s@^    if \[\[ "[$]{_ACCOUNT_LOCK_UNWRITABLE:-0}" -eq 1 \]\]; then$@    if false; then@
}
SED
try "v150_unwritable_accounts_wipe_message" "a run-dir wipe names an unwritable accounts directory" "$CLI" "$ACCOUNTS_BATS"

# The settings refresh is skipped on a host with no jq (retargeted from a source
# grep when the refresh moved into _refresh_settings_overlays).
cat > "$SED_TMP" << 'SED'
/^_refresh_settings_overlays()/,/^}$/{
  s@^  if \[\[ -d "[$]settings_overlay_dir" \]\] && command -v jq &>/dev/null; then$@  if [[ -d "$settings_overlay_dir" ]]; then@
}
SED
try "v150_settings_refresh_guards_jq" "hook bridge noop when jq unavailable"

# The Darwin blocker: /dev/fd/N is a devfs node there, so `-ef` (device AND
# inode) never matched and every harvest on a Mac refused. Reverting the inode
# reader to -ef, dropping the -L dereference that makes one reader answer alike
# on both platforms, and dropping the symlink refusal.
cat > "$SED_TMP" << 'SED'
/^_fd_holds_path()/,/^}$/{
  s@^  \[\[ "[$]a" == "[$]b" \]\]$@  [[ "$path" -ef "/dev/fd/$fd" ]]@
}
SED
try "v150_snapshot_inode_not_ef" "a snapshot is taken where -ef and the inode disagree"

cat > "$SED_TMP" << 'SED'
/^_fd_holds_path()/,/^}$/{
  s@ls -Ldi "/dev/fd/[$]fd"@ls -di "/dev/fd/$fd"@
}
SED
try "v150_snapshot_fd_deref" "a snapshot still refuses a descriptor on another file"

cat > "$SED_TMP" << 'SED'
/^_fd_holds_path()/,/^}$/{
  s@^  \[\[ ! -L "[$]path" \]\] || return 1$@  :@
}
SED
try "v150_snapshot_symlink_path" "a snapshot refuses a symlinked path and a missing one"

# The refused-harvest advisory: without it a refusal at a session end is silent
# and reads as saved.
cat > "$SED_TMP" << 'SED'
/^_maybe_report_account_harvest_refused()/,/^}$/{
  s@^  \[\[ "[$]rc" -eq 1 \]\] || return 0$@  [[ "$rc" -eq 99 ]] || return 0@
}
SED
try "v150_harvest_refused_notice" "a refused harvest at session end says the login was not saved" "$CLI" "$ACCOUNTS_BATS"

cat > "$SED_TMP" << 'SED'
s@^  _maybe_report_account_harvest_refused "[$]_harvest" "[$]cname"$@  :@
SED
try "v150_harvest_refused_wired" "session end reports a refused harvest" "$CLI" "$EXEC_CLAUDE_BATS"

# An attach is a use. Without the stamp the list showed the hour of the last
# switch, so a session that had just ended read "last used 22h ago".
cat > "$SED_TMP" << 'SED'
/^_account_apply_exec_env()/,/^}$/{
  s@^  \[\[ [$]_si -ne 0 \]\] || _account_capture_meta "[$]acct" || true$@  :@
}
SED
try "v150_attach_stamps_last_used" "an attach stamps the account as used" "$CLI" "$ACCOUNTS_BATS"

# The blank line that keeps a pre-launch advisory out of the session-end
# reclaim's way. Without it the amber hooks line is erased on a clean exit.
cat > "$SED_TMP" << 'SED'
s@^  \[\[ [$]_ec_pre_notice -eq 0 \]\] || _EC_SAID=1$@  :@
SED
try "v150_advisory_survives_reclaim" "the advisory survives the session-end reclaim" "$CLI" "$HOOKS_BATS"

# The bridge waits for the spool as long as the session lives. The old 30s
# bound meant a first tool call later than half a minute got no host hooks.
cat > "$SED_TMP" << 'SED'
/^_hook_bridge_watcher()/,/^}$/{
  s@^  while \[\[ ! -f "[$]hooks_file" \]\]; do$@  _hb_waited=0; while [[ ! -f "$hooks_file" ]] \&\& [[ $_hb_waited -lt 30 ]]; do _hb_waited=$((_hb_waited + 1));@
}
SED
try "v150_bridge_waits_for_spool" "waits for a spool that arrives late" "$CLI" "$HOOKS_BATS"

# And the spool is created before claude starts, so nothing depends on the box.
cat > "$SED_TMP" << 'SED'
s@^    ( set -C; umask 077; : > "[$]hooks_file" ) 2>/dev/null || true$@    :@
SED
try "v150_bridge_spool_precreated" "the hook spool exists before claude starts" "$CLI" "$HOOKS_BATS"

# Identity before expiry at an attach. The old rule kept whatever expired last,
# so a stranger's login made inside the box won and the session billed to it.
cat > "$SED_TMP" << 'SED'
/^_account_sync_in_locked()/,/^}$/{
  s@^      _account_harvest_from "[$]acct" "[$]cname" "[$]snap" || _hrc=[$]?$@      _hrc=0@
}
SED
try "v150_attach_identity_before_expiry" "an attach refuses a newer login that belongs to another account" "$CLI" "$ACCOUNTS_BATS"

# And the account's own refreshed login still wins, with the store brought up
# to date rather than the box being pushed back onto an older token.
cat > "$SED_TMP" << 'SED'
/^_account_sync_in_locked()/,/^}$/{
  s@^      _account_harvest_from "[$]acct" "[$]cname" "[$]snap" || _hrc=[$]?$@      _hrc=3@
}
SED
try "v150_attach_keeps_own_refresh" "an attach keeps a newer login the server says is this account" "$CLI" "$ACCOUNTS_BATS"

# An identity the server could not vouch for must leave the staged login alone.
# Staging the store's copy over it rolls the box back to a spent grant.
cat > "$SED_TMP" << 'SED'
/^_account_sync_in_locked()/,/^}$/{
  s@^      if \[\[ [$]_hrc -ne 2 \]\]; then$@      if false; then@
}
SED
try "v150_attach_offline_keeps_staged" "an attach the server cannot vouch for keeps the login the box has" "$CLI" "$ACCOUNTS_BATS"

# A staging that failed for any other reason used to be silent, under a summary
# that named the pin.
cat > "$SED_TMP" << 'SED'
/^_account_apply_exec_env()/,/^}$/{
  s@^  elif \[\[ [$]_si -ne 0 && [$]{_ACCOUNT_STAGE_UNKEPT:-0} -ne 1 && [$]_si -ne [$]_ACCOUNT_LOCK_BUSY \]\]; then$@  elif false; then@
}
SED
try "v150_attach_reports_failed_staging" "an attach says so when the account could not be staged" "$CLI" "$ACCOUNTS_BATS"

# The spool is created with noclobber, so a planted link is never followed.
cat > "$SED_TMP" << 'SED'
s@^    ( set -C; umask 077; : > "[$]hooks_file" ) 2>/dev/null || true$@    ( umask 077; : > "$hooks_file" ) 2>/dev/null || true@
SED
try "v150_spool_noclobber" "a planted link is never created through" "$CLI" "$HOOKS_BATS"

# cleat shell and cleat login stage the pinned account too, so they have to
# leave the identity flag behind like every other path that changes the login.
cat > "$SED_TMP" << 'SED'
/^cmd_shell()/,/^}$/{
  s@^  _RESOLVED_PROJECT="[$]project"$@  :@
}
SED
try "v150_shell_flags_identity" "a shell or a login flags the cached identity" "$CLI" "$ACCOUNTS_BATS"

# The blank that keeps a notice out of the reclaim's way is emitted at the exec,
# because the prepare prints INSIDE the relaunch loop.
cat > "$SED_TMP" << 'SED'
s@^    \[\[ [$]{_EC_SAID:-0} -eq 0 \]\] || { echo ""; _EC_SAID=0; }$@    :@
SED
try "v150_blank_at_the_exec" "the blank before claude survives a notice printed by the prepare" "$CLI" "$EXEC_CLAUDE_BATS"

# And every late printer has to mark that window, or the blank never fires.
cat > "$SED_TMP" << 'SED'
/^_account_apply_exec_env()/,/^}$/{
  s@^    _EC_SAID=1$@    :@
}
SED
try "v150_late_printers_mark" "the blank before claude survives a notice printed by the prepare" "$CLI" "$EXEC_CLAUDE_BATS"

# The spool offset advances by bytes consumed as whole lines. Jumping to the
# window's end swallows the tail of an event the box was still writing.
cat > "$SED_TMP" << 'SED'
s@^      byte_offset=[$]_hb_pos$@      byte_offset=$file_size@
SED
try "v150_spool_offset_consumed" "an event torn across two polls is not lost" "$CLI" "$HOOKS_BATS"

# A redirect truncates before jq runs, so the refresh writes through a variable.
cat > "$SED_TMP" << 'SED'
/^_refresh_settings_overlays()/,/^}$/{
  s@^      if \[\[ -n "[$]_rso" \]\]; then$@      if true; then@
}
SED
try "v150_overlay_refresh_keeps_last_good" "a malformed host settings file never empties the overlay" "$CLI" "$HOOKS_BATS"

# cleat claude refreshes BOTH overlays through the shared function.
cat > "$SED_TMP" << 'SED'
/^cmd_claude()/,/^}$/{
  s@^  _refresh_settings_overlays "[$]cname" "[$]project"$@  :@
}
SED
try "v150_claude_refreshes_overlays" "wires the refresh in, not only the project half" "$CLI" "$HOOKS_BATS"

# A real login that is merely too big to copy is not junk.
cat > "$SED_TMP" << 'SED'
/^_account_keepable_snapshot()/,/^}$/{
  s@^  _account_cred_sane_size "[$]f" || return 2$@  _account_cred_sane_size "$f" || return 1@
}
SED
try "v150_oversized_login_kept" "an oversized but real login is kept, never treated as junk" "$CLI" "$ACCOUNTS_BATS"

# A deferred identity drop has to leave a retry behind, or the removed
# account's name outlives the account.
cat > "$SED_TMP" << 'SED'
/^_account_invalidate_identity_key()/,/^}$/{
  s@^    : > "[$]{f}.identity-stale" 2>/dev/null || true$@    :@
}
SED
try "v150_deferred_drop_flags" "a deferred identity drop leaves something for the next launch" "$CLI" "$ACCOUNTS_BATS"

# One bridge per box. Two tailing the same spool run every host hook twice.
cat > "$SED_TMP" << 'SED'
s@^    if _box_hook_bridge_live "[$]cname"; then$@    if false; then@
SED
try "v150_one_hook_bridge_per_box" "a second terminal on the same box does not start a second bridge" "$CLI" "$HOOKS_BATS"

# The third browser refusal had no report, so cleat login said nothing at all.
cat > "$SED_TMP" << 'SED'
s@^  _maybe_report_nobind_opens "[$]log" "[$]off"$@  :@
SED
try "v150_nobind_reported" "a login deferred for a busy callback port is reported" "$CLI" "$BROWSER_BRIDGE_BATS"

# The drops log grows on the box's schedule, so it is capped like the run log.
cat > "$SED_TMP" << 'SED'
/^_hook_drop_log()/,/^}$/{
  s@^      mv -f "[$]f" "[$]f.1" 2>/dev/null || true$@      :@
}
SED
try "v150_drops_log_rotates" "the box cannot grow it without bound" "$CLI" "$HOOKS_BATS"

# bash 3.2 treats an EMPTY array under set -u as unbound, so the bridge died on
# its first event whenever the host had no settings file.
cat > "$SED_TMP" << 'SED'
s%^        _execute_host_hook_bg "[$]_HOOK_EV_OUT" "[$]_HOOK_EV_DIR" "[$]_hb_ws" .*$%        _execute_host_hook_bg "$_HOOK_EV_OUT" "$_HOOK_EV_DIR" "$_hb_ws" "${settings_files[@]}"%
SED
try "v150_bridge_empty_array" "an array that can be empty uses the .form"

# The title sanitiser ends in a locale-free expansion, not a sed that BSD
# rejects on an invalid byte.
cat > "$SED_TMP" << 'SED'
/^_sessions_safe_str()/,/^}$/{
  s@^  printf .%s. "[$]{v//\\\\/\\\\\\\\}"$@  printf '%s' "$v" | sed 's/\\/\\\\/g'@
}
SED
try "v150_safe_str_no_sed" "one invalid byte does not kill the picker" "$CLI" "$SESSIONS_BATS"

# Typeahead is drained before the handover question, or a buffered Enter from
# the picker answers it yes and a running session is restarted unasked.
cat > "$SED_TMP" << 'SED'
/^      _handoff_drain_typeahead$/{
  s@^      _handoff_drain_typeahead$@      :@
}
SED
try "v150_handoff_drains_before_ask" "a keystroke typed before the question is not an answer to it" "$CLI" "$HANDOFF_BATS"

# The rename's temp paths are unguessable, so a link the box plants at a
# predictable name is never written through.
cat > "$SED_TMP" << 'SED'
/^_sessions_rename_write()/,/^}$/{
  s@^  stamp="[$](mktemp "[$]{sdir}/.cleat-mtime.XXXXXX" 2>/dev/null)" || stamp=""$@  stamp="${sdir}/.cleat-mtime.$$"@
}
SED
try "v150_rename_temp_mktemp" "a link planted at the temp path is never written through" "$CLI" "$SESSIONS_BATS"

# One project is one box whatever the caller's locale.
cat > "$SED_TMP" << 'SED'
s@^  dir_name="[$](basename "[$]project_path" | LC_ALL=C tr .\[:upper:\]. .\[:lower:\]. | LC_ALL=C sed .s/\[^a-z0-9-\]/-/g.)"$@  dir_name="$(basename "$project_path" | tr '"'"'[:upper:]'"'"' '"'"'[:lower:]'"'"' | sed '"'"'s/[^a-z0-9-]/-/g'"'"')"@
SED
try "v150_container_name_locale" "the same project is one box whatever the caller" "$CLI" "$CONTAINER_NAME_BATS"

# One regex engine on both platforms: BSD grep rejects the PCRE-isms Claude
# Code's matchers use, so those hooks were silently skipped on a Mac. The
# mutation makes jq's test() fall back to a literal compare, which \w cannot
# satisfy.
cat > "$SED_TMP" << 'SED'
s@try ([$]t | test([$]m)) catch false@($t == $m)@
SED
try "v150_matcher_one_engine" "the same pattern matches on macOS and on Linux" "$CLI" "$HOOKS_BATS"

# `date -r` is an epoch on BSD and a FILE on GNU, so the probe runs from /.
cat > "$SED_TMP" << 'SED'
/^_account_clock()/,/^}$/{
  s@^  out="[$]( (cd / && date -r "[$]e" +%H:%M) 2>/dev/null || true)"$@  out="$(date -r "$e" +%H:%M 2>/dev/null || true)"@
}
SED
try "v150_clock_probe_from_root" "the reset clock ignores a file named like the epoch" "$CLI" "$ACCOUNTS_BATS"

# The verified-version list is prose in the notice. Printed raw it reads as one
# mangled version number as soon as it holds more than one entry.
cat > "$SED_TMP" << 'SED'
/^_handoff_verified_phrase()/,/^}$/{
  s@^    elif \[\[ [$]i -eq [$]n \]\]; then out="[$]{out} and [$]{v}"$@    elif [[ $i -eq $n ]]; then out="${out} ${v}"@
}
SED
try "v150_verified_versions_prose" "the verified-version notice reads as prose" "$CLI" "$HANDOFF_BATS"

# A staged login the box did not last run on takes the cached identity with it.
# Without the flag Claude shows the old account and sends its organisation.
cat > "$SED_TMP" << 'SED'
/^_account_sync_in_locked()/,/^}$/{
  s@^  \[\[ "[$](_account_cred_login "[$]snap")" == "[$]sobj" \]\] || _ACCOUNT_STAGED_NEW_LOGIN=1$@  :@
}
SED
try "v150_attach_flags_stale_identity" "an attach that stages a different login flags the cached identity" "$CLI" "$ACCOUNTS_BATS"

# The probe is shipped as text on argv, so a bare-word match made it report
# itself as a background shell and every live switch refused.
cat > "$SED_TMP" << 'SED'
/^_hb_scan()/,/^}$/{
  s@^        \*/shell-snapshots/\*) found_shell=1; break ;;$@        *shell-snapshots*) found_shell=1; break ;;@
}
SED
try "v150_probe_shell_path_only" "box probe ignores a process that merely names shell-snapshots" "$CLI" "$HANDOFF_BATS"



# Every $( ) forks a shell with the same argv under a new pid, so a pid skip
# list cannot cover the scan's own fork. Argv is the identity.
cat > "$SED_TMP" << 'SED'
/^_hb_scan()/,/^}$/{
  s@^      \[\[ "[$]joined" != "[$]selfcmd" \]\] || continue$@      :@
}
SED
try "v150_scan_skips_own_fork" "box scan ignores a fork of the script itself" "$CLI" "$HANDOFF_BATS"

# A sibling exec of the same script, and its runuser parent, carry the shipped
# text too. Neither is this pid, this parent, nor argv-identical to this scan.
cat > "$SED_TMP" << 'SED'
/^_hb_scan()/,/^}$/{
  s@^      \[\[ "[$]w" == cleat-hb \]\] || continue$@      [[ "$w" == cleat-hb-never ]] || continue@
}
SED
# The two self-skip tests in handoff.bats (the probe's own shell, the terminate
# recheck's) are deliberately WITHOUT their own entry: three mechanisms cover
# that scan now (the cleat-hb marker, the argv identity, the pid skip), and no
# single revert is observable in those two fixtures because the others catch
# it. The distinct scenarios each have an entry: v150_scan_skips_sibling_run
# for the marker, v150_scan_skips_own_fork for the argv, v150_probe_shell_path_only
# for the pattern.
try "v150_scan_skips_sibling_run" "box scan ignores a sibling run of the script" "$CLI" "$HANDOFF_BATS"
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

