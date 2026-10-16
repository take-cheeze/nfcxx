# frozen_string_literal: true

require 'set'
require_relative 'bytecode_ir'

# BLOCK_SELF (ADR 0456): is a Ruby method a plain yielder, one that runs its block only through Proc#call?
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
  WRITE_ONLY_OPS = Set['ENTER', 'NOP', 'GETCONST', 'GETGV', 'GETSV', 'GETIV', 'GETCV', 'GETUPVAR', 'BLOCK', 'LAMBDA',
                       'METHOD', 'JMP', 'RETNIL', 'RETSELF', 'RETTRUE', 'RETFALSE', 'BLKPUSH', 'OCLASS', 'TCLASS',
                       'EXCEPT', 'STRING', 'MOVE', 'JMPIF', 'JMPNOT', 'JMPNIL'].freeze
  FORWARDING_OPS = Set['SUPER', 'ARGARY'].freeze
  SENDS = Set['SEND', 'SEND0', 'SENDB', 'SSEND', 'SSEND0', 'SSENDB'].freeze
  # Operators whose read set is R(a)..R(a+width-1) (vm.c OP_ADD..OP_GE: R(a) op R(a+1); OP_GETIDX: R(a)[R(a+1)];
  # OP_SETIDX: R(a)[R(a+1)] = R(a+2); OP_ADDI/OP_SUBI and the patched OP_ADDILV/OP_SUBILV: R(a) op an immediate, whose
  # fallback writes the immediate before sending), including their method-send fallback, which passes exactly those.
  FIXED_WINDOW_OPS = { 'ADD' => 2, 'SUB' => 2, 'MUL' => 2, 'DIV' => 2, 'EQ' => 2, 'LT' => 2, 'LE' => 2, 'GT' => 2,
                       'GE' => 2, 'GETIDX' => 2, 'SETIDX' => 3, 'ADDI' => 1, 'SUBI' => 1, 'ADDILV' => 1,
                       'SUBILV' => 1 }.freeze

  module_function

  # nil when the Ruby method body +irep+ (and its nested blocks, from +ireps+) only calls its block, else why not.
  def plain_yielder_why(irep, ireps)
    return 'has no body' unless irep

    req, opt, rest, post, key, kdict = irep.enter&.enter_fields&.first(6)&.map(&:to_i) || [0, 0, 0, 0, 0, 0]
    blk = 1 + req + opt + rest + post + (key.positive? || kdict.positive? ? 1 : 0)
    frame_why(irep, ireps, [[irep, Set[blk.to_s]]], blk.to_s)
  end

  # +frames+: [[irep, captured proc slots], ...] from the method body down to +irep+.
  def frame_why(irep, ireps, frames, blk)
    program = BytecodeIR.for(irep)
    proc_at = lambda do |idx, reg|
      defs = program.reaching_definitions(idx, reg.to_s, through_handlers: true)
      return :unknown if defs.nil?

      defs.any? { |df| proc_def?(irep, df, frames, blk) }
    end
    slots = frames.last[1]
    irep.instructions.each_with_index do |insn, idx|
      op = insn.op
      return "forwards its block (#{op})" if FORWARDING_OPS.include?(op)
      next if op.start_with?('LOAD') || WRITE_ONLY_OPS.include?(op)

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
    irep.instructions.each_with_index do |insn, idx|
      next unless insn.reg

      slots << insn.reg if case insn.op
                           when 'MOVE' then proc_at.call(idx, insn.regs[1]) == true
                           when 'BLKPUSH' then true
                           when 'GETUPVAR' then proc_def?(irep, BytecodeIR::Definition.new(idx, insn.reg), frames, blk)
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
    return df.reg.to_s == blk if df.entry?

    insn = irep.instructions[df.index]
    case insn.op
    when 'BLKPUSH' then true
    when 'GETUPVAR'
      index, level = insn.upvar_ref
      pos = index && frames.length - 2 - level
      frame = pos && pos >= 0 ? frames[pos] : nil
      !frame || frame[1].include?(index.to_s)
    else false
    end
  end

  # [[register, :receiver | :argument], ...] the instruction reads, or nil when its read set is not modelled.
  def reads_of(irep, insn)
    op = insn.op
    regs = insn.regs
    if SENDS.include?(op)
      no_args = op.end_with?('0')
      return nil unless insn.reg && (no_args || insn.plain_fixed_argc?)

      d = insn.reg.to_i
      n = (no_args ? 0 : insn.argc.to_i) + (op.end_with?('B') ? 1 : 0)
      args = (1..n).map { |k| [(d + k).to_s, :argument] }
      return op.start_with?('SSEND') ? args : [[d.to_s, :receiver]] + args
    end
    if op == 'BLKCALL'
      # `yield`'s call (vm.c OP_BLKCALL): runs R(a) as a block, under its own self, with R(a+1..a+n).
      n = insn.typed.find { |operand| operand.kind == :int }&.value
      return nil unless insn.reg && n

      d = insn.reg.to_i
      return [[d.to_s, :called]] + (1..n).map { |k| [(d + k).to_s, :argument] }
    end
    case op
    when 'RETURN', 'RETURN_BLK', 'BREAK', 'SETIV', 'SETGV', 'SETSV', 'SETCV', 'SETCONST', 'SETUPVAR', 'GETMCNST'
      regs.map { |r| [r, :argument] }
    when *FIXED_WINDOW_OPS.keys
      # vm.c: these read R(a) and the next width-1 registers only, also when they fall back to a send.
      return nil unless insn.reg

      FIXED_WINDOW_OPS[op].times.map { |k| [(insn.reg.to_i + k).to_s, :argument] }
    else
      # An operator window (ADD, ARRAY, HASH, STRCAT, ...) reads past its listed registers: every register from the
      # lowest listed one up to the frame's last.
      lo = regs.map(&:to_i).min
      return [] unless lo

      (lo...[irep.nregs.to_i, lo + 1].max).map { |r| [r.to_s, :argument] }
    end
  end
end
