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

@test "fork: the session key follows the copy, not the live project" {
  # Shipped broken, found on a real host run 2026-07-29. Under the docker cap
  # the container cd's into the workspace HOST path, so Claude Code derives its
  # session key from the fork copy. Both the generated mountpoint and the
  # session mount were keyed off the live PROJECT, so the box looked for a key
  # that did not exist, and the projects parent is :ro so it could not create
  # one. Sessions and memory silently did not persist for a fork box.
  mock_docker_images "cleat"
  printf '[capabilities]\ndocker\n' > "$TEST_TEMP/project/.cleat"
  _trust_lookup() { echo "trusted"; }
  cap_is_active() { [[ "$1" == "docker" ]]; }
  _FORK_REQUESTED=true
  run cmd_run "$TEST_TEMP/project"
  assert_success

  local fork_key
  fork_key="$(_claude_session_key "$CLEAT_FORKS_DIR/$CNAME")"
  # the generated parent holds a mountpoint for the COPY's key
  [ -d "$CLEAT_RUN_DIR/$CNAME/home/projects/$fork_key" ] \
    || { echo "missing fork session key: $fork_key"; \
         ls -A "$CLEAT_RUN_DIR/$CNAME/home/projects"; return 1; }
  # ...and the writable session dir is mounted at that key, not the project's
  run assert_docker_run_has "$CNAME" "/home/coder/.claude/projects/$fork_key"
  assert_success
  run assert_docker_run_lacks "$CNAME" "/home/coder/.claude/projects/$(_claude_session_key "$TEST_TEMP/project")"
  assert_success
}

@test "fork: the session key replaces dots as well as slashes" {
  # The half my first fix missed. Claude Code encodes BOTH / and . as a dash:
  # measured on a live box, the workspace
  #   /Users/marcin/.config/cleat/forks/cleat-demo-ab8ed4e5-feat-a
  # became  -Users-marcin--config-cleat-forks-...  with a DOUBLE dash for "/.".
  # Slash-only matched for a dotless project path, so this hid, but the DEFAULT
  # fork root is ~/.config/cleat/forks, so every fork box under the docker cap
  # missed its session dir.
  run _claude_session_key "/Users/marcin/.config/cleat/forks/cleat-demo-ab8ed4e5-feat-a"
  assert_success
  assert_output "-Users-marcin--config-cleat-forks-cleat-demo-ab8ed4e5-feat-a"
}

@test "fork: a dotted fork root still gets a session mountpoint the box can find" {
  # End to end for the same bug, through the real generator.
  CLEAT_FORKS_DIR="$TEST_TEMP/.config/cleat/forks"
  local ws="$CLEAT_FORKS_DIR/$CNAME"
  mkdir -p "$ws"
  _generate_home_overlay "$CNAME" "$ws" "key-abc"
  local want
  want="$(_claude_session_key "$ws")"
  case "$want" in
    *".."*|*"."*) echo "key still contains a dot: $want"; return 1 ;;
  esac
  [ -d "$CLEAT_RUN_DIR/$CNAME/home/projects/$want" ] \
    || { echo "missing mountpoint for $want"; \
         ls -A "$CLEAT_RUN_DIR/$CNAME/home/projects"; return 1; }
}

@test "fork: a plain box still keys its session off the project path" {
  # The same code path must not move for a non-fork box: workspace == project.
  mock_docker_images "cleat"
  printf '[capabilities]\ndocker\n' > "$TEST_TEMP/project/.cleat"
  _trust_lookup() { echo "trusted"; }
  cap_is_active() { [[ "$1" == "docker" ]]; }
  run cmd_run "$TEST_TEMP/project"
  assert_success
  local proj_key
  proj_key="$(_claude_session_key "$TEST_TEMP/project")"
  [ -d "$CLEAT_RUN_DIR/$CNAME/home/projects/$proj_key" ] \
    || { echo "missing project session key: $proj_key"; return 1; }
  run assert_docker_run_has "$CNAME" "/home/coder/.claude/projects/$proj_key"
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

@test "fork: the heal notice prints once even though two verbs preflight" {
  # cmd_start preflights and then calls cmd_run, which preflights too so that
  # `cleat run <box> --fork` cannot reach its plain `docker rm`. A real host run
  # showed the heal line twice because both calls ran the body. Asserted in ONE
  # shell on purpose: `run` is a subshell, so a test that calls cmd_run twice
  # through `run` cannot see the per-process guard at all.
  mock_docker_images "cleat"
  _FORK_REQUESTED=true
  run cmd_run "$TEST_TEMP/project"
  assert_success
  rm -rf "$CLEAT_FORKS_DIR/$CNAME"
  _FORK_PREFLIGHT_DONE=""
  # The notice only fires when there is a container to drop, so give it one.
  container_exists() { return 0; }
  local out
  out="$( { _fork_preflight "$CNAME" recreate; _fork_preflight "$CNAME" recreate; } 2>&1 )"
  local n
  n="$(printf '%s\n' "$out" | grep -c "recreating it" || true)"
  [ "$n" = "1" ] || { echo "expected 1 heal notice, got $n:"; printf '%s\n' "$out"; return 1; }
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
  container_exists() { return 0; }   # there IS a box to heal
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

@test "fork: the summary does not claim the project is mounted for a fork box" {
  # Shipped wrong, seen on a real host run: with the docker cap the Project line
  # read "~/proj (same path, sandboxed)" directly above a Fork line naming a
  # different directory. False twice over. The box has the COPY mounted, and the
  # path it is mounted at is the copy's own.
  mkdir -p "$CLEAT_FORKS_DIR/$CNAME"
  _fork_mark "$CNAME"
  cap_is_active() { [[ "$1" == "docker" ]]; }
  run _print_summary_block "$CNAME" "$TEST_TEMP/project"
  assert_success
  assert_output --partial "not mounted"
  # the PROJECT line specifically must not claim the mount
  local projline
  projline="$(printf '%s\n' "$output" | grep -- "Project:" | head -1)"
  case "$projline" in
    *"same path, sandboxed"*) echo "Project line still claims the mount: $projline"; return 1 ;;
  esac
  # the Fork line now carries the mount instead
  local forkline
  forkline="$(printf '%s\n' "$output" | grep -- "Fork:" | head -1)"
  case "$forkline" in
    *"same path, sandboxed"*) ;;
    *) echo "Fork line does not say where the copy is mounted: $forkline"; return 1 ;;
  esac
}

