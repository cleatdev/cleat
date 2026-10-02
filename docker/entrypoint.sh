#!/bin/bash
set -e

HOST_UID="${HOST_UID:-1000}"
HOST_GID="${HOST_GID:-1000}"

# Validate UID/GID are numeric to prevent sed injection
if ! [[ "$HOST_UID" =~ ^[0-9]+$ ]] || ! [[ "$HOST_GID" =~ ^[0-9]+$ ]]; then
  echo "ERROR: HOST_UID and HOST_GID must be numeric (got UID='$HOST_UID', GID='$HOST_GID')" >&2
  exit 1
fi

# Remap coder UID/GID to match host user if they differ
CURRENT_UID=$(id -u coder)
CURRENT_GID=$(id -g coder)

if [ "$CURRENT_GID" != "$HOST_GID" ]; then
  sed -i "s/^coder:x:${CURRENT_GID}:/coder:x:${HOST_GID}:/" /etc/group
  sed -i "s/^coder:\([^:]*\):\([^:]*\):${CURRENT_GID}:/coder:\1:\2:${HOST_GID}:/" /etc/passwd
fi

if [ "$CURRENT_UID" != "$HOST_UID" ]; then
  sed -i "s/^coder:x:${CURRENT_UID}:/coder:x:${HOST_UID}:/" /etc/passwd
fi

# A caged box (concept/46): only a box created under an egress policy has the
# gateway's socket volume mounted at /run/cleat-egress, and the image never
# creates that directory, so the mount is the signal. Box root cannot fake a
# mount without CAP_SYS_ADMIN. Nothing here carries security weight: the box
# has no network, and these only point its tools at the relay. Every write is
# `|| true`, so none can block a start. The relay starts after the uid remap,
# as coder, on every start of the box. It starts before the ownership fixups
# below. chown -R walks the whole bind-mounted ~/.claude, which takes longer
# the more the user keeps there. The launch gate waits only ten seconds for
# the relay's first heartbeat. The supervisor never exits, so it runs in the
# background: in the foreground every fixup below would wait on it forever.
# None of them touches the relay's lock, its log or /run/cleat-egress. The apt
# sources are never touched and NODE_OPTIONS is never set.
if mountpoint -q /run/cleat-egress 2>/dev/null; then
  printf 'Acquire::https::Proxy "http://127.0.0.1:3128";\nAcquire::http::Proxy "http://127.0.0.1:3128";\n' \
    | tee /etc/apt/apt.conf.d/99cleat-egress-proxy >/dev/null 2>&1 || true
  mkdir -p /etc/xdg/pip /usr/local/etc 2>/dev/null || true
  printf '[global]\nproxy = http://127.0.0.1:3128\n' | tee /etc/xdg/pip/pip.conf >/dev/null 2>&1 || true
  printf 'https-proxy=http://127.0.0.1:3128\nproxy=http://127.0.0.1:3128\n' \
    | tee /usr/local/etc/npmrc >/dev/null 2>&1 || true
  git config --system http.proxy http://127.0.0.1:3128 2>/dev/null || true
  # The relay's lock and log sit in the sticky /tmp, which survives a stop.
  # A lock left by the last run would make the new relay exit as a duplicate.
  # The log is the relay's own, opened as coder: -h, so a link planted in its
  # place is never followed as root.
  rm -f /tmp/cleat-egress-shim.lock 2>/dev/null || true
  chown -h "$HOST_UID:$HOST_GID" /tmp/cleat-egress-shim.log 2>/dev/null || true
  runuser -u coder -- /usr/local/bin/cleat-egress-shim </dev/null >/dev/null 2>&1 &
fi

chown "$HOST_UID:$HOST_GID" /home/coder
chown -R "$HOST_UID:$HOST_GID" /home/coder/.claude 2>/dev/null || true
chown "$HOST_UID:$HOST_GID" /home/coder/.claude.json 2>/dev/null || true
chown "$HOST_UID:$HOST_GID" /workspace 2>/dev/null || true

# Claude Code's binary store lives in ~/.local (the launcher symlink in
# ~/.local/bin and the versioned binaries in ~/.local/share/claude). It is
# baked at build time owned by the build UID and is NOT host-mounted. Without
# this chown, after the UID remap above the runtime user can't write it, so
# `claude update` and the on-launch auto-updater fail with EACCES (and
# `claude doctor` reports a broken install). Chown it so the native update
# path works. NB: ~/.local is in the container's writable layer, so updates
# made this way are ephemeral. They revert on `cleat rm`/recreate. The
# durable path is `cleat upgrade-claude` / the on-start update prompt, which
# commit the new version into the image.
chown -R "$HOST_UID:$HOST_GID" /home/coder/.local 2>/dev/null || true

