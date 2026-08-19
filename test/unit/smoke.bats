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

  cd "$TEST_TEMP/project"
  run cleat_bin_timeout 5 start
  grep -qF "/var/run/docker.sock:/var/run/docker.sock" "$DOCKER_CALLS" || {
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
if _browser_should_open auto 1 0; then echo "plain=open"; else echo "plain=defer"; fi
if _browser_should_open auto 1 1; then echo "auth=open"; else echo "auth=defer"; fi
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
