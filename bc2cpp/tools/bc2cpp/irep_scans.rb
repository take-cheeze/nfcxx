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
    [from, instructions.length - 1].min.downto(0) do |index|
      insn = instructions[index]
      hit = barrier && (barrier.respond_to?(:call) ? barrier.call(insn, reg) : barrier.include?(insn.op))
      return barrier_result if hit
      next if skip_ops&.include?(insn.op)
      next unless insn.reg == reg

      if follow_moves && insn.op == 'MOVE'
        moves += 1
        return nil if max_moves && moves > max_moves

        reg = insn.regs[1]
        return nil unless reg

        next
      end

      step = yield insn, index, reg
      next if step.equal?(KEEP)
      return step unless step.is_a?(Follow)

      reg = step.reg
      return nil unless reg
    end
    exhausted&.call(reg)
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
