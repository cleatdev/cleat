#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Mutation test for the regression registry.
#
# For each historical bug recorded in test/unit/regressions.bats, this script
# applies a sed mutation to bin/cleat that reintroduces the bug, then runs
# the guarding test and verifies the test FAILS. A test that passes against
# the mutated source is worthless — it doesn't catch the bug it claims to.
#
# This is the "verify 3 times" layer for the regression registry:
#   1. The test passes on the current (fixed) code
#   2. The test fails when the fix is reverted (this script)
#   3. The test does not cause false positives in the full suite
#
# Usage: test/mutation_regressions.sh [filter]
#   filter — optional substring to select a subset of mutations by name
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

# v0.5.1 — cmd_claude must set _RESOLVED_PROJECT
cat > "$SED_TMP" << 'SED'
/^cmd_claude()/,/^}$/{
  /_RESOLVED_PROJECT="\$project"/d
}
SED
try "v0.5.1_resolved_project" "cmd_claude sets _RESOLVED_PROJECT"

# v0.5.1 — hook overlay must replace command, not strip. Break it by replacing
# the forwarder path with something no test checks for.
cat > "$SED_TMP" << 'SED'
s|cat >> /var/log/cleat/events.jsonl|/bin/true|g
SED
try "v0.5.1_hook_replace" "hook overlay replaces command with forwarder"

# v0.6.0 + v0.6.5 — both guards must hold. Break BOTH the -d dir check and
# the -f file skip so the overlay is mounted even when neither exists.
cat > "$SED_TMP" << 'SED'
s|if \[\[ -d "\$project/.claude" \]\]; then|if true; then|
/\[\[ -f "\$pf" \]\] || continue/d
SED
try "v0.6.0_claude_guard" "skip project overlay when .claude/ missing"

# v0.6.1 — _browser_watcher must remove stale bridge file at startup
cat > "$SED_TMP" << 'SED'
/^  # Remove any URL left over from a previous session$/,/^  rm -f "\$bridge_file"$/d
SED
try "v0.6.1_browser_stale" "browser bridge removes stale file"

# v0.6.2 — docker run failure must surface docker stderr
cat > "$SED_TMP" << 'SED'
s|\[\[ -s "\$_docker_err" \]\] && error "\${DIM}\$(cat "\$_docker_err")\${RESET}"|true|
SED
try "v0.6.2_stderr_error" "docker run failure surfaces docker stderr"

# v0.6.2 — cmd_run must wipe stale overlay dir
cat > "$SED_TMP" << 'SED'
s|rm -rf "\$settings_overlay_dir"|true|
SED
try "v0.6.2_stale_overlay" "cmd_run wipes stale settings overlay"

# v0.6.2 — summary block must collapse $HOME to ~ (not show '~' literally)
cat > "$SED_TMP" << 'SED'
s|display_path="\${project/#\$HOME/\$_tilde}"|display_path="'~'\${project#\$HOME}"|
SED
try "v0.6.2_tilde" "summary block shows ~ without quotes"

# v0.6.3 — exec_claude must pass _RESOLVED_ENV_ARGS to docker exec
cat > "$SED_TMP" << 'SED'
/^exec_claude()/,/^}$/{
  /"\${_RESOLVED_ENV_ARGS\[@\]+/d
}
SED
try "v0.6.3_exec_claude_env" "exec_claude passes resolved env args"

# v0.6.3 — cmd_shell must call resolve_env_args. Replace the call with a
# no-op so the function signature is preserved but env resolution is skipped.
cat > "$SED_TMP" << 'SED'
/^cmd_shell()/,/^}$/{
  s|resolve_env_args "\$project"|true|
}
SED
try "v0.6.3_shell_resolve" "cmd_shell resolves env args"

# v0.6.3 — cmd_shell must set full PATH (use CLAUDE_ENV, not hardcoded HOME only)
cat > "$SED_TMP" << 'SED'
/^cmd_shell()/,/^}$/{
  s|"\${CLAUDE_ENV\[@\]}"|-e HOME=/home/coder|
}
SED
try "v0.6.3_shell_path" "cmd_shell sets PATH with /home/coder/.local/bin"

