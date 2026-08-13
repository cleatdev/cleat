#!/usr/bin/env bats
# ─────────────────────────────────────────────────────────────────────────────
# Native ctrl+v image paste: the in-box shim.
#
# The shim runs INSIDE the box, not in the CLI, so per rule 7 these tests
# execute the emitted script directly with its three absolute paths rewritten
# into $TEST_TEMP. The original is never modified.
#
# The contract it must satisfy is Claude Code's, extracted verbatim from the
# 2.1.227 bundle:
#   checkImage: xclip -selection clipboard -t TARGETS -o | grep -E "image/(png|jpeg|jpg|gif|webp|bmp)"
#   saveImage:  xclip -selection clipboard -t image/png -o > FILE
# ─────────────────────────────────────────────────────────────────────────────

load "../setup"

setup() {
  _common_setup
  source_cli

  CLIPDIR="$TEST_TEMP/cleat-clip"
  BOXDIR="$HOME/.cleat-clipimg"
  REALXC="$TEST_TEMP/real-xclip"
  mkdir -p "$CLIPDIR"

  # A stand-in for the copy shim, so delegation is observable.
  cat > "$REALXC" << EOF
#!/bin/sh
echo "DELEGATED:\$*" >> "$TEST_TEMP/delegated"
exit 0
EOF
  chmod +x "$REALXC"

  SHIM="$TEST_TEMP/xclip"
  _clipimg_emit "$SHIM"
  # Rewrite the three absolute paths. HOME is already sandboxed by _common_setup,
  # so $D lands inside the test dir on its own.
  sed -i.bak \
    -e "s@^REQ=.*@REQ=$CLIPDIR/.image-req@" \
    -e "s@^LOCK=.*@LOCK=$CLIPDIR/.image-lock@" \
    -e "s@^REAL=.*@REAL=$REALXC@" \
    "$SHIM"
  rm -f "$SHIM.bak"
  chmod +x "$SHIM"
}

teardown() { _common_teardown; }

# A host that answers one request: consume the marker, deliver, signal done.
_fake_host() {
  local payload="$1"
  (
    local i=0
    while [ ! -e "$CLIPDIR/.image-req" ]; do
      i=$((i + 1)); [ "$i" -gt 60 ] && exit 0
      sleep 0.05
    done
    rm -f "$CLIPDIR/.image-req"
    mkdir -p "$BOXDIR"
    if [ -n "$payload" ]; then printf '%s' "$payload" > "$BOXDIR/in.png"; else : > "$BOXDIR/in.png"; fi
    : > "$BOXDIR/in.done"
  ) &
}

# ── delegation: everything that is not an image read behaves as before ──────

@test "clipimg shim: copy mode delegates to the real shim" {
  echo hi | "$SHIM" -selection clipboard
  run cat "$TEST_TEMP/delegated"
  assert_output --partial "DELEGATED:-selection clipboard"
}

@test "clipimg shim: a bare -o text read delegates, it never asks the host" {
  run "$SHIM" -o
  assert_success
  [ -s "$TEST_TEMP/delegated" ] || { echo "text read did not delegate"; return 1; }
  [ ! -e "$CLIPDIR/.image-req" ] || { echo "a text read raised an image request"; return 1; }
}

@test "clipimg shim: an explicit text target delegates and asks nothing" {
  run "$SHIM" -selection clipboard -t text/plain -o
  assert_success
  [ ! -e "$CLIPDIR/.image-req" ] || { echo "text/plain raised an image request"; return 1; }
}

# ── the check leg ───────────────────────────────────────────────────────────

@test "clipimg shim: with no host listening it gives up instead of hanging" {
  # The single most important property: a shim that blocks forever hangs the
  # paste for the life of the session. Nothing consumes the marker here.
  local start end
  start="$(date +%s)"
  run "$SHIM" -selection clipboard -t TARGETS -o
  end="$(date +%s)"
  assert_failure
  assert_output ""
  [ $((end - start)) -le 4 ] || { echo "took $((end - start))s, should give up in ~1.2s"; return 1; }
  # And it tidies up, so the next press is not blocked by its own lock.
  [ ! -e "$CLIPDIR/.image-req" ]  || { echo "left its request behind"; return 1; }
  [ ! -e "$CLIPDIR/.image-lock" ] || { echo "left its lock behind"; return 1; }
}

@test "clipimg shim: a served image makes the check leg report image/png" {
  _fake_host "PNGBYTES"
  run "$SHIM" -selection clipboard -t TARGETS -o
  assert_success
  # Claude Code greps this output for image/(png|jpeg|...), so the exact token
  # matters more than anything else the shim prints.
  assert_output "image/png"
  run bash -c "printf '%s' \"\$(cat '$BOXDIR/cache.png' 2>/dev/null)\""
  assert_output "PNGBYTES"
}

