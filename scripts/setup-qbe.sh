#!/usr/bin/env bash
# Build the QBE back end (3rd/qbe) and the cproc C front end (3rd/cproc) into
# build/qbe and build/cproc. Both build in a copy of the source so the
# submodules stay clean.
#
# 3rd/qbe is take-cheeze/qbe, a daily mirror of https://c9x.me/git/qbe.git (see that
# repo's sync workflow); 3rd/cproc is michaelforney/cproc. Move both forward together.
# scripts/cproc-empty-struct.patch (see docs/notes/freestanding.md) and scripts/cproc-vaarg-aggregate.patch
# (va_arg of small integer-class structs, needed by mruby) and scripts/cproc-empty-copy.patch (no copy of a
# zero-size struct) are applied, in that order, to the cproc copy;
# they must be refreshed if 3rd/cproc moves. scripts/qbe-uninit-slot.patch is applied to the QBE copy. Re-run this script after pulling a new patch.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
git -C "$root" submodule update --init 3rd/qbe 3rd/cproc

for p in qbe cproc; do
  rm -rf "$root/build/$p"; mkdir -p "$root/build"
  cp -r "$root/3rd/$p" "$root/build/$p"
  rm -rf "$root/build/$p/.git"
done
for p in cproc-empty-struct cproc-vaarg-aggregate cproc-empty-copy; do
  patch -d "$root/build/cproc" -p1 --batch < "$root/scripts/$p.patch"
done
# QBE: scripts/qbe-uninit-slot.patch (a never-stored struct slot passed by value must not become a null load)
patch -d "$root/build/qbe" -p1 --batch < "$root/scripts/qbe-uninit-slot.patch"
make -C "$root/build/qbe" -j"$(nproc)" >/dev/null
(cd "$root/build/cproc" && ./configure >/dev/null && make -j"$(nproc)" cproc-qbe >/dev/null)
echo "built: $root/build/qbe/qbe $root/build/cproc/cproc-qbe"
