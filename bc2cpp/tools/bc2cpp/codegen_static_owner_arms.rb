# frozen_string_literal: true

# STATIC_OWNER_ARMS: an owner call (OUTSIDE_OWNER_CALL / NAME_OWNER_SET) looks the name up in the receiver's method
# table on every call. When its owner set holds compiled Ruby definitions, exact-class arms go in front of it: a
# receiver whose class is exactly K (mrb_class, so a singleton class never matches) calls the `_impl` of the
# definition K's lookup reaches first, and every other receiver keeps the owner call as the else.
#
# Sound for the same reasons as a POLY arm (poly_candidates): the definition is public and Ruby (no native, no
# repeated or singleton owner, no module), its owner has no prepend or unknown mixin, the name is not installed at
# run time (devirt_blocked_name?), its body compiles clean and the argument count fits its arity, so the owner call's
# visibility (level 2) and arity (level 1) checks would pass too. A subclass gets an arm only when
# inheriting_subclasses proves its lookup ends at that definition.
#
# The arms are added after compile_method finishes, so every pass that matches the owner-call line text (STRICT_HINT
# wraps, CheckedSend's level) has already run on the single line, and the line itself stays the else unchanged for
# SymbolCache. Only engine bodies get arms (mruby's own methods bind statically to core definitions only), only an
# owner call with no block, and BC2CPP_STATIC_OWNER_ARMS=0 turns them off.
module StaticOwnerArms
  STATIC_OWNER_ARMS_MAX = 6
  OWNER_CALL_LINE = %r{^(?<indent>[ \t]*)(?<dest>r\d+)\ =\ (?<call>bc2cpp_owner_call_named\(M,\ (?<recv>r\d+|self),
    \ "(?<name>[^"]+)",\ \d,\ BC2CPP_OWNERS\([^)]*\),\ mrb_nil_value\(\),\ (?<argc>\d+)(?<args>(?:,\ r\d+)*)\);
    \ /\*\ CLOSED_WORLD\ owner-call:\ \S+\ \*/)$}x

  def compile_method(label)
    @static_owner_arms_stack ||= []
    outer = !@static_owner_arms_stack.include?(label)
    @static_owner_arms_stack.push(label)
    begin
      result = super
      outer ? static_owner_arms_expand(label, result) : result
    ensure
      @static_owner_arms_stack.pop
    end
  end

  private

  def static_owner_arms_expand(label, result)
    return result unless result.is_a?(Hash) && result[:code].is_a?(String) && !result[:unsupported]
    return result if ENV['BC2CPP_STATIC_OWNER_ARMS'] == '0' || @clean_probe || !@closed_world
    return result if @owner_of.fetch(label).core || !result[:code].include?('CLOSED_WORLD owner-call')

    # The matched calls take no block: no send's block may leak into direct_call_args.
    saved = [@call_block_expr, @call_block_stack_expr]
    @call_block_expr = @call_block_stack_expr = nil
    static_owner_arms_rewrite(result)
  ensure
    @call_block_expr, @call_block_stack_expr = saved if saved
  end

  def static_owner_arms_rewrite(result)
    code = result[:code]
    out = +''
    pos = 0
    code.to_enum(:scan, OWNER_CALL_LINE).each do
      m = Regexp.last_match
      argv = m[:args].scan(/r\d+/)
      next unless argv.size == m[:argc].to_i

      arms = static_owner_arm_targets(m[:name], argv.size)
      seen = code[[m.begin(0) - 4000, 0].max...m.begin(0)]
      arms = arms.reject { |klass, _| static_owner_already_guarded?(seen, klass, m[:recv]) }
      next if arms.empty?

      out << code[pos...m.begin(0)] << static_owner_arms_code(m, arms, argv)
      pos = m.end(0)
    end
    return result if pos.zero?

    out << code[pos..]
    result.merge(code: out)
  end

  def static_owner_arms_code(m, arms, argv)
    ind = m[:indent]
    note = arms.map(&:first).join(', ')
    branches = arms.map do |klass, t|
      impl = "#{cpp_name(t.owner, t.name)}_impl"
      call_argv, = direct_call_args(t, argv, impl)
      "if (bc2cpp_soc == #{owner_class_ptr_expr(klass)}) {\n" \
        "#{ind}    #{m[:dest]} = #{impl}(M, #{([m[:recv]] + call_argv).join(', ')});\n#{ind}  } else "
    end
    "#{ind}// STATIC_OWNER_ARMS :#{m[:name]} -> #{note}: exact class, direct call; the owner call for any other " \
      "receiver\n#{ind}{ struct RClass* bc2cpp_soc = mrb_class(M, #{m[:recv]});\n" \
      "#{ind}  #{branches.join}{\n#{ind}    #{m[:dest]} = #{m[:call]}\n#{ind}  } }"
  end

  # An arm for K is dead when an enclosing guard already sent class K elsewhere (a TYPED / POLY / INHERITED arm
  # before this else). Only a slot that exists can appear in that text.
  def static_owner_already_guarded?(seen, klass, recv)
    slot = @owner_class_cache&.dig(klass, :index)
    return false unless slot

    expr = Regexp.escape("bc2cpp_owner_class_#{slot}(M)")
    cls = "mrb_obj_class\\(M, #{Regexp.escape(recv)}\\)|bc2cpp_recv_class"
    seen.match?(/#{expr} == (?:#{cls})|(?:#{cls}) == #{expr}/)
  end

  # [[class, definition]] for the arms of `name` called with `argc` arguments, at most STATIC_OWNER_ARMS_MAX.
  def static_owner_arm_targets(name, argc)
    @static_owner_arm_targets ||= {}
    key = [name, argc, @only_owners]
    return @static_owner_arm_targets[key] if @static_owner_arm_targets.key?(key)

    @static_owner_arm_targets[key] = static_owner_arm_targets_decide(name, argc)
  end

  def static_owner_arm_targets_decide(name, argc)
    return [] if devirt_blocked_name?(name)

    defs = core_targets(@registry[name]) || []
    repeated = defs.group_by(&:owner).select { |_, group| group.size > 1 }.keys
    arms = []
    defs.each do |t|
      next if t.owner == '<native>' || repeated.include?(t.owner) || t.owner.end_with?('.singleton')
      next unless t.irep && t.visibility == :public
      next if CodeGen.module_names&.include?(t.owner)
      next unless Array(@prepended_modules[t.owner]).empty? && !@unknown_mixins.include?(t.owner)
      next unless compiles_clean?(t.irep)
      next unless poly_arity_fits?(@ireps.fetch(t.irep), argc, true)
      next unless native_arg_types(t, mandatory_arity(@ireps.fetch(t.irep))).compact.empty?
      next if @only_owners && !@only_owners.include?(t.owner) && !@other_owners&.include?(t.owner)

      ([t.owner] + inheriting_subclasses(name, t.owner)).each { |klass| arms << [klass, t] }
    end
    arms.uniq(&:first).first(STATIC_OWNER_ARMS_MAX)
  end
end

CodeGen.prepend(StaticOwnerArms)
