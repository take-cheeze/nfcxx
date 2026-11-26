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
# The Y1-SIMT model (lean/Y1.lean): its checks (the 4x4 matmul, a mutant, out-of-range access) are evaluated by the build.
lake build Y1 || { echo "FAIL tests/lean: Y1 checks"; exit 1; }
echo "ok: Y1-SIMT model and its matmul checks"
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
# The semantics (NfcxxIR/Semantics.lean) on hand-written functions with known answers.
expect() {
  local file=$1 want=$2 got
  got=$("$exe" run "$file" main 2>&1)
  if [ "$got" != "$want" ]; then echo "FAIL tests/lean: $file: got '$got', want '$want'"; fail=1; fi
}
expect tests/sem/sum_loop.ir "value 55"
expect tests/sem/wrap_add.ir "value -2147483648"
expect tests/sem/div_zero.ir "trap: division by zero"
expect tests/sem/slot_store.ir "value 42"
expect tests/sem/slot_uninit.ir "stuck: slot \$\"x\" is read before it is written"
expect tests/sem/float_add.ir "stuck: constant of type double is not an integer literal: 1.5"
# switch: fall-through, break, default, no match, and a break inside a loop inside an arm (1011, then +7)
expect tests/sem/switch.ir "value 1018"
expect tests/sem/switch_nested.ir "stuck: a case label nested inside a statement of a switch body is not modelled"
expect tests/sem/bitcast.ir "value 4294967295"
expect tests/sem/bitcast_width.ir "stuck: bitcast between integer types of different widths (64 and 32 bits)"
expect tests/sem/eval.ir "value 5"
expect tests/sem/eval_trap.ir "trap: division by zero"
expect tests/sem/eval_call.ir "stuck: call of external function f is not modelled"
# calls within the module: arguments bound to the parameters, a fresh environment per callee, recursion (5! = 120)
expect tests/sem/call_double.ir "value 15"
expect tests/sem/call_recursive.ir "value 120"
expect tests/sem/call_external.ir "stuck: call of external function missing_fn is not modelled"
expect tests/sem/call_arity.ir "stuck: call of one with 2 arguments, but it has 1 parameter(s)"
expect tests/sem/call_unbounded.ir "stuck: out of fuel: the calls are nested too deeply"
echo "ok: the semantics gives the expected outcome for the IR functions in tests/sem"
exit $fail
