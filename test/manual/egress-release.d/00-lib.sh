# egress-release.d/00-lib.sh: the library of egress-release.sh.
#
# Sourced by the entry point, never run on its own. It holds everything section 4 of the design
# names (DESIGN.md in the release-test notes): output, checks, run_cmd and its watchdog, text
# helpers, the cleat and docker wrappers, the scenario's helpers, the env file, the expect driver
# (a heredoc written into the run dir), human prompts, T1 and T3, host control, key value state,
# the safety fences, dry-run, the report and its redaction, the step registry.
#
# Rules for this file and every part: bash 3.2 (no associative arrays, no mapfile, no ${x,,}, no
# |& pipe, no case fallthrough, no negative array indexes, an empty array only as
# ${a[@]+"${a[@]}"}), BSD and GNU
# tools alike (no sed -i, no stat -c on macOS, no date -d, no readlink -f, no grep -P, no
# timeout(1)), BWK awk (no gensub, no regex intervals). Private names start with mt__.
#
# Additions to the design's API, each documented where it is defined: t_mode, t_is_auto,
# xstatus, xquiet, xsh_out, xsh_rc, kv_list. The library also shadows docker, cleat, osascript,
# networksetup, pmset and open with guard functions (section "Safety").

MT__TESTPROJ="eg-default eg-pull eg-smoke eg-refuse eg-check eg-setup eg-lock eg-fork eg-old eg-spec4 eg-core eg-rerun eg-rm eg-sweep eg-sweep2 eg-sweep3 eg-restart eg-night eg-stale eg-contain eg-other"

# ---------------------------------------------------------------------------------------------
# Overrides and globals
# ---------------------------------------------------------------------------------------------

# Resolve the MT_* overrides to their effective values (defaults applied, paths absolute).
# MT__SCRIPT_DIR (the directory of the running entry point) must be set. Safe to call twice.
mt_resolve_overrides() {
  local d
  if [ -z "${MT_WT:-}" ]; then
    MT_WT="${MT__REPO_DIR:-$MT__SCRIPT_DIR}/../.."
  fi
  if [ -d "$MT_WT" ]; then MT_WT=$(cd "$MT_WT" && pwd); fi
  MT_BASH="${MT_BASH:-/bin/bash}"
  case "$MT_BASH" in
    /*) ;;
    *) d=$(command -v "$MT_BASH" 2>/dev/null) && MT_BASH="$d" ;;
  esac
  MT_IMAGE="${MT_IMAGE:-cleat}"
  MT_EXPECT_ENGINE="${MT_EXPECT_ENGINE:-desktop-macos}"
  MT_NO_HOST_CONTROL="${MT_NO_HOST_CONTROL:-}"
  MT_SIM_HOST="${MT_SIM_HOST:-}"
  MT_ANSWERS="${MT_ANSWERS:-}"
  if [ -n "$MT_ANSWERS" ]; then
    case "$MT_ANSWERS" in /*) ;; *) MT_ANSWERS="$(pwd)/$MT_ANSWERS" ;; esac
  fi
  MT_ANSWERS_DEFAULT="${MT_ANSWERS_DEFAULT:-s}"
  MT_T1_AUTO="${MT_T1_AUTO:-}"
  MT_T1_TYPE="${MT_T1_TYPE:-}"
  MT_MIN_SLEEP_MINS="${MT_MIN_SLEEP_MINS:-60}"
  MT_MIN_NIGHT_HOURS="${MT_MIN_NIGHT_HOURS:-8}"
  MT_RESULTS="${MT_RESULTS:-$HOME/mt-egress-results}"
  case "$MT_RESULTS" in /*) ;; *) MT_RESULTS="$(pwd)/$MT_RESULTS" ;; esac
  export MT_BASH
}

# The overrides pinned in run.env, in this order.
MT__PINNED="MT_WT MT_BASH MT_IMAGE MT_EXPECT_ENGINE MT_NO_HOST_CONTROL MT_SIM_HOST MT_ANSWERS MT_ANSWERS_DEFAULT MT_T1_AUTO MT_T1_TYPE MT_MIN_SLEEP_MINS MT_MIN_NIGHT_HOURS"

# mt_lib_init: set every global of section 4.1. Needs RUN, RUNID, INV, DRY and MT__CODE_DIR from
# the entry point. In dry-run every test path lives inside the dry run dir.
mt_lib_init() {
  mt_resolve_overrides
  IS_MACOS=0
  [ "$(uname -s 2>/dev/null)" = Darwin ] && IS_MACOS=1
  DRY="${DRY:-0}"
  if [ "$DRY" = 1 ]; then
    P="$RUN/home/mt-egress"
    EGX="$RUN/home/mt-egress-xdg"
    UPX="$RUN/home/mt-egress-xdg-up"
    ENVF="$RUN/home/mt-eg-env.sh"
    READF="$RUN/home/mt-egress-readings.txt"
    CLEAT_UNVAL="$RUN/home/bin/cleat-unvalidated"
    CLEAT_NOGW="$RUN/home/bin/cleat-nogw"
  else
    P="$HOME/mt-egress"
    EGX="$HOME/mt-egress-xdg"
    UPX="$HOME/mt-egress-xdg-up"
    ENVF="$HOME/mt-eg-env.sh"
    READF="$HOME/mt-egress-readings.txt"
    CLEAT_UNVAL="$MT_WT/bin/cleat-unvalidated"
    CLEAT_NOGW="$MT_WT/bin/cleat-nogw"
  fi
  CFG="$EGX/cleat"
  SCRATCH="$RUN/scratch"
  CLEAT_V154="$SCRATCH/cleat-v154"
  GWIMG=""
  if [ -f "$MT_WT/bin/cleat" ]; then
    GWIMG="$(sed -n 's/^_GATEWAY_IMAGE="\(.*\)"$/\1/p' "$MT_WT/bin/cleat")"
  fi
  ENGINE_WORDS=""
  case "$MT_EXPECT_ENGINE" in
    desktop-macos|desktop-linux) ENGINE_WORDS="$(eg_engine_words "$MT_EXPECT_ENGINE")" ;;
  esac
  MT__KV="$RUN/kv"
  MT__STRIP="$MT__CODE_DIR/strip.sed"
  MT__DRIVER="$MT__CODE_DIR/drive.exp"
  MT__MATCHER="$MT__CODE_DIR/match.tcl"
  MT__ENVF="$ENVF"
  export MT__ENVF
  mkdir -p "$SCRATCH" "$RUN/t" 2>/dev/null
  [ "$DRY" = 1 ] && mkdir -p "$RUN/home/bin" 2>/dev/null
  [ -f "$MT__KV" ] || : > "$MT__KV"
  STEP_ID="${STEP_ID:-}"
  STEP_DIR="${STEP_DIR:-}"
  ATTEMPT="${ATTEMPT:-0}"
  STEP_TITLE="${STEP_TITLE:-}"
  RC=0; OUT=""; ERR=""; RAW=""; CMDREF=""; TIMEDOUT=0
  XBG=""; CHOICE=""; HOSTACT=""
  MT__JOBPID=""; MT__WDPID=""; MT__BGPIDS=""
  mt__write_helpers
}

# eg_engine_words KIND: the words _egress_engine_words prints (bin/cleat:10947), copied for the two
# kinds this run can meet. Any other kind is a framework error.
eg_engine_words() {
  case "$1" in
    desktop-macos) printf 'Docker Desktop on macOS' ;;   # bin/cleat:10949
    desktop-linux) printf 'Docker Desktop on Linux' ;;   # bin/cleat:10952
    *) fatal "eg_engine_words: no words recorded for engine kind $1" ;;
  esac
}

# ---------------------------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------------------------

mt__colors() {
  if [ "${MT__COLOR:-0}" = 1 ]; then
    MT__C_RED=$'\033[0;31m'; MT__C_GREEN=$'\033[0;32m'; MT__C_AMBER=$'\033[38;5;214m'
    MT__C_DIM=$'\033[2m'; MT__C_BOLD=$'\033[1m'; MT__C_RESET=$'\033[0m'; MT__C_BLUE=$'\033[0;34m'
  else
    MT__C_RED=""; MT__C_GREEN=""; MT__C_AMBER=""; MT__C_DIM=""; MT__C_BOLD=""; MT__C_RESET=""; MT__C_BLUE=""
  fi
}
mt__colors

say() { printf '%s\n' "$*"; }
hdr() { printf '\n%s== %s ==%s\n' "$MT__C_BOLD" "$*" "$MT__C_RESET"; }
warn() {
  printf '%s! %s%s\n' "$MT__C_AMBER" "$*" "$MT__C_RESET"
  if [ -n "${STEP_DIR:-}" ] && [ -d "$STEP_DIR" ]; then mt__check_write NOTE "$*" "" "" ""; fi
  return 0
}
# fatal TEXT: framework misuse or a fence refusal. Ends the step as ERROR. Inside a run_cmd job
# it leaves a marker that run_cmd turns into the same exit in the step shell.
fatal() {
  printf '%sFATAL: %s%s\n' "$MT__C_RED" "$*" "$MT__C_RESET" >&2
  mt__exit_with 1 "fatal: $*"
}
# mt__exit_with CODE NOTE: end the step (or the run_cmd job, which then hands the code on).
mt__exit_with() {
  if [ "${MT__IN_JOB:-0}" = 1 ] && [ -n "${MT__JOBBASE:-}" ]; then
    printf '%s\t%s\n' "$1" "$2" > "$MT__JOBBASE.exit"
  elif [ -n "${STEP_DIR:-}" ] && [ -d "$STEP_DIR" ]; then
    printf '%s\t%s\n' "$1" "$2" > "$STEP_DIR/.end"
  fi
  exit "$1"
}

# ---------------------------------------------------------------------------------------------
# Key value state (append-only $RUN/kv, last line wins)
# ---------------------------------------------------------------------------------------------

mt__kv_key_ok() {
  case "$1" in ''|*[!a-z0-9._-]*) return 1 ;; esac
  return 0
}
kv_set() {
  local k="$1" v="${2-}"
  mt__kv_key_ok "$k" || fatal "kv_set: bad key '$k' (allowed: a-z 0-9 . _ -)"
  case "$v" in *$'\t'*|*$'\n'*|*$'\r'*) v=$(printf '%s' "$v" | tr '\t\n\r' '   ') ;; esac
  printf '%s\t%s\n' "$k" "$v" >> "$MT__KV"
}
mt__kv_raw() {
  [ -f "$MT__KV" ] || return 0
  LC_ALL=C awk -F'\t' -v k="$1" '$1==k{v=substr($0, length(k)+2); f=1} END{if (f && v != "__mt_deleted__") print "=" v}' "$MT__KV" 2>/dev/null
}
kv_get() {
  mt__kv_key_ok "$1" || fatal "kv_get: bad key '$1'"
  local v
  v=$(mt__kv_raw "$1")
  case "$v" in
    =*) printf '%s\n' "${v#=}" ;;
    *) printf '%s\n' "${2-}" ;;
  esac
}
kv_has() {
  mt__kv_key_ok "$1" || fatal "kv_has: bad key '$1'"
  local v
  v=$(mt__kv_raw "$1")
  [ -n "$v" ]
}
kv_del() { kv_set "$1" "__mt_deleted__"; }
# kv_list PREFIX: every live key starting with PREFIX, one per line, in first-set order (addition).
kv_list() {
  [ -f "$MT__KV" ] || return 0
  LC_ALL=C awk -F'\t' -v p="$1" 'index($1, p) == 1 { if (!($1 in seen)) { seen[$1] = 1; order[++n] = $1 } v[$1] = substr($0, length($1)+2) }
    END { for (i = 1; i <= n; i++) if (v[order[i]] != "__mt_deleted__") print order[i] }' "$MT__KV"
}

# ---------------------------------------------------------------------------------------------
# Checks (one line each in $STEP_DIR/checks.tsv: n status desc expected got cmdref)
# ---------------------------------------------------------------------------------------------

mt__oneline() {
  # tabs and newlines to spaces, at most $2 characters (default 400)
  local s="$1" max="${2:-400}"
  case "$s" in *$'\t'*|*$'\n'*|*$'\r'*) s=$(printf '%s' "$s" | tr '\t\r' '  ' | awk 'NR > 1 { printf " | " } { printf "%s", $0 }') ;; esac
  if [ "${#s}" -gt "$max" ]; then s="${s:0:$max}..."; fi
  printf '%s' "$s"
}
mt__check_write() {
  # STATUS DESC EXPECTED GOT CMDREF: append one line, print nothing
  local f n
  [ -n "${STEP_DIR:-}" ] || return 0
  f="$STEP_DIR/checks.tsv"
  n=1
  if [ -f "$f" ]; then n=$(( $(wc -l < "$f" | tr -d ' ') + 1 )); fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$n" "$1" "$(mt__oneline "$2" 300)" "$(mt__oneline "$3" 300)" "$(mt__oneline "$4" 400)" "${5:-}" >> "$f"
}
mt__check_add() {
  # STATUS DESC EXPECTED GOT CMDREF: record and print
  local st="$1" desc="$2" exp="$3" got="$4" ref="${5:-}"
  mt__check_write "$st" "$desc" "$exp" "$got" "$ref"
  case "$st" in
    PASS) printf '  %s✔%s %s\n' "$MT__C_GREEN" "$MT__C_RESET" "$desc" ;;
    HUMAN-PASS) printf '  %s✔%s %s (you said yes)\n' "$MT__C_GREEN" "$MT__C_RESET" "$desc" ;;
    FAIL|HUMAN-FAIL|TIMEOUT)
      printf '  %s✖%s %s%s\n' "$MT__C_RED" "$MT__C_RESET" "$desc" "$( [ "$st" = TIMEOUT ] && printf ' (timed out)')"
      [ -n "$exp" ] && printf '      expected: %s\n' "$(mt__oneline "$exp" 200)"
      [ -n "$got" ] && printf '      got:      %s\n' "$(mt__oneline "$got" 200)"
      ;;
    SKIP|HUMAN-SKIP) printf '  %s~ %s (skipped: %s)%s\n' "$MT__C_DIM" "$desc" "$got" "$MT__C_RESET" ;;
    NOTE) printf '  %s· %s%s\n' "$MT__C_DIM" "$desc" "$MT__C_RESET" ;;
    VALUE) printf '  = %s: %s\n' "$desc" "$(mt__oneline "$got" 200)" ;;
    DRY) printf '  [dry] check: %s expects %s\n' "$desc" "$exp" ;;
  esac
  case "$st" in PASS|HUMAN-PASS|NOTE|VALUE|SKIP|HUMAN-SKIP|DRY) return 0 ;; esac
  return 1
}
# The cmd file stem a check read: the file's own .cmd sibling, else CMDREF.
mt__ref() {
  local f="$1" b
  b="${f##*/}"
  case "$b" in cmd-*) b="${b%%.*}"; printf '%s' "$b"; return 0 ;; esac
  printf '%s' "${CMDREF:-}"
}
mt__excerpt() {
  # FILE [CHARS]: the start of a file on one line
  local f="$1" n="${2:-400}" s
  [ -f "$f" ] || { printf '(no file %s)' "$f"; return 0; }
  s=$(LC_ALL=C head -c 6000 "$f" | awk 'NF { if (o) printf " | "; printf "%s", $0; o = 1 }')
  [ -n "$s" ] || s="(empty output)"
  mt__oneline "$s" "$n"
}
mt__file_arg() {
  # the FILE argument of a check: given, else $OUT
  if [ -n "${1:-}" ]; then printf '%s' "$1"; else printf '%s' "${OUT:-}"; fi
}
mt__dry_check() {
  mt__check_add DRY "$1" "$2" "" ""
}

expect_contains() {
  local desc="$1" needle="$2" f ref line
  f=$(mt__file_arg "${3:-}"); ref=$(mt__ref "$f")
  [ "${DRY:-0}" = 1 ] && { mt__dry_check "$desc" "$needle"; return 0; }
  if [ ! -f "$f" ]; then mt__check_add FAIL "$desc" "contains: $needle" "(no output file)" "$ref"; return 1; fi
  if mt__contains "$needle" "$f"; then
    line=$(LC_ALL=C grep -F -m 1 -e "${needle%%$'\n'*}" "$f" 2>/dev/null)
    mt__check_add PASS "$desc" "contains: $needle" "$line" "$ref"
    return 0
  fi
  mt__check_add FAIL "$desc" "contains: $needle" "$(mt__excerpt "$f")" "$ref"
}
expect_not_contains() {
  local desc="$1" needle="$2" f ref line
  f=$(mt__file_arg "${3:-}"); ref=$(mt__ref "$f")
  [ "${DRY:-0}" = 1 ] && { mt__dry_check "$desc" "no: $needle"; return 0; }
  if [ ! -f "$f" ]; then mt__check_add FAIL "$desc" "does not contain: $needle" "(no output file)" "$ref"; return 1; fi
  if mt__contains "$needle" "$f"; then
    line=$(LC_ALL=C grep -F -m 1 -e "${needle%%$'\n'*}" "$f" 2>/dev/null)
    mt__check_add FAIL "$desc" "does not contain: $needle" "${line:-$needle}" "$ref"
    return 1
  fi
  mt__check_add PASS "$desc" "does not contain: $needle" "" "$ref"
}
mt__contains() {
  # NEEDLE FILE: fixed string, possibly over several lines
  case "$1" in
    *$'\n'*)
      MT_NEEDLE="$1" LC_ALL=C awk 'BEGIN { n = ENVIRON["MT_NEEDLE"] } { c = c $0 "\n" } END { exit (index(c, n) ? 0 : 1) }' "$2" ;;
    *) LC_ALL=C grep -F -q -e "$1" "$2" 2>/dev/null ;;
  esac
}
mt__grep_ok() {
  # ERE FILE: rc 0 match, 1 none. A bad regex is a framework error.
  printf 'x\n' | LC_ALL=C grep -E -q -e "$1" >/dev/null 2>&1
  [ $? -le 1 ] || fatal "bad regular expression: $1"
  LC_ALL=C grep -E -q -e "$1" "$2" 2>/dev/null
}
expect_match() {
  local desc="$1" ere="$2" f ref line
  f=$(mt__file_arg "${3:-}"); ref=$(mt__ref "$f")
  [ "${DRY:-0}" = 1 ] && { mt__dry_check "$desc" "/$ere/"; return 0; }
  if [ ! -f "$f" ]; then mt__check_add FAIL "$desc" "matches: $ere" "(no output file)" "$ref"; return 1; fi
  if mt__grep_ok "$ere" "$f"; then
    line=$(LC_ALL=C grep -E -m 1 -e "$ere" "$f" 2>/dev/null)
    mt__check_add PASS "$desc" "matches: $ere" "$line" "$ref"
    return 0
  fi
  mt__check_add FAIL "$desc" "matches: $ere" "$(mt__excerpt "$f")" "$ref"
}
expect_not_match() {
  local desc="$1" ere="$2" f ref line
  f=$(mt__file_arg "${3:-}"); ref=$(mt__ref "$f")
  [ "${DRY:-0}" = 1 ] && { mt__dry_check "$desc" "no /$ere/"; return 0; }
  if [ ! -f "$f" ]; then mt__check_add FAIL "$desc" "matches nothing: $ere" "(no output file)" "$ref"; return 1; fi
  if mt__grep_ok "$ere" "$f"; then
    # every matching line (up to five) goes into got: a report pasted into a chat then names each
    # failing test of a bats run, not the first alone
    line=$(LC_ALL=C grep -E -e "$ere" "$f" 2>/dev/null | awk '{ n++; if (n <= 5) printf "%s%s", (n > 1 ? " | " : ""), $0 } END { if (n > 5) printf " | and %d more", n - 5 }')
    mt__check_add FAIL "$desc" "matches nothing: $ere" "$line" "$ref"
    return 1
  fi
  mt__check_add PASS "$desc" "matches nothing: $ere" "" "$ref"
}
expect_line() {
  local desc="$1" want="$2" f ref
  f=$(mt__file_arg "${3:-}"); ref=$(mt__ref "$f")
  [ "${DRY:-0}" = 1 ] && { mt__dry_check "$desc" "a line: $want"; return 0; }
  if [ ! -f "$f" ]; then mt__check_add FAIL "$desc" "a line: $want" "(no output file)" "$ref"; return 1; fi
  if MT_LINE="$want" LC_ALL=C awk 'BEGIN { w = ENVIRON["MT_LINE"]; sub(/[ \t]+$/, "", w) } { l = $0; sub(/[ \t]+$/, "", l); if (l == w) { f = 1; exit } } END { exit (f ? 0 : 1) }' "$f"; then
    mt__check_add PASS "$desc" "a line: $want" "$want" "$ref"
    return 0
  fi
  mt__check_add FAIL "$desc" "a line: $want" "$(mt__excerpt "$f")" "$ref"
}
mt__cmp() {
  # GOT OP N (integers)
  case "$2" in
    eq) [ "$1" -eq "$3" ] ;; ne) [ "$1" -ne "$3" ] ;; ge) [ "$1" -ge "$3" ] ;;
    gt) [ "$1" -gt "$3" ] ;; le) [ "$1" -le "$3" ] ;; lt) [ "$1" -lt "$3" ] ;;
    *) fatal "bad comparison operator '$2' (eq ne ge gt le lt)" ;;
  esac
}
mt__is_int() {
  case "$1" in ''|-|*[!0-9-]*|?*-*) return 1 ;; esac
  return 0
}
expect_count() {
  local desc="$1" ere="$2" op="$3" n="$4" f ref got
  f=$(mt__file_arg "${5:-}"); ref=$(mt__ref "$f")
  mt__is_int "$n" || fatal "expect_count: N is not an integer: $n"
  [ "${DRY:-0}" = 1 ] && { mt__dry_check "$desc" "count /$ere/ $op $n"; return 0; }
  if [ ! -f "$f" ]; then mt__check_add FAIL "$desc" "lines matching $ere: $op $n" "(no output file)" "$ref"; return 1; fi
  mt__grep_ok "$ere" "$f" >/dev/null 2>&1
  got=$(LC_ALL=C grep -E -e "$ere" "$f" 2>/dev/null | awk 'END { print NR + 0 }')
  if mt__cmp "$got" "$op" "$n"; then
    mt__check_add PASS "$desc" "lines matching $ere: $op $n" "$got" "$ref"
    return 0
  fi
  mt__check_add FAIL "$desc" "lines matching $ere: $op $n" "$got lines" "$ref"
}
expect_order() {
  local desc="$1" first="$2" second="$3" f ref r
  f=$(mt__file_arg "${4:-}"); ref=$(mt__ref "$f")
  [ "${DRY:-0}" = 1 ] && { mt__dry_check "$desc" "$first before $second"; return 0; }
  if [ ! -f "$f" ]; then mt__check_add FAIL "$desc" "$first, then $second" "(no output file)" "$ref"; return 1; fi
  r=$(MT_A="$first" MT_B="$second" LC_ALL=C awk 'BEGIN { a = ENVIRON["MT_A"]; b = ENVIRON["MT_B"] } { c = c $0 "\n" }
      END { i = index(c, a); j = index(c, b); if (i == 0) print "first-missing"; else if (j > 0 && j < i) print "second-before"; else print "ok" }' "$f")
  case "$r" in
    ok) mt__check_add PASS "$desc" "$first, then $second" "" "$ref" ;;
    first-missing) mt__check_add FAIL "$desc" "$first, then $second" "the first is missing: $(mt__excerpt "$f" 200)" "$ref" ;;
    *) mt__check_add FAIL "$desc" "$first, then $second" "the second occurs before the first" "$ref" ;;
  esac
}
expect_eq() {
  [ "${DRY:-0}" = 1 ] && { mt__dry_check "$1" "= $3"; return 0; }
  if [ "$2" = "$3" ]; then mt__check_add PASS "$1" "$3" "$2" ""; else mt__check_add FAIL "$1" "$3" "$2" ""; fi
}
expect_ne() {
  [ "${DRY:-0}" = 1 ] && { mt__dry_check "$1" "!= $3"; return 0; }
  if [ "$2" != "$3" ]; then mt__check_add PASS "$1" "not $3" "$2" ""; else mt__check_add FAIL "$1" "not $3" "$2" ""; fi
}
expect_num() {
  local desc="$1" got="$2" op="$3" n="$4"
  [ "${DRY:-0}" = 1 ] && { mt__dry_check "$desc" "$op $n"; return 0; }
  mt__is_int "$n" || fatal "expect_num: N is not an integer: $n"
  if ! mt__is_int "$got"; then mt__check_add FAIL "$desc" "$op $n" "not a number: $got" ""; return 1; fi
  if mt__cmp "$got" "$op" "$n"; then mt__check_add PASS "$desc" "$op $n" "$got" ""; else mt__check_add FAIL "$desc" "$op $n" "$got" ""; fi
}
# expect_rc DESC WANT: WANT is N or !N (any code but N). A timed-out command is a TIMEOUT.
expect_rc() {
  local desc="$1" want="$2" ok=1
  [ "${DRY:-0}" = 1 ] && { mt__dry_check "$desc" "rc $want"; return 0; }
  if [ "${TIMEDOUT:-0}" = 1 ]; then mt__check_add TIMEOUT "$desc" "rc $want" "the command timed out" "${CMDREF:-}"; return 1; fi
  case "$want" in
    !*) [ "${RC:-0}" != "${want#!}" ] || ok=0 ;;
    *) [ "${RC:-0}" = "$want" ] || ok=0 ;;
  esac
  if [ "$ok" = 1 ]; then mt__check_add PASS "$desc" "rc $want" "rc $RC" "${CMDREF:-}"; else mt__check_add FAIL "$desc" "rc $want" "rc $RC" "${CMDREF:-}"; fi
}
check_pass() { mt__check_add PASS "$1" "" "${2:-}" "${CMDREF:-}"; }
check_fail() { mt__check_add FAIL "$1" "${2:-}" "${3:-}" "${CMDREF:-}"; }
check_skip() { mt__check_add SKIP "$1" "" "${2:-}" ""; return 0; }
check_note() { mt__check_add NOTE "$1" "" "" ""; return 0; }
record_value() {
  local k="$1" v="${2-}" desc="${3:-$1}"
  kv_set "$k" "$v"
  mt__check_add VALUE "$desc" "" "$v" ""
  printf '%s UTC  %s  %s=%s\n' "$(utc_stamp)" "${STEP_ID:-run}" "$k" "$(mt__oneline "$v" 2000)" >> "$RUN/readings.txt"
  return 0
}
rec_row() { kv_set "rec.row$1.${STEP_ID:-run}" "$2"; }
rec_set() { kv_set "rec.$1" "$2"; }
step_abort() {
  mt__check_add FAIL "step aborted" "" "$1" ""
  mt__exit_with 3 "$1"
}
step_skip() {
  mt__check_add SKIP "step skipped" "" "$1" ""
  mt__exit_with 4 "$1"
}

# ---------------------------------------------------------------------------------------------
# Running commands: run_cmd, val and the watchdog (no timeout(1) on macOS)
# ---------------------------------------------------------------------------------------------

# The argv as one readable shell line.
mt__shjoin() {
  local mt__a mt__o="" mt__q
  for mt__a in "$@"; do
    case "$mt__a" in
      ''|*[!A-Za-z0-9_./:=@%+,^-]*) printf -v mt__q '%q' "$mt__a" ;;
      *) mt__q="$mt__a" ;;
    esac
    mt__o="$mt__o${mt__o:+ }$mt__q"
  done
  printf '%s' "$mt__o"
}
mt__cmd_new() {
  # DIR: a new cmd-<m> stem in DIR, into MT__BASE and CMDREF
  local mt__d="$1" mt__n=0
  [ -f "$mt__d/.cmdn" ] && mt__n=$(cat "$mt__d/.cmdn" 2>/dev/null)
  mt__is_int "$mt__n" || mt__n=0
  mt__n=$((mt__n + 1))
  printf '%s\n' "$mt__n" > "$mt__d/.cmdn"
  MT__BASE="$mt__d/cmd-$mt__n"
  CMDREF="cmd-$mt__n"
}
mt__watchdog() {
  # PID SECS FLAG: TERM the job's group at SECS, KILL it 3 s later. The wait reads the whole group:
  # the job's subshell dies at once, while the expect driver in it needs a moment to hang up the
  # session it spawned (which sits in a session of its own, out of reach of the group KILL).
  local pid="$1" secs="$2" flag="$3" n=0 k
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$n" -ge "$secs" ]; then
      : > "$flag"
      kill -TERM -"$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null
      k=0
      while [ "$k" -lt 3 ] && { kill -0 -"$pid" 2>/dev/null || kill -0 "$pid" 2>/dev/null; }; do sleep 1; k=$((k + 1)); done
      kill -KILL -"$pid" 2>/dev/null
      kill -KILL "$pid" 2>/dev/null
      return 0
    fi
    sleep 1
    n=$((n + 1))
  done
  return 0
}
mt__show() {
  # FILE [PREFIX]: the first 60 lines, indented
  [ -s "$1" ] || return 0
  awk -v f="${1##*/}" -v p="${2:-}" 'NR <= 60 { print "    " p $0 } END { if (NR > 60) printf "    ... %d more lines in %s\n", NR - 60, f }' "$1"
}
# mt__kill_job: stop the running run_cmd job group and its watchdog (Ctrl-C, cleanup).
mt__kill_job() {
  local p k
  for p in ${MT__JOBPID:-} ${MT__BGPIDS:-}; do
    kill -TERM -"$p" 2>/dev/null || kill -TERM "$p" 2>/dev/null
  done
  k=0
  while [ "$k" -lt 15 ]; do
    local alive=0
    # the group, not the leader alone: an expect driver in it hangs up its own session first
    for p in ${MT__JOBPID:-} ${MT__BGPIDS:-}; do
      kill -0 -"$p" 2>/dev/null && alive=1
      kill -0 "$p" 2>/dev/null && alive=1
    done
    [ "$alive" = 1 ] || break
    sleep 0.2
    k=$((k + 1))
  done
  for p in ${MT__JOBPID:-} ${MT__BGPIDS:-}; do
    kill -KILL -"$p" 2>/dev/null
    kill -KILL "$p" 2>/dev/null
  done
  if [ -n "${MT__WDPID:-}" ]; then
    kill -TERM -"$MT__WDPID" 2>/dev/null || kill -TERM "$MT__WDPID" 2>/dev/null
  fi
  for p in ${MT__JOBPID:-} ${MT__WDPID:-} ${MT__BGPIDS:-}; do { wait "$p"; } 2>/dev/null; done
  MT__JOBPID=""; MT__WDPID=""; MT__BGPIDS=""
}

# mt__job_start BASE SECS INFILE OUTFILE ERRFILE -- CMD...: CMD in its own process group (set -m
# just around the start), plus a watchdog. ERRFILE "-" means stderr into OUTFILE. Sets MT__JS_PID
# and MT__JS_WPID.
mt__job_start() {
  local mt__jb="$1" mt__js="$2" mt__ji="$3" mt__jo="$4" mt__je="$5"
  shift 5
  [ "${1:-}" = -- ] && shift
  rm -f "$mt__jb.timedout"
  set -m
  if [ "$mt__je" = - ]; then
    ( MT__IN_JOB=1; MT__JOBBASE="$mt__jb"; "$@" ) < "$mt__ji" > "$mt__jo" 2>&1 &
  else
    ( MT__IN_JOB=1; MT__JOBBASE="$mt__jb"; "$@" ) < "$mt__ji" > "$mt__jo" 2> "$mt__je" &
  fi
  MT__JS_PID=$!
  ( mt__watchdog "$MT__JS_PID" "$mt__js" "$mt__jb.timedout" ) < /dev/null > /dev/null 2>&1 &
  MT__JS_WPID=$!
  set +m
}
# mt__job_wait PID WPID BASE: reaps the job, stops its watchdog. Sets MT__JW_RC and MT__JW_TO.
mt__job_wait() {
  local mt__wp="$1" mt__ww="$2" mt__wb="$3"
  MT__JOBPID="$mt__wp"; MT__WDPID="$mt__ww"
  { wait "$mt__wp"; } 2>/dev/null
  MT__JW_RC=$?
  if [ -f "$mt__wb.timedout" ]; then
    # The watchdog fired: the subshell is gone, an expect driver may still be hanging up its
    # session and writing its status. Let it finish (3 s at most), then end what is left.
    local mt__wk=0
    while [ "$mt__wk" -lt 15 ] && kill -0 -"$mt__wp" 2>/dev/null; do sleep 0.2; mt__wk=$((mt__wk + 1)); done
    kill -KILL -"$mt__wp" 2>/dev/null
  fi
  kill -TERM -"$mt__ww" 2>/dev/null || kill -TERM "$mt__ww" 2>/dev/null
  { wait "$mt__ww"; } 2>/dev/null
  MT__JOBPID=""; MT__WDPID=""
  MT__JW_TO=0
  if [ -f "$mt__wb.timedout" ]; then MT__JW_TO=1; MT__JW_RC=124; fi
}
# mt__job_exit_marker BASE: a fatal, step_abort or step_skip inside the job ends the step the same way.
mt__job_exit_marker() {
  local mt__code mt__note
  [ -f "$1.exit" ] || return 0
  IFS=$'\t' read -r mt__code mt__note < "$1.exit"
  mt__is_int "$mt__code" || mt__code=1
  printf '%s\n' "$mt__note" >&2
  mt__exit_with "$mt__code" "$mt__note"
}

