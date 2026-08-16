#!/usr/bin/env bats
load "../setup"

setup() {
  _common_setup
  use_docker_stub

  mkdir -p "$TEST_TEMP/bin"
  cat > "$TEST_TEMP/bin/git" << 'GITSTUB'
#!/usr/bin/env bash
echo "git $*" >> "${GIT_CALLS:-/dev/null}"
case "$*" in
  *ls-remote*) echo "${GIT_LS_REMOTE_OUTPUT:-}" ;;
  *fetch*)
    [[ "${GIT_FETCH_FAIL:-}" == "1" ]] && exit 1
    exit 0 ;;
  *checkout*)
    [[ "${GIT_CHECKOUT_FAIL:-}" == "1" ]] && exit 1
    exit 0 ;;
  *)  exit 0 ;;
esac
GITSTUB
  chmod +x "$TEST_TEMP/bin/git"
  export PATH="$TEST_TEMP/bin:$PATH"
  GIT_CALLS="$TEST_TEMP/git_calls"
  export GIT_CALLS
  touch "$GIT_CALLS"
  source_cli
}

teardown() { _common_teardown; }

@test "update: fails if not a git installation" {
  REPO_DIR="$TEST_TEMP"
  run cmd_update
  assert_failure
  assert_output --partial "not a git installation"
}

@test "update: reports already up to date" {
  mkdir -p "$TEST_TEMP/.git"
  REPO_DIR="$TEST_TEMP"
  UPDATE_CHECK_FILE="$TEST_TEMP/.update_check"
  export GIT_LS_REMOTE_OUTPUT="abc123	refs/tags/v${VERSION}"

  run cmd_update
  assert_success
  assert_output --partial "Already on the latest version"
}

@test "update: fails when no remote tags exist" {
  mkdir -p "$TEST_TEMP/.git"
  REPO_DIR="$TEST_TEMP"
  UPDATE_CHECK_FILE="$TEST_TEMP/.update_check"
  export GIT_LS_REMOTE_OUTPUT=""

  run cmd_update
  assert_failure
  assert_output --partial "No tags found"
}

@test "update: checks out new version and clears cache" {
  mkdir -p "$TEST_TEMP/.git"
  REPO_DIR="$TEST_TEMP"
  UPDATE_CHECK_FILE="$TEST_TEMP/.update_check"
  echo "12345 old" > "$UPDATE_CHECK_FILE"
  export GIT_LS_REMOTE_OUTPUT="abc123	refs/tags/v99.0.0"

  run cmd_update
  assert_success
  assert_output --partial "99.0.0"
  assert_output --partial "cleat rebuild"

  # Git checkout was called
  run cat "$GIT_CALLS"
  assert_output --partial "checkout"

  # Cache file cleared
  [[ ! -f "$UPDATE_CHECK_FILE" ]]  || return 1
}

@test "update: fails gracefully on fetch error" {
  mkdir -p "$TEST_TEMP/.git"
  REPO_DIR="$TEST_TEMP"
  export GIT_FETCH_FAIL=1

  run cmd_update
  assert_failure
  assert_output --partial "Failed to fetch"
}

@test "update: fails gracefully on checkout error" {
  mkdir -p "$TEST_TEMP/.git"
  REPO_DIR="$TEST_TEMP"
  UPDATE_CHECK_FILE="$TEST_TEMP/.update_check"
  export GIT_LS_REMOTE_OUTPUT="abc123	refs/tags/v99.0.0"
  export GIT_CHECKOUT_FAIL=1

  run cmd_update
  assert_failure
  assert_output --partial "Failed to checkout"
}

@test "update: tries docker pull after git update" {
  mkdir -p "$TEST_TEMP/.git"
  REPO_DIR="$TEST_TEMP"
  UPDATE_CHECK_FILE="$TEST_TEMP/.update_check"
  echo "12345 old" > "$UPDATE_CHECK_FILE"
  export GIT_LS_REMOTE_OUTPUT="abc123	refs/tags/v99.0.0"

  run cmd_update
  assert_success

  # Docker pull was attempted with the version-matched registry image
  # (v99.0.0 is the new tag cmd_update just checked out).
  run grep "pull" "$DOCKER_CALLS"
  assert_success
  assert_output --partial "${REGISTRY_BASE}:v99.0.0"
}

@test "update: shows rebuild hint when pull fails" {
  mkdir -p "$TEST_TEMP/.git"
  REPO_DIR="$TEST_TEMP"
  UPDATE_CHECK_FILE="$TEST_TEMP/.update_check"
  echo "12345 old" > "$UPDATE_CHECK_FILE"
  export GIT_LS_REMOTE_OUTPUT="abc123	refs/tags/v99.0.0"
  # Pull fails (default stub behavior)

  run cmd_update
  assert_success
  assert_output --partial "cleat rebuild"
}

@test "update: refuses to self-update a Homebrew install when brew is off PATH" {
  # The detector has its own tests below; here we lock the BRANCH: a
  # brew-managed cleat must refuse before any git or docker work, and must
  # never print the curl re-install hint (which on an Intel Mac would symlink
  # over Homebrew's own bin). _brew_present is forced FALSE so this covers the
  # fallback: detection deliberately never depends on brew being reachable, so
  # the printed remedy has to work when it is not. Forcing it also keeps the
  # suite from shelling out to a real brew on a developer's Mac.
  mkdir -p "$TEST_TEMP/.git"
  REPO_DIR="$TEST_TEMP"
  UPDATE_CHECK_FILE="$TEST_TEMP/.update_check"
  export GIT_LS_REMOTE_OUTPUT="abc123	refs/tags/v99.0.0"
  _is_brew_managed() { return 0; }
  _brew_present() { return 1; }

  run cmd_update
  assert_failure
  assert_output --partial "Installed via Homebrew"
  assert_output --partial "brew upgrade cleatdev/tap/cleat"
  refute_output --partial "not a git installation"
  refute_output --partial "install.sh"

  # No network, no checkout, no image pull: the refusal is total.
  run cat "$GIT_CALLS"
  refute_output --partial "fetch"
  refute_output --partial "checkout"
  run cat "$DOCKER_CALLS"
  refute_output --partial "pull"
}

