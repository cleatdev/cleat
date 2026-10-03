# egress-release.d/32-full-c.sh: sitting 2: 2.24 to 2.31, with 2.14-acct right after 2.25d.
#
# A part of egress-release.sh. Sourced, never run. It holds only function definitions, reg calls
# and comments: nothing else runs at source time. One function per step, named st_ plus the id
# with . and - turned into _, registered in scenario order (at the end of this file) with
#   reg ID SITTING KIND CLASS FUNC "TITLE"
# The steps, their checks and their re-entry rules are DESIGN.md section 6.2. A helper this part
# needs that the library lacks is written here, prefixed with the part's number (p32_).
#
# Every expected string below was read in the candidate first (bin/cleat, docker/ or
# docker/gateway/ at ac6ee85) and carries its source line. Where the code and the scenario or the
# design differ, the code wins and the comment says so:
#   1. T1 gets UPX and cleatup() (and cleat154()) on the same typed line as the launch:
#      cd eg-old && UPX=...; cleatup() {...}; echo "MT-UPX=[$UPX]"; [ -n "$UPX" ] && cleatup
#      The [ -n "$UPX" ] guard makes the scenario's trap (an empty UPX falls back to the real
#      config) impossible. The echo is checked in the capture. One line, not three commands:
#      the typed answerer of a command keeps reading T1 for 20 s, so it would answer the next
#      command's recreate question with the catalogue's n (2.24i needs a yes).
#   2. 2.24b's refusing-boxes note is printed under the upgrade config: note_check runs with
#      EGX="$UPX" for that one call, because refusing_set reads $EGX.
#   3. 2.24h checks F1 (ac6ee85): the pull spinner's line is plain text (bin/cleat:11528). Before
#      the fix spin printed ${DIM} as the text \033[2m (spin prints with printf %s, bin/cleat:567),
#      as part 20 met at 1.2b. A colour code shown as text is a FAIL tagged (F1). The literal
#      codes are then taken out for the scenario's line, so F1 fails once.
#   4. cleat login runs claude auth login inside the box (bin/cleat:23324), which box_claude_live
#      reads as a live Claude, so t_wait_launch cannot wait for a login. 2.25b and 2.25d wait for
#      the account's own credential file to be written (the harvest after the login,
#      bin/cleat:23334) with no Claude left in the box.
#   5. 2.27b's rule answers a recreate question with n<enter> (the design's bare n would leave the
#      line unanswered).
#   6. 2.14-acct runs its automated picker pass whenever a named account exists, also with T1
#      simulated (2.25b makes lab-a before its sign-in). Only the real-key pass needs T1.
#   7. 2.24-spec4 compares the gateway, volume and host file NAMES before and after, not egobjs's
#      raw text, whose Status column and ls times move by themselves.
#   8. 2.27c finds the Egress row by a first pass that only moves and presses Esc, then acts on
#      exactly that row (a space on the wrong row would tick a capability in the run's config).
#   9. 2.26 never removes an image from the other engine itself (the fence allows no rmi there):
#      it prints the command and asks.
#  10. 2.31 waits up to 100 s for healthy (the scenario's 40 s, then 60 more under emulation).
#  11. The accounts screens and a login's output show the login and its organisation. Their checks
#      never quote the text (p32_quiet_match), so nothing of either reaches the report.
#  12. Additions the scenario implies: 2.27a starts only from the strict mode (two right arrows reach
#      off only from there), 2.28a and 2.28c count the running daily boxes (the sweep must never
#      stop one), 2.25a puts the candidate image back when 2.24-clean left the swap mark.
#  13. 2.30 resumes with cleat resume --cap unsafe-rm. A --cap lasts one invocation and caps are in
#      the fingerprint, so the scenario's bare cleat resume meets a recreate question. Its overlay
#      refresh then drops the hook (bin/cleat:22683). The count reads 0 whatever the box did.
#  14. G2's log rows are the x denied and the x refused rows (a host turned away either way). Leg d
#      reads only the lines of the log that 2.25c's reading did not hold, never a row count: the
#      copy is read again from the gateway and its generation can move between the legs.
#  15. 2.28d starts the sweep's launch when the create marker of eg-sweep3 appears (a host file),
#      the earliest a script can see the window. The record says when the box was created against it.
#  16. 2.26 asks for the other engine to be started when it does not answer, so a stopped OrbStack
#      or Colima is never read as DOCKER_CONTEXT not being honoured.
#  17. 2.27c checks F4 (ac6ee85): one Enter on the Egress row prints exactly one "Saved to" line,
#      the config editor's (bin/cleat:33734), never a second from the handoff
#      (bin/cleat:17816). Its path is ${config_file/#${HOME}/~}: bash 3.2 prints the ~ form, bash
#      5.2 tilde-expands the replacement and prints the absolute path. With MT_BASH at bash 3.2
#      (the Mac) the ~ form is required, under a later bash either form passes.
#
# kv this part writes (DESIGN.md section 7.1): image.swapped (2.24-pre, 2.24-back, 2.24d to
# 2.24f, 2.24-clean), eg-old.cn, acct.sid.c, acct.sid.d (private), image.claude.after (2.29),
# amd64.* (2.31), rec.g2a, rec.g2b (2.25c, 2.25d), rec.upgrade.* (2.24: r63, question, w9, e, h,
# j), c46.upgrade_question, c46.accounts_keys, step27c.saved (F4), plus the part's own marks under p32.*
# (p32.g2.c.rows, p32.g2.d.rows, p32.old.gw, p32.old.vol, p32.sweep.*, p32.boxid.*). Files in the
# run's scratch dir: p32-g2-c.full and p32-g2-d.full (each leg's whole log), p32-g2-c.log and
# p32-g2-d.log (each leg's own lines), p32-daily-before.txt (2.28a), p32-git-before-2.24h.txt.
#
# Helpers (p32_): p32_dry, p32_is_int, p32_cd, p32_sleep, p32_tilde, p32_ere, p32_count, p32_version,
# the image pieces (p32_spec, p32_img_id, p32_img_tree, p32_tree_ok, p32_img_state, p32_spec6_ok,
# p32_image_v154, p32_image_candidate), the eg-old pieces (p32_old_box, p32_old_stop,
# p32_old_state_check, p32_upx_has_egress, p32_upx_drop, p32_settings_back, p32_one_question),
# the T1 pieces (p32_bash_word, p32_upx_line, p32_cleatup_line, p32_c154_line, p32_old_cmd,
# p32_t1_idle, p32_launch, p32_exit, p32_end_region, p32_ask, p32_ask_record, p32_ask_lines,
# p32_word), the account pieces (p32_cred_sum, p32_login_done, p32_login, p32_need_login, p32_pin,
# p32_acct_count, p32_acct_state, p32_claude_pids, p32_is_claude_cmd, p32_reopened), the G2 pieces
# (p32_log_hosts, p32_log_rows, p32_lines_not_in, p32_g2_log, p32_newest_jsonl, p32_debug_count,
# p32_debug_lines, p32_debug_read), the picker and editor program pieces (p32_pk_*, p32_ed_*,
# p32_rowno, p32_nrows, p32_cursor_row, p32_w12_check), then pipelines run only through run_cmd,
# val or wait_for (p32_write_v154, p32_write_nogw, p32_egobjs_names, p32_names_count,
# p32_row_items, p32_strip_literal_esc, p32_ctx, p32_ctx_up, p32_ctx_candidates, p32_proc_status,
# p32_rendered_digest, p32_hook_count, p32_box_exists, p32_create_seen, p32_shim_ok,
# p32_eg_entries).

# ---------------------------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------------------------

p32_dry() { [ "${DRY:-0}" = 1 ]; }
p32_is_int() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac; return 0; }

# p32_cd PROJ [make]: into $P/PROJ. make: mkdir -p first. A dry run makes it inside its own home.
p32_cd() {
  local d="$P/$1"
  if [ "${2:-}" = make ] || p32_dry; then mkdir -p "$d" || fatal "cannot create $d"; fi
  [ -d "$d" ] || step_abort "no project $d: run the step that makes it first"
  cd "$d" || step_abort "cannot cd to $d"
}
# p32_sleep SECS [WHY]: a pause a dry run skips.
p32_sleep() {
  [ -n "${2:-}" ] && say "Waiting $1 s: $2"
  p32_dry && return 0
  sleep "$1"
}
# p32_tilde PATH: PATH with $HOME written as ~, the way cleat prints it.
p32_tilde() {
  case "$1" in "$HOME"/*) printf '~/%s' "${1#"$HOME"/}" ;; *) printf '%s' "$1" ;; esac
}
# p32_ere TEXT: TEXT with every ERE metacharacter escaped.
p32_ere() { printf '%s' "$1" | sed -e 's/[][\.^$*+?(){}|]/\\&/g'; }
# p32_count ERE FILE: lines of FILE matching ERE (0 when FILE is missing).
p32_count() { LC_ALL=C grep -E -e "$1" "$2" 2>/dev/null | awk 'END { print NR + 0 }'; }
# p32_version: the candidate's VERSION (1.5.4 at ac6ee85: the image refresh target).
p32_version() { sed -n 's/^VERSION="\(.*\)"$/\1/p' "$MT_WT/bin/cleat" | head -n 1; }
p32_word() { case "$1" in 0) printf pass ;; 1) printf defect ;; *) printf skipped ;; esac; }
# p32_needed: the Needed: line of _egress_engine_refusal (bin/cleat:10967), built the code's way
# from the candidate's _EGRESS_VALIDATED_ENGINES with the words of bin/cleat:10949-10952.
p32_needed() {
  local k need="" w
  for k in $(sed -n 's/^_EGRESS_VALIDATED_ENGINES="\(.*\)"$/\1/p' "$MT_WT/bin/cleat" | head -n 1); do
    case "$k" in
      desktop-macos) w="Docker Desktop on macOS" ;;
      desktop-windows) w="Docker Desktop on Windows, through WSL2 integration" ;;
      engine-linux) w="Docker Engine on Linux (rootful)" ;;
      desktop-linux) w="Docker Desktop on Linux" ;;
      *) w="an engine cleat could not identify" ;;
    esac
    need="${need:+$need, or }$w"
  done
  printf 'Needed:  %s' "$need"
}

# ---- pipelines, run only through run_cmd or val ----
p32_spec() { docker image inspect "$1" --format '{{index .Config.Labels "sh.cleat.image-spec"}}'; }
p32_img_id() { docker image inspect "$1" --format '{{.Id}}'; }
# p32_img_tree REF: egimg's two lines for any image reference.
p32_img_tree() {
  if docker run --rm --entrypoint cat "$1" /usr/local/bin/cleat-egress-shim 2>/dev/null | cmp -s - "$MT_WT/docker/cleat-egress-shim"; then echo "relay: this tree's"; else echo "relay: NOT this tree's"; fi
  if docker run --rm --entrypoint cat "$1" /entrypoint.sh 2>/dev/null | cmp -s - "$MT_WT/docker/entrypoint.sh"; then echo "entrypoint: this tree's"; else echo "entrypoint: NOT this tree's"; fi
  return 0
}
p32_write_v154() { git -C "$MT_WT" show v1.5.4:bin/cleat > "$1"; }
p32_write_nogw() {
  sed 's|^_GATEWAY_IMAGE=".*"$|_GATEWAY_IMAGE="ghcr.io/cleatdev/cleat-gw@sha256:0000000000000000000000000000000000000000000000000000000000000000"|' "$MT_WT/bin/cleat" > "$CLEAT_NOGW"
}
# p32_egobjs_names: egobjs as names only (no Status column, no ls times), sorted.
p32_egobjs_names() {
  local d
  echo "-- gateways:"; docker ps -a --filter label=sh.cleat.role=gateway --format '{{.Names}}' | LC_ALL=C sort
  echo "-- socket volumes:"; docker volume ls -q --filter label=sh.cleat.role=egress-sock | LC_ALL=C sort
  echo "-- host files:"
  for d in egress-rendered egress-boxes egress-pins egress-notices; do
    if [ -d "$CFG/$d" ]; then ( cd "$CFG/$d" && ls -A ) | sed "s|^|$d/|"; fi
  done
  return 0
}
p32_names_count() { docker ps -a --format '{{.Names}}' | LC_ALL=C grep -E -e "$1" | awk 'END { print NR + 0 }'; }
# p32_other_running: the running cleat containers that are neither a test box nor a gateway (the
# daily boxes), sorted. Kept in the run dir only, never in a check's text.
p32_other_running() { docker ps --format '{{.Names}}' | LC_ALL=C grep -E -e '^cleat-' | LC_ALL=C grep -v -E -e '^cleat-(eg-[a-z0-9-]*-[0-9a-f]{8}|gw-[0-9a-f]{12})$' | LC_ALL=C sort; return 0; }
# p32_row_items NAME FILE: the comma list of status's NAME: row as words, without none and claude.
p32_row_items() {
  LC_ALL=C awk -v k="$1:" '$1 == k { sub(/^ *[A-Za-z]+: */, ""); n = split($0, a, /, */); for (i = 1; i <= n; i++) if (a[i] != "" && a[i] != "none" && a[i] != "claude") printf "%s%s", (o++ ? " " : ""), a[i] } END { printf "\n" }' "$2"
}
p32_strip_literal_esc() { LC_ALL=C sed -e 's/\\033\[[0-9;]*m//g' "$1"; }
p32_ctx() { local c="$1"; shift; DOCKER_CONTEXT="$c" docker "$@"; }
# p32_ctx_up CONTEXT: rc 0 when that engine answers.
p32_ctx_up() { DOCKER_CONTEXT="$1" docker info > /dev/null 2>&1; }
# p32_ctx_candidates: the docker contexts whose name or endpoint says orbstack or colima.
p32_ctx_candidates() {
  docker context ls --format '{{.Name}}|{{.DockerEndpoint}}' | LC_ALL=C awk -F'|' 'tolower($0) ~ /orbstack|colima/ { n = $1; sub(/ *\*$/, "", n); sub(/^ +/, "", n); sub(/ +$/, "", n); if (n != "") print n }'
}
p32_proc_status() { docker exec "$1" python3 -c "print(open('/proc/1/status').read())" | grep -E '^(Uid|CapEff)'; }
p32_rendered_digest() { sed -n 's/^ *"digest": *"\([^"]*\)".*/\1/p' "$1" | head -n 1; }
p32_hook_count() { bx "$1" grep -c 'PermissionRequest' /home/coder/.claude/settings.json; return 0; }
p32_box_exists() { [ -n "$(cn "$1")" ]; }
# p32_shim_ok OUTFILE: rc 0 when a status read shows the shim listening.
p32_shim_ok() { LC_ALL=C grep -q '● Shim listening' "$1" 2>/dev/null; }
# p32_eg_entries FILE: rc 0 when FILE's [egress] section holds a pack = or allow = line (deny lines do not count).
p32_eg_entries() {
  [ -f "$1" ] || return 1
  LC_ALL=C awk '/^[[:space:]]*\[/ { s = ($0 ~ /^[[:space:]]*\[egress\][[:space:]]*$/); next }
    s && /^[[:space:]]*(pack|allow)[[:space:]]*=/ { f = 1 } END { exit (f ? 0 : 1) }' "$1"
}

# ---- the image swap of 2.24 ----
# p32_tree_ok FILE: rc 0 when p32_img_tree's output reads this tree's twice.
p32_tree_ok() { [ -f "$1" ] && LC_ALL=C grep -q "^relay: this tree's" "$1" && LC_ALL=C grep -q "^entrypoint: this tree's" "$1"; }
# p32_img_state: P32_SPEC (MT_IMAGE's spec label) and P32_TREE (1: this tree's relay and entrypoint).
p32_img_state() {
  P32_SPEC=""; P32_TREE=0
  val P32_SPEC -t 60 -- p32_spec "$MT_IMAGE"
  run_cmd -q -t 300 -- p32_img_tree "$MT_IMAGE"
  p32_tree_ok "$OUT" && P32_TREE=1
  say "    $MT_IMAGE reads spec ${P32_SPEC:-none}, this tree's relay and entrypoint: $( [ "$P32_TREE" = 1 ] && printf yes || printf no)"
}
p32_spec6_ok() {
  run_cmd -q -t 300 -- p32_img_tree "$MT_IMAGE:mt-spec6"
  p32_tree_ok "$OUT"
}
# p32_image_v154 [pull]: MT_IMAGE holds the released v1.5.4 image (spec 4) and the candidate is
# kept in MT_IMAGE:mt-spec6. The candidate is copied there only from an MT_IMAGE that reads this
# tree's. pull: always pull v1.5.4 first (2.24-pre's own line), else only when it is missing.
p32_image_v154() {
  local spec=""
  if p32_dry; then
    P32_SPEC=4; P32_TREE=0
    kv_set image.swapped 1
    img_tag "$MT_IMAGE" "$MT_IMAGE:mt-spec6"
    dk_pull ghcr.io/cleatdev/cleat:v1.5.4 1200
    img_tag ghcr.io/cleatdev/cleat:v1.5.4 "$MT_IMAGE"
    val spec -t 60 -- p32_spec "$MT_IMAGE"
    expect_eq "$MT_IMAGE reads spec 4 (the v1.5.4 image)" "$spec" 4
    return 0
  fi
  p32_img_state
  if [ "$P32_SPEC" = 4 ]; then
    # Re-entry: the swap happened in an earlier attempt. The candidate must be in mt-spec6.
    p32_spec6_ok || step_abort "$MT_IMAGE already reads spec 4 and $MT_IMAGE:mt-spec6 is not this tree's image, so the candidate image is kept nowhere. Rebuild it: ./egress-release.sh --only 0.5, then run 2.24 again from 2.24-pre"
    kv_set image.swapped 1
    check_note "$MT_IMAGE already holds the v1.5.4 image (an earlier attempt). The candidate stays in $MT_IMAGE:mt-spec6"
    if [ "${1:-}" != pull ]; then return 0; fi
  else
    [ "$P32_TREE" = 1 ] || step_abort "$MT_IMAGE reads spec ${P32_SPEC:-none} and is not this tree's build. Never swap it away: ./egress-release.sh --only 0.5"
    kv_set image.swapped 1
    img_tag "$MT_IMAGE" "$MT_IMAGE:mt-spec6" || step_abort "could not keep the candidate image as $MT_IMAGE:mt-spec6"
    check_pass "the candidate image is kept as $MT_IMAGE:mt-spec6"
  fi
  if [ "${1:-}" = pull ] || ! run_cmd -q -t 60 -- p32_img_id ghcr.io/cleatdev/cleat:v1.5.4; then
    dk_pull ghcr.io/cleatdev/cleat:v1.5.4 1200
    expect_rc "docker pull ghcr.io/cleatdev/cleat:v1.5.4" 0
  fi
  img_tag ghcr.io/cleatdev/cleat:v1.5.4 "$MT_IMAGE" || step_abort "could not tag the v1.5.4 image as $MT_IMAGE"
  val spec -t 60 -- p32_spec "$MT_IMAGE"
  expect_eq "$MT_IMAGE reads spec 4 (the v1.5.4 image)" "$spec" 4
}
# p32_image_candidate: MT_IMAGE holds this tree's image again (from mt-spec6 when it does not).
p32_image_candidate() {
  if p32_dry; then
    P32_SPEC=6; P32_TREE=1
    img_tag "$MT_IMAGE:mt-spec6" "$MT_IMAGE"
    kv_set image.swapped 0
    expect_eq "$MT_IMAGE reads spec 6" "" ""
    return 0
  fi
  p32_img_state
  if [ "$P32_TREE" != 1 ] || [ "$P32_SPEC" != 6 ]; then
    p32_spec6_ok || step_abort "$MT_IMAGE is not this tree's image and $MT_IMAGE:mt-spec6 is not either. Rebuild it: ./egress-release.sh --only 0.5"
    img_tag "$MT_IMAGE:mt-spec6" "$MT_IMAGE" || step_abort "could not tag $MT_IMAGE:mt-spec6 back as $MT_IMAGE"
    p32_img_state
  fi
  expect_eq "$MT_IMAGE reads spec 6" "$P32_SPEC" 6
  expect_eq "$MT_IMAGE carries this tree's relay and entrypoint" "$P32_TREE" 1
  if [ "$P32_TREE" = 1 ] && [ "$P32_SPEC" = 6 ]; then kv_set image.swapped 0; fi
  return 0
}

