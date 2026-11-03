#!/usr/bin/env bash
# Native check of a call through a function pointer under --safe (scripts/pathb-ssa-qbe.rb's __nfcxx_sp_call): a
# pointer to the function runs as in the default build; a pointer to a stack slot is not a function and aborts.
set -eu
cd "$(dirname "$0")/../../.."
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
ruby scripts/pathb-ssa-build --safe -o "$tmp/bad.s" tests/pathb-ssa-qbe/safe_call/bad.ir
cc tests/pathb-ssa-qbe/safe_call/drv.c "$tmp/bad.s" $(cat "$tmp/bad.s.link") -o "$tmp/prog"
good=$("$tmp/prog" 0)
if [ "$good" != "6" ]; then
  echo "FAIL safe_call: valid pointer gave '$good', want 6"
  exit 1
fi
if "$tmp/prog" 1 >/dev/null 2>&1; then
  echo "FAIL safe_call: a pointer to a stack slot was called without an abort"
  exit 1
fi
echo "ok   safe_call: valid pointer runs (6), a stack-slot pointer aborts"
