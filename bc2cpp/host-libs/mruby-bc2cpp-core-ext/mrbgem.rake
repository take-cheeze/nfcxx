# mruby-bc2cpp-core-ext: small core methods written in Ruby, so bc2cpp compiles them (and, where its inliner can,
# inlines them) instead of the block-driven Enumerable fallbacks or an opaque native call. Each body must behave as
# the method it replaces on every input the closed world can pass it.
MRuby::Gem::Specification.new('mruby-bc2cpp-core-ext') do |spec|
  spec.license = 'MIT'
  spec.authors = 'take-cheeze'
  spec.summary = 'Small core methods in Ruby for the bc2cpp closed-world builds'
end