# run_cmd [-t SECS] [-n NAME] [-i FILE] [-e] [-q] -- CMD [ARGS...]
# Runs CMD (a binary or a shell function) in its own process group with stdin from FILE (default
# /dev/null), bounded by a watchdog of SECS (default 120). Sets RC OUT ERR RAW CMDREF TIMEDOUT and
# returns RC. -e keeps stderr apart (ERR), -q prints nothing. A timeout records a TIMEOUT check.
run_cmd() {
  local mt__secs=120 mt__name="" mt__in=/dev/null mt__sep=0 mt__quiet=0 mt__poll=""
  while [ $# -gt 0 ]; do
    case "$1" in
      -t) mt__secs="$2"; shift 2 ;;
      -n) mt__name="$2"; shift 2 ;;
      -i) mt__in="$2"; shift 2 ;;
      -e) mt__sep=1; shift ;;
      -q) mt__quiet=1; shift ;;
      --poll) mt__poll="$2"; mt__quiet=1; shift 2 ;;
      --) shift; break ;;
      *) fatal "run_cmd: unknown option '$1' (put the command after --)" ;;
    esac
  done
  [ $# -gt 0 ] || fatal "run_cmd: no command after --"
  mt__is_int "$mt__secs" || fatal "run_cmd: -t needs whole seconds, got '$mt__secs'"
  [ "$mt__in" = /dev/null ] || [ -r "$mt__in" ] || fatal "run_cmd: cannot read the input file $mt__in"
  local mt__d mt__base mt__line
  mt__d="${STEP_DIR:-}"
  [ -n "$mt__d" ] || mt__d="${MT__CMDDIR:-$RUN/main}"
  [ -d "$mt__d" ] || mkdir -p "$mt__d"
  if [ -n "$mt__poll" ]; then
    mt__base="$mt__d/$mt__poll"
  else
    mt__cmd_new "$mt__d"
    mt__base="$MT__BASE"
  fi
  mt__line=$(mt__shjoin "$@")
  printf '%s\n# name: %s\n# cwd: %s\n# watchdog: %s s\n# started: %s UTC\n' "$mt__line" "$mt__name" "$PWD" "$mt__secs" "$(utc_stamp)" > "$mt__base.cmd"
  rm -f "$mt__base.exit" "$mt__base.timedout" "$mt__base.rawerr"
  : > "$mt__base.err"
  RAW="$mt__base.raw"; OUT="$mt__base.out"; ERR="$mt__base.err"; TIMEDOUT=0
  if [ "${DRY:-0}" = 1 ]; then
    [ -n "$mt__poll" ] || printf '  [dry] %s%s\n' "$mt__line" "${mt__name:+  ($mt__name)}"
    : > "$mt__base.raw"; : > "$mt__base.out"
    RC=0; printf '0\n' > "$mt__base.rc"
    return 0
  fi
  [ "$mt__quiet" = 1 ] || printf '%s$ %s%s\n' "$MT__C_DIM" "$mt__line" "$MT__C_RESET"
  if [ "$mt__sep" = 1 ]; then
    mt__job_start "$mt__base" "$mt__secs" "$mt__in" "$mt__base.raw" "$mt__base.rawerr" -- "$@"
  else
    mt__job_start "$mt__base" "$mt__secs" "$mt__in" "$mt__base.raw" - -- "$@"
  fi
  mt__job_wait "$MT__JS_PID" "$MT__JS_WPID" "$mt__base"
  TIMEDOUT=$MT__JW_TO
  RC=$MT__JW_RC
  printf '%s\n' "$RC" > "$mt__base.rc"
  printf '# ended: %s UTC rc=%s%s\n' "$(utc_stamp)" "$RC" "$( [ "$TIMEDOUT" = 1 ] && printf ' (watchdog)')" >> "$mt__base.cmd"
  mt_clean "$mt__base.raw" "$mt__base.out"
  [ "$mt__sep" = 1 ] && mt_clean "$mt__base.rawerr" "$mt__base.err"
  [ -f "$mt__base.exit" ] && mt__show "$mt__base.out"
  mt__job_exit_marker "$mt__base"
  if [ "$mt__quiet" != 1 ]; then
    mt__show "$OUT"
    [ "$mt__sep" = 1 ] && mt__show "$ERR" "stderr: "
    [ "$RC" = 0 ] || printf '    %s(rc %s)%s\n' "$MT__C_DIM" "$RC" "$MT__C_RESET"
  fi
  if [ "$TIMEDOUT" = 1 ]; then
    if [ -n "$mt__poll" ]; then
      [ -n "${STEP_DIR:-}" ] && mt__check_write NOTE "a probe timed out after $mt__secs s: $mt__line" "" "" ""
    else
      mt__check_add TIMEOUT "command timed out after $mt__secs s: $mt__line" "" "" "$CMDREF"
    fi
  fi
  return "$RC"
}

# val VAR [run_cmd options] -- CMD [ARGS...]: CMD's cleaned stdout, trimmed, into VAR.
val() {
  local mt__vname="$1" mt__vv
  shift
  case "$mt__vname" in ''|[0-9]*|*[!A-Za-z0-9_]*) fatal "val: bad variable name '$mt__vname'" ;; esac
  if [ "${DRY:-0}" = 1 ]; then
    run_cmd -q -e "$@"
    printf -v "$mt__vname" '%s' "<dry:$mt__vname>"
    return 0
  fi
  run_cmd -q -e "$@"
  mt__vv=$(cat "$OUT" 2>/dev/null)
  mt__vv="${mt__vv#"${mt__vv%%[![:space:]]*}"}"
  mt__vv="${mt__vv%"${mt__vv##*[![:space:]]}"}"
  printf -v "$mt__vname" '%s' "$mt__vv"
  return "$RC"
}

# mt__probe SECS CMD...: a quiet bounded probe that leaves the step's last command (OUT, RC...)
# untouched. Its output is in MT__PROBE_OUT until the next probe.
mt__probe() {
  local mt__s1="${OUT:-}" mt__s2="${ERR:-}" mt__s3="${RAW:-}" mt__s4="${RC:-0}" mt__s5="${CMDREF:-}" mt__s6="${TIMEDOUT:-0}" mt__ps="$1" mt__prc
  shift
  run_cmd --poll probe -e -t "$mt__ps" -- "$@"
  mt__prc=$RC
  MT__PROBE_OUT="$OUT"
  OUT="$mt__s1"; ERR="$mt__s2"; RAW="$mt__s3"; RC="$mt__s4"; CMDREF="$mt__s5"; TIMEDOUT="$mt__s6"
  return "$mt__prc"
}

# ---------------------------------------------------------------------------------------------
# Text helpers
# ---------------------------------------------------------------------------------------------

mt_clean() {
  LC_ALL=C tr -d '\000' < "$1" | LC_ALL=C sed -f "$MT__STRIP" | LC_ALL=C tr '\r' '\n' > "$2"
}
clean_text() {
  LC_ALL=C tr -d '\000' | LC_ALL=C sed -f "$MT__STRIP" | LC_ALL=C tr '\r' '\n'
}
mt__derived() {
  # DESC SRCFILE: a new cmd file standing for "<the source command> | DESC", into MT__BASE, CMDREF
  local d src="$2" first=""
  d="${STEP_DIR:-}"; [ -n "$d" ] || d="${MT__CMDDIR:-$RUN/main}"
  [ -d "$d" ] || mkdir -p "$d"
  case "${src##*/}" in
    cmd-*) [ -f "${src%.*}.cmd" ] && first=$(head -1 "${src%.*}.cmd") ;;
  esac
  [ -n "$first" ] || first="${src##*/}"
  mt__cmd_new "$d"
  printf '%s | %s\n' "$first" "$1" > "$MT__BASE.cmd"
  OUT="$MT__BASE.out"; ERR="$MT__BASE.err"; RAW="$MT__BASE.out"
  : > "$ERR"
}
first_lines() {
  local n="$1" f
  f=$(mt__file_arg "${2:-}")
  mt__is_int "$n" || fatal "first_lines: N is not a number: $n"
  mt__derived "head -$n" "$f"
  if [ -f "$f" ]; then head -n "$n" "$f" > "$OUT"; else : > "$OUT"; fi
}
grep_lines() {
  local ere="$1" f
  f=$(mt__file_arg "${2:-}")
  mt__derived "grep -E '$ere'" "$f"
  printf 'x\n' | LC_ALL=C grep -E -q -e "$ere" >/dev/null 2>&1
  [ $? -le 1 ] || fatal "grep_lines: bad regular expression: $ere"
  if [ -f "$f" ]; then LC_ALL=C grep -E -e "$ere" "$f" > "$OUT" 2>/dev/null; else : > "$OUT"; fi
  return 0
}
grep_lines_after() {
  local ere="$1" n="$2" f
  f=$(mt__file_arg "${3:-}")
  mt__is_int "$n" || fatal "grep_lines_after: N is not a number: $n"
  mt__derived "grep -E -A $n '$ere'" "$f"
  printf 'x\n' | LC_ALL=C grep -E -q -e "$ere" >/dev/null 2>&1
  [ $? -le 1 ] || fatal "grep_lines_after: bad regular expression: $ere"
  if [ -f "$f" ]; then LC_ALL=C grep -E -A "$n" -e "$ere" "$f" > "$OUT" 2>/dev/null; else : > "$OUT"; fi
  return 0
}
display_width() {
  printf '%s' "$1" | LC_ALL=C tr -d '\200-\277' | wc -c | tr -d ' '
}
utc_stamp() { date -u '+%Y-%m-%d %H:%M:%S'; }
epoch_now() { date -u +%s; }

# Days from civil (Howard Hinnant), in awk. mt_epoch sets MT_FRAC to the fraction digits.
MT__AWK_EPOCH='
function mt_dfc(y, m, d,   era, yoe, doy, doe) {
  y -= (m <= 2)
  if (y >= 0) era = int(y / 400); else era = -int((399 - y) / 400)
  yoe = y - era * 400
  doy = int((153 * (m + (m > 2 ? -3 : 9)) + 2) / 5) + d - 1
  doe = yoe * 365 + int(yoe / 4) - int(yoe / 100) + doy
  return era * 146097 + doe - 719468
}
function mt_epoch(s,   y, mo, d, h, mi, se, rest, z, sign, zh, zm, e) {
  MT_FRAC = ""
  if (s !~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9][T ][0-9][0-9]:[0-9][0-9]:[0-9][0-9]/) return ""
  y = substr(s, 1, 4) + 0; mo = substr(s, 6, 2) + 0; d = substr(s, 9, 2) + 0
  h = substr(s, 12, 2) + 0; mi = substr(s, 15, 2) + 0; se = substr(s, 18, 2) + 0
  rest = substr(s, 20)
  if (substr(rest, 1, 1) == ".") {
    if (match(rest, /^\.[0-9]+/)) { MT_FRAC = substr(rest, 2, RLENGTH - 1); rest = substr(rest, RLENGTH + 1) }
  }
  sub(/^ +/, "", rest)
  sub(/ +$/, "", rest)
  e = mt_dfc(y, mo, d) * 86400 + h * 3600 + mi * 60 + se
  if (rest == "" || rest == "Z" || rest == "UTC") return e
  sign = substr(rest, 1, 1)
  if (sign != "+" && sign != "-") return ""
  z = substr(rest, 2)
  gsub(/:/, "", z)
  if (z !~ /^[0-9][0-9][0-9][0-9]$/) return ""
  zh = substr(z, 1, 2) + 0; zm = substr(z, 3, 2) + 0
  if (sign == "+") e -= zh * 3600 + zm * 60; else e += zh * 3600 + zm * 60
  return e
}'
# iso_to_epoch STAMP: epoch seconds of a Docker, relay or pmset stamp. Empty when it cannot parse.
iso_to_epoch() {
  awk -v s="$1" "$MT__AWK_EPOCH"'
BEGIN { e = mt_epoch(s); if (e != "") printf "%.0f\n", e }'
}
# iso_cmp A B: lt, eq or gt, fractions included. rc 1 and nothing printed when either is unreadable.
iso_cmp() {
  awk -v a="$1" -v b="$2" "$MT__AWK_EPOCH"'
BEGIN {
  ea = mt_epoch(a); fa = MT_FRAC; eb = mt_epoch(b); fb = MT_FRAC
  if (ea == "" || eb == "") exit 1
  if (ea < eb) r = "lt"; else if (ea > eb) r = "gt"
  else {
    while (length(fa) < 9) fa = fa "0"
    while (length(fb) < 9) fb = fb "0"
    fa = "x" substr(fa, 1, 9); fb = "x" substr(fb, 1, 9)
    if (fa < fb) r = "lt"; else if (fa > fb) r = "gt"; else r = "eq"
  }
  print r
}'
}
file_mode() {
  if [ "${IS_MACOS:-0}" = 1 ]; then /usr/bin/stat -f %Lp "$1"; else stat -c %a "$1"; fi
}
file_owner() {
  if [ "${IS_MACOS:-0}" = 1 ]; then /usr/bin/stat -f %u "$1"; else stat -c %u "$1"; fi
}
# phys_path PATH: the physical absolute path (a final symlink is kept as a link, its directory resolved).
phys_path() {
  local p="$1" dir base
  case "$p" in /*) ;; *) p="$PWD/$p" ;; esac
  while [ "${#p}" -gt 1 ] && [ "${p%/}" != "$p" ]; do p="${p%/}"; done
  if [ -d "$p" ] && [ ! -L "$p" ]; then (cd -P "$p" 2>/dev/null && pwd -P); return; fi
  dir="${p%/*}"; base="${p##*/}"
  [ -n "$dir" ] || dir=/
  dir=$(cd -P "$dir" 2>/dev/null && pwd -P) || return 1
  if [ "$dir" = / ]; then printf '/%s\n' "$base"; else printf '%s/%s\n' "$dir" "$base"; fi
}
# file_edit FILE SEDSCRIPT: in-place edit for BSD and GNU sed, keeping the inode.
file_edit() {
  local f="$1" t
  [ -f "$f" ] || fatal "file_edit: no such file: $f"
  t="${f%/*}/.mt-edit.$$"
  [ "${f%/*}" = "$f" ] && t=".mt-edit.$$"
  if sed -e "$2" "$f" > "$t"; then
    cat "$t" > "$f"
    rm -f "$t"
    return 0
  fi
  rm -f "$t"
  return 1
}

# ---------------------------------------------------------------------------------------------
# Safety: the delete fence, the cwd and config guards, the verb guards, the fenced docker helpers
# ---------------------------------------------------------------------------------------------

