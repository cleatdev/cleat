#!/usr/bin/env bats
# `cleat account`: named Claude logins a box can be pinned to.
#
# The whole feature rests on one undocumented Claude Code env var,
# CLAUDE_SECURESTORAGE_CONFIG_DIR, which relocates the CREDENTIAL STORE and
# nothing else. See concept/44-account-switching.md. What is tested here is
# mostly refusal and mostly silence: the failures that matter (a lost refresh
# token, a credential written world-readable, the macOS Keychain quietly
# reverting a switch) all produce no error at the time.

load "../setup"

setup() {
  _common_setup
  use_docker_stub
  source_cli
  _has_unicode() { return 1; }
  CLEAT_ACCOUNTS_DIR="$TEST_TEMP/home/.config/cleat/accounts"
  CLEAT_BOX_ACCOUNTS_DIR="$TEST_TEMP/home/.config/cleat/box-accounts"
  CLEAT_RUN_DIR="$TEST_TEMP/home/.config/cleat/run"
  mkdir -p "$CLEAT_ACCOUNTS_DIR" "$CLEAT_BOX_ACCOUNTS_DIR" "$CLEAT_RUN_DIR"
}
teardown() { _common_teardown; }

CN="cleat-proj-abcdef12"

# A credential blob shaped like the real one. $1 = expiresAt (epoch ms),
# $2 = refreshToken (empty means signed out), $3 = refreshTokenExpiresAt.
_cred_blob() {
  # `${2-...}` and not `${2:-...}`: an EXPLICITLY empty refresh token is the
  # invalid_grant state and has to survive being passed in.
  local exp="${1:-9999999999999}" rt="${2-r-token}" rte="${3:-}"
  if [[ -n "$rte" ]]; then
    printf '{"claudeAiOauth":{"accessToken":"a-token","refreshToken":"%s","expiresAt":%s,"refreshTokenExpiresAt":%s,"subscriptionType":"max"}}\n' "$rt" "$exp" "$rte"
  else
    printf '{"claudeAiOauth":{"accessToken":"a-token","refreshToken":"%s","expiresAt":%s,"subscriptionType":"max"}}\n' "$rt" "$exp"
  fi
}

_mk_account() {   # $1 = name, $2 = expiresAt, $3 = refreshToken, $4 = refreshTokenExpiresAt
  mkdir -p "$CLEAT_ACCOUNTS_DIR/$1"
  chmod 700 "$CLEAT_ACCOUNTS_DIR/$1"
  _cred_blob "${2:-9999999999999}" "${3-r-token}" "${4:-}" > "$CLEAT_ACCOUNTS_DIR/$1/.credentials.json"
  chmod 600 "$CLEAT_ACCOUNTS_DIR/$1/.credentials.json"
}

_mk_staged() {   # $1 = cname, $2 = expiresAt
  mkdir -p "$CLEAT_RUN_DIR/$1/auth"
  _cred_blob "${2:-9999999999999}" > "$CLEAT_RUN_DIR/$1/auth/.credentials.json"
}

_pass_gates() {
  _daemon_up() { return 1; }          # no daemon: the verb must work anyway
  container_exists() { return 1; }
  _box_has_live_agent() { return 1; }
}

# ── names ──────────────────────────────────────────────────────────────────

@test "account: accepts the box-name charset" {
  local n
  for n in work a1 work-2 work_2 a012345678901234567890123456789; do
    run _validate_account_name "$n"
    assert_success
  done
}

@test "account: refuses a name that is not the box charset" {
  # Uppercase is the sharpest of these: Work and work are ONE directory on a
  # case-insensitive APFS host and two paths inside the container.
  local n
  for n in "" "Work" "work space" "work.a" "-work" "_work" "work/a" "../etc" "a01234567890123456789012345678901"; do
    run _validate_account_name "$n"
    assert_failure
  done
}

@test "account: refuses the subcommand words as names" {
  # They are reserved before the switch form is parsed, so an account named
  # `rm` could be created and then never selected again.
  local n
  for n in list rename rm delete restore trash off help; do
    run _validate_account_name "$n"
    assert_failure
  done
}

# ── the store ──────────────────────────────────────────────────────────────

@test "account: a new store is 0700 and its credential 0600" {
  # A credential at the host's default umask is readable by anything on the
  # machine, and it is live for weeks.
  _account_ensure_dir work
  [ "$(stat -c '%a' "$CLEAT_ACCOUNTS_DIR/work" 2>/dev/null || stat -f '%Lp' "$CLEAT_ACCOUNTS_DIR/work")" = "700" ]
  _cred_blob > "$TEST_TEMP/src.json"
  chmod 644 "$TEST_TEMP/src.json"
  run _account_write_cred work "$TEST_TEMP/src.json"
  assert_success
  [ "$(stat -c '%a' "$CLEAT_ACCOUNTS_DIR/work/.credentials.json" 2>/dev/null || stat -f '%Lp' "$CLEAT_ACCOUNTS_DIR/work/.credentials.json")" = "600" ]
}

