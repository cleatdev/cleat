#!/usr/bin/env bats
# ─────────────────────────────────────────────────────────────────────────────
# Integration: egress control against REAL Docker (EGRESS-SPEC.md 11.7).
#
# The file reads three facts from the shipped bin/cleat, never patches it,
# and takes one of three branches:
#
#   dormant   _EGRESS_ENFORCING is 0. A saved policy must create no gateway
#             object and the box keeps a normal network. Every case asserts
#             that, so the file lands before the flip and flips with it.
#   A         enforcement is live and this engine is not validated. Every case
#             asserts the refusal and that nothing was created. Ruling 9 ships
#             _EGRESS_VALIDATED_ENGINES="desktop-macos", so this is every CI
#             leg (engine-linux, rootless, vm-backend) and any run from inside
#             a Cleat box against Docker Desktop, which reads as desktop-linux.
#   B         enforcement is live on a validated engine: the ten cases of
#             11.7 and the two extras. Today that is the maintainer's Mac,
#             outside any box: ./test/integration/run.sh egress.bats
#
# No case ever skips. A skipped integration case reads as green and the job
# has no skip counter. An engine kind this file does not know fails it.
# CLEAT_INT_EXPECT_ENGINE, when set, pins the kind a CI leg must read, so a
# runner that drifts fails instead of quietly taking another branch.
#
# Teardown removes this test's objects by this box's hash only, never by the
# role label, which on a real machine would reap the user's own gateways.
# From inside a Cleat box, set TMPDIR to the repo's gitignored .egress-scratch
# dir so every bind the CLI makes lives on a path the Docker host can see.
# ─────────────────────────────────────────────────────────────────────────────

load "../setup"

_EG_KINDS=" desktop-macos desktop-windows desktop-linux engine-linux rootless vm-backend wsl-in-distro npipe-endpoint remote-endpoint windows-containers api-too-old unknown "

setup_file() {
  if ! command -v docker &>/dev/null; then
    skip "docker not available"
  fi
  if ! docker info &>/dev/null; then
    skip "docker daemon not reachable"
  fi
  local repo_root _build_log
  repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  # A failed build fails the file: a skip here would read as green.
  _build_log="$(docker build -q -t cleat -f "$repo_root/docker/Dockerfile" "$repo_root/docker/" 2>&1)" || {
    echo "# docker build failed, nothing below was tested:" >&3
    echo "$_build_log" | sed 's/^/#   /' >&3
    return 1
  }
  EG_ENFORCING="$(cli_call eval 'printf "%s" "$_EGRESS_ENFORCING"')"
  EG_KIND="$(cli_call _egress_engine_kind)"
  case "$_EG_KINDS" in
    *" $EG_KIND "*) ;;
    *) echo "# egress.bats does not know the engine kind '$EG_KIND'" >&3; return 1 ;;
  esac
  if [ -n "${CLEAT_INT_EXPECT_ENGINE:-}" ] && [ "$EG_KIND" != "$CLEAT_INT_EXPECT_ENGINE" ]; then
    echo "# this leg expects engine kind $CLEAT_INT_EXPECT_ENGINE and reads $EG_KIND" >&3
    return 1
  fi
  EG_VALID=0
  if cli_call _egress_engine_validated "$EG_KIND"; then EG_VALID=1; fi
  EG_WORDS="$(cli_call _egress_engine_words "$EG_KIND")"
  EG_GW_IMAGE="$(cli_call eval 'printf "%s" "$_GATEWAY_IMAGE"')"
  export EG_ENFORCING EG_KIND EG_VALID EG_WORDS EG_GW_IMAGE
  echo "# egress.bats: enforcing=$EG_ENFORCING kind=$EG_KIND validated=$EG_VALID" >&3
}

setup() {
  _common_setup
  INT_PROJECT="$TEST_TEMP/int-project"
  mkdir -p "$INT_PROJECT"
  export XDG_CONFIG_HOME="$TEST_TEMP/xdg"
  EG_CONF_DIR="$XDG_CONFIG_HOME/cleat"
  mkdir -p "$EG_CONF_DIR"
  printf '[egress]\nmode = strict\n' > "$EG_CONF_DIR/config"
  CN="$(int_cname)"
  BH="$(cli_call _egress_box_hash "$CN")"
  GW="cleat-gw-$BH"
  VOL="cleat-gw-$BH-sock"
  cd "$INT_PROJECT"
}

