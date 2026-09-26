# Shared fixtures for the egress unit tests (EGRESS-SPEC.md 11.3): the
# templates the gate reads, a caged box and its gateway that pass every
# assertion, and a gw-admin answer script. Loaded after ../setup.
#
# A test sets CN (the box's container name) and calls egress_box_names to
# derive BH, GW and VOL, then caged_box to plant the inspect fixtures.

# Derives the gateway's names from CN, as the CLI does.
egress_box_names() {
  BH="$(_egress_box_hash "$CN")"
  GW="cleat-gw-$BH"
  VOL="cleat-gw-$BH-sock"
}

# The gateway's admin answers, one file per verb under gwadmin/, a sequence
# whose last line repeats, the way the inspect fixtures behave. A verb with no
# file answers nothing and gw-admin's no-answer status, except last_shim_seen,
# which answers a fresh heartbeat unless a test says otherwise.
use_gw_admin_stub() {
  mkdir -p "$DOCKER_MOCK_DIR/gwadmin"
  cat > "$TEST_TEMP/gwexec.sh" <<'SH'
#!/usr/bin/env bash
shift
if [ "$1" = -u ]; then shift 2; fi
shift
[ "${1:-}" = /usr/local/bin/gw-admin ] || exit 0
f="$DOCKER_MOCK_DIR/gwadmin/$2"
if [ ! -f "$f" ]; then
  [ "$2" = last_shim_seen ] && { echo "ok last_shim_seen 3"; exit 0; }
  exit 2
fi
n=0; [ -f "$f.seq" ] && n=$(cat "$f.seq")
line=$(sed -n "$((n + 1))p" "$f")
[ -n "$line" ] || line=$(tail -n 1 "$f")
echo $((n + 1)) > "$f.seq"
printf '%s\n' "$line"
SH
  chmod +x "$TEST_TEMP/gwexec.sh"
  export DOCKER_STUB_EXEC_SCRIPT="$TEST_TEMP/gwexec.sh"
}

# mock_gw_admin <verb> <line>...: the lines that verb answers, in order.
mock_gw_admin() {
  local verb="$1" f
  shift
  mkdir -p "$DOCKER_MOCK_DIR/gwadmin"
  f="$DOCKER_MOCK_DIR/gwadmin/$verb"
  printf '%s\n' "$@" > "$f"
  rm -f "$f.seq"
}

# A launch that meets live enforcement: a strict global policy, the gateway
# image present, the daemon up, the engine pinned to the validated one, the
# stub strict about bind sources. Never the live host's engine (11.3).
mock_egress_caged_launch() {
  mkdir -p "$(dirname "$CLEAT_GLOBAL_CONFIG")"
  printf '[egress]\nmode = strict\n' > "$CLEAT_GLOBAL_CONFIG"
  mock_docker_image_cached "$_GATEWAY_IMAGE"
  _daemon_up() { return 0; }
  _egress_engine_kind() { printf 'desktop-macos'; }
  export DOCKER_STUB_STRICT=1
  _EGRESS_ENFORCING=1
  use_gw_admin_stub
}

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
