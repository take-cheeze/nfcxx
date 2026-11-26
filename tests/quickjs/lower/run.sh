#!/usr/bin/env bash
# QuickJS bytecode -> Path B IR (tools/quickjs/qjs_lower), end to end, for the lowered subset.
#
# Each program lower/*.js is compiled to QuickJS bytecode (tools/quickjs/qjs_compile, built from the same source as the
# reference qjs), lowered to IR (qjs_lower), emitted to QBE IL by scripts/pathb-qbe-emit.rb (run by scripts/mrb.rb),
# assembled by build/qbe/qbe, linked with the runtime in tests/quickjs/runtime, and run. Three kinds of program:
#   lower/*.js         the value of the global `result` (one line) and the exit status (0) must equal the reference's: the
#                      reference is qjs run on the same source with `console.log(result)` appended.
#   lower/rterr/*.js   a run-time error: the exit status (1) and the last line of the reference's stderr must appear in the
#                      program's stderr.
#   lower/err/*.js     refused: qjs_lower must exit 3 with "refused:" on stderr and print nothing on stdout.
# The header: an image of another BC_VERSION is refused (exit 3), a truncated one fails (exit 1).
#
#   QJS=/path/to/qjs tests/quickjs/lower/run.sh
# Without QJS, the reference is built from the submodule (3rd/quickjs) in build/quickjs-ref. The submodule's files are not
# written: the build happens in a copy.
set -u
shopt -s nullglob
root=$(cd "$(dirname "$0")/../../.." && pwd)
dir=$root/tests/quickjs
src=$root/tools/quickjs
work=${TMPDIR:-/tmp}/quickjs-lower.$$
mkdir -p "$work"
trap 'rm -rf "$work"' EXIT

if [ ! -x "$root/build/qbe/qbe" ]; then
  echo "quickjs-lower: build/qbe/qbe is missing (scripts/setup-qbe.sh)"
  exit 1
fi

# The reference qjs and the library the compile driver links: built from the submodule's source in a copy.
if [ -z "${QJS:-}" ]; then
  ref=$root/build/quickjs-ref
  if [ ! -x "$ref/qjs" ] || [ ! -f "$ref/libquickjs.a" ]; then
    rm -rf "$ref"
    mkdir -p "$root/build"
    cp -r "$root/3rd/quickjs" "$ref" || exit 1
    rm -rf "$ref/.git"
    make -C "$ref" qjs libquickjs.a > "$work/make.log" 2>&1 || { cat "$work/make.log"; echo "quickjs-lower: the reference does not build"; exit 1; }
  fi
  QJS=$ref/qjs
  lib=$ref/libquickjs.a
else
  # the compile driver needs the library of the same source: the directory of QJS, or the submodule's build next to it
  lib=$(dirname "$QJS")/libquickjs.a
  if [ ! -f "$lib" ]; then
    echo "quickjs-lower: $lib is missing (build the library next to QJS: make libquickjs.a)"
    exit 1
  fi
fi

c++ -std=c++17 -Wall -Wextra -I "$src" -o "$work/qjs_lower" "$src/qjs_lower_main.cpp" "$src/qjs_lower.cpp" \
  "$src/qjs_bc.cpp" "$src/qjs_insn.cpp" || exit 1
cc -std=c99 -O1 -I "$(dirname "$lib")" -o "$work/qjs_compile" "$src/qjs_compile.c" "$lib" -lm -lpthread -ldl || exit 1
cc -std=c99 -Wall -Wextra -c -o "$work/qjrt.o" "$dir/runtime/qjrt.c" || exit 1
cc -std=c99 -Wall -Wextra -c -o "$work/driver.o" "$dir/runtime/driver.c" || exit 1

# build PROG.js NAME: the program's binary in $work/NAME, or a failure message on stdout (status 1).
build() {
  local js=$1 base=$2
  "$work/qjs_compile" "$js" "$work/$base.qjsbc" 2> "$work/$base.err" || { echo "compile: $(cat "$work/$base.err")"; return 1; }
  "$work/qjs_lower" "$work/$base.qjsbc" > "$work/$base.ir" 2> "$work/$base.err" || { echo "lowering refused: $(cat "$work/$base.err")"; return 1; }
  "$root/scripts/mrb.rb" "$root/scripts/pathb-qbe-emit.rb" "$work/$base.ir" > "$work/$base.ssa" 2> "$work/$base.err" \
    || { echo "emitter: $(cat "$work/$base.err")"; return 1; }
  "$root/build/qbe/qbe" "$work/$base.ssa" > "$work/$base.s" 2> "$work/$base.err" || { echo "qbe: $(cat "$work/$base.err")"; return 1; }
  cc -o "$work/$base" "$work/$base.s" "$work/qjrt.o" "$work/driver.o" -lm || { echo "link"; return 1; }
}

