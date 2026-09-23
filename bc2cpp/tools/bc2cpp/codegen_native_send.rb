# frozen_string_literal: true

# CodeGen: sends devirtualized to native primitives.

class CodeGen
  # LITERAL_EQQ_SUPPORT soundness gate, re-checked against this run's @registry:
  # both `#==` and `#===` must be MONO native. `LITERAL === arg` must reach
  # mrb_eqq_m (src/kernel.c), which calls mrb_equal (src/object.c); mrb_equal
  # dispatches to the receiver's `#==` unless mrb_func_basic_p, and the Symbol
  # (mrb_obj_equal_m) and Fixnum (int_equal, src/numeric.c) branches rely on
  # those defaults. A reopened `#==` on any class could change that, so the
  # check is by name, not by owner. Any reopening flips this to false and the
  # sites fall back to POLY dispatch. Memoized: @registry is fixed after
  # CodeGen.new.
  def eqq_literal_devirt_safe?
    return @eqq_literal_devirt_safe if defined?(@eqq_literal_devirt_safe)

    @eqq_literal_devirt_safe = %w[== ===].all? do |n|
      defs = @registry[n]
      defs && defs.size == 1 && defs.first.owner == '<native>'
    end
  end

  # NATIVE_PRIMITIVE_SEND_ARITY: native methods compile_native_primitive_send can
  # inline, with the exact arity a call site must match (MRB_ARGS_NONE /
  # MRB_ARGS_REQ(1) in src/kernel.c, class.c, hash.c, string.c, numeric.c,
  # array.c, range.c). to_s/length/first/dup/=== have several native bodies;
  # see their *_TYPE_TAG_DISPATCH comments. to_i is arity 0 only (see
  # TO_I_TYPE_TAG_DISPATCH).
  # Not listed because a bytecode override makes native_only_mono? false (they
  # would be dead code): push (RPG2k#push), << (RGSS::ErrorReport::Tee#<<),
  # clear (RGSS::ErrorReport.clear), include? (mruby-rgss array_include.rb),
  # member? (Game::Battle::Combatant#member?). empty? and size also have
  # bytecode definitions (Game::MoveRoute#empty?, Game::Party#size), so they use
  # per-class guards below; size excludes String because its body uses the
  # private, build-flag-dependent RSTRING_CHAR_LEN.
  NATIVE_PRIMITIVE_SEND_ARITY = { '!' => 0, 'nil?' => 0, 'is_a?' => 1, 'kind_of?' => 1,
                                   'equal?' => 1, 'class' => 0, 'object_id' => 0, 'keys' => 0,
                                   'values' => 0,
                                   'to_s' => 0, 'length' => 0, 'first' => 0, 'dup' => 0,
                                   '===' => 1, '!=' => 1, 'to_i' => 0, 'respond_to?' => 1 }.freeze

  # Shared gate for NATIVE_PRIMITIVE_SEND_ARITY: `name` has exactly one registry
  # def and it is the native placeholder (irep nil). The opposite of
  # monomorphic_target, which needs an `_impl`. A game-side `def nil?` would add
  # a second def and fall back to POLY dispatch. Without NATIVE_SRCS there is no
  # placeholder, so nothing is proven.
  def native_only_mono?(name)
    defs = @registry[name]
    defs && defs.size == 1 && defs.first.irep.nil?
  end

  # Permit per-class fast paths only for exact built-in receivers, with a
  # native registration present and no Ruby replacement on those classes.
  # A prepend can sit ahead of the native method, so decline the fast path
  # for any base class with a known or unresolved prepend.
  def builtin_class_send_safe?(name, builtins)
    @builtin_class_send_safe ||= {}
    cache_key = [name, builtins]
    return @builtin_class_send_safe[cache_key] if @builtin_class_send_safe.key?(cache_key)

    defs = @registry[name]
    @builtin_class_send_safe[cache_key] = defs && defs.any? { |d| d.owner == '<native>' && d.irep.nil? } &&
                                          defs.none? { |d| builtins.include?(d.owner) } &&
                                          builtins.none? do |owner|
                                            !Array(@prepended_modules[owner]).empty? || @unknown_mixins.include?(owner)
                                          end
  end

  # Guarded direct C++ for one NATIVE_PRIMITIVE_SEND_ARITY name, or an exact-class
  # expression generated from registered native C methods. The per-method
  # soundness notes are at compile_send's call site.
  def compile_native_primitive_send(name, d, recv, argv)
    return compile_native_registered_expression(name, d, recv, argv) if @native_registered_expressions.key?(name)

    case name
    when 'respond_to?'
      # Kernel#respond_to? converts its name with mrb_obj_to_sym, then calls
      # mrb_respond_to; on a miss it may call an overridden respond_to_missing?.
      # Answer hits directly and keep the original call for misses. compile_send's
      # arity and native-only gates ensure the core method is the target.
      method_name = argv.first
      fallback = dynamic_dispatch_line(d, recv, name, argv)
      <<~CPP
          // respond_to? -- answer native hits directly; preserve missing-hook behavior on misses
          {
            // Braced so the symbol neither redeclares across sends that reuse
            // register #{d} nor sits between a goto and its label.
            mrb_sym bc2cpp_respond_to_id = mrb_obj_to_sym(M, #{method_name});
            if (mrb_respond_to(M, #{recv}, bc2cpp_respond_to_id)) {
              r#{d} = mrb_true_value();
            } else {
              #{fallback.chomp}
            }
          }
      CPP
    when '!'
      expression = @native_expression_devirt[name]
      if expression
        "  // ! -- generated from mruby's registered C implementation\n" \
          "  r#{d} = #{expression.gsub('recv', recv)};\n"
      else
        "  r#{d} = mrb_funcall(M, #{recv}, \"!\", 0);\n"
      end
    when 'nil?'
      "  // nil? -- native primitive, no lookup needed\n" \
      "  r#{d} = mrb_bool_value(mrb_nil_p(#{recv}));\n"
    when 'is_a?', 'kind_of?'
      arg = argv.first
      "  // #{name} -- native primitive, no lookup needed (argument type-checked at " \
      "runtime -- see compile_send's own comment)\n" \
      "  if (mrb_class_p(#{arg}) || mrb_module_p(#{arg})) {\n" \
      "    r#{d} = mrb_bool_value(mrb_obj_is_kind_of(M, #{recv}, mrb_class_ptr(#{arg})));\n" \
      "  } else {\n" \
      "    #{dynamic_dispatch_line(d, recv, name, argv)}" \
      "  }\n"
    when 'equal?'
      arg = argv.first
      "  // equal? -- native primitive, no lookup needed (mrb_obj_equal is a real\n" \
      "  // public MRB_API, safe for any receiver/argument pair -- no struct cast)\n" \
      "  r#{d} = mrb_bool_value(mrb_obj_equal(M, #{recv}, #{arg}));\n"
    when 'class'
      "  // class -- native primitive, no lookup needed (mrb_obj_class is a real\n" \
      "  // public MRB_API, safe for any receiver -- no struct cast)\n" \
      "  r#{d} = mrb_obj_value(mrb_obj_class(M, #{recv}));\n"
    when 'object_id'
      "  // object_id -- native primitive, no lookup needed (mrb_obj_id is a real\n" \
      "  // public MRB_API, safe for any receiver -- no struct cast)\n" \
      "  r#{d} = mrb_fixnum_value(mrb_obj_id(#{recv}));\n"
    when 'keys'
      # KEYS_TYPE_TAG_GUARD: mrb_hash_keys casts through mrb_hash_ptr unchecked
      # (mruby/hash.h), so a non-Hash receiver would be undefined behavior. Guard on
      # mrb_hash_p; otherwise mrb_funcall raises the real NoMethodError
      # (native_only_mono? proved no other `keys` exists).
      "  // keys -- native primitive, runtime-guarded (mrb_hash_keys casts straight\n" \
      "  // to struct RHash*, unsafe on a non-Hash receiver -- see compile_native_\n" \
      "  // primitive_send's own KEYS_TYPE_TAG_GUARD comment)\n" \
      "  if (mrb_hash_p(#{recv})) {\n" \
      "    r#{d} = mrb_hash_keys(M, #{recv});\n" \
      "  } else {\n" \
      "    #{dynamic_dispatch_line(d, recv, name, argv)}" \
      "  }\n"
    when 'values'
      # mrb_hash_values (mruby/hash.h) is the public native body for
      # Hash#values, but like mrb_hash_keys it casts through mrb_hash_ptr
      # without checking the receiver tag. Require an exact base Hash so a
      # subclass override keeps ordinary Ruby lookup; all other receiver
      # types also stay on that path.
      fallback = dynamic_dispatch_line(d, recv, name, argv)
      <<~CPP
          // HASH_VALUES :values -- exact base Hash only; preserve subclass overrides and non-Hash errors
          if (mrb_hash_p(#{recv}) && mrb_obj_ptr(#{recv})->c == M->hash_class) {
            r#{d} = mrb_hash_values(M, #{recv});
          } else {
            #{fallback.chomp}
          }
      CPP
    when 'key?'
      # mrb_hash_key_p is Hash-specific and casts through mrb_hash_ptr
      # without checking the receiver tag. Exact base Hash preserves
      # subclass/singleton overrides; every other value keeps Ruby lookup.
      key = argv.first
      fallback = dynamic_dispatch_line(d, recv, name, argv)
      <<~CPP
          // HASH_KEY_P :key? -- exact base Hash only; preserve overrides and non-Hash errors
          if (mrb_hash_p(#{recv}) && mrb_obj_ptr(#{recv})->c == M->hash_class) {
            r#{d} = mrb_bool_value(mrb_hash_key_p(M, #{recv}, #{key}));
          } else {
            #{fallback.chomp}
          }
      CPP
    when 'to_s'
      # TO_S_TYPE_TAG_DISPATCH: `to_s` has many native bodies (Array, String, Hash,
      # Integer, Float, Range, Module, Kernel) collapsed into one `<native>` entry,
      # so this switches on mrb_type(recv) and handles only tags whose body is safe
      # to run outside a dispatched frame; everything else uses mrb_funcall.
      #   MRB_TT_STRING: mrb_str_to_s (string.c, static) is `mrb_obj_class(mrb,
      #   self) != mrb->string_class ? mrb_str_dup(mrb, self) : self`, reproduced.
      #   MRB_TT_INTEGER: int_to_s is mrb_integer_to_str(mrb, self, 10) for n == 0
      #   (a public MRB_API).
      # Array/Hash are excluded: mrb_ary_to_s/mrb_hash_to_s start with
      # `mrb->c->ci->mid = MRB_SYM(inspect);`, which would corrupt the current
      # frame. Float/Range (static, no public equivalent) and Class/Module
      # (mrb_mod_to_s is internal.h-only) are excluded too.
      "  // to_s -- native primitive, runtime-guarded per real receiver type\n" \
      "  // (only String/Integer are handled directly -- see compile_native_\n" \
      "  // primitive_send's own TO_S_TYPE_TAG_DISPATCH comment for why Array/\n" \
      "  // Hash/Float/Range/Class are deliberately left to ordinary dispatch)\n" \
      "  switch (mrb_type(#{recv})) {\n" \
      "  case MRB_TT_STRING:\n" \
      "    r#{d} = mrb_obj_class(M, #{recv}) != M->string_class ? mrb_str_dup(M, #{recv}) : #{recv};\n" \
      "    break;\n" \
      "  case MRB_TT_INTEGER:\n" \
      "    r#{d} = mrb_integer_to_str(M, #{recv}, 10);\n" \
      "    break;\n" \
      "  default:\n" \
      "    #{dynamic_dispatch_line(d, recv, name, argv)}" \
      "    break;\n" \
      "  }\n"
    when 'length'
      # LENGTH_TYPE_TAG_DISPATCH: Array (mrb_ary_size: ARY_LEN) and Hash
      # (mrb_hash_size, public) are handled. String is excluded: mrb_str_size uses
      # RSTRING_CHAR_LEN, defined only inside string.c and dependent on
      # MRB_UTF8_STRING, so hardcoding it would couple to the build config.
      "  // length -- native primitive, runtime-guarded per real receiver type\n" \
      "  // (only Array/Hash are handled directly -- String is deliberately left\n" \
      "  // to ordinary dispatch, see compile_native_primitive_send's own\n" \
      "  // LENGTH_TYPE_TAG_DISPATCH comment for why)\n" \
      "  switch (mrb_type(#{recv})) {\n" \
      "  case MRB_TT_ARRAY:\n" \
      "    r#{d} = mrb_int_value(M, ARY_LEN(mrb_ary_ptr(#{recv})));\n" \
      "    break;\n" \
      "  case MRB_TT_HASH:\n" \
      "    r#{d} = mrb_int_value(M, mrb_hash_size(M, #{recv}));\n" \
      "    break;\n" \
      "  default:\n" \
      "    #{dynamic_dispatch_line(d, recv, name, argv)}" \
      "    break;\n" \
      "  }\n"
    when 'first'
      # FIRST_TYPE_TAG_DISPATCH: arity 0 only (`x.first(n)` never reaches here).
      # MRB_TT_ARRAY: reproduce mrb_ary_first's zero-argument body (calling it would
      # make mrb_get_argc read the caller's frame), behind exact base-Array identity
      # so subclasses and singletons keep Ruby dispatch.
      # MRB_TT_RANGE: range_beg (registered as `first`, ARGS_NONE) is
      # mrb_range_beg(mrb, range), a public macro.
      # Everything else uses mrb_funcall.
      "  // first -- native primitive, runtime-guarded for Range and exact Array\n" \
      "  // directly -- see compile_native_primitive_send's own\n" \
      "  // FIRST_TYPE_TAG_DISPATCH comment for Array's zero-arg expression)\n" \
      "  if (mrb_range_p(#{recv})) {\n" \
      "    r#{d} = mrb_range_beg(M, #{recv});\n" \
      "  } else if (mrb_array_p(#{recv}) && mrb_obj_ptr(#{recv})->c == M->array_class) {\n" \
      "    struct RArray* bc2cpp_first_array = mrb_ary_ptr(#{recv});\n" \
      "    r#{d} = ARY_LEN(bc2cpp_first_array) > 0 ? ARY_PTR(bc2cpp_first_array)[0] : mrb_nil_value();\n" \
      "  } else {\n" \
      "    #{dynamic_dispatch_line(d, recv, name, argv)}" \
      "  }\n"
    when '==='
      # EQQ_TYPE_TAG_DISPATCH: `===` has three native bodies, all static and reading
      # their argument via mrb_get_arg1 (a frame read), so each is reproduced from
      # public APIs:
      #   - CLASS/MODULE/SCLASS: mrb_mod_eqq is mrb_obj_is_kind_of(mrb, arg,
      #     mrb_class_ptr(mod)).
      #   - RANGE: range_include (range.c) with mrb_range_beg/end/excl_p and mrb_cmp
      #     in place of its static r_le/r_gt/r_ge; the switch is the type guard.
      #   - INTEGER/FLOAT/STRING/SYMBOL/TRUE/FALSE/ARRAY/HASH: mrb_eqq_m is
      #     mrb_bool_value(mrb_equal(mrb, self, arg)). nil is MRB_TT_FALSE
      #     (mruby/value.h), so no MRB_TT_NIL case exists (it would not compile).
      # Excluded: MRB_TT_DATA (mruby-onig-regexp's Regexp has a bytecode `#===`
      # outside closed_world_mrblib_srcs, and many wrapper types share the tag) and
      # MRB_TT_PROC (mruby-proc-ext's bytecode Proc#===). They use mrb_funcall.
      arg = argv.first
      # EQQ_INTEGER_FAST: `case cmd.code when Cmd::X` is one `===` per arm, and for
      # an Integer receiver mrb_equal falls back to funcall("==") whenever the values
      # differ (Integer#== is not the basic identity method). Two Integers are
      # decided natively whenever no Ruby-defined Integer#== is observable (the
      # closed-world gate); mixed Integer/Float or bigint still goes through
      # mrb_equal.
      integer_case =
        if builtin_class_send_safe?('==', %w[Integer])
          "  case MRB_TT_INTEGER:\n" \
            "    if (mrb_integer_p(#{arg})) {\n" \
            "      r#{d} = mrb_bool_value(mrb_integer(#{recv}) == mrb_integer(#{arg}));\n" \
            "      break;\n" \
            "    }\n" \
            "    r#{d} = mrb_bool_value(mrb_equal(M, #{recv}, #{arg}));\n" \
            "    break;\n"
        else
          "  case MRB_TT_INTEGER:\n"
        end
      "  // === -- native primitive, runtime-guarded per real receiver type\n" \
      "  // (see compile_native_primitive_send's own EQQ_TYPE_TAG_DISPATCH\n" \
      "  // comment for why MRB_TT_DATA/MRB_TT_PROC and everything else fall\n" \
      "  // through to ordinary dispatch)\n" \
      "  switch (mrb_type(#{recv})) {\n" \
      "  case MRB_TT_CLASS:\n" \
      "  case MRB_TT_MODULE:\n" \
      "  case MRB_TT_SCLASS:\n" \
      "    r#{d} = mrb_bool_value(mrb_obj_is_kind_of(M, #{arg}, mrb_class_ptr(#{recv})));\n" \
      "    break;\n" \
      "  case MRB_TT_RANGE: {\n" \
      "    mrb_value bc2cpp_eqq_beg#{d} = mrb_range_beg(M, #{recv});\n" \
      "    mrb_value bc2cpp_eqq_end#{d} = mrb_range_end(M, #{recv});\n" \
      "    mrb_bool bc2cpp_eqq_excl#{d} = mrb_range_excl_p(M, #{recv});\n" \
      "    mrb_bool bc2cpp_eqq_r#{d} = FALSE;\n" \
      "    if (mrb_nil_p(bc2cpp_eqq_beg#{d})) {\n" \
      "      mrb_int bc2cpp_eqq_c#{d} = mrb_cmp(M, bc2cpp_eqq_end#{d}, #{arg});\n" \
      "      bc2cpp_eqq_r#{d} = bc2cpp_eqq_excl#{d} ? (bc2cpp_eqq_c#{d} == 1) : (bc2cpp_eqq_c#{d} == 0 || bc2cpp_eqq_c#{d} == 1);\n" \
      "    } else {\n" \
      "      mrb_int bc2cpp_eqq_cb#{d} = mrb_cmp(M, bc2cpp_eqq_beg#{d}, #{arg});\n" \
      "      if (bc2cpp_eqq_cb#{d} == 0 || bc2cpp_eqq_cb#{d} == -1) {\n" \
      "        if (mrb_nil_p(bc2cpp_eqq_end#{d})) {\n" \
      "          bc2cpp_eqq_r#{d} = TRUE;\n" \
      "        } else {\n" \
      "          mrb_int bc2cpp_eqq_ce#{d} = mrb_cmp(M, bc2cpp_eqq_end#{d}, #{arg});\n" \
      "          bc2cpp_eqq_r#{d} = bc2cpp_eqq_excl#{d} ? (bc2cpp_eqq_ce#{d} == 1) : (bc2cpp_eqq_ce#{d} == 0 || bc2cpp_eqq_ce#{d} == 1);\n" \
      "        }\n" \
      "      }\n" \
      "    }\n" \
      "    r#{d} = mrb_bool_value(bc2cpp_eqq_r#{d});\n" \
      "    break;\n" \
      "  }\n" \
      "#{integer_case}" \
      "  case MRB_TT_FLOAT:\n" \
      "  case MRB_TT_STRING:\n" \
      "  case MRB_TT_SYMBOL:\n" \
      "  case MRB_TT_TRUE:\n" \
      "  case MRB_TT_FALSE:\n" \
      "  case MRB_TT_ARRAY:\n" \
      "  case MRB_TT_HASH:\n" \
      "    r#{d} = mrb_bool_value(mrb_equal(M, #{recv}, #{arg}));\n" \
      "    break;\n" \
      "  default:\n" \
      "    #{dynamic_dispatch_line(d, recv, name, argv)}" \
      "    break;\n" \
      "  }\n"
    when 'dup'
      # DUP_TYPE_TAG_DISPATCH: exhaustive, no mrb_funcall arm. `dup` has two native
      # registrations: mrb_obj_dup (Kernel, MRB_API; immediates return self, others
      # mrb_obj_alloc + init_copy, which still dispatches #initialize_copy) and
      # mrb_mod_dup (Class/Module, static: `mrb_obj_clone` then clear `frozen`,
      # reproduced). The default arm calls mrb_obj_dup directly.
      "  // dup -- native primitive, no lookup needed for any receiver (exactly\n" \
      "  // two real native implementations exist, both handled directly -- see\n" \
      "  // compile_native_primitive_send's own DUP_TYPE_TAG_DISPATCH comment)\n" \
      "  switch (mrb_type(#{recv})) {\n" \
      "  case MRB_TT_CLASS:\n" \
      "  case MRB_TT_MODULE:\n" \
      "  case MRB_TT_SCLASS:\n" \
      "    r#{d} = mrb_obj_clone(M, #{recv});\n" \
      "    mrb_obj_ptr(r#{d})->frozen = 0;\n" \
      "    break;\n" \
      "  default:\n" \
      "    r#{d} = mrb_obj_dup(M, #{recv});\n" \
      "    break;\n" \
      "  }\n"
    when '!='
      # NEQ_UNCONDITIONAL: `!=` is a hand-written bytecode RProc in class.c bob_init
      # (`return !(self == other)`), registered via mrb_define_method_raw (hence that
      # scan in extract_native_method_names). vm.c OP_EQ is identity, then a
      # hardcoded false for Symbols, then numeric fast paths or SEND :==. mrb_equal
      # (src/object.c) gives the same answer for every type (for a Symbol with the
      # default `==`, mrb_func_basic_p skips dispatch and returns false), so
      # `!mrb_equal(...)` needs no fallback.
      arg = argv.first
      "  // != -- native primitive, no lookup needed for any receiver (real\n" \
      "  // bytecode is exactly `!(self == other)`, mrb_equal reproduces ==\n" \
      "  // exactly for every type -- see compile_native_primitive_send's own\n" \
      "  // NEQ_UNCONDITIONAL comment)\n" \
      "  r#{d} = mrb_bool_value(!mrb_equal(M, #{recv}, #{arg}));\n"
    when 'to_i'
      # TO_I_TYPE_TAG_DISPATCH: `to_i` natives reachable in this build: Integer,
      # Float, String, and Time (mruby-time; complex/rational/object-ext are not in
      # build_config.rb).
      #   INTEGER: mrb_obj_itself (`return self;`).
      #   FLOAT: flo_to_i checks NaN/Infinity (mrb_check_num_exact, internal.h
      #   only, so reproduced with isinf/isnan + mrb_raise) and promotes to Bignum
      #   when !FIXABLE_FLOAT (mrb_bint_new_float/mrb_int_overflow, internal.h only).
      #   Only the finite, in-range case is handled (floor/ceil + mrb_int_value);
      #   the rest uses mrb_funcall.
      #   STRING: mrb_str_to_i reads `mrb_get_args(mrb, "|i", &base)`, but for the
      #   arity-0 shape base is always 10, so it is mrb_str_to_integer(mrb, self,
      #   10, FALSE). `str.to_i(base)` never reaches this table.
      # Time is excluded: time_to_i reads `struct mrb_time`, private to time.c.
      "  // to_i -- native primitive, runtime-guarded per real receiver type\n" \
      "  // (Integer/Float/String handled directly -- see compile_native_\n" \
      "  // primitive_send's own TO_I_TYPE_TAG_DISPATCH comment for why Time\n" \
      "  // and Float's own NaN/Infinity/overflow edge are deliberately left\n" \
      "  // to ordinary dispatch)\n" \
      "  switch (mrb_type(#{recv})) {\n" \
      "  case MRB_TT_INTEGER:\n" \
      "    r#{d} = #{recv};\n" \
      "    break;\n" \
      "  case MRB_TT_FLOAT: {\n" \
      "    mrb_float bc2cpp_toi_f#{d} = mrb_float(#{recv});\n" \
      "    if (isnan(bc2cpp_toi_f#{d}) || isinf(bc2cpp_toi_f#{d}) || !FIXABLE_FLOAT(bc2cpp_toi_f#{d})) {\n" \
      "      #{dynamic_dispatch_line(d, recv, name, argv)}" \
      "    } else {\n" \
      "      if (bc2cpp_toi_f#{d} > 0.0) bc2cpp_toi_f#{d} = floor(bc2cpp_toi_f#{d});\n" \
      "      if (bc2cpp_toi_f#{d} < 0.0) bc2cpp_toi_f#{d} = ceil(bc2cpp_toi_f#{d});\n" \
      "      r#{d} = mrb_int_value(M, (mrb_int)bc2cpp_toi_f#{d});\n" \
      "    }\n" \
      "    break;\n" \
      "  }\n" \
      "  case MRB_TT_STRING:\n" \
      "    r#{d} = mrb_str_to_integer(M, #{recv}, 10, FALSE);\n" \
      "    break;\n" \
      "  default:\n" \
      "    #{dynamic_dispatch_line(d, recv, name, argv)}" \
      "    break;\n" \
      "  }\n"
    end
  end

  # INTEGER_UNARY: an Integer runs Numeric#-@ (`0 - self`), Numeric#zero? (`self == 0`),
  # both Ruby in libmruby, and int_round (`self`); see docs/adr/0200.
  INTEGER_UNARY_OPS = {
    '-@' => ['mrb_int_value(M, -mrb_integer(%<r>s))', ' && mrb_integer(%<r>s) != MRB_INT_MIN'],
    'zero?' => ['mrb_bool_value(mrb_integer(%<r>s) == 0)', ''],
    'round' => ['%<r>s', '']
  }.freeze

  def compile_integer_unary(name, n, d, recv, argv)
    value, extra_guard = INTEGER_UNARY_OPS[name]
    return nil unless value && n.zero? && native_only_mono?(name) && integer_ancestry_native?(name)

    <<~CPP
        // INTEGER_UNARY :#{name} -- Integer receiver computed inline; anything else keeps the dispatch
        if (mrb_integer_p(#{recv})#{format(extra_guard, r: recv)}) {
          r#{d} = #{format(value, r: recv)};
        } else {
          #{dynamic_dispatch_line(d, recv, name, argv).chomp}
        }
    CPP
  end

  # builtin_class_send_safe? over Integer's ancestry and every module mixed into it.
  def integer_ancestry_native?(name)
    owners = %w[Integer Numeric Comparable]
    queue = owners.dup
    until queue.empty?
      owner = queue.shift
      (Array(@included_modules[owner]) + Array(@prepended_modules[owner])).each do |mod|
        next if owners.include?(mod)

        owners << mod
        queue << mod
      end
    end
    builtin_class_send_safe?(name, owners)
  end

  # Emit a generated native expression behind a runtime type-tag guard. Heap
  # objects also require their exact built-in class pointer; Float and Symbol
  # are immediate values and use only their unambiguous type tags.
  def compile_native_registered_expression(name, d, recv, argv)
    entries = @native_registered_expressions[name]
    fallback = dynamic_dispatch_line(d, recv, name, argv)
    return fallback unless entries && !entries.empty?
    return fallback unless entries.all? { |entry| entry[:arity] == argv.length }

    cases = entries.map do |entry|
      owner = entry[:owner]
      expression = entry[:expression].gsub('recv', recv)
      expression = expression.gsub('BC2CPP_ARG0', argv.fetch(0)) if entry[:arity] == 1
      source_comment = if name == 'clear' && owner[:class_name] == 'Array' && expression.include?('mrb_ary_clear')
                         '// ARRAY_CLEAR :clear -- generated from mruby core C'
                       end
      class_check = if %w[Float Symbol].include?(owner[:class_name])
                      "r#{d} = #{expression};"
                    else
                      <<~CPP.chomp
                        if (mrb_obj_ptr(#{recv})->c == M->#{owner[:field]}) {
                          r#{d} = #{expression};
                        } else {
                          #{fallback.chomp}
                        }
                      CPP
      end
      <<~CPP
        #{source_comment}
        case #{owner[:tag]}:
          #{class_check.gsub("\n", "\n  ")}
          break;
      CPP
    end.join
    <<~CPP
      // #{name} -- generated from native registrations and C method bodies
      switch (mrb_type(#{recv})) {
      #{cases}
      default:
        #{fallback.chomp}
        break;
      }
    CPP
  end
end