@test "update: hands a Homebrew install to brew upgrade" {
  # With brew reachable the refusal becomes a delegation: run the upgrade
  # rather than describe it, because `cleat update` on a git install updates
  # without asking and a keg should get the same treatment.
  mkdir -p "$TEST_TEMP/.git"
  REPO_DIR="$TEST_TEMP"
  UPDATE_CHECK_FILE="$TEST_TEMP/.update_check"
  export GIT_LS_REMOTE_OUTPUT="abc123	refs/tags/v99.0.0"
  _is_brew_managed() { return 0; }
  _brew_present() { return 0; }
  _brew_delegate() { echo "DELEGATE $*"; return 0; }

  run cmd_update
  # In the real binary the delegation execs and this process is gone, so the
  # exit code here is the unreachable backstop rather than brew's. What matters
  # is that the branch is terminal: with the delegate stubbed to RETURN, the
  # git updater below must still never run. The end-to-end success path (brew's
  # own exit code) is covered by the keg smoke test.
  assert_failure
  assert_output --partial "DELEGATE upgrade cleatdev/tap/cleat"
  refute_output --partial "Checking for updates"
  refute_output --partial "not a git installation"
  run cat "$GIT_CALLS"
  refute_output --partial "fetch"
  run cat "$DOCKER_CALLS"
  refute_output --partial "pull"
}

@test "update: _brew_delegate execs brew and never returns" {
  # The exec is the point: `brew upgrade` removes the keg this script is being
  # read from, so the process image must be replaced rather than the script
  # left to read its own deleted file. Run it in a real subprocess, since a
  # successful exec ends whatever process reaches it.
  cat > "$TEST_TEMP/bin/brew" << 'BREWSTUB'
#!/usr/bin/env bash
echo "BREW $*"
BREWSTUB
  chmod +x "$TEST_TEMP/bin/brew"

  local cli_copy="$TEST_TEMP/cleat-delegate.sh"
  sed 's/^set -euo pipefail$/: # stripped for this subshell/' "$CLI" > "$cli_copy"

  run bash -c 'source "$1"; _brew_delegate upgrade cleatdev/tap/cleat; echo "RETURNED"' \
    _ "$cli_copy"
  assert_success
  assert_output --partial "BREW upgrade cleatdev/tap/cleat"
  refute_output --partial "RETURNED"
}

@test "update: _brew_delegate survives an exec that cannot run brew" {
  # `command -v` succeeding does not mean exec will work: brew can be removed
  # between the check and the call (in cleat uninstall that window spans a
  # human prompt), lose its exec bit, or carry a bad interpreter. Without
  # `shopt -s execfail` a failed exec kills the shell at 126/127 and the
  # printed-command fallback is unreachable in exactly the case it exists for.
  # _brew_present is forced true with no brew on PATH to put exec in that state.
  local cli_copy="$TEST_TEMP/cleat-execfail.sh"
  sed 's/^set -euo pipefail$/: # stripped for this subshell/' "$CLI" > "$cli_copy"

  run env PATH="/usr/bin:/bin" bash -c \
    'source "$1"; _brew_present() { return 0; }; _brew_delegate upgrade cleatdev/tap/cleat && echo "EXECED" || echo "FELL THROUGH"' \
    _ "$cli_copy"
  assert_output --partial "FELL THROUGH"
  refute_output --partial "EXECED"
}

@test "update: _brew_delegate returns non-zero when brew is off PATH" {
  # The fallback the printed remedy depends on. No exec, no output claiming a
  # brew run happened.
  local cli_copy="$TEST_TEMP/cleat-nobrew.sh"
  sed 's/^set -euo pipefail$/: # stripped for this subshell/' "$CLI" > "$cli_copy"

  run env PATH="$TEST_TEMP/empty-bin:/usr/bin:/bin" bash -c \
    'source "$1"; _brew_delegate upgrade cleatdev/tap/cleat && echo "EXECED" || echo "FELL THROUGH"' \
    _ "$cli_copy"
  assert_success
  assert_output --partial "FELL THROUGH"
  refute_output --partial "EXECED"
}

@test "update: _is_brew_managed detects a keg through the bin symlink" {
  # No INSTALL_RECEIPT.json here on purpose: this test must depend on the
  # Cellar path segment alone, so breaking that pattern cannot be masked by
  # the receipt walk (which the separate receipt test covers).
  mkdir -p "$TEST_TEMP/hb/Cellar/cleat/9.9.9/libexec/bin" "$TEST_TEMP/hb/bin"
  : > "$TEST_TEMP/hb/Cellar/cleat/9.9.9/libexec/bin/cleat"
  ln -s "../Cellar/cleat/9.9.9/libexec/bin/cleat" "$TEST_TEMP/hb/bin/cleat"

  # Probe the SYMLINK: that is what BASH_SOURCE holds for a brew install.
  run _is_brew_managed "$TEST_TEMP/hb/bin/cleat"
  assert_success
}

@test "update: _is_brew_managed detects a keg receipt above the binary" {
  # Second signal, independent of the path spelling: the keg root's receipt.
  mkdir -p "$TEST_TEMP/keg/cleat/9.9.9/libexec/bin"
  : > "$TEST_TEMP/keg/cleat/9.9.9/libexec/bin/cleat"
  echo '{}' > "$TEST_TEMP/keg/cleat/9.9.9/INSTALL_RECEIPT.json"

  run _is_brew_managed "$TEST_TEMP/keg/cleat/9.9.9/libexec/bin/cleat"
  assert_success
}