# ---- eg-old ----
# p32_old_box: P32_OLD (the box), P32_OLDSHAPE ("<network> [<egress label>]"), P32_OLDCAGED (1 when
# it carries the egress label). Aborts when there is no box.
p32_old_box() {
  P32_OLD=""; P32_OLDSHAPE=""; P32_OLDCAGED=0
  val P32_OLD -t 60 -- cn eg-old
  if p32_dry; then return 0; fi
  [ -n "$P32_OLD" ] || step_abort "no eg-old box: run 2.24-pre first"
  val P32_OLDSHAPE -t 60 -- docker inspect -f '{{.HostConfig.NetworkMode}} [{{index .Config.Labels "sh.cleat.egress-hash"}}]' "$P32_OLD"
  case "$P32_OLDSHAPE" in *" [v"*) P32_OLDCAGED=1 ;; esac
  kv_set eg-old.cn "$P32_OLD"
  say "    eg-old: $P32_OLD on $P32_OLDSHAPE"
}
# p32_old_uncaged: abort when eg-old was caged already (2.24i ran): the upgrade steps before it
# cannot run again on that box.
p32_old_uncaged() {
  [ "$P32_OLDCAGED" = 1 ] || return 0
  step_abort "eg-old is caged already ($P32_OLDSHAPE): 2.24i ran in an earlier attempt. To run 2.24 again: ./egress-release.sh --only 2.24-clean, then from 2.24-pre"
}
# p32_old_stop: eg-old stopped (the scenario's launches meet a stopped box).
p32_old_stop() {
  p32_dry && return 0
  run_cmd -q -t 60 -- box_running eg-old || return 0
  check_note "eg-old is running (an earlier attempt or a session left open): cleatup stop first"
  p32_exit eg-old exit-before
  clt --as cleatup -T 300 -- stop
}
# p32_old_state_check WANT: eg-old's state and network after a refusal. WANT bridge: exited on
# its own (bridge) network. WANT none: exited on none (still caged).
p32_old_state_check() {
  local c=""
  val c -t 60 -- cn eg-old
  if [ -z "$c" ] && ! p32_dry; then check_fail "eg-old is kept" "the box still exists" "no eg-old box"; return 0; fi
  dk -- inspect -f '{{.State.Status}} {{.HostConfig.NetworkMode}}' "${c:-cleat-eg-old-00000000}"
  expect_match "eg-old is kept, stopped" '^exited '
  if [ "$1" = none ]; then
    expect_match "eg-old is still caged (network none)" '^exited none$'
  else
    expect_not_match "eg-old is still on its own bridge network (not none)" ' none$'
  fi
}
# p32_upx_has_egress: rc 0 when the upgrade config holds an [egress] section.
p32_upx_has_egress() { [ -f "$UPX/cleat/config" ] && LC_ALL=C grep -q '^\[egress\]' "$UPX/cleat/config"; }
# p32_upx_drop: the scenario's awk of 2.24j, through $SCRATCH/mt-upx-config, then cat back.
p32_upx_drop() {
  awk '/^\[/{s=($0=="[egress]")} !s' "$UPX/cleat/config" > "$SCRATCH/mt-upx-config" && cat "$SCRATCH/mt-upx-config" > "$UPX/cleat/config" && rm -f "$SCRATCH/mt-upx-config"
}
# p32_settings_back DIR: settings.mt moved back to settings (2.24e's cleanup and re-entry).
p32_settings_back() {
  local d="$1"
  case "$d" in "$UPX"/*) ;; *) printf 'p32_settings_back: refusing %s\n' "$d" >&2; return 1 ;; esac
  if [ -e "$d/settings.mt" ] && [ ! -e "$d/settings" ]; then mv "$d/settings.mt" "$d/settings"; fi
  return 0
}
# p32_one_question DESC: exactly one recreate or refresh question in the last xrun (W8).
p32_one_question() {
  local t n=0 v
  for t in img-refresh-recreate recreate img-refresh img-update recreate-policy recreate-touse reaper start-fresh unnamed-Yn; do
    v=$(xfired "$t"); p32_is_int "$v" || v=0
    n=$((n + v))
  done
  expect_num "$1" "$n" eq 1
}

# ---- T1 ----
p32_bash_word() { if [ "$MT_BASH" = /bin/bash ]; then printf '/bin/bash'; else printf '%q' "$MT_BASH"; fi; }
p32_upx_line() {
  if [ "$UPX" = "$HOME/mt-egress-xdg-up" ]; then printf '%s' 'UPX="$HOME/mt-egress-xdg-up"'; else printf 'UPX=%q' "$UPX"; fi
}
p32_cleatup_line() {
  printf 'cleatup()  { XDG_CONFIG_HOME="$UPX" CLEAT_NO_IDLE_SWEEP=1 CLEAT_NO_CLAUDE_UPDATE_CHECK=1 %s "$WT/bin/cleat" "$@"; }' "$(p32_bash_word)"
}
p32_c154_line() {
  printf 'cleat154() { XDG_CONFIG_HOME="$UPX" CLEAT_NO_IDLE_SWEEP=1 CLEAT_NO_CLAUDE_UPDATE_CHECK=1 %s %s "$@"; }' "$(p32_bash_word)" "$(printf '%q' "$CLEAT_V154")"
}
# p32_old_cmd FUNC: the T1 line that defines UPX and cleatup() (and cleat154()) and runs FUNC,
# only when UPX is set (departure 1).
p32_old_cmd() {
  local defs
  defs="$(p32_upx_line); $(p32_cleatup_line)"
  [ "$1" = cleat154 ] && defs="$defs; $(p32_c154_line)"
  printf '%s; echo "MT-UPX=[$UPX]"; [ -n "$UPX" ] && %s' "$defs" "$1"
}
# p32_t1_idle: no Claude session open in T1 (2.24's Before). The project T1 ran last and eg-old.
p32_t1_idle() {
  local proj p
  proj=$(kv_get t1.proj "")
  for p in $proj eg-old; do
    if ! p32_dry && run_cmd -q -t 90 -- box_claude_live "$p"; then
      check_note "a Claude session is open in $p: it ends first (2.24 starts with no session open in T1)"
      p32_exit "$p" "exit-before-$p"
    fi
  done
  return 0
}
# p32_ask ARGS..., p32_ask_record ARGS...: asked again while the answer is r. The last rc.
p32_ask() {
  local r
  while :; do ask "$@"; r=$?; [ "$r" = 5 ] || return "$r"; done
}
p32_ask_record() {
  local r
  while :; do ask_record "$@"; r=$?; [ "$r" = 5 ] || return "$r"; done
}
# p32_ask_lines TAG SPEC...: t_checks_or_ask's one question, asked even with a capture.
p32_ask_lines() {
  local tag="$1" s yes="" no=""
  shift
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
  p32_ask "$tag" T1 "Read what T1 printed when the command started, before Claude Code opened." "${yes:+T1 printed these lines:
$yes}${no:+
T1 printed none of these:
$no}" "Did T1 print exactly that?"
}
# p32_launch PROJ CMD TAG [--answer TAG=ANS]... [SPEC...]: [T1 launch CMD in PROJ] (DESIGN 6.2).
# P32_LRC is t_wait_launch's code: 0 live, 1 ended without Claude, 2 skipped, 3 timed out. A typed
# capture with no Egress: line at all is asked instead (Claude Code may clear the scrollback).
p32_launch() {
  local proj="$1" cmd="$2" tag="$3" s egline=0
  local ans=()
  shift 3
  while [ $# -gt 0 ] && [ "$1" = --answer ]; do ans[${#ans[@]}]="--answer"; ans[${#ans[@]}]="$2"; shift 2; done
  P32_LRC=0
  t_ensure t1
  t_run t1 "$proj" "$cmd" ${ans[@]+"${ans[@]}"}
  t_front t1
  t_wait_launch t1 "$proj" 900
  P32_LRC=$?
  case "$P32_LRC" in
    0) check_pass "Claude Code opened in T1 ($tag)" ;;
    1) check_fail "Claude Code opened in T1 ($tag)" "a live Claude Code session in $proj" "the command ended without Claude Code" ;;
    2) check_skip "Claude Code opened in T1 ($tag)" "skipped at the wait" ;;
    *) check_fail "Claude Code opened in T1 within 900 s ($tag)" "a live Claude Code session in $proj" "timed out" ;;
  esac
  [ $# -gt 0 ] || return 0
  for s in "$@"; do case "$s" in *Egress:*) egline=1 ;; esac; done
  if t_have_capture && t_capture t1 "$tag"; then
    t_region launch
    if [ "$egline" = 1 ] && [ "$(t_mode)" = typed ] && ! p32_dry && ! LC_ALL=C grep -q 'Egress:' "$OUT"; then
      check_note "T1's history holds no Egress: line (Claude Code may have cleared the scrollback when it drew): asked instead"
      p32_ask_lines "$tag" "$@"
      return 0
    fi
  fi
  while :; do t_checks_or_ask "$tag" "$@"; [ $? = 5 ] || break; done
  return 0
}
# p32_end_region FILE: from the last session end (bin/cleat:20274 Session ended, 20276 Claude
# exited with code N) to the end, or a marker line and the whole file when there is none.
p32_end_region() {
  LC_ALL=C awk '/Session ended\. Resume with: cleat resume|Claude exited with code [0-9]+/ { k = 0; f = 1 }
    { line[++k] = $0 }
    END { if (!f) print "__P32_NO_END_LINE__"; for (i = 1; i <= k; i++) print line[i] }' "$1"
}
# p32_exit PROJ TAG [SPEC...]: [T1 exit PROJ], then the end of the session against the specs.
p32_exit() {
  local proj="$1" tag="$2" live=1 r=0
  shift 2
  if ! p32_dry; then run_cmd -q -t 90 -- box_claude_live "$proj" || live=0; fi
  if [ "$live" = 0 ]; then
    check_note "T1: no Claude session was open in $proj"
    return 0
  fi
  t_wait_exit t1 "$proj" 600
  r=$?
  [ $# -gt 0 ] || return "$r"
  if t_have_capture && t_capture t1 "$tag"; then
    run_cmd -q -- p32_end_region "$OUT"
    if ! p32_dry && LC_ALL=C grep -q '^__P32_NO_END_LINE__$' "$OUT"; then
      if t_is_auto; then
        check_skip "the session-end report in T1" "T1 simulated: the session ended with Ctrl-C, so no session-end report"
        return "$r"
      fi
      check_note "T1 printed neither Session ended nor Claude exited with code N: the checks read the whole capture"
    fi
  fi
  while :; do t_checks_or_ask "$tag" "$@"; [ $? = 5 ] || break; done
  return "$r"
}

# ---- accounts and the live switch (2.25, 2.14-acct) ----
# p32_cred_sum ACCT: a checksum of the account's stored credential, empty when it has none.
p32_cred_sum() {
  local f="$CFG/accounts/$1/.credentials.json"
  [ -s "$f" ] || return 0
  cksum < "$f" | awk '{ print $1 "-" $2 }'
}
# p32_login_done ACCT BEFORE: the login landed in ACCT (its credential written and new) and no
# Claude runs in eg-core any more.
p32_login_done() {
  local now
  now=$(p32_cred_sum "$1")
  [ -n "$now" ] && [ "$now" != "$2" ] || return 1
  ! box_claude_live eg-core
}
p32_need_login() {
  p32_dry && return 0
  [ -n "$(p32_cred_sum "$1")" ] || step_abort "account $1 has no login: run 2.25b (lab-a) or 2.25d (lab-b) first"
}
# p32_pin: the account eg-core's box is pinned to (default when none).
p32_pin() {
  local c f
  c=$(cn_name eg-core) || return 0
  f="$CFG/box-accounts/$c"
  if [ -f "$f" ]; then head -n 1 "$f"; else printf 'default\n'; fi
}
p32_acct_count() { ( [ -d "$CFG/accounts" ] && cd "$CFG/accounts" && ls ) 2>/dev/null | LC_ALL=C grep -E -e '^[a-z0-9][a-z0-9_-]*$' | awk 'END { print NR + 0 }'; }
# p32_acct_state: what an accounts picker could change: the accounts, the trash, every pin.
p32_acct_state() {
  local f
  printf 'accounts:'; ( [ -d "$CFG/accounts" ] && cd "$CFG/accounts" && ls ) 2>/dev/null | tr '\n' ' '; printf '\n'
  printf 'trash:'; ( [ -d "$CFG/accounts/.trash" ] && cd "$CFG/accounts/.trash" && ls ) 2>/dev/null | tr '\n' ' '; printf '\n'
  printf 'pins:'
  if [ -d "$CFG/box-accounts" ]; then
    for f in "$CFG/box-accounts"/*; do [ -f "$f" ] && printf ' %s=%s' "${f##*/}" "$(head -n 1 "$f")"; done
  fi
  printf '\n'
}
# p32_login ACCT TAG: [T1 launch cleat login in eg-core]: the human signs in in the browser tab
# that opens on the Mac, then the wait for the credential (departure 4) and the success line.
p32_login() {
  local acct="$1" tag="$2" before="" now="" r
  before=$(p32_cred_sum "$acct")
  if [ -n "$before" ] && ! p32_dry; then
    choose "relogin-$acct" "Account $acct already holds a login (an earlier attempt). Keep it, or sign in again?" "k=keep the login it holds" "l=sign in again in the browser"
    if [ "$CHOICE" = k ]; then
      check_note "kept the login $acct already held: no new sign-in"
      check_pass "account $acct holds a login"
      return 0
    fi
  fi
  # cleat login refuses a stopped box (require_running, bin/cleat:23238). After a resume or a Docker
  # restart eg-core may be down: cleat run brings the caged box up first, with no session.
  if ! p32_dry && ! run_cmd -q -t 60 -- box_running eg-core; then
    check_note "the eg-core box is not running and cleat login needs it: cleat run starts it first"
    clt -T 900 -- run
    expect_rc "cleat run in eg-core exits 0 (the caged box, no session)" 0
  fi
  t_ensure t1
  say "T1 runs cleat login in eg-core now. A browser tab opens on this Mac: sign in there with the login meant for $acct."
  t_run t1 eg-core "cleat login"
  t_front t1
  wait_for "login-$acct" "In the browser tab that opened, sign in with the login meant for $acct. If Claude Code asks how to log in, pick the account login. If T1 asks for a code, paste it there. Come back here when T1 prints Auth saved. If T1 is back at its prompt without that line, press d." --timeout 900 --every 3 -- p32_login_done "$acct" "$before"
  r=$?
  [ "$r" = 2 ] && step_skip "the sign-in for $acct was skipped"
  # A d typed at the wait reads as met: the credential decides (a file read, no docker).
  now=$(p32_cred_sum "$acct")
  if p32_dry || { [ -n "$now" ] && [ "$now" != "$before" ]; }; then
    check_pass "the login landed in account $acct (its credential was written)"
  elif [ "$r" = 3 ]; then
    check_fail "the login landed in account $acct" "a new credential under accounts/$acct" "none within 900 s"
  else
    check_fail "the login landed in account $acct" "a new credential under accounts/$acct" "none: T1 ended without one"
  fi
  # The harvest writes the credential just before the success line (bin/cleat:23334, 23344).
  p32_sleep 5
  # The login's own output names the login: the check never quotes it.
  if t_have_capture && t_capture t1 "$tag"; then
    p32_quiet_match "T1 printed ✔ Auth saved to account $acct." "✔ Auth saved to account $(p32_ere "$acct")\\."   # bin/cleat:23344
  else
    p32_ask "$tag" T1 "Read what T1 printed after the sign-in." "T1 printed: ✔ Auth saved to account $acct." "Did T1 print exactly that?"
  fi
}
# p32_is_claude_cmd ARGV...: _is_claude_argv's reading (bin/cleat:24212) of one docker top line.
p32_is_claude_cmd() {
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
# p32_claude_pids PROJ: the pids of Claude Code processes in PROJ's box, one per line.
p32_claude_pids() {
  local c top col=-1 pcol=-1 i
  local f=()
  c=$(cn "$1")
  [ -n "$c" ] || return 0
  top=$(docker top "$c" 2>/dev/null) || return 0
  {
    IFS=$' \t' read -r -a f || true
    i=0
    while [ "$i" -lt "${#f[@]}" ]; do
      case "${f[$i]}" in CMD|COMMAND) col=$i ;; PID) pcol=$i ;; esac
      i=$((i + 1))
    done
    if [ "$col" -ge 0 ] && [ "$pcol" -ge 0 ]; then
      while IFS=$' \t' read -r -a f; do
        [ "${#f[@]}" -gt "$col" ] || continue
        if p32_is_claude_cmd "${f[@]:$col}"; then printf '%s\n' "${f[$pcol]}"; fi
      done
    fi
  } <<EOF
$top
EOF
  return 0
}
# p32_reopened PROJ OLDPIDS: rc 0 once a Claude Code runs in PROJ and none of OLDPIDS does.
p32_reopened() {
  local now p
  now=$(p32_claude_pids "$1" | tr '\n' ' ')
  case "$now" in *[0-9]*) ;; *) return 1 ;; esac
  for p in $now; do case " $2 " in *" $p "*) return 1 ;; esac; done
  return 0
}