@test "fork: without the docker cap the fork line points at workspace" {
  mkdir -p "$CLEAT_FORKS_DIR/$CNAME"
  _fork_mark "$CNAME"
  cap_is_active() { return 1; }
  run _print_summary_block "$CNAME" "$TEST_TEMP/project"
  assert_success
  local forkline
  forkline="$(printf '%s\n' "$output" | grep -- "Fork:" | head -1)"
  case "$forkline" in
    *"/workspace"*) ;;
    *) echo "Fork line does not name /workspace: $forkline"; return 1 ;;
  esac
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

# ── cleat fork: managing the copies ─────────────────────────────────────────
#
# Before this verb the copies were write-only state: created by --fork, kept on
# purpose by cleat rm, and after that reachable only by knowing the layout of
# $CLEAT_FORKS_DIR. There was also no way to get a FRESH copy at all, which is
# what a real host run hit: cleat rm keeps the copy, so start --fork reused it
# and a newly added `[fork] exclude` could never take effect.

@test "fork verb: says so plainly when there are no copies" {
  run cmd_fork
  assert_success
  assert_output --partial "No fork workspaces"
}

@test "fork verb: lists a copy with its size and its box state" {
  mock_docker_images "cleat"
  _FORK_REQUESTED=true
  run cmd_run "$TEST_TEMP/project"
  assert_success
  container_exists() { return 0; }
  run cmd_fork
  assert_success
  # Assert on THIS copy's row, not on the whole output: the legend at the bottom
  # always mentions "no box" while explaining what the marker means.
  local row
  row="$(printf '%s\n' "$output" | grep -- "$CNAME" | head -1)"
  case "$row" in
    *"box exists"*) ;;
    *) echo "row did not read as having a box: $row"; return 1 ;;
  esac
  case "$row" in
    *"no box"*) echo "row wrongly read as an orphan: $row"; return 1 ;;
  esac
  # and the size column is populated
  case "$row" in
    *KB*|*MB*|*GB*) ;;
    *) echo "row has no size: $row"; return 1 ;;
  esac
}

@test "fork verb: a copy whose container is gone reads as an orphan" {
  mkdir -p "$CLEAT_FORKS_DIR/cleat-gone-11112222-main"
  container_exists() { return 1; }
  run cmd_fork
  assert_success
  assert_output --partial "cleat-gone-11112222-main"
  assert_output --partial "no box"
}

@test "fork verb: the total is labelled apparent, never reclaimable" {
  # A copy-on-write copy shares blocks with the project, and du is not
  # clone-aware, so the number over-reports what deleting would free. Printing
  # it as reclaimable disk would be the same class of overclaim the docs ban.
  mkdir -p "$CLEAT_FORKS_DIR/cleat-x-11112222-main"
  container_exists() { return 1; }
  run cmd_fork
  assert_success
  assert_output --partial "apparent"
}

@test "fork verb: path prints the bare path and nothing else on stdout" {
  # This exists so `cd "$(cleat fork path feat-a)"` works, so a diagnostic on
  # stdout would be cd'd into.
  mkdir -p "$CLEAT_FORKS_DIR/$CNAME"
  run cmd_fork path main
  assert_success
  assert_output "$CLEAT_FORKS_DIR/$CNAME"
}

@test "fork verb: path fails with an empty stdout when there is no copy" {
  local out rc=0
  out="$(cmd_fork path main 2>/dev/null)" || rc=$?
  [ "$rc" != "0" ] || { echo "expected a non-zero exit"; return 1; }
  [ -z "$out" ] || { echo "expected empty stdout, got: $out"; return 1; }
}

