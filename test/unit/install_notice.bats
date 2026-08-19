#!/usr/bin/env bats
# ── _maybe_warn_multiple_installs (on-start second-install notice) ────────────
#
# Warns on every interactive start when more than one cleat is on the machine
# (e.g. a brew keg next to a curl install), the split a bare `cleat` resolves by
# PATH order. The one-install guard only covers cleat's own installers, so this
# runtime notice is what surfaces a brew-created duplicate. Warns, never blocks.
# TTY-only, so _is_tty is false under bats (output is captured) and the
# visible-path tests force it true. Silenced by CLEAT_NO_INSTALL_CHECK=1.
# The scan (_find_cleat_installs) and the running-binary resolver
# (_resolve_physical_path) are overridden to stage the machine state.
load "../setup"
setup() {
  _common_setup
  source_cli
}
teardown() { _common_teardown; }

# Two installs, the running one at $HOME/.local/bin/cleat (phys SELF), a shadow keg.
_stub_two() {
  _find_cleat_installs() {
    printf '%s\t%s\n' "/opt/homebrew/bin/cleat" "/opt/homebrew/Cellar/cleat/1.4.1/libexec/bin/cleat"
    printf '%s\t%s\n' "$HOME/.local/bin/cleat" "SELF"
  }
}

@test "install-notice: fires and names the running install when more than one is found" {
  _is_tty() { return 0; }
  _resolve_physical_path() { echo SELF; }
  _stub_two
  run _maybe_warn_multiple_installs
  assert_success
  assert_output --partial "2 cleat installs found"
  assert_output --partial "/opt/homebrew/bin/cleat"
  assert_output --partial "$HOME/.local/bin/cleat"
  # the "running" mark must sit on the running install's row, not the shadow
  run grep -E "running.*\.local/bin/cleat" <<< "$output"
  assert_success
}

@test "install-notice: silent when there is exactly one install" {
  _is_tty() { return 0; }
  _resolve_physical_path() { echo SELF; }
  _find_cleat_installs() { printf '%s\t%s\n' "/usr/local/bin/cleat" "SELF"; }
  run _maybe_warn_multiple_installs
  assert_success
  refute_output --partial "installs found"
}

@test "install-notice: silent on a non-interactive non-TTY run" {
  # _is_tty is false under bats (output is captured), so with a two-install scan
  # the ONLY thing keeping it quiet is the TTY gate.
  _resolve_physical_path() { echo SELF; }
  _stub_two
  run _maybe_warn_multiple_installs
  assert_success
  assert_output ""
}

@test "install-notice: respects the CLEAT_NO_INSTALL_CHECK kill switch" {
  _is_tty() { return 0; }
  _resolve_physical_path() { echo SELF; }
  _stub_two
  CLEAT_NO_INSTALL_CHECK=1
  run _maybe_warn_multiple_installs
  assert_success
  assert_output ""
}

@test "install-notice: gives the brew remedy when the single shadow is a Homebrew keg" {
  _is_tty() { return 0; }
  _resolve_physical_path() { echo "$HOME/.cleat/bin/cleat"; }   # running = a git install
  _find_cleat_installs() {
    printf '%s\t%s\n' "$HOME/.local/bin/cleat" "$HOME/.cleat/bin/cleat"
    printf '%s\t%s\n' "/opt/homebrew/bin/cleat" "/opt/homebrew/Cellar/cleat/1.4.1/libexec/bin/cleat"
  }
  run _maybe_warn_multiple_installs
  assert_success
  # the single-shadow keg branch, not the generic 3+/edge line (prose and the
  # command are asserted apart: an ANSI bold code sits between them)
  assert_output --partial "Remove the one you are not using:"
  assert_output --partial "brew uninstall cleatdev/tap/cleat"
  refute_output --partial "Remove one:"
  assert_output --partial "Homebrew"
  assert_output --partial "git"
}

@test "install-notice: gives the rm remedy when the single shadow is a git or script install" {
  _is_tty() { return 0; }
  _resolve_physical_path() { echo "/opt/homebrew/Cellar/cleat/1.4.1/libexec/bin/cleat"; }   # running = keg
  _find_cleat_installs() {
    printf '%s\t%s\n' "/opt/homebrew/bin/cleat" "/opt/homebrew/Cellar/cleat/1.4.1/libexec/bin/cleat"
    printf '%s\t%s\n' "$HOME/.local/bin/cleat" "$HOME/.cleat/bin/cleat"
  }
  run _maybe_warn_multiple_installs
  assert_success
  assert_output --partial "Remove the one you are not using:"
  assert_output --partial "rm $HOME/.local/bin/cleat"
  refute_output --partial "Remove one:"
}
