#!/usr/bin/env bats
# ─────────────────────────────────────────────────────────────────────────────
# Kits: curated per-box Claude pre-configurations (concept/34-kits.md).
#
# Covers: selection storage (host-side, keyed by cname), the overlay
# generation (user-first merge, agents copy, collisions, in-place rewrites,
# self-heal), the cmd_run mask mounts (:ro), the start/resume refresh, and
# the cmd_kit command surface (enable/off/show/list, the pre-kit rebuild
# offer, arg validation).
# ─────────────────────────────────────────────────────────────────────────────
load "../setup"

setup() {
  _common_setup
  use_docker_stub
  source_cli

  # Re-point every config-derived dir at the test temp (they were derived
  # from CLEAT_CONFIG_DIR at source time).
  CLEAT_CONFIG_DIR="$TEST_TEMP/cleat-config"
  CLEAT_GLOBAL_CONFIG="$CLEAT_CONFIG_DIR/config"
  CLEAT_GLOBAL_ENV="$CLEAT_CONFIG_DIR/env"
  CLEAT_RUN_DIR="$CLEAT_CONFIG_DIR/run"
  CLEAT_KITS_DIR="$CLEAT_CONFIG_DIR/kits"
  CLEAT_BOXES_DIR="$CLEAT_CONFIG_DIR/boxes"
  CLEAT_PROJECTS_DIR="$CLEAT_CONFIG_DIR/projects"
  CLEAT_TRUST_FILE="$CLEAT_CONFIG_DIR/trust"
  _first_run_tip_file="$CLEAT_CONFIG_DIR/.tip-shown"
  mkdir -p "$CLEAT_CONFIG_DIR"

  # Quiet the machinery unrelated to kits
  _host_clip_cmd() { echo ""; }
  check_for_update() { true; }
  check_drift() { true; }
  _resolve_config_drift() { true; }
  show_first_run_tip() { true; }

  mkdir -p "$TEST_TEMP/project"
  cd "$TEST_TEMP/project"
  CNAME="$(container_name_for "$TEST_TEMP/project")"
}

teardown() { _common_teardown; }

# ── Selection storage ────────────────────────────────────────────────────────

@test "kit: selection write/read roundtrip keyed by cname" {
  _box_kit_write "$CNAME" "plan-big-execute-small"
  run _box_kit_read "$CNAME"
  assert_success
  assert_output "plan-big-execute-small"
}

@test "kit: selection remove clears the file" {
  _box_kit_write "$CNAME" "plan-big-execute-small"
  _box_kit_remove "$CNAME"
  run _box_kit_read "$CNAME"
  assert_output ""
}

@test "kit: cmd_rm removes the kit selection even with no container" {
  mock_docker_ps ""
  mock_docker_ps_a ""
  _box_kit_write "$CNAME" "plan-big-execute-small"
  run cmd_rm
  assert_success
  [ ! -f "$CLEAT_KITS_DIR/$CNAME" ]
}

@test "kit: cmd_rm removes the kit selection AND run-dir overlay when the container exists (F36)" {
  mock_docker_ps ""
  mock_docker_ps_a "$CNAME"
  _box_kit_write "$CNAME" "plan-big-execute-small"
  mkdir -p "$CLEAT_RUN_DIR/$CNAME/kit/agents"
  : > "$CLEAT_RUN_DIR/$CNAME/kit/CLAUDE.md"
  run cmd_rm
  assert_success
  run grep -q "^docker rm $CNAME" "$DOCKER_CALLS"
  assert_success
  [ ! -f "$CLEAT_KITS_DIR/$CNAME" ]
  [ ! -d "$CLEAT_RUN_DIR/$CNAME" ]
}

# ── Overlay generation: merge semantics ──────────────────────────────────────

@test "kit: merged CLAUDE.md keeps user content first, kit section appended" {
  echo "MY GLOBAL RULES" > "$HOME/.claude/CLAUDE.md"
  _box_kit_write "$CNAME" "plan-big-execute-small"
  _generate_kit_overlay "$CNAME"
  run head -1 "$CLEAT_RUN_DIR/$CNAME/kit/CLAUDE.md"
  assert_output "MY GLOBAL RULES"
  run cat "$CLEAT_RUN_DIR/$CNAME/kit/CLAUDE.md"
  assert_output --partial "Cleat kit: plan-big-execute-small"
  assert_output --partial "plan-big / execute-small team"
}

@test "kit: fragment routes workflow stages through kit agents" {
  _box_kit_write "$CNAME" "plan-big-execute-small"
  _generate_kit_overlay "$CNAME"
  run cat "$CLEAT_RUN_DIR/$CNAME/kit/CLAUDE.md"
  assert_output --partial "agentType: 'scout' on"
  assert_output --partial "agentType: 'worker' on implementation stages"
  assert_output --partial "runs on the expensive session model"
}

@test "kit: fragment bans built-in agents and demands a loud kit failure" {
  _box_kit_write "$CNAME" "plan-big-execute-small"
  _generate_kit_overlay "$CNAME"
  run cat "$CLEAT_RUN_DIR/$CNAME/kit/CLAUDE.md"
  assert_output --partial "are the only subagents you dispatch"
  assert_output --partial "kit is broken instead of quietly working around it"
}

@test "kit: fragment dispatch trigger covers sizable single-file work" {
  _box_kit_write "$CNAME" "plan-big-execute-small"
  _generate_kit_overlay "$CNAME"
  run cat "$CLEAT_RUN_DIR/$CNAME/kit/CLAUDE.md"
  assert_output --partial "or a sizable"
  assert_output --partial "change within one file"
}

@test "kit: fragment keeps locating on scout even for judgment reads" {
  _box_kit_write "$CNAME" "plan-big-execute-small"
  _generate_kit_overlay "$CNAME"
  run cat "$CLEAT_RUN_DIR/$CNAME/kit/CLAUDE.md"
  assert_output --partial "have scout locate it, then read the located code yourself"
}

