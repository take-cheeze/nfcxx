#!/usr/bin/env bash
# The IR-to-IR inliner (scripts/pathb-ir-opt.rb, docs/notes/pathb-ir-passes.md) on helper.ir: the output must match its golden
# and must have no call of the inlined function left. The end-to-end check is the SYCL suite with the pass on:
# NFCXX_IR_OPT=inline tests/sycl/run.sh (the Vulkan programs), which must give the same results as without it.
set -uo pipefail
cd "$(dirname "$0")"
root=$(cd ../.. && pwd)
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
fail=0
"${RUBY:-ruby}" "$root/scripts/pathb-ir-opt.rb" --inline helper.ir > "$out/helper_inline.ir" || fail=1
if diff -u helper_inline.golden.ir "$out/helper_inline.ir"; then echo "inline helper: ok"; else echo "inline helper: FAIL"; fail=1; fi
if grep -q '(call int &"square"' "$out/helper_inline.ir"; then echo "inline helper: FAIL (square still called)"; fail=1; fi
# The same file through the whole pipeline (inline, then scalar replacement with constant propagation and unrolling): the
# golden tests/pathb-ir-opt/helper_sroa.golden.ir.
"${RUBY:-ruby}" "$root/scripts/pathb-ir-opt.rb" --inline --sroa helper.ir > "$out/helper_sroa.ir" || fail=1
if diff -u helper_sroa.golden.ir "$out/helper_sroa.ir"; then echo "inline+sroa helper: ok"; else echo "inline+sroa helper: FAIL"; fail=1; fi
# A 12-byte struct of alignment 4 (a uint3) copied out with a gap of 8 bytes at its start: the filler field must not be 8 bytes
# wide (a 64-bit access to an object 4 mod 8 is misaligned on the GPU; the old pass gave one unsigned_long field).
"${RUBY:-ruby}" "$root/scripts/pathb-ir-opt.rb" --inline --sroa align4_copy.ir > "$out/align4.ir" || fail=1
if grep -q "unsigned_long" "$out/align4.ir"; then echo "align-4 filler: FAIL (an 8-byte field)"; fail=1; else echo "align-4 filler: ok"; fi
exit $fail
