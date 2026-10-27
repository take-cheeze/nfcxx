#!/usr/bin/env bash
# Tally the Path B borrow checker's verdicts over lowered C++ programs (docs/notes/pathb-borrowck.md, "Refusals and
# limits"): each file is lowered with NFCXX_PATHB_BORROW=1 scripts/pathb-dump --ir and checked in four modes:
#   plain   no options
#   infer   --infer-loan-ends --infer-summaries
#   effects infer, plus --effects scripts/pathb-runtime.effects --effects scripts/pathb-libc.effects
#   emitted effects, plus --emitted-only (the functions the QBE emitter keeps)
# Prints, per mode, the count of each exit status (0 accepted, 1 error, 2 malformed, 3 refused) and of each refusal
# message (digits folded). The checker stops at its first refusal, so a message is the first one in the program.
# Usage: scripts/pathb-borrowck-tally.sh [-o DIR] [FILE.cpp...]
#   default files: tests/pathb-ir, tests/cases, tests/cpp-features, tests/cpp2, tests/pathb-borrow/{cpp,contracts}
#   -o DIR keeps the IR and DIR/MODE.tsv (file, exit status, first message) there
set -uo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
out=""
if [ "${1:-}" = -o ]; then out=$2; shift 2; fi
cd "$root"
if [ $# -gt 0 ]; then files=("$@")
else
  mapfile -t files < <(ls tests/pathb-ir/*.cpp tests/pathb-ir/borrow/*.cpp tests/cases/*.cpp 2>/dev/null
                        find tests/cpp-features tests/cpp2 -name '*.cpp' 2>/dev/null | sort
                        ls tests/pathb-borrow/cpp/*.cpp tests/pathb-borrow/contracts/*.cpp)
fi
if [ -z "$out" ]; then out=$(mktemp -d); trap 'rm -rf "$out"' EXIT; fi
mkdir -p "$out/ir"
lowered=0; failed=0
for f in "${files[@]}"; do
  n=$(echo "$f" | tr / _)
  if NFCXX_PATHB_BORROW=1 scripts/pathb-dump --ir "$f" > "$out/ir/$n.ir" 2>/dev/null; then lowered=$((lowered + 1))
  else rm -f "$out/ir/$n.ir"; failed=$((failed + 1)); fi
done
echo "$lowered programs lowered, $failed not lowered by the front end"
for mode in plain infer effects emitted; do
  case $mode in
    plain) opts=() ;;
    infer) opts=(--infer-loan-ends --infer-summaries) ;;
    effects|emitted) opts=(--infer-loan-ends --infer-summaries --effects scripts/pathb-runtime.effects --effects scripts/pathb-libc.effects) ;;
  esac
  [ $mode != emitted ] || opts+=(--emitted-only)
  : > "$out/$mode.tsv"
  for f in "${files[@]}"; do
    n=$(echo "$f" | tr / _)
    [ -f "$out/ir/$n.ir" ] || continue
    rc=0
    scripts/mrb scripts/pathb-borrowck.rb ${opts[@]+"${opts[@]}"} "$out/ir/$n.ir" > "$out/stdout" 2> "$out/stderr" || rc=$?
    msg=$(grep -hv '^inferred:' "$out/stderr" "$out/stdout" | head -1)
    printf '%s\t%s\t%s\n' "$f" "$rc" "$msg" >> "$out/$mode.tsv"
  done
  echo "== $mode: $(awk -F'\t' '{n[$2]++} END {printf "%d accepted, %d errors, %d malformed, %d refused", n[0], n[1], n[2], n[3]}' "$out/$mode.tsv")"
  awk -F'\t' '$2 == 3 {m = $3; gsub(/[0-9]+/, "N", m); print m}' "$out/$mode.tsv" | sort | uniq -c | sort -rn
done
