#!/usr/bin/env bash
# Install the Rust toolchain via rustup. Inlined by ../.cleat.
set -euo pipefail

# Non-interactive rustup: default stable toolchain, no prompts (amd64/arm64).
curl -fsSL https://sh.rustup.rs | sh -s -- -y --default-toolchain stable --profile minimal

# Put cargo on PATH for this payload and for future shells in the box.
export PATH="$HOME/.cargo/bin:$PATH"

rustc --version
cargo --version
