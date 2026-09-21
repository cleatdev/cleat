#!/usr/bin/env bats
# ─────────────────────────────────────────────────────────────────────────────
# Integration: `cleat account` against REAL Docker.
#
# The unit suite proves the docker ARGUMENTS are right. Only this file can
# prove the three things the feature actually rests on:
#
#   1. the per-box auth directory is really mounted into a real container,
#   2. the credential staged on the host is really readable at that path
#      inside it, and
#   3. CLAUDE_SECURESTORAGE_CONFIG_DIR really relocates Claude Code's
#      credential store, in the bundled version, without moving
#      projectsDirectory.
#
# Point 3 is the load-bearing claim of concept/44 and it was previously
# verified only on the host. The var is UNDOCUMENTED, so a bundled-Claude bump
# can retire it silently: this file is what turns that into a red test rather
# than a user who cannot log in.
#
# NOT covered, and deliberately: a real `/login` into a relocated store. That
# needs an interactive browser and a real Anthropic account, so it stays a
# manual step on the Mac. Everything short of the browser is here.
#
# THESE CANNOT RUN FROM INSIDE A CLEAT BOX ON macOS, and that is structural
# rather than a bug here: the box's /tmp is not the Mac's, so every file bind
# under $TEST_TEMP becomes a directory and the container refuses to start. CI's
# test-integration job runs them on a Linux runner, which is where they are
# green. The load-bearing probe below was ALSO run by hand against a real
# running box on 2026-09-12 and is recorded in concept/44.
#
# Skipped if docker is unavailable.
# ─────────────────────────────────────────────────────────────────────────────

load "../setup"

setup_file() {
  if ! command -v docker &>/dev/null; then
    skip "docker not available"
  fi
  if ! docker info &>/dev/null; then
    skip "docker daemon not reachable"
  fi
  local repo_root _build_log
  repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  _build_log="$(docker build -q -t cleat -f "$repo_root/docker/Dockerfile" "$repo_root/docker/" 2>&1)" || {
    echo "# docker build failed, nothing below was tested:" >&3
    echo "$_build_log" | sed 's/^/#   /' >&3
    skip "could not build cleat image"
  }
}

# The PATH the CLI itself passes on every exec (CLAUDE_ENV). `runuser` resets
# the environment, so without this `claude` is simply not found and the probe
# below would "pass" by never running.
INT_BOX_PATH="/home/coder/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

setup() {
  _common_setup
  INT_PROJECT="$TEST_TEMP/int-account"
  mkdir -p "$INT_PROJECT"
  export XDG_CONFIG_HOME="$TEST_TEMP/xdg"
  mkdir -p "$XDG_CONFIG_HOME/cleat"
  INT_CNAME="cleat-intacct-$(date +%s)-$$"
  export INT_CNAME
}

teardown() {
  docker rm -f "$INT_CNAME" >/dev/null 2>&1 || true
  local default_name
  default_name="$(int_cname 2>/dev/null)"
  if [[ -n "$default_name" ]]; then
    docker ps -aq --filter "name=^${default_name}" 2>/dev/null | while read -r _c; do
      [[ -n "$_c" ]] && docker rm -f "$_c" >/dev/null 2>&1 || true
    done
  fi
  _common_teardown
}

@test "integration: the per-box auth directory is really mounted into the box" {
  # A missing bind SOURCE makes Docker create a DIRECTORY at the target, which
  # is the failure that once broke git host-wide, so this asserts the real
  # container's real mount table rather than the argument list.
  cd "$INT_PROJECT"
  run "$CLI" run
  assert_success
  local cname
  cname="$(int_cname)"
  run docker inspect "$cname" --format '{{range .Mounts}}{{.Destination}}{{"\n"}}{{end}}'
  assert_success
  assert_output --partial "/home/coder/.cleat-auth"
}

@test "integration: a credential staged on the host is readable at that path in the box" {
  cd "$INT_PROJECT"
  run "$CLI" account work-int
  assert_success
  local cname store
  cname="$(int_cname)"
  store="$XDG_CONFIG_HOME/cleat/accounts/work-int"
  [ -d "$store" ]
  printf '{"claudeAiOauth":{"accessToken":"int-access","refreshToken":"int-refresh","expiresAt":%s}}\n' \
    "$(( ($(date +%s) + 3600) * 1000 ))" > "$store/.credentials.json"
  chmod 600 "$store/.credentials.json"
  # Staging is what every attach does; do it directly so the test needs no TTY.
  run cli_call _account_sync_in "$cname"
  run "$CLI" run
  assert_success
  run docker exec "$cname" cat /home/coder/.cleat-auth/.credentials.json
  assert_success
  assert_output --partial "int-refresh"
}

