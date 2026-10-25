# frozen_string_literal: true

require_relative 'bytecode_ir'

# Only complete caller joins become seeds: unresolved recursive components stay unknown.
module IrCallGraphTypes
  MAX_ROUNDS = 16
  MAX_NODES = 8192

  module_function

  def collect(gen, definitions, ireps, max_rounds: MAX_ROUNDS)
    bodies = definitions.select(&:irep).uniq { |definition| [definition.owner, definition.name, definition.irep] }.group_by(&:irep)
    nodes = bodies.flat_map do |label, owners|
      next [] unless owners.one?

      body = ireps[label]
      next [] unless body && gen.send(:pure_mandatory_arity?, body)

      (1..gen.send(:mandatory_arity, body)).map { |position| [owners.first, position] }
    end
    return {}.freeze if nodes.size > MAX_NODES

    facts = {}
    nodes.each do |definition, position|
      classes = gen.bytecode_ir_argument_classes(definition, position)
      # ENTRY_SEEDS: an entry point with no by-name caller is complete on its own (see ir_entry_seeds.rb).
      classes ||= gen.bytecode_ir_entry_seed_classes(definition, position) if gen.respond_to?(:bytecode_ir_entry_seed_classes)
      (facts[definition.irep] ||= {})[position] = classes if classes
    end
    max_rounds.times do
      analyses = {}
      added = {}
      read = lambda do |body, index, register|
        direct = gen.bytecode_ir_source_classes(body, index, register)
        next direct if direct

        analyses[body.label] ||= begin
          calls = BytecodeIR.for(body).each_source.filter_map do |insn, call_index|
            next unless BytecodeIR::Ops::SEND.include?(insn.op)

            classes = gen.bytecode_ir_call_result_classes(body, call_index)
            [call_index, classes] if classes
          end.to_h
          BytecodeIR::Types.new(body, inferred_args: facts.fetch(body.label, {}), inferred_calls: calls)
        end
        analyses[body.label].at(index, register)
      end
      nodes.each do |definition, position|
        next if facts.dig(definition.irep, position)

        classes = gen.bytecode_ir_argument_classes(definition, position, read: read)
        (added[definition.irep] ||= {})[position] = classes if classes
      end
      break if added.empty?

      added.each { |label, arguments| (facts[label] ||= {}).merge!(arguments) }
    end
    facts.transform_values { |arguments| arguments.freeze }.freeze
  end
end
