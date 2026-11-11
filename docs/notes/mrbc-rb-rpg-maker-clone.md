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

Implemented, byte for byte against the fork's mrbc (cli_test.rb: all 737 inputs, every gem's mrblib set, the core mrblib and
every file of bc2cpp/, 12 flag combinations each): `-o`, default output names, `-g`, `--remove-lv`, `-B` (C byte array),
`-B -s`, `-B -S` (cdump.c's C struct dump, with `-s`, and `--remove-lv`, which cdump ignores as mrbc does), `-g -B`,
`-g -B -S` for one or several input files, `-e`/`-E`, `--no-optimize`, `--no-ext-ops` (an operand that needs an OP_EXT is an
error in both), `-` (stdin), `-S` and `-s` without `-B` (mrbc ignores them: the plain binary); and, as text, with the oracle's exit
status: `-c` (`<prog>:<first input>:Syntax OK`, decided by compiling with the emitter), `--version`, `--copyright` (the fork's
text; `MRBC_RB_VERSION` replaces the version line), `-h`, an unknown option, a missing input / output file name / `-B` name
(usage text and status of mrbc.c), and `-v` where the run ends without compiling (mrbc prints the version when it parses the
first `-v`: so `-v` alone, `-v` with an unreadable input or a usage error show it first, as mrbc does).
`bin/mrbc_rb --help` (an addition; mrbc has none, it prints its usage and exits 1 for any unknown switch) lists these, the
additions (`--disasm`, `--help`) and the fallback; `-h` stays byte for byte mrbc's usage.
Handed to the real mrbc (`MRBC_FALLBACK`), or an error naming the reason without it: `-v`/`--verbose` with a program (the C
parser's AST dump, then the disassembly with the addresses of the irep structs: neither is reproducible from a Prism tree/RITE
image byte for byte; `--disasm` is the listing alone), a syntax error (mrbc words its own message), an input after the first that
mrbc cannot open (mrbc still writes the output of the others and exits 0), and a construct the emitter does not cover.

`codedump.rb` is a Ruby port of `src/codedump.c` (the listing `mrbc -v` prints after the AST dump): every instruction of
every irep, local variable names, catch tables, `OP_EXT1..3`, `mrb_sym_dump` quoting. `codedump_test.rb` checks it against
`mrbc -v` (from its first `irep` line on, addresses of the irep structs replaced) on all 739 inputs plus hand-made catch /
OP_EXT / literal cases: identical. The command line exposes it as `--disasm` (an addition; `-v` itself stays with the C mrbc
because of the AST dump).

### The file name symbol ids of `-g -S` (`file_syms.rb`)

`-g -S` writes, per irep, the symbol id of the file name, which is the id the name got in the C mrbc's symbol table. mrbc
interns the first file name before it parses and every further name in the partial hook (`mrb_parser_set_filename`), which
the lexer calls when it reaches the end of the previous file; by then the lexer has interned every identifier, constant,
`@ivar`, `@@cvar`, `$gvar`, label, method name (also a keyword after `.`) and `:sym` of the earlier files (a
`:"a b"` / `"a b": 1` literal is interned by its parser action; `%i[]` words and `a.b = 1`'s `b=` only in codegen, later).
So the id of file k is the build's presym count + 1 + the number of distinct symbols interned before it that take a number:

* a presym (`MRB_PRESYM_MAX` of the mrbc build; the set is the table in its `include/mruby/presym/table.h`) keeps its fixed
  id and takes none: `presym_fork.txt` (the fork's host mrbc, 1472, the default) and `presym_bootstrap.txt` (mruby's own
  bootstrap mrbc, 282) are embedded; `MRBC_RB_PRESYM=fork|bootstrap|<names file or presym/table.h>` chooses;
* `symbol.c` packs a name of at most 4 characters of `[_A-Za-z0-9]` into the symbol value itself (`sym_inline_pack`): no
  number either (that was the missing rule: without it the count was off by the short names).

The token stream comes from `Prism.lex` (identifier tokens correspond to mruby's lexer interns). Checked against the oracle:
all 10 multi-file gem sets (mruby-io, mruby-lcf, rgss, rpg2k, ...), 76 file sets of golden_test, and hand-made cases for
string symbols, labels, heredocs, interpolation, numbered parameters, `__END__` (the one known difference: mruby's lexer
stops at `__END__` for all the files after it).

## Can mruby's own build use it as `build.mrbcfile`?

Yes. Re-run on a copy of rpg-maker-clone's `3rd/mruby` (`gembox 'default'`, `enable_debug`, `enable_test`,
`conf.mrbcfile = .../bin/mrbc_rb`, `MRBC_RB_PRESYM=bootstrap`, `MRBC_FALLBACK` = the C build's bootstrap mrbc): the build
completes and `rake test` (mrbtest) gives the same result as the build with the C mrbc: 1869 assertions, 1866 OK, 0 KO,
1 Crash (the sandbox's UDPSocket test, the same in the C build), 2 Skip. All 97 generated C files (`gem_init.c`,
`gem_test.c`, `mrblib.c`, `assert.c`; the two builds in the same directory, as the paths are embedded) are
**byte-identical** to the C-mrbc build, `mruby-io` included; no `MRBC_RB_LOOSE_FILENAME_SYM`. 122 compiles were served by the
emitter, 3 (mrbtest's `test/t/*.rb`: an empty interpolated heredoc, a destructuring parameter, a syntax Prism rejects) by
the fallback; without `MRBC_FALLBACK` those stop the build and name the file.

* The file must exist and be executable at `build.mrbcfile` (it is a prerequisite of every `gem_init.c` and run by popen);
  `bin/mrbc_rb` has a `#!/usr/bin/env ruby` line and needs Ruby with Prism (Ruby 3.4+). `conf.mrbcfile=` (an external mrbc) also
  stops mruby from building its own bootstrap mrbc (`create_mrbc_build`), which is the point; cross builds take the host's.
* `MRBC_RB_PRESYM=bootstrap` only to match the C mrbc's bytes (the id numbers of the file names; the program is the same
  without it, since the generated `*_init_syms` assigns the names at start-up). The default set is the fork's host mrbc.
* `MRBC_FALLBACK=<C mrbc>` only if something outside the gems' mrblib is compiled: mrbtest's `test/t/*.rb` (see above).

The build_config change (host build) is in the patch below, opt-in with `MRUBY_MRBC_RB=1`.

### The library and the in-process hook (`cli.rb`, `cdump.rb`, `mruby_build.rb`)

`bin/mrbc_rb` is a 3-line wrapper (`exit MrbcRb::Cli.run(ARGV)`); everything it did lives in `bc2cpp/tools/mrbc_rb/cli.rb`:
`MrbcRb::Cli.run(argv, stdin:, stdout:, stderr:, env:, prog:)` returns the exit status (no `exit`, no `ENV`/`$stdout` reads; the
fallback mrbc is a subprocess whose output and status are passed on). Structured APIs below it: `MrbcRb.compile_result(src, name)` /
`MrbcRb.compile_files_result([[src, name], ...])` return a `MrbcRb::Result` (`image` = the RITE bytes, `tree` = the irep tree
`RiteDump::Irep` built from the emitter's own data), and `MrbcRb::CDump.dump(tree, name, static:, file_syms:)` writes `-B -S` from a
tree (`CDump.strip` applies `-g` / `--remove-lv` to a tree; `RiteDump.cstruct(image)` keeps the bytes path for `.mrb` input).
`--disasm` and `-S` no longer parse the image they just built (`lib_test.rb` checks that tree == `RiteDump.parse(image)` on 703 inputs).

mruby's own build is Ruby, so it can skip the spawn too. `mruby_build.rb` prepends a `MRuby::Command::Mrbc#run` that builds the same
command line and calls `Cli.run` in the rake process (one Prism load for the whole build, no ~0.2 s process start per file); it only
serves a build whose `mrbcfile` is `bin/mrbc_rb`, anything else runs as before. For rpg-maker-clone's `build_config.rb`, in
the `MRUBY_MRBC_RB=1` block of the patch below (the `require` can be at the top of the file):

```ruby
  if ENV['MRUBY_MRBC_RB'] == '1'
    require File.expand_path('3rd/nfcxx/bc2cpp/tools/mrbc_rb/mruby_build', __dir__)   # in-process Mrbc#run
    conf.mrbcfile = MrbcRb::MrubyBuild::WRAPPER   # = 3rd/nfcxx/bc2cpp/tools/mrbc_rb/bin/mrbc_rb: skips mruby's bootstrap mrbc
    ENV['MRBC_RB_PRESYM'] ||= 'bootstrap'
  end
```

Measured on the scratch copy of `3rd/mruby` (default gembox, `enable_debug`, `enable_test`, `all test`, `MRBC_RB_PRESYM=bootstrap`,
`MRBC_FALLBACK` = the bootstrap mrbc, 4 cores, minirake without `-j`): C-mrbc build (bootstrap mrbc compiled first) 31 s;
`mrbc_rb` spawned per file 38.8 s; in-process hook 24.1 s. Both emitter builds: mrbtest 1866/1869 (as before), all 97 generated C
files byte-identical to the C-mrbc build, 124 compiles by the emitter and 1 by the fallback.

### A build without a C mrbc: `fallback_provider`

`conf.mrbcfile =` leaves the build without a real mrbc, so a file the emitter does not cover (mrbtest's `test/t/*.rb`) has nothing
to fall back to unless `MRBC_FALLBACK` is set. `MrbcRb::MrubyBuild.fallback_provider = -> { ...build it...; path }` lets the
build provide one on demand: the callable runs at most once (thread-safe), only when a file is handed to the fallback and
`MRBC_FALLBACK` is not set in ENV, and a build the emitter covers completely never builds a C mrbc. rpg-maker-clone's
`build_config.rb` points it at the `host/mrbc` sub-build that mruby would have made first. `mruby_build_test.rb` checks it
without an oracle.

## Verification modes and the CI policy (`BC2CPP_MRBC_RB`)

| Mode | Needs a mrbc | What it checks |
| --- | --- | --- |
| (unset) | no | nothing: the emitter's bytes are used as they are; mrbc only serves what the emitter does not cover |
| `verify` | yes (`MRBC`) | every compile also runs `mrbc -g`; any byte difference aborts. With `BC2CPP_MRBC_SNAPSHOT_RECORD=<file>` each compile appends `<key> <value>` |
| `snapshot` | no | the emitter's image must hash to what mrbc once wrote for the same input (`bc2cpp/tools/mrbc_rb/snapshot.txt`, `snapshot_world.txt`); an input that is not in the table aborts |
| `0` | yes | always mrbc |

Table keys are content hashes (the files' bytes, in order; world files by their path relative to the world root only when the
source reads `__FILE__`/`__dir__`), so the table does not depend on where a checkout is or on which world commit it is at.
**A changed world pin alone does not fail anything**: `snapshot.rb --verify/--check` print one note ("world pin changed from X to Y:
inputs are matched by content hash ...") and the `# world:` / `# oracle:` headers are informational. What fails is an input that is
not in the table, or whose value differs from the emitter's (drift of the emitter or, with the oracle, of mrbc). After a bump that
changes many inputs they are one line ("world pin changed from X to Y: N inputs not in snapshot; run snapshot.rb --update ...")
instead of N. `snapshot_test.rb` checks this on a fake world at another commit.

Keeping the table complete: run the job in `verify` with `BC2CPP_MRBC_SNAPSHOT_RECORD`, then
`MRBC=<fork mrbc> BC2CPP_RPG_DIR=<world> ruby bc2cpp/tools/mrbc_rb/snapshot.rb --update --from-record <record files>` (merges the
records into `snapshot_world.txt`, refuses to write when the emitter differs from mrbc). In CI: dispatch `bc2cpp.yml` with
`mrbc_rb=record`; the world and checks jobs run `verify` with a record file each and upload it (`mrbc-record-*` artifacts).

Policy per job (measured on the pinned world, `bc2cpp.rb` compile stage of each job under `BC2CPP_NO_MRBC=1`):

* `mrbc-snapshot`: the one job with the oracle (builds it, `--check`) and the oracle-free test run.
* `world` `pathb_qbe_emit`, `pathb_borrowck`: `snapshot`. 2 inputs each (the closed world's mrblib sets plus the generated script
  program), all in the table after `--update --from-record` (3 entries in all); 0 missing. A change to `scripts/pathb-qbe-emit.rb` or
  `scripts/pathb-borrowck.rb` changes the program's hash: the job then says "input not in snapshot" and the entry is re-recorded as above.
* `world` `optcarrot`: stays on `verify`. It compiles a generated `benchmark.rb` written under a temporary directory that is
  part of the key (`__FILE__`), so no table entry can match.
* `checks` (3 shards): stay on `verify`. The fixtures compile generated programs: of the 24 checks run to completion, 64 distinct
  inputs were recorded and none was in the table. A `record` dispatch collects them for a later switch.
* Neither world job gets faster by itself: the sealed libmruby build still needs a real `mrbc` binary (`self.mrbcfile`), and the
  duplicate `mrbc -g` run of `verify` costs no measurable time (36.5 s snapshot vs 36.2 s verify, 37.3 s vs 38.0 s for the compile stage of
  `pathb_qbe_emit` and `pathb_borrowck`). What snapshot mode removes is the dependence on the oracle for those inputs, not the oracle build.

## What remains

* mrbtest's test files and any other file the emitter raises Unsupported on need either `MRBC_FALLBACK` or more emitter
  constructs (the other agent's area). `BC2CPP_MRBC_RB_LOG` / `MRBC_RB_LOG` list them.
* The CI fixture checks and `BC2CPP_MRBC_RB=verify` still want a C mrbc as the oracle: `host_mrbc` stays. With
  `MRUBY_MRBC_RB=1` the host build's `mrbcfile` is the script, so `task host_mrbc` (it depends on `MRuby.targets['host'].mrbcfile`) no
  longer builds a binary: point it at `exefile("#{build_dir}/bin/mrbc")` of the `mruby-bin-mrbc` gem (still in the host build) if
  the oracle build is wanted.
* `-v`, `--verbose` (the C parser's AST dump before the listing, which `--disasm` reproduces) need the C mrbc.

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
@@ -649,6 +649,17 @@
 
   enable_debug
 
+  # MRUBY_MRBC_RB=1: mruby's own gem build (every gem's mrblib, the core mrblib and mrbtest's test files, each compiled to a C
+  # array by `mrbc -B<sym> -o- -S [-s] files`) runs nfcxx's mrbc-compatible command instead of the C mrbc, so no mrbc has to be
+  # built first (`conf.mrbcfile=` makes mruby skip its own `mrbc` bootstrap build). What the emitter does not cover goes to the
+  # real mrbc named by MRBC_FALLBACK (mrbtest's test/t/*.rb has such files); without MRBC_FALLBACK the build stops and says which.
+  #  * enable_debug above adds `-g` to mrbc's options: `-g -S` of several files is reproduced (file name symbol ids,
+  #    file_syms.rb); MRBC_RB_PRESYM=bootstrap makes them the ones mruby's own bootstrap mrbc would write (only for byte equality).
+  if ENV['MRUBY_MRBC_RB'] == '1'
+    conf.mrbcfile = File.expand_path('3rd/nfcxx/bc2cpp/tools/mrbc_rb/bin/mrbc_rb', __dir__)
+    ENV['MRBC_RB_PRESYM'] ||= 'bootstrap'
+  end
+
   if cross
     # Force native host compilers so `mrbc` runs on the build machine even when
     # CMake hands us a cross compiler via CC/CXX (emscripten's em++, or
```
