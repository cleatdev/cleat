# egress-release.d/10-setup.sh: sitting 0: 0.1 to 0.6 (the candidate, the env file, host facts, a clean state, the images).
#
# A part of egress-release.sh. Sourced, never run. It holds only function definitions, reg calls,
# comments and the two counts below (plain assignments): nothing else runs at source time. One
# function per step, named st_ plus the id with . and - turned into _, registered in scenario
# order with
#   reg ID SITTING KIND CLASS FUNC "TITLE"
# The steps, their checks and their re-entry rules are DESIGN.md section 6.2. A helper this part
# needs that the library lacks is written here, prefixed with the part's number (p10_).
#
# Steps: 0.1, 0.1s, 0.1x (EXTRA), 0.2, 0.3, 0.4, 0.5, 0.6. Sitting 0 runs in T2 alone: nothing
# here opens T1 (the first step that needs it opens it). The questions: cert-head (only when HEAD
# is neither ac6ee85 nor ac6ee85 plus the script), dd-settings (two Docker Desktop settings, n asks
# you to type both), pm-read with host control off (the sleep assertions, then the holders when a
# count is not 0) and img-swapped (only when 0.5 runs while 2.24 holds the v1.5.4 image).
#
# Every step is safe to run again from its start. 0.1, 0.1s, 0.3 and 0.6 change nothing. 0.2
# rewrites the env file, as the scenario's cat > does. 0.4 reads, then makes ~/mt-egress once.
# 0.5 rebuilds the image again. 0.1x runs the whole suite and the harness again.
#
# The scenario holds the run on a red test file (0.1s) and on an image that is not this tree's
# (0.5). The framework's stop rule covers sitting 1 only, so those steps FAIL with a note that
# says to answer q at the question before sitting 1 and report it.
#
# Two gates keep a failed step from being built on. Every step after 0.1 ends at once as FAIL,
# changing nothing, until 0.1 has passed (p10_need_frozen). That is the scenario's "start again
# here". It also keeps ./egress-release.sh --new open, which refuses once ~/mt-egress or
# ~/mt-egress-xdg exist.
# 0.5 needs ~/mt-egress made by 0.4 (kv p.made), so a leftover FAIL of 0.4 is never followed by a
# directory that makes every later attempt of 0.4 fail too. A FAIL is terminal for --resume, so each
# fix names the --from that runs the failed step and everything after it again.
#
# Where this part departs from the scenario or the design (and why):
#   1. ./test.sh with file arguments runs bats directly (test.sh, "If specific files are passed"),
#      so it prints bats' TAP and no summary of its own: no "All tests passed", no per-file count.
#      0.1s reads the plan line 1..N, N lines "ok" and no "not ok", then compares N with what
#      bats --count finds for the same files and filter. "All tests passed" is read by 0.1x.
#   2. BATS_FORMATTER=tap is pinned for every bats run. It is bats' own default in this tree, so
#      the output is the same. A BATS_FORMATTER in your environment cannot change it.
#   3. The grep -n of 0.1 is written grep -n -E with one group instead of the BRE \| form: the
#      same three lines, on BSD and GNU grep alike.
#   4. 0.4 records daily.listable by running refusing_set against a scratch config that holds
#      only mode = strict. The run's own config holds no policy at 0.4, so refusing_set alone
#      lists nothing. This is the set the note of 1.2a's first allow should list.
#   5. 0.4 once this run has made ~/mt-egress (kv p.made): the leftover checks are recorded SKIP.
#      A clean start can only be judged before the run creates anything.
#   6. 0.5 asks before it replaces an image 2.24 holds on purpose (kv image.swapped is 1).
#   7. Watchdogs: 0.1s one hour per bats run, 0.1x four hours for the suite and twelve for the
#      harness, 0.5 one hour for the rebuild (the design's 1800 s left no margin on a slow link).
#   8. The scenario's /bin/bash is MT_BASH (the same file on the Mac): bats runs with the
#      directory of MT_BASH first on PATH, as PATH=/bin:/usr/bin:$PATH does there.
#   9. Two readings are taken with choose, not ask, because ask's n is a FAIL: Docker Desktop's two
#      settings in 0.3 (n means "type them") and, with host control off, the sleep assertions in
#      0.4 (a count above 0 is a note for sitting 3, never a FAIL of 0.4). The library's
#      pm_assertions asks with ask there, so 0.4 calls it only with host control on.
#  10. daily.names, daily.running and daily.count leave out cleat-eg-* and cleat-gw-* (test objects,
#      a leftover FAIL at the start), so redact never turns a test box into <daily box>. They take
#      only lines shaped like a container name, read from docker ps with its stderr kept apart, so
#      a docker error can never become a "box name" that redact would then blank in every report.

# ---------------------------------------------------------------------------------------------
# The agent's counts on the candidate
# ---------------------------------------------------------------------------------------------

# The agent's Linux run on ac6ee85 (bash 5): the suite's tests passed (1 skipped) and the mutation
# harness's mutations, every one caught and none skipped. 0.1s records them as the scenario's
# "the suite and harness counts with where they ran". Not a whole number: no harness count is
# recorded (5.1 then reads it from CI).
P10_SUITE_COUNT=4343
P10_HARNESS_COUNT=2180

# ---------------------------------------------------------------------------------------------
# Helpers of this part
# ---------------------------------------------------------------------------------------------

# p10_int VALUE: rc 0 for a whole number (a dry run's <dry:x> is not one).
p10_int() {
  case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac
  return 0
}

# p10_ver_ge A B: version A is at least B, compared as major then minor (whole numbers).
p10_ver_ge() {
  awk -v a="$1" -v b="$2" 'BEGIN {
    split(a, x, "."); split(b, y, ".")
    sub(/[^0-9].*$/, "", x[1]); sub(/[^0-9].*$/, "", x[2])
    if (x[1] == "" || x[2] == "") exit 1
    if (x[1] + 0 != y[1] + 0) exit !(x[1] + 0 > y[1] + 0)
    exit !(x[2] + 0 >= y[2] + 0)
  }'
}

# p10_check_ge DESC GOT MIN: a check that GOT is version MIN or later.
p10_check_ge() {
  if [ "${DRY:-0}" = 1 ]; then say "  [dry] check: $1 expects at least $3"; return 0; fi
  if p10_ver_ge "$2" "$3"; then check_pass "$1" "$2"; else check_fail "$1" "at least $3" "${2:-nothing}"; fi
}

# p10_join FILE: the non-empty lines of FILE on one line, joined by " | ".
p10_join() {
  [ -f "$1" ] || return 0
  awk 'NF { printf "%s%s", (n++ ? " | " : ""), $0 } END { if (n) printf "\n" }' "$1"
}

# p10_lines FILE: the non-empty lines of FILE, space separated, on one line.
p10_lines() {
  [ -f "$1" ] || return 0
  awk 'NF { printf "%s%s", (n++ ? " " : ""), $1 } END { if (n) printf "\n" }' "$1"
}

# p10_count FILE: how many non-empty lines FILE holds.
p10_count() {
  [ -f "$1" ] || { printf '0\n'; return 0; }
  awk 'NF { c++ } END { print c + 0 }' "$1"
}

# p10_git ARGS...: git in the candidate, with no optional lock (a read never writes the index).
p10_git() { GIT_OPTIONAL_LOCKS=0 git -C "$MT_WT" "$@"; }