@test "account: a credential that is not a JSON object is never written" {
  _account_ensure_dir work
  printf 'not json at all\n' > "$TEST_TEMP/src.json"
  run _account_write_cred work "$TEST_TEMP/src.json"
  assert_failure
  [ ! -f "$CLEAT_ACCOUNTS_DIR/work/.credentials.json" ]
}

@test "account: a symlinked store is refused, not followed" {
  # Claude Code's own store opens with O_NOFOLLOW and reports "no credentials"
  # on a symlink, so this failure is silent in both directions.
  mkdir -p "$TEST_TEMP/outside"
  ln -s "$TEST_TEMP/outside" "$CLEAT_ACCOUNTS_DIR/work"
  run _account_dir_ok work
  assert_failure
  _cred_blob > "$TEST_TEMP/src.json"
  run _account_write_cred work "$TEST_TEMP/src.json"
  assert_failure
  [ ! -f "$TEST_TEMP/outside/.credentials.json" ]
}

@test "account: a symlinked credential file is refused" {
  _account_ensure_dir work
  ln -s "$TEST_TEMP/elsewhere.json" "$CLEAT_ACCOUNTS_DIR/work/.credentials.json"
  _cred_blob > "$TEST_TEMP/src.json"
  run _account_write_cred work "$TEST_TEMP/src.json"
  assert_failure
  [ ! -e "$TEST_TEMP/elsewhere.json" ]
}

@test "account: the list skips anything that is not a usable account name" {
  _mk_account work
  mkdir -p "$CLEAT_ACCOUNTS_DIR/.trash" "$CLEAT_ACCOUNTS_DIR/Bad" "$CLEAT_ACCOUNTS_DIR/has space"
  : > "$CLEAT_ACCOUNTS_DIR/a-file"
  run _account_list
  assert_success
  assert_output "work"
}

@test "account: the list ignores a symlinked directory" {
  _mk_account work
  mkdir -p "$TEST_TEMP/outside"
  ln -s "$TEST_TEMP/outside" "$CLEAT_ACCOUNTS_DIR/sneaky"
  run _account_list
  assert_success
  assert_output "work"
}

# ── the per-box pin ────────────────────────────────────────────────────────

@test "account: a box with no pin reads as the default sentinel" {
  run _box_account_read "$CN"
  assert_success
  assert_output "default"
}

@test "account: a pin round-trips and can be removed" {
  _box_account_write "$CN" work
  run _box_account_read "$CN"
  assert_output "work"
  _box_account_remove "$CN"
  run _box_account_read "$CN"
  assert_output "default"
}

@test "account: a pin file is 0600" {
  _box_account_write "$CN" work
  [ "$(stat -c '%a' "$CLEAT_BOX_ACCOUNTS_DIR/$CN" 2>/dev/null || stat -f '%Lp' "$CLEAT_BOX_ACCOUNTS_DIR/$CN")" = "600" ]
}

@test "account: a hand-edited pin that is not a usable name falls back to default" {
  printf 'Not A Name\n' > "$CLEAT_BOX_ACCOUNTS_DIR/$CN"
  run _box_account_read "$CN"
  assert_output "default"
}

@test "account: the boxes pinned to an account are listed" {
  _box_account_write "box-one" work
  _box_account_write "box-two" work
  _box_account_write "box-three" other
  run _account_pinned_boxes work
  assert_success
  assert_line "box-one"
  assert_line "box-two"
  refute_line "box-three"
}

# ── staging in and harvesting out ──────────────────────────────────────────

@test "account: staging copies the stored credential into the box at 0600" {
  _mk_account work
  _box_account_write "$CN" work
  run _account_sync_in "$CN"
  assert_success
  [ -f "$CLEAT_RUN_DIR/$CN/auth/.credentials.json" ]
  [ "$(stat -c '%a' "$CLEAT_RUN_DIR/$CN/auth/.credentials.json" 2>/dev/null || stat -f '%Lp' "$CLEAT_RUN_DIR/$CN/auth/.credentials.json")" = "600" ]
}

@test "account: staging an empty account leaves the box signed out" {
  # A directory with no credential IS the clean scope: the box has to present
  # as signed out so /login lands in the right store.
  _account_ensure_dir work
  _box_account_write "$CN" work
  _mk_staged "$CN"
  run _account_sync_in "$CN"
  assert_success
  [ ! -f "$CLEAT_RUN_DIR/$CN/auth/.credentials.json" ]
}

