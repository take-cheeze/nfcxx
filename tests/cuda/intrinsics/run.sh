#!/usr/bin/env bash
# CUDA's integer intrinsics that llama.cpp's ggml-cuda uses, through the nfcxx driver (device prelude in
# tools/cuda-rewrite, BUILTIN_DEFS; the emitter's SCALAR_U32 and WARP_SHUFFLES).
#   pass:    int.cu builds, links, runs on the GPU and checks every intrinsic against the CUDA definitions (0 mismatches).
#   pass:    half.cu and half_arith.cu: the 16-bit half type (conversions, __hadd, __hmul, __hfma) against CUDA host results.
#   pass:    half2.cu (the packed __half2 and its pair functions) and int8.cu (8-bit integers), against host results.
#   pass:    prelude_gaps.cu (make_half2, powf within 1e-5 relative, memcpy and memset exact).
#   pass:    block.cu (__syncthreads_or, __reduce_add_sync, __threadfence_system, __nanosleep, __isnanf, __shfl_up_sync),
#            hmax.cu (__hmax) and math.cu (the float math and __dp4a, __ldg, __saturatef, __fdividef, within tolerances).
#   pass:    shared_bf16.cu (a static __shared__ array named like a dynamic one in another kernel; nv_bfloat162 as two lanes).
#   pass:    asm_ptx_widths.cu (CUB's ld and st inline PTX with 16-, 32- and 64-bit operands, "h" and "l" constraints).
#   pass:    bf16_class.cu (nv_bfloat16 as a 2-byte class: its operators, bit for bit against CUDA; a class with a destructor local).
#   pass:    bf16_forms.cu (__float2bfloat16, __bfloat162float, __float22bfloat162_rn, __bfloat1622float2, __low2/high2bfloat16
#            against CUDA host results, bit for bit, NaN canonical as the host).
#   pass:    math_fns.cu (sinf, cosf, tanhf, expm1f within 1 ulp of a double reference up to 1e6; floorf, roundf, trunc
#            exact; INFINITY and FLT_MAX).
# Needs the CUDA toolkit (CUDA_HOME, default /usr/local/cuda) and an NVIDIA GPU; skips (exit 0) when missing.
set -euo pipefail
cd "$(dirname "$0")"
root=$(cd ../../.. && pwd)
cuda=${CUDA_HOME:-/usr/local/cuda}
if [ ! -f "$cuda/include/cuda_runtime.h" ] || [ ! -e "$cuda/lib64/libcudart.so" ] || ! command -v nvidia-smi >/dev/null; then
  echo "SKIP: intrinsics: needs cuda_runtime.h, libcudart and nvidia-smi (CUDA_HOME)"; exit 0
fi
fail=0
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
export TMPDIR=$out

pass() {  # pass FILE.cu EXPECTED-SUBSTRING
  local src=$1 want=$2 name run
  name=$(basename "$src" .cu)
  if "$root/nfcxx" -c -I"$root/lib/cuda/host" -I"$cuda/include" "$src" -o "$out/$name.o" > "$out/$name.log" 2>&1 \
     && "$root/nfcxx" "$out/$name.o" -L"$cuda/lib64" -lcudart -o "$out/$name" >> "$out/$name.log" 2>&1 \
     && run=$(LD_LIBRARY_PATH="$cuda/lib64:/usr/lib/x86_64-linux-gnu" "$out/$name") && [[ "$run" == *"$want"* ]]; then
    echo "pass $name: $run"
  else
    echo "FAIL $name"; grep -v "pragma\|NV_SILENCE\|^ *\^\|^ *$\|warning" "$out/$name.log" | head -5; fail=1
  fi
}

refuse() {  # refuse FILE.cu MESSAGE-SUBSTRING
  local src=$1 want=$2 name rc=0
  name=$(basename "$src" .cu)
  "$root/nfcxx" -c -I"$root/lib/cuda/host" -I"$cuda/include" "$src" -o "$out/$name.o" > "$out/$name.log" 2>&1 || rc=$?
  if [ "$rc" = 3 ] && grep -q "$want" "$out/$name.log"; then
    echo "refused $name: $(grep -m1 "$want" "$out/$name.log" | cut -c1-160)"
  else
    echo "FAIL refused $name (exit $rc, expected 3 with: $want)"; fail=1
  fi
}

