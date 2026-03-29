#!/usr/bin/env bash
# Mutation testing for v0.3.0 capabilities
# For each critical behavior: mutate the source, run the guarding test, confirm FAILURE.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BATS="$PROJECT_ROOT/test/bats/bin/bats"
CLI="$PROJECT_ROOT/bin/cleat"
CLI_BACKUP="$PROJECT_ROOT/bin/cleat.backup"

BOLD='\033[1m'
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RESET='\033[0m'

pass=0
fail=0
total=0

# Save original
cp "$CLI" "$CLI_BACKUP"

restore() {
  cp "$CLI_BACKUP" "$CLI"
}

# Run a single mutation: apply sed, run a specific test, expect failure
mutate() {
  local description="$1"
  local sed_expr="$2"
  local test_file="$3"
  local test_name="$4"

  total=$((total + 1))
  restore

  # Apply the mutation
  sed -i "$sed_expr" "$CLI"

  # Run the specific test, expecting it to FAIL
  local output
  output=$("$BATS" --filter "^${test_name}$" "$test_file" 2>&1)
  local rc=$?

  if [[ $rc -ne 0 ]]; then
    echo -e "  ${GREEN}✔${RESET} CAUGHT: $description"
    pass=$((pass + 1))
  else
    echo -e "  ${RED}✗${RESET} MISSED: $description"
    echo "    Test passed despite mutation — test is ineffective!"
    echo "    Mutation: $sed_expr"
    fail=$((fail + 1))
  fi

  restore
}

echo ""
echo -e "${BOLD}Mutation Testing — v0.3.0 Capabilities${RESET}"
echo ""

# ── Mutation 1: Remove :ro from SSH mount (security-critical)
mutate \
  "ssh cap: remove :ro from .ssh mount" \
  's|\.ssh:/home/coder/\.ssh:ro|.ssh:/home/coder/.ssh|' \
  "$PROJECT_ROOT/test/unit/capabilities.bats" \
  "ssh cap: mounts ~/.ssh read-only when enabled"

# ── Mutation 2: Remove :ro from gitconfig mount (security-critical)
mutate \
  "git cap: remove :ro from .gitconfig mount" \
  's|\.gitconfig:/home/coder/\.gitconfig:ro|.gitconfig:/home/coder/.gitconfig|' \
  "$PROJECT_ROOT/test/unit/capabilities.bats" \
  "git cap: mounts ~/.gitconfig read-only when enabled"

# ── Mutation 3: Break git cap gate for gitconfig mount
mutate \
  "git cap: break cap_is_active gate for gitconfig" \
  '0,/cap_is_active git/s/cap_is_active git/cap_is_active xxx/' \
  "$PROJECT_ROOT/test/unit/capabilities.bats" \
  "git cap: mounts ~/.gitconfig read-only when enabled"

# ── Mutation 3b: Break ssh cap gate for ssh mount
mutate \
  "ssh cap: break cap_is_active gate for ssh keys" \
  '0,/cap_is_active ssh/s/cap_is_active ssh/cap_is_active xxx/' \
  "$PROJECT_ROOT/test/unit/capabilities.bats" \
  "ssh cap: mounts ~/.ssh read-only when enabled"

# ── Mutation 4: Remove env file reading in resolve_env_args
mutate \
  "env cap: skip global env file" \
  '/CLEAT_GLOBAL_ENV.*then/,/fi/{s/env_map\[/# env_map[/}' \
  "$PROJECT_ROOT/test/unit/capabilities.bats" \
  "env cap: passes env vars from global env file to docker run"

# ── Mutation 5: Break env cap gate — always read env files
mutate \
  "env cap: remove capability gate (always load env files)" \
  's/cap_is_active env 2>\/dev\/null/true/' \
  "$PROJECT_ROOT/test/unit/capabilities.bats" \
  "no env cap: ignores env files even when present"

# ── Mutation 6: Break --env bypass (require env cap for --env flag)
mutate \
  "--env flag: break capability bypass" \
  's/# 3\. --env flags (always work, bypass capability gate)/if cap_is_active env 2>\/dev\/null; then/' \
  "$PROJECT_ROOT/test/unit/capabilities.bats" \
  "--env flag: passes KEY=VALUE without env cap"

# ── Mutation 7: Remove version label from docker build
mutate \
  "build: remove version label" \
  's/--label "sh.cleat.version=\$VERSION" //' \
  "$PROJECT_ROOT/test/unit/capabilities.bats" \
  "build: stores version label on image"

