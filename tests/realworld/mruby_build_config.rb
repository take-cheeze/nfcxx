# Build configuration for tests/realworld/run_mruby.sh: mruby's default gembox, compiler and linker taken
# from the environment (MRUBY_CC / MRUBY_LD), so the same file drives the gcc control and nfcc.
MRuby::Build.new do |conf|
  conf.toolchain :gcc
  # mruby guesses "Windows" when any /a/../z/ directory exists (lib/mruby/gem.rb for_windows?), which is
  # wrong on some Linux hosts; naming the POSIX HAL gems makes the choice explicit, as mruby recommends.
  %w[hal-posix-io hal-posix-dir hal-posix-socket hal-posix-task].each { |g| conf.gem core: g }
  conf.gembox 'default'
  conf.cc.command = ENV.fetch('MRUBY_CC', 'gcc')
  conf.linker.command = ENV.fetch('MRUBY_LD', ENV.fetch('MRUBY_CC', 'gcc'))
  conf.archiver.command = 'ar'
  conf.enable_test if ENV['MRUBY_TEST']   # mruby's own suite: MRUBY_TEST=1 rake test
end
