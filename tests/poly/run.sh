#!/usr/bin/env bash
# nfcpoly: build the host test (tests/poly/host.cpp with lib/poly/nfcpoly.cpp and the C++-exception libmruby that
# scripts/setup-poly.sh builds per back end) with nfcxx and run it. See docs/notes/poly.md.
#   NFCXX_BACKEND=gcc|qbe   (default: both)
cd "$(dirname "$0")/../.."
backends=${NFCXX_BACKEND:-"qbe gcc"}
fail=0; tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
for be in $backends; do
  if ! out=$(NFCXX_BACKEND=$be scripts/setup-poly.sh 2>&1); then
    echo "FAIL $be poly (mruby build)"; tail -20 <<<"$out"; fail=1; continue
  fi
  if ! out=$(NFCXX_BACKEND=$be ./nfcxx -I lib/poly -I build/poly/$be/include tests/poly/host.cpp lib/poly/nfcpoly.cpp \
               lib/poly/nfcpoly_mruby.cpp build/poly/$be/lib/libmruby.a -o "$tmp/host-$be" 2>&1); then
    echo "FAIL $be poly (host build)"; grep -v 'prelinker' <<<"$out" | head -30; fail=1; continue
  fi
  if out=$("$tmp/host-$be" 2>&1); then
    echo "ok   $be poly: $(tail -1 <<<"$out")"
  else
    echo "FAIL $be poly"; head -40 <<<"$out"; fail=1
  fi
done
exit $fail
