#!/usr/bin/env bash
# Structs and unions passed and returned by value (struct_abi.cpp) follow nvcc's PTX calling convention. Checks: the IR
# golden; the emitted PTX's ABI-visible signatures (the .func/.entry headers and their parameter lists, with the struct
# parameters, the struct results and the scalar sizes) equal nvcc's PTX of struct_abi_ref.cu; ptxas assembles both; the
# kernel runs on the GPU with the structs passed from the host, with every element and the guard checked, for nfcxx's
# cubin and nvcc's cubin, and the two checksums are equal; a mutant (a wrong offset of the struct result, and one of a
# struct parameter) is caught. Needs the Path B harness, ptxas, nvcc, cuda_runtime.h, libcudart and an NVIDIA GPU; skips
# (exit 0) when one is missing (CUDA_HOME, default /usr/local/cuda).
set -euo pipefail
cd "$(dirname "$0")"
root=$(cd ../../.. && pwd)
[ -x "$root/build/pathb-ptx-emit" ] || make -s -C "$root/tools/pathb-ptx-emit" || exit 1
cuda=${CUDA_HOME:-/usr/local/cuda}
if [ ! -x "$root/build/pathb/cmake/bin/cpfe" ] || [ ! -x "$cuda/bin/ptxas" ] || [ ! -x "$cuda/bin/nvcc" ] \
   || [ ! -f "$cuda/include/cuda_runtime.h" ] || [ ! -e "$cuda/lib64/libcudart.so" ] || ! command -v nvidia-smi >/dev/null; then
  echo "SKIP: gpu struct abi: needs the Path B harness, ptxas, nvcc, cuda_runtime.h, libcudart and nvidia-smi"; exit 0
fi

fail=0
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
run_env() { LD_LIBRARY_PATH="$cuda/lib64:/usr/lib/x86_64-linux-gnu" "$@"; }
kernel=struct_kernel

# 1. The IR matches its golden.
"$root/scripts/pathb-dump" --ir --freestanding struct_abi.cpp > "$out/struct_abi.ir"
if diff -u struct_abi.ir "$out/struct_abi.ir"; then echo "IR struct_abi: ok"; else echo "IR struct_abi: FAIL"; fail=1; fi

# 2. The emitted PTX and nvcc's PTX of the same structs and functions: the same ABI-visible signatures.
"$root/build/pathb-ptx-emit" --emit "$out/struct_abi.ir" > "$out/struct_abi.ptx"
"$cuda/bin/nvcc" -ptx -arch=sm_75 struct_abi_ref.cu -o "$out/ref.ptx"
awk -f abi_sig.awk "$out/struct_abi.ptx" > "$out/ours.sig"
awk -f abi_sig.awk "$out/ref.ptx" > "$out/nvcc.sig"
if diff -u "$out/nvcc.sig" "$out/ours.sig"; then echo "signatures vs nvcc: ok"; else echo "signatures vs nvcc: FAIL"; fail=1; fi

# 3. ptxas assembles both; the kernel runs with the structs passed from the host, nfcxx's cubin and nvcc's cubin.
"$cuda/bin/ptxas" -arch=sm_75 "$out/struct_abi.ptx" -o "$out/struct_abi.cubin"
"$cuda/bin/nvcc" -cubin -arch=sm_75 struct_abi_ref.cu -o "$out/ref.cubin"
gcc -O2 -Wall -I"$cuda/include" -L"$cuda/lib64" launch_struct_abi.c -o "$out/launch" -lcudart
run_env "$out/launch" "$out/struct_abi.cubin" > "$out/ours.log" 2>&1 || true
run_env "$out/launch" "$out/ref.cubin" > "$out/nvcc.log" 2>&1 || true
cat "$out/ours.log"; cat "$out/nvcc.log"
if grep -q "struct_kernel: 0 mismatches, 0 guard writes" "$out/ours.log" && grep -q "struct_kernel: 0 mismatches, 0 guard writes" "$out/nvcc.log" \
   && [ "$(sed 's/.*checksum //' "$out/ours.log")" = "$(sed 's/.*checksum //' "$out/nvcc.log")" ]; then
  echo "run struct_abi (nfcxx and nvcc cubins, same answers): ok"
else
  echo "run struct_abi: FAIL"; fail=1
fi

# 4. Mutants must fail the same run: the struct result read at the wrong offset, and a struct parameter's field at the
# wrong offset.
sed '/^\.func (\.param \.align 4 \.b8 func_retval0\[8\]) mk_p8/,/^}/ s/func_retval0+4\]/func_retval0+0]/' "$out/struct_abi.ptx" > "$out/mut1.ptx"
sed 's/sum_m12_param_0+8\]/sum_m12_param_0+4]/' "$out/struct_abi.ptx" > "$out/mut2.ptx"
for m in mut1 mut2; do
  if cmp -s "$out/struct_abi.ptx" "$out/$m.ptx"; then echo "mutant $m: FAIL (the sed did not change the PTX)"; fail=1; continue; fi
  "$cuda/bin/ptxas" -arch=sm_75 "$out/$m.ptx" -o "$out/$m.cubin"
  if run_env "$out/launch" "$out/$m.cubin" >/dev/null 2>&1; then
    echo "mutant $m: FAIL (not caught)"; fail=1
  else
    echo "mutant $m: caught"
  fi
done

exit $fail
