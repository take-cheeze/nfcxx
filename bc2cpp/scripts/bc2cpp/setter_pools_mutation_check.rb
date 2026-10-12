#!/usr/bin/env ruby
# frozen_string_literal: true

# Mutation test for SETTER_POOLS / CHECKED_POOL_EXACT (docs/adr/0370). Each mutant is a copy of tools/bc2cpp with
# one soundness condition broken; scripts/bc2cpp/setter_pools_check.rb, run against the mutant through BC2CPP_TOOL,
# must FAIL on the check that guards that condition. A mutant that passes means the condition has no negative case.
#
# The mutants run through Bc2cppMutantPool (docs/ci.md, "Mutant pool"): a mutant stops at the FAIL line it is
# expected to cause.
#
# Usage: MRBC=path/to/mrbc [BC2CPP_MRUBY_FULL=dir] ruby scripts/bc2cpp/setter_pools_mutation_check.rb

require 'fileutils'
require 'tmpdir'
require_relative 'mutant_pool'

ROOT = File.expand_path('../..', __dir__)
abort 'SKIP: set MRBC' unless ENV['MRBC']

# [name, file, pattern, replacement, check label that must FAIL, needs the run half]
MUTANTS = [
  ['a Symbol of the setter (send(:x=), alias_method) does not withdraw it', 'codegen_setter_pools.rb',
   'return :poisoned if poisoned.include?(setter)', '',
   /read_kw|a Symbol of the setter/, false],
  ['a String the program spells does not withdraw the setter', 'codegen_setter_pools.rb',
   'return :spelled_name if setter_spelled_as_literal?(setter)', '', /read_str|spells "spstr="/, false],
  ['a native or foreign call of the name does not withdraw it', 'codegen_setter_pools.rb',
   'return :outside_call if setter_called_outside?(setter, stem)', '',
   /read_nat|native that calls|MRB_SYM_E|foreign Ruby source/, false],
  ['a setter with optional arguments is accepted', 'codegen_setter_pools.rb',
   'return :arity unless pure_mandatory_arity?(irep) && mandatory_arity(irep) == 1', '', /setter taking two arguments/, false],
  ['a setter that forwards with super is accepted', 'codegen_setter_pools.rb',
   "return :super if irep_tree_op?(irep, 'SUPER')", '', /forwards with super/, false],
  ['a group is pooled although one of its setters is refused', 'codegen_setter_pools.rb',
   'return nil if group.checked[:setters].any? { |setter| setter_pool_reads(setter).nil? }',
   'group.checked[:setters].select! { |setter| setter_pool_reads(setter) }',
   /read_send|read_alias|read_str|read_kw/, false],
  ['the pool does not carry the CHECKED provenance (the guard-free exact arms read it)', 'codegen_class_pools.rb',
   'stores[:classes].reduce(NumericFlow::CHECKED)', 'stores[:classes].reduce(0)', /nil-or-SpBox behind a class test|diagnostic marks/, false],
  ['the checked arm has no class test', 'codegen_setter_pools.rb',
   'if (mrb_obj_class(M, #{recv}) == #{checked_pool_class_expr(plan[:klass])}) {', 'if (1) {', /behind a class test|LOUD/, false],
  ['the nil arm is dropped', 'codegen_setter_pools.rb',
   "plan[:nilable] ? \"if (mrb_nil_p(\#{recv})) {\\n    \#{nil_arm}  } else \" : ''", "''",
   /nil arm is the NoMethodError helper|nil receiver raises/, false],
  ['a mixed set is read as its lowest class', 'codegen_setter_pools.rb',
   'klass = return_class_name_of_bit(mask & ~(NumericFlow::NIL | NumericFlow::CHECKED))',
   "rest = mask & ~(NumericFlow::NIL | NumericFlow::CHECKED)\n    klass = return_class_name_of_bit(rest & -rest)",
   /read_mix|mixed pool/, false],
  ['an unchecked accessor name is admitted by the alias operands', 'codegen_return_classes.rb',
   '|| !checked_accessor_name?(name)', '|| false', /stays withdrawn by the coarse alias rule/, false]
].freeze

failures = []
mutate = lambda do |(_name, file, pattern, replacement, expected, needs_run)|
  Dir.mktmpdir do |dir|
    FileUtils.cp_r(File.join(ROOT, 'tools/bc2cpp'), dir)
    path = File.join(dir, 'bc2cpp', file)
    text = File.read(path)
    next :site_gone unless text.include?(pattern)

    File.write(path, text.sub(pattern) { replacement })
    # The copy has no scripts/ beside it for the lint cross-check (ADR 0368), which no mutant is about.
    env = { 'BC2CPP_TOOL' => File.join(dir, 'bc2cpp', 'bc2cpp.rb'), 'BC2CPP_LINT_CROSSCHECK' => '0' }
    env['SP_GENERATED_ONLY'] = '1' unless needs_run
    Bc2cppMutantPool.run(env, [RbConfig.ruby, File.join(ROOT, 'scripts/bc2cpp/setter_pools_check.rb')],
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
  puts 'bc2cpp setter pools mutation check: PASS'
else
  warn "bc2cpp setter pools mutation check: #{failures.size} surviving mutant(s)"
  exit 1
end
