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

# ── Same-URL debounce (atomic per-URL marker) ─────────────────────────────────
# One user action can write the bridge file SEVERAL times (a TUI link click
# fires the open shim on press and release). The claim makes each write open
# once; the debounce makes each URL open once per window even across multiple
# writes claimed by DIFFERENT watchers: the one-click-N-tabs bug. The debounce is
# an atomic `mkdir` of a per-URL marker dir (not a read-then-write stamp), so two
# racing watchers can't both pass it. Markers self-expire by their own mtime.

@test "browser bridge: a repeat of the same URL inside the window is deduped" {
  local dir="$TEST_TEMP/clip"; mkdir -p "$dir"
  run _browser_recently_opened "$dir" "https://example.com/x"
  assert_failure   # first sighting → open it (and claim the marker)
  run _browser_recently_opened "$dir" "https://example.com/x"
  assert_success   # immediate repeat → suppressed
}

@test "browser bridge: a different URL is never debounced" {
  local dir="$TEST_TEMP/clip"; mkdir -p "$dir"
  run _browser_recently_opened "$dir" "https://example.com/x"
  assert_failure
  run _browser_recently_opened "$dir" "https://example.com/y"
  assert_failure   # distinct URL right after → still opens
}

@test "browser bridge: concurrent watchers open one URL exactly once (atomic debounce)" {
  # The one-click-TWO-tabs bug that survived the atomic claim. Two writes of the
  # SAME url (press + release) claimed by two live watchers (a login alongside a
  # session, two shells on one box, or a leaked orphan) both used to pass the old
  # read-then-write stamp before either wrote it. The atomic mkdir claim must
  # elect exactly ONE opener no matter how many fire at once. Mutation-verified
  # (mkdir → mkdir -p makes the claim non-exclusive and this fails).
  local dir="$TEST_TEMP/clip"; mkdir -p "$dir"
  local n=24 i wins
  local results="$TEST_TEMP/race_wins"; : > "$results"
  local go="$TEST_TEMP/race_go"
  for i in $(seq 1 "$n"); do
    ( while [ ! -f "$go" ]; do :; done            # barrier: maximise overlap
      if _browser_recently_opened "$dir" "https://example.com/race"; then :; else
        echo win >> "$results"                    # rc 1 = "open it" = a winner
      fi
    ) &
  done
  sleep 0.2                                        # let every racer reach the barrier
  touch "$go"
  wait
  wins="$(grep -c win "$results" 2>/dev/null)"; wins="${wins:-0}"
  [ "$wins" -eq 1 ] || { echo "expected exactly 1 opener across $n racers, got $wins"; return 1; }
}

@test "browser bridge: the same URL opens again once the window has passed" {
  local dir="$TEST_TEMP/clip"; mkdir -p "$dir"
  run _browser_recently_opened "$dir" "https://example.com/x"
  assert_failure                                   # first sighting opens, claims a marker
  local m
  for m in "$dir"/.open.*; do touch -t 200001010000 "$m" 2>/dev/null || true; done
  run _browser_recently_opened "$dir" "https://example.com/x"
  assert_failure   # marker predates the window → swept → opens again normally
}

@test "browser bridge: a leftover marker with no readable time fails open (never wedges)" {
  # A marker left in a broken state (mtime unreadable → treated as epoch 0, far
  # past the window) must be swept, never permanently suppress a URL.
  local dir="$TEST_TEMP/clip"; mkdir -p "$dir"
  local hash; hash="$(printf '%s' "https://example.com/x" | cksum)"; hash="${hash// /_}"
  mkdir -p "$dir/.open.$hash"
  touch -t 200001010000 "$dir/.open.$hash" 2>/dev/null || true
  run _browser_recently_opened "$dir" "https://example.com/x"
  assert_failure   # ancient/broken marker must never block an open
}

@test "browser bridge: the watcher consults the debounce before opening" {
  local dir="$TEST_TEMP/clip"; mkdir -p "$dir"
  _browser_recently_opened() { touch "$TEST_TEMP/debounce_consulted"; return 1; }
  cat > "$TEST_TEMP/fake_open" <<EOF
#!/usr/bin/env bash
echo "\$1" >> "$TEST_TEMP/opened.log"
EOF
  chmod +x "$TEST_TEMP/fake_open"
  _browser_watcher "$dir" "$TEST_TEMP/fake_open" "" >/dev/null 2>&1 &
  local wpid=$!
  sleep 0.7                                  # let it pass the startup rm -f
  printf '%s' "https://example.com/z" > "$dir/.browser-open"
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    [ -f "$TEST_TEMP/opened.log" ] && break
    sleep 0.5
  done
  kill "$wpid" 2>/dev/null || true
  wait "$wpid" 2>/dev/null || true
  [ -f "$TEST_TEMP/opened.log" ]        || { echo "URL never opened"; return 1; }
  [ -f "$TEST_TEMP/debounce_consulted" ] || { echo "watcher skipped the debounce"; return 1; }
}

@test "browser bridge: watcher self-exits when its spawning cleat process dies" {
  # The accumulation half of the one-click-N-tabs bug: a watcher whose cleat
  # process was SIGKILL'd (closed terminal) skips the cleanup trap and used to
  # poll forever: every crashed session added one more tab per click. The
  # liveness check reaps it within a poll tick.
  local dir="$TEST_TEMP/clip"; mkdir -p "$dir"
  cat > "$TEST_TEMP/spawner.sh" <<EOF
source "$TEST_TEMP/cli_stripped"
_browser_watcher "$dir" "true" "" >/dev/null 2>&1 &
echo "\$!" > "$TEST_TEMP/watcher_pid"
kill -9 \$\$
EOF
  sed 's/^set -euo pipefail$/:/' "$CLI" > "$TEST_TEMP/cli_stripped"
  bash "$TEST_TEMP/spawner.sh" 2>/dev/null || true
  local wpid dead=0
  wpid="$(cat "$TEST_TEMP/watcher_pid")"
  process_exited "$wpid" && dead=1
  # Unconditional reap: a live straggler holds bats' fd and hangs the file.
  kill "$wpid" 2>/dev/null || true
  [ "$dead" = 1 ] || { echo "watcher outlived its dead parent"; return 1; }
}
