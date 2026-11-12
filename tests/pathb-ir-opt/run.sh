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
# The caps count weighted nodes (--cost=weighted, the default): slots and other declarations are free, so a callee that is mostly
# declarations is inlined under a small --max-callee, and the plain node count (--cost=nodes) refuses it.
"${RUBY:-ruby}" "$root/scripts/pathb-ir-opt.rb" --inline --max-callee=12 weighted_cost.ir > "$out/wc_w.ir" || fail=1
"${RUBY:-ruby}" "$root/scripts/pathb-ir-opt.rb" --inline --max-callee=12 --cost=nodes weighted_cost.ir > "$out/wc_n.ir" || fail=1
if ! grep -q '(call int &"decls"' "$out/wc_w.ir" && grep -q '(call int &"decls"' "$out/wc_n.ir"; then echo "weighted cost: ok"; else echo "weighted cost: FAIL"; fail=1; fi
# Past --max-growth only a tiny callee (--max-tiny, default 16) is still inlined: with a budget of half the module, the tiny
# callee goes in and, with --max-tiny=0, it stays a call.
"${RUBY:-ruby}" "$root/scripts/pathb-ir-opt.rb" --inline --max-growth=0.5 weighted_cost.ir > "$out/tiny_on.ir" || fail=1
"${RUBY:-ruby}" "$root/scripts/pathb-ir-opt.rb" --inline --max-growth=0.5 --max-tiny=0 weighted_cost.ir > "$out/tiny_off.ir" || fail=1
if ! grep -q '(call int &"decls"' "$out/tiny_on.ir" && grep -q '(call int &"decls"' "$out/tiny_off.ir"; then echo "tiny callee: ok"; else echo "tiny callee: FAIL"; fail=1; fi
# The same file through the whole pipeline (inline, then scalar replacement with constant propagation and unrolling): the
# golden tests/pathb-ir-opt/helper_sroa.golden.ir.
"${RUBY:-ruby}" "$root/scripts/pathb-ir-opt.rb" --inline --sroa helper.ir > "$out/helper_sroa.ir" || fail=1
if diff -u helper_sroa.golden.ir "$out/helper_sroa.ir"; then echo "inline+sroa helper: ok"; else echo "inline+sroa helper: FAIL"; fail=1; fi
# The constant fold of wadd on int wraps (2147483647 + 1 is -2147483648), and a set of the index register after its bounds check
# keeps the index (no fold to offset 0).
"${RUBY:-ruby}" "$root/scripts/pathb-ir-opt.rb" --inline --sroa wadd_set.ir > "$out/wadd_set.ir" || fail=1
if grep -q '(const int -2147483648)' "$out/wadd_set.ir"; then echo "wadd wrap: ok"; else echo "wadd wrap: FAIL"; fail=1; fi
if grep -q '(index %0 %1 4)' "$out/wadd_set.ir" && ! grep -q '(offset %0 0)' "$out/wadd_set.ir"; then echo "set after bounds: ok"; else echo "set after bounds: FAIL"; fail=1; fi
# An inlined callee that asks for a sub-group size (a top-level sycl-kernel-attr) gives its caller that attr: the emitter reads
# the attr of the functions a kernel reaches, and the callee is no longer reached once it is inlined.
"${RUBY:-ruby}" "$root/scripts/pathb-ir-opt.rb" --inline subgroup_attr.ir > "$out/subgroup_attr.ir" || fail=1
if grep -q '(sycl-kernel-attr "entry" (reqd-sub-group-size 32))' "$out/subgroup_attr.ir"; then echo "subgroup attr through inline: ok"; else echo "subgroup attr through inline: FAIL"; fail=1; fi
# Two byval parameters of one callee that share a name (the front end names unnamed temporaries "tmp") get two slots of distinct
# names in the caller, not one name twice.
"${RUBY:-ruby}" "$root/scripts/pathb-ir-opt.rb" --inline byval_names.ir > "$out/byval_names.ir" || fail=1
if [ "$(grep -o '(slot "tmp\.byval[0-9]\.i[0-9]*"' "$out/byval_names.ir" | sort | uniq -d | wc -l)" = 0 ] && [ "$(grep -o '(slot "tmp\.byval[0-9]\.i[0-9]*"' "$out/byval_names.ir" | wc -l)" = 2 ]; then echo "byval slot names: ok"; else echo "byval slot names: FAIL"; fail=1; fi
# A 12-byte struct of alignment 4 (a uint3) copied out with a gap of 8 bytes at its start: the filler field must not be 8 bytes
# wide (a 64-bit access to an object 4 mod 8 is misaligned on the GPU; the old pass gave one unsigned_long field).
"${RUBY:-ruby}" "$root/scripts/pathb-ir-opt.rb" --inline --sroa align4_copy.ir > "$out/align4.ir" || fail=1
if grep -q "unsigned_long" "$out/align4.ir"; then echo "align-4 filler: FAIL (an 8-byte field)"; fail=1; else echo "align-4 filler: ok"; fi
# A struct-returning callee (its result is an sret parameter) is inlined: the callee's store goes to the slot the call passed.
"${RUBY:-ruby}" "$root/scripts/pathb-ir-opt.rb" --inline sret_inline.ir > "$out/sret_inline.ir" || fail=1
if ! grep -q '(call' "$out/sret_inline.ir" && grep -q '(store int $"tmp" %0)' "$out/sret_inline.ir"; then echo "sret inline: ok"; else echo "sret inline: FAIL"; fail=1; fi
# A return at the end of nested trailing blocks is in tail position: the callee is inlined.
"${RUBY:-ruby}" "$root/scripts/pathb-ir-opt.rb" --inline tail_block.ir > "$out/tail_block.ir" || fail=1
if ! grep -q '(call' "$out/tail_block.ir" && grep -q '(wadd int %0 %0)' "$out/tail_block.ir"; then echo "tail-block return: ok"; else echo "tail-block return: FAIL"; fail=1; fi
# An early-returning callee is inlined as a loop that runs once: each return stores the result slot and breaks. A callee whose
# return is inside one of its loops is inlined too, with a done flag that a test after that loop reads.
"${RUBY:-ruby}" "$root/scripts/pathb-ir-opt.rb" --inline early_return.ir > "$out/early_return.ir" || fail=1
if ! grep -q '(call int &"clamp0"' "$out/early_return.ir" && grep -q '(block (store int $"ret.i1" (const int 0)) (break))' "$out/early_return.ir" \
   && grep -q '(let %1 int (load int $"ret.i1"))' "$out/early_return.ir" && ! grep -q '(call' "$out/early_return.ir" \
   && grep -q '(store bool $"done.i2" (const bool 1))' "$out/early_return.ir"; then
  echo "early return: ok"; else echo "early return: FAIL"; fail=1; fi
