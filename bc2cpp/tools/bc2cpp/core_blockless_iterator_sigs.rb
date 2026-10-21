# frozen_string_literal: true

require_relative 'native_core_result_sigs'

# CoreBlocklessIteratorSigs: the result class of core block iterators called WITHOUT a block (a SEND site), read from
# sig/bc2cpp/declarations.rbs#core_blockless_iterators. Each member is the method-level union of its two forms; this
# reads the blockless overload. The block form is core_block_iterators (CoreBlockIteratorSigs).
module CoreBlocklessIteratorSigs
  PATH = NativeSigs.table('core_blockless_iterators')

  module_function

  # { 'Enumerable' => { 'map' => 'Enumerator', ... } }, frozen, read once per path.
  def results(path = PATH)
    @results ||= {}
    @results[path] ||= load_results(path)
  end

  def load_results(path)
    out = {}
    NativeCoreResultSigs.parse_decls(path).each do |decl|
      unless decl.is_a?(RBS::AST::Declarations::Module)
        raise "bc2cpp: #{path}: only `module` declarations are allowed here"
      end

      owner = decl.name.to_s.delete_prefix('::')
      table = out[owner] ||= {}
      decl.members.each do |member|
        unless member.is_a?(RBS::AST::Members::MethodDefinition) && member.kind == :instance
          raise "bc2cpp: #{path}: #{owner} members must be instance method definitions"
        end

        overload = NativeCoreResultSigs.form_overload(member, owner, path, :blockless)
        table[member.name.to_s] = NativeCoreResultSigs.result_kind(member, overload, owner, path, scalars: false,
                                                                                                classes: %w[Enumerator])
      end
    end
    out.transform_values(&:freeze).freeze
  end
end