@test "account: staging never overwrites a newer credential the box refreshed" {
  _mk_account work 1000
  _box_account_write "$CN" work
  _mk_staged "$CN" 9999999999999
  run _account_sync_in "$CN"
  assert_success
  run grep -c 9999999999999 "$CLEAT_RUN_DIR/$CN/auth/.credentials.json"
  assert_output "1"
}

@test "account: the default sentinel stages nothing at all" {
  _mk_account work
  run _account_sync_in "$CN"
  assert_success
  [ ! -d "$CLEAT_RUN_DIR/$CN/auth" ]
}

@test "account: a token the box refreshed is harvested back into the store" {
  # Without this every refresh after a switch is lost and the account is back
  # at /login, which is the exact pain this feature removes.
  _mk_account work 1000
  _box_account_write "$CN" work
  _mk_staged "$CN" 9999999999999
  run _account_sync_out "$CN"
  assert_success
  run grep -c 9999999999999 "$CLEAT_ACCOUNTS_DIR/work/.credentials.json"
  assert_output "1"
}

@test "account: harvesting never replaces a newer stored credential with an older one" {
  _mk_account work 9999999999999
  _box_account_write "$CN" work
  _mk_staged "$CN" 1000
  run _account_sync_out "$CN"
  assert_success
  run grep -c 9999999999999 "$CLEAT_ACCOUNTS_DIR/work/.credentials.json"
  assert_output "1"
}

@test "account: harvesting is a no-op for an unpinned box" {
  _mk_staged "$CN" 9999999999999
  run _account_sync_out "$CN"
  assert_success
  [ ! -d "$CLEAT_ACCOUNTS_DIR/default" ]
}

@test "account: harvesting refuses a symlinked box credential" {
  _mk_account work 1000
  _box_account_write "$CN" work
  mkdir -p "$CLEAT_RUN_DIR/$CN/auth"
  _cred_blob 9999999999999 > "$TEST_TEMP/planted.json"
  ln -s "$TEST_TEMP/planted.json" "$CLEAT_RUN_DIR/$CN/auth/.credentials.json"
  run _account_sync_out "$CN"
  assert_failure
  run grep -c 1000 "$CLEAT_ACCOUNTS_DIR/work/.credentials.json"
  assert_output "1"
}

@test "account: wiping a box run dir harvests first" {
  # cleat rm, every recreate and nuke all wipe this directory. A wipe that does
  # not harvest throws away a token the account has no other copy of.
  _mk_account work 1000
  _box_account_write "$CN" work
  _mk_staged "$CN" 9999999999999
  run _account_wipe_run_dir "$CN"
  assert_success
  [ ! -d "$CLEAT_RUN_DIR/$CN" ]
  run grep -c 9999999999999 "$CLEAT_ACCOUNTS_DIR/work/.credentials.json"
  assert_output "1"
}

@test "account: the whole-run-dir wipe harvests every pinned box" {
  _mk_account work 1000
  _box_account_write "$CN" work
  _mk_staged "$CN" 9999999999999
  run _account_sync_out_all
  assert_success
  run grep -c 9999999999999 "$CLEAT_ACCOUNTS_DIR/work/.credentials.json"
  assert_output "1"
}

# ── metadata ───────────────────────────────────────────────────────────────

@test "account: metadata round-trips and overwrites in place" {
  _account_ensure_dir work
  _account_meta_set work who "someone@example.com"
  _account_meta_set work plan max
  _account_meta_set work who "other@example.com"
  run _account_meta_get work who
  assert_output "other@example.com"
  run _account_meta_get work plan
  assert_output "max"
}

@test "account: metadata is 0600" {
  _account_ensure_dir work
  _account_meta_set work who "someone@example.com"
  [ "$(stat -c '%a' "$CLEAT_ACCOUNTS_DIR/work/meta" 2>/dev/null || stat -f '%Lp' "$CLEAT_ACCOUNTS_DIR/work/meta")" = "600" ]
}

@test "account: a metadata value cannot forge a second field or a second line" {
  # The file is one key and one value per line, and the values come out of
  # model-adjacent JSON. A tab or a newline in one would make the reader see a
  # key that was never set.
  _account_ensure_dir work
  _account_meta_set work who "$(printf 'a\tb\nplan\tfake')"
  run _account_meta_get work plan
  assert_failure
}

@test "account: a missing metadata key fails rather than printing an empty string" {
  _account_ensure_dir work
  run _account_meta_get work who
  assert_failure
}

# ── what the row says about the credential ─────────────────────────────────

@test "account: an account with no credential reads as signed out" {
  _account_ensure_dir work
  run _account_auth_state work
  assert_output "signed out"
}

@test "account: an account whose tokens were cleared reads as signed out" {
  # On invalid_grant the client writes EMPTY tokens back to disk, so a present
  # file is not the same as a working account.
  _mk_account work 9999999999999 ""
  run _account_auth_state work
  assert_output "signed out"
}

