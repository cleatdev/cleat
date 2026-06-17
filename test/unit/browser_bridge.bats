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

# ── No-duplicate bridge policy (CLEAT_BROWSER_BRIDGE) ──────────────────────────
# A clicked link is opened by the HOST TERMINAL itself (it makes URLs clickable);
# the in-container `open` shim ALSO writes the bridge, so the watcher opening it
# again is a second tab ~0.5s later. The watcher cannot see the terminal's open,
# so on an interactive terminal it DEFERS plain links to the terminal. Auth URLs
# (a localhost OAuth callback the user never clicks) and non-interactive sessions
# (nothing else opens them) always open via the bridge. CLEAT_BROWSER_BRIDGE
# overrides: always = open everything (pre-toggle behavior), off = open nothing.

@test "bridge mode: defaults to auto when unset" {
  unset CLEAT_BROWSER_BRIDGE
  run _browser_bridge_mode
  assert_output "auto"
}

@test "bridge mode: honors always and off, and falls back to auto on a typo" {
  CLEAT_BROWSER_BRIDGE=always run _browser_bridge_mode
  assert_output "always"
  CLEAT_BROWSER_BRIDGE=off run _browser_bridge_mode
  assert_output "off"
  CLEAT_BROWSER_BRIDGE=banana run _browser_bridge_mode    # unknown never wedges
  assert_output "auto"
}

@test "bridge policy: auto DEFERS a plain link on an interactive terminal (no duplicate)" {
  # mode=auto, host_opens_clicks=1, is_auth=0 -> the terminal owns it -> defer.
  run _browser_should_open auto 1 0
  assert_failure
}

@test "bridge policy: auto OPENS an auth URL even on an interactive terminal" {
  # The user never clicks an auth URL; the bridge + callback proxy own it.
  run _browser_should_open auto 1 1
  assert_success
}

@test "bridge policy: auto OPENS a plain link when no terminal is attached" {
  # Off a TTY (piped, scripted) nothing else opens the link, so the bridge must.
  run _browser_should_open auto 0 0
  assert_success
}

@test "bridge policy: always opens every URL; off opens none" {
  run _browser_should_open always 1 0   # plain + interactive: forced open
  assert_success
  run _browser_should_open always 0 0
  assert_success
  run _browser_should_open off 0 1      # even an auth URL: off opens nothing
  assert_failure
  run _browser_should_open off 0 0
  assert_failure
}

@test "browser bridge: auto mode does NOT re-open a plain link the terminal handled" {
  # Integration: drive the real watcher loop with an interactive terminal flag.
  # The plain link must never reach the opener (the visible duplicate tab).
  local dir="$TEST_TEMP/clip"; mkdir -p "$dir"
  cat > "$TEST_TEMP/fake_open" <<EOF
#!/usr/bin/env bash
echo "\$1" >> "$TEST_TEMP/opened.log"
EOF
  chmod +x "$TEST_TEMP/fake_open"
  # cname="" so the auth branch is skipped (is_auth stays 0); host_opens_clicks=1.
  _browser_watcher "$dir" "$TEST_TEMP/fake_open" "" "auto" "1" >/dev/null 2>&1 &
  local wpid=$!
  sleep 0.7                                  # let it pass the startup rm -f
  printf '%s' "https://example.com/plain" > "$dir/.browser-open"
  sleep 2                                    # several poll cycles
  kill -0 "$wpid" 2>/dev/null || { echo "watcher died before the assertion"; return 1; }
  kill "$wpid" 2>/dev/null || true
  wait "$wpid" 2>/dev/null || true
  [ ! -f "$TEST_TEMP/opened.log" ] || { echo "bridge re-opened a plain link the terminal already opened"; return 1; }
}

@test "browser bridge: auto mode still opens an auth URL on an interactive terminal" {
  local dir="$TEST_TEMP/clip"; mkdir -p "$dir"
  _extract_callback_port() { echo "1455"; return 0; }   # force the auth branch
  _auth_callback_proxy() { :; }                          # never start a real proxy
  cat > "$TEST_TEMP/fake_open" <<EOF
#!/usr/bin/env bash
echo "\$1" >> "$TEST_TEMP/opened.log"
EOF
  chmod +x "$TEST_TEMP/fake_open"
  _browser_watcher "$dir" "$TEST_TEMP/fake_open" "mybox" "auto" "1" >/dev/null 2>&1 &
  local wpid=$!
  sleep 0.7
  printf '%s' "https://claude.ai/oauth?redirect_uri=x" > "$dir/.browser-open"
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    [ -f "$TEST_TEMP/opened.log" ] && break
    sleep 0.5
  done
  kill "$wpid" 2>/dev/null || true
  wait "$wpid" 2>/dev/null || true
  [ -f "$TEST_TEMP/opened.log" ] || { echo "auth URL was not opened by the bridge"; return 1; }
}

@test "browser bridge: off mode opens nothing yet still starts the auth proxy (login works)" {
  # off withholds every browser open, even an auth URL, but the OAuth callback
  # proxy must STILL start so `cleat login` completes when the URL is opened by
  # hand. The proxy is started before the open gate, so it runs in every mode.
  local dir="$TEST_TEMP/clip"; mkdir -p "$dir"
  _extract_callback_port() { echo "1455"; return 0; }   # force the auth branch
  _auth_callback_proxy() { touch "$TEST_TEMP/proxy_started"; }
  cat > "$TEST_TEMP/fake_open" <<EOF
#!/usr/bin/env bash
echo "\$1" >> "$TEST_TEMP/opened.log"
EOF
  chmod +x "$TEST_TEMP/fake_open"
  _browser_watcher "$dir" "$TEST_TEMP/fake_open" "mybox" "off" "1" >/dev/null 2>&1 &
  local wpid=$!
  sleep 0.7
  printf '%s' "https://claude.ai/oauth?redirect_uri=x" > "$dir/.browser-open"
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    [ -f "$TEST_TEMP/proxy_started" ] && break
    sleep 0.5
  done
  sleep 1                                                # give any (wrong) open a chance to land
  kill "$wpid" 2>/dev/null || true
  wait "$wpid" 2>/dev/null || true
  [ -f "$TEST_TEMP/proxy_started" ] || { echo "off mode did not start the auth proxy; cleat login would hang"; return 1; }
  [ ! -f "$TEST_TEMP/opened.log" ] || { echo "off mode opened a browser; it must suppress every open"; return 1; }
}
