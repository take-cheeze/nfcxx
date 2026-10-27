#!/usr/bin/env bash
# The device pass of every ggml-sycl source (GGML_SRC/*.cpp, unchanged), as scripts/sycl-build.sh --backend=opencl runs it:
# the Path B front end (scripts/pathb-dump --ir), the Kernel-capability SPIR-V emitter (pathb-spirv-emit.rb --kernel-cl) and
# spirv-val. Nothing is linked or run; the sweep says which TUs of the backend the front end and the emitter accept.
# The macros are the reference build's (compile_commands.json of build-sycl) without GGML_SYCL_SUPPORT_LEVEL_ZERO_API (the
# lib/sycl runtime reports the OpenCL backend, so ggml's Level Zero calls are not reached) and without GGML_SYCL_GRAPH (lib/sycl
# has no sycl_ext_oneapi_graph; both are CMake options of the backend), and with GGML_SYCL_HAS_BF16 and GGML_SYCL_DMMV_HAS_BF16:
# common.hpp and dmmv.cpp define them only for icpx (__INTEL_LLVM_COMPILER), and without them the backend still offers bf16
# ops and aborts in them ("GGML tensor type not supported", "dequantize_mul_mat_vec unsupported GGML_TYPE 30"); lib/sycl has
# sycl::ext::oneapi::bfloat16.
#
#   tests/gpu/ggml/sweep.sh [-j N] [FILE.cpp ...]     (default: every .cpp of GGML_SRC, 8 jobs)
#
# Prints one line per TU, `NAME: ok (K kernels)`, `NAME: FAIL (front end)`, `NAME: FAIL (emitter)` or `NAME: FAIL (spirv-val)`
# followed by the first error, then a count. Exit 1 when a TU fails. Env: GGML_SRC (the ggml-sycl source dir),
# SPIRV_TOOLS_BIN (the directory holding spirv-val, when not on PATH). Skips (exit 0) when either is missing.
set -uo pipefail
export PATH=${SPIRV_TOOLS_BIN:+$SPIRV_TOOLS_BIN:}$PATH
root=$(cd "$(dirname "$0")/../../.." && pwd)
ggml_src=${GGML_SRC:-/home/takecheeze/dev/llm/llama.cpp/ggml/src/ggml-sycl}
jobs=8
if [ "${1:-}" = -j ]; then jobs=$2; shift 2; fi
if ! command -v spirv-val >/dev/null || [ ! -f "$ggml_src/ggml-sycl.cpp" ]; then
  echo "SKIP: gpu ggml sweep: needs spirv-val and GGML_SRC/ggml-sycl.cpp"; exit 0
fi
files=("$@")
[ ${#files[@]} -gt 0 ] || files=("$ggml_src"/*.cpp)
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT

# one FILE: the device pass of one TU; prints its verdict line
one() {
  local f=$1 b
  b=$(basename "$f" .cpp)
  if ! "$root/scripts/pathb-dump" --ir -std=c++17 -D__NFCXX_SYCL_DEVICE__ -DNDEBUG --diag_warning=narrowing_conversion \
      -I"$root/lib/sycl/include" -DGGML_SYCL_WARP_SIZE=16 -DGGML_SHARED -DGGML_BACKEND_BUILD -DGGML_BACKEND_SHARED \
      -DGGML_SCHED_MAX_COPIES=4 -DGGML_SYCL_DNNL=0 -DGGML_SYCL_F16 -DGGML_SYCL_HAS_BF16 -DGGML_SYCL_DMMV_HAS_BF16 -DGGML_SYCL_HOST_MEM_FALLBACK \
      -D_GNU_SOURCE -D_XOPEN_SOURCE=600 -Dggml_sycl_EXPORTS \
      -I"$root/lib/sycl-ggml" -I"$ggml_src" -I"$ggml_src/../../include" -I"$ggml_src/.." "$f" > "$out/$b.ir" 2> "$out/$b.err"; then
    echo "$b: FAIL (front end) $(grep -m1 -A1 -E 'error' "$out/$b.err" | tr -s ' \n' ' ' | cut -c1-200)"; return
  fi
  if ! "$root/scripts/mrb" "$root/scripts/pathb-spirv-emit.rb" --kernel-cl --manifest="$out/$b.man" "$out/$b.ir" \
      > "$out/$b.spv" 2> "$out/$b.err"; then
    echo "$b: FAIL (emitter) $(head -1 "$out/$b.err" | cut -c1-200)"; return
  fi
  if [ -s "$out/$b.spv" ] && ! spirv-val --target-env opencl2.2 "$out/$b.spv" > "$out/$b.err" 2>&1; then
    echo "$b: FAIL (spirv-val) $(head -1 "$out/$b.err" | cut -c1-200)"; return
  fi
  local nk
  nk=$(grep -c '^k' "$out/$b.man" 2>/dev/null)
  echo "$b: ok (${nk:-0} kernels)"
  rm -f "$out/$b.ir" "$out/$b.spv"
}
export -f one
export root ggml_src out
printf '%s\n' "${files[@]}" | xargs -P "$jobs" -I{} bash -c 'one "$1"' _ {} | sort > "$out/verdicts"
cat "$out/verdicts"
n=$(wc -l < "$out/verdicts"); ok=$(grep -c ': ok (' "$out/verdicts")
echo "sweep: $ok of $n TUs pass the device pass"
[ "$ok" = "$n" ]
