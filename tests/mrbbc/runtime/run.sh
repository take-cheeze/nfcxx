#!/usr/bin/env bash
# The runtime's own tests (tests/mrbbc/runtime): gc_test.c checks the collector of mrbrt.c under mrbbc_run. The test sets its
# own thresholds, so the two runs here differ only before its body starts; MRBBC_GC_THRESHOLD=1 over the whole programs is
# what tests/mrbbc/lower/run.sh exercises.
#
#   tests/mrbbc/runtime/run.sh
set -u
root=$(cd "$(dirname "$0")/../../.." && pwd)
rt=$root/tests/mrbbc/runtime
work=${TMPDIR:-/tmp}/mrbbc-runtime.$$
mkdir -p "$work"
trap 'rm -rf "$work"' EXIT

cc -std=c99 -Wall -Wextra -Werror -c -o "$work/mrbrt.o" "$rt/mrbrt.c" || exit 1
cc -std=c99 -Wall -Wextra -Werror -o "$work/gc_test" "$rt/gc_test.c" "$work/mrbrt.o" || exit 1

fail=0
for th in "" 1; do
  label=${th:-default}
  if ! got=$(MRBBC_GC_THRESHOLD=$th "$work/gc_test" 2>&1); then
    echo "FAIL gc_test (threshold $label): $got"
    fail=1
    continue
  fi
  echo "gc_test (threshold $label): $got"
done

if [ "$fail" -ne 0 ]; then
  echo "mrbbc-runtime: FAILED"
  exit 1
fi
echo "mrbbc-runtime: gc_test passes with the automatic threshold and with MRBBC_GC_THRESHOLD=1"