@test "update: _is_brew_managed is false for the curl install symlink shape" {
  # The Intel-Mac collision: /usr/local/bin is Homebrew's bin AND install.sh's
  # symlink target. Only the resolved physical path can tell them apart, so a
  # symlink in a brew-shaped directory pointing at ~/.cleat is NOT brew.
  mkdir -p "$TEST_TEMP/usr-local-bin" "$TEST_TEMP/.cleat/bin"
  : > "$TEST_TEMP/.cleat/bin/cleat"
  ln -s "$TEST_TEMP/.cleat/bin/cleat" "$TEST_TEMP/usr-local-bin/cleat"

  run _is_brew_managed "$TEST_TEMP/usr-local-bin/cleat"
  assert_failure
}

@test "update: _is_brew_managed is false for a plain regular file" {
  mkdir -p "$TEST_TEMP/plain/bin"
  : > "$TEST_TEMP/plain/bin/cleat"

  run _is_brew_managed "$TEST_TEMP/plain/bin/cleat"
  assert_failure
}

@test "update: _resolve_physical_path follows a relative symlink chain" {
  mkdir -p "$TEST_TEMP/hb/Cellar/cleat/9.9.9/libexec/bin" "$TEST_TEMP/hb/bin"
  : > "$TEST_TEMP/hb/Cellar/cleat/9.9.9/libexec/bin/cleat"
  ln -s "../Cellar/cleat/9.9.9/libexec/bin/cleat" "$TEST_TEMP/hb/bin/cleat"

  local want
  want="$(cd "$TEST_TEMP/hb/Cellar/cleat/9.9.9/libexec/bin" && pwd -P)/cleat"

  run _resolve_physical_path "$TEST_TEMP/hb/bin/cleat"
  assert_success
  assert_output "$want"
}

@test "update: _resolve_physical_path resolves through directories with spaces" {
  mkdir -p "$TEST_TEMP/h b/Cellar/cleat/9.9.9/libexec/bin" "$TEST_TEMP/h b/bin"
  : > "$TEST_TEMP/h b/Cellar/cleat/9.9.9/libexec/bin/cleat"
  ln -s "../Cellar/cleat/9.9.9/libexec/bin/cleat" "$TEST_TEMP/h b/bin/cleat"

  local want
  want="$(cd "$TEST_TEMP/h b/Cellar/cleat/9.9.9/libexec/bin" && pwd -P)/cleat"

  run _resolve_physical_path "$TEST_TEMP/h b/bin/cleat"
  assert_success
  assert_output "$want"

  run _is_brew_managed "$TEST_TEMP/h b/bin/cleat"
  assert_success
}

@test "update: _resolve_physical_path returns an unresolvable path unchanged" {
  # A deleted or never-created path (what BASH_SOURCE holds for a sourced
  # copy) must come back verbatim, not empty: callers pattern-match it.
  run _resolve_physical_path "$TEST_TEMP/gone/cleat"
  assert_success
  assert_output "$TEST_TEMP/gone/cleat"
}

@test "update: _resolve_physical_path survives a symlink cycle" {
  # A cycle must be capped, not walked forever. Run it in a timed subprocess
  # so a broken cap fails the test instead of hanging the whole suite.
  ln -s "$TEST_TEMP/loop-b" "$TEST_TEMP/loop-a"
  ln -s "$TEST_TEMP/loop-a" "$TEST_TEMP/loop-b"

  local cli_copy="$TEST_TEMP/cleat-cycle.sh"
  sed 's/^set -euo pipefail$/: # stripped for this subshell/' "$CLI" > "$cli_copy"

  run _portable_timeout 10 bash -c 'source "$1"; _resolve_physical_path "$2"' \
    _ "$cli_copy" "$TEST_TEMP/loop-a"
  assert_success
  assert_output --partial "$TEST_TEMP/loop-"
}

@test "update: the on-start prompt stays silent for an install with no git tree" {
  # The Homebrew shape relies on this gate: a keg has no .git, so the on-start
  # self-update offer must never fire there (it would git-checkout inside the
  # keg). Stronger than version.bats' shallow check: here a NEWER release is
  # cached and the TTY is forced, so only the .git gate keeps it quiet.
  REPO_DIR="$TEST_TEMP"  # deliberately no .git
  UPDATE_CHECK_FILE="$TEST_TEMP/.update_check"
  export CLEAT_FORCE_UPDATE_CHECK=1
  export GIT_LS_REMOTE_OUTPUT="abc123	refs/tags/v99.0.0"
  _is_tty() { return 0; }
  _repo_is_clean() { return 0; }
  _apply_cli_update() { echo "APPLY_CALLED"; return 0; }
  _reexec_cli() { echo "REEXEC_CALLED"; }

  run _maybe_prompt_cli_update <<< "n"
  assert_success
  assert_output ""

  # The gate returns before the throttle file is even written.
  run test -f "$UPDATE_CHECK_FILE"
  assert_failure
}

@test "update: the on-start prompt stays silent for a keg whose prefix has git" {
  # The .git gate alone is not enough. On macOS before 12.3 there is no usable
  # `readlink -f`, so REPO_DIR falls back to the Homebrew PREFIX, and on Apple
  # Silicon /opt/homebrew IS Homebrew's own git repository. So .git EXISTS here
  # on purpose: only the brew probe can keep the self-update offer (and its
  # `git checkout v<tag>`) out of brew's own checkout.
  mkdir -p "$TEST_TEMP/.git"
  REPO_DIR="$TEST_TEMP"
  UPDATE_CHECK_FILE="$TEST_TEMP/.update_check"
  export CLEAT_FORCE_UPDATE_CHECK=1
  export GIT_LS_REMOTE_OUTPUT="abc123	refs/tags/v99.0.0"
  _is_tty() { return 0; }
  _repo_is_clean() { return 0; }
  # Pins the ARGUMENT, not just the return value. Probing "$REPO_DIR" would
  # look natural (everything else in this function is REPO_DIR-based) and a
  # stub that ignored its argument would still pass, while in production
  # REPO_DIR on the pre-12.3 leg IS the Homebrew prefix, which is neither a
  # Cellar path nor a keg receipt, so the guard would quietly stop firing.
  _is_brew_managed() { [[ "$1" != "$REPO_DIR" ]]; }
  _apply_cli_update() { echo "APPLY_CALLED"; return 0; }
  _reexec_cli() { echo "REEXEC_CALLED"; }

  run _maybe_prompt_cli_update <<< "n"
  assert_success
  assert_output ""

  # No prompt, no update applied, and no network throttle file written.
  refute_output --partial "APPLY_CALLED"
  refute_output --partial "REEXEC_CALLED"
  run test -f "$UPDATE_CHECK_FILE"
  assert_failure
}

