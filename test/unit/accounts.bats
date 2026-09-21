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
  # Pinned too: the identity tests write a sibling project file, and without
  # this they would write it into the developer's REAL config directory.
  CLEAT_PROJECTS_DIR="$TEST_TEMP/home/.config/cleat/projects"
  mkdir -p "$CLEAT_ACCOUNTS_DIR" "$CLEAT_BOX_ACCOUNTS_DIR" "$CLEAT_RUN_DIR" "$CLEAT_PROJECTS_DIR"
  # A fixed clock, because the harvest refuses an expiry further out than any
  # real access token could be. Fixtures are dated against THIS, not against a
  # year-2286 sentinel, or they exercise the refusal instead of the harvest.
  _CLEAT_NOW_S=1789000000
  # No test reaches a real Anthropic host. Tests that assert on curl redefine it.
  curl() { cat >/dev/null 2>&1; return 7; }
}
teardown() { _common_teardown; }

CN="cleat-proj-abcdef12"

# A credential blob shaped like the real one. $1 = expiresAt (epoch ms),
# $2 = refreshToken (empty means signed out), $3 = refreshTokenExpiresAt.
#
# Fixture convention for every harvest test: a GENERATION tag (which refresh of
# a login this is) lives in accessToken. refreshToken names the GRANT (which
# login it is). A refresh keeps the grant, so two generations of one login share
# a refreshToken. That keeps an identity check that recognises the same grant
# offline, with no profile request.
_cred_blob() {
  # `${2-...}` and not `${2:-...}`: an EXPLICITLY empty refresh token is the
  # invalid_grant state and has to survive being passed in.
  local exp="${1:-1789003600000}" rt="${2-r-token}" rte="${3:-}"
  if [[ -n "$rte" ]]; then
    printf '{"claudeAiOauth":{"accessToken":"a-token","refreshToken":"%s","expiresAt":%s,"refreshTokenExpiresAt":%s,"subscriptionType":"max"}}\n' "$rt" "$exp" "$rte"
  else
    printf '{"claudeAiOauth":{"accessToken":"a-token","refreshToken":"%s","expiresAt":%s,"subscriptionType":"max"}}\n' "$rt" "$exp"
  fi
}

_mk_account() {   # $1 = name, $2 = expiresAt, $3 = refreshToken, $4 = refreshTokenExpiresAt
  mkdir -p "$CLEAT_ACCOUNTS_DIR/$1"
  chmod 700 "$CLEAT_ACCOUNTS_DIR/$1"
  _cred_blob "${2:-1789003600000}" "${3-r-token}" "${4:-}" > "$CLEAT_ACCOUNTS_DIR/$1/.credentials.json"
  chmod 600 "$CLEAT_ACCOUNTS_DIR/$1/.credentials.json"
}

_mk_staged() {   # $1 = cname, $2 = expiresAt
  mkdir -p "$CLEAT_RUN_DIR/$1/auth"
  _cred_blob "${2:-1789003600000}" > "$CLEAT_RUN_DIR/$1/auth/.credentials.json"
}

_pass_gates() {
  _daemon_up() { return 1; }          # no daemon: the verb must work anyway
  container_exists() { return 1; }
  _box_has_live_agent() { return 1; }
}

# Two account uuids in the alphabet the server uses.
UUID_WORK="0b8f2a6e-1c3d-4e5f-8a9b-0c1d2e3f4a5b"
UUID_OTHER="7d6c5b4a-3928-4716-9504-a3b2c1d0e9f8"

# A GET /api/oauth/profile body shaped like the real one: a flat account, and an
# organisation that carries an empty object of its own. $1 uuid, $2 email,
# $3 organisation name.
_profile_body() {
  printf '{"account":{"uuid":"%s","email":"%s","full_name":"Lab Person","has_claude_max":true},"organization":{"uuid":"org-0001","name":"%s","cc_onboarding_flags":{}}}' \
    "$1" "$2" "${3:-Acme Ltd}"
}

# The profile request answers 200 with that body, and each request leaves a
# line in $TEST_TEMP/profile-asked. Tests that never set this get the setup's
# curl, which answers nothing, so the identity reads as "cannot tell".
_profile_says() {
  _PROFILE_BODY="$(_profile_body "$@")"
  _account_profile_curl() { printf 'asked\n' >> "$TEST_TEMP/profile-asked"; printf '%s\n200' "$_PROFILE_BODY"; }
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
  for n in list rename rm delete restore trash held adopt off help; do
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

@test "account: switching from a logged-in account to a new one leaves nothing staged to harvest" {
  # An account with nothing stored is the clean scope, so /login lands in the
  # right store. The attach no longer clears a staged file to make it one,
  # because that file can be the only copy of a login made in the box. The
  # switch's own drop is therefore the one thing that keeps the account being
  # LEFT out of the new store: without it the next attach harvests it there.
  _pass_gates
  _mk_account old 1789000100000 old-token
  _box_account_write "$CN" old
  _mk_staged "$CN" 1789003600000
  run _account_do_switch new main "$CN" "$TEST_TEMP/proj"
  assert_success
  _account_box_ready() { return 0; }
  CLAUDE_ENV=()
  run _account_apply_exec_env "$CN"
  assert_success
  run test -e "$CLEAT_RUN_DIR/$CN/auth/.credentials.json"
  assert_failure
  run test -e "$CLEAT_ACCOUNTS_DIR/new/.credentials.json"
  assert_failure
}

@test "account: an attach pinned to a missing account keeps the staged login and recreates nothing" {
  # A pin can outlive its store: a store removed by hand, or trashed or renamed
  # away by a command that raced this box. The staged file can be that login's
  # freshest copy, and `cleat account restore` reconnects it.
  local staged="$CLEAT_RUN_DIR/$CN/auth/.credentials.json"
  _box_account_write "$CN" gone
  _mk_staged "$CN"
  ln "$staged" "$TEST_TEMP/staged.link"
  run _account_sync_in "$CN"
  assert_success
  # Same inode: neither removed nor replaced.
  run test "$staged" -ef "$TEST_TEMP/staged.link"
  assert_success
  run test -e "$CLEAT_ACCOUNTS_DIR/gone"
  assert_failure
  # A store that is a symlink is not an account either, so nothing it points
  # at is staged over the box's login.
  mkdir -p "$TEST_TEMP/outside"
  _cred_blob 1789007200000 planted > "$TEST_TEMP/outside/.credentials.json"
  ln -s "$TEST_TEMP/outside" "$CLEAT_ACCOUNTS_DIR/gone"
  run _account_sync_in "$CN"
  assert_success
  run test "$staged" -ef "$TEST_TEMP/staged.link"
  assert_success
  run cat "$staged"
  refute_output --partial "planted"
}

@test "account: staging never overwrites a newer credential the box refreshed" {
  _mk_account work 1000
  _box_account_write "$CN" work
  _mk_staged "$CN" 1789003600000
  ln "$CLEAT_ACCOUNTS_DIR/work/.credentials.json" "$TEST_TEMP/store.link"
  run _account_sync_in "$CN"
  assert_success
  run grep -c 1789003600000 "$CLEAT_RUN_DIR/$CN/auth/.credentials.json"
  assert_output "1"
  # The same grant, refreshed in the box, is recognised from the bytes alone.
  # An attach writes nothing: not the box's file, which a live session holds
  # open, and not the store, which a sibling box on this account may be
  # reading. The session end is what carries the refresh back.
  run test "$CLEAT_ACCOUNTS_DIR/work/.credentials.json" -ef "$TEST_TEMP/store.link"
  assert_success
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
  _mk_staged "$CN" 1789003600000
  run _account_sync_out "$CN"
  assert_success
  run grep -c 1789003600000 "$CLEAT_ACCOUNTS_DIR/work/.credentials.json"
  assert_output "1"
}

@test "account: harvesting never replaces a newer stored credential with an older one" {
  _mk_account work 1789003600000
  _box_account_write "$CN" work
  _mk_staged "$CN" 1000
  run _account_sync_out "$CN"
  assert_success
  run grep -c 1789003600000 "$CLEAT_ACCOUNTS_DIR/work/.credentials.json"
  assert_output "1"
}

@test "account: harvesting is a no-op for an unpinned box" {
  _mk_staged "$CN" 1789003600000
  run _account_sync_out "$CN"
  assert_success
  [ ! -d "$CLEAT_ACCOUNTS_DIR/default" ]
}

@test "account: harvesting refuses a symlinked box credential" {
  _mk_account work 1000
  _box_account_write "$CN" work
  mkdir -p "$CLEAT_RUN_DIR/$CN/auth"
  _cred_blob 1789003600000 > "$TEST_TEMP/planted.json"
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
  _mk_staged "$CN" 1789003600000
  run _account_wipe_run_dir "$CN"
  assert_success
  [ ! -d "$CLEAT_RUN_DIR/$CN" ]
  run grep -c 1789003600000 "$CLEAT_ACCOUNTS_DIR/work/.credentials.json"
  assert_output "1"
}

@test "account: the whole-run-dir wipe harvests every pinned box" {
  _mk_account work 1000
  _box_account_write "$CN" work
  _mk_staged "$CN" 1789003600000
  run _account_release_all
  assert_success
  run grep -c 1789003600000 "$CLEAT_ACCOUNTS_DIR/work/.credentials.json"
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
  _mk_account work 1789003600000 ""
  run _account_auth_state work
  assert_output "signed out"
}

@test "account: an expired refresh token reads as re-login" {
  _mk_account work 1789003600000 r-token 1000
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
  _mk_account work 17890036000009
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

@test "account: a harvest for an account that is gone creates nothing and keeps the staged login" {
  # Only an explicit create makes a store. And the harvest says it declined,
  # because the wipe that asked keeps the staged file only on a failure, and
  # that file can be the only copy of what the box refreshed.
  local leg staged="$CLEAT_RUN_DIR/$CN/auth/.credentials.json"
  eval "$(declare -f _account_write_cred | sed '1s/^_account_write_cred /_orig_write_cred /')"
  for leg in before during; do
    _GONE_ACCT="gone-$leg"
    # The same grant as the staged login, so the harvest decides with no request.
    _mk_account "$_GONE_ACCT" 1789003600000
    _box_account_write "$CN" "$_GONE_ACCT"
    _mk_staged "$CN" 1789007200000
    if [[ "$leg" == before ]]; then
      _account_trash "$_GONE_ACCT"
    else
      # Gone after the harvest has decided, which is where `cleat account rm`
      # in another terminal lands.
      _account_write_cred() { _account_trash "$_GONE_ACCT" || true; _orig_write_cred "$@"; }
    fi
    run _account_wipe_run_dir "$CN"
    assert_success
    run test -e "$CLEAT_ACCOUNTS_DIR/$_GONE_ACCT"
    assert_failure
    run test -f "$staged"
    assert_success
  done
}

@test "account: a usage poll that outlives account rm does not recreate the account" {
  # The poll waits on the network for up to three seconds and records the
  # numbers afterwards. A store removed meanwhile is not put back to hold them,
  # or `restore` refuses.
  command -v jq >/dev/null 2>&1 || skip "the usage poll needs jq"
  _mk_account work 1789007200000
  curl() {
    cat >/dev/null 2>&1
    _account_trash work
    printf '%s' '{"five_hour":{"utilization":16,"resets_at":"2026-09-10T02:00:00Z"},"seven_day":{"utilization":40,"resets_at":"2026-09-15T02:00:00Z"}}'
  }
  run _account_usage_fetch work
  run test -e "$CLEAT_ACCOUNTS_DIR/work"
  assert_failure
  run _account_restore work
  assert_success
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

# ── the trash view ─────────────────────────────────────────────────────────

# $1 = name, $2 = stamp, and optionally $3 = the email its meta should carry.
_mk_trashed() {
  local d="$CLEAT_ACCOUNTS_DIR/.trash/${2}-${1}"
  mkdir -p "$d"
  [ -n "${3:-}" ] && printf 'who\t%s\n' "$3" > "$d/meta"
  return 0
}

@test "account: the trash scan lists what is in the trash, newest first" {
  _mk_trashed old 1788000000
  _mk_trashed recent 1788900000
  run _account_trash_scan_sorted
  assert_success
  [ "$(echo "$output" | head -n1 | cut -f2)" = "recent" ]
  [ "$(echo "$output" | tail -n1 | cut -f2)" = "old" ]
}

@test "account: the trash scan skips what it cannot name" {
  # Same discipline as the sweep: a directory with no stamp, or whose
  # remainder is not a legal account name, is not a row. Otherwise a hand-made
  # directory becomes a row the picker then refuses to restore.
  _mk_trashed work 1788000000
  mkdir -p "$CLEAT_ACCOUNTS_DIR/.trash/not-a-stamp-work"
  mkdir -p "$CLEAT_ACCOUNTS_DIR/.trash/1788000001-Bad Name"
  ln -s "$TEST_TEMP" "$CLEAT_ACCOUNTS_DIR/.trash/1788000002-linked"
  run _account_trash_scan
  assert_success
  [ "$(echo "$output" | wc -l | tr -d ' ')" -eq 1 ]
  assert_output --partial "work"
}

@test "account: the trash count counts exactly what the scan counts" {
  _mk_trashed work 1788000000
  _mk_trashed other 1788000001
  mkdir -p "$CLEAT_ACCOUNTS_DIR/.trash/not-a-stamp-work"
  # A real stamp with a name the picker would refuse to restore. Counting it
  # would advertise a trash the view then draws one row shorter.
  mkdir -p "$CLEAT_ACCOUNTS_DIR/.trash/1788000002-Bad Name"
  run _account_trash_count
  assert_output "2"
}

@test "account: the trash count is zero when the trash is a symlink" {
  # _account_trash_dir refuses it, and a count that fell through to an error
  # would print nothing where the frame expects a number.
  ln -s "$TEST_TEMP/outside" "$CLEAT_ACCOUNTS_DIR/.trash"
  run _account_trash_count
  assert_output "0"
}

@test "account: meta reads by directory, so a removed account still says whose it was" {
  _mk_trashed work 1788000000 "gone@example.com"
  run _account_meta_get_at "$CLEAT_ACCOUNTS_DIR/.trash/1788000000-work" who
  assert_output "gone@example.com"
}

@test "account: the trash rows carry the name, the email and when it went" {
  _mk_trashed work 1788996400 "gone@example.com"
  _accounts_load_trash_rows
  [ "$_ACCT_N" -eq 1 ]
  [ "${_ACCT_NAME[0]}" = "work" ]
  [ "${_ACCT_AUTH[0]}" = "removed" ]
  [ "${_ACCT_WHO[0]}" = "gone@example.com" ]
  # Nothing in the trash is the active account, so no row is ever marked.
  [ "${_ACCT_MARK[0]}" = "0" ]
  echo "${_ACCT_D2[0]}" | grep -q "removed"
  echo "${_ACCT_D2[0]}" | grep -q "kept 30 days"
}

@test "account: a trash row with no meta says so instead of guessing" {
  _mk_trashed work 1788996400
  _accounts_load_trash_rows
  [ "${_ACCT_WHO[0]}" = "no login was recorded" ]
}

@test "account: the trash frame keeps the page + 4 invariant the live one has" {
  # The cursor-up reposition walks _ACCT_PAGE + 4 lines in both views. A view
  # that drew one line more or fewer would leave the list walking down the
  # screen one row per keypress.
  _term_rows() { echo 24; }; _term_cols() { echo 100; }
  _mk_trashed work 1788996400
  _mk_trashed other 1788996401
  _ACCT_VIEW="trash"
  _accounts_load_trash_rows
  _accounts_measure "$_ACCT_N"
  [ "$_ACCT_N" -eq 2 ]
  [ "$(_acct_draw_lines _accounts_frame 0 0 "$_ACCT_PAGE" 100 "$_ACCT_N")" -eq "$(( _ACCT_PAGE + 4 ))" ]
  # And an EMPTY trash still draws the full block, or the reposition would walk
  # past the top of the frame the moment the last item was restored.
  rm -rf "$CLEAT_ACCOUNTS_DIR/.trash"
  _accounts_load_trash_rows
  _accounts_measure "$_ACCT_N"
  [ "$(_acct_draw_lines _accounts_frame 0 0 "$_ACCT_PAGE" 100 "$_ACCT_N")" -eq "$(( _ACCT_PAGE + 4 ))" ]
}

@test "account: the trash view says restore and says how to get back" {
  _mk_trashed work 1788996400
  _ACCT_VIEW="trash"
  _accounts_load_trash_rows
  _accounts_frame 0 0 1 100 "$_ACCT_N" > "$TEST_TEMP/frame.out" 2>/dev/null
  grep -q "restore" "$TEST_TEMP/frame.out"
  grep -q "back" "$TEST_TEMP/frame.out"
  grep -q "Trash: 1 account, kept 30 days" "$TEST_TEMP/frame.out"
}

@test "account: an empty trash says so rather than drawing nothing" {
  _ACCT_VIEW="trash"
  _accounts_load_trash_rows
  [ "$_ACCT_N" -eq 0 ]
  _accounts_frame 0 0 1 100 0 > "$TEST_TEMP/frame.out" 2>/dev/null
  grep -q "The trash is empty" "$TEST_TEMP/frame.out"
}

@test "account: the live frame advertises the trash only when there is one" {
  _term_cols() { echo 100; }
  _mk_account one
  _ACCT_VIEW="live"
  _accounts_load_rows one
  _ACCT_TRASH_N=0
  _accounts_frame 0 0 "$_ACCT_N" 100 "$_ACCT_N" > "$TEST_TEMP/empty.out" 2>/dev/null
  run grep -q "trash" "$TEST_TEMP/empty.out"
  assert_failure
  _ACCT_TRASH_N=2
  _accounts_frame 0 0 "$_ACCT_N" 100 "$_ACCT_N" > "$TEST_TEMP/full.out" 2>/dev/null
  grep -q "trash (2)" "$TEST_TEMP/full.out"
}

@test "account: the trash pointer never widens the narrowest supported frame" {
  # It sits on the counter line and not the hint line for exactly this reason:
  # the hint is already 37 columns against a 44-column minimum, and a wrapped
  # line walks the whole block down the screen one row per keypress.
  _mk_account one
  _ACCT_VIEW="live"
  _accounts_load_rows one
  _ACCT_TRASH_N=99
  _accounts_frame 0 0 1 44 1 > "$TEST_TEMP/frame.out" 2>/dev/null
  local widest
  widest="$(sed $'s/\033\\[[0-9;]*[A-Za-z]//g' "$TEST_TEMP/frame.out" \
    | sed 's/↑/^/g; s/↓/v/g; s/⏎/E/g; s/▸/>/g; s/·/./g; s/…/./g; s/•/o/g; s/→/-/g; s/←/-/g' \
    | awk '{ n = length($0); if (n > m) m = n } END { print m + 0 }')"
  [ "$widest" -le 44 ]
}

@test "account: the picker crosses to the trash and restores from it" {
  _pass_gates
  _term_rows() { echo 24; }; _term_cols() { echo 100; }
  _mk_account keep
  _mk_account work
  _account_trash work
  [ ! -d "$CLEAT_ACCOUNTS_DIR/work" ]
  # Right into the trash, Enter on its only row, then quit.
  _acct_keys RIGHT ENTER QUIT
  run _accounts_picker_tui main "$CN" "$TEST_TEMP/proj"
  assert_success
  [ -d "$CLEAT_ACCOUNTS_DIR/work" ]
}

@test "account: left comes back to the live list without acting" {
  _pass_gates
  _term_rows() { echo 24; }; _term_cols() { echo 100; }
  _mk_account keep
  _mk_account work
  _account_trash work
  # Enter AFTER the left arrow, so the assertion proves which list the picker
  # was actually on. A left arrow that did nothing would leave Enter on the
  # trash row, and the restore would be the thing that ran.
  _acct_keys RIGHT LEFT ENTER QUIT QUIT
  run _accounts_picker_tui main "$CN" "$TEST_TEMP/proj"
  assert_success
  [ ! -d "$CLEAT_ACCOUNTS_DIR/work" ]
}

@test "account: enter on an empty trash does not close the picker" {
  # Pressing Enter on nothing is an ordinary thing to do. Ending the verb there
  # would throw the user back to a shell prompt for a keypress that means
  # nothing.
  _pass_gates
  _term_rows() { echo 24; }; _term_cols() { echo 100; }
  _mk_account keep
  _acct_keys RIGHT ENTER QUIT
  run _accounts_picker_tui main "$CN" "$TEST_TEMP/proj"
  assert_success
  assert_output --partial "Cancelled"
}

@test "account: removing the last account shows the trash instead of dropping out" {
  # The account just removed is in the trash and nowhere else. Being thrown to
  # a shell prompt with a command to retype is the unfriendliness this is about.
  _pass_gates
  _term_rows() { echo 24; }; _term_cols() { echo 100; }
  _mk_account work
  _account_trash work
  _acct_keys ENTER QUIT
  run _accounts_picker_tui main "$CN" "$TEST_TEMP/proj"
  assert_success
  assert_output --partial "Showing the trash"
  [ -d "$CLEAT_ACCOUNTS_DIR/work" ]
}

@test "account: restoring the wrong lookalike is still refused through the picker" {
  # A dash is legal inside an account name, so `*-work` also matches
  # `<stamp>-my-work`. The picker hands a NAME to the restore, which splits on
  # the stamp, so the lookalike must stay where it is.
  _pass_gates
  _term_rows() { echo 24; }; _term_cols() { echo 100; }
  _mk_account keep
  _mk_account my-work
  _account_trash my-work
  _acct_keys RIGHT ENTER QUIT
  run _accounts_picker_tui main "$CN" "$TEST_TEMP/proj"
  assert_success
  [ -d "$CLEAT_ACCOUNTS_DIR/my-work" ]
}

@test "account: cleat account trash lists the removed ones" {
  _mk_trashed work 1788996400 "gone@example.com"
  run _accounts_trash_text
  assert_success
  assert_output --partial "work"
  assert_output --partial "gone@example.com"
  assert_output --partial "cleat account restore"
}

@test "account: cleat account trash says the trash is empty rather than printing a bare header" {
  run _accounts_trash_text
  assert_success
  assert_output --partial "empty"
}

@test "account: the plain list points at the trash when something is in it" {
  # The picker advertises it on the counter line. Without this the non-TTY path
  # is the one place a removed account is invisible.
  _mk_account keep
  _mk_trashed work 1788996400
  run _accounts_picker_text main "$CN"
  assert_success
  assert_output --partial "1 in the trash"
}

@test "account: an empty account list still points at the trash" {
  _mk_trashed work 1788996400
  run _accounts_picker_text main "$CN"
  assert_success
  assert_output --partial "No named accounts yet"
  assert_output --partial "1 in the trash"
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
  # A running session takes only part of a login change: the next token, not
  # the store path or the account identity it started with. The reason it is
  # told is pinned in regressions.bats.
  _mk_account work
  _daemon_up() { return 0; }
  container_exists() { return 0; }
  is_running() { return 0; }
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

@test "account: the recreate remedy for a box without the account mount is a real command" {
  # It printed `cleat rm main then cleat main`, and `cleat main` is not a
  # command: the binary answers "Unknown command: main" with rc 1.
  _mk_account work
  _daemon_up() { return 0; }
  container_exists() { return 0; }
  _box_has_live_agent() { return 1; }
  docker() { case "$1" in exec) return 1 ;; *) return 0 ;; esac; }
  run _account_do_switch work main "$CN" "$TEST_TEMP/proj"
  assert_failure
  assert_output --partial "cleat start main"
  refute_output --regexp "then [^ ]*cleat [^ ]*main"
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
  is_running() { return 0; }
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

@test "account: a wipe that would reach the account store is refused" {
  # cmd_nuke prints "your ~/.claude auth is safe" and then removes four state
  # directories. Today the accounts tree is merely a SIBLING of all four, so
  # the promise holds by directory layout and by nothing else. This is the
  # guard that makes it hold by construction: one future edit that widens a
  # wipe to the config dir, or that moves the store under one of the four,
  # would otherwise destroy weeks of refresh token silently.
  _mk_account work
  run _nuke_wipe_dir "$(dirname "$CLEAT_ACCOUNTS_DIR")"
  assert_failure
  assert_output --partial "named Claude logins"
  [ -f "$CLEAT_ACCOUNTS_DIR/work/.credentials.json" ]
}

@test "account: the store directory itself is refused, not only its parent" {
  _mk_account work
  run _nuke_wipe_dir "$CLEAT_ACCOUNTS_DIR"
  assert_failure
  [ -d "$CLEAT_ACCOUNTS_DIR/work" ]
  run _nuke_wipe_dir "$CLEAT_BOX_ACCOUNTS_DIR"
  assert_failure
}

@test "account: an ordinary state directory is still wiped" {
  # The guard must refuse the account store and nothing else, or nuke stops
  # doing its job.
  mkdir -p "$CLEAT_RUN_DIR/somebox"
  run _nuke_wipe_dir "$CLEAT_RUN_DIR"
  assert_success
  [ ! -d "$CLEAT_RUN_DIR" ]
}

@test "account: a trailing slash does not defeat the wipe guard" {
  _mk_account work
  run _nuke_wipe_dir "$CLEAT_ACCOUNTS_DIR/"
  assert_failure
  [ -d "$CLEAT_ACCOUNTS_DIR/work" ]
}

@test "account: a directory that merely shares a prefix is not protected" {
  # The guard asks whether the STORE sits under the directory being wiped, so
  # the dangerous shortcut is a prefix test with no slash: the store
  # .../accounts would then read as "under" .../account, and a legitimate wipe
  # of a differently-named sibling would be refused forever. Hence a dir whose
  # name is a strict prefix of the store's.
  local prefix="${CLEAT_ACCOUNTS_DIR%s}"
  [ "$prefix" != "$CLEAT_ACCOUNTS_DIR" ]
  mkdir -p "$prefix/something"
  run _nuke_wipe_dir "$prefix"
  assert_success
  [ ! -d "$prefix" ]
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

# ── what the adversarial pass found ────────────────────────────────────────
#
# Everything below is a defect that a green suite did not see. They are grouped
# because they share one property: each is silent when it breaks.

@test "account: switching stages the incoming credential even when the box's is newer" {
  # THE critical one. Newest-wins is only valid WITHIN an account. Across a
  # switch the staged file belongs to the account being LEFT and is usually the
  # fresher of the two, so the staging declined and the box kept the OLD
  # account's credential while pinned to the new one.
  _pass_gates
  _mk_account old 1789003600000 old-token
  _mk_account new 1789000100000 new-token
  _box_account_write "$CN" old
  _mk_staged "$CN" 1789003600000
  run _account_do_switch new main "$CN" "$TEST_TEMP/proj"
  assert_success
  run grep -c "1789000100000" "$CLEAT_RUN_DIR/$CN/auth/.credentials.json"
  assert_output "1"
}

@test "account: switching does not write the old account's token into the new store" {
  # The second half of the same defect, and the destructive one: the stale
  # staged copy was harvested INTO the account just switched to, destroying its
  # refresh token with no trash and no undo.
  _pass_gates
  _mk_account old 1789003600000 old-token
  _mk_account new 1789000100000 new-token
  _box_account_write "$CN" old
  _mk_staged "$CN" 1789003600000
  _account_do_switch new main "$CN" "$TEST_TEMP/proj"
  _account_sync_out "$CN" || true
  run grep -c "new-token" "$CLEAT_ACCOUNTS_DIR/new/.credentials.json"
  assert_output "1"
}

@test "account: restore does not resurrect a different account whose name ends the same" {
  # A dash is legal inside an account name, so the old suffix glob matched
  # <stamp>-my-work when asked for `work`: it restored the wrong store under
  # the wrong name and stranded the real one in the trash forever.
  _mk_account my-work 1789003600000 mine
  _account_trash my-work
  run _account_restore work
  assert_failure
  [ ! -d "$CLEAT_ACCOUNTS_DIR/work" ]
  [ -d "$CLEAT_ACCOUNTS_DIR/.trash/"*"-my-work" ]
}

@test "account: restore still finds an account whose own name contains a dash" {
  _mk_account my-work
  _account_trash my-work
  run _account_restore my-work
  assert_success
  [ -d "$CLEAT_ACCOUNTS_DIR/my-work" ]
}

@test "account: a box cannot destroy a stored credential with a tokenless blob" {
  # The harvest reads a directory the box mounts read-write. "Newer" alone
  # earned an overwrite of the host's only copy, so a box could drop a JSON
  # object with a huge expiry and no tokens in it and sign the account out
  # permanently.
  _mk_account work 1789000100000 real-token
  _box_account_write "$CN" work
  mkdir -p "$CLEAT_RUN_DIR/$CN/auth"
  printf '{"claudeAiOauth":{"expiresAt":1789003600000}}\n' > "$CLEAT_RUN_DIR/$CN/auth/.credentials.json"
  run _account_sync_out "$CN"
  assert_failure
  run grep -c "real-token" "$CLEAT_ACCOUNTS_DIR/work/.credentials.json"
  assert_output "1"
  # A live access token and no refresh token, which the server does vouch for:
  # it is this account's, and saving it would still sign the account out for good.
  printf 'uuid\t%s\n' "$UUID_WORK" > "$CLEAT_ACCOUNTS_DIR/work/meta"
  printf '{"claudeAiOauth":{"accessToken":"live-access","expiresAt":1789003600000}}\n' > "$CLEAT_RUN_DIR/$CN/auth/.credentials.json"
  _profile_says "$UUID_WORK" work@example.com
  run _account_sync_out "$CN"
  assert_failure
  run grep -c "real-token" "$CLEAT_ACCOUNTS_DIR/work/.credentials.json"
  assert_output "1"
}

@test "account: a harvest is refused when the expiry is further out than any real token" {
  # The same grant, so nothing but the bound stands between it and the store.
  _mk_account work 1789000100000
  _box_account_write "$CN" work
  _mk_staged "$CN" 99999999999999
  run _account_sync_out "$CN"
  assert_failure
  run grep -c "1789000100000" "$CLEAT_ACCOUNTS_DIR/work/.credentials.json"
  assert_output "1"
}

@test "account: an oversized credential file is never read into a shell variable" {
  _account_ensure_dir work
  # A real credential is a few hundred bytes. This is a valid JSON OBJECT, so
  # only the size guard can refuse it: asserting on the predicate alone would
  # pass with the guard removed from the write path. The bulk is trailing
  # whitespace, so the part the merge reads under its own cap is still a whole
  # object and the merge alone would write it.
  { printf '{"claudeAiOauth":{"accessToken":"a","refreshToken":"r","expiresAt":1}}'; head -c 200000 /dev/zero | tr '\0' ' '; printf '\n'; } > "$TEST_TEMP/big.json"
  run _account_write_cred work "$TEST_TEMP/big.json"
  assert_failure
  [ ! -f "$CLEAT_ACCOUNTS_DIR/work/.credentials.json" ]
}

@test "account: switching to a new account does not stamp it with the previous email" {
  # The project store still holds the OUTGOING account's identity, so passing
  # it to the capture made the list name an account it had never seen.
  _pass_gates
  _mk_account old
  _mk_account new
  _box_account_write "$CN" old
  _account_meta_set old who "previous@example.com"
  # The project store still holds the OUTGOING identity. Without it the capture
  # reads nothing either way and this test passes whatever the code does.
  local key
  key="$(_derive_project_session_key "$TEST_TEMP/proj" main)"
  mkdir -p "$CLEAT_PROJECTS_DIR/$key"
  printf '{"oauthAccount":{"emailAddress":"previous@example.com","organizationName":"Old Org"}}\n' \
    > "$CLEAT_PROJECTS_DIR/$key/claude.json"
  run _account_do_switch new main "$CN" "$TEST_TEMP/proj"
  assert_success
  run _account_meta_get new who
  assert_failure
}

@test "account: the accounts directory itself is not world-readable" {
  # mkdir -p creates the PARENT at the host umask, so locking only the leaf
  # left every account NAME listable by anything on the machine.
  rm -rf "$CLEAT_ACCOUNTS_DIR"
  umask 022
  _account_ensure_dir work
  [ "$(stat -c '%a' "$CLEAT_ACCOUNTS_DIR" 2>/dev/null || stat -f '%Lp' "$CLEAT_ACCOUNTS_DIR")" = "700" ]
}

@test "account: cleat clean harvests before it prunes an orphaned run dir" {
  _mk_account work 1000
  _box_account_write "$CN" work
  _mk_staged "$CN" 1789003600000
  container_exists() { return 1; }
  mock_docker_ps ""
  run cmd_clean
  run grep -c "1789003600000" "$CLEAT_ACCOUNTS_DIR/work/.credentials.json"
  assert_output "1"
}

@test "account: a failed harvest leaves the staged credential rather than deleting it" {
  # The staged file may be the only copy of a token the box refreshed, so a
  # wipe that follows a failed harvest must not destroy the thing the harvest
  # was protecting.
  _mk_account work 1789003600000 newer
  _box_account_write "$CN" work
  _mk_staged "$CN" 1000
  mkdir -p "$CLEAT_RUN_DIR/$CN/clip"
  _account_sync_out_locked() { return 1; }
  run _account_wipe_run_dir "$CN"
  assert_success
  [ -f "$CLEAT_RUN_DIR/$CN/auth/.credentials.json" ]
  [ ! -d "$CLEAT_RUN_DIR/$CN/clip" ]
}

@test "account: removing an account harvests every pinned box before the store moves" {
  # After the trash the store path is gone, so a harvest from there is declined
  # and what the box refreshed never reaches the copy restore brings back.
  _pass_gates
  _mk_account work 1000 old-token
  _box_account_write "box-a" work
  mkdir -p "$CLEAT_RUN_DIR/box-a/auth"
  _cred_blob 1789003600000 harvested > "$CLEAT_RUN_DIR/box-a/auth/.credentials.json"
  # The refresh rotated the token, so the server has to say whose login it is.
  _profile_says "$UUID_WORK" work@example.com
  run _account_do_remove work 1
  assert_success
  [ ! -d "$CLEAT_ACCOUNTS_DIR/work" ]
  # No -r: BSD grep prefixes each count with the file name when it recurses,
  # so this read "path:1" on macOS and bare "1" on Linux. One file, one count.
  run bash -c 'grep -c harvested "$1"/.trash/*-work/.credentials.json' _ "$CLEAT_ACCOUNTS_DIR"
  assert_output "1"
}

@test "account: cleat login carries the credential store override" {
  # /login is the one command whose whole job is to WRITE a credential, so a
  # pinned box reaching it without the override wrote the new account straight
  # into the shared host login and clobbered it.
  _mk_account work
  _box_account_write "cleat-logintest" work
  docker() {
    case "$1" in
      inspect) printf '%s\n' "/home/coder/.cleat-auth" ;;
      *) command docker "$@" ;;
    esac
  }
  _daemon_up() { return 0; }
  container_exists() { return 0; }
  run _account_apply_exec_env "cleat-logintest"
  assert_success
  printf '%s\n' "${CLAUDE_ENV[@]}" > "$TEST_TEMP/env.out"
  _account_apply_exec_env "cleat-logintest" || true
  printf '%s\n' "${CLAUDE_ENV[@]}" > "$TEST_TEMP/env.out"
  run cat "$TEST_TEMP/env.out"
  assert_output --partial "CLAUDE_SECURESTORAGE_CONFIG_DIR=/home/coder/.cleat-auth"
}

@test "account: a box with no auth mount is never pointed at a store it does not have" {
  _mk_account work
  _box_account_write "cleat-nomount" work
  docker() { case "$1" in inspect) printf '%s\n' "/workspace" ;; *) return 0 ;; esac; }
  _daemon_up() { return 0; }
  container_exists() { return 0; }
  run _account_apply_exec_env "cleat-nomount"
  assert_failure
  assert_output --partial "cleat rm"
  printf '%s\n' "${CLAUDE_ENV[@]}" > "$TEST_TEMP/env.out"
  run grep -c CLAUDE_SECURESTORAGE "$TEST_TEMP/env.out"
  assert_output "0"
}

