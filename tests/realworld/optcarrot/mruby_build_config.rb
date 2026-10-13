# mruby build for tests/realworld/run_optcarrot.sh: compiler and linker from MRUBY_CC / MRUBY_LD (gcc control or nfcc),
# default gembox (as run_mruby.sh) plus mruby-onig-regexp (MRUBY_ONIG_DIR). full-core would add mruby-cmath, whose
# C _Complex cproc does not support. Regexp is absent from mruby core and optcarrot's opt.rb uses
# regex literals in class bodies, so it is needed to load the script. The gem builds its bundled Onigmo with ./configure
# and make, using this build's compiler.
MRuby::Build.new do |conf|
  conf.toolchain :gcc
  %w[hal-posix-io hal-posix-dir hal-posix-socket hal-posix-task].each { |g| conf.gem core: g }
  conf.gembox 'default'
  conf.gem ENV.fetch('MRUBY_ONIG_DIR')
  conf.cc.command = ENV.fetch('MRUBY_CC', 'gcc')
  conf.linker.command = ENV.fetch('MRUBY_LD', ENV.fetch('MRUBY_CC', 'gcc'))
  conf.archiver.command = 'ar'
end
