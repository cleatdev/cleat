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

BOLD=$'\033[1m'
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[0;33m'
DIM=$'\033[2m'
RESET=$'\033[0m'

cleanup() {
  [[ -f "$BACKUP" ]] && cp "$BACKUP" "$CLI"
  [[ -f "$INSTALLER_BACKUP" ]] && cp "$INSTALLER_BACKUP" "$INSTALLER"
  [[ -f "$ENTRYPOINT_BACKUP" ]] && cp "$ENTRYPOINT_BACKUP" "$ENTRYPOINT"
  [[ -f "$OPENBRIDGE_BACKUP" ]] && cp "$OPENBRIDGE_BACKUP" "$OPENBRIDGE"
  [[ -f "$CLIP_DAEMON_BACKUP" ]] && cp "$CLIP_DAEMON_BACKUP" "$CLIP_DAEMON"
  [[ -f "$CLIP_SHIM_BACKUP" ]] && cp "$CLIP_SHIM_BACKUP" "$CLIP_SHIM"
  [[ -f "$TEST_SH_BACKUP" ]] && cp "$TEST_SH_BACKUP" "$TEST_SH"
  rm -f "$BACKUP" "$INSTALLER_BACKUP" "$ENTRYPOINT_BACKUP" \
        "$OPENBRIDGE_BACKUP" "$CLIP_DAEMON_BACKUP" "$CLIP_SHIM_BACKUP" "$TEST_SH_BACKUP"
}
trap cleanup EXIT INT TERM

cp "$CLI" "$BACKUP"
cp "$INSTALLER" "$INSTALLER_BACKUP"
cp "$ENTRYPOINT" "$ENTRYPOINT_BACKUP"
cp "$OPENBRIDGE" "$OPENBRIDGE_BACKUP"
cp "$CLIP_DAEMON" "$CLIP_DAEMON_BACKUP"
cp "$CLIP_SHIM" "$CLIP_SHIM_BACKUP"
cp "$TEST_SH" "$TEST_SH_BACKUP"
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

  # Verify the mutated file still parses
  if ! bash -n "$target" 2>/dev/null; then
    echo "${YELLOW}~ $name: SKIPPED${RESET} ${DIM}(mutation caused syntax error)${RESET}"
    return 2
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
trap 'cleanup; rm -f "$SED_TMP"' EXIT INT TERM

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
s|if \[\[ -d "\$project/.claude" \]\]; then|if true; then|
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

# v0.10.0: docker cap must mount the host docker socket when active. Remove
# the socket mount; the regression guard for socket mount should fail.
cat > "$SED_TMP" << 'SED'
/mount_args+=(-v \/var\/run\/docker.sock/d
SED
try "v0.10.0_docker_cap_socket_mount" "docker cap mounts host socket"

# v0.10.0: docker cap must add a host-path identity mount + workdir so
# $(pwd) inside Cleat resolves to a host-valid path. Remove the identity
# mount; the path-remapping guard should fail.
cat > "$SED_TMP" << 'SED'
/mount_args+=(-v "\$project:\$project")/d
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
  s|caps="\$(_read_caps_from_file "\$path" \| _canonical_caps)"|caps="$(cat "$path")"|
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
cat > "$SED_TMP" << 'SED'
/_repo_is_clean || return 0/d
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
/^_project_caps_file()/,/^}$/{
  s|echo "\$project/.cleat.\$box"|echo "\$project/.cleat"|
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
/\[\[ "\$_src" == "\$project" \]\] || continue/d
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
# the "fresh install" test (which pins "New in v1.2.0") then fails.
cat > "$SED_TMP" << 'SED'
s/New in v1.2.0/New in v9.9.9/
SED
try "v0.15.0_highlight_label_frozen" "fresh install" "$CLI" "$WHATS_NEW_BATS"

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
/^      _maybe_check_docker_pressure$/d
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
s|(( 10#\$n > 0 ))|(( 10#$n >= 0 ))|
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
s|cleat.sh/changelog#v1.2.0|cleat.sh/changelog|
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
/^      _maybe_announce_docker_ready$/d
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
s|"$_login_bridge_mode" "0" &|"$_login_bridge_mode" "1" &|
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
SED
try "kits_ro_masks" "cmd_run mounts all three kit masks read-only" "$CLI" "$KITS_BATS"

# KIT COMMANDS MASK MOUNT: the third :ro mask (slash commands) must be present,
# or a caged agent can plant a host-user-level command native claude runs.
# Drop the commands mount entirely: the three-masks test loses it.
cat > "$SED_TMP" << 'SED'
/-v "\$CLEAT_RUN_DIR\/\${cname}\/kit\/commands:\/home\/coder\/\.claude\/commands:ro"/d
SED
try "kits_commands_mask_mount" "cmd_run mounts all three kit masks read-only" "$CLI" "$KITS_BATS"

# KIT COMMANDS PASS-THROUGH: the box must still READ the user's own slash
# commands (the mask seeds a copy). Break the copy: the pass-through test no
# longer finds the user's command in the overlay.
cat > "$SED_TMP" << 'SED'
s|cp -RL "${HOME}/.claude/commands/." "$kit_dir/commands/" 2>/dev/null \|\| true|true|
SED
try "kits_commands_passthrough" "pass-through-copies the user's slash commands" "$CLI" "$KITS_BATS"

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
/^_write_kits_to_file()/,/^}$/ s|\} > "\$file"|} > "$file"; [[ "$worker" != "$_KIT_DEFAULT_MODEL" ]]|
SED
try "kits_writer_strict_return" "DEFAULT models survives" "$CLI" "$SMOKE_BATS"

# COMMANDS PASS-THROUGH DEREFERENCE: dotfile-repo users symlink their slash
# commands; a copied symlink dangles inside the box. Revert -RL to -R: the
# deref test finds a symlink in the overlay and fails.
cat > "$SED_TMP" << 'SED'
s|cp -RL |cp -R |
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
# Collapse the predicate to always-VM: the native ready test fails.
cat > "$SED_TMP" << 'SED'
/^_docker_pool_is_vm()/,/^}$/ s|  _is_docker_desktop$|  return 0|
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
