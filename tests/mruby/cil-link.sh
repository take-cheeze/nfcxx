#!/usr/bin/env bash
# scripts/cil-link.{py,rb}: the mruby port must give the same output as the Python original (the oracle in
# tests/mruby/oracle/cil-link.py) for the fragments the current toolchain writes:
#   1. every tests/cil/cases/*.c, compiled by nfcc with NFCXX_BACKEND=cil (the qbe2cil.py route);
#   2. every tests/pathb-cil/cases/*.cpp, through scripts/pathb-dump --ir and pathb-cil-emit.py (the Path B route).
# Both versions link the same fragments with the IL kept. Compared: the CIL text, the exit status, and the output of
# the linked programs (exit status and stdout, against the program's EXPECT line and its .out file when it has them).
# Then the hand-written fragments of tests/mruby/cil-link: a fragment that makes ilasm fail (OUT.failed.il), 64-bit
# integers and float bit patterns above 2**63 - 1 (what JSON.parse loses), a main with arguments, and the usage errors.
# SKIP without python3, an mruby interpreter or build/cil/ilasm (scripts/setup-cil.sh). Parts 1 and 2 need the front
# ends (build/edg, build/qbe, build/cproc: scripts/setup-edg.sh, setup-qbe.sh; build/pathb: setup-pathb.sh) and are
# skipped with a message without them. The programs run only when dotnet is installed.
cd "$(dirname "$0")/../.."
root=$PWD; oracle=$root/tests/mruby/oracle/cil-link.py; here=$root/tests/mruby/cil-link
ilasm=${ILASM:-$root/build/cil/ilasm}
command -v python3 >/dev/null || { echo "SKIP cil-link: python3 not installed"; exit 0; }
[ -x "${MRB:-$root/build/mruby-tool/bin/mruby}" ] || { echo "SKIP cil-link: no mruby (scripts/setup-mruby.sh)"; exit 0; }
[ -x "$ilasm" ] || { echo "SKIP cil-link: scripts/setup-cil.sh has not run"; exit 0; }
dotnet=$(command -v dotnet || true)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/frag"
fail=0; cil_n=0; pb_n=0; runs=0; link_n=0

# same A B: both files are there and equal, or both are missing.
same() { if [ -e "$1" ] || [ -e "$2" ]; then cmp -s "$1" "$2"; else return 0; fi; }

# link_cmp LABEL FRAGMENT...: links with the Python original (into $tmp/link/LABEL/py) and the port (into .../rb), with the
# IL kept. Compares the exit status, the CIL text, the failed IL and the runtime config; when both linked, runs both
# programs and compares their exit status and stdout. Optional globals: want (the expected exit status), ref (the
# expected stdout file). Counts the linked programs in link_n.
link_cmp() {
  local label=$1; shift
  local d=$tmp/link/$label
  mkdir -p "$d/py" "$d/rb"
  ILASM=$ilasm NFCXX_KEEP_IL=1 python3 "$oracle" -o "$d/py/prog" "$@" 2>"$d/py.err"; local rcp=$?
  "$root/scripts/mrb" "$root/scripts/cil-link.rb" --ilasm "$ilasm" --keep-il -o "$d/rb/prog" "$@" 2>"$d/rb.err"; local rcr=$?
  if [ $rcp -ne $rcr ]; then
    echo "FAIL cil-link $label: exit status py=$rcp rb=$rcr"; head -3 "$d/py.err" "$d/rb.err"; fail=1; return
  fi
  for x in il failed.il runtimeconfig.json; do
    if ! same "$d/py/prog.$x" "$d/rb/prog.$x"; then echo "FAIL cil-link $label: $x differs"; diff "$d/py/prog.$x" "$d/rb/prog.$x" | head -5; fail=1; return; fi
  done
  if [ $rcp -ne 0 ]; then
    if [ ! -e "$d/rb/prog.failed.il" ]; then echo "FAIL cil-link $label: no failed IL written"; fail=1; return; fi
    echo "ok   cil-link $label (refused by ilasm, status $rcp, the same failed IL)"
    return
  fi
  if [ ! -s "$d/rb/prog.il" ]; then echo "FAIL cil-link $label: no IL written"; fail=1; return; fi
  link_n=$((link_n + 1))
  if [ -z "$dotnet" ]; then echo "ok   cil-link $label (IL identical, $(wc -l < "$d/rb/prog.il") lines; dotnet missing, not run)"; return; fi
  # (a program that aborts on purpose, as the bounds checks of tests/pathb-cil do, reports it on the shell's stderr)
  (cd "$d/py" && ./prog </dev/null >"$d/py.stdout" 2>/dev/null) 2>/dev/null; sp=$?
  (cd "$d/rb" && ./prog </dev/null >"$d/rb.stdout" 2>/dev/null) 2>/dev/null; sr=$?
  runs=$((runs + 2))
  if [ $sp -ne $sr ] || ! cmp -s "$d/py.stdout" "$d/rb.stdout"; then
    echo "FAIL cil-link $label: program output differs (py status $sp, rb status $sr)"; fail=1; return
  fi
  if [ -n "${want:-}" ] && [ "$sr" != "$want" ]; then echo "FAIL cil-link $label: want exit $want got $sr"; fail=1; return; fi
  if [ -n "${ref:-}" ] && ! cmp -s "$ref" "$d/rb.stdout"; then echo "FAIL cil-link $label: stdout differs from ${ref#$root/}"; fail=1; return; fi
  echo "ok   cil-link $label (IL identical, program exit $sr)"
}

