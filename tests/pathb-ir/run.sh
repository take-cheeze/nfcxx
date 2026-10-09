#!/usr/bin/env bash
# Path B stage 2 regression: lower each tests/cases/*.cpp to the mid-level IR (scripts/pathb-dump --ir) and diff
# the text against the golden tests/pathb-ir/<name>.ir. `tests/pathb-ir/run.sh --update` rewrites the goldens after
# an intended change. The run also reports coverage: how many IL node kinds were lowered and how many were not
# (NFCXX_PATHB_STATS=1 counts them in the back end). Needs a harness built by scripts/setup-pathb.sh: set
# PATHB_CPFE (and PATHB_BASE) to a scratch build, or use build/pathb.
cd "$(dirname "$0")/../.."
update=0; [ "${1:-}" = --update ] && update=1
# No automatic build: a missing harness is an error, so a worktree never rebuilds the shared build/ directory.
cpfe=${PATHB_CPFE:-build/pathb/cmake/bin/cpfe}
[ -x "$cpfe" ] || { echo "run.sh: no harness at $cpfe; set PATHB_CPFE (see docs/notes/pathb-stage2.md)" >&2; exit 2; }
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fail=0; gaps=0
# The probes of tests/pathb-qbe/cases that exercise the lowering itself (continue, bool loads, setjmp, unreachable
# code, EH thunks) have goldens here too, so a change in the IR text shows up as a diff.
probes="tests/pathb-qbe/cases/continue.cpp tests/pathb-qbe/cases/bool_load.cpp tests/pathb-qbe/cases/setjmp.cpp tests/pathb-qbe/cases/reachability.cpp tests/pathb-qbe/cases/eh_thunk.cpp"
for f in tests/cases/*.cpp $probes; do
  case $(basename "$f") in qbe_*) continue ;; esac   # production-path only (system headers, GNU forms): outside Path B
  n=$(basename "$f" .cpp)
  if ! NFCXX_PATHB_STATS=1 scripts/pathb-dump --ir "$f" > "$tmp/$n.ir" 2> "$tmp/$n.err"; then
    echo "FAIL (front end) $f"; grep -v '^ir-stat' "$tmp/$n.err" | head -5; fail=1; continue
  fi
  if ! head -1 "$tmp/$n.ir" | grep -q '^(ir-module '; then
    echo "FAIL harness $cpfe has no IR back end (no (ir-module) output); build it with scripts/setup-pathb.sh"; exit 2
  fi
  g=$(grep -c '(unsupported' "$tmp/$n.ir" || true); gaps=$((gaps + g))
  if [ $update = 1 ]; then cp "$tmp/$n.ir" "tests/pathb-ir/$n.ir"; echo "wrote tests/pathb-ir/$n.ir"; continue; fi
  if diff -u "tests/pathb-ir/$n.ir" "$tmp/$n.ir" > "$tmp/$n.diff"; then
    echo "ok   $f"
  else
    echo "DIFF $f"; head -40 "$tmp/$n.diff"; fail=1
  fi
done
# Gap probe: tests/pathb-ir/gaps.cpp uses constructs the lowering does not handle yet (VLA, statement
# expressions, inline asm, bit-fields). Its golden shows the (unsupported ...) markers; the count must match.
gap_expected=8
if ! NFCXX_PATHB_STATS=1 scripts/pathb-dump --ir tests/pathb-ir/gaps.cpp > "$tmp/gaps.ir" 2> "$tmp/gaps.err"; then
  echo "FAIL (front end) tests/pathb-ir/gaps.cpp"; fail=1
else
  g=$(grep -c '(unsupported' "$tmp/gaps.ir" || true)
  if [ $update = 1 ]; then cp "$tmp/gaps.ir" tests/pathb-ir/gaps.ir; echo "wrote tests/pathb-ir/gaps.ir"
  elif diff -u tests/pathb-ir/gaps.ir "$tmp/gaps.ir" > "$tmp/gaps.diff"; then
    if [ "$g" = "$gap_expected" ]; then echo "ok   tests/pathb-ir/gaps.cpp ($g unsupported markers)"
    else echo "FAIL tests/pathb-ir/gaps.cpp: $g unsupported markers, expected $gap_expected"; fail=1; fi
  else
    echo "DIFF tests/pathb-ir/gaps.cpp"; head -40 "$tmp/gaps.diff"; fail=1
  fi
fi
# Coverage: sum the per-kind counts of tests/cases (the gap probe is reported above, not here). A kind with a nonzero unsupported count is a gap.
for f in tests/cases/*.cpp; do case $(basename "$f") in qbe_*) continue ;; esac; cat "$tmp/$(basename "$f" .cpp).err"; done 2>/dev/null | awk '
  $1 == "ir-stat" && $2 != "total" {
    key = $2 " " $3; ok[key] += $5; gap[key] += $7; if (!(key in seen)) { seen[key] = 1; order[++n] = key }
  }
  END {
    kinds = 0; lowered_kinds = 0; gap_kinds = 0; tot_ok = 0; tot_gap = 0;
    for (i = 1; i <= n; i++) {
      k = order[i]; kinds++; tot_ok += ok[k]; tot_gap += gap[k];
      if (gap[k] > 0) { gap_kinds++; printf "coverage gap: %-22s lowered %d unsupported %d\n", k, ok[k], gap[k] }
      else lowered_kinds++;
    }
    printf "coverage: %d node kinds seen, %d lowered with no gap, %d with unsupported nodes\n", kinds, lowered_kinds, gap_kinds;
    printf "coverage: %d node occurrences lowered, %d unsupported\n", tot_ok, tot_gap;
  }'
echo "unsupported IR nodes across tests/cases: $gaps"
exit $fail