@test "fork verb: rm refuses while the box still exists" {
  # The container has the copy bind-mounted at /workspace. Deleting it under a
  # live box hands the agent a half tree with no warning.
  mkdir -p "$CLEAT_FORKS_DIR/$CNAME"
  container_exists() { return 0; }
  run cmd_fork rm main
  assert_failure
  assert_output --partial "still exists"
  [ -d "$CLEAT_FORKS_DIR/$CNAME" ]
}

@test "fork verb: rm keeps the copy when the confirmation is declined" {
  mkdir -p "$CLEAT_FORKS_DIR/$CNAME"
  echo "work" > "$CLEAT_FORKS_DIR/$CNAME/uncommitted.txt"
  container_exists() { return 1; }
  run cmd_fork rm main <<< "n"
  assert_success
  assert_output --partial "Kept"
  [ -f "$CLEAT_FORKS_DIR/$CNAME/uncommitted.txt" ]
}

@test "fork verb: rm deletes the copy and drops the fork marker when confirmed" {
  mkdir -p "$CLEAT_FORKS_DIR/$CNAME"
  _fork_mark "$CNAME"
  [ -f "$(_fork_marker_file "$CNAME")" ]
  container_exists() { return 1; }
  run cmd_fork rm main <<< "y"
  assert_success
  [ ! -e "$CLEAT_FORKS_DIR/$CNAME" ]
  [ ! -e "$(_fork_marker_file "$CNAME")" ]
}

@test "fork verb: prune deletes orphans and keeps copies that still have a box" {
  mkdir -p "$CLEAT_FORKS_DIR/cleat-orphan-11112222-main"
  mkdir -p "$CLEAT_FORKS_DIR/cleat-live-33334444-main"
  container_exists() { [[ "$1" == "cleat-live-33334444-main" ]]; }
  run cmd_fork prune --yes
  assert_success
  [ ! -e "$CLEAT_FORKS_DIR/cleat-orphan-11112222-main" ]
  [ -d "$CLEAT_FORKS_DIR/cleat-live-33334444-main" ]
}

@test "fork verb: prune keeps everything when the confirmation is declined" {
  mkdir -p "$CLEAT_FORKS_DIR/cleat-orphan-11112222-main"
  container_exists() { return 1; }
  run cmd_fork prune <<< "n"
  assert_success
  assert_output --partial "Kept"
  [ -d "$CLEAT_FORKS_DIR/cleat-orphan-11112222-main" ]
}

@test "fork verb: refresh re-copies and finally applies a changed exclude" {
  # THE host bug: cleat rm keeps the copy, so start --fork reused a stale one
  # and a newly added [fork] exclude never took effect. There was no way to
  # force a fresh copy short of deleting the directory by hand.
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project/node_modules/pkg"
  echo "dep" > "$TEST_TEMP/project/node_modules/pkg/i.js"
  _FORK_REQUESTED=true
  run cmd_run "$TEST_TEMP/project"
  assert_success
  [ -d "$CLEAT_FORKS_DIR/$CNAME/node_modules" ]

  # now the user adds the exclude and refreshes
  printf '[fork]\nexclude = node_modules\n' > "$TEST_TEMP/project/.cleat"
  container_exists() { return 1; }
  run cmd_fork refresh main <<< "y"
  assert_success
  [ ! -e "$CLEAT_FORKS_DIR/$CNAME/node_modules" ]
  [ -f "$CLEAT_FORKS_DIR/$CNAME/src/app.js" ]
}

@test "fork verb: refresh refuses while the box still exists" {
  mkdir -p "$CLEAT_FORKS_DIR/$CNAME"
  echo "agent work" > "$CLEAT_FORKS_DIR/$CNAME/wip.txt"
  container_exists() { return 0; }
  run cmd_fork refresh main
  assert_failure
  assert_output --partial "still exists"
  [ -f "$CLEAT_FORKS_DIR/$CNAME/wip.txt" ]
}

@test "fork verb: an unknown subcommand errors instead of guessing a box name" {
  # `cleat fork feat-a` must not be read as either "show me feat-a's copy" or
  # "run subcommand feat-a". Guessing is how a delete lands on the wrong thing.
  run cmd_fork feat-a
  assert_failure
  assert_output --partial "Unknown subcommand"
  # ...and the hint names the verb that WOULD fork that box
  assert_output --partial "cleat fork start feat-a"
}

@test "fork verb: the tree delete refuses a target outside the fork root" {
  mkdir -p "$TEST_TEMP/victim"
  echo "important" > "$TEST_TEMP/victim/keep.txt"
  run _fork_rm_tree "$TEST_TEMP/victim"
  assert_failure
  assert_output --partial "Refusing to delete outside"
  [ -f "$TEST_TEMP/victim/keep.txt" ]
}

