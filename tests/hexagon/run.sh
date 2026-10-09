#!/usr/bin/env bash
# Hexagon check for the generated C of every tests/cases/*.cpp (see docs/notes/hexagon.md).
#   1. EDG generates C for a 32-bit little-endian target (scripts/gen-c-target.sh, linux_riscv32).
#   2. clang --target=hexagon compiles it (-fwrapv -fno-strict-aliasing, as the gcc backend does).
#   3. If qemu-hexagon (Linux user mode) is installed, the object is flattened (flatlink.py,
#      since no Hexagon linker exists here), run, and its exit code compared with `// EXPECT:`.
# Cases that throw get tests/hexagon/eh_rt.c appended. Cases needing relocations or libc that flatlink.py lacks, and template
# instantiation (edg_prelink), are reported as SKIP with the reason. Exits 0 with SKIP when clang
# has no Hexagon backend.
# Env: CLANG (default clang), QEMU_HEXAGON (default qemu-hexagon), EDG_TARGET (default linux_riscv32).
cd "$(dirname "$0")/../.."
root=$PWD; here=$root/tests/hexagon
clang=${CLANG:-clang}; qemu=${QEMU_HEXAGON:-qemu-hexagon}; target=${EDG_TARGET:-linux_riscv32}
triple=hexagon-unknown-linux-musl

if ! echo 'int f(void){return 0;}' | $clang --target=$triple -ffreestanding -c -x c - -o /dev/null 2>/dev/null; then
  echo "SKIP hexagon: $clang has no hexagon target"; exit 0
fi
run=1
command -v "$qemu" >/dev/null 2>&1 || { run=0; echo "note: $qemu not found; compile-only"; }
[ -x "$root/build/edg/bin/cpfe" ] || { echo "SKIP hexagon: EDG not built (scripts/setup-edg.sh)"; exit 0; }

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fail=0; pass=0; skip=0
for f in "$root"/tests/cases/*.cpp; do
  n=$(basename "$f" .cpp)
  want=$(sed -n 's,^// EXPECT: *\(-\?[0-9]*\).*,\1,p' "$f" | head -1)
  if ! "$root/scripts/gen-c-target.sh" -t "$target" -o "$tmp/$n.c" "$f" 2>"$tmp/$n.edg"; then
    # The target configuration has no hosted C++ headers, so a case that includes <cstdint>, <map>,
    # etc. cannot be generated for it. That is a limit of this check, not a failure of the case.
    if grep -q "cannot open source file" "$tmp/$n.edg"; then
      echo "skip $n: SKIP-headers: $target has no hosted C++ headers"; skip=$((skip+1)); continue
    fi
    echo "FAIL (edg) $n"; head -3 "$tmp/$n.edg"; fail=1; continue
  fi
  cat "$here/stub.c" >> "$tmp/$n.c"
  # A case that throws (or rethrows) gets the EH runtime in the same translation unit.
  ehdef=
  if grep -q '__throw_setup\|__rethrow\|__internal_rethrow' "$tmp/$n.c"; then
    ehdef=-DNFCXX_EH_RT
    cat "$here/eh_rt.c" >> "$tmp/$n.c"
  fi
  # -G0: no small-data (GP) base is set up at run time, so every global is addressed absolutely.
  if ! $clang --target=$triple -ffreestanding -fno-pic -G0 -O2 -fwrapv -fno-strict-aliasing -w $ehdef \
        -c "$tmp/$n.c" -o "$tmp/$n.o" 2>"$tmp/$n.cc"; then
    echo "FAIL (clang) $n"; head -3 "$tmp/$n.cc"; fail=1; continue
  fi
  if [ $run = 0 ]; then echo "ok   compile $n"; pass=$((pass+1)); continue; fi
  if ! python3 "$here/flatlink.py" "$tmp/$n.o" "$tmp/$n.elf" _start 2>"$tmp/$n.link"; then
    case $(cat "$tmp/$n.link") in
      *SKIP-*) echo "skip $n: $(sed 's/^flatlink: //' "$tmp/$n.link")"; skip=$((skip+1)) ;;
      *) echo "FAIL (link) $n"; cat "$tmp/$n.link"; fail=1 ;;
    esac
    continue
  fi
  chmod +x "$tmp/$n.elf"
  timeout 30 "$qemu" "$tmp/$n.elf" >/dev/null 2>&1; got=$?
  if [ $((got & 255)) -eq $((want & 255)) ]; then echo "ok   run $n"; pass=$((pass+1));
  else echo "FAIL (run) $n: want $want got $got"; fail=1; fi
done
# Hand-written HVX kernel (no EDG): clang builtins with -mhvx, one 128-byte vaddh, exit 192.
if $clang --target=$triple -ffreestanding -fno-pic -O2 -mhvx -mhvx-length=128b -w \
      -c "$here/hvx_vaddh.c" -o "$tmp/hvx.o" 2>"$tmp/hvx.cc"; then
  if [ $run = 0 ]; then echo "ok   compile hvx_vaddh"; pass=$((pass+1));
  elif ! python3 "$here/flatlink.py" "$tmp/hvx.o" "$tmp/hvx.elf" _start 2>"$tmp/hvx.link"; then
    echo "FAIL (link) hvx_vaddh"; cat "$tmp/hvx.link"; fail=1
  else
    chmod +x "$tmp/hvx.elf"
    timeout 30 "$qemu" "$tmp/hvx.elf" >/dev/null 2>&1; got=$?
    if [ "$got" -eq 192 ]; then echo "ok   run hvx_vaddh"; pass=$((pass+1));
    else echo "FAIL (run) hvx_vaddh: want 192 got $got"; fail=1; fi
  fi
else
  echo "FAIL (clang) hvx_vaddh"; head -3 "$tmp/hvx.cc"; fail=1
fi
echo "hexagon: $pass passed, $skip skipped"
exit $fail
