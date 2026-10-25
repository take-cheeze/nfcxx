# frozen_string_literal: true

require 'set'
require_relative 'bytecode_ir'
require_relative 'bytecode_ir_ops'

# NIL_NARROWING: the registers that cannot hold nil at an instruction, because every path
# to it passes a test or a call that only a non-nil value survives.
#
# A forward must-analysis over the IR's normal and handler edges. The state at an
# instruction is the set of facts proven on entry to it; the method entry proves none, a join keeps what every
# incoming edge proves, and an instruction no path reaches proves everything (vacuously). A fact is a register proven
# non-nil, a class fact [register, K], or an available copy [:copy, a, b] (a and b hold the same value). Along an edge
# out of instruction p:
#
#   * every fact about a register p may write is dropped (Program#may_write_at?: a write, a callee frame below it, an
#     unmodelled op);
#   * `MOVE a b` copies b's facts to a and makes a a copy of b and of every register b is a copy of;
#   * the edge a non-nil value takes adds the tested register and its copies: the fall-through of `JMPNOT r` (`if r`)
#     and of `JMPNIL r` (`r&.`), the jump of `JMPIF r` (`return unless r`, `next unless r`). An edge that is both the
#     jump and the fall-through adds nothing;
#   * the normal return of `SEND r :m` (SEND, SEND0, SENDB) adds the copies of r, when nil cannot answer m
#     (CodeGen#nil_unanswerable?: no Ruby, foreign or native definition of m on NilClass, Object, Kernel,
#     BasicObject or a module they include, no method_missing there, no computed install of m). `nil.m` then raises
#     NoMethodError, so a call that returns normally had a non-nil receiver; r itself now holds the result;
#   * a handler edge (an exception raised at p) drops what p may write and adds nothing: p did not complete;
#   * a JMPUW edge proves nothing (an ensure body may run on the way);
#   * IS_A_GUARD: the truthy edge of `JMPIF t` / `JMPNOT t` (the jump of JMPIF, the fall-through of JMPNOT) right
#     after `SEND t :is_a? n=1` (or :kind_of?) adds each copy of the receiver as an instance of the class K, and so
#     as non-nil, when +class_guard+ names K for that SEND (CodeGen#is_a_guard_class: the name is only Kernel's
#     native, the argument is a straight-line constant that names exactly the declared class K, and K has no
#     subclass) and the test is the SEND's own result: the SEND is the test's only predecessor (handler edges
#     included) and its edge into the test is not a handler edge;
#   * the normal edge out of a `raise` SSEND that +class_guard+ calls no-return (CodeGen#raise_never_returns?:
#     Kernel's native raise is the only definition) proves everything: no value takes it. This is what lets
#     `raise ... unless x.is_a?(K)` narrow the code after it, where the raise's own fall-through joins the jump.
#
# A register a nested block writes (SETUPVAR) is never proven and never a copy: a call can run the block.
module NilNarrowing
  module_function

  # The truthy edge of these is where an `is_a?` result held true (JMPNIL tests nil, not truth).
  TRUTH_TESTS = %i[JMPIF JMPNOT].freeze
  IS_A_NAMES = %w[is_a? kind_of?].freeze
  # Sends with an explicit receiver: the SEND family minus the self-receiver forms (SSEND*), which nil can answer too.
  RECEIVER_CALLS = (BytecodeIR::Ops::SEND - BytecodeIR::Ops::SELF_SEND).freeze

  # True when +reg+ (digits) cannot be nil on entry to instruction +idx+ of +irep+. +nil_unanswerable+ is a callable
  # answering whether nil cannot answer a method name (nil: no call narrows); +class_guard+ an object answering
  # #is_a_class(irep, send_index) (the class an `is_a?` SEND proves on its true edge, or nil) and
  # #raise_never_returns?(irep, index) (nil: no guard narrows and every call may return);
  # +cache+ (a Hash the caller owns, one per pair of callables) keeps each irep's states.
  def non_nil?(irep, idx, reg, nil_unanswerable, cache = {}, class_guard: nil)
    state = state_at(irep, idx, reg.to_s, nil_unanswerable, class_guard, cache)
    !state.nil? && (state == :all || state.include?(reg.to_s))
  end

  # IS_A_GUARD: true when +reg+ holds an instance of exactly +klass+ on entry to instruction +idx+, because every
  # path to it passes a true `x.is_a?(klass)` test of the value (+class_guard+ as for non_nil?).
  def instance_of?(irep, idx, reg, klass, nil_unanswerable, cache = {}, class_guard: nil)
    return false unless class_guard

    state = state_at(irep, idx, reg.to_s, nil_unanswerable, class_guard, cache)
    !state.nil? && (state == :all || state.include?([reg.to_s, klass]))
  end

  # The state on entry to +idx+, or nil when +reg+ is never proven (a nested block writes it) or the irep's edges
  # are not resolved.
  def state_at(irep, idx, reg, nil_unanswerable, class_guard, cache)
    return nil if BytecodeIR.own_upvar_written_regs(irep).include?(reg)

    states = cache.fetch(irep.label) do
      cache[irep.label] = compute(irep, nil_unanswerable || ->(_name) { false }, class_guard)
    end
    states && states[idx]
  end

  def compute(irep, nil_unanswerable, class_guard = nil)
    prog = BytecodeIR.for(irep)
    all_preds = prog.instruction_predecessors(include_handlers: true) or return nil
    normal_preds = prog.instruction_predecessors or return nil
    # An edge that is both a normal successor and a handler edge is taken as a handler edge.
    raised = prog.handler_edges.to_set { |edge| [edge.src, edge.target] }
    states = Array.new(prog.instructions.length, :all)
    env = { irep: irep, prog: prog, decoded: prog.decoded, nil_unanswerable: nil_unanswerable,
            class_guard: class_guard, opaque: BytecodeIR.own_upvar_written_regs(irep), all_preds: all_preds,
            raised: raised, states: states }
    loop do
      changed = false
      states.each_index do |i|
        acc = :all
        all_preds[i].each do |p|
          out = if p == BytecodeIR::ENTRY then Set.new
                else edge_out(env, states[p], p, i, normal_preds[i].include?(p) && !raised.include?([p, i]))
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

  def copy_fact?(fact)
    fact.is_a?(Array) && fact.first == :copy
  end

  def class_fact?(fact)
    fact.is_a?(Array) && fact.size == 2
  end

  # The registers a fact is about.
  def fact_regs(fact)
    return [fact] unless fact.is_a?(Array)

    copy_fact?(fact) ? fact.drop(1) : [fact.first]
  end

  def copy(a, b)
    a.to_i < b.to_i ? [:copy, a, b] : [:copy, b, a]
  end

  # Registers that hold the same value as +reg+ by +state+'s available copies.
  def partners(state, reg)
    state.filter_map do |f|
      next unless copy_fact?(f) && f.include?(reg)

      f[1] == reg ? f[2] : f[1]
    end
  end

  # The state along the edge p -> i (normal: a normal successor of p, else a handler edge).
  def edge_out(env, state, p, i, normal)
    return :all if state == :all
    return :all if normal && env[:class_guard]&.raise_never_returns?(env[:irep], p)

    prog = env[:prog]
    out = state.reject { |f| fact_regs(f).any? { |r| prog.may_write_at?(p, r) } }.to_set
    return out unless normal

    op = env[:decoded][p].op
    return Set.new if op == :JMPUW
    return move(env, state, out, p) if op == :MOVE

    tested = narrowed_register(env, p, i)
    return out unless tested

    ([tested] + partners(state, tested)).each do |r|
      out << r unless env[:opaque].include?(r) || prog.may_write_at?(p, r)
    end
    is_a_facts(env, p, tested).each { |f| out << f.first << f }
    out
  end

  # `MOVE dest src`: dest takes src's facts and becomes a copy of src and of every register src is a copy of.
  def move(env, state, out, p)
    dest, src = BytecodeIR::OperandModel.move(env[:prog].instruction_at(p).source).to_a
    return out unless dest && src && dest != src

    out << dest if state.include?(src)
    state.each { |f| out << [dest, f.last] if class_fact?(f) && f.first == src }
    return out if env[:opaque].include?(dest) || env[:opaque].include?(src)

    out << copy(dest, src)
    partners(state, src).each { |r| out << copy(dest, r) unless r == dest }
    out
  end

  # IS_A_GUARD: [b, K] for each copy b of the receiver of `SEND tested :is_a? K` at p - 1, when the edge out of the
  # truth test at p (already known to be the edge a truthy +tested+ takes) is that SEND's true edge.
  def is_a_facts(env, p, tested)
    guard = env[:class_guard]
    return [] unless guard && TRUTH_TESTS.include?(env[:decoded][p].op) && p.positive?
    # The test reads the SEND's result only when the SEND is its one way in, on a normal edge.
    return [] unless env[:all_preds][p].to_a == [p - 1] && !env[:raised].include?([p - 1, p])

    prog = env[:prog]
    send = prog.instruction_at(p - 1).source
    return [] unless send.op == :SEND

    call = BytecodeIR::OperandModel.send_call(send)
    return [] unless IS_A_NAMES.include?(call.name) && call.receiver == tested

    klass = guard.is_a_class(env[:irep], p - 1) or return []
    before = env[:states][p - 1]
    return [] if before == :all

    partners(before, tested).filter_map do |src|
      next if env[:opaque].include?(src) || prog.may_write_at?(p - 1, src) || prog.may_write_at?(p, src)

      [src, klass]
    end
  end

  # The register a non-nil value must be in for control to take the edge p -> i, or nil.
  def narrowed_register(env, p, i)
    d = env[:decoded][p]
    insn = env[:prog].instruction_at(p).source
    if d.cond
      return nil if d.goto.nil? || d.goto == p + 1

      taken = i == d.goto
      return BytecodeIR::OperandModel.test_reg(insn) if d.cond == BytecodeIR::COND_IF ? taken : !taken

      return nil
    end
    return nil unless RECEIVER_CALLS.include?(d.op)

    call = BytecodeIR::OperandModel.send_call(insn)
    return nil unless call.name && env[:nil_unanswerable].call(call.name)

    # The receiver register itself now holds the call's result: only its copies keep the receiver.
    call.receiver
  end
end