mt__in_testproj() {
  case " $MT__TESTPROJ " in *" $1 "*) return 0 ;; esac
  return 1
}
mt__phys_or_self() {
  local r
  r=$(phys_path "$1" 2>/dev/null) || r=""
  [ -n "$r" ] || r="$1"
  printf '%s' "$r"
}
# safe_rm PATH...: rm -rf only inside the run's own places. A refusal is fatal.
safe_rm() {
  local t
  for t in "$@"; do mt__rm_one "$t"; done
  return 0
}
mt__rm_one() {
  local t="$1" rp home cfgdir root ok=0 a allow
  [ -n "$t" ] || fatal "safe_rm: an empty path"
  case "$t" in /*) ;; *) fatal "safe_rm: not an absolute path: $t" ;; esac
  while [ "${#t}" -gt 1 ] && [ "${t%/}" != "$t" ]; do t="${t%/}"; done
  case "${t##*/}" in ''|.|..) fatal "safe_rm: refusing $t" ;; esac
  rp=$(phys_path "$t" 2>/dev/null) || return 0
  home=$(mt__phys_or_self "$HOME")
  case "$rp" in
    /|"$home"|"$home/.config"|"$home/.config/"*|"$home/.claude") fatal "safe_rm: refusing $t" ;;
  esac
  for root in "$P" "$EGX" "$UPX"; do
    root=$(mt__phys_or_self "$root")
    case "$rp" in "$root"|"$root"/*) ok=1 ;; esac
  done
  root=$(mt__phys_or_self "$RUN")
  case "$rp" in "$root"/*) ok=1 ;; esac
  for a in "$ENVF" "$READF" "$CLEAT_UNVAL" "$CLEAT_NOGW"; do
    [ "$rp" = "$(mt__phys_or_self "$a")" ] && ok=1
  done
  if [ "$ok" = 0 ]; then
    allow=$(kv_get cleanup.allow "")
    for a in $allow; do
      case "$a" in
        "$HOME/.claude/projects/"eg-*|"$HOME/.claude/debug/"*.txt|"$HOME/.claude/projects/"*-mt-egress-eg-*)
          [ "$rp" = "$(mt__phys_or_self "$a")" ] && ok=1 ;;
      esac
    done
  fi
  [ "$ok" = 1 ] || fatal "safe_rm: refusing to delete outside the test's places: $t"
  if [ "${DRY:-0}" = 1 ]; then
    printf '  [dry] rm -rf %s\n' "$rp"
    return 0
  fi
  [ -e "$rp" ] || [ -L "$rp" ] || return 0
  rm -rf "${rp:?}"
}
# assert_cwd [ARGS...]: PWD is $P/<name> or below (never $P, $HOME or elsewhere).
assert_cwd() {
  case " $* " in
    " --version "|" version "|" help "|" --help "|" egress --help ") return 0 ;;
  esac
  local here pp
  here=$(mt__phys_or_self "$PWD")
  pp=$(mt__phys_or_self "$P")
  case "$here" in
    "$pp"/?*) return 0 ;;
  esac
  fatal "assert_cwd: cleat must run inside a test project under $P, not in $PWD"
}
# assert_xdg DIR: the config dir is one of the run's own.
assert_xdg() {
  local d="$1" s
  [ -n "$d" ] || fatal "assert_xdg: an empty XDG_CONFIG_HOME would fall back to your real config"
  case "$d" in "$HOME/.config"|"$HOME/.config/") fatal "assert_xdg: refusing the real config $d" ;; esac
  case "$d" in
    "$EGX"|"$UPX"|"$P/eg-contain/.cfg") return 0 ;;
  esac
  s="$SCRATCH"
  case "$d" in "$s"/?*) return 0 ;; esac
  fatal "assert_xdg: $d is not one of the run's config dirs"
}
# The cleat verb guard: stop-all, nuke, clean, prune and fork prune never run.
mt__cleat_verb_guard() {
  local a verb="" next="" want_next=0 skipv=0
  for a in "$@"; do
    case "$a" in stop-all|nuke) fatal "refusing: cleat $a acts on every box on this machine" ;; esac
  done
  for a in "$@"; do
    if [ "$skipv" = 1 ]; then skipv=0; continue; fi
    case "$a" in
      --env|-e) skipv=1; continue ;;
      -*) continue ;;
    esac
    if [ -z "$verb" ]; then verb="$a"; want_next=1; continue; fi
    if [ "$want_next" = 1 ]; then next="$a"; break; fi
  done
  case "$verb" in
    stop-all|nuke|clean|prune) fatal "refusing: cleat $verb" ;;
    fork) [ "$next" = prune ] && fatal "refusing: cleat fork prune" ;;
  esac
  return 0
}

# The docker verb guard (the dk wrapper and the docker shadow below): rm, rmi, kill, stop, tag,
# system, builder, the sub-verb forms and anything holding "prune" go through the fenced helpers.
mt__docker_guard() {
  local a verb="" sub="" skipv=0
  for a in "$@"; do
    case "$a" in *prune*) fatal "refusing: docker $(mt__shjoin "$@") (prune is never run)" ;; esac
  done
  for a in "$@"; do
    if [ "$skipv" = 1 ]; then skipv=0; continue; fi
    if [ -z "$verb" ]; then
      case "$a" in
        --context|-c|--host|-H|--config|--log-level|-l|--tlscacert|--tlscert|--tlskey) skipv=1; continue ;;
        -*) continue ;;
      esac
      verb="$a"
      continue
    fi
    case "$a" in -*) continue ;; esac
    sub="$a"
    break
  done
  case "$verb" in
    rm|rmi|kill|stop|tag|system|builder|rename)
      fatal "refusing: docker $verb (use the fenced helpers of the library)" ;;
    image|container|volume|network|buildx)
      case "$sub" in rm|remove|kill|stop|tag|rename) fatal "refusing: docker $verb $sub (use the fenced helpers)" ;; esac ;;
    context)
      case "$sub" in use|rm|remove|create|update|import) fatal "refusing: docker context $sub (it changes Docker for every terminal)" ;; esac ;;
  esac
  return 0
}
# The shadows. A part that calls docker directly still meets the fence and the dry-run. cleat is
# never called directly (cl and clt hold the guards). The host tools obey MT_NO_HOST_CONTROL.
docker() {
  mt__docker_guard "$@"
  if [ "${DRY:-0}" = 1 ]; then printf '[dry] docker %s\n' "$(mt__shjoin "$@")" >&2; return 0; fi
  command docker "$@"
}
mt__docker() {
  # the fenced helpers' own way in
  if [ "${DRY:-0}" = 1 ]; then printf '[dry] docker %s\n' "$(mt__shjoin "$@")" >&2; return 0; fi
  command docker "$@"
}
cleat() { fatal "a step called cleat directly: use cl (off a terminal) or clt (on a pty)"; }
mt__hosttool() {
  local t="$1"
  shift
  if [ "${DRY:-0}" = 1 ]; then printf '[dry] %s %s\n' "$t" "$(mt__shjoin "$@")" >&2; return 0; fi
  if ! host_can; then printf 'refused: %s with host control off\n' "$t" >&2; return 1; fi
  command "$t" "$@"
}
osascript() { mt__hosttool osascript "$@"; }
networksetup() { mt__hosttool networksetup "$@"; }
pmset() { mt__hosttool pmset "$@"; }
open() { mt__hosttool open "$@"; }

# Fenced docker helpers. Each refuses anything that is not a test object and runs through run_cmd.
mt__fence_proj() {
  mt__in_testproj "$1" || fatal "fence: $1 is not a test project (allowed: $MT__TESTPROJ)"
}
mt__fence_box() {
  # PROJ: the box name into MT__FBOX (empty when the box does not exist)
  mt__fence_proj "$1"
  MT__FBOX=""
  [ "${DRY:-0}" = 1 ] && { MT__FBOX="<dry:cn $1>"; return 0; }
  mt__probe 60 cn "$1"
  MT__FBOX=$(head -1 "$MT__PROBE_OUT" 2>/dev/null)
  case "$MT__FBOX" in
    ""|cleat-"$1"-*) ;;
    *) fatal "fence: cn $1 printed $MT__FBOX, which is not a box of that project" ;;
  esac
}
mt__fence_gw() {
  # PROJ: the gateway name into MT__FGW (empty when there is none)
  mt__fence_proj "$1"
  MT__FGW=""
  [ "${DRY:-0}" = 1 ] && { MT__FGW="<dry:gw $1>"; return 0; }
  mt__probe 60 gw "$1"
  MT__FGW=$(head -1 "$MT__PROBE_OUT" 2>/dev/null)
  case "$MT__FGW" in
    ""|cleat-gw-*) ;;
    *) fatal "fence: gw $1 printed $MT__FGW, which is not a gateway" ;;
  esac
}
box_rawstop() {
  mt__fence_box "$1"
  [ -n "$MT__FBOX" ] || { check_note "box_rawstop $1: no box"; return 1; }
  run_cmd -t 120 -n "box_rawstop $1" -- mt__docker stop "$MT__FBOX"
}
box_rawrm() {
  mt__fence_box "$1"
  [ -n "$MT__FBOX" ] || { check_note "box_rawrm $1: no box"; return 1; }
  run_cmd -t 120 -n "box_rawrm $1" -- mt__docker rm -f "$MT__FBOX"
}
gw_stop() {
  mt__fence_gw "$1"
  [ -n "$MT__FGW" ] || { check_note "gw_stop $1: no gateway"; return 1; }
  run_cmd -t 120 -n "gw_stop $1" -- mt__docker stop "$MT__FGW"
}
gw_kill() {
  mt__fence_gw "$1"
  [ -n "$MT__FGW" ] || { check_note "gw_kill $1: no gateway"; return 1; }
  run_cmd -t 60 -n "gw_kill $1" -- mt__docker kill "$MT__FGW"
}
gw_hardkill() {
  local pid gid
  mt__fence_gw "$1"
  [ -n "$MT__FGW" ] || { check_note "gw_hardkill $1: no gateway"; return 1; }
  val pid -t 30 -- mt__docker inspect -f '{{.State.Pid}}' "$MT__FGW"
  val gid -t 30 -- mt__docker inspect -f '{{.Id}}' "$MT__FGW"
  if [ "${DRY:-0}" != 1 ]; then
    mt__is_int "$pid" && [ "$pid" -gt 1 ] || { check_fail "gw_hardkill $1: read the gateway's pid" "a pid" "$pid"; return 1; }
    case "$gid" in *[!0-9a-f]*|"") check_fail "gw_hardkill $1: read the gateway's id" "64 hex" "$gid"; return 1 ;; esac
    [ "${#gid}" = 64 ] || { check_fail "gw_hardkill $1: read the gateway's id" "64 hex" "$gid"; return 1; }
  fi
  # The kill lands only when the pid sits in the gateway's own cgroup, read in the same pid
  # namespace that kills it: a pid from another namespace never kills another process.
  run_cmd -t 120 -n "gw_hardkill $1" -- mt__docker run --rm --pid=host alpine sh -c \
    'grep -q "$2" "/proc/$1/cgroup" 2>/dev/null || { echo "gw_hardkill: pid $1 is not in the gateway container, nothing killed" >&2; exit 3; }; kill -9 "$1"' \
    sh "$pid" "$gid"
  [ "${DRY:-0}" = 1 ] || [ "$RC" = 0 ] || check_fail "gw_hardkill $1: kill -9 the gateway's process" "rc 0" "rc $RC $(head -n 1 "$OUT" 2>/dev/null)"
  return "$RC"
}
gw_rm() {
  mt__fence_gw "$1"
  [ -n "$MT__FGW" ] || { check_note "gw_rm $1: no gateway"; return 1; }
  run_cmd -t 120 -n "gw_rm $1" -- mt__docker rm -f "$MT__FGW"
}
mt__fence_egv() {
  case "$1" in egv-?*) ;; *) fatal "fence: $1 is not an egv- name" ;; esac
}
egv_create() {
  local n="$1"
  mt__fence_egv "$n"
  shift
  run_cmd -t 300 -n "egv_create $n" -- mt__docker create --name "$n" "$@"
}
egv_run() {
  local n="$1"
  mt__fence_egv "$n"
  shift
  run_cmd -t 300 -n "egv_run $n" -- mt__docker run -d --name "$n" "$@"
}
egv_rm() {
  local n
  for n in "$@"; do mt__fence_egv "$n"; done
  run_cmd -t 120 -n "egv_rm" -- mt__docker rm -f "$@"
}
egv_volrm() {
  mt__fence_egv "$1"
  run_cmd -t 120 -n "egv_volrm $1" -- mt__docker volume rm "$1"
}
img_tag() {
  case "$2" in "$MT_IMAGE"|"$MT_IMAGE:latest"|"$MT_IMAGE:mt-spec6") ;; *) fatal "fence: img_tag may only tag $MT_IMAGE or $MT_IMAGE:mt-spec6, not $2" ;; esac
  run_cmd -t 120 -n "img_tag $1 $2" -- mt__docker tag "$1" "$2"
}
img_rm() {
  case "$1" in "$MT_IMAGE:mt-spec6"|ghcr.io/cleatdev/cleat:v1.5.4) ;; *)
    [ -n "$GWIMG" ] && [ "$1" = "$GWIMG" ] || fatal "fence: img_rm may only remove $MT_IMAGE:mt-spec6, ghcr.io/cleatdev/cleat:v1.5.4 or the gateway image, not $1" ;;
  esac
  run_cmd -t 300 -n "img_rm $1" -- mt__docker rmi "$1"
}

# on_cleanup "COMMAND": runs when the step ends for any reason, last registered first, each under
# a 60 s watchdog that pauses while a human prompt is open. Journaled, so a cut attempt shows them
# on resume.
on_cleanup() {
  local c="$1" n=0 f
  [ -n "${STEP_DIR:-}" ] || fatal "on_cleanup outside a step"
  case "$c" in *$'\n'*) fatal "on_cleanup: one line only" ;; esac
  f="$STEP_DIR/cleanups"
  [ -f "$f" ] && n=$(wc -l < "$f" | tr -d ' ')
  n=$((n + 1))
  printf '%s\t%s\n' "$n" "$c" >> "$f"
  [ "${DRY:-0}" = 1 ] && printf '  [dry] on_cleanup: %s\n' "$c"
  return 0
}
mt__cleanup_pending() {
  # DIR: the journal entries not yet run, last registered first, as "n<TAB>command"
  local d="$1"
  [ -f "$d/cleanups" ] || return 0
  awk -F'\t' -v done_f="$d/cleanups.done" 'BEGIN { while ((getline l < done_f) > 0) done[l] = 1 }
    { if (!($1 in done)) { n++; line[n] = $0 } } END { for (i = n; i >= 1; i--) print line[i] }' "$d/cleanups"
}
mt__run_cleanups() {
  # DIR: run the pending journal entries in this shell's context
  local d="$1" n c pid wpid k
  [ -f "$d/cleanups" ] || return 0
  mt__cleanup_pending "$d" > "$d/.cleanups.todo"
  while IFS=$'\t' read -r n c; do
    [ -n "$n" ] || continue
    printf '  %s· cleanup: %s%s\n' "$MT__C_DIM" "$c" "$MT__C_RESET"
    if [ "${DRY:-0}" = 1 ]; then printf '%s\n' "$n" >> "$d/cleanups.done"; continue; fi
    ( MT__IN_CLEANUP=1; eval "$c" ) < /dev/null &
    pid=$!
    k=0
    while kill -0 "$pid" 2>/dev/null; do
      if [ -f "$d/.asking" ]; then k=0; else k=$((k + 1)); fi
      if [ "$k" -ge 60 ]; then
        printf '  cleanup timed out after 60 s: %s\n' "$c"
        kill -TERM "$pid" 2>/dev/null
        sleep 1
        kill -KILL "$pid" 2>/dev/null
        break
      fi
      sleep 1
    done
    { wait "$pid"; } 2>/dev/null
    printf '%s\n' "$n" >> "$d/cleanups.done"
  done < "$d/.cleanups.todo"
  rm -f "$d/.cleanups.todo"
  return 0
}

# cand_plus_script DIR BASE [TIP]: rc 0 when TIP (default HEAD) of the checkout DIR is a later
# commit on BASE and every commit after BASE touches only the release-test script
# (test/manual/egress-release.sh and test/manual/egress-release.d/): the candidate BASE "plus the
# script". TIP equal to BASE, BASE missing or not under TIP, or any other path touched (a merge read
# against each parent, a rename read as both of its paths) is rc 1. Prints the commits after BASE
# and what they touch. Read only.
cand_plus_script() {
  local d="$1" base="$2" tip="${3:-HEAD}" head="" b="" n="" names="" bad=""
  head=$(GIT_OPTIONAL_LOCKS=0 git -C "$d" rev-parse --verify --quiet "$tip^{commit}" 2>/dev/null)
  b=$(GIT_OPTIONAL_LOCKS=0 git -C "$d" rev-parse --verify --quiet "$base^{commit}" 2>/dev/null)
  if [ -z "$head" ] || [ -z "$b" ]; then printf '%s or %s cannot be read\n' "$tip" "$base"; return 1; fi
  if [ "$head" = "$b" ]; then printf '%s is %s itself\n' "$tip" "$base"; return 1; fi
  if ! GIT_OPTIONAL_LOCKS=0 git -C "$d" merge-base --is-ancestor "$b" "$head" 2>/dev/null; then
    printf '%s is not a later commit on %s\n' "$tip" "$base"; return 1
  fi
  n=$(GIT_OPTIONAL_LOCKS=0 git -C "$d" rev-list --count "$b..$head" 2>/dev/null)
  names=$( { GIT_OPTIONAL_LOCKS=0 git -C "$d" log -m --no-renames --format= --name-only "$b..$head" \
    && GIT_OPTIONAL_LOCKS=0 git -C "$d" diff --no-renames --name-only "$b" "$head"; } 2>/dev/null) || {
    printf 'the commits after %s cannot be read\n' "$base"; return 1; }
  printf '%s commit(s) after %s touch:\n' "${n:-?}" "$base"
  printf '%s\n' "$names" | LC_ALL=C awk 'NF && !seen[$0]++ { print "  " $0 }'
  bad=$(printf '%s\n' "$names" | LC_ALL=C awk 'NF && $0 != "test/manual/egress-release.sh" && index($0, "test/manual/egress-release.d/") != 1 && !seen[$0]++ { printf "%s%s", (k++ ? " " : ""), $0 }')
  if [ -n "$bad" ]; then printf 'not the script alone: %s\n' "$bad"; return 1; fi
  printf '%s plus the script\n' "$base"
  return 0
}

# cand_tracked_dirty: the candidate's tracked changes (the work tree and the index against HEAD)
# outside the script's own files, one path per line. Empty: the code under test is HEAD's. The
# script's files (test/manual/egress-release.sh, test/manual/egress-release.d/) may change mid-run:
# a fixed script is how a run goes on after a script bug. No cleat code lives there. A git that
# cannot answer prints a line, so it never reads as clean.
cand_tracked_dirty() {
  local a b
  a=$(GIT_OPTIONAL_LOCKS=0 git -C "$MT_WT" diff --no-renames --name-only HEAD -- 2>/dev/null) || a="(git diff HEAD failed in $MT_WT)"
  b=$(GIT_OPTIONAL_LOCKS=0 git -C "$MT_WT" diff --no-renames --name-only --cached 2>/dev/null) || b="(git diff --cached failed in $MT_WT)"
  printf '%s\n%s\n' "$a" "$b" | LC_ALL=C awk 'NF && $0 != "test/manual/egress-release.sh" && index($0, "test/manual/egress-release.d/") != 1 && !seen[$0]++'
  return 0
}

# mt__cand_base: the candidate every run of this script certifies (0.1, preflight row 7, 5.x).
mt__cand_base() { printf 'ac6ee85'; }
# mt__cand_same_code WANT: rc 0 when the certified commit WANT is the candidate base or the base
# plus the script, and HEAD is the base plus the script: a script commit made again (amended or
# rebuilt) leaves the code under test the base's. Read only.
mt__cand_same_code() {
  local base bsha
  base=$(mt__cand_base)
  cand_plus_script "$MT_WT" "$base" > /dev/null 2>&1 || return 1
  bsha=$(GIT_OPTIONAL_LOCKS=0 git -C "$MT_WT" rev-parse --verify --quiet "$base^{commit}" 2>/dev/null)
  [ -n "$bsha" ] && [ "$bsha" = "$1" ] && return 0
  cand_plus_script "$MT_WT" "$base" "$1" > /dev/null 2>&1
}

# guard_candidate: HEAD is the certified commit, a later commit on it that touches only the
# script's own files (a script fix), or, when the run certified the candidate base with or without
# the script, the base plus the script (mt__cand_same_code). No tracked change outside the script's
# own files, no test lock. Prints the cause and the fix and returns 1 on a violation.
guard_candidate() {
  local want head dirty
  want=$(kv_get cand.sha "")
  [ -n "$want" ] || want=$(mt__runenv_get cand_sha)
  head=$(GIT_OPTIONAL_LOCKS=0 git -C "$MT_WT" rev-parse HEAD 2>/dev/null)
  if [ -n "$want" ] && [ "$head" != "$want" ] && ! cand_plus_script "$MT_WT" "$want" > /dev/null 2>&1 \
     && ! mt__cand_same_code "$want"; then
    printf 'The candidate moved: HEAD is %s, this run certifies %s.\n' "${head:-unknown}" "$want"
    printf 'A later commit on it may touch only test/manual/egress-release.sh and test/manual/egress-release.d/.\n'
    printf 'Fix: put %s back at %s (never change its code mid-run), or start a new run.\n' "$MT_WT" "$want"
    return 1
  fi
  dirty=$(cand_tracked_dirty)
  if [ -n "$dirty" ]; then
    printf 'The candidate has tracked changes (git -C %s status): %s\n' "$MT_WT" "$(printf '%s\n' "$dirty" | head -n 3 | tr '\n' ' ')"
    printf 'Fix: restore them. A suite or the mutation harness may be running there.\n'
    return 1
  fi
  if [ -e "$MT_WT/.test-suite.lock" ]; then
    printf 'A test lock is held in the candidate: %s/.test-suite.lock\n' "$MT_WT"
    printf 'Fix: wait for the suite or the harness to finish, or read .test-suite.lock/owner and remove a stale lock.\n'
    return 1
  fi
  return 0
}
# guard_image: the local image carries this tree's relay and entrypoint (unless image.swapped).
guard_image() {
  [ "$(kv_get image.swapped 0)" = 1 ] && return 0
  [ "${DRY:-0}" = 1 ] && return 0
  # A daemon that does not answer cannot show the image. The loop meets one only before a step
  # that runs with Docker Desktop quit (MT__DOWN_OK, a --resume into sitting 3): egimg would then
  # read both files as not this tree's and send you to 0.5 for nothing. 3.0 read the image.
  if ! mt__probe 30 mt__docker_up; then
    printf 'Docker does not answer, so the image is not read before this step (3.0 read it).\n'
    return 0
  fi
  mt__probe 300 egimg
  if LC_ALL=C grep -q "relay: this tree's" "$MT__PROBE_OUT" && LC_ALL=C grep -q "entrypoint: this tree's" "$MT__PROBE_OUT"; then
    return 0
  fi
  printf 'The %s image does not carry this tree'"'"'s relay and entrypoint:\n' "$MT_IMAGE"
  sed 's/^/    /' "$MT__PROBE_OUT"
  printf 'Fix: ./egress-release.sh --only 0.5\n'
  return 1
}
# git_dirty_untracked: git status --porcelain minus the script's own files, untracked or changed
# (empty means clean).
git_dirty_untracked() {
  GIT_OPTIONAL_LOCKS=0 git -C "$MT_WT" status --porcelain --untracked-files=all 2>/dev/null \
    | LC_ALL=C awk '{ p = substr($0, 4) } p != "test/manual/egress-release.sh" && index(p, "test/manual/egress-release.d/") != 1'
  return 0
}

# ---------------------------------------------------------------------------------------------
# cleat wrappers: cl (off a terminal), clt (on a pty), cleat_argv
# ---------------------------------------------------------------------------------------------

# cleat_argv [--as NAME] [--xdg DIR] [--bin PATH] [--bash PATH] [--env K=V]...
# Sets CLEAT_ARGV to "env K=V... BASH CLEAT" (the env file's cleat(), or one of its siblings) and
# MT__CA_SHIFT to the number of arguments it consumed.
cleat_argv() {
  local as="" xdg="" bin="" bsh="" n=0 e
  local envs=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --as) as="$2"; shift 2; n=$((n + 2)) ;;
      --xdg) xdg="$2"; shift 2; n=$((n + 2)) ;;
      --bin) bin="$2"; shift 2; n=$((n + 2)) ;;
      --bash) bsh="$2"; shift 2; n=$((n + 2)) ;;
      --env) envs[${#envs[@]}]="$2"; shift 2; n=$((n + 2)) ;;
      *) break ;;
    esac
  done
  MT__CA_SHIFT=$n
  local bx="$EGX" bb="$MT_WT/bin/cleat"
  local base=()
  case "$as" in
    "") base=("CLEAT_NO_IDLE_SWEEP=${CLEAT_NO_IDLE_SWEEP-1}") ;;
    cleatu) bb="$CLEAT_UNVAL"; base=("CLEAT_NO_IDLE_SWEEP=1") ;;
    cleatup) bx="$UPX"; base=("CLEAT_NO_IDLE_SWEEP=1" "CLEAT_NO_CLAUDE_UPDATE_CHECK=1") ;;
    cleat154) bx="$UPX"; bb="$CLEAT_V154"; base=("CLEAT_NO_IDLE_SWEEP=1" "CLEAT_NO_CLAUDE_UPDATE_CHECK=1") ;;
    cleatnogw) bx="$UPX"; bb="$CLEAT_NOGW"; base=("CLEAT_NO_IDLE_SWEEP=1" "CLEAT_NO_CLAUDE_UPDATE_CHECK=1") ;;
    *) fatal "cleat_argv: unknown --as $as (cleatu cleatup cleat154 cleatnogw)" ;;
  esac
  [ -n "$xdg" ] && bx="$xdg"
  [ -n "$bin" ] && bb="$bin"
  [ -n "$bsh" ] || bsh="$MT_BASH"
  assert_xdg "$bx"
  for e in ${envs[@]+"${envs[@]}"}; do
    case "$e" in [A-Za-z_]*=*) ;; *) fatal "cleat_argv: --env needs K=V, got $e" ;; esac
    case "$e" in XDG_CONFIG_HOME=*) assert_xdg "${e#XDG_CONFIG_HOME=}" ;; esac
  done
  CLEAT_ARGV=(env "XDG_CONFIG_HOME=$bx" "${base[@]}" ${envs[@]+"${envs[@]}"} "$bsh" "$bb")
}

# cl [run_cmd options] [cleat_argv options] -- ARGS...: the candidate off a terminal (stdin
# /dev/null, output to files): the scenario's `cleat ... | head`. Watchdog 300 s unless -t.
cl() {
  local ro=() co=()
  while [ $# -gt 0 ]; do
    case "$1" in
      -t|-n|-i) ro[${#ro[@]}]="$1"; ro[${#ro[@]}]="$2"; shift 2 ;;
      -e|-q) ro[${#ro[@]}]="$1"; shift ;;
      --as|--xdg|--bin|--bash|--env) co[${#co[@]}]="$1"; co[${#co[@]}]="$2"; shift 2 ;;
      --) shift; break ;;
      *) fatal "cl: unknown option '$1' (cleat's own arguments go after --)" ;;
    esac
  done
  mt__cleat_verb_guard "$@"
  assert_cwd "$@"
  cleat_argv ${co[@]+"${co[@]}"}
  run_cmd -t 300 ${ro[@]+"${ro[@]}"} -- "${CLEAT_ARGV[@]}" "$@"
}
# clt [xrun options] [cleat_argv options] -- ARGS...: the candidate on an 80x24 pty, every prompt
# answered by the catalogue unless --answer names it. Watchdog 600 s unless -T.
clt() {
  local xo=() co=()
  while [ $# -gt 0 ]; do
    case "$1" in
      -t|-T|-n|--rows|--cols|--answer) xo[${#xo[@]}]="$1"; xo[${#xo[@]}]="$2"; shift 2 ;;
      --rule)
        xo[${#xo[@]}]="$1"; xo[${#xo[@]}]="$2"; xo[${#xo[@]}]="$3"; xo[${#xo[@]}]="$4"; shift 4
        if [ $# -gt 0 ] && mt__is_int "$1"; then xo[${#xo[@]}]="$1"; shift; fi ;;
      --watch|--wrap-stty|--prog|--bg) xo[${#xo[@]}]="$1"; shift ;;
      --as|--xdg|--bin|--bash|--env) co[${#co[@]}]="$1"; co[${#co[@]}]="$2"; shift 2 ;;
      --) shift; break ;;
      *) fatal "clt: unknown option '$1' (cleat's own arguments go after --)" ;;
    esac
  done
  mt__cleat_verb_guard "$@"
  assert_cwd "$@"
  cleat_argv ${co[@]+"${co[@]}"}
  xrun -T 600 ${xo[@]+"${xo[@]}"} -- "${CLEAT_ARGV[@]}" "$@"
}

# cleat_copy_image FILE (addition): a cleat copy the script wrote (2.24's v1.5.4 copy) builds and
# runs MT_IMAGE: its IMAGE_NAME line is rewritten when MT_IMAGE is not cleat. Nothing changes on the Mac.
cleat_copy_image() {
  local f="$1"
  [ -f "$f" ] || fatal "cleat_copy_image: no file $f"
  case "$f" in "$SCRATCH"/*|"$CLEAT_UNVAL"|"$CLEAT_NOGW") ;; *) fatal "cleat_copy_image: $f is not a copy the script wrote" ;; esac
  [ "$MT_IMAGE" = cleat ] && return 0
  file_edit "$f" "s/^IMAGE_NAME=\"[^\"]*\"\$/IMAGE_NAME=\"$MT_IMAGE\"/"
  grep -q "^IMAGE_NAME=\"$MT_IMAGE\"\$" "$f" || fatal "cleat_copy_image: no IMAGE_NAME line rewritten in $f"
}

# ---------------------------------------------------------------------------------------------
# docker
# ---------------------------------------------------------------------------------------------

# dk [run_cmd options] -- ARGS...: docker ARGS through run_cmd (watchdog 120 s). The verbs the
# fence reserves are refused.
dk() {
  local ro=()
  while [ $# -gt 0 ]; do
    case "$1" in
      -t|-n|-i) ro[${#ro[@]}]="$1"; ro[${#ro[@]}]="$2"; shift 2 ;;
      -e|-q) ro[${#ro[@]}]="$1"; shift ;;
      --) shift; break ;;
      *) fatal "dk: unknown option '$1' (docker's arguments go after --)" ;;
    esac
  done
  mt__docker_guard "$@"
  run_cmd -t 120 ${ro[@]+"${ro[@]}"} -- docker "$@"
}
dk_pull() { dk -t "${2:-900}" -- pull "$1"; }

# ---------------------------------------------------------------------------------------------
# The scenario's helpers (the env file of 0.2). Parts call them only through run_cmd or val.
# ---------------------------------------------------------------------------------------------

mt__cn_compute() {
  # PROJ: container_name_for of $P/PROJ, computed by the candidate itself under MT_BASH
  "$MT_BASH" -c '. "$1/bin/cleat" >/dev/null 2>&1 || exit 1; container_name_for "$(resolve_project "$2")" main' _ "$MT_WT" "$P/$1" 2>/dev/null
}
mt__cn_shape_ok() {
  # NAME PROJ: ^cleat-PROJ-[0-9a-f]{8}$
  local h
  case "$1" in "cleat-$2-"????????) ;; *) return 1 ;; esac
  h="${1#cleat-$2-}"
  case "$h" in *[!0-9a-f]*) return 1 ;; esac
  return 0
}
cn_name() {
  local p="$1" n
  [ -n "$p" ] || { echo "cn_name: no project" >&2; return 1; }
  n=$(kv_get "cn.$p" "")
  if [ -z "$n" ]; then
    n=$(mt__cn_compute "$p")
    if ! mt__cn_shape_ok "$n" "$p"; then
      echo "cn: the candidate named the box of $p '$n', which does not match ^cleat-$p-[0-9a-f]{8}\$" >&2
      [ -n "${STEP_DIR:-}" ] && mt__check_write FAIL "cn $p: the box name has the scenario's shape" "cleat-$p-<8 hex>" "$n" ""
      return 1
    fi
    kv_set "cn.$p" "$n"
  fi
  printf '%s\n' "$n"
}
cn() {
  local n
  n=$(cn_name "$1") || return 1
  docker ps -a --filter "name=^${n}\$" --format '{{.Names}}' | grep -x -F -e "$n" | head -1
  return 0
}
vol() {
  local c
  c=$(cn "$1")
  [ -n "$c" ] || return 1
  docker inspect -f '{{range .Mounts}}{{if eq .Destination "/run/cleat-egress"}}{{.Name}}{{end}}{{end}}' "$c" 2>/dev/null
}
gw() {
  local v
  v=$(vol "$1")
  [ -n "$v" ] || return 1
  kv_set "gwof.$1" "${v%-sock}"
  printf '%s\n' "${v%-sock}"
}
bx() {
  local c
  c=$(cn "$1"); shift
  [ -n "$c" ] || { echo "bx: no box for that project" >&2; return 1; }
  docker exec -u coder "$c" "$@"
}
bxr() {
  local c
  c=$(cn "$1"); shift
  [ -n "$c" ] || { echo "bxr: no box for that project" >&2; return 1; }
  docker exec -u 0 "$c" "$@"
}
bget() { bx "$1" curl -sS -o /dev/null -w '%{http_code}\n' --max-time 30 -x http://127.0.0.1:3128 "$2"; }
bconnect() { bx "$1" bash -c "printf 'CONNECT $2 HTTP/1.1\r\nHost: $2\r\n\r\n' | socat -t 5 - TCP:127.0.0.1:3128"; }
gwadm() {
  local g
  g=$(gw "$1"); shift
  [ -n "$g" ] || { echo "gwadm: no gateway for that project" >&2; return 1; }
  docker exec "$g" /usr/local/bin/gw-admin "$@"
}
shimlog() { bx "$1" tail -n "${2:-10}" /tmp/cleat-egress-shim.log; }
shimpids() { bxr "$1" bash -c 'for p in /proc/[0-9]*; do n=${p#/proc/}; [ "$n" = "$$" ] && continue; c=$(tr "\0" " " < "$p/cmdline" 2>/dev/null); case "$c" in "bash /usr/local/bin/cleat-egress-shim"*|"socat -T 900"*) echo "$n $c";; esac; done'; }
egobjs() {
  echo "-- gateways:"; docker ps -a --filter label=sh.cleat.role=gateway --format '{{.Names}}  {{.Status}}'
  echo "-- socket volumes:"; docker volume ls -q --filter label=sh.cleat.role=egress-sock
  echo "-- host files:"; ls -la "$CFG/egress-rendered" "$CFG/egress-boxes" "$CFG/egress-pins" "$CFG/egress-notices" 2>/dev/null
  return 0
}
egkind() { (cd "$MT_WT" && XDG_CONFIG_HOME="$EGX" "$MT_BASH" -c '. bin/cleat; _egress_engine_kind; echo'); }
egcheck() {
  echo "candidate: $(GIT_OPTIONAL_LOCKS=0 git -C "$MT_WT" rev-parse --short HEAD) on $(GIT_OPTIONAL_LOCKS=0 git -C "$MT_WT" rev-parse --abbrev-ref HEAD)"
  # The env file's egcheck (scenario block A) less the script's own files (cand_tracked_dirty).
  if [ -z "$(cand_tracked_dirty)" ]; then echo "tree: clean"; else echo "tree: NOT CLEAN, stop"; fi
  if [ -e "$MT_WT/.test-suite.lock" ]; then echo "test lock held in the worktree: something runs tests there, stop"; fi
  return 0
}
egimg() {
  docker image inspect "$MT_IMAGE" --format "$MT_IMAGE"' image: spec={{index .Config.Labels "sh.cleat.image-spec"}} created={{.Created}}'
  if docker run --rm --entrypoint cat "$MT_IMAGE" /usr/local/bin/cleat-egress-shim | cmp -s - "$MT_WT/docker/cleat-egress-shim"; then echo "relay: this tree's"; else echo "relay: NOT this tree's, run 0.5 again"; fi
  if docker run --rm --entrypoint cat "$MT_IMAGE" /entrypoint.sh | cmp -s - "$MT_WT/docker/entrypoint.sh"; then echo "entrypoint: this tree's"; else echo "entrypoint: NOT this tree's, run 0.5 again"; fi
  return 0
}
egread() {
  local c v g n tmp
  c=$(cn "$1"); v=$(vol "$1"); g="${v%-sock}"
  tmp="$SCRATCH/.egread.$$"
  { echo "== $(date -u '+%F %T') UTC host, VM clock $(docker run --rm alpine date -u '+%F %T' 2>/dev/null) UTC"
    docker inspect -f '{{.Name}} status={{.State.Status}} running={{.State.Running}} health={{if .State.Health}}{{.State.Health.Status}}{{end}} exit={{.State.ExitCode}} restarts={{.RestartCount}} started={{.State.StartedAt}} finished={{.State.FinishedAt}}' "$g" "$c"
    docker volume inspect -f 'volume {{.Name}} created={{.CreatedAt}} labels={{json .Labels}}' "$v"
    docker exec "$g" /usr/local/bin/gw-admin path_ok; docker exec "$g" /usr/local/bin/gw-admin last_shim_seen; docker exec "$g" /usr/local/bin/gw-admin counts
    docker exec "$c" stat -c 'proxy.sock owner=%u mode=%a' /run/cleat-egress/proxy.sock
    echo "relay started=$(docker exec "$c" grep -c 'relay started' /tmp/cleat-egress-shim.log) exited=$(docker exec "$c" grep -c 'relay exited' /tmp/cleat-egress-shim.log) again=$(docker exec "$c" grep -c 'supervisor started again in place' /tmp/cleat-egress-shim.log)"
    echo "allow rows in the gateway log: $(docker logs "$g" 2>&1 | grep -c ' allow host=')"; } > "$tmp" 2>&1
  cat "$tmp"
  { printf '## %s step %s project %s\n' "$(utc_stamp)" "${STEP_ID:-run}" "$1"; cat "$tmp"; } >> "$READF"
  { printf '## %s step %s project %s\n' "$(utc_stamp)" "${STEP_ID:-run}" "$1"; cat "$tmp"; } >> "$RUN/readings.txt"
  n=$(kv_get read.last 0); mt__is_int "$n" || n=0
  n=$((n + 1))
  kv_set read.last "$n"
  kv_set "read.$n.proj" "$1"
  kv_set "read.$n.step" "${STEP_ID:-run}"
  mt__egread_parse "$tmp" "$n" "$g"
  rm -f "$tmp"
  return 0
}
mt__egread_parse() {
  # FILE N GW: the block into kv read.N.*
  local f="$1" n="$2" g="$3" line k v who rest w
  while IFS= read -r line; do
    case "$line" in
      "== "*)
        v="${line#== }"; kv_set "read.$n.host_clock" "${v%% UTC*}"
        v="${line##*VM clock }"; kv_set "read.$n.vm_clock" "${v% UTC}" ;;
      /*" status="*)
        who=box
        [ -n "$g" ] && [ "${line%% *}" = "/$g" ] && who=gw
        case "${line%% *}" in /cleat-gw-*) who=gw ;; esac
        kv_set "read.$n.$who.name" "${line%% *}"
        rest="${line#* }"
        for w in $rest; do
          k="${w%%=*}"; v="${w#*=}"
          case "$k" in status|running|health|exit|restarts|started|finished) kv_set "read.$n.$who.$k" "$v" ;; esac
        done ;;
      "volume "*)
        v="${line#* created=}"; kv_set "read.$n.vol.created" "${v%% labels=*}"
        kv_set "read.$n.vol.labels" "${line#* labels=}" ;;
      "ok path_ok "*) kv_set "read.$n.path_ok" "${line#ok path_ok }" ;;
      "ok last_shim_seen "*) kv_set "read.$n.last_shim_seen" "${line#ok last_shim_seen }" ;;
      "ok counts "*) kv_set "read.$n.counts" "${line#ok counts }" ;;
      "proxy.sock owner="*)
        v="${line#proxy.sock owner=}"; kv_set "read.$n.sock.owner" "${v%% *}"
        kv_set "read.$n.sock.mode" "${line##*mode=}" ;;
      "relay started="*)
        # only the three names egread prints: a docker error word in the line never becomes a key
        for w in ${line#relay }; do
          case "${w%%=*}" in started|exited|again) kv_set "read.$n.relay.${w%%=*}" "${w#*=}" ;; esac
        done ;;
      "allow rows in the gateway log: "*) kv_set "read.$n.allow_rows" "${line##*: }" ;;
    esac
  done < "$f"
  return 0
}
egprobe() {
  local c
  c=$(cn "$1")
  [ -n "$c" ] || { echo "egprobe: no box for that project" >&2; return 1; }
  docker exec -d -u coder "$c" bash -c 'while :; do printf "%s %s\n" "$(date -u +%FT%TZ)" "$(curl -s -o /dev/null -w %{http_code} --max-time 20 -x http://127.0.0.1:3128 https://api.anthropic.com/)" >> /tmp/egress-probe.log; sleep 60; done'
}
egexhaust() { docker exec -d -u coder "$(cn "$1")" python3 -c '
import os, time
end = time.time() + 120
while time.time() < end:
    try:
        pid = os.fork()
    except OSError:
        time.sleep(0.05)
        continue
    if pid == 0:
        try:
            os.execv("/bin/sleep", ["sleep", str(int(end - time.time()) + 5)])
        finally:
            os._exit(0)'; }
box_running() {
  local c
  c=$(cn "$1")
  [ -n "$c" ] || return 1
  [ "$(docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null)" = true ]
}
# Claude Code is live in the box: docker top's command column read the way _is_claude_argv reads
# it (bin/cleat:24212). A failing docker top is "not live" here.
mt__is_claude_argv() {
  case "${1:-}" in
    claude|*/claude|*/claude/versions/*) return 0 ;;
    node|*/node|nodejs|*/nodejs) ;;
    *) return 1 ;;
  esac
  while [ $# -gt 1 ]; do
    shift
    case "$1" in
      -*) ;;
      claude|*/claude|*/claude/versions/*|*/@anthropic-ai/claude-code/*) return 0 ;;
      *) return 1 ;;
    esac
  done
  return 1
}
box_claude_live() {
  local c top col=-1 i
  local f=()
  c=$(cn "$1")
  [ -n "$c" ] || return 1
  [ "$(docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null)" = true ] || return 1
  top=$(docker top "$c" 2>/dev/null) || return 1
  [ -n "$top" ] || return 1
  {
    IFS=$' \t' read -r -a f || true
    i=0
    while [ "$i" -lt "${#f[@]}" ]; do
      case "${f[$i]}" in CMD|COMMAND) col=$i ;; esac
      i=$((i + 1))
    done
    [ "$col" -ge 0 ] || return 1
    while IFS=$' \t' read -r -a f; do
      [ "${#f[@]}" -gt "$col" ] || continue
      mt__is_claude_argv "${f[@]:$col}" && return 0
    done
  } <<EOF
$top
EOF
  return 1
}
mt__box_fmt() {
  local c
  c=$(cn "$1")
  [ -n "$c" ] || return 1
  docker inspect -f "$2" "$c"
}
box_started() { mt__box_fmt "$1" '{{.State.StartedAt}}'; }
box_id() { mt__box_fmt "$1" '{{.Id}}'; }
box_netmode() { mt__box_fmt "$1" '{{.HostConfig.NetworkMode}}'; }
gw_started() {
  local g
  g=$(gw "$1")
  [ -n "$g" ] || return 1
  docker inspect -f '{{.State.StartedAt}}' "$g"
}
gw_state() {
  local g
  g=$(gw "$1")
  [ -n "$g" ] || return 1
  docker inspect -f '{{.State.Status}} exit={{.State.ExitCode}} restarts={{.RestartCount}} health={{if .State.Health}}{{.State.Health.Status}}{{end}}' "$g"
}

# ---------------------------------------------------------------------------------------------
# The env file of 0.2 (EGRESS-RELEASE-TEST.md lines 227 to 271, byte for byte)
# ---------------------------------------------------------------------------------------------

mt__env_template() {
  cat <<'MT__ENV_EOF'
# Egress first-release test. In every terminal: /bin/bash, then: source ~/mt-eg-env.sh
case "$BASH_VERSION" in 3.2.*) ;; *) echo "NOT BASH 3.2: run /bin/bash first, then source this again" ;; esac
export PATH="/bin:/usr/bin:/usr/sbin:/sbin:$PATH"; hash -r     # stock macOS tools first
WT="$HOME/Workspaces/cleat/.egress-stage3"   # the candidate checkout
EGX="$HOME/mt-egress-xdg"                    # isolated cleat config for the whole run
CFG="$EGX/cleat"                             # plays the part of ~/.config/cleat
P="$HOME/mt-egress"                          # every test project lives under here
GWIMG="$(sed -n 's/^_GATEWAY_IMAGE="\(.*\)"$/\1/p' "$WT/bin/cleat")"
# The candidate under /bin/bash 3.2 with its own config. Idle sweep off unless CLEAT_NO_IDLE_SWEEP=0.
cleat()    { XDG_CONFIG_HOME="$EGX" CLEAT_NO_IDLE_SWEEP="${CLEAT_NO_IDLE_SWEEP-1}" /bin/bash "$WT/bin/cleat" "$@"; }
# The main box of a test project (by directory name), its socket volume and its gateway, read from Docker.
cn()       { docker ps -a --filter "name=^cleat-$1-[0-9a-f]{8}\$" --format '{{.Names}}' | head -1; }
vol()      { docker inspect -f '{{range .Mounts}}{{if eq .Destination "/run/cleat-egress"}}{{.Name}}{{end}}{{end}}' "$(cn "$1")" 2>/dev/null; }
gw()       { v="$(vol "$1")"; [ -n "$v" ] && printf '%s\n' "${v%-sock}"; }
bx()       { c="$(cn "$1")"; shift; docker exec -u coder "$c" "$@"; }      # in the box, as its user
bxr()      { c="$(cn "$1")"; shift; docker exec -u 0 "$c" "$@"; }          # in the box, as root
bget()     { bx "$1" curl -sS -o /dev/null -w '%{http_code}\n' --max-time 30 -x http://127.0.0.1:3128 "$2"; }
bconnect() { bx "$1" bash -c "printf 'CONNECT $2 HTTP/1.1\r\nHost: $2\r\n\r\n' | socat -t 5 - TCP:127.0.0.1:3128"; }
gwadm()    { g="$(gw "$1")"; shift; docker exec "$g" /usr/local/bin/gw-admin "$@"; }
shimlog()  { bx "$1" tail -n "${2:-10}" /tmp/cleat-egress-shim.log; }
shimpids() { bxr "$1" bash -c 'for p in /proc/[0-9]*; do n=${p#/proc/}; [ "$n" = "$$" ] && continue; c=$(tr "\0" " " < "$p/cmdline" 2>/dev/null); case "$c" in "bash /usr/local/bin/cleat-egress-shim"*|"socat -T 900"*) echo "$n $c";; esac; done'; }
egobjs()   { echo "-- gateways:"; docker ps -a --filter label=sh.cleat.role=gateway --format '{{.Names}}  {{.Status}}'
             echo "-- socket volumes:"; docker volume ls -q --filter label=sh.cleat.role=egress-sock
             echo "-- host files:"; ls -la "$CFG/egress-rendered" "$CFG/egress-boxes" "$CFG/egress-pins" "$CFG/egress-notices" 2>/dev/null; }
# The engine kind, read the way docs/egress-validation.md says: source the checkout, call the measure.
egkind()   { (cd "$WT" && XDG_CONFIG_HOME="$EGX" /bin/bash -c '. bin/cleat; _egress_engine_kind; echo'); }
egcheck()  { echo "candidate: $(git -C "$WT" rev-parse --short HEAD) on $(git -C "$WT" rev-parse --abbrev-ref HEAD)"
             if git -C "$WT" diff --quiet HEAD --; then echo "tree: clean"; else echo "tree: NOT CLEAN, stop"; fi
             if [ -e "$WT/.test-suite.lock" ]; then echo "test lock held in the worktree: something runs tests there, stop"; fi; }
# Whether the local cleat image carries this tree's relay and entrypoint. Spec 6 changed inside the
# number, so the label alone cannot tell a build of this tree from an older spec 6 build.
egimg()    { docker image inspect cleat --format 'cleat image: spec={{index .Config.Labels "sh.cleat.image-spec"}} created={{.Created}}'
             if docker run --rm --entrypoint cat cleat /usr/local/bin/cleat-egress-shim | cmp -s - "$WT/docker/cleat-egress-shim"; then echo "relay: this tree's"; else echo "relay: NOT this tree's, run 0.5 again"; fi
             if docker run --rm --entrypoint cat cleat /entrypoint.sh | cmp -s - "$WT/docker/entrypoint.sh"; then echo "entrypoint: this tree's"; else echo "entrypoint: NOT this tree's, run 0.5 again"; fi; }
# Every reading 10.7 steps 11, 14 and 15 ask for, stamped, appended to ~/mt-egress-readings.txt
egread()   { c="$(cn "$1")"; v="$(vol "$1")"; g="${v%-sock}"
             { echo "== $(date -u '+%F %T') UTC host, VM clock $(docker run --rm alpine date -u '+%F %T' 2>/dev/null) UTC"
               docker inspect -f '{{.Name}} status={{.State.Status}} running={{.State.Running}} health={{if .State.Health}}{{.State.Health.Status}}{{end}} exit={{.State.ExitCode}} restarts={{.RestartCount}} started={{.State.StartedAt}} finished={{.State.FinishedAt}}' "$g" "$c"
               docker volume inspect -f 'volume {{.Name}} created={{.CreatedAt}} labels={{json .Labels}}' "$v"
               docker exec "$g" /usr/local/bin/gw-admin path_ok; docker exec "$g" /usr/local/bin/gw-admin last_shim_seen; docker exec "$g" /usr/local/bin/gw-admin counts
               docker exec "$c" stat -c 'proxy.sock owner=%u mode=%a' /run/cleat-egress/proxy.sock
               echo "relay started=$(docker exec "$c" grep -c 'relay started' /tmp/cleat-egress-shim.log) exited=$(docker exec "$c" grep -c 'relay exited' /tmp/cleat-egress-shim.log) again=$(docker exec "$c" grep -c 'supervisor started again in place' /tmp/cleat-egress-shim.log)"
               echo "allow rows in the gateway log: $(docker logs "$g" 2>&1 | grep -c ' allow host=')"; } 2>&1 | tee -a ~/mt-egress-readings.txt; }
# One request a minute from inside the box, as its user, logged in the box at /tmp/egress-probe.log
egprobe()  { docker exec -d -u coder "$(cn "$1")" bash -c 'while :; do printf "%s %s\n" "$(date -u +%FT%TZ)" "$(curl -s -o /dev/null -w %{http_code} --max-time 20 -x http://127.0.0.1:3128 https://api.anthropic.com/)" >> /tmp/egress-probe.log; sleep 60; done'; }
MT__ENV_EOF
}
# mt__lit_replace FROM TO: every literal FROM on stdin becomes TO.
mt__lit_replace() {
  MT_F="$1" MT_T="$2" LC_ALL=C awk 'BEGIN { f = ENVIRON["MT_F"]; t = ENVIRON["MT_T"] }
    { s = $0; o = ""; while ((i = index(s, f)) > 0) { o = o substr(s, 1, i - 1) t; s = substr(s, i + length(f)) } print o s }'
}
# mt__env_render FILE: the env file 0.2 writes, into FILE. Only an override that differs from its
# default changes a line, so with no overrides the file is the scenario's own.
mt__env_render() {
  local t1="$1" t2="$1.2" new
  mt__env_template > "$t1"
  if [ "$MT_WT" != "$HOME/Workspaces/cleat/.egress-stage3" ]; then
    case "$MT_WT" in
      "$HOME"/*) new='WT="$HOME/'"${MT_WT#"$HOME"/}"'"' ;;
      *) new='WT="'"$MT_WT"'"' ;;
    esac
    mt__lit_replace 'WT="$HOME/Workspaces/cleat/.egress-stage3"' "$new" < "$t1" > "$t2" && mv "$t2" "$t1"
  fi
  if [ "$MT_BASH" != /bin/bash ]; then
    mt__lit_replace '/bin/bash "$WT/bin/cleat"' "$MT_BASH"' "$WT/bin/cleat"' < "$t1" > "$t2" && mv "$t2" "$t1"
    mt__lit_replace "/bin/bash -c '. bin/cleat" "$MT_BASH -c '. bin/cleat" < "$t1" > "$t2" && mv "$t2" "$t1"
  fi
  if [ "$MT_IMAGE" != cleat ]; then
    mt__lit_replace 'docker image inspect cleat --format' "docker image inspect $MT_IMAGE --format" < "$t1" > "$t2" && mv "$t2" "$t1"
    mt__lit_replace '--entrypoint cat cleat /' "--entrypoint cat $MT_IMAGE /" < "$t1" > "$t2" && mv "$t2" "$t1"
  fi
  rm -f "$t2"
}
# env_write: writes $ENVF (the scenario's block A, see mt__env_render). An existing file that
# differs is overwritten, as the scenario's cat > does. The difference is a NOTE.
env_write() {
  local t1="$SCRATCH/.envf.$$"
  mt__env_render "$t1"
  if [ -f "$ENVF" ] && ! cmp -s "$t1" "$ENVF"; then
    check_note "the existing env file differed and is overwritten ($(diff "$ENVF" "$t1" 2>/dev/null | grep -c '^[<>]') lines changed)"
  fi
  cat "$t1" > "$ENVF"
  rm -f "$t1"
  return 0
}
# env_check: block B under MT_BASH (the env file sourced first). The output is in OUT.
env_check() {
  run_cmd -t 180 -n "env file, block B" -- "$MT_BASH" -c 'source "$1"; type cleat | head -1; cleat --version; cleat egress --help | grep -c '"'egress why'" _ "$ENVF"
}

# ---------------------------------------------------------------------------------------------
# The expect driver, bash side: xrun, the xp_* program, the prompt catalogue, xshell
# ---------------------------------------------------------------------------------------------

# The prompt catalogue (rule 3): TAG, Tcl ARE on the raw output, default keys, flags.
# Every default-yes offer is answered n unless a step names it (--answer TAG=ANSWER).
# Sources are bin/cleat lines at ac6ee85.
mt__catalogue() {
  cat <<'MT__CAT_EOF'
cli-upgrade	Upgrade now\?	n<enter>		21169
img-update	Update the image before starting\?	n<enter>		21346
img-refresh	Refresh the image now\?	n<enter>		6952
img-refresh-recreate	Refresh the image and recreate \S+ now\? \[Y/n\]	n<enter>		6861
recreate	Recreate \S+ now\? \[Y/n\]	n<enter>		6863
recreate-touse	Recreate \S+ now to use it\? \[Y/n\]	n<enter>		21618
recreate-policy	under the policy now\? It discards	n<enter>		11811
reaper	Recreate it now\?	n<enter>		7001
start-fresh	Remove container and start fresh\? \[Y/n\]	n<enter>		22816
prune	Prune them now\?	n<enter>		24379
docker-gate	to launch anyway	<enter>	note	24676
trust-caps	Trust this project('s \.cleat)?\?	n<enter>		5281 5306
trust-setup	Run this project's setup commands\?	n<enter>		5376
env-scaffold	Create \.cleat\.env in 	n<enter>		33745
handoff	Hand (over|both over|all [0-9]+ over)\? \[	n<enter>		30831
account-rm	Remove it\? \[y/N\]	n<enter>		31730
eg-open	Open egress for this box until it stops\? \[y/N\]	n<enter>		13431 17315
eg-open-always	Open egress for every box until you change it\? \[y/N\]	n<enter>		13481
eg-off-box	Turn egress control off and recreate the box\? \[y/N\]	n<enter>		13612 17322
eg-off-all	Turn egress control off for every new box\? \[y/N\]	n<enter>		13654 17318
eg-turn-off	Turn it off\? \[y/N\]	n<enter>		17329
eg-drop	Drop it\? \[y/N\]	n<enter>		14785 14816
eg-review	Accept these and re-pin\? \[y/N\]	n<enter>		13047
eg-save-ny	Save\? \[y/N\]	n<enter>		17333
eg-save-yn	Save\? \[Y/n\]	n<enter>		17344
eg-more	More below: any key goes on, q goes back\.	<space>		17418
kit-enable	Enable\? \[Y/n\]	n<enter>		35265
kit-rebuild	Rebuild now\? \[y/N\]	n<enter>		35174
delete-yn	(Delete it|Replace it|Delete all of them)\? \[y/N\]	n<enter>		26714 34928 34943 35056
cache-clear	Clear the shared build cache\? \[y/N\]	n<enter>		23950
write-cleat	Write this \.cleat\?	n<enter>		34018
unnamed-Yn	\[Y/n\](\x1b\[[0-9;]*m)? ?$	n<enter>	note	generic
unnamed-yN	\[y/N\](\x1b\[[0-9;]*m)? ?$	n<enter>	note	generic
MT__CAT_EOF
}
mt__cat_has() {
  mt__catalogue | awk -F'\t' -v t="$1" '$1 == t { f = 1 } END { exit (f ? 0 : 1) }'
}
# An --answer value as keys: manual (the program answers itself), keys with <name>, or a word
# that is typed and followed by Enter.
mt__answer_keys() {
  case "$1" in
    *"<"*) printf '%s' "$1" ;;
    *) printf '%s<enter>' "$1" ;;
  esac
}
mt__tsv_ok() {
  case "$1" in *$'\t'*|*$'\n'*) fatal "a tab or a newline cannot be part of an expect program field: $1" ;; esac
}
# mt__write_rules FILE: the step's rules, the program's xp_rule lines, the catalogue (with the
# step's answers), the generic rules. Uses the arrays mt__xr_* and mt__xa of the caller.
mt__write_rules() {
  local f="$1" i tag a ans keys max flags re
  : > "$f"
  i=0
  while [ "$i" -lt "${#mt__xr_tag[@]}" ]; do
    tag="${mt__xr_tag[$i]}"; keys="${mt__xr_keys[$i]}"; max="${mt__xr_max[$i]}"; flags=""
    for a in ${mt__xa[@]+"${mt__xa[@]}"}; do
      if [ "${a%%=*}" = "$tag" ]; then
        ans="${a#*=}"
        if [ "$ans" = manual ]; then flags=manual; keys=""; max=0; else keys=$(mt__answer_keys "$ans"); fi
      fi
    done
    printf 'rule\t%s\t%s\t%s\t%s\t%s\n' "$tag" "${mt__xr_re[$i]}" "$keys" "$max" "$flags" >> "$f"
    i=$((i + 1))
  done
  if [ -n "${STEP_DIR:-}" ] && [ -f "$STEP_DIR/.xprog" ] && [ "${mt__xprog:-0}" = 1 ]; then
    grep '^rule	' "$STEP_DIR/.xprog" >> "$f"
  fi
  : > "$f.answers"
  for a in ${mt__xa[@]+"${mt__xa[@]}"}; do printf '%s\n' "$a" >> "$f.answers"; done
  mt__catalogue | LC_ALL=C awk -F'\t' -v af="$f.answers" '
    BEGIN { while ((getline l < af) > 0) { i = index(l, "="); ans[substr(l, 1, i - 1)] = substr(l, i + 1) } }
    {
      tag = $1; re = $2; keys = $3; flags = $4; max = 0
      if (tag in ans) {
        a = ans[tag]
        if (a == "manual") { flags = "manual"; keys = ""; max = 0 }
        else { keys = (index(a, "<") ? a : a "<enter>"); max = 1 }
      }
      printf "rule\t%s\t%s\t%s\t%s\t%s\n", tag, re, keys, max, flags
    }' >> "$f"
  rm -f "$f.answers"
}
mt__xdir() {
  if [ -n "${STEP_DIR:-}" ]; then printf '%s' "$STEP_DIR"; else printf '%s' "${MT__CMDDIR:-$RUN/main}"; fi
}

# The sequential program, built line by line since the last xp_new.
xp_new() { local d; d=$(mt__xdir); mkdir -p "$d"; : > "$d/.xprog"; }
mt__xp() {
  local d a line=""
  d=$(mt__xdir)
  [ -f "$d/.xprog" ] || fatal "xp_*: call xp_new first"
  for a in "$@"; do mt__tsv_ok "$a"; line="$line${line:+	}$a"; done
  printf '%s\n' "$line" >> "$d/.xprog"
}
xp_rule() {
  [ $# -ge 3 ] || fatal "xp_rule TAG REGEX SEND [MAX]"
  local m="${4:-1}"
  mt__is_int "$m" || fatal "xp_rule: MAX must be a number"
  mt__xp rule "$1" "$2" "$3" "$m" ""
}
xp_wait() { [ $# -ge 2 ] || fatal "xp_wait TAG REGEX [SECS]"; mt__xp wait "$1" "$2" "${3:-}"; }
xp_send() { mt__xp send "$1"; }
xp_sleep() { mt__is_int "$1" || fatal "xp_sleep MS"; mt__xp sleep "$1"; }
xp_resize() { mt__is_int "$1" && mt__is_int "$2" || fatal "xp_resize ROWS COLS"; mt__xp resize "$1" "$2"; }
xp_snap() { mt__xp snap "$1"; }
xp_mark() { mt__xp mark "$1"; }
xp_hold() { mt__is_int "$2" && mt__is_int "$3" || fatal "xp_hold KEYS COUNT GAPMS"; mt__xp hold "$1" "$2" "$3"; }
xp_quiet() { mt__is_int "$1" || fatal "xp_quiet MS [NAME]"; mt__xp quiet "$1" "${2:-}"; }
xp_eof() { mt__xp eof "${1:-}"; }
xp_host() { mt__xp host "$1"; }

# xrun [-t IDLE] [-T TOTAL] [-n NAME] [--rows R] [--cols C] [--watch] [--wrap-stty]
#      [--answer TAG=ANSWER]... [--rule TAG REGEX SEND [MAX]]... [--prog] [--env K=V]... [--bg]
#      -- CMD [ARGS...]
# CMD on a pty (TERM=xterm-256color). RC is the child's exit code (124 on the driver's own idle
# timeout), OUT the cleaned transcript, RAW the raw log, the status file beside them. A --rule MAX
# defaults to 1 (0 means unlimited). ANSWER: y, n, any word (typed, then Enter), keys with <name>,
# or manual (the program answers that prompt itself).
xrun() {
  local idle=120 total=600 name="" rows=24 cols=80 watch=0 wrap=0 bg=0 mt__xprog=0
  local mt__xr_tag=() mt__xr_re=() mt__xr_keys=() mt__xr_max=() mt__xa=() envs=() a d base
  while [ $# -gt 0 ]; do
    case "$1" in
      -t) idle="$2"; shift 2 ;;
      -T) total="$2"; shift 2 ;;
      -n) name="$2"; shift 2 ;;
      --rows) rows="$2"; shift 2 ;;
      --cols) cols="$2"; shift 2 ;;
      --watch) watch=1; shift ;;
      --wrap-stty) wrap=1; shift ;;
      --answer)
        case "$2" in *=?*) ;; *) fatal "xrun: --answer needs TAG=ANSWER, got $2" ;; esac
        mt__xa[${#mt__xa[@]}]="$2"; shift 2 ;;
      --rule)
        [ $# -ge 4 ] || fatal "xrun: --rule TAG REGEX SEND [MAX]"
        mt__tsv_ok "$2"; mt__tsv_ok "$3"; mt__tsv_ok "$4"
        mt__xr_tag[${#mt__xr_tag[@]}]="$2"; mt__xr_re[${#mt__xr_re[@]}]="$3"; mt__xr_keys[${#mt__xr_keys[@]}]="$4"
        shift 4
        if [ $# -gt 0 ] && mt__is_int "$1"; then mt__xr_max[${#mt__xr_max[@]}]="$1"; shift; else mt__xr_max[${#mt__xr_max[@]}]=1; fi ;;
      --prog) mt__xprog=1; shift ;;
      --env) envs[${#envs[@]}]="$2"; shift 2 ;;
      --bg) bg=1; shift ;;
      --) shift; break ;;
      *) fatal "xrun: unknown option '$1' (the command goes after --)" ;;
    esac
  done
  [ $# -gt 0 ] || fatal "xrun: no command after --"
  for a in idle total rows cols; do
    eval "mt__is_int \"\$$a\"" || fatal "xrun: $a must be a number"
  done
  for a in ${mt__xa[@]+"${mt__xa[@]}"}; do
    local t="${a%%=*}" known=0 r
    mt__cat_has "$t" && known=1
    for r in ${mt__xr_tag[@]+"${mt__xr_tag[@]}"}; do [ "$r" = "$t" ] && known=1; done
    [ "$known" = 1 ] || fatal "xrun: --answer names an unknown prompt tag: $t"
  done
  d=$(mt__xdir); mkdir -p "$d"
  mt__cmd_new "$d"; base="$MT__BASE"
  mt__write_rules "$base.prog"
  if [ "$mt__xprog" = 1 ]; then
    [ -f "$d/.xprog" ] || fatal "xrun --prog: no program (xp_new first)"
    grep -v '^rule	' "$d/.xprog" >> "$base.prog"
  fi
  local cmd=(env TERM=xterm-256color ${envs[@]+"${envs[@]}"})
  if [ "$wrap" = 1 ]; then
    cmd=("${cmd[@]}" "$MT_BASH" -c 'trap ":" INT; "$@"; r=$?; stty -a; printf "\n__MT_TTY_END__ rc=%s\n" "$r"; exit $r' _)
  fi
  cmd=("${cmd[@]}" "$@")
  printf '%s\n# name: %s\n# cwd: %s\n# pty: %sx%s, idle %s s, watchdog %s s\n# started: %s UTC\n' "$(mt__shjoin "$@")" "$name" "$PWD" "$rows" "$cols" "$idle" "$total" "$(utc_stamp)" > "$base.cmd"
  rm -f "$base.status" "$base.exit"
  : > "$base.raw"; : > "$base.err"
  RAW="$base.raw"; OUT="$base.out"; ERR="$base.err"; TIMEDOUT=0
  MT__XLAST="$base"
  if [ "${DRY:-0}" = 1 ]; then
    printf '  [dry] on a %sx%s pty: %s\n' "$rows" "$cols" "$(mt__shjoin "$@")"
    if [ "$mt__xprog" = 1 ]; then sed 's/^/      [dry] program: /' "$d/.xprog" | grep -v 'program: rule' ; fi
    : > "$base.out"; RC=0; printf 'rc=0\nend=eof\n' > "$base.status"
    [ "$bg" = 1 ] && XBG="$base"
    return 0
  fi
  printf '%s$ [pty %sx%s] %s%s\n' "$MT__C_DIM" "$rows" "$cols" "$(mt__shjoin "$@")" "$MT__C_RESET"
  mt__job_start "$base" "$total" /dev/null "$base.drv" - -- expect -f "$MT__DRIVER" run "$base.prog" "" "$base.raw" "$base.status" "$rows" "$cols" "$idle" "$watch" -- "${cmd[@]}"
  if [ "$bg" = 1 ]; then
    printf '%s %s %s %s\n' "$MT__JS_PID" "$MT__JS_WPID" "$total" "$idle" > "$base.bg"
    MT__BGPIDS="${MT__BGPIDS:-} $MT__JS_PID"
    XBG="$base"
    return 0
  fi
  mt__job_wait "$MT__JS_PID" "$MT__JS_WPID" "$base"
  mt__xrun_finish "$base" "$MT__JW_RC" "$MT__JW_TO" "$idle" "$total"
}
# xrun_join HANDLE [SECS]: waits for a --bg xrun (at most SECS, default its watchdog), then sets
# the usual results.
xrun_join() {
  local base="$1" secs="${2:-}" pid wpid total idle k=0
  [ -f "$base.bg" ] || { [ "${DRY:-0}" = 1 ] && { OUT="$base.out"; RC=0; return 0; }; fatal "xrun_join: no background run $base"; }
  read -r pid wpid total idle < "$base.bg"
  [ -n "$secs" ] || secs="$total"
  while kill -0 "$pid" 2>/dev/null && [ "$k" -lt "$secs" ]; do sleep 1; k=$((k + 1)); done
  if kill -0 "$pid" 2>/dev/null; then
    : > "$base.timedout"
    kill -TERM -"$pid" 2>/dev/null; sleep 2; kill -KILL -"$pid" 2>/dev/null
  fi
  mt__job_wait "$pid" "$wpid" "$base"
  MT__BGPIDS=$(printf '%s\n' ${MT__BGPIDS:-} | grep -v -x -e "$pid" | tr '\n' ' ')
  CMDREF="${base##*/}"
  mt__xrun_finish "$base" "$MT__JW_RC" "$MT__JW_TO" "$idle" "$total"
}
mt__xrun_finish() {
  local base="$1" jrc="$2" jto="$3" idle="$4" total="$5" end rc k v line
  RAW="$base.raw"; OUT="$base.out"; ERR="$base.err"; CMDREF="${base##*/}"; MT__XLAST="$base"
  mt_clean "$base.raw" "$base.out"
  [ -f "$base.drv" ] && mt_clean "$base.drv" "$base.err"
  end=$(mt__stat_get "$base.status" end)
  rc=$(mt__stat_get "$base.status" rc)
  TIMEDOUT=0
  if [ "$jto" = 1 ]; then
    TIMEDOUT=1; RC=124
  elif mt__is_int "$rc"; then
    RC="$rc"
  else
    RC="$jrc"
  fi
  [ "$end" = idle-timeout ] && { TIMEDOUT=1; RC=124; }
  printf '%s\n' "$RC" > "$base.rc"
  printf '# ended: %s UTC rc=%s end=%s\n' "$(utc_stamp)" "$RC" "${end:-none}" >> "$base.cmd"
  mt__job_exit_marker "$base"
  mt__show "$OUT"
  [ "$RC" = 0 ] || printf '    %s(rc %s, %s)%s\n' "$MT__C_DIM" "$RC" "${end:-no end recorded}" "$MT__C_RESET"
  case "$end" in
    eof|signal|quit) ;;
    idle-timeout) mt__check_add TIMEOUT "no output for $idle s on the pty: $(head -1 "$base.cmd")" "" "" "$CMDREF" ;;
    wait-timeout) check_note "the program's wait '$(mt__stat_get "$base.status" waitfail)' did not match in time" ;;
    eof-early) check_note "the command ended before the program's wait '$(mt__stat_get "$base.status" waitfail)' matched" ;;
    error) mt__check_add FAIL "the driver could start the command" "" "$(mt__stat_get "$base.status" error)" "$CMDREF" ;;
    "")
      if [ "$jto" = 1 ]; then
        mt__check_add TIMEOUT "command timed out after $total s: $(head -1 "$base.cmd")" "" "" "$CMDREF"
      else
        mt__check_add FAIL "the expect driver ran" "a status file" "$(mt__excerpt "$base.err" 300)" "$CMDREF"
      fi ;;
  esac
  [ "$jto" = 1 ] && [ -n "$end" ] && mt__check_add TIMEOUT "command timed out after $total s: $(head -1 "$base.cmd")" "" "" "$CMDREF"
  # Every docker gate held and every unnamed offer answered n is a NOTE with its line.
  if [ -f "$base.status" ]; then
    while IFS= read -r line; do
      k="${line%%=*}"; v="${line#*=}"
      case "$k" in
        firedline.docker-gate.*) check_note "Docker config gate held the launch (Enter sent): $v" ;;
        firedline.unnamed-Yn.*|firedline.unnamed-yN.*) check_note "an offer no step names was answered n: $v" ;;
      esac
    done < "$base.status"
  fi
  return 0
}
mt__stat_get() {
  # FILE KEY: the value of KEY= (empty when absent)
  [ -f "$1" ] || return 0
  LC_ALL=C awk -v k="$2" 'index($0, k "=") == 1 { v = substr($0, length(k) + 2); f = 1 } END { if (f) print v }' "$1"
}
mt__xstat() {
  [ -n "${MT__XLAST:-}" ] || return 0
  mt__stat_get "$MT__XLAST.status" "$1"
}
# xfired TAG: how many times rule TAG fired in the last xrun.
xfired() { local v; v=$(mt__xstat "fired.$1"); printf '%s\n' "${v:-0}"; }
# xwaited TAG: rc 0 when the sequential wait TAG matched.
xwaited() { [ -n "$(mt__xstat "wait.$1")" ]; }
# xstatus KEY: any key of the last xrun's status file (addition).
xstatus() { mt__xstat "$1"; }
# xquiet NAME: "BYTES MS" of the xp_quiet NAME (addition).
xquiet() { printf '%s %s\n' "$(mt__xstat "quiet.$1.bytes")" "$(mt__xstat "quiet.$1.ms")"; }
# xsnap NAME: points OUT at the snapshot NAME of the last xrun.
xsnap() {
  local p
  p=$(mt__xstat "snap.$1")
  CMDREF="${MT__XLAST##*/}"
  if [ -n "$p" ] && [ -f "$p" ]; then
    OUT="$p"
  else
    OUT="${MT__XLAST:-$RUN/main/none}.nosnap-$1.txt"
    : > "$OUT"
    [ "${DRY:-0}" = 1 ] || check_note "snapshot $1 was not taken"
  fi
}

