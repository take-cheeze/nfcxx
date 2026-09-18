# optcarrot / bc2cpp scoping probe

A scoping investigation, not a shipped tool: how much of
[optcarrot](https://github.com/mame/optcarrot) (the pure-Ruby NES emulator
used as a Ruby-implementation benchmark) runs under this project's own
vendored mruby, as a candidate stress test for `tools/bc2cpp`. It does not
touch the RPG engine's build, gems, or bc2cpp's own closed-world registry --
except for one real mruby core fix (see point 4 below), which does.

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

Confirmed *not* a problem: the default (non-`--opt`) code path -- the actual
CPU/PPU emulation hot loop -- never calls `eval`/`send`/`define_method`; those
only appear behind optcarrot's own `--opt` runtime-codegen feature, which
this probe doesn't enable and a bc2cpp target wouldn't need either.

## Still open (not started)

Whether/how much of optcarrot's method bodies bc2cpp itself can actually
compile is unmeasured. bc2cpp is currently wired into this project's own 3
gems' `mrbgem.rake` files for its whole-program closed-world method registry;
pointing it at optcarrot means feeding it a new standalone source set, then
seeing how it lands against its real limits: no top-level/class-body
compilation (not a problem here -- only method bodies need it), no
splat/keyword-arg send sites, and only partial block/`SENDB` support (today
limited to specific inlined patterns like `.times`/`.each`/`.collect`/`.sort`)
against optcarrot's actual method shapes (`CPU#run`'s dispatch table,
`PPU#run`'s pixel loop).

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
- `mruby_build_config.rb` -- the `MRUBY_CONFIG` used to build a probe-only
  `mruby`/`mrbc` host binary (full-core gembox + `mruby-onig-regexp`). Not
  part of the project's real build.
- `../../patches/mruby-module-function-scope.patch` -- see point 4 above;
  this one *is* part of the project's real build.

## Reproducing

```
git submodule update --init --depth 1 3rd/mruby 3rd/mruby-onig-regexp 3rd/optcarrot
# Needs oniguruma headers -- on Debian/Ubuntu: apt-get install libonig-dev
# (otherwise mruby-onig-regexp falls back to a slow bundled onigmo build)

./scripts/apply_mruby_patch.bash 3rd/mruby "$(pwd)/patches/mruby-module-function-scope.patch"
cd 3rd/mruby
MRUBY_CONFIG=$(pwd)/../../tools/optcarrot_probe/mruby_build_config.rb rake -j"$(nproc)"
cd -

ruby tools/optcarrot_probe/build_bundle.rb /tmp/full_probe.rb
./3rd/mruby/bin/mruby /tmp/full_probe.rb 3rd/optcarrot/examples/Lan_Master.nes 180
```
