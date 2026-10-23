# frozen_string_literal: true

require_relative 'bytecode_ir_ops'
require_relative 'bytecode_ir'
require_relative 'rbs_signatures'
require_relative 'ir_yield_types'
require_relative 'ir_block_captures'
require_relative 'ir_rbs_block_types'
require_relative 'core_hierarchy_sigs'

module IrTypeFeedback
  # Not Ops::FRAME_EXIT: that set also holds STOP, which these block and method return kinds leave out.
  RETURN_OPS = %w[RETURN RETURN_BLK BREAK RETSELF RETNIL RETTRUE RETFALSE].freeze
  LITERAL_RETURNS = { 'RETNIL' => :NilClass, 'RETTRUE' => :TrueClass, 'RETFALSE' => :FalseClass }.freeze
  # Core superclasses and mixins, read from sig/bc2cpp/declarations.rbs#core_hierarchy (fails if that section is empty).
  CORE_PARENTS, CORE_MIXINS = CoreHierarchySigs.symbol_hierarchy

  module_function

  def callback_binding(ctx, definition, parent, index, analysis, prepared: nil)
    return nil if ENV['BC2CPP_IR_RBS_BLOCK_TYPES'] == '0' || !ctx.signature_contracts

    insn = parent.instructions[index]
    receiver = insn.op == 'SSENDB' ? Set[definition.owner.to_sym] : analysis.fact_at(index, insn.reg)&.classes
    return nil unless receiver&.size == 1

    applied = ctx.signature_contracts
    owners = prepared ? prepared.owners(receiver.first.to_s) : RbsSignatures.contract_owners(receiver.first.to_s, ctx.superclass_of || {},
                                          included_modules: ctx.included_modules || {}, prepended_modules: ctx.prepended_modules || {},
                                          unknown_mixins: ctx.gen.instance_variable_get(:@unknown_mixins) || Set.new)
    target = prepared ? prepared.target(receiver.first.to_s, insn.sym.to_s) : owners.find { |owner| applied.ir_methods.include?([owner, insn.sym.to_s]) }
    signature = target && IrRbsBlockTypes.signature_for(applied, target, insn.sym)
    return nil unless signature

    arguments = (1..insn.argc).map { |slot| analysis.fact_at(index, (insn.reg.to_i + slot).to_s) }
    elements = (1..insn.argc).map { |slot| analysis.element_fact_at(index, (insn.reg.to_i + slot).to_s) }
    IrRbsBlockTypes.bind(signature, arguments: arguments, argument_elements: elements)
  end

  # Protocol contracts never seed exact dispatch or enclosing returns.
  def iterator_block_rows(ctx, definition, parent, index, analysis, prepared: nil)
    return [] if ENV['BC2CPP_IR_BLOCK_TYPES'] == '0'

    insn = parent.instructions[index]
    return [] unless %w[SENDB SSENDB].include?(insn.op) && insn.plain_fixed_argc?

    definitions = BytecodeIR.reaching_definitions(parent, index, (insn.reg.to_i + insn.argc + 1).to_s, origin_transfers: true)
    return [] unless definitions&.size == 1 && !definitions.first.entry?

    producer = parent.instructions[definitions.first.index]
    child = ctx.ireps[Array(parent.reps)[producer.block_index.to_i]] if producer.op == 'BLOCK'
    fields = child&.enter&.enter_fields
    return [] unless child&.file && fields && fields.drop(1).all?(&:zero?) && fields.first.between?(0, 8)

    iterator = insn.op == 'SENDB' && insn.argc.zero? && %w[each map collect each_with_index].include?(insn.sym)
    elements = analysis.element_fact_at(index, insn.reg) if iterator
    binding = callback_binding(ctx, definition, parent, index, analysis, prepared: prepared)
    summary = IrYieldTypes.summarize(ctx, parent, index, analysis)
    if summary && summary.child.equal?(child)
      bounds = summary.arguments
      contracts = bounds.values.flat_map(&:contracts).uniq.sort.freeze
      invocation_safe = summary.invocation_safe
    elsif binding && binding.argument_facts.size == fields.first
      bounds = binding.argument_facts.each_with_index.to_h { |fact, slot| [(slot + 1).to_s, fact] }
      contracts = binding.contracts
      invocation_safe = false
    elsif elements && fields.first == (insn.sym == 'each_with_index' ? 2 : 1)
      contracts = (elements.contracts + ["iterator:#{insn.sym}"]).sort.freeze
      bounds = { '1' => BytecodeIR::Types::Fact.new(classes: elements.classes, declared: true, contracts: contracts) }
      bounds['2'] = BytecodeIR::Types::Fact.new(classes: Set[:Integer], declared: true, contracts: contracts) if fields.first == 2
      invocation_safe = false
    else
      return []
    end
    file = ctx.root ? child.file.sub(%r{\A#{Regexp.escape(ctx.root.to_s)}/?}, '') : child.file
    base = { 'owner' => definition.owner, 'method' => definition.name, 'file' => file, 'col' => 1,
             'scope' => file.match?(%r{(\A|/)3rd/}) ? 'core' : 'engine', 'expected' => nil, 'compatibility' => nil }
    rows = bounds.map do |reg, fact|
      base.merge('kind' => 'block_argument', 'detail' => Array(child.lv)[reg.to_i - 1].to_s,
                 'line' => child.enter.lineno, 'status' => fact.declared? ? 'declared' : 'inferred',
                 'type' => BytecodeIR::Types.type_name(fact.classes), 'contracts' => fact.contracts, 'reason' => nil)
    end
    callback_inputs_fit = true
    if binding && summary
      callback_inputs_fit = binding.argument_facts.size == bounds.size
      bounds.each do |reg, fact|
        expected = binding.argument_facts[reg.to_i - 1]
        next unless expected

        comparisons = fact.classes.map { |value| fits?(value, expected.classes, ctx) }
        callback_inputs_fit &&= comparisons.all?(true)
        next if fact.declared?

        row = rows[reg.to_i - 1]
        row['expected'] = BytecodeIR::Types.type_name(expected.classes)
        row['compatibility'] = comparisons.any?(&:nil?) ? 'unknown' : 'checked'
        row['status'] = 'unknown' if comparisons.any?(&:nil?)
        row['status'] = 'mismatch' if comparisons.all?(false)
        row['status'] = 'possible_mismatch' if comparisons.include?(false) && comparisons.include?(true)
      end
    end
    captures = IrBlockCaptures.new(parent: parent, child: child, call_index: index, producer_index: definitions.first.index,
                                  parent_analysis: analysis, ireps: ctx.ireps, invocation_safe: invocation_safe)
    block_analysis = BytecodeIR::Types.new(child, argument_facts: bounds, source_resolver: captures.method(:fact_at))
    exits = []
    child.instructions.each_with_index do |instruction, position|
      kind = if RETURN_OPS.include?(instruction.op) then 'block_return'
             elsif instruction.op == 'SETIV' then 'block_ivar_store'
             elsif %w[SEND SEND0 SENDB].include?(instruction.op) then 'block_receiver'
             end
      next unless kind

      refusal = {}
      fact = if LITERAL_RETURNS.key?(instruction.op)
               BytecodeIR::Types::Fact.new(classes: Set[LITERAL_RETURNS[instruction.op]], declared: false, contracts: [])
             elsif %w[RETURN_BLK BREAK RETSELF].include?(instruction.op) || !Array(child.catch_handlers).empty?
               refusal[:cause] = "unsupported:block-exit-or-handler"
               nil
             else
               block_analysis.fact_at(position, kind == 'block_ivar_store' ? instruction.reg_operand : instruction.reg, refusal: refusal)
             end
      rows << base.merge('kind' => kind, 'detail' => kind == 'block_ivar_store' ? "@#{instruction.ivar}" : kind == 'block_receiver' ? instruction.sym.to_s : 'return',
                         'line' => instruction.lineno, 'status' => !fact ? 'unknown' : fact.declared? ? 'declared' : 'inferred',
                         'type' => fact && BytecodeIR::Types.type_name(fact.classes),
                         'contracts' => fact&.declared? ? (fact.contracts + contracts).uniq.sort : [], 'reason' => refusal[:cause]&.to_s)
      exits << fact if kind == 'block_return'
    end
    if !exits.empty? && exits.none?(&:nil?) && Array(child.catch_handlers).empty? &&
       child.instructions.none? { |instruction| %w[RETURN_BLK BREAK].include?(instruction.op) }
      returned = BytecodeIR::Types::Fact.new(classes: exits.reduce(Set.new) { |set, fact| set | fact.classes },
                                          declared: exits.any?(&:declared?), contracts: exits.flat_map(&:contracts).uniq.sort)
      if binding && callback_inputs_fit
        result = binding.complete(returned, compatible: ->(actual, expected) {
          comparisons = actual.map { |value| fits?(value, expected, ctx) }
          comparisons.any?(&:nil?) ? nil : comparisons.all?
        })
        if result.return_fact
          type = BytecodeIR::Types.type_name(result.return_fact.classes)
          type = "Array[#{BytecodeIR::Types.type_name(result.return_elements.classes)}]" if result.return_fact.classes == Set[:Array] && result.return_elements
          rows << base.merge('kind' => 'callback_result', 'detail' => insn.sym, 'line' => insn.lineno,
                             'status' => 'declared', 'type' => type, 'contracts' => result.return_fact.contracts, 'reason' => nil)
        end
        if result.callback_expected && !returned.declared?
          comparisons = returned.classes.map { |value| fits?(value, result.callback_expected.classes, ctx) }
          status = comparisons.any?(&:nil?) ? 'unknown' : comparisons.all?(false) ? 'mismatch' : comparisons.include?(false) ? 'possible_mismatch' : 'inferred'
          rows << base.merge('kind' => 'block_contract', 'detail' => insn.sym, 'line' => insn.lineno,
                             'status' => status, 'type' => BytecodeIR::Types.type_name(returned.classes),
                             'expected' => BytecodeIR::Types.type_name(result.callback_expected.classes),
                             'compatibility' => comparisons.any?(&:nil?) ? 'unknown' : 'checked', 'contracts' => binding.contracts, 'reason' => nil)
        end
      elsif !binding && elements
        values = %w[map collect].include?(insn.sym) ? returned.classes : elements.classes
        rows << base.merge('kind' => 'iterator_result', 'detail' => insn.sym, 'line' => insn.lineno,
                           'status' => 'declared', 'type' => "Array[#{BytecodeIR::Types.type_name(values)}]",
                           'contracts' => (contracts + returned.contracts).uniq.sort, 'reason' => nil)
      end
    end
    rows
  end

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
    prepared = if applied && ENV['BC2CPP_IR_PREPARED_CONTRACTS'] != '0'
                 RbsSignatures::IrContracts.new(applied, superclass_of: ctx.superclass_of || {},
                                               included_modules: ctx.included_modules || {}, prepended_modules: ctx.prepended_modules || {},
                                               unknown_mixins: ctx.gen.instance_variable_get(:@unknown_mixins) || Set.new)
               end
    ctx.registry.values.flatten.select(&:irep).uniq(&:irep).each do |definition|
      irep = ctx.ireps[definition.irep]
      next unless irep&.file

      inferred_calls = {}
      if ENV['BC2CPP_IR_CALL_RESULTS'] != '0' && ctx.gen.respond_to?(:bytecode_ir_call_result_classes)
        irep.instructions.each_with_index do |insn, index|
          next unless BytecodeIR::Ops::SEND.include?(insn.op)

          classes = ctx.gen.bytecode_ir_call_result_classes(irep, index)
          contextual = ctx.gen.bytecode_ir_context_results&.call_classes(irep, index) if ctx.gen.respond_to?(:bytecode_ir_context_results)
          classes = contextual if contextual && (!classes || contextual.subset?(classes))
          inferred_calls[index] = classes if classes
        end
      end
      source_resolver = if ENV['BC2CPP_IR_SOURCE_TYPES'] != '0' && ctx.gen.respond_to?(:bytecode_ir_source_classes)
                          ->(index, reg) {
                            classes = ctx.gen.bytecode_ir_source_classes(irep, index, reg)
                            contextual = ctx.gen.bytecode_ir_context_results&.source_classes(irep, index, reg) if ctx.gen.respond_to?(:bytecode_ir_context_results)
                            classes = contextual if contextual && (!classes || contextual.subset?(classes))
                            classes
                          }
                        end
      inferred_args = {}
      if ENV['BC2CPP_IR_ARGUMENT_TYPES'] != '0' && ctx.gen.respond_to?(:bytecode_ir_argument_classes)
        enter = irep.enter&.enter_fields
        mandatory = enter ? enter[0].to_i : 0
        (1..mandatory).each do |position|
          classes = ctx.gen.bytecode_ir_argument_classes(definition, position)
          classes ||= ctx.gen.bytecode_ir_call_graph_argument_classes(definition, position) if ctx.gen.respond_to?(:bytecode_ir_call_graph_argument_classes)
          inferred_args[position.to_s] = classes if classes
        end
        # Optional registers: only a complete call-site join, where every reaching call passed the argument.
        if ctx.gen.respond_to?(:bytecode_ir_optional_argument_classes)
          ((mandatory + 1)..(mandatory + (enter ? enter[1].to_i : 0))).each do |position|
            classes = ctx.gen.bytecode_ir_optional_argument_classes(definition, position)
            inferred_args[position.to_s] = classes if classes
          end
        end
      end
      analysis = if applied
                   RbsSignatures.ir_types(applied, irep, prepared: prepared, superclass_of: ctx.superclass_of || {}, included_modules: ctx.included_modules || {},
                                          prepended_modules: ctx.prepended_modules || {}, unknown_mixins: ctx.gen.instance_variable_get(:@unknown_mixins) || Set.new, inferred_args: inferred_args, inferred_calls: inferred_calls, source_resolver: source_resolver)
                 else BytecodeIR::Types.new(irep, inferred_args: inferred_args, inferred_calls: inferred_calls, source_resolver: source_resolver)
                 end
      owners = prepared ? prepared.owners(definition.owner) : RbsSignatures.contract_owners(definition.owner, ctx.superclass_of || {},
                                            included_modules: ctx.included_modules || {}, prepended_modules: ctx.prepended_modules || {},
                                            unknown_mixins: ctx.gen.instance_variable_get(:@unknown_mixins) || Set.new)
      exits = []
      irep.instructions.each_with_index do |insn, index|
        kind = if RETURN_OPS.include?(insn.op) then 'return'
               elsif insn.op == 'SETIV' then 'ivar_store'
               elsif %w[SEND SEND0 SENDB].include?(insn.op) then 'receiver'
               end
        rows.concat(iterator_block_rows(ctx, definition, irep, index, analysis, prepared: prepared)) if %w[SENDB SSENDB].include?(insn.op)
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
