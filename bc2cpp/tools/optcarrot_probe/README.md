# optcarrot / bc2cpp scoping probe

A scoping investigation, not a shipped tool: how much of
[optcarrot](https://github.com/mame/optcarrot) (the pure-Ruby NES emulator
used as a Ruby-implementation benchmark) runs under this project's own
vendored mruby, as a candidate stress test for `tools/bc2cpp`. It does not
touch the RPG engine's build, gems, or bc2cpp's own closed-world registry --
except for two real mruby core fixes (points 4 and 5 below), which do.

optcarrot's own source lives in the `3rd/optcarrot` submodule (real upstream
history, its own `LICENSE`) rather than a bundled copy in this directory.

## Result

optcarrot's headless benchmark (`--benchmark`, `examples/Lan_Master.nes`, 180
frames, `:none` video/audio/input drivers) runs to completion under mruby,
using its real, unmodified upstream source, and produces the exact same
checksum as unmodified CRuby (`59662`), so the emulation itself is
behaviorally correct, not just crash-free.

Latest local 180-frame wall times from the comparative runner: CRuby 3.13s
(57.5 frames/s), interpreted mruby 26.92s (6.7 frames/s), and bc2cpp 29.72s
(6.1 frames/s). All three produce checksum `59662`. Timings vary by machine;
CI publishes each run's numbers and relative slowdown in the job summary. The
compiled result is still slower than interpreted mruby, but compiling PPU
helpers reduced the compiled time from 30.53s in a same-machine control run
with the PPU wholly interpreted to 29.72s here.

Getting there took:

1. Concatenating optcarrot's 9 core files (`optcarrot.rb`, `nes.rb`, `rom.rb`,
   `pad.rb`, `opt.rb`, `cpu.rb`, `apu.rb`, `ppu.rb`, `palette.rb`,
   `driver.rb`, `config.rb`) in real dependency order in place of
   `require_relative`, which mruby doesn't have (`build_bundle.rb`).
2. Five small pure-Ruby shims (`shims.rb`, ~30 lines) for mruby stdlib gaps:
   - `File.binread` -- missing; trivially backed by `IO.read(path, mode: "rb")`.
   - `Integer#[]` (bit read, e.g. `n[3]`) -- missing everywhere in mruby core
     and every bundled gem.
   - `Hash#compare_by_identity` -- missing; shimmed with a real identity-keyed
     (`object_id`-based) `[]`/`[]=`, not a value-equality stand-in (a naive
     alias would silently change semantics -- verified correct via the
     checksum match).
   - `Process.clock_gettime` / `Process::CLOCK_MONOTONIC` -- mruby has no
     `Process` module at all; shimmed with `Time.now`, which is *not* truly
     monotonic (only used for optcarrot's own FPS counter, not emulation
     correctness).
   - `String#sum` (checksum helper) -- missing; reimplemented per its
     documented default (16-bit sum of byte values).
3. `Regexp`, which is entirely absent from mruby core (`opt.rb` needs it just
   to load, for two regex-literal constants) -- solved by pulling in
   `3rd/mruby-onig-regexp`, which this project already vendors for its own
   build.
