# The bc2cpp command as an mruby executable: bin/mruby (a C main in this directory's gem, not mruby-bin-mruby) runs
# BC2CPPRunner.run with bc2cpp's own arguments in ARGV. Run from 3rd/mruby (the mruby rake root), with this config:
#   cd 3rd/mruby && MRUBY_CONFIG=../../host-libs/mruby-bc2cpp-runner/build_config.rb \
#     MRUBY_BUILD_DIR=<dir> rake
# Not wired into build_config.rb: this build is the bc2cpp runner alone. Its test status is in the runner's README.
ROOT = File.expand_path('../..', Dir.pwd) unless defined?(ROOT)

MRuby::Build.new('bc2cpp-runner') do |conf|
  toolchain :gcc
  # BC2CPP_RUNNER_OPT=1: an optimised runner (-O2, no MRB_DEBUG), the build to time. Without it: -g3 -O0 with MRB_DEBUG.
  if ENV['BC2CPP_RUNNER_OPT'] == '1'
    conf.cc.flags << '-O2'
    conf.cxx.flags << '-O2'
  else
    enable_debug
  end
  # Marshal (3rd/mruby-marshal) is C++, and its try/catch-free code still needs mruby's C++ exception mode: the VM's
  # exceptions are C++ throws, as in build_config.rb's closed build. Without it the first raise corrupts the VM.
  enable_cxx_exception
  # The probe in codegen nests calls a hundred deep through blocks; mruby's default call depth (512) raises SystemStackError
  # in the interpreted runner.
  conf.cc.defines << 'MRB_CALL_LEVEL_MAX=8192'
  conf.cxx.defines << 'MRB_CALL_LEVEL_MAX=8192'
  # bc2cpp splits its 20 MB output into millions of lines; mruby's default array length limit is 131072.
  conf.cc.defines << 'MRB_ARY_LENGTH_MAX=0'
  conf.cxx.defines << 'MRB_ARY_LENGTH_MAX=0'
  conf.gem core: 'mruby-bin-mrbc'
  conf.gem core: 'mruby-compiler'
  %w[mruby-array-ext mruby-hash-ext mruby-enum-ext mruby-io mruby-dir mruby-numeric-ext mruby-range-ext
     mruby-symbol-ext mruby-compar-ext mruby-fiber mruby-exit mruby-sprintf mruby-kernel-ext mruby-random
     mruby-math mruby-time mruby-bigint mruby-string-ext mruby-metaprog mruby-pack mruby-enumerator mruby-enum-lazy mruby-struct
     mruby-set mruby-method mruby-proc-ext mruby-errno mruby-error mruby-encoding].each { |g| conf.gem core: g }
  conf.gem File.join(ROOT, 'host-libs/mruby-require')
  # Marshal (the scan cache) depends on mruby-onig-regexp, which bundles Onigmo, as build_config.rb has it.
  conf.gem File.join(ROOT, '3rd/mruby-onig-regexp') do
    bundle_onigmo
  end
  conf.gem File.join(ROOT, '3rd/mruby-marshal')
  %w[mruby-shellwords mruby-json mruby-digest mruby-fileutils mruby-tmpdir mruby-tempfile mruby-dir-glob
     mruby-strscan mruby-compare-by-identity mruby-yaml mruby-zlib].each { |g| conf.gem File.join(ROOT, 'ruby-libs', g) }
  conf.gem File.join(ROOT, '3rd/mruby-stringio')
  conf.gem File.join(ROOT, 'host-libs/mruby-prism')
  conf.gem File.join(ROOT, 'host-libs/mruby-rbs')
  conf.gem File.join(ROOT, 'host-libs/mruby-process')
  conf.gem File.join(ROOT, 'host-libs/mruby-bc2cpp-sources')
  conf.gem File.join(ROOT, 'host-libs/mruby-bc2cpp-runner')
end
