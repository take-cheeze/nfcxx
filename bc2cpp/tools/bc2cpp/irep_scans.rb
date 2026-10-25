# frozen_string_literal: true

require_relative 'bytecode_ir_ops'
require_relative 'bytecode_ir_regions'

# Backward register scans over an Irep's instructions: the reaching-definition
# questions ("what wrote this register before here?") that every analysis pass
# asks. The walk and its index live on BytecodeIR::Program (bytecode_ir_regions.rb);
# these keep the Irep-side spelling the passes call and the queries built on it.
module IrepScans
  # Block results of #walk_writers: IrepScans.follow(reg) / KEEP.
  Follow = BytecodeIR::Follow
  KEEP = BytecodeIR::KEEP

  # A constant expression read back from a register (BytecodeIR::Program#constant_path).
  ConstantPath = BytecodeIR::ConstantPath

  # origin_ivar's walk steps over BLOCK's proc register and every lead-read-only op.
  ORIGIN_IVAR_SKIP_OPS = (BytecodeIR::Ops::LEAD_READ_ONLY | ['BLOCK']).freeze

  def self.follow(reg)
    Follow.new(reg)
  end

  # BytecodeIR::Program#walk_writers over this irep's instructions (options and
  # block protocol documented there).
  def walk_writers(from, reg, **options, &block)
    BytecodeIR.for(self).walk_writers(from, reg, **options, &block)
  end

  # JOIN_DOMINANCE: walk_writers whose every hop must dominate the
  # read it feeds (BytecodeIR.write_dominates?); a hop that does not ends the
  # walk with nil. +use+ is the instruction the first hop feeds.
  def walk_dominating_writers(from, reg, use: from + 1, follow_moves: false, exhausted: nil, **options)
    read = use
    entry = lambda do |last|
      BytecodeIR.write_dominates?(self, BytecodeIR::ENTRY, read, last) ? exhausted&.call(last) : nil
    end
    walk_writers(from, reg, exhausted: entry, **options) do |insn, index, cur|
      next nil unless BytecodeIR.write_dominates?(self, index, read, cur)

      read = index
      if follow_moves && insn.op == :MOVE
        IrepScans.follow(insn.regs[1])
      else
        yield insn, index, cur
      end
    end
  end

  # Index of the nearest instruction at or before +from+ whose leading register
  # operand is +reg+, or nil (BytecodeIR::Program#last_writer_index).
  def previous_lead_index(reg, from)
    BytecodeIR.for(self).last_writer_index(from, reg)
  end

  # BytecodeIR::Program#constant_path over this irep's instructions.
  def constant_path(from, reg, skip_ops: nil, barrier: nil)
    BytecodeIR.for(self).constant_path(from, reg, skip_ops: skip_ops, barrier: barrier)
  end

  # The constant name (`Name` or `Outer::Name`) that EVERY definition reaching
  # the read of +reg+ at instruction +use+ agrees on, through joins and loops
  # (BytecodeIR.reaching_definitions), or nil: a refused query, an entry value,
  # or any definition that is not a GETCONST (GETMCNST scopes chained the same
  # way) naming that same constant. Unlike #constant_path this does not stop at
  # a branch, so it also answers when unrelated branches sit between the load
  # and the use.
  # through_handlers: the query may sit inside a protected (rescue/ensure) range, whose handler edges the walk then
  # follows instead of refusing (BytecodeIR's handler-aware mode, as CONSTRUCTOR_POOLS uses it).
  def agreed_constant_name(use, reg, depth = 0, through_handlers: false)
    return nil if depth > CONSTANT_SCOPE_DEPTH

    defs = BytecodeIR.reaching_definitions(self, use, reg, through_handlers: through_handlers, shared: true)
    return nil if defs.nil? || defs.empty? || defs.any?(&:entry?)

    names = defs.map do |definition|
      insn = BytecodeIR.for(self).source_at(definition.index)
      case insn.op
      when :GETCONST then insn.const_name
      when :GETMCNST
        scope = agreed_constant_name(definition.index, insn.reg, depth + 1, through_handlers: through_handlers)
        scope && insn.mcnst_name && "#{scope}::#{insn.mcnst_name}"
      end
    end
    names.first if names.first && names.uniq.size == 1
  end
  CONSTANT_SCOPE_DEPTH = 4

  # The run of consecutive +op+ instructions ending at +from+ (inclusive), in
  # program order, at most +limit+ of them (the newest ones): the LOADSYMs of
  # `private :a, :b` sit right before the send.
  def preceding_run(op, from, limit: nil)
    BytecodeIR.for(self).run_of_op_ending(from, op, limit: limit)
  end

  # `Owner#@ivar` when the nearest defining instruction is a GETIV, else empty.
  def self.origin_ivar(irep, site, reg, owner_def)
    irep.walk_writers(site - 1, reg.to_s, skip_ops: ORIGIN_IVAR_SKIP_OPS) do |ins|
      next follow(ins.regs[1]) if ins.op == :MOVE && ins.regs[1]

      break "#{owner_def&.owner}#@#{ins.ivar}" if ins.op == :GETIV
    end.to_s
  end
end
