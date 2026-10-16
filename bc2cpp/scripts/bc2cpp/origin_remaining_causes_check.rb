#!/usr/bin/env ruby
# frozen_string_literal: true

# Two refusal causes of the origin walk that were still sound to resolve (see docs/bc2cpp-dynamic-site-census.md):
# a predecessor no execution reaches (no_predecessor) and a register a nested block may write (opaque_reg).
# Each resolution is origin-only (origin_transfers: true); the default walk must still refuse at both.
# Hand-built shapes with fixed answers; codegen never passes origin_transfers.
require 'set'
require_relative '../../tools/bc2cpp/irep'
require_relative '../../tools/bc2cpp/bytecode_ir'

def insn(addr, op, args)
  Insn.new(lineno: 1, addr: addr, op: op, args: args, raw: "#{op} #{args}")
end

failures = []
check = ->(label, ok) { failures << label unless ok }
program = ->(list, handlers = []) { BytecodeIR::Program.new(Irep.new(label: 't', instructions: list, catch_handlers: handlers)) }
defs_of = lambda do |prog, index, reg, **opts|
  found = prog.reaching_definitions(index, reg, **opts)
  found && found.map { |d| d.entry? ? :entry : d.index }
end

# no_predecessor: a jump no execution reaches (after an unconditional JMP, with no jump to it) is a predecessor of
# the join at index 4. The live path through index 1 supplies the only value, so the origin walk answers it. A dead
# query has no value to report and stays refused.
#   0: LOADI_1 R1   1: JMP -> 8   2: JMP -> 8 (dead)   3: LOADI_2 R1 (dead)   4: RETURN R1 (@8, the join)
dead_join = program.call([
  insn(0, 'LOADI_1', 'R1 (1)'), insn(2, 'JMP', '8'), insn(4, 'JMP', '8'), insn(6, 'LOADI_2', 'R1 (2)'),
  insn(8, 'RETURN', 'R1')
])
check.call('a dead predecessor of a live join is skipped (origin walk answers the live definition)',
           defs_of.call(dead_join, 4, '1', origin_transfers: true) == [0])
check.call('the default walk skips the dead predecessor too (ADR 0476)', defs_of.call(dead_join, 4, '1') == [0])
# A dead query keeps its dead predecessors: skipping them would answer [] (no definition), vacuously true.
#   0: LOADI_1 R1   1: RETURN R1   2: LOADI_2 R1 (dead)   3: RETURN R1 (dead, the query)
dead_tail = program.call([insn(0, 'LOADI_1', 'R1 (1)'), insn(2, 'RETURN', 'R1'), insn(4, 'LOADI_2', 'R1 (2)'),
                          insn(6, 'RETURN', 'R1')])
check.call('a dead query keeps its dead predecessors under the default walk (never an empty answer)',
           defs_of.call(dead_tail, 3, '1') == [2])
check.call('a query no execution reaches stays refused (no value to report)',
           dead_join.reaching_definitions(3, '1', origin_transfers: true).nil?)

# A node a handler reaches is live: the handler target (index 3, guarded) enters index 4 by normal flow, and the
# query's only predecessor is index 4. Skipping index 4 as dead would answer [] (no definition), so the test
# requires the refusal at the handler target instead.
#   0: LOADI_1 R1   1: SEND0 R2 (protected [2,4))   2: RETURN R1   3: LOADI_2 R1 (handler @6)   4: JMP -> 12
#   5: RETURN R1 (@12, the query)
handler_reach = program.call([
  insn(0, 'LOADI_1', 'R1 (1)'), insn(2, 'SEND0', "R2\t:f"), insn(4, 'RETURN', 'R1'), insn(6, 'LOADI_2', 'R1 (2)'),
  insn(8, 'JMP', '12'), insn(12, 'RETURN', 'R1')
], [CatchHandler.new(type: :rescue, begin_addr: 2, end_addr: 4, target: 6)])
refusal = {}
check.call('a node a handler reaches is not skipped as dead (the walk refuses at the handler target)',
           handler_reach.reaching_definitions(5, '1', origin_transfers: true, refusal: refusal).nil? &&
             refusal[:cause] == :query_guarded)

# opaque_reg: R1 is written by a nested block (opaque_regs). A closure-creating op placed after the query cannot have
# run before it, so the nested write cannot supply the value.
#   0: LOADI_1 R1   1: SEND0 R2   2: BLOCK R3 (closure created after the query)   3: RETURN R1
opaque_after = program.call([
  insn(0, 'LOADI_1', 'R1 (1)'), insn(2, 'SEND0', "R2\t:f"), insn(4, 'BLOCK', "R3\t1"), insn(6, 'RETURN', 'R1')
])
check.call('an opaque register is answered when no closure can exist before the query',
           defs_of.call(opaque_after, 1, '1', origin_transfers: true, opaque_regs: Set['1']) == [0])
check.call('without the origin option the opaque register is still refused',
           opaque_after.reaching_definitions(1, '1', opaque_regs: Set['1']).nil?)

# A block created before the query can run during a call between the definition and the use: refused.
#   0: LOADI_1 R1   1: BLOCK R3   2: SEND0 R2   3: RETURN R1
opaque_before = program.call([
  insn(0, 'LOADI_1', 'R1 (1)'), insn(2, 'BLOCK', "R3\t1"), insn(4, 'SEND0', "R2\t:f"), insn(6, 'RETURN', 'R1')
])
refusal = {}
check.call('an opaque register stays refused when a closure can run before the query',
           opaque_before.reaching_definitions(3, '1', origin_transfers: true, opaque_regs: Set['1'],
                                                      refusal: refusal).nil? && refusal[:cause] == :opaque_reg)

abort("bc2cpp_origin_remaining_causes_check FAILED: #{failures.join(', ')}") unless failures.empty?
puts 'bc2cpp_origin_remaining_causes_check OK'
