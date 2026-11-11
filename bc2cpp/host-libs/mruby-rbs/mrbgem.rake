# mruby-rbs: the RBS parser (3rd/rbs, the take-cheeze/rbs fork) as an mrbgem.
#
# Two halves:
#   - The C core (src/*.c, src/util/*.c of the fork) is compiled unchanged. src/mruby_rbs.c is the only
#     mruby-facing C: RBS::Native.parse_signature parses a source and returns the binary serialization.
#   - The Ruby half is the RBS library (lib/rbs of the fork) in a fixed load order (rbs_files.txt), built
#     into one mrblib by tools/build_mrblib.rb with the mruby deviations listed in that script. The binary is
#     decoded by lib/rbs/wasm/deserializer.rb into RBS::AST objects.
RBS_ROOT = File.expand_path('../../3rd/rbs', __dir__)
GEM_ROOT = __dir__

MRuby::Gem::Specification.new('mruby-rbs') do |spec|
  spec.license = 'BSD-2-Clause'
  spec.authors = 'Soutaro Matsumoto'
  spec.summary = 'RBS signature parser (C core and Ruby library from the rbs fork) for mruby'
  # Its Ruby half names Regexp at load time; mruby-onig-regexp defines it, and must load first.
  spec.add_dependency 'mruby-onig-regexp'

  # Written as "#{dir}/..." like the other repo gems, so the base-section scan (scripts/bc2cpp/base_rbs_all.rb) finds the headers.
  spec.cc.include_paths << "#{dir}/../../3rd/rbs/include" << "#{dir}/../../3rd/rbs/src"
  spec.cc.flags << '-std=gnu99' << '-Wno-unused-result'

  core_sources = Dir["#{RBS_ROOT}/src/*.c"] + Dir["#{RBS_ROOT}/src/util/*.c"]
  core_sources.each do |src|
    obj = objfile(src.sub(RBS_ROOT, "#{build_dir}/rbs-core").sub(/\.c\z/, ''))
    file obj => src do |t|
      FileUtils.mkdir_p(File.dirname(t.name))
      cc.run t.name, src
    end
    spec.objs << obj
  end

  # The Ruby half: regenerated when the fork, the file list or the generator changes.
  mrblib_out = "#{build_dir}/rbs_mrblib.rb"
  inputs = Dir["#{RBS_ROOT}/lib/rbs/**/*.rb"] + ["#{GEM_ROOT}/rbs_files.txt", "#{GEM_ROOT}/tools/build_mrblib.rb"]
  unless File.exist?(mrblib_out) && File.mtime(mrblib_out) >= inputs.map { |f| File.mtime(f) }.max
    FileUtils.mkdir_p(File.dirname(mrblib_out))
    ok = system(RbConfig.ruby, "#{GEM_ROOT}/tools/build_mrblib.rb", "#{RBS_ROOT}/lib", "#{GEM_ROOT}/rbs_files.txt", mrblib_out)
    raise 'mruby-rbs: tools/build_mrblib.rb failed' unless ok
  end
  spec.rbfiles << mrblib_out
end
