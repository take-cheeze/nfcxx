# frozen_string_literal: true

require_relative 'native_result_facts'
require_relative 'numeric_flow'

# CodeGen: NATIVE_RESULT_FACTS (ADR 0302). A fact is used only for a receiver the exact-class flow
# proved, while lookup from that class provably reaches the registration (native_exact_owner_safe?).
class CodeGen
  # :fixnum, :float, a class name or nil for `name` sent to an exact `klass` receiver.
  def native_result_kind(name, klass)
    @native_result_kinds ||= {}
    key = [name, klass]
    @native_result_kinds[key] = compute_native_result_kind(name, klass) unless @native_result_kinds.key?(key)
    @native_result_kinds[key]
  end

  def compute_native_result_kind(name, klass)
    kind = NativeResultFacts.kind(name, klass)
    return nil unless kind && @closed_world&.exact_instances_singleton_free?
    return nil unless native_exact_owner_safe?(name, klass)
    # A class result is `RGSS::Rect` as the constant names it today.
    return nil if kind.is_a?(String) && !@closed_world.native_class_constant_stable?(kind)

    kind
  end

  # The kinds covering EVERY native definition of +name+ as { owner => kind }, or nil when one is
  # undeclared, not a unique parsed registration, or defined outside mruby-rgss/src. A Ruby
  # definition of the name is not checked here: the callers join it in (numeric_return_def_usable?).
  def native_result_name_kinds(name)
    @native_result_name_kinds ||= {}
    @native_result_name_kinds[name] = compute_native_result_name_kinds(name) unless @native_result_name_kinds.key?(name)
    @native_result_name_kinds[name]
  end

  def compute_native_result_name_kinds(name)
    return nil unless @closed_world&.exact_instances_singleton_free? && @native_name_sources
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
    return nil unless recv.is_a?(Integer) && @numeric_class_bits

    mask = 0
    rest = recv
    found = false
    @numeric_class_bits.to_a.each do |klass, bit|
      next unless recv.anybits?(bit)

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
    when String then classes ? numeric_class_bit(kind) : NumericFlow::OTHER
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
