#!/usr/bin/env bash
# Instances of a launching function template declared extern in a header (llama.cpp's mmq.cuh and fattn-mma-f16.cuh):
# each is defined by one unit, so its kernels are in that unit's device image only, and the unit that calls them has
# no device image. The program runs both instances from main.cu. The mutant (one instance file left out) must fail to
# link. Needs CUDA_HOME and an NVIDIA GPU; skips (exit 0) when missing.
set -euo pipefail
cd "$(dirname "$0")"
root=$(cd ../../.. && pwd)
cuda=${CUDA_HOME:-/usr/local/cuda}
if [ ! -f "$cuda/include/cuda_runtime.h" ] || [ ! -e "$cuda/lib64/libcudart.so" ] || ! command -v nvidia-smi >/dev/null; then
  echo "SKIP: extern_inst: needs cuda_runtime.h, libcudart and nvidia-smi (CUDA_HOME)"; exit 0
fi
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
export TMPDIR=$out
export NFCXX_BACKEND=gcc  # the CUDA runtime headers do not compile on the qbe backend
fail=0

for u in main inst_2 inst_3; do
  if ! "$root/nfcxx" -c -I"$cuda/include" "$u.cu" -o "$out/$u.o" >> "$out/build.log" 2>&1; then
    echo "extern_inst: FAIL (compile $u.cu)"; grep -v "pragma\|NV_SILENCE\|^ *\^\|^ *$\|warning" "$out/build.log" | head -5; exit 1
  fi
done
# The calling unit has no kernels of its own: no registration tail in its object.
if nm "$out/main.o" | grep -q '__nfcxx_k_scale'; then
  echo "extern_inst: FAIL (main.o has the extern instances' kernels)"; fail=1
fi
if "$root/nfcxx" "$out/main.o" "$out/inst_2.o" "$out/inst_3.o" -L"$cuda/lib64" -lcudart -o "$out/prog" >> "$out/build.log" 2>&1 \
   && run=$(LD_LIBRARY_PATH="$cuda/lib64:/usr/lib/x86_64-linux-gnu" "$out/prog") && [[ "$run" == *"extern_inst: no error, 0 mismatches"* ]]; then
  echo "extern_inst (instances in their own units): ok"
else
  echo "extern_inst: FAIL"; echo "${run:-}"; grep -v "pragma\|NV_SILENCE\|^ *\^\|^ *$\|warning" "$out/build.log" | head -5; fail=1
fi
# Mutant: inst_3.o left out. scale_case<3> is defined nowhere, so the link must fail.
if "$root/nfcxx" "$out/main.o" "$out/inst_2.o" -L"$cuda/lib64" -lcudart -o "$out/mut" > "$out/mut.log" 2>&1; then
  echo "mutant extern_inst: FAIL (linked without inst_3.o)"; fail=1
else
  echo "mutant extern_inst: caught"
fi
exit $fail
