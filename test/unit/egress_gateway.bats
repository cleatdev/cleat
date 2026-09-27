#!/usr/bin/env bats
# The egress gateway's lifecycle (EGRESS-SPEC.md 8): its image, its creation
# beside a caged box, teardown and stop at every removal and stop site, the
# idle sweep and the volumes it owns.
load "../setup"
load "../lib/egress_fixtures"

setup() {
  _common_setup
  use_docker_stub
  source_cli
  _BOX=main
}
teardown() { _common_teardown; }

# ── The image (8.0) ─────────────────────────────────────────────────────────

@test "egress: the gateway image reference is a digest and never a tag" {
  [[ "$_GATEWAY_IMAGE" =~ ^ghcr\.io/cleatdev/cleat-gw@sha256:[0-9a-f]{64}$ ]]
}

@test "egress: a present gateway image produces no pull" {
  printf '%s\n' "$_GATEWAY_IMAGE" > "$DOCKER_MOCK_DIR/cached_images"
  run _egress_gateway_image_ensure
  assert_success
  assert_output ""
  run grep -c '^docker pull' "$DOCKER_CALLS"
  assert_output "0"
}

@test "egress: a missing gateway image is pulled once, pinned to the daemon's architecture" {
  _daemon_arch() { printf arm64; }
  export DOCKER_PULL_EXIT_CODE=0
  run _egress_gateway_image_ensure
  assert_success
  run grep -c '^docker pull' "$DOCKER_CALLS"
  assert_output "1"
  run grep -F -- "docker pull --platform linux/arm64 $_GATEWAY_IMAGE" "$DOCKER_CALLS"
  assert_success
}

@test "egress: a missing gateway image refuses the launch and names the image" {
  export DOCKER_PULL_EXIT_CODE=1
  run _egress_gateway_image_ensure
  assert_failure
  assert_output --partial "could not be pulled: $_GATEWAY_IMAGE"
  assert_output --partial "This is not a policy denial."
}

@test "egress: the gateway image pull shows one line off a terminal and a forced pull pulls a present image" {
  export DOCKER_PULL_EXIT_CODE=0
  run _egress_gateway_image_ensure
  assert_success
  assert_output --partial "Pulling the egress gateway image"
  run bash -c 'printf "%s\n" "$1" | grep -c .' _ "$output"
  assert_output "1"
  printf '%s\n' "$_GATEWAY_IMAGE" > "$DOCKER_MOCK_DIR/cached_images"
  : > "$DOCKER_CALLS"
  run _egress_gateway_image_ensure force
  assert_success
  run grep -c '^docker pull' "$DOCKER_CALLS"
  assert_output "1"
}

# ── Creation (8.2) ──────────────────────────────────────────────────────────
#
# The helpers the caged create calls, driven directly: the rendered policy
# first, then the labelled socket volume, then the gateway. The stub is strict,
# so a bind source that is missing or a cleat-gw- volume never created fails
# the run as Docker's auto-create would have hidden it. LINE is the gateway's
# recorded run line.

gw_started() {
  CN="${CN:-cleat-demo-3f2a9104}"
  egress_box_names
  export DOCKER_STUB_STRICT=1
  mkdir -p "$CLEAT_CONFIG_DIR"
  _egress_render_policy "$CN" strict "claude.ai"
  _egress_sock_volume_create "$CN"
  run _egress_gateway_run "$CN" 501 20
  assert_success
  LINE="$(docker_run_line_for "$GW")"
  [ -n "$LINE" ]
}

@test "egress: the gateway hash is twelve hex characters" {
  CN=cleat-demo-3f2a9104
  egress_box_names
  [[ "$BH" =~ ^[0-9a-f]{12}$ ]]
  run _egress_gateway_name "$CN"
  assert_output "cleat-gw-$BH"
  run _egress_sock_volume "$CN"
  assert_output "cleat-gw-$BH-sock"
  run _egress_policy_dir "$CN"
  assert_output "$CLEAT_CONFIG_DIR/egress-rendered/$BH"
  [ "$(_egress_box_hash "${CN}x")" != "$BH" ]
}

@test "egress: the gateway run line adds no network, user, init or health flag and nothing after the image" {
  gw_started
  local -a w
  read -r -a w <<< "$LINE"
  # The last word is the image: gateway.py takes no arguments.
  [ "${w[${#w[@]}-1]}" = "$_GATEWAY_IMAGE" ]
  run bash -c 'printf "%s\n" $1 | grep -- "^-" | LC_ALL=C sort -u | tr "\n" " "' _ "$LINE"
  assert_output "--cap-add --cap-drop --cpus --label --log-driver --log-opt --memory --memory-swap --name --pids-limit --read-only --restart --security-opt --stop-timeout --tmpfs -d -e -v "
  # docker run, never docker create.
  run grep -c "^docker create" "$DOCKER_CALLS"
  assert_output "0"
}

@test "egress: the gateway sets sh.cleat.gateway-for and never sh.cleat.box, never a version, never the box's name" {
  gw_started
  run bash -c 'printf "%s\n" $1 | grep -A1 -- "^--label$" | grep -v -- "^--label$" | grep -v "^--$"' _ "$LINE"
  assert_output "sh.cleat.role=gateway
sh.cleat.gateway-for=$BH"
  run grep -cF -- "$CN" <<< "$LINE"
  assert_output "0"
}

@test "egress: the gateway run line adds back exactly CHOWN, SETUID and SETGID" {
  gw_started
  run assert_docker_run_has "$GW" "--cap-drop ALL --cap-add CHOWN --cap-add SETUID --cap-add SETGID --security-opt no-new-privileges --read-only --tmpfs /run/gw-admin:rw,noexec,nosuid,nodev,size=1m "
  assert_success
  run grep -o -- "--cap-add" <<< "$LINE"
  assert_output "--cap-add
--cap-add
--cap-add"
}

@test "egress: the gateway run line pins the json-file log driver" {
  gw_started
  run assert_docker_run_has "$GW" "--log-driver json-file --log-opt max-size=2m --log-opt max-file=3 "
  assert_success
}

@test "egress gateway: the gateway run line pins the memory ceiling" {
  gw_started
  run assert_docker_run_has "$GW" "--memory 128m --memory-swap 128m --pids-limit 128 --cpus 1.0 --restart on-failure:3 --stop-timeout 5 "
  assert_success
}

@test "egress: the policy directory is mounted read-only in the gateway and in no box" {
  gw_started
  run assert_docker_run_has "$GW" "-v $CLEAT_CONFIG_DIR/egress-rendered/$BH:/etc/cleat-egress:ro "
  assert_success
  run grep -c "egress-rendered" <<< "$(grep '^docker run ' "$DOCKER_CALLS" | grep -vF -- "--name $GW ")"
  assert_output "0"
}

@test "egress: the socket volume is mounted read-write in the gateway" {
  gw_started
  run assert_docker_run_has "$GW" "-v ${VOL}:/run/cleat-egress "
  assert_success
  run assert_docker_run_lacks "$GW" "-v ${VOL}:/run/cleat-egress:ro"
  assert_success
}

