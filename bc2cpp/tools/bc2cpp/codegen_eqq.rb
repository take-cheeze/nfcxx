# frozen_string_literal: true

# EQQ_DIRECT (ADR 0293): `===` and `is_a?`/`kind_of?` reach their mruby bodies by direct C
# calls instead of a by-name send wherever the receiver or the closed world decides them.
class CodeGen
  # Every `===` the build can reach: Module (class.c mrb_mod_eqq), Range (range.c
  # range_include), Kernel (kernel.c mrb_eqq_m) and, outside the world, Set and the Ruby
  # Proc#=== / Regexp#=== (class-specific tags bc2cpp_eqq leaves to dispatch). The
  # closed-world gate proves no Ruby or dynamically installed `===` exists in the program, so a
  # receiver of a known tag answers with exactly that tag's body.
  def eqq_direct_safe?
    return @eqq_direct_safe if defined?(@eqq_direct_safe)

    world = block_core_world
    @eqq_direct_safe = !world.nil? && native_only_mono?('===') && world.ownerless_native_dispatch_safe?('===') &&
                       name_unrebound?('===')
  end

  # The static kind of the receiver register `reg` of the `===` at `idx`, from its dominating
  # writer (MOVEs followed), or nil:
  #   [:class]        a constant bound only to one class/module (StableClassConstants)
  #   [:fixnum, v]    a proven Integer constant or literal
  #   [:string] [:nil] [:true] [:false]   literals of those exact classes
  def eqq_receiver_kind(irep, idx, reg)
    irep.walk_dominating_writers(idx - 1, reg.to_s, use: idx, follow_moves: true) do |insn|
      case insn.op
      when 'GETCONST', 'GETMCNST'
        eqq_constant_kind(insn.op == 'GETCONST' ? insn.const_name : insn.mcnst_name)
      when /\ALOADI/
        lit = insn.paren_value || insn.imm_operand
        lit && eqq_fixnum_kind(lit.to_i)
      when 'STRING' then [:string]
      when 'LOADNIL' then [:nil]
      when 'LOADTRUE' then [:true]
      when 'LOADFALSE' then [:false]
      end
    end
  end

  # `r<d> = <Class|Integer|String|...> === arg` for a receiver whose class the bytecode proves,
  # or nil to keep bc2cpp_eqq. The register `recv` holds that very value (the dominating
  # write), so the body is the tag's own `===`.
  def compile_eqq_direct(irep, idx, reg, d, recv, arg)
    return nil unless eqq_direct_safe? && irep && idx

    kind = eqq_receiver_kind(irep, idx, reg)
    return nil unless kind

    case kind.first
    when :class
      "  // EQQ_DIRECT class/module constant: Module#=== is mrb_obj_is_kind_of (class.c mrb_mod_eqq)\n" \
        "  r#{d} = mrb_bool_value(mrb_obj_is_kind_of(M, #{arg}, mrb_class_ptr(#{recv})));\n"
    when :fixnum
      # Integer-vs-Integer is decided here while no Ruby Integer#== exists (EQQ_INTEGER_FAST);
      # every other argument takes Kernel#===, which is mrb_equal.
      fast = if eqq_literal_devirt_safe?
               "if (mrb_fixnum_p(#{arg})) {\n" \
                 "    r#{d} = mrb_bool_value(mrb_fixnum(#{arg}) == #{kind[1]});\n" \
                 '  } else '
             else
               ''
             end
      "  // EQQ_DIRECT Integer constant/literal: Kernel#=== is mrb_equal (kernel.c mrb_eqq_m)\n" \
        "  #{fast}{\n    r#{d} = mrb_bool_value(mrb_equal(M, #{recv}, #{arg}));\n  }\n"
    else
      "  // EQQ_DIRECT #{kind.first} literal: Kernel#=== is mrb_equal (kernel.c mrb_eqq_m)\n" \
        "  r#{d} = mrb_bool_value(mrb_equal(M, #{recv}, #{arg}));\n"
    end
  end

  # No alias, undef or Symbol-named define_method/remove_method in the world gives `name` a body
  # the registry does not list (symbol_installed_names is nil when one of them is computed).
  def name_unrebound?(name)
    installed = symbol_installed_names
    !installed.nil? && !installed.include?(name)
  end

  # Open worlds prove nothing about installs; a closed one must see none for `name`.
  def eqq_name_unrebound?(name)
    block_core_world.nil? || name_unrebound?(name)
  end

  # Fixnum literals a 32-bit mrb_int can compare without truncation.
  def eqq_fixnum_kind(value)
    value.between?(-0x7fff_ffff, 0x7fff_ffff) ? [:fixnum, value] : nil
  end

  # GETCONST's own order (codegen_insn.rb): a proven Integer value wins, else a stable
  # class/module constant.
  def eqq_constant_kind(name)
    return nil unless name

    if (value = self.class.integer_constant_values&.[](name))
      return eqq_fixnum_kind(value)
    end

    self.class.stable_class_constants&.include?(name) ? [:class] : nil
  end

  # The body of shared `bc2cpp_eqq`: one tag switch per file instead of one per `when` arm.
  # Only exact built-in tags are answered; everything else (Proc, Data, Set, plain objects)
  # dispatches by name once, here.
  def eqq_helper_code
    @eqq_helper_code ||= begin
      integer_fast = builtin_class_send_safe?('==', %w[Integer]) && eqq_name_unrebound?('==')
      lines = EQQ_HELPER_HEAD.dup
      # Both Integers are decided here; any other argument (Float, bigint) takes mrb_equal.
      lines << '    if (mrb_integer_p(arg)) return mrb_bool_value(mrb_integer(recv) == mrb_integer(arg));' if integer_fast
      lines.concat(EQQ_HELPER_TAIL)
      "#{lines.join("\n")}\n\n"
    end
  end

  EQQ_HELPER_HEAD = [
    '// EQQ_DIRECT -- shared `===` tag switch (ADR 0293): the bodies of Module#===, Range#===',
    '// and Kernel#===; MRB_TT_DATA, MRB_TT_PROC and the rest dispatch by name.',
    'static mrb_value bc2cpp_eqq(mrb_state* M, mrb_value recv, mrb_value arg) {',
    '  switch (mrb_type(recv)) {',
    '  case MRB_TT_CLASS:',
    '  case MRB_TT_MODULE:',
    '  case MRB_TT_SCLASS:',
    '    return mrb_bool_value(mrb_obj_is_kind_of(M, arg, mrb_class_ptr(recv)));',
    '  case MRB_TT_RANGE: {',
    '    mrb_value lo = mrb_range_beg(M, recv);',
    '    mrb_value hi = mrb_range_end(M, recv);',
    '    mrb_bool excl = mrb_range_excl_p(M, recv);',
    '    if (mrb_nil_p(lo)) {',
    '      mrb_int c = mrb_cmp(M, hi, arg);',
    '      return mrb_bool_value(excl ? (c == 1) : (c == 0 || c == 1));',
    '    }',
    '    mrb_int cb = mrb_cmp(M, lo, arg);',
    '    if (cb != 0 && cb != -1) return mrb_false_value();',
    '    if (mrb_nil_p(hi)) return mrb_true_value();',
    '    mrb_int ce = mrb_cmp(M, hi, arg);',
    '    return mrb_bool_value(excl ? (ce == 1) : (ce == 0 || ce == 1));',
    '  }',
    '  case MRB_TT_INTEGER:'
  ].freeze

  EQQ_HELPER_TAIL = [
    '    return mrb_bool_value(mrb_equal(M, recv, arg));',
    '  case MRB_TT_FLOAT:',
    '  case MRB_TT_STRING:',
    '  case MRB_TT_SYMBOL:',
    '  case MRB_TT_TRUE:',
    '  case MRB_TT_FALSE:',
    '  case MRB_TT_ARRAY:',
    '  case MRB_TT_HASH:',
    '    return mrb_bool_value(mrb_equal(M, recv, arg));',
    '  default:',
    '    return mrb_funcall(M, recv, "===", 1, arg);',
    '  }',
    '}'
  ].freeze

  # `dst = bc2cpp_eqq(M, recv, arg);`, building the helper on first use.
  def outlined_eqq_call(dst, recv, arg)
    eqq_helper_code
    "  #{dst} = bc2cpp_eqq(M, #{recv}, #{arg});\n"
  end

  # File-scope definition when a compiled entry calls the helper; '' otherwise.
  def emit_eqq_helper(codes)
    eqq_helper_site_count(codes).zero? ? '' : eqq_helper_code
  end

  def eqq_helper_site_count(codes)
    texts = codes.map { |c| c.is_a?(Hash) ? c[:code] : c }
    texts.sum { |t| t.scan(/= bc2cpp_eqq\(M,/).size }
  end

  # is_a?/kind_of? with a class/module argument is kernel.c's mrb_obj_is_kind_of_m; any other
  # argument raises mrb_get_args' 'c' TypeError (class.c ensure_class_type). A receiver without
  # Kernel (a BasicObject subclass) has no such method, so the raise needs the Kernel proof.
  def kind_of_type_error_direct?(name)
    world = block_core_world
    !world.nil? && world.kernel_native_dispatch_safe?(name) && name_unrebound?(name)
  end
end
