#!/usr/bin/env bash
# Runs the gateway corpus (EGRESS-SPEC.md 11.6). Opt-in from ./test.sh through
# CLEAT_GATEWAY_TESTS=1. Never skips: a missing or old python3 is rc 2, because
# a skipped gateway harness reads as green.
set -euo pipefail

PYTHON_FLOOR_MINOR=11   # python3 of Debian bookworm, the gateway image's base family

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! command -v python3 >/dev/null 2>&1; then
  echo "gateway corpus: python3 is required and missing" >&2
  exit 2
fi
if ! python3 -c "import sys; sys.exit(sys.version_info < (3, $PYTHON_FLOOR_MINOR))"; then
  echo "gateway corpus: python3 3.$PYTHON_FLOOR_MINOR or newer is required, found $(python3 -V 2>&1)" >&2
  exit 2
fi

echo "gateway corpus (python3 $(python3 -c 'import platform; print(platform.python_version())'))"
exec python3 "$here/corpus.py" "$@"
