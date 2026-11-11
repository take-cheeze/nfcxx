# Replacing mrbc with mrbc_rb in the rpg-maker-clone build

rpg-maker-clone (a separate repository that vendors nfcxx as `3rd/nfcxx`) is not edited from here; the patch it needs is at the
end of this note. This note says where the build uses `mrbc`, what nfcxx now offers, and what is left.

## Where the build uses mrbc

| Where | Class | What it needs |
| --- | --- | --- |
| `bc2cpp/tools/bc2cpp/irep.rb` `run_mrbc` (every bc2cpp compile: `compile_ireps`) | (a) | optional now: the emitter compiles; `MRBC`/`mrbc` on PATH is only a fallback |
| `mruby-core-compiled/mrbgem.rake`, `mruby-lcf-compiled/mrbgem.rake`: `spec.build.mrbcfile` in the `generated` prerequisites | (b) | only an ordering edge ("codegen must not start before mrbc exists"); not needed any more |
| `bc2cpp/tools/bc2cpp/compiled_gems.rb` `bc2cpp_compiled_gem_job`: `'MRBC' => spec.build.mrbcfile` | (b) | now passed only with `BC2CPP_USE_BUILD_MRBC=1`; an `MRBC` in the caller's environment reaches bc2cpp.rb as is |
| `cmake/build-mruby.cmake` `rake host_mrbc` (target `mruby_host_mrbc`), `build_config.rb` `task host_mrbc` | (b) | builds the bootstrap mrbc for the CI check jobs (`MRBC=` of the fixture checks and `BC2CPP_MRBC_RB=verify`); not part of the product build |
| `.github/workflows/build.yml` (`MRBC=` from `build-closed-*/host/**/bin/mrbc`, `MRBC:` in the sweep step) | (b) | the oracle for the fixture checks and the verify mode; keep |
| `bc2cpp/scripts/bc2cpp/*_check.rb`, `tests/bc2cpp` | (b) | test fixtures: `SKIP: set MRBC` without it, they compile through `compile_ireps` so they also work with the emitter, but their gates say "needs MRBC"; left as they are |
| `bc2cpp/host-libs/mruby-bc2cpp-sources/mrbgem.rake` (`mrbc -g -B... -o out file`) | (c) | now runs `bin/mrbc_rb` first, real mrbc as `MRBC_FALLBACK` (`BC2CPP_MRBC_RB=0` runs mrbc itself) |
| mruby's gem build: `lib/mruby/gem.rb` (every gem's mrblib: `mrbc -B<sym> -o- -S -s <files>`), `tasks/mrblib.rake` (core mrblib), `mrbgems/mruby-test/mrbgem.rake` (`-B -o- [-s]` for mrbtest) | (c) | `build.mrbcfile`; see below |

## The environment contract of bc2cpp

* `MRBC=<mrbc>`: the fallback for an input the emitter does not cover. Unset: `mrbc` on PATH if there is one.
* No mrbc at all (unset, not executable, none on PATH): the emitter serves every input. An input it does not cover (Unsupported,
  a parse error, a crash) aborts the run with `bc2cpp: the Ruby emitter (mrbc_rb) cannot compile ... and no mrbc is available`,
  naming the files and the reason.
* `BC2CPP_NO_MRBC=1`: never run an mrbc, even when one is set or on PATH.
* `BC2CPP_MRBC_RB=0`: always mrbc (aborts when there is none). `=verify`: both compile, bytes must match (needs an mrbc).
* `BC2CPP_MRBC_RB_LOG=<file>`: one line per compile, `emitter`, `mrbc` or `none` (the abort).
* `BC2CPP_USE_BUILD_MRBC=1` (compiled_gems.rb): hand `spec.build.mrbcfile` to bc2cpp as `MRBC`.

Checked on the scratch world (62 sources, the four compiled gems): a run with `MRBC` unset and no `mrbc` on PATH writes the same
`_gen.cpp`, `_decls.h`, `_entry.h` and `.mrb` files, byte for byte, as a run with `MRBC` set (the only textual difference is the
output directory name inside `#include` lines); every compile was served by the emitter.

## `bc2cpp/tools/mrbc_rb/bin/mrbc_rb`: mrbc's command line

Flags of `mrbc.c`: `-o<file>`/`-o <file>`, `-S`, `-B<sym>`/`-B <sym>`, `-c`, `-v`, `-g`, `-s`, `-e`/`-E`, `-h`, `--version`,
`--verbose`, `--copyright`, `--remove-lv`, `--no-ext-ops`, `--no-optimize`, several inputs (one program), `-` for stdin.

