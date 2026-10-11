#!/usr/bin/env bash
# Build the QBE back end (3rd/qbe) and the cproc C front end (3rd/cproc) into
# build/qbe and build/cproc. Both build in a copy of the source so the
# submodules stay clean.
#
# 3rd/qbe is take-cheeze/qbe, a daily mirror of https://c9x.me/git/qbe.git (see that
# repo's sync workflow). 3rd/cproc is take-cheeze/cproc, a fork of michaelforney/cproc: its branch
# nfcxx-patches is the pinned upstream commit plus nfcxx's cproc patches as commits (empty-struct,
# vaarg-aggregate, empty-copy, array-qual; see docs/notes/freestanding.md and docs/notes/realworld.md for what
# each one fixes). Move the pin in .gitmodules and the fork together when rebasing those patches onto a new upstream.
# scripts/qbe-uninit-slot.patch is applied to the QBE copy. Re-run this script after changing the pin.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
git -C "$root" submodule update --init 3rd/qbe 3rd/cproc

for p in qbe cproc; do
  rm -rf "$root/build/$p"; mkdir -p "$root/build"
  cp -r "$root/3rd/$p" "$root/build/$p"
  rm -rf "$root/build/$p/.git"
done
# QBE: scripts/qbe-uninit-slot.patch (a never-stored struct slot passed by value must not become a null load)
patch -d "$root/build/qbe" -p1 --batch < "$root/scripts/qbe-uninit-slot.patch"
make -C "$root/build/qbe" -j"$(nproc)" >/dev/null
(cd "$root/build/cproc" && ./configure >/dev/null && make -j"$(nproc)" cproc-qbe >/dev/null)
echo "built: $root/build/qbe/qbe $root/build/cproc/cproc-qbe"
