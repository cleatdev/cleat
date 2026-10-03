# egress-release.d/20-smoke.sh: sitting 1: 1.1 to 1.4 (integration branch B, the default, the first caged launch, session end).
#
# A part of egress-release.sh. Sourced, never run. It holds only function definitions, reg calls
# and comments: nothing else runs at source time. One function per step, named st_ plus the id
# with . and - turned into _, registered in scenario order with
#   reg ID SITTING KIND CLASS FUNC "TITLE"
# The steps, their checks and their re-entry rules are DESIGN.md section 6.2. Every expected string
# below was read in the candidate first. Its source line is the comment beside it.
#
# The steps
#   1.1          the integration file, branch B, outside any box (auto, no human)
#   1.1b-prep    the gateway image removed, no policy (auto)
#   1.1b-launch  cleat then cleat resume in eg-default (T1: /exit twice, a login note, a speed note)
#   1.1b-shell   cleat shell in eg-default: none of the four caged settings (expect)
#   1.1b-check   network, fragment, no socket dir, cleat rm (auto)
#   1.2a         the first allow and the refusing-boxes note (expect)
#   1.2-pull     EXTRA: a failed first pull with the network cut (Wi-Fi by host control)
#   1.2b         the first caged launch (T1: a login if asked, send reply with just ok, stay)
#   1.3a         status, 200, the 403 and its body (expect)
#   1.3b         the same through cleat shell (expect)
#   1.3c         why, test, log and status agree (expect)
#   1.3d         what Claude does at a denial (T1: one question to Claude, recorded)
#   1.4a         the session-end report (T1: /exit)
#   1.4b         the log, stop, status and the objects left (expect)
#
# The stop rule (a FAIL in sitting 1 ends the run) is the framework's: egress-release.sh stops at
# once when a sitting 1 gate fails (mt__run_step) and again at the sitting boundary (mt__boundary).
# Every step here is a gate except 1.2-pull, so nothing in this part has to call it.
#
# Where this part departs from the scenario (and why)
#   1. 1.2b in T1 typed mode cannot read "Pulling the egress gateway image". On a terminal the
#      spinner redraws that line with a carriage return and spin_stop erases it before it prints
#      the ready line (bin/cleat:545 spin, 582 spin_stop), so Terminal's history never holds it.
#      The check is SKIP there with that reason. The ready line (printed only after a pull,
#      bin/cleat:11536) and the pulled image's architecture against the daemon's stand for it.
#      In T1 auto mode the raw log keeps every frame and the line is checked as written.
#      F1 (ac6ee85): spin and spin_stop print their message with printf %s on a terminal
#      (bin/cleat:567, 593), so a ${DIM} in it showed as the text \033[2m (bin/cleat:253, 266).
#      Both gateway image lines are plain text now (bin/cleat:11528, 11536). A colour code shown
#      as text in the launch output is a FAIL tagged (F1), a regression of that fix. The checks
#      after it then read the lines with the literal codes taken out, so F1 fails once, not on
#      every line it touches. In human mode the pull-escape question asks. Its n is a FAIL.
#   2. 1.2b on re-entry (the box exists, Claude does not run) relaunches with cleat, which opens a
#      fresh session in the existing box with the same summary (bin/cleat cmd_start). cleat resume
#      would pass --continue and end on Claude Code's own "No conversation found" when the cut
#      attempt never sent a message. The two pull lines, Packs pinned and the host.docker.internal
#      notice print once per box, at its first launch (bin/cleat:12462, 12502), so they are SKIP
#      on that path. 1.3d reopens a session the same way.
#   3. 1.2b runs cleat egress status on the script's pty right after the launch whenever T1 printed
#      Shim not listening (W5: "run cleat egress status in T2 at once"). It also runs it whenever
#      the launch output cannot be read back (human mode, item 10), so the evidence exists before
#      the question is asked.
#   4. 1.3b runs sudo -n -i id -u, then sudo -n -i curl -sS https://example.com/, instead of an
#      interactive sudo -i and a curl typed into root's shell. -n makes a password prompt fail
#      instead of hang. The id line proves the curl really ran as root (a sudo that refused
#      would otherwise pass as "root cannot reach the network"). DESIGN.md section 8 item 4.
#      F3 (ac6ee85): neither sudo prints "sudo: unable to resolve host" and the box's hostname is
#      in its /etc/hosts (a caged box names itself there, docker/entrypoint.sh:50 to 53).
#      F2 (ac6ee85): /home/coder/.npm and everything under it belong to the box user (the
#      entrypoint's chown, docker/entrypoint.sh:94). Both are gate checks of 1.3b, tagged (Fn).
#   5. 1.3b checks curl's exit codes (56, 6) beside its messages. The messages are curl's own, not
#      cleat's: they are quoted from the scenario and cannot be grepped in the candidate.
#   6. 1.2a on re-entry drops the [egress] section an earlier attempt of 1.2a wrote, but only when
#      it is exactly what 1.2a writes (mode = strict, allow = example.com) and no caged box, gateway
#      or pin exists yet. Otherwise it ends as SKIP: the first allow cannot be repeated, the earlier
#      attempt's result stands and a re-run by hand never triggers the stop rule.
#   7. 1.1 refuses (SKIP) when MT_IMAGE is not cleat and test/integration/egress.bats still builds
#      and runs the image cleat (lines 50 and 399): it would replace the real cleat image.
#   8. 1.1b-check also checks that cn eg-default is empty after cleat rm (the scenario's reason for
#      the rm is 1.2's note).
#   9. 1.4a reads the session end from the last "Session ended. Resume with: cleat resume" line
#      (bin/cleat:20274) or "Claude exited with code N" (bin/cleat:20276, a non-zero exit prints no
#      Session ended line). With neither it reads the whole capture and says so in a NOTE.
#  10. In T1 typed mode a launch region with no Egress: line at all is asked instead of checked.
#      Claude Code can clear the screen and the scrollback when it draws, which takes the launch
#      summary out of Terminal's history. The human watched it (p20_launch brings T1 to the
#      front), so a missing history never reads as a product FAIL. Auto mode always checks.
#  11. 1.1b-launch and 1.1b-shell end as SKIP when the isolated config already holds an [egress]
#      section (1.2a ran): a launch would create a caged eg-default box with a gateway of its own,
#      which 1.4b's "one gateway" would then count.
#  12. 1.2b also records the gateway image's architecture against the daemon's after the pull,
#      and 1.1b-check checks the gateway image is still absent after the two launches.
#  13. 1.1b-launch asks the human to send "reply with just ok" in the first session, which the
#      scenario does not. cleat resume reopens the box's latest conversation and falls back to
#      claude --continue when there is none (bin/cleat:22993 to 23012), which Claude Code ends
#      with "No conversation found to continue" when a session saw no message. A resume that still
#      opens no Claude because of that is a NOTE, never a FAIL: its summary is checked all the same.
#
# kv this part writes (DESIGN.md section 7.1): int.walltime, rec.intb, int.date, int.gw.before,
# int.vol.before (1.1), note.1.2.count, note.1.2.running (1.2a), eg-smoke.cn, eg-smoke.gw,
# eg-smoke.bh (1.3a), p20.rm.1-1b, p20.stop.1-4b and p20.launch.1-2b (the part's own re-entry marks),
# report.1.4.count, report.1.4.named, report.1.4.hosts, report.1.4.read (1.4a),
# denied.1.4 (1.4b: the hosts the log lists as denied, space separated, the list 2.25 compares),
# plus VALUEs for the record: shell.1.1b, net.1.1b, gwimg.before.1.2b, gwpull.arch, gwimg.arch,
# docker.arch, root.curl.1.3b, claude.1.3d, step13b.npm (F2: the owner of /home/coder/.npm, the box
# user's uid and how many entries under it the box user does not own).
#
# Helpers this part adds (the library lacks them), all prefixed p20_. The ones that call docker
# are only ever run through run_cmd or val.

# ---------------------------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------------------------

