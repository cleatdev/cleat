#!/usr/bin/env bats
# ─────────────────────────────────────────────────────────────────────────────
# Forked workspaces: a box whose /workspace is its own COPY of the project
# instead of the live tree (concept/31).
#
# Covers the copy itself (CoW where available, symlinks NOT dereferenced,
# exclusions pruned, unsafe excludes refused), the mount swap, the marker that
# survives the copy, and the three ways a fork box could silently re-attach to
# the real tree: the docker cap, a vanished copy, and box discovery.
# ─────────────────────────────────────────────────────────────────────────────
load "../setup"

setup() {
  _common_setup
  use_docker_stub
  source_cli

  CLEAT_CONFIG_DIR="$TEST_TEMP/cleat-config"
  CLEAT_GLOBAL_CONFIG="$CLEAT_CONFIG_DIR/config"
  CLEAT_GLOBAL_ENV="$CLEAT_CONFIG_DIR/env"
  CLEAT_RUN_DIR="$CLEAT_CONFIG_DIR/run"
  CLEAT_KITS_DIR="$CLEAT_CONFIG_DIR/kits"
  CLEAT_BOXES_DIR="$CLEAT_CONFIG_DIR/boxes"
  CLEAT_FORKS_DIR="$CLEAT_CONFIG_DIR/forks"
  CLEAT_PROJECTS_DIR="$CLEAT_CONFIG_DIR/projects"
  CLEAT_TRUST_FILE="$CLEAT_CONFIG_DIR/trust"
  _first_run_tip_file="$CLEAT_CONFIG_DIR/.tip-shown"
  mkdir -p "$CLEAT_CONFIG_DIR"

  _host_clip_cmd() { echo ""; }
  check_for_update() { true; }
  check_drift() { true; }
  _resolve_config_drift() { true; }
  show_first_run_tip() { true; }

  mkdir -p "$TEST_TEMP/project/src"
  echo "code" > "$TEST_TEMP/project/src/app.js"
  cd "$TEST_TEMP/project"
  CNAME="$(container_name_for "$TEST_TEMP/project")"
  _FORK_REQUESTED=false
}
teardown() { _common_teardown; }

# ── the copy ────────────────────────────────────────────────────────────────

@test "fork: copy carries untracked and ignored files the project actually has" {
  echo "SECRET=1" > "$TEST_TEMP/project/.env"
  mkdir -p "$TEST_TEMP/project/node_modules/pkg"
  echo "dep" > "$TEST_TEMP/project/node_modules/pkg/i.js"
  _fork_copy_tree "$TEST_TEMP/project" "$CLEAT_FORKS_DIR/testbox"
  [ -f "$CLEAT_FORKS_DIR/testbox/.env" ]
  [ -f "$CLEAT_FORKS_DIR/testbox/node_modules/pkg/i.js" ]
  [ -f "$CLEAT_FORKS_DIR/testbox/src/app.js" ]
}

@test "fork: a symlink inside the project is copied as a symlink, never followed" {
  # SECURITY. A project containing sub/keys -> ~/.ssh must not have real key
  # bytes materialised into the cage's copy. Never add -L or -H to the copy.
  mkdir -p "$TEST_TEMP/secretstore"
  echo "PRIVATE-KEY-MATERIAL" > "$TEST_TEMP/secretstore/id_rsa"
  ln -s "$TEST_TEMP/secretstore" "$TEST_TEMP/project/src/keys"
  _fork_copy_tree "$TEST_TEMP/project" "$CLEAT_FORKS_DIR/testbox"
  [ -L "$CLEAT_FORKS_DIR/testbox/src/keys" ]
  run bash -c "grep -rl PRIVATE-KEY-MATERIAL '$TEST_TEMP/fork' 2>/dev/null || true"
  assert_output ""
}

