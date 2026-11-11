#!/usr/bin/env bash
# Native check of pdiff, a function used as a value, and a call through a function pointer (scripts/pathb-ssa-qbe.rb).
# The interpreter does not model these, so the expected values are the hand-computed ones: with f(x) = x + 1 and
# s = (n) + f(n) + 1000 * (-n), the result is 1 - 998 * n.
set -eu
cd "$(dirname "$0")/../../.."
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
ruby scripts/pathb-ssa-build -o "$tmp/ptr.s" tests/pathb-ssa-qbe/pointers/ptr.ir
cc tests/pathb-ssa-qbe/pointers/drv.c "$tmp/ptr.s" -o "$tmp/prog"
got=$("$tmp/prog" | tr '\n' ' ')
want="1 -997 -1995 2995 "
if [ "$got" = "$want" ]; then
  echo "ok   pointers: $got"
else
  echo "FAIL pointers: got '$got', want '$want'"
  exit 1
fi
