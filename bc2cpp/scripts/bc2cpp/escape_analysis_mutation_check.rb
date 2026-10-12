#!/usr/bin/env ruby
# frozen_string_literal: true

# Mutation test for the escape analysis (docs/adr/0316). Each mutant is a copy of tools/bc2cpp, placed
# inside the repository so its own ../.. is the repository root (the closed world reads the build's
# sources from there; a copy elsewhere sees an empty world and every mutant would die for the wrong reason),
# with one soundness condition removed. scripts/bc2cpp/escape_analysis_check.rb (EA_MODE=static) run against
# the mutant must FAIL on the check that guards the condition. An unmutated control run must pass.
#
# Usage: MRBC=path/to/mrbc ruby scripts/bc2cpp/escape_analysis_mutation_check.rb

require 'fileutils'
require 'rbconfig'
require 'tmpdir'
require_relative 'mutant_pool'

ROOT = File.expand_path('../..', __dir__)
abort 'SKIP: set MRBC' unless ENV['MRBC']

# [name, [[file, pattern, replacement], ...], check label that must FAIL]
MUTANTS = [
  ['an ivar store does not escape', [['escape_analysis.rb', "'SETIV' => :stored_ivar, ", '']], /SETIV|e_ivar/],
  ['a returned value does not escape', [['escape_analysis.rb', "'RETURN' => :returned, 'RETURN_BLK'", "'RETURN_BLK'"]], /RETURN|e_return/],
  ['an unknown callee keeps its arguments',
   [['escape_analysis.rb', 'return true if list.nil? || list.empty? || installer?(list) || @world.native_name?(name)',
     'return true if list.nil? || installer?(list) || @world.native_name?(name)']], /e_arg_unknown_callee|e_arg_stored/],
  ['an unknown method keeps its receiver',
   [['escape_analysis.rb', 'return nil if table.nil? && (list.empty? || @world.native_name?(name) || !opaque.empty?)',
     'return nil if table.nil? && (@world.native_name?(name) || !opaque.empty?)']], /e_receiver_unknown|e_by_name_send/],
  ['an unknown callee keeps its block',
   [['escape_analysis.rb', 'return true if (natives || list.empty?) && !NATIVE_BLOCK_NO_CAPTURE.include?(name)',
     'return true if natives && !NATIVE_BLOCK_NO_CAPTURE.include?(name)']], /e_block_unknown_callee|e_block_by_name/],
  ['a closure that reads the value is not examined', [['escape_analysis.rb', 'next if refs.empty? && !run.self_tracked', 'next']],
   /e_closure_escapes|e_closure_returned/],
  ['a recursive callee is assumed to capture',
   [['escape_analysis.rb', "@floor = [@floor, at].min\n        return false", "@floor = [@floor, at].min\n        return true"]],
   /c_block_recursive|c_lambda_self_ref/],
  ['a register copy does not carry the value',
   [['escape_analysis.rb', "when 'MOVE' then s - [lead] | (held.call(insn.regs[1]) ? [lead] : [])", "when 'MOVE' then s - [lead]"]],
   /e_return_via_move|SETIV through a copy/],
  ['a handler edge is ignored',
   [['escape_analysis.rb', 'seed.call(succ, (s | out).to_a) unless insns[i].successors.include?(succ)',
     'seed.call(succ, (s | out).to_a) if false']], /handler edge/],
  ['subclasses are not consulted', [['escape_analysis.rb', '([klass] + descendants(klass)).each do |c|', '[klass].each do |c|']],
   /subclass override of the callee/],
  ['an alias target is not followed', [['escape_analysis.rb', 'Array(@aliases.fetch(name, [])).each do |old|', '[].each do |old|']],
   /alias of the callee name/],
  ['define_method through send is not seen',
   [['escape_analysis.rb', 'elsif SENDS.include?(insn.op) && FORWARDING_SENDS.include?(insn.sym)', 'elsif false']],
   /define_method reached through send/],
  ['frame reflection is ignored',
   [['escape_analysis.rb', 'return failed(:reflection) unless @world.reflective_sites.empty?', ''],
    ['escape_analysis.rb', 'return true unless @world.reflective_sites.empty?', '']],
   /reads frames by name|ObjectSpace/],
  ['a native with a block is trusted by name',
   [['escape_analysis.rb', "NATIVE_BLOCK_NO_CAPTURE = Set['section', 'select', 'count', 'index']", "NATIVE_BLOCK_NO_CAPTURE = Set['section', 'select', 'count', 'index', 'new']"]],
   /NATIVE_BLOCK_NO_CAPTURE name has a manifest entry/],
  ['the kill switch is ignored', [['escape_analysis.rb', "ENV['BC2CPP_ESCAPE_ANALYSIS'] != '0'", 'true']], /kill switch/],
  ['the consumer admits every block', [['codegen_escape.rb', '!analyzer.creation(irep, index).escapes?', 'true']], /n_stash|n_give|n_send|n_unknown/],
  ['an outside Ruby definer is ignored',
   [['bc2cpp.rb', 'hidden_ruby_names.include?(name) || closed_world.unknown_definer?(name)', 'closed_world.unknown_definer?(name)']],
   /outside Ruby source defining the callee/],
  ['the open world is trusted',
   [['bc2cpp.rb', 'if escape_registry && closed_world && closed_world.global_refusal.nil? && closed_world.method_missing_classes.empty?',
     'if escape_registry && (closed_world.nil? || (closed_world.global_refusal.nil? && closed_world.method_missing_classes.empty?))'],
    ['bc2cpp.rb', 'hidden_ruby_names.include?(name) || closed_world.unknown_definer?(name)',
     'hidden_ruby_names.include?(name) || closed_world&.unknown_definer?(name)'],
    ['bc2cpp.rb', 'foreign_method_names(outside_ruby.reject', 'foreign_method_names(Array(outside_ruby).reject']],
   /without the closed world the proof is not offered/]
].freeze

