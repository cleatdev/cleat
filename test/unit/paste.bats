#!/usr/bin/env bats
# ─────────────────────────────────────────────────────────────────────────────
# cleat paste (concept/39): hand ONE image to a box and print the path.
#
# The box is never given a clipboard read of its own, so every test here is
# about the HOST side: what gets validated before anything crosses the
# boundary, where the file is staged, and what docker is actually asked to do.
#
# The clipboard reader itself (_host_clip_read_image) shells out to osascript /
# powershell.exe / xclip depending on the host, so it is exercised through
# --file and through stubs rather than by reading a real pasteboard.
# ─────────────────────────────────────────────────────────────────────────────

load "../setup"

setup() {
  _common_setup
  source_cli
  export PATH="$MOCK_BIN:$PATH"
  mock_docker_images "$IMAGE_NAME"

  PROJ="$TEST_TEMP/proj"
  mkdir -p "$PROJ"
  cd "$PROJ"
  CNAME="$(container_name_for "$PROJ" main)"
  # A live box for this project, so the verb gets past its preflight.
  _daemon_up() { return 0; }
  container_exists() { return 0; }
  mock_docker_ps "$CNAME"

  # Real signatures, not extensions: the CLI decides by magic bytes.
  printf '\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDRxxxxxxxx' > "$TEST_TEMP/shot.png"
  printf '\xff\xd8\xff\xe0\x00\x10JFIFxxxxxxxx'          > "$TEST_TEMP/shot.jpg"
  printf 'this is definitely not an image'               > "$TEST_TEMP/notes.txt"
}

teardown() { _common_teardown; }

# ── what crosses into the box ───────────────────────────────────────────────

@test "paste: --file copies the image in and prints an absolute container path" {
  run cmd_paste --file "$TEST_TEMP/shot.png" --no-copy
  assert_success
  # Claude Code reads an ABSOLUTE path off the container filesystem, so the
  # printed path must be absolute and carry a real image extension.
  assert_output --regexp '/home/coder/\.cleat-paste/paste-[0-9]{8}-[0-9]{6}-[0-9]+\.png'
  run assert_docker_exec_has "cp"
  assert_success
}

@test "paste: the extension follows the MAGIC BYTES, not the filename" {
  # A JPEG named .png must land as .jpg, because the extension is the only
  # thing Claude Code's paste path matches on.
  cp "$TEST_TEMP/shot.jpg" "$TEST_TEMP/liar.png"
  run cmd_paste --file "$TEST_TEMP/liar.png" --no-copy
  assert_success
  assert_output --partial ".jpg"
  refute_output --partial ".png"
  run bash -c "grep -c '\.jpg' '$DOCKER_CALLS'"
  assert_success
}

@test "paste: chowns the drop dir so coder can read it after the UID remap" {
  # The image builds as uid 1000 and the entrypoint remaps to HOST_UID, so a
  # file docker cp lands as root is unreadable to coder on most hosts.
  run cmd_paste --file "$TEST_TEMP/shot.png" --no-copy
  assert_success
  run assert_docker_exec_has "chown -R coder:coder /home/coder/.cleat-paste"
  assert_success
}

@test "paste: stages on the host OUTSIDE the box-writable clip mount" {
  # Staging inside the shared clip dir would let the box pre-plant a symlink
  # under a guessable name and turn this into host-file overwrite as the user.
  run cmd_paste --file "$TEST_TEMP/shot.png" --no-copy
  assert_success
  # The `docker cp` source path must not be under the mounted clip dir.
  run bash -c "grep -o '[^ ]*/paste-[0-9-]*\.png' '$DOCKER_CALLS' | head -1"
  assert_success
  [[ "$output" != *"/clip/"* ]] || {
    echo "staged inside the bind-mounted clip dir: $output"; return 1; }
}

# ── what is refused before it crosses ───────────────────────────────────────

@test "paste: refuses a file that is not an image, and copies nothing" {
  run cmd_paste --file "$TEST_TEMP/notes.txt" --no-copy
  assert_failure
  assert_output --partial "not a PNG"
  run bash -c "grep -c 'cleat-paste' '$DOCKER_CALLS' 2>/dev/null; true"
  assert_output "0"
}

@test "paste: refuses an image over the size cap, and copies nothing" {
  # Valid PNG magic, but past the cap.
  { printf '\x89PNG\r\n\x1a\n'; dd if=/dev/zero bs=1024 count=11000 2>/dev/null; } > "$TEST_TEMP/huge.png"
  run cmd_paste --file "$TEST_TEMP/huge.png" --no-copy
  assert_failure
  assert_output --partial "over the"
  run bash -c "grep -c 'cleat-paste' '$DOCKER_CALLS' 2>/dev/null; true"
  assert_output "0"
}

