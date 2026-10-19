#!/usr/bin/env ruby
# frozen_string_literal: true

# NUMERIC_CLASSES (docs/adr/0500): NumericFlow reads its instruction facts from the BytecodeIR::Program. Host only,
# under a second:
#   - Program#operands decodes the second register and the ivar the flow reads, and a bare instruction decodes to
#     the step the Program's table holds;
#   - Program#exits lists the frame exits, and NumericClasses.exit_mask joins the reached ones only;
#   - the literal-element proof (ADR 0354) answers from reaching definitions: a literal reaching the element's
#     register at the ARRAY, through joins and moves, is admitted; a call, a branch or a mutation between the ARRAY
#     and the read, an argument, a captured register, an out-of-range index and a handler are refused.
#
# Usage: ruby scripts/bc2cpp/ir_numeric_classes_check.rb

require 'set'
require_relative '../../tools/bc2cpp/irep'
require_relative '../../tools/bc2cpp/numeric_flow'

failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

NF = NumericFlow
NC = BytecodeIR::NumericClasses

def insn(addr, op, args)
  Insn.new(lineno: 1, addr: addr, op: op, args: args, raw: "#{op} #{args}")
end

$irep_serial = 0
def irep_of(list, handlers: [], pool: [])
  $irep_serial += 1
  Irep.new(label: "nc#{$irep_serial}", nregs: 10, instructions: list, catch_handlers: handlers, reps: [], pool: pool)
end

# The element mask of the read at the last-but-one instruction (the list ends in a RETURN).
def element(list, opaque: Set.new, pool: [], handlers: [])
  NC.element_literal_mask(irep_of(list, pool: pool, handlers: handlers), list.size - 2, opaque)
end

puts '-- operands (host)'
ops = BytecodeIR.for(irep_of([insn(0, 'MOVE', "R3\tR1"), insn(3, 'ADD', "R3\t(R4)"), insn(5, 'SETIV', "@n\tR3"),
                              insn(8, 'GETIV', "R5\t@n"), insn(11, 'GETIDX0', "R6\tR9[0]"), insn(14, 'RETURN', 'R5')]))
check.call('MOVE reads its source, ADD its parenthesised operand',
           ops.operands[0].b == 1 && ops.operands[1].b == 4 && ops.operands[1].ivar.nil?)
check.call('SETIV names its ivar and value, GETIV its ivar',
           ops.operands[2].b == 3 && ops.operands[2].ivar == 'n' && ops.operands[3].ivar == 'n' && ops.operands[3].b.nil?)
check.call('GETIDX0 reads its receiver', ops.operands[4].b == 9)
check.call('an op without either operand shares the empty Operands', ops.operands[5].equal?(BytecodeIR::NO_OPERANDS))
ops.instructions.each do |instruction|
  bare = NF.decode_step(instruction.source, ops.decoded[instruction.index])
  check.call("a bare #{instruction.op} decodes to the Program's step", bare == NF.table(ops).steps[instruction.index])
end

puts '-- exits (host)'
exits_irep = irep_of([insn(0, 'JMPNOT', "R1\t7"), insn(4, 'LOADI_1', "R2\t(1)"), insn(6, 'RETURN', 'R2'),
                      insn(7, 'RETNIL', ''), insn(8, 'RETSELF', '')])
exits = BytecodeIR.for(exits_irep).exits
check.call('every exit is listed, with the register RETURN hands out',
           exits.map { |e| [e.index, e.op, e.reg] } == [[2, 'RETURN', 2], [3, 'RETNIL', nil], [4, 'RETSELF', nil]])
states = [[0], [0], [0, 0, NF::INT], [0], nil]
joined = NC.exit_mask(exits_irep, states) { |exit, state| exit.reg ? state[exit.reg] : NF::NIL }
check.call('exit_mask joins the reached exits only', joined == (NF::INT | NF::NIL))

puts '-- literal elements (host)'
check.call('an Integer literal element of a fresh Array is Integer',
           element([insn(0, 'LOADI_3', "R3\t(3)"), insn(2, 'LOADNIL', 'R4 (nil)'), insn(4, 'ARRAY', "R3\t2"),
                    insn(7, 'LOADI_0', "R4\t(0)"), insn(9, 'GETIDX', "R3\t(R4)"), insn(11, 'RETURN', 'R3')]) == NF::INT)