# ── cleat install / uninstall against a Homebrew install ────────────────────
# Every test here stubs ln, rm and sudo. Not politeness: if a guard is reverted
# (which is exactly what the mutation harness does) an unstubbed test would run
# the real command against the real /usr/local/bin.

@test "install: refuses when the running cleat is a Homebrew keg" {
  _is_brew_managed() { return 0; }
  ln() { echo "LN $*"; }
  sudo() { echo "SUDO $*"; }

  run cmd_install
  unset -f ln sudo
  assert_failure
  assert_output --partial "Installed via Homebrew"
  assert_output --partial "brew upgrade cleatdev/tap/cleat"
  refute_output --partial "Installing CLI symlink"
  refute_output --partial "LN "
  refute_output --partial "SUDO "
}

@test "install: refuses to replace a Homebrew symlink in the target dir" {
  # The cross case: a git-installed cleat asked to take over a path Homebrew
  # owns. Only the TARGET is brew-managed here, which also pins the target to
  # /usr/local/bin: point it elsewhere and the mock stops matching.
  _is_brew_managed() { [[ "$1" == "/usr/local/bin/cleat" ]] && return 0; return 1; }
  ln() { echo "LN $*"; }
  sudo() { echo "SUDO $*"; }

  run cmd_install
  unset -f ln sudo
  assert_failure
  assert_output --partial "belongs to Homebrew"
  assert_output --partial "brew uninstall cleatdev/tap/cleat"
  refute_output --partial "Installing CLI symlink"
  refute_output --partial "LN "
  refute_output --partial "SUDO "
}

@test "install: symlinks normally when no Homebrew install is involved" {
  # Negative control: the guards must not block the ordinary git install.
  _is_brew_managed() { return 1; }
  ln() { echo "LN $*"; }
  sudo() { echo "SUDO $*"; }

  run cmd_install
  unset -f ln sudo
  assert_success
  assert_output --partial "Installing CLI symlink"
  assert_output --partial "/usr/local/bin/cleat"
  assert_output --partial "Installed!"
}

@test "uninstall: refuses when the running cleat is a keg and brew is off PATH" {
  _is_brew_managed() { return 0; }
  _brew_present() { return 1; }
  _is_interactive() { return 1; }
  rm() { echo "RM $*"; }
  sudo() { echo "SUDO $*"; }

  run cmd_uninstall
  unset -f rm sudo
  assert_failure
  assert_output --partial "Installed via Homebrew"
  assert_output --partial "brew uninstall cleatdev/tap/cleat"
  refute_output --partial "Removing CLI symlinks"
  refute_output --partial "RM "
  refute_output --partial "SUDO "
}

@test "uninstall: never prompts a keg without a terminal" {
  # Unattended runs must not reach a destructive brew uninstall, even with brew
  # right there. brew IS present here, so only the TTY gate keeps it out.
  _is_brew_managed() { return 0; }
  _brew_present() { return 0; }
  _is_interactive() { return 1; }
  _brew_delegate() { echo "DELEGATE $*"; return 0; }
  rm() { echo "RM $*"; }
  sudo() { echo "SUDO $*"; }

  run cmd_uninstall
  unset -f rm sudo
  assert_failure
  assert_output --partial "Installed via Homebrew"
  refute_output --partial "DELEGATE"
  refute_output --partial "Run brew uninstall"
  refute_output --partial "RM "
}

@test "uninstall: hands a keg to brew uninstall after a yes" {
  # brew uninstall removes the whole keg where this command normally drops a
  # symlink, so the delegation is consent-first rather than automatic.
  _is_brew_managed() { return 0; }
  _brew_present() { return 0; }
  _is_interactive() { return 0; }
  _brew_delegate() { echo "DELEGATE $*"; return 0; }
  rm() { echo "RM $*"; }
  sudo() { echo "SUDO $*"; }

  run cmd_uninstall <<< "y"
  unset -f rm sudo
  assert_failure
  assert_output --partial "Homebrew owns this install"
  assert_output --partial "removes the whole keg"
  assert_output --partial "DELEGATE uninstall cleatdev/tap/cleat"
  refute_output --partial "RM "
}

@test "uninstall: a declined keg prompt runs nothing" {
  _is_brew_managed() { return 0; }
  _brew_present() { return 0; }
  _is_interactive() { return 0; }
  _brew_delegate() { echo "DELEGATE $*"; return 0; }
  rm() { echo "RM $*"; }
  sudo() { echo "SUDO $*"; }

  run cmd_uninstall <<< "n"
  unset -f rm sudo
  assert_failure
  assert_output --partial "Skipped"
  assert_output --partial "brew uninstall cleatdev/tap/cleat"
  refute_output --partial "DELEGATE"
  refute_output --partial "RM "
}

@test "uninstall: a keg prompt on redirected stdin is a decline" {
  # The house rule for every [y/N]: EOF means no, never a silent yes. Here that
  # rule is the difference between a wrapper deleting someone's keg and not.
  _is_brew_managed() { return 0; }
  _brew_present() { return 0; }
  _is_interactive() { return 0; }
  _brew_delegate() { echo "DELEGATE $*"; return 0; }
  rm() { echo "RM $*"; }
  sudo() { echo "SUDO $*"; }

  run cmd_uninstall < /dev/null
  unset -f rm sudo
  assert_failure
  assert_output --partial "Skipped"
  refute_output --partial "DELEGATE"
  refute_output --partial "RM "
}

