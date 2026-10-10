# frozen_string_literal: true

require_relative 'numeric_flow'

# CodeGen: INSTANCE_RECEIVER (ADR 0302). A `.singleton` definer answers a class or module object only,
# and no instance has a singleton method (ClosedWorld#exact_instances_singleton_free?), so a receiver
# the exact-class flow proves holds only instances may ignore `.singleton` owners in ClosedWorld#refusal.
class CodeGen
  # Core classes whose NumericFlow bits stand for instances of exactly that class.
  INSTANCE_CORE_BITS = { NumericFlow::INT => 'Integer', NumericFlow::FLT => 'Float', NumericFlow::ARR => 'Array',
                         NumericFlow::HSH => 'Hash', NumericFlow::STR => 'String', NumericFlow::RNG => 'Range' }.freeze

  # The exact classes (nil is an instance too, and adds none) the receiver of the SEND at +site+
  # holds, or nil when the flow proves less: an unmodelled value could be a class object.
  def receiver_instances(site, name)
    irep, idx, insn = site_flow_position(site)
    return nil unless @native_results_ready && irep && idx && insn&.sym == name
    return nil unless %w[SEND SEND0].include?(insn.op)

    mask = exact_flow_mask(irep, idx, insn.reg)
    return nil unless mask.is_a?(Integer) && mask.positive?

    classes = []
    rest = mask & ~NumericFlow::NIL
    INSTANCE_CORE_BITS.each do |bit, klass|
      next unless rest.anybits?(bit)

      classes << klass
      rest &= ~bit
    end
    (@numeric_class_bits || {}).to_a.each do |klass, bit|
      next unless rest.anybits?(bit)
      return nil unless instance_class?(klass)

      classes << klass
      rest &= ~bit
    end
    rest.zero? ? classes : nil
  end

  # A class whose instances are never class or module objects: declared and not derived from
  # Module or Class, or one of the RGSS native classes (all subclasses of Object).
  def instance_class?(klass)
    @closed_world.instance_class?(klass) || NATIVE_WRAPPER_CLASS_ACCESSORS.key?(klass)
  end
end
