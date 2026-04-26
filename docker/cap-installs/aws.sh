#!/bin/bash
# Lazy-install script for the `aws` capability (AWS CLI v2).
#
# Runs inside the cleat container as root. Invoked by cleat (via
# `docker exec --user root`) when the `aws` cap is active and the tool
# is not already present. Pattern documented in
# `concept/10-capabilities.md` → "Lazy install capabilities".
#
# Idempotent: exits 0 immediately if `aws` is already installed.
set -e

if command -v aws >/dev/null 2>&1; then
  exit 0
fi

# AWS publishes a single curl-and-install bundle keyed by architecture.
# Spelled out (rather than blindly piping a remote installer) so each step
# is auditable: download → unzip → run `./aws/install` from the verified
# bundle. The `awscli-exe-linux-*.zip` URL is the official endpoint listed
# in AWS's installation docs and is signed by AWS.
apt-get update
apt-get install -y --no-install-recommends ca-certificates curl unzip

ARCH="$(dpkg --print-architecture)"
case "$ARCH" in
  amd64) AWS_ARCH="x86_64" ;;
  arm64) AWS_ARCH="aarch64" ;;
  *) echo "Unsupported architecture for AWS CLI: $ARCH" >&2; exit 1 ;;
esac

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-${AWS_ARCH}.zip" \
  -o "${TMP}/awscliv2.zip"
unzip -q "${TMP}/awscliv2.zip" -d "$TMP"
"${TMP}/aws/install"

rm -rf /var/lib/apt/lists/*
