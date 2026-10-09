# Build configuration for scripts/setup-mruby.sh: a small standalone `mruby` interpreter for nfcxx's own
# scripts (scripts/mrb). Core plus the I/O, pack, sprintf and *-ext gems the scripts use; no regexp gem
# exists in mruby core, so scripts must not use Regexp.
# The C compiler / linker come from MRUBY_CC / MRUBY_LD (host cc by default; nfcc to dogfood the compiler).
MRuby::Build.new do |conf|
  conf.toolchain :gcc
  # mruby guesses "Windows" when any /a/../z/ directory exists (lib/mruby/gem.rb for_windows?), which is
  # wrong on some Linux hosts; naming the POSIX HAL gems makes the choice explicit, as mruby recommends.
  # (Same workaround as tests/realworld/mruby_build_config.rb.)
  %w[hal-posix-io hal-posix-dir hal-posix-socket hal-posix-task].each { |g| conf.gem core: g }
  %w[mruby-io mruby-pack mruby-sprintf mruby-string-ext mruby-array-ext mruby-hash-ext mruby-set
     mruby-enum-ext mruby-numeric-ext mruby-kernel-ext mruby-object-ext mruby-symbol-ext mruby-range-ext
     mruby-error mruby-exit mruby-bigint mruby-bin-mruby].each { |g| conf.gem core: g }
  # Note: mruby 4 parses an integer literal above 2**31-1 as a bigint (mruby-bigint, included for the exact
  # float-literal arithmetic of scripts/qbe-prep.rb); scripts still spell such constants as shifts, e.g.
  # (1 << 32) - 1, so that they also run on an interpreter without it. Integer itself is 64-bit.
  # mruby caps an Array at 131072 entries by default (ArgumentError "array size too big"); the token list of
  # scripts/qbe-prep.rb for a large translation unit (doctest: 4.6 MB of C) is far longer. 0 removes the cap.
  conf.cc.defines << 'MRB_ARY_LENGTH_MAX=0'
  conf.cc.command = ENV.fetch('MRUBY_CC', 'cc')
  conf.linker.command = ENV.fetch('MRUBY_LD', ENV.fetch('MRUBY_CC', 'cc'))
  conf.archiver.command = 'ar'
end
