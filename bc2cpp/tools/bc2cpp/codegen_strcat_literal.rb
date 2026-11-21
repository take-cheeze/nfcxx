# frozen_string_literal: true

require 'set'
require_relative 'bytecode_ir'

# STRCAT_LITERAL: a literal piece of string interpolation ("a#{x}b") appends its bytes to the accumulator, and builds no
# String for them. Without it each piece is a STRING (a fresh mutable String) that the next STRCAT copies and drops.
#
# OP_STRCAT is mrb_ensure_string_type(R(a)) then mrb_str_concat(R(a), R(a+1)); for a String R(a+1) that is
# mrb_str_cat_str, whose bytes mrb_str_cat appends call for call (frozen check, ASCII flag and the empty-append early
# return included). A (STRING, STRCAT) pair is rewritten when all of these hold; any doubt keeps both instructions:
#   shape  the STRCAT follows the STRING, appends R(a+1) where R(a+1) is the STRING's register, and is reached only
#          by falling through from the STRING (strcat_literal_only_predecessor?)
#   dead   R(a+1) is a temporary (at or above nlocals, so no closure's GETUPVAR names it), and every path from the
#          STRCAT, handler edges included, overwrites it before any instruction reads it (strcat_literal_dead_after?)
# The STRING is suppressed and the STRCAT carries the literal, counted per method as CHR_APPEND counts its pairs.
#
# STRCAT_STRING_ACC: the STRCAT drops mrb_ensure_string_type when every definition of R(a) reaching it (MOVEs
# followed, handler edges crossed, a block's SETUPVAR register refused) is a STRING or a STRCAT, each of which leaves
# a String there. BC2CPP_STRCAT_LITERAL=0 turns both off.
class CodeGen
  def strcat_literal_enabled?
    ENV['BC2CPP_STRCAT_LITERAL'] != '0'
  end

  # The instruction indexes of +irep+ the rewrite touches: { STRING index => :lit, STRCAT index => :cat }.
  def strcat_literal_plan(irep)
    @strcat_literal_plans ||= {}
    @strcat_literal_plans[irep.label] ||= compute_strcat_literal_plan(irep)
  end

  # Whether the STRCAT at +idx+ of +irep+ is proven to find a String in its accumulator (STRCAT_STRING_ACC).
  def strcat_accumulator_string?(irep, idx)
    return false unless strcat_literal_enabled? && irep && idx && !@resumable

    prog = BytecodeIR.for(irep)
    return false unless prog.resolved? && prog.handlers_resolved?

    a = reg_int(prog.source_at(idx).reg)
    prods = BytecodeIR.producers(irep, idx, a, through_handlers: true)
    !prods.nil? && !prods.empty? && prods.all? { |p| !p.entry? && STRCAT_STRING_WRITERS.include?(p.insn.op) }
  end

  STRCAT_STRING_WRITERS = Set[:STRING, :STRCAT].freeze

  # Called by compile_method's wrapper: the counters of the method being compiled, nil outside one.
  attr_accessor :strcat_literal_state

  private

  def compute_strcat_literal_plan(irep)
    return {} unless strcat_literal_enabled?

    prog = BytecodeIR.for(irep)
    return {} unless prog.resolved? && prog.handlers_resolved?

    params = stack_tuple_params(irep)
    plan = {}
    prog.each_source do |insn, idx|
      next unless insn.op == :STRING && irep.pool.fetch(insn.pool_index.to_i).is_a?(String)

      cat = idx + 1 < prog.size ? prog.source_at(idx + 1) : nil
      next unless cat && cat.op == :STRCAT

      s = reg_int(insn.reg)
      a = reg_int(cat.reg)
      next unless a && s && s == a + 1
      next unless strcat_literal_only_predecessor?(prog, idx)
      next unless strcat_literal_dead_after?(irep, prog, idx + 1, s, params)

      plan[idx] = :lit
      plan[idx + 1] = :cat
    end
    plan
  end

  # Is the STRCAT after +idx+ reached only by falling through from the STRING at +idx+? The STRING's own handler edge
  # (an allocation failure) is not followed: the rewrite makes no allocation there.
  def strcat_literal_only_predecessor?(prog, idx)
    target = idx + 1
    prog.successors_of(idx) == [target] && prog.instructions.none? do |ins|
      ins.index != idx && prog.successors_of(ins.index, include_handlers: true).include?(target)
    end
  end

  # Ops that always write their leading register once they complete. A raise before the write leaves the old value,
  # so their handler edges are still walked.
  STRCAT_LITERAL_KILLS = (Set[:MOVE, :LOADL, :LOADSYM, :LOADNIL, :LOADSELF, :LOADTRUE, :LOADFALSE, :GETGV, :GETSV,
                              :GETIV, :GETCV, :GETCONST, :GETUPVAR, :STRING, :SYMBOL] |
                          BytecodeIR::Ops::LOADI_OPS | BytecodeIR::Ops::SEND).freeze

  # Is register +s+ overwritten before any read on every path from the STRCAT at +cat+? An op whose reads are not
  # modelled (stack_tuple_reads' :all) is a read.
  def strcat_literal_dead_after?(irep, prog, cat, s, params)
    return false if s < irep.nlocals.to_i

    todo = prog.successors_of(cat, include_handlers: true).dup
    seen = Set.new
    until todo.empty?
      j = todo.pop
      next unless seen.add?(j)

      ins = prog.source_at(j)
      reads = ins.op == :STRCAT ? [reg_int(ins.reg), reg_int(ins.reg) + 1] : string_eq_reads(ins, params)
      return false if reads == :all || reads.include?(s)

      killed = STRCAT_LITERAL_KILLS.include?(ins.op) && reg_int(ins.reg) == s
      todo.concat(killed ? Array(prog.raise_targets[j]) : prog.successors_of(j, include_handlers: true))
    end
    true
  end
