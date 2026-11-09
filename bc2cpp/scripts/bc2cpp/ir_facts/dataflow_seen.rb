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
           { opaque_regs: Set[2] }, { raiseif_nil: true }]
flag = 'BC2CPP_IR_SCALAR_SEEN'
saved = ENV[flag]
begin
  cases = 0
  [[], handlers].each do |catch_handlers|
    body = Irep.new(label: 'multi-register-loop', instructions: list, catch_handlers: catch_handlers, nregs: 6, nlocals: 5)
    [1, 2, 3, 8, 48].product(options).each do |budget, opts|
      results = %w[0 1].map do |mode|
        ENV[flag] = mode
        program = BytecodeIR::Program.new(body)
        (-1..list.size).flat_map do |index|
          %w[1 2 3 4].map do |register|
            refusal = {}
            found = program.reaching_definitions(index, register, **opts, max_states: budget, refusal: refusal)
            [found&.map { |d| [d.index, d.reg, d.built] }, refusal]
          end
        end
      end
      raise "dataflow answers or refusal order changed: #{[catch_handlers, budget, opts].inspect}" unless results[0] == results[1]

      cases += results.first.size
    end
  end
  ENV[flag] = '1'
  program = BytecodeIR::Program.new(Irep.new(label: 'loop', instructions: list, catch_handlers: [], nregs: 6, nlocals: 5))
  found = program.reaching_definitions(8, 1)
  raise 'loop lost a reaching register definition' unless found&.map { |d| [d.index, d.reg] } == [[0, 1], [1, 2], [2, 3]]
  found.first.reg = 99
  raise 'caller mutation changed cached definitions' unless program.reaching_definitions(8, 1).first.reg == 1
  puts "scalar dataflow seen: #{cases} definition and refusal comparisons passed"
ensure
  saved ? ENV[flag] = saved : ENV.delete(flag)
end
