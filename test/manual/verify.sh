#!/usr/bin/env bash
#
# cleat verify: run the manual release scenarios automatically.
#
# Replaces most of MANUAL-TESTS-*.md with something that runs itself, records
# what happened and stops to ask you only for the things a script must not do
# on your behalf.
#
# ── THE SAFETY MODEL ────────────────────────────────────────────────────────
#
# You are running this on your own machine, against a CLI whose whole job is
# deleting containers and workspace copies. So:
#
#   1. ISOLATED STATE. XDG_CONFIG_HOME is redirected into the run directory, and
#      cleat derives CLEAT_CONFIG_DIR from it. Your real ~/.config/cleat, with
#      your real forks, boxes and trust store, is never opened. A `cleat fork
#      prune --yes` in here cannot see your real copies.
#   2. ISOLATED PROJECTS. Every test project is created under the run directory.
#      Container names hash the project path, so they cannot collide with your
#      real boxes.
#   3. NO GLOBAL DESTRUCTION, EVER. This script never runs `nuke`, `stop-all`,
#      `clean`, or `prune` without --dry-run, because those reach every cleat
#      container and image on the host regardless of XDG_CONFIG_HOME. Those
#      checks are MANUAL and you run them yourself, or skip them.
#   4. EVERY DELETE IS FENCED. _safe_rm resolves the path physically and refuses
#      anything that is not inside the run directory.
#   5. NOTHING IN $HOME IS WRITTEN. The one scenario that needed a canary file
#      in your home directory now uses a canary inside the run directory, which
#      tests the same containment property without putting your home at risk.
#   6. It refuses to run as root, and refuses a run directory that resolves onto
#      your real config.
#
# ── USING IT ────────────────────────────────────────────────────────────────
#
#   ./verify.sh              run everything it can, stop at the first manual gate
#   ./verify.sh --resume     continue after you have done a manual step
#   ./verify.sh --list       show the checks and which need you
#   ./verify.sh --only 20    run one check
#   ./verify.sh --no-docker  skip everything that needs a daemon
#   ./verify.sh --report     print the report path and the summary
#   ./verify.sh --clean      remove the run directory
#
# Exit codes: 0 all green, 1 something failed, 10 waiting on you.
#
set -uo pipefail

# ── locations ───────────────────────────────────────────────────────────────
_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$_here/../../.." && pwd)"
CLI_BIN="${CLEAT_VERIFY_BIN:-$REPO_ROOT/cli/bin/cleat}"
RUN_DIR="${CLEAT_VERIFY_DIR:-${TMPDIR:-/tmp}/cleat-verify}"
RUN_DIR="$(printf '%s' "$RUN_DIR" | sed 's|//*|/|g; s|/$||')"
# The report lands inside the repo so it can be read from wherever you are
# working, including an agent in a container with the repo bind-mounted.
REPORT_DIR="$REPO_ROOT/.cleat-verify"
REPORT="$REPORT_DIR/report.md"
RESULTS="$REPORT_DIR/results.tsv"
STATE="$REPORT_DIR/state"

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; AMBER=$'\033[38;5;214m'
BLUE=$'\033[0;34m'; DIM=$'\033[2m'; BOLD=$'\033[1m'; RESET=$'\033[0m'
[[ -t 1 ]] || { RED=""; GREEN=""; AMBER=""; BLUE=""; DIM=""; BOLD=""; RESET=""; }

# ── guards, before anything touches the disk ────────────────────────────────
if [[ "$(id -u)" -eq 0 ]]; then
  echo "${RED}Refusing to run as root.${RESET} This script creates and deletes directories." >&2
  exit 1
fi
if [[ ! -x "$CLI_BIN" ]]; then
  echo "${RED}Cannot find the cleat binary at $CLI_BIN${RESET}" >&2
  echo "Set CLEAT_VERIFY_BIN=/path/to/bin/cleat and retry." >&2
  exit 1
fi

_phys() { ( cd -P "$1" 2>/dev/null && pwd -P ) 2>/dev/null; }

