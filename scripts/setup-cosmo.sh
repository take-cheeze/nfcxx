#!/usr/bin/env bash
# Fetches cosmocc (the Cosmopolitan Libc C/C++ toolchain, https://github.com/jart/cosmopolitan) into build/cosmocc, for
# `nfcxx --cosmo` (docs/notes/cosmo.md). Nothing is built from source: the release zip is unpacked as it is.
#   COSMOCC_URL=URL       the zip (default: https://cosmo.zip/pub/cosmocc/cosmocc.zip)
#   COSMOCC_SHA256=HEX    checked against the zip when set
#   COSMOCC_DIR=DIR       where it goes (default: build/cosmocc)
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
url=${COSMOCC_URL:-https://cosmo.zip/pub/cosmocc/cosmocc.zip}
dir=${COSMOCC_DIR:-$root/build/cosmocc}

if [ -x "$dir/bin/cosmocc" ]; then
  echo "cosmocc: already at $dir/bin/cosmocc"
  "$dir/bin/cosmocc" --version | head -1
  exit 0
fi

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
echo "cosmocc: fetching $url"
curl -fsSL --retry 3 -o "$tmp/cosmocc.zip" "$url"
if [ -n "${COSMOCC_SHA256:-}" ]; then
  echo "$COSMOCC_SHA256  $tmp/cosmocc.zip" | sha256sum -c -
else
  echo "cosmocc: sha256 of the zip (set COSMOCC_SHA256 to pin it): $(sha256sum "$tmp/cosmocc.zip" | cut -d' ' -f1)"
fi
mkdir -p "$dir"
unzip -q -o "$tmp/cosmocc.zip" -d "$dir"
chmod +x "$dir"/bin/* 2>/dev/null || true
"$dir/bin/cosmocc" --version | head -1
