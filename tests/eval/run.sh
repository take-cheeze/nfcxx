#!/usr/bin/env bash
# nfceval: build the host test (tests/eval/host.cpp, which includes lib/eval/nfceval.cpp) with nfcxx and run it. The host
# compiles snippets with nfcxx at run time (NFCXX is left unset, so it finds ./nfcxx itself), on the same
# backend as the host. See docs/notes/eval.md.
#   NFCXX_BACKEND=gcc|qbe   (default: both)
cd "$(dirname "$0")/../.."
root=$PWD
backends=${NFCXX_BACKEND:-"qbe gcc"}
fail=0; tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
unset NFCXX
for be in $backends; do
  # driver: -shared builds a shared object from .c and .cpp inputs (the library builds on this)
  if out=$(NFCXX_BACKEND=$be ./nfcxx -shared tests/eval/probe.c -o "$tmp/probe-c-$be.so" 2>&1 &&
           NFCXX_BACKEND=$be ./nfcxx -shared tests/eval/probe.cpp -o "$tmp/probe-cpp-$be.so" 2>&1 &&
           NFCXX_BACKEND=$be ./nfcxx tests/eval/probe_main.cpp -o "$tmp/probe-main-$be" 2>&1) &&
     "$tmp/probe-main-$be" "$tmp/probe-c-$be.so" "$tmp/probe-cpp-$be.so"; then
    echo "ok   $be nfcxx -shared (C and C++)"
  else
    echo "FAIL $be nfcxx -shared"; head -10 <<<"$out"; fail=1
  fi
  if ! out=$(NFCXX_BACKEND=$be ./nfcxx -I lib/eval -rdynamic tests/eval/host.cpp -o "$tmp/host-$be" 2>&1); then
    echo "FAIL $be eval (host build)"; head -10 <<<"$out"; fail=1; continue
  fi
  if out=$(NFCXX_BACKEND=$be NFCEVAL_CACHE="$tmp/cache-$be" "$tmp/host-$be" "$root/tests/eval" 2>&1); then
    echo "ok   $be eval: $(tail -1 <<<"$out")"
  else
    echo "FAIL $be eval"; head -30 <<<"$out"; fail=1
  fi
  rm -f "$tmp/host-$be"
done
exit $fail
