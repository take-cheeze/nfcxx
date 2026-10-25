# frozen_string_literal: true

require 'set'
require_relative 'bytecode_ir'
require_relative 'bytecode_ir_returns'

# NUMERIC_CLASSES: the IR's side of NumericFlow. The flow reads every instruction fact from the
# BytecodeIR::Program (decode, operands, edges, handler targets, frame exits) and answers the literal-element question
# with the IR's reaching definitions and the type layer's literal classes, so no numeric analysis walks
# `irep.instructions` itself.
module BytecodeIR
  # The operands NumericFlow reads besides Decoded's (#operands): +b+, the second register the op reads or writes
  # (MOVE's source, RESCUE's flag, the parenthesised operand of an operator, GETIDX0's receiver, SETIV's value), and
  # +ivar+, the instance variable of GETIV/SETIV. nil where the op has none.
  Operands = Struct.new(:b, :ivar)
  NO_OPERANDS = Operands.new(nil, nil).freeze
  OPERATOR_OPS = Set[:ADD, :SUB, :MUL, :DIV, :EQ, :LT, :LE, :GT, :GE].freeze
  SECOND_REG_OPS = Set[:MOVE, :RESCUE, :ADDILV, :SUBILV, :GETIDX0].freeze

  # Decode +insn+'s Operands. Reads only the operands the op has.
  def self.operands(insn)
    op = insn.op
    if op == :SETIV then Operands.new(insn.regs.first.to_i, insn.ivar)
    elsif op == :GETIV then Operands.new(nil, insn.ivar)
    elsif SECOND_REG_OPS.include?(op) then Operands.new(insn.regs[1].to_i, nil)
    elsif OPERATOR_OPS.include?(op) then Operands.new(insn.paren_reg.to_i, nil)
    else NO_OPERANDS
    end
  end

  class Program
    # Every instruction's Operands, frozen and index-aligned.
    def operands
      @operands ||= @instructions.map { |instruction| BytecodeIR.operands(instruction.source).freeze }.freeze
    end

    # True when every instruction in (+first+, +last+] is entered only from the one before it: no jump or method
    # entry lands inside, so the run executes as written once +first+ has. A catch handler entering the run is a
    # predecessor only with +include_handlers+ (the normal-flow graph does not carry it).
    def linear_corridor?(first, last, include_handlers: false)
      preds = instruction_predecessors(include_handlers: include_handlers) or return false

      ((first + 1)..last).all? { |target| preds[target].size == 1 && preds[target].include?(target - 1) }
    end
  end

  module NumericClasses
    module_function

    # NumericFlow's class facts of +irep+ (see NumericFlow.states): index -> state, nil when not modelled.
    def states(irep, oracle, opaque_regs, writes = nil)
      NumericFlow.states(irep, oracle, opaque_regs, writes)
    end

    # The join, over every exit the flow reached, of what the block maps (exit, its state) to; +init+ starts it.
    def exit_mask(irep, states, init = 0)
      BytecodeIR.for(irep).exits.reduce(init) do |joined, exit|
        state = states[exit.index]
        state ? joined | yield(exit, state) : joined
      end
    end

    # What the method whose body is +irep+ hands back through its own exits: RETURN and RETURN_BLK their register,
    # RETNIL nil, any other exit (self, true, false, break, stop) OTHER.
    def returned_mask(irep, states, init = 0)
      exit_mask(irep, states, init) do |exit, state|
        case exit.op
        when :RETURN, :RETURN_BLK then state[exit.reg] || NumericFlow::OTHER
        when :RETNIL then NumericFlow::NIL
        else NumericFlow::OTHER
        end
      end
    end

    # What the reached RETURN_BLK exits of the block +irep+ return from its method.
    def block_return_mask(irep, states)
      exit_mask(irep, states) { |exit, state| exit.op == :RETURN_BLK ? state[exit.reg] || NumericFlow::OTHER : 0 }
    end

    # True when the block +irep+ has a RETURN_BLK (a `return` from its method).
    def block_returns?(irep)
      BytecodeIR.for(irep).exits.any? { |exit| exit.op == :RETURN_BLK }
    end

    # Ops that run no Ruby, raise nothing and write one register: between an Array literal and its read they leave
    # the fresh Array as it was built.
    QUIET_OPS = Set[:NOP, :MOVE, :LOADNIL, :LOADTRUE, :LOADFALSE, :LOADSYM, :LOADL, :STRING].freeze

    # ELEMENT_LITERAL: the class mask of `GETIDX`/`GETIDX0` at +index+ when it reads a literal
    # position of an Array literal no Ruby could touch since it was built, from the definitions reaching that
    # position's register at the ARRAY; nil when not proven.
    def element_literal_mask(irep, index, opaque)
      return nil if ENV['BC2CPP_LITERAL_ELEMENT_PROOF'] == '0'

      program = BytecodeIR.for(irep)
      return nil if program.handlers?

      read = program.instructions[index].source
      op = read.op
      return nil unless op == :GETIDX || op == :GETIDX0

      opaque = opaque.frozen? ? opaque : opaque.dup.freeze
      receiver = op == :GETIDX ? read.reg.to_i : program.operands[index].b
      literal_index = 0
      if op == :GETIDX
        key = single_writer(program, index, receiver + 1, opaque, follow_moves: true)
        literal_index = key && integer_literal(key.last)
        return nil unless literal_index
      end
      origin, array = single_writer(program, index, receiver, opaque, follow_moves: false)
      return nil unless array && (array.op == :ARRAY || array.op == :ARRAY2) && fresh_since?(program, origin, index)

      source, count = array.src_and_literal || [array.reg.to_i, array.uint_operand]
      count = count.to_i if count
      return nil unless count && count.positive? && literal_index.between?(-count, count - 1)

      element = source.to_i + (literal_index % count)
      return nil if opaque.include?(element)

      defs = program.reaching_definitions(origin, element, shared: true, opaque_regs: opaque)
      return nil unless defs && !defs.empty?

      defs.reduce(0) do |mask, definition|
        return nil if definition.entry?

        writer = program.instructions[definition.index].source
        return nil unless writer.reg == definition.reg

        bit = NumericFlow::LITERAL_CLASS_MASKS[BytecodeIR::Types.literal_class(writer, irep.pool)]
        return nil unless bit

        mask | bit
      end
    end

    # [index, insn] of the one instruction whose write of +reg+ reaches +index+ (MOVE chains followed when
    # +follow_moves+), or nil.
    def single_writer(program, index, reg, opaque, follow_moves:)
      defs = program.reaching_definitions(index, reg, shared: true, opaque_regs: opaque, follow_moves: follow_moves)
      return nil unless defs && defs.size == 1 && !defs.first.entry?

      writer = program.instructions[defs.first.index].source
      writer.reg == defs.first.reg ? [defs.first.index, writer] : nil
    end

    # Nothing between the ARRAY at +origin+ and the read at +index+ can reach the Array: a straight run of quiet ops.
    def fresh_since?(program, origin, index)
      program.linear_corridor?(origin, index) &&
        ((origin + 1)...index).all? do |k|
          op = program.instructions[k].op
          QUIET_OPS.include?(op) || BytecodeIR::Ops::LOADI_OPS.include?(op)
        end
    end

    def integer_literal(insn)
      op = insn.op
      return -1 if op == :LOADI__1
      return -insn.uint_operand if op == :LOADINEG && insn.uint_operand
      return BytecodeIR::Ops::LOADI_SLOT_VALUE[op] if BytecodeIR::Ops::LOADI_SLOT.include?(op)
      return insn.imm_operand.to_i if %i[LOADI8 LOADI16 LOADI32].include?(op) && insn.imm_operand

      nil
    end
  end
end