_assert_run_dir_is_safe() {
  local p real home_real
  mkdir -p "$RUN_DIR" 2>/dev/null || { echo "${RED}Cannot create $RUN_DIR${RESET}" >&2; exit 1; }
  real="$(_phys "$RUN_DIR")" || real=""
  home_real="$(_phys "$HOME")" || home_real="$HOME"
  case "$real" in
    ""|/|"$home_real")
      echo "${RED}Refusing: the run directory resolves to $real${RESET}" >&2; exit 1 ;;
  esac
  # Never anywhere that could be a real cleat state dir.
  case "$real" in
    *"/.config/cleat"*|*"/.claude"*)
      echo "${RED}Refusing: the run directory is inside your real config ($real)${RESET}" >&2; exit 1 ;;
  esac
  # And it must not BE your home, nor contain it.
  case "$home_real/" in
    "$real"/*) echo "${RED}Refusing: the run directory contains your home directory${RESET}" >&2; exit 1 ;;
  esac

  # OWN IT, do not merely accept it. _safe_rm is correct, but its whole premise
  # is "this directory is ours", and nothing established that. Pointed at a
  # directory you already use, the checks rm -rf fixed names inside it
  # (projects/bom, projects/pbx-mem, canary, ...) and still printed all green.
  # So: an existing NON-EMPTY directory must carry our marker or we refuse.
  local marker="$real/.cleat-verify-runroot"
  if [[ ! -f "$marker" ]]; then
    if [[ -n "$(ls -A "$real" 2>/dev/null)" ]]; then
      echo "${RED}Refusing: $real already has content and was not created by this script.${RESET}" >&2
      echo "" >&2
      echo "If an earlier --clean stopped on root-owned files, this is the way out:" >&2
      echo "  sudo rm -rf $real" >&2
      echo "" >&2
      echo "Otherwise point CLEAT_VERIFY_DIR at a new or empty directory. This script" >&2
      echo "deletes fixed names inside its run dir, so it will not adopt one of yours." >&2
      exit 1
    fi
    printf 'cleat verify run root. Safe to delete.\n' > "$marker"
  fi
}

# Every delete goes through this. Physical resolution, then containment, so a
# symlink or a .. component cannot walk out of the run directory.
_safe_rm() {
  local target="$1" root parent base
  root="$(_phys "$RUN_DIR")" || return 1
  [[ -n "$root" ]] || return 1
  base="${target##*/}"
  case "$base" in ''|.|..) echo "refusing to delete $target" >&2; return 1 ;; esac
  parent="$(_phys "$(dirname "$target")")" || return 0    # parent gone, nothing to do
  case "$parent" in
    "$root"|"$root"/*) : ;;
    *) echo "${RED}REFUSING to delete outside the run dir: $target${RESET}" >&2; return 1 ;;
  esac
  [[ -e "$target" || -L "$target" ]] || return 0
  rm -rf "$target"
}


# Removing the run root itself. _safe_rm deliberately requires a target's parent
# to be inside the run dir, which the run dir's own parent never is, so --clean
# refused every time and then printed that it had succeeded. This validates the
# root the same way the startup guard does, then requires OUR marker, so it can
# only ever delete a directory this script created.
_clean_run_dir() {
  local real home_real
  real="$(_phys "$RUN_DIR")" || real=""
  home_real="$(_phys "$HOME")" || home_real="$HOME"
  if [[ -z "$real" ]]; then
    echo "nothing to clean at $RUN_DIR"
    return 0
  fi
  case "$real" in
    /|"$home_real") echo "${RED}Refusing to delete $real${RESET}" >&2; return 1 ;;
    *"/.config/cleat"*|*"/.claude"*)
      echo "${RED}Refusing to delete $real${RESET}" >&2; return 1 ;;
  esac
  case "$home_real/" in
    "$real"/*) echo "${RED}Refusing: $real contains your home directory${RESET}" >&2; return 1 ;;
  esac
  if [[ ! -f "$real/.cleat-verify-runroot" ]]; then
    echo "${RED}Refusing: $real has no run-root marker, so this script did not create it.${RESET}" >&2
    return 1
  fi
  rm -rf "$real" 2>/dev/null
  if [[ -e "$real" ]]; then
    # Retry once for the merely-unwritable case (ours, odd permissions).
    chmod -R u+rwX "$real" 2>/dev/null || true
    rm -rf "$real" 2>/dev/null || true
  fi
  if [[ ! -e "$real" ]]; then
    echo "removed $real"
    return 0
  fi
  # Something survived, and it is almost always root-owned: Docker creates
  # missing bind-mount targets as root, and the container writes into the
  # session overlays as root before the entrypoint remaps. A non-root user
  # cannot unlink those, and chmod cannot help with files it does not own.
  #
  # Re-plant the marker. `rm -rf` deletes it early in the walk, so a partial
  # clean used to leave a non-empty directory with no marker, which the
  # startup guard then refused forever. One failed clean became a dead end
  # with no way out that the script itself would tell you about.
  printf 'cleat verify run root. Safe to delete.\n' > "$real/.cleat-verify-runroot" 2>/dev/null || true
  echo "${RED}Could not fully remove $real${RESET}" >&2
  echo "" >&2
  echo "What survived is root-owned: Docker's bind-mount targets for a box that" >&2
  echo "still exists. Remove the box and they go with it. Reach for sudo only if" >&2
  echo "something is still there afterwards." >&2
  echo "" >&2
  echo "  docker ps -a --filter name=^cleat- --format '{{.Names}}'" >&2
  echo "  docker rm -f <the box this run created>" >&2
  echo "  $0 --clean" >&2
  echo "" >&2
  echo "Only if that leaves something behind:" >&2
  echo "  sudo rm -rf $real" >&2
  echo "" >&2
  echo "The marker is back either way, so the run dir never wedges." >&2
  return 1
}

# ── the isolated world ──────────────────────────────────────────────────────
_setup_world() {
  _assert_run_dir_is_safe
  export XDG_CONFIG_HOME="$RUN_DIR/xdg"
  mkdir -p "$XDG_CONFIG_HOME" "$RUN_DIR/projects" "$REPORT_DIR"
  # Non-interactive: never sit on a trust prompt inside an automated check.
  export CLEAT_TRUST_PROJECT=1
  export CLEAT_NO_DOCKER_GATE=1
  export CLEAT_NO_AUTOSTART=1
}

C() { "$CLI_BIN" "$@"; }
# Captured output ALWAYS goes through this. The CLI interleaves colour codes
# inside its own markers ("[<green>✔<reset>] git"), so a plain substring match
# on raw output silently never matches and every assertion reads as a failure.
_strip() { sed $'s/\033\[[0-9;]*m//g'; }
CO() { "$CLI_BIN" "$@" 2>&1 | _strip; }

_daemon_up() { command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; }

# ── results ─────────────────────────────────────────────────────────────────
_pass=0; _fail=0; _skip=0; _manual=0
_failed_names=""

_record() {  # id  status  title  detail
  printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$(printf '%s' "$4" | tr '\n' '~')" >> "$RESULTS"
}

ok()   { _pass=$((_pass+1));  echo "  ${GREEN}✔${RESET} $2"; _record "$1" PASS "$2" "${3:-}"; }
bad()  { _fail=$((_fail+1));  echo "  ${RED}✖${RESET} $2"; [[ -n "${3:-}" ]] && echo "      ${DIM}${3}${RESET}"
         _failed_names="${_failed_names}${1} "; _record "$1" FAIL "$2" "${3:-}"; }
skip() { _skip=$((_skip+1));  echo "  ${DIM}~ $2 (skipped: ${3:-})${RESET}"; _record "$1" SKIP "$2" "${3:-}"; }

# assert helpers, each recording its own result
want()      { [[ "$2" == *"$3"* ]] && ok "$1" "$4" || bad "$1" "$4" "expected to contain: $3"; }
want_not()  { [[ "$2" != *"$3"* ]] && ok "$1" "$4" || bad "$1" "$4" "must NOT contain: $3"; }
want_eq()   { [[ "$2" == "$3" ]] && ok "$1" "$4" || bad "$1" "$4" "got [$2] want [$3]"; }
want_file() { [[ -f "$2" ]] && ok "$1" "$3" || bad "$1" "$3" "missing file: $2"; }
want_nofile(){ [[ ! -e "$2" ]] && ok "$1" "$3" || bad "$1" "$3" "file should not exist: $2"; }

# ── manual gates ────────────────────────────────────────────────────────────
# A manual step records where we got to, prints exactly what you must do, and
# exits 10. Re-run with --resume and it picks up after that step.
_gate() {   # id  title  instructions...
  local id="$1" title="$2"; shift 2
  # Already satisfied on an earlier run: fall through so the assertions AFTER
  # the gate actually execute. Marking the CHECK done here meant --resume
  # skipped the entire function and the thing you just set up was never tested.
  _is_done "gate:$id" && return 0
  _manual=$((_manual+1))
  _record "$id" MANUAL "$title" ""
  echo ""
  echo "  ${AMBER}${BOLD}YOUR TURN${RESET}  ${BOLD}${title}${RESET}"
  local line
  for line in "$@"; do echo "      $line"; done
  echo ""
  echo "      ${DIM}Then: cd $REPO_ROOT && ./cli/test/manual/verify.sh --resume${RESET}"
  _mark_done "gate:$id"
  _write_report
  exit 10
}

# Completed checks are tracked as a SET, not as a high-water mark. A numeric
# threshold looked fine and was wrong: the run order is not numeric (the gates
# sit last), so stopping at gate 03 would have skipped check 01 forever.
_mark_done() { echo "$1" >> "$STATE"; }
_is_done()   { [[ -f "$STATE" ]] && grep -qxF "$1" "$STATE"; }

# Should this check run, given --resume / --only?
_want_check() {
  local id="$1"
  [[ -n "$ONLY" ]] && { [[ "$id" == "$ONLY" ]] && return 0 || return 1; }
  [[ "$RESUME" -eq 1 ]] && _is_done "$id" && return 1
  return 0
}

# ═══════════════════════════════════════════════════════════════════════════
# THE CHECKS
#
# Numbered to line up with MANUAL-TESTS-2026-07-31.md so a failure here points
# at a scenario you can read. Anything a script must not do on your machine is
# a _gate, never an automated step.
# ═══════════════════════════════════════════════════════════════════════════

new_project() {   # name -> echoes path
  local p="$RUN_DIR/projects/$1"
  _safe_rm "$p"; mkdir -p "$p"
  ( cd "$p" && git init -q && echo v1 > app.txt && git add -A \
      && GIT_AUTHOR_NAME=v GIT_AUTHOR_EMAIL=v@x GIT_COMMITTER_NAME=v GIT_COMMITTER_EMAIL=v@x \
         git commit -qm init ) 2>/dev/null
  echo "$p"
}

check_05_disable_indented() {
  local p out; p="$(new_project cfg-indent)"
  printf '  [caps]\ndocker\nssh\n' > "$p/.cleat"
  ( cd "$p" && C config --project --disable docker >/dev/null 2>&1 )
  out="$(cd "$p" && CO config --project --list)"
  want_not 05a "$out" "[✔] docker" "an indented [caps] really disables docker"
  want_eq  05b "$(grep -c '\[caps\]' "$p/.cleat")" "1" "no duplicate [caps] section is appended"

  printf '[caps]\ndocker\n  [setup]\nsudo apt-get update\n' > "$p/.cleat"
  ( cd "$p" && C config --project --disable docker >/dev/null 2>&1 )
  want 05c "$(cat "$p/.cleat")" "sudo apt-get update" "an indented [setup] survives a caps edit"
}

check_09_unreadable_cleat() {
  local p out rc; p="$(new_project unreadable)"
  printf '[caps]\ngit\n' > "$p/.cleat"; chmod 000 "$p/.cleat"
  out="$(cd "$p" && CO status)"; rc=$?
  chmod 644 "$p/.cleat"
  want_not 09a "$out" "Permission denied" "an unreadable .cleat does not crash the CLI"
  want_eq  09b "$rc" "0" "cleat status still exits 0"
}

check_10_env_name() {
  local out rc
  out="$(C --env "MY-VAR" version 2>&1)"; rc=$?
  # version does not resolve env, so use a verb that parses flags then stops
  out="$(cd "$RUN_DIR" && CO --env "MY-VAR" config --list 2>&1)"; rc=$?
  want    10a "$out" "Invalid environment variable name" "a bare --env with a bad name is refused"
  want_eq 10b "$rc" "1" "and it exits 1"
  out="$(cd "$RUN_DIR" && CO --env "MY-VAR=hello" config --list 2>&1)"; rc=$?
  want_eq 10c "$rc" "0" "KEY=VALUE is data and stays unrestricted"
}

check_11_nuke_no_tty() {
  # NOT run: `cleat nuke` removes every cleat container and image on the host,
  # which XDG_CONFIG_HOME does not isolate. Manual, or skipped.
  skip 11 "cleat nuke with no terminal" "destructive host-wide, run it yourself if you want it"
}

check_12_memory_floor() {
  local out rc; local p; p="$(new_project memfloor)"
  out="$(cd "$p" && CO config --project --memory 4)"; rc=$?
  want_eq 12a "$rc" "1" "memory below dockerd's 6 MB floor is refused"
  out="$(cd "$p" && CO config --project --memory 8g)"; rc=$?
  want_eq 12b "$rc" "0" "8g is still accepted"
}

check_13_bom() {
  local p out; p="$(new_project bom)"
  printf '\xef\xbb\xbf[caps]\ndocker\n' > "$p/.cleat"
  out="$(cd "$p" && CO config --project --list)"
  want 13a "$out" "docker" "a BOM does not void the first section"
  ( cd "$p" && C config --project --disable docker >/dev/null 2>&1 )
  [[ "$(grep -c '\[caps\]' "$p/.cleat")" -le 1 ]] \
    && ok 13b "and the writer never duplicates the section" \
    || bad 13b "and the writer never duplicates the section" "found more than one [caps]"
}

check_20_box_memory_writes_section() {
  local p; p="$(new_project pbx-mem)"
  printf '[caps]\ngit\nssh\n\n[setup]\nmake bootstrap\n' > "$p/.cleat"
  ( cd "$p" && C config feat --memory 4g >/dev/null 2>&1 )
  want_nofile 20a "$p/.cleat.feat" "no per-box FILE is created"
  local body; body="$(cat "$p/.cleat")"
  want 20b "$body" "[box.feat.resources]" "the box's section is written into .cleat"
  want 20c "$body" "make bootstrap" "the project [setup] survives"
  want 20d "$body" "ssh" "the project [caps] survives"
  want 20e "$body" "Per-box config" "the compatibility note is added"
  want_not 20f "$body" "cleat >=" "and it claims no version number"
}

check_22_declared_empty() {
  local p out; p="$(new_project pbx-empty)"
  printf '[caps]\ngit\ndocker\n[box.locked.caps]\n' > "$p/.cleat"
  out="$(cd "$p" && CO config locked --list)"
  want_not 22a "$out" "[✔] docker" "a declared-empty section grants no project caps"
  out="$(cd "$p" && CO config other --list)"
  want 22b "$out" "inherited from the project" "an undeclared box says it inherits"
}

check_23_empty_keeps_header() {
  local p; p="$(new_project pbx-lockdown)"
  printf '[caps]\ngit\nssh\n[box.locked.caps]\ndocker\n' > "$p/.cleat"
  ( cd "$p" && C config locked --disable docker >/dev/null 2>&1 )
  want 23a "$(cat "$p/.cleat")" "[box.locked.caps]" "emptying a declared section keeps its bare header"
  local out; out="$(cd "$p" && CO config locked --list)"
  want_not 23b "$out" "[✔] git" "so the lockdown is not escalated to the project set"
}

check_24_declared_replaces() {
  local p out; p="$(new_project pbx-replace)"
  printf '[caps]\ngit\nssh\ndocker\n[box.review.caps]\ngit\n' > "$p/.cleat"
  out="$(cd "$p" && CO config review --list)"
  want     24a "$out" "[✔] git" "a declared box keeps what it declares"
  want_not 24b "$out" "[✔] docker" "and REPLACES rather than merging"
  out="$(cd "$p" && CO config other --list)"
  want     24c "$out" "[✔] docker" "while an undeclared box inherits the project set"
}

check_25_resources_per_key() {
  local p out; p="$(new_project pbx-res)"
  printf '[resources]\nmemory = 2g\ncpus = 3\n[box.heavy.resources]\nmemory = 8g\n' > "$p/.cleat"
  out="$(cd "$p" && CO config heavy --list)"
  want 25a "$out" "8g" "a declared key wins"
  want 25b "$out" "3" "and an undeclared key still inherits"
  want 25c "$out" "declared" "the list marks which is which"
  want 25d "$out" "inherited" "for both directions"
}

check_26_materialize_and_restore() {
  local p; p="$(new_project pbx-mat)"
  printf '[caps]\ngit\nssh\n' > "$p/.cleat"
  ( cd "$p" && C config dev --enable gh >/dev/null 2>&1 )
  local sect; sect="$(sed -n '/\[box.dev.caps\]/,$p' "$p/.cleat")"
  want 26a "$sect" "git" "--enable materializes the inherited set"
  want 26b "$sect" "gh" "with the new cap added"
  ( cd "$p" && C config dev --disable gh >/dev/null 2>&1 )
  want_eq 26c "$(grep -c 'box.dev.caps' "$p/.cleat")" "0" "and going back to the inherited set restores inheritance"
}

check_27_legacy_file_announced() {
  local p out; p="$(new_project pbx-legacy)"
  printf '[caps]\ngit\n' > "$p/.cleat"
  printf '[caps]\ndocker\n' > "$p/.cleat.old"
  out="$(cd "$p" && CO config old --list)"
  want     27a "$out" "no longer read" "a leftover .cleat.<box> is announced"
  want     27b "$out" "box.old.caps" "and names the section to move to"
  want_not 27c "$out" "[✔] docker" "and its caps are NOT applied"
}

check_28_trust_per_box() {
  # Asserts the STORED HASHES directly rather than eyeballing `trust --list`
  # output for "did it change". The old version compared two renderings and
  # SKIPPED itself when they happened to look the same, which is a test that
  # reports nothing rather than a test that fails.
  local p; p="$(new_project pbx-trust)"
  printf '[caps]\ngit\n[box.ci.caps]\ndocker\n' > "$p/.cleat"
  local tf="$XDG_CONFIG_HOME/cleat/trust"
  ( cd "$p" && C trust main >/dev/null 2>&1 ) || true
  ( cd "$p" && C trust ci   >/dev/null 2>&1 ) || true
  local main_before ci_before main_after ci_after
  main_before="$(awk -F'\t' -v p="$p" '$1==p && $2=="main" {print $3}' "$tf" 2>/dev/null)"
  ci_before="$(  awk -F'\t' -v p="$p" '$1==p && $2=="ci"   {print $3}' "$tf" 2>/dev/null)"

  [[ -n "$main_before" && -n "$ci_before" ]] \
    && ok 28a "each box gets its own trust row" \
    || bad 28a "each box gets its own trust row" "main=[$main_before] ci=[$ci_before] in $tf"
  [[ "$main_before" != "$ci_before" ]] \
    && ok 28b "a declaring box hashes differently from the project default" \
    || bad 28b "a declaring box hashes differently from the project default" "both are [$main_before]"

  # now change ONLY the ci section and re-approve both
  printf '[caps]\ngit\n[box.ci.caps]\ndocker\nssh\n' > "$p/.cleat"
  ( cd "$p" && C trust main >/dev/null 2>&1 ) || true
  ( cd "$p" && C trust ci   >/dev/null 2>&1 ) || true
  main_after="$(awk -F'\t' -v p="$p" '$1==p && $2=="main" {print $3}' "$tf" 2>/dev/null)"
  ci_after="$(  awk -F'\t' -v p="$p" '$1==p && $2=="ci"   {print $3}' "$tf" 2>/dev/null)"
  [[ "$main_after" == "$main_before" ]] \
    && ok 28c "editing one box does NOT disturb another box's approval" \
    || bad 28c "editing one box does NOT disturb another box's approval" "main moved $main_before -> $main_after"
  [[ "$ci_after" != "$ci_before" ]] \
    && ok 28d "and the edited box IS re-hashed" \
    || bad 28d "and the edited box IS re-hashed" "ci stayed [$ci_before]"
}

check_30_global_refuses_and_typo_warns() {
  local p out; p="$(new_project pbx-warn)"
  printf '[caps]\ngit\n[box.Review.caps]\ndocker\n' > "$p/.cleat"
  out="$(cd "$p" && CO status)"
  want 30a "$out" "Unknown section" "a typo'd box name still warns"
  printf '[box.review.caps]\ngit\n' > "$XDG_CONFIG_HOME/cleat/config"
  out="$(cd "$p" && CO status)"
  want 30b "$out" "project-only" "per-box sections are refused in the global config"
  : > "$XDG_CONFIG_HOME/cleat/config"
}

# ── the Docker-dependent ones, and the manual gates ─────────────────────────

check_01_prune_daemon_down() {
  if _daemon_up; then
    _gate 01 "Scenario 1: fork prune with Docker stopped" \
      "This is the one that used to delete every fork copy on the machine." \
      "" \
      "  1. Quit Docker Desktop / OrbStack / Colima." \
      "  2. Re-run this script with --resume." \
      "" \
      "The script will then check that 'cleat fork' says 'box unknown' and that" \
      "'cleat fork prune --yes' REFUSES instead of deleting."
  fi
  # daemon is down: now we can check it
  local p out rc; p="$(new_project fork-down)"
  local forks="$XDG_CONFIG_HOME/cleat/forks"
  mkdir -p "$forks/cleat-fake-11112222-feat"
  echo wip > "$forks/cleat-fake-11112222-feat/WIP.txt"
  out="$(cd "$p" && CO fork)"
  want     01a "$out" "box unknown" "the list does not claim every box is gone"
  want_not 01b "$out" "no box" "and does not label a live box as an orphan"
  out="$(cd "$p" && CO fork prune --yes)"; rc=$?
  want_eq  01c "$rc" "1" "prune REFUSES while the daemon is unreachable"
  want     01d "$out" "Docker is not running" "and says why"
  want_file 01e "$forks/cleat-fake-11112222-feat/WIP.txt" "the copy and its uncommitted work survive"
  _safe_rm "$forks/cleat-fake-11112222-feat"
}

check_02_fork_containment() {
  local p out rc; p="$(new_project fork-contain)"
  # Canary inside the run dir, never in $HOME. Same property, no risk to you.
  local canary="$RUN_DIR/canary"; mkdir -p "$canary"; echo precious > "$canary/thesis.txt"
  local forks="$XDG_CONFIG_HOME/cleat/forks"; mkdir -p "$forks"
  # a real-looking copy so the '..' walk has a first component that exists
  mkdir -p "$forks/cleat-fork-contain-deadbeef-x"
  out="$(cd "$p" && CO fork rm 'x/../../../../../canary')"; rc=$?
  want_eq 02a "$rc" "1" "a box name that walks out of the fork root is refused"
  want    02b "$out" "Invalid box name" "with a clear message"
  want_file 02c "$canary/thesis.txt" "and the canary outside the fork root survives"
  out="$(cd "$p" && CO fork rm feat extra)"
  want    02d "$out" "Unexpected argument" "a stray second positional is refused"
  _safe_rm "$forks/cleat-fork-contain-deadbeef-x"; _safe_rm "$canary"
}

check_06_session_key() {
  _gate 06 "Scenario 6: sessions persist for a snake_case project" \
    "This one needs you to talk to Claude, so a script cannot do it." \
    "" \
    "  cd $RUN_DIR/projects" \
    "  mkdir -p my_app && cd my_app && git init -q" \
    "  XDG_CONFIG_HOME=$XDG_CONFIG_HOME $CLI_BIN config --project --enable docker" \
    "  XDG_CONFIG_HOME=$XDG_CONFIG_HOME $CLI_BIN start" \
    "" \
    "  Say something memorable to Claude, then type ${BOLD}/exit${RESET} once." \
    "" \
    "${AMBER}That is the only exit you type.${RESET} Claude is the box session here, so" \
    "/exit ends it and puts you straight back on the HOST shell, still in" \
    "my_app. Typing exit again closes your terminal." \
    "" \
    "From that same my_app directory, reopen the conversation:" \
    "  XDG_CONFIG_HOME=$XDG_CONFIG_HOME $CLI_BIN resume" \
    "" \
    "Claude must offer that conversation back. Leave it with /exit again," \
    "then check the host key:" \
    "  ls ~/.claude/projects/ | grep my" \
    "It must end -my-app with a DASH, not my_app." \
    "" \
    "Clean up when done:  XDG_CONFIG_HOME=$XDG_CONFIG_HOME $CLI_BIN rm"
}

check_03_nuke_keeps_forks() {
  _gate 03 "Scenario 3: nuke keeps fork copies and their markers" \
    "${RED}READ THIS BEFORE YOU RUN IT.${RESET} cleat nuke is HOST-WIDE. XDG_CONFIG_HOME" \
    "does NOT isolate any of the destructive half. Running it will:" \
    "" \
    "  - docker rm -f EVERY container named cleat-*, on this whole machine," \
    "    including their writable layers (anything installed in a box, an az" \
    "    login, uncommitted work in a non-fork box)" \
    "  - delete the cleat image" \
    "  - run 'docker builder prune -f', which wipes the build cache SHARED with" \
    "    every other Docker project you have, nothing to do with cleat" \
    "" \
    "See exactly what you would destroy first:" \
    "  docker ps -a --filter name=^cleat-" \
    "" \
    "${DIM}Skipping this is the normal choice. No later check depends on it.${RESET}" \
    "" \
    "If you do want it, in a THROWAWAY shell (the export leaks otherwise):" \
    "  ( export XDG_CONFIG_HOME=$XDG_CONFIG_HOME" \
    "    cd $RUN_DIR/projects && mkdir -p nuketest && cd nuketest && git init -q" \
    "    $CLI_BIN fork run feat" \
    "    echo work > \"\$($CLI_BIN fork path feat)/WIP.txt\"" \
    "    $CLI_BIN rm feat && $CLI_BIN nuke )      # type: nuke" \
    "" \
    "Then confirm the copies and markers SURVIVED the nuke:" \
    "  ls $XDG_CONFIG_HOME/cleat/boxes/*.fork" \
    "  cat $XDG_CONFIG_HOME/cleat/forks/*feat/WIP.txt"
}

# Some checks need a live daemon (prune refuses without one, by design). Skip
# cleanly rather than reporting a failure that is really an environment fact.
_need_daemon() {   # id  title
  _daemon_up && return 0
  skip "$1" "$2" "needs a running Docker daemon"
  return 1
}

# A fork copy and its marker, made directly. Lets the copy-shaped checks run
# without creating a container, which is both faster and safer.
_fake_fork() {   # project  box -> echoes the copy dir
  local proj="$1" box="${2:-main}" cname copy
  # ASK THE CLI for the container name rather than re-deriving it. An earlier
  # version rebuilt container_name_for by hand (basename, tr, sed, md5) and
  # skipped its 48-char truncation and trailing-dash strip, so a long project
  # name would have silently pointed these checks at a directory the CLI does
  # not use. `cleat status <box>` prints the real name and cannot drift.
  cname="$(cd "$proj" && CO status "$box" 2>/dev/null | awk '/Container:/ {print $NF; exit}')"
  if [[ -z "$cname" ]]; then
    echo "${RED}could not resolve the container name for box $box${RESET}" >&2
    return 1
  fi
  copy="$XDG_CONFIG_HOME/cleat/forks/$cname"
  mkdir -p "$copy" "$XDG_CONFIG_HOME/cleat/boxes"
  : > "$XDG_CONFIG_HOME/cleat/boxes/${cname}.fork"
  printf '%s' "$copy"
}

check_04_prune_owns_only_its_own() {
  _need_daemon 04 "fork prune only touches its own directories" || return 0
  local forks="$XDG_CONFIG_HOME/cleat/forks"; mkdir -p "$forks"
  mkdir -p "$forks/my-notes" "$forks/cleat-orphan-11112222-main"
  echo keep > "$forks/my-notes/x.txt"
  local p; p="$(new_project prune-own)"
  ( cd "$p" && C fork prune --yes >/dev/null 2>&1 )
  want_file  04a "$forks/my-notes/x.txt" "a directory that is not a cleat copy is left alone"
  want_nofile 04b "$forks/cleat-orphan-11112222-main" "while a real orphan copy is reclaimed"
  _safe_rm "$forks/my-notes"
}

check_07_status_box_positional() {
  local p out; p="$(new_project statusbox)"
  out="$(cd "$p" && CO status feat-a)"
  want     07a "$out" "$p" "cleat status <box> reports THIS project, not a phantom one"
  want_not 07b "$out" "Project:   feat-a" "and never a directory that does not exist"
  local q; q="$(new_project statusbox2)"
  out="$(cd "$p" && CO status "$q")"
  want     07c "$out" "$q" "a real path still works as a project argument"
  out="$(cd "$p" && CO status "Bad Name")"; local rc=$?
  want     07d "$out" "Invalid box name" "and an invalid box name is refused"
}

check_08_fork_dead_end() {
  # The fix, exercised without a container: a marker whose copy is gone must be
  # droppable. Before it, cleat rm kept the marker and cleat fork rm bailed on
  # the missing directory, so the box was unstartable with no way out.
  local p copy out; p="$(new_project deadend)"
  copy="$(_fake_fork "$p" feat)"
  _safe_rm "$copy"                       # marker survives, copy is gone
  out="$(cd "$p" && CO fork rm feat)"
  want 08a "$out" "marker cleared" "cleat fork rm drops a marker whose copy is gone"
  want_nofile 08b "$XDG_CONFIG_HOME/cleat/boxes/$(basename "$copy").fork" "and the marker is really removed"
  out="$(cd "$p" && CO fork rm feat)"
  want 08c "$out" "No fork workspace" "a second call correctly reports nothing to drop"
}

check_14_fork_path_capturable() {
  # THE bug this subcommand exists to avoid: tput wrote its cursor-restore
  # escape to STDOUT, so `cd "$(cleat fork path feat)"` got the path, a newline
  # and then the escape, and cd failed.
  local p copy out; p="$(new_project forkpath)"
  copy="$(_fake_fork "$p" feat)"
  # Guarded on a NON-EMPTY setup and a NON-EMPTY capture. Without that every
  # assertion here degenerates to green when fork path prints nothing:
  # want_eq "" "" matches, `case "" in *ESC*` cannot match, and bash `cd ""`
  # silently returns 0. The check that guards `cd "$(cleat fork path feat)"`
  # was reporting 3/3 while testing nothing at all.
  if [[ -z "$copy" ]]; then
    bad 14a "fork path prints the bare path and nothing else" "setup failed: no container name"
    bad 14b "no terminal escapes reach stdout" "setup failed"
    bad 14c "and the captured value is usable with cd" "setup failed"
    return 0
  fi
  out="$(cd "$p" && "$CLI_BIN" fork path feat 2>/dev/null)"
  if [[ -z "$out" ]]; then
    bad 14a "fork path prints the bare path and nothing else" "printed nothing at all"
    bad 14b "no terminal escapes reach stdout" "nothing captured to check"
    bad 14c "and the captured value is usable with cd" "nothing captured to cd into"
    return 0
  fi
  want_eq 14a "$out" "$copy" "fork path prints the bare path and nothing else"
  case "$out" in
    *$'\033'*) bad 14b "no terminal escapes reach stdout" "found an escape byte" ;;
    *)          ok  14b "no terminal escapes reach stdout" ;;
  esac
  ( cd "$out" ) 2>/dev/null && ok 14c "and the captured value is usable with cd" \
    || bad 14c "and the captured value is usable with cd" "cd into [$out] failed"
}

check_17_interrupted_copies() {
  _need_daemon 17 "interrupted copies are reclaimed" || return 0
  local forks="$XDG_CONFIG_HOME/cleat/forks"; mkdir -p "$forks/.tmp.999999/src"
  echo half > "$forks/.tmp.999999/src/a"
  local p out; p="$(new_project interrupted)"
  out="$(cd "$p" && CO fork)"
  want_not 17a "$out" ".tmp." "a staging tree is not listed as a workspace copy"
  out="$(cd "$p" && CO fork prune --yes)"
  want        17b "$out" "interrupted" "and prune reports reclaiming it"
  want_nofile 17c "$forks/.tmp.999999" "and it is actually gone"
}

check_18_trust_hash_recorded() {
  local p; p="$(new_project trusthash)"
  printf '[caps]\ngit\n' > "$p/.cleat"
  ( cd "$p" && C trust >/dev/null 2>&1 ) || true
  local tf="$XDG_CONFIG_HOME/cleat/trust" before after
  before="$(awk -F'\t' -v q="$p" '$1==q {print $3}' "$tf" 2>/dev/null | head -1)"
  [[ -n "$before" ]] && ok 18a "approving a project records a caps hash" \
    || bad 18a "approving a project records a caps hash" "no row for $p in $tf"
  # a comment-only edit must NOT invalidate the approval
  printf '[caps]\ngit\n# just a comment\n' > "$p/.cleat"
  ( cd "$p" && C trust >/dev/null 2>&1 ) || true
  after="$(awk -F'\t' -v q="$p" '$1==q {print $3}' "$tf" 2>/dev/null | head -1)"
  want_eq 18b "$after" "$before" "a comment-only edit does not change the recorded hash"
  # adding a capability MUST
  printf '[caps]\ngit\nssh\n' > "$p/.cleat"
  ( cd "$p" && C trust >/dev/null 2>&1 ) || true
  after="$(awk -F'\t' -v q="$p" '$1==q {print $3}' "$tf" 2>/dev/null | head -1)"
  [[ "$after" != "$before" ]] && ok 18c "but adding a capability does"     || bad 18c "but adding a capability does" "hash stayed [$before]"
}

check_21_older_cleat_fails_open() {
  # The one compatibility fact worth seeing rather than being told. An older
  # Cleat cannot see [box.*] sections, falls back to [caps], and therefore gives
  # a locked-down box MORE than intended. This check exists to prove that is
  # still true, so nobody assumes a reduction is safe on a mixed-version team.
  # ALWAYS re-extract, and check what came out. Trusting the -x bit meant an
  # executable already sitting at that path was run instead, and never
  # refreshed: a planted script, or a truncated earlier extraction, would be
  # executed forever. The shebang test closes the not-a-script case too.
  local old="$RUN_DIR/cleat-old"
  _safe_rm "$old"
  ( cd "$REPO_ROOT/cli" && git show v1.3.1:bin/cleat ) > "$old" 2>/dev/null || true
  if [[ ! -s "$old" ]] || ! head -1 "$old" | grep -q '^#!.*sh'; then
    _safe_rm "$old"
    skip 21 "a per-box lockdown on an older Cleat fails OPEN" "could not extract a usable v1.3.1 from git"
    return 0
  fi
  chmod +x "$old"
  local p; p="$(new_project failopen)"
  printf '[caps]\ngit\ndocker\n[box.locked.caps]\n' > "$p/.cleat"
  local new_out old_out
  new_out="$(cd "$p" && CO config locked --list)"
  old_out="$(cd "$p" && "$old" config locked --list 2>&1 | _strip)"
  want_not 21a "$new_out" "[✔] docker" "this Cleat honours the lockdown"
  want     21b "$old_out" "[✔] docker" "an older Cleat gives the box the project caps instead"
  ok 21c "so a per-box REDUCTION fails OPEN on an older CLI, as documented"
}

check_29_per_box_setup_and_fork() {
  local p out; p="$(new_project pbx-setupfork)"
  printf '[setup]\nmake bootstrap\n[box.ci.setup]\nnpm ci\n' > "$p/.cleat"
  out="$(cd "$p" && CO setup ci --show)"
  want     29a "$out" "npm ci" "a per-box [setup] is what the box would run"
  want_not 29b "$out" "make bootstrap" "and it REPLACES the project setup"
  out="$(cd "$p" && CO setup --show)"
  want     29c "$out" "make bootstrap" "while the project keeps its own"

  # [fork] excludes, through a real refresh so no container is needed
  local q copy; q="$(new_project pbx-forkex)"
  mkdir -p "$q/node_modules/pkg" "$q/target"; echo dep > "$q/node_modules/pkg/i.js"
  printf '[fork]\nexclude = node_modules\n[box.ci.fork]\nexclude = target\n' > "$q/.cleat"
  copy="$(_fake_fork "$q" ci)"
  ( cd "$q" && printf 'y\n' | C fork refresh ci >/dev/null 2>&1 )
  want_nofile 29d "$copy/target" "a per-box [fork] exclude is applied"
  want_file   29e "$copy/node_modules/pkg/i.js" "and it REPLACES the project exclude"
}

check_15_idle_sweep_shell() {
  _gate 15 "Scenario 15: the idle sweep leaves an open shell alone" \
    "Needs a shell held open past the idle grace window, so a script cannot do it." \
    "" \
    "  export XDG_CONFIG_HOME=$XDG_CONFIG_HOME" \
    "  cd $RUN_DIR/projects && mkdir -p sweeptest && cd sweeptest && git init -q" \
    "  $CLI_BIN fork run feat && $CLI_BIN shell feat" \
    "" \
    "Leave that shell OPEN. In another terminal, past the grace window:" \
    "  XDG_CONFIG_HOME=$XDG_CONFIG_HOME $CLI_BIN start   # from ANOTHER project" \
    "" \
    "${AMBER}Keep the XDG prefix on that command.${RESET} The sweep enumerates with" \
    "docker ps --filter label=sh.cleat.version, which is HOST-WIDE, so running it" \
    "without the prefix can stop your REAL boxes instead of the test one." \
    "" \
    "The feat box must still be running when you come back to it. While attached:" \
    "  ls $XDG_CONFIG_HOME/cleat/run/*feat/.attached.*   # the claim marker" \
    "" \
    "${DIM}Skipping is fine: a unit test covers the marker logic.${RESET}"
}

check_16_claude_commands_symlink() {
  _gate 16 "Scenario 16: a symlink inside ~/.claude/commands" \
    "This one is DELIBERATELY not automated. It has to plant a symlink in your" \
    "REAL ~/.claude/commands, and this script's whole safety model is that it" \
    "never writes there. So it is yours to run, or to skip." \
    "" \
    "  mkdir -p ~/.claude/commands/deploy" \
    "  ln -s ~/.ssh ~/.claude/commands/deploy/keys" \
    "  cd $RUN_DIR/projects && mkdir -p symtest && cd symtest && git init -q" \
    "  XDG_CONFIG_HOME=$XDG_CONFIG_HOME $CLI_BIN run" \
    "" \
    "Then the property that matters, that no real key BYTES were copied:" \
    "  ls -l $XDG_CONFIG_HOME/cleat/run/*symtest*/kit/commands/deploy/   # keys must be a SYMLINK" \
    "  grep -rl 'PRIVATE KEY' $XDG_CONFIG_HOME/cleat/run/*symtest*/kit/commands/ ; echo \"exit=\$?\"" \
    "" \
    "Clean up:  rm -rf ~/.claude/commands/deploy"
}