# p20_is_int VALUE: rc 0 for a whole non-negative number (a dry-run <dry:x> is not one).
p20_is_int() {
  case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac
  return 0
}
# p20_cd PROJ: into $P/PROJ, made when missing (the scenario's mkdir -p before each cd).
p20_cd() {
  mkdir -p "$P/$1" || fatal "cannot make $P/$1"
  cd "$P/$1" || fatal "cannot cd to $P/$1"
}
# p20_live PROJ: rc 0 when Claude Code runs in PROJ's box. Never live in a dry run, so the walk
# takes the launch path.
p20_live() {
  [ "${DRY:-0}" = 1 ] && return 1
  run_cmd -q -t 60 -- box_claude_live "$1"
}
# p20_need_running PROJ STEP: the box runs, else the step stops naming the step that starts it.
p20_need_running() {
  run_cmd -q -t 60 -- box_running "$1"
  [ "$RC" = 0 ] || step_abort "the $1 box is not running: run --only $2 first"
}
# p20_box PROJ: P20_BOX is the box's name when it exists, else empty (always empty in a dry run).
p20_box() {
  P20_BOX=""
  [ "${DRY:-0}" = 1 ] && return 0
  val P20_BOX -- cn "$1"
  return 0
}
# p20_count_gw, p20_count_vol: the scenario's two wc -l lines of 1.1 (run through val).
p20_count_gw() { docker ps -aq --filter label=sh.cleat.role=gateway | wc -l | tr -d ' '; }
p20_count_vol() { docker volume ls -q --filter label=sh.cleat.role=egress-sock | wc -l | tr -d ' '; }
# p20_spec_label: the image-spec label of MT_IMAGE (1.1's "still 6").
p20_spec_label() { docker image inspect "$MT_IMAGE" --format '{{index .Config.Labels "sh.cleat.image-spec"}}'; }
# p20_img_state REF: present or absent.
p20_img_state() {
  if docker image inspect --format '{{.Id}}' "$1" > /dev/null 2>&1; then echo present; else echo absent; fi
}
# p20_net_state: online or offline (the host reaches https://example.com/ or not).
p20_net_state() {
  if net_online; then echo online; else echo offline; fi
}
# p20_egress_sections: the count of [egress] lines in the isolated config, 0 without a file.
p20_egress_sections() {
  if [ -f "$CFG/config" ]; then
    LC_ALL=C awk '/^\[egress\]/ { n++ } END { print n + 0 }' "$CFG/config"
  else
    echo 0
  fi
}
# p20_no_policy_yet STEP: 1.1b is egress never turned on. Once 1.2a has written a policy, a 1.1b
# launch would create a caged eg-default box with a gateway of its own (and its shell would refuse),
# so the step ends as SKIP (a re-run by hand, not a product failure: no stop rule) before it makes
# objects the rest of sitting 1 does not expect.
p20_no_policy_yet() {
  local n
  val n -- p20_egress_sections
  if p20_is_int "$n" && [ "$n" -gt 0 ]; then
    step_skip "the isolated config already holds an [egress] section (1.2a ran): $1 shows the default only before it, so its earlier result stands. To repeat it: 3.5 of this attempt, then a new run"
  fi
  return 0
}
# p20_policy_is_12a FILE: yes when its [egress] section holds exactly what 1.2a's allow writes
# (bin/cleat:14216 and _write_egress_to_file: "mode = strict", then "allow = example.com").
p20_policy_is_12a() {
  [ -f "$1" ] || { echo no; return 0; }
  LC_ALL=C awk '
    /^[ \t]*\[egress\][ \t]*$/ { sec = 1; next }
    /^[ \t]*\[/ { sec = 0 }
    sec && NF { n++; l = $0; sub(/^[ \t]+/, "", l); sub(/[ \t\r]+$/, "", l); if (l == "mode = strict") m++; else if (l == "allow = example.com") a++; else o++ }
    END { print ((n == 2 && m == 1 && a == 1 && o == 0) ? "yes" : "no") }' "$1"
}
# p20_drop_egress FILE: the [egress] section out of FILE (the next section header and all else
# kept). Written through a temp file in the same directory, then copied back over (same inode).
p20_drop_egress() {
  local f="$1" t
  [ -f "$f" ] || return 0
  t="${f%/*}/.p20-drop.$$"
  LC_ALL=C awk '/^[ \t]*\[egress\][ \t]*$/ { sec = 1; next } /^[ \t]*\[/ { sec = 0 } !sec { print }' "$f" > "$t" || { rm -f "$t"; return 1; }
  cat "$t" > "$f"
  rm -f "$t"
  grep -c '^\[egress\]' "$f"
  return 0
}
# p20_int_names_cleat FILE: lines of the integration file that build or run the image cleat by name.
p20_int_names_cleat() {
  [ -f "$1" ] || { echo 0; return 0; }
  LC_ALL=C awk '/-t cleat( |$)|image inspect cleat( |$)| cleat -A / { n++ } END { print n + 0 }' "$1"
}
# p20_count FILE ERE: lines matching ERE (never grep -c, which exits 1 on zero).
p20_count() {
  [ -f "$1" ] || { echo 0; return 0; }
  LC_ALL=C grep -E -e "$2" "$1" 2>/dev/null | awk 'END { print NR + 0 }'
}
# p20_first FILE: the first non-empty line, trimmed.
p20_first() {
  [ -f "$1" ] || return 0
  LC_ALL=C awk 'NF { sub(/^[ \t]+/, ""); sub(/[ \t]+$/, ""); print; exit }' "$1"
}
# p20_section FILE NAME: the lines egobjs prints under "-- NAME:".
p20_section() {
  LC_ALL=C awk -v h="-- $2:" '$0 == h { on = 1; next } /^-- / { on = 0 } on && NF { print }' "$1"
}
# p20_ls_names DIR: the entries of DIR (ls -A), nothing when it does not exist.
p20_ls_names() {
  [ -d "$1" ] || return 0
  ls -A "$1"
}
# p20_note_rows FILE: the box names the refusing-boxes note lists (bin/cleat:13179 to 13188).
p20_note_rows() {
  [ -f "$1" ] || return 0
  LC_ALL=C awk '
    /created without egress control\. (Each|It) refuses to start/ { s = 1; next }
    s && /until it is recreated:/ { r = 1; next }
    r && /^[ \t]+cleat-/ { print $1; next }
    r { r = 0; s = 0 }' "$1"
}
# p20_note_value KEY: the VALUE note_check recorded as KEY in this attempt (note.count, note.running).
p20_note_value() {
  [ -f "$STEP_DIR/checks.tsv" ] || return 0
  awk -F'\t' -v k="$1" '$2 == "VALUE" && $3 == k { v = $5 } END { print v }' "$STEP_DIR/checks.tsv"
}
# p20_pull_arch FILE: the architecture the pull line names (bin/cleat:11528).
p20_pull_arch() {
  [ -f "$1" ] || return 0
  LC_ALL=C sed -n 's/.*Pulling the egress gateway image (ghcr\.io\/cleatdev\/cleat-gw, \([a-z0-9_]*\)).*/\1/p' "$1" | head -n 1
}
# p20_end_region FILE: the session end, from the last "Session ended. Resume with: cleat resume"
# (bin/cleat:20274) or "Claude exited with code N" (bin/cleat:20276) to the end. Without either
# line the whole capture follows a first line __P20_NO_END_LINE__.
p20_end_region() {
  LC_ALL=C awk '/Session ended\. Resume with: cleat resume|Claude exited with code [0-9]+/ { k = 0; f = 1 }
    { line[++k] = $0 }
    END { if (!f) print "__P20_NO_END_LINE__"; for (i = 1; i <= k; i++) print line[i] }' "$1"
}
# p20_report_count FILE: the count the report's first line gives (bin/cleat:20682, 20684), 0 when
# no report printed.
p20_report_count() {
  [ -f "$1" ] || { echo 0; return 0; }
  LC_ALL=C awk '/1 destination was denied by egress policy this session/ { c = 1 }
    / destinations were denied by egress policy this session/ { for (i = 1; i <= NF; i++) if ($i ~ /^[0-9]+$/) { c = $i; break } }
    END { print c + 0 }' "$1"
}
# p20_report_hosts FILE: the hosts the report's rows name (printf "      %-44s %s", bin/cleat:20708
# to 20713), one per line, a group "a, b" split, "(truncated)" dropped. A row of 44 characters or
# more has one space before its pack column, so a trailing "no pack" or "pack NAME" is cut too.
p20_report_hosts() {
  [ -f "$1" ] || return 0
  LC_ALL=C awk '
    /denied by egress policy this session/ { r = 1; next }
    r && /^[ \t]*$/ { r = 0; next }
    r && / on a port other than 443/ { next }
    r && /^      and [0-9]+ more/ { next }
    r && /^      [^ ]/ {
      s = $0; sub(/^ +/, "", s); i = index(s, "  "); if (i) s = substr(s, 1, i - 1)
      sub(/ (no pack|pack [^ ]+)$/, "", s)
      k = split(s, a, ", ")
      for (j = 1; j <= k; j++) { h = a[j]; sub(/ \(truncated\)$/, "", h); if (h != "" && !seen[h]++) print h }
    }' "$1"
}
# p20_log_hosts FILE: the hosts of the "x denied" rows of cleat egress log (bin/cleat:13939),
# first seen first, the port dropped.
p20_log_hosts() {
  [ -f "$1" ] || return 0
  LC_ALL=C awk '{ for (i = 1; i < NF; i++) if ($i == "x" && $(i + 1) == "denied") { h = $(i + 2); sub(/:[0-9]+$/, "", h); if (h != "" && !seen[h]++) print h; break } }' "$1"
}
# p20_has_literal_esc FILE: rc 0 when FILE holds a colour code printed as text (a backslash, 033
# and a bracket), the way spin and spin_stop showed ${DIM} on a terminal before F1 (departure 1).
p20_has_literal_esc() {
  [ -f "$1" ] && LC_ALL=C grep -q -F -e '\033[' "$1"
}
# p20_strip_literal_esc FILE: FILE with every colour code printed as text taken out.
p20_strip_literal_esc() {
  LC_ALL=C sed -e 's/\\033\[[0-9;]*m//g' "$1"
}
# p20_esc_check WHERE: F1 on OUT, the launch output. A colour code shown as text is a FAIL (the
# old behaviour of bin/cleat:11528 and 11536). OUT is then the same text with the literal codes
# taken out, so the checks after it read the words the scenario quotes and F1 fails only here.
p20_esc_check() {
  expect_not_contains "no colour code shown as text in $1: the gateway image lines are plain text (F1)" '\033['
  if [ "${DRY:-0}" != 1 ] && p20_has_literal_esc "$OUT"; then run_cmd -q -- p20_strip_literal_esc "$OUT"; fi
  return 0
}
# p20_npm_own PROJ: F2's reading of the box's npm directory as the box user: "owner=<uid or none>
# user=<uid> foreign=<entries under it the box user does not own>".
p20_npm_own() {
  bx "$1" sh -c 'u=$(id -u); if [ -e /home/coder/.npm ]; then printf "owner=%s user=%s foreign=%s\n" "$(stat -c %u /home/coder/.npm)" "$u" "$(find /home/coder/.npm ! -user "$u" 2>/dev/null | wc -l | tr -d " ")"; else printf "owner=none user=%s foreign=0\n" "$u"; fi'
}
# p20_hosts_named PROJ: F3's reading: "named" when the box's hostname is a word of its /etc/hosts,
# else "missing". The hostname itself (the container id) never reaches the record.
p20_hosts_named() {
  bx "$1" sh -c 'h=$(hostname); if [ -n "$h" ] && grep -qwF -- "$h" /etc/hosts; then echo named; else echo missing; fi'
}
# p20_no_conversation: rc 0 when the cleat resume that just ended in T1 opened no Claude because
# Claude Code found no conversation to continue (departure 13). Read from T1 when it can be,
# else the human is asked.
p20_no_conversation() {
  local r
  if t_have_capture; then
    if t_capture t1 resume-end && [ -f "$OUT" ] && LC_ALL=C grep -q -i -e 'no conversation found' "$OUT"; then
      return 0
    fi
    [ "$(t_mode)" = human ] || return 1
  fi
  p20_ask_record noconv T1 "Read what T1 printed after cleat resume, below its summary." "Did it end on Claude Code's own words No conversation found to continue, with no Claude session opened?"
  r=$?
  [ "$r" = 0 ]
}
# p20_launch PROJ CMD [SECS] [noconv]: CMD in T1 from $P/PROJ, then the wait for Claude Code.
# P20_LRC is t_wait_launch's code: 0 live, 1 the command ended without Claude, 2 skipped, 3 timed
# out. With noconv (the scenario's cleat resume of 1.1b) a command that ended on Claude Code's own
# "No conversation found" is a NOTE, never a FAIL (departure 13).
p20_launch() {
  local proj="$1" cmd="$2" secs="${3:-900}" noconv="${4:-}"
  P20_LRC=0
  t_ensure t1
  t_run t1 "$proj" "$cmd"
  t_front t1
  t_wait_launch t1 "$proj" "$secs"
  P20_LRC=$?
  case "$P20_LRC" in
    0) check_pass "Claude Code opened in T1 ($cmd in $proj)" ;;
    1)
      if [ "$noconv" = noconv ] && p20_no_conversation; then
        check_note "$cmd in $proj found no conversation to reopen (Claude Code's own No conversation found): no Claude session, the summary is still checked"
      else
        check_fail "Claude Code opened in T1 ($cmd in $proj)" "a live Claude Code in the box" "the command ended without opening Claude"
      fi ;;
    2) check_note "the wait for Claude Code in T1 was skipped ($cmd in $proj)" ;;
    *) check_fail "Claude Code opened in T1 ($cmd in $proj)" "a live Claude Code within $secs s" "no Claude Code after $secs s" ;;
  esac
  return 0
}
# p20_capture NAME launch|end: OUT is T1's capture narrowed to the launch or the session-end
# region. rc 1 when T1 cannot be read back (human mode, or typed mode that just dropped).
p20_capture() {
  t_have_capture || return 1
  t_capture t1 "$1" || return 1
  if [ "$2" = launch ]; then
    t_region launch
  else
    run_cmd -q -- p20_end_region "$OUT"
    if [ -f "$OUT" ] && LC_ALL=C grep -q '^__P20_NO_END_LINE__$' "$OUT"; then
      check_note "T1 printed neither Session ended nor Claude exited with code N: the checks read the whole capture"
    fi
  fi
  return 0
}
# p20_ask ARGS..., p20_ask_record ARGS...: ask and ask_record, asked again while the answer is r
# (rc 5 records nothing, so a repeat must never end the question). The rc of the last answer.
p20_ask() {
  local r
  while :; do ask "$@"; r=$?; [ "$r" = 5 ] || return "$r"; done
}
p20_ask_record() {
  local r
  while :; do ask_record "$@"; r=$?; [ "$r" = 5 ] || return "$r"; done
}
# p20_ask_lines TAG [--note TEXT] SPEC...: the one question t_checks_or_ask asks without a capture
# ("+text" T1 printed, "-text" it did not), asked even though T1 can be read back. TEXT is added
# to what the human is told to do.
p20_ask_lines() {
  local tag="$1" s yes="" no="" extra=""
  shift
  if [ "${1:-}" = --note ]; then extra="$2"; shift 2; fi
  for s in "$@"; do
    case "$s" in
      +*) yes="$yes${yes:+
}${s#+}" ;;
      -*) no="$no${no:+
}${s#-}" ;;
    esac
  done
  p20_ask "$tag" T1 "Read what T1 printed when the command started, before Claude Code opened.${extra:+
$extra}" "${yes:+T1 printed these lines:
$yes}${no:+
T1 printed none of these:
$no}" "Did T1 print exactly that?"
}
# p20_lost_summary: rc 0 when T1 is read through Terminal's history (typed mode) and the region
# in OUT holds no Egress: line at all. Claude Code can clear the screen and its scrollback when it
# draws, which takes the launch summary out of the history. The human saw it, so the human is asked.
p20_lost_summary() {
  [ "$(t_mode)" = typed ] || return 1
  [ -f "$OUT" ] && LC_ALL=C grep -q 'Egress:' "$OUT" && return 1
  check_note "T1's history holds no Egress: line after the command (Claude Code may have cleared the scrollback when it drew): asked instead"
  return 0
}
# p20_default_checks TAG: 1.1b's launch summary. Egress off, no pull, nothing else about egress.
p20_default_checks() {
  if p20_capture "$1" launch && ! p20_lost_summary; then
    expect_contains "printed: Egress:     off  ·  full network egress" "Egress:     off  ·  full network egress"   # bin/cleat:12309
    expect_not_contains "never printed: Pulling the egress gateway image" "Pulling the egress gateway image"   # bin/cleat:11528
    expect_not_contains "never printed: host.docker.internal is not reachable from a box with a policy." "host.docker.internal is not reachable from a box with a policy."   # bin/cleat:12463
    expect_count "exactly one line holds Egress (nothing else about egress)" 'Egress' eq 1
    expect_not_match "no line about the egress gateway, policy or control" 'egress (gateway|policy|control)'
  else
    p20_ask_lines "$1" \
      "+Egress:     off  ·  full network egress" \
      "-Pulling the egress gateway image" \
      "-host.docker.internal is not reachable from a box with a policy." \
      "-any other line about egress (a gateway, a policy, Packs pinned, Egress refused)"
  fi
}
# p20_smoke_open: Claude Code runs in eg-smoke, opened with cleat when it does not (a re-entry
# after a quit, departure 2). rc 0 when it runs (or T1 is simulated).
p20_smoke_open() {
  t_is_auto && return 0
  p20_live eg-smoke && return 0
  check_note "no Claude session is open in eg-smoke: a fresh one is opened with cleat. 1.4a's report then counts the denials from this session on, which 1.3d's curl adds to"
  say "T1 runs cleat in eg-smoke now: a fresh session in the existing box. If Claude opens on a login screen, sign in through the box."
  p20_launch eg-smoke cleat
  [ "$P20_LRC" = 0 ]
}

