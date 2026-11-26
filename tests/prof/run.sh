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
echo "PASS tests/prof"
