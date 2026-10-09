#!/usr/bin/env bash
# Checks that the struct layout EDG assumes for the Hexagon stand-in target (linux_riscv32) agrees
# with clang's Hexagon ABI. EDG's numbers are emitted as constants; each becomes a _Static_assert
# on the struct as clang lays it out. Skips cleanly if clang has no Hexagon backend.
cd "$(dirname "$0")/../.."
root=$PWD; here=$root/tests/hexagon
clang=${CLANG:-clang}; target=${EDG_TARGET:-linux_riscv32}
triple=hexagon-unknown-linux-musl
echo 'int f(void){return 0;}' | $clang --target=$triple -ffreestanding -c -x c - -o /dev/null 2>/dev/null \
  || { echo "SKIP layout: $clang has no hexagon target"; exit 0; }
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
"$root/scripts/gen-c-target.sh" -t "$target" -o "$tmp/probe.c" "$here/layout_probe.cpp" || exit 1
# nfcxx_<name> = <value>  ->  _Static_assert((<C expression for name>) == <value>)
grep -o 'const unsigned long nfcxx_[A-Za-z0-9_]* = [0-9]*' "$tmp/probe.c" | sed 's/const unsigned long nfcxx_//; s/ = /=/' |
while IFS== read name val; do
  val=${val%UL}
  case $name in
    sz_ptr) e='sizeof(void *)';;  sz_long) e='sizeof(long)';;  sz_ll) e='sizeof(long long)';;
    sz_wchar) e='sizeof(int)';;  sz_size_t) e='sizeof(unsigned long)';;
    al_ll) e='_Alignof(long long)';;  al_dbl) e='_Alignof(double)';;
    sz_*) e="sizeof(struct ${name#sz_})";;  al_*) e="_Alignof(struct ${name#al_})";;
    off_*) s=${name#off_}; e="__builtin_offsetof(struct ${s%_*}, ${s##*_})";;
  esac
  echo "_Static_assert(($e)==$val, \"$name\");"
done >> "$tmp/probe.c"
if $clang --target=$triple -ffreestanding -fsyntax-only -w "$tmp/probe.c" 2>"$tmp/err"; then
  echo "ok   layout ($(grep -c _Static_assert "$tmp/probe.c") EDG layout facts agree with clang $triple)"
else
  echo "FAIL layout:"; grep 'error' "$tmp/err" | sed 's|.*/||' | head; exit 1
fi