@test "integration: the staged credential is not world-readable inside the box" {
  cd "$INT_PROJECT"
  run "$CLI" account work-int
  assert_success
  local cname store
  cname="$(int_cname)"
  store="$XDG_CONFIG_HOME/cleat/accounts/work-int"
  printf '{"claudeAiOauth":{"accessToken":"a","refreshToken":"r","expiresAt":%s}}\n' \
    "$(( ($(date +%s) + 3600) * 1000 ))" > "$store/.credentials.json"
  run cli_call _account_sync_in "$cname"
  run "$CLI" run
  assert_success
  run docker exec "$cname" stat -c '%a' /home/coder/.cleat-auth/.credentials.json
  assert_success
  assert_output "600"
}

@test "integration: CLAUDE_SECURESTORAGE_CONFIG_DIR relocates the store and nothing else" {
  # THE claim the whole feature rests on, checked in the real box against the
  # bundled Claude Code rather than against the host's. `auth status` is
  # read-only: it creates nothing and logs nobody in or out.
  cd "$INT_PROJECT"
  run "$CLI" run
  assert_success
  local cname
  cname="$(int_cname)"

  run docker exec "$cname" runuser -u coder -- \
    env PATH="$INT_BOX_PATH" CLAUDE_SECURESTORAGE_CONFIG_DIR=/tmp/int-probe-store \
    claude auth status --json
  # No assert_success: `auth status` exits 1 when it reads signed out, which is
  # exactly the state an empty relocated store creates, and newer Claude Code
  # is stricter about that than the version this was written against. What the
  # probe is for is the JSON below, not the exit code.
  [ "$status" -le 1 ] || { echo "auth status died: rc=$status"; echo "$output"; return 1; }
  # Relocated: an empty store reads as signed out...
  assert_output --partial '"loggedIn": false'
  # ...while the conversations do NOT move, which is the requirement.
  assert_output --partial '/home/coder/.claude/projects'
  refute_output --partial '/tmp/int-probe-store/projects'
}

@test "integration: a read of the relocated store creates nothing in it" {
  # If a mere read created the store, the box-predates-the-mount guard would
  # be pointless: /login would have somewhere to write either way.
  cd "$INT_PROJECT"
  run "$CLI" run
  assert_success
  local cname
  cname="$(int_cname)"
  run docker exec "$cname" runuser -u coder -- \
    env PATH="$INT_BOX_PATH" CLAUDE_SECURESTORAGE_CONFIG_DIR=/tmp/int-probe-empty \
    claude auth status --json
  # No assert_success: `auth status` exits 1 when it reads signed out, which is
  # exactly the state an empty relocated store creates, and newer Claude Code
  # is stricter about that than the version this was written against. What the
  # probe is for is the JSON below, not the exit code.
  [ "$status" -le 1 ] || { echo "auth status died: rc=$status"; echo "$output"; return 1; }
  run docker exec "$cname" sh -c 'ls -A /tmp/int-probe-empty 2>/dev/null | wc -l'
  assert_success
  assert_output "0"
}

@test "integration: CLAUDE_CONFIG_DIR is the wrong lever, and this proves why" {
  # concept/44 rejects it because it takes the conversations with it. That is
  # the one rejection a reader is most likely to second-guess, so it is
  # measured rather than asserted.
  cd "$INT_PROJECT"
  run "$CLI" run
  assert_success
  local cname
  cname="$(int_cname)"
  run docker exec "$cname" runuser -u coder -- \
    env PATH="$INT_BOX_PATH" CLAUDE_CONFIG_DIR=/tmp/int-cfg-probe \
    claude auth status --json
  # No assert_success: `auth status` exits 1 when it reads signed out, which is
  # exactly the state an empty relocated store creates, and newer Claude Code
  # is stricter about that than the version this was written against. What the
  # probe is for is the JSON below, not the exit code.
  [ "$status" -le 1 ] || { echo "auth status died: rc=$status"; echo "$output"; return 1; }
  assert_output --partial '/tmp/int-cfg-probe/projects'
}
