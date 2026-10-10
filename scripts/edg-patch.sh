#!/usr/bin/env bash
# Apply scripts/edg-patches/*.patch (a/src/..., -p1) to an overlay of the EDG source tree.
# Usage: edg-patch.sh <overlay-dir>
# <overlay-dir> is a tree whose entries are symlinks into the 3rd/edg submodule (setup-edg.sh, setup-pathb.sh
# build one). A file a patch touches is replaced by a private copy first, so the submodule is never written.
# NFCXX_EDG_PATCHES=0 applies none (an unpatched build to compare against). See docs/notes/eval-order.md.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
ov=$1
[ "${NFCXX_EDG_PATCHES:-1}" != 0 ] || exit 0
shopt -s nullglob
for p in "$root"/scripts/edg-patches/*.patch; do
  for f in $(sed -n 's,^+++ b/,,p' "$p"); do
    if [ -L "$ov/$f" ]; then cp --remove-destination "$(readlink "$ov/$f")" "$ov/$f"; fi
  done
  patch -s -p1 -d "$ov" < "$p"
done
