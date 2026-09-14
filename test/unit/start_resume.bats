#!/usr/bin/env bats
load "../setup"
setup() {
  _common_setup
  use_docker_stub
  source_cli
  _host_clip_cmd() { echo ""; }
  check_for_update() { true; }
  check_drift() { true; }
  _resolve_config_drift() { true; }
}
teardown() { _common_teardown; }

@test "start: full flow: builds, runs, execs with --dangerously-skip-permissions" {
  mkdir -p "$TEST_TEMP/project"
  run cmd_start "$TEST_TEMP/project"
  assert_success
  run docker_build_calls
  assert_output --partial "docker build"
  run docker_run_calls
  assert_output --partial "docker run"
  run assert_docker_exec_has "--dangerously-skip-permissions"
  assert_success
}

@test "start: restarts stopped container instead of creating new" {
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"
  is_running() { return 1; }  # container exists but NOT running
  mock_docker_ps_a "$cname"
  # Settings overlay must exist or stale-mount check triggers recreation
  mkdir -p "$CLEAT_RUN_DIR/${cname}/settings"
  echo '{}' > "$CLEAT_RUN_DIR/${cname}/settings/settings.json"

  run cmd_start "$TEST_TEMP/project"
  assert_output --partial "Container started"
  run docker_calls
  assert_output --partial "docker start $cname"
  rm -rf "$CLEAT_RUN_DIR/${cname}/settings"
}

@test "start: skips build when image exists" {
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project"
  run cmd_start "$TEST_TEMP/project"
  run docker_build_calls
  refute_output --partial "docker build"
}

@test "start: does not re-run if container already running" {
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"
  mock_docker_ps "$cname"
  mock_docker_ps_a "$cname"

  run cmd_start "$TEST_TEMP/project"
  run docker_run_calls
  refute_output --partial "docker run"
}

@test "resume: creates container when none exists and continues" {
  # Session files live on the host and survive cleat rm, so cleat resume
  # now auto-creates a fresh container instead of erroring out. Claude is
  # launched with --continue so the user picks up where they left off.
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"

  run cmd_resume "$TEST_TEMP/project"
  assert_success
  assert_output --partial "No container for this project. Creating fresh"
  # docker run was invoked (container creation happened).
  run grep "^docker run" "$DOCKER_CALLS"
  assert_success

  rm -rf "$CLEAT_RUN_DIR/${cname}/settings" "$CLEAT_RUN_DIR/${cname}/hooks"
}

@test "resume: restarts stopped container with --continue" {
  mkdir -p "$TEST_TEMP/project"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"
  is_running() { return 1; }  # container exists but NOT running
  mock_docker_ps_a "$cname"
  mkdir -p "$CLEAT_RUN_DIR/${cname}/settings"
  echo '{}' > "$CLEAT_RUN_DIR/${cname}/settings/settings.json"

  run cmd_resume "$TEST_TEMP/project"
  assert_output --partial "Session resumed"
  run assert_docker_exec_has "--continue"
  assert_success
  run assert_docker_exec_has "--dangerously-skip-permissions"
  assert_success
  rm -rf "$CLEAT_RUN_DIR/${cname}/settings"
}

@test "resume: folds an in-box login from another box into a stopped box (login once, every box)" {
  # cmd_resume must refresh the per-project claude.json before docker start,
  # exactly like cmd_start, so a login done in another box carries in on resume
  # too. Without the cmd_resume-side call this assertion fails while every other
  # test stays green (the cmd_start test cannot see a resume-only regression).
  mkdir -p "$TEST_TEMP/project"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"
  is_running() { return 1; }
  mock_docker_ps_a "$cname"
  mkdir -p "$CLEAT_RUN_DIR/${cname}/settings"
  echo '{}' > "$CLEAT_RUN_DIR/${cname}/settings/settings.json"
  rm -f "${HOME}/.claude.json"
  mkdir -p "$CLEAT_PROJECTS_DIR/box-login-elsewhere"
  echo '{"oauthAccount":{"emailAddress":"resume@login.dev"},"userID":"ur"}' > "$CLEAT_PROJECTS_DIR/box-login-elsewhere/claude.json"
  local key
  key="$(_derive_project_session_key "$TEST_TEMP/project" "main")"
  mkdir -p "$CLEAT_PROJECTS_DIR/$key"
  echo '{"projects":{}}' > "$CLEAT_PROJECTS_DIR/$key/claude.json"

  run cmd_resume "$TEST_TEMP/project"
  assert_output --partial "Session resumed"
  run jq -r '.oauthAccount.emailAddress' "$CLEAT_PROJECTS_DIR/$key/claude.json"
  assert_output "resume@login.dev"
  rm -rf "$CLEAT_RUN_DIR/${cname}/settings"
}