@test "fork verb: the tree delete refuses a symlinked copy" {
  # rm -rf on a symlinked copy would follow it out of the fork root.
  mkdir -p "$TEST_TEMP/realdir" "$CLEAT_FORKS_DIR"
  echo "important" > "$TEST_TEMP/realdir/keep.txt"
  ln -s "$TEST_TEMP/realdir" "$CLEAT_FORKS_DIR/sneaky"
  run _fork_rm_tree "$CLEAT_FORKS_DIR/sneaky"
  assert_failure
  assert_output --partial "symlink"
  [ -f "$TEST_TEMP/realdir/keep.txt" ]
}

# ── cleat fork run / fork start ─────────────────────────────────────────────
#
# Discoverable aliases for `--fork` from the noun people reach for. Both exist
# on purpose: `run` is create-only, so shipping only `fork run` would hand
# someone a box and drop them back at their shell when they meant to work in it.
# These tests assert EQUIVALENCE, not just that the commands do something.

@test "fork run: mounts the copy at workspace, exactly like run --fork" {
  mock_docker_images "cleat"
  run cmd_fork run
  assert_success
  run assert_docker_run_has "$CNAME" "$CLEAT_FORKS_DIR/$CNAME:/workspace"
  assert_success
  run assert_docker_run_lacks "$CNAME" "$TEST_TEMP/project:/workspace"
  assert_success
}

@test "fork run: records the fork marker so the box stays forked" {
  mock_docker_images "cleat"
  run cmd_fork run
  assert_success
  run _box_is_fork "$CNAME"
  assert_success
}

@test "fork run: produces the same docker run line as run --fork" {
  # The point of the alias is that it is not a lookalike. Capture the recorded
  # docker command for each route and compare them.
  mock_docker_images "cleat"
  _FORK_REQUESTED=true
  run cmd_run "$TEST_TEMP/project"
  assert_success
  local via_flag
  via_flag="$(grep -F -- "--name $CNAME" "$DOCKER_CALLS" | tail -1)"

  # reset: same box, same project, via the new verb
  docker rm "$CNAME" >/dev/null 2>&1 || true
  : > "$DOCKER_CALLS"
  rm -rf "$CLEAT_RUN_DIR/$CNAME"
  container_exists() { return 1; }
  _FORK_REQUESTED=false
  _FORK_PREFLIGHT_DONE=""
  run cmd_fork run
  assert_success
  local via_verb
  via_verb="$(grep -F -- "--name $CNAME" "$DOCKER_CALLS" | tail -1)"

  [ -n "$via_flag" ] || { echo "no docker run recorded for the flag route"; return 1; }
  [ "$via_flag" = "$via_verb" ] || {
    echo "routes differ:"; echo "  flag: $via_flag"; echo "  verb: $via_verb"; return 1; }
}

@test "fork run: a named box lands on that box, not on main" {
  mock_docker_images "cleat"
  local named
  named="$(container_name_for "$TEST_TEMP/project" "feat-a")"
  run cmd_fork run feat-a
  assert_success
  run assert_docker_run_has "$named" "$CLEAT_FORKS_DIR/$named:/workspace"
  assert_success
}

@test "fork start: launches Claude rather than only creating the box" {
  # The whole reason both verbs exist. `run` is create-only; `start` must reach
  # the session launch. cmd_start is stubbed out to a marker so this stays a
  # unit test rather than a real session.
  mock_docker_images "cleat"
  cmd_start() { echo "CMD_START REACHED"; }
  run cmd_fork start feat-a
  assert_success
  assert_output --partial "CMD_START REACHED"
}

@test "fork start: sets the fork request before handing off" {
  # If the flag were not set, cmd_start would build a plain box in silence.
  local seen=""
  cmd_start() { seen="$_FORK_REQUESTED"; }
  cmd_fork start feat-a
  [ "$seen" = "true" ] || { echo "expected _FORK_REQUESTED=true, got: [$seen]"; return 1; }
}

@test "fork run: routes through _set_box so the box name is validated" {
  cmd_run() { echo "SHOULD NOT REACH"; }
  run cmd_fork run "Not A Valid Box"
  assert_failure
  assert_output --partial "Invalid box name"
  refute_output --partial "SHOULD NOT REACH"
}

@test "fork run: refuses a stray second positional like every box-aware verb" {
  cmd_run() { echo "SHOULD NOT REACH"; }
  run cmd_fork run feat-a extra
  assert_failure
  assert_output --partial "Unexpected argument"
  refute_output --partial "SHOULD NOT REACH"
}

@test "fork start: an existing plain box is refused, not converted" {
  # Same preflight as start --fork. Without it this alias would be a second
  # route to the destructive docker rm that preflight exists to stop.
  mock_docker_images "cleat"
  run cmd_run "$TEST_TEMP/project"     # a plain box exists
  assert_success
  container_exists() { return 0; }
  is_running() { return 1; }
  run cmd_fork run
  assert_failure
  assert_output --partial "already exists and is not a fork"
}

