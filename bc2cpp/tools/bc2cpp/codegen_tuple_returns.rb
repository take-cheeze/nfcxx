# frozen_string_literal: true

# CodeGen: TUPLE_RETURN_FACTS (ADR 0311).
#
# `a, b = pair(x)` is `SEND R5 :pair; AREF R3 R5 0; AREF R4 R5 1`, and AREF reads an element of whatever the
# call returned, so NumericFlow knew nothing about `a` and `b`. When every definition of `pair` ends in a
# literal `[e0, e1, ...]` of the same length, the call's result is a fresh Array nobody else holds, its element
# j holds exactly what the flow proved for register j at the ARRAY, and the AREFs that read it straight after
# the call see those classes. Each position is its own class set (`[x + 1, flag]` is INT and OTHER).
#
# Producer (`tuple_shape`): the name is a numeric-return candidate (a call reaches only the listed bytecode
# definitions), every definition is handler-free, has no RETURN_BLK anywhere in its blocks and no other kind of
# return, and each RETURN's register is defined only by ARRAY instructions of one length, each followed by
# nothing but JMP/NOP up to that RETURN, so the Array cannot be read, stored or changed before it leaves.
# Consumer (`tuple_aref_call`): the AREF reads the call's own result register with no branch target and no
# other instruction between the call and the AREF, so nothing can change the Array first. An index past the
# length reads nil, as OP_AREF does. Facts grow in the numeric fixpoint like the other pools.
class CodeGen
  TUPLE_CALL_OPS = %w[SEND SEND0 SSEND SSEND0].freeze
  # Any other way out of a method: the result is not an Array literal.
  TUPLE_FOREIGN_RETURN_OPS = %w[RETNIL RETSELF RETTRUE RETFALSE RETURN_BLK BREAK STOP].freeze
  TUPLE_KEPT_BITS = NumericFlow::NUM | NumericFlow::NIL
  TUPLE_WALK_LIMIT = 64

  def setup_tuple_returns
    @tuple_returns = {}
    @tuple_sites = {}
    @tuple_consumers = Hash.new { |h, k| h[k] = Set.new }
    return if ENV['BC2CPP_TUPLE_RETURNS'] == '0'

    numeric_return_candidates.each do |name|
      sites = tuple_name_sites(name)
      next unless sites

      @tuple_returns[name] = Array.new(sites.first[3], 0)
      @tuple_sites[name] = sites
    end
    return if @tuple_returns.empty?

    @ireps.each_value do |irep|
      irep.instructions.each_with_index do |insn, idx|
        next unless insn.op == 'AREF'

        src, = insn.src_and_literal
        name = src && tuple_aref_call(irep, idx, src)
        @tuple_consumers[name] << irep.label if name && @tuple_returns.key?(name)
      end
    end
  end

  # [[irep, ARRAY index, owner def, length], ...] over every definition of +name+, or nil.
  def tuple_name_sites(name)
    defs = @registry[name]
    return nil if defs.nil? || defs.empty?

    sites = defs.flat_map do |d|
      irep = d.irep && @ireps[d.irep]
      return nil unless irep

      found = tuple_shape(irep)
      return nil unless found

      found.map { |idx, n| [irep, idx, d, n] }
    end
    sites unless sites.empty? || sites.map(&:last).uniq.size != 1
  end

  # [[ARRAY index, length], ...] when every return of +irep+ hands back a fresh literal Array, else nil.
  def tuple_shape(irep)
    program = BytecodeIR.for(irep)
    return nil unless program.resolved? && !program.handlers?

    insns = irep.instructions
    return nil if insns.any? { |i| TUPLE_FOREIGN_RETURN_OPS.include?(i.op) } || tuple_block_returns?(irep)

    arrays = {}
    insns.each_index do |r|
      next unless insns[r].op == 'RETURN'

      reg = insns[r].reg
      defs = BytecodeIR.reaching_definitions(irep, r, reg, follow_moves: false)
      return nil if defs.nil? || defs.empty? || defs.any?(&:entry?)

      defs.each do |df|
        array = insns[df.index]
        n = array.op == 'ARRAY' ? array.uint_operand : nil
        return nil unless n && array.reg == reg && tuple_walk_to_return(program, df.index, reg) == r

        arrays[df.index] = n
      end
    end
    arrays.to_a unless arrays.empty?
  end

  # A `return` inside a block of +irep+ leaves the method with a value this shape does not see.
  def tuple_block_returns?(irep, seen = Set.new)
    Array(irep.reps).any? do |label|
      child = @ireps[label]
      next false unless child && seen.add?(label)

      child.instructions.any? { |i| i.op == 'RETURN_BLK' } || tuple_block_returns?(child, seen)
    end
  end

  # The RETURN of +reg+ reached from +from+ through nothing but JMP and NOP, else nil.
  def tuple_walk_to_return(program, from, reg)
    cur = from
    TUPLE_WALK_LIMIT.times do
      succ = program.instruction_at(cur).successors
      return nil unless succ.size == 1

      cur = succ.first
      insn = program.instruction_at(cur).source
      case insn.op
      when 'JMP', 'NOP' then next
      when 'RETURN' then return insn.reg == reg ? cur : nil
      else return nil
      end
    end
    nil
  end

  # Name of the call whose result register +src+ the AREF at +index+ reads, when nothing sits between them.
  def tuple_aref_call(irep, index, src)
    insns = irep.instructions
    j = index - 1
    j -= 1 while j >= 0 && insns[j].op == 'AREF' && insns[j].reg != src && insns[j].src_and_literal&.first == src
    call = j >= 0 ? insns[j] : nil
    return nil unless call && TUPLE_CALL_OPS.include?(call.op) && call.reg == src && call.sym

    preds = BytecodeIR.for(irep).instruction_predecessors(include_handlers: true)
    return nil unless preds && ((j + 1)..index).all? { |k| preds[k].to_a == [k - 1] }

    call.sym
  end

  # Class set of AREF's result for NumericFlow (nothing proven is OTHER).
  def tuple_aref_mask(irep, index, insn)
    return NumericFlow::OTHER if @tuple_returns.nil? || @tuple_returns.empty?

    src, lit = insn.src_and_literal
    name = src && tuple_aref_call(irep, index, src)
    masks = name && @tuple_returns[name]
    return NumericFlow::OTHER unless masks

    position = lit.to_i
    position < masks.size ? masks[position] : NumericFlow::NIL
  end

  # One growth pass; true when a position grew.
  def grow_tuple_returns
    changed = false
    @tuple_returns.each do |name, masks|
      joined = masks.dup
      @tuple_sites[name].each do |irep, idx, d, _n|
        first = irep.instructions[idx].reg.to_i
        joined.each_index do |j|
          raw = numeric_raw_mask(irep, idx, first + j, d)
          joined[j] |= tuple_position_mask(raw)
        end
      end
      next if joined == masks

      @tuple_returns[name] = joined
      @tuple_consumers[name].each { |label| numeric_invalidate(label) }
      changed = true
    end
    changed
  end

  # Numbers and nil survive; every other class (exact classes, kinds) becomes OTHER.
  def tuple_position_mask(raw)
    return NumericFlow::OTHER if raw.nil?

    kept = raw & TUPLE_KEPT_BITS
    (raw & ~TUPLE_KEPT_BITS).zero? ? kept : kept | NumericFlow::OTHER
  end

  # For the diagnostic: `NUMTUPLE name (INT, INT|FLT, OTHER)`.
  def tuple_facts_report
    (@tuple_returns || {}).filter_map do |name, masks|
      next if masks.all?(&:zero?)

      "  NUMTUPLE #{name} (#{masks.map { |m| numeric_mask_name(m) }.join(', ')})"
    end
  end
end
