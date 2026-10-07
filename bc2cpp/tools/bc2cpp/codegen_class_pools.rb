# frozen_string_literal: true

require_relative 'numeric_flow'

# CodeGen: CLASS_POOLS (ADR 0295).
#
# RETURN_CLASS_TABLE's flow (codegen_return_classes.rb) knows nothing outside the method, so an ivar
# read in another method than the one that wrote it, and an argument read in the callee, were
# unknown. These pools carry the exact-class bits (a proven `Klass.new`, ARR/HSH/STR/RNG) and
# NIL across methods the way ADR 0276's pools carry INT/FLT, with the same admission:
#
#   * ivar pools reuse NumericIvarGroup's structure: one pool per (family, name), keyed by the
#     group, joined over every SETIV of the family. A group the numeric proof refuses before any
#     flow runs (`structural`: a native or foreign source spells the name, bytecode names it as
#     a Symbol/String, an attr_writer writes it, a wild family, reflection) is never tracked.
#     A slot reads nil until assigned, so the entry mask carries NIL unless numeric_ivar_assured?
#     (every constructor assigns it before `self` escapes) and the read is outside any
#     `initialize` body, blocks included.
#   * argument pools reuse entry_arg_candidates: a mandatory argument of a name with one
#     definition, called only from visible, non-computed, same-arity sites, holds the join of the
#     class sets those sites pass.
#   * constant pools (ADR 0301) reuse NumericConstGroup: one pool per bare constant name, the join of
#     the class sets its SETCONST sites store, for a name every definition of which is visible and no
#     const_missing can answer.
#
# A pool is a least fixpoint of may-sets that only grows and is dropped for good when a site
# stores a value the flow cannot name (OTHER, a pending exception) or sits in an irep it does not
# model. A class bit says "exactly this class", so everything also needs
# ClosedWorld#exact_instances_singleton_free? (ADR 0280).
class CodeGen
  # Bits a pool may not carry: unmodelled values and a pending exception object.
  CLASS_POOL_UNSHIPPABLE = NumericFlow::OTHER | NumericFlow::EXC

  def setup_class_pools
    @class_ivar_pools = {}
    @class_arg_pools = {}
    @class_const_pools = {}
    @class_pools_on = class_pools_enabled?
    return unless @class_pools_on

    (@numeric_ivar_groups || {}).each do |key, group|
      if !group.structural
        @class_ivar_pools[key] = 0
      elsif (stores = checked_group_stores(group))
        # SETTER_POOLS (ADR 0370): the setter calls and audited natives are this group's other writers.
        @class_ivar_pools[key] = stores[:classes].reduce(NumericFlow::CHECKED) { |mask, klass| mask | numeric_class_bit(klass) }
        @checked_pools_used = true
      end
    end
    (@entry_cand || {}).each_key { |key| @class_arg_pools[key] = 0 }
    setter_arg_candidates.each_key do |key|
      @class_arg_pools[key] = NumericFlow::CHECKED
      @checked_pools_used = true
    end
    return unless const_missing_free?

    (@numeric_const_groups || {}).each { |name, group| @class_const_pools[name] = 0 unless group.structural }
  end

  # A lookup that finds no constant runs const_missing, whose answer is no definition's value.
  def const_missing_free?
    installed = symbol_installed_names
    !installed.nil? && !installed.include?('const_missing') && ownerless_native_dispatch_safe?('const_missing')
  end

  # BC2CPP_CLASS_POOLS=0 turns the pools off. A Marshal.load can build an object of any class with
  # ivars of its own choosing, which no site scan sees; like ADR 0276/0279/0285 the default models
  # hostile bytes as outside the closed world, and =strict withdraws the pools whenever any Ruby
  # in the build can reach `Marshal`.
  def class_pools_enabled?
    mode = ENV.fetch('BC2CPP_CLASS_POOLS', '1')
    return false if mode == '0'
    return false unless @closed_world&.exact_instances_singleton_free? && @foreign_method_names
    return true unless mode == 'strict'
    return false if @closed_world.outside_ruby_token?('Marshal')

    @ireps.each_value.none? do |irep|
      irep.instructions.any? do |insn|
        (insn.op == 'GETCONST' && insn.const_name == 'Marshal') || (insn.op == 'GETMCNST' && insn.mcnst_name == 'Marshal') ||
          insn.sym == 'Marshal'
      end
    end
  end

  # The class set register +reg+ holds when the instruction at +idx+ reads it (the exact-class flow
  # of ADR 0289): 0 when the instruction is unreached, nil when the irep is not modelled or a
  # nested block may write the register.
  def return_class_raw_mask(irep, idx, reg)
    states = return_class_states(irep)
    return nil unless states

    state = states[idx]
    return 0 unless state

    r = reg.to_i
    return nil if r >= irep.nregs.to_i || fixnum_proof_ctx(irep)[:upvars].include?(reg.to_s)

    state[r]
  end

  # The pooled class set of an ivar read in +irep+, or nil when untracked.
  def class_pool_ivar_mask(irep, name)
    return nil unless @class_pools_on

    owner = numeric_irep_owner[irep.label]
    return nil unless owner && !owner.owner.end_with?('.singleton') && !owner.owner.start_with?('<')

    @class_ivar_pools[[numeric_family(owner.owner), name]]
  end

  # What a slot holds on entry: whatever any method may have stored, plus nil unless every
  # constructor assigns it before `self` escapes. A body nested in an `initialize` may run before
  # that assignment, so it always includes nil.
  def class_pool_ivar_entry_mask(irep, name)
    mask = class_pool_ivar_mask(irep, name)
    return NumericFlow::OTHER unless mask

    owner = numeric_irep_owner[irep.label]
    assured = owner.name != 'initialize' && numeric_ivar_assured?(owner.owner, name)
    assured ? mask : mask | NumericFlow::NIL
  end

  def class_pool_ivar_fact_mask(irep, name)
    class_pool_ivar_mask(irep, name) || NumericFlow::OTHER
  end

  def class_pool_entry_mask(irep, reg)
    return NumericFlow::OTHER unless @class_pools_on

    @class_arg_pools[[irep.label, reg.to_i]] || NumericFlow::OTHER
  end

  # The pooled class set of a GETCONST/GETMCNST: the join of what every definition of the bare name
  # stores (ADR 0301). A name the numeric proof poisons has no pool.
  def class_pool_const_mask(insn)
    name = insn.const_name
    return NumericFlow::OTHER unless @class_pools_on && name && const_missing_free?

    @class_const_pools[name] || (@integer_constants&.include?(name) ? NumericFlow::INT : NumericFlow::OTHER)
  end

  # One growth pass over every pool; true when a mask grew or a pool was dropped.
  def grow_class_pools
    return false unless @class_pools_on

    changed = false
    @class_ivar_pools.keys.each do |key|
      group = @numeric_ivar_groups.fetch(key)
      sites = group.sites.map { |irep, idx, reg| [irep, idx, reg] }
      sites += checked_group_reads(group) if group.structural
      next unless grow_class_pool(@class_ivar_pools, key, sites) { group.readers.each { |l| return_class_invalidate(l) } }

      changed = true
    end
    @class_arg_pools.keys.each do |key|
      reads = setter_arg_candidates[key]
      unless reads
        sites, k = @entry_cand.fetch(key)
        reads = sites.map { |(irep, idx, recv, _argc, _own)| [irep, idx, (recv + k).to_s] }
      end
      next unless grow_class_pool(@class_arg_pools, key, reads) { return_class_invalidate(key[0]) }

      changed = true
    end
    @class_const_pools.keys.each do |name|
      group = @numeric_const_groups.fetch(name)
      next unless grow_class_pool(@class_const_pools, name, group.sites) { group.readers.each { |l| return_class_invalidate(l) } }

      changed = true
    end
    changed
  end

  # Join the class sets +reads+ ([irep, idx, reg]) see into pools[key]; drops the pool when one is
  # unmodelled. Yields to invalidate the flows that read it after a change.
  def grow_class_pool(pools, key, reads)
    current = pools[key]
    joined = 0
    reads.each do |irep, idx, reg|
      mask = return_class_raw_mask(irep, idx, reg)
      if mask.nil? || mask.anybits?(CLASS_POOL_UNSHIPPABLE)
        joined = nil
        break
      end
      joined |= mask
    end
    grown = joined && (current | joined)
    return false if grown == current

    grown.nil? ? pools.delete(key) : pools[key] = grown
    yield
    true
  end

  # Pools that hold a class set, for the diagnostic and the coverage report.
  def class_pool_report
    lines = []
    (@class_ivar_pools || {}).each do |(family, name), mask|
      lines << "  CLASSIVAR #{family}#@#{name} (#{class_mask_name(mask)})"
    end
    (@class_arg_pools || {}).each do |(label, k), mask|
      d = @owner_of[label]
      lines << "  CLASSARG #{d ? "#{d.owner}##{d.name}" : "<irep #{label}>"} arg#{k} (#{class_mask_name(mask)})"
    end
    (@class_const_pools || {}).each { |name, mask| lines << "  CLASSCONST #{name} (#{class_mask_name(mask)})" }
    lines.sort
  end

  # "NIL|Game::Foo" style name of a class mask.
  def class_mask_name(mask)
    parts = []
    parts << 'CHECKED' if mask.anybits?(NumericFlow::CHECKED)
    parts << numeric_mask_name(mask & ((1 << NumericFlow::CLASS_BIT_BASE) - 1)) if (mask & ((1 << NumericFlow::CLASS_BIT_BASE) - 1)).nonzero?
    (@numeric_class_bits || {}).each { |klass, bit| parts << klass if mask.anybits?(bit) }
    parts.empty? ? 'NONE' : parts.join('|')
  end
