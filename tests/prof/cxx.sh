#!/usr/bin/env bash
# Tests `nfcxx --profile` on a C++ input (docs/notes/profiler.md, "C++ inputs"): tests/prof/cxxprog.cpp is built by the
# driver's C++ route (EDG front end, then the gcc compile of the C it emits), run with NFCXX_PROFILE set, and its profile is
# checked with tests/prof/check_any.c.
#
# The program has three sites: main, the recursive free function fib (fib(10) makes 177 calls) and Counter::twice (one
# call). So the profile has 179 enter/exit pairs at 3 sites, on one thread, and main, fib and twice are named. The names
# are the symbols as dladdr gives them (the program's functions are global, and --profile passes -rdynamic): main, _Z3fibi
# and _ZNK7Counter5twiceEi. A static function has no exported symbol, so its name is +0x<offset> in the string table
# (docs/notes/profiler.md); this program has none, so the test does not check for one.
#
# The pair count also shows the runtime (lib/prof) is not instrumented: its calls would add pairs.
#
# This is separate from tests/prof/run.sh (the C program), and runs on its own: bash tests/prof/cxx.sh
set -eu
cd "$(dirname "$0")/../.."
out=build/prof
mkdir -p "$out"
cc=${CC:-gcc}
$cc -std=c11 -O2 -Wall -Wextra -Werror tests/prof/check_any.c -o "$out/check_any"

./nfcxx --profile tests/prof/cxxprog.cpp -o "$out/cxxprog" > "$out/cxxprog.build.log" 2>&1

# without the variable the program prints its result and writes no profile
rm -f "$out/cxx.noenv.prof"
env -u NFCXX_PROFILE "$out/cxxprog" | grep -q "^110$"
test ! -e "$out/cxx.noenv.prof"

rm -f "$out/cxx.prof"
NFCXX_PROFILE="$PWD/$out/cxx.prof" "$out/cxxprog" | grep -q "^110$"
"$out/check_any" "$out/cxx.prof" | grep -q "sites=3 pairs=179 threads=1"
"$out/check_any" "$out/cxx.prof" main > /dev/null # the global main is named in the string table
"$out/check_any" "$out/cxx.prof" _Z3fibi > /dev/null # fib, by its mangled name
"$out/check_any" "$out/cxx.prof" _ZNK7Counter5twiceEi > /dev/null # Counter::twice, by its mangled name
echo "PASS tests/prof/cxx.sh"
