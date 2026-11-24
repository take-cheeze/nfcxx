#!/usr/bin/env bash
# Lean side of the Path B IR (lean/): build nfcxx_ir and run it over the IR goldens.
# Every golden must pass `check`; each file in lean/tests/bad must be refused.
# Needs Lean 4 with lake (elan): without it the run is skipped, not failed.
cd "$(dirname "$0")/../../lean" || exit 2
if ! command -v lake >/dev/null 2>&1; then
  echo "SKIP tests/lean: lake (Lean 4, via elan) is not installed"
  exit 0
fi
lake build nfcxx_ir || { echo "FAIL tests/lean: build"; exit 1; }
exe=.lake/build/bin/nfcxx_ir
fail=0
if ! "$exe" check ../tests/pathb-ir/*.ir > /dev/null; then
  echo "FAIL tests/lean: goldens in tests/pathb-ir"; fail=1
else
  echo "ok: $(ls ../tests/pathb-ir/*.ir | wc -l) goldens parse and round-trip"
if ! "$exe" roundtrip ../tests/pathb-ir/*.ir > /dev/null; then
  echo "FAIL tests/lean: typed AST does not round-trip the goldens"; fail=1
else
  echo "ok: $(ls ../tests/pathb-ir/*.ir | wc -l) goldens decode to the typed AST and print back unchanged"
fi
fi
for f in tests/bad/*.ir; do
  if "$exe" check "$f" 2>/dev/null; then echo "FAIL tests/lean: $f was accepted"; fail=1; fi
done
echo "ok: $(ls tests/bad/*.ir | wc -l) malformed inputs refused"
exit $fail
