# Build configuration for scripts/setup-poly.sh: the mruby that lib/poly (nfcpoly) embeds. Unlike
# scripts/mruby-tool-config.rb (a standalone interpreter for the build's own scripts), this one builds only
# the library and its host tool mrbc, and it turns C++ exceptions on:
#
#   conf.enable_cxx_exception   mruby's raise is `throw`, MRB_TRY is try/catch. mruby compiles src/vm.c, error.c
#                               and gc.c, and the compiler gem's parser and code generator, as C++ (it wraps
#                               them in generated *-cxx.cxx files); everything else stays C. With nfcxx as the
#                               C++ compiler that is EDG's exception runtime, the same one the embedding
#                               program's `throw` and `catch` use, so a script error unwinds the C++ frames
#                               between the raise and the catch (and runs their destructors) instead of
#                               longjmp-ing over EDG's try stack. docs/notes/poly.md, "Exceptions".
#
# Compilers come from the environment: MRUBY_CC (nfcc) for C, MRUBY_CXX (nfcxx) for the C++ files and the link.
# NFCXX_BACKEND picks the back end of both.
#
# No mruby-io, mruby-exit, mruby-time or mruby-sleep: a script gets no files, no exit() and no clock unless the
# embedding program binds them (nfcpoly has no sandbox, but it need not hand out the host by default).
MRuby::Build.new do |conf|
  conf.toolchain :gcc

  %w[mruby-compiler mruby-sprintf mruby-string-ext mruby-array-ext mruby-hash-ext mruby-set mruby-enum-ext
     mruby-numeric-ext mruby-kernel-ext mruby-object-ext mruby-symbol-ext mruby-range-ext mruby-proc-ext
     mruby-compar-ext mruby-error mruby-metaprog mruby-math mruby-bigint mruby-struct
     mruby-toplevel-ext].each { |g| conf.gem core: g }

  conf.cc.command = ENV.fetch('MRUBY_CC')
  conf.cxx.command = ENV.fetch('MRUBY_CXX')
  conf.linker.command = ENV.fetch('MRUBY_CXX')
  conf.archiver.command = 'ar'

  # vm.c is compiled as C++ by EDG, which requires `void *` for the table of `goto *optable[insn]` (mruby declares it
  # `const void *`; docs/notes/cxx-driver.md). The switch dispatch is the portable form anyway (cproc has no
  # computed goto either).
  [conf.cc, conf.cxx].each { |c| c.defines << 'MRB_USE_VM_SWITCH_DISPATCH' }

  # The one volatile in the files mruby compiles as C++, `volatile int err` in mrb_core_init_protect (src/error.c), is
  # removed by scripts/mruby-cxx-novolatile.patch, which setup-poly.sh applies: cproc rejects every store to a
  # volatile object, and a -Dvolatile= here would break the hosted libstdc++ headers (std::launder, numeric_limits
  # overload on volatile). See docs/notes/poly.md, "Building mruby".

  # Order matters: the linker command was set above and enable_cxx_exception reads cxx.command.
  conf.enable_cxx_exception
end
