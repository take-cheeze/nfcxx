# frozen_string_literal: true

require_relative 'computed_send_names'
require_relative 'dynamic_names'

# COMPUTED_SEND_EXPANSION: `send(name, args...)` whose name register provably holds one of a
# finite set of plain Symbols (ComputedSendNames) becomes a chain of direct calls, one per name,
# each compiled as the literal-name send of the same site (so it inherits that name's own
# visibility, arity and dispatch proofs). It is taken only when every arm is a direct call with no
# by-name dispatch left in it; otherwise the site keeps its single computed send.
#
# The default arm is not a fallback: a Symbol outside the proven set is a proof violation
# and the one non-Symbol value a table can yield, nil, raises the TypeError `send`
# raises for it.
#
# COMPUTED_SEND_GUARDED: a computed send on self whose name is not provable instead tries the names self's
# class defines that the program spells as Symbols (DynamicNames) and that accept the call's argument count,
# one direct arm each, and keeps the original send as its default arm for any other value.
module ComputedSend
  # Only `__send__`: `send`/`public_send` come from mruby-metaprog, which a build (or a test harness
  # compiling against more gems than it links) may lack, and a direct arm would then answer where the
  # interpreter raises NoMethodError.
  SEND_NAMES = %w[__send__].freeze
  # `send` too when the closed world shows the build's only definition is Kernel's native one (mruby-metaprog).
  METAPROG_SEND_NAMES = %w[send].freeze
  # =0 keeps an unproven computed send as one by-name call.
  GUARDED_SWITCH = 'BC2CPP_COMPUTED_SEND_GUARDED'
  # COMPUTED_SEND_GUARDED: at most this many arms per site (the code size of the expansion, not its speed: the
  # arm is found through a table, see computed_send_guarded_dispatch).
  GUARDED_MAX_ARMS = 512
  # =0 keeps every computed send as one by-name call (the before side of a measurement).
  KILL_SWITCH = 'BC2CPP_COMPUTED_SEND'
  # Core containers whose [] / freeze the table proof reads through.
  TABLE_READERS = [%w[Array []], %w[Hash []]].freeze
  TABLE_FREEZERS = [%w[Array freeze], %w[Hash freeze], %w[Object freeze], %w[Kernel freeze]].freeze
  DYNAMIC_ARM = /\b(?:bc2cpp_send|bc2cpp_funcall\w*|mrb_funcall\w*|bc2cpp_nomethod\w*|bc2cpp_guard_violation\w*|bc2cpp_hint_violation\w*)\(|#error/

  def compile_send(insn, **kwargs)
    computed_send_expansion(insn, kwargs) { super } || super
  end

  private

  def computed_send_expansion(insn, kwargs, &original)
    plan = computed_send_plan(insn, kwargs)
    return computed_send_guarded(insn, kwargs, &original) unless plan

    names, irep, idx, owner_def = plan.values_at(:names, :irep, :idx, :owner_def)
    d = insn.reg.to_i
    self_implicit = BytecodeIR::Ops::SELF_SEND_FAMILY.include?(insn.op)
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
    return nil unless irep && idx && %i[SEND SSEND].include?(insn.op) &&
                      computed_send_name?(insn.sym, insn.op == :SSEND ? kwargs[:owner_def]&.owner : nil)
    return nil unless kwargs[:call_receiver].nil? && kwargs[:call_arguments].nil? && @call_block_expr.nil?
    return nil unless ENV[KILL_SWITCH] != '0' && NomethodReviewed.guard_violation_enabled? && insn.plain_fixed_argc?

    count = insn.n_spec.to_i
    return nil unless count.between?(1, CodeGen::FUNCALL_ARGC_MAX)

    original = BytecodeIR.for(irep).source_at(idx)
    return nil unless original && original.addr == insn.addr && original.op == insn.op && original.sym == insn.sym
    return nil unless computed_send_kernel?(insn.sym) && computed_send_world_static?

    names = ComputedSendNames.names_at(irep, idx, insn.reg.to_i + 1, computed_send_tables)
    return nil unless names && names.names.none? { |name| computed_send_name_rebound?(name) }
    return nil if names.source.include?('table') && !computed_send_tables_trusted?

    { names: names, irep: irep, idx: idx, owner_def: kwargs[:owner_def] }
  end

  # `owner`: the class of self at the site, whose own ancestors are the only definers that matter.
  def computed_send_name?(name, owner = nil)
    return true if SEND_NAMES.include?(name)
    return false unless METAPROG_SEND_NAMES.include?(name) && @closed_world

    owners = outside_owner_call_owners(name)
    return false unless owners&.include?('Kernel')
    return owners == ['Kernel'] unless owner

    chain = computed_send_chain(owner)
    chain && (owners - ['Kernel']).none? { |definer| chain.include?(definer) }
  end

  # `owner`, its program superclasses and their modules, and Object's own chain; nil for a module (any class
  # may include it) or a class whose chain reaches a core class other than Object.
  def computed_send_chain(owner)
    return nil unless @superclass_of.key?(owner)

    chain = []
    klass = owner
    while klass.is_a?(String) && @superclass_of.key?(klass) && !chain.include?(klass)
      chain << klass
      chain.concat(Array(@included_modules[klass]), Array(@prepended_modules[klass]))
      klass = @superclass_of[klass]
    end
    return nil unless klass == :none || klass == 'Object'

    chain + %w[Object Kernel BasicObject]
  end

  # COMPUTED_SEND_GUARDED: the expansion of an unproven name on self, or nil.
  def computed_send_guarded(insn, kwargs, &)
    irep, idx, owner_def = kwargs.values_at(:irep, :idx, :owner_def)
    return nil unless ENV[KILL_SWITCH] != '0' && ENV[GUARDED_SWITCH] != '0' && irep && idx && insn.op == :SSEND
    return nil unless owner_def && computed_send_name?(insn.sym, owner_def.owner)
    return nil unless kwargs[:call_receiver].nil? && kwargs[:call_arguments].nil? && @call_block_expr.nil?
    return nil unless computed_send_kernel?(insn.sym) && computed_send_world_static?

    original = BytecodeIR.for(irep).source_at(idx)
    return nil unless original && original.addr == insn.addr && original.op == insn.op && original.sym == insn.sym
    return computed_send_guarded_splat(insn, irep, idx, owner_def, &) if insn.n_spec == '*' && insn.nk_spec.nil?
    return nil unless insn.plain_fixed_argc?

    count = insn.n_spec.to_i
    return nil unless count.between?(1, CodeGen::FUNCALL_ARGC_MAX)

    d = insn.reg.to_i
    rest = (2..count).map { |k| "r#{d + k}" }
    arms = computed_send_guarded_names(owner_def.owner, count - 1).filter_map do |name|
      code = splat_send_with(name, d, true, irep, idx, owner_def, rest, nil)
      [name, code] if code && computed_send_arm_direct?(code)
    end
    return nil if arms.empty?

    computed_send_guarded_code(insn, arms, yield)
  end

  # `send(*args)`: the packed Array's first element is the name and its length picks the arity; each arm reads
  # its arguments out of the Array before the call.
  def computed_send_guarded_splat(insn, irep, idx, owner_def)
    d = insn.reg.to_i
    ary = "bc2cpp_gsplat_#{d}"
    groups = (0..[CodeGen::FUNCALL_ARGC_MAX - 1, 8].min).filter_map do |argc|
      argv = (1..argc).map { |k| "#{ary}_a#{k}" }
      arms = computed_send_guarded_names(owner_def.owner, argc).filter_map do |name|
        code = splat_send_with(name, d, true, irep, idx, owner_def, argv, nil)
        [name, code] if code && computed_send_arm_direct?(code)
      end
      [argc, arms] unless arms.empty?
    end
    total = groups.sum { |_, arms| arms.size }
    return nil if groups.empty? || total > GUARDED_MAX_ARMS

    fallback = yield
    list = "r#{d + 1}"
    out = +"  // COMPUTED_SEND_GUARDED :#{insn.sym} n=* over #{total} spelled names of self's class by arity; " \
           "any other value keeps the original send\n  {\n    bool #{ary}_done = false;\n"
    out << "    if (mrb_array_p(#{list}) && RARRAY_LEN(#{list}) >= 1 && mrb_symbol_p(RARRAY_PTR(#{list})[0])) {\n"
    out << "      mrb_sym #{ary}_id = mrb_symbol(RARRAY_PTR(#{list})[0]);\n      switch (RARRAY_LEN(#{list}) - 1) {\n"
    groups.each do |argc, arms|
      out << "      case #{argc}: {\n"
      (1..argc).each { |k| out << "        mrb_value #{ary}_a#{k} = RARRAY_PTR(#{list})[#{k}];\n" }
      out << computed_send_guarded_dispatch("#{ary}_id", "#{ary}_done", arms, '        ')
      out << "        break;\n      }\n"
    end
    out << "      default: break;\n      }\n    }\n    if (!#{ary}_done) {\n"
    out << fallback.lines.map { |line| "    #{line}" }.join
    out << "    }\n  }\n"
    out
  end

  # The arm for Symbol `id` among `arms`: a per-site table from Symbol id to arm number, built on the first call
  # for each mrb_state (Symbols are never collected, so the ids stay valid), then a switch on the number.
  def computed_send_guarded_dispatch(id, done, arms, pad)
    @computed_send_site_seq = (@computed_send_site_seq || 0) + 1
    tab = "bc2cpp_gtab_#{@computed_send_site_seq}"
    syms = arms.map { |name, _| "mrb_intern_lit(M, \"#{name}\")" }
    out = +"#{pad}static mrb_state* #{tab}_M = nullptr;\n#{pad}static uint16_t* #{tab} = nullptr;\n" \
           "#{pad}static mrb_sym #{tab}_max = 0;\n"
    out << "#{pad}if (#{tab}_M != M) {\n#{pad}  const mrb_sym syms[] = { #{syms.join(', ')} };\n"
    out << "#{pad}  mrb_sym max = 0;\n#{pad}  for (mrb_sym s : syms) if (s > max) max = s;\n"
    out << "#{pad}  free(#{tab});\n#{pad}  #{tab} = static_cast<uint16_t*>(calloc(max + 1, sizeof(uint16_t)));\n"
    out << "#{pad}  for (size_t k = 0; k < sizeof(syms) / sizeof(syms[0]); ++k) #{tab}[syms[k]] = (uint16_t)(k + 1);\n"
    out << "#{pad}  #{tab}_max = max;\n#{pad}  #{tab}_M = M;\n#{pad}}\n"
    out << "#{pad}switch (#{id} <= #{tab}_max ? #{tab}[#{id}] : 0) {\n"
    arms.each_with_index do |(name, code), i|
      out << "#{pad}case #{i + 1}: {  // :#{name}\n"
      out << code.lines.map { |line| "#{pad}  #{line}" }.join
      out << "#{pad}  #{done} = true;\n#{pad}  break;\n#{pad}}\n"
    end
    out << "#{pad}default: break;\n#{pad}}\n"
    out
  end

  # Spelled names `owner` itself defines in bytecode whose arity accepts `argc` arguments, sorted.
  def computed_send_guarded_names(owner, argc)
    @computed_send_universe ||= DynamicNames.universe(@ireps)
    names = @computed_send_universe.select do |name|
      next false if computed_send_name_rebound?(name) || !name.match?(/\A[a-z_]\w*[?!]?\z/)

      (@registry[name] || []).any? do |definition|
        definition.owner == owner && definition.irep && computed_send_accepts?(@ireps.fetch(definition.irep), argc)
      end
    end
    names.sort.first(GUARDED_MAX_ARMS + 1).then { |list| list.size > GUARDED_MAX_ARMS ? [] : list }
  end

  def computed_send_accepts?(t_irep, argc)
    mand = mandatory_arity(t_irep)
    return argc >= mand if rest_only_callee?(t_irep)

    argc.between?(mand, mand + positional_optional_count(t_irep))
  end

  def computed_send_guarded_code(insn, arms, fallback)
    d = insn.reg.to_i
    var = "bc2cpp_gsend_#{d}"
    out = +"  // COMPUTED_SEND_GUARDED :#{insn.sym} over #{arms.size} spelled names of self's class; " \
           "any other value keeps the original send\n  {\n    mrb_value #{var} = r#{d + 1};\n    bool #{var}_done = false;\n"
    out << "    if (mrb_symbol_p(#{var})) {\n      mrb_sym #{var}_id = mrb_symbol(#{var});\n"
    out << computed_send_guarded_dispatch("#{var}_id", "#{var}_done", arms, '      ')
    out << "    }\n    if (!#{var}_done) {\n"
    out << fallback.lines.map { |line| "    #{line}" }.join
    out << "    }\n  }\n"
    out
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

  # The send being replaced is mruby's own core `__send__`: a Ruby or native definition of it on another
  # class could be the receiver's.
  def computed_send_kernel?(name)
    return false if devirt_blocked_name?(name)

    @registry.fetch(name, []).all? { |definition| definition.owner == '<native>' }
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