@test "uninstall: refuses to remove a Homebrew symlink from the target dir" {
  # On an Intel Mac /usr/local/bin IS Homebrew's bin, so the rm would take
  # brew's own symlink with it and leave brew believing cleat is installed.
  _is_brew_managed() { [[ "$1" == "/usr/local/bin/cleat" ]] && return 0; return 1; }
  rm() { echo "RM $*"; }
  sudo() { echo "SUDO $*"; }

  run cmd_uninstall
  unset -f rm sudo
  assert_failure
  assert_output --partial "belongs to Homebrew"
  assert_output --partial "brew uninstall cleatdev/tap/cleat"
  refute_output --partial "Removing CLI symlinks"
  refute_output --partial "RM "
  refute_output --partial "SUDO "
}

@test "uninstall: removes the symlink when no Homebrew install is involved" {
  # Negative control for both uninstall guards.
  _is_brew_managed() { return 1; }
  rm() { echo "RM $*"; }
  sudo() { echo "SUDO $*"; }

  run cmd_uninstall
  unset -f rm sudo
  assert_success
  assert_output --partial "Removing CLI symlinks"
  assert_output --partial "/usr/local/bin/cleat"
  assert_output --partial "Uninstalled"
}

@test "update: skips rebuild hint when pull succeeds" {
  mkdir -p "$TEST_TEMP/.git"
  REPO_DIR="$TEST_TEMP"
  UPDATE_CHECK_FILE="$TEST_TEMP/.update_check"
  echo "12345 old" > "$UPDATE_CHECK_FILE"
  export GIT_LS_REMOTE_OUTPUT="abc123	refs/tags/v99.0.0"
  export DOCKER_PULL_EXIT_CODE=0

  run cmd_update
  assert_success
  # Should show the pulled-image success line, not the rebuild hint.
  assert_output --partial "pulled v99.0.0"
  refute_output --partial "cleat rebuild"

  unset DOCKER_PULL_EXIT_CODE
}

# ── One install per machine ─────────────────────────────────────────────────

@test "install: _find_cleat_installs lists each cleat on PATH, resolved, in order" {
  mkdir -p "$TEST_TEMP/p1" "$TEST_TEMP/p2" "$TEST_TEMP/real/bin"
  printf '#!/usr/bin/env bash\n' > "$TEST_TEMP/real/bin/cleat"
  chmod +x "$TEST_TEMP/real/bin/cleat"
  ln -s "$TEST_TEMP/real/bin/cleat" "$TEST_TEMP/p1/cleat"
  cp "$TEST_TEMP/real/bin/cleat" "$TEST_TEMP/p2/cleat"

  local old="$PATH"
  # /usr/bin and /bin stay on PATH: resolution shells out to readlink/dirname.
  PATH="$TEST_TEMP/p1:$TEST_TEMP/p2:/usr/bin:/bin"
  run _find_cleat_installs
  PATH="$old"

  assert_success
  # PATH order is the point: the first line is what a bare `cleat` runs.
  assert_line --index 0 --partial "$TEST_TEMP/p1/cleat"
  assert_line --index 0 --partial "$TEST_TEMP/real/bin/cleat"
  assert_line --index 1 --partial "$TEST_TEMP/p2/cleat"
}

@test "install: _find_cleat_installs ignores a cleat that is not executable" {
  # PATH resolution would not run it, so it is not an install.
  mkdir -p "$TEST_TEMP/p1"
  printf '#!/usr/bin/env bash\n' > "$TEST_TEMP/p1/cleat"
  chmod 644 "$TEST_TEMP/p1/cleat"

  local old="$PATH"
  PATH="$TEST_TEMP/p1:/usr/bin:/bin"
  run _find_cleat_installs
  PATH="$old"

  assert_success
  refute_output --partial "$TEST_TEMP/p1/cleat"
}

@test "install: _refuse_other_installs passes when the only cleat is ours" {
  # Same bin path is a re-install, not a second install.
  _find_cleat_installs() { printf '%s\t%s\n' "/usr/local/bin/cleat" "$HOME/.cleat/bin/cleat"; }

  run _refuse_other_installs "/usr/local/bin/cleat" ""
  assert_success
  assert_output ""
}

@test "install: _refuse_other_installs refuses a Homebrew keg at another path" {
  _find_cleat_installs() { printf '%s\t%s\n' "/opt/homebrew/bin/cleat" "/opt/homebrew/Cellar/cleat/1.4.0/libexec/bin/cleat"; }

  run _refuse_other_installs "/usr/local/bin/cleat" ""
  assert_failure
  assert_output --partial "already installed by Homebrew"
  assert_output --partial "/opt/homebrew/bin/cleat"
  assert_output --partial "brew uninstall cleatdev/tap/cleat"
}

@test "install: _refuse_other_installs never lets force override a keg" {
  # Orphaning a keg is the hazard the whole guard exists to prevent, so this is
  # the one conflict force must not resolve.
  _find_cleat_installs() { printf '%s\t%s\n' "/opt/homebrew/bin/cleat" "/opt/homebrew/Cellar/cleat/1.4.0/libexec/bin/cleat"; }
  rm() { echo "RM $*"; }

  run _refuse_other_installs "/usr/local/bin/cleat" 1
  unset -f rm
  assert_failure
  assert_output --partial "already installed by Homebrew"
  refute_output --partial "RM "
}