# p10_status_of ID: "STATUS NOTE" of step ID's closing line in this run (its last line in
# results.tsv that is not STARTED or RESET), empty when it never closed.
p10_status_of() {
  [ -f "$RUN/results.tsv" ] || return 0
  LC_ALL=C awk -F'\t' -v id="$1" 'NR > 1 && $2 == id && $4 != "STARTED" && $4 != "RESET" { s = $4 " " $9 } END { print s }' "$RUN/results.tsv" 2>/dev/null
  return 0
}

# p10_need_frozen: every step after 0.1 rests on the commit 0.1 froze. Until 0.1 has passed (or was
# left out on purpose with --skip) the step ends at once as FAIL and changes nothing: no 15 minute
# bats run, no env file, no ~/mt-egress, no rebuild of the image your daily boxes use. That also
# keeps 0.1's own advice (a new run) open, because ./egress-release.sh --new refuses once
# ~/mt-egress or ~/mt-egress-xdg exist. A 0.1 skipped after it crashed certified nothing either.
p10_need_frozen() {
  local st
  [ "${DRY:-0}" = 1 ] && return 0
  st=$(p10_status_of 0.1)
  case "$st" in "PASS "*|"SKIP skipped by --skip"*) return 0 ;; esac
  st="${st%% *}"
  step_abort "0.1 has not passed (${st:-it has not run}) and every step after it rests on the commit 0.1 freezes. Fix what 0.1 reported, then run ./egress-release.sh --from 0.1 (a different commit needs a new run: ./egress-release.sh --new). Answer q at the question before sitting 1."
}

# p10_bats_env CMD...: CMD with the directory of MT_BASH first on PATH, so the "#!/usr/bin/env bash"
# of test.sh and bats finds the bash cleat runs under (on the Mac /bin/bash 3.2.57, exactly as the
# scenario's PATH=/bin:/usr/bin:$PATH). BATS_FORMATTER=tap is bats' own default, pinned.
p10_bats_env() {
  local d="${MT_BASH%/*}"
  [ -n "$d" ] || d=/
  env PATH="$d:/bin:/usr/bin:$PATH" BATS_FORMATTER=tap "$@"
}

# p10_tree_clean WHEN: the candidate is as 0.1 froze it: no tracked change, nothing staged, no
# untracked file but this script's own (git status --short prints nothing else), no test lock.
p10_tree_clean() {
  local when="$1"
  run_cmd -q -- cand_tracked_dirty
  expect_not_match "$when: no tracked change in the candidate, staged or not (the script's own files aside)" '.'
  run_cmd -- git_dirty_untracked
  expect_not_match "$when: git status lists nothing but this script's own files" '.'
  if [ -e "$MT_WT/.test-suite.lock" ]; then
    check_fail "$when: no test lock in the candidate" "no .test-suite.lock" ".test-suite.lock exists (read its owner file)"
  else
    check_pass "$when: no test lock in the candidate"
  fi
}

# p10_count_is FILE PATTERN WANT DESC: grep -c PATTERN FILE prints WANT. The printed number is
# what counts, never grep's rc (grep -c exits 1 when it counts 0).
p10_count_is() {
  run_cmd -- grep -c "$2" "$1"
  expect_line "$4: grep -c prints $3" "$3"
}

# p10_tap KEY DESC WANT: the checks of one ./test.sh FILES run, whose bats TAP is in OUT: rc 0,
# the plan line 1..N with N equal to WANT, N lines "ok", no "not ok". Records kv KEY. Sets P10_N
# P10_OK P10_SKIP.
p10_tap() {
  local key="$1" desc="$2" want="$3" f="$OUT" n ok sk
  expect_rc "$desc: test.sh exits 0" 0
  n=$(awk '/^1\.\.[0-9]+$/ { sub(/^1\.\./, ""); print; exit }' "$f" 2>/dev/null)
  ok=$(awk '/^ok [0-9]+ / { c++ } END { print c + 0 }' "$f" 2>/dev/null)
  sk=$(awk '/^ok [0-9]+ / && /# skip/ { c++ } END { print c + 0 }' "$f" 2>/dev/null)
  P10_N="${n:-}"; P10_OK="${ok:-0}"; P10_SKIP="${sk:-0}"
  if p10_int "$want" || [ "${DRY:-0}" = 1 ]; then
    expect_eq "$desc: bats plans the $want tests bats --count finds" "${n:-no plan line}" "$want"
  elif [ "${DRY:-0}" != 1 ]; then
    check_fail "$desc: bats --count gave a number" "a number" "${want:-nothing}"
  fi
  if p10_int "$n"; then
    expect_count "$desc: each of the $n tests is ok" '^ok [0-9]+ ' eq "$n" "$f"
  else
    expect_match "$desc: bats printed its plan line" '^1\.\.[0-9]+$' "$f"
  fi
  expect_not_match "$desc: no test failed" '^not ok ' "$f"
  record_value "$key" "${ok:-0} of ${n:-?} ok, ${sk:-0} skipped" "$desc"
  if p10_int "$sk" && [ "$sk" -gt 0 ]; then
    check_note "$desc: $sk skipped: $(awk '/^ok [0-9]+ / && /# skip/ { sub(/^ok [0-9]+ /, ""); if (k++ < 5) printf "%s%s", (k > 1 ? " / " : ""), $0 }' "$f")"
  fi
  if LC_ALL=C grep -q '^not ok ' "$f" 2>/dev/null; then
    say "  The failing tests, with what bats printed for each (the whole output is in ${STEP_DIR:-.}/$CMDREF.out):"
    awk '/^not ok / { show = 1; k = 0; print "    " $0; next } /^ok / { show = 0; next }
      show && /^#/ { k++; if (k <= 40) print "    " $0 }' "$f" | head -n 200
  fi
  return 0
}

# p10_suite_rec: rec.suite.mac from what 0.1s and 0.1x measured (either may run again).
p10_suite_rec() {
  local a b
  a=$(kv_get suite.mac.files "")
  b=$(kv_get suite.mac.full "")
  rec_set suite.mac "${a:-the three files did not run}${b:+. $b}"
}

# p10_suite_nums FILE: "TOTAL PASSED SKIPPED FAILED" from test.sh's summary line.
p10_suite_nums() {
  awk '/ total / { for (i = 1; i < NF; i++) { w = $(i + 1)
      if (w == "total") t = $i; if (w == "passed") p = $i; if (w == "skipped") s = $i; if (w == "failed") f = $i } }
    END { printf "%d %d %d %d\n", t, p, s, f }' "$1" 2>/dev/null
}

# p10_harness_nums FILE: "TOTAL CAUGHT MISSED SKIPPED" from the harness's summary.
p10_harness_nums() {
  awk '/^ *Total: / { t = $2 } /^ *Caught: / { c = $2 } /^ *Missed: / { m = $2 } /^ *Skipped: / { s = $2 }
    END { printf "%d %d %d %d\n", t, c, m, s }' "$1" 2>/dev/null
}

# p10_tree_warn: a cleanup of 0.1s and 0.1x. A run cut by Ctrl-C or the watchdog may leave the test
# lock behind. A cut harness may also leave a file it rewrote. This says so loudly. It never
# restores anything itself.
p10_tree_warn() {
  local dirty
  dirty=$(cand_tracked_dirty)
  if [ -n "$dirty" ]; then
    printf '\n!!! The candidate has tracked changes after %s:\n' "${STEP_ID:-this step}"
    printf '%s\n' "$dirty" | sed 's/^/      /'
    printf '!!! The mutation harness rewrites files in place and keeps its backups in /tmp as\n'
    printf '!!! cleat-regression-mutation-*backup-<pid> (bin/cleat is cleat-regression-mutation-backup-<pid>).\n'
    printf '!!! Restore every file before anything else runs (git -C %s checkout -- FILE, or copy the backup back).\n' "$MT_WT"
  fi
  if [ -e "$MT_WT/.test-suite.lock" ]; then
    printf '!!! A test lock is left in the candidate. Read %s/.test-suite.lock/owner, then remove the lock if that run is gone.\n' "$MT_WT"
  fi
  return 0
}

