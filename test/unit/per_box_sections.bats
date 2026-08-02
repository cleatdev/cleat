#!/usr/bin/env bats
# ─────────────────────────────────────────────────────────────────────────────
# Per-box sections: [box.<name>.<kind>] inside the project .cleat.
#
# Replaces the old per-box FILES (.cleat.<box>), which are no longer read. One
# file per project instead of one per box, and, because a section write cannot
# replace a whole file, the strip-the-box class of editor bug is retired rather
# than patched.
#
# DECLARED replaces. ABSENT inherits. DECLARED-BUT-EMPTY is a real value.
# ─────────────────────────────────────────────────────────────────────────────
load "../setup"

setup() {
  _common_setup
  use_docker_stub
  source_cli
  CLEAT_CONFIG_DIR="$TEST_TEMP/cleat-config"
  CLEAT_GLOBAL_CONFIG="$CLEAT_CONFIG_DIR/config"
  CLEAT_GLOBAL_ENV="$CLEAT_CONFIG_DIR/env"
  CLEAT_TRUST_FILE="$CLEAT_CONFIG_DIR/trust"
  mkdir -p "$CLEAT_CONFIG_DIR"
  PROJECT="$TEST_TEMP/project"
  mkdir -p "$PROJECT"
  F="$PROJECT/.cleat"
}
teardown() { _common_teardown; }

# ── resolution ──────────────────────────────────────────────────────────────

@test "sections: an undeclared box inherits every project section" {
  printf '[caps]\ngit\nssh\n[setup]\nmake bootstrap\n[resources]\nmemory = 4g\n' > "$F"
  run _read_caps_from_file "$F" other
  assert_output --partial "git"
  assert_output --partial "ssh"
  run _read_setup_from_file "$F" other
  assert_output "make bootstrap"
  run _read_resource_from_file "$F" memory other
  assert_output "4g"
}

@test "sections: a declared caps section REPLACES, it never merges" {
  # Least privilege is the point: a box must be able to ask for FEWER caps.
  printf '[caps]\ngit\nssh\ndocker\n[box.review.caps]\ngit\n' > "$F"
  run _read_caps_from_file "$F" review
  assert_output "git"
  refute_output --partial "docker"
  refute_output --partial "ssh"
}

@test "sections: a declared but EMPTY caps section means zero caps, not inherit" {
  # The value the per-box files could not express: a bare header is a real
  # declaration. If this fell back, a lockdown box would silently run with the
  # project's full capability set.
  printf '[caps]\ngit\ndocker\n[box.locked.caps]\n' > "$F"
  run _read_caps_from_file "$F" locked
  assert_output ""
}

@test "sections: a declared but empty section still ends at the next header" {
  printf '[caps]\ngit\n[box.locked.caps]\n[box.other.caps]\ndocker\n' > "$F"
  run _read_caps_from_file "$F" locked
  assert_output ""
  run _read_caps_from_file "$F" other
  assert_output "docker"
}

@test "sections: setup is box-scoped and replaces wholesale" {
  printf '[setup]\nmake bootstrap\n[box.ci.setup]\nnpm ci\n' > "$F"
  run _read_setup_from_file "$F" ci
  assert_output "npm ci"
  refute_output --partial "bootstrap"
  run _read_setup_from_file "$F" main
  assert_output "make bootstrap"
}

@test "sections: resources resolve per KEY, so declaring memory keeps inherited cpus" {
  # caps/setup/fork are LIST sections and replace wholesale. resources is
  # key/value: declaring one key must not silently un-declare the other.
  printf '[resources]\nmemory = 4g\ncpus = 4\n[box.heavy.resources]\nmemory = 8g\n' > "$F"
  run _read_resource_from_file "$F" memory heavy
  assert_output "8g"
  run _read_resource_from_file "$F" cpus heavy
  assert_output "4"
}

@test "sections: fork excludes are box-scoped, and inherit when absent" {
  printf '[fork]\nexclude = node_modules\n[box.ci.fork]\nexclude = target\n' > "$F"
  run _read_section_all_from_file "$F" "$(_scoped_section "$F" ci fork)" exclude
  assert_output "target"
  run _read_section_all_from_file "$F" "$(_scoped_section "$F" other fork)" exclude
  assert_output "node_modules"
}