@test "install: _refuse_other_installs refuses a second symlink and names --force" {
  mkdir -p "$TEST_TEMP/other-bin" "$TEST_TEMP/tree/bin"
  : > "$TEST_TEMP/tree/bin/cleat"
  ln -s "$TEST_TEMP/tree/bin/cleat" "$TEST_TEMP/other-bin/cleat"
  _find_cleat_installs() { printf '%s\t%s\n' "$TEST_TEMP/other-bin/cleat" "$TEST_TEMP/tree/bin/cleat"; }

  run _refuse_other_installs "/usr/local/bin/cleat" ""
  assert_failure
  assert_output --partial "already installed elsewhere"
  assert_output --partial "$TEST_TEMP/other-bin/cleat"
  assert_output --partial "cleat install --force"
  # A plain second install is not a Homebrew problem, so it must not say so.
  refute_output --partial "Homebrew"
}

@test "install: _refuse_other_installs with force removes the other symlink" {
  mkdir -p "$TEST_TEMP/other-bin" "$TEST_TEMP/tree/bin"
  : > "$TEST_TEMP/tree/bin/cleat"
  ln -s "$TEST_TEMP/tree/bin/cleat" "$TEST_TEMP/other-bin/cleat"
  _find_cleat_installs() { printf '%s\t%s\n' "$TEST_TEMP/other-bin/cleat" "$TEST_TEMP/tree/bin/cleat"; }

  run _refuse_other_installs "/usr/local/bin/cleat" 1
  assert_success
  assert_output --partial "Replacing the install at"
  # Removed for real, and only the link: the tree it pointed at is untouched.
  [[ ! -e "$TEST_TEMP/other-bin/cleat" ]] || return 1
  [[ -f "$TEST_TEMP/tree/bin/cleat" ]] || return 1
}

@test "install: _refuse_other_installs will not delete a regular file, even with force" {
  # Not a symlink this installer created: it is somebody's own copy.
  mkdir -p "$TEST_TEMP/other-bin"
  printf '#!/usr/bin/env bash\n' > "$TEST_TEMP/other-bin/cleat"
  chmod +x "$TEST_TEMP/other-bin/cleat"
  _find_cleat_installs() { printf '%s\t%s\n' "$TEST_TEMP/other-bin/cleat" "$TEST_TEMP/other-bin/cleat"; }

  run _refuse_other_installs "/usr/local/bin/cleat" 1
  assert_failure
  assert_output --partial "real file, not a symlink"
  [[ -f "$TEST_TEMP/other-bin/cleat" ]] || return 1
}

@test "install: refuses when another install exists elsewhere" {
  _is_brew_managed() { return 1; }
  _refuse_other_installs() { echo "CONFLICT $*"; return 1; }
  ln() { echo "LN $*"; }
  sudo() { echo "SUDO $*"; }

  run cmd_install
  unset -f ln sudo
  assert_failure
  assert_output --partial "CONFLICT /usr/local/bin/cleat"
  refute_output --partial "Installing CLI symlink"
  refute_output --partial "LN "
}

@test "install: --force reaches the conflict check" {
  _is_brew_managed() { return 1; }
  _refuse_other_installs() { echo "CONFLICT args=[$*]"; return 1; }
  ln() { echo "LN $*"; }
  sudo() { echo "SUDO $*"; }

  run cmd_install --force
  unset -f ln sudo
  assert_failure
  assert_output --partial "CONFLICT args=[/usr/local/bin/cleat 1]"
}

@test "install: _find_cleat_installs sees a fixed location that is not on PATH" {
  # The Apple Silicon case: a Homebrew prefix is invisible to a shell that never
  # ran `brew shellenv`, so a PATH-only scan would report a clean machine while
  # a second cleat sits right there. HOME is isolated here, so ~/.local/bin
  # stands in for that whole class of location.
  mkdir -p "$HOME/.local/bin"
  printf '#!/usr/bin/env bash\n' > "$HOME/.local/bin/cleat"
  chmod +x "$HOME/.local/bin/cleat"

  local old="$PATH"
  PATH="/usr/bin:/bin"   # deliberately WITHOUT ~/.local/bin
  run _find_cleat_installs
  PATH="$old"

  assert_success
  assert_output --partial "$HOME/.local/bin/cleat"
}

# ── State files live outside the install tree ───────────────────────────────
# A keg is deleted and recreated by every `brew upgrade`, so in-tree state was
# lost on each upgrade and on every channel switch. These lock the new home.

@test "state: the update and highlight files default under the config dir" {
  # Behavioral, not a string check: write through the real code path and assert
  # the file lands in the config dir rather than beside the script.
  local cli_copy="$TEST_TEMP/cleat-statepaths.sh"
  sed 's/^set -euo pipefail$/: # stripped for this subshell/' "$CLI" > "$cli_copy"

  run bash -c 'source "$1"; printf "%s\n" "$UPDATE_CHECK_FILE $LAST_SEEN_VERSION_FILE $CLAUDE_CHECK_FILE $PRESSURE_CHECK_FILE $DISK_CHECK_FILE"' \
    _ "$cli_copy"
  assert_success
  assert_output --partial "/cleat/state/"
  refute_output --partial "/.update_check"
  refute_output --partial "/.last_seen_version"
}

@test "state: migrates a file left in the old in-tree location" {
  REPO_DIR="$TEST_TEMP/oldtree"
  CLEAT_STATE_DIR="$TEST_TEMP/newstate"
  UPDATE_CHECK_FILE="$CLEAT_STATE_DIR/update_check"
  mkdir -p "$REPO_DIR"
  echo "12345 9.9.9 9.9.9" > "$REPO_DIR/.update_check"

  run _migrate_state_files
  assert_success
  # Carried across, so an upgrade into this version does not re-nag about a
  # release the user already declined.
  run cat "$CLEAT_STATE_DIR/update_check"
  assert_output "12345 9.9.9 9.9.9"
  # And the old copy is cleaned up.
  run test -f "$REPO_DIR/.update_check"
  assert_failure
}

