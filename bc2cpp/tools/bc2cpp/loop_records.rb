# frozen_string_literal: true

require_relative 'bytecode_ir'
require_relative 'bytecode_ir_dataflow'

# LOOP_RECORDS: the emitter's loop and block-send records (MrbcRb::Annotations version 4) against what the bytecode shows of
# the same loops. Nothing reads the records for code yet, so a record that disagrees with its code is an emitter bug, and
# the build stops on one as it does on RBS_SEED_CONTRADICTION. BC2CPP_CLASS_SCOPE=0 drops the whole table, records included.
#
# Checked per irep, both ways where the bytecode can say:
#   * a loop: back_pc is a JMP to header_pc, body_pc a NOP, exit_pc the pc after the JMP;
#   * an exit is the op its kind says (break/next/redo/retry a JMPUW to after the loop / header_pc / body_pc / anywhere,
#     return a RETURN-family op, break_block BREAK, raise an EXIT_SENDS send) inside the loop; and every JMPUW in a loop is
#     an exit of the innermost one, every frame exit and exit send one of each loop around it, and every backward branch to
#     a header or body pc that loop's back edge or a recorded exit;
#   * writes: a named local the loop's code (or a block it creates, by SETUPVAR) writes is in the record. A recorded name
#     the code never writes is not a contradiction: the AST also counts a write the emitter compiles to no store of the
#     register (writes_ast_only, counted); the unnamed registers of the bytecode's own temporaries are no names;
#   * a block send: every SENDB/SSENDB/SUPER has a record, of its op and name; a literal (or `for`) block's send follows the
#     BLOCK of the recorded block irep, a `&:sym` one the LOADSYM of that Symbol, and no other kind follows a BLOCK.
module LoopRecords
  EXT_OPS = %i[EXT1 EXT2 EXT3].freeze
  BLOCK_SENDS = %i[SENDB SSENDB SUPER].freeze
  SEND_OPS = %i[SEND SEND0 SSEND SSEND0 SENDB SSENDB].freeze
  RETURN_OPS = %i[RETURN RETURN_BLK RETSELF RETNIL RETTRUE RETFALSE].freeze
  # MrbcRb::Annotations::EXIT_CALLS, by name.
  EXIT_SENDS = %w[raise fail throw exit exit! abort].freeze
  # The ops whose leading register this check takes as written (BytecodeIR's audited list, LOADI*, EXCEPT).
  WRITERS = ((BytecodeIR::WRITES_LEADING_REG_OPS.to_a + BytecodeIR::Ops::LOADI_OPS.to_a + [:EXCEPT]) -
             %i[ENTER SETGV SETSV SETIV SETCV SETCONST SETMCNST SETIDX JMP JMPIF JMPNOT JMPNIL RETURN RETURN_BLK BREAK
                STOP DEBUG NOP]).to_h { |op| [op, true] }.freeze
  # Ops that create a child irep whose SETUPVAR at its own depth writes this frame.
  CLOSURE_OPS = %i[BLOCK LAMBDA METHOD].freeze

  # contradictions: [String]; counts: what was checked and the write sets' agreement ({ writes_equal:, writes_ast_only:, ... }).
  Result = Struct.new(:contradictions, :counts)

  module_function

  def check(ireps)
    result = Result.new([], Hash.new(0))
    ireps.each do |label, irep|
      scope = irep.class_scope
      next unless scope && scope[:loops]

      insns = irep.instructions.reject { |i| EXT_OPS.include?(i.op) }
      report = ->(what) { result.contradictions << "#{label} (#{irep.file}): #{what}" }
      check_loops(ireps, irep, insns, scope[:loops], report, result.counts)
      check_block_sends(irep, insns, scope, report, result.counts)
    end
    result
  end

  # The build's check (bc2cpp.rb): stops with every contradiction listed. A method of its own, as the build's main body is
  # at mrbc's local-variable limit.
  def enforce!(ireps)
    rows = check(ireps).contradictions
    return if rows.empty?

    rows.each { |row| warn "  LOOP_RECORD #{row}" }
    abort "\n[bc2cpp] LOOP_RECORDS: #{rows.size} record(s) disagree with their bytecode (see above)."
  end

  def check_loops(ireps, irep, insns, loops, report, counts)
    by_addr = insns.to_h { |i| [i.addr, i] }
    index = insns.each_with_index.to_h { |i, k| [i.addr, k] }
    exits_at = {}
    loops.each do |lp|
      counts[:loops] += 1
      where = "loop line #{lp[:line]}"
      back = by_addr[lp[:back_pc]]
      after = back && insns[index[back.addr] + 1]
      unless back&.op == :JMP && back.branch_target == lp[:header_pc] && by_addr[lp[:body_pc]]&.op == :NOP &&
             lp[:header_pc] <= lp[:body_pc] && lp[:body_pc] < lp[:back_pc] && after&.addr == lp[:exit_pc]
        report.call("#{where}: no back edge JMP #{lp[:back_pc]} -> #{lp[:header_pc]} over NOP #{lp[:body_pc]}")
        next
      end
      lp[:exits].each do |e|
        (exits_at[e[:pc]] ||= []) << [lp, e[:kind]]
        insn = by_addr[e[:pc]]
        report.call("#{where}: #{e[:kind]} exit at #{e[:pc]} is #{insn&.op.inspect}") unless inside?(lp, e[:pc]) && exit_shape?(lp, e[:kind], insn)
      end
      check_writes(ireps, irep, insns, lp, where, report, counts)
    end
    check_exits_complete(insns, loops, exits_at, report)
  end

  def inside?(lp, pc) = pc >= lp[:header_pc] && pc <= lp[:back_pc]

  def exit_shape?(lp, kind, insn)
    return false unless insn

    case kind
    when :break then insn.op == :JMPUW && insn.branch_target >= lp[:exit_pc]
    when :next then insn.op == :JMPUW && insn.branch_target == lp[:header_pc]
    when :redo then insn.op == :JMPUW && insn.branch_target == lp[:body_pc]
    when :retry then insn.op == :JMPUW
    when :return then RETURN_OPS.include?(insn.op)
    when :break_block then insn.op == :BREAK
    when :raise then SEND_OPS.include?(insn.op) && EXIT_SENDS.include?(insn.sym.to_s)
    else false
    end
  end

  # The bytecode's exits each have their record: a JMPUW in the innermost loop around it, a frame exit or exit send in
  # every loop around it, and a backward branch to a loop's header or body in that loop.
  def check_exits_complete(insns, loops, exits_at, report)
    insns.each do |insn|
      around = loops.select { |lp| inside?(lp, insn.addr) }
      recorded = exits_at[insn.addr] || []
      if insn.op == :JMPUW && !around.empty?
        inner = around.min_by { |lp| lp[:back_pc] - lp[:header_pc] }
        report.call("JMPUW at #{insn.addr} is no exit of the loop of line #{inner[:line]}") unless recorded.any? { |lp, _| lp.equal?(inner) }
      elsif RETURN_OPS.include?(insn.op) || insn.op == :BREAK || (SEND_OPS.include?(insn.op) && EXIT_SENDS.include?(insn.sym.to_s))
        missing = around.reject { |lp| recorded.any? { |r, _| r.equal?(lp) } }
        missing.each { |lp| report.call("#{insn.op} at #{insn.addr} is no exit of the loop of line #{lp[:line]}") }
      end
      target = insn.branch_target
      next unless target && target <= insn.addr

      loops.each do |lp|
        next unless target == lp[:header_pc] || target == lp[:body_pc]
        next if insn.addr == lp[:back_pc] || recorded.any? { |r, _| r.equal?(lp) }

        report.call("backward #{insn.op} at #{insn.addr} -> #{target} is no edge of the loop of line #{lp[:line]}")
      end
    end
  end

  def check_writes(ireps, irep, insns, lp, where, report, counts)
    written = written_names(ireps, irep, insns, lp)
    unrecorded = written - lp[:writes]
    report.call("#{where}: writes #{unrecorded.join(', ')} the record does not list") unless unrecorded.empty?
    counts[lp[:writes] == written ? :writes_equal : :writes_ast_only] += 1 if unrecorded.empty?
  end

  # The names of +irep+'s locals that the code of +lp+ stores into, a block it creates (SETUPVAR at the block's depth)
  # included. Only the ops of WRITERS count, so a store this misses can only make the record look larger, never wrong.
  def written_names(ireps, irep, insns, lp)
    regs = {}
    insns.each do |insn|
      next unless inside?(lp, insn.addr)

      run = BytecodeIR.written_run(insn)
      if run then run.each { |r| regs[r] = true }
      elsif WRITERS.key?(insn.op) && insn.reg then regs[insn.reg] = true
      end
      next unless CLOSURE_OPS.include?(insn.op) && insn.block_index

      child = ireps[irep.reps[insn.block_index]]
      next unless child

      BytecodeIR.each_nested_insn(child, ->(l) { ireps[l] }) do |nested, depth|
        next unless nested.op == :SETUPVAR

        reg, level = nested.upvar_ref
        regs[reg.to_i] = true if level == depth
      end
    end
    lv = irep.lv || []
    regs.keys.select { |r| r >= 1 && r < irep.nlocals.to_i }.filter_map { |r| lv[r - 1] }.map(&:to_s).uniq.sort
  end

  def check_block_sends(irep, insns, scope, report, counts)
    sends = scope[:block_sends] || {}
    labels = scope[:labels]
    insns.each_with_index do |insn, k|
      next unless BLOCK_SENDS.include?(insn.op)

      counts[:block_sends] += 1
      rec = sends[insn.addr]
      next report.call("#{insn.op} at #{insn.addr} has no block-send record") unless rec

      prev = k.positive? ? insns[k - 1] : nil
      name = insn.op == :SUPER ? 'super' : insn.sym.to_s
      ok = rec[:method] == name &&
           case rec[:block]
           when :literal, :for
             prev&.op == :BLOCK && !rec[:block_irep].nil? && labels[rec[:block_irep]] == irep.reps[prev.block_index]
           when :sym then prev&.op == :LOADSYM && prev.sym.to_s == rec[:sym]
           else prev&.op != :BLOCK
           end
      report.call("#{insn.op} #{name} at #{insn.addr} line #{rec[:line]}: record #{rec[:method]} #{rec[:block]} after #{prev&.op.inspect}") unless ok
    end
  end
end
