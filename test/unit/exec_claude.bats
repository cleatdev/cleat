#!/usr/bin/env bats
load "../setup"
setup() {
  _common_setup
  use_docker_stub
  source_cli
  _host_clip_cmd() { echo ""; }
}
teardown() { _common_teardown; }

@test "execs into correct container as coder with -it" {
  run exec_claude "test-ctr" --dangerously-skip-permissions
  run assert_docker_exec_has "test-ctr"
  assert_success
  # Uses `runuser -u coder` rather than `docker exec --user coder` so that
  # supplementary groups from /etc/group are loaded via initgroups(3).
  # Required for the docker capability (host socket group membership).
  run assert_docker_exec_has "runuser -u coder"
  assert_success
  run assert_docker_exec_has "docker exec -it"
  assert_success
}

@test "forwards all arguments to claude inside container" {
  run exec_claude "test-ctr" --dangerously-skip-permissions --continue
  run assert_docker_exec_has "--dangerously-skip-permissions"
  assert_success
  run assert_docker_exec_has "--continue"
  assert_success
}

@test "sets HOME and PATH env vars" {
  run exec_claude "test-ctr" --dangerously-skip-permissions
  run assert_docker_exec_has "HOME=/home/coder"
  assert_success
  run assert_docker_exec_has "PATH="
  assert_success
}

@test "session env: CLAUDE_ENV injects exactly BROWSER, HOME, DISABLE_AUTOUPDATER, PATH, TERM (+ COLORTERM when set)" {
  # CLAUDE_ENV is forced into every session (docker exec -it "${CLAUDE_ENV[@]}").
  # Pin the EXACT key set so a future addition (especially one templated from
  # host state (PATH=$PATH, LANG, USER)) can't silently leak the host's shell
  # environment into the sandbox. Presence-only checks wouldn't catch that.
  # TERM and COLORTERM are the two DELIBERATE host-templated entries: docker
  # exec -t doesn't propagate the terminal type, and a terminfo mismatch
  # corrupts key sequences and colors. COLORTERM is filtered here because it's
  # only present when the invoking environment has it. BROWSER is fixed (never
  # host-templated): it points at the in-image open shim so login URLs reach
  # the bridge even in boxes whose create predates the -e BROWSER at run.
  local keys="" e
  for e in "${CLAUDE_ENV[@]}"; do
    [[ "$e" == "-e" ]] && continue
    [[ "${e%%=*}" == "COLORTERM" ]] && continue
    # IS_SANDBOX is the second conditional entry (root hosts only, so it only
    # shows up when the suite itself runs as root); its behavior is pinned by
    # the v1.2.0 regression test.
    [[ "${e%%=*}" == "IS_SANDBOX" ]] && continue
    keys+="${e%%=*}"$'\n'
  done
  local sorted
  sorted="$(printf '%s' "$keys" | sort | tr '\n' ' ' | sed 's/ *$//')"
  run echo "$sorted"
  assert_output "BROWSER DISABLE_AUTOUPDATER HOME PATH TERM"
}

@test "session env: BROWSER points at the open shim, never a host-templated value" {
  # The exec-time BROWSER is what heals boxes created before v1.1.1 (their
  # Config.Env is frozen without it, so claude 2.1.191+ falls back to the
  # manual code-paste login). It must be the fixed in-image shim path: a
  # host-templated BROWSER would leak the host's browser command into the box
  # where it doesn't exist.
  local e found=""
  for e in "${CLAUDE_ENV[@]}"; do
    [[ "${e%%=*}" == "BROWSER" ]] && found="$e"
  done
  run echo "$found"
  assert_output "BROWSER=/usr/local/bin/open-bridge"
}

@test "session env: COLORTERM is forwarded only when the host sets it" {
  # CLAUDE_ENV is built at SOURCE time, so the conditional must be exercised
  # in a fresh subprocess: an in-process override can't reach it. Forwarding
  # COLORTERM keeps truecolor in iTerm2/Ghostty; omitting it when absent keeps
  # the pinned key set tight.
  local stripped="$TEST_TEMP/cli_stripped"
  sed 's/^set -euo pipefail$/:/' "$CLI" > "$stripped"
  run bash -c "export COLORTERM=truecolor; source '$stripped'; printf '%s\n' \"\${CLAUDE_ENV[@]}\""
  assert_success
  assert_output --partial "COLORTERM=truecolor"
  run bash -c "unset COLORTERM; source '$stripped'; printf '%s\n' \"\${CLAUDE_ENV[@]}\""
  assert_success
  refute_output --partial "COLORTERM"
}

