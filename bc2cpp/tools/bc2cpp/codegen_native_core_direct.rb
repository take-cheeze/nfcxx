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
  def native_core_entry_safe?(entry)
    paths = @native_name_sources.values.flatten.uniq
    return false unless NativeCoreDirect.verified?(paths, entry)
    return false if symbol_installed_names.nil? || symbol_installed_names.include?(entry.name)
    return false if (@registry[entry.name] || []).any? { |definition| definition.owner == entry.owner }

    Array(@prepended_modules[entry.owner]).empty? && !@unknown_mixins.include?(entry.owner) &&
      @closed_world.core_native_arm_safe?(entry.name, entry.owner)
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
