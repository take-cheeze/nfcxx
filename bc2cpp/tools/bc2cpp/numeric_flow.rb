# frozen_string_literal: true

require 'set'
require_relative 'bytecode_ir'

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
  NUM = INT | FLT
  CONTAINERS = ARR | HSH | STR
  FALSY = NIL | OTHER

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
  # leaders. Any other op, or an irep with a catch handler, has no facts.
  SUPPORTED_OPS = (BytecodeIR::WRITES_LEADING_REG_OPS | BytecodeIR::READS_LEADING_REG_OPS).freeze
  # A callee frame starts at R(a) and may reuse every register above it.
  CALL_OPS = Set['SEND', 'SEND0', 'SENDB', 'SSEND', 'SSEND0', 'SSENDB', 'SUPER', 'EXEC', 'BLKCALL'].freeze
  # Leading register is only read (or the op writes an enclosing frame).
  NO_WRITE_OPS = Set['NOP', 'ENTER', 'JMP', 'JMPIF', 'JMPNOT', 'JMPNIL', 'RETURN', 'RETURN_BLK', 'RETSELF',
                     'RETNIL', 'RETTRUE', 'RETFALSE', 'BREAK', 'STOP', 'SETUPVAR', 'SETIDX', 'DEBUG',
                     'KEYEND', 'RAISEIF', 'MATCHERR'].freeze
  COND_BRANCHES = Set['JMPIF', 'JMPNOT', 'JMPNIL'].freeze
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
    return nil if program.handlers?

    insns = irep.instructions
    return nil if insns.empty?
    return nil unless insns.all? { |i| SUPPORTED_OPS.include?(i.op) || i.op.start_with?('LOADI') }

    nregs = [irep.nregs.to_i, 1].max
    slots = oracle.ivar_slots(irep)
    ctx = { irep: irep, oracle: oracle, opaque: opaque_regs, nregs: nregs, slots: slots,
            slot_of: slots.each_with_index.to_h { |name, k| [name, nregs + k] },
            facts: slots.map { |name| oracle.ivar_fact_mask(irep, name) },
            prov_base: nregs + slots.size, writes: writes }
    extra = enter_edges(irep)
    entry = Array.new(nregs, OTHER)
    (1..nregs - 1).each do |r|
      m = oracle.entry_mask(irep, r)
      entry[r] = m if m && !opaque_regs.include?(r.to_s)
    end
    slots.each { |name| entry << oracle.ivar_entry_mask(irep, name) }
    nregs.times { entry << 0 } # provenance: which slot (+1) each register was loaded from

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
      next if outs[i] == out

      outs[i] = out
      successors(program, extra, i).each do |s|
        edge = refine_edge(program, insns[i], i, s, out, ctx)
        next unless edge

        merged = join_state(ins[s], edge, ctx[:prov_base])
        next if merged == ins[s]

        ins[s] = merged
        work << s if queued.add?(s)
      end
    end
    ins
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
    return state unless COND_BRANCHES.include?(insn.op)

    goto = program.address_to_index[insn.branch_target]
    fall = index + 1
    return state if goto == fall || (target != goto && target != fall)

    narrow_chain(state, insn.reg.to_i, insn.op, target == goto, ctx, Set.new)
  end

  # Provenance values: 0 none, 1..K slot k-1, K+1+r register r.
  def narrow_chain(state, reg, op, taken, ctx, seen)
    return state unless seen.add?(reg)

    mask = state[reg]
    return state if mask.nil? || mask.zero?

    narrowed = narrow_by_truth(op, taken, mask)
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
      slot_narrowed = narrow_by_truth(op, taken, state[slot])
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

  def narrow_by_truth(op, taken, mask)
    case op
    when 'JMPIF' then taken ? mask & ~NIL : mask & FALSY
    when 'JMPNOT' then taken ? mask & FALSY : mask & ~NIL
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
    end

    if CALL_OPS.include?(op)
      # SENDB/SSENDB are excluded: a `break` in the caller's block becomes the result.
      mask = %w[SEND SEND0 SSEND SSEND0].include?(op) ? oracle.send_mask(irep, index, insn, state) : OTHER
      ((a + 1)...nregs).each { |r| out[r] = OTHER }
      refresh_slots(out, ctx)
      set.call(a, mask)
      return out
    end

    nil_raises = ->(sym) { oracle.nil_raises?(sym) }
    case op
    when /\ALOADI/
      set.call(a, INT)
    when 'LOADL'
      set.call(a, oracle.pool_mask(irep, insn))
    when 'LOADNIL'
      set.call(a, NIL)
    when 'MOVE'
      src = insn.regs[1].to_i
      set.call(a, src < nregs ? state[src] : OTHER)
      # `a` now mirrors `src` (and whatever `src` mirrored is reached through it).
      if src < nregs && src != a && !ctx[:opaque].include?(a.to_s) && !ctx[:opaque].include?(src.to_s)
        out[pb + a] = slot_count + 1 + src
      end
    when 'GETCONST', 'GETMCNST'
      set.call(a, oracle.const_mask(insn))
    when 'GETUPVAR'
      set.call(a, oracle.upvar_mask(irep, insn))
    when 'GETIV'
      slot = ctx[:slot_of][insn.ivar]
      set.call(a, slot ? state[slot] : OTHER)
      out[pb + a] = slot - nregs + 1 if slot && !ctx[:opaque].include?(a.to_s)
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
    nregs.times { |r| out[ctx[:prov_base] + r] = 0 }
  end
end