4. **A real mruby core fix**, `../../patches/mruby-module-function-scope.patch`,
   applied to `3rd/mruby` the same way (and with the same script,
   `scripts/apply_mruby_patch.bash`) as this project's other
   `patches/mruby-*.patch` files, and wired into the project's real build via
   `cmake/build-mruby.cmake` -- this one is not probe-only. Bare
   `module_function` (the "everything defined from here on becomes a module
   function" scope form, called with no arguments) was a literal no-op stub
   in mruby's own C source (`src/class.c`, `mrb_mod_module_function`: `if
   (argc == 0) { /* set MODFUNC SCOPE if implemented */ return mod; }` --
   explicitly unimplemented upstream), which `driver.rb`, `palette.rb`, and
   `driver/misc.rb` all use. The fix reuses mruby's own existing
   private/protected/public scope-tracking mechanism plus a previously
   unused/documented-ZERO bit in `mrb_callinfo.vis`/`REnv.flags`, and the
   same proc-sharing "install into a second class's method table" technique
   `module_function`'s already-working explicit named-method-list form used.
   Verified against mruby's own full bundled mrbtest suite (1874 OK / 0 KO,
   identical before and after) and against optcarrot's real, unpatched
   `driver.rb`/`palette.rb` directly (no source patch on optcarrot's side
   needed any more). See the patch file's own preamble for the full
   trail -- checked there first: is not implementable as a self-contained
   stub, since CRuby's true semantics require installing a *second* method
   (a public singleton copy) alongside the original, not just resolving one
   more visibility state.
5. **A second real mruby core fix**, `../../patches/mruby-parser-dump-back-nth-ref.patch`,
   also wired into `cmake/build-mruby.cmake`. `mrbc -v`'s own parse-tree dump
   printed garbage -- including, for optcarrot's real
   `lib/optcarrot/opt.rb:74` (`$1`/`$'`), an invalid UTF-8 byte -- for a
   `$&`/`` $` ``/`$'`/`$+`/`$1`/`$2`/... node, because its debug-print code
   read a raw AST-node pointer as if it were the node's own stored value
   instead of the real field (`node_to_int(tree)` vs. `back_ref_node(tree)
   ->type`/`nth_ref_node(tree)->nth` -- see the patch's own preamble).
   Debug-dump-only (mrb_parser_dump is never called from the real compiler
   path, so this changes no compiled bytecode), but `tools/bc2cpp/bc2cpp.rb`
   reads exactly that dump text and crashed outright on it -- this is what
   `bc2cpp_probe.rb` (below) needed to run at all. Same mrbtest verification
   as point 4.

Confirmed *not* a problem: the default (non-`--opt`) code path -- the actual
CPU/PPU emulation hot loop -- never calls `eval`/`send`/`define_method`; those
only appear behind optcarrot's own `--opt` runtime-codegen feature, which
this probe doesn't enable and a bc2cpp target wouldn't need either.

## bc2cpp coverage

`bc2cpp_probe.rb`/`optcarrot_bc2cpp_coverage_report.rb` run
`tools/bc2cpp/bc2cpp.rb` against optcarrot's own real source
(`3rd/optcarrot/lib`, unmodified) as its own standalone closed world --
entirely separate from bc2cpp's real registry (the RPG engine's own 3
compiled gems), same NATIVE_SRCS/FOREIGN_RUBY_SRCS inputs
`scripts/bc2cpp_coverage_report.rb` feeds the real one, and the same
method-level attempted/compiled-clean/`#error`-reason parsing logic reused
directly from that script. CI publishes the full report in the build job
summary alongside the real project's report, keeping generated coverage
output out of git. To print it locally after a bc2cpp.rb change, run
`MRBC=path/to/host/mrbc ruby
tools/optcarrot_probe/optcarrot_bc2cpp_coverage_report.rb`.

**Result: 383/383 methods (100.0%) compile clean**, up from an initial
92.2% baseline (measured with zero bc2cpp code changes) after seven real
`tools/bc2cpp/bc2cpp.rb` fixes landed alongside this probe (all verified
inert for the real project -- see below):

1. **`SUPER_TARGETS` gained 5 entries**: `Optcarrot::APU::{Pulse,Triangle,
   Noise}#reset`/`#active?`. Their bare `super` disassembles to `SUPER R2
   n=0` -- the exact already-supported shape this allowlist already covers
   for the real project's own `RPG2k3::Scene::Battle` methods -- into
   `Optcarrot::APU::Oscillator#reset`/`#active?`, which already compiled
   clean. Added only after the same due-diligence the existing entries
   document: grepped every real `.reset`/`.active?` call site in
   `3rd/optcarrot/lib` (none pass a block literal) and every real
   `include`/`prepend` in the whole closed world (2 total, both
   `include CodeOptimizationHelper`, unrelated to APU). `#initialize`/
   `#poke_0`/`#poke_3` deliberately NOT added: their own bare `super`
   disassembles to `SUPER Ra n=*` (a zsuper forwarding multiple explicit
   params via an ARGARY-built array) -- a real, different, still-
   unimplemented opcode shape, not a fact this allowlist gates at all.
   (Superseded for that zsuper shape by ADR 0159's general `SUPER` support.)
2. **A new `INTERN` opcode case**, unconditional (unlike `SUPER_TARGETS`,
   no whole-program fact to verify -- `OP_INTERN` is a pure, always-safe
   in-place String->Symbol conversion, `src/vm.c`'s own `mrb_ensure_
   string_type` + `mrb_intern_str`). optcarrot's `opt.rb` builds symbols
   dynamically (`:"#{...}"`-shaped); this is a genuine new bc2cpp
   capability, not optcarrot-specific, so it's unconditional the same way
   the pre-existing `STRCAT` case is.
3. **`BLOCK_FALLBACK_UPVAR_SAFE_METHODS` gained 12 entries**:
   `gsub gsub! sub sub! scan` (String), `each_value` (Hash), `with_index`
   (Enumerator), `step` (Numeric), `zip` (Enumerable/Enumerator). Each is a
   synchronous, never-stores-the-block receiver (same shape as every existing
   entry), so a block that captures an enclosing-method upvar passed to one of
   them is safe to compile through the same cfunc-backed-RProc fallback
   `each`/`map`/`flat_map` already use. This claims every remaining
   `BLOCK`/`SENDB` region in the probe (`CodeOptimizationHelper`'s and
   `OptimizedCodeBuilder`'s `gsub`/`scan`/`sub`/`map.with_index` codegen
   methods, `Config::Parser#find_option`'s `each_value`, `PPU::OptimizedCodeBuilder#
   parse_clock_handlers`'s `step`), so BLOCK_FALLBACK coverage goes 49 -> 72
   and the whole `unhandled opcode BLOCK`/`SENDB` bucket drops to zero. Safety
    was checked the way the list's own comments demand: a whole-program grep
    found no `def` of any of these names in this project's own sources that
    stores its block, `mruby-enum-lazy` (the `Lazy#zip`/`Lazy#with_index` twin)
    is not built, and `scripts/bc2cpp_coverage_report.rb`'s real-project output
    is **byte-identical** with and without the change. See that array's own
    comment for the per-name argument.
4. **KEYWORD_HASH_POSITIONAL_SUPPORT's own gate relaxed** off
   `pure_mandatory_arity?` to a new `keyword_hash_positional_callee?`, so a
   keyword call site whose callee declares NO keyword params but does take an
   `= default` optional positional compiles too. The trailing-Hash-as-positional
    translation is sound for any callee whose ENTER `kd == 0` (vm.c OP_ENTER's own
    arm), so an `opt` slot is fine -- the packed Hash simply lands in it, exactly
    as Ruby hands `foo(k: v)` to `def foo(a, b = 1)`; only the callee's key/kdict
    fields and an out-of-range positional count are refused. This closes
    `PPU::OptimizedCodeBuilder#batch_render_pixels`'s
    `expand_methods(fastpath, render_pixel: gen(...))`; real-project
    `scripts/bc2cpp_coverage_report.rb` output stays byte-identical.
 5. **`ENSURE_DISPATCH_MERGE_SUPPORT`**: `recognize_ensure_region` now accepts
    one jump shape it used to reject outright -- one from *inside* the
    protected range whose target is exactly the handler's own address.
    That's mrbc's `dispatch` tail-merge: when the protected body's last
    statement is conditional, its branch's normal exit jumps onto the
    ensure region (`NES#run`'s `if ... end` right before `ensure dispose
    end` compiles to `117 JMP 122` against `catch type: ensure begin: 0004
    end: 0122 target: 0122`). On the VM such a jump runs the ensure body
    inline and continues past the RAISEIF; the RAII model's exact
    equivalent is `goto L<raiseif_addr>` -- leaving the guard scope (which
    runs the ensure body) and landing on a label compile_method now emits
    just after it, which the suppressed handler range would otherwise have
    left dangling. Jumping *out* of a C++ scope via `goto` is legal and
    runs the destructor (only jumping in is not), and the remap is keyed
    on the irep object, so a nested block's same-numbered child-irep
    address can never be re-pointed. Jumps from outside the range onto the
    handler address are now explicitly rejected (previously they slipped
    through the crossing test's parity check toward exactly such a dangling
    label; mrbc never emits one). This closes `NES#run`'s
    `unhandled opcode EXCEPT` -- `NES#run` itself still stays one honest
    `#error` short of compiling, for its foreign `StackProf.start` keyword
    site named in the remaining-gaps paragraph below.
 6. **`KEYWORD_HASH_LEXICAL_SELF_SUPPORT`**: when KEYWORD_HASH_POSITIONAL's
    every-registry-def gate declines -- optcarrot's `PPU#initialize`'s
    `reset(mapping: false)` is exactly the `:close_message` case its own
    comment describes: every *other* `#reset` in the closed world (NES/CPU/
    APU/Pads) is 0-arg, so no 1-positional arity agrees program-wide -- the
    path retries against the single def this site can actually reach: an
    implicit-self send inside a `PPU` method whose owner `lexical_self_
    keyword_target` proves subclass-free, compiled-clean and not
    runtime-installed can only ever reach `PPU#reset`, which IS a clean
    `def reset(opt = {})`. The `mrb_funcall(self, "reset", 1, hash)` that
    gets emitted resolves at runtime to exactly the def that was proven
    reachable. Same selector and guards as LEXICAL_SELF_KEYWORD_SUPPORT,
    applied to the hash-as-trailing-positional path; `PPU#initialize`
    compiles clean (and, secondarily, newly shipping it unpoisons
    ClassLayout's `@vram_addr_inc`-style fixnum embedding across the PPU
    methods -- the probe's dynamic-dispatch site count actually *drops*
    114→107 for `:==`), and the report's method-level coverage goes
    381→382.
7. **`KEYWORD_NEVER_DEFINED_CONST_RECEIVER_SUPPORT`**: when every
    keyword-free proof declines -- optcarrot's `NES#run`'s
    `StackProf.start(mode:, out:, raw:)` is the case the remaining-gap
    paragraph below used to name: every `#start` def in the closed world
    is one this site cannot reach, so no arity agrees -- the path proves
    the site dynamically unreachable instead. `StackProf` is defined
    NOWHERE in this closed world (no SETCONST/SETMCNST, no CLASS/MODULE,
    no native `mrb_define_const`/`const_set`/`define_class`/
    `define_module`, no foreign-source assignment -- the closed-world
    universe `IntegerConstants.defined_name_universe`), so the GETCONST
    the receiver register provably holds raises NameError before the send
    can execute (no jump or handler entry lands between the two), and what
    gets emitted is the faithful OP_SEND shape anyway (keyword pairs
    packed into one trailing positional Hash, ordinary dynamic dispatch)
    so a hypothetical proof break shows a wrong-but-well-formed send.
    Tried last so it can never pre-empt an existing path; the report's
    method-level coverage goes 382→383, i.e. 100%.

Both hot-path entry points compile clean with real devirtualization already
firing -- `CPU#run` (the fetch/dispatch loop) gets a direct C++ call for
`do_clock`, proven monomorphic program-wide (`LEXICAL_SELF`); `PPU#run`
(the pixel-rendering loop, itself built on a `Fiber` internally) correctly
falls back to real dynamic dispatch only where the receiver's class
genuinely isn't known (`POLY :loglevel`) and to a wrapped-cfunc block
fallback for its one `Fiber.new { ... }` block.

No errored methods remain: 383/383 compile clean (100.0%), zero `#error`
markers. The last site to close was `NES#run`'s
`StackProf.start(mode:, out:, raw:)` keyword call on a receiver this
closed world knows nothing about (`StackProf` is loaded by a runtime
`require "stackprof"` that mruby can never service) -- closed by point 7
above, which proves the send dynamically unreachable rather than packing
against a callee that does not exist. Packing the keyword pairs into a
trailing positional Hash would have been sound only if the
(never-existing, here) callee declared no keyword parameters, and mruby
4.0.0's C API has no keyword-carrying funcall to reach an unknown callee
faithfully otherwise -- neither of those routes was taken; the
unreachability proof was. (`NES#run`'s former `EXCEPT` marker and
`PPU#initialize`'s whole keyword site were closed by points 5 and 6.)

A third fix closed the two keyword sites whose callee is keyword-free but
takes an `= default` optional positional (`PPU#initialize`'s sibling
`expand_methods(code, mdefs, meths = …)` at
`batch_render_pixels`): KEYWORD_HASH_POSITIONAL_SUPPORT's own gate was
relaxed off `pure_mandatory_arity?` to `keyword_hash_positional_callee?`,
which only requires ENTER's key/kdict fields (the real `kd == 0` vm.c's
OP_ENTER keys on) to be zero plus `total` inside the callee's accepted
positional range. The packed Hash then lands in the callee's next free
positional slot exactly as Ruby hands `foo(k: v)` to `def foo(a, b = 1)`.
Real-project `scripts/bc2cpp_coverage_report.rb` output stays byte-identical.

**Verifying "no regression to the real project"**: both fixes above touch
shared code (`tools/bc2cpp/bc2cpp.rb`), so before landing either, this
probe's own `mrbc` (imperfect -- missing several of `3rd/mruby`'s other
real patches, see `mruby_build_config.rb`) was used to run
`scripts/bc2cpp_coverage_report.rb` against the *real* project's closed
world twice with the *same* binary -- once with the bc2cpp.rb change, once
without (`git stash` on just that file) -- and the raw output diffed
directly. `SUPER_TARGETS`' new entries are exclusively `Optcarrot::...`-
namespaced, so this diff is byte-identical by construction; `INTERN`'s new
support diffed identical too (the real project's own code doesn't
currently build any symbol dynamically). This sidesteps needing this
sandbox to reproduce the real project's exact pinned toolchain (its own
`gperf`/`bison` versions) just to regenerate the real-project coverage report
for comparison -- which was tried first and produces spurious diffs
(different `mrbc` binary, not a real behavior change) rather than genuinely
mismatching output. Points 5, 6 and 7 were verified the same way, one step
stronger: not just the stats report but the REAL project's full raw
whole-program diagnostic (both runs' stdout and stderr, and the
`SKIP_UNSUPPORTED=1` shipped run's compiled-method set) diffed byte-
identical with and without the change. All three new paths are reject-then-
retry additions by construction -- they only ever run where the existing
gates already said no -- and neither ensure region the real project
actually recognizes (`Game::Battle#deal_attack`, `RGSS#audio_probe`) has a
jump onto its handler address, which is why the diff is empty rather than
merely small.

Not yet attempted: checking whether the 383 "compiled clean" methods
produce *correct* output (this only confirms bc2cpp's own compiler accepted
them without a `#error`, the same bar the real-project coverage report's own
numbers measure for the real project -- not that the generated C++ was run
and its output checked against CRuby/mruby's own, the way the
headless-benchmark checksum above verifies the *interpreted* path). The
keyword `SEND` whose receiver's class the closed world cannot see at all
(`NES#run`'s `StackProf.start`) is closed by point 7's unreachability
proof -- not by packing against a callee (no def to prove keyword-free)
nor by a keyword-carrying C-API call (mruby 4.0.0 has no such API --
`mrb_funcall` sets `ci->nk = 0`), neither of which can be sound there.

## Compiled runtime check

`compiled_run.rb` builds an isolated mruby binary with bc2cpp's generated
methods installed, then runs the same headless checksum benchmark. The first
run exposed two runtime correctness gaps despite all methods compiling
cleanly:

- A C function backed block with two parameters raised on mruby's `Hash#each`,
  which passes one `[key, value]` array. bc2cpp now applies the same array
  destructuring and lenient argument handling as an ordinary multi-parameter
  block.
- A base and subclass could each get a separate embedded ivar struct, but an
  mruby object has only one `DATA_PTR`. Their generated initializers replaced
  one struct pointer with the other. bc2cpp now keeps both layouts in normal
  instance variables when an embedded layout overlaps an inheritance chain.

With those fixes, the 180-frame run completes with checksum `59662`, matching
the interpreted run and CRuby. CI still showed SIGSEGVs after excluding CPU,
PPU, and the explicit NES Fiber boundaries, so the probe compiles setup
methods on `Optcarrot::Config` and `Optcarrot::Opt`, plus
`Optcarrot::ROM#initialize` before emulator Fibers start. Emulator runtime
methods remain interpreted until generated C functions are safe across mruby
Fiber switches. The benchmark still uses upstream emulation logic; only the
method registration set changes. It runs the same ROM and checksums under all
three systems; CRuby omits only the mruby-specific compatibility shims.

## Profiling notes

`perf` sampling is unavailable in the current environment (`perf_event_paranoid`
is 4), so I profiled both mruby modes with GCC `gprof` instead:

```
GPROF=1 GPROF_OUTPUT=/tmp/optcarrot-gprof MRBC=3rd/mruby/build/host/bin/mrbc \
  ruby tools/optcarrot_probe/compiled_run.rb 180
```

The instrumented runs took 54.24 seconds interpreted and 67.79 seconds with
bc2cpp. `-pg` roughly doubles runtime, so those absolute times are profiler
overhead; the relative result is close to the uninstrumented run. The
interpreted profile spent 34.2% in `mrb_vm_exec`, 13.8% in GC's
`gc_gray_rescan`, and 16.7% in ivar lookup (`iv_bsearch_idx`). The bc2cpp
profile spent 20.8% in `mrb_vm_exec`, 34.0% in `gc_gray_rescan`, and 11.0% in
`iv_bsearch_idx`. `mrb_funcall_with_block` calls rose from 547K to 17.2M,
and `mrb_vm_exec` calls rose from about 363K to 3.04M with bc2cpp. `CPU#run`
itself accounted for only 0.13% of sampled time.

This points to two limits: the PPU's Fiber-driven hot loop stays interpreted,
and compiled methods still cross into mruby through dynamic and block-carrying
calls. Those crossings leave substantial VM activity and coincide with much
more GC time, outweighing the bytecode dispatch removed from the compiled CPU
path. The profile is a direction, not a precise causal split: gprof sampling
and instrumentation are coarse, and the gprof build disables inlining only
for generated C++ methods to keep them visible; mruby's C runtime keeps its
normal optimization settings in both profiles.

The first concrete dispatch target is `CPU#run`: each opcode executes
`send(*DISPATCH[@opcode])`. bc2cpp emits that dynamic splat as
`mrb_funcall_argv`, and the compiled `CPU_run_impl` reaches it about 1.77
million times in the instrumented 180-frame run. Overall, `mrb_funcall_argv`
is called 13.6 million times and `mrb_funcall_with_block` 17.2 million times
in the compiled profile. A generated 256-way opcode case was tested and
discarded: on this machine, the 180-frame interpreted run slowed from about
25 seconds to 65 seconds. The profile also shows 6.1 million
`mrb_ary_splat` calls and a rise in GC gray rescans from
1,586 to 3,455; these are additional measurements to revisit after dispatch
overhead is reduced, not proof that it causes the GC increase.

`build_bundle.rb` now rewrites this one call in the generated optcarrot bundle
to dispatch by fixed positional arity (one through four). mruby's
`mrb_ary_splat` duplicates Array inputs, so this removes one temporary Ruby
Array from each interpreted CPU opcode while preserving the dispatch table
and dynamic `send` lookup. The rewrite fails if upstream changes or removes
the expected call. The 180-frame interpreted run still returns checksum
`59662`; the observed optcarrot FPS was 8.89 before and 8.91 after on this
machine, so this change targets allocation and GC pressure rather than a
measurable speedup. bc2cpp already sends a runtime splat's backing array
directly to `mrb_funcall_argv`, so its compiled CPU path does not gain this
allocation reduction.

bc2cpp also lowers the mapper's three-argument `Array#[]=` slice writes to
the public `mrb_ary_splice` API when the receiver is an exact Array and both
indices are fixnums. All other receiver and index shapes keep Ruby dispatch.
The runtime guard preserves Array subclasses and index coercion, and the
generated method returns the replacement value just like `Array#[]=`. The
coverage report counts these emitted fast paths so upstream source changes
remain visible.

The ROM loader's two-argument `Array#slice!` calls also have a guarded fast
path for an exact, unfrozen Array, a zero start, and a nonnegative fixnum
length. It copies the removed prefix with `mrb_ary_new_from_values`, removes
it with `mrb_ary_splice`, and returns the copied Array. Frozen receivers,
subclasses, and all other index shapes retain Ruby dispatch. The coverage
report counts these sites too. These calls run while loading the ROM, so the
optimization targets setup dispatch overhead rather than frame time.

The compiler also includes `mruby/numeric.h` in generated C++, required for
its integer and float conversion helpers.

## Files

- `build_bundle.rb` -- assembles a single runnable mruby script: applies
  `patches/mruby-module-function-scope.patch` to `3rd/mruby` (via
  `scripts/apply_mruby_patch.bash`, idempotent -- a safety net; the real
  build order below applies it before building mruby, not after), then
  concatenates `3rd/optcarrot`'s 9 core files (in the real dependency order,
  `require_relative` lines stripped since the concatenation IS the loading)
  between `shims.rb` and `runner_tail.rb`. Nothing under this directory
  hardcodes optcarrot's content -- output isn't checked in since it's fully
  mechanical to regenerate, and stays in sync with whatever commit
  `3rd/optcarrot` is pinned to.
- `shims.rb` -- the 5 stdlib shims, prepended to the bundle.
- `runner_tail.rb` -- headless `Optcarrot::NES.new(...).run` driver, appended
  to the bundle.
- `bc2cpp_probe.rb` -- runs `tools/bc2cpp/bc2cpp.rb` against optcarrot's real
  source as its own closed world and prints the method-level coverage
  breakdown above (`MRBC=path/to/host/mrbc ruby
  tools/optcarrot_probe/bc2cpp_probe.rb`). Self-applies
  `patches/mruby-parser-dump-back-nth-ref.patch` to `3rd/mruby` as a safety
  net, same caveat as `build_bundle.rb`'s own patch step (only actually
  fixes anything if MRBC hasn't been built yet from this checkout).
- `mruby_build_config.rb` -- the `MRUBY_CONFIG` used to build a probe-only
  `mruby`/`mrbc` host binary (full-core gembox + `mruby-onig-regexp`). Not
  part of the project's real build.
- `compiled_run.rb` -- builds an isolated bc2cpp-enabled mruby and runs the
  headless checksum benchmark; build artifacts stay in a temporary directory.
- `../../patches/mruby-module-function-scope.patch`,
  `../../patches/mruby-parser-dump-back-nth-ref.patch` -- see points 4 and 5
  above; both *are* part of the project's real build.

## Reproducing

```
git submodule update --init --depth 1 3rd/mruby 3rd/mruby-onig-regexp 3rd/optcarrot
# Needs oniguruma headers -- on Debian/Ubuntu: apt-get install libonig-dev
# (otherwise mruby-onig-regexp falls back to a slow bundled onigmo build)

./scripts/apply_mruby_patch.bash 3rd/mruby "$(pwd)/patches/mruby-module-function-scope.patch"
./scripts/apply_mruby_patch.bash 3rd/mruby "$(pwd)/patches/mruby-parser-dump-back-nth-ref.patch"
cd 3rd/mruby
MRUBY_CONFIG=$(pwd)/../../tools/optcarrot_probe/mruby_build_config.rb rake -j"$(nproc)"
cd -

# Run the actual emulation (needs both patches above):
ruby tools/optcarrot_probe/build_bundle.rb /tmp/full_probe.rb
./3rd/mruby/bin/mruby /tmp/full_probe.rb 3rd/optcarrot/examples/Lan_Master.nes 180

# bc2cpp coverage (needs only the parser-dump patch above):
MRBC=3rd/mruby/bin/mrbc ruby tools/optcarrot_probe/bc2cpp_probe.rb
MRBC=3rd/mruby/bin/mrbc ruby tools/optcarrot_probe/optcarrot_bc2cpp_coverage_report.rb
# Run the compiled headless checksum benchmark in a temporary build:
MRBC=3rd/mruby/bin/mrbc ruby tools/optcarrot_probe/compiled_run.rb
# Profile both mruby modes with gprof (requires GCC/binutils gprof):
GPROF=1 GPROF_OUTPUT=/tmp/optcarrot-gprof MRBC=3rd/mruby/bin/mrbc ruby tools/optcarrot_probe/compiled_run.rb 180
```
