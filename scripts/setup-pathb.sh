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
#   PATHB_EMSCRIPTEN=1   build the same cpfe for the browser with Emscripten (emcc on PATH: scripts/setup-emsdk.sh) into
#                        build/pathb-wasm: cmake/bin/cpfe.js and cpfe.wasm, a module (createCpfe) whose callMain runs one
#                        compilation, with Emscripten's in-memory file system (docs/notes/pathb-wasm-frontend.md)
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
src=${PATHB_EDG_SRC:-$root/3rd/edg}   # PATHB_EDG_SRC: an EDG checkout elsewhere (worktrees with an empty 3rd/)
emscripten=${PATHB_EMSCRIPTEN:-0}
if [ "$emscripten" = 1 ]; then out=${PATHB_OUT:-$root/build/pathb-wasm}; else out=${PATHB_OUT:-$root/build/pathb}; fi
# PATHB_OUT: build somewhere else (scratch builds, other checkouts)
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
link_all "$src/src" "$tree/src" CMakeLists.txt attribute.c
link_all "$src/cmake" "$tree/cmake" macro-conf
link_all "$src/cmake/macro-conf" "$tree/cmake/macro-conf" nfcxx-pathb

# 1. Back end swap: c_gen_be.c is no longer compiled; nfcxx_be.c takes its place in the CORE list.
sed 's/attribute\.c c_gen_be\.c cfe\.c/attribute.c nfcxx_be.c nfcxx_ir.c cfe.c/' "$src/src/CMakeLists.txt" > "$tree/src/CMakeLists.txt"
grep -q 'attribute.c nfcxx_be.c nfcxx_ir.c cfe.c' "$tree/src/CMakeLists.txt" || { echo "setup-pathb: CORE list patch failed" >&2; exit 1; }
cp "$root"/be/nfcxx_be.c "$root"/be/nfcxx_be.h "$root"/be/nfcxx_be_int.h "$root"/be/nfcxx_ir.c "$root"/be/nfcxx_names.h "$tree/src/"

# 1b. SYCL kernel attributes: [[sycl::reqd_sub_group_size(N)]] is a known attribute (namespace sycl, one integral
# constant argument, evaluated in the template instance), so the back end can read N (be/nfcxx_ir.c: ir_kernel_attrs).
# ggml-sycl's flash-attention tile kernels need 32-lane sub-groups; without the entry EDG drops the attribute.
rm -f "$tree/src/attribute.c"   # a symlink into the EDG checkout: the patched table must be a file of its own
sed -e 's/^  "_Clang",$/  "_Clang",\n  "sycl",/' \
    -e 's/^  { "carries_dependency", "", "c+", ak_carries_dependency },$/&\n  { "reqd_sub_group_size", "(ci)", "c+[sycl]", ak_unrecognized },/' \
  "$src/src/attribute.c" > "$tree/src/attribute.c"
grep -q '"reqd_sub_group_size", "(ci)"' "$tree/src/attribute.c" && grep -q '^  "sycl",$' "$tree/src/attribute.c" ||
  { echo "setup-pathb: attribute table patch failed" >&2; exit 1; }

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
if [ "$emscripten" = 1 ]; then
  # Floating point: SoftFloat (EDG's USE_SOFTFLOAT, as its Windows configuration), not the host's types. Without it EDG
  # keeps a target long double (x86-64's 80-bit x87 format) in the host's long double, which on wasm32 is binary128
  # (float_pt.c: fetch_host_fp_value, the comment in store_host_fp_value). Berkeley SoftFloat 3e, pinned, with x86's
  # NaN rules (8086-SSE), built with emcc into build/softfloat.
  sf=$root/build/softfloat; sf_commit=497c81c1f5016dc6ef5b3219ece2f3c261d4d8f1
  if [ ! -f "$sf/build/Linux-x86_64-GCC/softfloat.a" ] || [ "$(git -C "$sf" rev-parse HEAD 2>/dev/null)" != $sf_commit ]; then
    command -v emcc >/dev/null || { echo "setup-pathb: emcc is not on PATH (scripts/setup-emsdk.sh, then source its env)" >&2; exit 1; }
    rm -rf "$sf"; git clone -q https://github.com/ucb-bar/berkeley-softfloat-3.git "$sf"
    git -C "$sf" checkout -q $sf_commit
    make -s -C "$sf/build/Linux-x86_64-GCC" -j"${PATHB_JOBS:-4}" MAKELIB='emar crs $@' \
      COMPILE_C='emcc -c -Werror-implicit-function-declaration -DSOFTFLOAT_FAST_INT64 $(SOFTFLOAT_OPTS) $(C_INCLUDES) -O2 -o $@'
  fi
  export EDG_SOFTFLOAT_INCLUDE_PATH=$sf/source/include EDG_SOFTFLOAT_LIB_PATH=$sf/build/Linux-x86_64-GCC/softfloat.a
  # The host integers EDG holds target sizes and offsets in (a_targ_size_t is a_host_large_unsigned) are the host's
  # ptrdiff_t and size_t, 32 bits on wasm32, too small for x86-64's size_t (SIZE_MAX became 2^32 - 1). targ_def.h allows
  # any large host integer there: the tree's copy (never the submodule's) takes the 64-bit ones.
  rm -f "$tree/src/targ_def.h"
  sed -e 's/^typedef a_ptrdiff a_host_large_integer;$/typedef long long a_host_large_integer;  \/* nfcxx: 64-bit on wasm32 *\//' \
      -e 's/^typedef sizeof_t a_host_large_unsigned;$/typedef unsigned long long a_host_large_unsigned;  \/* nfcxx *\//' \
      -e 's/^#define MAX_HOST_LARGE_INTEGER PTRDIFF_MAX$/#define MAX_HOST_LARGE_INTEGER LLONG_MAX/' \
      -e 's/^#define MIN_HOST_LARGE_INTEGER PTRDIFF_MIN$/#define MIN_HOST_LARGE_INTEGER LLONG_MIN/' \
      -e 's/^#define MAX_HOST_LARGE_UNSIGNED SIZE_MAX$/#define MAX_HOST_LARGE_UNSIGNED ULLONG_MAX/' \
      "$src/src/targ_def.h" > "$tree/src/targ_def.h"
  [ "$(grep -c 'nfcxx' "$tree/src/targ_def.h")" = 2 ] && grep -q 'ULLONG_MAX$' "$tree/src/targ_def.h" \
    || { echo "setup-pathb: targ_def.h patch failed" >&2; exit 1; }
  cat >> "$tree/cmake/macro-conf/nfcxx-pathb/base.cmakedef" <<'CFG'