check.call('a negative index counts from the end',
           element([insn(0, 'LOADI_3', "R3\t(3)"), insn(2, 'STRING', "R4\tL[0]"), insn(5, 'ARRAY', "R3\t2"),
                    insn(8, 'LOADI__1', "R4\t(-1)"), insn(10, 'GETIDX', "R3\t(R4)"), insn(12, 'RETURN', 'R3')]) == NF::STR)
check.call('GETIDX0 reads position 0',
           element([insn(0, 'LOADNIL', 'R3 (nil)'), insn(2, 'ARRAY', "R3\t1"), insn(5, 'GETIDX0', "R5\tR3[0]"),
                    insn(8, 'RETURN', 'R5')]) == NF::NIL)
check.call('a Float pool literal is Float (the type layer)',
           element([insn(0, 'LOADL', "R3\tL[0]\t; 1.5"), insn(3, 'ARRAY', "R3\t1"), insn(6, 'GETIDX0', "R5\tR3[0]"),
                    insn(9, 'RETURN', 'R5')], pool: [{ type: :float, value: '1.5' }]) == NF::FLT)
check.call('a join of two literal arms holds both classes',
           element([insn(0, 'LOADI_1', "R3\t(1)"), insn(2, 'JMPNOT', "R1\t8"), insn(6, 'LOADNIL', 'R3 (nil)'),
                    insn(8, 'ARRAY', "R3\t1"), insn(11, 'GETIDX0', "R5\tR3[0]"), insn(14, 'RETURN', 'R5')]) ==
             (NF::INT | NF::NIL))
check.call('a literal moved into the element register is followed',
           element([insn(0, 'LOADI_2', "R6\t(2)"), insn(2, 'MOVE', "R3\tR6"), insn(5, 'ARRAY', "R3\t1"),
                    insn(8, 'GETIDX0', "R5\tR3[0]"), insn(11, 'RETURN', 'R5')]) == NF::INT)
check.call('a literal written before an unrelated call still reaches the ARRAY',
           element([insn(0, 'LOADI_2', "R3\t(2)"), insn(2, 'SEND0', "R4\t:f"), insn(5, 'ARRAY', "R3\t1"),
                    insn(8, 'GETIDX0', "R5\tR3[0]"), insn(11, 'RETURN', 'R5')]) == NF::INT)
check.call('a call between the ARRAY and the read refuses',
           element([insn(0, 'LOADI_2', "R3\t(2)"), insn(2, 'ARRAY', "R3\t1"), insn(5, 'SEND0', "R6\t:f"),
                    insn(8, 'GETIDX0', "R5\tR3[0]"), insn(11, 'RETURN', 'R5')]).nil?)
check.call('a branch into the corridor refuses',
           element([insn(0, 'LOADI_2', "R3\t(2)"), insn(2, 'ARRAY', "R3\t1"), insn(5, 'JMPNOT', "R1\t11"),
                    insn(9, 'LOADNIL', 'R7 (nil)'), insn(11, 'GETIDX0', "R5\tR3[0]"), insn(14, 'RETURN', 'R5')]).nil?)
check.call('a store into the Array before the read refuses',
           element([insn(0, 'LOADI_2', "R3\t(2)"), insn(2, 'ARRAY', "R3\t1"), insn(5, 'SETIDX', "R3\t(R4)\t(R5)"),
                    insn(8, 'GETIDX0', "R5\tR3[0]"), insn(11, 'RETURN', 'R5')]).nil?)
check.call('an element that is an argument refuses',
           element([insn(0, 'MOVE', "R3\tR1"), insn(3, 'ARRAY', "R3\t1"), insn(6, 'GETIDX0', "R5\tR3[0]"),
                    insn(9, 'RETURN', 'R5')]).nil?)
check.call('a call result element refuses',
           element([insn(0, 'SEND0', "R3\t:f"), insn(3, 'ARRAY', "R3\t1"), insn(6, 'GETIDX0', "R5\tR3[0]"),
                    insn(9, 'RETURN', 'R5')]).nil?)