# xshell PROJ [--as NAME] [--env K=V]... [--answer TAG=ANS]... -- [CMD...]
# cleat shell for PROJ on a pty: the first prompt (60 s), then each CMD with arithmetic markers,
# then exit. OUT is the whole session. xsh_out N and xsh_rc N read command N.
xshell() {
  local proj="$1" co=() ao=() i c here
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --as|--env|--bash|--xdg|--bin) co[${#co[@]}]="$1"; co[${#co[@]}]="$2"; shift 2 ;;
      --answer) ao[${#ao[@]}]="$1"; ao[${#ao[@]}]="$2"; shift 2 ;;
      --) shift; break ;;
      *) fatal "xshell: unknown option '$1'" ;;
    esac
  done
  mt__fence_proj "$proj"
  xp_new
  xp_wait container 'Container' 60
  xp_wait shell-prompt '[$#] ?(\x1b\[[0-9;?]*[a-zA-Z])*$' 60
  i=0
  for c in "$@"; do
    i=$((i + 1))
    mt__tsv_ok "$c"
    xp_send "printf '__MT_B_%d__\\n' \$((800+$i)); $c; printf '\\n__MT_%d_%d__\\n' \$((900+$i)) \$?<enter>"
    xp_wait "cmd-$i" "__MT_$((900 + i))_[0-9]+__" 180
  done
  xp_send "exit<enter>"
  xp_eof 30
  here="$PWD"
  if [ "${DRY:-0}" != 1 ] && [ ! -d "$P/$proj" ]; then fatal "xshell: no project directory $P/$proj"; fi
  cd "$P/$proj" 2>/dev/null || [ "${DRY:-0}" = 1 ] || fatal "xshell: cannot cd to $P/$proj"
  clt --prog -T 900 ${co[@]+"${co[@]}"} ${ao[@]+"${ao[@]}"} -- shell
  cd "$here" || true
  MT__XSH_OUT="$OUT"
  MT__XSH_REF="$CMDREF"
  return 0
}
# xsh_out N: points OUT at command N's own output (between its markers).
xsh_out() {
  local n="$1" src="${MT__XSH_OUT:-}"
  mt__is_int "$n" || fatal "xsh_out N"
  mt__derived "command $n of the shell" "${src:-none}"
  if [ -n "$src" ] && [ -f "$src" ]; then
    awk -v b="__MT_B_$((800 + n))__" -v e="__MT_$((900 + n))_" '
      index($0, e) == 1 { on = 0 }
      on { line[++k] = $0 }
      $0 == b { on = 1; k = 0 }
      END { if (k > 0 && line[k] == "") k--; for (i = 1; i <= k; i++) print line[i] }' "$src" > "$OUT"
  else
    : > "$OUT"
  fi
}
# xsh_rc N: command N's exit code (empty when its marker never came).
xsh_rc() {
  local n="$1"
  [ -n "${MT__XSH_OUT:-}" ] && [ -f "$MT__XSH_OUT" ] || return 0
  LC_ALL=C sed -n "s/^__MT_$((900 + n))_\\([0-9][0-9]*\\)__.*/\\1/p" "$MT__XSH_OUT" | head -1
}

# ---------------------------------------------------------------------------------------------
# Human interaction: ask, ask_record, say_do, wait_for, choose, read_line, MT_ANSWERS
# ---------------------------------------------------------------------------------------------

MT__ANS_GLOB=(); MT__ANS_VAL=(); MT__ANS_NOTE=(); MT__ANS_LINE=()
# mt__answers_load: MT_ANSWERS is read once per invocation. Lines: GLOB ANSWER [NOTE], # comments.
mt__answers_load() {
  MT__ANS_GLOB=(); MT__ANS_VAL=(); MT__ANS_NOTE=(); MT__ANS_LINE=()
  [ -n "${MT_ANSWERS:-}" ] || return 0
  [ -r "$MT_ANSWERS" ] || fatal "MT_ANSWERS names a file that cannot be read: $MT_ANSWERS"
  local line n=0 g a rest
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    line="${line%$'\r'}"
    line="${line#"${line%%[![:space:]]*}"}"
    case "$line" in ''|'#'*) continue ;; esac
    g=""; a=""; rest=""
    read -r g a rest <<MT__ANS_EOF
