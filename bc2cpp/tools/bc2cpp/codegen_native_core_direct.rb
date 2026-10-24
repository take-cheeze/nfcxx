# frozen_string_literal: true

require_relative 'native_core_direct'
require_relative 'core_hierarchy_sigs'

# NATIVE_CORE_DIRECT: exact builtin-class arms that call a core
# native's frame-independent body (NativeCoreDirect::ENTRIES) in front of a
# dynamic send.
#
# Prepended to CodeGen, so it wraps native_direct_dynamic_line (the send of a
# site with no guard chain) and guarded_fallback_line (a chain's else) without
# editing them. Both keep their result as the arm's else, so every receiver
# the arm does not name dispatches exactly as before.
module NativeCoreDirectFallback
  def native_direct_dynamic_line(d, recv, name, argv)
    native_core_direct_wrap(d, recv, name, argv, super)
  end

  def guarded_fallback_line(d, recv, name, argv, listed, site)
    native_core_direct_wrap(d, recv, name, argv, super)
  end

  def registered_expression_fallback(d, recv, name, argv, dispatch)
    native_core_direct_wrap(d, recv, name, argv, super)
  end

  # NATIVE_CORE_DIRECT_REST: the audited Array native for a receiver that is the
  # method's or block's own `*rest` parameter. ENTER (and every compiled entry, see
  # rest_only_callee?) builds that Array fresh, so it is an exact Array with no singleton
  # and the arm needs neither a guard nor the send. An entry whose argument needs a guard
  # keeps the ordinary arm.
  def rest_param_native_code(irep, idx, reg, name, d, recv, argv)
    return nil unless irep && idx && reg && !devirt_blocked_name?(name)
    # The rest Array is fresh, but a singleton maker in the world could still give it a singleton
    # class before the call.
    return nil unless block_core_world&.exact_instances_singleton_free?

    entry = rest_param_native_entry(name, argv.size)
    return nil unless entry && rest_param_receiver?(irep, idx, reg.to_s)

    "  // NATIVE_CORE_DIRECT_REST :#{name} -- receiver is the *rest parameter, a fresh exact Array\n" \
      "  r#{d} = #{entry.call(recv, argv)};\n"
  end

  def rest_param_native_entry(name, arity)
    world = block_core_world
    return nil unless world && @native_name_sources

    @rest_param_entries ||= {}
    @rest_param_entries.fetch([name, arity]) do
      @rest_param_entries[[name, arity]] =
        NativeCoreDirect::ENTRIES.find do |entry|
          entry.owner == 'Array' && entry.arg == :none && entry.name == name && entry.arity == arity &&
            native_core_entry_safe?(entry, world)
        end
    end
  end

  # Every definition of the register at `idx` is the entry value of the rest slot of an
  # irep that builds it (rest and mandatory parameters only). A rewrite of the slot, in the
  # irep or a nested block, is another definition (or refuses the query), so it is not this case.
  def rest_param_receiver?(irep, idx, reg)
    return false unless idx.between?(0, BytecodeIR.for(irep).size - 1)

    enter = irep.enter
    return false unless enter && (@owner_of.key?(irep.label) || rest_only_block?(irep))

    mand, opt, rest, post, kw, kwrest = enter.enter_fields
    return false unless rest == 1 && [opt, post, kw, kwrest].all?(&:zero?)

    slot = (1 + mand).to_s
    defs = BytecodeIR.reaching_definitions(irep, idx, reg)
    defs&.size == 1 && defs.first.entry? && defs.first.reg == slot
  end

  # Verified entries for `name` at this arity whose owner nothing in the closed
  # world can shadow. Closed world only: outside Ruby is otherwise unknown. A core body
  # compiles with the closed world withheld, but these are program-wide facts, so it
  # asks the same world (block_core_world), as NATIVE_CORE_DIRECT_REST does.
  def native_core_entries(name, arity)
    world = block_core_world
    return [] unless world && @native_name_sources

    @native_core_entries ||= {}
    @native_core_entries.fetch([name, arity]) do
      @native_core_entries[[name, arity]] =
        NativeCoreDirect::ENTRIES.select do |entry|
          entry.name == name && entry.arity == arity && native_core_entry_safe?(entry, world)
        end
    end
  end

  # A project definition on the class, a prepend, an unattributed mixin, a
  # dynamic installer or an outside Ruby definer all make the native body one
  # of several candidates; the exact-class guard cannot see a singleton or
  # subclass method, so those receivers fall to the send.
  def native_core_entry_safe?(entry, world = @closed_world)
    paths = @native_name_sources.values.flatten.uniq
    return false unless NativeCoreDirect.verified?(paths, entry)
    return false if symbol_installed_names.nil? || symbol_installed_names.include?(entry.name)
    return false if (@registry[entry.name] || []).any? { |definition| definition.owner == entry.owner }

    Array(@prepended_modules[entry.owner]).empty? && !@unknown_mixins.include?(entry.owner) &&
      world.core_native_arm_safe?(entry.name, entry.owner)
  end

  # KERNEL_DIRECT: the audited Kernel/BasicObject native for an implicit-self
  # send, called with no dispatch. Nothing here can name a receiver class, so the proof
  # is by name: the native is the only definition anywhere in the build, and no
  # receiver can lack Kernel (ClosedWorld#kernel_native_dispatch_safe?). Core bodies
  # get it too: these are program-wide facts, not the static-binding proofs a core
  # body is denied (block_core_world).
  def kernel_direct_code(name, d, recv, argv, self_implicit = true)
    entry = !devirt_blocked_name?(name) && kernel_direct_entry(name, argv.size, self_implicit)
    return nil unless entry

    note = "  // KERNEL_DIRECT :#{name} -- #{self_implicit ? 'implicit-self' : 'explicit-receiver'} #{entry.owner}##{name} is the only definition; " \
           "the audited native body runs with no dispatch\n"
    call = "r#{d} = #{entry.call(recv, argv)};\n"
    guards = []
    # An explicit receiver may be a bare BasicObject (basic_object_subclass_free? rules out subclasses only), which
    # lacks Kernel.
    if !self_implicit && entry.owner != 'BasicObject' && !kernel_receiver_sealed?
      guards << "mrb_obj_is_kind_of(M, #{recv}, M->kernel_module)"
    end
    arg_guard = NativeCoreDirect::ARG_GUARDS.fetch(entry.arg)
    guards << format(arg_guard, a: argv.first, b: argv[1]) if arg_guard
    return "#{note}  #{call}" if guards.empty?

    # A receiver or argument the guards reject keeps the send, so the method's own error is unchanged.
    "#{note}  if (#{guards.join(' && ')}) {\n    #{call}  } else {\n    #{dynamic_dispatch_line(d, recv, name, argv)}  }\n"
  end

  # BASIC_OBJECT_SEALED: the Kernel guard of an explicit-receiver row is dead when no bare BasicObject can exist
  # (ClosedWorld#basic_object_instance_free?) and no native can make one: a native source may name the class only to
  # define it (mruby's class.c) or to register methods on it.
  NATIVE_BASIC_OBJECT_USE = /MRB_MT_INIT_ROM|mrb_define_(?:class|const|method|module_function)\w*\(/

  def kernel_receiver_sealed?
    return @kernel_receiver_sealed if defined?(@kernel_receiver_sealed)

    @kernel_receiver_sealed = !!(@closed_world&.basic_object_instance_free? && @native_name_sources &&
                                 native_basic_object_registration_only?)
  end

  def native_basic_object_registration_only?
    @native_name_sources.values.flatten.uniq.all? do |path|
      next true if path.end_with?('/src/class.c')

      File.foreach(path, encoding: 'BINARY').all? do |line|
        !line.include?('BasicObject') || line.match?(NATIVE_BASIC_OBJECT_USE) || line.lstrip.start_with?('//', '/*', '*')
      end
    end
  end

  # An explicit receiver needs a row marked explicit_receiver, and a public one: a private native is a NoMethodError there.
  def kernel_direct_entry(name, arity, self_implicit = true)
    return nil unless block_core_world && @native_name_sources

    @kernel_direct_entries ||= {}
    @kernel_direct_entries.fetch([name, arity, self_implicit]) do
      @kernel_direct_entries[[name, arity, self_implicit]] =
        (NativeCoreDirect::KERNEL_ENTRIES + NativeCoreDirect::KERNEL_ANY_RECEIVER_ENTRIES).find do |entry|
          next false unless entry.name == name && entry.arity == arity
          next false unless self_implicit || (entry.explicit_receiver && !entry.aspec.include?('MRB_MT_PRIVATE'))

          kernel_direct_entry_safe?(entry)
        end
    end
  end

  def kernel_direct_entry_safe?(entry)
    paths = @native_name_sources.values.flatten.uniq
    return false unless NativeCoreDirect.verified?(paths, entry)
    return false if symbol_installed_names.nil? || symbol_installed_names.include?(entry.name)
    return false unless (@registry[entry.name] || []).all? { |definition| definition.owner == '<native>' }

    block_core_world.kernel_native_dispatch_safe?(entry.name)
  end

  def native_core_direct_wrap(d, recv, name, argv, tail)
    site = exact_core_site_for(recv, name)
    entries = native_core_entries(name, argv.size)
    # An exact-literal receiver is never another builtin, so their arms are dead code.
    entries = entries.select { |entry| entry.owner == site[:klass] } if site && CodeGen::EXACT_LITERAL_CLASS.value?(site[:klass])
    if entries.empty? || tail.include?('bc2cpp_nomethod')
      # NATIVE_OWNER_MAP: a chain with no audited native entry still gets the proven candidates' arms.
      arms = site || tail.include?('bc2cpp_nomethod') ? '' : native_owner_map_arms(d, recv, name, argv)
      return arms.empty? ? tail : "#{arms}{\n      #{tail.chomp}\n    }\n"
    end

    exact = native_core_exact_entry(entries, recv, name, argv)
    return exact_code_line(d, recv, argv, exact) if exact

    branches = entries.map do |entry|
      "if (#{native_core_guard(entry, recv, argv, site)}) {\n" \
        "    r#{d} = #{entry.call(recv, argv)};\n" \
        '  } else '
    end.join
    proven = site && entries.any? { |entry| entry.owner == site[:klass] }
    what = proven ? "proven #{site[:klass]} receiver, argument guarded," : "exact #{entries.map(&:owner).uniq.join('/')} receiver"
    # NATIVE_OWNER_MAP: proven Ruby candidates' exact-class arms come ahead of the by-name else.
    arms = site ? '' : native_owner_map_arms(d, recv, name, argv)
    else_body = arms.empty? ? tail.chomp : "#{arms}{\n      #{tail.chomp}\n    }"
    "// NATIVE_CORE_DIRECT :#{name} -- #{what} calls the verified core body\n" \
      "  #{branches}{\n" \
      "    #{else_body}\n" \
      "  }\n"
  end

  # FLOW_NATIVE_CORE_EXACT: FLOW_CORE_DIRECT's audited native, for a name the compiled core does not define (a C body,
  # such as Array#delete). The guard chain it replaces lists only project classes, none of which an exact core receiver
  # can be, so its arms are dead and its else is the by-name send.
  def flow_native_core_exact_line(d, recv, name, argv)
    return nil if devirt_blocked_name?(name)

    exact = native_core_exact_entry(native_core_entries(name, argv.size), recv, name, argv)
    return exact_code_line(d, recv, argv, exact) if exact

    site = exact_core_site_for(recv, name)
    inherited = site && inherited_core_entry(site[:klass], name, argv.size)
    inherited && inherited_code_line(d, recv, name, argv, inherited, site[:klass])
  end

  # INHERITED_CORE_DIRECT: the audited Kernel/BasicObject native an exact `klass` receiver reaches for `name`, or nil.
  # Lookup walks the class, its mixins, then its superclasses (CoreHierarchySigs.ancestors), so the native answers only
  # when nothing earlier in that walk defines the name: no native registration, no compiled or outside Ruby definition,
  # no prepend or project mixin that defines it, and no runtime installer of the name.
  def inherited_core_entry(klass, name, arity)
    @inherited_core_entries ||= {}
    key = [klass, name, arity]
    return @inherited_core_entries[key] if @inherited_core_entries.key?(key)

    @inherited_core_entries[key] = inherited_core_entry_uncached(klass, name, arity)
  end

  def inherited_core_entry_uncached(klass, name, arity)
    world = block_core_world
    return nil unless world && @native_name_sources && !devirt_blocked_name?(name)

    entry = NativeCoreDirect::INHERITED_ENTRIES.find { |e| e.name == name && e.arity == arity }
    return nil unless entry && CoreHierarchySigs.declared_class?(klass)

    paths = @native_name_sources.values.flatten.uniq
    return nil unless NativeCoreDirect.verified?(paths, entry)

    installed = symbol_installed_names
    return nil if installed.nil? || installed.include?(name)

    chain = CoreHierarchySigs.ancestors(klass)
    at = chain.index(entry.owner)
    return nil unless at

    lookup = chain[0..at]
    registrations, opaque = NativeExpressionDevirt.class_registrations(paths)
    # An unattributed registration of the name could be on any class in the walk.
    return nil unless opaque.fetch(name, []).empty?

    natives = registrations.fetch(name, []).map { |g| g[:owner] && g[:owner][:class_name] }
    return nil if natives.any? { |owner| owner.nil? || (lookup.include?(owner) && owner != entry.owner) }

    defs = @registry[name] || []
    mixins = lookup.flat_map { |a| Array(@included_modules[a]) + Array(@prepended_modules[a]) } - chain
    return nil if defs.any? { |definition| lookup.include?(definition.owner) || mixins.include?(definition.owner) }
    return nil if mixins.any? { |mod| !Array(@included_modules[mod]).empty? || !Array(@prepended_modules[mod]).empty? }
    return nil if lookup.any? { |a| !Array(@prepended_modules[a]).empty? || @unknown_mixins.include?(a) }
    return nil unless lookup.all? { |a| world.core_native_arm_safe?(name, a) }

    entry
  end

  def inherited_code_line(d, recv, name, argv, entry, klass)
    note = "// INHERITED_CORE_DIRECT :#{name} -- exact #{klass} receiver reaches #{entry.owner}##{name} first in its " \
           "lookup; verified core body, no dispatch\n"
    arg_guard = NativeCoreDirect::ARG_GUARDS.fetch(entry.arg)
    return "#{note}  r#{d} = #{entry.call(recv, argv)};\n" unless arg_guard

    "#{note}  if (#{format(arg_guard, a: argv.first, b: argv[1])}) {\n" \
      "    r#{d} = #{entry.call(recv, argv)};\n" \
      "  } else {\n" \
      "    #{dynamic_dispatch_line(d, recv, name, argv).chomp}\n" \
      "  }\n"
  end

  # EXACT_CORE_RECEIVER: the entry whose owner the receiver provably is, when its
  # argument guard is proven too; the send is then dead code.
  def native_core_exact_entry(entries, recv, name, argv)
    site = exact_core_site_for(recv, name)
    return nil unless site

    entries.find do |entry|
      entry.owner == site[:klass] && native_core_arg_proven?(entry, argv, site)
    end
  end

  def native_core_arg_proven?(entry, argv, site)
    case entry.arg
    when :none then true
    when :nil_or_string then %w[NilClass String].include?(site[:arg_class].call(0))
    when :array then site[:arg_class].call(0) == 'Array'
    when :integer, :two_integers then false
    end
  end

  # The class test is a fact at an exact site; the argument guard stays unless proven.
  def native_core_guard(entry, recv, argv, site)
    return entry.guard(recv, argv) unless site && entry.owner == site[:klass]

    arg_guard = NativeCoreDirect::ARG_GUARDS.fetch(entry.arg)
    arg_guard ? format(arg_guard, a: argv.first, b: argv[1]) : 'true'
  end

  def exact_code_line(d, recv, argv, entry)
    "// NATIVE_CORE_EXACT :#{entry.name} -- receiver is a literal or rest #{entry.owner} (unguarded proof), " \
      "verified core body, no dispatch\n" \
      "  r#{d} = #{entry.call(recv, argv)};\n"
  end
end

CodeGen.prepend(NativeCoreDirectFallback)