@test "sections: [box.main.<kind>] is honoured, not silently dead" {
  # Honouring main costs nothing and is what lets a .cleat be written so the
  # RESTRICTIVE section is the one an older Cleat reads.
  printf '[caps]\ngit\ndocker\n[box.main.caps]\ngit\n' > "$F"
  run _read_caps_from_file "$F" main
  assert_output "git"
}

@test "sections: a file with no box sections resolves byte-identically for every box" {
  printf '[caps]\ngit\nssh\n' > "$F"
  local a b
  a="$(_read_caps_from_file "$F" main)"
  b="$(_read_caps_from_file "$F" "")"
  [ "$a" = "$b" ]
  [ "$a" = "$(_read_caps_from_file "$F" anything)" ]
}

@test "sections: presence is a predicate, never an exit status through a substitution" {
  # `local x="$(f)"` reports local's status, not f's, so an rc-based
  # declared/absent contract reads "declared" every time. Six call sites in
  # bin/cleat already use that idiom.
  printf '[caps]\ngit\n[box.a.caps]\n' > "$F"
  run _cleat_section_present "$F" "box.a.caps"
  assert_success
  run _cleat_section_present "$F" "box.b.caps"
  assert_failure
}

@test "sections: CRLF and a BOM do not hide a box header" {
  printf '\xef\xbb\xbf[caps]\r\ngit\r\n[box.ci.caps]\r\ndocker\r\n' > "$F"
  run _read_caps_from_file "$F" ci
  assert_output "docker"
}

# ── trust ───────────────────────────────────────────────────────────────────

@test "sections: the caps hash is per box, and only the declaring box moves" {
  printf '[caps]\ngit\n[box.heavy.caps]\ngit\ndocker\n' > "$F"
  local main_before heavy_before
  main_before="$(_hash_cleat_caps "$F" main)"
  heavy_before="$(_hash_cleat_caps "$F" heavy)"
  [ "$main_before" != "$heavy_before" ]
  printf '[caps]\ngit\n[box.heavy.caps]\ngit\ndocker\nssh\n' > "$F"
  [ "$(_hash_cleat_caps "$F" main)" = "$main_before" ] \
    || { echo "main was re-prompted for an edit to another box"; return 1; }
  [ "$(_hash_cleat_caps "$F" heavy)" != "$heavy_before" ] \
    || { echo "heavy was NOT re-prompted for its own change"; return 1; }
}

@test "sections: two boxes inheriting the same caps hash identically" {
  printf '[caps]\ngit\n' > "$F"
  [ "$(_hash_cleat_caps "$F" a)" = "$(_hash_cleat_caps "$F" b)" ]
}

@test "sections: the caps hash refuses to guess a box" {
  # A defaulted box is how cmd_trust's loop silently hashed `main` while
  # iterating every box, showing a permanent false "changed since approval".
  run _hash_cleat_caps "$F"
  assert_failure
}

@test "sections: trust for one box does not imply trust for another" {
  printf '[caps]\ngit\n[box.heavy.caps]\ndocker\n' > "$F"
  _trust_record "$PROJECT" "$(_hash_cleat_caps "$F" main)" main ""
  _BOX=heavy
  run _is_project_trusted "$PROJECT"
  assert_failure
}

# ── the unknown-section warner ──────────────────────────────────────────────

@test "warner: a valid per-box section is accepted silently" {
  printf '[caps]\ngit\n[box.review.caps]\ngit\n[box.heavy.resources]\nmemory = 8g\n' > "$F"
  _WARNED_SECTIONS_FILES=""
  run _warn_unknown_cleat_sections "$F" project
  assert_success
  refute_output --partial "Unknown section"
}

@test "warner: a typo'd box name or kind still warns" {
  # A silently accepted typo is a box running the wrong configuration.
  printf '[box.Review.caps]\ngit\n' > "$F"
  _WARNED_SECTIONS_FILES=""
  run _warn_unknown_cleat_sections "$F" project
  assert_output --partial "Unknown section"

  printf '[box.review.capss]\ngit\n' > "$F"
  _WARNED_SECTIONS_FILES=""
  run _warn_unknown_cleat_sections "$F" project
  assert_output --partial "Unknown section"

  printf '[box.review]\ngit\n' > "$F"
  _WARNED_SECTIONS_FILES=""
  run _warn_unknown_cleat_sections "$F" project
  assert_output --partial "Unknown section"
}

