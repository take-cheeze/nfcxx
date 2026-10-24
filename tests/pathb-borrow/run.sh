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
echo "pass $pass fail 0"
