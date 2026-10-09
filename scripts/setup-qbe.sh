#!/usr/bin/env bash
# Build the QBE back end (3rd/qbe) and the cproc C front end (3rd/cproc) into
# build/qbe and build/cproc. Both build in a copy of the source so the
# submodules stay clean.
#
# Pinning: upstream QBE (c9x.me) isn't a submodule because it's unreachable from
# some CI/sandbox networks; 3rd/qbe is michaelforney/qbe (2021). cproc is pinned
# to the last commit before it started emitting the `call extern` keyword that
# this older QBE can't parse. Move both forward together.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
git -C "$root" submodule update --init 3rd/qbe 3rd/cproc

for p in qbe cproc; do
  rm -rf "$root/build/$p"; mkdir -p "$root/build"
  cp -r "$root/3rd/$p" "$root/build/$p"
  rm -rf "$root/build/$p/.git"
done
make -C "$root/build/qbe" -j"$(nproc)" >/dev/null
cp "$root/build/qbe/obj/qbe" "$root/build/qbe/qbe"
(cd "$root/build/cproc" && ./configure >/dev/null && make -j"$(nproc)" cproc-qbe >/dev/null)
echo "built: $root/build/qbe/qbe $root/build/cproc/cproc-qbe"
