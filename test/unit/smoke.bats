#!/usr/bin/env bats
# ─────────────────────────────────────────────────────────────────────────────
# REAL-BINARY SMOKE TESTS
#
# Every test here execs `bin/cleat` as a subprocess (never sourced). This
# means `set -euo pipefail` is active, and any unbound-variable / syntax /
# pipefail bug that would crash the real CLI is caught here.
#
# The sourced unit tests strip strict mode to coexist with bats' ERR trap.
# That makes them blind to bugs like:
#   - `echo $undefined_var` when `set -u` is active
#   - `docker ps | grep -q foo` where docker fails and pipefail propagates
#   - Syntax errors that only surface when the script is parsed fresh
#
# These smoke tests are the backstop. Every subcommand must have at least
# one test here that runs the real binary and verifies it exits cleanly.
# ─────────────────────────────────────────────────────────────────────────────

load "../setup"

setup() {
  _common_setup

  # Smoke tests exec bin/cleat directly, so we need a fully isolated HOME
  # that the CLI can write to without touching the real host.
  export HOME="$TEST_TEMP/home"
  mkdir -p "$HOME/.claude"

  # CLEAT_CONFIG_DIR is derived from XDG_CONFIG_HOME (or $HOME/.config) at the
  # top of bin/cleat. Force it into our temp dir via XDG_CONFIG_HOME.
  export XDG_CONFIG_HOME="$TEST_TEMP/xdg-config"
  export CLEAT_CONFIG_DIR="$XDG_CONFIG_HOME/cleat"
  mkdir -p "$CLEAT_CONFIG_DIR"

  # Docker stub goes first in PATH so cleat's `docker` calls are captured
  export PATH="$MOCK_BIN:$PATH"
}

# Compute the container name the same way cleat does (via container_name_for).
# We source the CLI in a subshell to call the function without polluting the
# smoke-test process (which must remain a real subprocess caller).
_compute_cname() {
  local project="$1"
  # Reimplement container_name_for inline rather than sourcing the entire CLI
  # (sourcing can fail on bash 3.2 due to strict-mode interactions).
  local dir_name hash
  dir_name="$(basename "$project" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g')"
  dir_name="${dir_name:0:48}"
  dir_name="${dir_name%-}"
  hash="$(echo -n "$project" | _md5 | head -c 8)"
  echo "cleat-${dir_name}-${hash}"
}

teardown() {
  _common_teardown
}

# Run cleat as a real subprocess. Signature: cleat_bin [ARGS...]
cleat_bin() {
  env \
    PATH="$MOCK_BIN:$PATH" \
    HOME="$HOME" \
    XDG_CONFIG_HOME="$XDG_CONFIG_HOME" \
    DOCKER_CALLS="$DOCKER_CALLS" \
    DOCKER_MOCK_DIR="$DOCKER_MOCK_DIR" \
    DOCKER_EXIT_CODE="${DOCKER_EXIT_CODE:-0}" \
    DOCKER_STDERR="${DOCKER_STDERR:-}" \
    "$CLI" "$@"
}

# Run cleat with a hard timeout (seconds). Used for subcommands that would
# otherwise block on interactive input. Uses _portable_timeout from setup.bash.
cleat_bin_timeout() {
  local secs="$1"; shift
  _portable_timeout "$secs" env \
    PATH="$MOCK_BIN:$PATH" \
    HOME="$HOME" \
    XDG_CONFIG_HOME="$XDG_CONFIG_HOME" \
    DOCKER_CALLS="$DOCKER_CALLS" \
    DOCKER_MOCK_DIR="$DOCKER_MOCK_DIR" \
    DOCKER_EXIT_CODE="${DOCKER_EXIT_CODE:-0}" \
    DOCKER_STDERR="${DOCKER_STDERR:-}" \
    "$CLI" "$@"
}

# Run an ARBITRARY cleat binary (a copy of it, or a symlink to one) as a real
# subprocess with the same isolated env cleat_bin uses. Lets a test exercise a
# different INSTALL SHAPE, e.g. a Homebrew keg, where the path the binary is
# reached through is the thing under test.
# Signature: cleat_bin_at PATH [ARGS...]
cleat_bin_at() {
  local bin="$1"; shift
  env \
    PATH="$MOCK_BIN:$PATH" \
    HOME="$HOME" \
    XDG_CONFIG_HOME="$XDG_CONFIG_HOME" \
    DOCKER_CALLS="$DOCKER_CALLS" \
    DOCKER_MOCK_DIR="$DOCKER_MOCK_DIR" \
    DOCKER_EXIT_CODE="${DOCKER_EXIT_CODE:-0}" \
    DOCKER_STDERR="${DOCKER_STDERR:-}" \
    "$bin" "$@"
}

