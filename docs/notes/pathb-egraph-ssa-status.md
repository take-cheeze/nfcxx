# Path B e-graph and SSA: status report (2026-11-05)

## Merged recently

- **Dead phi cycles removed (e-graph), PR #783.** A phi is kept only if a live use reaches it. Before, only phis with no uses at all were removed, so a loop accumulator that is updated but never read survived. Case: `tests/pathb-egraph/cases/dead_phi_cycle.ir` (one dead phi removed, 53 interpreted runs equal).
- **Uppercase `0X` literals in the SSA reader, PR #783.** `normalise_literals` in `scripts/pathb-ssa.rb` matched lowercase `0x` only, so the interpreter could not read `0X` and any such case failed the cases harness. Case: `tests/pathb-egraph/cases/hex_upper.ir`.

## Earlier

- Hex literals fold in the e-graph (`const_value`, PR #781).
- Deterministic step budget for the e-graph check replaces the wall-clock limit (PR #782): 100,000 steps; the largest finished golden run takes 2,189.
- Checked add, subtract, multiply and negate, signed and unsigned, on the SSA-to-QBE route (PRs #776, #779).
- Weighted cost model, selected with `--cost weighted` (PR #774). It changes no output yet.

## Still missing

**E-graph**
- Code motion across blocks: no hoisting, sinking or partial redundancy elimination.
- Memory across blocks: state starts empty in each block; loads through pointers are never merged; address-taking clears state (needs escape analysis).
- Rewrites that would make the weighted cost model choose differently: multiply-to-shift needs a wrapping shift operator, which the IR does not have (only the checked `cshl`); multiply-to-add is possible but unlisted.
- Bit-field and `index`/`offset` algebra: none.
- Floats: NaN payloads not modelled; float identities deliberately absent.
- Extraction: greedy per class, not DAG-optimal.

**SSA**
- A structurizer, needed before PTX, WebAssembly and WGSL can consume SSA.
- Verification checks structure only; meaning is checked on hand-written cases.
- SSA-to-QBE refusals: switch edges into a block with a phi; aggregates by value with an unknown ABI shape; bit-field access to floats; `pdiff` with a non-constant element size. The front-end `asm-clobbers` refusal is outside SSA.

## Performance against egg

`tests/pathb-egraph/egg/run.sh OPS PROGRAMS SEED` runs both on the same random straight-line integer programs (the
generator is `gen.rb`, the egg side `src/main.rs`, egg 0.11). The rules are the same families: commutativity, identities
(x+0, x-0, x*1, x*0, x-x), constant reassociation and x-c = x+(-c), and constant folding at 32-bit wrapping. Each
extracted program is evaluated on 260 input vectors and must equal the original's value (the run reports "all equal").

Measured with seed 7, 20 programs per size:

| Size | Ours (the pass alone) | egg (add, saturate, extract) | Operations in the output: ours / egg |
|---|---|---|---|
| 50 operations | about 98 ms per function | about 0.5 to 0.8 ms | 9.6 / 9.4 |
| 300 operations | about 130 ms per function | about 1.5 ms | 97.8 / 97.7 |

The extracted programs are about the same size, so the difference is speed: about 200x at 50 operations and about 90x at
300. Caveats: egg has no control flow, so only straight-line blocks are comparable; the timings are wall clock on one
machine; the earlier figure of about 32 ms per function did not reproduce (the same code takes about 100 ms today, and
the commit before the loop-invariant pass takes the same), and its cause is not known.

## Next candidates

1. A structurizer for the non-QBE consumers (large; needs a design decision).
2. Escape analysis, to allow memory forwarding across blocks.
3. A wrapping shift operator in the IR, to enable multiply-to-shift.
