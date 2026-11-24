# frozen_string_literal: true

require 'set'
require_relative 'numeric_flow'

# MONO_RECEIVER_PROOF: a MONO target is the one definition of its name, which says nothing about the receiver. nil, or
# an object whose class does not reach target.owner, raises NoMethodError (or reaches method_missing) in the
# interpreter, where a direct call would run the body. So a MONO call is left unguarded only when
# mono_receiver_proof says :proven; :nilable takes a nil test first; anything else takes the exact class guard with
# the by-name send. BC2CPP_MONO_RECEIVER_PROOF=0 restores the unguarded call everywhere.
class CodeGen
  # Owners every object reaches; Kernel and Object only when no class derives from BasicObject directly.
  MONO_UNIVERSAL_OWNERS = %w[Kernel Object].freeze

  def mono_receiver_proof_enabled?
    ENV['BC2CPP_MONO_RECEIVER_PROOF'] != '0'
  end

  # :proven (the receiver's class reaches target on every path), :nilable (nil, or that), or nil (unproven).
  # `reg` is the receiver register as the flow at (irep, idx) reads it, nil when the receiver is substituted.
  def mono_receiver_proof(name, target, recv:, self_implicit:, owner_def:, irep:, idx:, reg:)
    return :proven unless mono_receiver_proof_enabled?
    return :proven if mono_universal_owner?(target.owner)

    # The LOADSELF test reads the unshifted register: an inlined block body's `recv` is its shifted copy.
    self_recv = self_implicit || recv == 'self' || (irep && idx && reg && receiver_loaded_self?(RegName[reg.to_i], irep, idx))
    if self_recv
      self_owner = owner_def && self_class(owner_def)
      return :proven if self_owner && mono_self_reaches?(self_owner, target.owner, owner_def)
      return nil if self_implicit || recv == 'self'
    end
    return nil unless irep && idx && reg

    constant = @closed_world && constant_object_owner(irep, idx, reg, owner_def&.owner)
    if constant
      found = constant_object_singleton_def(name, constant)
      return found && mono_same_def?(found, target) ? :proven : nil
    end
    mono_flow_proof(name, target, irep, idx, reg.to_i)
  end

  def mono_same_def?(found, target)
    found.owner == target.owner && found.irep == target.irep
  end

  # The flow's class set: every class bit resolves `name` to target (closed_world_exact_target), plus nil at most.
  def mono_flow_proof(name, target, irep, idx, reg)
    mask = exact_flow_mask(irep, idx, reg)
    return nil unless mask.is_a?(Integer) && mask.positive?

    mask = exact_flow_strip_nil(irep, idx, reg, mask)
    rest = mask & ~NumericFlow::NIL
    return nil if rest.zero?

    core = MONO_CORE_BITS.select { |bit, _| rest.anybits?(bit) }
    return nil unless core.all? { |_, klass| mono_core_reaches?(name, klass, target.owner) }

    rest &= ~core.keys.reduce(0, :|)
    unless rest.zero?
      bits = numeric_receiver_class_bits(rest)
      return nil unless bits
      return nil unless bits.all? do |bit|
        klass = return_class_name_of_bit(bit)
        found = klass && closed_world_exact_target(name, klass)
        next mono_same_def?(found, target) if found

        klass && @closed_world.inherited_lookup_safe?(name, klass) && mono_class_reaches?(klass, target.owner)
      end
    end

    mask.anybits?(NumericFlow::NIL) ? :nilable : :proven
  end

  # The flow's exact core classes and mruby's fixed ancestor chain of each, up to Object.
  MONO_CORE_BITS = { NumericFlow::INT => 'Integer', NumericFlow::FLT => 'Float', NumericFlow::ARR => 'Array',
                     NumericFlow::HSH => 'Hash', NumericFlow::STR => 'String', NumericFlow::RNG => 'Range' }.freeze
  MONO_CORE_ANCESTORS = { 'Integer' => %w[Integer Numeric Comparable], 'Float' => %w[Float Numeric Comparable],
                          'Array' => %w[Array Enumerable], 'Hash' => %w[Hash Enumerable],
                          'String' => %w[String Comparable], 'Range' => %w[Range Enumerable] }.freeze

  # An exact core-class receiver reaches target_owner when it is on the class's chain and nothing on the chain up to
  # it answers the name first: no program mixin or prepend, no outside Ruby or by-name install, no native registration.
  def mono_core_reaches?(name, klass, target_owner)
    chain = MONO_CORE_ANCESTORS.fetch(klass)
    at = chain.index(target_owner)
    world = @closed_world
    return false unless at && world

    return false if chain[0..at].any? do |c|
      @unknown_mixins.include?(c) || !Array(@prepended_modules[c]).empty? || !(Array(@included_modules[c]) - chain).empty?
    end
    # The owner's own definition is the MONO target; only what sits before it can answer first.
    before = chain[0...at]
    return true if before.empty?

    installed = symbol_installed_names
    return false if installed.nil? || installed.include?(name)
    return false unless world.nil_foreign_definition_free?(name, before)

    world.native_paths_spelling(name).none? do |path|
      registrations, opaque = NativeExpressionDevirt.path_registrations(path)
      owners = registrations.fetch(name, []).map { |entry| entry[:owner]&.fetch(:class_name, nil) } + opaque.fetch(name, [])
      owners.any? { |owner| owner.nil? || before.include?(owner) }
    end
  end

  def mono_universal_owner?(owner)
    MONO_UNIVERSAL_OWNERS.include?(owner) && @closed_world&.basic_object_subclass_free?
  end

  # self is kind_of self_owner (self_class); its class chain reaches target_owner. A body shared by several owners
  # (module_function's copy) runs with a self of either, so it proves nothing.
  def mono_self_reaches?(self_owner, target_owner, owner_def)
    return false if owner_def.kind == :module_function || mono_shared_irep?(owner_def)

    singleton = self_owner.end_with?('.singleton')
    return false unless singleton == target_owner.end_with?('.singleton')

    singleton ? mono_class_reaches?(self_owner.delete_suffix('.singleton'), target_owner.delete_suffix('.singleton'), mixins: false) :
                mono_class_reaches?(self_owner, target_owner)
  end

  # Is `want` on the superclass chain of program class `klass` (or, for an instance lookup, a module one of those
  # classes includes)? MONO makes want's definition the only one of the name, so the lookup ends there.
  def mono_class_reaches?(klass, want, mixins: true)
    seen = Set.new
    while klass.is_a?(String) && seen.add?(klass)
      return true if klass == want
      return true if mixins && Array(@included_modules[klass]).include?(want)
      return true if mixins && klass == 'Object' && want == 'Kernel'

      # :none is an implicit Object; a BasicObject subclass ends at BasicObject, which has no superclass here.
      klass = @superclass_of[klass] == :none ? 'Object' : @superclass_of[klass]
    end
    false
  end

  def mono_shared_irep?(owner_def)
    return false unless owner_def.irep

    @mono_irep_owners ||= @registry.values.flatten.each_with_object(Hash.new { |h, k| h[k] = Set.new }) do |md, out|
      out[md.irep] << md.owner if md.irep
    end
    @mono_irep_owners[owner_def.irep].size > 1
  end

  # The guard an unproven MONO receiver takes: the exact class of an owner with no subclass, else kind_of (the
  # owner-class getter yields nullptr for an undefined constant, which fails both). The second value is the `listed`
  # of guarded_fallback_line: only an exact guard says the else arm's receiver cannot reach the owner.
  def mono_receiver_check(owner, recv)
    cls = owner_class_ptr_expr(owner)
    return [exact_class_guard(cls, recv), [owner]] if @closed_world&.exact_class?(owner)

    ["bc2cpp_kind_of_owner(M, #{recv}, #{cls})", []]
  end

  # A module or singleton owner has no instance whose class is it: its unproven receiver keeps only the by-name send.
  def mono_guardable_owner?(owner)
    !owner.end_with?('.singleton') && !@closed_world&.module_declared?(owner) && !MONO_MODULES.include?(owner)
  end
  MONO_MODULES = %w[Kernel Comparable Enumerable].freeze

  # What nil does with the call when nothing on nil answers the name: its NoMethodError, positionals as its args
  # (prepare_missing packs ci->n only). Nil when nil may answer it.
  def mono_nil_arm(d, recv, name, argv)
    return nil unless nil_unanswerable?(name)

    args = argv.empty? ? '' : ", #{argv.size}, #{argv.join(', ')}"
    "#{RegName[d]} = bc2cpp_nil_receiver_named(M, #{recv}, \"#{name}\"#{args}); #{NomethodReviewed.nil_receiver_marker(name)}\n"
  end
end