@test "paste: refuses an empty file" {
  : > "$TEST_TEMP/empty.png"
  run cmd_paste --file "$TEST_TEMP/empty.png" --no-copy
  assert_failure
}

@test "paste: refuses a missing file" {
  run cmd_paste --file "$TEST_TEMP/nope.png" --no-copy
  assert_failure
  assert_output --partial "No such file"
}

@test "paste: refuses an unknown option instead of treating it as a box" {
  run cmd_paste --wat
  assert_failure
  assert_output --partial "Unknown option"
}

@test "paste: refuses a second positional" {
  run cmd_paste boxa boxb
  assert_failure
  assert_output --partial "Unexpected argument"
}

# ── preflight ───────────────────────────────────────────────────────────────

@test "paste: says so when no box exists yet, rather than failing at docker cp" {
  container_exists() { return 1; }
  run cmd_paste --file "$TEST_TEMP/shot.png" --no-copy
  assert_failure
  assert_output --partial "No box for this project"
}

@test "paste: says so when the box exists but is stopped" {
  is_running() { return 1; }
  run cmd_paste --file "$TEST_TEMP/shot.png" --no-copy
  assert_failure
  assert_output --partial "not running"
  assert_output --partial "cleat resume"
}

@test "paste: refuses when the daemon is down" {
  _daemon_up() { return 1; }
  run cmd_paste --file "$TEST_TEMP/shot.png" --no-copy
  assert_failure
  assert_output --partial "Docker is not running"
}

# ── the clipboard hop is a convenience, never the source of truth ───────────

@test "paste: --no-copy does not touch the host clipboard" {
  # The box can write the host clipboard through the existing copy bridge, so
  # the PRINTED path is the trustworthy handoff. --no-copy must honour that.
  local marker="$TEST_TEMP/clip-was-written"
  _host_clip_cmd() { echo "touch '$marker'"; }
  run cmd_paste --file "$TEST_TEMP/shot.png" --no-copy
  assert_success
  [ ! -e "$marker" ] || { echo "clipboard written despite --no-copy"; return 1; }
}

@test "paste: without --no-copy it puts the container path on the host clipboard" {
  local captured="$TEST_TEMP/captured"
  _host_clip_cmd() { echo "cat > '$captured'"; }
  run cmd_paste --file "$TEST_TEMP/shot.png"
  assert_success
  [ -s "$captured" ] || { echo "nothing reached the host clipboard"; return 1; }
  run cat "$captured"
  assert_output --partial "/home/coder/.cleat-paste/paste-"
}

# ── the box-side reader ─────────────────────────────────────────────────────

@test "paste: reports no image when the clipboard holds none" {
  _host_clip_read_image() { return 1; }
  run cmd_paste --no-copy
  assert_failure
  assert_output --partial "No image on the clipboard"
  assert_output --partial "--file"
}

@test "paste: uses the clipboard reader when no --file is given" {
  # Whatever the reader produces is what gets validated and pushed.
  _host_clip_read_image() { printf '\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDRxxxx' > "$1"; return 0; }
  run cmd_paste --no-copy
  assert_success
  assert_output --partial ".png"
}

@test "paste: a clipboard reader that yields a non-image is still refused" {
  # The reader is per-OS and shells out; it must not be trusted to have
  # produced an image just because it exited 0.
  _host_clip_read_image() { printf 'nope not an image at all' > "$1"; return 0; }
  run cmd_paste --no-copy
  assert_failure
  assert_output --partial "not a PNG"
}

# ── magic byte classifier ───────────────────────────────────────────────────

@test "paste: _image_magic_kind identifies each accepted format and rejects others" {
  printf 'GIF89a0123456'                       > "$TEST_TEMP/a.gif"
  printf 'RIFF\x24\x00\x00\x00WEBPVP8 '        > "$TEST_TEMP/a.webp"
  printf '%%PDF-1.4 not an image'              > "$TEST_TEMP/a.pdf"

  run _image_magic_kind "$TEST_TEMP/shot.png"; assert_output "png"
  run _image_magic_kind "$TEST_TEMP/shot.jpg"; assert_output "jpg"
  run _image_magic_kind "$TEST_TEMP/a.gif";    assert_output "gif"
  run _image_magic_kind "$TEST_TEMP/a.webp";   assert_output "webp"
  run _image_magic_kind "$TEST_TEMP/a.pdf";    assert_output ""
  run _image_magic_kind "$TEST_TEMP/notes.txt"; assert_output ""
}
