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

@test "session end reports a refused harvest" {
  # A refusal printed nothing, so a login that was never saved read as saved.
  # That is how a Mac could run v1.5.0 for a week with an account the list kept
  # calling "signed out".
  mkdir -p "$CLEAT_ACCOUNTS_DIR/work" "$CLEAT_RUN_DIR/test-ctr/auth"
  printf '{"claudeAiOauth":{"accessToken":"at-A","refreshToken":"rt-A","expiresAt":1789028800000}}\n' \
    > "$CLEAT_RUN_DIR/test-ctr/auth/.credentials.json"
  _box_account_write test-ctr work
  _account_sync_out() { return 1; }
  run exec_claude "test-ctr" --dangerously-skip-permissions
  assert_success
  assert_output --partial "was not saved to"
  assert_output --partial "work"
  # A harvest that took says nothing.
  _account_sync_out() { return 0; }
  run exec_claude "test-ctr" --dangerously-skip-permissions
  assert_success
  refute_output --partial "was not saved to"
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

# ─────────────────────────────────────────────────────────────────────────────
# Live account switch: terminal 1's relaunch loop (M3, tests 51 to 67).
# Each drives the real loop through the docker stub's DOCKER_STUB_EXEC_SCRIPT,
# which returns a chosen exit code per exec and can leave a handoff ticket, so
# the reopen path runs end to end with no daemon. See concept/44.
# ─────────────────────────────────────────────────────────────────────────────

# Write the per-exec fixture script the stub runs. It logs each exec's argv,
# extracts CLEAT_EXEC_ID from the argv, optionally writes a ticket (ready|req)
# and exits the code from the plan (line N controls exec N).
rl_exec_script() {
  cat > "$TEST_TEMP/exec.sh" <<'SH'
#!/usr/bin/env bash
# Only the claude session exec matters here (it runs the clip-daemon wrapper).
# Every other docker exec (the coder-remap probe, the docker-access check) is a
# no-op exit 0, exactly as the plain stub would answer it.
flat="$(printf '%s ' "$@" | tr '\n' ' ')"
case "$flat" in *clip-daemon*) : ;; *) exit 0 ;; esac
n=$(cat "$HB_EXEC_COUNT" 2>/dev/null || echo 0); n=$((n+1)); printf '%s' "$n" > "$HB_EXEC_COUNT"
printf '%s\n' "$flat" >> "$HB_EXEC_ARGV"
id=""
for a in "$@"; do case "$a" in CLEAT_EXEC_ID=*) id="${a#CLEAT_EXEC_ID=}";; esac; done
printf '%s\n' "$id" >> "$HB_EXEC_IDS"
line=$(sed -n "${n}p" "$HB_PLAN" 2>/dev/null)
set -- $line
code="${1:-0}"; action="${2:-}"; byval="${3:-$HB_TICKET_BY}"
st=""
case "$action" in ready) st=ready ;; req) st=requested ;; esac
if [ -n "$st" ] && [ -n "$id" ]; then
  { printf 'v=1\n'; printf 'state=%s\n' "$st"; printf 'by=%s\n' "$byval"; \
    printf 'at=%s\n' "$(date +%s)"; printf 'sid=%s\n' "$HB_TICKET_SID"; \
    printf 'to=%s\n' "$HB_TICKET_TO"; } > "$HB_RUN_DIR/.handoff.$id"
fi
exit "$code"
SH
  chmod +x "$TEST_TEMP/exec.sh"
  export DOCKER_STUB_EXEC_SCRIPT="$TEST_TEMP/exec.sh"
}

# Common relaunch scaffolding: an interactive relaunchable session, a running
# box, a real transcript for the resume sid, and the fixture wired up.
rl_setup() {
  CN="cleat-rl-01"
  SID="d7b73579-1111-2222-3333-444455556666"
  _RESOLVED_PROJECT="$TEST_TEMP/proj"; _BOX=main
  mkdir -p "$_RESOLVED_PROJECT"
  SDIR="$(_sessions_key_dir "$_RESOLVED_PROJECT" main)"; mkdir -p "$SDIR"
  printf '{"type":"user","message":{"role":"user"},"parentUuid":null}\n' > "$SDIR/$SID.jsonl"
  HB_RUN_DIR="$CLEAT_RUN_DIR/$CN"; mkdir -p "$HB_RUN_DIR"
  export HB_EXEC_COUNT="$TEST_TEMP/ec" HB_EXEC_ARGV="$TEST_TEMP/eargv" HB_EXEC_IDS="$TEST_TEMP/eids"
  export HB_PLAN="$TEST_TEMP/plan" HB_RUN_DIR HB_TICKET_BY="$$" HB_TICKET_SID="$SID" HB_TICKET_TO="default"
  : > "$HB_EXEC_ARGV"; : > "$HB_EXEC_IDS"; rm -f "$HB_EXEC_COUNT"
  mock_docker_ps "$CN"
  _is_interactive() { return 0; }
  _account_sync_out() { echo "harvest" >> "$TEST_TEMP/order"; return 0; }
  rl_exec_script
}

