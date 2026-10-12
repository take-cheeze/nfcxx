#!/usr/bin/env ruby
# frozen_string_literal: true

# Mutation test for CLASS_POOLS / NILABLE_RECEIVER (docs/adr/0296). Each mutant is a copy of
# tools/bc2cpp with one soundness condition broken; scripts/bc2cpp/class_pools_check.rb, run against
# the mutant through BC2CPP_TOOL, must FAIL on the check that guards that condition. A mutant that
# passes means the condition has no negative case.
#
# The mutants run through Bc2cppMutantPool, so BC2CPP_JOBS (default: the core count, at most 4) of
# them go at a time and a mutant stops at the FAIL line it is expected to cause (docs/ci.md,
# "Mutant pool").
#
# Usage: MRBC=path/to/mrbc [BC2CPP_MRUBY_FULL=dir] ruby scripts/bc2cpp/class_pools_mutation_check.rb

require 'fileutils'
require 'tmpdir'
require_relative 'mutant_pool'

ROOT = File.expand_path('../..', __dir__)
abort 'SKIP: set MRBC' unless ENV['MRBC']

# [name, file, pattern, replacement, check label that must FAIL, needs the run half]
MUTANTS = [
  ['pools track structurally refused groups (writer, reflection, foreign source)', 'codegen_class_pools.rb',
   'unless group.structural', 'unless false', /read_written|read_refl|spells @box|define_method block/, false],
  ['an unassigned constructor path counts as assigned', 'codegen_class_pools.rb',
   "assured = owner.name != 'initialize' && numeric_ivar_assured?(owner.owner, name)", 'assured = true',
   /constructor path that leaves @lz unassigned/, false],
  ['a store the flow cannot name joins the pool as nothing', 'codegen_class_pools.rb',
   'if mask.nil? || mask.anybits?(CLASS_POOL_UNSHIPPABLE)', 'mask &= ~CLASS_POOL_UNSHIPPABLE if mask; if mask.nil?',
   /read_param|pl_use_param|read_mixed/, false],
  ['a pool site of another class is not joined', 'codegen_class_pools.rb',
   'joined |= mask', 'joined |= mask if joined.zero?', /read_mixed|pl_use_two/, false],
  ['a nil is assumed away everywhere, not only on the tested arm', 'codegen_return_classes.rb',
   '@nonnil_receiver == [irep.label, idx, reg] ? mask & ~NumericFlow::NIL : mask', 'mask & ~NumericFlow::NIL',
   /every method answers what the interpreter answers|nil local/, true],
  ['nil is always unanswerable (to_s on nil raises instead of answering)', 'codegen_class_pools.rb',
   'def nil_unanswerable?(name)', "def nil_unanswerable?(name)\n    return true",
   /pl_nil_ok|every method answers what the interpreter answers/, true],
  ['the nil arm is dropped', 'codegen_nilable_receiver.rb',
   '"  if (mrb_nil_p(#{recv})) {\n"', '"  if (0 && mrb_nil_p(#{recv})) {\n"',
   /nil receiver raises|every method answers what the interpreter answers|nil local/, true]
].freeze

failures = []
# nil when the mutation site is gone, else the run of the check against the mutant.
mutate = lambda do |(_name, file, pattern, replacement, expected, needs_run)|
  Dir.mktmpdir do |dir|
    Bc2cppMutantPool.copy_generator(ROOT, dir)
    path = File.join(dir, 'bc2cpp', file)
    text = File.read(path)
    next :site_gone unless text.include?(pattern)

    File.write(path, text.sub(pattern) { replacement })
    env = { 'BC2CPP_TOOL' => File.join(dir, 'bc2cpp', 'bc2cpp.rb') }
    env['PL_GENERATED_ONLY'] = '1' unless needs_run
    # A mutant stops at the FAIL line it is expected to cause (Bc2cppMutantPool.run).
    Bc2cppMutantPool.run(env, [RbConfig.ruby, File.join(ROOT, 'scripts/bc2cpp/class_pools_check.rb')],
                         stop_on: /^\s+FAIL .*(?:#{expected.source})/)
  end
end

Bc2cppMutantPool.each_ordered(MUTANTS, work: mutate) do |(name, file, _pattern, _replacement, expected, _needs_run), run|
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
  puts 'bc2cpp class pools mutation check: PASS'
else
  warn "bc2cpp class pools mutation check: #{failures.size} surviving mutant(s)"
  exit 1
end
