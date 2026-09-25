#!/usr/bin/env bats
# Tests for clipboard bridge: _clipboard_watcher and cleanup logic

load "../setup"

setup() {
  _common_setup
  source_cli
}

teardown() { _common_teardown; }

# ── _clipboard_watcher ──────────────────────────────────────────────────────

@test "_clipboard_watcher announces readiness from inside the box, as coder" {
  # The sentinel sits in the box's read-write clip mount, where a link renamed
  # over it at the right instant had the host's touch create or re-stamp a file
  # of the box's choosing. The host no longer writes it at all: one docker exec
  # as coder runs the readiness script inside the box.
  use_docker_stub
  local clip_dir="$TEST_TEMP/clip"
  mkdir -p "$clip_dir"

  _clipboard_watcher "$clip_dir" "true" test-ann >/dev/null 2>&1 &
  local pid=$! i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    grep -q '/tmp/cleat-clip/.host-ready$' "$DOCKER_CALLS" 2>/dev/null && break
    sleep 0.3
  done
  stop_watcher "$pid" "$clip_dir"

  run grep -cxF "docker exec -u coder test-ann sh -c $_CLIP_READY_SH sh /tmp/cleat-clip/.host-ready" "$DOCKER_CALLS"
  assert_output "1"
  [ ! -e "$clip_dir/.host-ready" ] || { echo "the host wrote the sentinel itself"; return 1; }
}

@test "readiness is retried while the box cannot write the clip dir yet" {
  # An exec that lands before the entrypoint remaps coder runs as the image's
  # uid, which cannot write a host-owned clip dir on Linux with another host uid
  # or on a rootless engine. One failed attempt must not cost the session its
  # file bridge.
  use_docker_stub
  export DOCKER_EXIT_CODE=1
  run _clip_announce_ready test-retry
  assert_success
  run grep -c '^docker exec -u coder test-retry ' "$DOCKER_CALLS"
  assert_output "3"
}

@test "the in-box readiness script turns any shape at .host-ready into a regular file" {
  # _clip_announce_ready runs this inside the box. Whatever the box left at the
  # name, it ends as a regular file, a link is never followed and a FIFO never
  # blocks. A regular file already there is left as it is.
  local d="$TEST_TEMP/shapes"
  mkdir -p "$d/dir/sub"
  echo junk > "$d/dir/sub/f"
  ln -s "$TEST_TEMP/dangling-target" "$d/dangling"
  echo keep > "$TEST_TEMP/linked"
  ln -s "$TEST_TEMP/linked" "$d/tofile"
  mkfifo "$d/fifo"
  echo existing > "$d/regular"
  local shape
  for shape in absent dir dangling tofile fifo regular; do
    _portable_timeout 5 sh -c "$_CLIP_READY_SH" sh "$d/$shape" </dev/null >/dev/null 2>&1 || true
    [ -f "$d/$shape" ] && [ ! -L "$d/$shape" ] || {
      echo "shape '$shape' is not a regular file at the sentinel afterwards"; ls -la "$d"; return 1; }
  done
  [ ! -e "$TEST_TEMP/dangling-target" ] || { echo "the script followed a dangling link"; return 1; }
  run cat "$TEST_TEMP/linked"
  assert_output "keep"
  run cat "$d/regular"
  assert_output "existing"
}

@test "exec_claude hands its watcher the box name and keeps its marker outside the clip mount" {
  # The marker used to be touched in the clip mount, under a name the box could
  # predict from the markers it saw there, so a link planted at it had the host
  # touch any file. It lives in the host-only clipwatch/ sibling now.
  use_docker_stub
  _host_clip_cmd() { echo "true"; }
  _host_open_cmd() { echo ""; }
  export CLEAT_NO_CLIPBOARD_IMAGE=1
  _clipboard_watcher() { printf '%s' "$3" > "$TEST_TEMP/seen-cname"; }
  # Runs synchronously right after the watcher spawn, before any teardown, so
  # what it lists is where the live session keeps its marker.
  _clipimg_remove_shim() {
    ls -a "$CLEAT_RUN_DIR/test-wmark/clip" > "$TEST_TEMP/seen-clip" 2>&1
    ls -a "$CLEAT_RUN_DIR/test-wmark/clipwatch" > "$TEST_TEMP/seen-watch" 2>&1
  }
  run exec_claude test-wmark --dangerously-skip-permissions
  assert_success
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    [ -s "$TEST_TEMP/seen-cname" ] && break
    sleep 0.2
  done
  run cat "$TEST_TEMP/seen-cname"
  assert_output "test-wmark"
  run grep -c '^\.watcher\.' "$TEST_TEMP/seen-clip"
  assert_output "0"
  run grep -cxF ".watcher.$$" "$TEST_TEMP/seen-watch"
  assert_output "1"
}