fail=0
n=0
for js in "$dir"/lower/*.js; do
  base=$(basename "$js" .js)
  if ! msg=$(build "$js" "$base"); then echo "FAIL $base: $msg"; fail=1; continue; fi
  got=$("$work/$base" 2>&1); gs=$?
  # the reference: the same program, with its result printed
  wrapped=$work/ref_$base.js
  { cat "$js"; printf '\nconsole.log(result);\n'; } > "$wrapped"
  want=$("$QJS" "$wrapped" 2>&1); ws=$?
  if [ "$got" != "$want" ] || [ "$gs" -ne "$ws" ]; then
    echo "FAIL $base: got [$got] (status $gs), qjs says [$want] (status $ws)"
    fail=1
    continue
  fi
  n=$((n + 1))
done

ne=0
for js in "$dir"/lower/err/*.js; do
  base=err_$(basename "$js" .js)
  "$work/qjs_compile" "$js" "$work/$base.qjsbc" 2> "$work/$base.err" || { echo "FAIL $base: qjs_compile refused the source: $(cat "$work/$base.err")"; fail=1; continue; }
  "$work/qjs_lower" "$work/$base.qjsbc" > "$work/$base.ir" 2> "$work/$base.err"
  status=$?
  if [ "$status" -ne 3 ] || [ -s "$work/$base.ir" ] || ! grep -q '^refused: ' "$work/$base.err"; then
    echo "FAIL err/$(basename "$js" .js): expected a refusal (exit 3), got exit $status: $(cat "$work/$base.err")"
    fail=1
    continue
  fi
  ne=$((ne + 1))
done

nr=0
for js in "$dir"/lower/rterr/*.js; do
  base=rterr_$(basename "$js" .js)
  if ! msg=$(build "$js" "$base"); then echo "FAIL rterr/$(basename "$js" .js): $msg"; fail=1; continue; fi
  got=$("$work/$base" 2>&1 >/dev/null); gs=$?
  "$QJS" "$js" > /dev/null 2> "$work/$base.qjs_err"; qs=$?
  # qjs prints the error line first and then its stack ("    at <eval> (path:line)"), so the error line is compared: the
  # last line of qjs's output would be the stack frame, which names the file's path.
  want=$(head -1 "$work/$base.qjs_err")
  if [ "$gs" -ne 1 ] || [ "$qs" -ne 1 ] || [ -z "$want" ] || [ "${got#*"$want"}" = "$got" ]; then
    echo "FAIL rterr/$(basename "$js" .js): expected exit 1 with qjs's last line '$want', got exit $gs: '$got'"
    fail=1
    continue
  fi
  nr=$((nr + 1))
done

# The header: an image of another version is refused, a truncated one is malformed.
hdr=$dir/lower/arith.js
"$work/qjs_compile" "$hdr" "$work/hdr.qjsbc" && {
  cp "$work/hdr.qjsbc" "$work/hdr_v4.qjsbc"
  printf '\x04' | dd of="$work/hdr_v4.qjsbc" bs=1 count=1 conv=notrunc 2>/dev/null
  "$work/qjs_lower" "$work/hdr_v4.qjsbc" > /dev/null 2> "$work/hdr_v4.err"; s4=$?
  if [ "$s4" -ne 3 ] || ! grep -q '^refused: bytecode version 4' "$work/hdr_v4.err"; then
    echo "FAIL header: a version 4 image gave exit $s4: $(cat "$work/hdr_v4.err")"
    fail=1
  fi
  head -c 20 "$work/hdr.qjsbc" > "$work/hdr_cut.qjsbc"
  "$work/qjs_lower" "$work/hdr_cut.qjsbc" > /dev/null 2> "$work/hdr_cut.err"; sc=$?
  if [ "$sc" -ne 1 ]; then
    echo "FAIL header: a truncated image gave exit $sc: $(cat "$work/hdr_cut.err")"
    fail=1
  fi
} || { echo "FAIL header: qjs_compile refused arith.js"; fail=1; }

if [ "$fail" -ne 0 ]; then
  echo "quickjs-lower: FAILED"
  exit 1
fi
echo "quickjs-lower: $n programs match qjs (or are refused as required), $ne refusals, $nr run-time errors match"
