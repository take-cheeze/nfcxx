#!/usr/bin/env bash
# libclang-edg: install the library, its headers and libclang-edg.pc under PREFIX (default build/libclang-edg/install).
# Uses the library scripts/build-libclang-edg.sh built. The runner it uses is the one named at build time: install
# the checkout's scripts/libclang-cursors with it, or set LIBCLANG_EDG_RUNNER when the library runs.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
out=${LIBCLANG_EDG_OUT:-$root/build/libclang-edg}
prefix=${1:-$out/install}
version=1.0
mkdir -p "$prefix/lib/pkgconfig" "$prefix/include/clang-c"
cp -P "$out/libclang-edg.so" "$out/libclang-edg.so.1" "$prefix/lib/"
cp "$root/lib/libclang-edg/include/clang-c/"*.h "$prefix/include/clang-c/"
sed -e "s|@PREFIX@|$prefix|" -e "s|@VERSION@|$version|" "$root/lib/libclang-edg/libclang-edg.pc.in" \
  > "$prefix/lib/pkgconfig/libclang-edg.pc"
echo "installed to $prefix"