@test "kit: worker agent is tool-pinned to executor tools" {
  _box_kit_write "$CNAME" "plan-big-execute-small"
  _generate_kit_overlay "$CNAME"
  run cat "$CLEAT_RUN_DIR/$CNAME/kit/agents/kit-worker.md"
  assert_output --partial "tools: Read, Edit, Write, Grep, Glob, Bash"
}

@test "kit: vanilla box gets a plain pass-through copy, no kit marker" {
  echo "MY GLOBAL RULES" > "$HOME/.claude/CLAUDE.md"
  _generate_kit_overlay "$CNAME"
  run cat "$CLEAT_RUN_DIR/$CNAME/kit/CLAUDE.md"
  assert_output "MY GLOBAL RULES"
}

@test "kit: missing host CLAUDE.md yields an empty (not absent) mask source" {
  rm -f "$HOME/.claude/CLAUDE.md"
  _generate_kit_overlay "$CNAME"
  [ -f "$CLEAT_RUN_DIR/$CNAME/kit/CLAUDE.md" ]
  [ ! -s "$CLEAT_RUN_DIR/$CNAME/kit/CLAUDE.md" ]
}

@test "kit: agents dir merges user agents with kit-prefixed agents" {
  mkdir -p "$HOME/.claude/agents"
  echo "user agent body" > "$HOME/.claude/agents/my-agent.md"
  _box_kit_write "$CNAME" "plan-big-execute-small"
  _generate_kit_overlay "$CNAME"
  [ -f "$CLEAT_RUN_DIR/$CNAME/kit/agents/my-agent.md" ]
  [ -f "$CLEAT_RUN_DIR/$CNAME/kit/agents/kit-worker.md" ]
  [ -f "$CLEAT_RUN_DIR/$CNAME/kit/agents/kit-scout.md" ]
  run cat "$CLEAT_RUN_DIR/$CNAME/kit/agents/kit-worker.md"
  assert_output --partial "model: sonnet"
}

@test "kit: a same-FILENAME user agent wins over the kit's copy" {
  mkdir -p "$HOME/.claude/agents"
  echo "USER OWNS THIS NAME" > "$HOME/.claude/agents/kit-worker.md"
  _box_kit_write "$CNAME" "plan-big-execute-small"
  _generate_kit_overlay "$CNAME"
  run cat "$CLEAT_RUN_DIR/$CNAME/kit/agents/kit-worker.md"
  assert_output "USER OWNS THIS NAME"
}

@test "kit: a user agent with the SAME NAME (different filename) suppresses the kit's agent" {
  # The realistic collision: a user's own scout.md declaring name: scout.
  # Claude dispatches by name, so two agents named 'scout' would be ambiguous
  # and could hand the read-only role to the user's writable agent. The kit's
  # scout must be skipped, leaving exactly one 'scout' (the user's).
  mkdir -p "$HOME/.claude/agents"
  printf -- '---\nname: scout\ntools: Read, Write, Edit\n---\nmine\n' > "$HOME/.claude/agents/my-scout.md"
  _box_kit_write "$CNAME" "plan-big-execute-small"
  _generate_kit_overlay "$CNAME"
  # the user's file is present, the kit's kit-scout.md is NOT (name collision)
  [ -f "$CLEAT_RUN_DIR/$CNAME/kit/agents/my-scout.md" ]
  [ ! -f "$CLEAT_RUN_DIR/$CNAME/kit/agents/kit-scout.md" ]
  # exactly one agent declares name: scout (tr strips BSD wc's padding)
  run bash -c "grep -l '^name: scout' \"$CLEAT_RUN_DIR/$CNAME/kit/agents\"/*.md | wc -l | tr -d ' '"
  assert_output "1"
  # the kit's worker (no user collision) still lands
  [ -f "$CLEAT_RUN_DIR/$CNAME/kit/agents/kit-worker.md" ]
}

@test "kit: _agent_name reads the frontmatter name, not the filename" {
  local f="$TEST_TEMP/some-file.md"
  printf -- '---\nname: reviewer\nmodel: sonnet\n---\nbody\n' > "$f"
  run _agent_name "$f"
  assert_output "reviewer"
}

@test "kit: enable warns by AGENT NAME when a user agent shadows a kit agent" {
  mock_docker_ps ""
  mock_docker_ps_a ""
  mkdir -p "$HOME/.claude/agents"
  printf -- '---\nname: worker\n---\nmine\n' > "$HOME/.claude/agents/my-worker.md"
  run cmd_kit plan-big-execute-small <<< "y"
  assert_success
  assert_output --partial "already have an agent named"
  assert_output --partial "worker"
}

@test "kit: unknown selection name degrades to vanilla instead of failing" {
  echo "MY GLOBAL RULES" > "$HOME/.claude/CLAUDE.md"
  _box_kit_write "$CNAME" "no-such-kit"
  run _generate_kit_overlay "$CNAME"
  assert_success
  run cat "$CLEAT_RUN_DIR/$CNAME/kit/CLAUDE.md"
  assert_output "MY GLOBAL RULES"
}

@test "kit: regeneration rewrites in place (inodes stable for live binds)" {
  _box_kit_write "$CNAME" "plan-big-execute-small"
  _generate_kit_overlay "$CNAME"
  local file_ino dir_ino file_ino2 dir_ino2
  file_ino="$(ls -i "$CLEAT_RUN_DIR/$CNAME/kit/CLAUDE.md" | awk '{print $1}')"
  dir_ino="$(ls -di "$CLEAT_RUN_DIR/$CNAME/kit/agents" | awk '{print $1}')"
  _generate_kit_overlay "$CNAME"
  file_ino2="$(ls -i "$CLEAT_RUN_DIR/$CNAME/kit/CLAUDE.md" | awk '{print $1}')"
  dir_ino2="$(ls -di "$CLEAT_RUN_DIR/$CNAME/kit/agents" | awk '{print $1}')"
  [ "$file_ino" = "$file_ino2" ]
  [ "$dir_ino" = "$dir_ino2" ]
}