# A PATH with every command except jq, for the real binary.
#
# The sourced tests hide jq with a `command` override, which a subprocess never
# sees, and dropping the directory jq lives in would take the coreutils beside
# it. So each PATH directory is mirrored as symlinks into one directory and the
# jq link is dropped. Prints the mirror, or nothing when it could not be built.
_smoke_nojq_path() {
  local farm="$TEST_TEMP/nojq-bin" d oldifs="$IFS"
  mkdir -p "$farm" || return 1
  IFS=:
  set -- $PATH
  IFS="$oldifs"
  for d in "$@"; do
    [ -d "$d" ] || continue
    ln -s "$d"/* "$farm"/ 2>/dev/null || true
  done
  rm -f "$farm/jq"
  [ -x "$farm/sed" ] && [ ! -e "$farm/jq" ] || return 1
  printf '%s' "$farm"
}

# ── Help and version ────────────────────────────────────────────────────────

@test "smoke: cleat --help exits 0 under strict mode" {
  run cleat_bin --help
  assert_success
  assert_output --partial "Cleat"
  refute_output --partial "unbound variable"
  refute_output --partial "command not found"
}

@test "smoke: cleat -h exits 0 under strict mode" {
  run cleat_bin -h
  assert_success
  assert_output --partial "Cleat"
}

@test "smoke: cleat help (subcommand form) exits 0" {
  run cleat_bin help
  assert_success
  assert_output --partial "Cleat"
}

@test "smoke: cleat --version exits 0 under strict mode" {
  run cleat_bin --version
  assert_success
  assert_output --partial "cleat"
}

@test "smoke: cleat -v exits 0" {
  run cleat_bin -v
  assert_success
  assert_output --partial "cleat"
}

@test "smoke: cleat version (subcommand form) exits 0" {
  run cleat_bin version
  assert_success
  assert_output --partial "cleat"
}

# ── cleat update on a Homebrew install ──────────────────────────────────────

@test "smoke: cleat update on a real Homebrew keg prints the brew command when brew is missing" {
  # Build the actual install shape a formula produces: the whole tree under
  # libexec inside the keg, the receipt at the keg root, and bin/cleat a
  # RELATIVE symlink into it. The binary is copied (not linked) because the
  # physical file has to live in the Cellar for the detector to be exercised
  # honestly. Then run it through the symlink, which is what a user's PATH
  # hits and what BASH_SOURCE reports.
  #
  # PATH is trimmed to the stub plus the system directories so this leg is the
  # brew-unreachable one on every host. Without that, the suite would find the
  # developer's real brew on a Mac and shell out to it.
  local keg="$TEST_TEMP/hb/Cellar/cleat/9.9.9"
  mkdir -p "$keg/libexec/bin" "$TEST_TEMP/hb/bin"
  cp "$CLI" "$keg/libexec/bin/cleat"
  echo '{}' > "$keg/INSTALL_RECEIPT.json"
  ln -s "../Cellar/cleat/9.9.9/libexec/bin/cleat" "$TEST_TEMP/hb/bin/cleat"

  run env PATH="$MOCK_BIN:/usr/bin:/bin" HOME="$HOME" \
    XDG_CONFIG_HOME="$XDG_CONFIG_HOME" DOCKER_CALLS="$DOCKER_CALLS" \
    DOCKER_MOCK_DIR="$DOCKER_MOCK_DIR" \
    "$TEST_TEMP/hb/bin/cleat" update
  assert_failure
  assert_output --partial "Installed via Homebrew"
  assert_output --partial "brew upgrade cleatdev/tap/cleat"
  # The generic no-git branch and its curl hint would wreck this install.
  refute_output --partial "not a git installation"
  refute_output --partial "install.sh"
  refute_output --partial "unbound variable"
  refute_output --partial "command not found"
  refute_output --partial "syntax error"
}

@test "smoke: cleat update hands a real Homebrew keg to brew" {
  # The delegation leg, end to end and under strict mode: the guard fires, the
  # process is REPLACED by brew, and nothing below the guard ever runs. A stub
  # brew ahead of everything on PATH stands in for the real one.
  local link stub="$TEST_TEMP/brewstub"
  link="$(_make_fake_keg "$TEST_TEMP/hb-delegate")"
  mkdir -p "$stub"
  cat > "$stub/brew" << 'BREWSTUB'
#!/usr/bin/env bash
echo "BREW $*"
BREWSTUB
  chmod +x "$stub/brew"

  run env PATH="$stub:$MOCK_BIN:/usr/bin:/bin" HOME="$HOME" \
    XDG_CONFIG_HOME="$XDG_CONFIG_HOME" DOCKER_CALLS="$DOCKER_CALLS" \
    DOCKER_MOCK_DIR="$DOCKER_MOCK_DIR" \
    "$link" update
  assert_success
  assert_output --partial "BREW upgrade cleatdev/tap/cleat"
  refute_output --partial "Checking for updates"
  refute_output --partial "not a git installation"
  refute_output --partial "unbound variable"
  refute_output --partial "command not found"
  refute_output --partial "syntax error"
}

# Builds the keg shape above and echoes the path of its bin symlink.
_make_fake_keg() {
  local root="${1:-$TEST_TEMP/hb}" keg
  keg="$root/Cellar/cleat/9.9.9"
  mkdir -p "$keg/libexec/bin" "$root/bin"
  cp "$CLI" "$keg/libexec/bin/cleat"
  echo '{}' > "$keg/INSTALL_RECEIPT.json"
  ln -s "../Cellar/cleat/9.9.9/libexec/bin/cleat" "$root/bin/cleat"
  printf '%s\n' "$root/bin/cleat"
}

# cmd_install and cmd_uninstall hardcode /usr/local/bin and shell out to ln, rm
# and sudo. These tests run the REAL binary, so if a guard ever regresses they
# would reach the developer's actual PATH symlink, and on an Intel Mac that
# directory is writable without sudo. Prepend recording stubs so the blast
# radius of a regression is a failed assertion instead of the maintainer's
# machine. Echoes the stub dir, for PATH.
_make_fs_stubs() {
  local d="$TEST_TEMP/fsstubs"
  mkdir -p "$d"
  local c
  for c in ln rm sudo; do
    cat > "$d/$c" << STUB
#!/usr/bin/env bash
echo "STUB-$c \$*"
STUB
    chmod +x "$d/$c"
  done
  printf '%s\n' "$d"
}

@test "smoke: cleat install refuses on a real Homebrew keg layout" {
  # The guard exits before the symlink work. The ln/rm/sudo stubs ahead of PATH
  # are what makes that safe to assert rather than assume: a reverted guard
  # records a STUB line instead of writing to the developer's /usr/local/bin.
  local link stubs
  link="$(_make_fake_keg)"
  stubs="$(_make_fs_stubs)"

  run env PATH="$stubs:$MOCK_BIN:$PATH" HOME="$HOME" \
    XDG_CONFIG_HOME="$XDG_CONFIG_HOME" DOCKER_CALLS="$DOCKER_CALLS" \
    DOCKER_MOCK_DIR="$DOCKER_MOCK_DIR" \
    "$link" install
  assert_failure
  assert_output --partial "Installed via Homebrew"
  assert_output --partial "brew upgrade cleatdev/tap/cleat"
  refute_output --partial "Installing CLI symlink"
  refute_output --partial "STUB-ln"
  refute_output --partial "STUB-sudo"
  refute_output --partial "unbound variable"
  refute_output --partial "command not found"
  refute_output --partial "syntax error"
}

@test "smoke: cleat uninstall refuses on a real Homebrew keg layout" {
  local link stubs
  link="$(_make_fake_keg)"
  stubs="$(_make_fs_stubs)"

  run env PATH="$stubs:$MOCK_BIN:$PATH" HOME="$HOME" \
    XDG_CONFIG_HOME="$XDG_CONFIG_HOME" DOCKER_CALLS="$DOCKER_CALLS" \
    DOCKER_MOCK_DIR="$DOCKER_MOCK_DIR" \
    "$link" uninstall
  assert_failure
  assert_output --partial "Installed via Homebrew"
  assert_output --partial "brew uninstall cleatdev/tap/cleat"
  refute_output --partial "Removing CLI symlinks"
  refute_output --partial "STUB-rm"
  refute_output --partial "STUB-sudo"
  refute_output --partial "unbound variable"
  refute_output --partial "command not found"
  refute_output --partial "syntax error"
}

# ── Release highlight (strict-mode body coverage) ────────────────────────────
# The sourced unit tests run with strict mode stripped, and the highlight is
# TTY-gated so a normal smoke subprocess returns before its body. Source the real
# binary in a subprocess under full `set -euo pipefail`, force the TTY path, and
# run the body, proving it's free of set -u / pipefail crashes on the real code.
@test "smoke: release highlight body is strict-mode (set -euo pipefail) safe" {
  local seen="$TEST_TEMP/.last_seen_version"
  run env HOME="$HOME" CLI="$CLI" RDIR="$TEST_TEMP" SEEN="$seen" PATH="$MOCK_BIN:$PATH" \
    bash -uo pipefail -c '
      source "$CLI"
      REPO_DIR="$RDIR"
      LAST_SEEN_VERSION_FILE="$SEEN"
      RELEASE_HIGHLIGHT_VERSION="$VERSION"
      _is_tty() { return 0; }
      _maybe_show_release_highlight
    '
  assert_success
  assert_output --partial "New in v"
  [[ -f "$seen" ]]  || return 1
}

# TTY-gated like the highlight, so a normal start smoke returns before this body.
# Source the real binary under full strict mode, force the TTY path and a
# two-install scan, and run the notice body: proves it's free of set -u /
# pipefail crashes on the real code.
@test "smoke: multiple-install notice body is strict-mode (set -euo pipefail) safe" {
  run env HOME="$HOME" CLI="$CLI" PATH="$MOCK_BIN:$PATH" \
    bash -uo pipefail -c '
      source "$CLI"
      _is_tty() { return 0; }
      _resolve_physical_path() { echo /b/phys; }
      _find_cleat_installs() {
        printf "%s\t%s\n" /a/bin/cleat /a/Cellar/cleat
        printf "%s\t%s\n" /b/bin/cleat /b/phys
      }
      _maybe_warn_multiple_installs
    '
  assert_success
  assert_output --partial "installs found"
}

# ── Unknown command handling ────────────────────────────────────────────────

@test "smoke: cleat unknown-command exits 1 without unbound variable" {
  run cleat_bin nonsense-command
  assert_failure
  refute_output --partial "unbound variable"
  refute_output --partial "syntax error"
}

# ── Status ───────────────────────────────────────────────────────────────────

@test "smoke: cleat status with no container exits cleanly" {
  printf '' > "$DOCKER_MOCK_DIR/ps_output"
  printf '' > "$DOCKER_MOCK_DIR/ps_a_output"
  printf '' > "$DOCKER_MOCK_DIR/images_output"
  mkdir -p "$TEST_TEMP/project"
  run cleat_bin status "$TEST_TEMP/project"
  assert_success
  assert_output --partial "Project:"
  refute_output --partial "unbound variable"
}

@test "smoke: cleat status with running container exits cleanly" {
  mkdir -p "$TEST_TEMP/project"
  # container_name_for uses $(pwd)/basename; mock will match any name.
  local cname="cleat-project-12345678"
  printf '%s\n' "$cname" > "$DOCKER_MOCK_DIR/ps_output"
  printf '%s\n' "$cname" > "$DOCKER_MOCK_DIR/ps_a_output"
  printf '%s\n' "cleat" > "$DOCKER_MOCK_DIR/images_output"
  run cleat_bin status "$TEST_TEMP/project"
  assert_success
  refute_output --partial "unbound variable"
}

# ── ps ───────────────────────────────────────────────────────────────────────

@test "smoke: cleat ps with no containers exits cleanly" {
  printf '' > "$DOCKER_MOCK_DIR/ps_output"
  printf '' > "$DOCKER_MOCK_DIR/ps_a_output"
  run cleat_bin ps
  assert_success
  refute_output --partial "unbound variable"
}

@test "smoke: cleat storage with no boxes exits cleanly" {
  printf '' > "$DOCKER_MOCK_DIR/ps_output"
  printf '' > "$DOCKER_MOCK_DIR/ps_a_output"
  printf '' > "$DOCKER_MOCK_DIR/images_output"
  run cleat_bin storage
  assert_success
  refute_output --partial "unbound variable"
  assert_output --partial "Docker storage"
}

@test "smoke: cleat storage exits with a friendly error when the daemon is down" {
  export DOCKER_EXIT_CODE=1
  run cleat_bin storage
  refute_output --partial "unbound variable"
  assert_output --partial "not running"
}

@test "smoke: cleat clean with the daemon down removes no box state and says so" {
  # Every prune asks docker whether a box still exists, and a down daemon
  # answers no for every box.
  export DOCKER_EXIT_CODE=1
  mkdir -p "$CLEAT_CONFIG_DIR/run/cleat-live-aaaa1111/settings" "$CLEAT_CONFIG_DIR/boxes"
  printf 'a box that still exists\n' > "$CLEAT_CONFIG_DIR/boxes/cleat-live-aaaa1111"
  run cleat_bin clean
  assert_failure
  refute_output --partial "unbound variable"
  assert_output --partial "Docker is not running"
  run test -d "$CLEAT_CONFIG_DIR/run/cleat-live-aaaa1111/settings"
  assert_success
  run test -f "$CLEAT_CONFIG_DIR/boxes/cleat-live-aaaa1111"
  assert_success
}

@test "smoke: cleat session with no sessions exits cleanly and says where it looked" {
  run cleat_bin_timeout 10 session
  assert_success
  refute_output --partial "unbound variable"
  # The directory is the whole diagnostic: the key is hashed from the path as
  # typed, so a differently-cased cwd on a Mac reads as data loss without it.
  assert_output --partial "Looked in"
}

@test "smoke: cleat session still lists when the Docker daemon is down" {
  # Listing is pure host filesystem and `session` is deliberately absent from
  # the preflight allowlist, because reclaiming disk is exactly when a user is
  # likely to have Docker off.
  export DOCKER_EXIT_CODE=1
  run cleat_bin_timeout 10 session
  assert_success
  refute_output --partial "unbound variable"
  refute_output --partial "not running"
}

@test "smoke: cleat session rm with no id asks which one" {
  run cleat_bin_timeout 10 session rm
  assert_failure
  refute_output --partial "unbound variable"
  assert_output --partial "Which session"
}

@test "smoke: cleat session rm refuses a too-short id" {
  run cleat_bin_timeout 10 session rm dead
  assert_failure
  refute_output --partial "unbound variable"
  assert_output --partial "Too short"
}

@test "smoke: cleat session rm refuses a non-hex id" {
  run cleat_bin_timeout 10 session rm ../../etc/passwd
  assert_failure
  refute_output --partial "unbound variable"
  assert_output --partial "Not a session id"
}

@test "smoke: cleat session rm --yes trashes a box session's per-box session-env under strict mode" {
  # session-env joined the per-box private dirs, so the delete set gained a path
  # under the run dir. Run on the real binary, where set -u would catch a name
  # the sourced tests cannot see.
  mkdir -p "$TEST_TEMP/project"
  cd "$TEST_TEMP/project"
  printf '' > "$DOCKER_MOCK_DIR/ps_output"
  printf '' > "$DOCKER_MOCK_DIR/ps_a_output"
  local proj="$TEST_TEMP/project" uuid="0123abcd-1111-2222-3333-444455556666"
  local key cname sdir envdir
  key="project-$(echo -n "$proj" | _md5 | head -c 8)"
  cname="$(_compute_cname "$proj")"
  sdir="$HOME/.claude/projects/$key"
  envdir="$CLEAT_CONFIG_DIR/run/$cname/home/session-env/$uuid"
  mkdir -p "$sdir" "$envdir"
  printf '{"type":"user","message":{"role":"user","content":"hi"},"sessionId":"%s"}\n' "$uuid" > "$sdir/$uuid.jsonl"
  echo "box env" > "$envdir/sessionstart-hook-0.sh"
  run cleat_bin_timeout 10 session rm "$uuid" --yes
  refute_output --partial "unbound variable"
  assert_success
  [ ! -e "$envdir" ] || { echo "the per-box session-env survived: $output"; return 1; }
  [ ! -e "$sdir/$uuid.jsonl" ] || { echo "the transcript was not trashed: $output"; return 1; }
}

@test "smoke: cleat session refuses an unknown flag" {
  run cleat_bin_timeout 10 session --wat
  assert_failure
  refute_output --partial "unbound variable"
  assert_output --partial "Unknown flag"
}

@test "smoke: cleat session refuses a stray positional like every box-aware verb" {
  run cleat_bin_timeout 10 session main extra
  assert_failure
  refute_output --partial "unbound variable"
  assert_output --partial "Unexpected argument"
}

@test "smoke: cleat session rename needs a value for --title" {
  run cleat_bin_timeout 10 session rename deadbeef01 --title
  assert_failure
  refute_output --partial "unbound variable"
}

@test "smoke: cleat account with no accounts exits cleanly and says how to make one" {
  run cleat_bin_timeout 10 account
  assert_success
  assert_output --partial "cleat account"
}

@test "smoke: cleat account list survives strict mode" {
  run cleat_bin_timeout 10 account list
  assert_success
}

@test "smoke: cleat account still works when the Docker daemon is down" {
  # Deliberately absent from the preflight allowlist, for the same reason
  # `sessions` is: a store operation must not need a daemon.
  DOCKER_STUB_DAEMON_DOWN=1 run cleat_bin_timeout 10 account list
  assert_success
}

@test "smoke: cleat browser origins survives strict mode" {
  run cleat_bin_timeout 10 browser origins
  assert_success
  assert_output --partial "claude.ai"
}

@test "smoke: cleat browser allow writes an origin and refuses a bad one" {
  run cleat_bin_timeout 10 browser allow auth.example.com
  assert_success
  run cleat_bin_timeout 10 browser origins
  assert_output --partial "auth.example.com"
  run cleat_bin_timeout 10 browser allow "not a host"
  assert_failure
}

@test "smoke: cleat browser allow keeps earlier origins and origins splits without globbing" {
  # The real binary under set -euo pipefail: a second allow rewrites the section
  # the first one wrote, an upper-case scheme goes through the one entry parser,
  # a numeric loopback is refused, and CLEAT_BROWSER_ORIGINS is split with
  # globbing off from a folder where `*` would match a file.
  run cleat_bin_timeout 10 browser allow first.example.com
  assert_success
  run cleat_bin_timeout 10 browser allow HTTPS://second.example.com
  assert_success
  run cleat_bin_timeout 10 browser allow 2130706433
  assert_failure
  mkdir -p "$TEST_TEMP/globcwd"
  : > "$TEST_TEMP/globcwd/evil.example"
  cd "$TEST_TEMP/globcwd"
  CLEAT_BROWSER_ORIGINS="*" run cleat_bin_timeout 10 browser origins
  assert_success
  assert_output --partial "    first.example.com"
  assert_output --partial "    second.example.com"
  assert_output --partial "    claude.com"
  assert_output --partial "    platform.claude.com"
  refute_output --partial "evil.example"
}

@test "smoke: cleat browser needs no Docker daemon" {
  # A destination allowlist is host-side policy. It must answer with the daemon
  # down, for the same reason cleat session and cleat account do.
  DOCKER_STUB_DAEMON_DOWN=1 run cleat_bin_timeout 10 browser origins
  assert_success
}

@test "smoke: cleat browser rejects an unknown subcommand" {
  run cleat_bin_timeout 10 browser frobnicate
  assert_failure
}

@test "smoke: cleat account trash runs with nothing in it" {
  run cleat_bin_timeout 10 account trash
  assert_success
  assert_output --partial "trash"
}

@test "smoke: cleat account refuses a name that is not the box charset" {
  run cleat_bin_timeout 10 account "Bad Name"
  assert_failure
  assert_output --partial "Invalid account name"
}

@test "smoke: cleat account refuses an unknown flag" {
  run cleat_bin_timeout 10 account --wat
  assert_failure
}

@test "smoke: cleat account rename needs both names" {
  run cleat_bin_timeout 10 account rename only-one
  assert_failure
}

@test "smoke: cleat account switch drops a stored identity under strict mode" {
  # Strict-mode cover for the rc-3 plumbing: without the `local _id_rc=0` in
  # each branch, the real binary dies with "_id_rc: unbound variable".
  command -v jq >/dev/null || skip "needs jq"
  mkdir -p "$TEST_TEMP/proj"
  cd "$TEST_TEMP/proj"
  local project key f
  project="$(cli_call resolve_project "$TEST_TEMP/proj")"
  key="$(cli_call _derive_project_session_key "$project" main)"
  f="$CLEAT_CONFIG_DIR/projects/$key/claude.json"
  mkdir -p "${f%/*}"
  printf '{"oauthAccount":{"emailAddress":"x@example.com"},"userID":"abc"}\n' > "$f"
  DOCKER_STUB_DAEMON_DOWN=1 run cleat_bin_timeout 15 account work
  assert_success
  refute_output --partial "unbound variable"
  assert_output --partial "is now on account"
  run jq -r '.oauthAccount // "absent"' "$f"
  assert_output "absent"
  run jq -r '.userID' "$f"
  assert_output "abc"
}

@test "smoke: cleat account switch on a host with no jq flags the box for the next launch" {
  # The jq-less half of the identity drop. With the box down it cannot edit the
  # file at all, so it leaves a flag next to it and the next launch clears it
  # through the box own jq. All of that runs under set -euo pipefail here,
  # which is where the sourced tests are blind.
  command -v jq >/dev/null || skip "needs jq on the host to hide it from the binary"
  mkdir -p "$TEST_TEMP/proj"
  cd "$TEST_TEMP/proj"
  local project key f nojq
  project="$(cli_call resolve_project "$TEST_TEMP/proj")"
  key="$(cli_call _derive_project_session_key "$project" main)"
  f="$CLEAT_CONFIG_DIR/projects/$key/claude.json"
  mkdir -p "${f%/*}"
  printf '{"oauthAccount":{"emailAddress":"x@example.com"},"userID":"abc"}\n' > "$f"
  nojq="$(_smoke_nojq_path)" || skip "could not mirror PATH without jq"
  # The mirror goes to the BINARY only. Putting it on this shell PATH would
  # leave bats running commands out of a directory the teardown deletes.
  run _portable_timeout 15 env \
    PATH="$MOCK_BIN:$nojq" \
    HOME="$HOME" \
    XDG_CONFIG_HOME="$XDG_CONFIG_HOME" \
    DOCKER_CALLS="$DOCKER_CALLS" \
    DOCKER_MOCK_DIR="$DOCKER_MOCK_DIR" \
    DOCKER_EXIT_CODE="${DOCKER_EXIT_CODE:-0}" \
    DOCKER_STUB_DAEMON_DOWN=1 \
    "$CLI" account work
  assert_success
  refute_output --partial "unbound variable"
  assert_output --partial "is now on account"
  [ -e "${f}.identity-stale" ] || { echo "no flag was left for the next launch"; return 1; }
  # Nothing was written into the file itself: a hand-rolled JSON edit is what
  # the box own jq exists to avoid.
  run jq -r '.oauthAccount.emailAddress' "$f"
  assert_output "x@example.com"
}

@test "smoke: cleat account rm unpins a box and drops the name it carried" {
  # The remove reaches the file through the key the pin carries, so this runs
  # the whole pin-write, key-read and in-place edit under set -euo pipefail.
  command -v jq >/dev/null || skip "needs jq"
  mkdir -p "$TEST_TEMP/proj"
  cd "$TEST_TEMP/proj"
  run cleat_bin_timeout 15 account work
  assert_success
  local project key f
  project="$(cli_call resolve_project "$TEST_TEMP/proj")"
  key="$(cli_call _derive_project_session_key "$project" main)"
  f="$CLEAT_CONFIG_DIR/projects/$key/claude.json"
  mkdir -p "${f%/*}"
  printf '{"oauthAccount":{"emailAddress":"work@example.com"},"userID":"abc"}\n' > "$f"
  run cleat_bin_timeout 15 account rm work --yes
  assert_success
  refute_output --partial "unbound variable"
  run jq -r '.oauthAccount // "absent"' "$f"
  assert_output "absent"
}

@test "smoke: cleat account rm with no name asks which one" {
  run cleat_bin_timeout 10 account rm
  assert_failure
  assert_output --partial "Which account"
}

@test "smoke: cleat account refuses a stray positional like every box-aware verb" {
  run cleat_bin_timeout 10 account work main extra
  assert_failure
}

@test "smoke: cleat account takes over a lock a dead command left, then switches and renames under strict mode" {
  # The lock, its steal, the read-once snapshot, the harvest and the staging all
  # run under set -euo pipefail here. The sourced unit tests strip strict mode.
  local accts="$CLEAT_CONFIG_DIR/accounts" pins="$CLEAT_CONFIG_DIR/box-accounts"
  mkdir -p "$accts/old" "$accts/.lock"
  chmod 700 "$accts" "$accts/old"
  # Expired, so the usage poll stays offline.
  printf '{"claudeAiOauth":{"accessToken":"at-O1","refreshToken":"rt-O","expiresAt":1000,"subscriptionType":"max"}}\n' > "$accts/old/.credentials.json"
  printf 'host %s pid 2147483646 at %s\n' "${HOSTNAME:-unknown}" "$(date +%s)" > "$accts/.lock/owner"
  DOCKER_STUB_DAEMON_DOWN=1 run cleat_bin_timeout 15 account old
  assert_success
  refute_output --partial "unbound variable"
  run grep -rl "at-O1" "$CLEAT_CONFIG_DIR/run"
  assert_success
  DOCKER_STUB_DAEMON_DOWN=1 run cleat_bin_timeout 15 account new
  assert_success
  refute_output --partial "unbound variable"
  DOCKER_STUB_DAEMON_DOWN=1 run cleat_bin_timeout 15 account rename old older
  assert_success
  refute_output --partial "unbound variable"
  # Two lines now: the account, then the box's per-project key, which is how a
  # remove finds the claude.json of a box in another project.
  run cat "$pins"/*
  assert_line --index 0 "new"
  assert_line --index 1 --regexp '^[a-z0-9_-]+$'
  run test -e "$accts/.lock"
  assert_failure
  run test -d "$accts/older"
  assert_success
}

@test "smoke: cleat account default keeps a staged login its account does not have" {
  # The release, the snapshot, the hold and its notice run under set -euo
  # pipefail here. The staged login is a different one and not newer, which the
  # harvest declines.
  local accts="$CLEAT_CONFIG_DIR/accounts" pins="$CLEAT_CONFIG_DIR/box-accounts" f cn="" staged
  run cleat_bin_timeout 15 account work
  assert_success
  for f in "$pins"/*; do cn="${f##*/}"; done
  run test -n "$cn"
  assert_success
  # Expired both, so nothing reaches the network.
  printf '{"claudeAiOauth":{"accessToken":"at-W1","refreshToken":"rt-W","expiresAt":2000,"subscriptionType":"max"}}\n' > "$accts/work/.credentials.json"
  staged="$CLEAT_CONFIG_DIR/run/$cn/auth/.credentials.json"
  mkdir -p "${staged%/*}"
  printf '{"claudeAiOauth":{"accessToken":"at-B0","refreshToken":"rt-boxlogin","expiresAt":1000,"subscriptionType":"max"}}\n' > "$staged"
  run cleat_bin_timeout 15 account default
  assert_success
  refute_output --partial "unbound variable"
  assert_output --partial "Kept a login from"
  run test -e "$staged"
  assert_failure
  run grep -rl "rt-boxlogin" "$accts/.held"
  assert_success
  # Listed, then saved under a new name, in strict mode too.
  local d id=""
  for d in "$accts/.held"/*; do id="${d##*/}"; done
  run cleat_bin_timeout 15 account held
  assert_success
  refute_output --partial "unbound variable"
  assert_output --partial "$id"
  # Saved into the account the box is pinned to again. The box's staged copy of
  # the old login is released and dropped. The old login is held.
  run cleat_bin_timeout 15 account work
  assert_success
  run grep -c "rt-W" "$staged"
  assert_output "1"
  run cleat_bin_timeout 15 account adopt "$id" work
  assert_success
  refute_output --partial "unbound variable"
  run grep -c "rt-boxlogin" "$accts/work/.credentials.json"
  assert_output "1"
  run test -e "$staged"
  assert_failure
  # And the login it replaced, saved under a new name.
  id=""
  for d in "$accts/.held"/*; do id="${d##*/}"; done
  run cleat_bin_timeout 15 account adopt "$id" saved
  assert_success
  refute_output --partial "unbound variable"
  run grep -c "rt-W" "$accts/saved/.credentials.json"
  assert_output "1"
}

