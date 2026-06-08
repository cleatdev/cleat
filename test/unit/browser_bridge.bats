#!/usr/bin/env bats
# ── Browser bridge (_browser_claim_url) ───────────────────────────────────────
#
# The host-side watcher forwards URLs written by the container's open-bridge shim
# to the host browser. Each pending URL must be opened EXACTLY ONCE even when
# several watchers are alive on the same bridge dir (an orphan left by a crashed
# session plus the current one). `_browser_claim_url` enforces that with an atomic
# rename: whoever wins the `mv` opens the URL; everyone else gets nothing.
load "../setup"
setup() {
  _common_setup
  source_cli
  BRIDGE="$TEST_TEMP/.browser-open"
}
teardown() { _common_teardown; }

@test "browser bridge: claims a pending URL and consumes the file" {
  printf '%s\n' "https://example.com/x" > "$BRIDGE"
  run _browser_claim_url "$BRIDGE"
  assert_success
  assert_output "https://example.com/x"
  [ ! -f "$BRIDGE" ]  || return 1   # file consumed
}

@test "browser bridge: returns nonzero when there is nothing to claim" {
  run _browser_claim_url "$BRIDGE"   # no file exists
  assert_failure
  assert_output ""
}

@test "browser bridge: a URL is claimed by exactly ONE of two racing watchers" {
  printf '%s\n' "https://example.com/once" > "$BRIDGE"
  # First watcher wins the claim.
  run _browser_claim_url "$BRIDGE"
  assert_success
  assert_output "https://example.com/once"
  # Second watcher (the orphan) finds nothing → one host tab, not two.
  run _browser_claim_url "$BRIDGE"
  assert_failure
  assert_output ""
}

@test "browser bridge: consuming an empty bridge file is harmless" {
  : > "$BRIDGE"   # empty file
  run _browser_claim_url "$BRIDGE"
  assert_success
  assert_output ""
  [ ! -f "$BRIDGE" ]  || return 1
}

@test "browser bridge: leaves no .opening temp file behind" {
  printf '%s\n' "https://example.com/y" > "$BRIDGE"
  _browser_claim_url "$BRIDGE" >/dev/null
  run bash -c "ls \"$TEST_TEMP\"/.browser-open.opening.* 2>/dev/null"
  assert_output ""
}

@test "browser bridge: watcher self-exits when its run dir is removed (orphan cleanup)" {
  # The fix's anti-orphan half: a watcher left behind by a crashed session must
  # stop polling once its run dir is gone (cleat rm/clean/nuke), instead of
  # spinning forever and re-opening URLs. Delete the `[ -d "$clip_dir" ]` guard
  # in _browser_watcher and this test fails (mutation-verified).
  local clip_dir="$TEST_TEMP/clip"
  mkdir -p "$clip_dir"
  _browser_watcher "$clip_dir" "true" "" >/dev/null 2>&1 &
  local wpid=$!
  sleep 1.5                                   # let it enter the poll loop
  kill -0 "$wpid" 2>/dev/null  || { echo "watcher exited prematurely"; return 1; }
  rm -rf "$clip_dir"                           # session removed → orphan must stop
  local i alive=1
  for i in 1 2 3 4 5 6 7 8 9 10; do
    if ! kill -0 "$wpid" 2>/dev/null; then alive=0; break; fi
    sleep 0.5
  done
  [ "$alive" = 1 ] && kill "$wpid" 2>/dev/null
  [ "$alive" = 0 ]  || { echo "watcher kept spinning after clip_dir removal"; return 1; }
}

@test "browser bridge: two distinct URLs both open (no same-second drop)" {
  # The old mtime-second dedup dropped a 2nd URL written in the same wall-clock
  # second. Consuming the file removes that failure mode: both are claimable.
  printf '%s\n' "https://example.com/a" > "$BRIDGE"
  run _browser_claim_url "$BRIDGE"
  assert_output "https://example.com/a"
  printf '%s\n' "https://example.com/b" > "$BRIDGE"   # same second in a fast test
  run _browser_claim_url "$BRIDGE"
  assert_output "https://example.com/b"
}
