# frozen_string_literal: true

require_relative 'bytecode_ir_types'

# Reporting consumes the settled family-wide pool, not individual store facts.
module IrIvarTypes
  module_function

  def classes(gen, owner, name)
    return nil if ENV['BC2CPP_IR_IVAR_TYPES'] == '0'
    return nil unless gen.instance_variable_get(:@class_pools_on) && gen.instance_variable_get(:@foreign_method_names) &&
                      gen.instance_variable_get(:@native_results_ready) && gen.instance_variable_get(:@rc_scoped_ready)
    return nil unless gen.instance_variable_get(:@closed_world)&.exact_instances_singleton_free?
    return nil if gen.instance_variable_get(:@numeric_ivar_disabled)
    return nil if owner.end_with?('.singleton') || owner.start_with?('<')

    key = [gen.numeric_family(owner), name.to_s]
    group = gen.instance_variable_get(:@numeric_ivar_groups)&.[](key)
    return nil unless group && !group.structural

    mask = gen.instance_variable_get(:@class_ivar_pools)&.[](key)
    return nil unless mask.is_a?(Integer)

    # Constructor assurance excludes nil only outside initialize; a declaration
    # also covers reads within initialize and its nested blocks.
    constructors_read = group.readers.any? do |label|
      definition = gen.numeric_irep_owner[label]
      irep = gen.instance_variable_get(:@ireps)&.[](label)
      definition&.name == 'initialize' && irep&.instructions&.any? { |insn| insn.op == 'GETIV' && insn.ivar.to_s == name.to_s }
    end
    mask |= NumericFlow::NIL if constructors_read || !gen.numeric_ivar_assured?(owner, name.to_s)
    gen.bytecode_ir_mask_classes(mask)
  end
end
