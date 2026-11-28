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

cc -std=c99 -Wall -Wextra -Werror -DMRBBC_VALUE="${MRBBC_VALUE:-8}" -c -o "$work/mrbrt.o" "$rt/mrbrt.c" || exit 1
cc -std=c99 -Wall -Wextra -Werror -DMRBBC_VALUE="${MRBBC_VALUE:-8}" -o "$work/gc_test" "$rt/gc_test.c" "$work/mrbrt.o" || exit 1

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

# Marshal (mrbbc_marshal_dump / mrbbc_marshal_load): the dumps of marshal_test.c's cases are CRuby's Marshal.dump bytes (the
# cases are marshal_cases.rb), and each dump loads and dumps back to the same bytes. Built with conservative GC: the cases'
# locals are roots the C stack scan finds.
if command -v ruby >/dev/null 2>&1; then
  cc -std=c99 -Wall -Wno-unused-parameter -Werror -DMRBBC_VALUE="${MRBBC_VALUE:-8}" -DMRBBC_GC_CONSERVATIVE=1 \
     -o "$work/marshal_test" "$rt/marshal_test.c" "$rt/mrbrt.c" -lm || exit 1
  ruby "$rt/marshal_cases.rb" > "$work/marshal_expected.txt" || exit 1
  if "$work/marshal_test" > "$work/marshal_got.txt" 2>&1 && diff -q "$work/marshal_expected.txt" "$work/marshal_got.txt" >/dev/null; then
    echo "marshal: $(wc -l < "$work/marshal_got.txt") cases match CRuby's Marshal.dump, and each reloads to the same bytes"
  else
    echo "FAIL marshal:"; diff "$work/marshal_expected.txt" "$work/marshal_got.txt" | head -20
    fail=1
  fi
else
  echo "marshal: skipped (ruby not found: the expected bytes come from CRuby's Marshal)"
fi

if [ "$fail" -ne 0 ]; then
  echo "mrbbc-runtime: FAILED"
  exit 1
fi
echo "mrbbc-runtime: gc_test passes with the automatic threshold and with MRBBC_GC_THRESHOLD=1"
