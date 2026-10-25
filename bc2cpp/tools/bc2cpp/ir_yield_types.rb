# frozen_string_literal: true

require_relative 'bytecode_ir'
require_relative 'bytecode_ir_containers'

# This is a caller-local protocol, not a global block or exact-dispatch proof.
module IrYieldTypes
  MAX_INSTRUCTIONS = 256
  MAX_RECEIVERS = 8
  PURE_OPS = %i[ENTER MOVE LOADNIL LOADTRUE LOADFALSE LOADSYM STRING LOADL LOADI LOADINEG
                LOADI16 LOADI32 JMP JMPIF JMPNOT JMPNIL BLKPUSH BLKCALL RETURN RETNIL
                RETTRUE RETFALSE NOP].freeze
  Summary = Struct.new(:child, :arguments, :targets, :invocation_safe, keyword_init: true)

  module_function

  def summarize(ctx, parent, index, analysis)
    return nil if ENV['BC2CPP_IR_YIELD_TYPES'] == '0'

    call = BytecodeIR.for(parent).source_at(index)
    return nil unless BytecodeIR::Ops::BLOCK_SEND.include?(call.op) && call.plain_fixed_argc?

    argc = call.argc
    child = literal_block(ctx.ireps, parent, index, call.reg.to_i + argc + 1)
    fields = child&.enter&.enter_fields
    return nil unless fields && fields.drop(1).all?(&:zero?) && Array(child.catch_handlers).empty?

    count = fields.first
    return nil unless count.between?(0, 8)

    receivers = ctx.gen.bytecode_ir_argument_receiver_classes(parent, index, call.reg)
    return nil unless receivers && receivers.size.between?(1, MAX_RECEIVERS)

    actuals = (1..argc).map { |position| analysis.fact_at(index, (call.reg.to_i + position).to_s) }
    return nil if actuals.any?(&:nil?)

    joined = Array.new(count) { [] }
    targets = []
    receivers.each do |receiver|
      target = ctx.gen.send(:closed_world_exact_target, call.sym, receiver.to_s)
      body = target&.irep && ctx.ireps[target.irep]
      return nil unless protocol_body?(body, argc)

      targets << "yield:#{target.owner}##{target.name}"
      callee = BytecodeIR::Types.new(body, argument_facts: actuals.each_with_index.to_h { |fact, slot| [(slot + 1).to_s, fact] })
      yields = []
      body.each_with_op(:BLKCALL) { |insn, position| yields << [insn, position] }
      return nil if yields.empty?

      yields.each do |instruction, position|
        # No argument packing, arity coercion, escaped Proc, or outer lexical yield.
        return nil unless instruction.first_of(:int)&.value == count
        definitions = BytecodeIR.reaching_definitions(body, position, instruction.reg, origin_transfers: true, shared: true)
        producer = definitions&.size == 1 && !definitions.first.entry? && BytecodeIR.for(body).source_at(definitions.first.index)
        return nil unless producer && producer.op == :BLKPUSH && producer.argary_spec == [argc, 0, 0, 0] && producer.first_of(:plit)&.value.to_s == '0'

        count.times do |slot|
          fact = callee.fact_at(position, (instruction.reg.to_i + slot + 1).to_s)
          return nil unless fact

          joined[slot] << fact
        end
      end
    end
    arguments = joined.each_with_index.to_h do |facts, slot|
      classes = facts.reduce(Set.new) { |set, fact| set | fact.classes }.freeze
      # Callee facts are independent, but actual arguments can be contract bounds.
      declared = facts.any?(&:declared?)
      contracts = declared ? facts.flat_map(&:contracts).uniq.sort.freeze : [].freeze
      [(slot + 1).to_s, BytecodeIR::Types::Fact.new(classes: classes, declared: declared, contracts: contracts).freeze]
    end.freeze
    Summary.new(child: child, arguments: arguments, targets: targets.uniq.sort.freeze, invocation_safe: true).freeze
  end

  def literal_block(ireps, parent, index, register)
    definitions = BytecodeIR.reaching_definitions(parent, index, register.to_s, origin_transfers: true, shared: true)
    return nil unless definitions&.size == 1 && !definitions.first.entry?

    producer = BytecodeIR.for(parent).source_at(definitions.first.index)
    producer.op == :BLOCK ? ireps[Array(parent.reps)[producer.block_index.to_i]] : nil
  end

  def protocol_body?(body, argc)
    return false unless body && Array(body.reps).empty? && Array(body.catch_handlers).empty?
    return false unless body.enter&.enter_fields == [argc, 0, 0, 0, 0, 0, 0, 0]
    return false unless BytecodeIR.for(body).size <= MAX_INSTRUCTIONS

    BytecodeIR.for(body).each_source.all? { |insn, _index| PURE_OPS.include?(insn.op) || BytecodeIR::Ops::LOADI_SLOT.include?(insn.op) }
  end
end
