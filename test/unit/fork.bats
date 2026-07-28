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

# ── cp flag selection ───────────────────────────────────────────────────────
#
# _fork_cp_flags must key off the cp BINARY, never off `uname`: a macOS host
# with Homebrew coreutils on PATH has GNU cp under the plain name, and GNU cp
# rejects -c.
#
# Asserting that against the runner's own cp only ever exercises the one arm
# that runner happens to have, which left three holes: the GNU `-d` and
# `--reflink=auto` flags and the BSD `-Rc` clone flag could each be deleted
# with the whole suite green, and a regression to OS-keyed dispatch had no
# assertion behind it anywhere. Standing a fake cp in front of the real one
# asserts every arm on every leg, Linux included.
#
# `kind` is baked into the shim rather than read from the environment so the
# shim keeps working through `run`, which re-executes it in a subshell.
_fake_cp() {
  mkdir -p "$TEST_TEMP/fakebin"
  {
    echo '#!/usr/bin/env bash'
    echo "kind=\"$1\""
    cat <<'SHIM'
case "$1" in
  --version)
    case "$kind" in
      gnu*) echo "cp (GNU coreutils) 9.1"; exit 0 ;;
      *)    echo "cp: illegal option -- -" >&2; exit 64 ;;
    esac ;;
  --help)
    case "$kind" in
      gnu-reflink) echo "      --reflink[=WHEN]  control clone/CoW copies"; exit 0 ;;
      gnu*)        echo "      --preserve[=ATTR_LIST]  preserve attributes"; exit 0 ;;
      *)           echo "usage: cp [-R [-H | -L | -P]] source target" >&2; exit 64 ;;
    esac ;;
esac
# the BSD clone probe is `cp -Rc <src>/. <dst>/`. Record it when asked, so a
# test can assert the probe actually ran rather than inferring it from a flag
# string the function would also produce without probing.
case " $* " in
  *" -Rc "*) [ -n "${FORK_CP_PROBE_LOG:-}" ] && echo "probe $*" >> "$FORK_CP_PROBE_LOG" ;;
esac
case "$kind" in
  bsd-noclone) case " $* " in *" -Rc "*) exit 1 ;; esac ;;
esac
exit 0
SHIM
  } > "$TEST_TEMP/fakebin/cp"
  chmod +x "$TEST_TEMP/fakebin/cp"
  PATH="$TEST_TEMP/fakebin:$PATH"
  # The probe memoises into a source-time global. Clearing it keeps a second
  # probe in one process from silently replaying the first one's answer.
  _FORK_CP_PROBED=""
  _FORK_CP_FLAGS=""
}

@test "fork: cp flags from a GNU binary with reflink" {
  _fake_cp gnu-reflink
  run _fork_cp_flags
  assert_success
  assert_output "-R -d --reflink=auto"
}

@test "fork: cp flags from a GNU binary without reflink" {
  # An older GNU cp: no --reflink in --help, so asking for it would abort the
  # copy rather than degrade to a byte copy.
  _fake_cp gnu-noreflink
  run _fork_cp_flags
  assert_success
  assert_output "-R -d"
}

@test "fork: cp flags from a BSD binary with clonefile" {
  _fake_cp bsd
  run _fork_cp_flags
  assert_success
  assert_output "-Rc"
}

@test "fork: cp flags from a BSD binary without clonefile" {
  # BSD cp that rejects -c: fall back to a plain recursive copy rather than
  # failing every fork.
  #
  # "-R" alone is a weak assertion, because it is also the value the function
  # sets BEFORE it probes. So this asserts the probe RAN: the probe writes a
  # .cpprobe.$$ tree under the fork root and removes it, which a shim can
  # record. Without that, the test passes just as well against a function that
  # never probes at all, and the one property it exists to guard is the probe.
  _fake_cp bsd-noclone
  FORK_CP_PROBE_LOG="$TEST_TEMP/cpprobe.log" run _fork_cp_flags
  assert_success
  assert_output "-R"
  [ -s "$TEST_TEMP/cpprobe.log" ] || { echo "the clone probe never ran"; return 1; }
}