# Claude Code's native installer stages each downloaded build under
# ~/.cache/claude/staging before atomically moving it into ~/.local. Like
# ~/.local it is baked at build time owned by the build UID and is NOT
# host-mounted, so after the remap above the runtime user can't mkdir there.
# Without this chown the installer dies with
#   EACCES: permission denied, mkdir '/home/coder/.cache/claude/staging/...'
# breaking `cleat upgrade-claude`, the on-start update prompt, and a manual
# in-container `claude update`. Chown it so staging can write.
chown -R "$HOST_UID:$HOST_GID" /home/coder/.cache 2>/dev/null || true

# The shell rc files (from useradd's skel) and ~/.config are created at build
# time owned by the build UID and are NOT host-mounted, so after the remap the
# runtime user cannot write them. Every provisioning tool that puts itself on
# PATH trips over exactly this: rustup amends ~/.profile, uv and the dotnet
# install script append to ~/.bashrc, and anything writing ~/.config/<tool>
# needs to create a directory inside ~/.config. Under a `[setup]` payload
# (which runs `bash -e`) that EACCES is a hard abort, so provisioning fails on
# any host whose UID is not the image's 1000, which is every macOS host.
# Reproduced on a 501:20 host: append to ~/.bashrc and mkdir ~/.config/fish
# both fail, while creating a NEW directory in ~ succeeds (the home dir itself
# is chowned above).
#
# .config is chowned NON-recursively on purpose. The gh capability bind-mounts
# the host's ~/.config/gh over the subdirectory, and recursing would rewrite
# the ownership of the user's real host files. Chowning the parent is all that
# is needed: it lets the runtime user create new entries alongside the mount.
chown "$HOST_UID:$HOST_GID" \
  /home/coder/.bashrc \
  /home/coder/.profile \
  /home/coder/.bash_logout \
  /home/coder/.config 2>/dev/null || true

# Docker capability: when /var/run/docker.sock is mounted (docker cap active),
# the socket is group-owned by the host's docker GID (typically 999 on Linux).
# The coder user's GID has been remapped to HOST_GID, which generally isn't
# the docker GID, so coder can't talk to the socket. Resolve this by ensuring
# a group exists with the socket's GID and making coder a member.
if [ -S /var/run/docker.sock ]; then
  SOCK_GID=$(stat -c '%g' /var/run/docker.sock 2>/dev/null || echo "")
  # Skip when the socket GID already matches coder's primary group (no-op).
  if [ -n "$SOCK_GID" ] && [[ "$SOCK_GID" =~ ^[0-9]+$ ]] && [ "$SOCK_GID" != "$(id -g coder)" ]; then
    SOCK_GROUP=$(getent group "$SOCK_GID" | cut -d: -f1)
    if [ -z "$SOCK_GROUP" ]; then
      # Re-point an existing docker-host group to the CURRENT socket GID rather
      # than leaving a stale group and adding a second: idempotent across the
      # Docker Desktop restarts that renumber the socket GID. See concept/15.
      if getent group docker-host >/dev/null 2>&1; then
        groupmod -g "$SOCK_GID" docker-host 2>/dev/null || true
      else
        groupadd -g "$SOCK_GID" docker-host 2>/dev/null || true
      fi
      SOCK_GROUP=$(getent group "$SOCK_GID" | cut -d: -f1)
    fi
    [ -n "$SOCK_GROUP" ] && usermod -aG "$SOCK_GROUP" coder 2>/dev/null || true
  fi
fi

# Clear stale clipboard-daemon runtime files left in this container's writable
# layer by a previous session. /tmp survives `docker stop`/`docker start`, so a
# file created under a different (pre-remap) uid could otherwise persist and
# wedge the next clip-daemon. As root we can remove them regardless of owner,
# guaranteeing a clean slate. Covers both the current per-uid dirs and the
# legacy bare paths used before v0.13.1.
rm -rf /tmp/cleat-run-* /tmp/clip.sock /tmp/clip-daemon.pid /tmp/clip-handler 2>/dev/null || true

if [ $# -eq 0 ]; then
  exec su -s /bin/bash coder
else
  exec su -s /bin/bash coder -c "$(printf ' %q' "$@" | cut -c2-)"
fi
