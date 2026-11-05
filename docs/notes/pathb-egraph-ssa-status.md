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

Egg 0.11 with the same rule families (commutativity, identities, constant reassociation, constant folding), 8 iterations, 2,000 added nodes. 20 random functions per size.

| Size | Ours (Ruby, wall) | egg (Rust release) | Ratio |
|---|---|---|---|
| 50 operations | about 32 ms per function | 0.4 ms | about 80x |
| 300 operations | about 92 ms per function | 1.4 ms | about 65x |

E-node counts are close (about 208 vs 225 at size 50). Caveats: our pass does verification and rendering as well, egg's constant analysis is 64-bit where ours is 32-bit, and extracted programs were not checked for equivalence.

## Next candidates

1. A structurizer for the non-QBE consumers (large; needs a design decision).
2. Escape analysis, to allow memory forwarding across blocks.
3. A wrapping shift operator in the IR, to enable multiply-to-shift.