@test "fork: the BSD clone probe leaves nothing behind" {
  # The probe creates a scratch tree under the fork root. It must clean up, or
  # a fork root fills with .cpprobe.NNN dirs, one per cleat invocation.
  _fake_cp bsd
  run _fork_cp_flags
  assert_success
  run bash -c "ls -A \"$CLEAT_FORKS_DIR\" 2>/dev/null | grep -c cpprobe || true"
  assert_output "0"
}

@test "fork: cp flags are probed from the real binary not from the OS name" {
  # The same invariant against whatever cp this leg actually ships, so a shim
  # that drifts from real cp behaviour cannot hide a break.
  run _fork_cp_flags
  assert_success
  if cp --version 2>/dev/null | grep -q "GNU coreutils"; then
    # GNU cp rejects -c, so choosing the clone flag here breaks every copy.
    refute_output --partial "-Rc"
    assert_output --partial "-R -d"
  else
    # BSD: -Rc where clonefile works, plain -R where it does not. Asserting
    # -Rc unconditionally would go red on a BSD host without clonefile.
    case "$output" in
      "-Rc"|"-R") ;;
      *) echo "unexpected BSD flags: $output"; return 1 ;;
    esac
  fi
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

# ── the guard must hold on every session verb, not just cmd_run ─────────────
# Found on a real macOS run: cmd_resume only re-checks bind sources when the
# container is STOPPED, so a RUNNING fork box whose copy had been deleted went
# straight to exec_claude and reported success on an empty workspace.

@test "fork: resume refuses when the copy is gone even if the box is running" {
  mkdir -p "$CLEAT_BOXES_DIR"; : > "$CLEAT_BOXES_DIR/$CNAME.fork"
  is_running() { return 0; }
  container_exists() { return 0; }
  _FORK_REQUESTED=false
  run cmd_resume "$TEST_TEMP/project"
  assert_failure
  assert_output --partial "workspace copy is missing"
}

@test "fork: start refuses when the copy is gone even if the box is running" {
  mkdir -p "$CLEAT_BOXES_DIR"; : > "$CLEAT_BOXES_DIR/$CNAME.fork"
  is_running() { return 0; }
  container_exists() { return 0; }
  _FORK_REQUESTED=false
  run cmd_start "$TEST_TEMP/project"
  assert_failure
  assert_output --partial "workspace copy is missing"
}

@test "fork: shell refuses when the copy is gone even if the box is running" {
  mkdir -p "$CLEAT_BOXES_DIR"; : > "$CLEAT_BOXES_DIR/$CNAME.fork"
  is_running() { return 0; }
  container_exists() { return 0; }
  _FORK_REQUESTED=false
  run cmd_shell "$TEST_TEMP/project"
  assert_failure
  assert_output --partial "workspace copy is missing"
}

@test "fork: an explicit fork flag heals a running box by recreating it" {
  # The mount is baked at create and cannot be repointed on a live container,
  # so healing has to drop the container and let the create path rebuild both.
  mkdir -p "$CLEAT_BOXES_DIR"; : > "$CLEAT_BOXES_DIR/$CNAME.fork"
  _FORK_REQUESTED=true
  run _fork_preflight "$CNAME" recreate
  assert_success
  assert_output --partial "recreating it"
}

@test "fork: a healthy fork box passes preflight silently" {
  mkdir -p "$CLEAT_BOXES_DIR" "$CLEAT_FORKS_DIR/$CNAME"
  : > "$CLEAT_BOXES_DIR/$CNAME.fork"
  run _fork_preflight "$CNAME"
  assert_success
  assert_output ""
}

@test "fork: a plain box is unaffected by preflight" {
  run _fork_preflight "$CNAME"
  assert_success
  assert_output ""
}

# ── fork root override and the age signal ───────────────────────────────────

@test "fork: the root defaults to the cleat config dir" {
  run _fork_root
  assert_output "$CLEAT_FORKS_DIR"
}

