# frozen_string_literal: true

require_relative 'escape_analysis'

# CodeGen: the escape analysis (ADR 0316) over this compiler's class facts.
class CodeGen
  ESCAPE_FLOW_CLASSES = { NumericFlow::INT => 'Integer', NumericFlow::FLT => 'Float', NumericFlow::ARR => 'Array',
                          NumericFlow::HSH => 'Hash', NumericFlow::STR => 'String', NumericFlow::NIL => 'NilClass',
                          NumericFlow::RNG => 'Range' }.freeze

  # The analyzer for this CodeGen, or nil when BC2CPP_ESCAPE_ANALYSIS=0 or no world was built (unit
  # checks that construct a CodeGen directly).
  def escape_analyzer
    return @escape_analyzer if defined?(@escape_analyzer)

    world = EscapeAnalysis.enabled? ? EscapeAnalysis.world : nil
    @escape_analyzer = world && EscapeAnalysis::Analyzer.new(world).tap do |analyzer|
      analyzer.receiver_classes = ->(irep, idx, reg) { escape_receiver_classes(irep, idx, reg) }
      analyzer.self_class = ->(irep) { escape_self_class(irep) }
    end
  end

  # BLOCK_FALLBACK_PROVEN (ADR 0316): the BLOCK at +index+ is handed only to callees that keep neither it nor
  # anything that reaches it, so the pointers it captures cannot outlive this frame. The by-name
  # allowlist (BLOCK_FALLBACK_UPVAR_SAFE_METHODS) is the other way in.
  def block_proven_to_stay?(irep, index)
    analyzer = escape_analyzer or return false

    !analyzer.creation(irep, index).escapes?
  end

  private

  # Every class the class flow says +reg+ may hold, nil when it names none or admits an unmodelled value.
  def escape_receiver_classes(irep, idx, reg)
    mask = exact_flow_mask(irep, idx, reg)
    return nil unless mask.is_a?(Integer) && mask.positive?

    names = ESCAPE_FLOW_CLASSES.filter_map { |bit, name| name if mask.anybits?(bit) }
    rest = mask & ~ESCAPE_FLOW_CLASSES.keys.reduce(0, :|)
    (@numeric_class_bits || {}).each do |klass, bit|
      next unless rest.anybits?(bit)

      names << klass
      rest &= ~bit
    end
    rest.zero? && !names.empty? ? names : nil
  end

  # The class or module whose instance method this irep (or the method it is a block of) is; nil for a
  # singleton method or a body whose owner is not a plain name.
  def escape_self_class(irep)
    # A block can run under another self (instance_eval, define_method): only a method body is certain.
    return nil unless @owner_of.key?(irep.label)

    owner = @owner_of[irep.label].owner
    owner.end_with?('.singleton') || owner.start_with?('<') ? nil : owner
  end
end
