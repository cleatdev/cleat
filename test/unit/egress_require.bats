#!/usr/bin/env bats
# The egress gate (EGRESS-SPEC.md 5.5 to 5.7): _egress_require, the create-time
# hash, the live-policy check, the box and gateway assertions and the
# capability interlocks. Stage two ships the gate with _EGRESS_ENFORCING at 0,
# so this file sets it to 1 after source_cli: every assertion runs live here,
# before a gateway exists to hide behind. One test runs the stage-two value.
load "../setup"

setup() {
  _common_setup
  use_docker_stub
  source_cli
  _EGRESS_ENFORCING=1
  _daemon_up() { return 0; }
  _egress_engine_kind() { printf 'desktop-macos'; }
  _host_clip_cmd() { echo ""; }
  CN="cleat-demo-3f2a9104"
  _BOX=main
  ACTIVE_CAPS=()
  mkdir -p "$(dirname "$CLEAT_GLOBAL_CONFIG")"
  printf '[egress]\nmode = strict\n' > "$CLEAT_GLOBAL_CONFIG"
  BH="$(_egress_box_hash "$CN")"
  GW="cleat-gw-$BH"
  VOL="cleat-gw-$BH-sock"
  # The gateway's admin answers, one file per verb, a sequence whose last line
  # repeats, the way the inspect fixtures behave.
  mkdir -p "$DOCKER_MOCK_DIR/gwadmin"
  cat > "$TEST_TEMP/gwexec.sh" <<'SH'
#!/usr/bin/env bash
shift
if [ "$1" = -u ]; then shift 2; fi
shift
[ "${1:-}" = /usr/local/bin/gw-admin ] || exit 0
f="$DOCKER_MOCK_DIR/gwadmin/$2"
[ -f "$f" ] || exit 2
n=0; [ -f "$f.seq" ] && n=$(cat "$f.seq")
line=$(sed -n "$((n + 1))p" "$f")
[ -n "$line" ] || line=$(tail -n 1 "$f")
echo $((n + 1)) > "$f.seq"
printf '%s\n' "$line"
SH
  chmod +x "$TEST_TEMP/gwexec.sh"
  export DOCKER_STUB_EXEC_SCRIPT="$TEST_TEMP/gwexec.sh"
}
teardown() { _common_teardown; }

# The templates the gate reads, verbatim. A fixture keyed on any other
# template is an undeclared format, which the stub refuses.
T_HASH='{{range $k, $v := .Config.Labels}}{{if eq $k "sh.cleat.egress-hash"}}LABEL={{$v}}{{end}}{{end}}'
T_ENGINE='{{range $k, $v := .Config.Labels}}{{if eq $k "sh.cleat.egress-engine"}}LABEL={{$v}}{{end}}{{end}}'
T_NETMODE='{{.HostConfig.NetworkMode}}'
T_NETS='{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}'
T_CAPADD='{{json .HostConfig.CapAdd}}'
T_CAPDROP='{{json .HostConfig.CapDrop}}'
T_EXTRA='{{json .HostConfig.ExtraHosts}}'
T_NS='{{.HostConfig.PidMode}}|{{.HostConfig.UsernsMode}}|{{.HostConfig.IpcMode}}'
T_DEV='{{json .HostConfig.Devices}}'
T_SEC='{{json .HostConfig.SecurityOpt}}'
T_PRIV='{{.HostConfig.Privileged}}'
T_SOCK='{{range .Mounts}}{{if eq .Destination "/run/cleat-egress"}}{{.Type}} {{.Name}} {{.RW}}{{end}}{{end}}'
T_DSOCK='{{range .Mounts}}{{if eq .Destination "/var/run/docker.sock"}}FOUND{{end}}{{end}}'
T_DESTS='{{range .Mounts}}{{.Destination}}{{"\n"}}{{end}}'
T_NAMES='{{range .Mounts}}{{.Name}}{{"\n"}}{{end}}'
T_ENV='{{range .Config.Env}}{{println .}}{{end}}'
T_VOL='{{index .Labels "sh.cleat.role"}} {{index .Labels "sh.cleat.gateway-for"}}'
T_GW='{{.State.Running}}|{{index .Config.Labels "sh.cleat.role"}}|{{index .Config.Labels "sh.cleat.gateway-for"}}'
T_HEALTH='{{.State.Health.Status}}'

# A caged box and its gateway that pass every assertion. Each F_ variable is
# one field: a test sets one before calling this to break exactly that field.
caged_box() {
  local cd digest
  cd="$(_egress_capdrop_canon "$_EGRESS_BOX_CAPDROP")"
  digest="$(_egress_create_digest "$CN" none "$cd" "${F_HOOKS:-0}")"
  mock_docker_inspect_field "$CN" "$T_HASH" "${F_HASH-LABEL=$digest}"
  mock_docker_inspect_field "$CN" "$T_ENGINE" "${F_ENGINE-LABEL=desktop-macos}"
  mock_docker_inspect_field "$CN" "$T_NETMODE" "${F_NETMODE-none}"
  mock_docker_inspect_field "$CN" "$T_NETS" "${F_NETS-none }"
  mock_docker_inspect_field "$CN" "$T_CAPADD" "${F_CAPADD-null}"
  mock_docker_inspect_field "$CN" "$T_CAPDROP" "${F_CAPDROP-[\"CAP_NET_RAW\"]}"
  mock_docker_inspect_field "$CN" "$T_EXTRA" "${F_EXTRA-null}"
  mock_docker_inspect_field "$CN" "$T_NS" "${F_NS-||private}"
  mock_docker_inspect_field "$CN" "$T_DEV" "${F_DEV-[]}"
  mock_docker_inspect_field "$CN" "$T_SEC" "${F_SEC-[\"label=disable\"]}"
  mock_docker_inspect_field "$CN" "$T_PRIV" "${F_PRIV-false}"
  mock_docker_inspect_field "$CN" "$T_SOCK" "${F_SOCK-volume $VOL false}"
  mock_docker_inspect_field "$CN" "$T_DSOCK" "${F_DSOCK-}"
  mock_docker_inspect_field "$CN" "$T_DESTS" "${F_DESTS-/workspace\n/home/coder/.claude\n/run/cleat-egress}"
  mock_docker_inspect_field "$CN" "$T_NAMES" "${F_NAMES-\n\n$VOL}"
  mock_docker_inspect_field "$CN" "$T_ENV" "${F_ENV-HOME=/home/coder\nHOST_UID=501\nHOST_GID=20}"
  mock_docker_volume_inspect_field "$VOL" "$T_VOL" "${F_VOL-egress-sock $BH}"
  mock_docker_inspect_field "$GW" "$T_GW" "${F_GW-true|gateway|$BH}"
  if [ -n "${F_HEALTH_SEQ:-}" ]; then
    local h
    for h in $F_HEALTH_SEQ; do mock_docker_inspect_field "$GW" "$T_HEALTH" "$h"; done
  else
    mock_docker_inspect_field "$GW" "$T_HEALTH" healthy
  fi
  echo "${F_PATHOK-ok path_ok true}" > "$DOCKER_MOCK_DIR/gwadmin/path_ok"
  echo "${F_SELFTEST-ok selftest cleat-egress-ok}" > "$DOCKER_MOCK_DIR/gwadmin/selftest"
  echo "ok reload ignored" > "$DOCKER_MOCK_DIR/gwadmin/reload"
  if [ -n "${F_DIGEST_SEQ:-}" ]; then
    printf '%s\n' $F_DIGEST_SEQ | sed 's/^/ok policy-digest /' > "$DOCKER_MOCK_DIR/gwadmin/policy-digest"
  else
    _egress_resolve "$CN"
    echo "ok policy-digest $(_egress_policy_digest "$_EG_MODE" "$_EG_HOSTS")" > "$DOCKER_MOCK_DIR/gwadmin/policy-digest"
  fi
}