@test "clipimg shim: the host's empty answer is a miss, not an empty attachment" {
  _fake_host ""
  run "$SHIM" -selection clipboard -t TARGETS -o
  assert_failure
  assert_output ""
}

# ── the save leg ────────────────────────────────────────────────────────────

@test "clipimg shim: the save leg emits the cached bytes and consumes them" {
  mkdir -p "$BOXDIR"
  printf 'REALPNGDATA' > "$BOXDIR/cache.png"
  run "$SHIM" -selection clipboard -t image/png -o
  assert_success
  assert_output "REALPNGDATA"
  # Consume-on-read: a second save must not re-attach the same image.
  [ ! -e "$BOXDIR/cache.png" ] || { echo "cache survived the save leg"; return 1; }
  run "$SHIM" -selection clipboard -t image/png -o
  assert_failure
  assert_output ""
}

@test "clipimg shim: the save leg fails when nothing was cached" {
  run "$SHIM" -selection clipboard -t image/png -o
  assert_failure
  assert_output ""
}

@test "clipimg shim: a stale cache cannot survive into the next check" {
  # Every check leg clears the cache first, so an abandoned delivery from an
  # earlier press can never be attached later.
  mkdir -p "$BOXDIR"
  printf 'STALE' > "$BOXDIR/cache.png"
  run "$SHIM" -selection clipboard -t TARGETS -o
  assert_failure
  [ ! -e "$BOXDIR/cache.png" ] || { echo "stale cache survived a failed check"; return 1; }
}

# ── argument spellings ──────────────────────────────────────────────────────

@test "clipimg shim: every output spelling reaches the image path" {
  # xclip accepts -o, -out, -output and the double-dash forms. Missing one
  # would send that spelling to the real shim and silently break the paste.
  local spelling
  for spelling in -o -out -output --out --output; do
    rm -f "$CLIPDIR/.image-req" "$BOXDIR/cache.png"
    rm -rf "$CLIPDIR/.image-lock"
    mkdir -p "$BOXDIR"
    printf 'X' > "$BOXDIR/cache.png"
    run "$SHIM" -selection clipboard -t image/png "$spelling"
    assert_success
    assert_output "X"
  done
}

@test "clipimg shim: the joined -timage/png spelling is understood" {
  mkdir -p "$BOXDIR"
  printf 'JOINED' > "$BOXDIR/cache.png"
  run "$SHIM" -selection clipboard -timage/png -o
  assert_success
  assert_output "JOINED"
}

@test "clipimg shim: -target is a target flag, not an output flag" {
  mkdir -p "$BOXDIR"
  printf 'Y' > "$BOXDIR/cache.png"
  run "$SHIM" -selection clipboard -target image/png -o
  assert_success
  assert_output "Y"
}

# ── the host side: serve and watcher ────────────────────────────────────────
#
# A capturing docker fake, so the tests can inspect the exact bytes that would
# reach the box. The real docker stub only records argv, and serve deletes its
# staging file, so neither alone can prove what was delivered.
_use_capturing_docker() {
  mkdir -p "$TEST_TEMP/bin" "$TEST_TEMP/captured"
  cat > "$TEST_TEMP/bin/docker" << EOF
#!/bin/sh
if [ "\$1" = "cp" ]; then
  dest="\$3"; name="\${dest##*/}"
  cp "\$2" "$TEST_TEMP/captured/\$name" 2>/dev/null
fi
echo "\$@" >> "$TEST_TEMP/docker-argv"
exit 0
EOF
  chmod +x "$TEST_TEMP/bin/docker"
  export PATH="$TEST_TEMP/bin:$PATH"
}

@test "clipimg serve: a valid image is delivered as in.png then in.done" {
  _use_capturing_docker
  _host_clip_read_image() { printf '\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDRpix' > "$1"; return 0; }
  _clipimg_serve "abox" "$TEST_TEMP/stage"

  run bash -c "printf '%s' \"\$(cat '$TEST_TEMP/captured/in.png')\""
  assert_output --partial "IHDRpix"
  [ -e "$TEST_TEMP/captured/in.done" ] || { echo "no in.done delivered"; return 1; }
  # in.png must be copied before in.done, or the shim could read a half image.
  run cat "$TEST_TEMP/docker-argv"
  local png_line done_line
  png_line="$(grep -n 'in.png' "$TEST_TEMP/docker-argv" | head -1 | cut -d: -f1)"
  done_line="$(grep -n 'in.done' "$TEST_TEMP/docker-argv" | head -1 | cut -d: -f1)"
  [ "$png_line" -lt "$done_line" ] || { echo "in.done was copied before in.png"; return 1; }
}

