# frozen_string_literal: true

require_relative 'bytecode_ir_ops'
require_relative 'ir_symbol_flow'

module BytecodeIR
  # Value classes, not representation/width proofs.
  class Types
    LITERAL_TYPES = {
      :LOADNIL => :NilClass, :LOADTRUE => :TrueClass, :LOADFALSE => :FalseClass,
      :LOADSYM => :Symbol, :SYMBOL => :Symbol, :INTERN => :Symbol, :STRING => :String,
      :ARRAY => :Array, :ARRAY2 => :Array, :HASH => :Hash,
      :RANGE_INC => :Range, :RANGE_EXC => :Range, :LAMBDA => :Proc, :BLOCK => :Proc
    }.freeze
    POOL_TYPES = { int32: :Integer, int64: :Integer, bigint: :Integer, float: :Float }.freeze
    ENTER_TYPES = { rest: [:Array], hash: [:Hash], block: [:Proc, :NilClass], local: [:NilClass] }.transform_values(&:freeze).freeze

    CALL_DEPTH_CAP = 24
    QUERY_CACHE_CAP = 2048
    CALL_QUERY_CAP = 2048

    Fact = Struct.new(:classes, :declared, :contracts, keyword_init: true) do
      def declared? = declared
    end

    # inferred_args: positional registers, plus the block register (a Proc join); inferred_keywords: required keyword
    # name => join; inferred_rest_elements: rest register => element join. Each is a call-site join (IrTypeFeedback).
    # declared_rest_elements: rest register => the T of a signature's `*T`.
    def initialize(irep, declared_args: {}, declared_optional_args: {}, declared_keywords: {}, declared_ivars: {}, declared_calls: {}, inferred_calls: {}, inferred_args: {}, inferred_keywords: {}, inferred_rest_elements: {}, declared_arg_elements: {}, declared_rest_elements: {}, declared_ivar_elements: {}, declared_const_elements: {}, source_resolver: nil, call_resolver: nil, argument_facts: {})
      @irep = irep
      required = irep.enter&.enter_fields&.first.to_i
      @argument_facts = argument_facts.to_h do |reg, fact|
        number = reg.to_s
        unless number.match?(/\A[1-9]\d*\z/) && number.to_i <= required && fact.is_a?(Fact) && !fact.classes.empty?
          raise ArgumentError, "bc2cpp: invalid IR argument fact R#{number}"
        end
        contracts = fact.contracts.empty? && fact.declared? ? ["argument:R#{number}"] : fact.contracts.dup
        [number, Fact.new(classes: fact.classes.to_set.dup.freeze, declared: fact.declared?, contracts: contracts.freeze).freeze]
      end.freeze
      @declared_args = declared_args.to_h do |reg, types|
        number = reg.to_s
        unless number.match?(/\A[1-9]\d*\z/) && number.to_i <= required
          raise ArgumentError, "bc2cpp: IR argument contract R#{number} is not a required parameter"
        end
        [number.dup.freeze, types.to_set.dup.freeze]
      end.freeze
      optional = irep.enter&.enter_fields&.[](1).to_i
      @declared_optional_args = declared_optional_args.to_h do |reg, types|
        number = reg.to_s
        unless number.match?(/\A[1-9]\d*\z/) && (required + 1..required + optional).cover?(number.to_i)
          raise ArgumentError, "bc2cpp: IR optional contract R#{number} is not an optional parameter"
        end
        [number.dup.freeze, types.to_set.dup.freeze]
      end.freeze
      @declared_keywords = declared_keywords.to_h { |name, types| [name.to_s, types.to_set.dup.freeze] }.freeze
      @declared_ivars = declared_ivars.to_h { |name, types| [name.to_s.delete_prefix('@').freeze, types.to_set.dup.freeze] }.freeze
      @declared_calls = declared_calls.to_h { |index, types| [index, types.to_set.dup.freeze] }.freeze
      @inferred_calls = inferred_calls.to_h { |index, types| [index, types.to_set.dup.freeze] }.freeze
      @inferred_args = inferred_args.to_h { |reg, types| [reg.to_s, types.to_set.dup.freeze] }.freeze
      @inferred_keywords = inferred_keywords.to_h { |name, types| [name.to_s, types.to_set.dup.freeze] }.freeze
      @inferred_rest_elements = inferred_rest_elements.to_h { |reg, types| [reg.to_s, types.to_set.dup.freeze] }.freeze
      @declared_arg_elements = declared_arg_elements.to_h { |reg, types| [reg.to_s, types.to_set.dup.freeze] }.freeze
      @declared_rest_elements = declared_rest_elements.to_h { |reg, types| [reg.to_s, types.to_set.dup.freeze] }.freeze
      @declared_ivar_elements = declared_ivar_elements.to_h { |name, types| [name.to_s.delete_prefix('@'), types.to_set.dup.freeze] }.freeze
      @declared_const_elements = declared_const_elements.to_h { |name, type| [name.to_s, Set[type.to_sym]] }.freeze
      @source_resolver = source_resolver
      @call_resolver = call_resolver
      @active_queries = Set.new
      @query_cache = {}
    end

    def self.type_name(classes)
      names = classes.map { |name| name == :NilClass ? 'nil' : name.to_s }
      names = ['bool'] + (names - %w[TrueClass FalseClass]) if names.include?('TrueClass') && names.include?('FalseClass')
      names.join(' | ')
    end

    # Classes that may reach this register read, or nil when any path is unknown.
    # Refusals retain the shared dataflow reason; unknown producers identify their opcode.
    def at(index, reg, max_states: DATAFLOW_MAX_STATES, refusal: nil)
      fact = query(index, reg, use_declarations: false, max_states: max_states, refusal: refusal)
      fact&.classes
    end

    # Declared classes are nominal bounds, conditional on the signature contract.
    # A declared fact cannot justify exact dispatch or unchecked native arithmetic.
    def fact_at(index, reg, max_states: DATAFLOW_MAX_STATES, refusal: nil)
      query(index, reg, use_declarations: true, max_states: max_states, refusal: refusal)
    end

    # A nominal iterator API uses the element bound without the absent-index nil added by [].
    def element_fact_at(index, reg, max_states: DATAFLOW_MAX_STATES)
      receiver = fact_at(index, reg, max_states: max_states)
      return nil unless receiver && receiver.classes == Set[:Array]

      definitions = BytecodeIR.reaching_definitions(@irep, index, reg, shared: true, origin_transfers: true, max_states: max_states)
      return nil unless definitions && !definitions.empty?

      elements = Set.new
      contracts = receiver.contracts.to_set
      definitions.each do |source|
        bound, contract = element_source_bound(source)
        return nil unless bound && !bound.empty?

        elements.merge(bound)
        contracts << contract if contract
      end
      Fact.new(classes: elements.freeze, declared: !contracts.empty?, contracts: contracts.to_a.sort.freeze).freeze
    end

    # The exact runtime class of a register read (+klass+, a Symbol) and, when every source is the same Integer
    # literal, its +value+.
    Exact = Struct.new(:klass, :value)

    EXACT_LITERAL_CLASSES = LITERAL_TYPES.except(:LAMBDA, :BLOCK).freeze
    # Ops that add to the container R(a) already holds, so its class stays (vm.c OP_ARYPUSH and the rest).
    # OP_ARYCAT stores a fresh Array over a nil R(a): requiring the result class rules that out.
    EXACT_EXTEND_OPS = { :ARYPUSH => :Array, :ARYCAT => :Array, :HASHADD => :Hash, :HASHCAT => :Hash,
                         :STRCAT => :String }.freeze

    # EXACT_LITERAL: the Exact class every definition reaching the read of +reg+ at +index+ agrees on,
    # from literal writers only, or nil. No argument, signature, inferred or resolver fact enters: those bound a
    # class nominally, and these callers drop their class test. Integers come from LOADI* alone (a pool integer
    # can overflow a 32-bit mrb_int). +self_class+ is the caller's own proof of R0 and LOADSELF.
    # +refusal+, when a Hash, receives `:cause`, the first reason the proof failed; the answer does not depend on it.
    def exact_at(index, reg, self_class: nil, max_states: DATAFLOW_MAX_STATES, refusal: nil)
      @exact_cache ||= {}
      key = [index, reg, self_class, max_states]
      if (cached = @exact_cache[key])
        unknown(refusal, cached[1]) if cached[1]
        return cached[0]
      end

      cause = {}
      result = compute_exact(index, reg, self_class, max_states, cause)
      @exact_cache[key] = [result, cause[:cause]].freeze if @exact_cache.size < QUERY_CACHE_CAP
      unknown(refusal, cause[:cause]) if cause[:cause]
      result
    end

    private

    def compute_exact(index, reg, self_class, max_states, refusal)
      classes = Set.new
      values = Set.new
      required = Set.new
      seen = Set.new
      work = [[index, reg]]
      until work.empty?
        at, register = work.pop
        next unless seen.add?([at, register])

        # Inside a protected range the handler edges are followed instead of refused (RECORD_HASH_PROOF's mode).
        first_refusal = {}
        definitions = [false, true].lazy.filter_map do |through|
          BytecodeIR.reaching_definitions(@irep, at, register, shared: true, origin_transfers: true, through_handlers: through,
                                                                max_states: max_states, refusal: through ? nil : first_refusal)
        end.first
        return unknown(refusal, first_refusal[:cause] || :unresolved) unless definitions
        return unknown(refusal, :no_definition) if definitions.empty?

        definitions.each do |definition|
          insn = definition.entry? ? nil : ir_program.source_at(definition.index)
          if insn && insn.reg == definition.reg && (container = EXACT_EXTEND_OPS[insn.op])
            required << container
            work << [definition.index, definition.reg]
            next
          end
          klass, value = exact_definition(definition, insn, self_class)
          return unknown(refusal, exact_refusal(definition, insn, self_class)) unless klass

          classes << klass
          values << value
        end
      end
      return unknown(refusal, :class_join) unless classes.size == 1
      return unknown(refusal, :container_mismatch) unless required.subset?(classes)

      klass = classes.first
      Exact.new(klass, klass == :Integer && values.size == 1 ? values.first : nil).freeze
    end

    def exact_definition(definition, insn, self_class)
      unless insn
        return [self_class] if definition.reg == 0

        return nil
      end
      return { rest: [:Array], local: [:NilClass] }[definition.built] if definition.built
      return nil unless insn.reg == definition.reg
      return [self_class] if insn.op == :LOADSELF

      value = integer_literal(insn)
      return [:Integer, value] unless value.nil?

      klass = EXACT_LITERAL_CLASSES[insn.op]
      klass && [klass]
    end

    # Why exact_definition gave no class for +definition+, for exact_at's refusal.
    def exact_refusal(definition, insn, self_class)
      return definition.reg == 0 && !self_class ? :self_unknown : :entry_value unless insn
      return "entry:#{definition.built}" if definition.built
      return :side_write unless insn.reg == definition.reg
      return :self_unknown if insn.op == :LOADSELF

      "producer:#{insn.op}"
    end

    def integer_literal(insn)
      case insn.op
      when :LOADI__1 then -1
      when BytecodeIR::Ops::LOADI_SLOT then insn.op.to_s.delete_prefix('LOADI_').to_i
      when :LOADI, :LOADI8, :LOADI16, :LOADI32, :LOADINEG
        value = insn.imm_operand&.to_i
        value && insn.op == :LOADINEG ? -value.abs : value
      end
    end

    def query(index, reg, use_declarations:, max_states:, refusal:)
      key = [index, reg, use_declarations, max_states]
      if (cached = @query_cache[key])
        unknown(refusal, cached[1]) if cached[1]
        return cached[0]
      end
      return unknown(refusal, :call_cycle) if @active_queries.include?(key)
      return unknown(refusal, :call_depth_cap) if @active_queries.size >= CALL_DEPTH_CAP
      @query_expansions = 0 if @active_queries.empty?
      @query_expansions += 1
      return unknown(refusal, :call_query_cap) if @query_expansions > CALL_QUERY_CAP

      @active_queries << key
      acquired = true
      cause = {}
      fact = compute_query(index, reg, use_declarations: use_declarations, max_states: max_states, refusal: cause)
      contextual_refusal = %i[call_cycle call_depth_cap call_query_cap].include?(cause[:cause])
      @query_cache[key] = [fact, cause[:cause]].freeze if !contextual_refusal && @query_cache.size < QUERY_CACHE_CAP
      unknown(refusal, cause[:cause]) if cause[:cause]
      fact
    ensure
      @active_queries.delete(key) if acquired
    end

    def compute_query(index, reg, use_declarations:, max_states:, refusal:)
      definitions = BytecodeIR.reaching_definitions(@irep, index, reg, shared: true, origin_transfers: true,
                                                    max_states: max_states, refusal: refusal)
      return nil unless definitions
      return unknown(refusal, :no_definition) if definitions.empty?

      source = definitions.any? do |definition|
        definition.entry? || definition.built == :arg ||
          (%i[GETIV GETCONST GETMCNST KARG GETUPVAR].include?(ir_program.source_at(definition.index).op) ||
           ENV['BC2CPP_IR_ELEMENT_TYPES'] != '0' && %i[GETIDX GETIDX0 AREF].include?(ir_program.source_at(definition.index).op))
      end
      if source && @source_resolver && (resolved = @source_resolver.call(index, reg))
        if resolved.is_a?(Fact)
          return resolved if !resolved.classes.empty? && (use_declarations || !resolved.declared?)
        elsif !resolved.empty?
          return Fact.new(classes: resolved.to_set.dup.freeze, declared: false, contracts: [].freeze).freeze
        end
      end

      types = Set.new
      contracts = Set.new
      definitions.each do |definition|
        argument = (definition.entry? || definition.built == :arg) ? @argument_facts[definition.reg] : nil
        values = if argument && (use_declarations || !argument.declared?)
                   contracts.merge(argument.contracts) if argument.declared?
                   argument.classes
                 else definition_types(definition)
                 end
        if !values && use_declarations
          values, contract = declared_definition(definition)
          contracts << contract.freeze if values
          if !values && !definition.entry?
            result = indexed_definition(definition, max_states: max_states, refusal: refusal)
            values = result&.classes
            contracts.merge(result.contracts) if result
          end
          if !values && @call_resolver && !definition.entry?
            insn = ir_program.source_at(definition.index)
            if %i[SEND SEND0].include?(insn.op) && insn.reg == definition.reg
              receiver = query(definition.index, insn.reg, use_declarations: true, max_states: max_states, refusal: refusal)
              result = receiver && @call_resolver.call(insn, receiver, refusal)
              values = result&.classes
              contracts.merge(result.contracts) if result
            end
          end
        end
        return unknown(refusal, definition.entry? ? :entry_value : "unknown:#{ir_program.source_at(definition.index).op}") unless values && !values.empty?

        types.merge(values)
      end
      Fact.new(classes: types.freeze, declared: !contracts.empty?, contracts: contracts.to_a.sort.freeze).freeze
    end

    # A keyword's value is its call-site join (an optional one's join already holds the default's class), unless the
    # signature declares that keyword: then nil, so declared_definition supplies the declared type.
    def keyword_definition_types(insn)
      name = insn.sym.to_s
      @declared_keywords.key?(name) ? nil : @inferred_keywords[name]
    end

    def declared_definition(definition)
      if definition.entry? || definition.built == :arg
        return [@declared_args[definition.reg] || @declared_optional_args[definition.reg], "argument:R#{definition.reg}"]
      end
      insn = ir_program.source_at(definition.index)
      return [nil, nil] unless insn.reg == definition.reg

      case insn.op
      when :KARG then [@declared_keywords[insn.sym.to_s], "keyword:#{insn.sym}"]
      when :GETIV then [@declared_ivars[insn.ivar], "ivar:@#{insn.ivar}"]
      when :SSEND, :SSEND0, :SSENDB then [@declared_calls[definition.index], "self-call:#{insn.sym}"]
      else [nil, nil]
      end
    end

    # LCF_ROW_FIELD: `row[:name]` on an LCF::Array1D reads the field the record's schema declares under that name, and
    # Array1D#[] raises for a name it does not declare, so the read is one of the classes every schema position
    # spelling the name can give (LcfSchemaOracle.by_name, receiver-independent). A key that is not a literal Symbol
    # has no such bound: it is reported as a non-literal key and stays untyped.
    def lcf_row_field(definition, insn, register, max_states:, refusal:)
      key_register = insn.op == :GETIDX0 ? nil : (insn.reg.to_i + 1)
      return nil unless key_register
      key_defs = BytecodeIR.reaching_definitions(@irep, definition.index, key_register, shared: true, origin_transfers: true,
                                                 max_states: max_states, refusal: refusal)
      syms = key_defs&.map { |source| source.entry? ? nil : ir_program.source_at(source.index) }
      unless syms && !syms.empty? && syms.all? { |producer| producer&.op == :LOADSYM }
        return unknown(refusal, :lcf_non_literal_key)
      end

      names = syms.map { |producer| producer.sym.to_s }.uniq
      return unknown(refusal, :lcf_non_literal_key) unless names.size == 1

      field = LcfSchemaOracle.field_classes.fetch(names.first) { return unknown(refusal, :lcf_unknown_field) }
      Fact.new(classes: field.map(&:to_sym).to_set.freeze, declared: false, contracts: [].freeze).freeze
    end

    # Container element bounds remain conditional on their RBS contract, including nil for absent keys.
    def indexed_definition(definition, max_states:, refusal:)
      return nil if ENV['BC2CPP_IR_ELEMENT_TYPES'] == '0'

      insn = ir_program.source_at(definition.index)
      return nil unless %i[GETIDX GETIDX0].include?(insn.op) && insn.reg == definition.reg

      register = insn.op == :GETIDX0 ? insn.regs[1] : insn.reg
      receiver = query(definition.index, register, use_declarations: true, max_states: max_states, refusal: refusal)
      return lcf_row_field(definition, insn, register, max_states: max_states, refusal: refusal) if
        receiver && receiver.classes == Set[:'LCF::Array1D']
      return nil unless receiver && receiver.classes.size == 1 && [:Array, :Hash].include?(receiver.classes.first)

      contracts = receiver.contracts.to_set
      if receiver.classes == Set[:Array] && insn.op != :GETIDX0
        key = query(definition.index, (insn.reg + 1), use_declarations: true, max_states: max_states, refusal: refusal)
        return nil unless key && key.classes == Set[:Integer]

        contracts.merge(key.contracts)
      end
      definitions = BytecodeIR.reaching_definitions(@irep, definition.index, register, shared: true, origin_transfers: true,
                                                    max_states: max_states, refusal: refusal)
      return nil unless definitions && !definitions.empty?

      elements = Set[:NilClass]
      definitions.each do |source|
        bound, contract = element_source_bound(source)
        return nil unless bound && !bound.empty?

        elements.merge(bound)
        contracts << contract.freeze if contract
      end
      Fact.new(classes: elements.freeze, declared: !contracts.empty?, contracts: contracts.to_a.sort.freeze).freeze
    end

    # The element bound one reaching definition of an array register gives, with its contract (nil when inferred).
    def element_source_bound(source)
      if source.entry? || source.built == :arg
        [@declared_arg_elements[source.reg], "element:argument:R#{source.reg}"]
      elsif source.built == :rest
        rest_element_bound(source.reg)
      else
        element_bound_of(ir_program.source_at(source.index))
      end
    end

    # The declared element bound of a receiver written by an ivar or constant read, with its provenance.
    def element_bound_of(producer)
      case producer.op
      when :GETIV then [@declared_ivar_elements[producer.ivar], "element:ivar:@#{producer.ivar}"]
      when :GETCONST then [@declared_const_elements[producer.const_name], "element:constant:#{producer.const_name}"]
      else [nil, nil]
      end
    end

    # The element bound of a rest parameter and its contract. The call-site join holds only while the body cannot
    # change the array (rest_array_private?); otherwise the signature's `*T` stands in. With both, the join wins, as
    # for a required parameter (definition_types before declared_definition).
    def rest_element_bound(reg)
      joined = @inferred_rest_elements[reg]
      return [joined, nil] if joined && rest_array_private?(reg)

      declared = @declared_rest_elements[reg]
      declared ? [declared, "element:argument:R#{reg}"] : [nil, nil]
    end

    # Ops that observe the frame's locals without naming the register: a closure captures them, ARGARY packs the
    # rest array for a zero-argument super, and binding/eval reach any local by name.
    REST_ARRAY_OBSERVERS = %i[LAMBDA BLOCK ARGARY].freeze

    # Every register holding the rest array (MOVE copies, flow-insensitive) may be read only as the receiver of an
    # element read (GETIDX, GETIDX0). Any other read can store a non-join element, so the join is withheld.
    def rest_array_private?(reg)
      @rest_private ||= {}
      @rest_private.fetch(reg) { @rest_private[reg] = compute_rest_array_private(reg) }
    end

    def compute_rest_array_private(reg)
      aliases = Set[reg.to_i]
      loop do
        grew = ir_program.each_source.any? do |insn, _index|
          insn.op == :MOVE && aliases.include?(insn.regs[1].to_i) && aliases.add?(insn.regs[0].to_i)
        end
        break unless grew
      end
      ir_program.each_source.none? { |insn, _index| rest_array_unsafe_use?(insn, aliases) }
    end

    def rest_array_unsafe_use?(insn, aliases)
      return true if REST_ARRAY_OBSERVERS.include?(insn.op)
      return true if BytecodeIR::Ops::SEND.include?(insn.op) && %w[binding eval].include?(insn.sym.to_s)

      reads = IrSymbolFlow.reads(@irep, insn).select { |reg| aliases.include?(reg) }
      return false if reads.empty?

      case insn.op
      when :MOVE then false
      when :GETIDX0 then reads != [insn.regs[1].to_i]
      when :GETIDX then reads != [insn.reg.to_i]
      else true
      end
    end

    def definition_types(definition)
      return @inferred_args[definition.reg] if definition.entry? || definition.built == :arg
      # A block join (Proc) replaces the nominal Proc-or-nil bound of the block slot.
      return @inferred_args[definition.reg] if definition.built == :block && @inferred_args.key?(definition.reg)
      return ENTER_TYPES[definition.built] if definition.built

      insn = ir_program.source_at(definition.index)
      return nil unless insn.reg == definition.reg
      return keyword_definition_types(insn) if insn.op == :KARG
      return [:TrueClass, :FalseClass] if insn.op == :KEY_P
      return @inferred_calls[definition.index] if BytecodeIR::Ops::SEND.include?(insn.op)

      type = Types.literal_class(insn, @irep.pool)
      type && [type]
    end

    # The class a literal-producing +insn+ leaves in its leading register (+pool+: the irep's literal pool, for LOADL),
    # or nil when the op is not a literal. Shared with NumericClasses' element proof.
    def self.literal_class(insn, pool)
      op = insn.op
      return :Integer if BytecodeIR::Ops::LOADI_OPS.include?(op)
      return LITERAL_TYPES[op] if LITERAL_TYPES.key?(op)
      return nil unless op == :LOADL

      pool_index = insn.pool_index
      entry = pool_index && pool && pool[pool_index]
      entry.is_a?(Hash) ? POOL_TYPES[entry[:type]] : nil
    end

    # The class an omitted optional keyword binds, or nil. The default code falls through to the join right after the
    # KARG at +karg_index+, so the definitions reaching that join are the KARG value and the default's writer. Only one
    # literal writer gives a class: a call, a local copy or a branch with several defaults is nil.
    def self.optional_keyword_default_class(irep, karg_index, reg)
      definitions = BytecodeIR.reaching_definitions(irep, karg_index + 1, reg, shared: true, origin_transfers: true,
                                                                              max_states: DATAFLOW_MAX_STATES)
      defaults = definitions&.reject { |definition| !definition.entry? && definition.index == karg_index }
      return nil unless defaults&.size == 1

      definition = defaults.first
      return nil if definition.entry? || definition.built

      insn = BytecodeIR.for(irep).source_at(definition.index)
      insn.reg == definition.reg ? literal_class(insn, irep.pool) : nil
    end

    def ir_program
      BytecodeIR.for(@irep)
    end

    def unknown(refusal, cause)
      refusal[:cause] ||= cause if refusal
      nil
    end
  end
end
