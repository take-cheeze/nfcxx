# frozen_string_literal: true

require_relative 'bytecode_ir'
require_relative 'rbs_signatures'

module IrTypeFeedback
  RETURN_OPS = %w[RETURN RETURN_BLK BREAK RETSELF RETNIL RETTRUE RETFALSE].freeze
  LITERAL_RETURNS = { 'RETNIL' => :NilClass, 'RETTRUE' => :TrueClass, 'RETFALSE' => :FalseClass }.freeze
  CORE_PARENTS = {
    Integer: :Numeric, Float: :Numeric, Numeric: :Object, String: :Object, Symbol: :Object,
    Array: :Object, Hash: :Object, Range: :Object, Proc: :Object, NilClass: :Object,
    TrueClass: :Object, FalseClass: :Object, Object: :BasicObject
  }.freeze

  CORE_MIXINS = { Array: [:Enumerable], Hash: [:Enumerable], Range: [:Enumerable],
                  Numeric: [:Comparable], String: [:Comparable], Object: [:Kernel] }.freeze

  module_function

  # A disjoint inferred may-set disproves a contract. An extra member alone may come from an infeasible path.
  def fits?(actual, expected, ctx)
    seen = Set.new
    work = [actual]
    until work.empty?
      current = work.pop
      next if seen.include?(current)
      return true if expected.include?(current)

      seen << current
      parent = (ctx.superclass_of || {})[current.to_s] || CORE_PARENTS[current]
      work << parent.to_sym if parent
      mixins = Array((ctx.included_modules || {})[current.to_s]) + Array((ctx.prepended_modules || {})[current.to_s])
      mixins += CORE_MIXINS.fetch(current, [])
      work.concat(mixins.map(&:to_sym))
    end
    concrete = CORE_PARENTS.keys.to_set | Set[:BasicObject]
    concrete.merge((ctx.superclass_of || {}).keys.reject { |name| ctx.modules&.include?(name) }.map(&:to_sym))
    # Missing module or external-type relations are unknown, not evidence of disjointness.
    expected.all? { |name| concrete.include?(name) } ? false : nil
  end

  def collect(ctx)
    rows = []
    returns = {}
    applied = ctx.signature_contracts
    ctx.registry.values.flatten.select(&:irep).uniq(&:irep).each do |definition|
      irep = ctx.ireps[definition.irep]
      next unless irep&.file

      inferred_calls = {}
      if ENV['BC2CPP_IR_CALL_RESULTS'] != '0' && ctx.gen.respond_to?(:bytecode_ir_call_result_classes)
        irep.instructions.each_with_index do |insn, index|
          next unless BytecodeIR::Types::CALL_OPS.include?(insn.op)

          classes = ctx.gen.bytecode_ir_call_result_classes(irep, index)
          inferred_calls[index] = classes if classes
        end
      end
      source_resolver = if ENV['BC2CPP_IR_SOURCE_TYPES'] != '0' && ctx.gen.respond_to?(:bytecode_ir_source_classes)
                          ->(index, reg) { ctx.gen.bytecode_ir_source_classes(irep, index, reg) }
                        end
      inferred_args = {}
      if ENV['BC2CPP_IR_ARGUMENT_TYPES'] != '0' && ctx.gen.respond_to?(:bytecode_ir_argument_classes)
        (1..irep.enter&.enter_fields&.first.to_i).each do |position|
          classes = ctx.gen.bytecode_ir_argument_classes(definition, position)
          classes ||= ctx.gen.bytecode_ir_call_graph_argument_classes(definition, position) if ctx.gen.respond_to?(:bytecode_ir_call_graph_argument_classes)
          inferred_args[position.to_s] = classes if classes
        end
      end
      analysis = if applied
                   RbsSignatures.ir_types(applied, irep, superclass_of: ctx.superclass_of || {}, included_modules: ctx.included_modules || {},
                                          prepended_modules: ctx.prepended_modules || {}, unknown_mixins: ctx.gen.instance_variable_get(:@unknown_mixins) || Set.new, inferred_args: inferred_args, inferred_calls: inferred_calls, source_resolver: source_resolver)
                 else BytecodeIR::Types.new(irep, inferred_args: inferred_args, inferred_calls: inferred_calls, source_resolver: source_resolver)
                 end
      owners = RbsSignatures.contract_owners(definition.owner, ctx.superclass_of || {},
                                            included_modules: ctx.included_modules || {}, prepended_modules: ctx.prepended_modules || {},
                                            unknown_mixins: ctx.gen.instance_variable_get(:@unknown_mixins) || Set.new)
      exits = []
      irep.instructions.each_with_index do |insn, index|
        kind = if RETURN_OPS.include?(insn.op) then 'return'
               elsif insn.op == 'SETIV' then 'ivar_store'
               elsif %w[SEND SEND0 SENDB].include?(insn.op) then 'receiver'
               end
        next unless kind

        refusal = {}
        fact = if LITERAL_RETURNS.key?(insn.op)
                 BytecodeIR::Types::Fact.new(classes: Set[LITERAL_RETURNS[insn.op]].freeze, declared: false, contracts: [].freeze).freeze
               elsif %w[RETURN_BLK BREAK RETSELF].include?(insn.op)
                 refusal[:cause] = "unsupported:#{insn.op}"
                 nil
               else
                 analysis.fact_at(index, kind == 'ivar_store' ? insn.reg_operand : insn.reg, refusal: refusal)
               end
        expected = if applied && kind == 'return'
                     applied.ir_return_types[irep.label]
                   elsif applied && kind == 'ivar_store' && applied.ir_owners[irep.label] == definition.owner
                     owners.filter_map { |owner| applied.ir_ivar_types[[owner, insn.ivar]] }.first
                   end
        comparisons = if fact && !fact.declared? && expected
                        fact.classes.map { |type| fits?(type, expected, ctx) }
                      else []
                      end
        outside = comparisons.any?(&:nil?) ? [] : comparisons.map { |fits| !fits }
        compatibility = comparisons.any?(&:nil?) ? 'unknown' : comparisons.empty? ? nil : 'checked'
        status = if !fact then 'unknown'
                 elsif !outside.empty? && outside.all? then 'mismatch'
                 elsif outside.any? then 'possible_mismatch'
                 elsif fact.declared? then 'declared'
                 else 'inferred'
                 end
        file = ctx.root ? irep.file.sub(%r{\A#{Regexp.escape(ctx.root.to_s)}/?}, '') : irep.file
        rows << { 'owner' => definition.owner, 'method' => definition.name, 'kind' => kind,
                  'detail' => kind == 'ivar_store' ? "@#{insn.ivar}" : kind == 'receiver' ? insn.sym.to_s : 'return',
                  'file' => file, 'line' => insn.lineno, 'col' => 1,
                  'scope' => file.match?(%r{(\A|/)3rd/}) ? 'core' : 'engine', 'status' => status,
                  'type' => fact && BytecodeIR::Types.type_name(fact.classes),
                  'expected' => expected && BytecodeIR::Types.type_name(expected),
                  'compatibility' => compatibility,
                  'contracts' => fact&.contracts || [], 'reason' => refusal[:cause]&.to_s }
        exits << fact if kind == 'return'
      end
      next if exits.empty? || exits.any?(&:nil?)

      classes = exits.reduce(Set.new) { |set, fact| set | fact.classes }.freeze
      contracts = exits.flat_map(&:contracts).uniq.sort.freeze
      returns[irep.label] = BytecodeIR::Types::Fact.new(classes: classes, declared: exits.any?(&:declared?), contracts: contracts).freeze
    end
    { rows: rows, returns: returns }
  end
end
