#!/usr/bin/env bash
# Tests `nfcxx --profile` through the Path B route (docs/notes/profiler.md, "Path B"): the default backend on x86-64 Linux
# plans the hooks (pathb-cc.rb --profile), the profiler runtime (lib/prof, compiled as C without the hooks) and the link
# (-rdynamic, the allocation wraps), with no fallback to the gcc backend. A C program (tests/prof/cprog.c: fib(10) makes
# 177 calls, so 178 enter/exit pairs at 2 sites, and main is named) and a C++ program (tests/prof/cxxprog.cpp: 179 pairs at 3
# sites) are built, run with NFCXX_PROFILE set, and checked with tests/prof/check_any.c. Without the variable the program
# prints its result and writes no profile. Run it on its own: bash tests/prof/pathb.sh
set -eu
cd "$(dirname "$0")/../.."
out=build/prof
mkdir -p "$out"
cc=${CC:-gcc}
$cc -std=c11 -O2 -Wall -Wextra -Werror tests/prof/check_any.c -o "$out/check_any"

# C: the driver's route is Path B (the trace names the plan, and no gcc fallback message)
NFCXX_DRIVER_TRACE=1 ./nfcxx --profile tests/prof/cprog.c -o "$out/pb_cprog" > "$out/pb_cprog.build.log" 2>&1
grep -q "nfcxx: driver: pathb-plan" "$out/pb_cprog.build.log"
if grep -q "building the program with the gcc backend" "$out/pb_cprog.build.log"; then
  echo "FAIL: the C program fell back to the gcc backend" >&2
  exit 1
fi
env -u NFCXX_PROFILE "$out/pb_cprog" | grep -q "^55$"
test ! -e "$out/pb_cprog.noenv.prof"
rm -f "$out/pb_cprog.prof"
NFCXX_PROFILE="$PWD/$out/pb_cprog.prof" "$out/pb_cprog" | grep -q "^55$"
"$out/check_any" "$out/pb_cprog.prof" | grep -q "sites=2 pairs=178 threads=1"
"$out/check_any" "$out/pb_cprog.prof" main > /dev/null # the global main is named in the string table
echo "C ok: tests/prof/cprog.c through Path B"

# C++: the same route, the program's own functions (main, fib, Counter::twice) named by their symbols
NFCXX_DRIVER_TRACE=1 ./nfcxx --profile tests/prof/cxxprog.cpp -o "$out/pb_cxxprog" > "$out/pb_cxxprog.build.log" 2>&1
grep -q "nfcxx: driver: pathb-plan" "$out/pb_cxxprog.build.log"
if grep -q "building the program with the gcc backend" "$out/pb_cxxprog.build.log"; then
  echo "FAIL: the C++ program fell back to the gcc backend" >&2
  exit 1
fi
env -u NFCXX_PROFILE "$out/pb_cxxprog" | grep -q "^110$"
test ! -e "$out/pb_cxx.noenv.prof"
rm -f "$out/pb_cxx.prof"
NFCXX_PROFILE="$PWD/$out/pb_cxx.prof" "$out/pb_cxxprog" | grep -q "^110$"
"$out/check_any" "$out/pb_cxx.prof" | grep -q "sites=3 pairs=179 threads=1"
"$out/check_any" "$out/pb_cxx.prof" main > /dev/null
"$out/check_any" "$out/pb_cxx.prof" _Z3fibi > /dev/null
"$out/check_any" "$out/pb_cxx.prof" _ZNK7Counter5twiceEi > /dev/null
echo "C++ ok: tests/prof/cxxprog.cpp through Path B"

# a build without --profile calls no hook and writes no profile
ruby scripts/pathb-cc.rb tests/prof/cprog.c -o "$out/pb_plain.o" 2>/dev/null
if nm "$out/pb_plain.o" | grep -q "__nfcxx_prof_"; then echo "FAIL: a build without --profile calls the hooks" >&2; exit 1; fi
echo "PASS tests/prof/pathb.sh"
