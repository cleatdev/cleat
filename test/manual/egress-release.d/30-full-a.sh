# egress-release.d/30-full-a.sh: sitting 2: 2.0 to 2.14 (2.14-acct lives in 32-full-c.sh).
#
# A part of egress-release.sh. Sourced, never run. It holds only function definitions, reg calls
# and comments: nothing else runs at source time. One function per step, named st_ plus the id
# with . and - turned into _, registered in scenario order with
#   reg ID SITTING KIND CLASS FUNC "TITLE"
# The steps, their checks and their re-entry rules are DESIGN.md section 6.2. A helper this part
# needs that the library lacks is written here, prefixed with the part's number (p30_).
#
# Every expected string below was read in the candidate first (bin/cleat, docker/ or
# docker/gateway/ at ac6ee85) and carries its source line. Where the code and the scenario or
# the design differ, the code wins and the comment says so:
#   - 2.11b: `Setup failed with exit code 100` is followed on the same line by
#     "(the box is up, provisioning did not finish)" (bin/cleat:19239). The check is
#     `exit code 100( |$)` and never `exit code 1( |$)`, not the design's `100$`.
#   - 2.7b: the relay row is detected in any `last seen <age> ago, no heartbeat since` form, then
#     the first such row must read the scenario's `1m<n>s` form within 150 s of the chown.
#   - 2.10c: a line counts as Docker's restart only when its RestartCount rose above the count
#     read before the kill. The first read after a kill can still show the old healthy gateway.
#     The watch lasts 45 s, not the design's 20: the gateway image's HEALTHCHECK runs every 15 s
#     (docker/gateway/Dockerfile:19), so healthy comes about 15 s after Docker's restart.
#   - 2.11-repo2 and 2.11b deny apt-debian only while the global policy lists it: a deny of a pack
#     the file never listed denies the pack's hosts instead (bin/cleat:14228), which would leave
#     deb.debian.org on the deny list for every later step.
#   - 2.11-repo2 installs docker-buildx-plugin, not the scenario's docker-ce-cli. The image already
#     ships docker-ce-cli (docker/Dockerfile:46), so with download.docker.com denied apt-get update
#     only warns and the install finds it current: Setup applied, rc 0 (measured in the validation
#     walk). docker-buildx-plugin comes from the same repository and is not in the image, so the
#     denied index makes the install fail with 100, the case the scenario wants.
#   - 2.11a, 2.11b and 2.11-repo2 also check F3 (ac6ee85): the [setup] lines run with sudo print
#     no "sudo: unable to resolve host", because a caged box names itself in /etc/hosts
#     (docker/entrypoint.sh:50 to 53). The checks carry (F3) for the sign-off's fixes table.
#   - 2.13a waits for each editor frame by its last sequence, ESC [ J (bin/cleat:16020). Every
#     <esc> is followed by more than a second of quiet: _read_esc_rest reads with -t 1 (bin/cleat:636).
#
# Helpers (p30_): p30_is_int, p30_cd, p30_ck_read, p30_ck_load, p30_uid, p30_gid, p30_403,
# p30_launch, p30_exit, p30_need_live, p30_need_up, p30_utf8, p30_ans_word, p30_rowno, p30_nrows, p30_rowtext, p30_cursor_row,
# p30_fails, p30_item_begin, p30_item_end, p30_maxwidth, the editor program pieces p30_ed_*,
# the picker pieces p30_pk_*, the snapshot loops p30_w12_*, the T1 window size p30_t1_size. Then
# pipelines run through run_cmd or val (p30_names_count, p30_gw_proc, p30_host_ids,
# p30_top_socat, p30_relay_count, p30_relay_last, p30_find_count, p30_net_dev, p30_ifaddrs,
# p30_lastmatch, p30_gw_watch, p30_ls_paths, p30_stty_part, p30_rawseq, p30_state_sum,
# p30_sessions_ids, p30_brew_bash, p30_policy_has_apt).

# ---------------------------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------------------------

p30_is_int() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac; return 0; }

# p30_cd PROJ [make]: into $P/PROJ. make: mkdir -p first. A dry run makes it inside its own home.
p30_cd() {
  local d="$P/$1"
  if [ "${2:-}" = make ] || [ "${DRY:-0}" = 1 ]; then mkdir -p "$d" || fatal "cannot create $d"; fi
  [ -d "$d" ] || step_abort "no project $d: run the step that makes it first"
  cd "$d" || step_abort "cannot cd to $d"
}

# p30_ck_read: eg-check's box, socket volume, gateway and gateway hash as Docker has them now.
p30_ck_read() {
  CK_CN=""; CK_VOL=""; CK_GW=""; CK_BH=""
  val CK_CN -t 60 -- cn eg-check
  val CK_VOL -t 60 -- vol eg-check
  val CK_GW -t 60 -- gw eg-check
  CK_BH="${CK_GW#cleat-gw-}"
}
# p30_ck_load: the names, from Docker, compared with what 2.4c kept (kv eg-check.*).
p30_ck_load() {
  local kcn kgw
  kcn=$(kv_get eg-check.cn "")
  kgw=$(kv_get eg-check.gw "")
  p30_ck_read
  if [ -z "$CK_CN" ]; then
    step_abort "no eg-check box: run 2.4b and 2.4c first"
  fi
  if [ -n "$kcn" ] && { [ "$kcn" != "$CK_CN" ] || [ "$kgw" != "$CK_GW" ]; }; then
    check_note "eg-check's box or gateway changed since 2.4c recorded them: now $CK_CN with $CK_GW"
  fi
  if [ -z "$kcn" ] || [ "$kcn" != "$CK_CN" ] || [ "$kgw" != "$CK_GW" ]; then
    kv_set eg-check.cn "$CK_CN"; kv_set eg-check.vol "$CK_VOL"; kv_set eg-check.gw "$CK_GW"; kv_set eg-check.bh "$CK_BH"
  fi
}
p30_uid() { kv_get box.uid "$(id -u)"; }
p30_gid() { kv_get box.gid "$(id -g)"; }

# p30_403 [FILE]: the denial of example.org, head and body, exactly as 1.3a quotes it.
p30_403() {
  local f="${1:-$OUT}"
  expect_contains "the 403 status line" "HTTP/1.1 403 cleat egress: example.org is not on the allowlist" "$f"   # gateway.py:197,230
  expect_contains "X-Cleat-Reason: policy" "X-Cleat-Reason: policy" "$f"                                      # gateway.py:236
  expect_contains "the body's first sentence" "cleat egress: example.org is not on the allowlist." "$f"       # gateway.py:215
  expect_contains "the body says it is not an outage" "This is a Cleat policy decision, not a network outage and not an" "$f"   # gateway.py:186
  expect_contains "the body says it is not an authentication failure" "authentication failure." "$f"          # gateway.py:187
  expect_contains "the body names the fix" "Ask the user to run: cleat egress allow example.org" "$f"        # gateway.py:202
}

# p30_launch PROJ CMD TAG [SPEC...]: [T1 launch CMD in PROJ] (DESIGN 6.2 notation). rc: t_wait_launch's.
p30_launch() {
  local proj="$1" cmd="$2" tag="$3" r
  shift 3
  t_ensure t1
  t_run t1 "$proj" "$cmd"
  t_wait_launch t1 "$proj" 600
  r=$?
  case "$r" in
    0) check_pass "Claude Code opened in T1 ($cmd in $proj)" ;;
    1) check_fail "Claude Code opened in T1 ($cmd in $proj)" "a live Claude Code session" "the command ended without Claude Code" ;;
    2) check_skip "Claude Code opened in T1 ($cmd in $proj)" "skipped at the wait"; return 2 ;;
    *) check_fail "Claude Code opened in T1 within 600 s ($cmd in $proj)" "a live Claude Code session" "timed out" ;;
  esac
  if [ $# -gt 0 ]; then
    if t_capture t1 "$tag"; then t_region launch; fi
    t_checks_or_ask "$tag" "$@"
  fi
  return "$r"
}

# p30_exit PROJ TAG [SPEC...]: [T1 exit PROJ], then the session-end region against the specs.
p30_exit() {
  local proj="$1" tag="$2" live=1 r
  shift 2
  run_cmd -q -t 90 -- box_claude_live "$proj" || live=0
  t_wait_exit t1 "$proj" 600
  r=$?
  if [ "$live" = 0 ]; then
    check_note "T1: no Claude session was open in $proj"
    return 0
  fi
  [ $# -gt 0 ] || return "$r"
  if t_capture t1 "$tag"; then
    t_region end
    if [ "${DRY:-0}" != 1 ] && [ ! -s "$OUT" ]; then
      if t_is_auto; then
        check_skip "the session-end report in T1" "T1 simulated: the session ended with Ctrl-C, so no session-end report"
      else
        check_fail "T1 printed the session-end line" "Session ended. Resume with: cleat resume" "not in T1's text"   # bin/cleat:20274
      fi
      return "$r"
    fi
  fi
  t_checks_or_ask "$tag" "$@"
  return "$r"
}

# p30_need_live PROJ TAG: Claude Code live in PROJ, resumed in T1 when it is not.
p30_need_live() {
  if run_cmd -q -t 90 -- box_claude_live "$1"; then return 0; fi
  check_note "Claude Code is not open in $1: T1 resumes it first"
  p30_launch "$1" "cleat resume" "$2"
}
# p30_need_up PROJ TAG: the box runs, with or without Claude Code. A box found stopped (a break
# between sittings, a Docker Desktop restart) is resumed in T1 first, as the scenario has it there.
p30_need_up() {
  if run_cmd -q -t 60 -- box_running "$1"; then return 0; fi
  check_note "the $1 box is not running (a break since the step before): T1 resumes it first"
  p30_launch "$1" "cleat resume" "$2"
}
# p30_utf8: rc 0 when the locale cleat runs in is UTF-8 (LC_ALL, then LC_CTYPE, then LANG). bash 4 and
# later then read a pasted ü as one character, else as two bytes. bash 3.2 always reads bytes.
p30_utf8() {
  case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in *[Uu][Tt][Ff]-8*|*[Uu][Tt][Ff]8*) return 0 ;; esac
  return 1
}
# p30_ans_word RC: an ask's answer as a word for the record (0 yes, 1 no, else skipped).
p30_ans_word() { case "$1" in 0) printf pass ;; 1) printf defect ;; *) printf skipped ;; esac; }

# Snapshot rows (files of the screen model, one row per line). The cursor row is the last row with ▸:
# an inline picker draws below what an earlier screen left (the kit picker above its models screen).
p30_rowno() { LC_ALL=C grep -n -E -e "$2" "$1" 2>/dev/null | head -n 1 | cut -d: -f1; }
p30_nrows() { LC_ALL=C grep -E -e "$2" "$1" 2>/dev/null | awk 'END { print NR + 0 }'; }
p30_rowtext() { p30_is_int "$2" || return 0; sed -n "${2}p" "$1" 2>/dev/null; }
p30_cursor_row() { LC_ALL=C grep -n -e '▸' "$1" 2>/dev/null | tail -n 1 | cut -d: -f1; }
# p30_maxwidth FILE FROM TO: the widest of rows FROM to TO, in columns.
p30_maxwidth() {
  LC_ALL=C tr -d '\200-\277' < "$1" 2>/dev/null | awk -v a="$2" -v b="$3" 'NR >= a + 0 && NR <= b + 0 { if (length($0) > m) m = length($0) } END { print m + 0 }'
}

# Per-item verdicts for the record (c46.editor): failures counted in this attempt's checks.tsv.
p30_fails() { awk -F'\t' '$2 == "FAIL" || $2 == "TIMEOUT" || $2 == "HUMAN-FAIL" { n++ } END { print n + 0 }' "$STEP_DIR/checks.tsv" 2>/dev/null; }
p30_item_begin() { P30_IFAIL=$(p30_fails); [ -n "$P30_IFAIL" ] || P30_IFAIL=0; hdr "$1"; }
p30_item_end() {
  local n
  n=$(p30_fails); p30_is_int "$n" || n=0
  if [ "$n" -gt "${P30_IFAIL:-0}" ]; then P30_ITEMS="${P30_ITEMS:-}${P30_ITEMS:+ }$1:defect"; else P30_ITEMS="${P30_ITEMS:-}${P30_ITEMS:+ }$1:pass"; fi
}

# ---- pipelines, run only through run_cmd or val ----
p30_names_count() { docker ps -a --format '{{.Names}}' | LC_ALL=C grep -E -e "$1" | awk 'END { print NR + 0 }'; }
p30_gw_proc() { docker exec "$1" python3 -c "print(open('/proc/1/status').read())" | grep -E '^(Uid|CapPrm|CapEff|NoNewPrivs)'; }
p30_host_ids() { docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$1" | grep -E '^HOST_(UID|GID)='; }
p30_top_socat() { docker top "$1" -o pid,uid,comm | grep -E 'UID|socat'; }
p30_relay_count() { bx "$1" grep -c 'relay started' /tmp/cleat-egress-shim.log; }
p30_relay_last() { bx "$1" grep 'relay started' /tmp/cleat-egress-shim.log | tail -n 1; }
p30_find_count() { bx "$1" sh -c 'find /home/coder/.claude 2>/dev/null | wc -l'; }
p30_net_dev() { bx "$1" cat /proc/net/dev | awk 'NR > 2 { print $1 }'; }
# p30_net_flags PROJ: "<interface> <flags>" for every interface of the box (sysfs, as its user).
p30_net_flags() { bx "$1" sh -c 'for f in /sys/class/net/*/flags; do n=${f%/flags}; printf "%s %s\n" "${n##*/}" "$(cat "$f")"; done'; }
# p30_capbnd PROJ: box root's capability bounding set, the hex digits alone.
p30_capbnd() { bxr "$1" sed -n 's/^CapBnd:[[:space:]]*//p' /proc/self/status; }
p30_ifaddrs() { command -v ifconfig > /dev/null 2>&1 || return 3; ifconfig | awk '/inet / { print $2 }'; }
p30_lastmatch() { LC_ALL=C grep -E -e "$1" "$2" | tail -n 1; }
p30_ls_paths() { ls "$@" 2>&1; return 0; }
# p30_gw_watch GW SECS BEFORE: the gateway's state once a second, until a restart Docker made
# (RestartCount above BEFORE) reads healthy. rc 0 then, 1 when SECS passed.
p30_gw_watch() {
  local i=0 l n
  while [ "$i" -lt "$2" ]; do
    l=$(docker inspect -f '{{.State.Status}} health={{.State.Health.Status}} restarts={{.RestartCount}}' "$1" 2>&1)
    printf '%s %s\n' "$(date -u +%T)" "$l"
    case "$l" in
      *health=healthy*)
        n="${l##*restarts=}"
        if p30_is_int "$n" && [ "$n" -gt "$3" ]; then return 0; fi ;;
    esac
    sleep 1
    i=$((i + 1))
  done
  return 1
}
# p30_stty_part FILE: the stty -a block the --wrap-stty wrapper printed after the TUI.
p30_stty_part() { awk '/speed [0-9]+ baud/ { on = 1 } on { print } /__MT_TTY_END__/ { exit }' "$1"; }
# p30_rawseq RAW: which cursor sequence came last, whether the last alternate screen was left.
p30_rawseq() {
  LC_ALL=C awk 'BEGIN { RS = "\033" } NR > 1 {
      if (substr($0, 1, 5) == "[?25h") last = "h"
      else if (substr($0, 1, 5) == "[?25l") last = "l"
      if (substr($0, 1, 7) == "[?1049h") { on = 1; off = 0 }
      else if (substr($0, 1, 7) == "[?1049l" && on) off = 1
    }
    END { printf "last25=%s alt_on=%d alt_off=%d\n", (last == "" ? "none" : last), on + 0, off + 0 }' "$1"
}
# p30_state_sum: what a picker could write: the run's config and every kit selection.
p30_state_sum() {
  local f
  if [ -f "$CFG/config" ]; then printf 'config %s\n' "$(cksum < "$CFG/config" | awk '{ print $1 "-" $2 }')"; else printf 'config none\n'; fi
  if [ -d "$CFG/kits" ]; then
    for f in "$CFG/kits"/*; do
      [ -f "$f" ] && printf 'kit %s %s\n' "${f##*/}" "$(cksum < "$f" | awk '{ print $1 }')"
    done
  fi
  return 0
}
# p30_sessions_ids FILE: a non-terminal session listing without its age column (bin/cleat:27093).
p30_sessions_ids() { LC_ALL=C grep -E -e '^    ' "$1" | cut -c25- | LC_ALL=C sort; LC_ALL=C grep -E -e 'sessions?\. Act on|in the trash' "$1"; return 0; }
p30_brew_bash() { local p; p=$(brew --prefix 2>/dev/null) || return 1; [ -x "$p/bin/bash" ] || return 1; printf '%s\n' "$p/bin/bash"; }
# p30_policy_has_apt: rc 0 when the global policy lists deb.debian.org (apt-debian is ticked).
p30_policy_has_apt() { [ -f "$CFG/config" ] && LC_ALL=C grep -q -E '^[[:space:]]*pack[[:space:]]*=[[:space:]]*apt-debian[[:space:]]*$' "$CFG/config"; }
# p30_t1_size ROWS COLS: typed mode sets T1's window. rc 1 when it could not (the human does it).
p30_t1_size() {
  local w
  [ "$(t_mode)" = typed ] || return 1
  w=$(kv_get t1.win "")
  p30_is_int "$w" || return 1
  run_cmd -q -t 20 -- osascript -e "tell application \"Terminal\"
  set number of rows of tab 1 of window id $w to $1
  set number of columns of tab 1 of window id $w to $2
end tell"
}

