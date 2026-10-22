# frozen_string_literal: true

require 'set'
require_relative 'bytecode_ir'

# RETURN_SITES: how a body leaves its frame and where the values it returns come from, for the return
# analyses (the Fixnum, Array and class return proofs, DECLARED_RETURN_CHECK and the exact-class return table).
module BytecodeIR
  # How each exit op leaves the frame. RETURN_BLK is a plain return in a method body (methods are strict procs) and
  # leaves the enclosing method from a block; BREAK ends the call that took the block.
  EXIT_KINDS = { 'RETURN' => :value, 'RETURN_BLK' => :block_return, 'RETNIL' => :nil, 'RETSELF' => :self,
                 'RETTRUE' => :true, 'RETFALSE' => :false, 'BREAK' => :break, 'STOP' => :stop }.freeze

  VALUE_EXIT_OPS = Set['RETURN', 'RETURN_BLK', 'BREAK'].freeze

  # One exit instruction: its +op+, +kind+ (EXIT_KINDS) and +reg+, the Integer register RETURN, RETURN_BLK and BREAK
  # hand back (nil for the others). The one shape both the return analyses and NumericClasses read.
  Exit = Struct.new(:index, :op, :kind, :reg)

  # A return source that is a nil literal (LOADNIL).
  NIL_SOURCE = :nil

  class Program
    # Every exit instruction, in program order.
    def exits
      @exits ||= @instructions.filter_map do |instruction|
        op = instruction.op
        kind = EXIT_KINDS[op]
        next unless kind

        Exit.new(instruction.index, op, kind, VALUE_EXIT_OPS.include?(op) ? instruction.source.reg.to_i : nil).freeze
      end.freeze
    end

    def exit?(*kinds)
      exits.any? { |e| kinds.include?(e.kind) }
    end

    # The definitions of +reg+ reaching the exit at +index+: NIL_SOURCE for a LOADNIL or the fall-through of a
    # RAISEIF of it, else [writer index, register]. nil when a path is unaccounted for: the query refused, or the
    # method's entry value reaches. Handler edges are followed, so a protected range costs nothing and a raise
    # contributes the value it was entered with; the handler entry (EXCEPT, RESCUE) is an unmodelled writer and refuses.
    def return_sources(index, reg, opaque_regs: nil, max_states: DATAFLOW_MAX_STATES)
      return nil unless reg

      definitions = reaching_definitions(index, reg.to_s, opaque_regs: opaque_regs, max_states: max_states,
                                                          through_handlers: true, raiseif_nil: true)
      return nil unless definitions

      definitions.map do |definition|
        return nil if definition.entry?

        nil_source = %w[LOADNIL RAISEIF].include?(@instructions[definition.index].op)
        nil_source ? NIL_SOURCE : [definition.index, definition.reg]
      end
    end
  end

  # Every irep nested in +irep+ (blocks and lambdas, at any depth), each once, depth first. Needs Irep#tree.
  def self.nested_bodies(irep)
    return [] if Array(irep.reps).empty?

    tree = irep.tree
    raise ArgumentError, "bc2cpp: irep #{irep.label} has children but no tree" unless tree

    out = []
    seen = Set.new
    stack = Array(irep.reps).reverse
    until stack.empty?
      label = stack.pop
      next unless seen.add?(label)

      child = tree[label]
      raise ArgumentError, "bc2cpp: irep #{label} missing from the tree" unless child

      out << child
      stack.concat(Array(child.reps).reverse)
    end
    out
  end

  # [child irep, Exit] for every exit of a kind in +kinds+ nested below +irep+.
  def self.nested_exits(irep, *kinds)
    nested_bodies(irep).flat_map do |child|
      self.for(child).exits.filter_map { |e| [child, e] if kinds.include?(e.kind) }
    end
  end

  def self.nested_exit?(irep, *kinds)
    nested_bodies(irep).any? { |child| self.for(child).exit?(*kinds) }
  end

  # Program#return_sources with the irep's own nested-block writes opaque.
  def self.return_sources(irep, index, reg, max_states: DATAFLOW_MAX_STATES)
    self.for(irep).return_sources(index, reg, opaque_regs: own_upvar_written_regs(irep), max_states: max_states)
  end
end
