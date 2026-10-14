# frozen_string_literal: true

require_relative 'native_core_result_sigs'

# CoreHierarchySigs: the mruby core classes the closed world does not declare, with their superclass and the modules
# they include, read from sig/native/core_hierarchy.rbs. Replaces CallFacts::CORE_SUPER and CORE_MIXINS, with the same
# values and key order. The file only describes ancestry; CallFacts still decides what an answer means.
module CoreHierarchySigs
  PATH = File.expand_path('../../sig/native/core_hierarchy.rbs', __dir__)

  module_function

  # [super_of, mixins]: super_of maps each class to its superclass name (nil for BasicObject), mixins maps a class to
  # the modules it includes, only for classes that include some.
  def load(path = PATH)
    super_of = {}
    mixins = {}
    NativeCoreResultSigs.parse_decls(path).each do |decl|
      raise "bc2cpp: #{path}: only `class` declarations are allowed here" unless decl.is_a?(RBS::AST::Declarations::Class)

      name = decl.name.to_s.delete_prefix('::')
      sup = decl.super_class&.name&.to_s&.delete_prefix('::')
      raise "bc2cpp: #{path}: #{name} has no superclass line (only BasicObject may omit it)" if sup.nil? && name != 'BasicObject'
      raise "bc2cpp: #{path}: #{name} is declared twice" if super_of.key?(name)

      super_of[name] = sup
      includes = decl.members.grep(RBS::AST::Members::Include).map { |m| m.name.to_s.delete_prefix('::') }
      mixins[name] = includes.freeze unless includes.empty?
    end
    [super_of.freeze, mixins.freeze]
  end
end