# v0.6.3 — cmd_login must call resolve_env_args. Replace with no-op.
cat > "$SED_TMP" << 'SED'
/^cmd_login()/,/^}$/{
  s|resolve_env_args "\$project"|true|
}
SED
try "v0.6.3_login_resolve" "cmd_login resolves env args"

# v0.6.3 — _parse_env_file must read last line without trailing newline
# (use # as delimiter to avoid shell pipe in pattern)
cat > "$SED_TMP" << 'SED'
s#while IFS= read -r line || \[\[ -n "\$line" \]\]; do#while IFS= read -r line; do#
SED
try "v0.6.3_parse_env_last" "_parse_env_file reads last line"

# v0.6.4 — _auth_callback_proxy must try TCP6 first. Remove the 6 so the
# call becomes pure TCP (the pre-fix behavior).
cat > "$SED_TMP" << 'SED'
s|TCP6\\\\:localhost|TCP\\\\:localhost|
SED
try "v0.6.4_tcp6_first" "tries TCP6 before TCP"

# v0.6.4 — socat must use -,ignoreeof to prevent stdin EOF propagation
cat > "$SED_TMP" << 'SED'
s|-,ignoreeof|-|g
SED
try "v0.6.4_ignoreeof" "uses ignoreeof on stdin"

# v0.6.5 — cmd_run must skip overlay mount when host file doesn't exist
cat > "$SED_TMP" << 'SED'
/\[\[ -f "\$pf" \]\] || continue/d
SED
try "v0.6.5_skip_missing" "cmd_run skips overlay mount for missing"

# v0.6.5 — cmd_run must force-remove partial container on failure
cat > "$SED_TMP" << 'SED'
/docker rm -f "\$cname" > \/dev\/null 2>&1 || true/d
SED
try "v0.6.5_cleanup_fail" "cmd_run cleans up partial container"

# v0.8.0 — per-project session overlay must be present in docker run
cat > "$SED_TMP" << 'SED'
/project_session_key=/d
/project_session_dir=/d
/mkdir -p "\$project_session_dir"/d
/mkdir -p "\${HOME}\/.claude\/projects\/-workspace"/d
/\$project_session_dir.*projects\/-workspace/d
SED
try "v0.8.0_session_isolation" "session overlay mount isolates projects"

# v0.8.0 — history.jsonl must be overlaid per-project. Remove the history mount.
cat > "$SED_TMP" << 'SED'
/history\.jsonl:\/home\/coder\/\.claude\/history\.jsonl/d
SED
try "v0.8.0_history_isolation" "history.jsonl overlay isolates per-project history"

# bash-3.2 — grep guard must catch associative arrays
cat > "$SED_TMP" << 'SED'
1a\
local -A _illegal_bash4=()
SED
try "bash32_assoc_array" "no associative arrays"

# bash-3.2 — grep guard must catch readarray (syntactically valid form)
cat > "$SED_TMP" << 'SED'
1a\
_never_run() { readarray -t arr < /dev/null; }
SED
try "bash32_readarray" "no readarray or mapfile"

# v0.9.2 — installer spin_stop must use %b (not %s) so escape sequences
# embedded in ok_msg/fail_msg render instead of printing literal \033.
cat > "$SED_TMP" << 'SED'
/^spin_stop()/,/^}$/{
  s|%b|%s|g
}
SED
try "v0.9.2_spin_stop_pct_b" "installer spin_stop renders escapes and clears line" "$INSTALLER"

