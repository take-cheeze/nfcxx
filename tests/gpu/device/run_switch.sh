#!/usr/bin/env bash
# A switch in a device kernel (switch.cpp): Path B IR (golden), the emitter, ptxas, and a launch that checks every
# element against the C switch. A mutant (case 3's value changed) must fail; a switch on a 1-byte integer is refused.
# Needs the Path B harness, ptxas, cuda_runtime.h, libcudart and an NVIDIA GPU; skips (exit 0) when one is missing.
set -euo pipefail
cd "$(dirname "$0")"
root=$(cd ../../.. && pwd)
cuda=${CUDA_HOME:-/usr/local/cuda}
if [ ! -x "$root/build/pathb/cmake/bin/cpfe" ] || [ ! -x "$cuda/bin/ptxas" ] || [ ! -f "$cuda/include/cuda_runtime.h" ] \
   || [ ! -e "$cuda/lib64/libcudart.so" ] || ! command -v nvidia-smi >/dev/null; then
  echo "SKIP: gpu switch: needs the Path B harness, ptxas, cuda_runtime.h, libcudart and nvidia-smi"; exit 0
fi
fail=0
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT

"$root/scripts/pathb-dump" --ir --freestanding switch.cpp > "$out/switch.ir"
if diff -u switch.ir "$out/switch.ir"; then echo "IR switch: ok"; else echo "IR switch: FAIL (golden differs)"; fail=1; fi

"$root/scripts/mrb" "$root/scripts/pathb-ptx-emit.rb" "$out/switch.ir" > "$out/switch.ptx"
"$cuda/bin/ptxas" -arch=sm_75 "$out/switch.ptx" -o "$out/switch.cubin"
gcc -O2 -Wall -I"$cuda/include" -L"$cuda/lib64" launch_switch.c -o "$out/launch" -lcudart
if LD_LIBRARY_PATH="$cuda/lib64:/usr/lib/x86_64-linux-gnu" "$out/launch" "$out/switch.cubin" _Z8classifyPKiPii; then
  echo "run switch: ok"
else
  echo "run switch: FAIL"; fail=1
fi

# A mutant: case 3 gives 8 instead of 7 (the setp against 3 is the only compare with immediate 3 in the dispatch).
sed 's/setp\.eq\.b32 \(%p[0-9]*\), \(%r[0-9]*\), 3;/setp.eq.b32 \1, \2, 9;/' "$out/switch.ptx" > "$out/mut.ptx"
"$cuda/bin/ptxas" -arch=sm_75 "$out/mut.ptx" -o "$out/mut.cubin"
if LD_LIBRARY_PATH="$cuda/lib64:/usr/lib/x86_64-linux-gnu" "$out/launch" "$out/mut.cubin" _Z8classifyPKiPii >/dev/null 2>&1; then
  echo "mutant switch: FAIL (not caught)"; fail=1
else
  echo "mutant switch: caught"
fi

# A switch on a 1-byte integer is refused with exit 3.
cat > "$out/refuse.cpp" <<'CPP'
void k(const char *in, int *out) { switch (in[0]) { case 1: out[0] = 1; break; default: out[0] = 2; } }
CPP
rc=0; "$root/scripts/pathb-dump" --ir --freestanding "$out/refuse.cpp" > "$out/refuse.ir" 2>/dev/null \
  && "$root/scripts/mrb" "$root/scripts/pathb-ptx-emit.rb" "$out/refuse.ir" > /dev/null 2>&1 || rc=$?
if [ "$rc" = 3 ]; then echo "refused switch on a char: ok"; else echo "refused switch on a char: FAIL (exit $rc)"; fail=1; fi
exit $fail
