# frozen_string_literal: true

require_relative 'rbs_signatures'
require_relative 'bytecode_ir'

# Conditional callback bounds retain their RBS provenance and never become optimizer seeds.
module IrRbsBlockTypes
  MAX_VARIABLES = 16
  DISJOINT_CORE = Set[:Integer, :Float, :String, :Symbol, :Array, :Hash, :NilClass, :TrueClass, :FalseClass].freeze
  Result = Struct.new(:return_fact, :return_elements, :callback_expected, :status, keyword_init: true)
  Binding = Struct.new(:signature, :variables, :argument_facts, :contracts, keyword_init: true) do
    def callback_expected
      IrRbsBlockTypes.fact(IrRbsBlockTypes.resolve(signature.block_type.type.return_type, variables), contracts)
    end

    def complete(block_return, compatible: nil)
      expected_type = signature.block_type.type.return_type
      vars = variables.dup
      if expected_type.is_a?(RBS::Types::Variable)
        name = expected_type.name.to_s
        return Result.new(status: :unknown) unless block_return && signature.type_params.include?(name)

        existing = vars[name]
        if existing && !block_return.classes.subset?(existing)
          status = IrRbsBlockTypes.compatibility(block_return.classes, existing, compatible)
          return Result.new(callback_expected: IrRbsBlockTypes.fact(existing, contracts), status: status) unless status == :compatible
        end

        vars[name] ||= block_return.classes
      end
      expected = IrRbsBlockTypes.resolve(expected_type, vars)
      status = if !expected || !block_return then :unknown
               else IrRbsBlockTypes.compatibility(block_return.classes, expected, compatible)
               end
      return Result.new(callback_expected: IrRbsBlockTypes.fact(expected, contracts), status: status) unless status == :compatible

      result_classes = IrRbsBlockTypes.resolve(signature.return_type, vars)
      elements = IrRbsBlockTypes.element_type(signature.return_type)
      Result.new(return_fact: IrRbsBlockTypes.fact(result_classes, contracts),
                 return_elements: IrRbsBlockTypes.fact(elements && IrRbsBlockTypes.resolve(elements, vars), contracts),
                 callback_expected: IrRbsBlockTypes.fact(expected, contracts), status: status)
    end
  end

  module_function

  def compatibility(actual, expected, comparator = nil)
    return :compatible if actual.subset?(expected)
    if comparator
      value = comparator.call(actual, expected)
      return value.nil? ? :unknown : value ? :compatible : :mismatch
    end
    return :mismatch if actual.subset?(DISJOINT_CORE) && expected.subset?(DISJOINT_CORE) && (actual & expected).empty?

    :unknown
  end

  def signature_for(applied, owner, name)
    applied.ir_block_signatures&.[]([owner.to_s, name.to_s])
  end

  def fact(classes, contracts)
    return nil unless classes && !classes.empty?

    BytecodeIR::Types::Fact.new(classes: classes.to_set.freeze, declared: true, contracts: contracts.sort.freeze).freeze
  end

  def element_type(type)
    type.args.first if type.is_a?(RBS::Types::ClassInstance) && type.name.to_s.delete_prefix('::') == 'Array' && type.args.size == 1
  end

  def resolve(type, variables)
    if type.is_a?(RBS::Types::Variable)
      variables[type.name.to_s]
    elsif type.is_a?(RBS::Types::Union)
      members = type.types.map { |member| resolve(member, variables) }
      members.reduce(Set.new, :|).freeze unless members.any?(&:nil?)
    elsif type.is_a?(RBS::Types::Optional)
      inner = resolve(type.type, variables)
      (inner | Set[:NilClass]).freeze if inner
    elsif type.is_a?(RBS::Types::ClassInstance) && !type.args.empty?
      return nil unless element_type(type) && resolve(element_type(type), variables)

      Set[:Array].freeze
    else
      RbsSignatures.value_classes_of(type)
    end
  end

  def unify(type, value, variables, names)
    return false unless value && !value.classes.empty? && value.classes.size <= MAX_VARIABLES

    if type.is_a?(RBS::Types::Variable)
      name = type.name.to_s
      return false unless names.include?(name)
      return false if variables[name] && variables[name] != value.classes

      variables[name] = value.classes
      true
    else
      classes = element_type(type) ? Set[:Array] : resolve(type, variables)
      classes && value.classes.subset?(classes)
    end
  end

  def bind(signature, arguments:, argument_elements: [], receiver_elements: nil)
    block = signature.block_type
    return nil unless block && signature.callback_supported && signature.type_params.size <= MAX_VARIABLES
    return nil if signature.type_param_bounds&.values&.any?

    function = block.type
    return nil unless function.optional_positionals.empty? && !function.rest_positionals && function.trailing_positionals.empty? &&
                      function.required_keywords.empty? && function.optional_keywords.empty? && !function.rest_keywords
    return nil unless arguments.size == signature.argument_types.size

    variables = {}
    contracts = ["rbs-block:#{signature.owner}##{signature.name}"]
    signature.argument_types.each_with_index do |type, index|
      element = element_type(type)
      value = arguments[index]
      return nil unless unify(type, value, variables, signature.type_params)
      contracts.concat(value.contracts)
      next unless element

      element_fact = argument_elements[index]
      return nil unless unify(element, element_fact, variables, signature.type_params)

      contracts.concat(element_fact.contracts)
    end
    # Class-level generics lack receiver type-argument metadata and remain unknown.
    bounds = function.required_positionals.map { |param| fact(resolve(param.type, variables), contracts.uniq) }
    return nil if bounds.any?(&:nil?)

    Binding.new(signature: signature, variables: variables.freeze, argument_facts: bounds.freeze, contracts: contracts.uniq.sort.freeze).freeze
  end
end