Implemented, byte for byte against the fork's mrbc (cli_test.rb: all 736 inputs, every gem's mrblib set, the core mrblib and
every file of bc2cpp/): `-o`, default output names, `-g`, `--remove-lv`, `-B` (C byte array), `-B -s`, `-B -S` (cdump.c's C
struct dump, with `-s`, and `--remove-lv`, which cdump ignores as mrbc does), `-g -B`, `-g -B -S` for one input file, `-e`/`-E`.
Handed to the real mrbc (`MRBC_FALLBACK`), or an error naming the reason without it: `-c`, `-v`, `--verbose`, `--version`,
`--copyright`, `-h`, `--no-ext-ops`, `--no-optimize`, stdin, a file mrbc cannot open, a syntax error (mrbc words its own), a
construct the emitter does not cover, and `-g -B -S` of several files.

`-g -S` writes, per irep, the symbol id of the file name, which is the id the name got in the C mrbc's symbol table. For one
input that is that build's presym count plus one (`MRBC_RB_FILENAME_SYM_BASE`, default 1472 = the fork's mrbc; mruby's own bootstrap
mrbc has 282: `MRB_PRESYM_MAX` in its `include/mruby/presym/id.h`). For several files it depends on what the parser interned
between the files. The generated `<name>_init_syms` assigns `filename_sym` from the file name at start-up, so the value is a
placeholder: `MRBC_RB_LOOSE_FILENAME_SYM=1` numbers the files base+1, base+2, ... (not mrbc's bytes, the same program).

## Can mruby's own build use it as `build.mrbcfile`?

Yes, with two conditions. Tried on a copy of rpg-maker-clone's `3rd/mruby` (`gembox 'default'`, `enable_debug`, `enable_test`,
`conf.mrbcfile = .../bin/mrbc_rb`): the build completes, `bin/mruby` runs, and mruby's test suite (`mrbtest`, 1869 assertions)
passes except one sandbox network test (UDPSocket). Of the 43 generated `gem_init.c`/mrbtest C files, 42 are identical to the
build with the C mrbc and `mruby-io` (several files, `-g -S`) differs only in the file name symbol ids.

* The file must exist and be executable at `build.mrbcfile` (it is a prerequisite of every `gem_init.c` and run by popen);
  `bin/mrbc_rb` has a `#!/usr/bin/env ruby` line and needs Ruby with Prism (Ruby 3.4+). `conf.mrbcfile=` (an external mrbc) also
  stops mruby from building its own bootstrap mrbc (`create_mrbc_build`), which is the point; cross builds take the host's.
* Two environment variables: `MRBC_RB_LOOSE_FILENAME_SYM=1` while `enable_debug` puts `-g` in mrbc's options (the host build of
  rpg-maker-clone does; the Wio/PSP/Maix cross builds already strip it), and `MRBC_FALLBACK=<C mrbc>` only if something outside
  the gems' mrblib is compiled: mrbtest's `test/t/*.rb` (the emitter does not cover some constructs there: `a[1] = 2` as an
  explicit call, `while` as a value, ...). The gems' mrblib and the core mrblib are all covered.

The build_config change (host build) is in the patch below, opt-in with `MRUBY_MRBC_RB=1`.

## What remains