@test "resume: attaches to running container without restarting" {
  mkdir -p "$TEST_TEMP/project"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"
  mock_docker_ps "$cname"
  mock_docker_ps_a "$cname"

  run cmd_resume "$TEST_TEMP/project"
  run docker_calls
  refute_output --partial "docker start"
  run assert_docker_exec_has "--continue"
  assert_success
}

@test "start: docker start failure does not orphan spinner (set -e safe)" {
  # Regression test: when docker start fails under set -euo pipefail,
  # the spinner must be stopped and not left running in the background.
  # The actual binary runs with set -e (unlike sourced tests).
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"
  is_running() { return 1; }
  mock_docker_ps_a "$cname"
  mkdir -p "$CLEAT_RUN_DIR/${cname}/settings"
  echo '{}' > "$CLEAT_RUN_DIR/${cname}/settings/settings.json"
  export DOCKER_EXIT_CODE=1  # docker start will fail

  run cmd_start "$TEST_TEMP/project"
  assert_failure
  assert_output --partial "Container failed to start"
  rm -rf "$CLEAT_RUN_DIR/${cname}/settings"
}

@test "start: docker start failure shows docker error and recovery hint" {
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"
  is_running() { return 1; }
  mock_docker_ps_a "$cname"
  mkdir -p "$CLEAT_RUN_DIR/${cname}/settings"
  echo '{}' > "$CLEAT_RUN_DIR/${cname}/settings/settings.json"
  export DOCKER_EXIT_CODE=1
  export DOCKER_STDERR="Error response from daemon: network bridge not found"

  run cmd_start "$TEST_TEMP/project"
  assert_failure
  assert_output --partial "Container failed to start"
  assert_output --partial "network bridge not found"
  assert_output --partial "cleat rm"
  rm -rf "$CLEAT_RUN_DIR/${cname}/settings"
}

@test "resume: docker start failure shows helpful error with reason" {
  mkdir -p "$TEST_TEMP/project"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"
  is_running() { return 1; }
  mock_docker_ps_a "$cname"
  mkdir -p "$CLEAT_RUN_DIR/${cname}/settings"
  echo '{}' > "$CLEAT_RUN_DIR/${cname}/settings/settings.json"
  export DOCKER_EXIT_CODE=1
  export DOCKER_STDERR="Error response from daemon: OCI runtime create failed"

  run cmd_resume "$TEST_TEMP/project"
  assert_failure
  assert_output --partial "Container failed to start"
  assert_output --partial "OCI runtime create failed"
  assert_output --partial "cleat rm"
  rm -rf "$CLEAT_RUN_DIR/${cname}/settings"
}

@test "start: stale mounts auto-recreate container after reboot" {
  # After host reboot, /tmp is cleared: settings overlay dir is gone.
  # cmd_start should detect this and silently recreate instead of failing.
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"
  is_running() { return 1; }
  mock_docker_ps_a "$cname"
  # Do NOT create settings overlay dir, simulates post-reboot state

  run cmd_start "$TEST_TEMP/project"
  assert_success
  assert_output --partial "Recreating container"
  assert_output --partial "host paths changed"
  # Should have removed old container and created new one via docker run
  run docker_calls
  assert_output --partial "docker rm -f $cname"
  assert_output --partial "docker run"
  refute_output --partial "docker start $cname"
  rm -rf "$CLEAT_RUN_DIR/${cname}/settings" "$CLEAT_RUN_DIR/${cname}/clip"
}

@test "resume: stale mounts auto-recreate and continue (sessions live on host)" {
  # After paths rotate (reboot, partial /tmp cleanup, SSH-socket rotation),
  # resume can't docker-start the stale container, but sessions live on the
  # host, so it recreates transparently and continues with --continue instead
  # of erroring out and dead-ending the user.
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"
  is_running() { return 1; }
  mock_docker_ps_a "$cname"
  # Do NOT create settings overlay dir, simulates post-reboot state

  run cmd_resume "$TEST_TEMP/project"
  assert_success
  assert_output --partial "Recreating container"
  assert_output --partial "host paths changed"
  run docker_calls
  assert_output --partial "docker rm -f $cname"
  assert_output --partial "docker run"
  refute_output --partial "docker start $cname"
  run assert_docker_exec_has "--continue"
  assert_success
  rm -rf "$CLEAT_RUN_DIR/${cname}/settings" "$CLEAT_RUN_DIR/${cname}/clip"
}

