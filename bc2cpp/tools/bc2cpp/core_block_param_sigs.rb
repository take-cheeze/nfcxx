# frozen_string_literal: true

require_relative 'native_core_result_sigs'

# CoreBlockParamSigs (CORE_BLOCK_ELEMENT_HINT): which block parameters of a core Array / Hash iterator receive an
# element of the receiver, read from sig/bc2cpp/declarations.rbs#core_block_params. The file declares `class Array[Elem]` and
# `class Hash[K, V]`; a block positional typed with the container's element variable (Elem, or V for a Hash value)
# is an element position. The table only says where an element arrives: CodeGen#block_fallback_element_hints still
# needs the receiver proven to be that container and its element class proven by the element scans.
module CoreBlockParamSigs
  PATH = NativeSigs.table('core_block_params')
  # The type variable whose value is the element class the element scans prove, per container.
  ELEMENT_VARIABLE = { 'Array' => 'Elem', 'Hash' => 'V' }.freeze
  # argc: the argument counts the shape holds for; arity: the block's positional count; elements: the 0-based block
  # positions that receive an element.
  Shape = Struct.new(:argc, :arity, :elements, keyword_init: true)

  module_function

  # { ['Array', 'each'] => Shape, ... }, frozen, read once per path.
  def shapes(path = PATH)
    @shapes ||= {}
    @shapes[path] ||= load_shapes(path)
  end

  def load_shapes(path)
    out = {}
    NativeCoreResultSigs.parse_decls(path).each do |decl|
      raise "bc2cpp: #{path}: only `class` declarations are allowed here" unless decl.is_a?(RBS::AST::Declarations::Class)

      klass = decl.name.to_s.delete_prefix('::')
      variable = ELEMENT_VARIABLE[klass] or raise "bc2cpp: #{path}: #{klass} is not a container with element facts"
      unless decl.type_params.map { |param| param.name.to_s }.include?(variable)
        raise "bc2cpp: #{path}: #{klass} must declare its element type parameter #{variable}"
      end

      decl.members.each do |member|
        unless member.is_a?(RBS::AST::Members::MethodDefinition) && member.kind == :instance && member.overloads.size == 1
          raise "bc2cpp: #{path}: #{klass} members must be single-overload instance method definitions"
        end

        key = [klass, member.name.to_s]
        raise "bc2cpp: #{path}: #{klass}##{member.name} is declared twice" if out.key?(key)

        out[key] = shape_of(member.overloads.first.method_type, variable, "#{path}: #{klass}##{member.name}")
      end
    end
    out.freeze
  end

  def shape_of(method_type, variable, where)
    fn = method_type.type
    block = method_type.block
    raise "bc2cpp: #{where} must take a required block" unless block&.required

    unless fn.rest_positionals.nil? && fn.trailing_positionals.empty? && fn.required_keywords.empty? &&
           fn.optional_keywords.empty? && fn.rest_keywords.nil?
      raise "bc2cpp: #{where} may only take positional parameters"
    end

    bfn = block.type
    unless bfn.optional_positionals.empty? && bfn.rest_positionals.nil? && bfn.trailing_positionals.empty? &&
           bfn.required_keywords.empty? && bfn.optional_keywords.empty? && bfn.rest_keywords.nil?
      raise "bc2cpp: #{where} block may only take required positionals"
    end

    elements = bfn.required_positionals.each_index.select do |i|
      type = bfn.required_positionals[i].type
      type.is_a?(RBS::Types::Variable) && type.name.to_s == variable
    end
    required = fn.required_positionals.size
    Shape.new(argc: (required..(required + fn.optional_positionals.size)), arity: bfn.required_positionals.size,
              elements: elements.freeze).freeze
  end
end