@test "warner: per-box sections are refused in the GLOBAL config" {
  # Box names are per project, so a global [box.feat-a.*] would apply to every
  # project that happens to have a box called feat-a.
  printf '[box.review.caps]\ngit\n' > "$CLEAT_GLOBAL_CONFIG"
  _WARNED_SECTIONS_FILES=""
  run _warn_unknown_cleat_sections "$CLEAT_GLOBAL_CONFIG" global
  assert_output --partial "project-only"
}

# ── the retired per-box file ────────────────────────────────────────────────

@test "legacy: a .cleat.<box> file is no longer read" {
  printf '[caps]\ngit\n' > "$F"
  printf '[caps]\ndocker\n' > "$PROJECT/.cleat.old"
  run _read_caps_from_file "$(_project_caps_file "$PROJECT")" old
  assert_output "git"
  refute_output --partial "docker"
}

@test "legacy: a leftover .cleat.<box> is announced, never silent" {
  # It would otherwise change a box's capabilities in either direction with
  # nothing on screen.
  printf '[caps]\ngit\n' > "$F"
  printf '[caps]\ndocker\n' > "$PROJECT/.cleat.old"
  _WARNED_LEGACY_BOX_FILES=""
  run _warn_legacy_box_file "$PROJECT" old
  assert_output --partial "no longer read"
  assert_output --partial "box.old.caps"
}

@test "legacy: the warning fires once per file, not once per resolve" {
  printf '[caps]\ndocker\n' > "$PROJECT/.cleat.old"
  _WARNED_LEGACY_BOX_FILES=""
  _warn_legacy_box_file "$PROJECT" old >/dev/null
  run _warn_legacy_box_file "$PROJECT" old
  assert_output ""
}

@test "legacy: a box named env no longer collides with the project env file" {
  # .cleat.env is the project ENV file and used to double as box env's cap
  # file, so `cleat config env --memory 4g` appended [resources] next to
  # API_TOKEN=. Dropping the per-box file fallback retires that for free.
  printf 'API_TOKEN=secret123\n' > "$PROJECT/.cleat.env"
  printf '[caps]\ngit\n' > "$F"
  run _project_caps_file "$PROJECT"
  assert_output "$F"
  run cat "$PROJECT/.cleat.env"
  assert_output "API_TOKEN=secret123"
}

# ── the editor ──────────────────────────────────────────────────────────────

@test "editor: a box resource edit writes a section, never a new file" {
  cd "$PROJECT"
  printf '[caps]\ngit\nssh\n[setup]\nmake bootstrap\n' > "$F"
  run cmd_config dev --memory 4g
  assert_success
  [ ! -e "$PROJECT/.cleat.dev" ] || { echo "a per-box file was created"; return 1; }
  run _read_resource_from_file "$F" memory dev
  assert_output "4g"
  # and nothing was stripped, which is the whole reason for sections
  run _read_caps_from_file "$F" dev
  assert_output --partial "git"
  run _read_setup_from_file "$F" dev
  assert_output --partial "make bootstrap"
}

@test "editor: enabling a cap on an inheriting box MATERIALIZES the inherited set" {
  # Otherwise --enable gh would leave the box with ONLY gh, which is exactly
  # how the old per-box file silently stripped a box.
  cd "$PROJECT"
  printf '[caps]\ngit\nssh\n' > "$F"
  run cmd_config dev --enable gh
  assert_success
  run _read_caps_from_file "$F" dev
  assert_output --partial "git"
  assert_output --partial "ssh"
  assert_output --partial "gh"
}

@test "editor: an edit back to the inherited set restores inheritance" {
  # Without delete-on-equal a no-op edit silently pins the box to today's
  # project caps forever, with no verb to undo it.
  cd "$PROJECT"
  printf '[caps]\ngit\nssh\n' > "$F"
  cmd_config dev --enable gh >/dev/null
  run grep -c 'box.dev.caps' "$F"
  assert_output "1"
  run cmd_config dev --disable gh
  assert_success
  run grep -c 'box.dev.caps' "$F"
  assert_output "0"
  # and the box is inheriting again, so a later project change reaches it
  printf '[caps]\ngit\nssh\ndocker\n' > "$F"
  run _read_caps_from_file "$F" dev
  assert_output --partial "docker"
}

@test "editor: emptying a declared box section keeps the header, never removes it" {
  # An omitted section means absent means INHERIT, so writing an empty set by
  # omission would escalate a locked-down box to the project's full cap set.
  cd "$PROJECT"
  printf '[caps]\ngit\nssh\n[box.locked.caps]\ndocker\n' > "$F"
  run cmd_config locked --disable docker
  assert_success
  run _cleat_section_present "$F" "box.locked.caps"
  assert_success
  run _read_caps_from_file "$F" locked
  assert_output ""
}

