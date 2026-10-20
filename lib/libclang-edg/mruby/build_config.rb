# Build configuration for scripts/setup-mruby-libclang-edg.sh: an mruby interpreter with the mruby-libclang-edg gem
# (this directory), so mruby scripts can use libclang-edg. Core gems, the I/O and string/array/hash extensions, and
# the POSIX HAL gems (named explicitly, as scripts/mruby-tool-config.rb explains).
# NFCXX_ROOT is set by the setup script, which copies this config into its build directory.
MRuby::Build.new do |conf|
  conf.toolchain :gcc
  %w[hal-posix-io hal-posix-dir hal-posix-socket hal-posix-task].each { |g| conf.gem core: g }
  %w[mruby-io mruby-string-ext mruby-array-ext mruby-hash-ext mruby-kernel-ext mruby-object-ext mruby-symbol-ext
     mruby-range-ext mruby-error mruby-exit mruby-bin-mruby].each { |g| conf.gem core: g }
  conf.gem File.join(ENV.fetch('NFCXX_ROOT'), 'lib', 'libclang-edg', 'mruby')
  conf.cc.command = ENV.fetch('MRUBY_CC', 'cc')
  conf.linker.command = ENV.fetch('MRUBY_CC', 'cc')
  conf.archiver.command = 'ar'
end