teardown() {
  local n h c
  # Every box of this project, then each box's gateway and socket volume by
  # that box's own hash. The main box's hash always, since its gateway can
  # outlive it.
  for n in $(docker ps -a --filter "name=^${CN}" --format '{{.Names}}' 2>/dev/null) "$CN"; do
    h="$(cli_call _egress_box_hash "$n")" || continue
    docker rm -f "$n" >/dev/null 2>&1 || true
    for c in $(docker ps -aq --filter "label=sh.cleat.gateway-for=${h}" 2>/dev/null); do
      docker rm -f "$c" >/dev/null 2>&1 || true
    done
    docker volume rm "cleat-gw-$h-sock" >/dev/null 2>&1 || true
  done
  _common_teardown
}

# ── The three branches ──────────────────────────────────────────────────────

# 0 only where the case itself can run: live enforcement on a validated engine.
eg_is_branch_b() { [ "$EG_ENFORCING" = 1 ] && [ "$EG_VALID" = 1 ]; }

# The assertion every case makes where it cannot run. Called at statement
# position, never on the left of || or &&, so a failing assert fails the test.
eg_other_branch() {
  if [ "$EG_ENFORCING" = 1 ]; then
    eg_assert_refused
  else
    eg_assert_dormant
  fi
}

eg_nothing_created() {
  run docker ps -aq --filter "name=^${GW}$"
  assert_output ""
  run docker volume ls -q --filter "name=^${VOL}$"
  assert_output ""
  [ ! -e "$EG_CONF_DIR/egress-rendered/$BH" ]
}

eg_assert_dormant() {
  run "$CLI" run
  assert_success
  eg_nothing_created
  run docker inspect -f '{{.HostConfig.NetworkMode}}' "$CN"
  assert_success
  refute_output "none"
}

eg_assert_refused() {
  run "$CLI" run
  assert_failure
  case "$EG_KIND" in
    engine-linux|desktop-windows)
      assert_output --partial "Egress control is not validated on this Docker engine yet"
      assert_output --partial "validated on Docker Desktop on macOS."
      assert_output --partial "docs/egress-validation.md" ;;
    *)
      assert_output --partial "Egress control is not available on this Docker engine"
      assert_output --partial "Needed:  Docker Desktop on macOS"
      refute_output --partial "Needed:  Docker Engine on Linux (rootful)" ;;
  esac
  assert_output --partial "cleat egress off"
  refute_output --partial "cleat egress open"
  run docker ps -aq --filter "name=^${CN}$"
  assert_output ""
  eg_nothing_created
}

# ── Branch B helpers ────────────────────────────────────────────────────────

# A caged box of this project, up, with its relay listening.
eg_caged_up() {
  run "$CLI" run
  assert_success
  run docker inspect -f '{{.HostConfig.NetworkMode}}' "$CN"
  assert_output "none"
  eg_wait_relay
}

eg_wait_relay() {
  local i
  for i in $(seq 1 40); do
    if docker exec "$CN" bash -c 'exec 3<>/dev/tcp/127.0.0.1/3128' >/dev/null 2>&1; then return 0; fi
    sleep 0.5
  done
  echo "# the relay never listened on 127.0.0.1:3128" >&3
  return 1
}

# An HTTPS request from inside the box through the relay: the status code.
eg_box_curl() {                          # <url>
  docker exec "$CN" curl -sS -o /dev/null -w '%{http_code}' --max-time 30 \
    --proxy http://127.0.0.1:3128 "$1" 2>/dev/null
}

eg_health() { docker inspect -f '{{.State.Health.Status}}' "$1" 2>/dev/null; }

eg_wait_health() {                       # <container> <status> <seconds>
  local i
  for i in $(seq 1 "$3"); do
    [ "$(eg_health "$1")" = "$2" ] && return 0
    sleep 1
  done
  echo "# $1 never read $2 within $3 s (last: $(eg_health "$1"))" >&3
  return 1
}

# ── Branch A: an engine that is not validated ───────────────────────────────

@test "egress integration: an unvalidated engine refuses a caged launch and creates nothing" {
  if [ "$EG_ENFORCING" != 1 ] || [ "$EG_VALID" = 1 ]; then eg_other_branch_or_b; return 0; fi
  eg_assert_refused
}

@test "egress integration: cleat egress status runs on a refused engine" {
  if [ "$EG_ENFORCING" != 1 ] || [ "$EG_VALID" = 1 ]; then eg_other_branch_or_b; return 0; fi
  run "$CLI" egress status
  assert_success
  assert_output --partial "$EG_WORDS"
}

# On a leg where Branch A cannot run: the dormant assertion before the flip,
# a caged launch that succeeds on a validated engine.
eg_other_branch_or_b() {
  if [ "$EG_ENFORCING" != 1 ]; then
    eg_assert_dormant
  else
    eg_caged_up
  fi
}

