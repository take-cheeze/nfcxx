#!/usr/bin/env bash
# Fetches cosmocc (the Cosmopolitan Libc C/C++ toolchain, https://github.com/jart/cosmopolitan) into build/cosmocc, for
# `nfcxx --cosmo` (docs/notes/cosmo.md). Nothing is built from source: the release zip is unpacked as it is.
#   COSMOCC_URL=URL       the zip (default: the 4.0.2 release asset on GitHub; cosmo.zip is not reachable from CI)
#   COSMOCC_SHA256=HEX    checked against the zip (default: the 4.0.2 asset's digest)
#   COSMOCC_DIR=DIR       where it goes (default: build/cosmocc)
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
version=4.0.2
url=${COSMOCC_URL:-https://github.com/jart/cosmopolitan/releases/download/$version/cosmocc-$version.zip}
dir=${COSMOCC_DIR:-$root/build/cosmocc}
# the digest of the 4.0.2 asset, as downloaded from the release on 2026-10-31; an empty COSMOCC_SHA256 (an unset repository variable) means this one
sha256=${COSMOCC_SHA256:-85b8c37a406d862e656ad4ec14be9f6ce474c1b436b9615e91a55208aced3f44}
[ -z "${COSMOCC_URL:-}" ] || sha256=${COSMOCC_SHA256:-}

if [ -x "$dir/bin/cosmocc" ]; then
  echo "cosmocc: already at $dir/bin/cosmocc"
  "$dir/bin/cosmocc" --version | head -1
  exit 0
fi

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
echo "cosmocc: fetching $url"
curl -fsSL --retry 3 -o "$tmp/cosmocc.zip" "$url"
if [ -n "$sha256" ]; then
  echo "$sha256  $tmp/cosmocc.zip" | sha256sum -c -
else
  echo "cosmocc: sha256 of the zip (set COSMOCC_SHA256 to pin it): $(sha256sum "$tmp/cosmocc.zip" | cut -d' ' -f1)"
fi
mkdir -p "$dir"
unzip -q -o "$tmp/cosmocc.zip" -d "$dir"
chmod +x "$dir"/bin/* 2>/dev/null || true
"$dir/bin/cosmocc" --version | head -1