# ── found by a host run, 2026-07-31 ─────────────────────────────────────────

@test "fork: a first create does not announce a heal for a leftover marker" {
  # A marker outlives its box on purpose, so one from a box removed long ago
  # (or from an rm -rf of the forks dir) made a brand-new `cleat fork start`
  # open with "Fork workspace is missing, recreating it" when nothing was
  # missing and nothing was being recreated.
  mock_docker_images "cleat"
  _fork_mark "$CNAME"                    # marker, but no copy and no container
  container_exists() { return 1; }
  _FORK_REQUESTED=true
  run cmd_run "$TEST_TEMP/project"
  assert_success
  refute_output --partial "recreating it"
  assert_output --partial "Workspace copied"
}

@test "fork: a real heal still announces itself when there is a box to heal" {
  # The other side: gating the notice must not silence the case it exists for.
  mock_docker_images "cleat"
  _fork_mark "$CNAME"
  container_exists() { return 0; }
  _FORK_REQUESTED=true
  run _fork_preflight "$CNAME" recreate
  assert_success
  assert_output --partial "recreating it"
}

@test "fork: a missing copy still refuses without the flag, container or not" {
  # The refusal is deliberately NOT gated on the container existing: refusing to
  # silently re-bind the live tree matters either way.
  _fork_mark "$CNAME"
  container_exists() { return 1; }
  _FORK_REQUESTED=false
  run _fork_preflight "$CNAME" recreate
  assert_failure
  assert_output --partial "workspace copy is missing"
}

@test "fork verb: prune clears a stale marker that has no copy and no box" {
  # Stale markers accumulated invisibly and were not inert: the next box of that
  # name became a fork with a missing copy, so cleat start refused.
  _fork_mark "cleat-gone-11112222-main"
  container_exists() { return 1; }
  run cmd_fork prune --yes
  assert_success
  assert_output --partial "stale fork marker"
  [ ! -e "$(_fork_marker_file "cleat-gone-11112222-main")" ]
}

@test "fork verb: prune keeps a marker whose copy still exists" {
  # That is the normal kept-copy state, not garbage.
  mkdir -p "$CLEAT_FORKS_DIR/cleat-keep-11112222-main"
  _fork_mark "cleat-keep-11112222-main"
  container_exists() { return 1; }
  run cmd_fork prune <<< "n"
  assert_success
  [ -f "$(_fork_marker_file "cleat-keep-11112222-main")" ]
}

@test "fork verb: prune keeps a marker whose box still exists" {
  _fork_mark "cleat-live-33334444-main"
  container_exists() { return 0; }
  run cmd_fork prune --yes
  assert_success
  [ -f "$(_fork_marker_file "cleat-live-33334444-main")" ]
}

@test "fork verb: marker-only prune does not claim to have removed copies" {
  _fork_mark "cleat-gone-11112222-main"
  container_exists() { return 1; }
  run cmd_fork prune --yes
  assert_success
  refute_output --partial "Removed 1 fork workspace"
  assert_output --partial "No copies to remove"
}

# ── box-name containment for the fork verb ──────────────────────────────────
#
# `cleat fork path|rm|refresh <box>` read the box positional directly instead
# of routing it through _set_box, so unlike every other box-aware verb the name
# was never validated. container_name_for appends it to the container name
# verbatim, _fork_dir appends THAT to the fork root, and the containment guards
# in _fork_rm_tree and _fork_copy_tree were textual (`case "$target" in
# "$root"/?*`), which a '..' component satisfies while resolving anywhere on
# the host. `cleat fork rm 'x/../../../Documents'` deleted ~/Documents.
# Found 2026-07-31. Two independent fixes, one test each: validate the name,
# and resolve containment physically the way _fork_prune_excludes already does.

@test "fork verb: rm refuses a box name that walks out of the fork root" {
  mkdir -p "$TEST_TEMP/victim"
  echo "important" > "$TEST_TEMP/victim/keep.txt"
  mkdir -p "$CLEAT_FORKS_DIR/$(container_name_for "$TEST_TEMP/project" x)"
  container_exists() { return 1; }
  run cmd_fork rm 'x/../../../victim' <<< "y"
  assert_failure
  assert_output --partial "Invalid box name"
  [ -f "$TEST_TEMP/victim/keep.txt" ]
}

@test "fork verb: refresh refuses a box name that walks out of the fork root" {
  mkdir -p "$TEST_TEMP/victim"
  echo "important" > "$TEST_TEMP/victim/keep.txt"
  mkdir -p "$CLEAT_FORKS_DIR/$(container_name_for "$TEST_TEMP/project" x)"
  container_exists() { return 1; }
  run cmd_fork refresh 'x/../../../victim' <<< "y"
  assert_failure
  assert_output --partial "Invalid box name"
  [ -f "$TEST_TEMP/victim/keep.txt" ]
  # and the project was not written over the victim either
  [ ! -e "$TEST_TEMP/victim/src" ]
}

