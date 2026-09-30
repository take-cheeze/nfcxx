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

    exact = native_core_exact_entry(entries, recv, name, argv)
    return exact_code_line(d, recv, argv, exact) if exact

    site = exact_core_site_for(recv, name)
    branches = entries.map do |entry|
      "if (#{native_core_guard(entry, recv, argv, site)}) {\n" \
        "    r#{d} = #{entry.call(recv, argv)};\n" \
        '  } else '
    end.join
    proven = site && entries.any? { |entry| entry.owner == site[:klass] }
    what = proven ? "proven #{site[:klass]} receiver, argument guarded," : "exact #{entries.map(&:owner).uniq.join('/')} receiver"
    "// NATIVE_CORE_DIRECT :#{name} -- #{what} calls the verified core body\n" \
      "  #{branches}{\n" \
      "    #{tail.chomp}\n" \
      "  }\n"
  end

  # EXACT_CORE_RECEIVER (ADR 0280): the entry whose owner the receiver provably is, when its
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
    when :integer then false
    end
  end

  # The class test is a fact at an exact site; the argument guard stays unless proven.
  def native_core_guard(entry, recv, argv, site)
    return entry.guard(recv, argv) unless site && entry.owner == site[:klass]

    arg_guard = NativeCoreDirect::ARG_GUARDS.fetch(entry.arg)
    arg_guard ? format(arg_guard, a: argv.first) : 'true'
  end

  def exact_code_line(d, recv, argv, entry)
    "// NATIVE_CORE_EXACT :#{entry.name} -- receiver is a literal or rest #{entry.owner} (unguarded proof), " \
      "verified core body, no dispatch\n" \
      "  r#{d} = #{entry.call(recv, argv)};\n"
  end
end

CodeGen.prepend(NativeCoreDirectFallback)
