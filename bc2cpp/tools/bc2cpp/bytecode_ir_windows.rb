# frozen_string_literal: true

# Adjacency windows over an irep's index-aligned instruction list. The closed-world
# scans (closed_world.rb) read neighbours by position; they hold the raw list, not a
# Program, so these take it directly. Linear order only: no CFG edge is followed.
module BytecodeIR
  module Window
    module_function

    # The instruction at index - 1, nil at the entry (same rule as Program#previous).
    def previous(insns, index)
      index.positive? ? insns[index - 1] : nil
    end

    # Up to +n+ instructions immediately before +index+, in program order (fewer near the entry).
    def preceding(insns, index, n)
      insns[(index - n).clamp(0, index)...index]
    end

    # Up to +n+ instructions immediately after +index+ (fewer at the end).
    def following(insns, index, n)
      insns[index + 1, n]
    end

    # Yields (insn, j) walking back from index - 1 down to +floor+, inclusive.
    def each_preceding(insns, index, floor = 0)
      (index - 1).downto(floor) { |j| yield insns[j], j }
    end

    # Yields (insn, j) walking forward from index + 1 up to +ceiling+, exclusive.
    def each_following(insns, index, ceiling = insns.size)
      ((index + 1)...ceiling).each { |j| yield insns[j], j }
    end

    # The nearest instruction walking back from index - 1 to +floor+ for which the block is true, or nil.
    def find_preceding(insns, index, floor = 0)
      (index - 1).downto(floor) { |j| return insns[j] if yield insns[j] }
      nil
    end
  end
end
