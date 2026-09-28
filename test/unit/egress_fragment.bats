#!/usr/bin/env bats
# ── Egress: what the agent is told (EGRESS-SPEC.md 9.4) ─────────────────────
#
# The '# Network access' block a caged box's CLAUDE.md carries in place of the
# shipped "full network access" sentence. Every claim in it is checkable from
# inside the box, the host list is the resolution's own, and a box with no
# policy, or one that predates its policy, keeps the shipped text byte for
# byte.
load "../setup"
load "../lib/egress_fixtures"
setup() {
  _common_setup
  use_docker_stub
  source_cli
  mock_egress_caged_launch
  mkdir -p "$TEST_TEMP/project"
  cd "$TEST_TEMP/project"
  CN="$(container_name_for "$TEST_TEMP/project" main)"
  egress_box_names
  unset CLEAT_BROWSER_BRIDGE
}
teardown() { _common_teardown; }

# The policy, as the global config's [egress] section.
policy() { printf '[egress]\n%b' "$1" > "$CLEAT_GLOBAL_CONFIG"; }

# The host block of a strict fragment: the lines after "on port 443:" and its
# blank line, up to the next blank line.
fragment_hosts() {
  printf '%s\n' "$1" | awk '/on port 443:$/ { f = 1; next } f == 1 && /^$/ { if (seen) exit; next } f == 1 { seen = 1; print }'
}

# The words of the fragment on one line, so a sentence reads whole across the
# payload's line breaks and their indentation.
joined() { printf '%s' "$1" | tr '\n' ' ' | tr -s ' '; }

@test "egress fragment: the network fragment never claims there is no interface" {
  policy 'mode = strict\n'
  run _provisioning_notes_claude_md "$CN"
  assert_success
  assert_line "# Network access"
  assert_line "This box was created with --network none. It has a loopback interface and an"
  refute_output --partial "no network interface"
  # The check it offers the agent needs no package: the image has no ip.
  assert_output --partial 'Check it yourself: `cat /proc/net/route` prints only its header'
  refute_output --partial "ip route"
  refute_output --partial "full network access"
  refute_output --partial "There is no egress allowlist"
}

@test "egress fragment: the fragment host list is generated from the resolved policy" {
  policy 'mode = strict\npack = github\nallow = git.acme.internal\n'
  run _provisioning_notes_claude_md "$CN"
  assert_success
  local listed want
  listed="$(fragment_hosts "$output" | tr -s ' ' '\n' | grep -v '^$' | LC_ALL=C sort)"
  _egress_resolve "$CN"
  want="$(printf '%s\n' "$_EG_HOSTS" | LC_ALL=C sort)"
  assert_equal "$listed" "$want"
  run printf '%s\n' "$listed"
  assert_line "git.acme.internal"
  assert_line "uploads.github.com"
  assert_line "api.anthropic.com"
  refute_line "registry.npmjs.org"
}

@test "egress fragment: a sub-tick that is off never appears in the fragment host list" {
  policy 'mode = strict\npack = gitlab\n'
  run _provisioning_notes_claude_md "$CN"
  assert_success
  run fragment_hosts "$output"
  assert_output --partial "gitlab.com"
  refute_output --partial "registry.gitlab.com"
  policy 'mode = strict\npack = gitlab\nallow = registry.gitlab.com\n'
  run _provisioning_notes_claude_md "$CN"
  run fragment_hosts "$output"
  assert_output --partial "registry.gitlab.com"
}

@test "egress fragment: the open mode fragment still names the proxy and the log" {
  policy 'mode = open\n'
  run _provisioning_notes_claude_md "$CN"
  assert_success
  assert_line "# Network access"
  assert_line "This box was created with --network none. It has a loopback interface and an"
  assert_output --partial "relayed to 127.0.0.1:3128."
  assert_output --partial "/run/cleat-egress/denials.log"
  assert_output --partial "There is no host allowlist in this session."
  assert_output --partial "every destination is recorded."
  # Open is a destination log, so nothing in it describes a list or a boundary.
  refute_output --partial "Only"
  refute_output --partial "A connection to anything else fails"
  refute_output --partial "If you need a host that is not listed"
  refute_output --partial "listed above"
  refute_output --partial "cleat egress allow"
  refute_output --partial "api.anthropic.com"
}

@test "egress fragment: the fragment tells the agent a cleat egress 403 is not an auth failure" {
  local mode
  for mode in strict open; do
    policy "mode = $mode\n"
    run _provisioning_notes_claude_md "$CN"
    assert_success
    run joined "$output"
    assert_output --partial 'A 403 whose body says "cleat egress" is a policy decision, not an authentication problem, so do not re-authenticate and do not switch accounts.'
  done
}

@test "egress fragment: strict names every workaround it forbids and the command to ask for" {
  policy 'mode = strict\n'
  run _provisioning_notes_claude_md "$CN"
  run joined "$output"
  assert_output --partial "1. Stop. Do not retry. Do not look for a mirror or an alternate CDN. Do not disable TLS verification. Do not try a different port."
  assert_output --partial "3. Give them this command: cleat egress allow <host>"
  assert_output --partial "So is any host, listed above or not, whose name resolves to a private, loopback or link-local address."
}