USE_SOFTFLOAT=1
USE_FLOAT128_FOR_HOST_FP_VALUE=0
USE_QUADMATH_LIBRARY=0
CFG
  # The target is the native build's, x86-64 Linux, which EDG otherwise infers from the host compiler's macros
  # (__linux__ selects defines_linux.h, __x86_64 these flags); a wasm32 host has neither. __linux__ is defined for
  # cpfe's sources below. tests: the IR of the native and of this front end are compared (pathb-wasm-frontend.md).
  cat >> "$tree/cmake/macro-conf/nfcxx-pathb/cpfe.cmakedef" <<'CFG'
TARG_SUPPORTS_X86_64=1
GNU_X86_ASM_EXTENSIONS_ALLOWED=1
GNU_X86_ATTRIBUTES_ALLOWED=1
CFG
  # ... and EDG takes its host's alignments from the target too (defines_linux.h, targ_def.h): these are wasm32's, which
  # the front end checks when it starts (il_alloc.c, check_host_alignment). They lay out its own memory only. A constant
  # is 8-aligned (its 64-bit host integers, below), a pointer 4.
  cat >> "$tree/cmake/macro-conf/nfcxx-pathb/cpfe.cmakedef" <<'CFG'
HOST_ALIGNMENT_REQUIRED=8
HOST_POINTER_ALIGNMENT=4
CFG
  # The largest size_t the front end represents: x86-64's, not the host's ULONG_MAX (targ_def.h's default).
  echo 'TARG_SIZE_T_MAX=18446744073709551615ULL' >> "$tree/cmake/macro-conf/nfcxx-pathb/cpfe.cmakedef"
fi
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
if [ "$emscripten" = 1 ]; then
  command -v emcc >/dev/null || { echo "setup-pathb: emcc is not on PATH (scripts/setup-emsdk.sh, then source its env)" >&2; exit 1; }
  # A module rather than a program: the page instantiates it per compilation (callMain), with the source, EDG's base
  # directory and the headers in its in-memory file system. The front end recurses deeply on large inputs: a big stack.
  # emcmake runs the build's own tool (mk_errinfo, the error tables) under node.
  # mk_errinfo, a tool the build runs (under node), writes the error tables to the disk: NODERAWFS.
  cat >> "$tree/src/CMakeLists.txt" <<'CM'

# nfcxx (scripts/setup-pathb.sh, PATHB_EMSCRIPTEN=1): cpfe as a module for the browser
target_link_options(mk_errinfo PRIVATE -sNODERAWFS=1)
# __linux__ also selects glibc's __isnan(double) in float_pt.c, which musl does not have: the same test as a builtin
target_compile_definitions(cpfe PRIVATE __linux__=1)
target_compile_options(cpfe PRIVATE "-D__isnan(x)=__builtin_isnan(x)")   # a function-like macro: not a definition
target_link_options(cpfe PRIVATE -sMODULARIZE=1 -sEXPORT_NAME=createCpfe -sINVOKE_RUN=0 -sEXIT_RUNTIME=1
  -sALLOW_MEMORY_GROWTH=1 -sSTACK_SIZE=8MB -sFORCE_FILESYSTEM=1 -sENVIRONMENT=web,worker,node
  -sEXPORTED_RUNTIME_METHODS=callMain,FS,ENV -lnodefs.js)
CM
  EDG_BASE=$base emcmake cmake -G Ninja -S "$tree" -B "$out/cmake" -DCMAKE_BUILD_TYPE=Release \
    -DEDG_MACRO_CONF=nfcxx-pathb >"$out/configure.log" 2>&1 \
    || { tail -30 "$out/configure.log" >&2; exit 1; }
  target=cpfe
else
  EDG_BASE=$base cmake -G Ninja -S "$tree" -B "$out/cmake" -DCMAKE_BUILD_TYPE=Release \
    -DEDG_MACRO_CONF=nfcxx-pathb -DCMAKE_C_COMPILER=gcc -DCMAKE_CXX_COMPILER=g++ >"$out/configure.log" 2>&1 \
    || { tail -30 "$out/configure.log" >&2; exit 1; }
  target=bin/cpfe
fi
cd "$out/cmake"
ninja ${PATHB_JOBS:+-j$PATHB_JOBS} $target >"$out/build.log" 2>&1 || { grep -m20 -B2 -A8 'error' "$out/build.log" >&2; exit 1; }
if [ "$emscripten" = 1 ]; then
  echo "Path B cpfe built for the browser: $out/cmake/bin/cpfe.js, cpfe.wasm (base dir: $base)"
else
  echo "Path B cpfe built: $out/cmake/bin/cpfe (base dir: $base)"
fi
