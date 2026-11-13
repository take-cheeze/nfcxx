# Path B SSA to QBE

`scripts/pathb-ssa-qbe.rb` emits QBE IL from the SSA text of a module (`docs/notes/pathb-ssa.md`), optionally after the
e-graph pass (`docs/notes/pathb-egraph.md`). It is the first consumer of the optimized SSA: until now the optimized form
was only interpreted. QBE (`build/qbe/qbe`) then assembles the IL to native code.

    ruby scripts/pathb-ssa.rb FILE.ir | ruby scripts/pathb-ssa-qbe.rb - > FILE.qbe
    build/qbe/qbe FILE.qbe > FILE.s

End-to-end check: `ruby tests/pathb-ssa-qbe/run.rb [CASE.ir ...]`. For each case with a `.args` file it optimizes
`main`, emits QBE, assembles it under the name `case_main`, links it with a C driver, runs it on each input and compares
with the interpreter. Cases the emitter or the interpreter does not cover are reported as SKIP with the reason.

## Subset

- Types: integer scalars of 8 to 64 bits, `bool`, and pointers. QBE class `w` for types up to 32 bits, `l` for 64-bit
  integers and pointers.
- Operations: `wadd`, `wsub`, `wmul`, `wneg`, `and`, `or`, `xor`; comparisons `eq ne lt.s lt.u le.s le.u`; integer
  conversions (`iconv`); `load` and `store` of scalar objects; `phi`, `br`, `condbr`, `ret`, `unreachable` (as `hlt`).
- Objects: a slot that the converter did not promote is allocated on the stack at entry (`alloc4`/`alloc8`). Address
  operands are `$slot`; a parameter `%k` is `%pk`; a register `%N` is `%vN`.
- `switch`: a chain of `jnz` tests (QBE has no switch). The first test is in the switch block; each later test has its
  own block. A phi of a target names the test block that jumps to it.
- Nested expressions (in operands, switch operands and phi operands) are computed into temporaries first, in the block
  that uses them (a phi operand in its predecessor).