@test "fork verb: path refuses an invalid box name instead of printing a path" {
  run cmd_fork path 'Bad Name'
  assert_failure
  assert_output --partial "Invalid box name"
}

@test "fork verb: rm refuses a stray second positional like every box-aware verb" {
  run cmd_fork rm main extra
  assert_failure
  assert_output --partial "Unexpected argument"
}

@test "fork verb: the tree delete refuses a path that only textually starts with the root" {
  # Defence in depth for the above: even handed a crafted path directly, the
  # delete must resolve containment physically. A fork copy is always exactly
  # one level under the fork root.
  mkdir -p "$TEST_TEMP/victim" "$CLEAT_FORKS_DIR/copy"
  echo "important" > "$TEST_TEMP/victim/keep.txt"
  run _fork_rm_tree "$CLEAT_FORKS_DIR/copy/../../../victim"
  assert_failure
  assert_output --partial "Refusing to delete outside"
  [ -f "$TEST_TEMP/victim/keep.txt" ]
}

@test "fork verb: the tree copy refuses a destination that only textually starts with the root" {
  # _fork_copy_tree rm -rf's its destination before moving the copy into place,
  # so the same textual guard let refresh both delete AND overwrite a host dir.
  mkdir -p "$TEST_TEMP/victim" "$CLEAT_FORKS_DIR/copy"
  echo "important" > "$TEST_TEMP/victim/keep.txt"
  run _fork_copy_tree "$TEST_TEMP/project" "$CLEAT_FORKS_DIR/copy/../../../victim"
  assert_failure
  assert_output --partial "Refusing to write a fork outside"
  [ -f "$TEST_TEMP/victim/keep.txt" ]
  [ ! -e "$TEST_TEMP/victim/src" ]
}

@test "fork verb: a normal one-level copy path is still accepted by both guards" {
  # The containment hardening must not refuse the only shape that is real.
  mkdir -p "$CLEAT_FORKS_DIR"
  run _fork_copy_tree "$TEST_TEMP/project" "$CLEAT_FORKS_DIR/$CNAME"
  assert_success
  [ -f "$CLEAT_FORKS_DIR/$CNAME/src/app.js" ]
  run _fork_rm_tree "$CLEAT_FORKS_DIR/$CNAME"
  assert_success
  [ ! -e "$CLEAT_FORKS_DIR/$CNAME" ]
}

# ── the daemon-down false negative ──────────────────────────────────────────
#
# container_exists is `docker ps -a | grep -q`, which returns FALSE when the
# daemon is merely stopped. cmd_status already guards on this ("the old line
# lied after every reboot"); the fork verb, written later, did not. So
# `cleat fork prune` read every live box as an orphan and deleted every
# workspace copy on the machine, uncommitted agent work included, on a laptop
# that had simply not started Docker yet. With --yes it did it without asking.
# Found 2026-07-31. This is the worst defect the fork feature has had.

@test "fork verb: prune refuses to delete anything when the daemon is unreachable" {
  mkdir -p "$CLEAT_FORKS_DIR/cleat-a-11112222-main" "$CLEAT_FORKS_DIR/cleat-b-33334444-main"
  echo "uncommitted work" > "$CLEAT_FORKS_DIR/cleat-a-11112222-main/WIP.txt"
  _daemon_up() { return 1; }
  container_exists() { return 1; }   # what a down daemon actually reports
  run cmd_fork prune --yes
  assert_failure
  assert_output --partial "Docker is not running"
  [ -f "$CLEAT_FORKS_DIR/cleat-a-11112222-main/WIP.txt" ]
  [ -d "$CLEAT_FORKS_DIR/cleat-b-33334444-main" ]
}

@test "fork verb: prune still works normally when the daemon is up" {
  mkdir -p "$CLEAT_FORKS_DIR/cleat-orphan-11112222-main"
  _daemon_up() { return 0; }
  container_exists() { return 1; }
  run cmd_fork prune --yes
  assert_success
  [ ! -e "$CLEAT_FORKS_DIR/cleat-orphan-11112222-main" ]
}

@test "fork verb: list does not call every box orphaned when the daemon is down" {
  # The list is read-only so it still prints, but it must not label a live box
  # "no box" and must not point the user at prune, which would be the delete.
  mkdir -p "$CLEAT_FORKS_DIR/cleat-a-11112222-main"
  _daemon_up() { return 1; }
  container_exists() { return 1; }
  run cmd_fork
  assert_success
  refute_output --partial "no box"
  assert_output --partial "Docker is not running"
}