@test "fork: the copy replaces a previous one instead of merging into it" {
  _fork_copy_tree "$TEST_TEMP/project" "$CLEAT_FORKS_DIR/testbox"
  echo "stale" > "$CLEAT_FORKS_DIR/testbox/gone.txt"
  _fork_copy_tree "$TEST_TEMP/project" "$CLEAT_FORKS_DIR/testbox"
  [ ! -e "$CLEAT_FORKS_DIR/testbox/gone.txt" ]
  [ -f "$CLEAT_FORKS_DIR/testbox/src/app.js" ]
}

@test "fork: the copy is not nested one level deeper than the project" {
  # cp -R src dst with dst ABSENT is the one form identical on BSD and GNU.
  # The trailing-slash forms silently produce fork/project/src on one of them.
  _fork_copy_tree "$TEST_TEMP/project" "$CLEAT_FORKS_DIR/testbox"
  [ -f "$CLEAT_FORKS_DIR/testbox/src/app.js" ]
  [ ! -e "$CLEAT_FORKS_DIR/testbox/project" ]
}

# ── exclusions ──────────────────────────────────────────────────────────────

@test "fork: configured excludes are pruned from the copy" {
  mkdir -p "$TEST_TEMP/project/node_modules/pkg" "$TEST_TEMP/project/dist"
  echo "dep" > "$TEST_TEMP/project/node_modules/pkg/i.js"
  echo "out" > "$TEST_TEMP/project/dist/b.js"
  printf '[fork]\nexclude = node_modules\nexclude = dist\n' > "$TEST_TEMP/project/.cleat"
  _fork_copy_tree "$TEST_TEMP/project" "$CLEAT_FORKS_DIR/testbox"
  _fork_prune_excludes "$CLEAT_FORKS_DIR/testbox" "$TEST_TEMP/project"
  [ ! -e "$CLEAT_FORKS_DIR/testbox/node_modules" ]
  [ ! -e "$CLEAT_FORKS_DIR/testbox/dist" ]
  [ -f "$CLEAT_FORKS_DIR/testbox/src/app.js" ]
}

@test "fork: an absolute or traversing exclude is refused, not executed" {
  mkdir -p "$TEST_TEMP/victim"
  echo "important" > "$TEST_TEMP/victim/keep.txt"
  printf '[fork]\nexclude = /tmp\nexclude = ../victim\n' > "$TEST_TEMP/project/.cleat"
  _fork_copy_tree "$TEST_TEMP/project" "$CLEAT_FORKS_DIR/testbox"
  run _fork_prune_excludes "$CLEAT_FORKS_DIR/testbox" "$TEST_TEMP/project"
  assert_output --partial "unsafe"
  [ -f "$TEST_TEMP/victim/keep.txt" ]
}

# ── the mount swap ──────────────────────────────────────────────────────────

@test "fork: cmd_run mounts the copy at workspace, not the live tree" {
  mock_docker_images "cleat"
  _FORK_REQUESTED=true
  run cmd_run "$TEST_TEMP/project"
  assert_success
  run assert_docker_run_has "$CNAME" "$CLEAT_FORKS_DIR/$CNAME:/workspace"
  assert_success
  run assert_docker_run_lacks "$CNAME" "$TEST_TEMP/project:/workspace"
  assert_success
}

@test "fork: without the flag a box still mounts the live tree" {
  mock_docker_images "cleat"
  run cmd_run "$TEST_TEMP/project"
  assert_success
  run assert_docker_run_has "$CNAME" "$TEST_TEMP/project:/workspace"
  assert_success
}

@test "fork: the marker makes a box stay forked without repeating the flag" {
  mock_docker_images "cleat"
  _FORK_REQUESTED=true
  run cmd_run "$TEST_TEMP/project"
  assert_success
  _FORK_REQUESTED=false
  run cmd_run "$TEST_TEMP/project"
  assert_success
  run assert_docker_run_has "$CNAME" "$CLEAT_FORKS_DIR/$CNAME:/workspace"
  assert_success
}

