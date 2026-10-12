#!/usr/bin/env ruby
# frozen_string_literal: true

# Mutation test for the compiled Game::CommonEvent.singleton / Game::MoveRoute.singleton owners and the bare
# `new(a, k: v)` of a class method (docs/adr/0422). Each mutant is a copy of tools/bc2cpp with one condition
# broken (or a copy of register.cxx with one registration moved or removed);
# scripts/bc2cpp/rpg2k_singleton_owners_check.rb, run against the mutant on the one world that exercises that
# condition, must FAIL on the check that guards it. An unmutated copy runs first and must pass.
#
# The mutant tree lives inside the repository (.mutants/, removed on exit): bc2cpp.rb finds the engine's gems
# relative to itself (../..), so a copy elsewhere would read a different layout.
#
# The runtime mutants run the compiled-versus-interpreted scenario and need BC2CPP_MRUBY_FULL (or a rake-built
# full-core mruby); without one they print SKIP and the generated-code mutants still run.
#
# Usage: MRBC=path/to/mrbc [BC2CPP_MRUBY_FULL=dir] ruby scripts/bc2cpp/rpg2k_singleton_owners_mutation_check.rb

require 'fileutils'
require 'rbconfig'
require 'tmpdir'
require_relative 'mutant_pool'
require_relative 'fixture_runtime'

ROOT = File.expand_path('../..', __dir__)
abort 'SKIP: set MRBC' unless ENV['MRBC']

KEYWORD = 'codegen_keyword_send.rb'
GEMS = 'compiled_gems.rb'
REGISTER = 'mruby-rpg2k-compiled/src/register.cxx'
BASE = 'base'
SUB = 'a subclass inherits the class method'
OPEN = 'an open world'

