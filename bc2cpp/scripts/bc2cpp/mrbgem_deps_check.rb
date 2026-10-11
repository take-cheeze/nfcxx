#!/usr/bin/env ruby
# encoding: UTF-8
# Check STALE_REQUIRE_RELATIVE_DEPS (see each *-compiled/mrbgem.rake's own
# comment): the Rake `file generated => [...]` rule for each compiled gem's
# generated C++ must depend on EVERY file under tools/bc2cpp/*.rb (globbed,
# not the single bc2cpp.rb path) -- bc2cpp.rb require_relative's several
# sibling files (native_expression_devirt.rb, symbol_cache.rb,
# const_site_cache.rb, ...) that change its generated output just as much as
# bc2cpp.rb itself. Editing only one of those never touched bc2cpp.rb's own
# mtime, so Rake considered an already-built `generated` file up to date and
# silently kept stale C++ on the next incremental build.
#
# A text check, not a Rake-execution one: mrbgem.rake runs inside mruby's own
# Gem::Specification.new block (MRuby::Gem::Specification#initialize's own
# instance_eval), which this script has no way to drive standalone the way
# the other bc2cpp_*_check.rb scripts drive bc2cpp.rb directly.

failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

%w[mruby-lcf-compiled mruby-rgss-compiled mruby-rpg2k-compiled mruby-core-compiled].each do |gem|
  path = File.expand_path("../#{gem}/mrbgem.rake", __dir__)
  source = File.read(path)
  check.call("#{gem}/mrbgem.rake globs every tools/bc2cpp/*.rb file as a dependency",
             source.match?(/Dir\[\s*"#\{dir\}\/\.\.\/tools\/bc2cpp\/\*\.rb"\s*\]/))
  check.call("#{gem}/mrbgem.rake's generated-file rule depends on that glob, not a single bc2cpp.rb path",
             source.match?(/file generated => \[\s*\*bc2cpp_tool_srcs\s*,/))
end

if failures.empty?
  puts 'bc2cpp mrbgem deps check: PASS'
else
  warn "bc2cpp mrbgem deps check: #{failures.size} failure(s)"
  exit 1
end
