# frozen_string_literal: true

# CodeGen: NUMERIC_SLOW_PATH (ADR 0292). The else of a guarded numeric arm is one typed helper per
# operator that runs the C function the Integer/Float method (or vm.c's inline pair) runs for the
# operand tags, and dispatches by name only for a class it does not own. What it cannot match
# exactly (zero divisor, MRB_INT_MIN count, Float#%) stays on the by-name call.
class CodeGen
  NUMERIC_SLOW_PRELUDE = <<~CPP
    // NUMERIC_SLOW_PATH (ADR 0292): mruby's bigint entry points are declared only in
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

  # NUMERIC_SLOW_CLOSED (ADR 0360, 0361): operators whose every definer in the build is on these classes, which the
  # helper's own arms cover, so its by-name fallback is dead and becomes a proven NoMethodError. `-` is absent:
  # Array#- (mruby-array-ext) is a hash/`==` walk with no public entry point to mirror.
  NUMERIC_SLOW_CLOSED = { '/' => %w[Integer Float], '+' => %w[Integer Float Array String],
                          '*' => %w[Integer Float Array String] }.freeze

  # `members` is CallFacts::Answers' set of every class that may answer `name`; it is nil for a name
  # nothing bounds (computed installers, Object/Kernel definers, unreadable native owners). `owners` are the
  # classes whose method the helper's arms run.
  def numeric_slow_closed?(name)
    owners = NUMERIC_SLOW_CLOSED[name]
    return false unless owners && ENV['BC2CPP_NUMERIC_SLOW_CLOSED'] != '0'
    return false unless @closed_world && @native_name_sources && @closed_world.global_refusal.nil?
    return false unless @closed_world.exact_instances_singleton_free? && @closed_world.method_missing_classes.empty?

    answers = call_facts_answers
    definers = answers.definers(name)
    return false if definers.nil? || definers[:singleton]
    return false unless %i[ruby foreign modules].all? { |kind| definers[kind].empty? }

    members = numeric_slow_members(answers, name)
    !members.nil? && members.all? { |klass| numeric_slow_inherits_owner?(answers, klass, owners) }
  end

  # `klass` is an owner, or a class whose whole lookup path is known and runs through an owner: with no Ruby, module
  # or foreign definer of the name it resolves to the owner's native method, whose tag the helper switches on.
  def numeric_slow_inherits_owner?(answers, klass, owners)
    return true if owners.include?(klass)

    ancestors, unknown = answers.ancestors(klass)
    !unknown && ancestors.any? { |name| owners.include?(name) }
  end

  # `members` less Time and its subclasses when mruby-time is not in the build's gem list: the host scan reads
  # every core gem's sources, and `Time#+` / `Time#-` are static in mruby-time (no mirror possible).
  def numeric_slow_members(answers, name)
    members = answers.members(name)
    gems = CodeGen.build_gem_names
    return members if members.nil? || gems.nil? || gems.include?('mruby-time')

    timed = members.select { |k| answers.ancestors(k).first.include?('Time') }
    return members if timed.any? { |k| @closed_world.class_declared?(k) }

    members - timed
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
      open_form = numeric_slow_arith_source(key, op, helper, head, float)
      return open_form unless numeric_slow_closed?(op)

      # A build that links the Complex or Rational gem has more definers than the world scan lists.
      "#if defined(MRB_USE_COMPLEX) || defined(MRB_USE_RATIONAL)\n#{open_form}" \
        "#else\n#{numeric_slow_closed_arith_source(key, op, helper, head)}#endif\n"
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
    elsif key == 'div' && numeric_slow_closed?('/')
      # A build that links the Complex or Rational gem has more `/` definers than the world scan lists.
      "#if defined(MRB_USE_COMPLEX) || defined(MRB_USE_RATIONAL)\n#{numeric_slow_div_source(head)}" \
        "#else\n#{numeric_slow_closed_div_source(head)}#endif\n"
    elsif key == 'div'
      numeric_slow_div_source(head)
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

  # The by-name form of `+ - *` (ADR 0292).
  def numeric_slow_arith_source(key, op, helper, head, float)
    # Two Integers are vm.c OP_MATH: the overflow goes to mrb_bint_*_ii (Integer#op's mrb_bint_* path
    # mishandles an MRB_INT_MIN operand on the 32-bit targets). Everything else the VM sends, so it is
    # mrb_num_*, Integer#op's body for an Integer/bigint receiver and Float#op's for these operands
    # (a Complex operand keeps the method).
    float_arm = float ? ' || (mrb_float_p(a) && bc2cpp_slow_num_p(b))' : ''
    <<~CPP
      #{head}, mrb_value b) {
        if (!((bc2cpp_slow_int_p(a) && bc2cpp_slow_num_p(b))#{float_arm})) return mrb_funcall(M, a, "#{op}", 1, b);
      #{numeric_slow_int_pair_source(key)}
        int ai = mrb_gc_arena_save(M);
        mrb_value r = #{helper}(M, a, b);
        #{NUMERIC_SLOW_DONE}
      }

    CPP
  end

  # The two-Fixnum arm of `+ - *`, shared by the by-name and the closed forms: it always returns.
  def numeric_slow_int_pair_source(key)
    <<~CPP.chomp.gsub(/^(?=[^#\n])/, '  ')
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
    CPP
  end

  # NUMERIC_SLOW_CLOSED `+` and `*` (ADR 0361): Integer, bigint and Float take mrb_num_*, Integer#op's and Float#op's
  # body (a non-numeric operand is its TypeError); String and Array take the C++ of mrb_str_plus_m, mrb_str_times,
  # mrb_ary_plus and mrb_ary_times, built from the public entry points they call; no other class answers.
  def numeric_slow_closed_arith_source(key, op, helper, head)
    arms = key == 'add' ? numeric_slow_closed_plus_arms : numeric_slow_closed_times_arms
    <<~CPP
      #{head}, mrb_value b) {
      #{numeric_slow_int_pair_source(key)}
        mrb_state* mrb = M;  // E_ARGUMENT_ERROR names the state `mrb`
        int ai = mrb_gc_arena_save(M);
        mrb_value r;
        if (bc2cpp_slow_int_p(a)) {
          r = #{helper}(M, a, b);
        }
      #ifndef MRB_NO_FLOAT
        else if (mrb_float_p(a)) {
          r = #{helper}(M, a, b);
        }
      #endif
        else if (mrb_string_p(a)) {
      #{arms.fetch(:string)}
        }
        else if (mrb_array_p(a)) {
      #{arms.fetch(:array)}
        }
        else {
          return bc2cpp_nomethod_named(M, a, "#{op}", 1, b);
        }
        #{NUMERIC_SLOW_DONE}
      }

    CPP
  end

  def numeric_slow_closed_plus_arms
    {
      string: '    r = mrb_str_plus(M, a, mrb_ensure_string_type(M, b));',
      array: <<~CPP.chomp.gsub(/^(?=.)/, '    ')
        mrb_ensure_array_type(M, b);
        mrb_int total;
        if (mrb_int_add_overflow(RARRAY_LEN(a), RARRAY_LEN(b), &total)) mrb_raise(M, E_ARGUMENT_ERROR, "array size too big");
        r = mrb_ary_new_capa(M, total);
        mrb_ary_concat(M, r, a);
        mrb_ary_concat(M, r, b);
      CPP
    }
  end

  def numeric_slow_closed_times_arms
    {
      string: <<~'CPP'.chomp.gsub(/^(?=.)/, '    '),
        mrb_int times = mrb_as_int(M, b), len;
        if (times < 0) mrb_raise(M, E_ARGUMENT_ERROR, "negative argument");
        if (mrb_int_mul_overflow(RSTRING_LEN(a), times, &len)) mrb_raise(M, E_ARGUMENT_ERROR, "argument too big");
        r = mrb_str_new(M, NULL, len);
        char* p = RSTRING_PTR(r);
        if (len > 0) {
          mrb_int n = RSTRING_LEN(a);
          memcpy(p, RSTRING_PTR(a), n);
          while (n <= len / 2) {
            memcpy(p + n, p, n);
            n *= 2;
          }
          memcpy(p + n, p, len - n);
        }
        p[len] = '\0';
        RSTR_COPY_SINGLE_BYTE_FLAG(mrb_str_ptr(r), mrb_str_ptr(a));
      CPP
      array: <<~CPP.chomp.gsub(/^(?=.)/, '    ')
        mrb_value sep = mrb_check_string_type(M, b);
        if (!mrb_nil_p(sep)) {
          r = mrb_ary_join(M, a, sep);
        }
        else {
          mrb_int times = mrb_as_int(M, b), total;
          if (times < 0) mrb_raise(M, E_ARGUMENT_ERROR, "negative argument");
          if (times == 0) {
            r = mrb_ary_new(M);
          }
          else {
            if (mrb_int_mul_overflow(RARRAY_LEN(a), times, &total)) mrb_raise(M, E_ARGUMENT_ERROR, "array size too big");
            r = mrb_ary_new_capa(M, total);
            if (total > 0) for (mrb_int i = 0; i < times; i++) mrb_ary_concat(M, r, a);
          }
        }
      CPP
    }
  end

  # int_div; a Float receiver is the arm in front of this call.
  def numeric_slow_div_source(head)
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
  end

  # int_div and flo_div with no Complex or Rational operand (the caller selects this form only when those gems'
  # macros are unset); any other receiver class answers `/` nowhere, which is what the dispatch raised.
  def numeric_slow_closed_div_source(head)
    <<~CPP
      #{head}, mrb_value b) {
        mrb_state* mrb = M;  // E_TYPE_ERROR names the state `mrb`
        int ai = mrb_gc_arena_save(M);
        mrb_value r;
        if (bc2cpp_slow_int_p(a)) {
          if (!bc2cpp_slow_num_p(b)) mrb_raisef(M, E_TYPE_ERROR, "can't convert %Y into Integer", b);
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
        }
      #ifndef MRB_NO_FLOAT
        else if (mrb_float_p(a)) {
          r = mrb_float_value(M, mrb_div_float(mrb_float(a), mrb_as_float(M, b)));
        }
      #endif
        else {
          return bc2cpp_nomethod_named(M, a, "/", 1, b);
        }
        #{NUMERIC_SLOW_DONE}
      }

    CPP
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
