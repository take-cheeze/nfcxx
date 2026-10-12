#!/usr/bin/env ruby
# frozen_string_literal: true

# Mutation test for CLASS_NARROWING (docs/adr/0375). Each mutant is a copy of tools/bc2cpp with one soundness condition
# broken; scripts/bc2cpp/class_narrowing_check.rb, run against the mutant through BC2CPP_TOOL, must FAIL on the check that
# guards that condition. A mutant that passes means the condition has no negative case. An unmutated copy runs first and
# must pass: it proves the harness runs the same check the mutants run.
#
# The mutant tree lives inside the repository (.mutants/, removed on exit): bc2cpp.rb finds the engine's gems relative to
# itself (../..), so a copy elsewhere would read a different layout.
#
# Not mutated, by design: the refusal of a captured register (MOVE never records a test for an opaque source and every
# consumer refuses a captured register too), the handler edge (the existing raise_state design, covered by neg_rescue
# only through it) and the singleton gate (exact_flow_mask requires a singleton-free world as well). Each is defended
# twice, so removing one copy changes no output. The same holds for the class hierarchy gate of a tested class (a
# dynamic or unresolved subclass): ClosedWorld#descendants already counts every wild class as a descendant of every
# class, so the positive set is a superset either way, and the run-time guard backs it (the rogue-subclass run).
#
# Each mutant names the worlds it can break (the check's CN_WORLDS filter; none: CN_SKIP_WORLDS) and whether it needs the
# behavioural half (a full run against real mruby), so a mutant only pays for the part of the check that can kill it.
#
# Usage: MRBC=path/to/mrbc [BC2CPP_MRUBY_FULL=dir] ruby scripts/bc2cpp/class_narrowing_mutation_check.rb

require 'fileutils'
require 'rbconfig'
require 'tmpdir'
require_relative 'mutant_pool'

ROOT = File.expand_path('../..', __dir__)
abort 'SKIP: set MRBC' unless ENV['MRBC']

NARROW = 'codegen_class_narrowing.rb'
FLOW = 'numeric_flow.rb'

# [name, file, pattern, replacement, check label that must FAIL, worlds regexp or nil, needs the run half]
MUTANTS = [
  ['the two edges of a test are swapped', NARROW,
   'kept = mask & (truth ? pass : fail)', 'kept = mask & (truth ? fail : pass)',
   /narrowing removes work|no by-name dispatch is left/, nil, false],
  ['a test that names a class forgets its subclasses', NARROW,
   'classes = [klass] + hierarchy[:descendants].to_a', 'classes = [klass]',
   /every call answers what the interpreter answers/, nil, true],
  ['a rewrite of the variable does not forget the test', FLOW,
   "        clear_class_tests(out, ctx, slot_count + 1 + r)\n", '',
   /NEG neg_reassign|NEG neg_loop_swap|NEG neg_stale_test|NEG a rewrite of the variable/, nil, false],
  ['a call does not forget the test of an ivar', FLOW,
   "      slots.times { |k| clear_class_tests(out, ctx, k + 1) }\n", '',
   /NEG neg_call_between|NEG neg_stale_ivar|NEG a call between/, nil, false],
  ['a join keeps the test one side holds', FLOW,
   'r < prov_base ? m | new[r] : (m == new[r] ? m : 0)', 'r < prov_base ? m | new[r] : (m == new[r] ? m : (m.zero? ? new[r] : (new[r].zero? ? m : 0)))',
   /NEG neg_join_test|NEG a join keeps/, nil, false],
  ['the kill switch is ignored', NARROW,
   "ENV['BC2CPP_CLASS_NARROWING'] != '0' && ", '',
   /narrowing removes work/, nil, false],
  ['a Ruby is_a?, kind_of?, nil? or respond_to? is ignored', NARROW,
   '@class_test_name_safe[name] = safe && name_unrebound?(name) && class_test_native_owners?(name)', '@class_test_name_safe[name] = true',
   /NEG a Ruby (is_a\?|kind_of\?|instance_of\?|nil\?|!|respond_to\?|class) definition/, 'Ruby (is_a|kind_of|instance_of|nil|!|respond_to|class)', false],
  ['an alias or a computed definition of the name is ignored', NARROW,
   '@class_test_name_safe[name] = safe && name_unrebound?(name) && class_test_native_owners?(name)', '@class_test_name_safe[name] = safe && class_test_native_owners?(name)',
   /NEG an alias of is_a\?|NEG a definition from a computed list/, 'alias of is_a|computed list', false],
  ['a Ruby === is ignored', NARROW,
   "return nil unless argc == 1 && insn.op == 'SEND' && eqq_direct_safe?", "return nil unless argc == 1 && insn.op == 'SEND'",
   /NEG a Ruby === definition/, 'Ruby ===', false],
  ['a BasicObject subclass is ignored', NARROW,
   "(name == '!' ? world.ownerless_native_dispatch_safe?(name) : world.kernel_native_dispatch_safe?(name))", 'world.ownerless_native_dispatch_safe?(name)',
   /NEG a BasicObject subclass/, 'BasicObject subclass', false],
  ['a subclass of a core class is ignored', NARROW,
   'return CLASS_TEST_CORE_POSITIVE[klass] if test.kind == :instance_of || core_class_subclass_free?(klass)', 'return CLASS_TEST_CORE_POSITIVE[klass]',
   /NEG a subclass of Array/, 'subclass of Array', false],
  ['a respond_to_missing? hook is ignored', NARROW,
   '&& class_test_name_safe?(name) && respond_to_missing_absent?', '&& class_test_name_safe?(name)',
   /NEG a Ruby respond_to_missing\? definition/, 'respond_to_missing', false],
  ['a == on class objects is ignored', NARROW,
   'return nil unless marker.equal?(CLASS_OF) && class_narrowing_enabled? && class_object_eq_safe?', 'return nil unless marker.equal?(CLASS_OF) && class_narrowing_enabled?',
   /NEG a (Ruby == definition on a class object|Ruby == definition on Object|module mixed into Class)/, 'Ruby ==|module mixed into Class', false],
  ['`raise` returns', NARROW,
   "@class_narrowing_raise = class_test_name_safe?('raise') unless defined?(@class_narrowing_raise)", '@class_narrowing_raise = false',
   /pos_early_raise/, nil, false],
  ['`a || b` is not threaded', FLOW,
   "return target unless src.op == 'JMPIF' || src.op == 'JMPNOT'", 'return target',
   /pos_or|pos_and/, nil, false],
  ['a copy chain is cut at its first link', FLOW,
   'while code.positive? && codes.size < CLASS_TEST_CHAIN_MAX', 'while code.positive? && codes.empty?',
   /pos_case/, nil, false],
  ['the run-time guard is dropped', NARROW,
   'return nil unless class_narrowing_enabled? && (insn.op == \'SEND\' || insn.op == \'SEND0\')', 'return nil',
   /carries its run-time guard|raises the guard violation/, nil, true]
].freeze