@test "session env: TERM falls back to xterm-256color when the host has none" {
  local stripped="$TEST_TEMP/cli_stripped"
  sed 's/^set -euo pipefail$/:/' "$CLI" > "$stripped"
  run bash -c "unset TERM; source '$stripped'; printf '%s\n' \"\${CLAUDE_ENV[@]}\""
  assert_success
  assert_output --partial "TERM=xterm-256color"
}

@test "creates clipboard bridge directory" {
  run exec_claude "my-ctr" --dangerously-skip-permissions
  run test -d "$CLEAT_RUN_DIR/my-ctr/clip"
  assert_success
  rm -rf "$CLEAT_RUN_DIR/my-ctr/clip"
}

@test "passes resolved env args to docker exec" {
  _RESOLVED_ENV_ARGS=(-e "DATABASE_URL=postgres://localhost/mydb" -e "SECRET=abc")
  run exec_claude "test-ctr" --dangerously-skip-permissions
  run assert_docker_exec_has "DATABASE_URL=postgres://localhost/mydb"
  assert_success
  run assert_docker_exec_has "SECRET=abc"
  assert_success
}

@test "handles empty resolved env args without error" {
  _RESOLVED_ENV_ARGS=()
  run exec_claude "test-ctr" --dangerously-skip-permissions
  assert_success
  run assert_docker_exec_has "test-ctr"
  assert_success
}

@test "env args with special characters are preserved" {
  _RESOLVED_ENV_ARGS=(-e "DSN=postgres://user:p@ss@host/db?opt=1&x=2")
  run exec_claude "test-ctr" --dangerously-skip-permissions
  run assert_docker_exec_has "DSN=postgres://user:p@ss@host/db?opt=1&x=2"
  assert_success
}

@test "exit 0 and 130 (Ctrl-C) produce no warning" {
  for code in 0 130; do
    export DOCKER_EXIT_CODE=$code
    run exec_claude "test-ctr" --dangerously-skip-permissions
    refute_output --partial "exited with code"
  done
}

@test "unexpected exit code warns user" {
  export DOCKER_EXIT_CODE=42
  run exec_claude "test-ctr" --dangerously-skip-permissions
  assert_output --partial "exited with code 42"
}

# ── OOM detection + guidance (_maybe_explain_oom) ─────────────────────────────
# A box that hits its memory ceiling OOM-kills (no swap, by design). The kill
# is otherwise an unexplained crash; name it and say how to fix it. Two signals:
# the cgroup OOM flag (State.OOMKilled) or exit 137 (SIGKILL).

@test "oom: explains an OOM flagged by the container (State.OOMKilled=true)" {
  docker() { [[ "$1" == "inspect" ]] && { echo "true"; return 0; }; return 0; }
  run _maybe_explain_oom "test-ctr" 1 2147483648   # 2 GiB box
  assert_success
  assert_output --partial "Out of memory"
  assert_output --partial "2 GB"          # the box-limit note
  assert_output --partial "memory = 8g"   # raise-memory guidance
  assert_output --partial "maxWorkers"    # fewer-workers guidance
}

@test "oom: infers OOM from exit 137 (SIGKILL) even when inspect reports false" {
  docker() { [[ "$1" == "inspect" ]] && { echo "false"; return 0; }; return 0; }
  run _maybe_explain_oom "test-ctr" 137 ""
  assert_success
  assert_output --partial "Out of memory"
}

@test "oom: stays silent on a non-OOM failure (other non-zero exit, not OOM-killed)" {
  docker() { [[ "$1" == "inspect" ]] && { echo "false"; return 0; }; return 0; }
  run _maybe_explain_oom "test-ctr" 1 2147483648
  assert_success
  assert_output ""
}