@test "account: the mount probe reads a STOPPED box rather than execing into it" {
  # docker exec needs a RUNNING container, so a merely stopped box answered
  # "no mount" and every switch against one was refused for a reason that was
  # not true.
  _daemon_up() { return 0; }
  container_exists() { return 0; }
  : > "$TEST_TEMP/docker.log"
  docker() {
    echo "$1" >> "$TEST_TEMP/docker.log"
    case "$1" in inspect) printf '%s\n' "/home/coder/.cleat-auth" ;; *) return 1 ;; esac
  }
  run _account_box_ready "cleat-stopped"
  assert_success
  run cat "$TEST_TEMP/docker.log"
  refute_output --partial "exec"
}

@test "account: going back to the shared login respects the live-session gate" {
  _mk_account work
  _box_account_write "$CN" work
  _daemon_up() { return 0; }
  container_exists() { return 0; }
  is_running() { return 0; }
  _box_has_live_agent() { return 0; }
  run _account_do_switch default main "$CN" "$TEST_TEMP/proj"
  assert_failure
  assert_output --partial "live Claude session"
  run _box_account_read "$CN"
  assert_output "work"
}

@test "account: an emptied shared credential is not reported as logged in" {
  # On invalid_grant the client writes EMPTY tokens back to disk, so the file
  # survives a logout. Non-empty is not the same as usable.
  mkdir -p "$HOME/.claude"
  printf '{"claudeAiOauth":{"accessToken":"","refreshToken":"","expiresAt":0}}\n' > "$HOME/.claude/.credentials.json"
  run _account_cred_plausible "$HOME/.claude/.credentials.json"
  assert_failure
}

@test "account: an age is never printed with the word ago twice" {
  _account_ensure_dir work
  _CLEAT_NOW_S=1789000000
  _account_meta_set work last_used 1788980000
  _accounts_load_rows default
  printf '%s\n' "${_ACCT_D2[1]}" > "$TEST_TEMP/d2"
  run cat "$TEST_TEMP/d2"
  assert_output --partial "ago"
  refute_output --partial "ago ago"
}

@test "account: a stale usage snapshot says so even when the line is truncated" {
  # The pane clamps from the right, so a trailing "(as of ...)" was the first
  # thing cut on a narrow terminal and an hours-old percentage was then shown
  # as if it were current.
  _account_ensure_dir work
  _CLEAT_NOW_S=1789000000
  _account_meta_set work usage_at 1788980000
  _account_meta_set work usage_five 16
  _account_meta_set work usage_five_resets 1789900000
  run _account_usage_render work
  assert_success
  [[ "$output" == "last known "* ]]
}

@test "account: an account name too wide for its column is visibly truncated" {
  _mk_account a-very-long-account-name
  _accounts_load_rows default
  _accounts_frame 1 0 2 100 "$_ACCT_N" > "$TEST_TEMP/frame.out" 2>/dev/null
  run cat "$TEST_TEMP/frame.out"
  assert_output --partial "…"
  refute_output --partial "a-very-long-account-name"
}

@test "account: a short name is never truncated and never padded away" {
  _mk_account work
  _accounts_load_rows default
  _accounts_frame 1 0 2 100 "$_ACCT_N" > "$TEST_TEMP/frame.out" 2>/dev/null
  run cat "$TEST_TEMP/frame.out"
  assert_output --partial "work"
}

@test "account: a wide-character detail line is budgeted at two columns per glyph" {
  # Observable as a DIFFERENCE, not as an absolute width: under the C locale
  # bash counts BYTES, which already over-clamps, so "is it under 50 columns"
  # passes with or without the halving. What the halving changes is how much
  # is shown.
  _mk_account work
  _account_meta_set work org "株式会社株式会社株式会社株式会社株式会社株式会社"
  _has_unicode() { return 1; }
  _accounts_load_rows default
  _accounts_frame 1 0 2 50 "$_ACCT_N" > "$TEST_TEMP/wide.off" 2>/dev/null
  _has_unicode() { return 0; }
  _accounts_load_rows default
  _accounts_frame 1 0 2 50 "$_ACCT_N" > "$TEST_TEMP/wide.on" 2>/dev/null
  local off on
  off="$(wc -c < "$TEST_TEMP/wide.off" | tr -d ' ')"
  on="$(wc -c < "$TEST_TEMP/wide.on" | tr -d ' ')"
  [ "$on" -lt "$off" ] || { echo "unicode budget did not shrink the pane: $on vs $off"; return 1; }
}