@test "fork: the docker cap exposes the copy, never the real working tree" {
  # bin/cleat mounts $project at its own host path for the docker cap and sets
  # workdir there. For a fork box that would hand back the live tree and
  # cancel the isolation entirely.
  mock_docker_images "cleat"
  printf '[capabilities]\ndocker\n' > "$TEST_TEMP/project/.cleat"
  _trust_lookup() { echo "trusted"; }
  cap_is_active() { [[ "$1" == "docker" ]]; }
  _FORK_REQUESTED=true
  run cmd_run "$TEST_TEMP/project"
  assert_success
  run assert_docker_run_lacks "$CNAME" "$TEST_TEMP/project:$TEST_TEMP/project"
  assert_success
}

# ── the ways a fork could silently re-attach ────────────────────────────────

@test "fork: a fork box whose copy is missing refuses instead of using the live tree" {
  mock_docker_images "cleat"
  _FORK_REQUESTED=true
  run cmd_run "$TEST_TEMP/project"
  assert_success
  rm -rf "$CLEAT_FORKS_DIR/$CNAME"
  _FORK_REQUESTED=false
  run cmd_run "$TEST_TEMP/project"
  assert_failure
  assert_output --partial "workspace copy is missing"
}

@test "fork: forking a directory that is already a fork is refused" {
  mkdir -p "$CLEAT_FORKS_DIR/some-box/src"
  mock_docker_images "cleat"
  _FORK_REQUESTED=true
  run cmd_run "$CLEAT_FORKS_DIR/some-box"
  assert_failure
  assert_output --partial "Refusing to fork a fork"
}

@test "fork: cleat rm keeps the workspace copy and says where it is" {
  mock_docker_images "cleat"
  _FORK_REQUESTED=true
  run cmd_run "$TEST_TEMP/project"
  assert_success
  container_exists() { return 1; }
  run cmd_rm
  assert_success
  assert_output --partial "Fork workspace kept"
  [ -d "$CLEAT_FORKS_DIR/$CNAME" ]
}

@test "fork: a fork box is listed by cleat status" {
  # A fork box mounts the forks path at /workspace, not the project path. If
  # box discovery only matches the project path, every fork box silently
  # vanishes from Boxes while still appearing in `cleat ps`.
  mkdir -p "$TEST_TEMP/project"
  local hash bname
  hash="$(echo -n "$TEST_TEMP/project" | _md5 | head -c 8)"
  bname="cleat-project-${hash}-feat"
  printf '%s\n' "$bname" > "$DOCKER_MOCK_DIR/ps_a_output"
  printf 'feat|true|%s\n' "$CLEAT_FORKS_DIR/$bname" > "$DOCKER_MOCK_DIR/inspect_output"
  run cmd_status "$TEST_TEMP/project"
  assert_success
  assert_output --partial "feat"
}

@test "fork: an exclude cannot delete through a symlink the project contains" {
  # SECURITY, and the escape the absolute/traversal guard does NOT catch:
  # rm -rf follows every INTERMEDIATE symlink component, and the copy
  # deliberately preserves symlinks. `exclude = docs/thesis.txt` where
  # docs -> ~/Documents is neither absolute nor traversing, and would delete
  # the real host file.
  mkdir -p "$TEST_TEMP/OUTSIDE/Documents"
  echo "THESIS" > "$TEST_TEMP/OUTSIDE/Documents/thesis.txt"
  ln -s "$TEST_TEMP/OUTSIDE" "$TEST_TEMP/project/docs"
  printf '[fork]\nexclude = docs/Documents\n' > "$TEST_TEMP/project/.cleat"
  _fork_copy_tree "$TEST_TEMP/project" "$CLEAT_FORKS_DIR/testbox"
  run _fork_prune_excludes "$CLEAT_FORKS_DIR/testbox" "$TEST_TEMP/project"
  assert_output --partial "resolves outside the fork"
  [ -f "$TEST_TEMP/OUTSIDE/Documents/thesis.txt" ]
}

@test "fork: a partial copy is discarded instead of mounted as the workspace" {
  mock_docker_images "cleat"
  _fork_copy_tree() { return 1; }
  _FORK_REQUESTED=true
  run cmd_run "$TEST_TEMP/project"
  assert_failure
  assert_output --partial "Could not copy the workspace"
  [ ! -d "$CLEAT_FORKS_DIR/$CNAME" ]
}