@test "oom: a session SIGKILLed (exit 137) surfaces the guidance through exec_claude" {
  export DOCKER_EXIT_CODE=137
  run exec_claude "test-ctr" --dangerously-skip-permissions
  assert_output --partial "Out of memory"
}

# ── Host fork exhaustion guidance (_maybe_explain_fork_exhaustion) ─────────────
# During a heavy multi-agent run the HOST per-user process table can fill, and
# Cleat's background watchers log "fork: Resource temporarily unavailable". The
# session usually still succeeds; this surfaces one plain host-limit diagnostic
# from THIS session's slice of the watcher log (never a stale prior session's).

@test "fork exhaustion: explains a fork error logged this session" {
  local log="$TEST_TEMP/.watcher-log"
  printf '/usr/local/bin/cleat: fork: retry: Resource temporarily unavailable\n' > "$log"
  run _maybe_explain_fork_exhaustion "$log" 0
  assert_success
  assert_output --partial "process slots"
  assert_output --partial "maxprocperuid"
}

@test "fork exhaustion: stays silent on a clean watcher log" {
  local log="$TEST_TEMP/.watcher-log"
  printf '[browser-watcher 10:00:00] opening URL on host\n' > "$log"
  run _maybe_explain_fork_exhaustion "$log" 0
  assert_success
  assert_output ""
}

@test "fork exhaustion: ignores a fork error from a PRIOR session (before the offset)" {
  local log="$TEST_TEMP/.watcher-log"
  printf '/usr/local/bin/cleat: fork: retry: Resource temporarily unavailable\n' > "$log"
  local off; off="$(wc -c < "$log")"     # this session starts AFTER the stale error
  printf 'clean line this session\n' >> "$log"
  run _maybe_explain_fork_exhaustion "$log" "$off"
  assert_success
  assert_output ""
}

@test "fork exhaustion: silent when the log does not exist" {
  run _maybe_explain_fork_exhaustion "$TEST_TEMP/nope" 0
  assert_success
  assert_output ""
}

@test "watcher log cap: a small log is kept and its size is the read offset" {
  local log="$TEST_TEMP/.watcher-log"
  printf 'small\n' > "$log"                 # 6 bytes
  run _cap_watcher_log "$log"
  assert_success
  assert_output "6"
  [ -s "$log" ]                             # not truncated
}

@test "watcher log cap: an oversized log is truncated and the offset resets to 0" {
  local log="$TEST_TEMP/.watcher-log"
  head -c 1200000 /dev/zero | tr '\0' 'x' > "$log"   # ~1.2 MB, over the 1 MB cap
  run _cap_watcher_log "$log"
  assert_success
  assert_output "0"
  [ ! -s "$log" ]                           # truncated to empty
}

@test "watcher log cap: a missing log yields offset 0, creates nothing" {
  run _cap_watcher_log "$TEST_TEMP/absent-log"
  assert_success
  assert_output "0"
  [ ! -e "$TEST_TEMP/absent-log" ]
}

@test "watcher log cap: BSD wc padding is stripped (macOS wc -c emits a padded count)" {
  # macOS/BSD wc -c right-justifies its count ("      6"), which the ^[0-9]+$
  # guard would reject and force to 0, defeating both the cap and the offset on
  # the maintainer's platform. This test simulates that padding on Linux CI.
  local log="$TEST_TEMP/.watcher-log"
  printf 'hello\n' > "$log"                 # 6 bytes
  wc() { if [ "$1" = "-c" ]; then printf '      %s\n' "$(command wc -c | command tr -d ' ')"; else command wc "$@"; fi; }
  run _cap_watcher_log "$log"
  assert_success
  assert_output "6"                          # not "0"
}