@test "editor: a box edit leaves every other box's section untouched" {
  cd "$PROJECT"
  printf '[caps]\ngit\n[box.a.caps]\ndocker\n[box.b.resources]\nmemory = 8g\n' > "$F"
  run cmd_config c --memory 2g
  assert_success
  run _read_caps_from_file "$F" a
  assert_output "docker"
  run _read_resource_from_file "$F" memory b
  assert_output "8g"
}

@test "editor: --list reports the box's effective config, not the project's" {
  cd "$PROJECT"
  printf '[caps]\ngit\n[box.dev.caps]\ndocker\n[box.dev.resources]\nmemory = 8g\n' > "$F"
  run cmd_config dev --list
  assert_success
  assert_output --partial "8g"
}

@test "editor: enabling on a box that ALREADY declares caps adds to ITS set, not the project's" {
  # The scoped-read half of materialize. An inheriting box's effective set IS
  # the project set, so that case cannot tell a scoped read from a bare one.
  # A box with its own section can: --enable must extend docker, not git+ssh.
  cd "$PROJECT"
  printf '[caps]\ngit\nssh\n[box.dev.caps]\ndocker\n' > "$F"
  run cmd_config dev --enable gh
  assert_success
  run _read_caps_from_file "$F" dev
  assert_output --partial "docker"
  assert_output --partial "gh"
  refute_output --partial "git"
  refute_output --partial "ssh"
}

# ── the interactive picker writes where the readers read ────────────────────

@test "editor: the interactive picker scopes a box's save, it does not write project-wide" {
  # The direct --enable/--disable path scoped correctly while the PICKER wrote
  # into the bare [caps], so a box edit made through the TUI granted the
  # capability to EVERY box. Two independent review passes caught it.
  cd "$PROJECT"
  printf '[caps]\ngit\n' > "$F"
  _config_editor_save "$F" project "$PROJECT" "git,docker" "" "" 0 0 "" dev >/dev/null
  run _read_caps_from_file "$F" dev
  assert_output --partial "docker"
  # the project, and therefore every other box, is untouched
  run _read_caps_from_file "$F" ""
  refute_output --partial "docker"
  run _read_caps_from_file "$F" someotherbox
  refute_output --partial "docker"
}

@test "editor: the picker scopes resources too" {
  cd "$PROJECT"
  printf '[resources]\nmemory = 2g\n' > "$F"
  _config_editor_save "$F" project "$PROJECT" "" "8g" "" 0 0 "" dev >/dev/null
  run _read_resource_from_file "$F" memory dev
  assert_output "8g"
  run _read_resource_from_file "$F" memory ""
  assert_output "2g"
}

@test "editor: a main-box edit writes where main actually reads" {
  # `cleat config main` wrote [caps] while the readers honoured an existing
  # [box.main.caps], so the edit was a silent no-op AND granted project-wide.
  cd "$PROJECT"
  printf '[caps]\ngit\ndocker\n[box.main.caps]\ngit\n' > "$F"
  run cmd_config main --enable gh
  assert_success
  run _read_caps_from_file "$F" main
  assert_output --partial "gh"
  assert_output --partial "git"
  refute_output --partial "docker"
}

@test "editor: a declared-empty lockdown survives an edit that lands on empty" {
  # delete-on-equal must not fire on an EMPTY set: a bare header is an explicit
  # lockdown, and dropping it lets the box inherit whatever the project gains.
  cd "$PROJECT"
  printf '[caps]\n[box.locked.caps]\ndocker\n' > "$F"
  run cmd_config locked --disable docker
  assert_success
  run _cleat_section_present "$F" "box.locked.caps"
  assert_success
  printf '[caps]\ngit\nssh\n[box.locked.caps]\n' > "$F"
  run _read_caps_from_file "$F" locked
  assert_output ""
}

@test "legacy: the env sidecar is never mistaken for a per-box caps file" {
  # The warning told the user to move .cleat.env, their SECRETS file, into the
  # committed .cleat as [box.env.caps].
  printf 'API_TOKEN=secret\n' > "$PROJECT/.cleat.env"
  _WARNED_LEGACY_BOX_FILES=""
  run _warn_legacy_box_file "$PROJECT" env
  assert_success
  assert_output ""
}

