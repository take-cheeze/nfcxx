#!/usr/bin/env ruby
# frozen_string_literal: true

# Insn operand decoding must ignore mrbc's trailing `; R5:name` comment, and
# BytecodeIR must keep the branch edge of a commented jump.
require_relative '../../tools/bc2cpp/irep'
require_relative '../../tools/bc2cpp/bytecode_ir'

def insn(addr, op, args)
  Insn.new(lineno: 1, addr: addr, op: op, args: args, raw: "#{op} #{args}")
end

failures = []
check = ->(label, ok) { failures << label unless ok }

commented = insn(7, 'JMPIF', "R5\t016\t; R5:quit_on_close")
check.call('commented jump target', commented.jump_target == 16)
check.call('comment is not an operand', commented.typed.map(&:kind) == %i[reg addr])
check.call('plain jump target', insn(0, 'JMP', '019').jump_target == 19)
check.call('non-jump has no target', insn(0, 'MOVE', "R1\tR2\t; R2:x").jump_target.nil?)
check.call('unparsable operands raise', begin; insn(0, 'JMP', 'R5').typed; false; rescue ArgumentError; true; end)

irep = Irep.new(label: 't', instructions: [commented, insn(11, 'LOADI_1', 'R5 (1)'), insn(16, 'RETURN', 'R5')])
edges = BytecodeIR::Program.new(irep).instruction_at(0).successors
check.call('BytecodeIR keeps commented edge', edges.sort == [1, 2])

check.call('branch_target of JMPUW', insn(0, 'JMPUW', '021').branch_target == 21)
check.call('branch_target of conditional', commented.branch_target == 16)
check.call('branch_target of non-branch', insn(0, 'MOVE', "R1\tR2").branch_target.nil?)
edge_irep = Irep.new(label: 't2', instructions: [insn(0, 'JMPNOT', "R1\t9"), insn(4, 'JMP', '9'), insn(9, 'RETURN', 'R1')])
check.call('jump_edges_before lists edges', BytecodeIR::Program.new(edge_irep).jump_edges_before(2, %w[JMP JMPNOT]) == [[0, 2], [1, 2]])
check.call('jump_edges_before stops at limit', BytecodeIR::Program.new(edge_irep).jump_edges_before(1, %w[JMP JMPNOT]) == [[0, 2]])
bad_irep = Irep.new(label: 't3', instructions: [insn(0, 'JMP', '77'), insn(4, 'RETURN', 'R1')])
check.call('jump_edges_before nil on unresolved target', BytecodeIR::Program.new(bad_irep).jump_edges_before(2, %w[JMP]).nil?)
uw_irep = Irep.new(label: 't3b', instructions: [insn(0, 'JMPUW', '9'), insn(4, 'LOADNIL', 'R1 (nil)'), insn(9, 'RETURN', 'R1')])
check.call('jump_edges_before lists a JMPUW edge when asked (jump_target is nil for it)',
           BytecodeIR::Program.new(uw_irep).jump_edges_before(3, %w[JMP JMPUW]) == [[0, 2]])
check.call('jump_edges_before ignores a JMPUW that is not asked for',
           BytecodeIR::Program.new(uw_irep).jump_edges_before(3, %w[JMP]) == [])

pred_irep = Irep.new(label: 't4', instructions: [
  insn(0, 'JMPIF', "R1\t12"), insn(4, 'RAISEIF', 'R1'), insn(6, 'JMPUW', '14'),
  insn(8, 'LOADNIL', 'R1 (nil)'), insn(12, 'RETURN', 'R1'), insn(14, 'RETURN', 'R2')
])
preds = BytecodeIR::Program.new(pred_irep).instruction_predecessors
check.call('entry edge into instruction 0', preds[0].to_a == [BytecodeIR::ENTRY])
check.call('conditional branch adds target and fallthrough', preds[4].include?(0) && preds[1].include?(0))
check.call('RAISEIF conservatively falls through', preds[2].include?(1))
check.call('JMPUW never falls through', !preds[3].include?(2))
check.call('JMPUW target predecessor', preds[5].include?(2))
check.call('predecessors nil when unresolved', BytecodeIR::Program.new(bad_irep).instruction_predecessors.nil?)

wr = Irep.new(label: 't5', instructions: [
  insn(0, 'LOADNIL', 'R3 (nil)'), insn(2, 'MOVE', "R4\tR3"), insn(5, 'MOVE', "R5\tR4"),
  insn(8, 'SEND', "R6\t:foo\tn=0"), insn(12, 'RETURN', 'R5')
])
check.call('last_writer finds nearest write', wr.last_writer(4, 4).addr == 2)
check.call('last_writer_index none before entry', wr.last_writer_index(-1, 3).nil?)
check.call('source_writer follows MOVE chain', wr.source_writer(3, 5).op == 'LOADNIL')
check.call('source_writer nil when never written', wr.source_writer(3, 9).nil?)
check.call('index_of_addr', wr.index_of_addr(8) == 3)
check.call('instructions_at half-open range', wr.instructions_at(2...8).map(&:addr) == [2, 5])

abort("bc2cpp_insn_operands_check FAILED: #{failures.join(', ')}") unless failures.empty?
puts 'bc2cpp_insn_operands_check OK'
