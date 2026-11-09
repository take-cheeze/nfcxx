# mruby-bc2cpp-runner: runs bc2cpp under mruby. The bc2cpp sources come from mruby-bc2cpp-sources (baked for require); this
# gem gives the command its entry, and its executable (tools/mruby/main.c, installed as bin/mruby): a C main that sets
# ARGV and runs `BC2CPPRunner.run`, with no script and no mruby-bin-mruby. The baked entry runs its main block because its
# `$PROGRAM_NAME == __FILE__` test holds (see tools/bc2cpp/bake_sources.rb). The first argument may still be
# bc2cpp_main.rb or mruby_tool.rb (the scripts of the callers), which the main skips.
MRuby::Gem::Specification.new('mruby-bc2cpp-runner') do |spec|
  spec.license = 'MIT'
  spec.authors = 'take-cheeze'
  spec.summary = 'Runs bc2cpp (baked for mruby) as a command'
  spec.bins = %w[mruby]
  spec.add_dependency 'mruby-require', core: 'mruby-require'
  spec.add_dependency 'mruby-bc2cpp-sources'
end
