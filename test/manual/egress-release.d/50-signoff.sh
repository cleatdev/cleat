# egress-release.d/50-signoff.sh: sign-off: 5.1 to 5.5 (owed items, the record draft, the decision, the report).
#
# A part of egress-release.sh. Sourced, never run. It holds only function definitions, reg calls
# and comments: nothing else runs at source time. One function per step, named st_ plus the id
# with . and - turned into _, registered in scenario order with
#   reg ID SITTING KIND CLASS FUNC "TITLE"
# The steps are DESIGN.md section 6.2 (sign-off) with the contracts of section 7. A helper this
# part needs that the library lacks is written here, prefixed p50_.
#
# What the five steps write, all inside the run dir (never the repo, never the docs):
#   signoff/5.1-owed.md        5.1: the scenario's 5.1 table, filled with what this run knows
#   signoff/5.2-record.md      5.2: the scenario's 5.2 block: the run paragraph, the fifteen rows,
#                              the integration B line and the two G2 lines
#   signoff/5.3-concept46.md   5.3: the concept/46 paragraph
#   signoff/5.4-summary.md     5.4: every step with its status
#   signoff/5.4-fixes.md       5.4: the fixes table of the scenario with the steps that confirm each
#   signoff/5.4-decision.md    5.4: the scenario's 5.4 checklist, a box ticked only when its steps passed
#   record-draft.md            5.2 and 5.3 assembled and redacted: the file to copy from
#   decision.md                5.4's summary, 5.1, the fixes and the checklist assembled and redacted
#   report.md                  5.5 (report_write)
# Each step reads results.tsv and kv only, rewrites its own section and assembles both files
# again, so any of them can run again at any time (--only 5.2 regenerates the draft).
#
# Rules this part follows. Where it departs from DESIGN.md, the scenario wins:
#   - A step's status is the last line results.tsv holds for it. Only PASS passes. SKIP, ERROR, a
#     cut attempt and a step not run all leave a box unticked and a fix unconfirmed. The one
#     exception: a re-entry skip whose note says the earlier attempt's result stands (1.1b-*, 1.2a,
#     2.27a) keeps the last PASS or FAIL before it (p50_load).
#   - The 5.4 checklist is the scenario's thirteen rows verbatim (DESIGN 7.4 merged three of them).
#     Rows that are no hand test on the Mac (CI, 5.1 complete, release notes) stay unticked: by
#     hand. Rows with a hand part (filing, the reword) tick their steps and leave the hand part open.
#   - W3 and Review: surfaces count 2.10a with 2.10c. The scenario's "2.10 (quiet)" covers the
#     gateway down (2.10a checks it) and just restarted by Docker (2.10c). DESIGN 7.3 named 2.10c.
#   - An EXTRA named in a fix (P50_F_PART) leaves the fix "partly confirmed" when it did not run,
#     which keeps the checklist row "Every fix ... confirmed" unticked (DESIGN 7.3). No fix names
#     one now: W10's 2.15 a reads (the Hosts row, no Pinned: row) are repeated by gate 2.15b, so a
#     default run (gates only) confirms W10 and the gap never surfaces after 3.5 removed eg-smoke.
#   - "When it ran" (3.2 in W4, W5 and row 14, an extra of sitting 1 in its row): a step that ran
#     must have passed. One that did not run changes nothing.
#   - A row of 5.2 that did not pass shows it in Result and opens its Notes with NOT PASSED, so a
#     reading a failed attempt wrote is never filed as a pass.
#   - The record draft quotes no command output. It is built from the rec.*, c46.* and reading
#     values the steps wrote as shapes, then redacted (daily boxes, login, emails, UUIDs, tokens,
#     home paths). Then the step counts what must never be in it (a daily box name, the login, the
#     git identity, an email, a UUID, a token, a home path) and fails when one is.
#   - 5.4 fails when a checklist row its steps decide is not ticked or a fix is not confirmed, so
#     --report lists what holds the tag. A failing 5.4 is the decision "hold", not a crash.
#   - 5.1 reads CI with gh run view, read-only, when gh is installed and logged in. It never pushes
#     or dispatches. Without gh the row says: check by hand.
#   - 5.5 copies ~/mt-egress-readings.txt into the run dir, then asks before deleting it (keep is
#     the first answer), so "the run dir keeps a copy" holds whatever the answer.
#
# Expected strings: this part checks no product output. Its reminders quote three product
# strings, each read in bin/cleat at ac6ee85: "Refresh the image and recreate <box> now? [Y/n]"
# (bin/cleat:6861), "Refresh the image now?" (bin/cleat:6952) and "The core pack has not yet been
# validated against a real Claude Code session." (bin/cleat:12533).
#
# Helpers (p50_): p50_ci_run, p50_ci_repo, p50_cert, p50_is_int, p50_find, p50_load, p50_stv,
# p50_word, p50_eval, p50_span, p50_ymd, p50_need, p50_kvq, p50_cell, p50_sentence, p50_andsep,
# p50_cut, p50_firsts, p50_row_steps, p50_row_opt, p50_row_notes, p50_answer, p50_chk, p50_secs,
# p50_cv_after, p50_gwref, p50_vadd,
# p50_verdict, p50_verdicts_emit, p50_leaks, p50_put, p50_assemble, p50_fix_ids, p50_fix,
# p50_fix_seen, p50_ci_parse, p50_gen_owed, p50_gen_record, p50_gen_c46, p50_gen_summary,
# p50_gen_fixes, p50_gen_decision, p50_row_done. The one command they run (gh run view) goes
# through mt__probe, so a hung gh is a note, never a failed check.

# ---------------------------------------------------------------------------------------------
# Constants (functions, so nothing runs at source time)
# ---------------------------------------------------------------------------------------------

# The CI run 5.1 reads: the one p50_ci_pick chose, else the run dispatched on 197bfe9 (ac6ee85
# plus the script, 2026-10-03), which 5.1 then reads as another commit's when HEAD carries other code.
p50_ci_default() { printf '37105999785'; }
p50_ci_run() { printf '%s' "${P50_CI_RUN:-$(p50_ci_default)}"; }
p50_ci_repo() { printf 'cleatdev/cleat'; }
p50_cert() { printf 'ac6ee85'; }

p50_is_int() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac; return 0; }
# p50_secs VALUE: "N s" for a whole number of seconds, else the value as the step recorded it
# (never, unreadable).
p50_secs() { if p50_is_int "${1:-}"; then printf '%s s' "$1"; else printf '%s' "${1:-?}"; fi; }

# ---------------------------------------------------------------------------------------------
# Statuses from results.tsv
# ---------------------------------------------------------------------------------------------

# p50_find ID: its registry index into P50_I (-1 and rc 1 when it is not registered).
p50_find() {
  local i=0
  P50_I=-1
  while [ "$i" -lt "${#R_ID[@]}" ]; do
    if [ "${R_ID[$i]}" = "$1" ]; then P50_I=$i; return 0; fi
    i=$((i + 1))
  done
  return 1
}

# p50_load: every registered step's last line in results.tsv into P50_ST (pending when it has
# none), P50_ATT (that line's attempt), P50_T0 and P50_T1 (its start and end, epoch seconds),
# P50_NOTE. Also P50_D, the sign-off directory, made on demand.
# One exception to "the last line": a re-entry skip whose note says the earlier attempt's result
# stands (1.1b-prep to 1.1b-check, 1.2a and 2.27a print one when their state already exists) keeps
# the last PASS or FAIL before it, as its own message promises. Without one it stays SKIP.
p50_load() {
  local i id st att t0 t1 note f
  P50_D="$RUN/signoff"
  mkdir -p "$P50_D" || fatal "cannot create $P50_D"
  P50_ST=(); P50_ATT=(); P50_T0=(); P50_T1=(); P50_NOTE=()
  i=0
  while [ "$i" -lt "${#R_ID[@]}" ]; do
    P50_ST[$i]=pending; P50_ATT[$i]=0; P50_T0[$i]=""; P50_T1[$i]=""; P50_NOTE[$i]=""
    i=$((i + 1))
  done
  [ -f "$RUN/results.tsv" ] || return 0
  f="$P50_D/.results.$$"
  LC_ALL=C awk -F'\t' 'NR > 1 && $2 != "" {
      id = $2
      if (!(id in seen)) { seen[id] = 1; o[++n] = id }
      if ($4 == "SKIP" && (id in kst) && (index($9, "result stands") || index($9, "checks stand in that attempt") || index($9, "its checks are in that attempt"))) {
        st[id] = kst[id]; at[id] = kat[id]; t0[id] = kt0[id]; t1[id] = kt1[id]; nt[id] = knt[id]
        next
      }
      st[id] = $4; at[id] = $3; t0[id] = $5; t1[id] = $6; nt[id] = $9
      if ($4 == "PASS" || $4 == "FAIL") { kst[id] = $4; kat[id] = $3; kt0[id] = $5; kt1[id] = $6; knt[id] = $9 }
    }
    END { for (k = 1; k <= n; k++) { id = o[k]; printf "%s\037%s\037%s\037%s\037%s\037%s\n", id, st[id], at[id], t0[id], t1[id], nt[id] } }' "$RUN/results.tsv" > "$f"
  while IFS=$'\037' read -r id st att t0 t1 note; do
    [ -n "$id" ] || continue
    p50_find "$id" || continue
    P50_ST[$P50_I]="$st"; P50_ATT[$P50_I]="$att"; P50_T0[$P50_I]="$t0"; P50_T1[$P50_I]="$t1"; P50_NOTE[$P50_I]="$note"
  done < "$f"
  rm -f "$f"
  return 0
}

# p50_stv ID: its status into P50_S (missing when the registry has no such step).
p50_stv() {
  if p50_find "$1"; then P50_S="${P50_ST[$P50_I]}"; else P50_S=missing; fi
}

# p50_word STATUS: the status as the drafts say it.
p50_word() {
  case "$1" in
    pending) printf 'not run' ;;
    STARTED) printf 'cut short' ;;
    INTERRUPTED) printf 'interrupted' ;;
    RESET) printf 'to run again' ;;
    DRY) printf 'dry run' ;;
    missing) printf 'not registered' ;;
    *) printf '%s' "$1" ;;
  esac
}

# p50_eval REQUIRED [WHEN-RAN] [EXTRAS]: the verdict of a set of steps into P50_V (pass, partial
# or fail), P50_WHY (what did not pass) and P50_IDS (every step with its status).
#   REQUIRED  each must be PASS
#   WHEN-RAN  each counts only when it ran (not pending, SKIP or missing), then it must be PASS
#   EXTRAS    each must be PASS when it ran. One that did not run makes the verdict partial
p50_eval() {
  local id ids="" bad="" part=0 w seen=" "
  for id in $1; do
    case "$seen" in *" $id "*) continue ;; esac
    seen="$seen$id "
    p50_stv "$id"; w=$(p50_word "$P50_S")
    ids="$ids${ids:+, }$id $w"
    [ "$P50_S" = PASS ] || bad="$bad${bad:+, }$id $w"
  done
  for id in ${2:-}; do
    case "$seen" in *" $id "*) continue ;; esac
    seen="$seen$id "
    p50_stv "$id"
    case "$P50_S" in pending|SKIP|missing) continue ;; esac
    w=$(p50_word "$P50_S")
    ids="$ids${ids:+, }$id $w"
    [ "$P50_S" = PASS ] || bad="$bad${bad:+, }$id $w"
  done
  for id in ${3:-}; do
    case "$seen" in *" $id "*) continue ;; esac
    seen="$seen$id "
    p50_stv "$id"; w=$(p50_word "$P50_S")
    case "$P50_S" in
      PASS) ids="$ids${ids:+, }$id PASS" ;;
      pending|SKIP|missing) part=1; ids="$ids${ids:+, }$id $w (an EXTRA)" ;;
      *) ids="$ids${ids:+, }$id $w"; bad="$bad${bad:+, }$id $w" ;;
    esac
  done
  P50_IDS="$ids"; P50_WHY="$bad"
  if [ -n "$bad" ]; then P50_V=fail
  elif [ "$part" = 1 ]; then P50_V=partial
  else P50_V=pass; fi
  return 0
}