@test "smoke: cleat account moves a box between two named logins under strict mode" {
  # The forced staging, the key-scoped merge (the awk splitter) and the harvest's
  # projection into the store run under set -euo pipefail here. Both logins are
  # expired, so the usage poll stays offline.
  local accts="$CLEAT_CONFIG_DIR/accounts" pins="$CLEAT_CONFIG_DIR/box-accounts" a f cn="" staged
  mkdir -p "$accts"
  chmod 700 "$accts"
  for a in old new; do
    mkdir -p "$accts/$a"
    chmod 700 "$accts/$a"
    printf '{"claudeAiOauth":{"accessToken":"at-%s","refreshToken":"%s-rt","expiresAt":1000,"subscriptionType":"max"}}\n' \
      "$a" "$a" > "$accts/$a/.credentials.json"
  done
  DOCKER_STUB_DAEMON_DOWN=1 run cleat_bin_timeout 15 account old
  assert_success
  refute_output --partial "unbound variable"
  for f in "$pins"/*; do cn="${f##*/}"; done
  run test -n "$cn"
  assert_success
  staged="$CLEAT_CONFIG_DIR/run/$cn/auth/.credentials.json"
  # The box refreshed its login and signed into an MCP server of its own.
  printf '{"mcpOAuth":{"s|1":{"accessToken":"MCP-box","expiresAt":1500}},"claudeAiOauth":{"accessToken":"at-old2","refreshToken":"old-rt","expiresAt":2000,"subscriptionType":"max"}}\n' \
    > "$staged"
  DOCKER_STUB_DAEMON_DOWN=1 run cleat_bin_timeout 15 account new
  assert_success
  refute_output --partial "unbound variable"
  run cat "$staged"
  assert_output --partial "new-rt"
  assert_output --partial "MCP-box"
  refute_output --partial "old-rt"
  run cat "$accts/old/.credentials.json"
  assert_output --partial "at-old2"
  refute_output --partial "MCP-box"
}

@test "smoke: cleat account held runs with nothing held" {
  run cleat_bin_timeout 10 account held
  assert_success
  refute_output --partial "unbound variable"
  assert_output --partial "No held logins"
}

@test "smoke: cleat account adopt with no id asks which one" {
  run cleat_bin_timeout 10 account adopt
  assert_failure
  refute_output --partial "unbound variable"
  assert_output --partial "Which one"
}

# The renderer and the save, on the real binary. Both walk the held tree and
# the save then removes the entry it took, all of it under set -euo pipefail.
_smoke_plant_held() {
  local hdir="$CLEAT_CONFIG_DIR/accounts/.held" entry
  mkdir -p "$hdir"
  chmod 700 "$CLEAT_CONFIG_DIR/accounts" "$hdir"
  entry="$(mktemp -d "$hdir/$(date +%s)-XXXXXX")"
  chmod 700 "$entry"
  # Expired, so no path here reaches the network.
  printf '{"claudeAiOauth":{"accessToken":"at-H1","refreshToken":"rt-held","expiresAt":1000,"subscriptionType":"max"}}\n' \
    > "$entry/.credentials.json"
  chmod 600 "$entry/.credentials.json"
  printf 'acct\twork\nbox\tcleat-smoke-abcdef12\nreason\tunsaved\nuuid\t\nwho\theld@example.com\norg\t\n' \
    > "$entry/meta"
  chmod 600 "$entry/meta"
  HELD_ID="${entry##*/}"
}

@test "smoke: cleat account held describes a held login" {
  local HELD_ID=""
  _smoke_plant_held
  run cleat_bin_timeout 10 account held
  assert_success
  refute_output --partial "unbound variable"
  assert_output --partial "$HELD_ID"
  assert_output --partial "its account did not save it"
  assert_output --partial "held@example.com"
  assert_output --partial "cleat account adopt"
}

@test "smoke: cleat account adopt saves a held login as a new account" {
  local HELD_ID="" store mode
  _smoke_plant_held
  store="$CLEAT_CONFIG_DIR/accounts/saved/.credentials.json"
  run cleat_bin_timeout 15 account adopt "$HELD_ID" saved
  assert_success
  refute_output --partial "unbound variable"
  assert_output --partial "Saved held login"
  assert_output --partial "saved"
  run grep -c "rt-held" "$store"
  assert_output "1"
  mode="$(stat -c '%a' "$store" 2>/dev/null || stat -f '%Lp' "$store")"
  assert_equal "$mode" "600"
  # The entry it took is gone, and the list says so.
  run test -e "$CLEAT_CONFIG_DIR/accounts/.held/$HELD_ID"
  assert_failure
  run cleat_bin_timeout 10 account held
  assert_success
  assert_output --partial "No held logins"
  run cleat_bin_timeout 10 account list
  assert_success
  assert_output --partial "saved"
}

@test "smoke: cleat account holds a newer login the server says is another account's" {
  # The identity check (the scoped readers, the profile request through curl's
  # stdin config, the status line, the parse and the hold) runs under set -euo
  # pipefail here. curl is a stub on PATH that answers for another account.
  local accts="$CLEAT_CONFIG_DIR/accounts" pins="$CLEAT_CONFIG_DIR/box-accounts" f cn="" staged now d id=""
  run cleat_bin_timeout 15 account work
  assert_success
  for f in "$pins"/*; do cn="${f##*/}"; done
  run test -n "$cn"
  assert_success
  now="$(date +%s)"
  # The store's token has expired, so the list's usage poll stays offline.
  printf '{"claudeAiOauth":{"accessToken":"at-W1","refreshToken":"rt-W","expiresAt":%s,"subscriptionType":"max"}}\n' \
    "$(( (now - 60) * 1000 ))" > "$accts/work/.credentials.json"
  printf 'uuid\t11111111-aaaa-4aaa-8aaa-aaaaaaaaaaaa\nwho\twork@example.com\n' > "$accts/work/meta"
  staged="$CLEAT_CONFIG_DIR/run/$cn/auth/.credentials.json"
  mkdir -p "${staged%/*}"
  printf '{"claudeAiOauth":{"accessToken":"at-B1","refreshToken":"rt-B","expiresAt":%s,"subscriptionType":"max"}}\n' \
    "$(( (now + 3600) * 1000 ))" > "$staged"
  mkdir -p "$TEST_TEMP/curlbin"
  cat > "$TEST_TEMP/curlbin/curl" <<'CURL'
#!/bin/sh
cat > "${0%/*}/stdin"
printf '{\n  "account": {"uuid": "22222222-bbbb-4bbb-8bbb-bbbbbbbbbbbb", "email": "other@example.com"},\n  "organization": {"uuid": "org-2", "name": "Other Org", "cc_onboarding_flags": {}}\n}\n200'
CURL
  chmod +x "$TEST_TEMP/curlbin/curl"
  PATH="$TEST_TEMP/curlbin:$PATH" run cleat_bin_timeout 20 account list
  assert_success
  refute_output --partial "unbound variable"
  assert_output --partial "1 held login"
  run cat "$TEST_TEMP/curlbin/stdin"
  assert_output --partial "api/oauth/profile"
  run grep -c "rt-W" "$accts/work/.credentials.json"
  assert_output "1"
  for d in "$accts/.held"/*; do id="${d##*/}"; done
  run grep -c "rt-B" "$accts/.held/$id/.credentials.json"
  assert_output "1"
  run cleat_bin_timeout 15 account held
  assert_success
  refute_output --partial "unbound variable"
  assert_output --partial "other@example.com"
}

# The live gate reads `docker top` through the array-and-slice column reader,
# which only the real binary runs under `set -u`. A bare `${f[@]}` there would
# die with "unbound variable" on the first blank row.
@test "smoke: cleat account switches a box whose only leftover is a dev server" {
  mkdir -p "$TEST_TEMP/proj"
  cd "$TEST_TEMP/proj"
  local project cn
  project="$(cli_call resolve_project "$TEST_TEMP/proj")"
  cn="$(_compute_cname "$project")"
  mock_docker_ps "$cn"
  mock_docker_ps_a "$cn"
  mock_docker_inspect "/home/coder/.cleat-auth"
  mock_docker_top \
    'UID    PID   PPID  C  STIME  TTY  TIME      CMD' \
    'root   1     0     0  09:14  ?    00:00:00  /sbin/docker-init -- /entrypoint.sh bash' \
    '' \
    'claude 91    1     0  09:40  ?    00:00:04  node /workspace/node_modules/.bin/vite --host'
  run cleat_bin_timeout 15 account work
  assert_success
  refute_output --partial "unbound variable"
  refute_output --partial "live Claude session"
  assert_output --partial "is now on account"
}

@test "smoke: cleat account refuses a live box that has no account mount" {
  # No account mount: a switch cannot take effect, so a live session is refused
  # rather than handed over (the live switch needs the mount).
  mkdir -p "$TEST_TEMP/proj"
  cd "$TEST_TEMP/proj"
  local project cn
  project="$(cli_call resolve_project "$TEST_TEMP/proj")"
  cn="$(_compute_cname "$project")"
  mock_docker_ps "$cn"
  mock_docker_ps_a "$cn"
  mock_docker_top \
    'UID    PID   PPID  C  STIME  TTY   TIME      CMD' \
    'claude 91    1     0  09:40  pts/0 00:00:09  claude --dangerously-skip-permissions --continue'
  run cleat_bin_timeout 15 account work
  assert_failure
  refute_output --partial "unbound variable"
  assert_output --partial "has a live Claude session"
}

@test "smoke: cleat account hands a live mounted box to the switch and refuses safely on an unreadable probe" {
  # A running, mounted box with a live agent routes to the live switch. The
  # docker stub's exec is a no-op, so the probe reads nothing and the switch
  # refuses without crashing under strict mode.
  mkdir -p "$TEST_TEMP/proj"
  cd "$TEST_TEMP/proj"
  local project cn
  project="$(cli_call resolve_project "$TEST_TEMP/proj")"
  cn="$(_compute_cname "$project")"
  mock_docker_ps "$cn"
  mock_docker_ps_a "$cn"
  mock_docker_inspect "/home/coder/.cleat-auth"
  mock_docker_top \
    'UID    PID   PPID  C  STIME  TTY   TIME      CMD' \
    'claude 91    1     0  09:40  pts/0 00:00:09  claude --dangerously-skip-permissions --continue'
  run cleat_bin_timeout 15 account work
  assert_failure
  refute_output --partial "unbound variable"
  assert_output --partial "could not tell what the Claude session"
}

@test "smoke: cleat account rejects --now on a non-switch verb" {
  run cleat_bin_timeout 10 account list --now
  assert_failure
  refute_output --partial "unbound variable"
  assert_output --partial "--now only applies when switching a box"
}

@test "smoke: cleat account help names the live-switch flags" {
  run cleat_bin_timeout 10 account --help
  assert_success
  assert_output --partial "--now"
  assert_output --partial "restarts on it and reopens its conversation"
}

@test "smoke: cleat account appears in help" {
  run cleat_bin_timeout 10 help
  assert_success
  assert_output --partial "account"
}

@test "smoke: cleat session trash runs with nothing in it" {
  run cleat_bin_timeout 10 session trash
  assert_success
  assert_output --partial "trash"
}

@test "smoke: cleat session trash takes no id and refuses a stray positional" {
  run cleat_bin_timeout 10 session trash main extra
  assert_failure
}

@test "smoke: the plural and the short form still reach the session verb" {
  # Nothing has shipped under either name, so this is courtesy rather than
  # compatibility. `cleat sessions` is what fingers type.
  local alias
  for alias in sessions ses; do
    run cleat_bin_timeout 10 "$alias"
    assert_success
    assert_output --partial "Looked in"
  done
}

@test "smoke: cleat session appears in help under its singular name" {
  # `sessions` also appears in that same line as prose, so the assertion has to
  # be on the VERB column or it passes whatever the verb is called. The colour
  # escapes sit between the verb and its argument, hence the strip.
  run cleat_bin help
  assert_success
  local plain
  plain="$(printf '%s\n' "$output" | sed $'s/\033\\[[0-9;]*m//g')"
  [[ "$plain" == *"session [box]"* ]]
  [[ "$plain" != *"sessions [box]"* ]]
}

@test "smoke: CLEAT_NO_CLIPBOARD_IMAGE=1 start path does not crash" {
  printf '' > "$DOCKER_MOCK_DIR/ps_output"
  printf '' > "$DOCKER_MOCK_DIR/ps_a_output"
  printf '' > "$DOCKER_MOCK_DIR/images_output"
  export CLEAT_NO_CLIPBOARD_IMAGE=1
  run cleat_bin_timeout 5 status
  refute_output --partial "unbound variable"
  refute_output --partial "command not found"
}

@test "smoke: cleat prune --cache --yes runs non-interactively without crashing" {
  printf '' > "$DOCKER_MOCK_DIR/images_output"
  run cleat_bin prune --cache --yes
  assert_success
  refute_output --partial "unbound variable"
}

# ── config ──────────────────────────────────────────────────────────────────

@test "smoke: cleat config --list exits cleanly on fresh config" {
  run cleat_bin config --list
  assert_success
  refute_output --partial "unbound variable"
}

@test "smoke: cleat config --enable git persists to config file" {
  run cleat_bin config --enable git
  assert_success
  assert_output --partial "git"
  [[ -f "$CLEAT_CONFIG_DIR/config" ]] || {
    echo "config file not created"
    return 1
  }
  grep -q "^git$" "$CLEAT_CONFIG_DIR/config" || {
    echo "git cap not persisted"
    cat "$CLEAT_CONFIG_DIR/config"
    return 1
  }
}

@test "smoke: cleat config --enable gh persists to config file" {
  run cleat_bin config --enable gh
  assert_success
  assert_output --partial "gh"
  grep -q "^gh$" "$CLEAT_CONFIG_DIR/config" || {
    echo "gh cap not persisted"
    cat "$CLEAT_CONFIG_DIR/config"
    return 1
  }
}