# A pid that is certainly dead (spawned then reaped): a ticket writer that died.
rl_dead_pid() { local p; sleep 0.01 & p=$!; wait "$p" 2>/dev/null || true; echo "$p"; }

@test "relaunch with a ready ticket passes exactly the skip permissions flag and the resume id" {
  rl_setup
  printf '143 ready\n0\n' > "$HB_PLAN"
  run exec_claude "$CN" --dangerously-skip-permissions
  assert_success
  run cat "$HB_EXEC_COUNT"; assert_output "2"
  run sed -n '2p' "$TEST_TEMP/eargv"
  assert_output --partial "--dangerously-skip-permissions"
  assert_output --partial "--resume $SID"
  refute_output --partial "--continue"
}

@test "relaunch ignores a ready ticket when Claude exited on its own" {
  rl_setup
  # Exit 0 with a ready ticket present must NOT relaunch: only 143 does.
  printf '0 ready\n' > "$HB_PLAN"
  run exec_claude "$CN" --dangerously-skip-permissions
  assert_success
  run cat "$HB_EXEC_COUNT"; assert_output "1"
  refute_output --partial "--resume"
}

@test "relaunch does not reopen when the requested ticket writer died and still harvests" {
  rl_setup
  HB_TICKET_BY="$(rl_dead_pid)"
  _HANDOFF_T1_WAIT_S=1   # bound the wait when the dead-writer check is mutated out
  printf '143 req\n' > "$HB_PLAN"
  run exec_claude "$CN" --dangerously-skip-permissions
  assert_success
  # A dead writer ends the wait at once: no T0 waiting line, no relaunch. This
  # refute must sit right after the exec, before another run overwrites $output.
  refute_output --partial "switching this box to"
  run cat "$HB_EXEC_COUNT"; assert_output "1"
  run grep -c '^harvest' "$TEST_TEMP/order"
  assert_output "1"
}

@test "relaunch says it is waiting while the ticket reads requested" {
  rl_setup
  _HANDOFF_T1_WAIT_S=1
  _handoff_t1_pause() { sleep 0.2; }
  printf '143 req\n' > "$HB_PLAN"   # requested with a live writer ($$), never ready
  run exec_claude "$CN" --dangerously-skip-permissions
  assert_success
  # T0 prints exactly once across the whole wait.
  run grep -c "switching this box to" <<<"$output"
  assert_output "1"
}

@test "relaunch drains typeahead before the relaunch" {
  rl_setup
  _handoff_drain_typeahead() { echo drain >> "$TEST_TEMP/drain"; }
  printf '143 ready\n0\n' > "$HB_PLAN"
  run exec_claude "$CN" --dangerously-skip-permissions
  assert_success
  run cat "$TEST_TEMP/drain"; assert_output "drain"
}

@test "relaunch drops the store variable and its e flag as a pair" {
  source_cli
  CLAUDE_ENV=(-e HOME=/home/coder -e CLAUDE_SECURESTORAGE_CONFIG_DIR=/x -e PATH=/bin)
  _claude_env_drop_store
  run printf '%s\n' "${CLAUDE_ENV[*]}"
  assert_output "-e HOME=/home/coder -e PATH=/bin"
}

@test "relaunch runs the macOS seed only before a relaunch onto the shared login" {
  rl_setup
  _seed_macos_credentials() { echo seed >> "$TEST_TEMP/seed"; }
  _account_apply_exec_env() { :; }
  # A pinned box (store pin is a named account): the seed must NOT run.
  _claude_env_store_pin() { printf work; }
  printf '0\n' > "$HB_PLAN"
  run exec_claude "$CN" --dangerously-skip-permissions
  assert_success
  run test -f "$TEST_TEMP/seed"; assert_failure
  # The shared login (default pin): the seed runs.
  rm -f "$TEST_TEMP/seed"
  _claude_env_store_pin() { printf '%s' "$_ACCOUNT_DEFAULT"; }
  run exec_claude "$CN" --dangerously-skip-permissions
  assert_success
  run cat "$TEST_TEMP/seed"; assert_output "seed"
}

