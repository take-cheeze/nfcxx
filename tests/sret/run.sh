#!/usr/bin/env bash
# Class-returning library functions (scripts/sret.sh): std::filesystem::path results, hosted, both backends.
#   NFCXX_BACKEND=qbe|gcc   (default: both)
cd "$(dirname "$0")/../.."
backends=${NFCXX_BACKEND:-"qbe gcc"}
fail=0; tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
for be in $backends; do
  if NFCXX_BACKEND=$be ./nfcxx tests/sret/class_return.cpp -o "$tmp/t" 2>"$tmp/err" && "$tmp/t" >"$tmp/out" 2>&1; then
    echo "ok    $be class_return"
  else
    echo "FAIL  $be class_return"; cat "$tmp/err" "$tmp/out" 2>/dev/null | head -5; fail=1
  fi
done
exit $fail
