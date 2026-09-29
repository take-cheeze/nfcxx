# frozen_string_literal: true

# Backward register scans over an Irep's instructions: the reaching-definition
# questions ("what wrote this register before here?") that every analysis pass
# asks. Each pass used to hand-roll the same `downto(0)` loop with its own
# MOVE / skip / stop rules; they live here so the rules are spelled as options
# and the loop exists once.
module IrepScans
  # Block result: keep walking, now following +reg+. A nil +reg+ is a MOVE with
  # no source, which ends the walk with nil.
  Follow = Struct.new(:reg)

  # Block result: keep walking with the register unchanged (the instruction was
  # transparent for this question, e.g. a `.freeze` on the same register).
  KEEP = Follow.new(:same).freeze

  # A constant expression read back from a register (see #constant_path).
  # +root+ is :const (GETCONST), :object (OCLASS) or :nil (LOADNIL); +name+ and
  # +root_index+ are the GETCONST's name and instruction index (nil for the
  # others); +segments+ are the GETMCNST names applied on top, outermost first.
  ConstantPath = Struct.new(:root, :name, :root_index, :segments, :qualified)

  def self.follow(reg)
    Follow.new(reg)
  end

  # Walk backwards from instruction +from+ (inclusive) along register +reg+,
  # yielding `(insn, index, reg)` for each instruction whose leading register
  # operand is the followed register. The block's result decides what happens:
  # IrepScans.follow(other) / KEEP continue, anything else (nil, false, a
  # value) ends the walk and is returned.
  #
  # Options, checked per instruction in this order:
  # * barrier: ops (Array) or `->(insn, reg)`; a hit ends the walk with
  #   +barrier_result+ whether or not the instruction touches the register.
  # * skip_ops: ops ignored even when they name the register (read-only
  #   opcodes, BLOCK's proc register).
  # * follow_moves: MOVE is followed to its source without yielding; a MOVE
  #   without a source, or more than +max_moves+ of them, ends the walk with nil.
  # +exhausted+ (`->(reg)`) supplies the result when the top of the body is
  # reached with +reg+ never written, i.e. an incoming register.
  def walk_writers(from, reg, skip_ops: nil, barrier: nil, barrier_result: nil,
                   follow_moves: false, max_moves: nil, exhausted: nil)
    moves = 0
    callable_barrier = barrier.respond_to?(:call)
    index = [from, instructions.length - 1].min
    while index >= 0
      # Without a barrier only an instruction leading with +reg+ can matter, so
      # jump straight to the previous one (skip_ops only ever skips those too).
      unless barrier
        index = previous_lead_index(reg, index)
        break unless index
      end
      insn = instructions[index]
      hit = barrier && (callable_barrier ? barrier.call(insn, reg) : barrier.include?(insn.op))
      return barrier_result if hit
      next_index = index - 1
      if insn.reg != reg || skip_ops&.include?(insn.op)
        index = next_index
        next
      end

      if follow_moves && insn.op == 'MOVE'
        moves += 1
        return nil if max_moves && moves > max_moves

        reg = insn.regs[1]
        return nil unless reg

        index = next_index
        next
      end

      step = yield insn, index, reg
      index = next_index
      next if step.equal?(KEEP)
      return step unless step.is_a?(Follow)

      reg = step.reg
      return nil unless reg
    end
    exhausted&.call(reg)
  end

  # JOIN_DOMINANCE (ADR 0261): walk_writers whose every hop must dominate the
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
      if follow_moves && insn.op == 'MOVE'
        IrepScans.follow(insn.regs[1])
      else
        yield insn, index, cur
      end
    end
  end

  # Index of the nearest instruction at or before +from+ whose leading register
  # operand is +reg+, or nil. The per-register index lists are built once per
  # irep (instructions never change after loading).
  def previous_lead_index(reg, from)
    @lead_indices ||= instructions.each_with_index.group_by { |insn, _| insn.reg }
                                  .transform_values { |pairs| pairs.map(&:last).freeze }.freeze
    indices = @lead_indices[reg]
    return nil unless indices

    position = indices.bsearch_index { |i| i > from }
    position = position ? position - 1 : indices.length - 1
    position.negative? ? nil : indices[position]
  end

  # The constant expression held in +reg+ at instruction +from+ (inclusive):
  # MOVEs and GETMCNST scopes followed back to the GETCONST / OCLASS / LOADNIL
  # that roots it. Nil when anything else writes the register on the way (or
  # the register is never written). +skip_ops+ / +barrier+ are walk_writers'.
  # GETMCNST always carries its `::Name` (OperandSchema), so a segment is never nil.
  def constant_path(from, reg, skip_ops: nil, barrier: nil)
    segments = []
    qualified = false
    walk_writers(from, reg, skip_ops: skip_ops, barrier: barrier, follow_moves: true) do |insn, index|
      case insn.op
      when 'GETMCNST'
        segment = insn.mcnst_name
        next nil unless segment

        qualified = true
        segments.unshift(segment)
        KEEP
      when 'GETCONST'
        ConstantPath.new(:const, insn.const_name, index, segments, qualified)
      when 'OCLASS'
        ConstantPath.new(:object, nil, nil, segments, qualified)
      when 'LOADNIL'
        ConstantPath.new(:nil, nil, nil, segments, qualified)
      end
    end
  end

  # The constant name (`Name` or `Outer::Name`) that EVERY definition reaching
  # the read of +reg+ at instruction +use+ agrees on, through joins and loops
  # (BytecodeIR.reaching_definitions), or nil: a refused query, an entry value,
  # or any definition that is not a GETCONST (GETMCNST scopes chained the same
  # way) naming that same constant. Unlike #constant_path this does not stop at
  # a branch, so it also answers when unrelated branches sit between the load
  # and the use.
  def agreed_constant_name(use, reg, depth = 0)
    return nil if depth > CONSTANT_SCOPE_DEPTH

    defs = BytecodeIR.reaching_definitions(self, use, reg)
    return nil if defs.nil? || defs.empty? || defs.any?(&:entry?)

    names = defs.map do |definition|
      insn = instructions[definition.index]
      case insn.op
      when 'GETCONST' then insn.const_name
      when 'GETMCNST'
        scope = agreed_constant_name(definition.index, insn.reg, depth + 1)
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
    run = []
    [from, instructions.length - 1].min.downto(0) do |index|
      break if limit && run.size >= limit

      insn = instructions[index]
      break unless insn.op == op

      run.unshift(insn)
    end
    run
  end
end
