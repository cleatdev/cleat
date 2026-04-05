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

# Hook event forwarding: inject cleat-hook-logger into project-local settings.
# Writes to /workspace/.claude/settings.local.json (project-local, gitignored).
# The hook command is guarded so it silently no-ops outside a Cleat container.
_inject_hook_settings() {
  local settings_dir="/workspace/.claude"
  local settings_file="$settings_dir/settings.local.json"

  # Non-blocking events to log (async, no performance impact)
  local hook_events="SessionStart SessionEnd PostToolUse PostToolUseFailure Notification SubagentStart SubagentStop CwdChanged FileChanged PreCompact PostCompact Stop StopFailure"

  # Guard command: no-ops silently if cleat-hook-logger isn't available
  local cmd="test -x /usr/local/bin/cleat-hook-logger && cleat-hook-logger || true"

  # Build the hooks JSON
  local hooks_json="{\"hooks\":{"
  local first=true
  for event in $hook_events; do
    if [ "$first" = true ]; then first=false; else hooks_json+=","; fi
    hooks_json+="\"$event\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"$cmd\",\"async\":true}]}]"
  done
  hooks_json+="}}"

  mkdir -p "$settings_dir" 2>/dev/null || true

  # If settings.local.json exists, merge (preserve existing settings)
  if [ -f "$settings_file" ]; then
    # Already configured? Skip.
    if grep -q "cleat-hook-logger" "$settings_file" 2>/dev/null; then
      return 0
    fi
    local existing
    existing="$(cat "$settings_file" 2>/dev/null)" || existing="{}"
    echo "$existing" | jq --argjson new_hooks "$hooks_json" '
      .hooks = ((.hooks // {}) as $existing |
        ($new_hooks.hooks) as $new |
        ($existing * ($new | to_entries | map({
          key: .key,
          value: (($existing[.key] // []) + .value)
        }) | from_entries)))
    ' > "${settings_file}.tmp" 2>/dev/null && mv "${settings_file}.tmp" "$settings_file"
  else
    echo "$hooks_json" | jq '.' > "$settings_file"
  fi
  chown "$HOST_UID:$HOST_GID" "$settings_dir" "$settings_file" 2>/dev/null || true
}

# Ensure hooks log directory is writable
chown "$HOST_UID:$HOST_GID" /var/log/cleat 2>/dev/null || true

# Inject hook settings (skip if CLEAT_NO_HOOKS is set)
# Failures here must not prevent the container from starting.
if [ "${CLEAT_NO_HOOKS:-}" != "1" ]; then
  _inject_hook_settings || true
fi

if [ $# -eq 0 ]; then
  exec su -s /bin/bash coder
else
  exec su -s /bin/bash coder -c "$(printf ' %q' "$@" | cut -c2-)"
fi