@test "account: an expired refresh token reads as re-login" {
  _mk_account work 9999999999999 r-token 1000
  run _account_auth_state work
  assert_output "re-login"
}

@test "account: a credential with no refresh expiry is not guessed at" {
  # refreshTokenExpiresAt is OPTIONAL. A 2026-05 credential on the maintainer's
  # own machine has no such field, and inventing an expiry for it would render
  # a working account as dead.
  _mk_account work
  run _account_auth_state work
  assert_output "ok"
}

# ── usage ──────────────────────────────────────────────────────────────────

@test "account: usage renders nothing at all without a snapshot" {
  _account_ensure_dir work
  run _account_usage_render work
  assert_failure
  assert_output ""
}

@test "account: usage renders the stored snapshot" {
  _account_ensure_dir work
  _CLEAT_NOW_S=1000000
  _account_meta_set work usage_at 1000000
  _account_meta_set work usage_five 16
  _account_meta_set work usage_week 40
  _account_meta_set work usage_five_resets 1000600
  _account_meta_set work usage_week_resets 1600000
  run _account_usage_render work
  assert_success
  assert_output --partial "5h 16%"
  assert_output --partial "7d 40%"
}

@test "account: a window whose reset time has passed says so instead of a stale number" {
  # resets_at is an absolute future instant, so it stays TRUE while the
  # percentage goes stale. Printing the old percentage after it elapsed would
  # be the one invented figure in the feature.
  _account_ensure_dir work
  _CLEAT_NOW_S=2000000
  _account_meta_set work usage_at 1000000
  _account_meta_set work usage_five 16
  _account_meta_set work usage_five_resets 1000600
  run _account_usage_render work
  assert_success
  assert_output --partial "window reset"
  refute_output --partial "16%"
}

@test "account: a snapshot older than the throttle carries its own age" {
  _account_ensure_dir work
  _CLEAT_NOW_S=1000000
  _account_meta_set work usage_at 900000
  _account_meta_set work usage_five 16
  _account_meta_set work usage_five_resets 9999999
  run _account_usage_render work
  assert_success
  assert_output --partial "as of"
}

@test "account: usage is never polled for an account whose token has expired" {
  # Rule one of three: a refresh MAY rotate the refresh token, so polling a
  # parked account for display could revoke a credential held elsewhere.
  _mk_account work 1000
  _CLEAT_NOW_S=9999999
  curl() { echo "CURL RAN" >> "$TEST_TEMP/curl.log"; }
  run _account_usage_fetch work
  assert_failure
  [ ! -f "$TEST_TEMP/curl.log" ]
}

@test "account: usage is not polled again inside the throttle window" {
  _mk_account work 99999999999999
  _CLEAT_NOW_S=1000000
  _account_meta_set work usage_at 1000000
  curl() { echo "CURL RAN" >> "$TEST_TEMP/curl.log"; }
  run _account_usage_fetch work
  assert_failure
  [ ! -f "$TEST_TEMP/curl.log" ]
}

@test "account: the usage request carries skip_spend and never the token on argv" {
  # skip_spend keeps real billing figures out of a picker. The token goes in on
  # stdin because argv is visible in ps on a shared host.
  curl() { cat > "$TEST_TEMP/curl.stdin"; printf '%s\n' "$*" > "$TEST_TEMP/curl.argv"; }
  run _account_usage_curl "SECRET-TOKEN"
  assert_success
  run cat "$TEST_TEMP/curl.argv"
  refute_output --partial "SECRET-TOKEN"
  run cat "$TEST_TEMP/curl.stdin"
  assert_output --partial "skip_spend=1"
  assert_output --partial "SECRET-TOKEN"
}

# ── trash, restore, rename ─────────────────────────────────────────────────

@test "account: removing an account moves it to the trash" {
  _mk_account work
  run _account_trash work
  assert_success
  [ ! -d "$CLEAT_ACCOUNTS_DIR/work" ]
  [ -f "$CLEAT_ACCOUNTS_DIR/.trash/"*"-work/.credentials.json" ]
}

@test "account: a trashed account comes back" {
  _mk_account work
  _account_trash work
  run _account_restore work
  assert_success
  [ -f "$CLEAT_ACCOUNTS_DIR/work/.credentials.json" ]
}

@test "account: restore never overwrites an account that came back on its own" {
  _mk_account work
  _account_trash work
  _mk_account work 1234
  run _account_restore work
  assert_failure
  run grep -c 1234 "$CLEAT_ACCOUNTS_DIR/work/.credentials.json"
  assert_output "1"
}

