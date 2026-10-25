# frozen_string_literal: true

# CodeGen: NUMERIC_CONSTANT_RANGES consumer.
#
# fixnum_interval answers "is register +reg+ at +idx+ a Fixnum whose value lies in a known interval", from integer
# literals, constants with a proven interval (IntegerConstantRanges) and + - * / of those. An arithmetic result is a
# Fixnum here only because its interval fits the narrowest target Fixnum range.
# The walk is single-path with proven_fixnum_operand?'s barriers; every hop must dominate the read it feeds
# (BytecodeIR.write_dominates?), so a join gives up.
class CodeGen
  FIXNUM_INTERVAL_OPS = %i[ADD SUB MUL DIV ADDI SUBI].freeze

  # The gate for every use of a constant interval: a closed world with no runtime constant rebinding, no
  # const_missing, and Integer's + - * / still the core bodies (a definition-time `A / B` runs them).
  def fixnum_intervals_on?
    !self.class.integer_constant_ranges.nil? && static_constant_world? && %w[+ - * /].all? { |op| numeric_op_native?(op) }
  end

  # BC2CPP_NUMERIC_CONSTANTS=0 off, and every constant binding visible: no const_set, remove_const or
  # const_missing, no global refusal.
  # Not memoized: @closed_world is swapped for the world of a core method.
  def static_constant_world?
    IntegerConstantRanges.enabled? && !@closed_world.nil? && @closed_world.constants_static? && const_missing_free?
  end

  # NUMERIC_INTERVAL_OPERANDS: the interval proof also vouches for operands of the Fixnum proof's consumers.
  # BC2CPP_NUMERIC_INTERVALS=0 turns that off (the output is master's).
  def numeric_intervals_on?
    ENV['BC2CPP_NUMERIC_INTERVALS'] != '0' && fixnum_intervals_on?
  end

  PROVEN_INDEX_NOTE = "// NUMERIC_INTERVAL_OPERANDS -- index operand proven Fixnum (ADR 0326)\n  "

  # An Array index the Fixnum proof (with the interval sources) covers: no integer test, no `[]` funcall else.
  def proven_index_operand?(irep, idx, reg, owner_def)
    ENV['BC2CPP_NUMERIC_INTERVALS'] != '0' && !reg.nil? && proven_fixnum_operand?(irep, idx, reg, owner_def)
  end

  def fixnum_interval_const?(name)
    numeric_intervals_on? && !name.nil? && !self.class.integer_constant_ranges[name].nil?
  end

  # [lo, hi] or nil; +why+ (an Array) collects the leaf that stopped a nil answer, for the probe.
  def fixnum_interval(irep, idx, reg, owner_def, depth = 0, why = nil)
    return nil unless irep && idx && reg && owner_def && fixnum_intervals_on?
    return fixnum_interval_fail(why, 'depth') if depth > FIXNUM_PROOF_MAX_DEPTH

    ctx = fixnum_proof_ctx(irep)
    cur = reg
    return fixnum_interval_fail(why, 'upvar') if ctx[:upvars].include?(cur)

    unaudited = lambda do |insn, _cur|
      ctx[:protected].include?(insn.addr) ||
        !(FIXNUM_PROOF_STEP_OVER_OPS.include?(insn.op) || insn.op.to_s.start_with?('LOADI'))
    end
    use_insn = idx >= 0 && BytecodeIR.for(irep).source_at(idx)
    return fixnum_interval_fail(why, 'barrier') if !use_insn || unaudited.call(use_insn, cur)

    read = idx
    irep.walk_writers(idx - 1, cur, skip_ops: FIXNUM_PROOF_READONLY_REG_OPS, barrier: unaudited,
                                    exhausted: ->(_r) { fixnum_interval_fail(why, 'param') }) do |insn, j, wreg|
      next fixnum_interval_fail(why, 'join') unless BytecodeIR.write_dominates?(irep, j, read, wreg)

      read = j
      if insn.op == :MOVE
        src = insn.regs[1]
        next fixnum_interval_fail(why, 'move') if src.nil? || ctx[:upvars].include?(src)

        next IrepScans.follow(src)
      end
      fixnum_interval_source(irep, j, insn, wreg, owner_def, depth, why)
    end
  end

  def fixnum_interval_source(irep, j, insn, wreg, owner_def, depth, why)
    op = insn.op
    if op.to_s.start_with?('LOADI')
      value = IntegerConstantRanges.literal(insn)
      return value ? [value, value] : fixnum_interval_fail(why, 'literal')
    end
    case op
    when :GETCONST, :GETMCNST
      name = op == :GETCONST ? insn.const_name : insn.mcnst_name
      range = name && self.class.integer_constant_ranges[name]
      range || fixnum_interval_fail(why, "const:#{name}")
    when :GETIDX, :GETIDX0
      # SEALED_INT16 (sealed_int16_locals.rb): an in-range read of a proven int16 array has the array's interval.
      sealed_element_range(irep, j) || fixnum_interval_fail(why, op)
    when *FIXNUM_INTERVAL_OPS
      left = fixnum_interval(irep, j, insn.regs[0], owner_def, depth + 1, why)
      right = if %i[ADDI SUBI].include?(op)
                imm = insn.imm_operand&.to_i
                imm && [imm, imm]
              else
                fixnum_interval(irep, j, insn.regs[1], owner_def, depth + 1, why)
              end
      return nil unless left && right

      result = IntegerConstantRanges.combine(op, left, right)
      result || fixnum_interval_fail(why, "range:#{op}")
    else
      fixnum_interval_fail(why, op.to_s.start_with?('SEND', 'SSEND') ? "send:#{insn.sym}" : op)
    end
  end

  def fixnum_interval_fail(why, leaf)
    why&.push(leaf)
    nil
  end
end
