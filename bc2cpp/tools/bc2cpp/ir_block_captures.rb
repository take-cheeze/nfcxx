# frozen_string_literal: true

require_relative 'bytecode_ir'

# Capture facts apply only during a proven synchronous, nonescaping invocation.
class IrBlockCaptures
  PURE_OPS = %w[ENTER MOVE LOADSELF LOADNIL LOADTRUE LOADFALSE LOADSYM SYMBOL STRING
                LOADI LOADI16 LOADI32 LOADINEG LOADL GETUPVAR JMP JMPIF JMPNOT JMPNIL
                RETURN RETSELF RETNIL RETTRUE RETFALSE NOP].freeze

  def initialize(parent:, child:, call_index:, producer_index:, parent_analysis:, ireps:, invocation_safe: false)
    @parent = parent
    @child = child
    @call_index = call_index
    @analysis = parent_analysis
    @safe = invocation_safe && ENV['BC2CPP_IR_BLOCK_CAPTURES'] != '0' &&
            safe_invocation?(producer_index, ireps)
  end

  # Every reaching producer must identify a stable slot in the immediate parent.
  def fact_at(index, reg)
    return nil unless @safe

    definitions = BytecodeIR.reaching_definitions(@child, index, reg.to_s, origin_transfers: true)
    return nil unless definitions && !definitions.empty?

    facts = definitions.map do |definition|
      return nil if definition.entry?

      instruction = @child.instructions[definition.index]
      return nil unless instruction.op == 'GETUPVAR'

      slot, level = instruction.upvar_ref
      return nil unless level == 0 && slot.to_i.positive? && slot.to_i < @parent.nlocals.to_i
      return nil if BytecodeIR.own_upvar_written_regs(@parent).include?(slot.to_s)

      fact = @analysis.fact_at(@call_index, slot.to_s)
      return nil unless fact && !fact.classes.empty?

      fact
    end
    BytecodeIR::Types::Fact.new(classes: facts.reduce(Set.new) { |set, fact| set | fact.classes }.freeze,
                                declared: facts.any?(&:declared?),
                                contracts: facts.flat_map(&:contracts).uniq.sort.freeze).freeze
  end

  private

  def safe_invocation?(producer_index, ireps)
    return false unless @call_index.is_a?(Integer) && producer_index.is_a?(Integer) && producer_index < @call_index
    return false unless Array(@parent.catch_handlers).empty? && Array(@child.catch_handlers).empty? && Array(@child.reps).empty?
    return false unless BytecodeIR.for(@parent).resolved? && BytecodeIR.for(@child).resolved?
    return false unless BytecodeIR.for(@child).instructions.all? { |instruction| PURE_OPS.include?(instruction.op) || instruction.op.match?(/\ALOADI_[0-7]\z/) }

    call = @parent.instructions[@call_index]
    producer = @parent.instructions[producer_index]
    return false unless call && %w[SENDB SSENDB].include?(call.op) && call.plain_fixed_argc?
    return false unless producer&.op == 'BLOCK' && ireps[Array(@parent.reps)[producer.block_index.to_i]].equal?(@child)

    block_reg = (call.reg.to_i + call.argc + 1).to_s
    definitions = BytecodeIR.reaching_definitions(@parent, @call_index, block_reg, origin_transfers: true)
    return false unless definitions&.size == 1 && definitions.first.index == producer_index

    # Straight-line transport prevents another invocation or escape before this call.
    corridor = @parent.instructions[(producer_index + 1)...@call_index]
    corridor.all? { |instruction| %w[MOVE LOADNIL LOADTRUE LOADFALSE LOADSYM LOADI LOADI16 LOADI32 LOADINEG LOADL STRING].include?(instruction.op) || instruction.op.match?(/\ALOADI_[0-7]\z/) }
  end
end