# ---------------------------------------------------------------------------------------------
# 1.1 Integration branch B, outside any box
# ---------------------------------------------------------------------------------------------

# Re-entry: the file's teardown removes its own objects, so it runs again as it is.
st_1_1() {
  local n bgw bvol agw avol t0 t1 secs okn intout spec short
  run_cmd -t 60 -- egcheck
  expect_contains "egcheck: the tracked tree is clean" "tree: clean"
  expect_not_contains "egcheck: no test lock in the worktree" "test lock held in the worktree"
  if [ "$MT_IMAGE" != cleat ]; then
    val n -- p20_int_names_cleat "$MT_WT/test/integration/egress.bats"
    if p20_is_int "$n" && [ "$n" -gt 0 ]; then
      step_skip "test/integration/egress.bats builds and runs the image cleat by name, not $MT_IMAGE: running it would replace the real cleat image"
    fi
  fi
  if [ "${DRY:-0}" != 1 ] && [ ! -x "$MT_WT/test/bats/bin/bats" ]; then
    step_abort "the bats submodule is missing in the candidate (test/bats/bin/bats): run git submodule update --init in it, then --only 1.1"
  fi
  val bgw -- p20_count_gw
  val bvol -- p20_count_vol
  record_value int.gw.before "$bgw" "gateways before the run"
  record_value int.vol.before "$bvol" "socket volumes before the run"
  cd "$MT_WT" || fatal "cannot cd to $MT_WT"
  t0=$(epoch_now)
  run_cmd -t 5400 -n "integration branch B" -- env PATH="${MT_BASH%/*}:$PATH" CLEAT_INT_EXPECT_ENGINE="$MT_EXPECT_ENGINE" ./test/integration/run.sh egress.bats
  t1=$(epoch_now)
  cd "$HOME" || true
  intout="$OUT"
  secs=$((t1 - t0))
  cp "$RAW" "$SCRATCH/mt-int-b.tap" 2>/dev/null || true
  check_note "the TAP output is kept as $SCRATCH/mt-int-b.tap"
  expect_rc "run.sh egress.bats exits 0" 0
  expect_contains "the header: enforcing=1, the engine kind, validated=1" "# egress.bats: enforcing=1 kind=$MT_EXPECT_ENGINE validated=1"   # test/integration/egress.bats:76
  expect_line "the plan is 14 cases" "1..14"
  n=1
  while [ "$n" -le 14 ]; do
    expect_match "ok $n" "^ok $n "
    n=$((n + 1))
  done
  expect_count "exactly 14 ok lines" '^ok ' eq 14
  expect_not_match "no not ok" '^not ok'
  expect_not_contains "no # skip" '# skip'
  okn=$(p20_count "$intout" '^ok ')
  record_value int.walltime "$secs" "wall time of the integration run (s)"
  val agw -- p20_count_gw
  val avol -- p20_count_vol
  expect_eq "the gateway count is back where it started" "$agw" "$bgw"
  expect_eq "the socket volume count is back where it started" "$avol" "$bvol"
  val spec -- p20_spec_label
  expect_eq "the $MT_IMAGE image still carries image-spec 6" "$spec" 6
  run_cmd -t 300 -- egimg
  expect_contains "egimg: the relay is this tree's (the file built from the same tree)" "relay: this tree's"
  expect_contains "egimg: the entrypoint is this tree's" "entrypoint: this tree's"
  short=$(kv_get cand.short "")
  if [ -z "$short" ]; then val short -- git -C "$MT_WT" rev-parse --short HEAD; fi
  rec_set intb "$okn of 14, $secs s, $short"
  kv_set int.date "$(date -u +%Y-%m-%d)"
  record_value int.result "$okn of 14, $secs s, $short" "the integration B line for the record (rec.intb)"
}
reg 1.1 1 auto gate st_1_1 "Integration branch B, outside any box"

