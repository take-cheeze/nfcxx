# frozen_string_literal: true

require 'set'
require_relative 'bytecode_ir'
require_relative 'class_scope'

# CONST_CONDITIONAL: the bare constant names some SETCONST/SETMCNST of which may not run (`NEVER = 9 if W == 0`, a write in
# a loop, a block, a rescue, after an early `return`, or in a body opened under a condition). A read of such a name may
# raise NameError however the name's bindings are valued, so no proof may stand in a value for the read
# (INTEGER_CONSTANT_VALUE_PROOF); a proof of the value's class stays sound, as a read that raises yields no value.
#
# A write is unconditional when the emitter's annotation says so (MrbcRb::Annotations.straight_nodes, `conditional: false`).
# Without an annotation it is unconditional only when its irep runs whenever the program loads (a root, or a body whose
# EXEC must run in a parent that does) and every path from the irep's entry to a normal exit passes it (must_run). Both
# answers are conservative. An exception no handler of the irep catches ends the load, so it is no path; an exit send
# (`raise`, `exit`) is counted as an exit all the same.
module ConstConditional
  # Sends that leave the statement list without an ordinary return, as the emitter's EXIT_CALLS.
  EXIT_SENDS = %w[raise fail throw exit exit! abort].to_set.freeze
  SEND_OPS = %i[SEND SEND0 SSEND SSEND0 SENDB SSENDB].to_set.freeze
  NO_FALLTHROUGH = BytecodeIR::NO_FALLTHROUGH.to_set.freeze
  BLOCK_SENDS = %i[SENDB SSENDB SUPER].to_set.freeze
  EXITS = BytecodeIR::Ops::FRAME_EXIT

  module_function

  # The bare names with a conditional write in +ireps+ (label => Irep, the whole program).
  def names(ireps)
    sites(ireps).filter_map { |(_label, _addr, name), conditional| name if conditional }.to_set
  end

  # { [label, address, bare name] => conditional? } for every SETCONST/SETMCNST of +ireps+.
  def sites(ireps)
    run = straight_ireps(ireps)
    out = {}
    ireps.each do |label, irep|
      graph = nil
      BytecodeIR.for(irep).each_with_op(:SETCONST, :SETMCNST) do |insn, idx|
        name = insn.op == :SETCONST ? insn.const_name : insn.mcnst_name
        next unless name

        op = irep.class_scope && ClassScope.op_at(irep, insn)
        out[[label, insn.addr, name.to_s]] = if op&.key?(:conditional)
                                               op[:conditional]
                                             else
                                               !run.include?(label) || !must_run?(graph ||= flow(irep), idx)
                                             end
      end
    end
    out
  end

  # The ireps that run whenever the program loads: every root, and a body whose EXEC must run in such a parent and is
  # covered by none of its handlers (one would catch an exception out of the body, which then stops short of its writes).
  def straight_ireps(ireps)
    children = ireps.each_value.flat_map { |irep| Array(irep.reps) }.to_set
    work = ireps.keys.reject { |label| children.include?(label) }
    run = Set.new
    until work.empty?
      label = work.pop
      next unless run.add?(label)

      irep = ireps.fetch(label)
      graph = nil
      BytecodeIR.for(irep).each_with_op(:EXEC) do |insn, idx|
        child = irep.reps[insn.block_index]
        covered = (irep.catch_handlers || []).any? { |h| insn.addr >= h.begin_addr && insn.addr < h.end_addr }
        work << child if child && !covered && must_run?(graph ||= flow(irep), idx)
      end
    end
    run
  end

  # [successors (index => [index]), exits (indices that end the irep normally)] of +irep+'s instructions: fall-through,
  # branch targets, and from every instruction a handler covers, that handler's target.
  def flow(irep)
    program = BytecodeIR.for(irep)
    index_of = {}
    insns = []
    program.each_source do |insn, idx|
      index_of[insn.addr] = idx
      insns << [insn, idx]
    end
    succ = Hash.new { |h, k| h[k] = [] }
    exits = Set.new
    handlers = irep.catch_handlers || []
    # A `return` in a block leaves this irep from the send that runs the block.
    block_exit = block_return?(irep)
    insns.each_with_index do |(insn, idx), pos|
      exits << idx if EXITS.include?(insn.op) || (SEND_OPS.include?(insn.op) && EXIT_SENDS.include?(insn.sym.to_s)) ||
                      (block_exit && BLOCK_SENDS.include?(insn.op))
      succ[idx] << insns[pos + 1][1] if insns[pos + 1] && !NO_FALLTHROUGH.include?(insn.op)
      if (target = insn.branch_target)
        # A target that is no instruction start is not modelled: every write of the irep is then conditional.
        return [nil, nil] unless index_of.key?(target)

        succ[idx] << index_of[target]
      end
      handlers.each do |handler|
        next unless insn.addr >= handler.begin_addr && insn.addr < handler.end_addr
        return [nil, nil] unless index_of.key?(handler.target)

        succ[idx] << index_of[handler.target]
      end
    end
    [succ, exits, insns.first&.last]
  end

  # Does a block +irep+ makes (BLOCK, and the blocks those make) hold a RETURN_BLK?
  def block_return?(irep)
    tree = irep.tree || {}
    work = [irep]
    until work.empty?
      at = work.pop
      BytecodeIR.for(at).each_with_op(:BLOCK) do |insn, _idx|
        child = tree[at.reps[insn.block_index]]
        return true unless child
        return true if BytecodeIR.for(child).op?(:RETURN_BLK)

        work << child
      end
    end
    false
  end

  # Does every path from the entry to an exit pass instruction +idx+? A search that may not enter +idx+ reaching an exit
  # says no.
  def must_run?(graph, idx)
    succ, exits, entry = graph
    return false if succ.nil? || entry.nil?
    return true if entry == idx

    seen = Set[entry]
    work = [entry]
    until work.empty?
      at = work.pop
      return false if exits.include?(at)

      succ[at].each { |nxt| work << nxt if nxt != idx && seen.add?(nxt) }
    end
    true
  end
end