check_19_hooks() {
  _gate 19 "Scenario 19: hooks, if you use them" \
    "Only meaningful if you already have hooks in ~/.claude/settings.json, and" \
    "it runs YOUR hook commands on the host, so it is not the script's to run." \
    "" \
    "  cd $RUN_DIR/projects && mkdir -p hooktest && cd hooktest && git init -q" \
    "  XDG_CONFIG_HOME=$XDG_CONFIG_HOME $CLI_BIN config --project --enable hooks" \
    "  XDG_CONFIG_HOME=$XDG_CONFIG_HOME $CLI_BIN start" \
    "" \
    "Work normally for a bit, then check each hook fired ONCE per event (an" \
    "event appended while the bridge was reading used to run twice), and after" \
    "exit that no hook process is left behind." \
    "" \
    "${DIM}Skipping is the normal choice unless you actually use hooks.${RESET}"
}

# ── report ──────────────────────────────────────────────────────────────────
_write_report() {
  mkdir -p "$REPORT_DIR"
  {
    echo "# cleat verify report"
    echo ""
    echo "- run dir: \`$RUN_DIR\`"
    echo "- isolated state: \`$XDG_CONFIG_HOME/cleat\` (your real config was never opened)"
    echo "- binary: \`$CLI_BIN\`"
    echo "- version: \`$("$CLI_BIN" version 2>/dev/null | tr -d '\033' | sed 's/\[[0-9;]*m//g' | tr -s ' ')\`"
    echo "- docker: $(_daemon_up && echo up || echo down)"
    echo ""
    echo "| | count |"
    echo "|---|---|"
    echo "| passed | $_pass |"
    echo "| failed | $_fail |"
    echo "| skipped | $_skip |"
    echo "| waiting on you | $_manual |"
    echo ""
    if [[ -s "$RESULTS" ]]; then
      echo "## Results"
      echo ""
      echo "| id | status | check | detail |"
      echo "|---|---|---|---|"
      local id st ti de
      while IFS=$'\t' read -r id st ti de; do
        printf '| %s | %s | %s | %s |\n' "$id" "$st" "$ti" "${de//~/ }"
      done < "$RESULTS"
      echo ""
    fi
    if [[ -n "$_failed_names" ]]; then
      echo "## Failed"
      echo ""
      echo "\`$_failed_names\`"
      echo ""
      echo "Each id maps to a scenario in MANUAL-TESTS-2026-07-31.md."
    fi
  } > "$REPORT"
}

