# frozen_string_literal: true

require_relative 'numeric_flow'

# CodeGen: CAPTURED_LOCAL_CLASS (ADR 0308).
#
# A block's GETUPVAR is the defining frame's register: the class set is that frame's state at the creating BLOCK/LAMBDA
# joined with every value stored into the register since (numeric_upvar_mask's argument, for class bits). A class belongs
# to the variable, not to its aliases, so ADR 0296's refusal of element classes does not apply. Only a write by name
# (Binding#local_variable_set, eval) could bypass the flow, so the proof is off when a build can reach one.
class CodeGen
  # Sends that can store into a local without a SETUPVAR the flow could see.
  CAPTURED_LOCAL_WRITER_NAMES = %w[binding local_variable_set eval].freeze
  # A rebinding send runs a block under another self; a string argument is an eval of source text.
  CAPTURED_LOCAL_STRING_EVALS = %w[instance_eval class_eval module_eval instance_exec class_exec module_exec].freeze

  # The class set a block's GETUPVAR sees (NumericFlow::OTHER when unproven).
  def class_upvar_mask(irep, insn)
    return NumericFlow::OTHER unless captured_local_class_enabled?

    index, level = insn.upvar_ref
    return NumericFlow::OTHER unless index

    ancestor, creation = captured_local_frame(irep, level)
    return NumericFlow::OTHER unless ancestor
    return NumericFlow::OTHER if index >= ancestor.nregs.to_i || fixnum_proof_ctx(ancestor)[:upvars].include?(index.to_s)

    states = return_class_states(ancestor)
    state = states && states[creation]
    return NumericFlow::OTHER unless state

    state[index] | (@rc_writes.dig(ancestor.label, index) || 0)
  end

  # [defining irep, index of the BLOCK/LAMBDA that created the closure on the path], or nil.
  def captured_local_frame(irep, level)
    cur = irep
    ancestor = nil
    creation = nil
    (level + 1).times do
      link = numeric_block_parents[cur.label]
      return nil unless link

      ancestor, creation = link
      cur = ancestor
    end
    [ancestor, creation]
  end

  def captured_local_class_enabled?
    return @captured_local_class_enabled if defined?(@captured_local_class_enabled)

    @captured_local_class_enabled = ENV.fetch('BC2CPP_CAPTURED_LOCAL_CLASS', '1') != '0' && captured_local_writers_absent?
  end

  # No native of the build implements or calls a way to write a local by name (so a computed-name send has nothing
  # to reach), no outside Ruby spells one, and no send, symbol or string of the world names one. A rebinding send
  # with a literal block is fine (its SETUPVARs are visible); without one it may eval text.
  def captured_local_writers_absent?
    return false unless @closed_world && @closed_world.global_refusal.nil?

    names = CAPTURED_LOCAL_WRITER_NAMES
    return false if names.any? { |name| !@closed_world.native_paths_spelling(name).empty? || @closed_world.outside_ruby_token?(name) }

    @ireps.each_value do |irep|
      irep.instructions.each_with_index do |insn, idx|
        sym = insn.sym
        next unless sym

        return false if names.include?(sym)
        return false if CAPTURED_LOCAL_STRING_EVALS.include?(sym) && insn.op.include?('SEND') && !literal_block_argument?(irep, idx, insn)
      end
    end
    !DynamicNames.universe(@ireps).intersect?(names)
  end
end
