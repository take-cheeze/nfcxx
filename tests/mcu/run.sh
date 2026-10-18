#!/usr/bin/env bash
# ESP32-C3 (RV32IMC, ILP32, bare metal) checks. EDG has no bare-metal RV32 table, so the generated C comes from the
# linux_riscv32 stand-in (scripts/gen-c-target.sh, docs/notes/hexagon.md). Three checks:
#   1. layout: the sizes, alignments and offsets EDG assumes for linux_riscv32 are _Static_asserted by clang for
#      riscv32-unknown-elf (tests/hexagon/layout_probe.cpp, the same oracle the Hexagon check uses);
#   2. compile: tests/mcu/*.cpp, emitted as C by EDG and compiled by clang for the ESP32-C3 ISA and ABI;
#   3. run: `// RUN-QEMU:` probes are linked with tests/mcu/esp32c3 and run on Espressif's QEMU (QEMU_ESP32C3); the exit
#      status and the optional `// RUN-QEMU-OUT:` text are checked. Skipped without that emulator.
# Exits 0 with SKIP when clang has no riscv32 target or EDG is not built.
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

# 3. Run: `// RUN-QEMU: N` probes are linked with tests/mcu/esp32c3 (start.S, start.c, link.ld) into an ELF that
#    Espressif's QEMU runs with `-M esp32c3 -kernel`. The exit status (semihosting SYS_EXIT) must be N, and the output
#    must contain the `// RUN-QEMU-OUT:` text when given. QEMU_ESP32C3 names the emulator (default qemu-system-riscv32,
#    which must be Espressif's fork: mainline QEMU has no esp32c3 machine). Skipped without it.
qemu=${QEMU_ESP32C3:-qemu-system-riscv32}
if ! command -v "$qemu" >/dev/null 2>&1 || ! "$qemu" -M help 2>/dev/null | grep -q esp32c3; then
  echo "skip  mcu run: no QEMU with the esp32c3 machine (set QEMU_ESP32C3 to Espressif's qemu-system-riscv32)"
  exit $fail
fi
for f in "$root"/tests/mcu/*.cpp; do
  name=$(basename "$f" .cpp)
  want=$(sed -n 's,^// RUN-QEMU: *,,p' "$f" | head -1)
  [ -n "$want" ] || continue
  out=$(sed -n 's,^// RUN-QEMU-OUT: *,,p' "$f" | head -1)
  if ! ./nfcxx --freestanding --emit-c --target="$target" "$f" > "$tmp/$name.run.c" 2> "$tmp/$name.run.edg"; then
    echo "FAIL mcu run $name: EDG refused it for $target"; head -3 "$tmp/$name.run.edg"; fail=1; continue
  fi
  if ! $clang --target=$triple $arch -ffreestanding -fwrapv -fno-strict-aliasing -O2 -w -c "$tmp/$name.run.c" -o "$tmp/$name.run.o" 2> "$tmp/$name.run.cc" ||
     ! $clang --target=$triple $arch -O2 -w -c "$root/tests/mcu/esp32c3/start.S" -o "$tmp/start.o" ||
     ! $clang --target=$triple $arch -O2 -w -c "$root/tests/mcu/esp32c3/start.c" -o "$tmp/uart.o" ||
     ! $clang --target=$triple $arch -fuse-ld=lld -nostdlib -static -Wl,-T,"$root/tests/mcu/esp32c3/link.ld" \
        "$tmp/start.o" "$tmp/$name.run.o" "$tmp/uart.o" -o "$tmp/$name.elf" 2> "$tmp/$name.ld"; then
    echo "FAIL mcu run $name: build failed"; head -3 "$tmp/$name.run.cc" "$tmp/$name.ld" 2>/dev/null; fail=1; continue
  fi
  timeout 60 "$qemu" -M esp32c3 -nographic -semihosting -kernel "$tmp/$name.elf" > "$tmp/$name.out" 2>&1 < /dev/null
  got=$?
  if [ "$got" -ne "$want" ]; then
    echo "FAIL mcu run $name: exit $got, want $want"; tail -3 "$tmp/$name.out"; fail=1; continue
  fi
  if [ -n "$out" ] && ! grep -qF "$out" "$tmp/$name.out"; then
    echo "FAIL mcu run $name: output lacks '$out'"; tail -3 "$tmp/$name.out"; fail=1; continue
  fi
  echo "ok   mcu run $name: esp32c3 exit $got${out:+, output '$out'}"
done
exit $fail