# v0.9.2 — installer spin_stop must emit \r\033[K (not just \r) to clear the
# rest of a longer spinner line before writing a shorter success message.
cat > "$SED_TMP" << 'SED'
/^spin_stop()/,/^}$/{
  s|\\r\\033\[K|\\r|g
}
SED
try "v0.9.2_spin_stop_line_clear" "installer spin_stop renders escapes and clears line" "$INSTALLER"

# v0.9.2 — cmd_run must call _do_pull before falling back to _do_build so
# first-run users get the GHCR prebuilt image instead of a 2-5 min local build.
cat > "$SED_TMP" << 'SED'
s#_do_pull || _do_build#_do_build#
SED
try "v0.9.2_cmd_run_pull_first" "cmd_run attempts pull before building on first run"

# v0.9.2 — REGISTRY_IMAGE must be derived from $VERSION, not hardcoded to
# :latest. Revert to :latest and confirm the version-match guard fails.
cat > "$SED_TMP" << 'SED'
s|^REGISTRY_IMAGE=.*|REGISTRY_IMAGE="${REGISTRY_BASE}:latest"|
SED
try "v0.9.2_registry_tag_latest" "registry image tag matches CLI version"

# v0.9.2 — bin/cleat's spin_stop must emit \r\033[K (not just \r) to clear
# the rest of a longer spinner line before writing a shorter success message.
cat > "$SED_TMP" << 'SED'
/^spin_stop()/,/^}$/{
  s|\\r\\033\[K|\\r|g
}
SED
try "v0.9.2_cli_spin_stop_line_clear" "bin/cleat spin_stop clears line before writing"

# v0.10.0 — docker must be in KNOWN_CAPS. Remove it, guard test should fail.
cat > "$SED_TMP" << 'SED'
s|^KNOWN_CAPS=(git ssh env hooks gh docker)$|KNOWN_CAPS=(git ssh env hooks gh)|
SED
try "v0.10.0_docker_in_known_caps" "docker listed in KNOWN_CAPS"

# v0.10.0 — docker cap must mount the host docker socket when active. Remove
# the socket mount; the regression guard for socket mount should fail.
cat > "$SED_TMP" << 'SED'
/mount_args+=(-v \/var\/run\/docker.sock/d
SED
try "v0.10.0_docker_cap_socket_mount" "docker cap mounts host socket"

# v0.10.0 — docker cap must add a host-path identity mount + workdir so
# $(pwd) inside Cleat resolves to a host-valid path. Remove the identity
# mount; the path-remapping guard should fail.
cat > "$SED_TMP" << 'SED'
/mount_args+=(-v "\$project:\$project")/d
SED
try "v0.10.0_docker_cap_identity_mount" "docker cap mounts project at host path with workdir"

# v0.10.0 — workspace trust must default-deny project .cleat caps in non-TTY
# contexts when no opt-in is provided. Remove the trust gate so project
# caps are applied unconditionally — the supply-chain regression guard
# should fail.
cat > "$SED_TMP" << 'SED'
s|if _resolve_project_trust "\$project" "\$trust_mode"; then|if true; then|
SED
try "v0.10.0_trust_default_deny" "skips project .cleat caps"

# v0.10.0 — cmd_status must call resolve_caps with readonly mode so it
# never prompts. Remove the readonly argument and the "status never
# prompts" guard should fail.
cat > "$SED_TMP" << 'SED'
/# Resolve caps for display only/,/resolve_caps.*readonly/{
  s|resolve_caps "\$project" readonly|resolve_caps "\$project"|
}
SED
try "v0.10.0_status_readonly_trust" "cmd_status never prompts for trust"

# v0.10.0 — the trust hash must be over the *canonical* cap list, not the
# raw .cleat file. If the hash includes comments/whitespace, comment
# edits trigger re-approval churn. Replace canonical hashing with raw
# file hashing and the hash-stability guard should fail.
cat > "$SED_TMP" << 'SED'
/^_hash_cleat_caps\(\)/,/^}$/{
  s|caps="\$(_read_caps_from_file "\$path" \| _canonical_caps)"|caps="$(cat "$path")"|
}
SED
try "v0.10.0_trust_hash_canonical" "trust hash is over canonical caps"

# v0.10.0 — _md5 on Linux uses md5sum which appends "  -" (stdin filename)
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

# v0.10.0 — cleat resume after cleat rm must auto-create the container
# (not error out) so --continue can resume from the host-side session
# dir. Replace the cmd_run call with a plain `exit 1` and the regression
# test should fail (assert_success on cmd_resume).
cat > "$SED_TMP" << 'SED'
s#cmd_run "\$project"#exit 1#
SED
try "v0.10.0_resume_auto_creates" "cleat resume after cleat rm creates container"

