#!/usr/bin/env bash
# Local lifetime checker: positive, negative, refusal, and frontend integration tests.
set -euo pipefail
cd "$(dirname "$0")/../.."
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
pass=0
for src in tests/pathb-borrow/cases/*.ir; do
  want=$(head -1 "${src%.ir}.expect")
  rc=0
  scripts/mrb scripts/pathb-borrowck.rb "$src" > "$tmp/out" 2>&1 || rc=$?
  if [ "$rc" != "$want" ] || ! diff -u <(tail -n +2 "${src%.ir}.expect") "$tmp/out"; then
    echo "FAIL $src: expected exit $want, got $rc"
    cat "$tmp/out"
    exit 1
  fi
  echo "ok   $src"
  pass=$((pass + 1))
  if [ "$want" = 3 ]; then
    rc=0
    scripts/mrb scripts/pathb-borrowck.rb --infer-loan-ends "$src" > "$tmp/out" 2>&1 || rc=$?
    if [ "$rc" != 3 ] || ! diff -u <(tail -n +2 "${src%.ir}.expect") "$tmp/out"; then
      echo "FAIL $src: inference must preserve refusal"
      exit 1
    fi
    echo "ok   $src (inference preserves refusal)"
    pass=$((pass + 1))
  fi
done
# Inference is opt-in: compare each fixture with exact expectations in both modes.
for src in tests/pathb-borrow/inferred/*.ir; do
  for mode in explicit inferred; do
    options=()
    [ "$mode" = explicit ] || options=(--infer-loan-ends)
    expected=${src%.ir}.$mode.expect
    want=$(head -1 "$expected")
    rc=0
    scripts/mrb scripts/pathb-borrowck.rb "${options[@]}" "$src" > "$tmp/out" 2>&1 || rc=$?
    if [ "$rc" != "$want" ] || ! diff -u <(tail -n +2 "$expected") "$tmp/out"; then
      echo "FAIL $src ($mode): expected exit $want, got $rc"
      cat "$tmp/out"
      exit 1
    fi
    echo "ok   $src ($mode)"
    pass=$((pass + 1))
  done
done
# Value transfers are checked in explicit and inferred loan modes.
for src in tests/pathb-borrow/moves/*.ir tests/pathb-borrow/fields/*.ir tests/pathb-borrow/layouts/*.ir tests/pathb-borrow/drops/*.ir tests/pathb-borrow/calls/*.ir tests/pathb-borrow/returned/*.ir tests/pathb-borrow/verify/*.ir tests/pathb-borrow/index/*.ir tests/pathb-borrow/eh/*.ir tests/pathb-borrow/copy/*.ir; do
  for mode in explicit inferred; do
    options=()
    expected=${src%.ir}.expect
    if [ "$mode" = inferred ]; then
      options=(--infer-loan-ends)
      [ ! -f "${src%.ir}.inferred.expect" ] || expected=${src%.ir}.inferred.expect
    fi
    want=$(head -1 "$expected")
    rc=0
    scripts/mrb scripts/pathb-borrowck.rb "${options[@]}" "$src" > "$tmp/out" 2>&1 || rc=$?
    if [ "$rc" != "$want" ] || ! diff -u <(tail -n +2 "$expected") "$tmp/out"; then
      echo "FAIL $src ($mode): expected exit $want, got $rc"
      cat "$tmp/out"
      exit 1
    fi
    echo "ok   $src ($mode)"
    pass=$((pass + 1))
  done
done
# Summary inference is opt-in; each fixture runs with it in both loan modes.
for src in tests/pathb-borrow/summaries/*.ir; do
  for mode in explicit inferred; do
    options=(--infer-summaries)
    [ "$mode" = explicit ] || options+=(--infer-loan-ends)
    expected=${src%.ir}.expect
    want=$(head -1 "$expected")
    rc=0
    scripts/mrb scripts/pathb-borrowck.rb "${options[@]}" "$src" > "$tmp/out" 2>&1 || rc=$?
    if [ "$rc" != "$want" ] || ! diff -u <(tail -n +2 "$expected") "$tmp/out"; then
      echo "FAIL $src ($mode): expected exit $want, got $rc"
      cat "$tmp/out"
      exit 1
    fi
    echo "ok   $src ($mode)"
    pass=$((pass + 1))
  done
done
# Real C++ lowering already emits decl/scope-end facts. Compare the checker
# against source expectations, and require accepted IR to remain emit-able.
for src in tests/pathb-borrow/cpp/*.cpp; do
  NFCXX_PATHB_BORROW=1 scripts/pathb-dump --ir "$src" > "$tmp/source.ir"
  rc=0
  scripts/mrb scripts/pathb-borrowck.rb "$tmp/source.ir" > "$tmp/out" 2>&1 || rc=$?
  want=$(sed -n 's,^// EXIT: ,,p' "$src")
  pattern=$(sed -n 's,^// DIAG: ,,p' "$src")
  if [ "$rc" != "$want" ] || ! grep -Fq -- "$pattern" "$tmp/out"; then
    echo "FAIL $src: expected exit $want, got $rc"
    cat "$tmp/out"
    exit 1
  fi
  scripts/mrb scripts/pathb-qbe-emit.rb --no-prune "$tmp/source.ir" > "$tmp/source.qbe"
  echo "ok   $src"
  pass=$((pass + 1))
done
# Summaries of functions defined in the module are checked against their bodies.
# The same lowered C++ verifies under correct summaries and fails under wrong ones.
NFCXX_PATHB_BORROW=1 scripts/pathb-dump --ir tests/pathb-borrow/contracts/callees.cpp > "$tmp/callees.ir"
for effects in tests/pathb-borrow/contracts/*.effects; do
  { head -1 "$tmp/callees.ir"; cat "$effects"; tail -n +2 "$tmp/callees.ir"; } > "$tmp/contracted.ir"
  expected=${effects%.effects}.expect
  want=$(head -1 "$expected")
  for options in "" --infer-loan-ends; do
    rc=0
    scripts/mrb scripts/pathb-borrowck.rb $options "$tmp/contracted.ir" > "$tmp/out" 2>&1 || rc=$?
    if [ "$rc" != "$want" ] || ! diff -u <(tail -n +2 "$expected") "$tmp/out"; then
      echo "FAIL $effects ${options:-explicit}: expected exit $want, got $rc"
      exit 1
    fi
  done
  scripts/mrb scripts/pathb-qbe-emit.rb --no-prune "$tmp/contracted.ir" > "$tmp/contracted.qbe"
  echo "ok   $effects against lowered C++ bodies"
  pass=$((pass + 1))
done
# Inferred summaries let callers of lowered C++ callees be checked without
# annotations. Dropping the initializing call must expose the uninitialized use.
# The frontend prints the (borrow-layout ...) records of the structs involved.
NFCXX_PATHB_BORROW=1 scripts/pathb-dump --ir tests/pathb-borrow/contracts/inferred.cpp > "$tmp/inferred0.layout.ir"
grep -Fqx '(borrow-layout (struct "Pair") 8 4 (field "a" 0 int) (field "b" 4 int))' "$tmp/inferred0.layout.ir" ||
  { echo "FAIL inferred.cpp: no borrow-layout record for Pair"; exit 1; }
sed '/^  init_pair(&s, 2);$/d' tests/pathb-borrow/contracts/inferred.cpp > "$tmp/uninit.cpp"
NFCXX_PATHB_BORROW=1 scripts/pathb-dump --ir "$tmp/uninit.cpp" > "$tmp/uninit0.layout.ir" 2>/dev/null
for options in --infer-summaries "--infer-summaries --infer-loan-ends"; do
  scripts/mrb scripts/pathb-borrowck.rb $options "$tmp/inferred0.layout.ir" > "$tmp/out"
  grep -Fq 'ok: local lifetime checks passed' "$tmp/out" || { echo "FAIL inferred.cpp ($options)"; cat "$tmp/out"; exit 1; }
  rc=0
  scripts/mrb scripts/pathb-borrowck.rb $options "$tmp/uninit0.layout.ir" > "$tmp/out" 2>&1 || rc=$?
  if [ "$rc" != 1 ] || ! grep -Fq 'main: uninitialized: s' "$tmp/out"; then
    echo "FAIL inferred.cpp without init_pair ($options): expected exit 1, got $rc"
    cat "$tmp/out"
    exit 1
  fi
done
# Printed summaries are ordinary contracts: pasted back, they check without inference.
{ head -1 "$tmp/inferred0.layout.ir"
  scripts/mrb scripts/pathb-borrowck.rb --infer-summaries "$tmp/inferred0.layout.ir" | sed -n 's/^inferred: //p'
  tail -n +2 "$tmp/inferred0.layout.ir"; } > "$tmp/pasted.ir"
scripts/mrb scripts/pathb-borrowck.rb "$tmp/pasted.ir" > "$tmp/out"
scripts/mrb tests/mruby/oracle/pathb-qbe-emit.rb --no-prune "$tmp/pasted.ir" > "$tmp/pasted-oracle.qbe"
scripts/mrb scripts/pathb-qbe-emit.rb --no-prune "$tmp/pasted.ir" > "$tmp/pasted.qbe"
cmp "$tmp/pasted.qbe" "$tmp/pasted-oracle.qbe"
scripts/mrb scripts/pathb-qbe-emit.rb --no-prune "$tmp/inferred0.layout.ir" > "$tmp/inferred.qbe"
cmp "$tmp/inferred.qbe" "$tmp/pasted.qbe"
"${QBE:-build/qbe/qbe}" "$tmp/inferred.qbe" -o "$tmp/inferred.s"
cc "$tmp/inferred.s" -o "$tmp/inferred"
"$tmp/inferred" || { echo "FAIL inferred.cpp runtime: expected 0"; exit 1; }
echo "ok   inferred summaries for lowered C++ callees, mutant, and native execution"
pass=$((pass + 1))
# Plain calls to inferred returned-alias callees get implicit loans. Holding the
# returned alias across a direct write to its source must be a loan conflict.
aliases=tests/pathb-borrow/contracts/aliases.cpp
sed 's/^  bump(second(&s));$/  int *b = second(\&s); s.b = 9; bump(b);/' "$aliases" > "$tmp/aliases_held.cpp"
for name in aliases aliases_held; do
  src=$aliases
  [ "$name" = aliases ] || src=$tmp/$name.cpp
  NFCXX_PATHB_BORROW=1 scripts/pathb-dump --ir "$src" > "$tmp/$name.ir"
done
scripts/mrb scripts/pathb-borrowck.rb --infer-summaries --infer-loan-ends "$tmp/aliases.ir" > "$tmp/out"
grep -Fq 'ok: local lifetime checks passed' "$tmp/out" || { echo "FAIL $aliases"; cat "$tmp/out"; exit 1; }
rc=0
scripts/mrb scripts/pathb-borrowck.rb --infer-summaries --infer-loan-ends "$tmp/aliases_held.ir" > "$tmp/out" 2>&1 || rc=$?
if [ "$rc" != 1 ] || ! grep -q 'main: loan-conflict: s\[4\.\.8\] (&.*second.*#1)' "$tmp/out"; then
  echo "FAIL $aliases holding the alias across a write: expected exit 1, got $rc"
  cat "$tmp/out"
  exit 1
fi
rc=0
scripts/mrb scripts/pathb-borrowck.rb --infer-summaries "$tmp/aliases.ir" > "$tmp/out" 2>&1 || rc=$?
[ "$rc" = 3 ] || { echo "FAIL $aliases: implicit loans need inference, got $rc"; cat "$tmp/out"; exit 1; }
scripts/mrb scripts/pathb-qbe-emit.rb --no-prune "$tmp/aliases.ir" > "$tmp/aliases.qbe"
"${QBE:-build/qbe/qbe}" "$tmp/aliases.qbe" -o "$tmp/aliases.s"
cc "$tmp/aliases.s" -o "$tmp/aliases"
"$tmp/aliases" || { echo "FAIL $aliases runtime: expected 0"; exit 1; }
echo "ok   implicit returned loans for lowered C++ calls, held-alias mutant, and native execution"
pass=$((pass + 1))
# The frontend's (borrow-layout ...) records let a reader of a padded struct be
# summarized and checked. Without them the summary is not found, and the records
# never change generated code. Structs a record cannot describe get none.
lay=tests/pathb-borrow/contracts/layouts.cpp
NFCXX_PATHB_BORROW=1 scripts/pathb-dump --ir "$lay" > "$tmp/lay.ir"
grep -v '^(borrow-layout ' "$tmp/lay.ir" > "$tmp/lay_bare.ir"
cmp -s "$tmp/lay.ir" "$tmp/lay_bare.ir" && { echo "FAIL $lay: no borrow-layout records"; exit 1; }
scripts/mrb scripts/pathb-borrowck.rb --infer-summaries "$tmp/lay.ir" > "$tmp/out"
grep -Fq 'ok: local lifetime checks passed' "$tmp/out" || { echo "FAIL $lay"; cat "$tmp/out"; exit 1; }
rc=0
scripts/mrb scripts/pathb-borrowck.rb --infer-summaries "$tmp/lay_bare.ir" > "$tmp/out" 2>&1 || rc=$?
[ "$rc" = 3 ] || { echo "FAIL $lay without records: expected exit 3, got $rc"; cat "$tmp/out"; exit 1; }
scripts/mrb scripts/pathb-qbe-emit.rb --no-prune "$tmp/lay.ir" > "$tmp/lay.qbe"
scripts/mrb scripts/pathb-qbe-emit.rb --no-prune "$tmp/lay_bare.ir" > "$tmp/lay_bare.qbe"
cmp "$tmp/lay.qbe" "$tmp/lay_bare.qbe"
scripts/mrb tests/mruby/oracle/pathb-qbe-emit.rb --no-prune "$tmp/lay.ir" > "$tmp/lay-oracle.qbe"
cmp "$tmp/lay.qbe" "$tmp/lay-oracle.qbe"
"${QBE:-build/qbe/qbe}" "$tmp/lay.qbe" -o "$tmp/lay.s"
cc "$tmp/lay.s" -o "$tmp/lay"
"$tmp/lay" || { echo "FAIL $lay runtime: expected 0"; exit 1; }
NFCXX_PATHB_BORROW=1 scripts/pathb-dump --ir tests/pathb-borrow/contracts/nolayouts.cpp > "$tmp/nolay.ir"
grep '^(borrow-layout ' "$tmp/nolay.ir" > "$tmp/nolay.layouts" || true
printf '%s\n' '(borrow-layout (struct "Plain") 16 8 (field "z" 0 int) (field "next" 8 (ptr (const (struct "Plain")))))' |
  cmp - "$tmp/nolay.layouts" || { echo "FAIL nolayouts.cpp records"; cat "$tmp/nolay.layouts"; exit 1; }
scripts/mrb scripts/pathb-qbe-emit.rb --no-prune "$tmp/nolay.ir" > /dev/null
echo "ok   frontend borrow-layout records, record-less mutant, unsupported structs, and native execution"
pass=$((pass + 1))
# A const pointer result gets a shared alias summary; writing its source while the
# result is live conflicts. The printed summary validates in the emitter and oracle.
calias=tests/pathb-borrow/contracts/const_alias.cpp
sed 's/^  int v = \*q;$/  s.b = 5; int v = *q;/' "$calias" > "$tmp/calias_held.cpp"
NFCXX_PATHB_BORROW=1 scripts/pathb-dump --ir "$calias" > "$tmp/calias.ir"
NFCXX_PATHB_BORROW=1 scripts/pathb-dump --ir "$tmp/calias_held.cpp" > "$tmp/calias_held.ir"
scripts/mrb scripts/pathb-borrowck.rb --infer-summaries --infer-loan-ends "$tmp/calias.ir" > "$tmp/out"
grep -Fq '(returns (ptr (const int)) (from-arg 0 4 shared))' "$tmp/out" && grep -Fq 'ok: local lifetime checks passed' "$tmp/out" ||
  { echo "FAIL $calias"; cat "$tmp/out"; exit 1; }
rc=0
scripts/mrb scripts/pathb-borrowck.rb --infer-summaries --infer-loan-ends "$tmp/calias_held.ir" > "$tmp/out" 2>&1 || rc=$?
if [ "$rc" != 1 ] || ! grep -q 'main: loan-conflict: s\[4\.\.8\] (&.*second.*#1)' "$tmp/out"; then
  echo "FAIL $calias writing the source while the result is live: expected exit 1, got $rc"; cat "$tmp/out"; exit 1
fi
{ head -1 "$tmp/calias.ir"; sed -n 's/^inferred: //p' "$tmp/out"; tail -n +2 "$tmp/calias.ir"; } > "$tmp/calias_pasted.ir"
scripts/mrb scripts/pathb-qbe-emit.rb --no-prune "$tmp/calias_pasted.ir" > "$tmp/calias.qbe"
scripts/mrb tests/mruby/oracle/pathb-qbe-emit.rb --no-prune "$tmp/calias_pasted.ir" > "$tmp/calias-oracle.qbe"
cmp "$tmp/calias.qbe" "$tmp/calias-oracle.qbe"
"${QBE:-build/qbe/qbe}" "$tmp/calias.qbe" -o "$tmp/calias.s"
cc "$tmp/calias.s" -o "$tmp/calias"
"$tmp/calias" || { echo "FAIL $calias runtime: expected 0"; exit 1; }
echo "ok   const pointer results: shared alias summary, held-result mutant, emitter validation, and native execution"
pass=$((pass + 1))
# A local with a destructor is bracketed by exception-stack frame pushes and pops;
# the checker tracks the stack and infers the destructors' summaries. Using the
# object through a pointer after its scope is still found.
raii=tests/pathb-borrow/contracts/raii.cpp
sed 's/^  return r - 3;$/  return get(k) - 3;/' "$raii" > "$tmp/raii_late.cpp"
NFCXX_PATHB_BORROW=1 scripts/pathb-dump --ir "$raii" > "$tmp/raii.ir"
NFCXX_PATHB_BORROW=1 scripts/pathb-dump --ir "$tmp/raii_late.cpp" > "$tmp/raii_late.ir" 2>/dev/null
grep -Fq '@"__curr_eh_stack_entry" $"' "$tmp/raii.ir" || { echo "FAIL $raii: no exception-stack frame"; exit 1; }
scripts/mrb scripts/pathb-borrowck.rb --infer-summaries --infer-loan-ends "$tmp/raii.ir" > "$tmp/out"
grep -Fq 'ok: local lifetime checks passed' "$tmp/out" || { echo "FAIL $raii"; cat "$tmp/out"; exit 1; }
rc=0
scripts/mrb scripts/pathb-borrowck.rb --infer-summaries --infer-loan-ends "$tmp/raii_late.ir" > "$tmp/out" 2>&1 || rc=$?
if [ "$rc" != 1 ] || ! grep -Fq 'main: use-after-scope: g' "$tmp/out"; then
  echo "FAIL $raii using the object after its scope: expected exit 1, got $rc"; cat "$tmp/out"; exit 1
fi
scripts/mrb scripts/pathb-qbe-emit.rb "$tmp/raii.ir" > "$tmp/raii.qbe"
"${QBE:-build/qbe/qbe}" "$tmp/raii.qbe" -o "$tmp/raii.s"
# EDG's EH runtime (libC.a) defines the exception-stack globals, linked as tests/pathb-qbe/run.sh does.
edglib=${EDG_LIB:-build/edg/lib}
if [ -f "$edglib/libC.a" ]; then
  cc "$tmp/raii.s" -o "$tmp/raii" -L"$edglib" -lC -lstdc++ -lgcc_s -lpthread -lm -latomic
  "$tmp/raii" || { echo "FAIL $raii runtime: expected 0"; exit 1; }
else
  echo "skip $raii native run: no $edglib/libC.a"
fi
echo "ok   exception-stack frames around a destructor, after-scope mutant, and native execution"
pass=$((pass + 1))
# Runtime helpers for long double and __int128 are described by the trusted
# scripts/pathb-runtime.effects; without it their calls are refused. An
# uninitialized operand is found at the helper call. Every summary in the file
# validates in the emitter and oracle too.
ldsrc=tests/pathb-borrow/contracts/longdouble.cpp
effects=scripts/pathb-runtime.effects
sed 's/^  long double a = 2.0L, b = 3.0L;$/  long double a, b = 3.0L;/' "$ldsrc" > "$tmp/ld_uninit.cpp"
NFCXX_PATHB_BORROW=1 scripts/pathb-dump --ir "$ldsrc" > "$tmp/ld.ir"
NFCXX_PATHB_BORROW=1 scripts/pathb-dump --ir "$tmp/ld_uninit.cpp" > "$tmp/ld_uninit.ir" 2>/dev/null
rc=0
scripts/mrb scripts/pathb-borrowck.rb "$tmp/ld.ir" > "$tmp/out" 2>&1 || rc=$?
[ "$rc" = 3 ] || { echo "FAIL $ldsrc without --effects: expected exit 3, got $rc"; cat "$tmp/out"; exit 1; }
scripts/mrb scripts/pathb-borrowck.rb --effects "$effects" "$tmp/ld.ir" > "$tmp/out"
grep -Fq 'ok: local lifetime checks passed' "$tmp/out" || { echo "FAIL $ldsrc"; cat "$tmp/out"; exit 1; }
rc=0
scripts/mrb scripts/pathb-borrowck.rb --effects "$effects" "$tmp/ld_uninit.ir" > "$tmp/out" 2>&1 || rc=$?
if [ "$rc" != 1 ] || ! grep -q '^main: uninitialized: ' "$tmp/out"; then
  echo "FAIL $ldsrc with an uninitialized operand: expected exit 1, got $rc"; cat "$tmp/out"; exit 1
fi
# The module's own summary of a name wins over the file's.
{ head -1 "$tmp/ld.ir"
  echo '(call-effects "__nfcxx_ld_mul" (returns void) (nothrow) (noescape) (closed) (args (write (array 16 unsigned_char)) (read (array 16 unsigned_char)) (read (array 16 unsigned_char))))'
  tail -n +2 "$tmp/ld.ir"; } > "$tmp/ld_own.ir"
rc=0
scripts/mrb scripts/pathb-borrowck.rb --effects "$effects" "$tmp/ld_own.ir" > "$tmp/out" 2>&1 || rc=$?
if [ "$rc" != 1 ] || ! grep -q '^main: uninitialized: ' "$tmp/out"; then
  echo "FAIL $ldsrc: a module summary must override --effects (write needs its output initialized), got $rc"; cat "$tmp/out"; exit 1
fi
echo '(borrow-layout (struct "X") 4 4)' > "$tmp/bad.effects"
rc=0
scripts/mrb scripts/pathb-borrowck.rb --effects "$tmp/bad.effects" "$tmp/ld.ir" > "$tmp/out" 2>&1 || rc=$?
[ "$rc" = 2 ] || { echo "FAIL --effects with a non-call-effects form: expected exit 2, got $rc"; exit 1; }
{ head -1 "$tmp/ld.ir"; grep -v '^;' "$effects"; tail -n +2 "$tmp/ld.ir"; } > "$tmp/ld_effects.ir"
scripts/mrb scripts/pathb-qbe-emit.rb --no-prune "$tmp/ld_effects.ir" > "$tmp/ld.qbe"
scripts/mrb tests/mruby/oracle/pathb-qbe-emit.rb --no-prune "$tmp/ld_effects.ir" > "$tmp/ld-oracle.qbe"
cmp "$tmp/ld.qbe" "$tmp/ld-oracle.qbe"
scripts/mrb scripts/pathb-qbe-emit.rb --no-prune "$tmp/ld.ir" | cmp - "$tmp/ld.qbe"
ldrt=$(scripts/pathb-ldrt)
"${QBE:-build/qbe/qbe}" "$tmp/ld.qbe" -o "$tmp/ld.s"
cc "$tmp/ld.s" "$ldrt" -lstdc++ -lm -o "$tmp/ld"
"$tmp/ld" || { echo "FAIL $ldsrc runtime: expected 0"; exit 1; }
echo "ok   runtime helper effects, uninitialized operand, module precedence, emitter validation, and native execution"
pass=$((pass + 1))
# A lowered VLA's pointer local has declaration facts. (EDG's exception-stack
# registration around it is still refused, for its own reason.)
NFCXX_PATHB_BORROW=1 scripts/pathb-dump --ir tests/pathb-borrow/contracts/vla.cpp > "$tmp/vla.ir"
grep -Fq '(decl $"a" val)' "$tmp/vla.ir" && grep -Fq '(scope-end $"a")' "$tmp/vla.ir" ||
  { echo "FAIL vla.cpp: no facts for the VLA"; exit 1; }
rc=0
scripts/mrb scripts/pathb-borrowck.rb "$tmp/vla.ir" > "$tmp/out" 2>&1 || rc=$?
if [ "$rc" != 3 ] || grep -Fq 'missing declaration facts' "$tmp/out"; then
  echo "FAIL vla.cpp: expected a refusal other than missing facts, got $rc"; cat "$tmp/out"; exit 1
fi
echo "ok   declaration facts for lowered VLAs"
pass=$((pass + 1))
# Call-argument temporaries get (decl ... temp) facts around their full expression,
# so a recursive callee gets a summary. An uninitialized argument is still found.
temps=tests/pathb-borrow/contracts/temporaries.cpp
NFCXX_PATHB_BORROW=1 scripts/pathb-dump --ir "$temps" > "$tmp/temps.ir"
grep -Fq '(decl $"tmp" temp)' "$tmp/temps.ir" && grep -Fq '(scope-end $"tmp")' "$tmp/temps.ir" ||
  { echo "FAIL $temps: missing temporary facts"; exit 1; }
sed 's/int c = 0;/int c;/' "$temps" > "$tmp/temps_uninit.cpp"
NFCXX_PATHB_BORROW=1 scripts/pathb-dump --ir "$tmp/temps_uninit.cpp" > "$tmp/temps_uninit.ir"
for options in --infer-summaries "--infer-summaries --infer-loan-ends"; do
  scripts/mrb scripts/pathb-borrowck.rb $options "$tmp/temps.ir" > "$tmp/out"
  grep -Fq 'ok: local lifetime checks passed' "$tmp/out" || { echo "FAIL $temps ($options)"; cat "$tmp/out"; exit 1; }
  rc=0
  scripts/mrb scripts/pathb-borrowck.rb $options "$tmp/temps_uninit.ir" > "$tmp/out" 2>&1 || rc=$?
  if [ "$rc" != 1 ] || ! grep -Fq 'main: uninitialized: c' "$tmp/out"; then
    echo "FAIL $temps with an uninitialized argument ($options): expected exit 1, got $rc"
    cat "$tmp/out"
    exit 1
  fi
done
scripts/mrb scripts/pathb-qbe-emit.rb --no-prune "$tmp/temps.ir" > "$tmp/temps.qbe"
"${QBE:-build/qbe/qbe}" "$tmp/temps.qbe" -o "$tmp/temps.s"
cc "$tmp/temps.s" -o "$tmp/temps"
"$tmp/temps" || { echo "FAIL $temps runtime: expected 0"; exit 1; }
echo "ok   temporary facts for lowered C++ call arguments, mutant, and native execution"
pass=$((pass + 1))
# Checking facts and value-transfer policy must not change native execution.
# Loan erasure and replacing explicit transfers with loads must yield the same QBE.
for loan_ir in tests/mruby/pathb-edge/loan_facts.ir tests/mruby/pathb-edge/reborrow_facts.ir tests/mruby/pathb-edge/move_facts.ir tests/mruby/pathb-edge/field_move_facts.ir tests/mruby/pathb-edge/drop_state_facts.ir; do
scripts/mrb scripts/pathb-borrowck.rb "$loan_ir" > "$tmp/loan-check"
scripts/mrb scripts/pathb-borrowck.rb --infer-loan-ends "$loan_ir" > "$tmp/inferred-check"
scripts/mrb scripts/pathb-qbe-emit.rb --no-prune "$loan_ir" > "$tmp/loans.qbe"
scripts/mrb tests/mruby/oracle/pathb-qbe-emit.rb --no-prune "$loan_ir" > "$tmp/oracle.qbe"
cmp "$tmp/loans.qbe" "$tmp/oracle.qbe"
sed -E 's/\((move-value|copy-value) int (\(offset \$"s" [0-9]+\))\)/\(load int \2\)/g; s/\((move-value|copy-value) int (\$"x")\)/\(load int \2\)/g; s/\(reborrow \(ptr int\) "[^"]+" (shared|exclusive) "[^"]+" (%[0-9]+)\)/\2/g; s/\(borrow \(ptr int\) "[^"]+" (shared|exclusive) (\$"x")\)/\2/g; /\(loan-end /d; /\(drop-(obligation|live|state|state-if-live) /d' "$loan_ir" > "$tmp/plain.ir"
scripts/mrb scripts/pathb-qbe-emit.rb --no-prune "$tmp/plain.ir" > "$tmp/plain.qbe"
cmp "$tmp/loans.qbe" "$tmp/plain.qbe"
"${QBE:-build/qbe/qbe}" "$tmp/loans.qbe" -o "$tmp/loans.s"
cc "$tmp/loans.s" -o "$tmp/loans"
rc=0
"$tmp/loans" || rc=$?
[ "$rc" = 7 ] || { echo "FAIL loan runtime: expected 7, got $rc"; exit 1; }
echo "ok   $loan_ir metadata erasure, emitter oracle, and native execution"
pass=$((pass + 1))
done
# Semantic layouts change initialization proof, never generated code. Without
# the contract, the same whole-object borrow must retain conservative padding checks.
semantic_ir=tests/mruby/pathb-edge/semantic_layout_facts.ir
for mode in explicit inferred; do
  options=()
  [ "$mode" = explicit ] || options=(--infer-loan-ends)
  scripts/mrb scripts/pathb-borrowck.rb "${options[@]}" "$semantic_ir" > "$tmp/semantic-check"
done
scripts/mrb scripts/pathb-qbe-emit.rb --no-prune "$semantic_ir" > "$tmp/semantic.qbe"
scripts/mrb tests/mruby/oracle/pathb-qbe-emit.rb --no-prune "$semantic_ir" > "$tmp/semantic-oracle.qbe"
cmp "$tmp/semantic.qbe" "$tmp/semantic-oracle.qbe"
sed '/^(borrow-layout /d' "$semantic_ir" > "$tmp/unannotated.ir"
rc=0
scripts/mrb scripts/pathb-borrowck.rb "$tmp/unannotated.ir" > "$tmp/unannotated-check" 2>&1 || rc=$?
if [ "$rc" != 1 ] || ! grep -Fq 'uninitialized: s' "$tmp/unannotated-check"; then
  echo "FAIL semantic layout fallback: expected conservative padding error, got $rc"
  cat "$tmp/unannotated-check"
  exit 1
fi
scripts/mrb scripts/pathb-qbe-emit.rb --no-prune "$tmp/unannotated.ir" > "$tmp/unannotated.qbe"
cmp "$tmp/semantic.qbe" "$tmp/unannotated.qbe"
"${QBE:-build/qbe/qbe}" "$tmp/semantic.qbe" -o "$tmp/semantic.s"
cc "$tmp/semantic.s" -o "$tmp/semantic"
rc=0
"$tmp/semantic" || rc=$?
[ "$rc" = 7 ] || { echo "FAIL semantic layout runtime: expected 7, got $rc"; exit 1; }
echo "ok   semantic layout padding proof, metadata erasure, oracle, and native execution"
pass=$((pass + 1))
# Contract metadata must not replace or erase actual calls. Link audited C
# helpers and validate their observed scalar results in both checker modes.
call_ir=tests/mruby/pathb-edge/call_effects_facts.ir
for mode in explicit inferred; do
  options=()
  [ "$mode" = explicit ] || options=(--infer-loan-ends)
  scripts/mrb scripts/pathb-borrowck.rb "${options[@]}" "$call_ir" > "$tmp/call-check"
done
scripts/mrb scripts/pathb-qbe-emit.rb --no-prune "$call_ir" > "$tmp/calls.qbe"
scripts/mrb tests/mruby/oracle/pathb-qbe-emit.rb --no-prune "$call_ir" > "$tmp/call-oracle.qbe"
cmp "$tmp/calls.qbe" "$tmp/call-oracle.qbe"
sed '/^(call-effects /d' "$call_ir" > "$tmp/uncontracted.ir"
rc=0
scripts/mrb scripts/pathb-borrowck.rb "$tmp/uncontracted.ir" > "$tmp/uncontracted-check" 2>&1 || rc=$?
if [ "$rc" != 3 ] || ! grep -Fq 'calls require lifetime/effect contracts' "$tmp/uncontracted-check"; then
  echo "FAIL uncontracted call: expected refusal, got $rc"
  cat "$tmp/uncontracted-check"
  exit 1
fi
scripts/mrb scripts/pathb-qbe-emit.rb --no-prune "$tmp/uncontracted.ir" > "$tmp/uncontracted.qbe"
cmp "$tmp/calls.qbe" "$tmp/uncontracted.qbe"
"${QBE:-build/qbe/qbe}" "$tmp/calls.qbe" -o "$tmp/calls.s"
cc "$tmp/calls.s" tests/pathb-borrow/native/call_effects.c -o "$tmp/calls"
rc=0
"$tmp/calls" || rc=$?
[ "$rc" = 7 ] || { echo "FAIL contracted native calls: expected 7, got $rc"; exit 1; }
echo "ok   actual contracted calls, metadata erasure, oracle, and native execution"
pass=$((pass + 1))
# A returned alias is an actual pointer result; loan metadata erases to an
# ordinary call with byte-identical QBE and an observable write through it.
returned_ir=tests/mruby/pathb-edge/returned_loan_facts.ir
for mode in explicit inferred; do
  options=()
  [ "$mode" = explicit ] || options=(--infer-loan-ends)
  scripts/mrb scripts/pathb-borrowck.rb "${options[@]}" "$returned_ir" > "$tmp/returned-check"
done
scripts/mrb scripts/pathb-qbe-emit.rb --no-prune "$returned_ir" > "$tmp/returned.qbe"
scripts/mrb tests/mruby/oracle/pathb-qbe-emit.rb --no-prune "$returned_ir" > "$tmp/returned-oracle.qbe"
cmp "$tmp/returned.qbe" "$tmp/returned-oracle.qbe"
sed -e '/^(call-effects /d' -e 's/(call-borrow (ptr int) "R" root /(call (ptr int) /' "$returned_ir" > "$tmp/returned-plain.ir"
scripts/mrb scripts/pathb-qbe-emit.rb --no-prune "$tmp/returned-plain.ir" > "$tmp/returned-plain.qbe"
cmp "$tmp/returned.qbe" "$tmp/returned-plain.qbe"
"${QBE:-build/qbe/qbe}" "$tmp/returned.qbe" -o "$tmp/returned.s"
cc "$tmp/returned.s" tests/pathb-borrow/native/call_effects.c -o "$tmp/returned"
rc=0
"$tmp/returned" || rc=$?
[ "$rc" = 7 ] || { echo "FAIL returned alias runtime: expected 7, got $rc"; exit 1; }
echo "ok   returned alias calls, metadata erasure, oracle, and native execution"
pass=$((pass + 1))
# Verified callees and their caller in one module run natively.
verified_ir=tests/mruby/pathb-edge/verified_callee_facts.ir
for mode in explicit inferred; do
  options=()
  [ "$mode" = explicit ] || options=(--infer-loan-ends)
  scripts/mrb scripts/pathb-borrowck.rb "${options[@]}" "$verified_ir" > "$tmp/verified-check"
done
scripts/mrb scripts/pathb-qbe-emit.rb --no-prune "$verified_ir" > "$tmp/verified.qbe"
scripts/mrb tests/mruby/oracle/pathb-qbe-emit.rb --no-prune "$verified_ir" > "$tmp/verified-oracle.qbe"
cmp "$tmp/verified.qbe" "$tmp/verified-oracle.qbe"
"${QBE:-build/qbe/qbe}" "$tmp/verified.qbe" -o "$tmp/verified.s"
cc "$tmp/verified.s" -o "$tmp/verified"
rc=0
"$tmp/verified" || rc=$?
[ "$rc" = 7 ] || { echo "FAIL verified callees runtime: expected 7, got $rc"; exit 1; }
echo "ok   verified callee bodies, caller, oracle, and native execution"
pass=$((pass + 1))
echo "pass $pass fail 0"
