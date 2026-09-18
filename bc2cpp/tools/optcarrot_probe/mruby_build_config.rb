# mruby build config for the optcarrot/bc2cpp scoping probe (see README.md in
# this directory). Not part of the project's real build -- point MRUBY_CONFIG
# at this file's absolute path when invoking rake from 3rd/mruby, e.g.:
#
#   cd 3rd/mruby && MRUBY_CONFIG=$(pwd)/../../tools/optcarrot_probe/mruby_build_config.rb rake -j"$(nproc)"
#
# full-core pulls in every mrbgem this project vendors under 3rd/mruby (Struct,
# ObjectSpace, IO, Set, Fiber, Complex, Rational, ...); mruby-onig-regexp adds
# Regexp, which is otherwise entirely absent from mruby core and which
# optcarrot's opt.rb needs just to load (regex literals in class-body
# constants). Requires the mruby-onig-regexp submodule checked out and, unless
# it's able to link a system oniguruma, its bundled onigmo build (slow -- the
# system package is much faster: `apt-get install libonig-dev` on Debian/Ubuntu).
MRuby::Build.new do |conf|
  conf.toolchain
  conf.gembox 'full-core'
  conf.gem File.expand_path('../../3rd/mruby-onig-regexp', __dir__)
  conf.enable_debug
end
