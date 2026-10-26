#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../../tools/bc2cpp/irep'
require_relative '../../tools/bc2cpp/bytecode_ir_operands'
require_relative '../../tools/bc2cpp/escape_analysis'
require_relative '../../tools/bc2cpp/call_site_index'
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
  suite.check("#{label}: packed argument register spans", analyzer.send(:argument_slots, insn) == slots)
  body = Irep.new(label: label, instructions: [insn], nregs: 32, nlocals: 1, catch_handlers: [], reps: [], pool: [])
  if BytecodeIR::Ops::RECEIVER_SEND.include?(op)
    site = CallSiteIndex.build({ label => body })['target'].first
    suite.check("#{label}: call-site arity remains conservative", site.last == call_argc)
  end
  text = insn.argc_text
  suite.check("#{label}: formatting stays at the text boundary",
              text == (old_n ? "n=#{old_n}#{old_nk ? "|nk=#{old_nk}" : ''}" : nil))
end

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
