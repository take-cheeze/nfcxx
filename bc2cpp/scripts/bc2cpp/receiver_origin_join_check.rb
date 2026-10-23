#!/usr/bin/env ruby
# frozen_string_literal: true

# The POLY_DIAG `origin=` of an unresolved receiver (receiver_trace_origin) names every producer that reaches the
# use, through BytecodeIR.reaching_definitions. The textual walk named only the instruction nearest before the use,
# so a join `x = nil; x = a if c; x.to_s` reported just the arm written last in the instruction order. A receiver with
# one producer keeps its single label.
#
# Usage: MRBC=path/to/mrbc ruby scripts/bc2cpp/receiver_origin_join_check.rb

require_relative 'check_support'

suite = FixtureCheck.new('receiver_origin_join_check')
suite.require_mrbc!
# The fixtures declare no RBS; the repository's signatures name engine classes these fixtures lack.
ENV['BC2CPP_SIG_DIRS'] = ''
require_relative '../../tools/bc2cpp/bc2cpp'
check = suite.method(:check)

SNIPPET = <<~RUBY
  def probe(c, a)
    x = nil
    x = a if c
    x.to_s
  end
  def single(c, a)
    x = nil
    x.to_s
  end
RUBY

# The origin label of each method's `to_s` receiver, computed while the fixture is compiled.
origins = suite.compile(SNIPPET) do |ireps, root|
  registry = build_registry(ireps, root)[0]
  gen = CodeGen.new(ireps, registry, {}, {}, {}, {}, {}, {}, {}, {}, {}, Set.new)
  %w[probe single].to_h do |name|
    irep = ireps.fetch(registry.fetch(name).first.irep)
    insn, idx = irep.instructions.each_with_index.find do |candidate, _|
      BytecodeIR::Ops::SEND.include?(candidate.op) && candidate.sym == 'to_s'
    end
    [name, gen.send(:receiver_trace_origin, irep, idx, insn.reg.to_i)]
  end
end

puts '-- RECEIVER_ORIGIN (join-aware POLY_DIAG origin)'
check.call('a join names both producers that reach the use, sorted',
           origins['probe'] == 'join:incoming_or_unwritten_register.write_loadnil')
check.call('a receiver with one producer keeps its single label', origins['single'] == 'write_loadnil')

suite.finish!
