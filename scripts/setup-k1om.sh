#!/usr/bin/env bash
# setup-k1om.sh: the runtime for `nfcxx --target=linux_k1om` (Intel Knights Corner). Needs the k1om toolchain at
# NFCXX_K1OM_ROOT (default /opt/k1om; docs/notes/k1om.md). Builds:
#   build/edg-k1om      the EDG front end and its runtime sources, for the host (host tools only)
#   build/k1om/libC.a   EDG's C++ runtime compiled for k1om, through the same gcc-cc chain the programs use
# c99_complex.c is left out: it needs _Float16 and __bf16, which the host front end does not give GCC 5.
# Idempotent: rebuilds only when build/k1om/libC.a is missing.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
k1om=${NFCXX_K1OM_ROOT:-/opt/k1om}
[ -x "$k1om/bin/k1om-mpss-linux-gcc" ] || { echo "setup-k1om: no k1om gcc at $k1om/bin (build the toolchain: docs/notes/k1om.md)" >&2; exit 1; }
[ -f "$root/build/k1om/libC.a" ] && { echo "k1om runtime: already built ($root/build/k1om/libC.a)"; exit 0; }

# 1. The host EDG tree, separate from build/edg so the native build is not touched.
(cd "$root" && env -u NFCXX_GCC -u NFCXX_CC -u NFCXX_AS EDG_BUILD="$root/build/edg-k1om" EDG_BASE="$root/build/edg-base-k1om" \
  scripts/setup-edg.sh > "$root/build/edg-k1om.log" 2>&1) || { echo "setup-k1om: EDG build failed (see build/edg-k1om.log)" >&2; exit 1; }

# 2. The runtime: the compile commands ninja would run for lib/libC.a, run with the k1om compiler chain.
cd "$root/build/edg-k1om"
cmds=$(ninja -t commands lib/libC.a | grep -E 'rt-cache|lib_src' | grep -v ' ar qc' | grep -v 'c99_complex' || true)
[ -n "$cmds" ] || { echo "setup-k1om: no runtime compile commands in build/edg-k1om" >&2; exit 1; }
export NFCXX_GCC="$root/scripts/k1om-cc.rb" NFCXX_CC="$root/scripts/gcc-cc" NFCXX_AS="$root/scripts/k1om-bin/as" NFCXX_K1OM_ROOT="$k1om"
export NFCXX_CCACHE=0
while IFS= read -r c; do
  bash -c "$c" > "$root/build/edg-k1om-rt.log" 2>&1 || { echo "setup-k1om: runtime compile failed: ${c:0:160}" >&2; grep -m3 error "$root/build/edg-k1om-rt.log" >&2; exit 1; }
done <<< "$cmds"

# 3. Archive the objects with the k1om ar, without c99_complex.
mkdir -p "$root/build/k1om"
objs=$(cd lib_src/edg-cpp-rt-cache && ls *.o | grep -v '^c99_complex\.o$')
rm -f "$root/build/k1om/libC.a"
(cd lib_src/edg-cpp-rt-cache && "$k1om/bin/k1om-mpss-linux-ar" rcs "$root/build/k1om/libC.a" $objs)
echo "k1om runtime: $root/build/k1om/libC.a ($(echo $objs | wc -w) objects)"
