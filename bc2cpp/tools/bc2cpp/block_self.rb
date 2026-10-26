# frozen_string_literal: true

require 'set'
require_relative 'bytecode_ir_ops'
require_relative 'bytecode_ir'

# BLOCK_SELF: is a Ruby method a plain yielder, one that runs its block only through Proc#call?
#
# The block register (1 + required + optional + rest + post + the keyword dict, from ENTER), every copy of it
# (reaching definitions follow MOVEs), every captured slot a nested block reads it from (GETUPVAR) and every
# BLKPUSH (`yield`) hold the Proc. Each read of a Proc-holding register must be a copy (MOVE), a truth test
# (JMPIF/JMPNOT/JMPNIL), the receiver of a `call` or the block a BLKCALL (`yield`) runs, whose arguments do not
# hold it. Any other read (an argument, a
# return, a store, a register window an operator reads) lets the Proc escape and refuses, as do SUPER and ARGARY
# (they pass the frame's block on). A read whose reaching definitions are not computable refuses. Proc#call runs
# the Proc under the self it closed over, so the block of a plain yielder never runs under another self.
module BlockSelf
  WRITE_ONLY_OPS = Set[:ENTER, :NOP, :GETCONST, :GETGV, :GETSV, :GETIV, :GETCV, :GETUPVAR, :BLOCK, :LAMBDA,
                       :METHOD, :JMP, :RETNIL, :RETSELF, :RETTRUE, :RETFALSE, :BLKPUSH, :OCLASS, :TCLASS,
                       :EXCEPT, :STRING, :MOVE, :JMPIF, :JMPNOT, :JMPNIL].freeze
  FORWARDING_OPS = Set[:SUPER, :ARGARY].freeze
  # Operators whose read set is R(a)..R(a+width-1) (vm.c OP_ADD..OP_GE: R(a) op R(a+1); OP_GETIDX: R(a)[R(a+1)];
  # OP_SETIDX: R(a)[R(a+1)] = R(a+2); OP_ADDI/OP_SUBI and the patched OP_ADDILV/OP_SUBILV: R(a) op an immediate, whose
  # fallback writes the immediate before sending), including their method-send fallback, which passes exactly those.
  FIXED_WINDOW_OPS = { :ADD => 2, :SUB => 2, :MUL => 2, :DIV => 2, :EQ => 2, :LT => 2, :LE => 2, :GT => 2,
                       :GE => 2, :GETIDX => 2, :SETIDX => 3, :ADDI => 1, :SUBI => 1, :ADDILV => 1,
                       :SUBILV => 1 }.freeze

  # Operators whose read set the operand count fixes (vm.c): ARRAY a b reads R(a)..R(a+b-1), ARRAY2 a b c reads
  # R(b)..R(b+c-1), ARYPUSH a b reads R(a)..R(a+b), HASH a b reads R(a)..R(a+2b-1), HASHADD a b reads R(a)..R(a+2b),
  # and ARYCAT/HASHCAT/STRCAT a read R(a) and R(a+1), ARYSPLAT a only R(a).
  COUNTED_WINDOW_OPS = %i[ARRAY ARYPUSH HASH HASHADD ARYCAT HASHCAT STRCAT ARYSPLAT].freeze

  module_function

  # nil when the Ruby method body +irep+ (and its nested blocks, from +ireps+) only calls its block, else why not.
  def plain_yielder_why(irep, ireps)
    return 'has no body' unless irep

    req, opt, rest, post, key, kdict = irep.enter&.enter_fields&.first(6)&.map(&:to_i) || [0, 0, 0, 0, 0, 0]
    blk = 1 + req + opt + rest + post + (key.positive? || kdict.positive? ? 1 : 0)
    frame_why(irep, ireps, [[irep, Set[blk]]], blk)
  end

  # +frames+: [[irep, captured proc slots], ...] from the method body down to +irep+.
  def frame_why(irep, ireps, frames, blk)
    program = BytecodeIR.for(irep)
    proc_at = lambda do |idx, reg|
      defs = program.reaching_definitions(idx, reg, through_handlers: true, shared: true)
      return :unknown if defs.nil?

      defs.any? { |df| proc_def?(irep, df, frames, blk) }
    end
    slots = frames.last[1]
    program.each_source do |insn, idx|
      op = insn.op
      return "forwards its block (#{op})" if FORWARDING_OPS.include?(op)
      next if BytecodeIR::Ops::LOAD_PREFIX_OPS.include?(op) || WRITE_ONLY_OPS.include?(op)

      reads = reads_of(irep, insn)
      return "reads registers it cannot list (#{op})" if reads.nil?

      reads.each do |reg, role|
        holds = proc_at.call(idx, reg)
        return "has no reaching definitions at #{op}" if holds == :unknown
        next unless holds
        next if role == :called || (role == :receiver && insn.sym == 'call')

        return "lets its block escape (#{op} #{insn.sym} R#{reg})"
      end
    end
    # Captured slots for the nested blocks: every register this frame may write a Proc into.
    program.each_with_op(:MOVE, :BLKPUSH, :GETUPVAR) do |insn, idx|
      next unless insn.reg

      slots << insn.reg if case insn.op
                           when :MOVE then proc_at.call(idx, insn.regs[1]) == true
                           when :BLKPUSH then true
                           when :GETUPVAR then proc_def?(irep, BytecodeIR::Definition.new(idx, insn.reg), frames, blk)
                           else false
                           end
    end
    irep.reps.each do |child_label|
      child = ireps[child_label] or return 'has a nested block with no body'
      why = frame_why(child, ireps, frames + [[child, Set.new]], nil)
      return why if why
    end
    nil
  end

  def proc_def?(irep, df, frames, blk)
    return df.reg == blk if df.entry?

    insn = BytecodeIR.for(irep).source_at(df.index)
    case insn.op
    when :BLKPUSH then true
    when :GETUPVAR
      index, level = insn.upvar_ref
      pos = index && frames.length - 2 - level
      frame = pos && pos >= 0 ? frames[pos] : nil
      !frame || frame[1].include?(index)
    else false
    end
  end

  # The registers after R(a) a send reads (vm.c OP_SEND): its positional arguments, one Array for a splat; its
  # keywords, a key and a value each or one Hash for `**`; and the block of a B-suffixed send.
  def send_window(insn)
    op = insn.op
    block = BytecodeIR::Ops::B_SUFFIX_OPS.include?(op) ? 1 : 0
    return block if BytecodeIR::Ops::ZERO_SUFFIX_OPS.include?(op)

    return nil unless insn.argc_operand

    insn.positional_slots + insn.keyword_slots + block
  end

  # The registers a COUNTED_WINDOW_OPS operator reads, or nil when its operands do not parse.
  def counted_window(insn)
    a = insn.reg&.to_i or return nil
    count = insn.typed.find { |operand| operand.kind == :int }&.value
    case insn.op
    when :ARRAY
      regs = insn.regs
      return nil unless count

      # ARRAY2 prints as ARRAY with its source register in front of the count.
      from = regs.size > 1 ? regs[1].to_i : a
      (from...(from + count)).to_a
    when :ARYPUSH then count && (a..(a + count)).to_a
    when :HASH then count && (a...(a + (2 * count))).to_a
    when :HASHADD then count && (a..(a + (2 * count))).to_a
    when :ARYSPLAT then [a]
    else [a, a + 1]
    end
  end

  # [[register, :receiver | :argument], ...] the instruction reads, or nil when its read set is not modelled.
  def reads_of(irep, insn)
    op = insn.op
    regs = insn.regs
    if BytecodeIR::Ops::SEND.include?(op)
      n = send_window(insn)
      return nil unless insn.reg && n

      d = insn.reg
      args = (1..n).map { |k| [d + k, :argument] }
      return BytecodeIR::Ops::SELF_SEND.include?(op) ? args : [[d, :receiver]] + args
    end
    if op == :BLKCALL
      # `yield`'s call (vm.c OP_BLKCALL): runs R(a) as a block, under its own self, with R(a+1..a+n).
      n = insn.typed.find { |operand| operand.kind == :int }&.value
      return nil unless insn.reg && n

      d = insn.reg
      return [[d, :called]] + (1..n).map { |k| [d + k, :argument] }
    end
    case op
    when :RETURN, :RETURN_BLK, :BREAK, :SETIV, :SETGV, :SETSV, :SETCV, :SETCONST, :SETUPVAR, :GETMCNST
      regs.map { |r| [r, :argument] }
    when *FIXED_WINDOW_OPS.keys
      # vm.c: these read R(a) and the next width-1 registers only, also when they fall back to a send.
      return nil unless insn.reg

      FIXED_WINDOW_OPS[op].times.map { |k| [(insn.reg + k), :argument] }
    when *COUNTED_WINDOW_OPS
      window = counted_window(insn)
      return nil unless window

      window.map { |r| [r, :argument] }
    else
      # An operator window (ADD, ARRAY, HASH, STRCAT, ...) reads past its listed registers: every register from the
      # lowest listed one up to the frame's last.
      lo = regs.min
      return [] unless lo

      (lo...[irep.nregs.to_i, lo + 1].max).map { |r| [r, :argument] }
    end
  end
end