@test "smoke: cleat config --enable docker persists to config file" {
  run cleat_bin config --enable docker
  assert_success
  assert_output --partial "docker"
  grep -q "^docker$" "$CLEAT_CONFIG_DIR/config" || {
    echo "docker cap not persisted"
    cat "$CLEAT_CONFIG_DIR/config"
    return 1
  }
}

@test "smoke: cleat config --list includes docker as a known cap" {
  run cleat_bin config --list
  assert_success
  assert_output --partial "docker"
}

@test "smoke: cleat config --list prints the Resources block cleanly" {
  run cleat_bin config --list
  assert_success
  assert_output --partial "Resources"
  refute_output --partial "unbound variable"
}

@test "smoke: cleat config --enable unsafe-rm persists to config file" {
  run cleat_bin config --enable unsafe-rm
  assert_success
  assert_output --partial "unsafe-rm"
  grep -q "^unsafe-rm$" "$CLEAT_CONFIG_DIR/config" || {
    echo "unsafe-rm cap not persisted"
    cat "$CLEAT_CONFIG_DIR/config"
    return 1
  }
}

@test "smoke: cleat --cap unsafe-rm is a valid capability (not rejected)" {
  printf '' > "$DOCKER_MOCK_DIR/ps_output"
  printf '' > "$DOCKER_MOCK_DIR/ps_a_output"
  printf '' > "$DOCKER_MOCK_DIR/images_output"
  mkdir -p "$TEST_TEMP/project"
  run cleat_bin --cap unsafe-rm status "$TEST_TEMP/project"
  assert_success
  refute_output --partial "Unknown capability"
  refute_output --partial "unbound variable"
}

@test "smoke: cleat config --memory persists to config file" {
  run cleat_bin config --memory 4g
  assert_success
  grep -q "^memory = 4g$" "$CLEAT_CONFIG_DIR/config" || {
    echo "memory not persisted"
    cat "$CLEAT_CONFIG_DIR/config"
    return 1
  }
}

@test "smoke: cleat config --cpus then --memory keeps both keys" {
  cleat_bin config --cpus 2 >/dev/null
  run cleat_bin config --memory 6g
  assert_success
  grep -q "^cpus = 2$" "$CLEAT_CONFIG_DIR/config" || { echo "cpus lost"; cat "$CLEAT_CONFIG_DIR/config"; return 1; }
  grep -q "^memory = 6g$" "$CLEAT_CONFIG_DIR/config" || { echo "memory missing"; cat "$CLEAT_CONFIG_DIR/config"; return 1; }
}

# A memory value above the old fixed 8g ceiling now reaches the VM-relative
# warning path (docker info reads, awk comparisons, the arithmetic tiers). Those
# are exactly the pipelines that abort a strict-mode binary on a no-match, so the
# real subprocess has to walk them.
@test "smoke: cleat config --memory above the project cap exits cleanly" {
  run cleat_bin config --memory 24g
  assert_success
  refute_output --partial "unbound variable"
  grep -q "^memory = 24g$" "$CLEAT_CONFIG_DIR/config" || {
    echo "memory not persisted"; cat "$CLEAT_CONFIG_DIR/config"; return 1; }
}

@test "smoke: cleat config --project --memory above the cap warns and still writes" {
  cd "$TEST_TEMP"
  run cleat_bin config --project --memory 32g
  assert_success
  refute_output --partial "unbound variable"
  assert_output --partial "caps memory at"
}

@test "smoke: cleat config --cpus above the core count exits cleanly" {
  run cleat_bin config --cpus 512
  assert_success
  refute_output --partial "unbound variable"
  grep -q "^cpus = 512$" "$CLEAT_CONFIG_DIR/config" || {
    echo "cpus not persisted"; cat "$CLEAT_CONFIG_DIR/config"; return 1; }
}

@test "smoke: cleat config --memory with a bad value exits 1" {
  run cleat_bin config --memory lots
  assert_failure
  assert_output --partial "Invalid memory value"
}

@test "smoke: cleat config with no flags and closed stdin exits, never hangs" {
  # Drives the interactive editor with no TTY (text fallback) and EOF stdin: it
  # must fail open and return, not spin on 'Unknown capability' forever.
  run cleat_bin_timeout 10 config < /dev/null
  assert_success
  assert_output --partial "Cancelled"
}

@test "smoke: cleat trust --list shows no projects initially" {
  run cleat_bin trust --list
  assert_success
  assert_output --partial "No trusted projects"
}

@test "smoke: cleat trust records a project's .cleat and --list shows it" {
  mkdir -p "$TEST_TEMP/proj"
  printf '[caps]\ngit\n' > "$TEST_TEMP/proj/.cleat"
  run cleat_bin trust "$TEST_TEMP/proj"
  assert_success
  assert_output --partial "Trusted"
  run cleat_bin trust --list
  assert_success
  assert_output --partial "$TEST_TEMP/proj"
}

@test "smoke: cleat untrust removes a project's trust entry" {
  mkdir -p "$TEST_TEMP/proj"
  printf '[caps]\ngit\n' > "$TEST_TEMP/proj/.cleat"
  cleat_bin trust "$TEST_TEMP/proj" >/dev/null
  run cleat_bin untrust "$TEST_TEMP/proj"
  assert_success
  assert_output --partial "Removed trust"
}

@test "smoke: cleat trust fails cleanly when .cleat is missing" {
  mkdir -p "$TEST_TEMP/proj"
  run cleat_bin trust "$TEST_TEMP/proj"
  assert_failure
  assert_output --partial "No .cleat file"
}

@test "smoke: cleat trust <box> records a per-box trust row" {
  mkdir -p "$TEST_TEMP/proj"
  printf '[caps]\ngit\n' > "$TEST_TEMP/proj/.cleat"
  printf '[box.web.caps]\ndocker\n'   >> "$TEST_TEMP/proj/.cleat"
  cd "$TEST_TEMP/proj"
  run cleat_bin trust web
  assert_success
  assert_output --partial "[web]"
  run cleat_bin trust --list
  assert_success
  assert_output --partial "[web]"
}

@test "smoke: cleat untrust <box> removes only that box, main survives" {
  mkdir -p "$TEST_TEMP/proj"
  printf '[caps]\ngit\n' > "$TEST_TEMP/proj/.cleat"
  printf '[box.web.caps]\ndocker\n'   >> "$TEST_TEMP/proj/.cleat"
  cd "$TEST_TEMP/proj"
  cleat_bin trust >/dev/null
  cleat_bin trust web >/dev/null
  run cleat_bin untrust web
  assert_success
  assert_output --partial "Removed trust"
  assert_output --partial "[web]"
  run cleat_bin trust --list
  assert_success
  # main survives (path present) and only the web row is gone (no [web] tag);
  # this fails a wrong impl that removed main and kept web.
  assert_output --partial "$TEST_TEMP/proj"
  refute_output --partial "[web]"
}

@test "smoke: cleat start with --trust-project auto-approves project .cleat" {
  mkdir -p "$TEST_TEMP/proj"
  printf '[caps]\nenv\n' > "$TEST_TEMP/proj/.cleat"
  printf '' > "$DOCKER_MOCK_DIR/ps_output"
  printf '' > "$DOCKER_MOCK_DIR/ps_a_output"
  printf 'cleat\n' > "$DOCKER_MOCK_DIR/images_output"
  # Override the auto-trust env var from setup so we genuinely test the flag.
  unset CLEAT_TRUST_PROJECT

  cd "$TEST_TEMP/proj"
  run cleat_bin_timeout 5 --trust-project start
  # env cap should be respected (env vars would flow into docker run when
  # .cleat.env exists; if not, no crash either way)
  refute_output --partial "Project .cleat skipped"
  refute_output --partial "unbound variable"
}

@test "smoke: cleat config --enable unknown-cap exits 1" {
  run cleat_bin config --enable totally-not-a-cap
  assert_failure
  refute_output --partial "unbound variable"
}

@test "smoke: cleat config --disable env is idempotent on fresh config" {
  run cleat_bin config --disable env
  assert_success
  refute_output --partial "unbound variable"
}

# ── rm / stop-all / clean / nuke (safe variants) ────────────────────────────

@test "smoke: cleat rm with no container exits cleanly" {
  printf '' > "$DOCKER_MOCK_DIR/ps_output"
  printf '' > "$DOCKER_MOCK_DIR/ps_a_output"
  mkdir -p "$TEST_TEMP/project"
  cd "$TEST_TEMP/project"
  run cleat_bin rm
  assert_success
  refute_output --partial "unbound variable"
}

@test "smoke: cleat stop-all with no containers exits cleanly" {
  printf '' > "$DOCKER_MOCK_DIR/ps_output"
  printf '' > "$DOCKER_MOCK_DIR/ps_a_output"
  run cleat_bin stop-all
  assert_success
  refute_output --partial "unbound variable"
}

# ── Argument parsing (global flags) ─────────────────────────────────────────

@test "smoke: cleat --cap git --help does not error on flag parsing" {
  run cleat_bin --cap git --help
  assert_success
  refute_output --partial "unbound variable"
}

@test "smoke: cleat --env KEY=VAL --help parses global flags cleanly" {
  run cleat_bin --env "FOO=bar" --help
  assert_success
  refute_output --partial "unbound variable"
}

@test "smoke: cleat --env-file /nonexistent --help does not crash on flag parsing" {
  # Flag parsing happens before the file is validated; --help short-circuits.
  run cleat_bin --env-file "$TEST_TEMP/noexist.env" --help
  assert_success
  refute_output --partial "unbound variable"
}

@test "smoke: cleat --cap without value exits 1 cleanly" {
  run cleat_bin --cap
  assert_failure
  refute_output --partial "unbound variable"
  assert_output --partial "Missing"
}

@test "smoke: cleat --env without value exits 1 cleanly" {
  run cleat_bin --env
  assert_failure
  refute_output --partial "unbound variable"
  assert_output --partial "Missing"
}

# ── start / run (main lifecycle) ────────────────────────────────────────────
# These exercise the full startup path, which is where strict-mode bugs
# are most likely to surface. Mock docker always succeeds.

@test "smoke: cleat start with fresh image path exits cleanly" {
  mkdir -p "$TEST_TEMP/project"
  printf '' > "$DOCKER_MOCK_DIR/ps_output"
  printf '' > "$DOCKER_MOCK_DIR/ps_a_output"
  printf 'cleat\n' > "$DOCKER_MOCK_DIR/images_output"

  # start → reaches exec_claude which would docker exec; our docker stub
  # accepts it. We use a short timeout via a wrapper so interactive bits
  # don't hang.
  cd "$TEST_TEMP/project"
  run cleat_bin_timeout 5 start
  # The test must either succeed or fail with a clear message. It must
  # NOT hang, and must NOT emit strict-mode errors.
  refute_output --partial "unbound variable"
  refute_output --partial "command not found"
  refute_output --partial "syntax error"
}

@test "smoke: cleat run into existing image exits cleanly" {
  mkdir -p "$TEST_TEMP/project"
  printf '' > "$DOCKER_MOCK_DIR/ps_output"
  printf '' > "$DOCKER_MOCK_DIR/ps_a_output"
  printf 'cleat\n' > "$DOCKER_MOCK_DIR/images_output"

  cd "$TEST_TEMP/project"
  run cleat_bin_timeout 5 run
  refute_output --partial "unbound variable"
  refute_output --partial "syntax error"
}

@test "smoke: cleat run builds isolated .claude.json from a valid host file (strict mode)" {
  mkdir -p "$TEST_TEMP/project"
  printf '' > "$DOCKER_MOCK_DIR/ps_output"
  printf '' > "$DOCKER_MOCK_DIR/ps_a_output"
  printf 'cleat\n' > "$DOCKER_MOCK_DIR/images_output"
  printf '{"oauthAccount":{"emailAddress":"a@b.com"},"projects":{"/workspace":{"hasTrustDialogAccepted":true}}}' > "$HOME/.claude.json"

  cd "$TEST_TEMP/project"
  run cleat_bin_timeout 5 run
  refute_output --partial "unbound variable"
  refute_output --partial "syntax error"
}

@test "smoke: cleat run survives a corrupt host .claude.json (strict mode)" {
  mkdir -p "$TEST_TEMP/project"
  printf '' > "$DOCKER_MOCK_DIR/ps_output"
  printf '' > "$DOCKER_MOCK_DIR/ps_a_output"
  printf 'cleat\n' > "$DOCKER_MOCK_DIR/images_output"
  printf '{"oauthAccount": {' > "$HOME/.claude.json"   # truncated / invalid

  cd "$TEST_TEMP/project"
  run cleat_bin_timeout 5 run
  refute_output --partial "unbound variable"
  refute_output --partial "syntax error"
  # The corruption is handled gracefully: host file backed up, not a crash.
  assert_output --partial "backed up to"
  [[ -f "$HOME/.claude.json.bak" ]]
}

@test "smoke: cleat run copies the user's rules into the box overlay and drops every link under strict mode" {
  # The instruction-surface pass-through runs cp, find and chmod on content the
  # user controls. Strict mode on the real binary is where a failing one would
  # take the whole launch down.
  mkdir -p "$TEST_TEMP/project" "$HOME/.claude/rules/lang" "$TEST_TEMP/outside"
  printf '' > "$DOCKER_MOCK_DIR/ps_output"
  printf '' > "$DOCKER_MOCK_DIR/ps_a_output"
  printf 'cleat\n' > "$DOCKER_MOCK_DIR/images_output"
  echo "Prefer small diffs." > "$HOME/.claude/rules/lang/style.md"
  echo "SECRET" > "$TEST_TEMP/outside/key"
  ln -s "$TEST_TEMP/outside/key" "$HOME/.claude/rules/key.md"
  mkfifo "$HOME/.claude/rules/pipe"
  printf '{"bindings":[]}\n' > "$HOME/.claude/keybindings.json"

  cd "$TEST_TEMP/project"
  run cleat_bin_timeout 10 run
  refute_output --partial "unbound variable"
  refute_output --partial "syntax error"
  local cname o
  cname="$(_compute_cname "$TEST_TEMP/project")"
  o="$CLEAT_CONFIG_DIR/run/$cname/home/instr"
  run cat "$o/rules/lang/style.md"
  assert_output "Prefer small diffs."
  run find "$o" ! -type d ! -type f
  assert_output ""
  grep -q ":/home/coder/.claude/rules:ro" "$DOCKER_CALLS"
}

@test "smoke: cleat run stops before docker run on a wrong-type instruction-surface target" {
  mkdir -p "$TEST_TEMP/project"
  printf '' > "$DOCKER_MOCK_DIR/ps_output"
  printf '' > "$DOCKER_MOCK_DIR/ps_a_output"
  printf 'cleat\n' > "$DOCKER_MOCK_DIR/images_output"
  mkdir -p "$HOME/.claude/daemon.json"

  cd "$TEST_TEMP/project"
  run cleat_bin_timeout 10 run
  assert_failure
  refute_output --partial "unbound variable"
  assert_output --partial "daemon.json is a directory"
  run grep -c "^docker run " "$DOCKER_CALLS"
  assert_output "0"
}

@test "smoke: cleat start names a host ~/.claude/.config.json under strict mode" {
  mkdir -p "$TEST_TEMP/project"
  printf '' > "$DOCKER_MOCK_DIR/ps_output"
  printf '' > "$DOCKER_MOCK_DIR/ps_a_output"
  printf 'cleat\n' > "$DOCKER_MOCK_DIR/images_output"
  printf '{"mcpServers":{}}\n' > "$HOME/.claude/.config.json"

  cd "$TEST_TEMP/project"
  run cleat_bin_timeout 10 start
  refute_output --partial "unbound variable"
  refute_output --partial "syntax error"
  assert_output --partial "~/.claude/.config.json"
}