@test "relaunch keeps watchers across the relaunch and tears them down once at the end" {
  rl_setup
  printf '143 ready\n0\n' > "$HB_PLAN"
  run exec_claude "$CN" --dangerously-skip-permissions
  assert_success
  run cat "$HB_EXEC_COUNT"; assert_output "2"
  # The harvest (part of the single final teardown) runs exactly once, not per
  # iteration: the watchers stayed up across the relaunch.
  run grep -c '^harvest' "$TEST_TEMP/order"
  assert_output "1"
}

@test "relaunch hides code 143 only when a ticket explains it" {
  rl_setup
  # 143 with a ticket: reopen, clean end, no exit-code line.
  printf '143 ready\n0\n' > "$HB_PLAN"
  run exec_claude "$CN" --dangerously-skip-permissions
  assert_success
  refute_output --partial "exited with code 143"
  assert_output --partial "Session ended"
  # 143 with no ticket: reported as today.
  rm -f "$HB_EXEC_COUNT" "$HB_RUN_DIR"/.handoff.*
  printf '143\n' > "$HB_PLAN"
  run exec_claude "$CN" --dangerously-skip-permissions
  assert_output --partial "Claude exited with code 143"
}

@test "relaunch sets an exec id only for the fixed argument shapes on a terminal and after the user env args" {
  rl_setup
  _RESOLVED_ENV_ARGS=(-e FOO=bar)
  printf '0\n0\n0\n' > "$HB_PLAN"
  # Relaunchable + interactive: an exec id, placed AFTER the user env args.
  run exec_claude "$CN" --dangerously-skip-permissions
  run sed -n '1p' "$TEST_TEMP/eargv"
  assert_output --partial "CLEAT_EXEC_ID="
  local line; line="$(sed -n '1p' "$TEST_TEMP/eargv")"
  run bash -c '[[ "${1%%CLEAT_EXEC_ID*}" == *"FOO=bar"* ]]' _ "$line"
  assert_success
  # A non-relaunchable argv shape: no exec id.
  : > "$TEST_TEMP/eargv"; rm -f "$HB_EXEC_COUNT"
  run exec_claude "$CN" --dangerously-skip-permissions --verbose
  run sed -n '1p' "$TEST_TEMP/eargv"
  refute_output --partial "CLEAT_EXEC_ID="
  # Not a terminal: no exec id even for a relaunchable shape.
  : > "$TEST_TEMP/eargv"; rm -f "$HB_EXEC_COUNT"
  _is_interactive() { return 1; }
  run exec_claude "$CN" --dangerously-skip-permissions
  run sed -n '1p' "$TEST_TEMP/eargv"
  refute_output --partial "CLEAT_EXEC_ID="
}

@test "relaunch ends with the stopped waiting line on Ctrl C during the wait" {
  rl_setup
  HB_TICKET_TO="work"
  _HANDOFF_T1_WAIT_S=1
  _handoff_t1_pause() {
    if [[ ! -f "$TEST_TEMP/killed" ]]; then : > "$TEST_TEMP/killed"; sh -c 'kill -INT $PPID'; fi
    sleep 0.05
  }
  printf '143 req\n' > "$HB_PLAN"   # requested with a live writer, interrupted before ready
  run exec_claude "$CN" --dangerously-skip-permissions
  assert_output --partial "Stopped waiting for the account switch"
  run cat "$HB_EXEC_COUNT"; assert_output "1"
}

@test "relaunch restores the terminal before the final harvest" {
  rl_setup
  _restore_terminal() { echo restore >> "$TEST_TEMP/order2"; }
  _account_sync_out() { echo harvest >> "$TEST_TEMP/order2"; return 0; }
  printf '143 ready\n0\n' > "$HB_PLAN"
  run exec_claude "$CN" --dangerously-skip-permissions
  assert_success
  # The FINAL restore is the last one; the final harvest follows it.
  run bash -c 'tail -2 "$1"' _ "$TEST_TEMP/order2"
  assert_output "$(printf 'restore\nharvest')"
}

