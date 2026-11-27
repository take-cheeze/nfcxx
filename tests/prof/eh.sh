#!/usr/bin/env bash
# Profiler and C++ exceptions, Path B (docs/notes/profiler.md, "Path B"): scripts/pathb-cc.rb --profile compiles
# tests/prof/ehprog.cpp, whose recursive descend() throws through through(), which holds an object with a destructor, and
# main catches it. An exception that leaves a profiled function runs its exit hook (__nfcxx_prof_exit_addr) on the way out,
# so the profile is balanced: check_any finds no thread inside a call and enters equal exits. The program prints
# "caught 7 destructed 1": the throw reached main and the destructor ran once. Needs the Path B harness (scripts/setup-pathb.sh)
# and QBE (scripts/setup-qbe.sh); the runtime is built here with the C compiler.
set -eu
cd "$(dirname "$0")/../.."
out=build/prof-eh
mkdir -p "$out"
cc=${CC:-gcc}
$cc -std=c11 -O2 -Wall -Wextra -Werror tests/prof/check_any.c -o "$out/check_any"
ruby scripts/pathb-cc.rb --profile tests/prof/ehprog.cpp -o "$out/ehprog.o"
ldrt=$(scripts/pathb-ldrt.rb)
# The runtime is C: compiled by the C compiler, linked by the C++ driver (which adds libstdc++ for the program).
for f in nfcxx_prof nfcxx_prof_cyg nfcxx_machine nfcxx_alloc; do
  $cc -std=gnu11 -O2 -pthread -Ilib/prof -c lib/prof/$f.c -o "$out/$f.o"
done
c++ -O1 -std=c++17 -pthread -rdynamic -Ilib/prof "$out/ehprog.o" "$out/nfcxx_prof.o" "$out/nfcxx_prof_cyg.o" \
  "$out/nfcxx_machine.o" "$out/nfcxx_alloc.o" $ldrt -lstdc++ -lgcc_s -lpthread -lm -latomic \
  -Wl,--wrap=malloc,--wrap=calloc,--wrap=realloc,--wrap=free -o "$out/ehprog" 2> "$out/link.log" ||
  { cat "$out/link.log" >&2; exit 1; }
env -u NFCXX_PROFILE "$out/ehprog" | grep -q "^caught 7 destructed 1$"
test ! -e "$out/noenv.prof"
rm -f "$out/ehprog.prof"
NFCXX_PROFILE="$PWD/$out/ehprog.prof" "$out/ehprog" | grep -q "^caught 7 destructed 1$"
"$out/check_any" "$out/ehprog.prof" _Z7descendi | grep -q "threads=1"
"$out/check_any" "$out/ehprog.prof" _Z7throughi >/dev/null
"$out/check_any" "$out/ehprog.prof" main >/dev/null
echo "PASS tests/prof/eh.sh"