# v0.10.0 — cmd_rm must not touch the per-project session dir under
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

# v0.10.0 — docker cap must overlay the session dir at the host-path-
# encoded key (so Claude's host-path-derived session dir maps to the
# per-project overlay). Remove the second session-dir overlay under
# the docker cap and the guard should fail.
cat > "$SED_TMP" << 'SED'
/mount_args+=(-v "\${project_session_dir}:\/home\/coder\/\.claude\/projects\/\${_host_project_key}")/d
SED
try "v0.10.0_docker_cap_session_overlay" "docker cap overlays session dir at host-path key"

# v0.10.1 — _do_pull must short-circuit when the version-tagged prebuilt
# image is already on disk. Force the cache check to always-false so
# every call hits the network, then fails (DOCKER_PULL_EXIT_CODE=1 in
# tests), then falls back to a local build — exactly what the regression
# test forbids.
cat > "$SED_TMP" << 'SED'
s|if docker image inspect "\$target_image" > /dev/null 2>&1; then|if false; then|
SED
try "v0.10.1_pull_local_cache_short_circuit" "_do_pull reuses locally cached prebuilt without network call"

# v0.10.1 — when the cache hit fires but `docker tag` silently fails,
# _do_pull must fall through to the network pull instead of returning
# success. Mutate the inner tag-success guard to unconditional truth so
# the success branch always fires regardless of the tag's exit code —
# the hardening regression test should fail (no fall-through warning,
# no network pull attempt).
cat > "$SED_TMP" << 'SED'
s|if docker tag "\$target_image" "\$IMAGE_NAME" > /dev/null 2>&1; then|if true; then|
SED
try "v0.10.1_pull_cache_tag_failure_fallthrough" "_do_pull falls through to network pull when cache-hit tag fails"

# v0.12.1 — drift detection now prompts to recreate (interactive). Mutate
# cmd_start to drop the _resolve_config_drift call. Without it, drift
# silently goes undetected and users keep hitting the stale-cap container.
# The regression spy in regressions.bats should fail to set DRIFT_CALLED.
cat > "$SED_TMP" << 'SED'
/^cmd_start()/,/^}$/{
  /_resolve_config_drift "\$cname" "\$project"/d
}
SED
try "v0.12.1_drift_recreate_wired" "cmd_start invokes _resolve_config_drift"

# v0.12.1 — the drift recreate prompt must interpret ANSI escapes. The prompt
# now routes through the shared _ask_yn helper, so mutate ITS `echo -en` back to
# `echo -n`: $BOLD/$RESET would then print as literal `\033[...]` strings. The
# regression test (pipes "y" into _resolve_config_drift) asserts no such literal
# appears — and this guards every prompt that uses _ask_yn, not just this one.
cat > "$SED_TMP" << 'SED'
s|echo -en "    ${_prompt}"|echo -n "    ${_prompt}"|
SED
try "v0.12.1_drift_prompt_ansi" "drift recreate prompt interprets ANSI escapes"

# v0.12.3 — _settings_overlay_intact must also verify that each bind source
# inside the overlay dir is a regular file, not just that the dir exists.
# Mutate the per-file check out of the helper so it falls back to the old
# dir-only behavior. With the per-file guard removed, cmd_start no longer
# auto-recreates on partial rotation — it would fall through to
# `docker start` and the regression test's recreate assertions would fail.
cat > "$SED_TMP" << 'SED'
/^_settings_overlay_intact()/,/^}$/{
  /\[\[ -f "\$src" \]\] || return 1/d
}
SED
try "v0.12.3_overlay_intact_per_file_check" "cmd_start auto-recreates when overlay dir survives but a file is missing"

# ── upgrade-claude hardening (tested against upgrade_claude.bats) ────────────