$line
MT__ANS_EOF
    [ -n "$a" ] || fatal "MT_ANSWERS line $n has no answer: $line"
    MT__ANS_GLOB[${#MT__ANS_GLOB[@]}]="$g"
    MT__ANS_VAL[${#MT__ANS_VAL[@]}]="$a"
    MT__ANS_NOTE[${#MT__ANS_NOTE[@]}]="$rest"
    MT__ANS_LINE[${#MT__ANS_LINE[@]}]="$n"
  done < "$MT_ANSWERS"
}
# mt__answer_for KEY: MT__A_VAL, MT__A_NOTE, MT__A_SRC (the line that gave it, or default).
mt__answer_for() {
  local key="$1" i=0 g
  while [ "$i" -lt "${#MT__ANS_GLOB[@]}" ]; do
    g="${MT__ANS_GLOB[$i]}"
    # shellcheck disable=SC2254
    case "$key" in
      $g)
        MT__A_VAL="${MT__ANS_VAL[$i]}"; MT__A_NOTE="${MT__ANS_NOTE[$i]}"
        MT__A_SRC="MT_ANSWERS line ${MT__ANS_LINE[$i]} ($g)"
        return 0 ;;
    esac
    i=$((i + 1))
  done
  MT__A_VAL="$MT_ANSWERS_DEFAULT"; MT__A_NOTE=""; MT__A_SRC="MT_ANSWERS_DEFAULT"
  return 1
}
mt__ask_key() { printf '%s:%s' "${STEP_ID:-${MT__ASK_ID:-run}}" "$1"; }
mt__bell() {
  [ -n "${MT_ANSWERS:-}" ] && return 0
  { printf '\a' > /dev/tty; } 2>/dev/null || true
}
mt__tty_line() {
  # VAR: one line from /dev/tty. A missing terminal is fatal (MT_ANSWERS is the way to run unattended).
  local mt__tl=""
  if ! { IFS= read -r mt__tl < /dev/tty; } 2>/dev/null; then
    fatal "this prompt needs a terminal: run it in Terminal.app, or set MT_ANSWERS for an unattended run"
  fi
  printf -v "$1" '%s' "$mt__tl"
}
mt__lines() {
  # TEXT: each line indented
  local l
  while IFS= read -r l; do printf '    %s\n' "$l"; done <<MT__L_EOF
$1
MT__L_EOF
}
mt__prompt_head() {
  local t="${STEP_TITLE:-}"
  printf '\n%s---- [%s]%s ----%s\n' "$MT__C_BOLD" "${STEP_ID:-${MT__ASK_ID:-run}}" "${t:+ $t}" "$MT__C_RESET"
}
mt__asking_on() { [ -n "${STEP_DIR:-}" ] && [ -d "$STEP_DIR" ] && : > "$STEP_DIR/.asking"; return 0; }
mt__asking_off() { [ -n "${STEP_DIR:-}" ] && rm -f "$STEP_DIR/.asking"; return 0; }
mt__r_used() {
  # KEY: rc 0 when an r from MT_ANSWERS was already honoured for this prompt in this attempt
  local f="${STEP_DIR:-${MT__CMDDIR:-$RUN/main}}/.rused"
  [ -f "$f" ] && grep -q -x -F -e "$1" "$f"
}
mt__r_mark() {
  local f="${STEP_DIR:-${MT__CMDDIR:-$RUN/main}}/.rused"
  printf '%s\n' "$1" >> "$f"
}
mt__quit() {
  # TAG: q at a prompt saves and quits (the step ends INTERRUPTED)
  if [ "${MT__IN_CLEANUP:-0}" = 1 ]; then return 2; fi
  printf '\nSaved. The step ends here and resumes from its start with --resume.\n'
  mt__exit_with 10 "quit at $1"
}

# ask TAG TERMINAL "WHAT TO DO" "WHAT YOU SHOULD SEE" ["QUESTION"]: rc 0 y, 1 n, 2 s, 5 r.
ask() {
  mt__ask_core ask "$1" "$2" "$3" "${4:-}" "${5:-Did it go as described?}"
}
# ask_record TAG TERMINAL "WHAT TO DO" "QUESTION": as ask, but n records a NOTE, never a FAIL.
ask_record() {
  mt__ask_core record "$1" "$2" "$3" "" "${4:-What happened?}"
}
mt__ask_core() {
  local kind="$1" tag="$2" term="$3" what="$4" see="$5" q="$6" key ans note
  key=$(mt__ask_key "$tag")
  if { [ "$term" = T1 ] || [ "$term" = T3 ]; } && t_is_auto; then
    mt__check_add HUMAN-SKIP "[$tag] $q" "" "T1 simulated: no Claude conversation" ""
    return 2
  fi
  while :; do
    mt__prompt_head
    [ -n "$term" ] && printf 'Where: %s\n' "$term"
    if [ -n "$what" ]; then printf 'Do:\n'; mt__lines "$what"; fi
    if [ -n "$see" ]; then printf 'You should see:\n'; mt__lines "$see"; fi
    printf '%s%s%s\n' "$MT__C_BOLD" "$q" "$MT__C_RESET"
    printf 'y = as described, n = not as described, s = skip, r = repeat, q = save and quit\n'
    if [ "${DRY:-0}" = 1 ]; then
      printf '> y   [dry] answered y\n'
      ans=y
    elif [ -n "${MT_ANSWERS:-}" ]; then
      mt__answer_for "$key"
      ans="$MT__A_VAL"
      case "$ans" in r|R) if mt__r_used "$key"; then ans=s; else mt__r_mark "$key"; fi ;; esac
      printf '> %s   (from %s)\n' "$ans" "$MT__A_SRC"
    else
      mt__bell
      case "$term" in T1|T3) t_front t2 ;; esac
      mt__asking_on
      printf '> '
      mt__tty_line ans
      mt__asking_off
    fi
    local mt__src=""
    [ -n "${MT_ANSWERS:-}" ] && [ "${DRY:-0}" != 1 ] && mt__src=" ($MT__A_SRC)"
    case "$ans" in
      y|Y|yes|YES|Yes)
        if [ "$kind" = ask ]; then mt__check_add HUMAN-PASS "[$tag] $q" "$see" "yes$mt__src" ""; else mt__check_add HUMAN-PASS "[$tag] $q" "" "yes$mt__src" ""; fi
        return 0 ;;
      n|N|no|NO|No)
        note=""
        if [ "${DRY:-0}" = 1 ]; then note=dry
        elif [ -n "${MT_ANSWERS:-}" ]; then note="${MT__A_NOTE:-scripted no}"
        else
          printf 'What was different? (one line)\n> '
          mt__asking_on; mt__tty_line note; mt__asking_off
        fi
        if [ "$kind" = ask ]; then
          mt__check_add HUMAN-FAIL "[$tag] $q" "$see" "no: $note$mt__src" ""
        else
          mt__check_add NOTE "[$tag] $q: no. $note$mt__src" "" "" ""
        fi
        return 1 ;;
      s|S|skip)
        mt__check_add HUMAN-SKIP "[$tag] $q" "" "skipped at the prompt$mt__src" ""
        return 2 ;;
      r|R) return 5 ;;
      q|Q)
        mt__quit "$tag"
        mt__check_add HUMAN-SKIP "[$tag] $q" "" "q during a cleanup counts as skip" ""
        return 2 ;;
      *) printf 'Answer y, n, s, r or q.\n'
         [ -n "${MT_ANSWERS:-}" ] && { mt__check_add HUMAN-SKIP "[$tag] $q" "" "MT_ANSWERS gave '$ans'" ""; return 2; } ;;
    esac
  done
}
# say_do TERMINAL "WHAT TO DO": an instruction, no question.
say_do() {
  mt__prompt_head
  printf 'Where: %s\n' "$1"
  printf 'Do:\n'
  mt__lines "$2"
  case "$1" in T1) t_front t1 ;; T3) t_front t3 ;; esac
  return 0
}
# wait_for TAG "WHAT TO DO" [--timeout S] [--every S] [--auto] -- COND [ARGS...]
# rc 0 met (or d: the human said done), 2 skipped, 3 timed out. q saves and quits.
# --auto (addition): a machine wait no human acts in: MT_ANSWERS is not consulted (it polls to the
# timeout). The keys still work at a terminal.
wait_for() {
  local tag="$1" what="$2" to="" every=2 key start now k ch r mt__wcond auto=0
  shift 2
  while [ $# -gt 0 ]; do
    case "$1" in
      --auto) auto=1; shift ;;
      --timeout) to="$2"; shift 2 ;;
      --every) every="$2"; shift 2 ;;
      --) shift; break ;;
      *) fatal "wait_for: unknown option '$1' (the condition goes after --)" ;;
    esac
  done
  [ $# -gt 0 ] || fatal "wait_for: no condition after --"
  mt__is_int "$every" && [ "$every" -ge 1 ] || every=2
  key=$(mt__ask_key "$tag")
  mt__wcond=$(mt__shjoin "$@")
  mt__prompt_head
  printf 'Waiting for: %s\n' "$mt__wcond"
  [ -n "$what" ] && { printf 'Do:\n'; mt__lines "$what"; }
  if [ "${DRY:-0}" = 1 ]; then printf '[dry] the wait counts as met\n'; return 0; fi
  if [ -n "${MT_ANSWERS:-}" ] && [ "$auto" = 1 ]; then
    [ -n "$to" ] || to=300
  elif [ -n "${MT_ANSWERS:-}" ]; then
    mt__answer_for "$key"
    printf '(answer %s from %s)\n' "$MT__A_VAL" "$MT__A_SRC"
    case "$MT__A_VAL" in
      s|S|n|N) mt__check_add HUMAN-SKIP "[$tag] wait: $mt__wcond" "" "skipped from MT_ANSWERS" ""; return 2 ;;
      q|Q) mt__quit "$tag"; return 2 ;;
      d|D) mt__check_add NOTE "[$tag] wait: the answers file said done" "" "" ""; return 0 ;;
    esac
    [ -n "$to" ] || to=300
  else
    printf 'Keys here: d = done, s = skip, q = save and quit, ? = show this again\n'
  fi
  start=$(epoch_now)
  while :; do
    if mt__probe 60 "$@"; then return 0; fi
    now=$(epoch_now)
    if [ -n "$to" ] && [ $((now - start)) -ge "$to" ]; then
      mt__check_add NOTE "[$tag] wait timed out after $to s: $mt__wcond" "" "" ""
      return 3
    fi
    if [ -n "${MT_ANSWERS:-}" ]; then
      sleep "$every"
      continue
    fi
    k=0
    while [ "$k" -lt "$every" ]; do
      ch=""
      mt__asking_on
      { IFS= read -r -s -n 1 -t 1 ch < /dev/tty; } 2>/dev/null
      r=$?
      mt__asking_off
      if [ "$r" -ne 0 ] && [ "$r" -le 128 ] && [ -z "$ch" ]; then sleep 1; fi
      case "$ch" in
        d|D) mt__check_add NOTE "[$tag] the human said done" "" "" ""; return 0 ;;
        s|S) mt__check_add HUMAN-SKIP "[$tag] wait: $mt__wcond" "" "skipped at the prompt" ""; return 2 ;;
        q|Q) mt__quit "$tag"; return 2 ;;
        '?') printf 'Waiting for: %s\n' "$mt__wcond"; [ -n "$what" ] && mt__lines "$what"
             printf 'Keys here: d = done, s = skip, q = save and quit\n' ;;
      esac
      k=$((k + 1))
    done
  done
}
# choose [--default KEY] TAG "QUESTION" OPTION...: sets CHOICE. An option is KEY or KEY=description.
# The first is the default for an MT_ANSWERS answer that names none of them. --default KEY: an
# empty line at the terminal (Enter) takes KEY. Without it Enter asks again.
choose() {
  local def=""
  if [ "${1:-}" = --default ]; then def="$2"; shift 2; fi
  local tag="$1" q="$2" key o k ans
  shift 2
  [ $# -gt 0 ] || fatal "choose: no options"
  key=$(mt__ask_key "$tag")
  while :; do
    mt__prompt_head
    printf '%s%s%s\n' "$MT__C_BOLD" "$q" "$MT__C_RESET"
    for o in "$@"; do
      case "$o" in *=*) printf '  %s = %s\n' "${o%%=*}" "${o#*=}" ;; *) printf '  %s\n' "$o" ;; esac
    done
    [ -z "$def" ] || printf '  (Enter = %s)\n' "$def"
    if [ "${DRY:-0}" = 1 ]; then
      ans="${1%%=*}"; printf '> %s   [dry] the first option\n' "$ans"
    elif [ -n "${MT_ANSWERS:-}" ]; then
      mt__answer_for "$key"
      ans="$MT__A_VAL"
      case "$ans" in r|R) if mt__r_used "$key"; then ans=s; else mt__r_mark "$key"; fi ;; esac
      printf '> %s   (from %s)\n' "$ans" "$MT__A_SRC"
    else
      mt__bell
      mt__asking_on
      printf '> '
      mt__tty_line ans
      mt__asking_off
      [ -n "$ans" ] || ans="$def"
    fi
    for o in "$@"; do
      k="${o%%=*}"
      if [ "$ans" = "$k" ] || [ "$(printf '%s' "$ans" | tr 'A-Z' 'a-z')" = "$(printf '%s' "$k" | tr 'A-Z' 'a-z')" ]; then
        CHOICE="$k"
        [ -n "${STEP_DIR:-}" ] && mt__check_write NOTE "[$tag] chose $k" "" "" ""
        return 0
      fi
    done
    if [ "${DRY:-0}" = 1 ] || [ -n "${MT_ANSWERS:-}" ]; then
      CHOICE="${1%%=*}"
      # a first option r (run it again) taken by default holds once per prompt, like a scripted r:
      # a step that crashes the same way every time must not loop for ever
      if [ "${DRY:-0}" != 1 ]; then
        case "$CHOICE" in r|R) if mt__r_used "$key"; then [ $# -ge 2 ] && CHOICE="${2%%=*}"; else mt__r_mark "$key"; fi ;; esac
      fi
      printf '(%s is not an option here: %s)\n' "$ans" "$CHOICE"
      [ -n "${STEP_DIR:-}" ] && mt__check_write NOTE "[$tag] the answer $ans is not an option, took $CHOICE" "" "" ""
      return 0
    fi
    printf 'Type one of the options.\n'
  done
}
# read_line TAG "PROMPT" VAR: one line of free text into VAR.
read_line() {
  local tag="$1" q="$2" mt__rlv="$3" key mt__rl=""
  case "$mt__rlv" in ''|[0-9]*|*[!A-Za-z0-9_]*) fatal "read_line: bad variable name '$mt__rlv'" ;; esac
  key=$(mt__ask_key "$tag")
  mt__prompt_head
  printf '%s%s%s\n' "$MT__C_BOLD" "$q" "$MT__C_RESET"
  if [ "${DRY:-0}" = 1 ]; then
    mt__rl=dry; printf '> dry\n'
  elif [ -n "${MT_ANSWERS:-}" ]; then
    mt__answer_for "$key"
    case "$MT__A_VAL" in q|Q) mt__quit "$tag" ;; esac
    mt__rl="$MT__A_NOTE"
    printf '> %s   (from %s)\n' "$mt__rl" "$MT__A_SRC"
  else
    printf '(one line. A q alone saves and quits)\n'
    mt__bell
    mt__asking_on
    printf '> '
    mt__tty_line mt__rl
    mt__asking_off
    # every other prompt reads q as save and quit: a free-text one does the same
    case "$mt__rl" in q|Q) mt__quit "$tag" ;; esac
  fi
  printf -v "$mt__rlv" '%s' "$mt__rl"
  return 0
}

# ---------------------------------------------------------------------------------------------
# Terminals T1 and T3 (the script runs in T2). Modes: auto (MT_T1_AUTO=1, a background expect
# driver), typed (Terminal.app driven with osascript), human (the human types, the script asks).
# ---------------------------------------------------------------------------------------------

MT__TMODE=""
# t_mode: the mode of this invocation (addition). Any osascript failure drops typed to human.
t_mode() {
  local m inv
  if [ -n "${MT__TMODE:-}" ]; then printf '%s\n' "$MT__TMODE"; return 0; fi
  m=$(kv_get t.mode "")
  inv=$(kv_get t.mode.inv "")
  if [ -z "$m" ] || [ "$inv" != "${INV:-0}" ]; then
    if [ "${MT_T1_AUTO:-}" = 1 ]; then
      m=auto
    elif [ "${IS_MACOS:-0}" = 1 ] && host_can && [ "${MT_T1_TYPE:-1}" != 0 ]; then
      if [ "${DRY:-0}" = 1 ] || mt__osa_probe; then m=typed; else m=human; fi
    else
      m=human
    fi
    kv_set t.mode "$m"
    kv_set t.mode.inv "${INV:-0}"
  fi
  MT__TMODE="$m"
  printf '%s\n' "$m"
}
# t_is_auto: rc 0 in T1 auto mode (addition).
t_is_auto() { [ "$(t_mode)" = auto ]; }
t_have_capture() {
  case "$(t_mode)" in auto|typed) return 0 ;; esac
  return 1
}
mt__t_norm() {
  case "$1" in t1|T1) printf 't1' ;; t2|T2) printf 't2' ;; t3|T3) printf 't3' ;; *) fatal "terminal must be t1, t2 or t3, got $1" ;; esac
}
mt__t_upper() { printf '%s' "$1" | tr 'a-z' 'A-Z'; }
mt__osa_str() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }
mt__t_drop() {
  # REASON: typed mode fails over to human for the rest of the invocation
  kv_set t.mode human
  kv_set t.mode.inv "${INV:-0}"
  kv_set t.drop "$1"
  MT__TMODE=human
  printf '%s! T1 typing stops for this run of the script: %s. You type in T1 from now on.%s\n' "$MT__C_AMBER" "$1" "$MT__C_RESET"
  [ -n "${STEP_DIR:-}" ] && mt__check_write NOTE "T1 typing dropped to human: $1" "" "" ""
  return 0
}
mt__osa_probe() {
  mt__probe 20 osascript -e '-- mt:probe' -e 'tell application "Terminal" to count windows'
}
# mt__osa NAME SCRIPT: osascript under a 20 s watchdog. Output in MT__OSA_OUT. A failure drops
# typed mode to human and returns 1.
mt__osa() {
  local name="$1" script="$2" err
  MT__OSA_OUT=""
  if [ "${DRY:-0}" = 1 ]; then printf '  [dry] osascript (%s)\n' "$name"; return 0; fi
  if mt__probe 20 osascript -e "-- mt:$name" -e "$script"; then
    MT__OSA_OUT=$(cat "$MT__PROBE_OUT" 2>/dev/null)
    return 0
  fi
  err=$(head -2 "${MT__PROBE_OUT%.out}.err" 2>/dev/null | tr '\n' ' ')
  err="${err% }"
  case "$err" in *-1743*) err="not allowed to control Terminal (System Settings, Privacy and Security, Automation): $err" ;; esac
  mt__t_drop "osascript $name failed: ${err:-no message}"
  return 1
}
# T1 and T3 are found by the tty of their tab, never by a window id or a tab index. A closed
# window's id and a tab's place go to other windows and tabs (a Terminal relaunch, a resume the
# next day, a tab he opened himself). A command typed there would run in whatever shell holds
# them: his login zsh, where cleat is his installed release on his real config. kv T.tty is the
# tab's tty, T.plist the sorted process names of that tab at the env-file bash prompt and T.base
# their count. Before a line is typed the tab must show exactly T.plist (mt__t_state). Each typed
# line also carries a guard that runs it only in a bash with the env file sourced (mt__t_typed_run).
mt__t_tty() { kv_get "$1.tty" ""; }
mt__t_tty_ok() {
  case "$1" in /dev/*[!A-Za-z0-9/._-]*|/dev/) return 1 ;; /dev/?*) return 0 ;; esac
  return 1
}
# mt__t_tabscript TTY BODY: AppleScript that finds the Terminal tab whose tty is TTY and runs BODY
# on it, with mtTab the tab and mtWid the id of its window. It returns MT-NO-TAB when no tab has it.
mt__t_tabscript() {
  printf '%s\n' 'tell application "Terminal"' \
    '	set mtWid to missing value' \
    '	set mtTi to 0' \
    '	repeat with mtW in windows' \
    '		try' \
    '			repeat with mtI from 1 to (count of tabs of mtW)' \
    "				if (tty of tab mtI of mtW) is \"$1\" then" \
    '					set mtWid to id of mtW' \
    '					set mtTi to mtI' \
    '				end if' \
    '			end repeat' \
    '		end try' \
    '	end repeat' \
    '	if mtWid is missing value then return "MT-NO-TAB"' \
    '	set mtTab to tab mtTi of window id mtWid' \
    "$2" \
    'end tell'
}
# mt__t_osa T NAME BODY: mt__osa on T's own tab. MT__OSA_OUT is MT-NO-TAB when T has no tab now
# (rc 0). rc 1 only when osascript itself failed, which drops typed mode to human.
mt__t_osa() {
  local tty
  tty=$(mt__t_tty "$1")
  if ! mt__t_tty_ok "$tty"; then MT__OSA_OUT="MT-NO-TAB"; return 0; fi
  mt__osa "$2" "$(mt__t_tabscript "$tty" "$3")"
}
# mt__t_plist_norm TEXT: osascript's "login, -zsh, bash" as sorted names on one line. Sorted, so
# the order Terminal lists them in never matters.
mt__t_plist_norm() {
  printf '%s\n' "$1" | tr ',' '\n' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | grep -v '^$' | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//'
}
mt__t_procs() {
  # T: the process names of T's tab (MT__T_PLIST, MT-NO-TAB when it has none) and their number
  # (MT__T_PROCS). rc 1 when they cannot be read.
  MT__T_PROCS=""; MT__T_PLIST=""
  mt__t_osa "$1" "procs-$1" '	return processes of mtTab' || return 1
  if [ "$MT__OSA_OUT" = MT-NO-TAB ]; then MT__T_PLIST=MT-NO-TAB; return 1; fi
  MT__T_PLIST=$(mt__t_plist_norm "$MT__OSA_OUT")
  MT__T_PROCS=$(printf '%s\n' "$MT__T_PLIST" | awk '{ print NF }')
  mt__is_int "$MT__T_PROCS" && [ "$MT__T_PROCS" -gt 0 ]
}
# mt__t_state T: MT__T_STATE is prompt (the tab shows exactly T.plist: the env-file bash at its
# prompt), busy (more processes: a command runs there), lost (no such tab, fewer or other
# processes, or the tab is T2's own) or error (osascript failed: typed mode is human now).
mt__t_state() {
  local base blist
  MT__T_STATE=error
  if [ -n "${MT__T2TTY:-}" ] && [ "$(mt__t_tty "$1")" = "$MT__T2TTY" ]; then
    MT__T_STATE=lost; MT__T_PLIST="the tab of T2, where this script runs"; return 0
  fi
  if ! mt__t_procs "$1"; then
    [ "$(t_mode)" = typed ] || return 0
    MT__T_STATE=lost; return 0
  fi
  blist=$(kv_get "$1.plist" "")
  base=$(kv_get "$1.base" "")
  if [ -z "$blist" ] || ! mt__is_int "$base"; then MT__T_STATE=lost
  elif [ "$MT__T_PLIST" = "$blist" ]; then MT__T_STATE=prompt
  elif [ "$MT__T_PROCS" -gt "$base" ]; then MT__T_STATE=busy
  else MT__T_STATE=lost; fi
  return 0
}
# mt__t_my_tty: the tty of the terminal this script runs in (T2), empty when there is none.
mt__t_my_tty() {
  local t
  t=$(tty 2>/dev/null) || t=""
  case "$t" in /dev/tty|/dev/console) t="" ;; esac
  if ! mt__t_tty_ok "$t"; then
    t=$(ps -o tty= -p "$$" 2>/dev/null | tr -d ' ')
    case "$t" in *[!A-Za-z0-9/._-]*) t="" ;; tty?*|pts/?*) t="/dev/$t" ;; *) t="" ;; esac
  fi
  mt__t_tty_ok "$t" && printf '%s\n' "$t"
  return 0
}

# t_ensure T: T exists and sits at a bash prompt with the env file sourced.
t_ensure() {
  local t m T
  t=$(mt__t_norm "$1"); T=$(mt__t_upper "$t")
  m=$(t_mode)
  case "$m" in
    auto) return 0 ;;
    typed) mt__t_typed_ensure "$t" && return 0 ;;
  esac
  [ "$(kv_get "$t.ready.inv" "")" = "${INV:-0}" ] && return 0
  ask "$t-open" "$T" "Open a new Terminal.app window (default profile, 80x24) for $T. Type /bin/bash on its own line and press Enter.
Then, on a line of its own (never pasted together with the first):
source ~/mt-eg-env.sh
type cleat | head -1" "cleat is a function. No NOT BASH 3.2 line." "Is $T at a bash prompt with the env file sourced?"
  kv_set "$t.ready.inv" "${INV:-0}"
  return 0
}
# mt__t_open_fail T REASON: a new window of T did not become the env-file bash. Typed mode stops.
mt__t_open_fail() {
  kv_del "$1.plist"
  mt__t_drop "$2"
  return 1
}
mt__t_typed_ensure() {
  local t="$1" T tty k hist n prev="" bname
  T=$(mt__t_upper "$t")
  # dry run: a window that opened (a Mac dry run walks typed mode, it never drops to human here)
  if [ "${DRY:-0}" = 1 ]; then
    printf '  [dry] open %s in Terminal.app (80x24), /bin/bash, source the env file\n' "$T"
    kv_set "$t.tty" /dev/ttys-dry; kv_set "$t.plist" "-zsh bash login"; kv_set "$t.base" 3
    return 0
  fi
  if [ -n "$(mt__t_tty "$t")" ]; then
    mt__t_state "$t"
    case "$MT__T_STATE" in
      prompt|busy) return 0 ;;
      error) return 1 ;;
    esac
    # lost: never typed into again. A new window opens (three times at most in one invocation).
    n=0
    [ "$(kv_get "$t.reopen.inv" "")" = "${INV:-0}" ] && n=$(kv_get "$t.reopen.n" 0)
    mt__is_int "$n" || n=0
    n=$((n + 1))
    kv_set "$t.reopen.inv" "${INV:-0}"; kv_set "$t.reopen.n" "$n"
    if [ "$n" -gt 3 ]; then
      mt__t_drop "$T had to be opened again three times in this run of the script"
      return 1
    fi
    k="The old one is never typed into again: close it."
    case "${MT__T_PLIST:-}" in
      ''|MT-NO-TAB) MT__T_PLIST="its window is gone"; k="" ;;
      "the tab of T2, where this script runs") k="" ;;
      *) MT__T_PLIST="its processes now: $MT__T_PLIST" ;;
    esac
    printf '%s! %s is no longer the bash this script opened (%s). A new %s window opens.%s%s\n' \
      "$MT__C_AMBER" "$T" "$MT__T_PLIST" "$T" "${k:+ $k}" "$MT__C_RESET"
    [ -n "${STEP_DIR:-}" ] && mt__check_write NOTE "$T was lost ($MT__T_PLIST): a new window opened" "" "" ""
  fi
  kv_del "$t.plist"; kv_del "$t.base"
  mt__osa "new-$t" "tell application \"Terminal\"
	set mtNew to do script \"$(mt__osa_str "$MT_BASH")\"
	delay 1
	return tty of mtNew
end tell" || return 1
  tty="$MT__OSA_OUT"
  mt__t_tty_ok "$tty" || { mt__t_open_fail "$t" "Terminal returned no tty for the new $T window: ${tty:-nothing}"; return 1; }
  if [ -n "${MT__T2TTY:-}" ] && [ "$tty" = "$MT__T2TTY" ]; then mt__t_open_fail "$t" "the new $T window reported the tty of T2 ($tty)"; return 1; fi
  kv_set "$t.tty" "$tty"
  # Wait for the bash it started before typing the source line (never into the login shell).
  bname="${MT_BASH##*/}"
  k=0
  while :; do
    sleep 1
    mt__t_procs "$t"
    [ "$(t_mode)" = typed ] || return 1
    case " $MT__T_PLIST " in *" $bname "*) break ;; esac
    k=$((k + 1))
    [ "$k" -lt 15 ] || { mt__t_open_fail "$t" "the new $T window never started $MT_BASH (${MT__T_PLIST:-no process list})"; return 1; }
  done
  mt__t_osa "$t" "source-$t" "	do script \"source $(mt__osa_str "$ENVF")\" in mtTab
	return \"ok\"" || return 1
  [ "$MT__OSA_OUT" != MT-NO-TAB ] || { mt__t_open_fail "$t" "the new $T window closed while it opened"; return 1; }
  sleep 1
  mt__t_osa "$t" "typecheck-$t" '	do script "type cleat | head -1" in mtTab
	return "ok"' || return 1
  mt__t_osa "$t" "size-$t" "	set number of rows of mtTab to 24
	set number of columns of mtTab to 80
	set custom title of mtTab to \"$T egress test\"
	return \"ok\"" || return 1
  k=0
  hist=""
  while [ "$k" -lt 15 ]; do
    sleep 1
    mt__t_osa "$t" "history-$t" '	return history of mtTab' || return 1
    hist="$MT__OSA_OUT"
    case "$hist" in *"cleat is a function"*) break ;; esac
    k=$((k + 1))
  done
  case "$hist" in
    *"NOT BASH 3.2"*) mt__t_open_fail "$t" "$T reported NOT BASH 3.2"; return 1 ;;
    *"cleat is a function"*) ;;
    *) mt__t_open_fail "$t" "$T never printed: cleat is a function"; return 1 ;;
  esac
  # The processes at the prompt: the same sorted list read twice in a row, a second apart, with
  # the bash in it. That list is what "at its prompt" means from now on.
  k=0
  while [ "$k" -lt 10 ]; do
    sleep 1
    mt__t_procs "$t"
    [ "$(t_mode)" = typed ] || return 1
    case " $MT__T_PLIST " in
      *" $bname "*) [ -n "$prev" ] && [ "$MT__T_PLIST" = "$prev" ] && break ;;
    esac
    prev="$MT__T_PLIST"
    k=$((k + 1))
  done
  [ "$k" -lt 10 ] || { mt__t_open_fail "$t" "$T's processes never settled at its prompt (${MT__T_PLIST:-none})"; return 1; }
  kv_set "$t.plist" "$MT__T_PLIST"
  kv_set "$t.base" "$MT__T_PROCS"
  t_front t2
  return 0
}
# t_front T: typed mode brings T's window to the front. T2 is the tab of this script's own tty.
# A raise that fails changes nothing else: typed mode stays on.
t_front() {
  local t tty
  [ "$(t_mode)" = typed ] || return 0
  [ "${DRY:-0}" = 1 ] && return 0
  t=$(mt__t_norm "$1")
  if [ "$t" = t2 ]; then tty="${MT__T2TTY:-}"; else tty=$(mt__t_tty "$t"); fi
  mt__t_tty_ok "$tty" || return 0
  mt__probe 20 osascript -e "-- mt:front-$t" -e "$(mt__t_tabscript "$tty" '	set index of window id mtWid to 1
	try
		set selected of mtTab to true
	end try
	activate
	return "ok"')" || true
  return 0
}
mt__t_answer_text() {
  # TAG: the prompt in words, from the catalogue regex
  mt__catalogue | awk -F'\t' -v t="$1" '$1 == t { print $2 }' | sed -e 's/\\S+/<box>/g' -e 's/(\\x1b[^)]*)?//g' -e 's/\\//g' -e 's/ ?\$$//'
}
mt__t_cmd_guard() {
  # the verb guard over a typed command line (a leading cleat function name is skipped)
  local IFS=' '
  set -f
  # shellcheck disable=SC2086
  set -- $1
  set +f
  case "${1:-}" in cleat|cleatu|cleatup|cleat154|cleatnogw) shift ;; esac
  mt__cleat_verb_guard "$@"
}
# t_run T PROJ "COMMAND" [--answer TAG=ANS]...: COMMAND in T from $P/PROJ (no cd when PROJ is empty).
t_run() {
  local t T proj="$2" cmd="$3" m line n a ans
  local answers=()
  t=$(mt__t_norm "$1"); T=$(mt__t_upper "$t")
  shift 3
  while [ $# -gt 0 ]; do
    case "$1" in
      --answer) answers[${#answers[@]}]="$2"; shift 2 ;;
      *) fatal "t_run: unknown option '$1'" ;;
    esac
  done
  [ -z "$proj" ] || mt__fence_proj "$proj"
  mt__t_cmd_guard "$cmd"
  # T1 and T3 run every command with the env file sourced (cleat is its function). 3.5 deletes it.
  if [ "${DRY:-0}" != 1 ] && [ ! -f "$ENVF" ]; then
    step_abort "the env file ~/mt-eg-env.sh is gone (3.5 deletes it): run ./egress-release.sh --only 0.2, then this step again"
  fi
  t_ensure "$t"
  m=$(t_mode)
  n=$(kv_get "$t.runs" 0); mt__is_int "$n" || n=0
  n=$((n + 1))
  kv_set "$t.runs" "$n"
  kv_set "$t.proj" "$proj"
  if [ -n "$proj" ]; then line="cd \"$P/$proj\" && $cmd"; else line="$cmd"; fi
  case "$m" in
    auto) mt__t_auto_start "$t" "$n" "$proj" "$cmd" ${answers[@]+"${answers[@]}"}; return 0 ;;
    typed)
      if mt__t_typed_run "$t" "$n" "$proj" "$line" ${answers[@]+"${answers[@]}"}; then return 0; fi ;;
  esac
  # human (or typed just dropped)
  local extra=""
  for a in ${answers[@]+"${answers[@]}"}; do
    ans="${a#*=}"
    extra="${extra}When it asks: $(mt__t_answer_text "${a%%=*}"), type $ans and press Enter.
"
  done
  extra="${extra}Answer n to any other [Y/n] or [y/N] offer."
  say_do "$T" "$line
