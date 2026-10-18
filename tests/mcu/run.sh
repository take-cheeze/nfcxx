#!/usr/bin/env bash
# ESP32-C3 (RV32IMC, ILP32, bare metal) compile-only checks. EDG has no bare-metal RV32 table, so the generated C
# comes from the linux_riscv32 stand-in (scripts/gen-c-target.sh, docs/notes/hexagon.md). Two checks:
#   1. layout: the sizes, alignments and offsets EDG assumes for linux_riscv32 are _Static_asserted by clang for
#      riscv32-unknown-elf (tests/hexagon/layout_probe.cpp, the same oracle the Hexagon check uses);
#   2. compile: tests/mcu/*.cpp, emitted as C by EDG and compiled by clang for the ESP32-C3 ISA and ABI.
# Exits 0 with SKIP when clang has no riscv32 target or EDG is not built. No emulator yet.
cd "$(dirname "$0")/../.."
root=$PWD
clang=${CLANG:-clang}
triple=riscv32-unknown-elf
arch="-march=rv32imc -mabi=ilp32"
target=${EDG_TARGET:-linux_riscv32}

echo 'int f(void){return 0;}' | $clang --target=$triple $arch -ffreestanding -c -x c - -o /dev/null 2>/dev/null \
  || { echo "SKIP mcu: $clang has no $triple target"; exit 0; }
[ -x "$root/build/edg/bin/cpfe" ] || { echo "SKIP mcu: EDG not built (scripts/setup-edg.sh)"; exit 0; }

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fail=0

# 1. Layout: EDG's numbers become _Static_asserts on the struct as clang lays it out.
"$root/scripts/gen-c-target.sh" -t "$target" -o "$tmp/layout.c" "$root/tests/hexagon/layout_probe.cpp" || exit 1
grep -o 'const unsigned long nfcxx_[A-Za-z0-9_]* = [0-9]*' "$tmp/layout.c" | sed 's/const unsigned long nfcxx_//; s/ = /=/' |
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
done >> "$tmp/layout.c"
if $clang --target=$triple $arch -ffreestanding -fsyntax-only -w "$tmp/layout.c" 2> "$tmp/layout.err"; then
  echo "ok   mcu layout ($(grep -c _Static_assert "$tmp/layout.c") EDG layout facts agree with clang $triple)"
else
  echo "FAIL mcu layout:"; grep error "$tmp/layout.err" | sed 's|.*/||' | head -5; fail=1
fi

# 2. Compile: each probe is emitted as C by EDG and compiled for the ESP32-C3 ISA and ABI.
for f in "$root"/tests/mcu/*.cpp; do
  name=$(basename "$f" .cpp)
  if ! ./nfcxx --freestanding --emit-c --target="$target" "$f" > "$tmp/$name.c" 2> "$tmp/$name.edg"; then
    echo "FAIL mcu $name: EDG refused it for $target"; head -3 "$tmp/$name.edg"; fail=1; continue
  fi
  if $clang --target=$triple $arch -ffreestanding -fwrapv -fno-strict-aliasing -O2 -w \
        -c "$tmp/$name.c" -o "$tmp/$name.o" 2> "$tmp/$name.cc"; then
    echo "ok   mcu compile $name ($triple $arch)"
  else
    echo "FAIL mcu compile $name:"; head -3 "$tmp/$name.cc"; fail=1
  fi
done
exit $fail