# ---- the editor's program pieces (2.13a, 2.14-brew) ----
# p30_ed_begin: a new program that waits for the editor's first frame (it ends with ESC [ J).
p30_ed_begin() {
  xp_new
  xp_wait open 'Cleat egress' 120
  xp_wait f0 '\x1b\[J' 30
  P30_KN=0
}
# p30_ed_key KEYS [SNAP]: KEYS, then the frame they cause, then a snapshot.
p30_ed_key() {
  P30_KN=$((P30_KN + 1))
  xp_mark "k$P30_KN"
  xp_send "$1"
  xp_wait "f$P30_KN" '\x1b\[J' 20
  if [ -n "${2:-}" ]; then xp_sleep 200; xp_snap "$2"; fi
}
# p30_ed_last: from the top of the list to its last row, [+] Add a host.
p30_ed_last() { xp_hold "<down>" 35 40; xp_quiet 800 "nav$P30_KN"; }
# p30_ed_addp: space on [+] Add a host, then the prompt.
p30_ed_addp() {
  P30_KN=$((P30_KN + 1))
  xp_mark "k$P30_KN"
  xp_send "<space>"
  xp_wait "addp$P30_KN" 'Add a host >' 20
  xp_sleep 300
}
# p30_ed_quit: Esc on the list cancels after a second: Nothing saved, then the end.
p30_ed_quit() { xp_send "<esc>"; xp_wait nothing 'Nothing saved' 20; xp_eof 30; }

# ---- the pickers' program pieces (2.14a, 2.14-brew): each redraw ends with ESC [ <n> A ----
p30_pk_begin() { xp_new; xp_wait open "$1" 120; xp_wait d0 '\x1b\[[0-9]+A' 30; xp_sleep 200; P30_KN=0; }
p30_pk_key() {
  P30_KN=$((P30_KN + 1))
  xp_mark "k$P30_KN"
  xp_send "$1"
  xp_wait "d$P30_KN" '\x1b\[[0-9]+A' 20
  xp_sleep 200
  [ -n "${2:-}" ] && xp_snap "$2"
  return 0
}
# p30_pk_chords PREFIX [ITERM]: Option+Left, Option+Right, Page Up, down, each with a snapshot.
p30_pk_chords() {
  p30_pk_key "<opt-left>" "$1-optl"
  p30_pk_key "<opt-right>" "$1-optr"
  if [ -n "${2:-}" ]; then
    p30_pk_key "<opt-left-iterm>" "$1-optli"
    p30_pk_key "<opt-right-iterm>" "$1-optri"
  fi
  p30_pk_key "<pgup>" "$1-pgup"
  p30_pk_key "<down>" "$1-down"
}
# p30_pk_check NAME PREFIX [ITERM] [STAY]: the chords did nothing, down moved the cursor one row
# (STAY non-empty: a list of one row, where down has nowhere to go and the cursor stays).
p30_pk_check() {
  local name="$1" pre="$2" stay="${4:-}" s r0 r1 want snaps="optl optr"
  [ -n "${3:-}" ] && snaps="$snaps optli optri"
  snaps="$snaps pgup"
  for s in $snaps; do
    xsnap "$pre-$s"
    expect_not_contains "$name: still open after $s (no Cancelled.)" "Cancelled."
    expect_match "$name: the picker is still drawn after $s" '▸'
  done
  xsnap "$pre-pgup"; r0=$(p30_cursor_row "$OUT")
  xsnap "$pre-down"; r1=$(p30_cursor_row "$OUT")
  if [ "${DRY:-0}" = 1 ]; then expect_eq "$name: down moves the cursor one row" "$r1" "$r0"; return 0; fi
  if p30_is_int "$r0" && p30_is_int "$r1"; then
    if [ -n "$stay" ]; then
      want="$r0"
      check_note "$name: one row only, so down keeps the cursor where it is"
    else
      want=$((r0 + 1))
    fi
    expect_eq "$name: down moves the cursor one row" "$r1" "$want"
  else
    check_fail "$name: down moves the cursor one row" "a cursor row in both snapshots" "before ${r0:-none}, after ${r1:-none}"
  fi
}

# ---- cleat config held to the window (W12): checks over a series of snapshots ----
# p30_w12_snaps PREFIX N: the snapshot names PREFIX-1 .. PREFIX-N.
p30_w12_snaps() { local i=1; while [ "$i" -le "$2" ]; do printf '%s-%s\n' "$1" "$i"; i=$((i + 1)); done; }
# p30_w12_check LABEL COLS ROWERE SNAP...: one Capabilities header in each, never moving, the
# footer and the named row whole at 80 or cut with … at fewer, no frame row wider than COLS - 1.
p30_w12_check() {
  local label="$1" cols="$2" rowre="$3" s cap0="" cap n bad_one="" bad_move="" bad_foot="" bad_row="" bad_wide="" foot w
  shift 3
  if [ "${DRY:-0}" = 1 ]; then
    expect_eq "$label: one Capabilities header in every snapshot" "" ""
    return 0
  fi
  for s in "$@"; do
    xsnap "$s"
    n=$(p30_nrows "$OUT" 'Capabilities')
    [ "$n" = 1 ] || bad_one="$bad_one $s($n)"
    cap=$(p30_rowno "$OUT" 'Capabilities')
    [ -n "$cap0" ] || cap0="$cap"
    [ "$cap" = "$cap0" ] || bad_move="$bad_move $s(row $cap, was $cap0)"
    foot=$(p30_rowno "$OUT" '↑/↓ move  space toggle')
    if [ "$cols" -ge 80 ]; then
      LC_ALL=C grep -q -E -e '↑/↓ move  space toggle  ←/→ change  ⏎ save  q cancel$' "$OUT" || bad_foot="$bad_foot $s"   # bin/cleat:33853
      LC_ALL=C grep -q -E -e "$rowre" "$OUT" || bad_row="$bad_row $s"
    else
      LC_ALL=C grep -q -E -e '^  ↑/↓ move  space toggle  ←/→ change  ⏎.*…$' "$OUT" || bad_foot="$bad_foot $s"
      LC_ALL=C grep -q -E -e "$rowre" "$OUT" || bad_row="$bad_row $s"
    fi
    if p30_is_int "$cap" && p30_is_int "$foot"; then
      w=$(p30_maxwidth "$OUT" "$cap" "$foot")
      p30_is_int "$w" && [ "$w" -le $((cols - 1)) ] || bad_wide="$bad_wide $s($w)"
    else
      bad_wide="$bad_wide $s(no frame)"
    fi
  done
  if [ -z "$bad_one" ]; then check_pass "$label: exactly one Capabilities header in all $# snapshots"; else check_fail "$label: exactly one Capabilities header in every snapshot" "1 each" "$bad_one"; fi
  if [ -z "$bad_move" ]; then check_pass "$label: the frame never moved (Capabilities on screen row $cap0 throughout)"; else check_fail "$label: the frame never moves down the window" "the same row" "$bad_move"; fi
  if [ -z "$bad_foot" ]; then check_pass "$label: the footer reads as expected in every snapshot"; else check_fail "$label: the footer reads as expected in every snapshot" "whole at 80, cut with … below" "$bad_foot"; fi
  if [ -z "$bad_row" ]; then check_pass "$label: the long row reads as expected in every snapshot"; else check_fail "$label: the long row reads as expected in every snapshot" "$rowre" "$bad_row"; fi
  if [ -z "$bad_wide" ]; then check_pass "$label: no frame row is wider than $((cols - 1)) columns"; else check_fail "$label: no frame row wider than $((cols - 1)) columns" "<= $((cols - 1))" "$bad_wide"; fi
}

# ---------------------------------------------------------------------------------------------
# 2.0 Sitting 2 starts
# ---------------------------------------------------------------------------------------------
st_2_0() {
  run_cmd -t 60 -- egcheck
  expect_contains "egcheck: the tracked tree is clean" "tree: clean"
  expect_not_contains "egcheck: no test lock in the worktree" "test lock held"
  run_cmd -t 600 -- egimg
  expect_contains "egimg: the relay is this tree's" "relay: this tree's"
  expect_contains "egimg: the entrypoint is this tree's" "entrypoint: this tree's"
  if [ "${DRY:-0}" != 1 ] && { ! LC_ALL=C grep -q "relay: this tree's" "$OUT" || ! LC_ALL=C grep -q "entrypoint: this tree's" "$OUT"; }; then
    step_abort "the $MT_IMAGE image was not built from this tree. Never go on with it: ./egress-release.sh --only 0.5"
  fi
}

# ---------------------------------------------------------------------------------------------
# 2.1 Step 1: refusal on an engine not validated
# ---------------------------------------------------------------------------------------------
st_2_1() {
  local n sgw
  p30_cd eg-refuse make
  on_cleanup "safe_rm $(printf '%q' "$CLEAT_UNVAL")"
  sed 's/^_EGRESS_VALIDATED_ENGINES=".*"$/_EGRESS_VALIDATED_ENGINES="engine-linux"/' "$MT_WT/bin/cleat" > "$CLEAT_UNVAL" \
    || step_abort "could not write $CLEAT_UNVAL"
  n=$(LC_ALL=C grep -c '^_EGRESS_VALIDATED_ENGINES="engine-linux"$' "$CLEAT_UNVAL" 2>/dev/null)
  expect_num "the copy names engine-linux alone (grep -c)" "${n:-0}" eq 1
  if [ "${DRY:-0}" != 1 ] && [ "${n:-0}" != 1 ]; then step_abort "the throwaway copy was not narrowed"; fi
  cl --as cleatu -- egress status
  first_lines 3
  expect_contains "status: not available on this engine" "x Egress control is not available on $ENGINE_WORDS"   # bin/cleat:14475
  expect_contains "status: boxes with a policy refuse, cleat egress off named" "Boxes with a policy refuse to start here.  Run without it:  cleat egress off"   # bin/cleat:14476
  clt --as cleatu -T 300 -- run
  expect_rc "cleatu run exits 1" 1
  expect_contains "the refusal headline" "✖ Egress control is not validated on this Docker engine yet"   # bin/cleat:10973
  expect_contains "the engine line" "Engine:  $ENGINE_WORDS"                                            # bin/cleat:10975
  expect_contains "the status line" "Status:  supported design, not yet validated on this platform"    # bin/cleat:10976
  expect_contains "the validated-on line" "Egress control is validated on"                             # bin/cleat:10978
  # The copy's set is engine-linux alone, so the line names that engine and no other (10970-10972, 10951).
  expect_contains "the validated-on line names the narrowed set" "Egress control is validated on Docker Engine on Linux (rootful)."
  expect_contains "the reason, first half" "Until the validation checklist passes here, cleat refuses rather than"   # bin/cleat:10979
  expect_contains "the reason, second half" "claiming a cage it has not tested."                       # bin/cleat:10980
  expect_contains "cleat egress off is named" "Run without it:  cleat egress off"                      # bin/cleat:10982
  expect_contains "the tracking pointer" "Track it:        docs/egress-validation.md"                  # bin/cleat:10983
  expect_not_contains "cleat egress open is never named" "cleat egress open"
  val n -t 60 -- p30_names_count '^cleat-eg-refuse-'
  expect_num "no eg-refuse box exists" "$n" eq 0
  val sgw -t 60 -- gw eg-smoke
  run_cmd -t 60 -- egobjs
  first_lines 3
  expect_count "egobjs: one gateway in the first lines" '^cleat-gw-' eq 1
  if [ -n "$sgw" ]; then
    expect_match "egobjs: that gateway is eg-smoke's" "^$sgw "
  else
    check_note "eg-smoke's gateway could not be named: only the count was checked"
  fi
  safe_rm "$CLEAT_UNVAL"
  expect_eq "git status --short prints nothing (the script's own files aside)" "$(git_dirty_untracked)" ""
  rec_row 1 "refused on $ENGINE_WORDS by a copy narrowed to engine-linux: rc 1, nothing created, cleat egress off named, cleat egress open never named"
}

# ---------------------------------------------------------------------------------------------
# 2.2 Step 2: the validated leg
# ---------------------------------------------------------------------------------------------
st_2_2() {
  p30_cd eg-refuse make
  cl -- egress status
  first_lines 3
  expect_contains "no box yet, the gateway comes with it" "○ No box yet. Its gateway is created with it on the next launch."   # bin/cleat:14478
  expect_not_contains "no engine refusal: not available" "not available"
  expect_not_contains "no engine refusal: not validated" "not validated"
  rec_row 2 "the candidate renders gateway rows (No box yet) and no engine line"
}

# ---------------------------------------------------------------------------------------------
# 2.3 Step 3: the host.docker.internal probe (records only)
# ---------------------------------------------------------------------------------------------
st_2_3() {
  local created resolved err rt ran=1
  p30_cd eg-refuse make
  dk -t 300 -- run --rm --network none --add-host host.docker.internal:host-gateway alpine cat /etc/hosts
  [ "$TIMEDOUT" = 1 ] && ran=0
  if [ "$RC" = 0 ]; then created=yes; else created=no; fi
  if [ "${DRY:-0}" != 1 ] && LC_ALL=C grep -q 'host\.docker\.internal' "$OUT"; then resolved=yes; else resolved=no; fi
  record_value step3.created "$created" "the --network none create succeeded"
  record_value step3.resolved "$resolved" "host.docker.internal is in /etc/hosts"
  dk -t 120 -- run --rm --network none --add-host host.docker.internal:host-gateway --entrypoint bash "$MT_IMAGE" -c 'time timeout 5 curl -sS http://host.docker.internal/'
  [ "$TIMEDOUT" = 1 ] && ran=0
  err=$(LC_ALL=C grep -m 1 'curl:' "$OUT" 2>/dev/null)
  rt=$(LC_ALL=C grep -m 1 '^real' "$OUT" 2>/dev/null)
  record_value step3.curl "${err:-no curl error line} (rc $RC)" "the in-image curl to host.docker.internal"
  record_value step3.real "${rt:-no time line}" "its elapsed time"
  if [ "$ran" = 1 ]; then check_pass "both probes ran (this step records, it does not judge)"; else check_fail "both probes ran" "both finished" "a probe timed out"; fi
  rec_row 3 "probe: create $created, resolved $resolved, connect: ${err:-none}, ${rt:-no time}"
}

