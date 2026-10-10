#!/usr/bin/env bash
# Path B stage 1 regression: a FROZEN set. For each existing golden tests/pathb/<name>.il, dump the lowered IL of
# tests/cases/<name>.cpp with scripts/pathb-dump and diff it against the golden. New cases are not added here: the
# stage 1 printer cannot print every node of hosted-header code (constexpr_if, if_consteval, ...). Cover new cases
# with tests/pathb-ir (stage 2), which runs every tests/cases/*.cpp. `tests/pathb/run.sh --update` rewrites only the
# existing goldens, after an intended change. Needs the harness: scripts/setup-pathb.sh (built on first use if missing).
cd "$(dirname "$0")/../.."
update=0; [ "${1:-}" = --update ] && update=1
[ -n "${PATHB_CPFE:-}" ] || [ -x build/pathb/cmake/bin/cpfe ] || scripts/setup-pathb.sh >/dev/null
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fail=0; gaps=0
for g0 in tests/pathb/*.il; do
  n=$(basename "$g0" .il); f=tests/cases/$n.cpp
  [ -f "$f" ] || { echo "FAIL golden $g0 has no $f"; fail=1; continue; }
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
echo "unsupported IL nodes across the stage 1 set: $gaps"
exit $fail