@test "fork: an unreadable subdirectory does not make a copy report 0 KB" {
  [ "$(id -u)" -ne 0 ] || skip "root descends into any directory, so du never fails"
  # du prints a valid total AND exits non-zero when it cannot descend into one
  # subdir. Under the CLI's `set -o pipefail` the pipeline's failure discarded
  # that total, so `cleat fork list`, `fork rm` and `fork prune` all reported
  # "0 KB apparent" for a real multi-gigabyte copy.
  set -o pipefail
  local d="$CLEAT_FORKS_DIR/cleat-size-11112222-main"
  mkdir -p "$d/data" "$d/locked/inner"
  dd if=/dev/zero of="$d/data/blob" bs=1024 count=512 2>/dev/null
  chmod 000 "$d/locked"
  local kb; kb="$(_fork_size_kb "$d")"
  chmod 755 "$d/locked"
  [ "$kb" -gt 100 ] || { echo "expected a real size, got ${kb} KB"; return 1; }
}

@test "fork: the session key replaces EVERY non-alphanumeric, not only / and ." {
  # The other half the dot fix still missed. Claude Code encodes every
  # character outside [A-Za-z0-9] as a dash, dashes themselves excepted.
  # Measured against the bundled Claude Code 2.1.220 on 2026-07-31 by running
  # it in a directory literally named  a_b c+d@e#f%g(h)i,j=k~l  and reading the
  # key it created: every one of those characters came back as a single dash.
  # Underscore is the one that matters in practice: my_app, foo_bar and
  # snake_case repo names are everywhere, and each of them got a session
  # mountpoint at a key Claude Code never looks at. Under the docker cap that
  # parent is :ro, so Claude could not create the right one either and
  # sessions plus memory silently did not persist. Same failure the dot bug
  # caused, reached by a commoner path.
  run _claude_session_key "/home/u/my_app"
  assert_success
  assert_output "-home-u-my-app"

  run _claude_session_key "/w/a_b c+d@e#f%g(h)i,j=k~l"
  assert_success
  assert_output "-w-a-b-c-d-e-f-g-h-i-j-k-l"
}

@test "fork: the session key leaves an already-safe path byte-identical" {
  # The compatibility half: widening the encoder must not re-key the paths
  # that were already correct, or every existing user loses their history.
  run _claude_session_key "/Users/marcin/Workspaces/cleat"
  assert_output "-Users-marcin-Workspaces-cleat"
  run _claude_session_key "/Users/marcin/.config/cleat/forks/cleat-demo-ab8ed4e5-feat-a"
  assert_output "-Users-marcin--config-cleat-forks-cleat-demo-ab8ed4e5-feat-a"
}

@test "fork verb: rm drops a fork marker whose copy is already gone" {
  # The dead end. A marker outlives its copy on purpose, but a marker with NO
  # copy makes every later `cleat start <box>` refuse. The refusal said "drop
  # the fork with cleat rm <box>", and cleat rm deliberately KEEPS the marker,
  # while cleat fork rm bailed on the missing directory. Both documented exits
  # were closed and the box was unstartable with no way out in the message.
  _fork_mark "$CNAME"
  [ ! -d "$CLEAT_FORKS_DIR/$CNAME" ]
  container_exists() { return 1; }
  run cmd_fork rm main
  assert_success
  assert_output --partial "marker cleared"
  [ ! -e "$(_fork_marker_file "$CNAME")" ]
}

@test "fork verb: rm still refuses when there is neither a copy nor a marker" {
  # Not a fork at all: saying "cleared" would be a lie.
  container_exists() { return 1; }
  run cmd_fork rm main
  assert_failure
  assert_output --partial "No fork workspace"
}

@test "fork: the missing-copy refusal names a command that actually works" {
  # It used to name `cleat rm <box>`, which keeps the marker by design.
  _fork_mark "$CNAME"
  container_exists() { return 1; }
  _FORK_REQUESTED=false
  run _fork_preflight "$CNAME" recreate
  assert_failure
  assert_output --partial "cleat fork rm"
  refute_output --partial "drop the fork with cleat rm"
}

@test "fork verb: prune reclaims an interrupted copy's staging tree" {
  # _fork_copy_tree_locked stages into $root/.tmp.<pid> and renames. A copy
  # killed part way strands that tree, and _fork_all_dirs globs "$root"/* which
  # skips dotfiles, so it was invisible to fork list, uncounted by prune and
  # never reclaimed: a silent disk leak the size of the project.
  _daemon_up() { return 0; }
  container_exists() { return 1; }
  mkdir -p "$CLEAT_FORKS_DIR/.tmp.999999/src"
  echo "half a copy" > "$CLEAT_FORKS_DIR/.tmp.999999/src/app.js"
  run cmd_fork prune --yes
  assert_success
  assert_output --partial "interrupted"
  [ ! -e "$CLEAT_FORKS_DIR/.tmp.999999" ]
}

@test "fork verb: prune leaves a staging tree whose copy is still running" {
  # A concurrent cleat must never have its half-written copy deleted.
  _daemon_up() { return 0; }
  container_exists() { return 1; }
  mkdir -p "$CLEAT_FORKS_DIR/.tmp.$$/src"
  run cmd_fork prune --yes
  assert_success
  [ -d "$CLEAT_FORKS_DIR/.tmp.$$" ]
  rm -rf "$CLEAT_FORKS_DIR/.tmp.$$"
}

