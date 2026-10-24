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
# Loans carry checking facts only. Erasing those facts must yield exactly the
# same QBE, and the generated native program must still return its written value.
loan_ir=tests/mruby/pathb-edge/loan_facts.ir
scripts/mrb scripts/pathb-borrowck.rb "$loan_ir" > "$tmp/loan-check"
scripts/mrb scripts/pathb-qbe-emit.rb --no-prune "$loan_ir" > "$tmp/loans.qbe"
scripts/mrb tests/mruby/oracle/pathb-qbe-emit.rb --no-prune "$loan_ir" > "$tmp/oracle.qbe"
cmp "$tmp/loans.qbe" "$tmp/oracle.qbe"
sed -E 's/\(borrow \(ptr int\) "[^"]+" (shared|exclusive) (\$"x")\)/\2/g; /\(loan-end /d' "$loan_ir" > "$tmp/plain.ir"
scripts/mrb scripts/pathb-qbe-emit.rb --no-prune "$tmp/plain.ir" > "$tmp/plain.qbe"
cmp "$tmp/loans.qbe" "$tmp/plain.qbe"
"${QBE:-build/qbe/qbe}" "$tmp/loans.qbe" -o "$tmp/loans.s"
cc "$tmp/loans.s" -o "$tmp/loans"
rc=0
"$tmp/loans" || rc=$?
[ "$rc" = 7 ] || { echo "FAIL loan runtime: expected 7, got $rc"; exit 1; }
echo "ok   loan metadata erasure, emitter oracle, and native execution"
pass=$((pass + 1))
echo "pass $pass fail 0"