# p50_ymd EPOCH: YYYY-MM-DD in UTC (days from civil, inverted, in awk: no date -r or date -d).
p50_ymd() {
  p50_is_int "$1" || return 0
  awk -v e="$1" 'BEGIN {
    z = int(e / 86400) + 719468; era = int(z / 146097); doe = z - era * 146097
    yoe = int((doe - int(doe / 1460) + int(doe / 36524) - int(doe / 146096)) / 365)
    y = yoe + era * 400; doy = doe - (365 * yoe + int(yoe / 4) - int(yoe / 100))
    mp = int((5 * doy + 2) / 153); d = doy - int((153 * mp + 2) / 5) + 1
    if (mp < 10) m = mp + 3; else m = mp - 9
    if (m <= 2) y = y + 1
    printf "%04d-%02d-%02d\n", y, m, d
  }'
}

# p50_span IDS: the days those steps ran ("D" or "D1 to D2"), from the attempt each one's status
# comes from. Steps not run or skipped add no day. Empty when none ran.
p50_span() {
  local id lo="" hi="" a b
  for id in $1; do
    p50_find "$id" || continue
    case "${P50_ST[$P50_I]}" in pending|SKIP) continue ;; esac
    a="${P50_T0[$P50_I]}"; b="${P50_T1[$P50_I]}"
    p50_is_int "$a" || continue
    p50_is_int "$b" || b="$a"
    if [ -z "$lo" ] || [ "$a" -lt "$lo" ]; then lo="$a"; fi
    if [ -z "$hi" ] || [ "$b" -gt "$hi" ]; then hi="$b"; fi
  done
  [ -n "$lo" ] || return 0
  a=$(p50_ymd "$lo"); b=$(p50_ymd "$hi")
  if [ "$a" = "$b" ]; then printf '%s' "$a"; else printf '%s to %s' "$a" "$b"; fi
}

# ---------------------------------------------------------------------------------------------
# Text
# ---------------------------------------------------------------------------------------------

# p50_need VAR KEY STEP: kv KEY into VAR, or "<not recorded: STEP>" (and KEY joins P50_MISS).
p50_need() {
  local p50__nv
  p50__nv=$(kv_get "$2" "")
  if [ -z "$p50__nv" ]; then
    P50_MISS="${P50_MISS:-}${P50_MISS:+, }$2 ($3)"
    p50__nv="<not recorded: $3>"
  fi
  printf -v "$1" '%s' "$p50__nv"
}
# p50_kvq KEY: the value, or a question mark.
p50_kvq() {
  local v
  v=$(kv_get "$1" "")
  printf '%s' "${v:-?}"
}
# p50_cell TEXT: one markdown table cell (one line, a pipe escaped).
p50_cell() {
  printf '%s' "$1" | tr '\t\r\n' '   ' | sed 's/|/\\|/g'
}
# p50_sentence TEXT: TEXT trimmed, ending in a full stop.
p50_sentence() {
  local s="$1"
  s="${s%"${s##*[![:space:]]}"}"
  [ -n "$s" ] || return 0
  case "$s" in
    *.|*'!'|*'?') printf '%s' "$s" ;;
    *) printf '%s.' "$s" ;;
  esac
}
# p50_firsts "A, B, C" N: the first N items of a comma list, then how many more.
p50_firsts() {
  printf '%s' "$1" | awk -v n="$2" '{ k = split($0, a, ", "); o = ""; for (i = 1; i <= k && i <= n; i++) o = o (i > 1 ? ", " : "") a[i]; if (k > n) o = o " and " (k - n) " more"; printf "%s", o }'
}
# p50_andsep "A|B|C": "A", "A and B", "A, B and C" (no serial comma: the repo's writing rule).
p50_andsep() {
  printf '%s' "$1" | awk -F'|' '{ for (i = 1; i <= NF; i++) { if (i > 1) printf "%s", (i == NF ? " and " : ", "); printf "%s", $i } }'
}
# p50_cut TEXT N: TEXT on one line, at most N characters.
p50_cut() {
  local s
  s=$(printf '%s' "$1" | tr '\t\r\n' '   ')
  if [ "${#s}" -gt "$2" ]; then s="${s:0:$2}..."; fi
  printf '%s' "$s"
}
# p50_gwref: the gateway reference cut after 8 hex characters of its digest (scenario 5.2).
p50_gwref() {
  local g="${GWIMG:-}" d
  [ -n "$g" ] || g=$(kv_get gwimg.ref "")
  case "$g" in
    *@sha256:*) d="${g#*@sha256:}"; printf '%s@sha256:%s...' "${g%%@sha256:*}" "$(printf '%s' "$d" | cut -c1-8)" ;;
    '') printf '<not recorded: 0.6>' ;;
    *) printf '%s' "$g" ;;
  esac
}

# p50_cv_after: the Claude Code version sitting 3 ran on, when 2.29 ran and its upgrade-claude left
# another version than 0.5 recorded (kv image.claude.after holds claude --version's first line).
# Empty otherwise: then every step ran on image.claude.
p50_cv_after() {
  local a b
  p50_stv 2.29
  case "$P50_S" in pending|SKIP|missing) return 0 ;; esac
  a=$(kv_get image.claude.after "" | awk '{ print $1; exit }')
  b=$(kv_get image.claude "")
  case "$a" in [0-9]*.[0-9]*.[0-9]*) ;; *) return 0 ;; esac
  [ "$a" = "$b" ] || printf '%s' "$a"
}

# ---------------------------------------------------------------------------------------------
# The fifteen rows of 5.2 (DESIGN 7.2) and their notes
# ---------------------------------------------------------------------------------------------

# p50_row_steps N: the steps that must pass for row N. p50_row_opt N: those that count when they ran.
p50_row_steps() {
  case "$1" in
    1) printf '2.1' ;; 2) printf '2.2' ;; 3) printf '2.3 2.8' ;; 4) printf '2.4a 2.4b 2.4c' ;;
    5) printf '2.5' ;; 6) printf '2.6' ;; 7) printf '2.7a 2.7b 2.7c' ;; 8) printf '2.8' ;;
    9) printf '2.9a 2.9b' ;; 10) printf '2.10a 2.10b 2.10c' ;; 11) printf '3.3a 3.3b' ;;
    12) printf '2.11a 2.11b' ;; 13) printf '2.12' ;; 14) printf '3.1a 3.1b 3.1c 3.1d 3.1e' ;;
    15) printf '3.4ev 3.4lid 3.4am 3.4dd' ;;
  esac
}
p50_row_opt() {
  case "$1" in 14) printf '3.2' ;; esac
}
# p50_row_notes N: the values of kv rec.row<N>.<step>, in registry order, as sentences. A step that
# counts only when it ran (3.2 in row 14) adds nothing while its status says it did not run, so a
# reading an earlier attempt left is never filed beside a skip.
p50_row_notes() {
  local n="$1" k id idx out="" s f opt
  opt=" $(p50_row_opt "$n") "
  f="$P50_D/.rows.$$"
  : > "$f"
  for k in $(kv_list "rec.row$n."); do
    id="${k#"rec.row$n."}"
    case "$opt" in
      *" $id "*) p50_stv "$id"; case "$P50_S" in pending|SKIP|missing) continue ;; esac ;;
    esac
    if p50_find "$id"; then idx=$P50_I; else idx=99999; fi
    printf '%s\t%s\n' "$idx" "$k" >> "$f"
  done
  for k in $(sort -n "$f" | cut -f2); do
    s=$(p50_sentence "$(kv_get "$k" "")")
    [ -n "$s" ] && out="$out${out:+ }$s"
  done
  rm -f "$f"
  printf '%s' "$out"
}

# p50_answer ID TAG: "STATUS<TAB>GOT<TAB>DESC" of the first check whose description starts with
# [TAG] in the attempt ID's status comes from. rc 1 when there is none.
p50_answer() {
  local att f
  p50_find "$1" || return 1
  att="${P50_ATT[$P50_I]}"
  f="$RUN/steps/$1/a$att/checks.tsv"
  [ -f "$f" ] || return 1
  MT_T="[$2]" awk -F'\t' 'BEGIN { t = ENVIRON["MT_T"] } index($3, t) == 1 { print $2 "\t" $5 "\t" $3; f = 1; exit } END { exit (f ? 0 : 1) }' "$f"
}

# p50_chk ID TEXT: the checks whose description holds TEXT, in the attempt ID's status comes from,
# into P50_C: pass (at least one, none failed), fail (one failed) or none (no such check there).
p50_chk() {
  local f
  P50_C=none
  p50_find "$1" || return 0
  f="$RUN/steps/$1/a${P50_ATT[$P50_I]}/checks.tsv"
  [ -f "$f" ] || return 0
  P50_C=$(MT_T="$2" LC_ALL=C awk -F'\t' 'BEGIN { t = ENVIRON["MT_T"] } index($3, t) { n++; if ($2 == "FAIL" || $2 == "TIMEOUT" || $2 == "HUMAN-FAIL") b++ } END { if (n == 0) print "none"; else if (b) print "fail"; else print "pass" }' "$f")
  return 0
}

# ---------------------------------------------------------------------------------------------
# Verdicts into checks, leak checks, files
# ---------------------------------------------------------------------------------------------

# p50_vadd VERDICT DESC WHY: one verdict for the step's checks (written by p50_verdicts_emit).
# VERDICT is pass, partial, fail, hand (no step decides it) or note (information only).
p50_vadd() {
  printf '%s\037%s\037%s\n' "$1" "$2" "$(printf '%s' "${3:-}" | tr '\t\n\037' '   ')" >> "$STEP_DIR/p50-verdicts"
}
p50_verdict() {
  if [ "${DRY:-0}" = 1 ]; then
    case "$1" in hand|note) check_note "$2" ;; *) expect_eq "$2" "$1" pass ;; esac
    return 0
  fi
  case "$1" in
    pass) check_pass "$2" "${3:-}" ;;
    partial) check_note "$2: partly confirmed (${3:-})" ;;
    hand) check_note "$2: by hand${3:+ ($3)}" ;;
    note) check_note "$2${3:+: $3}" ;;
    *) check_fail "$2" "every step PASS" "${3:-}" ;;
  esac
  return 0
}
p50_verdicts_emit() {
  local f="$STEP_DIR/p50-verdicts" v desc why
  [ -f "$f" ] || return 0
  while IFS=$'\037' read -r v desc why; do
    [ -n "$v" ] || continue
    p50_verdict "$v" "$desc" "$why"
  done < "$f"
  rm -f "$f"
  return 0
}

