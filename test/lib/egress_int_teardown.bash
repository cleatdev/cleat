# The cleanup test/integration/egress.bats runs after every case, kept here so
# a unit test can drive it against the recording docker stub.
#
# eg_int_teardown_boxes <cname>: removes this project's boxes, then each box's
# gateway and socket volume by that box's own hash. Nothing is touched unless
# <cname> has the shape container_name_for gives it: an empty or stray name
# would make the name filter match every container on the host, the user's own
# included, and every one of them would be force-removed.
eg_int_teardown_boxes() {
  local cn="${1:-}" n h c
  case "$cn" in
    cleat-*-[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;;
    *) return 0 ;;
  esac
  for n in $(docker ps -a --filter "name=^${cn}(-[a-z0-9_.-]+)?$" --format '{{.Names}}' 2>/dev/null) "$cn"; do
    case "$n" in "$cn"|"$cn"-*) ;; *) continue ;; esac
    h="$(cli_call _egress_box_hash "$n")" || continue
    docker rm -f "$n" >/dev/null 2>&1 || true
    for c in $(docker ps -aq --filter "label=sh.cleat.gateway-for=${h}" 2>/dev/null); do
      docker rm -f "$c" >/dev/null 2>&1 || true
    done
    docker volume rm "cleat-gw-$h-sock" >/dev/null 2>&1 || true
  done
  return 0
}
