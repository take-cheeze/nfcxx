# frozen_string_literal: true

require_relative 'native_direct'

# NATIVE_EXACT_DIRECT (docs/adr/0281): a send whose receiver is proven to be
# exactly one RGSS class instance or one class/module object calls the native's
# frame-independent entry point (NativeDirect::ENTRIES, ADR 0263) with no
# guard on the receiver and no dispatch fallback. ADR 0253's arms guard by
# class and keep the send as their else; here the receiver fact is a proof
# (a stable constant, or `self` of an exact class), so the send disappears.
#
# The lookup a proven receiver performs reaches the native registration when:
#   - the name is spelled only by the RGSS sources, registered once on the
#     owner, and no closed-world definer, alias, undef, visibility change or
#     runtime installer names it (ClosedWorld#native_exact_direct_name_safe?);
#   - the registry holds no Ruby definition of it on the owner, and nothing is
#     prepended or mixed in unresolved on the owner (or, for a singleton, on
#     the class or module itself);
#   - for a class object, extending it or reopening `class << self` cannot
#     precede the singleton's own table: an extend is a global refusal
#     (ClosedWorld#scan_send) and a reopening is a registry definition.
module NativeExactDirect
  RGSS_SRC = '/mruby-rgss/src/'

  # The code for `recv.name(*argv)` where `recv` is exactly `owner` (an RGSS
  # class name, or "X.singleton" for the class or module object X), or nil.
  # `int_proven` (`->(position)`) says an :int argument is provably a Fixnum, which drops its
  # mrb_integer_p test and with it the by-name else (ADR 0296).
  def native_exact_direct_code(name, d, recv, argv, owner, int_proven: nil)
    return nil if @call_block_expr

    entry = owner && NativeDirect::ENTRIES.dig(name, owner)
    return nil unless entry && entry.kinds.size == argv.size && native_exact_owner_safe?(name, owner)

    @native_construct_used << owner
    if ENV['BC2CPP_NATIVE_INT_ARGS'] && @native_int_site && entry.kinds.include?(:int)
      native_int_arg_probe("exact:#{owner}##{name}", *@native_int_site[0, 2], argv, @native_int_site[2], @native_int_site[3])
    end
    guards = entry.kinds.each_index.select { |i| entry.kinds[i] == :int && !int_proven&.call(i) }
                 .map { |i| "mrb_integer_p(#{argv[i]})" }
    args = entry.kinds.each_index.map do |i|
      case entry.kinds[i]
      when :int then "mrb_integer(#{argv[i]})"
      when :bool then "mrb_test(#{argv[i]})"
      else argv[i]
      end
    end
    call = "r#{d} = rgss::#{entry.function}(#{(['M', recv] + args).join(', ')});"
    note = "  // NATIVE_EXACT_DIRECT :#{name} -> #{owner} (exact receiver, unique RGSS native registration), " \
           "direct entry point #{entry.function} without dispatch.\n"
    return "#{note}  #{call}\n" if guards.empty?

    # An argument mrb_get_args would coerce (a Float for "i") keeps the send.
    "#{note}  if (#{guards.join(' && ')}) {\n    #{call}\n  } else {\n    #{dynamic_dispatch_line(d, recv, name, argv).chomp}\n  }\n"
  end

  # Owner of the receiver `self` in the enclosing method when it is proven to be
  # exactly that class's instance ("Klass") or that class or module object
  # ("Klass.singleton"), else nil. lexical_self_owner and
  # lexical_self_singleton_owner prove the same facts for Ruby-defined names,
  # but the singleton one also demands inherited_lookup_safe?(name), which no
  # native name can satisfy; a native registration is found on the owner's own
  # table before any inherited lookup happens.
  def native_exact_self_owner(owner_def)
    return nil unless owner_def && self_class(owner_def)

    owner = owner_def.owner
    return lexical_self_owner(owner_def) unless owner.is_a?(String) && owner.end_with?('.singleton')

    base = owner.delete_suffix('.singleton')
    # Top-level `def self.x` is main's singleton, also spelled "Object.singleton".
    return nil if base == 'Object'
    return nil unless exact_receiver_class?(base) || @closed_world&.module_object_self?(base)

    owner
  end

  def native_exact_owner_safe?(name, owner)
    return false unless @closed_world && @native_name_sources && !symbol_installed_names.nil?
    return false if symbol_installed_names.include?(name) || devirt_blocked_name?(name)
    return false unless @closed_world.native_exact_direct_name_safe?(name, RGSS_SRC)

    paths = @native_name_sources.fetch(name, []).select { |path| path.include?(RGSS_SRC) }
    return false unless NativeDirect.registration_count(name, owner, paths) == 1

    defs = @registry[name] || []
    base = owner.delete_suffix('.singleton')
    defs.any? { |definition| definition.owner == '<native>' && definition.irep.nil? } &&
      defs.none? { |definition| definition.owner == owner } &&
      [owner, base].all? { |o| Array(@prepended_modules[o]).empty? && !@unknown_mixins.include?(o) }
  end
end

CodeGen.include(NativeExactDirect)