@test "fork verb: a staging tree is not listed as a workspace copy" {
  _daemon_up() { return 0; }
  mkdir -p "$CLEAT_FORKS_DIR/.tmp.999999"
  container_exists() { return 1; }
  run cmd_fork
  assert_success
  refute_output --partial ".tmp."
}

# ── fork start/run are session launches ─────────────────────────────────────

@test "fork verb: fork run reaches the session preflights, like start --fork" {
  # main() dispatched `fork` outside the block that runs the CLI-update check,
  # Docker autostart, idle sweep, pressure check and config gate, so
  # `cleat fork start` was NOT the same command as `cleat start --fork` even
  # though both its own help and cleat help say it is. With the daemon down it
  # skipped the autostart every other launch verb gets.
  _ensure_daemon() { echo "PREFLIGHT-RAN"; }
  _maybe_prompt_cli_update() { :; }
  _maybe_sweep_idle_boxes() { echo "SWEEP-ARG:[$*]"; }
  _maybe_check_docker_pressure() { :; }
  _maybe_show_release_highlight() { :; }
  _maybe_announce_docker_ready() { :; }
  _maybe_gate_on_docker_config() { :; }
  cmd_fork() { :; }
  run main fork run feat-a
  assert_success
  assert_output --partial "PREFLIGHT-RAN"
  # and the subcommand is stripped before the sweep, which uses $1 as the box
  # to SKIP: passing "start" would have let it stop the box being launched.
  assert_output --partial "SWEEP-ARG:[feat-a]"
}

@test "fork verb: fork start reaches the session preflights too" {
  _ensure_daemon() { echo "PREFLIGHT-RAN"; }
  _maybe_prompt_cli_update() { :; }
  _maybe_sweep_idle_boxes() { :; }
  _maybe_check_docker_pressure() { :; }
  _maybe_show_release_highlight() { :; }
  _maybe_announce_docker_ready() { :; }
  _maybe_gate_on_docker_config() { :; }
  cmd_fork() { :; }
  run main fork start feat-a
  assert_success
  assert_output --partial "PREFLIGHT-RAN"
}

@test "fork verb: a read-only fork subcommand never boots the daemon" {
  # The other half of the same dispatch rule: stop/status/nuke and the
  # read-only fork subcommands must never start a VM.
  _ensure_daemon() { echo "PREFLIGHT-RAN"; }
  cmd_fork() { :; }
  run main fork path feat-a
  assert_success
  refute_output --partial "PREFLIGHT-RAN"
}

@test "fork verb: bare cleat fork never boots the daemon" {
  _ensure_daemon() { echo "PREFLIGHT-RAN"; }
  cmd_fork() { :; }
  run main fork
  assert_success
  refute_output --partial "PREFLIGHT-RAN"
}

@test "fork verb: prune ignores a directory that is not a cleat workspace copy" {
  # The fork root is user-settable via [fork] dir, so prune must not assume it
  # owns everything one level under it. It used to delete ANY directory there,
  # which is severe if someone points [fork] dir at a path holding anything
  # else. Every real copy is named by container_name_for, so it starts cleat-.
  _daemon_up() { return 0; }
  container_exists() { return 1; }
  mkdir -p "$CLEAT_FORKS_DIR/cleat-orphan-11112222-main"
  mkdir -p "$CLEAT_FORKS_DIR/my-important-notes"
  echo "not cleat's" > "$CLEAT_FORKS_DIR/my-important-notes/keep.txt"
  run cmd_fork prune --yes
  assert_success
  [ ! -e "$CLEAT_FORKS_DIR/cleat-orphan-11112222-main" ]
  [ -f "$CLEAT_FORKS_DIR/my-important-notes/keep.txt" ]
}

@test "fork verb: list ignores a directory that is not a workspace copy" {
  _daemon_up() { return 0; }
  container_exists() { return 1; }
  mkdir -p "$CLEAT_FORKS_DIR/my-important-notes"
  run cmd_fork
  assert_success
  refute_output --partial "my-important-notes"
}

@test "fork: a named box's [fork] excludes come from its own .cleat.<box>" {
  # The excludes were read from $project/.cleat unconditionally, so a named box
  # using .cleat.<box> had its caps honoured from that file and its excludes
  # read from a different one.
  mkdir -p "$TEST_TEMP/project/node_modules/pkg"
  echo dep > "$TEST_TEMP/project/node_modules/pkg/i.js"
  printf '[fork]\nexclude = node_modules\n' > "$TEST_TEMP/project/.cleat.feat"
  printf '[caps]\ngit\n' > "$TEST_TEMP/project/.cleat"
  local dst="$CLEAT_FORKS_DIR/boxcopy"
  _fork_copy_tree "$TEST_TEMP/project" "$dst"
  _fork_prune_excludes "$dst" "$TEST_TEMP/project" feat
  [ ! -e "$dst/node_modules" ] || { echo "the box's own exclude was ignored"; return 1; }
  [ -f "$dst/src/app.js" ]
}
