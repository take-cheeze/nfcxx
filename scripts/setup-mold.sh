#!/usr/bin/env bash
# Build mold 3 (the Rust linker, https://github.com/rui314/mold) into build/mold/bin: mold and ld.mold, so that
#   PATH="$PWD/build/mold/bin:$PATH" NFCXX_LD=mold ./nfcxx ...
# links with it. The source is the v3.0.0 tag, checked against the pinned commit below; the build is cargo's
# (Rust 1.95 or newer, and network access for its crates, including the mimalloc_rust git dependency).
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
tag=v3.0.0
pin=8de38c35a2df16a25f7ff87ac3ad07156a925beb   # the commit of v3.0.0
src="$root/build/mold-src"

command -v cargo >/dev/null || { echo "setup-mold: cargo not found (install Rust 1.95 or newer)" >&2; exit 1; }
rm -rf "$src"; mkdir -p "$root/build"
git clone -q --depth 1 --branch "$tag" https://github.com/rui314/mold.git "$src"
[ "$(git -C "$src" rev-parse HEAD)" = "$pin" ] || { echo "setup-mold: $tag is not $pin" >&2; exit 1; }
(cd "$src" && cargo build --release -p mold-cli >/dev/null)

mkdir -p "$root/build/mold/bin"
install -m 755 "$src/target/release/mold" "$root/build/mold/bin/mold"
ln -sf mold "$root/build/mold/bin/ld.mold"
rm -rf "$src"
"$root/build/mold/bin/mold" --version
