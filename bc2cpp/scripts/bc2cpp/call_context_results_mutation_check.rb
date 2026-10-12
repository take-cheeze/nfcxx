#!/usr/bin/env ruby
# frozen_string_literal: true

require 'fileutils'
require 'rbconfig'
require 'tmpdir'
require_relative 'mutant_pool'

ROOT = File.expand_path('../..', __dir__)
abort 'SKIP: set MRBC' unless ENV['MRBC']
MUTANTS = [
  ['control', nil, nil, nil, {}],
  ['switch ignored', 'codegen_return_classes.rb', "ENV['BC2CPP_CALL_CONTEXT_RESULTS'] != '0'", 'true', { 'BC2CPP_CALL_CONTEXT_RESULTS' => '0' }],
  ['lexical subclass gate omitted', 'codegen_return_classes.rb', '@closed_world.exact_class?(owner)', 'true', {}],
  ['argument cache omitted', 'codegen_return_classes.rb', 'contextual ? arguments : nil', 'nil', {}],
  ['argument masks ignored', 'codegen_return_classes.rb', '@arguments.fetch(reg - 1, NumericFlow::OTHER)', 'NumericFlow::OTHER', {}],
  ['declaring self substituted', 'codegen_return_classes.rb', 'return_class_context_def_mask(definition, state[insn.reg.to_i], arguments)', 'return_class_context_def_mask(definition, numeric_class_bit(definition.owner), arguments)', {}],
  ['block switch ignored', 'codegen_return_classes.rb', "ENV['BC2CPP_BLOCK_CONTEXT_RESULTS'] == '0'", 'false', { 'BC2CPP_BLOCK_CONTEXT_RESULTS' => '0' }],
  ['reflective local writer audit omitted', 'codegen_return_classes.rb', 'return nil unless captured_local_class_enabled?', 'return nil if false', {}],
  ['captured writes ignored', 'codegen_return_classes.rb', 'NumericFlow.states(body, oracle, fixnum_proof_ctx(body)[:upvars], writes)', 'NumericFlow.states(body, oracle, Set.new, writes)', {}],
  ['later capture stores omitted', 'codegen_return_classes.rb', '(frame[:writes][index] || 0)', '0', {}],
  ['capture context omitted', 'codegen_return_classes.rb', '@cg.return_class_context_upvar_mask(irep, insn, @contexts)', 'NumericFlow::OTHER', {}],
  ['nonlocal block returns omitted', 'codegen_return_classes.rb', 'block_returns = return_class_context_block_returns(body, states, writes)', 'block_returns = 0', {}],
  ['trailing-argument count ignored', 'call_context_arguments.rb', 'rest.zero? && arguments.size > required + optional + post', 'false', {}],
  ['keyword and block shape ignored', 'call_context_arguments.rb', '[keywords, keydict, block, fields[7]].all?(&:zero?)', 'true', {}],
  ['optional initializer slot ignored', 'call_context_arguments.rb', 'target = index + supplied + 1', 'target = index + 1', {}],
  ['ENTER selection ignored', 'numeric_flow.rb', 'oracle.respond_to?(:context_enter_edges) && oracle.context_enter_edges.key?(i)', 'false', {}],
  ['signature switch ignored', 'call_context_arguments.rb', "ENV['BC2CPP_CONTEXT_ARGUMENT_SHAPES'] == '0'", 'false', { 'BC2CPP_CONTEXT_ARGUMENT_SHAPES' => '0' }],
  ['closure gate omitted', 'codegen_return_classes.rb', 'unless Array(body.reps).empty?', 'if false', {}],
  ['LOADSELF fact omitted', 'numeric_flow.rb', 'oracle.respond_to?(:loadself_mask) ? oracle.loadself_mask : OTHER', 'OTHER', {}],
  ['outside lookup ignored', 'codegen_return_classes.rb', 'definition = closed_world_exact_target(name, receiver_class, accessor: argc == 0)', 'definition = @registry.fetch(name, []).find { |d| d.owner == receiver_class }', {}],
  ['implicit receiver ignored', 'codegen_return_classes.rb', 'inputs[insn.reg.to_i] = @receiver', 'inputs[insn.reg.to_i] = NumericFlow::OTHER', {}]
].freeze
work = lambda do |(_name, file, pattern, replacement, extra)|
  Dir.mktmpdir('context-mutant') do |dir|
    FileUtils.cp_r(File.join(ROOT, 'tools'), dir)
    if file
      path = File.join(dir, 'tools/bc2cpp', file)
      source = File.read(path)
      next nil unless source.include?(pattern)

      File.write(path, source.sub(pattern) { replacement })
    end
    env = { 'BC2CPP_TOOL' => File.join(dir, 'tools/bc2cpp/bc2cpp.rb'), 'CC_GENERATED_ONLY' => '1' }.merge(extra)
    Bc2cppMutantPool.run(env, [RbConfig.ruby, File.join(ROOT, 'scripts/bc2cpp/call_context_results_check.rb')])
  end
end
failures = []
Bc2cppMutantPool.each_ordered(MUTANTS, work: work) do |(name, file, _pattern, _replacement, _extra), run|
  ok = run && (file ? !run.success && run.out.match?(/^\s+FAIL /) : run.success)
  puts "  #{ok ? 'ok  ' : 'FAIL'} #{name}"
  failures << name unless ok
  warn run&.out unless ok
end
abort "FAILED: #{failures.join(', ')}" unless failures.empty?
puts 'bc2cpp call context results mutation check: PASS'
