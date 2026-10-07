# frozen_string_literal: true

# CodeGen: unbox a native entry point's arguments with the conversion mrb_get_args performs (ADR 0372).
#
# An RGSS binding is `T a; ...; mrb_get_args(M, "<fmt>", &a, ...); return entry(M, self, a, ...)` and
# scripts/native_binding_split.rb refuses any body with a statement before the mrb_get_args call, so the call site that
# has proven the receiver and the argument count can run the same conversions itself. "i" is exactly
# `mrb_as_int(mrb, arg)` and "f" `mrb_as_float(mrb, arg)` (3rd/mruby/src/class.c, pinned by
# scripts/bc2cpp_native_param_unbox_check.rb), so for EVERY argument value the unboxed call raises, converts and
# calls to_int exactly as dispatch does: an Integer tag test with a by-name else only re-derived that.
module NativeParamUnbox
  # BC2CPP_NATIVE_PARAM_UNBOX=0 restores the Integer tag test and the by-name else.
  def native_param_unbox_on?
    ENV['BC2CPP_NATIVE_PARAM_UNBOX'] != '0'
  end

  # The arm for `name` may drop its tag test and by-name else: the switch is on and no alias, Symbol definition, undef,
  # computed-name installer, visibility change or outside source can make `name` reach something other than the RGSS
  # native (the proof of native_exact_owner_safe?). Without it the old gate keeps dispatching what it does not test.
  def native_param_unbox_name?(name)
    return false unless native_param_unbox_on? && @closed_world && !symbol_installed_names.nil?

    !symbol_installed_names.include?(name) && !devirt_blocked_name?(name) &&
      @closed_world.native_exact_direct_name_safe?(name, NativeExactDirect::RGSS_SRC)
  end

  # [statements, argument expressions] for `kinds` over the argument registers `argv`. A converting kind is a
  # statement of its own, in argument order: operands of one call expression are unsequenced, and the order decides which
  # TypeError/RangeError wins and when each to_int runs. +unboxed+ lists the positions already known to be a Fixnum
  # (proven, or tested by the caller), which `mrb_integer` reads without a conversion.
  def native_param_unbox_args(d, argv, kinds, unboxed: [])
    stmts = []
    args = kinds.each_index.map do |i|
      local = "bc2cpp_pu#{d}_#{i}"
      case kinds[i]
      when :int
        next "mrb_integer(#{argv[i]})" if unboxed.include?(i)

        stmts << "mrb_int #{local} = mrb_as_int(M, #{argv[i]});"
        local
      when :float
        stmts << "mrb_float #{local} = mrb_as_float(M, #{argv[i]});"
        local
      when :bool then "mrb_test(#{argv[i]})"
      else argv[i]
      end
    end
    [stmts, args]
  end

  # [guards, call] for `r<d> = rgss::<function>(M, recv, args)`: when the name is proven (native_param_unbox_name?) there
  # is no guard and every unproven :int argument is converted; otherwise each :int argument not in +proven+ keeps its
  # Integer tag test (the caller dispatches by name when it fails) and only the sequencing of the :float ones changes.
  def native_param_unbox_call(name, d, recv, argv, function, kinds, proven: [])
    safe = native_param_unbox_name?(name)
    ints = kinds.each_index.select { |i| kinds[i] == :int }
    guards = safe ? [] : (ints - proven).map { |i| "mrb_integer_p(#{argv[i]})" }
    stmts, args = native_param_unbox_args(d, argv, kinds, unboxed: safe ? proven : ints)
    [guards, native_param_unbox_block(stmts, "r#{d} = rgss::#{function}(#{(['M', recv] + args).join(', ')});")]
  end

  # `call` run after `stmts`, in a block of its own so the locals stay out of the case labels around it.
  def native_param_unbox_block(stmts, call)
    return call if stmts.empty?

    "{\n      #{stmts.join("\n      ")}\n      #{call.chomp}\n    }\n"
  end
end

class CodeGen
  include NativeParamUnbox
end