end

# CodeGen: the nil half of a pooled class set (ADR 0296).
class CodeGen
  # Classes whose methods nil answers: itself and what it inherits. The ROM scan names a class
  # after its `mrb->nil_class` field ("Nil"), its boot variable ("Basic_object") or its constant.
  NIL_OWNER_NAMES = %w[NilClass Nil Object Kernel BasicObject Basic_object].freeze

  # Modules that reach nil through an include or prepend on one of its ancestors.
  def nil_ancestor_modules
    @nil_ancestor_modules ||= begin
      found = Set.new(NIL_OWNER_NAMES)
      queue = NIL_OWNER_NAMES.dup
      until queue.empty?
        owner = queue.shift
        (Array(@included_modules[owner]) + Array(@prepended_modules[owner])).each { |mod| queue << mod if found.add?(mod) }
      end
      found
    end
  end

  # nil has no method +name+ anywhere in the build, so `nil.name` only raises NoMethodError: no
  # Ruby definition on nil's ancestors (outside sources and dynamic installers included), no
  # method_missing on them, and every native registration of the name belongs to a resolved class
  # that nil does not descend from. Anything unresolved answers false.
  def nil_unanswerable?(name)
    @nil_unanswerable ||= {}
    return @nil_unanswerable[name] if @nil_unanswerable.key?(name)

    @nil_unanswerable[name] = compute_nil_unanswerable(name)
  end

  # NATIVE_CLASS_ARMS (ADR 0323): nil_unanswerable? with the installs only a class object sees left out; nil is
  # an instance of a non-Module class, as every set a lever of that ADR judges.
  def nil_unanswerable_for_instances?(name)
    @nil_unanswerable_instances ||= {}
    return @nil_unanswerable_instances[name] if @nil_unanswerable_instances.key?(name)

    @nil_unanswerable_instances[name] = nil_unanswerable_refusal(name, installed: symbol_instance_installed_names, instance_scope: true).nil?
  end

  def compute_nil_unanswerable(name)
    nil_unanswerable_refusal(name).nil?
  end

  # nil, or why nil may answer +name+. The native registrations are read from the build's own
  # sources that spell the name (the closed world's scan, not the caller's NATIVE_SRCS list, so a gem
  # that list leaves out cannot hide a NilClass method). Class-method registrations are skipped by the
  # scan on purpose (they never shadow an instance lookup); a definition through a helper that takes
  # the name as a literal is outside what any bc2cpp native scan sees.
  def nil_unanswerable_refusal(name, installed: symbol_installed_names, instance_scope: false)
    world = block_core_world
    return :no_world unless world && name
    return :installed if installed.nil? || installed.include?(name)
    return :foreign_ruby unless world.nil_foreign_definition_free?(name, nil_ancestor_modules.to_a, instance_scope: instance_scope)
    return :method_missing if (world.method_missing_classes.to_a & nil_ancestor_modules.to_a).any?
    return :registry if (@registry[name] || []).any? { |definition| nil_ancestor_modules.include?(definition.owner) }

    world.native_paths_spelling(name).each do |path|
      registrations, opaque = NativeExpressionDevirt.scan_class_registrations([path])
      owners = registrations.fetch(name, []).map { |entry| entry[:owner]&.fetch(:class_name, nil) } + opaque.fetch(name, [])
      return :unresolved_native_owner if owners.any?(&:nil?)
      return :native_on_nil if owners.any? { |owner| nil_ancestor_modules.include?(owner) }
    end
    nil
  end
end
