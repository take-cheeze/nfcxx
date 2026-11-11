#!/usr/bin/env bash
# Builds call-value.ptx: one kernel k<ID> per row of call-cases.tsv, from the text the lowering emits (--eval-arith) for
# that row: the device-intrinsic, warp, atomic and ptx-asm forms of lower_call.cpp. Each kernel loads the operands (A and B
# from the two input slots, the scratch slot of the row's pointer) and stores the result of a mode r row. One thread per
# element; every slot is 8 bytes. Usage: call-gen.sh [OUTDIR] (default: this directory). call-value.sh runs the check.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
dir=${1:-$here}
cxx=${PTX_EMIT:-$(cd "$here/../../.." && pwd)/build/pathb-ptx-emit}
# The presets: %1 = B as s32, %2 = A as s32, %3 = A as f32, %4 = the scratch slot's address, %5 = B as f32.
P='((%1 %xb int) (%2 %xa int) (%3 %fa float) (%4 %pa (ptr)) (%5 %fb float))'
rows=$(grep -v '^#' "$here/call-cases.tsv")
: > "$dir/call.case"
while IFS=$'\t' read -r id kind dest mode instr; do
  if [ "$kind" = asm ]; then
    printf '(asm %s %s)\n' "$P" "$instr" >> "$dir/call.case"
  else
    printf '(call %s %s %s)\n' "$dest" "$P" "$instr" >> "$dir/call.case"
  fi
done <<< "$rows"
"$cxx" --eval-arith "$dir/call.case" > "$dir/call.out"
n_rows=$(printf '%s\n' "$rows" | wc -l)
[ "$(wc -l < "$dir/call.out")" -eq "$n_rows" ] || { echo "call-gen: case count"; exit 1; }
: > "$dir/call-value.ptx"
{ echo ".version 7.5"; echo ".target sm_75"; echo ".address_size 64"; } >> "$dir/call-value.ptx"
n=0
while IFS=$'\t' read -r id kind dest mode instr; do
  n=$((n+1))
  low=$(sed -n "${n}p" "$dir/call.out")
  case $low in NOTCALL|NOTARITH|REFUSED|BADIR|BADCASE) echo "row $id: $low"; exit 1;; esac
  case $dest in int) dpt=s32; ldt=s32;; float) dpt=f32; ldt=f32;; *) dpt=;; esac
  body=$(printf '%s\n' "$low" | sed 's/ ~ /\n/g' | sed 's/%d\([,; ]\)/%Dd\1/g')
  {
    echo ".visible .entry k$id(.param .u64 pa, .param .u64 pb, .param .u64 po, .param .u64 ps, .param .u32 pn)"
    echo "{"
    echo "  .reg .u32 %t<16>; .reg .u64 %w<16>; .reg .pred %q<4>;"
    echo "  .reg .pred %p<64>; .reg .b32 %r<64>; .reg .b64 %rd<64>; .reg .f32 %f<64>; .reg .f64 %fd<64>;"
    echo "  .reg .s32 %xa, %xb; .reg .f32 %fa, %fb; .reg .u64 %pa;"
    [ -n "$dpt" ] && echo "  .reg .$dpt %Dd;"
    echo "  ld.param.u64 %w0, [pa]; ld.param.u64 %w1, [pb]; ld.param.u64 %w2, [po]; ld.param.u64 %w7, [ps]; ld.param.u32 %t0, [pn];"
    echo "  mov.u32 %t1, %ctaid.x; mov.u32 %t2, %ntid.x; mov.u32 %t3, %tid.x; mad.lo.u32 %t1, %t1, %t2, %t3;"
    echo "  setp.ge.u32 %q0, %t1, %t0; @%q0 bra DONE;"
    echo "  mul.wide.u32 %w3, %t1, 8; add.u64 %w4, %w0, %w3; add.u64 %w5, %w1, %w3; add.u64 %w6, %w2, %w3; add.u64 %pa, %w7, %w3;"
    echo "  ld.global.s32 %xb, [%w5]; ld.global.s32 %xa, [%w4]; ld.global.f32 %fa, [%w4]; ld.global.f32 %fb, [%w5];"
    printf '%s\n' "$body" | sed 's/^/  /'
    if [ "$mode" = r ]; then
      echo "  st.global.$ldt [%w6], %Dd;"
    fi
    echo "DONE:"
    echo "  ret;"
    echo "}"
  } >> "$dir/call-value.ptx"
done <<< "$rows"
echo "call-gen: $n kernels"
