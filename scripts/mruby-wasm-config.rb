# Build configuration for scripts/setup-mruby-wasm.sh: the interpreter of scripts/mrb (scripts/mruby-tool-config.rb)
# built with Emscripten for the browser, so that the wasm explorer's page can run scripts/pathb-wasm-emit.rb itself
# (docs/notes/pathb-wasm-frontend.md). The gems are the tool's, without the regexp and JSON gems (no script that runs
# in the page uses them) and the socket and task HALs. The host build only makes mrbc, which compiles mrblib.
MRuby::Build.new do |conf|
  conf.toolchain :gcc
  %w[hal-posix-io hal-posix-dir].each { |g| conf.gem core: g }
end

MRuby::CrossBuild.new('wasm') do |conf|
  conf.toolchain :emscripten
  %w[hal-posix-io hal-posix-dir].each { |g| conf.gem core: g }
  %w[mruby-io mruby-pack mruby-sprintf mruby-string-ext mruby-array-ext mruby-hash-ext mruby-set
     mruby-enum-ext mruby-numeric-ext mruby-kernel-ext mruby-object-ext mruby-symbol-ext mruby-range-ext
     mruby-error mruby-exit mruby-bigint mruby-bin-mruby].each { |g| conf.gem core: g }
  conf.cc.defines << 'MRB_ARY_LENGTH_MAX=0'   # as the tool (scripts/mruby-tool-config.rb)
  # Integer is 64-bit, as on the tool's 64-bit host: mruby makes it 32-bit on a 32-bit target (wasm32), and the scripts
  # compute 64-bit values (LEB128 encodings, masks) with it. A 32-bit Integer changed the emitter's output.
  conf.cc.defines.concat %w[MRB_INT64 MRB_NO_BOXING]   # mruby needs MRB_NO_BOXING for a 64-bit Integer on wasm32
  conf.cc.flags << '-O2'
  # A module, as the front end (setup-pathb.sh): createMruby, one instance per run, callMain, the in-memory file system.
  conf.linker.flags.concat %w[-O2 -sMODULARIZE=1 -sEXPORT_NAME=createMruby -sINVOKE_RUN=0 -sEXIT_RUNTIME=1
    -sALLOW_MEMORY_GROWTH=1 -sSTACK_SIZE=4MB -sFORCE_FILESYSTEM=1 -sENVIRONMENT=web,worker,node
    -sEXPORTED_RUNTIME_METHODS=callMain,FS,ENV]
  conf.exts.executable = '.js'
end
