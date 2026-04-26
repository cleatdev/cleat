#!/bin/bash
# Lazy-install script for the `gcloud` capability (Google Cloud CLI).
#
# Runs inside the cleat container as root. Invoked by cleat (via
# `docker exec --user root`) when the `gcloud` cap is active and the tool
# is not already present. Pattern documented in
# `concept/10-capabilities.md` → "Lazy install capabilities".
#
# Idempotent: exits 0 immediately if `gcloud` is already installed.
set -e

if command -v gcloud >/dev/null 2>&1; then
  exit 0
fi

# Google's official Debian install path. Spelled out (rather than piping
# https://sdk.cloud.google.com to bash) so each step is auditable and
# pinned to the keyring / repo we expect — same approach as cap-installs/az.sh.
apt-get update
apt-get install -y --no-install-recommends ca-certificates curl gpg

install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg \
  | gpg --dearmor -o /etc/apt/keyrings/cloud.google.gpg
chmod a+r /etc/apt/keyrings/cloud.google.gpg

echo "deb [signed-by=/etc/apt/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" \
  > /etc/apt/sources.list.d/google-cloud-sdk.list

apt-get update
apt-get install -y --no-install-recommends google-cloud-cli

rm -rf /var/lib/apt/lists/*