@test "fork: a global config fork dir moves the root" {
  mkdir -p "$CLEAT_CONFIG_DIR" "$TEST_TEMP/elsewhere"
  printf '[fork]\ndir = %s\n' "$TEST_TEMP/elsewhere" > "$CLEAT_GLOBAL_CONFIG"
  run _fork_root
  assert_output "$TEST_TEMP/elsewhere"
  run bash -c "source_cli 2>/dev/null; true"   # no-op, keeps shellcheck quiet
}

@test "fork: a relative fork dir is refused and falls back to the default" {
  mkdir -p "$CLEAT_CONFIG_DIR"
  printf '[fork]\ndir = ../nope\n' > "$CLEAT_GLOBAL_CONFIG"
  # Assert on the CAPTURED VALUE, not on `run` output: bats merges stderr into
  # $output, so a --partial check there passed even while the warning was
  # polluting the value itself. Every real caller uses a command substitution.
  local root
  root="$(_fork_root 2>/dev/null)"
  [ "$root" = "$CLEAT_FORKS_DIR" ] || { echo "got: [$root]"; return 1; }
  # and the warning is still emitted, just on stderr
  run _fork_root
  assert_output --partial "not an absolute path"
}

@test "fork: a project cleat file cannot move the fork root" {
  # .cleat arrives with cloned repos and this value is a path cleat creates and
  # removes under, so it is deliberately global-config only.
  printf '[fork]\ndir = %s/evil\n' "$TEST_TEMP" > "$TEST_TEMP/project/.cleat"
  run _fork_root
  assert_output "$CLEAT_FORKS_DIR"
}

@test "fork: the copy honours the configured root" {
  mkdir -p "$CLEAT_CONFIG_DIR" "$TEST_TEMP/elsewhere"
  printf '[fork]\ndir = %s\n' "$TEST_TEMP/elsewhere" > "$CLEAT_GLOBAL_CONFIG"
  _fork_copy_tree "$TEST_TEMP/project" "$TEST_TEMP/elsewhere/box1"
  [ -f "$TEST_TEMP/elsewhere/box1/src/app.js" ]
}

@test "fork: the copy still refuses a destination outside the configured root" {
  mkdir -p "$CLEAT_CONFIG_DIR" "$TEST_TEMP/elsewhere"
  printf '[fork]\ndir = %s\n' "$TEST_TEMP/elsewhere" > "$CLEAT_GLOBAL_CONFIG"
  run _fork_copy_tree "$TEST_TEMP/project" "$CLEAT_FORKS_DIR/box1"
  assert_failure
  assert_output --partial "Refusing to write a fork outside"
}

@test "fork: a fresh copy reads as just now, never as nothing" {
  mkdir -p "$TEST_TEMP/freshcopy"
  run _fork_age_human "$TEST_TEMP/freshcopy"
  assert_output "just now"
}

@test "fork: an older copy reports its age in hours" {
  mkdir -p "$TEST_TEMP/oldcopy"
  touch -t "$(date -d '3 hours ago' +%Y%m%d%H%M 2>/dev/null || date -v-3H +%Y%m%d%H%M)" "$TEST_TEMP/oldcopy"
  run _fork_age_human "$TEST_TEMP/oldcopy"
  assert_output "3h ago"
}

@test "fork: the summary names the copy and its age for a fork box" {
  mkdir -p "$CLEAT_BOXES_DIR" "$CLEAT_FORKS_DIR/$CNAME"
  : > "$CLEAT_BOXES_DIR/$CNAME.fork"
  run _print_summary_block "$CNAME" "$TEST_TEMP/project"
  assert_success
  assert_output --partial "Fork:"
  assert_output --partial "copied"
}

@test "fork: the summary has no fork line for a plain box" {
  run _print_summary_block "$CNAME" "$TEST_TEMP/project"
  assert_success
  refute_output --partial "Fork:"
}

# ── audit follow-ups ────────────────────────────────────────────────────────