@test "smoke: cleat start fails cleanly when docker run errors" {
  mkdir -p "$TEST_TEMP/project"
  printf '' > "$DOCKER_MOCK_DIR/ps_output"
  printf '' > "$DOCKER_MOCK_DIR/ps_a_output"
  printf 'cleat\n' > "$DOCKER_MOCK_DIR/images_output"
  export DOCKER_EXIT_CODE=125
  export DOCKER_STDERR="Error: something went wrong"

  cd "$TEST_TEMP/project"
  run cleat_bin_timeout 5 start
  refute_output --partial "unbound variable"
  refute_output --partial "syntax error"
  # Either the docker error surfaces, or a retry message: both OK
  [[ "$status" -ne 0 ]] || true
}

# ── Boxes: named per-project sandboxes (see concept/20-boxes.md) ────────────

@test "smoke: cleat start <box> creates a box-suffixed container" {
  mkdir -p "$TEST_TEMP/project"
  printf '' > "$DOCKER_MOCK_DIR/ps_output"
  printf '' > "$DOCKER_MOCK_DIR/ps_a_output"
  printf 'cleat\n' > "$DOCKER_MOCK_DIR/images_output"

  cd "$TEST_TEMP/project"
  run cleat_bin_timeout 5 start az
  refute_output --partial "unbound variable"
  refute_output --partial "syntax error"
  grep -qE 'cleat-project-[0-9a-f]{8}-az' "$DOCKER_CALLS" || {
    echo "expected an -az suffixed container in docker calls"
    grep '^docker run' "$DOCKER_CALLS"
    return 1
  }
}

@test "smoke: a path argument is rejected as an invalid box name" {
  mkdir -p "$TEST_TEMP/project"
  run cleat_bin start "$TEST_TEMP/project"
  assert_failure
  assert_output --partial "Invalid box name"
  refute_output --partial "unbound variable"
}

@test "smoke: cleat describe sets and shows a box description" {
  mkdir -p "$TEST_TEMP/project"
  cd "$TEST_TEMP/project"
  cleat_bin describe az "cloud box" >/dev/null
  run cleat_bin describe az
  assert_success
  assert_output --partial "cloud box"
  refute_output --partial "unbound variable"
}

# ── Kits ────────────────────────────────────────────────────────────────────

@test "smoke: bare cleat kit (non-TTY text picker) cancels cleanly on EOF" {
  mkdir -p "$TEST_TEMP/project"
  cd "$TEST_TEMP/project"
  run cleat_bin kit < /dev/null
  assert_success
  assert_output --partial "Cleat Kits"
  assert_output --partial "Cancelled"
  refute_output --partial "unbound variable"
}

@test "smoke: cleat kit text picker enables end to end under strict mode" {
  mkdir -p "$TEST_TEMP/project"
  cd "$TEST_TEMP/project"
  run cleat_bin kit <<< $'plan-big-execute-small\nworker=haiku\ndone'
  assert_success
  assert_output --partial "enabled for box"
  refute_output --partial "unbound variable"
  run cleat_bin kit list
  assert_success
  assert_output --partial "This project:"
}

@test "smoke: cleat kit picker 'done' with DEFAULT models survives strict mode (F35)" {
  # The exact input that once killed the real binary: enabling with both
  # models at the default drives _write_kits_to_file down the both-default
  # branch, whose trailing && list used to return 1 and abort under set -e.
  mkdir -p "$TEST_TEMP/project"
  cd "$TEST_TEMP/project"
  run cleat_bin kit <<< $'plan-big-execute-small\ndone'
  assert_success
  assert_output --partial "enabled for box"
  refute_output --partial "unbound variable"
}

@test "smoke: cleat kit list exits 0 and shows the library" {
  mkdir -p "$TEST_TEMP/project"
  cd "$TEST_TEMP/project"
  run cleat_bin kit list
  assert_success
  assert_output --partial "Cleat Kits"
  assert_output --partial "plan-big-execute-small"
  refute_output --partial "unbound variable"
}

@test "smoke: cleat kit show prints the kit contents" {
  mkdir -p "$TEST_TEMP/project"
  cd "$TEST_TEMP/project"
  run cleat_bin kit show plan-big-execute-small
  assert_success
  assert_output --partial "kit-worker.md"
  assert_output --partial "model: sonnet"
  refute_output --partial "unbound variable"
}

@test "smoke: cleat kit enable + kit list reflect the selection end to end" {
  mkdir -p "$TEST_TEMP/project"
  cd "$TEST_TEMP/project"
  run cleat_bin kit plan-big-execute-small <<< "y"
  assert_success
  assert_output --partial "enabled for box"
  run cleat_bin kit list
  assert_success
  assert_output --partial "This project:"
  refute_output --partial "unbound variable"
}

@test "smoke: cleat kit off with no selection exits 0" {
  mkdir -p "$TEST_TEMP/project"
  cd "$TEST_TEMP/project"
  run cleat_bin kit off
  assert_success
  assert_output --partial "No kit enabled"
  refute_output --partial "unbound variable"
}

@test "smoke: cleat kit rejects an unknown kit with exit 1" {
  mkdir -p "$TEST_TEMP/project"
  cd "$TEST_TEMP/project"
  run cleat_bin kit definitely-not-a-kit
  assert_failure
  assert_output --partial "Unknown kit"
  refute_output --partial "unbound variable"
}

@test "smoke: cleat kit --help exits 0" {
  run cleat_bin kit --help
  assert_success
  assert_output --partial "cleat kit <name> [box]"
  refute_output --partial "unbound variable"
}

@test "smoke: cleat status exits 0 even when the docker daemon is unavailable" {
  # Box discovery must not abort status under set -euo pipefail when docker errs
  # (regression guard for the bare command-substitution strict-mode crash).
  mkdir -p "$TEST_TEMP/project"
  export DOCKER_EXIT_CODE=1
  cd "$TEST_TEMP/project"
  run cleat_bin status
  assert_success
  # Autopilot's status honesty: a down daemon is named, not "not created".
  assert_output --partial "Docker isn't running"
  refute_output --partial "unbound variable"
}

# ── Docker autopilot ────────────────────────────────────────────────────────

@test "smoke: a session verb with the daemon down fails clean, no raw docker error" {
  mkdir -p "$TEST_TEMP/project"
  cd "$TEST_TEMP/project"
  export DOCKER_EXIT_CODE=1
  run cleat_bin start
  assert_failure
  assert_output --partial "Docker isn't running"
  # The remedy phrasing depends on what engine the real host detects:
  # a copy-pasteable command gets "Start it with:", an instruction-only
  # environment (e.g. a macOS runner with no Docker.app) gets "To fix:".
  # Both are the clean-failure contract this smoke test guards.
  assert_output --regexp "Start it with:|To fix:"
  refute_output --partial "unbound variable"
}

@test "smoke: a remote DOCKER_HOST is refused with a clear message" {
  mkdir -p "$TEST_TEMP/project"
  cd "$TEST_TEMP/project"
  export DOCKER_EXIT_CODE=1
  export DOCKER_HOST="tcp://ci-runner:2376"
  run cleat_bin start
  assert_failure
  assert_output --partial "Remote Docker daemon unreachable"
  unset DOCKER_HOST
}

@test "smoke: resume also autopilots a down daemon (F33: hook membership)" {
  mkdir -p "$TEST_TEMP/project"
  cd "$TEST_TEMP/project"
  export DOCKER_EXIT_CODE=1
  run cleat_bin resume
  assert_failure
  assert_output --partial "Docker isn't running"
  refute_output --partial "Cannot connect to the Docker daemon"
  refute_output --partial "unbound variable"
}

@test "smoke: shell also autopilots a down daemon (F33: hook membership)" {
  mkdir -p "$TEST_TEMP/project"
  cd "$TEST_TEMP/project"
  export DOCKER_EXIT_CODE=1
  run cleat_bin shell
  assert_failure
  assert_output --partial "Docker isn't running"
  refute_output --partial "unbound variable"
}

@test "smoke: autopilot is a no-op when the daemon is up (exit-code gate)" {
  # A session verb against an up daemon must never claim Docker is down. With
  # no container, `cleat claude` fails at require_running, NOT at autopilot;
  # a stderr-string-matching _daemon_up would misread the stub's silence as
  # down and flip this output.
  mkdir -p "$TEST_TEMP/project"
  cd "$TEST_TEMP/project"
  run cleat_bin claude
  assert_failure
  refute_output --partial "Docker isn't running"
  assert_output --partial "is not running"
}

@test "smoke: stop with the daemon down is not gated by autopilot" {
  mkdir -p "$TEST_TEMP/project"
  cd "$TEST_TEMP/project"
  export DOCKER_EXIT_CODE=1
  run cleat_bin stop
  assert_success
  refute_output --partial "Docker isn't running"
  refute_output --partial "unbound variable"
}

@test "smoke: a box-aware verb rejects a stray second positional" {
  mkdir -p "$TEST_TEMP/project"
  cd "$TEST_TEMP/project"
  run cleat_bin stop az dev
  assert_failure
  assert_output --partial "Unexpected argument"
  refute_output --partial "unbound variable"
}

# ── Env passthrough end-to-end ─────────────────────────────────────────────
# The real binary + docker stub: confirm env vars make it into the docker
# exec args. This is the test that would have caught v0.6.3 at smoke level.

@test "smoke: cleat --env KEY=VAL start passes to docker run" {
  mkdir -p "$TEST_TEMP/project"
  printf '' > "$DOCKER_MOCK_DIR/ps_output"
  printf '' > "$DOCKER_MOCK_DIR/ps_a_output"
  printf 'cleat\n' > "$DOCKER_MOCK_DIR/images_output"

  cd "$TEST_TEMP/project"
  run cleat_bin_timeout 5 --env "SMOKE_TEST_VAR=hello" start
  # Check the docker stub recorded our env var
  grep -q 'SMOKE_TEST_VAR=hello' "$DOCKER_CALLS" || {
    echo "SMOKE_TEST_VAR not passed to docker run"
    echo "Docker calls:"
    cat "$DOCKER_CALLS"
    return 1
  }
}

@test "smoke: .cleat.env in project dir is loaded when env cap active" {
  mkdir -p "$TEST_TEMP/project"
  cat > "$TEST_TEMP/project/.cleat.env" << 'EOF'
DATABASE_URL=postgres://smoke-test/db
EOF
  cat > "$TEST_TEMP/project/.cleat" << 'EOF'
[caps]
env
EOF
  printf '' > "$DOCKER_MOCK_DIR/ps_output"
  printf '' > "$DOCKER_MOCK_DIR/ps_a_output"
  printf 'cleat\n' > "$DOCKER_MOCK_DIR/images_output"

  cd "$TEST_TEMP/project"
  run cleat_bin_timeout 5 start
  grep -q 'DATABASE_URL=postgres://smoke-test/db' "$DOCKER_CALLS" || {
    echo "DATABASE_URL from .cleat.env not passed to docker run"
    cat "$DOCKER_CALLS"
    return 1
  }
}

@test "smoke: cleat shell with .cleat.env passes env to docker exec" {
  mkdir -p "$TEST_TEMP/project"
  cat > "$TEST_TEMP/project/.cleat.env" << 'EOF'
SHELL_TEST_VAR=shell-value
EOF
  cat > "$TEST_TEMP/project/.cleat" << 'EOF'
[caps]
env
EOF
  # Compute the exact cname cleat will look for so the mock ps can return it
  local cname
  cname="$(_compute_cname "$TEST_TEMP/project")"
  [[ -n "$cname" ]] || { echo "cname computation failed"; return 1; }
  printf '%s\n' "$cname" > "$DOCKER_MOCK_DIR/ps_output"
  printf '%s\n' "$cname" > "$DOCKER_MOCK_DIR/ps_a_output"

  cd "$TEST_TEMP/project"
  run cleat_bin_timeout 5 shell
  grep -q 'SHELL_TEST_VAR=shell-value' "$DOCKER_CALLS" || {
    echo "SHELL_TEST_VAR not in docker exec args"
    echo "Expected cname: $cname"
    echo "Status: $status"
    echo "Output: $output"
    echo "Docker calls:"
    cat "$DOCKER_CALLS"
    return 1
  }
}

@test "smoke: cleat start with gh cap mounts ~/.config/gh" {
  mkdir -p "$TEST_TEMP/project"
  mkdir -p "$HOME/.config/gh"
  cat > "$TEST_TEMP/project/.cleat" << 'EOF'
[caps]
gh
EOF
  printf '' > "$DOCKER_MOCK_DIR/ps_output"
  printf '' > "$DOCKER_MOCK_DIR/ps_a_output"
  printf 'cleat\n' > "$DOCKER_MOCK_DIR/images_output"

  cd "$TEST_TEMP/project"
  run cleat_bin_timeout 5 start
  grep -qF ".config/gh:/home/coder/.config/gh" "$DOCKER_CALLS" || {
    echo "gh config mount missing from docker run"
    cat "$DOCKER_CALLS"
    return 1
  }
}

@test "smoke: cleat start with docker cap mounts socket and host path" {
  mkdir -p "$TEST_TEMP/project"
  cat > "$TEST_TEMP/project/.cleat" << 'EOF'
[caps]
docker
EOF
  printf '' > "$DOCKER_MOCK_DIR/ps_output"
  printf '' > "$DOCKER_MOCK_DIR/ps_a_output"
  printf 'cleat\n' > "$DOCKER_MOCK_DIR/images_output"

  # The engine-aware cap binds the REAL socket and guards on it being live.
  # Provide a real live host socket via DOCKER_HOST so this passes
  # deterministically even on a runner without Docker (macOS CI has no
  # /var/run/docker.sock, so the guard would correctly skip the mount there).
  local fake_sock="$TEST_TEMP/docker.sock"
  python3 -c "import socket,sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])" "$fake_sock"
  export DOCKER_HOST="unix://$fake_sock"

  cd "$TEST_TEMP/project"
  run cleat_bin_timeout 5 start
  # Assert the DEST is bound (a socket is mounted). Source differs by daemon
  # location: host-local (Linux) binds $fake_sock; a VM-backed daemon (macOS
  # runner) binds the in-VM /var/run/docker.sock. Both end at :/var/run/docker.sock.
  grep -qF ":/var/run/docker.sock" "$DOCKER_CALLS" || {
    echo "docker socket mount missing from docker run"
    cat "$DOCKER_CALLS"
    return 1
  }
  grep -qF "$TEST_TEMP/project:$TEST_TEMP/project" "$DOCKER_CALLS" || {
    echo "host-path identity mount missing from docker run"
    cat "$DOCKER_CALLS"
    return 1
  }
  grep -qF "CLEAT_HOST_PROJECT=$TEST_TEMP/project" "$DOCKER_CALLS" || {
    echo "CLEAT_HOST_PROJECT env missing from docker run"
    cat "$DOCKER_CALLS"
    return 1
  }
}

@test "smoke: cleat --cap hooks start runs a host hook through a live bridge" {
  # The bridge is spawned in exec_claude, AFTER cmd_run has returned, and it was
  # handed cmd_run's `local _workspace`. Under the real binary's set -u the
  # backgrounded spawn died on "unbound variable" before its log redirect, so the
  # hooks cap forwarded nothing in every session while the sourced tests (strict
  # mode stripped) stayed green. Proven end to end: the docker stub plays the
  # box and appends Stop events until the user's host hook has run.
  command -v jq >/dev/null 2>&1 || skip "the bridge needs jq on the host"
  mkdir -p "$TEST_TEMP/project/sub/src"
  printf '' > "$DOCKER_MOCK_DIR/ps_output"
  printf '' > "$DOCKER_MOCK_DIR/ps_a_output"
  printf 'cleat\n' > "$DOCKER_MOCK_DIR/images_output"
  local got="$TEST_TEMP/hook_stdin"
  cat > "$HOME/.claude/settings.json" << EOF
{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"{ pwd -P; cat; } > $got.part && mv $got.part $got"}]}]}}
EOF
  # Only the claude launch is intercepted. The bound keeps a dead bridge a
  # failed assertion after ~15s, never a hung file.
  local stub="$TEST_TEMP/hookstub"
  mkdir -p "$stub"
  cat > "$stub/docker" << EOF
