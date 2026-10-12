#!/usr/bin/env ruby
# frozen_string_literal: true

# Mutation test for docs/adr/0416 (CLASS_OBJECT_ARGS). Each mutant is a copy of tools/bc2cpp with one soundness condition
# of tools/bc2cpp/codegen_class_object_args.rb broken; scripts/bc2cpp/class_object_args_check.rb, run against the mutant
# through BC2CPP_TOOL, must FAIL on the check that guards that condition. A mutant that passes means the condition has no
# negative case. The host half of the check is enough (no mrbc), so this runs anywhere.
#
# No mutant for the Symbol rule of the call index: DynamicNames (numeric_dynamically_named?) refuses a Symbol-spelled name
# on its own, so breaking either alone changes no answer; both are kept as defence in depth.
#
# Usage: ruby scripts/bc2cpp/class_object_args_mutation_check.rb

require 'fileutils'
require 'tmpdir'
require_relative 'mutant_pool'

ROOT = File.expand_path('../..', __dir__)
FILE = 'codegen_class_object_args.rb'

# [name, pattern, replacement, check label that must FAIL]
MUTANTS = [
  ['a call whose argument count is not the arity is a site', 'next unless argc == mand', 'next unless true',
   /told apart by arity/],
  ['a poisoned name keeps its call sites', 'unless @class_object_call_index[:poisoned].include?(name)', 'if true',
   /Symbol naming the method|splat call|keyword call|alias of the method/],
  ['an alias no longer poisons the old name', 'poisoned << old if old', 'nil', /alias of the method/],
  ['a splat or keyword call is a site of the arity', 'if insn.reg.nil? || !(zero || insn.plain_fixed_argc?)', 'if insn.reg.nil?',
   /splat call|keyword call/],
  ['a captured parameter may be rewritten', 'return false unless d && d.irep == ancestor.label && index.positive? && index <= mandatory_arity(ancestor)',
   'return true', /rewritten parameter/],
  ['a nested block that writes the parameter is ignored', 'defs && defs.all?(&:entry?)', 'true', /rewritten parameter|nested block that writes/],
  ['a parameter overwritten by another parameter counts as unwritten', 'reg, through_handlers: true, follow_moves: false)',
   'reg, through_handlers: true)', /copy of another parameter/],
  ['the capture precondition is dropped', 'return nil unless captured_local_class_enabled?', 'nil', /capture precondition/],
  ['a name outside code calls is admitted', 'return false if class_object_called_outside?(name) || numeric_dynamically_named?(name)',
   'return false if numeric_dynamically_named?(name)', /outside source calls|native string literal/],
  ['a computed-name universe no longer refuses the name', 'return false if class_object_called_outside?(name) || numeric_dynamically_named?(name)',
   'return false if class_object_called_outside?(name)', /spells as a String/],
  ['a definition the registry cannot see is admitted', '@foreign_method_names.include?(name) || @closed_world.unknown_def?(name)',
   '@foreign_method_names.include?(name)', /registry cannot see/],
  ['a foreign Ruby definition is admitted', '@foreign_method_names.include?(name) || @closed_world.unknown_def?(name)',
   '@closed_world.unknown_def?(name)', /foreign Ruby source also defines/],
  ['another definition that calls super no longer withdraws the name', 'defs.none? { |other| !other.equal?(d) && class_object_super_in?(other) }',
   'true', /calls super withdraws/],
  ['a constant that may bind a non-class is a class', 'return nil unless name && @closed_world.class_valued_constant?(name)',
   'return nil unless name', /non-class/],
  ['a method with a rest parameter is accepted', 'return nil unless k.positive? && pure_mandatory_arity?(irep) && k <= mandatory_arity(irep)',
   'return nil unless k.positive? && k <= mandatory_arity(irep)', /rest parameter/],
  ['a cycle is solved by answering with what is known', 'return nil if active.include?(key)', 'return Set.new if active.include?(key)',
   /reaches its own parameter/],
  ['the kill switch is ignored', "ENV.fetch('BC2CPP_CLASS_OBJECT_ARGS', '1') != '0'", 'true', /BC2CPP_CLASS_OBJECT_ARGS=0/]
].freeze

failures = []
mutate = lambda do |(_name, pattern, replacement, expected)|
  Dir.mktmpdir do |dir|
    FileUtils.cp_r(File.join(ROOT, 'tools/bc2cpp'), dir)
    path = File.join(dir, 'bc2cpp', FILE)
    text = File.read(path)
    next :site_gone unless text.include?(pattern)

    File.write(path, text.sub(pattern) { replacement })
    env = { 'BC2CPP_TOOL' => File.join(dir, 'bc2cpp', 'bc2cpp.rb'), 'MRBC' => nil }
    Bc2cppMutantPool.run(env, [RbConfig.ruby, File.join(ROOT, 'scripts/bc2cpp/class_object_args_check.rb')],
                         stop_on: /^\s+FAIL .*(?:#{expected.source})/)
  end
end

Bc2cppMutantPool.each_ordered(MUTANTS, work: mutate) do |(name, _pattern, _replacement, expected), run|
  if run == :site_gone
    puts "  FAIL #{name}: the mutation site is gone from #{FILE}"
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
  puts 'bc2cpp class object args mutation check: PASS'
else
  warn "bc2cpp class object args mutation check: #{failures.size} surviving mutant(s)"
  exit 1
end