$extra"
  return 0
}
mt__t_typed_run() {
  local t="$1" n="$2" proj="$3" line="$4" T k mark full rules tty refused=0 chk
  shift 4
  T=$(mt__t_upper "$t")
  if [ "${DRY:-0}" = 1 ]; then printf '  [dry] typed into %s: %s\n' "$T" "$line"; return 0; fi
  [ -n "$(mt__t_tty "$t")" ] || return 1
  # shellcheck disable=SC2034  # nb is counted through eval by mt__answers_gave_up
  local nb=0 rb
  mark="MT${INV:-0}-$n"
  # The guard: the line runs only in a bash that sourced the env file (egobjs is its function).
  # In any other shell, his login zsh above all, it prints MT-NOT-ENV-SHELL and runs nothing. The
  # empty quotes keep that word out of the typed line itself. The mark ends the line too, so the
  # text after it is the command's output even when Terminal wraps the line.
  full=": $mark; if [ -n \"\${BASH_VERSION:-}\" ] && typeset -f egobjs >/dev/null 2>&1; then $line; else echo MT-NOT\"\"-ENV-SHELL; fi; : $mark"
  chk="$RUN/t/.$t.chk.$$"
  while :; do
    k=0
    while :; do
      mt__t_state "$t"
      case "$MT__T_STATE" in
        prompt) break ;;
        error) return 1 ;;
        lost) mt__t_typed_ensure "$t" || return 1; continue ;;
      esac
      [ "$(t_mode)" = typed ] || return 1
      k=$((k + 1))
      if [ "$k" -ge 120 ]; then
        # n or s: the script stops waiting and you type this one command yourself (human fallback)
        ask_record "$t-busy" "$T" "Finish what runs there (end Claude with /exit if it is open). Answer n if it cannot be ended: you then type the next command yourself." "Is it back at its prompt?"
        rb=$?
        case "$rb" in 1|2) return 1 ;; esac
        mt__answers_gave_up "$t-busy" "$T still runs something" nb && return 1
        k=0
      fi
      sleep 1
    done
    mt__t_osa "$t" "run-$t" "	do script \"$(mt__osa_str "$full")\" in mtTab
	return \"ok\"" || return 1
    if [ "$MT__OSA_OUT" = MT-NO-TAB ]; then
      mt__t_typed_ensure "$t" || return 1
      continue
    fi
    # The guard's answer comes at once. A refusal means the tab was not the env-file bash after
    # all: it is never typed into again, a new window opens and the line is typed there (once).
    sleep 2
    mt__t_osa "$t" "check-$t" '	return history of mtTab' || return 1
    printf '%s\n' "$MT__OSA_OUT" > "$chk"
    if mt__t_text_after_mark "$chk" "$mark" | LC_ALL=C grep -q -e 'MT-NOT-ENV-SHELL'; then
      rm -f "$chk"
      refused=$((refused + 1))
      printf '%s! %s was not the bash with the env file: the line ran nothing there. Close that window.%s\n' "$MT__C_AMBER" "$T" "$MT__C_RESET"
      [ -n "${STEP_DIR:-}" ] && mt__check_write NOTE "$T refused a typed line (not the env-file bash): a new window opens" "" "" ""
      [ "$refused" -lt 2 ] || { mt__t_drop "$T refused a typed line twice"; return 1; }
      kv_del "$t.plist"
      mt__t_typed_ensure "$t" || return 1
      continue
    fi
    rm -f "$chk"
    break
  done
  tty=$(mt__t_tty "$t")
  kv_set "$t.mark" "$mark"
  kv_set "$t.started" "$(epoch_now)"
  rm -f "$RUN/t/$t.busyseen" "$RUN/t/$t.answerer.stop"
  rules="$RUN/t/$t-$n.rules"
  local mt__xa=("$@") mt__xr_tag=() mt__xr_re=() mt__xr_keys=() mt__xr_max=() mt__xprog=0
  mt__write_rules "$rules"
  set -m
  ( mt__t_answerer "$t" "$tty" "$proj" "$mark" "$rules" "$RUN/t/$t-$n.answers" ) < /dev/null > "$RUN/t/$t-$n.answerer.log" 2>&1 &
  # This invocation's pid of it: a stop in a later invocation (or after a reboot) never signals a
  # pid that another process may hold by then. The step's own end stops it too (MT__BGPIDS).
  kv_set "$t.answerer" "$! ${INV:-0}"
  MT__BGPIDS="${MT__BGPIDS:-} $!"
  set +m
  return 0
}
mt__t_text_after_mark() {
  # FILE MARK: the text after the last line holding MARK
  awk -v m="$2" 'index($0, m) { k = 0; next } { line[++k] = $0 } END { for (i = 1; i <= k; i++) print line[i] }' "$1"
}
mt__t_answerer() {
  local t="$1" tty="$2" proj="$3" mark="$4" rules="$5" log="$6" start now hist got tag keys pline base txt
  start=$(epoch_now)
  base=$(kv_get "$t.base" 0)
  hist="$RUN/t/.$t.hist.$$"
  txt="$RUN/t/.$t.text.$$"
  : > "$RUN/t/.$t.state.$$"
  while :; do
    sleep 2
    now=$(epoch_now)
    [ $((now - start)) -ge 900 ] && break
    [ -f "$RUN/t/$t.answerer.stop" ] && break
    if [ -n "$proj" ] && box_claude_live "$proj"; then break; fi
    got=$(command osascript -e "$(mt__t_tabscript "$tty" '	return processes of mtTab')" 2>/dev/null) || break
    [ "$got" != MT-NO-TAB ] || break
    got=$(mt__t_plist_norm "$got" | awk '{ print NF }')
    if mt__is_int "$got" && mt__is_int "$base"; then
      if [ "$got" -gt "$base" ]; then : > "$RUN/t/$t.busyseen"; fi
      if [ "$got" -le "$base" ] && { [ -f "$RUN/t/$t.busyseen" ] || [ $((now - start)) -ge 20 ]; }; then break; fi
    fi
    command osascript -e "$(mt__t_tabscript "$tty" '	return history of mtTab')" > "$hist" 2>/dev/null || break
    [ "$(cat "$hist")" != MT-NO-TAB ] || break
    mt__t_text_after_mark "$hist" "$mark" > "$txt"
    got=$(expect -f "$MT__MATCHER" "$rules" "$txt" "$RUN/t/.$t.state.$$" 2>/dev/null) || continue
    [ -n "$got" ] || continue
    tag="${got%%	*}"; keys="${got#*	}"; pline="${keys#*	}"; keys="${keys%%	*}"
    if [ -n "$proj" ] && box_claude_live "$proj"; then break; fi
    case "$keys" in
      *"<enter>")
        command osascript -e "$(mt__t_tabscript "$tty" "	do script \"$(mt__osa_str "${keys%<enter>}")\" in mtTab
	return \"ok\"")" >/dev/null 2>&1 || break ;;
      *) printf '%s\tunsupported keys %s\t%s\n' "$tag" "$keys" "$pline" >> "$log"; continue ;;
    esac
    printf '%s\t%s\t%s\n' "$tag" "$keys" "$pline" >> "$log"
  done
  rm -f "$hist" "$txt" "$RUN/t/.$t.state.$$"
}
# mt__t_answerer_stop T: stops T's answerer when this invocation started it and the pid is still
# this script's (ps), then forgets it. A pid from another invocation is never signalled.
mt__t_answerer_stop() {
  local v p inv
  : > "$RUN/t/$1.answerer.stop"
  v=$(kv_get "$1.answerer" "")
  [ -n "$v" ] || return 0
  kv_del "$1.answerer"
  p="${v%% *}"; inv="${v#* }"
  mt__is_int "$p" || return 0
  [ "$inv" = "${INV:-0}" ] || return 0
  if kill -0 "$p" 2>/dev/null && ps -o command= -p "$p" 2>/dev/null | LC_ALL=C grep -q -e 'egress-release'; then
    sleep 3
    kill -TERM -"$p" 2>/dev/null || kill -TERM "$p" 2>/dev/null
  fi
  MT__BGPIDS=$(printf '%s\n' ${MT__BGPIDS:-} | grep -v -x -e "$p" | tr '\n' ' ')
  return 0
}
mt__t_auto_start() {
  local t="$1" n="$2" proj="$3" cmd="$4" base pid cdflag=1
  shift 4
  base="$RUN/t/$t-$n"
  mt__t_auto_end_prev "$t"
  local mt__xa=("$@") mt__xr_tag=() mt__xr_re=() mt__xr_keys=() mt__xr_max=() mt__xprog=0
  mt__write_rules "$base.prog"
  : > "$base.ctl"
  [ -n "$proj" ] || cdflag=0
  if [ "${DRY:-0}" = 1 ]; then
    printf '  [dry] T1 simulated: %s in %s\n' "$cmd" "${proj:-the home dir}"
    kv_set "$t.base.auto" "$base"
    return 0
  fi
  set -m
  ( cd "$HOME" || exit 1
    exec expect -f "$MT__DRIVER" driver "$base.prog" "$base.ctl" "$base.raw" "$base.status" 24 80 600 0 -- \
      "$MT_BASH" -c 'source "$1" >/dev/null 2>&1; if [ "$3" = 1 ]; then cd "$2" || exit 1; fi; eval "$4"' _ "$ENVF" "$P/$proj" "$cdflag" "$cmd"
  ) < /dev/null > "$base.drv" 2>&1 &
  pid=$!
  set +m
  kv_set "$t.pid" "$pid"
  kv_set "$t.base.auto" "$base"
  mt__check_add NOTE "T1 simulated: $cmd in ${proj:-the home dir}" "" "" ""
  return 0
}
mt__t_auto_alive() {
  local pid base
  pid=$(kv_get "$1.pid" "")
  base=$(kv_get "$1.base.auto" "")
  [ -n "$pid" ] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  [ -z "$(mt__stat_get "$base.status" end)" ]
}
mt__t_auto_end_prev() {
  local t="$1" base pid k=0
  mt__t_auto_alive "$t" || return 0
  base=$(kv_get "$t.base.auto" "")
  pid=$(kv_get "$t.pid" "")
  printf 'quit\n' >> "$base.ctl"
  while kill -0 "$pid" 2>/dev/null && [ "$k" -lt 20 ]; do sleep 0.5; k=$((k + 1)); done
  kill -TERM "$pid" 2>/dev/null
  mt__check_add NOTE "T1 simulated: the previous session was hung up first" "" "" ""
}
# The probes t_wait_launch and t_wait_exit poll (run as run_cmd jobs).
mt__t_launch_probe() {
  local t="$1" proj="$2" now st
  if [ -n "$proj" ] && box_claude_live "$proj"; then return 0; fi
  case "$(kv_get t.mode human)" in
    auto) mt__t_auto_alive "$t" || return 0 ;;
    typed)
      st=$(kv_get "$t.started" 0)
      now=$(epoch_now)
      if mt__t_procs "$t"; then
        [ "$MT__T_PROCS" -gt "$(kv_get "$t.base" 99)" ] && : > "$RUN/t/$t.busyseen"
        if [ "$MT__T_PROCS" -le "$(kv_get "$t.base" 0)" ] && { [ -f "$RUN/t/$t.busyseen" ] || [ $((now - st)) -ge 20 ]; }; then return 0; fi
      elif [ "$MT__T_PLIST" = MT-NO-TAB ]; then
        # the tab is gone: nothing can open there any more
        return 0
      fi ;;
  esac
  return 1
}
mt__t_exit_probe() {
  local t="$1" proj="$2"
  if [ -n "$proj" ] && box_claude_live "$proj"; then return 1; fi
  case "$(kv_get t.mode human)" in
    auto) mt__t_auto_alive "$t" && return 1 ;;
    typed)
      # at its prompt, or the tab is gone or no longer the env-file bash: nothing runs there now
      mt__t_state "$t"
      case "$MT__T_STATE" in prompt|lost) ;; *) return 1 ;; esac ;;
  esac
  return 0
}
# t_wait_launch T PROJ [SECS]: rc 0 Claude is live, 1 the command ended without Claude, 2 skipped,
# 3 timed out (default 600 s).
t_wait_launch() {
  local t T proj="$2" secs="${3:-600}" r
  t=$(mt__t_norm "$1"); T=$(mt__t_upper "$t")
  [ "${DRY:-0}" = 1 ] && { printf '  [dry] wait for Claude to open in %s (%s)\n' "$T" "$proj"; return 0; }
  if [ "$(t_mode)" = human ]; then
    wait_for "$t-launch" "Wait for Claude Code to open in $T. If cleat stops without opening Claude, press d." --timeout "$secs" --every 2 -- mt__t_launch_probe "$t" "$proj"
  else
    wait_for "$t-launch" "Wait for Claude Code to open in $T. If cleat stops without opening Claude, press d." --auto --timeout "$secs" --every 2 -- mt__t_launch_probe "$t" "$proj"
  fi
  r=$?
  mt__t_answerer_stop "$t" >/dev/null 2>&1
  case "$r" in
    0) if [ -n "$proj" ] && mt__probe 60 box_claude_live "$proj"; then return 0; fi; return 1 ;;
    2) return 2 ;;
    *) return 3 ;;
  esac
}
# t_wait_exit T PROJ [SECS]: ends the session (the human types /exit, auto mode sends Ctrl-C) and
# waits for the session-end output. Records the method.
t_wait_exit() {
  local t T proj="$2" secs="${3:-600}" m base pid k method r
  t=$(mt__t_norm "$1"); T=$(mt__t_upper "$t")
  m=$(t_mode)
  [ "${DRY:-0}" = 1 ] && { printf '  [dry] end the session in %s (%s)\n' "$T" "$proj"; return 0; }
  if [ "$m" = auto ]; then
    base=$(kv_get "$t.base.auto" ""); pid=$(kv_get "$t.pid" "")
    if ! mt__t_auto_alive "$t"; then check_note "$T: no session to end"; return 0; fi
    method=auto-ctrl-c
    printf 'send\t<ctrl-c>\n' >> "$base.ctl"; sleep 1; printf 'send\t<ctrl-c>\n' >> "$base.ctl"
    k=0
    while [ "$k" -lt 10 ] && mt__t_auto_alive "$t" && mt__probe 60 box_claude_live "$proj"; do sleep 1; k=$((k + 1)); done
    if mt__t_auto_alive "$t" && mt__probe 60 box_claude_live "$proj"; then
      method=auto-exit
      printf 'send\t/exit<enter>\n' >> "$base.ctl"
      k=0
      while [ "$k" -lt 20 ] && mt__t_auto_alive "$t" && mt__probe 60 box_claude_live "$proj"; do sleep 1; k=$((k + 1)); done
    fi
    k=0
    while [ "$k" -lt 30 ] && mt__t_auto_alive "$t"; do sleep 1; k=$((k + 1)); done
    if mt__t_auto_alive "$t"; then
      method=auto-hangup
      printf 'quit\n' >> "$base.ctl"
      k=0
      while [ "$k" -lt 10 ] && kill -0 "$pid" 2>/dev/null; do sleep 1; k=$((k + 1)); done
      kill -TERM "$pid" 2>/dev/null
    fi
    check_note "$T session ended: $method"
    return 0
  fi
  if [ -n "$proj" ] && ! mt__probe 60 box_claude_live "$proj"; then
    [ "$m" != typed ] || mt__t_state "$t"
    if [ "$m" != typed ] || [ "$MT__T_STATE" = prompt ] || [ "$MT__T_STATE" = lost ]; then
      check_note "$T: no Claude session to end in $proj"
      return 0
    fi
  fi
  say_do "$T" "/exit"
  wait_for "$t-exit" "Type /exit in Claude Code in $T and wait for cleat's session-end report." --timeout "$secs" -- mt__t_exit_probe "$t" "$proj"
  r=$?
  check_note "$T session ended: human"
  [ "$r" = 0 ] && return 0
  return "$r"
}
# t_capture T NAME: what T printed since its last t_run, cleaned, as a cmd file (OUT, CMDREF).
t_capture() {
  local t T m base
  t=$(mt__t_norm "$1"); T=$(mt__t_upper "$t")
  m=$(t_mode)
  if [ "${DRY:-0}" = 1 ]; then mt__derived "capture of $T ($2)" none; : > "$OUT"; return 0; fi
  case "$m" in
    auto)
      base=$(kv_get "$t.base.auto" "")
      mt__derived "capture of $T ($2)" "${base:-none}.raw"
      if [ -n "$base" ] && [ -f "$base.raw" ]; then mt_clean "$base.raw" "$OUT"; else : > "$OUT"; fi
      return 0 ;;
    typed)
      mt__derived "capture of $T ($2)" none
      if mt__t_osa "$t" "capture-$t" '	return history of mtTab' && [ "$MT__OSA_OUT" != MT-NO-TAB ]; then
        printf '%s\n' "$MT__OSA_OUT" > "$OUT.hist"
        mt__t_text_after_mark "$OUT.hist" "$(kv_get "$t.mark" "")" | clean_text > "$OUT"
        rm -f "$OUT.hist"
        mt__t_answer_notes "$t"
        return 0
      fi
      : > "$OUT"
      return 1 ;;
  esac
  return 1
}
mt__t_answer_notes() {
  # the offers the T1 answerer answered, as NOTEs
  local t="$1" n f tag keys line
  n=$(kv_get "$t.runs" 0)
  f="$RUN/t/$t-$n.answers"
  [ -f "$f" ] || return 0
  while IFS=$'\t' read -r tag keys line; do
    check_note "$(mt__t_upper "$t") answered $tag with $keys: $line"
  done < "$f"
}
# t_region launch|end: narrows OUT (after t_capture) to the launch or the session-end region.
t_region() {
  local src="$OUT" which="$1"
  mt__derived "region $which" "$src"
  [ -f "$src" ] || { : > "$OUT"; return 0; }
  # The session end starts at the last "Session ended. Resume with: cleat resume" (bin/cleat:20274)
  # or, after a non-zero exit, which prints no such line, at "Claude exited with code N" (20276).
  # The egress report and the other session-end notices follow either.
  case "$which" in
    launch) LC_ALL=C awk '{ print } /Session ended\. Resume with: cleat resume|Claude exited with code [0-9]+/ { exit }' "$src" > "$OUT" ;;
    end) LC_ALL=C awk '/Session ended\. Resume with: cleat resume|Claude exited with code [0-9]+/ { k = 0; f = 1 } { line[++k] = $0 }
           END { if (f) for (i = 1; i <= k; i++) print line[i] }' "$src" > "$OUT"
         if [ -s "$OUT" ] && ! LC_ALL=C grep -q 'Session ended\. Resume with: cleat resume' "$OUT"; then
           check_note "the session ended with $(LC_ALL=C grep -m 1 -o -E 'Claude exited with code [0-9]+' "$OUT"), so no Session ended line: the session-end checks read from that line"
         fi ;;
    *) fatal "t_region launch|end" ;;
  esac
  return 0
}
# t_type T "TEXT": types TEXT and Return into T (typed and auto). rc 1 in human mode.
t_type() {
  local t m base
  t=$(mt__t_norm "$1")
  m=$(t_mode)
  [ "${DRY:-0}" = 1 ] && { printf '  [dry] type into %s: %s\n' "$t" "$2"; return 0; }
  case "$m" in
    typed)
      mt__t_osa "$t" "type-$t" "	do script \"$(mt__osa_str "$2")\" in mtTab
	return \"ok\"" || return 1
      [ "$MT__OSA_OUT" != MT-NO-TAB ] ;;
    auto) base=$(kv_get "$t.base.auto" ""); [ -n "$base" ] || return 1; printf 'send\t%s<enter>\n' "$2" >> "$base.ctl"; return 0 ;;
    *) return 1 ;;
  esac
}
# t_checks_or_ask TAG "+text" "-text" "~ERE"...: checks on the captured region, or one question.
t_checks_or_ask() {
  local tag="$1" s yes="" no=""
  shift
  if t_have_capture; then
    for s in "$@"; do
      case "$s" in
        +*) expect_contains "printed: ${s#+}" "${s#+}" ;;
        -*) expect_not_contains "never printed: ${s#-}" "${s#-}" ;;
        ~*) expect_match "printed a line matching: ${s#\~}" "${s#\~}" ;;
        *) fatal "t_checks_or_ask: a spec starts with + - or ~: $s" ;;
      esac
    done
    return 0
  fi
  for s in "$@"; do
    case "$s" in
      +*) yes="$yes${yes:+
}${s#+}" ;;
      ~*) yes="$yes${yes:+
}(a line like) ${s#\~}" ;;
      -*) no="$no${no:+
}${s#-}" ;;
    esac
  done
  ask "$tag" T1 "Read what T1 printed." "${yes:+T1 printed these lines:
$yes}${no:+
T1 printed none of these:
$no}" "Did T1 print exactly that?"
}

# ---------------------------------------------------------------------------------------------
# Host control: Docker Desktop, Wi-Fi, lid sleep, pmset. HOSTACT is real, human, sim or skipped.
# ---------------------------------------------------------------------------------------------

