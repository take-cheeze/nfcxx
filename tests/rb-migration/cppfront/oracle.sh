#!/usr/bin/env bash
# Build cppfront (Herb Sutter's Cpp2 to C++1 translator, Apache 2.0, https://github.com/hsutter/cppfront) into build/cppfront,
# for nfcxx's .cpp2 inputs (experimental: docs/notes/cpp2.md). The source is a shallow clone of the pinned commit (v0.8.2)
# in build/cppfront-src; CPPFRONT_SRC names a checkout to use instead (no clone), CPPFRONT_REPO another remote.
# The pin is not a submodule, so a fresh checkout and CI do not fetch it unless a .cpp2 build asks for it.
# CXX (default c++) builds it; cppfront is one C++20 file, so the host compiler is enough.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
pin=66eb614ff7947ed2502227ae55bc686d98868abf
src=${CPPFRONT_SRC:-$root/build/cppfront-src}
out=$root/build/cppfront

if [ -z "${CPPFRONT_SRC:-}" ] && [ ! -f "$src/source/cppfront.cpp" ]; then
  rm -rf "$src"; mkdir -p "$(dirname "$src")"
  git init -q "$src"
  git -C "$src" fetch -q --depth 1 "${CPPFRONT_REPO:-https://github.com/hsutter/cppfront}" "$pin"
  git -C "$src" checkout -q FETCH_HEAD
fi
[ -f "$src/source/cppfront.cpp" ] || { echo "setup-cppfront: no source/cppfront.cpp under $src" >&2; exit 1; }

mkdir -p "$(dirname "$out")"
"${CXX:-c++}" -std=c++20 -O2 -o "$out.tmp" "$src/source/cppfront.cpp"
mv "$out.tmp" "$out"
echo "setup-cppfront: built $out from $src ($(sed -n 's/.*"\(v[0-9.]*\)".*/\1/p' "$src/source/version.info"))"
