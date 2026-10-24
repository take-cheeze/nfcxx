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
for src in tests/pathb-borrow/moves/*.ir tests/pathb-borrow/fields/*.ir tests/pathb-borrow/layouts/*.ir tests/pathb-borrow/drops/*.ir tests/pathb-borrow/calls/*.ir tests/pathb-borrow/returned/*.ir tests/pathb-borrow/verify/*.ir; do
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
layouts=tests/pathb-borrow/contracts/inferred.layouts
NFCXX_PATHB_BORROW=1 scripts/pathb-dump --ir tests/pathb-borrow/contracts/inferred.cpp > "$tmp/inferred0.ir"
sed '/^  init_pair(&s, 2);$/d' tests/pathb-borrow/contracts/inferred.cpp > "$tmp/uninit.cpp"
NFCXX_PATHB_BORROW=1 scripts/pathb-dump --ir "$tmp/uninit.cpp" > "$tmp/uninit0.ir" 2>/dev/null
for name in inferred0 uninit0; do
  { head -1 "$tmp/$name.ir"; cat "$layouts"; tail -n +2 "$tmp/$name.ir"; } > "$tmp/$name.layout.ir"
done
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