# ---------------------------------------------------------------------------------------------
# 2.4 Step 4: a box with a one-host policy
# ---------------------------------------------------------------------------------------------
st_2_4a() {
  local h
  p30_cd eg-check make
  clt -T 300 -- egress --list
  for h in api.anthropic.com claude.ai claude.com code.claude.com platform.claude.com example.com; do
    expect_match "--list holds $h" "^ +$(printf '%s' "$h" | sed 's/\./\\./g') +"   # bin/cleat:13702 (printf '    %-40s %s')
  done
}

st_2_4b() {
  local existed=0 c sum
  p30_cd eg-check
  if [ "${DRY:-0}" != 1 ] && run_cmd -q -t 90 -- box_claude_live eg-check; then
    check_note "Claude Code is already open in eg-check (an earlier attempt): the launch checks cannot be made again"
    check_pass "Claude Code is live in eg-check"
    return 0
  fi
  if [ "${DRY:-0}" != 1 ]; then
    val c -t 60 -- cn eg-check
    [ -n "$c" ] && existed=1
  fi
  say "If Claude Code opens on a login screen in T1, sign in through the box, then leave the session open."
  # A re-run after 2.13a item 11 saved the github pack: the summary counts its hosts as well.
  sum="+Egress:     strict  ·  6 hosts, 1 pack"
  if [ "${DRY:-0}" != 1 ] && [ -f "$CFG/config" ] && LC_ALL=C grep -q -E '^[[:space:]]*pack[[:space:]]*=[[:space:]]*github[[:space:]]*$' "$CFG/config"; then
    check_note "github is in the global policy (2.13a saved it before this re-run): the summary counts its hosts and two packs"
    sum="~Egress: +strict  ·  [0-9]+ hosts, 2 packs"
  fi
  if [ "$existed" = 1 ]; then
    check_note "the eg-check box exists from an earlier attempt: its once-per-box notice printed then"
    p30_launch eg-check cleat launch-2.4 \
      "$sum" \
      "-Shim not listening"
  else
    p30_launch eg-check cleat launch-2.4 \
      "$sum" \
      "+host.docker.internal is not reachable from a box with a policy." \
      "-Shim not listening"
  fi
  # bin/cleat:12331 (the summary row), 12463 (the notice), 11464 and 14707 (the relay advisory and row)
}

st_2_4c() {
  local mode mount uidl n nf line
  p30_cd eg-check
  p30_ck_read
  [ -n "$CK_CN" ] || step_abort "no eg-check box: run 2.4b first"
  [ -n "$CK_GW" ] || step_abort "eg-check has no gateway: run 2.4b first"
  kv_set eg-check.cn "$CK_CN"; kv_set eg-check.vol "$CK_VOL"; kv_set eg-check.gw "$CK_GW"; kv_set eg-check.bh "$CK_BH"
  say "$CK_CN $CK_GW $CK_VOL $CK_BH"
  dk -- inspect -f '{{.HostConfig.NetworkMode}} {{json .HostConfig.CapDrop}}' "$CK_CN"
  expect_match "the box's network is none" '^none '
  # The scenario's two spellings only: another one is the difference 2.4 says to write down.
  expect_match "the box drops CAP_NET_RAW or ALL" '("CAP_NET_RAW"|"ALL")'
  mode=$(head -n 1 "$OUT" 2>/dev/null)
  record_value step4.box.netmode_capdrop "$mode" "the box's NetworkMode and CapDrop"
  dk -- inspect -f '{{range .Mounts}}{{if eq .Destination "/run/cleat-egress"}}{{.Type}} {{.Name}} {{.Destination}} rw={{.RW}}{{end}}{{end}}' "$CK_CN"
  expect_match "the socket mount is the gateway's volume, read-only" '^volume cleat-gw-[0-9a-f]{12}-sock /run/cleat-egress rw=false$'
  mount=$(head -n 1 "$OUT" 2>/dev/null)
  record_value step4.box.mount "$mount" "the box's mount line"
  dk -- inspect -f '{{index .Config.Labels "sh.cleat.egress-engine"}} {{index .Config.Labels "sh.cleat.egress-hash"}}' "$CK_CN"
  expect_match "the engine and hash labels" "^$MT_EXPECT_ENGINE v1:[0-9a-f]{16}\$"
  dk -- inspect -f '{{.State.Health.Status}} ro={{.HostConfig.ReadonlyRootfs}} restart={{.HostConfig.RestartPolicy.Name}}:{{.HostConfig.RestartPolicy.MaximumRetryCount}} mem={{.HostConfig.Memory}} pids={{.HostConfig.PidsLimit}} add={{.HostConfig.CapAdd}} drop={{.HostConfig.CapDrop}} sec={{.HostConfig.SecurityOpt}}' "$CK_GW"
  expect_match "the gateway: healthy, read-only, on-failure:3, 128 MiB, 128 pids" '^healthy ro=true restart=on-failure:3 mem=134217728 pids=128 '
  expect_match "the gateway adds CHOWN" 'add=\[[^]]*(CAP_)?CHOWN'
  expect_match "the gateway adds SETUID" 'add=\[[^]]*(CAP_)?SETUID'
  expect_match "the gateway adds SETGID" 'add=\[[^]]*(CAP_)?SETGID'
  expect_match "the gateway drops ALL" 'drop=\[[^]]*ALL'
  expect_match "the gateway has no-new-privileges" 'sec=\[[^]]*no-new-privileges'
  run_cmd -t 60 -- p30_gw_proc "$CK_GW"
  uidl=$(awk '$1 == "Uid:" { print $2 }' "$OUT" 2>/dev/null)
  record_value step4.gw.uid "${uidl:-none}" "the gateway process uid (65532 expected)"
  if [ "${DRY:-0}" = 1 ]; then expect_ne "the gateway runs at a nonzero uid" "$uidl" "0"
  elif p30_is_int "$uidl" && [ "$uidl" != 0 ]; then check_pass "the gateway runs at a nonzero uid" "$uidl"
  else check_fail "the gateway runs at a nonzero uid" "not 0" "${uidl:-none}"; fi
  expect_match "CapPrm all zeros" '^CapPrm:[[:space:]]+0+$'
  expect_match "CapEff all zeros" '^CapEff:[[:space:]]+0+$'
  expect_match "NoNewPrivs: 1" '^NoNewPrivs:[[:space:]]+1$'
  # The three normalization containers. Names never start with cleat-.
  nf=$(p30_fails)
  on_cleanup "egv_rm egv-netraw egv-all egv-seccomp"
  egv_rm egv-netraw egv-all egv-seccomp
  egv_create egv-netraw --cap-drop NET_RAW alpine true
  egv_create egv-all --cap-drop ALL alpine true
  egv_create egv-seccomp --security-opt seccomp=unconfined alpine true
  dk -- inspect -f '{{json .HostConfig.CapDrop}}' egv-netraw
  line=$(head -n 1 "$OUT" 2>/dev/null); record_value step4.netraw "$line" "egv-netraw CapDrop, verbatim"
  expect_line 'egv-netraw reads exactly ["CAP_NET_RAW"]' '["CAP_NET_RAW"]'
  dk -- inspect -f '{{json .HostConfig.CapDrop}}' egv-all
  line=$(head -n 1 "$OUT" 2>/dev/null); record_value step4.all "$line" "egv-all CapDrop, verbatim"
  expect_line 'egv-all reads exactly ["ALL"]' '["ALL"]'
  dk -- inspect -f '{{json .HostConfig.SecurityOpt}}' egv-seccomp
  line=$(head -n 1 "$OUT" 2>/dev/null); record_value step4.seccomp "$line" "egv-seccomp SecurityOpt, verbatim"
  expect_match "egv-seccomp has an entry ending =unconfined" '"[^"]*=unconfined"'
  egv_rm egv-netraw egv-all egv-seccomp
  n=$(p30_fails)
  if p30_is_int "$n" && p30_is_int "$nf" && [ "$n" -gt "$nf" ]; then
    check_note "a different spelling is not a pass: write the difference down before the leg can be validated"
  fi
  rec_row 4 "box: $mode, $mount. normalization: $(kv_get step4.netraw ''), $(kv_get step4.all ''), $(kv_get step4.seccomp '')"
}

# ---------------------------------------------------------------------------------------------
# 2.5 to 2.8
# ---------------------------------------------------------------------------------------------
st_2_5() {
  local log
  p30_cd eg-check
  p30_ck_load
  p30_need_up eg-check resume-2.5
  run_cmd -e -t 60 -- bget eg-check https://example.com/
  expect_line "an allowed host answers 200" "200"
  record_value step5.code "$(head -n 1 "$OUT" 2>/dev/null)" "the code"
  cl -- egress log
  log="$OUT"
  run_cmd -q -t 30 -- p30_lastmatch 'allowed   example\.com:443' "$log"
  expect_match "the log's last allow of example.com" 'v allowed   example\.com:443'   # bin/cleat:13929
  rec_row 5 "bget example.com: $(kv_get step5.code '') and the log row v allowed example.com:443"
}

st_2_6() {
  p30_cd eg-check
  p30_ck_load
  p30_need_up eg-check resume-2.6
  run_cmd -t 60 -- bconnect eg-check example.org:443
  p30_403
  record_value step6.status "$(LC_ALL=C grep -m 1 '^HTTP/' "$OUT" 2>/dev/null)" "the status line"
  record_value step6.body "$(LC_ALL=C grep -m 1 -A 2 'This is a Cleat policy decision' "$OUT" 2>/dev/null | tr '\n' ' ')" "the two body sentences"
  cl -- egress why example.org
  first_lines 4
  expect_contains "why: denied" "x Denied   example.org:443"   # bin/cleat:13810
  rec_row 6 "bconnect example.org: 403 with X-Cleat-Reason policy and both body sentences, why: x Denied"
}

st_2_7a() {
  local uid gid myuid mygid hu hg own bad
  p30_cd eg-check
  p30_ck_load
  p30_need_up eg-check resume-2.7a
  myuid=$(id -u); mygid=$(id -g)
  run_cmd -t 60 -- p30_host_ids "$CK_CN"
  hu=$(sed -n 's/^HOST_UID=//p' "$OUT" 2>/dev/null | head -n 1)
  hg=$(sed -n 's/^HOST_GID=//p' "$OUT" 2>/dev/null | head -n 1)
  expect_eq "HOST_UID is this user's uid" "$hu" "$myuid"
  expect_eq "HOST_GID is this user's gid" "$hg" "$mygid"
  uid="${hu:-$myuid}"; gid="${hg:-$mygid}"
  p30_is_int "$uid" || uid="$myuid"
  p30_is_int "$gid" || gid="$mygid"
  record_value box.uid "$uid" "the box uid"
  kv_set box.gid "$gid"
  val own -t 60 -- bx eg-check stat -c '%u' /run/cleat-egress/proxy.sock
  if [ "${DRY:-0}" != 1 ] && [ "$own" != "$uid" ]; then
    check_note "the socket belongs to ${own:-nobody}, not $uid (an earlier attempt's chown): cleat egress restart first"
    clt -T 300 -- egress restart
  fi
  run_cmd -t 60 -- p30_top_socat "$CK_CN"
  bad=$(awk -v u="$uid" 'tolower($0) ~ /socat/ { n++; if ($2 != u) b++ } END { if (n == 0) print "none"; else print b + 0 }' "$OUT" 2>/dev/null)
  if [ "${DRY:-0}" = 1 ]; then expect_eq "every socat runs at the box uid" "$bad" "0"
  elif [ "$bad" = 0 ]; then check_pass "every socat runs at uid $uid"
  else check_fail "every socat runs at the box uid" "uid $uid on each socat line" "${bad:-?} lines differ (none = no socat)"; fi
  run_cmd -t 60 -- bx eg-check stat -c '%u %a %F' /run/cleat-egress/proxy.sock
  expect_line "the socket is the box uid's, 600, a socket" "$uid 600 socket"
  run_cmd -t 60 -- bxr eg-check rm -f /run/cleat-egress/proxy.sock
  expect_rc "box root cannot unlink the socket" '!0'
  expect_contains "the rm is refused as a read-only file system" "Read-only file system"
  dk -t 60 -- exec -u "$uid:$gid" "$CK_GW" /usr/local/bin/gw-admin selftest
  expect_contains "selftest as the box uid" "ok selftest cleat-egress-ok"   # gw-admin:58
  dk -t 60 -- exec -u "$((uid + 1)):$gid" "$CK_GW" /usr/local/bin/gw-admin selftest
  expect_rc "selftest as uid + 1 exits 2" 2
  expect_contains "selftest as uid + 1 gets no answer" "gw-admin: no answer"   # gw-admin:79
}

st_2_7b() {
  local vol uid chown_at i t secs="" turned="" extra=0 stamp rows gwbad="" before after said1 said2 own
  p30_cd eg-check
  p30_ck_load
  p30_need_up eg-check resume-2.7b
  uid=$(p30_uid)
  vol="$CK_VOL"
  case "$vol" in cleat-gw-*-sock|"<dry:"*) ;; *) step_abort "eg-check's socket volume is '$vol', not a gateway socket volume" ;; esac
  # Re-entry: an earlier attempt's chown still holds (cut after it). The relay's heartbeat has failed
  # since then, so a second chown alone would time the row from the first one: the turn would come
  # early and read 2m or more after a break. cleat egress restart gives a fresh socket and a
  # heartbeat first, so this attempt times its own chown.
  val own -t 60 -- bx eg-check stat -c '%u' /run/cleat-egress/proxy.sock
  if [ "${DRY:-0}" != 1 ] && [ "$own" != "$uid" ]; then
    check_note "the socket belongs to ${own:-nobody}, not $uid (an earlier attempt's chown): cleat egress restart first, so the relay is heard again before this chown"
    clt -T 300 -- egress restart
    expect_contains "the gateway restarted and healthy before the chown" "✔ Box main's gateway restarted and healthy."   # bin/cleat:13295
    run_cmd -t 60 -- bx eg-check stat -c '%u %a' /run/cleat-egress/proxy.sock
    expect_line "the socket is the box uid's again before the chown" "$uid 600"
  fi
  chown_at=$(epoch_now)
  kv_set step7.chown_at "$chown_at"
  say "chown at $(date -u +%T) UTC"
  dk -t 120 -- run --rm -v "$vol:/v" alpine chown 0:0 /v/proxy.sock
  run_cmd -t 60 -- bx eg-check stat -c '%u %a' /run/cleat-egress/proxy.sock
  expect_line "the socket now belongs to root" "0 600"
  run_cmd -e -t 60 -- bget eg-check https://example.com/
  expect_not_contains "the request no longer gets 200" "200"
  record_value step7.bget "$(head -n 1 "$OUT" 2>/dev/null) $(head -n 1 "$ERR" 2>/dev/null)" "the failing request"
  run_cmd -t 60 -- bconnect eg-check example.org:443
  expect_not_contains "the CONNECT gets no 403" "403"
  record_value step7.bconnect "$(head -n 1 "$OUT" 2>/dev/null)" "the failing CONNECT"
  i=1
  while [ "$i" -le 10 ]; do
    t=$(epoch_now)
    stamp=$(date -u +%T)
    cl -t 120 -- egress status
    grep_lines 'Gateway|Shim'
    rows=$(tr '\n' '|' < "$OUT" 2>/dev/null)
    record_value "step7.read$i" "$stamp $rows" "read $i"
    if [ "${DRY:-0}" != 1 ] && ! LC_ALL=C grep -q '● Gateway healthy' "$OUT"; then gwbad="$gwbad $i"; fi
    if [ -n "$turned" ]; then extra=1; break; fi
    if [ "${DRY:-0}" = 1 ] || LC_ALL=C grep -q -E -e '! Shim not listening +last seen [0-9]+m?[0-9]*s ago, no heartbeat since' "$OUT"; then
      turned="$i"
      secs=$((t - chown_at))
      expect_match "the first turned row reads 1m<n>s" '! Shim not listening +last seen 1m[0-9]+s ago, no heartbeat since'   # bin/cleat:14703,14707
    fi
    i=$((i + 1))
    if [ "$i" -le 10 ] && [ "${DRY:-0}" != 1 ]; then sleep 15; fi
  done
  if [ -n "$turned" ]; then
    record_value step7.secs "$secs" "seconds from the chown to the turned row"
    expect_num "the relay row turned within 150 s of the chown" "$secs" le 150
  else
    check_fail "the relay row turned within ten reads" "! Shim not listening    last seen 1m<n>s ago, no heartbeat since" "never in 10 reads"
  fi
  [ "$extra" = 1 ] || [ -z "$turned" ] || check_note "no read was left after the turn"
  if [ -z "$gwbad" ]; then check_pass "the gateway row read ● Gateway healthy in every read"; else check_fail "the gateway row read ● Gateway healthy in every read" "● Gateway healthy" "not in read(s)$gwbad"; fi
  clt -T 300 -- egress status
  expect_contains "the row: health only" "(health only, not proof)"                              # bin/cleat:14708
  expect_contains "the row: fail before policy" "If requests fail, they fail before they reach policy."   # bin/cleat:14709
  expect_contains "the row: not a policy denial" "Not a policy denial."                            # bin/cleat:14710
  expect_contains "the row's fix" "Fix:  cleat egress restart --shim"                              # bin/cleat:14711
  val before -t 60 -- p30_relay_count eg-check
  clt -t 60 -T 300 -- shell
  expect_rc "cleat shell refuses, rc 1" 1
  expect_contains "shell: the gate's refusal" "✖ Egress refused box main: its gateway did not answer the box's own connection."   # bin/cleat:11781,12052
  expect_contains "shell: not a policy denial" "This is not a policy denial."                     # bin/cleat:11783
  expect_contains "shell: the fix is cleat egress restart" "Fix:  cleat egress restart"           # bin/cleat:11785
  expect_not_contains "shell: the fix is not --shim" "Fix:  cleat egress restart --shim"
  said1=$(LC_ALL=C grep -E -e "Egress refused|This is not a policy denial|Fix:" "$OUT" 2>/dev/null | sed "s/^ *//" | head -n 3)
  clt -T 300 -- egress restart --shim
  expect_rc "cleat egress restart --shim refuses, rc 1" 1
  expect_contains "--shim: the gate's refusal" "✖ Egress refused box main: its gateway did not answer the box's own connection."
  expect_contains "--shim: not a policy denial" "This is not a policy denial."
  expect_contains "--shim: hands on to cleat egress restart" "Fix:  cleat egress restart"
  record_value step7.shim "$(LC_ALL=C grep -m 1 'Egress refused' "$OUT" 2>/dev/null)" "what restart --shim printed"
  said2=$(LC_ALL=C grep -E -e "Egress refused|This is not a policy denial|Fix:" "$OUT" 2>/dev/null | sed "s/^ *//" | head -n 3)
  val after -t 60 -- p30_relay_count eg-check
  expect_eq "restart --shim started no relay (relay started count)" "$after" "$before"
  ask_record two-hops T2 "The status row named its own fix: cleat egress restart --shim. The gate runs first and names cleat egress restart, the command that heals this.
