# frozen_string_literal: true

require 'set'
require_relative 'factory_flow'

# CodeGen: DECLARED_ELEMENT_GUARD and DECLARED_ELEMENT_MASK.
#
# An RBS `@items: Array[Integer]` declares the element class of an ivar's Array. Nothing proves it: an element store can
# be made anywhere (a native `<<`, a reflective write), so the declaration is checked where the element is read instead.
# A GETIDX/GETIDX0 whose receiver's one reaching definition is `@items` of a declaring class tests its result after the
# read (DECLARED_ELEMENT_GUARD): the element must be the declared built-in class or nil (an index past the end). A
# mismatch raises BC2cppDeclarationViolation through bc2cpp_declared_ivar_violation, as a declared ivar's store does.
# Reading the element is the only place the flow uses the declaration (DECLARED_ELEMENT_MASK), so a read the guard does
# not cover is never given the class. One class is declared: a built-in one, a program class, or a native class with no
# subclass (declared_element_kept?).
class CodeGen
  class << self
    # { [owner, name without @] => { kind:, text: } } for this build (nil or empty: none).
    attr_accessor :declared_ivar_elements
    # DECLARED_ARG_ELEMENT: { irep label => { register => { kind:, text:, klass: } } } of the positional parameters a
    # signature declares `Array[T]` (or `Array[T]?`) for (nil or empty: none).
    attr_accessor :declared_arg_elements
    # DECLARED_RECORD_READ: { irep label => { register => { key => { kind:, klass:, nilable:, text: } } } } of the
    # positional parameters a signature declares a record type `{ k: T, ?j: U? }` for (nil or empty: none).
    attr_accessor :declared_arg_records
  end

  DECLARED_ELEMENT_CLASSES = {
    'Integer' => [:integer, 'Integer'],
    'Float' => [:float, 'Float'],
    'Symbol' => [:symbol, 'Symbol'],
    'String' => [:string, 'String'],
    'Array' => [:array, 'Array'],
    'Hash' => [:hash, 'Hash'],
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
    # DECLARED_NATIVE: any other one-class Array element is a candidate, kept only for a native class
    # (declared_element_kept?).
    (applied.ivar_sigs || {}).each_value do |iv|
      key = [iv.owner, iv.name.to_s.delete_prefix('@')]
      classes = iv.type.element_classes
      next unless iv.type.kind == :array && classes && classes.size == 1 && !out.key?(key)

      klass = classes.first.to_s
      out[key] = { kind: :class, text: "Array[#{klass}]", klass: klass, native_only: true } if klass.match?(/\A[A-Z][\w:]*\z/)
    end
    out
  end

  # DECLARED_ARG_ELEMENT: the same element kinds for declared parameters (applied.ir_arg_elements).
  def self.declared_arg_element_table(applied)
    return {} unless applied

    optional = applied.ir_arg_optional_elements || {}
    (applied.ir_arg_elements.keys | optional.keys).each_with_object({}) do |label, acc|
      regs = applied.ir_arg_elements.fetch(label, {}).merge(optional.fetch(label, {}))
      entries = regs.filter_map do |reg, classes|
        next unless classes.is_a?(Set) && classes.size == 1

        klass = classes.first.to_s
        kind, = DECLARED_ELEMENT_CLASSES[klass]
        kind ||= :class if klass.match?(/\A[A-Z][\w:]*\z/) && !%w[Array Hash Object NilClass].include?(klass)
        [reg, { kind: kind, text: "Array[#{klass}]", klass: klass }] if kind
      end
      acc[label] = entries.to_h unless entries.empty?
    end
  end

  # DECLARED_RECORD_READ: the checkable fields of each record parameter (applied.ir_arg_records). A field is checkable
  # when its type is one class of DECLARED_ELEMENT_CLASSES or a program class, optionally `T?`; an optional key (`?k:`)
  # reads nil when absent. Other fields (untyped, unions) are left out and their reads stay unchecked.
  def self.declared_arg_record_table(applied)
    return {} unless applied && applied.ir_arg_records

    applied.ir_arg_records.each_with_object({}) do |(label, regs), acc|
      table = regs.each_with_object({}) do |(reg, record), out|
        fields = {}
        optional = record.respond_to?(:optional_fields) ? record.optional_fields : {}
        [[record.fields, false], [optional, true]].each do |set, opt|
          set.each do |key, type|
            field = record_field_spec(type, opt)
            fields[key.to_sym] = field if field
          end
        end
        out[reg] = fields unless fields.empty?
      end
      acc[label] = table unless table.empty?
    end
  end

  def self.record_field_spec(type, optional_key)
    nilable = optional_key
    if type.is_a?(RBS::Types::Optional)
      nilable = true
      type = type.type
    end
    return nil unless type.is_a?(RBS::Types::ClassInstance) && type.args.empty?

    klass = type.name.to_s.delete_prefix('::')
    kind, = DECLARED_ELEMENT_CLASSES[klass]
    kind ||= :class if klass.match?(/\A[A-Z][\w:]*\z/) && !%w[Array Hash Object NilClass BasicObject].include?(klass)
    return nil unless kind

    { kind: kind, klass: klass, nilable: nilable, text: "#{klass}#{'?' if nilable}" }
  end

  # DECLARED_RECORD_READ: the field entry a GETIDX at +idx+ reads, when its receiver's every reaching definition is the
  # entry value of one declared record parameter and its key is one literal Symbol the record declares; else nil. The
  # read is tested after it runs (declared_element_getidx_guard), so the field class holds whatever wrote the Hash,
  # aliases and mutations before the read included. BC2CPP_DECLARED_RECORD_READ=0 turns it off.
  def declared_record_read(irep, idx, insn)
    return nil unless insn.op == :GETIDX && irep && idx && ENV['BC2CPP_DECLARED_RECORD_READ'] != '0'

    table = self.class.declared_arg_records&.[](irep.label)
    return nil unless table

    producers = BytecodeIR.producers(irep, idx, insn.regs.first)
    return nil if producers.nil? || producers.empty? || !producers.all?(&:entry?) || producers.map(&:reg).uniq.size != 1

    reg = producers.first.reg.to_i
    fields = table[reg]
    key = fields && record_literal_key(irep, idx, insn.regs.first.to_i + 1)
    field = key && fields[key]
    return nil unless field && (field[:kind] != :class || @closed_world&.exact_class?(field[:klass]))

    owner = @owner_of[irep.label]
    where = owner ? "#{owner.owner}##{owner.name}" : irep.label.to_s
    field.merge(owner: where, name: "arg#{reg}[:#{key}]", subject: "#{where} argument #{reg}[:#{key}]",
                marker: "#{where} arg#{reg}[:#{key}]")
  end

  # The one literal Symbol the key register holds at +idx+ (handler edges crossed), else nil.
  def record_literal_key(irep, idx, key_reg)
    defs = BytecodeIR.reaching_definitions(irep, idx, key_reg, through_handlers: true, shared: true)
    return nil unless defs && defs.size == 1 && !defs.first.entry?

    writer = BytecodeIR.for(irep).source_at(defs.first.index)
    writer.op == :LOADSYM ? writer.sym&.to_sym : nil
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
      return declared_element_kept?(entry) ? entry.merge(owner: k, name: name) : nil if entry

      k = @superclass_of[k]
    end
    nil
  end

  # DECLARED_NATIVE: an element of a native class (ClosedWorld#native_class?) is tested by its exact class, so it is kept
  # only while ClosedWorld#native_family is the class alone; a candidate entry (native_only) only for such a class.
  def declared_element_kept?(entry)
    return true unless entry[:kind] == :class

    native = @closed_world&.native_class?(entry[:klass])
    return !entry[:native_only] unless native

    declared_native_exact?(entry[:klass])
  end

  def declared_native_exact?(klass)
    (@declared_native_exact ||= {}).fetch(klass) do
      @declared_native_exact[klass] = !@closed_world.nil? && RbsParamCheck.native_declarations? &&
                                      @closed_world.native_family(klass) == [klass]
    end
  end

  # The receiver's declared element entry when its one reaching definition is an ivar read, else nil.
  def declared_element_receiver(irep, idx, reg, owner, derived: false, depth: 0)
    return nil unless irep && idx && reg && owner

    producers = BytecodeIR.producers(irep, idx, reg)
    return nil if producers.nil? || producers.empty?
    return declared_arg_element_receiver(irep, producers) if producers.any?(&:entry?)

    # `(@x || [])` for a read or loop: an empty Array literal adds no element (a store could go into the literal).
    producers = producers.reject { |p| empty_array_literal?(p.insn) } if derived && producers.size > 1
    return nil unless producers.size == 1

    producer = producers.first
    unless producer.insn&.op == :GETIV
      return nil unless derived

      return declared_reader_receiver(irep, producer) || element_preserving_receiver(irep, idx, producer, owner, depth)
    end
    return nil unless self.class.declared_ivar_elements && !self.class.declared_ivar_elements.empty?

    declared_element_entry(owner, producer.insn.ivar)
  end

  # DECLARED_ELEMENT_DERIVED (reads and loops only): a no-argument filter or reordering of a receiver with a declared
  # element (`xs.reject(&:x)`, `@a.sort`, `@a + @b` of one element), used once and only by the consumer at +idx+, holds
  # only elements of that receiver. The consumer still tests every element it binds or reads, so this only picks the
  # class it tests. A copy something else can reach (and so store into) is refused. BC2CPP_DECLARED_ELEMENT_DERIVED=0.
  ELEMENT_PRESERVING = %w[reject select filter sort sort_by uniq compact dup reverse].to_set.freeze

  def element_preserving_receiver(irep, idx, producer, owner, depth)
    insn = producer.insn
    return nil if insn.nil? || depth >= 4 || ENV['BC2CPP_DECLARED_ELEMENT_DERIVED'] == '0'
    return nil unless %i[SEND SEND0 SENDB ADD GETIDX].include?(insn.op)

    uses = FactoryFlow.uses(irep, producer.index, producer.reg)
    return nil unless uses && uses.map(&:first).uniq == [idx]

    inner = ->(r) { declared_element_receiver(irep, producer.index, r, owner, derived: true, depth: depth + 1) }
    if insn.op == :ADD
      left = inner.call(insn.reg)
      right = left && inner.call(insn.reg + 1)
      return left if right && right[:kind] == left[:kind] && right[:klass] == left[:klass]

      return nil
    end
    return inner.call(insn.reg) if declared_slice_producer?(irep, producer.index, insn)
    return nil unless %i[SEND SEND0 SENDB].include?(insn.op)
    return nil unless ELEMENT_PRESERVING.include?(insn.sym.to_s) && insn.argc.to_i.zero? && insn.plain_fixed_argc?

    inner.call(insn.reg)
  end

  # DECLARED_ELEMENT_READER (reads and loops only): `x.actors` returns `@actors` of `x` itself when `x` is exactly one
  # class whose lookup of the name reaches a public attr_reader. The class comes from declared_reader_states, a flow
  # that never takes this branch, so every flow typing the read and the codegen emitting its guard read one fixed
  # answer. BC2CPP_DECLARED_ELEMENT_READER=0 turns it off.
  def declared_reader_receiver(irep, producer)
    insn = producer.insn
    return nil unless insn && (insn.op == :SEND0 || (insn.op == :SEND && insn.plain_fixed_argc? && insn.argc.to_i.zero?))
    return nil if ENV['BC2CPP_DECLARED_ELEMENT_READER'] == '0' || @rc_reader_prior || !@rc_scoped_ready

    name = insn.sym.to_s
    @declared_reader_names ||= self.class.declared_ivar_elements.to_h.keys.to_set { |(_, ivar)| ivar }
    return nil unless @declared_reader_names.include?(name)

    klass = declared_reader_receiver_class(irep, producer.index, insn.reg)
    return nil unless klass && declared_reader_target?(klass, name)

    declared_element_entry(klass, name)
  end

  # The one program class declared_reader_states gives +reg+ read at +index+ (no nil, no other class), or nil.
  def declared_reader_receiver_class(irep, index, reg)
    return nil unless @closed_world&.exact_instances_singleton_free?
    return nil if reg.to_i >= irep.nregs.to_i || fixnum_proof_ctx(irep)[:upvars].include?(reg)

    klass = return_class_of_mask(declared_reader_states(irep)&.[](index)&.[](reg.to_i))
    klass if klass.is_a?(String) && !RETURN_BITLESS_CLASSES.include?(klass) && @closed_world.class_hierarchy(klass)
  end

  # The receiver-scoped exact-class flow of +irep+ (return_class_method_oracle), run once with DECLARED_ELEMENT_READER
  # off (@rc_reader_prior) and kept out of the scoped cache. The answer it gives is fixed once computed.
  def declared_reader_states(irep)
    @rc_reader_states ||= {}
    return @rc_reader_states[irep.label] if @rc_reader_states.key?(irep.label)

    prior = @rc_reader_prior
    begin
      @rc_reader_prior = true
      @rc_reader_states[irep.label] =
        BytecodeIR::NumericClasses.states(irep, return_class_method_oracle(irep), fixnum_proof_ctx(irep)[:upvars], {})
    ensure
      @rc_reader_prior = prior
    end
  end

  # Does an explicit `name` call on an exact +klass+ instance run a plain attr_reader (mrb_iv_get of `@name`)?
  def declared_reader_target?(klass, name)
    @declared_reader_targets ||= {}
    key = [klass, name]
    return @declared_reader_targets[key] if @declared_reader_targets.key?(key)

    ok = @closed_world.inherited_lookup_safe?(name, klass) && !devirt_blocked_name?(name) &&
         !bytecode_ir_name_removed?(name)
    target, known = ok ? closed_world_lookup_target(name, klass, Set.new, any_visibility: true) : [nil, false]
    @declared_reader_targets[key] = known && target && target.kind == :ivar_accessor && target.irep.nil? &&
                                    target.owner != '<native>' && explicit_call_visible?(name, target) ? true : false
  end

  # DECLARED_INDEX_KIND: a slice of the receiver (`xs[a..b]`, `xs[0...-1]`, `xs[i, n]`): Array#[] with a Range or with two
  # arguments returns a fresh Array of receiver elements (ary_subseq) or nil. Only a Range literal's index proves the
  # one-argument form here: this runs inside the flows, which give no settled index class.
  def declared_slice_producer?(irep, index, insn)
    return false if ENV['BC2CPP_DECLARED_INDEX_KIND'] == '0'
    return insn.sym.to_s == '[]' && insn.argc.to_i == 2 && insn.plain_fixed_argc? if insn.op == :SEND
    return false unless insn.op == :GETIDX

    defs = BytecodeIR.reaching_definitions(irep, index, insn.regs[1], shared: true)
    !defs.nil? && !defs.empty? && defs.all? do |d|
      !d.entry? && BytecodeIR::Ops::RANGE_BUILD.include?(BytecodeIR.for(irep).source_at(d.index).op)
    end
  end

  # DECLARED_ARG_ELEMENT: a receiver whose reaching definitions are a declared `Array[T]` parameter's entry value, plus
  # any number of empty Array literals (`xs || []`), which add no element. BC2CPP_DECLARED_ARG_ELEMENT=0 turns it off.
  def declared_arg_element_receiver(irep, producers)
    return nil if ENV['BC2CPP_DECLARED_ARG_ELEMENT'] == '0'

    table = self.class.declared_arg_elements&.[](irep.label)
    return nil unless table

    entries = producers.reject { |p| !p.entry? && empty_array_literal?(p.insn) }
    return nil unless entries.all?(&:entry?) && entries.map(&:reg).uniq.size == 1

    reg = entries.first.reg.to_i
    entry = table[reg]
    return nil unless entry

    owner = @owner_of[irep.label]
    where = owner ? "#{owner.owner}##{owner.name}" : irep.label.to_s
    entry.merge(owner: where, name: "arg#{reg}", subject: "#{where} argument #{reg}[]", marker: "#{where} arg#{reg}")
  end

  def empty_array_literal?(insn)
    insn && insn.op == :ARRAY && insn.typed.size == 2 && insn.typed[1].value.to_i.zero?
  end

  # DECLARED_ELEMENT_GUARD: the statement checking the element a GETIDX/GETIDX0 at +idx+ stored into `dest` (a register
  # name). Empty when the receiver has no declared element.
  def declared_element_getidx_guard(insn, irep, owner_def, idx, reg_offset)
    return '' unless %i[GETIDX GETIDX0].include?(insn.op)

    # The raw register, as the flow's mask reads it (declared_element_index_mask) and as the emitted read names it.
    receiver = insn.op == :GETIDX0 ? insn.regs[1] : insn.regs.first
    entry = declared_element_receiver(irep, idx, receiver, owner_def&.owner, derived: true)
    unless entry
      field = declared_record_read(irep, idx, insn)
      return field ? element_guard_statement(field, RegName[insn.regs.first], nil_ok: field[:nilable], verb: 'read') : ''
    end

    read = declared_index_read(irep, idx, insn)
    return '' unless read

    # The read result is nil past the end, so nil is allowed here.
    guard = element_guard_statement(entry, RegName[insn.regs.first], nil_ok: true, verb: 'read')
    return guard if read == :always

    key = RegName[insn.regs[1]]
    "  if (mrb_integer_p(#{key}) || mrb_bigint_p(#{key})) {\n  #{guard}  }\n"
  end

  # DECLARED_INDEX_KIND: what a one-index read of a declared element receiver returns, given the flow's class bits
  # +key+ for its index. :element when the index is only an Integer (fixnum or heap): Array#[] reads one element, nil
  # past the end. :slice when it is only an exact Range: a fresh Array of receiver elements (ary_subseq) or nil. 0 for
  # an index with no value yet, nil for anything else. BC2CPP_DECLARED_INDEX_KIND=0 reads every index as an element.
  def declared_index_kind(insn, key)
    return :element if insn.op == :GETIDX0 || ENV['BC2CPP_DECLARED_INDEX_KIND'] == '0'
    return nil unless key.is_a?(Integer) && !key.negative?
    return 0 if key.zero?
    return :element if (key & ~NumericFlow::INT).zero?

    key == NumericFlow::RNG ? :slice : nil
  end

  # DECLARED_INDEX_KIND, where it is enforced: every flow gives the read its element class only for an index its own
  # state proves Integer (declared_element_index_mask), so the guard must test every read some flow may prove Integer.
  # The settled table flow decides: proven Integer, always (:always); neither INT nor OTHER (unknown), so no Integer
  # reaches it and no sound flow proves one, none (nil); otherwise, or with no settled flow, the guard tests the index
  # itself at run time (:tested).
  def declared_index_read(irep, idx, insn)
    return :always if declared_index_kind(insn, nil) == :element

    ready = @foreign_method_names && @closed_world&.exact_instances_singleton_free? && @native_results_ready && @rc_scoped_ready
    key = ready ? return_class_states(irep)&.[](idx)&.[](insn.regs[1].to_i) : nil
    return :tested unless key.is_a?(Integer) && key.positive?
    return :always if declared_index_kind(insn, key) == :element

    key.anybits?(NumericFlow::INT | NumericFlow::OTHER) ? :tested : nil
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
  PUSH_SENDS = { '<<' => 1, 'push' => :any, 'unshift' => :any }.freeze

  def declared_element_push_guard(insn, irep, owner_def, idx)
    return '' unless insn.op == :SEND && PUSH_SENDS.key?(insn.sym.to_s)
    return '' if insn.keyword_argc.to_i.positive? || insn.positional_splat?

    arity = PUSH_SENDS[insn.sym.to_s]
    argc = insn.argc.to_i
    return '' unless arity == :any ? argc.positive? : argc == arity

    entry = declared_element_receiver(irep, idx, insn.reg, owner_def&.owner)
    return '' unless entry

    # Every pushed argument is tested, in order, before the native mutator runs.
    (1..argc).map { |k| element_guard_statement(entry, RegName[insn.reg + k], nil_ok: false, verb: 'assigned') }.join
  end

  # The C statement raising when `var` (an mrb_value) is not the declared element kind (and not nil, when nil_ok).
  def element_guard_statement(entry, var, nil_ok:, verb:)
    quote = ->(text) { text.gsub(/["\\]/) { |c| "\\#{c}" } }
    cond = case entry[:kind]
           when :float then "mrb_float_p(#{var})"
           when :integer then "(mrb_integer_p(#{var}) || mrb_bigint_p(#{var}))"
           when :symbol then "mrb_symbol_p(#{var})"
           when :string then "mrb_string_p(#{var})"
           when :array then "mrb_array_p(#{var})"
           when :hash then "mrb_hash_p(#{var})"
           when :class then exact_class_guard(owner_class_ptr_expr(entry[:klass]), var)
           end
    ok = nil_ok ? "mrb_nil_p(#{var}) || (#{cond})" : cond
    "  if (mrb_unlikely(!(#{ok}))) " \
      "bc2cpp_declared_ivar_violation(M, #{var}, \"#{quote.call(entry[:subject] || "#{entry[:owner]}#@#{entry[:name]}[]")}\", " \
      "\"#{quote.call(entry[:text])}\"); /* DECLARED_ELEMENT_GUARD #{entry[:marker] || "#{entry[:owner]}##{entry[:name]}"} #{verb} */\n"
  end

  # DECLARED_LOOP_ELEMENT: the declared program-class element of an inlined Array loop's receiver (its one reaching
  # definition at the SENDB is `@x` of a declaring class), or nil. The loop tests each element it binds
  # (declared_loop_element_guard), so inside that body the parameter is exactly the class while no write reaches it
  # (declared_loop_element_class). Only an exact program class: the guard's class test is pointer equality.
  def declared_loop_element(region, irep, d)
    return nil if region[:ssendb] || d.nil? || ENV['BC2CPP_DECLARED_LOOP_ELEMENT'] == '0'

    idx = irep.index_of_addr(region[:sendb_addr])
    entry = declared_element_receiver(irep, idx, region[:dest_reg], d.owner, derived: true)
    entry if entry && declared_element_exact?(entry)
  end

  # Is the element guard's test the element's exact class? A program class is tested by pointer equality; Integer,
  # Float and Symbol have no subclass; String, Array and Hash are tested by kind, which is their class only in a build
  # with no subclass of them (core_class_subclass_free?, as for the parameter and keyword guards).
  def declared_element_exact?(entry)
    case entry[:kind]
    when :class then @closed_world&.exact_class?(entry[:klass]) || declared_native_exact?(entry[:klass])
    when :integer, :float, :symbol then ENV['BC2CPP_DECLARED_CORE_ELEMENT'] != '0'
    when :string, :array, :hash
      ENV['BC2CPP_DECLARED_CORE_ELEMENT'] != '0' && !block_core_world.nil? && core_class_subclass_free?(entry[:klass])
    else false
    end
  end

  # DECLARED_ELEMENT_GUARD on a loop element: the statement testing the element bound to `var`. An element inside the
  # bounds is never a read past the end, so nil raises too.
  def declared_loop_element_guard(region, var)
    entry = region[:declared_element]
    entry ? element_guard_statement(entry, var, nil_ok: false, verb: 'iterated') : ''
  end

  # The class DECLARED_LOOP_ELEMENT gives +reg+ at +idx+ of +irep+: only while that irep's inlined body is compiled
  # under its guard, and only when every reaching definition is the parameter's entry value (a MOVE of it counts).
  def declared_loop_element_class(irep, idx, reg)
    scope = @declared_loop_elements
    return nil if scope.nil? || scope.empty?

    hits = scope.select { |e| e[:irep].equal?(irep) }
    return nil if hits.empty?

    defs = BytecodeIR.reaching_definitions(irep, idx, reg, shared: true)
    return nil if defs.nil? || defs.empty?

    # A block may bind several element parameters (`sort { |a, b| }`), each under its own entry test.
    classes = defs.map { |df| df.entry? && hits.find { |e| e[:reg] == df.reg.to_s }&.dig(:klass) }
    classes.uniq.size == 1 && classes.first ? classes.first : nil
  end

  # declared_loop_element_class as flow bits (declared_arg_bits), or nil.
  def declared_loop_element_bits(irep, idx, reg)
    klass = declared_loop_element_class(irep, idx, reg)
    return nil unless klass

    kind = DECLARED_ELEMENT_CLASSES[klass]&.first || :class
    bits = declared_arg_bits(klass, kind, false)
    bits.zero? ? nil : bits
  end

  # DECLARED_ELEMENT_MASK: the class set of a GETIDX/GETIDX0 result the flow may use: for an element read, the declared
  # element's class and nil (guarded by DECLARED_ELEMENT_GUARD, see declared_index_read); for a slice, Array or nil.
  # nil when no element is declared or the index kind is unproven.
  def declared_element_index_mask(irep, index, insn, state)
    return nil unless %i[GETIDX GETIDX0].include?(insn.op)

    receiver = insn.op == :GETIDX0 ? insn.regs[1] : insn.regs.first
    owner = @owner_of[irep.label]&.owner
    entry = declared_element_receiver(irep, index, receiver, owner, derived: true)
    return declared_record_index_mask(irep, index, insn) unless entry

    kind = declared_index_kind(insn, insn.op == :GETIDX ? state[insn.regs[1].to_i] : nil)
    return kind if kind == 0
    return declared_slice_mask(state[receiver.to_i]) if kind == :slice
    return nil unless kind == :element

    bits = if entry[:kind] == :class
             declared_arg_bits(entry[:klass], :class, false)
           else
             NumericFlow.class_bits(entry[:klass]).keys.inject(0, :|)
           end
    # A class with no bit yet gives no mask: the flow keeps the unknown answer rather than renumbering the masks.
    bits.zero? ? nil : bits | NumericFlow::NIL
  end

  # DECLARED_INDEX_KIND: a Range read of an exact ::Array whose `[]` is mruby's own is an exact ::Array or nil; it needs
  # no guard. Its elements are the receiver's, which only a consumer testing them uses (declared_slice_producer?).
  def declared_slice_mask(receiver)
    return nil unless receiver.is_a?(Integer) && receiver.anybits?(NumericFlow::ARR)
    return nil unless (receiver & ~(NumericFlow::ARR | NumericFlow::NIL)).zero? && frozen_table_name_safe?('[]', 'Array')

    NumericFlow::ARR | NumericFlow::NIL
  end

  # DECLARED_RECORD_READ: the field's class (nil too when it may be absent or nil), for the guarded read only.
  def declared_record_index_mask(irep, index, insn)
    field = declared_record_read(irep, index, insn)
    return nil unless field

    bits = if field[:kind] == :class
             declared_arg_bits(field[:klass], :class, false)
           else
             NumericFlow.class_bits(field[:klass]).keys.inject(0, :|)
           end
    return nil if bits.zero?

    field[:nilable] ? bits | NumericFlow::NIL : bits
  end
end
