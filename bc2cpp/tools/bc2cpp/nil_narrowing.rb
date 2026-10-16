# frozen_string_literal: true

require 'set'
require_relative 'bytecode_ir'

# NIL_NARROWING (docs/adr/0456, third step): the registers that cannot hold nil at an instruction, because every path
# to it passes a test or a call that only a non-nil value survives.
#
# A forward must-analysis over the irep's normal and handler edges. The state at an instruction is the set of registers
# proven non-nil on entry to it; the method entry proves none, a join keeps what every incoming edge proves, and an
# instruction no path reaches proves everything (vacuously). Along an edge out of instruction p:
#
#   * every register p may write is dropped (Program#may_write?: a write, a callee frame below it, an unmodelled op);
#   * `MOVE a b` copies b's fact to a;
#   * the edge a non-nil value takes adds the tested register: the fall-through of `JMPNOT r` (`if r`) and of
#     `JMPNIL r` (`r&.`), the jump of `JMPIF r` (`return unless r`, `next unless r`). An edge that is both the jump and
#     the fall-through adds nothing;
#   * the normal return of `SEND r :m` (SEND, SEND0, SENDB) adds the register r was copied from, when nil cannot
#     answer m (CodeGen#nil_unanswerable?: no Ruby, foreign or native definition of m on NilClass, Object, Kernel,
#     BasicObject or a module they include, no method_missing there, no computed install of m). `nil.m` then raises
#     NoMethodError, so a call that returns normally had a non-nil receiver. A test of a register copied from a local
#     narrows the local the same way.
#   * a handler edge (an exception raised at p) drops what p may write and adds nothing: p did not complete;
#   * a JMPUW edge proves nothing (an ensure body may run on the way).
#
# "r was copied from b" means the nearest writer of r before p is `MOVE r b`, that write reaches p on every path
# (Program#write_dominates?), and nothing between them may write b. A register a nested block writes (SETUPVAR) is
# never proven: a call can run the block.
module NilNarrowing
  module_function

  TESTED_ON_FALLTHROUGH = %w[JMPNOT JMPNIL].freeze
  TESTED_ON_JUMP = %w[JMPIF].freeze
  RECEIVER_CALLS = %w[SEND SEND0 SENDB].freeze
  # Back-walk bound when looking for the MOVE a receiver or a tested register was copied by.
  COPY_WINDOW = 64

  # True when +reg+ (digits) cannot be nil on entry to instruction +idx+ of +irep+. +nil_unanswerable+ is a callable
  # answering whether nil cannot answer a method name (nil: no call narrows); +cache+ (a Hash the caller owns, one per
  # callable) keeps each irep's states.
  def non_nil?(irep, idx, reg, nil_unanswerable, cache = {})
    reg = reg.to_s
    return false if BytecodeIR.own_upvar_written_regs(irep).include?(reg)

    states = cache.fetch(irep.label) { cache[irep.label] = compute(irep, nil_unanswerable || ->(_name) { false }) }
    return false unless states

    state = states[idx]
    state == :all || state.include?(reg)
  end

  def compute(irep, nil_unanswerable)
    prog = BytecodeIR.for(irep)
    all_preds = prog.instruction_predecessors(include_handlers: true) or return nil
    normal_preds = prog.instruction_predecessors or return nil
    opaque = BytecodeIR.own_upvar_written_regs(irep)
    # An edge that is both a normal successor and a handler edge is taken as a handler edge.
    raised = prog.handler_edges.to_set { |edge| [edge.src, edge.target] }
    count = prog.instructions.length
    states = Array.new(count, :all)
    loop do
      changed = false
      prog.instructions.each do |instruction|
        i = instruction.index
        acc = :all
        all_preds[i].each do |p|
          out = if p == BytecodeIR::ENTRY then Set.new
                else
                  normal = normal_preds[i].include?(p) && !raised.include?([p, i])
                  edge_out(irep, prog, states[p], p, i, normal, nil_unanswerable, opaque)
                end
          acc = meet(acc, out)
        end
        next if acc == states[i]

        states[i] = acc
        changed = true
      end
      break unless changed
    end
    states.map { |s| s == :all ? s : s.freeze }.freeze
  end

  def meet(acc, out)
    return out if acc == :all
    return acc if out == :all

    acc & out
  end

  # The state along the edge p -> i (normal: a normal successor of p, else a handler edge).
  def edge_out(irep, prog, state, p, i, normal, nil_unanswerable, opaque)
    return :all if state == :all

    insn = prog.instructions[p].source
    out = state.reject { |r| prog.may_write?(insn, r) }.to_set
    return out unless normal
    return Set.new if insn.op == 'JMPUW'

    if insn.op == 'MOVE'
      dest, src = insn.regs
      out << dest if dest && src && state.include?(src)
      return out
    end

    tested = narrowed_register(insn, prog, p, i, nil_unanswerable)
    return out unless tested

    [tested, copy_source(irep, prog, p, tested)].compact.each do |r|
      next if opaque.include?(r) || prog.may_write?(insn, r)

      out << r
    end
    out
  end

  # The register a non-nil value must be in for control to take the edge p -> i, or nil.
  def narrowed_register(insn, prog, p, i, nil_unanswerable)
    op = insn.op
    if TESTED_ON_FALLTHROUGH.include?(op) || TESTED_ON_JUMP.include?(op)
      target = prog.address_to_index[insn.branch_target]
      return nil if target.nil? || target == p + 1

      taken = i == target
      return insn.reg if TESTED_ON_FALLTHROUGH.include?(op) ? !taken : taken

      return nil
    end
    return nil unless RECEIVER_CALLS.include?(op) && insn.sym && nil_unanswerable.call(insn.sym)

    # The receiver register itself now holds the call's result: only the register it was copied from keeps the
    # receiver (copy_source), and edge_out keeps the receiver only for that one.
    insn.reg
  end

  # The register +reg+ was copied from by the nearest write of +reg+ before +p+, when that `MOVE reg b` reaches +p+ on
  # every path and nothing in between may write b; else nil.
  def copy_source(irep, prog, p, reg)
    k = p - 1
    floor = [p - COPY_WINDOW, 0].max
    k -= 1 while k >= floor && !prog.may_write?(prog.instructions[k].source, reg)
    return nil if k < floor

    writer = prog.instructions[k].source
    return nil unless writer.op == 'MOVE' && writer.regs[0] == reg

    src = writer.regs[1]
    return nil unless src && BytecodeIR.write_dominates?(irep, k, p, reg)
    return nil if ((k + 1)...p).any? { |j| prog.may_write?(prog.instructions[j].source, src) }

    src
  end
end