@test "egress fragment: no policy, an off policy and enforcement off keep the shipped text byte for byte" {
  local base
  rm -f "$CLEAT_GLOBAL_CONFIG"
  base="$(_provisioning_notes_claude_md "$CN")"
  run printf '%s\n' "$base"
  refute_output --partial "# Network access"
  # The shipped close, byte for byte, after the line it has always followed.
  run bash -c 'printf "%s\n" "$1" | tail -n 3' _ "$base"
  assert_output 'Never suggest forking Cleat, editing its Dockerfile, or `cleat rebuild` to add
tools; `[setup]` is the supported path. There is no egress allowlist: the box has
full network access.'
  policy 'mode = off\n'
  run _provisioning_notes_claude_md "$CN"
  assert_equal "$output" "$base"
  policy ''
  run _provisioning_notes_claude_md "$CN"
  assert_equal "$output" "$base"
  policy 'mode = strict\n'
  _EGRESS_ENFORCING=0
  run _provisioning_notes_claude_md "$CN"
  assert_equal "$output" "$base"
  _EGRESS_ENFORCING=1
  # No box name: the image-baked notes, never a guess at a box's policy.
  run _provisioning_notes_claude_md
  assert_equal "$output" "$base"
}

@test "egress fragment: a box that predates its policy is not told it is caged" {
  policy 'mode = strict\n'
  container_exists() { return 0; }
  F_HASH="" caged_box
  run _provisioning_notes_claude_md "$CN"
  assert_success
  refute_output --partial "# Network access"
  assert_output --partial "full network access."
  # The same box once it carries the label.
  rm -rf "$DOCKER_MOCK_DIR/inspect"
  caged_box
  run _provisioning_notes_claude_md "$CN"
  assert_output --partial "# Network access"
}

@test "egress fragment: a policy that does not resolve leaves the shipped text and never exits" {
  # Hosts with no mode: the resolver exits, and only the gate may refuse.
  printf '[egress]\nallow = a.example\n' > "$CLEAT_GLOBAL_CONFIG"
  run _provisioning_notes_claude_md "$CN"
  assert_success
  refute_output --partial "# Network access"
  assert_output --partial "full network access."
  refute_output --partial "lists hosts but no mode"
}

@test "egress fragment: the browser paragraph says what the bridge really does" {
  policy 'mode = strict\n'
  run _provisioning_notes_claude_md "$CN"
  run joined "$output"
  assert_output --partial 'a small fixed set of origins, and that is not covered by the list above. `cleat browser origins` on the host shows the set.'
  CLEAT_BROWSER_BRIDGE=always
  run _provisioning_notes_claude_md "$CN"
  run joined "$output"
  assert_output --partial "open any URL this box writes (CLEAT_BROWSER_BRIDGE=always on the host)"
  refute_output --partial "small fixed set"
  CLEAT_BROWSER_BRIDGE=off
  run _provisioning_notes_claude_md "$CN"
  assert_line "Nothing this box writes opens in your host's browser."
  refute_output --partial "small fixed set"
  unset CLEAT_BROWSER_BRIDGE
  policy 'mode = open\n'
  run _provisioning_notes_claude_md "$CN"
  run joined "$output"
  assert_output --partial "origins, and that does not go through this proxy."
}

@test "egress fragment: the host list wraps at 78 columns with two-space gaps" {
  local long
  # 91 columns in labels a resolver accepts: no label passes 63.
  long="$(printf 'l%019d.' 1 2 3 4)example"
  policy "mode = strict\npack = github\nallow = $long\n"
  run _provisioning_notes_claude_md "$CN"
  local block
  block="$(fragment_hosts "$output")"
  run awk -v L="$long" 'length($0) > 78 && $0 != "  " L { print "wide: " $0 }' <<< "$block"
  assert_output ""
  run grep -vc '^  [^ ]' <<< "$block"
  assert_output "0"
  run printf '%s\n' "$block"
  assert_line "  $long"
  assert_line --partial "  api.anthropic.com  api.github.com  claude.ai"
  # More than one line: 78 is a width, not a single line.
  run awk 'END { print (NR >= 3) ? "several" : NR }' <<< "$block"
  assert_output "several"
}

@test "egress fragment: the kit overlay carries the fragment for a caged box" {
  policy 'mode = strict\n'
  _generate_kit_overlay "$CN"
  run cat "$CLEAT_RUN_DIR/$CN/kit/CLAUDE.md"
  assert_output --partial "# ── Cleat box provisioning ──"
  assert_output --partial "# Network access"
  refute_output --partial "full network access"
}

