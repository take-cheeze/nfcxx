# mruby's cross build for macOS arm64 (cross_macos.sh mruby). The target objects come from mruby_cross_cc.sh (qbe-cc to
# Darwin assembly, llvm-mc, ld64.lld against the clean-room libSystem stub). mruby's host build, with the host gcc, supplies
# mrbc, the tool that compiles the Ruby parts of the gems.
#
# The gem set is narrower than run_mruby.sh's default gembox: the dir, socket, time and sleep gems and their hal-posix
# counterparts are still left out (they need sockaddr, dirent and timer layouts not yet written). mruby-io and hal-posix-io
# are in, for puts and the IO class. mruby_test.rb needs only core, format (sprintf), catch/throw, and the array,
# hash, string, kernel, enum and numeric extensions, and none of them use those layouts.
MRuby::CrossBuild.new('arm64-macos') do |conf|
  %w[mruby-bin-mruby mruby-sprintf mruby-catch mruby-error mruby-array-ext mruby-hash-ext mruby-string-ext
     mruby-kernel-ext mruby-enum-ext mruby-numeric-ext].each { |g| conf.gem core: g }
  # mruby-io provides puts and the IO and File classes that run_mruby.sh's check uses. It needs a HAL gem, the POSIX one here;
  # the POSIX headers it needs are in tests/macos-sysroot/include (their layouts are documented where they are written).
  conf.gem core: 'hal-posix-io'
  conf.gem core: 'mruby-io'
  # mruby's read-only-data check on Apple targets reads the Mach-O segment layout (mach-o/getsect.h). Turning it off is
  # mruby's documented option: literal data is then not recognised as read-only, which only costs an optimisation.
  conf.cc.defines << 'MRB_NO_DEFAULT_RO_DATA_P'
  # The VM's labels-as-values dispatch (&&label, a GNU extension) is selected because the cross compiler preprocesses with
  # clang, which defines __clang__. cproc has no labels-as-values, so the switch dispatch is used instead; mruby's
  # documented option, and the same bytecode semantics.
  conf.cc.defines << 'MRB_USE_VM_SWITCH_DISPATCH'
  conf.cc.command = ENV.fetch('MRUBY_CROSS_CC')
  conf.linker.command = ENV.fetch('MRUBY_CROSS_LD')
  conf.archiver.command = ENV.fetch('MRUBY_AR', 'llvm-ar')
end
