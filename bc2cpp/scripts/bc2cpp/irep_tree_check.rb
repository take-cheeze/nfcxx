#!/usr/bin/env ruby
# frozen_string_literal: true

# BytecodeIR::Tree (tools/bc2cpp/bytecode_ir_tree.rb) answers the closure-tree questions escape analysis asks, with
# the answers the raw `irep.reps` formulation gave: which children a closure op names, which of them resolve, and
# the depth-first order and [owner, index] chains of a subtree walk. Hand-built ireps, host only (no mrbc).
#
# Usage: ruby scripts/bc2cpp/irep_tree_check.rb

require 'set'
require_relative '../../tools/bc2cpp/irep'
require_relative '../../tools/bc2cpp/bytecode_ir_tree'

failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

def insn(addr, op, args)
  Insn.new(lineno: 1, addr: addr, op: op, args: args, raw: "#{op} #{args}")
end

def irep(label, instructions, reps = [])
  Irep.new(label: label, instructions: instructions, reps: reps, nlocals: 2, nregs: 4, catch_handlers: [])
end

CLOSURES = Set[:BLOCK, :LAMBDA].freeze

# root --BLOCK 0--> a --LAMBDA 0--> b ; root --LAMBDA 1--> "missing" (no Irep) ; a --BLOCK 1--> nothing (dangling)
leaf = irep('b', [insn(0, :GETUPVAR, "R1\t0\t1"), insn(4, :RETURN, 'R1')])
mid = irep('a', [insn(0, :LAMBDA, "R2\tI[0]"), insn(4, :BLKPUSH, "R3\t1\t0"), insn(8, :BLOCK, "R2\tI[1]"),
                 insn(12, :RETURN, 'R2')], ['b', 'nowhere'])
root = irep('root', [insn(0, :BLOCK, "R2\tI[0]"), insn(4, :LAMBDA, "R3\tI[1]"), insn(8, :SEND, "R2\t0\t0"),
                     insn(12, :RETURN, 'R2')], ['a', 'missing'])
ireps = { 'root' => root, 'a' => mid, 'b' => leaf }

puts '-- child resolution'
check.call('child_labels keeps every closure site, in program order, and labels that name no irep kept as named',
           BytecodeIR::Tree.child_labels(root, CLOSURES) == [[0, 'a'], [1, 'missing']])
check.call('children drops the labels that are not in the ireps table',
           BytecodeIR::Tree.children(root, ireps, CLOSURES).map { |i, c| [i, c.label] } == [[0, 'a']])
check.call('the ops asked for are the only sites (BLOCK alone skips the LAMBDA site)',
           BytecodeIR::Tree.child_labels(root, Set[:BLOCK]) == [[0, 'a']])
check.call('an irep without closure ops has no children',
           BytecodeIR::Tree.children(leaf, ireps, CLOSURES) == [])

puts '-- subtree walk'
visited = []
BytecodeIR::Tree.each_subtree(root, ireps, CLOSURES) { |node, depth, chain| visited << [node.label, depth, chain.map { |o, i| [o.label, i] }] }
check.call('each_subtree visits the irep, then its nested ireps depth-first',
           visited.map(&:first) == %w[root a b])
check.call('each_subtree reports depth and the [owner, index] chain to each irep',
           visited == [['root', 0, []], ['a', 1, [['root', 0]]], ['b', 2, [['root', 0], ['a', 0]]]])

from_child = []
BytecodeIR::Tree.each_subtree(mid, ireps, CLOSURES, 0, [[root, 0]]) { |node, depth, chain| from_child << [node.label, depth, chain.size] }
check.call('a walk started at a child carries the chain it was given and extends it',
           from_child == [['a', 0, 1], ['b', 1, 2]])

puts '-- equivalence with the raw reps formulation'
raw_children = lambda do |irep|
  irep.instructions.each_with_index.filter_map do |i, j|
    next unless CLOSURES.include?(i.op)

    child = ireps[irep.reps[i.block_index.to_i]]
    [j, child] if child
  end
end
check.call('children agrees with the raw reps lookup on every irep',
           ireps.values.all? { |r| BytecodeIR::Tree.children(r, ireps, CLOSURES).map { |i, c| [i, c.label] } ==
                                  raw_children.call(r).map { |i, c| [i, c.label] } })

puts
if failures.empty?
  puts 'bc2cpp irep tree check: PASS'
else
  warn "bc2cpp irep tree check: #{failures.size} failure(s)"
  exit 1
end
