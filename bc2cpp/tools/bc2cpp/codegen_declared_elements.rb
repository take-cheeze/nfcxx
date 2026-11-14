# frozen_string_literal: true

require 'set'

# CodeGen: DECLARED_ELEMENT_GUARD and DECLARED_ELEMENT_MASK.
#
# An RBS `@items: Array[Integer]` declares the element class of an ivar's Array. Nothing proves it: an element store can
# be made anywhere (a native `<<`, a reflective write), so the declaration is checked where the element is read instead.
# A GETIDX/GETIDX0 whose receiver's one reaching definition is `@items` of a declaring class tests its result after the
# read (DECLARED_ELEMENT_GUARD): the element must be the declared built-in class or nil (an index past the end). A
# mismatch raises BC2cppDeclarationViolation through bc2cpp_declared_ivar_violation, as a declared ivar's store does.
# Reading the element is the only place the flow uses the declaration (DECLARED_ELEMENT_MASK), so a read the guard does
# not cover is never given the class. Only single built-in classes are declared here: Integer, Float, Symbol, String.
class CodeGen
  class << self
    # { [owner, name without @] => { kind:, text: } } for this build (nil or empty: none).
    attr_accessor :declared_ivar_elements
  end

  DECLARED_ELEMENT_CLASSES = {
    'Integer' => [:integer, 'Integer'],
    'Float' => [:float, 'Float'],
    'Symbol' => [:symbol, 'Symbol'],
    'String' => [:string, 'String'],
  }.freeze

  # The declarations of one build's applied signatures: { [owner, name] => { kind:, text: } } for each Array ivar whose
  # element type is exactly one of DECLARED_ELEMENT_CLASSES.
  def self.declared_element_table(applied)
    return {} unless applied

    applied.ir_ivar_elements.each_with_object({}) do |((owner, name), classes), out|
      next unless classes.is_a?(Set) && classes.size == 1

      klass = classes.first.to_s
      kind, = DECLARED_ELEMENT_CLASSES[klass]
      next unless kind

      out[[owner, name.to_s.delete_prefix('@')]] = { kind: kind, text: "Array[#{klass}]", klass: klass }
    end
  end

  # The declared element of ivar +name+ for +klass+ or its nearest declaring ancestor, or nil.
  def declared_element_entry(klass, name)
    table = self.class.declared_ivar_elements
    return nil if table.nil? || table.empty? || klass.nil?

    name = name.to_s.delete_prefix('@')
    k = klass
    64.times do
      return nil unless k.is_a?(String)

      entry = table[[k, name]]
      return entry.merge(owner: k, name: name) if entry

      k = @superclass_of[k]
    end
    nil
  end

  # The receiver's declared element entry when its one reaching definition is an ivar read, else nil.
  def declared_element_receiver(irep, idx, reg, owner)
    return nil unless irep && idx && reg && owner && self.class.declared_ivar_elements && !self.class.declared_ivar_elements.empty?

    producers = BytecodeIR.producers(irep, idx, reg)
    return nil unless producers&.size == 1

    producer = producers.first
    return nil if producer.entry? || producer.insn&.op != :GETIV

    declared_element_entry(owner, producer.insn.ivar)
  end

  # DECLARED_ELEMENT_GUARD: the statement checking the element a GETIDX/GETIDX0 at +idx+ stored into `dest` (a register
  # name). Empty when the receiver has no declared element.
  def declared_element_getidx_guard(insn, irep, owner_def, idx, reg_offset)
    return '' unless %i[GETIDX GETIDX0].include?(insn.op)

    # The raw register, as the flow's mask reads it (declared_element_index_mask) and as the emitted read names it.
    receiver = insn.op == :GETIDX0 ? insn.regs[1] : insn.regs.first
    entry = declared_element_receiver(irep, idx, receiver, owner_def&.owner)
    return '' unless entry

    var = RegName[insn.regs.first]
    quote = ->(text) { text.gsub(/["\\]/) { |c| "\\#{c}" } }
    cond = case entry[:kind]
           when :float then "mrb_float_p(#{var})"
           when :integer then "(mrb_integer_p(#{var}) || mrb_bigint_p(#{var}))"
           when :symbol then "mrb_symbol_p(#{var})"
           when :string then "mrb_string_p(#{var})"
           end
    "  if (mrb_unlikely(!(mrb_nil_p(#{var}) || (#{cond})))) " \
      "bc2cpp_declared_ivar_violation(M, #{var}, \"#{quote.call("#{entry[:owner]}#@#{entry[:name]}[]")}\", " \
      "\"#{quote.call(entry[:text])}\"); /* DECLARED_ELEMENT_GUARD #{entry[:owner]}##{entry[:name]} */\n"
  end

  # DECLARED_ELEMENT_MASK: the class set of a GETIDX/GETIDX0 result the flow may use: the declared element's class and
  # nil (guarded by DECLARED_ELEMENT_GUARD, so the read is never another class). nil when no element is declared.
  def declared_element_index_mask(irep, index, insn)
    return nil unless %i[GETIDX GETIDX0].include?(insn.op)

    receiver = insn.op == :GETIDX0 ? insn.regs[1] : insn.regs.first
    owner = @owner_of[irep.label]&.owner
    entry = declared_element_receiver(irep, index, receiver, owner)
    return nil unless entry

    NumericFlow.class_bits(entry[:klass]).keys.inject(0, :|) | NumericFlow::NIL
  end
end
