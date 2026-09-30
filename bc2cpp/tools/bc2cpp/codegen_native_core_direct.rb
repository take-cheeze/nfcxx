# frozen_string_literal: true

require_relative 'native_core_direct'

# NATIVE_CORE_DIRECT (docs/adr/0257): exact builtin-class arms that call a core
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

  # NATIVE_CORE_DIRECT_REST (ADR 0274): the audited Array native for a receiver that is the
  # method's or block's own `*rest` parameter. ENTER (and every compiled entry, see
  # rest_only_callee?) builds that Array fresh, so it is an exact Array with no singleton
  # and the arm needs neither a guard nor the send. An entry whose argument needs a guard
  # keeps the ordinary arm.
  def rest_param_native_code(irep, idx, reg, name, d, recv, argv)
    return nil unless irep && idx && reg && !devirt_blocked_name?(name)

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
    return false unless idx.between?(0, irep.instructions.length - 1)

    enter = irep.enter
    return false unless enter && (@owner_of.key?(irep.label) || rest_only_block?(irep))

    mand, opt, rest, post, kw, kwrest = enter.enter_fields
    return false unless rest == 1 && [opt, post, kw, kwrest].all?(&:zero?)

    slot = (1 + mand).to_s
    defs = BytecodeIR.reaching_definitions(irep, idx, reg)
    defs&.size == 1 && defs.first.entry? && defs.first.reg == slot
  end

  # Verified entries for `name` at this arity whose owner nothing in the closed
  # world can shadow. Closed world only: outside Ruby is otherwise unknown.
  def native_core_entries(name, arity)
    return [] unless @closed_world && @native_name_sources

    @native_core_entries ||= {}
    @native_core_entries.fetch([name, arity]) do
      @native_core_entries[[name, arity]] =
        NativeCoreDirect::ENTRIES.select do |entry|
          entry.name == name && entry.arity == arity && native_core_entry_safe?(entry)
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

  # KERNEL_DIRECT (ADR 0274): the audited Kernel/BasicObject native for an implicit-self
  # send, called with no dispatch. Nothing here can name a receiver class, so the proof
  # is by name: the native is the only definition anywhere in the build, and no
  # receiver can lack Kernel (ClosedWorld#kernel_native_dispatch_safe?). Core bodies
  # get it too: these are program-wide facts, not the static-binding proofs a core
  # body is denied (block_core_world).
  def kernel_direct_code(name, d, recv, argv)
    entry = !devirt_blocked_name?(name) && kernel_direct_entry(name, argv.size)
    return nil unless entry

    "  // KERNEL_DIRECT :#{name} -- implicit-self #{entry.owner}##{name} is the only definition; " \
      "the audited native body runs with no dispatch\n" \
      "  r#{d} = #{entry.call(recv, argv)};\n"
  end

  def kernel_direct_entry(name, arity)
    return nil unless block_core_world && @native_name_sources

    @kernel_direct_entries ||= {}
    @kernel_direct_entries.fetch([name, arity]) do
      @kernel_direct_entries[[name, arity]] =
        NativeCoreDirect::KERNEL_ENTRIES.find do |entry|
          entry.name == name && entry.arity == arity && kernel_direct_entry_safe?(entry)
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
    entries = native_core_entries(name, argv.size)
    return tail if entries.empty? || tail.include?('bc2cpp_nomethod')

    branches = entries.map do |entry|
      "if (#{entry.guard(recv, argv)}) {\n" \
        "    r#{d} = #{entry.call(recv, argv)};\n" \
        '  } else '
    end.join
    "// NATIVE_CORE_DIRECT :#{name} -- exact #{entries.map(&:owner).uniq.join('/')} receiver calls the verified core body\n" \
      "  #{branches}{\n" \
      "    #{tail.chomp}\n" \
      "  }\n"
  end
end

CodeGen.prepend(NativeCoreDirectFallback)