# usage_cmp LABEL MSG ARGS...: both versions fail with status 1 on ARGS. MSG (when not "-") is the exact stderr text.
usage_cmp() {
  local label=$1 msg=$2; shift 2
  local d=$tmp/usage/$label; mkdir -p "$d"
  ILASM=$ilasm python3 "$oracle" "$@" 2>"$d/py.err" >/dev/null; local rcp=$?
  "$root/scripts/mrb" "$root/scripts/cil-link.rb" --ilasm "$ilasm" "$@" 2>"$d/rb.err" >/dev/null; local rcr=$?
  if [ $rcp -ne 1 ] || [ $rcr -ne 1 ]; then echo "FAIL cil-link usage $label: status py=$rcp rb=$rcr, want 1"; fail=1; return; fi
  if [ "$msg" != - ] && { [ "$(cat "$d/py.err")" != "$msg" ] || [ "$(cat "$d/rb.err")" != "$msg" ]; }; then
    echo "FAIL cil-link usage $label: stderr differs from '$msg'"; head -2 "$d/py.err" "$d/rb.err"; fail=1; return
  fi
  echo "ok   cil-link usage $label"
}

# ---- 1. the qbe2cil.py route: tests/cil/cases through nfcc -------------------------------------------------------------
want= ref=
if [ -x "$root/build/edg/bin/eccp" ] && [ -x "$root/build/qbe/qbe" ] && [ -x "$root/build/cproc/cproc-qbe" ]; then
  for f in "$root"/tests/cil/cases/*.c; do
    n=$(basename "$f" .c)
    if ! NFCXX_BACKEND=cil "$root/nfcc" -c "$f" -o "$tmp/frag/cil-$n.o" 2>"$tmp/frag/cil-$n.err"; then
      echo "FAIL cil-link: nfcc made no fragment for cil/$n"; head -3 "$tmp/frag/cil-$n.err"; fail=1; continue
    fi
    cil_n=$((cil_n + 1))
    want=$(sed -n 's,^// EXPECT: *\(-*[0-9]*\).*,\1,p' "$f" | head -1)
    ref=; [ -f "$root/tests/cil/cases/$n.out" ] && ref=$root/tests/cil/cases/$n.out
    link_cmp "cil-$n" "$tmp/frag/cil-$n.o"
  done
  want= ref=
else
  echo "skip cil-link: the qbe2cil route needs EDG, QBE and cproc (scripts/setup-edg.sh, setup-qbe.sh)"
fi

# ---- 2. the Path B route: tests/pathb-cil/cases through pathb-dump and pathb-cil-emit.py -------------------------------
if [ -x "$root/build/pathb/cmake/bin/cpfe" ]; then
  for f in "$root"/tests/pathb-cil/cases/*.cpp; do
    n=$(basename "$f" .cpp)
    grep -q '^// EXPECT-REFUSED' "$f" && continue  # the emitter refuses these: no fragment
    if ! "$root/scripts/pathb-dump" --ir "$f" >"$tmp/frag/pb-$n.ir" 2>/dev/null ||
       ! python3 "$root/scripts/pathb-cil-emit.py" "$tmp/frag/pb-$n.ir" "$tmp/frag/pb-$n.json" 2>/dev/null; then
      echo "FAIL cil-link: no fragment for pathb-cil/$n"; fail=1; continue
    fi
    pb_n=$((pb_n + 1))
    want=$(sed -n 's,^// EXPECT: *\(-*[0-9]*\).*,\1,p' "$f" | head -1)
    link_cmp "pb-$n" "$tmp/frag/pb-$n.json"
  done
  want=
else
  echo "skip cil-link: the Path B route needs the harness (scripts/setup-pathb.sh)"
fi
# The comparison must not be vacuous: with a front end present, its fragments were linked.
if [ -x "$root/build/edg/bin/eccp" ] && [ $cil_n -lt 4 ]; then echo "FAIL cil-link: only $cil_n qbe2cil fragments"; fail=1; fi
if [ -x "$root/build/pathb/cmake/bin/cpfe" ] && [ $pb_n -lt 4 ]; then echo "FAIL cil-link: only $pb_n Path B fragments"; fail=1; fi

# ---- 3. hand-written fragments --------------------------------------------------------------------------------------
link_cmp bigint "$here/bigint.json"
# The integers must be the same bits the Python original writes (the float64 with the sign bit, the int64 minimum).
if ! grep -q 'ldc.r8 (00 00 00 00 00 00 00 c0)' "$tmp/link/bigint/rb/prog.il" || ! grep -q 'ldc.i8 -9223372036854775808' "$tmp/link/bigint/rb/prog.il"; then
  echo "FAIL cil-link bigint: the IL lacks the 64-bit bit patterns"; fail=1
fi
# An ilasm failure: the IL is written to OUT.failed.il and the exit status is 1, in both.
link_cmp bad-il "$here/bad-il.json"
if ! grep -qF 'cil-link: ilasm failed (the IL is in ' "$tmp/link/bad-il/rb.err" || ! grep -qF 'cil-link: ilasm failed (the IL is in ' "$tmp/link/bad-il/py.err"; then
  echo "FAIL cil-link bad-il: the failure message differs"; fail=1
fi
# A main with arguments other than (int, char **).
usage_cmp bad-main "cil-link: main takes ['int64']; only main(void) and main(int, char **) are supported" -o "$tmp/usage/x" "$here/bad-main.json"

# ---- 4. usage errors -----------------------------------------------------------------------------------------------
usage_cmp no-o "cil-link: no -o OUT" "$here/bigint.json"
usage_cmp no-fragments "cil-link: no input fragments" -o "$tmp/usage/x"
usage_cmp defined-twice "cil-link: function main is defined twice" -o "$tmp/usage/x" "$here/bigint.json" "$here/bigint.json"
usage_cmp missing-fragment - -o "$tmp/usage/x" "$tmp/usage/no-such-file.json"
usage_cmp o-without-name - "$here/bigint.json" -o
# An ilasm that is not there: both refuse with status 1 (the messages name the setting differently).
d=$tmp/usage/no-ilasm; mkdir -p "$d"
ILASM=$tmp/usage/no-such-ilasm python3 "$oracle" -o "$d/py" "$here/bigint.json" 2>"$d/py.err"; rcp=$?
"$root/scripts/mrb" "$root/scripts/cil-link.rb" --ilasm "$tmp/usage/no-such-ilasm" -o "$d/rb" "$here/bigint.json" 2>"$d/rb.err"; rcr=$?
if [ $rcp -eq 1 ] && [ $rcr -eq 1 ] && grep -q '^cil-link: ilasm not found at ' "$d/py.err" && grep -q '^cil-link: ilasm not found at ' "$d/rb.err"; then
  echo "ok   cil-link usage no-ilasm"
else echo "FAIL cil-link usage no-ilasm: status py=$rcp rb=$rcr"; fail=1; fi

# The programs run through the same launcher on both sides: a fragment set with no link failure must have run.
if [ -n "$dotnet" ] && [ $link_n -gt 0 ] && [ $runs -ne $((link_n * 2)) ]; then echo "FAIL cil-link: $runs runs for $link_n programs"; fail=1; fi
[ $fail -eq 0 ] || exit 1
echo "cil-link: $link_n programs linked, $cil_n qbe2cil and $pb_n Path B fragments compared"
exit 0