@test "kit: switching kits off clears the kit content on regeneration" {
  echo "MY GLOBAL RULES" > "$HOME/.claude/CLAUDE.md"
  _box_kit_write "$CNAME" "plan-big-execute-small"
  _generate_kit_overlay "$CNAME"
  _box_kit_remove "$CNAME"
  _generate_kit_overlay "$CNAME"
  run cat "$CLEAT_RUN_DIR/$CNAME/kit/CLAUDE.md"
  assert_output "MY GLOBAL RULES"
  [ ! -f "$CLEAT_RUN_DIR/$CNAME/kit/agents/kit-worker.md" ]
}

@test "kit: generation self-heals a directory squatting on the CLAUDE.md path" {
  mkdir -p "$CLEAT_RUN_DIR/$CNAME/kit/CLAUDE.md"
  run _generate_kit_overlay "$CNAME"
  assert_success
  [ -f "$CLEAT_RUN_DIR/$CNAME/kit/CLAUDE.md" ]
}

# ── [kits] model overrides ───────────────────────────────────────────────────

@test "kit: default agent models are the sonnet alias" {
  _box_kit_write "$CNAME" "plan-big-execute-small"
  _generate_kit_overlay "$CNAME"
  run grep "^model:" "$CLEAT_RUN_DIR/$CNAME/kit/agents/kit-worker.md"
  assert_output "model: sonnet"
  run grep "^model:" "$CLEAT_RUN_DIR/$CNAME/kit/agents/kit-scout.md"
  assert_output "model: sonnet"
}

@test "kit: [kits] worker_model and scout_model override the emitted frontmatter" {
  cat > "$CLEAT_GLOBAL_CONFIG" << 'EOF'
[kits]
worker_model = claude-sonnet-5
scout_model = haiku
EOF
  _box_kit_write "$CNAME" "plan-big-execute-small"
  _generate_kit_overlay "$CNAME"
  run grep "^model:" "$CLEAT_RUN_DIR/$CNAME/kit/agents/kit-worker.md"
  assert_output "model: claude-sonnet-5"
  run grep "^model:" "$CLEAT_RUN_DIR/$CNAME/kit/agents/kit-scout.md"
  assert_output "model: haiku"
}

@test "kit: a non-token [kits] model value falls back to the default (frontmatter injection guard)" {
  cat > "$CLEAT_GLOBAL_CONFIG" << 'EOF'
[kits]
worker_model = sonnet; rm -rf /
scout_model = evil value
EOF
  _box_kit_write "$CNAME" "plan-big-execute-small"
  _generate_kit_overlay "$CNAME"
  run grep "^model:" "$CLEAT_RUN_DIR/$CNAME/kit/agents/kit-worker.md"
  assert_output "model: sonnet"
  run grep "^model:" "$CLEAT_RUN_DIR/$CNAME/kit/agents/kit-scout.md"
  assert_output "model: sonnet"
}

@test "kit: the confirm screen shows the effective (overridden) models" {
  mock_docker_ps ""
  mock_docker_ps_a ""
  cat > "$CLEAT_GLOBAL_CONFIG" << 'EOF'
[kits]
worker_model = haiku
EOF
  run cmd_kit plan-big-execute-small <<< "n"
  assert_success
  assert_output --partial "worker (model: haiku)"
  assert_output --partial "your session's model"
}

@test "kit: kit show reflects the overridden models" {
  cat > "$CLEAT_GLOBAL_CONFIG" << 'EOF'
[kits]
scout_model = claude-haiku-4-5-20251001
EOF
  run cmd_kit show plan-big-execute-small
  assert_success
  assert_output --partial "model: claude-haiku-4-5-20251001"
}

# ── cmd_run: mask mounts ─────────────────────────────────────────────────────

@test "kit: cmd_run mounts all three kit masks read-only" {
  mock_docker_images "cleat"
  run cmd_run "$TEST_TEMP/project"
  assert_success
  run assert_docker_run_has "$CNAME" "/kit/CLAUDE.md:/home/coder/.claude/CLAUDE.md:ro"
  assert_success
  run assert_docker_run_has "$CNAME" "/kit/agents:/home/coder/.claude/agents:ro"
  assert_success
  run assert_docker_run_has "$CNAME" "/kit/commands:/home/coder/.claude/commands:ro"
  assert_success
}

@test "kit: the commands mask is USER-level only; project commands stay writable via /workspace" {
  # A user-level ~/.claude/commands is masked :ro. A PROJECT command
  # (<project>/.claude/commands) must NOT be masked: it rides the /workspace
  # bind mount read-write, is version-controlled, and is the intended escape
  # hatch for authoring commands inside a box. Guard that cmd_run masks the
  # HOME path but never mounts anything :ro over /workspace/.claude/commands.
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project/.claude/commands"
  echo "ship it" > "$TEST_TEMP/project/.claude/commands/deploy.md"
  run cmd_run "$TEST_TEMP/project"
  assert_success
  # the project is bind-mounted whole, so /workspace carries .claude/commands
  run assert_docker_run_has "$CNAME" "$TEST_TEMP/project:/workspace"
  assert_success
  # and cleat never masks the project-level commands path (only the user-level one)
  run assert_docker_run_lacks "$CNAME" "/workspace/.claude/commands"
  assert_success
}

@test "kit: cmd_run generates the overlay and pre-creates the host targets" {
  mock_docker_images "cleat"
  rm -f "$HOME/.claude/CLAUDE.md"
  run cmd_run "$TEST_TEMP/project"
  assert_success
  [ -f "$CLEAT_RUN_DIR/$CNAME/kit/CLAUDE.md" ]
  [ -d "$CLEAT_RUN_DIR/$CNAME/kit/agents" ]
  [ -d "$CLEAT_RUN_DIR/$CNAME/kit/commands" ]
  # VirtioFS nested-mount prerequisite: targets exist in the base mount source
  [ -f "$HOME/.claude/CLAUDE.md" ]
  [ -d "$HOME/.claude/agents" ]
  [ -d "$HOME/.claude/commands" ]
}