# Channel validation must reject anything but stable/latest/semver. Neuter the
# regex guard so a shell-injection channel would slip through — the rejection
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
# Filter is a regex matched against the test name — keep it free of the name's
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
# already runs the remote version — the equal-version test must then fail.
# Use `#` as the sed delimiter — the pattern contains `||`, which would
# otherwise be read as the `s|...|` delimiter and break the expression.
cat > "$SED_TMP" << 'SED'
s#\[\[ "\$remote" != "\$local_v" \]\] || return 0#[[ "$remote" != "$local_v" ]] || true#
SED
try "claude_check_strictly_newer" "no prompt when the image already runs the remote version" "$CLI" "$CLAUDE_BATS"

# CLEAT_CLAUDE_CHANNEL is user-controlled and is interpolated into a URL and
# the in-container shell command, so a non-stable/latest/semver value must be
# replaced with the safe default. Drop the fallback so a malicious channel
# would pass through — the injection-guard test must then fail.
# `#` delimiter again — the pattern contains `||`.
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

# cmd_clean's prune report must use if/fi, not `[[ ]] &&` — the latter makes the
# function (last statement in main) exit 1 on a successful run with 0 orphans.
# Revert to the `&&` form; the "exits 0 with nothing to prune" test must fail.
cat > "$SED_TMP" << 'SED'
s#if \[\[ \$_pruned -gt 0 \]\]; then info "Pruned \${_pruned} orphaned runtime dir(s)."; fi#[[ $_pruned -gt 0 ]] \&\& info "Pruned ${_pruned} orphaned runtime dir(s)."#
SED
try "run_dir_clean_exit_code" "exits 0 on a successful run with nothing to prune" "$CLI" "$RUN_DIR_BATS"

# v0.13.0 — the container must mount the per-project isolated .claude.json, not
# the shared host file. Revert to the old host-file mount; the regression test
# (which asserts the bind source is the per-project store, never ~/.claude.json)
# must fail.
cat > "$SED_TMP" << 'SED'
s#mount_args+=(-v "\$project_claude_json:/home/coder/.claude.json")#mount_args+=(-v "${HOME}/.claude.json:/home/coder/.claude.json")#
SED
try "v0.13.0_claude_json_isolation" "container mounts an isolated .claude.json"

# v0.13.0 — the summary "Project:" row must tell the truth under the docker cap
# (host path "(same path, sandboxed)", not "→ /workspace"). Revert the docker
# branch to the /workspace form; the regression test must fail.
cat > "$SED_TMP" << 'SED'
s#${display_path} ${DIM}(same path, sandboxed)${RESET}#${display_path} ${DIM}→${RESET} /workspace#
SED
try "v0.13.0_project_row_docker_cap" "summary Project row is truthful under the docker cap"

# v0.13.0 — _ask_yn must treat a read FAILURE (EOF / redirected stdin) as DECLINE,
# not empty (which callers read as the [Y/n] default of yes). Revert to the old
# empty-on-EOF behavior; the EOF-decline test must fail.
cat > "$SED_TMP" << 'SED'
s#read -r _reply || { printf -v "$_var" '%s' 'n'; return 0; }#read -r _reply || _reply=""#
SED
try "v0.13.0_ask_yn_eof_declines" "EOF / redirected stdin yields decline" "$CLI" "$TERMINAL_UX_BATS"

# v0.13.0 — the CLI self-update must skip a dirty/dev tree (else it nags
# "Update failed" every launch). Drop the guard; the dirty-tree skip test fails.
cat > "$SED_TMP" << 'SED'
/_repo_is_clean || return 0/d
SED
try "v0.13.0_cli_update_skips_dirty_tree" "skips entirely on a dirty/dev tree" "$CLI" "$VERSION_BATS"

# v0.13.0 — _apply_cli_update must check out the v-prefixed tag (latest_remote_tag
# returns a bare X.Y.Z; tags are vX.Y.Z). Drop the prefix; the real-git apply
# test (which asserts `checkout v9.9.9`) must fail.
cat > "$SED_TMP" << 'SED'
s#checkout "v${target}"#checkout "${target}"#
SED
try "v0.13.0_apply_checkout_v_prefix" "_apply_cli_update checks out v<tag>" "$CLI" "$VERSION_BATS"

