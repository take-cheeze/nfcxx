# frozen_string_literal: true

# TAGGED_FIXNUM: the Fixnum arms of + - * and the ordering/equality compares work on the boxed word itself when the
# boxing makes that exact (word boxing, fixnum = (n << 1) | 1, mrb_int as wide as the word); every other build keeps
# the unbox/rebox form. The soundness argument per target is in docs/bc2cpp-tagged-fixnum.md.
module TaggedFixnum
  module_function

  # Printed once per translation unit, after the mruby includes and ahead of every generated function.
  PRELUDE = <<~'CPP'
    #ifndef BC2CPP_TAGGED_FIXNUM
    #define BC2CPP_TAGGED_FIXNUM 0
    #if defined(MRB_WORD_BOXING) && defined(__GNUC__)
    // MRB_FIXNUM_SHIFT is 0 for a 64-bit word with MRB_INT32, where the word range is not the fixnum range.
    #if MRB_FIXNUM_SHIFT == 1 && WORDBOX_FIXNUM_FLAG == 1 && WORDBOX_FIXNUM_MASK == 1 && MRB_INT_MAX == INTPTR_MAX && \
        MRB_INT_MIN == INTPTR_MIN
    #undef BC2CPP_TAGGED_FIXNUM
    #define BC2CPP_TAGGED_FIXNUM 1
    #endif
    #endif
    #endif
    #if BC2CPP_TAGGED_FIXNUM
    // The fixnum range is the word range less one bit, so a word op overflows exactly when the result is not FIXABLE.
    static_assert(MRB_FIXNUM_MAX == (INTPTR_MAX >> 1) && MRB_FIXNUM_MIN == (INTPTR_MIN >> 1), "TAGGED_FIXNUM range");
    #define BC2CPP_FIXNUM_PAIR_P(a, b) ((((a).w & (b).w) & 1) != 0)
    #define BC2CPP_FIXNUM_WORD(v) ((intptr_t)(v).w)
    static inline mrb_value bc2cpp_fixnum_word_value(uintptr_t w) {
      mrb_value v;
      v.w = w;
      return v;
    }
    // Both tag bits are 1: & and | keep it, ^ clears it.
    #define BC2CPP_FIXNUM_AND(a, b) bc2cpp_fixnum_word_value((a).w & (b).w)
    #define BC2CPP_FIXNUM_OR(a, b) bc2cpp_fixnum_word_value((a).w | (b).w)
    #define BC2CPP_FIXNUM_XOR(a, b) bc2cpp_fixnum_word_value(((a).w ^ (b).w) | 1)
    // (2a+1) + 2b = 2(a+b)+1, and likewise for -; true (result untouched) when a+b leaves the fixnum range.
    static inline bool bc2cpp_fixnum_add(mrb_value a, mrb_value b, mrb_value& z) {
      intptr_t w;
      if (__builtin_add_overflow((intptr_t)a.w, (intptr_t)(b.w - 1), &w)) return true;
      z.w = (uintptr_t)w;
      return false;
    }
    static inline bool bc2cpp_fixnum_sub(mrb_value a, mrb_value b, mrb_value& z) {
      intptr_t w;
      if (__builtin_sub_overflow((intptr_t)a.w, (intptr_t)(b.w - 1), &w)) return true;
      z.w = (uintptr_t)w;
      return false;
    }
    // 2a * b = 2ab is even, so the +1 cannot overflow.
    static inline bool bc2cpp_fixnum_mul(mrb_value a, mrb_value b, mrb_value& z) {
      intptr_t w;
      if (__builtin_mul_overflow((intptr_t)(a.w - 1), (intptr_t)b.w >> 1, &w)) return true;
      z.w = (uintptr_t)w + 1;
      return false;
    }
    #else
    #define BC2CPP_FIXNUM_PAIR_P(a, b) (mrb_fixnum_p(a) && mrb_fixnum_p(b))
    #define BC2CPP_FIXNUM_WORD(v) mrb_fixnum(v)
    #define BC2CPP_FIXNUM_AND(a, b) mrb_fixnum_value(mrb_fixnum(a) & mrb_fixnum(b))
    #define BC2CPP_FIXNUM_OR(a, b) mrb_fixnum_value(mrb_fixnum(a) | mrb_fixnum(b))
    #define BC2CPP_FIXNUM_XOR(a, b) mrb_fixnum_value(mrb_fixnum(a) ^ mrb_fixnum(b))
    static inline bool bc2cpp_fixnum_add(mrb_value a, mrb_value b, mrb_value& z) {
      mrb_int r;
      if (mrb_int_add_overflow(mrb_fixnum(a), mrb_fixnum(b), &r) || !FIXABLE(r)) return true;
      z = mrb_fixnum_value(r);
      return false;
    }
    static inline bool bc2cpp_fixnum_sub(mrb_value a, mrb_value b, mrb_value& z) {
      mrb_int r;
      if (mrb_int_sub_overflow(mrb_fixnum(a), mrb_fixnum(b), &r) || !FIXABLE(r)) return true;
      z = mrb_fixnum_value(r);
      return false;
    }
    static inline bool bc2cpp_fixnum_mul(mrb_value a, mrb_value b, mrb_value& z) {
      mrb_int r;
      if (mrb_int_mul_overflow(mrb_fixnum(a), mrb_fixnum(b), &r) || !FIXABLE(r)) return true;
      z = mrb_fixnum_value(r);
      return false;
    }
    #endif
  CPP

  OPS = { '+' => %w[bc2cpp_fixnum_add mrb_num_add], '-' => %w[bc2cpp_fixnum_sub mrb_num_sub],
          '*' => %w[bc2cpp_fixnum_mul mrb_num_mul] }.freeze

  # Both operands are Fixnums. Overflow runs mrb_num_* (Integer#+ etc.), which builds the heap Integer or bigint.
  # The result is a reference parameter: a `&rN` would keep a resumable step's registers in its frame
  # (RESUMABLE_REGISTER_ADDRESS).
  def tier(name, dest, rhs)
    helper, slow = OPS.fetch(name)
    "if (#{BranchHints.unlikely("#{helper}(r#{dest}, #{rhs}, r#{dest})")}) { r#{dest} = #{slow}(M, r#{dest}, #{rhs}); }"
  end

  def pair(left, right)
    "BC2CPP_FIXNUM_PAIR_P(#{left}, #{right})"
  end

  BITOPS = { '&' => 'BC2CPP_FIXNUM_AND', '|' => 'BC2CPP_FIXNUM_OR', '^' => 'BC2CPP_FIXNUM_XOR' }.freeze

  # `left op right` (& | ^) for two Fixnums, boxed.
  def bitop(left, op, right)
    "#{BITOPS.fetch(op)}(#{left}, #{right})"
  end

  # The boolean of `left op right` for two Fixnums: the tagged words order and compare like their values.
  def compare(left, op, right)
    "BC2CPP_FIXNUM_WORD(#{left}) #{op} BC2CPP_FIXNUM_WORD(#{right})"
  end
end
