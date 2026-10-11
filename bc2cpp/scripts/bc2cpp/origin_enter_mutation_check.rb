#!/usr/bin/env ruby
# frozen_string_literal: true

# Mutation check for the origin walk's ENTER slot model, EXCEPT pass-through and the join may-sets (ADR 0379). Each mutant is a copy of
# tools/bc2cpp with one rule broken; the hand-built checks (bc2cpp_origin_multiwrite_check,
# bc2cpp_origin_transfers_check, bc2cpp_origin_may_sets_check) must fail on it. The control mutant is unchanged and
# must pass. No compiler is needed.
require 'fileutils'
require 'rbconfig'
require 'tmpdir'
require_relative 'mutant_pool'
ROOT = File.expand_path('../..', __dir__)
CHECKS = %w[bc2cpp_origin_multiwrite_check.rb bc2cpp_origin_transfers_check.rb bc2cpp_origin_may_sets_check.rb].freeze
DATAFLOW = 'bytecode_ir_dataflow.rb'
TABLE = 'site_origin_table.rb'
CENSUS = 'site_census.rb'
MUTANTS = [
  ['control', nil, nil, nil],
  ['R1 is the entry value', DATAFLOW, 'return(n == 1 && kd.zero? ? :arg : :entry) if n <= req + opt', 'return :entry if n <= req + opt'],
  ['R1 with keywords is a parameter', DATAFLOW, 'n == 1 && kd.zero? ? :arg : :entry', 'n == 1 ? :arg : :entry'],
  ['post slots are the entry value', DATAFLOW, 'return :post if n <= len', 'return :entry if n <= len'],
  ['rest slot is a post', DATAFLOW, 'return :rest if rest.positive? && n == req + opt + 1', 'return :post if rest.positive? && n == req + opt + 1'],
  ['keyword hash needs no keywords', DATAFLOW, 'return :hash if kd == 1 && n == len + 1', 'return :hash if n == len + 1'],
  ['block slot ignores the keyword hash', DATAFLOW, 'return :block if n == len + kd + 1', 'return :block if n == len + 1'],
  ['every register is a local', DATAFLOW, 'nlocals && n < nlocals ? :local : :temp', ':local'],
  ['locals include nlocals', DATAFLOW, 'nlocals && n < nlocals ? :local : :temp', 'nlocals && n <= nlocals ? :local : :temp'],
  ['unknown nlocals is a local', DATAFLOW, 'nlocals && n < nlocals ? :local : :temp', '!nlocals || n < nlocals ? :local : :temp'],
  ['a temporary passes to the entry', DATAFLOW, 'when :temp then :refuse_enter_temp', 'when :temp then :pass'],
  ['a malformed operand is read anyway', DATAFLOW, 'return nil unless fields.size == 8', 'return nil if false'],
  ['locals are not typed', DATAFLOW, '%i[arg rest post hash block local].include?(kind)', '%i[arg rest post hash block].include?(kind)'],
  ['the typed slots reach the codegen walk', DATAFLOW, 'if typed_enter then enter_origin_effect(insn, reg)', 'if true then enter_origin_effect(insn, reg)'],
  ['a local is a parameter', TABLE, "definition.built == :local ? 'literal_or_fresh' : 'parameter'", "'parameter'"],
  ['a join is not sorted', TABLE, 'defs.map { |d| category(irep, d) }.uniq.sort.join', 'defs.map { |d| category(irep, d) }.uniq.join'],
  ['a join keeps repeats', TABLE, 'defs.map { |d| category(irep, d) }.uniq.sort.join', 'defs.map { |d| category(irep, d) }.sort.join'],
  ['a mixed call is unknown', TABLE, "return result_category(insn.op) || 'unknown'", "return 'unknown'"],
  ['a call without text is unknown', TABLE, "'SUPER', 'BLKCALL' then 'call_result'\n      else 'other'", "'SUPER', 'BLKCALL' then 'unknown'\n      else 'other'"],
  ['EXCEPT refuses other registers', DATAFLOW, "when 'EXCEPT' then insn.reg == reg ? :define : :pass", "when 'EXCEPT' then insn.reg == reg ? :define : :refuse"],
  ['EXCEPT passes its own register', DATAFLOW, "when 'EXCEPT' then insn.reg == reg ? :define : :pass", "when 'EXCEPT' then :pass"],
  ['a re-assigned loop element is trusted', CENSUS, "lines[(j + 1)...i].any? { |l| l =~ /\\b\#{recv} = / }", 'false'],
  ['any indexed read is a loop element', CENSUS, "origin == 'indexed_result' ? origin : nil", 'origin'],
  ['an unknown member is dropped', CENSUS, "return ['unknown', 'ambiguous', set] if set.include?('unknown')", 'nil'],
  ['agreeing origins are a join', CENSUS, "[set.size == 1 ? set.first : 'join', 'ambiguous', set]", "['join', 'ambiguous', set]"],
  ['a join without a set is a join', CENSUS, "status == 'ambiguous' && category != '-'", "status == 'ambiguous'"],
  ['a register mismatch is trusted', CENSUS, "recv == \"r\#{m[3]}\" ? join_origin(category)", 'true ? join_origin(category)']
].freeze
work = lambda do |(_name, file, pattern, replacement)|
  Dir.mktmpdir('origin-enter-mutant') do |dir|
    FileUtils.cp_r(File.join(ROOT, 'tools'), dir)
    FileUtils.mkdir_p(File.join(dir, 'scripts'))
    CHECKS.each { |check| FileUtils.cp(File.join(ROOT, 'scripts', check), File.join(dir, 'scripts', check)) }
    if file
      path = File.join(dir, 'tools/bc2cpp', file)
      source = File.read(path)
      next nil unless source.include?(pattern)

      File.write(path, source.sub(pattern) { replacement })
    end
    # The mutant is caught when any check fails; the control needs every check to pass.
    results = CHECKS.map { |check| Bc2cppMutantPool.run({}, [RbConfig.ruby, File.join(dir, 'scripts', check)]) }
    out = results.map(&:out).join
    results.all?(&:success) ? Bc2cppMutantPool::Result.new(out, true, false) : Bc2cppMutantPool::Result.new(out, false, false)
  end
end
failures = []
Bc2cppMutantPool.each_ordered(MUTANTS, work: work) do |(name, file, _pattern, _replacement), run|
  ok = run && (file ? !run.success : run.success)
  puts "  #{ok ? 'ok  ' : 'FAIL'} #{name}"
  failures << name unless ok
  warn run&.out unless ok || run.nil?
  warn "pattern of '#{name}' not found" if run.nil?
end
abort "FAILED: #{failures.join(', ')}" unless failures.empty?
puts 'origin enter mutations: PASS'
