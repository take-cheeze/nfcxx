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