# p50_leaks FILE LABEL [public]: what must never be in FILE. Counts are recorded, never the
# matches. public adds the home path check (the record draft goes to the public repo).
p50_leaks() {
  local f="$1" what="$2" n=0 d u gn ge
  if [ ! -f "$f" ]; then check_fail "$what exists" "the file" "no file $f"; return 0; fi
  for d in $(kv_get daily.names ""); do
    [ -n "$d" ] || continue
    if LC_ALL=C grep -F -q -e "$d" "$f" 2>/dev/null; then n=$((n + 1)); fi
  done
  expect_eq "$what names no daily box (names found)" "$n" 0
  u=$(id -un 2>/dev/null)
  n=0
  if [ -n "$u" ] && LC_ALL=C grep -i -w -F -q -e "$u" "$f" 2>/dev/null; then n=1; fi
  expect_eq "$what holds no login name (lines found)" "$n" 0
  gn=$(GIT_OPTIONAL_LOCKS=0 git -C "$MT_WT" config user.name 2>/dev/null)
  ge=$(GIT_OPTIONAL_LOCKS=0 git -C "$MT_WT" config user.email 2>/dev/null)
  n=0
  if [ -n "$gn" ] && LC_ALL=C grep -F -q -e "$gn" "$f" 2>/dev/null; then n=$((n + 1)); fi
  if [ -n "$ge" ] && LC_ALL=C grep -F -q -e "$ge" "$f" 2>/dev/null; then n=$((n + 1)); fi
  expect_eq "$what holds no git identity (found)" "$n" 0
  expect_not_match "$what holds no email address" '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z][A-Za-z]+' "$f"
  expect_not_match "$what holds no UUID" '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}' "$f"
  expect_not_match "$what holds no token" 'sk-ant-|eyJ[A-Za-z0-9_-]{8}' "$f"
  if [ "${3:-}" = public ]; then
    expect_not_contains "$what holds no home path" "$HOME/" "$f"
    expect_not_match "$what holds no /Users/<name> path" '/Users/[^/ ]+/' "$f"
  fi
  return 0
}

# p50_put NAME: stdin into signoff/NAME, atomically.
p50_put() {
  cat > "$P50_D/.$1.$$" && mv -f "$P50_D/.$1.$$" "$P50_D/$1"
}

# p50_assemble: record-draft.md (5.2, 5.3) and decision.md (5.4's summary, 5.1, the fixes, 5.4)
# from the sections that exist, each through redact.
p50_assemble() {
  local t="$P50_D/.assemble.$$" s
  {
    printf '# The record draft for docs/egress-validation.md and concept/46\n\n'
    printf 'Run %s, candidate %s. Assembled %s UTC by egress-release.sh from the run'"'"'s results and readings.\n' "$RUNID" "$(kv_get cand.short "?")" "$(utc_stamp)"
    printf 'Nothing here is in the repo: copy it by hand after reading it. A row that did not pass says so in its\n'
    printf 'Result and opens its Notes with NOT PASSED. A value in angle brackets was not recorded. Make it again\n'
    printf '(--only '"'"'5.*'"'"') before you edit docs/egress-validation.md in the candidate: a tracked change there\n'
    printf 'stops every later step of this run.\n'
    for s in 5.2-record.md 5.3-concept46.md; do
      printf '\n'
      if [ -f "$P50_D/$s" ]; then cat "$P50_D/$s"; else printf '(%s has not run yet: ./egress-release.sh --only %s)\n' "${s%%-*}" "${s%%-*}"; fi
    done
  } > "$t"
  redact < "$t" > "$RUN/.record-draft.md.$$" && mv -f "$RUN/.record-draft.md.$$" "$RUN/record-draft.md"
  {
    printf '# The release decision of the egress control release test\n\n'
    printf 'Run %s, candidate %s. Assembled %s UTC by egress-release.sh from the run'"'"'s results and readings.\n' "$RUNID" "$(kv_get cand.short "?")" "$(utc_stamp)"
    printf 'A box is ticked only when every step behind it passed. By hand means no step of this run can decide it.\n'
    if [ -f "$P50_D/decision-line.txt" ]; then printf '\n**Decision.** %s\n' "$(cat "$P50_D/decision-line.txt")"; fi
    for s in 5.4-summary.md 5.1-owed.md 5.4-fixes.md 5.4-decision.md; do
      printf '\n'
      if [ -f "$P50_D/$s" ]; then cat "$P50_D/$s"; else printf '(%s has not run yet: ./egress-release.sh --only %s)\n' "${s%%-*}" "${s%%-*}"; fi
    done
  } > "$t"
  redact < "$t" > "$RUN/.decision.md.$$" && mv -f "$RUN/.decision.md.$$" "$RUN/decision.md"
  rm -f "$t"
  return 0
}

# ---------------------------------------------------------------------------------------------
# The fixes of the scenario (EGRESS-RELEASE-TEST.md, "The fixes to confirm on the Mac": cbb4297's
# W1 to W12 and the review's rows, then ac6ee85's F1 to F5) and the steps behind each. The checks
# of F1 to F5 carry "(Fn)" in their descriptions, which p50_fix_seen reads.
# ---------------------------------------------------------------------------------------------

p50_fix_ids() { printf '%s\n' W1 W2 W3 W4 W5 W6 W7 W8 W9 W10 W11 W12 destroy relay surfaces late F1 F2 F3 F4 F5; }

# p50_fix ID: P50_F_NAME, P50_F_CIN (the scenario's "Confirmed in"), P50_F_REQ, P50_F_OPT (when
# it ran), P50_F_PART (EXTRAs) and P50_F_NOW (the scenario's "PASS now", shortened).
p50_fix() {
  P50_F_OPT=""; P50_F_PART=""; P50_F_NAME="$1"
  case "$1" in
    W1) P50_F_CIN="2.20"; P50_F_REQ="2.20a 2.20b 2.20c 2.20d"
        P50_F_NOW="On a terminal the refusal prints before any \`Recreate ... now? [Y/n]\`, rc 1, the box still there on \`none\` with its gateway. The same for a stopped box and for \`cleat run\` on it" ;;
    W2) P50_F_CIN="2.18"; P50_F_REQ="2.18a 2.18b"
        P50_F_NOW="Variant b: at least one \`supervisor started again in place\` line or a \`--again\` process. Variant a: bash's give-up line in the relay log while the same heartbeat loop lives on. Both: \`Shim listening\` again after the hold with no \`restart --shim\`" ;;
    W3) P50_F_CIN="2.16 (named), 2.10 (quiet)"; P50_F_REQ="2.16b 2.16c 2.10a 2.10c"
        P50_F_NOW="2.16: \`! shim not listening (not a denial)\` under \`Egress:\` and the four lines at session end. 2.10: nothing about the relay while the gateway is down or just restarted by Docker" ;;
    W4) P50_F_CIN="3.1, 3.2"; P50_F_REQ="3.1c"; P50_F_OPT="3.2"
        P50_F_NOW="Every state a quit leaves is named by status. The box's exit code and the gateway's \`StartedAt\` are recorded, never the gateway's exit code alone" ;;
    W5) P50_F_CIN="2.9, 2.17 d, 3.1, 3.2"; P50_F_REQ="2.9b 2.17d 3.1d 3.1e"; P50_F_OPT="3.2"
        P50_F_NOW="No \`Shim not listening\` at any of those launches. The relay starts within a few seconds of the box, whatever \`~/.claude\` holds" ;;
    W6) P50_F_CIN="3.1, 3.4"; P50_F_REQ="3.1c 3.4am 3.4dd"
        P50_F_NOW="\`CreatedAt\` and both labels unchanged under a live box" ;;
    W7) P50_F_CIN="1.1b, 1.3, 1.4, 2.11, 2.25"; P50_F_REQ="1.1b-shell 1.3b 1.4a 1.4b 2.11a 2.25c 2.25d"
        P50_F_NOW="Four in a caged shell and in a caged \`[setup]\`, none in an uncaged shell. No Datadog intake host and no \`mcp-proxy.anthropic.com\` in any session-end report. Remote Control refuses in a caged box. claude.ai connectors and the Artifact tool are off" ;;
    W8) P50_F_CIN="2.24 d to f"; P50_F_REQ="2.24d 2.24e 2.24f"
        P50_F_NOW="One question whatever the answer, never \`Refresh the image now?\` after it. A refresh that still lacks the relay refuses with the box kept" ;;
    W9) P50_F_CIN="2.21 c, 2.24 b"; P50_F_REQ="2.21c 2.24b"
        P50_F_NOW="2.21 c: the drop ends with the two running lines. 2.24 b: the eg-old row ends in \`running\`, then \`It is running, so it keeps its full network until it stops.\` and \`A session already open in it is not caged.\` (the plural forms of Conventions when daily boxes are listed too)" ;;
    W10) P50_F_CIN="2.7, 2.15 a, 2.16, 2.17 e, 2.25 a"; P50_F_REQ="2.7b 2.15b 2.16b 2.17e 2.25a"
        P50_F_NOW="\`last seen <age> ago, no heartbeat since\`, \`Hosts:\` and \`allowed, but the name did not resolve, or none of its addresses from the last 60 seconds answered\`" ;;
    W11) P50_F_CIN="0.3"; P50_F_REQ="0.3"
        P50_F_NOW="egkind reads \`desktop-macos\`" ;;
    W12) P50_F_CIN="2.14, 2.27 c"; P50_F_REQ="2.14a 2.14b 2.27c"
        P50_F_NOW="At Terminal.app's 80 columns one \`Capabilities\` header, no drift, both rows whole" ;;
    destroy) P50_F_NAME="Review: destroy"; P50_F_CIN="2.24 e, h and j"; P50_F_REQ="2.24e 2.24h 2.24j"
        P50_F_NOW="A declined refresh followed by moved host paths refuses naming \`cleat rebuild\`. A gateway image that cannot be pulled refuses before the box goes. A box whose policy was removed refuses naming \`cleat egress off\`. The box is kept every time" ;;
    relay) P50_F_NAME="Review: relay"; P50_F_CIN="2.16 a, 2.18"; P50_F_REQ="2.16a 2.18a 2.18b"
        P50_F_NOW="A healthy box shows one supervisor line, one \`--beats\` loop and the listener socat, with no \`--again\`. After 2.18 b only the supervisor reads \`--again\`, never its loop" ;;
    surfaces) P50_F_NAME="Review: surfaces"; P50_F_CIN="2.10, 2.16"; P50_F_REQ="2.10a 2.10c 2.16b 2.16c"
        P50_F_NOW="As W3. The fork change has nothing to see" ;;
    late) P50_F_NAME="Late fix"; P50_F_CIN="1.2, 2.24 b"; P50_F_REQ="1.2a 2.24b"
        P50_F_NOW="No row for the site preview container or for any other container that is not a box" ;;
    F1) P50_F_CIN="1.2, 2.24 h"; P50_F_REQ="1.2b 2.24h"
        P50_F_NOW="The gateway image lines are plain text: \`Pulling the egress gateway image (ghcr.io/cleatdev/cleat-gw, <arch>)\` and \`✔ Egress gateway image ready (ghcr.io/cleatdev/cleat-gw)\`, never \`\\033[2m\` or \`\\033[0m\` shown as text" ;;
    F2) P50_F_CIN="1.3, 2.15 i"; P50_F_REQ="1.3b"; P50_F_OPT="2.15i"
        P50_F_NOW="\`/home/coder/.npm\` in a caged box belongs to the box user. npm in the box works, never EACCES on it" ;;
    F3) P50_F_CIN="1.3, 2.11"; P50_F_REQ="1.3b 2.11a 2.11b"; P50_F_OPT="2.11-repo2"
        P50_F_NOW="A caged box names itself in its \`/etc/hosts\`. No \`sudo: unable to resolve host\` line from \`sudo -i\` or from a \`[setup]\` line run with sudo" ;;
    F4) P50_F_CIN="2.27 c"; P50_F_REQ="2.27c"
        P50_F_NOW="One Enter on the Egress row of \`cleat config\` prints exactly one \`Saved to\` line" ;;
    F5) P50_F_CIN="3.1, 3.2, 3.4"; P50_F_REQ="3.1b 3.1e 3.4dd"; P50_F_OPT="3.2"
        P50_F_NOW="A session whose box stopped or whose Docker quit never ends with \`Out of memory. The box hit its memory ceiling\`" ;;
    *) fatal "p50_fix: no fix $1" ;;
  esac
}