@test "state: migration never clobbers state already in the new location" {
  REPO_DIR="$TEST_TEMP/oldtree"
  CLEAT_STATE_DIR="$TEST_TEMP/newstate"
  mkdir -p "$REPO_DIR" "$CLEAT_STATE_DIR"
  echo "OLD" > "$REPO_DIR/.update_check"
  echo "CURRENT" > "$CLEAT_STATE_DIR/update_check"

  run _migrate_state_files
  assert_success
  run cat "$CLEAT_STATE_DIR/update_check"
  assert_output "CURRENT"
}

@test "state: migration is silent when the install tree is unreadable" {
  # A keg's tree is not writable. A failed move must never fail a launch.
  REPO_DIR="$TEST_TEMP/does-not-exist"
  CLEAT_STATE_DIR="$TEST_TEMP/newstate"

  run _migrate_state_files
  assert_success
  assert_output ""
}

# ── One version source for every install shape ──────────────────────────────

@test "update: latest_remote_tag asks its own origin on a git checkout" {
  mkdir -p "$TEST_TEMP/.git"
  REPO_DIR="$TEST_TEMP"
  export GIT_LS_REMOTE_OUTPUT="abc123	refs/tags/v9.9.9"

  run latest_remote_tag
  assert_success
  assert_output "9.9.9"
  run cat "$GIT_CALLS"
  assert_output --partial "ls-remote --tags --refs origin"
}

@test "update: latest_remote_tag asks the public URL when there is no repo" {
  # A keg has no repo to ask, so the SAME lookup runs against the public URL.
  # That is what makes the on-start offer identical on both channels.
  REPO_DIR="$TEST_TEMP"   # deliberately no .git
  export GIT_LS_REMOTE_OUTPUT="abc123	refs/tags/v9.9.9"

  run latest_remote_tag
  assert_success
  assert_output "9.9.9"
  run cat "$GIT_CALLS"
  assert_output --partial "https://github.com/cleatdev/cleat"
  refute_output --partial "refs origin"
}

# ── On-start offer: parity between a keg and a git checkout ─────────────────

_keg_prompt_setup() {
  REPO_DIR="$TEST_TEMP"
  UPDATE_CHECK_FILE="$TEST_TEMP/update_check"
  export CLEAT_FORCE_UPDATE_CHECK=1
  export GIT_LS_REMOTE_OUTPUT="abc123	refs/tags/v99.0.0"
  _is_tty() { return 0; }
  # Argument-pinned, as above: a probe of $REPO_DIR must not satisfy this.
  _is_brew_managed() { [[ "$1" != "$REPO_DIR" ]]; }
  _brew_present() { return 0; }
  _apply_brew_update() { echo "BREW_APPLY"; return 0; }
  _apply_cli_update() { echo "GIT_APPLY"; return 0; }
  _reexec_cli() { echo "REEXEC"; }
}

@test "update: a keg is offered the update and upgraded through brew" {
  _keg_prompt_setup

  run _maybe_prompt_cli_update <<< "y"
  assert_success
  assert_output --partial "Cleat update available"
  assert_output --partial "99.0.0"
  assert_output --partial "BREW_APPLY"
  assert_output --partial "REEXEC"
  # The git updater must never touch a keg.
  refute_output --partial "GIT_APPLY"
}

@test "update: a keg with no brew on PATH is never offered anything" {
  # Nothing to act on, so nothing worth interrupting a launch for.
  _keg_prompt_setup
  _brew_present() { return 1; }

  run _maybe_prompt_cli_update <<< "y"
  assert_success
  assert_output ""
  refute_output --partial "BREW_APPLY"
}

@test "update: a keg offer is not blocked by a dirty working tree" {
  # _repo_is_clean guards an auto `git checkout`. A keg has no tree to be
  # dirty, so consulting it there would silence the offer forever.
  _keg_prompt_setup
  _repo_is_clean() { return 1; }

  run _maybe_prompt_cli_update <<< "y"
  assert_success
  assert_output --partial "BREW_APPLY"
}

@test "update: a keg honours CLEAT_NO_UPDATE_CHECK like a git install" {
  _keg_prompt_setup
  export CLEAT_NO_UPDATE_CHECK=1

  run _maybe_prompt_cli_update <<< "y"
  assert_success
  assert_output ""
}

@test "update: a keg records a decline and does not re-nag for that version" {
  _keg_prompt_setup

  run _maybe_prompt_cli_update <<< "n"
  assert_success
  assert_output --partial "Cleat update available"
  refute_output --partial "BREW_APPLY"
  # The declined version is remembered in field 3, exactly as on a git install.
  run cat "$UPDATE_CHECK_FILE"
  assert_output --partial "99.0.0 99.0.0"
}

@test "update: a keg treats redirected stdin as a decline" {
  # The house rule everywhere: EOF means no, never a silent yes.
  _keg_prompt_setup

  run _maybe_prompt_cli_update < /dev/null
  assert_success
  refute_output --partial "BREW_APPLY"
  refute_output --partial "REEXEC"
}

@test "update: a keg is never nagged to downgrade" {
  _keg_prompt_setup
  export GIT_LS_REMOTE_OUTPUT="abc123	refs/tags/v0.0.1"

  run _maybe_prompt_cli_update <<< "y"
  assert_success
  assert_output ""
}

@test "update: an install with neither a repo nor a keg stays silent" {
  # A tarball or a hand-copied script has no updater at all.
  _keg_prompt_setup
  _is_brew_managed() { return 1; }   # and REPO_DIR has no .git

  run _maybe_prompt_cli_update <<< "y"
  assert_success
  assert_output ""
}

@test "update: a git checkout still uses the git updater, not brew" {
  # The control for all of the above: the existing channel is untouched.
  _keg_prompt_setup
  mkdir -p "$TEST_TEMP/.git"
  _is_brew_managed() { return 1; }
  _repo_is_clean() { return 0; }

  run _maybe_prompt_cli_update <<< "y"
  assert_success
  assert_output --partial "GIT_APPLY"
  refute_output --partial "BREW_APPLY"
}

