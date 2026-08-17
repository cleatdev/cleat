# Mutual exclusion for everything that reads or executes the working tree while
# the mutation harness is rewriting it.
#
# WHY THIS EXISTS. The harness rewrites nine tracked files IN PLACE (bin/cleat,
# install.sh, test.sh, test/setup.bash, test/integration/lifecycle.bats and the
# four docker/ shims), mutation by mutation. Anything reading them meanwhile
# sees sabotaged or half-written source and fails for reasons unrelated to any
# change: the bash32 mutation puts `local -A` on line 2, so every sourced test
# dies with "local: -A: invalid option" on macOS bash 3.2, and a truncated read
# gives "syntax error: unexpected end of file" at a different offset each time.
# From the other side the harness sees its tests pass against source someone
# else restored underneath it, and reports a wall of false MISSED.
#
# WHY IT LIVES IN THE REPO. A checkout bind-mounted into a container is shared
# with the host, but /tmp is not. That cross-machine case is the one that
# actually bit: a harness run inside a Cleat box and a suite run on the Mac,
# same files, neither able to see the other's temp dir.
#
# WHY A PID IS NOT ENOUGH. pid 4242 in a container is unrelated to pid 4242 on
# the host, so liveness is probed ONLY when the hostname matches. A lock held
# by another machine is judged by age alone, and the message says so instead of
# pretending to know.
#
# Callers must define _CLEAT_TEST_LOCK_ROOT (the cli/ directory) before
# sourcing, or set _CLEAT_TEST_LOCK_DIR outright (tests do).

_CLEAT_TEST_LOCK="${_CLEAT_TEST_LOCK_DIR:-${_CLEAT_TEST_LOCK_ROOT:-.}/.test-suite.lock}"
_CLEAT_TEST_LOCK_STALE_SECS="${_CLEAT_TEST_LOCK_STALE_SECS:-7200}"

_tl_now()  { date +%s 2>/dev/null || echo 0; }
_tl_host() { hostname 2>/dev/null || echo unknown; }

# Print why we cannot proceed, then leave. Callers arrange to have written
# NOTHING before this point.
_tl_refuse() {   # owner-record
  local owner="$1"
  echo "" >&2
  echo "  Refusing to start: ${owner:-another run} holds the test lock." >&2
  echo "" >&2
  echo "  The mutation harness rewrites bin/cleat and the shipped scripts in" >&2
  echo "  place, so running anything against this checkout at the same time" >&2
  echo "  makes BOTH report failures that are not real. This checkout may be" >&2
  echo "  shared with a container or another machine, which is where it bites" >&2
  echo "  hardest: same files, different /tmp, neither run able to see the" >&2
  echo "  other." >&2
  echo "" >&2
  echo "  Wait for that run, or if you are certain it is dead:" >&2
  echo "    rm -rf $_CLEAT_TEST_LOCK" >&2
  echo "" >&2
  exit 1
}

# True when the recorded owner is provably gone. An UNREADABLE or unparseable
# record is deliberately NOT stale: a winner that has created the directory but
# not yet written the record would otherwise be robbed by the next arrival,
# which is a race both runners win.
_tl_owner_is_stale() {   # owner-record
  local owner="$1" o_host o_pid o_at age
  [[ -n "$owner" ]] || return 1
  o_host="$(printf '%s' "$owner" | sed -n 's/.* host \(.*\) pid .*/\1/p')"
  o_pid="$(printf '%s'  "$owner" | sed -n 's/.* pid \([0-9][0-9]*\) at .*/\1/p')"
  o_at="$(printf '%s'   "$owner" | sed -n 's/.* at \([0-9][0-9]*\)$/\1/p')"
  [[ -n "$o_pid" && -n "$o_at" ]] || return 1

  age=$(( $(_tl_now) - o_at ))
  # A clock running BACKWARDS relative to the writer (a container hours behind
  # its host was observed in this very project) yields a negative age. Treat
  # that as fresh, never as expired, or one machine steals the other's live
  # lock.
  (( age < 0 )) && return 1
  # An age backstop applies on EVERY host, not just a foreign one: a pid can be
  # recycled, and without this a reused pid wedges the checkout forever.
  (( age > _CLEAT_TEST_LOCK_STALE_SECS )) && return 0

  if [[ "$o_host" == "$(_tl_host)" ]]; then
    kill -0 "$o_pid" 2>/dev/null && return 1
    return 0
  fi
  # Another machine, within the age window: assume alive. We cannot probe it.
  return 1
}

_take_test_lock() {   # label
  local label="$1" owner="" tries=0
  while (( tries < 3 )); do
    if mkdir "$_CLEAT_TEST_LOCK" 2>/dev/null; then
      echo "${label} host $(_tl_host) pid $$ at $(_tl_now)" \
        > "$_CLEAT_TEST_LOCK/owner" 2>/dev/null || true
      return 0
    fi
    owner="$(cat "$_CLEAT_TEST_LOCK/owner" 2>/dev/null || true)"
    _tl_owner_is_stale "$owner" || _tl_refuse "$owner"

    # Claim the RIGHT to clear it before clearing it. Exactly one process can
    # rename a given directory; everyone else gets ENOENT and loops round to
    # find the lock either gone or freshly held. `rm -rf` followed by `mkdir`
    # has no such property: every racer removes and every racer recreates.
    if mv "$_CLEAT_TEST_LOCK" "${_CLEAT_TEST_LOCK}.stale.$$" 2>/dev/null; then
      rm -rf "${_CLEAT_TEST_LOCK}.stale.$$" 2>/dev/null || true
    fi
    tries=$(( tries + 1 ))
  done
  _tl_refuse "$owner"
}

_drop_test_lock() {
  [[ -f "$_CLEAT_TEST_LOCK/owner" ]] || return 0
  # Match the whole triple, not a bare pid: pid 42 must not release pid 4242's
  # lock, and a foreign host's identical pid must not release ours.
  case "$(cat "$_CLEAT_TEST_LOCK/owner" 2>/dev/null || true)" in
    *" host $(_tl_host) pid $$ at "*) rm -rf "$_CLEAT_TEST_LOCK" 2>/dev/null || true ;;
  esac
}
