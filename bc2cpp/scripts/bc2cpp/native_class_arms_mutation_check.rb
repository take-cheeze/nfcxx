#!/usr/bin/env ruby
# frozen_string_literal: true

# Mutation test for NATIVE_CLASS_ARMS (docs/adr/0323). Each mutant is a copy of tools/bc2cpp with one soundness
# condition broken; scripts/bc2cpp/native_class_arms_check.rb (generated-code half), run against the mutant through
# BC2CPP_TOOL, must FAIL on the check that guards that condition. A mutant that passes means the condition has no
# negative case. An unmutated copy runs first and must pass: it proves the harness runs the same check the mutants
# run, with the fixture classes registered (the closed world is the repository's own, so the copy lives inside it).
#
# The mutant tree lives inside the repository (.mutants/, removed on exit): bc2cpp.rb finds the engine's gems
# relative to itself (../..), so a copy elsewhere would read a different layout and every mutant would die for the
# wrong reason.
#
# Usage: MRBC=path/to/mrbc ruby scripts/bc2cpp/native_class_arms_mutation_check.rb

require 'fileutils'
require 'rbconfig'
require 'tmpdir'
require_relative 'mutant_pool'

ROOT = File.expand_path('../..', __dir__)
abort 'SKIP: set MRBC' unless ENV['MRBC']

# [name, file, pattern, replacement, check label that must FAIL]
MUTANTS = [
  ['every unknown definer counts as landing on a class object', 'closed_world.rb',
   '@unknown_def_sources[name].any? { |label| label.nil? || !class_object_body?(label) }',
   '@unknown_def_sources[name].any? { |label| label.nil? }',
   /NEG a def nested in a block of the class-object body|NEG an instance-level alias of the name/],
  ['an install with another receiver counts as the class-object body\'s own', 'codegen_return_analysis.rb',
   'names.merge(syms) unless scoped && insn.op.start_with?(\'SSEND\')', 'names.merge(syms) unless scoped',
   /NEG an install on another class from the class-object body/],
  ['an `alias` keyword in any body is a class-object install', 'codegen_return_analysis.rb',
   'names << insn.sym unless scoped', 'names << insn.sym unless skip_class_object',
   /NEG an instance-level alias keyword/],
  ['an outside native or Ruby definer never reaches a class', 'call_facts.rb',
   '      outside = lambda do |owner|', "      outside = lambda do |_owner|\n        next false",
   /NEG an outside Ruby source reopens a class of the set|NEG a native source defines the name/],
  ['a declared class is never reached by an outside definer', 'call_facts.rb',
   '(!@cw.class_declared?(owner) || owner == simple(owner) || @cw.outside_spells_class?(owner))',
   '(!@cw.class_declared?(owner) || false)',
   /NEG an outside Ruby source reopens a class of the set|NEG a native source defines the name/],
  ['the exact set is judged native free without looking at the lookup path', 'codegen_call_facts.rb',
   'return [exact, true, native_class_free?(name, exact), true] if exact', 'return [exact, true, true, true] if exact',
   /NEG an outside Ruby source reopens a class of the set|NEG a native source defines the name/],
  ['the exact set is not scoped', 'codegen_call_facts.rb',
   'return [exact, true, native_class_free?(name, exact), true] if exact', 'return [exact, false, native_class_free?(name, exact), true] if exact',
   /pos_count: the proven receiver set/],
  ['the instance-scoped unknown-definer test is not used', 'closed_world.rb',
   'return :unknown_definer if instance_scope ? instance_unknown_def?(name) : @unknown_defs.include?(name)',
   'return :unknown_definer if @unknown_defs.include?(name)', /pos_update: the proven receiver set/],
  ['the class-object installs are still installed names', 'codegen_send.rb',
   '    installed = instance_scope ? symbol_instance_installed_names : symbol_installed_names
    refuse = lambda do |chain, arms = nil|', '    installed = symbol_installed_names
    refuse = lambda do |chain, arms = nil|', /pos_update: the proven receiver set/],
  ['a nil the flow cannot exclude does not keep the gates of a name nil answers', 'codegen_call_facts.rb',
   '(!mask.is_a?(Integer) || mask.anybits?(NumericFlow::NIL)) && !nil_unanswerable_for_instances?(name)', 'false',
   /NEG a native source defines na_zork on NilClass/],
  ['the flow-proven core call is never made', 'codegen_core_exact_direct.rb',
   'core_exact_direct_line(d, recv, name, argv, dynamic_dispatch_line(d, recv, name, argv))
  end

  # compile_core_min_max', 'nil
  end

  # compile_core_min_max', /pos_delete_hash: a flow-proven Hash/],
  ['the core-direct kill switch is ignored', 'codegen_core_exact_direct.rb',
   "return nil unless ENV['BC2CPP_NATIVE_CLASS_ARMS'] != '0' && exact_core_site_for(recv, name)",
   'return nil unless exact_core_site_for(recv, name)', /kill switch/],
  ['the class-arms kill switch is ignored', 'codegen_call_facts.rb',
   "ENV['BC2CPP_NATIVE_CLASS_ARMS'] != '0' && !@closed_world.nil?", '!@closed_world.nil?', /kill switch/]
].freeze

mutate = lambda do |(_name, file, pattern, replacement, expected)|
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
    env = { 'BC2CPP_TOOL' => File.join(dir, 'tools', 'bc2cpp', 'bc2cpp.rb'), 'NA_GENERATED_ONLY' => '1' }
    # A mutant the check already reports as caught need not run to the end.
    Bc2cppMutantPool.run(env, [RbConfig.ruby, File.join(ROOT, 'scripts/bc2cpp/native_class_arms_check.rb')],
                         stop_on: expected && Regexp.new("^\\s+FAIL .*(?:#{expected.source})"))
  ensure
    FileUtils.rm_rf(dir)
    Dir.rmdir(File.join(ROOT, '.mutants')) if Dir.empty?(File.join(ROOT, '.mutants'))
  end
end

failures = []
control = [['unmutated control', nil, nil, nil, nil]]
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
  puts 'bc2cpp native class arms mutation check: PASS'
else
  warn "bc2cpp native class arms mutation check: #{failures.size} failure(s)"
  exit 1
end
