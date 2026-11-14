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

Status: first step done, and measured on optcarrot: no compile-time gain (the tiered build was about 6% slower in three interleaved runs) and no runtime gain established. See docs/notes/bc2cpp-shard-tiers.md.
Earlier wording: first step done. `--shard-cold-opt` and `--shard-hot-owners` (command-line flags) place a GCC optimize pragma in shards
other than the main file, and keep caller-named hot owners in the main file (`docs/notes/bc2cpp-shard-tiers.md`,
`bc2cpp/scripts/bc2cpp/shard_output_check.rb`, its tier section). Not profiled, not measured on optcarrot. Per-function levels are not
attempted.

### 3. Lazy codegen (bc2cpp)

Relax compiles only what a program calls. If bc2cpp emits every method in the closed world, emitting only methods
reachable from the entry points would shrink the output and the C++ build.

Status: present, verified in code. `MainReachability` (tools/bc2cpp/main_reachability.rb) computes the methods
reachable from `main`, and `CodeGen#compile_all` (codegen_emit.rb) compiles only the labels in `live_labels`, so the rest stay
on the VM. Dispatch by name is covered by refusals: a reflection use or another refusal retains the whole program
(`retain all:` in the build log). Not measured: how many methods a full world drops (the optcarrot run compiles 599).

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

Status: partly present (coverage.json), tier and timing added. `generation/coverage.json` now has a `methods` array:
one object per translated method with `entry`, `owner`, `name`, `tier` (the `--shard-cold-opt` level for a method in a
cold shard, else `"default"`) and `compile_seconds` (under `BC2CPP_PROFILE_TIMINGS=1`, else `null`). bc2cpp writes the
same objects as a `== compiled method report ==` section at exit. Share of hot-path samples is still not added.

### 6. Per-phase trace of builds (nfcxx)

Relax reports every phase, so a slow build can be explained from its record. nfcxx already has `--trace=t.json`
(Chrome/Perfetto driver steps, `docs/notes/tracing.md`). Adding per-translation-unit and per-backend timings to that
trace is probably the cheapest win here.

Status: not started.

### 7. Background checking (nfcxx)

Relax type-checks each function before it runs and borrow-checks in the background, with `--check-first` to wait
instead. nfcxx's opt-in Path B borrow checker (`docs/notes/pathb-borrowck.md`) could run the same way in an editor or
watch loop, reporting later.

Status: not present, verified in code. Neither `scripts/pathb-borrowck.rb` nor the driver has a background or watch mode; the
borrow check runs once per invocation (docs/notes/pathb-borrowck.md).

### 8. Content-hashed per-unit cache (nfcxx)

Relax swaps recompiled functions into a live process; that is a JIT-scale change and I would not copy it. A smaller
step is a per-function or per-translation-unit cache keyed by hashes of the preprocessed input. It matters most for
the large-library tests (`tests/realworld`, `tests/llamacpp`, `tests/coreclr-gc`).

Status: largely present. `nfcxx --cache=DIR` (NFCXX_CACHE) keeps each `-c` compile under a key built from its inputs, and
`NFCXX_CACHE_REMOTE=gha` shares the objects through the GitHub Actions cache (docs/notes/cxx-driver.md, "Compile cache").
Not measured: how much of a large library's build time an unchanged unit saves with it.

## What not to copy

- A JIT for steady-state speed. Relax's own numbers show its generated code is slower than release builds. nfcxx's
  AOT backends (gcc, qbe, Path B) produce optimized code now.
- Live patching of running programs. It depends on Relax's own runtime, which nfcxx does not have.

## Next steps, in order

1. Profile the optcarrot world (needs Ruby 4.0) and generate a hot-owner list for idea 2.
2. Measure compile time with and without `--shard-cold-opt` on that world. Done: no gain, see docs/notes/bc2cpp-shard-tiers.md.
3. Add the build phase timings to `--trace` (idea 6).
4. Audit the bc2cpp cache keys against their inputs (idea 4).