# The digest of the policy the global config resolves to right now.
current_digest() {
  _egress_resolve "$CN"
  _egress_policy_digest "$_EG_MODE" "$_EG_HOSTS"
}

# How many times the stub recorded a docker call carrying this text.
count_calls() { grep -cF -- "$1" "$DOCKER_CALLS" || true; }

# ── Stage two, the daemon and the off path ──────────────────────────────────

@test "egress require: a saved policy does not refuse a launch before enforcement ships" {
  _EGRESS_ENFORCING=0
  mkdir -p "$DOCKER_MOCK_DIR/inspect"
  run _egress_require "$CN" start
  assert_success
  assert_output ""
  run count_calls "docker inspect"
  assert_output "0"
}

@test "egress require: no policy and no label passes silently" {
  rm -f "$CLEAT_GLOBAL_CONFIG"
  mock_docker_inspect_field "$CN" "$T_HASH" ""
  run _egress_require "$CN" start
  assert_success
  assert_output ""
  run count_calls "$T_NETMODE"
  assert_output "0"
}

@test "egress require: a removed policy on a policy box refuses" {
  rm -f "$CLEAT_GLOBAL_CONFIG"
  mock_docker_inspect_field "$CN" "$T_HASH" "LABEL=v1:0123456789abcdef"
  run _egress_require "$CN" start
  assert_failure
  assert_output --partial "Egress refused box"
  assert_output --partial "created under an egress policy that no longer resolves"
  assert_output --partial "cleat egress off"
}

@test "egress require: a box with egress mode off and the label refuses like a removed policy" {
  printf '[egress]\nmode = off\n' > "$CLEAT_GLOBAL_CONFIG"
  mock_docker_inspect_field "$CN" "$T_HASH" "LABEL=v1:0123456789abcdef"
  run _egress_require "$CN" start
  assert_failure
  assert_output --partial "no longer resolves"
}

@test "egress require: an unreadable label with no policy does not refuse" {
  rm -f "$CLEAT_GLOBAL_CONFIG"
  mkdir -p "$DOCKER_MOCK_DIR/inspect"
  run _egress_require "$CN" start
  assert_success
  assert_output ""
}

@test "egress require: a reply that is not a label answer never reads as a label" {
  rm -f "$CLEAT_GLOBAL_CONFIG"
  mock_docker_inspect "true"
  run _egress_require "$CN" start
  assert_success
  assert_output ""
}

@test "egress require: a down daemon produces the daemon error, not an egress refusal" {
  _daemon_up() { return 1; }
  _egress_engine_kind() { echo "engine probed" >> "$TEST_TEMP/probed"; printf 'vm-backend'; }
  mkdir -p "$DOCKER_MOCK_DIR/inspect"
  run _egress_require "$CN" login
  assert_success
  assert_output ""
  run count_calls "docker inspect"
  assert_output "0"
  [ ! -e "$TEST_TEMP/probed" ]
}

# ── A healthy caged box ─────────────────────────────────────────────────────

@test "egress require: a caged box that passes every assertion is allowed" {
  caged_box
  run _egress_require "$CN" start
  assert_success
  assert_output ""
  run count_calls "gw-admin reload"
  assert_output "0"
}

@test "egress require: the mounts reads are the range predicates" {
  caged_box
  run _egress_require "$CN" start
  assert_success
  run count_calls "$T_SOCK"
  assert_output "1"
  run count_calls "$T_DSOCK"
  assert_output "1"
  run count_calls "$T_DESTS"
  assert_output "1"
  run count_calls "$T_NAMES"
  assert_output "1"
}

# ── One test per assertion ──────────────────────────────────────────────────

@test "egress require: a network mode other than none refuses" {
  F_NETMODE=bridge caged_box
  run _egress_require "$CN" start
  assert_failure
  assert_output --partial "network mode is not none"
}

@test "egress require: NetworkMode none with a second network in Networks refuses" {
  F_NETS="none bridge " caged_box
  run _egress_require "$CN" start
  assert_failure
  assert_output --partial "attached to a network other than none"
}

@test "egress require: a non-empty CapAdd refuses" {
  F_CAPADD='["NET_RAW"]' caged_box
  run _egress_require "$CN" start
  assert_failure
  assert_output --partial "added capabilities"
}

@test "egress require: a missing CAP_NET_RAW refuses" {
  F_CAPDROP='["CAP_CHOWN"]' caged_box
  run _egress_require "$CN" start
  assert_failure
  assert_output --partial "does not drop NET_RAW"
  rm -rf "$DOCKER_MOCK_DIR/inspect" "$DOCKER_MOCK_DIR/volume_inspect"
  F_CAPDROP=null caged_box
  run _egress_require "$CN" start
  assert_failure
  assert_output --partial "does not drop NET_RAW"
}

@test "egress require: a capability whose name only contains ALL does not pass as ALL" {
  F_CAPDROP='["CAP_SYSLOG_ALLX"]' caged_box
  run _egress_require "$CN" start
  assert_failure
  assert_output --partial "does not drop NET_RAW"
}

