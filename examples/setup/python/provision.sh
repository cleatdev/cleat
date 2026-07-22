#!/usr/bin/env bash
# Python provisioning for a Cleat box. Inlined by ./.cleat via `script`.
#
# The whole [setup] payload runs under `bash -e`, so the first failing command
# stops the rest. Write these steps to be safe to re-run: `cleat setup` can
# replay them, and a recreate runs them again on a fresh box.
set -euo pipefail

# uv is a fast, single-binary Python package and version manager (amd64 and
# arm64). It installs into ~/.local/bin.
curl -fsSL https://astral.sh/uv/install.sh | sh

# Make uv available in this payload and in future shells for the box.
export PATH="$HOME/.local/bin:$PATH"
if ! grep -q '.local/bin' "$HOME/.bashrc" 2>/dev/null; then
  echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME/.bashrc"
fi

# Pin an interpreter and sync the project's dependencies if it declares any.
uv python install 3.12
if [ -f /workspace/pyproject.toml ] || [ -f /workspace/uv.lock ]; then
  cd /workspace
  uv sync
fi

uv --version
