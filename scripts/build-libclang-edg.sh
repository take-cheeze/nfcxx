#!/usr/bin/env bash
# libclang-edg: build lib/libclang-edg/clang_edg.c and the generated stubs into build/libclang-edg/libclang-edg.so, a
# shared library with libclang's C API: the functions clang.cindex uses (lib/libclang-edg/include/clang-c/).
# The library is versioned: SONAME libclang-edg.so.1, and only clang_* is exported (libclang-edg.map).
# Needs the front end built first (scripts/setup-libclang-edg.sh); the library runs scripts/libclang-cursors from this
# checkout, or the runner named by LIBCLANG_EDG_RUNNER at run time.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
out=${LIBCLANG_EDG_OUT:-$root/build/libclang-edg}
cc=${CC:-cc}
mkdir -p "$out"
"$cc" -std=c99 -Wall -Wextra -Werror -fPIC -shared -O2 \
  -Wl,-soname,libclang-edg.so.1 -Wl,--version-script="$root/lib/libclang-edg/libclang-edg.map" \
  -DLIBCLANG_EDG_RUNNER_DEFAULT="\"$root/scripts/libclang-cursors\"" \
  -I "$root/lib/libclang-edg/include" \
  -o "$out/libclang-edg.so.1" "$root/lib/libclang-edg/clang_edg.c" "$root/lib/libclang-edg/generated/stubs.c"
ln -sf libclang-edg.so.1 "$out/libclang-edg.so"
echo "built $out/libclang-edg.so.1"
