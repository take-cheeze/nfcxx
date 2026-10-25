#!/usr/bin/env ruby
# frozen_string_literal: true

# EXACT_LITERAL: BytecodeIR::Types#exact_at, the exact-class proof of the exact-receiver, `===`, `times`
# and literal-block sites, on hand-built bytecode. Every reaching definition must be a literal (or the `*rest` slot)
# of one class; a container op keeps the class only of the container it extends.
#
#   ruby scripts/bc2cpp/ir_facts_check.rb
require_relative '../../../tools/bc2cpp/irep'
require_relative '../../../tools/bc2cpp/bytecode_ir'
require_relative '../../../tools/bc2cpp/codegen_exact_receiver'
require_relative '../../../tools/bc2cpp/codegen_step_loop'

require_relative '../check_support'
require_relative '../ir_instruction_fixtures'
extend IrInstructionFixtures
suite = FixtureCheck.new('ir_exact_types_check')
check = suite.method(:check)
types = lambda do |list, enter: nil|
  list = [insn(0, :ENTER, enter)] + list if enter
  BytecodeIR::Types.new(Irep.new(label: 't', instructions: list, catch_handlers: [], nlocals: 8))
end
klass = ->(fact) { fact&.klass }

# 0: ARRAY R1 0   1: ARYPUSH R1 1   2: STRING R3 L[0]   3: STRCAT R3 (R4)   4: LOADINEG R5 -5   5: RETURN R1
straight = types.call([
  insn(0, :ARRAY, "R1\t0"), insn(3, :ARYPUSH, "R1\t1"), insn(6, :STRING, "R3\tL[0]"), insn(9, :STRCAT, "R3\t(R4)"),
  insn(11, :LOADINEG, "R5\t-5"), insn(14, :RETURN, 'R1')
])
check.call('ARYPUSH keeps the Array literal it extends', klass.call(straight.exact_at(5, '1')) == :Array)
check.call('STRCAT keeps the String literal it extends', klass.call(straight.exact_at(5, '3')) == :String)
check.call('LOADINEG is an Integer with its negative value', straight.exact_at(5, '5').to_a == [:Integer, -5])
check.call('an unwritten temporary has no exact class', straight.exact_at(5, '6').nil?)

%i[SYMBOL INTERN].each do |op|
  symbol = types.call([insn(0, op, op == :SYMBOL ? "R1\tL[0]" : 'R1'), insn(3, :RETURN, 'R1')])
  check.call("#{op} has a Symbol result type", symbol.at(1, '1') == Set[:Symbol])
  check.call("#{op} has an exact Symbol result class", klass.call(symbol.exact_at(1, '1')) == :Symbol)
end
presence = types.call([insn(0, :KEY_P, "R1\t:option"), insn(3, :RETURN, 'R1')])
check.call('keyword presence has both boolean classes', presence.at(1, '1') == Set[:TrueClass, :FalseClass])
check.call('keyword presence does not claim one exact boolean class', presence.exact_at(1, '1').nil?)

# A join of two literals on each register: R1 is 3 on both arms, R2 an Array on one and a Hash on the other.
join = types.call([
  insn(0, :JMPNOT, "R7\t12"), insn(4, :LOADI_3, "R1\t(3)"), insn(6, :ARRAY, "R2\t0"), insn(9, :JMP, '16'),
  insn(12, :LOADI_3, "R1\t(3)"), insn(14, :HASH, "R2\t0"), insn(16, :RETURN, 'R1')
])
check.call('a join of the same Integer literal keeps its value', join.exact_at(6, '1').to_a == [:Integer, 3])
check.call('a join of an Array and a Hash literal has no exact class', join.exact_at(6, '2').nil?)

# A loop that pushes onto the Array it started with: 0: ARRAY R1 0   1: JMPNOT R7 -> 4   2: ARYPUSH R1 1   3: JMP -> 1
loop = types.call([
  insn(0, :ARRAY, "R1\t0"), insn(3, :JMPNOT, "R7\t12"), insn(7, :ARYPUSH, "R1\t1"), insn(9, :JMP, '3'),
  insn(12, :RETURN, 'R1')
])
check.call('a loop that ARYPUSHes onto an Array literal keeps the Array', klass.call(loop.exact_at(4, '1')) == :Array)

# OP_ARYCAT over a nil R(a) stores a fresh Array: the nil literal is not carried through it.
arycat = types.call([insn(0, :LOADNIL, "R1\t(nil)"), insn(2, :ARYCAT, "R1\t(R2)"), insn(4, :RETURN, 'R1')])
check.call('ARYCAT over a nil literal has no exact class', arycat.exact_at(2, '1').nil?)
check.call('the nil literal itself is exact', klass.call(arycat.exact_at(1, '1')) == :NilClass)

