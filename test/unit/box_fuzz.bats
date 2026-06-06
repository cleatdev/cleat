#!/usr/bin/env bats
# Boxes — property/fuzz tests (see feedback_deep_testing_bar). These assert the
# load-bearing invariants over a CROSS-PRODUCT of adversarial inputs, not just a
# handful of examples — so a future tweak to the truncation math, the charset,
# or the session-key derivation can't quietly break a corner. Pure functions,
# no docker.
load "../setup"
setup()    { _common_setup; source_cli; }
teardown() { _common_teardown; }

# Adversarial project paths: root, spaces, mixed case, unicode, dots, shell
# metacharacters, deep nesting, trailing dash.
_FUZZ_PATHS=(
  "/" "/a" "/home/user/proj" "/p/with space" "/p/CAPS-Mixed" "/p/weird-ünïcode-ßß"
  "/p/a.b.c.v2" "/p/under_score" "/p/end-" '/p/$dollar&semi;pipe|tick`'
  "/very/deeply/nested/path/to/some/project/directory/here"
)

@test "fuzz: container_name_for — <=63 chars, 8-hex hash, valid Docker name, default byte-identical, named suffix, for ANY path x box" {
  local longdir; longdir="/x/$(printf 'a%.0s' {1..120})"
  local paths=( "${_FUZZ_PATHS[@]}" "$longdir" )
  local boxes=( "" "main" "a" "az" "dev-2_x" "scratch" "untrusted" "$(printf 'b%.0s' {1..31})" )
  local p b r
  for p in "${paths[@]}"; do
    for b in "${boxes[@]}"; do
      r="$(container_name_for "$p" "$b")"
      # 1. Never exceeds Docker's 63-char container-name limit.
      [[ ${#r} -le 63 ]] || { echo "len ${#r} > 63: p='$p' b='$b' -> $r"; return 1; }
      # 2. Always a valid Docker container name.
      [[ "$r" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]] || { echo "invalid docker name: p='$p' b='$b' -> $r"; return 1; }
      # 3. Always cleat-…-<8 hex>[ -<box> ]; the hash is never truncated away.
      [[ "$r" =~ ^cleat-.*-[0-9a-f]{8}(-[a-z0-9_-]+)?$ ]] || { echo "bad shape: p='$p' b='$b' -> $r"; return 1; }
      if [[ -z "$b" || "$b" == "main" ]]; then
        # 4. Default box ("" / main) is byte-identical to the legacy no-box name.
        [[ "$r" == "$(container_name_for "$p")" ]] || { echo "default not byte-identical: p='$p' b='$b' -> $r"; return 1; }
      else
        # 5. A named box's name ends with -<box>.
        [[ "$r" == *"-$b" ]] || { echo "named-box suffix missing: p='$p' b='$b' -> $r"; return 1; }
      fi
    done
  done
}

@test "fuzz: container_name_for — distinct (path,box) pairs never collide (modulo md5)" {
  # Same path, different boxes -> different names; same box, different paths ->
  # different names (the hash disambiguates).
  local a b
  a="$(container_name_for /home/me/api az)"; b="$(container_name_for /home/me/api dev)"
  [[ "$a" != "$b" ]] || { echo "same-path boxes collided: $a"; return 1; }
  a="$(container_name_for /home/alice/app)"; b="$(container_name_for /home/bob/app)"
  [[ "$a" != "$b" ]] || { echo "different-path mains collided: $a"; return 1; }
  a="$(container_name_for /home/me/api az)"; b="$(container_name_for /home/me/api)"
  [[ "$a" != "$b" ]] || { echo "named vs main collided: $a"; return 1; }
}

@test "fuzz: _derive_project_session_key — default byte-identical to legacy; named appends -<box>; for ANY path" {
  local p b legacy
  for p in "${_FUZZ_PATHS[@]}"; do
    legacy="$(basename "$p" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g')-$(echo -n "$p" | _md5 | head -c 8)"
    [[ "$(_derive_project_session_key "$p")" == "$legacy" ]]      || { echo "default key drift: p='$p'"; return 1; }
    [[ "$(_derive_project_session_key "$p" main)" == "$legacy" ]] || { echo "main key drift: p='$p'"; return 1; }
    for b in az dev scratch; do
      [[ "$(_derive_project_session_key "$p" "$b")" == "${legacy}-$b" ]] || { echo "named key wrong: p='$p' b='$b'"; return 1; }
    done
  done
}

@test "fuzz: _validate_box_name — never crashes and agrees with its charset, for hostile inputs" {
  local inputs=(
    "" "a" "az" "main" "1" "a-b" "a_b" "main-2" "x--y" "0box" "z9"
    "A" "Az" "-a" "_a" ".a" "a." "a/b" "a b" 'a$b' 'a;b' 'a&b' 'a|b' 'a`b' 'a*b' "a:b"
    "café" "$(printf 'a%.0s' {1..31})" "$(printf 'a%.0s' {1..32})"
    $'a\nb' $'ab\n' $'a\tb' $'\ta'
  )
  local s
  for s in "${inputs[@]}"; do
    if [[ "$s" =~ ^[a-z0-9][a-z0-9_-]{0,30}$ ]]; then
      _validate_box_name "$s" || { echo "should ACCEPT: '$s'"; return 1; }
    else
      ! _validate_box_name "$s" || { echo "should REJECT: '$s'"; return 1; }
    fi
  done
}
