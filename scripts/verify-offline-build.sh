#!/usr/bin/env bash
set -euo pipefail
export RUSTUP_HOME="${RUSTUP_HOME:-$HOME/.rustup}"
export CARGO_NET_OFFLINE=true
rustup toolchain install stable >/dev/null 2>&1 || true
rustup component add rust-src >/dev/null 2>&1 || true
rustup target add wasm32-unknown-unknown >/dev/null 2>&1 || true
cargo build --release --target wasm32-unknown-unknown
test -f target/wasm32-unknown-unknown/release/exotic_orbits_sim.wasm
echo OFFLINE_BUILD_OK
