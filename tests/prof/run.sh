#!/usr/bin/env bash
# Tests the profiler runtime (lib/prof, docs/notes/profiler.md): the profile is written only when NFCXX_PROFILE names a
# file, and the file has the expected records from one thread and from two worker threads.
set -eu
cd "$(dirname "$0")/../.."
out=build/prof
mkdir -p "$out"
cc=${CC:-gcc}
$cc -std=c11 -O2 -Wall -Wextra -Werror -pthread -Ilib/prof lib/prof/nfcxx_prof.c lib/prof/nfcxx_machine.c tests/prof/basic.c -lm -o "$out/basic"
$cc -std=c11 -O2 -Wall -Wextra -Werror tests/prof/check.c -o "$out/check"

rm -f "$out/unset.prof"
env -u NFCXX_PROFILE "$out/basic" | tee "$out/unset.log" | grep -q "enabled=0"
test ! -e "$out/unset.prof"

rm -f "$out/on.prof"
NFCXX_PROFILE="$PWD/$out/on.prof" "$out/basic" | tee "$out/on.log" | grep -q "enabled=1"
"$out/check" "$out/on.prof"

# --profile through the driver, gcc backend (-finstrument-functions): fib(10) makes 177 calls, and main is one more.
# The default route is Path B (tests/prof/pathb.sh).
$cc -std=c11 -O2 -Wall -Wextra -Werror tests/prof/check_any.c -o "$out/check_any"
./nfcxx --backend=gcc --profile tests/prof/cprog.c -o "$out/cprog" > "$out/cprog.build.log" 2>&1
env -u NFCXX_PROFILE "$out/cprog" | grep -q "^55$"
test ! -e "$out/cprog.noenv.prof"
rm -f "$out/cprog.prof"
NFCXX_PROFILE="$PWD/$out/cprog.prof" "$out/cprog" | grep -q "^55$"
"$out/check_any" "$out/cprog.prof" | grep -q "sites=2 pairs=178 threads=1"
"$out/check_any" "$out/cprog.prof" main >/dev/null # the global function is named in the string table
grep -a -q -E "clock=(tsc|monotonic)" "$out/cprog.prof" # the counters chunk names the clock

# --profile with --backend=pathb is the Path B route too (the hooks, tests/prof/pathb.sh): the same profile
./nfcxx --backend=pathb --profile tests/prof/cprog.c -o "$out/cprog_pb" > "$out/pb.log" 2>&1
rm -f "$out/cprog_pb.prof"
NFCXX_PROFILE="$PWD/$out/cprog_pb.prof" "$out/cprog_pb" | grep -q "^55$"
"$out/check_any" "$out/cprog_pb.prof" | grep -q "sites=2 pairs=178 threads=1"
echo "PASS tests/prof"
