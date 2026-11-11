# frozen_string_literal: true

require_relative 'native_core_result_sigs'

# CoreHierarchySigs: the mruby core classes the closed world does not declare, with their superclass and the modules
# they include, read from sig/bc2cpp/declarations.rbs#core_hierarchy. Replaces CallFacts::CORE_SUPER and CORE_MIXINS, with the same
# values and key order. The file only describes ancestry; CallFacts still decides what an answer means.
module CoreHierarchySigs
  PATH = NativeSigs.table('core_hierarchy')

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
    # Every consumer assumes the core classes are declared; an empty section would be read as "no core classes".
    raise "bc2cpp: #{path}: no core_hierarchy classes (the section is missing or empty)" if super_of.empty?

    [super_of.freeze, mixins.freeze]
  end

  # load(PATH), read once.
  def hierarchy
    @hierarchy ||= load.freeze
  end

  # Ruby's lookup order for an instance of +name+: the class, the modules it includes (the last include first), then
  # the same for its superclass. `ancestors('Object')` is Object, Kernel, BasicObject.
  def ancestors(name)
    super_of, mixins = hierarchy
    raise "bc2cpp: #{PATH}: #{name} is not declared" unless super_of.key?(name)

    out = []
    while name
      out << name
      out.concat(Array(mixins[name]).reverse)
      name = super_of[name]
    end
    out.freeze
  end

  # hierarchy with Symbol names, for callers that key on symbols (IrTypeFeedback). BasicObject has no superclass entry.
  def symbol_hierarchy
    super_of, mixins = hierarchy
    parents = super_of.each_with_object({}) { |(name, sup), out| out[name.to_sym] = sup.to_sym unless sup.nil? }
    [parents.freeze, mixins.to_h { |name, mods| [name.to_sym, mods.map(&:to_sym).freeze] }.freeze]
  end

  # The superclass chain from +name+ up to, not including, +stop+ (which must be on it).
  def superclasses_below(name, stop)
    super_of, = hierarchy
    raise "bc2cpp: #{PATH}: #{name} is not declared" unless super_of.key?(name)

    out = []
    until name == stop
      raise "bc2cpp: #{PATH}: #{stop} is not a superclass of #{out.first || name}" if name.nil?

      out << name
      name = super_of[name]
    end
    out.freeze
  end

  # Whether +name+ is a core class (a `class` line of the section). A core module (Kernel, Enumerable) is not.
  def declared_class?(name)
    super_of, = hierarchy
    super_of.key?(name)
  end

  # The classes declared with +name+ as their superclass, in file order.
  def subclasses(name)
    super_of, = hierarchy
    raise "bc2cpp: #{PATH}: #{name} is not declared" unless super_of.key?(name)

    super_of.select { |_, sup| sup == name }.keys.freeze
  end

  # The native scans name some core classes after their boot variable or mrb_state field, not their constant (the
  # ROM scan: `mrb->nil_class` gives "Nil", the boot variable `basic_object` gives "Basic_object"). Each listed class
  # is followed by those spellings, so an owner set built from +names+ also matches the scanned owners.
  SCAN_SPELLINGS = { 'NilClass' => %w[Nil], 'BasicObject' => %w[Basic_object] }.freeze

  def with_scan_spellings(names)
    names.flat_map { |name| [name, *SCAN_SPELLINGS.fetch(name, [])] }.freeze
  end
end
