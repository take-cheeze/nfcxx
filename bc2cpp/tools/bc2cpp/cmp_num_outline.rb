# frozen_string_literal: true

# CMP_NUM_OUTLINE: the arms of OP_EQ/OP_LT/... (compile_cmp) and NEQ_OP_EQ past the Fixnum pair run in one shared
# helper per operator instead of inline at every site. They take a heap Integer or a Float, which on word boxing are
# out-of-line reads (mrb_integer_func, mrb_word_boxing_value_float) and soft-float compares at each site. A helper
# holds exactly the arms it replaces, in their order, and answers mrb_undef where the inline chain reached its
# fallback, which stays at the site.
module CmpNumOutline
  OPS = { 'lt' => '<', 'le' => '<=', 'gt' => '>', 'ge' => '>=' }.freeze
  KEYS = OPS.invert.freeze

  module_function

  # BC2CPP_CMP_NUM_OUTLINE=0 keeps the inline arms.
  def on?
    ENV['BC2CPP_CMP_NUM_OUTLINE'] != '0'
  end

  def helper(sym)
    sym == '==' ? 'bc2cpp_cmp_num_eq' : "bc2cpp_cmp_num_#{KEYS.fetch(sym)}"
  end

  def float_arms(sym)
    <<~CPP.chomp
      #ifndef MRB_NO_FLOAT
        if (mrb_integer_p(d) && mrb_float_p(s)) return mrb_bool_value(mrb_integer(d) #{sym} mrb_float(s));
        if (mrb_float_p(d) && mrb_integer_p(s)) return mrb_bool_value(mrb_float(d) #{sym} mrb_integer(s));
        if (mrb_float_p(d) && mrb_float_p(s)) return mrb_bool_value(mrb_float(d) #{sym} mrb_float(s));
      #endif
    CPP
  end

  # The ordering helpers are compile_cmp's numeric_dispatch; the EQ one is its INTEGER_PAIR_EQ arm, identity, the
  # Symbol answer and then numeric_dispatch, whose Integer pair the first arm already took.
  RUNTIME = (OPS.map do |key, sym|
    <<~CPP
      [[gnu::noinline]] inline mrb_value bc2cpp_cmp_num_#{key}(mrb_state* M, mrb_value d, mrb_value s) {
        (void)M;
        if (mrb_integer_p(d) && mrb_integer_p(s)) {
      #ifdef MRB_NO_FLOAT
          return mrb_bool_value(mrb_fixnum(d) #{sym} mrb_fixnum(s));
      #else
          return mrb_bool_value(mrb_integer(d) #{sym} mrb_integer(s));
      #endif
        }
      #{float_arms(sym)}
        return mrb_undef_value();
      }
    CPP
  end.join + <<~CPP).freeze
    [[gnu::noinline]] inline mrb_value bc2cpp_cmp_num_eq(mrb_state* M, mrb_value d, mrb_value s) {
      if (mrb_integer_p(d) && mrb_integer_p(s)) return mrb_bool_value(mrb_integer(d) == mrb_integer(s));
      if (mrb_obj_eq(M, d, s)) return mrb_true_value();
      if (mrb_symbol_p(d)) return mrb_false_value();
    #{float_arms('==')}
      return mrb_undef_value();
    }
  CPP

  # `if (fixnum pair) {...} else ` is +fixnum_arm+; the helper's answer lands in `dest`, the fallback runs on undef.
  def dispatch(fixnum_arm, sym, dest, left, right, fallback, negate: false)
    answer = negate ? 'mrb_bool_value(mrb_false_p(bc2cpp_nt))' : 'bc2cpp_nt'
    "{ mrb_value bc2cpp_nt;\n#{fixnum_arm}if (!mrb_undef_p(bc2cpp_nt = #{helper(sym)}(M, #{left}, #{right}))) {\n  " \
      "#{dest} = #{answer};\n} else {\n#{fallback.chomp}\n}\n}\n"
  end
end
