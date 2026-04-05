#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BATS="$SCRIPT_DIR/test/bats/bin/bats"

# Ensure bats submodules are initialized
if [[ ! -f "$BATS" ]]; then
  echo "Bats not found. Initializing submodules..."
  git -C "$SCRIPT_DIR" submodule update --init --recursive
  if [[ ! -f "$BATS" ]]; then
    echo "Error: Failed to initialize test dependencies." >&2
    echo "Run: git submodule update --init --recursive" >&2
    exit 1
  fi
fi

# If specific files are passed, run them directly
if [[ $# -gt 0 ]]; then
  exec "$BATS" "$@"
fi

# ── Colors ──────────────────────────────────────────────────────────────────
BOLD='\033[1m'
DIM='\033[2m'
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
RESET='\033[0m'

# ── Run each file in isolation ──────────────────────────────────────────────
total_pass=0
total_fail=0
total_skip=0
total_files=0
failed_files=()
start_time=$(date +%s)

files=("$SCRIPT_DIR"/test/unit/*.bats)

echo ""
echo -e "${BOLD}${CYAN}  ┌─────────────────────────────────────────┐${RESET}"
echo -e "${BOLD}${CYAN}  │   Cleat CLI Test Suite                  │${RESET}"
echo -e "${BOLD}${CYAN}  └─────────────────────────────────────────┘${RESET}"
echo -e "  ${DIM}Running ${#files[@]} test files...${RESET}"
echo ""

for f in "${files[@]}"; do
  fname="$(basename "$f" .bats)"
  total_files=$((total_files + 1))

  output=$("$BATS" "$f" 2>&1)
  file_pass=$(echo "$output" | grep -c "^ok " || true)
  file_fail=$(echo "$output" | grep -c "^not ok " || true)
  file_skip=$(echo "$output" | grep -c "# skip" || true)

  total_pass=$((total_pass + file_pass))
  total_fail=$((total_fail + file_fail))
  total_skip=$((total_skip + file_skip))

  if [[ "$file_fail" -gt 0 ]]; then
    echo -e "  ${RED}✖${RESET} ${fname}  ${DIM}(${file_pass} passed, ${RED}${file_fail} failed${RESET}${DIM})${RESET}"
    failed_files+=("$fname")
    # Show failure details indented
    echo "$output" | grep -A5 "^not ok" | sed 's/^/      /'
  else
    local_info=""
    if [[ "$file_skip" -gt 0 ]]; then
      local_info="  ${DIM}(${file_skip} skipped)${RESET}"
    fi
    echo -e "  ${GREEN}✔${RESET} ${fname}  ${DIM}(${file_pass} passed)${RESET}${local_info}"
  fi
done

# ── Summary ─────────────────────────────────────────────────────────────────
end_time=$(date +%s)
elapsed=$((end_time - start_time))
total=$((total_pass + total_fail))

echo ""
echo -e "  ${DIM}─────────────────────────────────────────${RESET}"

if [[ "$total_fail" -eq 0 ]]; then
  echo -e "  ${GREEN}${BOLD}All tests passed${RESET}"
else
  echo -e "  ${RED}${BOLD}${total_fail} test(s) failed${RESET}"
fi

summary="  ${BOLD}${total}${RESET} total"
summary+="  ${GREEN}${total_pass} passed${RESET}"
if [[ "$total_fail" -gt 0 ]]; then
  summary+="  ${RED}${total_fail} failed${RESET}"
fi
if [[ "$total_skip" -gt 0 ]]; then
  summary+="  ${YELLOW}${total_skip} skipped${RESET}"
fi
summary+="  ${DIM}(${elapsed}s)${RESET}"
echo -e "$summary"

if [[ "${#failed_files[@]}" -gt 0 ]]; then
  echo ""
  echo -e "  ${RED}Failed suites:${RESET}"
  for ff in "${failed_files[@]}"; do
    echo -e "    ${DIM}•${RESET} $ff"
  done
fi

echo ""

[[ "$total_fail" -eq 0 ]]