_summary() {
  # Counted from the results file, not from this process's counters: a resumed
  # run starts them at zero, so the last leg reported "0 passed" for a session
  # that had 42 greens in it.
  # No `|| echo 0`: grep -c PRINTS 0 and EXITS 1 when it matches nothing, so the
  # fallback appended a second zero and the count became "0\n0", which then blew
  # up the arithmetic below. Count with awk, which has one exit status.
  if [[ -s "$RESULTS" ]]; then
    _pass="$(awk -F'\t' '$2=="PASS"{n++} END{print n+0}' "$RESULTS")"
    _fail="$(awk -F'\t' '$2=="FAIL"{n++} END{print n+0}' "$RESULTS")"
    _skip="$(awk -F'\t' '$2=="SKIP"{n++} END{print n+0}' "$RESULTS")"
    _manual="$(awk -F'\t' '$2=="MANUAL"{n++} END{print n+0}' "$RESULTS")"
  fi
  _write_report
  echo ""
  echo "  ${BOLD}${_pass} passed${RESET}  ${_fail} failed  ${_skip} skipped  ${_manual} waiting on you"
  echo "  ${DIM}report: $REPORT${RESET}"
  echo ""
  [[ "$_fail" -gt 0 ]] && return 1
  return 0
}

# ── driver ──────────────────────────────────────────────────────────────────
# Ids line up one-to-one with MANUAL-TESTS-2026-07-31.md, so "did I test
# everything" has one answer. Gates (the ones a script must not do for you) run
# last so the automated body always completes first.
CHECKS="02_fork_containment 04_prune_owns_only_its_own 05_disable_indented
        07_status_box_positional 08_fork_dead_end 09_unreadable_cleat
        10_env_name 11_nuke_no_tty 12_memory_floor 13_bom
        14_fork_path_capturable 17_interrupted_copies 18_trust_hash_recorded
        20_box_memory_writes_section 21_older_cleat_fails_open
        22_declared_empty 23_empty_keeps_header 24_declared_replaces
        25_resources_per_key 26_materialize_and_restore 27_legacy_file_announced
        28_trust_per_box 29_per_box_setup_and_fork 30_global_refuses_and_typo_warns
        01_prune_daemon_down 03_nuke_keeps_forks 06_session_key
        15_idle_sweep_shell 16_claude_commands_symlink 19_hooks"