@test "clipimg serve: no image still answers, with an EMPTY in.png" {
  # The always-answer property. Without it the shim waits out its full timeout
  # on every text paste. The box reads an empty in.png as a miss.
  _use_capturing_docker
  _host_clip_read_image() { return 1; }
  _clipimg_serve "abox" "$TEST_TEMP/stage"

  [ -e "$TEST_TEMP/captured/in.png" ]  || { echo "serve did not answer at all"; return 1; }
  [ -e "$TEST_TEMP/captured/in.done" ] || { echo "no in.done on the miss path"; return 1; }
  [ ! -s "$TEST_TEMP/captured/in.png" ] || { echo "miss delivered non-empty bytes"; return 1; }
}

@test "clipimg serve: a non-image payload is refused as a miss" {
  # The reader returned 0 but produced junk. The magic-byte gate must collapse
  # it to empty, exactly as cleat paste does, so text-shaped bytes can never
  # reach Claude Code as an image.
  _use_capturing_docker
  _host_clip_read_image() { printf 'this is not an image' > "$1"; return 0; }
  _clipimg_serve "abox" "$TEST_TEMP/stage"

  [ ! -s "$TEST_TEMP/captured/in.png" ] || { echo "a non-image was delivered"; return 1; }
}

@test "clipimg serve: an over-cap image is refused as a miss" {
  _use_capturing_docker
  _host_clip_read_image() {
    { printf '\x89PNG\r\n\x1a\n'; dd if=/dev/zero bs=1024 count=11000 2>/dev/null; } > "$1"
    return 0
  }
  _clipimg_serve "abox" "$TEST_TEMP/stage"
  [ ! -s "$TEST_TEMP/captured/in.png" ] || { echo "an over-cap image was delivered"; return 1; }
}

@test "clipimg watcher: consumes the request marker and serves once" {
  _use_capturing_docker
  _host_clip_read_image() { printf '\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDRz' > "$1"; return 0; }

  _clipimg_watcher "$CLIPDIR" "abox" &
  local wpid=$!
  # The box's shim writes a contentless request into the shared dir.
  : > "$CLIPDIR/.image-req"
  # Give the 250 ms poll a couple of ticks plus the serve.
  local i=0
  while [ ! -e "$TEST_TEMP/captured/in.done" ] && [ "$i" -lt 40 ]; do sleep 0.1; i=$((i+1)); done
  kill "$wpid" 2>/dev/null || true
  wait "$wpid" 2>/dev/null || true

  [ ! -e "$CLIPDIR/.image-req" ] || { echo "watcher never consumed the request"; return 1; }
  run bash -c "printf '%s' \"\$(cat '$TEST_TEMP/captured/in.png')\""
  assert_output --partial "IHDRz"
}

@test "clipimg watcher: never reads the request file's content" {
  # The request is a signal, not a message. If the watcher ever read it, a box
  # could smuggle a target or a path through it. Plant hostile content and prove
  # the served image comes only from the host reader, never from the request.
  _use_capturing_docker
  _host_clip_read_image() { printf '\x89PNG\r\n\x1a\nFROMHOST' > "$1"; return 0; }

  _clipimg_watcher "$CLIPDIR" "abox" &
  local wpid=$!
  printf 'text/plain\n/etc/passwd\n' > "$CLIPDIR/.image-req"
  local i=0
  while [ ! -e "$TEST_TEMP/captured/in.done" ] && [ "$i" -lt 40 ]; do sleep 0.1; i=$((i+1)); done
  kill "$wpid" 2>/dev/null || true
  wait "$wpid" 2>/dev/null || true

  run bash -c "cat '$TEST_TEMP/captured/in.png'"
  assert_output --partial "FROMHOST"
  refute_output --partial "passwd"
}

# ── the shim drop ───────────────────────────────────────────────────────────

@test "clipimg drop: copies the shim to .local/bin ahead of the real xclip" {
  _use_capturing_docker
  _clipimg_drop_shim "abox"
  run cat "$TEST_TEMP/docker-argv"
  assert_output --partial "cp"
  assert_output --partial "abox:/home/coder/.local/bin/xclip"
  # What landed is really our shim.
  run cat "$TEST_TEMP/captured/xclip"
  assert_output --partial "cleat-shim v1"
}

@test "clipimg remove: only deletes a file carrying our marker" {
  # The removal must never delete a user's own xclip at that path. It is guarded
  # by the marker, run inside the box, so here we just prove the guard is in the
  # command rather than an unconditional rm.
  mkdir -p "$TEST_TEMP/bin"
  cat > "$TEST_TEMP/bin/docker" << EOF
#!/bin/sh
echo "\$@" >> "$TEST_TEMP/docker-argv"
exit 0
EOF
  chmod +x "$TEST_TEMP/bin/docker"
  export PATH="$TEST_TEMP/bin:$PATH"

  _clipimg_remove_shim "abox"
  run cat "$TEST_TEMP/docker-argv"
  assert_output --partial "cleat-shim v1"
  refute_output --regexp 'rm -f "?/home/coder/.local/bin/xclip"?$'
}
