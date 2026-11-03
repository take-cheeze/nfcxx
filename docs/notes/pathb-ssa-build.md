# Path B SSA build driver (opt-in)

`scripts/pathb-ssa-build` runs the whole Path B chain for one IR file and writes assembly:

    scripts/pathb-ssa-build [-o OUT.s] [--no-opt] FILE.ir

1. `scripts/pathb-ssa.rb` converts the IR to SSA (`docs/notes/pathb-ssa.md`).
2. `scripts/pathb-egraph.rb` optimizes the SSA (`docs/notes/pathb-egraph.md`). `--no-opt` skips this step.
3. `scripts/pathb-ssa-qbe.rb` emits QBE IL (`docs/notes/pathb-ssa-qbe.md`). The globals' data is emitted once, and each
   function is emitted on its own.
4. `build/qbe/qbe` (or `NFCXX_QBE`) assembles the IL. The assembly goes to `-o OUT.s`, or stdout.

The driver does not link. The caller links the assembly with the runtime it needs.

## Opt-in

Nothing calls the driver. The default Path B flow (`scripts/pathb-dump`, the `NFCXX_PATHB_MODE=ir` output, and the
existing harness and CI) does not use it, and is unchanged.

## Functions the emitter does not cover

A function outside the emitter's subset is not emitted. Its name and the reason go to stderr, the other functions are
still written, and the status is 3. The driver does not fall back to the Path B IL output for that function.
Callers of a function that was not emitted get an undefined symbol at link time. A status 3 output is therefore not a
complete program.

## Status

| status | meaning |
|---|---|
| 0 | every function emitted |
| 1 | error: conversion, optimization, or QBE failed (the message is on stderr) |
| 2 | usage |
| 3 | some functions not emitted; the names and reasons are on stderr, and the assembly has the rest |

## Test

    ruby tests/pathb-ssa-build/run.rb

It checks a covered case (`tests/pathb-ssa/cases/ternary_set.ir`) against its `.args` results after linking with a C
driver, a partial module (`tests/pathb-egraph/cases/memory_volatile.ir`: status 3, reason reported, the function absent),
and the usage status.
