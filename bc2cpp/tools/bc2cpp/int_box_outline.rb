# frozen_string_literal: true

# Integer boxing the generated code can do without mrb_int_value / mrb_integer, which on word boxing are out-of-line
# calls that also handle a heap Integer.
#
# UPVAR_PTR_FIXNUM: a block env carries the addresses of the builder's registers. They are mrb_value-aligned, so the
# address >> 2 is a Fixnum wherever UINTPTR_MAX >> 2 fits MRB_FIXNUM_MAX (bc2cpp_upvar_ptr_fits); elsewhere the slot
# keeps the mrb_int_value form. Writer and reader are this module's, the only ones of an upvar slot.
#
# SIZE_FIXNUM: an Array length or Hash size counts elements of at least sizeof(mrb_value) bytes in one address space,
# so it is at most SIZE_MAX / sizeof(mrb_value); where that bound is FIXABLE (bc2cpp_size_fits) the box is immediate.
#
# INT_PAIR_OUTLINE: mrb_as_int is two out-of-line calls (mrb_ensure_int_type, mrb_integer_func) and Integer#/ of a
# pair three; one shared helper per form runs the same calls in the same order.
module IntBoxOutline
  module_function

  def upvar_on?
    ENV['BC2CPP_UPVAR_PTR_FIXNUM'] != '0'
  end

  def size_on?
    ENV['BC2CPP_SIZE_FIXNUM'] != '0'
  end

  def pair_on?
    ENV['BC2CPP_INT_PAIR_OUTLINE'] != '0'
  end

  # The env slot for register address `expr`, or nil for the mrb_int_value form.
  def upvar_write(expr)
    upvar_on? ? "bc2cpp_upvar_ptr_value(M, #{expr})" : nil
  end

  def upvar_read(slot)
    upvar_on? ? "bc2cpp_upvar_ptr(#{slot})" : "reinterpret_cast<mrb_value*>(static_cast<uintptr_t>(mrb_integer(#{slot})))"
  end

  SIZE_BOXES = [['mrb_int_value(M, ARY_LEN(', 'bc2cpp_size_value(M, ARY_LEN('],
                ['mrb_int_value(M, (mrb_hash_size(M, ', 'bc2cpp_size_value(M, (mrb_hash_size(M, ']].freeze

  # A native C expression (NativeExpressionDevirt) with its length box made immediate.
  def size_boxed(expression)
    return expression unless size_on?

    SIZE_BOXES.reduce(expression) { |text, (from, to)| text.start_with?(from) ? to + text[from.size..] : text }
  end

  def div_pair(dest, left, right)
    return "#{dest} = bc2cpp_div_int_pair(M, #{left}, #{right});" if pair_on?

    "#{dest} = mrb_div_int_value(M, mrb_integer(#{left}), mrb_integer(#{right}));"
  end

  RUNTIME = <<~CPP
    // UPVAR_PTR_FIXNUM, SIZE_FIXNUM, INT_PAIR_OUTLINE (int_box_outline.rb).
    static_assert(alignof(mrb_value) >= 4, "UPVAR_PTR_FIXNUM: a register address has two clear low bits");
    #define bc2cpp_upvar_ptr_fits ((uintmax_t)(UINTPTR_MAX >> 2) <= (uintmax_t)MRB_FIXNUM_MAX)
    static inline mrb_value bc2cpp_upvar_ptr_value(mrb_state* M, mrb_value* p) {
      if (bc2cpp_upvar_ptr_fits) return mrb_fixnum_value((mrb_int)((uintptr_t)p >> 2));
      return mrb_int_value(M, static_cast<mrb_int>(reinterpret_cast<uintptr_t>(p)));
    }
    static inline mrb_value* bc2cpp_upvar_ptr(mrb_value v) {
      if (bc2cpp_upvar_ptr_fits) return reinterpret_cast<mrb_value*>((uintptr_t)mrb_fixnum(v) << 2);
      return reinterpret_cast<mrb_value*>(static_cast<uintptr_t>(mrb_integer(v)));
    }
    #define bc2cpp_size_fits ((uintmax_t)(SIZE_MAX / sizeof(mrb_value)) <= (uintmax_t)MRB_FIXNUM_MAX)
    static inline mrb_value bc2cpp_size_value(mrb_state* M, mrb_int n) {
      if (bc2cpp_size_fits) return mrb_fixnum_value(n);
      return mrb_int_value(M, n);
    }
    // mruby/internal.h has no C linkage guard.
    extern "C" mrb_value mrb_div_int_value(mrb_state*, mrb_int, mrb_int);
    [[gnu::noinline]] inline mrb_value bc2cpp_div_int_pair(mrb_state* M, mrb_value a, mrb_value b) {
      return mrb_div_int_value(M, mrb_integer(a), mrb_integer(b));
    }
  CPP

  # mrb_as_int keeps its spelling at every site (mruby.h's macro); the one call it becomes holds both reads.
  AS_INT = <<~CPP
    [[gnu::noinline]] inline mrb_int bc2cpp_as_int(mrb_state* M, mrb_value v) { return mrb_as_int(M, v); }
    #undef mrb_as_int
    #define mrb_as_int(mrb, val) bc2cpp_as_int(mrb, val)
  CPP
end
