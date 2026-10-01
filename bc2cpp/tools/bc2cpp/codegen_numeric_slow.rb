# frozen_string_literal: true

# CodeGen: NUMERIC_SLOW_PATH (ADR 0290). The else of a guarded numeric arm is one typed helper per
# operator that runs the C function the Integer/Float method (or vm.c's inline pair) runs for the
# operand tags, and dispatches by name only for a class it does not own. What it cannot match
# exactly (zero divisor, MRB_INT_MIN count, Float#%) stays on the by-name call.
class CodeGen
  NUMERIC_SLOW_PRELUDE = <<~CPP
    // NUMERIC_SLOW_PATH (ADR 0290): mruby's bigint entry points are declared only in
    // mruby/internal.h, which has no C linkage guard.
    #ifdef MRB_USE_BIGINT
    extern "C" mrb_value mrb_bint_div(mrb_state*, mrb_value, mrb_value);
    extern "C" mrb_value mrb_bint_mod(mrb_state*, mrb_value, mrb_value);
    extern "C" mrb_value mrb_bint_and(mrb_state*, mrb_value, mrb_value);
    extern "C" mrb_value mrb_bint_or(mrb_state*, mrb_value, mrb_value);
    extern "C" mrb_value mrb_bint_xor(mrb_state*, mrb_value, mrb_value);
    extern "C" mrb_value mrb_bint_lshift(mrb_state*, mrb_value, mrb_int);
    extern "C" mrb_value mrb_bint_rshift(mrb_state*, mrb_value, mrb_int);
    extern "C" mrb_value mrb_bint_new_int(mrb_state*, mrb_int);
    extern "C" mrb_value mrb_bint_add_ii(mrb_state*, mrb_int, mrb_int);
    extern "C" mrb_value mrb_bint_sub_ii(mrb_state*, mrb_int, mrb_int);
    extern "C" mrb_value mrb_bint_mul_ii(mrb_state*, mrb_int, mrb_int);
    extern "C" mrb_value mrb_as_bint(mrb_state*, mrb_value);
    #endif
    // mrb_bigint_p and mrb_float_p are FALSE in a build without them.
    static inline mrb_bool bc2cpp_slow_int_p(mrb_value v) { return mrb_integer_p(v) || mrb_bigint_p(v); }
    static inline mrb_bool bc2cpp_slow_num_p(mrb_value v) { return bc2cpp_slow_int_p(v) || mrb_float_p(v); }

  CPP

  # A result that may be a heap object is kept alive by one arena entry, what a by-name call
  # leaves; the temporaries of the body are dropped, so a loop does not grow the arena.
  NUMERIC_SLOW_DONE = <<~CPP.chomp
    mrb_gc_arena_restore(M, ai);
      mrb_gc_protect(M, r);
      return r;
  CPP

  NUMERIC_SLOW_ARITH = { 'add' => ['+', 'mrb_num_add'], 'sub' => ['-', 'mrb_num_sub'],
                         'mul' => ['*', 'mrb_num_mul'] }.freeze
  NUMERIC_SLOW_CMP = { 'lt' => '<', 'le' => '<=', 'gt' => '>', 'ge' => '>=' }.freeze
  NUMERIC_SLOW_BITS = { 'and' => ['&', 'mrb_bint_and'], 'or' => ['|', 'mrb_bint_or'],
                        'xor' => ['^', 'mrb_bint_xor'] }.freeze
  NUMERIC_SLOW_KEYS = { '+' => 'add', '-' => 'sub', '*' => 'mul', '<' => 'lt', '<=' => 'le', '>' => 'gt',
                        '>=' => 'ge', '/' => 'div', '%' => 'mod', '&' => 'and', '|' => 'or', '^' => 'xor',
                        '<<' => 'lshift', '>>' => 'rshift', '-@' => 'neg', 'zero?' => 'zero',
                        'round' => 'round' }.freeze

  # The call that finishes arm `name`; `float` selects the variant that also takes Float receivers.
  def numeric_slow_call(name, d, recv, argv, float: false)
    key = NUMERIC_SLOW_KEYS.fetch(name)
    "r#{d} = bc2cpp_slow_#{key}#{float ? '_f' : ''}(M, #{([recv] + argv).join(', ')});\n"
  end

  # Float#op may stay native while Integer's is Ruby (or the reverse): each receiver class is
  # admitted on its own.
  def numeric_slow_float_safe?(name, owners = %w[Integer Numeric])
    builtin_class_send_safe?(name, owners + ['Float'])
  end

  # File-scope definitions of the helpers `codes` call; '' when none.
  def emit_numeric_slow_helpers(codes)
    texts = codes.map { |c| c.is_a?(Hash) ? c[:code] : c }
    used = texts.flat_map { |t| t.scan(/\bbc2cpp_slow_([a-z]+)(_f)?\(M,/) }.uniq
    return '' if used.empty?

    NUMERIC_SLOW_PRELUDE + used.sort.map { |key, float| numeric_slow_source(key, float ? true : false) }.join
  end

  # How many sites call each helper, for the stderr summary.
  def numeric_slow_site_counts(codes)
    texts = codes.map { |c| c.is_a?(Hash) ? c[:code] : c }
    counts = Hash.new(0)
    texts.each { |t| t.scan(/= bc2cpp_slow_([a-z]+)(?:_f)?\(M,/) { |(key)| counts[key] += 1 } }
    counts.sort.to_h
  end

  private

  def numeric_slow_source(key, float)
    suffix = float ? '_f' : ''
    head = "static mrb_value bc2cpp_slow_#{key}#{suffix}(mrb_state* M, mrb_value a"
    if NUMERIC_SLOW_ARITH.key?(key)
      op, helper = NUMERIC_SLOW_ARITH.fetch(key)
      # Two Integers are vm.c OP_MATH: the overflow goes to mrb_bint_*_ii (Integer#op's mrb_bint_* path
      # mishandles an MRB_INT_MIN operand on the 32-bit targets). Everything else the VM sends, so it is
      # mrb_num_*, Integer#op's body for an Integer/bigint receiver and Float#op's for these operands
      # (a Complex operand keeps the method).
      float_arm = float ? ' || (mrb_float_p(a) && bc2cpp_slow_num_p(b))' : ''
      <<~CPP
        #{head}, mrb_value b) {
          if (!((bc2cpp_slow_int_p(a) && bc2cpp_slow_num_p(b))#{float_arm})) return mrb_funcall(M, a, "#{op}", 1, b);
          if (mrb_integer_p(a) && mrb_integer_p(b)) {
            mrb_int x = mrb_integer(a), y = mrb_integer(b), z;
            if (!mrb_int_#{key}_overflow(x, y, &z)) return mrb_int_value(M, z);
        #ifdef MRB_USE_BIGINT
            int ai = mrb_gc_arena_save(M);
            mrb_value r = mrb_bint_#{key}_ii(M, x, y);
            mrb_gc_arena_restore(M, ai);
            mrb_gc_protect(M, r);
            return r;
        #else
            mrb_state* mrb = M;  // E_RANGE_ERROR names the state `mrb`
            mrb_raise(M, E_RANGE_ERROR, "integer overflow");
        #endif
          }
          int ai = mrb_gc_arena_save(M);
          mrb_value r = #{helper}(M, a, b);
          #{NUMERIC_SLOW_DONE}
        }

      CPP
    elsif NUMERIC_SLOW_CMP.key?(key)
      op = NUMERIC_SLOW_CMP.fetch(key)
      <<~CPP
        #{head}, mrb_value b) {
          // num_lt & co. (cmpnum): a Float pair never gets here from an operator opcode, the inline
          // OP_CMP pairs in compile_cmp take it, so NaN keeps the method's answer for an explicit send.
          if (!bc2cpp_slow_num_p(a)) return mrb_funcall(M, a, "#{op}", 1, b);
          mrb_state* mrb = M;  // E_ARGUMENT_ERROR names the state `mrb`
          int ai = mrb_gc_arena_save(M);
          mrb_int c = mrb_cmp(M, a, b);
          if (c == -2) mrb_raisef(M, E_ARGUMENT_ERROR, "comparison of %t with %t failed", a, b);
          mrb_gc_arena_restore(M, ai);
          return mrb_bool_value(c #{op} 0);
        }

      CPP
    elsif key == 'div'
      # int_div; a Float receiver is the arm in front of this call.
      <<~CPP
        #{head}, mrb_value b) {
          if (!(bc2cpp_slow_int_p(a) && bc2cpp_slow_num_p(b))) return mrb_funcall(M, a, "/", 1, b);
          int ai = mrb_gc_arena_save(M);
          mrb_value r;
        #ifndef MRB_NO_FLOAT
          if (mrb_float_p(b)) r = mrb_float_value(M, mrb_div_float(mrb_as_float(M, a), mrb_float(b)));
          else
        #endif
        #ifdef MRB_USE_BIGINT
          if (mrb_bigint_p(a)) r = mrb_bint_div(M, a, b);
          else if (mrb_bigint_p(b)) r = mrb_bint_div(M, mrb_as_bint(M, a), b);
          else
        #endif
          r = mrb_div_int_value(M, mrb_integer(a), mrb_integer(b));
          #{NUMERIC_SLOW_DONE}
        }

      CPP
    elsif key == 'mod'
      # int_mod for two Integers; a Float operand needs flodivmod (static), a zero divisor
      # the method's ZeroDivisionError.
      <<~CPP
        #{head}, mrb_value b) {
          if (!(bc2cpp_slow_int_p(a) && bc2cpp_slow_int_p(b))) return mrb_funcall(M, a, "%", 1, b);
          int ai = mrb_gc_arena_save(M);
          mrb_value r;
        #ifdef MRB_USE_BIGINT
          if (mrb_bigint_p(a)) r = mrb_bint_mod(M, a, b);
          else if (mrb_bigint_p(b)) r = mrb_bint_mod(M, mrb_as_bint(M, a), b);
          else
        #endif
          {
            mrb_int x = mrb_integer(a), y = mrb_integer(b);
            if (x == 0) return a;
            if (y == 0) return mrb_funcall(M, a, "%", 1, b);
            if (x == MRB_INT_MIN && y == -1) return mrb_fixnum_value(0);
            mrb_int mod = x % y;
            if ((x < 0) != (y < 0) && mod != 0) mod += y;
            r = mrb_int_value(M, mod);
          }
          #{NUMERIC_SLOW_DONE}
        }

      CPP
    elsif NUMERIC_SLOW_BITS.key?(key)
      op, bint = NUMERIC_SLOW_BITS.fetch(key)
      # int_and/int_or/int_xor; a Float operand is the method's own (mis)read of the operand.
      <<~CPP
        #{head}, mrb_value b) {
          if (!(bc2cpp_slow_int_p(a) && bc2cpp_slow_int_p(b))) return mrb_funcall(M, a, "#{op}", 1, b);
          int ai = mrb_gc_arena_save(M);
          mrb_value r;
        #ifdef MRB_USE_BIGINT
          if (mrb_bigint_p(a)) r = #{bint}(M, a, b);
          else if (mrb_bigint_p(b)) r = #{bint}(M, mrb_as_bint(M, a), b);
          else
        #endif
          r = mrb_int_value(M, mrb_integer(a) #{op} mrb_integer(b));
          #{NUMERIC_SLOW_DONE}
        }

      CPP
    elsif %w[lshift rshift].include?(key)
      numeric_slow_shift_source(key, head)
    elsif key == 'neg'
      # Numeric#-@ is `0 - self`, evaluated by OP_SUB: an Integer overflows into mrb_bint_sub_ii (not
      # Integer#-, whose MRB_INT_MIN operand is wrong in the bigint core), a bigint takes Integer#-, a
      # Float the inline 0 - float (so -0.0 stays +0.0).
      float_arm = float ? "\n#ifndef MRB_NO_FLOAT\n  if (mrb_float_p(a)) {\n    int ai = mrb_gc_arena_save(M);\n    " \
                          "mrb_value r = mrb_float_value(M, (mrb_float)0 - mrb_float(a));\n    " \
                          "mrb_gc_arena_restore(M, ai);\n    mrb_gc_protect(M, r);\n    return r;\n  }\n#endif" : ''
      <<~CPP
        #{head}) {
        #ifdef MRB_USE_BIGINT
          if (mrb_integer_p(a)) {
            mrb_int x = mrb_integer(a), z;
            if (!mrb_int_sub_overflow(0, x, &z)) return mrb_int_value(M, z);
            int ai = mrb_gc_arena_save(M);
            mrb_value r = mrb_bint_sub_ii(M, 0, x);
            mrb_gc_arena_restore(M, ai);
            mrb_gc_protect(M, r);
            return r;
          }
          if (mrb_bigint_p(a)) {
            int ai = mrb_gc_arena_save(M);
            mrb_value r = mrb_num_sub(M, mrb_fixnum_value(0), a);
            mrb_gc_arena_restore(M, ai);
            mrb_gc_protect(M, r);
            return r;
          }
        #endif#{float_arm}
          return mrb_funcall(M, a, "-@", 0);
        }

      CPP
    elsif key == 'zero'
      # Numeric#zero? is `self == 0`; a Float compares as the VM's inline (Float, Integer) pair.
      <<~CPP
        #{head}) {
        #ifndef MRB_NO_FLOAT
          if (mrb_float_p(a)) return mrb_bool_value(mrb_float(a) == 0);
        #endif
          return mrb_funcall(M, a, "zero?", 0);
        }

      CPP
    elsif key == 'round'
      # int_round with no digits returns self, a bigint included.
      <<~CPP
        #{head}) {
          if (mrb_bigint_p(a)) return a;
          return mrb_funcall(M, a, "round", 0);
        }

      CPP
    else
      raise "unknown NUMERIC_SLOW_PATH helper #{key}"
    end
  end

  # int_lshift / int_rshift for an Integer count; MRB_INT_MIN, a Float or bigint count keep the method.
  def numeric_slow_shift_source(key, head)
    left = key == 'lshift'
    op = left ? '<<' : '>>'
    bint = left ? 'mrb_bint_lshift' : 'mrb_bint_rshift'
    shift = left ? 'width' : '-width'
    <<~CPP
      #{head}, mrb_value b) {
        if (!(bc2cpp_slow_int_p(a) && mrb_integer_p(b) && mrb_integer(b) != MRB_INT_MIN)) return mrb_funcall(M, a, "#{op}", 1, b);
        mrb_int width = mrb_integer(b);
        if (width == 0) return a;
        int ai = mrb_gc_arena_save(M);
        mrb_value r;
      #ifdef MRB_USE_BIGINT
        if (mrb_bigint_p(a)) r = #{bint}(M, a, width);
        else
      #endif
        {
          mrb_int val = mrb_integer(a);
          if (val == 0) return a;
          if (mrb_num_shift(M, val, #{shift}, &val)) {
            r = mrb_int_value(M, val);
          } else {
      #ifdef MRB_USE_BIGINT
            r = #{bint}(M, mrb_bint_new_int(M, val), width);
      #else
            return mrb_funcall(M, a, "#{op}", 1, b);
      #endif
          }
        }
        #{NUMERIC_SLOW_DONE}
      }

    CPP
  end
end