@test "kit: overlay pass-through-copies the user's slash commands (read-only mask seed)" {
  mkdir -p "$HOME/.claude/commands/frontend"
  echo "deploy the app" > "$HOME/.claude/commands/deploy.md"
  echo "make a component" > "$HOME/.claude/commands/frontend/component.md"
  _generate_kit_overlay "$CNAME"
  # top-level and namespaced (subdir) commands both survive
  run cat "$CLEAT_RUN_DIR/$CNAME/kit/commands/deploy.md"
  assert_output "deploy the app"
  [ -f "$CLEAT_RUN_DIR/$CNAME/kit/commands/frontend/component.md" ]
}

@test "kit: commands overlay is an empty dir when the user has no commands" {
  rm -rf "$HOME/.claude/commands"
  _generate_kit_overlay "$CNAME"
  [ -d "$CLEAT_RUN_DIR/$CNAME/kit/commands" ]
  run bash -c "ls -A \"$CLEAT_RUN_DIR/$CNAME/kit/commands\""
  assert_output ""
}

@test "kit: commands regen drops a command the user deleted (in-place refresh)" {
  mkdir -p "$HOME/.claude/commands"
  echo "old" > "$HOME/.claude/commands/gone.md"
  _generate_kit_overlay "$CNAME"
  [ -f "$CLEAT_RUN_DIR/$CNAME/kit/commands/gone.md" ]
  rm -f "$HOME/.claude/commands/gone.md"
  _generate_kit_overlay "$CNAME"
  [ ! -f "$CLEAT_RUN_DIR/$CNAME/kit/commands/gone.md" ]
}

@test "kit: commands pass-through dereferences symlinked commands" {
  # Dotfile-repo users symlink their commands; a copied symlink would point
  # at a host path that does not exist inside the box.
  mkdir -p "$HOME/.claude/commands" "$HOME/dotfiles"
  echo "real content" > "$HOME/dotfiles/deploy.md"
  ln -s "$HOME/dotfiles/deploy.md" "$HOME/.claude/commands/deploy.md"
  _generate_kit_overlay "$CNAME"
  [ -f "$CLEAT_RUN_DIR/$CNAME/kit/commands/deploy.md" ]
  [ ! -L "$CLEAT_RUN_DIR/$CNAME/kit/commands/deploy.md" ]
  run cat "$CLEAT_RUN_DIR/$CNAME/kit/commands/deploy.md"
  assert_output "real content"
}

@test "kit: a dangling symlink in the commands overlay is cleared on regen" {
  # -e alone skips dangling symlinks in the clear loop, so a deleted host
  # command copied as a symlink would stay visible in the box forever.
  mkdir -p "$CLEAT_RUN_DIR/$CNAME/kit/commands"
  ln -s "$TEST_TEMP/gone-target" "$CLEAT_RUN_DIR/$CNAME/kit/commands/stale.md"
  _generate_kit_overlay "$CNAME"
  [ ! -L "$CLEAT_RUN_DIR/$CNAME/kit/commands/stale.md" ]
  [ ! -e "$CLEAT_RUN_DIR/$CNAME/kit/commands/stale.md" ]
}

@test "kit: cmd_run bakes an enabled kit into the overlay" {
  mock_docker_images "cleat"
  _box_kit_write "$CNAME" "plan-big-execute-small"
  run cmd_run "$TEST_TEMP/project"
  assert_success
  run cat "$CLEAT_RUN_DIR/$CNAME/kit/CLAUDE.md"
  assert_output --partial "Cleat kit: plan-big-execute-small"
  [ -f "$CLEAT_RUN_DIR/$CNAME/kit/agents/kit-worker.md" ]
}

# ── start/resume refresh ─────────────────────────────────────────────────────

@test "kit: cmd_resume refreshes the kit overlay for a kitted box" {
  mock_docker_images "cleat"
  mock_docker_ps "$CNAME"
  mock_docker_ps_a "$CNAME"
  _container_has_kit_mounts() { return 0; }
  _maybe_prompt_image_rebuild() { true; }
  _maybe_prompt_init_recreate() { true; }
  exec_claude() { true; }
  _print_summary_block() { true; }
  echo "FRESH RULES" > "$HOME/.claude/CLAUDE.md"
  _box_kit_write "$CNAME" "plan-big-execute-small"
  run cmd_resume
  assert_success
  run cat "$CLEAT_RUN_DIR/$CNAME/kit/CLAUDE.md"
  assert_output --partial "FRESH RULES"
  assert_output --partial "Cleat kit: plan-big-execute-small"
}

@test "kit: cmd_resume skips the refresh for a pre-kit box" {
  mock_docker_images "cleat"
  mock_docker_ps "$CNAME"
  mock_docker_ps_a "$CNAME"
  _container_has_kit_mounts() { return 1; }
  _maybe_prompt_image_rebuild() { true; }
  _maybe_prompt_init_recreate() { true; }
  exec_claude() { true; }
  _print_summary_block() { true; }
  _box_kit_write "$CNAME" "plan-big-execute-small"
  run cmd_resume
  assert_success
  [ ! -e "$CLEAT_RUN_DIR/$CNAME/kit/CLAUDE.md" ]
}

@test "kit: cmd_start refreshes the kit overlay for a kitted box" {
  mock_docker_images "cleat"
  mock_docker_ps "$CNAME"
  mock_docker_ps_a "$CNAME"
  _container_has_kit_mounts() { return 0; }
  _maybe_prompt_image_rebuild() { true; }
  _maybe_prompt_init_recreate() { true; }
  _maybe_prompt_claude_update() { true; }
  exec_claude() { true; }
  _print_summary_block() { true; }
  show_first_run_tip() { true; }
  echo "FRESH RULES" > "$HOME/.claude/CLAUDE.md"
  _box_kit_write "$CNAME" "plan-big-execute-small"
  run cmd_start
  assert_success
  run cat "$CLEAT_RUN_DIR/$CNAME/kit/CLAUDE.md"
  assert_output --partial "FRESH RULES"
  assert_output --partial "Cleat kit: plan-big-execute-small"
}

