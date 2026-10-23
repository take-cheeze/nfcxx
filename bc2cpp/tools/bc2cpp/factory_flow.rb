# frozen_string_literal: true

require_relative 'ir_symbol_flow'

# Uses of a factory constant, including MOVE aliases, over normal and handler edges.
module FactoryFlow
  module_function

  def uses(irep, index, reg, max_aliases: BytecodeIR::DATAFLOW_MAX_STATES)
    program = BytecodeIR.for(irep)
    work = [[index, reg]]
    seen = Set.new
    uses = Set.new
    until work.empty?
      origin, register = work.pop
      next unless seen.add?([origin, register])
      return nil if seen.size > max_aliases

      reads = IrSymbolFlow.value_reads(irep, origin, register) or return nil
      reads.each do |use|
        instruction = program.source_at(use)
        if instruction.op == 'MOVE'
          work << [use, instruction.reg]
        else
          uses << [use, register]
        end
      end
    end
    uses
  end
end
