# frozen_string_literal: true

require_relative '../../../tools/bc2cpp/irep'
require_relative '../../../tools/bc2cpp/bytecode_ir'

# Moves around a back edge revisit the same instruction with several registers.
ops = [[:LOADI_1, 'R1 (1)'], [:LOADI_2, 'R2 (2)'], [:LOADI_3, 'R3 (3)'],
       [:JMPNOT, 'R4 8'], [:MOVE, 'R1 R2'], [:MOVE, 'R2 R3'], [:MOVE, 'R3 R1'],
       [:JMP, '3'], [:RETURN, 'R1']]
list = ops.each_with_index.map { |(op, args), i| Insn.new(lineno: 1, addr: i, op: op, args: args, raw: "#{op} #{args}") }
handlers = [CatchHandler.new(type: :rescue, begin_addr: 4, end_addr: 7, target: 8)]
options = [{}, { follow_moves: false }, { origin_transfers: true }, { through_handlers: true },
           { through_handlers: true, origin_transfers: true }, { opaque_regs: Set[2].freeze },
           { opaque_regs: Set[2] }, { raiseif_nil: true }, { through_handlers: true, handler_ops: true },
           { through_handlers: true, handler_ops: true, raiseif_nil: true, origin_transfers: true }]
flag = 'BC2CPP_IR_SCALAR_SEEN'
saved = ENV[flag]
dense_flag = 'BC2CPP_IR_DENSE_SEEN'
saved_dense = ENV[dense_flag]
begin
  cases = 0
  [[], handlers].each do |catch_handlers|
    body = Irep.new(label: 'multi-register-loop', instructions: list, catch_handlers: catch_handlers, nregs: 6, nlocals: 5)
    [1, 2, 3, 8, 48].product(options).each do |budget, opts|
      results = %w[0 1].product(%w[0 1]).map do |mode, dense_mode|
        ENV[flag] = mode
        ENV[dense_flag] = dense_mode
        program = BytecodeIR::Program.new(body)
        (-1..list.size).flat_map do |index|
          %w[1 2 3 4].map do |register|
            refusal = {}
            found = program.reaching_definitions(index, register, **opts, max_states: budget, refusal: refusal)
            [found&.map { |d| [d.index, d.reg, d.built] }, refusal]
          end
        end
      end
      raise "dataflow answers or refusal order changed: #{[catch_handlers, budget, opts].inspect}" unless results.all? { |result| result == results.first }

      cases += results.first.size * (results.size - 1)
    end
  end
  ENV[flag] = '1'
  ENV[dense_flag] = '1'
  program = BytecodeIR::Program.new(Irep.new(label: 'loop', instructions: list, catch_handlers: [], nregs: 6, nlocals: 5))
  found = program.reaching_definitions(8, 1)
  raise 'loop lost a reaching register definition' unless found&.map { |d| [d.index, d.reg] } == [[0, 1], [1, 2], [2, 3]]
  found.first.reg = 99
  raise 'caller mutation changed cached definitions' unless program.reaching_definitions(8, 1).first.reg == 1

  # Reusing stamp 1 after the bounded counter wraps must not treat an old query's slots as visited.
  rollover = BytecodeIR::Program.new(Irep.new(label: 'rollover', instructions: list, catch_handlers: [], nregs: 6, nlocals: 5))
  expected = rollover.reaching_definitions(8, 1, refusal: {})
  rollover.instance_variable_set(:@reaching_scratch_seen_generation, BytecodeIR::DATAFLOW_SEEN_GENERATIONS - 1)
  raise 'stamp rollover retained a prior query' unless rollover.reaching_definitions(8, 1, refusal: {}) == expected

  # An opaque-membership callback can query the same Program while the outer scratch is in use.
  inner = nil
  opaque = Object.new
  opaque.define_singleton_method(:each) { |_block = nil| self }
  opaque.define_singleton_method(:include?) do |_register|
    inner ||= program.reaching_definitions(8, 2, refusal: {})
    false
  end
  nested = program.reaching_definitions(8, 1, opaque_regs: opaque, refusal: {})
  raise 'reentrant walk clobbered the outer scratch' unless nested == expected
  raise 'reentrant walk changed its own answer' unless inner == program.reaching_definitions(8, 2, refusal: {})
  puts "scalar/dense dataflow seen: #{cases} definition and refusal comparisons passed; rollover/reentry passed"
ensure
  saved ? ENV[flag] = saved : ENV.delete(flag)
  saved_dense ? ENV[dense_flag] = saved_dense : ENV.delete(dense_flag)
end

# A high exception register needs a heap-allocated bit mask. Before RAISEIF both
# normal and exceptional predecessors reach EXCEPT; after it, only the nil path does.
[4, 100].each do |exception_reg|
  ops = [[:LOADI_1, 'R1 (1)'], [:SEND0, 'R120 :work'], [:LOADI_2, 'R1 (2)'],
         [:EXCEPT, "R#{exception_reg}"], [:RAISEIF, "R#{exception_reg}"], [:RETURN, 'R1']]
  list = ops.each_with_index.map do |(op, args), i|
    Insn.new(lineno: 1, addr: i, op: op, args: args, raw: "#{op} #{args}")
  end
  body = Irep.new(label: 'except-nil-path', instructions: list, nregs: 122, nlocals: 2,
                  catch_handlers: [CatchHandler.new(type: :rescue, begin_addr: 1, end_addr: 2, target: 3)])
  program = BytecodeIR::Program.new(body)
  [[4, [[0, 1], [2, 1]]], [5, [[2, 1]]]].each do |index, expected|
    found = program.reaching_definitions(index, 1, through_handlers: true, handler_ops: true)
    raise "EXCEPT nil path changed for R#{exception_reg} at #{index}" unless found&.map { |d| [d.index, d.reg] } == expected
  end
end
puts 'EXCEPT nil paths: low and high exception registers passed'
