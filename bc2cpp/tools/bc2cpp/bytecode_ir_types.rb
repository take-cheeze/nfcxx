# frozen_string_literal: true

module BytecodeIR
  # Value classes, not representation/width proofs. See ADR 0440.
  class Types
    LITERAL_TYPES = {
      'LOADNIL' => :NilClass, 'LOADTRUE' => :TrueClass, 'LOADFALSE' => :FalseClass,
      'LOADSYM' => :Symbol, 'SYMBOL' => :Symbol, 'STRING' => :String,
      'ARRAY' => :Array, 'ARRAY2' => :Array, 'HASH' => :Hash,
      'RANGE_INC' => :Range, 'RANGE_EXC' => :Range, 'LAMBDA' => :Proc, 'BLOCK' => :Proc
    }.freeze
    POOL_TYPES = { int32: :Integer, int64: :Integer, bigint: :Integer, float: :Float }.freeze
    ENTER_TYPES = { rest: [:Array], hash: [:Hash], block: [:Proc, :NilClass], local: [:NilClass] }.transform_values(&:freeze).freeze

    Fact = Struct.new(:classes, :declared, :contracts, keyword_init: true) do
      def declared? = declared
    end

    def initialize(irep, declared_args: {}, declared_ivars: {}, declared_calls: {})
      @irep = irep
      required = irep.enter&.enter_fields&.first.to_i
      @declared_args = declared_args.to_h do |reg, types|
        number = reg.to_s
        unless number.match?(/\A[1-9]\d*\z/) && number.to_i <= required
          raise ArgumentError, "bc2cpp: IR argument contract R#{number} is not a required parameter"
        end
        [number.dup.freeze, types.to_set.dup.freeze]
      end.freeze
      @declared_ivars = declared_ivars.to_h { |name, types| [name.to_s.delete_prefix('@').freeze, types.to_set.dup.freeze] }.freeze
      @declared_calls = declared_calls.to_h { |index, types| [index, types.to_set.dup.freeze] }.freeze
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

    private

    def query(index, reg, use_declarations:, max_states:, refusal:)
      definitions = BytecodeIR.reaching_definitions(@irep, index, reg, origin_transfers: true,
                                                    max_states: max_states, refusal: refusal)
      return nil unless definitions
      return unknown(refusal, :no_definition) if definitions.empty?

      types = Set.new
      contracts = Set.new
      definitions.each do |definition|
        values = definition_types(definition)
        if !values && use_declarations
          values, contract = declared_definition(definition)
          contracts << contract.freeze if values
        end
        return unknown(refusal, definition.entry? ? :entry_value : "unknown:#{@irep.instructions[definition.index].op}") unless values && !values.empty?

        types.merge(values)
      end
      Fact.new(classes: types.freeze, declared: !contracts.empty?, contracts: contracts.to_a.sort.freeze).freeze
    end

    def declared_definition(definition)
      if definition.entry? || definition.built == :arg
        return [@declared_args[definition.reg], "argument:R#{definition.reg}"]
      end
      insn = @irep.instructions[definition.index]
      return [nil, nil] unless insn.reg == definition.reg

      case insn.op
      when 'GETIV' then [@declared_ivars[insn.ivar], "ivar:@#{insn.ivar}"]
      when 'SSEND', 'SSEND0', 'SSENDB' then [@declared_calls[definition.index], "self-call:#{insn.sym}"]
      else [nil, nil]
      end
    end

    def definition_types(definition)
      return nil if definition.entry?
      return ENTER_TYPES[definition.built] if definition.built

      insn = @irep.instructions[definition.index]
      return nil unless insn.reg == definition.reg
      return [:Integer] if insn.op.match?(/\ALOADI(?:8|16|32|NEG|__1|_[0-7])\z/)
      return [LITERAL_TYPES[insn.op]] if LITERAL_TYPES.key?(insn.op)
      return nil unless insn.op == 'LOADL'

      pool_index = insn.pool_index
      entry = pool_index && @irep.pool && @irep.pool[pool_index]
      type = entry.is_a?(Hash) && POOL_TYPES[entry[:type]]
      type && [type]
    end

    def unknown(refusal, cause)
      refusal[:cause] ||= cause if refusal
      nil
    end
  end
end
