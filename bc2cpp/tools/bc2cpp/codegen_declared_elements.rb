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

    out = applied.ir_ivar_elements.each_with_object({}) do |((owner, name), classes), acc|
      next unless classes.is_a?(Set) && classes.size == 1

      klass = classes.first.to_s
      kind, = DECLARED_ELEMENT_CLASSES[klass]
      next unless kind

      acc[[owner, name.to_s.delete_prefix('@')]] = { kind: kind, text: "Array[#{klass}]", klass: klass }
    end
    # A program class: the RBS element of an exact-class Array (ivar_elements is filled only from declarations; the
    # traced hints go to element_layout, which is not a declaration and is not used here).
    (applied.ivar_elements || {}).each do |owner, names|
      names.each do |name, klass|
        next unless klass.is_a?(String) && !out.key?([owner, name.to_s.delete_prefix('@')])

        out[[owner, name.to_s.delete_prefix('@')]] = { kind: :class, text: "Array[#{klass}]", klass: klass }
      end
    end
    out
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

    # The read result is nil past the end, so nil is allowed here.
    element_guard_statement(entry, RegName[insn.regs.first], nil_ok: true, verb: 'read')
  end

  # DECLARED_ELEMENT_GUARD on a store: `@items[i] = v` tests the stored value before the store writes it. nil is not an
  # allowed element (only a read past the end yields nil), so a nil store raises too.
  def declared_element_setidx_guard(insn, irep, owner_def, idx, reg_offset)
    return '' unless insn.op == :SETIDX

    entry = declared_element_receiver(irep, idx, insn.regs.first, owner_def&.owner)
    return '' unless entry

    element_guard_statement(entry, RegName[insn.regs[2]], nil_ok: false, verb: 'assigned')
  end

  # DECLARED_ELEMENT_GUARD on a native store: `@items << v` (a one-argument `<<` on a declared element receiver) tests
  # the argument before the push. Only that form: other stores that run a native mutator are not checked here.
  def declared_element_push_guard(insn, irep, owner_def, idx)
    return '' unless insn.op == :SEND && insn.sym.to_s == '<<' && insn.argc == 1 && !insn.keyword_argc.to_i.positive?

    entry = declared_element_receiver(irep, idx, insn.reg, owner_def&.owner)
    return '' unless entry

    element_guard_statement(entry, RegName[insn.reg + 1], nil_ok: false, verb: 'assigned')
  end

  # The C statement raising when `var` (an mrb_value) is not the declared element kind (and not nil, when nil_ok).
  def element_guard_statement(entry, var, nil_ok:, verb:)
    quote = ->(text) { text.gsub(/["\\]/) { |c| "\\#{c}" } }
    cond = case entry[:kind]
           when :float then "mrb_float_p(#{var})"
           when :integer then "(mrb_integer_p(#{var}) || mrb_bigint_p(#{var}))"
           when :symbol then "mrb_symbol_p(#{var})"
           when :string then "mrb_string_p(#{var})"
           when :class then exact_class_guard(owner_class_ptr_expr(entry[:klass]), var)
           end
    ok = nil_ok ? "mrb_nil_p(#{var}) || (#{cond})" : cond
    "  if (mrb_unlikely(!(#{ok}))) " \
      "bc2cpp_declared_ivar_violation(M, #{var}, \"#{quote.call("#{entry[:owner]}#@#{entry[:name]}[]")}\", " \
      "\"#{quote.call(entry[:text])}\"); /* DECLARED_ELEMENT_GUARD #{entry[:owner]}##{entry[:name]} #{verb} */\n"
  end

  # DECLARED_ELEMENT_MASK: the class set of a GETIDX/GETIDX0 result the flow may use: the declared element's class and
  # nil (guarded by DECLARED_ELEMENT_GUARD, so the read is never another class). nil when no element is declared.
  def declared_element_index_mask(irep, index, insn)
    return nil unless %i[GETIDX GETIDX0].include?(insn.op)

    receiver = insn.op == :GETIDX0 ? insn.regs[1] : insn.regs.first
    owner = @owner_of[irep.label]&.owner
    entry = declared_element_receiver(irep, index, receiver, owner)
    return nil unless entry

    bits = if entry[:kind] == :class
             declared_arg_bits(entry[:klass], :class, false)
           else
             NumericFlow.class_bits(entry[:klass]).keys.inject(0, :|)
           end
    # A class with no bit yet gives no mask: the flow keeps the unknown answer rather than renumbering the masks.
    bits.zero? ? nil : bits | NumericFlow::NIL
  end
end
