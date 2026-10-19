# frozen_string_literal: true

require_relative 'bytecode_ir'

# Instruction-level queries the block-region recognizers (codegen_loop_regions,
# codegen_loop_inline, codegen_block_fallback) and the Irep scans (irep.rb,
# irep_scans.rb delegate here) share, kept apart from the control-flow
# construction in bytecode_ir.rb. Every answer is a pure function of the
# instruction list: nothing here adds or removes a CFG edge.
module BytecodeIR
  # Result of Program#copy_root.
  CopyRoot = Struct.new(:reg, :writer)

  # Block result of Program#walk_writers: keep walking, now following +reg+. A
  # nil +reg+ is a MOVE with no source, which ends the walk with nil.
  Follow = Struct.new(:reg)
  # Block result: keep walking with the register unchanged (the instruction was
  # transparent for this question, e.g. a `.freeze` on the same register).
  KEEP = Follow.new(:same).freeze

  class Program
    # Source instructions (in program order) whose op is one of +ops+.
    def instructions_with_op(*ops)
      @instructions.filter_map { |instruction| instruction.source if ops.include?(instruction.op) }
    end

    # Yields [source, index] for the same instructions, in program order.
    def each_with_op(*ops)
      ops = ops.uniq
      indices = ops.flat_map { |op| indices_by_op.fetch(op, []) }
      indices.sort! if ops.size > 1
      indices.each { |index| yield @instructions[index].source, index }
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

      indices = second_ops.uniq.flat_map { |op| indices_by_op.fetch(op, []) }
      indices.sort! if second_ops.uniq.size > 1
      indices.each do |index|
        next unless index.positive?

        instruction = @instructions[index]
        first = @instructions[index - 1].source
        yield first, instruction.source, index if first.op == first_op
      end
    end

    # Source instructions of the unbroken run of +op+ starting at linear
    # +index+ (empty when the instruction there is not +op+ or is missing).
    def run_of_op(index, op)
      run = []
      while (instruction = @instructions[index]) && instruction.op == op
        run << instruction.source
        index += 1
      end
      run
    end

    # Source instructions of the unbroken run of +op+ ending at linear +index+
    # (inclusive), in program order, at most +limit+ of them (the newest).
    def run_of_op_ending(index, op, limit: nil)
      run = []
      index = [index, @instructions.length - 1].min
      while index >= 0 && (limit.nil? || run.size < limit) && @instructions[index].op == op
        run.unshift(@instructions[index].source)
        index -= 1
      end
      run
    end

    # Follow MOVE copies of +reg+ backward from +from_index+ (inclusive) to the
    # register the value was copied out of. The writer is the first non-MOVE
    # instruction writing that register, nil when none precedes (a value that
    # entered the frame). nil when +reg+ is nil or a MOVE has no source.
    def copy_root(from_index, reg)
      return nil unless reg

      walk_writers(from_index, reg, follow_moves: true, exhausted: ->(root) { CopyRoot.new(root, nil) }) do |insn, _, root|
        CopyRoot.new(root, insn)
      end
    end

    # Index of the nearest instruction at or before +from_index+ whose leading
    # register operand is +reg+ (spelled as Insn#reg spells it), or nil. Linear
    # order, not dominance: the textually preceding writer, which only a
    # straight-line caller may read as the reaching one (see
    # BytecodeIR.write_dominates? and #reaching_definitions for joins).
    def last_writer_index(from_index, reg)
      return nil if reg.nil?

      indices = lead_indices[reg]
      return nil unless indices

      position = indices.bsearch_index { |i| i > from_index }
      position = position ? position - 1 : indices.length - 1
      position.negative? ? nil : indices[position]
    end

    # Walk backwards from instruction +from_index+ (inclusive) along register
    # +reg+, yielding `(insn, index, reg)` for each instruction whose leading
    # register operand is the followed register. The block's result decides
    # what happens: Follow / KEEP continue, anything else (nil, false, a value)
    # ends the walk and is returned.
    #
    # Options, checked per instruction in this order:
    # * barrier: ops (Array) or `->(insn, reg)`; a hit ends the walk with
    #   +barrier_result+ whether or not the instruction touches the register.
    # * skip_ops: ops ignored even when they name the register (read-only
    #   opcodes, BLOCK's proc register).
    # * follow_moves: MOVE is followed to its source without yielding; a MOVE
    #   without a source, or more than +max_moves+ of them, ends the walk with nil.
    # +exhausted+ (`->(reg)`) supplies the result when the top of the body is
    # reached with +reg+ never written, i.e. an incoming register.
    def walk_writers(from_index, reg, skip_ops: nil, barrier: nil, barrier_result: nil,
                     follow_moves: false, max_moves: nil, exhausted: nil)
      moves = 0
      callable_barrier = barrier.respond_to?(:call)
      index = [from_index, @instructions.length - 1].min
      while index >= 0
        # Without a barrier only an instruction leading with +reg+ can matter, so
        # jump straight to the previous one (skip_ops only ever skips those too).
        unless barrier
          index = last_writer_index(index, reg)
          break unless index
        end
        insn = @instructions[index].source
        hit = barrier && (callable_barrier ? barrier.call(insn, reg) : barrier.include?(insn.op))
        return barrier_result if hit

        next_index = index - 1
        if insn.reg != reg || skip_ops&.include?(insn.op)
          index = next_index
          next
        end

        if follow_moves && insn.op == 'MOVE'
          moves += 1
          return nil if max_moves && moves > max_moves

          reg = insn.regs[1]
          return nil unless reg

          index = next_index
          next
        end

        step = yield insn, index, reg
        index = next_index
        next if step.equal?(KEEP)
        return step unless step.is_a?(Follow)

        reg = step.reg
        return nil unless reg
      end
      exhausted&.call(reg)
    end

    private

    # Per-op and per-leading-register index lists, built once (the instruction
    # list never changes after loading; see #built_from?).
    def indices_by_op
      @indices_by_op ||= @instructions.group_by(&:op).transform_values { |list| list.map(&:index).freeze }.freeze
    end

    def lead_indices
      @lead_indices ||= @instructions.group_by { |instruction| instruction.source.reg }
                                     .transform_values { |list| list.map(&:index).freeze }.freeze
    end
  end
end