# ---------------------------------------------------------------------------------------------
# 1.1b The default: egress never turned on
# ---------------------------------------------------------------------------------------------

# Re-entry: removing an absent image is a NOTE, the rest only reads.
st_1_1b_prep() {
  local st n
  check_note "0.6 recorded gwimg.present=$(kv_get gwimg.present unknown) (1 present, 0 absent)"
  val st -- p20_img_state "$GWIMG"
  if [ "$st" = absent ]; then
    check_note "the gateway image is already absent: nothing to remove"
  else
    img_rm "$GWIMG"
    expect_rc "docker image rm of the gateway image" 0
  fi
  val st -- p20_img_state "$GWIMG"
  expect_eq "the gateway image is absent, so 1.2 shows the first pull" "$st" absent
  run_cmd -t 120 -- egobjs
  expect_not_match "egobjs: no gateway, no socket volume, no host file" '^([^-]|-[^-])'
  val n -- p20_egress_sections
  expect_eq "no [egress] section in the isolated config" "$n" 0
  mkdir -p "$P/eg-default" || fatal "cannot make $P/eg-default"
  check_pass "the eg-default project exists" "$P/eg-default"
}
reg 1.1b-prep 1 auto gate st_1_1b_prep "The default: gateway image removed, no policy"

# Re-entry: a session still open in eg-default is ended first, then both launches run again.
# Refused once 1.2a has turned the policy on (p20_no_policy_yet).
st_1_1b_launch() {
  p20_cd eg-default
  p20_no_policy_yet 1.1b-launch
  if p20_live eg-default; then
    check_note "a Claude session is already open in eg-default (an earlier attempt): it is ended first"
    t_wait_exit t1 eg-default
  fi
  say "T1 runs cleat in eg-default now: the first Claude launch of the run."
  say "If Claude opens on a login screen, sign in through the box (the login note of scenario 1.2)."
  p20_launch eg-default cleat
  kv_del p20.rm.1-1b
  p20_default_checks launch-1
  if [ "$P20_LRC" = 0 ]; then
    p20_ask_record login-1.1b T1 "Look at Claude Code in T1. If it opened on a login screen, sign in through the box." "Did Claude open without a login screen? (y = no login needed, n = you signed in: say how it went)"
    p20_ask_record hello-1.1b T1 "In Claude Code in T1, send:
reply with just ok
(cleat resume below reopens this conversation. A session with no message leaves nothing to reopen.)" "Did Claude answer?"
  fi
  t_wait_exit t1 eg-default
  say "T1 runs cleat resume in eg-default now."
  p20_launch eg-default "cleat resume" 900 noconv
  p20_default_checks launch-2
  t_wait_exit t1 eg-default
  p20_ask_record speed T1 "Think back over the two launches in eg-default." "Did both launches feel as quick as your daily cleat?"
}
reg 1.1b-launch 1 mixed gate st_1_1b_launch "The default: two launches"

# Re-entry: read-only (a shell in the running box).
st_1_1b_shell() {
  local r
  p20_cd eg-default
  p20_no_policy_yet 1.1b-shell
  p20_need_running eg-default 1.1b-launch
  xshell eg-default -- "env | grep -cE '^(DISABLE_TELEMETRY|DISABLE_ERROR_REPORTING|ENABLE_CLAUDEAI_MCP_SERVERS|CLAUDE_CODE_DISABLE_ARTIFACT)='"
  r=$(xsh_rc 1)
  if [ -z "$r" ] && [ "${DRY:-0}" != 1 ]; then
    check_fail "the env line ran in the box shell" "its end marker" "no marker: the shell did not open or the command did not finish"
  fi
  xsh_out 1
  expect_line "an uncaged shell carries none of the four caged settings (W7)" 0   # bin/cleat:121 _EGRESS_PAIRED_ENV, caged execs only
  record_value shell.1.1b "$(p20_first "$OUT")" "the count the uncaged shell printed"
}
reg 1.1b-shell 1 expect gate st_1_1b_shell "The default: no caged setting in an uncaged shell"

# Re-entry: reads, then cleat rm. An attempt cut after its rm finds no box: kv p20.rm.1-1b says
# this step removed it, so the step ends as SKIP (its checks are in the cut attempt) rather than FAIL.
st_1_1b_check() {
  local c net lab st
  p20_cd eg-default
  val c -- cn eg-default
  if [ -z "$c" ]; then
    [ "$(kv_get p20.rm.1-1b "")" = 1 ] && step_skip "an earlier attempt of 1.1b-check already removed the eg-default box (its checks are in that attempt). To check again: --only 1.1b-launch,1.1b-shell,1.1b-check"
    step_abort "no eg-default box: run --only 1.1b-launch first"
  fi
  p20_need_running eg-default 1.1b-launch
  dk -- inspect -f '{{.HostConfig.NetworkMode}} [{{index .Config.Labels "sh.cleat.egress-hash"}}]' "$c"
  net=$(LC_ALL=C awk 'NF { print $1; exit }' "$OUT")
  lab=$(LC_ALL=C awk 'NF { $1 = ""; sub(/^ +/, ""); print; exit }' "$OUT")
  record_value net.1.1b "$net" "the NetworkMode of the uncaged box"
  expect_ne "a normal network, never none" "$net" none
  expect_eq "no egress-hash label" "$lab" "[]"
  run_cmd -t 120 -- egobjs
  expect_not_match "egobjs still lists nothing" '^([^-]|-[^-])'
  val st -- p20_img_state "$GWIMG"
  expect_eq "the gateway image is still absent: no launch pulled it" "$st" absent
  run_cmd -t 60 -- bx eg-default getent hosts host.docker.internal
  expect_rc "getent hosts host.docker.internal succeeds in the box" 0
  expect_match "host.docker.internal resolves to an address" '^[0-9A-Fa-f.:]+[[:space:]]+host\.docker\.internal'
  run_cmd -t 60 -- bx eg-default grep -c 'There is no egress allowlist: the box has' /home/coder/.claude/CLAUDE.md
  expect_line "the shipped CLAUDE.md sentence is there once" 1   # bin/cleat:3383
  run_cmd -t 60 -- bx eg-default grep -c '^# Network access' /home/coder/.claude/CLAUDE.md
  expect_line "no network fragment in a box with no policy" 0   # bin/cleat:3434
  run_cmd -t 60 -- bx eg-default test -d /run/cleat-egress
  expect_rc "no socket dir in the box" 1
  clt -- rm
  expect_contains "cleat rm: Removed cleat-eg-default-" "Removed cleat-eg-default-"   # bin/cleat:23064
  kv_set p20.rm.1-1b 1
  val c -- cn eg-default
  expect_eq "the eg-default box is gone, so 1.2's note cannot list it" "$c" ""
}
reg 1.1b-check 1 auto gate st_1_1b_check "The default: network, fragment, rm"

