#!/usr/bin/env bash
# Build llama.cpp's SYCL backend (ggml/src/ggml-sycl, unchanged) into a libggml-sycl.so with nfcxx: every source is a
# separate scripts/sycl-build.sh -c compile (the device image beside each object, lib/sycl/include/sycl/rt_image.hpp),
# then one nfcxx -shared link against the libggml-base.so of a llama.cpp build. The library has the SONAME of the CMake
# build (libggml-sycl.so.0), so a ggml program finds it in place of the icpx one through LD_LIBRARY_PATH.
#
#   scripts/ggml-sycl-lib.sh [-j N] [--backend=level-zero|opencl] OUTDIR
#
# One source is replaced by lib/sycl-ggml/stubs: fused-gemm.cpp (joint_matrix; the stubs decline, so the unfused path
# runs). The oneMKL calls (gemm, gemm_batch, trsm_batch) are lib/sycl-ggml/oneapi/mkl.hpp's reference kernels. The macros
# are tests/gpu/ggml/sweep.sh's. A compile that fails is listed with its first error and the link is not run (exit 1).
# Objects are kept in OUTDIR/obj and rebuilt when missing or older than their source, a header of lib/sycl or
# lib/sycl-ggml, or the compilers (build/pathb, build/edg, cproc, qbe and their scripts).
# Env: GGML_SRC (the ggml-sycl source dir), GGML_BUILD (the bin dir with libggml-base.so), SPIRV_TOOLS_BIN.
set -uo pipefail
export PATH=${SPIRV_TOOLS_BIN:+$SPIRV_TOOLS_BIN:}$PATH
root=$(cd "$(dirname "$0")/.." && pwd)
ggml_src=${GGML_SRC:-/home/takecheeze/dev/llm/llama.cpp/ggml/src/ggml-sycl}
ggml_build=${GGML_BUILD:-/home/takecheeze/dev/llm/llama.cpp/build-sycl/bin}
jobs=4 backend=level-zero outdir=""
while [ $# -gt 0 ]; do
  case $1 in
    -j) jobs=$2; shift ;;
    --backend=*) backend=${1#--backend=} ;;
    -*) echo "ggml-sycl-lib: unknown option $1" >&2; exit 2 ;;
    *) outdir=$1 ;;
  esac
  shift
done
[ -n "$outdir" ] || { echo "usage: ggml-sycl-lib.sh [-j N] [--backend=level-zero|opencl] OUTDIR" >&2; exit 2; }
case $backend in level-zero) rtlib=-l:libze_loader.so.1 ;; opencl) rtlib=-l:libOpenCL.so.1 ;; *) echo "ggml-sycl-lib: --backend must be level-zero or opencl" >&2; exit 2 ;; esac
mkdir -p "$outdir/obj"
outdir=$(cd "$outdir" && pwd)
stubs=$root/lib/sycl-ggml/stubs
# the newest input every object depends on: a stamp file dated like it
stamp=$outdir/obj/.inputs
newest=$(find "$root/lib/sycl" "$root/lib/sycl-ggml" "$root/scripts/sycl-build.sh" "$root/scripts/pathb-spirv-emit.rb" \
  "$root/build/pathb/cmake/bin/cpfe" "$root/build/edg/bin/cpfe" "$root/build/cproc/cproc-qbe" "$root/build/qbe/qbe" \
  "$root/scripts/qbe-cc" "$root/scripts/qbe-prep.rb" "$root/scripts/weak-symbols" "$root/tools/weak-symbols/weak_symbols.cpp" "$root/nfcxx" -type f -printf '%T@ %p\n' 2>/dev/null | sort -n | tail -1 | cut -d' ' -f2-)
touch -r "$newest" "$stamp"
srcs=()
for f in "$ggml_src"/*.cpp; do
  b=$(basename "$f")
  if [ -f "$stubs/$b" ]; then srcs+=("$stubs/$b"); else srcs+=("$f"); fi
done
# the flash-attention template instances, as ggml-sycl's CMakeLists.txt adds them
for f in "$ggml_src"/template-instances/fattn-tile*.cpp "$ggml_src"/template-instances/fattn-vec*.cpp; do srcs+=("$f"); done

# one SRC: compiles one source to OUTDIR/obj/NAME.o; prints "NAME: ok (Ns)" or "NAME: FAIL" and the first error
one() {
  local f=$1 b log s
  b=$(basename "$f" .cpp)
  log=$outdir/obj/$b.log
  if [ -f "$outdir/obj/$b.o" ] && [ "$outdir/obj/$b.o" -nt "$f" ] && [ "$outdir/obj/$b.o" -nt "$outdir/obj/.inputs" ]; then
    echo "$b: ok (kept)"; return
  fi
  s=$(date +%s)
  if "$root/scripts/sycl-build.sh" --backend="$backend" -c -fPIC --ndebug --diag_warning=narrowing_conversion \
      -DGGML_SYCL_WARP_SIZE=16 -DGGML_SHARED -DGGML_BACKEND_BUILD -DGGML_BACKEND_SHARED -DGGML_SCHED_MAX_COPIES=4 \
      -DGGML_SYCL_DNNL=0 -DGGML_SYCL_F16 -DGGML_SYCL_HAS_BF16 -DGGML_SYCL_DMMV_HAS_BF16 -DGGML_SYCL_HOST_MEM_FALLBACK -D_GNU_SOURCE -D_XOPEN_SOURCE=600 -Dggml_sycl_EXPORTS \
      -I"$root/lib/sycl-ggml" -I"$ggml_src" -I"$ggml_src/../../include" -I"$ggml_src/.." \
      "$f" -o "$outdir/obj/$b.o" > "$log" 2>&1; then
    echo "$b: ok ($(( $(date +%s) - s ))s)"
  else
    rm -f "$outdir/obj/$b.o"
    echo "$b: FAIL $(grep -m1 -iE -A2 'error|refused|undefined' "$log" | tr -s ' \n' ' ' | cut -c1-240)"
  fi
}
export -f one
export root ggml_src outdir backend
printf '%s\n' "${srcs[@]}" | xargs -P "$jobs" -I{} bash -c 'one "$1"' _ {} | sort | tee "$outdir/compile.txt"
nfail=$(grep -c ': FAIL' "$outdir/compile.txt")
[ "$nfail" = 0 ] || { echo "ggml-sycl-lib: $nfail of ${#srcs[@]} sources failed; not linking"; exit 1; }

objs=("$outdir"/obj/*.o)
if ! "$root/nfcxx" -shared "${objs[@]}" -o "$outdir/libggml-sycl.so.0" -Wl,-soname,libggml-sycl.so.0 \
    -L"$ggml_build" -lggml-base -Wl,-rpath,"$ggml_build" $rtlib > "$outdir/link.log" 2>&1; then
  echo "ggml-sycl-lib: link FAIL"; grep -v prelinker "$outdir/link.log" | head -20; exit 1
fi
ln -sfn libggml-sycl.so.0 "$outdir/libggml-sycl.so"
echo "ggml-sycl-lib: $outdir/libggml-sycl.so.0 (${#objs[@]} objects)"
