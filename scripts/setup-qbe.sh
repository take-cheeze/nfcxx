#!/usr/bin/env bash
# Build the QBE back end (3rd/qbe) and the cproc C front end (3rd/cproc) into
# build/qbe and build/cproc. Both build in a copy of the source so the
# submodules stay clean.
#
# 3rd/qbe is take-cheeze/qbe, a daily mirror of https://c9x.me/git/qbe.git (see that
# repo's sync workflow); 3rd/cproc is michaelforney/cproc. Move both forward together.
# scripts/cproc-empty-struct.patch is applied to the cproc copy (see docs/notes/freestanding.md); it
# must be refreshed if 3rd/cproc moves.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
git -C "$root" submodule update --init 3rd/qbe 3rd/cproc

for p in qbe cproc; do
  rm -rf "$root/build/$p"; mkdir -p "$root/build"
  cp -r "$root/3rd/$p" "$root/build/$p"
  rm -rf "$root/build/$p/.git"
done
patch -d "$root/build/cproc" -p1 --batch < "$root/scripts/cproc-empty-struct.patch"
make -C "$root/build/qbe" -j"$(nproc)" >/dev/null
(cd "$root/build/cproc" && ./configure >/dev/null && make -j"$(nproc)" cproc-qbe >/dev/null)
echo "built: $root/build/qbe/qbe $root/build/cproc/cproc-qbe"
