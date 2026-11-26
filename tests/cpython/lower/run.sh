#!/usr/bin/env bash
# CPython 3.13 .pyc -> Path B IR (tools/cpython/cpy_lower), end to end, for the lowered subset.
#
# Each program lower/*.py is compiled to a .pyc by python3 (3.13), lowered to IR (tools/cpython/cpy_lower), emitted to QBE IL
# by scripts/pathb-qbe-emit.rb (run by scripts/mrb.rb), assembled by build/qbe/qbe, linked with the runtime in
# tests/cpython/runtime, and run. Three kinds of program:
#   lower/*.py          the printed `result` global (one line) and the exit status (0) must equal the reference's: python3
#                       runs the same source and prints its `result`.
#   lower/rterr/*.py    a run-time error: the exit status (1) and the last line of the reference's stderr (the exception
#                       line, e.g. "ZeroDivisionError: ...") must appear in the program's stderr.
#   lower/err/*.py      refused: cpy_lower must exit 3 with "refused:" on stderr and print nothing on stdout.
#
#   PYTHON=python3 MRB=/path/to/mruby tests/cpython/lower/run.sh
# The emitter runs under mruby: MRB names the mruby interpreter (scripts/mrb.rb builds one when MRB is unset). Exit 77
# (skip) when PYTHON is not a CPython 3.13.
set -u
shopt -s nullglob
root=$(cd "$(dirname "$0")/../../.." && pwd)
dir=$root/tests/cpython
src=$root/tools/cpython
work=${TMPDIR:-/tmp}/cpython-lower.$$
mkdir -p "$work"
trap 'rm -rf "$work"' EXIT

PY=${PYTHON:-python3}
if ! "$PY" -c 'import sys; sys.exit(0 if sys.version_info[:2] == (3, 13) else 1)' 2>/dev/null; then
  echo "cpython-lower: skipped (PYTHON must be CPython 3.13)"
  exit 77
fi
c++ -std=c++17 -Wall -Wextra -o "$work/lower" "$src/cpy_marshal.cpp" "$src/cpy_lower.cpp" "$src/cpy_lower_main.cpp" || exit 1
cc -std=c99 -Wall -Wextra -c -o "$work/pyrt.o" "$dir/runtime/pyrt.c" || exit 1
cc -std=c99 -Wall -Wextra -c -o "$work/driver.o" "$dir/runtime/driver.c" || exit 1

# compile FILE.py to FILE.pyc (CPython 3.13, timestamp-based, the default)
pyc() {
  "$PY" -c 'import py_compile, sys; py_compile.compile(sys.argv[1], cfile=sys.argv[2], doraise=True)' "$1" "$2"
}

# build PYC NAME: the program's binary in $work/NAME, or a failure message on stdout (status 1).
build() {
  local pycfile=$1 base=$2
  "$work/lower" "$pycfile" > "$work/$base.ir" 2> "$work/$base.err" || { echo "lowering refused: $(cat "$work/$base.err")"; return 1; }
  "$root/scripts/mrb.rb" "$root/scripts/pathb-qbe-emit.rb" "$work/$base.ir" > "$work/$base.ssa" 2> "$work/$base.err" \
    || { echo "emitter: $(cat "$work/$base.err")"; return 1; }
  "$root/build/qbe/qbe" "$work/$base.ssa" > "$work/$base.s" 2> "$work/$base.err" || { echo "qbe: $(cat "$work/$base.err")"; return 1; }
  cc -o "$work/$base.bin" "$work/$base.s" "$work/pyrt.o" "$work/driver.o" -lm || { echo "link"; return 1; }
}

