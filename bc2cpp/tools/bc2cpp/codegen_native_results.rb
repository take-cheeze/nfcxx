# frozen_string_literal: true

require_relative 'native_result_facts'
require_relative 'native_class_results'
require_relative 'native_core_result_sigs'
require_relative 'core_blockless_iterator_sigs'
require_relative 'core_hierarchy_sigs'
require_relative 'numeric_flow'
require_relative 'codegen_return_classes'

# CodeGen: NATIVE_RESULT_FACTS (ADR 0302). A fact is used only for a receiver the exact-class flow
# proved, while lookup from that class provably reaches the registration (native_exact_owner_safe?).
class CodeGen
  NATIVE_RESULT_CORE_CLASS_BITS = RETURN_CORE_CLASS.map { |bit, klass| [klass, bit, bit.bit_length - 1].freeze }.freeze

  # Class bits only append; identity also separates copies restored by without_probe_side_effects.
  def native_result_class_bits
    bits = @numeric_class_bits
    return NATIVE_RESULT_CORE_CLASS_BITS unless bits

    cached = @native_result_class_bits
    return cached[2] if cached && cached[0].equal?(bits) && cached[1] == bits.size

    entries = (bits.map { |klass, bit| [klass, bit, bit.bit_length - 1].freeze } + NATIVE_RESULT_CORE_CLASS_BITS).freeze
    @native_result_class_bits = [bits, bits.size, entries]
    entries
  end

  # :fixnum, :float, a class name or nil for `name` sent to an exact `klass` receiver.
  def native_result_kind(name, klass)
    @native_result_kinds ||= {}
    key = [name, klass]
    @native_result_kinds[key] = compute_native_result_kind(name, klass) unless @native_result_kinds.key?(key)
    @native_result_kinds[key]
  end

  def compute_native_result_kind(name, klass)
    core_kind = native_core_declared_result(name, klass)
    if ENV['BC2CPP_NATIVE_CLASS_RESULTS'] != '0' && @closed_world&.exact_instances_singleton_free? && @native_name_sources && core_kind
      entry = NativeCoreDirect::ENTRIES.find { |candidate| candidate.owner == klass && candidate.name == name }
      return core_kind if entry && native_core_entry_safe?(entry)
    end
    kind = NativeResultFacts.kind(name, klass)
    return nil unless kind && @closed_world&.exact_instances_singleton_free?
    return nil unless native_exact_owner_safe?(name, klass)
    # A class result is `RGSS::Rect` as the constant names it today.
    return nil if kind.is_a?(String) && !@closed_world.native_class_constant_stable?(kind)

    kind
  end

  def native_core_declared_result(name, klass)
    return nil if ENV['BC2CPP_NATIVE_COLLECTION_RESULTS'] == '0' && %w[compact join].include?(name)

    NativeCoreResultSigs.kinds.dig(klass, name)
  end

  # BOOL (`!=`): mruby's BasicObject#!= is `!(self == other)`, and `!` answers true or false, so a `!=` send answers
  # one of the two boolean class bits whatever the receiver. Gated like the other core results: exact instances, and no
  # program definition or installer of `!=` or `!` (a program override of either would change the answer).
  def native_core_neq_class_result(insn, state)
    return nil unless insn.op == 'SEND' && insn.sym == '!=' && insn.plain_fixed_argc? && insn.argc == 1
    return nil unless @closed_world&.exact_instances_singleton_free?

    installed = symbol_installed_names
    return nil if installed.nil? || installed.include?('!=') || installed.include?('!')
    return nil unless %w[!= !].all? { |name| (@registry[name] || []).all? { |definition| definition.owner == '<native>' } }

    numeric_class_bit('TrueClass') | numeric_class_bit('FalseClass')
  end

  # SEND/SEND0 with no block: a core block iterator of Enumerable (core_blockless_iterators) returns an Enumerator. The
  # receiver is any exact core class that includes Enumerable (CoreHierarchySigs), and the argument count must be one the
  # blockless declaration accepts. mruby's Enumerable iterators return `to_enum` when no block is given (ADR 0524).
  # Gated: exact instances, no installed or program definition of the name, and the result is NumericFlow::ENUMERATOR,
  # which names no class.
  def native_core_blockless_enumerator_result(insn, state)
    return nil unless ENV['BC2CPP_NATIVE_CLASS_RESULTS'] != '0' && %w[SEND SEND0].include?(insn.op)
    return nil unless insn.op == 'SEND0' || insn.plain_fixed_argc?
    return nil unless @closed_world&.exact_instances_singleton_free?

    owner = RETURN_CORE_CLASS[state[insn.reg.to_i]]
    return nil unless owner && CoreHierarchySigs.hierarchy[1].fetch(owner, []).include?('Enumerable')
    return nil unless CoreBlocklessIteratorSigs.results.dig('Enumerable', insn.sym) == 'Enumerator'

    argc = insn.op == 'SEND0' ? 0 : insn.argc
    min, max = CoreBlocklessIteratorSigs.arity('Enumerable', insn.sym)
    return nil unless argc && argc >= min && (max.nil? || argc <= max)
    return nil if symbol_installed_names.nil? || symbol_installed_names.include?(insn.sym)
    return nil unless (@registry[insn.sym] || []).all? { |definition| definition.owner == '<native>' }

    NumericFlow::ENUMERATOR
  end

  # Only the exact-class oracle supplies this receiver: numeric masks alone
  # do not prove lookup reaches the built-in class's audited body.
  def native_core_class_result(insn, state)
    neq = native_core_neq_class_result(insn, state)
    return neq if neq

    enumerator = native_core_blockless_enumerator_result(insn, state)
    return enumerator if enumerator
    return nil unless ENV['BC2CPP_NATIVE_CLASS_RESULTS'] != '0' && %w[SEND SEND0].include?(insn.op)

    owner = RETURN_CORE_CLASS[state[insn.reg.to_i]]
    return nil unless owner && native_core_declared_result(insn.sym, owner)

    kind = native_result_kind(insn.sym, owner)
    kind && native_result_bits(kind, true)
  end

  # The core Struct alias copies its native inspect entry. Any unmodelled
  # replacement of that entry or another alias of to_s withdraws this bridge.
  def native_struct_string_alias_safe?
    return @native_struct_string_alias_safe if defined?(@native_struct_string_alias_safe)

    @native_struct_string_alias_safe = audit_native_struct_string_alias
  end

  def audit_native_struct_string_alias
    return false if ENV['BC2CPP_NATIVE_STRING_RESULTS'] == '0' || ENV['BC2CPP_NATIVE_CLASS_RESULTS'] == '0'
    return false unless @closed_world && @native_name_sources && @closed_world.native_class_constant_stable?('Struct')
    return false unless @closed_world.core_native_arm_safe?('inspect', 'Struct')
    return false if symbol_installed_names.nil? || symbol_installed_names.include?('inspect')
    return false if (@registry['inspect'] || []).any? { |definition| definition.owner == 'Struct' }
    return false unless Array(@prepended_modules['Struct']).empty? && !@unknown_mixins.include?('Struct')

    @ireps.each_value do |irep|
      aliasing = irep.instructions.any? { |insn| insn.op == 'ALIAS' || insn.sym == 'alias_method' }
      irep.instructions.each do |insn|
        return false if %w[UNDEF ALIAS].include?(insn.op) && insn.sym == 'inspect'
        next unless aliasing && insn.sym == 'to_s' && %w[ALIAS LOADSYM].include?(insn.op)

        return false unless insn.op == 'ALIAS' && insn.first_of(:name)&.value == 'inspect' &&
                            NativeClassResults.source_matches?(irep.file, NativeClassResults::STRUCT_ALIAS_PATH, NativeClassResults::STRUCT_ALIAS_SHA)
      end
    end
    paths = @closed_world.native_paths_spelling('inspect')
    registrations, opaque = NativeExpressionDevirt.class_registrations(paths)
    return false if opaque.fetch('inspect', []).any? { |owner| owner.nil? || owner == 'Struct' }

    entries = registrations.fetch('inspect', []).select { |entry| entry[:owner]&.fetch(:class_name, nil) == 'Struct' }
    entries.one? && entries.first[:function] == 'mrb_struct_to_s' &&
      NativeClassResults.source_matches?(entries.first[:path], '3rd/mruby/mrbgems/mruby-struct/src/struct.c')
  end

  # Every linked native definition must have an audited return kind; outside Ruby withdraws
  # the proof. Compiled Ruby definitions join separately (numeric_return_def_usable?).
  def native_result_name_kinds(name)
    @native_result_name_kinds ||= {}
    @native_result_name_kinds[name] = compute_native_result_name_kinds(name) unless @native_result_name_kinds.key?(name)
    @native_result_name_kinds[name]
  end

  def compute_native_result_name_kinds(name)
    return nil unless @closed_world&.exact_instances_singleton_free? && @native_name_sources
    return nil if name == 'to_s' && !native_struct_string_alias_safe?

    paths = @closed_world.native_paths_spelling(name)
    audited = NativeClassResults.kinds(name, paths, string_subclass_free: %w[to_s join].include?(name) && @closed_world.native_subclass_free?(['String']))
    ruby_aliases = []
    if name == 'to_s'
      ruby_aliases = @closed_world.outside_ruby_paths_defining(name).select do |path|
        NativeClassResults.source_matches?(path, NativeClassResults::STRUCT_ALIAS_PATH, NativeClassResults::STRUCT_ALIAS_SHA)
      end
    end
    visible = name == 'to_s' ? @closed_world.native_return_sources_visible?(name, ruby_aliases) : @closed_world.name_visible_except_natives_in?(name, '/')
    if audited && visible
      kinds = audited.values.flat_map { |kind| Array(kind) }
      return audited if kinds.all? { |kind| !kind.is_a?(String) || !kind.include?('::') || @closed_world.native_class_constant_stable?(kind) }
    end
    return nil unless @closed_world.name_visible_except_natives_in?(name, NativeExactDirect::RGSS_SRC)

    paths = @closed_world.native_paths_spelling(name)
    owners = paths.empty? ? nil : NativeDirect.registered_owners(name, paths)
    return nil if owners.nil? || owners.empty?

    owners.to_h do |owner|
      kind = NativeResultFacts.kind(name, owner)
      return nil unless kind && NativeDirect.registration_count(name, owner, paths) == 1
      return nil if kind.is_a?(String) && !@closed_world.native_class_constant_stable?(kind)

      [owner, kind]
    end
  end

  # What the `<native>` placeholder definition of a name returns: the join of its owners' kinds.
  def native_result_def_mask(d, classes:)
    kinds = d.irep.nil? && native_result_name_kinds(d.name)
    return NumericFlow::OTHER unless kinds

    kinds.each_value.reduce(0) { |mask, kind| mask | native_result_bits(kind, classes) }
  end

  # The class set of `name` sent to a receiver holding the class bits of `recv`, or nil when no
  # class bit in it has a fact (every other site keeps its old answer). A bit without a fact, or
  # any other bit, makes the result unknown; nil only raises when nothing answers `name` on it.
  # +classes+ keeps a class result as OTHER for the numeric flow, which carries no class bits.
  def native_result_flow_mask(name, recv, classes: true)
    return nil unless recv.is_a?(Integer)

    mask = 0
    rest = recv
    found = false
    class_bits = native_result_class_bits
    class_bits.each do |klass, bit, position|
      # Each class owns one bit; indexing avoids a temporary bignum intersection.
      next unless recv[position] == 1

      rest &= ~bit
      kind = native_result_kind(name, klass)
      found ||= !kind.nil?
      mask |= native_result_bits(kind, classes)
    end
    return nil unless found

    rest &= ~NumericFlow::NIL if nil_unanswerable?(name)
    rest.zero? ? mask : mask | NumericFlow::OTHER
  end

  def native_result_bits(kind, classes)
    case kind
    when :fixnum then NumericFlow::INT
    when :float then NumericFlow::FLT
    when :nil then NumericFlow::NIL
    when Array then kind.reduce(0) { |mask, member| mask | native_result_bits(member, classes) }
    when String
      core = RETURN_CORE_CLASS.key(kind)
      core || (classes ? numeric_class_bit(kind) : NumericFlow::OTHER)
    else NumericFlow::OTHER
    end
  end

  # NumericFlow's answer for a SEND whose receiver the exact-class flow knows (nil: no fact).
  def native_result_numeric_mask(irep, index, insn)
    return nil unless @native_results_ready && %w[SEND SEND0].include?(insn.op)

    native_result_flow_mask(insn.sym, exact_flow_mask(irep, index, insn.reg), classes: false)
  end

  # FIXNUM_RETURN_PROOF's native source: the send provably returns mrb_fixnum_value(..). INT alone
  # means every class bit of the receiver had a :fixnum fact (a bit without one adds OTHER).
  def native_fixnum_result?(irep, index, insn)
    return false unless @native_results_ready && %w[SEND SEND0].include?(insn.op)

    native_result_flow_mask(insn.sym, exact_flow_mask(irep, index, insn.reg), classes: false) == NumericFlow::INT
  end
end
