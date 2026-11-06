# The bc2cpp command as an mruby executable: bin/mruby runs a script that calls BC2CPPRunner.run, with bc2cpp's own
# arguments in ARGV. Run from 3rd/mruby (the mruby rake root), with this config:
#   cd 3rd/mruby && MRUBY_CONFIG=../../host-libs/mruby-bc2cpp-runner/build_config.rb \
#     MRUBY_BUILD_DIR=<dir> rake
# Not wired into build_config.rb: this build is the bc2cpp runner alone. Its test status is in the runner's README.
ROOT = File.expand_path('../..', Dir.pwd) unless defined?(ROOT)

MRuby::Build.new('bc2cpp-runner') do |conf|
  toolchain :gcc
  enable_debug
  conf.gem core: 'mruby-bin-mruby'
  conf.gem core: 'mruby-bin-mrbc'
  conf.gem core: 'mruby-compiler'
  %w[mruby-array-ext mruby-hash-ext mruby-enum-ext mruby-io mruby-dir mruby-numeric-ext mruby-range-ext
     mruby-symbol-ext mruby-compar-ext mruby-fiber mruby-exit mruby-sprintf mruby-kernel-ext mruby-random
     mruby-math mruby-time mruby-bigint mruby-string-ext mruby-metaprog mruby-pack mruby-enumerator mruby-struct
     mruby-set].each { |g| conf.gem core: g }
  conf.gem File.join(ROOT, 'host-libs/mruby-require')
  %w[mruby-shellwords mruby-json mruby-digest mruby-fileutils mruby-tmpdir mruby-tempfile mruby-dir-glob
     mruby-strscan].each { |g| conf.gem File.join(ROOT, 'ruby-libs', g) }
  conf.gem File.join(ROOT, 'host-libs/mruby-prism')
  conf.gem File.join(ROOT, 'host-libs/mruby-rbs')
  conf.gem File.join(ROOT, 'host-libs/mruby-bc2cpp-sources')
  conf.gem File.join(ROOT, 'host-libs/mruby-bc2cpp-runner')
end
