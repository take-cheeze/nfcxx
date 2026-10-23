# frozen_string_literal: true

require 'set'
require_relative 'class_layout'

# IVAR_CANDIDATE: the type type_facts writes for a ClassLayout-traced ivar. Every member of the numeric family shares
# the slot, so the stores are joined across it. `nil` is added where a read may precede every store (see `type`).
module IvarCandidates
  module_function

  # The per-compile index. `nil_write` answers whether a SETIV's source register holds nil on every path (the
  # predicate ClassLayout uses to skip `@x = nil`).
  def index(ctx, gen, nil_write: method(:nil_literal_write?))
    found_at = {}
    ctx.store_log.each { |(_owner, label, idx), entry| found_at[[label, idx]] = entry[1] }
    table = Hash.new { |h, k| h[k] = { classes: Set.new, unresolved: false, nil_store: false, read_owners: Set.new } }
    opaque = Set.new
    ctx.ireps.each do |label, irep|
      owner = gen.numeric_irep_owner[label]&.owner
      irep.each_with_op('GETIV', 'SETIV') do |insn, idx|
        name = insn.ivar.to_s
        # Code no owner claims (a module body, say) may touch any owner's slot, so no candidate for this name is sound.
        next opaque << name unless owner

        entry = table[[gen.numeric_family(owner), name]]
        next entry[:read_owners] << owner if insn.op == 'GETIV'

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
    { table: table, opaque: opaque }
  end

  # ClassLayout::UNKNOWN when the stores cannot be joined, nil when no store was traced for the ivar, else the
  # candidate type string (`A | B | nil`, the form BytecodeIR::Types.type_name and RBS export accept).
  def type(index, gen, owner, name)
    name = name.to_s
    return ClassLayout::UNKNOWN if index[:opaque].include?(name)

    entry = index[:table][[gen.numeric_family(owner), name]]
    return nil if entry.nil? || (entry[:classes].empty? && !entry[:unresolved])
    return ClassLayout::UNKNOWN if entry[:unresolved]

    nilable = entry[:nil_store] ||
              entry[:read_owners].any? { |reader| !gen.numeric_ivar_assured?(reader, name) }
    (entry[:classes].sort + (nilable ? ['nil'] : [])).join(' | ')
  end
end
