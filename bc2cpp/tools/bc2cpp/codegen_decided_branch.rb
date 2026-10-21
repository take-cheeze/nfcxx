# frozen_string_literal: true

require_relative 'numeric_flow'

# DECIDED_BRANCH: a conditional jump whose tested register the NumericFlow state decides is emitted as an unconditional
# `goto` (taken on every path) or as nothing (never taken), instead of `if (mrb_test(rN))`.
#
# The mask of a register before the jump is every class its value can have there. A mask with no NIL and no OTHER is
# truthy on every path (OTHER holds false and every unknown value); a mask of exactly NIL is falsy on every path; JMPNIL
# is taken exactly when the mask is NIL and never when it has no NIL bit. An unreached instruction (mask 0) decides
# nothing.
#
# Nothing is cut. A taken fold keeps the fall-through code, which a label may still reach, and a not-taken fold keeps the
# jump's target, so no arm is deleted and no jump-edge check is needed. BC2CPP_DECIDED_BRANCH=0 keeps every test.
class CodeGen
  DECIDED_BRANCH_OPS = %w[JMPIF JMPNOT JMPNIL].freeze

  def decided_branch_enabled?
    ENV['BC2CPP_DECIDED_BRANCH'] != '0'
  end

  # :taken or :not_taken when the state decides the jump at +idx+, else nil. +reg_offset+ must be 0: a shifted
  # instruction names registers of the enclosing frame, which the state of +irep+ does not index.
  def decided_branch_outcome(insn, irep, owner_def, idx, reg_offset = 0)
    return nil unless decided_branch_enabled? && idx && reg_offset.zero? && DECIDED_BRANCH_OPS.include?(insn.op)

    mask = numeric_raw_mask(irep, idx, insn.reg.to_i, owner_def)
    return nil unless mask.is_a?(Integer) && mask.positive?

    if insn.op == 'JMPNIL'
      return :taken if mask == NumericFlow::NIL
      return :not_taken if (mask & NumericFlow::NIL).zero?

      return nil
    end

    truthy = (mask & NumericFlow::FALSY).zero?
    return nil unless truthy || mask == NumericFlow::NIL

    jumps = truthy == (insn.op == 'JMPIF')
    jumps ? :taken : :not_taken
  end

  # The generated C++ for a decided jump to +target+ (a label name), or nil when the state does not decide it and the
  # caller keeps its test.
  def decided_branch_code(insn, outcome, target)
    case outcome
    when :taken then "  goto #{target}; // DECIDED_BRANCH #{insn.op} R#{insn.reg}: taken\n"
    when :not_taken then "  // DECIDED_BRANCH #{insn.op} R#{insn.reg}: not taken\n"
    end
  end
end
