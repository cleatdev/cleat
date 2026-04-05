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

chown "$HOST_UID:$HOST_GID" /home/coder
chown -R "$HOST_UID:$HOST_GID" /home/coder/.claude 2>/dev/null || true
chown "$HOST_UID:$HOST_GID" /home/coder/.claude.json 2>/dev/null || true
chown "$HOST_UID:$HOST_GID" /workspace 2>/dev/null || true

if [ $# -eq 0 ]; then
  exec su -s /bin/bash coder
else
  exec su -s /bin/bash coder -c "$(printf ' %q' "$@" | cut -c2-)"
fi
