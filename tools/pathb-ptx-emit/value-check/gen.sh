#!/usr/bin/env bash
# Builds value.ptx: one kernel k<ID> per row of cases.tsv, from the text the lowering emits (--eval-arith) for that row,
# wrapped with the loads of the operands and the store of the result. One thread per element; every slot is 8 bytes.
# Usage: gen.sh [OUTDIR] (default: this directory). value-check.sh runs the whole check.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
dir=${1:-$here}   # where value.ptx, all.case and all.out go
cxx=${PTX_EMIT:-$(cd "$here/../../.." && pwd)/build/pathb-ptx-emit}
ptxty() { case $1 in int) echo s32;; unsigned_int) echo u32;; long) echo s64;; unsigned_long) echo u64;;
  float) echo f32;; double) echo f64;; bool) echo pred;; *) echo "unknown $1" >&2; exit 1;; esac; }
ldty() { case $1 in int) echo s32;; unsigned_int) echo u32;; long) echo s64;; unsigned_long) echo u64;;
  float) echo f32;; double) echo f64;; esac; }
# The case file: one (arith DEST PRESETS INSTR) per row.
: > "$dir/all.case"
while IFS=$'\t' read -r id instr dest a b; do
  presets=""
  [ "$a" != "-" ] && presets="(%1 %A$a $a)"
  [ "$b" != "-" ] && presets="$presets (%2 %B$b $b)"
  printf '(arith %s (%s) %s)\n' "$dest" "$presets" "$instr" >> "$dir/all.case"
done < "$here/cases.tsv"
"$cxx" --eval-arith "$dir/all.case" > "$dir/all.out"
[ "$(wc -l < "$dir/all.out")" -eq "$(wc -l < "$here/cases.tsv")" ] || { echo "gen: case count"; exit 1; }
: > "$dir/value.ptx"
{
  echo ".version 7.5"; echo ".target sm_75"; echo ".address_size 64"
} >> "$dir/value.ptx"
n=0
while IFS=$'\t' read -r id instr dest a b; do
  n=$((n+1))
  low=$(sed -n "${n}p" "$dir/all.out")
  [ "$low" != "NOTARITH" ] && [ "$low" != "REFUSED" ] && [ "$low" != "BADIR" ] || { echo "row $id: $low"; exit 1; }
  dpt=$(ptxty "$dest")
  body=$(printf '%s\n' "$low" | sed 's/ ~ /\n/g' | sed 's/%d\([,; ]\)/%Dd\1/g')
  {
    echo ".visible .entry k$id(.param .u64 pa, .param .u64 pb, .param .u64 po, .param .u32 pn)"
    echo "{"
    echo "  .reg .u32 %t<16>; .reg .u64 %w<16>; .reg .pred %q<4>;"
    echo "  .reg .pred %p<64>; .reg .b32 %r<64>; .reg .b64 %rd<64>; .reg .f32 %f<64>; .reg .f64 %fd<64>;"
    [ "$a" != "-" ] && echo "  .reg .$(ptxty "$a") %A$a;"
    [ "$b" != "-" ] && echo "  .reg .$(ptxty "$b") %B$b;"
    echo "  .reg .$dpt %Dd;"
    echo "  ld.param.u64 %w0, [pa]; ld.param.u64 %w1, [pb]; ld.param.u64 %w2, [po]; ld.param.u32 %t0, [pn];"
    echo "  mov.u32 %t1, %ctaid.x; mov.u32 %t2, %ntid.x; mov.u32 %t3, %tid.x; mad.lo.u32 %t1, %t1, %t2, %t3;"
    echo "  setp.ge.u32 %q0, %t1, %t0; @%q0 bra DONE;"
    echo "  mul.wide.u32 %w3, %t1, 8; add.u64 %w4, %w0, %w3; add.u64 %w5, %w1, %w3; add.u64 %w6, %w2, %w3;"
    [ "$a" != "-" ] && echo "  ld.global.$(ldty "$a") %A$a, [%w4];"
    [ "$b" != "-" ] && echo "  ld.global.$(ldty "$b") %B$b, [%w5];"
    printf '%s\n' "$body" | sed 's/^/  /'
    case $dest in
      bool) echo "  selp.u32 %t4, 1, 0, %Dd; st.global.u32 [%w6], %t4;";;
      *) echo "  st.global.$(ldty "$dest") [%w6], %Dd;";;
    esac
    echo "DONE:"
    echo "  ret;"
    echo "}"
  } >> "$dir/value.ptx"
done < "$here/cases.tsv"
echo "gen: $n kernels"
