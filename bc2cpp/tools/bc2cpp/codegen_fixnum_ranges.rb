# frozen_string_literal: true

# CodeGen: NUMERIC_CONSTANT_RANGES consumer (ADR 0318).
#
# fixnum_interval answers "is register +reg+ at +idx+ a Fixnum whose value lies in a known interval", from integer
# literals, constants with a proven interval (IntegerConstantRanges) and + - * / of those. An arithmetic result is a
# Fixnum here only because its interval fits the narrowest target Fixnum range (ADR 0279 retired the unbounded rule).
# The walk is proven_fixnum_operand?'s single-path walk: same barriers, same region dominance; a join gives up.
class CodeGen
  FIXNUM_INTERVAL_OPS = %w[ADD SUB MUL DIV ADDI SUBI].freeze

  # The gate for every use of a constant interval: a closed world with no runtime constant rebinding, no
  # const_missing, and Integer's + - * / still the core bodies (a definition-time `A / B` runs them).
  def fixnum_intervals_on?
    !self.class.integer_constant_ranges.nil? && static_constant_world? && %w[+ - * /].all? { |op| numeric_op_native?(op) }
  end

  # BC2CPP_NUMERIC_CONSTANTS=0 off, and every constant binding visible: no const_set, remove_const, autoload or
  # const_missing, no global refusal.
  # Not memoized: @closed_world is swapped for the world of a core method (ADR 0264).
  def static_constant_world?
    ENV['BC2CPP_NUMERIC_CONSTANTS'] != '0' && !@closed_world.nil? && @closed_world.constants_static? && const_missing_free?
  end

  # [lo, hi] or nil; +why+ (an Array) collects the leaf that stopped a nil answer, for the probe.
  def fixnum_interval(irep, idx, reg, owner_def, depth = 0, why = nil)
    return nil unless irep && idx && reg && owner_def && fixnum_intervals_on?
    return fixnum_interval_fail(why, 'depth') if depth > FIXNUM_PROOF_MAX_DEPTH

    ctx = fixnum_proof_ctx(irep)
    cur = reg.to_s
    return fixnum_interval_fail(why, 'upvar') if ctx[:upvars].include?(cur)

    unaudited = lambda do |insn, _cur|
      ctx[:protected].include?(insn.addr) ||
        !(FIXNUM_PROOF_STEP_OVER_OPS.include?(insn.op) || insn.op.start_with?('LOADI'))
    end
    use_insn = idx >= 0 && irep.instructions[idx]
    return fixnum_interval_fail(why, 'barrier') if !use_insn || unaudited.call(use_insn, cur)

    irep.walk_writers(idx - 1, cur, skip_ops: FIXNUM_PROOF_READONLY_REG_OPS, barrier: unaudited,
                                    exhausted: ->(_r) { fixnum_interval_fail(why, 'param') }) do |insn, j, wreg|
      if insn.op == 'MOVE'
        src = insn.regs[1]
        next fixnum_interval_fail(why, 'move') if src.nil? || ctx[:upvars].include?(src)

        next IrepScans.follow(src)
      end
      next fixnum_interval_fail(why, 'join') unless fixnum_proof_region_ok?(irep, ctx, j, idx)

      fixnum_interval_source(irep, j, insn, wreg, owner_def, depth, why)
    end
  end

  def fixnum_interval_source(irep, j, insn, wreg, owner_def, depth, why)
    op = insn.op
    if op.start_with?('LOADI')
      value = IntegerConstantRanges.literal(insn)
      return value ? [value, value] : fixnum_interval_fail(why, 'literal')
    end
    case op
    when 'GETCONST', 'GETMCNST'
      name = op == 'GETCONST' ? insn.const_name : insn.mcnst_name
      range = name && self.class.integer_constant_ranges[name]
      range || fixnum_interval_fail(why, "const:#{name}")
    when *FIXNUM_INTERVAL_OPS
      left = fixnum_interval(irep, j, insn.regs[0], owner_def, depth + 1, why)
      right = if %w[ADDI SUBI].include?(op)
                imm = insn.imm_operand&.to_i
                imm && [imm, imm]
              else
                fixnum_interval(irep, j, insn.regs[1], owner_def, depth + 1, why)
              end
      return nil unless left && right

      result = IntegerConstantRanges.combine(op, left, right)
      result || fixnum_interval_fail(why, "range:#{op}")
    else
      fixnum_interval_fail(why, op.start_with?('SEND', 'SSEND') ? "send:#{insn.sym}" : op)
    end
  end

  def fixnum_interval_fail(why, leaf)
    why&.push(leaf)
    nil
  end
end