check.call('a Symbol element stays unproven (a closed-world class bit only the oracle names)',
           element([insn(0, 'LOADSYM', "R3\t:a"), insn(3, 'ARRAY', "R3\t1"), insn(6, 'GETIDX0', "R5\tR3[0]"),
                    insn(9, 'RETURN', 'R5')]).nil?)
check.call('a captured element register refuses',
           element([insn(0, 'LOADI_2', "R3\t(2)"), insn(2, 'ARRAY', "R3\t1"), insn(5, 'GETIDX0', "R5\tR3[0]"),
                    insn(8, 'RETURN', 'R5')], opaque: Set['3']).nil?)
check.call('an index past the end refuses',
           element([insn(0, 'LOADI_2', "R3\t(2)"), insn(2, 'ARRAY', "R3\t1"), insn(5, 'LOADI_1', "R4\t(1)"),
                    insn(7, 'GETIDX', "R3\t(R4)"), insn(9, 'RETURN', 'R3')]).nil?)
check.call('a non-literal index refuses',
           element([insn(0, 'LOADI_2', "R3\t(2)"), insn(2, 'ARRAY', "R3\t1"), insn(5, 'MOVE', "R4\tR1"),
                    insn(8, 'GETIDX', "R3\t(R4)"), insn(10, 'RETURN', 'R3')]).nil?)
check.call('a receiver that is not an Array literal refuses',
           element([insn(0, 'MOVE', "R3\tR1"), insn(3, 'GETIDX0', "R5\tR3[0]"), insn(6, 'RETURN', 'R5')]).nil?)
with_handler = [insn(0, 'LOADI_2', "R3\t(2)"), insn(2, 'ARRAY', "R3\t1"), insn(5, 'GETIDX0', "R5\tR3[0]"),
                insn(8, 'RETURN', 'R5'), insn(10, 'EXCEPT', 'R6'), insn(12, 'RETURN', 'R6')]
check.call('an irep with a handler refuses',
           NC.element_literal_mask(irep_of(with_handler, handlers: [{ type: :rescue, begin: 0, end: 8, target: 10 }]),
                                   2, Set.new).nil?)
ENV['BC2CPP_LITERAL_ELEMENT_PROOF'] = '0'
check.call('BC2CPP_LITERAL_ELEMENT_PROOF=0 withdraws the proof',
           element([insn(0, 'LOADI_2', "R3\t(2)"), insn(2, 'ARRAY', "R3\t1"), insn(5, 'GETIDX0', "R5\tR3[0]"),
                    insn(8, 'RETURN', 'R5')]).nil?)
ENV.delete('BC2CPP_LITERAL_ELEMENT_PROOF')

puts '-- through the flow (host)'
# An oracle that proves nothing but the literals the flow models itself.
class BareOracle
  def entry_mask(_irep, _reg) = NF::OTHER
  def const_mask(_insn) = NF::OTHER
  def ivar_slots(_irep) = []
  def ivar_entry_mask(_irep, _name) = NF::OTHER
  def ivar_fact_mask(_irep, _name) = NF::OTHER
  def send_mask(_irep, _index, _insn, _state) = NF::OTHER
  def upvar_mask(_irep, _insn) = NF::OTHER
  def pool_mask(_irep, _insn) = NF::OTHER
  def op_native?(_sym) = true
  def nil_raises?(_sym) = true
end
flow = irep_of([insn(0, 'LOADI_3', "R3\t(3)"), insn(2, 'LOADI_4', "R4\t(4)"), insn(4, 'ARRAY', "R3\t2"),
                insn(7, 'LOADI_1', "R4\t(1)"), insn(9, 'GETIDX', "R3\t(R4)"), insn(11, 'ADDI', "R3\t1"),
                insn(14, 'RETURN', 'R3')])
flow_states = NF.states(flow, BareOracle.new, Set.new)
check.call('the flow reads the element proof: `[3, 4][1] + 1` is Integer', flow_states[6][3] == NF::INT)

if failures.empty?
  puts 'ir_numeric_classes_check: ok'
else
  warn "ir_numeric_classes_check: #{failures.size} failure(s)"
  exit 1
end