@test "fork exhaustion: the advisory is emitted AFTER the session-end reclaim" {
  # Placement guard: on rc=0 the success path runs a `\033[A\033[2K` reclaim that
  # erases the line just above it. The advisory must print AFTER that reclaim, or
  # its last (most actionable) line is wiped. Override the diagnostic to a
  # sentinel and assert it lands after "Session ended".
  _maybe_explain_fork_exhaustion() { echo "FORK_ADVISORY_SENTINEL"; }
  run exec_claude "test-ctr" --dangerously-skip-permissions
  assert_success
  assert_output --partial "FORK_ADVISORY_SENTINEL"
  local end_line adv_line
  end_line="$(printf '%s\n' "$output" | grep -n 'Session ended' | head -1 | cut -d: -f1)"
  adv_line="$(printf '%s\n' "$output" | grep -n 'FORK_ADVISORY_SENTINEL' | head -1 | cut -d: -f1)"
  [ -n "$end_line" ] && [ -n "$adv_line" ] || { echo "end=$end_line adv=$adv_line"; return 1; }
  [ "$adv_line" -gt "$end_line" ] || { echo "advisory (line $adv_line) not after session-end (line $end_line)"; return 1; }
}

# ── session-end reports: browser refusals and hook drops ─────────────────────
# Both reports read a byte window of a log from an offset exec_claude captures
# before the session. The report functions are tested on their own in
# browser_bridge.bats and hooks.bats. These pin the wiring: that exec_claude
# calls them, and hands them the offset rather than the start of the file.
#
# The rows are written from inside the `docker exec -it` call, which is the
# session itself. exec_claude issues other docker execs before it (the remap
# wait, docker access), so keying on `exec` alone would write twice.

@test "session end: a refusal written during the session is reported" {
  _host_open_cmd() { echo ""; }
  docker() {
    if [ "${1:-}" = exec ] && [ "${2:-}" = -it ]; then
      printf '[browser-watcher 10:00:00] %s origin=auth.example.com url=https://auth.example.com/oauth/authorize?redirect_uri=x\n' \
        "$_BROWSER_BLOCKED_MARK" >> "$CLEAT_RUN_DIR/test-ctr/clip/.proxy-log"
    fi
    command docker "$@"
  }
  run exec_claude "test-ctr" --dangerously-skip-permissions
  assert_success
  assert_output --partial "cleat browser allow auth.example.com"
}

@test "session end: a refusal from an earlier session is not repeated" {
  # Without the offset a refusal re-fires on every launch, the nag concept/21
  # forbids. One refusal this session keeps the report on screen, so the test
  # reads what it printed rather than a report that never ran.
  _host_open_cmd() { echo ""; }
  mkdir -p "$CLEAT_RUN_DIR/test-ctr/clip"
  printf '[browser-watcher 09:00:00] %s origin=old.example.com url=https://old.example.com/oauth/authorize?redirect_uri=x\n' \
    "$_BROWSER_BLOCKED_MARK" > "$CLEAT_RUN_DIR/test-ctr/clip/.proxy-log"
  docker() {
    if [ "${1:-}" = exec ] && [ "${2:-}" = -it ]; then
      printf '[browser-watcher 10:00:00] %s origin=new.example.com url=https://new.example.com/oauth/authorize?redirect_uri=x\n' \
        "$_BROWSER_BLOCKED_MARK" >> "$CLEAT_RUN_DIR/test-ctr/clip/.proxy-log"
    fi
    command docker "$@"
  }
  run exec_claude "test-ctr" --dangerously-skip-permissions
  assert_success
  assert_output --partial "cleat browser allow new.example.com"
  refute_output --partial "old.example.com"
}

@test "session end: a hook drop written during the session is reported, an earlier one is not" {
  _host_open_cmd() { echo ""; }
  # A drop row from a previous session of this same box, before the offset.
  _hook_drop_log "path" '{"hook_event_name":"Stop"}' "test-ctr" 0
  docker() {
    if [ "${1:-}" = exec ] && [ "${2:-}" = -it ]; then
      _hook_drop_log "path" '{"hook_event_name":"Stop"}' "test-ctr" 40
    fi
    command docker "$@"
  }
  run exec_claude "test-ctr" --dangerously-skip-permissions
  assert_success
  # The count sits between bold escapes, and BOLD itself carries a 1, so the
  # escapes go first. A $'...' literal: BSD sed has no \x1b.
  local plain
  plain="$(printf '%s' "$output" | sed $'s/\033\\[[0-9;]*m//g')"
  run printf '%s' "$plain"
  assert_output --partial "Dropped 1 hook event from the box"
}