# ── _container_bind_sources_present (vanished bind-source detection) ──────────
# Detects when a baked-in bind-mount source no longer exists on the host, so the
# caller can recreate instead of letting `docker start` abort with an opaque OCI
# "not a directory" error. The headline trigger is the macOS SSH agent socket,
# whose launchd path rotates on every reboot.

@test "bind-sources: present when every bind source exists on the host" {
  touch "$TEST_TEMP/sock"
  mock_docker_inspect "$(printf 'bind|%s\nbind|%s\n' "$TEST_TEMP" "$TEST_TEMP/sock")"
  run _container_bind_sources_present "cleat-x"
  assert_success
}

@test "bind-sources: stale when a bind source has vanished (rotated SSH socket)" {
  # The launchd SSH-agent socket dir is regenerated each reboot, so the recorded
  # source path no longer resolves on the host.
  mock_docker_inspect "$(printf 'bind|%s\nbind|%s\n' \
    "$TEST_TEMP" "$TEST_TEMP/run/com.apple.launchd.GONE/Listeners")"
  run _container_bind_sources_present "cleat-x"
  assert_failure
}

@test "bind-sources: ignores non-bind mounts (volumes/tmpfs have no host source)" {
  # A volume Source under docker's internal dir won't exist on the host, but a
  # non-bind mount must NEVER be treated as a vanished source.
  mock_docker_inspect "$(printf 'volume|%s\ntmpfs|\n' "/var/lib/docker/volumes/x/_data")"
  run _container_bind_sources_present "cleat-x"
  assert_success
}

@test "no arguments to main defaults to start" {
  mock_docker_images "cleat"
  run bash -c '
    export DOCKER_PS_OUTPUT="" DOCKER_PS_A_OUTPUT="" DOCKER_IMAGES_OUTPUT="cleat"
    export DOCKER_CALLS="'"$DOCKER_CALLS"'" PATH="'"$MOCK_BIN"':$PATH"
    source "'"$CLI"'"
    _host_clip_cmd() { echo ""; }
    check_for_update() { true; }
    check_drift() { true; }
    _resolve_config_drift() { true; }
    main
  '
  run docker_run_calls
  assert_output --partial "docker run"
}

# ── Resume target: conversation and model (B14) ─────────────────────────────

_rs_mine="11111111-1111-4111-8111-111111111111"
_rs_other="22222222-2222-4222-8222-222222222222"

# A minimal transcript in Claude Code 2.1.270's shape. $1 dir, $2 id, $3 the
# assistant model, $4 the cost-state usage key (what the run really ran).
_rs_conv() {
  mkdir -p "$1"
  printf '%s\n' \
    '{"parentUuid":null,"isSidechain":false,"type":"user","message":{"role":"user","content":"hi"},"uuid":"u1","timestamp":"2026-09-13T10:00:00.000Z","entrypoint":"cli","sessionId":"'"$2"'"}' \
    '{"parentUuid":"u1","isSidechain":false,"message":{"id":"m1","type":"message","role":"assistant","model":"'"$3"'","content":[{"type":"text","text":"ok"}]},"type":"assistant","uuid":"u2","timestamp":"2026-09-13T10:00:01.000Z","entrypoint":"cli","sessionId":"'"$2"'"}' \
    '{"type":"cost-state","sessionId":"'"$2"'","modelUsage":{"'"$4"'":{"inputTokens":1}}}' > "$1/$2.jsonl"
}

@test "resume: names the newest saved conversation instead of passing --continue" {
  mkdir -p "$TEST_TEMP/project"
  local cname sdir
  cname="$(container_name_for "$TEST_TEMP/project")"
  is_running() { return 1; }
  mock_docker_ps_a "$cname"
  mkdir -p "$CLEAT_RUN_DIR/${cname}/settings"
  echo '{}' > "$CLEAT_RUN_DIR/${cname}/settings/settings.json"
  sdir="$(_sessions_key_dir "$TEST_TEMP/project" main)"
  _rs_conv "$sdir" "$_rs_other" claude-sonnet-5 claude-sonnet-5
  touch -t 202601010000 "$sdir/$_rs_other.jsonl"
  _rs_conv "$sdir" "$_rs_mine" claude-sonnet-5 claude-sonnet-5

  run cmd_resume "$TEST_TEMP/project"
  assert_success
  run assert_docker_exec_has "--dangerously-skip-permissions --resume $_rs_mine"
  assert_success
  run grep -F -- "--continue" "$DOCKER_CALLS"
  assert_failure
}