# p10_egobjs_counts FILE: "GATEWAYS VOLUMES HOSTFILES", the lines under each header of egobjs.
p10_egobjs_counts() {
  awk '/^-- gateways:$/ { s = 1; next } /^-- socket volumes:$/ { s = 2; next } /^-- host files:$/ { s = 3; next }
    NF && s { c[s]++ } END { printf "%d %d %d\n", c[1], c[2], c[3] }' "$1" 2>/dev/null
}

# p10_leftover_ls: the scenario's ls -d of what an earlier attempt leaves (nothing when clean).
p10_leftover_ls() {
  ls -d "$P" "$UPX" "$CFG/config" "$CFG/run" "$CFG"/egress-* 2>/dev/null
  return 0
}

# p10_cfg_ls: ls "$CFG" (nothing when the directory does not exist).
p10_cfg_ls() {
  [ -d "$CFG" ] || return 0
  ls "$CFG"
}

# p10_real_egress: how many [egress] sections your real config holds (0 when there is no file).
p10_real_egress() {
  local f="$HOME/.config/cleat/config"
  if [ -f "$f" ]; then grep -c '^\[egress\]' "$f"; else printf '0\n'; fi
  return 0
}

# p10_test_boxes: the test boxes that exist (cleat-eg-*), one per line.
p10_test_boxes() { docker ps -a --filter "name=^cleat-eg-" --format '{{.Names}}'; return 0; }

# p10_names FILE: the lines of FILE shaped like a cleat container name, one per line. Anything else
# (a docker error that reached the file) is never taken for a box: these names feed redact.
p10_names() {
  LC_ALL=C grep -E '^cleat-[A-Za-z0-9_.-]+$' "$1" 2>/dev/null
  return 0
}

# p10_not_test FILE: the names in FILE that are not test objects (cleat-eg-* boxes, cleat-gw-*).
p10_not_test() {
  p10_names "$1" | grep -v -e '^cleat-eg-' -e '^cleat-gw-'
  return 0
}

# p10_listable: the boxes the refusing-boxes note will list once a policy exists (the first
# allow of 1.2a): refusing_set run against a scratch config that holds only mode = strict.
p10_listable() {
  local EGX="$SCRATCH/mt-listable"
  mkdir -p "$EGX/cleat" || return 1
  printf '[egress]\nmode = strict\n' > "$EGX/cleat/config" || return 1
  refusing_set
}

# p10_dd_pairs FILE: the "key": value pairs in Docker Desktop's settings lines (dd_settings_guess)
# whose key names the VM manager or file sharing, one per line. The settings file may hold its whole
# JSON on one line, so the pairs are cut out rather than the lines shown.
p10_dd_pairs() {
  awk '{
    s = $0
    while (match(s, /"[A-Za-z0-9_]+"[ \t]*:[ \t]*("[^"]*"|true|false|[0-9]+)/)) {
      p = substr(s, RSTART, RLENGTH); s = substr(s, RSTART + RLENGTH)
      k = p; sub(/[ \t]*:.*$/, "", k)
      if (tolower(k) ~ /virtuali[sz]ation|virtiofs|grpcfuse|libkrun|vmm/) print p
    }
  }' "$1" 2>/dev/null
  return 0
}

# p10_dd_guess FILE: "VMM|FS" read from Docker Desktop's settings lines (dd_settings_guess), each
# "unknown" when the lines do not say. A guess for you to confirm, never a check.
p10_dd_guess() {
  awk '
    { l = tolower($0) }
    l ~ /"[a-z]*libkrun[a-z]*"[ \t]*:[ \t]*true/ { lk = 1 }
    l ~ /"usevirtualizationframework"[ \t]*:[ \t]*true/ { vf = 1 }
    l ~ /"usevirtualizationframework"[ \t]*:[ \t]*false/ { vfoff = 1 }
    l ~ /"[a-z]*virtiofs[a-z]*"[ \t]*:[ \t]*true/ { fsv = 1 }
    l ~ /"[a-z]*virtiofs[a-z]*"[ \t]*:[ \t]*false/ { fsvoff = 1 }
    l ~ /"[a-z]*grpcfuse[a-z]*"[ \t]*:[ \t]*true/ { fsg = 1 }
    l ~ /"[a-z]*grpcfuse[a-z]*"[ \t]*:[ \t]*false/ { fsgoff = 1 }
    END {
      v = "unknown"
      if (lk) v = "Docker VMM"; else if (vf) v = "Apple Virtualization framework"; else if (vfoff) v = "QEMU (Legacy)"
      f = "unknown"
      if (lk || fsv) f = "VirtioFS"; else if (fsg) f = "gRPC FUSE"; else if (fsvoff && fsgoff) f = "osxfs (Legacy)"
      printf "%s|%s\n", v, f
    }' "$1" 2>/dev/null
}

# p10_platforms FILE: "Platform: os/arch" for each platform of a docker manifest inspect index
# (the fallback of 0.6 when buildx is missing).
p10_platforms() {
  awk '/"platform"[ \t]*:/ { inp = 1; a = ""; o = ""; next }
    inp && /"architecture"[ \t]*:/ { v = $0; sub(/.*"architecture"[ \t]*:[ \t]*"/, "", v); sub(/".*$/, "", v); a = v }
    inp && /"os"[ \t]*:/ { v = $0; sub(/.*"os"[ \t]*:[ \t]*"/, "", v); sub(/".*$/, "", v); o = v }
    inp && /}/ { print "Platform: " o "/" a; inp = 0 }' "$1" 2>/dev/null
}

# ---------------------------------------------------------------------------------------------
# 0.1 Freeze the candidate [RELEASE GATE]
# ---------------------------------------------------------------------------------------------

