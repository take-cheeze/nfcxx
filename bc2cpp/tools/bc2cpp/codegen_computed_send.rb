# frozen_string_literal: true

require_relative 'computed_send_names'

# COMPUTED_SEND_EXPANSION (ADR 0303): `send(name, args...)` whose name register provably holds one of a
# finite set of plain Symbols (ComputedSendNames) becomes a chain of direct calls, one per name,
# each compiled as the literal-name send of the same site (so it inherits that name's own
# visibility, arity and dispatch proofs). It is taken only when every arm is a direct call with no
# by-name dispatch left in it; otherwise the site keeps its single computed send.
#
# The default arm is not a fallback: a Symbol outside the proven set is a proof violation
# (ADR 0290), and the one non-Symbol value a table can yield, nil, raises the TypeError `send`
# raises for it.
module ComputedSend
  SEND_NAMES = %w[send __send__ public_send].freeze
  # =0 keeps every computed send as one by-name call (the before side of a measurement).
  KILL_SWITCH = 'BC2CPP_COMPUTED_SEND'
  # Core containers whose [] / freeze the table proof reads through.
  TABLE_READERS = [%w[Array []], %w[Hash []]].freeze
  TABLE_FREEZERS = [%w[Array freeze], %w[Hash freeze], %w[Object freeze], %w[Kernel freeze]].freeze
  DYNAMIC_ARM = /\b(?:bc2cpp_send|bc2cpp_funcall\w*|mrb_funcall\w*|bc2cpp_nomethod\w*|bc2cpp_guard_violation\w*)\(|#error/

  def compile_send(insn, **kwargs)
    computed_send_expansion(insn, kwargs) || super
  end

  private

  def computed_send_expansion(insn, kwargs)
    plan = computed_send_plan(insn, kwargs)
    return nil unless plan

    names, irep, idx, owner_def = plan.values_at(:names, :irep, :idx, :owner_def)
    d = insn.reg.to_i
    self_implicit = insn.op.start_with?('SSEND')
    rest = (2..insn.n_spec.to_i).map { |k| "r#{d + k}" }
    arms = names.names.map do |name|
      code = splat_send_with(name, d, self_implicit, irep, idx, owner_def, rest, nil)
      return nil unless code && computed_send_arm_direct?(code)

      [name, code]
    end
    computed_send_code(insn, names, arms, self_implicit)
  end

  # nil, or the proven name set with the site the arms are compiled for.
  def computed_send_plan(insn, kwargs)
    irep, idx = kwargs.values_at(:irep, :idx)
    return nil unless irep && idx && %w[SEND SSEND].include?(insn.op) && SEND_NAMES.include?(insn.sym)
    return nil unless kwargs[:call_receiver].nil? && kwargs[:call_arguments].nil? && @call_block_expr.nil?
    return nil unless ENV[KILL_SWITCH] != '0' && NomethodReviewed.guard_violation_enabled? && insn.plain_fixed_argc?

    count = insn.n_spec.to_i
    return nil unless count.between?(1, CodeGen::FUNCALL_ARGC_MAX)

    original = irep.instructions[idx]
    return nil unless original && original.addr == insn.addr && original.op == insn.op && original.sym == insn.sym
    return nil unless computed_send_kernel?(insn.sym) && computed_send_world_static?

    names = ComputedSendNames.names_at(irep, idx, insn.reg.to_i + 1, computed_send_tables)
    return nil unless names && names.names.none? { |name| computed_send_name_rebound?(name) }
    return nil if names.source.include?('table') && !computed_send_tables_trusted?
    return nil if insn.sym == 'public_send' && !names.names.all? { |name| computed_send_public_only?(name) }

    { names: names, irep: irep, idx: idx, owner_def: kwargs[:owner_def] }
  end

  def computed_send_tables
    self.class.computed_send_tables || {}
  end

  # The violation arm and the arms assume nothing answers or replaces a name behind their back: a
  # closed world with no method_missing, no singleton class on an instance and no unresolved installer.
  def computed_send_world_static?
    @closed_world && @closed_world.global_refusal.nil? && @closed_world.method_missing_classes.empty? &&
      @closed_world.exact_instances_singleton_free? && !symbol_installed_names.nil?
  end

  def computed_send_name_rebound?(name)
    devirt_blocked_name?(name) || symbol_installed_names.include?(name)
  end

  # The send being replaced is mruby's own Kernel#send: a Ruby or native `send` of another class
  # could be the receiver's, and `send`/`public_send` come from a gem the build may lack
  # (`__send__` is core).
  def computed_send_kernel?(name)
    return false if devirt_blocked_name?(name)

    defs = @registry.fetch(name, [])
    return false unless defs.all? { |definition| definition.owner == '<native>' }

    name == '__send__' || !defs.empty?
  end

  # public_send checks visibility, which a direct arm does not: every definition of each name
  # must be public and stay so.
  def computed_send_public_only?(name)
    defs = @registry.fetch(name, [])
    !defs.empty? && defs.all? { |definition| definition.visibility == :public } &&
      @closed_world.visibility_stable?(name)
  end

  # The table proof reads the constant through Array#[] / Hash#[] and trusts `freeze`: nothing may
  # replace them.
  def computed_send_tables_trusted?
    (TABLE_READERS + TABLE_FREEZERS).all? do |owner, name|
      defs = @registry.fetch(name, [])
      defs.all? { |definition| definition.owner == '<native>' || !%w[Array Hash Object Kernel BasicObject].include?(definition.owner) } &&
        @closed_world.core_native_arm_safe?(name, owner)
    end
  end

  def computed_send_arm_direct?(code)
    live = code.lines.reject { |line| line.lstrip.start_with?('//') }.join
    live.include?('_impl(M') && !live.match?(DYNAMIC_ARM)
  end

  def computed_send_code(insn, names, arms, self_implicit)
    d = insn.reg.to_i
    recv = self_implicit ? 'self' : "r#{d}"
    all = (1..insn.n_spec.to_i).map { |k| "r#{d + k}" }
    var = "bc2cpp_csend_#{d}"
    violation = guard_violation_line(d, recv, insn.sym, all, 'COMPUTED_SEND')
    out = +"  // COMPUTED_SEND :#{insn.sym} (#{names.source}) over #{names.names.join('/')}: direct arm per name, " \
           "a Symbol outside the set is a proof violation (ADR 0303)\n  {\n    mrb_value #{var} = #{all.first};\n"
    out << "    if (mrb_symbol_p(#{var})) {\n      mrb_sym #{var}_id = mrb_symbol(#{var});\n"
    arms.each_with_index do |(name, code), i|
      out << "      #{i.zero? ? '' : 'else '}if (#{var}_id == mrb_intern_lit(M, \"#{name}\")) {\n"
      out << code.lines.map { |line| "        #{line}" }.join
      out << "      }\n"
    end
    out << "      else {\n        #{violation.chomp}\n      }\n    } else {\n"
    # TypeError for nil, exactly as Kernel#send raises it; a value the table cannot hold is a violation.
    out << "      (void)mrb_obj_to_sym(M, #{var});\n" if names.nilable
    out << "      #{violation.chomp}\n    }\n  }\n"
    out
  end
end

CodeGen.prepend(ComputedSend)
CodeGen.singleton_class.attr_accessor :computed_send_tables