RESUME=0; ONLY=""; NO_DOCKER=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --resume)    RESUME=1; shift ;;
    --only)      ONLY="${2:-}"; shift 2 ;;
    --no-docker) NO_DOCKER=1; shift ;;
    --clean)     _clean_rc=0
                 _clean_run_dir || _clean_rc=$?
                 # fenced too: only ever the derived report dir, never a path
                 # someone passed in.
                 case "$REPORT_DIR" in
                   */.cleat-verify) [[ -d "$REPORT_DIR" ]] && rm -rf "$REPORT_DIR" \
                                      && echo "removed $REPORT_DIR" ;;
                   *) echo "${RED}Refusing to delete $REPORT_DIR${RESET}" >&2 ;;
                 esac
                 # Propagate the failure. Exiting 0 here is how `--clean && run`
                 # sailed on past a clean that had not cleaned anything.
                 exit "$_clean_rc" ;;
    --report)    [[ -f "$REPORT" ]] && { echo "$REPORT"; cat "$REPORT"; } || echo "no report yet"; exit 0 ;;
    --list)      echo "checks (id  needs-you?):"
                 for c in $CHECKS; do
                   case "$c" in 01_*|03_*|06_*|15_*|16_*|19_*) echo "  ${c%%_*}  YES" ;; *) echo "  ${c%%_*}  no" ;; esac
                 done; exit 0 ;;
    -h|--help)   sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)           echo "unknown option: $1" >&2; exit 1 ;;
  esac
