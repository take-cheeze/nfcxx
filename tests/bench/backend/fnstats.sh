#!/usr/bin/env bash
# usage: fnstats.sh BINARY FUNCPREFIX  -> instruction count, vector ops, stack operands inside the function
b=$1; p=$2
objdump -d -C --no-show-raw-insn "$b" | awk -v p="$p" '
  /^[0-9a-f]+ </ && index($0, "<" p) {on=1; next}
  on && /^$/ {on=0}
  on {print}' > /tmp/fn.$$.txt
n=$(wc -l < /tmp/fn.$$.txt)
vec=$(grep -c -E "[[:space:]]v?(mulps|addps|mulpd|addpd|subps|subpd|mulss|addss|movups|movaps|movdqu|movdqa|paddd|vfmadd[0-9a-z]*|vmul|vadd|vfma)" /tmp/fn.$$.txt)
stk=$(grep -c -E "\(%rsp\)|0x[0-9a-f]+\(%rsp\)|\(%rbp\)|-0x[0-9a-f]+\(%rbp\)" /tmp/fn.$$.txt)
echo "$b $p insns=$n vector_ops=$vec stack_operands=$stk"
rm -f /tmp/fn.$$.txt