cleat shell printed:
${said1:-(nothing matched)}
cleat egress restart --shim printed:
${said2:-(nothing matched)}" \
    "Do the two hops read clearly: the row's own fix, cleat egress restart --shim, hands on to cleat egress restart?"
}

st_2_7c() {
  local uid
  p30_cd eg-check
  p30_ck_load
  # A box stopped since 2.7b (a break): its gateway is readied first, since the launch gate would
  # refuse the root-owned socket, then T1 resumes the box and the heal below runs as written.
  if ! run_cmd -q -t 60 -- box_running eg-check; then
    check_note "the eg-check box is not running: cleat egress restart readies its gateway, then T1 resumes the box"
    clt -T 300 -- egress restart
    p30_need_up eg-check resume-2.7c
  fi
  uid=$(p30_uid)
  clt -T 300 -- egress restart
  expect_contains "the gateway restarted and healthy" "✔ Box main's gateway restarted and healthy."   # bin/cleat:13295
  run_cmd -t 60 -- bx eg-check stat -c '%u %a' /run/cleat-egress/proxy.sock
  expect_line "the socket is the box uid's again" "$uid 600"
  run_cmd -e -t 60 -- bget eg-check https://example.com/
  expect_line "the allowed host answers 200 again" "200"
  run_cmd -t 60 -- bconnect eg-check example.org:443
  first_lines 1
  expect_contains "the CONNECT gets the 403 line again" "HTTP/1.1 403 cleat egress: example.org is not on the allowlist"
  rec_row 7 "uid $uid, socket $uid 600, the chown failed both requests, the row turned after $(kv_get step7.secs '?') s, restart --shim handed on to cleat egress restart, healed"
}

# p30_net_extra: after p30_net_dev (OUT), the interfaces besides lo. The scenario says lo: alone.
# A kernel with the tunnel drivers built in, Docker Desktop's VM among them (measured in the
# validation walk), gives every new network namespace its fallback tunnel devices: tunl0, gre0,
# gretap0, erspan0, ip_vti0, ip6_vti0, sit0, ip6tnl0, ip6gre0. They pass only when each is down
# and box root cannot raise one (CAP_NET_ADMIN, bit 12, is not in its bounding set). Any other
# name, an interface that is up, or the capability fails.
p30_net_extra() {
  local f="$OUT" extra n odd="" up="" fl bnd line
  if [ "${DRY:-0}" = 1 ]; then
    expect_eq "/proc/net/dev lists nothing but lo: and the kernel's fallback tunnel devices" "" ""
    run_cmd -t 60 -- p30_net_flags eg-check
    expect_eq "every interface but lo is down" "" ""
    val bnd -t 60 -- p30_capbnd eg-check
    expect_eq "box root cannot raise an interface (no CAP_NET_ADMIN)" "" ""
    return 0
  fi
  extra=$(LC_ALL=C grep -v -x -e 'lo:' "$f" 2>/dev/null | tr -d ':' | tr '\n' ' ')
  extra="${extra% }"
  if [ -z "$extra" ]; then
    check_pass "/proc/net/dev lists lo: alone"
    record_value step8.netdev "lo alone" "the box's interfaces"
    return 0
  fi
  for n in $extra; do
    case "$n" in tunl0|gre0|gretap0|erspan0|ip_vti0|ip6_vti0|sit0|ip6tnl0|ip6gre0) ;; *) odd="$odd $n" ;; esac
  done
  record_value step8.netdev "lo and the fallback tunnels $extra" "the box's interfaces"
  if [ -n "$odd" ]; then
    check_fail "/proc/net/dev lists nothing but lo: and the kernel's fallback tunnel devices" "lo:, then only tunl0 gre0 gretap0 erspan0 ip_vti0 ip6_vti0 sit0 ip6tnl0 ip6gre0" "also:$odd"
  else
    check_pass "/proc/net/dev: besides lo: only the kernel's fallback tunnel devices" "$extra"
    check_note "the scenario says lo: alone. This kernel gives every network namespace its fallback tunnel devices, so each is checked to be down and out of box root's reach"
  fi
  run_cmd -t 60 -- p30_net_flags eg-check
  while read -r n fl; do
    [ -n "$n" ] && [ "$n" != lo ] || continue
    case "$fl" in 0x[0-9a-fA-F]*) ;; *) up="$up $n($fl)"; continue ;; esac
    case "$fl" in *[!0-9a-fA-Fx]*) up="$up $n($fl)"; continue ;; esac
    [ $((fl & 1)) = 0 ] || up="$up $n(up)"
  done < "$OUT"
  if [ "$RC" = 0 ] && [ -z "$up" ]; then
    check_pass "every interface but lo is down (no IFF_UP)"
  else
    check_fail "every interface but lo is down (no IFF_UP)" "down" "rc $RC,${up:- no flags read}"
  fi
  val bnd -t 60 -- p30_capbnd eg-check
  line="$bnd"
  case "$bnd" in ''|*[!0-9a-fA-F]*) bnd="" ;; esac
  record_value step8.capbnd "${line:-none}" "box root's capability bounding set"
  if [ -z "$bnd" ]; then
    check_fail "box root cannot raise an interface (no CAP_NET_ADMIN)" "a CapBnd line" "${line:-none}"
  elif [ $(( (0x$bnd >> 12) & 1 )) = 0 ]; then
    check_pass "box root cannot raise an interface (CAP_NET_ADMIN is not in its bounding set)" "CapBnd $bnd"
  else
    check_fail "box root cannot raise an interface (no CAP_NET_ADMIN)" "bit 12 clear" "CapBnd $bnd"
  fi
}

st_2_8() {
  local n addrs pub rt a code
  p30_cd eg-check
  p30_ck_load
  p30_need_up eg-check resume-2.8
  run_cmd -t 60 -- bx eg-check getent hosts example.com
  expect_rc "no resolver in the box (getent rc 2)" 2
  run_cmd -t 60 -- bxr eg-check python3 -c 'import socket; socket.socket(socket.AF_PACKET, socket.SOCK_RAW)'
  expect_contains "no raw socket, even for box root" "PermissionError: [Errno 1] Operation not permitted"
  run_cmd -t 60 -- bx eg-check cat /proc/net/route
  expect_count "/proc/net/route is the header line alone" '.' eq 1
  run_cmd -t 60 -- p30_net_dev eg-check
  expect_line "/proc/net/dev lists lo:" "lo:"
  p30_net_extra
  run_cmd -t 60 -- bx eg-check cat /etc/resolv.conf
  record_value step8.resolv "$(tr '\n' ' ' < "$OUT" 2>/dev/null | cut -c1-200)" "/etc/resolv.conf (present, which is expected)"
  run_cmd -t 60 -- bx eg-check bash -c 'time timeout 5 curl -sS http://host.docker.internal/'
  expect_contains "host.docker.internal does not resolve in a caged box" "Could not resolve host"
  rt=$(LC_ALL=C grep -m 1 '^real' "$OUT" 2>/dev/null)
  record_value step8.hdi_time "${rt:-no time line}" "the in-box half of step 3"
  # Residual 30: the host's own public IPv4 address.
  if [ "${IS_MACOS:-0}" != 1 ] && [ "${DRY:-0}" != 1 ]; then
    check_skip "residual 30 (the Mac's public IPv4)" "not macOS"
    record_value step8.residual30 "not measured (not macOS)"
  else
    run_cmd -q -t 30 -- p30_ifaddrs
    addrs=$(tr '\n' ' ' < "$OUT" 2>/dev/null)
    if [ "${DRY:-0}" != 1 ] && { [ "$RC" != 0 ] || [ -z "${addrs// /}" ]; }; then
      # No address read is not "no public address": the residual stays unmeasured, said so.
      record_value step8.residual30 "not measured: ifconfig gave no address (rc $RC)" "residual 30"
      check_note "residual 30: read the Mac's addresses by hand with ifconfig and follow 2.8 of the scenario"
      addrs=""
    fi
    pub=$(printf '%s\n' $addrs | awk -F. 'NF == 4 {
        a = $1 + 0; b = $2 + 0
        if (a == 10 || a == 127) next
        if (a == 172 && b >= 16 && b <= 31) next
        if (a == 192 && b == 168) next
        if (a == 169 && b == 254) next
        if (a == 100 && b >= 64 && b <= 127) next
        print; exit }')
    if [ -z "$pub" ] && [ -z "$addrs" ] && [ "${DRY:-0}" != 1 ]; then
      :
    elif [ -z "$pub" ]; then
      record_value step8.residual30 "host holds no public IPv4" "residual 30"
    else
      choose residual30 "This Mac holds a public IPv4 address ($pub). Does something on it listen on port 443?" "n=no listener: record and skip" "y=yes: run the residual 30 probe now"
      if [ "$CHOICE" = y ]; then
        clt --answer eg-open=y -T 300 -- egress open
        a=$(printf '%s' "$pub" | tr '.' '-')
        run_cmd -e -t 60 -- bget eg-check "https://$a.sslip.io/"
        code=$(head -n 1 "$OUT" 2>/dev/null)
        case "$code" in 000|403|"") record_value step8.residual30 "public IPv4 present: refused ($code)" "residual 30" ;;
          *) record_value step8.residual30 "public IPv4 present: reached ($code)" "residual 30" ;; esac
        check_note "cleat egress open stays until step 9 stops the box"
      else
        record_value step8.residual30 "public IPv4 present, no listener on 443: not probed" "residual 30"
      fi
    fi
  fi
  rec_row 8 "getent rc 2, AF_PACKET EPERM, route header alone, $(kv_get step8.netdev 'interfaces not recorded'), $(kv_get step8.residual30 'residual 30 not recorded')"
  rec_row 3 "a caged box cannot resolve host.docker.internal (Could not resolve host)"
}

# ---------------------------------------------------------------------------------------------
# 2.9 Step 9: stop, then resume
# ---------------------------------------------------------------------------------------------
st_2_9a() {
  p30_cd eg-check
  p30_ck_load
  p30_exit eg-check exit-2.9a
  clt -T 300 -- stop
  if [ "${DRY:-0}" != 1 ] && LC_ALL=C grep -q 'Container not running' "$OUT"; then
    check_note "the box was already stopped (Container not running)"
  else
    expect_contains "cleat stop ends the session" "✔ Session ended. Resume with: cleat resume"   # bin/cleat:23039
  fi
  cl -- egress status
  first_lines 4
  expect_match "the gateway is stopped with its box" '○ Gateway stopped +its box is stopped too'   # bin/cleat:14673
  expect_contains "its fix is cleat start" "Fix:  cleat start"                                    # bin/cleat:14675
  cl -- status
  grep_lines_after 'Egress:' 1
  expect_match "cleat status has its Egress row" 'Egress:'
  expect_not_match "no anomaly line for a stopped box" '^[[:space:]]+(!|x) '   # bin/cleat:14617
}

st_2_9b() {
  local uid gs bs rel line rstamp re be lat fc
  p30_cd eg-check
  p30_ck_load
  uid=$(p30_uid)
  if [ "${DRY:-0}" != 1 ] && run_cmd -q -t 90 -- box_claude_live eg-check; then
    check_note "Claude Code is already open in eg-check (an earlier attempt): the resume checks cannot be made again"
  else
    p30_launch eg-check "cleat resume" resume-2.9 \
      "-Shim not listening" \
      "-host.docker.internal is not reachable from a box with a policy." \
      "-An MCP server running on your host stops working here"
  fi
  p30_ck_load
  val gs -t 60 -- gw_started eg-check
  val bs -t 60 -- box_started eg-check
  record_value step9.gw_started "$gs" "the gateway's StartedAt"
  record_value step9.box_started "$bs" "the box's StartedAt"
  rel=$(iso_cmp "$gs" "$bs")
  expect_eq "the gateway started before the box" "$rel" "lt"
  val line -t 60 -- box_netmode eg-check
  expect_eq "the box is still on none" "$line" "none"
  run_cmd -e -t 60 -- bget eg-check https://example.com/
  expect_line "step 5 holds: 200" "200"
  run_cmd -t 60 -- bconnect eg-check example.org:443
  p30_403
  run_cmd -t 60 -- p30_top_socat "$CK_CN"
  expect_match "socat runs at the box uid" "^ *[0-9]+ +$uid +socat"
  run_cmd -t 60 -- bx eg-check stat -c '%u %a' /run/cleat-egress/proxy.sock
  expect_line "the socket reads uid 600" "$uid 600"
  val line -t 60 -- p30_relay_last eg-check
  record_value step9.relay_line "$line" "the last relay started line"
  val fc -t 120 -- p30_find_count eg-check
  record_value step9.claude_files "$fc" "files under ~/.claude in the box"
  rstamp="${line%% *}"
  re=$(iso_to_epoch "$rstamp")
  be=$(iso_to_epoch "$bs")
  lat=""
  if p30_is_int "$re" && p30_is_int "$be"; then
    lat=$((re - be))
    record_value step9.relay_latency "$lat" "seconds from the box's StartedAt to relay started (W5)"
    expect_num "the last relay started line is from this start (not before the box's StartedAt)" "$lat" ge 0
    expect_num "the relay started within 10 s of the box (W5)" "$lat" le 10
  elif [ "${DRY:-0}" = 1 ]; then
    expect_num "the relay started within 10 s of the box (W5)" "0" le 10
  else
    record_value step9.relay_latency "unreadable" "seconds from the box's StartedAt to relay started (W5)"
    check_fail "the relay start latency could be read" "two stamps" "relay '${rstamp:-none}', box '${bs:-none}'"
  fi
  rec_row 9 "gateway started before the box, steps 5 to 7 hold, none, socat and socket at $uid, relay latency $(kv_get step9.relay_latency '?') s over $fc files, no relay advisory, no repeated notice"
}

