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

  TERMINATORS = %w[JMP JMPIF JMPNOT JMPNIL RETURN RETURN_BLK BREAK RAISE RAISEIF STOP].freeze
  CONDITIONAL_BRANCHES = %w[JMPIF JMPNOT JMPNIL].freeze

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
      @instructions.each do |instruction|
        next_index = instruction.index + 1
        next_addr = @instructions[next_index]&.addr
        targets = branch_targets(instruction)
        unless instruction.op == 'JMP'
          targets << next_addr if next_addr && !TERMINATORS.include?(instruction.op)
          targets << next_addr if next_addr && CONDITIONAL_BRANCHES.include?(instruction.op)
        end
        instruction.successors = targets.filter_map { |addr| @address_to_index[addr] }.uniq.freeze
      end
    end

    def branch_targets(instruction)
      Array(instruction.source.jump_target)
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
