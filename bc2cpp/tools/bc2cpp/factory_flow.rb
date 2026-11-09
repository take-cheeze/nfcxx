# frozen_string_literal: true

require_relative 'ir_symbol_flow'

# Uses of a factory constant, including MOVE aliases, over normal and handler edges.
module FactoryFlow
  module_function

  # Collected as [use index, register] pairs, one per join arm; the register is
  # the alias name at that use. Nil when the answer is not provable (a refusal,
  # a use the walk cannot list) or the alias budget is exceeded.
  def uses(irep, index, reg, max_aliases: BytecodeIR::DATAFLOW_MAX_STATES)
    uses = Set.new
    walked = IrSymbolFlow.follow_forward_uses(irep, index, reg, max_states: max_aliases) do |use, _insn, register|
      uses << [use, register]
      nil
    end
    return nil if walked.nil?

    uses
  end
end