st_0_1() {
  local head="" short="" branch="" want="" subj="" p1="" p2="" p3="" w1="" w2="" w3="" eng="" anc missing="" r=0 desc=""
  cd "$MT_WT" || step_abort "cannot enter the candidate checkout $MT_WT"
  hdr "The tree: git status --short must print nothing"
  run_cmd -- env GIT_OPTIONAL_LOCKS=0 git status --short
  p10_tree_clean "0.1"

  hdr "The commit"
  val head -- p10_git rev-parse HEAD
  val short -- p10_git rev-parse --short HEAD
  val branch -- p10_git rev-parse --abbrev-ref HEAD
  val subj -- p10_git log -1 --format=%s
  val want -- p10_git rev-parse --verify --quiet 'ac6ee85^{commit}'
  run_cmd -- env GIT_OPTIONAL_LOCKS=0 git log --oneline -5
  record_value cand.log "$(p10_join "$OUT")" "git log --oneline -5"
  for anc in 2a831dc cbb4297 68f1153 ac6ee85; do
    run_cmd -q -- p10_git merge-base --is-ancestor "$anc" HEAD
    expect_rc "$anc is in the history of HEAD" 0 || missing="$missing $anc"
  done
  [ -z "$missing" ] || step_abort "MT_WT is not the candidate: HEAD $short lacks$missing. Point MT_WT at the candidate checkout (or put it at the candidate), then start a new run: ./egress-release.sh --new. Answer q at the question before sitting 1."
  if [ "$head" = "$want" ]; then
    check_pass "HEAD is ac6ee85 (the fixes the release-test script found on real Docker)" "$short"
  else
    # ac6ee85 plus the script: every later commit touches only test/manual/egress-release.sh and
    # test/manual/egress-release.d/. The run then certifies ac6ee85's code with its script on it.
    run_cmd -- cand_plus_script "$MT_WT" ac6ee85
    if [ "$RC" = 0 ]; then
      desc="ac6ee85 plus the script"
      check_pass "HEAD $short is ac6ee85 plus the script: the commits after ac6ee85 touch only test/manual/egress-release.sh and test/manual/egress-release.d/" "$short"
    else
      r=5
      while [ "$r" = 5 ]; do
        ask cert-head T2 "Read the commit this run would certify, the HEAD of the candidate checkout:
  $short  $subj
It is a later commit on ac6ee85 that changes more than the script (the lines above name what it
touches), not ac6ee85 itself. The run certifies exactly one commit." "HEAD is the commit you mean to certify" "Certify $short instead of ac6ee85?"
        r=$?
      done
      if [ "$r" != 0 ]; then
        step_abort "HEAD $short is not certified. Put the candidate at the commit to certify, then start a new run: ./egress-release.sh --new. Answer q at the question before sitting 1."
      fi
      desc="named at 0.1 in place of ac6ee85"
      check_note "HEAD $short is certified in place of ac6ee85 (you said yes)"
    fi
  fi
  # The chain under ac6ee85, read from ac6ee85 itself (HEAD may be a later commit on it).
  val p1 -- p10_git rev-parse 'ac6ee85~1'
  val p2 -- p10_git rev-parse 'ac6ee85~2'
  val p3 -- p10_git rev-parse 'ac6ee85~3'
  val w1 -- p10_git rev-parse --verify --quiet '68f1153^{commit}'
  val w2 -- p10_git rev-parse --verify --quiet 'cbb4297^{commit}'
  val w3 -- p10_git rev-parse --verify --quiet '2a831dc^{commit}'
  expect_eq "ac6ee85 is on 68f1153 (the late note fix)" "$p1" "$w1"
  expect_eq "on cbb4297 (the release-test fixes)" "$p2" "$w2"
  expect_eq "on 2a831dc (the bash 3.2 key-reader fix)" "$p3" "$w3"

  hdr "The fixes are in"
  p10_count_is bin/cleat '^_read_esc_rest()' 1 "the shared escape reader is in"
  p10_count_is bin/cleat '^_egress_esc_rest()' 0 "the editor's private copy is gone"
  p10_count_is bin/cleat '^_egress_refuse_before_teardown()' 1 "the refusals before a teardown are in"
  p10_count_is bin/cleat '^_EGRESS_PAIRED_ENV=' 1 "the four caged settings are in"
  p10_count_is docker/cleat-egress-shim 'supervisor started again in place' 1 "the relay restarts itself"
  run_cmd -- grep -n -E '^(_EGRESS_ENFORCING|_EGRESS_VALIDATED_ENGINES|_IMAGE_SPEC_VERSION)=' bin/cleat
  expect_match "_EGRESS_ENFORCING=1" '^[0-9]+:_EGRESS_ENFORCING=1$'
  expect_match "_IMAGE_SPEC_VERSION=6" '^[0-9]+:_IMAGE_SPEC_VERSION=6$'
  if [ "$MT_EXPECT_ENGINE" = desktop-macos ]; then
    expect_match "_EGRESS_VALIDATED_ENGINES=\"desktop-macos\"" '^[0-9]+:_EGRESS_VALIDATED_ENGINES="desktop-macos"$'
  else
    val eng -- sed -n 's/^_EGRESS_VALIDATED_ENGINES="\(.*\)"$/\1/p' bin/cleat
    case " $eng " in
      *" desktop-macos "*)
        case " $eng " in
          *" $MT_EXPECT_ENGINE "*)
            check_pass "the validated engines hold desktop-macos and $MT_EXPECT_ENGINE" "$eng"
            check_note "validation deviation: the engines line reads \"$eng\", not \"desktop-macos\" alone" ;;
          *) check_fail "the validated engines hold $MT_EXPECT_ENGINE (MT_EXPECT_ENGINE)" "desktop-macos $MT_EXPECT_ENGINE" "$eng" ;;
        esac ;;
      *"<dry:"*) ;;
      *) check_fail "the validated engines hold desktop-macos" "desktop-macos" "${eng:-nothing}" ;;
    esac
  fi

  [ "${DRY:-0}" = 1 ] || kv_set cand.sha "$head"
  record_value cand.short "$short" "the certified commit"
  if [ -n "$desc" ]; then record_value cand.desc "$desc" "what the certified commit is"; else kv_del cand.desc; fi
  record_value cand.branch "$branch" "its branch"
  rec_set run.sha "$short"
  case "$branch" in
    egress-stage3|"<dry:"*) ;;
    *) check_note "the branch is $branch, not egress-stage3 (the SHA is what the run certifies)" ;;
  esac
  return 0
}
reg 0.1 0 auto gate st_0_1 "Freeze the candidate"

# ---------------------------------------------------------------------------------------------
# 0.1s The three bats files and the two relay regressions under bash 3.2 [RELEASE GATE]
# ---------------------------------------------------------------------------------------------

st_0_1s() {
  local bver="" want1="" want2="" f1="" f2=""
  p10_need_frozen
  cd "$MT_WT" || step_abort "cannot enter the candidate checkout $MT_WT"
  [ -f test/bats/bin/bats ] || step_abort "test/bats is missing in the candidate: run git submodule update --init --recursive there, then ./egress-release.sh --only 0.1s"
  on_cleanup "p10_tree_warn"
  hdr "The bash bats runs under"
  val bver -- p10_bats_env bash -c 'printf "%s" "$BASH_VERSION"'
  case "$bver" in
    3.2.57*) check_pass "bats runs under bash 3.2.57 (the first bash on its PATH)" "$bver" ;;
    "<dry:"*) ;;
    *) check_fail "bats runs under bash 3.2.57 (the first bash on its PATH)" "3.2.57" "${bver:-no bash}" ;;
  esac

  hdr "config.bats, egress_ui.bats and entrypoint.bats under bash 3.2"
  val want1 -t 120 -- p10_bats_env test/bats/bin/bats --count test/unit/config.bats test/unit/egress_ui.bats test/unit/entrypoint.bats
  say "bats --count finds $want1 tests in the three files. They take 5 to 15 minutes on a Mac."
  run_cmd -t 3600 -n "three bats files under bash 3.2" -- p10_bats_env ./test.sh test/unit/config.bats test/unit/egress_ui.bats test/unit/entrypoint.bats
  p10_tap suite.mac.three "the three files" "$want1"
  f1="$P10_OK of ${P10_N:-?} ok with $P10_SKIP skipped"

  hdr "The two relay regressions under bash 3.2"
  val want2 -t 120 -- p10_bats_env test/bats/bin/bats --count -f 'command line that names it|inherited their count' test/unit/regressions.bats
  if p10_int "$want2"; then
    expect_num "the filter names the two relay regressions" "$want2" eq 2
  elif [ "${DRY:-0}" != 1 ]; then
    check_fail "bats --count reads the relay regressions" "2" "${want2:-nothing}"
  fi
  run_cmd -t 1200 -n "the two relay regressions under bash 3.2" -- p10_bats_env ./test.sh -f 'command line that names it|inherited their count' test/unit/regressions.bats
  p10_tap suite.mac.relay "the relay regressions" 2
  f2="$P10_OK of ${P10_N:-?} ok"

  hdr "The tree after the bats runs"
  p10_tree_clean "after the bats runs"
  if [ "${DRY:-0}" != 1 ] && LC_ALL=C awk -F'\t' '$2 == "FAIL" || $2 == "TIMEOUT" { f = 1 } END { exit !f }' "$STEP_DIR/checks.tsv" 2>/dev/null; then
    warn "A red test file holds the run until it is fixed (scenario 0.1). Answer q at the question before sitting 1 and report it."
  fi

  kv_set suite.mac.files "config.bats egress_ui.bats entrypoint.bats $f1, the two relay regressions $f2, bats under bash $bver"
  if p10_int "$P10_HARNESS_COUNT"; then
    rec_set suite.linux "$P10_SUITE_COUNT tests passed with 1 skipped (bash 5) and $P10_HARNESS_COUNT of $P10_HARNESS_COUNT mutations caught with none skipped, by the agent on ac6ee85 on Linux only"
  else
    rec_set suite.linux "$P10_SUITE_COUNT tests passed with 1 skipped (bash 5) by the agent on ac6ee85 on Linux only. The harness count is not recorded here: read it from CI"
  fi
  p10_suite_rec
  return 0
}
reg 0.1s 0 auto gate st_0_1s "The three bats files and the two relay regressions under bash 3.2"