# ---------------------------------------------------------------------------------------------
# 1.2 The first caged launch
# ---------------------------------------------------------------------------------------------

# Re-entry: see departure 6 in the header.
st_1_2a() {
  local n pol gws allow_out tests cnt run dc
  p20_cd eg-smoke
  val n -- p20_egress_sections
  if p20_is_int "$n" && [ "$n" -gt 0 ]; then
    val pol -- p20_policy_is_12a "$CFG/config"
    p20_box eg-smoke
    val gws -- p20_count_gw
    if [ "$pol" = yes ] && [ -z "$P20_BOX" ] && [ "$gws" = 0 ] && [ ! -e "$CFG/egress-pins" ]; then
      run_cmd -t 30 -- p20_drop_egress "$CFG/config"
      expect_line "re-entry: the earlier attempt's [egress] section is dropped" 0
      check_note "re-entry: the [egress] section an earlier attempt of 1.2a wrote was dropped from the isolated config, so the first allow runs again"
    else
      step_skip "the first allow cannot be repeated: the isolated config holds more than 1.2a's policy, or a caged box, gateway or pin exists (box ${P20_BOX:-none}, gateways ${gws:-?}). The earlier attempt's result stands. To repeat it: 3.5 of this attempt, then a new run"
    fi
  fi
  cl -- egress status
  first_lines 3
  expect_contains "status before: ○ Egress control is off for this box" "○ Egress control is off for this box"   # bin/cleat:14448
  clt -- egress allow example.com
  allow_out="$OUT"
  expect_rc "cleat egress allow example.com exits 0" 0
  expect_contains "✔ Saved to ~/mt-egress-xdg/cleat/config" "✔ Saved to ~/mt-egress-xdg/cleat/config"   # bin/cleat:14258
  expect_contains "mode = strict (the policy was off)" "mode = strict (the policy was off)"   # bin/cleat:14216
  expect_match "the host line: example.com" '^ +example\.com$'   # bin/cleat:14260
  expect_contains "Now strict, 6 hosts allowed, port 443 only." "Now strict, 6 hosts allowed, port 443 only."   # bin/cleat:14265
  expect_contains "The core pack has not yet been validated against a real Claude Code session." "The core pack has not yet been validated against a real Claude Code session."   # bin/cleat:12533
  note_check
  tests=$(p20_note_rows "$allow_out" | awk '/^cleat-eg-/ { n++ } END { print n + 0 }')
  expect_num "the note lists no test box (every row is a daily box)" "$tests" eq 0
  cnt=$(p20_note_value note.count)
  run=$(p20_note_value note.running)
  kv_set note.1.2.count "$cnt"
  kv_set note.1.2.running "$run"
  dc=$(kv_get daily.listable.count "")
  if p20_is_int "$cnt" && p20_is_int "$dc" && [ "$cnt" = "$dc" ]; then
    check_pass "the note lists as many boxes as 0.4 expected it to (daily.listable.count)" "$cnt"
  else
    check_note "the note listed ${cnt:-?} boxes, ${run:-?} marked running. 0.4 expected ${dc:-?} (daily.listable.count). A daily box made or removed since 0.4 explains a difference: note_check above read Docker now"
  fi
  cl -- egress status
  first_lines 3
  expect_contains "status after: ○ No box yet. Its gateway is created with it on the next launch." "○ No box yet. Its gateway is created with it on the next launch."   # bin/cleat:14478
}
reg 1.2a 1 expect gate st_1_2a "The first allow and the refusing-boxes note"

# Re-entry: it runs only while the gateway image is absent and only with the network cut, so a
# second run either repeats the refusal or skips.
st_1_2_pull() {
  local st same c
  val st -- p20_img_state "$GWIMG"
  [ "$st" = present ] && step_skip "only visible before 1.2b's first pull: the gateway image is present"
  wifi_off
  host_effective || step_skip "the network was not cut (host action ${HOSTACT:-none}): never launch with it up, the box would be created"
  val st -- p20_net_state
  [ "$st" = online ] && step_skip "the Mac still reaches the internet with Wi-Fi off, so the pull cannot fail"
  p20_cd eg-pull
  run_cmd -t 120 -- egobjs
  cp "$OUT" "$SCRATCH/mt-egobjs-before.txt" || fatal "cannot write $SCRATCH/mt-egobjs-before.txt"
  clt -T 900 -- run
  expect_rc "cleat run exits 1" 1
  expect_contains "the spinner ends: Egress gateway image pull failed" "Egress gateway image pull failed"   # bin/cleat:11531
  expect_contains "✖ Egress refused box main: the egress gateway image could not be pulled: <the image>" "✖ Egress refused box main: the egress gateway image could not be pulled: $GWIMG"   # bin/cleat:11781, 11532
  expect_contains "This is not a policy denial." "This is not a policy denial."   # bin/cleat:11783
  expect_contains "Fix:  check the network and that Docker can reach ghcr.io, then re-run cleat" "Fix:  check the network and that Docker can reach ghcr.io, then re-run cleat"   # bin/cleat:11785, 11533
  run_cmd -t 120 -- egobjs
  if cmp -s "$OUT" "$SCRATCH/mt-egobjs-before.txt"; then same=yes; else same=no; fi
  expect_eq "egobjs is unchanged: nothing created" "$same" yes
  val c -- cn eg-pull
  expect_eq "no eg-pull box exists" "$c" ""
  wifi_on
}
reg 1.2-pull 1 mixed extra st_1_2_pull "A failed first pull"