@test "_clipboard_watcher from a dead cleat process never copies (orphan guard)" {
  # A watcher whose cleat process was SIGKILL'd must not keep writing a dead
  # session's box clipboard over the host clipboard. The liveness check sits
  # at the copy choke point, so this holds in all three watch modes.
  local clip_dir="$TEST_TEMP/clip"
  mkdir -p "$clip_dir"
  sed 's/^set -euo pipefail$/:/' "$CLI" > "$TEST_TEMP/cli_stripped"
  cat > "$TEST_TEMP/clip_spawner.sh" <<EOF
source "$TEST_TEMP/cli_stripped"
_clipboard_watcher "$clip_dir" "touch '$TEST_TEMP/copied'" >/dev/null 2>&1 &
echo "\$!" > "$TEST_TEMP/clip_watcher_pid"
kill -9 \$\$
EOF
  bash "$TEST_TEMP/clip_spawner.sh" 2>/dev/null || true
  sleep 0.3
  # Deliver a clipboard write the way the box does (mv → fires moved_to too)
  echo "stolen" > "$TEST_TEMP/payload"
  mv "$TEST_TEMP/payload" "$clip_dir/clipboard"
  local wpid
  wpid="$(cat "$TEST_TEMP/clip_watcher_pid")"
  process_exited "$wpid" || true
  # Unconditional reap: a live straggler holds bats' fd and hangs the file.
  kill "$wpid" 2>/dev/null || true
  [ ! -f "$TEST_TEMP/copied" ] || { echo "orphan watcher copied a dead session's clipboard"; return 1; }
}

@test "_clipboard_watcher delivers a fresh copy once and consumes the payload" {
  local clip_dir="$TEST_TEMP/clip"
  mkdir -p "$clip_dir"

  _clipboard_watcher "$clip_dir" "cat >> '$TEST_TEMP/copied'" >/dev/null 2>&1 &
  local pid=$!
  sleep 0.3
  # Deliver a clipboard write the way the box shim does (mv → fires moved_to)
  echo "fresh-copy" > "$TEST_TEMP/payload"
  mv "$TEST_TEMP/payload" "$clip_dir/clipboard"
  sleep 2
  stop_watcher "$pid" "$clip_dir"

  run cat "$TEST_TEMP/copied"
  assert_success
  assert_output "fresh-copy"
  # Delivered means claimed: the payload must not remain on disk for a later
  # session's watcher to replay.
  [ ! -f "$clip_dir/clipboard" ] || { echo "payload not consumed on delivery"; return 1; }
}

@test "_clipboard_watcher claims live outside the .clipboard.* cleanup namespace" {
  # Every session's exit sweep runs rm -f on .clipboard.* in the SHARED clip
  # dir, so a claim named inside that namespace can be deleted by a sibling
  # session exiting mid-delivery (the copy is silently lost). The claim must
  # live under .claim.* instead. The snoop clip command records the claim
  # path at the moment of delivery, while the claim file exists.
  #
  # The claim also moved OUT of the shared dir entirely (into a clipclaim/
  # sibling) to close the symlink-swap window, so look for it there. The
  # namespace property this test guards is unchanged: still .claim.*, still
  # never .clipboard.*.
  local clip_dir="$TEST_TEMP/clip"
  mkdir -p "$clip_dir"

  _clipboard_watcher "$clip_dir" "ls '$TEST_TEMP'/clipclaim/.claim.* >> '$TEST_TEMP/claims-seen' 2>/dev/null; cat > '$TEST_TEMP/copied'" >/dev/null 2>&1 &
  local pid=$!
  sleep 0.3
  echo "payload" > "$TEST_TEMP/payload"
  mv "$TEST_TEMP/payload" "$clip_dir/clipboard"
  sleep 2
  stop_watcher "$pid" "$clip_dir"

  run cat "$TEST_TEMP/copied"
  assert_success
  assert_output "payload"
  [ -s "$TEST_TEMP/claims-seen" ] || { echo "no .claim.* file existed at delivery time (claim is misnamed)"; return 1; }
  run grep -c "/\.claim\." "$TEST_TEMP/claims-seen"
  assert_success
}

