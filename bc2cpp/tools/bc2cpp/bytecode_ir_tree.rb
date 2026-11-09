# frozen_string_literal: true

require_relative 'bytecode_ir'

# The irep tree around a Program. Irep#reps is index-aligned with an instruction's block operand and holds
# the child's label, which only the caller's ireps table resolves, so the lookup is passed in rather than
# read from Irep#tree (a copied subtree is registered in a table that Irep#tree does not name).
module BytecodeIR
  module Tree
    # [[index, label]] for each instruction of +irep+ whose op is in +ops+, in program order. The label is
    # the child irep the instruction names (nil when reps has no entry for it).
    def self.child_labels(irep, ops)
      sites = []
      BytecodeIR.for(irep).each_with_op(*ops) do |insn, index|
        sites << [index, irep.reps[insn.block_index.to_i]]
      end
      sites
    end

    # [[index, child irep]] of +irep+'s +ops+ instructions whose child is in +ireps+ (label => Irep).
    def self.children(irep, ireps, ops)
      child_labels(irep, ops).filter_map do |index, label|
        child = ireps[label]
        [index, child] if child
      end
    end

    # Yields (irep, depth, chain) for +irep+, then depth-first for each irep nested in it through an +ops+
    # site. +chain+ is the [owner, index] pairs from the frame the walk started in down to the owner of +irep+.
    def self.each_subtree(irep, ireps, ops, depth = 0, chain = [], &block)
      block.call(irep, depth, chain)
      children(irep, ireps, ops).each do |index, child|
        each_subtree(child, ireps, ops, depth + 1, chain + [[irep, index]], &block)
      end
    end
  end
end