# Re-entry: Claude live in eg-smoke: the launch is not repeated. When that session is the one an
# earlier attempt of 1.2b launched (kv p20.launch.1-2b names its path, whether it pulled and its T1
# command number, which must still be T1's latest) and T1 can be read back, its summary is checked
# from T1's capture: an attempt cut while it waited for Claude (Ctrl-C, a crash) never checked the
# first caged launch, whose pull lines and notices print only once. Otherwise the summary is SKIP.
# The box there but no Claude: cleat resume (departure 2).
st_1_2b() {
  local pre how cmd pulled=0 lrc=0 arch darch iarch status_done=0 reread=0 lh lp lr
  p20_cd eg-smoke
  val pre -- p20_img_state "$GWIMG"
  record_value gwimg.before.1.2b "$pre" "the gateway image before the launch"
  p20_box eg-smoke
  if p20_live eg-smoke; then how=live
  elif [ -n "$P20_BOX" ]; then how=resume
  else how=fresh
  fi
  check_note "launch path: $how"
  if [ "$how" = live ]; then
    check_note "Claude is already live in eg-smoke (an earlier attempt): the launch is not repeated"
    lh=""; lp=""; lr=""
    read -r lh lp lr <<EOF
$(kv_get p20.launch.1-2b "")
EOF
    case "$lh $lp" in "fresh 0"|"fresh 1"|"resume 0") ;; *) lr="" ;; esac
    if [ -n "$lr" ] && [ "$lr" = "$(kv_get t1.runs "")" ] && [ "$(kv_get t1.proj "")" = eg-smoke ] && t_have_capture; then
      how="$lh"; pulled="$lp"; reread=1
      check_note "the live session is the one an earlier attempt of 1.2b launched (T1 command $lr, path $how): its launch summary is checked from T1's capture"
    else
      check_skip "the launch summary" "the launch ran in an earlier attempt"
    fi
  fi
  if [ "$how" != live ]; then
    if [ "$reread" = 0 ]; then
      cmd=cleat
      [ "$how" = fresh ] && [ "$pre" != present ] && pulled=1
      if [ "$how" = fresh ]; then
        say "T1 runs cleat in eg-smoke now: the first caged launch."
        [ "$pulled" = 1 ] && say "It pulls the gateway image first (a spinner, then a ready line)."
      else
        say "T1 runs cleat in eg-smoke now: the box exists from an earlier attempt and Claude does not run in it, so cleat opens a fresh session there."
      fi
      say "If Claude opens on a login screen, sign in through the box: a login through the cage."
      # t_run numbers T1's commands: this launch is the next one.
      lr=$(kv_get t1.runs 0); p20_is_int "$lr" || lr=0
      kv_set p20.launch.1-2b "$how $pulled $((lr + 1))"
      p20_launch eg-smoke "$cmd"
      lrc=$P20_LRC
      kv_del p20.stop.1-4b
    fi
    if p20_capture launch launch && ! p20_lost_summary; then
      [ "$pulled" = 1 ] && p20_esc_check "T1's launch"
      if [ "$pulled" = 1 ]; then
        if [ "$(t_mode)" = typed ]; then
          check_skip "printed: Pulling the egress gateway image (ghcr.io/cleatdev/cleat-gw, <arch>)" "the spinner line is redrawn with a carriage return and erased by spin_stop on a terminal (bin/cleat:545, 582), so T1's history cannot hold it. The ready line and the image's architecture stand for it"
        else
          expect_match "printed: Pulling the egress gateway image (ghcr.io/cleatdev/cleat-gw, <arch>)" 'Pulling the egress gateway image \(ghcr\.io/cleatdev/cleat-gw, (arm64|amd64)\)'   # bin/cleat:11528
          arch=$(p20_pull_arch "$OUT")
          record_value gwpull.arch "${arch:-none}" "the architecture the pull line names"
        fi
        expect_contains "printed: ✔ Egress gateway image ready (ghcr.io/cleatdev/cleat-gw)" "✔ Egress gateway image ready (ghcr.io/cleatdev/cleat-gw)"   # bin/cleat:11536
      else
        check_skip "the two pull lines" "no pull at this launch (path $how, gateway image $pre before it)"
      fi
      expect_contains "printed: Egress:     strict  ·  6 hosts, 1 pack" "Egress:     strict  ·  6 hosts, 1 pack"   # bin/cleat:12332, the core pack's five hosts plus example.com
      if [ "$how" = fresh ]; then
        expect_contains "printed: Packs pinned at catalogue rev 1. Later additions wait for review." "Packs pinned at catalogue rev 1. Later additions wait for review."   # bin/cleat:12503
        expect_contains "printed: host.docker.internal is not reachable from a box with a policy." "host.docker.internal is not reachable from a box with a policy."   # bin/cleat:12463
        expect_contains "printed: An MCP server running on your host stops working here" "An MCP server running on your host stops working here"   # bin/cleat:12464
      else
        check_skip "Packs pinned and the host.docker.internal notice" "printed once per box, at its first launch (bin/cleat:12462, 12502): this launch reopens a box an earlier attempt made"
      fi
      expect_not_contains "never printed: Egress refused" "Egress refused"   # bin/cleat:11781
      expect_not_contains "never printed: Shim not listening (W5)" "Shim not listening"   # bin/cleat:11464
      if [ -f "$OUT" ] && LC_ALL=C grep -q 'Shim not listening' "$OUT"; then
        clt -- egress status
        status_done=1
        check_note "W5: T1 printed Shim not listening at the launch. cleat egress status right after it is $CMDREF of this attempt: keep both"
      fi
    else
      clt -- egress status
      status_done=1
      check_note "cleat egress status right after the launch is $CMDREF of this attempt (W5 evidence: the launch output in T1 cannot be read back)"
      if [ "$pulled" = 1 ] && [ "$how" = fresh ]; then
        p20_ask_lines launch --note "The Pulling line shows only while its spinner turns: the ready line then takes its place. On the two gateway image lines, \\033[2m shown as text before the bracket and \\033[0m after it still count as the line here: the next question asks about them (F1)." \
          "+Pulling the egress gateway image (ghcr.io/cleatdev/cleat-gw, arm64) with a spinner (amd64 on an Intel Mac)" \
          "+✔ Egress gateway image ready (ghcr.io/cleatdev/cleat-gw)" \
          "+Egress:     strict  ·  6 hosts, 1 pack" \
          "+Packs pinned at catalogue rev 1. Later additions wait for review." \
          "+host.docker.internal is not reachable from a box with a policy." \
          "+An MCP server running on your host stops working here" \
          "-Egress refused" \
          "-! Shim not listening (before Claude opened)"
        p20_ask pull-escape T1 "Look again at the two gateway image lines T1 printed before the summary." "Pulling the egress gateway image (ghcr.io/cleatdev/cleat-gw, arm64) and ✔ Egress gateway image ready (ghcr.io/cleatdev/cleat-gw), plain text" "Did both read cleanly, with no \\033[2m or \\033[0m shown as text around the bracket? n is a FAIL: the old behaviour F1 fixed at bin/cleat:11528 and 11536 (F1)"
      elif [ "$how" = fresh ]; then
        p20_ask_lines launch \
          "+Egress:     strict  ·  6 hosts, 1 pack" \
          "+Packs pinned at catalogue rev 1. Later additions wait for review." \
          "+host.docker.internal is not reachable from a box with a policy." \
          "+An MCP server running on your host stops working here" \
          "-Egress refused" \
          "-! Shim not listening (before Claude opened)"
      else
        p20_ask_lines launch \
          "+Egress:     strict  ·  6 hosts, 1 pack" \
          "-Egress refused" \
          "-! Shim not listening (before Claude opened)"
      fi
    fi
    if [ "$pulled" = 1 ]; then
      val darch -- docker version --format '{{.Server.Arch}}'
      val iarch -- docker image inspect "$GWIMG" --format '{{.Architecture}}'
      record_value gwimg.arch "$iarch" "the gateway image's architecture after the pull"
      record_value docker.arch "$darch" "the daemon's architecture"
      expect_eq "the pulled gateway image matches the daemon's architecture" "$iarch" "$darch"
    fi
  fi
  [ "$status_done" = 1 ] || check_note "no Shim not listening line at the launch, so no extra status read (W5)"
  if [ "$how" != live ] && [ "$lrc" != 0 ]; then
    check_skip "the Claude items" "Claude Code did not open in T1"
    return 0
  fi
  if [ "$how" != live ]; then
    p20_ask_record login-1.2 T1 "Look at Claude Code in T1. If it opened on a login screen, sign in through the box (the isolated config holds no named account, so the box uses the shared default login)." "Did Claude open without a login screen? (y = no login needed, n = you signed in through the box: say how it went)"
  fi
  p20_ask hello T1 "In Claude Code in T1, send:
reply with just ok" "Claude answers ok" "Did Claude answer?"
  say "Leave T1 in this session: 1.3 and 1.4 use it."
}
reg 1.2b 1 mixed gate st_1_2b "The first caged launch"

# ---------------------------------------------------------------------------------------------
# 1.3 Enforcement in both directions
# ---------------------------------------------------------------------------------------------

# Re-entry: read-only, one more denial of example.org in the gateway's log.
st_1_3a() {
  local c g bh hex
  p20_cd eg-smoke
  p20_need_running eg-smoke 1.2b
  val c -- cn eg-smoke
  val g -- gw eg-smoke
  [ -n "$c" ] || step_abort "no eg-smoke box: run --only 1.2b first"
  [ -n "$g" ] || step_abort "eg-smoke has no socket volume, so it has no gateway: the box is not caged"
  bh="${g#cleat-gw-}"
  record_value eg-smoke.cn "$c" "the box"
  record_value eg-smoke.gw "$g" "its gateway"
  record_value eg-smoke.bh "$bh" "its box hash"
  case "$bh" in ????????????) hex=yes ;; *) hex=no ;; esac
  case "$bh" in *[!0-9a-f]*) hex=no ;; esac
  expect_eq "the gateway is cleat-gw-<12 hex>" "$hex" yes   # bin/cleat _egress_gateway_name, _egress_box_hash
  dk -- inspect -f '{{.HostConfig.NetworkMode}} {{index .Config.Labels "sh.cleat.egress-engine"}}' "$c"
  expect_line "NetworkMode none, engine label $MT_EXPECT_ENGINE" "none $MT_EXPECT_ENGINE"   # bin/cleat:22518
  clt -- egress status
  expect_match "● Gateway healthy  cleat-gw-<12 hex>  up <time>  0 restarts" '● Gateway healthy +cleat-gw-[0-9a-f]{12} +up .+ +0 restarts'   # bin/cleat:14647
  expect_contains "the image line: the first 60 characters of the gateway image" "image ${GWIMG:0:60}"   # bin/cleat:14649
  expect_match "● Shim listening  127.0.0.1:3128 inside the box  last seen <n>s ago" '● Shim listening +127\.0\.0\.1:3128 inside the box +last seen [0-9]+(s|m[0-9][0-9]s) ago'   # bin/cleat:14698
  expect_contains "(health only, not proof)" "(health only, not proof)"   # bin/cleat:14699
  expect_contains "Mode:      strict  ·  live, read from the gateway" "Mode:      strict  ·  live, read from the gateway"   # bin/cleat:14500
  expect_match "Box:  cleat-eg-smoke-<8 hex>  network=none  cap-drop=NET_RAW  verified" 'Box:       cleat-eg-smoke-[0-9a-f]{8}   network=none  cap-drop=NET_RAW  verified'   # bin/cleat:14559
  expect_not_contains "the Mode row never says saved. The gateway enforces a different policy" "saved. The gateway enforces a different policy"   # bin/cleat:14502
  run_cmd -t 120 -- bget eg-smoke https://example.com/
  expect_line "example.com through the proxy: 200" 200
  run_cmd -t 120 -- bconnect eg-smoke example.org:443
  expect_line "HTTP/1.1 403 cleat egress: example.org is not on the allowlist" "HTTP/1.1 403 cleat egress: example.org is not on the allowlist"   # docker/gateway/gateway.py:197, 230
  expect_line "Content-Type: text/plain; charset=utf-8" "Content-Type: text/plain; charset=utf-8"   # docker/gateway/gateway.py:231
  expect_match "Content-Length: <n>" '^Content-Length: [0-9]+$'   # docker/gateway/gateway.py:232
  expect_line "Connection: close" "Connection: close"   # docker/gateway/gateway.py:233
  expect_line "X-Cleat-Reason: policy" "X-Cleat-Reason: policy"   # docker/gateway/gateway.py:236, 223
  expect_line "the body: cleat egress: example.org is not on the allowlist." "cleat egress: example.org is not on the allowlist."   # docker/gateway/gateway.py:219
  expect_line "the body: This is a Cleat policy decision, not a network outage and not an" "This is a Cleat policy decision, not a network outage and not an"   # docker/gateway/gateway.py:186
  expect_line "the body: authentication failure." "authentication failure."   # docker/gateway/gateway.py:187
  expect_line "the body: Ask the user to run: cleat egress allow example.org" "Ask the user to run: cleat egress allow example.org"   # docker/gateway/gateway.py:202
  expect_order "the status line, then Content-Type" "HTTP/1.1 403 cleat egress" "Content-Type: text/plain"
  expect_order "Content-Type, then Content-Length" "Content-Type: text/plain" "Content-Length:"
  expect_order "Content-Length, then Connection" "Content-Length:" "Connection: close"
  expect_order "Connection, then X-Cleat-Reason" "Connection: close" "X-Cleat-Reason: policy"
  expect_order "X-Cleat-Reason, then the body" "X-Cleat-Reason: policy" "cleat egress: example.org is not on the allowlist."
  expect_order "the body's first sentence, then the second" "cleat egress: example.org is not on the allowlist." "This is a Cleat policy decision"
  expect_order "the second sentence, then the remedy" "authentication failure." "Ask the user to run: cleat egress allow example.org"
  run_cmd -t 60 -- bx eg-smoke grep -c '^# Network access' /home/coder/.claude/CLAUDE.md
  expect_line "the network fragment is in the box's CLAUDE.md: the agent is told" 1   # bin/cleat:3434
}
reg 1.3a 1 expect gate st_1_3a "Enforcement: status, 200, the 403 and its body"