@test "kit: cmd_start skips the refresh for a pre-kit box" {
  mock_docker_images "cleat"
  mock_docker_ps "$CNAME"
  mock_docker_ps_a "$CNAME"
  _container_has_kit_mounts() { return 1; }
  _maybe_prompt_image_rebuild() { true; }
  _maybe_prompt_init_recreate() { true; }
  _maybe_prompt_claude_update() { true; }
  exec_claude() { true; }
  _print_summary_block() { true; }
  show_first_run_tip() { true; }
  _box_kit_write "$CNAME" "plan-big-execute-small"
  run cmd_start
  assert_success
  [ ! -e "$CLEAT_RUN_DIR/$CNAME/kit/CLAUDE.md" ]
}

@test "kit: _container_has_kit_mounts reads the inspected mount destinations" {
  mock_docker_inspect "/home/coder/.claude/CLAUDE.md"
  run _container_has_kit_mounts "$CNAME"
  assert_success
  mock_docker_inspect "/workspace"
  run _container_has_kit_mounts "$CNAME"
  assert_failure
}

# ── Pre-mask boxes: recreate note ────────────────────────────────────────────

@test "kit: a box missing the commands mask gets the recreate note" {
  container_exists() { return 0; }
  mock_docker_inspect $'/home/coder/.claude/CLAUDE.md\n/home/coder/.claude/agents'
  run _maybe_note_missing_kit_masks "$CNAME"
  assert_success
  assert_output --partial "predates the read-only ~/.claude masks"
  assert_output --partial "cleat rm && cleat"
}

@test "kit: a fully masked box gets no recreate note" {
  container_exists() { return 0; }
  mock_docker_inspect $'/home/coder/.claude/CLAUDE.md\n/home/coder/.claude/agents\n/home/coder/.claude/commands'
  run _maybe_note_missing_kit_masks "$CNAME"
  assert_success
  refute_output --partial "predates"
}

@test "kit: no container, no recreate note" {
  container_exists() { return 1; }
  run _maybe_note_missing_kit_masks "$CNAME"
  assert_success
  refute_output --partial "predates"
}

@test "kit: cmd_start surfaces the recreate note for a pre-mask box" {
  mock_docker_images "cleat"
  mock_docker_ps "$CNAME"
  mock_docker_ps_a "$CNAME"
  mock_docker_inspect "/workspace"
  _container_has_kit_mounts() { return 1; }
  _maybe_prompt_image_rebuild() { true; }
  _maybe_prompt_init_recreate() { true; }
  _maybe_prompt_claude_update() { true; }
  exec_claude() { true; }
  _print_summary_block() { true; }
  show_first_run_tip() { true; }
  run cmd_start
  assert_success
  assert_output --partial "predates the read-only ~/.claude masks"
}

# ── Mask targets on the host (VirtioFS pre-create) ───────────────────────────

@test "kit: create refuses a broken symlink at ~/.claude/commands with a clear remedy" {
  mkdir -p "$HOME/.claude"
  rm -rf "$HOME/.claude/commands"
  ln -s "$HOME/no-such-target" "$HOME/.claude/commands"
  run _ensure_kit_mask_targets
  assert_failure
  assert_output --partial "broken symlink"
}

@test "kit: mask targets are created when absent and a healthy symlink passes" {
  mkdir -p "$HOME/.claude" "$HOME/real-commands"
  rm -rf "$HOME/.claude/commands"
  ln -s "$HOME/real-commands" "$HOME/.claude/commands"
  run _ensure_kit_mask_targets
  assert_success
  [ -f "$HOME/.claude/CLAUDE.md" ]
  [ -d "$HOME/.claude/agents" ]
}

# ── cmd_kit: command surface ─────────────────────────────────────────────────

@test "kit: enable writes the selection after confirm" {
  mock_docker_ps ""
  mock_docker_ps_a ""
  run cmd_kit plan-big-execute-small <<< "y"
  assert_success
  assert_output --partial "enabled for box"
  run _box_kit_read "$CNAME"
  assert_output "plan-big-execute-small"
}

@test "kit: enable confirm screen credits the Anthropic pattern" {
  mock_docker_ps ""
  mock_docker_ps_a ""
  run cmd_kit plan-big-execute-small <<< "y"
  assert_success
  assert_output --partial "Pattern from Anthropic's cookbook"
}

@test "kit: enable defaults to yes on empty confirm" {
  mock_docker_ps ""
  mock_docker_ps_a ""
  run cmd_kit plan-big-execute-small <<< ""
  assert_success
  run _box_kit_read "$CNAME"
  assert_output "plan-big-execute-small"
}

@test "kit: declining the confirm writes nothing" {
  mock_docker_ps ""
  mock_docker_ps_a ""
  run cmd_kit plan-big-execute-small <<< "n"
  assert_success
  assert_output --partial "Cancelled"
  [ ! -f "$CLEAT_KITS_DIR/$CNAME" ]
}

@test "kit: enable with a box positional targets that box's cname" {
  mock_docker_ps ""
  mock_docker_ps_a ""
  run cmd_kit plan-big-execute-small dev <<< "y"
  assert_success
  local dev_cname
  dev_cname="$(container_name_for "$TEST_TEMP/project" "dev")"
  run _box_kit_read "$dev_cname"
  assert_output "plan-big-execute-small"
}

@test "kit: enable rejects an invalid box name" {
  run cmd_kit plan-big-execute-small "BAD NAME"
  assert_failure
  assert_output --partial "Invalid box name"
}

