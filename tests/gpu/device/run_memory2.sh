#!/usr/bin/env bash
# Device memory constructs from C++ source (memory2.cpp): a bool in memory and in registers, a function-local
# __shared__ array with a barrier, a __device__ global array, and a struct field behind a pointer. The source goes through the Path B front end
# (scripts/pathb-dump --ir), the emitter, ptxas for sm_75, and the runtime (launch_memory2.c). Each kernel also has a
# source mutant that must fail. Needs the Path B harness, ptxas, cuda_runtime.h, libcudart and an NVIDIA GPU; skips
# (exit 0) when one is missing (CUDA_HOME, default /usr/local/cuda).
set -euo pipefail
cd "$(dirname "$0")"
root=$(cd ../../.. && pwd)
cuda=${CUDA_HOME:-/usr/local/cuda}
if [ ! -x "$root/build/pathb/cmake/bin/cpfe" ] || [ ! -x "$cuda/bin/ptxas" ] || [ ! -f "$cuda/include/cuda_runtime.h" ] \
   || [ ! -e "$cuda/lib64/libcudart.so" ] || ! command -v nvidia-smi >/dev/null; then
  echo "SKIP: gpu memory2: needs the Path B harness, ptxas, cuda_runtime.h, libcudart and nvidia-smi"; exit 0
fi

fail=0
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
run_env=(env LD_LIBRARY_PATH="$cuda/lib64:/usr/lib/x86_64-linux-gnu")

# build SRC NAME: lowers SRC to PTX and cubin under $out/NAME.*
build() {
  "$root/scripts/pathb-dump" --ir --freestanding "$1" > "$out/$2.ir"
  "$root/scripts/mrb" "$root/scripts/pathb-ptx-emit.rb" "$out/$2.ir" > "$out/$2.ptx"
  "$cuda/bin/ptxas" -arch=sm_75 "$out/$2.ptx" -o "$out/$2.cubin"
}

# 1. The IR matches its golden, and the PTX has the forms the test is about.
"$root/scripts/pathb-dump" --ir --freestanding memory2.cpp > "$out/memory2.ir"
if diff -u memory2.ir "$out/memory2.ir"; then echo "IR memory2: ok"; else echo "IR memory2: FAIL"; fail=1; fi
build memory2.cpp memory2
for want in ".shared .align 4 .b8 tile" ".global .align 4 .b8 g_table" "st.u8" "ld.u8" "selp.u32" "bar.sync 0" "add.s64"; do
  if grep -q -- "$want" "$out/memory2.ptx"; then :; else echo "PTX has no '$want': FAIL"; fail=1; fi
done
echo "PTX forms: ok"

# 2. The kernels run and every result is checked.
gcc -O2 -Wall -I"$cuda/include" -L"$cuda/lib64" launch_memory2.c -o "$out/launch" -lcudart
if "${run_env[@]}" "$out/launch" "$out/memory2.cubin"; then echo "run memory2: ok"; else echo "run memory2: FAIL"; fail=1; fi

# 3. Mutants: each kernel's result must change, so the run must fail.
mutant() {  # mutant NAME FROM TO: the source with one replacement, built and run
  sed "s/$2/$3/" memory2.cpp > "$out/$1.cpp"
  if cmp -s memory2.cpp "$out/$1.cpp"; then echo "mutant $1: FAIL (pattern not found)"; fail=1; return; fi
  build "$out/$1.cpp" "$1"
  if "${run_env[@]}" "$out/launch" "$out/$1.cubin" >/dev/null 2>&1; then
    echo "mutant $1: FAIL (not caught)"; fail=1
  else
    echo "mutant $1: caught"
  fi
}
mutant bool_seven '? 7 : 3' '? 6 : 3'
mutant shared_index 'tile\[63 - t\]' 'tile[t]'
mutant global_plus 'g_table\[i\] + 1' 'g_table[i] + 2'
mutant offset_fields 'p\[i\].b - p\[i\].a' 'p[i].b - p[i].b'

exit $fail