# ---------------------------------------------------------------------------------------------
# 2.10 Step 10: kill the gateway
# ---------------------------------------------------------------------------------------------
st_2_10a() {
  local line gst
  p30_cd eg-check
  p30_ck_load
  # Re-entry: a gateway an earlier attempt killed, or one Docker restarted in 2.10c, gets a fresh
  # one first, so the kill below starts from a running gateway with 0 restarts.
  val gst -t 60 -- docker inspect -f '{{.State.Status}} {{.RestartCount}}' "$CK_GW"
  if [ "${DRY:-0}" != 1 ] && [ "$gst" != "running 0" ]; then
    check_note "the gateway reads '$gst' before the kill (an earlier attempt): cleat egress restart gives a fresh one first"
    clt -T 300 -- egress restart
    p30_ck_load
  fi
  p30_need_live eg-check resume-2.10a
  dk -- inspect -f '{{.State.StartedAt}} {{.RestartCount}}' "$CK_CN"
  line=$(head -n 1 "$OUT" 2>/dev/null)
  kv_set step10.box_started "${line%% *}"
  kv_set step10.box_restarts "${line##* }"
  record_value step10.box_before "$line" "the box's StartedAt and RestartCount before"
  gw_kill eg-check
  sleep 2
  dk -- inspect -f '{{.State.Status}} exit={{.State.ExitCode}} restarts={{.RestartCount}}' "$CK_GW"
  record_value step10.gw_after_kill "$(head -n 1 "$OUT" 2>/dev/null)" "the gateway right after docker kill"
  if [ "${DRY:-0}" != 1 ] && LC_ALL=C grep -q '^running' "$OUT"; then
    check_note "Docker brought the gateway back by itself: a success afterwards is the new gateway, not a bypass"
  else
    expect_line "the gateway exited 137, no restart" "exited exit=137 restarts=0"
  fi
  run_cmd -e -t 60 -- bx eg-check curl -sS -o /dev/null -w '%{http_code}\n' --max-time 20 -x http://127.0.0.1:3128 https://example.com/
  expect_rc "the request fails" '!0'
  expect_line "the request ends 000" "000"
  record_value step10.curl "$(head -n 1 "$ERR" 2>/dev/null)" "curl's message"
  run_cmd -t 60 -- bconnect eg-check example.org:443
  expect_not_contains "never a 403 while the gateway is down" "403"
  cl -- egress status
  first_lines 4
  expect_match "status: the gateway stopped, 0 restarts" 'x Gateway stopped +exited, 0 restarts'   # bin/cleat:14668
  expect_contains "status: no egress at all, not a denial" "The box has no egress at all right now. This is not a policy denial."   # bin/cleat:14670
  expect_contains "status: the fix" "Fix:  cleat egress restart"                                 # bin/cleat:14674
  cl -- status
  grep_lines_after 'Egress:' 1
  expect_contains "cleat status: the gateway line" "! gateway stopped. This is not a policy denial.  cleat egress status"   # bin/cleat:14620
  expect_not_contains "cleat status: nothing about the relay (W3)" "shim not listening"
  ask claude-fails T1 "In T1, ask Claude Code anything (for example: say hi)." "It fails with Claude Code's own network error." "Did Claude Code fail with its own network error?"
}

st_2_10b() {
  local line
  p30_cd eg-check
  p30_ck_load
  clt -T 300 -- egress restart
  expect_contains "the gateway restarted and healthy" "✔ Box main's gateway restarted and healthy."   # bin/cleat:13295
  run_cmd -e -t 60 -- bget eg-check https://example.com/
  expect_line "the healed request: 200" "200"
  dk -- inspect -f '{{.State.StartedAt}} {{.RestartCount}}' "$CK_CN"
  line=$(head -n 1 "$OUT" 2>/dev/null)
  expect_eq "the box's StartedAt is unchanged" "${line%% *}" "$(kv_get step10.box_started '')"
  expect_eq "the box's RestartCount is unchanged" "${line##* }" "$(kv_get step10.box_restarts '')"
  cl -- status
  grep_lines_after 'Egress:' 1
  expect_not_match "cleat status: the Egress row alone" '^[[:space:]]+(!|x) '
  ask claude-works T1 "In T1, ask Claude Code again." "It answers, with no box restart." "Did Claude Code answer?"
}

st_2_10c() {
  local try=1 caught=0 r rs gst state st1 shim
  p30_cd eg-check
  while [ "$try" -le 3 ]; do
    hdr "Try $try of 3: a restart Docker makes"
    p30_ck_load
    # A gateway that is not running, or that used its three restarts (an earlier try or attempt),
    # gets a fresh one first. Docker would not restart it again. A launch would refuse it.
    val gst -t 60 -- docker inspect -f '{{.State.Status}} {{.RestartCount}}' "$CK_GW"
    rs="${gst##* }"
    p30_is_int "$rs" || rs=0
    if [ "${DRY:-0}" != 1 ] && { [ "${gst%% *}" != running ] || [ "$rs" -ge 3 ]; }; then
      check_note "the gateway reads '$gst' (an earlier try or attempt): cleat egress restart gives a fresh one"
      clt -T 300 -- egress restart
      p30_ck_load
      rs=0
    fi
    p30_need_live eg-check "resume-2.10c-$try"
    if ! t_is_auto; then
      say ">>> Get ready in T1: the gateway is killed now and Docker brings it back in about 15 s."
      say ">>> The moment this script says NOW, type /exit in Claude Code in T1. The window is a few seconds wide."
    fi
    gw_hardkill eg-check
    run_cmd -t 90 -- p30_gw_watch "$CK_GW" 45 "$rs"
    r=$RC
    record_value "step10.watch$try" "$(tr '\n' '|' < "$OUT" 2>/dev/null)" "the gateway once a second after kill -9"
    if [ "$r" != 0 ] && [ "${DRY:-0}" != 1 ]; then
      check_note "try $try: the gateway did not come back healthy within 45 s"
      try=$((try + 1))
      continue
    fi
    if ! t_is_auto; then say ">>> NOW: type /exit in Claude Code in T1. The window closes at the relay's next heartbeat, at most 30 s after the restart."; fi
    t_wait_exit t1 eg-check 60
    cl -t 60 -- status
    grep_lines_after 'Egress:' 1
    st1="$OUT"
    cl -t 60 -- egress status
    grep_lines_after 'Shim' 1
    shim="$OUT"
    if [ "${DRY:-0}" = 1 ] || LC_ALL=C grep -q -E -e '! Shim not listening +never seen by this gateway' "$shim"; then
      state=caught
    elif LC_ALL=C grep -q 'Shim listening' "$shim"; then
      state=missed
    else
      state=other
    fi
    record_value "step10.try$try" "$state: $(tr '\n' '|' < "$shim" 2>/dev/null)" "the relay row right after the exit"
    if [ "$state" = caught ]; then
      caught=1
      expect_not_match "cleat status said nothing about the relay inside the window (W3)" '^[[:space:]]+(!|x) ' "$st1"
      expect_match "the relay row still reads never seen by this gateway" '! Shim not listening +never seen by this gateway' "$shim"   # bin/cleat:14701
      if t_capture t1 end-2.10c; then t_region end; fi
      if [ "${DRY:-0}" != 1 ] && t_have_capture && [ ! -s "$OUT" ]; then
        if t_is_auto; then check_skip "the session-end report said nothing about the relay" "T1 simulated: no session-end report"
        else check_fail "T1 printed the session-end line" "Session ended. Resume with: cleat resume" "not in T1's text"; fi
      else
        t_checks_or_ask end-2.10c "-Shim not listening" "-the in-box relay has not been heard from"   # bin/cleat:11464
      fi
      break
    fi
    check_note "try $try missed the window ($state): the next heartbeat came first"
    try=$((try + 1))
  done
  if [ "$caught" = 1 ]; then
    record_value step10.window "caught on try $try" "the restart window (W3)"
  else
    record_value step10.window "window not caught" "the restart window (W3): the unit tests hold the rule"
  fi
  p30_need_live eg-check resume-2.10c-last
  rec_row 10 "kill: exit 137, 0 restarts, curl $(kv_get step10.curl '?'), status x Gateway stopped, healed with the box unchanged, Docker's restart: $(kv_get step10.window '?')"
}

# ---------------------------------------------------------------------------------------------
# 2.11 Step 12: [setup] over https
# ---------------------------------------------------------------------------------------------
st_2_11a() {
  local c n
  p30_cd eg-setup make
  if [ "${ATTEMPT:-1}" -gt 1 ] && [ "${DRY:-0}" != 1 ]; then
    val c -t 60 -- cn eg-setup
    if [ -n "$c" ]; then
      check_note "an earlier attempt left the eg-setup box: cleat rm first"
      clt -T 300 -- rm
    fi
    cl -- untrust
    check_note "an earlier attempt approved the setup payload: cleat untrust so the prompt shows again"
  fi
  printf '[setup]\nenv > /tmp/mt-setup-env\nsudo apt-get update\nsudo apt-get install -y sl\n' > .cleat
  clt -T 300 -- egress allow apt-debian
  expect_match "allow apt-debian saves the pack" '^ +pack apt-debian$'   # bin/cleat:14222
  clt --answer trust-setup=y -t 600 -T 1200 -- run
  expect_match "the setup prompt names the network" "▸ Project .* wants to run [0-9]+ command\\(s\\) in the box as coder \\(network limited to this box's egress policy\\)"   # bin/cleat:5354,5357
  if [ "${DRY:-0}" != 1 ]; then expect_eq "the setup question was answered once (y)" "$(xfired trust-setup)" "1"; fi
  expect_not_contains "no Setup failed line" "Setup failed"
  expect_contains "Setup applied" "Setup applied"   # bin/cleat:19237
  expect_not_contains "the [setup] lines run with sudo print no sudo: unable to resolve host (F3)" "unable to resolve host"   # docker/entrypoint.sh:50 to 53
  run_cmd -t 60 -- bx eg-setup test -x /usr/games/sl
  expect_rc "sl is installed" 0
  val n -t 60 -- bx eg-setup grep -cE '^(DISABLE_TELEMETRY|DISABLE_ERROR_REPORTING|ENABLE_CLAUDEAI_MCP_SERVERS|CLAUDE_CODE_DISABLE_ARTIFACT)=' /tmp/mt-setup-env
  expect_num "the setup environment holds the four caged settings (W7)" "$n" eq 4
  record_value step12.env_count "$n" "the caged settings in the setup environment"
  rec_row 12 "first run: Setup applied (rc 0), sl installed, $n of 4 caged settings in the setup environment"
}

st_2_11b() {
  local c
  p30_cd eg-setup
  val c -t 60 -- cn eg-setup
  if [ "${DRY:-0}" != 1 ]; then
    [ -n "$c" ] || step_abort "no eg-setup box: run 2.11a first"
    run_cmd -q -t 60 -- box_running eg-setup || step_abort "the eg-setup box is not running: run 2.11a again"
  fi
  if [ "${DRY:-0}" = 1 ] || p30_policy_has_apt; then
    clt -T 300 -- egress deny apt-debian
    expect_contains "deny removes the pack" "pack apt-debian removed"   # bin/cleat:14225
  else
    check_note "apt-debian is no longer in the policy (an earlier attempt removed it): no deny, which would deny its hosts instead"
  fi
  printf '[setup]\nsudo apt-get update\nsudo apt-get install -y cowsay\n' > .cleat
  clt --answer trust-setup=y -t 600 -T 900 -- setup
  expect_match "the setup fails as policy: exit code 100" 'Setup failed with exit code 100( |$)'   # bin/cleat:19239
  expect_not_match "never exit code 1 (sudo refused)" 'Setup failed with exit code 1( |$)'
  expect_not_contains "the [setup] lines run with sudo print no sudo: unable to resolve host (F3)" "unable to resolve host"   # docker/entrypoint.sh:50 to 53
  cl -- egress why cowsay
  first_lines 8
  expect_match "why cowsay: the apt line names deb.debian.org, denied, pack apt-debian" 'apt +deb\.debian\.org.* denied +pack apt-debian'   # bin/cleat:13868
  run_cmd -t 60 -- bx eg-setup tail -n 3 /run/cleat-egress/denials.log
  expect_contains "the denial log names deb.debian.org" "deb.debian.org"
  clt -T 300 -- rm
  expect_contains "cleat rm removes eg-setup" "Removed cleat-eg-setup-"   # bin/cleat:23064
  rec_row 12 "without the pack: Setup failed with exit code 100 (never 1), why cowsay names apt-debian, the denial log names deb.debian.org"
}

st_2_11_repo2() {
  local n c
  p30_cd eg-setup
  on_cleanup "p30_repo2_cleanup"
  if [ "${DRY:-0}" != 1 ]; then
    val c -t 60 -- cn eg-setup
    if [ -n "$c" ]; then
      check_note "an eg-setup box is left (an earlier attempt): cleat rm first, so the run makes a fresh one"
      clt -T 300 -- rm
    fi
  fi
  clt -T 300 -- egress allow apt-debian
  expect_match "allow apt-debian" '^ +pack apt-debian$'
  # docker-buildx-plugin, not docker-ce-cli: the image ships docker-ce-cli (see the header).
  printf '[setup]\nsudo apt-get update\nsudo apt-get install -y docker-buildx-plugin\n' > .cleat
  clt --answer trust-setup=y -t 600 -T 1200 -- run
  expect_match "the second repository fails as policy: exit code 100" 'Setup failed with exit code 100( |$)'
  expect_not_match "never exit code 1" 'Setup failed with exit code 1( |$)'
  expect_not_contains "the [setup] lines run with sudo print no sudo: unable to resolve host (F3)" "unable to resolve host"
  expect_contains "apt met the gateway's 403 for download.docker.com" "403 cleat egress: download.docker.com is not on the allowlist"   # gateway.py:197,230
  record_value step12.repo2_rc "$(LC_ALL=C grep -m 1 -o -E 'Setup (applied|failed with exit code [0-9]+)' "$OUT" 2>/dev/null)" "the setup result"
  run_cmd -t 60 -- bx eg-setup dpkg -s docker-buildx-plugin
  expect_rc "docker-buildx-plugin did not get installed" '!0'
  cl -- egress why docker-buildx-plugin
  first_lines 12
  expect_match "why docker-buildx-plugin: download.docker.com denied, pack apt-image-extras" 'apt +download\.docker\.com.* denied +pack apt-image-extras'
  expect_match "why docker-buildx-plugin: the denials are counted" '[0-9]+ denials this session'   # bin/cleat:13872
  record_value step12.repo2_why "$(LC_ALL=C grep -m 1 'download\.docker\.com' "$OUT" 2>/dev/null)" "the why line"
  val n -t 60 -- bx eg-setup grep -c download.docker.com /run/cleat-egress/denials.log
  expect_num "the denial log names download.docker.com" "${n:-0}" ge 1
  clt -T 300 -- rm
  expect_contains "cleat rm removes eg-setup" "Removed cleat-eg-setup-"
  if [ "${DRY:-0}" = 1 ] || p30_policy_has_apt; then
    clt -T 300 -- egress deny apt-debian
    expect_contains "deny removes the pack" "pack apt-debian removed"
  fi
}
# The cleanup of 2.11-repo2: apt-debian leaves the policy only while the policy lists it.
p30_repo2_cleanup() {
  if [ -d "$P/eg-setup" ] && p30_policy_has_apt; then
    ( cd "$P/eg-setup" && cl -q -- egress deny apt-debian )
  fi
  return 0
}

