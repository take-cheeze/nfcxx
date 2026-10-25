#!/usr/bin/env ruby
# frozen_string_literal: true

# GAME_VARIABLES_RECEIVER: CodeGen#game_variables_index_receiver? answers from every value that reaches the index
# read (BytecodeIR.reaching_definitions), not from the textually nearest LOADSELF. A `r = @data; r = self if c; r[0]`
# join must refuse: the @data path is not self, and the proof grants the game-variable range to the element.
# Host only (no mrbc): hand-built instruction lists through the real CodeGen method.
#
# Usage: ruby scripts/bc2cpp/game_variables_receiver_check.rb

require_relative '../../tools/bc2cpp/bc2cpp'

failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

def insn(addr, op, args)
  Insn.new(lineno: 1, addr: addr, op: op, args: args, raw: "#{op} #{args}")
end

def irep_of(list)
  Irep.new(label: "gv#{list.hash}", nregs: 10, instructions: list, catch_handlers: [], reps: [], pool: [])
end

# No static class for the receiver: the answer must come from the reaching writers alone.
gen = CodeGen.allocate
gen.define_singleton_method(:static_indexable_class) { |*| nil }
owner = Struct.new(:owner).new('Game::Variables')

puts '-- join of an ivar and self (host)'
joined = irep_of([insn(0, :GETIV, "R2\t@data"), insn(1, :JMPNOT, "R1\t3"), insn(2, :LOADSELF, "R2\t(R2)"),
                  insn(3, :GETIDX, "R3\t(R2)")])
check.call('a receiver that is @data on one path is not a game-variables receiver',
           gen.game_variables_index_receiver(joined, 3, 2, owner) == false)

puts '-- straight-line self (host)'
straight = irep_of([insn(0, :LOADSELF, "R2\t(R2)"), insn(1, :GETIDX, "R3\t(R2)")])
check.call('a straight-line self receiver is a game-variables receiver',
           gen.game_variables_index_receiver?(straight, 1, '2', owner) == true)

puts '-- join of self with self (host)'
both_self = irep_of([insn(0, :LOADSELF, "R2\t(R2)"), insn(1, :JMPNOT, "R1\t3"), insn(2, :LOADSELF, "R2\t(R2)"),
                     insn(3, :GETIDX, "R3\t(R2)")])
check.call('self on every path stays a game-variables receiver',
           gen.game_variables_index_receiver?(both_self, 3, '2', owner) == true)

puts '-- no writer in the body (host)'
entry = irep_of([insn(0, :GETIDX, "R3\t(R2)")])
check.call('a receiver from the frame entry is not proven', gen.game_variables_index_receiver?(entry, 0, '2', owner) == false)

if failures.empty?
  puts 'game_variables_receiver_check: all checks passed'
else
  puts "game_variables_receiver_check: #{failures.size} failure(s)"
  exit 1
end
