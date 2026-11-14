# Ideas from makepad/relax for nfcxx and bc2cpp

Source: the makepad/relax README and AGENTS.md (a live Rust compiler and JIT, https://github.com/makepad/relax), read
2026-11-14. Its figures are the project's own, measured on an M4 Mac and an 8-core Linux desktop, and were not re-run
here. Relax's point is iteration speed (time to first frame, edit to running program), not the speed of the code it
produces: by its own numbers that code is 1.12x (x64) to 1.24x (arm64) the time of stock `--release`. So the ideas
below are for build and edit loops, and nothing here argues for replacing nfcxx's ahead-of-time backends with a JIT.

## Ideas

### 1. Tiered execution for cold methods (bc2cpp)

Relax compiles each function on its first call (interpreter or O1), recompiles hot ones at O3 in the background, and
swaps them in. bc2cpp compiles the whole closed world ahead of time, and methods it cannot translate stay on the mruby
VM. Keeping the VM as the cold tier and promoting hot methods would cut compile time for large worlds such as
optcarrot. Caveat: `docs/notes/bc2cpp-epoch-method-table.md` argues against one specific lookup optimization; it does
not rule out tiering.

Status: not started. Needs a hot-method profile and a way to swap a method's implementation at run time.

### 2. Per-function (or per-shard) optimization level (bc2cpp)

Relax's `#[relax(O3)]` lets a function ask for a level, and the attribute is a no-op under rustc. bc2cpp could emit
cold code at a lower level and raise only hot kernels. Compile time is a visible cost: about 5.5 s warm for the
optcarrot compiler run, plus the C++ build.

Status: first step done. `BC2CPP_SHARD_COLD_OPT` and `BC2CPP_SHARD_HOT_OWNERS` place a GCC optimize pragma in shards
other than the main file, and keep caller-named hot owners in the main file (`docs/notes/bc2cpp-shard-tiers.md`,
`bc2cpp/scripts/bc2cpp/shard_tiers_check.rb`). Not profiled, not measured on optcarrot. Per-function levels are not
attempted.

### 3. Lazy codegen (bc2cpp)

Relax compiles only what a program calls. If bc2cpp emits every method in the closed world, emitting only methods
reachable from the entry points would shrink the output and the C++ build.

Status: not started. Needs the reachability information the closed-world analysis already computes, checked against
dispatch that can reach methods by name.

### 4. One cache rule: keyed by input hashes (bc2cpp)

Relax keys every cached result by the hashes of its inputs, so a hit is what a fresh compile would produce. bc2cpp has
a source-digested scan cache and a generation cache keyed by Ruby version, sources and header contents. Check that
every cache key covers every input, including sibling sources. The optcarrot profile note already found one
`String#scan` hot spot in the scan path.

Status: not started as an audit.

### 5. Inspectability as a report (bc2cpp)

Relax has `why-slow`, a flight recorder, and per-function version listings. bc2cpp already writes
`generation/coverage.json` (translated methods and fallback reasons). Adding per-method tier, compile time and share of
hot-path samples would make the next optimization decision faster.

Status: partly present (coverage.json). Tier and timing columns not added.

### 6. Per-phase trace of builds (nfcxx)

Relax reports every phase, so a slow build can be explained from its record. nfcxx already has `--trace=t.json`
(Chrome/Perfetto driver steps, `docs/notes/tracing.md`). Adding per-translation-unit and per-backend timings to that
trace is probably the cheapest win here.

Status: not started.

### 7. Background checking (nfcxx)

Relax type-checks each function before it runs and borrow-checks in the background, with `--check-first` to wait
instead. nfcxx's opt-in Path B borrow checker (`docs/notes/pathb-borrowck.md`) could run the same way in an editor or
watch loop, reporting later.

Status: not started.

### 8. Content-hashed per-unit cache (nfcxx)

Relax swaps recompiled functions into a live process; that is a JIT-scale change and I would not copy it. A smaller
step is a per-function or per-translation-unit cache keyed by hashes of the preprocessed input. It matters most for
the large-library tests (`tests/realworld`, `tests/llamacpp`, `tests/coreclr-gc`).

Status: not started. Needs a measurement of how much of the build time these tests spend on unchanged units.

## What not to copy

- A JIT for steady-state speed. Relax's own numbers show its generated code is slower than release builds. nfcxx's
  AOT backends (gcc, qbe, Path B) produce optimized code now.
- Live patching of running programs. It depends on Relax's own runtime, which nfcxx does not have.

## Next steps, in order

1. Profile the optcarrot world (needs Ruby 4.0) and generate a hot-owner list for idea 2.
2. Measure compile time with and without `BC2CPP_SHARD_COLD_OPT` on that world.
3. Add the build phase timings to `--trace` (idea 6).
4. Audit the bc2cpp cache keys against their inputs (idea 4).
