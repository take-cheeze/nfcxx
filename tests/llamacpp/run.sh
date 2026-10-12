#!/usr/bin/env bash
# llama.cpp's host-side ggml (ggml/src/*.c, *.cpp and ggml-cpu/) through the nfcxx driver, on the gcc backend.
# The clone is build/targets/llama.cpp (git clone --depth 1 https://github.com/ggml-org/llama.cpp.git); missing -> SKIP.
#
# Checks: every core and CPU-backend source compiles (C through the C path, C++ with -std=c++17); the link of
# tests/llamacpp/ggml_cpu_check.c against those objects reports the blocker recorded in BLOCKER below and nothing
# else (XFAIL), so a new failure or a fixed link shows up. Flags follow llama.cpp's CMake for Linux, with two
# probe-only choices: GGML_CPU_GENERIC (no x86 SIMD code) and the SSE predefines removed, because gcc 15's
# immintrin.h needs AVX10.2 builtins that EDG does not know (docs/notes/llamacpp.md).
set -euo pipefail
cd "$(dirname "$0")"
root=$(cd ../.. && pwd)
L=${LLAMA_CPP:-$root/build/targets/llama.cpp}
BLOCKER='undefined reference to `_ZNSt12__shared_ptrINSt10filesystem7__cxx114_DirELN9__gnu_cxx12_Lock_policyE2EED1Ev'"'"
if [ ! -f "$L/ggml/src/ggml.c" ]; then echo "SKIP: llamacpp: no clone at $L"; exit 0; fi

fail=0
out=$(mktemp -d); trap 'rm -rf "$out"' EXIT
export NFCXX_BACKEND=gcc TMPDIR=$out
mkdir -p "$out/gen"
sed 's/@GGML_VERSION@/0.0.0/; s/@GGML_BUILD_COMMIT@/test/' "$L/ggml/src/ggml-version.h.in" > "$out/gen/ggml-version.h"
inc=(-I"$L/ggml/include" -I"$L/ggml/src" -I"$L/ggml/src/ggml-cpu" -I"$out/gen" -D_GNU_SOURCE)
cpu=(-DGGML_CPU_GENERIC -U__SSE__ -U__SSE2__ -U__SSE3__ -U__SSSE3__)

compile() {  # compile SRC OBJ EXTRA...: one source through the driver; report a failure with its first error
  local src=$1 obj=$2; shift 2
  local lang=-std=c++17; [ "${src##*.}" = c ] && lang=
  if ! "$root/nfcxx" -c "${inc[@]}" "$@" $lang "$src" -o "$obj" > "$obj.log" 2>&1; then
    echo "FAIL compile $(basename "$src"): $(grep -m1 -E ' error|fatal error' "$obj.log" | sed "s|$L/||" | cut -c1-160)"
    return 1
  fi
}

objs=()
for f in "$L"/ggml/src/*.c "$L"/ggml/src/*.cpp "$L"/ggml/src/ggml-cpu/*.c "$L"/ggml/src/ggml-cpu/*.cpp "$L"/ggml/src/ggml-cpu/tiled/*.cpp; do
  n=$(basename "$f"); case $n in ggml-blas*|*cuda*) continue;; esac
  case $f in
    */ggml-cpu/*.cpp) extra=("${cpu[@]}") ;;   # C++: no SSE predefines (the x86 headers need AVX10.2 builtins)
    */ggml-cpu/*) extra=(-DGGML_CPU_GENERIC) ;;
    *) extra=() ;;
  esac
  o=$out/$(basename "$(dirname "$f")")-$n.o
  if compile "$f" "$o" "${extra[@]}"; then objs+=("$o"); else fail=1; fi
done
echo "compiled ${#objs[@]} objects"

# The link: ggml_cpu_check.c with the objects. The one known blocker is accepted; any other output is a failure.
if [ $fail = 0 ]; then
  compile ggml_cpu_check.c "$out/check.o" >/dev/null || fail=1
  if "$root/nfcxx" "${objs[@]}" "$out/check.o" -lm -lpthread -lstdc++ -o "$out/check" > "$out/link.log" 2>&1; then
    "$out/check" && echo "ggml cpu check: ok" || { echo "ggml cpu check: FAIL"; fail=1; }
  else
    if grep -v 'name decoding\|prelinker\|^ *$\|unreachable\|^ *[|^]\|line [0-9]*: warning\|assigned to file\|executing:' "$out/link.log" \
       | grep -q "error\|undefined" && \
       [ "$(grep -c 'undefined reference' "$out/link.log")" = "$(grep -c "$BLOCKER" "$out/link.log")" ]; then
      echo "XFAIL link: the blocker remains (undefined ~__shared_ptr<std::filesystem::__cxx11::_Dir>)"
    else
      echo "FAIL link: $(grep -m2 'undefined\|error' "$out/link.log" | cut -c1-200)"; fail=1
    fi
  fi
fi
exit $fail
