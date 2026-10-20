# mruby gem: mruby-libclang-edg, the classes LibclangEdg::Index, TranslationUnit and Cursor over libclang-edg.so
# (lib/libclang-edg; build it with scripts/build-libclang-edg.sh). The shared library is linked by name; the
# directory it is in is put on the runtime search path.
MRuby::Gem::Specification.new('mruby-libclang-edg') do |spec|
  spec.license = 'MIT'
  spec.authors = 'nfcxx contributors'
  spec.summary = "libclang's C API on the EDG front end, for mruby"
  libdir = ENV.fetch('LIBCLANG_EDG_OUT', File.expand_path('../../../build/libclang-edg', __dir__))
  spec.cc.include_paths << File.expand_path('../include', __dir__)
  spec.linker.library_paths << libdir
  spec.linker.libraries << 'clang-edg'
  spec.linker.flags_after_libraries << "-Wl,-rpath,#{libdir}"
end
