#!/usr/bin/env bash
# Install TinyGo (https://tinygo.org, a Go compiler built on LLVM) into build/tinygo, for the wasm explorer's Go language
# (docs/notes/wasm-explorer.md): `tinygo build -o prog.ll` writes the LLVM IR that scripts/llvm-to-pathb.rb translates.
# The release is the pinned linux-amd64 tarball, checked against its SHA-256. TinyGo runs the Go toolchain (go, 1.22 to
# 1.25 for this release), which must be on PATH. Does nothing if the pinned version is installed already.
#   FORCE=1   download again
# Exit status: 0 installed (or up to date); 3 cannot be installed here (not linux-amd64, or no download); 1 failed.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
version=0.39.0
sha256=a119801579ef0a7a4f3ee285f0caf55241eaa9e115154c2028b696770b47a846
url=https://github.com/tinygo-org/tinygo/releases/download/v$version/tinygo$version.linux-amd64.tar.gz
out=$root/build/tinygo

if [ -z "${FORCE:-}" ] && [ -x "$out/bin/tinygo" ] && [ "$(cat "$out/.version" 2>/dev/null)" = "$version" ]; then
  exit 0
fi
[ "$(uname -s)-$(uname -m)" = Linux-x86_64 ] || { echo "setup-tinygo: only linux-amd64 is pinned" >&2; exit 3; }

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
curl -fsSL -o "$tmp/tinygo.tar.gz" "$url" || { echo "setup-tinygo: cannot download $url" >&2; exit 3; }
echo "$sha256  $tmp/tinygo.tar.gz" | sha256sum -c --quiet - || { echo "setup-tinygo: checksum mismatch" >&2; exit 1; }
tar -xzf "$tmp/tinygo.tar.gz" -C "$tmp"
rm -rf "$out"; mkdir -p "$root/build"
mv "$tmp/tinygo" "$out"
echo "$version" > "$out/.version"
echo "setup-tinygo: $out/bin/tinygo $version"
