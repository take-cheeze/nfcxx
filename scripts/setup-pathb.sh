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
# EDG's top CMakeLists.txt builds a Release on macOS as a universal binary (CMAKE_OSX_ARCHITECTURES arm64;x86_64). The
# harness is for the host only: its SoftFloat archive is the host's, so a second architecture cannot link. Drop that line.
rm -f "$tree/CMakeLists.txt"
sed '/set(CMAKE_OSX_ARCHITECTURES "arm64;x86_64")/d' "$src/CMakeLists.txt" > "$tree/CMakeLists.txt"
! grep -q 'CMAKE_OSX_ARCHITECTURES "arm64;x86_64"' "$tree/CMakeLists.txt" || { echo "setup-pathb: universal-binary patch failed" >&2; exit 1; }

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
# Floating point: SoftFloat (EDG's USE_SOFTFLOAT, as its Windows configuration) on every host. Without it EDG takes the
# host's float128 (defines_linux.h), which Apple clang lacks on arm64. Berkeley SoftFloat 3e, pinned, with x86's NaN
# rules (8086-SSE), built with the host C compiler into build/softfloat-native.
sf=$root/build/softfloat-native
sf_commit=497c81c1f5016dc6ef5b3219ece2f3c261d4d8f1; sf_config=${PATHB_SOFTFLOAT_CONFIG:-Linux-x86_64-GCC}
sf_cc=${CC:-cc}; sf_ar=${AR:-ar}
if [ ! -f "$sf/build/$sf_config/softfloat.a" ] || [ "$(git -C "$sf" rev-parse HEAD 2>/dev/null)" != $sf_commit ]; then
  command -v "$sf_cc" >/dev/null || { echo "setup-pathb: $sf_cc is not on PATH" >&2; exit 1; }
  rm -rf "$sf"; git clone -q https://github.com/ucb-bar/berkeley-softfloat-3.git "$sf"
  git -C "$sf" checkout -q $sf_commit
  make -s -C "$sf/build/$sf_config" -j"${PATHB_JOBS:-4}" MAKELIB="$sf_ar crs \$@" \
    COMPILE_C="$sf_cc -c -Werror-implicit-function-declaration -DSOFTFLOAT_FAST_INT64 \$(SOFTFLOAT_OPTS) \$(C_INCLUDES) -O2 -o \$@"
fi
export EDG_SOFTFLOAT_INCLUDE_PATH=$sf/source/include EDG_SOFTFLOAT_LIB_PATH=$sf/build/$sf_config/softfloat.a
cat >> "$tree/cmake/macro-conf/nfcxx-pathb/base.cmakedef" <<'CFG'
USE_SOFTFLOAT=1
USE_FLOAT128_FOR_HOST_FP_VALUE=0
USE_QUADMATH_LIBRARY=0
CFG
# The target is x86-64 for every host: EDG otherwise infers the x86 asm extensions from the host compiler's macros
# (__x86_64 in lang_feat.h), so an arm64 host compiles nfcxx_ir.c without the x86 asm operand classes it names
# (aoc_reg_a, aoc_cc, ...). Path B emits x86-64 code (pathb-cc), so the front end parses x86 asm for that target on
# every host. On an x86-64 Linux host these are the values EDG already infers.
cat >> "$tree/cmake/macro-conf/nfcxx-pathb/cpfe.cmakedef" <<'CFG'
TARG_SUPPORTS_X86_64=1
GNU_X86_ASM_EXTENSIONS_ALLOWED=1
GNU_X86_ATTRIBUTES_ALLOWED=1
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
rm -rf "$base/include"; ln -s "$src/include_c++" "$base/include"

cd "$tree"
EDG_BASE=$base cmake -G Ninja -S "$tree" -B "$out/cmake" -DCMAKE_BUILD_TYPE=Release \
  -DEDG_MACRO_CONF=nfcxx-pathb -DCMAKE_C_COMPILER=gcc -DCMAKE_CXX_COMPILER=g++ >"$out/configure.log" 2>&1 \
  || { tail -30 "$out/configure.log" >&2; exit 1; }
cd "$out/cmake"
ninja ${PATHB_JOBS:+-j$PATHB_JOBS} bin/cpfe >"$out/build.log" 2>&1 || { grep -m20 -B2 -A8 'error' "$out/build.log" >&2; exit 1; }
echo "Path B cpfe built: $out/cmake/bin/cpfe (base dir: $base)"
