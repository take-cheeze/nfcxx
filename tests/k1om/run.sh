#!/usr/bin/env bash
# tests/k1om/run.sh: nfcxx --target=linux_k1om builds freestanding C++ into Intel Knights Corner (k1om) programs.
# Checks the ELF machine of each program (EM_K1OM). Running them needs the card (see docs/notes/k1om.md).
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
k1om=${NFCXX_K1OM_ROOT:-/opt/k1om}
[ -x "$k1om/bin/k1om-mpss-linux-gcc" ] || { echo "tests/k1om: no k1om toolchain at $k1om (skipped)"; exit 0; }
[ -f "$root/build/k1om/libC.a" ] || "$root/scripts/setup-k1om.rb"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fail=0
for src in "$root"/tests/k1om/*.cpp; do
  name=$(basename "$src" .cpp)
  "$root/nfcxx" --freestanding --target=linux_k1om "$src" -o "$tmp/$name" >"$tmp/$name.log" 2>&1 \
    || { echo "FAIL build $name"; sed -n 1,20p "$tmp/$name.log"; fail=1; continue; }
  if readelf -h "$tmp/$name" | grep -q 'Intel K1OM'; then echo "PASS $name (Intel K1OM)"; else echo "FAIL $name: not a K1OM binary"; fail=1; fi
done
exit $fail
