# frozen_string_literal: true

require_relative 'numeric_flow'

# CodeGen: NUMERIC_IVAR_PROOF (ADR 0276).
#
# What class set can `@name` hold? One whole-program fact per (family, name):
# the join of the class sets of every value any SETIV stores, computed by the
# same NumericFlow that consumes it (grown from empty, so `@i += 1` proves itself
# from `@i = 0`).
#
# A family is a connected component of the class graph (superclass and
# include/prepend links): an ivar slot exists on an object and is visible to
# every method of every class that object is an instance of, so unrelated
# hierarchies never share one and `@width` in a Window is not `@width` in a
# Rect. Sound only when nothing writes the slot outside the SETIV sites this
# scan sees, so a group FAILS (is never tracked) when:
#   - a native or foreign-Ruby source spells the name (outside_ivar_names), or
#     bytecode names it as a Symbol/String (`instance_variable_set(:@x)`);
#   - any irep with no owner (class body, top level) touches it, or the owner is
#     Object/Kernel/BasicObject (visible to every family);
#   - an attr_writer/attr_accessor writes it (the value is the caller's), or a
#     class in the family has an unresolved superclass or an unknown mixin;
#   - a SETIV site lives in an irep NumericFlow cannot model, or stores a value
#     whose class set is not known.
# Reflection that could reach any ivar (`instance_variable_set` with a computed
# name, `instance_eval` and friends, which rebind `self`) disables the whole
# proof.
#
# An ivar nothing has assigned reads nil, so a slot starts as the group's mask
# joined with NIL (ivar_entry_mask) unless every constructor assigns it first
# (numeric_ivar_assured?), and the flow's SETIV then narrows it. IvarLayout's
# Fixnum-embedded fields keep their own guarantee: Integer, never unassigned.
class CodeGen
  # `structural` is the part of `failed` that does not depend on a flow (a poisoned name, a wild family,
  # an attr_writer), which the class pools of ADR 0295 reuse.
  NumericIvarGroup = Struct.new(:family, :name, :mask, :sites, :readers, :failed, :structural)

  # Sends that write an ivar by computed name: only a Symbol literal argument
  # (poisoned by name) is tolerated.
  NUMERIC_IVAR_NAMED_WRITES = %w[instance_variable_set remove_instance_variable].freeze
  # Sends whose block runs with another object as `self`.
  NUMERIC_SELF_REBINDERS = %w[instance_eval instance_exec class_eval class_exec module_eval module_exec
                              define_method define_singleton_method eval].freeze
  NUMERIC_IVAR_UNIVERSAL_OWNERS = %w[Object Kernel BasicObject Module Class].freeze

  def setup_numeric_ivar_groups
    @numeric_ivar_groups = {}
    @numeric_irep_slots = {}
    @numeric_irep_owner = nil
    @numeric_ivar_disabled = numeric_ivar_prerequisites_missing?
    return if @numeric_ivar_disabled

    build_numeric_families
    poisoned = numeric_ivar_poisoned_names
    rebound = numeric_self_rebound_ireps
    return if @numeric_ivar_disabled

    @ireps.each_value do |irep|
      owner = numeric_irep_owner[irep.label]
      irep.instructions.each_with_index do |insn, idx|
        next unless insn.op == 'GETIV' || insn.op == 'SETIV'

        name = insn.ivar
        next unless name

        if owner.nil? || rebound.include?(irep.label)
          poisoned << name
          next
        end
        next if owner.owner.end_with?('.singleton') || owner.owner.start_with?('<')

        if NUMERIC_IVAR_UNIVERSAL_OWNERS.include?(owner.owner)
          poisoned << name
          next
        end

        group = (@numeric_ivar_groups[[numeric_family(owner.owner), name]] ||=
                   NumericIvarGroup.new(numeric_family(owner.owner), name, 0, [], Set.new, false, false))
        group.readers << irep.label
        group.sites << [irep, idx, insn.regs.first] if insn.op == 'SETIV'
      end
    end
    fail_numeric_ivar_groups(poisoned)
  end

  def numeric_ivar_prerequisites_missing?
    @outside_ivar_names.nil? || @closed_world.nil? || !@closed_world.global_refusal.nil?
  end

  # label -> the MethodDef whose body (blocks included) the irep is.
  def numeric_irep_owner
    @numeric_irep_owner ||= begin
      map = {}
      @owner_of.each do |label, d|
        stack = [label]
        until stack.empty?
          cur = stack.pop
          next if map.key?(cur)

          map[cur] = d
          (@ireps[cur]&.reps || []).each { |c| stack << c }
        end
      end
      map
    end
  end

  def build_numeric_families
    parent = Hash.new { |h, k| h[k] = k }
    find = lambda do |x|
      parent[x] = find.call(parent[x]) unless parent[x] == x
      parent[x]
    end
    union = ->(a, b) { parent[find.call(a)] = find.call(b) }
    @superclass_of.each do |klass, sup|
      union.call(klass, sup) if sup.is_a?(String)
    end
    [@included_modules, @prepended_modules].each do |table|
      table.each { |klass, mods| Array(mods).each { |m| union.call(klass, m) } }
    end
    @numeric_family_find = find
    @numeric_wild_families = Set.new
    known_owner_set.each do |owner|
      next if owner.end_with?('.singleton') || owner.start_with?('<')

      declared_class = @closed_world.class_declared?(owner)
      @numeric_wild_families << find.call(owner) if declared_class && !@superclass_of.key?(owner)
    end
    @unknown_mixins.each { |m| @numeric_wild_families << find.call(m) }
  end

  def numeric_family(owner)
    @numeric_family_find.call(owner)
  end

  # Names no group may track; sets @numeric_ivar_disabled when reflection could
  # write any ivar.
  def numeric_ivar_poisoned_names
    names = Set.new(@outside_ivar_names - @native_ivar_scopes.keys)
    @ireps.each_value do |irep|
      irep.instructions.each_with_index do |insn, idx|
        sym = insn.sym
        if sym && insn.op == 'LOADSYM'
          names << sym.delete_prefix('@') if sym.start_with?('@') && !sym.start_with?('@@')
          @numeric_ivar_disabled = "LOADSYM #{sym}" if (NUMERIC_IVAR_NAMED_WRITES + NUMERIC_SELF_REBINDERS).include?(sym)
        elsif sym && insn.op.include?('SEND') && NUMERIC_IVAR_NAMED_WRITES.include?(sym)
          @numeric_ivar_disabled = "non-literal #{sym} in #{irep.label}" unless literal_ivar_argument?(irep, idx, insn)
        end
        if insn.op == 'STRING'
          entry = irep.pool[insn.pool_index.to_i]
          names << entry[1..] if entry.is_a?(String) && entry.start_with?('@') && !entry.start_with?('@@')
        end
      end
    end
    names
  end

  # Ireps that may run with a `self` other than their method's: every block
  # nested in an irep that hands a literal block to instance_eval and friends.
  # Their ivar accesses name slots of an unknown object, so those names are
  # poisoned. A rebinding send that does not take a literal block could run any
  # proc, so it disables the proof.
  def numeric_self_rebound_ireps
    out = Set.new
    @ireps.each_value do |irep|
      irep.instructions.each_with_index do |insn, idx|
        next unless insn.op.include?('SEND') && NUMERIC_SELF_REBINDERS.include?(insn.sym)

        @numeric_ivar_disabled = "rebinder #{insn.sym} without literal block in #{irep.label}" unless literal_block_argument?(irep, idx, insn)
        stack = Array(irep.reps).dup
        until stack.empty?
          label = stack.pop
          next unless out.add?(label)

          stack.concat(Array(@ireps[label]&.reps))
        end
      end
    end
    out
  end

  # SENDB whose block register is written by BLOCK/LAMBDA in the same irep.
  def literal_block_argument?(irep, idx, insn)
    return false unless insn.op.end_with?('B') && insn.reg

    n = insn.op.end_with?('0B') ? 0 : insn.argc
    return false unless n

    irep.walk_writers(idx - 1, (insn.reg.to_i + n + 1).to_s, follow_moves: true) do |writer|
      %w[BLOCK LAMBDA].include?(writer.op)
    end || false
  end

  # `instance_variable_set(:@x, v)`: the name is a LOADSYM (already poisoned).
  def literal_ivar_argument?(irep, idx, insn)
    return false unless insn.reg

    irep.walk_writers(idx - 1, (insn.reg.to_i + 1).to_s, follow_moves: true) do |writer|
      writer.op == 'LOADSYM' && writer.sym.to_s.start_with?('@')
    end || false
  end

  def fail_numeric_ivar_groups(poisoned)
    wild = @numeric_wild_families
    writers = Set.new
    @registry.each_value do |defs|
      defs.each do |d|
        next unless d.kind == :ivar_accessor && d.irep.nil? && d.name.end_with?('=')

        writers << [numeric_family(d.owner), d.name.chomp('=')]
      end
    end
    @numeric_ivar_groups.each_value do |group|
      native_family = numeric_ivar_native_poisoned?(group.family, group.name)
      group.failed = native_family || poisoned.include?(group.name) || wild.include?(group.family) ||
                     writers.include?([group.family, group.name])
      group.structural = group.failed
    end
  end

  def numeric_ivar_native_poisoned?(family, name)
    scopes = @native_ivar_scopes[name]
    @outside_ivar_names.include?(name) && (scopes.nil? || scopes.any? { |owner| numeric_family(owner) == family })
  end

  # Tracked ivar names of +irep+, in a stable order: those with a live group and
  # those the compiler already embeds as a Fixnum field (IvarLayout, which keeps
  # them assigned before self is exposed).
  def numeric_ivar_slots(irep)
    return [] if @numeric_ivar_disabled || @numeric_irep_slots.nil?

    @numeric_irep_slots[irep.label] ||= begin
      owner = numeric_irep_owner[irep.label]
      if owner.nil? || owner.owner.end_with?('.singleton') || owner.owner.start_with?('<')
        []
      else
        fam = numeric_family(owner.owner)
        names = @numeric_ivar_groups.select { |(f, _), g| f == fam && !g.failed && g.readers.include?(irep.label) }
                                    .keys.map(&:last)
        irep.instructions.each do |insn|
          next unless insn.op == 'GETIV' || insn.op == 'SETIV'

          names << insn.ivar if insn.ivar && embed_type(owner.owner, insn.ivar) == :fixnum
        end
        names.uniq.sort
      end
    end
  end

  def numeric_ivar_group(irep, name)
    owner = numeric_irep_owner[irep.label]
    owner && @numeric_ivar_groups && @numeric_ivar_groups[[numeric_family(owner.owner), name]]
  end

  def numeric_embedded_fixnum_ivar?(irep, name)
    owner = numeric_irep_owner[irep.label]
    owner && embed_type(owner.owner, name) == :fixnum
  end

  # What a slot holds on entry: whatever any method may have stored, plus nil
  # unless every constructor assigns it before `self` escapes (see
  # numeric_ivar_assured?). An #initialize body runs before that assignment by
  # definition, so it always starts with nil possible.
  def numeric_ivar_entry_mask(irep, name)
    return NumericFlow::INT if numeric_embedded_fixnum_ivar?(irep, name)

    group = numeric_ivar_group(irep, name)
    return NumericFlow::OTHER unless group && !group.failed

    owner = numeric_irep_owner[irep.label]
    constructing = owner.name == 'initialize' && owner.irep == irep.label
    assured = !constructing && numeric_ivar_assured?(owner.owner, name)
    assured ? group.mask : group.mask | NumericFlow::NIL
  end

  def numeric_ivar_fact_mask(irep, name)
    return NumericFlow::INT if numeric_embedded_fixnum_ivar?(irep, name)

    group = numeric_ivar_group(irep, name)
    group && !group.failed ? group.mask : NumericFlow::OTHER
  end

  def invalidate_numeric_ivar_readers(group)
    group.readers.each do |label|
      numeric_invalidate(label)
      @numeric_irep_slots.delete(label)
    end
  end

  # One growth pass over every group; true when anything changed. A group's mask
  # is the join of every value any SETIV stores; it fails for good when a site
  # stores an unmodelled class or sits in an irep the flow cannot model.
  def grow_numeric_ivar_groups
    return false if @numeric_ivar_disabled

    changed = false
    @numeric_ivar_groups.each_value do |group|
      next if group.failed

      joined = 0
      ok = true
      group.sites.each do |irep, idx, reg|
        mask = numeric_raw_mask(irep, idx, reg, numeric_irep_owner[irep.label])
        if mask.nil? || (mask & NumericFlow::OPAQUE) != 0
          ok = false
          break
        end
        joined |= mask
      end
      if !ok
        group.failed = true
      elsif (joined | group.mask) == group.mask
        next
      else
        group.mask |= joined
      end
      invalidate_numeric_ivar_readers(group)
      changed = true
    end
    changed
  end

  # ---------------------------------------------------------------------------
  # Constructor assurance: does every instance of +owner+ (a declared class) or
  # of a descendant have +ivar+ assigned before any method but #initialize can
  # run on it? Then a read outside #initialize never sees the nil of an
  # unassigned slot.
  #
  # Objects come from Class#new (standard_constructor_lookup?: no `allocate`
  # or `new` is redefined or installed; Marshal.load of hostile data is outside
  # the model, as for every embedded ivar). For each class K in the subtree:
  #   * the #initialize K resolves to (its own, else the superclass's) must
  #     assign the ivar on every path before `self` can reach other code
  #     (BytecodeIR's INIT_ASSIGNED must-analysis, ADR 0261), where a `super`
  #     counts as an assignment when the superclass assures it, and as harmless
  #     when the superclass's #initialize never lets `self` out;
  #   * K has exactly one #initialize, no prepend, no included module defining
  #     one, and its superclass resolves to a declared class or to Object.
  # A class with no #initialize anywhere assures nothing (Object#initialize is
  # native).
  # ---------------------------------------------------------------------------
  def numeric_ivar_assured?(owner, ivar)
    @numeric_assured ||= {}
    key = [owner, ivar]
    return @numeric_assured[key] if @numeric_assured.key?(key)

    @numeric_assured[key] = numeric_ivar_assured_uncached?(owner, ivar)
  end

  # No `allocate` (which makes an object #initialize never saw) is called or named
  # anywhere in the closed world.
  def numeric_allocate_free?
    return @numeric_allocate_free unless @numeric_allocate_free.nil?

    @numeric_allocate_free = @ireps.each_value.none? do |irep|
      irep.instructions.any? { |i| i.sym == 'allocate' && (i.op == 'LOADSYM' || i.op.include?('SEND')) }
    end
  end

  def numeric_ivar_assured_uncached?(owner, ivar)
    return false unless numeric_allocate_free?
    return false unless @closed_world.class_declared?(owner) && @closed_world.standard_constructor_lookup?

    hierarchy = @closed_world.class_hierarchy(owner)
    return false unless hierarchy && hierarchy[:wild].empty?

    ([owner] + hierarchy[:descendants].to_a).all? { |k| numeric_init_assures?(k, ivar, Set.new) }
  end

  # The MethodDef of +klass+'s own #initialize, nil when it defines none, or
  # :unknown when something (prepend, an included module's #initialize, several
  # definitions, a native body) makes the answer unusable.
  def numeric_init_definition(klass)
    return :unknown unless (Array(@prepended_modules[klass]).empty? &&
                         Array(@included_modules[klass]).none? { |m| (@registry['initialize'] || []).any? { |d| d.owner == m } })

    defs = (@registry['initialize'] || []).select { |d| d.owner == klass }
    return nil if defs.empty?
    return :unknown unless defs.one? && defs.first.irep && @ireps[defs.first.irep]

    defs.first
  end

  def numeric_init_assures?(klass, ivar, seen)
    return false unless seen.add?(klass)

    definition = numeric_init_definition(klass)
    return false if definition == :unknown

    parent = @superclass_of[klass]
    if definition.nil?
      return parent.is_a?(String) && numeric_init_assures?(parent, ivar, seen)
    end

    super_ok = parent.is_a?(String) && super_reaches_superclass?(definition)
    super_assigns = super_ok && numeric_init_assures?(parent, ivar, seen.dup)
    super_free = !parent.is_a?(String) ? parent == :none : super_ok && numeric_init_exposure_free?(parent, Set.new)
    program = BytecodeIR.for(@ireps[definition.irep])
    numeric_assigned_before_exposure?(program, ivar, super_assigns, super_assigns || super_free)
  end

  # BytecodeIR::Program#ivar_assigned_before_exposure? with `super` modelled: it
  # assigns when +super_assigns+, and lets `self` out only unless +super_safe+.
  def numeric_assigned_before_exposure?(program, ivar, super_assigns, super_safe)
    preds = program.instruction_predecessors(include_handlers: true) or return false

    insns = program.instructions
    out = Array.new(insns.length, true)
    before = lambda do |i|
      reached = preds[i].map { |p| p == BytecodeIR::ENTRY ? false : out[p] }
      reached.empty? || reached.all?
    end
    changed = true
    while changed
      changed = false
      insns.each do |instruction|
        i = instruction.index
        insn = instruction.source
        assigned = before.call(i) || (insn.op == 'SETIV' && insn.ivar == ivar) ||
                   (insn.op == 'SUPER' && super_assigns)
        next if out[i] == assigned

        out[i] = assigned
        changed = true
      end
    end
    insns.all? do |instruction|
      insn = instruction.source
      exposing = BytecodeIR::Program::SELF_EXPOSING_OPS.include?(insn.op) && !(insn.op == 'SUPER' && super_safe)
      observes = BytecodeIR::Program::FRAME_EXIT_OPS.include?(insn.op) || exposing ||
                 (insn.op == 'GETIV' && insn.ivar == ivar) ||
                 (!%w[GETIV SETIV].include?(insn.op) && insn.regs.include?('0'))
      before.call(instruction.index) || !observes
    end
  end

  # Does the #initialize +klass+ resolves to never let `self` reach other code?
  def numeric_init_exposure_free?(klass, seen)
    return false unless seen.add?(klass)

    definition = numeric_init_definition(klass)
    return false if definition == :unknown

    parent = @superclass_of[klass]
    if definition.nil?
      return parent == :none || (parent.is_a?(String) && numeric_init_exposure_free?(parent, seen))
    end

    super_ok = parent.is_a?(String) && super_reaches_superclass?(definition)
    super_free = parent.is_a?(String) ? super_ok && numeric_init_exposure_free?(parent, seen) : parent == :none
    @ireps[definition.irep].instructions.all? do |insn|
      next super_free if insn.op == 'SUPER'

      !BytecodeIR::Program::SELF_EXPOSING_OPS.include?(insn.op) &&
        (%w[GETIV SETIV].include?(insn.op) || !insn.regs.include?('0'))
    end
  end
end
