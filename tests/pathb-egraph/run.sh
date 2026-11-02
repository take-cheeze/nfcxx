#!/usr/bin/env bash
# Path B e-graph pass regression (docs/notes/pathb-egraph.md, scripts/pathb-egraph.rb). Exits nonzero on any failure.
#  1. Goldens: every function of tests/pathb-ir/*.ir is converted (pathb-ssa.rb's own verification), optimized, and
#     the result is printed, parsed and verified again; a small-budget variant is verified too.
#  2. Cases: tests/pathb-ssa/cases/*.ir and tests/pathb-egraph/cases/*.ir are optimized and verified; with a .args
#     file, `main` runs in the interpreter (original, optimized and small-budget forms) on the .args inputs and on 50
#     random inputs, and the results must be equal (and equal to the expected values). The redundancy case must lose lets.
#  3. The command line: `pathb-ssa.rb` output piped through `pathb-egraph.rb`, then `--check` on the result.
cd "$(dirname "$0")/../.." || exit 1
fail=0
tmp=$(mktemp -d) || exit 1
trap 'rm -rf "$tmp"' EXIT

ruby tests/pathb-egraph/check.rb goldens tests/pathb-ir/*.ir || fail=1
ruby tests/pathb-egraph/check.rb cases tests/pathb-ssa/cases/*.ir tests/pathb-egraph/cases/*.ir || fail=1

for f in tests/pathb-egraph/cases/redundant.ir tests/pathb-ir/abi_struct.ir; do
  name=$(basename "$f" .ir)
  if ! ruby scripts/pathb-ssa.rb "$f" > "$tmp/$name.ssa" 2> "$tmp/$name.err"; then
    echo "FAIL cli pathb-ssa $f"; cat "$tmp/$name.err"; fail=1; continue
  fi
  if ! ruby scripts/pathb-egraph.rb --stats "$tmp/$name.ssa" > "$tmp/$name.opt" 2> "$tmp/$name.stats"; then
    echo "FAIL cli pathb-egraph $f"; cat "$tmp/$name.stats"; fail=1; continue
  fi
  if ! ruby scripts/pathb-egraph.rb --check "$tmp/$name.opt" > /dev/null 2>&1; then
    echo "FAIL cli --check of the optimized $f"; fail=1; continue
  fi
  echo "ok   cli $name: $(cat "$tmp/$name.stats" | sed 's/^pathb-egraph: //')"
done

exit $fail
