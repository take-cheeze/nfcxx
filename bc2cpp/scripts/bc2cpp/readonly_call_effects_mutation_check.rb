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
  ['disable ignored', 'readonly_call_effects.rb', "ENV['BC2CPP_READONLY_CALL_EFFECTS'] == '0'", 'false', { 'BC2CPP_READONLY_CALL_EFFECTS' => '0' }],
  ['arity ignored', 'readonly_call_effects.rb', 'body.enter&.enter_fields == Array.new(8, 0)', 'true', {}],
  ['nested frames ignored', 'readonly_call_effects.rb', 'Array(body.reps).empty?', 'true', {}],
  ['handlers ignored', 'readonly_call_effects.rb', '!program.handlers?', 'true', {}],
  ['unresolved flow ignored', 'readonly_call_effects.rb', 'program.resolved?', 'true', {}],
  ['opcode effects ignored', 'readonly_call_effects.rb', 'OPS.include?(insn.op)', 'true', {}],
  ['receiver coverage ignored', 'readonly_call_effects.rb', 'classes.values.reduce(0, :|) == receiver', 'true', {}],
  ['union member ignored', 'readonly_call_effects.rb', 'classes.all?', 'classes.any?', {}],
  ['outside lookup ignored', 'readonly_call_effects.rb', 'closed_world_exact_target(insn.sym, klass)', '@registry.fetch(insn.sym, []).find { |d| d.owner == klass }', {}],
  ['implicit self ignored', 'codegen_return_classes.rb', 'super(irep, index, explicit, inputs)', 'super(irep, index, insn, state)', {}],
  ['provenance clearing omitted', 'numeric_flow.rb', 'nregs.times { |r| out[pb + r] = 0 }', 'nregs.times { |_r| nil }', {}],
  ['exceptional refresh omitted', 'numeric_flow.rb', 'refresh_slots(state, ctx)', '# refresh omitted', {}],
  ['effect hook omitted', 'numeric_flow.rb', 'preserve = oracle.respond_to?(:preserves_ivar_slots?)', 'preserve = false && oracle.respond_to?(:preserves_ivar_slots?)', {}]
].freeze
work = lambda do |(_name, file, pattern, replacement, extra)|
  Dir.mktmpdir('readonly-effect-mutant') do |dir|
    FileUtils.cp_r(File.join(ROOT, 'tools'), dir)
    if file
      path = File.join(dir, 'tools/bc2cpp', file)
      source = File.read(path)
      next nil unless source.include?(pattern)

      File.write(path, source.sub(pattern) { replacement })
    end
    env = { 'BC2CPP_TOOL' => File.join(dir, 'tools/bc2cpp/bc2cpp.rb'), 'CC_GENERATED_ONLY' => '1' }.merge(extra)
    Bc2cppMutantPool.run(env, [RbConfig.ruby, File.join(ROOT, 'scripts/bc2cpp/readonly_call_effects_check.rb')])
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
puts 'readonly call effects mutations: PASS'