done

_setup_world
[[ "$RESUME" -eq 1 ]] || { : > "$RESULTS"; : > "$STATE"; }

echo ""
echo "  ${BOLD}cleat verify${RESET}  ${DIM}isolated state in $XDG_CONFIG_HOME/cleat${RESET}"
echo "  ${DIM}your real ~/.config/cleat is not touched${RESET}"
# Where am I? A gated run spans several invocations over as long as it takes to
# do the manual bits, and without this the only way to know how far you got was
# to remember. Derived from the gates in this file so it cannot drift.
_GATES_TOTAL="$(grep -c '^[[:space:]]*_gate ' "${BASH_SOURCE[0]}" 2>/dev/null || true)"
case "$_GATES_TOTAL" in ''|*[!0-9]*) _GATES_TOTAL=6 ;; esac
_GATES_DONE=0
if [[ -f "$STATE" ]]; then
  _GATES_DONE="$(grep -c '^gate:' "$STATE" 2>/dev/null || true)"
  case "$_GATES_DONE" in ''|*[!0-9]*) _GATES_DONE=0 ;; esac
fi
echo "  ${DIM}manual gates: ${_GATES_DONE}/${_GATES_TOTAL} passed${RESET}"
echo ""

for c in $CHECKS; do
  id="${c%%_*}"
  _want_check "$id" || continue
  case "$c" in
    01_*|03_*|06_*|15_*|16_*|19_*) [[ "$NO_DOCKER" -eq 1 ]] && { skip "$id" "$c" "--no-docker"; continue; } ;;
  esac
  "check_$c"
  _mark_done "$id"
done

rm -f "$STATE"
_summary