@test "account: a wide-character organisation name cannot overflow the detail pane" {
  _has_unicode() { return 0; }
  _mk_account work
  _account_meta_set work org "株式会社株式会社株式会社株式会社株式会社株式会社"
  _accounts_load_rows default
  _accounts_frame 1 0 2 50 "$_ACCT_N" > "$TEST_TEMP/frame.out" 2>/dev/null
  # Column cost, not byte cost, and measured without depending on the locale:
  # a CJK glyph is three UTF-8 bytes and paints two columns, ASCII is one of
  # each. awk under LC_ALL=C counts BYTES, which is why the obvious version of
  # this assertion is wrong.
  local line plain ascii wide cols widest=0
  while IFS= read -r line; do
    # The frame's OWN glyphs are all single-column, so fold them to ASCII
    # before the wide-character arithmetic or they each count as two.
    plain="$(printf '%s' "$line" | sed $'s/\033\\[[0-9;]*[A-Za-z]//g' \
      | sed 's/▸/>/g; s/•/o/g; s/…/./g; s/·/./g; s/↑/^/g; s/↓/v/g; s/⏎/E/g')"
    ascii="$(printf '%s' "$plain" | LC_ALL=C tr -cd ' -~' | wc -c | tr -d ' ')"
    wide="$(printf '%s' "$plain" | LC_ALL=C tr -d ' -~' | wc -c | tr -d ' ')"
    cols=$(( ascii + (wide / 3) * 2 ))
    [ "$cols" -gt "$widest" ] && widest=$cols
  done < "$TEST_TEMP/frame.out"
  [ "$widest" -le 50 ] || { echo "drew $widest columns"; return 1; }
}

@test "account: the action screen clamps a long email to the terminal width" {
  # The back-out walks up a FIXED three lines, so a wrapped header line makes
  # the redrawn list land on top of the menu it was meant to replace.
  _mk_account work
  _account_meta_set work who "an-extremely-long-email-address-that-would-certainly-wrap@a-very-long-domain.example.com"
  _term_cols() { echo 40; }
  _acct_keys QUIT
  run _accounts_action_tui work main "$CN" "$TEST_TEMP/proj"
  assert_failure
  local widest
  widest="$(printf '%s\n' "$output" | sed $'s/\033\\[[0-9;]*[A-Za-z]//g' \
    | sed 's/…/./g; s/↑/^/g; s/↓/v/g; s/⏎/E/g; s/▸/>/g' \
    | awk '{ n = length($0); if (n > m) m = n } END { print m + 0 }')"
  [ "$widest" -le 40 ] || { echo "drew $widest columns"; return 1; }
}

@test "account: a pinned box is not re-stamped with the host account's identity" {
  # The per-project builder is HOST-first for identity, which is right for a
  # box on the shared login and wrong for a pinned one: it re-stamped the host
  # account's email and organisation onto a box running as somebody else, on
  # every start.
  command -v jq >/dev/null || skip "needs jq"
  _mk_account work
  _box_account_write "$CN" work
  container_name_for() { echo "$CN"; }
  mkdir -p "$HOME/.claude"
  printf '{"oauthAccount":{"emailAddress":"host@example.com"},"userID":"abc"}\n' > "$HOME/.claude.json"
  mkdir -p "$TEST_TEMP/store"
  _build_project_claude_json "$TEST_TEMP/store/claude.json" "" "$CN"
  run jq -r '.oauthAccount // "absent"' "$TEST_TEMP/store/claude.json"
  assert_output "absent"
  # userID is machine-scoped rather than account-scoped, so it still comes from
  # the host.
  run jq -r '.userID' "$TEST_TEMP/store/claude.json"
  assert_output "abc"
}

@test "account: an unpinned box still gets the host identity, exactly as before" {
  command -v jq >/dev/null || skip "needs jq"
  mkdir -p "$HOME/.claude"
  printf '{"oauthAccount":{"emailAddress":"host@example.com"},"userID":"abc"}\n' > "$HOME/.claude.json"
  mkdir -p "$TEST_TEMP/store"
  _build_project_claude_json "$TEST_TEMP/store/claude.json" "" "$CN"
  run jq -r '.oauthAccount.emailAddress' "$TEST_TEMP/store/claude.json"
  assert_output "host@example.com"
}

@test "account: a pinned box does not even read a sibling box's identity file" {
  # The gate sits behind the del, so its effect on the OUTPUT is masked. What
  # it does observably is stop a pinned box reading other projects' files at
  # all, which is the part worth pinning: nothing in those files says which
  # account they belong to.
  command -v jq >/dev/null || skip "needs jq"
  _mk_account work
  _box_account_write "$CN" work
  container_name_for() { echo "$CN"; }
  _newest_sibling_identity() { : > "$TEST_TEMP/sibling-read"; }
  printf '{}\n' > "$HOME/.claude.json"
  mkdir -p "$TEST_TEMP/store"
  _build_project_claude_json "$TEST_TEMP/store/claude.json" "" "$CN"
  [ ! -f "$TEST_TEMP/sibling-read" ]
  # And an UNPINNED box still does, so the gate is the only difference.
  _box_account_remove "$CN"
  _build_project_claude_json "$TEST_TEMP/store/claude.json" "" "$CN"
  [ -f "$TEST_TEMP/sibling-read" ]
}

@test "account: a pinned box does not inherit a sibling box's login either" {
  # The sibling scan picks the newest per-project file holding a login, and
  # nothing in that file says which ACCOUNT it belongs to.
  command -v jq >/dev/null || skip "needs jq"
  _mk_account work
  _box_account_write "$CN" work
  container_name_for() { echo "$CN"; }
  mkdir -p "$CLEAT_PROJECTS_DIR/other"
  printf '{"oauthAccount":{"emailAddress":"sibling@example.com"}}\n' > "$CLEAT_PROJECTS_DIR/other/claude.json"
  printf '{}\n' > "$HOME/.claude.json"
  mkdir -p "$TEST_TEMP/store"
  _build_project_claude_json "$TEST_TEMP/store/claude.json" "" "$CN"
  run jq -r '.oauthAccount // "absent"' "$TEST_TEMP/store/claude.json"
  assert_output "absent"
}

# ── what the completeness critic found ─────────────────────────────────────

@test "account: a merely STOPPED box is not mistaken for one with a live session" {
  # _box_has_live_agent maps ANY docker top failure to "live", and docker top
  # fails on a stopped container while container_exists (docker ps -a) is true
  # for one. Without is_running every stopped box read as live, which is the
  # normal steady state: the idle sweep stops boxes by itself.
  _pass_gates
  _mk_account work
  _daemon_up() { return 0; }
  container_exists() { return 0; }
  is_running() { return 1; }
  _box_has_live_agent() { return 0; }
  docker() { case "$1" in inspect) printf '%s\n' "/home/coder/.cleat-auth" ;; *) return 1 ;; esac; }
  run _account_do_switch work main "$CN" "$TEST_TEMP/proj"
  assert_success
  refute_output --partial "live Claude session"
}

@test "account: unpinning a stopped box is not refused either" {
  # cleat account default is the escape hatch the picker's first row exists
  # for, so wedging it on a stopped box closes the only way back.
  _mk_account work
  _box_account_write "$CN" work
  _daemon_up() { return 0; }
  container_exists() { return 0; }
  is_running() { return 1; }
  _box_has_live_agent() { return 0; }
  run _account_do_switch default main "$CN" "$TEST_TEMP/proj"
  assert_success
  run _box_account_read "$CN"
  assert_output "default"
}

@test "account: removing is not wedged by one stale stopped box on the machine" {
  # _account_pinned_boxes scans EVERY pin file, not this project's, so one
  # stopped box anywhere made the account unremovable from every directory.
  _pass_gates
  _mk_account work
  _box_account_write "box-elsewhere" work
  _daemon_up() { return 0; }
  container_exists() { return 0; }
  is_running() { return 1; }
  _box_has_live_agent() { return 0; }
  run _account_do_remove work 1
  assert_success
  [ ! -d "$CLEAT_ACCOUNTS_DIR/work" ]
}

@test "account: identity is captured on a host with no jq" {
  # Who an account is comes from the server's answer, read with the flat reader
  # on every host. macOS base has no jq, and a reader that needed it named no
  # account there. The answer is pretty-printed here, whitespace and all.
  _mk_account work 1000 old-token
  _box_account_write "$CN" work
  _mk_staged "$CN" 1789003600000
  _account_profile_curl() {
    printf '{\n  "account": {\n    "uuid": "%s",\n    "email": "alice@example.com"\n  },\n  "organization": {\n    "uuid": "org-0001",\n    "name": "Acme Ltd",\n    "cc_onboarding_flags": {}\n  }\n}\n200' "$UUID_WORK"
  }
  _hide_jq
  run _account_sync_out "$CN"
  unset -f command
  assert_success
  run _account_meta_get work who
  assert_output "alice@example.com"
  run _account_meta_get work org
  assert_output "Acme Ltd"
  run _account_meta_get work uuid
  assert_output "$UUID_WORK"
}

@test "account: a refused switch leaves no pin file behind at all" {
  # _box_account_read SANITISES, so asserting it reports `default` passes even
  # when a junk pin file is sitting on disk for _account_pinned_boxes and
  # cleat account rm to iterate.
  _pass_gates
  run _account_do_switch "Bad Name" main "$CN" "$TEST_TEMP/proj"
  assert_failure
  [ ! -f "$CLEAT_BOX_ACCOUNTS_DIR/$CN" ]
}

@test "account: every attach re-stages the stored credential" {
  # Another box may have refreshed it since this one last ran, so the staging
  # is not only a switch-time step. Asserting the env var alone passes with
  # the staging deleted.
  _mk_account work 1789003600000 fresher
  _box_account_write "cleat-stagetest" work
  _host_clip_cmd() { echo ""; }
  docker() {
    case "$1" in
      inspect) printf '%s\n' "/home/coder/.cleat-auth" ;;
      *) command docker "$@" ;;
    esac
  }
  _daemon_up() { return 0; }
  container_exists() { return 0; }
  run exec_claude "cleat-stagetest" --dangerously-skip-permissions
  run grep -c "fresher" "$CLEAT_RUN_DIR/cleat-stagetest/auth/.credentials.json"
  assert_output "1"
}

@test "account: the plain listing renders a row rather than only the empty note" {
  # cleat account list is the non-TTY path for every pipe and every CI run,
  # and the smoke test runs it with NO accounts, so the row-rendering half
  # never executed anywhere in the suite.
  _mk_account work
  _account_meta_set work who "you@example.com"
  run _accounts_picker_text main "$CN"
  assert_success
  assert_output --partial "work"
  assert_output --partial "you@example.com"
  assert_output --partial "default"
}

@test "account: rename and restore work through their command-level wrappers" {
  _mk_account work
  run _account_do_rename work other
  assert_success
  [ -d "$CLEAT_ACCOUNTS_DIR/other" ]
  _account_trash other
  run _account_do_restore other
  assert_success
  [ -d "$CLEAT_ACCOUNTS_DIR/other" ]
  run _account_do_restore never-existed
  assert_failure
}

@test "account: the mount probe succeeds against a healthy modern box" {
  # Every switch test either takes the daemon down or stubs the probe to fail,
  # so the success path had never executed.
  _daemon_up() { return 0; }
  container_exists() { return 0; }
  docker() { case "$1" in inspect) printf '%s\n%s\n' "/workspace" "/home/coder/.cleat-auth" ;; *) return 1 ;; esac; }
  run _account_box_ready "cleat-healthy"
  assert_success
}

@test "account: capture never reads a project file" {
  # Found on a real Mac. The per-project claude.json holds whatever identity
  # Claude last wrote there, and a box that was pinned but never RAN as the
  # account (no auth mount, or pinned and never started) still holds the
  # SHARED login's. Reading it named a brand-new account with the maintainer's
  # own email. The box writes that file, so it is never read for identity.
  _pass_gates
  _mk_account work
  _box_account_write "$CN" work
  local key
  key="$(_derive_project_session_key "$TEST_TEMP/proj" main)"
  mkdir -p "$CLEAT_PROJECTS_DIR/$key"
  printf '{"oauthAccount":{"emailAddress":"primary@example.com","organizationName":"Primary Org"}}\n' \
    > "$CLEAT_PROJECTS_DIR/$key/claude.json"
  # Staged or not, the file names nobody.
  run _account_do_switch work main "$CN" "$TEST_TEMP/proj"
  assert_success
  _mk_staged "$CN" 1789003600000
  run _account_do_switch work main "$CN" "$TEST_TEMP/proj"
  assert_success
  run _account_meta_get work who
  assert_failure
  run _account_meta_get work org
  assert_failure
  # The plan and last_used still land.
  run _account_meta_get work plan
  assert_output "max"
  run _account_meta_get work last_used
  assert_success
}

@test "account: an account the box did run as still gets its identity captured" {
  # The other half: the list names a human only through a verified harvest, so
  # the switch's harvest has to record it. The project file says one thing and
  # the server another, and the server wins.
  _pass_gates
  _mk_account work 1000 old-token
  _box_account_write "$CN" work
  _mk_staged "$CN" 1789003600000
  local key
  key="$(_derive_project_session_key "$TEST_TEMP/proj" main)"
  mkdir -p "$CLEAT_PROJECTS_DIR/$key"
  printf '{"oauthAccount":{"emailAddress":"stale@example.com","organizationName":"Stale Org"}}\n' \
    > "$CLEAT_PROJECTS_DIR/$key/claude.json"
  _profile_says "$UUID_WORK" real@example.com "Real Org"
  run _account_do_switch work main "$CN" "$TEST_TEMP/proj"
  assert_success
  assert_output --partial "real@example.com"
  run _account_meta_get work who
  assert_output "real@example.com"
  run _account_meta_get work org
  assert_output "Real Org"
}

@test "account: the launch summary does not call a pinned box's auth shared" {
  # The line sits directly above the summary block that names the account, so
  # "Auth shared" on a pinned box contradicted the line under it.
  _mk_account work
  _box_account_write "$CN" work
  run _print_auth_line "$CN"
  assert_success
  assert_output --partial "work"
  refute_output --partial "shared"
}

@test "account: a pinned box without the account mount says its auth is shared" {
  # The pin stays on a box that predates the account mount, but the exec runs
  # it on the shared login. The launch line read the pin and printed a green
  # "Auth from account work" above a session on the shared login.
  _mk_account work
  _box_account_write "$CN" work
  _daemon_up() { return 0; }
  container_exists() { return 0; }
  mock_docker_inspect $'/workspace\n/home/coder/.claude'
  run _print_auth_line "$CN"
  assert_success
  assert_output --partial "Auth shared"
  refute_output --partial "Auth from account"
  # With the mount the pin is in effect.
  mock_docker_inspect $'/workspace\n/home/coder/.claude\n/home/coder/.cleat-auth'
  run _print_auth_line "$CN"
  assert_output --partial "Auth from account"
}

@test "account: an unpinned box still says its auth is shared" {
  run _print_auth_line "$CN"
  assert_success
  assert_output --partial "Auth shared"
}

@test "account: a box CREATED while pinned is not stamped with the host identity either" {
  # The two refresh paths passed the container name; the create path did not.
  # So `cleat rm` then `cleat account <name>` then a start gave the right
  # credential with the WRONG name on it, which is what /usage shows inside
  # the box. Found on a real Mac, 2026-09-12.
  command -v jq >/dev/null || skip "needs jq"
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project"
  local cname
  cname="$(container_name_for "$TEST_TEMP/project")"
  _mk_account work
  _box_account_write "$cname" work
  printf '{"oauthAccount":{"emailAddress":"host@example.com"},"userID":"abc"}\n' > "$HOME/.claude.json"
  run cmd_run "$TEST_TEMP/project"
  assert_success
  local key f
  key="$(_derive_project_session_key "$TEST_TEMP/project" main)"
  f="$CLEAT_PROJECTS_DIR/${key}/claude.json"
  [ -f "$f" ]
  run jq -r '.oauthAccount // "absent"' "$f"
  assert_output "absent"
}

@test "account: an unpinned box created the same way still gets the host identity" {
  command -v jq >/dev/null || skip "needs jq"
  mock_docker_images "cleat"
  mkdir -p "$TEST_TEMP/project"
  printf '{"oauthAccount":{"emailAddress":"host@example.com"},"userID":"abc"}\n' > "$HOME/.claude.json"
  run cmd_run "$TEST_TEMP/project"
  assert_success
  local key f
  key="$(_derive_project_session_key "$TEST_TEMP/project" main)"
  f="$CLEAT_PROJECTS_DIR/${key}/claude.json"
  run jq -r '.oauthAccount.emailAddress' "$f"
  assert_output "host@example.com"
}

@test "account: switching drops the identity the box is carrying" {
  # Claude shows the account email from oauthAccount in the per-project
  # claude.json and from nowhere else: the credential blob carries no identity
  # and the access token is opaque. A COMPLETE oauthAccount also freezes it,
  # because profileFetchedAt lives inside that object and the refetch only runs
  # when the key is absent. The start rebuild never reaches a RUNNING box.
  command -v jq >/dev/null || skip "needs jq"
  _pass_gates
  _mk_account work
  local key f
  key="$(_derive_project_session_key "$TEST_TEMP/proj" main)"
  mkdir -p "$CLEAT_PROJECTS_DIR/$key"
  f="$CLEAT_PROJECTS_DIR/$key/claude.json"
  printf '{"oauthAccount":{"emailAddress":"previous@example.com","profileFetchedAt":9999999999999},"userID":"abc","projects":{"/workspace":{}}}\n' > "$f"
  run _account_do_switch work main "$CN" "$TEST_TEMP/proj"
  assert_success
  run jq -r '.oauthAccount // "absent"' "$f"
  assert_output "absent"
  # Everything else in the file survives: this is a targeted delete, not a
  # rebuild, and the file is a live bind source.
  run jq -r '.userID' "$f"
  assert_output "abc"
  run jq -r '.projects["/workspace"] | type' "$f"
  assert_output "object"
}

@test "account: unpinning drops it too" {
  command -v jq >/dev/null || skip "needs jq"
  _mk_account work
  _box_account_write "$CN" work
  local key f
  key="$(_derive_project_session_key "$TEST_TEMP/proj" main)"
  mkdir -p "$CLEAT_PROJECTS_DIR/$key"
  f="$CLEAT_PROJECTS_DIR/$key/claude.json"
  printf '{"oauthAccount":{"emailAddress":"named@example.com"},"userID":"abc"}\n' > "$f"
  run _account_do_switch default main "$CN" "$TEST_TEMP/proj"
  assert_success
  run jq -r '.oauthAccount // "absent"' "$f"
  assert_output "absent"
}

@test "account: a renamed account still drops its boxes' identity when it is removed" {
  # The remove finds each box's claude.json through the key recorded with the
  # pin, so a rename that rewrote the pin without it stranded the name again.
  command -v jq >/dev/null || skip "needs jq"
  _pass_gates
  _mk_account work
  local f
  run _account_do_switch work main "$CN" "$TEST_TEMP/proj"
  assert_success
  f="$CLEAT_PROJECTS_DIR/$(_derive_project_session_key "$TEST_TEMP/proj" main)/claude.json"
  mkdir -p "${f%/*}"
  printf '{"oauthAccount":{"emailAddress":"work@example.com"},"userID":"abc"}\n' > "$f"
  run _account_do_rename work work2
  assert_success
  run _account_do_remove work2 1
  assert_success
  run jq -r '.oauthAccount // "absent"' "$f"
  assert_output "absent"
}

@test "account: a hand-edited pin key never reaches outside the projects store" {
  # The pin file is hand-editable and its second line is joined into a path.
  command -v jq >/dev/null || skip "needs jq"
  _pass_gates
  _mk_account work
  mkdir -p "$CLEAT_PROJECTS_DIR" "${CLEAT_PROJECTS_DIR%/*}/outside"
  printf '{"oauthAccount":{"emailAddress":"keep@example.com"}}\n' > "${CLEAT_PROJECTS_DIR%/*}/outside/claude.json"
  printf 'work\n../outside\n' > "$CLEAT_BOX_ACCOUNTS_DIR/$CN"
  run _account_do_remove work 1
  assert_success
  run _box_account_read "$CN"
  assert_output "default"
  run jq -r '.oauthAccount.emailAddress' "${CLEAT_PROJECTS_DIR%/*}/outside/claude.json"
  assert_output "keep@example.com"
}

@test "account: the identity delete keeps the file's inode for a live bind mount" {
  # An atomic temp-and-mv swaps the inode out from under a running container,
  # which is why _refresh_project_claude_json refuses to touch a running box at
  # all. This one has to be safe on one.
  command -v jq >/dev/null || skip "needs jq"
  local key f before after
  key="$(_derive_project_session_key "$TEST_TEMP/proj" main)"
  mkdir -p "$CLEAT_PROJECTS_DIR/$key"
  f="$CLEAT_PROJECTS_DIR/$key/claude.json"
  printf '{"oauthAccount":{"emailAddress":"x@example.com"}}\n' > "$f"
  before="$(ls -i "$f" | awk '{print $1}')"
  run _account_invalidate_identity "$TEST_TEMP/proj" main
  assert_success
  after="$(ls -i "$f" | awk '{print $1}')"
  [ "$before" = "$after" ]
}

