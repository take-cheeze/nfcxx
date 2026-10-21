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

  # { 'Enumerable' => ['map', 'collect', 'filter_map'], ... }: the iterators whose Array elements are the block's own
  # returns, declared as `-> Array[U]` with the block's `-> U` (`def map: [U] () { (untyped) -> U } -> Array[U]`).
  # The element mask is read from these declarations, not from a list of names in codegen.
  def block_return_elements(path = PATH)
    @block_return_elements ||= {}
    @block_return_elements[path] ||= load_block_return_elements(path)
  end

  # True when +name+ is declared as a block iterator and every owner that declares it takes its elements from the block.
  def block_return_element?(name, path = PATH)
    declaring = results(path).select { |_owner, names| names.key?(name) }.keys
    return false if declaring.empty?

    elements = block_return_elements(path)
    declaring.all? { |owner| elements.fetch(owner, []).include?(name) }
  end

  def load_block_return_elements(path)
    out = {}
    NativeCoreResultSigs.parse_decls(path).each do |decl|
      next unless decl.is_a?(RBS::AST::Declarations::Class) || decl.is_a?(RBS::AST::Declarations::Module)

      owner = decl.name.to_s.delete_prefix('::')
      names = out[owner] ||= Set.new
      decl.members.each do |member|
        next unless member.is_a?(RBS::AST::Members::MethodDefinition) && member.kind == :instance

        method_type = member.overloads.first.method_type
        next unless method_type.block&.type.is_a?(RBS::Types::Function)

        ret = method_type.type.return_type
        element = ret.is_a?(RBS::Types::ClassInstance) && ret.name.to_s.delete_prefix('::') == 'Array' && ret.args.size == 1 &&
                  ret.args.first
        block_ret = method_type.block.type.return_type
        names << member.name.to_s if element.is_a?(RBS::Types::Variable) && block_ret.is_a?(RBS::Types::Variable) &&
                                     element.name == block_ret.name
      end
    end
    out.transform_values { |names| names.to_a.freeze }.freeze
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