@test "claim dir: a link at clipclaim is refused, never used" {
  # The watchers rename box-written names into this directory. A link there
  # would send them wherever it points, so it is refused like a missing one,
  # and the bridge that needed it stays off.
  mkdir -p "$TEST_TEMP/lk" "$TEST_TEMP/elsewhere"
  ln -s "$TEST_TEMP/elsewhere" "$TEST_TEMP/lk/clipclaim"
  run _host_claim_dir "$TEST_TEMP/lk/clip"
  assert_failure
  assert_output ""
  # A missing one is created, and its path is the one the watchers use.
  run _host_claim_dir "$TEST_TEMP/ok/clip"
  assert_success
  assert_output "$TEST_TEMP/ok/clipclaim"
  run test -d "$TEST_TEMP/ok/clipclaim"
  assert_success
}

# ── exec_claude teardown: the marker and the sentinel ───────────────────────
# These drive exec_claude's real _cleanup_session. They used to define their own
# copy of the teardown inline and test that, so they passed whatever the real
# code did.

_teardown_stubs() {
  use_docker_stub
  _host_clip_cmd() { echo "true"; }
  _host_open_cmd() { echo ""; }
  _clipboard_watcher() { :; }
  export CLEAT_NO_CLIPBOARD_IMAGE=1
}

@test "cleanup removes session marker" {
  _teardown_stubs
  run exec_claude test-tdm --dangerously-skip-permissions
  assert_success
  [ -d "$CLEAT_RUN_DIR/test-tdm/clipwatch" ] || { echo "the session never made its marker dir"; return 1; }
  # The marker names this shell's pid, which is alive, so only the teardown's
  # own unlink can remove it.
  [ ! -e "$CLEAT_RUN_DIR/test-tdm/clipwatch/.watcher.$$" ] || {
    echo "the session left its own marker behind"; return 1; }
}

@test "cleanup removes sentinel when last session exits" {
  _teardown_stubs
  mkdir -p "$CLEAT_RUN_DIR/test-tds/clip"
  : > "$CLEAT_RUN_DIR/test-tds/clip/.host-ready"
  run exec_claude test-tds --dangerously-skip-permissions
  assert_success
  [ ! -e "$CLEAT_RUN_DIR/test-tds/clip/.host-ready" ] || {
    echo "the last session out left the sentinel on, so copies go to a bridge nobody reads"; return 1; }
}

@test "cleanup keeps sentinel when other sessions remain" {
  _teardown_stubs
  mkdir -p "$CLEAT_RUN_DIR/test-tdk/clip" "$CLEAT_RUN_DIR/test-tdk/clipwatch"
  : > "$CLEAT_RUN_DIR/test-tdk/clip/.host-ready"
  # A live sibling session, backed by a real process so the dead-marker sweep
  # keeps its marker.
  sleep 30 &
  local sib=$!
  : > "$CLEAT_RUN_DIR/test-tdk/clipwatch/.watcher.$sib"
  run exec_claude test-tdk --dangerously-skip-permissions
  kill "$sib" 2>/dev/null || true; wait "$sib" 2>/dev/null || true
  assert_success
  [ -f "$CLEAT_RUN_DIR/test-tdk/clip/.host-ready" ] || {
    echo "a sibling's live bridge lost its sentinel"; return 1; }
  [ -e "$CLEAT_RUN_DIR/test-tdk/clipwatch/.watcher.$sib" ] || {
    echo "the teardown removed a live sibling's marker"; return 1; }
}

