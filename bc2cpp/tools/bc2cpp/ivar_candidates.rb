# frozen_string_literal: true

require 'set'
require_relative 'bytecode_ir'
require_relative 'class_layout'

# IVAR_CANDIDATE: the type type_facts writes for a ClassLayout-traced ivar. Every member of the numeric family shares
# the slot, so the stores are joined across it. `nil` is added where a read may precede every store (see `type`).
module IvarCandidates
  module_function

  # Reflection that reaches an ivar by name without a GETIV or SETIV in the body that runs it. The scan cannot see
  # those accesses, so reflective_access says which names they can touch (see there).
  ALL_NAMES = :all
  REFLECTIVE_WRITES = %w[instance_variable_set remove_instance_variable].freeze
  NAME_READERS = %w[instance_variable_get instance_variable_defined?].freeze
  ATTR_READERS = %w[attr attr_reader attr_accessor].freeze
  # The first argument names a method or a Method object, run by name. A literal name outside REFLECTIVE_NAMES runs
  # an ordinary method, whose own body the scan sees.
  NAME_DISPATCH = %w[send __send__ public_send method public_method instance_method public_instance_method
                     define_method define_singleton_method].freeze
  # A string eval (no block) reads any ivar. A block form runs a block, and a read in a block is never store-first.
  EVAL_SENDS = %w[eval instance_eval class_eval module_eval].freeze
  REFLECTIVE_NAMES = (REFLECTIVE_WRITES + NAME_READERS + ATTR_READERS + NAME_DISPATCH + EVAL_SENDS).to_set.freeze

  # The per-compile index. `nil_write` answers whether a SETIV's source register holds nil on every path (the
  # predicate ClassLayout uses to skip `@x = nil`). `unstored_reads` answers, per irep and name, the GETIV indexes
  # some path reaches before any store (BytecodeIR::Program#unstored_ivar_reads); nil keeps every read.
  def index(ctx, gen, nil_write: method(:nil_literal_write?), unstored_reads: method(:unstored_reads))
    found_at = {}
    ctx.store_log.each { |(_owner, label, idx), entry| found_at[[label, idx]] = entry[1] }
    table = Hash.new { |h, k| h[k] = { classes: Set.new, unresolved: false, nil_store: false, read_owners: Set.new } }
    opaque = Set.new
    reflective = reflective_access(ctx.ireps)
    ctx.ireps.each do |label, irep|
      definer = gen.numeric_irep_owner[label]
      owner = definer&.owner
      irep.each_with_op('GETIV', 'SETIV') do |insn, idx|
        name = insn.ivar.to_s
        # Code no owner claims (a module body, say) may touch any owner's slot, so no candidate for this name is sound.
        next opaque << name unless owner

        entry = table[[gen.numeric_family(owner), name]]
        if insn.op == :GETIV
          next if store_first?(definer, label, irep, idx, name, reflective, unstored_reads)

          next entry[:read_owners] << owner
        end

        found = found_at[[label, idx]]
        if found
          entry[:classes] << found.to_s
        elsif found_at.key?([label, idx]) || !nil_write.call(irep, idx, insn.regs.first)
          entry[:unresolved] = true
        else
          entry[:nil_store] = true
        end
      end
    end
    { table: table, opaque: opaque, reflective: reflective }
  end

  # The ivar names reflection can reach, or ALL_NAMES when a reflective access may reach any ivar. The exact rule is
  # in docs/bc2cpp-ir-feedback.md (Boundaries); the scan cannot see these reads, so they disable the proof here.
  def reflective_access(ireps)
    names = Set.new
    ireps.each_value do |irep|
      BytecodeIR.for(irep).each_source do |insn, idx|
        case insn.op
        when :LOADSYM
          return ALL_NAMES if REFLECTIVE_NAMES.include?(insn.sym.to_s)
        when :SEND, :SENDB, :SSEND, :SSENDB
          found = reflective_send(irep, idx, insn)
          return ALL_NAMES if found == ALL_NAMES

          names.merge(found) if found
        end
      end
    end
    names.freeze
  end

  # nil for a send that is not reflective, ALL_NAMES or the Set of ivar names it reaches (see reflective_access).
  def reflective_send(irep, idx, insn)
    sym = insn.sym.to_s
    return nil unless REFLECTIVE_NAMES.include?(sym)
    return ALL_NAMES if REFLECTIVE_WRITES.include?(sym)
    if EVAL_SENDS.include?(sym)
      return BytecodeIR::Ops::B_SUFFIX_OPS.include?(insn.op) ? Set.new : ALL_NAMES
    end

    if NAME_DISPATCH.include?(sym)
      dispatched = literal_names(irep, idx, insn, 1) or return ALL_NAMES
      return REFLECTIVE_NAMES.include?(dispatched.first) ? ALL_NAMES : Set.new
    end

    # Each argument of NAME_READERS and ATTR_READERS is an ivar name (`:@x` or, for attr, `:x`).
    count = ATTR_READERS.include?(sym) ? insn.argc : 1
    names = literal_names(irep, idx, insn, count) or return ALL_NAMES
    names.map { |name| name.delete_prefix('@') }.to_set
  end

  # The Symbol names the first +count+ arguments of the send at +idx+ are proven to hold: every reaching definition
  # is a LOADSYM of that name. Nil when any argument is not provably one literal name (a splat, a parameter, a
  # String, two possible values), so the caller treats the send as computed.
  def literal_names(irep, idx, insn, count)
    return nil unless insn.reg && insn.argc && insn.argc >= count && count.positive?

    (1..count).map do |offset|
      defs = BytecodeIR.reaching_definitions(irep, idx, (insn.reg.to_i + offset).to_s, through_handlers: true, shared: true)
      return nil unless defs

      program = BytecodeIR.for(irep)
      writers = defs.map { |df| df.entry? ? nil : program.source_at(df.index) }
      return nil unless writers.all? { |writer| writer&.op == :LOADSYM }

      syms = writers.map { |writer| writer.sym.to_s }.uniq
      return nil unless syms.size == 1

      syms.first
    end
  end

  # A read is store-first when it sits in its owner's method body (a block's frame can be entered before any store) and
  # no path reaches it without a SETIV of +name+ first. Such a read yields a value some store wrote, so it adds no nil.
  # A reflective access to +name+ bypasses the scan, so it never qualifies (see reflective_access).
  def store_first?(definer, label, irep, idx, name, reflective, unstored_reads)
    return false if reflective == ALL_NAMES || reflective.include?(name) || definer.irep != label

    unstored = unstored_reads.call(irep, name)
    !unstored.nil? && !unstored.include?(idx)
  end

  def unstored_reads(irep, name) = BytecodeIR.for(irep).unstored_ivar_reads(name)

  # ClassLayout::UNKNOWN when the stores cannot be joined, nil when no store was traced for the ivar, else the
  # candidate type string (`A | B | nil`, the form BytecodeIR::Types.type_name and RBS export accept).
  def type(index, gen, owner, name)
    name = name.to_s
    return ClassLayout::UNKNOWN if index[:opaque].include?(name)

    entry = index[:table][[gen.numeric_family(owner), name]]
    return nil if entry.nil? || (entry[:classes].empty? && !entry[:unresolved])
    return ClassLayout::UNKNOWN if entry[:unresolved]

    nilable = nil_reachable?(index, gen, owner, name)
    (entry[:classes].sort + (nilable ? ['nil'] : [])).join(' | ')
  end

  # True when some read of +name+ may see the slot's nil: a reflected name, a `@x = nil` store, a read that is not
  # store-first (see store_first?) in a reader numeric_ivar_assured? does not clear, or a body the scan cannot read.
  # Reflection can read the slot from any body, so no assurance clears nil for a reflected name.
  def nil_reachable?(index, gen, owner, name)
    name = name.to_s
    return true if index[:opaque].include?(name)

    entry = index[:table][[gen.numeric_family(owner), name]]
    return true if entry.nil?

    reflected = index[:reflective] == ALL_NAMES || index[:reflective].include?(name)
    reflected || entry[:nil_store] || entry[:read_owners].any? { |reader| !gen.numeric_ivar_assured?(reader, name) }
  end

  # The embedded layout's type (+classes+, a type string such as `bool` or `Integer?`) with the nil that nil_reachable?
  # adds. IvarLayout joins every SETIV of the ivar, so +classes+ is right; it knows nothing of a read before the first
  # store, which type() would add. A type that already admits nil is returned as it is.
  def with_nil(index, gen, owner, name, classes)
    return classes if classes.split(' | ').include?('nil') || classes.end_with?('?')

    nil_reachable?(index, gen, owner, name) ? "#{classes} | nil" : classes
  end
end