@test "account: the identity delete refuses a symlinked store" {
  command -v jq >/dev/null || skip "needs jq"
  local key f
  key="$(_derive_project_session_key "$TEST_TEMP/proj" main)"
  mkdir -p "$CLEAT_PROJECTS_DIR/$key"
  f="$CLEAT_PROJECTS_DIR/$key/claude.json"
  printf '{"oauthAccount":{"emailAddress":"x@example.com"}}\n' > "$TEST_TEMP/outside.json"
  ln -s "$TEST_TEMP/outside.json" "$f"
  run _account_invalidate_identity "$TEST_TEMP/proj" main
  assert_success
  run jq -r '.oauthAccount.emailAddress' "$TEST_TEMP/outside.json"
  assert_output "x@example.com"
}

@test "account: a pinned box does not inherit the shared usage cache either" {
  # Claude guards cachedUsageUtilization against cross-account reuse by
  # comparing its accountUuid against oauthAccount, and a pinned box has
  # deliberately removed oauthAccount. So the entry is written with no uuid and
  # read back as a match, and a failed live fetch inside the hour would show
  # the OTHER account's numbers as "last-known usage".
  command -v jq >/dev/null || skip "needs jq"
  _mk_account work
  _box_account_write "$CN" work
  container_name_for() { echo "$CN"; }
  printf '{"oauthAccount":{"emailAddress":"host@example.com"},"cachedUsageUtilization":{"utilization":42}}\n' > "$HOME/.claude.json"
  mkdir -p "$TEST_TEMP/store"
  _build_project_claude_json "$TEST_TEMP/store/claude.json" "" "$CN"
  run jq -r '.cachedUsageUtilization // "absent"' "$TEST_TEMP/store/claude.json"
  assert_output "absent"
}

@test "account: an unpinned box keeps the usage cache, which is its own account's" {
  command -v jq >/dev/null || skip "needs jq"
  printf '{"oauthAccount":{"emailAddress":"host@example.com"},"cachedUsageUtilization":{"utilization":42}}\n' > "$HOME/.claude.json"
  mkdir -p "$TEST_TEMP/store"
  _build_project_claude_json "$TEST_TEMP/store/claude.json" "" "$CN"
  run jq -r '.cachedUsageUtilization.utilization' "$TEST_TEMP/store/claude.json"
  assert_output "42"
}

@test "account: a pin the box cannot honour reports as the shared login, not as the account" {
  # The box keeps its pin (it has to outlive the cleat rm that fixes it) and
  # the attach falls back to the shared login, so anything that REPORTS the
  # account has to ask the same question the attach does.
  _mk_account work
  _box_account_write "$CN" work
  _daemon_up() { return 0; }
  container_exists() { return 0; }
  docker() { case "$1" in inspect) printf '%s\n' "/workspace" ;; *) return 1 ;; esac; }
  run _account_effective "$CN"
  assert_failure
  assert_output "default"
}

@test "account: a pin the box CAN honour reports as the account" {
  _mk_account work
  _box_account_write "$CN" work
  _daemon_up() { return 0; }
  container_exists() { return 0; }
  docker() { case "$1" in inspect) printf '%s\n' "/home/coder/.cleat-auth" ;; *) return 1 ;; esac; }
  run _account_effective "$CN"
  assert_success
  assert_output "work"
}

@test "account: cannot-tell is not demotion, since the next run creates the mount" {
  # A box that does not exist yet gets the mount from the next docker run, so
  # a probe that cannot answer must not report the pin as broken.
  _mk_account work
  _box_account_write "$CN" work
  _daemon_up() { return 1; }
  container_exists() { return 1; }
  run _account_effective "$CN"
  assert_success
  assert_output "work"
}

@test "account: an unpinned box answers with the sentinel and no docker call" {
  : > "$TEST_TEMP/docker.log"
  docker() { echo "$1" >> "$TEST_TEMP/docker.log"; return 1; }
  run _account_effective "$CN"
  assert_success
  assert_output "default"
  [ ! -s "$TEST_TEMP/docker.log" ]
}

@test "account: the Claude image upgrade keeps the image's own cleat labels" {
  # docker commit writes a fresh config, so without re-stamping, the upgraded
  # image loses sh.cleat.image-spec and sh.cleat.version. That fails OPEN in
  # the rebuild prompt, so it never nags: the cost is that a genuine spec bump
  # can then never reach that user again. Measured on a real Mac.
  : > "$TEST_TEMP/commit.log"
  image_exists() { return 0; }
  _image_claude_version() { echo "2.1.1"; }
  _image_spec_version() { echo "4"; }
  _image_cleat_version() { echo "1.4.3"; }
  docker() {
    case "$1" in
      commit) printf '%s\n' "$*" >> "$TEST_TEMP/commit.log"; return 0 ;;
      *) return 0 ;;
    esac
  }
  run _upgrade_claude_image latest
  run cat "$TEST_TEMP/commit.log"
  assert_output --partial "sh.cleat.image-spec=4"
  assert_output --partial "sh.cleat.version=1.4.3"
}

@test "account: an unlabelled image does not gain a fabricated label" {
  : > "$TEST_TEMP/commit.log"
  image_exists() { return 0; }
  _image_claude_version() { echo "2.1.1"; }
  _image_spec_version() { echo ""; }
  _image_cleat_version() { echo ""; }
  docker() {
    case "$1" in
      commit) printf '%s\n' "$*" >> "$TEST_TEMP/commit.log"; return 0 ;;
      *) return 0 ;;
    esac
  }
  run _upgrade_claude_image latest
  run cat "$TEST_TEMP/commit.log"
  refute_output --partial "sh.cleat"
}

@test "account: usage is never polled on an expired login because an MCP token beside it is alive" {
  # The expiry that gates a poll is the Claude login's own. An MCP server's
  # token written after it in the same file says nothing about the login.
  mkdir -p "$CLEAT_ACCOUNTS_DIR/work"
  printf '{"claudeAiOauth":{"accessToken":"a-token","refreshToken":"r-token","expiresAt":%s},"mcpOAuth":{"s|1":{"accessToken":"m","refreshToken":"m","expiresAt":%s}}}' \
    $(( (_CLEAT_NOW_S - 3600) * 1000 )) $(( (_CLEAT_NOW_S + 86400) * 1000 )) > "$CLEAT_ACCOUNTS_DIR/work/.credentials.json"
  curl() { cat >/dev/null 2>&1; echo "CURL RAN" >> "$TEST_TEMP/curl.log"; }
  run _account_usage_fetch work
  assert_failure
  [ ! -f "$TEST_TEMP/curl.log" ]
}

@test "account: a credential file past the size cap never reads as a live login" {
  # The staged copy lives in a directory the box can write. Its expiry is read
  # before any size check. Past the cap the login is not there to read.
  local pad f="$CLEAT_RUN_DIR/$CN/auth/.credentials.json"
  mkdir -p "$CLEAT_RUN_DIR/$CN/auth"
  pad="$(printf '%*s' 70000 '' | tr ' ' x)"
  printf '{"pad":"%s","claudeAiOauth":{"accessToken":"a","refreshToken":"r","expiresAt":1789003600000}}' "$pad" > "$f"
  run _account_cred_expiry "$f"
  assert_output "0"
  # The same login inside the cap reads, so the 0 above is the cap and not the shape.
  printf '{"pad":"x","claudeAiOauth":{"accessToken":"a","refreshToken":"r","expiresAt":1789003600000}}' > "$f"
  run _account_cred_expiry "$f"
  assert_output "1789003600000"
}

# ── credential readers scoped to the Claude login ──────────────────────────
#
# The file Claude writes also holds mcpOAuth, one entry per MCP server with its
# own tokens. Claude writes it before claudeAiOauth when the MCP login came
# first (mc) and after it otherwise (cm). $1 = order, $2 = the Claude login's
# accessToken, $3 = its refreshToken.
_mcp_order_blob() {
  local claude mcp
  claude="\"claudeAiOauth\":{\"accessToken\":\"$2\",\"refreshToken\":\"$3\",\"expiresAt\":1789007200000,\"scopes\":[\"user:inference\",\"user:profile\"],\"subscriptionType\":\"max\",\"rateLimitTier\":\"default_claude_max_20x\"}"
  mcp="\"mcpOAuth\":{\"linear|0123456789abcdef\":{\"serverName\":\"linear\",\"serverUrl\":\"https://mcp.linear.app/mcp\",\"accessToken\":\"MCP-SERVER-TOKEN\",\"refreshToken\":\"MCP-SERVER-REFRESH\",\"expiresAt\":1789086400000,\"scope\":\"read write\"}}"
  if [ "$1" = cm ]; then
    printf '{%s,%s}\n' "$claude" "$mcp"
  else
    printf '{%s,%s}\n' "$mcp" "$claude"
  fi
}

@test "account: a reader scoped to claudeAiOauth never returns a coresident MCP token" {
  local f="$TEST_TEMP/cred.json" leg order
  for leg in jq nojq; do
    [ "$leg" = nojq ] && _hide_jq
    for order in cm mc; do
      _mcp_order_blob "$order" sk-ant-oat01-OWN sk-ant-ort01-OWN > "$f"
      run _account_cred_str "$f" accessToken
      assert_output "sk-ant-oat01-OWN"
      run _account_cred_str "$f" refreshToken
      assert_output "sk-ant-ort01-OWN"
      # The plan the list shows is the login's own too.
      _mk_account work
      cp "$f" "$CLEAT_ACCOUNTS_DIR/work/.credentials.json"
      _account_capture_meta work
      run _account_meta_get work plan
      assert_equal "$leg $order $output" "$leg $order max"
    done
  done
  # Two access tokens inside the login are two answers. Neither is read.
  printf '{"claudeAiOauth":{"accessToken":"sk-ant-oat01-FIRST","refreshToken":"r","accessToken":"sk-ant-oat01-SECOND","expiresAt":1789007200000}}\n' > "$f"
  run _account_cred_str "$f" accessToken
  assert_failure
  assert_output ""
  # A refresh token held as a number is not a string, so it reads as absent.
  printf '{"claudeAiOauth":{"accessToken":"a","refreshToken":12345,"expiresAt":1789007200000}}\n' > "$f"
  run _account_cred_str "$f" refreshToken
  assert_failure
  assert_output ""
}

@test "account: a blanked login beside a live MCP entry reads as signed out on either host" {
  # invalid_grant writes EMPTY tokens back into claudeAiOauth and leaves every
  # MCP entry alone. The live MCP tokens must not make the login look alive.
  local leg order
  for leg in jq nojq; do
    [ "$leg" = nojq ] && _hide_jq
    for order in cm mc; do
      _mk_account work
      _mcp_order_blob "$order" "" "" > "$CLEAT_ACCOUNTS_DIR/work/.credentials.json"
      run _account_auth_state work
      assert_equal "$leg $order $output" "$leg $order signed out"
      run _account_cred_plausible "$CLEAT_ACCOUNTS_DIR/work/.credentials.json"
      assert_failure
      # The same file with the login intact reads as alive, so the two above
      # are the scope and not the fixture.
      _mcp_order_blob "$order" sk-ant-oat01-OWN sk-ant-ort01-OWN > "$CLEAT_ACCOUNTS_DIR/work/.credentials.json"
      run _account_auth_state work
      assert_equal "$leg $order $output" "$leg $order ok"
      run _account_cred_plausible "$CLEAT_ACCOUNTS_DIR/work/.credentials.json"
      assert_success
    done
  done
}

@test "account: an access token outside the base64url alphabet is refused and never reaches curl" {
  # The store is harvested out of a directory the box mounts read-write. The
  # token goes into a curl config that takes one directive per line.
  curl() { cat >/dev/null 2>&1; echo "CURL RAN" >> "$TEST_TEMP/curl.log"; }
  local f="$CLEAT_ACCOUNTS_DIR/work/.credentials.json" tok
  _mk_account work
  # A JSON newline escape, a raw newline, an escaped quote and a backslash.
  for tok in 'x\noutput = /tmp/pwned' "$(printf 'x\noutput = /tmp/pwned')" 'x\" output = \"/tmp/pwned' 'x\\y'; do
    printf '{"claudeAiOauth":{"accessToken":"%s","refreshToken":"r","expiresAt":1789007200000}}\n' "$tok" > "$f"
    run _account_access_token work
    assert_failure
    assert_output ""
    run _account_usage_fetch work
    assert_failure
  done
  run test -e "$TEST_TEMP/curl.log"
  assert_failure
  # Every character a real OAuth token uses still passes.
  printf '{"claudeAiOauth":{"accessToken":"sk-ant-oat01-Az09_.~+/=","refreshToken":"r","expiresAt":1789007200000}}\n' > "$f"
  run _account_access_token work
  assert_success
  assert_output "sk-ant-oat01-Az09_.~+/="
}

# ── the account lock ───────────────────────────────────────────────────────

_lock_dir() { printf '%s' "$CLEAT_ACCOUNTS_DIR/.lock"; }
_lock_plant() {   # $1 = owner record, empty for none
  mkdir -p "$(_lock_dir)"
  [[ -z "${1:-}" ]] || printf '%s\n' "$1" > "$(_lock_dir)/owner"
}
_lock_live_record() { printf 'host %s pid %s at %s' "${HOSTNAME:-unknown}" "$$" "$(date +%s)"; }
_lock_pinned_pair() {
  _pass_gates
  _mk_account a 1789003600000 token-a
  _mk_account b 1789002000000 token-b
  _box_account_write "$CN" a
  _mk_staged "$CN" 1789003600000
}
_lock_absent() {   # $1 = what just ran
  run test -e "$(_lock_dir)"
  assert_equal "$1 left the lock: $status" "$1 left the lock: 1"
}

@test "account: every locked action releases the account lock" {
  # A lock left behind by a successful action wedges every later attach,
  # session end and switch until it ages out.
  _lock_pinned_pair
  _ACCOUNT_LOCK_WAIT_S=0
  run _account_sync_in "$CN"
  _lock_absent sync_in
  run _account_sync_out "$CN"
  _lock_absent sync_out
  run _account_do_switch b main "$CN" "$TEST_TEMP/proj"
  assert_success
  _lock_absent switch
  run _account_do_switch default main "$CN" "$TEST_TEMP/proj"
  assert_success
  _lock_absent unpin
  run _account_rename b c
  assert_success
  _lock_absent rename
  run _account_do_remove c 1
  assert_success
  _lock_absent remove
  run _account_restore c
  assert_success
  _lock_absent restore
  _box_account_write "$CN" a
  run _account_release_all
  _lock_absent release_all
  run _account_wipe_run_dir "$CN"
  _lock_absent wipe
  run _box_account_read "$CN"
  assert_output "a"
}

@test "account: a lock whose owner has exited is taken over" {
  # A Ctrl-C inside a locked section leaves the directory behind.
  _lock_pinned_pair
  _ACCOUNT_LOCK_WAIT_S=0
  _lock_plant "host ${HOSTNAME:-unknown} pid 2147483646 at $(date +%s)"
  run _account_do_switch b main "$CN" "$TEST_TEMP/proj"
  assert_success
  run _box_account_read "$CN"
  assert_output "b"
}

@test "account: a lock with no owner record yet is honoured, and taken over once past the grace period" {
  # mkdir comes before the record write, so a record-less lock is usually a
  # winner a moment from writing it. One that stays record-less was killed in
  # that moment and must not wedge the feature.
  _lock_pinned_pair
  _ACCOUNT_LOCK_WAIT_S=0
  _lock_plant ""
  run _account_do_switch b main "$CN" "$TEST_TEMP/proj"
  assert_failure
  run _box_account_read "$CN"
  assert_output "a"
  _path_mtime() { printf '%s' "$(( $(date +%s) - _ACCOUNT_LOCK_GRACE_S - 5 ))"; }
  run _account_do_switch b main "$CN" "$TEST_TEMP/proj"
  assert_success
  run _box_account_read "$CN"
  assert_output "b"
}

@test "account: a lock past the age bound is taken over even while its pid is alive" {
  # A pid recycled after a reboot answers kill -0 for a process that never
  # held the lock.
  _lock_pinned_pair
  _ACCOUNT_LOCK_WAIT_S=0
  _lock_plant "host ${HOSTNAME:-unknown} pid $$ at $(( $(date +%s) - _ACCOUNT_LOCK_STALE_S - 5 ))"
  run _account_do_switch b main "$CN" "$TEST_TEMP/proj"
  assert_success
  run _box_account_read "$CN"
  assert_output "b"
}

@test "account: a lock held by a live process is waited on, never taken" {
  _lock_pinned_pair
  _ACCOUNT_LOCK_WAIT_S=0
  local rec
  rec="$(_lock_live_record)"
  _lock_plant "$rec"
  run _account_do_switch b main "$CN" "$TEST_TEMP/proj"
  assert_failure
  assert_output --partial "Another cleat command is changing accounts right now."
  run cat "$(_lock_dir)/owner"
  assert_output "$rec"
  # Another machine's pid cannot be probed from here, so a fresh record from
  # one is honoured whatever its pid is, until the age bound.
  rec="host not-${HOSTNAME:-unknown}.example pid 2147483646 at $(date +%s)"
  _lock_plant "$rec"
  run _account_do_switch b main "$CN" "$TEST_TEMP/proj"
  assert_failure
  run cat "$(_lock_dir)/owner"
  assert_output "$rec"
  run _box_account_read "$CN"
  assert_output "a"
}

@test "account: a steal gives back a lock that changed hands after it was judged stale" {
  # Two takers can judge the same dead lock stale. The second one's rename then
  # captures the FIRST one's fresh lock, which must go straight back.
  _lock_pinned_pair
  _ACCOUNT_LOCK_WAIT_S=0
  _lock_plant "host ${HOSTNAME:-unknown} pid 2147483646 at $(date +%s)"
  local live
  live="$(_lock_live_record)"
  mv() {
    if [[ "${1:-}" == "$(_lock_dir)" && ! -e "$TEST_TEMP/swapped" ]]; then
      : > "$TEST_TEMP/swapped"
      printf '%s\n' "$live" > "$(_lock_dir)/owner"
    fi
    command mv "$@"
  }
  run _account_do_switch b main "$CN" "$TEST_TEMP/proj"
  assert_failure
  run test -e "$TEST_TEMP/swapped"
  assert_success
  run _box_account_read "$CN"
  assert_output "a"
  run cat "$(_lock_dir)/owner"
  assert_output "$live"
}

@test "account: releasing never removes a lock another process now holds" {
  _account_lock
  printf 'host %s pid 2147483646 at %s\n' "${HOSTNAME:-unknown}" "$(date +%s)" > "$(_lock_dir)/owner"
  _account_unlock
  run test -d "$(_lock_dir)"
  assert_success
}

@test "account: lock ownership reads true only while this shell still holds it" {
  # The live switch writes the store only while it owns the lock. Before it takes
  # the lock, ownership is false. After it takes the lock, true. If an age-bound
  # steal by another command replaces the owner record, ownership must go false
  # again so the switch never writes over a login another command is staging.
  run _account_lock_owned
  assert_failure
  _account_lock
  run _account_lock_owned
  assert_success
  printf 'host %s pid 2147483646 at %s\n' "${HOSTNAME:-unknown}" "$(date +%s)" > "$(_lock_dir)/owner"
  run _account_lock_owned
  assert_failure
  _account_unlock
}

@test "account: something this CLI did not create at the lock path is never cleared or waited on" {
  # Only a directory is ever made there. A symlink is refused at once, even one
  # old enough to read as abandoned, rather than followed, removed or polled.
  mkdir -p "$CLEAT_ACCOUNTS_DIR" "$TEST_TEMP/elsewhere"
  ln -s "$TEST_TEMP/elsewhere" "$(_lock_dir)"
  _path_mtime() { printf '%s' "$(( $(date +%s) - _ACCOUNT_LOCK_STALE_S - 5 ))"; }
  _account_lock_pause() { echo waited >> "$TEST_TEMP/pauses"; }
  _ACCOUNT_LOCK_WAIT_S=2
  run _account_lock
  assert_equal "$status" "$_ACCOUNT_LOCK_BUSY"
  run test -L "$(_lock_dir)"
  assert_success
  run test -e "$TEST_TEMP/elsewhere/owner"
  assert_failure
  run test -e "$TEST_TEMP/pauses"
  assert_failure
}

