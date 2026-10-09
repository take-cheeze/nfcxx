# frozen_string_literal: true

require 'set'
require_relative 'bytecode_ir'
require_relative 'literal_element_proof'

# NUMERIC_FLOW (ADR 0276): a forward dataflow over one irep that says which
# registers provably hold an Integer (fixnum or bigint), a Float, an exact
# Array/Hash/String or nil at each instruction. It is the unguarded proof behind
# dropping the dynamic-send else of the guarded arithmetic and compare arms; it
# never trusts a hint or a runtime guard.
#
# Lattice per register: the set of classes the register may hold.
#   INT   an Integer (fixnum OR bigint -- never assume it fits mrb_int)
#   FLT   a Float
#   ARR   exactly ::Array (not a subclass)
#   HSH   exactly ::Hash
#   STR   exactly ::String
#   NIL   nil
#   OTHER anything else, including false and an unassigned local's other uses
#   RNG   exactly ::Range; EXC a pending exception object (what EXCEPT reads); and the bits from 1 << 9 up: exactly one closed-world class each
#         (CodeGen#numeric_class_bit). They enter through a proven `Klass.new`, a Range literal, or a true, false or
#         Symbol literal (LOADTRUE, LOADFALSE, LOADSYM: TrueClass, FalseClass, Symbol) and reach other methods only
#         through return values (ADR 0289) or the class pools. FalseClass is the one falsy class bit: a truthiness
#         test leaves it on the falsy edge only. The oracle's false_class_bit names it; an oracle that names none
#         keeps every class bit on both edges (falsy_class_bits).
# Bits from OBJECT_KIND_BASE up are object kinds the oracle names (LcfRowFlow, ADR 0294): each is
# "exactly an instance of that kind" and truthy, like ARR. Unlike the class bits they ride through
# pooled arguments, ivars and constants; what a bit means, and what `[]` on it returns, is the
# oracle's (`index_mask`).
# 0 is "no value yet" (unreached). Join is bitwise OR, so the answer cannot
# depend on visiting order. A register is numeric when its set is a non-empty
# subset of INT|FLT.
#
# Instance variables the compiler tracks ride along as extra registers past the
# real ones ("slots"), so `@i = 0; ... @i + 1` and a loop-carried `@i += 1`
# are ordinary dataflow. What another method may store into a slot is bounded by
# the whole-program fact the oracle supplies (ADR 0276). A register loaded
# from a slot or copied from another register remembers it (its provenance)
# until either changes, so `return unless @x` narrows the slot the test read and
# `r ? r + 1 : 0` the variable behind the copy the test used, not only the
# temporary.
module NumericFlow
  INT = 1
  FLT = 2
  ARR = 4
  HSH = 8
  STR = 16
  NIL = 32
  OTHER = 64
  RNG = 128
  EXC = 256
  NUM = INT | FLT
  CONTAINERS = ARR | HSH | STR
  FALSY = NIL | OTHER
  CLASS_BIT_BASE = 9
  # LCF object kinds (LcfRowFlow) live above every class bit; CodeGen#numeric_class_bit refuses to grow into them.
  OBJECT_KIND_BASE = 320
  CLASS_BITS = ((1 << OBJECT_KIND_BASE) - 1) & (-1 << CLASS_BIT_BASE)
  # Bits a fact outside one method (argument, ivar, constant) may not carry: OTHER, Range, EXC and
  # every class bit. Only return values ship them across methods. Object kinds are not among them.
  OPAQUE = OTHER | (((1 << OBJECT_KIND_BASE) - 1) & (-1 << 7))
  # Provenance, not a class (ADR 0370): the set came from a pool whose completeness is a runtime-checked claim. A mask
  # that carries it never equals a class bit, so every unguarded decoder refuses it; only CHECKED_POOL_EXACT reads it.
  CHECKED = 1 << (OBJECT_KIND_BASE - 1)

  module_function

  def numeric?(mask)
    mask.is_a?(Integer) && mask.positive? && (mask & ~NUM).zero?
  end

  def containers?(mask)
    mask.is_a?(Integer) && mask.positive? && (mask & ~CONTAINERS).zero?
  end

  # Result class of Integer/Float `+ - * /` (and `%`) on two operands, monotone in
  # both masks. +nil_raises+: nil has no such operator anywhere in the program, so
  # a nil operand only ever raises and contributes no value. Integer only for
  # Integer op Integer, Float as soon as either side may be a Float; an operand
  # of any other class makes the result unknown (OTHER); 0 when no value can flow
  # out (both paths raise, or an operand is unreached).
  def arith(left, right, nil_raises)
    unknown_bits = nil_raises ? ~(NUM | NIL) : ~NUM
    result = 0
    result |= OTHER if ((left | right) & unknown_bits).nonzero?
    ln = left & NUM
    rn = right & NUM
    if ln.nonzero? && rn.nonzero?
      result |= INT if (ln & rn & INT).nonzero?
      result |= FLT if ((ln | rn) & FLT).nonzero?
    end
    result
  end

  # Ops whose only effect on registers is writing their leading register (the
  # audited BytecodeIR::WRITES_LEADING_REG_OPS list), plus the read-only
  # leaders and the two a rescue clause adds: EXCEPT writes its leading register,
  # RESCUE its second. Any other op has no facts.
  SUPPORTED_OPS = (BytecodeIR::WRITES_LEADING_REG_OPS | BytecodeIR::READS_LEADING_REG_OPS |
                   Set['EXCEPT', 'RESCUE']).freeze
  # A callee frame starts at R(a) and may reuse every register above it.
  CALL_OPS = Set['SEND', 'SEND0', 'SENDB', 'SSEND', 'SSEND0', 'SSENDB', 'SUPER', 'EXEC', 'BLKCALL'].freeze
  # Leading register is only read (or the op writes an enclosing frame).
  NO_WRITE_OPS = Set['NOP', 'ENTER', 'JMP', 'JMPIF', 'JMPNOT', 'JMPNIL', 'RETURN', 'RETURN_BLK', 'RETSELF',
                     'RETNIL', 'RETTRUE', 'RETFALSE', 'BREAK', 'STOP', 'SETUPVAR', 'SETIDX', 'DEBUG',
                     'KEYEND', 'RAISEIF', 'MATCHERR'].freeze
  COND_BRANCHES = Set['JMPIF', 'JMPNOT', 'JMPNIL'].freeze
  # How many copies of one variable a recorded class test follows.
  CLASS_TEST_CHAIN_MAX = 8
  # How many branches on one test boolean a narrowed edge is carried through.
  CLASS_TEST_THREAD_MAX = 4
  ARITH_OPS = { 'ADD' => '+', 'SUB' => '-', 'MUL' => '*' }.freeze
  IMM_ARITH_OPS = { 'ADDI' => '+', 'SUBI' => '-', 'ADDILV' => '+', 'SUBILV' => '-' }.freeze
  # In-place container builders: the register keeps its exact class.
  KEEPS_CLASS = { 'ARYPUSH' => ARR, 'ARYCAT' => ARR, 'HASHADD' => HSH, 'HASHCAT' => HSH, 'STRCAT' => STR }.freeze

  # The facts the compiler proves elsewhere, as an object answering:
  #   entry_mask(irep, reg)                class set of an incoming argument
  #   const_mask(insn)                     class set of a GETCONST/GETMCNST
  #   ivar_slots(irep)                     tracked ivar names (see above)
  #   ivar_entry_mask(irep, name)          a slot's mask on method entry
  #   ivar_fact_mask(irep, name)           what any callee may leave in a slot
  #   send_mask(irep, index, insn, state)  class set of a SEND-family result
  #   upvar_mask(irep, insn)               class set of a GETUPVAR (a captured local)
  #   pool_mask(irep, insn)                class set of a LOADL
  #   index_mask(irep, index, insn, state) class set of a GETIDX/GETIDX0 result (optional)
  #   aref_mask(irep, index, insn, state)  class set of an AREF result (optional; TUPLE_RETURN_FACTS)
  #   op_native?(symbol)                   `+ - * /` are the core Integer/Float bodies
  #   nil_raises?(symbol)                  nil answers `symbol` only by raising
  # Each answers OTHER (or false) when it proves nothing.
  #
  # Returns index -> state (an Array of masks, nil for an unreachable
  # instruction), or nil when the irep is not modelled. Slots follow the
  # nregs real registers, in ivar_slots order. +writes+, when given, receives for
  # each register the union of every value any instruction stores into it (what
  # a block created earlier may see when it runs later).
  def states(irep, oracle, opaque_regs, writes = nil)
    program = BytecodeIR.for(irep)
    return nil unless program.resolved?
    return nil if program.handlers? && !program.handlers_resolved?

    insns = irep.instructions
    return nil if insns.empty?
    return nil unless insns.all? { |i| SUPPORTED_OPS.include?(i.op) || i.op.start_with?('LOADI') }

    nregs = [irep.nregs.to_i, 1].max
    slots = oracle.ivar_slots(irep)
    ctx = { irep: irep, oracle: oracle, opaque: opaque_regs, nregs: nregs, slots: slots,
            slot_of: slots.each_with_index.to_h { |name, k| [name, nregs + k] },
            facts: slots.map { |name| oracle.ivar_fact_mask(irep, name) },
            prov_base: nregs + slots.size, writes: writes }
    # CLASS_NARROWING (ADR 0375): a third block of nregs entries after the provenance, one per register, naming the
    # class test whose boolean result the register holds. Off (nil) unless the oracle can recognise a test.
    if oracle.respond_to?(:class_narrowing_active?) && oracle.class_narrowing_active?
      ctx[:test_base] = ctx[:prov_base] + nregs
      ctx[:tests] = []
      ctx[:test_ids] = {}
      # A constant lookup runs Ruby only through const_missing; without one, `is_a?(Foo)` does not forget the ivars.
      ctx[:const_quiet] = oracle.respond_to?(:const_lookup_quiet?) && oracle.const_lookup_quiet?
    end
    extra = enter_edges(irep)
    raises = program.handler_edges.group_by(&:src).transform_values { |edges| edges.map(&:target).uniq }
    # A rescue target is entered only by a raise, so its EXCEPT always reads an exception; an ensure
    # target is also reached by falling in, where there is none.
    by_kind = program.handler_edges.group_by(&:kind).transform_values { |edges| edges.map(&:target).to_set }
    ctx[:rescue_only] = by_kind.fetch(:rescue, Set.new) - by_kind.fetch(:ensure, Set.new)
    entry = Array.new(nregs, OTHER)
    entry[0] = oracle.self_mask if oracle.respond_to?(:self_mask)
    (1..nregs - 1).each do |r|
      m = oracle.entry_mask(irep, r)
      entry[r] = m if m && !opaque_regs.include?(r.to_s)
    end
    slots.each { |name| entry << oracle.ivar_entry_mask(irep, name) }
    nregs.times { entry << 0 } # provenance: which slot (+1) each register was loaded from
    nregs.times { entry << 0 } if ctx[:test_base] # class tests: which test each register's boolean holds

    ins = Array.new(insns.length)
    outs = Array.new(insns.length)
    ins[0] = entry
    work = [0]
    queued = Set[0]
    until work.empty?
      i = work.shift
      queued.delete(i)
      st = ins[i]
      next unless st

      out = transfer(i, insns[i], st, ctx)
      # Every instruction of a protected range may raise into its handler, where the registers
      # are as they were at the raise (ADR 0289): the state before the op, widened by what a
      # callee can do, or after it.
      raises.fetch(i, []).each do |target|
        edge = raise_state(insns[i], st, out, ctx)
        merged = join_state(ins[target], edge, ctx[:prov_base])
        next if merged == ins[target]

        ins[target] = merged
        work << target if queued.add?(target)
      end
      next if outs[i] == out

      outs[i] = out
      targets = if oracle.respond_to?(:context_enter_edges) && oracle.context_enter_edges.key?(i)
                  oracle.context_enter_edges.fetch(i)
                else
                  successors(program, extra, i)
                end
      # A call that never returns (`raise`) has no normal successor; its handler edges are above.
      targets = [] if oracle.respond_to?(:noreturn_call?) && oracle.noreturn_call?(irep, i, insns[i])
      targets.each do |s|
        edge = refine_edge(program, insns[i], i, s, out, ctx)
        next unless edge

        s = thread_class_test(program, insns, insns[i], i, s, edge, ctx) if ctx[:test_base]
        merged = join_state(ins[s], edge, ctx[:prov_base])
        next if merged == ins[s]

        ins[s] = merged
        work << s if queued.add?(s)
      end
    end
    ins
  end

  # The state a handler starts from when +insn+ raises. A callee frame starts at R(a) and may
  # reuse every register from there up; any Ruby the op runs may have stored into an ivar.
  def raise_state(insn, before, after, ctx)
    state = before
    if CALL_OPS.include?(insn.op)
      state = before.dup
      (insn.reg.to_i...ctx[:nregs]).each { |r| state[r] = OTHER }
      refresh_slots(state, ctx)
    elsif silent_call?(insn, before, ctx)
      state = before.dup
      refresh_slots(state, ctx)
    end
    join_state(state, after, ctx[:prov_base])
  end

  def successors(program, extra, index)
    base = program.instruction_at(index).successors
    more = extra[index]
    more ? (base | more) : base
  end

  # OP_ENTER with optional arguments jumps into a table of JMPs that follows
  # it; the disassembly shows no edge, so every table slot is a successor.
  def enter_edges(irep)
    edges = {}
    irep.instructions.each_with_index do |insn, i|
      next unless insn.op == 'ENTER'

      opt = insn.enter_fields[1].to_i
      next if opt.zero?

      edges[i] = (1..(opt + 1)).map { |k| i + k }.select { |k| k < irep.instructions.length }
    end
    edges
  end

  # The state flowing along edge insn -> target: a conditional branch narrows the
  # tested register (and whatever it was loaded or copied from) by truthiness; nil
  # and false are the only falsy values. nil when the edge is infeasible.
  def refine_edge(program, insn, index, target, state, ctx)
    return refine_raiseif(insn, state) if insn.op == 'RAISEIF'
    return state unless COND_BRANCHES.include?(insn.op)

    goto = program.address_to_index[insn.branch_target]
    fall = index + 1
    return state if goto == fall || (target != goto && target != fall)

    taken = target == goto
    edge = narrow_chain(state, insn.reg.to_i, insn.op, taken, ctx, Set.new)
    return edge unless edge && ctx[:test_base] && insn.op != 'JMPNIL'

    narrow_by_class_test(edge, insn.reg.to_i, (insn.op == 'JMPIF') == taken, ctx)
  end

  # The edge out of `JMPIF R` / `JMPNOT R` into another branch on the same register R, which holds a class test's
  # boolean, already decides that branch (`a || b` and `a && b` in a condition compile to two of them): continue at
  # its successor, so the narrowing the edge carries is not joined away with the path that tests again.
  def thread_class_test(program, insns, src, index, target, edge, ctx)
    return target unless src.op == 'JMPIF' || src.op == 'JMPNOT'

    reg = src.reg.to_i
    id = edge[ctx[:test_base] + reg].to_i
    return target if id.zero? || !ctx[:tests].fetch(id - 1)[1].respond_to?(:narrow)

    goto = program.address_to_index[src.branch_target]
    return target if goto == index + 1 || (target != goto && target != index + 1)

    truth = (src.op == 'JMPIF') == (target == goto)
    CLASS_TEST_THREAD_MAX.times do
      branch = insns[target]
      break unless branch && (branch.op == 'JMPIF' || branch.op == 'JMPNOT') && branch.reg.to_i == reg

      jump = program.address_to_index[branch.branch_target]
      break if jump == target + 1

      target = (branch.op == 'JMPIF') == truth ? jump : target + 1
    end
    target
  end

  # CLASS_NARROWING (ADR 0375): the register tested by the branch holds the boolean of a class test, so on the edge
  # where it is +truth+ the tested value and every variable it was copied from (the chain, recorded when the test
  # ran) is narrowed by the test's predicate. nil when no value can take the edge.
  def narrow_by_class_test(state, reg, truth, ctx)
    id = state[ctx[:test_base] + reg].to_i
    return state if id.zero?

    codes, pred = ctx[:tests].fetch(id - 1)
    return state unless pred.respond_to?(:narrow)

    slots = ctx[:slots].size
    out = state
    codes.each do |code|
      at = code <= slots ? ctx[:nregs] + code - 1 : code - slots - 1
      mask = state[at]
      next if mask.nil? || mask.zero?

      narrowed = pred.narrow(mask, truth)
      return nil if narrowed.zero?
      next if narrowed == mask

      out = out.dup if out.equal?(state)
      out[at] = narrowed
    end
    out
  end

  # Remember that +reg+ holds the boolean of the class test +test+ ([subject offset, predicate]) of the SEND at
  # +index+, aimed at every variable the subject register was a copy of when the call started. A call clears the
  # provenance, so the chain (`case x`: the argument copies the case temporary, which copies x) is read here.
  def record_class_test(out, state, insn, test, ctx)
    a = insn.reg.to_i
    subject = a + test[0]
    return if subject >= ctx[:nregs]

    slots = ctx[:slots].size
    codes = []
    code = state[ctx[:prov_base] + subject].to_i
    while code.positive? && codes.size < CLASS_TEST_CHAIN_MAX
      if code > slots
        reg = code - slots - 1
        # At or above the callee frame, or captured: no longer (or never) the tested variable.
        break if reg >= a || ctx[:opaque].include?(reg.to_s) || codes.include?(code)

        codes << code
        code = state[ctx[:prov_base] + reg].to_i
      else
        codes << code
        break
      end
    end
    return if codes.empty?

    key = [codes.freeze, test[1]]
    id = (ctx[:test_ids][key] ||= (ctx[:tests] << key).size)
    out[ctx[:test_base] + a] = id
  end

  def record_class_eq(out, insn, index, id, ctx)
    codes, marker = ctx[:tests].fetch(id - 1)
    a = insn.reg.to_i
    b = insn.paren_reg.to_i
    oracle = ctx[:oracle]
    return if b >= ctx[:nregs] || codes.include?(ctx[:slots].size + 1 + a) || !oracle.respond_to?(:class_eq_test)
    # The guard of an EQ reads the subject from a register: an ivar-only chain is not narrowed.
    return if codes.none? { |code| code > ctx[:slots].size }

    pred = oracle.class_eq_test(ctx[:irep], index, insn, marker)
    return unless pred

    key = [codes, pred]
    out[ctx[:test_base] + a] = (ctx[:test_ids][key] ||= (ctx[:tests] << key).size)
    oracle.note_class_test(ctx[:irep], index, codes, ctx[:slots].size, pred) if oracle.respond_to?(:note_class_test)
  end

  # Forget every test aimed at provenance +code+ (the variable it narrows was rewritten).
  def clear_class_tests(out, ctx, code)
    ctx[:nregs].times do |q|
      id = out[ctx[:test_base] + q]
      out[ctx[:test_base] + q] = 0 if id.positive? && ctx[:tests].fetch(id - 1)[0].include?(code)
    end
  end

  # `RAISEIF Ra` raises unless Ra is nil, so the fall-through edge holds only a nil (or unknown) Ra.
  def refine_raiseif(insn, state)
    reg = insn.reg.to_i
    mask = state[reg]
    return state if mask.nil? || mask.zero?

    narrowed = mask & FALSY
    return nil if narrowed.zero?

    return state if narrowed == mask

    out = state.dup
    out[reg] = narrowed
    out
  end

  # Provenance values: 0 none, 1..K slot k-1, K+1+r register r.
  def narrow_chain(state, reg, op, taken, ctx, seen)
    return state unless seen.add?(reg)

    mask = state[reg]
    return state if mask.nil? || mask.zero?

    sure, maybe = falsy_class_bits(ctx)
    narrowed = narrow_by_truth(op, taken, mask, sure, maybe)
    return nil if narrowed.zero?

    out = state
    if narrowed != mask
      out = state.dup
      out[reg] = narrowed
    end
    prov = state[ctx[:prov_base] + reg].to_i
    slots = ctx[:slots].size
    if prov.positive? && prov <= slots
      slot = ctx[:nregs] + prov - 1
      slot_narrowed = narrow_by_truth(op, taken, state[slot], sure, maybe)
      return nil if slot_narrowed.zero? && !state[slot].zero?

      if slot_narrowed != state[slot]
        out = out.dup if out.equal?(state)
        out[slot] = slot_narrowed
      end
    elsif prov > slots
      out = narrow_chain(out, prov - slots - 1, op, taken, ctx, seen)
    end
    out
  end

  # [definitely falsy, possibly falsy] class bits. FalseClass is the only class bit that is falsy, and it is falsy for
  # sure. An oracle that does not name it leaves every class bit possibly falsy and none definitely falsy.
  def falsy_class_bits(ctx)
    oracle = ctx[:oracle]
    return [0, CLASS_BITS] unless oracle.respond_to?(:false_class_bit)

    bit = oracle.false_class_bit.to_i
    [bit, bit]
  end

  # The class bit of a true, false or Symbol literal, or OTHER when the oracle names none.
  def literal_class_mask(insn, ctx)
    oracle = ctx[:oracle]
    (oracle.respond_to?(:literal_class_mask) && oracle.literal_class_mask(insn)) || OTHER
  end

  # A truthy edge drops nil and the definitely falsy class bits; a falsy edge keeps nil, OTHER and the possibly falsy
  # class bits. JMPNIL needs no class bits: only nil is nil.
  def narrow_by_truth(op, taken, mask, sure, maybe)
    case op
    when 'JMPIF' then taken ? mask & ~(NIL | sure) : mask & (FALSY | maybe)
    when 'JMPNOT' then taken ? mask & (FALSY | maybe) : mask & ~(NIL | sure)
    else taken ? (mask & FALSY).zero? ? 0 : NIL : mask & ~NIL # JMPNIL: nil exactly on the taken edge
    end
  end

  # Masks join by union; a provenance survives only when both sides agree.
  def join_state(old, new, prov_base)
    return new.dup if old.nil?

    joined = old.each_with_index.map do |m, r|
      r < prov_base ? m | new[r] : (m == new[r] ? m : 0)
    end
    joined == old ? old : joined
  end

  def transfer(index, insn, state, ctx)
    op = insn.op
    if NO_WRITE_OPS.include?(op)
      # SETIDX writes no register but may call a user #[]=.
      return state unless op == 'SETIDX' && silent_call?(insn, state, ctx)

      out = state.dup
      refresh_slots(out, ctx)
      return out
    end

    oracle = ctx[:oracle]
    irep = ctx[:irep]
    nregs = ctx[:nregs]
    pb = ctx[:prov_base]
    if op == 'SETIV'
      slot = ctx[:slot_of][insn.ivar]
      return state unless slot

      out = state.dup
      out[slot] = state[insn.regs.first.to_i]
      # Registers loaded from the old value no longer mirror the slot.
      nregs.times { |r| out[pb + r] = 0 if out[pb + r] == slot - nregs + 1 }
      clear_class_tests(out, ctx, slot - nregs + 1) if ctx[:test_base]
      return out
    end

    reg = insn.reg
    a = reg&.to_i
    return state if a.nil? || a >= nregs

    out = state.dup
    slot_count = ctx[:slots].size
    writes = ctx[:writes]
    set = lambda do |r, mask|
      out[r] = ctx[:opaque].include?(r.to_s) ? OTHER : mask
      writes[r] = (writes[r] || 0) | out[r] if writes
      out[pb + r] = 0
      # Registers that mirrored the old value of r no longer do.
      nregs.times { |q| out[pb + q] = 0 if out[pb + q] == slot_count + 1 + r }
      if ctx[:test_base]
        out[ctx[:test_base] + r] = 0
        clear_class_tests(out, ctx, slot_count + 1 + r)
      end
    end

    if CALL_OPS.include?(op)
      # A block result needs its own proof: `break` replaces the callee's answer.
      mask = if %w[SEND SEND0 SSEND SSEND0].include?(op)
               oracle.send_mask(irep, index, insn, state)
             elsif %w[SENDB SSENDB].include?(op) && oracle.respond_to?(:block_send_mask)
               oracle.block_send_mask(irep, index, insn, state)
             elsif op == 'SUPER' && oracle.respond_to?(:super_mask)
               oracle.super_mask(irep, index, insn, state)
             else OTHER
             end
      test = ctx[:test_base] && %w[SEND SEND0].include?(op) ? oracle.class_test(irep, index, insn, state) : nil
      ((a + 1)...nregs).each { |r| out[r] = OTHER }
      preserve = oracle.respond_to?(:preserves_ivar_slots?) && oracle.preserves_ivar_slots?(irep, index, insn, state)
      if preserve
        nregs.times { |r| out[pb + r] = 0 } unless ctx[:test_base]
      else
        refresh_slots(out, ctx)
      end
      clobber_class_test_copies(out, ctx, a) if ctx[:test_base]
      set.call(a, mask)
      record_class_test(out, state, insn, test, ctx) if test
      return out
    end

    nil_raises = ->(sym) { oracle.nil_raises?(sym) }
    case op
    when /\ALOADI/
      set.call(a, INT)
    when 'LOADL'
      set.call(a, oracle.pool_mask(irep, insn))
    when 'LOADSELF'
      set.call(a, oracle.respond_to?(:loadself_mask) ? oracle.loadself_mask : OTHER)
    when 'LOADNIL'
      set.call(a, NIL)
    when 'LOADTRUE', 'LOADFALSE', 'LOADSYM'
      set.call(a, literal_class_mask(insn, ctx))
    when 'MOVE'
      src = insn.regs[1].to_i
      set.call(a, src < nregs ? state[src] : OTHER)
      # `a` now mirrors `src` (and whatever `src` mirrored is reached through it).
      if src < nregs && src != a && !ctx[:opaque].include?(a.to_s) && !ctx[:opaque].include?(src.to_s)
        out[pb + a] = slot_count + 1 + src
        copy_class_test(out, state, a, src, ctx) if ctx[:test_base]
      end
    when 'GETCONST', 'GETMCNST'
      set.call(a, oracle.const_mask(insn))
    when 'GETUPVAR'
      set.call(a, oracle.upvar_mask(irep, insn))
    when 'GETIV'
      slot = ctx[:slot_of][insn.ivar]
      set.call(a, slot ? state[slot] : OTHER)
      out[pb + a] = slot - nregs + 1 if slot && !ctx[:opaque].include?(a.to_s)
    when 'EXCEPT'
      set.call(a, ctx[:rescue_only].include?(index) ? EXC : EXC | NIL)
    when 'RESCUE'
      # Reads the exception in its first register, writes the match flag to its second.
      b = insn.regs[1].to_i
      set.call(b, OTHER) if b < nregs
    when 'RANGE_INC', 'RANGE_EXC'
      set.call(a, RNG)
    when 'ARRAY', 'ARRAY2'
      set.call(a, ARR)
    when 'HASH'
      set.call(a, HSH)
    when 'STRING'
      set.call(a, STR)
    when 'ARYPUSH', 'ARYCAT', 'HASHADD', 'HASHCAT', 'STRCAT'
      keep = KEEPS_CLASS.fetch(op)
      set.call(a, state[a] == keep ? keep : OTHER)
    when 'ADD', 'SUB', 'MUL'
      b = insn.paren_reg.to_i
      sym = ARITH_OPS.fetch(op)
      ok = oracle.op_native?(sym) && b < nregs
      set.call(a, ok ? arith(state[a], state[b], nil_raises.call(sym)) : OTHER)
    when 'ADDI', 'SUBI'
      sym = IMM_ARITH_OPS.fetch(op)
      set.call(a, oracle.op_native?(sym) ? arith(state[a], INT, nil_raises.call(sym)) : OTHER)
    when 'ADDILV', 'SUBILV'
      sym = IMM_ARITH_OPS.fetch(op)
      # R[b], R[b+1] are working space for the fallback method call.
      b = insn.regs[1].to_i
      [b, b + 1].each { |r| set.call(r, OTHER) if r < nregs }
      set.call(a, oracle.op_native?(sym) ? arith(state[a], INT, nil_raises.call(sym)) : OTHER)
    when 'DIV'
      b = insn.paren_reg.to_i
      ok = oracle.op_native?('/') && b < nregs
      set.call(a, ok ? arith(state[a], state[b], nil_raises.call('/')) : OTHER)
    when 'GETIDX', 'GETIDX0'
      literal = LiteralElementProof.mask(irep, index, ctx[:opaque])
      set.call(a, literal || (oracle.respond_to?(:index_mask) ? oracle.index_mask(irep, index, insn, state) : OTHER))
    when 'AREF'
      set.call(a, oracle.respond_to?(:aref_mask) ? oracle.aref_mask(irep, index, insn, state) : OTHER)
    when 'EQ'
      # `x.class == C`: the class-of boolean meets a class constant, which makes it the instance_of test of x.
      id = ctx[:test_base] ? state[ctx[:test_base] + a].to_i : 0
      set.call(a, OTHER)
      record_class_eq(out, insn, index, id, ctx) if id.positive?
    else
      set.call(a, OTHER)
    end
    refresh_slots(out, ctx) if silent_call?(insn, state, ctx)
    out
  end

  # Non-call ops that dispatch to Ruby the flow does not follow, with the same `self`
  # (ADR 0276 addendum): an operator on a non-number, an index on anything but an exact
  # Array with an Integer index, interpolation, hash/array splat, range or constant lookup.
  SILENT_CALL_OPS = Set['ADD', 'SUB', 'MUL', 'DIV', 'EQ', 'LT', 'LE', 'GT', 'GE', 'GETIDX', 'GETIDX0', 'SETIDX',
                        'STRCAT', 'HASH', 'HASHADD', 'HASHCAT', 'ARYCAT', 'ARYSPLAT', 'AREF', 'RANGE_INC',
                        'RANGE_EXC', 'GETCONST', 'GETMCNST'].freeze

  # Judged on the state before the op, whose operands are still intact.
  def silent_call?(insn, state, ctx)
    return false unless SILENT_CALL_OPS.include?(insn.op)
    return false if ctx[:slots].empty?
    return false if ctx[:const_quiet] && (insn.op == 'GETCONST' || insn.op == 'GETMCNST')

    a = insn.reg.to_i
    at = ->(r) { r < ctx[:nregs] ? state[r] : nil }
    plain = ->(m) { m.is_a?(Integer) && m.positive? && (m & ~NUM).zero? }
    case insn.op
    when 'ADD', 'SUB', 'MUL', 'DIV', 'EQ', 'LT', 'LE', 'GT', 'GE'
      !(plain.call(at.call(a)) && plain.call(at.call(insn.paren_reg.to_i)))
    when 'GETIDX', 'SETIDX' then !(at.call(a) == ARR && at.call(a + 1) == INT)
    when 'GETIDX0' then at.call(insn.regs[1].to_i) != ARR
    when 'STRCAT' then at.call(a + 1) != STR
    else true
    end
  end

  # Every slot may now hold what any callee could have stored, and no register still
  # mirrors a slot.
  def refresh_slots(out, ctx)
    nregs = ctx[:nregs]
    ctx[:facts].each_with_index { |fact, k| out[nregs + k] |= fact }
    if ctx[:test_base]
      # CLASS_NARROWING: a call cannot write a local no block captures, so two registers that held the same value
      # still do; only the copies of a slot are forgotten (and, in the call, the callee's frame).
      slots = ctx[:slots].size
      nregs.times { |r| out[ctx[:prov_base] + r] = 0 if out[ctx[:prov_base] + r] <= slots }
      slots.times { |k| clear_class_tests(out, ctx, k + 1) }
    else
      nregs.times { |r| out[ctx[:prov_base] + r] = 0 }
    end
  end

  # The callee frame starts at R(a): whatever mirrored a register from there up, or was tested through one, is gone.
  def clobber_class_test_copies(out, ctx, a)
    slots = ctx[:slots].size
    pb = ctx[:prov_base]
    tb = ctx[:test_base]
    ctx[:nregs].times do |q|
      code = out[pb + q]
      out[pb + q] = 0 if q >= a || (code > slots && code - slots - 1 >= a)
      id = out[tb + q]
      next unless id.positive?

      codes = ctx[:tests].fetch(id - 1)[0]
      out[tb + q] = 0 if q > a || codes.any? { |c| c > slots && c - slots - 1 >= a }
    end
  end

  # `v = x.is_a?(C)`: the copy holds the same boolean, unless the test was aimed at the register being overwritten.
  def copy_class_test(out, state, dst, src, ctx)
    id = state[ctx[:test_base] + src].to_i
    return if id.zero? || ctx[:tests].fetch(id - 1)[0].include?(ctx[:slots].size + 1 + dst)

    out[ctx[:test_base] + dst] = id
  end
end