@test "kit: unknown kit name errors and lists the library" {
  run cmd_kit bogus
  assert_failure
  assert_output --partial "Unknown kit"
  assert_output --partial "plan-big-execute-small"
}

@test "kit: enabling on a pre-kit box offers a rebuild and declining changes nothing" {
  mock_docker_ps ""
  mock_docker_ps_a "$CNAME"
  _container_has_kit_mounts() { return 1; }
  run cmd_kit plan-big-execute-small <<< "n"
  assert_success
  assert_output --partial "needs a rebuild"
  [ ! -f "$CLEAT_KITS_DIR/$CNAME" ]
}

@test "kit: accepting the pre-kit rebuild removes the container and enables" {
  mock_docker_ps ""
  mock_docker_ps_a "$CNAME"
  _container_has_kit_mounts() { return 1; }
  run cmd_kit plan-big-execute-small <<< "y"
  assert_success
  run _box_kit_read "$CNAME"
  assert_output "plan-big-execute-small"
  run grep -q "^docker rm -f $CNAME" "$DOCKER_CALLS"
  assert_success
}

@test "kit: enable on a live-agent box notes it applies next session" {
  mock_docker_ps "$CNAME"
  mock_docker_ps_a "$CNAME"
  _container_has_kit_mounts() { return 0; }
  _box_has_live_agent() { return 0; }
  run cmd_kit plan-big-execute-small <<< "y"
  assert_success
  assert_output --partial "applies from the next session"
  # The post-enable nudge names the mechanism for the named pairing: the kit
  # never touches the session model, /model inside the session does.
  assert_output --partial "pick Fable 5 with"
}

@test "kit: enable on an existing mounted box regenerates the overlay immediately (F34)" {
  # _kit_apply's in-place regen is the only refresh for cleat claude/shell
  # (no regen hook there), so it must actually rewrite the overlay now.
  mock_docker_ps "$CNAME"
  mock_docker_ps_a "$CNAME"
  _container_has_kit_mounts() { return 0; }
  _box_has_live_agent() { return 1; }
  echo "MY RULES" > "$HOME/.claude/CLAUDE.md"
  run cmd_kit plan-big-execute-small <<< "y"
  assert_success
  run cat "$CLEAT_RUN_DIR/$CNAME/kit/CLAUDE.md"
  assert_output --partial "MY RULES"
  assert_output --partial "Cleat kit: plan-big-execute-small"
  [ -f "$CLEAT_RUN_DIR/$CNAME/kit/agents/kit-worker.md" ]
}

@test "kit: off removes the selection and reports the kit" {
  mock_docker_ps ""
  mock_docker_ps_a ""
  _box_kit_write "$CNAME" "plan-big-execute-small"
  run cmd_kit off
  assert_success
  assert_output --partial "disabled"
  [ ! -f "$CLEAT_KITS_DIR/$CNAME" ]
}

@test "kit: off with no selection is a friendly no-op" {
  mock_docker_ps ""
  mock_docker_ps_a ""
  run cmd_kit off
  assert_success
  assert_output --partial "No kit enabled"
}

@test "kit: show prints the kit's full contents" {
  run cmd_kit show plan-big-execute-small
  assert_success
  assert_output --partial "kit-worker.md"
  assert_output --partial "kit-scout.md"
  assert_output --partial "model: sonnet"
  assert_output --partial "planner"
}

@test "kit: kit show prints the cookbook reference" {
  run cmd_kit show plan-big-execute-small
  assert_success
  assert_output --partial "claude-cookbooks/blob/main/managed_agents/CMA_plan_big_execute_small.ipynb"
}

@test "kit: cmd_kit list shows the library and this project's selections" {
  _box_kit_write "$CNAME" "plan-big-execute-small"
  local dev_cname
  dev_cname="$(container_name_for "$TEST_TEMP/project" "dev")"
  _box_kit_write "$dev_cname" "plan-big-execute-small"
  run cmd_kit list
  assert_success
  assert_output --partial "Cleat Kits"
  assert_output --partial "This project:"
  # A color code sits between the label and the kit name; assert separately.
  assert_output --partial "main:"
  assert_output --partial "dev:"
}

# ── Interactive picker (text mode; the TUI shares draw + apply helpers) ──────

@test "kit: bare cmd_kit on a non-TTY routes to the text picker" {
  mock_docker_ps ""
  mock_docker_ps_a ""
  run cmd_kit <<< "q"
  assert_success
  assert_output --partial "Cancelled"
  assert_output --partial "worker="
}

@test "kit: text picker enables a kit and saves a model override on done" {
  mock_docker_ps ""
  mock_docker_ps_a ""
  run _kit_picker_text <<< $'plan-big-execute-small\nworker=haiku\ndone'
  assert_success
  assert_output --partial "enabled for box"
  run _box_kit_read "$CNAME"
  assert_output "plan-big-execute-small"
  run _read_section_from_file "$CLEAT_GLOBAL_CONFIG" kits worker_model
  assert_output "haiku"
}

@test "kit: text picker q cancels with nothing written" {
  mock_docker_ps ""
  mock_docker_ps_a ""
  run _kit_picker_text <<< $'plan-big-execute-small\nworker=haiku\nq'
  assert_success
  assert_output --partial "Cancelled"
  [ ! -f "$CLEAT_KITS_DIR/$CNAME" ]
  run _read_section_from_file "$CLEAT_GLOBAL_CONFIG" kits worker_model
  assert_output ""
}

@test "kit: text picker EOF cancels cleanly" {
  mock_docker_ps ""
  mock_docker_ps_a ""
  run _kit_picker_text < /dev/null
  assert_success
  assert_output --partial "Cancelled"
}

@test "kit: text picker rejects a non-token model value and does not save it" {
  mock_docker_ps ""
  mock_docker_ps_a ""
  run _kit_picker_text <<< $'worker=evil value\ndone'
  assert_success
  assert_output --partial "Not a model token"
  run _read_section_from_file "$CLEAT_GLOBAL_CONFIG" kits worker_model
  assert_output ""
}