# p50_fix_seen ID: what the Mac showed for the fix, from the readings its steps recorded (empty
# when they recorded none).
p50_fix_seen() {
  local a b c out=""
  case "$1" in
    W2)
      a=$(kv_get step18b.again ""); b=$(kv_get step18a.listen ""); c=$(kv_get step18b.listen "")
      [ -n "$a" ] && out="supervisor started again in place: $a (2.18b)"
      if [ -n "$b$c" ]; then out="$out${out:+, }Shim listening again after the hold: $(p50_secs "$b") (2.18a), $(p50_secs "$c") (2.18b)"; fi ;;
    W3|surfaces)
      a=$(kv_get step16b.status_line ""); b=$(kv_get step16b.secs ""); c=$(kv_get step10.window "")
      [ -n "$a" ] && out="cleat status read: $a"
      [ -n "$b" ] && out="$out${out:+, }the row turned $b s after the kill (2.16b)"
      [ -n "$c" ] && out="$out${out:+, }the restart Docker made (2.10c): $c" ;;
    W4)
      a=$(kv_get step14.case "")
      b=$(kv_get step14.w4 "")
      case "$a:$b" in
        clean:*) out="a plain quit left both containers stopped, so the gateway was not orphaned ($(p50_kvq step14.clean))" ;;
        w4:*"gateway running=true"*) out="a plain quit left the box at exit 255. The daemon started the gateway again without its box, so it was orphaned ($b)" ;;
        w4:*) out="a plain quit left the box at exit 255. The gateway stayed stopped, so it was not orphaned (${b:-?})" ;;
        :*) ;;
        *) out="a plain quit left neither the clean case nor the W4 case ($a)" ;;
      esac
      b=$(kv_get step14.unclean "")
      [ -n "$b" ] && out="$out${out:+. }The unclean half (3.2): $b" ;;
    W5)
      a=$(kv_get step9.relay_latency ""); b=$(kv_get step17d.pause "")
      [ -n "$a" ] && out="the relay started after the box: $(p50_secs "$a") (2.9b)"
      [ -n "$b" ] && out="$out${out:+, }the resume beside an orphaned gateway took $(p50_secs "$b") (2.17d)" ;;
    W6)
      for c in 3.1c 3.4am 3.4dd; do
        p50_chk "$c" "(W6)"
        case "$P50_C" in
          pass) out="$out${out:+, }$c unchanged" ;;
          fail) out="$out${out:+, }$c CHANGED or unread" ;;
        esac
      done
      [ -z "$out" ] || out="the socket volume's CreatedAt and labels: $out" ;;
    W7)
      a=$(kv_get step12.env_count ""); b=$(kv_get g2.c.remote_msg "")
      [ -n "$a" ] && out="$a of 4 settings in the caged [setup] (2.11a)"
      [ -n "$b" ] && out="$out${out:+, }Remote Control: $b" ;;
    W8)
      a=$(kv_get c46.upgrade_question "")
      [ -n "$a" ] && out="the one question: $a" ;;
    W9)
      # step21c.dropped is 2.21c's own 0/1 marker, never a reading: its (W9) checks say what showed.
      a=$(kv_get rec.upgrade.w9 "")
      p50_chk 2.21c "(W9)"
      case "$P50_C" in
        pass) out="2.21c: the drop printed both running lines" ;;
        fail) out="2.21c: a running line was missing from the drop" ;;
        *) p50_stv 2.21c; [ "$P50_S" = PASS ] && out="2.21c: the drop ran in an earlier attempt" ;;
      esac
      [ -n "$a" ] && out="$out${out:+, }2.24b: $a" ;;
    W10)
      a=$(kv_get step7.secs ""); b=$(kv_get step15.hosts_row "")
      [ -n "$a" ] && out="the stale row turned $a s after the chown (2.7b)"
      [ -n "$b" ] && out="$out${out:+, }status read \`$b\` (2.15b)" ;;
    W11)
      a=$(kv_get egress.kind "")
      [ -n "$a" ] && out="egkind read $a" ;;
    W12)
      a=$(kv_get c46.pickers_keys "")
      [ -n "$a" ] && out="real keys: $a" ;;
    destroy)
      a=$(kv_get rec.upgrade.e ""); b=$(kv_get rec.upgrade.h ""); c=$(kv_get rec.upgrade.j "")
      [ -n "$a" ] && out="e: $a"
      [ -n "$b" ] && out="$out${out:+. }h: $b"
      [ -n "$c" ] && out="$out${out:+. }j: $c" ;;
    relay)
      # The counts of p31_shim_sum (sup again beats socat), never its pids or the relay's name.
      a=$(kv_get step16a.shim_before ""); b=$(kv_get step18b.shim_after "")
      a="${a%% relay=*}"; b="${b%% relay=*}"
      [ -n "$a" ] && out="a healthy box read $a (2.16a)"
      [ -n "$b" ] && out="$out${out:+, }after the hold of 2.18b $b" ;;
    late)
      a=$(kv_get note.1.2.count "")
      [ -n "$a" ] && out="the first allow's note listed $a boxes (1.2a)" ;;
    F1|F2|F3|F4|F5)
      # Each step's checks tagged (Fn): a step that took a path without them adds nothing.
      p50_fix "$1"
      for c in $P50_F_REQ $P50_F_OPT; do
        p50_chk "$c" "($1)"
        case "$P50_C" in
          pass) out="$out${out:+, }$c as fixed" ;;
          fail) out="$out${out:+, }$c SHOWED THE OLD BEHAVIOUR" ;;
        esac
      done
      case "$1" in
        F2) a=$(kv_get step13b.npm ""); [ -n "$a" ] && out="$out${out:+. }/home/coder/.npm read $a (1.3b)" ;;
        F4) a=$(kv_get step27c.saved ""); [ -n "$a" ] && out="$out${out:+. }the Saved lines: $a (2.27c)" ;;
      esac ;;
  esac
  printf '%s' "$out"
}

# ---------------------------------------------------------------------------------------------
# The generators (each prints a section to stdout and runs no command)
# ---------------------------------------------------------------------------------------------

# p50_ci_pick CANDFULL: the newest test.yml run on egress-dev whose commit carries the certified
# code into P50_CI_RUN and P50_CI_SHA. That is the certified commit itself, or one that differs from
# it only in the script's own files, either way round (a script fix pushed after the run, or a run
# dispatched after a script fix). None: the newest run, which 5.1 reads as another commit's. gh
# unable to list: the default run. Read-only (gh run list), bounded by the probe.
p50_ci_pick() {
  local cand="$1" id sha first="" list
  P50_CI_RUN=""; P50_CI_SHA=""
  say "\$ gh run list -R $(p50_ci_repo) --branch egress-dev --workflow test.yml   (read-only, at most 60 s)"
  mt__probe 60 gh run list -R "$(p50_ci_repo)" --branch egress-dev --workflow test.yml --limit 30 \
    --json databaseId,headSha --jq '.[] | "\(.databaseId)\t\(.headSha)"' || return 0
  list="$MT__PROBE_OUT"
  while IFS=$'\t' read -r id sha; do
    [ -n "$id" ] && [ -n "$sha" ] || continue
    [ -n "$first" ] || first="$id"
    if [ "$sha" = "$cand" ] \
      || cand_plus_script "$MT_WT" "$sha" "$cand" > /dev/null 2>&1 \
      || cand_plus_script "$MT_WT" "$cand" "$sha" > /dev/null 2>&1; then
      P50_CI_RUN="$id"; P50_CI_SHA="$sha"
      return 0
    fi
  done < "$list"
  [ -z "$first" ] || P50_CI_RUN="$first"
  return 0
}

# p50_ci_parse FILE CANDFULL: the CI reading into P50_CI_V (green, red, running, other, unread)
# and P50_CI_TXT. FILE holds gh's lines: run<TAB>status<TAB>conclusion<TAB>sha, job<TAB>name<TAB>status<TAB>conclusion.
p50_ci_parse() {
  local f="$1" cand="$2" st co sha n bad mac macbad
  P50_CI_V=unread; P50_CI_TXT=""
  [ -s "$f" ] || return 0
  st=$(awk -F'\t' '$1 == "run" { print $2; exit }' "$f")
  co=$(awk -F'\t' '$1 == "run" { print $3; exit }' "$f")
  sha=$(awk -F'\t' '$1 == "run" { print $4; exit }' "$f")
  [ -n "$st" ] || return 0
  n=$(awk -F'\t' '$1 == "job" { k++ } END { print k + 0 }' "$f")
  bad=$(awk -F'\t' '$1 == "job" && $4 != "success" && $4 != "skipped" && $4 != "neutral" { printf "%s%s (%s %s)", (k++ ? ", " : ""), $2, $3, ($4 == "" ? "no conclusion" : $4) }' "$f")
  mac=$(awk -F'\t' '$1 == "job" && tolower($2) ~ /macos/ { k++ } END { print k + 0 }' "$f")
  macbad=$(awk -F'\t' '$1 == "job" && tolower($2) ~ /macos/ && $4 != "success" { k++ } END { print k + 0 }' "$f")
  if [ -n "$cand" ] && [ "$sha" != "$cand" ]; then
    P50_CI_V=other
    P50_CI_TXT="run $(p50_ci_run) is on $(printf '%s' "$sha" | cut -c1-7), not on the certified $(printf '%s' "$cand" | cut -c1-7). By hand: push the certified commit to egress-dev, then gh workflow run test.yml --ref egress-dev and wait for every job"
    return 0
  fi
  if [ "$st" != completed ]; then
    P50_CI_V=running
    P50_CI_TXT="run $(p50_ci_run) on $(printf '%s' "$sha" | cut -c1-7) reads $st (jobs: $n). Read it again later: ./egress-release.sh --only 5.1"
    return 0
  fi
  if [ "$co" = success ] && [ -z "$bad" ] && [ "$mac" = 0 ]; then
    P50_CI_V=other
    P50_CI_TXT="run $(p50_ci_run) on $(printf '%s' "$sha" | cut -c1-7) completed success (jobs: $n), but no job names macOS: check the macOS leg by hand"
  elif [ "$co" = success ] && [ -z "$bad" ]; then
    P50_CI_V=green
    P50_CI_TXT="green: run $(p50_ci_run) on $(printf '%s' "$sha" | cut -c1-7) completed success, $n jobs with none failed, $mac of them on macOS. Read $(utc_stamp) UTC with gh run view"
  else
    P50_CI_V=red
    P50_CI_TXT="NOT green: run $(p50_ci_run) on $(printf '%s' "$sha" | cut -c1-7) concluded ${co:-without a conclusion}. Jobs that did not succeed: ${bad:-none listed}. macOS jobs not green: $macbad of $mac"
  fi
  return 0
}