# v0.13.0 — the open-bridge shim must guard its stdin `cat` read behind a tty
# check, else an interactive `open` (and `./test.sh` on a terminal) blocks
# forever. Remove the guard; the regression test that greps for `[ ! -t 0 ]`
# in the shim must fail.
cat > "$SED_TMP" << 'SED'
s/ && \[ ! -t 0 \]//
SED
try "v0.13.0_openbridge_tty_guard" "open-bridge does not read stdin when fd0 is a tty" "$OPENBRIDGE" "$REGRESSIONS"

# v0.13.0 — the test runner must feed bats stdin from /dev/null so an
# interactive run can't hang on a test that reads fd0. Drop the redirect; the
# regression test that greps test.sh for `</dev/null` on the bats call must
# fail. (Delete the token rather than rewriting the tail — a `&` in the sed
# replacement would expand to the whole match and leave `</dev/null` behind.)
cat > "$SED_TMP" << 'SED'
s#"\$f" </dev/null#"\$f"#
SED
try "v0.13.0_testsh_stdin_isolation" "test runner isolates bats stdin from the terminal" "$TEST_SH" "$REGRESSIONS"

# v0.13.0 — the sandbox-break warning (`warn_sandbox`) must render its whole
# line in amber, not just the `!`, so the docker-socket caution matches the
# sandbox cap. Revert it to the marker-only form; the terminal_ux test that
# asserts the amber code runs straight into the message must fail.
cat > "$SED_TMP" << 'SED'
s|\${AMBER}! \$1\${RESET}|\${AMBER}!\${RESET} \$1|
SED
try "v0.13.0_warn_sandbox_full_amber" "the whole line is amber, matching the sandbox cap" "$CLI" "$TERMINAL_UX_BATS"

# v0.13.1 — the session env must disable Claude's launch-time auto-updater
# (the freeze). Drop the flag from CLAUDE_ENV; the regression test that asserts
# the session exec carries DISABLE_AUTOUPDATER=1 must fail.
cat > "$SED_TMP" << 'SED'
s| -e DISABLE_AUTOUPDATER=1||
SED
try "v0.13.1_disable_autoupdater" "session env disables Claude's launch-time auto-updater"

# v0.13.1 — exec_claude must wait for the entrypoint UID remap before launching.
# Delete the call; the test that asserts a `id -u coder` probe was issued fails.
cat > "$SED_TMP" << 'SED'
/_wait_for_coder_remap "\$cname"/d
SED
try "v0.13.1_remap_wait" "session waits for the UID remap before launching"

# v0.13.1 — clip-daemon must use a per-uid runtime dir (CLEAT_CLIP_DIR), not the
# shared /tmp/clip.sock. Revert it to a fixed path; the test that points it at a
# per-uid dir and checks the socat bind path must fail.
cat > "$SED_TMP" << 'SED'
s|"\${CLEAT_CLIP_DIR:-/tmp/cleat-run-\$(id -u)}"|"/tmp/cleat-run-mutant"|
SED
try "v0.13.1_clip_per_uid_dir" "clip-daemon uses a per-uid runtime dir" "$CLIP_DAEMON" "$REGRESSIONS"

# v0.13.1 — the clip shim must resolve the SAME per-uid socket as clip-daemon.
# Revert it to the legacy /tmp/clip.sock; the path-consistency test must fail.
cat > "$SED_TMP" << 'SED'
s|SOCK="\${CLEAT_CLIP_DIR:-/tmp/cleat-run-\$(id -u)}/clip.sock"|SOCK="/tmp/clip.sock"|
SED
try "v0.13.1_clip_shim_sock_path" "clip shim and clip-daemon resolve the SAME socket path" "$CLIP_SHIM" "$REGRESSIONS"

# v0.13.1 — the entrypoint must clear stale clip runtime files (as root) before
# dropping to coder. Delete the cleanup line; the entrypoint test that asserts
# the removal must fail.
cat > "$SED_TMP" << 'SED'
/rm -rf \/tmp\/cleat-run-/d
SED
try "v0.13.1_entrypoint_clip_cleanup" "clears stale clipboard runtime files before dropping to coder" "$ENTRYPOINT" "$ENTRYPOINT_BATS"

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
