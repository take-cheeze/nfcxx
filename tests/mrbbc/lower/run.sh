#!/usr/bin/env bash
# mruby 4.0 bytecode -> Path B IR (tools/mrbbc/mrb_lower.cpp), end to end, for the lowered subset.
#
# Each program is compiled by mrbc_rb (bc2cpp/tools/mrbc_rb, the Ruby RITE emitter; it needs Prism 1.9.0), lowered
# (mrbbc_lower), emitted to QBE IL by
# scripts/pathb-qbe-emit.rb (run by scripts/mrb.rb), assembled by QBE, linked with the runtime in tests/mrbbc/runtime, and
# run. Three kinds of program:
#   lower/*.rb       the value the program returns (its last line is one expression) is printed the way mruby's p prints
#                    it. The reference is the pinned mruby run on the same file with that last line replaced by p(...).
#   lower/rterr/*.rb an uncaught runtime error: the exit status is 1 and the last stderr line, after its "file:line: "
#                    prefix, equals the mruby's (the class in parentheses included).
#   lower/err/*.rb   a program with an opcode, operand form or table the producer does not lower yet. It is refused: the
#                    lowering exits 3, writes "refused:" on stderr and nothing on stdout. A program with more than 255
#                    registers (EXT1 prefixes) is generated here and refused the same way. --report-all lists that
#                    refusal first (and every one, as err/NAME.report says when it exists); it lists none for lower/*.rb.
# A program that is refused never reaches the emitter, so a refusal is not a silent miscompile.
#
#   tests/mrbbc/lower/run.sh
# MRBBC_VALUE selects the value layout (8, the default; 4 or 16): the lowering's --value and the runtime's MRBBC_VALUE.
# MRBBC_GC_THRESHOLD=1 collects before every allocation (GC stress); RT_CFLAGS goes to the runtime's compile and the link
# (for example -DMRBBC_GC_CONSERVATIVE=1, or -fsanitize=address).
# Exit 77 (skip) when mrbc, the mruby interpreter or QBE is missing.
set -u
root=$(cd "$(dirname "$0")/../../.." && pwd)
src=$root/tools/mrbbc
rt=$root/tests/mrbbc/runtime
dir=$root/tests/mrbbc/lower
MRBC=${MRBC:-$root/bc2cpp/tools/mrbc_rb/bin/mrbc_rb}
# No C mrbc fallback: a program that mrbc_rb cannot compile fails the suite, rather than being compiled by another tool.
export MRBC_FALLBACK=${MRBC_FALLBACK:-/nonexistent}
MRUBY=${MRUBY:-$root/build/mruby-tool/bin/mruby}
QBE=${QBE:-$root/build/qbe/qbe}
VALUE=${MRBBC_VALUE:-8}
RT_CFLAGS=${RT_CFLAGS:-}
work=${TMPDIR:-/tmp}/mrbbc-lower.$$
mkdir -p "$work"
trap 'rm -rf "$work"' EXIT

if [ ! -x "$MRBC" ] || [ ! -x "$MRUBY" ] || [ ! -x "$QBE" ]; then
  echo "mrbbc-lower: skipped (needs mrbc at $MRBC, the mruby interpreter at $MRUBY and QBE at $QBE)"
  exit 77
fi

c++ -std=c++17 -O1 -Wall -Wextra -Werror -I"$src" -o "$work/lower" "$src/mrb_rite.cpp" "$src/mrb_lower.cpp" \
  "$src/mrbbc_lower_main.cpp" || exit 1
# shellcheck disable=SC2086
cc -std=c99 -Wall -Wextra -Werror -DMRBBC_VALUE="$VALUE" $RT_CFLAGS -c -o "$work/mrbrt.o" "$rt/mrbrt.c" || exit 1
# shellcheck disable=SC2086
cc -std=c99 -Wall -Wextra -Werror -DMRBBC_VALUE="$VALUE" $RT_CFLAGS -c -o "$work/driver.o" "$rt/driver.c" || exit 1

# build SRC NAME: the program binary in $work/NAME, or the failing step's message on stdout (status 1).
build() {
  local rb=$1 base=$2
  "$MRBC" -o "$work/$base.rite" "$rb" > /dev/null 2>&1 || { echo "mrbc refused the program"; return 1; }
  "$work/lower" --value="$VALUE" "$work/$base.rite" > "$work/$base.ir" 2> "$work/$base.err" \
    || { echo "lowering: $(cat "$work/$base.err")"; return 1; }
  "$root/scripts/mrb.rb" "$root/scripts/pathb-qbe-emit.rb" "$work/$base.ir" > "$work/$base.ssa" 2> "$work/$base.err" \
    || { echo "emitter: $(cat "$work/$base.err")"; return 1; }
  "$QBE" "$work/$base.ssa" > "$work/$base.s" 2> "$work/$base.err" || { echo "qbe: $(cat "$work/$base.err")"; return 1; }
  # shellcheck disable=SC2086
  cc $RT_CFLAGS -o "$work/$base" "$work/$base.s" "$work/mrbrt.o" "$work/driver.o" || { echo "link"; return 1; }
}

