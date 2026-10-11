#!/usr/bin/env ruby
# frozen_string_literal: true

# Mutation test for the NUMERIC_INTERVAL_OPERANDS (docs/adr/0326). Each mutant is a copy of tools/bc2cpp with
# one soundness condition broken; scripts/bc2cpp/numeric_intervals_check.rb, run against the mutant through BC2CPP_TOOL,
# must FAIL on the check that guards that condition. A mutant that passes means the condition has no negative case. The
# unmutated copy runs first as a control and must pass, so a mutant is never "killed" by a world the copy itself cannot
# generate (the copy sits inside the repository, so the closed world it scans is the real one).
#
# The generated-code half decides every mutant (NI_GENERATED_ONLY), so no mruby build is needed.
#
# Usage: MRBC=path/to/mrbc ruby scripts/bc2cpp/numeric_intervals_mutation_check.rb

require 'fileutils'
require 'rbconfig'
require 'tmpdir'
require_relative 'mutant_pool'

ROOT = File.expand_path('../..', __dir__)
abort 'SKIP: set MRBC' unless ENV['MRBC']

RANGES = 'codegen_fixnum_ranges.rb'
PROOF = 'codegen_fixnum_proof.rb'
INSN = 'codegen_insn.rb'
SWITCH = "ENV['BC2CPP_NUMERIC_INTERVALS'] != '0'"

# [name, file, pattern, replacement, check label that must FAIL]; a nil pattern is the control.
MUTANTS = [
  ['control (unmutated)', RANGES, nil, nil, nil],
  ['the operand kill switch is ignored by the interval gate', RANGES, "#{SWITCH} && fixnum_intervals_on?", 'fixnum_intervals_on?',
   /kill switch \(BC2CPP_NUMERIC_INTERVALS=0\)/],
  ['the index kill switch is ignored', RANGES, "#{SWITCH} && !reg.nil? && proven_fixnum_operand?", '!reg.nil? && proven_fixnum_operand?',
   /kill switch \(BC2CPP_NUMERIC_INTERVALS=0\)/],
  ['every index operand is proven', RANGES, "#{SWITCH} && !reg.nil? && proven_fixnum_operand?(irep, idx, reg.to_s, owner_def)", '!reg.nil?',
   /NEG idx_arg|NEG idx_flt/],
  ['an interval constant is vouched for outside a static constant world', RANGES, 'numeric_intervals_on? && !name.nil? &&', '!name.nil? &&',
   /NEG a (?:redefined Integer#\+|native source defining the constant|const_missing)|the open world proves nothing/],
  ['every constant name is an interval constant', RANGES, 'numeric_intervals_on? && !name.nil? && !self.class.integer_constant_ranges[name].nil?', '!name.nil?',
   /NEG add_big|NEG add_flt/],
  ['an arithmetic result is vouched for outside a static constant world', PROOF, '!@fixnum_proof_skip_constants && numeric_intervals_on? &&', '!@fixnum_proof_skip_constants &&',
   /NEG a (?:redefined Integer#\+|native source defining the constant|const_missing)|the open world proves nothing|kill switch/],
  ['an arithmetic result is always a Fixnum', PROOF, '!fixnum_interval_source(irep, j, insn, reg, owner_def, 0, nil).nil?', 'true',
   /NEG unproven_chain|NEG add_p/],
  ['the Array read keeps its integer test', INSN, 'if exact && proven_index_operand?(irep, idx, unshift_proof_reg(s, reg_offset), owner_def)',
   'if false && proven_index_operand?(irep, idx, unshift_proof_reg(s, reg_offset), owner_def)', /idx_c: the Array index has no integer test/],
  ['the Array write keeps its integer test', INSN, 'if exact && proven_index_operand?(irep, idx, unshift_proof_reg(idx_reg, reg_offset), owner_def)',
   'if false && proven_index_operand?(irep, idx, unshift_proof_reg(idx_reg, reg_offset), owner_def)', /idx_set: the Array index has no integer test/]
].freeze

# nil when the mutation site is gone, else the run of the check against the mutant.
mutate = lambda do |(_name, file, pattern, replacement, expected)|
  # Inside the repository: bc2cpp.rb finds the engine's gems relative to itself (../..), and a copy elsewhere scans an empty world.
  Dir.mktmpdir('.ni_mutant', ROOT) do |dir|
    Dir.children(ROOT).reject { |entry| entry.start_with?('.') || %w[tools].include?(entry) }.each do |entry|
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
    env = { 'BC2CPP_TOOL' => File.join(dir, 'tools', 'bc2cpp', 'bc2cpp.rb'), 'NI_GENERATED_ONLY' => '1' }
    # A mutant stops at the first FAIL line it is expected to cause (Bc2cppMutantPool.run); the control runs to the end.
    stop = pattern ? /^\s+FAIL .*(?:#{expected.source})/ : nil
    Bc2cppMutantPool.run(env, [RbConfig.ruby, File.join(ROOT, 'scripts/bc2cpp/numeric_intervals_check.rb')], stop_on: stop)
  end
end

failures = []
Bc2cppMutantPool.each_ordered(MUTANTS, work: mutate) do |(name, file, pattern, _replacement, expected), run|
  if run.nil?
    puts "  FAIL #{name}: the mutation site is gone from #{file}"
    failures << name
    next
  end
  if pattern.nil?
    puts "  #{run.success ? 'ok  ' : 'FAIL'} #{name} passes"
    unless run.success
      puts run.out.lines.last(15).join
      failures << name
    end
    next
  end
  failed_lines = run.out.lines.grep(/^\s*FAIL /)
  killed = !run.success && failed_lines.any? { |l| l.match?(expected) }
  puts "  #{killed ? 'ok  ' : 'FAIL'} mutant killed: #{name}"
  unless killed
    puts failed_lines.first(5).join
    puts run.out.lines.last(8).join if failed_lines.empty?
    failures << name
  end
end

if failures.empty?
  puts 'bc2cpp numeric intervals mutation check: PASS'
else
  warn "bc2cpp numeric intervals mutation check: #{failures.size} surviving mutant(s)"
  exit 1
end
