# frozen_string_literal: true

require_relative '../../../tools/bc2cpp/irep'
require_relative '../../../tools/bc2cpp/bytecode_ir'

# RESCUE writes its second operand, which may differ from the register the
# writer index tracks. It must still stop a walk before skip_ops or a MOVE.
ops = [[:LOADI_1, 'R1 (1)'], [:NOP, ''], [:LOADI_2, 'R2 (2)'],
       [:RESCUE, 'R4 R2'], [:NOP, ''], [:MOVE, 'R1 R2'],
       [:RESCUE, 'R5 R3'], [:MOVE, 'R2 R3'], [:NOP, ''], [:RETURN, 'R1']]
list = ops.each_with_index.map do |(op, args), i|
  Insn.new(lineno: 1, addr: i, op: op, args: args, raw: "#{op} #{args}")
end
barrier = ->(insn, reg) { insn.op == :RESCUE && insn.regs[1] == reg }
cases = 0
[list, list.reject { |insn| insn.op == :RESCUE }].each do |instructions|
  body = Irep.new(label: 'writer-barriers', instructions: instructions, catch_handlers: [], nregs: 8, nlocals: 6)
  program = BytecodeIR::Program.new(body)
  (-1..list.size + 1).to_a.product([nil, 0, 1, 2, 3, 4, 5, 7], [nil, [:RESCUE], [:MOVE, :RESCUE]],
                                 [false, true], [nil, 0, 1, 2], [false, nil, :barrier], [false, true]).each do |from, reg, skips, moves, max, stopped, keep|
    results = [nil, :RESCUE].map do |hint|
      visits = []
      result = program.walk_writers(from, reg, skip_ops: skips, barrier: barrier, barrier_op: hint,
                                   barrier_result: stopped, follow_moves: moves, max_moves: max,
                                   exhausted: ->(last) { [:entry, last] }) do |insn, index, current|
        visits << [index, current]
        if insn.op == :MOVE
          BytecodeIR::Follow.new(insn.regs[1])
        elsif keep
          BytecodeIR::KEEP
        else
          [:writer, index, current]
        end
      end
      [result, visits]
    end
    raise "sparse barrier walk changed result or visits: #{[from, reg, skips, moves, max, stopped, keep].inspect}" unless results[0] == results[1]

    cases += 1
  end
end
body = Irep.new(label: 'writer-barriers', instructions: list, catch_handlers: [], nregs: 8, nlocals: 6)
program = BytecodeIR::Program.new(body)
stopped = program.walk_writers(5, 1, barrier: barrier, barrier_op: :RESCUE, barrier_result: :blocked,
                              follow_moves: true, skip_ops: [:RESCUE]) { :unexpected }
raise 'MOVE skipped a RESCUE write to its source register' unless stopped == :blocked
puts "writer barriers: #{cases} result and visit comparisons passed"
