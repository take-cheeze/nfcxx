#!/usr/bin/env ruby
# frozen_string_literal: true

# COMPILED_GEMS_CONFIG (tools/bc2cpp/compiled_gems.yml, loaded by tools/bc2cpp/compiled_gems_config.rb):
#
#   fixtures
#     - a good file loads, in file order, with the optional key absent where unset;
#     - each way to get it wrong raises: unknown keys (top level and per gem), a missing out_symbol or owners_from,
#       a duplicate out_symbol, a duplicate key (YAML would keep the last), an owners source that is neither
#       `core` nor a base gem, a base gem with no directory, a malformed gem name, namespace list or version;
#   repository file
#     - names exactly the mruby-*-compiled gems that exist, and BC2CPP_COMPILED_GEMS is that table with the owners
#       derived from the named source.
#
# Usage: ruby scripts/bc2cpp/compiled_gems_config_check.rb

require 'tmpdir'
require_relative 'check_support'
require_relative '../../tools/bc2cpp/compiled_gems'

suite = FixtureCheck.new('compiled_gems_config_check')
Config = Bc2cppCompiledGemsConfig
ROOT = File.expand_path('../..', __dir__)

GOOD = <<~YAML
  version: 1
  gems:
    mruby-a-compiled:
      owners_from: mruby-a
      out_symbol: a_compiled
      native_namespaces: [A, B::C]
    mruby-core-compiled:
      owners_from: core
      out_symbol: core_compiled
YAML

def load_text(text, gems_root: nil)
  Dir.mktmpdir('gems_config') do |dir|
    path = File.join(dir, 'compiled_gems.yml')
    File.write(path, text)
    Config.load(path, gems_root: gems_root)
  end
end

# The raised message must name the problem, not just fail.
def fails_with(text, pattern, gems_root: nil)
  load_text(text, gems_root: gems_root)
  false
rescue Config::Error => e
  e.message.match?(pattern)
end

def fails_with_path(path, pattern)
  Config.load(path)
  false
rescue Config::Error => e
  e.message.match?(pattern)
end

entries = load_text(GOOD)
suite.check('a good file loads its gems in file order', entries.map(&:name) == %w[mruby-a-compiled mruby-core-compiled])
suite.check('a good file keeps the values', entries[0].to_h == { name: 'mruby-a-compiled', owners_from: 'mruby-a',
                                                                out_symbol: 'a_compiled', native_namespaces: %w[A B::C] })
suite.check('native_namespaces is nil when unset', entries[1].native_namespaces.nil? && entries[1].owners_from == 'core')

suite.check('an unknown top-level key fails', fails_with(GOOD + "extra: 1\n", /unknown top-level keys \["extra"\]/))
suite.check('a wrong version fails', fails_with(GOOD.sub('version: 1', 'version: 2'), /version must be 1/))
suite.check('a non-mapping file fails', fails_with("- a\n", /top level must be a mapping/))
suite.check('an empty gem list fails', fails_with("version: 1\ngems: {}\n", /non-empty mapping/))
suite.check('an unknown gem key fails', fails_with(GOOD.sub('out_symbol: a_compiled', "out_symbol: a_compiled\n    owner: x"), /unknown keys \["owner"\]/))
suite.check('a missing out_symbol fails', fails_with(GOOD.sub("    out_symbol: a_compiled\n", ''), /mruby-a-compiled.*missing out_symbol/))
suite.check('a missing owners_from fails', fails_with(GOOD.sub("    owners_from: mruby-a\n", ''), /missing owners_from/))
suite.check('a duplicate out_symbol fails', fails_with(GOOD.sub('core_compiled', 'a_compiled'), /duplicate out_symbol "a_compiled"/))
suite.check('a duplicate gem key fails', fails_with(GOOD + "  mruby-a-compiled:\n    owners_from: core\n    out_symbol: z\n", /duplicate key "mruby-a-compiled"/))
suite.check('an owners source that is not core or a gem fails', fails_with(GOOD.sub('owners_from: mruby-a', 'owners_from: Core'), /owners_from must be `core` or a base gem/))
suite.check('a non-string owners source fails', fails_with(GOOD.sub('owners_from: mruby-a', 'owners_from: [mruby-a]'), /owners_from must be/))
suite.check('a malformed out_symbol fails', fails_with(GOOD.sub('a_compiled', 'A-compiled'), /out_symbol must match/))
suite.check('a malformed gem name fails', fails_with(GOOD.sub('mruby-a-compiled', 'a-compiled'), /gem name must match/))
suite.check('a gem entry that is not a mapping fails', fails_with("version: 1\ngems:\n  mruby-a-compiled: x\n", /must be a mapping/))
suite.check('an empty namespace list fails', fails_with(GOOD.sub('[A, B::C]', '[]'), /native_namespaces must be/))
suite.check('a repeated namespace fails', fails_with(GOOD.sub('[A, B::C]', '[A, A]'), /native_namespaces must be/))
suite.check('a lowercase namespace fails', fails_with(GOOD.sub('[A, B::C]', '[a]'), /native_namespaces must be/))
suite.check('a missing file fails', fails_with_path('/nonexistent/compiled_gems.yml', /no such file/))
suite.check('invalid YAML fails as a config error', fails_with("version: [1\n", /compiled_gems/))
Dir.mktmpdir('gems_root') do |root|
  Dir.mkdir(File.join(root, 'mruby-a'))
  suite.check('a base gem with a directory passes', !load_text(GOOD, gems_root: root).empty?)
  suite.check('a base gem without a directory fails', fails_with(GOOD.sub('owners_from: mruby-a', 'owners_from: mruby-b'), /not a gem directory/, gems_root: root))
