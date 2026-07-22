#!/usr/bin/env bash
# Extra Rust dev tools, installed on top of the toolchain. Inlined by ../.cleat
# after toolchain.sh, so cargo is already present.
set -euo pipefail

export PATH="$HOME/.cargo/bin:$PATH"

# Components that pair with most editors and CI.
rustup component add clippy rustfmt

# cargo-binstall pulls prebuilt binaries instead of compiling from source, so
# adding tools stays fast. Swap in whatever your project leans on.
curl -fsSL https://raw.githubusercontent.com/cargo-bins/cargo-binstall/main/install-from-binstall-release.sh | bash
cargo binstall -y cargo-watch cargo-nextest

cargo clippy --version
