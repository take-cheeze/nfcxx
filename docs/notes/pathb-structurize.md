# Path B: SSA to structured IR

`scripts/pathb-ssa-structurize.rb` turns the SSA text of `scripts/pathb-ssa.rb` back into the structured IR, so that the
structured back ends (SPIR-V, PTX, WGSL, WASM) can consume optimized SSA.

    ruby scripts/pathb-ssa.rb FILE.ir | ruby scripts/pathb-ssa-structurize.rb - > FILE.sir
    NFCXX_STRUCTURIZE_VERBOSE=1 ...   # the method chosen for each function, on stderr

## Method

Each function is structured when the CFG allows it, and falls back to a state machine when it does not.

**Structured.** The CFG is rebuilt from its dominators and postdominators:
- A natural loop (a back edge to a dominating header) becomes `(loop (body ...) (step))`. Its exits are `break`s. With one
  exit, the exit block continues after the loop. With several, each exit sets a per-loop exit code and breaks, and after the
  loop a test of the code continues at the exit taken. That also covers a break out of a nested loop.
- A branch (`condbr`, or a `switch` as a chain of `if`s) becomes an `if` whose arms meet at the branch block's immediate
  postdominator, when that block lies in the structure here. Otherwise both arms must leave the structure by a jump.
- A jump is its phi copies, then `continue` to the loop header, `break` (with the exit code) to a loop exit, nothing to a
  merge that the arm already reaches, or the next block of the sequence.
- A block reached on two paths is emitted once per path (node splitting). Each copy gets fresh names for its own lets, and
  its registers are assigned again; a block already on the path being emitted (an irreducible cycle) falls back, and the
  total growth is bounded by a budget.

**State machine (fallback).** Each SSA block is a case of a switch on a state register, the switch is the body of a loop, and
a block ends by setting the state and leaving the switch. This is valid for any CFG.

**Values.** A value that another block reads, or that a phi defines, is a register declared at the top of the function. A
value used only in its own block stays a `let`, so the patterns the emitters read off a `let` (the closure cast of SYCL
kernels) keep working. Phi copies on an edge are two-phase when there is more than one phi.

## Numbers

- Golden files of `tests/pathb-ir` (6599 functions): all 6599 structured, none in the state machine.
- The SYCL vecadd device module (2510 functions): all 2510 structured, and the module validates.
- The SYCL Vulkan suite (26 programs, RADV) with `NFCXX_CFG=structurize`, with and without `NFCXX_SSA_OPT=egraph`: the
  same results as without them.
- vecadd benchmark (2^20, RADV): 3.38 ms per dispatch structured, against 3.04 to 3.23 ms without (within run-to-run noise).
  The state machine alone cost about 0.5 ms more, so the structure is what the structured back ends need.

## Checks

- `tests/pathb-ssa-structurize/run.sh`: the switch golden converts and parses as IR, and the vecadd program validates through
  the chain (where the nfcxx build and a Vulkan device are present).
- `scripts/sycl-build.sh` runs the chain when `NFCXX_CFG=structurize` is set, after `NFCXX_IR_OPT`.

- `NFCXX_SSA_OPT=egraph` runs the e-graph pass (docs/notes/pathb-egraph.md) on the SSA before the structurizer. On the
  vecadd module it removes about 10% of the lets (16348 to 14767) and folds 30 branches. It doesn't change the vecadd kernel's
  GPU time, which is dominated by the aggregate frame.

## Not done

- The SSA-side optimizations that target the measured bottleneck are not written yet: scalar replacement of the `nd_item`
  aggregate (SROA), inlining of the SYCL helpers on the SSA, and loop-invariant code motion.

## Defaults and switches (2026-11-05)

- The SYCL device build runs the SSA round trip by default: `pathb-ssa.rb`, then `pathb-egraph.rb`, then
  `pathb-ssa-structurize.rb`. Opt out with `NFCXX_CFG=off` (the structured IR as the front end wrote it) or `NFCXX_SSA_OPT=off`
  (no e-graph pass). `NFCXX_IR_OPT=inline` still runs the structured inliner first.
- The SSA converter now promotes a slot whose type is const-qualified, such as the closure pointer of a SYCL kernel (`(const
  (ptr ...))`): its loads and stores are compared up to the top-level const. The kernel's own frame slots are gone that way.
- The Vulkan suite (26 programs, RADV) passes with the defaults, with the same results as before.
- The vecadd kernel's frame is still 96 bytes, and its instruction count is still 582 with the inliner on. The frame comes from
  the aggregate values of the callee chain (the accessor and `id` copies) and from the `byval` `nd_item`. Removing that needs
  scalar replacement of aggregates, which is not written yet.

## Where the vecadd frame comes from (2026-11-05)

`NFCXX_EMIT_FRAMES=1 scripts/pathb-spirv-emit.rb` prints each function's frame (bytes and slot names) on stderr. For the
vecadd benchmark the 80-byte frame of the kernel's entry (the 96 of the manifest is that plus slack) is the SYCL entry wrapper
`__nfcxx_sycl_entry_nd`: its slot `it` (the 72-byte `nd_item`) and an 8-byte temporary. The wrapper passes `&it` to the kernel
lambda, which takes the item `byval`. So the slot escapes into the call.

Removing the frame needs the lambda inlined into the wrapper (the inliner refuses `byval` parameters) and then scalar
replacement of `it`. Two things are missing for that:
- A `byval` copy needs the struct's size, and the IR does not carry sizes of user struct types.
- Aliasing the argument instead of copying is sound only when the callee's parameter is read-only and nothing else can reach
  the caller's object while the callee runs. That needs an escape check on both sides.

Either the front end should emit struct sizes for `byval` parameters, or the aliasing rule should be implemented with the
escape check. Neither is in place.
