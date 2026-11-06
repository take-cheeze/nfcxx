# mruby-bc2cpp-sources: the bc2cpp source graph, baked into this build so that require can load each file by name.
#
# tools/bc2cpp/bake_sources.rb renders every file reachable from tools/bc2cpp/bc2cpp.rb into one generated mrblib file
# (each file a string under its baked name, with its require_relative and __FILE__ already resolved). The generated
# file is written to the build directory, so the sources are never copied into the tree.
BC2CPP_SOURCES_ROOT = File.expand_path('../..', __dir__)
BC2CPP_SOURCES_ENTRY = 'tools/bc2cpp/bc2cpp.rb'
# Scripts the tools load by name rather than by require_relative: baked in with the entry, so that require finds them.
BC2CPP_SOURCES_EXTRA = %w[scripts/rpg2k/closed_world_lint.rb].freeze

MRuby::Gem::Specification.new('mruby-bc2cpp-sources') do |spec|
  spec.license = 'MIT'
  spec.authors = 'take-cheeze'
  spec.summary = 'The bc2cpp source graph, baked for require under mruby'
  spec.add_dependency 'mruby-require'
  spec.add_dependency 'mruby-env'

  generator = File.join(BC2CPP_SOURCES_ROOT, 'tools/bc2cpp/bake_sources.rb')
  baked = "#{build_dir}/bc2cpp_sources.rb"
  inputs = Dir[File.join(BC2CPP_SOURCES_ROOT, 'tools/bc2cpp/**/*.rb')] + [generator] +
           BC2CPP_SOURCES_EXTRA.map { |f| File.join(BC2CPP_SOURCES_ROOT, f) }
  unless File.exist?(baked) && File.mtime(baked) >= inputs.map { |f| File.mtime(f) }.max
    FileUtils.mkdir_p(File.dirname(baked))
    ok = system(RbConfig.ruby, generator, BC2CPP_SOURCES_ENTRY, baked, *BC2CPP_SOURCES_EXTRA)
    raise 'mruby-bc2cpp-sources: tools/bc2cpp/bake_sources.rb failed' unless ok
  end
  spec.rbfiles << baked
end
