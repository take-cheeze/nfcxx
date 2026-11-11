# mruby-prism: the Prism Ruby parser (3rd/prism, the take-cheeze/prism fork of ruby/prism, pinned at v1.9.0) for mruby.
#
# Two halves, as mruby-rbs has:
#   - The C core (vendored from the submodule, compiled unchanged). src/mruby_prism.c is the only mruby-facing C:
#     Prism::Native.parse_serialized(source) returns Prism's binary serialization of the AST.
#   - The Ruby half: the deserializer and node classes, built from the same pinned fork by tools/build_mrblib.rb
#     (a rendered mrblib with the mruby deviations listed there), plus mrblib/prism.rb for Prism.parse.
#
# The fork does not commit the files prism generates from its templates. They are rendered into this gem's build
# directory, so the submodule is never modified.
PRISM_ROOT = File.expand_path('../../3rd/prism', __dir__)
PRISM_TEMPLATES = File.join(PRISM_ROOT, 'templates')
PRISM_GEM_ROOT = __dir__

require File.join(PRISM_TEMPLATES, 'template')

# The generated sources and headers the core needs (prism's Rakefile builds the same set).
PRISM_GENERATED = %w[
  src/diagnostic.c src/node.c src/prettyprint.c src/serialize.c src/token_type.c
  include/prism/ast.h include/prism/diagnostic.h
].freeze

MRuby::Gem::Specification.new('mruby-prism') do |spec|
  spec.license = 'MIT'
  spec.authors = 'Shopify Inc. (prism); take-cheeze (mruby glue)'
  spec.summary = 'Prism Ruby parser for mruby'
  spec.add_dependency 'mruby-stringio'
  spec.add_dependency 'mruby-encoding'
  spec.add_dependency 'mruby-onig-regexp'

  gen_root = "#{build_dir}/prism-gen"

  # Generated files come first on the include path, so the rendered headers win over any in the source tree.
  spec.cc.include_paths.unshift("#{gen_root}/include")
  spec.cc.include_paths << "#{PRISM_ROOT}/include"
  spec.cc.flags << '-std=gnu99' << '-Wno-unused-result'

  PRISM_GENERATED.each do |name|
    out = File.join(gen_root, name)
    file out => ["#{PRISM_TEMPLATES}/#{name}.erb", "#{PRISM_TEMPLATES}/template.rb", "#{PRISM_ROOT}/config.yml"] do |t|
      FileUtils.mkdir_p(File.dirname(t.name))
      Prism::Template.render(name, write_to: t.name)
    end
    # Rendered now, not only as a rake task: the presym scan and the core's own preprocessing read these headers
    # (prism/diagnostic.h from pm_strpbrk.h), and their tasks are not prerequisites of those steps.
    unless File.exist?(out) && File.mtime(out) >= File.mtime("#{PRISM_TEMPLATES}/#{name}.erb")
      FileUtils.mkdir_p(File.dirname(out))
      Prism::Template.render(name, write_to: out)
    end
  end

  sources = Dir["#{PRISM_ROOT}/src/*.c"] + Dir["#{PRISM_ROOT}/src/util/*.c"] +
            PRISM_GENERATED.grep(/\.c\z/).map { |name| File.join(gen_root, name) }
  sources.each do |src|
    rel = src.start_with?(gen_root) ? src.delete_prefix("#{gen_root}/") : src.delete_prefix("#{PRISM_ROOT}/")
    obj = objfile("#{build_dir}/prism-core/#{rel}".sub(/\.c\z/, ''))
    prereqs = [src] + PRISM_GENERATED.map { |name| File.join(gen_root, name) }.select { |p| p.end_with?('.h') }
    file obj => prereqs do |t|
      FileUtils.mkdir_p(File.dirname(t.name))
      cc.run t.name, src
    end
    spec.objs << obj
  end

  # The Ruby half: rebuilt when the fork, the encoding model or the build script changes.
  mrblib_out = "#{build_dir}/prism_mrblib.rb"
  inputs = Dir["#{PRISM_ROOT}/lib/prism/**/*.rb"] + Dir["#{PRISM_ROOT}/templates/**/*"] +
           ["#{PRISM_GEM_ROOT}/ruby/encoding_light.rb", "#{PRISM_GEM_ROOT}/tools/build_mrblib.rb"]
  unless File.exist?(mrblib_out) && File.mtime(mrblib_out) >= inputs.map { |f| File.mtime(f) }.max
    FileUtils.mkdir_p(File.dirname(mrblib_out))
    ok = system(RbConfig.ruby, "#{PRISM_GEM_ROOT}/tools/build_mrblib.rb", PRISM_ROOT, "#{PRISM_GEM_ROOT}/ruby/encoding_light.rb", mrblib_out)
    raise 'mruby-prism: tools/build_mrblib.rb failed' unless ok
  end
  spec.rbfiles << mrblib_out
end