# ── Branch B: the ten cases of 11.7 ─────────────────────────────────────────

@test "egress integration: an allowed host over 443 succeeds and the gateway runs unprivileged" {
  if ! eg_is_branch_b; then eg_other_branch; return 0; fi
  eg_caged_up
  run eg_box_curl https://api.anthropic.com/
  refute_output "000"
  refute_output ""
  run docker exec "$GW" python3 -c "print(open('/proc/1/status').read())"
  assert_success
  assert_output --regexp $'Uid:\t[1-9]'
  assert_output --partial $'CapPrm:\t0000000000000000'
  assert_output --partial $'CapEff:\t0000000000000000'
  run docker exec "$GW" /usr/local/bin/gw-admin policy-digest
  assert_output --partial "ok policy-digest v1:"
}

@test "egress integration: a denied host fails with a message naming the policy" {
  if ! eg_is_branch_b; then eg_other_branch; return 0; fi
  eg_caged_up
  run docker exec "$CN" bash -c 'printf "CONNECT example.org:443 HTTP/1.1\r\nHost: example.org:443\r\n\r\n" | socat -t 5 - TCP:127.0.0.1:3128'
  assert_output --partial "HTTP/1.1 403"
  assert_output --partial "X-Cleat-Reason: policy"
  assert_output --partial "cleat egress: example.org is not on the allowlist."
}

@test "egress integration: getent hosts fails" {
  if ! eg_is_branch_b; then eg_other_branch; return 0; fi
  eg_caged_up
  run docker exec "$CN" getent hosts example.com
  assert_equal "$status" 2
}

@test "egress integration: a raw AF_PACKET send from box root fails with EPERM" {
  if ! eg_is_branch_b; then eg_other_branch; return 0; fi
  eg_caged_up
  run docker exec -u 0 "$CN" python3 -c 'import socket; socket.socket(socket.AF_PACKET, socket.SOCK_RAW)'
  assert_failure
  assert_output --partial "PermissionError"
  assert_output --partial "[Errno 1]"
}

@test "egress integration: cleat stop then cleat starts the gateway before the box" {
  if ! eg_is_branch_b; then eg_other_branch; return 0; fi
  eg_caged_up
  run "$CLI" stop
  assert_success
  run "$CLI" egress status
  assert_output --partial "Gateway stopped"
  # The default verb is start. No terminal, so the session itself ends at
  # once: what is asserted is what happened before it.
  run _portable_timeout 180 "$CLI" < /dev/null
  local g b
  g="$(docker inspect -f '{{.State.StartedAt}}' "$GW")"
  b="$(docker inspect -f '{{.State.StartedAt}}' "$CN")"
  [ -n "$g" ]
  [ -n "$b" ]
  [[ "$g" < "$b" ]]
  run docker inspect -f '{{.State.Running}}' "$GW"
  assert_output "true"
}

@test "egress integration: a killed gateway is an outage and a restart heals it with no box restart" {
  if ! eg_is_branch_b; then eg_other_branch; return 0; fi
  eg_caged_up
  local started restarts
  started="$(docker inspect -f '{{.State.StartedAt}}' "$CN")"
  restarts="$(docker inspect -f '{{.RestartCount}}' "$CN")"
  docker kill "$GW" >/dev/null
  run eg_box_curl https://api.anthropic.com/
  refute_output "403"
  run "$CLI" egress restart
  assert_success
  eg_wait_relay
  run eg_box_curl https://api.anthropic.com/
  refute_output "000"
  refute_output ""
  run docker inspect -f '{{.State.StartedAt}}|{{.RestartCount}}' "$CN"
  assert_output "$started|$restarts"
}

@test "egress integration: cleat rm removes the gateway and the volume" {
  if ! eg_is_branch_b; then eg_other_branch; return 0; fi
  eg_caged_up
  run "$CLI" rm
  assert_success
  eg_nothing_created
  [ ! -e "$EG_CONF_DIR/egress-boxes/$CN" ]
  [ ! -e "$EG_CONF_DIR/egress-pins/$CN" ]
  [ ! -e "$EG_CONF_DIR/egress-notices/$CN" ]
  run docker volume ls -q --filter "label=sh.cleat.gateway-for=$BH"
  assert_output ""
}

