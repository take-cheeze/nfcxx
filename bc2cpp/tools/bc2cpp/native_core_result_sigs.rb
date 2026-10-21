# frozen_string_literal: true

require 'set'
require_relative 'native_sigs'

# NativeCoreResultSigs: the result kind of built-in methods, read from RBS files under sig/bc2cpp/. It replaces the
# hand-written NativeClassResults::EXACT_CORE_KINDS table with the same { class => { name => kind } } shape. A file
# only names kinds; codegen_native_results.rb and the NATIVE_RESULT_FACTS audit still gate every answer on the
# closed-world pins and the source checks, so a file edit can only widen what is considered, never skip those checks.
module NativeCoreResultSigs
  PATH = NativeSigs.table('core_results')
  FRESH_ARRAY_PATH = NativeSigs.table('core_fresh_arrays')
  RGSS_PATH = NativeSigs.table('rgss_results')
  RESULT_CLASSES = %w[Array String].freeze

  module_function

  # { 'Array' => { 'to_a' => 'Array', ... }, ... }, frozen, read once per path. Only Array and String results.
  def kinds(path = PATH)
    @kinds ||= {}
    @kinds[path] ||= load_kinds(path, scalars: true)
  end

  # The method names that return a fresh Array on some core owner (CORE_ARRAY_RETURN_METHODS). A declaration
  # returning anything but Array would make the name claim false, so it is rejected here.
  def fresh_array_names(path = FRESH_ARRAY_PATH)
    kinds(path).each do |klass, table|
      table.each do |name, result|
        raise "bc2cpp: #{path}: #{klass}##{name} must return Array for a fresh-Array claim" unless result == 'Array'
      end
    end
    kinds(path).values.flat_map(&:keys).to_set.freeze
  end

  # The declarations of one native table (NativeSigs.table names it), or of a file holding one table's text.
  def parse_decls(path)
    return NativeSigs.decls(path) if NativeSigs.table?(path)

    require 'rbs'
    _buf, _dirs, decls = RBS::Parser.parse_signature(RBS::Buffer.new(name: File.basename(path), content: File.read(path)))
    decls
  end

  # Kinds are :fixnum (Integer, only with +scalars+), :float (Float, only with +scalars+) or a class name listed in
  # +classes+. Each method takes one overload and returns exactly one of those.
  # +form+: a member may carry several overloads (the method-level union of a bare and a block form), and its kind is
  # read from the one of that form: :block (takes a block) or :blockless. Without it every member is single-overload.
  def load_kinds(path, scalars: false, classes: RESULT_CLASSES, form: nil)
    decls = parse_decls(path)
    out = {}
    decls.each do |decl|
      raise "bc2cpp: #{path}: only `class` reopenings are allowed here, not #{decl.class.name.split('::').last}" unless decl.is_a?(RBS::AST::Declarations::Class)

      klass = decl.name.to_s.delete_prefix('::')
      table = out[klass] ||= {}
      decl.members.each do |member|
        unless member.is_a?(RBS::AST::Members::MethodDefinition) && (member.overloads.size == 1 || form)
          raise "bc2cpp: #{path}: #{klass} members must be single-overload method definitions"
        end

        overload = form ? form_overload(member, klass, path, form) : member.overloads.first
        table[member.name.to_s] = result_kind(member, overload, klass, path, scalars: scalars, classes: classes)
      end
    end
    out.transform_values { |table| table.freeze }.freeze
  end

  # The one overload of +form+ (:block or :blockless) of a member.
  def form_overload(member, klass, path, form)
    wanted = form == :block
    matches = member.overloads.select { |o| o.method_type.block.nil? != wanted }
    raise "bc2cpp: #{path}: #{klass}##{member.name} needs exactly one #{form} overload" unless matches.size == 1

    matches.first
  end

  def result_kind(member, overload, klass, path, scalars:, classes:)
    ret = overload.method_type.type.return_type
    name = ret.is_a?(RBS::Types::ClassInstance) ? ret.name.to_s.delete_prefix('::') : nil
    return :fixnum if scalars && name == 'Integer'
    return :float if scalars && name == 'Float'
    return name if classes.include?(name)

    allowed = scalars ? %w[Integer Float] + classes : classes
    raise "bc2cpp: #{path}: #{klass}##{member.name} must return one of #{allowed.join(', ')}"
  end
end
