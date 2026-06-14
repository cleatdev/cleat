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

@test "session env: CLAUDE_ENV injects exactly HOME, DISABLE_AUTOUPDATER, PATH, TERM (+ COLORTERM when set)" {
  # CLAUDE_ENV is forced into every session (docker exec -it "${CLAUDE_ENV[@]}").
  # Pin the EXACT key set so a future addition — especially one templated from
  # host state (PATH=$PATH, LANG, USER) — can't silently leak the host's shell
  # environment into the sandbox. Presence-only checks wouldn't catch that.
  # TERM and COLORTERM are the two DELIBERATE host-templated entries: docker
  # exec -t doesn't propagate the terminal type, and a terminfo mismatch
  # corrupts key sequences and colors. COLORTERM is filtered here because it's
  # only present when the invoking environment has it.
  local keys="" e
  for e in "${CLAUDE_ENV[@]}"; do
    [[ "$e" == "-e" ]] && continue
    [[ "${e%%=*}" == "COLORTERM" ]] && continue
    keys+="${e%%=*}"$'\n'
  done
  local sorted
  sorted="$(printf '%s' "$keys" | sort | tr '\n' ' ' | sed 's/ *$//')"
  run echo "$sorted"
  assert_output "DISABLE_AUTOUPDATER HOME PATH TERM"
}

@test "session env: COLORTERM is forwarded only when the host sets it" {
  # CLAUDE_ENV is built at SOURCE time, so the conditional must be exercised
  # in a fresh subprocess — an in-process override can't reach it. Forwarding
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