# Re-entry: read-only (one shell in the running box).
st_1_3b() {
  local i r own="" named="" o="" u="" f=""
  p20_cd eg-smoke
  p20_need_running eg-smoke 1.2b
  xshell eg-smoke -- \
    "env | grep -E '^(DISABLE_TELEMETRY|DISABLE_ERROR_REPORTING|ENABLE_CLAUDEAI_MCP_SERVERS|CLAUDE_CODE_DISABLE_ARTIFACT)='" \
    "curl -sS -o /dev/null -w '%{http_code}\n' https://example.com/" \
    "curl -sS https://example.org/" \
    "curl -sS --noproxy '*' https://example.com/" \
    "sudo -n -i id -u" \
    "sudo -n -i curl -sS https://example.com/"
  i=1
  while [ "$i" -le 6 ]; do
    r=$(xsh_rc "$i")
    if [ -z "$r" ] && [ "${DRY:-0}" != 1 ]; then
      check_fail "command $i ran in the box shell" "its end marker" "no marker: the shell did not open or the command did not finish"
    fi
    i=$((i + 1))
  done
  xsh_out 1
  expect_line "the caged shell carries DISABLE_TELEMETRY=1 (W7)" "DISABLE_TELEMETRY=1"   # bin/cleat:121
  expect_line "the caged shell carries DISABLE_ERROR_REPORTING=1 (W7)" "DISABLE_ERROR_REPORTING=1"   # bin/cleat:121
  expect_line "the caged shell carries ENABLE_CLAUDEAI_MCP_SERVERS=false (W7)" "ENABLE_CLAUDEAI_MCP_SERVERS=false"   # bin/cleat:122
  expect_line "the caged shell carries CLAUDE_CODE_DISABLE_ARTIFACT=1 (W7)" "CLAUDE_CODE_DISABLE_ARTIFACT=1"   # bin/cleat:122
  expect_count "exactly the four settings" '^(DISABLE_TELEMETRY|DISABLE_ERROR_REPORTING|ENABLE_CLAUDEAI_MCP_SERVERS|CLAUDE_CODE_DISABLE_ARTIFACT)=' eq 4
  xsh_out 2
  expect_line "example.com through the proxy variables: 200" 200
  expect_eq "that curl exits 0" "$(xsh_rc 2)" 0
  xsh_out 3
  expect_contains "example.org: curl: (56) CONNECT tunnel failed, response 403" "curl: (56) CONNECT tunnel failed, response 403"   # curl's own words for the gateway's 403
  expect_not_match "example.org never answers 200" '^200$'
  expect_eq "that curl exits 56" "$(xsh_rc 3)" 56
  xsh_out 4
  expect_contains "without the proxy: curl: (6) Could not resolve host" "curl: (6) Could not resolve host"   # curl's own words, the box has no resolver
  expect_eq "that curl exits 6" "$(xsh_rc 4)" 6
  xsh_out 5
  expect_line "sudo -i runs as root without a password prompt" 0
  expect_not_contains "sudo -i id -u prints no sudo: unable to resolve host (F3)" "unable to resolve host"   # the line ac6ee85's entrypoint removed (docker/entrypoint.sh:50 to 53)
  xsh_out 6
  expect_not_contains "sudo -i curl prints no sudo: unable to resolve host (F3)" "unable to resolve host"
  # curl's own line first: a sudo warning above it is never what root's curl said (F3 above checks
  # that sudo prints none).
  record_value root.curl.1.3b "$(LC_ALL=C grep -m 1 '^curl:' "$OUT" 2>/dev/null || p20_first "$OUT")" "what curl printed as root"
  expect_not_match "root gets no 200: no proxy and no route" '^200$'
  expect_ne "curl as root exits non-zero" "$(xsh_rc 6)" 0
  if [ -z "$(xsh_rc 6)" ] && [ "${DRY:-0}" != 1 ]; then check_fail "curl as root ended" "an exit code" "none"; fi
  hdr "The box names itself in /etc/hosts (F3)"
  val named -t 60 -- p20_hosts_named eg-smoke
  expect_eq "the box's hostname is in its /etc/hosts (F3)" "$named" named   # docker/entrypoint.sh:50 to 53
  hdr "npm's directory belongs to the box user (F2)"
  val own -t 120 -- p20_npm_own eg-smoke
  record_value step13b.npm "$own" "/home/coder/.npm: its owner, the box user's uid, entries the box user does not own"
  case "$own" in
    "<dry:"*) expect_eq "/home/coder/.npm belongs to the box user (F2)" "$own" "owner=<uid> user=<uid> foreign=0" ;;
    owner=none\ user=*) check_note "no /home/coder/.npm in the box: npm makes it as the box user at its first run (F2 has nothing to read)" ;;
    owner=*\ user=*\ foreign=*)
      o=$(printf '%s' "$own" | sed -n 's/^owner=\([^ ]*\) .*/\1/p')
      u=$(printf '%s' "$own" | sed -n 's/.* user=\([^ ]*\) .*/\1/p')
      f=$(printf '%s' "$own" | sed -n 's/.* foreign=\([^ ]*\)$/\1/p')
      if p20_is_int "$o" && p20_is_int "$u" && p20_is_int "$f"; then
        expect_eq "/home/coder/.npm belongs to the box user (F2)" "$o" "$u"   # docker/entrypoint.sh:94
        expect_eq "nothing under /home/coder/.npm belongs to another uid (F2)" "$f" 0
      else
        check_fail "the box's npm directory was read (F2)" "owner=<uid> user=<uid> foreign=<n>" "$own"
      fi ;;
    *) check_fail "the box's npm directory was read (F2)" "owner=<uid> user=<uid> foreign=<n>" "${own:-nothing}" ;;
  esac
}
reg 1.3b 1 expect gate st_1_3b "Enforcement through cleat shell"