@test "egress integration: a second gateway on the same volume flips the original to unhealthy" {
  if ! eg_is_branch_b; then eg_other_branch; return 0; fi
  eg_caged_up
  eg_wait_health "$GW" healthy 60
  local uid gid
  uid="$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$CN" | sed -n 's/^HOST_UID=//p')"
  gid="$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$CN" | sed -n 's/^HOST_GID=//p')"
  # The 8.2 flags, on the same socket volume and the same rendered policy,
  # labelled for this box so the teardown removes it.
  docker run -d --name "cleat-gw-$BH-impostor" \
    --label sh.cleat.role=gateway --label "sh.cleat.gateway-for=$BH" \
    --cap-drop ALL --cap-add CHOWN --cap-add SETUID --cap-add SETGID \
    --security-opt no-new-privileges --read-only \
    --tmpfs /run/gw-admin:rw,noexec,nosuid,nodev,size=1m \
    -v "$VOL:/run/cleat-egress" \
    -v "$EG_CONF_DIR/egress-rendered/$BH:/etc/cleat-egress:ro" \
    -e "CLEAT_SOCK_UID=$uid" -e "CLEAT_SOCK_GID=$gid" \
    "$EG_GW_IMAGE" >/dev/null
  eg_wait_health "$GW" unhealthy 60
  run docker exec "$GW" /usr/local/bin/gw-admin path_ok
  assert_output --partial "false"
  run "$CLI" egress status
  assert_output --partial "Gateway displaced"
  docker rm -f "cleat-gw-$BH-impostor" >/dev/null
  sleep 3
  run eg_health "$GW"
  assert_output "unhealthy"
  run "$CLI" egress restart
  assert_success
  eg_wait_health "$GW" healthy 60
}

@test "egress integration: a volume removed between create and start is a refusal" {
  if ! eg_is_branch_b; then eg_other_branch; return 0; fi
  local real
  real="$(command -v docker)"
  mkdir -p "$TEST_TEMP/wrapbin"
  # A pass-through docker that removes the socket volume right after the CLI
  # creates it, so the gateway's run makes an unlabelled one.
  cat > "$TEST_TEMP/wrapbin/docker" <<SH
#!/usr/bin/env bash
"$real" "\$@"
rc=\$?
if [ "\$rc" = 0 ] && [ "\${1:-}" = volume ] && [ "\${2:-}" = create ]; then
  for a in "\$@"; do
    case "\$a" in cleat-gw-*-sock) "$real" volume rm "\$a" >/dev/null 2>&1 ;; esac
  done
fi
exit \$rc
SH
  chmod +x "$TEST_TEMP/wrapbin/docker"
  PATH="$TEST_TEMP/wrapbin:$PATH" run "$CLI" run
  assert_failure
  # Never a silent uncaged start: a box that exists has no network.
  if [ -n "$(docker ps -aq --filter "name=^${CN}$")" ]; then
    run docker inspect -f '{{.HostConfig.NetworkMode}}' "$CN"
    assert_output "none"
  fi
  if docker volume inspect "$VOL" >/dev/null 2>&1; then
    run docker volume inspect -f '{{index .Labels "sh.cleat.role"}}' "$VOL"
    assert_output ""
  fi
}

@test "egress integration: setup over https succeeds with the apt pack and fails naming the policy without it" {
  if ! eg_is_branch_b; then eg_other_branch; return 0; fi
  printf '[setup]\nsudo apt-get update\nsudo apt-get install -y sl\n' > "$INT_PROJECT/.cleat"
  export CLEAT_TRUST_SETUP=1
  # The deny arm: apt-debian not in the policy.
  run "$CLI" run
  assert_output --partial "Setup failed with exit code 100"
  run "$CLI" egress why sl
  assert_output --partial "pack apt-debian"
  # The allow arm, on a second box of the project.
  printf '[egress]\nmode = strict\npack = apt-debian\n' > "$EG_CONF_DIR/config"
  printf '[setup]\nsudo apt-get update\nsudo apt-get install -y cowsay\n' > "$INT_PROJECT/.cleat"
  local acn
  acn="$(int_cname apt)"
  run "$CLI" run apt
  refute_output --partial "Setup failed"
  run docker exec "$acn" test -x /usr/games/cowsay
  assert_success
}

@test "egress integration: the socket volume holds exactly proxy.sock and denials.log" {
  if ! eg_is_branch_b; then eg_other_branch; return 0; fi
  eg_caged_up
  run docker run --rm --entrypoint ls -v "$VOL:/v:ro" cleat -A /v
  assert_success
  assert_output "denials.log
proxy.sock"
}

@test "egress integration: gateway alive and box gone reports orphaned rather than healthy" {
  if ! eg_is_branch_b; then eg_other_branch; return 0; fi
  eg_caged_up
  docker stop "$CN" >/dev/null
  run "$CLI" egress status
  assert_output --partial "Gateway orphaned"
  refute_output --partial "Gateway healthy"
}
