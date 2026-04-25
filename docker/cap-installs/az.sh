#!/bin/bash
# Lazy-install script for the `az` capability (Azure CLI).
#
# Runs inside the cleat container as root. Invoked by cleat (via
# `docker exec --user root`) when the `az` cap is active and the tool
# is not already present. Pattern documented in
# `concept/10-capabilities.md` → "Lazy install capabilities".
#
# Idempotent: exits 0 immediately if `az` is already installed. Subsequent
# container starts hit the fast path and skip this script entirely (cleat
# checks `command -v az` first).
set -e

if command -v az >/dev/null 2>&1; then
  exit 0
fi

# Microsoft's official Debian install path. Spelled out (rather than
# piping `aka.ms/InstallAzureCLIDeb` to bash) so each step is auditable
# and pinned to the keyring / repo we expect.
apt-get update
apt-get install -y --no-install-recommends ca-certificates curl gpg

install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://packages.microsoft.com/keys/microsoft.asc \
  | gpg --dearmor -o /etc/apt/keyrings/microsoft.gpg
chmod a+r /etc/apt/keyrings/microsoft.gpg

AZ_DIST="$(. /etc/os-release && echo "${VERSION_CODENAME}")"
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/microsoft.gpg] https://packages.microsoft.com/repos/azure-cli/ ${AZ_DIST} main" \
  > /etc/apt/sources.list.d/azure-cli.list

apt-get update
apt-get install -y --no-install-recommends azure-cli

rm -rf /var/lib/apt/lists/*
