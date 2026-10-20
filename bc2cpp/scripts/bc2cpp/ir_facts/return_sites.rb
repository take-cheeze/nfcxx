#!/usr/bin/env ruby
# frozen_string_literal: true

# RETURN_SITES (docs/adr/0503): the exits of a body, the bodies and exits nested in it, and the definitions a
# returned register comes from (BytecodeIR::Program#return_sources), on hand-built instruction lists. Host only.
#
# Usage: ruby scripts/bc2cpp/ir_facts_check.rb

require 'set'
require_relative '../../../tools/bc2cpp/irep'
require_relative '../../../tools/bc2cpp/bytecode_ir'
require_relative '../../../tools/bc2cpp/bytecode_ir_returns'

failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

def insn(addr, op, args)
  Insn.new(lineno: 1, addr: addr, op: op, args: args, raw: "#{op} #{args}")
end

def irep_of(list, handlers = [], label: "t#{list.hash}", reps: [])
  Irep.new(label: label, instructions: list, catch_handlers: handlers, reps: reps)
end

puts '-- exits'
mixed = irep_of([insn(0, 'JMPNOT', "R1\t6"), insn(4, 'RETURN', 'R2'), insn(6, 'JMPIF', "R3\t11"), insn(10, 'RETNIL', ''),
                 insn(11, 'RETSELF', '')])
exits = BytecodeIR.for(mixed).exits
check.call('every frame exit, in order, with its kind', exits.map(&:kind) == %i[value nil self] &&
                                                       exits.map(&:index) == [1, 3, 4])
check.call('RETURN hands back its register; RETNIL none', exits.first.reg == 2 && exits[1].reg.nil?)
check.call('exit? asks by kind', BytecodeIR.for(mixed).exit?(:value) && !BytecodeIR.for(mixed).exit?(:block_return))

puts '-- nested bodies'
grandchild = irep_of([insn(0, 'BREAK', 'R1')], label: 'g')
child = irep_of([insn(0, 'RETURN_BLK', 'R1'), insn(2, 'BLOCK', "R2\tI[0]")], label: 'c', reps: ['g'])
other = irep_of([insn(0, 'RETURN', 'R1')], label: 'o')
parent = irep_of([insn(0, 'BLOCK', "R2\tI[0]"), insn(3, 'BLOCK', "R3\tI[1]"), insn(6, 'RETURN', 'R1')], label: 'p',
                 reps: %w[c o])
tree = { 'p' => parent, 'c' => child, 'g' => grandchild, 'o' => other }
tree.each_value { |irep| irep.tree = tree }
check.call('nested bodies are depth first, each once', BytecodeIR.nested_bodies(parent).map(&:label) == %w[c g o])
check.call('a nested RETURN_BLK is found with its body',
           BytecodeIR.nested_exits(parent, :block_return).map { |body, e| [body.label, e.index] } == [['c', 0]])
check.call('a BREAK two levels down is a nested exit', BytecodeIR.nested_exit?(parent, :break) &&
                                                      !BytecodeIR.nested_exit?(child, :block_return))

puts '-- return_sources'
# `def f; TEST rescue false; end`: the no-match arm re-raises through RAISEIF, which falls through only on nil.
rescued = irep_of([
  insn(0, 'ENTER', '0:0:0:0:0:0:0:0 (0x0)'), insn(4, 'GETCONST', "R2\tTEST"), insn(7, 'JMP', '032'),
  insn(10, 'EXCEPT', 'R2'), insn(12, 'GETCONST', "R3\tNameError"), insn(15, 'RESCUE', "R2\tR3"),
  insn(18, 'JMPIF', "R3\t025"), insn(22, 'JMP', '030'), insn(25, 'LOADFALSE', "R2\t(false)"), insn(27, 'JMP', '032'),
  insn(30, 'RAISEIF', 'R2'), insn(32, 'RETURN', 'R2')
], [CatchHandler.new(type: :rescue, begin_addr: 4, end_addr: 7, target: 10)])
rescued.tree = { rescued.label => rescued }
check.call('`x rescue y`: the constant, the rescue value and the RAISEIF fall-through (nil)',
           BytecodeIR.return_sources(rescued, 11, '2')&.sort_by(&:to_s) == [[1, '2'], [8, '2'], :nil].sort_by(&:to_s))
check.call('without raiseif_nil the RAISEIF is a step over and the walk reaches the unmodelled RESCUE (negative)',
           BytecodeIR.reaching_definitions(rescued, 11, '2', through_handlers: true).nil?)

joined = irep_of([
  insn(0, 'JMPNOT', "R1\t7"), insn(3, 'LOADNIL', "R2\t(nil)"), insn(5, 'JMP', '9'), insn(7, 'LOADI_3', "R2\t(3)"),
  insn(9, 'MOVE', "R3\tR2"), insn(12, 'RETURN', 'R3')
])
check.call('a LOADNIL is a nil source; a MOVE is followed to its source',
           BytecodeIR.for(joined).return_sources(5, '3')&.sort_by(&:to_s) == [[3, '2'], :nil].sort_by(&:to_s))
check.call('an entry value refuses', BytecodeIR.for(joined).return_sources(0, '1').nil?)
check.call('a missing register refuses', BytecodeIR.for(joined).return_sources(5, nil).nil?)

puts '-- write_dominates? across an early return'
early = irep_of([
  insn(0, 'ARRAY', "R2\t0"), insn(3, 'JMPIF', "R1\t9"), insn(7, 'RETURN', 'R2'), insn(9, 'MOVE', "R3\tR2"),
  insn(12, 'RETURN', 'R3')
])
check.call('a RETURN of the register between the write and the read does not stop the dominance',
           BytecodeIR.write_dominates?(early, 0, 3, '2'))
check.call('a real write of the register between them still does (negative)',
           !BytecodeIR.write_dominates?(irep_of([insn(0, 'ARRAY', "R2\t0"), insn(3, 'LOADNIL', "R2\t(nil)"),
                                                 insn(5, 'MOVE', "R3\tR2"), insn(8, 'RETURN', 'R3')]), 0, 2, '2'))

if failures.empty?
  puts 'bc2cpp IR return sites check: PASS'
else
  warn "bc2cpp IR return sites check: #{failures.size} FAILED"
  exit 1
end