@test "kit: text picker warns on an unknown kit name" {
  mock_docker_ps ""
  mock_docker_ps_a ""
  run _kit_picker_text <<< $'bogus\nq'
  assert_success
  assert_output --partial "Unknown kit"
}

@test "kit: text picker none disables an enabled kit on done" {
  mock_docker_ps ""
  mock_docker_ps_a ""
  _box_kit_write "$CNAME" "plan-big-execute-small"
  run _kit_picker_text <<< $'none\ndone'
  assert_success
  assert_output --partial "disabled"
  [ ! -f "$CLEAT_KITS_DIR/$CNAME" ]
}

@test "kit: text picker lists kit descriptions" {
  mock_docker_ps ""
  mock_docker_ps_a ""
  run _kit_picker_text <<< "q"
  assert_success
  assert_output --partial "Flagship judgment"
}

@test "kit: picker draw marks the selected kit and the cursor row" {
  run _kit_picker_draw 0 "plan-big-execute-small"
  assert_output --partial "▸"
  assert_output --partial "●"
  assert_output --partial "plan-big-execute-small"
  assert_output --partial "none"
}

@test "kit: picker detail pane shows the cursored kit description" {
  run _kit_picker_draw 0 ""
  assert_output --partial "its own context window"
  assert_output --partial "coordinator-pattern cookbook"
}

@test "kit: models draw shows both roles with their models" {
  run _kit_models_draw 0 sonnet haiku
  assert_output --partial "worker"
  assert_output --partial "sonnet"
  assert_output --partial "scout"
  assert_output --partial "haiku"
}

@test "kit: model cycle walks the stock choices and keeps a custom value reachable" {
  run _kit_next_model sonnet ""
  assert_output "haiku"
  run _kit_next_model haiku ""
  assert_output "opus"
  run _kit_next_model inherit ""
  assert_output "sonnet"
  run _kit_next_model inherit "claude-sonnet-5"
  assert_output "claude-sonnet-5"
  run _kit_next_model claude-sonnet-5 "claude-sonnet-5"
  assert_output "sonnet"
}

@test "kit: reverse model cycle mirrors the forward ring" {
  run _kit_prev_model sonnet ""
  assert_output "inherit"
  run _kit_prev_model haiku ""
  assert_output "sonnet"
  run _kit_prev_model sonnet "claude-sonnet-5"
  assert_output "claude-sonnet-5"
}

# ── Interactive TUI event loops (F32; driven via the _read_keypress seam) ─────
#
# The real _read_keypress is called via $(...) command substitution, so any
# counter it increments lives in a subshell and is lost. The scripted queue
# must therefore be file-backed (state on disk survives the subshell). The
# fallback key ends any loop that over-reads, so a bug can't hang the suite.

_tui_keys() {   # usage: _tui_keys ENTER SPACE ENTER   (last arg = the over-read fallback)
  printf '%s\n' "$@" > "$TEST_TEMP/keys"
  _read_keypress() {
    local f="$TEST_TEMP/keys" k
    k="$(head -n1 "$f" 2>/dev/null)"
    tail -n +2 "$f" > "$f.rest" 2>/dev/null && mv "$f.rest" "$f" 2>/dev/null
    [ -n "$k" ] && echo "$k" || echo ENTER
  }
}

@test "kit: TUI picker ENTER on a kit → models screen ENTER enables it" {
  mock_docker_ps ""
  mock_docker_ps_a ""
  _tui_keys ENTER ENTER
  run _kit_picker_tui
  assert_success
  assert_output --partial "enabled for box"
  run _box_kit_read "$CNAME"
  assert_output "plan-big-execute-small"
}

@test "kit: TUI picker RIGHT selects like ENTER" {
  mock_docker_ps ""
  mock_docker_ps_a ""
  # RIGHT stands in for the real \033[C sequence _read_keypress now decodes
  # (regression v1.2.0): screen 1's row select accepts RIGHT same as ENTER.
  _tui_keys RIGHT ENTER
  run _kit_picker_tui
  assert_success
  assert_output --partial "enabled for box"
  run _box_kit_read "$CNAME"
  assert_output "plan-big-execute-small"
}

@test "kit: TUI models SPACE cycles the worker model and saves it to the RIGHT role" {
  mock_docker_ps ""
  mock_docker_ps_a ""
  # ENTER (pick kit) → SPACE (cursor 0 = worker: sonnet→haiku) → ENTER (save)
  _tui_keys ENTER SPACE ENTER
  run _kit_picker_tui
  assert_success
  run _read_section_from_file "$CLEAT_GLOBAL_CONFIG" kits worker_model
  assert_output "haiku"
  # scout untouched (swap-guard: worker override must not land as scout_model)
  run _read_section_from_file "$CLEAT_GLOBAL_CONFIG" kits scout_model
  assert_output ""
}

@test "kit: TUI models RIGHT cycles the worker model like SPACE" {
  mock_docker_ps ""
  mock_docker_ps_a ""
  # ENTER (pick kit) → RIGHT (cursor 0 = worker: sonnet→haiku) → ENTER (save)
  # RIGHT stands in for the real \033[C sequence (regression v1.2.0).
  _tui_keys ENTER RIGHT ENTER
  run _kit_picker_tui
  assert_success
  run _read_section_from_file "$CLEAT_GLOBAL_CONFIG" kits worker_model
  assert_output "haiku"
  run _read_section_from_file "$CLEAT_GLOBAL_CONFIG" kits scout_model
  assert_output ""
}

@test "kit: TUI models LEFT cycles the model backwards" {
  mock_docker_ps ""
  mock_docker_ps_a ""
  # ENTER (pick kit) → LEFT (cursor 0 = worker: sonnet→inherit, no custom
  # pin so the ring wraps to the last stock choice) → ENTER (save)
  _tui_keys ENTER LEFT ENTER
  run _kit_picker_tui
  assert_success
  run _read_section_from_file "$CLEAT_GLOBAL_CONFIG" kits worker_model
  assert_output "inherit"
  run _read_section_from_file "$CLEAT_GLOBAL_CONFIG" kits scout_model
  assert_output ""
}