# ---- G2: the log, the session id, the debug log ----
# The rows of cleat egress log that turned a connection away: "x denied" and "x refused" (the sni,
# handshake-flood and address codes), bin/cleat:13922-13928. Both count for G2: a host Claude Code
# needed is lost either way.
# p32_log_rows FILE: how many such rows FILE holds.
p32_log_rows() { LC_ALL=C awk '{ for (i = 1; i < NF; i++) if ($i == "x" && ($(i + 1) == "denied" || $(i + 1) == "refused")) { n++; break } } END { print n + 0 }' "$1" 2>/dev/null; }
# p32_log_hosts FILE: the hosts of those rows, first seen first, the port dropped.
p32_log_hosts() {
  [ -f "$1" ] || return 0
  LC_ALL=C awk '{ for (i = 1; i < NF; i++) if ($i == "x" && ($(i + 1) == "denied" || $(i + 1) == "refused")) { h = $(i + 2); sub(/:[0-9]+$/, "", h); if (h != "" && !seen[h]++) print h; break } }' "$1"
}
# p32_lines_not_in EARLIER FILE: the lines of FILE that EARLIER does not hold. Each log row
# carries its own UTC stamp, so a row of the earlier leg never reads as new. A copy the gateway
# started again (a new log generation) still leaves only this leg's rows.
p32_lines_not_in() { LC_ALL=C awk 'FILENAME == ARGV[1] { seen[$0] = 1; next } !($0 in seen)' "$1" "$2"; }
# p32_g2_log LEG [EARLIER]: the G2 reading of cleat egress log in OUT for one leg. EARLIER is the
# whole log an earlier leg read: only the lines it does not hold belong to this leg. The whole log
# is kept as $SCRATCH/p32-g2-LEG.full for a later leg.
p32_g2_log() {
  local leg="$1" prev="${2:-}" logf="$OUT" legf hosts h in73="" other="" w7=""
  legf="$SCRATCH/p32-g2-$leg.log"
  if [ -n "$prev" ] && [ -f "$prev" ] && [ -f "$logf" ]; then
    p32_lines_not_in "$prev" "$logf" > "$legf"
  elif [ -f "$logf" ]; then
    cat "$logf" > "$legf"
  else
    : > "$legf"
  fi
  if [ -f "$logf" ]; then cat "$logf" > "$SCRATCH/p32-g2-$leg.full"; else : > "$SCRATCH/p32-g2-$leg.full"; fi
  for h in http-intake.logs.us5.datadoghq.com browser-intake-us5-datadoghq.com mcp-proxy.anthropic.com; do
    expect_not_contains "this leg's log never names $h (W7)" "$h" "$legf"
    LC_ALL=C grep -q -F -e "$h" "$legf" 2>/dev/null && w7="$w7${w7:+ }$h"
  done
  hosts=$(p32_log_hosts "$legf" | tr '\n' ' ')
  hosts="${hosts% }"
  for h in $hosts; do
    case "$h" in
      raw.githubusercontent.com|storage.googleapis.com|downloads.claude.ai|registry.npmjs.org) in73="$in73${in73:+ }$h" ;;
      http-intake.logs.us5.datadoghq.com|browser-intake-us5-datadoghq.com|mcp-proxy.anthropic.com) ;;
      *) other="$other${other:+ }$h" ;;
    esac
  done
  record_value "g2.$leg.denied" "${hosts:-none}" "every host the log denied or refused in this leg"
  record_value "g2.$leg.73" "${in73:-none}" "the spec 7.3 hosts denied (recorded only, never a FAIL)"
  record_value "g2.$leg.w7" "${w7:-none}" "the three W7 hosts in the log (none expected)"
  if [ -n "$other" ]; then
    p32_ask "g2-other-$leg" T2 "" "These hosts outside spec 7.3 were denied in this leg: $other" "Did every step of this leg still work (y), or did one break for one of them (n)?"
    record_value "g2.$leg.other" "$other" "denied hosts outside spec 7.3"
  else
    record_value "g2.$leg.other" "none" "denied hosts outside spec 7.3"
  fi
  kv_set "p32.g2.$leg.rows" "$(p32_log_rows "$legf")"
  P32_G2_HOSTS="${hosts:-none}"; P32_G2_73="${in73:-none}"; P32_G2_W7="${w7:-none}"
}
# p32_t1_text [ANCHOR]: T1's text since its last typed command, cleaned, into $SCRATCH/p32-t1.txt.
# With ANCHOR only what follows the last line holding it (empty when no line holds it). rc 1 when
# T1's text cannot be read (no typed mode, no tab). Typed mode only: it reads Terminal's history.
p32_t1_text() {
  local tf="$SCRATCH/p32-t1.txt" mark
  [ "$(t_mode)" = typed ] || return 1
  mt__t_osa t1 "read-t1" '	return history of mtTab' || return 1
  [ "$MT__OSA_OUT" != MT-NO-TAB ] || return 1
  printf '%s\n' "$MT__OSA_OUT" > "$tf.hist"
  mark=$(kv_get t1.mark "")
  if [ -n "$mark" ]; then mt__t_text_after_mark "$tf.hist" "$mark" | clean_text > "$tf.all"; else clean_text < "$tf.hist" > "$tf.all"; fi
  if [ -z "${1:-}" ]; then mv -f "$tf.all" "$tf"
  elif LC_ALL=C grep -q -F -e "$1" "$tf.all"; then mt__t_text_after_mark "$tf.all" "$1" > "$tf"
  else : > "$tf"; fi
  rm -f "$tf.hist" "$tf.all"
  return 0
}
# p32_rc_seen: T1 shows Remote Control's refusal naming DISABLE_TELEMETRY (2.25c item 5, the
# setting's name as cleat passes it, bin/cleat:121).
p32_rc_seen() { p32_t1_text && LC_ALL=C grep -q -e 'DISABLE_TELEMETRY' "$SCRATCH/p32-t1.txt"; }
# p32_tools_listed: after the last line holding 2.25c's item 6 question T1 shows a tool list (the
# Bash and WebFetch tools the earlier items used are in it).
p32_tools_listed() {
  p32_t1_text 'List the names of the tools you can call' || return 1
  LC_ALL=C grep -q -w -e 'Bash' "$SCRATCH/p32-t1.txt" && LC_ALL=C grep -q -w -e 'WebFetch' "$SCRATCH/p32-t1.txt"
}
# p32_tools_seen: p32_tools_listed with the text after the question unchanged since the last poll
# (Claude Code has finished writing the list).
p32_tools_seen() {
  local tf="$SCRATCH/p32-t1.txt"
  if ! p32_tools_listed; then rm -f "$tf.prev"; return 1; fi
  if [ -f "$tf.prev" ] && cmp -s "$tf" "$tf.prev"; then return 0; fi
  cp -f "$tf" "$tf.prev"
  return 1
}
# p32_newest_jsonl: the newest transcript of eg-core's sessions on the host (2.25c's SID line).
p32_newest_jsonl() { ls -t "$HOME"/.claude/projects/eg-core-????????/*.jsonl 2>/dev/null | head -n 1; }
p32_debug_count() { LC_ALL=C grep -i -E -e "$2" "$1" 2>/dev/null | awk 'END { print NR + 0 }'; }
# p32_debug_lines FILE: the scenario's two greps (kept in the run dir only, never in the report).
p32_debug_lines() {
  grep -iE 'proxy|ECONN|ETIMEDOUT|ENOTFOUND|403|tunnel' "$1" | head -n 40
  echo "-- claudeai-mcp:"
  grep -i 'claudeai-mcp' "$1" | head -n 5
  return 0
}
# p32_sid: the newest eg-core session id into P32_SID (empty when none).
p32_sid() {
  local jf=""
  P32_SID=""
  val jf -t 30 -- p32_newest_jsonl
  p32_dry && { P32_SID="dry-session"; return 0; }
  [ -n "$jf" ] || return 0
  jf="${jf##*/}"
  P32_SID="${jf%.jsonl}"
}
# p32_debug_read LEG: the debug log of the newest eg-core session read back (2.25c's T2 lines), or
# the scenario's fallback through cleat shell and claude --debug. P32_DEBUG says what happened.
# LEG is c (2.25c) or d (2.25d: 5.2's second G2 line asks "the same", the debug log included).
p32_debug_read() {
  local leg="$1" f n1="" n2="" r
  P32_DEBUG=""
  p32_sid
  f="$HOME/.claude/debug/$P32_SID.txt"
  if [ -z "$P32_SID" ] || { [ ! -f "$f" ] && ! p32_dry; }; then
    check_note "no debug log for the session id ${P32_SID:-none}: the scenario's fallback through cleat shell and claude --debug"
    t_ensure t1
    t_run t1 eg-core "cleat shell"
    p32_ask "g2-debug-$leg" T1 "Click T1. In the box shell it just opened, type: claude --debug
In that session send item 2 and item 3 of 2.25$leg again (the Bash ls and the WebFetch), then /exit.
Then type exit to leave the box shell." "T1 is back at its own prompt." "Did the debug session run both items?"
    p32_sid
    f="$HOME/.claude/debug/$P32_SID.txt"
  fi
  kv_set "acct.sid.$leg" "$P32_SID"
  if [ -n "$P32_SID" ] && { [ -f "$f" ] || p32_dry; }; then
    run_cmd -q -t 60 -- p32_debug_lines "$f"
    say "    The debug lines are in $OUT (the run dir only)."
    val n1 -t 60 -- p32_debug_count "$f" 'proxy|ECONN|ETIMEDOUT|ENOTFOUND|403|tunnel'
    val n2 -t 60 -- p32_debug_count "$f" 'claudeai-mcp'
    record_value "g2.$leg.debug_proxy_lines" "$n1" "debug lines about the proxy or the network"
    record_value "g2.$leg.debug_mcp_lines" "$n2" "debug lines naming claudeai-mcp (the connectors turned off)"
    check_pass "the Claude Code debug log of this session was read back"
    P32_DEBUG="read back ($n1 proxy or network lines, $n2 claudeai-mcp lines)"
  else
    check_fail "G2 incomplete: a Claude Code debug log read back" "~/.claude/debug/<session id>.txt" "no debug file for the newest eg-core session"
    P32_DEBUG="none (G2 incomplete)"
  fi
  return 0
}

# ---- picker, editor and W12 program pieces (each picker redraw ends with ESC [ <n> A) ----
p32_rowno() { LC_ALL=C grep -n -E -e "$2" "$1" 2>/dev/null | head -n 1 | cut -d: -f1; }
p32_nrows() { LC_ALL=C grep -E -e "$2" "$1" 2>/dev/null | awk 'END { print NR + 0 }'; }
p32_cursor_row() { LC_ALL=C grep -n -e '▸' "$1" 2>/dev/null | tail -n 1 | cut -d: -f1; }
# p32_quiet_match DESC ERE [no]: a check on OUT that never quotes OUT. The accounts screens and a
# login's output show the login and its organisation, which must never reach the report.
p32_quiet_match() {
  local desc="$1" ere="$2" neg="${3:-}" hit=0
  if p32_dry; then expect_eq "$desc" "" ""; return 0; fi
  if LC_ALL=C grep -E -q -e "$ere" "$OUT" 2>/dev/null; then hit=1; fi
  if [ -z "$neg" ] && [ "$hit" = 1 ]; then check_pass "$desc"
  elif [ -z "$neg" ]; then check_fail "$desc" "a line matching $ere" "not found (the text stays in the run dir, ${OUT##*/})"
  elif [ "$hit" = 0 ]; then check_pass "$desc"
  else check_fail "$desc" "no line matching $ere" "found (the text stays in the run dir, ${OUT##*/})"; fi
}
p32_pk_begin() { xp_new; xp_wait open "$1" 120; xp_wait d0 '\x1b\[[0-9]+A' 30; xp_sleep 200; P32_KN=0; }
p32_pk_key() {
  P32_KN=$((P32_KN + 1))
  xp_mark "k$P32_KN"
  xp_send "$1"
  xp_wait "d$P32_KN" '\x1b\[[0-9]+A' 20
  xp_sleep 200
  [ -n "${2:-}" ] && xp_snap "$2"
  return 0
}
# p32_pk_chords PREFIX: Option+Left, Option+Right, Page Up, then down, each with a snapshot.
p32_pk_chords() {
  p32_pk_key "<opt-left>" "$1-optl"
  p32_pk_key "<opt-right>" "$1-optr"
  p32_pk_key "<pgup>" "$1-pgup"
  p32_pk_key "<down>" "$1-down"
}
# p32_pk_check NAME PREFIX: the chords did nothing, down moved the cursor one row. The checks
# never quote the screen (p32_quiet_match): the accounts picker shows logins.
p32_pk_check() {
  local name="$1" pre="$2" s r0 r1
  for s in optl optr pgup; do
    xsnap "$pre-$s"
    p32_quiet_match "$name: still open after $s (no Cancelled.)" 'Cancelled\.' no
    p32_quiet_match "$name: the picker is still drawn after $s" '▸'
  done
  xsnap "$pre-pgup"; r0=$(p32_cursor_row "$OUT")
  xsnap "$pre-down"; r1=$(p32_cursor_row "$OUT")
  if p32_dry; then expect_eq "$name: down moves the cursor one row" "$r1" "$r0"; return 0; fi
  if p32_is_int "$r0" && p32_is_int "$r1"; then
    expect_eq "$name: down moves the cursor one row" "$r1" "$((r0 + 1))"
  else
    check_fail "$name: down moves the cursor one row" "a cursor row in both snapshots" "before ${r0:-none}, after ${r1:-none}"
  fi
}
# p32_w12_check LABEL SNAP...: in every snapshot one Capabilities header, on the same screen row (W12).
p32_w12_check() {
  local label="$1" s n cap cap0="" bad_one="" bad_move=""
  shift
  if p32_dry; then expect_eq "$label: one Capabilities header, a still frame" "" ""; return 0; fi
  for s in "$@"; do
    xsnap "$s"
    n=$(p32_nrows "$OUT" 'Capabilities')
    [ "$n" = 1 ] || bad_one="$bad_one $s($n)"
    cap=$(p32_rowno "$OUT" 'Capabilities')
    [ -n "$cap0" ] || cap0="$cap"
    [ "$cap" = "$cap0" ] || bad_move="$bad_move $s(row $cap, was $cap0)"
  done
  if [ -z "$bad_one" ]; then check_pass "$label: exactly one Capabilities header in all $# snapshots"; else check_fail "$label: exactly one Capabilities header in every snapshot" "1 each" "$bad_one"; fi
  if [ -z "$bad_move" ]; then check_pass "$label: the frame never moved (Capabilities on screen row ${cap0:-?})"; else check_fail "$label: the frame never moves down the window" "the same row" "$bad_move"; fi
}
# The editor: a frame ends with ESC [ J (bin/cleat:16020).
p32_ed_begin() { xp_new; xp_wait open 'Cleat egress' 120; xp_wait f0 '\x1b\[J' 30; xp_sleep 200; P32_KN=0; }
p32_ed_key() {
  P32_KN=$((P32_KN + 1))
  xp_mark "k$P32_KN"
  xp_send "$1"
  xp_wait "f$P32_KN" '\x1b\[J' 20
  xp_sleep 200
  [ -n "${2:-}" ] && xp_snap "$2"
  return 0
}

# ---------------------------------------------------------------------------------------------
# 2.24 Upgrading a box made by v1.5.4
# ---------------------------------------------------------------------------------------------
# Every 2.24 step: kv image.swapped is 1 from just before the first swap until the candidate image
# is back, so guard_image lets a resume inside 2.24 go on. The candidate is copied to mt-spec6 only
# from an MT_IMAGE that reads this tree's (p32_image_v154), never removed while MT_IMAGE reads 4.

# Re-entry: the v1.5.4 copy is written again, the swap keeps an earlier attempt's mt-spec6, an
# uncaged eg-old with no egress label is kept. A caged eg-old means 2.24i ran: abort.
st_2_24_pre() {
  local n c="" shape="" id154="" idbox=""
  p32_t1_idle
  p32_cd eg-old make
  run_cmd -t 120 -- p32_write_v154 "$CLEAT_V154"
  expect_rc "git show v1.5.4:bin/cleat into the run dir" 0
  if ! p32_dry; then
    [ -s "$CLEAT_V154" ] || step_abort "could not write the v1.5.4 copy: is the tag v1.5.4 in $MT_WT?"
    cleat_copy_image "$CLEAT_V154"
  fi
  n=$(p32_count "^IMAGE_NAME=\"$MT_IMAGE\"\$" "$CLEAT_V154")
  expect_num "the copy builds and runs $MT_IMAGE (grep -c of its IMAGE_NAME line)" "$n" eq 1
  n=$(p32_count '^_EGRESS_ENFORCING=' "$CLEAT_V154")
  expect_num "the copy is the released code, which knows no egress (no _EGRESS_ENFORCING line)" "$n" eq 0
  cl --as cleat154 -t 60 -- --version
  expect_contains "cleat154 --version prints cleat v1.5.4" "cleat v1.5.4"   # v1.5.4 bin/cleat cmd_version
  p32_image_v154 pull
  val c -t 60 -- cn eg-old
  if [ -n "$c" ] && ! p32_dry; then
    val shape -t 60 -- docker inspect -f '{{.HostConfig.NetworkMode}} [{{index .Config.Labels "sh.cleat.egress-hash"}}]' "$c"
    case "$shape" in
      *" [v"*|"none "*) step_abort "eg-old exists and is caged already ($shape): an earlier attempt went past 2.24i. Run ./egress-release.sh --only 2.24-clean, then 2.24 again from 2.24-pre" ;;
    esac
    check_note "the uncaged eg-old box of an earlier attempt is kept ($shape)"
  else
    say "cleat154 run in eg-old: an uncaged v1.5.4 box from the spec 4 image. Every update question is answered n."
    clt --as cleat154 -T 900 -- run
    val c -t 60 -- cn eg-old
  fi
  if [ -z "$c" ] && ! p32_dry; then step_abort "cleat154 run made no eg-old box"; fi
  kv_set eg-old.cn "$c"
  dk -- inspect -f '{{.HostConfig.NetworkMode}} [{{index .Config.Labels "sh.cleat.egress-hash"}}]' "${c:-cleat-eg-old-00000000}"
  expect_not_match "eg-old is uncaged (its network is not none)" '^none '
  expect_match "eg-old carries no egress label" ' \[\]$'
  val id154 -t 60 -- p32_img_id ghcr.io/cleatdev/cleat:v1.5.4
  val idbox -t 60 -- docker inspect -f '{{.Image}}' "${c:-cleat-eg-old-00000000}"
  expect_eq "eg-old was created from the v1.5.4 image" "$idbox" "$id154"
}

