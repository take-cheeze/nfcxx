#!/usr/bin/env bash
# Path B profiler hooks (docs/notes/profiler.md, "Path B"): scripts/pathb-cc.rb --profile calls the runtime's enter and exit
# hooks (__nfcxx_prof_enter_addr / __nfcxx_prof_exit_addr, lib/prof/nfcxx_prof_cyg.c) at each function's entry and before
# each return. The test compiles tests/prof/cprog.c through Path B, checks the hooks are referenced only with --profile,
# links the runtime, and checks the profile: fib(10) gives 178 enter/exit pairs at 2 sites, and main is named.
# Needs the Path B harness (scripts/setup-pathb.sh) and QBE (scripts/setup-qbe.sh); built on first use otherwise.
set -eu
cd "$(dirname "$0")/../.."
out=build/pathb-prof
mkdir -p "$out"
cc=${CC:-gcc}
$cc -std=c11 -O2 -Wall -Wextra -Werror tests/prof/check_any.c -o "$out/check_any"
ruby scripts/pathb-cc.rb --profile tests/prof/cprog.c -o "$out/cprog.o"
ruby scripts/pathb-cc.rb tests/prof/cprog.c -o "$out/plain.o"
nm "$out/cprog.o" | grep -q "__nfcxx_prof_enter_addr"
nm "$out/cprog.o" | grep -q "__nfcxx_prof_exit_addr"
if nm "$out/plain.o" | grep -q "__nfcxx_prof_"; then echo "FAIL: a build without --profile calls the hooks" >&2; exit 1; fi
$cc -std=c11 -O2 -pthread -rdynamic -Ilib/prof "$out/cprog.o" lib/prof/nfcxx_prof.c lib/prof/nfcxx_prof_cyg.c \
  lib/prof/nfcxx_machine.c lib/prof/nfcxx_alloc.c -lm \
  -Wl,--wrap=malloc,--wrap=calloc,--wrap=realloc,--wrap=free -o "$out/cprog"
rm -f "$out/cprog.prof"
NFCXX_PROFILE="$PWD/$out/cprog.prof" "$out/cprog" | grep -q "^55$"
"$out/check_any" "$out/cprog.prof" main | grep -q "sites=2 pairs=178 threads=1"
echo "PASS tests/pathb-prof"
