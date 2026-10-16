#!/usr/bin/env bash
# Writes the arithmetic cases for diff-arith.sh to stdout: every form of the arithmetic, comparison and conversion group
# over the scalar types, with register and constant operands and the edge constants. Each case is
# (arith DEST_TYPE ((%N PTX_REG TYPE) ...) INSTR), read by --eval-arith and by lower-arith-driver.rb.
set -eu

ints="char signed_char unsigned_char short unsigned_short int unsigned_int long unsigned_long bool"
flts="float double"
ibin="wadd wsub wmul cdiv crem and or xor"
fbin="fadd fsub fmul fdiv"
cmps="lt le gt ge eq ne lt.s le.s gt.s ge.s eq.s ne.s lt.u le.u gt.u ge.u eq.u ne.u lt.f le.f gt.f ge.f eq.f ne.f"
# 2^63-1 is left out: the reference's imm wraps it under mruby (an int-to-float compare near 2^63), a defect of the
# reference, not of this port.
iconsts="0 1 -1 3 40 127 255 32767 65535 2147483647 -2147483648 4294967295 4611686018427387904"
fconsts="0.0 -0.0 1.5 -2.0 0.1 2.5e-5 1e16 1e300 123456789.0"

# The operand pairs of a binary form over type $1: a register or a constant on each side.
pairs() {
  local t=$1 c
  printf '%%1 %%2\n'
  for c in 0 -1 3 40; do printf '%%1 (const %s %s)\n' "$t" "$c"; printf '(const %s %s) %%2\n' "$t" "$c"; done
}

for t in $ints; do
  # Binary forms on one type: both operands of that type.
  for op in $ibin; do
    while read -r a b; do
      printf '(arith %s ((%%1 %%r1 %s) (%%2 %%r2 %s)) (%s %s %s %s))\n' "$t" "$t" "$t" "$op" "$t" "$a" "$b"
    done < <(pairs "$t" | sed 's/^\(%1\) \(%2\)$/\1 \2/')
  done
  # Shifts: the count is a register of type int or unsigned long, or a constant.
  for op in cshl cshr; do
    for ct in int unsigned_long; do
      printf '(arith %s ((%%1 %%r1 %s) (%%2 %%r2 %s)) (%s %s %%1 %%2))\n' "$t" "$t" "$ct" "$op" "$t"
      printf '(arith %s ((%%1 %%r1 %s)) (%s %s %%1 (const %s 40)))\n' "$t" "$t" "$op" "$t" "$ct"
    done
    printf '(arith %s ((%%1 %%r1 %s)) (%s %s %%1 (const int 3)))\n' "$t" "$t" "$op" "$t"
  done
  # Unary forms: negation, complement and the comparisons against each operand pair.
  printf '(arith %s ((%%1 %%r1 %s)) (wneg %s %%1))\n' "$t" "$t" "$t"
  printf '(arith %s ((%%1 %%r1 %s)) (not %s %%1))\n' "$t" "$t" "$t"
  for op in $cmps; do
    while read -r a b; do
      printf '(arith bool ((%%1 %%r1 %s) (%%2 %%r2 %s)) (%s %s %s %s))\n' "$t" "$t" "$op" "$t" "$a" "$b"
    done < <(pairs "$t")
  done
  for c in $iconsts; do
    printf '(arith %s ((%%1 %%r1 %s)) (wadd %s %%1 (const %s %s)))\n' "$t" "$t" "$t" "$t" "$c"
  done
  # Integer to integer conversions from each integer type (a bool source selects 0 or 1).
  for s in $ints; do
    printf '(arith %s ((%%1 %%r1 %s)) (iconv %s %%1))\n' "$t" "$s" "$t"
  done
  # Float to integer conversions.
  for f in $flts; do
    printf '(arith %s ((%%1 %%r1 %s)) (cf2i %s %%1))\n' "$t" "$f" "$t"
  done
done

for t in $flts; do
  for op in $fbin; do
    printf '(arith %s ((%%1 %%r1 %s) (%%2 %%r2 %s)) (%s %s %%1 %%2))\n' "$t" "$t" "$t" "$op" "$t"
    printf '(arith %s ((%%1 %%r1 %s)) (%s %s %%1 (const %s 1.5)))\n' "$t" "$t" "$op" "$t" "$t"
  done
  printf '(arith %s ((%%1 %%r1 %s)) (fneg %s %%1))\n' "$t" "$t" "$t"
  for op in $cmps; do
    printf '(arith bool ((%%1 %%r1 %s) (%%2 %%r2 %s)) (%s %s %%1 %%2))\n' "$t" "$t" "$op" "$t"
  done
  for c in $fconsts; do
    printf '(arith %s ((%%1 %%r1 %s)) (fadd %s %%1 (const %s %s)))\n' "$t" "$t" "$t" "$t" "$c"
  done
  # Float conversions between the two float widths, and from each integer type.
  for s in $flts; do
    printf '(arith %s ((%%1 %%r1 %s)) (fconv %s %%1))\n' "$t" "$s" "$t"
  done
  for s in $ints; do
    printf '(arith %s ((%%1 %%r1 %s)) (i2f %s %%1))\n' "$t" "$s" "$t"
    printf '(arith %s ((%%1 %%r1 %s)) (u2f %s %%1))\n' "$t" "$s" "$t"
  done
done

# Refused and malformed forms: a float bitwise op, a bool negation, a bool comparison of ordering, an operand of an
# unset register, and a comparison whose result is not a predicate.
printf '(arith float ((%%1 %%r1 float) (%%2 %%r2 float)) (and float %%1 %%2))\n'
printf '(arith bool ((%%1 %%r1 bool)) (wneg bool %%1))\n'
printf '(arith bool ((%%1 %%r1 bool) (%%2 %%r2 bool)) (lt bool %%1 %%2))\n'
printf '(arith int ((%%1 %%r1 int)) (wadd int %%9 %%1))\n'
printf '(arith int ((%%1 %%r1 int)) (lt int %%1 %%1))\n'
printf '(arith int ((%%1 %%r1 int)) (fadd int %%1 %%1))\n'
printf '(arith int ((%%1 %%r1 int)) (iconv int (const int 7)))\n'
printf '(arith int ((%%1 %%r1 float)) (cf2i int %%1))\n'
printf '(arith bool ((%%1 %%r1 bool)) (eq int %%1 %%1))\n'
