#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Mutual exclusion with the mutation harness. See test/lib/testlock.sh.
_CLEAT_TEST_LOCK_ROOT="$SCRIPT_DIR"
. "$SCRIPT_DIR/test/lib/testlock.sh"
_take_test_lock "the test suite"
trap _drop_test_lock EXIT INT TERM

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
  # NOT `exec`: exec replaces the process image and discards the EXIT trap,
  # which leaked the lock on every `./test.sh <file>` run.
  "$BATS" "$@"
  exit $?
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

# Optional sharding for slow CI runners: TEST_SHARD_TOTAL=N + TEST_SHARD_INDEX=K
# runs only the files at positions where (pos % N == K), so CI can split the
# suite across N parallel runners. macOS runners are slow and highly variable, so
# one shard finishes under the job timeout where the whole suite would not. Unset
# (the default: local runs and the Linux CI legs) runs every file. Modulo-by-
# position interleaves the list so each shard draws a mix of large and small files.
_shard_note=""
if [[ -n "${TEST_SHARD_TOTAL:-}" ]]; then
  # REFUSE a nonsense shard spec instead of running a subset (or nothing) and
  # reporting success: a typo'd matrix would otherwise show a green job that
  # tested less than it claimed, which is worse than a red one.
  if [[ ! "${TEST_SHARD_TOTAL}" =~ ^[1-9][0-9]*$ ]]; then
    echo "TEST_SHARD_TOTAL must be a positive integer, got '${TEST_SHARD_TOTAL}'." >&2
    exit 1
  fi
  if [[ ! "${TEST_SHARD_INDEX:-0}" =~ ^[0-9]+$ ]] || [[ "${TEST_SHARD_INDEX:-0}" -ge "$TEST_SHARD_TOTAL" ]]; then
    echo "TEST_SHARD_INDEX must be an integer in 0..$((TEST_SHARD_TOTAL - 1)), got '${TEST_SHARD_INDEX:-0}'." >&2
    exit 1
  fi
  _shard_files=()
  _shard_i=0
  for _sf in "${files[@]}"; do
    if [[ $((_shard_i % TEST_SHARD_TOTAL)) -eq "${TEST_SHARD_INDEX:-0}" ]]; then
      _shard_files+=("$_sf")
    fi
    _shard_i=$((_shard_i + 1))
  done
  # ${#arr[@]} is safe under set -u even when empty; a bare "${arr[@]}" is not on
  # bash 3.2, so bail before the loop rather than expand an empty array. With a
  # validated spec this means more shards than files: still a misconfiguration,
  # so fail rather than report a green job that ran nothing.
  if [[ ${#_shard_files[@]} -eq 0 ]]; then
    echo "No test files for shard ${TEST_SHARD_INDEX:-0}/${TEST_SHARD_TOTAL}: more shards than test files." >&2
    exit 1
  fi
  files=("${_shard_files[@]}")
  _shard_note=" ${DIM}(shard ${TEST_SHARD_INDEX:-0}/${TEST_SHARD_TOTAL})${RESET}"
fi

echo ""
echo -e "${BOLD}${CYAN}  ┌─────────────────────────────────────────┐${RESET}"
echo -e "${BOLD}${CYAN}  │   Cleat CLI Test Suite                  │${RESET}"
echo -e "${BOLD}${CYAN}  └─────────────────────────────────────────┘${RESET}"
echo -e "  ${DIM}Running ${#files[@]} test files...${RESET}${_shard_note}"
echo ""

for f in "${files[@]}"; do
  fname="$(basename "$f" .bats)"
  total_files=$((total_files + 1))

  # Redirect bats stdin from /dev/null so an interactive `./test.sh` matches CI:
  # any test that reads fd0 (e.g. a shim that falls through to `cat`) gets EOF
  # instead of blocking forever on the developer's terminal.
  output=$("$BATS" "$f" </dev/null 2>&1)
  bats_rc=$?
  file_pass=$(echo "$output" | grep -c "^ok " || true)
  file_fail=$(echo "$output" | grep -c "^not ok " || true)
  file_skip=$(echo "$output" | grep -c "# skip" || true)

  # Trust bats' EXIT STATUS, not just the "not ok" lines. A file whose bats run
  # is killed (OOM, the job timeout, a crashed helper) can exit non-zero having
  # printed no "not ok" at all, which counted as a clean pass and let a shard go
  # green while testing nothing. Charge one synthetic failure so the file is
  # reported and the suite exits non-zero.
  if [[ "$bats_rc" -ne 0 && "$file_fail" -eq 0 ]]; then
    file_fail=1
    output="$output
not ok (harness) bats exited $bats_rc without reporting a failure: the run was killed or crashed"
  fi

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