@test "egress gateway: the shared volume carries only the socket and the denials log" {
  # The box mounts this volume. Anything else the gateway put in it, the box
  # could read, and a policy there could be rewritten from inside the cage.
  gw_started
  local -a w
  local i dests="" srcs=""
  read -r -a w <<< "$LINE"
  for ((i = 0; i < ${#w[@]} - 1; i++)); do
    [ "${w[$i]}" = -v ] || continue
    case "${w[$i+1]#*:}" in
      /run/cleat-egress|/run/cleat-egress/*|/run/cleat-egress:*)
        dests+="${w[$i+1]#*:}"$'\n'; srcs+="${w[$i+1]%%:*}"$'\n' ;;
    esac
  done
  run printf '%s' "$dests"
  assert_output "/run/cleat-egress"
  run printf '%s' "$srcs"
  assert_output "$VOL"
}

@test "egress: the gateway takes the socket owner it is handed and refuses one that is not a number" {
  gw_started
  run assert_docker_run_has "$GW" '-e CLEAT_SOCK_UID=501 -e CLEAT_SOCK_GID=20 '
  assert_success
  : > "$DOCKER_CALLS"
  local bad
  for bad in "x:20" "501:" ":20" "501:20:1" "-1:20"; do
    run _egress_gateway_run "$CN" "${bad%%:*}" "${bad#*:}"
    assert_failure
  done
  run _egress_gateway_run "$CN" 501 ""
  assert_failure
  run grep -c '^docker run' "$DOCKER_CALLS"
  assert_output "0"
}

@test "egress: the gateway is never run before its rendered policy exists" {
  # Docker makes a missing bind source as a root-owned directory, the way a
  # probe once turned a missing ~/.gitconfig into a directory on the host.
  CN=cleat-demo-3f2a9104
  egress_box_names
  mkdir -p "$CLEAT_CONFIG_DIR"
  run _egress_gateway_run "$CN" 501 20
  assert_failure
  [ ! -e "$CLEAT_CONFIG_DIR/egress-rendered" ]
  # A directory with no policy in it, and a policy dir that is a link.
  mkdir -p "$CLEAT_CONFIG_DIR/egress-rendered/$BH"
  run _egress_gateway_run "$CN" 501 20
  assert_failure
  rmdir "$CLEAT_CONFIG_DIR/egress-rendered/$BH"
  mkdir -p "$TEST_TEMP/elsewhere"
  printf '{}\n' > "$TEST_TEMP/elsewhere/policy.json"
  ln -s "$TEST_TEMP/elsewhere" "$CLEAT_CONFIG_DIR/egress-rendered/$BH"
  run _egress_gateway_run "$CN" 501 20
  assert_failure
  run grep -c '^docker run' "$DOCKER_CALLS"
  assert_output "0"
}

@test "egress: a gateway run that fails prints what Docker said" {
  CN=cleat-demo-3f2a9104
  egress_box_names
  mkdir -p "$CLEAT_CONFIG_DIR"
  _egress_render_policy "$CN" strict "claude.ai"
  export DOCKER_EXIT_CODE=1
  export DOCKER_STDERR="Conflict. The container name /$GW is already in use"
  run _egress_gateway_run "$CN" 501 20
  assert_failure
  assert_output --partial "is already in use"
}

@test "egress: start does not require a resolver" {
  # The selftest and the health probe ask for a reserved name the gateway
  # answers itself. An .invalid name never resolves (RFC 6761), so a gateway
  # can start and prove itself on a host whose DNS is down.
  CN=cleat-demo-3f2a9104
  egress_box_names
  mkdir -p "$CLEAT_CONFIG_DIR"
  _egress_render_policy "$CN" strict "claude.ai"
  run python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["selftest_host"])' "$CLEAT_CONFIG_DIR/egress-rendered/$BH/policy.json"
  assert_output "cleat-gateway.invalid"
}

@test "egress: the socket volume is created with both labels before the gateway" {
  gw_started
  run grep -n "^docker volume create" "$DOCKER_CALLS"
  assert_output --partial "--label sh.cleat.role=egress-sock --label sh.cleat.gateway-for=$BH $VOL"
  local vn rn
  vn="$(grep -n "^docker volume create" "$DOCKER_CALLS" | cut -d: -f1)"
  rn="$(grep -nF -- "--name $GW " "$DOCKER_CALLS" | cut -d: -f1)"
  [ "$vn" -lt "$rn" ]
}

@test "egress: a socket volume that cannot be created fails" {
  CN=cleat-demo-3f2a9104
  export DOCKER_VOLUME_EXIT_CODE=1
  run _egress_sock_volume_create "$CN"
  assert_failure
}

# ── Teardown (8.7) ──────────────────────────────────────────────────────────

# A box with everything a caged create leaves behind: the rendered policy, a
# create marker, the session marker and the three files that belong to the box.
teardown_box() {
  CN=cleat-demo-3f2a9104
  egress_box_names
  mkdir -p "$CLEAT_CONFIG_DIR/egress-rendered/$BH" "$CLEAT_RUN_DIR/$CN/egress" \
    "$CLEAT_CONFIG_DIR/egress-boxes" "$CLEAT_CONFIG_DIR/egress-pins" "$CLEAT_CONFIG_DIR/egress-notices"
  printf '{}\n' > "$CLEAT_CONFIG_DIR/egress-rendered/$BH/policy.json"
  : > "$CLEAT_RUN_DIR/$CN/egress/creating"
  printf 'started\n' > "$CLEAT_CONFIG_DIR/egress-boxes/$CN.session"
  printf '[egress]\nmode = off\n' > "$CLEAT_CONFIG_DIR/egress-boxes/$CN"
  printf 'pin\n' > "$CLEAT_CONFIG_DIR/egress-pins/$CN"
  printf 'seen\n' > "$CLEAT_CONFIG_DIR/egress-notices/$CN"
}

@test "egress: teardown is a no-op for a throwaway container" {
  run _egress_teardown cleat-claude-upgrade keep
  assert_success
  assert_output ""
  run grep -c "cleat-gw-" "$DOCKER_CALLS"
  assert_output "0"
  run _egress_teardown "" forget
  assert_success
}

@test "egress: teardown removes the gateway before the box, then the socket volume and the rendered policy" {
  teardown_box
  run _egress_teardown "$CN" keep
  assert_success
  assert_output ""
  run grep -n "^docker rm -f \|^docker volume rm " "$DOCKER_CALLS"
  assert_output "$(printf '1:docker rm -f %s\n2:docker rm -f %s\n3:docker volume rm %s' "$GW" "$CN" "$VOL")"
  [ ! -e "$CLEAT_CONFIG_DIR/egress-rendered/$BH" ]
  [ ! -e "$CLEAT_RUN_DIR/$CN/egress/creating" ]
  [ ! -e "$CLEAT_CONFIG_DIR/egress-boxes/$CN.session" ]
}

@test "egress: teardown keeps a box's own files on keep and removes them on forget" {
  teardown_box
  run _egress_teardown "$CN" keep
  assert_success
  [ -f "$CLEAT_CONFIG_DIR/egress-boxes/$CN" ]
  [ -f "$CLEAT_CONFIG_DIR/egress-pins/$CN" ]
  [ -f "$CLEAT_CONFIG_DIR/egress-notices/$CN" ]
  # Anything but the literal forget keeps them, a missing kind included.
  run _egress_teardown "$CN"
  [ -f "$CLEAT_CONFIG_DIR/egress-boxes/$CN" ]
  run _egress_teardown "$CN" Forget
  [ -f "$CLEAT_CONFIG_DIR/egress-boxes/$CN" ]
  run _egress_teardown "$CN" forget
  assert_success
  [ ! -e "$CLEAT_CONFIG_DIR/egress-boxes/$CN" ]
  [ ! -e "$CLEAT_CONFIG_DIR/egress-pins/$CN" ]
  [ ! -e "$CLEAT_CONFIG_DIR/egress-notices/$CN" ]
}

@test "egress: teardown never removes the global egress section" {
  teardown_box
  mkdir -p "$(dirname "$CLEAT_GLOBAL_CONFIG")"
  printf '[egress]\nmode = strict\npack = github\n' > "$CLEAT_GLOBAL_CONFIG"
  printf 'global pin\n' > "$CLEAT_CONFIG_DIR/egress-pins/global"
  run _egress_teardown "$CN" forget
  assert_success
  run cat "$CLEAT_GLOBAL_CONFIG" "$CLEAT_CONFIG_DIR/egress-pins/global"
  assert_output "[egress]
mode = strict
pack = github
global pin"
}

@test "egress: teardown touches no gateway or volume for a box that never had a policy" {
  CN=cleat-demo-3f2a9104
  egress_box_names
  run _egress_teardown "$CN" keep
  assert_success
  run cat "$DOCKER_CALLS"
  assert_output "docker rm -f $CN"
  # force clears them anyway: the pre-clear before a caged create.
  : > "$DOCKER_CALLS"
  run _egress_teardown "$CN" keep force
  run grep -c "$GW" "$DOCKER_CALLS"
  assert_output "2"
  # A create marker alone is a create in flight.
  : > "$DOCKER_CALLS"
  mkdir -p "$CLEAT_RUN_DIR/$CN/egress"
  : > "$CLEAT_RUN_DIR/$CN/egress/creating"
  run _egress_teardown "$CN" keep
  run grep -c "$GW" "$DOCKER_CALLS"
  assert_output "2"
}

@test "egress: teardown stops before the files when the box survives its removal" {
  # Forgetting a surviving box's policy file would hand it the global policy.
  teardown_box
  export DOCKER_EXIT_CODE=1
  container_exists() { return 0; }
  run _egress_teardown "$CN" forget
  assert_failure
  run grep -c "^docker volume rm" "$DOCKER_CALLS"
  assert_output "0"
  [ -f "$CLEAT_CONFIG_DIR/egress-rendered/$BH/policy.json" ]
  [ -f "$CLEAT_CONFIG_DIR/egress-boxes/$CN" ]
  # A removal that errored on a box already gone carries on.
  container_exists() { return 1; }
  run _egress_teardown "$CN" forget
  assert_success
  [ ! -e "$CLEAT_CONFIG_DIR/egress-boxes/$CN" ]
}

@test "egress: teardown with a hash that is not twelve hex never reaches egress-rendered" {
  # A host with no md5 tool hashes with cksum: ten decimal digits at most.
  teardown_box
  mkdir -p "$CLEAT_CONFIG_DIR/egress-rendered/aaaaaaaaaaaa"
  _md5() { printf '3015617425\n'; }
  run _egress_teardown "$CN" forget
  assert_success
  [ -d "$CLEAT_CONFIG_DIR/egress-rendered/aaaaaaaaaaaa" ]
  [ -d "$CLEAT_CONFIG_DIR/egress-rendered/$BH" ]
  run cat "$DOCKER_CALLS"
  assert_output "docker rm -f $CN"
  # The box's own files are named by the box, never by the hash.
  [ ! -e "$CLEAT_CONFIG_DIR/egress-boxes/$CN" ]
  _md5() { printf 'zzzzzzzzzzzzzzzz\n'; }
  : > "$DOCKER_CALLS"
  run _egress_teardown "$CN" keep
  [ -d "$CLEAT_CONFIG_DIR/egress-rendered/$BH" ]
  run cat "$DOCKER_CALLS"
  assert_output "docker rm -f $CN"
}

@test "egress: the box's socket owner is read off its frozen environment" {
  CN=cleat-demo-3f2a9104
  mock_docker_inspect_field "$CN" "$T_ENV" 'HOME=/home/coder\nHOST_UID=5151\nHOST_GID=5152'
  run _egress_box_sock_ids "$CN"
  assert_success
  assert_output "5151:5152"
  CN=cleat-demo-3f2a9105
  mock_docker_inspect_field "$CN" "$T_ENV" 'HOST_UID=5151'
  run _egress_box_sock_ids "$CN"
  assert_failure
  CN=cleat-demo-3f2a9106
  mock_docker_inspect_field "$CN" "$T_ENV" 'HOST_UID=51x\nHOST_GID=5152'
  run _egress_box_sock_ids "$CN"
  assert_failure
}

# ── The caged create through cmd_run (8.2, 8.4, 3.8) ────────────────────────
#
# A fresh project under a strict policy with enforcement live: the gateway
# image present, the engine pinned to the validated one, the stub strict about
# bind sources and the cleat-gw volume ledger. The box and gateway fixtures the
# gate reads are planted up front, so a create that makes them passes.

caged_create() {
  mock_egress_caged_launch
  mkdir -p "$TEST_TEMP/project"
  CN="$(container_name_for "$TEST_TEMP/project")"
  egress_box_names
  mock_docker_images "cleat"
  _host_clip_cmd() { echo ""; }
  caged_box
}

@test "egress: the socket volume is mounted read-only in the box" {
  caged_create
  # And under the macOS mount backend's nested-bind rule, on top of strict.
  export DOCKER_STUB_SIMULATE_VIRTIOFS=1
  run cmd_run "$TEST_TEMP/project"
  assert_success
  run assert_docker_run_has "$CN" "-v ${VOL}:/run/cleat-egress:ro "
  assert_success
}

@test "egress gateway: a caged box is created with network none, NET_RAW dropped and the three labels" {
  caged_create
  run cmd_run "$TEST_TEMP/project"
  assert_success
  local want
  want="$(_egress_create_digest "$CN" none "$(_egress_capdrop_canon NET_RAW)" 0)"
  run assert_docker_run_has "$CN" "--network none --cap-drop NET_RAW "
  assert_success
  run assert_docker_run_has "$CN" "--label sh.cleat.role=box --label sh.cleat.egress-hash=$want --label sh.cleat.egress-engine=desktop-macos "
  assert_success
  # The box keeps its setuid transition (sudo, [setup]) and gains nothing.
  local no
  for no in no-new-privileges --cap-add --privileged /etc/cleat-egress egress-rendered HTTPS_PROXY; do
    run assert_docker_run_lacks "$CN" "$no"
    assert_success
  done
}

@test "egress: a box without a policy keeps --add-host on a non-Desktop engine" {
  caged_create
  rm -f "$CLEAT_GLOBAL_CONFIG"
  rm -rf "$DOCKER_MOCK_DIR/inspect"
  _is_docker_desktop() { return 1; }
  run cmd_run "$TEST_TEMP/project"
  assert_success
  run assert_docker_run_has "$CN" "--add-host host.docker.internal:host-gateway"
  assert_success
}

@test "egress: a caged create makes the volume, the policy, the gateway and the box in that order" {
  caged_create
  docker() {
    if [ "$1" = run ] && [[ " $* " == *" --name $GW "* ]]; then
      if [ -f "$CLEAT_CONFIG_DIR/egress-rendered/$BH/policy.json" ]; then echo rendered >> "$TEST_TEMP/seen"; fi
    fi
    command docker "$@"
  }
  run cmd_run "$TEST_TEMP/project"
  assert_success
  local order
  order="$(grep -n "^docker image inspect $_GATEWAY_IMAGE\|^docker volume create\|^docker run -d --name $GW \|^docker run -d --name $CN " "$DOCKER_CALLS" \
    | sed -e "s|^[0-9]*:docker image inspect.*|image|" -e "s|^[0-9]*:docker volume create.*|volume|" \
          -e "s|^[0-9]*:docker run -d --name $GW .*|gateway|" -e "s|^[0-9]*:docker run -d --name $CN .*|box|" | tr '\n' ' ')"
  [ "$order" = "image volume gateway box " ]
  run cat "$TEST_TEMP/seen"
  assert_output "rendered"
}

@test "egress: the create marker is written before the volume and removed only after the first gate passes" {
  caged_create
  docker() {
    if [ "$1" = volume ] && [ "$2" = create ] && [ -f "$CLEAT_RUN_DIR/$CN/egress/creating" ]; then
      echo marked >> "$TEST_TEMP/seen"
    fi
    command docker "$@"
  }
  run cmd_run "$TEST_TEMP/project"
  assert_success
  run cat "$TEST_TEMP/seen"
  assert_output "marked"
  [ ! -e "$CLEAT_RUN_DIR/$CN/egress/creating" ]
  # A gate that refuses leaves the marker for the teardown its remedy runs.
  rm -rf "$DOCKER_MOCK_DIR/inspect" "$DOCKER_MOCK_DIR/volume_inspect"
  F_HEALTH_SEQ=unhealthy caged_box
  : > "$DOCKER_CALLS"
  run cmd_run "$TEST_TEMP/project"
  assert_failure
  assert_output --partial "gateway is not healthy"
  [ -f "$CLEAT_RUN_DIR/$CN/egress/creating" ]
}

@test "egress: a caged create that cannot make its gateway creates no box" {
  caged_create
  # The gateway image cannot be pulled: nothing at all is made.
  rm -f "$DOCKER_MOCK_DIR/cached_images"
  run cmd_run "$TEST_TEMP/project"
  assert_failure
  assert_output --partial "could not be pulled"
  run grep -cE "^docker (volume create|run )" "$DOCKER_CALLS"
  assert_output "0"
  # The volume cannot be made: no gateway, no box, the marker gone.
  mock_docker_image_cached "$_GATEWAY_IMAGE"
  : > "$DOCKER_CALLS"
  export DOCKER_VOLUME_EXIT_CODE=1
  run cmd_run "$TEST_TEMP/project"
  assert_failure
  assert_output --partial "could not create its egress socket volume"
  run grep -c "^docker run " "$DOCKER_CALLS"
  assert_output "0"
  [ ! -e "$CLEAT_RUN_DIR/$CN/egress/creating" ]
  unset DOCKER_VOLUME_EXIT_CODE
  # The gateway does not start: no box, and the volume and the policy go.
  : > "$DOCKER_CALLS"
  docker() {
    if [ "$1" = run ] && [[ " $* " == *" --name $GW "* ]]; then
      echo "docker $*" >> "$DOCKER_CALLS"
      echo "port is already allocated" >&2
      return 125
    fi
    command docker "$@"
  }
  run cmd_run "$TEST_TEMP/project"
  assert_failure
  assert_output --partial "its egress gateway did not start"
  assert_output --partial "port is already allocated"
  run docker_run_line_for "$CN"
  assert_output ""
  # The pre-clear removes the volume once before the create. The cleanup
  # removes it again after the failed gateway run.
  local gn vn
  gn="$(grep -nF -- "--name $GW " "$DOCKER_CALLS" | tail -1 | cut -d: -f1)"
  vn="$(grep -n "^docker volume rm $VOL" "$DOCKER_CALLS" | tail -1 | cut -d: -f1)"
  [ "$vn" -gt "$gn" ]
  [ ! -e "$CLEAT_CONFIG_DIR/egress-rendered/$BH" ]
}

@test "egress gateway: an unvalidated engine creates nothing" {
  caged_create
  _egress_engine_kind() { printf 'engine-linux'; }
  run cmd_run "$TEST_TEMP/project"
  assert_failure
  assert_output --partial "not validated on this Docker engine"
  run grep -cE "^docker (image inspect|pull|volume create|run )" "$DOCKER_CALLS"
  assert_output "0"
  [ ! -e "$CLEAT_RUN_DIR/$CN/egress/creating" ]
}

@test "egress: a caged create refuses a box image older than the relay and creates nothing" {
  caged_create
  local old
  for old in 5 "" x; do
    : > "$DOCKER_CALLS"
    eval "_image_spec_version() { printf '%s' '$old'; }"
    run cmd_run "$TEST_TEMP/project"
    assert_failure
    assert_output --partial "predates the relay"
    assert_output --partial "cleat rebuild"
    run grep -cE "^docker (volume create|run )" "$DOCKER_CALLS"
    assert_output "0"
  done
}

@test "egress gateway: a fork box creates its own gateway" {
  caged_create
  local fork_cn fork_bh main_gw
  main_gw="$GW"
  fork_cn="$(container_name_for "$TEST_TEMP/project" review)"
  fork_bh="$(_egress_box_hash "$fork_cn")"
  [ "$fork_bh" != "$BH" ]
  CN="$fork_cn"; egress_box_names
  caged_box
  _BOX=review
  _box_is_fork() { return 0; }
  _fork_dir() { printf '%s' "$TEST_TEMP/forks/review"; }
  mkdir -p "$TEST_TEMP/forks/review"
  run cmd_run "$TEST_TEMP/project"
  assert_success
  run assert_docker_run_has "cleat-gw-$fork_bh" "--label sh.cleat.gateway-for=$fork_bh "
  assert_success
  run docker_run_line_for "$main_gw"
  assert_output ""
}

@test "egress gateway: the label the create path writes is the one the gate accepts" {
  caged_create
  run cmd_run "$TEST_TEMP/project"
  assert_success
  local label
  label="$(docker_run_line_for "$CN" | grep -o 'sh.cleat.egress-hash=[^ ]*' | cut -d= -f2)"
  [ -n "$label" ]
  rm -rf "$DOCKER_MOCK_DIR/inspect" "$DOCKER_MOCK_DIR/volume_inspect"
  F_HASH="LABEL=$label" caged_box
  run _egress_require "$CN" start
  assert_success
}

@test "egress gateway: a caged box's config hash carries its five egress facts" {
  caged_create
  run cmd_run "$TEST_TEMP/project"
  assert_success
  local want plain
  want="$(_EGRESS_FP_CAGED=1 compute_config_fingerprint "$TEST_TEMP/project" "$CN")"
  plain="$(_EGRESS_FP_CAGED=0 compute_config_fingerprint "$TEST_TEMP/project" "$CN")"
  [ "$want" != "$plain" ]
  run assert_docker_run_has "$CN" "--label sh.cleat.config-hash=v2:$want "
  assert_success
}

# ── Health readers (8.6, 8.10) ──────────────────────────────────────────────

@test "egress: the shim assertion fails when the relay is not listening" {
  CN=cleat-demo-3f2a9104
  egress_box_names
  use_gw_admin_stub
  local age
  for age in 12 90; do
    mock_gw_admin last_shim_seen "ok last_shim_seen $age"
    run _egress_shim_alive "$GW"
    assert_success
  done
  for age in 91 300 -1; do
    mock_gw_admin last_shim_seen "ok last_shim_seen $age"
    run _egress_shim_alive "$GW"
    assert_failure
  done
  # An error line, and no answer at all.
  mock_gw_admin last_shim_seen "err last_shim_seen not-ready"
  run _egress_shim_alive "$GW"
  assert_failure
  mock_gw_admin last_shim_seen ""
  run _egress_shim_alive "$GW"
  assert_failure
}

@test "egress: a healthy gateway with no running box is reported as orphaned" {
  CN=cleat-demo-3f2a9104
  egress_box_names
  use_gw_admin_stub
  mock_gw_admin path_ok "ok path_ok true"
  container_exists() { [ "$1" = "$GW" ]; }
  is_running() { [ "$1" = "$GW" ]; }
  run _egress_gateway_state "$CN"
  assert_output "orphaned"
}

@test "egress: the gateway state names missing, stopped, displaced and healthy" {
  CN=cleat-demo-3f2a9104
  egress_box_names
  use_gw_admin_stub
  container_exists() { return 1; }
  run _egress_gateway_state "$CN"
  assert_output "missing"
  container_exists() { return 0; }
  is_running() { [ "$1" = "$CN" ]; }
  run _egress_gateway_state "$CN"
  assert_output "stopped"
  is_running() { return 0; }
  mock_gw_admin path_ok "ok path_ok false"
  run _egress_gateway_state "$CN"
  assert_output "displaced"
  # A gateway that cannot answer is displaced too: the fail-closed word.
  mock_gw_admin path_ok ""
  run _egress_gateway_state "$CN"
  assert_output "displaced"
  mock_gw_admin path_ok "ok path_ok true"
  run _egress_gateway_state "$CN"
  assert_output "healthy"
}

# ── The proxy environment (3.1) ─────────────────────────────────────────────

# A caged box, running, whose gate passes: exec_claude, cmd_shell and
# cmd_login run against it through the stub.
caged_running() {
  caged_create
  mock_docker_ps "$CN"
  mock_docker_ps_a "$CN"
  _RESOLVED_PROJECT="$TEST_TEMP/project"
  _is_interactive() { return 0; }
  _wait_for_coder_remap() { true; }
}

proxy_env_on() {                         # <cname>
  local v
  for v in "HTTPS_PROXY=http://127.0.0.1:3128" "https_proxy=http://127.0.0.1:3128" \
    "http_proxy=http://127.0.0.1:3128" "NO_PROXY=localhost,127.0.0.1,::1" "no_proxy=localhost,127.0.0.1,::1"; do
    run assert_docker_exec_has "$1" "-e $v "
    assert_success
  done
}

@test "egress gateway: a caged box's exec carries the proxy environment" {
  caged_running
  run exec_claude "$CN" --dangerously-skip-permissions
  assert_success
  run grep "^docker exec -it .* $CN " "$DOCKER_CALLS"
  assert_success
  proxy_env_on "$CN"
}

@test "egress gateway: cleat shell and cleat login into a caged box carry the proxy environment" {
  caged_running
  run cmd_shell "$TEST_TEMP/project"
  assert_success
  proxy_env_on "$CN"
  : > "$DOCKER_CALLS"
  run cmd_login "$TEST_TEMP/project"
  proxy_env_on "$CN"
}

@test "egress gateway: the proxy environment is added once however many gates pass" {
  caged_running
  _egress_require "$CN" claude
  _egress_proxy_env_add
  _egress_require "$CN" claude
  _egress_proxy_env_add
  run bash -c 'printf "%s\n" "$@" | grep -c "^HTTPS_PROXY="' _ "${CLAUDE_ENV[@]}"
  assert_output "1"
  # A gate that did not pass adds nothing.
  CLAUDE_ENV=(-e HOME=/home/coder)
  rm -f "$CLEAT_GLOBAL_CONFIG"
  _egress_require "$CN" claude || true
  _egress_proxy_env_add
  run printf '%s ' "${CLAUDE_ENV[@]}"
  assert_output "-e HOME=/home/coder "
}

@test "egress gateway: a caged box's setup payload carries the proxy environment" {
  caged_running
  _SETUP_DECLARED=1; _SETUP_TRUSTED=1
  _build_setup_payload() { printf 'curl -fsS https://docs.example.test\n'; }
  _setup_payload_hash() { printf 'h1'; }
  _trust_lookup_setup() { printf 'h1'; }
  run _maybe_run_setup "$CN" "$TEST_TEMP/project" main 1
  assert_success
  run grep "^docker exec .*-w /workspace $CN runuser -u coder -- bash -e" "$DOCKER_CALLS"
  assert_success
  [[ "$output" == *"-e HOME=/home/coder -e HTTPS_PROXY=http://127.0.0.1:3128 "* ]]
  [[ "$output" == *"-e no_proxy=localhost,127.0.0.1,::1 -w /workspace "* ]]
}

# ── Teardown and stop at the removal and stop sites (8.7) ───────────────────

# The recorded order of this box's gateway rm, box rm and volume rm.
teardown_order() {
  grep -E "^docker (rm -f|volume rm) " "$DOCKER_CALLS" \
    | sed -e "s|^docker rm -f $GW\$|gateway|" -e "s|^docker rm -f $CN\$|box|" -e "s|^docker volume rm $VOL\$|volume|" \
    | tr '\n' ' '
}

# A caged box, existing and stopped, for the site families below.
site_box() {
  teardown_box
  mock_docker_ps ""
  mock_docker_ps_a "$CN"
}

@test "egress: teardown removes the gateway before the box at every removal family" {
  # A recreate prompt: the config drift accept path on a terminal.
  site_box
  _container_config_hash() { echo "v2:old"; }
  _is_tty() { return 0; }
  run _resolve_config_drift "$CN" "$TEST_TEMP" <<< "y"
  assert_success
  run teardown_order
  assert_output "gateway box volume "
  # A host-path recreate: cmd_start on a box whose bind sources moved.
  site_box
  : > "$DOCKER_CALLS"
  mkdir -p "$TEST_TEMP/p1"
  _container_bind_sources_present() { return 1; }
  cmd_run() { echo "recreated" >> "$TEST_TEMP/recreated"; }
  container_name_for() { printf '%s' "$CN"; }
  _resolve_config_drift() { true; }
  exec_claude() { true; }
  run cmd_start "$TEST_TEMP/p1"
  run teardown_order
  assert_output "gateway box volume "
  # Removal for good: cmd_rm.
  site_box
  : > "$DOCKER_CALLS"
  run cmd_rm "$TEST_TEMP/p1"
  assert_success
  run teardown_order
  assert_output "gateway box volume "
}

@test "egress gateway: cmd_rm removes the per-box override" {
  site_box
  mkdir -p "$TEST_TEMP/p1"
  container_name_for() { printf '%s' "$CN"; }
  run cmd_rm "$TEST_TEMP/p1"
  assert_success
  [ ! -e "$CLEAT_CONFIG_DIR/egress-boxes/$CN" ]
  [ ! -e "$CLEAT_CONFIG_DIR/egress-boxes/$CN.session" ]
  [ ! -e "$CLEAT_CONFIG_DIR/egress-pins/$CN" ]
  [ ! -e "$CLEAT_CONFIG_DIR/egress-rendered/$BH" ]
}

@test "egress gateway: a recreate keeps the per-box policy file and the pin" {
  site_box
  local before
  before="$(cat "$CLEAT_CONFIG_DIR/egress-boxes/$CN" "$CLEAT_CONFIG_DIR/egress-pins/$CN" "$CLEAT_CONFIG_DIR/egress-notices/$CN")"
  # The drift accept path on a terminal, answered with Enter.
  _container_config_hash() { echo "v2:old"; }
  _is_tty() { return 0; }
  run _resolve_config_drift "$CN" "$TEST_TEMP" <<< ""
  assert_success
  assert_output --partial "Removed"
  run cat "$CLEAT_CONFIG_DIR/egress-boxes/$CN" "$CLEAT_CONFIG_DIR/egress-pins/$CN" "$CLEAT_CONFIG_DIR/egress-notices/$CN"
  assert_output "$before"
  [ ! -e "$CLEAT_CONFIG_DIR/egress-boxes/$CN.session" ]
  # The host-paths recreate in cmd_start, which asks nothing at all.
  printf 'started\n' > "$CLEAT_CONFIG_DIR/egress-boxes/$CN.session"
  mkdir -p "$TEST_TEMP/p1"
  _container_bind_sources_present() { return 1; }
  cmd_run() { true; }
  container_name_for() { printf '%s' "$CN"; }
  _resolve_config_drift() { true; }
  exec_claude() { true; }
  run cmd_start "$TEST_TEMP/p1"
  run cat "$CLEAT_CONFIG_DIR/egress-boxes/$CN" "$CLEAT_CONFIG_DIR/egress-pins/$CN" "$CLEAT_CONFIG_DIR/egress-notices/$CN"
  assert_output "$before"
  [ ! -e "$CLEAT_CONFIG_DIR/egress-boxes/$CN.session" ]
}

@test "egress: cleat stop stops the gateway after the box and keeps what a start needs" {
  teardown_box
  mock_docker_ps "$CN"
  mkdir -p "$TEST_TEMP/p1"
  container_name_for() { printf '%s' "$CN"; }
  run cmd_stop "$TEST_TEMP/p1"
  assert_success
  run grep -n "^docker stop " "$DOCKER_CALLS"
  assert_output "$(printf '1:docker stop %s\n2:docker stop %s' "$CN" "$GW")"
  [ -f "$CLEAT_CONFIG_DIR/egress-rendered/$BH/policy.json" ]
  [ -f "$CLEAT_CONFIG_DIR/egress-boxes/$CN" ]
  run grep -c "^docker volume rm\|^docker rm" "$DOCKER_CALLS"
  assert_output "0"
  # A box already down still has its orphaned gateway stopped.
  mock_docker_ps ""
  : > "$DOCKER_CALLS"
  run cmd_stop "$TEST_TEMP/p1"
  run cat "$DOCKER_CALLS"
  assert_output "docker stop $GW"
}

@test "egress open: the session marker is removed on stop" {
  teardown_box
  mock_docker_ps "$CN"
  mkdir -p "$TEST_TEMP/p1"
  container_name_for() { printf '%s' "$CN"; }
  run cmd_stop "$TEST_TEMP/p1"
  assert_success
  [ ! -e "$CLEAT_CONFIG_DIR/egress-boxes/$CN.session" ]
}

@test "egress: rm and stop add no docker call for a box with no rendered policy" {
  CN=cleat-demo-3f2a9104
  egress_box_names
  mkdir -p "$TEST_TEMP/p1"
  container_name_for() { printf '%s' "$CN"; }
  mock_docker_ps "$CN"
  mock_docker_ps_a "$CN"
  run cmd_stop "$TEST_TEMP/p1"
  run cat "$DOCKER_CALLS"
  assert_output "docker stop $CN"
  : > "$DOCKER_CALLS"
  run cmd_rm "$TEST_TEMP/p1"
  run grep -c "cleat-gw-" "$DOCKER_CALLS"
  assert_output "0"
}

# ── The start path (8.7) ────────────────────────────────────────────────────

# A caged box and its gateway, both stopped, whose bind sources are intact:
# cmd_start and cmd_resume take the docker start branch.
stopped_caged() {
  mock_egress_caged_launch
  mkdir -p "$TEST_TEMP/project"
  CN="$(container_name_for "$TEST_TEMP/project")"
  egress_box_names
  mock_docker_images "cleat"
  _host_clip_cmd() { echo ""; }
  container_exists() { return 0; }
  is_running() { return 1; }
  _settings_overlay_intact() { return 0; }
  _container_bind_sources_present() { return 0; }
  _history_bind_in_session_dir() { return 1; }
  _resolve_config_drift() { true; }
  exec_claude() { true; }
}

@test "egress: cleat start on a stopped caged box starts the gateway before the box" {
  stopped_caged
  F_HEALTH_SEQ="starting healthy" caged_box
  run cmd_start "$TEST_TEMP/project"
  assert_success
  local g b
  g="$(grep -n "^docker start $GW\$" "$DOCKER_CALLS" | cut -d: -f1)"
  b="$(grep -n "^docker start $CN\$" "$DOCKER_CALLS" | cut -d: -f1)"
  [ -n "$g" ] && [ -n "$b" ] && [ "$g" -lt "$b" ]
  # The policy was rendered before the gateway started: its bind source.
  [ -f "$(_egress_policy_dir "$CN")/policy.json" ]
}

@test "egress: cleat resume on a stopped caged box starts the gateway before the box" {
  stopped_caged
  F_HEALTH_SEQ="starting healthy" caged_box
  run cmd_resume "$TEST_TEMP/project"
  assert_success
  local g b
  g="$(grep -n "^docker start $GW\$" "$DOCKER_CALLS" | cut -d: -f1)"
  b="$(grep -n "^docker start $CN\$" "$DOCKER_CALLS" | cut -d: -f1)"
  [ -n "$g" ] && [ -n "$b" ] && [ "$g" -lt "$b" ]
}

@test "egress: a missing gateway refuses cleat start and names egress restart" {
  stopped_caged
  caged_box
  container_exists() { [ "$1" != "$GW" ]; }
  run cmd_start "$TEST_TEMP/project"
  assert_failure
  assert_output --partial "its gateway is missing"
  assert_output --partial "cleat egress restart"
  run grep -c "^docker start " "$DOCKER_CALLS"
  assert_output "0"
  # Never recreated in its place.
  run docker_run_line_for "$GW"
  assert_output ""
}

@test "egress: cleat start leaves a box that never had a gateway to check one" {
  stopped_caged
  F_HASH="" caged_box
  container_exists() { [ "$1" != "$GW" ]; }
  run cmd_start "$TEST_TEMP/project"
  assert_failure
  assert_output --partial "created before its egress policy"
  refute_output --partial "cleat egress restart"
  run grep -c "^docker start $CN\$" "$DOCKER_CALLS"
  assert_output "1"
  run grep -c "^docker start cleat-gw-" "$DOCKER_CALLS"
  assert_output "0"
}

@test "egress: cleat claude never starts a gateway stopped under a running box" {
  stopped_caged
  F_GW="false|gateway|$BH" caged_box
  is_running() { [ "$1" = "$CN" ]; }
  run cmd_claude "$TEST_TEMP/project"
  assert_failure
  assert_output --partial "gateway is missing, stopped or not this box's"
  run grep -c "^docker start " "$DOCKER_CALLS"
  assert_output "0"
}

# ── The idle sweep's gateway pass (8.8, 8.9) ────────────────────────────────

# A box's gateway as the two enumerations answer it, each for its own filter,
# and no running box for the sweep's own loop.
sweep_setup() {
  CN=cleat-proj-abcdef12
  egress_box_names
  _running_cleat_boxes() { :; }
  mkdir -p "$CLEAT_CONFIG_DIR/egress-rendered/$BH"
  mock_docker_inspect_field "$GW" "$T_HEALTH" healthy
}
sweep_gws() { mock_docker_ps_filter "$1" "label=sh.cleat.role=gateway"; }
sweep_boxes() { mock_docker_ps_filter "$1" "label=sh.cleat.version"; }
acted() { grep -cE "^docker (stop|rm -f|volume rm) (cleat-gw-|$VOL)" "$DOCKER_CALLS" || true; }

@test "egress: the idle sweep stops a gateway whose box is stopped" {
  sweep_setup
  sweep_gws "$GW|$BH|running"
  sweep_boxes "$CN|exited"
  run _sweep_idle_boxes ""
  assert_success
  assert_output ""
  run grep -c "^docker stop $GW\$" "$DOCKER_CALLS"
  assert_output "1"
  # Stopped, never removed: a start brings it back.
  run grep -c "^docker rm -f $GW\|^docker volume rm" "$DOCKER_CALLS"
  assert_output "0"
}

@test "egress: the idle sweep never stops a gateway whose box is running" {
  sweep_setup
  sweep_gws "$GW|$BH|running"
  local st
  for st in running restarting paused; do
    sweep_boxes "$CN|$st"
    : > "$DOCKER_CALLS"
    run _sweep_idle_boxes ""
    run acted
    assert_output "0"
  done
}

@test "egress: the idle sweep never stops a starting gateway whose box is stopped" {
  sweep_setup
  rm -rf "$DOCKER_MOCK_DIR/inspect"
  mock_docker_inspect_field "$GW" "$T_HEALTH" starting
  sweep_gws "$GW|$BH|running"
  sweep_boxes "$CN|exited"
  run _sweep_idle_boxes ""
  run acted
  assert_output "0"
}

@test "egress: the idle sweep never stops the gateway of the box being launched" {
  sweep_setup
  sweep_gws "$GW|$BH|running"
  sweep_boxes "$CN|exited"
  run _sweep_idle_boxes "$CN"
  run acted
  assert_output "0"
  # And with no box at all yet: the launch is creating it.
  sweep_boxes ""
  run _sweep_idle_boxes "$CN"
  run acted
  assert_output "0"
}

@test "egress: the idle sweep skips a gateway inside the create window" {
  sweep_setup
  sweep_gws "$GW|$BH|running"
  sweep_boxes ""
  mkdir -p "$CLEAT_RUN_DIR/$CN/egress"
  : > "$CLEAT_RUN_DIR/$CN/egress/creating"
  run _sweep_idle_boxes ""
  run acted
  assert_output "0"
  [ -d "$CLEAT_CONFIG_DIR/egress-rendered/$BH" ]
}

@test "egress: the idle sweep removes an orphaned gateway with its volume" {
  sweep_setup
  sweep_gws "$GW|$BH|running"
  sweep_boxes ""
  run _sweep_idle_boxes ""
  assert_output ""
  run grep -c "^docker rm -f $GW\$" "$DOCKER_CALLS"
  assert_output "1"
  run grep -c "^docker volume rm $VOL\$" "$DOCKER_CALLS"
  assert_output "1"
  [ ! -e "$CLEAT_CONFIG_DIR/egress-rendered/$BH" ]
}

@test "egress: the idle sweep finds a creating box's marker through its run dir" {
  # A marker older than the window is an orphan like any other, and goes with it.
  sweep_setup
  sweep_gws "$GW|$BH|running"
  sweep_boxes ""
  mkdir -p "$CLEAT_RUN_DIR/$CN/egress"
  touch -t 200001010000 "$CLEAT_RUN_DIR/$CN/egress/creating"
  run _sweep_idle_boxes ""
  run grep -c "^docker rm -f $GW\$" "$DOCKER_CALLS"
  assert_output "1"
  [ ! -e "$CLEAT_RUN_DIR/$CN/egress/creating" ]
}

@test "egress: the idle sweep acts on nothing when an enumeration fails" {
  sweep_setup
  sweep_gws "$GW|$BH|running"
  sweep_boxes ""
  export DOCKER_PS_EXIT_CODE=1
  run _sweep_idle_boxes ""
  run acted
  assert_output "0"
  unset DOCKER_PS_EXIT_CODE
  # Only the box list failing: a gateway that looks orphaned is not removed.
  docker() {
    if [ "$1" = ps ] && [[ " $* " == *" label=sh.cleat.version "* ]]; then return 1; fi
    command docker "$@"
  }
  : > "$DOCKER_CALLS"
  run _sweep_idle_boxes ""
  run acted
  assert_output "0"
}

@test "egress: the idle sweep ignores a gateway label that is not a box hash" {
  # Every container run from the gateway image inherits its role label, a
  # hand-run debug container included.
  sweep_setup
  sweep_gws "$(printf 'cleat-gw-debug||running\ncleat-gw-x|NOT12HEX|running')"
  sweep_boxes ""
  run _sweep_idle_boxes ""
  run grep -c "^docker rm -f\|^docker stop" "$DOCKER_CALLS"
  assert_output "0"
}

@test "egress: the idle sweep removes a dangling socket volume outside the create window and keeps one inside it" {
  sweep_setup
  sweep_gws "cleat-gw-ffffffffffff|ffffffffffff|running"
  sweep_boxes "cleat-other-11111111|running"
  printf '%s|%s\n' "$VOL" "$BH" > "$DOCKER_MOCK_DIR/volume_ls_output"
  mkdir -p "$CLEAT_RUN_DIR/$CN/egress"
  : > "$CLEAT_RUN_DIR/$CN/egress/creating"
  run _sweep_idle_boxes ""
  run grep -c "^docker volume rm $VOL\$" "$DOCKER_CALLS"
  assert_output "0"
  rm -f "$CLEAT_RUN_DIR/$CN/egress/creating"
  : > "$DOCKER_CALLS"
  run _sweep_idle_boxes ""
  run grep -c "^docker volume rm $VOL\$" "$DOCKER_CALLS"
  assert_output "1"
}

@test "egress: a sweep on a machine with no gateway makes one docker call" {
  _running_cleat_boxes() { :; }
  : > "$DOCKER_CALLS"
  run _sweep_idle_boxes ""
  run cat "$DOCKER_CALLS"
  assert_output "docker ps -a --filter label=sh.cleat.role=gateway --format {{.Names}}|{{.Label \"sh.cleat.gateway-for\"}}|{{.State}}"
}

# ── The denial log, read host-side (8.4) ────────────────────────────────────

# A gateway whose denial log holds <rows>, as docker cp would copy it out.
seed_denials() {                         # <rows>
  CN=cleat-demo-3f2a9104
  egress_box_names
  use_gw_admin_stub
  mkdir -p "$DOCKER_MOCK_DIR/cp/$GW"
  printf '%b' "$1" > "$DOCKER_MOCK_DIR/cp/$GW/denials.log"
}
ROW1='2026-09-26T10:00:00Z code=policy sub=- origin=box host=pastebin.example port=443 trunc=0\n'
ROW2='2026-09-26T10:00:05Z code=sni sub=sni-mismatch origin=box host=github.com port=443 trunc=0\n'

@test "egress log: the denial log is read by docker cp out of the gateway" {
  seed_denials "$ROW1"
  run _egress_denials_copy "$CN"
  assert_success
  run grep -c "^docker cp $GW:/run/cleat-egress/denials.log " "$DOCKER_CALLS"
  assert_output "1"
  run grep -c "^docker exec" "$DOCKER_CALLS"
  assert_output "0"
  run cat "$CLEAT_RUN_DIR/$CN/egress/denials.log"
  assert_output "${ROW1%\\n}"
  # No temp copy is left behind.
  run bash -c 'ls -A "$1" | grep -c "^\.denials"' _ "$CLEAT_RUN_DIR/$CN/egress"
  assert_output "0"
}

@test "egress log: a copy is never written through a link" {
  seed_denials "$ROW1"
  mkdir -p "$TEST_TEMP/elsewhere" "$CLEAT_RUN_DIR/$CN"
  ln -s "$TEST_TEMP/elsewhere" "$CLEAT_RUN_DIR/$CN/egress"
  run _egress_denials_copy "$CN"
  assert_failure
  run ls -A "$TEST_TEMP/elsewhere"
  assert_output ""
  # The box's whole run dir a link: the egress dir made under it would be real.
  rm -f "$CLEAT_RUN_DIR/$CN/egress"
  rmdir "$CLEAT_RUN_DIR/$CN"
  ln -s "$TEST_TEMP/elsewhere" "$CLEAT_RUN_DIR/$CN"
  run _egress_denials_copy "$CN"
  assert_failure
  run ls -A "$TEST_TEMP/elsewhere"
  assert_output ""
}

@test "egress log: a down daemon or a missing gateway reads as no rows" {
  seed_denials "$ROW1"
  export DOCKER_CP_EXIT_CODE=1
  run _egress_denials_copy "$CN"
  assert_failure
  assert_output ""
  [ ! -e "$CLEAT_RUN_DIR/$CN/egress/denials.log" ]
  run _egress_denials_rows "$CLEAT_RUN_DIR/$CN/egress/denials.log" 0
  assert_success
  assert_output ""
}

@test "egress log: a line with no leading timestamp is skipped" {
  seed_denials "junk line\n${ROW1}code=policy host=x.example\n10:00:00Z code=policy sub=- origin=box host=y.example port=443 trunc=0\n${ROW2}"
  _egress_denials_copy "$CN"
  run _egress_denials_rows "$CLEAT_RUN_DIR/$CN/egress/denials.log" 0
  assert_output "${ROW1%\\n}
${ROW2%\\n}"
}

@test "egress log: a row with a replaced byte renders as truncated" {
  seed_denials '2026-09-26T10:00:00Z code=policy sub=- origin=box host=pa\xc3\xa9stebin.example port=443 trunc=0\n2026-09-26T10:00:01Z code=policy sub=- origin=box host=UP.example port=443 trunc=0\n2026-09-26T10:00:02Z code=policy sub=- origin=box host=a\033[31m.example port=443 trunc=0\n'
  _egress_denials_copy "$CN"
  run _egress_denials_rows "$CLEAT_RUN_DIR/$CN/egress/denials.log" 0
  assert_line --index 0 "2026-09-26T10:00:00Z code=policy sub=- origin=box host=pa??stebin.example port=443 trunc=1"
  assert_line --index 1 "2026-09-26T10:00:01Z code=policy sub=- origin=box host=??.example port=443 trunc=1"
  refute_output --partial $'\033'
}

@test "egress log: a row that names another origin is still the box's" {
  seed_denials '2026-09-26T10:00:00Z code=policy sub=- origin=user host=x.example port=443 trunc=0\n2026-09-26T10:00:01Z code=newcode sub=- origin=box host=y.example port=443 trunc=0\n'
  _egress_denials_copy "$CN"
  run _egress_denials_rows "$CLEAT_RUN_DIR/$CN/egress/denials.log" 0
  assert_line --index 0 "2026-09-26T10:00:00Z code=policy sub=- origin=box host=x.example port=443 trunc=0"
  # A code this CLI does not know is kept, so it renders as itself.
  assert_line --index 1 --partial "code=newcode"
}

@test "egress log: an offset past the end of the file rereads from zero" {
  seed_denials "$ROW1$ROW2"
  _egress_denials_copy "$CN"
  local f="$CLEAT_RUN_DIR/$CN/egress/denials.log" size
  size="$(_path_size "$f")"
  mock_gw_admin log-state "ok log-state 7 $size"
  run _egress_denials_window "$GW" "7:$(( size + 50 ))" "$f"
  assert_output "0"
  # Inside the file, at the same generation, the mark stands.
  run _egress_denials_window "$GW" "7:10" "$f"
  assert_output "10"
}

@test "egress log: a generation change rereads from zero" {
  seed_denials "$ROW1$ROW2"
  _egress_denials_copy "$CN"
  local f="$CLEAT_RUN_DIR/$CN/egress/denials.log"
  # A higher generation with a size above the mark: the log wrapped and grew.
  mock_gw_admin log-state "ok log-state 8 9999"
  run _egress_denials_window "$GW" "7:10" "$f"
  assert_output "0"
  run _egress_denials_rows "$f" "$output"
  assert_output "${ROW1%\\n}
${ROW2%\\n}"
  # An admin socket that cannot answer rereads too: duplicates, never silence.
  mock_gw_admin log-state ""
  run _egress_denials_window "$GW" "7:10" "$f"
  assert_output "0"
}

@test "egress log: the session mark is one log-state read, saved beside the copy" {
  CN=cleat-demo-3f2a9104
  egress_box_names
  use_gw_admin_stub
  mock_gw_admin log-state "ok log-state 1790000000123 512"
  _egress_denials_mark "$CN"
  [ "$_EG_MARK_GEN" = 1790000000123 ] && [ "$_EG_MARK_OFF" = 512 ]
  run _egress_denials_mark_read "$CN"
  assert_output "1790000000123:512"
  run count_calls "gw-admin log-state"
  assert_output "1"
  # Anything but two numbers leaves no mark, and a reader then reads all.
  mock_gw_admin log-state "ok log-state x 512"
  _egress_denials_mark "$CN"
  [ -z "$_EG_MARK_GEN" ] && [ "$_EG_MARK_OFF" = 0 ]
}

@test "egress log: allowed connections come from the gateway's own output" {
  CN=cleat-demo-3f2a9104
  egress_box_names
  mkdir -p "$DOCKER_MOCK_DIR/logs"
  printf '%s\n' "cleat-gw: serving v1:abc, mode strict, 5 hosts" \
    "2026-09-26T10:00:00Z allow host=api.anthropic.com port=443 trunc=0" \
    "2026-09-26T10:00:01Z allow host=x\"y.example port=443 trunc=0" \
    "not a row" > "$DOCKER_MOCK_DIR/logs/$GW"
  run _egress_allow_rows "$CN"
  assert_output "2026-09-26T10:00:00Z allow host=api.anthropic.com port=443 trunc=0
2026-09-26T10:00:01Z allow host=x?y.example port=443 trunc=1"
  run grep -c "^docker logs $GW" "$DOCKER_CALLS"
  assert_output "1"
  : > "$DOCKER_CALLS"
  run _egress_allow_rows "$CN" "2026-09-26T09:00:00Z"
  run grep -c "^docker logs --since 2026-09-26T09:00:00Z $GW" "$DOCKER_CALLS"
  assert_output "1"
}

@test "egress: the shared volume manifest rejects a third path" {
  run _egress_volume_manifest_ok "$(printf 'denials.log\nproxy.sock\n')"
  assert_success
  local bad
  for bad in "$(printf 'denials.log\nproxy.sock\npolicy.json\n')" "$(printf 'proxy.sock\n')" \
    "$(printf 'proxy.sock\npolicy.json\n')" \
    "$(printf 'denials.log\ndenials.log\n')" "$(printf 'denials.log\nproxy.sock\n.hidden\n')" ""; do
    run _egress_volume_manifest_ok "$bad"
    assert_failure
  done
}

@test "egress audit: the origin gate reads the copy the reader wrote" {
  # A name that came off a denial row is the box's choice: it meets the gate.
  seed_denials "$ROW1"
  run _egress_origin_gate pastebin.example
  assert_success
  _egress_denials_copy "$CN"
  run _egress_origin_gate pastebin.example
  assert_failure
  run _egress_origin_gate docs.example.test
  assert_success
}
