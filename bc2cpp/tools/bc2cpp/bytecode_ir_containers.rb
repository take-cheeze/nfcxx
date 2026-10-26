# frozen_string_literal: true

require 'set'
require_relative 'bytecode_ir'

# Container shapes on the IR: the literal that built the Array or Hash a register holds, the registers
# its elements and pairs came from, and the value class each producer of a register gives. RecordHash,
# ArrayElementLayout / HashElementLayout and SEALED_HASH_IVAR read these instead of indexing irep.instructions.
module BytecodeIR
  # An Array or Hash literal. `ARRAY Ra n` reads n registers from Ra, `ARRAY Ra Rb n` (ARRAY2, printed as ARRAY with
  # a source register) n from Rb, `HASH Ra n` n key/value pairs from Ra (vm.c OP_ARRAY, OP_ARRAY2, OP_HASH).
  ContainerLiteral = Struct.new(:index, :kind, :base, :count) do
    def empty?
      count.zero?
    end

    # Element registers of an Array, value registers of a Hash.
    def value_regs
      kind == :hash ? (0...count).map { |k| base + (2 * k) + 1 } : (0...count).map { |k| base + k }
    end

    def key_regs
      kind == :hash ? (0...count).map { |k| base + (2 * k) } : []
    end
  end

  # One value that can reach a register read: the definition and the instruction that wrote it (nil for the value
  # the frame was entered with).
  Producer = Struct.new(:definition, :insn) do
    def entry?
      definition.entry?
    end

    def index
      definition.index
    end

    def reg
      definition.reg
    end

    def op
      insn&.op
    end
  end

  # Value classes of a literal producer, spelled as the layout tables spell them. Read on first use: this file
  # can load while Types is still loading (bytecode_ir.rb -> here, from inside bytecode_ir_types.rb).
  def self.literal_value_classes
    @literal_value_classes ||= Types::LITERAL_TYPES.transform_values(&:to_s).freeze
  end

  def self.pool_value_classes
    @pool_value_classes ||= Types::POOL_TYPES.transform_values(&:to_s).freeze
  end

  LOADI_OP = /\ALOADI(?:8|16|32|NEG|__1|_[0-7])\z/

  class Program
    def source_at(index)
      @instructions[index]&.source
    end

    def size
      @instructions.length
    end

    # Yields [source, index] for every instruction, in program order.
    def each_source(&block)
      return enum_for(:each_source) unless block

      @instructions.each { |instruction| yield instruction.source, instruction.index }
    end

    # The container literal the instruction at +index+ builds, or nil.
    def container_literal(index)
      insn = source_at(index)
      return nil unless insn

      case insn.op
      when :HASH
        count = insn.uint_operand
        count && ContainerLiteral.new(index, :hash, insn.reg.to_i, count)
      when :ARRAY
        if insn.regs.size == 2
          count = insn.typed.last.value
          count.is_a?(Integer) && count >= 0 ? ContainerLiteral.new(index, :array, insn.regs[1].to_i, count) : nil
        else
          count = insn.uint_operand
          count && ContainerLiteral.new(index, :array, insn.reg.to_i, count)
        end
      end
    end

    # The class of the value a literal producer at +index+ leaves in its leading register, or nil when it is not a
    # literal (Types#definition_types' literal arm). +pool+ is the irep's literal pool.
    def literal_class(index, pool)
      insn = source_at(index)
      return nil unless insn
      return 'Integer' if BytecodeIR::Ops::LOADI_OPS.include?(insn.op)
      literal = BytecodeIR.literal_value_classes
      return literal[insn.op] if literal.key?(insn.op)
      return nil unless insn.op == :LOADL

      entry = insn.pool_index && pool && pool[insn.pool_index]
      entry.is_a?(Hash) ? BytecodeIR.pool_value_classes[entry[:type]] : nil
    end

    # Yields [source, index] from +start+ while each instruction is entered only from the one before it (normal or
    # handler edges), at most +window+ of them; none when the edge set is unresolved.
    def straight_line(start, window)
      preds = instruction_predecessors(include_handlers: true) or return nil
      k = start
      while k < @instructions.length && k < start + window
        break unless preds[k] == Set[k - 1]

        yield @instructions[k].source, k
        k += 1
      end
      nil
    end

    # Nothing between +from+ and +to+ can change a container built at +from+: every instruction strictly between them
    # is a QUIET_OPS load or a jump into (from, to], so each path from +from+ stays in that span until it reaches +to+
    # and runs no method. A literal mutated before its use (`a = []; a << x; @v = a`) fails this.
    QUIET_OPS = Set[:NOP, :MOVE, :LOADL, :LOADSYM, :LOADNIL, :LOADSELF, :LOADTRUE, :LOADFALSE, :GETIV,
                    :GETCONST, :GETUPVAR, :STRING, :BLOCK, :LAMBDA, :JMP, :JMPIF, :JMPNOT, :JMPNIL].freeze

    def quiet_span?(from, to)
      return false unless from < to && resolved?

      (from + 1...to).all? do |k|
        insn = @instructions[k].source
        next false unless QUIET_OPS.include?(insn.op) || BytecodeIR::Ops::LOADI_OPS.include?(insn.op)

        @instructions[k].successors.all? { |s| s > from && s <= to }
      end
    end

    # The child irep index of the `BLOCK R(recv+1) I[k]` directly before the block-carrying call at +index+.
    def adjacent_block_index(index, recv_reg)
      block = index.positive? ? source_at(index - 1) : nil
      return nil unless block&.op == :BLOCK && block.reg == recv_reg + 1

      block.block_index
    end
  end

  # Producers of +reg+ at +index+ in +irep+ (reaching_definitions with the irep's nested-block writes), or nil when
  # the dataflow refuses or finds none.
  def self.producers(irep, index, reg, **options)
    defs = reaching_definitions(irep, index, reg, shared: true, **options)
    return nil if defs.nil? || defs.empty?

    program = self.for(irep)
    defs.map { |d| Producer.new(d, d.entry? ? nil : program.source_at(d.index)) }
  end

  # Program#literal_class of the instruction at +index+ of +irep+.
  def self.literal_class(irep, index)
    self.for(irep).literal_class(index, irep.pool)
  end
end