@test "account: a symlinked trash directory is refused" {
  mkdir -p "$TEST_TEMP/outside"
  ln -s "$TEST_TEMP/outside" "$CLEAT_ACCOUNTS_DIR/.trash"
  _mk_account work
  run _account_trash work
  [ "$status" -eq 2 ]
  [ -d "$CLEAT_ACCOUNTS_DIR/work" ]
}

@test "account: the trash sweep drops entries past the window and keeps fresh ones" {
  mkdir -p "$CLEAT_ACCOUNTS_DIR/.trash/1-work" "$CLEAT_ACCOUNTS_DIR/.trash/$(date +%s)-other"
  mkdir -p "$CLEAT_ACCOUNTS_DIR/.trash/not-a-stamp-work"
  run _account_trash_sweep
  assert_success
  [ ! -d "$CLEAT_ACCOUNTS_DIR/.trash/1-work" ]
  [ -d "$CLEAT_ACCOUNTS_DIR/.trash/not-a-stamp-work" ]
}

@test "account: renaming moves the store and every pin follows it" {
  # Without the pin rewrite every box pinned to the old name silently falls
  # back to the shared store at its next attach, which reads as being logged
  # out by cleat.
  _mk_account work
  _box_account_write "$CN" work
  run _account_rename work other
  assert_success
  [ -d "$CLEAT_ACCOUNTS_DIR/other" ]
  [ ! -d "$CLEAT_ACCOUNTS_DIR/work" ]
  run _box_account_read "$CN"
  assert_output "other"
}

@test "account: renaming onto an existing name is refused" {
  _mk_account work
  _mk_account other
  run _account_rename work other
  assert_failure
  [ -d "$CLEAT_ACCOUNTS_DIR/work" ]
}

# ── the actions ────────────────────────────────────────────────────────────

@test "account: switching creates a clean store and pins the box" {
  _pass_gates
  run _account_do_switch work main "$CN" "$TEST_TEMP/proj"
  assert_success
  assert_output --partial "/login"
  [ -d "$CLEAT_ACCOUNTS_DIR/work" ]
  run _box_account_read "$CN"
  assert_output "work"
}

@test "account: switching says what a shared conversation costs" {
  # Claude Code ties a conversation to the account that started it, and the
  # suppression it writes is silent at the time.
  _pass_gates
  _mk_account work
  run _account_do_switch work main "$CN" "$TEST_TEMP/proj"
  assert_success
  assert_output --partial "--resume"
}

@test "account: switching refuses an unusable name and pins nothing" {
  _pass_gates
  run _account_do_switch "Bad Name" main "$CN" "$TEST_TEMP/proj"
  assert_failure
  run _box_account_read "$CN"
  assert_output "default"
}

@test "account: switching back to default unpins the box and clears the staged copy" {
  _pass_gates
  _mk_account work
  _account_do_switch work main "$CN" "$TEST_TEMP/proj"
  run _account_do_switch default main "$CN" "$TEST_TEMP/proj"
  assert_success
  run _box_account_read "$CN"
  assert_output "default"
  [ ! -f "$CLEAT_RUN_DIR/$CN/auth/.credentials.json" ]
}

@test "account: switching refuses while the box has a live Claude session" {
  # Claude Code notices the credential file changing, disarms its auth watcher
  # and writes its own token back over the swap.
  _mk_account work
  _daemon_up() { return 0; }
  container_exists() { return 0; }
  _box_has_live_agent() { return 0; }
  run _account_do_switch work main "$CN" "$TEST_TEMP/proj"
  assert_failure
  assert_output --partial "live Claude session"
  run _box_account_read "$CN"
  assert_output "default"
}

@test "account: switching still works with the daemon down" {
  # The verb is deliberately outside the preflight allowlist. _box_has_live_agent
  # answers "live" when it cannot read docker, which is the safe default where
  # it is used and the wrong one here.
  _mk_account work
  _daemon_up() { return 1; }
  container_exists() { return 1; }
  _box_has_live_agent() { return 0; }
  run _account_do_switch work main "$CN" "$TEST_TEMP/proj"
  assert_success
}

@test "account: a box that predates the auth mount is told to recreate, not left broken" {
  # Without this /login would create the store inside the container filesystem
  # and cleat rm would destroy the login with no warning.
  _mk_account work
  _daemon_up() { return 0; }
  container_exists() { return 0; }
  _box_has_live_agent() { return 1; }
  docker() { case "$1" in exec) return 1 ;; *) return 0 ;; esac; }
  run _account_do_switch work main "$CN" "$TEST_TEMP/proj"
  assert_failure
  assert_output --partial "cleat rm"
}

