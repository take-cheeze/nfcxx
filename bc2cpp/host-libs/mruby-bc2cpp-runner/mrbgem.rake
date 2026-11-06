# mruby-bc2cpp-runner: runs bc2cpp under mruby. The bc2cpp sources come from mruby-bc2cpp-sources (baked for require); this
# gem gives the command its entry. A build that links it runs `BC2CPPRunner.run` after ARGV is set, e.g. from a script
# that mruby executes with the command's arguments: the baked entry runs its main block because its `$PROGRAM_NAME ==
# __FILE__` test holds (see tools/bc2cpp/bake_sources.rb).
MRuby::Gem::Specification.new('mruby-bc2cpp-runner') do |spec|
  spec.license = 'MIT'
  spec.authors = 'take-cheeze'
  spec.summary = 'Runs bc2cpp (baked for mruby) as a command'
  spec.add_dependency 'mruby-require', core: 'mruby-require'
  spec.add_dependency 'mruby-bc2cpp-sources'
end