# EXTRA. Re-entry: nothing is created, so it runs again as it is (an eg-spec4 box is the defect).
st_2_24_spec4() {
  local spec="" c="" n before after
  val spec -t 60 -- p32_spec "$MT_IMAGE"
  if ! p32_dry && [ "$spec" != 4 ]; then step_skip "$MT_IMAGE reads spec ${spec:-none}, not 4: run it right after 2.24-pre (--only 2.24-pre,2.24-spec4)"; fi
  p32_cd eg-spec4 make
  val c -t 60 -- cn eg-spec4
  if [ -n "$c" ] && ! p32_dry; then step_abort "an eg-spec4 box exists ($c): an earlier attempt created one, which is the defect this step looks for"; fi
  run_cmd -q -t 120 -- p32_egobjs_names
  before="$SCRATCH/mt-egobjs-before.txt"
  cat "$OUT" > "$before" 2>/dev/null || : > "$before"
  say "cleat run in eg-spec4 with the main config (strict): Refresh the image now? is answered n."
  clt -T 900 -- run
  expect_rc "cleat run exits 1" 1
  expect_contains "the relay refusal" "✖ Egress refused box main: the cleat image predates the relay a caged box reaches its gateway through."   # bin/cleat:11740, 11782
  expect_contains "it names cleat rebuild" "Fix:  cleat rebuild refreshes the image, then re-run cleat"   # bin/cleat:11741, 11786
  record_value upgrade.spec4 "$(LC_ALL=C grep -m 1 'Egress refused' "$OUT" 2>/dev/null | sed 's/^ *//') / $(LC_ALL=C grep -m 1 'Fix:' "$OUT" 2>/dev/null | sed 's/^ *//')" "the two lines"
  val n -t 60 -- p32_names_count '^cleat-eg-spec4-'
  expect_num "no eg-spec4 box was created" "$n" eq 0
  run_cmd -q -t 120 -- p32_egobjs_names
  after="$OUT"
  run_cmd -t 30 -- diff "$before" "$after"
  expect_rc "egobjs: nothing new (gateways, socket volumes and host files by name)" 0
}

# Re-entry: an MT_IMAGE already back at this tree's spec 6 is left as it is.
st_2_24_back() {
  p32_image_candidate
  p32_old_box
  dk -- inspect -f '{{.HostConfig.NetworkMode}} [{{index .Config.Labels "sh.cleat.egress-hash"}}]' "${P32_OLD:-cleat-eg-old-00000000}"
  expect_not_match "eg-old is on a bridge network, not none" '^none '
  expect_match "eg-old carries an empty egress label" ' \[\]$'
}

# Re-entry: a policy an earlier attempt of 2.24b saved is dropped again (the scenario's own awk of
# 2.24j), so egress is never turned on for the launch. A session already open is kept.
st_2_24a() {
  local id154="" idbox=""
  p32_cd eg-old
  p32_old_box
  p32_old_uncaged
  if p32_upx_has_egress; then
    run_cmd -t 30 -- p32_upx_drop
    check_note "re-entry: the [egress] section an earlier attempt of 2.24b saved was dropped from the upgrade config"
  fi
  if ! p32_dry && run_cmd -q -t 90 -- box_claude_live eg-old; then
    check_note "Claude Code is already open in eg-old (an earlier attempt): the launch lines cannot be read again"
    check_pass "Claude Code is live in eg-old"
  else
    say "T1 defines UPX and cleatup() on the same line as the launch, then runs cleatup in eg-old. Stay in the session that opens."
    p32_launch eg-old "$(p32_old_cmd cleatup)" launch-2.24a \
      "+MT-UPX=[$UPX]" \
      "-Recreate" \
      "-Refresh the image" \
      "-Update the image before starting?" \
      "+Egress:     off  ·  full network egress"   # bin/cleat:12309, 6861, 6952, 21346
  fi
  val id154 -t 60 -- p32_img_id ghcr.io/cleatdev/cleat:v1.5.4
  val idbox -t 60 -- docker inspect -f '{{.Image}}' "${P32_OLD:-cleat-eg-old-00000000}"
  expect_eq "the box still runs the spec 4 image (the same id as ghcr.io/cleatdev/cleat:v1.5.4)" "$idbox" "$id154"
  if [ "$idbox" = "$id154" ]; then
    record_value upgrade.r63 "a spec 4 box ran unprompted with egress off (the per-box image-spec check, R6-3, is not built)" "R6-3 evidence for 5.1"
    rec_set upgrade.r63 "a spec 4 box ran unprompted with egress off"
  fi
}

# Re-entry: as 2.24a (an earlier allow is dropped first, so the write turns the policy on again and
# prints the note). A session that is not open is opened again in T1.
st_2_24b() {
  local allow ref code="" row
  p32_cd eg-old
  p32_old_box
  p32_old_uncaged
  if p32_upx_has_egress; then
    run_cmd -t 30 -- p32_upx_drop
    check_note "re-entry: the [egress] section an earlier attempt saved was dropped, so this allow turns the policy on again"
  fi
  if ! p32_dry && ! run_cmd -q -t 90 -- box_claude_live eg-old; then
    check_note "no Claude session is open in eg-old: T1 opens one first (the W9 lines need a running box with a session)"
    p32_launch eg-old "$(p32_old_cmd cleatup)" launch-2.24b "+Egress:     off  ·  full network egress"
  fi
  clt --as cleatup -T 300 -- egress allow example.com
  allow="$OUT"; ref="$CMDREF"
  expect_rc "cleatup egress allow example.com exits 0" 0
  expect_contains "the write" "✔ Saved to $(p32_tilde "$UPX/cleat/config")"   # bin/cleat:14258
  expect_contains "the write turned the policy on" "mode = strict (the policy was off)"   # bin/cleat:14216
  OUT="$allow"; CMDREF="$ref"
  EGX="$UPX" note_check --also "${P32_OLD:-cleat-eg-old-00000000}"
  row="^ +$(p32_ere "${P32_OLD:-cleat-eg-old-00000000}") +cleat rm && cleat +$(p32_ere "$(p32_tilde "$P/eg-old")") +running$"
  expect_match "the eg-old row ends in running (W9)" "$row" "$allow"   # bin/cleat:13195-13196
  expect_match "the running lines follow the rows (W9)" '(It is running, so it keeps its full network until it stops\.|One of them is running, so it keeps its full network until it stops\.|[0-9]+ of them are running\. Each keeps its full network until it stops\.)' "$allow"   # bin/cleat:13202-13208
  expect_match "a session already open is not caged (W9)" 'A session already open in (it|one) is not caged\.' "$allow"   # bin/cleat:13208-13211
  val code -t 120 -- docker exec -u coder "${P32_OLD:-cleat-eg-old-00000000}" curl -sS -o /dev/null -w '%{http_code}\n' https://example.org/
  expect_eq "the open session is not caged: example.org answers 200" "$code" 200
  record_value upgrade.w9 "$(LC_ALL=C grep -E -m 1 'created without egress control' "$allow" 2>/dev/null | sed 's/^ *//') / $(LC_ALL=C grep -E -m 1 'running, so it keeps|are running\. Each keeps' "$allow" 2>/dev/null | sed 's/^ *//') / curl $code" "the W9 lines"
  rec_set upgrade.w9 "the eg-old row ended in running, the running lines followed, example.org answered $code from the open session"
  p32_exit eg-old exit-2.24b
  clt --as cleatup -T 300 -- stop
  if ! p32_dry && LC_ALL=C grep -q 'Container not running' "$OUT"; then
    check_note "eg-old was already stopped (Container not running)"   # bin/cleat:23043
  else
    expect_contains "cleatup stop" "✔ Session ended. Resume with: cleat resume"   # bin/cleat:23039
  fi
}

# Re-entry: a running eg-old is stopped first. Nothing here changes anything.
st_2_24c() {
  p32_cd eg-old
  p32_old_box
  p32_old_uncaged
  if ! p32_dry && ! p32_upx_has_egress; then step_abort "the upgrade config has no [egress] section: run 2.24b first"; fi
  p32_old_stop
  cl --as cleatup -- egress status
  first_lines 3
  expect_contains "status: x This box was created without egress control" "x This box was created without egress control"   # bin/cleat:14480
  expect_contains "status: It refuses to start until it is recreated:  cleat rm && cleat" "It refuses to start until it is recreated:  cleat rm && cleat"   # bin/cleat:14481
  cl --as cleatup --
  expect_rc "cleatup off a terminal exits 1" 1
  expect_match "Config changed since cleat-eg-old-<8 hex> was created. Recreate to apply: cleat rm && cleat" '▸ Config changed since cleat-eg-old-[0-9a-f]{8} was created\. Recreate to apply: cleat rm && cleat$'   # bin/cleat:6896
  expect_contains "the refusal: created before its egress policy" "✖ Egress refused box main: it was created before its egress policy, so it has no cage."   # bin/cleat:11842
  expect_contains "its fix: cleat rm && cleat recreates it under the policy" "Fix:  cleat rm && cleat recreates it under the policy"   # bin/cleat:11842, 14373
  p32_old_state_check bridge
}

# Re-entry: the swap keeps an earlier attempt's mt-spec6. The question can be asked again.
st_2_24d() {
  local ver q tr
  p32_cd eg-old
  p32_old_box
  p32_old_uncaged
  if ! p32_dry && ! p32_upx_has_egress; then step_abort "the upgrade config has no [egress] section: run 2.24b first"; fi
  p32_old_stop
  p32_image_v154
  ver=$(p32_version)
  clt --as cleatup --answer img-refresh-recreate=n -T 600 --
  tr="$OUT"
  expect_rc "cleatup exits 1" 1
  expect_match "the drift line names the missing egress cage" '▸ Config changed since cleat-eg-old-[0-9a-f]{8} was created: it has no egress cage, and your egress policy needs one'   # bin/cleat:6845, 6855
  expect_contains "the refresh rides on the recreate" "▸ The cleat image predates the egress relay, so the recreate refreshes it first (downloads the prebuilt v$ver, or builds it locally)"   # bin/cleat:6860
  expect_match "the one question: Refresh the image and recreate <box> now? [Y/n]" 'Refresh the image and recreate cleat-eg-old-[0-9a-f]{8} now\? \[Y/n\]'   # bin/cleat:6861
  expect_contains "n: Skipped" "▸ Skipped. Keeping existing container. Run cleat rm && cleat when ready."   # bin/cleat:6890
  expect_contains "then c's refusal" "it was created before its egress policy, so it has no cage."   # bin/cleat:11842
  expect_order "the refusal comes after the Skipped line" "Skipped. Keeping existing container." "Egress refused box main"
  expect_not_contains "never Refresh the image now? after it (W8)" "Refresh the image now?"   # bin/cleat:6952
  p32_one_question "exactly one question in all (W8)"
  p32_old_state_check bridge
  q=$(LC_ALL=C grep -E -m 1 'Refresh the image and recreate' "$tr" 2>/dev/null | sed -e 's/^ *//' -e 's/ *\[Y\/n\].*$/ [Y\/n]/' -e 's/cleat-eg-old-[0-9a-f]\{8\}/<box>/')
  record_value upgrade.question "${q:-not seen}" "the one question over the spec 4 image (W8)"
  rec_set upgrade.question "${q:-not seen}"
  kv_set c46.upgrade_question "${q:-not seen}"
}

# Re-entry: a settings.mt an earlier attempt left is moved back first (also the step's cleanup).
st_2_24e() {
  local dir
  p32_cd eg-old
  p32_old_box
  p32_old_uncaged
  if ! p32_dry && ! p32_upx_has_egress; then step_abort "the upgrade config has no [egress] section: run 2.24b first"; fi
  p32_old_stop
  dir="$UPX/cleat/run/${P32_OLD:-cleat-eg-old-00000000}"
  if ! p32_dry && [ -e "$dir/settings.mt" ] && [ ! -e "$dir/settings" ]; then
    run_cmd -t 30 -- p32_settings_back "$dir"
    check_note "re-entry: the settings overlay an earlier attempt moved aside is back"
  fi
  if ! p32_dry && [ ! -e "$dir/settings" ]; then step_abort "the box's settings overlay is not at $dir/settings: stop here, as the scenario says"; fi
  on_cleanup "p32_settings_back $(printf '%q' "$dir")"
  p32_image_v154
  run_cmd -t 30 -- mv "$dir/settings" "$dir/settings.mt"
  expect_rc "a host path the box mounts is gone (settings moved aside)" 0
  clt --as cleatup --answer img-refresh-recreate=n -T 600 --
  expect_rc "cleatup exits 1" 1
  expect_contains "n: Skipped" "▸ Skipped. Keeping existing container. Run cleat rm && cleat when ready."   # bin/cleat:6890
  expect_contains "the refusal names the old image" "✖ Egress refused box main: the cleat image predates the relay a caged box reaches its gateway through."   # bin/cleat:11740
  expect_contains "its fix names cleat rebuild" "Fix:  cleat rebuild refreshes the image, then re-run cleat"   # bin/cleat:11741
  expect_order "the refusal comes after the Skipped line" "Skipped. Keeping existing container." "the cleat image predates the relay"
  expect_not_contains "never Recreating container (host paths changed)" "Recreating container (host paths changed)"   # bin/cleat:22786
  expect_not_contains "nothing was recreated" "Recreating container"
  p32_one_question "exactly one question in all"
  p32_old_state_check bridge
  run_cmd -t 30 -- p32_settings_back "$dir"
  if ! p32_dry && [ ! -e "$dir/settings" ]; then check_fail "the settings overlay is back" "$dir/settings" "missing"; else check_pass "the settings overlay is back before anything starts the box"; fi
  record_value upgrade.e "refused naming cleat rebuild, nothing recreated, eg-old kept on its bridge network" "destroy case e"
  rec_set upgrade.e "refused naming cleat rebuild, box kept"
}

# Re-entry: the candidate goes back into MT_IMAGE at the end whatever the answer did.
st_2_24f() {
  local ver dir
  p32_cd eg-old
  p32_old_box
  p32_old_uncaged
  if ! p32_dry && ! p32_upx_has_egress; then step_abort "the upgrade config has no [egress] section: run 2.24b first"; fi
  p32_old_stop
  dir="$UPX/cleat/run/${P32_OLD:-cleat-eg-old-00000000}"
  p32_dry || p32_settings_back "$dir"
  p32_image_v154
  ver=$(p32_version)
  say "The one deliberate yes of rule 3: $MT_IMAGE holds v$ver already, the candidate is safe in $MT_IMAGE:mt-spec6."
  clt --as cleatup --answer img-refresh-recreate=y -T 1200 --
  expect_rc "cleatup exits 1" 1
  expect_match "the refresh: Image ready (cached or pulled v$ver)" "✔ Image ready \\((cached|pulled) v$(p32_ere "$ver")"   # bin/cleat:21421, 21438, 21498
  expect_contains "it still lacks the relay: e's refusal" "✖ Egress refused box main: the cleat image predates the relay a caged box reaches its gateway through."   # bin/cleat:11740
  expect_order "the refusal comes after the refresh" "Image ready" "Egress refused box main"
  expect_not_contains "no Recreating container" "Recreating container"   # bin/cleat:6875
  expect_not_contains "never Refresh the image now? (W8)" "Refresh the image now?"
  p32_one_question "exactly one question in all (W8)"
  p32_old_state_check bridge
  p32_image_candidate
}

# Re-entry: the candidate image is put back first when MT_IMAGE does not hold it.
st_2_24g() {
  p32_cd eg-old
  p32_old_box
  p32_old_uncaged
  if ! p32_dry && ! p32_upx_has_egress; then step_abort "the upgrade config has no [egress] section: run 2.24b first"; fi
  p32_old_stop
  p32_image_candidate
  clt --as cleatup --answer recreate=n -T 600 --
  expect_rc "cleatup exits 1" 1
  expect_match "the drift line names the missing egress cage" '▸ Config changed since cleat-eg-old-[0-9a-f]{8} was created: it has no egress cage, and your egress policy needs one'   # bin/cleat:6845
  expect_match "the plain question: Recreate <box> now? [Y/n]" 'Recreate cleat-eg-old-[0-9a-f]{8} now\? \[Y/n\]'   # bin/cleat:6863
  expect_not_contains "no image line: the image carries the relay" "The cleat image predates the egress relay"   # bin/cleat:6860
  expect_contains "n: Skipped" "▸ Skipped. Keeping existing container. Run cleat rm && cleat when ready."   # bin/cleat:6890
  expect_contains "then c's refusal" "✖ Egress refused box main: it was created before its egress policy, so it has no cage."   # bin/cleat:11842
  p32_one_question "exactly one question in all"
  record_value upgrade.question_g "$(LC_ALL=C grep -E -m 1 'Recreate cleat-eg-old-[0-9a-f]{8} now' "$OUT" 2>/dev/null | sed -e 's/^ *//' -e 's/ *\[Y\/n\].*$/ [Y\/n]/' -e 's/cleat-eg-old-[0-9a-f]\{8\}/<box>/')" "the plain question over the spec 6 image"
  p32_old_state_check bridge
}

# Re-entry: the throwaway copy is written again and removed at the end (also the cleanup).
st_2_24h() {
  local n zero gitb now
  zero="ghcr.io/cleatdev/cleat-gw@sha256:0000000000000000000000000000000000000000000000000000000000000000"
  p32_cd eg-old
  p32_old_box
  p32_old_uncaged
  if ! p32_dry && ! p32_upx_has_egress; then step_abort "the upgrade config has no [egress] section: run 2.24b first"; fi
  p32_old_stop
  p32_image_candidate
  on_cleanup "safe_rm $(printf '%q' "$CLEAT_NOGW")"
  # What git status lists before the copy, so the closing check judges only this step's file.
  p32_dry || safe_rm "$CLEAT_NOGW"
  run_cmd -q -t 60 -- git_dirty_untracked
  gitb="$SCRATCH/p32-git-before-2.24h.txt"
  cat "$OUT" > "$gitb" 2>/dev/null || : > "$gitb"
  run_cmd -t 60 -- p32_write_nogw
  expect_rc "the throwaway copy is written" 0
  n=$(p32_count '^_GATEWAY_IMAGE="ghcr.io/cleatdev/cleat-gw@sha256:0000' "$CLEAT_NOGW")
  expect_num "the copy names the gateway image that cannot be pulled (grep -c)" "$n" eq 1
  if ! p32_dry && [ "$n" != 1 ]; then step_abort "the throwaway copy was not written as the scenario's sed makes it"; fi
  clt --as cleatnogw --answer recreate=y -T 600 --
  expect_rc "cleatnogw exits 1" 1
  expect_match "the yes answered the plain question" 'Recreate cleat-eg-old-[0-9a-f]{8} now\? \[Y/n\]'   # bin/cleat:6863
  expect_contains "the spinner: Pulling the egress gateway image" "Pulling the egress gateway image"   # bin/cleat:11528
  # F1: no literal colour code. The strip after it changes nothing then, so the spinner's words
  # below are read as printed. An F1 regression fails here once.
  expect_not_contains "no colour code shown as text on the pull line: plain text (F1)" '\033['   # bin/cleat:11528
  run_cmd -q -- p32_strip_literal_esc "$OUT"
  expect_contains "the spinner names the image and the arch" "Pulling the egress gateway image (ghcr.io/cleatdev/cleat-gw, "   # bin/cleat:11528
  expect_contains "the spinner ends: Egress gateway image pull failed" "Egress gateway image pull failed"   # bin/cleat:11531
  expect_contains "the refusal names the image" "✖ Egress refused box main: the egress gateway image could not be pulled: $zero"   # bin/cleat:11532
  expect_contains "This is not a policy denial." "This is not a policy denial."   # bin/cleat:11783
  expect_contains "its fix" "Fix:  check the network and that Docker can reach ghcr.io, then re-run cleat"   # bin/cleat:11533
  expect_not_contains "no Recreating container before the refusal" "Recreating container"   # bin/cleat:6875
  p32_one_question "exactly one question in all"
  p32_old_state_check bridge
  safe_rm "$CLEAT_NOGW"
  if ! p32_dry && [ -e "$CLEAT_NOGW" ]; then check_fail "the throwaway copy is removed" "no $CLEAT_NOGW" "it is still there"; else check_pass "the throwaway copy is removed"; fi
  run_cmd -t 60 -- git_dirty_untracked
  if ! p32_dry && [ -s "$gitb" ]; then
    # Something untracked was there before this step: only a change from that reading is this step's.
    now="$OUT"
    check_note "git status listed untracked files before this step too (not this step's doing): the check compares with that reading"
    run_cmd -t 30 -- diff "$gitb" "$now"
    expect_rc "git status --short prints what it printed before the step (the script's own files aside)" 0
  else
    expect_count "git status --short prints nothing (the script's own files aside)" '.' eq 0
  fi
  record_value upgrade.h "refused before the box went (the gateway image pull failed), eg-old kept on its bridge network" "destroy case h"
  rec_set upgrade.h "refused at the gateway image pull, box kept"
}

