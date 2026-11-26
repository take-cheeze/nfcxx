# mruby-require: require for this project's mruby builds, as one gem.
#
# Three kinds of feature. A feature a gem or mrblib provides is named as the script it came from ('rbs/buffer') or as
# the library name ('set'); it registers a check that the code is really present. A baked source (MRubyRequire.bake,
# written by tools/bc2cpp/bake_sources.rb) is a file's text under its baked name, which require evaluates with
# Kernel#eval under that name, or a source compiled to bytecode (mruby-bc2cpp-sources), which it runs without eval.
# A file is loaded from a path, or from $LOAD_PATH for a plain name (src/require.c: the native half, which also keeps
# $LOADED_FEATURES, provides Module#autoload, and raises LoadError for anything else).
# require returns true the first time, false afterwards, and raises LoadError for anything nothing provides.
MRuby::Gem::Specification.new('mruby-require') do |spec|
  spec.license = 'MIT'
  spec.authors = 'take-cheeze'
  spec.summary = 'Kernel#require over the features the mrbgems, mrblibs, baked sources and files of this build provide'
end
