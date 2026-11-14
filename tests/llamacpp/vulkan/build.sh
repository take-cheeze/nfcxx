#!/usr/bin/env bash
# llama.cpp's ggml with the Vulkan backend through the nfcxx driver, linked into test-backend-ops (llama.cpp's
# per-op check of each backend against the CPU). The host side is nfcxx's: vulkan-shaders-gen, ggml-vulkan*.cpp,
# the generated shader sources (SPIR-V byte arrays), the core and the CPU backend. The shaders themselves are GLSL and
# go through glslc, as in llama.cpp's own build, or through glslang (NFCXX_VK_GLSL=glslang: glslc-glslang.sh, the same
# command line with glslangValidator, see there). Objects are kept in OUT and a file is compiled again only when its
# object is missing, so a second run only links.
# Usage: tests/llamacpp/vulkan/build.sh [OUT_DIR]     (default: build/llvk); the program is OUT/test-backend-ops.
# Env: LLAMA (clone, default build/targets/llama.cpp), JOBS (default 4). Skips (exit 0) without the clone, the Vulkan
# headers or the shader compiler (glslc, or glslangValidator and spirv-opt with NFCXX_VK_GLSL=glslang).
set -uo pipefail
root=$(cd "$(dirname "$0")/../../.." && pwd)
llama=${LLAMA:-$root/build/targets/llama.cpp}
out=${1:-$root/build/llvk}
# The shader compiler: glslc (default), or glslang through glslc-glslang.sh (NFCXX_VK_GLSL=glslang).
case ${NFCXX_VK_GLSL:-glslc} in
  glslc) glslc_cmd=glslc ;;
  glslang) glslc_cmd=$root/tests/llamacpp/vulkan/glslc-glslang.sh ;;
  *) echo "FAIL NFCXX_VK_GLSL must be glslc or glslang"; exit 1 ;;
esac
have_glsl=0
if [ "$glslc_cmd" = glslc ]; then command -v glslc > /dev/null && have_glsl=1
else command -v glslangValidator > /dev/null && command -v spirv-opt > /dev/null && [ -x "$glslc_cmd" ] && have_glsl=1; fi
if [ ! -f "$llama/ggml/src/ggml.c" ] || [ ! -f /usr/include/vulkan/vulkan.hpp ] || [ $have_glsl = 0 ]; then
  echo "SKIP: llama.cpp clone ($llama), vulkan.hpp or the shader compiler (${NFCXX_VK_GLSL:-glslc}) missing"; exit 0
fi
vk=$llama/ggml/src/ggml-vulkan
mkdir -p "$out/obj" "$out/gen/vk" "$out/spv" "$out/tmp"
export NFCXX_BACKEND=gcc TMPDIR=$out/tmp
# NFCXX_PATH=b (Path B for the C++): the C files go through gcc too (qbe-cc has no _Atomic, which ggml-cpu.c uses).
[ "${NFCXX_PATH:-}" != b ] || export NFCXX_PATHB_C=gcc
sed 's/@GGML_VERSION@/0.0.0/; s/@GGML_BUILD_COMMIT@/test/' "$llama/ggml/src/ggml-version.h.in" > "$out/gen/ggml-version.h"

# The glslc extension probes of ggml-vulkan/CMakeLists.txt (test_shader_extension_support): a definition for each
# extension this glslc accepts, for vulkan-shaders-gen and for ggml-vulkan.cpp alike.
vkdefs=""
for t in coopmat:COOPMAT coopmat2:COOPMAT2 coopmat2_decode_vector:COOPMAT2_DECODE_VECTOR integer_dot:INTEGER_DOT \
         bfloat16:BFLOAT16 float_e2m1:FLOAT_E2M1 float_e4m3:FLOAT_E4M3; do
  # The message, not the exit status, decides (as in CMake): glslc fails for other reasons too.
  msg=$("$glslc_cmd" -o /dev/null -fshader-stage=compute --target-env=vulkan1.3 "$vk/vulkan-shaders/feature-tests/${t%%:*}.comp" 2>&1)
  case $msg in *"extension not supported"*) ;; *) vkdefs+=" -DGGML_VULKAN_${t#*:}_GLSLC_SUPPORT" ;; esac
done
echo "shader compiler ${glslc_cmd##*/} extensions:$vkdefs"

gen=$out/vulkan-shaders-gen
if [ ! -x "$gen" ]; then
  # shellcheck disable=SC2086
  "$root/nfcxx" -std=c++17 $vkdefs "$vk/vulkan-shaders/vulkan-shaders-gen.cpp" -lpthread -o "$gen" > "$out/gen.log" 2>&1 ||
    { echo "FAIL vulkan-shaders-gen: $(grep -m1 -E ' error|refused:' "$out/gen.log" | cut -c1-160)"; exit 1; }
fi
hpp=$out/gen/ggml-vulkan-shaders.hpp
[ -f "$hpp" ] || "$gen" --output-dir "$out/spv" --target-hpp "$hpp" > "$out/shaders.log" 2>&1 ||
  { echo "FAIL shader header"; exit 1; }
