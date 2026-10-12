#!/usr/bin/env ruby
# frozen_string_literal: true

# Mutation test for EXT_PREFIX (docs/adr/0320). Each mutant is a copy of tools/bc2cpp with one condition of the
# prefix folding broken; scripts/bc2cpp/ext_prefix_check.rb, run against the mutant through BC2CPP_TOOL, must FAIL on
# the check that guards that condition. A mutant that passes means the condition has no negative case.
#
# The copy lives inside the repository (a hidden sibling of tools/), never in the system temp dir: bc2cpp.rb finds the
# engine's gems relative to itself, and a copy elsewhere sees an empty closed world, where every mutant would die for
# lack of a world instead of for its mutation. The unmutated copy runs first, with the generated-code half, and must
# pass: that is what shows the copy's closed world is the real one.
#
# Usage: MRBC=path/to/mrbc ruby scripts/bc2cpp/ext_prefix_mutation_check.rb

require 'fileutils'
require 'rbconfig'
require 'tmpdir'
require_relative 'mutant_pool'

ROOT = File.expand_path('../..', __dir__)
abort 'SKIP: set MRBC' unless ENV['MRBC']
COPY_PREFIX = 'bc2cpp_ext_mutant'

# [name, file, pattern, replacement, check label that must FAIL]
MUTANTS = [
  ['a prefix widens nothing', 'insn_decoder.rb',
   'ext = EXT_WIDTH.fetch(name)', 'ext = 0',
   /EXT1 widens|EXT2 widens|EXT3 widens|EXT1 on LOADSYM|EXT2 on LOADSYM|prefixed conditional|raised/],
  ['a folded instruction starts at its widened opcode, not at the prefix byte', 'insn_decoder.rb',
   'insns << build(name, values, pc, ext_start || start, start)', 'insns << build(name, values, pc, start, start)',
   /starts at its prefix byte|names the prefix byte|BytecodeIR resolves|address is the prefix byte/],
  ['a branch target is measured from the widened opcode', 'insn_decoder.rb',
   'insns << build(name, values, pc, ext_start || start, start)',
   'insns << build(name, values, (ext_start || start) + 1, ext_start || start, start)',
   /starts at its prefix byte|names the prefix byte|BytecodeIR resolves|operands, args and line|branch of the folded listing/],
  ['the width of a prefix outlives its instruction', 'insn_decoder.rb',
   'ext = fold ? 0 : EXT_WIDTH.fetch(name, 0)', 'ext = fold ? ext : EXT_WIDTH.fetch(name, 0)',
   /raised|widens|prefixed conditional|ends after/],
  ['a prefix at the end of the iseq is accepted', 'insn_decoder.rb',
   'raise "bc2cpp: EXT prefix at #{ext_start} ends the iseq" if ext_start', 'nil',
   /prefix that ends the iseq/],
  ['a prefix after a prefix is accepted', 'insn_decoder.rb',
   'raise "bc2cpp: EXT prefix at #{start} follows another prefix" if ext_start', 'nil',
   /prefix after a prefix/],
  ['the kill switch is ignored', 'insn_decoder.rb',
   "def self.fold_ext_prefix? = ENV['BC2CPP_EXT_PREFIX'] != '0'", 'def self.fold_ext_prefix? = true',
   /BC2CPP_EXT_PREFIX=0/],
  ['EXT2 is left as an instruction of its own', 'insn_decoder.rb',
   'if fold && EXT_WIDTH.key?(name)', "if fold && name != 'EXT2'",
   /EXT2 widens|EXT2 on LOADSYM|raised|prefix left/]
].freeze

# The run of the check against a copy of the generator with +mutation+ applied (nil: the unmutated control).
run_copy = lambda do |mutation, env_extra, stop_on|
  Dir.mktmpdir(COPY_PREFIX, ROOT) do |dir|
    Dir.children(ROOT).reject { |entry| entry == '.git' || entry == 'tools' || entry.start_with?(COPY_PREFIX) }.each do |entry|
      FileUtils.ln_s(File.join(ROOT, entry), File.join(dir, entry))
    end
    FileUtils.mkdir_p(File.join(dir, 'tools'))
    Dir.children(File.join(ROOT, 'tools')).reject { |entry| entry == 'bc2cpp' }.each do |entry|
      FileUtils.ln_s(File.join(ROOT, 'tools', entry), File.join(dir, 'tools', entry))
    end
    FileUtils.cp_r(File.join(ROOT, 'tools/bc2cpp'), File.join(dir, 'tools'))
    if mutation
      _name, file, pattern, replacement = mutation
      path = File.join(dir, 'tools', 'bc2cpp', file)
      text = File.read(path)
      next nil unless text.include?(pattern)

      File.write(path, text.sub(pattern) { replacement })
    end
    env = { 'BC2CPP_TOOL' => File.join(dir, 'tools', 'bc2cpp', 'bc2cpp.rb'), 'EXT_PREFIX_GENERATED_ONLY' => '1' }.merge(env_extra)
    Bc2cppMutantPool.run(env, [RbConfig.ruby, File.join(ROOT, 'scripts/bc2cpp/ext_prefix_check.rb')], stop_on: stop_on)
  end
end

failures = []

control = run_copy.call(nil, {}, nil)
puts "  #{control.success ? 'ok  ' : 'FAIL'} the unmutated copy passes the whole check, generated-code half included"
unless control.success
  puts control.out.lines.last(15).join
  failures << 'control'
end
vacuous = control.out.include?('ok   a method of the class body with more than 255 symbols reads its constant table')
puts "  #{vacuous ? 'ok  ' : 'FAIL'} the copy's closed world is not empty (the constant table of a wide class body is proven)"
failures << 'closed world' unless vacuous

mutate = lambda do |mutant|
  expected = mutant.last
  run_copy.call(mutant, {}, /^\s+FAIL .*(?:#{expected.source})/)
end

Bc2cppMutantPool.each_ordered(MUTANTS, work: mutate) do |(name, file, _pattern, _replacement, expected), run|
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
    puts run.out.lines.last(6).join if failed_lines.empty?
    failures << name
  end
end

if failures.empty?
  puts 'bc2cpp ext prefix mutation check: PASS'
else
  warn "bc2cpp ext prefix mutation check: #{failures.size} failure(s) (#{failures.join(', ')})"
  exit 1
end
