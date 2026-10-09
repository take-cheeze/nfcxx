#!/usr/bin/env bash
# Path B stage 1 regression: dump the lowered IL of each tests/cases/*.cpp with scripts/pathb-dump and diff it
# against the golden in tests/pathb/<name>.il. Run `tests/pathb/run.sh --update` to rewrite the goldens after an
# intended change. Needs the harness: scripts/setup-pathb.sh (built on first use if missing).
cd "$(dirname "$0")/../.."
update=0; [ "${1:-}" = --update ] && update=1
[ -x build/pathb/cmake/bin/cpfe ] || scripts/setup-pathb.sh >/dev/null
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fail=0; gaps=0
for f in tests/cases/*.cpp; do
  n=$(basename "$f" .cpp)
  if ! scripts/pathb-dump "$f" > "$tmp/$n.il" 2> "$tmp/$n.err"; then
    echo "FAIL (front end) $f"; head -5 "$tmp/$n.err"; fail=1; continue
  fi
  g=$(grep -c '(unsupported' "$tmp/$n.il" || true); gaps=$((gaps + g))
  if [ $update = 1 ]; then cp "$tmp/$n.il" "tests/pathb/$n.il"; echo "wrote tests/pathb/$n.il"; continue; fi
  if diff -u "tests/pathb/$n.il" "$tmp/$n.il" > "$tmp/$n.diff"; then
    echo "ok   $f"
  else
    echo "DIFF $f"; head -40 "$tmp/$n.diff"; fail=1
  fi
done
echo "unsupported IL nodes across tests/cases: $gaps"
exit $fail