# Returns inside loops and switches (a nested loop, a switch in a loop with a continue, a loop in a switch of a void callee):
# after inlining, and after inlining and scalar replacement, main gives the results of the C program in return_in_loop.args
# (computed by gcc from the same functions), in the structured interpreter and in the SSA form of scripts/pathb-ssa.rb.
"${RUBY:-ruby}" "$root/scripts/pathb-ir-opt.rb" --inline return_in_loop.ir > "$out/ril.ir" || fail=1
"${RUBY:-ruby}" "$root/scripts/pathb-ir-opt.rb" --inline --sroa return_in_loop.ir > "$out/ril_sroa.ir" || fail=1
ril=ok
grep -q '(call' "$out/ril.ir" && ril="FAIL (a call is left)"
while read -r inp _ want; do
  for f in ril ril_sroa; do
    got=$(ruby "$root/scripts/pathb-ssa.rb" --run $inp "$out/$f.ir" 2>&1)
    [ "$got" = "structured=$want ssa=$want" ] || ril="FAIL ($f.ir on $inp: $got, want $want)"
  done
done < return_in_loop.args
echo "return in a loop or switch: $ril"; [ "$ril" = ok ] || fail=1
# The unroller (--sroa): a counter stepped by wmul, by +16 (unsigned long), down by 1 (unsigned, `3 <= j`), a loop of no trip,
# and `0 < mask` with mask >>= 1 (shr) are unrolled; the loop whose counter is written through a pointer stays. main gives the
# results of the C program in unroll.args (gcc); the interpreter has no cshr, so shr is checked by its shape (four copies).
"${RUBY:-ruby}" "$root/scripts/pathb-ir-opt.rb" --sroa unroll.ir > "$out/unroll.ir" || fail=1
un=ok
[ "$(grep -o '(loop' "$out/unroll.ir" | wc -l)" = 1 ] || un="FAIL (want one loop left)"
[ "$(grep -o '(cshr' "$out/unroll.ir" | wc -l)" = 4 ] || un="FAIL (want four shr copies)"
while read -r inp _ want; do
  got=$(ruby "$root/scripts/pathb-ssa.rb" --run $inp "$out/unroll.ir" 2>&1)
  [ "$got" = "structured=$want ssa=$want" ] || un="FAIL (on $inp: $got, want $want)"
