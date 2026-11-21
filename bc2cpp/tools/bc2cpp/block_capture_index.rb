# frozen_string_literal: true

require_relative 'bytecode_ir'

# Bytecode-only captures, shared across probes within one CodeGen.
class BlockCaptureIndex
  def initialize(ireps, max_depth, block_given_names)
    @ireps = ireps
    @max_depth = max_depth
    @block_given_names = block_given_names
    @upvars = {}.compare_by_identity
    @block_levels = {}.compare_by_identity
  end

  def upvars(irep)
    @upvars.fetch(irep) do
      needs = []
      opaque = false
      walked = BytecodeIR.each_nested_insn(irep, ->(label) { @ireps[label] }, max_depth: @max_depth) do |insn, depth|
        if insn.op == :ARGARY
          # BLOCK_ZSUPER: a bare `super` in a block reads the method frame's parameters as GETUPVARs would.
          reads = insn.argary_frame_reads
          opaque ||= reads.nil?
          next unless reads && reads[0] >= 1

          level = reads[0] - 1
          reads[1].each { |index| needs << [level - depth, index].freeze } if level >= depth
          next
        end
        next unless insn.op == :GETUPVAR || insn.op == :SETUPVAR

        index, level = insn.upvar_ref
        needs << [level - depth, index].freeze if level >= depth
      end
      @upvars[irep] = walked && !opaque ? needs.uniq.sort.freeze : nil
    end
  end

  def block_levels(irep, depth = 0, given: true)
    return nil if depth > @max_depth

    # Depth changes both the refusal budget and the level of a block_given? read.
    by_mode = @block_levels[irep] ||= [{}, {}]
    by_depth = by_mode[given ? 1 : 0]
    return by_depth[depth] if by_depth.key?(depth)

    needs = []
    BytecodeIR.for(irep).instructions_with_op(:BLKPUSH).each do |insn|
      level = insn.paren_value
      return store_levels(by_depth, depth, nil) unless level

      needs << level.to_i
    end
    # BLOCK_ZSUPER: OP_ARGARY copies the block slot of the frame `lv` names, as BLKPUSH reads it.
    BytecodeIR.for(irep).instructions_with_op(:ARGARY).each do |insn|
      level = insn.paren_int
      return store_levels(by_depth, depth, nil) unless level

      needs << level
    end
    if given && BytecodeIR.for(irep).instructions_with_op(:SSEND0).any? { |insn| @block_given_names.include?(insn.sym) }
      needs << depth + 1
    end
    (irep.reps || []).each do |label|
      child = label && @ireps[label]
      next unless child

      levels = block_levels(child, depth + 1, given: given)
      return store_levels(by_depth, depth, nil) unless levels

      levels.each { |level| needs << level - 1 if level >= 1 }
    end
    store_levels(by_depth, depth, needs.uniq.sort.freeze)
  end

  private

  def store_levels(by_depth, depth, value)
    by_depth[depth] = value
  end
end