@test "egress require: the literal ALL passes" {
  F_CAPDROP='["ALL"]' caged_box
  run _egress_require "$CN" start
  assert_success
}

@test "egress require: a non-empty ExtraHosts refuses" {
  F_EXTRA='["host.docker.internal:host-gateway"]' caged_box
  run _egress_require "$CN" start
  assert_failure
  assert_output --partial "extra host entries"
}

@test "egress require: IpcMode private passes and IpcMode host refuses" {
  F_NS='||shareable' caged_box
  run _egress_require "$CN" start
  assert_success
  local ns
  for ns in '||host' 'host||private' '|host|private'; do
    rm -rf "$DOCKER_MOCK_DIR/inspect" "$DOCKER_MOCK_DIR/volume_inspect"
    F_NS="$ns" caged_box
    run _egress_require "$CN" start
    assert_failure
    assert_output --partial "shares a host namespace"
  done
}

@test "egress require: a mapped host device refuses" {
  F_DEV='[{"PathOnHost":"/dev/net/tun"}]' caged_box
  run _egress_require "$CN" start
  assert_failure
  assert_output --partial "host devices"
}

@test "egress require: seccomp unconfined refuses" {
  F_SEC='["seccomp=unconfined","label=disable"]' caged_box
  run _egress_require "$CN" start
  assert_failure
  assert_output --partial "unconfined"
}

@test "egress require: an unreadable security profile refuses" {
  caged_box
  sed -i.bak "/HostConfig.SecurityOpt/d" "$DOCKER_MOCK_DIR/inspect/$CN" && rm -f "$DOCKER_MOCK_DIR/inspect/$CN.bak"
  run _egress_require "$CN" start
  assert_failure
  assert_output --partial "unconfined"
}

@test "egress require: a privileged box refuses" {
  F_PRIV=true caged_box
  run _egress_require "$CN" start
  assert_failure
  assert_output --partial "privileged"
}

@test "egress require: an unlabelled auto-created socket volume refuses" {
  F_VOL=" " caged_box
  run _egress_require "$CN" start
  assert_failure
  assert_output --partial "socket volume is not the one cleat labelled"
  assert_output --partial "This is not a policy denial."
}

@test "egress require: a socket volume labelled for another box refuses" {
  F_VOL="egress-sock 000000000000" caged_box
  run _egress_require "$CN" start
  assert_failure
  assert_output --partial "socket volume is not the one cleat labelled"
}

@test "egress require: a read-write socket mount refuses" {
  F_SOCK="volume $VOL true" caged_box
  run _egress_require "$CN" start
  assert_failure
  assert_output --partial "egress socket is not the read-only volume"
}

@test "egress require: a socket mount of another volume name refuses" {
  F_SOCK="volume cleat-gw-000000000000-sock false" caged_box
  run _egress_require "$CN" start
  assert_failure
  assert_output --partial "egress socket is not the read-only volume"
}

@test "egress require: a docker socket mount refuses" {
  F_DSOCK=FOUND caged_box
  run _egress_require "$CN" start
  assert_failure
  assert_output --partial "Docker socket is mounted"
}

@test "egress require: no box mount lands on the gateway policy directory" {
  local d
  for d in '/workspace\n/run/cleat-egress\n/etc/cleat-egress' '/workspace\n/run/cleat-egress\n/etc/cleat-egress/policy.json'; do
    rm -rf "$DOCKER_MOCK_DIR/inspect" "$DOCKER_MOCK_DIR/volume_inspect"
    F_DESTS="$d" caged_box
    run _egress_require "$CN" start
    assert_failure
    assert_output --partial "reaches the gateway's policy"
  done
  rm -rf "$DOCKER_MOCK_DIR/inspect" "$DOCKER_MOCK_DIR/volume_inspect"
  F_NAMES="\n$VOL\ncleat-gw-$BH-policy" caged_box
  run _egress_require "$CN" start
  assert_failure
  assert_output --partial "reaches the gateway's policy"
  # A destination that only shares the prefix is not under the directory.
  rm -rf "$DOCKER_MOCK_DIR/inspect" "$DOCKER_MOCK_DIR/volume_inspect"
  F_DESTS='/workspace\n/run/cleat-egress\n/etc/cleat-egress-notes' caged_box
  run _egress_require "$CN" start
  assert_success
}

@test "egress require: a box created on another engine refuses" {
  F_ENGINE="LABEL=engine-linux" caged_box
  run _egress_require "$CN" start
  assert_failure
  assert_output --partial "created on another Docker engine"
}

# ── The create-time hash (5.5, 5.6 check one) ───────────────────────────────

@test "egress require: a box that predates its policy refuses" {
  F_HASH="" caged_box
  run _egress_require "$CN" start
  assert_failure
  assert_output --partial "created before its egress policy"
  assert_output --partial "cleat rm && cleat"
}

@test "egress require: a hash in another format version refuses" {
  F_HASH="LABEL=v9:0123456789abcdef" caged_box
  run _egress_require "$CN" start
  assert_failure
  assert_output --partial "in another format"
}

@test "egress require: a changed create-time fact refuses" {
  F_HASH="LABEL=v1:0123456789abcdef" caged_box
  run _egress_require "$CN" start
  assert_failure
  assert_output --partial "a create-time fact changed"
  refute_output --partial "CLEAT_EGRESS_ALLOW_HOOKS"
}

@test "egress require: the drift refusal is identical on a non-TTY" {
  F_HASH="" caged_box
  run _egress_require "$CN" start
  local plain="$output" plain_rc="$status"
  rm -rf "$DOCKER_MOCK_DIR/inspect" "$DOCKER_MOCK_DIR/volume_inspect"
  F_HASH="" caged_box
  _is_tty() { return 0; }
  _is_interactive() { return 0; }
  run _egress_require "$CN" start
  [ "$status" -eq "$plain_rc" ]
  [ "$status" -eq 1 ]
  [ "$output" = "$plain" ]
}

