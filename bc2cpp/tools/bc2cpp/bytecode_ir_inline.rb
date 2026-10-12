# frozen_string_literal: true

require 'set'
require_relative 'bytecode_ir'
require_relative 'irep_arity'

module BytecodeIR
  # Separate register namespaces and symbolic exits avoid modifying the loaded IREP.
  class MethodInlineRegion
    OPS = Set.new(%w[ENTER NOP MOVE LOADL LOADSYM LOADNIL LOADSELF LOADTRUE LOADFALSE
                     GETIV SETIV GETCONST GETMCNST GETIDX GETIDX0 SETIDX
                     SSEND SSEND0 SEND SEND0 JMP JMPIF JMPNOT JMPNIL
                     RETURN RETSELF RETNIL RETTRUE RETFALSE ADD SUB MUL DIV ADDI SUBI
                     ADDILV SUBILV EQ LT LE GT GE ARRAY ARRAY2 AREF ASET STRING STRCAT]).freeze
    RETURNS = %w[RETURN RETSELF RETNIL RETTRUE RETFALSE].freeze
    attr_reader :program, :irep

    def self.build(irep, argc)
      return nil unless pure_mandatory_arity?(irep) && mandatory_arity(irep) == argc
      return nil unless Array(irep.catch_handlers).empty? && Array(irep.reps).empty?
      return nil unless irep.instructions.size <= 256 && irep.nregs <= 128
      return nil unless irep.instructions.all? { |insn| OPS.include?(insn.op) || insn.op.start_with?('LOADI') }
      return nil unless irep.instructions.all? { |insn| !%w[SEND SSEND].include?(insn.op) || insn.plain_fixed_argc? }

      program = BytecodeIR.for(irep)
      return nil unless program.resolved? && program.instructions.any?
      return nil unless RETURNS.include?(program.instructions.last.op) || program.instructions.last.op == 'JMP'

      new(irep, program)
    end

    def initialize(irep, program)
      @irep = irep
      @program = program
    end
  end
end