@test "legacy: a leftover per-box file is announced on a session verb, not only in config" {
  # Warning only from cmd_config meant `cleat start <box>` ran the box with the
  # project defaults while a .cleat.<box> sat there declaring something else.
  printf '[caps]\ngit\n' > "$F"
  printf '[caps]\ndocker\n' > "$PROJECT/.cleat.old"
  _WARNED_LEGACY_BOX_FILES=""
  _BOX="old"
  run resolve_caps "$PROJECT"
  assert_output --partial "no longer read"
}

@test "editor: a no-op edit of the PROJECT config never deletes [caps]" {
  # delete-on-equal is only meaningful for a per-box section. For the bare
  # [caps] the "inherited" set IS the set being written, so it fired on every
  # no-op project edit and wiped the section: a silent, total capability wipe.
  cd "$PROJECT"
  printf '[caps]\ngit\nssh\n' > "$F"
  _config_editor_save "$F" project "$PROJECT" "git,ssh" "" "" 0 0 "" "" >/dev/null
  run _read_caps_from_file "$F" ""
  assert_output --partial "git"
  assert_output --partial "ssh"
}

@test "editor: a no-op edit of box main never deletes the project [caps]" {
  cd "$PROJECT"
  printf '[caps]\ngit\nssh\n' > "$F"
  _config_editor_save "$F" project "$PROJECT" "git,ssh" "" "" 0 0 "" main >/dev/null
  run _read_caps_from_file "$F" main
  assert_output --partial "git"
  assert_output --partial "ssh"
}

@test "editor: the picker loads a box's OWN declared resources, not the project's" {
  # It writes back whatever it loaded, so loading the project's number would
  # freeze it into the box's section or clear the box's own ceiling.
  printf '[resources]\nmemory = 2g\n[box.heavy.resources]\nmemory = 8g\n' > "$F"
  run _config_load_resource "$F" memory default "" heavy
  assert_output --partial "8g"
  run _config_load_resource "$F" memory default "" ""
  assert_output --partial "2g"
}

# ── the three review leftovers ──────────────────────────────────────────────

@test "trust: the prompt names the box and the section it resolved" {
  # With per-box config in ONE file the box name is the only thing separating
  # two different consent decisions, so "Project .cleat" alone is ambiguous.
  printf '[caps]\ngit\n[box.ci.caps]\ndocker\n' > "$F"
  run _trust_subject "$PROJECT" ci caps
  assert_output "$(printf '.cleat [box.ci.caps]')"
  run _trust_subject "$PROJECT" other caps
  assert_output --partial "box other"
  run _trust_subject "$PROJECT" main caps
  assert_output ".cleat [caps]"
}

@test "trust: the caps prompt shows the resolved subject, not a bare .cleat" {
  printf '[caps]\ngit\n[box.ci.caps]\ndocker\n' > "$F"
  _BOX=ci
  _is_tty() { return 0; }
  _read_keypress() { printf 'n'; }
  _ask_yn() { printf -v "$1" '%s' 'n'; }
  run _trust_prompt "$PROJECT" docker
  assert_output --partial "box.ci.caps"
}

@test "editor: editing the project default warns when main declares its own" {
  # Otherwise the edit reports success and changes nothing for main.
  cd "$PROJECT"
  printf '[caps]\ngit\n[box.main.caps]\ngit\n' > "$F"
  run _config_write_caps_scoped "$F" caps "" git ssh
  assert_success
  assert_output --partial "unaffected"
}

@test "editor: no such warning when main inherits normally" {
  cd "$PROJECT"
  printf '[caps]\ngit\n' > "$F"
  run _config_write_caps_scoped "$F" caps "" git ssh
  assert_success
  refute_output --partial "unaffected"
}

@test "sections: the first box section adds a compatibility note to the file" {
  # .cleat is committed and shared. An older Cleat cannot see [box.*] sections
  # and falls back to [caps], so a per-box REDUCTION fails OPEN on a teammate's
  # older CLI. Worth saying in the file, not only in the docs.
  cd "$PROJECT"
  printf '[caps]\ngit\n' > "$F"
  cmd_config dev --enable docker >/dev/null
  run head -2 "$F"
  assert_output --partial "cleat >="
  assert_output --partial "Older versions ignore them"
}

@test "sections: the compatibility note is written once, not on every edit" {
  cd "$PROJECT"
  printf '[caps]\ngit\n' > "$F"
  cmd_config dev --enable docker >/dev/null
  cmd_config dev --enable gh >/dev/null
  cmd_config other --memory 4g >/dev/null
  run grep -c '^# cleat >= ' "$F"
  assert_output "1"
}