@test "account: removing an account unpins the boxes that used it" {
  _pass_gates
  _is_interactive() { return 0; }
  _ask_yn() { printf -v "$1" '%s' 'y'; }
  _mk_account work
  _box_account_write "$CN" work
  _mk_staged "$CN" 1
  run _account_do_remove work 1
  assert_success
  run _box_account_read "$CN"
  assert_output "default"
  [ ! -f "$CLEAT_RUN_DIR/$CN/auth/.credentials.json" ]
}

@test "account: removing needs a terminal or --yes, and does nothing without either" {
  _pass_gates
  _is_interactive() { return 1; }
  _mk_account work
  run _account_do_remove work 0
  assert_success
  assert_output --partial "--yes"
  [ -d "$CLEAT_ACCOUNTS_DIR/work" ]
}

@test "account: removing refuses while a box pinned to it has a live session" {
  _mk_account work
  _box_account_write "$CN" work
  _daemon_up() { return 0; }
  container_exists() { return 0; }
  _box_has_live_agent() { return 0; }
  run _account_do_remove work 1
  assert_failure
  [ -d "$CLEAT_ACCOUNTS_DIR/work" ]
}

# ── the docker wiring ──────────────────────────────────────────────────────

@test "account: a pinned box gets the credential store env var" {
  _mk_account work
  _box_account_write "cleat-envtest" work
  _host_clip_cmd() { echo ""; }
  run exec_claude "cleat-envtest" --dangerously-skip-permissions
  run assert_docker_exec_has "CLAUDE_SECURESTORAGE_CONFIG_DIR=/home/coder/.cleat-auth"
  assert_success
}

@test "account: an unpinned box gets no credential store env var at all" {
  # The default sentinel has to be byte-identical to the behaviour before this
  # feature existed, or every box that never runs the verb is a migration.
  _host_clip_cmd() { echo ""; }
  run exec_claude "cleat-envtest2" --dangerously-skip-permissions
  run grep -c "CLAUDE_SECURESTORAGE_CONFIG_DIR" "$DOCKER_CALLS"
  assert_output "0"
}

@test "account: a pinned box skips the macOS Keychain seed" {
  # The seed compares token EXPIRY and never identity, so on a Mac it would
  # quietly restore the Keychain's account about eight hours after a switch.
  _mk_account work
  _box_account_write "cleat-seedtest" work
  _host_clip_cmd() { echo ""; }
  _seed_macos_credentials() { : > "$TEST_TEMP/seeded"; }
  run exec_claude "cleat-seedtest" --dangerously-skip-permissions
  [ ! -f "$TEST_TEMP/seeded" ]
}

@test "account: an unpinned box still gets the macOS Keychain seed" {
  _host_clip_cmd() { echo ""; }
  _seed_macos_credentials() { : > "$TEST_TEMP/seeded"; }
  run exec_claude "cleat-seedtest2" --dangerously-skip-permissions
  [ -f "$TEST_TEMP/seeded" ]
}

@test "account: the per-box auth directory is created before any docker run" {
  # A missing bind source makes Docker create a DIRECTORY at the target, which
  # is the failure that once broke git host-wide.
  run _generate_home_overlay "cleat-overlay" "$TEST_TEMP/ws" "key"
  assert_success
  [ -d "$CLEAT_RUN_DIR/cleat-overlay/auth" ]
  [ "$(stat -c '%a' "$CLEAT_RUN_DIR/cleat-overlay/auth" 2>/dev/null || stat -f '%Lp' "$CLEAT_RUN_DIR/cleat-overlay/auth")" = "700" ]
}

@test "account: a planted symlink where the auth directory goes is replaced" {
  mkdir -p "$CLEAT_RUN_DIR/cleat-overlay2"
  ln -s "$TEST_TEMP/outside" "$CLEAT_RUN_DIR/cleat-overlay2/auth"
  run _generate_home_overlay "cleat-overlay2" "$TEST_TEMP/ws" "key"
  assert_success
  [ ! -L "$CLEAT_RUN_DIR/cleat-overlay2/auth" ]
  [ -d "$CLEAT_RUN_DIR/cleat-overlay2/auth" ]
}

# ── the picker ─────────────────────────────────────────────────────────────

_acct_draw_lines() {
  "$@" > "$TEST_TEMP/frame.out" 2>/dev/null
  wc -l < "$TEST_TEMP/frame.out" | tr -d ' '
}

_acct_keys() {
  printf '%s\n' "$@" > "$TEST_TEMP/keys"
  _read_keypress() {
    local f="$TEST_TEMP/keys" k
    k="$(head -n1 "$f" 2>/dev/null)"
    tail -n +2 "$f" > "$f.rest" 2>/dev/null && mv "$f.rest" "$f" 2>/dev/null
    [ -n "$k" ] && echo "$k" || echo QUIT
  }
}