#!/usr/bin/env bash
case " \$* " in
  *" exec "*" runuser "*)
    i=0
    while [ ! -s "$got" ] && [ "\$i" -lt 60 ]; do
      for d in "$XDG_CONFIG_HOME"/cleat/run/*/hooks; do
        [ -d "\$d" ] && printf '%s\n' '{"hook_event_name":"Stop","cwd":"/workspace/sub","tool_input":{"path":"src"}}' >> "\$d/events.jsonl"
      done
      sleep 0.25
      i=\$((i + 1))
    done
    ;;
esac
exec "$MOCK_BIN/docker" "\$@"
EOF
  chmod +x "$stub/docker"

  cd "$TEST_TEMP/project"
  run _portable_timeout 30 env PATH="$stub:$MOCK_BIN:$PATH" HOME="$HOME" \
    XDG_CONFIG_HOME="$XDG_CONFIG_HOME" DOCKER_CALLS="$DOCKER_CALLS" \
    DOCKER_MOCK_DIR="$DOCKER_MOCK_DIR" DOCKER_EXIT_CODE=0 \
    "$CLI" --cap hooks start
  refute_output --partial "unbound variable"
  refute_output --partial "jq is not installed"
  [ -s "$got" ] || { echo "the host hook never ran, so the bridge was not alive"; echo "$output"; return 1; }
  # A session that runs a host hook says so, on the real start path (H4).
  assert_output --partial "Host hooks enabled. The box chooses when they run"
  # A plain box translates /workspace/sub to the project's own sub folder, keeps
  # the relative path it judged from there, and runs the hook in that folder.
  run cat "$got"
  assert_line --index 0 "$(cd -P "$TEST_TEMP/project/sub" && pwd -P)"
  assert_output --partial "\"cwd\":\"$TEST_TEMP/project/sub\""
  assert_output --partial '"path":"src"'
}

@test "smoke: a hooks session reports this box's dropped event and logs the one that ran" {
  # The per-box drop report, the bounded spool read and the run log all run on
  # the real start path, where set -u applies and the sourced suites cannot see
  # an unbound name. The stub box appends one event naming a host path outside
  # the workspace beside each Stop event, until the user's host hook has run.
  command -v jq >/dev/null 2>&1 || skip "the bridge needs jq on the host"
  mkdir -p "$TEST_TEMP/project"
  printf '' > "$DOCKER_MOCK_DIR/ps_output"
  printf '' > "$DOCKER_MOCK_DIR/ps_a_output"
  printf 'cleat\n' > "$DOCKER_MOCK_DIR/images_output"
  local got="$TEST_TEMP/hook_stdin"
  cat > "$HOME/.claude/settings.json" << EOF
{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"cat > $got.part && mv $got.part $got"}]}]}}
EOF
  local stub="$TEST_TEMP/hookstub"
  mkdir -p "$stub"
  cat > "$stub/docker" << EOF
#!/usr/bin/env bash
case " \$* " in
  *" exec "*" runuser "*)
    i=0
    while [ ! -s "$got" ] && [ "\$i" -lt 60 ]; do
      for d in "$XDG_CONFIG_HOME"/cleat/run/*/hooks; do
        [ -d "\$d" ] && printf '%s\n%s\n' '{"hook_event_name":"Stop","cwd":"/etc"}' \
          '{"hook_event_name":"Stop","cwd":"/workspace"}' >> "\$d/events.jsonl"
      done
      sleep 0.25
      i=\$((i + 1))
    done
    ;;
esac
exec "$MOCK_BIN/docker" "\$@"
EOF
  chmod +x "$stub/docker"

  cd "$TEST_TEMP/project"
  run _portable_timeout 30 env PATH="$stub:$MOCK_BIN:$PATH" HOME="$HOME" \
    XDG_CONFIG_HOME="$XDG_CONFIG_HOME" DOCKER_CALLS="$DOCKER_CALLS" \
    DOCKER_MOCK_DIR="$DOCKER_MOCK_DIR" DOCKER_EXIT_CODE=0 \
    "$CLI" --cap hooks start
  refute_output --partial "unbound variable"
  [ -s "$got" ] || { echo "the host hook never ran, so the bridge was not alive"; echo "$output"; return 1; }
  assert_output --partial "hook event"
  assert_output --partial "could not map to its own files"
  run grep -c "RAN-EVENT" "$XDG_CONFIG_HOME/cleat/state/hook-runs.log"
  assert_success
}

@test "smoke: a host hook still runs through a live bridge on a host with no timeout, gtimeout or perl" {
  # The hook is bounded through an argv prefix, and with none of the three the
  # prefix is an EMPTY array. bash 3.2 under set -u calls an empty "${a[@]}"
  # unbound, which would kill the bridge's hook run on exactly the host the
  # fallback exists for, while the sourced suites (strict mode stripped) stayed
  # green. The PATH here is the test's own with those three taken out.
  command -v jq >/dev/null 2>&1 || skip "the bridge needs jq on the host"
  mkdir -p "$TEST_TEMP/project"
  printf '' > "$DOCKER_MOCK_DIR/ps_output"
  printf '' > "$DOCKER_MOCK_DIR/ps_a_output"
  printf 'cleat\n' > "$DOCKER_MOCK_DIR/images_output"
  local farm="$TEST_TEMP/nobound" d
  mkdir -p "$farm"
  while IFS= read -r d; do
    [ -n "$d" ] && [ -d "$d" ] && [ "$d" != "$MOCK_BIN" ] || continue
    ln -s "$d"/* "$farm"/ 2>/dev/null || true
  done < <(printf '%s\n' "$PATH" | tr ':' '\n')
  rm -f "$farm/timeout" "$farm/gtimeout" "$farm/perl"
  local got="$TEST_TEMP/hook_stdin"
  cat > "$HOME/.claude/settings.json" << EOF
{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"cat > $got.part && mv $got.part $got"}]}]}}
EOF
  local stub="$TEST_TEMP/hookstub"
  mkdir -p "$stub"
  cat > "$stub/docker" << EOF
#!/usr/bin/env bash
case " \$* " in
  *" exec "*" runuser "*)
    i=0
    while [ ! -s "$got" ] && [ "\$i" -lt 60 ]; do
      for d in "$XDG_CONFIG_HOME"/cleat/run/*/hooks; do
        [ -d "\$d" ] && printf '%s\n' '{"hook_event_name":"Stop","cwd":"/workspace"}' >> "\$d/events.jsonl"
      done
      sleep 0.25
      i=\$((i + 1))
    done
    ;;
esac
exec "$MOCK_BIN/docker" "\$@"
EOF
  chmod +x "$stub/docker"

  cd "$TEST_TEMP/project"
  run _portable_timeout 30 env PATH="$stub:$MOCK_BIN:$farm" HOME="$HOME" \
    XDG_CONFIG_HOME="$XDG_CONFIG_HOME" DOCKER_CALLS="$DOCKER_CALLS" \
    DOCKER_MOCK_DIR="$DOCKER_MOCK_DIR" DOCKER_EXIT_CODE=0 \
    "$CLI" --cap hooks start
  refute_output --partial "unbound variable"
  [ -s "$got" ] || { echo "the host hook never ran, so the bridge was not alive"; echo "$output"; return 1; }
  run cat "$got"
  assert_output --partial '"hook_event_name":"Stop"'
}

@test "smoke: cleat start names a non-default browser bridge mode under strict mode" {
  # B7: the launch summary names the bridge mode when it is not auto. The row
  # reads CLEAT_BROWSER_BRIDGE on the real start path, where set -u applies.
  mkdir -p "$TEST_TEMP/project"
  printf '' > "$DOCKER_MOCK_DIR/ps_output"
  printf '' > "$DOCKER_MOCK_DIR/ps_a_output"
  printf 'cleat\n' > "$DOCKER_MOCK_DIR/images_output"
  cd "$TEST_TEMP/project"
  export CLEAT_BROWSER_BRIDGE=always
  run cleat_bin_timeout 5 start
  unset CLEAT_BROWSER_BRIDGE
  refute_output --partial "unbound variable"
  assert_output --partial "Browser:"
  assert_output --partial "destination check off"
}

# ── Config drift and version label ──────────────────────────────────────────

# ── Session isolation ──────────────────────────────────────────────────────

@test "smoke: cleat start mounts per-project session overlay" {
  mkdir -p "$TEST_TEMP/project"
  printf '' > "$DOCKER_MOCK_DIR/ps_output"
  printf '' > "$DOCKER_MOCK_DIR/ps_a_output"
  printf 'cleat\n' > "$DOCKER_MOCK_DIR/images_output"

  local _bn _h project_key
  _bn="$(basename "$TEST_TEMP/project" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g')"
  _h="$(echo -n "$TEST_TEMP/project" | _md5 | head -c 8)"
  project_key="${_bn}-${_h}"

  cd "$TEST_TEMP/project"
  run cleat_bin_timeout 5 start
  grep -q "projects/-workspace" "$DOCKER_CALLS" || {
    echo "Session overlay mount missing from docker run"
    cat "$DOCKER_CALLS"
    return 1
  }
  # Use -F for literal match (project_key starts with - which grep reads as a flag)
  grep -qF -- "${project_key}:/home/coder/.claude/projects/-workspace" "$DOCKER_CALLS" || {
    echo "Session overlay source doesn't match project key"
    cat "$DOCKER_CALLS"
    return 1
  }
}

@test "smoke: cleat start mounts per-project history overlay" {
  mkdir -p "$TEST_TEMP/project"
  printf '' > "$DOCKER_MOCK_DIR/ps_output"
  printf '' > "$DOCKER_MOCK_DIR/ps_a_output"
  printf 'cleat\n' > "$DOCKER_MOCK_DIR/images_output"

  local _bn _h project_key
  _bn="$(basename "$TEST_TEMP/project" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g')"
  _h="$(echo -n "$TEST_TEMP/project" | _md5 | head -c 8)"
  project_key="${_bn}-${_h}"

  cd "$TEST_TEMP/project"
  run cleat_bin_timeout 5 start
  grep -qF -- "history.jsonl:/home/coder/.claude/history.jsonl" "$DOCKER_CALLS" || {
    echo "History overlay mount missing from docker run"
    cat "$DOCKER_CALLS"
    return 1
  }
  grep -qF -- "${project_key}/history.jsonl:/home/coder/.claude/history.jsonl" "$DOCKER_CALLS" || {
    echo "History overlay source doesn't match project key"
    cat "$DOCKER_CALLS"
    return 1
  }
}

# ── Config drift and version label ──────────────────────────────────────────

@test "smoke: cleat start stores config-hash label on run" {
  mkdir -p "$TEST_TEMP/project"
  printf '' > "$DOCKER_MOCK_DIR/ps_output"
  printf '' > "$DOCKER_MOCK_DIR/ps_a_output"
  printf 'cleat\n' > "$DOCKER_MOCK_DIR/images_output"

  cd "$TEST_TEMP/project"
  run cleat_bin_timeout 5 start
  grep -q 'sh.cleat.config-hash=' "$DOCKER_CALLS" || {
    echo "config-hash label missing from docker run"
    cat "$DOCKER_CALLS"
    return 1
  }
}

@test "smoke: cleat start stores version label on run" {
  mkdir -p "$TEST_TEMP/project"
  printf '' > "$DOCKER_MOCK_DIR/ps_output"
  printf '' > "$DOCKER_MOCK_DIR/ps_a_output"
  printf 'cleat\n' > "$DOCKER_MOCK_DIR/images_output"

  cd "$TEST_TEMP/project"
  run cleat_bin_timeout 5 start
  grep -q 'sh.cleat.version=' "$DOCKER_CALLS" || {
    echo "version label missing from docker run"
    cat "$DOCKER_CALLS"
    return 1
  }
}

@test "smoke: cleat upgrade-claude runs installer + commit under strict mode" {
  printf '' > "$DOCKER_MOCK_DIR/ps_output"
  printf '' > "$DOCKER_MOCK_DIR/ps_a_output"
  printf 'cleat\n' > "$DOCKER_MOCK_DIR/images_output"

  run cleat_bin_timeout 10 upgrade-claude latest
  [ "$status" -eq 0 ]
  grep -q 'install.sh' "$DOCKER_CALLS" || {
    echo "installer not invoked"; cat "$DOCKER_CALLS"; return 1
  }
  grep -q '^docker commit' "$DOCKER_CALLS" || {
    echo "commit not invoked"; cat "$DOCKER_CALLS"; return 1
  }
}

@test "smoke: cleat upgrade-claude rejects a bogus version under strict mode" {
  printf 'cleat\n' > "$DOCKER_MOCK_DIR/images_output"

  run cleat_bin upgrade-claude not-a-version
  [ "$status" -eq 1 ]
  [[ "$output" == *"Invalid version"* ]]
}

@test "smoke: on-start update check never blocks a non-interactive start" {
  mkdir -p "$TEST_TEMP/project"
  printf '' > "$DOCKER_MOCK_DIR/ps_output"
  printf '' > "$DOCKER_MOCK_DIR/ps_a_output"
  printf 'cleat\n' > "$DOCKER_MOCK_DIR/images_output"

  # Force the check and pretend a much newer Claude Code exists. A
  # non-interactive run (smoke output is piped, so not a TTY) must skip the
  # prompt entirely and start the container: never hang waiting on input.
  export CLEAT_FORCE_CLAUDE_CHECK=1
  export CLEAT_FAKE_REMOTE_CLAUDE=2.1.999

  cd "$TEST_TEMP/project"
  run cleat_bin_timeout 5 start
  refute_output --partial "Update the image before starting?"
  # The container actually started: proves cmd_run got past the check rather
  # than blocking on the prompt (which would have tripped the 5s timeout).
  grep -q 'sh.cleat.version=' "$DOCKER_CALLS" || {
    echo "container never started; the update check may have blocked"
    cat "$DOCKER_CALLS"
    return 1
  }
}

@test "smoke: cleat prune exits 0 under strict mode" {
  # No prunable artifacts in the stub world, must report cleanly, not crash
  # on set -u / pipefail in the stats plumbing.
  run cleat_bin prune
  assert_success
  assert_output --partial "Nothing to prune"
  refute_output --partial "unbound variable"
  refute_output --partial "command not found"
}

@test "smoke: cleat status survives the new arch/zombie/VM probes under strict mode" {
  run cleat_bin status
  assert_success
  assert_output --partial "Status:"
  refute_output --partial "unbound variable"
}

@test "smoke: the on-start Docker-tuned confirmation survives strict mode" {
  # The on-start sequence isn't reachable through a stubbed `cleat start`, so
  # drive _maybe_announce_docker_ready (and its per-URL marker sweep) directly in
  # a subprocess with the binary's REAL `set -euo pipefail` intact, the condition
  # macOS users run under. Catches set -e trips (e.g. _path_mtime's stat probe on
  # a vanished marker) and set -u unbound vars that the sourced unit tests, which
  # strip strict mode, can't see.
  cat > "$TEST_TEMP/ready_strict.sh" <<EOF
set -euo pipefail
source "$CLI"
_is_tty() { return 0; }
_is_docker_desktop() { return 0; }            # VM-backed engine (the noun is engine-aware)
_docker_vm_memory() { echo 17179869184; }     # 16 GiB VM
_host_total_memory() { echo 34359738368; }    # 32 GiB host → rec 16 (met)
_ONSTART_GAP_OPEN=0
_maybe_announce_docker_ready
# Native-engine reading of the same nod (small host, no VM): exercises the
# engine predicate and the headroom-floor arithmetic under real strict mode.
_is_macos() { return 1; }
_is_docker_desktop() { return 1; }
_docker_vm_memory() { echo 4294967296; }      # a 4 GB native host
_host_total_memory() { echo 4294967296; }
_maybe_announce_docker_ready
# Exercise the debounce sweep over a stale marker via the real if-condition call.
clip="\$(mktemp -d)"
mkdir -p "\$clip/.open.stale"; touch -t 200001010000 "\$clip/.open.stale"
if _browser_recently_opened "\$clip" "https://example.com/z"; then :; fi
rm -rf "\$clip"
EOF
  run bash "$TEST_TEMP/ready_strict.sh"
  assert_success
  assert_output --partial "Docker tuned for Cleat"
  assert_output --partial "4 GB RAM available to boxes"  # the native reading, no VM claim
  refute_output --partial "unbound variable"
  refute_output --partial "command not found"
}

