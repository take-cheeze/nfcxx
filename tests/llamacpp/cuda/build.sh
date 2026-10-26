#!/usr/bin/env bash
# llama.cpp's ggml with the CUDA backend through the nfcxx driver, linked into test-backend-ops (llama.cpp's
# per-op check of each backend against the CPU). Objects are kept in OUT and a file is compiled again only when its
# object is missing, so a second run only links. Compiles on the gcc backend, flags as llama.cpp's CMake gives them
# by default (FlashAttention: only f16-f16), the CPU backend with GGML_CPU_GENERIC (tests/llamacpp/run.sh).
# Usage: tests/llamacpp/cuda/build.sh [OUT_DIR]     (default: build/llcu); the program is OUT/test-backend-ops.
# Env: LLAMA (clone, default build/targets/llama.cpp), CUDA_HOME (default /usr/local/cuda), JOBS (default 2:
# ggml-cuda.cu alone takes about 7.5 GB). Skips (exit 0) without the clone or the CUDA headers.
set -uo pipefail
root=$(cd "$(dirname "$0")/../../.." && pwd)
llama=${LLAMA:-$root/build/targets/llama.cpp}
cuda=${CUDA_HOME:-/usr/local/cuda}
out=${1:-$root/build/llcu}
if [ ! -f "$llama/ggml/src/ggml.c" ] || [ ! -f "$cuda/include/cuda_runtime.h" ]; then
  echo "SKIP: llama.cpp clone ($llama) or CUDA headers ($cuda) missing"; exit 0
fi
mkdir -p "$out/obj" "$out/gen" "$out/tmp"
export NFCXX_BACKEND=gcc TMPDIR=$out/tmp
sed 's/@GGML_VERSION@/0.0.0/; s/@GGML_BUILD_COMMIT@/test/' "$llama/ggml/src/ggml-version.h.in" > "$out/gen/ggml-version.h"
fa=(); for k in q4_0 q4_1 q5_0 q5_1 q8_0 bf16 f16; do for v in q4_0 q4_1 q5_0 q5_1 q8_0 bf16 f16; do
  on=0; [ "$k-$v" = f16-f16 ] && on=1; fa+=("-DGGML_CUDA_FA_$(echo "${k}_${v}" | tr a-z A-Z)=$on"); done; done
inc="-I$llama/ggml/include -I$llama/ggml/src -I$llama/ggml/src/ggml-cpu -I$out/gen -D_GNU_SOURCE"
export root out inc
export cuflags="-std=c++17 -DGGML_USE_CUDA ${fa[*]} -I$root/lib/cuda/host -I$cuda/include -I$cuda/include/cccl -I$llama/ggml/src/ggml-cuda"
export cpuflags="-DGGML_CPU_GENERIC"
export cpuxxflags="-DGGML_CPU_GENERIC -U__SSE__ -U__SSE2__ -U__SSE3__ -U__SSSE3__"

# One line per source: SOURCE<TAB>FLAGS-VARIABLE. The object name is the path under llama.cpp with / as __.
{
  for f in "$llama"/ggml/src/*.c; do printf '%s\t\n' "$f"; done
  for f in "$llama"/ggml/src/*.cpp; do printf '%s\tcxx\n' "$f"; done
  for f in "$llama"/ggml/src/ggml-cpu/*.c; do printf '%s\tcpuflags\n' "$f"; done
  for f in "$llama"/ggml/src/ggml-cpu/*.cpp "$llama"/ggml/src/ggml-cpu/tiled/*.cpp; do printf '%s\tcpuxxflags\n' "$f"; done
  find "$llama/ggml/src/ggml-cuda" -name '*.cu' | sort | while read -r f; do printf '%s\tcuflags\n' "$f"; done
  printf '%s\tcxx\n' "$llama/tests/test-backend-ops.cpp"
} > "$out/sources"

# The core files are compiled with the backends they register (ggml-backend-reg.cpp: GGML_USE_CPU, GGML_USE_CUDA).
compile_one() {
  local f=$1 kind=$2 n flags
  n=$(echo "${f#"$LLAMA_ROOT"/}" | tr / _); o=$out/obj/$n.o
  [ -f "$o" ] && return 0
  case $kind in
    cxx) flags="-std=c++17 -DGGML_USE_CPU -DGGML_USE_CUDA" ;;
    cpuxxflags) flags="-std=c++17 $cpuxxflags" ;;
    '') flags="-DGGML_USE_CPU -DGGML_USE_CUDA" ;;
    *) flags=${!kind} ;;
  esac
  local start=$SECONDS
  # Straight to the object's name: the prelinker records it, and the link reads <stem>.ti and <stem>.ii beside it.
  # shellcheck disable=SC2086
  if timeout 2400 "$root/nfcxx" -c $inc $flags "$f" -o "$o" > "$out/obj/$n.log" 2>&1; then
    echo "ok   $((SECONDS - start))s ${f#"$LLAMA_ROOT"/}"
  else
    rm -f "$o"; echo "FAIL ${f#"$LLAMA_ROOT"/}: $(grep -m1 -E ' error|refused:|cannot open' "$out/obj/$n.log" | cut -c1-160)"
    return 1
  fi
}
export -f compile_one
export LLAMA_ROOT=$llama
fail=0
tr '\t' '\n' < "$out/sources" | xargs -d '\n' -n 2 -P "${JOBS:-2}" bash -c 'compile_one "$0" "$1"' || fail=1
[ $fail = 0 ] || { echo "compile failures: see $out/obj/*.log"; exit 1; }

objs=(); while IFS=$'\t' read -r f _; do objs+=("$out/obj/$(echo "${f#"$llama"/}" | tr / _).o"); done < "$out/sources"
if "$root/nfcxx" "${objs[@]}" -L"$cuda/lib64" -lcuda -lcublas -lcudart -lm -lpthread -lstdc++ \
   -o "$out/test-backend-ops" > "$out/link.log" 2>&1; then
  echo "linked $out/test-backend-ops (${#objs[@]} objects)"
else
  echo "FAIL link: $(grep -m3 'undefined\|error' "$out/link.log" | cut -c1-200)"; exit 1
fi
