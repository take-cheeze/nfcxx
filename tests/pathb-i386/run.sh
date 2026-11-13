#!/usr/bin/env bash
# Path B on the 32-bit x86 target (scripts/pathb-cc --i386; docs/notes/nfcc-pathb.md): each tests/pathb-i386/cases/*.c defines
# `int pb_main(void)`, is built by Path B and by `gcc -m32`, linked with tests/pathb-i386/rt.c (built by gcc: its output
# helpers, the libgcc division functions and the block functions, so the calls go both ways between gcc's code and QBE's), and run as a
# 32-bit Linux program (a static one, no libc; int $0x80). Both must print the same and exit with the same status: the
# oracle is gcc, not a number in the file. Each case runs in QBE's two conventions: cdecl (i386) and gcc's -mregparm=3
# (i386_regparm3), the one the kernel's real-mode code is built with. A case whose first line is `// NO-RUN` is only built
# (code for real mode, say). The real-mode build (--m16) of every case is checked to assemble and to be 16-bit code
# (objdump -m i8086 shows the operand size prefixes of .code16gcc).
# Needs gcc with -m32 (the compiler only: no 32-bit libc), ld, objdump, the Path B harness (scripts/setup-pathb.sh) and QBE
# (scripts/setup-qbe.sh). A host that cannot run 32-bit programs (no IA32 emulation) only builds: "skip run".
cd "$(dirname "$0")/../.."
root=$PWD
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fail=0
gccf=(-m32 -ffreestanding -fno-pic -fno-pie -fno-stack-protector -fwrapv -fno-strict-aliasing -fno-asynchronous-unwind-tables -O1)
rtf=(-fno-builtin -fno-tree-loop-distribute-patterns)

# can this host run a 32-bit program?
printf '\t.globl _start\n_start:\n\tmovl $1, %%eax\n\tmovl $3, %%ebx\n\tint $0x80\n' > "$tmp/probe.S"
canrun=0
if gcc -m32 -c "$tmp/probe.S" -o "$tmp/probe.o" 2>/dev/null && ld -m elf_i386 -o "$tmp/probe" "$tmp/probe.o" 2>/dev/null; then
  "$tmp/probe"; [ $? != 3 ] || canrun=1
fi
[ $canrun = 1 ] || echo "skip run: this host does not run 32-bit programs (only the builds are checked)"

for conv in cdecl regparm; do
  cf=(); pf=(--i386); gf=()
  if [ $conv = regparm ]; then cf=(-mregparm=3); pf+=(--regparm=3); fi
  gcc "${gccf[@]}" "${cf[@]}" "${rtf[@]}" -c tests/pathb-i386/rt.c -o "$tmp/rt-$conv.o" || { echo "FAIL rt ($conv)"; exit 1; }
  for f in tests/pathb-i386/cases/*.c; do
    n=$(basename "$f" .c)
    norun=0; head -1 "$f" | grep -q '^// NO-RUN' && norun=1
    if ! scripts/pathb-cc "${pf[@]}" "$f" -o "$tmp/pb.o" 2>"$tmp/err"; then
      echo "FAIL $n ($conv): Path B: $(head -3 "$tmp/err")"; fail=1; continue
    fi
    if ! file "$tmp/pb.o" | grep -q 'ELF 32-bit'; then echo "FAIL $n ($conv): the object is not ELF32"; fail=1; continue; fi
    if [ $canrun = 0 ] || [ $norun = 1 ]; then echo "ok   $n ($conv, built)"; continue; fi
    gcc "${gccf[@]}" "${cf[@]}" -c "$f" -o "$tmp/gcc.o" 2>"$tmp/err" || { echo "FAIL $n ($conv): gcc: $(head -3 "$tmp/err")"; fail=1; continue; }
    ld -m elf_i386 -o "$tmp/gcc.exe" "$tmp/rt-$conv.o" "$tmp/gcc.o" 2>"$tmp/err" || { echo "FAIL $n ($conv): gcc link: $(head -3 "$tmp/err")"; fail=1; continue; }
    ld -m elf_i386 -o "$tmp/pb.exe" "$tmp/rt-$conv.o" "$tmp/pb.o" 2>"$tmp/err" || { echo "FAIL $n ($conv): Path B link: $(head -3 "$tmp/err")"; fail=1; continue; }
    "$tmp/gcc.exe" > "$tmp/gcc.out"; want=$?
    "$tmp/pb.exe" > "$tmp/pb.out"; got=$?
    if [ "$got" = "$want" ] && cmp -s "$tmp/gcc.out" "$tmp/pb.out"; then
      echo "ok   $n ($conv, exit $got, $(wc -l < "$tmp/pb.out") lines)"
    else
      echo "FAIL $n ($conv): gcc exits $want, Path B $got"; diff "$tmp/gcc.out" "$tmp/pb.out" | head -6; fail=1
    fi
  done
done

# real mode: .code16gcc, built and read back
for f in tests/pathb-i386/cases/*.c; do
  n=$(basename "$f" .c)
  if ! scripts/pathb-cc --i386 --regparm=3 --m16 "$f" -o "$tmp/pb16.o" 2>"$tmp/err"; then
    echo "FAIL $n (m16): Path B: $(head -3 "$tmp/err")"; fail=1; continue
  fi
  if objdump -d -m i8086 "$tmp/pb16.o" | grep -q '	66 55 '; then echo "ok   $n (m16: 16-bit code)"; else echo "FAIL $n (m16): no operand size prefix in the code"; fail=1; fi
done
exit $fail