@test "smoke: VM swap detection + advisory survive strict mode" {
  # The swap scrape is a grep pipeline + bash arithmetic, exactly the shape that
  # trips set -e/pipefail (a no-match grep) and set -u (unbound _DD_* seams).
  # Exercise both the empty (no-match) path and the live advisory under the
  # binary's REAL strict mode, the condition macOS users run under.
  cat > "$TEST_TEMP/swap_strict.sh" <<EOF
set -euo pipefail
source "$CLI"
_is_tty() { return 0; }
# Docker Desktop is the premise of the whole scrape: the settings file is only
# read when Desktop is the running engine, so a host that moved to OrbStack or
# Colima is not described by a file it left behind.
_is_docker_desktop() { return 0; }
_docker_vm_memory() { echo 17179869184; }     # 16 GiB VM (memory is fine)
_host_total_memory() { echo 34359738368; }    # 32 GiB host
dd="\$(mktemp -d)"
export _DD_SETTINGS_DIR="\$dd"
# 1. SwapMiB absent → the no-match grep must NOT abort (the || true guard).
printf '{ "MemoryMiB": 16384 }\n' > "\$dd/settings-store.json"
empty="\$(_docker_vm_swap_bytes)"; echo "empty=[\$empty]"
# 2. A leading-zero value must read base-10, never abort on invalid octal.
printf '{ "SwapMiB": 08 }\n' > "\$dd/settings-store.json"
octal="\$(_docker_vm_swap_bytes)"; echo "octal=[\$octal]"
# 3. No settings file at all (the common non-Docker-Desktop case) must not abort.
rm -f "\$dd/settings-store.json"
nofile="\$(_docker_vm_swap_bytes)"; echo "nofile=[\$nofile]"
# 4. Low SwapMiB → the advisory branch runs end to end.
printf '{ "SwapMiB": 1024 }\n' > "\$dd/settings-store.json"
_ONSTART_GAP_OPEN=0
_maybe_announce_docker_ready
rm -rf "\$dd"
EOF
  run bash "$TEST_TEMP/swap_strict.sh"
  assert_success
  assert_output --partial "empty=[]"
  assert_output --partial "octal=[8388608]"              # "08" read as base-10 (8 MiB), no abort
  assert_output --partial "nofile=[]"                    # no settings file, clean empty
  assert_output --partial "Swap ≥ 2 GB"
  refute_output --partial "unbound variable"
  refute_output --partial "command not found"
  refute_output --partial "value too great for base"     # the octal arithmetic error must not leak
}

@test "smoke: VM configured-size read + bridge policy survive strict mode" {
  # The configured-slider read is a grep pipeline + 10# arithmetic (the set -e /
  # pipefail / set -u shape), and the bridge policy helpers run on every session
  # start. Exercise them under the binary's REAL strict mode, the condition macOS
  # users run under, including the no-settings and unset-env-var paths.
  cat > "$TEST_TEMP/vmbridge_strict.sh" <<EOF
set -euo pipefail
source "$CLI"
_is_tty() { return 0; }
_is_docker_desktop() { return 0; }             # Docker Desktop (the slider read is DD by nature)
_docker_vm_memory() { echo 25125558681; }      # ~23.4 GiB MemTotal (a 24 GB slider)
_host_total_memory() { echo 68719476736; }     # 64 GiB host
dd="\$(mktemp -d)"
export _DD_SETTINGS_DIR="\$dd"
# 1. Configured slider read from settings: a 24 GB slider must display 24, not 23.
printf '{ "MemoryMiB": 24576, "SwapMiB": 4096 }\n' > "\$dd/settings-store.json"
_ONSTART_GAP_OPEN=0
_maybe_announce_docker_ready
# 2. No settings file: the resolver must fall back to MemTotal rounding, no abort.
rm -f "\$dd/settings-store.json"
fb="\$(_docker_vm_display_gb 17179869184)"; echo "fallback=[\$fb]"
# 3. Bridge policy with the env var UNSET (set -u) and on a typo.
unset CLEAT_BROWSER_BRIDGE
echo "mode=[\$(_browser_bridge_mode)]"
if _browser_should_open auto 1 0 1; then echo "plain=open"; else echo "plain=defer"; fi
if _browser_should_open auto 1 1 1; then echo "auth=open"; else echo "auth=defer"; fi
# 3b. The destination gate itself, under strict mode: _bridge_url_host runs a
#     tr pipeline and _bridge_origin_allowed reads a here-doc in a while loop,
#     both of which are the pipefail / set -u shape.
if _bridge_dest_allowed "https://claude.ai/oauth/authorize"; then echo "listed=open"; else echo "listed=deny"; fi
if _bridge_dest_allowed "https://evil.example.com/x"; then echo "unlisted=open"; else echo "unlisted=deny"; fi
echo "origins=[$(_bridge_origins_effective | grep -c .)]"
# 4. Auth classification under strict mode: the code-paste login URL (no
#    loopback callback) is auth; a plain link is not; neither aborts set -e.
if _is_auth_url "https://claude.ai/oauth/authorize?code=true&redirect_uri=https%3A%2F%2Fconsole.anthropic.com%2Fcb"; then echo "codepaste=auth"; else echo "codepaste=plain"; fi
if _is_auth_url "https://example.com/docs"; then echo "docs=auth"; else echo "docs=plain"; fi
rm -rf "\$dd"
EOF
  run bash "$TEST_TEMP/vmbridge_strict.sh"
  assert_success
  assert_output --partial "24 GB VM"                     # configured slider drives the display
  refute_output --partial "23 GB VM"
  assert_output --partial "fallback=[16]"                # MemTotal rounding when settings are gone
  assert_output --partial "mode=[auto]"                  # unset env var defaults to auto, no unbound-var
  assert_output --partial "plain=defer"                  # no duplicate tab on an interactive terminal
  assert_output --partial "auth=open"                    # login URLs still open
  assert_output --partial "codepaste=auth"               # code-paste login URL counts as auth
  assert_output --partial "listed=open"                  # the destination gate allows a shipped origin
  assert_output --partial "unlisted=deny"                # and refuses one the box chose
  assert_output --partial "docs=plain"                   # plain links still defer
  refute_output --partial "unbound variable"
  refute_output --partial "command not found"
}

@test "smoke: the Docker-config gate survives strict mode and never hangs" {
  # The gate holds an interactive launch on a `read`; that read (and its `|| true`
  # fail-open) is exactly the shape that trips set -e on EOF, and the whole
  # function runs bare in main's dispatch under real `set -euo pipefail`. Drive it
  # directly (a stubbed `cleat start` can't reach the on-start sequence), armed and
  # with _is_interactive forced true, feeding EOF via </dev/null: it must print the
  # banner, fall through the read, and exit 0 without hanging or aborting. Also
  # prove the escape hatch and the non-interactive path stay silent under strict mode.
  cat > "$TEST_TEMP/gate_strict.sh" <<EOF
set -euo pipefail
source "$CLI"
_is_interactive() { return 0; }
# Force non-WSL: the gate early-returns on a real WSL kernel (bin/cleat ~9666),
# and the Windows/WSL2 CI leg sources this under one, which would suppress the
# banner this test asserts.
_is_wsl() { return 1; }
_DOCKER_GATE_PENDING=1
_DOCKER_GATE_SUMMARY="Docker VM memory is 8 GB (aim for 16 GB)."
# 1. Armed + interactive + EOF stdin: banner prints, read fails open, rc 0.
_maybe_gate_on_docker_config </dev/null
echo "after-block=[\$?]"
# 2. Escape hatch: silent, no hold.
CLEAT_NO_DOCKER_GATE=1 _maybe_gate_on_docker_config </dev/null && echo "hatch=ok"
# 3. Non-interactive: silent even when armed.
_is_interactive() { return 1; }
_maybe_gate_on_docker_config </dev/null && echo "noninteractive=ok"
EOF
  run bash "$TEST_TEMP/gate_strict.sh"
  assert_success
  assert_output --partial "Docker is not tuned for Cleat"
  assert_output --partial "after-block=[0]"
  assert_output --partial "hatch=ok"
  assert_output --partial "noninteractive=ok"
  refute_output --partial "unbound variable"
  refute_output --partial "command not found"
}

# ── [setup] provisioning (concept/16) ───────────────────────────────────────

@test "smoke: cleat setup reports no [setup] section" {
  mkdir -p "$TEST_TEMP/proj"
  printf '[caps]\ngit\n' > "$TEST_TEMP/proj/.cleat"
  cd "$TEST_TEMP/proj"
  run cleat_bin setup
  assert_success
  assert_output --partial "No [setup] section"
  refute_output --partial "unbound variable"
}

@test "smoke: cleat setup --show previews an approved payload" {
  mkdir -p "$TEST_TEMP/proj"
  printf '[setup]\necho hello-from-setup\n' > "$TEST_TEMP/proj/.cleat"
  run cleat_bin trust "$TEST_TEMP/proj"
  assert_success
  cd "$TEST_TEMP/proj"
  run cleat_bin setup --show
  assert_success
  assert_output --partial "Source:"
  assert_output --partial "Hash:"
  assert_output --partial "Trust:"
  refute_output --partial "unbound variable"
}

@test "smoke: cleat setup refuses an unapproved payload non-interactively" {
  mkdir -p "$TEST_TEMP/proj"
  printf '[setup]\necho hello-from-setup\n' > "$TEST_TEMP/proj/.cleat"
  unset CLEAT_TRUST_SETUP
  local cname
  cname="$(_compute_cname "$TEST_TEMP/proj")"
  printf '%s\n' "$cname" > "$DOCKER_MOCK_DIR/ps_output"
  cd "$TEST_TEMP/proj"
  run cleat_bin setup
  assert_failure
  assert_output --partial "not approved"
  refute_output --partial "unbound variable"
}

@test "smoke: cleat help lists the setup verb" {
  run cleat_bin help
  assert_success
  assert_output --partial "Run this project's [setup] provisioning now"
  refute_output --partial "unbound variable"
}

@test "smoke: --fork is accepted and does not crash the real binary" {
  # Strict-mode coverage for the flag path: _FORK_REQUESTED is read in cmd_run
  # under set -euo pipefail, and an unbound-variable slip there would only show
  # up as a subprocess failure, never in a sourced test.
  run cleat_bin --fork --help
  assert_success
  assert_output --partial "cleat"
}

@test "smoke: --fork on a directory under the forks dir refuses cleanly" {
  run cleat_bin run --fork nonexistent-box-name-that-is-fine
  # Either it refuses for a real reason or it fails on docker being stubbed
  # out, but it must never emit a bash trace or an unbound-variable error.
  refute_output --partial "unbound variable"
  refute_output --partial "syntax error"
}

@test "smoke: cleat fork with no copies exits 0" {
  mkdir -p "$TEST_TEMP/project"
  cd "$TEST_TEMP/project"
  run cleat_bin fork
  assert_success
  assert_output --partial "No fork workspaces"
  refute_output --partial "unbound variable"
}

@test "smoke: cleat fork list survives strict mode with a copy present" {
  mkdir -p "$TEST_TEMP/project"
  cd "$TEST_TEMP/project"
  mkdir -p "$CLEAT_CONFIG_DIR/forks/cleat-smoke-11112222-main"
  run cleat_bin fork list
  assert_success
  assert_output --partial "cleat-smoke-11112222-main"
  assert_output --partial "apparent"
  refute_output --partial "unbound variable"
}

@test "smoke: cleat fork prune with nothing to do exits 0" {
  mkdir -p "$TEST_TEMP/project"
  cd "$TEST_TEMP/project"
  run cleat_bin fork prune
  assert_success
  assert_output --partial "Nothing to prune"
  refute_output --partial "unbound variable"
}

@test "smoke: cleat fork path with no copy exits 1 and prints nothing on stdout" {
  mkdir -p "$TEST_TEMP/project"
  cd "$TEST_TEMP/project"
  run cleat_bin fork path main
  assert_failure
  refute_output --partial "unbound variable"
}

@test "smoke: cleat fork rejects an unknown subcommand with exit 1" {
  mkdir -p "$TEST_TEMP/project"
  cd "$TEST_TEMP/project"
  run cleat_bin fork definitely-not-a-subcommand
  assert_failure
  assert_output --partial "Unknown subcommand"
  refute_output --partial "unbound variable"
}

@test "smoke: cleat fork --help exits 0" {
  run cleat_bin fork --help
  assert_success
  assert_output --partial "cleat fork prune"
  refute_output --partial "unbound variable"
}

@test "smoke: cleat fork run creates a fork box under strict mode" {
  mkdir -p "$TEST_TEMP/project"
  cd "$TEST_TEMP/project"
  run cleat_bin fork run
  assert_success
  assert_output --partial "Workspace copied"
  refute_output --partial "unbound variable"
}

@test "smoke: cleat fork run rejects an invalid box name with exit 1" {
  mkdir -p "$TEST_TEMP/project"
  cd "$TEST_TEMP/project"
  run cleat_bin fork run "Bad Name"
  assert_failure
  assert_output --partial "Invalid box name"
  refute_output --partial "unbound variable"
}

@test "smoke: cleat fork run rejects a stray second positional with exit 1" {
  mkdir -p "$TEST_TEMP/project"
  cd "$TEST_TEMP/project"
  run cleat_bin fork run feat-a extra
  assert_failure
  assert_output --partial "Unexpected argument"
  refute_output --partial "unbound variable"
}

@test "smoke: cleat fork run then cleat fork list shows the copy" {
  mkdir -p "$TEST_TEMP/project"
  cd "$TEST_TEMP/project"
  run cleat_bin fork run feat-a
  assert_success
  run cleat_bin fork list
  assert_success
  assert_output --partial "feat-a"
  refute_output --partial "unbound variable"
}

@test "smoke: cleat fork path output is capturable, no trailing escapes" {
  # THE bug this subcommand exists to avoid, and it only shows through a real
  # subprocess. `tput cnorm` writes its escape to STDOUT whether or not stdout
  # is a terminal, so every command ended with a cursor-restore sequence.
  # Invisible to a human, fatal to `cd "$(cleat fork path feat-a)"`: the
  # captured value was the path, a newline, then \033[?12l\033[?25h, and cd
  # failed with "no such file or directory". Host run, 2026-07-31.
  mkdir -p "$TEST_TEMP/project"
  cd "$TEST_TEMP/project"
  run cleat_bin fork run
  assert_success
  local out
  out="$(cleat_bin fork path 2>/dev/null)"
  case "$out" in
    *$'\033'*) echo "escape on stdout:"; printf '%s' "$out" | od -c | tail -4; return 1 ;;
  esac
  [ -d "$out" ] || { echo "captured value is not a directory: [$out]"; return 1; }
  ( cd "$out" ) || { echo "cd into the captured path failed"; return 1; }
}