done < unroll.args
echo "unroll: $un"; [ "$un" = ok ] || fail=1
# --prune-unused: the roots are what another object can see (external, constructor); a weak or static function stays only
# when a root reaches it by name (helper: called, via_table: named by a reached table), the others go.
"${RUBY:-ruby}" "$root/scripts/pathb-ir-opt.rb" --prune-unused prune_unused.ir > "$out/prune_unused.ir" || fail=1
if [ "$(grep -o '^(function "[^"]*"' "$out/prune_unused.ir" | tr '\n' ' ')" = '(function "via_table" (function "helper" (function "api" (function "ctor_fn" ' ] \
   && grep -q '^(global "tab"' "$out/prune_unused.ir" && ! grep -q '^(global "dead_tab"' "$out/prune_unused.ir"; then echo "prune unused: ok"; else echo "prune unused: FAIL"; fail=1; fi
# --prune-unreachable: the function no root reaches goes; one called by the entry, one whose address it takes, and one a named global's
# initializer names stay.
"${RUBY:-ruby}" "$root/scripts/pathb-ir-opt.rb" --prune-unreachable=__nfcxx_sycl_entry_ prune.ir > "$out/prune.ir" || fail=1
if [ "$(grep -o '^(function "[^"]*"' "$out/prune.ir" | tr '\n' ' ')" = '(function "virt" (function "fp_target" (function "used" (function "__nfcxx_sycl_entry_k" ' ] \
   && grep -q '^(global "vt"' "$out/prune.ir" && ! grep -q '^(global "dead"' "$out/prune.ir"; then echo "prune unreachable: ok"; else echo "prune unreachable: FAIL"; fail=1; fi
# The EH state globals: their stores go, their loads become null (a pointer) or 0; the slot stores stay for the later passes.
"${RUBY:-ruby}" "$root/scripts/pathb-ir-opt.rb" --strip-eh strip_eh.ir > "$out/strip_eh.ir" || fail=1
if ! grep '(function' "$out/strip_eh.ir" | grep -q 'eh_' && grep -q '(let %1 (ptr (struct "__C8")) (null (ptr (struct "__C8"))))' "$out/strip_eh.ir" \
   && grep -q '(let %2 unsigned_short (const unsigned_short 0))' "$out/strip_eh.ir"; then echo "strip eh: ok"; else echo "strip eh: FAIL"; fail=1; fi
# A function with no call drops its EH stack entry (slot, push, pop); one with a call keeps it.
"${RUBY:-ruby}" "$root/scripts/pathb-ir-opt.rb" --strip-leaf-eh strip_leaf_eh.ir > "$out/strip_leaf_eh.ir" || fail=1
if ! grep '^(function "_ZNK1A3getEv"' "$out/strip_leaf_eh.ir" | grep -q '__C8' \
   && grep '^(function "withcall"' "$out/strip_leaf_eh.ir" | grep -q '(slot "tmp.1" (struct "__C8")'; then echo "strip leaf eh: ok"; else echo "strip leaf eh: FAIL"; fail=1; fi
# A function whose calls all go to functions that cannot throw (here one that only makes an atomic call) loses its frame too;
# the one that calls an unknown external function (withcall) keeps it.
if ! grep '^(function "vialeaf"' "$out/strip_leaf_eh.ir" | grep -q '__C8' && ! grep '^(function "leafonly"' "$out/strip_leaf_eh.ir" | grep -q '__C8' \
   && grep '^(function "withcall"' "$out/strip_leaf_eh.ir" | grep -q '__C8'; then echo "strip nothrow callers: ok"; else echo "strip nothrow callers: FAIL"; fail=1; fi
# A cleanup frame (kind 1) is set up and read back through chains of offsets of its address: those go with it. A destructor whose
# only call is to a guarded (noexcept) function loses both of its frames; the guarded function, which calls an unknown one, keeps its own.
"${RUBY:-ruby}" "$root/scripts/pathb-ir-opt.rb" --strip-leaf-eh strip_kind1.ir > "$out/strip_kind1.ir" || fail=1
if ! grep '^(function "dtor_like"' "$out/strip_kind1.ir" | grep -q '__C9\|__eh_curr_region' \
   && grep '^(function "guarded_member"' "$out/strip_kind1.ir" | grep -q '(slot "tmp.1" (struct "__C9")'; then echo "strip kind 1 frame: ok"; else echo "strip kind 1 frame: FAIL"; fail=1; fi
# A call of a function that never returns (an assertion failure) lets nothing out; an unknown project function does, unless
# --nothrow-extern names it.
"${RUBY:-ruby}" "$root/scripts/pathb-ir-opt.rb" --strip-leaf-eh --nothrow-extern=proj_abort strip_kind1.ir > "$out/strip_kind1b.ir" || fail=1
if ! grep '^(function "asserter"' "$out/strip_kind1.ir" | grep -q '__C9' && grep '^(function "projabort"' "$out/strip_kind1.ir" | grep -q '__C9' \
   && ! grep '^(function "projabort"' "$out/strip_kind1b.ir" | grep -q '__C9'; then echo "nothrow externs: ok"; else echo "nothrow externs: FAIL"; fail=1; fi
# Scalar replacement through a `this` slot: a pointer slot stored twice with one array's address reads as that address, a memcpy
# of a constant size is a copy, and the arrays become scalar slots.
"${RUBY:-ruby}" "$root/scripts/pathb-ir-opt.rb" --sroa sroa_this.ir > "$out/sroa_this.ir" || fail=1
if grep -q '(slot "v.f4" int 4 4)' "$out/sroa_this.ir" && grep -q '(slot "w.f4" int 4 4)' "$out/sroa_this.ir" && ! grep -q 'memcpy\|(store (ptr int) \$"self"' "$out/sroa_this.ir"; then
  echo "sroa through this: ok"; else echo "sroa through this: FAIL"; fail=1; fi
# Store-to-load forwarding: the load after the store takes the stored value; the load after the call does not.
"${RUBY:-ruby}" "$root/scripts/pathb-ir-opt.rb" --forward forward.ir > "$out/forward.ir" || fail=1
if grep -q '(let %1 int %0)' "$out/forward.ir" && grep -q '(let %2 int (load int $"x"))' "$out/forward.ir"; then echo "forward: ok"; else echo "forward: FAIL"; fail=1; fi
# A callee with a goto and a label is inlined, and each copy's labels get a suffix of their own: two calls of it leave no call
# and two different label names (the asm goto of the kernel's static_cpu_has is such a callee).
"${RUBY:-ruby}" "$root/scripts/pathb-ir-opt.rb" --inline goto_inline.ir > "$out/goto_inline.ir" || fail=1
if ! grep -q '(call' "$out/goto_inline.ir" && [ "$(grep -o '(label "yes\.i[0-9]*")' "$out/goto_inline.ir" | sort -u | wc -l)" = 2 ] \
   && [ "$(grep -o '(goto "yes\.i[0-9]*")' "$out/goto_inline.ir" | sort -u | wc -l)" = 2 ]; then echo "goto and label inline: ok"; else echo "goto and label inline: FAIL"; fail=1; fi
exit $fail