end

repo = Config.load(gems_root: ROOT)
on_disk = Dir[File.join(ROOT, 'mruby-*-compiled')].map { |dir| File.basename(dir) }.sort
suite.check('the repository file names exactly the mruby-*-compiled gems', repo.map(&:name).sort == on_disk)
suite.check('BC2CPP_COMPILED_GEMS keeps the file order', BC2CPP_COMPILED_GEMS.keys == repo.map(&:name))
suite.check('BC2CPP_COMPILED_GEMS owners come from the named source', repo.all? do |entry|
  want = entry.owners_from == 'core' ? BC2CPP_CORE_OWNERS : bc2cpp_gem_owners(entry.owners_from)
  got = BC2CPP_COMPILED_GEMS[entry.name]
  got[:owners] == want && !want.empty? && got[:out_symbol] == entry.out_symbol && got[:native_namespaces] == entry.native_namespaces
end)

text = bc2cpp_build_config_text
%w[closed psp wio maix].each do |name|
  gems = bc2cpp_rpg_maker_gem_lines(text, name, ROOT)
  suite.check("#{name} omits Marshal, Kernel extensions and Random",
              (%w[mruby-marshal mruby-kernel-ext mruby-random] & gems.keys).empty?)
end
%w[host emscripten android].each do |name|
  gems = bc2cpp_rpg_maker_gem_lines(text, name, ROOT)
  suite.check("#{name} retains game-script dependencies",
              (%w[mruby-marshal mruby-kernel-ext mruby-random] - gems.keys).empty?)
end
suite.check('keyword defaults are read for multi-format dependency selection',
            bc2cpp_rpg_maker_gem_lines(text, 'host', ROOT).key?('mruby-mvjs') &&
              !bc2cpp_rpg_maker_gem_lines(text.sub('include_mvjs: true)', 'include_mvjs: false)'), 'host', ROOT).key?('mruby-mvjs'))
core = bc2cpp_closed_core_gems(ROOT)
suite.check('the compiled-core closure does not pull Struct or dropped helpers back in',
            (%w[mruby-struct mruby-kernel-ext mruby-random] & core).empty?)
suite.check('metaprogramming stays for the RGSS tilemap probe', core.include?('mruby-metaprog'))
suite.check('canonical compiled sources exclude the absent Struct gem',
            closed_world_mrblib_srcs(ROOT).none? { |path| path.include?('/mruby-struct/') })
suite.check('compiled core includes Struct only when the build actually supplies it',
            !bc2cpp_core_compiled_edges(ROOT, []).include?('mruby-struct') &&
              bc2cpp_core_compiled_edges(ROOT, ['mruby-struct']).include?('mruby-struct'))
suite.check('RGSS declares Marshal for its tests, not its runtime',
            !bc2cpp_rake_dependencies(File.join(ROOT, 'mruby-rgss'), ROOT).include?('mruby-marshal') &&
              File.read(File.join(ROOT, 'mruby-rgss/mrbgem.rake')).include?("add_test_dependency 'mruby-marshal'"))
suite.check('XP declares its own Marshal runtime dependency',
            bc2cpp_rake_dependencies(File.join(ROOT, 'mruby-rpgxp'), ROOT).include?('mruby-marshal'))
suite.check('RPG2k-only sources do not call omitted APIs',
            system(RbConfig.ruby, File.join(ROOT, 'scripts/wio/dropped_gems_check.rb'), '--rpg2k'))

suite.finish!
