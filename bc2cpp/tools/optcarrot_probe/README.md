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

Latest local 180-frame wall times from the comparative runner: CRuby ~4.9s,
interpreted mruby ~59-60s, and bc2cpp ~63-67s (varies by machine); CI
publishes each run's numbers and relative slowdown in the job summary. All
three produce checksum `59662`. `compiled_run.rb` compiles and installs
`Optcarrot::Config`, `Optcarrot::Opt`, `Optcarrot::CPU`, `Optcarrot::NES`, the
`Optcarrot::ROM` setup methods, and the post-Fiber `Optcarrot::Video#tick`/
`Optcarrot::APU#flush_sound`/`#vsync` hooks. `Optcarrot::PPU` alone stays
excluded, for its own separate, unrelated `Fiber.new` bug (see "Compiled
runtime check" below). The other four were excluded too for a while, for a
real, CI-reproducible SIGSEGV in bc2cpp's own generated code for
`Array#last` -- see that section's own "Update (ARY_PTR/ARY_LEN root cause)"
for the actual bc2cpp code-generation bug this was root-caused and fixed to,
and why they are back.

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

The generated Optcarrot build lowers two-argument `Array#[]` sends to a
guarded Array copy when runtime checks confirm an exact, unshared base Array
and a Fixnum slice length from 0 through 10. This matches mruby's own copy
path; larger or shared slices retain Ruby dispatch and mruby's shared-storage
optimization. Other receiver types, index types, and arities also retain Ruby
dispatch; the CI coverage report counts the emitted sites.

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
the interpreted run and CRuby.

CI once showed SIGSEGVs when `Optcarrot::CPU`, `Optcarrot::PPU`, and the
explicit `Optcarrot::NES` Fiber boundaries ran compiled, so the probe used to
compile only `Optcarrot::Config`/`Optcarrot::Opt` plus a handful of setup and
frame-boundary methods, and left CPU's opcode dispatch and the whole PPU Fiber
loop interpreted. That is no longer reproducible: the same three classes --
CPU (`#run` and every `op_*` opcode handler), PPU (`#run`, the Fiber body
itself, `#sync`, and every helper it reaches), and NES (`#run`/`#step`
/`#dispose`, the Fiber's creator and resumer) -- now run the full 180-frame
headless benchmark compiled, individually and together, repeatedly, with the
same `59662` checksum as the interpreted and CRuby runs every time. `bc2cpp`
gained many correctness fixes since the SIGSEGVs were last observed (the two
above, plus everything landed since -- see `git log` on
`tools/bc2cpp/bc2cpp.rb`); no single change was bisected as the fix, so this
is a re-verified fact, not a root-caused one. `compiled_run.rb` now compiles
all five: `Optcarrot::Config`, `Optcarrot::Opt`, `Optcarrot::CPU`,
`Optcarrot::PPU`, `Optcarrot::NES`, plus the same
`Optcarrot::ROM.singleton#load`/`Optcarrot::ROM#initialize` setup methods,
`Optcarrot::PPU#setup_frame` (now redundant with the rest of `PPU` also
compiling, kept for clarity), and the post-Fiber `Optcarrot::Video#tick` and
`Optcarrot::APU#flush_sound`/`#vsync` hooks. `Optcarrot::Video` and
`Optcarrot::APU` stay interpreted apart from those two hooks.

**Update (gc_gray_rescan investigation session)**: re-running this exact
configuration to reproduce the gray_rescan numbers cited below found two real,
100%-reproducible regressions in this bc2cpp.rb/mruby state -- distinct from
the historical SIGSEGV this section spent so much text re-verifying wasn't
happening, and distinct from each other:

1. **A null-`DATA_PTR` segfault**, `gdb`-confirmed at `Optcarrot::APU#reset`'s
   `((Optcarrot__APU_ivars*)DATA_PTR(self))->cycles_ratecounter = ...`. bc2cpp's
   whole-program ivar-embedding analysis now proves `Optcarrot::APU`'s (and
   `APU::DMC`'s) ivars embeddable, so `emit_register`'s `embeds` list applies
   `MRB_SET_INSTANCE_TT(APU_class, MRB_TT_DATA)` to every `APU` instance --
   but `Optcarrot::APU#initialize` was never in `FIBER_SAFE_OWNERS` (`APU`
   itself never was, only its `flush_sound`/`vsync` frame-boundary hooks), so
   `APU.new`'s dynamic-dispatch `#initialize` call ran the ordinary
   interpreted bytecode, which has no notion of the embedded struct and never
   calls `mrb_data_init`. `DATA_PTR(self)` stays the null pointer
   `mrb_obj_alloc` leaves it at, and `NES#reset`'s devirtualized (direct C++,
   no dynamic dispatch, so registration status never entered into it) call
   into the compiled `Optcarrot__APU_reset_impl` dereferences it immediately.
   **Fixed** in `compiled_run.rb`: `emit_register` now installs every
   compiled method of any class the `embeds` diagnostic names, not just
   `FIBER_SAFE_OWNERS`' hand-picked subset, so an embedded class's instances
   are always constructed (and always operated on) through compiled,
   struct-aware code -- the same invariant `FIBER_SAFE_OWNERS` already gave
   `CPU`/`PPU`/`NES` by installing all of their own methods together, just
   computed from the same source bc2cpp's own embedding proof already
   is, instead of tracked by hand.
2. **A always-raising `FiberError`** once (1) stopped masking it: `PPU#run`'s
   `@fiber ||= Fiber.new { ... }` compiles its block through the same
   `BLOCK_FALLBACK` path every other block literal uses
   (`emit_block_fallback_glue`), wrapping it as a cfunc-backed `RProc` via
   `mrb_proc_new_cfunc_with_env` -- fine for `each`/`map`/`sub`/... (none
   check the RProc's own kind), but mruby's `Fiber.new`
   (`mrbgems/mruby-fiber/src/fiber.c`'s `init_fiber`) explicitly checks
   `MRB_PROC_CFUNC_P(p)` and raises `FiberError: tried to create Fiber from C
   defined method` rather than dereference a `body.irep` a cfunc-backed proc
   doesn't have. Deterministic C logic, not a timing-dependent crash: every
   180-frame run with `PPU` compiled hits it the instant `PPU#run` first
   runs, gprof build or not. **Not fixed** -- needs bc2cpp to emit a real,
   bytecode-backed `Proc` for a block specifically passed to `Fiber.new` (or
   to recognize that shape and decline to devirtualize into the method that
   creates it), a `tools/bc2cpp/bc2cpp.rb` code-generation change out of this
   session's own scope. `compiled_run.rb` excludes `Optcarrot::PPU` from
   `ONLY_OWNERS` entirely again (not just from `FIBER_SAFE_OWNERS` --
   devirtualization reaches a compiled `_impl` regardless of whether
   `emit_register` ever installs it, so leaving `PPU` compiled-but-
   uninstalled would not have avoided this) until that lands and gets the
   same re-verification `CPU`/`NES` did above.

With both changes, `compiled_run.rb`'s 180-frame run is back to completing
cleanly (`Optcarrot::Config`, `Optcarrot::Opt`, `Optcarrot::CPU`,
`Optcarrot::NES`, `Optcarrot::APU`, `Optcarrot::APU::DMC`, `Optcarrot::Pad`,
and `Optcarrot::ROM` compiled and installed -- 198 methods locally, vs. this
section's earlier ~92% baseline and the since-lost "all three" figures above
-- `Optcarrot::PPU`/`Optcarrot::Video` interpreted), checksum `59662` on all
three runtimes, same as every number in this file. It is neither confirmation
nor contradiction of this section's own "all three run compiled" claim above
for `Optcarrot::PPU` specifically -- that configuration is currently broken
by bug 2, full stop, regardless of bug 1 -- so treat this section's own
PPU-compiled numbers as historical (true when written, not currently
reproducible) rather than re-verified.

**Update (FIBER_NEW_BLOCK_UNSAFE_SUPPORT session)**: bug 2's own "needs
bc2cpp to emit a real, bytecode-backed Proc... (or to recognize that shape
and decline to devirtualize into the method that creates it)" is now half
done -- the second, narrower option, not the first. `tools/bc2cpp/bc2cpp.rb`'s
`recognize_block_fallback_regions` (the generic `BLOCK_FALLBACK` recognizer
every block-carrying call site not otherwise special-cased goes through)
now refuses to admit a `Fiber.new { ... }` call site as a region at all: a
bare `GETCONST ... Fiber` feeding an explicit-receiver `SENDB :new`,
matched by the same short backward-register-walk `IvarLayout.trace_type`
already uses elsewhere in this file. An unclaimed `BLOCK`/`SENDB` pair
falls through unchanged to `compile_insn`'s pre-existing, honest `#error
unhandled opcode BLOCK` -- so `SKIP_UNSUPPORTED=1`'s own established "a
method whose generated code contains a `#error` marker anywhere is dropped
whole" mechanism now does exactly what emitting a real bytecode-backed Proc
would have done, with none of the new machinery that would need (embedding
raw irep binary data into the generated program, getting mruby's binary
irep format exactly right across every target this compiler ships to).
Verified directly: with `BC2CPP_SELF_REGISTERING=1` and `PPU` scanned as
part of the whole program, `Optcarrot::PPU#run` -- and *only* `PPU#run` --
now carries the `#error` marker (`optcarrot_bc2cpp_coverage_report.rb`'s
own count: 1 of 383 methods left on the interpreter, down from 0 before
this change only because this is the first time `PPU` was ever scanned
with `BC2CPP_SELF_REGISTERING=1` at all); all 15 `scripts/bc2cpp_*_check.rb`
static checks still pass, and the real project's own 3 compiled gems are
unaffected (no `Fiber.new` call site exists anywhere in
`mruby-lcf-compiled`/`mruby-rgss-compiled`/`mruby-rpg2k-compiled`'s own
`mrblib`, confirmed by grep, so this is currently a no-op there -- a
defensive fix for whenever/if that pattern ever appears, not something
with observable effect on the real project today).

That alone is **not enough** to let `compiled_run.rb` re-admit `Optcarrot::
PPU` to `ONLY_OWNERS`, though -- tried it, against this exact fix, and hit
a *second*, different crash: `resuming dead fiber (FiberError)`, thrown
from `PPU#run`'s own (now correctly interpreted) `@fiber.resume` call.
Root cause, traced by hand rather than assumed: fixing only the `Fiber.new`
call site leaves `main_loop` (the fiber body's own real payload) and
everything IT calls -- `wait_frame`/`wait_zero_clocks`/`wait_one_clock`/
`wait_two_clocks` at minimum, and transitively whatever those reach --
fully compiled and devirtualized, since none of THEM contain the one
shape this fix recognizes. So the fiber's own execution now crosses from
its interpreted, bytecode-backed body into native, VM-invisible compiled
code before it ever reaches a `Fiber.yield` call. `PPU#sync`/`#vsync`
(also compiled) reach `PPU#run` -- the method that owns `@fiber.resume` --
only through dynamic dispatch (`run` isn't itself compiled), which is a
`mrb_funcall`-shaped call from mruby's own perspective; `fiber_resume`
(`mrbgems/mruby-fiber/src/fiber.c`) checks exactly this
(`mrb->c->ci->cci > 0`) to decide whether to resume the fiber through its
`vmexec`-reentrant path (`mrb_vm_exec(mrb, c->ci->proc, c->ci->pc)`,
called synchronously from inside `fiber_switch` itself) rather than the
ordinary suspend-and-return path -- and that reentrant path is where
something breaks: not at `Fiber.yield` itself (`mrb_fiber_yield` never
calls `fiber_check_cfunc`, unlike `fiber_switch`, so a yield crossing a
compiled frame is never rejected outright), but silently enough that a
*later* `.resume` call finds the fiber already `MRB_FIBER_TERMINATED`
rather than raising anything at the actual moment of corruption. This
exact `mrb_funcall`-from-compiled-`CPU`-into-interpreted-`PPU#sync`-into-
bare-`run` shape already existed, unaffected, in every prior successful
180-frame run this whole session (`PPU` was always fully excluded, so
`main_loop` and everything downstream of it was always ALSO interpreted,
keeping the whole fiber-body-to-`Fiber.yield` chain free of any compiled
frame) -- the newly-compiled `main_loop`/`wait_*` chain is the one real
difference, and the evidence points there, though this has not been
confirmed with a `gdb`/call-graph trace the way the `ARY_PTR`/`ARY_LEN`
root cause above was.

So the real fix needs to keep the *entire* reachable graph from the fiber
body down to every `Fiber.yield` call site off the compiled/devirtualized
path -- `main_loop` and its own transitive callees, not just the `Fiber.
new` construction -- which is a substantially larger and riskier change
than this session's own scope (it would need either a whole-program
reachability analysis from every `Fiber.yield`/`Fiber#resume` site back to
its owning `Fiber.new`, or a much more general "some Ruby-level
suspend/resume boundary exists here, never devirtualize across it"
primitive). `compiled_run.rb` still excludes `Optcarrot::PPU` from
`ONLY_OWNERS` entirely -- this session's own fix is real, tested, and safe
to keep, but does not by itself unlock `PPU`.

**Update (FIBER_REACHABILITY_UNSAFE_SUPPORT session)**: `PPU` is unlocked
now, for real, with a real end-to-end pass of the 180-frame benchmark to
show for it -- not just a static coverage-report count. Two things landed
in `tools/bc2cpp/bc2cpp.rb`, both required, verified by removing each in
turn and re-testing:

1. `calls_fiber_yield?` -- a method whose own bytecode directly calls
   `Fiber.yield` (a bare `GETCONST Fiber` feeding a plain `SEND`/`SEND0`
   `:yield` -- confirmed via a fresh `mrbc -v`: unlike `Fiber.new`, this
   opcode shape carries no `BLOCK` at all, so it was never caught by the
   `Fiber.new` fix above and compiled successfully into an ordinary
   dynamic-dispatch `mrb_funcall`-style call reaching `mrb_fiber_yield`
   directly from whatever native frame happened to be running) is refused
   compilation, the same `#error`-stub shape `compile_method` already uses
   for its own "has non-mandatory arguments" rejection.
2. `compute_fiber_unsafe_methods` -- tried (1) alone first, expecting it
   to be enough alongside the earlier `Fiber.new` fix. It was not: `PPU`
   with only `run`/`wait_frame`/`wait_zero_clocks`/`wait_one_clock`/
   `wait_two_clocks` excluded (five methods -- the `Fiber.new` site and its
   four direct `Fiber.yield` callers) still crashed the real 180-frame
   benchmark with the identical `resuming dead fiber (FiberError)`
   documented above. `main_loop` -- compiled, calling those four through
   ordinary bare self-sends -- was still sitting between the fiber's entry
   point and every yield. So this computes the full transitive closure:
   starting from every `Fiber.new { block }` call site's own block body,
   found by a whole-program scan (not gated to one method, unlike the
   `Fiber.new` fix's own recognizer), follow every bare/self-implicit send
   (`SSEND`/`SSEND0`/`SSENDB`, which Ruby resolves to `self`
   unambiguously) to another method of the SAME owner class, and refuse
   every method reached this way, however many hops out. Scoped to same-
   owner self-sends specifically because every real call inside this
   closed world's one Fiber body already has that shape -- see that
   method's own comment for the honest limit (an explicit-receiver call
   crossing OUT of the fiber's own class is out of scope, a real gap only
   if such a call itself reaches a `Fiber.yield`, which none does here).

Confirmed against this exact tree: the closure reaches 36 of `PPU`'s own
75 methods (`main_loop` itself, everything it calls to actually render a
scanline -- `open_name`/`open_attr`/`open_pattern`/`fetch_*`/
`evaluate_sprites_*`/`render_pixel`/`batch_render_eight_pixels`/
`load_tiles`/`preload_tiles`/`scroll_*`/`vblank_*`/`update_enabled_flags*`/
`boot`, plus the 4 direct `Fiber.yield` callers and `run` itself), leaving
the other ~38 (`sync`, `vsync`, `setup_frame`, `active?`,
`monitor_a12_rising_edge`, `make_sure_invariants`, accessors, ...)
eligible to compile. All 15 `scripts/bc2cpp_*_check.rb` static checks
still pass. `compiled_run.rb`'s own `ONLY_OWNERS` no longer excludes
`Optcarrot::PPU` at all -- the whole-class exclusion that comment used to
carry is now redundant with the exact, per-method one `bc2cpp.rb` itself
enforces. The real 180-frame benchmark (`KEEP_TEMP=...
MRBC=... ruby tools/optcarrot_probe/compiled_run.rb`) now completes
end-to-end with `Optcarrot::PPU` partially compiled, checksum `59662` on
all three runtimes, run repeatedly -- the crash this whole thread started
from does not reproduce.

Wall-clock is not yet cleanly measured: the one run taken so far
(`bc2cpp installed 232 compiled methods`, `mruby + bc2cpp` at 76.41s vs.
the plain interpreter's 70.36s -- bc2cpp *slower*) happened on a machine
showing moderate load (0.6-0.8 on 4 cores) at the time, the same caveat
that has corrupted more than one gprof/timing run earlier in this
project's history; a clean, idle-machine before/after (`PPU` excluded vs.
this fix's partial inclusion) is the honest next step before trusting
either number, not something this paragraph will guess at.

**Update (clean-machine re-measurement)**: done, on a genuinely idle
machine (load 0.3-1.2 throughout, one brief dip to 1.9 between runs from
an unrelated process that finished before the second run started).
Scratch copies only, `tools/optcarrot_probe/compiled_run.rb` itself
untouched -- Run A restored the old `.reject { |owner| owner.start_with?(
'Optcarrot::PPU') }` line onto a scratch copy (simulating the pre-fix
baseline); Run B ran a scratch copy of the current, landed file
unmodified. Confirmed the only diff between the two scratch files was
that one line.

| | Run A: `PPU` excluded (old) | Run B: `PPU` included (this fix) | delta |
|---|---|---|---|
| compiled methods | 198 | 232 | +34 |
| CRuby | 7.06s (25.51 fps) | 7.16s (25.14 fps) | +0.10s |
| mruby interpreter | 70.80s (2.54 fps) | 71.86s (2.50 fps) | +1.06s (+1.5%) |
| mruby + bc2cpp | 78.20s (2.30 fps) | 78.33s (2.30 fps) | +0.13s (+0.17%) |

Checksum `59662` on all three runtimes, both runs. Verdict: compiling
`PPU`'s fiber-safe 34 extra methods is wall-clock *neutral* for `mruby +
bc2cpp` -- +0.17%, well inside run-to-run noise, neither a real speedup
nor a real slowdown. The earlier, separately-flagged observation that
`mruby + bc2cpp` runs slower than the plain mruby interpreter for this
whole probe is now confirmed as real, not noise, in both configurations:
~7.4s (10.5%) slower in Run A, ~6.5s (9.0%) slower in Run B, consistently.
That gap predates this session's own work by a long margin -- this file's
own intro already put it at roughly 10% ("CRuby ~4.9s, interpreted mruby
~59-60s, and bc2cpp ~63-67s") before `CPU`/`NES` even compiled, and at
12.6% once they did ("CRuby 4.82s, interpreted mruby 59.60s, and bc2cpp
67.09s") -- and is a separate, larger open question this specific change
neither caused nor closed.

**Update (CI SIGSEGV investigation)**: the "confirmed safe" `Optcarrot::CPU`/
`NES` claim above, and the `Optcarrot::Video`/`APU` frame-boundary hooks it
was extended with, did not hold up against CI's own 180-frame run -- CI
started failing with a plain SIGSEGV in this job. Re-running the exact CI
configuration reproduced it locally, `gdb`-confirmed a null `DATA_PTR` inside
`Optcarrot__APU_vsync_impl`/`Optcarrot__APU_clock_frame_counter_impl` called
directly from `Optcarrot__NES_step_impl` -- a different symptom from bug 1
above (that one is fixed and stays fixed), reached only through `NES#run`'s
real, Fiber-driven multi-frame loop, which the shorter local smoke checks
this section otherwise relies on do not exercise long enough to hit.
Excluding `Optcarrot::APU` from `ONLY_OWNERS` (matching how `Optcarrot::PPU`
is already excluded) did not fix it: with `Optcarrot::APU` also excluded, the
same 180-frame run instead segfaults inside `Optcarrot__Video_tick_impl`
(`@times.last` on a plain, non-embedded Array ivar) -- and bisecting that
crash down (see the long comment on `FIBER_SAFE_OWNERS` in
`compiled_run.rb`) found it reproduces from `Optcarrot::Video` *alone*, no
`CPU`/`NES`/`PPU`/`APU` compiled at all, no devirtualization involved: a
plain interpreter call into the registered, compiled `Video#tick` crashes on
its 4th invocation every time, exactly when mruby's own embedded-array
storage (3 elements inline on this word-boxed 64-bit build) overflows onto
the heap -- `gdb` traced it to bc2cpp's generated `ARY_LEN`/`ARY_PTR` codegen
for `Array#last` reading a stale cached pointer from one `mrb_val_union(r3)`
call while a different call for the identical `r3`, moments later, correctly
returns the array's real, current pointer; that is a bc2cpp code-generation
defect, not anything specific to Fiber adjacency, this repo's ivar-embedding
work, or `patches/mruby-nomemoryerror-reentrant-alloc.patch` (checked and
ruled out, along with the pre-session `bc2cpp.rb`, as explained in
`compiled_run.rb`'s own comment). `compiled_run.rb` now excludes
`Optcarrot::CPU`/`NES`/`Video`/`APU` from `ONLY_OWNERS` too, alongside the
already-excluded `Optcarrot::PPU` -- back to compiling only
`Optcarrot::Config`/`Optcarrot::Opt` plus the `Optcarrot::ROM` setup methods
(24 methods), which the full 180-frame run completes cleanly with checksum
`59662` on all three runtimes, repeatedly. This is a real regression in scope
from the "all five compiled" state this section spent a lot of text
re-verifying, not a partial fix -- re-enabling any of `CPU`/`NES`/`Video`/
`APU`/`PPU` needs the underlying bc2cpp codegen bug (and the separate
`PPU`/`Fiber.new` one) fixed first, and re-verified against the real
180-frame `nes.run` loop specifically, not a shorter smoke run -- see
`compiled_run.rb`'s own comment on `FIBER_SAFE_OWNERS` for the full
evidence. Treat every "all three"/"all five compiled" number and claim above
in this section as historical only, same caveat as bug 2's paragraph.

**Update (ARY_PTR/ARY_LEN root cause)**: the `Optcarrot::Video#tick` SIGSEGV
above is now root-caused and fixed, not just worked around. The crash was in
`tools/bc2cpp/native_expression_devirt.rb`'s
`exact_array_no_argument_element_expression` -- the code that turns a real
mruby C method body like `mrb_ary_last` (`struct RArray *a = mrb_ary_ptr(self);
... return ARY_PTR(a)[ARY_LEN(a) - 1];`) into a single call-site C++
expression for `Array#last`/`Array#first`. It independently re-substituted
the wrapper's own local `a` everywhere it was used instead of materializing
it once, the way the real C body does, so the assembled expression for
`#last` called `mrb_ary_ptr(recv)` three times over in one statement (once
for the `> 0` length guard, once for the `- 1` index, once more hardcoded for
the `ARY_PTR` base), each expansion re-nesting the `ARY_EMBED_P`/`ARY_LEN`/
`ARY_PTR` macros' own embed-vs-heap ternary on top of the last. `gdb`, reading
a real `-O0` build of the generated `.cpp` at the crash, found the array's
own `RArray` struct (`flags`/`len`/`capa`/`ptr`) completely intact at every
checkpoint, including inside the crashing statement's own `mrb_val_union`
calls -- but GCC's code generation for that specific triply-nested ternary
tree left one code path (the one skipping the now-redundant middle
computation) reading an uninitialized callee-saved register instead of a
freshly computed pointer: a genuine compiler-facing code-generation defect,
triggered by the redundant, repeated call shape itself, not by anything
Fiber-, devirtualization-, or ivar-embedding-related (reproduced identically
at `-O0`, with and without `-fno-strict-aliasing`, and under
AddressSanitizer, ruling out an earlier guess that this was an
optimization-level-dependent stale-register-cache artifact). `Array#first`
has the same latent two-call shape (its index is the literal `0`, so no
second `ARY_LEN`) and never reproduced a crash in this same probe, but
nothing in the C++ standard promises repeated calls to an equivalent
expression get merged, so the fix hoists both: the generated expression now
materializes `mrb_ary_ptr(recv)` into a single local via a GNU statement
expression and reuses it, exactly like the real C body does, instead of
re-deriving it per use (`hoist_repeated_receiver_array_pointer` in
`native_expression_devirt.rb`). With that landed, a fresh
`tools/optcarrot_probe/compiled_run.rb` run compiles and installs
`Optcarrot::CPU`/`Optcarrot::NES`/`Optcarrot::Video`/`Optcarrot::APU` again
(`Optcarrot::PPU` stays out for its own, separate, still-unfixed `Fiber.new`
bug above) and completes the full 180-frame `nes.run` loop with checksum
`59662` on all three runtimes, repeatedly -- not a shorter smoke run. Treat
this paragraph, not the "back to compiling only Config/Opt" paragraph above
it, as the current state.

Compiling the actual hot path does not yet make it faster: the latest local
180-frame run measured CRuby 4.82s, interpreted mruby 59.60s, and bc2cpp
67.09s (all three checksum `59662`), i.e. bc2cpp is now about 12.6% slower
than interpreted mruby rather than the roughly 10% it was before CPU/PPU/NES
were included. `CPU#run`'s own dispatch (`send(*DISPATCH[@opcode])`) is
inherently data-driven -- the opcode table maps to a different bound method
per NES instruction, so bc2cpp correctly keeps it as a real `mrb_funcall`
rather than guessing a fixed target -- and a fair share of CPU/PPU's own
instance variables are not proven embeddable (mixed/opaque types), so their
compiled bodies still pay `mrb_iv_get`'s `iv_bsearch_idx` the same way the
interpreter does. Compiling more of the real program is still valuable on its
own terms (the stated goal of this probe is exercising bc2cpp against a real,
non-toy Ruby program), and it is a prerequisite for any future ivar-embedding
work on CPU/PPU to matter at all -- but it is not, by itself, the source of a
wall-clock win. The exact-Array `clear` fast path, retained capacity, and
frame-buffer reuse notes below are unaffected by this change; they already
applied to the newly-compiled methods' bodies once those bodies started
running.

The pixel Array is synchronously consumed by `Video#tick` before the next
`NES#step`, and mruby's GC scans only the live Array length. The benchmark
still uses upstream emulation logic; only the method registration set
changes. It runs the same ROM and checksums under all three systems; CRuby
omits only the mruby-specific compatibility shims.

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

This pointed to two limits: the PPU's Fiber-driven hot loop stayed
interpreted, and compiled methods still crossed into mruby through dynamic and
block-carrying calls. Those crossings left substantial VM activity and
coincided with much more GC time, outweighing the bytecode dispatch removed
from the compiled CPU path. The profile is a direction, not a precise causal
split: gprof sampling and instrumentation are coarse, and the gprof build
disables inlining only for generated C++ methods to keep them visible;
mruby's C runtime keeps its normal optimization settings in both profiles.

**Update, with `Optcarrot::CPU`/`PPU`/`NES` all compiled** (see "Compiled
runtime check" above): a fresh instrumented 180-frame run measured 108.54s
interpreted and 131.74s compiled (both checksum `59662`). The two profiles
are now far more alike than before, which is itself the finding: compiling
the PPU Fiber loop did not narrow the gap. `mrb_vm_exec` fell from 45.9% to
40.4% (real bytecode dispatch removed, as expected), but `iv_bsearch_idx`
stayed essentially flat at 14.3% -> 11.2% of *sampled time* while its *call
count* barely moved (354.2M -> 364.6M -- compiling these classes did not
reduce how often their ivars get looked up, because it did not make more of
their ivars embeddable). `gc_gray_rescan` rose 8.5% -> 11.9%. This matches
`tools/optcarrot_probe/bc2cpp_probe.rb`'s own `== ivar embedding ==` output
directly: of `Optcarrot::CPU`'s and `Optcarrot::PPU`'s real instance
variables (registers, scroll/palette/rendering state -- dozens between the
two), only `CPU#@clk_total` and 9 `PPU#@...` fields are proven embeddable;
everything else (`CPU#@a`/`@x`/`@y`/`@s`/`@p`/`@pc`/register file, PPU's
buffers and per-scanline state, ...) still goes through mruby's ordinary
ivar table, compiled code included. Embedding more of that state -- widening
`IvarLayout`'s proof to cover whatever currently poisons it to OPAQUE/UNKNOWN
for these two classes -- is the concrete next target this measurement points
at, not further dispatch-shape experiments on `CPU#run` itself.

**Update (ivar-embedding widening session)**: acted on that target.
`IvarLayout`'s backward SETIV trace (`tools/bc2cpp/bc2cpp.rb`) recognized
only `LOADI*` (Fixnum literal), `LOADSYM` (Symbol literal), `ADD`/`ADDI`
(trusted unconditionally), and a narrow, fully-proven `SUB`/`MUL`/`%`/`&`/
`|`/`^` set -- every SETIV site not shaped like one of those poisoned the
whole ivar to UNKNOWN forever (`IvarLayout.join`'s own all-sites-must-agree
semantics), and reading the disassembly directly for `Optcarrot::CPU`/`PPU`
found two large, completely safe classes of site this missed: a literal
`@flag = true`/`@flag = false` (no case at all -- fell through to the
generic "unrecognized opcode" UNKNOWN branch), and `@x = SOME_CONST` for a
constant this file's own `IntegerConstants` whole-program pass had *already*
proven always integer-valued for a different purpose (`INTEGER_CONSTANT_
PROOF`, used by `compile_insn`'s own GETCONST/GETMCNST fast path) but that
`IvarLayout` never consulted. Both are now recognized: a new `:bool`
embeddable type (a real `mrb_bool` struct field, boxed/unboxed through
mruby's own public `mrb_bool_value`/`mrb_true_p`/`mrb_false_p` -- no single
combined "is this a real boolean" macro exists, so a tiny generated
`bc2cpp_bool_p` OR of the two ships alongside, emitted once per file and
only when actually used), and a `GETCONST`/`GETMCNST` case that embeds as
`:fixnum` exactly when `integer_constants.include?(name)` already holds
(threaded into `IvarLayout.analyze` for the first time; previously only
`CodeGen` itself consumed that proof).

**Correction, same session**: the obvious way to measure this --
`scripts/bc2cpp_coverage_report.rb`'s own `ivar embedding (EMBED)` line,
115 -> 216 -- is the wrong number, and does not mean any of it reaches this
probe. That count is `IvarLayout`'s own raw proof, printed by the driver
before `CodeGen` even exists; it says nothing about what the real generated
code does with it. Two later, independent filters sit between that proof
and an actual `mrb_bool`/`mrb_int` struct field: `CodeGen#drop_unsafe_
embeddings` (every method touching the ivar has to compile clean, or
embedding it would silently diverge from the interpreter's own `iv_tbl`),
and, decisively for this probe, `tools/bc2cpp/compiled_gems.rb`'s
`BC2CPP_WIRED_EMBEDDINGS` -- a hand-maintained allowlist of real-project
classes (`Game::Screen`, `Game::ChipSet`, `Game::Switches`, `RPG2k::
Scene::VehicleWorld`, `LCF::EventCommand`, `LCF::MoveCommand` as of this
writing) that `CodeGen.wired_embeddings` gates every embedding against,
unconditionally, for *every* `bc2cpp.rb` invocation including this probe's
own. No `Optcarrot::*` class is on that list, so `drop_unsafe_embeddings`
rejects all of them outright regardless of what `IvarLayout` proved --
confirmed directly against the real generated code from this exact,
current `compiled_run.rb` (`KEEP_TEMP=... ruby tools/optcarrot_probe/
compiled_run.rb`, then `grep DATA_PTR gem/src/optcarrot_probe_gen.cpp`):
zero matches, and `@clk_total` -- the one field this section has
documented as "proven embeddable" since long before this session --
compiles to a plain `mrb_iv_get`/`mrb_iv_set` pair, not a struct access.
That earlier "only `CPU#@clk_total` and 9 `PPU#@...` fields are proven
embeddable" claim above was always describing `IvarLayout`'s own proof,
never active struct embedding; this correction applies to it equally, not
just to this session's own new fields.

This session's actual, *verified* effect is entirely in the real project,
not this probe: `grep`-ing the real generated code for `BC2CPP_WIRED_
EMBEDDINGS`'s own classes' `_ivars` structs, before vs. after, shows
`Game::Screen` gaining 5 real fields (12 -> 17) -- `@shake_continuous`/
`@flash_continuous`/`@pan_locked` as new `mrb_bool` fields, `@shake_
frames`/`@fade_transition` as `mrb_int` via the new constant-sourced case.
No other currently-wired class gains anything (none of their own ivars
happen to be bool- or constant-sourced). `Game::Screen` is a real, hot
class in the RPG2k screen-effect pipeline, genuinely reducing its own
`iv_bsearch_idx` traffic -- just not anything this probe's own gprof
numbers can show, since this probe never compiles it. (An earlier revision
of this paragraph also cited `Game::Interpreter` gaining 11 embedded
`mrb_bool` fields from this same change -- true when written, but
`Game::Interpreter` was removed from `BC2CPP_WIRED_EMBEDDINGS` by a
concurrent, unrelated session shortly after, for a real, severe bug
(`Game::Interpreter`/`Transition`/`Map` had compiled entry points their
own `register.cxx` never installed -- an interpreted fallback then read
the ordinary ivar table while compiled methods wrote the embedded struct
and saw `nil`, silently killing every Parallel Process event). That
removal is unrelated to this change -- it would have applied identically
with zero new `Game::Interpreter` fields -- but it does mean this
paragraph's own "verified" claim about `Game::Interpreter` no longer
holds; `Game::Screen` is the one still-current, still-verified case.)
The full 180-frame `nes.run` loop still checksums `59662` on CRuby,
interpreted mruby, and bc2cpp alike (the `:bool`/constant-sourced codegen
itself is exercised for real by this probe's own build even though none
of it lands on a struct field here -- every newly-recognized SETIV/GETIV
source still has to compile to *some* correct code, struct-backed or
not), run repeatedly against the real, non-scratch `compiled_run.rb`.

**Update (BC2CPP_SELF_REGISTERING session)**: the correction above's own
root cause -- `BC2CPP_WIRED_EMBEDDINGS` gating every embedding
unconditionally, for every `bc2cpp.rb` invocation including this probe's
own -- is now fixed for this probe specifically, not just documented.
That allowlist exists because the REAL compiled gems' hand-written
`register.cxx` does not install every compiled entry point of an
embedding class by construction (see that constant's own comment for the
real, shipped bug this caused). This file's own `emit_register`, above,
never had that gap: it already installs every compiled method of any
owner its own `embeds` diagnostic names, computed from the exact same
diagnostic bc2cpp.rb itself prints -- "embeddable" and "installed" were
always the same fact here, by construction, the identical guarantee a
concurrent session's own `emit_owner_registrations` mechanism now
provides by generation for the real gems (see `docs/adr/0185`-adjacent
work). `compiled_run.rb` now sets `BC2CPP_SELF_REGISTERING=1`, which
tells bc2cpp.rb's driver to skip the allowlist entirely for this
invocation (nothing in this closed world was ever on it anyway) and let
every ivar `IvarLayout`/`drop_unsafe_embeddings` themselves already
proved safe actually embed -- those two checks (every accessor compiles
clean, no native `attr_reader`/`writer` collision) still run
unconditionally either way; only the extra, hand-maintenance-specific
allowlist gate is removed.

Confirmed against the real generated code from this exact, current
`compiled_run.rb` (`KEEP_TEMP=... MRBC=... ruby tools/optcarrot_probe/
compiled_run.rb`): `Optcarrot::CPU` now has a real `Optcarrot__CPU_ivars`
struct (`@clk_total` as `mrb_int`, `@jammed`/`@ppu_sync` as the `:bool`
type from the session above), with real `DATA_PTR` reads/writes at
`CPU#run`'s own call sites -- `@ppu_sync`'s own struct read appears at
both places `cpu.rb` checks it (`@ppu.sync(@clk) if @ppu_sync`).
`Optcarrot::ROM`, `Pad`, `APU`, and `APU::DMC` also gain real embedded
structs the same way. `Optcarrot::PPU`'s own ivars (`@run`/`@vblank`/
`@hclk`/`@scanline`/... from the session above) are still inert -- not
because of `BC2CPP_WIRED_EMBEDDINGS` any more, but because `PPU` itself
stays out of `ONLY_OWNERS` entirely, for its own separate, still-open
`Fiber.new` bug (see "Compiled runtime check" above); embedding an
ivar of a class with zero compiled entry points has nothing to attach
to. The full 180-frame `nes.run` loop checksums `59662` on CRuby,
interpreted mruby, and bc2cpp alike, run repeatedly.

**What this does *not* establish**: a measured wall-clock improvement.
`gprof` runs taken in this same session, with and without this change,
both landed in a machine state clearly under heavy external contention --
`sigalrm_handler` (the profiler's own timer-signal handler) and a single
`mrb_mruby_task_gem_final` call each showing 40-48% of "self time" is not
real application work, it is corrupted sampling from a shared, busy
machine, the same caveat a concurrent session's own PR raised about this
identical environment ("measurements were taken across several runs on a
shared machine (other agents building concurrently)"). The *disabled*
control run (`BC2CPP_SELF_REGISTERING=0` against this same, current
`compiled_run.rb`) was equally corrupted and equally slow, which is what
rules this out as a regression from the change itself rather than
environment noise -- but it also means neither run's absolute numbers,
nor their `iv_bsearch_idx` call counts (identical between the two runs,
which is itself suspicious given real, confirmed new struct accesses at
`CPU#run`'s own hot path -- not yet explained), should be trusted as a
real measurement right now. Re-measuring on a quiet machine, the same
caveat that PR's own author gave their part of this exact story, is the
honest next step here too, not a number this paragraph will guess at.

**Update (clean-machine re-measurement)**: done, on a genuinely idle
4-core box (load average 0.15-0.92 throughout, confirmed via `uptime`
before starting) rather than guessed at. Same method as the corrupted
runs above -- `GPROF=1` against this exact `compiled_run.rb`, changing
only `BC2CPP_SELF_REGISTERING` between the two -- but this time the
profiles came back clean: `sigalrm_handler`/`mrb_mruby_task_gem_final`
are ordinary small entries near the bottom of the flat profile (0.03-
0.14% self-time), not 40-48% of it, confirming the earlier corruption
really was machine contention and not a flaw in the measurement itself.
Both runs still checksum `59662`.

The `iv_bsearch_idx` call-count identity from the corrupted runs
*reproduced exactly* on the clean machine: 376,884,519 in both the
`BC2CPP_SELF_REGISTERING=0` and `=1` runs, down to the identical
318,027,773/58,856,746 caller-edge split. That rules out "it was noise"
as the explanation -- it is a real, deterministic fact that this specific
change does not move that specific counter, most likely because
`iv_bsearch_idx`'s 376M calls are dominated by ivars/classes this change
never touches (`Video`/`PPU`'s own dynamic ivars, or other machinery
entirely), not by the 3 fields (`@clk_total`/`@jammed`/`@ppu_sync`) this
change actually embeds on `CPU`. Nobody has yet isolated which call sites
those 376M calls actually come from -- that would need `gprof -q`'s call
graph (the same tool the `gc_gray_rescan` investigation below used), not
attempted this session.

Despite that, wall-clock *did* move, consistently: the bc2cpp run took
287.99s disabled vs. 270.14s enabled (-6.2%), while the CRuby and
interpreted-mruby runs (neither of which this env var touches) stayed
within 1-3% of each other, the expected run-to-run noise band -- so the
6.2% bc2cpp delta is attributable to the change, not noise. The
mechanism is not `iv_bsearch_idx`, per the paragraph above; the flat
profile's other real (non-noise-band) delta is `sym_check`/`mrb_packed_
int_decode`/`symtbl_get_ptr`/`symtbl_is_literal` -- four functions in
mruby's packed-symbol-table decode path, all moving together (as they
should; they are one call chain) from about 2,212,743,000 calls disabled
to about 1,856,817,000 enabled, a 355.9M-call, 16.1% drop, reproducible
and far outside noise. `mrb_vm_exec`'s own call count (3,016,234) and
`gc_gray_rescan`'s (2,879) were identical between both runs, so this
isn't a change in how much bytecode ran or how the GC behaved -- it is
specifically less symbol-table traffic. A plausible mechanism, not yet
confirmed: the coverage report's `synthesized accessor overrides
(ATTR_STRUCT_DEVIRT)` count goes 0 (disabled) -> 3 (enabled) -- 3 extra
struct-aware accessor methods `CodeGen#emit_ivar_accessor_pair` only
synthesizes once embedding is actually active (see `drop_unsafe_
embeddings`'s own `natively_exposed?`/`synthesizable_accessor_only?`
machinery) -- and if any of those 3 sit on `CPU#run`'s own hot path, a
synthesized direct accessor bypasses the ordinary `SEND` dispatch (and
whatever symbol-table work that dispatch does) entirely. Tracing exactly
which 3 methods those are, and whether they're actually hot, is the next
step to turn "plausible" into "confirmed" -- not attempted this session.

**Correction (the 3-accessor mechanism above is wrong)**: traced exactly
which 3 methods those are, as promised above, and none of them run at
all in this benchmark. `Optcarrot::Pad#buttons`/`#buttons=`'s only real
callers are `Pad#press`/`#release` (`pad.rb`'s own `@pads[pad].buttons
|= 1 << btn` / `&= ~(...)`), which this probe's own headless driver
(`runner_tail.rb`) never reaches -- it constructs `Optcarrot::NES.new`
with `input: :none`, so zero input events are ever generated across all
180 frames. `Optcarrot::CPU#ppu_sync=`'s only real caller anywhere in
`3rd/optcarrot/lib` is `optcarrot/mapper/mmc3.rb`'s `@cpu.ppu_sync =
true` -- and `mapper/mmc3.rb` is not in this probe's own 11-file source
list (`compiled_run.rb`'s own `sources` array), so that call site isn't
even part of the compiled program, let alone executed. All 3
synthesized accessors have exactly zero executions this benchmark ever
takes, confirmed by grepping the loaded source tree rather than assumed
-- they cannot be the source of a 355.9M-call difference in anything.

The real mechanism, found by comparing `emit_register`'s own `rows`
(the methods it actually installs via `mrb_define_method`) between the
two configurations directly, rather than reasoning about `embeds`
secondhand: `BC2CPP_SELF_REGISTERING`'s dominant effect was never really
about ivar embedding at all -- it's that `emit_register`'s own
registration filter (`FIBER_SAFE_OWNERS.include?(owner) || safe_setup ||
safe_frame_boundary || embeds.include?(owner)`, this file's own comment
above) uses `embeds.include?(owner)` as one of its four ways for a
method to qualify, and `embeds` is *empty* whenever
`BC2CPP_SELF_REGISTERING` is unset -- because `embeds` is computed from
the exact same `BC2CPP_WIRED_EMBEDDINGS`-gated diagnostic this whole
change targets. Disabled, only whatever a class's `FIBER_SAFE_*` entry
explicitly lists gets registered; every other method of that class keeps
running as plain interpreted bytecode, not because it failed to compile,
but because nothing ever called `mrb_define_method` to install the
compiled version over it. Counted directly (excluding `Optcarrot::PPU`,
which the real benchmark always excludes via its own separate
`ONLY_OWNERS` step regardless of this env var): disabled installs 151
real methods total; enabled installs 199 -- 48 more, concentrated
exactly where `FIBER_SAFE_OWNERS`/`FIBER_SAFE_SETUP_METHODS`/
`FIBER_SAFE_FRAME_BOUNDARY_METHODS` never reached:

- `Optcarrot::ROM`: 1 method (`initialize`) -> 10 (adds `peek_6000`/
  `poke_6000` -- the cartridge-space memory access path the CPU's own
  `fetch`/`store` reach on every out-of-RAM address -- plus `init`,
  `load_battery`, `parse_header`, `reset`, `save_battery`, `vsync`,
  `inspect`).
- `Optcarrot::Pad`: 0 methods -> 7 (the entire class, including its own
  `peek`/`poke`/`poll_state` -- unexercised by this particular `input:
  :none` benchmark run, per the correction above, but real for any run
  that does drive input).
- `Optcarrot::APU`: 2 methods (`flush_sound`, `vsync`, both already
  covered by `FIBER_SAFE_FRAME_BOUNDARY_METHODS`) -> 20 (adds `do_clock`,
  `clock_dma`, `clock_dmc`, `clock_frame_counter`, `clock_frame_irq`,
  `clock_oscillators`, `proceed`, `peek_4015`, `peek_40xx`, `poke_4015`,
  `poke_4017`, `reset`, `reset_mapping`, `update`, `update_delta`,
  `update_latency`, `initialize`, `inspect` -- the entire per-cycle audio
  processing path).
- `Optcarrot::APU::DMC`: 0 methods -> 13 (the entire class).

So the 16.1% symbol-table-traffic drop and the 6.2% wall-clock win are
both far more directly explained by "48 more real, previously-
interpreted hot-path methods -- including the ROM read path every
CPU memory access can reach and the entirety of APU's audio clocking --
now run as compiled C++ instead of through the interpreter's own `SEND`
dispatch" than by anything involving ivar embedding or synthesized
accessors. This also means this PR's own original framing (centered on
3 embedded `CPU` ivars) undersold its real effect: the ivar embedding is
real and independently useful, but registration completeness for whole
classes was always the bigger win sitting in the same diagnostic gate.
Still not run through `gprof -q`'s call graph to prove the *exact*
causal chain from "more compiled methods" to "less symbol-table
traffic" rather than merely correlating -- that remains the honest next
step.

**Why `CPU`'s own register file stays unembedded**: the "next concrete
target" this section's own earlier revision named -- `@a`/`@x`/`@y`/`@s`/
`@p`/`@pc` (real names: `@_a`/`@_x`/`@_y`/`@_sp`/`@_pc`, plus the split
flag register `@_p_c`/`@_p_d`/`@_p_i`/`@_p_nz`/`@_p_v`) -- traced by hand
against `3rd/optcarrot/lib/optcarrot/cpu.rb` and `IvarLayout.trace_type`
(`tools/bc2cpp/bc2cpp.rb`) directly, rather than guessed at: these ivars do
have plenty of purely-Fixnum SETIV sites (`#reset`'s `@_a = @_x = @_y = 0`,
the flag-register literals right after it), but every one of them also has
at least one site like `cpu.rb`'s `@_p_nz = @_a = @data` or
`@_pc = peek16(RESET_VECTOR)`, where the source is `GETIV @data`/a `SEND`
result rather than a literal or proven arithmetic. `IvarLayout.trace_type`
already *does* follow a `GETIV` of another ivar (walks to
`known_ivar_types[other_ivar]`, part of the same 10-pass fixed point that
lets one embeddable ivar's proof feed another's) -- the trace isn't
missing that case. It fails here because `@data`/`@addr` are themselves
never provably Fixnum: their own SETIV sites include `@data = fetch(@_pc)`,
a plain `SEND`, and `IvarLayout.trace_type`'s `SEND` case only trusts a
closed, guarded set of operator names (`%`/`&`/`|`/`^`, `native_only_mono?`)
-- it has no general "this method is proven to always return Fixnum" case.
That proof *does* exist elsewhere in this file -- `CodeGen#compute_fixnum_
return_names` (`FIXNUM_RETURN_PROOF`, printed in the coverage report) -- but
it is computed by `CodeGen` itself, from `@ivar_layout` among other inputs,
strictly *after* `IvarLayout.analyze` has already run and returned; feeding
it back into `IvarLayout.trace_type`'s `SEND` case would need restructuring
the two into one shared fixed point (`IvarLayout` proving ivars,
`FIXNUM_RETURN_PROOF` proving methods, each feeding the other, iterated to
convergence) rather than the current one-directional pipeline. That is a
real, buildable next step -- not attempted this session, since it changes
a load-bearing whole-program analysis shared by every compiled gem in the
real project, not just this probe, and deserves its own session with room
to verify it doesn't regress any of the three real compiled gems.
Confirmed directly against this exact tree (`BC2CPP_SELF_REGISTERING=1`
coverage report, `grep CPU` over the `== ivar embedding ==` section): only
`@clk_total` (`fixnum`), `@jammed`, and `@ppu_sync` (`bool`) are `CPU`'s
embedded ivars today; the register file is absent from that list entirely,
landing instead in the (differently-purposed) `CLASS_CANDIDATE`
devirtualization-hint list further down the same diagnostic output, not in
any "poisoned, here's why" list -- `IvarLayout.analyze` only ever returns
successfully-typed ivars, so a failed trace leaves no direct trace of
*why* in the diagnostic output; the reasoning above came from reading
`cpu.rb`'s own SETIV sites against `trace_type`'s cases by hand, not from
a tool that reports failures.

**Update (FIXNUM_RETURN_IVAR_HINT session)**: acted on the "real, buildable
next step" named just above -- but stratified, not a full joint fixpoint,
mirroring `ClassLayout`/`ARRAY_RETURN_PROOF`'s own existing
`ARRAY_RETURN_IVAR_HINT` two-level shape (that call site's own header
explicitly rejects a full alternation as unjustified extra machinery for
the measured payoff; the same argument applies here). See ADR 0187 for the
full mechanism. Verified this exact tree's `optcarrot_bc2cpp_coverage_
report.rb` output is byte-identical before and after -- `CPU`'s own
register file still does not embed, and now with a confirmed reason rather
than a guess: `fetch`/`peek16`/`peek` (what `@data`/`@addr`/`@_pc` actually
trace back to) read through `NES`'s own per-address memory-mapper dispatch
(`@fetch[addr]`/`@store[addr]`, an Array of per-device callables looked up
by address, then called) -- genuinely `POLY` across optcarrot's different
mapper classes, not `MONO`, so `FIXNUM_RETURN_PROOF`'s own admission rule 1
(`@registry[N]` holds exactly one real-bytecode definition) correctly
refuses them regardless of this change. The gap this change actually closes
needs a bare, whole-program-unique method name; `CPU`'s own memory access
path is dispatched by runtime address instead, a fundamentally different,
receiver-class-aware devirtualization problem this change does not attempt.
The change is not a no-op elsewhere, though: the real project's own 3
compiled gems gain 5 embedded ivars this way (`Game::Screen#@fade_frames`,
`Game::Interpreter#@battle_indent`/`@choice_indent`/`@inn_indent`/
`@shop_indent`), confirmed directly against the real regenerated code
(`grep _ivars`/`DATA_PTR`), with all 22 `scripts/bc2cpp_*_check.rb` static
checks (including `bc2cpp_wired_embedding_check.rb`'s own per-class
installed-entry-point count for both affected, already-wired classes)
still passing.

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

**`gc_gray_rescan` root cause (gc_gray_rescan investigation session)**:
traced with a fresh gprof run and `gprof -q`'s call graph (not just the flat
profile) against this exact tree, in the reduced-but-working configuration
the "Compiled runtime check" section's own Update paragraph above landed
(`Optcarrot::PPU` interpreted, everything else -- including `CPU`'s opcode
dispatch loop -- compiled): `gc_gray_rescan` calls rose 1,237 -> 3,495 and its
share of sampled time 8.10% -> 31.64%, becoming the single hottest function in
the compiled profile, ahead of `mrb_vm_exec` itself (46.65% -> 27.93% of time,
but its own *call count* rose 362,821 -> 3,029,982 -- 8.3x more re-entries
into the VM despite less total bytecode work, matching the interpreted-vs-
compiled `mrb_funcall_with_block` gap this file already measured
elsewhere: 547K -> 17.2M in an earlier, PPU-included run). This is the
mechanism, read directly from `3rd/mruby/src/gc.c` and confirmed against the
call graph, not inferred from the flat profile alone:

- `gc_gray_rescan` only runs when the fixed 1,024-slot `gray_stack`
  (`MRB_GRAY_STACK_SIZE`) overflows during marking (`add_gray_list`,
  `gc.c`): once full, every further object due to turn gray sets
  `gray_overflow` instead, and the *next* drain has to fall back to a full,
  unbounded scan of every heap page looking for gray objects
  (`gc_gray_rescan` itself) rather than popping the stack. The call graph
  confirms this is not a one-shot cost: `gc_gray_rescan` runs 3,389 times
  from just 5,227 `incremental_marking_phase` calls and 817
  `root_scan_phase` calls -- multiple full-heap rescans per GC cycle, not one.
- `mrb_gc_protect` -- the call that leaves a value in the GC's fixed-growth
  "arena" root set (`gc.c`'s `gc_arena_keep`/`gc_protect`) -- is called
  111,759,292 times in the compiled profile (not even in interpreted's own
  top 50, i.e. under ~9M there: a well over 12x rise). The call graph traces
  most of that rise to exactly the crossings above: `mrb_funcall_with_block`
  (mruby's own C API every non-devirtualized bc2cpp call site --
  `dynamic_dispatch_line`'s `mrb_funcall`, `compile_dynamic_splat_send`'s
  `mrb_funcall_argv`, `emit_block_fallback_glue`'s own calls -- ultimately
  funnels through) protects its own return value on every call
  (12,554,060 calls contribute that many `mrb_gc_protect` calls directly),
  and each such call that reaches a non-cfunc method re-enters `mrb_vm_exec`
  recursively, whose own bytecode -- OP_ARRAY/OP_STRING/OP_HASH literal
  construction, mostly -- calls `mrb_gc_protect` on every literal it builds
  (94,264,629 of the 111.7M calls trace to `mrb_vm_exec` directly).
- The reason this inflates `gc_gray_rescan` specifically, not just GC time in
  general: `root_scan_phase` marks the *entire* arena in one synchronous pass
  (`for (i=0,e=gc->arena_idx; i<e; i++) mrb_gc_mark(mrb, gc->arena[i])`,
  `gc.c`) with no draining in between, exactly like it marks the live VM
  register stack (`mark_context_stack`). mruby's interpreter keeps the arena
  bounded to roughly one call's worth of garbage at a time: `mrb_vm_exec`'s
  own `CASE(OP_SEND...)` handler calls `mrb_gc_arena_shrink` (`vm.c`) right
  after *every* cfunc-target call returns, restoring the arena to that one
  `mrb_vm_exec` invocation's own entry baseline. A devirtualized call from
  one compiled method directly into another's `_impl` function (a plain C++
  call, no VM crossing at all) gets no such shrink -- nothing resets the
  arena between one `mrb_funcall`/`mrb_funcall_argv` call and the next inside
  a hot, self-contained loop like `CPU#run`'s `send(*DISPATCH[@opcode])`
  dispatch (about 1.77M calls in the earlier, 180-frame instrumented run),
  so garbage the interpreter would have reclaimed after every single send
  instead accumulates across the whole compiled method's own execution,
  growing the arena and, with it, how much a synchronous root-scan pass finds
  gray at once -- past the 1,024-slot stack, into `gc_gray_rescan`.
- This is architecturally inherent to how bc2cpp represents a compiled
  method's own registers (plain `mrb_value` C++ locals -- `mrb_value r0 =
  self;` and so on in the generated code, confirmed by reading it directly --
  never part of `mrb->c->stbase`, the VM's own rooted register stack) and
  therefore to why the arena has to do this rooting job at all for them: it
  is not a bug in any one call site, it is the necessary cost of leaving the
  VM's own register-stack rooting behind. **No fix was attempted.** The one
  design that would bound it -- bracket every generated method body with its
  own `mrb_gc_arena_save`/`_restore` (mirroring `mrb_vm_exec`'s own cfunc
  epilogue, shrinking to the method's own entry baseline and re-protecting
  only its actual return value at every exit) -- is plausible and would touch
  only `tools/bc2cpp/bc2cpp.rb`'s method prologue/epilogue emission, but this
  file's own `bc2cpp_ensure_guard` comment already documents exactly the
  failure mode that makes this genuinely risky to ship without exhaustive
  verification: a wrong arena shrink drops a register some other, not-yet-
  executed part of the same method still needs, and the resulting corruption
  is "silent, load-dependent" -- it showed up only once enough allocation
  happened to make a GC actually fire at the wrong moment, not on every run
  or even most runs. Getting this right needs proving no live register (not
  just the return value) depends on an arena entry above the shrink point at
  every one of a method's exits, which needs real liveness analysis this
  session did not attempt, plus `MRB_GC_STRESS`-style exhaustive testing (a
  GC on every allocation) rather than the single-seed checksum check this
  probe otherwise relies on -- out of this session's own time budget. Whether
  the wall-clock win from bounding the arena would even exceed
  `iv_bsearch_idx`'s already-identified, separately-tracked cost (see the
  Update paragraph just above) is also unmeasured.

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

The compiler also lowers `Array#<<` to `mrb_ary_push` for exact Arrays when
the native method is uncontested, and lowers `%`/`&`/`|`/`^` sends when both
operands are Fixnums and the closed-world method registry contains only
native definitions. Subclasses, non-Fixnums, zero divisors, and other
unhandled shapes retain Ruby dispatch. Modulo uses Ruby's sign correction and
handles the minimum-integer/`-1` overflow case. The current Optcarrot report
finds 57 Array pushes and 340 modulo/bitwise sites, including 105 bitwise
OR/XOR sites. It also lowers Fixnum `+`, `-`, and `*` sends through mruby's
overflow-aware numeric helpers when both operands are Fixnums and the Integer
method is uncontested; non-Fixnums retain Ruby dispatch. There are 418 such
arithmetic sites. The report also finds 118 Fixnum `<`, `<=`, `>`, and `>=`
comparisons, which use direct C comparisons under the same guarded dispatch
fallback. Non-Fixnum `==` fallbacks first use mruby's public `mrb_obj_eq`
identity/type shortcut before Ruby dispatch, matching the interpreter and
avoiding a method call when the operands already compare equal at that level.
Fixnum `>>` sends use direct signed shifts when both operands are Fixnums and
the Integer method is uncontested; left-shift overflow and other operand types
keep Ruby dispatch so mruby can produce its normal bignum or error result. The
coverage report finds 54 such sites.
The frame-boundary `PPU#setup_frame` also reuses the exact pixel Array's
backing storage across frames; other exact-Array `clear` sites lower to
`mrb_ary_clear` under the same exact-class guard. In `APU#flush_sound`, the
output and sample buffers also retain capacity; the exact-Array `concat` site
copies into the persistent output Array with `mrb_ary_splice` instead of
replacing it with a shared buffer.
The coverage report identifies candidates across the standalone Optcarrot
closed world; `Optcarrot::CPU` and `Optcarrot::NES` are compiled and
installed (see "Compiled runtime check" below) -- `Optcarrot::PPU` stays
interpreted (its own, separate `Fiber.new` bug), and `Video`/`APU` besides
their two frame-boundary hooks are the classes that remain interpreted too.

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
# Also needs gperf (the vendored mruby regenerates its keyword table with it)
# and a C++ driver for the generated gem.

# The probe applies the mruby patches its generated code needs itself (its
# VM_UNWIND_RESTORE helper reads mrb_state::errinfo, which only
# patches/mruby-dollar-bang-scoped.patch adds), so a bare host mrbc is enough
# to RUN the bundle below; only the manual b/c2cpp runs need these two:
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

## Integer-or-nil A/B (ADR 0232)

`compiled_run.rb` also accepts `OPTCARROT_FIXNUM_NIL_IVARS`, an exact
`Owner#@ivar` list, to A/B the tagged Integer-or-nil embedding against
the control in the same build:

```
OPTCARROT_FIXNUM_NIL_IVARS='Optcarrot::CPU#@opcode' \
  MRBC=3rd/mruby/bin/mrbc ruby tools/optcarrot_probe/compiled_run.rb 180
```

`Optcarrot::CPU#@opcode` is the one field here a declaration can reach
and the sweep cannot: it is written nil in `#initialize` and otherwise
only by `@opcode = fetch(@_pc)`, whose value comes through the NES
per-address `@fetch[addr]` callable table and is opaque to the analysis.

Measured outcome: with `@opcode` embedded, the linked binary's `.text`
is **byte-identical** to the control (2,319,680 bytes both) and the
180-frame wall times are within run-to-run noise. That is the point worth
recording: ivar access is not this benchmark's bottleneck. `iv_bsearch_idx`
is unchanged by embedding either (244 embedded ivars across 50 classes
with or without it), and the dominant compiled-mode cost is the GC
arena -- `gc_gray_rescan` at 31.6% of sampled time, from arena growth
across devirtualized calls that never re-enter `mrb_vm_exec`. The union
is infrastructure for nilable scalars, not an FPS win here.
