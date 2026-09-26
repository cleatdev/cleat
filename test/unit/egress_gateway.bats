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