@test "relaunch suppresses the resume dialog on the reopen only" {
  rl_setup
  printf '143 ready\n0\n' > "$HB_PLAN"
  run exec_claude "$CN" --dangerously-skip-permissions
  assert_success
  # The reopen is transparent: no question in the way, so no hint to answer one.
  refute_output --partial "answer that before you type continue"
  # Line 1 is the original exec. An ordinary launch keeps Claude Code's own
  # resume behaviour, so neither threshold rides on it.
  run sed -n '1p' "$TEST_TEMP/eargv"
  refute_output --partial "CLAUDE_CODE_RESUME_THRESHOLD_MINUTES"
  refute_output --partial "CLAUDE_CODE_RESUME_TOKEN_THRESHOLD"
  # Line 2 is the reopen. Both thresholds, each of which suppresses the dialog
  # on its own, at values no real session reaches.
  run sed -n '2p' "$TEST_TEMP/eargv"
  assert_output --partial "CLAUDE_CODE_RESUME_THRESHOLD_MINUTES=$_HANDOFF_RESUME_THRESHOLD_MIN"
  assert_output --partial "CLAUDE_CODE_RESUME_TOKEN_THRESHOLD=$_HANDOFF_RESUME_TOKEN_THRESHOLD"
  run test "$_HANDOFF_RESUME_THRESHOLD_MIN" -ge 5256000
  assert_success
  run test "$_HANDOFF_RESUME_TOKEN_THRESHOLD" -ge 1000000000
  assert_success
}

@test "relaunch ignores its consumed ticket when the relaunched session returns" {
  rl_setup
  # Same by and at: the relaunch's exec returns 0, the ticket is consumed, one
  # relaunch only.
  printf '143 ready\n0\n' > "$HB_PLAN"
  run exec_claude "$CN" --dangerously-skip-permissions
  assert_success
  run cat "$HB_EXEC_COUNT"; assert_output "2"
  # A new pair (different by) written on the relaunch: a fresh switch, wait again.
  rm -f "$HB_EXEC_COUNT" "$HB_RUN_DIR"/.handoff.*
  printf '143 ready\n143 ready 99999\n0\n' > "$HB_PLAN"
  run exec_claude "$CN" --dangerously-skip-permissions
  assert_success
  run cat "$HB_EXEC_COUNT"; assert_output "3"
}

@test "relaunch names the account it landed on when the wait ends unfinished" {
  rl_setup
  HB_TICKET_BY="$(rl_dead_pid)"
  # to == the settled pin (both the shared login): T-landed.
  HB_TICKET_TO="default"
  printf '143 req\n' > "$HB_PLAN"
  run exec_claude "$CN" --dangerously-skip-permissions
  assert_output --partial "This conversation did not reopen"
  refute_output --partial "The account switch did not finish"
  # to != the settled pin: T-unfinished.
  rm -f "$HB_EXEC_COUNT" "$HB_RUN_DIR"/.handoff.*
  HB_TICKET_TO="work"
  run exec_claude "$CN" --dangerously-skip-permissions
  assert_output --partial "The account switch did not finish"
  refute_output --partial "This conversation did not reopen"
}

@test "relaunch ends with the box stopped line when the box is gone" {
  rl_setup
  is_running() { return 1; }
  printf '143 ready\n0\n' > "$HB_PLAN"
  run exec_claude "$CN" --dangerously-skip-permissions
  assert_output --partial "The box stopped during the account switch"
  run cat "$HB_EXEC_COUNT"; assert_output "1"
}

@test "the blank before claude survives a notice printed by the prepare" {
  # The hooks advisory was fixed first, but the account and identity lines
  # print INSIDE the relaunch loop, after that blank, so they became the last
  # line again and the clean-exit reclaim erased them. The invariant now sits
  # at the last moment before the exec.
  mkdir -p "$CLEAT_ACCOUNTS_DIR/work" "$CLEAT_RUN_DIR/test-ctr/auth"
  printf 'last_used\t1\n' > "$CLEAT_ACCOUNTS_DIR/work/meta"
  _box_account_write test-ctr work
  _account_box_ready() { return 1; }   # the box cannot use its account yet
  local LF=$'\n'
  run exec_claude "test-ctr" --dangerously-skip-permissions
  assert_success
  assert_output --partial "has no account mount"
  # A blank line separates that notice from the session output, so the reclaim
  # erases the blank and the notice stays in the scrollback.
  [[ "$output" == *"$LF$LF"* ]]
  local tail_after_blank="${output##*"$LF$LF"}"
  case "$tail_after_blank" in
    *"Session ended"*) : ;;
    *) printf 'no blank line before the session output\n' >&2; return 1 ;;
  esac
}
