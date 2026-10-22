# frozen_string_literal: true

require_relative 'native_core_result_sigs'

# CoreBlockIteratorSigs: the result class of core block iterators called with a literal block, read from
# sig/bc2cpp/declarations.rbs#core_block_iterators. Codegen does not read it: block_collection_result_mask derives the
# class from the core bodies. scripts/bc2cpp/core_facts_rbs_check.rb holds the declaration to those bodies' shape.
module CoreBlockIteratorSigs
  PATH = NativeSigs.table('core_block_iterators')
  CLASSES = %w[Array Hash].freeze

  module_function

  # { 'Enumerable' => { 'map' => 'Array', ... }, 'Hash' => { 'reject' => 'Hash' } }, frozen, read once per path.
  def results(path = PATH)
    @results ||= {}
    @results[path] ||= load_results(path)
  end

  # Where each iterator's Array elements come from, read from the declarations:
  #   :block_return  `-> Array[U]` with the block's `-> U` (`def map: [U] () { (untyped) -> U } -> Array[U]`): the
  #                  block's own returns, so the element mask is the block's return class;
  #   :receiver      `-> Array[Elem]` with the block's `(Elem) -> ...` (Array's own select, reject, find_all, sort_by):
  #                  the receiver's elements, unchanged.
  # Anything else (an `untyped` element, flat_map's flattening) is not listed. Codegen reads these, not a name list.
  def element_sources(path = PATH)
    @element_sources ||= {}
    @element_sources[path] ||= load_element_sources(path)
  end

  # Owners and names whose elements come from the block's returns (see element_sources).
  def block_return_elements(path = PATH)
    element_sources(path).transform_values { |names| names.select { |_, kind| kind == :block_return }.keys.freeze }
  end

  # True when +name+ is declared as a block iterator and every owner that declares it takes its elements from the block.
  def block_return_element?(name, path = PATH)
    element_kind?(name, :block_return, path)
  end

  # True when +name+ is declared as a block iterator and every owner that declares it yields the receiver's elements.
  def receiver_element?(name, path = PATH)
    element_kind?(name, :receiver, path)
  end

  def element_kind?(name, kind, path)
    declaring = results(path).select { |_owner, names| names.key?(name) }.keys
    return false if declaring.empty?

    sources = element_sources(path)
    declaring.all? { |owner| sources.fetch(owner, {})[name] == kind }
  end

  def load_element_sources(path)
    out = {}
    NativeCoreResultSigs.parse_decls(path).each do |decl|
      next unless decl.is_a?(RBS::AST::Declarations::Class) || decl.is_a?(RBS::AST::Declarations::Module)

      owner = decl.name.to_s.delete_prefix('::')
      kinds = out[owner] ||= {}
      decl.members.each do |member|
        next unless member.is_a?(RBS::AST::Members::MethodDefinition) && member.kind == :instance

        method_type = member.overloads.first.method_type
        next unless method_type.block&.type.is_a?(RBS::Types::Function)

        kind = element_kind_of(method_type)
        kinds[member.name.to_s] = kind if kind
      end
    end
    out.transform_values { |kinds| kinds.freeze }.freeze
  end

  # The element source of one declaration, or nil.
  def element_kind_of(method_type)
    ret = method_type.type.return_type
    return nil unless ret.is_a?(RBS::Types::ClassInstance) && ret.name.to_s.delete_prefix('::') == 'Array' && ret.args.size == 1

    element = ret.args.first
    return nil unless element.is_a?(RBS::Types::Variable)

    block = method_type.block.type
    return :block_return if block.return_type.is_a?(RBS::Types::Variable) && block.return_type.name == element.name

    first = block.required_positionals.first&.type
    return :receiver if first.is_a?(RBS::Types::Variable) && first.name == element.name

    nil
  end

  def load_results(path)
    out = {}
    NativeCoreResultSigs.parse_decls(path).each do |decl|
      unless decl.is_a?(RBS::AST::Declarations::Class) || decl.is_a?(RBS::AST::Declarations::Module)
        raise "bc2cpp: #{path}: only `class` and `module` declarations are allowed here"
      end

      owner = decl.name.to_s.delete_prefix('::')
      table = out[owner] ||= {}
      decl.members.each do |member|
        unless member.is_a?(RBS::AST::Members::MethodDefinition) && member.kind == :instance && member.overloads.size == 1
          raise "bc2cpp: #{path}: #{owner} members must be single instance method definitions"
        end

        method_type = member.overloads.first.method_type
        raise "bc2cpp: #{path}: #{owner}##{member.name} must take a block and no arguments" unless
          method_type.block && method_type.type.required_positionals.empty? && method_type.type.optional_positionals.empty?

        ret = method_type.type.return_type
        klass = ret.is_a?(RBS::Types::ClassInstance) ? ret.name.to_s.delete_prefix('::') : nil
        raise "bc2cpp: #{path}: #{owner}##{member.name} must return Array or Hash" unless CLASSES.include?(klass)
        raise "bc2cpp: #{path}: #{owner}##{member.name} is declared twice" if table.key?(member.name.to_s)

        table[member.name.to_s] = klass
      end
    end
    out.transform_values(&:freeze).freeze
  end
end
