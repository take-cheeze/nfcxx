# mruby-dir-glob: Dir.glob and Dir.[] for mruby, which mruby-dir does not provide.
#
# The wildcards bc2cpp's build uses: `*`, `?`, `**` (any depth of directories), and `{a,b}` alternatives. Dot entries
# match only a pattern segment that starts with a dot, as in CRuby. Results come in the order of the walk, with each
# directory's entries sorted; callers that need a total order sort them, as they do on CRuby.
MRuby::Gem::Specification.new('mruby-dir-glob') do |spec|
  spec.license = 'MIT'
  spec.authors = 'take-cheeze'
  spec.summary = 'Dir.glob and Dir.[] (wildcards, ** and braces), for mruby'
end
