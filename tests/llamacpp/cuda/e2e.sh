#!/usr/bin/env bash
# End-to-end inference on the CUDA backend: llama.cpp's examples/simple (llama-simple) on a GGUF model, with ggml and
# ggml-cuda as tests/llamacpp/cuda/build.sh compiled them through nfcxx (its objects in OUT/obj, except
# test-backend-ops.cpp). libllama (src/*.cpp, src/models/*.cpp) and simple.cpp are host-only C++ outside what is under
# test here, so they are compiled by the host g++ (into OUT/e2e); the link is nfcxx's, which the nfcxx objects need
# (their template instances, .ti beside each object).
# Usage: tests/llamacpp/cuda/e2e.sh MODEL.gguf [PROMPT] [OUT_DIR]   (default OUT_DIR build/llcu; run build.sh first)
# Env: LLAMA (clone, default build/targets/llama.cpp), CUDA_HOME, JOBS (default 2), NGL (layers on the GPU, default 99),
# N_PREDICT (default 32), E2E_BUILD_ONLY=1 (build and link only). Prints the generated text and exits with the
# program's status.
set -u
root=$(cd "$(dirname "$0")/../../.." && pwd)
model=${1:?usage: e2e.sh MODEL.gguf [PROMPT] [OUT_DIR]}
prompt=${2:-The capital of France is}
out=${3:-$root/build/llcu}
llama=${LLAMA:-$root/build/targets/llama.cpp}
cuda=${CUDA_HOME:-/usr/local/cuda}
[ -f "$out/sources" ] || { echo "e2e: no $out/sources (run tests/llamacpp/cuda/build.sh first)" >&2; exit 2; }
e2e=$out/e2e; mkdir -p "$e2e/gen"
sed 's/@LLAMA_VERSION@/0.0.0/; s/@LLAMA_BUILD_COMMIT@/test/' "$llama/src/llama-version.h.in" > "$e2e/gen/llama-version.h"
# -include algorithm: src/models/clef.cpp calls std::find without <algorithm>, which libstdc++ 15 no longer brings in
cxxflags="-std=c++17 -O2 -include algorithm -I$e2e/gen -I$llama/include -I$llama/src -I$llama/ggml/include"
srcs=("$llama"/src/*.cpp "$llama"/src/models/*.cpp "$llama/examples/simple/simple.cpp")
compile() {  # compile SRC: OUT/e2e/<path with / as _>.o, unless it is there
  local o; o=$e2e/$(echo "${1#"$llama"/}" | tr / _).o
  [ -f "$o" ] || ${CXX:-g++} $cxxflags -c "$1" -o "$o" || { echo "FAIL compile $1"; return 1; }
}
export -f compile; export llama e2e cxxflags
printf '%s\n' "${srcs[@]}" | xargs -d '\n' -n 1 -P "${JOBS:-2}" bash -c 'compile "$0"' || exit 1
# ggml's objects from build.sh: every source but the test program
objs=(); while IFS=$'\t' read -r f _; do
  case $f in */tests/test-backend-ops.cpp) continue ;; esac
  objs+=("$out/obj/$(echo "${f#"$llama"/}" | tr / _).o")
done < "$out/sources"
for s in "${srcs[@]}"; do objs+=("$e2e/$(echo "${s#"$llama"/}" | tr / _).o"); done
"$root/nfcxx" "${objs[@]}" -L"$cuda/lib64" -lcuda -lcublas -lcudart -lm -lpthread -lstdc++ -o "$e2e/llama-simple" \
  > "$e2e/link.log" 2>&1 || { echo "FAIL link: $(grep -m3 'undefined\|error' "$e2e/link.log" | cut -c1-200)"; exit 1; }
echo "linked $e2e/llama-simple"
[ "${E2E_BUILD_ONLY:-0}" = 1 ] && exit 0
"$e2e/llama-simple" -m "$model" -n "${N_PREDICT:-32}" -ngl "${NGL:-99}" "$prompt"