end

# Prepended to CodeGen: counts the halves of each rewrite in one method and recompiles it without the rewrite when
# they do not match.
module StrcatLiteralCompileMethod
  def compile_method(label)
    return super unless strcat_literal_enabled?
    return super if strcat_literal_state

    @strcat_literal_off ||= Set.new
    return super if @strcat_literal_off.include?(label)

    state = { lit: Hash.new(0), cat: Hash.new(0) }
    self.strcat_literal_state = state
    text = begin
      super
    ensure
      self.strcat_literal_state = nil
    end
    return text if state[:lit] == state[:cat]

    warn "bc2cpp STRCAT_LITERAL: #{label} compiled one half of a rewrite without the other; recompiled without it" if ENV['BC2CPP_STRCAT_LITERAL_REPORT'] == '1'
    @strcat_literal_off << label
    super
  end
end

# Prepended to CodeGen: the STRING of a planned pair emits a comment only, and the STRCAT appends its bytes.
module StrcatLiteralCompileInsn
  def compile_insn(insn, irep, owner_def, idx = nil, reg_offset = 0)
    state = strcat_literal_state
    return super unless state && idx && !@resumable

    kind = strcat_literal_plan(irep)[idx]
    return super unless kind

    pair = kind == :lit ? idx : idx - 1
    key = [irep.label, pair, reg_offset]
    if kind == :lit
      state[:lit][key] += 1
      return "  // STRCAT_LITERAL: the STRCAT below appends this literal's bytes\n"
    end

    state[:cat][key] += 1
    string_insn = BytecodeIR.for(irep).source_at(idx - 1)
    string_insn = string_insn.shift_regs(reg_offset) unless reg_offset.zero?
    cat_text = super(insn, irep, owner_def, idx, reg_offset)
    a = reg_int(insn.reg)
    concat = "  mrb_str_concat(M, r#{a}, r#{a + 1});\n"
    if cat_text.scan(concat).size == 1
      literal = irep.pool.fetch(string_insn.pool_index.to_i)
      return cat_text.sub(concat) { "  bc2cpp_str_cat_lit(M, r#{a}, #{c_string_literal(literal)});\n" }
    end

    # Another emitter's STRCAT text: the pair as it was.
    super(string_insn, irep, owner_def, idx - 1, reg_offset) + cat_text
  end
end

CodeGen.prepend(StrcatLiteralCompileMethod)
CodeGen.prepend(StrcatLiteralCompileInsn)