# [name, file under tools/bc2cpp (or REGISTER), pattern, replacement, world (RSO_WORLDS), runtime?, FAIL label]
MUTANTS = [
  ['a bare `new` in a class method is not recognised', KEYWORD,
   'implicit if implicit && @closed_world&.exact_class?(implicit)', 'nil', BASE, false,
   /Game::MoveRoute\.singleton#from_page carries|the compiler refuses/],
  ['a bare `new` in an instance method is taken for the class', KEYWORD,
   'implicit = implicit_singleton_self_class(owner_def)', "implicit = owner_def&.owner&.delete_suffix('.singleton')", BASE, false,
   /the compiler refuses/],
  ['a class with descendants is taken for exact', KEYWORD,
   'implicit if implicit && @closed_world&.exact_class?(implicit)', 'implicit', SUB, false, /the compiler refuses/],
  ['a class with descendants is taken for exact (run)', KEYWORD,
   'implicit if implicit && @closed_world&.exact_class?(implicit)', 'implicit', SUB, true,
   /the compiled calls answer what the interpreter answers/],
  ['an open world is taken for exact', KEYWORD,
   'implicit if implicit && @closed_world&.exact_class?(implicit)',
   'implicit if implicit && (@closed_world ? @closed_world.exact_class?(implicit) : true)', OPEN, false, /the compiler refuses/],
  ['Game::CommonEvent.singleton is not an owner', GEMS,
   'Game::CommonEvent.singleton Game::MoveRoute.singleton', 'Game::MoveRoute.singleton', BASE, false,
   /Game::CommonEvent\.singleton is an owner/],
  ['Game::MoveRoute.singleton is not an owner', GEMS,
   'Game::CommonEvent.singleton Game::MoveRoute.singleton', 'Game::CommonEvent.singleton', BASE, false,
   /Game::MoveRoute\.singleton is an owner/],
  ['another compiled gem also owns Game::MoveRoute.singleton', GEMS,
   "owners: %w[RGSS::Sprite RGSS::Plane", "owners: %w[Game::MoveRoute.singleton RGSS::Sprite RGSS::Plane", BASE, false,
   /Game::MoveRoute\.singleton is an owner of no other compiled gem/],
  ['same_route? is not registered', REGISTER,
   /  mrb_define_class_method\(M, move_route, "same_route\?",\n\s+Game__MoveRoute_singleton_same_route\$3f,\n\s+MRB_ARGS_REQ\(2\)\);\n/, '', BASE, false,
   /register\.cxx registers move_route\.same_route\?/],
  ['the registrations sit outside the full-build region', REGISTER,
   '  // Game::CommonEvent.singleton and Game::MoveRoute.singleton (docs/adr/0422):',
   "#endif  // BC2CPP_HOT_ONLY_STUBS\n  // Game::CommonEvent.singleton and Game::MoveRoute.singleton (docs/adr/0422):", BASE, false,
   /register\.cxx registers common_event\.load/],
  ['a hot-only build lists same_route?', 'hot_methods.txt',
   "Game.singleton#camera_offset\n", "Game.singleton#camera_offset\nGame::MoveRoute.singleton#same_route?\n", BASE, false,
   /hot_methods\.txt does not list Game::MoveRoute\.singleton#same_route\?|a hot-only build emits no code for Game::MoveRoute\.singleton#same_route\?/]
].freeze

runtime = Bc2cppFixtureRuntime
mutate = lambda do |(_name, file, pattern, replacement, world, run_it, expected)|
  FileUtils.mkdir_p(File.join(ROOT, '.mutants'))
  dir = Dir.mktmpdir('m', File.join(ROOT, '.mutants'))
  begin
    Dir.children(ROOT).reject { |entry| %w[.git tools .mutants].include?(entry) }.each do |entry|
      FileUtils.ln_s(File.join(ROOT, entry), File.join(dir, entry))
    end
    FileUtils.mkdir_p(File.join(dir, 'tools'))
    Dir.children(File.join(ROOT, 'tools')).reject { |entry| entry == 'bc2cpp' }.each do |entry|
      FileUtils.ln_s(File.join(ROOT, 'tools', entry), File.join(dir, 'tools', entry))
    end
    FileUtils.cp_r(File.join(ROOT, 'tools/bc2cpp'), File.join(dir, 'tools'))
    env = { 'BC2CPP_TOOL' => File.join(dir, 'tools', 'bc2cpp', 'bc2cpp.rb'), 'BC2CPP_JOBS' => '1' }
    if pattern
      mutated = file == REGISTER ? File.join(dir, 'register.cxx') : File.join(dir, 'tools', 'bc2cpp', file)
      text = File.read(file == REGISTER ? File.join(ROOT, REGISTER) : mutated)
      next nil unless text.match?(pattern.is_a?(Regexp) ? pattern : Regexp.new(Regexp.escape(pattern)))

      File.write(mutated, text.sub(pattern) { replacement })
      env['RSO_REGISTER'] = mutated if file == REGISTER
    end
    if world
      env['RSO_WORLDS'] = world
      env['RSO_GENERATED_ONLY'] = '1' unless run_it
    end
    Bc2cppMutantPool.run(env, [RbConfig.ruby, File.join(ROOT, 'scripts/bc2cpp/rpg2k_singleton_owners_check.rb')],
                         stop_on: expected && Regexp.new("^\\s+FAIL .*(?:#{expected.source})"))
  ensure
    FileUtils.rm_rf(dir)
    Dir.rmdir(File.join(ROOT, '.mutants')) if Dir.empty?(File.join(ROOT, '.mutants'))
  end
end

failures = []
control = [['unmutated control', nil, nil, nil, nil, nil, nil]]
Bc2cppMutantPool.each_ordered(control, work: mutate) do |(name, *), run|
  passed = run.success
  puts "  #{passed ? 'ok  ' : 'FAIL'} #{name} passes the check"
  unless passed
    puts run.out.lines.grep(/^\s+FAIL /).first(5).join
    failures << name
  end
end

full = runtime.full_or_build
mutants = MUTANTS.reject do |name, _file, _pattern, _replacement, _world, run_it, _expected|
  skip = run_it && (full.nil? || !runtime.compiler?)
  puts "  SKIP #{name}: needs BC2CPP_MRUBY_FULL and g++" if skip
  skip
end
Bc2cppMutantPool.each_ordered(mutants, work: mutate) do |(name, file, _pattern, _replacement, _world, _run_it, expected), run|
  if run.nil?
    puts "  FAIL #{name}: the mutation site is gone from #{file}"
    failures << name
    next
  end
  failed_lines = run.out.lines.grep(/^\s+FAIL /)
  killed = !run.success && failed_lines.any? { |l| l.match?(expected) }
  puts "  #{killed ? 'ok  ' : 'FAIL'} mutant killed: #{name}"
  unless killed
    puts failed_lines.first(5).join
    failures << name
  end
end

if failures.empty?
  puts 'bc2cpp rpg2k singleton owners mutation check: PASS'
else
  warn "bc2cpp rpg2k singleton owners mutation check: #{failures.size} failure(s)"
  exit 1
end