@test "egress require: a launch that drops the hooks escape a box was created with names the flag" {
  ACTIVE_CAPS=(hooks)
  F_HOOKS=1 CLEAT_EGRESS_ALLOW_HOOKS=1 caged_box
  run _egress_require "$CN" start
  assert_failure
  assert_output --partial "the hooks capability runs host commands"
  # With the flag on this launch too, the box passes.
  export CLEAT_EGRESS_ALLOW_HOOKS=1
  run _egress_require "$CN" start
  assert_success
  # A box created without the escape, launched with it, names the flag.
  rm -rf "$DOCKER_MOCK_DIR/inspect" "$DOCKER_MOCK_DIR/volume_inspect" "$DOCKER_MOCK_DIR/gwadmin"/*
  unset CLEAT_EGRESS_ALLOW_HOOKS
  F_HOOKS=0 caged_box
  export CLEAT_EGRESS_ALLOW_HOOKS=1
  run _egress_require "$CN" start
  assert_failure
  assert_output --partial "created without CLEAT_EGRESS_ALLOW_HOOKS=1"
}

@test "egress require: the hooks flag in the environment does not move the hash of a box without the hooks capability" {
  local a b
  ACTIVE_CAPS=(git)
  a="$(_egress_create_digest "$CN" none CAP_NET_RAW "$(_egress_hooks_fact)")"
  b="$(CLEAT_EGRESS_ALLOW_HOOKS=1 _egress_create_digest "$CN" none CAP_NET_RAW "$(CLEAT_EGRESS_ALLOW_HOOKS=1 _egress_hooks_fact)")"
  [ "$a" = "$b" ]
  run env CLEAT_EGRESS_ALLOW_HOOKS=1 bash -c 'true'
  ACTIVE_CAPS=(hooks)
  CLEAT_EGRESS_ALLOW_HOOKS=1
  run _egress_hooks_fact
  assert_output "1"
  unset CLEAT_EGRESS_ALLOW_HOOKS
  run _egress_hooks_fact
  assert_output "0"
}

@test "egress require: a box created with the flag but without the hooks capability is not claim void" {
  ACTIVE_CAPS=()
  local cd digest
  cd="$(_egress_capdrop_canon "$_EGRESS_BOX_CAPDROP")"
  digest="$(CLEAT_EGRESS_ALLOW_HOOKS=1 _egress_create_digest "$CN" none "$cd" "$(CLEAT_EGRESS_ALLOW_HOOKS=1 _egress_hooks_fact)")"
  mock_docker_inspect_field "$CN" "$T_HASH" "LABEL=$digest"
  run _egress_claim_void "$CN"
  assert_output "clear"
  rm -rf "$DOCKER_MOCK_DIR/inspect"
  mock_docker_inspect_field "$CN" "$T_HASH" "LABEL=$(_egress_create_digest "$CN" none "$cd" 1)"
  run _egress_claim_void "$CN"
  assert_output "void"
  rm -rf "$DOCKER_MOCK_DIR/inspect"
  mock_docker_inspect_field "$CN" "$T_HASH" "LABEL=v1:ffffffffffffffff"
  run _egress_claim_void "$CN"
  assert_output "unknown"
  rm -rf "$DOCKER_MOCK_DIR/inspect"
  mock_docker_inspect_field "$CN" "$T_HASH" ""
  run _egress_claim_void "$CN"
  assert_output "clear"
}

@test "egress require: the sha256 helper prefers sha256sum, then shasum, then md5" {
  # A Mac without coreutils has shasum. One that installs coreutils later gets
  # sha256sum, which prints the same hex, so no caged box's hash moves.
  mkdir -p "$TEST_TEMP/shabin"
  printf '#!/usr/bin/env bash\necho "gnu-hex  -"\n' > "$TEST_TEMP/shabin/sha256sum"
  printf '#!/usr/bin/env bash\n[ "$1 $2" = "-a 256" ] || exit 2\necho "bsd-hex  -"\n' > "$TEST_TEMP/shabin/shasum"
  chmod +x "$TEST_TEMP/shabin/sha256sum" "$TEST_TEMP/shabin/shasum"
  PATH="$TEST_TEMP/shabin:$PATH"
  run _sha256 <<< "x"
  assert_output "gnu-hex  -"
  command() { if [ "$1 $2" = "-v sha256sum" ]; then return 1; fi; builtin command "$@"; }
  run _sha256 <<< "x"
  assert_output "bsd-hex  -"
  command() { case "$1 $2" in "-v sha256sum"|"-v shasum") return 1 ;; esac; builtin command "$@"; }
  run _sha256 <<< "x"
  assert_output "$(printf 'x\n' | _md5)"
  unset -f command
}

@test "egress require: cap-drop spelling does not change the hash" {
  local want s
  want="$(_egress_create_digest "$CN" none "$(_egress_capdrop_canon NET_RAW)" 0)"
  for s in net_raw CAP_NET_RAW cap_net_raw NeT_rAw; do
    [ "$(_egress_create_digest "$CN" none "$(_egress_capdrop_canon "$s")" 0)" = "$want" ]
  done
  run _egress_capdrop_canon all net_raw NET_RAW
  assert_output "ALL,CAP_NET_RAW"
}

@test "egress require: bumping the catalogue rev alone does not change the hash" {
  local a
  a="$(_egress_create_digest "$CN" none CAP_NET_RAW 0)"
  _EGRESS_CATALOGUE_REV=99
  [ "$(_egress_create_digest "$CN" none CAP_NET_RAW 0)" = "$a" ]
}

@test "egress fingerprint: the gateway digest is not in the create-time hash and the gateway spec version is" {
  local a
  a="$(_egress_create_digest "$CN" none CAP_NET_RAW 0)"
  # A rebuild for a base advisory moves the digest and must recreate no box.
  _GATEWAY_IMAGE="ghcr.io/cleatdev/cleat-gw@sha256:$(printf '%064d' 7)"
  [ "$(_egress_create_digest "$CN" none CAP_NET_RAW 0)" = "$a" ]
  _GATEWAY_SPEC_VERSION=$(( _GATEWAY_SPEC_VERSION + 1 ))
  [ "$(_egress_create_digest "$CN" none CAP_NET_RAW 0)" != "$a" ]
}

@test "egress require: the gateway spec version is in the create-time hash" {
  local a
  a="$(_egress_create_digest "$CN" none CAP_NET_RAW 0)"
  _GATEWAY_SPEC_VERSION=2
  [ "$(_egress_create_digest "$CN" none CAP_NET_RAW 0)" != "$a" ]
  run _egress_create_facts "$CN" none CAP_NET_RAW 0
  assert_output "egress:netmode=none
egress:capdrop=CAP_NET_RAW
egress:volume=$VOL
egress:gateway=2
egress:hooks=0"
  run _egress_create_digest "$CN" none CAP_NET_RAW 0
  assert_output --regexp '^v1:[0-9a-f]{16}$'
}

@test "egress require: a changed allowlist neither refuses nor asks for a recreate" {
  caged_box
  run _egress_require "$CN" start
  assert_success
  local before after
  before="$(current_digest)"
  printf '[egress]\nmode = strict\nallow = docs.rs\n' > "$CLEAT_GLOBAL_CONFIG"
  after="$(current_digest)"
  [ "$before" != "$after" ]
  printf 'ok policy-digest %s\nok policy-digest %s\n' "$before" "$after" > "$DOCKER_MOCK_DIR/gwadmin/policy-digest"
  rm -f "$DOCKER_MOCK_DIR/gwadmin/policy-digest.seq"
  run _egress_require "$CN" start
  assert_success
  assert_output ""
  run count_calls "gw-admin reload"
  assert_output "1"
}

# ── The live policy (5.6 check two, assertion 13) ───────────────────────────

@test "egress require: a live-digest mismatch reloads and proceeds" {
  local want
  want="$(current_digest)"
  F_DIGEST_SEQ="v1:0000000000000000 $want" caged_box
  run _egress_require "$CN" start
  assert_success
  run count_calls "gw-admin reload"
  assert_output "1"
  run count_calls "docker cp"
  assert_output "0"
  run count_calls "docker kill"
  assert_output "0"
  run grep -F "\"digest\": \"$want\"" "$(_egress_policy_dir "$CN")/policy.json"
  assert_success
}

@test "egress require: a live digest that survives one reload refuses" {
  F_DIGEST_SEQ="v1:0000000000000000" caged_box
  run _egress_require "$CN" start
  assert_failure
  assert_output --partial "enforcing a different policy"
  assert_output --partial "This is not a policy denial."
  run count_calls "gw-admin reload"
  assert_output "1"
}

@test "egress require: a gateway enforcing a stale policy names reload and never names rm" {
  F_DIGEST_SEQ="v1:0000000000000000" caged_box
  run _egress_require "$CN" start
  assert_failure
  assert_output --partial "cleat egress reload"
  refute_output --partial "cleat rm"
}

@test "egress require: a gateway enforcing open does not match a strict resolution over the same hosts" {
  _egress_resolve "$CN"
  local open_digest
  open_digest="$(_egress_policy_digest open "$_EG_HOSTS")"
  [ "$open_digest" != "$(_egress_policy_digest strict "$_EG_HOSTS")" ]
  F_DIGEST_SEQ="$open_digest" caged_box
  run _egress_require "$CN" start
  assert_failure
  assert_output --partial "enforcing a different policy"
}

@test "egress require: a reload the gateway refuses leaves the launch refused" {
  caged_box
  echo "v1:0000000000000000" | sed 's/^/ok policy-digest /' > "$DOCKER_MOCK_DIR/gwadmin/policy-digest"
  echo "err reload parse" > "$DOCKER_MOCK_DIR/gwadmin/reload"
  run _egress_require "$CN" start
  assert_failure
  assert_output --partial "enforcing a different policy"
}

@test "egress require: the in-loop gate re-resolves and never restores an earlier policy" {
  printf '[egress]\nmode = strict\nallow = docs.rs\n' > "$CLEAT_GLOBAL_CONFIG"
  local p1 p2
  p1="$(current_digest)"
  caged_box
  run _egress_require "$CN" start
  assert_success
  printf '[egress]\nmode = strict\nallow = docs.rs\ndeny = docs.rs\n' > "$CLEAT_GLOBAL_CONFIG"
  p2="$(current_digest)"
  [ "$p1" != "$p2" ]
  # The gateway already enforces P2: no reload.
  echo "ok policy-digest $p2" > "$DOCKER_MOCK_DIR/gwadmin/policy-digest"
  rm -f "$DOCKER_MOCK_DIR/gwadmin/policy-digest.seq"
  local reloads
  reloads="$(count_calls "gw-admin reload")"
  run _egress_require "$CN" claude
  assert_success
  run count_calls "gw-admin reload"
  assert_output "$reloads"
  # The gateway still enforces P1: exactly one reload, rendered from P2.
  printf 'ok policy-digest %s\nok policy-digest %s\n' "$p1" "$p2" > "$DOCKER_MOCK_DIR/gwadmin/policy-digest"
  rm -f "$DOCKER_MOCK_DIR/gwadmin/policy-digest.seq"
  run _egress_require "$CN" claude
  assert_success
  run count_calls "gw-admin reload"
  assert_output "$((reloads + 1))"
  run grep -F "\"digest\": \"$p2\"" "$(_egress_policy_dir "$CN")/policy.json"
  assert_success
  run grep -F "docs.rs" "$(_egress_policy_dir "$CN")/policy.json"
  assert_failure
}

# ── The gateway (assertion 15) ──────────────────────────────────────────────

@test "egress require: the gateway label is matched by box hash, not container name" {
  F_GW="true|gateway|$CN" caged_box
  run _egress_require "$CN" start
  assert_failure
  assert_output --partial "gateway is missing, stopped or not this box's"
  assert_output --partial "cleat egress restart"
  run count_calls "docker inspect --format $T_GW $GW"
  assert_output "1"
}

@test "egress require: a missing gateway refuses and names restart" {
  caged_box
  rm -f "$DOCKER_MOCK_DIR/inspect/$GW"
  run _egress_require "$CN" start
  assert_failure
  assert_output --partial "cleat egress restart"
  assert_output --partial "This is not a policy denial."
}

@test "egress require: a stopped gateway refuses" {
  F_GW="false|gateway|$BH" caged_box
  run _egress_require "$CN" start
  assert_failure
  assert_output --partial "missing, stopped"
}

@test "egress require: a gateway still starting inside the create window is waited for" {
  F_HEALTH_SEQ="starting starting healthy" caged_box
  mkdir -p "$CLEAT_RUN_DIR/$CN/egress"
  : > "$CLEAT_RUN_DIR/$CN/egress/creating"
  run _egress_require "$CN" run
  assert_success
  run count_calls "$T_HEALTH"
  assert_output "3"
}

@test "egress require: a gateway still starting outside the create window refuses" {
  F_HEALTH_SEQ="starting healthy" caged_box
  run _egress_require "$CN" start
  assert_failure
  assert_output --partial "gateway is not healthy"
  run count_calls "$T_HEALTH"
  assert_output "1"
}

@test "egress require: a stale create marker is outside the window" {
  F_HEALTH_SEQ="starting healthy" caged_box
  mkdir -p "$CLEAT_RUN_DIR/$CN/egress"
  : > "$CLEAT_RUN_DIR/$CN/egress/creating"
  _path_mtime() { echo $(( $(date +%s) - _EGRESS_CREATE_GRACE_SECS - 1 )); }
  run _egress_require "$CN" run
  assert_failure
  run count_calls "$T_HEALTH"
  assert_output "1"
}

@test "egress require: an unhealthy gateway breaks the wait early" {
  F_HEALTH_SEQ="starting unhealthy" caged_box
  mkdir -p "$CLEAT_RUN_DIR/$CN/egress"
  : > "$CLEAT_RUN_DIR/$CN/egress/creating"
  run _egress_require "$CN" run
  assert_failure
  assert_output --partial "gateway is not healthy"
  run count_calls "$T_HEALTH"
  assert_output "2"
}

@test "egress require: the health wait is bounded" {
  _EGRESS_HEALTH_WAIT_SECS=1
  F_HEALTH_SEQ="starting" caged_box
  mkdir -p "$CLEAT_RUN_DIR/$CN/egress"
  : > "$CLEAT_RUN_DIR/$CN/egress/creating"
  run _egress_require "$CN" run
  assert_failure
  run count_calls "$T_HEALTH"
  assert_output "6"
}

@test "egress require: a gateway that does not hold its socket path refuses" {
  F_PATHOK="ok path_ok false" caged_box
  run _egress_require "$CN" start
  assert_failure
  assert_output --partial "does not hold the socket"
}

@test "egress require: a failing selftest refuses" {
  F_SELFTEST="err selftest not-ready" caged_box
  run _egress_require "$CN" start
  assert_failure
  assert_output --partial "did not answer the box's own connection"
}

@test "egress require: the selftest runs as the box's own uid and gid" {
  caged_box
  run _egress_require "$CN" start
  assert_success
  run count_calls "docker exec -u 501:20 $GW /usr/local/bin/gw-admin selftest"
  assert_output "1"
}

@test "egress require: a box with no HOST_UID refuses the selftest" {
  F_ENV="HOME=/home/coder" caged_box
  run _egress_require "$CN" start
  assert_failure
  assert_output --partial "did not answer the box's own connection"
  run count_calls "gw-admin selftest"
  assert_output "0"
}

@test "egress require: admin verbs go to the gateway and never to the box" {
  caged_box
  run _egress_require "$CN" start
  assert_success
  run grep -F "docker exec $CN" "$DOCKER_CALLS"
  assert_failure
  run count_calls "docker exec $GW /usr/local/bin/gw-admin path_ok"
  assert_output "1"
}

# ── The capability interlocks (assertion 16) ────────────────────────────────

@test "egress require: an active policy refuses a box with the ssh capability" {
  ACTIVE_CAPS=(ssh)
  caged_box
  run _egress_require "$CN" start
  assert_failure
  assert_output --partial "the ssh capability"
  assert_output --partial "cleat egress off"
}

@test "egress require: no policy leaves the ssh capability alone" {
  ACTIVE_CAPS=(ssh docker hooks)
  rm -f "$CLEAT_GLOBAL_CONFIG"
  mock_docker_inspect_field "$CN" "$T_HASH" ""
  run _egress_require "$CN" start
  assert_success
  assert_output ""
  run _egress_ssh_conflict off
  assert_failure
  run _egress_ssh_conflict ""
  assert_failure
  run _egress_ssh_conflict strict
  assert_success
  run _egress_ssh_conflict open
  assert_success
}

@test "egress require: egress off leaves the ssh capability alone" {
  ACTIVE_CAPS=(ssh)
  printf '[egress]\nmode = off\n' > "$CLEAT_GLOBAL_CONFIG"
  mock_docker_inspect_field "$CN" "$T_HASH" ""
  run _egress_require "$CN" start
  assert_success
  assert_output ""
}

@test "egress require: an active policy refuses a box with the docker capability" {
  ACTIVE_CAPS=(docker)
  caged_box
  run _egress_require "$CN" start
  assert_failure
  assert_output --partial "the docker capability"
  run _egress_docker_conflict off
  assert_failure
}

@test "egress require: an active policy refuses the hooks capability unless the escape is set" {
  ACTIVE_CAPS=(hooks)
  caged_box
  run _egress_require "$CN" start
  assert_failure
  assert_output --partial "the hooks capability"
  run _egress_hooks_conflict off
  assert_failure
  CLEAT_EGRESS_ALLOW_HOOKS=1
  run _egress_hooks_conflict strict
  assert_failure
  CLEAT_EGRESS_ALLOW_HOOKS=0
  run _egress_hooks_conflict strict
  assert_success
}

@test "egress require: open mode meets the interlocks as strict does" {
  printf '[egress]\nmode = open\n' > "$CLEAT_GLOBAL_CONFIG"
  ACTIVE_CAPS=(ssh)
  caged_box
  run _egress_require "$CN" start
  assert_failure
  assert_output --partial "the ssh capability"
}

@test "egress require: gh and unsafe-rm do not interlock" {
  ACTIVE_CAPS=(gh unsafe-rm git)
  caged_box
  run _egress_require "$CN" start
  assert_success
}

# ── The engine and the digest tool ──────────────────────────────────────────

@test "egress require: an unvalidated engine refuses before reading the box" {
  _egress_engine_kind() { printf 'desktop-windows'; }
  mkdir -p "$DOCKER_MOCK_DIR/inspect"
  run _egress_require "$CN" start
  assert_failure
  assert_output --partial "not validated on this Docker engine yet"
  assert_output --partial "docs/egress-validation.md"
  run count_calls "$T_NETMODE"
  assert_output "0"
}

@test "egress require: a refused engine refuses and names cleat egress off" {
  _egress_engine_kind() { printf 'vm-backend'; }
  mkdir -p "$DOCKER_MOCK_DIR/inspect"
  run _egress_require "$CN" start
  assert_failure
  assert_output --partial "not available on this Docker engine"
  assert_output --partial "cleat egress off"
  refute_output --partial "cleat egress open"
}

@test "egress require: open mode on a refused engine refuses" {
  printf '[egress]\nmode = open\n' > "$CLEAT_GLOBAL_CONFIG"
  _egress_engine_kind() { printf 'rootless'; }
  run _egress_require "$CN" start
  assert_failure
  assert_output --partial "not available on this Docker engine"
}

@test "egress require: a host whose md5 is the cksum fallback refuses a policy" {
  _egress_md5_ok() { return 1; }
  mkdir -p "$DOCKER_MOCK_DIR/inspect"
  run _egress_require "$CN" start
  assert_failure
  assert_output --partial "no md5sum or md5"
}

@test "egress require: a config directory inside the box's workspace refuses" {
  caged_box
  _RESOLVED_PROJECT="$(dirname "$CLEAT_CONFIG_DIR")"
  run _egress_require "$CN" start
  assert_failure
  assert_output --partial "inside a folder a box can write"
  _RESOLVED_PROJECT="$TEST_TEMP/elsewhere"
  mkdir -p "$_RESOLVED_PROJECT"
  run _egress_require "$CN" start
  assert_success
}

@test "egress require: a global config linked into the workspace refuses at the gate" {
  mkdir -p "$TEST_TEMP/dotfiles/cleat"
  printf '[egress]\nmode = strict\n' > "$TEST_TEMP/dotfiles/cleat/config"
  rm -f "$CLEAT_GLOBAL_CONFIG"
  ln -s "$TEST_TEMP/dotfiles/cleat/config" "$CLEAT_GLOBAL_CONFIG"
  caged_box
  _RESOLVED_PROJECT="$TEST_TEMP/dotfiles"
  run _egress_require "$CN" start
  assert_failure
  assert_output --partial "An egress policy file lives inside a folder a box can write"
}

@test "egress require: a box that still has the ssh mounts refuses whatever the launch caps" {
  ACTIVE_CAPS=()
  local d
  for d in '/workspace\n/run/cleat-egress\n/home/coder/.ssh' '/workspace\n/run/cleat-egress\n/tmp/ssh-agent.sock'; do
    rm -rf "$DOCKER_MOCK_DIR/inspect" "$DOCKER_MOCK_DIR/volume_inspect"
    F_DESTS="$d" caged_box
    run _egress_require "$CN" shell
    assert_failure
    assert_output --partial "ssh keys or agent mounted"
  done
}

@test "egress require: a docker socket at /run refuses like one at /var/run" {
  F_DESTS='/workspace\n/run/cleat-egress\n/run/docker.sock' caged_box
  run _egress_require "$CN" start
  assert_failure
  assert_output --partial "Docker socket is mounted"
}

@test "egress require: a colon separated unconfined profile refuses" {
  F_SEC='["seccomp:unconfined","label=disable"]' caged_box
  run _egress_require "$CN" start
  assert_failure
  assert_output --partial "unconfined"
}

# ── The rendered policy (8.2) ───────────────────────────────────────────────

@test "egress require: the rendered policy is the gateway's document, byte for byte" {
  run _egress_policy_json strict $'claude.ai\napi.anthropic.com\nclaude.ai\n'
  assert_success
  local d
  d="$(_egress_policy_digest strict $'api.anthropic.com\nclaude.ai')"
  assert_output "{
  \"v\": 1,
  \"digest\": \"$d\",
  \"mode\": \"strict\",
  \"port\": 443,
  \"hosts\": [
    \"api.anthropic.com\",
    \"claude.ai\"
  ],
  \"max_tunnels\": 256,
  \"handshake_timeout_s\": 20,
  \"denials_log_max_bytes\": 1048576,
  \"selftest_host\": \"cleat-gateway.invalid\"
}"
}

@test "egress require: the rendered policy is a 0644 file in a 0755 directory" {
  _egress_render_policy "$CN" strict $'claude.ai\napi.anthropic.com'
  local dir mode
  dir="$(_egress_policy_dir "$CN")"
  [ -f "$dir/policy.json" ]
  mode="$(stat -c %a "$dir" 2>/dev/null || stat -f %Lp "$dir")"
  [ "$mode" = 755 ]
  mode="$(stat -c %a "$dir/policy.json" 2>/dev/null || stat -f %Lp "$dir/policy.json")"
  [ "$mode" = 644 ]
  run ls -A "$dir"
  assert_output "policy.json"
  [[ "$dir" == "$CLEAT_CONFIG_DIR/egress-rendered/$BH" ]]
}

@test "egress require: the renderer refuses a directory, a link and a host it would have to escape" {
  local dir
  dir="$(_egress_policy_dir "$CN")"
  mkdir -p "$dir/policy.json"
  run _egress_render_policy "$CN" strict claude.ai
  assert_failure
  rm -rf "$dir"
  mkdir -p "$TEST_TEMP/elsewhere" "$(dirname "$dir")"
  ln -s "$TEST_TEMP/elsewhere" "$dir"
  run _egress_render_policy "$CN" strict claude.ai
  assert_failure
  [ ! -e "$TEST_TEMP/elsewhere/policy.json" ]
  rm -f "$dir"
  run _egress_render_policy "$CN" strict 'claude.ai"'
  assert_failure
  run _egress_render_policy "$CN" off claude.ai
  assert_failure
}

@test "egress require: the names derive from the box container name, twelve hex" {
  [[ "$BH" =~ ^[0-9a-f]{12}$ ]]
  run _egress_gateway_name "$CN"
  assert_output "cleat-gw-$BH"
  run _egress_sock_volume "$CN"
  assert_output "cleat-gw-$BH-sock"
  [ "$(_egress_box_hash "${CN}x")" != "$BH" ]
  [ "$(_egress_gateway_name "$CN")" != "$CN" ]
}

# ── Placement (5.7): before every exec, on every fatal verb ─────────────────

# A box that predates a strict policy: the gate refuses at its first read.
placement_box() {
  mkdir -p "$TEST_TEMP/project"
  CN="$(container_name_for "$TEST_TEMP/project")"
  mock_docker_images "cleat"
  mock_docker_ps "$CN"
  mock_docker_ps_a "$CN"
  check_for_update() { true; }
  check_drift() { true; }
  _resolve_config_drift() { true; }
}

no_exec_recorded() {
  run grep -E '^docker exec' "$DOCKER_CALLS"
  assert_failure
}

@test "egress require: the gate runs before the first docker exec on every fatal verb" {
  placement_box
  local v
  for v in cmd_start cmd_resume cmd_claude cmd_shell cmd_login; do
    : > "$DOCKER_CALLS"
    run "$v" "$TEST_TEMP/project"
    assert_failure
    assert_output --partial "Egress refused box"
    no_exec_recorded
  done
  : > "$DOCKER_CALLS"
  _SETUP_DECLARED=1
  _SETUP_TRUSTED=1
  run _maybe_run_setup "$CN" "$TEST_TEMP/project" main 1
  assert_failure
  assert_output --partial "Egress refused box"
  no_exec_recorded
  : > "$DOCKER_CALLS"
  run exec_claude "$CN" --dangerously-skip-permissions
  assert_failure
  assert_output --partial "Egress refused box"
  no_exec_recorded
}

@test "egress require: cleat run gates right after the box is created" {
  placement_box
  mock_docker_ps ""
  mock_docker_ps_a ""
  run cmd_run "$TEST_TEMP/project"
  assert_failure
  assert_output --partial "Egress refused box"
  run grep -E "^docker run .*--name $CN" "$DOCKER_CALLS"
  assert_success
  no_exec_recorded
}

@test "egress require: the refusal comes before the launch summary" {
  placement_box
  run cmd_start "$TEST_TEMP/project"
  assert_failure
  refute_output --partial "Claude launched"
}

@test "egress require: with no policy every fatal verb still runs" {
  placement_box
  rm -f "$CLEAT_GLOBAL_CONFIG"
  run cmd_claude "$TEST_TEMP/project"
  assert_success
  run grep -E '^docker exec -it' "$DOCKER_CALLS"
  assert_success
}

# ── The relaunch loop (5.7) ─────────────────────────────────────────────────

# An interactive relaunchable session whose first claude exec exits 143 and
# leaves a ready ticket, so the loop runs a second iteration. EXTRA runs in
# the exec script on the first claude exec, to change the world in between.
loop_setup() {
  SID="d7b73579-1111-2222-3333-444455556666"
  _RESOLVED_PROJECT="$TEST_TEMP/proj"; _BOX=main
  mkdir -p "$_RESOLVED_PROJECT"
  SDIR="$(_sessions_key_dir "$_RESOLVED_PROJECT" main)"; mkdir -p "$SDIR"
  printf '{"type":"user","message":{"role":"user"},"parentUuid":null}\n' > "$SDIR/$SID.jsonl"
  mkdir -p "$CLEAT_RUN_DIR/$CN"
  export LOOP_COUNT="$TEST_TEMP/lc" LOOP_RUN_DIR="$CLEAT_RUN_DIR/$CN" LOOP_SID="$SID" LOOP_BY="$$"
  export LOOP_GW_SCRIPT="$TEST_TEMP/gwexec.sh" LOOP_CFG="$CLEAT_GLOBAL_CONFIG"
  cat > "$TEST_TEMP/loop.sh" <<'SH'
#!/usr/bin/env bash
flat="$(printf '%s ' "$@" | tr '\n' ' ')"
case "$flat" in *clip-daemon*) : ;; *gw-admin*) exec "$LOOP_GW_SCRIPT" "$@" ;; *) exit 0 ;; esac
n=$(cat "$LOOP_COUNT" 2>/dev/null || echo 0); n=$((n+1)); printf '%s' "$n" > "$LOOP_COUNT"
[ "$n" -eq 1 ] || exit 0
id=""
for a in "$@"; do case "$a" in CLEAT_EXEC_ID=*) id="${a#CLEAT_EXEC_ID=}";; esac; done
{ printf 'v=1\nstate=ready\nby=%s\nat=%s\nsid=%s\nto=default\n' "$LOOP_BY" "$(date +%s)" "$LOOP_SID"; } > "$LOOP_RUN_DIR/.handoff.$id"
if [ -n "${LOOP_EXTRA:-}" ]; then eval "$LOOP_EXTRA"; fi
exit 143
SH
  chmod +x "$TEST_TEMP/loop.sh"
  export DOCKER_STUB_EXEC_SCRIPT="$TEST_TEMP/loop.sh"
  mock_docker_ps "$CN"
  _is_interactive() { return 0; }
  _account_sync_out() { return 0; }
}

@test "egress require: the relaunch loop re-checks before each exec" {
  caged_box
  loop_setup
  # A live switch flags Claude's cached identity stale, so the relaunch's
  # prepare step reaches into the box with docker top.
  export LOOP_EXTRA=': > "$LOOP_RUN_DIR/claude.json.identity-stale"'
  _exec_claude_prepare_account() { docker top "$1" >/dev/null 2>&1 || true; }
  run exec_claude "$CN" --dangerously-skip-permissions
  assert_success
  run cat "$LOOP_COUNT"
  assert_output "2"
  # After the first claude exec, the gate's own read comes before the next
  # docker top and before the second claude exec.
  local first_exec gate top second
  first_exec="$(grep -nE '^docker exec -it' "$DOCKER_CALLS" | sed -n 1p | cut -d: -f1)"
  second="$(grep -nE '^docker exec -it' "$DOCKER_CALLS" | sed -n 2p | cut -d: -f1)"
  gate="$(grep -nF "$T_NETMODE" "$DOCKER_CALLS" | awk -F: -v f="$first_exec" '$1 > f {print $1; exit}')"
  top="$(grep -nE '^docker top' "$DOCKER_CALLS" | awk -F: -v f="$first_exec" '$1 > f {print $1; exit}')"
  [ -n "$first_exec" ] && [ -n "$second" ] && [ -n "$gate" ] && [ -n "$top" ]
  [ "$gate" -lt "$top" ]
  [ "$gate" -lt "$second" ]
}

@test "egress require: a refusal inside the relaunch loop breaks out and runs the session end once" {
  caged_box
  loop_setup
  # Between the two iterations the policy is removed from under the caged box.
  export LOOP_EXTRA='rm -f "$LOOP_CFG"'
  _maybe_report_hook_drops() { echo "reports" >> "$TEST_TEMP/reports"; }
  run exec_claude "$CN" --dangerously-skip-permissions
  assert_failure
  assert_output --partial "no longer resolves"
  refute_output --partial "Claude exited with code"
  run cat "$LOOP_COUNT"
  assert_output "1"
  run grep -c reports "$TEST_TEMP/reports"
  assert_output "1"
}

@test "egress require: a refusing reader inside the relaunch loop cannot exit past the session end" {
  caged_box
  loop_setup
  export LOOP_EXTRA='printf "[egress]\nallow = docs.rs\n" > "$LOOP_CFG"'
  _maybe_report_hook_drops() { echo "reports ran"; }
  run exec_claude "$CN" --dangerously-skip-permissions
  assert_failure
  assert_output --partial "lists hosts but no mode"
  assert_output --partial "reports ran"
  run cat "$LOOP_COUNT"
  assert_output "1"
}