@test "account: the frame is page + 4 lines whatever the list length" {
  _term_rows() { echo 24; }; _term_cols() { echo 100; }
  _mk_account one; _mk_account two
  _accounts_load_rows one
  _accounts_measure "$_ACCT_N"
  # Two stored accounts plus the shared-login row.
  [ "$_ACCT_N" -eq 3 ]
  [ "$(_acct_draw_lines _accounts_frame 0 0 "$_ACCT_PAGE" 100 "$_ACCT_N")" -eq 7 ]
}

@test "account: the detail pane keeps its height for a row that has nothing to say" {
  _term_rows() { echo 24; }; _term_cols() { echo 100; }
  _mk_account one
  _accounts_load_rows one
  _accounts_measure "$_ACCT_N"
  [ "$(_acct_draw_lines _accounts_frame 0 0 "$_ACCT_PAGE" 100 "$_ACCT_N")" -eq 6 ]
}

@test "account: the frame normalises a hostile offset instead of aborting" {
  # A negative subscript aborts bash 3.2 outright and silently renders the
  # wrong rows on bash 5.
  _mk_account one
  _accounts_load_rows one
  run _accounts_frame -5 -9 2 100 1
  assert_success
}

@test "account: the viewport is sized from the terminal" {
  local i
  for i in 1 2 3 4 5 6 7 8 9; do _mk_account "acct$i"; done
  _term_rows() { echo 14; }; _term_cols() { echo 100; }
  _accounts_load_rows one
  _accounts_measure "$_ACCT_N"
  # 14 rows - 9 of chrome = a 5-row viewport.
  [ "$_ACCT_PAGE" -eq 5 ]
}

@test "account: the cursor cannot end up on a row that is not drawn" {
  _mk_account one; _mk_account two
  _ACCT_PAGE=1
  _ACCT_CURSOR=99
  _ACCT_OFFSET=99
  _accounts_clamp 2
  [ "$_ACCT_CURSOR" -eq 1 ]
  [ "$_ACCT_OFFSET" -eq 1 ]
}

@test "account: a row is truncated to the terminal width, never wrapped" {
  _mk_account one
  _account_meta_set one who "a-very-long-email-address-that-would-wrap@some-long-domain.example.com"
  _accounts_load_rows one
  _accounts_frame 0 0 1 50 1 > "$TEST_TEMP/frame.out" 2>/dev/null
  local widest
  widest="$(sed $'s/\033\\[[0-9;]*[A-Za-z]//g' "$TEST_TEMP/frame.out" \
    | sed 's/↑/^/g; s/↓/v/g; s/⏎/E/g; s/▸/>/g; s/·/./g; s/…/./g; s/•/o/g' \
    | awk '{ n = length($0); if (n > m) m = n } END { print m + 0 }')"
  [ "$widest" -le 50 ]
}

@test "account: the shared login is always the first row, so the picker is not a one-way door" {
  _mk_account one
  _accounts_load_rows one
  [ "${_ACCT_NAME[0]}" = "default" ]
  [ "$_ACCT_STORED" -eq 1 ]
}

@test "account: the shared login row is marked when no account is pinned" {
  _mk_account one
  _accounts_load_rows default
  [ "${_ACCT_MARK[0]}" = "1" ]
}

@test "account: the picker puts a box back on the shared login" {
  _pass_gates
  _mk_account one
  _box_account_write "$CN" one
  _acct_keys ENTER ENTER QUIT
  run _accounts_picker_tui main "$CN" "$TEST_TEMP/proj"
  assert_success
  run _box_account_read "$CN"
  assert_output "default"
}

@test "account: the shared login cannot be renamed or removed" {
  _pass_gates
  _mk_account one
  _acct_keys ENTER DOWN DOWN ENTER QUIT
  run _accounts_picker_tui main "$CN" "$TEST_TEMP/proj"
  assert_success
  assert_output --partial "nothing to rename or remove"
  [ -d "$CLEAT_ACCOUNTS_DIR/one" ]
}

@test "account: default is refused as a stored account name" {
  # It is the sentinel every staging path reads as "no account", so a real
  # directory of that name could be pinned and then never staged.
  run _validate_account_name default
  assert_failure
}

@test "account: q closes the picker" {
  _mk_account one
  _acct_keys QUIT
  run _accounts_picker_tui main "$CN" "$TEST_TEMP/proj"
  assert_success
  assert_output --partial "Cancelled."
}

@test "account: an unknown key is a no-op and does not close the picker" {
  _mk_account one
  _acct_keys OTHER OTHER QUIT
  run _accounts_picker_tui main "$CN" "$TEST_TEMP/proj"
  assert_success
  [ "$(printf '%s\n' "$output" | grep -c "Cancelled.")" -eq 1 ]
}

