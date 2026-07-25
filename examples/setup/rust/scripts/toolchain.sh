#!/usr/bin/env bash
# Install the Rust toolchain via rustup. Inlined by ../.cleat.
set -euo pipefail

# rustc shells out to the system linker and the slim base ships no C toolchain
# at all (verified: no cc, gcc, ld, make or pkg-config), so without this every
# compile dies with "linker `cc` not found" and rustup's own installer warns
# about it. pkg-config comes along because most -sys crates need it to find
# system libraries.
sudo apt-get update
sudo apt-get install -y --no-install-recommends build-essential pkg-config

# Non-interactive rustup: default stable toolchain, no prompts (amd64/arm64).
# --no-modify-path is deliberate. By default rustup appends a PATH line to the
# shell rc files (~/.profile, ~/.bashrc), which a non-interactive [setup]
# payload never sources anyway. Those files also belong to the image's build
# user on a box created before the ownership fix, so writing them fails outright
# and takes the whole payload down with it (the payload runs under `bash -e`).
curl -fsSL https://sh.rustup.rs | sh -s -- -y --no-modify-path \
  --default-toolchain stable --profile minimal

# Put cargo on PATH for the rest of this payload...
export PATH="$HOME/.cargo/bin:$PATH"

# ...and for the session, by symlinking each tool into ~/.local/bin, which the
# box already puts first on PATH. `ln -sf` makes this safe to re-run.
mkdir -p "$HOME/.local/bin"
for _bin in "$HOME"/.cargo/bin/*; do
  [ -x "$_bin" ] || continue
  ln -sf "$_bin" "$HOME/.local/bin/$(basename "$_bin")"
done

rustc --version
cargo --version
