#!/usr/bin/env bash
# Path B stage 1: build a cpfe whose back end is ours (be/nfcxx_be.c) instead of EDG's C generator.
#
# 3rd/edg stays untouched. build/pathb/tree is a patched *view* of it: every entry is a symlink into the
# submodule except the few things we change:
#   src/CMakeLists.txt             c_gen_be.c -> nfcxx_be.c in CORE_FRONT_END_SOURCE_FILES
#   src/nfcxx_be.{c,h}, nfcxx_names.h   copies of be/ (the new back end and its name tables)
##   cmake/macro-conf/nfcxx-pathb/  macro config: BACK_END_IS_C_GEN_BE=0, DO_IL_LOWERING=1, everything else as
#                                  linux-gcc-release (so the IL is lowered exactly as the C generator sees it)
# Result: build/pathb/cmake/bin/cpfe. scripts/pathb-dump runs it from build/pathb/edg-base like the driver does.
# Reruns refresh the tree and rebuild only what changed (build/pathb/cmake is kept).
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
src=${PATHB_EDG_SRC:-$root/3rd/edg}   # PATHB_EDG_SRC: an EDG checkout elsewhere (worktrees with an empty 3rd/)
out=${PATHB_OUT:-$root/build/pathb}   # PATHB_OUT: build somewhere else (scratch builds, other checkouts)
tree=$out/tree

if [ ! -f "$src/CMakeLists.txt" ]; then
  git -C "$root" submodule update --init --depth 1 3rd/edg
fi

rm -rf "$tree"; mkdir -p "$tree/src" "$tree/cmake/macro-conf/nfcxx-pathb"  # keep $out/cmake: incremental rebuilds

# Symlink the submodule's top level, src/ and cmake/macro-conf/, so only what we patch is a real file.
link_all() { # link_all <from-dir> <to-dir> <exclude-name>...
  local from=$1 to=$2; shift 2
  for e in "$from"/* "$from"/.[!.]*; do
    [ -e "$e" ] || continue
    local n; n=$(basename "$e")
    for x in "$@"; do [ "$n" = "$x" ] && continue 2; done
    ln -s "$e" "$to/$n"
  done
}
link_all "$src" "$tree" src cmake
link_all "$src/src" "$tree/src" CMakeLists.txt
link_all "$src/cmake" "$tree/cmake" macro-conf
link_all "$src/cmake/macro-conf" "$tree/cmake/macro-conf" nfcxx-pathb

# 1. Back end swap: c_gen_be.c is no longer compiled; nfcxx_be.c takes its place in the CORE list.
sed 's/attribute\.c c_gen_be\.c cfe\.c/attribute.c nfcxx_be.c nfcxx_ir.c cfe.c/' "$src/src/CMakeLists.txt" > "$tree/src/CMakeLists.txt"
grep -q 'attribute.c nfcxx_be.c nfcxx_ir.c cfe.c' "$tree/src/CMakeLists.txt" || { echo "setup-pathb: CORE list patch failed" >&2; exit 1; }
cp "$root"/be/nfcxx_be.c "$root"/be/nfcxx_be.h "$root"/be/nfcxx_be_int.h "$root"/be/nfcxx_ir.c "$root"/be/nfcxx_names.h "$tree/src/"

# 2. Macro config. Same lowering options as linux-gcc-release, but the C back end (and its C++ sibling) off.
cat > "$tree/cmake/macro-conf/nfcxx-pathb/base.cmakedef" <<'CFG'
import <linux-gcc-release/base>
CFG
cat > "$tree/cmake/macro-conf/nfcxx-pathb/cpfe.cmakedef" <<'CFG'
# nfcxx Path B harness. The EDG C-generating back end is off; nfcxx_be.c defines back_end() instead.
BACK_END_IS_C_GEN_BE=0
BACK_END_IS_CP_GEN_BE=0
# IL lowering stays on, so the back end sees the lowered IL the C generator would see.
DO_IL_LOWERING=1
# Variable-length arrays are lowered by the front end, as the C generator's configuration does: the storage is a
# __vla_alloc call (EDG runtime, libC.a, malloc based) at the declaration and a __vla_dealloc call at every exit from
# the scope (end of block, break/continue/goto/return, and the EH cleanup list). QBE has no stack save/restore, so
# the earlier scheme (QBE alloc16, never released) could not free VLA storage at block exit.
LOWER_VARIABLE_LENGTH_ARRAYS=1
import <support/platform/linux/cpfe>
import <support/build-type/release/cpfe>
CFG
cat > "$tree/cmake/macro-conf/nfcxx-pathb/cpfe-cp.cmakedef" <<'CFG'
import <linux-gcc-release/cpfe-cp>
CFG
cat > "$tree/cmake/macro-conf/nfcxx-pathb/cdisp.cmakedef" <<'CFG'
import <linux-gcc-release/cdisp>
CFG

# 3. Base dir (predefined macros, EDG's own headers) as in setup-edg.sh.
base=$out/edg-base
rm -rf "$base"; cp -r "$src/bases/docker/dev-env/gcc" "$base"
# The base's include/ is a relative symlink into the submodule; cp -r copies the link text, which would dangle
# from build/pathb. Point it at the submodule absolutely.
rm -f "$base/include"; ln -s "$src/include_c++" "$base/include"

cd "$tree"
EDG_BASE=$base cmake -G Ninja -S "$tree" -B "$out/cmake" -DCMAKE_BUILD_TYPE=Release \
  -DEDG_MACRO_CONF=nfcxx-pathb -DCMAKE_C_COMPILER=gcc -DCMAKE_CXX_COMPILER=g++ >"$out/configure.log" 2>&1 \
  || { tail -30 "$out/configure.log" >&2; exit 1; }
cd "$out/cmake"
ninja ${PATHB_JOBS:+-j$PATHB_JOBS} bin/cpfe >"$out/build.log" 2>&1 || { grep -m20 -B2 -A8 'error' "$out/build.log" >&2; exit 1; }
echo "Path B cpfe built: $out/cmake/bin/cpfe (base dir: $base)"