@test "account: a wipe that cannot take the account lock keeps the staged credential" {
  # Never an unlocked delete. The rest of the run dir still goes.
  _lock_pinned_pair
  _mk_account a 1000 token-a
  mkdir -p "$CLEAT_RUN_DIR/$CN/clip"
  # A journal at the run dir root goes with the rest of the directory, so it is
  # held first. That needs no lock.
  _cred_blob 1789000000000 journal-token > "$CLEAT_RUN_DIR/$CN/.prev.1789000000"
  _ACCOUNT_LOCK_WAIT_S=0
  _lock_plant "$(_lock_live_record)"
  run _account_wipe_run_dir "$CN"
  assert_success
  assert_output --partial "Kept the staged login"
  run test -f "$CLEAT_RUN_DIR/$CN/auth/.credentials.json"
  assert_success
  run test -d "$CLEAT_RUN_DIR/$CN/clip"
  assert_failure
  run grep -rl journal-token "$CLEAT_ACCOUNTS_DIR/.held"
  assert_success
  run grep -c "token-a" "$CLEAT_ACCOUNTS_DIR/a/.credentials.json"
  assert_output "1"
}

@test "account: a nuke that cannot take the account lock keeps the run dir and the login staged in it" {
  # nuke harvests every pinned box before it wipes the run dir. A harvest that
  # cannot run must never fall through to the wipe, or it deletes a login the
  # box refreshed that no store holds yet.
  _mk_account work 1000 stored-token
  _box_account_write "$CN" work
  mkdir -p "$CLEAT_RUN_DIR/$CN/auth"
  _cred_blob 1789003600000 staged-token > "$CLEAT_RUN_DIR/$CN/auth/.credentials.json"
  mock_docker_ps ""
  _ACCOUNT_LOCK_WAIT_S=0
  _lock_plant "$(_lock_live_record)"
  run cmd_nuke <<< "nuke"
  assert_output --partial "Kept $CLEAT_RUN_DIR: another cleat command is changing accounts."
  run grep -c "staged-token" "$CLEAT_RUN_DIR/$CN/auth/.credentials.json"
  assert_output "1"
  run grep -c "stored-token" "$CLEAT_ACCOUNTS_DIR/work/.credentials.json"
  assert_output "1"
  run _box_account_read "$CN"
  assert_output "work"
}

@test "account: an unpinned box's wipe takes no lock and removes everything" {
  # There is no store to harvest into, so a busy lock can never keep a stale run
  # dir around for a box that is not pinned. The login left in it is held
  # first, which needs no lock either.
  mkdir -p "$CLEAT_RUN_DIR/$CN/clip" "$CLEAT_RUN_DIR/$CN/auth"
  _cred_blob > "$CLEAT_RUN_DIR/$CN/auth/.credentials.json"
  _ACCOUNT_LOCK_WAIT_S=0
  _lock_plant "$(_lock_live_record)"
  run _account_wipe_run_dir "$CN"
  assert_success
  refute_output --partial "changing accounts"
  refute_output --partial "runtime dir"
  run test -d "$CLEAT_RUN_DIR/$CN"
  assert_failure
}

@test "account: a session that cannot take the account lock touches neither credential and says so" {
  _mk_account work 1000 stored-token
  _box_account_write "cleat-locktest" work
  mkdir -p "$CLEAT_RUN_DIR/cleat-locktest/auth"
  _cred_blob 1789003600000 staged-token > "$CLEAT_RUN_DIR/cleat-locktest/auth/.credentials.json"
  _host_clip_cmd() { echo ""; }
  _ACCOUNT_LOCK_WAIT_S=0
  _lock_plant "$(_lock_live_record)"
  run exec_claude "cleat-locktest" --dangerously-skip-permissions
  assert_output --partial "starts with the login it already has"
  assert_output --partial "The login this session refreshed was not saved"
  assert_output --partial "saved when the next session ends"
  run grep -c "stored-token" "$CLEAT_ACCOUNTS_DIR/work/.credentials.json"
  assert_output "1"
  run grep -c "staged-token" "$CLEAT_RUN_DIR/cleat-locktest/auth/.credentials.json"
  assert_output "1"
  # And the box still reads its own store: the env var is not dropped.
  run assert_docker_exec_has "CLAUDE_SECURESTORAGE_CONFIG_DIR=/home/coder/.cleat-auth"
  assert_success
}

@test "account: the session-end busy note comes after the reclaim, so a clean exit at a terminal never erases it" {
  # On a clean exit at a terminal exec_claude moves the cursor up a line and
  # erases it, to reclaim the line Claude leaves behind. Printed before that,
  # the note's last line was the one erased.
  _mk_account work 1000 stored-token
  _box_account_write "cleat-locktest" work
  mkdir -p "$CLEAT_RUN_DIR/cleat-locktest/auth"
  _cred_blob 1789003600000 staged-token > "$CLEAT_RUN_DIR/cleat-locktest/auth/.credentials.json"
  _host_clip_cmd() { echo ""; }
  _is_tty() { return 0; }
  _restore_terminal() { :; }
  _ACCOUNT_LOCK_WAIT_S=0
  _lock_plant "$(_lock_live_record)"
  run exec_claude "cleat-locktest" --dangerously-skip-permissions
  # The clean-exit leg, with its reclaim.
  assert_output --partial "Session ended"
  assert_output --partial $'\033[A\033[2K'
  local after="${output#*The login this session refreshed was not saved}"
  run printf '%s' "$after"
  assert_output --partial "It stays in the box and is saved when the next session ends."
  refute_output --partial $'\033[A'
}

@test "account: a verb that cannot take the account lock changes nothing, while list still draws" {
  # The harvest at the top of every cleat account run is the first to wait. A
  # verb that went on to wait a second time would hold the terminal for twice
  # the timeout before saying the same thing.
  _pass_gates
  _mk_account work 1000 stored-token
  _box_account_write "$(container_name_for "$(resolve_project "$PWD")" main)" work
  _ACCOUNT_LOCK_WAIT_S=0
  _lock_plant "$(_lock_live_record)"
  eval "$(declare -f _account_lock | sed '1s/^_account_lock /_acct_orig_lock /')"
  _account_lock() { echo attempt >> "$TEST_TEMP/lock-attempts"; _acct_orig_lock "$@"; }
  run cmd_account rename work other
  assert_failure
  assert_output --partial "Another cleat command is changing accounts right now."
  run grep -c attempt "$TEST_TEMP/lock-attempts"
  assert_output "1"
  run test -d "$CLEAT_ACCOUNTS_DIR/work"
  assert_success
  run cmd_account list
  assert_success
  assert_output --partial "work"
}

@test "account: rename and restore that cannot take the account lock say so, not that the account is missing" {
  # The usual case: the project's box is unpinned, so the harvest at the top of
  # the verb takes no lock and the busy status comes back from the rename or the
  # restore itself.
  _pass_gates
  _mk_account work 1000 stored-token
  _mk_account gone 1000 gone-token
  _account_trash gone
  run _box_account_read "$(container_name_for "$(resolve_project "$PWD")" main)"
  assert_output "$_ACCOUNT_DEFAULT"
  _ACCOUNT_LOCK_WAIT_S=0
  _lock_plant "$(_lock_live_record)"
  run cmd_account rename work other
  assert_failure
  assert_output --partial "Another cleat command is changing accounts right now."
  refute_output --partial "Could not rename"
  run cmd_account restore gone
  assert_failure
  assert_output --partial "Another cleat command is changing accounts right now."
  refute_output --partial "No removed account"
  refute_output --partial "Trash:"
  run test -d "$CLEAT_ACCOUNTS_DIR/work"
  assert_success
  run test -e "$CLEAT_ACCOUNTS_DIR/other"
  assert_failure
  run test -e "$CLEAT_ACCOUNTS_DIR/gone"
  assert_failure
  run _account_trash_scan
  assert_output --partial "	gone"
}

@test "account: a pin rewrite never shows a reader an empty pin" {
  # The attach, status and the launch summary read the pin without the lock,
  # and an empty pin reads as the shared login.
  _box_account_write "$CN" a
  local f
  f="$(_box_account_file "$CN")"
  printf() {
    if [[ "${2:-}" == "b" && ! -e "$TEST_TEMP/seen" ]]; then
      head -n1 "$f" > "$TEST_TEMP/seen" 2>/dev/null
    fi
    builtin printf "$@"
  }
  _box_account_write "$CN" b
  unset -f printf
  run cat "$TEST_TEMP/seen"
  assert_output "a"
  run _box_account_read "$CN"
  assert_output "b"
  # No temp file is left for a glob over the pins to trip on.
  run _account_pinned_boxes b
  assert_output "$CN"
}

@test "account: a locked body that calls a locking wrapper nests instead of waiting on itself" {
  # Waiting on its own lock would end in the timeout, and every caller treats
  # that as "change nothing", so the harvest would be skipped without a word.
  _mk_account work 1000
  _box_account_write "$CN" work
  _mk_staged "$CN" 1789003600000
  _ACCOUNT_LOCK_WAIT_S=0
  _account_lock
  run _account_sync_out "$CN"
  assert_success
  _account_unlock
  _lock_absent "the outer hold"
  run grep -c 1789003600000 "$CLEAT_ACCOUNTS_DIR/work/.credentials.json"
  assert_output "1"
}

@test "account: the pin directory is not readable by other users" {
  # At the host umask it listed every container name and the account pinned
  # to it.
  rm -rf "$CLEAT_BOX_ACCOUNTS_DIR"
  umask 022
  _box_account_write "$CN" work
  run stat -c '%a' "$CLEAT_BOX_ACCOUNTS_DIR"
  [ "$status" -eq 0 ] || run stat -f '%Lp' "$CLEAT_BOX_ACCOUNTS_DIR"
  assert_output "700"
}

@test "account: a snapshot refuses a symlink swapped in after the regular-file check" {
  # The staged file is box-writable. A symlink swapped in between the check and
  # the open would have the host read any file the user can read.
  local src="$CLEAT_RUN_DIR/$CN/auth/.credentials.json" secret="$TEST_TEMP/host-secret.json"
  mkdir -p "${src%/*}"
  _cred_blob > "$src"
  printf '{"secret":"FAKE-HOST-SECRET"}\n' > "$secret"
  mktemp() {
    rm -f "$src"
    ln -s "$secret" "$src"
    command mktemp "$@"
  }
  run _account_snapshot_cred "$src"
  assert_failure
  assert_output ""
  unset -f mktemp
  # Nothing is left behind in the accounts directory.
  run bash -c 'ls -A "$1" | grep -c "^[.]snap[.]"' _ "$CLEAT_ACCOUNTS_DIR"
  assert_output "0"
  # The same file with no swap snapshots, so the refusal above is the swap.
  rm -f "$src"
  _cred_blob > "$src"
  run _account_snapshot_cred "$src"
  assert_success
  run cat "$output"
  assert_output --partial "r-token"
}

@test "account: a box pinned while rm waits at its prompt is unpinned too" {
  # The pinned boxes were read before the question and never again, so a box
  # pinned while it was on screen stayed pinned to a store in the trash.
  _pass_gates
  _is_interactive() { return 0; }
  _mk_account work
  _box_account_write "$CN" work
  _ask_yn() {
    _box_account_write "cleat-late-abcdef12" work
    _mk_staged "cleat-late-abcdef12" 1
    printf -v "$1" '%s' y
  }
  run _account_do_remove work 0
  assert_success
  run _box_account_read "cleat-late-abcdef12"
  assert_output "default"
  run test -e "$CLEAT_RUN_DIR/cleat-late-abcdef12/auth/.credentials.json"
  assert_failure
}

# ── held logins ────────────────────────────────────────────────────────────
#
# A login a box had that no store took is copied to accounts/.held before any
# wipe, switch, remove or attach deletes or replaces it.

_mode_of() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"; }

# $1 = refreshToken tag. Holds a login for $CN and leaves its id in HELD_ID.
_mk_held() {
  _cred_blob "${2:-1789025200000}" "$1" > "$TEST_TEMP/held-src.json"
  _account_hold "$TEST_TEMP/held-src.json" "${3-work}" "$CN" "${4:-unsaved}"
  HELD_ID="$_ACCOUNT_HELD_ID"
}

@test "account: a switch that cannot keep the outgoing login changes nothing" {
  # The hold is impossible, so the switch away, the unpin and the remove all
  # stop before anything moves, and the lock is released.
  _pass_gates
  local staged="$CLEAT_RUN_DIR/$CN/auth/.credentials.json"
  _mk_account work 1789028800000 store-token
  _mk_account other 1789025200000 other-token
  _box_account_write "$CN" work
  mkdir -p "$CLEAT_RUN_DIR/$CN/auth"
  _cred_blob 1789025200000 box-login > "$staged"
  : > "$CLEAT_ACCOUNTS_DIR/.held"
  run _account_do_switch other main "$CN" "$TEST_TEMP/proj"
  assert_failure
  assert_output --partial "Nothing was switched"
  run _account_do_switch default main "$CN" "$TEST_TEMP/proj"
  assert_failure
  assert_output --partial "Nothing was switched"
  run _account_do_remove work 1
  assert_failure
  assert_output --partial "Nothing was removed"
  run _box_account_read "$CN"
  assert_output "work"
  run _account_exists work
  assert_success
  run grep -c box-login "$staged"
  assert_output "1"
  run test -e "$CLEAT_ACCOUNTS_DIR/.lock"
  assert_failure
}

@test "account: a staged login the store already holds is wiped with no held copy" {
  # The same grant, and the store is at least as fresh. Holding it would bury
  # every real held login under a copy of every box on the account.
  local mode
  for mode in jq nojq; do
    [[ "$mode" == nojq ]] && _hide_jq
    _mk_account work 1789028800000 same-grant
    _box_account_write "$CN" work
    mkdir -p "$CLEAT_RUN_DIR/$CN/auth"
    _cred_blob 1789025200000 same-grant > "$CLEAT_RUN_DIR/$CN/auth/.credentials.json"
    run _account_sync_out "$CN"
    assert_success
    run _account_wipe_run_dir "$CN"
    assert_success
    refute_output --partial "Kept"
    run test -d "$CLEAT_RUN_DIR/$CN"
    assert_failure
    run test -e "$CLEAT_ACCOUNTS_DIR/.held"
    assert_failure
  done
  unset -f command
}

@test "account: a symlinked staged credential is never copied into the held logins" {
  # The auth dir is the box's own mount, so a link there can point at any file
  # the host user can read.
  _pass_gates
  _mk_account work 1789028800000 store-token
  _mk_account other 1789025200000 other-token
  _box_account_write "$CN" work
  mkdir -p "$CLEAT_RUN_DIR/$CN/auth"
  _cred_blob 1789025200000 host-secret > "$TEST_TEMP/host.json"
  ln -s "$TEST_TEMP/host.json" "$CLEAT_RUN_DIR/$CN/auth/.credentials.json"
  run _account_do_switch other main "$CN" "$TEST_TEMP/proj"
  assert_success
  run grep -rl host-secret "$CLEAT_ACCOUNTS_DIR"
  assert_failure
}

@test "account: setting aside a box's leftover files skips links, pipes, non-credentials and the store's own copy" {
  local rd="$CLEAT_RUN_DIR/$CN" auth="$CLEAT_RUN_DIR/$CN/auth"
  _mk_account work 1789028800000 store-token
  _box_account_write "$CN" work
  mkdir -p "$auth"
  _cred_blob 1789025200000 store-token > "$auth/.credentials.json"
  _cred_blob 1789025200000 planted-through-link > "$TEST_TEMP/host.json"
  ln -s "$TEST_TEMP/host.json" "$auth/.cleat-link.json"
  mkfifo "$auth/.pipe.json"
  printf '{"hooks":{}}\n' > "$rd/settings.json"
  cp "$CLEAT_ACCOUNTS_DIR/work/.credentials.json" "$auth/.credentials.json.tmp.AbC123"
  # The one real leftover: a journal at the run dir root.
  _cred_blob 1789021600000 journal-token > "$rd/.prev.1789000000"
  # A second box whose auth dir is itself a link to a host directory.
  mkdir -p "$CLEAT_RUN_DIR/cleat-linked-abcdef12" "$TEST_TEMP/hostdir"
  _cred_blob 1789025200000 linked-dir-secret > "$TEST_TEMP/hostdir/.cleat-prev.json"
  ln -s "$TEST_TEMP/hostdir" "$CLEAT_RUN_DIR/cleat-linked-abcdef12/auth"
  run _account_hold_run_extras "$CN"
  assert_success
  run _account_hold_run_extras cleat-linked-abcdef12
  assert_success
  run grep -rl journal-token "$CLEAT_ACCOUNTS_DIR/.held"
  assert_success
  run grep -rlE "planted-through-link|store-token|linked-dir-secret" "$CLEAT_ACCOUNTS_DIR/.held"
  assert_failure
}

@test "account: switching an unpinned box keeps a login left in its auth dir" {
  # No harvest looks at a box that is not pinned, so a staged file a crash left
  # there went with the switch.
  _pass_gates
  _mk_account work 1789028800000 store-token
  mkdir -p "$CLEAT_RUN_DIR/$CN/auth"
  _cred_blob 1789025200000 left-login > "$CLEAT_RUN_DIR/$CN/auth/.credentials.json"
  run _account_do_switch work main "$CN" "$TEST_TEMP/proj"
  assert_success
  assert_output --partial "Kept a login left behind"
  run grep -rl left-login "$CLEAT_ACCOUNTS_DIR/.held"
  assert_success
  run grep -c store-token "$CLEAT_RUN_DIR/$CN/auth/.credentials.json"
  assert_output "1"
}

@test "account: a wipe does not keep a staged file that is not a credential" {
  # Claude blanks both tokens on invalid_grant. The harvest refuses that, and a
  # wipe that kept auth/ on every refusal left the directory for good while
  # cleat clean reported pruning it on every run.
  _mk_account work 1000 store-token
  _box_account_write "$CN" work
  mkdir -p "$CLEAT_RUN_DIR/$CN/auth"
  printf '{"claudeAiOauth":{"accessToken":"","refreshToken":"","expiresAt":1789025200000}}\n' > "$CLEAT_RUN_DIR/$CN/auth/.credentials.json"
  run _account_sync_out "$CN"
  assert_failure
  run _account_wipe_run_dir "$CN"
  assert_success
  run test -d "$CLEAT_RUN_DIR/$CN"
  assert_failure
  run test -e "$CLEAT_ACCOUNTS_DIR/.held"
  assert_failure
}

@test "account: held logins are 0600 in a 0700 directory and a symlinked held directory is refused" {
  local entry
  umask 022
  _mk_held held-token
  entry="$CLEAT_ACCOUNTS_DIR/.held/$HELD_ID"
  run _account_held_id_ok "$HELD_ID"
  assert_success
  run _mode_of "$CLEAT_ACCOUNTS_DIR/.held"
  assert_output "700"
  run _mode_of "$entry"
  assert_output "700"
  run _mode_of "$entry/.credentials.json"
  assert_output "600"
  run _mode_of "$entry/meta"
  assert_output "600"
  # A link where the held logins go is refused, never written through.
  CLEAT_ACCOUNTS_DIR="$TEST_TEMP/accounts2"
  mkdir -p "$CLEAT_ACCOUNTS_DIR" "$TEST_TEMP/elsewhere"
  ln -s "$TEST_TEMP/elsewhere" "$CLEAT_ACCOUNTS_DIR/.held"
  run _account_hold "$TEST_TEMP/held-src.json" work "$CN" unsaved
  assert_failure
  run ls -A "$TEST_TEMP/elsewhere"
  assert_output ""
}

@test "account: held logins are swept after the trash window and fresh ones are kept" {
  local held="$CLEAT_ACCOUNTS_DIR/.held" now
  now="$(date +%s)"
  mkdir -p "$held/1000000000-AbC123" "$held/${now}-XyZ789" "$held/not-an-id"
  _cred_blob > "$held/1000000000-AbC123/.credentials.json"
  _cred_blob > "$held/${now}-XyZ789/.credentials.json"
  run _account_trash_sweep
  assert_success
  run test -d "$held/1000000000-AbC123"
  assert_failure
  run test -d "$held/${now}-XyZ789"
  assert_success
  run test -d "$held/not-an-id"
  assert_success
}

@test "account: held logins are listed with where they were headed and how to save one" {
  _mk_held listed-token
  run _accounts_held_text
  assert_success
  assert_output --partial "$HELD_ID"
  assert_output --partial "from box $CN, for account work"
  assert_output --partial "cleat account adopt <id> <name>"
  run _account_held_count
  assert_output "1"
  # Every plain list points at them.
  _mk_account work
  run _accounts_picker_text main "$CN"
  assert_success
  assert_output --partial "1 held login. See it with"
}

