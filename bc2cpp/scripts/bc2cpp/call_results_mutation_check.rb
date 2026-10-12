#!/usr/bin/env ruby
# frozen_string_literal: true

# Mutation test for ACCESSOR_RETURN_CLASS and EXACT_CORE_ARMS (docs/adr/0309). Each mutant is a copy of
# tools/bc2cpp with one soundness condition broken; scripts/bc2cpp/call_results_check.rb, run against the
# mutant through BC2CPP_TOOL (generated-code half only), must FAIL on the check that guards that
# condition. A mutant that passes means the condition has no negative case.
#
# The mutants run through Bc2cppMutantPool, so BC2CPP_JOBS (default: the core count, at most 4) of
# them go at a time and a mutant stops at the FAIL line it is expected to cause (docs/ci.md,
# "Mutant pool").
#
# Usage: MRBC=path/to/mrbc ruby scripts/bc2cpp/call_results_mutation_check.rb

require 'fileutils'
require 'tmpdir'
require_relative 'mutant_pool'

ROOT = File.expand_path('../..', __dir__)
abort 'SKIP: set MRBC' unless ENV['MRBC']

# [name, file, pattern, replacement, check label that must FAIL]
MUTANTS = [
  ['a slot no constructor assigns counts as assigned (nil is dropped from the reader)', 'codegen_return_accessors.rb',
   'numeric_ivar_assured?(d.owner, d.name) ? pool : pool | NumericFlow::NIL', 'pool',
   /an unassigned slot: the send keeps its guard/],
  ['a slot with no pool counts as an empty one', 'codegen_return_accessors.rb',
   'return NumericFlow::OTHER unless pool', 'pool ||= 0',
   /NEG a writer the setter pool refuses|NEG an instance_variable_set|NEG a store from a subclass|NEG a second class/],
  ['the accessor kill switch is ignored', 'codegen_return_accessors.rb',
   "ENV.fetch('BC2CPP_RETURN_ACCESSORS', '1') != '0'", 'true', /BC2CPP_RETURN_ACCESSORS=0/],
  ['the scoped accessor kill switch is ignored', 'codegen_return_classes.rb',
   "ENV.fetch('BC2CPP_SCOPED_ACCESSOR_RETURNS', '1') != '0'", 'true', /BC2CPP_SCOPED_ACCESSOR_RETURNS=0/],
  ['the exact-core kill switch is ignored', 'codegen_exact_core_arms.rb',
   "ENV.fetch('BC2CPP_EXACT_CORE_ARMS', '1') != '0'", 'true', /BC2CPP_EXACT_CORE_ARMS=0/],
  ['the push arm takes any exact core class, not only Array', 'codegen_exact_core_arms.rb',
   "return nil unless exact_core_arm_class(irep, idx, reg, self_implicit) == 'Array'",
   'return nil unless exact_core_arm_class(irep, idx, reg, self_implicit)', /NEG push_hash/],
  ['the Integer-path push ignores a Ruby Array#<<', 'codegen_send.rb',
   "exact_push = builtin_class_send_safe?(name, %w[Array]) &&\n                   exact_array_push_code(",
   "exact_push = exact_array_push_code(", /a Ruby Array#<</]
].freeze

failures = []
# CR_MUTANT=text runs the mutants whose name contains it (while developing a new one).
mutants = ENV['CR_MUTANT'] ? MUTANTS.select { |m| m.first.include?(ENV['CR_MUTANT']) } : MUTANTS
# nil when the mutation site is gone, else the run of the check against the mutant.
mutate = lambda do |(_name, file, pattern, replacement, expected)|
  Dir.mktmpdir do |dir|
    FileUtils.cp_r(File.join(ROOT, 'tools/bc2cpp'), dir)
    path = File.join(dir, 'bc2cpp', file)
    text = File.read(path)
    next :site_gone unless text.include?(pattern)

    File.write(path, text.sub(pattern) { replacement })
    env = { 'BC2CPP_TOOL' => File.join(dir, 'bc2cpp', 'bc2cpp.rb'), 'CR_GENERATED_ONLY' => '1' }
    # A mutant stops at the FAIL line it is expected to cause (Bc2cppMutantPool.run).
    Bc2cppMutantPool.run(env, [RbConfig.ruby, File.join(ROOT, 'scripts/bc2cpp/call_results_check.rb')],
                         stop_on: /^\s+FAIL .*(?:#{expected.source})/)
  end
end

Bc2cppMutantPool.each_ordered(mutants, work: mutate) do |(name, file, _pattern, _replacement, expected), run|
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
  puts 'bc2cpp call results mutation check: PASS'
else
  warn "bc2cpp call results mutation check: #{failures.size} surviving mutant(s)"
  exit 1
end
