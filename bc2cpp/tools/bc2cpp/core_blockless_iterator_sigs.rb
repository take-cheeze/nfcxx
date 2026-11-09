# frozen_string_literal: true

require_relative 'native_core_result_sigs'

# CoreBlocklessIteratorSigs: the result class of core block iterators called WITHOUT a block (a SEND site), read from
# sig/bc2cpp/declarations.rbs#core_blockless_iterators. Each member is the method-level union of its blockless overload
# (the result class, Enumerator, and the argument count) and its block overload; a member with only one form is refused.
# The block form's result is core_block_iterators (CoreBlockIteratorSigs) where that table declares it.
module CoreBlocklessIteratorSigs
  PATH = NativeSigs.table('core_blockless_iterators')

  module_function

  # { 'Enumerable' => { 'map' => 'Enumerator', ... } }, frozen, read once per path.
  def results(path = PATH)
    tables(path)[:results]
  end

  # [min, max] positional arguments the blockless call of +name+ takes (max nil: any number), or nil when undeclared.
  def arity(owner, name, path = PATH)
    tables(path)[:arity].dig(owner, name)
  end

  def tables(path)
    @loaded ||= {}
    @loaded[path] ||= load_tables(path)
  end

  def load_tables(path)
    results = {}
    arity = {}
    NativeCoreResultSigs.parse_decls(path).each do |decl|
      unless decl.is_a?(RBS::AST::Declarations::Module)
        raise "bc2cpp: #{path}: only `module` declarations are allowed here"
      end

      owner = decl.name.to_s.delete_prefix('::')
      kinds = results[owner] ||= {}
      sizes = arity[owner] ||= {}
      decl.members.each do |member|
        unless member.is_a?(RBS::AST::Members::MethodDefinition) && member.kind == :instance
          raise "bc2cpp: #{path}: #{owner} members must be instance method definitions"
        end

        # Every member is the method-level union of its two forms: one blockless overload and one with a block.
        forms = member.overloads.map { |o| o.method_type.block ? :block : :blockless }.sort
        unless forms == %i[block blockless]
          raise "bc2cpp: #{path}: #{owner}##{member.name} must declare one blockless and one block overload, not #{forms.join(' and ')}"
        end

        overload = NativeCoreResultSigs.form_overload(member, owner, path, :blockless)
        fn = overload.method_type.type
        kinds[member.name.to_s] = NativeCoreResultSigs.result_kind(member, overload, owner, path, scalars: false,
                                                                                                  classes: %w[Enumerator])
        min = fn.required_positionals.size
        max = fn.rest_positionals ? nil : min + fn.optional_positionals.size
        sizes[member.name.to_s] = [min, max].freeze
      end
    end
    { results: results.transform_values(&:freeze).freeze, arity: arity.transform_values(&:freeze).freeze }.freeze
  end
end
