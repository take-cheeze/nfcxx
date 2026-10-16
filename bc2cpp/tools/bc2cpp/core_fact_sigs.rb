# frozen_string_literal: true

require 'set'
require_relative 'native_core_result_sigs'
require_relative 'core_hierarchy_sigs'

# CoreFactSigs: facts about mruby core methods that used to be Ruby constants in the generator, read from RBS files
# under sig/native/ (docs/adr/0473). Each file holds one kind of fact; its loader accepts only the declaration shape
# that fact has and raises on anything else, so a file edit cannot slip a malformed claim past it. The owners must be
# classes or modules of sig/native/core_hierarchy.rbs, declared with the right keyword. scripts/bc2cpp/
# core_facts_rbs_check.rb checks every entry against the 3rd/mruby sources.
#
# These files are fact tables, not program signatures: RbsSignatures skips them (FILES), because some of the methods
# (Kernel#to_enum, Proc#yield, Proc#===) have mrblib bodies a signature would otherwise attach a hint to.
module CoreFactSigs
  DIR = File.expand_path('../../sig/native', __dir__)
  FRAME_READERS_PATH = File.join(DIR, 'core_frame_readers.rbs')
  ENUMERATORS_PATH = File.join(DIR, 'core_enumerators.rbs')
  PROC_CALLS_PATH = File.join(DIR, 'core_proc_calls.rbs')
  CLASS_TESTS_PATH = File.join(DIR, 'core_class_tests.rbs')
  FILES = [FRAME_READERS_PATH, ENUMERATORS_PATH, PROC_CALLS_PATH, CLASS_TESTS_PATH].freeze

  module_function

  # [[owner, MethodDefinition], ...] in file order: single-overload instance methods without a block, on an owner
  # in +owners+ declared as core_hierarchy.rbs has it (a module only if some class includes it).
  def methods_of(path, owners)
    super_of, mixins = CoreHierarchySigs.hierarchy
    modules = mixins.values.flatten.to_set
    out = []
    NativeCoreResultSigs.parse_decls(path).each do |decl|
      owner = decl.name.to_s.delete_prefix('::')
      raise "bc2cpp: #{path}: #{owner} may not be declared here (only #{owners.join(', ')})" unless owners.include?(owner)

      is_module = decl.is_a?(RBS::AST::Declarations::Module)
      unless (is_module && modules.include?(owner)) ||
             (decl.is_a?(RBS::AST::Declarations::Class) && decl.super_class.nil? && decl.type_params.empty? && super_of.key?(owner))
        raise "bc2cpp: #{path}: #{owner} must be declared as core_hierarchy.rbs has it (module or class, no superclass line)"
      end

      decl.members.each do |member|
        unless member.is_a?(RBS::AST::Members::MethodDefinition) && member.kind == :instance &&
               member.overloads.size == 1 && member.overloads.first.method_type.block.nil? &&
               member.overloads.first.method_type.type_params.empty?
          raise "bc2cpp: #{path}: #{owner} members must be single-overload instance methods without a block"
        end
        raise "bc2cpp: #{path}: #{owner}##{member.name} is declared twice" if out.any? { |o, m| o == owner && m.name == member.name }

        out << [owner, member]
      end
    end
    out
  end

  def cached(key, path)
    @cache ||= {}
    @cache[[key, path]] ||= yield
  end

  def return_name(member)
    ret = member.overloads.first.method_type.type.return_type
    case ret
    when RBS::Types::ClassInstance then ret.name.to_s.delete_prefix('::')
    when RBS::Types::Bases::Bool then 'bool'
    end
  end

  def positionals(member)
    fn = member.overloads.first.method_type.type
    [fn.required_positionals.size, fn.optional_positionals.size, !fn.rest_positionals.nil?,
     !(fn.trailing_positionals.empty? && fn.required_keywords.empty? && fn.optional_keywords.empty?)]
  end

  # { block: names, frame: names }: Kernel methods taking no argument that read the caller's block (`-> bool`) or
  # capture the caller's frame (`-> Binding`).
  def frame_readers(path = FRAME_READERS_PATH)
    cached(:frame_readers, path) do
      out = { block: [], frame: [] }
      methods_of(path, %w[Kernel]).each do |owner, member|
        raise "bc2cpp: #{path}: #{owner}##{member.name} must take no argument" unless positionals(member) == [0, 0, false, false]

        kind = { 'bool' => :block, 'Binding' => :frame }[return_name(member)]
        raise "bc2cpp: #{path}: #{owner}##{member.name} must return bool (block reader) or Binding (frame reader)" unless kind

        out[kind] << member.name.to_s
      end
      out.transform_values(&:freeze).freeze
    end
  end

  # CodeGen::BLOCK_GIVEN_NAMES.
  def block_given_names
    frame_readers[:block]
  end

  # CodeGen::FRAME_READING_NAMES.
  def frame_reading_names
    frame_readers[:frame]
  end

  # Kernel methods returning an Enumerator over a method the receiver is later sent (CallSiteIndex::ENUM_SENDS,
  # EnumeratorModel::NAMES).
  def enumerator_makers(path = ENUMERATORS_PATH)
    cached(:enumerator_makers, path) do
      methods_of(path, %w[Kernel]).map do |owner, member|
        raise "bc2cpp: #{path}: #{owner}##{member.name} must return Enumerator" unless return_name(member) == 'Enumerator'

        member.name.to_s
      end.freeze
    end
  end

  # Proc methods that run the proc with all their arguments (CodeGen::PROC_CALL_NAMES).
  def proc_call_names(path = PROC_CALLS_PATH)
    cached(:proc_call_names, path) do
      methods_of(path, %w[Proc]).map do |owner, member|
        unless positionals(member) == [0, 0, true, false] && member.overloads.first.method_type.type.return_type.is_a?(RBS::Types::Bases::Any)
          raise "bc2cpp: #{path}: #{owner}##{member.name} must be `(*untyped) -> untyped`"
        end

        member.name.to_s
      end.freeze
    end
  end

  # { name => [owner, ...] } in first-declaration order (CodeGen::CLASS_TEST_NATIVE_OWNERS).
  def class_test_owners(path = CLASS_TESTS_PATH)
    cached(:class_test_owners, path) do
      out = {}
      methods_of(path, %w[Kernel NilClass BasicObject]).each do |owner, member|
        (out[member.name.to_s] ||= []) << owner
      end
      out.transform_values(&:freeze).freeze
    end
  end

  # [owner, name, required, optional] per class-test declaration, for the source check.
  def class_test_arities(path = CLASS_TESTS_PATH)
    methods_of(path, %w[Kernel NilClass BasicObject]).map do |owner, member|
      required, optional, rest, other = positionals(member)
      raise "bc2cpp: #{path}: #{owner}##{member.name} may only take plain positionals" if rest || other

      [owner, member.name.to_s, required, optional]
    end
  end
end