# ---------------------------------------------------------------------------------------------
# 0.1x The whole suite and the mutation harness on the Mac [EXTRA, optional in the scenario]
# ---------------------------------------------------------------------------------------------

st_0_1x() {
  local bver="" src=0 tot=0 pas=0 skp=0 fal=0 mt=0 mc=0 mm=0 ms=0
  p10_need_frozen
  cd "$MT_WT" || step_abort "cannot enter the candidate checkout $MT_WT"
  [ -f test/bats/bin/bats ] || step_abort "test/bats is missing in the candidate: run git submodule update --init --recursive there"
  # Rule 3: nothing runs tests in the worktree once the hand run is in progress. The harness
  # rewrites bin/cleat in place, under every session the candidate runs.
  if [ "${DRY:-0}" != 1 ] && LC_ALL=C awk -F'\t' 'NR > 1 && $2 ~ /^[1-3]\./ { f = 1 } END { exit !f }' "$RUN/results.tsv" 2>/dev/null; then
    step_skip "the hand run is in progress (a step of sitting 1 or later has run): rule 3 allows the whole suite and the harness only before sitting 1"
  fi
  run_cmd -q -e -- p10_test_boxes
  if [ -s "$OUT" ]; then
    step_skip "test boxes exist ($(p10_lines "$OUT")): rule 3 allows the whole suite and the harness only before sitting 1"
  fi
  on_cleanup "p10_tree_warn"
  val bver -- p10_bats_env bash -c 'printf "%s" "$BASH_VERSION"'

  hdr "The whole suite (./test.sh)"
  say "Every test file under bash $bver: about an hour on a Mac. Nothing to do meanwhile."
  run_cmd -t 14400 -n "the whole suite" -- p10_bats_env ./test.sh
  src=$RC
  expect_rc "./test.sh exits 0" 0
  # test.sh prints "All tests passed" and "  T total  P passed  S skipped  (Ns)" only on the whole-suite path
  expect_contains "test.sh says All tests passed" "All tests passed"
  expect_not_match "no test file failed" '^ +✖ '
  read -r tot pas skp fal <<P10_EOF
$(p10_suite_nums "$OUT")
P10_EOF
  record_value suite.mac.total "$tot total, $pas passed, $skp skipped, $fal failed" "the whole suite"
  if [ "$src" != 0 ] && [ "${DRY:-0}" != 1 ]; then
    check_skip "the mutation harness" "the whole suite failed first: fix it, then ./egress-release.sh --only 0.1x"
    kv_set suite.mac.full "whole suite FAILED ($fal failed of $tot) under bash $bver, harness not run"
    p10_suite_rec
    return 0
  fi

  hdr "The mutation harness (MUTATION_MAX_SKIPPED=0)"
  say "Every registered mutation against its own test: several hours. It restores every file it rewrites."
  run_cmd -t 43200 -n "the mutation harness" -- p10_bats_env env MUTATION_MAX_SKIPPED=0 ./test/mutation_regressions.sh
  expect_rc "the harness exits 0" 0
  # test/mutation_regressions.sh: the summary "  Total:", "  Caught:", "  Missed:", "  Skipped:" (lines 18134 to 18137)
  expect_match "Missed: 0" '^ *Missed: +0$'
  expect_match "Skipped: 0" '^ *Skipped: +0$'
  read -r mt mc mm ms <<P10_EOF
$(p10_harness_nums "$OUT")
P10_EOF
  expect_eq "every mutation is caught (Caught equals Total)" "$mc" "$mt"
  record_value suite.mac.harness "$mc of $mt caught, $mm missed, $ms skipped" "the mutation harness"

  hdr "The tree after the harness: git status --short prints nothing"
  p10_tree_clean "after the harness (it restores every file it rewrote)"
  kv_set suite.mac.full "whole suite $pas passed of $tot with $skp skipped, harness $mc of $mt mutations caught with $ms skipped, under bash $bver"
  p10_suite_rec
  return 0
}
reg 0.1x 0 auto extra st_0_1x "The whole suite and the mutation harness on the Mac"

# ---------------------------------------------------------------------------------------------
# 0.2 The env file
# ---------------------------------------------------------------------------------------------

st_0_2() {
  p10_need_frozen
  cd "$MT_WT" || step_abort "cannot enter the candidate checkout $MT_WT"
  hdr "Block A: the env file"
  env_write
  expect_contains "the env file holds block A" "# Egress first-release test. In every terminal: /bin/bash, then: source ~/mt-eg-env.sh" "$ENVF"
  expect_contains "it defines cleat as the candidate with the isolated config" 'cleat()    { XDG_CONFIG_HOME="$EGX"' "$ENVF"

  hdr "Block B: the env file sourced under $MT_BASH"
  env_check
  expect_rc "block B exits 0" 0
  expect_not_contains "no NOT BASH 3.2 line" "NOT BASH 3.2"
  expect_line "type cleat | head -1 prints: cleat is a function" "cleat is a function"
  # bin/cleat:35871 cmd_version prints "cleat v$VERSION", VERSION="1.5.4" at bin/cleat:5
  expect_contains "cleat --version prints cleat v1.5.4" "cleat v1.5.4"
  # bin/cleat:12885, the help row "egress why <host|pkg> [box]": the released v1.5.4 has no egress verb
  expect_line "cleat egress --help | grep -c 'egress why' prints 1 (this is the candidate)" "1"
  return 0
}
reg 0.2 0 auto gate st_0_2 "The env file"

# ---------------------------------------------------------------------------------------------
# 0.3 Host facts, recorded once [RELEASE GATE]
# ---------------------------------------------------------------------------------------------

