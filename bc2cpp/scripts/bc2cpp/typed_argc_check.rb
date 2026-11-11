#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../../tools/bc2cpp/irep'
require_relative '../../tools/bc2cpp/bytecode_ir_operands'
require_relative '../../tools/bc2cpp/escape_analysis'
require_relative '../../tools/bc2cpp/call_site_index'
require_relative '../../tools/bc2cpp/block_self'
require_relative '../../tools/bc2cpp/ir_block_operands'
require_relative 'check_support'

suite = FixtureCheck.new('typed_argc_check')
model = BytecodeIR::OperandModel
analyzer = EscapeAnalysis::Analyzer.allocate
# positional count, keyword count, positional splat, keyword presence, keyword splat, register spans.
cases = {
  'absent SEND0' => [:SEND0, 'R2 :target', [nil, nil, false, false, false], [0, 0], 0],
  'fixed zero' => [:SEND, 'R2 :target n=0', [0, nil, false, false, false], [0, 0], 0],
  'fixed maximum' => [:SEND, 'R2 :target n=14', [14, nil, false, false, false], [14, 0], 14],
  'explicit keyword zero' => [:SEND, 'R2 :target n=0|nk=0', [0, 0, false, true, false], [0, 0], 0],
  'keyword pairs' => [:SENDB, 'R2 :target n=2|nk=3', [2, 3, false, true, false], [2, 6], nil],
  'positional splat' => [:SSENDB, 'R2 :target n=*', [nil, nil, true, false, false], [1, 0], nil],
  'keyword splat' => [:SEND, 'R2 :target n=2|nk=*', [2, nil, false, true, true], [2, 1], nil],
  'both splats' => [:SEND, 'R2 :target n=*|nk=*', [nil, nil, true, true, true], [1, 1], nil]
}
cases.each do |label, (op, args, expected, slots, call_argc)|
  insn = Insn.new(op: op, args: args, addr: 0)
  old_n = insn.n_spec
  old_nk = insn.nk_spec
  insn.define_singleton_method(:n_spec) { raise 'analysis formatted a positional count' }
  insn.define_singleton_method(:nk_spec) { raise 'analysis formatted a keyword count' }
  spec = model.argc_spec(insn)
  suite.check("#{label}: numeric counts and explicit flags", spec.to_a == expected)
  suite.check("#{label}: primitive slot counts", [insn.positional_slots, insn.keyword_slots] == slots)
  suite.check("#{label}: packed argument register spans", analyzer.send(:argument_slots, insn) == slots)
  expected_block = insn.argc_operand ? insn.reg + slots.sum + 1 : nil
  suite.check("#{label}: block operand register", IrBlockOperands.block_register(insn) == expected_block)
  block_slot = BytecodeIR::Ops::B_SUFFIX_OPS.include?(op) ? 1 : 0
  suite.check("#{label}: block-self send window", BlockSelf.send_window(insn) == slots.sum + block_slot)
  body = Irep.new(label: label, instructions: [insn], nregs: 32, nlocals: 1, catch_handlers: [], reps: [], pool: [])
  if BytecodeIR::Ops::RECEIVER_SEND.include?(op)
    site = CallSiteIndex.build({ label => body })['target'].first
    suite.check("#{label}: call-site arity remains conservative", site.last == call_argc)
  end
  text = insn.argc_text
  suite.check("#{label}: formatting stays at the text boundary",
              text == (old_n ? "n=#{old_n}#{old_nk ? "|nk=#{old_nk}" : ''}" : nil))
end

probe = Insn.new(op: :SEND, args: 'R2 :target n=3|nk=2')
probe.typed
probe.argc
before = GC.stat(:total_allocated_objects)
10_000.times { probe.positional_slots; probe.keyword_slots }
allocated = GC.stat(:total_allocated_objects) - before
suite.check('primitive slot queries allocate no per-query objects', allocated < 20)
before = GC.stat(:total_allocated_objects)
10_000.times { analyzer.send(:argument_slots, probe) }
allocated = GC.stat(:total_allocated_objects) - before
suite.check('escape spans allocate only the returned pair', allocated.between?(10_000, 10_020))

if ENV['MRBC']
  suite.require_mrbc!
  suite.compile(<<~SOURCE) do |ireps, _root|
    def typed_count_calls(receiver, values, keywords)
      receiver.fixed
      receiver.fixed(1, 2)
      receiver.fixed(value: 1)
      receiver.fixed(*values)
      receiver.fixed(**keywords)
    end
  SOURCE
    calls = ireps.values.flat_map(&:instructions).select { |i| i.sym == 'fixed' }
    suite.check('binary decoding retains all count shapes', calls.size == 5 &&
                calls.any? { |i| i.argc == 2 && !i.keyword_arguments? } &&
                calls.any?(&:positional_splat?) && calls.any?(&:keyword_splat?) &&
                calls.any? { |i| i.keyword_argc == 1 })
  end
end
suite.finish!
