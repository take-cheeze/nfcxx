#!/usr/bin/env bash
# Tests the profiler runtime (lib/prof, docs/notes/profiler.md): the profile is written only when NFCXX_PROFILE names a
# file, and the file has the expected records from one thread and from two worker threads.
set -eu
cd "$(dirname "$0")/../.."
out=build/prof
mkdir -p "$out"
cc=${CC:-gcc}
$cc -std=c11 -O2 -Wall -Wextra -Werror -pthread -Ilib/prof lib/prof/nfcxx_prof.c tests/prof/basic.c -o "$out/basic"
$cc -std=c11 -O2 -Wall -Wextra -Werror tests/prof/check.c -o "$out/check"

rm -f "$out/unset.prof"
env -u NFCXX_PROFILE "$out/basic" | tee "$out/unset.log" | grep -q "enabled=0"
test ! -e "$out/unset.prof"

rm -f "$out/on.prof"
NFCXX_PROFILE="$PWD/$out/on.prof" "$out/basic" | tee "$out/on.log" | grep -q "enabled=1"
"$out/check" "$out/on.prof"

# --profile through the driver (gcc backend, -finstrument-functions): fib(10) makes 177 calls, and main is one more
$cc -std=c11 -O2 -Wall -Wextra -Werror tests/prof/check_any.c -o "$out/check_any"
./nfcxx --profile tests/prof/cprog.c -o "$out/cprog" > "$out/cprog.build.log" 2>&1
env -u NFCXX_PROFILE "$out/cprog" | grep -q "^55$"
test ! -e "$out/cprog.noenv.prof"
rm -f "$out/cprog.prof"
NFCXX_PROFILE="$PWD/$out/cprog.prof" "$out/cprog" | grep -q "^55$"
"$out/check_any" "$out/cprog.prof" | grep -q "sites=2 pairs=178 threads=1"

# --profile with Path B is refused (the IR has no profiling calls yet)
if ./nfcxx --backend=pathb --profile tests/prof/cprog.c -o "$out/cprog_pb" > "$out/pb.log" 2>&1; then
  echo "FAIL: --backend=pathb --profile was accepted" >&2
  exit 1
fi
grep -q "cannot be used with --backend=pathb" "$out/pb.log"
echo "PASS tests/prof"
