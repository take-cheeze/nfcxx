#!/usr/bin/env ruby
# frozen_string_literal: true

# Mutation test for TUPLE_RETURN_FACTS (docs/adr/0311). Each mutant is a copy of tools/bc2cpp with one
# soundness condition broken; scripts/bc2cpp/tuple_return_check.rb (generated-code half), run against the
# mutant through BC2CPP_TOOL, must FAIL on the check that guards that condition. A mutant that passes means
# the condition has no negative case.
#
# The mutants run through Bc2cppMutantPool, so BC2CPP_JOBS (default: the core count, at most 4) of
# them go at a time and a mutant stops at the FAIL line it is expected to cause (docs/ci.md,
# "Mutant pool").
#
# Usage: MRBC=path/to/mrbc ruby scripts/bc2cpp/tuple_return_mutation_check.rb

require 'fileutils'
require 'tmpdir'
require_relative 'mutant_pool'

ROOT = File.expand_path('../..', __dir__)
abort 'SKIP: set MRBC' unless ENV['MRBC']

# [name, file, pattern, replacement, check label that must FAIL]
MUTANTS = [
  ['a return value that is not an ARRAY literal counts as one', 'codegen_tuple_returns.rb',
   "n = array.op == 'ARRAY' ? array.uint_operand : nil", "n = array.op == 'ARRAY' ? array.uint_operand : 2",
   /second definition returning a non-literal|no name with a second shape/],
  ['the walk from the ARRAY to the RETURN may cross any instruction', 'codegen_tuple_returns.rb',
   "      else return nil\n      end\n    end\n    nil", "      else next\n      end\n    end\n    nil",
   /reads the Array before it leaves|nor is a call between/],
  ['definitions of different lengths join', 'codegen_tuple_returns.rb',
   'sites unless sites.empty? || sites.map(&:last).uniq.size != 1', 'sites unless sites.empty?',
   /another length|no name with a second shape/],
  ['a return inside a block is not looked for', 'codegen_tuple_returns.rb',
   ' || tuple_block_returns?(irep)', '', /`return` from a block/],
  ['any name qualifies, not only the numeric-return candidates', 'codegen_tuple_returns.rb',
   'numeric_return_candidates.each do |name|', '@registry.keys.each do |name|',
   /core Ruby library also defines|method_missing anywhere/],
  ['a branch target between the call and the destructure is allowed', 'codegen_tuple_returns.rb',
   'return nil unless preds && ((j + 1)..index).all? { |k| preds[k].to_a == [k - 1] }', 'return nil unless preds',
   /branch join in front of the destructure/],
  ['an index past the length reads an Integer', 'codegen_tuple_returns.rb',
   'position < masks.size ? masks[position] : NumericFlow::NIL', 'masks[position] || NumericFlow::INT',
   /index past the length/],
  ['a class other than a number or nil is kept as a number', 'codegen_tuple_returns.rb',
   '(raw & ~TUPLE_KEPT_BITS).zero? ? kept : kept | NumericFlow::OTHER',
   '(raw & ~TUPLE_KEPT_BITS).zero? ? kept : kept | NumericFlow::INT', /String position keeps its send/],
  ['the kill switch is ignored', 'codegen_tuple_returns.rb',
   "return if ENV['BC2CPP_TUPLE_RETURNS'] == '0'", 'nil', /BC2CPP_TUPLE_RETURNS=0/],
  ['a grown position does not invalidate the destructuring methods', 'codegen_tuple_returns.rb',
   '@tuple_consumers[name].each { |label| numeric_invalidate(label) }', 'nil',
   /Integer positions of a literal pair prove/]
].freeze

failures = []
# nil when the mutation site is gone, else the run of the check against the mutant.
mutate = lambda do |(_name, file, pattern, replacement, expected)|
  Dir.mktmpdir do |dir|
    Bc2cppMutantPool.copy_generator(ROOT, dir)
    path = File.join(dir, 'bc2cpp', file)
    text = File.read(path)
    next :site_gone unless text.include?(pattern)

    File.write(path, text.sub(pattern) { replacement })
    env = { 'BC2CPP_TOOL' => File.join(dir, 'bc2cpp', 'bc2cpp.rb'), 'TQ_GENERATED_ONLY' => '1' }
    # A mutant stops at the FAIL line it is expected to cause (Bc2cppMutantPool.run).
    Bc2cppMutantPool.run(env, [RbConfig.ruby, File.join(ROOT, 'scripts/bc2cpp/tuple_return_check.rb')],
                         stop_on: /^\s+FAIL .*(?:#{expected.source})/)
  end
end

Bc2cppMutantPool.each_ordered(MUTANTS, work: mutate) do |(name, file, _pattern, _replacement, expected), run|
  if run == :site_gone
    puts "  FAIL #{name}: the mutation site is gone from #{file}"
    failures << name
    next
  end
  failed_lines = run.out.lines.grep(/^\s+FAIL /)
  killed = !run.success && failed_lines.any? { |l| l.match?(expected) }
  puts "  #{killed ? 'ok  ' : 'FAIL'} mutant killed: #{name}"
  unless killed
    puts failed_lines.first(5).join
    puts run.out.lines.last(8).join if failed_lines.empty?
    failures << name
  end
end

if failures.empty?
  puts 'bc2cpp tuple return mutation check: PASS'
else
  warn "bc2cpp tuple return mutation check: #{failures.size} surviving mutant(s)"
  exit 1
end