# ---------------------------------------------------------------------------------------------
# 2.12 Step 13: cleat rm leaves nothing
# ---------------------------------------------------------------------------------------------
st_2_12() {
  local cn vol gw bh scn sgw n c
  cn=$(kv_get eg-check.cn ""); vol=$(kv_get eg-check.vol ""); gw=$(kv_get eg-check.gw ""); bh=$(kv_get eg-check.bh "")
  if [ "${DRY:-0}" = 1 ] && [ -z "$cn" ]; then cn="cleat-eg-check-0000dry0"; vol="cleat-gw-000000000000-sock"; gw="cleat-gw-000000000000"; bh="000000000000"; fi
  [ -n "$cn" ] && [ -n "$gw" ] && [ -n "$vol" ] || step_abort "the names 2.4c keeps are missing: run 2.4c first"
  p30_cd eg-check
  p30_exit eg-check exit-2.12
  say "$cn $gw $vol $bh"
  val c -t 60 -- cn eg-check
  if [ "${DRY:-0}" != 1 ] && [ -z "$c" ]; then
    # Re-entry: an earlier attempt's cleat rm already ran. What it left is still checked below.
    check_note "the eg-check box is already gone (an earlier attempt removed it): the checks of what is left still run"
  else
    clt -T 300 -- rm
    expect_contains "cleat rm removes the box" "Removed $cn."   # bin/cleat:23064
  fi
  dk -- ps -aq --filter "name=^$gw\$"
  expect_count "the gateway is gone" '.' eq 0
  dk -- volume ls -q --filter "name=^$vol\$"
  expect_count "the socket volume is gone" '.' eq 0
  run_cmd -t 30 -- p30_ls_paths "$CFG/egress-rendered/$bh" "$CFG/egress-boxes/$cn" "$CFG/egress-pins/$cn" "$CFG/egress-notices/$cn"
  expect_count "the four host files are gone" 'No such file or directory' eq 4
  val sgw -t 60 -- gw eg-smoke
  run_cmd -t 60 -- egobjs
  expect_not_contains "egobjs: nothing of eg-check's box" "$cn"
  expect_not_contains "egobjs: nothing of eg-check's gateway" "$bh"
  expect_match "egress-pins still holds the machine's global pin" ' global$'
  if [ -n "$sgw" ]; then
    n=$(awk '/^-- gateways:/ { g = 1; next } /^-- / { g = 0 } g && NF { n++ } END { print n + 0 }' "$OUT" 2>/dev/null)
    expect_num "egobjs: one gateway left" "$n" eq 1
    expect_match "egobjs: it is eg-smoke's" "^$sgw "
    n=$(awk '/^-- socket volumes:/ { g = 1; next } /^-- / { g = 0 } g && NF { n++ } END { print n + 0 }' "$OUT" 2>/dev/null)
    expect_num "egobjs: one socket volume left" "$n" eq 1
    expect_contains "egobjs: it is eg-smoke's" "$sgw-sock"
  else
    check_note "eg-smoke's gateway could not be named"
  fi
  rec_row 13 "cleat rm: no gateway, no volume, four host files gone, the global pin kept, only eg-smoke's objects left"
}

# ---------------------------------------------------------------------------------------------
# 2.13 The editor at 80x24
# ---------------------------------------------------------------------------------------------
# p30_ed_run NAME [clt options]: runs the program built since p30_ed_begin on cleat egress.
p30_ed_run() {
  local name="$1"
  shift
  clt --prog -n "$name" -T 300 "$@" -- egress
}

st_2_13a() {
  local f r rt ra ro rl q ms bytes saved=0 bash3=1 sp t11 c11
  p30_cd eg-smoke
  P30_ITEMS=""
  if [ -f "$CFG/config" ] && LC_ALL=C grep -q -E '^[[:space:]]*pack[[:space:]]*=[[:space:]]*github[[:space:]]*$' "$CFG/config"; then saved=1; fi
  # 2.13 starts from the policy 2.11 leaves: example.com, no apt-debian. A 2.11b or 2.11-repo2 that
  # did not finish leaves the pack listed, which would read as 7 hosts here: it is denied the way
  # 2.11b denies it (the pack is listed, so the deny removes it and denies no host).
  if [ "${DRY:-0}" != 1 ] && p30_policy_has_apt; then
    check_note "apt-debian is still in the global policy (2.11b or 2.11-repo2 did not finish): cleat egress deny apt-debian first, as 2.11b does"
    cl -- egress deny apt-debian
    expect_contains "deny removes the pack" "pack apt-debian removed"   # bin/cleat:14225
  fi

  p30_item_begin "1. The frame"
  p30_ed_begin
  xp_snap frame
  p30_ed_quit
  p30_ed_run ed-frame
  xsnap frame; f="$OUT"
  expect_match "the title" 'Cleat egress \(what every box may reach\)' "$f"                     # bin/cleat:16028
  expect_match "the subtitle" "Claude Code's own 5 hosts are always allowed\\." "$f"             # bin/cleat:16031
  rt=$(p30_rowno "$f" "Claude Code's own 5 hosts are always allowed")
  if p30_is_int "$rt"; then expect_eq "no third warning line (a blank row under the subtitle)" "$(p30_rowtext "$f" $((rt + 1)))" ""
  else expect_eq "no third warning line (a blank row under the subtitle)" "${rt:-no subtitle}" "a blank row"; fi
  expect_match "the Mode row" '▸ Mode  ‹ strict ›' "$f"                                          # bin/cleat:16057
  expect_match "Packs with 1-5 of 26 on the same row" 'Packs \(space ticks\) +1-5 of 26$' "$f"  # bin/cleat:16070-16078
  expect_match "Hosts" 'Hosts \(space ticks\)' "$f"
  expect_match "example.com ticked" '\[✔\] example\.com' "$f"
  expect_match "the add row" '\[\+\] Add a host' "$f"
  if [ "$saved" = 1 ]; then
    check_note "github was saved by an earlier attempt: the status line counts more than 6 hosts"
    ro=$(p30_rowno "$f" '^  On save: [0-9]+ hosts allowed')
  else
    ro=$(p30_rowno "$f" '^  On save: 6 hosts allowed')
  fi
  ra=$(p30_rowno "$f" '\[\+\] Add a host')
  if [ "${DRY:-0}" = 1 ]; then expect_eq "exactly one blank row above On save" "" ""
  elif p30_is_int "$ro" && p30_is_int "$ra"; then
    expect_eq "exactly one blank row right above On save (blank)" "$(p30_rowtext "$f" $((ro - 1)))" ""
    expect_ne "exactly one blank row right above On save (the pane's last line above it)" "$(p30_rowtext "$f" $((ro - 2)))" ""
    expect_eq "the four-line pane between the add row and On save" "$((ro - ra))" "7"     # bin/cleat:16127-16133
    expect_match "the key legend under On save" '↑/↓ move  ←/→ change mode  ⏎ save  q cancel' "$f"   # bin/cleat:16372
    expect_eq "the legend is the row under On save" "$(p30_rowno "$f" '↑/↓ move  ←/→ change mode')" "$((ro + 1))"
  else
    check_fail "the On save row and the add row are on screen" "both rows" "On save ${ro:-missing}, add ${ra:-missing}"
  fi
  p30_item_end 1

  p30_item_begin "2. Holding a key"
  p30_ed_begin
  xp_hold "<down>" 90 33
  xp_quiet 1000 hdown
  xp_snap down
  xp_hold "<up>" 90 33
  xp_quiet 1000 hup
  xp_snap up
  p30_ed_quit
  p30_ed_run ed-hold
  for q in hdown hup; do
    sp=$(xquiet "$q"); bytes="${sp%% *}"; ms="${sp##* }"
    record_value "step13.hold.$q" "$bytes bytes, $ms ms until 1 s of quiet" "after the last key ($q)"
    if [ "${DRY:-0}" = 1 ]; then expect_num "nothing kept drawing after the last key ($q)" "$ms" le 2000
    elif p30_is_int "$ms"; then expect_num "nothing kept drawing more than a second after the last key ($q, ms to quiet)" "$ms" le 2000
    else check_fail "nothing kept drawing after the last key ($q)" "a quiet measure" "${sp:-none}"; fi
  done
  xsnap down
  expect_match "held down: the cursor reached the last row" '▸ \[\+\] Add a host'
  xsnap up
  expect_match "held up: the cursor is back on the first row" '▸ Mode'
  p30_item_end 2

  p30_item_begin "3. containers is a normal pack"
  p30_ed_begin
  p30_ed_key "<down>" find
  P30_KN=$((P30_KN + 1)); xp_mark "k$P30_KN"; xp_send "<space>"; xp_wait findp 'Find a pack >' 20
  xp_send "cont"
  xp_wait typed 'Find a pack >(\x1b\[[0-9;]*m)* cont' 10
  p30_ed_key "<enter>" filtered
  p30_ed_key "<space>" ticked
  p30_ed_key "<right>" hosts
  p30_ed_key "<left>" back
  p30_ed_key "<space>" unticked
  p30_ed_quit
  p30_ed_run ed-containers
  xsnap filtered
  expect_match "the filtered list header" 'Packs matching "cont" \(space ticks\)'                 # bin/cleat:16070
  r=$(p30_rowno "$OUT" '\[·\] containers')
  expect_match "containers is listed unticked" '\[·\] containers'
  rl=$(p30_rowtext "$OUT" "$r")
  expect_match "its row: skopeo, crane and oras" 'skopeo, crane and oras' "$OUT"                 # bin/cleat:15116
  if [ "${DRY:-0}" != 1 ]; then
    case "$rl" in *'skopeo, crane and oras'*'! anyone can upload'*) check_pass "the containers row reads its purpose and ! anyone can upload" "$rl" ;;
      *) check_fail "the containers row reads its purpose and ! anyone can upload" "skopeo, crane and oras ... ! anyone can upload" "$rl" ;; esac   # bin/cleat:15143
  fi
  expect_not_match "nothing about the docker cap" '[Dd]ocker cap'
  xsnap ticked
  expect_match "space ticks it" '\[✔\] containers'
  expect_not_match "still nothing about the docker cap" '[Dd]ocker cap'
  xsnap hosts
  expect_match "right shows its hosts, production.cloudfront.docker.com among them" 'production\.cloudfront\.docker\.com'
  xsnap back
  expect_match "left comes back to the list" 'Packs matching "cont"'
  expect_match "the pane: one tick reaches five other GitHub hosts" 'One tick here reaches 5 other GitHub hosts as well\.'   # bin/cleat:16588
  record_value step13.containers_pane "$(LC_ALL=C grep -m 1 'One tick here reaches' "$OUT" 2>/dev/null | sed 's/^ *//')" "the containers pane, for 2.13b's question"
  xsnap unticked
  expect_match "space again unticks it" '\[·\] containers'
  p30_item_end 3

  p30_item_begin "4. Esc leaves the Add a host prompt"
  p30_ed_begin
  p30_ed_last
  xp_snap onadd
  p30_ed_addp
  xp_snap prompt4
  xp_send "abc"
  xp_wait typed4 'Add a host >(\x1b\[[0-9;]*m)* abc' 10
  p30_ed_key "<esc>" back4
  p30_ed_quit
  p30_ed_run ed-esc-prompt
  xsnap onadd
  expect_match "the cursor is on the last row, [+] Add a host" '▸ \[\+\] Add a host'
  xsnap prompt4
  expect_match "the prompt opens" 'Add a host >'                                               # bin/cleat:16951
  expect_match "the pane says Esc goes back" 'HTTPS only, no wildcards\. Esc goes back\.'       # bin/cleat:16949
  xsnap back4
  expect_match "Esc: back on the list" '▸ \[\+\] Add a host'
  expect_not_match "Esc: the prompt is closed" 'Add a host >'
  expect_not_match "nothing was added" 'abc'
  p30_item_end 4

  p30_item_begin "5. Option+Left does nothing in the prompt"
  p30_ed_begin
  p30_ed_last
  p30_ed_addp
  xp_send "abc"
  xp_wait typed5 'Add a host >(\x1b\[[0-9;]*m)* abc' 10
  xp_send "<opt-left>"; xp_sleep 400
  xp_send "<opt-right>"; xp_sleep 400
  xp_send "<left>"; xp_sleep 400
  xp_send "<right>"; xp_sleep 1500
  xp_snap chords5
  xp_send "<bs>"; xp_sleep 800
  xp_snap bs5
  xp_send "d.example"; xp_sleep 800
  p30_ed_key "<enter>" added5
  p30_ed_key "<space>" untick5
  p30_ed_quit
  p30_ed_run ed-chords-prompt
  xsnap chords5
  expect_match "after Option+Left, Option+Right, left and right the prompt reads abc" '^  Add a host > abc$'
  xsnap bs5
  expect_match "Backspace leaves ab" '^  Add a host > ab$'
  xsnap added5
  expect_match "Added abd.example, with the private-address note" 'Added abd\.example\. A name on a private address is always blocked\.'   # bin/cleat:16956
  expect_match "the row [✔] abd.example appears under the cursor" '▸ \[✔\] abd\.example'
  xsnap untick5
  expect_match "space unticks it" '\[·\] abd\.example'
  p30_item_end 5

  p30_item_begin "6. Non-ASCII is shown and refused"
  p30_ed_begin
  p30_ed_last
  p30_ed_addp
  xp_send "bücher.de"
  xp_sleep 1500
  xp_snap paste6
  P30_KN=$((P30_KN + 1)); xp_mark "k$P30_KN"; xp_send "<enter>"; xp_wait "f$P30_KN" '\x1b\[J' 20; xp_sleep 500
  xp_snap enter6
  p30_ed_key "<esc>" back6
  p30_ed_quit
  p30_ed_run ed-paste
  xsnap paste6
  case "$("$MT_BASH" -c 'printf %s "${BASH_VERSINFO[0]}"' 2>/dev/null)" in 3) bash3=1 ;; *) bash3=0 ;; esac
  if [ "$bash3" = 1 ]; then
    expect_match "the paste shows b??cher.de (bash 3.2 reads a byte per key)" '^  Add a host > b\?\?cher\.de$'
  elif p30_utf8; then
    expect_match "the paste shows b?cher.de (bash 4 or later in a UTF-8 locale)" '^  Add a host > b\?cher\.de$'
  else
    check_note "the locale is not UTF-8, so bash 4 or later reads the paste a byte at a time"
    expect_match "the paste shows b??cher.de (bash 4 or later outside a UTF-8 locale)" '^  Add a host > b\?\?cher\.de$'
  fi
  expect_match "the pane refuses non-ASCII" '✘ Only plain ASCII can be typed here\.'             # bin/cleat:16851
  xsnap enter6
  expect_match "Enter refuses it" '✘ Hostname only: no path, query, percent sign or brackets\.'  # bin/cleat:16940
  expect_match "the prompt is empty again" '^  Add a host >$'
  xsnap back6
  expect_not_match "nothing was added" 'cher\.de'
  p30_item_end 6

  p30_item_begin "7. Option+Left on the list"
  p30_ed_begin
  p30_ed_key "<opt-left>" optl7
  p30_ed_quit
  p30_ed_run ed-optleft
  expect_count "the editor closed once, at the Esc after Option+Left" 'Nothing saved\.' eq 1
  xsnap optl7
  expect_match "after Option+Left the editor is still open" 'Cleat egress \(what every box may reach\)'
  expect_match "the cursor is still on the Mode row" '▸ Mode'
  p30_item_end 7

  p30_item_begin "8. The mode ring"
  p30_ed_begin
  p30_ed_key "<right>" open8
  p30_ed_key "<right>" off8
  p30_ed_key "<left>" back8
  p30_ed_key "<left>" strict8
  p30_ed_quit
  p30_ed_run ed-mode
  xsnap open8
  expect_match "right: open" '‹ open ›'
  expect_match "open is per box only, not saved here" '\(per box only, not saved here\)'        # bin/cleat:15172
  expect_match "the status line keeps strict" '^  On save: keeps strict'                       # bin/cleat:16351
  xsnap off8
  expect_match "right again: off" '‹ off ›'
  xsnap back8
  expect_match "left: open" '‹ open ›'
  xsnap strict8
  expect_match "left again: strict" '‹ strict ›'
  p30_item_end 8

  p30_item_begin "9. A resize below 22 rows"
  p30_ed_begin
  xp_resize 20 80
  xp_quiet 1000 rz
  xp_mark k9
  xp_send "<down>"
  xp_wait typed9 'typed, what every box may reach' 20
  xp_wait tprompt 'done saves\. q leaves\.' 10
  xp_sleep 300
  xp_send "q<enter>"
  xp_wait ns9 'Nothing saved' 10
  xp_eof 30
  p30_ed_run ed-resize
  sp=$(xquiet rz); bytes="${sp%% *}"
  expect_eq "nothing redraws on the resize itself (bytes in the second after it)" "$bytes" "0"
  expect_contains "the next key drops to the typed form" "Cleat egress (typed, what every box may reach)"   # bin/cleat:17545
  expect_contains "q in the typed form: Nothing saved" "▸ Nothing saved."                     # bin/cleat:17593
  check_note "the redraw waits for a key after a resize"
  p30_item_end 9

  p30_item_begin "10. Ctrl-C mid-screen"
  p30_ed_begin
  xp_send "<ctrl-c>"
  xp_wait end10 '__MT_TTY_END__ rc=' 30
  xp_eof 15
  p30_ed_run ed-ctrlc --wrap-stty
  record_value step13.ctrlc_rc "$(LC_ALL=C sed -n 's/.*__MT_TTY_END__ rc=\([0-9]*\).*/\1/p' "$OUT" 2>/dev/null | head -n 1)" "cleat's exit code after Ctrl-C"
  ra="$RAW"
  run_cmd -q -t 30 -- p30_stty_part "$OUT"
  expect_match "the terminal echoes again (stty: echo)" '(^|[[:space:]])echo([[:space:]]|$)'
  expect_not_match "echo is not off (no -echo)" '(^|[[:space:]])-echo([[:space:]]|$)'
  expect_match "the terminal is line-buffered again (stty: icanon)" '(^|[[:space:]])icanon([[:space:]]|$)'
  expect_not_match "icanon is not off (no -icanon)" '(^|[[:space:]])-icanon([[:space:]]|$)'
  run_cmd -q -t 30 -- p30_rawseq "$ra"
  expect_contains "the last cursor sequence shows the cursor (ESC [?25h)" "last25=h"
  expect_contains "the alternate screen was entered" "alt_on=1"
  expect_contains "the alternate screen was left" "alt_off=1"
  p30_item_end 10

  p30_item_begin "11. Save"
  if [ "$saved" = 1 ]; then
    check_skip "item 11: save github" "pack = github is already saved by an earlier attempt"
    # The record keeps the verdict of the attempt that saved, so a re-run never turns it into skipped.
    case " $(kv_get c46.editor '') " in
      *" 11:pass "*) P30_ITEMS="$P30_ITEMS 11:pass"; check_note "item 11 passed in the attempt that saved: the record keeps 11:pass" ;;
      *" 11:defect "*) P30_ITEMS="$P30_ITEMS 11:defect"; check_note "item 11 failed in the attempt that saved: the record keeps 11:defect" ;;
      *) P30_ITEMS="$P30_ITEMS 11:skipped" ;;
    esac
  else
    p30_ed_begin
    p30_ed_key "<down>" find11
    P30_KN=$((P30_KN + 1)); xp_mark "k$P30_KN"; xp_send "<space>"; xp_wait findp11 'Find a pack >' 20
    xp_send "github"
    xp_wait typed11 'Find a pack >(\x1b\[[0-9;]*m)* github' 10
    p30_ed_key "<enter>" filtered11
    p30_ed_key "<space>" ticked11
    xp_mark save1
    xp_send "<enter>"
    xp_wait review1 'Save\? \[Y/n\]' 30
    xp_sleep 300
    xp_snap review11
    xp_mark no1
    xp_send "n<enter>"
    xp_wait notsaved 'Not saved\. Your changes are still here\.' 20
    xp_wait fns '\x1b\[J' 10
    xp_sleep 300
    xp_snap notsaved11
    xp_mark save2
    xp_send "<enter>"
    xp_wait review2 'Save\? \[Y/n\]' 30
    xp_sleep 300
    xp_send "y<enter>"
    xp_wait saved11 'Saved to ' 60
    xp_eof 120
    p30_ed_run ed-save --answer eg-save-yn=manual
    t11="$OUT"; c11="$CMDREF"
    xsnap filtered11
    expect_match "the cursor is on the github pack" '▸ \[·\] github '
    xsnap ticked11
    expect_match "github is ticked" '▸ \[✔\] github '
    xsnap review11
    expect_match "the review: the question" 'Save what every box may reach\?'                  # bin/cleat:17369
    expect_match "the review: the mode" 'Mode      strict, only the hosts ticked'               # bin/cleat:17172
    expect_match "the review: Added github" 'Added     github'                                  # bin/cleat:17192
    expect_match "the review: allowed hosts, was 6" 'Allowed   [0-9]+ hosts, HTTPS only\. +Was 6\.'   # bin/cleat:17201
    expect_match "the review: no box can read the file" 'No box can read or change this file\.'  # bin/cleat:17335
    expect_match "the review asks Save? [Y/n]" 'Save\? \[Y/n\]'                                 # bin/cleat:17344
    xsnap notsaved11
    expect_match "n: the list comes back, nothing saved" 'Not saved\. Your changes are still here\.'   # bin/cleat:17017
    p30_ed_save_checks "$t11" "$c11"
    p30_item_end 11
  fi

  p30_item_begin "12. Esc alone"
  p30_ed_begin
  xp_mark k12
  xp_send "<esc>"
  xp_quiet 5000 esc
  xp_wait ns12 'Nothing saved' 5
  xp_eof 15
  p30_ed_run ed-esc
  expect_contains "Esc on the list: Nothing saved" "▸ Nothing saved."   # bin/cleat:17056
  sp=$(xquiet esc); ms="${sp##* }"
  record_value step13.esc_ms "$ms" "milliseconds from Esc to the end (about a second expected)"
  p30_item_end 12

  record_value c46.editor "$P30_ITEMS" "2.13 per item, automated at 24x80 under $MT_BASH"
}
# p30_ed_save_checks TRANSCRIPT CMDREF: item 11's output after the save.
p30_ed_save_checks() {
  local tr="$1" ref="$2" cnt
  expect_contains "saved to the run's config" "✔ Saved to ~/mt-egress-xdg/cleat/config" "$tr"   # bin/cleat:17444
  val cnt -t 180 -- refusing_set
  if [ "${DRY:-0}" != 1 ] && [ -z "$cnt" ]; then
    expect_contains "no box would refuse: Applies to the next box you start." "Applies to the next box you start." "$tr"   # bin/cleat:17521
  else
    OUT="$tr"; CMDREF="$ref"
    note_check
    expect_not_contains "no Applies line after the note" "Applies to the next box you start." "$tr"
    expect_not_contains "no Applies-immediately line after the note" "Applies immediately." "$tr"
  fi
  cl -- egress --list
  expect_match "example.com stays ticked" '^ +example\.com +'
  expect_match "github's hosts are allowed now" '^ +github\.com +'
}

