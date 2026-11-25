#!/usr/bin/env bash
# MicroPython .mpy (bytecode, format 6) -> Path B IR (tools/mpy/mpy_lower), end to end, for the lowered subset.
#
# Each program lower/*.py is compiled by mpy-cross, lowered to IR, emitted to QBE IL by scripts/pathb-qbe-emit.rb (run by
# scripts/mrb.rb), assembled by QBE, linked with the runtime in tests/mpy/runtime, and run. The printed result must equal
# the `result` global that the MicroPython reference computes from the same .mpy file. A program in lower/err/ uses an
# opcode outside the subset: it must be refused (exit 3) with the reason on stderr, and no IR is produced.
#
#   MPY_CROSS=/path/to/mpy-cross MICROPY=/path/to/micropython tests/mpy/lower/run.sh
# Exit 77 (skip) when either variable is not set to an executable.
set -u
root=$(cd "$(dirname "$0")/../../.." && pwd)
dir=$root/tests/mpy
work=${TMPDIR:-/tmp}/mpy-lower.$$
mkdir -p "$work"
trap 'rm -rf "$work"' EXIT

if [ -z "${MPY_CROSS:-}" ] || [ ! -x "$MPY_CROSS" ] || [ -z "${MICROPY:-}" ] || [ ! -x "$MICROPY" ]; then
  echo "mpy-lower: skipped (set MPY_CROSS and MICROPY to mpy-cross and the reference micropython)"
  exit 77
fi
c++ -std=c++17 -Wall -Wextra -o "$work/lower" "$root/tools/mpy/mpy_reader.cpp" "$root/tools/mpy/mpy_lower.cpp" \
  "$root/tools/mpy/mpy_lower_main.cpp" || exit 1
cc -std=c99 -Wall -Wextra -c -o "$work/rt.o" "$dir/runtime/mpy_rt.c" || exit 1
cc -std=c99 -Wall -Wextra -c -o "$work/driver.o" "$dir/runtime/driver.c" || exit 1

fail=0
n=0
for src in "$dir"/lower/*.py; do
  base=$(basename "$src" .py)
  mkdir -p "$work/$base"
  "$MPY_CROSS" -o "$work/$base/$base.mpy" "$src" || { echo "FAIL $base: mpy-cross refused the source"; fail=1; continue; }
  "$work/lower" "$work/$base/$base.mpy" > "$work/$base.ir" 2> "$work/$base.err" \
    || { echo "FAIL $base: lowering refused: $(cat "$work/$base.err")"; fail=1; continue; }
  "$root/scripts/mrb.rb" "$root/scripts/pathb-qbe-emit.rb" "$work/$base.ir" > "$work/$base.ssa" 2> "$work/$base.err" \
    || { echo "FAIL $base: emitter: $(cat "$work/$base.err")"; fail=1; continue; }
  "$root/build/qbe/qbe" "$work/$base.ssa" > "$work/$base.s" 2> "$work/$base.err" \
    || { echo "FAIL $base: qbe: $(cat "$work/$base.err")"; fail=1; continue; }
  cc -o "$work/$base.bin" "$work/$base.s" "$work/rt.o" "$work/driver.o" -lm || { echo "FAIL $base: link"; fail=1; continue; }
  got=$("$work/$base.bin" 2>&1)
  want=$("$MICROPY" -c "import sys; sys.path.insert(0,'$work/$base'); import $base; print($base.result)" 2>&1)
  if [ "$got" != "$want" ]; then
    echo "FAIL $base: got '$got', MicroPython says '$want'"
    fail=1
    continue
  fi
  n=$((n + 1))
done

for src in "$dir"/lower/err/*.py; do
  base=$(basename "$src" .py)
  mkdir -p "$work/err/$base"
  "$MPY_CROSS" -o "$work/err/$base/$base.mpy" "$src" || { echo "FAIL err/$base: mpy-cross refused the source"; fail=1; continue; }
  "$work/lower" "$work/err/$base/$base.mpy" > "$work/err/$base.ir" 2> "$work/err/$base.err"
  status=$?
  if [ "$status" -ne 3 ] || [ -s "$work/err/$base.ir" ] || ! grep -q 'not lowered yet' "$work/err/$base.err"; then
    echo "FAIL err/$base: expected a refusal (exit 3), got exit $status: $(cat "$work/err/$base.err")"
    fail=1
    continue
  fi
  n=$((n + 1))
done

# lower/rterr/*.py lower and run, and must fail at run time (exit 1) with the exception line that MicroPython raises for the
# same module (its last output line, e.g. "TypeError: ..."), which is then the runtime's message after its "mpy: " prefix.
for src in "$dir"/lower/rterr/*.py; do
  base=$(basename "$src" .py)
  mkdir -p "$work/rterr/$base"
  "$MPY_CROSS" -o "$work/rterr/$base/$base.mpy" "$src" || { echo "FAIL rterr/$base: mpy-cross refused the source"; fail=1; continue; }
  "$work/lower" "$work/rterr/$base/$base.mpy" > "$work/rterr/$base.ir" 2> "$work/rterr/$base.err" \
    || { echo "FAIL rterr/$base: lowering refused: $(cat "$work/rterr/$base.err")"; fail=1; continue; }
  "$root/scripts/mrb.rb" "$root/scripts/pathb-qbe-emit.rb" "$work/rterr/$base.ir" > "$work/rterr/$base.ssa" 2> "$work/rterr/$base.err" \
    || { echo "FAIL rterr/$base: emitter: $(cat "$work/rterr/$base.err")"; fail=1; continue; }
  "$root/build/qbe/qbe" "$work/rterr/$base.ssa" > "$work/rterr/$base.s" 2> "$work/rterr/$base.err" \
    || { echo "FAIL rterr/$base: qbe: $(cat "$work/rterr/$base.err")"; fail=1; continue; }
  cc -o "$work/rterr/$base.bin" "$work/rterr/$base.s" "$work/rt.o" "$work/driver.o" -lm || { echo "FAIL rterr/$base: link"; fail=1; continue; }
  got=$("$work/rterr/$base.bin" 2>&1)
  status=$?
  want=$("$MICROPY" -c "import sys; sys.path.insert(0,'$work/rterr/$base'); import $base" 2>&1 | tail -1)
  if [ "$status" -ne 1 ] || [ -z "$want" ] || [ "${got#*"$want"}" = "$got" ]; then
    echo "FAIL rterr/$base: expected exit 1 with '$want', got exit $status: '$got'"
    fail=1
    continue
  fi
  n=$((n + 1))
done

if [ "$fail" -ne 0 ]; then
  echo "mpy-lower: FAILED"
  exit 1
fi
echo "mpy-lower: $n programs match the MicroPython reference (or are refused as required)"