@test "egress fragment: a reload that lands rewrites the overlay, and a matching digest leaves it" {
  policy 'mode = strict\n'
  caged_box
  container_exists() { return 0; }
  _container_has_kit_mounts() { return 0; }
  _generate_kit_overlay() { echo "regen $1" >> "$TEST_TEMP/regen"; }
  # The digest the gateway answers already matches: nothing to rewrite.
  _egress_resolve "$CN"
  run _egress_live_ok "$CN" "$_EG_MODE" "$_EG_HOSTS"
  assert_success
  [ ! -f "$TEST_TEMP/regen" ]
  # A stale digest, then the reload's answer.
  mock_gw_admin policy-digest "ok policy-digest v1:0000000000000000" "ok policy-digest $(current_digest)"
  run _egress_live_ok "$CN" "$_EG_MODE" "$_EG_HOSTS"
  assert_success
  run cat "$TEST_TEMP/regen"
  assert_output "regen $CN"
  # A reload the gateway does not take refuses, and rewrites nothing.
  rm -f "$TEST_TEMP/regen"
  mock_gw_admin policy-digest "ok policy-digest v1:0000000000000000"
  run _egress_live_ok "$CN" "$_EG_MODE" "$_EG_HOSTS"
  assert_failure
  [ ! -f "$TEST_TEMP/regen" ]
}

@test "egress fragment: the refresh skips a box with no overlay mounts and never fails" {
  _generate_kit_overlay() { echo "regen $1" >> "$TEST_TEMP/regen"; return 1; }
  container_exists() { return 0; }
  _container_has_kit_mounts() { return 1; }
  run _egress_fragment_refresh "$CN"
  assert_success
  [ ! -f "$TEST_TEMP/regen" ]
  container_exists() { return 1; }
  _container_has_kit_mounts() { return 0; }
  run _egress_fragment_refresh "$CN"
  assert_success
  [ ! -f "$TEST_TEMP/regen" ]
  container_exists() { return 0; }
  run _egress_fragment_refresh "$CN"
  assert_success
  run cat "$TEST_TEMP/regen"
  assert_output "regen $CN"
}

@test "egress fragment: cleat claude rewrites the overlay after its gate under a policy" {
  policy 'mode = strict\n'
  _fork_preflight() { :; }
  require_running() { :; }
  resolve_caps() { :; }
  resolve_env_args() { :; }
  _resolve_config_drift() { :; }
  container_exists() { return 0; }
  _egress_require() { echo gate >> "$TEST_TEMP/order"; _EG_CAGED=1; return 0; }
  _egress_fragment_refresh() { echo "refresh $1" >> "$TEST_TEMP/order"; }
  # The next step after the refresh ends the run: the rest is other tests'.
  _maybe_note_missing_kit_masks() { exit 7; }
  run cmd_claude "$TEST_TEMP/project"
  assert_equal "$status" 7
  run cat "$TEST_TEMP/order"
  assert_output "gate
refresh $CN"
  # No policy: the gate passes uncaged and the verb rewrites nothing it did
  # not before.
  : > "$TEST_TEMP/order"
  _egress_require() { echo gate >> "$TEST_TEMP/order"; _EG_CAGED=0; return 0; }
  run cmd_claude "$TEST_TEMP/project"
  run cat "$TEST_TEMP/order"
  assert_output "gate"
}

@test "egress fragment: the setup prompt names the network the policy gives" {
  policy 'mode = strict\n'
  run _setup_trust_prompt "$TEST_TEMP/project" "echo hi" 1 <<< "n"
  assert_output --partial "in the box as coder (network limited to this box's egress policy)"
  refute_output --partial "full network access"
  policy 'mode = open\n'
  run _setup_trust_prompt "$TEST_TEMP/project" "echo hi" 1 <<< "n"
  assert_output --partial "in the box as coder (any TLS host, through the egress proxy)"
  rm -f "$CLEAT_GLOBAL_CONFIG"
  run _setup_trust_prompt "$TEST_TEMP/project" "echo hi" 1 <<< "n"
  assert_output --partial "in the box as coder (full network access)"
  policy 'mode = strict\n'
  _EGRESS_ENFORCING=0
  run _setup_trust_prompt "$TEST_TEMP/project" "echo hi" 1 <<< "n"
  assert_output --partial "in the box as coder (full network access)"
}

@test "egress fragment: the setup prompt promises the policy's network only where the box will be caged" {
  policy 'mode = strict\n'
  # A validated engine and nothing that refuses: the policy's network.
  run _setup_trust_prompt "$TEST_TEMP/project" "echo hi" 1 <<< "n"
  assert_output --partial "(network limited to this box's egress policy)"
  # An engine that refuses every caged create: the create would refuse, so
  # after cleat egress off the approved payload runs with full network.
  _egress_engine_kind() { printf engine-linux; }
  run _setup_trust_prompt "$TEST_TEMP/project" "echo hi" 1 <<< "n"
  assert_output --partial "(full network access)"
  # A capability the interlock refuses: the same.
  _egress_engine_kind() { printf desktop-macos; }
  _egress_interlocks() { return 1; }
  run _setup_trust_prompt "$TEST_TEMP/project" "echo hi" 1 <<< "n"
  assert_output --partial "(full network access)"
}