# Re-entry: an eg-old caged by an earlier attempt is not recreated again: its state is checked.
st_2_24i() {
  local idimg="" line=""
  p32_cd eg-old
  p32_old_box
  if ! p32_dry && ! p32_upx_has_egress; then step_abort "the upgrade config has no [egress] section: run 2.24b first"; fi
  p32_image_candidate
  if [ "$P32_OLDCAGED" = 1 ]; then
    check_note "eg-old is caged already (an earlier attempt accepted the recreate): the launch lines cannot be read again"
  else
    p32_old_stop
    say "T1 runs cleatup in eg-old. Answer Y to Recreate cleat-eg-old-<8 hex> now? [Y/n] (typed mode answers it), then Claude opens."
    # One question in all (the scenario's Pass): no image question before or after the recreate.
    p32_launch eg-old "$(p32_old_cmd cleatup)" launch-2.24i --answer recreate=y \
      "+MT-UPX=[$UPX]" \
      "+▸ Recreating container..." \
      "+✔ Removed cleat-eg-old-" \
      "+Egress:     strict  ·  6 hosts, 1 pack" \
      "+Packs pinned at catalogue rev 1. Later additions wait for review." \
      "-Refresh the image" \
      "-Update the image before starting?"   # bin/cleat:6875, 6883, 12331, 12503, 6861, 6952, 21346
  fi
  val idimg -t 60 -- p32_img_id "$MT_IMAGE"
  val line -t 60 -- docker inspect -f '{{.HostConfig.NetworkMode}} {{.Image}}' "${P32_OLD:-cleat-eg-old-00000000}"
  expect_eq "eg-old is caged now (none) on the spec 6 image" "$line" "none $idimg"
  p32_exit eg-old exit-2.24i
}

# Re-entry: an [egress] section already gone is a NOTE. A stopped box stays stopped.
st_2_24j() {
  local n
  p32_cd eg-old
  p32_old_box
  if ! p32_dry && [ "$P32_OLDCAGED" != 1 ]; then step_abort "eg-old is not caged: run 2.24i first"; fi
  p32_exit eg-old exit-2.24j
  clt --as cleatup -T 300 -- stop
  if p32_upx_has_egress || p32_dry; then
    run_cmd -t 30 -- p32_upx_drop
    expect_rc "the scenario's awk drops [egress] from the upgrade config" 0
  else
    check_note "the upgrade config has no [egress] section already (an earlier attempt)"
  fi
  n=$(p32_count '^\[egress\]' "$UPX/cleat/config")
  expect_num "grep -c '^\\[egress\\]' of the upgrade config" "$n" eq 0
  clt --as cleatup -T 600 -- run
  expect_rc "cleatup run exits 1" 1
  expect_contains "the refusal: no longer resolves" "✖ Egress refused box main: it was created under an egress policy that no longer resolves."   # bin/cleat:11790
  expect_contains "its fix names cleat egress off" "Fix:  cleat egress off recreates it with a normal network, or restore the [egress] section"   # bin/cleat:11791
  expect_not_contains "nothing was recreated" "Recreating container"
  p32_old_state_check none
  record_value upgrade.j "refused naming cleat egress off, eg-old kept stopped on none (still caged)" "destroy case j"
  rec_set upgrade.j "refused naming cleat egress off, box kept caged"
}

# EXTRA. Re-entry: runs only while eg-old is caged with its policy removed (after 2.24j).
st_2_24_down() {
  local g="" v=""
  p32_cd eg-old
  p32_old_box
  if ! p32_dry && { [ "$P32_OLDCAGED" != 1 ] || p32_upx_has_egress; }; then
    step_skip "needs eg-old caged with its policy removed, as 2.24j leaves it"
  fi
  val g -t 60 -- gw eg-old
  val v -t 60 -- vol eg-old
  if ! p32_dry && { [ -z "$g" ] || [ -z "$v" ]; }; then step_abort "eg-old's gateway or socket volume cannot be named"; fi
  kv_set p32.old.gw "$g"; kv_set p32.old.vol "$v"
  # The v1.5.4 copy lives in the run dir: a later invocation or a cleaned scratch writes it again.
  if ! p32_dry && [ ! -s "$CLEAT_V154" ]; then
    run_cmd -t 120 -- p32_write_v154 "$CLEAT_V154"
    [ -s "$CLEAT_V154" ] || step_abort "could not write the v1.5.4 copy: is the tag v1.5.4 in $MT_WT?"
    cleat_copy_image "$CLEAT_V154"
  fi
  cl --as cleat154 -- ps
  expect_contains "cleat154 ps lists eg-old's gateway as if it were a box" "${g:-cleat-gw-000000000000}"   # v1.5.4 cmd_ps: docker ps -a --filter name=^cleat-
  record_value upgrade.down.ps "$(LC_ALL=C grep -F -m 1 -e "${g:-cleat-gw-}" "$OUT" 2>/dev/null | sed 's/^ *//')" "the gateway row cleat154 ps prints"
  say "T1 runs cleat154 in eg-old. It offers a recreate (v1.5.4 knows nothing of the cage): answer Y (typed mode answers it)."
  p32_launch eg-old "$(p32_old_cmd cleat154)" launch-2.24down --answer recreate=y "+MT-UPX=[$UPX]"
  dk -- inspect -f '{{.HostConfig.NetworkMode}}' "${P32_OLD:-cleat-eg-old-00000000}"
  expect_not_match "the box came back on a normal network" '^none$'
  dk -- ps -a --filter label=sh.cleat.role=gateway --format '{{.Names}}'
  expect_line "the gateway stays behind" "${g:-cleat-gw-000000000000}"
  dk -- volume ls -q --filter label=sh.cleat.role=egress-sock
  expect_line "the socket volume stays behind" "${v:-cleat-gw-000000000000-sock}"
  p32_exit eg-old exit-2.24down
  clt --as cleatup -T 300 -- rm
  expect_contains "cleatup rm removes the box" "Removed ${P32_OLD:-cleat-eg-old-00000000}."   # bin/cleat:23064
  dk -- ps -aq --filter "name=^${g:-cleat-gw-000000000000}\$"
  expect_count "the gateway is gone" '.' eq 0
  dk -- volume ls -q --filter "name=^${v:-cleat-gw-000000000000-sock}\$"
  expect_count "the socket volume is gone" '.' eq 0
  record_value upgrade.down "recreated on a normal network by v1.5.4, the gateway and the volume stayed until cleatup rm" "the downgrade"
}

# Re-entry: every part checks first (no box, no UPX, no mt-spec6, no v1.5.4 image are all fine).
st_2_24_clean() {
  local c="" g="" v="" have=""
  p32_cd eg-old
  val c -t 60 -- cn eg-old
  if [ -n "$c" ]; then
    val g -t 60 -- gw eg-old
    val v -t 60 -- vol eg-old
    [ -n "$g" ] || g=$(kv_get p32.old.gw "")
    [ -n "$v" ] || v=$(kv_get p32.old.vol "")
    p32_exit eg-old exit-2.24clean
    clt --as cleatup -T 300 -- rm
    expect_contains "cleatup rm removes eg-old" "Removed $c."   # bin/cleat:23064
  else
    check_note "no eg-old box (2.24-down or an earlier attempt removed it)"
  fi
  if [ -n "$g" ]; then
    dk -- ps -aq --filter "name=^$g\$"
    expect_count "eg-old's gateway is gone" '.' eq 0
  fi
  if [ -n "$v" ]; then
    dk -- volume ls -q --filter "name=^$v\$"
    expect_count "eg-old's socket volume is gone" '.' eq 0
  fi
  cd "$P" || cd "$HOME" || true
  safe_rm "$UPX" "$CLEAT_V154"
  p32_image_candidate
  if p32_dry || run_cmd -q -t 60 -- p32_img_id "$MT_IMAGE:mt-spec6"; then
    if [ "$P32_TREE" = 1 ] || p32_dry; then
      img_rm "$MT_IMAGE:mt-spec6"
      expect_rc "docker rmi $MT_IMAGE:mt-spec6" 0
    fi
  fi
  val have -t 60 -- p32_spec "$MT_IMAGE"
  expect_eq "$MT_IMAGE reads spec 6" "$have" 6
  run_cmd -t 600 -- egimg
  expect_contains "egimg: the relay is this tree's" "relay: this tree's"
  expect_contains "egimg: the entrypoint is this tree's" "entrypoint: this tree's"
  if p32_dry || run_cmd -q -t 60 -- p32_img_id ghcr.io/cleatdev/cleat:v1.5.4; then
    img_rm ghcr.io/cleatdev/cleat:v1.5.4
    if [ "$RC" != 0 ]; then
      check_note "docker rmi ghcr.io/cleatdev/cleat:v1.5.4 failed ($(head -n 1 "$OUT" 2>/dev/null)): a container still uses it (a daily box may). It is left. Rule 3 stands: answer n to Refresh the image now?"
    else
      check_pass "the v1.5.4 image is removed"
    fi
  fi
  kv_set image.swapped 0
  case "$(t_mode)" in
    typed)
      t_ensure t1
      t_run t1 "" "unset -f cleatup cleat154"
      p32_sleep 21 "the typed answerer of that line ends before T1 is used again" ;;
    human) say_do T1 "unset -f cleatup cleat154" ;;
  esac
}

# ---------------------------------------------------------------------------------------------
# 2.25 A real Claude Code session through the core pack, then after a live account switch
# ---------------------------------------------------------------------------------------------

# Re-entry: a policy that is the core pack already denies nothing more.
st_2_25a() {
  local st packs hosts p h
  p32_cd eg-core make
  if [ "$(kv_get image.swapped 0)" = 1 ]; then
    # 2.24-clean was skipped or cut: guard_image trusts the swap mark, so the candidate goes back here.
    check_note "the v1.5.4 swap of 2.24 is still marked (2.24-clean did not finish): the candidate image goes back first"
    p32_image_candidate
  fi
  cl -- egress status
  st="$OUT"
  grep_lines '^  (Packs|Hosts):'
  expect_match "status has a Packs: row" '^  Packs: '     # bin/cleat:14512
  expect_match "status has a Hosts: row" '^  Hosts: '     # bin/cleat:14530
  if ! p32_dry && ! LC_ALL=C grep -q '^  Packs: ' "$st"; then step_abort "cleat egress status shows no Packs: row: the global policy is not strict"; fi
  packs=$(p32_row_items Packs "$OUT")
  hosts=$(p32_row_items Hosts "$OUT")
  say "    packs to deny: ${packs:-none}. hosts to deny: ${hosts:-none}"
  for p in $packs; do
    clt -T 300 -- egress deny "$p"
    expect_rc "cleat egress deny $p exits 0" 0
    expect_match "the pack $p is denied whole" "(pack $(p32_ere "$p") removed|the hosts of pack $(p32_ere "$p") denied)"   # bin/cleat:14234, 14242
    if ! p32_dry && ! LC_ALL=C grep -q "pack $p removed" "$OUT"; then check_note "$p was not listed in the global file, so its hosts were denied one by one"; fi
  done
  if [ -n "$hosts" ]; then
    # shellcheck disable=SC2086
    clt -T 300 -- egress deny $hosts
    expect_rc "cleat egress deny $hosts exits 0" 0
    for h in $hosts; do expect_contains "$h denied" "$h denied"; done   # bin/cleat:14258
  fi
  record_value step25.denied "packs: ${packs:-none}. hosts: ${hosts:-none}" "what 2.25a denied"
  cl -- egress --list
  expect_count "nothing but five hosts is left" '^    [a-z0-9]' eq 5   # bin/cleat:14299
  expect_count "the five are the core pack's" '^    (api\.anthropic\.com|claude\.ai|claude\.com|code\.claude\.com|platform\.claude\.com) ' eq 5
}

# Re-entry: the pin and the box are taken as they are, a login already there may be kept.
st_2_25b() {
  local c="" net="" i=0
  p32_cd eg-core
  if ! p32_dry && run_cmd -q -t 90 -- box_claude_live eg-core; then
    check_note "a Claude session is open in eg-core (an earlier attempt): it ends first (the pin is made with no session open)"
    p32_exit eg-core exit-2.25b-pre
  fi
  clt -T 300 -- account lab-a
  expect_rc "cleat account lab-a exits 0" 0
  expect_contains "the box is pinned to lab-a" "✔ main is now on account lab-a"   # bin/cleat:31620
  val c -t 60 -- cn eg-core
  if [ -z "$c" ] || p32_dry; then
    clt -T 900 -- run
    expect_rc "cleat run exits 0 (the caged box, no session)" 0
  elif ! run_cmd -q -t 60 -- box_running eg-core; then
    check_note "the eg-core box exists stopped (an earlier attempt): cleat run creates it again"
    clt -T 900 -- run
    expect_rc "cleat run exits 0" 0
  else
    check_note "the eg-core box runs already (an earlier attempt)"
  fi
  val net -t 60 -- box_netmode eg-core
  expect_eq "the eg-core box is caged (network none)" "$net" none
  while :; do
    i=$((i + 1))
    cl -- egress status
    if p32_dry || p32_shim_ok "$OUT" || [ "$i" -ge 6 ]; then break; fi
    p32_sleep 10 "the relay's first heartbeat"
  done
  first_lines 6
  expect_contains "status: ● Gateway healthy" "● Gateway healthy"   # bin/cleat:14647
  expect_contains "status: ● Shim listening" "● Shim listening"     # bin/cleat:14698
  if t_is_auto; then
    step_skip "T1 simulated: no browser sign-in without a human (2.25c, 2.25d and 2.25e skip too, 2.14-acct runs its automated pass)"
  fi
  p32_login lab-a auth-2.25b
}

# Re-entry: a session already open in eg-core is used as it is (the items are asked again).
st_2_25c() {
  local pin="" msg="" items="" r=9
  p32_cd eg-core
  if t_is_auto; then step_skip "T1 simulated: no Claude conversation"; fi
  p32_need_login lab-a
  val pin -t 30 -- p32_pin
  if ! p32_dry && [ "$pin" != lab-a ]; then
    check_note "eg-core is pinned to ${pin:-nothing}: back to lab-a first (no session open)"
    p32_exit eg-core exit-2.25c-pre
    clt -T 300 -- account lab-a
    expect_contains "the box is pinned to lab-a" "✔ main is now on account lab-a"   # bin/cleat:31620
  fi
  if ! p32_dry && run_cmd -q -t 90 -- box_claude_live eg-core; then
    check_note "Claude Code is already open in eg-core (an earlier attempt): the items are asked in that session"
  else
    p32_launch eg-core cleat launch-2.25c "+Egress:     strict  ·  5 hosts, 1 pack"   # bin/cleat:12331
    if ! p32_dry && [ "$P32_LRC" != 0 ]; then step_abort "Claude Code did not open in eg-core"; fi
  fi
  p32_ask status-login T1 "Click T1. In Claude Code there type /status and press Enter. Read which login it names, then press Esc. Never type the login here." "/status names the login you signed in with for lab-a." "Does /status name the login of lab-a?"
  items="status:$(p32_word $?)"
  p32_ask bash-ls T1 "Click T1. In Claude Code there send:
Use the Bash tool to run ls -la and tell me how many entries there are." "Claude runs ls -la through the Bash tool and answers with a count." "Did the tool turn work?"
  items="$items bash:$(p32_word $?)"
  p32_ask webfetch T1 "Click T1. In Claude Code there send:
Use the WebFetch tool to fetch https://code.claude.com/docs/en/network-config and list the hostnames it names." "WebFetch fetches the page and Claude lists the hostnames it names." "Did the WebFetch work?"
  items="$items webfetch:$(p32_word $?)"
  p32_ask mcp T1 "Click T1. In Claude Code there type /mcp and press Enter, then Esc." "No claude.ai connector is listed: ENABLE_CLAUDEAI_MCP_SERVERS=false turns them off. A local stdio server would still show." "Does /mcp list no claude.ai connector?"
  items="$items mcp:$(p32_word $?)"
  p32_ask_record mcp-account T1 "" "Does this account have claude.ai connectors of its own (so their absence above means something)? y = it has some, n = it has none."
  # c.5 and c.6: with T1's text in reach (typed mode) the script reads the refusal and the tool
  # list itself and records the message. It asks only when T1 never shows them.
  r=9
  if t_have_capture && { p32_dry || p32_t1_text; }; then
    say_do T1 "Click T1. In Claude Code there start Remote Control: /remote-control, or the command /help lists for it.
The script reads Claude Code's answer from T1."
    wait_for remote-control "Wait for Claude Code's answer in T1 (d once it has answered, s to skip)." --auto --timeout 120 --every 3 -- p32_rc_seen
    r=$?
    if [ "$r" = 2 ]; then
      items="$items remote-control:$(p32_word 2)"
    elif p32_dry || p32_rc_seen; then
      msg=$(LC_ALL=C grep -m 1 -e 'DISABLE_TELEMETRY' "$SCRATCH/p32-t1.txt" 2>/dev/null | LC_ALL=C sed -e 's/^[^A-Za-z0-9]*//' -e 's/[[:space:]]*$//' | redact)
      check_pass "[remote-control] Remote Control refused, naming DISABLE_TELEMETRY (read from T1)" "$msg"
      items="$items remote-control:$(p32_word 0)"
    else
      r=9
    fi
  fi
  if [ "$r" = 9 ]; then
    p32_ask remote-control T1 "Click T1. In Claude Code there start Remote Control: /remote-control, or the command /help lists for it." "It refuses, with a message that names DISABLE_TELEMETRY (telemetry off also turns off the feature flags it needs)." "Did Remote Control refuse, naming DISABLE_TELEMETRY?"
    items="$items remote-control:$(p32_word $?)"
    read_line remote-msg "Type the refusal message as Claude Code showed it (one line, no login names in it)." msg
  fi
  record_value g2.c.remote_msg "$msg" "the Remote Control refusal"
  r=9
  if t_have_capture && { p32_dry || p32_t1_text; }; then
    rm -f "$SCRATCH/p32-t1.txt.prev"
    say_do T1 "Click T1. In Claude Code there send:
List the names of the tools you can call, one per line.
The script reads the list from T1."
    wait_for tools "Wait for Claude Code's list in T1 (d once it has listed them, s to skip)." --auto --timeout 180 --every 3 -- p32_tools_seen
    r=$?
    if [ "$r" = 2 ]; then
      items="$items tools:$(p32_word 2)"
    elif p32_dry || p32_tools_listed; then
      if ! p32_dry && LC_ALL=C grep -q -e 'Artifact' "$SCRATCH/p32-t1.txt"; then
        # A word in Claude's answer is not yet a tool in its list: you judge that one.
        check_note "T1's answer after the question names Artifact: $(LC_ALL=C grep -m 1 -e 'Artifact' "$SCRATCH/p32-t1.txt" | LC_ALL=C sed 's/^[^A-Za-z0-9]*//')"
        r=9
      else
        check_pass "[tools] no Artifact tool among the tools Claude Code lists (W7, read from T1)" "$(awk 'NF { n++ } END { print n + 0 }' "$SCRATCH/p32-t1.txt" 2>/dev/null) lines after the question, Bash and WebFetch among them"
        items="$items tools:$(p32_word 0)"
      fi
    else
      r=9
    fi
  fi
  if [ "$r" = 9 ]; then
    p32_ask tools T1 "Click T1. In Claude Code there send:
List the names of the tools you can call, one per line." "No Artifact tool among them (CLAUDE_CODE_DISABLE_ARTIFACT=1)." "Is there no Artifact tool in the list?"
    items="$items tools:$(p32_word $?)"
  fi
  record_value g2.c.items "$items" "2.25c items 1 to 6"
  p32_exit eg-core exit-2.25c \
    "-http-intake.logs.us5.datadoghq.com" \
    "-browser-intake-us5-datadoghq.com" \
    "-mcp-proxy.anthropic.com"
  cl -- egress log
  p32_g2_log c
  p32_debug_read c
  rec_set g2a "the first leg: login through the cage, a tool turn ($(printf '%s' "$items" | awk '{ for (i = 1; i <= NF; i++) if ($i ~ /^bash:/) print substr($i, 6) }')), a WebFetch ($(printf '%s' "$items" | awk '{ for (i = 1; i <= NF; i++) if ($i ~ /^webfetch:/) print substr($i, 10) }')), denied hosts: $P32_G2_HOSTS, spec 7.3 hosts denied: $P32_G2_73, W7 hosts: $P32_G2_W7, debug log: $P32_DEBUG, Claude Code $(kv_get image.claude unknown)"
}