st_2_13b() {
  local r before after res=""
  p30_cd eg-smoke
  if t_is_auto; then step_skip "needs the real keyboard (T1 simulated)"; fi
  before=$(p30_state_sum)
  t_ensure t1
  if ! p30_t1_size 24 80; then
    say_do T1 "Make T1 24 rows by 80 columns (Terminal.app's default). stty size prints 24 80."
  fi
  while :; do
    t_run t1 eg-smoke "cleat egress"
    ask editor-keys T1 "Click T1 (the cleat egress editor) and use the real keys:
1. Hold the down arrow three seconds, then release: the cursor stops at once, nothing keeps scrolling.
2. Hold the up arrow back to the top: no lag per key.
3. Press Option+Left on the list: the editor stays open.
4. Move to [/] Find a pack, press space, type cont, press Enter. The cursor is on containers. The right arrow shows its hosts, the left arrow comes back to the list. Read the pane under the list: one tick reaches five other GitHub hosts as well.
5. Move to [+] Add a host (the last row), press space, type abc, then Option+Left, Option+Right, the left and right arrows: the prompt stays open and still reads abc.
6. Press Esc (back on the list), then Esc again on the list.
Never save in this pass: never Enter on the list." "The cursor stops when you let go. The editor never closes on Option+Left. The prompt keeps abc. The last Esc prints: ▸ Nothing saved." "Did the editor behave as described?"
    r=$?
    [ "$r" = 5 ] || break
  done
  res="keys:$(p30_ans_word "$r")"
  ask_record containers-pane T1 "Think back to the pane of step 4: one tick on containers reaches five other GitHub hosts as well, because ghcr's blob host shares a certificate with them." \
    "Does the containers pane read clearly?"
  while :; do
    t_run t1 eg-smoke "cleat egress"
    ask editor-resize T1 "Click T1 (the editor is open at 24 rows) and drag the window shorter than 22 rows. Nothing redraws yet: a resize only sets a flag. Press the down arrow (never q, Esc, Enter or space here). The typed form appears. Type q and press Enter." \
      "Cleat egress (typed, what every box may reach), then after q: ▸ Nothing saved." "Did it drop to the typed form and leave with Nothing saved?"
    r=$?
    p30_t1_size 24 80 || say_do T1 "Drag T1 back to 24 rows (stty size prints 24 80)."
    [ "$r" = 5 ] || break
  done
  res="$res resize:$(p30_ans_word "$r")"
  while :; do
    t_run t1 eg-smoke "cleat egress"
    ask editor-ctrlc T1 "Click T1 and press Ctrl-C while the editor is on screen. Then type echo ok and press Enter." \
      "Back at the prompt the typed characters show, ok prints and the cursor is visible." "Is T1's terminal intact?"
    r=$?
    [ "$r" = 5 ] || break
  done
  res="$res ctrlc:$(p30_ans_word "$r")"
  record_value c46.editor_keys "$res" "2.13 with real keys in Terminal.app"
  after=$(p30_state_sum)
  expect_eq "the real-key passes saved nothing (config and kit selections unchanged)" "$after" "$before"
}

# ---------------------------------------------------------------------------------------------
# 2.14 The pickers and cleat config
# ---------------------------------------------------------------------------------------------
st_2_14a() {
  local before after s0 s1 nosess=0 onesess="" i tr
  p30_cd eg-smoke
  before=$(p30_state_sum)
  cl -- session
  if [ "${DRY:-0}" != 1 ] && LC_ALL=C grep -q 'No sessions for this project yet\.' "$OUT"; then nosess=1; fi   # bin/cleat:33096
  if [ "${DRY:-0}" != 1 ] && LC_ALL=C grep -q '1 session\. Act on it' "$OUT"; then onesess=1; fi            # bin/cleat:27097
  run_cmd -q -t 30 -- p30_sessions_ids "$OUT"
  s0=$(cat "$OUT" 2>/dev/null)

  hdr "cleat config: the chords"
  p30_pk_begin 'Cleat config'
  p30_pk_chords cfg
  xp_send "<esc>"; xp_wait c1 'Cancelled\.' 15; xp_sleep 300; xp_snap cfg-esc; xp_eof 30
  clt --prog -n config-keys -T 300 -- config
  p30_pk_check "cleat config" cfg
  xsnap cfg-esc
  expect_match "cleat config: Esc prints ▸ Cancelled." '▸ Cancelled\.'   # bin/cleat:33914

  hdr "cleat config: the iTerm2 chords"
  p30_pk_begin 'Cleat config'
  p30_pk_key "<opt-left-iterm>" cfgi-optli
  p30_pk_key "<opt-right-iterm>" cfgi-optri
  xp_send "<esc>"; xp_wait c2 'Cancelled\.' 15; xp_eof 30
  clt --prog -n config-iterm -T 300 -- config
  xsnap cfgi-optli
  expect_not_contains "cleat config: still open after ESC [1;3D" "Cancelled."
  xsnap cfgi-optri
  expect_not_contains "cleat config: still open after ESC [1;3C" "Cancelled."
  expect_match "cleat config: still drawn" '▸'

  hdr "cleat kit"
  p30_pk_begin 'Cleat Kits'
  p30_pk_chords kit
  xp_send "<esc>"; xp_wait c3 'Cancelled\.' 15; xp_eof 30
  clt --prog -n kits -T 300 -- kit
  tr="$OUT"
  p30_pk_check "cleat kit" kit
  expect_contains "cleat kit: Esc prints ▸ Cancelled." "▸ Cancelled." "$tr"   # bin/cleat:35626

  hdr "cleat kit: the models screen"
  p30_pk_begin 'Cleat Kits'
  P30_KN=$((P30_KN + 1)); xp_mark "k$P30_KN"; xp_send "<enter>"
  xp_wait models 'agent models' 20
  xp_wait dm '\x1b\[[0-9]+A' 10
  xp_sleep 300
  xp_snap mdl-open
  p30_pk_chords mdl
  xp_send "<esc>"; xp_wait c4 'Cancelled\.' 15; xp_eof 30
  clt --prog -n kit-models -T 300 -- kit
  tr="$OUT"
  xsnap mdl-open
  expect_match "Enter at once opens the models screen" 'Kit .* · agent models'   # bin/cleat:35523
  p30_pk_check "kit models" mdl
  expect_contains "kit models: Esc prints ▸ Cancelled." "▸ Cancelled." "$tr"   # bin/cleat:35568
  after=$(p30_state_sum)
  expect_eq "kit models wrote nothing (config and kit selections unchanged)" "$after" "$before"

  if [ "$nosess" = 1 ]; then
    check_skip "cleat session and its action menu" "no past conversation in eg-smoke (1.2 makes one with a real Claude Code session)"
  else
    hdr "cleat session"
    p30_pk_begin 'rename or delete'
    p30_pk_chords ses
    xp_send "<esc>"; xp_wait c5 'Cancelled\.' 15; xp_eof 30
    clt --prog -n sessions -T 300 -- session
    tr="$OUT"
    p30_pk_check "cleat session" ses "" "$onesess"
    expect_contains "cleat session: Esc prints ▸ Cancelled." "▸ Cancelled." "$tr"   # bin/cleat:27055

    hdr "cleat session: the action menu"
    p30_pk_begin 'rename or delete'
    P30_KN=$((P30_KN + 1)); xp_mark "k$P30_KN"; xp_send "<enter>"
    xp_wait menu 'choose  q back' 20
    xp_wait dmn '\x1b\[[0-9]+A' 10
    xp_sleep 300
    xp_snap act-open
    p30_pk_chords act
    P30_KN=$((P30_KN + 1)); xp_mark "k$P30_KN"; xp_send "<esc>"
    xp_wait backlist 'rename or delete' 20
    xp_wait dbl '\x1b\[[0-9]+A' 10
    xp_sleep 300
    xp_snap act-back
    xp_send "<esc>"; xp_wait c6 'Cancelled\.' 15; xp_eof 30
    clt --prog -n session-actions -T 300 -- session
    tr="$OUT"
    xsnap act-open
    expect_match "Enter opens the action menu" 'Rename'
    expect_match "the menu's legend" '↑/↓ move  ⏎ choose  q back'   # bin/cleat:26804
    p30_pk_check "session actions" act
    xsnap act-down
    expect_match "down moved to Delete (never chosen)" '▸ Delete'
    xsnap act-back
    expect_match "Esc backs out to the list" '⏎ rename or delete  q close'   # bin/cleat:26385
    expect_contains "the second Esc closes the list: ▸ Cancelled." "▸ Cancelled." "$tr"
    cl -- session
    run_cmd -q -t 30 -- p30_sessions_ids "$OUT"
    s1=$(cat "$OUT" 2>/dev/null)
    expect_eq "no session was renamed or deleted" "$s1" "$s0"
  fi

  hdr "cleat config held to the window at 80 columns (W12)"
  p30_pk_begin 'Cleat config'
  for i in 1 2 3 4 5 6 7 8 9 10; do p30_pk_key "<down>" "w12d-$i"; done
  for i in 1 2 3 4 5; do p30_pk_key "<up>" "w12u-$i"; done
  xp_send "<esc>"; xp_wait c7 'Cancelled\.' 15; xp_sleep 300; xp_snap w12-esc; xp_eof 30
  clt --prog -n config-w12 -T 300 -- config
  # shellcheck disable=SC2046
  p30_w12_check "W12 at 80" 80 '\[·\] unsafe-rm  Disarm the rm delete-safety prompt \(global/CLI only\)$' $(p30_w12_snaps w12d 10) $(p30_w12_snaps w12u 5)   # bin/cleat:33261
  xsnap w12-esc
  p30_w12_esc_check "W12 at 80"
  after=$(p30_state_sum)
  expect_eq "nothing was acted on in any picker (config and kit selections unchanged)" "$after" "$before"

  hdr "an [egress] section that does not resolve, at 80 and 50 columns"
  safe_rm "$SCRATCH/mt-w12"
  mkdir -p "$SCRATCH/mt-w12/cleat" && printf '[egress]\nallow = a.example\n' > "$SCRATCH/mt-w12/cleat/config"
  on_cleanup "safe_rm $(printf '%q' "$SCRATCH/mt-w12")"
  p30_pk_begin 'Cleat config'
  for i in 1 2 3 4 5 6 7 8 9; do p30_pk_key "<down>" "invd-$i"; done
  for i in 1 2 3 4 5 6 7 8 9; do p30_pk_key "<up>" "invu-$i"; done
  xp_send "<esc>"; xp_wait c8 'Cancelled\.' 15; xp_sleep 300; xp_snap inv-esc; xp_eof 30
  clt --prog -n config-invalid-80 -T 300 --xdg "$SCRATCH/mt-w12" -- config
  # shellcheck disable=SC2046
  p30_w12_check "invalid [egress] at 80" 80 '\[·\] Egress  invalid  \[egress\] does not resolve\.  cleat egress status$' $(p30_w12_snaps invd 9) $(p30_w12_snaps invu 9)   # bin/cleat:17758,33648
  xsnap invd-9
  expect_match "the cursor reached the Egress row" '▸ \[·\] Egress'
  p30_pk_begin 'Cleat config'
  for i in 1 2 3 4 5 6 7 8 9; do p30_pk_key "<down>" "n50d-$i"; done
  for i in 1 2 3 4 5 6 7 8 9; do p30_pk_key "<up>" "n50u-$i"; done
  xp_send "<esc>"; xp_wait c9 'Cancelled\.' 15; xp_eof 30
  clt --prog -n config-invalid-50 -T 300 --cols 50 --xdg "$SCRATCH/mt-w12" -- config
  # shellcheck disable=SC2046
  p30_w12_check "invalid [egress] at 50" 50 '\[·\] (Egress|unsafe-rm) .*…$' $(p30_w12_snaps n50d 9) $(p30_w12_snaps n50u 9)
  xsnap n50d-3
  expect_match "at 50 the unsafe-rm row ends in …" '\[·\] unsafe-rm .*…$'
  xsnap n50d-1
  expect_match "at 50 the Egress row ends in …" '\[·\] Egress .*…$'
  safe_rm "$SCRATCH/mt-w12"
}
# p30_w12_esc_check LABEL: after Esc the footer row is unchanged and ▸ Cancelled. is below it.
p30_w12_esc_check() {
  local rf rc
  rf=$(p30_rowno "$OUT" '↑/↓ move  space toggle  ←/→ change  ⏎ save  q cancel$')
  rc=$(p30_rowno "$OUT" '▸ Cancelled\.')
  if [ "${DRY:-0}" = 1 ]; then expect_eq "$1: after Esc the footer stays and Cancelled is below it" "" ""; return 0; fi
  if p30_is_int "$rf" && p30_is_int "$rc" && [ "$rc" -gt "$rf" ]; then
    check_pass "$1: after Esc the footer stays whole and ▸ Cancelled. is below it" "footer row $rf, Cancelled row $rc"
  else
    check_fail "$1: after Esc the footer stays whole and ▸ Cancelled. is below it" "the footer, then ▸ Cancelled. under it" "footer row ${rf:-missing}, Cancelled row ${rc:-missing}"
  fi
}