st_0_3() {
  local macos="" arch="" eng="" api="" plat="" uid="" gid="" kind="" guess="" vmm="" fs="" r=0
  p10_need_frozen
  cd "$MT_WT" || step_abort "cannot enter the candidate checkout $MT_WT"
  hdr "egcheck"
  run_cmd -- egcheck
  # egcheck is the env file's own (scenario block A), less the script's own files
  expect_contains "egcheck: tree: clean" "tree: clean"
  expect_not_contains "egcheck: no test lock line" "test lock held in the worktree"

  hdr "The Mac"
  if command -v sw_vers > /dev/null 2>&1; then
    val macos -- sw_vers -productVersion
  else
    macos="not macOS"
  fi
  record_value host.macos "${macos:-unknown}" "macOS (sw_vers -productVersion)"
  val arch -- uname -m
  record_value host.arch "$arch" "uname -m"
  run_cmd -- "$MT_BASH" --version
  first_lines 1
  expect_contains "the bash cleat runs under is GNU bash, version 3.2.57" "GNU bash, version 3.2.57"
  record_value host.bash "$(p10_join "$OUT")" "$MT_BASH --version | head -1"

  hdr "Docker"
  dk -- version --format 'Engine {{.Server.Version}}, API {{.Server.APIVersion}}, {{.Server.Platform.Name}}'
  eng=$(awk '/^Engine / { v = $2; sub(/,$/, "", v); print v; exit }' "$OUT" 2>/dev/null)
  api=$(awk '/^Engine / { v = $4; sub(/,$/, "", v); print v; exit }' "$OUT" 2>/dev/null)
  plat=$(sed -n 's/^Engine [^,]*, API [^,]*, //p' "$OUT" 2>/dev/null | head -n 1)
  p10_check_ge "Engine at or above 20.10 (the egress floor)" "$eng" 20.10
  p10_check_ge "API at or above 1.41 (the egress floor)" "$api" 1.41
  record_value docker.engine "$eng" "Docker Engine"
  record_value docker.api "$api" "Docker API"
  record_value docker.platform "$plat" "Docker platform"
  dk -- info --format 'driver={{.Driver}} os={{.OperatingSystem}} name={{.Name}} cpus={{.NCPU}} mem={{.MemTotal}}'
  # Docker's own words. bin/cleat:10910-10912 (_egress_engine_kind) requires the same two for a desktop-* kind
  expect_contains "Docker Desktop's own engine" "os=Docker Desktop name=docker-desktop"
  record_value docker.info "$(p10_join "$OUT")" "docker info"

  hdr "Your account"
  val uid -- id -u
  val gid -- id -g
  record_value host.uid "$uid" "id -u"
  record_value host.gid "$gid" "id -g"
  if p10_int "$uid" && p10_int "$gid" && { [ "$uid" != 501 ] || [ "$gid" != 20 ]; }; then
    check_note "uid $uid and gid $gid are not those of a default first account (501 and 20). Not a failure."
  fi

  hdr "The engine kind (W11: the reader docs/egress-validation.md gives)"
  val kind -t 120 -- egkind
  expect_eq "egkind prints $MT_EXPECT_ENGINE" "$kind" "$MT_EXPECT_ENGINE"
  record_value egress.kind "$kind" "engine kind"

  hdr "Docker Desktop: the virtual machine manager and the file sharing implementation"
  run_cmd -q -- dd_settings_guess
  p10_dd_pairs "$OUT" > "$STEP_DIR/dd-settings.txt"
  guess=$(p10_dd_guess "$STEP_DIR/dd-settings.txt")
  vmm="${guess%%|*}"; fs="${guess#*|}"
  [ -n "$vmm" ] || vmm=unknown
  [ -n "$fs" ] || fs=unknown
  if [ "$vmm" != unknown ] && [ "$fs" != unknown ]; then
    say_do Mac "Open Docker Desktop, Settings, General. Read two settings there: the virtual machine
manager and the file sharing implementation. Docker Desktop's settings file says:
$(sed 's/^/  /' "$STEP_DIR/dd-settings.txt")
which reads as
  Virtual machine manager: $vmm
  File sharing implementation: $fs (VirtioFS expected)"
    choose dd-settings "Do both settings read so in Settings, General?" "y=both read as shown" "n=one differs: type both"
    r=0
    [ "$CHOICE" = y ] || r=1
  else
    say_do Mac "Open Docker Desktop, Settings, General. Read two settings there: the virtual machine manager
and the file sharing implementation (VirtioFS expected). Type each exactly as it reads."
    r=1
  fi
  if [ "$r" = 1 ]; then
    read_line dd-vmm "The virtual machine manager, as Settings, General shows it:" vmm
    read_line dd-fileshare "The file sharing implementation, as Settings, General shows it:" fs
  fi
  [ -n "$vmm" ] || vmm="not read"
  [ -n "$fs" ] || fs="not read"
  record_value dd.vmm "$vmm" "virtual machine manager"
  record_value dd.fileshare "$fs" "file sharing implementation"
  case "$fs" in
    VirtioFS|"not read"|dry) ;;
    *) check_note "file sharing reads $fs: the scenario expects VirtioFS" ;;
  esac
  return 0
}
reg 0.3 0 mixed gate st_0_3 "Host facts"

# ---------------------------------------------------------------------------------------------
# 0.4 A clean starting state [RELEASE GATE]
# ---------------------------------------------------------------------------------------------

