# frozen_string_literal: true

require_relative 'bytecode_ir'

module BytecodeIR
  # A yielding helper keeps its registers in the caller's persistent frame.
  # Reject unresolved control flow before assigning any resume states.
  class ResumableRegion
    RETURNS = %w[RETURN RETSELF RETNIL RETTRUE RETFALSE].freeze
    attr_reader :program

    def self.build(irep)
      return nil unless Array(irep.catch_handlers).empty? && Array(irep.reps).empty?
      return nil unless irep.enter.nil? || irep.enter.enter_fields.all?(&:zero?)

      program = BytecodeIR.for(irep)
      return nil unless program.resolved? && program.instructions.any?
      return nil unless RETURNS.include?(program.instructions.last.op)
      return nil if program.instructions.any? { |node| %w[JMPUW BREAK RETURN_BLK STOP].include?(node.op) }
      return nil if program.instructions.drop(1).any? { |node| node.op == 'ENTER' }
      return nil if program.branch_edges.any? { |edge| program.insn_at_addr(edge.target)&.op == 'ENTER' }

      new(program)
    end

    def initialize(program)
      @program = program
    end
  end
end