# p50_gen_owed: the table of the scenario's 5.1 with what this run knows, then its two reminders.
p50_gen_owed() {
  local t a b cand cv date
  cand=$(kv_get cand.short "?")
  printf '## 5.1 Owed before the tag, not a hand test on the Mac\n\n'
  printf '| Item | Status |\n|---|---|\n'
  printf '| CI green on the pushed candidate, every job. The macOS leg matters most | %s |\n' "$(p50_cell "${P50_CI_TXT:-check by hand: gh run view $(p50_ci_run) -R $(p50_ci_repo)}")"
  printf '| The two gateway soaks of 8.1 (300 concurrent tunnels, then 3,000 s at about 10,000 CONNECTs a second, plus the allow-log and heartbeat variants) | %s |\n' \
    "owed: this script does not run them. Run them before the tag or waive them in writing (then the caps and the heartbeat interval stay NOT-MEASURABLE, no public number, 2.19 is the only load evidence and the soaks move to the stage-four list)"
  printf '| The resolver never yielding a mapped IPv6 candidate (Appendix B, still inferred) | %s |\n' "owed: no hand test here. By hand"
  p50_stv 2.30
  case "$P50_S" in
    PASS) t="measured in 2.30 after the box removed its own hook: the delete mid-session showed: $(p50_kvq rail.midsession) (a prompt: Claude Code read the settings again, no prompt: the session kept its hook). PermissionRequest lines after the resume: $(p50_kvq rail.after_resume) (1 or more: the resume put the hook back). It fixes the rail residual's wording only" ;;
    pending|SKIP|missing) t="2.30 $(p50_word "$P50_S"): run it (./egress-release.sh --only 2.30) or waive it in writing" ;;
    *) t="2.30 $(p50_word "$P50_S"): read its checks, then run it again or waive it in writing" ;;
  esac
  printf '| Whether a box can disarm its own unsafe-rm guard (2.30) | %s |\n' "$(p50_cell "$t")"
  p50_stv 2.24a
  a=$(kv_get rec.upgrade.r63 "")
  printf '| R6-3 per-box image-spec check: built, or deferred in writing | %s |\n' "$(p50_cell "by hand: built or deferred in writing. The evidence, 2.24a $(p50_word "$P50_S"): ${a:-not recorded}")"
  p50_eval "1.1b-shell 1.3b 1.4a 1.4b 2.11a 2.25c 2.25d"
  if [ "$P50_V" = pass ]; then t="confirmed on the Mac: $P50_IDS"; else t="NOT confirmed: $P50_WHY. All: $P50_IDS"; fi
  printf '| W7: the paired settings of spec 7.3 are wired. Their cost, Remote Control refusing in a caged box, is recorded in concept/46 | %s |\n' "$(p50_cell "$t. Remote Control in 2.25c: $(p50_kvq g2.c.remote_msg). The concept/46 entry: by hand")"
  p50_stv 2.7b
  t="2.7b $(p50_word "$P50_S"), the two-hops record not found"
  a=$(p50_answer 2.7b two-hops)
  if [ -n "$a" ]; then
    b=$(printf '%s' "$a" | cut -f1)
    case "$b" in
      HUMAN-PASS) t="2.7b: you said the two hops read clearly (the row's own fix cleat egress restart --shim, then cleat egress restart)" ;;
      NOTE) t="2.7b: you said they did not read clearly: $(printf '%s' "$a" | cut -f3 | sed 's/^.*: no\. //')" ;;
      *) t="2.7b: not answered ($b)" ;;
    esac
  fi
  printf '| The relay row heading Shim not listening for a socket that refuses the box uid while the relay listens (2.7) | %s |\n' "$(p50_cell "$t. Accept it in writing or retitle it: by hand")"
  p50_eval "2.13a 2.13b"
  printf '| test/manual/verify.sh egress picker scenario (11.8) | %s |\n' "$(p50_cell "not built. 2.13 stands in this release: $P50_IDS")"
  printf '| Docs: the Docker floor in docs/cli.md, docs.astro and the README, the README paragraph, the cleat --help example naming both doors, the R6-5 site audit. docs/cli.md checked against what the Mac printed. docs.astro, the README, ROADMAP.md and site/RELEASE.md carry what section 4 lists | %s |\n' "by hand"
  a=$(kv_get rec.suite.linux ""); b=$(kv_get rec.suite.mac "")
  t="by hand in ROADMAP.md and site/RELEASE.md. On Linux: ${a:-not recorded}. On the Mac: ${b:-not recorded}"
  case "$cand" in
    "$(p50_cert)"*|'?') ;;
    *)
      # ac6ee85 plus the script: the later commits add only test/manual/egress-release*, which no
      # test and no CI job runs, so ac6ee85's counts are the certified commit's.
      if [ "$(kv_get cand.desc "")" = "$(p50_cert) plus the script" ]; then
        t="$t. They are for $(p50_cert): the certified $cand adds only the script, which no test runs"
      else
        t="$t. The Linux counts are for $(p50_cert), not for the certified $cand: count it"
      fi ;;
  esac
  printf '| Counts for the certified commit in ROADMAP.md and site/RELEASE.md | %s |\n' "$(p50_cell "$t")"
  p50_eval "2.25a 2.25b 2.25c 2.25d"
  cv=$(kv_get image.claude "")
  date=$(p50_span "2.25c")
  if [ "$P50_V" = pass ]; then
    t="2.25 passed on ${date:-?}: before the tag reword it with its tests, naming Claude Code ${cv:-<version>} and that date, for example: The core pack was checked against Claude Code ${cv:-<version>} on ${date:-<date>}. Never remove it"
  else
    t="2.25 did not pass ($P50_WHY): the line stays as it is (The core pack has not yet been validated against a real Claude Code session.). A G2 failure is a core-pack change decided in writing before the tag"
  fi
  printf '| _egress_unmeasured_line reworded with its tests, naming the Claude Code version and date, if 2.25 passed. Never removed | %s |\n' "$(p50_cell "$t")"
  printf '| Merge egress-dev into main (a fast-forward of 41 commits plus 2a831dc, cbb4297, 68f1153, ac6ee85 and the commit that adds this script) | %s |\n' "your call"
  printf '| EGRESS-CATALOGUE.md:10 still says egress is not enforced | %s |\n' "set aside with the catalogue: a reminder only"
  printf '\n**After the tag (W8).** First check after publishing the image: on a Mac holding a v1.5.4 box and the\n'
  printf 'v1.5.4 image, `cleat` on a terminal asks `Refresh the image and recreate <box> now? [Y/n]` once. A yes\n'
  printf 'leaves the image-spec label at 6, the box on `none` and Claude caged. `Refresh the image now?` never\n'
  printf 'appears. The release notes name the one question.\n'
  printf '\n**Section 4 of the scenario.** What the release notes and the site may and may not say: read it before\n'
  printf 'writing either. Stage three claims nothing in public. "Under validation", never "validated".\n'
}

# p50_gen_record: the scenario's 5.2 block, filled in. Notes P50_MISS and writes the row verdicts.
p50_gen_record() {
  local sha br ver mac arch bashv plat eng api vmm fs kind huid hgid buid spec cv nv nr na ns gw
  local archnote span all n ids opt res notes date intb okn walls d1 st kindw cva
  P50_MISS=""
  p50_need sha cand.short 0.1
  br=$(kv_get cand.branch "")
  [ -n "$br" ] || br=egress-stage3
  ver=$(sed -n 's/^VERSION="\(.*\)"$/\1/p' "$MT_WT/bin/cleat" 2>/dev/null | head -n 1)
  [ -n "$ver" ] || ver="?"
  p50_need mac host.macos 0.3
  p50_need arch host.arch 0.3
  bashv=$(kv_get host.bash "" | sed -n 's/.*version \([0-9][0-9.]*\).*/\1/p' | head -n 1)
  if [ -z "$bashv" ]; then P50_MISS="${P50_MISS}${P50_MISS:+, }host.bash (0.3)"; bashv="<not recorded: 0.3>"; fi
  p50_need plat docker.platform 0.3
  case "$plat" in "Docker Desktop"*) ;; *) plat="Docker Desktop $plat" ;; esac
  p50_need eng docker.engine 0.3
  p50_need api docker.api 0.3
  p50_need vmm dd.vmm 0.3
  p50_need fs dd.fileshare 0.3
  p50_need kind egress.kind 0.3
  p50_need huid host.uid 0.3
  p50_need hgid host.gid 0.3
  p50_need buid box.uid 2.7a
  p50_need spec image.spec 0.5
  p50_need cv image.claude 0.5
  p50_need nv image.node 0.5
  p50_need nr step4.netraw 2.4c
  p50_need na step4.all 2.4c
  p50_need ns step4.seccomp 2.4c
  gw=$(p50_gwref)
  p50_stv 2.31
  case "$P50_S" in
    PASS) archnote="the amd64 gateway started once under emulation (2.31): health $(p50_kvq amd64.health), platform.machine() $(p50_kvq amd64.machine), $(p50_kvq amd64.ids), policy digest $(p50_kvq amd64.digest)" ;;
    pending|SKIP|missing) archnote="$arch only" ;;
    *) archnote="$arch only (2.31 ran and did not pass: $(p50_word "$P50_S"))" ;;
  esac
  all=""
  n=1
  while [ "$n" -le 15 ]; do all="$all $(p50_row_steps "$n") $(p50_row_opt "$n")"; n=$((n + 1)); done
  span=$(p50_span "$all")
  case "$kind" in desktop-macos) kindw="Docker Desktop for macOS" ;; *) kindw="Docker Desktop, engine kind $kind" ;; esac
  printf '## 5.2 The record for docs/egress-validation.md\n\n'
  printf 'Above the results table (line 19 is already fixed in the candidate, W11):\n\n'
  printf '### Run of %s, %s\n\n' "${span:-<no step of the fifteen ran>}" "$kindw"
  printf 'Candidate cli `%s` on %s (VERSION %s until the tag). macOS %s on %s,\n' "$sha" "$br" "$ver" "$mac" "$arch"
  printf '%s. %s %s.\n' "$archnote" "$MT_BASH" "$bashv"
  printf '%s, Engine %s, API %s, %s,\n' "$plat" "$eng" "$api" "$vmm"
  printf '%s. Engine kind `%s`. Host uid %s, gid %s. Box uid %s. Image spec %s\n' "$fs" "$kind" "$huid" "$hgid" "$buid" "$spec"
  printf '(Claude Code %s, Node %s). Gateway `%s`.\n' "$cv" "$nv" "$gw"
  cva=$(p50_cv_after)
  [ -z "$cva" ] || printf 'Steps 11, 14 and 15 ran on Claude Code %s, which `cleat upgrade-claude` put in the image before sitting 3.\n' "$cva"
  printf 'Step 4 normalization: `--cap-drop NET_RAW` gives `%s`, `--cap-drop ALL` gives `%s`,\n' "$nr" "$na"
  printf '`--security-opt seccomp=unconfined` gives `%s`.\n' "$ns"
  printf '\nThen replace the `not yet run` row with these fifteen rows (the file keeps its header):\n\n'
  printf '| Date | Engine kind | Step | Result | Notes |\n|---|---|---|---|---|\n'
  P50_ROWS_OK=0; P50_ROWS_BAD=""
  n=1
  while [ "$n" -le 15 ]; do
    ids=$(p50_row_steps "$n"); opt=$(p50_row_opt "$n")
    p50_eval "$ids" "$opt"
    date=$(p50_span "$ids $opt")
    notes=$(p50_row_notes "$n")
    [ -n "$notes" ] || notes="(no reading recorded)"
    if [ "$P50_V" = pass ]; then
      if [ "$n" = 3 ]; then res=recorded; else res=PASS; fi
      P50_ROWS_OK=$((P50_ROWS_OK + 1))
    else
      res="not passed"
      case ", $P50_WHY" in *" FAIL"*|*" ERROR"*) res=FAIL ;; esac
      if [ -z "$date" ]; then res="not run"; fi
      notes="NOT PASSED: $P50_WHY. $notes"
      P50_ROWS_BAD="$P50_ROWS_BAD${P50_ROWS_BAD:+, }$n"
      p50_vadd note "row $n of 5.2 did not pass" "$P50_WHY"
    fi
    printf '| %s | %s | %s | %s | %s |\n' "$date" "$(p50_cell "$kind")" "$n" "$res" "$(p50_cell "$notes")"
    n=$((n + 1))
  done
  printf '\nBelow the table, the dated lines for the other runs:\n\n'
  printf '| Date | Run | Result | Notes |\n|---|---|---|---|\n'
  p50_stv 1.1
  st="$P50_S"
  intb=$(kv_get rec.intb "")
  okn=""
  case "$intb" in *" of 14"*) okn="${intb%% of 14*}" ;; esac
  walls=$(kv_get int.walltime "")
  d1=$(kv_get int.date "")
  [ -n "$d1" ] || d1=$(p50_span 1.1)
  case "$st" in
    PASS) res="${okn:-14} of 14" ;;
    pending|SKIP|missing) res="not run" ;;
    *) res="FAIL${okn:+ ($okn of 14)}" ;;
  esac
  printf '| %s | Integration branch B, outside any box | %s | %s |\n' "$d1" "$res" "$(p50_cell "wall time ${walls:-?} s, $sha (1.1)")"
  p50_eval "2.25a 2.25b 2.25c"
  date=$(p50_span "2.25a 2.25b 2.25c")
  notes=$(kv_get rec.g2a "")
  [ -n "$notes" ] || notes="(no reading recorded)"
  if [ "$P50_V" = pass ]; then res=PASS; else res="not passed"; notes="NOT PASSED: $P50_WHY. $notes"; fi
  printf '| %s | Core pack, login, tool turn, WebFetch (G2) | %s | %s |\n' "$date" "$res" "$(p50_cell "$notes")"
  p50_eval "2.25d"
  date=$(p50_span "2.25d")
  notes=$(kv_get rec.g2b "")
  [ -n "$notes" ] || notes="(no reading recorded)"
  if [ "$P50_V" = pass ]; then res=PASS; else res="not passed"; notes="NOT PASSED: $P50_WHY. $notes"; fi
  printf '| %s | Core pack after a live account switch (G2) | %s | %s |\n' "$date" "$res" "$(p50_cell "$notes")"
}