@test "sections: a file with no box sections gets no note" {
  cd "$PROJECT"
  printf '[caps]\ngit\n' > "$F"
  cmd_config --project --enable ssh >/dev/null 2>&1 || true
  run grep -c '^# cleat >= ' "$F"
  assert_output "0"
}

@test "sections: the note is a comment, so it never changes what is resolved" {
  cd "$PROJECT"
  printf '[caps]\ngit\n' > "$F"
  cmd_config dev --enable docker >/dev/null
  run _read_caps_from_file "$F" ""
  assert_output "git"
  run _read_caps_from_file "$F" dev
  assert_output --partial "docker"
}

@test "sections: an ambient _WRITE_SECTION cannot redirect a project write" {
  # The scoped-writer channels are function parameters carried in globals. Read
  # straight from the inherited environment, a stray value in the user's shell
  # would silently send a project edit into some other section.
  cd "$PROJECT"
  printf '[caps]\ngit\n' > "$F"
  run env _WRITE_SECTION="box.evil.caps" _WRITE_EMPTY_SECTION=1 \
      "$PROJECT_ROOT/bin/cleat" config --project --enable ssh
  assert_success
  run _cleat_section_present "$F" "box.evil.caps"
  assert_failure
  run _read_caps_from_file "$F" ""
  assert_output --partial "ssh"
}

@test "editor: --list marks each box value as declared or inherited" {
  # A box view that shows only values cannot be told apart from the project's
  # own, and the difference decides whether a later project edit reaches it.
  cd "$PROJECT"
  printf '[caps]\ngit\n[resources]\nmemory = 2g\ncpus = 2\n[box.heavy.caps]\ndocker\n[box.heavy.resources]\nmemory = 8g\n' > "$F"
  run cmd_config heavy --list
  assert_success
  assert_output --partial "8g"
  assert_output --partial "declared"
  assert_output --partial "inherited"
  assert_output --partial "box heavy"
}

@test "editor: --list on an inheriting box says so for capabilities" {
  cd "$PROJECT"
  printf '[caps]\ngit\n' > "$F"
  run cmd_config other --list
  assert_success
  assert_output --partial "inherited from the project"
}

@test "editor: the project --list is unchanged, with no box annotations" {
  cd "$PROJECT"
  printf '[caps]\ngit\n[resources]\nmemory = 2g\n' > "$F"
  run cmd_config --project --list
  assert_success
  refute_output --partial "declared"
  refute_output --partial "box "
}

@test "editor: a no-op picker save on main never deletes the project [resources]" {
  # _config_load_resource read "box.main.resources" unconditionally. That
  # section does not exist, so the picker showed "default" and saving wrote an
  # empty section, DELETING the project's [resources]. The load must use the
  # same section the writer targets.
  cd "$PROJECT"
  printf '[caps]\ngit\n[resources]\nmemory = 2g\ncpus = 3\n' > "$F"
  run _config_load_resource "$F" memory default "" main
  assert_output --partial "2g"
  _config_editor_save "$F" project "$PROJECT" "git" "2g" "3" 0 0 "" main >/dev/null
  run _read_resource_from_file "$F" memory main
  assert_output "2g"
  run _read_resource_from_file "$F" cpus main
  assert_output "3"
}

@test "editor: a no-op picker save with no box also keeps [resources]" {
  cd "$PROJECT"
  printf '[resources]\nmemory = 2g\ncpus = 3\n' > "$F"
  run _config_load_resource "$F" cpus all "" ""
  assert_output --partial "3"
  _config_editor_save "$F" project "$PROJECT" "" "2g" "3" 0 0 "" "" >/dev/null
  run _read_resource_from_file "$F" cpus ""
  assert_output "3"
}

@test "editor: a real box still loads only what it declares" {
  # Deliberate: the picker writes back what it displays, so an inheriting box
  # must not materialize the project's value just by being opened.
  cd "$PROJECT"
  printf '[resources]\nmemory = 2g\n[box.heavy.resources]\nmemory = 8g\n' > "$F"
  run _config_load_resource "$F" memory default "" heavy
  assert_output --partial "8g"
  run _config_load_resource "$F" memory default "" other
  assert_output --partial "default"
}

@test "help: the config line no longer names the retired per-box file" {
  run cmd_help
  assert_success
  refute_output --partial ".cleat.<box>"
}
