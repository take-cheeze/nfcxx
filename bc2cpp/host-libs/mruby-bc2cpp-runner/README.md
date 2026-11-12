# mruby-bc2cpp-runner

The bc2cpp command as an mruby executable. `mruby-bc2cpp-sources` bakes the bc2cpp source graph for `require`;
this gem's C main calls its entry (`BC2CPPRunner.run`).

Build from nfcxx's repository root (requires the EDG toolchain from `scripts/setup-edg.sh`):

```sh
scripts/setup-bc2cpp.sh
scripts/bc2cpp --annotated path/to/program.rb
```

The setup script fetches the pinned test world and the Prism/RBS submodules, then builds the optimized runner with
nfcxx's gcc backend. `BC2CPP_WORLD_ROOT` or `BC2CPP_RPG_DIR` selects an existing world. The command still requires
bc2cpp's closed-world inputs (`BC2CPP_BUILD_NAME`, `BC2CPP_BUILD_GEMS`, `NATIVE_SRCS`, `FOREIGN_RUBY_SRCS`), just as CRuby
does. Existing build integrations can use the path printed by setup as `BC2CPP_MRUBY_RUNNER`.

`BC2CPP_RUNNER_CXX` selects another C++ compiler; `NFCXX_BACKEND` selects nfcxx's backend (gcc by default).
`BC2CPP_RUNNER_BUILD_DIR` selects the output directory. Use separate directories for different compilers or flags.
The runner-specific compiler setting keeps nfcxx's bootstrap helpers on the host compiler; globally setting
`CXX=nfcxx` can make those helpers recursively build themselves.

This executable runs baked mruby bytecode. The experimental `bc2cpp-self` build, which translates bc2cpp's own
Ruby methods to C++, is built by `scripts/setup-bc2cpp-self.sh` and run by `scripts/bc2cpp-self`.
See [the self-AOT build instructions](../../../docs/notes/bc2cpp-self-aot.md).

The equivalent direct rake build, from the selected world's `3rd/mruby`, is:

    BC2CPP_WORLD_ROOT=<world> MRUBY_CONFIG=<nfcxx>/bc2cpp/host-libs/mruby-bc2cpp-runner/build_config.rb MRUBY_BUILD_DIR=<dir> rake
    <dir>/bc2cpp-runner/bin/mruby <bc2cpp args>

## Status

The nfcxx/gcc build passes a closed-world fixture: generated C++ and bytecode match CRuby exactly, and nfcxx compiles
and links that output against the runner's own runtime. Interpreted and compiled arithmetic, Unicode strings,
division-by-zero exceptions and executable-file checks agree. The fixture defaults to native mrbc; set
`BC2CPP_RUNNER_MRBC_MODE=verify` to require the Ruby emitter's bytes to match native mrbc too. Native, default and
strict verification modes have all been checked.

Reproduce with a full pinned-world checkout selected by `BC2CPP_WORLD_ROOT`:

```sh
runner=$(scripts/setup-bc2cpp.sh)
MRBC="$(dirname "$runner")/mrbc" BC2CPP_MRUBY_RUNNER="$runner" \
  CXX="$PWD/nfcxx" NFCXX_BACKEND=gcc ruby tests/bc2cpp/runner_generation.rb
ruby tests/bc2cpp/source_baking.rb
```

Set in the environment of a run: `BC2CPP_RUBY=<nfcxx>/bc2cpp/tools/bc2cpp/mruby-ruby` (the wrapper the tools start subprocesses
with, RbConfig.ruby) and `BC2CPP_MRUBY=<dir>/bc2cpp-runner/bin/mruby` (the executable the wrapper runs).

Fixed to get here: `mruby-prism` renders its generated headers when defined, and its `ascii_only?` no longer builds an
Array of every byte (too large for a big source). `mruby-require` supplies `LoadError`, `ScriptError`, `Object#then`,
`Kernel#tap`, `Kernel#Array` as CRuby has it (`Array(nil)` is `[]`), and `File::Stat` without `Struct`. `mruby-env`
gives `ENV`. `mruby-process` gives `Open3` (capture3, capture2, capture2e), `Process` (pid, clock_gettime) and
`Kernel#system`, over a fork/exec primitive. The build adds Onigmo, Marshal (with C++ exception mode), StringIO, YAML,
zlib and the core method/proc gems.

Full RPG builds remain outside this fixture's coverage.