# p50_gen_c46: the concept/46 paragraph (scenario 5.3), one paragraph from the run's readings.
p50_gen_c46() {
  local sha ver mac arch plat eng api vmm fs kind spec cv span all n ok bad t p e k w4 id seen conf part notc
  sha=$(kv_get cand.short "?")
  ver=$(sed -n 's/^VERSION="\(.*\)"$/\1/p' "$MT_WT/bin/cleat" 2>/dev/null | head -n 1)
  mac=$(p50_kvq host.macos); arch=$(p50_kvq host.arch); plat=$(p50_kvq docker.platform)
  eng=$(p50_kvq docker.engine); api=$(p50_kvq docker.api); vmm=$(p50_kvq dd.vmm); fs=$(p50_kvq dd.fileshare)
  kind=$(p50_kvq egress.kind); spec=$(p50_kvq image.spec); cv=$(p50_kvq image.claude)
  all=""; ok=0; bad=""
  n=1
  while [ "$n" -le 15 ]; do
    all="$all $(p50_row_steps "$n") $(p50_row_opt "$n")"
    p50_eval "$(p50_row_steps "$n")" "$(p50_row_opt "$n")"
    if [ "$P50_V" = pass ]; then ok=$((ok + 1)); else bad="$bad${bad:+, }step $n ($P50_WHY)"; fi
    n=$((n + 1))
  done
  span=$(p50_span "$all")
  p="Hand run of ${span:-<not run>} on $plat (Engine $eng, API $api, $vmm, $fs), engine kind \`$kind\`, macOS $mac on $arch: candidate cli \`$sha\` (VERSION ${ver:-?} until the tag), image spec $spec with Claude Code $cv."
  t=$(p50_cv_after)
  [ -z "$t" ] || p="$p Sitting 3 (steps 11, 14 and 15) ran on Claude Code $t after 2.29's \`cleat upgrade-claude\`."
  if [ "$ok" = 15 ]; then p="$p All fifteen steps of docs/egress-validation.md passed."
  else p="$p $ok of the fifteen steps of docs/egress-validation.md passed. Not passed: $bad."; fi
  p50_stv 1.1
  if [ "$P50_S" = PASS ]; then t="Integration branch B passed 14 of 14 outside any box in $(p50_kvq int.walltime) s."
  else t="Integration branch B did not pass (1.1 $(p50_word "$P50_S")$( [ -n "$(kv_get rec.intb "")" ] && printf ': %s' "$(kv_get rec.intb "")"))."; fi
  p="$p $t"
  p50_eval "2.13a 2.13b"
  if [ "$P50_V" = pass ]; then t="The editor at 80x24 in Terminal.app passed (2.13)"; else t="The editor at 80x24 in Terminal.app did not pass (2.13: $P50_WHY)"; fi
  p="$p $t: automated items $(p50_kvq c46.editor), real keys $(p50_kvq c46.editor_keys)."
  p50_eval "2.14a 2.14b 2.14-acct"
  if [ "$P50_V" = pass ]; then t="The pickers and cleat config passed under bash 3.2 at 80 columns (2.14)"; else t="The pickers and cleat config did not pass (2.14: $P50_WHY)"; fi
  p="$p $t: real keys $(p50_kvq c46.pickers_keys), the accounts picker $(p50_kvq c46.accounts_keys)."
  p50_eval "2.24d 2.24e 2.24f 2.24g"
  if [ "$P50_V" = pass ]; then t="The upgrade asked one question each time (2.24 d to g)"; else t="The upgrade questions did not pass (2.24 d to g: $P50_WHY)"; fi
  p="$p $t: $(p50_kvq c46.upgrade_question)."
  p50_stv 3.1c
  w4=$(p50_fix_seen W4)
  if [ -n "$w4" ]; then p="$p W4 (3.1c $(p50_word "$P50_S")): $w4."
  else p="$p W4 is unread: 3.1c $(p50_word "$P50_S")."; fi
  conf=""; part=""; notc=""
  for id in $(p50_fix_ids); do
    p50_fix "$id"
    p50_eval "$P50_F_REQ" "$P50_F_OPT" "$P50_F_PART"
    case "$P50_V" in
      pass) conf="$conf${conf:+|}$P50_F_NAME" ;;
      partial) part="$part${part:+, }$P50_F_NAME ($P50_IDS)" ;;
      *) notc="$notc${notc:+, }$P50_F_NAME ($P50_WHY)" ;;
    esac
  done
  [ -z "$conf" ] || p="$p Confirmed on the Mac: $(p50_andsep "$conf")."
  [ -n "$part" ] && p="$p Partly confirmed: $part."
  [ -n "$notc" ] && p="$p Not confirmed: $notc."
  for id in W2 W3 W5 W6 W7 W8 W9 W10 W12 destroy relay late F1 F2 F3 F4 F5; do
    seen=$(p50_fix_seen "$id")
    [ -n "$seen" ] || continue
    p50_fix "$id"
    p="$p $P50_F_NAME: $seen."
  done
  p50_eval "2.25a 2.25b 2.25c"; e="$P50_V"; t="$P50_WHY"
  p50_eval "2.25d"; k="$P50_V"
  if [ "$e" = pass ] && [ "$k" = pass ]; then
    p="$p The core pack passed both G2 legs (2.25: a login, a tool turn and a WebFetch, then the same after a live account switch) against Claude Code $cv on $(p50_span "2.25c 2.25d")."
  else
    p="$p The core pack did not pass G2 against Claude Code $cv (${t:-first leg passed}${t:+, }$( [ "$k" = pass ] && printf 'the switch leg passed' || printf 'the switch leg %s' "$P50_WHY"))."
  fi
  p="$p No CI leg covers the allowing path on \`desktop-macos\` (ruling 9), so this hand run is its only end-to-end evidence."
  p50_stv 2.31
  if [ "$P50_S" = PASS ]; then p="$p Architecture: $arch. The amd64 gateway also started once under emulation (2.31)."
  else p="$p Architecture: $arch only."; fi
  printf '## 5.3 The run in concept/46 (its stage-three section)\n\n'
  printf '%s\n' "$p"
}

# p50_gen_summary: every step with its status, by sitting.
p50_gen_summary() {
  local sit i n g gp xr xp xf note st date gbad xbad
  g=0; gp=0; xr=0; xp=0; xf=0; gbad=""; xbad=""
  i=0
  while [ "$i" -lt "${#R_ID[@]}" ]; do
    if [ "${R_SIT[$i]}" != 5 ]; then
      st="${P50_ST[$i]}"
      if [ "${R_CLASS[$i]}" = gate ]; then
        g=$((g + 1))
        if [ "$st" = PASS ]; then gp=$((gp + 1)); else gbad="$gbad${gbad:+, }${R_ID[$i]} $(p50_word "$st")"; fi
      else
        case "$st" in pending|SKIP) ;; *) xr=$((xr + 1)) ;; esac
        case "$st" in
          PASS) xp=$((xp + 1)) ;;
          FAIL|ERROR) xf=$((xf + 1)); xbad="$xbad${xbad:+, }${R_ID[$i]} $st" ;;
        esac
      fi
    fi
    i=$((i + 1))
  done
  P50_GATES_BAD="$gbad"; P50_EXTRAS_BAD="$xbad"; P50_GATES_N="$g"; P50_GATES_P="$gp"
  printf '## Every step\n\n'
  printf 'Release gates of sittings 0 to 3: %s of %s passed. Extras: %s ran, %s passed, %s failed.\n' "$gp" "$g" "$xr" "$xp" "$xf"
  [ -n "$gbad" ] && printf '\nGates not passed: %s.\n' "$gbad"
  [ -n "$xbad" ] && printf '\nExtras that failed (an EXTRA holds the tag only through a defect it found): %s.\n' "$xbad"
  for sit in 0 1 2 3 5; do
    printf '\n### Sitting %s\n\n| Step | Class | Status | Attempts | Date | Title | Note |\n|---|---|---|---|---|---|---|\n' "$sit"
    i=0
    while [ "$i" -lt "${#R_ID[@]}" ]; do
      if [ "${R_SIT[$i]}" = "$sit" ]; then
        st=$(p50_word "${P50_ST[$i]}")
        [ "${R_ID[$i]}" = "${STEP_ID:-}" ] && st="running now"
        note=""
        case "${P50_ST[$i]}" in PASS|pending) ;; *) note=$(p50_cut "${P50_NOTE[$i]}" 160) ;; esac
        date=$(p50_span "${R_ID[$i]}")
        printf '| %s | %s | %s | %s | %s | %s | %s |\n' "${R_ID[$i]}" "${R_CLASS[$i]}" "$st" "${P50_ATT[$i]}" "$date" "$(p50_cell "${R_TITLE[$i]}")" "$(p50_cell "$note")"
      fi
      i=$((i + 1))
    done
  done
}

