#!/usr/bin/env ruby
# frozen_string_literal: true

# Mutation test for NATIVE_ARM_COVER (docs/adr/0378). Each mutant is a copy of tools/bc2cpp with one soundness
# condition broken; scripts/bc2cpp/native_arm_cover_check.rb, run against the mutant through
# BC2CPP_TOOL, must FAIL on the check that guards that condition. A mutant that passes means the condition has no
# negative case. An unmutated copy runs first and must pass: it proves the harness runs the same check the mutants
# run, with the fixture classes registered (the closed world is the repository's own, so the copy lives inside it).
#
# The mutant tree lives inside the repository (.mutants/, removed on exit): bc2cpp.rb finds the engine's gems
# relative to itself (../..), so a copy elsewhere would read a different layout and every mutant would die for the
# wrong reason.
#
# Usage: MRBC=path/to/mrbc ruby scripts/bc2cpp/native_arm_cover_mutation_check.rb

require 'fileutils'
require 'rbconfig'
require 'tmpdir'
require_relative 'mutant_pool'

ROOT = File.expand_path('../..', __dir__)
abort 'SKIP: set MRBC' unless ENV['MRBC']

# [name, file, pattern, replacement, check label that must FAIL]
MUTANTS = [
  ['every class of the set counts as covered', 'codegen_call_facts.rb',
   'classes.all? { |k| covered.include?(k) || answers.resolves_in_ruby?(k, name) }', 'classes.all? { |_k| true }',
   /NEG NcHost#neg_no_arm|NEG NcHost#neg_mixed_no_arm|NEG NcHost#neg_param|a Ruby override of Viewport#update/],
  ['a class is covered by any wrapper owner, not by the arms emitted ahead of this else', 'codegen_call_facts.rb',
   'Array(@native_arms_emitted && @native_arms_emitted[name])', 'CodeGen::NATIVE_WRAPPER_CLASS_ACCESSORS.keys',
   /NEG NcHost#neg_no_arm|NEG NcHost#neg_mixed_no_arm/],
  ['the cover kill switch is ignored', 'codegen_call_facts.rb',
   "return [] if ENV['BC2CPP_NATIVE_ARM_COVER'] == '0'", 'nil', /kill switch/]
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
    env = { 'BC2CPP_TOOL' => File.join(dir, 'tools', 'bc2cpp', 'bc2cpp.rb') }
    # A mutant the check already reports as caught need not run to the end.
    Bc2cppMutantPool.run(env, [RbConfig.ruby, File.join(ROOT, 'scripts/bc2cpp/native_arm_cover_check.rb')],
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
  puts 'bc2cpp native arm cover mutation check: PASS'
else
  warn "bc2cpp native arm cover mutation check: #{failures.size} failure(s)"
  exit 1
end