run_check = lambda do |tool_dir|
  env = { 'EA_TOOL_DIR' => tool_dir, 'EA_MODE' => 'static', 'MRBC' => ENV.fetch('MRBC') }
  [env, [RbConfig.ruby, File.join(ROOT, 'scripts/bc2cpp/escape_analysis_check.rb')]]
end

mutate = lambda do |(_name, edits, expected)|
  # Inside the repo, so the copy's own ../.. is the repo root.
  Dir.mktmpdir('.eamut', ROOT) do |dir|
    FileUtils.cp_r(File.join(ROOT, 'tools/bc2cpp'), dir)
    missing = edits.reject do |file, pattern, replacement|
      path = File.join(dir, 'bc2cpp', file)
      text = File.read(path)
      text.include?(pattern) && File.write(path, text.sub(pattern) { replacement })
    end
    next :gone unless missing.empty?

    env, argv = run_check.call(File.join(dir, 'bc2cpp'))
    Bc2cppMutantPool.run(env, argv, stop_on: /^\s+FAIL .*(?:#{expected.source})/)
  end
end

failures = []
control = Dir.mktmpdir('.eamut', ROOT) do |dir|
  FileUtils.cp_r(File.join(ROOT, 'tools/bc2cpp'), dir)
  env, argv = run_check.call(File.join(dir, 'bc2cpp'))
  Bc2cppMutantPool.run(env, argv)
end
puts "  #{control.success ? 'ok  ' : 'FAIL'} control: the unmutated copy passes"
unless control.success
  puts control.out.lines.grep(/FAIL|rror/).first(8).join
  failures << 'control'
end

Bc2cppMutantPool.each_ordered(MUTANTS, work: mutate) do |(name, edits, expected), run|
  if run == :gone
    puts "  FAIL #{name}: a mutation site is gone from #{edits.map(&:first).uniq.join(', ')}"
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
  puts "bc2cpp escape analysis mutation check: PASS (#{MUTANTS.size} mutants killed, control passes)"
else
  warn "bc2cpp escape analysis mutation check: #{failures.size} failure(s)"
  exit 1
end
