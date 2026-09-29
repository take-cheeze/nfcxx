# frozen_string_literal: true

require_relative 'bytecode_ir'

# Instruction-level queries the block-region recognizers (codegen_loop_regions,
# codegen_loop_inline, codegen_block_fallback) share, kept apart from the
# control-flow construction in bytecode_ir.rb. Every answer is a pure function
# of the instruction list: nothing here adds or removes a CFG edge.
module BytecodeIR
  # Result of Program#copy_root.
  CopyRoot = Struct.new(:reg, :writer)

  class Program
    # Source instructions (in program order) whose op is one of +ops+.
    def instructions_with_op(*ops)
      @instructions.filter_map { |instruction| instruction.source if ops.include?(instruction.op) }
    end

    # Yields [source, index] for the same instructions.
    def each_with_op(*ops)
      @instructions.each do |instruction|
        yield instruction.source, instruction.index if ops.include?(instruction.op)
      end
    end

    def op?(*ops)
      @instructions.any? { |instruction| ops.include?(instruction.op) }
    end

    # Addresses some jump op lands on, including ones that are not an
    # instruction (those make #resolved? false, not an error here).
    def branch_target_addrs
      @branch_target_addrs ||= @instructions.filter_map { |instruction| instruction.source.branch_target }.to_set.freeze
    end

    # Source instruction at linear index - 1, nil at the entry.
    def previous(index)
      index.positive? ? @instructions[index - 1]&.source : nil
    end

    # Every [first, second, second_index] where +second+ has an op in
    # +second_ops+ and linearly follows an instruction whose op is +first_op+.
    # Linear adjacency, not dominance: a jump into +second+ is not excluded,
    # matching the shape mrbc emits for a block-carrying call.
    def adjacent_pairs(first_op, second_ops)
      return enum_for(:adjacent_pairs, first_op, second_ops) unless block_given?

      @instructions.each do |instruction|
        next unless second_ops.include?(instruction.op) && instruction.index.positive?

        first = @instructions[instruction.index - 1].source
        yield first, instruction.source, instruction.index if first.op == first_op
      end
    end

    # Follow MOVE copies of +reg+ backward from +from_index+ (inclusive) to the
    # register the value was copied out of. The writer is the first non-MOVE
    # instruction writing that register, nil when none precedes (a value that
    # entered the frame). nil when +reg+ is nil or a MOVE has no source.
    def copy_root(from_index, reg)
      return nil unless reg

      loop do
        writer_index = last_writer_index(from_index, reg)
        return CopyRoot.new(reg, nil) unless writer_index

        writer = @instructions[writer_index].source
        return CopyRoot.new(reg, writer) unless writer.op == 'MOVE'

        reg = writer.regs[1]
        return nil unless reg

        from_index = writer_index - 1
      end
    end

    private

    def last_writer_index(from_index, reg)
      [from_index, @instructions.length - 1].min.downto(0) do |i|
        return i if @instructions[i].source.reg == reg
      end
      nil
    end
  end
end
