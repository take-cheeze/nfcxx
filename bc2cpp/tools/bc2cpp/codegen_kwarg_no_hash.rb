# frozen_string_literal: true

require 'set'
require_relative 'bytecode_ir'

# KWARG_NO_HASH: a method (or block) with keyword parameters and no `**rest` builds no Hash of its keywords.
#
# mrbc (codegen.c, after OP_KEYEND) rebuilds the keyword Hash for a bare `super` to forward: one LOADSYM/MOVE pair per
# keyword, `HASH Rs k`, `MOVE Rkd Rs`, where Rkd is the `**` register (m1 + o + r + m2 + 1). Only OP_ARGARY reads Rkd.
# The compiled `_impl` takes the keywords as parameters, so that Hash is one allocation per call nothing looks at.
#
# The HASH and its MOVE emit nothing when all of these hold; any doubt keeps both:
#   shape     ENTER has keywords and no `**rest`; the instructions after the one KEYEND are exactly the pairs, the HASH of
#             k pairs and the MOVE into Rkd, with Rkd named `**`
#   dead      no instruction but the MOVE reads Rs or Rkd with the HASH or the MOVE as a reaching definition (an op whose
#             reads are not modelled counts as reading both); the irep's own ARGARY reads Rkd, so a bare `super` keeps it
#   captures  no block nested under the irep has an ARGARY, or reads or writes Rs or Rkd of the irep as an upvar
# The compiled code has no VM frame for a reflective read (binding, local_variable_get) to see the register through.
# BC2CPP_KWARG_NO_HASH=0 turns it off; BC2CPP_KWARG_NO_HASH_REPORT=1 prints each irep's plan or refusal.
class CodeGen
  def kwarg_no_hash_enabled?
    ENV['BC2CPP_KWARG_NO_HASH'] != '0'
  end

  # { HASH index => :hash, MOVE index => :move } for +irep+, or {} when the rebuild stays.
  def kwarg_no_hash_plan(irep)
    @kwarg_no_hash_plans ||= {}.compare_by_identity
    @kwarg_no_hash_plans[irep] ||= begin
      plan, reason = compute_kwarg_no_hash_plan(irep)
      if ENV['BC2CPP_KWARG_NO_HASH_REPORT'] == '1' && (plan.any? || reason != :no_keywords)
        where = "#{File.basename(irep.file.to_s)}:#{irep.instructions&.first&.lineno}"
        warn "bc2cpp KWARG_NO_HASH: #{where} (irep #{irep.label}): #{plan.any? ? 'no Hash' : "kept (#{reason})"}"
      end
      plan.freeze
    end
  end

  private

  def compute_kwarg_no_hash_plan(irep)
    return [{}, :disabled] unless kwarg_no_hash_enabled?

    fields = irep.enter&.enter_fields
    return [{}, :no_keywords] unless fields && fields.size >= 6 && fields[4].to_i.positive?
    return [{}, :keyword_rest] unless fields[5].to_i.zero?

    prog = BytecodeIR.for(irep)
    return [{}, :unresolved] unless prog.resolved? && prog.handlers_resolved?

    shape = kwarg_no_hash_shape(irep, prog, fields)
    return [{}, :shape] unless shape

    hash_idx, s, kd = shape
    return [{}, :captured] unless kwarg_no_hash_uncaptured?(irep, [s, kd].to_set)

    params = stack_tuple_params(irep)
    return [{}, :read] unless kwarg_no_hash_dead?(irep, prog, hash_idx, [s, kd], params)

    [{ hash_idx => :hash, hash_idx + 1 => :move }, nil]
  end

  # [HASH index, Rs, Rkd] of the rebuild after KEYEND, or nil.
  def kwarg_no_hash_shape(irep, prog, fields)
    keyends = []
    prog.each_source { |insn, idx| keyends << idx if insn.op == :KEYEND }
    return nil unless keyends.size == 1

    k = fields[4].to_i
    kd = fields.first(4).sum(&:to_i) + 1
    return nil unless irep.lv && irep.lv[kd - 1].to_s == '**'

    at = keyends.first + 1
    first = at < prog.size ? prog.source_at(at) : nil
    return nil unless first&.op == :LOADSYM

    s = reg_int(first.reg)
    k.times do |i|
      sym = prog.source_at(at + (2 * i))
      val = prog.source_at(at + (2 * i) + 1)
      return nil unless sym&.op == :LOADSYM && reg_int(sym.reg) == s + (2 * i)
      return nil unless val&.op == :MOVE && reg_int(val.regs[0]) == s + (2 * i) + 1
    end
    hash_idx = at + (2 * k)
    hash = prog.source_at(hash_idx)
    move = hash_idx + 1 < prog.size ? prog.source_at(hash_idx + 1) : nil
    return nil unless hash&.op == :HASH && reg_int(hash.reg) == s && hash.uint_operand.to_i == k
    return nil unless move&.op == :MOVE && move.regs.map(&:to_i) == [kd, s]

    [hash_idx, s, kd]
  end

  # BLOCK and LAMBDA read no register; what their body reads of this frame is kwarg_no_hash_uncaptured?'s.
  KWARG_NO_HASH_NO_READS = Set[:BLOCK, :LAMBDA].freeze

  # No instruction but the MOVE reads Rs or Rkd with the HASH or the MOVE as a reaching definition (MOVEs are followed,
  # so a read of Rkd names the HASH). A refused dataflow query keeps the Hash.
  def kwarg_no_hash_dead?(irep, prog, hash_idx, regs, params)
    writers = [hash_idx, hash_idx + 1]
    prog.instructions.all? do |ins|
      j = ins.index
      next true if j == hash_idx + 1 || KWARG_NO_HASH_NO_READS.include?(ins.source.op)

      reads = string_eq_reads(ins.source, params)
      regs.all? do |reg|
        next true unless reads == :all || reads.include?(reg)
        # handler_ops: a handler's EXCEPT and RESCUE are walked as vm.c runs them, not refused.
        defs = prog.reaching_definitions(j, reg, opaque_regs: BytecodeIR.own_upvar_written_regs(irep),
                                            through_handlers: true, handler_ops: true)
        defs && defs.none? { |d| !d.entry? && writers.include?(d.index) }
      end
    end
  end

  # No nested block packs a frame (ARGARY) or touches one of +regs+ of +irep+ through its env.
  def kwarg_no_hash_uncaptured?(irep, regs)
    walk = lambda do |node, depth|
      Array(node.reps).all? do |label|
        child = irep.tree&.[](label)
        next false unless child

        cprog = BytecodeIR.for(child)
        next false if cprog.op?(:ARGARY)

        touched = false
        %i[GETUPVAR SETUPVAR].each do |op|
          cprog.each_with_op(op) do |insn, _|
            index, level = insn.upvar_ref
            touched = true if index.nil? || (level == depth && regs.include?(index))
          end
        end
        !touched && walk.call(child, depth + 1)
      end
    end
    walk.call(irep, 0)
  end
end

# Prepended to CodeGen, outermost: the planned HASH and MOVE emit a comment only.
module KwargNoHashCompileInsn
  def compile_insn(insn, irep, owner_def, idx = nil, reg_offset = 0)
    kind = idx && irep && kwarg_no_hash_enabled? ? kwarg_no_hash_plan(irep)[idx] : nil
    return super unless kind

    if kind == :hash
      "  // KWARG_NO_HASH: the keyword Hash only a bare super reads is not built\n"
    else
      "  // KWARG_NO_HASH: the ** register is never read\n"
    end
  end
end

CodeGen.prepend(KwargNoHashCompileInsn)