@test "kit: TUI picker DOWN to 'none' + ENTER disables an enabled kit" {
  mock_docker_ps ""
  mock_docker_ps_a ""
  _box_kit_write "$CNAME" "plan-big-execute-small"
  _tui_keys DOWN ENTER
  run _kit_picker_tui
  assert_success
  assert_output --partial "disabled"
  [ ! -f "$CLEAT_KITS_DIR/$CNAME" ]
}

@test "kit: TUI picker q cancels with nothing written" {
  mock_docker_ps ""
  mock_docker_ps_a ""
  _tui_keys QUIT QUIT
  run _kit_picker_tui
  assert_success
  assert_output --partial "Cancelled"
  [ ! -f "$CLEAT_KITS_DIR/$CNAME" ]
}

@test "kit: TUI picker survives PgUp without cancelling" {
  mock_docker_ps ""
  mock_docker_ps_a ""
  # OTHER stands in for an unrecognized escape sequence like PgUp (\033[5~),
  # which _read_keypress now decodes as OTHER, not ESC (regression v1.2.0).
  # The picker loop has no case for OTHER, so it must be a no-op, not a
  # cancel: only the trailing QUIT should produce "Cancelled.".
  _tui_keys OTHER QUIT QUIT
  run _kit_picker_tui
  assert_success
  assert_output --partial "Cancelled."
  local cancel_count
  cancel_count="$(grep -c "Cancelled\." <<< "$output")"
  [ "$cancel_count" -eq 1 ]
  [ ! -f "$CLEAT_KITS_DIR/$CNAME" ]
}

@test "kit: TUI models q cancels without enabling (kit picked, models cancelled)" {
  mock_docker_ps ""
  mock_docker_ps_a ""
  _tui_keys ENTER QUIT QUIT
  run _kit_picker_tui
  assert_success
  assert_output --partial "Cancelled"
  [ ! -f "$CLEAT_KITS_DIR/$CNAME" ]
}

# ── [kits] config writer ─────────────────────────────────────────────────────

@test "kit: writer emits [kits] with only the non-default keys" {
  _write_kits_to_file "$CLEAT_GLOBAL_CONFIG" haiku sonnet
  run cat "$CLEAT_GLOBAL_CONFIG"
  assert_output "[kits]
worker_model = haiku"
}

@test "kit: writer omits the [kits] section entirely when both are defaults" {
  _write_kits_to_file "$CLEAT_GLOBAL_CONFIG" haiku sonnet
  _write_kits_to_file "$CLEAT_GLOBAL_CONFIG" sonnet sonnet
  run grep -c "kits" "$CLEAT_GLOBAL_CONFIG"
  assert_output "0"
}

@test "kit: writer preserves [caps] and [resources] sections" {
  cat > "$CLEAT_GLOBAL_CONFIG" << 'EOF'
[caps]
git
ssh
[resources]
memory = 8g
[kits]
worker_model = opus
EOF
  _write_kits_to_file "$CLEAT_GLOBAL_CONFIG" haiku haiku
  run _read_caps_from_file "$CLEAT_GLOBAL_CONFIG"
  assert_output "git
ssh"
  run _read_section_from_file "$CLEAT_GLOBAL_CONFIG" resources memory
  assert_output "8g"
  run _read_section_from_file "$CLEAT_GLOBAL_CONFIG" kits worker_model
  assert_output "haiku"
  # the old [kits] key was replaced, not duplicated
  run grep -c "worker_model" "$CLEAT_GLOBAL_CONFIG"
  assert_output "1"
}

@test "kit: writer survives strict mode with default models (regression: silent death on done)" {
  # A false `[[ ]] && echo` as the writer's last list made the function return
  # 1 and killed the strict-mode text picker on "done". Exercised end to end
  # by the smoke test; guarded here at function level.
  _write_kits_to_file "$CLEAT_GLOBAL_CONFIG" sonnet sonnet
  run _write_kits_to_file "$CLEAT_GLOBAL_CONFIG" sonnet sonnet
  assert_success
}

@test "kit: help flag prints usage" {
  run cmd_kit --help
  assert_success
  assert_output --partial "cleat kit <name> [box]"
}

# ── Launch summary ───────────────────────────────────────────────────────────

@test "kit: launch summary shows the enabled kit" {
  resolve_caps "$TEST_TEMP/project" readonly
  _box_kit_write "$CNAME" "plan-big-execute-small"
  run _print_summary_block "$CNAME" "$TEST_TEMP/project"
  assert_output --partial "Kit:"
  assert_output --partial "plan-big-execute-small"
}

@test "kit: launch summary omits the Kit line when no kit is enabled" {
  resolve_caps "$TEST_TEMP/project" readonly
  run _print_summary_block "$CNAME" "$TEST_TEMP/project"
  refute_output --partial "Kit:"
}

@test "kit: a tampered selection file is printed as data, not interpreted" {
  # Selection files are hand-editable; backslash escapes must never be
  # expanded on output (echo -e would turn \n into a newline).
  resolve_caps "$TEST_TEMP/project" readonly
  mkdir -p "$CLEAT_KITS_DIR"
  printf '%s\n' 'bad\nkit' > "$CLEAT_KITS_DIR/$CNAME"
  run _print_summary_block "$CNAME" "$TEST_TEMP/project"
  assert_output --partial 'bad\nkit'
}

# ── Nuke ─────────────────────────────────────────────────────────────────────

@test "kit: nuke wipes the kit selections dir" {
  mock_docker_ps ""
  mock_docker_ps_a ""
  _box_kit_write "$CNAME" "plan-big-execute-small"
  run cmd_nuke <<< "nuke"
  [ ! -d "$CLEAT_KITS_DIR" ]
}
