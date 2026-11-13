#!/usr/bin/env bash
# Path B's real-mode code (scripts/pathb-cc --i386 --regparm=3 --m16: .code16gcc) run in real mode under qemu-system-i386.
# Each tests/pathb-i386/realmode/cases/*.c defines `int pb_main(void)`; it is built by Path B and by `gcc -m16 -march=i386 -mregparm=3`
# (the kernel's REALMODE_CFLAGS), linked at 0x7e00 with stage2.S (pb_putc: a debug console write, the exit device) and rt16.c (memcpy and
# the libgcc functions), put behind a boot sector (boot.S) that loads it with int $0x13, and booted. Both images must write the same
# to the debug console and exit with the same status: the oracle is gcc, not a number in the file. Not run (and "skip" is printed) without
# qemu-system-i386 or the 32-bit assembler and linker.
# Usage: tests/pathb-i386/realmode.sh [CASE.c...]. REALMODE_EXTRA="-I.. -D.." gives the compiles more options (the kernel files
# of arch/x86/boot are run this way: docs/notes/linux-kernel.md).
cd "$(dirname "$0")/../.."
root=$PWD
command -v qemu-system-i386 >/dev/null || { echo "skip: no qemu-system-i386"; exit 0; }
gcc -m32 -c -x assembler /dev/null -o /dev/null 2>/dev/null || { echo "skip: gcc -m32 cannot assemble"; exit 0; }
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fail=0
rm16=(-std=gnu11 -m16 -Os -march=i386 -mregparm=3 -fno-strict-aliasing -fomit-frame-pointer -fno-pic -mno-mmx -mno-sse -ffreestanding -fno-stack-protector -mpreferred-stack-boundary=2 -fno-asynchronous-unwind-tables -fno-builtin)
# the support code is the same for both images
gcc "${rm16[@]}" -c tests/pathb-i386/realmode/rt16.c -o "$tmp/rt16.o" || { echo "FAIL rt16.c"; exit 1; }
gcc -m32 -c tests/pathb-i386/realmode/stage2.S -o "$tmp/stage2.o" || { echo "FAIL stage2.S"; exit 1; }

# image NAME OBJECT...: link the stage and put the boot sector in front of it; the image is $tmp/NAME.img
image() {
  local name=$1 size sectors
  shift
  ld -m elf_i386 -Ttext 0x7e00 --oformat binary -e _stage2 -o "$tmp/$name.stage" "$tmp/stage2.o" "$@" "$tmp/rt16.o" 2>"$tmp/err" || { echo "link: $(head -3 "$tmp/err")"; return 1; }
  size=$(wc -c < "$tmp/$name.stage"); sectors=$(( (size + 511) / 512 ))
  [ $sectors -le 60 ] || { echo "the code is $size bytes: more than 60 sectors"; return 1; }
  gcc -m32 -DNSECT=$sectors -c tests/pathb-i386/realmode/boot.S -o "$tmp/boot.o" || return 1
  ld -m elf_i386 -Ttext 0x7c00 --oformat binary -o "$tmp/boot.bin" "$tmp/boot.o" || return 1
  { cat "$tmp/boot.bin" "$tmp/$name.stage"; head -c $((sectors * 512 - size)) /dev/zero; } > "$tmp/$name.img"
}
# run NAME: boot the image; the debug console is $tmp/NAME.out, the status of qemu is in $tmp/NAME.rc
run() {
  local name=$1 rc=0
  timeout 60 qemu-system-i386 -display none -serial none -monitor none -no-reboot -m 16 -drive file="$tmp/$name.img",format=raw,if=ide \
    -debugcon file:"$tmp/$name.out" -device isa-debug-exit,iobase=0xf4,iosize=0x04 >/dev/null 2>&1 || rc=$?
  echo $rc > "$tmp/$name.rc"
}

cases=("$@"); [ ${#cases[@]} -gt 0 ] || cases=(tests/pathb-i386/realmode/cases/*.c)
for f in "${cases[@]}"; do
  n=$(basename "$f" .c)
  # shellcheck disable=SC2086
  if ! gcc "${rm16[@]}" ${REALMODE_EXTRA:-} -c "$f" -o "$tmp/gcc.o" 2>"$tmp/err"; then echo "FAIL $n: gcc: $(head -3 "$tmp/err")"; fail=1; continue; fi
  # shellcheck disable=SC2086
  if ! scripts/pathb-cc --i386 --regparm=3 --m16 ${REALMODE_EXTRA:-} "$f" -o "$tmp/pb.o" 2>"$tmp/err"; then echo "FAIL $n: Path B: $(head -3 "$tmp/err")"; fail=1; continue; fi
  # REALMODE_SRCS: more C files, built the same way by both compilers (the kernel's string.c and printf.c)
  gobj=("$tmp/gcc.o") pobj=("$tmp/pb.o") x=0
  for src in ${REALMODE_SRCS:-}; do
    x=$((x + 1))
    # shellcheck disable=SC2086
    gcc "${rm16[@]}" ${REALMODE_EXTRA:-} -c "$src" -o "$tmp/gcc.x$x.o" 2>"$tmp/err" || { echo "FAIL $n: gcc $src: $(grep -m1 error "$tmp/err")"; fail=1; continue 2; }
    # shellcheck disable=SC2086
    scripts/pathb-cc --i386 --regparm=3 --m16 ${REALMODE_EXTRA:-} "$src" -o "$tmp/pb.x$x.o" 2>"$tmp/err" || { echo "FAIL $n: Path B $src: $(head -2 "$tmp/err")"; fail=1; continue 2; }
    gobj+=("$tmp/gcc.x$x.o"); pobj+=("$tmp/pb.x$x.o")
  done
  image gcc "${gobj[@]}" > "$tmp/msg" 2>&1 || { echo "FAIL $n: gcc image: $(cat "$tmp/msg")"; fail=1; continue; }
  image pb "${pobj[@]}" > "$tmp/msg" 2>&1 || { echo "FAIL $n: Path B image: $(cat "$tmp/msg")"; fail=1; continue; }
  run gcc; run pb
  if [ ! -s "$tmp/gcc.out" ]; then echo "FAIL $n: the gcc image wrote nothing (qemu status $(cat "$tmp/gcc.rc"))"; fail=1; continue; fi
  if cmp -s "$tmp/gcc.out" "$tmp/pb.out" && [ "$(cat "$tmp/gcc.rc")" = "$(cat "$tmp/pb.rc")" ]; then
    echo "ok   $n (real mode: $(wc -l < "$tmp/pb.out") lines, qemu status $(cat "$tmp/pb.rc"); .text+.data: $(size "$tmp/gcc.o" | awk 'NR==2{print $1+$2}') bytes by gcc, $(size "$tmp/pb.o" | awk 'NR==2{print $1+$2}') by Path B)"
  else
    echo "FAIL $n: gcc status $(cat "$tmp/gcc.rc"), Path B $(cat "$tmp/pb.rc")"; diff "$tmp/gcc.out" "$tmp/pb.out" | head -8; fail=1
  fi
done
exit $fail