# Re-entry: a session left open is ended first, then the leg runs from the switch to lab-b.
st_2_25d() {
  local pids0="" r items=""
  p32_cd eg-core
  if t_is_auto; then step_skip "T1 simulated: no Claude conversation and no second sign-in"; fi
  p32_need_login lab-a
  if ! p32_dry && run_cmd -q -t 90 -- box_claude_live eg-core; then
    check_note "a Claude session is open in eg-core: it ends first (the second login is made with no session open)"
    p32_exit eg-core exit-2.25d-pre
  fi
  clt -T 300 -- account lab-b
  expect_rc "cleat account lab-b exits 0" 0
  expect_contains "the box is pinned to lab-b" "✔ main is now on account lab-b"   # bin/cleat:31620
  p32_login lab-b auth-2.25d
  clt -T 300 -- account lab-a
  expect_rc "cleat account lab-a exits 0" 0
  expect_contains "the box is back on lab-a" "✔ main is now on account lab-a"   # bin/cleat:31620
  p32_launch eg-core cleat launch-2.25d "+Egress:     strict  ·  5 hosts, 1 pack"   # bin/cleat:12331
  if ! p32_dry && [ "$P32_LRC" != 0 ]; then step_abort "Claude Code did not open in eg-core"; fi
  p32_ask hello T1 "Click T1. In Claude Code there send:
reply with just ok
Wait until it has answered and sits idle (no spinner, no question), then leave it alone." "Claude answers ok and waits idle." "Did Claude answer? Is it idle now?"
  val pids0 -t 60 -- p32_claude_pids eg-core
  say "The script switches the box to lab-b now, with the session open in T1. Watch T1."
  clt --answer handoff=y -T 300 -- account lab-b
  expect_rc "cleat account lab-b exits 0" 0
  expect_contains "the disclosure names the live session" "main has a live Claude session in another terminal"   # bin/cleat:30862
  expect_contains "the disclosure says what happens" "Handing it over to lab-b restarts it there and reopens the same conversation."   # bin/cleat:30870
  expect_num "one question: Hand over? [Y/n]" "$(xfired handoff)" eq 1   # bin/cleat:30829
  expect_contains "the switch landed" "✔ main is now on account lab-b"   # bin/cleat:31022
  expect_contains "the other terminal reopens" "The session in the other terminal is reopening on lab-b."   # bin/cleat:31024
  wait_for reopen "Watch T1: it says the other terminal is switching, then Claude Code reopens by itself on the same conversation." --auto --timeout 180 --every 2 -- p32_reopened eg-core "$pids0"
  r=$?
  if [ "$r" = 0 ]; then check_pass "Claude Code reopened in eg-core by itself (a new process)"; else check_fail "Claude Code reopened in eg-core by itself" "a new Claude Code process within 180 s" "none"; fi
  p32_ask status-login-b T1 "Click T1. In Claude Code there type /status and press Enter. Read which login it names, then press Esc. Never type the login here." "/status names the second login (lab-b's)." "Does /status name the login of lab-b?"
  items="status:$(p32_word $?)"
  p32_ask bash-ls-b T1 "Click T1. In Claude Code there send:
Use the Bash tool to run ls -la and tell me how many entries there are." "Claude runs ls -la through the Bash tool and answers with a count." "Did the tool turn work?"
  items="$items bash:$(p32_word $?)"
  p32_ask webfetch-b T1 "Click T1. In Claude Code there send:
Use the WebFetch tool to fetch https://code.claude.com/docs/en/network-config and list the hostnames it names." "WebFetch fetches the page and Claude lists the hostnames it names." "Did the WebFetch work?"
  items="$items webfetch:$(p32_word $?)"
  record_value g2.d.items "$items" "2.25d items 1 to 3 after the switch"
  p32_exit eg-core exit-2.25d \
    "-http-intake.logs.us5.datadoghq.com" \
    "-browser-intake-us5-datadoghq.com" \
    "-mcp-proxy.anthropic.com"
  cl -- egress log
  if [ -f "$SCRATCH/p32-g2-c.full" ]; then
    p32_g2_log d "$SCRATCH/p32-g2-c.full"
  else
    check_note "no reading of the log from 2.25c in this run: the whole log counts for this leg"
    p32_g2_log d
  fi
  # G2 needs the debug log read back for this leg too (5.2's second G2 line: "the same"). It also
  # stores acct.sid.d, the id 3.5 finds this session's debug file by.
  p32_debug_read d
  rec_set g2b "after a live account switch: the second login through the cage, the session reopened by itself ($( [ "$r" = 0 ] && printf yes || printf no)), items $items, denied hosts: $P32_G2_HOSTS, spec 7.3 hosts denied: $P32_G2_73, W7 hosts: $P32_G2_W7, debug log: $P32_DEBUG, Claude Code $(kv_get image.claude unknown)"
}

# Re-entry: nothing is acted on, so it runs again as it is.
st_2_14_acct() {
  local n="" before after tr r
  p32_cd eg-core
  val n -t 30 -- p32_acct_count
  if ! p32_dry && [ "${n:-0}" = 0 ]; then step_skip "no named account yet: cleat account prints a hint instead of a picker (2.25b makes lab-a)"; fi
  before=$(p32_acct_state)
  hdr "cleat account: the chords, then lab-a's action menu"
  p32_pk_begin 'Claude accounts'
  p32_pk_chords acc
  P32_KN=$((P32_KN + 1)); xp_mark "k$P32_KN"; xp_send "<enter>"
  xp_wait amenu 'choose  q back' 20
  xp_wait dam '\x1b\[[0-9]+A' 10
  xp_sleep 300
  xp_snap am-open
  p32_pk_chords am
  P32_KN=$((P32_KN + 1)); xp_mark "k$P32_KN"; xp_send "<esc>"
  xp_wait back 'switch or edit  q close' 20
  xp_wait dbk '\x1b\[[0-9]+A' 10
  xp_sleep 300
  xp_snap am-back
  xp_send "<esc>"; xp_wait cancel 'Cancelled\.' 15; xp_eof 30
  clt --prog -n accounts -T 300 -- account
  tr="$OUT"
  xsnap acc-optl
  p32_quiet_match "the picker draws the shared login first" ' default '   # bin/cleat:32065
  p32_pk_check "cleat account" acc
  xsnap acc-down
  p32_quiet_match "down moved to lab-a" '▸[^a-z]*lab-a( |$)'   # bin/cleat:32247
  xsnap am-open
  p32_quiet_match "Enter on lab-a opens its action menu" '^  lab-a$'   # bin/cleat:32370
  p32_quiet_match "the menu's first row" 'Use here'   # bin/cleat:32323
  p32_quiet_match "the menu's legend" '↑/↓ move  ⏎ choose  q back'   # bin/cleat:32377
  p32_pk_check "lab-a's action menu" am
  xsnap am-down
  p32_quiet_match "down moved to Rename (never chosen)" '▸ Rename'
  xsnap am-back
  p32_quiet_match "Esc backs out to the list" '↑/↓ move  ⏎ switch or edit  q close'   # bin/cleat:32316
  expect_count "the second Esc closes it: ▸ Cancelled. once" '▸ Cancelled\.' eq 1 "$tr"   # bin/cleat:32610
  after=$(p32_acct_state)
  expect_eq "nothing was acted on (accounts, trash and pins unchanged)" "$after" "$before"
  if t_is_auto; then
    check_skip "the accounts picker with real keys" "T1 simulated: needs the real keyboard"
    return 0
  fi
  while :; do
    t_run t1 eg-core "cleat account"
    ask acct-keys T1 "Click T1 (cleat account) and press Option+Left, then Option+Right, then Page Up (fn+Shift+↑ in Terminal.app), then the down arrow once (to lab-a), then Enter: lab-a's action menu opens. There press Option+Left, Option+Right, Page Up, the down arrow once, then Esc (back to the list), then Esc again. Never Enter in the action menu, never space." \
      "The chords do nothing anywhere, the down arrow moves one row, the first Esc backs out of the menu, the second prints ▸ Cancelled. Nothing switched, renamed or removed." "Did the accounts picker and its menu behave as described?"
    r=$?; [ "$r" = 5 ] || break
  done
  record_value c46.accounts_keys "$(p32_word "$r")" "the accounts picker with real keys in Terminal.app"
  after=$(p32_acct_state)
  expect_eq "the real-key pass acted on nothing" "$after" "$before"
}

# EXTRA. Re-entry: the deny file is written again and removed at the end (also the cleanup).
st_2_25e() {
  p32_cd eg-core
  if t_is_auto; then step_skip "T1 simulated: no Claude conversation"; fi
  if ! p32_dry && run_cmd -q -t 90 -- box_claude_live eg-core; then
    check_note "a Claude session is open in eg-core: it ends first (the deny must be read at the start)"
    p32_exit eg-core exit-2.25e-pre
  fi
  mkdir -p "$P/eg-core/.claude" || step_abort "cannot create $P/eg-core/.claude"
  on_cleanup "safe_rm $(printf '%q' "$P/eg-core/.claude")"
  printf '{"permissions":{"deny":["WebSearch"]}}\n' > "$P/eg-core/.claude/settings.json" || step_abort "cannot write the deny"
  check_pass "the project denies WebSearch ($P/eg-core/.claude/settings.json)"
  p32_launch eg-core cleat launch-2.25e
  p32_ask_record websearch T1 "Click T1. In Claude Code there send:
Search the web for the latest Docker Desktop release and give me its version." "Was the WebSearch tool unavailable (Claude said it cannot search the web, or answered another way)?"
  record_value g2.e.websearch "$(p32_word $?)" "y: the tool was unavailable"
  p32_exit eg-core exit-2.25e
  safe_rm "$P/eg-core/.claude"
}