# Entry values: the *rest slot is an Array, R0 is self only on the caller's proof, an argument is never exact.
entry = types.call([insn(4, :LOADSELF, "R4\t(R0)"), insn(6, :RETURN, 'R1')], enter: '1:0:1:0:0:0:0:0 (0x41000)')
check.call('the *rest slot is an Array', klass.call(entry.exact_at(2, '2')) == :Array)
check.call('a required argument has no exact class', entry.exact_at(2, '1').nil?)
check.call('R0 is self_class on the caller\'s proof', klass.call(entry.exact_at(2, '0', self_class: :Array)) == :Array)
check.call('R0 has no exact class without it', entry.exact_at(2, '0').nil?)
check.call('LOADSELF is self_class on the caller\'s proof', klass.call(entry.exact_at(2, '4', self_class: :Hash)) == :Hash)

# A pool integer is not an exact Integer literal (it can overflow a 32-bit mrb_int).
pool = BytecodeIR::Types.new(Irep.new(label: 't', instructions: [insn(0, :LOADL, "R1\tL[0]"), insn(3, :RETURN, 'R1')],
                                      catch_handlers: [], nlocals: 4, pool: [{ type: :int64, value: 1 << 40 }]))
check.call('LOADL of a pool integer has no exact class', pool.exact_at(1, '1').nil?)

# The refusal names the first definition the proof cannot use; a cached answer reports the same cause.
cause = lambda do |analysis, index, reg, **options|
  refusal = {}
  analysis.exact_at(index, reg, refusal: refusal, **options)
  refusal[:cause]
end
check.call('a join of two classes refuses as class_join', cause.call(join, 6, '2') == :class_join)
check.call('a pool integer refuses on its producer', cause.call(pool, 1, '1') == 'producer:LOADL')
check.call('a cached refusal reports its cause again', cause.call(pool, 1, '1') == 'producer:LOADL')
check.call('R0 without the caller\'s proof refuses as self_unknown', cause.call(entry, 2, '0') == :self_unknown)
check.call('LOADSELF without the caller\'s proof refuses as self_unknown', cause.call(entry, 2, '4') == :self_unknown)
check.call('an answered proof records no cause', cause.call(straight, 5, '1').nil?)

# The step-loop consumer requires one literal value, not merely Integer class agreement.
generator = CodeGen.allocate
step_body = lambda do |rows, handlers = []|
  Irep.new(label: 'step', instructions: rows.each_with_index.map { |(op, args), i| insn(i, op, args) },
           catch_handlers: handlers, nlocals: 1, nregs: 8, reps: [], pool: [])
end
step_value = lambda do |body|
  generator.step_loop_literal(body, body.instructions.size - 2, '2')
end
moved = step_body.call([[:LOADI_2, 'R5 (2)'], [:MOVE, 'R3 R5'], [:MOVE, 'R2 R3'], [:RETURN, 'R2']])
check.call('step literal follows MOVE chains', step_value.call(moved) == 2)
joined = [[:JMPNOT, 'R1 3'], [:LOADI_2, 'R2 (2)'], [:JMP, '4'], [:LOADI_2, 'R2 (2)'], [:RETURN, 'R2']]
check.call('step literal accepts equal values across a join', step_value.call(step_body.call(joined)) == 2)
different = joined.map(&:dup)
different[3] = [:LOADI_3, 'R2 (3)']
check.call('step literal refuses different Integer values across a join', step_value.call(step_body.call(different)).nil?)
different[3] = [:LOADNIL, 'R2 (nil)']
check.call('step literal refuses a non-Integer arm', step_value.call(step_body.call(different)).nil?)
loop_rows = [[:LOADI_2, 'R2 (2)'], [:JMPNOT, 'R1 4'], [:NOP, ''], [:JMP, '1'], [:RETURN, 'R2']]
check.call('step literal survives a preserving loop', step_value.call(step_body.call(loop_rows)) == 2)
loop_rows[2] = [:LOADI_3, 'R2 (3)']
check.call('step literal refuses a loop that changes its value', step_value.call(step_body.call(loop_rows)).nil?)
check.call('step literal refuses an entry value', step_value.call(step_body.call([[:NOP, ''], [:RETURN, 'R2']])).nil?)
handler = CatchHandler.new(type: :rescue, begin_addr: 1, end_addr: 3, target: 4)
rescued = [[:LOADI_2, 'R2 (2)'], [:NOP, ''], [:NOP, ''], [:JMP, '4'], [:RETURN, 'R2']]
check.call('step literal follows handler paths that preserve its value', step_value.call(step_body.call(rescued, [handler])) == 2)
rescued[2] = [:LOADI_3, 'R2 (3)']
check.call('step literal refuses different values on handler paths', step_value.call(step_body.call(rescued, [handler])).nil?)
limit = CodeGen::STEP_LOOP_LITERAL_MAX
[0, limit, -limit, limit + 1, -limit - 1].each do |value|
  expected = value.abs <= limit ? value : nil
  body = step_body.call([[:LOADI32, "R2 #{value}"], [:RETURN, 'R2']])
  check.call("step literal keeps the cross-target fixnum boundary #{value}", step_value.call(body) == expected)
end
large = step_body.call([[:LOADL, 'R2 L[0]'], [:RETURN, 'R2']])
large.pool = [{ type: :int64, raw: '.i64=1099511627776' }]
check.call('step literal refuses pool integers', step_value.call(large).nil?)

suite.finish!