* mrbtest's test files and any other file the emitter raises Unsupported on need either `MRBC_FALLBACK` or more emitter
  constructs (the other agent's area). `BC2CPP_MRBC_RB_LOG` / `MRBC_RB_LOG` list them.
* The CI fixture checks and `BC2CPP_MRBC_RB=verify` still want a C mrbc as the oracle: `host_mrbc` stays. With
  `MRUBY_MRBC_RB=1` the host build's `mrbcfile` is the script, so `task host_mrbc` (it depends on `MRuby.targets['host'].mrbcfile`) no
  longer builds a binary: point it at `exefile("#{build_dir}/bin/mrbc")` of the `mruby-bin-mrbc` gem (still in the host build) if
  the oracle build is wanted.
* `-g -S` of several files is not byte-identical (placeholders), see above. `-c`, `-v`, `--verbose` need the C mrbc's text.

## Patch for take-cheeze/rpg-maker-clone (apply with `patch -p1` from its root)

```diff
--- a/mruby-core-compiled/mrbgem.rake
+++ b/mruby-core-compiled/mrbgem.rake
@@ -53,9 +53,11 @@
 
   generated = "#{build_dir}/core_compiled_gen.cpp"
 
-  # bc2cpp.rb runs MRBC: without this edge `rake -m` can start codegen before
-  # the bootstrap mrbc exists.
-  file generated => [*bc2cpp_tool_srcs, compiled_gems_rb, compiled_gems_yml, spec.build.mrbcfile, *closed_world_prereqs, *native_srcs,
+  # bc2cpp.rb compiles the Ruby sources with its own emitter (tools/mrbc_rb), so this task needs no mrbc binary and no
+  # `spec.build.mrbcfile` edge. (BC2CPP_USE_BUILD_MRBC=1 hands the build's mrbc to bc2cpp as a fallback for a source the
+  # emitter does not cover; then the edge is needed again, so it is added only in that mode.)
+  mrbc_edge = ENV['BC2CPP_USE_BUILD_MRBC'] == '1' ? [spec.build.mrbcfile] : []
+  file generated => [*bc2cpp_tool_srcs, compiled_gems_rb, compiled_gems_yml, *mrbc_edge, *closed_world_prereqs, *native_srcs,
                      *foreign_ruby_srcs, *bc2cpp_host_native_srcs(build.name, "#{dir}/..")] do |t|
     # SHARED_GENERATION: with every other compiled gem of this build that is out of date, in one
     # bc2cpp.rb analysis (tools/bc2cpp/compiled_gems.rb bc2cpp_compiled_gem_job holds this gem's environment).
--- a/mruby-lcf-compiled/mrbgem.rake
+++ b/mruby-lcf-compiled/mrbgem.rake
@@ -111,9 +111,11 @@
 
   generated = "#{build_dir}/lcf_compiled_gen.cpp"
 
-  # bc2cpp.rb runs MRBC: without this edge `rake -m` can start codegen before
-  # the bootstrap mrbc exists.
-  file generated => [*bc2cpp_tool_srcs, compiled_gems_rb, compiled_gems_yml, spec.build.mrbcfile, *closed_world_prereqs, *native_srcs,
+  # bc2cpp.rb compiles the Ruby sources with its own emitter (tools/mrbc_rb), so this task needs no mrbc binary and no
+  # `spec.build.mrbcfile` edge. (BC2CPP_USE_BUILD_MRBC=1 hands the build's mrbc to bc2cpp as a fallback for a source the
+  # emitter does not cover; then the edge is needed again, so it is added only in that mode.)
+  mrbc_edge = ENV['BC2CPP_USE_BUILD_MRBC'] == '1' ? [spec.build.mrbcfile] : []
+  file generated => [*bc2cpp_tool_srcs, compiled_gems_rb, compiled_gems_yml, *mrbc_edge, *closed_world_prereqs, *native_srcs,
                      *foreign_ruby_srcs, *bc2cpp_host_native_srcs(build.name, "#{dir}/..")] do |t|
     # SHARED_GENERATION: with every other compiled gem of this build that is out of date, in one
     # bc2cpp.rb analysis (tools/bc2cpp/compiled_gems.rb bc2cpp_compiled_gem_job holds this gem's environment).
--- a/build_config.rb
+++ b/build_config.rb
@@ -649,6 +649,18 @@
 
   enable_debug
 
+  # MRUBY_MRBC_RB=1: mruby's own gem build (every gem's mrblib, the core mrblib and mrbtest's test files, each compiled to a C
+  # array by `mrbc -B<sym> -o- -S [-s] files`) runs nfcxx's mrbc-compatible command instead of the C mrbc, so no mrbc has to be
+  # built first (`conf.mrbcfile=` makes mruby skip its own `mrbc` bootstrap build). What the emitter does not cover goes to the
+  # real mrbc named by MRBC_FALLBACK (mrbtest's test/t/*.rb has such files); without MRBC_FALLBACK the build stops and says which.
+  #  * enable_debug above adds `-g` to mrbc's options, and `-g -S` of several files needs MRBC_RB_LOOSE_FILENAME_SYM=1: the
+  #    file name symbol ids in the C structs are placeholders (the generated *_init_syms assigns the real ones at start-up).
+  #  * MRBC_RB_FILENAME_SYM_BASE: the mrbc build's presym count, only to match a C mrbc's bytes (not needed to run).
+  if ENV['MRUBY_MRBC_RB'] == '1'
+    conf.mrbcfile = File.expand_path('3rd/nfcxx/bc2cpp/tools/mrbc_rb/bin/mrbc_rb', __dir__)
+    ENV['MRBC_RB_LOOSE_FILENAME_SYM'] ||= '1'
+  end
+
   if cross
     # Force native host compilers so `mrbc` runs on the build machine even when
     # CMake hands us a cross compiler via CC/CXX (emscripten's em++, or
```