# ── Mutation 8: Remove config-hash label from docker run
mutate \
  "run: remove config-hash label" \
  's/--label "sh.cleat.config-hash=\$config_hash"//' \
  "$PROJECT_ROOT/test/unit/capabilities.bats" \
  "run: stores config-hash label on container"

# ── Mutation 9: Break SSH agent forwarding path
mutate \
  "ssh cap: break SSH agent socket path" \
  's|/tmp/ssh-agent.sock|/tmp/wrong.sock|g' \
  "$PROJECT_ROOT/test/unit/capabilities.bats" \
  "ssh cap: SSH agent forwarding when SSH_AUTH_SOCK is a socket"

# ── Mutation 9b: Weaken SSH_AUTH_SOCK validation (-S → -n accepts non-sockets)
mutate \
  "ssh cap: weaken SSH_AUTH_SOCK check from -S to -n" \
  's/\[\[ -S "${SSH_AUTH_SOCK:-}"/[[ -n "${SSH_AUTH_SOCK:-}"/' \
  "$PROJECT_ROOT/test/unit/capabilities.bats" \
  "ssh cap: no SSH forwarding when SSH_AUTH_SOCK is not a socket"

# ── Mutation 9c: Break bare env key validation
mutate \
  "env: remove bare key name validation" \
  '/\^.a-zA-Z_/d' \
  "$PROJECT_ROOT/test/unit/capabilities.bats" \
  "parse_env_file: skips bare KEY with invalid variable name"

# ── Mutation 9d: Remove CRLF stripping from all parsers
mutate \
  "config: remove CR stripping from parsers" \
  '/line=.\{1,\}line%/d' \
  "$PROJECT_ROOT/test/unit/config.bats" \
  "read_caps: handles CRLF line endings"

# ── Mutation 9e: Remove empty key validation from env parser
mutate \
  "env: remove empty key validation" \
  '/KEY=VALUE.*validate key/,+2d' \
  "$PROJECT_ROOT/test/unit/capabilities.bats" \
  "parse_env_file: skips empty key \\(=VALUE line\\)"

# ── Mutation 9f: Remove container name truncation
mutate \
  "container_name: remove length truncation" \
  '/dir_name="\${dir_name:0:48}"/d' \
  "$PROJECT_ROOT/test/unit/container_name.bats" \
  "container name never exceeds Docker.s 63-char limit"

# ── Mutation 10: Change [caps] section header to [capabilities]
mutate \
  "config: break [caps] section header" \
  's/\[caps\]/[capabilities]/' \
  "$PROJECT_ROOT/test/unit/config.bats" \
  "read_caps: reads caps from \\[caps\\] section"

# ── Mutation 11: Break --cap validation — accept anything
mutate \
  "--cap flag: remove validation" \
  '/_cap_valid=false/,/exit 1/{s/exit 1/: # noop/}' \
  "$PROJECT_ROOT/test/unit/argument_parsing.bats" \
  "parse_global_flags: --cap rejects unknown capability"

# ── Mutation 12: Break _write_caps_to_file — don't write [caps] header
mutate \
  "write_caps: omit [caps] section header" \
  's/echo "\[caps\]"/# omitted/' \
  "$PROJECT_ROOT/test/unit/config.bats" \
  "write_caps: creates file with \\[caps\\] section"

# ── Mutation 13: Break --enable — don't actually add to array
mutate \
  "config --enable: don't add cap to list" \
  's/current_caps+=("$cap_name")/# skip adding/' \
  "$PROJECT_ROOT/test/unit/config.bats" \
  "config --enable: enables a capability"

# ── Mutation 14: Break --disable — don't filter out cap
mutate \
  "config --disable: don't remove cap from list" \
  's/\[\[ "\$cap" != "\$cap_name" \]\] && new_caps+=("\$cap")/new_caps+=("\$cap")/' \
  "$PROJECT_ROOT/test/unit/config.bats" \
  "config --disable: removes a capability"

# ── Mutation 15: Break version string
mutate \
  "version: wrong version number" \
  's/^VERSION="0.3.0"/VERSION="9.9.9"/' \
  "$PROJECT_ROOT/test/unit/version.bats" \
  "version: prints current version"

# ── Summary
echo ""
echo -e "  ─────────────────────────────────────────"
if [[ $fail -eq 0 ]]; then
  echo -e "  ${GREEN}${BOLD}All mutations caught${RESET}"
else
  echo -e "  ${RED}${BOLD}${fail} mutation(s) survived!${RESET}"
fi
echo -e "  ${BOLD}${total}${RESET} mutations  ${GREEN}${pass} caught${RESET}  ${RED}${fail} survived${RESET}"
echo ""

# Cleanup
rm -f "$CLI_BACKUP"

[[ $fail -eq 0 ]]