@test "smoke: no cursor escapes reach stdout when it is not a terminal" {
  # Same defect, wider surface: any scriptable output would have been corrupted.
  # Narrowed to the CURSOR sequences on purpose; colour codes on stdout are a
  # separate question and are not what broke command substitution.
  mkdir -p "$TEST_TEMP/project"
  cd "$TEST_TEMP/project"
  local out
  out="$(cleat_bin fork list 2>/dev/null)"
  case "$out" in
    *$'\033'"[?25h"*|*$'\033'"[?12l"*|*$'\033'"[?25l"*)
      echo "cursor escape on stdout:"; printf '%s' "$out" | od -c | tail -4; return 1 ;;
  esac
}

@test "smoke: cleat fork run gets the session preflights, like start --fork" {
  # `cleat fork start|run` was dispatched without the preflight block that
  # every other session verb gets, so with the daemon down it skipped Docker
  # autostart and died on a raw daemon error while `cleat start --fork` from
  # the same shell brought Docker up. The two are documented as the same
  # command. Asserted through the real binary because it is a main() dispatch
  # question, not a cmd_fork one.
  mkdir -p "$TEST_TEMP/project"
  cd "$TEST_TEMP/project"
  run cleat_bin fork run feat-a
  assert_success
  refute_output --partial "unbound variable"
}

@test "smoke: a read-only fork subcommand still never boots the daemon" {
  # The other half: stop/status/nuke and the read-only fork verbs must not
  # start a VM. If `fork path` ever runs _ensure_daemon, this catches it.
  mkdir -p "$TEST_TEMP/project"
  cd "$TEST_TEMP/project"
  run cleat_bin fork path feat-a
  assert_failure
  refute_output --partial "Starting Docker"
  refute_output --partial "unbound variable"
}

# Run `cleat <verb>` against a running stub box whose interactive exec does what
# a login inside the box does: it hands the watcher an authorize URL at an
# unlisted origin, then returns once the watcher has refused it. A wrapper
# ahead of the stub in PATH, because cleat_bin puts the stub first. The binary
# runs under its own set -euo pipefail, which is what a sourced test cannot see.
_smoke_refused_open() {
  local verb="$1"
  mkdir -p "$TEST_TEMP/project" "$TEST_TEMP/wrap"
  local cname; cname="$(_compute_cname "$TEST_TEMP/project")"
  printf '%s\n' "$cname" > "$DOCKER_MOCK_DIR/ps_output"
  printf '%s\n' "$cname" > "$DOCKER_MOCK_DIR/ps_a_output"
  local clip="$XDG_CONFIG_HOME/cleat/run/$cname/clip"
  cat > "$TEST_TEMP/wrap/docker" <<WRAP
#!/usr/bin/env bash
case "\$*" in
  "exec -it "*)
    printf '%s' 'https://auth.example.com/oauth/authorize?client_id=x&redirect_uri=http%3A%2F%2Flocalhost%3A45454%2Fcallback' > "$clip/.browser-open"
    i=0
    while [ "\$i" -lt 100 ]; do
      grep -q 'BLOCKED-ORIGIN origin=auth.example.com' "$clip/.proxy-log" 2>/dev/null && break
      sleep 0.1
      i=\$((i + 1))
    done ;;
esac
exec "$MOCK_BIN/docker" "\$@"
WRAP
  printf '#!/usr/bin/env bash\nexit 0\n' > "$TEST_TEMP/wrap/xdg-open"
  chmod +x "$TEST_TEMP/wrap/docker" "$TEST_TEMP/wrap/xdg-open"
  cd "$TEST_TEMP/project"
  _portable_timeout 30 env \
    PATH="$TEST_TEMP/wrap:$MOCK_BIN:$PATH" \
    HOME="$HOME" \
    XDG_CONFIG_HOME="$XDG_CONFIG_HOME" \
    DOCKER_CALLS="$DOCKER_CALLS" \
    DOCKER_MOCK_DIR="$DOCKER_MOCK_DIR" \
    DOCKER_EXIT_CODE=0 \
    "$CLI" "$verb"
}

@test "smoke: cleat shell reports a refused browser open under strict mode" {
  run _smoke_refused_open shell
  assert_success
  assert_output --partial "cleat browser allow auth.example.com"
  refute_output --partial "unbound variable"
}

@test "smoke: cleat login reports a refused browser open under strict mode" {
  run _smoke_refused_open login
  assert_success
  assert_output --partial "cleat browser allow auth.example.com"
  refute_output --partial "unbound variable"
}

@test "smoke: cleat shell reports a rate-capped browser open under strict mode" {
  # The box's minute ledger already holds six fresh opens, so the next URL is
  # held back by the cap and the report prints it when the shell ends. always
  # mode, so no origin check stands in front of the cap.
  mkdir -p "$TEST_TEMP/project" "$TEST_TEMP/wrap"
  local cname; cname="$(_compute_cname "$TEST_TEMP/project")"
  printf '%s\n' "$cname" > "$DOCKER_MOCK_DIR/ps_output"
  printf '%s\n' "$cname" > "$DOCKER_MOCK_DIR/ps_a_output"
  local clip="$XDG_CONFIG_HOME/cleat/run/$cname/clip"
  local ledger="$XDG_CONFIG_HOME/cleat/run/$cname/clipclaim/.opens"
  cat > "$TEST_TEMP/wrap/docker" <<WRAP
#!/usr/bin/env bash
case "\$*" in
  "exec -it "*)
    mkdir -p "\$(dirname "$ledger")"
    now=\$(date +%s); : > "$ledger"
    for k in 1 2 3 4 5 6; do echo "\$now" >> "$ledger"; done
    printf '%s' 'https://docs.example.org/capped-page' > "$clip/.browser-open"
    i=0
    while [ "\$i" -lt 100 ]; do
      grep -q 'RATE-CAPPED limit=' "$clip/.proxy-log" 2>/dev/null && break
      sleep 0.1
      i=\$((i + 1))
    done ;;
esac
exec "$MOCK_BIN/docker" "\$@"
WRAP
  printf '#!/usr/bin/env bash\nexit 0\n' > "$TEST_TEMP/wrap/xdg-open"
  chmod +x "$TEST_TEMP/wrap/docker" "$TEST_TEMP/wrap/xdg-open"
  cd "$TEST_TEMP/project"
  run _portable_timeout 30 env \
    PATH="$TEST_TEMP/wrap:$MOCK_BIN:$PATH" \
    HOME="$HOME" \
    XDG_CONFIG_HOME="$XDG_CONFIG_HOME" \
    DOCKER_CALLS="$DOCKER_CALLS" \
    DOCKER_MOCK_DIR="$DOCKER_MOCK_DIR" \
    DOCKER_EXIT_CODE=0 \
    CLEAT_BROWSER_BRIDGE=always \
    "$CLI" shell
  assert_success
  assert_output --partial "Did not open"
  assert_output --partial "https://docs.example.org/capped-page"
  refute_output --partial "unbound variable"
}

@test "smoke: cleat browser origins lists a loopback entry as ignored under strict mode" {
  CLEAT_BROWSER_ORIGINS="localhost auth.example.com" run cleat_bin_timeout 10 browser origins
  assert_success
  assert_output --partial "Ignored"
  assert_output --partial "    auth.example.com"
}

@test "smoke: cleat login with no container runs the real binary without a strict-mode crash" {
  # House rule 13: every subcommand gets a smoke test. login was the one verb
  # with none, and it is the verb that drives the browser bridge and the
  # callback proxy, so a set -u slip here strands a login on a real host.
  printf '' > "$DOCKER_MOCK_DIR/ps_output"
  printf '' > "$DOCKER_MOCK_DIR/ps_a_output"
  printf '' > "$DOCKER_MOCK_DIR/images_output"
  run cleat_bin_timeout 10 login
  refute_output --partial "unbound variable"
  refute_output --partial "command not found"
  refute_output --partial "syntax error"
}

@test "smoke: cleat login on a pinned box harvests the new login under strict mode" {
  # The pin read, the store override, the staging, the exec and the harvest all
  # run under set -euo pipefail here. Store and staged share a refreshToken (the
  # same grant, refreshed), so the harvest never reaches the network.
  mkdir -p "$TEST_TEMP/project"
  local cname now_ms
  cname="$(_compute_cname "$TEST_TEMP/project")"
  printf '%s\n' "$cname" > "$DOCKER_MOCK_DIR/ps_output"
  printf '%s\n' "$cname" > "$DOCKER_MOCK_DIR/ps_a_output"
  printf '%s\n' "/home/coder/.cleat-auth" > "$DOCKER_MOCK_DIR/inspect_output"
  now_ms=$(( $(date +%s) * 1000 ))
  mkdir -p "$CLEAT_CONFIG_DIR/box-accounts" "$CLEAT_CONFIG_DIR/accounts/work" \
    "$CLEAT_CONFIG_DIR/run/$cname/auth"
  printf 'work\n' > "$CLEAT_CONFIG_DIR/box-accounts/$cname"
  printf '{"claudeAiOauth":{"accessToken":"a-old","refreshToken":"r-same","expiresAt":%s,"subscriptionType":"max"}}\n' \
    "$(( now_ms + 3600000 ))" > "$CLEAT_CONFIG_DIR/accounts/work/.credentials.json"
  # What `claude auth login` leaves in the relocated store: a newer credential.
  printf '{"claudeAiOauth":{"accessToken":"a-new","refreshToken":"r-same","expiresAt":%s,"subscriptionType":"max"}}\n' \
    "$(( now_ms + 28800000 ))" > "$CLEAT_CONFIG_DIR/run/$cname/auth/.credentials.json"
  cd "$TEST_TEMP/project"
  run cleat_bin_timeout 20 login
  assert_success
  refute_output --partial "unbound variable"
  assert_output --partial "Auth saved to account"
  run grep -c "a-new" "$CLEAT_CONFIG_DIR/accounts/work/.credentials.json"
  assert_output "1"
}

@test "smoke: cleat resume names a saved conversation and its 1M model under strict mode" {
  mkdir -p "$TEST_TEMP/project"
  cd "$TEST_TEMP/project"
  local cname key sdir id="11111111-1111-4111-8111-111111111111"
  cname="$(_compute_cname "$TEST_TEMP/project")"
  key="${cname#cleat-}"
  printf '%s\n' "$cname" > "$DOCKER_MOCK_DIR/ps_output"
  printf '%s\n' "$cname" > "$DOCKER_MOCK_DIR/ps_a_output"
  printf 'cleat\n' > "$DOCKER_MOCK_DIR/images_output"
  sdir="$HOME/.claude/projects/$key"
  mkdir -p "$sdir"
  printf '%s\n' \
    '{"parentUuid":null,"isSidechain":false,"type":"user","message":{"role":"user","content":"hi"},"entrypoint":"cli","sessionId":"'"$id"'"}' \
    '{"parentUuid":"u1","isSidechain":false,"message":{"id":"m1","type":"message","role":"assistant","model":"claude-opus-5","content":[]},"type":"assistant","sessionId":"'"$id"'"}' \
    '{"type":"cost-state","sessionId":"'"$id"'","modelUsage":{"claude-opus-5[1m]":{"inputTokens":12}}}' > "$sdir/$id.jsonl"

  run cleat_bin_timeout 10 resume
  refute_output --partial "unbound variable"
  refute_output --partial "syntax error"
  run grep -F -- "--resume $id --model claude-opus-5[1m]" "$DOCKER_CALLS"
  assert_success
}

# Resolve a project the way the CLI does and print "CNAME<TAB>SDIR". Sources a
# strict-mode-stripped copy in a subshell (main() is guarded behind a
# BASH_SOURCE check, so sourcing runs no command).
_smoke_resolve() {
  local proj="$1"
  sed 's/^set -euo pipefail$/ /' "$CLI" > "$TEST_TEMP/cli-src.sh"
  env HOME="$HOME" XDG_CONFIG_HOME="$XDG_CONFIG_HOME" bash -c '
    cd "$3" || exit 1
    source "$1" >/dev/null 2>&1 || true
    p="$(resolve_project "")"
    printf "%s\t%s" "$(container_name_for "$p" main)" "$(_sessions_key_dir "$p" main)"
  ' _ "$TEST_TEMP/cli-src.sh" "$proj" "$proj"
}

@test "smoke: cleat relaunches once on a ready switch ticket under strict mode" {
  # The relaunch loop, on the REAL binary under set -euo pipefail and a pty (so
  # the session is interactive and relaunchable). The exec fixture returns 143
  # with a ready ticket the first time and 0 the second, so the loop reopens
  # once. See concept/44 5.6.
  command -v script >/dev/null 2>&1 || skip "no script(1) for a pty (handover 9.2)"
  script -qec true /dev/null >/dev/null 2>&1 || skip "script(1) -qec form unavailable"

  mkdir -p "$TEST_TEMP/project"
  local cname sdir sid resolved
  sid="d7b73579-1111-2222-3333-444455556666"
  resolved="$(_smoke_resolve "$TEST_TEMP/project")"
  cname="${resolved%%$'\t'*}"; sdir="${resolved#*$'\t'}"
  printf '%s\n' "$cname" > "$DOCKER_MOCK_DIR/ps_output"
  printf '%s\n' "$cname" > "$DOCKER_MOCK_DIR/ps_a_output"
  printf 'cleat\n' > "$DOCKER_MOCK_DIR/images_output"
  mkdir -p "$sdir"
  printf '{"type":"user","message":{"role":"user"},"parentUuid":null}\n' > "$sdir/$sid.jsonl"

  local rundir="$XDG_CONFIG_HOME/cleat/run/$cname"
  mkdir -p "$rundir"
  cat > "$TEST_TEMP/exec.sh" <<SH
#!/usr/bin/env bash
flat="\$(printf '%s ' "\$@" | tr '\n' ' ')"
case "\$flat" in *clip-daemon*) : ;; *) exit 0 ;; esac
n=\$(cat "$TEST_TEMP/n" 2>/dev/null || echo 0); n=\$((n+1)); printf '%s' "\$n" > "$TEST_TEMP/n"
id=""; for a in "\$@"; do case "\$a" in CLEAT_EXEC_ID=*) id="\${a#CLEAT_EXEC_ID=}";; esac; done
if [ "\$n" -eq 1 ] && [ -n "\$id" ]; then
  { printf 'v=1\n'; printf 'state=ready\n'; printf 'by=%s\n' "\$PPID"; printf 'at=%s\n' "\$(date +%s)"; printf 'sid=%s\n' "$sid"; printf 'to=default\n'; } > "$rundir/.handoff.\$id"
  exit 143
fi
exit 0
SH
  chmod +x "$TEST_TEMP/exec.sh"

  local cmd
  cmd="cd '$TEST_TEMP/project' && env PATH='$MOCK_BIN:$PATH' HOME='$HOME' XDG_CONFIG_HOME='$XDG_CONFIG_HOME' DOCKER_CALLS='$DOCKER_CALLS' DOCKER_MOCK_DIR='$DOCKER_MOCK_DIR' DOCKER_STUB_EXEC_SCRIPT='$TEST_TEMP/exec.sh' CLEAT_TRUST_PROJECT=1 '$CLI' claude"
  run script -qec "$cmd" /dev/null
  refute_output --partial "unbound variable"
  refute_output --partial "syntax error"
  # The real binary prints the dialog hint on the reopen (O1 declined).
  assert_output --partial "answer that before you type continue"
  # Two session execs: the original and the reopen.
  run grep -c "docker exec -it" "$DOCKER_CALLS"
  assert_output "2"
  # The reopen carries the resume id exactly once.
  run grep -c -- "--resume $sid" "$DOCKER_CALLS"
  assert_output "1"
  # O1 declined: the resume-from-summary dialog is not suppressed, so no
  # threshold variable is ever injected on any exec.
  run cat "$DOCKER_CALLS"
  refute_output --partial "CLAUDE_CODE_RESUME_THRESHOLD_MINUTES"
}
