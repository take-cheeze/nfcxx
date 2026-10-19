#!/usr/bin/env ruby
# frozen_string_literal: true

# IR container shapes (docs/bc2cpp-ir-containers.md, ADR 0493) on hand-built instruction lists: the container literal
# an instruction builds, the producers of a register through a join, the literal value classes, the straight-line
# window SEALED_HASH_IVAR walks, and the element join the layouts take over every producer.
#
# Usage: ruby scripts/bc2cpp/ir_container_shapes_check.rb

require 'set'
TOOLS = ENV['BC2CPP_TOOLS_DIR'] || File.expand_path('../../tools/bc2cpp', __dir__)
$LOAD_PATH.unshift(TOOLS)
require 'irep'
require 'bytecode_ir_containers'
require 'element_layouts'

failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

def insn(addr, op, args)
  Insn.new(lineno: 1, addr: addr, op: op, args: args, raw: "#{op} #{args}")
end

def irep_of(list, pool: [], reps: [])
  Irep.new(label: "t#{list.hash}", instructions: list, catch_handlers: [], pool: pool, reps: reps, nlocals: 2)
end

puts '-- container_literal'
literals = irep_of([insn(0, 'ARRAY', "R3\t2"), insn(3, 'ARRAY', "R3\tR5\t2"), insn(7, 'HASH', "R2\t2"),
                    insn(10, 'HASH', "R2\t0"), insn(13, 'RETURN', 'R2')])
program = BytecodeIR.for(literals)
array = program.container_literal(0)
check.call('ARRAY R3 2 reads R3, R4', array.kind == :array && array.value_regs == %w[3 4] && array.key_regs.empty?)
array2 = program.container_literal(1)
check.call('the two-register ARRAY (ARRAY2) reads from its source register', array2.value_regs == %w[5 6])
hash = program.container_literal(2)
check.call('HASH R2 2 has keys R2, R4 and values R3, R5', hash.key_regs == %w[2 4] && hash.value_regs == %w[3 5])
check.call('an empty HASH is empty', program.container_literal(3).empty?)
check.call('a RETURN builds no container', program.container_literal(4).nil?)

puts '-- producers through a join'
# R3 = c ? [] : [x]; @a = R3
joined = irep_of([insn(0, 'JMPNOT', "R1\t9"), insn(4, 'ARRAY', "R3\t0"), insn(7, 'JMP', '15'),
                  insn(9, 'LOADI_1', "R3\t(1)"), insn(11, 'ARRAY', "R3\t1"), insn(15, 'SETIV', "@a\tR3"),
                  insn(18, 'RETURN', 'R3')])
sources = BytecodeIR.producers(joined, 5, '3')
check.call('both arms of the join produce the stored value', sources&.map(&:index) == [1, 4])
check.call('a producer carries its instruction', sources&.map(&:op) == %w[ARRAY ARRAY])
check.call('the element join skips the empty arm and takes the other one',
           join_element_producers(joined, 5, '3') { |p| p.index == 1 ? ArrayElementLayout::VACUOUS : 'Game::Actor' } ==
             'Game::Actor')
check.call('the element join refuses when the arms disagree',
           join_element_producers(joined, 5, '3') { |p| p.index == 1 ? 'A' : 'B' }.nil?)
check.call('the element join refuses when one arm is unknown',
           join_element_producers(joined, 5, '3') { |p| p.index == 1 ? 'A' : nil }.nil?)
check.call('an argument read is the entry producer',
           BytecodeIR.producers(joined, 0, '1')&.map(&:entry?) == [true])

puts '-- literal classes'
classes = irep_of([insn(0, 'LOADI_5', "R2\t(5)"), insn(1, 'STRING', "R3\tL[0]"), insn(3, 'LOADNIL', "R4\t(nil)"),
                   insn(5, 'LOADL', "R5\tL[1]"), insn(7, 'LOADSYM', "R6\t:k"), insn(9, 'GETIV', "R7\t@x"),
                   insn(12, 'RETURN', 'R2')],
                  pool: ['s', { type: :float, value: 1.5 }])
check.call('LOADI is Integer, STRING String, LOADNIL NilClass',
           [0, 1, 2].map { |i| BytecodeIR.literal_class(classes, i) } == %w[Integer String NilClass])
check.call('a float pool entry is Float', BytecodeIR.literal_class(classes, 3) == 'Float')
check.call('LOADSYM is Symbol and GETIV is not a literal',
           BytecodeIR.literal_class(classes, 4) == 'Symbol' && BytecodeIR.literal_class(classes, 5).nil?)

puts '-- straight_line'
seen = []
program = BytecodeIR.for(joined)
program.straight_line(1, 16) { |_insn, k| seen << k }
check.call('the window stops before a jump target', seen == [1, 2])
seen = []
program.straight_line(4, 1) { |_insn, k| seen << k }
check.call('the window stops at its size', seen == [4])

puts '-- quiet_span?'
# a = []; a << 1; @v = a  -- the send between the literal and the store may add an element.
mutated = irep_of([insn(0, 'ARRAY', "R2\t0"), insn(3, 'MOVE', "R3\tR2"), insn(6, 'LOADI_1', "R4\t(1)"),
                   insn(8, 'SEND', "R3\t:<<\tn=1"), insn(12, 'SETIV', "@v\tR2"), insn(15, 'RETURN', 'R2')])
check.call('a send between the literal and its read is not quiet', !BytecodeIR.for(mutated).quiet_span?(0, 4))
check.call('loads between the literal and its read are quiet', BytecodeIR.for(mutated).quiet_span?(0, 3))
# (@v || {}).each_value { ... }  -- the join after the literal stays inside the span.
defaulted = irep_of([insn(0, 'GETIV', "R2\t@v"), insn(3, 'JMPIF', "R2\t9"), insn(7, 'HASH', "R2\t0"),
                     insn(9, 'BLOCK', "R3\tI[0]"), insn(12, 'SENDB', "R2\t:each_value\tn=0"),
                     insn(16, 'RETURN', 'R2')], reps: ['child'])
check.call('`(@v || {})`: the literal reaches the call through quiet code', BytecodeIR.for(defaulted).quiet_span?(2, 4))
check.call('a read before the literal is not a span', !BytecodeIR.for(defaulted).quiet_span?(2, 1))

puts '-- adjacent_block_index'
blocks = irep_of([insn(0, 'BLOCK', "R3\tI[0]"), insn(3, 'SENDB', "R2\t:map\tn=0"), insn(7, 'RETURN', 'R2')],
                 reps: ['child'])
check.call('the BLOCK writing the block slot of the call is found',
           BytecodeIR.for(blocks).adjacent_block_index(1, '2') == 0)
check.call('a BLOCK writing another register is not', BytecodeIR.for(blocks).adjacent_block_index(1, '1').nil?)

if failures.empty?
  puts 'ir_container_shapes_check: ok'
else
  puts "ir_container_shapes_check: #{failures.size} FAIL"
  exit 1
end