@test "account: the picker switches the box to the highlighted account" {
  _pass_gates
  _mk_account one
  _acct_keys DOWN ENTER ENTER QUIT
  run _accounts_picker_tui main "$CN" "$TEST_TEMP/proj"
  assert_success
  run _box_account_read "$CN"
  assert_output "one"
}

@test "account: the picker comes back to the list after an action" {
  _pass_gates
  _mk_account one
  _acct_keys ENTER ENTER QUIT
  run _accounts_picker_tui main "$CN" "$TEST_TEMP/proj"
  assert_success
  [ "$(printf '%s\n' "$output" | grep -c "⏎ switch or edit")" -ge 2 ]
}

@test "account: backing out of the action screen says nothing and redraws" {
  _mk_account one
  _acct_keys ENTER QUIT QUIT
  run _accounts_picker_tui main "$CN" "$TEST_TEMP/proj"
  assert_success
  [ "$(printf '%s\n' "$output" | grep -c "Cancelled.")" -eq 1 ]
  [ "$(printf '%s\n' "$output" | grep -c "⏎ switch or edit")" -ge 2 ]
}

@test "account: an empty list says how to make the first account" {
  run _accounts_picker_tui main "$CN" "$TEST_TEMP/proj"
  assert_success
  assert_output --partial "cleat account <name>"
}

@test "account: narrowing the window mid-session leaves the picker cleanly" {
  _mk_account one
  : > "$TEST_TEMP/wcalls"
  _term_size() {
    echo x >> "$TEST_TEMP/wcalls"
    if [[ "$(wc -l < "$TEST_TEMP/wcalls" | tr -d ' ')" -le 3 ]]; then echo "24 100"; else echo "24 30"; fi
  }
  _acct_keys DOWN QUIT
  run _accounts_picker_tui main "$CN" "$TEST_TEMP/proj"
  assert_success
  assert_output --partial "⏎ switch or edit"
  assert_output --partial "too narrow"
}

@test "account: a failure during the row load still restores the terminal" {
  _is_tty() { return 0; }
  : > "$TEST_TEMP/stty.log"
  stty() { case "$1" in -g) echo "SAVED" ;; *) echo "stty $*" >> "$TEST_TEMP/stty.log" ;; esac; }
  _mk_account one
  _accounts_load_rows() { exit 7; }
  run _accounts_picker_tui main "$CN" "$TEST_TEMP/proj"
  [ "$status" -eq 7 ]
  run cat "$TEST_TEMP/stty.log"
  assert_output --partial "stty SAVED"
}

@test "account: the frame forks nothing per row" {
  # Same claim the session frame carries: a $(printf ...) for the columns is a
  # command substitution and forks once PER ROW. `printf -v` assigns in the
  # current shell and forks nothing, so only the non-`-v` calls are counted,
  # and there must be exactly ONE: the single write that emits the frame.
  local i
  for i in 1 2 3 4 5 6; do _mk_account "acct$i"; done
  _term_rows() { echo 24; }; _term_cols() { echo 100; }
  _accounts_load_rows one
  _accounts_measure "$_ACCT_N"
  : > "$TEST_TEMP/pcalls"
  printf() {
    if [ "${1:-}" != "-v" ]; then echo "cmd" >> "$TEST_TEMP/pcalls"; fi
    command printf "$@"
  }
  _accounts_frame 0 0 "$_ACCT_PAGE" "$_ACCT_COLS" "$_ACCT_N" > /dev/null
  unset -f printf
  [ "$(wc -l < "$TEST_TEMP/pcalls" | tr -d ' ')" -eq 1 ]
}

# ── the command ────────────────────────────────────────────────────────────

@test "account: an unknown flag is refused" {
  run cmd_account --wat
  assert_failure
  assert_output --partial "Unknown flag"
}

@test "account: rename with one argument says what it needs" {
  run cmd_account rename only-one
  assert_failure
  assert_output --partial "rename <old> <new>"
}

@test "account: restore with no name says what it needs" {
  run cmd_account restore
  assert_failure
  assert_output --partial "restore <name>"
}

@test "account: the per-box auth directory is mounted into the container" {
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"
  run cmd_run "$TEST_TEMP/project"
  assert_success
  run assert_docker_run_has "$cname" "auth:/home/coder/.cleat-auth"
  assert_success
}

@test "account: the store survives cleat nuke, which promises auth is safe" {
  # cmd_nuke says "your ~/.claude auth is safe" and then wipes four state
  # directories. An accounts tree caught in that wipe would destroy weeks of
  # refresh token while the message said it had not.
  _mk_account work
  _box_account_write "$CN" work
  mock_docker_ps ""
  run cmd_nuke <<< "nuke"
  [ -f "$CLEAT_ACCOUNTS_DIR/work/.credentials.json" ]
  [ -f "$CLEAT_BOX_ACCOUNTS_DIR/$CN" ]
}