st_0_4() {
  local made="" left=0 g=0 v=0 h=0 real="" cnt=0 names="" running="" listable=""
  p10_need_frozen
  made=$(kv_get p.made "")
  cd "$HOME" || step_abort "cannot enter $HOME"

  hdr "Test objects of an earlier attempt (egobjs)"
  run_cmd -- egobjs
  read -r g v h <<P10_EOF
$(p10_egobjs_counts "$OUT")
P10_EOF
  if [ -z "$made" ]; then
    expect_eq "egobjs lists no gateway" "$g" 0 || left=$((left + 1))
    expect_eq "egobjs lists no socket volume" "$v" 0 || left=$((left + 1))
    expect_eq "egobjs lists no host file" "$h" 0 || left=$((left + 1))
  else
    check_skip "egobjs lists nothing" "this run made $P already: a clean start is judged only before it creates anything"
  fi
  run_cmd -- p10_leftover_ls
  if [ -z "$made" ]; then
    expect_not_match "no leftover test directory or config (the ls -d prints nothing)" '.' || left=$((left + 1))
  else
    check_skip "no leftover test directory or config" "this run made $P already"
  fi
  run_cmd -- p10_cfg_ls
  record_value cfg.ls "$(p10_lines "$OUT")" "ls \$CFG (state only, made by 0.2's two commands)"
  if [ -z "$made" ]; then
    expect_not_match "\$CFG holds no config, run or egress-* yet" '^(config|run|egress-.*)$' || left=$((left + 1))
  fi
  if [ ! -s "$OUT" ] && [ "${DRY:-0}" != 1 ]; then
    check_note "\$CFG is empty or absent: the scenario expects state there, made by 0.2's two commands"
  fi

  hdr "Your real config: no policy"
  run_cmd -- p10_real_egress
  real=$(awk 'NF { print $1; exit }' "$OUT" 2>/dev/null)
  [ -f "$HOME/.config/cleat/config" ] || check_note "there is no ~/.config/cleat/config: it holds no policy"
  expect_eq "grep -c '^\[egress\]' ~/.config/cleat/config prints 0" "${real:-nothing}" 0
  if p10_int "$real"; then record_value realcfg.egress "$real" "[egress] sections in your real config"; fi

  hdr "Your daily boxes, running or stopped (sitting 3 stops all of them)"
  check_note "Your daily boxes keep running through sittings 0 to 2. Sitting 3 quits Docker Desktop, which ends every session on this Mac: plan for it."
  # docker's own exit code and its stderr kept apart: an error never reads as a box name.
  dk -q -e -- ps -a --format '{{.Names}}'
  if ! expect_rc "docker ps -a lists the containers" 0; then
    sed 's/^/    stderr: /' "$ERR"
    [ -n "$made" ] || left=$((left + 1))   # no list, so no test box of an earlier attempt can be ruled out
  fi
  grep_lines '^cleat-'
  say "\$ docker ps -a --format '{{.Names}}' | grep '^cleat-'"
  sed 's/^/    /' "$OUT"
  if [ -z "$made" ]; then
    expect_not_match "no test box of an earlier attempt (cleat-eg-*)" '^cleat-eg-' || left=$((left + 1))
  fi
  names=$(p10_not_test "$OUT" | tr '\n' ' ')
  cnt=$(p10_not_test "$OUT" | awk 'END { print NR + 0 }')
  kv_set daily.names "${names% }"
  record_value daily.count "$cnt" "daily boxes the docker ps -a line listed (1.2 compares against it)"
  dk -q -e -- ps --format '{{.Names}}'
  expect_rc "docker ps lists the running ones" 0 || sed 's/^/    stderr: /' "$ERR"
  running=$(p10_not_test "$OUT" | tr '\n' ' ')
  kv_set daily.running "${running% }"
  record_value daily.running.count "$(p10_not_test "$OUT" | awk 'END { print NR + 0 }')" "of them running now"
  run_cmd -q -e -t 180 -- p10_listable
  [ "$RC" = 0 ] || check_note "the boxes a policy would list could not be read (rc $RC)"
  p10_names "$OUT" > "$STEP_DIR/listable.txt"
  listable=$(p10_lines "$STEP_DIR/listable.txt")
  kv_set daily.listable "$listable"
  record_value daily.listable.count "$(p10_count "$STEP_DIR/listable.txt")" "of them the refusing-boxes note of 1.2a should list (made from the $MT_IMAGE image)"
  safe_rm "$SCRATCH/mt-listable"

  hdr "Sleep assertions (sitting 3 needs both counts at 0 and no holder)"
  if host_can || [ "${DRY:-0}" = 1 ]; then
    pm_assertions
  else
    # pm_assertions would ask with ask, whose n is a FAIL. A count above 0 is only a note here.
    say_do Mac "In a terminal on the Mac run:
  pmset -g assertions | grep -E '^ +(PreventUserIdleSystemSleep|PreventSystemSleep) '
  pmset -g assertions | grep -E 'pid [0-9]+\(' | grep -E 'PreventUserIdleSystemSleep|PreventSystemSleep'"
    choose pm-read "Are both counts 0?" "y=both counts are 0" "n=one is not 0"
    PM_IDLE="?"; PM_SYS="?"; PM_HOLDERS=""
    if [ "$CHOICE" = y ]; then
      PM_IDLE=0; PM_SYS=0
    else
      read_line pm-holders "Which processes hold them (names only, from the second line)?" PM_HOLDERS
    fi
  fi
  record_value sleep.counts "PreventUserIdleSystemSleep ${PM_IDLE:-?} PreventSystemSleep ${PM_SYS:-?}" "sleep assertions"
  record_value sleep.holders "${PM_HOLDERS:-none}" "held by"
  if [ "${PM_IDLE:-?}" != 0 ] || [ "${PM_SYS:-?}" != 0 ]; then
    check_note "Something holds the Mac awake (${PM_HOLDERS:-holder unknown}). Sitting 3 needs both counts at 0 and no holder: turn it off before 3.3."
  fi

  hdr "The home of every test project: $P"
  if [ -n "$made" ]; then
    mkdir -p "$P" || step_abort "cannot create $P"
    check_note "$P was made by this run before (0.4): nothing judged again"
  elif [ "$left" -gt 0 ]; then
    check_note "Not making $P: $left leftover checks failed. Fix: run 3.5 of the earlier attempt first (./egress-release.sh --only 3.5 --run <its id>), or remove what it left as 3.5 lists. Never remove a gateway you cannot place. Then ./egress-release.sh --from 0.2 (3.5 also deletes ~/mt-eg-env.sh and ~/mt-egress-xdg, which 0.2 writes again)."
  else
    kv_set p.made "$(epoch_now)"
    say "\$ mkdir -p $P"
    mkdir -p "$P" || step_abort "cannot create $P"
    check_pass "made $P"
  fi
  return 0
}
reg 0.4 0 auto gate st_0_4 "A clean starting state"

# ---------------------------------------------------------------------------------------------
# 0.5 The box image at spec 6, built from this tree [RELEASE GATE]
# ---------------------------------------------------------------------------------------------