mutate = lambda do |(_name, file, pattern, replacement, _expected, worlds, needs_run)|
  FileUtils.mkdir_p(File.join(ROOT, '.mutants'))
  dir = Dir.mktmpdir('m', File.join(ROOT, '.mutants'))
  begin
    # Every other entry of the repository root is linked, so the copy keeps the layout bc2cpp.rb expects.
    Dir.children(ROOT).reject { |entry| %w[.git tools .mutants].include?(entry) }.each do |entry|
      FileUtils.ln_s(File.join(ROOT, entry), File.join(dir, entry))
    end
    FileUtils.mkdir_p(File.join(dir, 'tools'))
    Dir.children(File.join(ROOT, 'tools')).reject { |entry| entry == 'bc2cpp' }.each do |entry|
      FileUtils.ln_s(File.join(ROOT, 'tools', entry), File.join(dir, 'tools', entry))
    end
    FileUtils.cp_r(File.join(ROOT, 'tools/bc2cpp'), File.join(dir, 'tools'))
    if pattern
      path = File.join(dir, 'tools', 'bc2cpp', file)
      text = File.read(path)
      next nil unless text.include?(pattern)

      File.write(path, text.sub(pattern) { replacement })
    end
    env = { 'BC2CPP_TOOL' => File.join(dir, 'tools', 'bc2cpp', 'bc2cpp.rb') }
    env['CN_GENERATED_ONLY'] = '1' unless needs_run
    # :all keeps every world (the control), nil none, a regexp only the worlds it matches.
    case worlds
    when :all then nil
    when nil then env['CN_SKIP_WORLDS'] = '1'
    else env['CN_WORLDS'] = worlds
    end
    Bc2cppMutantPool.run(env, [RbConfig.ruby, File.join(ROOT, 'scripts/bc2cpp/class_narrowing_check.rb')])
  ensure
    FileUtils.rm_rf(dir)
    Dir.rmdir(File.join(ROOT, '.mutants')) if Dir.empty?(File.join(ROOT, '.mutants'))
  end
end

failures = []
# The control runs the whole check, the worlds and the run half included.
control = [['unmutated control', nil, nil, nil, nil, :all, true]]
Bc2cppMutantPool.each_ordered(control, work: mutate) do |(name, *), run|
  passed = run.success
  puts "  #{passed ? 'ok  ' : 'FAIL'} #{name} passes the check"
  unless passed
    puts run.out.lines.grep(/^\s+FAIL /).first(5).join
    failures << name
  end
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
    failures << name
  end
end

if failures.empty?
  puts 'bc2cpp class narrowing mutation check: PASS'
else
  warn "bc2cpp class narrowing mutation check: #{failures.size} failure(s)"
  exit 1
end