# ── Clipboard priority (already in clipboard_detect.bats, but verify the
#    integration: exec_claude skips watcher when no clip command found) ──────

@test "exec_claude skips clipboard watcher when no clip command available" {
  use_docker_stub

  # Override _host_clip_cmd to simulate no clipboard
  _host_clip_cmd() { echo ""; }

  local clip_dir="$CLEAT_RUN_DIR/test-noclip/clip"
  rm -rf "$clip_dir"

  run exec_claude "test-noclip" --dangerously-skip-permissions

  # No .host-ready sentinel should exist (watcher was never started)
  [[ ! -f "$clip_dir/.host-ready" ]]  || return 1
  rm -rf "$clip_dir"
}

@test "clipboard delivery: the host caps an oversized payload at the documented 100KB" {
  # docker/clip caps what the SHIM writes, but the shim is not the only thing
  # that can put a file in the shared clip dir, and cli/README states the limit
  # as a fact about the bridge.
  local clip_dir="$TEST_TEMP/clip"; mkdir -p "$clip_dir"
  local out="$TEST_TEMP/pasted"
  _clipboard_watcher "$clip_dir" "cat > '$TEST_TEMP/pasted'" >/dev/null 2>&1 &
  local wpid=$!
  sleep 0.3
  # Deliver the way the box shim does: mv, so the inotify branch fires too.
  head -c 200000 /dev/zero | tr '\0' 'z' > "$TEST_TEMP/big-payload"
  mv "$TEST_TEMP/big-payload" "$clip_dir/clipboard"
  local i
  for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
    [ -s "$out" ] && break
    sleep 0.3
  done
  stop_watcher "$wpid" "$clip_dir"
  [ -s "$out" ] || { echo "nothing was delivered to the host clipboard"; return 1; }
  local sz; sz="$(wc -c < "$out" | tr -d '[:space:]')"
  [ "$sz" -eq 102400 ] || { echo "host delivered $sz bytes, expected the 102400 cap"; return 1; }
}

@test "clipboard delivery: a small payload still arrives byte-identical" {
  local clip_dir="$TEST_TEMP/clip"; mkdir -p "$clip_dir"
  local out="$TEST_TEMP/pasted-small"
  _clipboard_watcher "$clip_dir" "cat > '$TEST_TEMP/pasted-small'" >/dev/null 2>&1 &
  local wpid=$!
  sleep 0.3
  printf 'hello from the cage' > "$TEST_TEMP/small-payload"
  mv "$TEST_TEMP/small-payload" "$clip_dir/clipboard"
  local i
  for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
    [ -s "$out" ] && break
    sleep 0.3
  done
  stop_watcher "$wpid" "$clip_dir"
  run cat "$out"
  assert_output "hello from the cage"
}

@test "clipboard delivery: a directory planted as the payload is dropped and a later copy still lands" {
  # The box can name a directory `clipboard`. The claim move succeeds, the
  # symlink drop passes it, and `wc -c` on it fails: under the binary's set -e
  # that failed substitution killed the watcher. It must be dropped instead.
  local clip_dir="$TEST_TEMP/clip"; mkdir -p "$clip_dir"
  _clipboard_watcher "$clip_dir" "cat > '$TEST_TEMP/after-dir'" >/dev/null 2>&1 &
  local wpid=$!
  sleep 0.3
  mkdir "$TEST_TEMP/junkdir"
  mv "$TEST_TEMP/junkdir" "$clip_dir/clipboard"
  sleep 1.5
  [ -z "$(ls -A "$TEST_TEMP/clipclaim" 2>/dev/null)" ] || {
    echo "the directory lingers in the claim dir"; ls -la "$TEST_TEMP/clipclaim"; return 1; }
  printf 'later' > "$TEST_TEMP/p2"
  mv "$TEST_TEMP/p2" "$clip_dir/clipboard"
  local i
  for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
    [ -s "$TEST_TEMP/after-dir" ] && break
    sleep 0.3
  done
  stop_watcher "$wpid" "$clip_dir"
  run cat "$TEST_TEMP/after-dir"
  assert_output "later"
}
