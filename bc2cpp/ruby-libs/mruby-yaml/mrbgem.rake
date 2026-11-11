# mruby-yaml: YAML.safe_load and YAML.safe_load_file for mruby, for the plain-data subset bc2cpp's config uses.
#
# Supported: block mappings and block sequences (2-space or any consistent indentation), flow sequences of plain scalars
# ([a, b]), plain and quoted scalars, integers, true/false/null, and comments. Duplicate mapping keys are an error. Anything
# else (anchors, tags, block scalars, multi-line scalars, flow mappings) raises YAML::SyntaxError: a file this parser cannot
# read fails loudly rather than parsing differently from Psych.
MRuby::Gem::Specification.new('mruby-yaml') do |spec|
  spec.license = 'MIT'
  spec.authors = 'take-cheeze'
  spec.summary = 'YAML.safe_load for the plain-data subset, for mruby'
  spec.add_dependency 'mruby-require'
end
