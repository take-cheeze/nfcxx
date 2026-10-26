#!/usr/bin/env bash
# CPU-only GPU check: tools/pathb-ptx-emit lowers tests/gpu/mul2.ir to PTX, and the ptx-interp
# interpreter runs it with the launch tests/gpu/launch.c uses (8 blocks of 128 threads, N=1000,
# 64 guard ints past b, a[i] = i - 299). No GPU and no CUDA are needed.
# The mutants must be caught, which shows the check notices a wrong multiplier and a missing bounds check.
set -euo pipefail
cd "$(dirname "$0")"
root=$(cd ../.. && pwd)
[ -x "$root/build/pathb-ptx-emit" ] || ninja -C "$root/tools/pathb-ptx-emit" >/dev/null || exit 1
# The PTX emitter: the C++ tool (tools/pathb-ptx-emit).
emit_ptx() {
  [ -x "$root/build/pathb-ptx-emit" ] || ninja -C "$root/tools/pathb-ptx-emit" >/dev/null || return 1
  "$root/build/pathb-ptx-emit" --emit "$@"
}
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT

gcc -std=c11 -O2 -Wall -Wextra -Werror -pedantic -o "$out/ptxi" ptx-interp/ptxi.c
emit_ptx mul2.ir > "$out/mul2.ptx"

launch=(mul2 --grid 8 --block 128 ptr:1064:iota=-299 ptr:1064 s32:1000 --dump 1)

# check FILE: one value per line (buffer b). b[i] == 2*a[i] for i < 1000; the guard ints are zero.
check() {
  awk 'BEGIN { bad = 0; guard = 0 }
       { i = NR - 1
         if (i < 1000) { if ($1 + 0 != 2 * (i - 299)) bad++ }
         else if ($1 + 0 != 0) guard++ }
       END { if (NR != 1064) { printf "  wrong line count %d\n", NR; exit 1 }
             printf "  %d elements, %d mismatches, %d guard writes\n", 1000, bad, guard
             exit (bad != 0 || guard != 0) }' "$1"
}

"$out/ptxi" "$out/mul2.ptx" "${launch[@]}" > "$out/out.txt"
check "$out/out.txt"
echo "mul2 on the PTX interpreter: ok"

# Mutant 1: a wrong multiplier. Mutant 2: the bounds check against 2000, so threads 1000..1023 write
# into the guard ints. Each must fail the interpreter or the check.
sed 's/mul.lo.s32 \(%r[0-9]*\), \(%r[0-9]*\), 2;/mul.lo.s32 \1, \2, 3;/' "$out/mul2.ptx" > "$out/mul3.ptx"
sed 's/setp.lt.s32 %p0, %r5, %r6;/setp.lt.s32 %p0, %r5, 2000;/' "$out/mul2.ptx" > "$out/nobounds.ptx"
for m in mul3 nobounds; do
  status=0
  "$out/ptxi" "$out/$m.ptx" "${launch[@]}" > "$out/$m.out" || status=$?
  if [ "$status" -eq 0 ] && check "$out/$m.out"; then
    echo "mutant $m was not caught" >&2
    exit 1
  fi
  echo "mutant $m caught (interpreter exit $status)"
done

# An instruction the interpreter does not model is refused before it runs (exit 3).
sed 's/ld.s32 %r6, \[%rd6\];/ld.s32 %r6, [%rd6];\n  bar.sync 0;/' "$out/mul2.ptx" > "$out/barrier.ptx"
status=0
"$out/ptxi" "$out/barrier.ptx" "${launch[@]}" > /dev/null 2>&1 || status=$?
[ "$status" -eq 3 ] || { echo "barrier: expected exit 3, got $status" >&2; exit 1; }
echo "unsupported instruction refused (exit 3)"

# A launch that runs past b (2000 elements against a 1064-element buffer) must fault (exit 4).
status=0
"$out/ptxi" "$out/mul2.ptx" mul2 --grid 9 --block 128 ptr:1064:iota=-299 ptr:1064 s32:2000 > /dev/null 2>&1 || status=$?
[ "$status" -eq 4 ] || { echo "out-of-bounds launch: expected exit 4, got $status" >&2; exit 1; }
echo "out-of-bounds access faults (exit 4)"

