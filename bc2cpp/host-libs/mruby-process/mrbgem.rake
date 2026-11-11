# mruby-process: the process primitives bc2cpp uses under mruby. The C half (src/process.c) spawns a command with its
# stdin, stdout and stderr on pipes, reads the clock, and reports the process id. mrblib/process.rb gives them the
# Open3 (capture3, capture2, capture2e), Process and RbConfig names the tools call. Requiring 'open3' is satisfied here. RbConfig.ruby is mruby-require's (BC2CPP_RUBY).
MRuby::Gem::Specification.new('mruby-process') do |spec|
  spec.license = 'MIT'
  spec.authors = 'take-cheeze'
  spec.add_dependency 'mruby-require'
  spec.summary = 'Open3, Process and RbConfig for mruby (spawn with captured output)'
end
