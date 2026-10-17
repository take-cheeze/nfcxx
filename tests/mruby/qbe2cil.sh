#!/usr/bin/env bash
# scripts/qbe2cil.{py,rb}: the mruby port must give the same bytes as the Python original (the oracle in
# tests/mruby/oracle/) on each fixture in tests/mruby/qbe2cil/. Compared: the JSON fragment (byte for byte) and the exit
# status; for a refusal, the status and a message on stderr from both (the texts differ where Python raises an uncaught
# exception). The assembly tail is an input: qbe2cil reads its .quad lines (the constructors); each run gets its own copy
# and must leave the file as it was.
#   real_*.ssa   QBE IL from the repo's front end, once (see the recipe below); real_qbe_global_ctor.tail.s is its tail.
#   e_*.ssa      hand-written IL for the forms the corpus does not reach: every data item kind, every operator and
#                compare, aggregates, the export quirk, UTF-8 and control bytes in names.
#   r_*.ssa      hand-written IL that both refuse (exit 1).
# Recipe for the real_ fixtures (done once, on this repo, with EDG, cproc and QBE built): C++ inputs go through
# `nfcxx --emit-c`; hand-written C through qbe-cc's C-input path (-include defs.h, qbe-prep.rb --c-input). Then
#   cc -E -P -undef -D__CPROC__ [-include defs.h] FILE > pp.c
#   scripts/mrb scripts/qbe-prep.rb [--c-input] pp.c prep.c tail.s
#   build/cproc/cproc-qbe < prep.c > out.ssa
cd "$(dirname "$0")/../.."
root=$PWD; here=$root/tests/mruby/qbe2cil; oracle=$root/tests/mruby/oracle
command -v python3 >/dev/null || { echo "SKIP qbe2cil: python3 not installed"; exit 0; }
[ -x "${MRB:-$root/build/mruby-tool/bin/mruby}" ] || { echo "SKIP qbe2cil: no mruby (scripts/setup-mruby.sh)"; exit 0; }
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fail=0; accepted=0; refused=0

for f in "$here"/*.ssa; do
  n=$(basename "$f" .ssa)
  tail=$here/$n.tail.s; [ -f "$tail" ] || tail=-
  tp=$tail; tr=$tail
  if [ "$tail" != - ]; then cp "$tail" "$tmp/$n.py.tail"; cp "$tail" "$tmp/$n.rb.tail"; tp=$tmp/$n.py.tail; tr=$tmp/$n.rb.tail; fi
  python3 "$oracle/qbe2cil.py" "$f" "$tp" "$n" "$tmp/$n.py.json" 2>"$tmp/$n.py.err"; rcp=$?
  "$root/scripts/mrb" "$root/scripts/qbe2cil.rb" "$f" "$tr" "$n" "$tmp/$n.rb.json" 2>"$tmp/$n.rb.err"; rcr=$?
  if [ "$tail" != - ] && { ! cmp -s "$tail" "$tmp/$n.py.tail" || ! cmp -s "$tail" "$tmp/$n.rb.tail"; }; then
    echo "FAIL qbe2cil $n: the assembly tail was changed by a run"; fail=1; continue
  fi
  if [ $rcp -ne $rcr ]; then
    echo "FAIL qbe2cil $n: exit status py=$rcp rb=$rcr"; head -2 "$tmp/$n.py.err" "$tmp/$n.rb.err"; fail=1; continue
  fi
  if [ $rcp -ne 0 ]; then
    if [ ! -s "$tmp/$n.py.err" ] || [ ! -s "$tmp/$n.rb.err" ]; then
      echo "FAIL qbe2cil $n: a refusal without a message"; fail=1; continue
    fi
    refused=$((refused + 1)); echo "ok   qbe2cil $n (refused, exit $rcp)"; continue
  fi
  if ! cmp -s "$tmp/$n.py.json" "$tmp/$n.rb.json"; then
    echo "FAIL qbe2cil $n: JSON differs from the Python original"; cmp "$tmp/$n.py.json" "$tmp/$n.rb.json" | head -2; fail=1; continue
  fi
  echo "ok   qbe2cil $n ($(wc -c < "$tmp/$n.rb.json") bytes of JSON)"
  accepted=$((accepted + 1))
done

# The comparison must not be vacuous: enough inputs of both kinds, and the outputs exercise the features the CIL
# backend has to get right (variadic calls, indirect calls, stack slots, data items, constructors).
if [ $accepted -lt 14 ] || [ $refused -lt 15 ]; then
  echo "FAIL qbe2cil: too little was compared ($accepted accepted, $refused refused)"; fail=1
fi
for want in nfcxx_vcall calli localloc '"zero"' '"addr"' '"float32"' '"float64"' '"variadic": true' '"ctors": \[$'; do
  if ! grep -q -- "$want" "$tmp"/*.py.json; then echo "FAIL qbe2cil: no fragment has $want"; fail=1; fi
done
if [ $fail -eq 0 ]; then echo "ok   qbe2cil: $accepted fragments and $refused refusals identical to the Python original"; fi
exit $fail
