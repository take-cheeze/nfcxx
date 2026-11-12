# The bc2cpp command as an mruby executable: bin/mruby (a C main in this directory's gem, not mruby-bin-mruby) runs
# BC2CPPRunner.run with bc2cpp's own arguments in ARGV. Run from 3rd/mruby (the mruby rake root), with this config:
#   cd 3rd/mruby && MRUBY_CONFIG=../../host-libs/mruby-bc2cpp-runner/build_config.rb \
#     MRUBY_BUILD_DIR=<dir> rake
# Not wired into build_config.rb: this build is the bc2cpp runner alone. Its test status is in the runner's README.
require_relative '../../tools/bc2cpp/world_root'
ROOT = BC2CPP_WORLD_ROOT unless defined?(ROOT)

self_aot = ENV['BC2CPP_RUNNER_SELF'] == '1'
MRuby::Build.new(self_aot ? 'bc2cpp-self' : 'bc2cpp-runner') do |conf|
  toolchain :gcc
  # Keep the host CXX available to nfcxx's bootstrap helpers. Setting CXX=nfcxx
  # globally can recursively rebuild weak-symbols with the compiler it supports.
  if (compiler = ENV['BC2CPP_RUNNER_CXX']) && !compiler.empty?
    conf.cxx.command = compiler
    conf.linker.command = compiler
    conf.cc.defines << 'MRB_USE_VM_SWITCH_DISPATCH'
    conf.cxx.defines << 'MRB_USE_VM_SWITCH_DISPATCH'
  end
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
  if self_aot
    conf.mrbcfile = ENV.fetch('MRBC')
  else
    conf.gem core: 'mruby-bin-mrbc'
    conf.gem core: 'mruby-compiler'
  end
  %w[mruby-array-ext mruby-hash-ext mruby-enum-ext mruby-io mruby-dir mruby-numeric-ext mruby-range-ext
     mruby-symbol-ext mruby-compar-ext mruby-fiber mruby-exit mruby-sprintf mruby-kernel-ext mruby-random
     mruby-math mruby-time mruby-bigint mruby-string-ext mruby-metaprog mruby-pack mruby-enumerator mruby-enum-lazy mruby-struct
     mruby-set mruby-method mruby-proc-ext mruby-errno mruby-error mruby-encoding].each { |g| conf.gem core: g }
  conf.gem File.expand_path('../mruby-require', __dir__)
  conf.gem File.expand_path('../mruby-env', __dir__)
  # Marshal (the scan cache) depends on mruby-onig-regexp, which bundles Onigmo, as build_config.rb has it.
  conf.gem File.join(ROOT, '3rd/mruby-onig-regexp') do
    bundle_onigmo
  end
  conf.gem File.join(ROOT, '3rd/mruby-marshal')
  %w[mruby-shellwords mruby-json mruby-digest mruby-fileutils mruby-tmpdir mruby-tempfile mruby-dir-glob
     mruby-strscan mruby-compare-by-identity mruby-yaml mruby-zlib].each { |g| conf.gem File.expand_path("../../ruby-libs/#{g}", __dir__) }
  conf.gem File.join(ROOT, '3rd/mruby-stringio')
  conf.gem File.expand_path('../mruby-prism', __dir__)
  conf.gem File.expand_path('../mruby-rbs', __dir__)
  conf.gem File.expand_path('../mruby-process', __dir__)
  conf.gem File.join(BC2CPP_TREE_ROOT, 'host-libs/mruby-bc2cpp-sources')
  conf.gem File.join(BC2CPP_TREE_ROOT, 'host-libs/mruby-bc2cpp-runner')
  conf.gem ENV.fetch('BC2CPP_RUNNER_SELF_GEM') if self_aot
end

# Export the configured runtime rather than reconstructing its gem dependencies.
if (manifest = ENV['BC2CPP_RUNNER_MANIFEST'])
  require 'json'
  task :bc2cpp_runner_manifest do
    build = MRuby.targets.fetch(self_aot ? 'bc2cpp-self' : 'bc2cpp-runner')
    gems = build.gems.reject { |gem| gem.name == 'mruby-compiler' || gem.name.start_with?('mruby-bin-') }
    native = Dir[File.join(MRUBY_ROOT, 'src/*.{c,cpp,cxx}')]
    ruby = Dir[File.join(MRUBY_ROOT, 'mrblib/**/*.rb')]
    gems.each do |gem|
      ruby.concat(gem.rbfiles.flatten)
      native.concat(Dir[File.join(gem.dir, '{src,core}/**/*.{c,cpp,cxx}')])
      gem.objs.each do |obj|
        next unless Rake::Task.task_defined?(obj)
        native.concat(Rake::Task[obj].prerequisites.select do |path|
          path.match?(/\.(c|cpp|cxx)\z/) && File.file?(path) && !path.end_with?('/gem_init.c')
        end)
      end
    end
    include_paths = (build.compilers + gems.flat_map(&:compilers)).flat_map(&:include_paths).flatten.uniq
    headers = include_paths.flat_map { |path| Dir[File.join(path, '**/*.{h,hpp,hxx}')] }.uniq.sort
    File.write(manifest, JSON.pretty_generate('gems' => gems.to_h { |gem| [gem.name, gem.dir] },
                                             'native' => native.uniq.sort, 'ruby' => ruby.uniq.sort,
                                             'headers' => headers, 'defines' => build.cc.defines.flatten))
  end
end