# p50_gen_fixes: the fixes table with the steps behind each. Writes the fix verdicts.
p50_gen_fixes() {
  local id v seen
  P50_FIX_BAD=""; P50_FIX_PART=""
  printf '## The fixes to confirm on the Mac\n\n'
  printf 'A fix is confirmed when every step behind it passed. A step that shows the old behaviour is a\n'
  printf 'regression of that fix: record it with the output and hold the tag.\n\n'
  printf '| Fix | Confirmed in (scenario) | Steps of this run | Status | PASS now | Seen on the Mac |\n|---|---|---|---|---|---|\n'
  for id in $(p50_fix_ids); do
    p50_fix "$id"
    p50_eval "$P50_F_REQ" "$P50_F_OPT" "$P50_F_PART"
    case "$P50_V" in
      pass) v="confirmed" ;;
      partial) v="partly confirmed: the EXTRA did not run"; P50_FIX_PART="$P50_FIX_PART${P50_FIX_PART:+, }$P50_F_NAME" ;;
      *) v="NOT confirmed: $P50_WHY"; P50_FIX_BAD="$P50_FIX_BAD${P50_FIX_BAD:+, }$P50_F_NAME" ;;
    esac
    seen=$(p50_fix_seen "$id")
    printf '| %s | %s | %s | %s | %s | %s |\n' "$P50_F_NAME" "$P50_F_CIN" "$(p50_cell "$P50_IDS")" "$(p50_cell "$v")" "$(p50_cell "$P50_F_NOW")" "$(p50_cell "${seen:--}")"
    p50_vadd "$P50_V" "fix $P50_F_NAME confirmed ($P50_F_CIN)" "$( [ "$P50_V" = fail ] && printf '%s' "$P50_WHY" || printf '%s' "$P50_IDS")"
  done
}

# p50_gen_decision: the scenario's 5.4 checklist, verbatim, with a Done column. Writes the row
# verdicts. Needs P50_FIX_BAD and P50_FIX_PART (p50_gen_fixes) and P50_CI_TXT.
p50_gen_decision() {
  local ids="" i n cfg
  P50_CHK_BAD=""; P50_CFG_BAD=""
  printf '## 5.4 Release decision\n\n| Check | Done |\n|---|---|\n'
  # 1
  p50_eval "0.1 0.1s"
  p50_row_done steps "0.1 the certified commit (\`ac6ee85\`, \`ac6ee85\` plus the script, or the one you name) named, tree clean, its suite and harness counts recorded, the three bash 3.2 files and the two relay regressions green" ""
  # 2
  p50_eval "0.3 0.4 0.5 0.6"
  p50_row_done steps "0.3 to 0.6 pass (\`egimg\` reads both \`this tree's\` lines for the box image, the gateway digest listed for linux/amd64 and linux/arm64)" ""
  # 3: every gate of sitting 1, its extras when they ran
  ids=""; i=0; n=""
  while [ "$i" -lt "${#R_ID[@]}" ]; do
    if [ "${R_SIT[$i]}" = 1 ]; then
      if [ "${R_CLASS[$i]}" = gate ]; then ids="$ids ${R_ID[$i]}"; else n="$n ${R_ID[$i]}"; fi
    fi
    i=$((i + 1))
  done
  p50_eval "$ids" "$n"
  p50_row_done steps "Sitting 1 all pass, 1.1b included" ""
  # 4
  ids=""; n=1; i=""
  while [ "$n" -le 15 ]; do ids="$ids $(p50_row_steps "$n")"; i="$i $(p50_row_opt "$n")"; n=$((n + 1)); done
  p50_eval "$ids" "$i"
  p50_row_done mixed "Fifteen rows of 5.2 pass and are filed" "file the fifteen rows in docs/egress-validation.md from record-draft.md"
  # 5
  p50_eval "1.1 2.25a 2.25b 2.25c 2.25d"
  p50_row_done mixed "The integration B line and the G2 lines of 5.2 are filed" "file the three lines from record-draft.md"
  # 6
  p50_eval "2.13a 2.13b 2.14a 2.14b 2.14-acct"
  p50_row_done steps "2.13 and 2.14 pass on bash 3.2, 2.14 at 80 columns" ""
  # 7
  p50_eval "2.15-pre 2.15b 2.15d 2.15g 2.15h 2.16a 2.16b 2.16c 2.17-pre 2.17d 2.17e 2.18a 2.18b 2.20a 2.20b 2.20c 2.20d 2.21a 2.21b 2.21c 2.21e 2.24-pre 2.24-back 2.24a 2.24b 2.24c 2.24d 2.24e 2.24f 2.24g 2.24h 2.24i 2.24j 2.24-clean 2.27a 2.27b 2.27c 2.27d"
  p50_row_done steps "2.15 b, d, g and h, 2.16, 2.17 d and e, 2.18, 2.20, 2.21 (e included), 2.24 (a to j), 2.27 pass" ""
  # 8
  p50_eval "2.25a 2.25b 2.25c 2.25d"
  if [ "$P50_V" = pass ]; then
    p50_row_done mixed "2.25 run: passed and \`_egress_unmeasured_line\` reworded (naming the version and date), or failed with the core-pack change decided in writing" "reword _egress_unmeasured_line with its tests, naming Claude Code $(p50_kvq image.claude) and $(p50_span "2.25c")"
  else
    P50_WHY="$P50_WHY. By hand: decide the core-pack change in writing before the tag"
    p50_row_done steps "2.25 run: passed and \`_egress_unmeasured_line\` reworded (naming the version and date), or failed with the core-pack change decided in writing" ""
  fi
  # 9
  if [ -z "${P50_FIX_BAD:-}" ] && [ -z "${P50_FIX_PART:-}" ]; then P50_V=pass; P50_IDS="all twenty-one confirmed"
  else
    P50_V=fail
    P50_WHY="${P50_FIX_BAD:+not confirmed: $P50_FIX_BAD}${P50_FIX_BAD:+${P50_FIX_PART:+. }}${P50_FIX_PART:+partly confirmed: $P50_FIX_PART}"
  fi
  p50_row_done steps "Every fix in the two tables near the top (W1 to W12, the review rows, the late fix and F1 to F5) confirmed on the Mac: its step passed as written, no regression seen" ""
  # 10 to 13
  p50_row_done hand "CI green on the pushed candidate, every job (5.1)" "${P50_CI_TXT:-see 5.1}"
  p50_row_done hand "5.1 complete: soaks run or waived with their consequences, the unsafe-rm measurement run or waived, R6-3 built or deferred, the relay heading accepted or retitled, docs items done" "see the 5.1 table"
  cfg=0
  if [ -f "$HOME/.config/cleat/config" ]; then
    cfg=$(awk '/^\[egress\]/ { k++ } END { print k + 0 }' "$HOME/.config/cleat/config" 2>/dev/null)
  fi
  p50_eval "3.5"
  if [ "${cfg:-0}" != 0 ]; then P50_V=fail; P50_WHY="${P50_WHY:+$P50_WHY, }your real config holds $cfg [egress] section(s) now"; P50_CFG_BAD="$cfg"; fi
  p50_row_done steps "3.5 cleanup done, real config untouched" ""
  p50_row_done hand "Release notes and site copy follow section 4" "section 4 of the scenario"
}

# p50_row_done KIND CHECK HAND: one checklist row from P50_V, P50_WHY and P50_IDS.
#   steps  ticked when the steps passed
#   mixed  the steps ticked when they passed, the hand part always open
#   hand   no step decides it: by hand
p50_row_done() {
  local kind="$1" check="$2" hand="$3" cell
  [ "$kind" = hand ] || [ "$P50_V" = pass ] || P50_CHK_BAD="${P50_CHK_BAD:-}${P50_CHK_BAD:+|}\"$(p50_cut "$check" 60)\""
  case "$kind" in
    steps)
      if [ "$P50_V" = pass ]; then cell="[x] passed: $P50_IDS"; else cell="[ ] not yet: $P50_WHY"; fi
      p50_vadd "$( [ "$P50_V" = pass ] && printf pass || printf fail)" "5.4: $(printf '%s' "$check" | cut -c1-90)" "$( [ "$P50_V" = pass ] && printf '%s' "$P50_IDS" || printf '%s' "$P50_WHY")" ;;
    mixed)
      if [ "$P50_V" = pass ]; then cell="[x] the steps passed. [ ] by hand: $hand"; else cell="[ ] not yet: $P50_WHY. Then by hand: $hand"; fi
      p50_vadd "$( [ "$P50_V" = pass ] && printf pass || printf fail)" "5.4: $(printf '%s' "$check" | cut -c1-90) (its steps)" "$( [ "$P50_V" = pass ] && printf '%s' "$P50_IDS" || printf '%s' "$P50_WHY")" ;;
    *)
      cell="[ ] by hand: $hand"
      p50_vadd hand "5.4: $(printf '%s' "$check" | cut -c1-90)" "" ;;
  esac
  printf '| %s | %s |\n' "$(p50_cell "$check")" "$(p50_cell "$cell")"
}

# ---------------------------------------------------------------------------------------------
# The steps
# ---------------------------------------------------------------------------------------------

