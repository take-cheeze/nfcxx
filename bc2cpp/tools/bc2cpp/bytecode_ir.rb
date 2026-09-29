# frozen_string_literal: true

# A conservative normal-flow view of an mruby IREP. The original disassembly
# remains the source of opcode semantics; this layer gives analyses stable
# instruction identities and explicit basic-block edges. Catch-handler edges
# are not modeled, so consumers must not use this graph to prove exception flow.
module BytecodeIR
  Instruction = Struct.new(:index, :source, :successors, keyword_init: true) do
    def addr
      source.addr
    end

    def op
      source.op
    end
  end

  BasicBlock = Struct.new(:id, :instructions, :successors, :predecessors, keyword_init: true)

  # Ops after which control never reaches the next instruction. RAISE and
  # RAISEIF are deliberately absent: a missing predecessor makes a proof wrong
  # while an extra one only costs a proof, so they conservatively fall through.
  NO_FALLTHROUGH = %w[JMP JMPUW RETURN RETURN_BLK RETSELF RETNIL RETTRUE RETFALSE BREAK STOP].freeze
  CONDITIONAL_BRANCHES = %w[JMPIF JMPNOT JMPNIL].freeze
  TERMINATORS = (NO_FALLTHROUGH + CONDITIONAL_BRANCHES).freeze
  # Predecessor id of the method-entry edge into instruction 0.
  ENTRY = -1

  class Program
    attr_reader :instructions, :blocks, :address_to_index

    def initialize(irep)
      @instructions = Array(irep.instructions).each_with_index.map do |source, index|
        Instruction.new(index: index, source: source, successors: [])
      end
      @address_to_index = @instructions.to_h { |instruction| [instruction.addr, instruction.index] }
      build_edges
      build_blocks
    end

    def instruction_at(index)
      @instructions[index]
    end

    # False when some branch targets an address that is not an instruction, so
    # the edge set is incomplete and no analysis may rely on it.
    def resolved?
      @resolved
    end

    # index -> Set of predecessor indices, with ENTRY for instruction 0's
    # method-entry edge. Nil when #resolved? is false.
    def instruction_predecessors
      return nil unless @resolved

      @instruction_predecessors ||= begin
        preds = Array.new(@instructions.length) { Set.new }
        preds[0] << ENTRY unless preds.empty?
        @instructions.each do |instruction|
          instruction.successors.each { |successor| preds[successor] << instruction.index }
        end
        preds.each(&:freeze).freeze
      end
    end

    # [source, target] instruction-index pairs of the given jump ops located
    # before +limit+, or nil when a jump's target address is not an instruction.
    def jump_edges_before(limit, ops)
      edges = []
      @instructions.each do |instruction|
        break if instruction.index >= limit
        next unless ops.include?(instruction.op)

        target = @address_to_index[instruction.source.jump_target]
        return nil unless target

        edges << [instruction.index, target]
      end
      edges
    end

    private

    def build_edges
      @resolved = true
      @instructions.each do |instruction|
        targets = []
        target_addr = instruction.source.branch_target
        if target_addr
          target = @address_to_index[target_addr]
          target ? targets << target : @resolved = false
        end
        next_index = instruction.index + 1
        targets << next_index if next_index < @instructions.length && !NO_FALLTHROUGH.include?(instruction.op)
        instruction.successors = targets.uniq.freeze
      end
    end

    def build_blocks
      if @instructions.empty?
        @blocks = [].freeze
        return
      end

      leaders = [0]
      @instructions.each do |instruction|
        next unless TERMINATORS.include?(instruction.op)

        instruction.successors.each do |successor|
          leaders << successor
        end
        if CONDITIONAL_BRANCHES.include?(instruction.op) && instruction.index + 1 < @instructions.length
          leaders << instruction.index + 1
        end
      end
      leaders = leaders.uniq.sort
      ranges = leaders.each_with_index.map do |start, i|
        [start, (leaders[i + 1] || @instructions.length) - 1]
      end
      owner = {}
      @blocks = ranges.each_with_index.map do |(first, last), id|
        members = (first..last).to_a
        members.each { |index| owner[index] = id }
        BasicBlock.new(id: id, instructions: members.freeze, successors: [], predecessors: [])
      end
      @blocks.each do |block|
        terminal = @instructions[block.instructions.last]
        block.successors = terminal.successors.filter_map { |index| owner[index] }.uniq.freeze
      end
      @blocks.each do |block|
        block.successors.each { |successor| @blocks[successor].predecessors << block.id }
      end
      @blocks.each { |block| block.predecessors.freeze }
      @blocks.freeze
    end
  end

  def self.for(irep)
    cached = irep.instance_variable_get(:@bytecode_ir)
    return cached if cached

    irep.instance_variable_set(:@bytecode_ir, Program.new(irep))
  end
end