- Checked operations (`cdiv`, `crem`, `cshl`, `cshr`, `cf2i`): each check is a call `pathb_check(cond, code)` placed before
  the operation; codes 1 division by zero, 2 signed overflow, 3 shift count out of range, 4 float to integer out of range.
  A signed 32-bit `cdiv` or `crem` by a constant d >= 3 that is not a power of two has no division instruction: the quotient
  is the high part of a 64-bit multiply by c = floor(2^s / d) + 1 (s = 31 + ceil(log2 d)), plus 1 for a negative dividend,
  and the remainder is x - q * d (`magic_div32_lines`; Lemire, "Beating the compiler at signed 32-bit division", 2026, https://lemire.me/blog/2026/10/31/beating-the-compiler-at-signed-32-bit-division/).
  QBE emits `idivl` for a constant `div`, so this is what removes it. Powers of two, negative and 64-bit divisors, and
  variable divisors keep the division instruction.
  The checked add, subtract, multiply and negate (`cadd`, `csub`, `cmul`, `cneg`) check with code 2: a narrow type is
  computed in 64 bits and range-checked; an 8-byte add or subtract uses the sign-bit identities; an 8-byte multiply divides
  the product back by the operand (a divisor of 0 or -1 is replaced by 1, see `checked_arith_lines`), so it needs no runtime.
  The unsigned forms check with unsigned comparisons: a narrow result must not exceed the type's maximum, an add wraps below an
  operand, a subtract borrows, a multiply divides back, and a negate of a nonzero value overflows.
  The runtime must not return when `cond` is nonzero (it traps; the test driver longjmps out). No block is split. `bool`
  checked ops are not emitted.
- Floats: `s` and `d` classes; float literals are rounded to their type and written as exact hex, so `-0.0` survives.
  Int to float follows the source signedness.
- Globals become QBE `data` with their initialisers (zero, integer and pointer scalars, addresses of module globals).
  Extern, thread-local and other initialisers are not emitted; a reference to one raises `QbeUnsupported`.
- Calls: `(call RET &"name" ARG...)` is a direct call by name; module functions and libc (`_setjmp`, `longjmp`) alike.
- `(nonnull P)` traps on a null pointer (code 5); `(bounds I N)` traps on an index outside [0, N) (code 6), with an
  unsigned comparison so a negative index is caught too.
- Addresses: `(addr $slot)`, `(offset P K)` and `(index P I SIZE)`; a slot of an array type is allocated at its full size.
- Volatile accesses (`load.v`/`store.v`) call the volatile helpers the module declares, as the flat emitter does.
- Aggregates passed or returned by value are lowered when their `abi-type` has a shape the emitter knows; an unknown shape is
  refused.

A function outside the subset raises `QbeUnsupported` and nothing is emitted for it, so a module with an unsupported
function still emits the rest.

## The 32-bit x86 targets

`scripts/pathb-ssa-build --target=i386|i386_regparm3 [--m16]` emits for QBE's i386 targets (`Qbe.ptr32`: pointers are of class `w`, `long` is
`int`, a structure's `l` and `d` leaves are words, no checks, no jump tables, asm templates as helpers with 32-bit registers). The IR is the
front end's `--target=linux_i686` one (its layout has `(pointer 4)`, which selects the mode). docs/notes/nfcc-pathb.md, "The 32-bit x86 target".

## Status

`tests/pathb-ssa-qbe/run.rb` on the current cases: 32 match the interpreter, 0 mismatches, 3 skipped (a double-typed
global in `float_fold`, a volatile access in `memory_volatile`, and an aggregate in `memory_dead_store`), plus
`memory_store_forward`, which the interpreter itself does not model (its typed cells reject an `int` access to a `long`).

The runner runs the interpreter through `tests/pathb-egraph/check.rb`'s `CaseMachine`, so `observe`, `clobber` and the
volatile accesses are modelled on both sides. A case whose `clobber` targets a non-int slot is skipped.
The emitter uses the same naming and cls rules as the QBE it is tested against; a mismatch is a bug in the emitter,
the optimizer, or the interpreter, and the runner reports which one by comparing against the interpreter.

## Frames

QBE gives every `alloc` a frame offset of its own and shares nothing, and Path B code used to have frames several times gcc's
(`tests/ast` `inline_loops` and `tests/uop` `test.cpp` overflowed the 8 MB stack in a recursion of a few thousand levels; the
measured frames are in `docs/notes/cproc-removal-library-suites.md`). Three things now keep them small:

- **A function that calls `_setjmp` promotes its slots again.** Every `try` block of the C++ EH lowering is an `_setjmp`, and
  `scripts/pathb-ssa.rb` used to keep *every* slot of such a function in memory (the inlined bodies of `std::vector`'s
  `_M_realloc_insert` and the like: 300 slots, 3 KB). A promoted slot would hold the value of the first return when a throw lands
  after the call, so the slots that are *live after a call of `_setjmp`* (read, on some path from it, before a store: `Converter#
  drop_live_across_setjmp`, a backward liveness over the CFG) stay in memory, and the others (written before every read on any path
  from the call, so that both returns see their own values) are promoted. The emitter still passes the address of each remaining
  slot to `__pathb_escape`. `tests/pathb-ssa-qbe/frames/setjmp.ir`: `a` (set in one arm and read after the second return) stays, `t`
  (stored right after the call) is promoted.
- **Slots whose lifetimes do not overlap share one stack object** (`Fn#share_slots`). A lifetime is bracketed by
  `(life-start $"x")` and `(life-end $"x")` facts that the inliner writes around each inlined body for the slots it hoists
  (`pathb-ir-opt.rb --scope-facts`, which `pathb-cc` passes after `--inline` unless `--asan` or `--safe-pointers` is on): the
  callee's frame lives exactly as long as its statements. The emitter runs a forward may-analysis of the slots in scope over the SSA
  blocks (a slot is in scope from its `life-start` on every path to a `life-end`); two slots conflict when one starts while the
  other is in scope on some path. A slot with no facts, one whose atom is named outside its scope, or one whose derived address (an offset, bitcast, index, select or
  phi of it, the pointer a call returns when given one) is still named in a register outside its scope, never shares; an address kept
  in memory is trusted to die with the scope, as the language requires. Slots are grouped greedily in order; a group's object
  has its largest size and alignment. Two inlined calls one after the other thus have the frame of the larger, not of both, nested
  ones (a callee's own callees) stay apart, and a call in a loop reuses the same object each iteration. `--asan` and `--safe` (each
  slot an object of its own, with redzones or registered) do not share. The e-graph pass ignores the facts (`life-start` and
  `life-end` neither read nor write memory and do not make a slot escape; the front end's `decl` and `scope-end` do).
  `tests/pathb-ssa-qbe/frames/share.ir` shows the frame of eight 1 KB arrays at 5 KB, the sums right, the facts-less and
  rogue slots apart.
- **EH entries are cut to the bytes written** (`pathb-ir-opt.rb --shrink-eh-frames`, `docs/notes/pathb-ir-passes.md`): of the
  715 KB of memory slots in `nfcast_nodes.cpp`'s IR, 550 KB were the 240-byte EH entries of functions and inlined bodies (2292 of
  them), and a function's needs 48 bytes, a noexcept function's 16. `--strip-leaf-eh` removes the facts of the EH frames it drops.

Measured with `scripts/pathb-cc` (HEAD, then this change; `objdump -d`, `sub $N, %rsp` of each function; gcc -O2 in the last column):

| | before | after | gcc -O2 |
| --- | --- | --- | --- |
| `nfcuop_pattern.o`: total of all frames / the largest | 54376 / 4152 B (`vector<Rule>::_M_range_insert`) | 20856 / 760 | 1616 / 248 |
| `Rewriter::go` (graph_rewrite's recursion, tests/uop `test.cpp`) | 680 | 408 | 248 |
| `nfcast_nodes.o`: total / the largest | 1332448 / 3408 B (`vector<unique_ptr<Node>>::_M_realloc_insert`) | 424008 / 968 (`Cloner::clone`) | 27584 / 776 |
| `NumForNode::exec`, `ReturnNode::exec` (tests/ast) | 872, 472 | 664, 280 | 216, 120 |
| `vector<unique_ptr<N>>::_M_realloc_insert` (a small test unit: a try block, all slots used to stay in memory) | 3296 | 680 | |
| `inline_loops.lua` (State::max_depth 1500 levels): the smallest stack it runs in | 4699 KB | 3212 KB | |

What is left: the 240-byte entry of every try block (the catch fields sit behind the `jmp_buf`, so it does not shrink), and the
locals of the source function itself (named locals in disjoint blocks, the front end's temporaries) have no lifetime facts, so they
do not share: of the memory slots of `nfcast_nodes.cpp` after the passes, 199 KB are try entries, 88 KB are slots whose address
escapes and that have no facts, 85 KB have facts (and share), 45 KB are never addressed except by loads, stores and copies (a
liveness over the slot contents could share those too).

## Next

1. Aggregates by value (copy) and volatile accesses.
2. Decide the wiring into `bin/nfcxx` (behind an option, Path B only).

## GNU C constructs of the kernel's shape (the cproc-removal work)

- **`__builtin_return_address(0)`, `__builtin_frame_address(0)`** (x86-64): IR rvalues `(retaddr)` and `(frameaddr)`; QBE gives every
  function a frame pointer, and a weak helper the driver appends (`# pathb-asm retaddr`, `frameaddr`; `ASM_HELPERS` in
  `scripts/pathb-ssa-build`) reads the caller's `8(%rbp)` or `%rbp`. A call of the helper is followed by an empty call, so QBE does not
  make `return __builtin_return_address(0);` a tail call (`leave; jmp`, which would run the helper in the caller's frame). The inliner
  leaves a function that holds one of them alone. A level other than 0 is refused (`builtin return_address of a level other than 0`).
  `__builtin_extract_return_addr` and `__builtin_frob_return_addr` are the identity. arm64 has no helper: the unit is refused there.
- **`__attribute__((noinline))`**: the front end writes a `(noinline)` function head when `NFCXX_IR_NOINLINE=1` (`pathb-dump
  --ir-noinline`, which `pathb-cc` passes for the SSA emitter only: the other emitters refuse an unknown head), and
  `scripts/pathb-ir-opt.rb` does not inline such a callee.
- **`__attribute__((cleanup(f)))`** (C and C++): `be/nfcxx_ir.c` keeps the stack of the function's variables with a cleanup and
  writes `(eval (call void &"f" &var))` where their scope ends: at a block's end, at `return` (after the value is computed), and
  at `goto`/`break`/`continue` for the variables above the target label's count (`ir_cu_*`).
- **`section("S")`** on a global: `section "S" "aw"` (`"a"` for a const object) on its QBE data, as gcc does; `used` keeps a static
  object that nothing refers to (`(used)` global flag: a root of both prunes). A thread-local with a section is refused.
- **GNU case ranges** of more than 1024 values: a label (`__case_range_N`) in the switch body and, before the switch, one test
  `(le.u (wsub (iconv unsigned_long x) LO) (HI - LO))` and a `goto` to it per range.
- **A flexible array member** initialised by a string or by elements: the global's size is the struct plus them; no bounds check
  is made on an array of size 0.