pass int.cu "intrinsics: no error, 0 mismatches"
pass half.cu "half: no error, 0 mismatches"
pass half_arith.cu "half arith: no error, 0 mismatches"
pass half2.cu "half2: no error, 0 mismatches"
pass int8.cu "int8: no error, 0 mismatches"
pass half2_forms.cu "half2 forms: no error, 0 mismatches"
pass block.cu "block: no error, 0 mismatches"
pass hmax.cu "hmax: no error, 0 mismatches"
pass math.cu "math: no error, 57344 checks, 0 mismatches"
pass votes_trap.cu "votes: no error, 0 mismatches"
pass minmax.cu "minmax: no error, 0 mismatches"
pass half2_ops.cu "half2 ops: no error, 0 mismatches"
pass byvalue.cu "byvalue: no error, 0 mismatches"
pass half2_member.cu "half2 member: no error, 0 mismatches"
pass scalars.cu "scalars: no error, 0 mismatches"
pass shared_bf16.cu "shared bf16: no error, 0 mismatches"
pass prelude_gaps.cu "prelude gaps: no error, 0 mismatches"
pass fma_round.cu "half fma: no error, 0 mismatches"
pass float2int_round.cu "float2int_rn: no error, 0 mismatches"
pass bf16_forms.cu "bf16 forms: no error, 0 mismatches"
pass bf16_class.cu "bf16 class: no error, 0 mismatches"
pass asm_ptx_widths.cu "ptx widths: no error, 0 mismatches"
pass math_fns.cu "math_fns: no error, 9175155 checks, 0 mismatches"
pass math2.cu "math2: no error, 0 mismatches"
pass min_mixed_enum_class.cu "min mixed: no error, 0 mismatches"
pass atomics.cu "atomics: no error, 0 mismatches"
pass cf2i_small.cu "cf2i small: no error, 0 mismatches"
pass cf2i_convert.cu "cf2i convert: no error, 0 mismatches"
pass ldmatrix.cu "ldmatrix: no error, 0 mismatches"
pass log1pf.cu "log1pf: no error, max 0 ulps over 1048576 points, 0 over the bound, 0 edge mismatches"
pass static_constexpr.cu "static constexpr: no error, 0 mismatches"
pass min_mixed_enum_class.cu "min mixed: no error, 0 mismatches"
pass define_header_skip.cu "define header skip: no error, 0 mismatches"
pass host_member_drop.cu "host member drop: no error, 0 mismatches"
pass const_tables.cu "const tables: no error, 0 mismatches"
pass global_init_bytes.cu "global init bytes: no error, 0 mismatches"
# Mutant: one device table entry changed (2 for 1): the host reference is literal, so the run must report mismatches.
if "$root/nfcxx" -c -I"$cuda/include" global_init_bytes_mutant.cu -o "$out/gim.o" > "$out/gim.log" 2>&1 \
   && "$root/nfcxx" "$out/gim.o" -L"$cuda/lib64" -lcudart -o "$out/gim" >> "$out/gim.log" 2>&1 \
   && run=$(LD_LIBRARY_PATH="$cuda/lib64:/usr/lib/x86_64-linux-gnu" "$out/gim" || true) \
   && [[ "$run" == *"mismatches"* && "$run" != *" 0 mismatches"* ]]; then
  echo "mutant global_init_bytes_mutant: caught: $run"
else
  echo "FAIL global_init_bytes_mutant: the mutant was not caught"; fail=1
fi
pass isinf_assume.cu "isinf: no error, 0 mismatches"
# Mutant: the expected value of isinf for NaN is set to 1 (the device says 0): the run must report mismatches.
if "$root/nfcxx" -c -I"$cuda/include" isinf_assume_mutant.cu -o "$out/ia.o" > "$out/ia.log" 2>&1 \
   && "$root/nfcxx" "$out/ia.o" -L"$cuda/lib64" -lcudart -o "$out/ia" >> "$out/ia.log" 2>&1 \
   && run=$(LD_LIBRARY_PATH="$cuda/lib64:/usr/lib/x86_64-linux-gnu" "$out/ia" || true) \
   && [[ "$run" == *"mismatches"* && "$run" != *" 0 mismatches"* ]]; then
  echo "mutant isinf_assume_mutant: caught: $run"
else
  echo "FAIL isinf_assume_mutant: the mutant was not caught"; fail=1
fi
pass cg_tile.cu "cg tile: no error, 0 mismatches"
pass cub_block.cu "cub block: no error, 0 mismatches"
pass shared_align.cu "shared align: no error, 0 mismatches"
pass nsdmi_leaf.cu "nsdmi leaf: no error, 0 mismatches"
pass launch_arrow_args.cu "launch arrow args: no error, 0 mismatches"
pass device_const_scalar.cu "device const scalar: no error, 0 mismatches"
refuse refuse_cvta.cu "call of __nfcxx_cvta_generic_to_shared"
refuse refuse_hgt2.cu "call of __nfcxx_hgt2_mask"
refuse refuse_cub.cu "cub::DeviceScan at line"
refuse refuse_host_static.cu "host variable table read in device code"
pass static_const_scalar.cu "static const scalar: no error, 0 mismatches"
# Mutant: the device sees K = 4 while the host expects 3, so the check must see mismatches.
if "$root/nfcxx" -c -I"$root/lib/cuda/host" -I"$cuda/include" static_const_scalar_mutant.cu -o "$out/scm.o" > "$out/scm.log" 2>&1 \
   && "$root/nfcxx" "$out/scm.o" -L"$cuda/lib64" -lcudart -o "$out/scm" >> "$out/scm.log" 2>&1 \
   && run=$(LD_LIBRARY_PATH="$cuda/lib64:/usr/lib/x86_64-linux-gnu" "$out/scm" || true) \
   && [[ "$run" == *"mismatches"* && "$run" != *" 0 mismatches"* ]]; then
  echo "mutant static_const_scalar: caught: $run"
else
  echo "FAIL static_const_scalar: the mutant was not caught"; fail=1
fi
exit $fail