@test "fork: stop-all keeps a fork marker whose container is already gone" {
  # cleat rm <box> deliberately removes the container and KEEPS the copy, so
  # the marker legitimately outlives its container. Pruning it there re-binds
  # the next run to the live tree.
  mkdir -p "$CLEAT_BOXES_DIR"
  : > "$CLEAT_BOXES_DIR/$CNAME.fork"
  printf '%s\n' "$CNAME" > "$DOCKER_MOCK_DIR/ps_output"
  printf '%s\n' "$CNAME" > "$DOCKER_MOCK_DIR/ps_a_output"
  container_exists() { return 1; }
  run cmd_stop_all
  assert_success
  [ -f "$CLEAT_BOXES_DIR/$CNAME.fork" ]
}

@test "fork: clean keeps a fork marker whose container is already gone" {
  mkdir -p "$CLEAT_BOXES_DIR"
  : > "$CLEAT_BOXES_DIR/$CNAME.fork"
  container_exists() { return 1; }
  run cmd_clean
  assert_success
  [ -f "$CLEAT_BOXES_DIR/$CNAME.fork" ]
}

@test "fork: run refuses the flag on an existing plain box instead of destroying it" {
  # cmd_run is reached directly by `cleat run <box> --fork`, without the
  # preflight cmd_start does first, and its container_exists branch is a plain
  # `docker rm`. So the flag used to silently destroy an existing plain box's
  # writable layer and rebuild it on a copy, which is worse than the no-op the
  # preflight was written to stop. run and start must give the same answer.
  mock_docker_images "cleat"
  run cmd_run "$TEST_TEMP/project"          # a plain box exists
  assert_success
  container_exists() { return 0; }
  is_running() { return 1; }
  _FORK_REQUESTED=true
  _BOX=main
  run cmd_run "$TEST_TEMP/project"
  assert_failure
  assert_output --partial "already exists and is not a fork"
}

@test "fork: the flag on an existing plain box refuses instead of doing nothing" {
  # The create block only runs when there is no container, so --fork on an
  # existing plain box was silently ignored and the live tree stayed mounted.
  container_exists() { return 0; }
  _FORK_REQUESTED=true
  run _fork_preflight "$CNAME" recreate
  assert_failure
  assert_output --partial "already exists and is not a fork"
}

@test "fork: shell never force-removes a box while healing" {
  # Healing drops the container so the create path rebuilds it. shell and
  # claude have no create path, so healing there destroys a live box with
  # nothing to rebuild it.
  mkdir -p "$CLEAT_BOXES_DIR"; : > "$CLEAT_BOXES_DIR/$CNAME.fork"
  _FORK_REQUESTED=true
  run _fork_preflight "$CNAME"
  assert_failure
  assert_output --partial "workspace copy is missing"
  run grep -c "rm -f $CNAME" "$DOCKER_CALLS"
  assert_output "0"
}

@test "fork: an exclude naming the workspace root is refused, not fatal" {
  # `.` passes the physical-parent check and rm refuses it non-zero, which
  # under strict mode aborted the run after a successful copy.
  printf '[fork]\nexclude = .\n' > "$TEST_TEMP/project/.cleat"
  _fork_copy_tree "$TEST_TEMP/project" "$CLEAT_FORKS_DIR/testbox"
  run _fork_prune_excludes "$CLEAT_FORKS_DIR/testbox" "$TEST_TEMP/project"
  assert_success
  assert_output --partial "names the workspace root"
  [ -f "$CLEAT_FORKS_DIR/testbox/src/app.js" ]
}

@test "fork: a fork root inside the project is refused" {
  mkdir -p "$CLEAT_CONFIG_DIR"
  printf '[fork]\ndir = %s/inner\n' "$TEST_TEMP/project" > "$CLEAT_GLOBAL_CONFIG"
  mock_docker_images "cleat"
  _FORK_REQUESTED=true
  run cmd_run "$TEST_TEMP/project"
  assert_failure
  assert_output --partial "Fork root is inside the project"
}