# Device helpers (tests/gpu/device/helper.ir): helper_kernel calls square_plus_one, which calls square, so the PTX has
# .func bodies and call instructions. The same launch as tests/gpu/device/launch_helper.c: out[i] = in[i]^2 + 1 for
# i < 1000 (in[i] = i - 300), and the guard ints stay zero. A mutant (+1 becomes +2) must be caught.
emit_ptx "$root/tests/gpu/device/helper.ir" > "$out/helper.ptx"
hlaunch=(helper_kernel --grid 8 --block 128 ptr:1064:iota=-300 ptr:1064 s32:1000 --dump 1)
check_helper() {
  awk 'BEGIN { bad = 0; guard = 0 }
       { i = NR - 1
         if (i < 1000) { if ($1 + 0 != (i - 300) * (i - 300) + 1) bad++ }
         else if ($1 + 0 != 0) guard++ }
       END { if (NR != 1064) { printf "  wrong line count %d\n", NR; exit 1 }
             printf "  %d elements, %d mismatches, %d guard writes\n", 1000, bad, guard
             exit (bad != 0 || guard != 0) }' "$1"
}
"$out/ptxi" "$out/helper.ptx" "${hlaunch[@]}" > "$out/helper.out"
check_helper "$out/helper.out"
echo "helper_kernel (calls .func square_plus_one, which calls square) on the PTX interpreter: ok"

sed 's/add\.s32 %r3, %r2, 1;/add.s32 %r3, %r2, 2;/' "$out/helper.ptx" > "$out/helper_mut.ptx"
status=0
"$out/ptxi" "$out/helper_mut.ptx" "${hlaunch[@]}" > "$out/helper_mut.out" || status=$?
if [ "$status" -eq 0 ] && check_helper "$out/helper_mut.out"; then
  echo "helper mutant was not caught" >&2
  exit 1
fi
echo "helper mutant caught (interpreter exit $status)"

# A call of a function the module does not define is refused (exit 3).
sed 's/call (%r13), square_plus_one, /call (%r13), no_such_function, /' "$out/helper.ptx" > "$out/helper_nocallee.ptx"
status=0
"$out/ptxi" "$out/helper_nocallee.ptx" "${hlaunch[@]}" > /dev/null 2>&1 || status=$?
[ "$status" -eq 3 ] || { echo "undefined callee: expected exit 3, got $status" >&2; exit 1; }
echo "call of an undefined function refused (exit 3)"

# Structs and unions by value (device/struct_int.ir, integer members only): a struct parameter is a byte array of the
# caller's copy, a struct result is the func_retval0 array, a struct argument is copied into the callee's array, and
# a union is passed like a struct, as nvcc passes them. The host's bytes are the arguments p = {3, 5}, u = 7 and
# m = {10, -2, 3, 4}; out[i] = (3 + i + 5) + 7 + (bump(m with a += i)'s sum) = 35 + 2i, guards zero. A mutant (the
# struct result read at the wrong offset) must be caught.
emit_ptx "$root/tests/gpu/device/struct_int.ir" > "$out/struct_int.ptx"
slaunch=(struct_kernel --grid 8 --block 128 ptr:1064 s32:1000 bytes:0300000005000000 bytes:07000000
         bytes:0a000000feff030004000000 --dump 0)
check_struct() {
  awk 'BEGIN { bad = 0; guard = 0 }
       { i = NR - 1
         if (i < 1000) { if ($1 + 0 != 35 + 2 * i) bad++ }
         else if ($1 + 0 != 0) guard++ }
       END { if (NR != 1064) { printf "  wrong line count %d\n", NR; exit 1 }
             printf "  %d elements, %d mismatches, %d guard writes\n", 1000, bad, guard
             exit (bad != 0 || guard != 0) }' "$1"
}
"$out/ptxi" "$out/struct_int.ptx" "${slaunch[@]}" > "$out/struct_int.out"
check_struct "$out/struct_int.out"
echo "struct parameters on the PTX interpreter: ok"
sed '/^\.func (\.param \.align 4 \.b8 func_retval0\[8\]) mk_p8/,/^}/ s/func_retval0+4\]/func_retval0+0]/' \
  "$out/struct_int.ptx" > "$out/struct_int_mut.ptx"
status=0
"$out/ptxi" "$out/struct_int_mut.ptx" "${slaunch[@]}" > "$out/struct_int_mut.out" || status=$?
if [ "$status" -eq 0 ] && check_struct "$out/struct_int_mut.out"; then
  echo "struct mutant was not caught" >&2
  exit 1
fi
echo "struct mutant caught (interpreter exit $status)"
