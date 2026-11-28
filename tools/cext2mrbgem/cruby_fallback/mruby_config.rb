# Prototype (opt-in, --cruby-fallback): a host build of the fork with mruby-marshal, the Marshal boundary of the fallback.
# Used by run_proto.sh through MRUBY_CONFIG, with MRUBY_BUILD_DIR kept apart from the submodule's own build.
MRuby::Build.new('host') do |conf|
  toolchain :gcc
  conf.gembox 'default'
  conf.gem :core => 'mruby-marshal'
  conf.enable_test
  conf.enable_bintest
  conf.enable_debug
end