@test "account: the live frame advertises held logins on the counter line" {
  local widest
  _term_cols() { echo 100; }
  _mk_account one
  _ACCT_VIEW="live"
  _accounts_load_rows one
  _ACCT_TRASH_N=0
  _ACCT_HELD_N=0
  _accounts_frame 0 0 "$_ACCT_N" 100 "$_ACCT_N" > "$TEST_TEMP/none.out" 2>/dev/null
  run grep -c "held" "$TEST_TEMP/none.out"
  assert_output "0"
  _ACCT_HELD_N=3
  _accounts_frame 0 0 "$_ACCT_N" 100 "$_ACCT_N" > "$TEST_TEMP/held.out" 2>/dev/null
  run grep -c "held (3): cleat account held" "$TEST_TEMP/held.out"
  assert_output "1"
  # The same height, which is what the cursor-up reposition depends on.
  assert_equal "$(wc -l < "$TEST_TEMP/held.out")" "$(wc -l < "$TEST_TEMP/none.out")"
  # Beside the trash pointer at the narrowest supported width, it is clamped
  # rather than wrapped.
  _ACCT_TRASH_N=99
  _ACCT_HELD_N=99
  _accounts_frame 0 0 1 44 1 > "$TEST_TEMP/narrow.out" 2>/dev/null
  widest="$(sed $'s/\033\\[[0-9;]*[A-Za-z]//g' "$TEST_TEMP/narrow.out" \
    | sed 's/↑/^/g; s/↓/v/g; s/⏎/E/g; s/▸/>/g; s/·/./g; s/…/./g; s/•/o/g; s/→/-/g; s/←/-/g' \
    | awk '{ n = length($0); if (n > m) m = n } END { print m + 0 }')"
  run test "$widest" -le 44
  assert_success
}

@test "account: a held login adopted under a new name becomes that account" {
  _mk_held adopted-token 1789025200000 "" left-in-box
  run _account_do_adopt "$HELD_ID" fresh
  assert_success
  run grep -c adopted-token "$CLEAT_ACCOUNTS_DIR/fresh/.credentials.json"
  assert_output "1"
  run _mode_of "$CLEAT_ACCOUNTS_DIR/fresh/.credentials.json"
  assert_output "600"
  run _mode_of "$CLEAT_ACCOUNTS_DIR/fresh"
  assert_output "700"
  run test -e "$CLEAT_ACCOUNTS_DIR/.held/$HELD_ID"
  assert_failure
  # An id that is not held, or a name that cannot be an account, changes nothing.
  _mk_held second-token
  run _account_do_adopt 1789000000-ZZZZZZ other
  assert_failure
  run _account_do_adopt "$HELD_ID" held
  assert_failure
  run _account_exists other
  assert_failure
  run test -d "$CLEAT_ACCOUNTS_DIR/.held/$HELD_ID"
  assert_success
}

@test "account: adopting into an existing account holds the credential it replaces" {
  local first
  _mk_account work 1789028800000 old-store-token
  _mk_held new-token
  first="$HELD_ID"
  run _account_do_adopt "$first" work
  assert_success
  run grep -c new-token "$CLEAT_ACCOUNTS_DIR/work/.credentials.json"
  assert_output "1"
  run grep -rl old-store-token "$CLEAT_ACCOUNTS_DIR/.held"
  assert_success
  run test -e "$CLEAT_ACCOUNTS_DIR/.held/$first"
  assert_failure
}

