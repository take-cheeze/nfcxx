# Path B: optimizations measured and rejected

These are the IR-level and emitter-level changes that were measured on the llama.cpp `ggml-vulkan.cpp` translation unit
(33 MB of IR after inlining; the object is 878k instructions) and not kept. Each entry records the measurement, the
reason it was rejected, and what would change the answer. The numbers are from the session that produced them; they are
not stable across IR changes, so re-measure before relying on one.

## Dead-store elimination, straight-line form

- Measured: a store into a non-escaping slot is removed when the same statement list overwrites that slot before any
  statement reads it (any use of the slot or a pointer derived from it counts as a read; nested blocks clear the pending
  store). Result: 117 of 173,135 stores into non-escaping slots (0.1%); 117 of 476,497 stores overall.
- Rejected: too small to justify a pass.
- Earlier figure, not valid: 79,780 (16.7%) "dead" stores. That count treated a store as dead when a later store in an
  enclosing or sibling branch overwrote it, which is unsound: the overwrite may happen on one path only.
- What would change the answer: path-sensitive liveness (a store is dead only if every path overwrites it), which needs
  dominance information the pass does not have.

## Write-only non-escaping slots

- Measured: slots whose address never leaves the function (no call argument, stored value or return) and that are never
  read, directly or through a derived pointer. Result: 3 slots, 0 stores into them.
- Rejected: nothing to remove.

## Alias-based duplicate null checks

- Measured: a `nonnull` check on a value that is a copy (or offset/bitcast) of a value already checked in an enclosing
  scope. Result: 0.
- Duplicate `nonnull` checks on the same SSA name within one function: 0.
- Rejected: the redundancy is not in the checks as lowered. Copy propagation for checks would gain nothing here.

## Trap-only check blocks as the default

- Measured: emitting each failed check as a bare trap (`--trap-checks`) instead of a call to the abort helper. Result:
  878,481 to 805,775 instructions (-8%).
- Rejected as a default: the abort message is lost, so a failed check reports nothing but a signal. Kept as an option.
- What would change the answer: a diagnostic that still names the failing location without the call.

## Removing the static call-site minimum from the weak-function rule

- Measured on the Vulkan IR, with the benefit-ranked allowance: minimum of 8 call sites (default), 66 `shared_ptr`
  calls left at 284 MB; no minimum, default allowance, 262 left at 303 MB; no minimum, unlimited allowance, 55 left at
  963 MB.
- Rejected: without a minimum the allowance is spent on single-call helpers, and the unlimited run triples the module
  size, which is the memory problem the module split was meant to bound.
- Kept: the call count as a benefit weight. It is a static count and does not show how often a call runs.

## Unlimited weak-growth allowance

- Measured: 67 `shared_ptr` calls left at 309 MB (node-count threshold), against 67 at 273 MB with the bounded allowance.
- Rejected: the bound costs nothing in calls left and keeps the module near 273 MB.

## Depth limit

- Measured: `--max-depth` 2, 4, 8 and 12 on the same configuration. Results are identical from 4 upward (66 calls left,
  284 MB).
- Rejected: the inliner reaches a fixed point before the limit.

## Exempting selected weak callees from the caller cap

- Measured: 67 to 66 calls left, for +11 MB.
- Rejected: one call for 11 MB.

## Analysis speed as a bottleneck

- Measured: the whole-file analysis takes 46 seconds (parsing 29 s). The slow part was the polling interval used to wait
  for background jobs, not the computation.
- Rejected as an optimization target: no compiler change follows from it.

## Still open

- Exception guard frames around inlined code: 35,875 frame-record stores and 3,594 thread-local reads in the Path B object,
  against 201 stores and no thread-local reads in the gcc object. Not rejected; the next thing to measure, by how many
  frames sit around calls that cannot throw.
