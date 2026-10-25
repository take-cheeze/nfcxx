#!/usr/bin/env bash
# The IA-64 C++ calling convention across compilers (abi.h): a class that is trivial for the purposes of calls is
# passed and returned in registers, any other one through a hidden pointer, and nfcxx must decide as g++ does.
# C++20 classes with conditionally trivial copy and move constructors (P0848: libstdc++'s std::optional<T>), a class
# containing one, and a move-only class with a trivial move constructor. Each direction: a g++ library called by the
# nfcxx program, and an nfcxx library called by the g++ program; the output must be the all-g++ build's.
#   NFCXX_BACKEND=qbe|gcc   (default: both)
cd "$(dirname "$0")/../.."
d=tests/call-abi
backends=${NFCXX_BACKEND:-"qbe gcc"}
fail=0; tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/gxx"
g++ -std=c++20 -shared -fPIC $d/lib.cpp -o "$tmp/gxx/libabi.so" &&
  g++ -std=c++20 $d/main.cpp -L"$tmp/gxx" -labi -Wl,-rpath,"$tmp/gxx" -o "$tmp/ref" || { echo "FAIL g++ reference build"; exit 1; }
ref=$("$tmp/ref")
for be in $backends; do
  # g++ library, nfcxx caller.
  if out=$(NFCXX_BACKEND=$be ./nfcxx -std=c++20 $d/main.cpp -L"$tmp/gxx" -labi -Wl,-rpath,"$tmp/gxx" -o "$tmp/caller-$be" 2>&1); then
    got=$("$tmp/caller-$be" 2>&1)
    [ "$got" = "$ref" ] && echo "ok    $be: nfcxx caller, g++ library" ||
      { echo "FAIL  $be: nfcxx caller, g++ library"; diff <(echo "$ref") <(echo "$got") | head -20; fail=1; }
  else echo "FAIL  $be: nfcxx caller (build)"; grep -i error <<<"$out" | head -5; fail=1; fi
  # nfcxx library, g++ caller.
  mkdir -p "$tmp/$be"
  if out=$(NFCXX_BACKEND=$be ./nfcxx -std=c++20 -shared -fPIC $d/lib.cpp -o "$tmp/$be/libabi.so" 2>&1) &&
     out=$(g++ -std=c++20 $d/main.cpp -L"$tmp/$be" -labi -Wl,-rpath,"$tmp/$be" -o "$tmp/callee-$be" 2>&1); then
    got=$("$tmp/callee-$be" 2>&1)
    [ "$got" = "$ref" ] && echo "ok    $be: g++ caller, nfcxx library" ||
      { echo "FAIL  $be: g++ caller, nfcxx library"; diff <(echo "$ref") <(echo "$got") | head -20; fail=1; }
  else echo "FAIL  $be: nfcxx library (build)"; grep -i error <<<"$out" | head -5; fail=1; fi
done
exit $fail