export gen hpp out glslc_cmd
gen_one() {
  local f=$1 b; b=$(basename "$f")
  [ -f "$out/gen/vk/$b.cpp" ] && return 0
  "$gen" --glslc "$glslc_cmd" --source "$f" --output-dir "$out/spv" --target-hpp "$hpp" --target-cpp "$out/gen/vk/$b.cpp" \
    > "$out/gen/vk/$b.log" 2>&1 || { rm -f "$out/gen/vk/$b.cpp"; echo "FAIL shader $b"; return 1; }
}
export -f gen_one
ls "$vk"/vulkan-shaders/*.comp | xargs -P "$(nproc)" -n 1 bash -c 'gen_one "$0"' || { echo "shader failures"; exit 1; }

inc="-I$llama/ggml/include -I$llama/ggml/src -I$llama/ggml/src/ggml-cpu -I$out/gen -D_GNU_SOURCE"
export root inc vkdefs
# OpenMP for the ggml CPU backend, as llama.cpp's CMake builds it by default (GGML_OPENMP=ON): with it the CPU workers are
# OpenMP threads that sleep when idle. Without it ggml runs its own thread pool, whose workers busy-wait between graphs
# (about 60% of a core each in a decode run). NFCXX_OPENMP=0 builds without it.
if [ "${NFCXX_OPENMP:-1}" != 0 ]; then cpu_omp="-fopenmp -DGGML_USE_OPENMP"; omp_link="-fopenmp -lgomp"
else cpu_omp=""; omp_link=""; fi
export cpuflags="-DGGML_CPU_GENERIC $cpu_omp"
export cpuxxflags="-DGGML_CPU_GENERIC -U__SSE__ -U__SSE2__ -U__SSE3__ -U__SSSE3__ $cpu_omp"

# One line per source: SOURCE<TAB>KIND. The object name is the path under llama.cpp (or OUT) with / as _.
{
  for f in "$llama"/ggml/src/*.c; do printf '%s\t\n' "$f"; done
  for f in "$llama"/ggml/src/*.cpp; do printf '%s\tcxx\n' "$f"; done
  for f in "$llama"/ggml/src/ggml-cpu/*.c; do printf '%s\tcpuflags\n' "$f"; done
  for f in "$llama"/ggml/src/ggml-cpu/*.cpp "$llama"/ggml/src/ggml-cpu/tiled/*.cpp; do printf '%s\tcpuxxflags\n' "$f"; done
  for f in "$vk"/*.cpp; do printf '%s\tvk\n' "$f"; done
  # The biggest first: mul_mm.comp.cpp (about 77 MB of byte arrays) takes the longest.
  ls -S "$out"/gen/vk/*.cpp | while read -r f; do printf '%s\tvk\n' "$f"; done
  printf '%s\tcxx\n' "$llama/tests/test-backend-ops.cpp"
} > "$out/sources"

objname() { local f=${1#"$LLAMA_ROOT"/}; f=${f#"$out"/}; echo "$out/obj/$(echo "$f" | tr / _).o"; }
compile_one() {
  local f=$1 kind=$2 o flags
  o=$(objname "$f")
  [ -f "$o" ] && return 0
  case $kind in
    cxx) flags="-std=c++17 -DGGML_USE_CPU -DGGML_USE_VULKAN" ;;
    vk) flags="-std=c++17 $vkdefs" ;;
    cpuxxflags) flags="-std=c++17 $cpuxxflags" ;;
    '') flags="-DGGML_USE_CPU -DGGML_USE_VULKAN" ;;
    *) flags=${!kind} ;;
  esac
  # NDEBUG as in llama.cpp's Release build (the reference the comparisons use): assert() compiles out, so the host code
  # carries no assertion checks on its hot paths. GGML_ASSERT stays on, as it does there.
  flags="$flags -DNDEBUG"
  local start=$SECONDS
  # shellcheck disable=SC2086
  # NFCXX_PATH=b: the generated shader files are byte tables and no code. Path B's route takes minutes per megabyte of
  # such data (scripts/pathb-ssa-build), so they are compiled by the host g++ (NFCXX_DATA_CXX), and the code is Path B's.
  local driver=$root/nfcxx
  if [ "${NFCXX_PATH:-}" = b ] && [ "$kind" = vk ] && [[ $f == */gen/vk/*.cpp ]]; then driver=${NFCXX_DATA_CXX:-g++}; fi
  if timeout 2400 "$driver" -c $inc $flags "$f" -o "$o" > "${o%.o}.log" 2>&1; then
    echo "ok   $((SECONDS - start))s ${f#"$LLAMA_ROOT"/}"
  else
    rm -f "$o"; echo "FAIL ${f#"$LLAMA_ROOT"/}: $(grep -m1 -E ' error|refused:|cannot open' "${o%.o}.log" | cut -c1-160)"
    return 1
  fi
}
export -f compile_one objname
export LLAMA_ROOT=$llama
fail=0
tr '\t' '\n' < "$out/sources" | xargs -d '\n' -n 2 -P "${JOBS:-4}" bash -c 'compile_one "$0" "$1"' || fail=1
[ $fail = 0 ] || { echo "compile failures: see $out/obj/*.log"; exit 1; }

objs=(); while IFS=$'\t' read -r f _; do objs+=("$(objname "$f")"); done < "$out/sources"
# NFCXX_PATH=b: the object-only link is not Path B's link, so the runtime archive (scripts/pathb-ldrt: _mm_pause and the
# long double helpers) goes on the line here.
[ "${NFCXX_PATH:-}" != b ] || objs+=("$("$root/scripts/pathb-ldrt")")
if "$root/nfcxx" "${objs[@]}" $omp_link -lvulkan -lm -lpthread -lstdc++ -o "$out/test-backend-ops" > "$out/link.log" 2>&1; then
  echo "linked $out/test-backend-ops (${#objs[@]} objects)"
else
  echo "FAIL link: $(grep -m3 'undefined\|error' "$out/link.log" | cut -c1-200)"; exit 1
fi
