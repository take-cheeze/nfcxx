# frozen_string_literal: true

require 'set'

# NativeCoreResultSigs: the result class of built-in methods, read from sig/native/core_results.rbs. It replaces the
# hand-written NativeClassResults::EXACT_CORE_KINDS table with the same { class => { name => class } } shape. The file
# only names classes; codegen_native_results.rb still gates every answer on the closed-world pins, so a file edit can
# only widen what is considered, never skip those checks.
module NativeCoreResultSigs
  PATH = File.expand_path('../../sig/native/core_results.rbs', __dir__)
  RESULT_CLASSES = %w[Array String].freeze

  module_function

  FRESH_ARRAY_PATH = File.expand_path('../../sig/native/core_fresh_arrays.rbs', __dir__)

  # { 'Array' => { 'to_a' => 'Array', ... }, ... }, frozen, read once per path.
  def kinds(path = PATH)
    @kinds ||= {}
    @kinds[path] ||= load_kinds(path)
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

  def load_kinds(path)
    begin
      require 'rbs'
    rescue LoadError
      raise "bc2cpp: #{path} needs the rbs gem (gem install rbs)"
    end
    _buf, _dirs, decls = RBS::Parser.parse_signature(RBS::Buffer.new(name: File.basename(path), content: File.read(path)))
    out = {}
    decls.each do |decl|
      raise "bc2cpp: #{path}: only `class` reopenings are allowed here, not #{decl.class.name.split('::').last}" unless decl.is_a?(RBS::AST::Declarations::Class)

      klass = decl.name.to_s.delete_prefix('::')
      table = out[klass] ||= {}
      decl.members.each do |member|
        unless member.is_a?(RBS::AST::Members::MethodDefinition) && member.overloads.size == 1
          raise "bc2cpp: #{path}: #{klass} members must be single-overload method definitions"
        end

        table[member.name.to_s] = result_class(member, klass, path)
      end
    end
    out.transform_values { |table| table.freeze }.freeze
  end

  def result_class(member, klass, path)
    ret = member.overloads.first.method_type.type.return_type
    name = ret.is_a?(RBS::Types::ClassInstance) ? ret.name.to_s.delete_prefix('::') : nil
    raise "bc2cpp: #{path}: #{klass}##{member.name} must return one of #{RESULT_CLASSES.join(', ')}" unless RESULT_CLASSES.include?(name)

    name
  end
end