# Re-entry: read-only.
st_1_3c() {
  p20_cd eg-smoke
  p20_need_running eg-smoke 1.2b
  clt -- egress why example.org
  expect_contains "why: x Denied   example.org:443" "x Denied   example.org:443"   # bin/cleat:13810
  expect_match "why: an Allow it line naming cleat egress allow example.org" 'Allow it:.*cleat egress allow example\.org'   # bin/cleat:13835
  if [ -f "$OUT" ] && LC_ALL=C grep -q 'is also a package name\.' "$OUT"; then
    check_note "why also printed the package block (? example.org is also a package name.): ruled behaviour R5-28, not a defect"   # bin/cleat:13851
  fi
  clt -- egress test example.org
  expect_rc "test example.org exits 1 (a deny exits 1 by design)" 1
  expect_contains "test: x deny    example.org:443   the gateway's matcher, box main" "x deny    example.org:443   the gateway's matcher, box main"   # bin/cleat:14021
  clt -- egress test example.com
  expect_rc "test example.com exits 0" 0
  expect_contains "test: v allow   example.com:443" "v allow   example.com:443"   # bin/cleat:14003
  clt -- egress log
  expect_match "log: Egress log for box main   gateway cleat-gw-<12 hex>   times in UTC" 'Egress log for box main   gateway cleat-gw-[0-9a-f]{12}   times in UTC'   # bin/cleat:13922
  clt -- status
  expect_contains "status: Egress:    strict  ·  6 hosts, 1 pack" "Egress:    strict  ·  6 hosts, 1 pack"   # bin/cleat:14602, four spaces after Egress:
}
reg 1.3c 1 expect gate st_1_3c "why, test, log, status agree"

# Re-entry: the question again (a new session is opened first when none runs).
st_1_3d() {
  local r
  p20_cd eg-smoke
  p20_need_running eg-smoke 1.2b
  if ! p20_smoke_open; then
    check_skip "what Claude does at a denial" "no Claude session could be opened in eg-smoke"
    return 0
  fi
  p20_ask_record claude-curl T1 "In Claude Code in T1, send:
Use the Bash tool to run curl -sS https://example.org/ and tell me what you would do next." "Did it read /run/cleat-egress/denials.log, stop and give you cleat egress allow example.org rather than retry, hunt for a mirror or turn off TLS checks? (model behaviour: record what it did, never a failure)"
  r=$?
  case "$r" in
    0) record_value claude.1.3d "as the box tells it" "what Claude did at the denial" ;;
    1) record_value claude.1.3d "differently (the note above)" "what Claude did at the denial" ;;
  esac
}
reg 1.3d 1 human gate st_1_3d "What Claude does at a denial"

# ---------------------------------------------------------------------------------------------
# 1.4 Session end and stop
# ---------------------------------------------------------------------------------------------

# Re-entry: no session open: the end of the last one is read from the same capture.
st_1_4a() {
  local region cnt hosts named r
  p20_cd eg-smoke
  if p20_live eg-smoke; then
    t_wait_exit t1 eg-smoke
  elif t_is_auto; then
    t_wait_exit t1 eg-smoke
  else
    check_note "no Claude session is open in eg-smoke: the end of the last one is read"
  fi
  if p20_capture end end; then
    region="$OUT"
    expect_match "printed: ! 1 destination was (or N destinations were) denied by egress policy this session" '! (1 destination was|[0-9]+ destinations were) denied by egress policy this session'   # bin/cleat:20682, 20684
    expect_contains "printed: cleat egress log     every denial with timestamps" "cleat egress log     every denial with timestamps"   # bin/cleat:20720
    expect_not_contains "never names http-intake.logs.us5.datadoghq.com (W7)" "http-intake.logs.us5.datadoghq.com"
    expect_not_contains "never names browser-intake-us5-datadoghq.com (W7)" "browser-intake-us5-datadoghq.com"
    expect_not_contains "never names mcp-proxy.anthropic.com (W7)" "mcp-proxy.anthropic.com"
    expect_not_contains "nothing about the relay: Shim not listening" "Shim not listening"   # bin/cleat:11464
    expect_not_contains "nothing about the relay: the in-box relay has not been heard from" "the in-box relay has not been heard from"   # bin/cleat:11464
    cnt=$(p20_report_count "$region")
    hosts=$(p20_report_hosts "$region" | tr '\n' ' ')
    hosts="${hosts% }"
    named=0
    case " $hosts " in *" example.org "*) named=1 ;; esac
    kv_set report.1.4.read capture
  else
    while :; do
      t_checks_or_ask report \
        "+! 1 destination was denied by egress policy this session (or N destinations were denied)" \
        "+cleat egress log     every denial with timestamps" \
        "-http-intake.logs.us5.datadoghq.com" \
        "-browser-intake-us5-datadoghq.com" \
        "-mcp-proxy.anthropic.com" \
        "-Shim not listening, or anything about the in-box relay"
      [ $? = 5 ] || break
    done
    p20_ask_record report-named T1 "Read the session-end report in T1 again." "Did the report name example.org on one of its rows?"
    r=$?
    case "$r" in 0) named=1 ;; 1) named=0 ;; *) named="" ;; esac
    read_line report-count "How many destinations did the report's first line count? (the number, 0 when no report printed)" cnt
    cnt=$(printf '%s' "$cnt" | tr -cd '0-9')
    hosts=""
    kv_set report.1.4.read human
  fi
  record_value report.1.4.count "$cnt" "destinations the report's header counts"
  record_value report.1.4.named "$named" "example.org named in the report (1 yes, 0 no)"
  record_value report.1.4.hosts "$hosts" "the hosts the report names"
}
reg 1.4a 1 mixed gate st_1_4a "The session-end report"

# Re-entry: the log and the reads again. An attempt cut after its stop finds the box stopped: kv
# p20.stop.1-4b says this step stopped it, so the stop check is SKIP and the reads still run. A box
# found stopped without that mark is checked as written (cleat stop then says Container not running).
st_1_4b() {
  local logout hosts h named cnt inlog ok eg
  p20_cd eg-smoke
  cl -- egress log
  grep_lines ' x denied '
  logout="$OUT"
  hosts=$(p20_log_hosts "$logout" | tr '\n' ' ')
  hosts="${hosts% }"
  record_value denied.1.4 "$hosts" "every host cleat egress log lists as denied"
  for h in http-intake.logs.us5.datadoghq.com browser-intake-us5-datadoghq.com mcp-proxy.anthropic.com; do
    expect_not_contains "the log never denies $h (W7)" "$h" "$logout"
  done
  for h in raw.githubusercontent.com storage.googleapis.com downloads.claude.ai registry.npmjs.org; do
    case " $hosts " in *" $h "*) check_note "denied and recorded only (spec 7.3 pairs no setting with it): $h" ;; esac
  done
  named=$(kv_get report.1.4.named "")
  cnt=$(kv_get report.1.4.count "")
  inlog=0
  case " $hosts " in *" example.org "*) inlog=1 ;; esac
  ok=no
  if [ "$named" = 1 ]; then ok=yes
  elif p20_is_int "$cnt" && [ "$cnt" -gt 3 ] && [ "$inlog" = 1 ]; then ok=yes
  fi
  if [ -z "$(kv_get report.1.4.read "")" ] && [ "${DRY:-0}" != 1 ]; then
    check_fail "1.4a read the session-end report" "its reading in kv report.1.4.*" "none: run --only 1.4a,1.4b (1.4a reads the end of the last session when none is open)"
  fi
  expect_eq "example.org is named in the report, or the report counts more than three and the log lists it (report named ${named:-unknown}, count ${cnt:-unknown}, in the log $inlog)" "$ok" yes
  run_cmd -q -t 60 -- box_running eg-smoke
  if [ "$RC" != 0 ] && [ "$(kv_get p20.stop.1-4b "")" = 1 ]; then
    check_skip "stop: ✔ Session ended. Resume with: cleat resume" "an earlier attempt of 1.4b already stopped the box (its stop line is in that attempt). The reads below still run"
  else
    clt -- stop
    expect_contains "stop: ✔ Session ended. Resume with: cleat resume" "✔ Session ended. Resume with: cleat resume"   # bin/cleat:23039
    kv_set p20.stop.1-4b 1
  fi
  cl -- egress status
  first_lines 4
  expect_match "status: ○ Gateway stopped       its box is stopped too" '○ Gateway stopped +its box is stopped too'   # bin/cleat:14675
  expect_contains "status: Fix:  cleat start" "Fix:  cleat start"   # bin/cleat:14677
  run_cmd -t 120 -- egobjs
  eg="$OUT"
  run_cmd -q -- p20_section "$eg" gateways
  expect_count "egobjs: one gateway" '.' eq 1
  expect_match "egobjs: the gateway exited with its box" '^cleat-gw-[0-9a-f]{12}  Exited'
  run_cmd -q -- p20_section "$eg" "socket volumes"
  expect_count "egobjs: one socket volume" '.' eq 1
  expect_match "egobjs: the socket volume is cleat-gw-<12 hex>-sock" '^cleat-gw-[0-9a-f]{12}-sock$'
  run_cmd -q -- p20_ls_names "$CFG/egress-rendered"
  expect_count "egress-rendered: one rendered policy" '.' eq 1
  run_cmd -q -- p20_ls_names "$CFG/egress-pins"
  expect_line "egress-pins holds global" global
  run_cmd -q -- p20_ls_names "$CFG/egress-notices"
  expect_match "egress-notices holds cleat-eg-smoke-<8 hex>" '^cleat-eg-smoke-[0-9a-f]{8}$'
}
reg 1.4b 1 expect gate st_1_4b "The log, stop, status, objects left"
