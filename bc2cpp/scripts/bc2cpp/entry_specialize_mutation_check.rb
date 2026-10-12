#!/usr/bin/env ruby
# frozen_string_literal: true

# Mutation test for ENTRY_GUARDED_SPECIALIZATION (docs/adr/0380). Each mutant is a copy of tools/bc2cpp with one
# soundness condition broken; scripts/bc2cpp/entry_specialize_check.rb, run against the mutant through
# BC2CPP_TOOL, must FAIL on the check that guards that condition. A mutant that passes means the condition has no
# negative case. The headline mutant removes the entry check: the specialized body then runs for every argument.
#
# The mutants run through Bc2cppMutantPool, so BC2CPP_JOBS (default: the core count, at most 4) of them go at a
# time and a mutant stops at the FAIL line it is expected to cause (docs/ci.md, "Mutant pool").
#
# Usage: MRBC=path/to/mrbc [BC2CPP_MRUBY_FULL=dir] ruby scripts/bc2cpp/entry_specialize_mutation_check.rb

require 'fileutils'
require 'tmpdir'
require_relative 'mutant_pool'

ROOT = File.expand_path('../..', __dir__)
abort 'SKIP: set MRBC' unless ENV['MRBC']

GUARD_CALL = 'out << "  if (#{entry_spec[:guard]}) return #{entry_spec[:call]}'

# [name, file, pattern, replacement, check label that must FAIL, needs the run half]
MUTANTS = [
  ['the entry check is removed (the specialized body runs for every argument)', 'codegen_method.rb',
   GUARD_CALL, GUARD_CALL.sub('(#{entry_spec[:guard]})', '(1 || #{entry_spec[:guard]})'),
   /fixture compiles and runs|every call answers what the interpreter answers|a guard hit runs/, true],
  ['a miss falls off the end instead of running the generic body', 'codegen_method.rb',
   "(['self'] + arg_names).join(', ')});\\n\" if entry_spec&.fetch(:guard)",
   "(['self'] + arg_names).join(', ')}); else return mrb_nil_value();\\n\" if entry_spec&.fetch(:guard)",
   /every call answers what the interpreter answers|a guard miss runs the generic body/, true],
  ['the user-class test accepts a subclass', 'codegen_entry_specialize.rb',
   'mrb_obj_ptr(%<v>s)->c == #{owner_class_ptr_expr(klass)}', 'mrb_obj_is_kind_of(M, %<v>s, #{owner_class_ptr_expr(klass)})',
   /guard compares the object's own class pointer|every call answers what the interpreter answers/, false],
  ['the user-class test goes through mrb_obj_class (a singleton class is skipped)', 'codegen_entry_specialize.rb',
   '!mrb_immediate_p(%<v>s) && mrb_obj_ptr(%<v>s)->c == #{owner_class_ptr_expr(klass)}',
   'mrb_obj_class(M, %<v>s) == #{owner_class_ptr_expr(klass)}',
   /guard compares the object's own class pointer/, false],
  ['the Hash test accepts a subclass', 'codegen_entry_specialize.rb',
   "test: 'mrb_hash_p(%<v>s) && mrb_obj_ptr(%<v>s)->c == M->hash_class'", "test: 'mrb_hash_p(%<v>s)'",
   /Hash: the guard is the exact class|every call answers what the interpreter answers/, false],
  ['the Integer test accepts a Float', 'codegen_entry_specialize.rb',
   "test: 'mrb_fixnum_p(%<v>s)'", "test: '(mrb_fixnum_p(%<v>s) || mrb_float_p(%<v>s))'",
   /Integer: the guard is a fixnum test|every call answers what the interpreter answers/, false],
  ['the Integer test accepts a bigint-capable integer predicate', 'codegen_entry_specialize.rb',
   "test: 'mrb_fixnum_p(%<v>s)'", "test: 'mrb_integer_p(%<v>s)'",
   /Integer: the guard is a fixnum test/, false],
  ['the assumption is registered under the original label (the generic body sees it)', 'codegen_entry_specialize.rb',
   'key = [clone_label, a[:reg]]', 'key = [label, a[:reg]]',
   /the generic body is byte-for-byte the gate-off body|a user class: the by-name send is a direct call|Hash: the guard is the exact class/, false],
  ['the clone does not carry the call-site facts of the original', 'codegen_entry_specialize.rb',
   'next unless key.is_a?(Array) && key.first == label', 'next unless false',
   /identity clone SpHost#/, false],
  ['blocks are admitted', 'codegen_entry_specialize.rb',
   "return 'block fallback regions' if needs_return_catch || !block_fallback_regions.empty?", 'nil',
   /NEG SpHost#with_block/, false],
  ['optional, rest and keyword parameters are admitted', 'codegen_entry_specialize.rb',
   "return 'optional, rest or keyword parameters' unless mandatory_ok && !opt.positive? && !has_rest && kw_table.nil?", 'nil',
   /NEG SpHost#with_(opt|kw|rest)/, false],
  ['a rescue range is admitted', 'codegen_entry_specialize.rb',
   "return entry_specialize_refuse(d, 'has a rescue/ensure range') unless (irep.catch_handlers || []).empty?", 'nil',
   /NEG SpHost#with_rescue/, false],
  ['a world with singleton makers is trusted', 'codegen_entry_specialize.rb',
   "return entry_specialize_refuse(d, 'no exact-class world (singletons or reflection reachable)') unless @closed_world&.exact_instances_singleton_free?",
   'nil', /NEG a singleton maker in the world|NEG the open world/, false],
  ['an assumption that changes nothing keeps a duplicate body', 'codegen_entry_specialize.rb',
   "if spec == entry_specialize_compile(label, d, irep, [], tag: 'base')", "if false",
   /NEG SpHost#use_noop/, false],
  ['the gate treats 0 as a plan file name', 'codegen_entry_specialize.rb',
   '!(value.empty? || value == \'0\')', '!value.empty?',
   /gate off \(0\)/, false],
  ['a missing plan file builds generic silently', 'codegen_entry_specialize.rb',
   'raise "#{ENTRY_SPEC_ENV}: no such file #{path}" unless File.file?(path)', 'return {} unless File.file?(path)',
   /a plan file that does not exist fails the build loudly/, false]
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
    env['SP_GENERATED_ONLY'] = '1' unless needs_run
    # A mutant stops at the FAIL line it is expected to cause (Bc2cppMutantPool.run).
    Bc2cppMutantPool.run(env, [RbConfig.ruby, File.join(ROOT, 'scripts/bc2cpp/entry_specialize_check.rb')],
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
  puts 'bc2cpp entry specialize mutation check: PASS'
else
  warn "bc2cpp entry specialize mutation check: #{failures.size} surviving mutant(s)"
  exit 1
end
