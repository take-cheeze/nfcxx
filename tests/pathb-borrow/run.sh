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
for src in tests/pathb-borrow/moves/*.ir tests/pathb-borrow/fields/*.ir tests/pathb-borrow/layouts/*.ir tests/pathb-borrow/drops/*.ir; do
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
echo "pass $pass fail 0"
