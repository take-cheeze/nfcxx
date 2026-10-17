#!/usr/bin/env bash
# scripts/pathb-cil-emit.{py,rb}: the mruby port must give the same result as the Python original (the oracle in
# tests/mruby/oracle/) on every input: the JSON fragment it writes, stdout, stderr and the exit status must be identical.
#   - tests/pathb-ir/*.ir and tests/pathb-ir/borrow/*.ir (stored IR of the C++ programs);
#   - tests/mruby/pathb-cil-edge/*.ir (hand-written IR: one file per refusal and error path, and the success forms of
#     the number atoms, the data initializers, the try idiom and the indirect call). A file named x_* makes the Python
#     original die with an uncaught exception (a traceback there), so only the exit status is compared for it;
#   - the IR of tests/pathb-cil/cases/*.cpp when the Path B harness is built (scripts/setup-pathb.sh);
#   - generated inputs: CRLF line ends and a raw CR inside a string (the text mode of the original reads files with
#     universal newlines, stdin is read as it is), octal escapes above 255 in a name, a usage error, a missing file, an
#     extra argument, and the IR from stdin ('-').
# The usage is `pathb-cil-emit FILE.ir OUT.json` (or `-` for stdin); the fragment goes to OUT.json.
cd "$(dirname "$0")/../.."
root=$PWD; oracle=$root/tests/mruby/oracle; here=$root/tests/mruby/pathb-cil-edge
command -v python3 >/dev/null || { echo "SKIP pathb-cil-emit: python3 not installed"; exit 0; }
[ -x "${MRB:-$root/build/mruby-tool/bin/mruby}" ] || { echo "SKIP pathb-cil-emit: no mruby (scripts/setup-mruby.sh)"; exit 0; }
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fail=0; runs=0; emitted=0; refused=0; errors=0; bytes=0

# cil_both <label> <mode> <stdin file> <args...>: runs the Python original and the port with the same arguments (the word
# OUT stands for the fragment path, each run has its own). mode is full (stdout, stderr, status and fragment are compared)
# or status (the Python original raises: only stdout and status). Counts the runs by outcome.
cil_both() {
  local label=$1 mode=$2 in=$3; shift 3
  local pa=() ra=() x rcp rcr
  for x in "$@"; do
    if [ "$x" = OUT ]; then pa+=("$tmp/py.json"); ra+=("$tmp/rb.json"); else pa+=("$x"); ra+=("$x"); fi
  done
  rm -f "$tmp/py.json" "$tmp/rb.json"
  runs=$((runs + 1))
  python3 "$oracle/pathb-cil-emit.py" "${pa[@]}" <"$in" >"$tmp/py.out" 2>"$tmp/py.err"; rcp=$?
  "$root/scripts/mrb" "$root/scripts/pathb-cil-emit.rb" "${ra[@]}" <"$in" >"$tmp/rb.out" 2>"$tmp/rb.err"; rcr=$?
  if [ "$rcp" -ne "$rcr" ]; then
    echo "FAIL pathb-cil-emit $label: exit status py=$rcp rb=$rcr"; head -2 "$tmp/py.err" "$tmp/rb.err"; fail=1; return
  fi
  if ! cmp -s "$tmp/py.out" "$tmp/rb.out"; then echo "FAIL pathb-cil-emit $label: stdout differs"; fail=1; return; fi
  if [ "$mode" = full ] && ! cmp -s "$tmp/py.err" "$tmp/rb.err"; then
    echo "FAIL pathb-cil-emit $label: stderr differs"; head -2 "$tmp/py.err" "$tmp/rb.err"; fail=1; return
  fi
  if [ -e "$tmp/py.json" ] || [ -e "$tmp/rb.json" ]; then
    if ! cmp -s "$tmp/py.json" "$tmp/rb.json"; then echo "FAIL pathb-cil-emit $label: fragment differs"; fail=1; return; fi
  fi
  if [ "$rcp" -eq 0 ]; then
    if [ "$mode" = status ]; then echo "FAIL pathb-cil-emit $label: expected an exception, got a fragment"; fail=1; return; fi
    emitted=$((emitted + 1)); bytes=$((bytes + $(wc -c <"$tmp/py.json")))
  elif grep -q '^pathb-cil-emit: refused: ' "$tmp/py.err" 2>/dev/null; then refused=$((refused + 1))
  else errors=$((errors + 1))
  fi
}

