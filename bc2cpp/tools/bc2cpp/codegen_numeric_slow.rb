# frozen_string_literal: true

# CodeGen: NUMERIC_SLOW_PATH (ADR 0292). The else of a guarded numeric arm is one typed helper per
# operator that runs the C function the Integer/Float method (or vm.c's inline pair) runs for the
# operand tags, and dispatches by name only for a class it does not own. What it cannot match
# exactly (zero divisor, MRB_INT_MIN count, Float#%) stays on the by-name call.
class CodeGen
  class << self
    # CoreCompare::OPS the build's core sources still match (ADR 0362); nil proves nothing.
    attr_accessor :core_compare
  end

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

  # NUMERIC_SLOW_CLOSED (ADR 0360, 0361, 0364): operators whose every definer in the build is on these classes, which
  # the helper's own arms cover, so its by-name fallback is dead and becomes a proven NoMethodError. `-` is absent:
  # Array#- (mruby-array-ext) is a hash/`==` walk with no public entry point to mirror.
  NUMERIC_SLOW_CLOSED = { '/' => %w[Integer Float], '+' => %w[Integer Float Array String],
                          '*' => %w[Integer Float Array String], '^' => %w[Integer NilClass TrueClass FalseClass],
                          '>>' => %w[Integer], 'round' => %w[Integer Float] }.freeze

  # `members` is CallFacts::Answers' set of every class that may answer `name`; it is nil for a name
  # nothing bounds (computed installers, Object/Kernel definers, unreadable native owners). `owners` are the
  # classes whose method the helper's arms run.
  def numeric_slow_closed?(name)
    owners = NUMERIC_SLOW_CLOSED[name]
    return false unless owners && numeric_slow_closed_world?

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

  # NUMERIC_SLOW_CLOSED_CMP (ADR 0362): `<` `<=` `>` `>=` are answered by the numeric natives, Comparable's Ruby
  # body (String, Symbol and any Numeric that is not an Integer or Float, through the mixin) and the Hash subset
  # tests. The helper mirrors the first two and keeps the by-name call for Hash; every other receiver is a proven
  # NoMethodError.
  NUMERIC_SLOW_CMP_OWNERS = %w[Integer Float Numeric String Symbol Hash].freeze
  # Where `<=>` of a String, a Symbol or another Numeric is looked up; no Ruby may define it there, which keeps it
  # an Integer or nil answer (`cmp < 0`), and String's and Symbol's are the natives mrb_cmp reads directly.
  NUMERIC_SLOW_CMP_LOOKUP = %w[String Symbol Numeric Comparable Object Kernel BasicObject].freeze
  NUMERIC_SLOW_SPACESHIP = { 'String' => 'mrb_str_cmp_m', 'Symbol' => 'sym_cmp' }.freeze

  def numeric_slow_closed_cmp?(name)
    return false unless NUMERIC_SLOW_CMP.value?(name) && numeric_slow_closed_world?

    @numeric_slow_closed_cmp ||= {}
    @numeric_slow_closed_cmp.fetch(name) { @numeric_slow_closed_cmp[name] = numeric_slow_cmp_proof(name) }
  end

  # The Comparable body this arm mirrors is the build's own, and nothing but the numeric natives, that body and
  # Hash's Ruby answers `name` (members), so only String and Symbol reach it.
  def numeric_slow_cmp_proof(name)
    return false unless self.class.core_compare&.include?(name)

    answers = call_facts_answers
    definers = answers.definers(name)
    return false if definers.nil? || definers[:singleton] || !definers[:ruby].empty? || !definers[:modules].empty?
    return false unless definers[:foreign].subset?(%w[Comparable Hash].to_set)
    return false unless definers[:native].subset?(%w[Integer Float Numeric].to_set)

    members = answers.members(name)
    !members.nil? && members.subset?(NUMERIC_SLOW_CMP_OWNERS.to_set) && numeric_slow_spaceship_core?(answers)
  end

  # Comparable's `self <=> other` is mrb_cmp: it calls mrb_str_cmp for a String and dispatches `<=>` otherwise, and
  # `cmp < 0` needs an Integer or nil answer, so no Ruby `<=>` may sit on the receivers' lookup (ADR 0362).
  def numeric_slow_spaceship_core?(answers)
    return false unless core_ancestry(*NUMERIC_SLOW_CMP_LOOKUP)
    return false unless NUMERIC_SLOW_CMP_LOOKUP.all? { |owner| @closed_world.core_native_arm_safe?('<=>', owner) }

    installed = symbol_installed_names
    return false if installed.nil? || installed.include?('<=>') || devirt_blocked_name?('<=>')
    return false if answers.opaque_owners.fetch('<=>', []).any? { |owner| owner.nil? || NUMERIC_SLOW_CMP_LOOKUP.include?(owner) }
    return false if @registry.fetch('<=>', []).any? { |d| NUMERIC_SLOW_CMP_LOOKUP.include?(d.owner) }

    natives = answers.registrations.fetch('<=>', []).group_by { |e| e[:owner]&.fetch(:class_name, nil) }
    NUMERIC_SLOW_SPACESHIP.all? do |owner, function|
      entries = natives.fetch(owner, [])
      entries.size == 1 && entries.first[:function] == function && entries.first[:path].end_with?("/src/#{owner.downcase}.c")
    end && !natives.key?(nil)
  end

  def numeric_slow_closed_world?
    ENV['BC2CPP_NUMERIC_SLOW_CLOSED'] != '0' && @closed_world && @native_name_sources && @closed_world.global_refusal.nil? &&
      @closed_world.exact_instances_singleton_free? && @closed_world.method_missing_classes.empty?
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
    head = numeric_slow_head(key, float)
    closed = numeric_slow_closed_source(key, head)
    return numeric_slow_open_source(key, head, float) unless closed

    # A build that links the Complex or Rational gem has more definers (or receivers) than the world scan lists
    # (`/`, `+ *`, `< <= > >=`, `round`, `% -@`), so it keeps the by-name body.
    "#if defined(MRB_USE_COMPLEX) || defined(MRB_USE_RATIONAL)\n#{numeric_slow_open_source(key, head, float)}" \
      "#else\n#{closed}#endif\n"
  end

  def numeric_slow_head(key, float)
    "static mrb_value bc2cpp_slow_#{key}#{float ? '_f' : ''}(mrb_state* M, mrb_value a"
  end

  # The closed form of helper `key`, or nil when its operator is not proven closed in this world (each key is
  # independent: `+ *` ADR 0361, `< <= > >=` ADR 0362, `/` ADR 0360, `^ >> round` ADR 0364, `% -@` ADR 0367).
  def numeric_slow_closed_source(key, head)
    op = NUMERIC_SLOW_KEYS.key(key)
    if NUMERIC_SLOW_ARITH.key?(key)
      return nil unless numeric_slow_closed?(op)

      numeric_slow_closed_arith_source(key, op, NUMERIC_SLOW_ARITH.fetch(key).last, head)
    elsif NUMERIC_SLOW_CMP.key?(key)
      numeric_slow_closed_cmp?(op) ? numeric_slow_closed_cmp_source(head, op) : nil
    elsif %w[mod neg].include?(key)
      misc = numeric_slow_misc(op)
      return nil unless misc

      key == 'mod' ? numeric_slow_closed_mod_source(head, misc) : numeric_slow_closed_neg_source(head, misc)
    elsif numeric_slow_closed?(op)
      case key
      when 'div' then numeric_slow_closed_div_source(head)
      when 'xor' then numeric_slow_closed_xor_source(head)
      when 'rshift' then numeric_slow_closed_rshift_source(head)
      when 'round' then numeric_slow_closed_round_source(head)
      else raise "no closed form for NUMERIC_SLOW_PATH helper #{key}"
      end
    end
  end

  def numeric_slow_open_source(key, head, float)
    if NUMERIC_SLOW_ARITH.key?(key)
      op, helper = NUMERIC_SLOW_ARITH.fetch(key)
      numeric_slow_arith_source(key, op, helper, head, float)
    elsif NUMERIC_SLOW_CMP.key?(key)
      numeric_slow_cmp_source(head, NUMERIC_SLOW_CMP.fetch(key))
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

  def numeric_slow_cmp_source(head, op)
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

  # CMP_CLOSED (ADR 0362). Integer and Float are num_lt & co.; a String, a Symbol and any other Numeric are
  # Comparable's body, whose `<=>` is mrb_cmp's (the message names `.class`, hence %T, not num_lt's %t); a Hash keeps
  # the method, Ruby over `==` of its values; any other receiver answers `#{op}` nowhere.
  def numeric_slow_closed_cmp_source(head, op)
    <<~CPP
      #{head}, mrb_value b) {
        mrb_state* mrb = M;  // E_ARGUMENT_ERROR names the state `mrb`
        int ai = mrb_gc_arena_save(M);
        mrb_int c;
        if (bc2cpp_slow_num_p(a)) {
          c = mrb_cmp(M, a, b);
          if (c == -2) mrb_raisef(M, E_ARGUMENT_ERROR, "comparison of %t with %t failed", a, b);
        } else if (mrb_string_p(a) || mrb_symbol_p(a) || mrb_obj_is_kind_of(M, a, mrb_class_get(M, "Numeric"))) {
          c = mrb_cmp(M, a, b);
          if (c == -2) mrb_raisef(M, E_ARGUMENT_ERROR, "comparison of %T with %T failed", a, b);
        } else if (mrb_type(a) == MRB_TT_HASH) {
          return mrb_funcall(M, a, "#{op}", 1, b);
        } else {
          return bc2cpp_nomethod_named(M, a, "#{op}", 1, b);
        }
        mrb_gc_arena_restore(M, ai);
        return mrb_bool_value(c #{op} 0);
      }

    CPP
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

  # int_xor, true_xor, false_xor (nil shares false's): an Integer operand is read as the method reads it, any
  # other operand only through mrb_test; every other receiver class answers `^` nowhere.
  def numeric_slow_closed_xor_source(head)
    <<~CPP
      #{head}, mrb_value b) {
        if (bc2cpp_slow_int_p(a)) {
          int ai = mrb_gc_arena_save(M);
          mrb_value r;
      #ifdef MRB_USE_BIGINT
          if (mrb_bigint_p(a)) r = mrb_bint_xor(M, a, b);
          else if (mrb_bigint_p(b)) r = mrb_bint_xor(M, mrb_as_bint(M, a), b);
          else
      #endif
          r = mrb_int_value(M, mrb_integer(a) ^ mrb_integer(b));
          #{NUMERIC_SLOW_DONE}
        }
        if (mrb_nil_p(a) || mrb_false_p(a)) return mrb_bool_value(mrb_test(b));
        if (mrb_true_p(a)) return mrb_bool_value(!mrb_test(b));
        return bc2cpp_nomethod_named(M, a, "^", 1, b);
      }

    CPP
  end

  # int_rshift for any count the method accepts (mrb_as_int coerces it); Integer is the only receiver class.
  def numeric_slow_closed_rshift_source(head)
    <<~CPP
      #{head}, mrb_value b) {
        if (!bc2cpp_slow_int_p(a)) return bc2cpp_nomethod_named(M, a, ">>", 1, b);
        mrb_state* mrb = M;  // E_RANGE_ERROR names the state `mrb`
        mrb_int width = mrb_as_int(M, b);
        if (width == 0) return a;
        if (width == MRB_INT_MIN) mrb_raise(M, E_RANGE_ERROR, "integer overflow in bit shift");
        int ai = mrb_gc_arena_save(M);
        mrb_value r;
      #ifdef MRB_USE_BIGINT
        if (mrb_bigint_p(a)) r = mrb_bint_rshift(M, a, width);
        else
      #endif
        {
          mrb_int val = mrb_integer(a);
          if (val == 0) return a;
          if (mrb_num_shift(M, val, -width, &val)) {
            r = mrb_int_value(M, val);
          } else {
      #ifdef MRB_USE_BIGINT
            r = mrb_bint_rshift(M, mrb_bint_new_int(M, val), width);
      #else
            mrb_raise(M, E_RANGE_ERROR, "integer overflow in bit shift");
      #endif
          }
        }
        #{NUMERIC_SLOW_DONE}
      }

    CPP
  end

  # int_round and flo_round without digits; the Float body is flo_round's for ndigits == 0.
  def numeric_slow_closed_round_source(head)
    <<~CPP
      #{head}) {
        if (bc2cpp_slow_int_p(a)) return a;
      #ifndef MRB_NO_FLOAT
        if (mrb_float_p(a)) {
          mrb_state* mrb = M;  // E_FLOATDOMAIN_ERROR names the state `mrb`
          double number = mrb_float(a), d;
          if (isinf(number)) mrb_raise(M, E_FLOATDOMAIN_ERROR, number < 0 ? "-Infinity" : "Infinity");
          if (isnan(number)) mrb_raise(M, E_FLOATDOMAIN_ERROR, "NaN");
          if (number > 0.0) {
            d = floor(number);
            number = d + (number - d >= 0.5);
          } else if (number < 0.0) {
            d = ceil(number);
            number = d - (d - number >= 0.5);
          }
          if (!FIXABLE_FLOAT(number)) {
            int ai = mrb_gc_arena_save(M);
            mrb_value r = mrb_float_value(M, number);
            #{NUMERIC_SLOW_DONE}
          }
          return mrb_int_value(M, (mrb_int)number);
        }
      #endif
        return bc2cpp_nomethod_named(M, a, "round");
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