host_can() {
  [ "${IS_MACOS:-0}" = 1 ] && [ "${MT_NO_HOST_CONTROL:-}" != 1 ]
}
mt__host_sim() {
  [ "${MT_NO_HOST_CONTROL:-}" = 1 ] && [ "${MT_SIM_HOST:-}" = 1 ]
}
mt__hostact() {
  # NAME HOW: sets HOSTACT and records it
  HOSTACT="$2"
  kv_set "hostact.${STEP_ID:-run}.$1" "$2"
  mt__check_add NOTE "host action: $1 $2" "" "" ""
  return 0
}
host_effective() {
  case "${HOSTACT:-}" in real|human) return 0 ;; esac
  return 1
}
mt__docker_up() { command docker info > /dev/null 2>&1; }
mt__docker_down() { ! command docker info > /dev/null 2>&1; }
dd_wait_down() {
  local secs="${1:-180}"
  if [ "${DRY:-0}" = 1 ]; then printf '  [dry] wait for Docker to stop answering\n'; return 0; fi
  if mt__host_sim; then HOSTACT=sim; return 2; fi
  wait_for dd-down "" --auto --timeout "$secs" --every 2 -- mt__docker_down
  [ $? = 0 ] && { kv_set dd.down_at "$(utc_stamp)"; return 0; }
  return 1
}
dd_wait_up() {
  local secs="${1:-300}"
  if [ "${DRY:-0}" = 1 ]; then printf '  [dry] wait for Docker to answer\n'; return 0; fi
  wait_for dd-up "" --auto --timeout "$secs" --every 3 -- mt__docker_up
  [ $? = 0 ] && { kv_set dd.up_at "$(utc_stamp)"; return 0; }
  return 1
}
# mt__answers_gave_up TAG WHAT COUNTVAR: a question loop that MT_ANSWERS keeps answering yes while
# the fact stays false would never end. The third round under MT_ANSWERS gives up (rc 0) with a
# NOTE. At a terminal the loop is yours: s or q end it. COUNTVAR is the caller's counter.
mt__answers_gave_up() {
  [ -n "${MT_ANSWERS:-}" ] || return 1
  eval "$3=\$((\${$3:-0} + 1))"
  eval "[ \"\$$3\" -ge 3 ]" || return 1
  [ -n "${STEP_DIR:-}" ] && mt__check_write NOTE "[$1] $2 after three scripted answers: given up" "" "" ""
  return 0
}
# dd_quit [PROJ]: quit Docker Desktop (sim: stop the step's own box and gateway only).
dd_quit() {
  local proj="${1:-}" r n=0
  if [ "${DRY:-0}" = 1 ]; then printf '  [dry] quit Docker Desktop\n'; HOSTACT=real; return 0; fi
  if mt__host_sim; then
    if [ -n "$proj" ]; then box_rawstop "$proj"; gw_stop "$proj"; fi
    mt__hostact dd_quit sim
    return 0
  fi
  kv_set dd.quit_req "$(utc_stamp)"
  if host_can; then
    run_cmd -t 30 -n "quit Docker Desktop" -- osascript -e 'quit app "Docker"'
    if [ "$RC" = 0 ]; then
      dd_wait_down 180
      if [ $? = 0 ]; then mt__hostact dd_quit real; return 0; fi
    fi
  fi
  while :; do
    ask dd-quit Mac "Quit Docker Desktop from its menu (the whale icon, Quit Docker Desktop)." "Docker Desktop quits. Every box on this Mac stops." "Has Docker Desktop quit?"
    r=$?
    case "$r" in
      0) dd_wait_down 120 && { mt__hostact dd_quit human; return 0; } ;;
      5) continue ;;
      *) mt__hostact dd_quit skipped; return 1 ;;
    esac
    mt__answers_gave_up dd-quit "Docker still answers" n && { mt__hostact dd_quit skipped; return 1; }
  done
}
# dd_open: open Docker Desktop and wait for the engine (sim: nothing).
dd_open() {
  local r n=0
  if [ "${DRY:-0}" = 1 ]; then printf '  [dry] open Docker Desktop\n'; HOSTACT=real; return 0; fi
  if mt__host_sim; then mt__hostact dd_open sim; return 0; fi
  if host_can; then
    run_cmd -t 30 -n "open Docker Desktop" -- open -a Docker
    if [ "$RC" = 0 ] && dd_wait_up 300; then mt__hostact dd_open real; return 0; fi
  fi
  while :; do
    ask dd-open Mac "Open Docker Desktop from Applications and wait for the engine to run." "docker info answers" "Is Docker Desktop running?"
    r=$?
    case "$r" in
      0) dd_wait_up 300 && { mt__hostact dd_open human; return 0; } ;;
      5) continue ;;
      *) mt__hostact dd_open skipped; return 1 ;;
    esac
    mt__answers_gave_up dd-open "Docker does not answer" n && { mt__hostact dd_open skipped; return 1; }
  done
}
# wifi_dev: the device after "Hardware Port: Wi-Fi" (kv wifi.dev), printed.
wifi_dev() {
  local d
  d=$(kv_get wifi.dev "")
  if [ -z "$d" ] && host_can; then
    mt__probe 30 networksetup -listallhardwareports
    d=$(awk '/^Hardware Port: Wi-Fi/ { f = 1; next } f && /^Device:/ { print $2; exit }' "$MT__PROBE_OUT")
    [ -n "$d" ] && kv_set wifi.dev "$d"
  fi
  printf '%s\n' "$d"
}
net_online() { curl -sS -o /dev/null --max-time 5 https://example.com/ 2>/dev/null; }
mt__net_offline() { ! net_online; }
wifi_off() {
  local dev r
  if [ "${DRY:-0}" = 1 ]; then printf '  [dry] Wi-Fi off\n'; HOSTACT=real; return 0; fi
  on_cleanup wifi_on
  if mt__host_sim; then mt__hostact wifi_off sim; return 0; fi
  dev=$(wifi_dev)
  if host_can && [ -n "$dev" ]; then
    run_cmd -t 30 -n "Wi-Fi off" -- networksetup -setairportpower "$dev" off
    if wait_for wifi-off "" --auto --timeout 30 --every 2 -- mt__net_offline; then mt__hostact wifi_off real; return 0; fi
    local iface
    iface=$(route -n get default 2>/dev/null | awk '/interface:/ { print $2 }')
    ask wifi-still-online Mac "The Mac still reaches the internet with Wi-Fi off. The default route uses ${iface:-another interface}. Unplug or turn off that interface now." "https://example.com/ no longer answers" "Is the Mac offline now?"
    r=$?
  else
    ask wifi-off Mac "Turn Wi-Fi off from the menu bar (and unplug any network cable)." "the Mac is offline" "Is the Mac offline now?"
    r=$?
  fi
  if [ "$r" = 0 ] && mt__probe 30 mt__net_offline; then mt__hostact wifi_off human; return 0; fi
  mt__hostact wifi_off skipped
  return 1
}
wifi_on() {
  local dev r n=0
  if [ "${DRY:-0}" = 1 ]; then printf '  [dry] Wi-Fi on\n'; return 0; fi
  if mt__host_sim; then mt__hostact wifi_on sim; return 0; fi
  if mt__probe 10 net_online; then return 0; fi
  dev=$(wifi_dev)
  if host_can && [ -n "$dev" ]; then
    run_cmd -t 30 -n "Wi-Fi on" -- networksetup -setairportpower "$dev" on
    if wait_for wifi-on "" --auto --timeout 90 --every 3 -- net_online; then mt__hostact wifi_on real; return 0; fi
  fi
  while :; do
    ask wifi-on Mac "Turn Wi-Fi back on (and plug back any cable you unplugged)." "the Mac is online" "Is the Mac online again?"
    r=$?
    case "$r" in
      0) mt__probe 30 net_online && { mt__hostact wifi_on human; return 0; } ;;
      2) mt__hostact wifi_on skipped; return 1 ;;
    esac
    mt__answers_gave_up wifi-on "the Mac is still offline" n && { mt__hostact wifi_on skipped; return 1; }
  done
}
# lid_sleep MIN: always the human. Records kv <step>.asked_at and <step>.back_at (epochs).
lid_sleep() {
  local min="${1:-60}" s="${STEP_ID:-run}" r
  kv_set "$s.asked_at" "$(epoch_now)"
  if [ "${DRY:-0}" = 1 ]; then printf '  [dry] lid sleep %s min\n' "$min"; return 0; fi
  if mt__host_sim; then
    sleep 5
    kv_set "$s.back_at" "$(epoch_now)"
    mt__hostact lid_sleep sim
    return 0
  fi
  while :; do
    ask lid-sleep Mac "Close the lid now (no external display attached, keep-awake off). Leave it closed at least $min minutes. When the Mac wakes and you have logged in, come back here and answer y." "the Mac slept for at least $min minutes" "Did it sleep with the lid closed?"
    r=$?
    [ "$r" = 5 ] && continue
    break
  done
  kv_set "$s.back_at" "$(epoch_now)"
  if [ "$r" = 0 ]; then mt__hostact lid_sleep human; return 0; fi
  mt__hostact lid_sleep skipped
  return 1
}
# pm_assertions: PM_IDLE, PM_SYS (the two system-wide counts) and PM_HOLDERS (process names).
pm_assertions() {
  PM_IDLE=""; PM_SYS=""; PM_HOLDERS=""
  if [ "${DRY:-0}" = 1 ]; then printf '  [dry] pmset -g assertions\n'; PM_IDLE=0; PM_SYS=0; return 0; fi
  if host_can; then
    run_cmd -t 60 -n "pmset assertions" -- pmset -g assertions
    PM_IDLE=$(awk '/^Assertion status system-wide/ { f = 1; next } f && /^[^ \t]/ { f = 0 } f && $1 == "PreventUserIdleSystemSleep" { print $2 }' "$OUT")
    PM_SYS=$(awk '/^Assertion status system-wide/ { f = 1; next } f && /^[^ \t]/ { f = 0 } f && $1 == "PreventSystemSleep" { print $2 }' "$OUT")
    # The script's own caffeinate (sittings 0 to 2, egress-release.sh) is not one of yours: its
    # assertion is taken off the count and its line off the holders.
    local own=0
    if [ -n "${MT__CAFF_PID:-}" ]; then
      own=$(awk -v me="pid ${MT__CAFF_PID}(" '/^Listed by owning process/ { f = 1; next } f && /^[^ \t]/ { f = 0 }
        f && index($0, me) && /PreventUserIdleSystemSleep/ { n++ } END { print n + 0 }' "$OUT")
      if mt__is_int "$own" && mt__is_int "$PM_IDLE" && [ "$own" -gt 0 ] && [ "$PM_IDLE" -ge "$own" ]; then
        PM_IDLE=$((PM_IDLE - own))
        check_note "the script's own caffeinate (pid $MT__CAFF_PID) is left out of the count"
      fi
    fi
    PM_HOLDERS=$(awk -v me="pid ${MT__CAFF_PID:-none}(" '/^Listed by owning process/ { f = 1; next } f && /^[^ \t]/ { f = 0 }
      f && index($0, me) { next }
      f && /(PreventUserIdleSystemSleep|PreventSystemSleep)/ && match($0, /pid [0-9]+\([^)]*\)/) {
        s = substr($0, RSTART, RLENGTH); sub(/^pid [0-9]+\(/, "", s); sub(/\)$/, "", s); print s }' "$OUT" | sort -u | tr '\n' ' ')
    PM_HOLDERS="${PM_HOLDERS% }"
    return 0
  fi
  if ask pm-read Mac "In a terminal run: pmset -g assertions" "PreventUserIdleSystemSleep 0 and PreventSystemSleep 0 under Assertion status system-wide" "Are both counts 0?"; then
    PM_IDLE=0; PM_SYS=0
  else
    PM_IDLE="?"; PM_SYS="?"
    read_line pm-holders "Which processes hold them (names only)?" PM_HOLDERS
  fi
  return 0
}
# pm_sleep_log [AFTER_EPOCH]: the last sleep (after AFTER_EPOCH when given) from pmset's log.
# Sets PM_SLEEP_START PM_SLEEP_END (stamps), PM_SLEEP_MINS, PM_DARKWAKES. OUT holds the lines.
pm_sleep_log() {
  PM_SLEEP_START=""; PM_SLEEP_END=""; PM_SLEEP_MINS=""; PM_DARKWAKES=""
  if [ "${DRY:-0}" = 1 ]; then printf '  [dry] pmset -g log\n'; return 0; fi
  if ! host_can; then return 1; fi
  run_cmd -t 180 -n "pmset sleep log" -- mt__pm_log_tail
  pm_parse_sleep "$OUT" "${1:-}"
}
mt__pm_log_tail() { pmset -g log | grep -E 'Entering Sleep|Wake from' | tail -n 40; }
# pm_parse_sleep FILE [AFTER_EPOCH]: the parser, alone (fixture-tested).
pm_parse_sleep() {
  local f="$1" after="${2:-0}" r
  r=$(awk -v after="$after" "$MT__AWK_EPOCH"'
    {
      st = substr($0, 1, 25)
      e = mt_epoch(st)
      if (e == "") next
      if ($0 ~ /Entering Sleep/ && ($0 ~ /Clamshell Sleep/ || $0 ~ /Software Sleep/)) {
        if (after + 0 > 0) {
          if (ss == "" && e + 0 >= after + 0) { ss = st; se = e; dw = 0; we = ""; ws = "" }
        } else { ss = st; se = e; dw = 0; we = ""; ws = "" }
        next
      }
      if (ss != "" && we == "") {
        if ($0 ~ /DarkWake from/) { dw++; next }
        if ($0 ~ /Wake from/) { we = e; ws = st }
      }
    }
    END {
      if (ss == "") exit 1
      m = (we == "" ? "" : int((we - se) / 60))
      printf "%s\t%s\t%s\t%s\n", ss, ws, m, dw + 0
    }' "$f") || return 1
  PM_SLEEP_START="${r%%	*}"; r="${r#*	}"
  PM_SLEEP_END="${r%%	*}"; r="${r#*	}"
  PM_SLEEP_MINS="${r%%	*}"; PM_DARKWAKES="${r#*	}"
  return 0
}
# dd_settings_guess: Docker Desktop's settings lines about the VM manager and file sharing.
dd_settings_guess() {
  local f
  for f in "$HOME/Library/Group Containers/group.com.docker/settings-store.json" "$HOME/Library/Group Containers/group.com.docker/settings.json"; do
    [ -f "$f" ] || continue
    LC_ALL=C grep -i -E 'virtuali[sz]ation|virtiofs|grpcfuse|libkrun|vmm|UseVirtualizationFramework|filesharing' "$f" 2>/dev/null | sed 's/^[[:space:]]*//'
    return 0
  done
  return 0
}
# host_kill_vm PID: 3.2 only. kill -9 PID after checking it is Docker Desktop's VM process.
host_kill_vm() {
  local pid="$1" c
  mt__is_int "$pid" || fatal "host_kill_vm: not a pid: $pid"
  host_can || fatal "host_kill_vm needs host control"
  c=$(ps -o command= -p "$pid" 2>/dev/null)
  printf '%s\n' "$c" | grep -q -E 'com\.docker\.(krun|virtualization)|qemu-system' || fatal "host_kill_vm: $pid is not Docker Desktop's VM ($c)"
  [ "${DRY:-0}" = 1 ] && { printf '  [dry] kill -9 %s\n' "$pid"; return 0; }
  kill -9 "$pid"
  mt__hostact kill_vm real
}

# ---------------------------------------------------------------------------------------------
# The refusing-boxes note
# ---------------------------------------------------------------------------------------------

# refusing_set: the names the refusing-boxes note should list right now. The rule is
# _egress_refusing_boxes_note's (bin/cleat:13146 at ac6ee85) less its printing, run by the
# candidate itself (refusing.sh in the run's code dir). Call it through run_cmd or val.
refusing_set() {
  XDG_CONFIG_HOME="$EGX" "$MT_BASH" "$MT__CODE_DIR/refusing.sh" "$MT_WT"
}
# note_check [--also NAME]...: parses the refusing-boxes note in OUT and checks it against Docker.
note_check() {
  local src="$OUT" ref="$CMDREF" a exp_f got_f run_f parse_f e r listed missing extra bad
  local also=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --also) also[${#also[@]}]="$2"; shift 2 ;;
      *) fatal "note_check: unknown option '$1'" ;;
    esac
  done
  if [ "${DRY:-0}" = 1 ]; then mt__dry_check "the refusing-boxes note" "the names refusing_set gives"; return 0; fi
  exp_f="$SCRATCH/.note.exp.$$"; got_f="$SCRATCH/.note.got.$$"; run_f="$SCRATCH/.note.run.$$"; parse_f="$SCRATCH/.note.parse.$$"
  mt__probe 180 refusing_set
  { cat "$MT__PROBE_OUT"; for a in ${also[@]+"${also[@]}"}; do printf '%s\n' "$a"; done; } | grep -v '^$' | LC_ALL=C sort -u > "$exp_f"
  mt__probe 60 docker ps --filter "name=^cleat-" --format '{{.Names}}'
  LC_ALL=C sort -u "$MT__PROBE_OUT" > "$run_f"
  OUT="$src"; CMDREF="$ref"
  LC_ALL=C awk '
    !seen && /[0-9]+ boxes were created without egress control\. Each refuses to start/ { hdr = "many"; for (i = 1; i <= NF; i++) if ($i ~ /^[0-9]+$/) { cnt = $i; break }; seen = 1; next }
    !seen && /1 box was created without egress control\. It refuses to start/ { hdr = "one"; cnt = 1; seen = 1; next }
    seen && !done && /until it is recreated:/ { inrows = 1; next }
    inrows && /^[ \t]+cleat-/ { sub(/[ \t]+$/, ""); print "ROW\t" $1 "\t" ($NF == "running" ? 1 : 0); next }
    inrows { inrows = 0; done = 1 }
    /It is running, so it keeps its full network until it stops\./ { print "RUN1" }
    /One of them is running, so it keeps its full network until it stops\./ { print "RUNONE" }
    / of them are running\. Each keeps its full network until it stops\./ { for (i = 1; i <= NF; i++) if ($i ~ /^[0-9]+$/) { print "RUNN\t" $i; break } }
    /A session already open in it is not caged\./ { print "SESS1" }
    /A session already open in one is not caged\./ { print "SESSN" }
    END { print "HDR\t" hdr "\t" cnt }' "$src" > "$parse_f"
  e=$(awk 'END { print NR + 0 }' "$exp_f")
  awk -F'\t' '$1 == "ROW" { print $2 }' "$parse_f" | LC_ALL=C sort -u > "$got_f"
  listed=$(awk 'END { print NR + 0 }' "$got_f")
  r=$(awk -F'\t' '$1 == "HDR" { print $2 }' "$parse_f")
  printf '    note_check: expected %s box(es), the note lists %s\n' "$e" "$listed"
  if [ "$e" = 0 ]; then
    if [ -z "$r" ]; then mt__check_add PASS "no refusing-boxes note (no box would refuse)" "no note" "" "$ref"
    else mt__check_add FAIL "no refusing-boxes note (no box would refuse)" "no note" "a note listing $listed" "$ref"; fi
  else
    if [ -z "$r" ]; then
      mt__check_add FAIL "the refusing-boxes note is printed" "a note listing $e" "no note" "$ref"
    else
      local want_hdr=many
      [ "$e" = 1 ] && want_hdr=one
      local cnt
      cnt=$(awk -F'\t' '$1 == "HDR" { print $3 }' "$parse_f")
      if [ "$r" = "$want_hdr" ] && [ "$cnt" = "$e" ]; then
        mt__check_add PASS "the note's header counts $e" "$e" "$cnt" "$ref"
      else
        mt__check_add FAIL "the note's header counts $e" "$e ($want_hdr)" "$cnt ($r)" "$ref"
      fi
    fi
    missing=$(LC_ALL=C comm -23 "$exp_f" "$got_f" | awk 'END { print NR + 0 }')
    extra=$(LC_ALL=C comm -13 "$exp_f" "$got_f" | awk 'END { print NR + 0 }')
    if [ "$missing" = 0 ] && [ "$extra" = 0 ]; then
      mt__check_add PASS "the note lists exactly the boxes that would refuse" "$e" "$listed" "$ref"
    else
      LC_ALL=C comm -3 "$exp_f" "$got_f" | sed 's/^/      differs: /'
      mt__check_add FAIL "the note lists exactly the boxes that would refuse" "$e boxes" "$missing missing, $extra extra" "$ref"
    fi
  fi
  bad=$(awk '/^cleat-gw-/ { print; next } !/^cleat-[a-z0-9-]*-[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f](-[a-z0-9_-]+)?$/ { print }' "$got_f" | awk 'END { print NR + 0 }')
  if [ "$listed" != 0 ]; then
    if [ "$bad" = 0 ]; then mt__check_add PASS "no row names a container that is not a box" "" "" "$ref"
    else mt__check_add FAIL "no row names a container that is not a box" "box names only" "$bad rows are not boxes" "$ref"; fi
  fi
  # running marks and the running lines
  local runrows wantrun marked lines want
  LC_ALL=C comm -12 "$got_f" "$run_f" > "$got_f.r"
  wantrun=$(awk 'END { print NR + 0 }' "$got_f.r")
  awk -F'\t' '$1 == "ROW" && $3 == 1 { print $2 }' "$parse_f" | LC_ALL=C sort -u > "$got_f.m"
  marked=$(LC_ALL=C comm -3 "$got_f.m" "$got_f.r" | awk 'END { print NR + 0 }')
  runrows=$(awk 'END { print NR + 0 }' "$got_f.m")
  if [ "$listed" != 0 ]; then
    if [ "$marked" = 0 ]; then mt__check_add PASS "the rows marked running are the running boxes" "$wantrun" "$runrows" "$ref"
    else mt__check_add FAIL "the rows marked running are the running boxes" "$wantrun running" "$runrows marked, $marked differ" "$ref"; fi
  fi
  lines=$(awk -F'\t' '$1 ~ /^(RUN1|RUNONE|RUNN|SESS1|SESSN)$/ { printf "%s%s ", $1, ($2 != "" ? ":" $2 : "") }' "$parse_f")
  lines="${lines% }"
  if [ "$wantrun" = 0 ] || [ "$listed" = 0 ]; then want=""
  elif [ "$listed" = 1 ]; then want="RUN1 SESS1"
  elif [ "$wantrun" = 1 ]; then want="RUNONE SESS1"
  else want="RUNN:$wantrun SESSN"; fi
  if [ "$lines" = "$want" ]; then mt__check_add PASS "the running lines fit $wantrun running of $listed" "${want:-none}" "${lines:-none}" "$ref"
  else mt__check_add FAIL "the running lines fit $wantrun running of $listed" "${want:-none}" "${lines:-none}" "$ref"; fi
  mt__check_add VALUE "note.count" "" "$listed" ""
  mt__check_add VALUE "note.running" "" "$wantrun" ""
  rm -f "$exp_f" "$got_f" "$got_f.m" "$got_f.r" "$run_f" "$parse_f"
  return 0
}

# ---------------------------------------------------------------------------------------------
# Redaction and the report
# ---------------------------------------------------------------------------------------------

# redact (stdin to stdout): $HOME, the login and git identity, emails, UUIDs, tokens, the daily
# boxes (kv daily.names), any other non-test box, home paths outside the test's own, the night repo.
redact() {
  local lit="$SCRATCH/.redact.$$" u n gn ge h hs w
  [ -d "$SCRATCH" ] || mkdir -p "$SCRATCH"
  : > "$lit"
  for n in $(kv_get daily.names ""); do printf '%s\t<daily box>\n' "$n" >> "$lit"; done
  n=$(kv_get night.repo "")
  [ -n "$n" ] && printf '%s\t<repo>\n' "$n" >> "$lit"
  gn=$(GIT_OPTIONAL_LOCKS=0 git -C "$MT_WT" config user.name 2>/dev/null)
  ge=$(GIT_OPTIONAL_LOCKS=0 git -C "$MT_WT" config user.email 2>/dev/null)
  [ -n "$ge" ] && printf '%s\t<email>\n' "$ge" >> "$lit"
  [ -n "$gn" ] && printf '%s\t<git user>\n' "$gn" >> "$lit"
  h=$(uname -n 2>/dev/null)
  hs="${h%%.*}"
  [ -n "$h" ] && printf '%s\t<host>\n' "$h" >> "$lit"
  [ -n "$hs" ] && [ "$hs" != "$h" ] && printf '%s\t<host>\n' "$hs" >> "$lit"
  u=$(id -un 2>/dev/null)
  w="$MT_WT"
  case "$w" in "$HOME"/*) w="~/${w#"$HOME"/}" ;; esac
  MT_RHOME="$HOME" MT_RUSER="$u" MT_RWT="$w" MT_RTEST="$MT__TESTPROJ" LC_ALL=C awk -v lit="$lit" '
    function rep(s, f, t,   o, i) { o = ""; while ((i = index(s, f)) > 0) { o = o substr(s, 1, i - 1) t; s = substr(s, i + length(f)) } return o s }
    function isw(c) { return (c ~ /[A-Za-z0-9_]/) }
    function rep_word(s, w, t,   o, ls, lw, i, a, b) {
      if (w == "") return s
      o = ""; lw = tolower(w)
      while (1) {
        ls = tolower(s); i = index(ls, lw)
        if (i == 0) break
        a = (i > 1 ? substr(s, i - 1, 1) : ""); b = substr(s, i + length(w), 1)
        if ((a == "" || !isw(a)) && (b == "" || !isw(b))) { o = o substr(s, 1, i - 1) t; s = substr(s, i + length(w)) }
        else { o = o substr(s, 1, i + length(w) - 1); s = substr(s, i + length(w)) }
      }
      return o s
    }
    function rep_re(s, re, t,   o) { o = ""; while (match(s, re)) { o = o substr(s, 1, RSTART - 1) t; s = substr(s, RSTART + RLENGTH) } return o s }
    function tok(s,   o, w, r) {
      o = ""
      while (match(s, /[A-Za-z0-9_-]+/)) {
        w = substr(s, RSTART, RLENGTH)
        r = w
        if (length(w) >= 40 && w !~ /^[0-9a-f]+$/) r = "<token>"
        o = o substr(s, 1, RSTART - 1) r; s = substr(s, RSTART + RLENGTH)
      }
      return o s
    }
    function istest(name,   p, n, i) {
      n = split(ENVIRON["MT_RTEST"], p, " ")
      for (i = 1; i <= n; i++) if (index(name, "cleat-" p[i] "-") == 1 && length(name) >= length("cleat-" p[i] "-") + 8) {
        rest = substr(name, length("cleat-" p[i] "-") + 1)
        if (rest ~ /^[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]$/) return 1
      }
      return 0
    }
    function boxes(s,   o, re, w, nx) {
      o = ""
      re = "cleat-[a-z0-9][a-z0-9-]*-" H8
      while (match(s, re)) {
        w = substr(s, RSTART, RLENGTH); nx = substr(s, RSTART + RLENGTH, 1)
        if (nx ~ /[A-Za-z0-9_]/ || w ~ /^cleat-gw-/) { o = o substr(s, 1, RSTART + RLENGTH - 1); s = substr(s, RSTART + RLENGTH); continue }
        o = o substr(s, 1, RSTART - 1) (istest(w) ? w : "<other box>")
        s = substr(s, RSTART + RLENGTH)
      }
      return o s
    }
    function homepaths(s,   o, p, keep) {
      o = ""
      while (match(s, /~\/[^ \t"'"'"'`)>|,;]+/)) {
        p = substr(s, RSTART, RLENGTH)
        keep = (p ~ /^~\/mt-eg/ || p ~ /^~\/\.config\/cleat/ || p ~ /^~\/\.claude/ || p ~ /^~\/Library\// || index(p, ENVIRON["MT_RWT"]) == 1)
        o = o substr(s, 1, RSTART - 1) (keep ? p : "~/<path>")
        s = substr(s, RSTART + RLENGTH)
      }
      return o s
    }
    BEGIN {
      FS = "\t"
      while ((getline l < lit) > 0) { i = index(l, "\t"); nlit++; lf[nlit] = substr(l, 1, i - 1); lt[nlit] = substr(l, i + 1) }
      for (i = 2; i <= nlit; i++) for (j = i; j > 1 && length(lf[j]) > length(lf[j - 1]); j--) {
        tf = lf[j]; lf[j] = lf[j - 1]; lf[j - 1] = tf; tt = lt[j]; lt[j] = lt[j - 1]; lt[j - 1] = tt }
      H = "[0-9a-fA-F]"; H8 = H H H H H H H H
      UU = H8 "-" H H H H "-" H H H H "-" H H H H "-" H8 H H H H
      home = ENVIRON["MT_RHOME"]
      FS = " "
    }
    {
      s = $0
      for (i = 1; i <= nlit; i++) s = rep(s, lf[i], lt[i])
      if (home != "" && home != "/") s = rep(s, home, "~")
      s = rep_re(s, "[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z][A-Za-z]+", "<email>")
      s = rep_re(s, UU, "<uuid>")
      s = rep_re(s, "sk-ant-[A-Za-z0-9_-]+", "<token>")
      s = rep_re(s, "eyJ[A-Za-z0-9_.-]+", "<token>")
      s = tok(s)
      s = boxes(s)
      s = homepaths(s)
      s = rep_word(s, ENVIRON["MT_RUSER"], "<user>")
      print s
    }'
  rm -f "$lit"
}
mt__md_cell() {
  # TEXT: one table cell (no pipes, no newlines)
  printf '%s' "$1" | tr '\n\t|' '  /'
}
# report_write FILE: the report of section 5.8 (redacted). Never a raw transcript, a T1 capture,
# account output or a debug excerpt.
report_write() {
  local f="$1" tmp="$SCRATCH/.report.$$" i id st att endt note sit d first
  [ -d "$SCRATCH" ] || mkdir -p "$SCRATCH"
  mt__res_load
  {
    printf '# Egress release test report\n\n'
    printf -- '- Run: %s\n' "$RUNID"
    printf -- '- Candidate: %s%s on %s (HEAD at creation %s)\n' "$(kv_get cand.short "?")" "$(d=$(kv_get cand.desc ""); [ -n "$d" ] && printf ' (%s)' "$d")" "$(kv_get cand.branch "?")" "$(mt__runenv_get cand_sha | cut -c1-12)"
    printf -- '- Overrides:'
    for v in $MT__PINNED; do
      eval "printf ' %s=%s' \"$v\" \"\${$v:-}\""
    done
    printf '\n'
    [ "$(mt__runenv_get override_stop_rule)" = 1 ] && printf -- '- The stop rule was overridden (--override-stop-rule)\n'
    printf -- '- Written: %s UTC\n\n' "$(utc_stamp)"
    printf '## Sittings\n\n| Sitting | Dates | Pass | Fail | Error | Skip | Other | Pending |\n|---|---|---|---|---|---|---|---|\n'
    for sit in 0 1 2 3 5; do mt__report_sitting "$sit"; done
    printf '\n## Steps\n\n| Step | Status | Attempts | Note |\n|---|---|---|---|\n'
    i=0
    while [ "$i" -lt "${#R_ID[@]}" ]; do
      printf '| %s | %s | %s | %s |\n' "${R_ID[$i]}" "${S_STATUS[$i]}" "${S_ATT[$i]}" "$(mt__md_cell "$(mt__oneline "${S_NOTE[$i]}" 150)")"
      i=$((i + 1))
    done
    printf '\n## Failures and errors\n\n'
    first=1
    i=0
    while [ "$i" -lt "${#R_ID[@]}" ]; do
      case "${S_STATUS[$i]}" in
        FAIL|ERROR)
          first=0
          printf '### %s %s (%s, attempt %s)\n\n' "${R_ID[$i]}" "${R_TITLE[$i]}" "${S_STATUS[$i]}" "${S_ATT[$i]}"
          [ -n "${S_NOTE[$i]}" ] && printf 'Note: %s\n\n' "$(mt__oneline "${S_NOTE[$i]}" 300)"
          d="$RUN/steps/${R_ID[$i]}/a${S_ATT[$i]}"
          if [ -f "$d/checks.tsv" ]; then
            awk -F'\t' -v d="$d" '$2 == "FAIL" || $2 == "TIMEOUT" || $2 == "HUMAN-FAIL" {
                c = ""
                if ($6 != "") { cf = d "/" $6 ".cmd"; if ((getline c < cf) <= 0) c = ""; close(cf) }
                printf "- %s: %s\n", $2, $3
                if ($4 != "") printf "  - expected: `%s`\n", $4
                if ($5 != "") printf "  - got: `%s`\n", substr($5, 1, 200)
                if (c != "") printf "  - command: `%s`\n", substr(c, 1, 300)
              }' "$d/checks.tsv"
          fi
          printf '\n' ;;
      esac
      i=$((i + 1))
    done
    [ "$first" = 1 ] && printf 'None.\n\n'
    # kv defect.<step>: a defect a step saw in the candidate and recorded without failing on it.
    # Read from kv, never from the last attempt's checks, so a later attempt that did not see it
    # again (a re-run takes another path) never drops it from the report. At ac6ee85 no step
    # writes one: the five defects of the first real-Docker run are fixed there and each is a
    # check that fails the step (F1 to F5, the sign-off's fixes table).
    printf '## Defects seen in the candidate (recorded, never a pass condition)\n\n'
    first=1
    for d in $(kv_list defect.); do
      printf -- '- %s: %s\n' "${d#defect.}" "$(mt__oneline "$(kv_get "$d" "")" 300)"
      first=0
    done
    [ "$first" = 1 ] && printf 'None.\n'
    printf '\n## Human notes\n\n'
    mt__report_notes 'HUMAN-FAIL|HUMAN-SKIP|NOTE' '^\['
    printf '\n## Host actions simulated or skipped\n\n'
    mt__report_notes 'NOTE' '^host action: .* (sim|skipped)$'
    printf '\n## T1 simulated\n\n'
    mt__report_notes 'NOTE|HUMAN-SKIP' '^T1 simulated|T1 simulated: no Claude conversation'
    printf '\n## Removed steps and code changed since a pass\n\n'
    printf -- '- removed: %s\n' "${MT__RES_REMOVED:-none}"
    printf -- '- changed since pass: %s\n' "$(mt__changed_since_pass)"
  } > "$tmp"
  redact < "$tmp" > "$f"
  rm -f "$tmp"
}
mt__report_sitting() {
  local sit="$1" i p=0 fl=0 er=0 sk=0 ot=0 pe=0 dmin="" dmax="" s e
  i=0
  while [ "$i" -lt "${#R_ID[@]}" ]; do
    if [ "${R_SIT[$i]}" = "$sit" ]; then
      case "${S_STATUS[$i]}" in
        PASS) p=$((p + 1)) ;; FAIL) fl=$((fl + 1)) ;; ERROR) er=$((er + 1)) ;; SKIP) sk=$((sk + 1)) ;;
        pending) pe=$((pe + 1)) ;; *) ot=$((ot + 1)) ;;
      esac
      s="${S_START[$i]}"; e="${S_END[$i]}"
      if mt__is_int "$s"; then { [ -z "$dmin" ] || [ "$s" -lt "$dmin" ]; } && dmin="$s"; fi
      if mt__is_int "$e"; then { [ -z "$dmax" ] || [ "$e" -gt "$dmax" ]; } && dmax="$e"; fi
    fi
    i=$((i + 1))
  done
  printf '| %s | %s | %s | %s | %s | %s | %s | %s |\n' "$sit" "$(mt__epoch_date "$dmin")${dmax:+ to $(mt__epoch_date "$dmax")}" "$p" "$fl" "$er" "$sk" "$ot" "$pe"
}
mt__epoch_date() {
  [ -n "$1" ] || { printf 'not run'; return 0; }
  mt__epoch_fmt "$1" '+%Y-%m-%d'
}
# mt__epoch_fmt EPOCH FORMAT: date -u -r on BSD, date -u -d @ on GNU (whichever this date takes).
mt__epoch_fmt() {
  date -u -r "$1" "$2" 2>/dev/null || date -u -d "@$1" "$2" 2>/dev/null || printf '%s' "$1"
}
mt__report_notes() {
  # STATUSES DESC-ERE: matching checks of every step's last attempt, one bullet each
  local i d any=0
  i=0
  while [ "$i" -lt "${#R_ID[@]}" ]; do
    d="$RUN/steps/${R_ID[$i]}/a${S_ATT[$i]}"
    if [ "${S_ATT[$i]}" != 0 ] && [ -f "$d/checks.tsv" ]; then
      MT_STS="^($1)\$" MT_RE="$2" awk -F'\t' -v id="${R_ID[$i]}" 'BEGIN { sts = ENVIRON["MT_STS"]; re = ENVIRON["MT_RE"] } $2 ~ sts && $3 ~ re {
          printf "- %s: %s%s\n", id, $3, ($5 != "" ? " (" substr($5, 1, 200) ")" : "") ; n++ }
        END { exit (n > 0 ? 0 : 1) }' "$d/checks.tsv" && any=1
    fi
    i=$((i + 1))
  done
  [ "$any" = 1 ] || printf 'None.\n'
  return 0
}

# ---------------------------------------------------------------------------------------------
# The step registry (parallel arrays, linear lookup: bash 3.2 has no associative arrays)
# ---------------------------------------------------------------------------------------------

R_ID=(); R_SIT=(); R_KIND=(); R_CLASS=(); R_FUNC=(); R_TITLE=(); R_PART=(); R_LINE=()
MT__REG_ERRORS=""
mt__reg_err() { MT__REG_ERRORS="${MT__REG_ERRORS}$1
"; }
# reg ID SITTING KIND CLASS FUNC "TITLE": one call per step, at source time, in scenario order.
reg() {
  local line="${BASH_LINENO[0]:-?}" part="${MT__PART:-?}" id want i
  if [ $# -ne 6 ]; then mt__reg_err "$part line $line: reg needs ID SITTING KIND CLASS FUNC TITLE, got $# arguments"; return 0; fi
  id="$1"
  case "$id" in ''|*[!0-9a-z.-]*) mt__reg_err "$part line $line: bad id '$id' (allowed: 0-9 a-z . -)"; return 0 ;; esac
  case "$2" in 0|1|2|3|5) ;; *) mt__reg_err "$part line $line: $id: bad sitting '$2' (0 1 2 3 5)"; return 0 ;; esac
  case "$3" in auto|expect|human|mixed) ;; *) mt__reg_err "$part line $line: $id: bad kind '$3' (auto expect human mixed)"; return 0 ;; esac
  case "$4" in gate|extra) ;; *) mt__reg_err "$part line $line: $id: bad class '$4' (gate extra)"; return 0 ;; esac
  want="st_$(printf '%s' "$id" | tr '.-' '__')"
  [ "$5" = "$want" ] || { mt__reg_err "$part line $line: $id: the function must be named $want, not $5"; return 0; }
  [ -n "$6" ] || { mt__reg_err "$part line $line: $id: an empty title"; return 0; }
  i=0
  while [ "$i" -lt "${#R_ID[@]}" ]; do
    if [ "${R_ID[$i]}" = "$id" ]; then mt__reg_err "$part line $line: duplicate id $id (first in ${R_PART[$i]} line ${R_LINE[$i]})"; return 0; fi
    i=$((i + 1))
  done
  i=${#R_ID[@]}
  R_ID[$i]="$id"; R_SIT[$i]="$2"; R_KIND[$i]="$3"; R_CLASS[$i]="$4"; R_FUNC[$i]="$5"; R_TITLE[$i]="$6"
  R_PART[$i]="$part"; R_LINE[$i]="$line"
  return 0
}
# mt__reg_check_funcs PART: every step PART registered has its function defined.
mt__reg_check_funcs() {
  local i=0
  while [ "$i" -lt "${#R_ID[@]}" ]; do
    if [ "${R_PART[$i]}" = "$1" ] && ! declare -F "${R_FUNC[$i]}" > /dev/null; then
      mt__reg_err "$1 line ${R_LINE[$i]}: ${R_ID[$i]}: the function ${R_FUNC[$i]} is not defined when the part has loaded"
    fi
    i=$((i + 1))
  done
}
mt__reg_index() {
  # ID: its registry index, rc 1 when unknown
  local i=0
  while [ "$i" -lt "${#R_ID[@]}" ]; do
    [ "${R_ID[$i]}" = "$1" ] && { printf '%s' "$i"; return 0; }
    i=$((i + 1))
  done
  return 1
}
mt__hash() { declare -f "$1" | cksum | awk '{ print $1 "-" $2 }'; }

# ---------------------------------------------------------------------------------------------
# results.tsv (append-only) and run.env
# ---------------------------------------------------------------------------------------------

MT__RES_HEADER='run_id	step_id	attempt	status	start	end	code_hash	transcript	note'
mt__res_append() {
  # ID ATTEMPT STATUS START END HASH TRANSCRIPT NOTE
  local note
  note=$(mt__oneline "${8:-}" 300)
  [ -f "$RUN/results.tsv" ] || printf '%s\n' "$MT__RES_HEADER" > "$RUN/results.tsv"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$RUNID" "$1" "$2" "$3" "$4" "${5:-}" "${6:-}" "${7:-}" "$note" >> "$RUN/results.tsv"
}
# mt__res_load: per registry index S_STATUS (pending when no line) S_ATT (highest attempt)
# S_LASTATT (the last line's attempt) S_HASH S_START S_END S_NOTE. Also MT__RES_REMOVED.
mt__res_load() {
  local i id st att lastatt hash start endt note
  S_STATUS=(); S_ATT=(); S_LASTATT=(); S_HASH=(); S_START=(); S_END=(); S_NOTE=()
  i=0
  while [ "$i" -lt "${#R_ID[@]}" ]; do
    S_STATUS[$i]=pending; S_ATT[$i]=0; S_LASTATT[$i]=0; S_HASH[$i]=""; S_START[$i]=""; S_END[$i]=""; S_NOTE[$i]=""
    i=$((i + 1))
  done
  MT__RES_REMOVED=""
  [ -f "$RUN/results.tsv" ] || return 0
  while IFS=$'\037' read -r id st att lastatt hash start endt note; do
    [ -n "$id" ] || continue
    if i=$(mt__reg_index "$id"); then
      S_STATUS[$i]="$st"; S_ATT[$i]="$att"; S_LASTATT[$i]="$lastatt"; S_HASH[$i]="$hash"
      S_START[$i]="$start"; S_END[$i]="$endt"; S_NOTE[$i]="$note"
    else
      MT__RES_REMOVED="$MT__RES_REMOVED${MT__RES_REMOVED:+ }$id"
    fi
  done <<MT__RES_EOF
$(LC_ALL=C awk -F'\t' 'NR > 1 && $2 != "" {
    id = $2
    if (!(id in seen)) { seen[id] = 1; order[++n] = id; first[id] = $5 }
    st[id] = $4; la[id] = $3; h[id] = $7; e[id] = $6; nt[id] = $9
    if ($3 + 0 > mx[id] + 0) mx[id] = $3 + 0
  }
  END { for (k = 1; k <= n; k++) { id = order[k]; printf "%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\n", id, st[id], mx[id] + 0, la[id], h[id], first[id], e[id], nt[id] } }' "$RUN/results.tsv")
MT__RES_EOF
}
mt__is_terminal() { case "$1" in PASS|FAIL|SKIP|DRY) return 0 ;; esac; return 1; }
mt__changed_since_pass() {
  local i out=""
  i=0
  while [ "$i" -lt "${#R_ID[@]}" ]; do
    if [ "${S_STATUS[$i]}" = PASS ] && [ -n "${S_HASH[$i]}" ] && declare -F "${R_FUNC[$i]}" > /dev/null; then
      [ "$(mt__hash "${R_FUNC[$i]}")" = "${S_HASH[$i]}" ] || out="$out${out:+ }${R_ID[$i]}"
    fi
    i=$((i + 1))
  done
  printf '%s\n' "${out:-none}"
}
mt__runenv_get() {
  [ -f "$RUN/run.env" ] || return 0
  LC_ALL=C awk -F'\t' -v k="$1" '$1 == k { v = substr($0, length(k) + 2) } END { print v }' "$RUN/run.env"
}
mt__runenv_has() {
  [ -f "$RUN/run.env" ] || return 1
  LC_ALL=C awk -F'\t' -v k="$1" '$1 == k { f = 1 } END { exit (f ? 0 : 1) }' "$RUN/run.env"
}
mt__runenv_set() { printf '%s\t%s\n' "$1" "$2" >> "$RUN/run.env"; }

# ---------------------------------------------------------------------------------------------
# The files written into the run's code dir: drive.exp, match.tcl, refusing.sh, strip.sed
# ---------------------------------------------------------------------------------------------

mt__write_helpers() {
  local d="$MT__CODE_DIR" e b c
  [ -d "$d" ] || mkdir -p "$d"
  [ -w "$d" ] || return 0
  mt__drive_exp > "$d/drive.exp.tmp" && mv -f "$d/drive.exp.tmp" "$d/drive.exp"
  mt__match_tcl > "$d/match.tcl.tmp" && mv -f "$d/match.tcl.tmp" "$d/match.tcl"
  mt__refusing_sh > "$d/refusing.sh.tmp" && mv -f "$d/refusing.sh.tmp" "$d/refusing.sh"
  e=$(printf '\033'); b=$(printf '\007'); c=$(printf '\r')
  {
    printf 's|%s\\[[0-?]*[ -/]*[@-~]||g\n' "$e"
    printf 's|%s][^%s%s]*%s||g\n' "$e" "$b" "$e" "$b"
    printf 's|%s][^%s%s]*%s\\\\||g\n' "$e" "$b" "$e" "$e"
    printf 's|%s[()].||g\n' "$e"
    printf 's|%s[=>78cDEM]||g\n' "$e"
    printf 's|%s||g\n' "$b"
    printf 's|%s$||\n' "$c"
  } > "$d/strip.sed.tmp" && mv -f "$d/strip.sed.tmp" "$d/strip.sed"
  return 0
}
mt__drive_exp() {
  cat <<'MT__DRIVE_EOF'
# drive.exp: the expect driver of egress-release.sh (written by 00-lib.sh into the run dir).
#
# argv: MODE PROG CTL RAW STATUS ROWS COLS IDLE WATCH -- CMD [ARGS...]
#   MODE    run (rules plus an optional sequential program) or driver (T1 auto: a control file)
#   PROG    the rules and program file, one TAB separated line each:
#             rule TAG REGEX KEYS MAX FLAGS   (FLAGS: note, manual)
#             wait TAG REGEX SECS | send KEYS | sleep MS | resize ROWS COLS | snap NAME
#             mark NAME | hold KEYS COUNT GAPMS | quiet MS NAME | eof SECS | host COMMAND
#   CTL     driver mode: the control file (send KEYS, answer TAG KEYS, quit), polled every 300 ms
#   RAW     the raw log (log_file -a)
#   STATUS  key=value lines: rc end waitfail fired.TAG wait.TAG mark.NAME snap.NAME cursor.NAME ...
#   IDLE    seconds without output that end the reactive loop (also the default wait)
#   WATCH   1: copy the raw stream to /dev/tty as well
# Exit code: the child's (128+N when a signal ended it), 124 on the driver's own idle timeout.

set mt_args $argv
if {[llength $mt_args] < 11 || [lindex $mt_args 9] ne "--"} {
    puts stderr "drive.exp: bad arguments: $mt_args"
    exit 2
}
foreach {mode progf ctlf rawf statf rows cols idle watch} [lrange $mt_args 0 8] break
set cmd [lrange $mt_args 10 end]

encoding system utf-8
log_user 0
exp_internal 0
match_max 1000000
set timeout -1
remove_nulls 0

set t0 [clock milliseconds]
set st_keys {}
array set st {}
proc stset {k v} {
    global st st_keys
    regsub -all {[\r\n]} $v { } v
    if {![info exists st($k)]} { lappend st_keys $k }
    set st($k) $v
}
proc stget {k {d ""}} {
    global st
    if {[info exists st($k)]} { return $st($k) }
    return $d
}
proc flush_status {} {
    global st st_keys statf t0
    set st(elapsed) [expr {([clock milliseconds] - $t0) / 1000.0}]
    if {[lsearch -exact $st_keys elapsed] < 0} { lappend st_keys elapsed }
    set tmp "$statf.tmp"
    if {[catch {
        set f [open $tmp w]
        fconfigure $f -encoding utf-8
        foreach k $st_keys { puts $f "$k=$st($k)" }
        close $f
        file rename -force $tmp $statf
    } err]} {
        catch {puts stderr "drive.exp: status write failed: $err"}
    }
}

# ---- keys ------------------------------------------------------------------
set keymap [list \
    <up> "\033\[A" <down> "\033\[B" <left> "\033\[D" <right> "\033\[C" \
    <esc> "\033" <enter> "\r" <space> " " <tab> "\t" <bs> "\177" \
    <pgup> "\033\[5~" <pgdn> "\033\[6~" <home> "\033\[H" <end> "\033\[F" \
    <opt-left-iterm> "\033\[1;3D" <opt-right-iterm> "\033\[1;3C" \
    <opt-left> "\033b" <opt-right> "\033f" \
    <ctrl-c> "\003" <ctrl-d> "\004" <lt> "<"]
proc keys {k} {
    global keymap
    return [string map $keymap $k]
}

# ---- the rules and the program ---------------------------------------------
set rules {}
set program {}
set need_screen 0
proc load_prog {f} {
    global rules program need_screen
    if {$f eq "" || ![file exists $f]} { return }
    set fh [open $f r]
    fconfigure $fh -encoding utf-8
    set data [read $fh]
    close $fh
    foreach line [split $data "\n"] {
        if {$line eq ""} { continue }
        set fl [split $line "\t"]
        set op [lindex $fl 0]
        if {$op eq "rule"} {
            # tag regex keys max flags
            set max [lindex $fl 4]
            if {$max eq ""} { set max 0 }
            lappend rules [list [lindex $fl 1] [lindex $fl 2] [lindex $fl 3] $max [lindex $fl 5]]
        } else {
            if {$op eq "snap" || $op eq "resize"} { set need_screen 1 }
            lappend program $fl
        }
    }
}
load_prog $progf
array set fired {}
foreach r $rules { set fired([lindex $r 0]) 0 }

# ---- the stream ------------------------------------------------------------
# buf holds the output since the absolute character offset bufbase.
set buf ""
set bufbase 0
set basebytes 0
set rawbytes 0
set consumed 0
set seqpos 0
set eofseen 0
set ev ""
set scrq ""
set ttyfd ""
if {$watch eq "1"} { catch {set ttyfd [open /dev/tty w]} }

proc abs_len {} {
    global buf bufbase
    return [expr {$bufbase + [string length $buf]}]
}
proc bytes_at {abspos} {
    # the raw log byte offset of an absolute character offset
    global buf bufbase basebytes
    set rel [expr {$abspos - $bufbase}]
    if {$rel <= 0} { return $basebytes }
    return [expr {$basebytes + [string length [encoding convertto utf-8 [string range $buf 0 [expr {$rel - 1}]]]]}]
}
proc trim_buf {} {
    global buf bufbase basebytes consumed seqpos
    set keep 262144
    set len [string length $buf]
    if {$len < 2 * $keep} { return }
    set low [expr {$bufbase + $len - $keep}]
    if {$seqpos < $low} { set low $seqpos }
    set cut [expr {$low - $bufbase}]
    if {$cut <= 0} { return }
    set gone [string range $buf 0 [expr {$cut - 1}]]
    set basebytes [expr {$basebytes + [string length [encoding convertto utf-8 $gone]]}]
    set buf [string range $buf $cut end]
    set bufbase [expr {$bufbase + $cut}]
    if {$consumed < $bufbase} { set consumed $bufbase }
}
proc plain {s} {
    regsub -all {\033\[[0-?]*[ -/]*[@-~]} $s {} s
    regsub -all {\033\][^\007\033]*(\007|\033\\)} $s {} s
    regsub -all {\033[()].} $s {} s
    regsub -all {\033.} $s {} s
    regsub -all {[\000-\010\013-\037\177]} $s {} s
    return [string trim $s]
}
proc line_of {s e} {
    # the text of the line holding the match that ends at relative index e
    global buf
    set a [string last "\n" $buf $s]
    set b [string first "\n" $buf $e]
    if {$b < 0} { set b [string length $buf] }
    set t [string range $buf [expr {$a + 1}] [expr {$b - 1}]]
    regsub -all {\r} $t "\n" t
    set parts [split $t "\n"]
    set out ""
    foreach p $parts { set p [plain $p]; if {$p ne ""} { set out $p } }
    return $out
}
proc line_start {rel} {
    # the absolute offset of the start of the line holding the relative index rel
    global buf bufbase
    set nl [string last "\n" $buf [expr {$rel - 1}]]
    return [expr {$bufbase + $nl + 1}]
}
# A prompt line one rule answered is never answered again by another rule: a named rule that
# matched the start of a prompt leaves its [Y/n] for nobody else, even when the rest arrives later.
set firedline -1
set firedtag ""
proc check_rules {} {
    global rules fired buf bufbase consumed sid firedline firedtag
    set guard 0
    while {[incr guard] < 1000} {
        set hit 0
        set from [expr {$consumed - $bufbase}]
        if {$from < 0} { set from 0 }
        set i 0
        foreach r $rules {
            foreach {tag re ks max flags} $r break
            if {$max > 0 && $fired($tag) >= $max} { incr i; continue }
            if {[catch {regexp -start $from -indices -- $re $buf m} ok]} { incr i; continue }
            if {!$ok} { incr i; continue }
            foreach {ms me} $m break
            if {$me < $ms} { incr i; continue }
            if {[line_start $ms] == $firedline && $tag ne $firedtag} { incr i; continue }
            set firedline [line_start $ms]
            set firedtag $tag
            incr fired($tag)
            stset "fired.$tag" $fired($tag)
            if {[string first note $flags] >= 0 || [string first manual $flags] < 0} {
                stset "firedline.$tag.$fired($tag)" [line_of $ms $me]
            }
            set consumed [expr {$bufbase + $me + 1}]
            if {[string first manual $flags] < 0 && $ks ne ""} {
                catch {exp_send -i $sid -- [keys $ks]}
            }
            flush_status
            set hit 1
            break
        }
        if {!$hit} { break }
    }
}
proc on_data {data} {
    global buf rawbytes scrq need_screen ttyfd ev
    append buf $data
    set rawbytes [expr {$rawbytes + [string length [encoding convertto utf-8 $data]]}]
    if {$need_screen} {
        append scrq $data
        if {[string length $scrq] > 1000000} { scr_feed_queue }
    }
    if {$ttyfd ne ""} { catch {puts -nonewline $ttyfd $data; flush $ttyfd} }
    check_rules
    trim_buf
    set ev data
}
proc on_eof {} {
    global eofseen ev
    set eofseen 1
    set ev eof
}
proc wait_event {ms} {
    # returns data, eof or timeout
    global ev eofseen
    if {$eofseen} { return eof }
    set ev ""
    set id [after $ms {set ::ev timeout}]
    vwait ::ev
    after cancel $id
    return $ev
}
proc wait_ms {ms} {
    # lets output and the rules run for ms milliseconds
    set end [expr {[clock milliseconds] + $ms}]
    while {1} {
        set left [expr {$end - [clock milliseconds]}]
        if {$left <= 0} { return }
        if {[wait_event $left] eq "eof"} {
            # nothing more will come: just let the time pass
            after [expr {max(0, $end - [clock milliseconds])}]
            return
        }
    }
}

# ---- the screen model (a VT subset) ----------------------------------------
array set S {}
proc scr_blank {} { global S; return [string repeat " " $S(cols)] }
proc scr_init {r c} {
    global S
    set S(rows) $r; set S(cols) $c
    set S(cr) 0; set S(cc) 0; set S(wrap) 0
    set S(alt) 0; set S(pend) ""
    set S(sr) 0; set S(sc) 0
    set S(lines) {}
    set b [scr_blank]
    for {set i 0} {$i < $r} {incr i} { lappend S(lines) $b }
}
proc scr_clamp {} {
    global S
    if {$S(cr) < 0} { set S(cr) 0 }
    if {$S(cr) >= $S(rows)} { set S(cr) [expr {$S(rows) - 1}] }
    if {$S(cc) < 0} { set S(cc) 0 }
    if {$S(cc) >= $S(cols)} { set S(cc) [expr {$S(cols) - 1}] }
}
proc scr_lf {} {
    global S
    if {$S(cr) >= $S(rows) - 1} {
        set S(lines) [lrange $S(lines) 1 end]
        lappend S(lines) [scr_blank]
        set S(cr) [expr {$S(rows) - 1}]
    } else {
        incr S(cr)
    }
}
proc scr_ri {} {
    global S
    if {$S(cr) <= 0} {
        set S(lines) [linsert [lrange $S(lines) 0 end-1] 0 [scr_blank]]
        set S(cr) 0
    } else {
        incr S(cr) -1
    }
}
proc scr_put {t} {
    global S
    while {[string length $t] > 0} {
        if {$S(wrap)} { set S(cc) 0; scr_lf; set S(wrap) 0 }
        set room [expr {$S(cols) - $S(cc)}]
        if {$room <= 0} { set S(cc) [expr {$S(cols) - 1}]; set room 1 }
        set chunk [string range $t 0 [expr {$room - 1}]]
        set t [string range $t $room end]
        set k [string length $chunk]
        set line [lindex $S(lines) $S(cr)]
        set line [string replace $line $S(cc) [expr {$S(cc) + $k - 1}] $chunk]
        lset S(lines) $S(cr) $line
        set S(cc) [expr {$S(cc) + $k}]
        if {$S(cc) >= $S(cols)} { set S(cc) [expr {$S(cols) - 1}]; set S(wrap) 1 }
    }
}
proc scr_erase_line {r from to} {
    global S
    if {$from > $to} { return }
    set line [lindex $S(lines) $r]
    set line [string replace $line $from $to [string repeat " " [expr {$to - $from + 1}]]]
    lset S(lines) $r $line
}
proc scr_csi {params final} {
    global S
    set priv ""
    if {[regexp {^([?>=<])(.*)$} $params -> priv rest]} { set params $rest }
    set ps [split $params ";"]
    set p1 [lindex $ps 0]; set p2 [lindex $ps 1]
    if {![string is integer -strict $p1]} { set p1 0 }
    if {![string is integer -strict $p2]} { set p2 0 }
    set n $p1
    if {$n < 1} { set n 1 }
    if {$priv eq "?"} {
        if {$params eq "1049" && ($final eq "h")} {
            if {!$S(alt)} {
                set S(main) $S(lines); set S(msr) $S(cr); set S(msc) $S(cc)
                set S(alt) 1
                set S(lines) {}
                set b [scr_blank]
                for {set i 0} {$i < $S(rows)} {incr i} { lappend S(lines) $b }
                set S(wrap) 0
            }
        } elseif {$params eq "1049" && ($final eq "l")} {
            if {$S(alt)} {
                set S(lines) $S(main); set S(cr) $S(msr); set S(cc) $S(msc)
                set S(alt) 0; set S(wrap) 0
                scr_clamp
            }
        }
        return
    }
    if {$priv ne ""} { return }
    switch -- $final {
        A { set S(cr) [expr {$S(cr) - $n}]; set S(wrap) 0 }
        B { set S(cr) [expr {$S(cr) + $n}]; set S(wrap) 0 }
        C { set S(cc) [expr {$S(cc) + $n}]; set S(wrap) 0 }
        D { set S(cc) [expr {$S(cc) - $n}]; set S(wrap) 0 }
        E { set S(cr) [expr {$S(cr) + $n}]; set S(cc) 0; set S(wrap) 0 }
        F { set S(cr) [expr {$S(cr) - $n}]; set S(cc) 0; set S(wrap) 0 }
        G { set S(cc) [expr {$n - 1}]; set S(wrap) 0 }
        d { set S(cr) [expr {$n - 1}]; set S(wrap) 0 }
        H - f {
            set r $p1; set c $p2
            if {$r < 1} { set r 1 }
            if {$c < 1} { set c 1 }
            set S(cr) [expr {$r - 1}]; set S(cc) [expr {$c - 1}]; set S(wrap) 0
        }
        J {
            scr_clamp
            set last [expr {$S(cols) - 1}]
            if {$p1 == 0} {
                scr_erase_line $S(cr) $S(cc) $last
                for {set r [expr {$S(cr) + 1}]} {$r < $S(rows)} {incr r} { scr_erase_line $r 0 $last }
            } elseif {$p1 == 1} {
                for {set r 0} {$r < $S(cr)} {incr r} { scr_erase_line $r 0 $last }
                scr_erase_line $S(cr) 0 $S(cc)
            } else {
                for {set r 0} {$r < $S(rows)} {incr r} { scr_erase_line $r 0 $last }
            }
        }
        K {
            scr_clamp
            set last [expr {$S(cols) - 1}]
            if {$p1 == 0} {
                scr_erase_line $S(cr) $S(cc) $last
            } elseif {$p1 == 1} {
                scr_erase_line $S(cr) 0 $S(cc)
            } else {
                scr_erase_line $S(cr) 0 $last
            }
        }
        default { }
    }
    scr_clamp
}
proc scr_feed {data} {
    global S
    set s "$S(pend)$data"
    set S(pend) ""
    set n [string length $s]
    set i 0
    while {$i < $n} {
        if {[regexp -start $i -indices {[\000-\037\177]} $s m]} {
            set p [lindex $m 0]
        } else {
            set p $n
        }
        if {$p > $i} {
            scr_put [string range $s $i [expr {$p - 1}]]
            set i $p
            continue
        }
        set ch [string index $s $i]
        switch -- $ch {
            "\r" { set S(cc) 0; set S(wrap) 0; incr i }
            "\n" - "\013" - "\014" { scr_lf; set S(wrap) 0; incr i }
            "\b" { if {$S(cc) > 0} { incr S(cc) -1 }; set S(wrap) 0; incr i }
            "\t" {
                set c [expr {($S(cc) / 8 + 1) * 8}]
                if {$c > $S(cols) - 1} { set c [expr {$S(cols) - 1}] }
                set S(cc) $c; incr i
            }
            "\033" {
                if {$i + 1 >= $n} { set S(pend) [string range $s $i end]; return }
                set nx [string index $s [expr {$i + 1}]]
                if {$nx eq "\["} {
                    set rest [string range $s [expr {$i + 2}] [expr {$i + 64}]]
                    if {[regexp {^([0-?]*)([ -/]*)([@-~])} $rest all params inter final]} {
                        scr_csi $params $final
                        set i [expr {$i + 2 + [string length $all]}]
                    } elseif {[regexp {^[0-?]*[ -/]*$} $rest] && [string length $rest] < 60} {
                        set S(pend) [string range $s $i end]; return
                    } else {
                        set i [expr {$i + 2}]
                    }
                } elseif {$nx eq "\]"} {
                    set a [string first "\007" $s [expr {$i + 2}]]
                    set b [string first "\033\\" $s [expr {$i + 2}]]
                    if {$a < 0 && $b < 0} {
                        if {$n - $i < 4096} { set S(pend) [string range $s $i end]; return }
                        set i [expr {$i + 2}]
                    } elseif {$b < 0 || ($a >= 0 && $a < $b)} {
                        set i [expr {$a + 1}]
                    } else {
                        set i [expr {$b + 2}]
                    }
                } elseif {$nx eq "(" || $nx eq ")"} {
                    if {$i + 2 >= $n} { set S(pend) [string range $s $i end]; return }
                    set i [expr {$i + 3}]
                } else {
                    switch -- $nx {
                        7 { set S(sr) $S(cr); set S(sc) $S(cc) }
                        8 { set S(cr) $S(sr); set S(cc) $S(sc); set S(wrap) 0; scr_clamp }
                        M { scr_ri }
                        D { scr_lf }
                        E { scr_lf; set S(cc) 0 }
                        c { scr_init $S(rows) $S(cols) }
                        default { }
                    }
                    set i [expr {$i + 2}]
                }
            }
            default { incr i }
        }
    }
}
proc scr_feed_queue {} {
    global scrq
    set q $scrq
    set scrq ""
    scr_feed $q
}
proc scr_resize_lines {lines oldrows r c cr} {
    # returns {lines newcr}
    set out {}
    foreach l $lines {
        if {[string length $l] > $c} {
            set l [string range $l 0 [expr {$c - 1}]]
        } else {
            append l [string repeat " " [expr {$c - [string length $l]}]]
        }
        lappend out $l
    }
    if {$cr >= $r} {
        set drop [expr {$cr - $r + 1}]
        set out [lrange $out $drop end]
        set cr [expr {$cr - $drop}]
    }
    set out [lrange $out 0 [expr {$r - 1}]]
    while {[llength $out] < $r} { lappend out [string repeat " " $c] }
    return [list $out $cr]
}
proc scr_resize {r c} {
    global S
    set res [scr_resize_lines $S(lines) $S(rows) $r $c $S(cr)]
    set S(lines) [lindex $res 0]; set S(cr) [lindex $res 1]
    if {$S(alt)} {
        set res [scr_resize_lines $S(main) $S(rows) $r $c $S(msr)]
        set S(main) [lindex $res 0]; set S(msr) [lindex $res 1]
    }
    set S(rows) $r; set S(cols) $c
    set S(wrap) 0
    scr_clamp
}
proc scr_snap {name} {
    global S statf
    scr_feed_queue
    set dir [file dirname $statf]
    set base [file rootname [file tail $statf]]
    set path [file join $dir "$base.snap-$name.txt"]
    set f [open $path w]
    fconfigure $f -encoding utf-8
    foreach l $S(lines) { puts $f [string trimright $l " "] }
    close $f
    stset "snap.$name" $path
    stset "cursor.$name" "[expr {$S(cr) + 1}],[expr {$S(cc) + 1}]"
    flush_status
}

# ---- the child -------------------------------------------------------------
set stty_init "rows $rows columns $cols"
if {[catch {log_file -a $rawf} err]} {
    puts stderr "drive.exp: cannot log to $rawf: $err"
}
if {[catch {spawn -noecho {*}$cmd} err]} {
    stset rc 127
    stset end error
    stset error $err
    flush_status
    exit 127
}
set sid $spawn_id
set cpid [exp_pid -i $sid]
set slave ""
catch {set slave $spawn_out(slave,name)}
catch {fconfigure $sid -encoding utf-8}
scr_init $rows $cols
stset pid $cpid
flush_status

expect_background {
    -i $sid -re {.+} { on_data $expect_out(0,string) }
    -i $sid eof { on_eof }
}

proc sig {name pid} {
    # the bash builtin kill: /bin/kill differs between BSD and Linux and may be absent. bash 3.2
    # reads "kill -s SIG -PID" as a second signal name, so the group takes the -- form.
    set bash /bin/bash
    if {[info exists ::env(MT_BASH)] && $::env(MT_BASH) ne ""} { set bash $::env(MT_BASH) }
    catch {exec $bash -c {kill -s $1 -- -$2 2>/dev/null; kill -s $1 $2 2>/dev/null; exit 0} _ $name $pid}
}
proc hangup {} {
    global sid cpid eofseen
    sig HUP $cpid
    set end [expr {[clock milliseconds] + 2000}]
    while {!$eofseen && [clock milliseconds] < $end} { wait_event 200 }
    if {!$eofseen} {
        sig KILL $cpid
    }
}
proc finish {endkind {forcerc ""}} {
    global sid cpid eofseen
    if {$endkind ne "eof" && $endkind ne "eof-early" && !$eofseen} { hangup }
    catch {expect_background -i $sid}
    catch {close -i $sid}
    set rc 0
    if {[catch {wait -i $sid} w]} {
        set rc 1
    } else {
        set rc [lindex $w 3]
        if {[lindex $w 2] == -1} { set rc 1 }
        if {[llength $w] > 4 && [lindex $w 4] eq "CHILDKILLED"} {
            set sigs {SIGHUP 1 SIGINT 2 SIGQUIT 3 SIGILL 4 SIGTRAP 5 SIGABRT 6 SIGBUS 7 SIGFPE 8 SIGKILL 9 SIGUSR1 10 SIGSEGV 11 SIGUSR2 12 SIGPIPE 13 SIGALRM 14 SIGTERM 15}
            set sn [lindex $w 5]
            set num 0
            foreach {nm v} $sigs { if {$nm eq $sn} { set num $v } }
            set rc [expr {128 + $num}]
        }
    }
    if {$::need_screen} { catch {scr_feed_queue} }
    stset rc $rc
    stset end $endkind
    if {$::mode eq "driver"} { stset exited $rc }
    flush_status
    if {$endkind eq "idle-timeout"} { exit 124 }
    exit $rc
}
proc on_signal {} {
    global cpid
    sig HUP $cpid
    after 300
    sig KILL $cpid
    stset rc 143
    stset end signal
    flush_status
    exit 143
}
trap on_signal {SIGTERM SIGINT SIGHUP}

# ---- the sequential program ------------------------------------------------
proc seq_wait {tag re secs} {
    global buf bufbase seqpos eofseen
    set deadline [expr {[clock milliseconds] + int($secs * 1000)}]
    while {1} {
        set from [expr {$seqpos - $bufbase}]
        if {$from < 0} { set from 0 }
        if {![catch {regexp -start $from -indices -- $re $buf m} ok] && $ok} {
            set me [lindex $m 1]
            set seqpos [expr {$bufbase + $me + 1}]
            stset "wait.$tag" [bytes_at $seqpos]
            flush_status
            return ok
        }
        if {$eofseen} { return eof }
        set left [expr {$deadline - [clock milliseconds]}]
        if {$left <= 0} { return timeout }
        if {$left > 1000} { set left 1000 }
        wait_event $left
    }
}
set hostn 0
set quietn 0
proc run_program {} {
    global program sid seqpos idle hostn quietn slave cpid eofseen
    foreach fl $program {
        set op [lindex $fl 0]
        switch -- $op {
            wait {
                set tag [lindex $fl 1]; set re [lindex $fl 2]; set secs [lindex $fl 3]
                if {$secs eq ""} { set secs $idle }
                set r [seq_wait $tag $re $secs]
                if {$r eq "eof"} {
                    stset waitfail $tag
                    finish eof-early
                }
                if {$r eq "timeout"} {
                    stset waitfail $tag
                    flush_status
                    set end [expr {[clock milliseconds] + 3000}]
                    while {!$eofseen && [clock milliseconds] < $end} { wait_event 200 }
                    finish wait-timeout
                }
            }
            send {
                if {$eofseen} { continue }
                catch {exp_send -i $sid -- [keys [lindex $fl 1]]}
            }
            sleep { wait_ms [lindex $fl 1] }
            hold {
                set k [keys [lindex $fl 1]]; set count [lindex $fl 2]; set gap [lindex $fl 3]
                for {set j 0} {$j < $count} {incr j} {
                    if {$eofseen} { break }
                    catch {exp_send -i $sid -- $k}
                    wait_ms $gap
                }
            }
            quiet {
                set ms [lindex $fl 1]; set name [lindex $fl 2]
                incr quietn
                if {$name eq ""} { set name $quietn }
                set start [clock milliseconds]
                set before $::rawbytes
                set limit [expr {$start + $idle * 1000}]
                set last $start
                while {1} {
                    set now [clock milliseconds]
                    if {$now - $last >= $ms} { break }
                    if {$now >= $limit} { break }
                    set r [wait_event [expr {$ms - ($now - $last)}]]
                    if {$r eq "data"} { set last [clock milliseconds] }
                    if {$r eq "eof"} { break }
                }
                stset "quiet.$name.bytes" [expr {$::rawbytes - $before}]
                stset "quiet.$name.ms" [expr {[clock milliseconds] - $start}]
                flush_status
            }
            resize {
                set r [lindex $fl 1]; set c [lindex $fl 2]
                scr_feed_queue
                scr_resize $r $c
                if {$slave ne ""} { catch {exec stty rows $r columns $c < $slave} }
                sig WINCH $cpid
            }
            snap { scr_snap [lindex $fl 1] }
            mark {
                set seqpos [abs_len]
                stset "mark.[lindex $fl 1]" [bytes_at $seqpos]
                flush_status
            }
            eof {
                set secs [lindex $fl 1]
                if {$secs eq ""} { set secs $idle }
                set end [expr {[clock milliseconds] + int($secs * 1000)}]
                while {!$eofseen && [clock milliseconds] < $end} { wait_event 500 }
                if {!$eofseen} {
                    stset waitfail eof
                    finish wait-timeout
                }
            }
            host {
                incr hostn
                set hc [lindex $fl 1]
                send_log "\n__MT_HOST_${hostn}_BEGIN__\n"
                set bash /bin/bash
                if {[info exists ::env(MT_BASH)] && $::env(MT_BASH) ne ""} { set bash $::env(MT_BASH) }
                set envf ""
                if {[info exists ::env(MT__ENVF)]} { set envf $::env(MT__ENVF) }
                set hrc 0
                if {[catch {exec $bash -c {if [ -n "$1" ] && [ -f "$1" ]; then . "$1" >/dev/null 2>&1; fi; eval "$2"} _ $envf $hc 2>@1} out]} {
                    set hrc 1
                    if {[lindex $::errorCode 0] eq "CHILDSTATUS"} { set hrc [lindex $::errorCode 2] }
                }
                regsub {\n?child process exited abnormally$} $out {} out
                send_log "$out\n__MT_HOST_${hostn}_END__ rc=$hrc\n"
                stset "host.$hostn.rc" $hrc
                flush_status
            }
            default { }
        }
    }
}

# ---- run -------------------------------------------------------------------
if {$mode eq "driver"} {
    set ctlseen 0
    while {!$eofseen} {
        wait_event 300
        if {$ctlf eq "" || ![file exists $ctlf]} { continue }
        if {[catch {set fh [open $ctlf r]; fconfigure $fh -encoding utf-8; set data [read $fh]; close $fh}]} { continue }
        set lines [split $data "\n"]
        set total [llength $lines]
        if {[lindex $lines end] eq ""} { incr total -1 }
        while {$ctlseen < $total} {
            set line [lindex $lines $ctlseen]
            incr ctlseen
            set fl [split $line "\t"]
            switch -- [lindex $fl 0] {
                send { if {!$eofseen} { catch {exp_send -i $sid -- [keys [lindex $fl 1]]} } }
                answer {
                    set tag [lindex $fl 1]; set ks [lindex $fl 2]
                    set new {}
                    set found 0
                    foreach r $rules {
                        if {[lindex $r 0] eq $tag} { set r [lreplace $r 2 4 $ks 1 ""]; set fired($tag) 0; set found 1 }
                        lappend new $r
                    }
                    set rules $new
                }
                quit { finish quit }
                default { }
            }
        }
    }
    finish eof
}
run_program
# The reactive loop: rules until EOF, or IDLE seconds without output. Tcl's timers follow the
# wall clock, which runs on while the Mac sleeps: after a sleep the timer is overdue at once and
# a command that never hung would end as idle-timeout. A wait that ended more than a minute later
# than IDLE is that case: the loop waits again (five times at most).
set slept 0
while {!$eofseen} {
    set w0 [clock milliseconds]
    if {[wait_event [expr {$idle * 1000}]] eq "timeout"} {
        set late [expr {[clock milliseconds] - $w0 - $idle * 1000}]
        if {$late > 60000 && $slept < 5} {
            incr slept
            stset slept "$slept, the last [expr {$late / 1000}] s"
            continue
        }
        finish idle-timeout
    }
}
finish eof
MT__DRIVE_EOF
}
mt__match_tcl() {
  cat <<'MT__MATCH_EOF'
# match.tcl RULES TEXT STATE: the first catalogue prompt in TEXT after what was already answered.
# Prints TAG<TAB>KEYS<TAB>LINE and exits 0, or exits 1. STATE keeps the consumed offset and the
# fired counts (T1 typed mode's answerer, egress-release.sh).
foreach {rulesf textf statef} $argv break
encoding system utf-8
set consumed 0
array set fired {}
if {[file exists $statef]} {
    set f [open $statef r]
    foreach l [split [read $f] "\n"] {
        set fl [split $l " "]
        if {[lindex $fl 0] eq "consumed"} { set consumed [lindex $fl 1] }
        if {[lindex $fl 0] eq "fired"} { set fired([lindex $fl 1]) [lindex $fl 2] }
    }
    close $f
}
if {![string is integer -strict $consumed]} { set consumed 0 }
set f [open $textf r]
fconfigure $f -encoding utf-8
set text [string trimright [read $f]]
close $f
set f [open $rulesf r]
fconfigure $f -encoding utf-8
set rules [split [read $f] "\n"]
close $f
foreach line $rules {
    set fl [split $line "\t"]
    if {[lindex $fl 0] ne "rule"} { continue }
    set tag [lindex $fl 1]; set re [lindex $fl 2]; set keys [lindex $fl 3]; set max [lindex $fl 4]; set flags [lindex $fl 5]
    if {[string first manual $flags] >= 0} { continue }
    if {![info exists fired($tag)]} { set fired($tag) 0 }
    if {[string is integer -strict $max] && $max > 0 && $fired($tag) >= $max} { continue }
    if {[catch {regexp -start $consumed -indices -- $re $text m} ok] || !$ok} { continue }
    set s [lindex $m 0]; set e [lindex $m 1]
    if {$e < $s} { continue }
    set a [string last "\n" $text $s]
    set b [string first "\n" $text $e]
    if {$b < 0} { set b [string length $text] }
    set lt [string trim [string range $text [expr {$a + 1}] [expr {$b - 1}]]]
    incr fired($tag)
    set f [open $statef w]
    puts $f "consumed $b"
    foreach k [array names fired] { puts $f "fired $k $fired($k)" }
    close $f
    puts "$tag\t$keys\t$lt"
    exit 0
}
exit 1
MT__MATCH_EOF
}
mt__refusing_sh() {
  cat <<'MT__REFUSING_EOF'
# refusing.sh WT: the names the refusing-boxes note would list right now, one per line.
# The rule is _egress_refusing_boxes_note's (bin/cleat:13146 at ac6ee85) without its printing.
# Run by egress-release.sh under MT_BASH with XDG_CONFIG_HOME set to the run's config.
cd "$1" || exit 1
. ./bin/cleat > /dev/null 2>&1 || exit 1
set +e +u
set +o pipefail 2>/dev/null
[ "$_EGRESS_ENFORCING" = 1 ] || exit 0
_daemon_up || exit 0
_egress_engine_validated "$(_egress_engine_kind)" || exit 0
docker ps -a --filter "name=^cleat-" --format '{{.Names}}' 2>/dev/null | while IFS= read -r n; do
  [ -n "$n" ] || continue
  meta="$(docker inspect --format '{{range $k, $v := .Config.Labels}}{{if eq $k "sh.cleat.role"}}ROLE={{$v}}{{end}}{{end}}|{{range $k, $v := .Config.Labels}}{{if eq $k "sh.cleat.egress-hash"}}HASH{{end}}{{end}}|{{range .Mounts}}{{if eq .Destination "/workspace"}}{{.Source}}{{end}}{{end}}|{{index .Config.Labels "sh.cleat.box"}}|{{.Config.Image}}' "$n" 2>/dev/null)" || continue
  role="${meta%%|*}"; meta="${meta#*|}"
  lbl="${meta%%|*}"; meta="${meta#*|}"
  img="${meta##*|}"
  case "$img" in "$IMAGE_NAME"|"$IMAGE_NAME":*|"$REGISTRY_BASE"|"$REGISTRY_BASE":*|"$REGISTRY_BASE"@*) ;; *) continue ;; esac
  case "$role" in ROLE=|ROLE=box|"") ;; *) continue ;; esac
  [ "$lbl" = HASH ] && continue
  ( _egress_resolve "$n" ) > /dev/null 2>&1 || continue
  _egress_resolve "$n" > /dev/null 2>&1
  case "$_EG_MODE" in strict|open) printf '%s\n' "$n" ;; esac
done
exit 0
MT__REFUSING_EOF
}