# Input files of the stored corpus: the goldens and the hand-written IR.
for f in "$root"/tests/pathb-ir/*.ir "$root"/tests/pathb-ir/borrow/*.ir; do
  cil_both "${f#$root/tests/}" full /dev/null "$f" OUT
done
for f in "$here"/*.ir; do
  case $(basename "$f") in x_*) mode=status ;; *) mode=full ;; esac
  cil_both "pathb-cil-edge/$(basename "$f")" $mode /dev/null "$f" OUT
done

# The IR of the CIL spike's C++ programs, when the Path B harness is built (the same lowering as scripts/pathb-cil).
cpfe=${PATHB_CPFE:-$root/build/pathb/cmake/bin/cpfe}
if [ -x "$cpfe" ]; then
  export PATHB_CPFE=$cpfe PATHB_BASE=${PATHB_BASE:-$root/build/pathb/edg-base}
  mkdir -p "$tmp/ir"
  gen=0
  for f in "$root"/tests/pathb-cil/cases/*.cpp; do
    b=$(basename "$f" .cpp)
    "$root/scripts/pathb-dump" --ir "$f" >"$tmp/ir/$b.ir" 2>/dev/null || continue
    gen=$((gen + 1))
    cil_both "pathb-cil/cases/$b" full /dev/null "$tmp/ir/$b.ir" OUT
  done
  [ $gen -gt 0 ] || { echo "FAIL pathb-cil-emit: the harness produced no IR"; fail=1; }
else
  echo "skip pathb-cil-emit: no Path B harness at $cpfe (scripts/setup-pathb.sh), only the stored IR is checked"
fi

# Generated inputs.
# CRLF line ends, and a raw CR LF inside a string: the file is read in text mode (universal newlines), stdin is not.
printf '(data "d" (array 4 char) (string "a\r\nb"))\r\n(function "f" (ret int) (params) (return (const int 0)))\r\n' >"$tmp/crlf.ir"
cil_both "CRLF file" full /dev/null "$tmp/crlf.ir" OUT
cil_both "CRLF on stdin" full "$tmp/crlf.ir" - OUT
# Octal escapes in a name: \351 (latin-1 e-acute) and \777 (511, above a byte), which JSON writes as \u escapes.
printf '(function "f\\351\\777" (ret int) (params) (return (const int 0)))\n' >"$tmp/names.ir"
cil_both "octal names" full /dev/null "$tmp/names.ir" OUT
# A superscript one (a latin-1 digit for isdigit, which int() refuses) after %: the original raises.
printf '(function "f" (ret int) (params) (return %%\262))\n' >"$tmp/sup.ir"
cil_both "superscript temporary" status /dev/null "$tmp/sup.ir" OUT
# Stdin, the usage errors, a missing file, an extra argument.
cil_both "stdin" full "$here/ok_numbers.ir" - OUT
cil_both "usage (no arguments)" status /dev/null
cil_both "usage (one argument)" status /dev/null "$here/ok_numbers.ir"
cil_both "missing file" status /dev/null "$tmp/no-such.ir" OUT
cil_both "extra argument is ignored" full /dev/null "$here/ok_numbers.ir" OUT extra

# The comparison must not be vacuous: the fragments, the refusals and the uncaught errors were all exercised.
if [ $emitted -lt 20 ] || [ $refused -lt 40 ] || [ $errors -lt 8 ]; then
  echo "FAIL pathb-cil-emit: too little was compared (emitted=$emitted refused=$refused errors=$errors)"; fail=1
fi
[ $fail -eq 0 ] && echo "ok   pathb-cil-emit: $runs runs identical ($emitted fragments, $((bytes / 1024)) KB of JSON, $refused refused, $errors errors)"
exit $fail