@test "resume: starts a new conversation when the only one is open in another terminal" {
  mkdir -p "$TEST_TEMP/project"
  local cname sdir
  cname="$(container_name_for "$TEST_TEMP/project")"
  mock_docker_ps "$cname"
  mock_docker_ps_a "$cname"
  sdir="$(_sessions_key_dir "$TEST_TEMP/project" main)"
  _rs_conv "$sdir" "$_rs_other" claude-opus-5 "claude-opus-5[1m]"
  _box_live_session_ids() { printf '%s\n' "22222222-2222-4222-8222-222222222222"; }

  run cmd_resume "$TEST_TEMP/project"
  assert_success
  assert_output --partial "open in another terminal. Starting a new one."
  run grep -E -- "--continue|--resume" "$DOCKER_CALLS"
  assert_failure
}

@test "resume: a live session with no saved conversation keeps --continue and says nothing" {
  mkdir -p "$TEST_TEMP/project"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"
  mock_docker_ps "$cname"
  mock_docker_ps_a "$cname"
  _box_live_session_ids() { printf '%s\n' "22222222-2222-4222-8222-222222222222"; }

  run cmd_resume "$TEST_TEMP/project"
  assert_success
  refute_output --partial "open in another terminal"
  run assert_docker_exec_has "--dangerously-skip-permissions --continue"
  assert_success
}

@test "resume: a configured model suppresses the 1M carry (env pin or settings)" {
  # Claude Code loses [1m] only when no model is configured. With one configured,
  # its own restore is the user's choice (opusplan[1m] switches models by mode).
  mkdir -p "$TEST_TEMP/project/.claude"
  local cname sdir
  cname="$(container_name_for "$TEST_TEMP/project")"
  mock_docker_ps "$cname"
  mock_docker_ps_a "$cname"
  sdir="$(_sessions_key_dir "$TEST_TEMP/project" main)"
  _rs_conv "$sdir" "$_rs_mine" claude-opus-5 "claude-opus-5[1m]"

  _CLI_ENVS=("ANTHROPIC_MODEL=claude-sonnet-5")
  run cmd_resume "$TEST_TEMP/project"
  assert_success
  run assert_docker_exec_has "--resume $_rs_mine"
  assert_success
  run grep -F -- "--model" "$DOCKER_CALLS"
  assert_failure

  _CLI_ENVS=()
  : > "$DOCKER_CALLS"
  printf '{\n  "model" : "opusplan[1m]"\n}\n' > "$TEST_TEMP/project/.claude/settings.local.json"
  run cmd_resume "$TEST_TEMP/project"
  assert_success
  run assert_docker_exec_has "--resume $_rs_mine"
  assert_success
  run grep -F -- "--model" "$DOCKER_CALLS"
  assert_failure

  printf '{}' > "$TEST_TEMP/project/.claude/settings.local.json"
  : > "$DOCKER_CALLS"
  printf '{"env":{"ANTHROPIC_MODEL":"claude-sonnet-5"}}' > "$HOME/.claude/settings.json"
  run cmd_resume "$TEST_TEMP/project"
  assert_success
  run grep -F -- "--model" "$DOCKER_CALLS"
  assert_failure
}

@test "resume pick: skips a transcript with no conversation, a sidechain and a claude -p session" {
  local sdir="$TEST_TEMP/sessions" a b c
  _rs_conv "$sdir" "$_rs_mine" claude-opus-5 claude-opus-5
  touch -t 202601010000 "$sdir/$_rs_mine.jsonl"
  a="33333333-3333-4333-8333-333333333333"
  b="44444444-4444-4444-8444-444444444444"
  c="55555555-5555-4555-8555-555555555555"
  printf '%s\n' '{"type":"custom-title","customTitle":"x","sessionId":"'"$a"'"}' > "$sdir/$a.jsonl"
  printf '%s\n' '{"parentUuid":null,"isSidechain":true,"type":"user","sessionId":"'"$b"'"}' > "$sdir/$b.jsonl"
  printf '%s\n' '{"parentUuid":null,"isSidechain":false,"type":"user","entrypoint":"sdk-cli","sessionId":"'"$c"'"}' > "$sdir/$c.jsonl"

  run _resume_pick_session "$sdir" ""
  assert_success
  assert_output "$_rs_mine"
}

@test "resume pick: never follows a symlinked transcript or a non-session file" {
  local sdir="$TEST_TEMP/sessions" link="66666666-6666-4666-8666-666666666666"
  _rs_conv "$sdir" "$_rs_mine" claude-opus-5 claude-opus-5
  touch -t 202601010000 "$sdir/$_rs_mine.jsonl"
  _rs_conv "$TEST_TEMP/elsewhere" "$link" claude-opus-5 claude-opus-5
  ln -s "$TEST_TEMP/elsewhere/$link.jsonl" "$sdir/$link.jsonl"
  printf '%s\n' '{"parentUuid":null,"type":"user"}' > "$sdir/history.jsonl"

  run _resume_pick_session "$sdir" ""
  assert_output "$_rs_mine"
}

