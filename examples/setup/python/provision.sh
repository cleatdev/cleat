#!/usr/bin/env bash
# Python provisioning for a Cleat box. Inlined by ./.cleat via `script`.
#
# The whole [setup] payload runs under `bash -e`, so the first failing command
# stops the rest. Write these steps to be safe to re-run: `cleat setup` can
# replay them, and a recreate runs them again on a fresh box.
set -euo pipefail

# uv is a fast, single-binary Python package and version manager (amd64 and
# arm64). UV_UNMANAGED_INSTALL points the installer at a directory we choose and
# turns off everything else it would otherwise touch: no shell rc edits, and no
# ~/.config/uv receipt. Neither is a write this payload needs, and on a box
# created before the entrypoint learned to chown those paths both fail outright
# and take the whole payload down (it runs under `bash -e`).
#
# INSTALLER_NO_MODIFY_PATH alone is NOT enough. Measured on a pre-fix box: it
# stops the rc edits but the receipt directory still fails, and the installer
# exits 1 ("unable to create receipt directory at /home/coder/.config/uv").
# UV_UNMANAGED_INSTALL exits 0 on the same box.
#
# ~/.local/bin is already first on the session PATH, so nothing further is
# needed to expose uv to the agent.
#
# Trade-off: an unmanaged install has no receipt, so `uv self update` refuses.
# This file owns uv's version instead, and a recreate re-runs it.
curl -fsSL https://astral.sh/uv/install.sh | env UV_UNMANAGED_INSTALL="$HOME/.local/bin" sh

# Make uv available for the rest of this payload.
export PATH="$HOME/.local/bin:$PATH"

# Pin an interpreter and sync the project's dependencies if it declares any.
uv python install 3.12
if [ -f /workspace/pyproject.toml ] || [ -f /workspace/uv.lock ]; then
  cd /workspace
  uv sync
fi

uv --version