# ── _apply_brew_update ──────────────────────────────────────────────────────

@test "update: _apply_brew_update upgrades the formula and clears the caches" {
  cat > "$TEST_TEMP/bin/brew" << 'BREWSTUB'
#!/usr/bin/env bash
echo "BREW $*"
BREWSTUB
  chmod +x "$TEST_TEMP/bin/brew"
  UPDATE_CHECK_FILE="$TEST_TEMP/update_check"
  CLAUDE_CHECK_FILE="$TEST_TEMP/claude_check"
  echo stale > "$UPDATE_CHECK_FILE"
  echo stale > "$CLAUDE_CHECK_FILE"

  run _apply_brew_update
  assert_success
  assert_output --partial "BREW upgrade cleatdev/tap/cleat"
  # Both caches cleared so the new keg is re-evaluated next launch.
  run test -f "$UPDATE_CHECK_FILE"
  assert_failure
  run test -f "$CLAUDE_CHECK_FILE"
  assert_failure
}

@test "update: _apply_brew_update returns rather than exec'ing, so the session goes on" {
  # Unlike `cleat update`, the on-start path must come BACK and re-exec, which
  # is what keeps your session alive across the upgrade.
  cat > "$TEST_TEMP/bin/brew" << 'BREWSTUB'
#!/usr/bin/env bash
echo "BREW $*"
BREWSTUB
  chmod +x "$TEST_TEMP/bin/brew"
  UPDATE_CHECK_FILE="$TEST_TEMP/update_check"
  CLAUDE_CHECK_FILE="$TEST_TEMP/claude_check"

  local cli_copy="$TEST_TEMP/cleat-brewapply.sh"
  sed 's/^set -euo pipefail$/: # stripped for this subshell/' "$CLI" > "$cli_copy"

  run bash -c 'source "$1"; UPDATE_CHECK_FILE="$2"; CLAUDE_CHECK_FILE="$3"; _apply_brew_update; echo "RETURNED rc=$?"' \
    _ "$cli_copy" "$TEST_TEMP/update_check" "$TEST_TEMP/claude_check"
  assert_success
  assert_output --partial "RETURNED rc=0"
}

@test "update: _apply_brew_update fails when brew is gone or errors" {
  _brew_present() { return 1; }
  run _apply_brew_update
  assert_failure

  cat > "$TEST_TEMP/bin/brew" << 'BREWSTUB'
#!/usr/bin/env bash
exit 1
BREWSTUB
  chmod +x "$TEST_TEMP/bin/brew"
  unset -f _brew_present
  run _apply_brew_update
  assert_failure
}

@test "state: migration also rescues state from a script install after a switch" {
  # The channel-switch case. Someone moving from a pre-1.4 script install
  # straight to a keg never launches the old install again, so its state would
  # sit orphaned in ~/.cleat. REPO_DIR here is the NEW install, which has
  # nothing; the rescue is the second source.
  REPO_DIR="$TEST_TEMP/new-install"
  CLEAT_STATE_DIR="$TEST_TEMP/newstate"
  mkdir -p "$REPO_DIR" "$HOME/.cleat"
  echo "12345 9.9.9 9.9.9" > "$HOME/.cleat/.update_check"

  run _migrate_state_files
  assert_success
  run cat "$CLEAT_STATE_DIR/update_check"
  assert_output "12345 9.9.9 9.9.9"
}

@test "state: this install's own tree wins over the script-install leftovers" {
  # Both sources present: the install being RUN is the current truth.
  REPO_DIR="$TEST_TEMP/new-install"
  CLEAT_STATE_DIR="$TEST_TEMP/newstate"
  mkdir -p "$REPO_DIR" "$HOME/.cleat"
  echo "MINE" > "$REPO_DIR/.update_check"
  echo "LEFTOVER" > "$HOME/.cleat/.update_check"

  run _migrate_state_files
  assert_success
  run cat "$CLEAT_STATE_DIR/update_check"
  assert_output "MINE"
}

@test "state: a box is the same box whichever install created it" {
  # The whole basis of a lossless switch: identity is derived from the PROJECT,
  # never from where Cleat itself lives. If this ever stops holding, switching
  # channels silently orphans every container and session.
  mkdir -p "$TEST_TEMP/proj"
  local from_git from_keg key_git key_keg

  REPO_DIR="$HOME/.cleat"
  from_git="$(container_name_for "$TEST_TEMP/proj")"
  key_git="$(_derive_project_session_key "$TEST_TEMP/proj")"

  REPO_DIR="$TEST_TEMP/hb/Cellar/cleat/9.9.9/libexec"
  from_keg="$(container_name_for "$TEST_TEMP/proj")"
  key_keg="$(_derive_project_session_key "$TEST_TEMP/proj")"

  [[ -n "$from_git" && "$from_git" == "$from_keg" ]] || {
    echo "container name differs: $from_git vs $from_keg"; return 1; }
  [[ -n "$key_git" && "$key_git" == "$key_keg" ]] || {
    echo "session key differs: $key_git vs $key_keg"; return 1; }
}

@test "state: the script-install rescue copies but never deletes" {
  # ~/.cleat can still belong to a LIVE install. Running a working copy from a
  # checkout, which is what every Cleat developer does, must not consume the
  # installed cleat's state. Only the tree actually being run is tidied up.
  REPO_DIR="$TEST_TEMP/new-install"
  CLEAT_STATE_DIR="$TEST_TEMP/newstate"
  mkdir -p "$REPO_DIR" "$HOME/.cleat"
  echo "12345 9.9.9 9.9.9" > "$HOME/.cleat/.update_check"

  run _migrate_state_files
  assert_success
  run cat "$CLEAT_STATE_DIR/update_check"
  assert_output "12345 9.9.9 9.9.9"
  # Still there: it was rescued, not taken.
  run test -f "$HOME/.cleat/.update_check"
  assert_success
}
