# frozen_string_literal: true

module IrNativeExpressionTypes
  WRAPPERS = { 'mrb_bool_value' => [:TrueClass, :FalseClass], 'mrb_true_value' => [:TrueClass],
               'mrb_false_value' => [:FalseClass], 'mrb_nil_value' => [:NilClass],
               'mrb_fixnum_value' => [:Integer], 'mrb_int_value' => [:Integer], 'mrb_float_value' => [:Float] }.freeze

  module_function

  # The audited expression must be this whole constructor, not a ternary starting with one.
  def classes(expression, receiver)
    return nil unless expression.is_a?(String)
    return [receiver.to_sym] if expression == 'recv'

    name = expression[/\A(\w+)\(/, 1]
    return nil unless WRAPPERS.key?(name)

    depth = 0
    quote = nil
    escaped = false
    expression.each_char.with_index do |char, index|
      if quote
        if escaped then escaped = false
        elsif char == '\\' then escaped = true
        elsif char == quote then quote = nil
        end
      elsif ['"', "'"].include?(char) then quote = char
      elsif char == '(' then depth += 1
      elsif char == ')'
        depth -= 1
        return nil if depth.negative? || depth.zero? && index != expression.length - 1
      end
    end
    depth.zero? && quote.nil? ? WRAPPERS[name] : nil
  end
end

class CodeGen
  def bytecode_ir_native_expression_inventory
    (@native_registered_expressions || {}).flat_map do |name, entries|
      entries.map do |entry|
        owner = entry[:owner][:class_name]
        classes = bytecode_ir_native_expression_classes(name, owner, entry[:arity])
        kind = native_result_kind(name, owner) unless classes
        classes ||= bytecode_ir_mask_classes(native_result_bits(kind, true)) if kind
        { 'owner' => owner, 'method' => name, 'arity' => entry[:arity],
          'type' => classes && BytecodeIR::Types.type_name(classes),
          'reason' => classes ? nil : 'unmodelled-result-or-unproven-identity' }
      end
    end.sort_by { |row| [row['owner'], row['method'], row['arity']] }
  end

  # Reuse the direct-expression registration and replacement audit, without seeding optimizer tables.
  def bytecode_ir_native_expression_classes(name, receiver, argc)
    return nil if ENV['BC2CPP_IR_NATIVE_EXPRESSION_TYPES'] == '0'
    return nil unless @closed_world&.exact_instances_singleton_free? && @native_results_ready
    return nil unless @closed_world.native_class_constant_stable?(receiver)
    return nil if devirt_blocked_name?(name)
    installed = symbol_installed_names
    return nil unless installed && !installed.include?(name)

    entries = Array(@native_registered_expressions&.[](name)).select { |entry| entry[:owner][:class_name] == receiver && entry[:arity] == argc }
    return nil unless entries.one? && builtin_class_send_safe?(name, [receiver])

    classes = IrNativeExpressionTypes.classes(entries.first[:expression], receiver)
    classes&.to_set&.freeze
  end
end