st_2_14b() {
  local r nosess=0 before after s0="" s1 res=""
  p30_cd eg-smoke
  if t_is_auto; then step_skip "needs the real keyboard (T1 simulated)"; fi
  before=$(p30_state_sum)
  cl -- session
  if [ "${DRY:-0}" != 1 ] && LC_ALL=C grep -q 'No sessions for this project yet\.' "$OUT"; then nosess=1; fi   # bin/cleat:33096
  run_cmd -q -t 30 -- p30_sessions_ids "$OUT"
  s0=$(cat "$OUT" 2>/dev/null)
  t_ensure t1
  p30_t1_size 24 80 || say_do T1 "Make T1 24 rows by 80 columns (Terminal.app's default). stty size prints 24 80."
  while :; do
    t_run t1 eg-smoke "cleat config"
    ask config-keys T1 "Click T1 (cleat config) and press Option+Left, then Option+Right, then Page Up (fn+Shift+↑ in Terminal.app, which scrolls its own window without Shift), then ↓ once, then Esc. Never space, never Enter." \
      "The chords do nothing, the down arrow moves one row, Esc prints ▸ Cancelled. Nothing was acted on." "Did cleat config behave as described?"
    r=$?; [ "$r" = 5 ] || break
  done
  res="config-keys:$(p30_ans_word "$r")"
  while :; do
    t_run t1 eg-smoke "cleat config"
    ask config-w12 T1 "Click T1 (cleat config) and press the down arrow ten times, then the up arrow five times, then Esc." \
      "One Capabilities header throughout. The frame never moves down the window. The footer ↑/↓ move  space toggle  ←/→ change  ⏎ save  q cancel and the row [·] unsafe-rm  Disarm the rm delete-safety prompt (global/CLI only) stay whole. Esc leaves the footer where it was and prints ▸ Cancelled. below it." \
      "Did cleat config stay held to the window?"
    r=$?; [ "$r" = 5 ] || break
  done
  res="$res config-w12:$(p30_ans_word "$r")"
  while :; do
    t_run t1 eg-smoke "cleat kit"
    ask pickers-kit T1 "Click T1 (cleat kit) and press Option+Left, Option+Right, Page Up, the down arrow once, then Esc." \
      "The chords do nothing, the down arrow moves one row, Esc prints ▸ Cancelled." "Did the kit picker behave as described?"
    r=$?; [ "$r" = 5 ] || break
  done
  res="$res kits:$(p30_ans_word "$r")"
  while :; do
    t_run t1 eg-smoke "cleat kit"
    ask pickers-models T1 "Click T1 (cleat kit) and press Enter at once, with the cursor still on plan-big-execute-small (never on the last row, which turns kits off). On the models screen (Kit ... · agent models) press Option+Left, Option+Right, Page Up, the down arrow once, then Esc. Never Enter on the models screen: it enables the kit." \
      "The chords do nothing, the down arrow moves to scout, Esc prints ▸ Cancelled. and writes nothing." "Did the models screen behave as described?"
    r=$?; [ "$r" = 5 ] || break
  done
  res="$res kit-models:$(p30_ans_word "$r")"
  if [ "$nosess" = 1 ]; then
    check_skip "cleat session with real keys" "no past conversation in eg-smoke"
  else
    while :; do
      t_run t1 eg-smoke "cleat session"
      ask pickers-session T1 "Click T1 (cleat session) and press Option+Left, Option+Right, Page Up, the down arrow once. Then press Enter on a conversation: its action menu opens. There press Option+Left, Option+Right, Page Up, the down arrow once, then Esc (back to the list), then Esc again. Never Enter in the action menu: it renames or deletes." \
        "The chords do nothing anywhere, the down arrow moves one row, the first Esc backs out to the list, the second prints ▸ Cancelled. Nothing renamed, nothing deleted." "Did the session picker and its menu behave as described?"
      r=$?; [ "$r" = 5 ] || break
    done
    res="$res sessions:$(p30_ans_word "$r")"
  fi
  safe_rm "$SCRATCH/mt-w12"
  mkdir -p "$SCRATCH/mt-w12/cleat" && printf '[egress]\nallow = a.example\n' > "$SCRATCH/mt-w12/cleat/config"
  on_cleanup "safe_rm $(printf '%q' "$SCRATCH/mt-w12")"
  while :; do
    if p30_t1_size 24 50; then
      say "The script made T1 50 columns wide."
    else
      say_do T1 "Drag T1 to about 50 columns wide (stty size prints 24 50 or close)."
    fi
    t_run t1 eg-smoke "XDG_CONFIG_HOME=\"$SCRATCH/mt-w12\" CLEAT_NO_IDLE_SWEEP=1 \"$MT_BASH\" \"\$WT/bin/cleat\" config"
    ask narrow T1 "Click T1 (cleat config on a throwaway config, about 50 columns) and press the down arrow to the Egress row, back up, then Esc." \
      "Every long row of the frame ends in … instead of wrapping, the footer too. The frame never moves. The line above the frame starting The last row writes ./.cleat may wrap: it is drawn once." "Did the narrow frame read as described?"
    r=$?
    p30_t1_size 24 80 || say_do T1 "Widen T1 back to 80 columns."
    [ "$r" = 5 ] || break
  done
  res="$res narrow:$(p30_ans_word "$r")"
  safe_rm "$SCRATCH/mt-w12"
  ask_record iterm T1 "If you use iTerm2 as well: open a window there, type /bin/bash, then on its own line source ~/mt-eg-env.sh, then cd ~/mt-egress/eg-smoke and cleat config. Press Option+Left (iTerm2 sends ESC [1;3D), then Esc." \
    "Did Option+Left do nothing in iTerm2? (Answer y as well when you do not use iTerm2.)"
  record_value c46.pickers_keys "$res" "2.14 with real keys in Terminal.app"
  after=$(p30_state_sum)
  expect_eq "the real-key passes acted on nothing (config and kit selections unchanged)" "$after" "$before"
  if [ "$nosess" != 1 ]; then
    cl -- session
    run_cmd -q -t 30 -- p30_sessions_ids "$OUT"
    s1=$(cat "$OUT" 2>/dev/null)
    expect_eq "no session was renamed or deleted" "$s1" "$s0"
  fi
}

st_2_14_brew() {
  local bb before after
  p30_cd eg-smoke
  val bb -t 60 -- p30_brew_bash
  if [ "${DRY:-0}" != 1 ] && { [ "$RC" != 0 ] || [ -z "$bb" ]; }; then
    step_skip "no Homebrew bash on this Mac (brew --prefix or its bin/bash is missing)"
  fi
  if [ "${DRY:-0}" != 1 ]; then
    record_value step14.brew_bash "$("$bb" -c 'printf %s "$BASH_VERSION"' 2>/dev/null)" "the Homebrew bash version"
  fi
  before=$(p30_state_sum)
  hdr "2.13 items 4 to 7 under Homebrew bash"
  p30_ed_begin
  p30_ed_last
  p30_ed_addp
  xp_send "abc"
  xp_wait typedb 'Add a host >(\x1b\[[0-9;]*m)* abc' 10
  p30_ed_key "<esc>" b-back4
  p30_ed_addp
  xp_send "abc"
  xp_wait typedb2 'Add a host >(\x1b\[[0-9;]*m)* abc' 10
  xp_send "<opt-left>"; xp_sleep 400
  xp_send "<opt-right>"; xp_sleep 400
  xp_send "<left>"; xp_sleep 400
  xp_send "<right>"; xp_sleep 1500
  xp_snap b-chords
  xp_send "<bs><bs><bs>"; xp_sleep 800
  xp_send "bücher.de"; xp_sleep 1500
  xp_snap b-paste
  p30_ed_key "<esc>" b-back6
  p30_ed_key "<opt-left>" b-optl
  p30_ed_quit
  p30_ed_run brew-editor --bash "$bb"
  xsnap b-back4
  expect_not_match "Homebrew bash: Esc left the prompt, nothing added" 'abc'
  xsnap b-chords
  expect_match "Homebrew bash: the prompt still reads abc after the chords" '^  Add a host > abc$'
  xsnap b-paste
  if p30_utf8; then
    expect_match "Homebrew bash: the paste shows b?cher.de (one ? for the character)" '^  Add a host > b\?cher\.de$'
  else
    check_note "the locale is not UTF-8, so Homebrew bash reads the paste a byte at a time"
    expect_match "Homebrew bash: the paste shows b??cher.de (a byte at a time outside UTF-8)" '^  Add a host > b\?\?cher\.de$'
  fi
  expect_match "Homebrew bash: non-ASCII refused" '✘ Only plain ASCII can be typed here\.'
  xsnap b-optl
  expect_match "Homebrew bash: Option+Left on the list leaves it open" 'Cleat egress \(what every box may reach\)'
  hdr "cleat config under Homebrew bash"
  p30_pk_begin 'Cleat config'
  p30_pk_chords bcfg iterm
  xp_send "<esc>"; xp_wait cb 'Cancelled\.' 15; xp_eof 30
  clt --prog -n brew-config -T 300 --bash "$bb" -- config
  p30_pk_check "cleat config (Homebrew bash)" bcfg iterm
  after=$(p30_state_sum)
  expect_eq "nothing was acted on" "$after" "$before"
}

# ---------------------------------------------------------------------------------------------
# The registry, in scenario order
# ---------------------------------------------------------------------------------------------
reg 2.0        2 auto   gate  st_2_0        "Sitting 2 starts: egcheck, egimg"
reg 2.1        2 expect gate  st_2_1        "Step 1: refusal on an engine not validated"
reg 2.2        2 auto   gate  st_2_2        "Step 2: the validated leg"
reg 2.3        2 auto   gate  st_2_3        "Step 3: the host.docker.internal probe (records)"
reg 2.4a       2 expect gate  st_2_4a       "Step 4: the one-host policy listed"
reg 2.4b       2 mixed  gate  st_2_4b       "Step 4: the launch"
reg 2.4c       2 auto   gate  st_2_4c       "Step 4: isolation and the three normalization strings"
reg 2.5        2 auto   gate  st_2_5        "Step 5: an allowed host"
reg 2.6        2 auto   gate  st_2_6        "Step 6: a denied host and its body"
reg 2.7a       2 auto   gate  st_2_7a       "Step 7: socket permission, positive half"
reg 2.7b       2 expect gate  st_2_7b       "Step 7: socket permission, negative half"
reg 2.7c       2 expect gate  st_2_7c       "Step 7: heal"
reg 2.8        2 auto   gate  st_2_8        "Step 8: no route, no resolver, no raw socket"
reg 2.9a       2 mixed  gate  st_2_9a       "Step 9: stop"
reg 2.9b       2 mixed  gate  st_2_9b       "Step 9: resume, relay latency"
reg 2.10a      2 mixed  gate  st_2_10a      "Step 10: kill the gateway"
reg 2.10b      2 mixed  gate  st_2_10b      "Step 10: heal"
reg 2.10c      2 mixed  gate  st_2_10c      "Step 10: a restart Docker makes"
reg 2.11a      2 expect gate  st_2_11a      "Step 12: [setup] with the pack"
reg 2.11b      2 expect gate  st_2_11b      "Step 12: [setup] without the pack"
reg 2.11-repo2 2 expect extra st_2_11_repo2 "Step 12: the second repository"
reg 2.12       2 mixed  gate  st_2_12       "Step 13: cleat rm leaves nothing"
reg 2.13a      2 expect gate  st_2_13a      "The editor at 80x24, automated"
reg 2.13b      2 human  gate  st_2_13b      "The editor at 80x24, real keys"
reg 2.14a      2 expect gate  st_2_14a      "Pickers and cleat config at 80 and 50 columns, automated"
reg 2.14b      2 human  gate  st_2_14b      "Pickers and cleat config, real keys"
reg 2.14-brew  2 expect extra st_2_14_brew  "The same under Homebrew bash"
