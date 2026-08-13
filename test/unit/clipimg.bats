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
