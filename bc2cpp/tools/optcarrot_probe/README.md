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

Timing (180 frames): CRuby ~3.8s (~54 fps) vs. this mruby interpreter
~37.3s (~4.8-6 fps) -- roughly 10x slower on the plain interpreter, which is
the gap a bc2cpp-style AOT compiler would aim to close.

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
directly from that script. The full report lives at
`docs/optcarrot_bc2cpp_coverage.txt`, the same convention
`docs/bc2cpp_coverage.txt` sets for the real project -- regenerate it after
any bc2cpp.rb change with `MRBC=path/to/host/mrbc ruby
tools/optcarrot_probe/optcarrot_bc2cpp_coverage_report.rb`.

**Result: 362/383 methods (94.5%) compile clean**, up from an initial
92.2% baseline (measured with zero bc2cpp code changes) after two real
`tools/bc2cpp/bc2cpp.rb` fixes landed alongside this probe (both verified
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
2. **A new `INTERN` opcode case**, unconditional (unlike `SUPER_TARGETS`,
   no whole-program fact to verify -- `OP_INTERN` is a pure, always-safe
   in-place String->Symbol conversion, `src/vm.c`'s own `mrb_ensure_
   string_type` + `mrb_intern_str`). optcarrot's `opt.rb` builds symbols
   dynamically (`:"#{...}"`-shaped); this is a genuine new bc2cpp
   capability, not optcarrot-specific, so it's unconditional the same way
   the pre-existing `STRCAT` case is.

Both hot-path entry points compile clean with real devirtualization already
firing -- `CPU#run` (the fetch/dispatch loop) gets a direct C++ call for
`do_clock`, proven monomorphic program-wide (`LEXICAL_SELF`); `PPU#run`
(the pixel-rendering loop, itself built on a `Fiber` internally) correctly
falls back to real dynamic dispatch only where the receiver's class
genuinely isn't known (`POLY :loglevel`) and to a wrapped-cfunc block
fallback for its one `Fiber.new { ... }` block.

The remaining 21 errored methods, by `#error` reason
(`docs/optcarrot_bc2cpp_coverage.txt` has the full, current breakdown):

```
    12  unhandled opcode BLOCK
    12  unhandled opcode SENDB
     7  unhandled opcode ARGARY
     7  unhandled opcode SUPER
     4  SEND/SSEND has a splat and/or keyword argument list (n=...)
     1  unhandled opcode EXCEPT
    43  total (a method can carry more than one #error)
```

Mostly concentrated in the `--opt` runtime-codegen machinery itself
(`CodeOptimizationHelper`/`OptimizedCodeBuilder` -- string-building,
`gsub`/regex-heavy methods that were never going to be AOT-compilable
candidates, `--opt` being metaprogrammed source generation by design). The
remaining `SUPER` count is exactly the `SUPER Ra n=*` zsuper-with-multiple-
params shape described above (`#initialize`/`#poke_0`/`#poke_3`), tied to
the `ARGARY` count -- a real, scoped, larger codegen feature, not attempted
here. `docs/bc2cpp_coverage.txt`'s own `#error` breakdown for the real
project shows the same `BLOCK`/`SENDB`/`SUPER` opcode gaps, so none of
these are optcarrot-specific.

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
`gperf`/`bison` versions) just to regenerate `docs/bc2cpp_coverage.txt`
for comparison -- which was tried first and produces spurious diffs
(different `mrbc` binary, not a real behavior change) rather than genuinely
mismatching output.

Not yet attempted: checking whether the 362 "compiled clean" methods
produce *correct* output (this only confirms bc2cpp's own compiler accepted
them without a `#error`, the same bar `docs/bc2cpp_coverage.txt`'s own
numbers measure for the real project -- not that the generated C++ was run
and its output checked against CRuby/mruby's own, the way the
headless-benchmark checksum above verifies the *interpreted* path), or
adding support for `BLOCK`/`SENDB`/`ARGARY`/splat-kwarg `SEND`/`EXCEPT`.

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
```
