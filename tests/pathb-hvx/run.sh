#!/usr/bin/env bash
# Path B prototype IR -> C+HVX emitter check (scripts/pathb-hvx-emit.rb, docs/notes/hexagon.md section 5).
# For each tests/pathb-hvx/cases/* probe: scripts/pathb-dump.rb --ir -> the emitter ->
# clang --target=hexagon -> flatlink (tests/hexagon/flatlink.rb, no Hexagon linker exists) ->
# run under qemu-hexagon, exit code compared with the probe's // EXPECT:.
# A probe the emitter must refuse (tests/pathb-qbe/cases/arith.cpp has no vector loop,
# and a whole runnable module like hvx_add_i16.cpp is outside the prototype): exit 3
# with `refused:` on stderr.
# Skips cleanly when the harness, clang's Hexagon backend or qemu is missing.
# Env: PATHB_CPFE/PATHB_BASE (default build/pathb/...), CLANG (default clang), QEMU_HEXAGON (default qemu-hexagon).
cd "$(dirname "$0")/../.."
root=$PWD; here=$root/tests/pathb-hvx
cpfe=${PATHB_CPFE:-$root/build/pathb/cmake/bin/cpfe}
[ -x "$cpfe" ] || { echo "SKIP pathb-hvx: no harness at $cpfe; run scripts/setup-pathb.sh"; exit 0; }
clang=${CLANG:-clang}; qemu=${QEMU_HEXAGON:-qemu-hexagon}
triple=hexagon-unknown-linux-musl
if ! echo 'int f(void){return 0;}' | $clang --target=$triple -ffreestanding -c -x c - -o /dev/null 2>/dev/null; then
  echo "SKIP pathb-hvx: $clang has no hexagon target"; exit 0
fi
run=1
command -v "$qemu" >/dev/null 2>&1 || { run=0; echo "note: $qemu not found; compile-only"; }
[ -x "$root/scripts/mrb.rb" ] || { echo "SKIP pathb-hvx: scripts/mrb.rb not executable"; exit 0; }

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fail=0; pass=0
export PATHB_CPFE=$cpfe
export PATHB_BASE=${PATHB_BASE:-$root/build/pathb/edg-base}
for d in "$here"/cases/*/; do
  n=$(basename "$d")
  want=$(sed -n 's,^// EXPECT: *\(-*[0-9]*\).*,\1,p' "$d/main.c" | head -1)
  [ -n "$want" ] || { echo "FAIL (probe) $n: no // EXPECT: in main.c"; fail=1; continue; }
  if ! ruby "$root/scripts/pathb-dump.rb" --ir "$d/loop.cpp" >"$tmp/$n.ir" 2>"$tmp/$n.dump"; then
    echo "FAIL (dump) $n"; head -3 "$tmp/$n.dump"; fail=1; continue
  fi
  if ! "$root/scripts/mrb.rb" "$root/scripts/pathb-hvx-emit.rb" "$tmp/$n.ir" >"$tmp/$n.c" 2>"$tmp/$n.emit"; then
    echo "FAIL (emit) $n"; head -3 "$tmp/$n.emit"; fail=1; continue
  fi
  cat "$d/main.c" >> "$tmp/$n.c"
  if ! $clang --target=$triple -ffreestanding -fno-pic -G0 -O2 -fwrapv -fno-strict-aliasing -mhvx -mhvx-length=128b -w \
        -c "$tmp/$n.c" -o "$tmp/$n.o" 2>"$tmp/$n.cc"; then
    echo "FAIL (clang) $n"; head -3 "$tmp/$n.cc"; fail=1; continue
  fi
  if ! $clang --target=$triple -ffreestanding -fno-pic -G0 -O2 -fwrapv -fno-strict-aliasing -mhvx -mhvx-length=128b -w \
        -S "$tmp/$n.c" -o "$tmp/$n.s" 2>"$tmp/$n.asm"; then
    echo "FAIL (asm) $n"; head -3 "$tmp/$n.asm"; fail=1; continue
  fi
  if ! grep -q "vadd" "$tmp/$n.s"; then
    echo "FAIL (vectorize) $n: no vadd in Hexagon assembly"; fail=1; continue
  fi
  if [ $run = 0 ]; then echo "ok   compile $n"; pass=$((pass+1)); continue; fi
  if ! "$root/scripts/mrb.rb" "$root/tests/hexagon/flatlink.rb" "$tmp/$n.o" "$tmp/$n.elf" _start 2>"$tmp/$n.link"; then
    echo "FAIL (link) $n"; cat "$tmp/$n.link"; fail=1; continue
  fi
  chmod +x "$tmp/$n.elf"
  timeout 30 "$qemu" "$tmp/$n.elf" >/dev/null 2>&1; got=$?
  if [ $((got & 255)) -eq $((want & 255)) ]; then echo "ok   run $n"; pass=$((pass+1));
  else echo "FAIL (run) $n: want $want got $got"; fail=1; fi
done
# Refusals: modules the prototype must not silently accept (exit 3, `refused:` on stderr).
refused_ok=1
if ruby "$root/scripts/pathb-dump.rb" --ir "$root/tests/pathb-qbe/cases/arith.cpp" >"$tmp/ref.ir" 2>/dev/null; then
  if "$root/scripts/mrb.rb" "$root/scripts/pathb-hvx-emit.rb" "$tmp/ref.ir" >"$tmp/ref.c" 2>"$tmp/ref.err"; then
    echo "FAIL (refuse) arith: emitter accepted a scalar module"; fail=1; refused_ok=0
  elif grep -q "^refused:" "$tmp/ref.err"; then
    echo "ok   refuse arith"; pass=$((pass+1))
  else
    echo "FAIL (refuse) arith: wrong stderr:"; head -2 "$tmp/ref.err"; fail=1; refused_ok=0
  fi
else
  echo "FAIL (dump) arith"; fail=1; refused_ok=0
fi
[ $refused_ok = 1 ] || true
# A whole-module dump with a main must also be refused (only single loops emit).
if ruby "$root/scripts/pathb-dump.rb" --ir "$root/tests/cases/hvx_add_i16.cpp" >"$tmp/whole.ir" 2>/dev/null; then
  if "$root/scripts/mrb.rb" "$root/scripts/pathb-hvx-emit.rb" "$tmp/whole.ir" >"$tmp/whole.c" 2>"$tmp/whole.err"; then
    echo "FAIL (refuse) whole-module: accepted main"; fail=1
  elif grep -q "^refused:" "$tmp/whole.err"; then
    echo "ok   refuse whole-module"; pass=$((pass+1))
  else
    echo "FAIL (refuse) whole-module: wrong stderr:"; head -2 "$tmp/whole.err"; fail=1
  fi
else
  echo "FAIL (dump) whole-module"; fail=1
fi
echo "pathb-hvx: $pass passed"
exit $fail