@test "resume carry: the 1M form only when the run recorded its usage under it" {
  local sdir="$TEST_TEMP/sessions"
  _rs_conv "$sdir" "$_rs_mine" claude-opus-5 "claude-opus-5[1m]"
  run _resume_model_carry "$sdir/$_rs_mine.jsonl"
  assert_output "claude-opus-5[1m]"

  # Switched to Sonnet mid-conversation: the last assistant model has no 1M record.
  _rs_conv "$sdir" "$_rs_other" claude-sonnet-5 "claude-opus-5[1m]"
  run _resume_model_carry "$sdir/$_rs_other.jsonl"
  assert_output ""
}

@test "resume carry: skips a synthetic error message and refuses a malformed model id" {
  local sdir="$TEST_TEMP/sessions"
  _rs_conv "$sdir" "$_rs_mine" claude-opus-5 "claude-opus-5[1m]"
  # A usage-limit reply is an assistant record with model <synthetic>.
  printf '%s\n' '{"parentUuid":"u2","isSidechain":false,"message":{"id":"x","type":"message","role":"assistant","model":"<synthetic>","content":[]},"type":"assistant","isApiErrorMessage":true}' >> "$sdir/$_rs_mine.jsonl"
  run _resume_model_carry "$sdir/$_rs_mine.jsonl"
  assert_output "claude-opus-5[1m]"

  _rs_conv "$sdir" "$_rs_other" 'claude-x;touch' 'claude-x;touch[1m]'
  run _resume_model_carry "$sdir/$_rs_other.jsonl"
  assert_output ""
}

@test "resume probe: reports only sessions whose process is alive with the recorded start time" {
  local d="$TEST_TEMP/sess" pr="$TEST_TEMP/proc"
  mkdir -p "$d" "$pr/101" "$pr/102" "$pr/104" "$pr/105"
  # Field 22 (starttime) is the 20th after "pid (comm) "; the comm holds ") ".
  printf '101 (cl) aude) S 1 1 1 0 -1 4194560 1 0 0 0 0 0 0 0 20 0 11 0 555 0\n' > "$pr/101/stat"
  printf '102 (claude) S 1 1 1 0 -1 4194560 1 0 0 0 0 0 0 0 20 0 11 0 555 0\n' > "$pr/102/stat"
  printf '104 (claude) S 1 1 1 0 -1 4194560 1 0 0 0 0 0 0 0 20 0 11 0 888 0\n' > "$pr/104/stat"
  printf '105 (claude) S 1 1 1 0 -1 4194560 1 0 0 0 0 0 0 0 20 0 11 0 999 0\n' > "$pr/105/stat"
  printf '{"pid":101,"sessionId":"%s","procStart":"555"}' "$_rs_mine" > "$d/101.json"
  # pid reused after a restart: the start time does not match
  printf '{"pid":102,"sessionId":"33333333-3333-4333-8333-333333333333","procStart":"777"}' > "$d/102.json"
  # left behind by a SIGKILL: no process at all
  printf '{"pid":103,"sessionId":"44444444-4444-4444-8444-444444444444","procStart":"1"}' > "$d/103.json"
  # pretty-printed is read the same
  printf '{\n  "pid": 104,\n  "sessionId": "%s",\n  "procStart": "888"\n}\n' "$_rs_other" > "$d/104.json"
  # a symlink is never read through
  printf '{"pid":105,"sessionId":"55555555-5555-4555-8555-555555555555","procStart":"999"}' > "$TEST_TEMP/target.json"
  ln -s "$TEST_TEMP/target.json" "$d/105.json"

  run sh -c "$_RESUME_LIVE_PROBE" _ "$d" "$pr"
  assert_success
  assert_output "$(printf '%s\n%s' "$_rs_mine" "$_rs_other")"
}

@test "resume probe: box output that is not a session id is dropped" {
  mkdir -p "$TEST_TEMP/fakebin"
  printf '#!/bin/sh\nprintf "%%s\\n" "not-a-uuid" "%s" "\\$(touch x)" ""\n' "$_rs_mine" > "$TEST_TEMP/fakebin/docker"
  chmod +x "$TEST_TEMP/fakebin/docker"
  PATH="$TEST_TEMP/fakebin:$PATH" run _box_live_session_ids cleat-x
  assert_success
  assert_output "$_rs_mine"
}
