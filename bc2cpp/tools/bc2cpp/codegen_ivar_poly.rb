# frozen_string_literal: true

# CodeGen: POLY_SMALL_N chains, ivar access and outlined index helpers.

class CodeGen
  # POLY_SMALL_N_SUPPORT: a POLY name can still become a chain of
  # runtime-class-checked direct calls, one `if` per eligible owner, ending in
  # mrb_funcall for every other class. A single eligible target is useful too;
  # the fallback covers native, unclean or filtered definitions.
  # Bounded by POLY_SMALL_N_MAX: past that a linear chain of class compares is
  # no longer clearly cheaper than mruby's method-table lookup, and code size
  # keeps growing. 16 covers the `dispose` family; POLY_TABLE
  # (compile_poly_table) takes the names past it, such as `update`.
  # C++ vtables are not an option: mruby objects are tagged mrb_values, not C++
  # polymorphic instances; the mrb_obj_class chain reuses the TYPED/IVAR_ACCESSOR
  # trust model.
  # Narrower than TYPED/MONO: only pure-mandatory candidates whose arity equals
  # the call's `n` join; others are left to the fallback. Same
  # @only_owners/@other_owners gate (no `_impl` for owners not emitted).
  POLY_SMALL_N_MAX = 16

  # ADR 0259: a definition with optional parameters joins a chain (its `_impl`
  # takes every optional, see direct_call_args); the table path keeps the
  # exact-arity rule, so the wider set is used only while it still fits a chain.
  def poly_small_n_targets(name, n)
    [true, false].each do |optional|
      candidates = poly_candidates(name, n, optional: optional)
      return candidates if candidates && candidates.size <= POLY_SMALL_N_MAX
    end
    nil
  end

  # Every definition of `name` a runtime-class-checked direct call can reach
  # for an `n`-argument send, uncapped; nil when there is none.
  def poly_candidates(name, n, optional: false)
    # RUNTIME_DEF_DEVIRT_GUARD: same gate as monomorphic_target. The chain's
    # `mrb_obj_class(M, recv) == Widget` guard still matches an object whose
    # singleton class was just given its own `shared_name`.
    return nil if devirt_blocked_name?(name)

    defs = @registry[name]
    # LONE_ACCESSOR_CHAIN: a name whose only definition is a plain attr_reader/
    # attr_writer (LCF::EventCommand `indent`/`code`) cannot be MONO (no bytecode).
    # The receiver may be any class (rpgxp/rpgvx/wolf define their own), so it is
    # a one-candidate exact-class chain with the funcall fallback.
    lone_accessor = defs && defs.size == 1 && defs.first.kind == :ivar_accessor && defs.first.irep.nil?
    return nil unless defs && (defs.size >= 2 || lone_accessor)

    # An owner with two definitions of the name (attr_reader later redefined by a
    # def, or the reverse) never joins: which one is live depends on definition
    # order.
    repeated_owners = defs.group_by(&:owner).select { |_, group| group.size > 1 }.keys
    candidates = defs.select do |t|
      next false if repeated_owners.include?(t.owner)

      # POLY_SMALL_N_ACCESSOR: an :ivar_accessor definition (no irep) joins the chain
      # as a bare mrb_iv_get/mrb_iv_set behind the IVAR_ACCESSOR_DEVIRT guard. The
      # shape check is its arity (0 reader, 1 writer); no ONLY_OWNERS gate needed.
      if t.kind == :ivar_accessor && t.irep.nil?
        next false if t.owner.end_with?('.singleton')
        next false unless n == (name.end_with?('=') ? 1 : 0)

        # EMBEDDED_ACCESSOR_CHAIN: an embedded ivar is only reachable through its
        # synthesized accessor, which IVAR_ACCESS uses when it is linkable from
        # here; otherwise leave the candidate out (the funcall reaches it).
        next !ivar_accessor_call_code(t.owner, 'recv', name, 0, ['arg']).nil?
      end
      next false unless t.irep
      # SINGLETON_OWNER_EXCLUSION: a `.singleton` owner can never match the guard:
      # mrb_obj_class is mrb_class_real(mrb_class(obj)) (src/class.c), which skips
      # SCLASS/ICLASS and returns e.g. Module, and const_chain_value_expr strips the
      # suffix. Such a candidate would be dead code, so it is excluded.
      next false if t.owner.end_with?('.singleton')
      next false unless compiles_clean?(t.irep)

      t_irep = @ireps.fetch(t.irep)
      next false unless poly_arity_fits?(t_irep, n, optional)
      next false unless native_arg_types(t, mandatory_arity(t_irep)).compact.empty?

      if @only_owners && !@only_owners.include?(t.owner)
        next false unless @other_owners&.include?(t.owner)
      end

      true
    end
    candidates unless candidates.empty?
  end

  def poly_arity_fits?(irep, n, optional)
    return pure_mandatory_arity?(irep) && n == mandatory_arity(irep) unless optional

    pure_mandatory_or_optional_arity?(irep) && n.between?(mandatory_arity(irep), mandatory_arity(irep) + optional_arity(irep))
  end

  # POLY_DIAGNOSTICS: definition-level exclusion counts attached to each
  # emitted polymorphic call site. They explain table coverage; they do not
  # claim that every excluded definition is reachable at that particular site.
  def poly_diagnostic(name, n, path, candidates, receiver: 'runtime_class', origin: nil)
    @poly_diagnostic_reason_cache ||= {}
    cache_key = [name, n, candidates.map(&:object_id)]
    reasons = @poly_diagnostic_reason_cache[cache_key]
    unless reasons
      defs = @registry[name] || []
      reasons = Hash.new(0)
      if devirt_blocked_name?(name)
        reasons[:runtime_definition_guard] += defs.size
      elsif defs.size < 2 && !(defs.size == 1 && defs.first.kind == :ivar_accessor && defs.first.irep.nil?)
        reasons[defs.empty? ? :no_registered_definition : :single_registered_definition] += 1
      else
        eligible = candidates.map(&:object_id).to_set
        repeated = defs.group_by(&:owner).select { |_owner, group| group.size > 1 }.keys
        defs.each do |target|
          next if eligible.include?(target.object_id)

          reason = if repeated.include?(target.owner)
                     :redefined_owner
                   elsif target.owner.end_with?('.singleton')
                     :singleton_owner
                   elsif target.kind == :ivar_accessor
                     n == (name.end_with?('=') ? 1 : 0) ? :accessor_unlinkable : :arity
                   elsif !target.irep
                     native_direct_lifted?(name, n) ? :native_direct : :native_or_uncompiled
                   elsif !compiles_clean?(target.irep)
                     :unclean
                   elsif !pure_mandatory_or_optional_arity?(@ireps.fetch(target.irep))
                     :unsupported_arity
                   elsif !poly_arity_fits?(@ireps.fetch(target.irep), n, true)
                     :arity
                   elsif !native_arg_types(target, n).compact.empty?
                     :native_argument
                   elsif @only_owners && !@only_owners.include?(target.owner) && !@other_owners&.include?(target.owner)
                     :owner_not_emitted
                   else
                     :not_in_candidate_set
                   end
          reasons[reason] += 1
        end
      end
      @poly_diagnostic_reason_cache[cache_key] = reasons
    end
    excluded = reasons.sort_by { |reason, _| reason.to_s }.map { |reason, count| "#{reason}=#{count}" }.join(',')
    "  // POLY_DIAG path=#{path} receiver=#{receiver} name=#{name.inspect} arity=#{n} candidates=#{candidates.size} " \
      "excluded=#{excluded.empty? ? 'none' : excluded}#{" origin=#{origin}" if origin}\n"
  end

  # True when `owner`'s ivar behind accessor `name` (a reader `code`, or a writer
  # `code=`) is embedded in the RData struct and therefore served by a synthesized
  # accessor pair (ATTR_STRUCT_DEVIRT, emit_ivar_accessor_pair) instead of the
  # native attr_reader/attr_writer.
  def embedded_accessor?(owner, name)
    writer = name.end_with?('=')
    @synthesize_accessor_for.include?([owner, name.chomp('='), writer ? :writer : :reader])
  end

  # IVAR_ACCESS: the only emitter of ivar access on `recv`, an object of exact
  # class `klass` (nil: unknown). GETIV/SETIV and every devirtualized accessor go
  # through here, so an embedded ivar never touches iv_tbl, where it reads nil.
  # `self_of_klass` means `recv` is self inside klass's own compiled body, whose
  # struct is always in this file. Returns nil when only dispatch can reach it.
  def ivar_get_code(klass, recv, ivar, dst, self_of_klass: false)
    type = ivar_embed_type(klass, ivar)
    return "#{dst} = mrb_iv_get(M, #{recv}, mrb_intern_cstr(M, \"@#{ivar}\"));" if type.nil?
    return nil if type == :unknown

    if self_of_klass
      field = "((#{struct_name(klass)}*)DATA_PTR(#{recv}))->#{ivar_field_name(ivar)}"
      value = type == :value ? "(mrb_undef_p(#{field}) ? mrb_nil_value() : #{field})" : "#{TYPE_OPS.fetch(type)[:box]}(#{field})"
      "#{dst} = #{value};"
    elsif embedded_accessor_linkable?(klass, ivar)
      "#{dst} = #{sanitize(klass)}_#{sanitize(ivar)}_impl(M, #{recv});"
    end
  end

  # IVAR_ACCESS's write half: the statement storing `src` into @ivar, or nil.
  # Same rules as ivar_get_code. With `dst`, it also leaves `src` (attr_writer's
  # return value) in `dst`.
  def ivar_set_code(klass, recv, ivar, src, self_of_klass: false, dst: nil, indent: '  ')
    type = ivar_embed_type(klass, ivar)
    tail = dst ? "\n#{indent}#{dst} = #{src};" : ''
    return "mrb_iv_set(M, #{recv}, mrb_intern_cstr(M, \"@#{ivar}\"), #{src});#{tail}" if type.nil?
    return nil if type == :unknown

    if self_of_klass
      unless src.match?(/\A\w+\z/)
        store = ivar_set_code(klass, recv, ivar, 'bc2cpp_iv_val', self_of_klass: true, indent: indent)
        return "{ mrb_value bc2cpp_iv_val = #{src}; #{store} }#{tail}"
      end

      if type == :value
        field = "((#{struct_name(klass)}*)DATA_PTR(#{recv}))->#{ivar_field_name(ivar)}"
        return "#{indent}#{field} = #{src};\n#{indent}mrb_field_write_barrier_value(M, " \
               "(struct RBasic*)mrb_obj_ptr(#{recv}), #{src});#{tail}"
      end

      ops = TYPE_OPS.fetch(type)
      # Guarded: an uncompiled writer could still store another type. (Not
      # E_TYPE_ERROR: that macro hardcodes `mrb`; generated code names it `M`.)
      # NILABLE_EMBED_SUPPORT: a tagged field has no single `= unbox(src)`
      # expression, so it stores through bc2cpp_fixnum_or_nil_set instead. The
      # check still runs first, so a refused value leaves the field unchanged.
      store =
        if NULLABLE_TYPES.include?(type)
          "#{indent}bc2cpp_fixnum_or_nil_set(&((#{struct_name(klass)}*)DATA_PTR(#{recv}))->#{ivar_field_name(ivar)}, #{src});"
        else
          "#{indent}((#{struct_name(klass)}*)DATA_PTR(#{recv}))->#{ivar_field_name(ivar)} = #{ops[:unbox]}(#{src});"
        end
      "if (!#{ops[:check]}(#{src})) mrb_raise(M, mrb_exc_get_id(M, mrb_intern_lit(M, \"TypeError\")), \"@#{ivar}: expected #{ops[:err]}\");\n" \
        "#{store}#{tail}"
    elsif embedded_accessor_linkable?(klass, "#{ivar}=")
      "#{dst ? "#{dst} = " : ''}#{sanitize(klass)}_#{sanitize(ivar)}_eq_impl(M, #{recv}, #{src});"
    end
  end

  # IVAR_ACCESS for an attr_reader/attr_writer call `name` on `recv`: the
  # statements leaving the call's value in r<d>, or nil.
  def ivar_accessor_call_code(klass, recv, name, d, argv, self_of_klass: false, indent: '  ')
    ivar = name.chomp('=')
    return ivar_get_code(klass, recv, ivar, "r#{d}", self_of_klass: self_of_klass) unless name.end_with?('=')

    ivar_set_code(klass, recv, ivar, argv.first, self_of_klass: self_of_klass, dst: "r#{d}", indent: indent)
  end

  # nil: use the runtime ivar API, which routes through an RData slot descriptor
  # when present and falls back to iv_tbl for dynamic names.
  def ivar_embed_type(klass, ivar)
    return embed_type(klass, ivar) if klass

    nil
  end

  # The synthesized accessor (reader `name`, writer `name=`) exists and is
  # defined by this file or declared by another compiled gem's header.
  def embedded_accessor_linkable?(owner, name)
    return false unless embedded_accessor?(owner, name)

    !@only_owners || @only_owners.include?(owner) || @other_owners&.include?(owner) || false
  end

  POLY_SMALL_N_INHERITED_MAX = 16

  # INHERITED_GUARD: closed-world strict subclasses of `owner` whose instances'
  # lookup of `name` provably ends at `owner`'s own def: no class on the way
  # defines it or mixes anything in, and nothing aliases/undefines the name.
  def inheriting_subclasses(name, owner)
    installed = symbol_installed_names
    return [] if installed.nil? || installed.include?(name)
    return [] unless Array(@prepended_modules[owner]).empty? && !@unknown_mixins.include?(owner)
    # A native def outside mruby's core (which only touches core classes) could
    # sit on a subclass; without the source map any native def declines.
    natives = @native_name_sources ? @native_name_sources.fetch(name, []) : nil
    if natives.nil?
      return [] if @registry.fetch(name, []).any? { |md| md.owner == '<native>' }
    elsif natives.any? { |path| !path.match?(%r{/3rd/mruby/(?:src|mrbgems)/}) }
      return []
    end

    def_owners = @registry.fetch(name, []).map(&:owner).to_set
    mixed = lambda do |klass|
      !Array(@included_modules[klass]).empty? || !Array(@prepended_modules[klass]).empty? ||
        @unknown_mixins.include?(klass)
    end
    @superclass_of.keys.sort.select do |klass|
      next false unless strict_subclass?(klass, owner)

      k = klass
      k = @superclass_of[k] until k == owner || def_owners.include?(k) || mixed.call(k)
      k == owner
    end.first(POLY_SMALL_N_INHERITED_MAX)
  end

  # INHERITED_GUARD's subclasses per candidate owner.
  def poly_inherited(name, candidates)
    candidates.to_h do |t|
      subs = inheriting_subclasses(name, t.owner)
      # An accessor's storage is the owner's; skip a subclass that embeds the ivar itself.
      if t.kind == :ivar_accessor && t.irep.nil?
        subs = subs.reject do |s|
          k = s
          k = @superclass_of[k] until k == t.owner || embed_type(k, name.chomp('='))
          k != t.owner
        end
      end
      [t.owner, subs]
    end
  end

  # The chain, or past POLY_SMALL_N_MAX the table, so a name that outgrows the
  # chain cap does not fall to plain dispatch (ADR 0261).
  def compile_poly_dispatch(name, d, recv, argv, n, closed_world_site: nil)
    compile_poly_small_n(name, d, recv, argv, n, closed_world_site: closed_world_site) ||
      compile_poly_table(name, d, recv, argv, n, closed_world_site: closed_world_site)
  end

  def compile_poly_small_n(name, d, recv, argv, n, closed_world_site: nil)
    candidates = poly_small_n_targets(name, n)
    return nil unless candidates

    inherited = poly_inherited(name, candidates)
    # INHERITED_GUARD: a subclass that inherits a candidate's def joins its
    # branch; the receiver's class is then read once instead of per compare.
    hoist = inherited.values.any?(&:any?)
    recv_class = hoist ? 'bc2cpp_recv_class' : "mrb_obj_class(M, #{recv})"
    branches = candidates.map do |target|
      check = ([target.owner] + inherited[target.owner]).map do |owner|
        "#{owner_class_ptr_expr(owner)} == #{recv_class}"
      end.join(' || ')
      call = if target.kind == :ivar_accessor && target.irep.nil?
               # POLY_SMALL_N_ACCESSOR: attr_reader/attr_writer are a bare
               # mrb_iv_get / mrb_iv_set (3rd/mruby/src/class.c), or the
               # synthesized accessor for an embedded ivar; the writer returns
               # the assigned value, not the ivar read back.
               ivar_accessor_call_code(target.owner, recv, name, d, argv, indent: '    ')
             else
               impl = cpp_name(target.owner, target.name) + '_impl'
               call_argv, = direct_call_args(target, argv, impl)
               "r#{d} = #{impl}(M, #{([recv] + call_argv).join(', ')});"
             end
      "if (#{check}) {\n    #{call}\n  } else "
    end
    owners_note = candidates.map(&:owner).join(', ')
    diag = poly_diagnostic(name, n, 'chain', candidates)
    note = "  // POLY_SMALL_N :#{name} -> #{owners_note} (#{candidates.size} known real definitions), " \
           "runtime-class-checked direct C++ calls chained, mrb_funcall fallback for any other class\n"
    listed = candidates.flat_map { |t| [t.owner] + inherited[t.owner] }
    fallback = guarded_fallback_line(d, recv, name, argv, listed, closed_world_site)
    chain = "#{branches.join}{\n    #{fallback}  }\n"
    return "#{diag}#{note}  #{chain}" unless hoist

    subs = inherited.flat_map { |owner, list| list.map { |s| "#{s} < #{owner}" } }
    "#{diag}#{note}  // INHERITED_GUARD :#{name} -- also #{subs.join(', ')}\n" \
      "  {\n  struct RClass* #{recv_class} = mrb_obj_class(M, #{recv});\n  #{chain}  }\n"
  end

  # CHA_SELF (ADR 0254): `self.name` in a method of class C reaches C or one of
  # its descendants. When the closed world enumerates them all, the receiver's
  # class need not be compared: every descendant either resolves `name` to the
  # definition C's own lookup finds, or to one of a few overriders, and those
  # get exact-class arms (with the classes that inherit from them) ahead of a
  # default arm.
  CHA_SELF_GUARDS_MAX = 8

  # [plan, reason]: plan is { default: MethodDef, arms: [[MethodDef, [class...]]] }
  # or nil with the Symbol naming the refusal. `explicit` is a `self.name` send
  # (public methods only), as opposed to an implicit-self call.
  def cha_self_plan(name, n, self_owner, explicit:)
    return [nil, :no_closed_world] unless @closed_world
    return [nil, :not_a_class] if self_owner.end_with?('.singleton') || !@closed_world.class_declared?(self_owner)
    return [nil, :blocked_name] if devirt_blocked_name?(name)

    hierarchy = @closed_world.class_hierarchy(self_owner)
    return [nil, :opaque_hierarchy] unless hierarchy
    return [nil, :unsafe_name] unless @closed_world.inherited_lookup_safe?(name, self_owner)

    installed = symbol_installed_names
    return [nil, :installed_name] if installed.nil? || installed.include?(name)
    return [nil, :native_definition] if @registry.fetch(name, []).any? { |d| d.owner == '<native>' }
    return [nil, :method_missing] unless @closed_world.self_method_missing_free?(self_owner)

    default, known = closed_world_lookup_target(name, self_owner, Set.new, self_call: true)
    return [nil, known ? :no_definition : :ambiguous_lookup] unless default

    descendants = hierarchy[:descendants]
    return [nil, :mixin_in_the_way] if descendants.any? { |klass| cha_mixin_may_define?(name, klass) }

    overriders = @registry.fetch(name, []).select { |d| descendants.include?(d.owner) }
    unless overriders.empty?
      return [nil, :wild_subclass] unless hierarchy[:wild].empty?
      return [nil, :redefined_owner] if overriders.group_by(&:owner).any? { |_, defs| defs.size > 1 }
    end

    arms = cha_override_arms(overriders, self_owner, descendants)
    return [nil, :unresolved_chain] unless arms
    return [nil, :too_many_guards] if arms.sum { |_, classes| classes.size } > CHA_SELF_GUARDS_MAX

    ([default] + arms.map(&:first)).each do |t|
      reason = cha_unready_reason(t, name, n, explicit, descendants)
      return [nil, reason] if reason
    end
    [{ default: default, arms: arms }, nil]
  end

  # Does a mixin on `klass` (a descendant) possibly supply `name`? Any mixin the
  # compiler cannot name, or whose own mixins it cannot follow, may.
  def cha_mixin_may_define?(name, klass)
    return true if @unknown_mixins.include?(klass)

    (Array(@included_modules[klass]) + Array(@prepended_modules[klass])).any? do |mod|
      cha_module_may_define?(name, mod, Set.new)
    end
  end

  def cha_module_may_define?(name, mod, seen)
    return false unless seen.add?(mod)
    return true unless @closed_world.stable_constant_identity?(mod) && !@unknown_mixins.include?(mod)
    return true if @registry.fetch(name, []).any? { |d| d.owner == mod }

    (Array(@included_modules[mod]) + Array(@prepended_modules[mod])).any? do |inner|
      cha_module_may_define?(name, inner, seen)
    end
  end

  # [[MethodDef, classes]] for each overrider: the classes whose lookup of the
  # name ends at it (the overrider and the descendants inheriting from it). nil
  # when a descendant's chain to `self_owner` cannot be followed.
  def cha_override_arms(overriders, self_owner, descendants)
    return [] if overriders.empty?

    by_owner = overriders.to_h { |d| [d.owner, d] }
    classes = Hash.new { |h, k| h[k] = [] }
    descendants.sort.each do |klass|
      k = klass
      seen = Set.new
      until k == self_owner || by_owner.key?(k)
        return nil unless k.is_a?(String) && seen.add?(k)

        k = @superclass_of[k]
      end
      classes[k] << klass if by_owner.key?(k)
    end
    overriders.map { |d| [d, classes[d.owner]] }
  end

  # nil when `t` can be called directly from this site, else why not.
  def cha_unready_reason(t, name, n, explicit, descendants)
    return :singleton_definer if t.owner.end_with?('.singleton')
    return :private_definer if explicit && t.visibility != :public
    if @only_owners && !@only_owners.include?(t.owner) && !@other_owners&.include?(t.owner)
      return :owner_not_emitted
    end

    if t.irep.nil?
      return :not_compiled unless t.kind == :ivar_accessor && n == (name.end_with?('=') ? 1 : 0)

      # A descendant that embeds the ivar the accessor's owner keeps in iv_tbl
      # (or the reverse) has a different storage than the accessor's.
      ivar = name.chomp('=')
      return :embedded_elsewhere if descendants.any? { |k| k != t.owner && embed_type(k, ivar) }
      return :accessor_unlinkable if ivar_accessor_call_code(t.owner, 'recv', name, 0, ['arg']).nil?

      return nil
    end

    irep = @ireps.fetch(t.irep)
    return :arity unless pure_mandatory_or_optional_arity?(irep) &&
                         n.between?(mandatory_arity(irep), mandatory_arity(irep) + optional_arity(irep))
    return :unclean unless compiles_clean?(t.irep)

    nil
  end

  # The statements calling one CHA_SELF target into r<d>.
  def cha_call_code(t, self_owner, recv, name, d, argv, indent: '  ')
    if t.irep.nil?
      return ivar_accessor_call_code(t.owner, recv, name, d, argv, self_of_klass: t.owner == self_owner,
                                                                    indent: indent)
    end

    impl = cpp_name(t.owner, t.name) + '_impl'
    call_argv, = direct_call_args(t, argv, impl)
    "r#{d} = #{impl}(M, #{([recv] + call_argv).join(', ')});"
  end

  def cha_self_code(plan, self_owner, name, d, recv, argv)
    default = plan[:default]
    arms = plan[:arms]
    if arms.empty?
      return "  // CLOSED_WORLD_SELF :#{name} -> #{default.owner}##{default.name} (self in #{self_owner}; " \
             "class hierarchy analysis: no descendant defines or mixes in the name), direct C++ call\n" \
             "  #{cha_call_code(default, self_owner, recv, name, d, argv)}\n"
    end

    note = arms.map { |t, classes| "#{t.owner} (#{classes.join(', ')})" }.join('; ')
    hoist = arms.sum { |_, classes| classes.size } > 1
    recv_class = hoist ? 'bc2cpp_recv_class' : "mrb_obj_class(M, #{recv})"
    branches = arms.map do |t, classes|
      check = classes.map { |k| "#{owner_class_ptr_expr(k)} == #{recv_class}" }.join(' || ')
      "if (#{check}) {\n    #{cha_call_code(t, self_owner, recv, name, d, argv, indent: '    ')}\n  } else "
    end
    chain = "#{branches.join}{\n    #{cha_call_code(default, self_owner, recv, name, d, argv, indent: '    ')}\n  }\n"
    head = "  // CLOSED_WORLD_SELF :#{name} -> #{default.owner}##{default.name} (self in #{self_owner}; class " \
           "hierarchy analysis: only #{note} override), exact-class arms for the overriders, " \
           "the inherited definition for every other receiver\n"
    return "#{head}  #{chain}" unless hoist

    "#{head}  {\n  struct RClass* #{recv_class} = mrb_obj_class(M, #{recv});\n  #{chain}  }\n"
  end

  # POLY_TABLE (ADR 0227): a name with more than POLY_SMALL_N_MAX candidates
  # gets one file-scope table of {owner, `_impl`} rows shared by every site,
  # instead of a per-site chain. The site looks the receiver's class up and
  # calls the `_impl` it finds; any other class takes the same guarded fallback
  # as a POLY_SMALL_N chain. Bounded by POLY_TABLE_MAX to keep a scan short.
  POLY_TABLE_MAX = 64
  # Entries in each table's memo of recent lookups (a power of two).
  POLY_TABLE_MEMO = 8

  def compile_poly_table(name, d, recv, argv, n, closed_world_site: nil)
    candidates = poly_candidates(name, n)
    return nil unless candidates && candidates.size.between?(POLY_SMALL_N_MAX + 1, POLY_TABLE_MAX)

    # POLY_SMALL_N_ACCESSOR candidates have no `_impl` to point at; their
    # classes are left out of the table and reach the fallback.
    candidates = candidates.reject { |t| t.kind == :ivar_accessor && t.irep.nil? }
    return nil if candidates.size <= POLY_SMALL_N_MAX

    table = poly_table(name, n, candidates)
    return nil if table[:entries].empty?

    diag = poly_diagnostic(name, n, 'table', candidates)
    fn_type = "mrb_value (*)(#{(['mrb_state*'] + Array.new(n + 1, 'mrb_value')).join(', ')})"
    note = "  // POLY_TABLE :#{name} -> #{table[:symbol]} (#{candidates.size} known real definitions, " \
           "#{table[:entries].size} classes), runtime-class lookup then direct C++ call, mrb_funcall fallback " \
           "for any other class\n"
    fallback = guarded_fallback_line(d, recv, name, argv, table[:entries].map(&:first), closed_world_site)
    "#{diag}#{note}  if (bc2cpp_poly_fn bc2cpp_pfn = bc2cpp_poly_lookup(M, mrb_obj_class(M, #{recv}), " \
      "#{table[:symbol]})) {\n" \
      "    r#{d} = reinterpret_cast<#{fn_type}>(bc2cpp_pfn)(M, #{([recv] + argv).join(', ')});\n" \
      "  } else {\n" \
      "    #{fallback}" \
      "  }\n"
  end

  # One table per distinct entry list, since the candidates can differ
  # between sites of one name. An INHERITED_GUARD subclass gets its own row.
  # Built outside the enclosing method's state, as index_helper_code is.
  def poly_table(name, n, candidates)
    @poly_tables ||= {}
    with_fresh_method_state do
      inherited = poly_inherited(name, candidates)
      entries = candidates.flat_map do |t|
        impl = cpp_name(t.owner, t.name) + '_impl'
        ([t.owner] + inherited[t.owner]).map { |owner| [owner, impl] }
      end
      # POLY_TABLE_NO_CLASS_ROW: bc2cpp_poly_lookup rejects a Class/Module
      # receiver before scanning, so neither may be a row (the fallback
      # reaches such a def instead).
      entries = entries.reject { |owner, _| %w[Class Module].include?(owner) }
      @poly_tables[[name, n, entries]] ||= { name: name, entries: entries,
                                             symbol: "bc2cpp_poly_table_#{@poly_tables.size}" }
    end
  end

  # OWNER_CLASS_CACHE slots and memo space for the tables the final `codes`
  # use, taken only now so a dropped table takes none and no other slot is
  # renumbered. Must run before emit_owner_class_cache.
  def reserve_poly_table_slots(codes)
    @poly_tables_emitted = poly_tables_used(codes)
    @poly_tables_emitted.each_with_index do |t, i|
      t[:getters] = t[:entries].map { |owner, _| owner_class_fn_name(owner) }
      t[:slots] = t[:entries].map { |owner, _| @owner_class_cache.fetch(owner)[:index] }
      t[:memo] = i * POLY_TABLE_MEMO
    end
  end

  # POLY_TABLE_MEMO: remembers recent lookups, misses included, per table. A
  # hit's key is an owner class, trusted exactly as its OWNER_CLASS_CACHE slot
  # is; a stale miss (a freed class's address reused) only sends that class
  # to the fallback, which is always correct. Cleared with that cache, since
  # a later VM can reuse the addresses. Declared inside emit_owner_class_cache
  # for that reason; '' without a table.
  def poly_table_memo_decl
    return '' if @poly_tables_emitted.nil? || @poly_tables_emitted.empty?

    <<~CPP
      // POLY_TABLE_MEMO -- see codegen_ivar_poly.rb's poly_table_memo_decl.
      typedef void (*bc2cpp_poly_fn)(void);
      struct bc2cpp_poly_memo {
        struct RClass* c;
        bc2cpp_poly_fn fn;
      };
      static bc2cpp_poly_memo bc2cpp_poly_memos[#{@poly_tables_emitted.size * POLY_TABLE_MEMO}];
    CPP
  end

  # The tables `codes` reference, with the shared lookup ahead of them; ''
  # when none. Printed after OWNER_CLASS_CACHE and the `_impl` declarations.
  def emit_poly_tables(codes)
    used = poly_tables_used(codes)
    return '' if used.empty?

    out = +<<~CPP
      // POLY_TABLE -- see codegen_ivar_poly.rb's compile_poly_table.
      struct bc2cpp_poly_entry {
        struct RClass* (*owner)(mrb_state*);
        bc2cpp_poly_fn fn;
        int slot;
      };
      struct bc2cpp_poly_table {
        const bc2cpp_poly_entry* rows;
        int n;
        bc2cpp_poly_memo* memo;
      };
      // A row compares against its resolved OWNER_CLASS_CACHE slot and runs
      // the getter only while that slot is empty. Out of line: one copy per
      // file is the point of the table.
      [[gnu::noinline]] static bc2cpp_poly_fn bc2cpp_poly_lookup(mrb_state* M, struct RClass* c, const bc2cpp_poly_table& t) {
        // `Graphics.update`: a class or module receiver is never a row
        // (POLY_TABLE_NO_CLASS_ROW), so skip the scan.
        if (c == M->class_class || c == M->module_class) return nullptr;
        if (bc2cpp_owner_class_state != M) {
          bc2cpp_reset_owner_classes();
          bc2cpp_owner_class_state = M;
        }
        uintptr_t h = reinterpret_cast<uintptr_t>(c);
        bc2cpp_poly_memo& m = t.memo[((h >> 4) ^ (h >> 10)) & #{POLY_TABLE_MEMO - 1}];
        if (m.c == c) return m.fn;
        bc2cpp_poly_fn fn = nullptr;
        for (int i = 0; i < t.n; ++i) {
          struct RClass* k = bc2cpp_owner_class_slots[t.rows[i].slot];
          if (k == c || (!k && t.rows[i].owner(M) == c)) {
            fn = t.rows[i].fn;
            break;
          }
        }
        m.c = c;
        m.fn = fn;
        return fn;
      }
    CPP
    used.each do |table|
      rows = "#{table[:symbol]}_rows"
      out << "// POLY_TABLE :#{table[:name]}\n"
      out << "static const bc2cpp_poly_entry #{rows}[] = {\n"
      table[:entries].zip(table.fetch(:getters), table.fetch(:slots)).each do |(owner, impl), getter, slot|
        out << "  {#{getter}, reinterpret_cast<bc2cpp_poly_fn>(#{impl}), #{slot}},  // #{owner}\n"
      end
      out << "};\n"
      out << "static const bc2cpp_poly_table #{table[:symbol]} = {#{rows}, #{table[:entries].size}, " \
             "bc2cpp_poly_memos + #{table.fetch(:memo)}};\n"
    end
    out << "\n"
  end

  # Tables built for a method that was then dropped are not emitted.
  def poly_tables_used(codes)
    texts = codes.map { |c| c.is_a?(Hash) ? c[:code] : c }
    (@poly_tables || {}).values.select { |t| texts.any? { |text| text.include?("#{t[:symbol]})) {") } }
  end

  # Sites per table name, for the stderr summary.
  def poly_table_site_counts(codes)
    texts = codes.map { |c| c.is_a?(Hash) ? c[:code] : c }
    poly_tables_used(codes).to_h do |t|
      ["#{t[:name]} (#{t[:symbol]}, #{t[:entries].size} classes)", texts.sum { |text| text.scan("#{t[:symbol]})) {").size }]
    end
  end

  # Bounded like POLY_SMALL_N_MAX; few Struct owners share a member name.
  STRUCT_INDEX_MAX = 8

  # STRUCT_INDEX_CACHE: `event[:page]` on an unknown receiver used to
  # mrb_funcall "[]", and Struct's native [] (mrb_struct_aref, mruby-struct
  # struct.c) scans __members__ each call. For a known Struct owner
  # (STRUCT_MEMBERS_ANALYSIS) and a literal Symbol key the index is a constant,
  # so read RARRAY_PTR directly behind an exact-class guard per owner,
  # bounds-checked like struct_aref_sym (`i < plen ? ptr[i] : nil`).
  # Reached only from GETIDX's INDEX_CHAIN tail; other keys keep the existing
  # chain and fallback.
  def compile_struct_literal_index_read(irep, idx, s, d)
    return nil unless CodeGen.struct_members && !CodeGen.struct_members.empty?

    literal = trace_eqq_literal_receiver(irep, idx, s)
    return nil unless literal && literal[:type] == :symbol

    candidates = CodeGen.struct_members.filter_map do |owner, members|
      i = members.index(literal[:name])
      [owner, i] if i
    end
    return nil if candidates.empty? || candidates.size > STRUCT_INDEX_MAX

    candidates.map do |owner, i|
      "else if (mrb_type(r#{d}) == MRB_TT_STRUCT && " \
        "mrb_obj_ptr(r#{d})->c == #{owner_class_ptr_expr(owner)}) {\n" \
        "    r#{d} = (#{i} < RARRAY_LEN(r#{d})) ? RARRAY_PTR(r#{d})[#{i}] : mrb_nil_value();\n" \
        "  } "
    end.join
  end

  # OUTLINED_INDEX_OPS (ADR 0216): the generic part of an untyped GETIDX/
  # GETIDX0/SETIDX (exact-class Array/Hash/String fast paths, and for GETIDX
  # INDEX_CHAIN's POLY_SMALL_N `#[]` chain) does not depend on the site, so it
  # is one static helper per file. STRUCT_INDEX_CACHE's literal-Symbol branches
  # stay inline ahead of the call (a Struct never matches the Array/Hash/String
  # arms, so the order is unobservable), as do the TYPED/static-receiver paths.
  INDEX_HELPERS = {
    'getidx' => 'mrb_value recv, mrb_value key',
    'getidx0' => 'mrb_value recv',
    'setidx' => 'mrb_value recv, mrb_value idx, mrb_value val'
  }.freeze

  # `dst = bc2cpp_<kind>(M, args...);`, building the helper on first use.
  def outlined_index_call(kind, dst, *args)
    index_helper_code(kind)
    "#{dst} = bc2cpp_#{kind}(M, #{args.join(', ')});\n"
  end

  # GETIDX's generic tail, after any STRUCT_INDEX_CACHE branches. nil under
  # RUNTIME_DEF_DEVIRT_GUARD for `[]`: that chain must skip POLY_SMALL_N and
  # the shared helper does not, so the caller keeps the inline form.
  def outlined_getidx_code(d, s, struct_read)
    return nil if devirt_blocked_name?('[]')

    call = outlined_index_call('getidx', "r#{d}", "r#{d}", "r#{s}")
    return call if struct_read.nil? || struct_read.empty?

    "#{struct_read.delete_prefix('else ')}else {\n  #{call}}\n"
  end

  # Built once per run under with_fresh_method_state, so the enclosing method's
  # RUNTIME_DEF_DEVIRT_GUARD cannot leak into the shared chain; building during
  # compilation allocates OWNER_CLASS_CACHE slots before that table is printed.
  def index_helper_code(kind)
    @index_helper_code ||= {}
    @index_helper_code[kind] ||= with_fresh_method_state { build_index_helper(kind) }
  end

  def build_index_helper(kind)
    body = case kind
           when 'getidx'
             # INDEX_CHAIN's tail, with the result in r0 (the name
             # compile_poly_small_n spells as `r<d>`).
             tail = compile_poly_dispatch('[]', 0, 'recv', ['key'], 1) ||
                    "  r0 = mrb_funcall(M, recv, \"[]\", 1, key);\n"
             <<~CPP.chomp + "\n#{tail}  return r0;\n"
               if (mrb_array_p(recv) && mrb_obj_ptr(recv)->c == M->array_class && mrb_integer_p(key)) {
                 return bc2cpp_ary_entry(M, recv, mrb_integer(key));
               } else if (mrb_hash_p(recv) && mrb_obj_ptr(recv)->c == M->hash_class) {
                 return mrb_hash_get(M, recv, key);
               } else if (mrb_string_p(recv) && mrb_obj_ptr(recv)->c == M->string_class &&
                          (mrb_integer_p(key) || mrb_string_p(key) || mrb_range_p(key))) {
                 return mrb_str_aref(M, recv, key, mrb_undef_value());
               }
               mrb_value r0 = mrb_nil_value();
             CPP
           when 'getidx0'
             <<~CPP
               if (mrb_array_p(recv) && mrb_obj_ptr(recv)->c == M->array_class) {
                 return bc2cpp_ary_entry(M, recv, 0);
               } else if (mrb_hash_p(recv) && mrb_obj_ptr(recv)->c == M->hash_class) {
                 return mrb_hash_get(M, recv, mrb_fixnum_value(0));
               }
               return mrb_funcall(M, recv, "[]", 1, mrb_fixnum_value(0));
             CPP
           when 'setidx'
             # The fast paths leave the assigned value in the register, the
             # fallback whatever `[]=` returned (vm.c's OP_SETIDX).
             <<~CPP
               if (mrb_array_p(recv) && mrb_obj_ptr(recv)->c == M->array_class && mrb_integer_p(idx)) {
                 mrb_ary_set(M, recv, mrb_integer(idx), val);
                 return val;
               } else if (mrb_hash_p(recv) && mrb_obj_ptr(recv)->c == M->hash_class) {
                 mrb_hash_set(M, recv, idx, val);
                 return val;
               }
               return mrb_funcall(M, recv, "[]=", 2, idx, val);
             CPP
           end
    "// OUTLINED_INDEX_OPS -- #{kind.upcase}'s generic chain, see bc2cpp.rb's INDEX_HELPERS comment.\n" \
      "static mrb_value bc2cpp_#{kind}(mrb_state* M, #{INDEX_HELPERS.fetch(kind)}) {\n" \
      "#{body.gsub(/^(?=.)/, '  ')}}\n\n"
  end

  # The helpers `codes` (generated C++ texts, or compiled entries' hashes)
  # call, in INDEX_HELPERS order. A helper built for a method that was then
  # dropped (a probe, or an unsupported method) is not emitted.
  def index_helpers_used(codes)
    texts = codes.map { |c| c.is_a?(Hash) ? c[:code] : c }
    INDEX_HELPERS.keys.select do |kind|
      @index_helper_code&.key?(kind) && texts.any? { |t| t.include?("bc2cpp_#{kind}(M,") }
    end
  end

  # File-scope definitions of the helpers `codes` call; '' when none.
  def emit_index_helpers(codes)
    index_helpers_used(codes).map { |kind| @index_helper_code.fetch(kind) }.join
  end

  # How many sites call each helper, for the stderr summary.
  def index_helper_site_counts(codes)
    texts = codes.map { |c| c.is_a?(Hash) ? c[:code] : c }
    INDEX_HELPERS.keys.to_h { |kind| [kind, texts.sum { |t| t.scan(/= bc2cpp_#{kind}\(M,/).size }] }
  end
end