# 5.1: the owed table. Re-entry: rewrites signoff/5.1-owed.md, reads CI again.
st_5_1() {
  local cand e gh_ok=0
  p50_load
  cand=$(kv_get cand.sha "")
  [ -n "$cand" ] || cand=$(GIT_OPTIONAL_LOCKS=0 git -C "$MT_WT" rev-parse HEAD 2>/dev/null)
  hdr "CI on the certified commit (read-only: gh run view, never a push or a dispatch)"
  P50_CI_V=unread; P50_CI_TXT=""; P50_CI_RUN=""; P50_CI_SHA=""
  if command -v gh > /dev/null 2>&1; then gh_ok=1; fi
  if [ "$gh_ok" = 1 ]; then
    p50_ci_pick "$cand"
    # A probe, not run_cmd: a slow network or a hung gh then reads "check by hand" (a NOTE), never
    # a TIMEOUT check that would fail this step.
    say "\$ gh run view $(p50_ci_run) -R $(p50_ci_repo) --json status,conclusion,headSha,jobs   (read-only, at most 90 s)"
    if mt__probe 90 gh run view "$(p50_ci_run)" -R "$(p50_ci_repo)" --json status,conclusion,headSha,jobs \
      --jq '"run\t" + .status + "\t" + (.conclusion // "") + "\t" + .headSha, (.jobs[] | "job\t" + .name + "\t" + .status + "\t" + (.conclusion // ""))'; then
      cp "$MT__PROBE_OUT" "$STEP_DIR/ci.txt" 2>/dev/null
      # A run on a commit with the certified code is read as the certified commit's own.
      p50_ci_parse "$STEP_DIR/ci.txt" "${P50_CI_SHA:-$cand}"
      if [ -n "$P50_CI_SHA" ] && [ "$P50_CI_SHA" != "$cand" ]; then
        P50_CI_TXT="$P50_CI_TXT (its commit differs from the certified $(printf '%s' "$cand" | cut -c1-7) only in the script's own files)"
      fi
    else
      e=$(head -n 1 "${MT__PROBE_OUT%.out}.err" 2>/dev/null | cut -c1-120)
      P50_CI_TXT="check by hand: gh run view read nothing${e:+ ($e)}. gh run view $(p50_ci_run) -R $(p50_ci_repo)"
    fi
  else
    P50_CI_TXT="check by hand: gh is not installed here. gh run view $(p50_ci_run) -R $(p50_ci_repo), every job green on the certified commit"
  fi
  [ -n "$P50_CI_TXT" ] || P50_CI_TXT="check by hand: gh run view $(p50_ci_run) -R $(p50_ci_repo)"
  if [ "${DRY:-0}" = 1 ]; then
    expect_eq "CI run $(p50_ci_run) is green on the certified commit" "$P50_CI_V" green
  else
    case "$P50_CI_V" in
      green) check_pass "CI run $(p50_ci_run) is green on the certified commit, every job" "$P50_CI_TXT" ;;
      red) check_fail "CI run $(p50_ci_run) is green on the certified commit, every job" "completed success, every job success" "$P50_CI_TXT" ;;
      *) check_note "CI: $P50_CI_TXT" ;;
    esac
  fi
  kv_set signoff.ci "$P50_CI_V"
  kv_set signoff.ci.text "$P50_CI_TXT"

  hdr "The table of 5.1"
  p50_gen_owed | p50_put 5.1-owed.md
  p50_assemble
  sed 's/^/  /' "$P50_D/5.1-owed.md"
  if [ -s "$P50_D/5.1-owed.md" ]; then check_pass "the 5.1 table is written" "$RUN/decision.md"
  else check_fail "the 5.1 table is written" "signoff/5.1-owed.md" "empty"; fi
  p50_leaks "$RUN/decision.md" "decision.md"
  return 0
}

# 5.2: the record draft. Re-entry: rewrites signoff/5.2-record.md from kv and results.tsv.
st_5_2() {
  p50_load
  hdr "The record for docs/egress-validation.md (scenario 5.2)"
  : > "$STEP_DIR/p50-verdicts"
  P50_MISS=""; P50_ROWS_OK=0; P50_ROWS_BAD=""
  # Run in this shell (not a pipe), so P50_MISS and the row counts survive.
  p50_gen_record > "$P50_D/.5.2.$$"
  p50_put 5.2-record.md < "$P50_D/.5.2.$$"
  rm -f "$P50_D/.5.2.$$"
  p50_assemble
  sed 's/^/  /' "$RUN/record-draft.md"
  record_value signoff.rows "$P50_ROWS_OK of 15 passed${P50_ROWS_BAD:+ (not passed: rows $P50_ROWS_BAD)}" "the fifteen rows"
  [ -n "$P50_MISS" ] && check_note "values not recorded in the draft: $P50_MISS"
  p50_verdicts_emit
  expect_count "the draft holds the fifteen rows" '^[|] [^|]* [|] [^|]* [|] ([1-9]|1[0-5]) [|]' eq 15 "$RUN/record-draft.md"
  expect_contains "the draft holds the run paragraph" "### Run of " "$RUN/record-draft.md"
  expect_contains "the draft holds the integration B line" "| Integration branch B, outside any box |" "$RUN/record-draft.md"
  expect_contains "the draft holds the first G2 line" "| Core pack, login, tool turn, WebFetch (G2) |" "$RUN/record-draft.md"
  expect_contains "the draft holds the second G2 line" "| Core pack after a live account switch (G2) |" "$RUN/record-draft.md"
  p50_leaks "$RUN/record-draft.md" "the record draft" public
  return 0
}

# 5.3: the concept/46 paragraph. Re-entry: rewrites signoff/5.3-concept46.md.
st_5_3() {
  p50_load
  hdr "The paragraph for concept/46 (scenario 5.3)"
  p50_gen_c46 > "$P50_D/.5.3.$$"
  p50_put 5.3-concept46.md < "$P50_D/.5.3.$$"
  rm -f "$P50_D/.5.3.$$"
  p50_assemble
  fold -s -w 100 "$P50_D/5.3-concept46.md" | sed 's/^/  /'
  expect_contains "the paragraph names ruling 9" "No CI leg covers the allowing path on \`desktop-macos\` (ruling 9)" "$RUN/record-draft.md"
  expect_match "the paragraph names the architecture" 'Architecture: ' "$RUN/record-draft.md"
  p50_leaks "$RUN/record-draft.md" "the record draft" public
  return 0
}

# 5.4: every step, the fixes, the checklist, the decision. Re-entry: rewrites its three sections.
st_5_4() {
  local line
  p50_load
  : > "$STEP_DIR/p50-verdicts"
  P50_CI_TXT=$(kv_get signoff.ci.text "")
  [ -n "$P50_CI_TXT" ] || P50_CI_TXT="not read yet: ./egress-release.sh --only 5.1"
  hdr "Every step"
  p50_gen_summary > "$P50_D/.5.4s.$$"
  p50_put 5.4-summary.md < "$P50_D/.5.4s.$$"
  hdr "The fixes"
  p50_gen_fixes > "$P50_D/.5.4f.$$"
  p50_put 5.4-fixes.md < "$P50_D/.5.4f.$$"
  hdr "The release decision checklist"
  p50_gen_decision > "$P50_D/.5.4d.$$"
  p50_put 5.4-decision.md < "$P50_D/.5.4d.$$"
  rm -f "$P50_D/.5.4s.$$" "$P50_D/.5.4f.$$" "$P50_D/.5.4d.$$"
  if [ -n "${P50_GATES_BAD:-}" ] || [ -n "${P50_FIX_BAD:-}" ] || [ -n "${P50_CFG_BAD:-}" ]; then
    line="HOLD THE TAG."
    [ -n "${P50_GATES_BAD:-}" ] && line="$line $((P50_GATES_N - P50_GATES_P)) of $P50_GATES_N release gates did not pass: $(p50_firsts "$P50_GATES_BAD" 12)."
    [ -n "${P50_FIX_BAD:-}" ] && line="$line Not confirmed: $P50_FIX_BAD."
    [ -n "${P50_CFG_BAD:-}" ] && line="$line Your real ~/.config/cleat/config holds $P50_CFG_BAD [egress] section(s): find what wrote it."
  elif [ -n "${P50_FIX_PART:-}" ]; then
    line="Every release gate passed. Partly confirmed: $P50_FIX_PART (an EXTRA behind it did not run). Run it, or accept the gap in writing."
  else
    line="Every release gate passed and every fix is confirmed."
  fi
  # A checklist row its steps decide can stay open with every gate passed only through an EXTRA
  # that ran and failed (rows 3 and 4) or a partly confirmed fix: name the rows.
  if [ -z "${P50_GATES_BAD:-}" ] && [ -z "${P50_FIX_BAD:-}" ] && [ -z "${P50_CFG_BAD:-}" ] && [ -n "${P50_CHK_BAD:-}" ]; then
    line="$line Rows of the 5.4 checklist not ticked: $(p50_andsep "$P50_CHK_BAD")."
  fi
  [ -n "${P50_EXTRAS_BAD:-}" ] && line="$line Extras that failed: $P50_EXTRAS_BAD (read each: a defect it found may hold the tag)."
  line="$line Still by hand before the tag: CI (5.1), the rest of 5.1, filing the record, the concept/46 paragraph, the release notes and the site copy (section 4)."
  printf '%s\n' "$line" > "$P50_D/decision-line.txt"
  p50_assemble
  sed -n '/^## 5.4 Release decision/,$p' "$P50_D/5.4-decision.md" | sed 's/^/  /'
  say ""
  say "Decision: $line" | fold -s -w 100
  record_value signoff.decision "$line" "the release decision"
  p50_verdicts_emit
  p50_leaks "$RUN/decision.md" "decision.md"
  return 0
}

# 5.5: the report, the paths, the readings file. Re-entry: writes the report again, asks again.
st_5_5() {
  local rc
  p50_load
  hdr "The report"
  report_write "$RUN/report.md"
  if [ -s "$RUN/report.md" ]; then check_pass "report.md is written" "$RUN/report.md"
  else check_fail "report.md is written" "a report" "an empty or missing file"; fi
  p50_leaks "$RUN/report.md" "report.md"
  p50_assemble
  say ""
  say "Written in the run dir (private, redacted where they leave it):"
  say "  $RUN/report.md          the report, to paste into a chat (./egress-release.sh --report prints it)"
  say "  $RUN/record-draft.md    the 5.2 record and the 5.3 paragraph: copy them by hand"
  say "  $RUN/decision.md        every step, 5.1, the fixes and the 5.4 checklist"
  if [ -f "$P50_D/decision-line.txt" ]; then
    say ""
    fold -s -w 100 "$P50_D/decision-line.txt" | sed 's/^/  /'
  else
    say "  (5.4 has not run: ./egress-release.sh --only 5.4)"
  fi

  hdr "The readings file"
  if [ -f "$READF" ]; then
    rc=1
    if cp "$READF" "$RUN/mt-egress-readings.txt" 2>/dev/null && cmp -s "$READF" "$RUN/mt-egress-readings.txt"; then rc=0; fi
    if [ "$rc" != 0 ]; then
      check_fail "the run dir keeps a copy of ~/mt-egress-readings.txt" "a copy" "cp failed: the file stays where it is"
      return 0
    fi
    check_pass "the run dir keeps a copy of ~/mt-egress-readings.txt" "$RUN/mt-egress-readings.txt"
    choose del-readings "Delete ~/mt-egress-readings.txt now? The run dir keeps a copy. Delete it once the record is in docs/egress-validation.md (scenario 3.5)." \
      "n=keep it for now" "y=delete it"
    if [ "$CHOICE" = y ]; then
      safe_rm "$READF"
      if [ -e "$READF" ] && [ "${DRY:-0}" != 1 ]; then check_fail "~/mt-egress-readings.txt is deleted" "gone" "still there"
      else check_note "~/mt-egress-readings.txt deleted. The copy: $RUN/mt-egress-readings.txt"; fi
    else
      check_note "~/mt-egress-readings.txt kept. Delete it once the record is written: rm ~/mt-egress-readings.txt"
    fi
  else
    check_note "~/mt-egress-readings.txt is not there (deleted already, or no reading was taken)"
  fi
  say ""
  say "Next, by hand: file the record in docs/egress-validation.md and the paragraph in concept/46, work"
  say "through the 5.1 table and the open boxes of 5.4 in decision.md, then the release notes and the site"
  say "copy by section 4 of the scenario. This script never commits, pushes or tags."
  say "Run every sign-off step you still want (--only 5.1 to read CI again, --only '5.*' for fresh drafts)"
  say "before you edit docs/egress-validation.md in the candidate. An edit there is a tracked change: from"
  say "then on every step of this run refuses to start, the sign-off included."
  return 0
}

reg 5.1 5 auto  gate st_5_1 "Owed before the tag"
reg 5.2 5 auto  gate st_5_2 "The record draft for docs/egress-validation.md"
reg 5.3 5 auto  gate st_5_3 "The concept/46 paragraph draft"
reg 5.4 5 auto  gate st_5_4 "The fixes confirmed and the release decision"
reg 5.5 5 mixed gate st_5_5 "The report"