st_0_5() {
  local sw="" spec="" created="" ce="" age=0 cv="" nv="" rb="" cur="" late=0
  p10_need_frozen
  sw=$(kv_get image.swapped 0)
  if [ "$sw" = 1 ]; then
    # A decision, not a reading: choose, whose first option (keep) is also what an answers file
    # that names neither gets.
    choose img-swapped "2.24 holds the v1.5.4 image in $MT_IMAGE on purpose (kv image.swapped is 1). A rebuild puts this tree's image back, so 2.24 then starts again at 2.24-pre. Rebuild the image now?" "n=no: keep the image 2.24 holds (0.5 is skipped)" "y=yes: rebuild it now"
    [ "$CHOICE" = y ] || step_skip "kept the image 2.24 holds: resume 2.24, or run 0.5 again and answer y"
  fi
  # $P is 0.4's to make, once the start is clean. Making it here after a leftover FAIL of 0.4 would
  # turn every later attempt of 0.4 into a FAIL on this run's own directory.
  if [ "${DRY:-0}" != 1 ] && [ -z "$(kv_get p.made "")" ]; then
    step_abort "0.4 has not made $P yet: it makes it once nothing of an earlier attempt is left. Fix what 0.4 reported, then run ./egress-release.sh --from 0.2"
  fi
  mkdir -p "$P/eg-smoke" || step_abort "cannot create $P/eg-smoke"
  cd "$P/eg-smoke" || step_abort "cannot enter $P/eg-smoke"

  hdr "The $MT_IMAGE images before the rebuild (every tag)"
  dk -- image ls "$MT_IMAGE" --format '{{.Repository}}:{{.Tag}}  {{.ID}}  {{.CreatedSince}}'
  record_value image.tags.before "$(p10_join "$OUT")" "$MT_IMAGE tags before the rebuild"
  dk -q -- image inspect "$MT_IMAGE:mt-spec6" --format '{{.Id}}'
  if [ "$RC" = 0 ]; then
    # 2.24's rule: never remove mt-spec6 while MT_IMAGE reads spec 4, it may be the only copy of
    # the candidate image. Then the tag goes only after this rebuild has proved itself.
    val cur -- docker image inspect "$MT_IMAGE" --format '{{index .Config.Labels "sh.cleat.image-spec"}}'
    if [ "$cur" = 6 ] || [ "${DRY:-0}" = 1 ]; then
      say "A $MT_IMAGE:mt-spec6 tag 2.24 left in an earlier attempt is an older spec 6 build: removing the tag."
      img_rm "$MT_IMAGE:mt-spec6"
      [ "$RC" = 0 ] || check_note "$MT_IMAGE:mt-spec6 could not be removed (rc $RC): a container may still use it"
    else
      late=1
      check_note "$MT_IMAGE reads spec ${cur:-unknown}, so $MT_IMAGE:mt-spec6 may be the only copy of the candidate image. Its tag goes only after the rebuild passes egimg."
    fi
  else
    check_note "no $MT_IMAGE:mt-spec6 tag (nothing 2.24 left)"
  fi

  hdr "cleat rebuild: builds from the candidate's docker/ with --no-cache"
  say "5 to 15 minutes. Nothing to do meanwhile."
  clt -t 600 -T 3600 -n "cleat rebuild" -- rebuild
  rb="$STEP_DIR/rebuild-printed.txt"
  LC_ALL=C grep -v 'Rebuilding image\.\.\.$' "$OUT" 2>/dev/null | awk 'NF' | tail -n 40 > "$rb"
  say "  What it printed besides the spinner (a failed build prints its log here):"
  sed 's/^/    /' "$rb"
  expect_rc "cleat rebuild exits 0" 0
  # bin/cleat:21553 spin "Rebuilding image...", bin/cleat:21558 spin_stop "Image rebuilt" "Image build failed"
  expect_contains "it says Rebuilding image..." "Rebuilding image..."
  expect_contains "it says Image rebuilt" "Image rebuilt" "$rb"
  expect_not_contains "no Image build failed" "Image build failed" "$rb"
  [ "$RC" = 0 ] || step_abort "cleat rebuild failed: read the build log above, then ./egress-release.sh --only 0.5. Never go on without this tree's image: answer q at the question before sitting 1."
  # From here $MT_IMAGE is a build of this tree, whatever a later check of this step finds.
  if [ "$sw" = 1 ]; then
    kv_set image.swapped 0
    check_note "kv image.swapped is 0 again: $MT_IMAGE is this tree's image"
  fi

  hdr "The image's labels"
  dk -- image inspect "$MT_IMAGE" --format 'spec={{index .Config.Labels "sh.cleat.image-spec"}} version={{index .Config.Labels "sh.cleat.version"}}'
  # bin/cleat:21555-21557 label the build, _IMAGE_SPEC_VERSION=6 (bin/cleat:70), VERSION="1.5.4" (bin/cleat:5)
  expect_line "spec=6 version=1.5.4" "spec=6 version=1.5.4"
  spec=$(sed -n 's/^spec=\([^ ]*\) .*$/\1/p' "$OUT" 2>/dev/null | head -n 1)
  record_value image.spec "$spec" "the image-spec label"

  hdr "egimg: the image carries this tree's relay and entrypoint"
  run_cmd -t 300 -- egimg
  # egimg is the env file's own (scenario block A): it cmp's the image's files with docker/ of this tree
  expect_contains "relay: this tree's" "relay: this tree's"
  expect_contains "entrypoint: this tree's" "entrypoint: this tree's"
  record_value image.egimg "$(p10_join "$OUT")" "egimg"
  if LC_ALL=C grep -q "NOT this tree's" "$OUT" 2>/dev/null; then
    step_abort "the $MT_IMAGE image does not carry this tree's relay or entrypoint. Never go on with that image: answer q at the question before sitting 1, then ./egress-release.sh --only 0.5 rebuilds it. If it still differs, check that MT_WT is the worktree 0.1 froze."
  fi
  created=$(sed -n 's/.* created=\([^ ]*\).*$/\1/p' "$OUT" 2>/dev/null | head -n 1)
  ce=$(iso_to_epoch "$created")
  if p10_int "$ce"; then
    age=$(( $(epoch_now) - ce ))
    expect_num "the image was created less than 60 minutes ago (seconds)" "$age" lt 3600
    [ "$age" -ge -300 ] || check_note "created= is $((0 - age)) s in the future: the Docker VM's clock runs ahead of the Mac's"
  elif [ "${DRY:-0}" != 1 ]; then
    check_fail "egimg prints the image's created= stamp" "created=<a Docker stamp>" "${created:-nothing}"
  fi

  if [ "$late" = 1 ]; then
    say "The rebuild passed egimg: now the $MT_IMAGE:mt-spec6 tag goes."
    img_rm "$MT_IMAGE:mt-spec6"
    [ "$RC" = 0 ] || check_note "$MT_IMAGE:mt-spec6 could not be removed (rc $RC): a container may still use it"
  fi

  hdr "Claude Code and Node in the image"
  dk -e -t 180 -- run --rm --entrypoint sh "$MT_IMAGE" -c '/home/coder/.local/bin/claude --version; node --version'
  expect_rc "both print a version" 0
  expect_match "Claude Code prints its version" '^[0-9]+\.[0-9]+\.[0-9]+'
  expect_match "Node prints its version" '^v[0-9]+\.[0-9]+\.[0-9]+'
  cv=$(awk '/^[0-9]+\.[0-9]+\.[0-9]+/ { print $1; exit }' "$OUT" 2>/dev/null)
  nv=$(awk '/^v[0-9]+\./ { print $1; exit }' "$OUT" 2>/dev/null)
  record_value image.claude "$cv" "Claude Code in the image"
  record_value image.node "$nv" "Node in the image"

  hdr "The relay's tools in the image"
  dk -e -t 180 -- run --rm --entrypoint sh "$MT_IMAGE" -c 'for t in socat flock runuser mountpoint curl python3; do command -v $t >/dev/null || echo "missing $t"; done; test -x /usr/local/bin/cleat-egress-shim && echo relay-present'
  # docker/Dockerfile:100-101 copies the relay to /usr/local/bin/cleat-egress-shim, socat and curl are installed there
  expect_line "relay-present" "relay-present"
  expect_not_match "no missing tool" '^missing '

  check_note "This replaced $MT_IMAGE:latest, which your daily v1.5.4 boxes also use. The relay stays idle in a box without the socket volume. 1.1 builds and tags $MT_IMAGE again from the same tree."
  return 0
}
reg 0.5 0 expect gate st_0_5 "The box image at spec 6, built from this tree"

# ---------------------------------------------------------------------------------------------
# 0.6 The gateway image [RELEASE GATE]
# ---------------------------------------------------------------------------------------------

st_0_6() {
  local pfile=""
  p10_need_frozen
  [ -n "$GWIMG" ] || step_abort "bin/cleat names no _GATEWAY_IMAGE: MT_WT is not the candidate"
  cd "$HOME" || step_abort "cannot enter $HOME"
  hdr "The pinned gateway image: echo \"\$GWIMG\""
  run_cmd -- printf '%s\n' "$GWIMG"
  expect_match "it is pinned by digest" '@sha256:[0-9a-f]{64}$'
  record_value gwimg.ref "$GWIMG" "the gateway image (_GATEWAY_IMAGE in bin/cleat)"

  hdr "Its platforms"
  dk -q -t 60 -- buildx version
  if [ "$RC" = 0 ]; then
    dk -t 180 -- buildx imagetools inspect "$GWIMG"
    expect_rc "docker buildx imagetools inspect reads the index" 0
    grep_lines 'Platform:'
    pfile="$OUT"
  else
    check_note "docker buildx is missing: docker manifest inspect reads the same index"
    dk -t 180 -- manifest inspect "$GWIMG"
    expect_rc "docker manifest inspect reads the index" 0
    pfile="$STEP_DIR/platforms.txt"
    p10_platforms "$OUT" > "$pfile"
    sed 's/^/    /' "$pfile"
  fi
  expect_match "linux/amd64 is listed" 'Platform:[[:space:]]+linux/amd64' "$pfile"
  expect_match "linux/arm64 is listed" 'Platform:[[:space:]]+linux/arm64' "$pfile"
  record_value gwimg.platforms "$(awk '{ print $2 }' "$pfile" 2>/dev/null | sort -u | tr '\n' ' ')" "platforms listed"

  hdr "Present on this Mac?"
  dk -q -- image inspect "$GWIMG" --format '{{.Id}}'
  if [ "$RC" = 0 ]; then
    record_value gwimg.present 1 "present (1.1b-prep removes it on purpose)"
  else
    record_value gwimg.present 0 "not present: 1.1 pulls it"
  fi
  check_note "Listed is not started: the amd64 gateway image has never run. The record says arm64 only unless 2.31 runs."
  return 0
}
reg 0.6 0 auto gate st_0_6 "The gateway image"