# ── session-end held notice ──────────────────────────────────────────────────
# A harvest that found the box's login belongs to another account holds it
# instead of saving it over the pinned one (status 2). Nothing else on screen
# says so, and the box keeps running on that login until the next switch.

_held_other_account() {
  printf '{"claudeAiOauth":{"accessToken":"at-B1","refreshToken":"rt-B","expiresAt":1789028800000}}\n' > "$TEST_TEMP/held-src.json"
  _account_hold "$TEST_TEMP/held-src.json" work test-ctr other-account \
    "22222222-bbbb-4bbb-8bbb-bbbbbbbbbbbb" other@example.com "Other Org"
  HELD_ID="$_ACCOUNT_HELD_ID"
}

@test "session end says so when the login the box used belongs to another account" {
  local elsewhere
  _held_other_account
  run test -n "$HELD_ID"
  assert_success
  # A newer entry another box held is never this session's.
  printf '{"claudeAiOauth":{"accessToken":"at-C1","refreshToken":"rt-C","expiresAt":1789028800000}}\n' > "$TEST_TEMP/held-elsewhere.json"
  date() { printf '9000000000\n'; }
  _account_hold "$TEST_TEMP/held-elsewhere.json" work other-ctr other-account \
    "33333333-cccc-4ccc-8ccc-cccccccccccc" elsewhere@example.com ""
  unset -f date
  elsewhere="$_ACCOUNT_HELD_ID"
  run test -n "$elsewhere"
  assert_success
  _account_sync_out() { return 2; }
  run exec_claude "test-ctr" --dangerously-skip-permissions
  assert_success
  assert_output --partial "a login for another account, so it was not saved to"
  assert_output --partial "work"
  assert_output --partial "other@example.com"
  assert_output --partial "cleat account adopt $HELD_ID <name>"
  refute_output --partial "$elsewhere"
  refute_output --partial "elsewhere@example.com"
  # After the reclaim, which erases the line above it.
  local end_line notice_line
  end_line="$(printf '%s\n' "$output" | grep -n 'Session ended' | head -1 | cut -d: -f1)"
  notice_line="$(printf '%s\n' "$output" | grep -n "a login for another account, so it was not saved to" | head -1 | cut -d: -f1)"
  run test "${notice_line:-0}" -gt "${end_line:-999999}"
  assert_success
}

@test "session end stays quiet when the harvest had nothing to hold" {
  _held_other_account
  local rc
  for rc in 0 1 3; do
    _HARVEST_RC="$rc"
    _account_sync_out() { return "$_HARVEST_RC"; }
    run exec_claude "test-ctr" --dangerously-skip-permissions
    assert_success
    refute_output --partial "another account"
    refute_output --partial "cleat account adopt"
  done
}

# ── attach heal (_refresh_attached_claude_json) ──────────────────────────────
# The end-to-end heal (poisoned flag fixed in place, same inode) is pinned in
# regressions.bats; these pin the guards around it.

@test "attach heal: skips when a live agent is in the box" {
  _RESOLVED_PROJECT="$TEST_TEMP/project"
  mkdir -p "$_RESOLVED_PROJECT"
  local key
  key="$(_derive_project_session_key "$_RESOLVED_PROJECT" "main")"
  mkdir -p "$CLEAT_PROJECTS_DIR/$key"
  local f="$CLEAT_PROJECTS_DIR/$key/claude.json"
  echo '{"hasCompletedOnboarding":false}' > "$f"
  _box_has_live_agent() { return 0; }   # another session's claude is live

  run exec_claude "test-ctr" --dangerously-skip-permissions

  run jq -r '.hasCompletedOnboarding' "$f"
  assert_output "false"
}