fail=0
n=0
for py in "$dir"/lower/*.py; do
  base=$(basename "$py" .py)
  mkdir -p "$work/$base"
  pyc "$py" "$work/$base/$base.pyc" || { echo "FAIL $base: python3 refused the source"; fail=1; continue; }
  if ! msg=$(build "$work/$base/$base.pyc" "$base"); then echo "FAIL $base: $msg"; fail=1; continue; fi
  got=$("$work/$base.bin" 2>&1); gs=$?
  want=$("$PY" -c 'import runpy, sys; print(runpy.run_path(sys.argv[1])["result"])' "$py" 2>&1); ws=$?
  if [ "$got" != "$want" ] || [ "$gs" -ne "$ws" ]; then
    echo "FAIL $base: got [$got] (status $gs), python3 says [$want] (status $ws)"
    fail=1
    continue
  fi
  n=$((n + 1))
done

for py in "$dir"/lower/err/*.py; do
  base=$(basename "$py" .py)
  mkdir -p "$work/err/$base"
  pyc "$py" "$work/err/$base/$base.pyc" || { echo "FAIL err/$base: python3 refused the source"; fail=1; continue; }
  "$work/lower" "$work/err/$base/$base.pyc" > "$work/err/$base.ir" 2> "$work/err/$base.err"
  status=$?
  if [ "$status" -ne 3 ] || [ -s "$work/err/$base.ir" ] || ! grep -q '^refused: ' "$work/err/$base.err"; then
    echo "FAIL err/$base: expected a refusal (exit 3), got exit $status: $(cat "$work/err/$base.err")"
    fail=1
    continue
  fi
  n=$((n + 1))
done

# lower/rterr/*.py lower and run, and must fail at run time with exit 1 and the exception line that python3 prints last.
for py in "$dir"/lower/rterr/*.py; do
  base=$(basename "$py" .py)
  mkdir -p "$work/rterr/$base"
  pyc "$py" "$work/rterr/$base/$base.pyc" || { echo "FAIL rterr/$base: python3 refused the source"; fail=1; continue; }
  if ! msg=$(build "$work/rterr/$base/$base.pyc" "rterr_$base"); then echo "FAIL rterr/$base: $msg"; fail=1; continue; fi
  got=$("$work/rterr_$base.bin" 2>&1); gs=$?
  want=$("$PY" "$py" 2>&1 | tail -1)
  if [ "$gs" -ne 1 ] || [ -z "$want" ] || [ "${got#*"$want"}" = "$got" ]; then
    echo "FAIL rterr/$base: expected exit 1 with '$want', got exit $gs: '$got'"
    fail=1
    continue
  fi
  n=$((n + 1))
done

# The header: a .pyc of another version (the magic number of CPython 3.12 here) and a hash-based .pyc are refused (exit 3).
mkdir -p "$work/header"
pyc "$dir/lower/arith.py" "$work/header/arith.pyc" || { echo "FAIL header: python3 refused the source"; fail=1; }
"$PY" -c 'import sys; d = bytearray(open(sys.argv[1], "rb").read()); d[0:4] = b"\xcb\x0d\x0d\x0a"; open(sys.argv[2], "wb").write(d)' \
  "$work/header/arith.pyc" "$work/header/magic312.pyc" || fail=1
"$PY" -c 'import py_compile, sys; py_compile.compile(sys.argv[1], cfile=sys.argv[2], doraise=True, invalidation_mode=py_compile.PycInvalidationMode.UNCHECKED_HASH)' \
  "$dir/lower/arith.py" "$work/header/hash.pyc" || fail=1
for bad in magic312 hash; do
  "$work/lower" "$work/header/$bad.pyc" > "$work/header/$bad.ir" 2> "$work/header/$bad.err"
  status=$?
  if [ "$status" -ne 3 ] || [ -s "$work/header/$bad.ir" ] || ! grep -q '^refused: ' "$work/header/$bad.err"; then
    echo "FAIL header/$bad: expected a refusal (exit 3), got exit $status: $(cat "$work/header/$bad.err")"
    fail=1
  fi
done

if [ "$fail" -ne 0 ]; then
  echo "cpython-lower: FAILED"
  exit 1
fi
echo "cpython-lower: $n programs match python3 (or are refused as required)"
