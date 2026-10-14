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

    def initialize(irep)
      @irep = irep
    end

    # Classes that may reach this register read, or nil when any path is unknown.
    # Refusals retain the shared dataflow reason; unknown producers identify their opcode.
    def at(index, reg, max_states: DATAFLOW_MAX_STATES, refusal: nil)
      definitions = BytecodeIR.reaching_definitions(@irep, index, reg, origin_transfers: true,
                                                    max_states: max_states, refusal: refusal)
      return nil unless definitions
      return unknown(refusal, :no_definition) if definitions.empty?

      types = Set.new
      definitions.each do |definition|
        values = definition_types(definition)
        return unknown(refusal, definition.entry? ? :entry_value : "unknown:#{@irep.instructions[definition.index].op}") unless values

        types.merge(values)
      end
      types.freeze
    end

    private

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
