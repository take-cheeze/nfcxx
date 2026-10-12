#!/usr/bin/env ruby
# frozen_string_literal: true

# Mutation test for the RBS emitter (docs/adr/0414, tools/bc2cpp/type_check_rbs.rb). Each mutant is a copy of tools/bc2cpp with one defect;
# scripts/bc2cpp/emit_rbs_check.rb, run against the mutant through BC2CPP_TOOLS_DIR, must FAIL on the check that
# guards the behaviour. The text mutants need no MRBC (`--unit-only`); the round-trip mutant compiles a fixture.
#
# Usage: [MRBC=path/to/mrbc] ruby scripts/bc2cpp/emit_rbs_mutation_check.rb

require 'fileutils'
require 'rbconfig'
require 'tmpdir'
require_relative 'mutant_pool'

ROOT = File.expand_path('../..', __dir__)

# [name, file, pattern, replacement, check label that must FAIL, needs the round-trip half]
MUTANTS = [
  ['a core method is written again', 'type_check_rbs.rb', 'next if core && core_has.call(owner, m[\'name\'], singleton)', 'nil',
   /reopened core class/, false],
  ['an unknown class is written as is', 'type_check_rbs.rb', "          else 'untyped'\n          end\n      nilable", "          else a\n          end\n      nilable", /unknown class and untyped parameter/, false],
  ['bare Array stays bare', 'type_check_rbs.rb', "elsif GENERIC.key?(a) then GENERIC[a]", "elsif GENERIC.key?(a) then a", /Array gets arguments|ivars and constants/, false],
  ['initialize returns what the body returns', 'type_check_rbs.rb', "ret = 'void' if m['name'] == 'initialize'", 'nil', /void initialize/, false],
  ['private methods are public', 'type_check_rbs.rb', "(m['visibility'] == 'private' ? priv : pub) << line", 'pub << line', /private section/, false],
  ['a singleton method is an instance method', 'type_check_rbs.rb', "\"def \#{singleton ? 'self.' : ''}\#{m['name']}", "\"def \#{m['name']}", /def self\./, false],
  ['the superclass is dropped', 'type_check_rbs.rb', 'sup && declared.include?(sup) && sup != owner ?', 'false ?', /superclass the program defines/, false],
  ['a nilable type loses its ?', 'type_check_rbs.rb', 'nilable && t != \'untyped\' ? "#{t}?" : t', 't', /nilable return stays nilable/, false],
  ['optional parameters are dropped', 'type_check_rbs.rb', "positional.concat(Array.new(m['opt'].to_i, '?untyped'))", 'nil', /optional, rest, keyword/, false],
  ['a constant is not written', 'type_check_rbs.rb', "line = \"\#{name}: \#{rbs_type(c['type'], declared)}\"", "next", /ivars and constants/, false],
  ['a union return is not parenthesised', 'type_check_rbs.rb', "ret = \"(\#{ret})\" if ret.include?(' | ')", 'nil',
   /union return is parenthesised/, false],
  ['the round trip emits parameter types as untyped', 'type_check_rbs.rb', "positional = m['params'].map { |p| rbs_type(p['type'], declared) }", "positional = m['params'].map { 'untyped' }", /typed parameters of the fixture|typed parameters, void/, true]
].freeze

failures = []
mutate = lambda do |(_name, file, pattern, replacement, expected, needs_analysis)|
  next :skip if needs_analysis && !ENV['MRBC']

  # The copy sits in tools/ with its files at the top, so the generator's root is this repository; a copy in a temp
  # directory cannot find the mruby sources it reads (compiled_gems.rb).
  Dir.mktmpdir('bc2cpp-mutant-', File.join(ROOT, 'tools')) do |dir|
    FileUtils.cp_r(File.join(ROOT, 'tools/bc2cpp/.'), dir)
    path = File.join(dir, file)
    text = File.read(path)
    next :site_gone unless text.include?(pattern)

    File.write(path, text.sub(pattern) { replacement })
    env = { 'BC2CPP_TOOLS_DIR' => dir }
    argv = [RbConfig.ruby, File.join(ROOT, 'scripts/bc2cpp/emit_rbs_check.rb')]
    argv << '--unit-only' unless needs_analysis
    Bc2cppMutantPool.run(env, argv, stop_on: /^\s+FAIL .*(?:#{expected.source})/)
  end
end

Bc2cppMutantPool.each_ordered(MUTANTS, work: mutate) do |(name, file, _pattern, _replacement, expected, _needs), run|
  if run == :skip
    puts "  SKIP #{name} (set MRBC)"
    next
  end
  if run == :site_gone
    puts "  FAIL #{name}: the mutation site is gone from #{file}"
    failures << name
    next
  end
  failed_lines = run.out.lines.grep(/^\s+FAIL /)
  killed = !run.success && (failed_lines.any? { |l| l.match?(expected) } || false)
  puts "  #{killed ? 'ok  ' : 'FAIL'} mutant killed: #{name}"
  unless killed
    puts failed_lines.first(5).join
    puts run.out.lines.last(8).join if failed_lines.empty?
    failures << name
  end
end

if failures.empty?
  puts 'bc2cpp emit rbs mutation check: PASS'
else
  warn "bc2cpp emit rbs mutation check: #{failures.size} surviving mutant(s)"
  exit 1
end