# value_ref SRC OUT: SRC with its last line replaced by p(LAST), the reference program.
value_ref() {
  local rb=$1 out=$2 last
  last=$(tail -n 1 "$rb")
  head -n -1 "$rb" > "$out"
  printf 'p(%s)\n' "$last" >> "$out"
}

# The generated programs: 200 locals with a sum (registers below 256), and a 100-deep nested sum over the locals,
# which needs registers past 255 (mrbc widens those with an EXT1 prefix; the producer refuses them).
wide_ok=$work/wide_locals.rb
wide_ext=$work/wide_ext.rb
: > "$wide_ok"
for i in $(seq 1 200); do echo "v$i = $i" >> "$wide_ok"; done
echo "v1 + v2 + v100 + v200" >> "$wide_ok"
cp "$wide_ok" "$wide_ext"
pre=; post=
for i in $(seq 1 100); do pre="$pre""v$i + ("; post=")$post"; done
echo "x = ${pre}v101${post}" >> "$wide_ext"
echo "x" >> "$wide_ext"

fail=0
n=0
for rb in "$dir"/*.rb "$wide_ok"; do
  base=$(basename "$rb" .rb)
  if ! msg=$(build "$rb" "$base"); then echo "FAIL $base: $msg"; fail=1; continue; fi
  value_ref "$rb" "$work/$base.ref.rb"
  if ! report=$("$work/lower" --report-all "$work/$base.rite" 2> /dev/null) || [ -n "$report" ]; then
    echo "FAIL $base: --report-all lists [$(echo "$report" | head -n 1)]"; fail=1; continue
  fi
  got=$("$work/$base") || { echo "FAIL $base: the program exited with status $?"; fail=1; continue; }
  want=$("$MRUBY" "$work/$base.ref.rb") || { echo "FAIL $base: the reference failed"; fail=1; continue; }
  n=$((n + 1))
  if [ "$got" != "$want" ]; then
    echo "FAIL $base: got [$got], mruby gives [$want]"
    fail=1
  fi
done

nr=0
for rb in "$dir"/rterr/*.rb; do
  base=rterr_$(basename "$rb" .rb)
  if ! msg=$(build "$rb" "$base"); then echo "FAIL $base: $msg"; fail=1; continue; fi
  "$work/$base" > "$work/$base.out" 2> "$work/$base.stderr"; status=$?
  "$MRUBY" "$rb" > "$work/$base.mout" 2> "$work/$base.mstderr"; mstatus=$?
  got=$(tail -n 1 "$work/$base.stderr" | sed -E 's/.*: //')
  want=$(tail -n 1 "$work/$base.mstderr" | sed -E 's/.*: //')
  nr=$((nr + 1))
  if [ "$status" -ne 1 ] || [ "$mstatus" -ne 1 ] || [ "$got" != "$want" ] || [ -s "$work/$base.out" ]; then
    echo "FAIL $base: got [$got] (status $status), mruby gives [$want] (status $mstatus)"
    fail=1
  fi
done

ne=0
for rb in "$dir"/err/*.rb "$wide_ext"; do
  base=err_$(basename "$rb" .rb)
  "$MRBC" -o "$work/$base.rite" "$rb" > /dev/null 2>&1 || { echo "FAIL $base: mrbc refused the program"; fail=1; continue; }
  "$work/lower" "$work/$base.rite" > "$work/$base.out" 2> "$work/$base.err"; status=$?
  ne=$((ne + 1))
  if [ "$status" -ne 3 ] || ! grep -q '^refused: ' "$work/$base.err" || [ -s "$work/$base.out" ]; then
    echo "FAIL $base: status $status, stderr [$(head -n 1 "$work/$base.err")]"
    fail=1
    continue
  fi
  "$work/lower" --report-all "$work/$base.rite" > "$work/$base.report" 2> /dev/null; status=$?
  first=$(head -n 1 "$work/$base.report" | sed -E 's/^[^:]*: //')
  if [ "$status" -ne 3 ] || [ "$first" != "$(head -n 1 "$work/$base.err")" ]; then
    echo "FAIL $base: --report-all status $status, first [$first]"
    fail=1
  elif [ -f "${rb%.rb}.report" ] && ! diff -u "${rb%.rb}.report" "$work/$base.report"; then
    echo "FAIL $base: --report-all differs from $(basename "${rb%.rb}").report"
    fail=1
  fi
done

if [ "$fail" -ne 0 ]; then
  echo "mrbbc-lower: FAILED"
  exit 1
fi
echo "mrbbc-lower (value $VALUE): $n programs match mruby 4.0; $nr runtime errors match mruby; $ne programs refused (exit 3)"