@test "account: an adopted login carries its own identity and the one it replaced keeps its own" {
  local held_old=""
  _mk_account work 1789028800000 old-store-token
  # No uuid: an account saved before any harvest was verified. Two known and
  # different uuids are refused instead (see the adopt identity test).
  printf 'who\tx@example.com\norg\tX Org\n' > "$CLEAT_ACCOUNTS_DIR/work/meta"
  # The held login knows who it is but not its organisation.
  _cred_blob 1789025200000 new-token > "$TEST_TEMP/held-src.json"
  _account_hold "$TEST_TEMP/held-src.json" work "$CN" unsaved new-uuid-0002 y@example.com ""
  run _account_do_adopt "$_ACCOUNT_HELD_ID" work
  assert_success
  run _account_meta_get work who
  assert_output "y@example.com"
  run _account_meta_get work uuid
  assert_output "new-uuid-0002"
  # Never left naming the organisation of the login that was replaced.
  run _account_meta_get work org
  assert_output ""
  # The replaced login is held under the name it was saved with.
  local d
  for d in "$CLEAT_ACCOUNTS_DIR/.held"/*; do held_old="$d"; done
  run grep -c old-store-token "$held_old/.credentials.json"
  assert_output "1"
  run _account_meta_get_at "$held_old" who
  assert_output "x@example.com"
  run _account_meta_get_at "$held_old" org
  assert_output "X Org"
}

@test "account: adopting into an account whose pinned box has a live session changes nothing" {
  _daemon_up() { return 0; }
  container_exists() { return 0; }
  is_running() { return 0; }
  _box_has_live_agent() { return 0; }
  _mk_account work 1789028800000 store-token
  _box_account_write "$CN" work
  mkdir -p "$CLEAT_RUN_DIR/$CN/auth"
  cp "$CLEAT_ACCOUNTS_DIR/work/.credentials.json" "$CLEAT_RUN_DIR/$CN/auth/.credentials.json"
  _mk_held adopted-token 1789025200000 "" left-in-box
  run _account_do_adopt "$HELD_ID" work
  assert_failure
  assert_output --partial "has a live Claude session"
  run test -f "$CLEAT_ACCOUNTS_DIR/.held/$HELD_ID/.credentials.json"
  assert_success
  run grep -c store-token "$CLEAT_ACCOUNTS_DIR/work/.credentials.json"
  assert_output "1"
  run grep -c store-token "$CLEAT_RUN_DIR/$CN/auth/.credentials.json"
  assert_output "1"
}

@test "account: an adopt that cannot keep a pinned box's login saves nothing" {
  _pass_gates
  local staged="$CLEAT_RUN_DIR/$CN/auth/.credentials.json"
  _mk_account work 1789028800000 store-token
  _box_account_write "$CN" work
  mkdir -p "$CLEAT_RUN_DIR/$CN/auth"
  _cred_blob 1789025200000 box-login > "$staged"
  _mk_held adopted-token 1789025200000 "" left-in-box
  # No copy of the box's login can be taken.
  _account_snapshot_cred() { return 1; }
  run _account_do_adopt "$HELD_ID" work
  assert_failure
  assert_output --partial "Could not keep the login"
  assert_output --partial "Nothing was saved"
  run test -f "$CLEAT_ACCOUNTS_DIR/.held/$HELD_ID/.credentials.json"
  assert_success
  run grep -c store-token "$CLEAT_ACCOUNTS_DIR/work/.credentials.json"
  assert_output "1"
  run grep -c box-login "$staged"
  assert_output "1"
  run test -e "$CLEAT_ACCOUNTS_DIR/.lock"
  assert_failure
}

@test "account: an adopt whose store write fails keeps the held login" {
  _mk_account work 1789028800000 store-token
  _mk_held adopted-token
  # The write into the store fails, the way a full disk does.
  _account_write_cred() { return 1; }
  run _account_do_adopt "$HELD_ID" work
  assert_failure
  assert_output --partial "The held login is still there"
  run grep -c adopted-token "$CLEAT_ACCOUNTS_DIR/.held/$HELD_ID/.credentials.json"
  assert_output "1"
  run grep -c store-token "$CLEAT_ACCOUNTS_DIR/work/.credentials.json"
  assert_output "1"
}

@test "account: an attach that cannot keep the login it would replace stages nothing and says so" {
  # The store's login is newer and a different one. It is staged only once the
  # box's login is held. The held logins have nowhere to go.
  _pass_gates
  local staged="$CLEAT_RUN_DIR/$CN/auth/.credentials.json"
  _mk_account work 1789028800000 store-token
  _box_account_write "$CN" work
  mkdir -p "$CLEAT_RUN_DIR/$CN/auth"
  _cred_blob 1789025200000 box-login > "$staged"
  : > "$CLEAT_ACCOUNTS_DIR/.held"
  _account_box_ready() { return 0; }
  CLAUDE_ENV=()
  run _account_apply_exec_env "$CN"
  assert_success
  assert_output --partial "starts with the login it already has: it could not be kept before staging"
  assert_output --partial "is writable"
  run grep -c box-login "$staged"
  assert_output "1"
  # Re-selecting the account the box is on stages the same way and names why.
  run _account_do_switch work main "$CN" "$TEST_TEMP/proj"
  assert_failure
  assert_output --partial "Could not keep the login"
  run grep -c box-login "$staged"
  assert_output "1"
}

@test "account: nuke keeps the run dir when a login in it cannot be kept" {
  mock_docker_ps_a ""
  # Something that is not a directory where the held logins go.
  : > "$CLEAT_ACCOUNTS_DIR/.held"
  # A pinned box with a login its store does not have.
  _mk_account work 1789028800000 store-token
  _box_account_write "$CN" work
  mkdir -p "$CLEAT_RUN_DIR/$CN/auth"
  _cred_blob 1789025200000 box-login > "$CLEAT_RUN_DIR/$CN/auth/.credentials.json"
  run cmd_nuke <<< "nuke"
  assert_output --partial "could not be saved anywhere else"
  run grep -c box-login "$CLEAT_RUN_DIR/$CN/auth/.credentials.json"
  assert_output "1"
  # A box that is not pinned, with a journal in it, while no box is pinned.
  CLEAT_RUN_DIR="$TEST_TEMP/run-unpinned"
  CLEAT_BOX_ACCOUNTS_DIR="$TEST_TEMP/pins-empty"
  mkdir -p "$CLEAT_BOX_ACCOUNTS_DIR" "$CLEAT_RUN_DIR/$CN/auth"
  _cred_blob 1789025200000 journal-token > "$CLEAT_RUN_DIR/$CN/auth/.cleat-prev.json"
  run cmd_nuke <<< "nuke"
  assert_output --partial "could not be saved anywhere else"
  run grep -c journal-token "$CLEAT_RUN_DIR/$CN/auth/.cleat-prev.json"
  assert_output "1"
}

@test "account: a login whose copy cannot be taken is never deleted" {
  _pass_gates
  local staged="$CLEAT_RUN_DIR/$CN/auth/.credentials.json" accts="$CLEAT_ACCOUNTS_DIR"
  mkdir -p "$CLEAT_RUN_DIR/$CN/auth"
  _cred_blob 1789025200000 box-login > "$staged"
  # A box that is not pinned, with no directory to copy its login into.
  CLEAT_ACCOUNTS_DIR="$TEST_TEMP/accounts-is-a-file"
  : > "$CLEAT_ACCOUNTS_DIR"
  run _account_wipe_run_dir "$CN"
  assert_success
  assert_output --partial "could not be saved anywhere else"
  run grep -c box-login "$staged"
  assert_output "1"
  # A pinned box whose login cannot be copied, for a switch and for a wipe.
  CLEAT_ACCOUNTS_DIR="$accts"
  _mk_account work 1789028800000 store-token
  _mk_account other 1789025200000 other-token
  _box_account_write "$CN" work
  _account_snapshot_cred() { return 1; }
  run _account_do_switch other main "$CN" "$TEST_TEMP/proj"
  assert_failure
  assert_output --partial "Nothing was switched"
  run grep -c box-login "$staged"
  assert_output "1"
  run _account_wipe_run_dir "$CN"
  assert_success
  run grep -c box-login "$staged"
  assert_output "1"
}

# ── identity-verified harvest ──────────────────────────────────────────────
#
# A newer staged login is saved over the store only when it is provably the same
# account: the same refresh token, or the account uuid the server names for it.
# Every test that reaches the server stubs _account_profile_curl, and the setup's
# curl answers nothing for the rest.

@test "account: a login verified as the pinned account is harvested and its identity recorded" {
  # A rotated refresh token is a different grant, so only the server can say it
  # is still this account. The uuid matches the recorded one, so it is saved,
  # and what the account shows afterwards is the server's current answer.
  _mk_account work 1000 old-token
  printf 'uuid\t%s\nwho\told@example.com\norg\tOld Org\n' "$UUID_WORK" > "$CLEAT_ACCOUNTS_DIR/work/meta"
  _box_account_write "$CN" work
  mkdir -p "$CLEAT_RUN_DIR/$CN/auth"
  _cred_blob 1789003600000 rotated-token > "$CLEAT_RUN_DIR/$CN/auth/.credentials.json"
  _profile_says "$UUID_WORK" New@Example.com "New Org"
  run _account_sync_out "$CN"
  assert_success
  run grep -c rotated-token "$CLEAT_ACCOUNTS_DIR/work/.credentials.json"
  assert_output "1"
  run _account_meta_get work uuid
  assert_output "$UUID_WORK"
  run _account_meta_get work who
  assert_output "New@Example.com"
  run _account_meta_get work org
  assert_output "New Org"
  run test -e "$CLEAT_ACCOUNTS_DIR/.held"
  assert_failure
}

@test "account: an unchanged refresh token is harvested without asking the server" {
  # A refresh that kept the grant is the same login, and most refreshes are that.
  _mk_account work 1000
  printf 'uuid\t%s\n' "$UUID_WORK" > "$CLEAT_ACCOUNTS_DIR/work/meta"
  _box_account_write "$CN" work
  _mk_staged "$CN" 1789003600000
  # Were it asked, the server would call this login someone else's.
  _profile_says "$UUID_OTHER" other@example.com
  run _account_sync_out "$CN"
  assert_success
  run grep -c 1789003600000 "$CLEAT_ACCOUNTS_DIR/work/.credentials.json"
  assert_output "1"
  run test -e "$TEST_TEMP/profile-asked"
  assert_failure
}

@test "account: an MCP login both files share never stands in for the same Claude login" {
  # Claude writes mcpOAuth ahead of claudeAiOauth after /login, and an attach
  # copies the store's whole file into the box, so the store and a login made in
  # the box as someone else can open with the same MCP refresh token.
  local leg cn staged
  for leg in jq nojq; do
    [ "$leg" = nojq ] && _hide_jq
    cn="cleat-mcp-$leg"
    _mk_account "work-$leg"
    printf 'uuid\t%s\n' "$UUID_WORK" > "$CLEAT_ACCOUNTS_DIR/work-$leg/meta"
    _mcp_order_blob mc at-store rt-store | sed 's/1789007200000/1789003600000/' \
      > "$CLEAT_ACCOUNTS_DIR/work-$leg/.credentials.json"
    _box_account_write "$cn" "work-$leg"
    staged="$CLEAT_RUN_DIR/$cn/auth/.credentials.json"
    mkdir -p "${staged%/*}"
    _mcp_order_blob mc at-other rt-other > "$staged"
    _profile_says "$UUID_OTHER" other@example.com
    run _account_sync_out "$cn"
    assert_equal "$leg $status" "$leg 2"
    run grep -c rt-store "$CLEAT_ACCOUNTS_DIR/work-$leg/.credentials.json"
    assert_output "1"
  done
  unset -f command
}

@test "account: an expired access token is never sent to the server" {
  # Asking with a dead token only earns a 401, and refreshing it first could
  # rotate a refresh token another copy still holds. It reads as cannot tell.
  _mk_account work 1000 old-token
  _box_account_write "$CN" work
  mkdir -p "$CLEAT_RUN_DIR/$CN/auth"
  # Newer than the store, but its access token expired a second ago.
  _cred_blob 1788999999000 rotated-token > "$CLEAT_RUN_DIR/$CN/auth/.credentials.json"
  _profile_says "$UUID_WORK" work@example.com
  run _account_sync_out "$CN"
  assert_equal "$status" 3
  run test -e "$TEST_TEMP/profile-asked"
  assert_failure
  run grep -c old-token "$CLEAT_ACCOUNTS_DIR/work/.credentials.json"
  assert_output "1"
}

@test "account: a login the server cannot be asked about is left where it is" {
  local staged="$CLEAT_RUN_DIR/$CN/auth/.credentials.json"
  _mk_account work 1000 old-token
  _box_account_write "$CN" work
  mkdir -p "${staged%/*}"
  _profile_says "$UUID_WORK" work@example.com
  # An access token a curl config cannot carry safely.
  printf '{"claudeAiOauth":{"accessToken":"at \\"x","refreshToken":"rotated","expiresAt":1789003600000}}\n' > "$staged"
  run _account_sync_out "$CN"
  assert_equal "unsafe $status" "unsafe 3"
  # No curl on the host.
  _cred_blob 1789003600000 rotated > "$staged"
  command() {
    if [ "$1" = "-v" ] && [ "$2" = "curl" ]; then return 1; fi
    builtin command "$@"
  }
  run _account_sync_out "$CN"
  unset -f command
  assert_equal "no-curl $status" "no-curl 3"
  run test -e "$TEST_TEMP/profile-asked"
  assert_failure
  run grep -c old-token "$CLEAT_ACCOUNTS_DIR/work/.credentials.json"
  assert_output "1"
}

@test "account: the profile request carries the token on stdin and ends with the status code" {
  command -v curl >/dev/null || skip "needs curl"
  curl() { cat > "$TEST_TEMP/curl.stdin"; printf '%s\n' "$*" > "$TEST_TEMP/curl.argv"; }
  run _account_profile_curl "SECRET-TOKEN"
  assert_success
  run cat "$TEST_TEMP/curl.argv"
  refute_output --partial "SECRET-TOKEN"
  run cat "$TEST_TEMP/curl.stdin"
  assert_output --partial 'header = "Authorization: Bearer SECRET-TOKEN"'
  assert_output --partial 'url = "https://api.anthropic.com/api/oauth/profile"'
  assert_output --partial 'max-time = 3'
  # A real curl reads that config: the last line is the code, 000 when nothing
  # answered, which is "cannot tell".
  unset -f curl
  _ACCOUNT_PROFILE_URL="http://127.0.0.1:9/api/oauth/profile"
  run _account_profile_curl "tok"
  assert_output "$(printf '\n000')"
  _mk_account work 1789003600000 rt
  run _account_cred_identity "$CLEAT_ACCOUNTS_DIR/work/.credentials.json"
  assert_equal "$status" 3
  assert_output ""
}

@test "account: the profile reader takes the account uuid and nothing forged inside a string" {
  local body leg want
  body='{"account":{"full_name":"x \"uuid\":\"forged-uuid-0000\",\"email\":\"evil@example.com\"","uuid":"'"$UUID_WORK"'","email":"real@example.com"},"organization":{"name":"Org \"name\":\"Forged\"","uuid":"org-0001","cc_onboarding_flags":{}}}'
  want="$(printf '%s\t%s\t%s' "$UUID_WORK" real@example.com 'Org "name":"Forged"')"
  for leg in jq nojq; do
    [ "$leg" = nojq ] && _hide_jq
    run _account_profile_parse "$body"
    assert_success
    assert_output "$want"
  done
  unset -f command
}

@test "account: the profile reader refuses a shape it does not know" {
  # Not a vacuous pass: the reader exists.
  run type -t _account_profile_parse
  assert_output "function"
  local u="$UUID_WORK" e='"email":"a@example.com"' body
  for body in \
    '{"account":{"uuid":"'"$u"'",'"$e"'},"account":{"uuid":"'"$UUID_OTHER"'","email":"b@example.com"}}' \
    '{"account":{"uuid":"'"$u"'",'"$e"'},"meta":{"account":{"role":"member"}}}' \
    '{"account":{"uuid":"'"$u"'",'"$e"',"memberships":{"org":"x"}}}' \
    '{"account":{"uuid":"'"$u"'","uuid":"'"$UUID_OTHER"'",'"$e"'}}' \
    '{"account":{"uuid":"'"$u"'"}}' \
    '{"account":{"uuid":"'"$u"'","email":""}}' \
    '{"account":{"uuid":"not a uuid!",'"$e"'}}' \
    '{"account":{"uuid":"abc",'"$e"'}}' \
    '{"account":{"uuid":12345678901,'"$e"'}}' \
    '{"type":"error","error":{"type":"authentication_error","message":"Invalid bearer token"}}' \
    ''; do
    run _account_profile_parse "$body"
    assert_equal "$status:$output <- $body" "1: <- $body"
  done
}

@test "account: a box that keeps refreshing a foreign login keeps one held entry, the newest" {
  local staged="$CLEAT_RUN_DIR/$CN/auth/.credentials.json" gen
  _mk_account work 1000 store-token
  printf 'uuid\t%s\nwho\twork@example.com\n' "$UUID_WORK" > "$CLEAT_ACCOUNTS_DIR/work/meta"
  _box_account_write "$CN" work
  mkdir -p "${staged%/*}"
  _profile_says "$UUID_OTHER" other@example.com
  # Every session end on a box running as another account holds a new generation.
  for gen in 1 2 3; do
    printf '{"claudeAiOauth":{"accessToken":"at-B%s","refreshToken":"rt-B%s","expiresAt":%s}}\n' \
      "$gen" "$gen" "$(( 1789003600000 + gen * 1000 ))" > "$staged"
    run _account_sync_out "$CN"
    assert_equal "gen $gen: $status" "gen $gen: 2"
  done
  run _account_held_count
  assert_output "1"
  run grep -rl '"accessToken":"at-B3"' "$CLEAT_ACCOUNTS_DIR/.held"
  assert_success
  # An older generation turning up late does not replace it.
  printf '{"claudeAiOauth":{"accessToken":"at-B2","refreshToken":"rt-B2","expiresAt":1789003602000}}\n' > "$staged"
  run _account_sync_out "$CN"
  assert_equal "$status" 2
  run _account_held_count
  assert_output "1"
  run grep -rl '"accessToken":"at-B3"' "$CLEAT_ACCOUNTS_DIR/.held"
  assert_success
  # A newer login the server names as a third account is not a generation of
  # the second one. Folding it in would delete the only copy of that login.
  printf '{"claudeAiOauth":{"accessToken":"at-C1","refreshToken":"rt-C1","expiresAt":1789003609000}}\n' > "$staged"
  _profile_says "3c2b1a09-8f7e-4d6c-9b5a-4f3e2d1c0b9a" third@example.com
  run _account_sync_out "$CN"
  assert_equal "$status" 2
  run _account_held_count
  assert_output "2"
  run grep -rl '"accessToken":"at-B3"' "$CLEAT_ACCOUNTS_DIR/.held"
  assert_success
  run grep -rl '"accessToken":"at-C1"' "$CLEAT_ACCOUNTS_DIR/.held"
  assert_success
  # The store never moved.
  run grep -c store-token "$CLEAT_ACCOUNTS_DIR/work/.credentials.json"
  assert_output "1"
}

@test "account: a login already held as another account is not sent to the server again" {
  _mk_account work 1000 store-token
  printf 'uuid\t%s\n' "$UUID_WORK" > "$CLEAT_ACCOUNTS_DIR/work/meta"
  _box_account_write "$CN" work
  mkdir -p "$CLEAT_RUN_DIR/$CN/auth"
  _cred_blob 1789003600000 foreign-token > "$CLEAT_RUN_DIR/$CN/auth/.credentials.json"
  _profile_says "$UUID_OTHER" other@example.com
  run _account_sync_out "$CN"
  assert_equal "$status" 2
  run _account_sync_out "$CN"
  assert_equal "$status" 2
  run grep -c asked "$TEST_TEMP/profile-asked"
  assert_output "1"
  run _account_held_count
  assert_output "1"
}

@test "account: adopt refuses a login verified as a different person than the account" {
  local id
  _mk_account work 1789028800000 store-token
  printf 'uuid\t%s\nwho\twork@example.com\n' "$UUID_WORK" > "$CLEAT_ACCOUNTS_DIR/work/meta"
  _cred_blob 1789025200000 foreign-token > "$TEST_TEMP/held-src.json"
  _account_hold "$TEST_TEMP/held-src.json" work "$CN" other-account "$UUID_OTHER" other@example.com "Other Org"
  id="$_ACCOUNT_HELD_ID"
  run _account_do_adopt "$id" work
  assert_failure
  assert_output --partial "belongs to a different account than"
  assert_output --partial "other@example.com"
  assert_output --partial "Nothing was saved"
  run grep -c store-token "$CLEAT_ACCOUNTS_DIR/work/.credentials.json"
  assert_output "1"
  run _account_meta_get work uuid
  assert_output "$UUID_WORK"
  # Nothing was exchanged: the one entry is still there and nothing joined it.
  run _account_held_count
  assert_output "1"
  run test -d "$CLEAT_ACCOUNTS_DIR/.held/$id"
  assert_success
  # Under a name of its own it is saved, with the identity the server gave it.
  run _account_do_adopt "$id" other
  assert_success
  run _account_meta_get other uuid
  assert_output "$UUID_OTHER"
  run _account_meta_get other who
  assert_output "other@example.com"
}

# ── staging by key ─────────────────────────────────────────────────────────
#
# A box's credential file also holds what the box signed into for itself (an MCP
# server's mcpOAuth, pluginSecrets). Only the account's keys cross between a box
# and a store, and a switch replaces them with one rename.

# $1 = MCP label. A box-owned member, not an object.
_mcp_member() {
  printf '"mcpOAuth":{"s|1":{"accessToken":"MCP-%s","refreshToken":"MCP-R-%s","expiresAt":1789002000000}}' "$1" "$1"
}

@test "account: a switch that cannot stage puts the pin back on the account it left" {
  # Staging replaces the old login by rename and no longer removes it first, so
  # a staging that fails leaves the old login in place. The pin has to go back
  # with it, or the next detach harvests the old account's login INTO the new
  # account's store.
  _pass_gates
  _account_usage_fetch() { return 1; }
  local staged="$CLEAT_RUN_DIR/$CN/auth/.credentials.json"
  _mk_account old 1789003600000 old-token
  _account_ensure_dir new
  # Every reader finds the login, but it is not one JSON object the merge can
  # split, so nothing can be staged from it.
  printf '{"claudeAiOauth":{"accessToken":"a-token","refreshToken":"new-token","expiresAt":1789000100000}} trailing\n' \
    > "$CLEAT_ACCOUNTS_DIR/new/.credentials.json"
  _box_account_write "$CN" old
  mkdir -p "${staged%/*}"
  cp "$CLEAT_ACCOUNTS_DIR/old/.credentials.json" "$staged"
  run _account_do_switch new main "$CN" "$TEST_TEMP/proj"
  assert_failure
  assert_output --partial "Could not stage"
  run _box_account_read "$CN"
  assert_output "old"
  run grep -c "old-token" "$staged"
  assert_output "1"
  run test -e "$CLEAT_ACCOUNTS_DIR/.lock"
  assert_failure
}

@test "account: a switch from the shared login that cannot stage leaves the box unpinned" {
  # A directory where the credential goes. A rename onto it would move the new
  # login INTO it, report success and leave the box with no credential at all.
  _pass_gates
  local cn="cleat-proj-dirdir12"
  _mk_account new 1789003600000 new-token
  mkdir -p "$CLEAT_RUN_DIR/$cn/auth/.credentials.json"
  run _account_do_switch new main "$cn" "$TEST_TEMP/proj"
  assert_failure
  assert_output --partial "Could not stage"
  run test -e "$CLEAT_BOX_ACCOUNTS_DIR/$cn"
  assert_failure
  run _box_account_read "$cn"
  assert_output "default"
  run grep -rl "new-token" "$CLEAT_RUN_DIR/$cn"
  assert_failure
}

@test "account: switching replaces a symlink the box planted where its credential goes" {
  # A symlink is not a login. The writer refuses to rename over one, so the
  # switch drops it and stages rather than failing on what the box planted.
  _pass_gates
  _account_usage_fetch() { return 1; }
  local staged="$CLEAT_RUN_DIR/$CN/auth/.credentials.json"
  _mk_account old 1789003600000 old-token
  _mk_account new 1789000100000 new-token
  _box_account_write "$CN" old
  mkdir -p "${staged%/*}"
  printf 'host file\n' > "$TEST_TEMP/elsewhere"
  ln -s "$TEST_TEMP/elsewhere" "$staged"
  run _account_do_switch new main "$CN" "$TEST_TEMP/proj"
  assert_success
  run test -L "$staged"
  assert_failure
  run grep -c "new-token" "$staged"
  assert_output "1"
  run cat "$TEST_TEMP/elsewhere"
  assert_output "host file"
}

@test "account: switching to an account with no login signs the box out but keeps its MCP login" {
  # The account being left must not stay staged under the new pin, and the
  # box's own MCP server login must not go with it.
  _pass_gates
  _account_usage_fetch() { return 1; }
  local staged="$CLEAT_RUN_DIR/$CN/auth/.credentials.json"
  _mk_account old 1789003600000 old-token
  _account_ensure_dir fresh
  _box_account_write "$CN" old
  mkdir -p "${staged%/*}"
  printf '{%s,"claudeAiOauth":{"accessToken":"a-token","refreshToken":"old-token","expiresAt":1789003600000}}\n' \
    "$(_mcp_member own)" > "$staged"
  run _account_do_switch fresh main "$CN" "$TEST_TEMP/proj"
  assert_success
  run cat "$staged"
  assert_output --partial "MCP-own"
  refute_output --partial "claudeAiOauth"
  # And the next attach, still with no login stored, leaves it as it is.
  _account_box_ready() { return 0; }
  CLAUDE_ENV=()
  run _account_apply_exec_env "$CN"
  assert_success
  run cat "$staged"
  assert_output --partial "MCP-own"
  run test -e "$CLEAT_ACCOUNTS_DIR/fresh/.credentials.json"
  assert_failure
}

# The unpin, account rm and account adopt each ended a box's use of a login by
# deleting the whole staged file, which signed the box out of the MCP servers it
# logged into for itself. A switch between two named accounts kept them. All
# three now take the account's keys out and leave the rest.
_mcp_staged_fixture() {
  _pass_gates
  _account_usage_fetch() { return 1; }
  STAGED="$CLEAT_RUN_DIR/$CN/auth/.credentials.json"
  _mk_account work 1789003600000 work-token
  _box_account_write "$CN" work
  mkdir -p "${STAGED%/*}"
  printf '{%s,"claudeAiOauth":{"accessToken":"a-token","refreshToken":"work-token","expiresAt":1789003600000}}\n' \
    "$(_mcp_member own)" > "$STAGED"
}

@test "account: unpinning keeps the box's own MCP login in the staged file" {
  _mcp_staged_fixture
  run _account_do_switch default main "$CN" "$TEST_TEMP/proj"
  assert_success
  run _box_account_read "$CN"
  assert_output "default"
  run cat "$STAGED"
  assert_output --partial "MCP-own"
  refute_output --partial "claudeAiOauth"
  run _mode_of "$STAGED"
  assert_output "600"
}

@test "account: account rm keeps the unpinned box's own MCP login in the staged file" {
  _mcp_staged_fixture
  _is_interactive() { return 0; }
  _ask_yn() { printf -v "$1" '%s' 'y'; }
  run _account_do_remove work 1
  assert_success
  run _box_account_read "$CN"
  assert_output "default"
  run cat "$STAGED"
  assert_output --partial "MCP-own"
  refute_output --partial "claudeAiOauth"
}

@test "account: account adopt keeps a pinned box's own MCP login in the staged file" {
  _mcp_staged_fixture
  _mk_held adopted-token 1789025200000 "" left-in-box
  run _account_do_adopt "$HELD_ID" work
  assert_success
  run cat "$STAGED"
  assert_output --partial "MCP-own"
  refute_output --partial "claudeAiOauth"
  run grep -c adopted-token "$CLEAT_ACCOUNTS_DIR/work/.credentials.json"
  assert_output "1"
}

@test "account: an unpin removes a staged file that holds nothing but the account's login" {
  _pass_gates
  _account_usage_fetch() { return 1; }
  _mk_account work 1789003600000 work-token
  _box_account_write "$CN" work
  mkdir -p "$CLEAT_RUN_DIR/$CN/auth"
  cp "$CLEAT_ACCOUNTS_DIR/work/.credentials.json" "$CLEAT_RUN_DIR/$CN/auth/.credentials.json"
  run _account_do_switch default main "$CN" "$TEST_TEMP/proj"
  assert_success
  run test -e "$CLEAT_RUN_DIR/$CN/auth/.credentials.json"
  assert_failure
}

@test "account: staging by key writes the same bytes with and without jq" {
  # jq is optional on the host. A Mac without it and a Linux host with it must
  # harvest and stage the same bytes from the same input.
  command -v jq >/dev/null || skip "needs jq for the jq leg"
  _leg() {
    [[ "$1" == nojq ]] && _hide_jq
    _mk_account "w-$1" 1789003600000 grant
    _box_account_write "box-$1" "w-$1"
    mkdir -p "$CLEAT_RUN_DIR/box-$1/auth"
    printf '{\n  "mcpOAuth": {"s|1": {"accessToken": "MCP-own", "expiresAt": 1789002000000}},\n  "pluginSecrets": {"p": {"k": "v \\"}{\\" w"}},\n  "claudeAiOauth": {"accessToken": "harvested", "refreshToken": "grant", "expiresAt": 1789007200000}\n}\n' \
      > "$CLEAT_RUN_DIR/box-$1/auth/.credentials.json"
    _account_sync_out "box-$1"
    cat "$CLEAT_ACCOUNTS_DIR/w-$1/.credentials.json"
    echo "--"
    printf '{"claudeAiOauth":{"accessToken":"other-box","refreshToken":"grant","expiresAt":1789010800000}}\n' \
      > "$CLEAT_ACCOUNTS_DIR/w-$1/.credentials.json"
    _account_sync_in "box-$1"
    cat "$CLEAT_RUN_DIR/box-$1/auth/.credentials.json"
  }
  local out_jq out_nojq
  out_jq="$(_leg jq)"
  out_nojq="$(_leg nojq)"
  assert_equal "$out_nojq" "$out_jq"
  run printf '%s' "${out_nojq%%--*}"
  assert_output --partial "harvested"
  refute_output --partial "MCP-own"
  run printf '%s' "${out_nojq#*--}"
  assert_output --partial "other-box"
  assert_output --partial "MCP-own"
  assert_output --partial '"k": "v \"}{\" w"'
}

@test "account: a box file the splitter cannot read is replaced by the account, never merged" {
  # What a staging writes goes back into the box, so a staged file that is not
  # one clean JSON object contributes nothing rather than half of itself.
  _mk_account work 1789003600000 stored
  _box_account_write "$CN" work
  mkdir -p "$CLEAT_RUN_DIR/$CN/auth"
  printf '{"mcpOAuth":{"a":1} junk,"claudeAiOauth":{"expiresAt":1}}' > "$CLEAT_RUN_DIR/$CN/auth/.credentials.json"
  run _account_sync_in "$CN"
  assert_success
  run cat "$CLEAT_RUN_DIR/$CN/auth/.credentials.json"
  refute_output --partial "junk"
  refute_output --partial "mcpOAuth"
  assert_output --partial "stored"
}

@test "account: the credential merge refuses to read through a symlink" {
  # Its output goes into a box or a store. Following a link would copy a HOST
  # json file there.
  _mk_account work 1789003600000 stored
  printf '{"hostSecret":"do-not-leak","claudeAiOauth":{"accessToken":"host"}}\n' > "$TEST_TEMP/host.json"
  ln -s "$TEST_TEMP/host.json" "$TEST_TEMP/link.json"
  run _account_cred_merge "$TEST_TEMP/link.json" "$CLEAT_ACCOUNTS_DIR/work/.credentials.json"
  assert_failure
  refute_output --partial "do-not-leak"
  run _account_cred_merge "" "$TEST_TEMP/link.json"
  assert_failure
  refute_output --partial "host"
}

@test "account: an attach does not rewrite a staged login that already matches the store" {
  # A rewrite moves the file under any session running in the box and gains
  # nothing. The box's own keys around the login do not make it a different one.
  _mk_account work 1789003600000 stored
  _box_account_write "$CN" work
  local staged="$CLEAT_RUN_DIR/$CN/auth/.credentials.json"
  mkdir -p "${staged%/*}"
  printf '{%s,"claudeAiOauth":{"accessToken":"a-token","refreshToken":"stored","expiresAt":1789003600000,"subscriptionType":"max"}}\n' \
    "$(_mcp_member own)" > "$staged"
  ln "$staged" "$TEST_TEMP/staged.link"
  run _account_sync_in "$CN"
  assert_success
  run test "$staged" -ef "$TEST_TEMP/staged.link"
  assert_success
}

@test "account: a held login keeps every key the box had" {
  # A held copy is the bytes it was found in, so an MCP login beside it is kept
  # too and a retry finds the same bytes already held.
  _mk_account work 1789028800000 store-token
  _box_account_write "$CN" work
  local staged="$CLEAT_RUN_DIR/$CN/auth/.credentials.json"
  mkdir -p "${staged%/*}"
  printf '{%s,"claudeAiOauth":{"accessToken":"a-token","refreshToken":"box-login","expiresAt":1789025200000}}\n' \
    "$(_mcp_member own)" > "$staged"
  cp "$staged" "$TEST_TEMP/staged.orig"
  run _account_sync_in "$CN"
  assert_success
  run grep -rl "box-login" "$CLEAT_ACCOUNTS_DIR/.held"
  assert_success
  assert_equal "${#lines[@]}" 1
  run cmp "${lines[0]}" "$TEST_TEMP/staged.orig"
  assert_success
  # The box has the store's login now, and its own MCP login is still there.
  run cat "$staged"
  assert_output --partial "store-token"
  assert_output --partial "MCP-own"
}

@test "account: a harvest never writes a store without the login it read" {
  # Every reader finds claudeAiOauth at any depth. The store keeps top-level
  # keys only. A login the box nested one level down passed every check as the
  # same grant refreshed and would have been written as {}.
  _mk_account work 1789003600000 grant
  _box_account_write "$CN" work
  mkdir -p "$CLEAT_RUN_DIR/$CN/auth"
  printf '{"wrapper":{"claudeAiOauth":{"accessToken":"nested","refreshToken":"grant","expiresAt":1789007200000}}}\n' \
    > "$CLEAT_RUN_DIR/$CN/auth/.credentials.json"
  run _account_sync_out "$CN"
  assert_failure
  run cat "$CLEAT_ACCOUNTS_DIR/work/.credentials.json"
  assert_output --partial '"refreshToken":"grant","expiresAt":1789003600000'
  refute_output --partial "nested"
  # The file stays for the next session end, as for any refused harvest.
  run test -f "$CLEAT_RUN_DIR/$CN/auth/.credentials.json"
  assert_success
}

# ── where a login made outside `cleat run` ends up ───────────────────────────

@test "account: a login made in cleat shell on a pinned box is harvested when the shell exits" {
  # `cleat shell` is a place people run `claude`, so it is a place people run
  # `/login`. It never harvested, so the new login stayed in the box until some
  # later session end happened to pick it up, and the next attach's staging
  # deleted it first.
  mkdir -p "$TEST_TEMP/project"
  local cn staged
  cn="$(container_name_for "$TEST_TEMP/project")"
  staged="$CLEAT_RUN_DIR/$cn/auth/.credentials.json"
  _mk_account work 1000 old-token
  printf 'uuid\t%s\nwho\twork@example.com\n' "$UUID_WORK" > "$CLEAT_ACCOUNTS_DIR/work/meta"
  _box_account_write "$cn" work
  _profile_says "$UUID_WORK" work@example.com
  mock_docker_ps "$cn"
  _host_open_cmd() { echo ""; }
  _daemon_up() { return 0; }
  container_exists() { return 0; }
  docker() {
    case "$1" in
      inspect) printf '%s\n' "/home/coder/.cleat-auth" ;;
      exec)
        # What a `/login` inside the shell leaves in the relocated store.
        if [[ "$*" == *"-- bash" ]]; then
          mkdir -p "${staged%/*}"
          _cred_blob 1789003600000 shell-login-token > "$staged"
        fi
        command docker "$@" ;;
      *) command docker "$@" ;;
    esac
  }
  run cmd_shell "$TEST_TEMP/project"
  assert_success
  run grep -c shell-login-token "$CLEAT_ACCOUNTS_DIR/work/.credentials.json"
  assert_output "1"
}

@test "account: a box with no account mount names its own box in the recreate hint" {
  # A bare `cleat rm` removes main. On any named box the old hint sent the user
  # to remove a different box than the one that needs recreating.
  _mk_account work
  _box_account_write "cleat-proj-deadbeef" work
  _daemon_up() { return 0; }
  container_exists() { return 0; }
  # A mount table with no /home/coder/.cleat-auth in it.
  docker() { case "$1" in inspect) printf '/workspace\n' ;; *) command docker "$@" ;; esac; }
  _BOX=dev
  CLAUDE_ENV=()
  run _account_apply_exec_env "cleat-proj-deadbeef"
  assert_failure
  assert_output --regexp 'Box .*dev.* \(cleat-proj-deadbeef\) has no account mount'
  assert_output --partial "cleat rm dev"
}

# A pinned, running box whose `claude auth login` exec writes WHAT into the
# relocated store. $1 = the credential blob, or empty to write nothing.
_login_box() {
  mkdir -p "$TEST_TEMP/project"
  _LB_CN="$(container_name_for "$TEST_TEMP/project")"
  _LB_BLOB="$1"
  _LB_STAGED="$CLEAT_RUN_DIR/$_LB_CN/auth/.credentials.json"
  mock_docker_ps "$_LB_CN"
  _host_open_cmd() { echo ""; }
  _daemon_up() { return 0; }
  container_exists() { return 0; }
  docker() {
    case "$1" in
      inspect) printf '%s\n' "/home/coder/.cleat-auth" ;;
      exec)
        if [[ -n "$_LB_BLOB" && "$*" == *"-- claude auth login" ]]; then
          mkdir -p "${_LB_STAGED%/*}"
          printf '%s\n' "$_LB_BLOB" > "$_LB_STAGED"
        fi
        command docker "$@" ;;
      *) command docker "$@" ;;
    esac
  }
}

@test "account: cleat login says so when the browser signed in as another account" {
  # The browser is usually signed into the primary account, so `cleat login` on
  # a box pinned to a second one is the easiest way to authorize as the wrong
  # person. The harvest holds that login. Saying nothing would leave the user
  # believing the account now has a login it does not have.
  _mk_account work 1000 old-token
  printf 'uuid\t%s\nwho\twork@example.com\n' "$UUID_WORK" > "$CLEAT_ACCOUNTS_DIR/work/meta"
  _login_box "$(_cred_blob 1789003600000 other-grant)"
  _box_account_write "$_LB_CN" work
  _profile_says "$UUID_OTHER" other@example.com
  run cmd_login "$TEST_TEMP/project"
  assert_success
  assert_output --partial "You signed in as another account, so it was not saved to"
  assert_output --partial "other@example.com"
  assert_output --partial "cleat account adopt"
  refute_output --partial "Auth saved"
  run grep -c old-token "$CLEAT_ACCOUNTS_DIR/work/.credentials.json"
  assert_output "1"
}

@test "account: cleat login says so when the harvest could not take the account lock" {
  # A busy lock writes nothing. The login is in the box and the next session end
  # saves it, so the line has to say that rather than claim or deny a save.
  _mk_account work 1000 old-token
  _login_box ""
  _box_account_write "$_LB_CN" work
  _account_sync_out() { return "$_ACCOUNT_LOCK_BUSY"; }
  run cmd_login "$TEST_TEMP/project"
  assert_success
  assert_output --partial "another cleat command is changing accounts"
  assert_output --partial "saved when the next session ends"
  refute_output --partial "Auth saved"
}

# An accounts directory that cannot take the lock at all (a sudo run left it
# root-owned, a read-only mount, a full disk) was reported at three sites as
# another cleat command changing accounts, with a promise of a later save that
# can never happen. The failure is simulated the way EACCES, EROFS and ENOSPC
# look to the lock: mkdir fails and leaves nothing at the path.
_unwritable_lock() {
  local lock; lock="$(_account_lock_path)"
  eval "mkdir() { [[ \"\$1\" == '$lock' ]] && return 1; command mkdir \"\$@\"; }"
}

@test "account: cleat login names an unwritable accounts directory, not another command" {
  _mk_account work 1000 old-token
  _login_box ""
  _box_account_write "$_LB_CN" work
  _account_sync_out() { _ACCOUNT_LOCK_UNWRITABLE=1; return "$_ACCOUNT_LOCK_BUSY"; }
  run cmd_login "$TEST_TEMP/project"
  assert_success
  assert_output --partial "Cleat cannot write to the accounts directory"
  assert_output --partial "Check that $CLEAT_ACCOUNTS_DIR is writable."
  refute_output --partial "another cleat command"
  refute_output --partial "saved when the next session ends"
}

@test "account: an attach names an unwritable accounts directory, not another command" {
  _mk_account work
  _box_account_write "$CN" work
  _account_box_ready() { return 0; }
  _unwritable_lock
  CLAUDE_ENV=()
  run _account_apply_exec_env "$CN"
  assert_success
  assert_output --partial "Cleat cannot write to the accounts directory"
  assert_output --partial "Check that $CLEAT_ACCOUNTS_DIR is writable."
  refute_output --partial "Another cleat command"
}

@test "account: a run-dir wipe names an unwritable accounts directory, not another command" {
  _mk_account work
  _box_account_write "$CN" work
  _mk_staged "$CN"
  _unwritable_lock
  run _account_wipe_run_dir "$CN"
  assert_success
  assert_output --partial "Cleat cannot write to the accounts directory"
  assert_output --partial "Check that $CLEAT_ACCOUNTS_DIR is writable."
  refute_output --partial "another cleat command"
  run test -f "$CLEAT_RUN_DIR/$CN/auth/.credentials.json"
  assert_success
}

@test "account rm refuses while a pinned box is reopening a session" {
  # A box mid-handoff still has a ticket its own terminal will consume to reopen
  # the conversation on this account. Removing the account now would unpin it out
  # from under that reopen, so rm refuses and changes nothing.
  _mk_account work
  _box_account_write "$CN" work
  local sid="d7b73579-1111-2222-3333-444455556666"
  _handoff_ticket_write "$CN" "deadbeef1234cafe" requested "$sid" work
  run _account_do_remove work 1
  assert_failure
  assert_output --partial "is still reopening a session from an earlier switch"
  [ -d "$CLEAT_ACCOUNTS_DIR/work" ] || fail "the account was removed while a box was reopening"
}

@test "account rm refuses while a pinned box has a cleat shell open" {
  # The unpin is a move from an account to the shared login, which the switch
  # refuses with a cleat shell open (a claude started there keeps the login the
  # shell opened with). rm unpinned the box anyway.
  _pass_gates
  _mk_account work
  _box_account_write "$CN" work
  mkdir -p "$CLEAT_RUN_DIR/$CN"
  printf 'kind=shell\n' > "$CLEAT_RUN_DIR/$CN/.attached.$$"
  run _account_do_remove work 1
  assert_failure
  assert_output --partial "has a cleat shell open in another terminal"
  [ -d "$CLEAT_ACCOUNTS_DIR/work" ] || fail "the account was removed with a shell open"
  run _box_account_read "$CN"
  assert_output "work"
  run test -e "$CLEAT_ACCOUNTS_DIR/.lock"
  assert_failure
  # Once the shell has gone, the remove goes through.
  rm -f "$CLEAT_RUN_DIR/$CN/.attached.$$"
  run _account_do_remove work 1
  assert_success
}

# ── the live switch routing (M4) ────────────────────────────────────────────

@test "account: a running mounted box with a live session routes the switch to the live handoff" {
  _mk_account work
  _box_account_write "$CN" old; _mk_account old
  _daemon_up() { return 0; }
  container_exists() { return 0; }
  is_running() { return 0; }
  _box_has_live_agent() { return 0; }
  _account_box_ready() { return 0; }
  # The handoff itself is exercised in handoff.bats; here we prove the router
  # reaches it, with the flags passed through.
  _account_handoff() { echo "ROUTED $1 $2 $5 $6"; return 0; }
  run _account_do_switch work main "$CN" "$TEST_TEMP/proj" 1 1
  assert_success
  assert_output "ROUTED work main 1 1"
}

@test "account: a live box with no account mount is refused, never handed over" {
  _mk_account work
  _box_account_write "$CN" old; _mk_account old
  _daemon_up() { return 0; }
  container_exists() { return 0; }
  is_running() { return 0; }
  _box_has_live_agent() { return 0; }
  _account_box_ready() { return 1; }
  _account_handoff() { echo "SHOULD-NOT-ROUTE"; return 0; }
  run _account_do_switch work main "$CN" "$TEST_TEMP/proj" 0 0
  assert_failure
  assert_output --partial "has a live Claude session"
  refute_output --partial "SHOULD-NOT-ROUTE"
  run _box_account_read "$CN"; assert_output "old"
}

@test "account: a running mounted box with no live session keeps the offline switch" {
  _mk_account work
  _box_account_write "$CN" old; _mk_account old
  mkdir -p "$CLEAT_PROJECTS_DIR/$(_derive_project_session_key "$TEST_TEMP/proj" main)"
  _daemon_up() { return 0; }
  container_exists() { return 0; }
  is_running() { return 0; }
  _box_has_live_agent() { return 1; }
  _account_box_ready() { return 0; }
  _account_handoff() { echo "SHOULD-NOT-ROUTE"; return 0; }
  run _account_do_switch work main "$CN" "$TEST_TEMP/proj"
  assert_success
  refute_output --partial "SHOULD-NOT-ROUTE"
  assert_output --partial "is now on account"
  run _box_account_read "$CN"; assert_output "work"
}

@test "account: default unpin of a running mounted box with a live session routes to the handoff" {
  _box_account_write "$CN" old; _mk_account old
  _daemon_up() { return 0; }
  container_exists() { return 0; }
  is_running() { return 0; }
  _box_has_live_agent() { return 0; }
  _account_box_ready() { return 0; }
  _account_handoff() { echo "ROUTED $1 $2"; return 0; }
  run _account_do_switch default main "$CN" "$TEST_TEMP/proj" 0 1
  assert_success
  assert_output "ROUTED default main"
}

@test "account: a refused harvest at session end says the login was not saved" {
  # Silence read as saved. On a Mac before the inode fix every harvest refused,
  # the account kept saying "signed out" and nothing ever said why.
  _mk_account work
  _mk_staged "$CN"
  _box_account_write "$CN" work

  run _maybe_report_account_harvest_refused 1 "$CN"
  assert_success
  assert_output --partial "was not saved to"
  assert_output --partial "work"
  assert_output --partial "cleat account list"

  # A harvest that took, one held as another account's and one the server could
  # not vouch for right now each have their own line or their own silence.
  for _rc in 0 2 3 "$_ACCOUNT_LOCK_BUSY"; do
    run _maybe_report_account_harvest_refused "$_rc" "$CN"
    assert_success
    assert_output ""
  done

  # An unpinned box has no account to save to, so it stays quiet.
  _box_account_write "$CN" "$_ACCOUNT_DEFAULT"
  run _maybe_report_account_harvest_refused 1 "$CN"
  assert_output ""

  # So does a pinned box with nothing staged to save.
  _box_account_write "$CN" work
  rm -f "$CLEAT_RUN_DIR/$CN/auth/.credentials.json"
  run _maybe_report_account_harvest_refused 1 "$CN"
  assert_output ""
}

@test "account: an attach stamps the account as used" {
  # Only a switch stamped last_used, so an account a box ran on all day still
  # showed the hour of the last switch. A session that ended a minute ago read
  # "last used 22h ago" in the list.
  _mk_account work
  _box_account_write "$CN" work
  _account_meta_set work last_used 1000
  mkdir -p "$CLEAT_RUN_DIR/$CN/auth"
  _account_box_ready() { return 0; }
  _account_sync_in() { return 0; }
  date() { printf '1789400000\n'; }

  CLAUDE_ENV=()
  run _account_apply_exec_env "$CN"
  assert_success
  run _account_meta_get work last_used
  assert_output "1789400000"

  # A staging that did not take leaves it alone: the box keeps the login it
  # already has, which may be another account's.
  _account_meta_set work last_used 1000
  _account_sync_in() { return 1; }
  CLAUDE_ENV=()
  run _account_apply_exec_env "$CN"
  run _account_meta_get work last_used
  assert_output "1000"
  unset -f date
}

@test "account: an attach refuses a newer login that belongs to another account" {
  # "Newest wins" alone handed a pinned box to a stranger. A /login made inside
  # the box as someone else refreshes to an expiry hours past the store's, so
  # the attach kept it, said the pin had taken, and the session ran and billed
  # as the other account. Found on a real Mac, 2026-09-19.
  local staged="$CLEAT_RUN_DIR/$CN/auth/.credentials.json"
  _mk_account work 1789003600000 work-token
  _box_account_write "$CN" work
  mkdir -p "$CLEAT_RUN_DIR/$CN/auth"
  _cred_blob 1789999999000 stranger-token > "$staged"
  # The server says it is someone else.
  _account_meta_set work uuid 11111111-aaaa-4aaa-8aaa-aaaaaaaaaaaa
  _account_cred_identity() { printf '22222222-bbbb-4bbb-8bbb-bbbbbbbbbbbb\tother@example.com\tOther Org\n'; }

  run _account_sync_in "$CN"
  assert_success
  # The box now runs on the account it is pinned to.
  run cat "$staged"
  assert_output --partial "work-token"
  refute_output --partial "stranger-token"
  # And the stranger's login is kept, not destroyed.
  run bash -c 'grep -rl "stranger-token" "$1"/.held 2>/dev/null | head -1' _ "$CLEAT_ACCOUNTS_DIR"
  assert_success
  assert_output --partial ".held"
}

@test "account: an attach keeps a newer login the server says is this account" {
  # The common case the expiry rule exists for: the box refreshed this
  # account's own login and rotated its refresh token, so the bytes no longer
  # match the store. The box keeps it, and the store is brought up to date.
  local staged="$CLEAT_RUN_DIR/$CN/auth/.credentials.json"
  _mk_account work 1789003600000 work-token
  _box_account_write "$CN" work
  mkdir -p "$CLEAT_RUN_DIR/$CN/auth"
  _cred_blob 1789999999000 rotated-token > "$staged"
  _account_meta_set work uuid 11111111-aaaa-4aaa-8aaa-aaaaaaaaaaaa
  _account_cred_identity() { printf '11111111-aaaa-4aaa-8aaa-aaaaaaaaaaaa\tme@example.com\tMy Org\n'; }
  ln "$staged" "$TEST_TEMP/staged-keep.link"

  run _account_sync_in "$CN"
  assert_success
  run cat "$staged"
  assert_output --partial "rotated-token"
  # Same inode: the file a live session already has open is not rewritten
  # underneath it just to put back bytes it already holds.
  run test "$staged" -ef "$TEST_TEMP/staged-keep.link"
  assert_success
  # The store caught up, so a later attach has it too.
  run cat "$CLEAT_ACCOUNTS_DIR/work/.credentials.json"
  assert_output --partial "rotated-token"
}

@test "account: an attach that stages a different login flags the cached identity" {
  # Only the credential moved, so Claude kept showing the name it had cached in
  # the box's claude.json and kept sending that account's organisation. On a
  # real Mac /status named the account whose login had just been held while the
  # box ran on the pinned one. Found 2026-09-20.
  _mk_account work 1789003600000 work-token
  _box_account_write "$CN" work
  mkdir -p "$CLEAT_RUN_DIR/$CN/auth"
  _cred_blob 1789000100000 other-token > "$CLEAT_RUN_DIR/$CN/auth/.credentials.json"
  _RESOLVED_PROJECT="$TEST_TEMP/proj"
  local key f
  key="$(_derive_project_session_key "$_RESOLVED_PROJECT" main)"
  f="$CLEAT_PROJECTS_DIR/${key}/claude.json"
  mkdir -p "${f%/*}"
  printf '{"oauthAccount":{"emailAddress":"someone@example.com"}}\n' > "$f"
  _account_box_ready() { return 0; }

  CLAUDE_ENV=()
  run _account_apply_exec_env "$CN"
  assert_success
  run test -e "${f}.identity-stale"
  assert_success

  # The same login staged again is not an identity change, so nothing is
  # flagged and no launch spends work clearing what is already right.
  rm -f "${f}.identity-stale"
  CLAUDE_ENV=()
  run _account_apply_exec_env "$CN"
  assert_success
  run test -e "${f}.identity-stale"
  assert_failure
}

@test "account: an attach the server cannot vouch for keeps the login the box has" {
  # Claude rotates the refresh token on nearly every refresh, so staging the
  # store's copy over a login this box refreshed rolls it back to a grant that
  # is already spent. With the identity check unable to answer (offline, a slow
  # reply past the 3s bound, a 401) that happened on EVERY attach.
  local staged="$CLEAT_RUN_DIR/$CN/auth/.credentials.json"
  _mk_account work 1789003600000 work-token
  _box_account_write "$CN" work
  mkdir -p "$CLEAT_RUN_DIR/$CN/auth"
  _cred_blob 1789999999000 rotated-token > "$staged"
  ln "$staged" "$TEST_TEMP/offline.link"
  # The server cannot say whose login this is.
  _account_cred_identity() { return 3; }

  run _account_sync_in "$CN"
  assert_success
  run cat "$staged"
  assert_output --partial "rotated-token"
  refute_output --partial "work-token"
  # Not rewritten either: a live session holds that file open.
  run test "$staged" -ef "$TEST_TEMP/offline.link"
  assert_success
  # And nothing was quarantined for a question the server never answered.
  run bash -c 'ls -A "$1"/.held 2>/dev/null | wc -l | tr -d " "' _ "$CLEAT_ACCOUNTS_DIR"
  assert_output "0"
}

@test "account: an attach says so when the account could not be staged" {
  # Silent before: the summary printed an Account row naming the pin while the
  # box ran the session on whatever login it already had.
  _mk_account work
  _box_account_write "$CN" work
  _account_box_ready() { return 0; }
  _account_sync_in() { return 1; }
  _ACCOUNT_STAGE_UNKEPT=0
  CLAUDE_ENV=()
  run _account_apply_exec_env "$CN"
  assert_output --partial "starts with the login it already has"
  assert_output --partial "work"

  # The two failures that already had their own line keep it, and a staging
  # that took stays quiet.
  _account_sync_in() { return 0; }
  CLAUDE_ENV=()
  run _account_apply_exec_env "$CN"
  refute_output --partial "starts with the login it already has"
}

@test "account: a shell or a login flags the cached identity when it stages another login" {
  # Both verbs stage the pinned account into the box, so both can change which
  # login it holds. Neither set the resolved project, so the flag that tells
  # the next launch to drop Claude's cached identity was written nowhere and
  # the box kept naming the account it used to be on.
  _pass_gates
  is_running() { return 0; }
  container_exists() { return 0; }
  _mk_account work 1789003600000 work-token
  local proj="$TEST_TEMP/proj-shell"
  mkdir -p "$proj"
  local cn
  cn="$(container_name_for "$proj" main)"
  _box_account_write "$cn" work
  mkdir -p "$CLEAT_RUN_DIR/$cn/auth"
  _cred_blob 1789000100000 other-token > "$CLEAT_RUN_DIR/$cn/auth/.credentials.json"
  local key f
  key="$(_derive_project_session_key "$proj" main)"
  f="$CLEAT_PROJECTS_DIR/${key}/claude.json"
  mkdir -p "${f%/*}"
  printf '{"oauthAccount":{"emailAddress":"old@example.com"}}\n' > "$f"
  _account_box_ready() { return 0; }
  docker() { return 0; }

  run cmd_shell "$proj"
  run test -e "${f}.identity-stale"
  assert_success
}

@test "account: an oversized but real login is kept, never treated as junk" {
  # The size check ran first, so a real login in a file the box had grown past
  # the cap answered "junk" and every deleter destroyed it with no held copy.
  local f="$TEST_TEMP/big.json"
  {
    printf '{"claudeAiOauth":{"accessToken":"a-token","refreshToken":"r-token","expiresAt":1789003600000},"junk":"'
    head -c 70000 /dev/zero | tr '\0' 'x'
    printf '"}\n'
  } > "$f"
  run _account_keepable_snapshot "$f"
  # 2, not 1: cannot copy it, so keep it where it is.
  assert_equal "$status" 2

  # Junk of any size is still junk.
  printf '{"not":"a login"}\n' > "$TEST_TEMP/junk.json"
  run _account_keepable_snapshot "$TEST_TEMP/junk.json"
  assert_equal "$status" 1
}

@test "account: a deferred identity drop leaves something for the next launch" {
  # A live Claude holds claude.json open, so the drop waits. cleat account rm
  # swallows that status, so with no flag the removed account's email stayed in
  # the box forever.
  local key f
  key="$(_derive_project_session_key "$TEST_TEMP/idproj" main)"
  f="$CLEAT_PROJECTS_DIR/${key}/claude.json"
  mkdir -p "${f%/*}"
  printf '{"oauthAccount":{"emailAddress":"gone@example.com"}}\n' > "$f"
  _box_claude_live() { return 0; }

  run _account_invalidate_identity_key "$key" "$CN"
  assert_equal "$status" 3
  run test -e "${f}.identity-stale"
  assert_success

  # With no live session the drop happens and the flag is cleared.
  _box_claude_live() { return 1; }
  run _account_invalidate_identity_key "$key" "$CN"
  assert_success
  run test -e "${f}.identity-stale"
  assert_failure
}

@test "account: the reset clock ignores a file named like the epoch" {
  # `date -r` is an epoch on BSD and a FILE on GNU, and the fallback only fires
  # when the first form printed nothing. In a directory holding a file whose
  # name is that epoch, GNU date printed that file's mtime and exited 0, so the
  # picker showed an arbitrary time as the reset instant. cleat is normally run
  # from the project root, which the box mounts read-write.
  local e=1789900000
  local truth
  truth="$(date -r "$e" +%H:%M 2>/dev/null || date -d "@$e" +%H:%M 2>/dev/null)"
  cd "$TEST_TEMP"
  touch -t 202001010101 "$e"

  run _account_clock "$e"
  assert_success
  assert_output "$truth"
  refute_output "01:01"
}