# ---------------------------------------------------------------------------------------------
# 2.26 Another engine refuses (EXTRA)
# ---------------------------------------------------------------------------------------------
# Re-entry: the image question is answered n every time. A run that pulled the image says so.
st_2_26() {
  local list="" other="" had="" n opts=() o
  run_cmd -t 60 -- p32_ctx_candidates
  list=$(cat "$OUT" 2>/dev/null)
  if p32_dry; then other=dry-context
  elif [ -z "$list" ]; then step_skip "no OrbStack or Colima context in docker context ls"
  else
    n=$(printf '%s\n' "$list" | awk 'NF { n++ } END { print n + 0 }')
    if [ "$n" = 1 ]; then other="$list"
    else
      for o in $list; do opts[${#opts[@]}]="$o=the $o context"; done
      choose other-ctx "Which other engine?" ${opts[@]+"${opts[@]}"}
      other="$CHOICE"
    fi
  fi
  say "    the other engine's context: $other"
  # A stopped engine answers nothing. Status would then say Docker is not running.
  if ! p32_dry && ! run_cmd -q -t 60 -- p32_ctx_up "$other"; then
    wait_for "ctx-up" "Start that engine (OrbStack or Colima, the context $other) and wait until it runs. Docker Desktop stays as it is." --timeout 600 --every 5 -- p32_ctx_up "$other"
    if [ $? != 0 ] || ! run_cmd -q -t 60 -- p32_ctx_up "$other"; then step_skip "the $other engine is not running"; fi
  fi
  run_cmd -t 120 -- p32_ctx "$other" image ls "$MT_IMAGE" --format '{{.Repository}}:{{.Tag}}'
  if [ "$RC" = 0 ] && [ -s "$OUT" ]; then had=yes; else had=no; fi
  record_value step26.had_image "$had" "the other engine had a $MT_IMAGE image before"
  p32_cd eg-other make
  cl --env "DOCKER_CONTEXT=$other" -- egress status
  first_lines 3
  if ! p32_dry && ! LC_ALL=C grep -q 'not available on' "$OUT"; then
    cd "$P" || true
    safe_rm "$P/eg-other"
    if LC_ALL=C grep -q 'Docker is not running' "$OUT"; then
      step_skip "cleat egress status found no Docker on $other (bin/cleat:14471): start that engine, then run 2.26 again"
    fi
    check_note "DOCKER_CONTEXT=$other is not honoured: cleat egress status speaks of Docker Desktop. The scenario's fallback, docker context use, changes Docker for every terminal, so the script never runs it"
    step_skip "DOCKER_CONTEXT is not honoured: run 2.26 by hand with docker context use $other, then docker context use back"
  fi
  expect_contains "status: not available on a Docker engine inside a VM" "x Egress control is not available on a Docker engine inside a VM (Colima, Lima, OrbStack, Rancher Desktop)"   # bin/cleat:14475, 10954
  say "cleat run on $other: every image question is answered n. A first run there pulls the v1.5.4 image (about a gigabyte)."
  clt --env "DOCKER_CONTEXT=$other" -T 1800 -- run
  expect_rc "cleat run exits 1" 1
  expect_contains "the refusal" "✖ Egress control is not available on this Docker engine"   # bin/cleat:10986
  expect_contains "Needed: the validated engines" "$(p32_needed)"   # bin/cleat:10989
  expect_contains "both ways forward" "Two ways forward:"   # bin/cleat:10998
  expect_contains "cleat egress off is named" "Run without egress control: cleat egress off gives this box"   # bin/cleat:11000
  n=$(( $(xfired img-refresh) + $(xfired img-update) + $(xfired img-refresh-recreate) ))
  expect_num "no image question before the refusal" "$n" eq 0
  p32_ed_begin
  xp_snap ed
  xp_send "q"
  xp_wait ns 'Nothing saved' 20
  xp_eof 30
  clt --prog -n other-editor -T 300 --env "DOCKER_CONTEXT=$other" -- egress
  xsnap ed
  expect_match "the editor warns" '! A caged box will not start on this engine: '   # bin/cleat:15347
  run_cmd -t 120 -- p32_ctx "$other" ps -a --format '{{.Names}}'
  expect_count "no eg-other container on that engine" '^cleat-eg-other-' eq 0
  cd "$P" || true
  safe_rm "$P/eg-other"
  if [ "$had" = no ] && ! p32_dry; then
    p32_ask_record ctx-rmi T2 "This run pulled the image into $other. In another terminal run:
DOCKER_CONTEXT=$other docker rmi $MT_IMAGE ghcr.io/cleatdev/cleat:v1.5.4" "Did the rmi remove both from that engine?"
  fi
  record_value step26.result "refused on $other: not available, $(p32_needed), no image question, the editor warns" "the other engine"
}

# ---------------------------------------------------------------------------------------------
# 2.27 Off for every box, then on again through cleat config
# ---------------------------------------------------------------------------------------------

# Re-entry: a global policy already off (an earlier attempt saved it) is a SKIP with that reason.
st_2_27a() {
  local ids="" ide="" ids2="" ide2="" cs="" ce="" tr
  p32_cd eg-smoke
  cl -- egress --list
  if ! p32_dry && LC_ALL=C grep -q '^  Mode:     off' "$OUT"; then
    step_skip "the global policy is off already (an earlier attempt saved it): its checks stand in that attempt"   # bin/cleat:14290
  fi
  # Two presses of the right arrow reach off only from strict (the ring is strict, open, off).
  if ! p32_dry && ! LC_ALL=C grep -q '^  Mode:     strict' "$OUT"; then
    step_abort "the global mode is not strict ($(LC_ALL=C grep -m 1 '^  Mode:' "$OUT" 2>/dev/null | sed 's/^ *//')): 2.27a starts from the strict core pack 2.25a left"   # bin/cleat:14294
  fi
  val cs -t 60 -- cn eg-smoke
  val ce -t 60 -- cn eg-core
  val ids -t 60 -- box_id eg-smoke
  val ide -t 60 -- box_id eg-core
  kv_set p32.boxid.eg-smoke "$ids"; kv_set p32.boxid.eg-core "$ide"
  p32_ed_begin
  p32_ed_key "<right>" open1
  p32_ed_key "<right>" off1
  xp_mark save
  xp_send "<enter>"
  xp_wait turnoff 'Turning egress control off for every new box on this machine' 60
  xp_wait question 'Turn egress control off for every new box\? \[y/N\]' 180
  xp_wait saved 'egress control is off for every new box\.' 60
  xp_eof 60
  clt --prog -n global-off -T 600 --answer eg-off-all=y -- egress
  tr="$OUT"
  expect_rc "cleat egress exits 0" 0
  xsnap off1
  expect_match "the Mode row reads off" '‹ off ›'
  OUT="$tr"
  expect_contains "the review: Turning egress control off for every new box on this machine" "! Turning egress control off for every new box on this machine"   # bin/cleat:13563
  expect_match "the caged boxes are listed under the policy line" '(1 box was created under a policy\. A session already open in it|[0-9]+ boxes were created under a policy\. A session already open in one)'   # bin/cleat:13572, 13574
  expect_contains "each refuses until recreated" "stays caged, but each box refuses to start, attach or relaunch until"   # bin/cleat:13576
  expect_contains "with cleat egress off" "you recreate it with cleat egress off."   # bin/cleat:13577
  if [ -n "$cs" ]; then expect_contains "eg-smoke's box is listed" "$cs"; else check_note "no eg-smoke box exists, so the review cannot list it (the scenario expects it)"; fi
  if [ -n "$ce" ]; then expect_contains "eg-core's box is listed" "$ce"; else check_note "no eg-core box exists, so the review cannot list it (the scenario expects it)"; fi
  expect_num "the review paged with More below (space, never q)" "$(xfired eg-more)" ge 1   # bin/cleat:17418
  expect_num "the question was asked once" "$(xfired eg-off-all)" eq 1   # bin/cleat:17318
  expect_contains "saved: off for every new box" "✔ Saved to $(p32_tilde "$CFG/config"): egress control is off for every new box."   # bin/cleat:13674
  val ids2 -t 60 -- box_id eg-smoke
  val ide2 -t 60 -- box_id eg-core
  expect_eq "eg-smoke's box was not recreated" "$ids2" "$ids"
  expect_eq "eg-core's box was not recreated" "$ide2" "$ide"
}

# Re-entry: nothing is created, so it runs again as it is. It needs 2.27a's global off: under a
# policy that resolves, cleat would open Claude on the script's own pty.
st_2_27b() {
  local net=""
  p32_cd eg-smoke
  cl -- egress --list
  if ! p32_dry && ! LC_ALL=C grep -q '^  Mode:     off' "$OUT"; then
    step_skip "the global policy is not off ($(LC_ALL=C grep -m 1 '^  Mode:' "$OUT" 2>/dev/null | sed 's/^ *//')): 2.27b needs 2.27a's global off, run 2.27a first"   # bin/cleat:14290
  fi
  if ! p32_dry && run_cmd -q -t 90 -- box_claude_live eg-smoke; then
    check_note "a Claude session is open in eg-smoke: it ends first"
    p32_exit eg-smoke exit-2.27b-pre
  fi
  say "cleat in eg-smoke on the script's own pty: refused before Claude opens. Any recreate question is answered n (and counted)."
  clt --rule w1 'Recreate \S+ now\? \[Y/n\]' 'n<enter>' -T 600 --
  expect_rc "cleat exits 1" 1
  expect_num "no recreate question" "$(xfired w1)" eq 0
  expect_num "no recreate offer under the policy either" "$(xfired recreate-policy)" eq 0
  expect_contains "the refusal: no longer resolves" "✖ Egress refused box main: it was created under an egress policy that no longer resolves."   # bin/cleat:11790
  expect_contains "its fix names cleat egress off" "Fix:  cleat egress off recreates it with a normal network, or restore the [egress] section"   # bin/cleat:11791
  val net -t 60 -- box_netmode eg-smoke
  expect_eq "eg-smoke is still on none" "$net" none
}

# Re-entry: an [egress] already strict shows the strict row: SKIP with that reason (the writes of
# this step happened in an earlier attempt).
st_2_27c() {
  local k=0 i=0 want=0 ncaps=0 due="" tr="" snaps="" s="" n="" bmaj=""
  p32_cd eg-smoke
  cl -- egress --list
  if ! p32_dry && ! LC_ALL=C grep -q '^  Mode:     off' "$OUT"; then
    step_skip "the global policy is not off (an earlier attempt turned it on): run 2.27a first to repeat this"
  fi
  if p32_eg_entries "$CFG/config"; then
    due="Egress control is on, with the Claude Code hosts and the packs and hosts already saved."   # bin/cleat:17819
  else
    due="Egress control is on, with the Claude Code hosts and nothing else."   # bin/cleat:17821
  fi
  say "    the message due: $due"
  ncaps=$(sed -n 's/^KNOWN_CAPS=(\(.*\))$/\1/p' "$MT_WT/bin/cleat" | head -n 1 | awk '{ print NF }')
  want=$(( ${ncaps:-0} + 2 ))   # caps, memory, cpus, then Egress (bin/cleat:33606)
  hdr "find the Egress row (moves and Esc only)"
  p32_pk_begin 'Cleat config'
  i=1
  while [ "$i" -le 12 ]; do p32_pk_key "<down>" "cfind-$i"; snaps="$snaps cfind-$i"; i=$((i + 1)); done
  xp_send "<esc>"; xp_wait c1 'Cancelled\.' 15; xp_eof 30
  clt --prog -n config-find -T 300 -- config
  # shellcheck disable=SC2086
  p32_w12_check "cleat config at 80 columns" $snaps
  if p32_dry; then
    k="$want"
  else
    i=1
    while [ "$i" -le 12 ]; do
      xsnap "cfind-$i"
      if LC_ALL=C grep -q -E -e '▸ \[[^]]*\] Egress ' "$OUT"; then k="$i"; break; fi
      i=$((i + 1))
    done
  fi
  expect_eq "the Egress row is $want rows down (after the $ncaps capabilities, memory and cpus)" "$k" "$want"
  if ! p32_dry && [ "$k" != "$want" ]; then step_abort "the Egress row was not where the code puts it: nothing was pressed on it"; fi
  xsnap "cfind-$k"
  expect_match "the Egress row reads off" '\[·\] Egress  off      new boxes reach your whole network$'   # bin/cleat:17760, 33614
  expect_order "the Egress row sits under Resources" "Resources" "Egress  off"
  hdr "on again: space and Enter on the Egress row, then q in the editor"
  p32_pk_begin 'Cleat config'
  i=1
  while [ "$i" -le "$k" ]; do p32_pk_key "<down>" "cact-$i"; i=$((i + 1)); done
  p32_pk_key "<space>" cact-space
  xp_mark save
  xp_send "<enter>"
  xp_wait saved 'Saved to' 60
  xp_wait choose 'Choose what boxes on this machine may reach on the next screen\.' 120
  xp_wait edopen 'Cleat egress' 120
  xp_wait edframe '\x1b\[J' 30
  xp_sleep 500
  xp_snap editor
  xp_send "q"
  xp_wait cancel 'Egress control is on with the Claude Code hosts only\.' 60
  xp_eof 60
  clt --prog -n config-on -T 600 -- config
  tr="$OUT"
  xsnap "cact-$k"
  expect_match "the cursor is on the Egress row" '▸ \[·\] Egress  off'
  xsnap cact-space
  expect_match "space: strict on save, then choose the hosts" '\[✔\] Egress  strict   on save, then choose the hosts'   # bin/cleat:17774
  # shellcheck disable=SC2046
  p32_w12_check "cleat config while acting" $(i=1; while [ "$i" -le "$k" ]; do printf 'cact-%s ' "$i"; i=$((i + 1)); done) cact-space
  OUT="$tr"
  # F4: one Enter, one Saved line: the editor's (bin/cleat:33734). The handoff prints none of its
  # own for the file the editor named (bin/cleat:17816). Its ~ form is bash 3.2's (departure 17).
  n=$(p32_count 'Saved to ' "$tr")
  [ "${DRY:-0}" = 1 ] || record_value step27c.saved "$n" "Saved to lines printed for the one Enter on the Egress row"
  expect_count "one Enter on the Egress row prints exactly one Saved to line (F4)" 'Saved to ' eq 1 "$tr"
  val bmaj -t 30 -- "$MT_BASH" -c 'printf "%s" "${BASH_VERSINFO[0]}"'
  if p32_dry || [ "$bmaj" = 3 ]; then
    expect_contains "Enter saves: ✔ Saved to ~/mt-egress-xdg/cleat/config, the ~ form of bash 3.2 (F4)" "✔ Saved to $(p32_tilde "$CFG/config")" "$tr"   # bin/cleat:33734
  elif LC_ALL=C grep -q -F -e "✔ Saved to $(p32_tilde "$CFG/config")" "$tr" 2>/dev/null || LC_ALL=C grep -q -F -e "✔ Saved to $CFG/config" "$tr" 2>/dev/null; then
    check_pass "Enter saves: ✔ Saved to the config, in the ~ form or (bash $bmaj tilde-expands it) the absolute one (F4)" "$(LC_ALL=C grep -m 1 -F -e '✔ Saved to' "$tr" 2>/dev/null)"   # bin/cleat:33734
  else
    check_fail "Enter saves: ✔ Saved to the config, in the ~ form or (bash $bmaj tilde-expands it) the absolute one (F4)" "✔ Saved to $(p32_tilde "$CFG/config")" "$(LC_ALL=C grep -m 1 -F -e 'Saved to' "$tr" 2>/dev/null)"
  fi
  OUT="$tr"   # val above moved OUT to its own output
  expect_contains "the message due" "$due"
  expect_contains "the next screen" "Choose what boxes on this machine may reach on the next screen."   # bin/cleat:17823
  OUT="$tr"
  note_check
  xsnap editor
  expect_match "the editor opened" 'Cleat egress'
  OUT="$tr"
  # q cancels the editor (bin/cleat:17053, _EGS_OUT empty), so the handoff prints the Cancelled form.
  # The variant without it follows only a save that had nothing to change (bin/cleat:17848).
  expect_contains "q: Cancelled. Egress control is on with the Claude Code hosts only." "Cancelled. Egress control is on with the Claude Code hosts only."   # bin/cleat:17850
  cl -- egress --list
  expect_match "the policy was written before the editor opened: strict" '^  Mode:     strict'   # bin/cleat:14294
  s=$(LC_ALL=C grep -E -e 'Saved to|Egress control is on|Choose what boxes|Cancelled\. Egress|Add what your boxes need' "$tr" 2>/dev/null | sed -e 's/^ *//' | head -n 8)
  p32_ask_record c-clear T2 "Read these lines, which cleat config printed:
$s" "Do they read clearly? The policy was written before the editor opened, so the cancel still leaves it on."
  hdr "cleat config --project has no Egress row"
  p32_pk_begin 'Cleat config'
  xp_snap proj
  xp_send "<esc>"; xp_wait c2 'Cancelled\.' 15; xp_eof 30
  clt --prog -n config-project -T 300 -- config --project
  xsnap proj
  expect_not_match "no Egress row in the project editor" '\] Egress '
  expect_match "the project scope" 'Scope: project'   # bin/cleat:33776
}

# Re-entry: the allow is written again (harmless). A session left open is ended first.
st_2_27d() {
  local net="" h
  p32_cd eg-smoke
  if ! p32_dry && run_cmd -q -t 90 -- box_claude_live eg-smoke; then
    check_note "a Claude session is open in eg-smoke: it ends first"
    p32_exit eg-smoke exit-2.27d-pre
  fi
  clt -T 300 -- egress allow example.com
  expect_rc "cleat egress allow example.com exits 0" 0
  expect_contains "Now strict, 6 hosts allowed" "Now strict, 6 hosts allowed, port 443 only."   # bin/cleat:14265
  cl -- egress --list
  expect_match "strict" '^  Mode:     strict'   # bin/cleat:14294
  expect_count "six hosts" '^    [a-z0-9]' eq 6
  for h in api.anthropic.com claude.ai claude.com code.claude.com platform.claude.com example.com; do
    expect_match "--list holds $h" "^    $(p32_ere "$h") "
  done
  say "T1 runs cleat in eg-smoke: caged again. Answer n to any recreate offer."
  p32_launch eg-smoke cleat launch-2.27d "+Egress:     strict  ·  "   # bin/cleat:12331
  val net -t 60 -- box_netmode eg-smoke
  expect_eq "eg-smoke is caged (none)" "$net" none
  p32_exit eg-smoke exit-2.27d
  clt -T 300 -- stop
  if ! p32_dry && LC_ALL=C grep -q 'Container not running' "$OUT"; then
    check_note "eg-smoke was already stopped"
  else
    expect_contains "cleat stop" "✔ Session ended. Resume with: cleat resume"   # bin/cleat:23039
  fi
}

# ---------------------------------------------------------------------------------------------
# 2.28 The idle sweep's gateway pass (EXTRA)
# ---------------------------------------------------------------------------------------------
# Re-entry: an existing box is kept, a running one is stopped raw again.
st_2_28a() {
  local d c="" s1="" s2="" g1="" g2="" st=""
  # The daily boxes running now: the sweep must never stop one (2.28c compares, by count only).
  run_cmd -q -t 60 -- p32_other_running
  cat "$OUT" > "$SCRATCH/p32-daily-before.txt" 2>/dev/null || : > "$SCRATCH/p32-daily-before.txt"
  for d in eg-sweep eg-sweep2; do
    p32_cd "$d" make
    val c -t 60 -- cn "$d"
    if [ -n "$c" ] && ! p32_dry; then check_note "the $d box exists (an earlier attempt)"; else clt -T 900 -- run; expect_rc "cleat run in $d exits 0" 0; fi
  done
  p32_cd eg-sweep
  for d in eg-sweep eg-sweep2; do
    if p32_dry || run_cmd -q -t 60 -- box_running "$d"; then box_rawstop "$d"; fi
  done
  val g1 -t 60 -- gw eg-sweep
  val g2 -t 60 -- gw eg-sweep2
  kv_set p32.sweep.gw1 "$g1"; kv_set p32.sweep.gw2 "$g2"
  dk -- inspect -f '{{.Name}} {{.State.Status}} {{.State.StartedAt}}' "${g1:-cleat-gw-000000000001}" "${g2:-cleat-gw-000000000002}"
  expect_count "both gateways keep running, orphaned" ' running ' eq 2
  s2=$(LC_ALL=C awk -v g="/$g2" '$1 == g { print $3 }' "$OUT" 2>/dev/null)
  record_value sweep.gw2_started "${s2:-unread}" "eg-sweep2's gateway StartedAt before the launch"
  p32_launch eg-sweep2 "CLEAT_NO_IDLE_SWEEP=0 CLEAT_IDLE_GRACE_MINS=1 cleat" launch-2.28a
  dk -- inspect -f '{{.Name}} {{.State.Status}} {{.State.StartedAt}}' "${g1:-cleat-gw-000000000001}" "${g2:-cleat-gw-000000000002}"
  st=$(LC_ALL=C awk -v g="/$g1" '$1 == g { print $2 }' "$OUT" 2>/dev/null)
  if p32_dry; then expect_eq "eg-sweep's gateway was stopped by the sweep" "" ""
  else expect_eq "eg-sweep's gateway was stopped by the sweep (exited)" "$st" exited; fi
  s1=$(LC_ALL=C awk -v g="/$g2" '$1 == g { print $2 " " $3 }' "$OUT" 2>/dev/null)
  if p32_dry; then expect_eq "eg-sweep2's gateway runs with the same StartedAt" "" ""
  else expect_eq "eg-sweep2's gateway still runs with the same StartedAt (reused)" "$s1" "running $s2"; fi
  p32_exit eg-sweep2 exit-2.28a
}

# Re-entry: the names come from kv when the box is gone already.
st_2_28b() {
  local g="" v="" bh c="" n
  p32_cd eg-sweep
  val c -t 60 -- cn eg-sweep
  if [ -n "$c" ]; then
    val g -t 60 -- gw eg-sweep
    val v -t 60 -- vol eg-sweep
    kv_set p32.sweep.gwa "$g"; kv_set p32.sweep.vola "$v"; kv_set p32.sweep.cna "$c"
  else
    g=$(kv_get p32.sweep.gwa ""); v=$(kv_get p32.sweep.vola ""); c=$(kv_get p32.sweep.cna "")
    [ -n "$g" ] || step_abort "no eg-sweep box and no names kept: run 2.28a first"
    check_note "the eg-sweep box is gone already (an earlier attempt removed it)"
  fi
  bh="${g#cleat-gw-}"
  say "    $g $v $bh"
  if p32_dry || run_cmd -q -t 60 -- p32_box_exists eg-sweep; then box_rawrm eg-sweep; fi
  if ! p32_dry && ! run_cmd -q -t 60 -- box_running eg-sweep2; then
    check_note "the eg-sweep2 box is not running: T1 opens and ends a session in it first (it then runs detached)"
    p32_launch eg-sweep2 cleat launch-2.28b-pre
    p32_exit eg-sweep2 exit-2.28b-pre
  fi
  xshell eg-sweep2 --env CLEAT_NO_IDLE_SWEEP=0 --env CLEAT_IDLE_GRACE_MINS=1 --
  dk -- ps -aq --filter "name=^${g:-cleat-gw-000000000001}\$"
  expect_count "the gateway with no box is removed" '.' eq 0
  dk -- volume ls -q --filter "name=^${v:-cleat-gw-000000000001-sock}\$"
  expect_count "its socket volume is removed" '.' eq 0
  run_cmd -t 30 -- ls "$CFG/egress-rendered/$bh"
  expect_contains "its rendered policy is removed" "No such file or directory"
  n=0
  [ -e "$CFG/egress-notices/$c" ] && n=$((n + 1))
  [ -e "$CFG/egress-pins/$c" ] && n=$((n + 1))
  record_value sweep.left "$n of 2 (egress-notices and egress-pins of the removed box stay: the sweep does not own them, 3.5 lists them)" "the box's own host files"
}

# Re-entry: the launch and the session are made again, the sweep then stops what is idle.
st_2_28c() {
  local st="" c2=""
  p32_launch eg-sweep2 cleat launch-2.28c
  p32_exit eg-sweep2 exit-2.28c
  p32_sleep 70 "the box idles past the one-minute grace (its run dir was stamped at the detach)"
  p32_cd eg-sweep
  clt --env CLEAT_NO_IDLE_SWEEP=0 --env CLEAT_IDLE_GRACE_MINS=1 -T 900 -- run
  expect_rc "cleat run in eg-sweep exits 0 (a fresh box)" 0
  expect_match "the sweep ran first: Stopped <n> idle session(s)" '▸ Stopped [0-9]+ idle session'   # bin/cleat:24311
  val c2 -t 60 -- cn eg-sweep2
  val st -t 60 -- docker inspect -f '{{.State.Status}}' "${c2:-cleat-eg-sweep2-00000000}"
  expect_eq "eg-sweep2 is stopped" "$st" exited
  val st -t 60 -- docker inspect -f '{{.State.Status}}' "$(kv_get p32.sweep.gw2 cleat-gw-000000000002)"
  expect_eq "its gateway is stopped with it" "$st" exited
  p32_daily_compare
}
# p32_daily_compare: the daily boxes that ran at 2.28a still run (counts only, never names).
p32_daily_compare() {
  local gone=0 n
  if [ ! -f "$SCRATCH/p32-daily-before.txt" ] || p32_dry; then check_skip "no daily box was stopped by the sweep" "no reading from 2.28a in this run"; return 0; fi
  run_cmd -q -t 60 -- p32_other_running
  n=$(LC_ALL=C comm -23 "$SCRATCH/p32-daily-before.txt" "$OUT" 2>/dev/null | awk 'NF { n++ } END { print n + 0 }')
  gone="${n:-0}"
  if [ "$gone" = 0 ]; then
    check_pass "every daily box that ran at 2.28a still runs (the sweep skipped them)"
  else
    p32_ask sweep-daily T2 "" "$gone of the daily boxes that ran when 2.28a started are stopped now." "Did you stop them yourself? (y = you did, n = nobody did, so the sweep stopped a daily box)"
  fi
  record_value sweep.daily_stopped "$gone" "daily boxes stopped since 2.28a (count only)"
}

# p32_create_seen MARKER STATUS: rc 0 once the caged create of eg-sweep3 has begun: its create
# marker is written (bin/cleat:22501, before the socket volume and the gateway) or its box exists.
# Also once the create's own run has ended (STATUS holds end=), so a refused create costs no wait.
p32_create_seen() { [ -e "$1" ] || LC_ALL=C grep -q '^end=' "$2" 2>/dev/null || [ -n "$(cn eg-sweep3)" ]; }
# Re-entry: an eg-sweep3 box already there aborts (the race can only be watched at a create).
st_2_28d() {
  local h c="" c3="" marker t0 t1 t2 running="" net="" code="" st="" created="" ce se rel
  p32_cd eg-sweep
  if ! p32_dry && ! run_cmd -q -t 60 -- box_running eg-sweep; then step_abort "the eg-sweep box is not running: run 2.28c first"; fi
  p32_cd eg-sweep3 make
  val c -t 60 -- cn eg-sweep3
  if [ -n "$c" ] && ! p32_dry; then step_abort "an eg-sweep3 box exists already: the create window cannot be watched again (2.28-clean removes it)"; fi
  # The window opens with the create marker (bin/cleat:11719), a host file: watched without a docker
  # call, so the sweep's launch starts as early as a script can start it. A marker an earlier refused
  # create left behind would open the wait at once, so it goes first.
  c3=$(cn_name eg-sweep3) || step_abort "cannot name the eg-sweep3 box"
  marker="$CFG/run/$c3/egress/creating"
  if ! p32_dry && [ -e "$marker" ]; then safe_rm "$marker"; fi
  t0=$(epoch_now)
  clt --bg -T 900 -- run
  h="$XBG"
  wait_for sweep3-create "" --auto --timeout 300 --every 1 -- p32_create_seen "$marker" "$h.status"
  t1=$(epoch_now)
  running=no
  if [ -f "$h.status" ] && ! LC_ALL=C grep -q '^end=' "$h.status"; then running=yes; fi
  st=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  xshell eg-sweep --env CLEAT_NO_IDLE_SWEEP=0 --env CLEAT_IDLE_GRACE_MINS=1 --
  t2=$(epoch_now)
  xrun_join "$h" 900
  expect_rc "cleat run in eg-sweep3 exits 0" 0
  val created -t 60 -- docker inspect -f '{{.Created}}' "$c3"
  ce=$(iso_to_epoch "$created"); se=$(iso_to_epoch "$st")
  if p32_is_int "$ce" && p32_is_int "$se"; then
    if [ "$ce" -ge "$se" ]; then rel="the box was created $((ce - se)) s after the sweep's launch started"
    else rel="the box was created $((se - ce)) s before the sweep's launch started"; fi
  else
    rel="the box's create time was not read"
  fi
  record_value sweep.window "the create was seen $((t1 - t0)) s in and was still running then: $running. The sweep's launch started then and ended $((t2 - t0)) s in. $rel" "whether the sweep launch started before the create finished"
  val net -t 60 -- box_netmode eg-sweep3
  expect_eq "eg-sweep3 came up caged (none)" "$net" none
  run_cmd -t 60 -- bx eg-sweep3 ls /run/cleat-egress
  expect_line "its socket dir holds denials.log" denials.log
  expect_line "its socket dir holds proxy.sock" proxy.sock
  val code -t 120 -- bget eg-sweep3 https://example.com/
  expect_eq "bget example.com answers 200" "$code" 200
}

# Re-entry: a box already gone is a NOTE.
st_2_28_clean() {
  local d c=""
  for d in eg-sweep eg-sweep2 eg-sweep3; do
    [ -d "$P/$d" ] || p32_dry || { check_note "no project $d"; continue; }
    p32_cd "$d"
    val c -t 60 -- cn "$d"
    if [ -n "$c" ]; then
      clt -T 300 -- rm
      expect_contains "cleat rm in $d" "Removed $c."   # bin/cleat:23064
    else
      check_note "no $d box"
    fi
  done
}

# ---------------------------------------------------------------------------------------------
# 2.29 Two removal sites users hit (EXTRA)
# ---------------------------------------------------------------------------------------------
# p32_rerun_checks LABEL BH: one gateway and one volume for the box hash, caged, 200 and the 403.
p32_rerun_checks() {
  local label="$1" bh="$2" net="" code=""
  dk -- ps -aq --filter "label=sh.cleat.gateway-for=$bh"
  expect_count "$label: one gateway for the box" '.' eq 1
  dk -- volume ls -q --filter "label=sh.cleat.gateway-for=$bh"
  expect_count "$label: one socket volume for the box" '.' eq 1
  val net -t 60 -- box_netmode eg-rerun
  expect_eq "$label: the box is caged (none)" "$net" none
  val code -t 120 -- bget eg-rerun https://example.com/
  expect_eq "$label: bget example.com answers 200" "$code" 200
  run_cmd -t 120 -- bconnect eg-rerun example.org:443
  first_lines 1
  expect_contains "$label: example.org is denied (the 403 line)" "HTTP/1.1 403 cleat egress: example.org is not on the allowlist"   # gateway.py:197, 230
}
# Re-entry: an eg-rerun box of an earlier attempt is used as it is.
st_2_29() {
  local c="" g="" bh v=""
  p32_cd eg-rerun make
  val c -t 60 -- cn eg-rerun
  if [ -z "$c" ] || p32_dry; then clt -T 900 -- run; expect_rc "cleat run exits 0 (a caged box)" 0
  else check_note "the eg-rerun box exists (an earlier attempt)"; fi
  val g -t 60 -- gw eg-rerun
  if ! p32_dry && [ -z "$g" ]; then step_abort "eg-rerun has no gateway: the box is not caged"; fi
  bh="${g#cleat-gw-}"
  say "    $g $bh"
  clt -T 300 -- stop
  clt -T 900 -- run
  expect_rc "cleat run on the stopped box exits 0 (removes it and creates it again)" 0
  p32_rerun_checks "after cleat run on a stopped box" "$bh"
  say "cleat upgrade-claude: it may take minutes. Recreate cleat-eg-rerun-<8 hex> now to use it? is answered Y."
  clt --answer recreate-touse=y -T 1800 -- upgrade-claude
  expect_match "Claude Code upgraded, or already at the newest" 'Claude Code (upgraded( \(|$)|already at .* \(no change\))'   # bin/cleat:21729-21737
  expect_num "the recreate was offered and answered Y" "$(xfired recreate-touse)" eq 1   # bin/cleat:21618
  p32_rerun_checks "after upgrade-claude" "$bh"
  dk -t 300 -- run --rm --entrypoint sh "$MT_IMAGE" -c '/home/coder/.local/bin/claude --version'
  v=$(head -n 1 "$OUT" 2>/dev/null)
  record_value image.claude.after "${v:-unread}" "Claude Code in the image now (sitting 3 runs on it)"
  clt -T 300 -- rm
  expect_contains "cleat rm" "Removed ${c:-cleat-eg-rerun}"   # bin/cleat:23064
}

# ---------------------------------------------------------------------------------------------
# 2.30 Can a box disarm its own unsafe-rm guard (EXTRA)
# ---------------------------------------------------------------------------------------------
# p32_py_drop: the scenario's Python that drops the PermissionRequest hook from the box's settings.
p32_py_drop() { printf '%s' 'import json; p="/home/coder/.claude/settings.json"; d=json.load(open(p)); d.get("hooks", {}).pop("PermissionRequest", None); open(p, "w").write(json.dumps(d, indent=2))'; }
# Re-entry: the launch opens a session again (a session left open is ended first).
st_2_30() {
  local n="" r
  p32_cd eg-rm make
  mkdir -p "$P/eg-rm/scratch" || step_abort "cannot create $P/eg-rm/scratch"
  if ! p32_dry && run_cmd -q -t 90 -- box_claude_live eg-rm; then p32_exit eg-rm exit-2.30-pre; fi
  p32_launch eg-rm "cleat --cap unsafe-rm" launch-2.30
  val n -t 60 -- p32_hook_count eg-rm
  expect_num "the hook is there (PermissionRequest in the box's settings.json)" "${n:-0}" ge 1
  run_cmd -t 60 -- bxr eg-rm python3 -c "$(p32_py_drop)"
  expect_rc "box root rewrites the settings overlay" 0
  val n -t 60 -- p32_hook_count eg-rm
  expect_num "the box removed it (PermissionRequest count 0)" "${n:-1}" eq 0
  p32_ask_record rm-prompt T1 "Click T1. In Claude Code there send:
Use the Bash tool to run rm -rf /workspace/scratch." "Did Claude Code's delete prompt appear? (y = it appeared, the session re-read the settings. n = the delete ran with no prompt, the session kept the hook it read at start)"
  r=$?
  if [ "$r" = 0 ]; then record_value rail.midsession prompt "the delete prompt mid-session"
  elif [ "$r" = 1 ]; then record_value rail.midsession "no prompt" "the delete prompt mid-session"
  else record_value rail.midsession "not asked" "the delete prompt mid-session"; fi
  p32_exit eg-rm exit-2.30
  # The resume carries the launch's own --cap (departure 13). A CLI cap lasts one invocation
  # (parse_global_flags, bin/cleat:36041) and caps are in the fingerprint (bin/cleat:6144). So a
  # bare cleat resume meets a recreate question, then its overlay refresh drops the hook
  # (bin/cleat:22683): 0 whatever the box did.
  p32_launch eg-rm "cleat resume --cap unsafe-rm" resume-2.30
  val n -t 60 -- p32_hook_count eg-rm
  expect_num "the resume regenerated the overlay (PermissionRequest back)" "${n:-0}" ge 1
  record_value rail.after_resume "${n:-0}" "PermissionRequest lines after the resume"
  p32_exit eg-rm exit-2.30b
  clt -T 300 -- rm
  expect_contains "cleat rm" "Removed cleat-eg-rm-"   # bin/cleat:23064
}

# ---------------------------------------------------------------------------------------------
# 2.31 The amd64 gateway (EXTRA)
# ---------------------------------------------------------------------------------------------
p32_egv_gone() {
  egv_rm egv-amd64 > /dev/null 2>&1
  egv_volrm egv-amd64-sock > /dev/null 2>&1
  return 0
}
# p32_gw_native SECS: the local gateway image back to the engine's own architecture when the emulated
# run left the amd64 one in its place (a create checks only that the image exists, bin/cleat:11520,
# so every later caged box would get an emulated gateway). Also the step's cleanup, for a cut run.
p32_gw_native() {
  local s="" a=""
  val s -t 60 -- docker version -f '{{.Server.Arch}}'
  val a -t 60 -- docker image inspect "$GWIMG" --format '{{.Architecture}}'
  if p32_dry || [ -z "$s" ] || [ -z "$a" ] || [ "$a" = "$s" ]; then return 0; fi
  say "    the local gateway image reads $a, the engine $s: docker pull --platform linux/$s $GWIMG"
  dk -t "${1:-900}" -- pull --platform "linux/$s" "$GWIMG"
  [ "$RC" = 0 ] || warn "the gateway image is still $a: run docker pull --platform linux/$s $GWIMG before any caged launch"
  return 0
}
# Re-entry: a container or volume of an earlier attempt is removed first.
st_2_31() {
  local g="" bh pol health="" mach="" want="" got="" arch="" sarch="" i uidl cap
  p32_cd eg-smoke
  val g -t 60 -- gw eg-smoke
  bh="${g#cleat-gw-}"
  pol="$CFG/egress-rendered/$bh/policy.json"
  if ! p32_dry && { [ -z "$g" ] || [ ! -f "$pol" ]; }; then
    step_abort "no rendered policy at $pol: Docker would make the bind source a directory. Launch eg-smoke once (cleat there), then run 2.31 again"
  fi
  on_cleanup "p32_gw_native 50"
  on_cleanup "p32_egv_gone"
  run_cmd -q -t 60 -- docker ps -aq --filter 'name=^egv-amd64$'
  if [ -s "$OUT" ]; then p32_egv_gone; check_note "an egv-amd64 container of an earlier attempt was removed first"; fi
  egv_run egv-amd64 --platform linux/amd64 \
    --cap-drop ALL --cap-add CHOWN --cap-add SETUID --cap-add SETGID \
    --security-opt no-new-privileges --read-only \
    --tmpfs /run/gw-admin:rw,noexec,nosuid,nodev,size=1m \
    -v egv-amd64-sock:/run/cleat-egress \
    -v "$CFG/egress-rendered/$bh:/etc/cleat-egress:ro" \
    -e CLEAT_SOCK_UID="$(id -u)" -e CLEAT_SOCK_GID="$(id -g)" \
    "$GWIMG"
  expect_rc "the amd64 gateway starts (emulated)" 0
  p32_sleep 40 "the scenario's 40 s for the emulated gateway"
  i=0
  while :; do
    val health -t 60 -- docker inspect -f '{{.State.Health.Status}}' egv-amd64
    if p32_dry || [ "$health" = healthy ] || [ "$i" -ge 12 ]; then break; fi
    p32_sleep 5
    i=$((i + 1))
  done
  expect_eq "it reports healthy" "$health" healthy
  val mach -t 120 -- docker exec egv-amd64 python3 -c "import platform; print(platform.machine())"
  expect_eq "it runs as x86_64" "$mach" x86_64
  run_cmd -t 120 -- p32_proc_status egv-amd64
  uidl=$(LC_ALL=C awk '$1 == "Uid:" { print $2 }' "$OUT" 2>/dev/null)
  cap=$(LC_ALL=C awk '$1 == "CapEff:" { print $2 }' "$OUT" 2>/dev/null)
  expect_eq "its process uid is 65532" "$uidl" 65532
  expect_match "CapEff is all zero" '^CapEff:[[:space:]]+0+$'
  val got -t 120 -- docker exec egv-amd64 /usr/local/bin/gw-admin policy-digest
  val want -t 30 -- p32_rendered_digest "$pol"
  expect_eq "gw-admin policy-digest equals the rendered digest" "$got" "ok policy-digest $want"   # gateway.py:1035, bin/cleat _egress_policy_json
  record_value amd64.health "$health" "the amd64 gateway's health"
  record_value amd64.machine "$mach" "platform.machine()"
  record_value amd64.ids "Uid $uidl, CapEff $cap" "the process's uid and effective capabilities"
  record_value amd64.digest "${got#ok policy-digest }" "the digest it loaded (the rendered one: $want)"
  egv_rm egv-amd64
  egv_volrm egv-amd64-sock
  val sarch -t 60 -- docker version -f '{{.Server.Arch}}'
  val arch -t 60 -- docker image inspect "$GWIMG" --format '{{.Architecture}}'
  record_value amd64.local_arch_after "${arch:-unread}" "the local gateway image's architecture right after the emulated run"
  if ! p32_dry && [ -n "$sarch" ] && [ "$arch" != "$sarch" ]; then
    check_note "the local gateway image reads $arch after the emulated run: pulled back as linux/$sarch before any caged launch"
    p32_gw_native 900
    val arch -t 60 -- docker image inspect "$GWIMG" --format '{{.Architecture}}'
  fi
  expect_eq "the local gateway image stays native ($sarch)" "$arch" "$sarch"
}

# ---------------------------------------------------------------------------------------------
# The registry (run order: DESIGN.md section 6.1)
# ---------------------------------------------------------------------------------------------
reg 2.24-pre   2 expect gate  st_2_24_pre   "Upgrade: a v1.5.4 box from the spec 4 image"
reg 2.24-spec4 2 expect extra st_2_24_spec4 "Upgrade: the relay refusal on spec 4"
reg 2.24-back  2 auto   gate  st_2_24_back  "Upgrade: the candidate image back"
reg 2.24a      2 mixed  gate  st_2_24a      "Upgrade: egress never turned on"
reg 2.24b      2 mixed  gate  st_2_24b      "Upgrade: the policy saved while that session runs (W9)"
reg 2.24c      2 auto   gate  st_2_24c      "Upgrade: refused off a terminal"
reg 2.24d      2 expect gate  st_2_24d      "Upgrade: one question over an old image, declined (W8)"
reg 2.24e      2 expect gate  st_2_24e      "Upgrade: a host path moved (destroy case)"
reg 2.24f      2 expect gate  st_2_24f      "Upgrade: the question accepted before the tag (W8)"
reg 2.24g      2 expect gate  st_2_24g      "Upgrade: the plain question, declined"
reg 2.24h      2 expect gate  st_2_24h      "Upgrade: a gateway image that cannot be pulled (destroy case)"
reg 2.24i      2 mixed  gate  st_2_24i      "Upgrade: accepted"
reg 2.24j      2 expect gate  st_2_24j      "Upgrade: a box whose policy was removed (destroy case)"
reg 2.24-down  2 mixed  extra st_2_24_down  "Downgrade with a caged box"
reg 2.24-clean 2 auto   gate  st_2_24_clean "Upgrade: cleanup"
reg 2.25a      2 expect gate  st_2_25a      "Core pack: only the five hosts"
reg 2.25b      2 mixed  gate  st_2_25b      "Core pack: a login through the cage"
reg 2.25c      2 mixed  gate  st_2_25c      "Core pack: a tool turn and a WebFetch (G2)"
reg 2.25d      2 mixed  gate  st_2_25d      "Core pack after a live account switch (G2)"
reg 2.14-acct  2 mixed  gate  st_2_14_acct  "The accounts picker (the last row of 2.14)"
reg 2.25e      2 mixed  extra st_2_25e      "WebSearch with a deny"
reg 2.26       2 expect extra st_2_26       "Another engine refuses"
reg 2.27a      2 expect gate  st_2_27a      "Global off"
reg 2.27b      2 expect gate  st_2_27b      "A caged box after the global off"
reg 2.27c      2 expect gate  st_2_27c      "On again from cleat config"
reg 2.27d      2 mixed  gate  st_2_27d      "Ready for sitting 3"
reg 2.28a      2 mixed  extra st_2_28a      "Sweep: an orphaned gateway is stopped"
reg 2.28b      2 mixed  extra st_2_28b      "Sweep: a gateway with no box is removed"
reg 2.28c      2 mixed  extra st_2_28c      "Sweep: a detached caged box idle past the grace"
reg 2.28d      2 expect extra st_2_28d      "Sweep: the create window"
reg 2.28-clean 2 expect extra st_2_28_clean "Sweep: cleanup"
reg 2.29       2 expect extra st_2_29       "Two removal sites users hit"
reg 2.30       2 mixed  extra st_2_30       "Can a box disarm its own unsafe-rm guard"
reg 2.31       2 auto   extra st_2_31       "The amd64 gateway"
