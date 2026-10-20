#!/usr/bin/env ruby
# frozen_string_literal: true

# EXACT_LITERAL (ADR 0280): BytecodeIR::Types#exact_at, the exact-class proof of the exact-receiver, `===`, `times`
# and literal-block sites, on hand-built bytecode. Every reaching definition must be a literal (or the `*rest` slot)
# of one class; a container op keeps the class only of the container it extends.
#
#   ruby scripts/bc2cpp/ir_facts_check.rb
require_relative '../../../tools/bc2cpp/irep'
require_relative '../../../tools/bc2cpp/bytecode_ir'

require_relative '../check_support'
require_relative '../ir_instruction_fixtures'
extend IrInstructionFixtures
suite = FixtureCheck.new('ir_exact_types_check')
check = suite.method(:check)
types = lambda do |list, enter: nil|
  list = [insn(0, 'ENTER', enter)] + list if enter
  BytecodeIR::Types.new(Irep.new(label: 't', instructions: list, catch_handlers: [], nlocals: 8))
end
klass = ->(fact) { fact&.klass }

# 0: ARRAY R1 0   1: ARYPUSH R1 1   2: STRING R3 L[0]   3: STRCAT R3 (R4)   4: LOADINEG R5 -5   5: RETURN R1
straight = types.call([
  insn(0, 'ARRAY', "R1\t0"), insn(3, 'ARYPUSH', "R1\t1"), insn(6, 'STRING', "R3\tL[0]"), insn(9, 'STRCAT', "R3\t(R4)"),
  insn(11, 'LOADINEG', "R5\t-5"), insn(14, 'RETURN', 'R1')
])
check.call('ARYPUSH keeps the Array literal it extends', klass.call(straight.exact_at(5, '1')) == :Array)
check.call('STRCAT keeps the String literal it extends', klass.call(straight.exact_at(5, '3')) == :String)
check.call('LOADINEG is an Integer with its negative value', straight.exact_at(5, '5').to_a == [:Integer, -5])
check.call('an unwritten temporary has no exact class', straight.exact_at(5, '6').nil?)

# A join of two literals on each register: R1 is 3 on both arms, R2 an Array on one and a Hash on the other.
join = types.call([
  insn(0, 'JMPNOT', "R7\t12"), insn(4, 'LOADI_3', "R1\t(3)"), insn(6, 'ARRAY', "R2\t0"), insn(9, 'JMP', '16'),
  insn(12, 'LOADI_3', "R1\t(3)"), insn(14, 'HASH', "R2\t0"), insn(16, 'RETURN', 'R1')
])
check.call('a join of the same Integer literal keeps its value', join.exact_at(6, '1').to_a == [:Integer, 3])
check.call('a join of an Array and a Hash literal has no exact class', join.exact_at(6, '2').nil?)

# A loop that pushes onto the Array it started with: 0: ARRAY R1 0   1: JMPNOT R7 -> 4   2: ARYPUSH R1 1   3: JMP -> 1
loop = types.call([
  insn(0, 'ARRAY', "R1\t0"), insn(3, 'JMPNOT', "R7\t12"), insn(7, 'ARYPUSH', "R1\t1"), insn(9, 'JMP', '3'),
  insn(12, 'RETURN', 'R1')
])
check.call('a loop that ARYPUSHes onto an Array literal keeps the Array', klass.call(loop.exact_at(4, '1')) == :Array)

# OP_ARYCAT over a nil R(a) stores a fresh Array: the nil literal is not carried through it.
arycat = types.call([insn(0, 'LOADNIL', "R1\t(nil)"), insn(2, 'ARYCAT', "R1\t(R2)"), insn(4, 'RETURN', 'R1')])
check.call('ARYCAT over a nil literal has no exact class', arycat.exact_at(2, '1').nil?)
check.call('the nil literal itself is exact', klass.call(arycat.exact_at(1, '1')) == :NilClass)

# Entry values: the *rest slot is an Array, R0 is self only on the caller's proof, an argument is never exact.
entry = types.call([insn(4, 'LOADSELF', "R4\t(R0)"), insn(6, 'RETURN', 'R1')], enter: '1:0:1:0:0:0:0:0 (0x41000)')
check.call('the *rest slot is an Array', klass.call(entry.exact_at(2, '2')) == :Array)
check.call('a required argument has no exact class', entry.exact_at(2, '1').nil?)
check.call('R0 is self_class on the caller\'s proof', klass.call(entry.exact_at(2, '0', self_class: :Array)) == :Array)
check.call('R0 has no exact class without it', entry.exact_at(2, '0').nil?)
check.call('LOADSELF is self_class on the caller\'s proof', klass.call(entry.exact_at(2, '4', self_class: :Hash)) == :Hash)

# A pool integer is not an exact Integer literal (it can overflow a 32-bit mrb_int).
pool = BytecodeIR::Types.new(Irep.new(label: 't', instructions: [insn(0, 'LOADL', "R1\tL[0]"), insn(3, 'RETURN', 'R1')],
                                      catch_handlers: [], nlocals: 4, pool: [{ type: :int64, value: 1 << 40 }]))
check.call('LOADL of a pool integer has no exact class', pool.exact_at(1, '1').nil?)

suite.finish!