@test "fork: the box-state pruner keeps the fork marker" {
  # <cname>.fork has no matching container name, so a pruner that does not
  # strip the suffix deletes it. The box then silently mounts the LIVE tree.
  mkdir -p "$CLEAT_BOXES_DIR"
  : > "$CLEAT_BOXES_DIR/$CNAME.fork"
  container_exists() { [[ "$1" == "$CNAME" ]]; }
  mock_docker_ps ""
  run cmd_stop_all
  assert_success
  [ -f "$CLEAT_BOXES_DIR/$CNAME.fork" ]
}

@test "fork: a symlinked project root produces a real copy, not an alias" {
  # `cp -R "$src" "$dst"` copies the LINK when the project root is itself a
  # symlink, so the fork becomes an alias for the live tree and the whole
  # feature voids silently. Copying "$src/." into a created dst is the fix.
  mkdir -p "$TEST_TEMP/realproj/src"
  echo "original" > "$TEST_TEMP/realproj/src/app.js"
  ln -s "$TEST_TEMP/realproj" "$TEST_TEMP/linkproj"
  _fork_copy_tree "$TEST_TEMP/linkproj" "$CLEAT_FORKS_DIR/box1"
  [ ! -L "$CLEAT_FORKS_DIR/box1" ]
  [ -f "$CLEAT_FORKS_DIR/box1/src/app.js" ]
  echo "forked" > "$CLEAT_FORKS_DIR/box1/src/app.js"
  run cat "$TEST_TEMP/realproj/src/app.js"
  assert_output "original"
}

@test "fork: the copy refuses a destination outside the forks dir" {
  run _fork_copy_tree "$TEST_TEMP/project" "$TEST_TEMP/somewhere-else"
  assert_failure
  assert_output --partial "Refusing to write a fork outside"
  [ ! -e "$TEST_TEMP/somewhere-else" ]
}

@test "fork: a second concurrent copy is refused rather than racing" {
  mkdir -p "$CLEAT_FORKS_DIR/.lock.box2"
  run _fork_copy_tree "$TEST_TEMP/project" "$CLEAT_FORKS_DIR/box2"
  assert_failure
  assert_output --partial "already copying this workspace"
}

@test "fork: cp flags are probed from the binary, not from the OS name" {
  # A macOS host with Homebrew coreutils on PATH has GNU cp under the plain
  # name, and GNU cp rejects -c. An OS-keyed branch breaks the fork there.
  run _fork_cp_flags
  assert_success
  case "$output" in
    *-R*) ;;
    *) echo "expected a -R form, got: $output"; return 1 ;;
  esac
  # this box has GNU coreutils, so it must NOT have chosen the BSD clone flag
  refute_output --partial "-Rc"
}

@test "fork: an explicit fork flag recreates a copy that went missing" {
  # The marker is written once the copy lands, so a first run whose container
  # creation then failed left a marked box with no copy. Refusing there made
  # the state unrecoverable. An explicit --fork must heal it.
  mock_docker_images "cleat"
  _FORK_REQUESTED=true
  run cmd_run "$TEST_TEMP/project"
  assert_success
  rm -rf "$CLEAT_FORKS_DIR/$CNAME"
  [ -f "$CLEAT_BOXES_DIR/$CNAME.fork" ]
  _FORK_REQUESTED=true
  run cmd_run "$TEST_TEMP/project"
  assert_success
  assert_output --partial "Copying workspace"
  [ -d "$CLEAT_FORKS_DIR/$CNAME" ]
}

@test "fork: without the flag a missing copy still refuses, never re-binds" {
  # The other half: resume and start must NOT silently heal, because a fork box
  # quietly re-attaching to the live tree is the failure this guards.
  mock_docker_images "cleat"
  _FORK_REQUESTED=true
  run cmd_run "$TEST_TEMP/project"
  assert_success
  rm -rf "$CLEAT_FORKS_DIR/$CNAME"
  _FORK_REQUESTED=false
  run cmd_run "$TEST_TEMP/project"
  assert_failure
  assert_output --partial "workspace copy is missing"
}