@test "attach heal: a failed rebuild never truncates the live file" {
  _RESOLVED_PROJECT="$TEST_TEMP/project"
  mkdir -p "$_RESOLVED_PROJECT"
  local key
  key="$(_derive_project_session_key "$_RESOLVED_PROJECT" "main")"
  mkdir -p "$CLEAT_PROJECTS_DIR/$key"
  local f="$CLEAT_PROJECTS_DIR/$key/claude.json"
  echo '{"hasCompletedOnboarding":false,"projects":{"/workspace":{"x":1}}}' > "$f"
  _box_has_live_agent() { return 1; }
  _build_project_claude_json() { echo '{}' > "$1"; }   # simulate a failed merge

  run exec_claude "test-ctr" --dangerously-skip-permissions

  run jq -r '.projects."/workspace".x' "$f"
  assert_output "1"
}

@test "attach heal: a healthy file costs no docker probe" {
  _RESOLVED_PROJECT="$TEST_TEMP/project"
  mkdir -p "$_RESOLVED_PROJECT"
  local key
  key="$(_derive_project_session_key "$_RESOLVED_PROJECT" "main")"
  mkdir -p "$CLEAT_PROJECTS_DIR/$key"
  echo '{"hasCompletedOnboarding":true,"oauthAccount":{"emailAddress":"a@b.c"}}' > "$CLEAT_PROJECTS_DIR/$key/claude.json"
  _box_has_live_agent() { touch "$TEST_TEMP/probed"; return 0; }

  run exec_claude "test-ctr" --dangerously-skip-permissions

  [ ! -f "$TEST_TEMP/probed" ] || { echo "a healthy file still hit docker top on attach"; return 1; }
}

@test "attach heal: an onboarded API-key box (no oauthAccount) short-circuits, no probe" {
  # An ANTHROPIC_API_KEY user never has an oauthAccount, but is onboarded and
  # shows no login screen. The gate keys on hasCompletedOnboarding alone, so
  # this box must NOT run the pipeline (and its box-only state stays untouched)
  # on every attach. Gating on oauthAccount here was the wipe bug.
  _RESOLVED_PROJECT="$TEST_TEMP/project"
  mkdir -p "$_RESOLVED_PROJECT"
  local key
  key="$(_derive_project_session_key "$_RESOLVED_PROJECT" "main")"
  mkdir -p "$CLEAT_PROJECTS_DIR/$key"
  echo '{"hasCompletedOnboarding":true,"mcpServers":{"foo":{"cmd":"x"}}}' > "$CLEAT_PROJECTS_DIR/$key/claude.json"
  _box_has_live_agent() { touch "$TEST_TEMP/probed"; return 0; }

  run exec_claude "test-ctr" --dangerously-skip-permissions

  [ ! -f "$TEST_TEMP/probed" ] || { echo "onboarded API-key box hit docker top on attach"; return 1; }
}

@test "attach heal: healing a poisoned box preserves box-only top-level state (mcpServers)" {
  # The confirmed review finding: a logout-poisoned box (onboarding false) that
  # also carries user-scoped mcpServers must be healed WITHOUT dropping the
  # mcpServers. A host-as-base rebuild wiped them; the proj-then-host base keeps
  # them.
  _RESOLVED_PROJECT="$TEST_TEMP/project"
  mkdir -p "$_RESOLVED_PROJECT"
  local key
  key="$(_derive_project_session_key "$_RESOLVED_PROJECT" "main")"
  mkdir -p "$CLEAT_PROJECTS_DIR/$key"
  local f="$CLEAT_PROJECTS_DIR/$key/claude.json"
  echo '{"hasCompletedOnboarding":false,"mcpServers":{"foo":{"command":"run-foo"}}}' > "$f"
  rm -f "${HOME}/.claude.json"   # host has no mcpServers to restore from
  _box_has_live_agent() { return 1; }

  run exec_claude "test-ctr" --dangerously-skip-permissions

  run jq -r '.hasCompletedOnboarding' "$f"
  assert_output "true"
  run jq -r '.mcpServers.foo.command' "$f"
  assert_output "run-foo"
}

@test "watcher log cap: drops a FIFO instead of leaving it for the redirect to block on" {
  local log="$TEST_TEMP/.watcher-log"
  mkfifo "$log"
  run _cap_watcher_log "$log"
  assert_success
  assert_output "0"
  [ ! -p "$log" ] || { echo "the FIFO survived, the next >> would block forever"; return 1; }
}
