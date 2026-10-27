# frozen_string_literal: true

# CodeGen: INTEGER_BIT_AREF -- `n[i]` on a Fixnum, inline, when the program's only Integer#[] is the bit read
# `(self >> i) & 1` (optcarrot's shim). See docs/bc2cpp-integer-bit-aref.md.
class CodeGen
  INTEGER_BIT_AREF_NOTE = '// INTEGER_BIT_AREF -- Fixnum receiver, index >= 0: Integer#[] is `(self >> i) & 1`'

  # A Fixnum receiver and a non-negative Fixnum index; a bignum, a negative index or any other class fails it and
  # keeps the generic path (Integer#<< for a negative width, the bignum `>>`).
  def integer_bit_aref_test(recv, key)
    "mrb_fixnum_p(#{recv}) && mrb_fixnum_p(#{key}) && mrb_fixnum(#{key}) >= 0"
  end

  # The bit under integer_bit_aref_test. A width past the sign bit reads the sign, as mrb_num_shift does for `>>`.
  def integer_bit_aref_value(recv, key)
    "mrb_fixnum_value(mrb_fixnum(#{key}) >= MRB_INT_BIT - 1 ? (mrb_fixnum(#{recv}) < 0) : " \
      "((mrb_fixnum(#{recv}) >> mrb_fixnum(#{key})) & 1))"
  end

  def integer_bit_aref_arm(dst, recv, key, otherwise)
    "if (#{integer_bit_aref_test(recv, key)}) {\n" \
      "  #{dst} = #{integer_bit_aref_value(recv, key)};\n" \
      "} else {\n#{otherwise.gsub(/^(?=.)/, '  ')}}\n"
  end

  # bc2cpp_getidx's arm, after its Array test so an Array site pays nothing for it; '' outside the world.
  def integer_bit_aref_helper_arm
    return '' unless integer_bit_aref_world?

    "  #{INTEGER_BIT_AREF_NOTE}\n" \
      "  if (#{integer_bit_aref_test('recv', 'key')}) {\n" \
      "    return #{integer_bit_aref_value('recv', 'key')};\n" \
      "  }\n"
  end

  # GETIDX on a receiver NumericFlow proves Integer: the arm with no Array/Hash/String tests ahead of it.
  def integer_bit_aref_site(irep, idx, reg, owner_def, d, s, fallback)
    return nil unless integer_bit_aref_world?
    return nil unless numeric_raw_mask(irep, idx, reg, owner_def) == NumericFlow::INT

    "#{INTEGER_BIT_AREF_NOTE} (receiver proven Integer)\n#{integer_bit_aref_arm("r#{d}", "r#{d}", "r#{s}", fallback)}"
  end

  # True when a Fixnum's `[]` reaches exactly the bit read: the closed world names one Ruby Integer#[] (no alias,
  # installer or runtime definer, nothing prepended into Integer) whose bytecode is INTEGER_BIT_AREF_BODY, and Integer's
  # `>>` and `&` are mruby's native ones. The POLY chain this arm runs ahead of calls the same body for an Integer.
  def integer_bit_aref_world?
    # Per world: core bodies compile with the closed world withdrawn.
    memo = (@integer_bit_aref_world ||= {}.compare_by_identity)
    return memo[@closed_world] if memo.key?(@closed_world)

    memo[@closed_world] = integer_bit_aref_world_uncached
  end

  def integer_bit_aref_world_uncached
    return false if ENV['BC2CPP_INTEGER_BIT_AREF'] == '0' || @closed_world.nil? || devirt_blocked_name?('[]')
    return false unless Array(@prepended_modules['Integer']).empty? && !@unknown_mixins.include?('Integer')

    defs = (@registry['[]'] || []).select { |d| d.owner == 'Integer' }
    return false unless defs.size == 1

    target = defs.first
    return false unless target.irep && target.copy_irep.nil? && target.installer.nil? && target.visibility == :public
    return false unless %w[>> &].all? { |name| builtin_class_send_safe?(name, ['Integer']) }

    integer_bit_aref_body?(@ireps[target.irep])
  end

  # `def [](i); (self >> i) & 1; end` as mrbc emits it: the shift is an SSEND with the argument copied above the
  # receiver slot, or a SEND on a copy of self.
  def integer_bit_aref_body?(irep)
    return false unless irep && Array(irep.reps).empty? && Array(irep.catch_handlers).empty?

    insns = irep.instructions
    fields = insns.first&.op == :ENTER ? insns.first.enter_fields : []
    return false unless fields.first == 1 && fields.drop(1).all?(&:zero?)

    body = insns.drop(1)
    self_copy = body.shift if body.size == 6
    return false unless body.size == 5

    move, shift, one, mask, ret = body
    k = shift.regs.first
    return false unless k

    shift_op = self_copy ? :SEND : :SSEND
    return false if self_copy && !(self_copy.op == :MOVE && self_copy.regs == [k, 0])

    move.op == :MOVE && move.regs == [k + 1, 1] && shift.op == shift_op && shift.sym == '>>' && shift.argc == 1 &&
      (one.op == :LOADI_1 || (one.op == :LOADI && BytecodeIR::OperandModel.imm_operand(one) == 1)) &&
      one.regs == [k + 1] &&
      mask.op == :SEND && mask.regs == [k] && mask.sym == '&' && mask.argc == 1 &&
      ret.op == :RETURN && ret.regs == [k]
  end
end
