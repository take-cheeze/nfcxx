# mruby-env: ENV for this project's mruby builds. mruby has no environment hash. The C half (src/env.c) reads and
# writes the process environment; mrblib/env.rb gives it the Hash-like methods the tools use (ENV[], fetch, key?,
# delete, to_h, reject, ...). A build that links mruby-bc2cpp-sources depends on this gem, so ENV exists before the
# sources load.
MRuby::Gem::Specification.new('mruby-env') do |spec|
  spec.license = 'MIT'
  spec.authors = 'take-cheeze'
  spec.summary = 'ENV (the process environment) for mruby'
end
