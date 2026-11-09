# mruby-bc2cpp-runner

The bc2cpp command as an mruby executable. `mruby-bc2cpp-sources` bakes the bc2cpp source graph for `require`;
this gem names its entry (`BC2CPPRunner.run`), and `bc2cpp_main.rb` is the script the executable runs.

Build (from the repository root):

    cd 3rd/mruby && MRUBY_CONFIG=../../host-libs/mruby-bc2cpp-runner/build_config.rb MRUBY_BUILD_DIR=<dir> rake
    <dir>/bc2cpp-runner/bin/mruby ../../host-libs/mruby-bc2cpp-runner/bc2cpp_main.rb <bc2cpp args>

## Status

The executable loads bc2cpp's whole source graph, and its entry runs the way CRuby's does: with no arguments it prints the
usage, and with a toy program it refuses (not a closed world, as CRuby also does). A real run needs the closed-world
inputs (BC2CPP_BUILD_NAME=closed, its gem list, NATIVE_SRCS, FOREIGN_RUBY_SRCS) that the closed build's rake task sets.
Those have not been run through this executable yet.

Set in the environment of a run: `BC2CPP_RUBY=<repo>/tools/bc2cpp/mruby-ruby` (the wrapper the tools start subprocesses
with, RbConfig.ruby) and `BC2CPP_MRUBY=<dir>/bc2cpp-runner/bin/mruby` (the executable the wrapper runs).

Fixed to get here: `mruby-prism` renders its generated headers when defined, and its `ascii_only?` no longer builds an
Array of every byte (too large for a big source). `mruby-require` supplies `LoadError`, `ScriptError`, `Object#then`,
`Kernel#tap`, `Kernel#Array` as CRuby has it (`Array(nil)` is `[]`), and `File::Stat` without `Struct`. `mruby-env`
gives `ENV`. `mruby-process` gives `Open3` (capture3, capture2, capture2e), `Process` (pid, clock_gettime) and
`Kernel#system`, over a fork/exec primitive. The build adds Onigmo, Marshal (with C++ exception mode), StringIO, YAML,
zlib and the core method/proc gems.

Open items: a closed-world run through this executable, and any gems the closed run needs beyond the set above.
