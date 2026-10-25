# frozen_string_literal: true

# Report-only fact for ESCAPE_ANALYSIS: does a confined `new` object store only immediate ivars? Reopens
# EscapeAnalysis::Analyzer. Nothing here changes generated code; tools/bc2cpp/escape_report.rb emits the result.
# Design and limits: docs/bc2cpp-immediate-ivars.md.
#
# object_ivar_stores(irep, index, klass) => [verdict, detail]
#   ['immediate', n]        every SETIV that can reach the object stores a provably immediate value (n stores);
#   ['not_immediate', why]  a store may hold a heap reference, or the stores cannot be enumerated.
# Only 'immediate' counts as immediate-only: an unknown value or an unenumerable store set is not immediate.
#
# The frames that can run with the object are scanned: the creating frame (the object is the `new` register, not its
# self), initialize, and every method a send on the object reaches (self is the object there). Within a frame a
# forward may-alias flow tracks the registers holding the object; any use the flow does not model is an unenumerated
# reason, so the answer is never too small.
module EscapeAnalysis
  class Analyzer
    # Ops that write their leading register with an immediate value (no heap object): nil, true, false, symbols, small
    # ints. LOADL (constant pool: floats, bignums, strings) and STRING are left out on purpose.
    IMMEDIATE_LOADS = Set[:LOADNIL, :LOADTRUE, :LOADFALSE, :LOADSYM, :LOADI__1, :LOADI_0, :LOADI_1, :LOADI_2,
                          :LOADI_3, :LOADI_4, :LOADI_5, :LOADI_6, :LOADI_7, :LOADI8, :LOADINEG, :LOADI16,
                          :LOADI32].freeze
    # Ops that write a register other than their leading one. An irep holding one has no proven immediate register.
    NON_LEAD_WRITERS = %i[APOST RESCUE KARG KEY_P].freeze
    # Binary and immediate-operand ops: each is a send on its receiver, one of its operands (see object_insn_check).
    SEND_LIKE = Set.new(BINARY_NAMES.keys + %i[ADDI SUBI ADDILV SUBILV GETIDX GETIDX0 SETIDX]).freeze
    # Ops that read a register window (see object_window), modelled as the escape analysis' flow models them.
    WINDOW_OPS = Set[:ARRAY, :HASH, :HASHADD, :ARYPUSH, :ARYCAT, :HASHCAT, :ARYSPLAT, :STRCAT, :BLKCALL,
                     :RANGE_INC, :RANGE_EXC, :CLASS, :MODULE, :SCLASS, :EXEC, :DEF, :TDEF, :SDEF].freeze
    CLASS_MACHINERY = Set[:CLASS, :MODULE, :SCLASS, :EXEC, :DEF, :TDEF, :SDEF].freeze
    # Ops that read only formals or the block slot, never a register the object can be in.
    BENIGN_LEADS = Set[:BLKPUSH, :ARGARY].freeze

    # [verdict, detail] for the `new` at irep[index] that constructs an exact +klass+.
    def object_ivar_stores(irep, index, klass)
      @ivar_store_memo ||= {}
      @ivar_store_memo[[irep.label, index, klass]] ||= compute_object_ivar_stores(irep, index, klass)
    end

    private

    def compute_object_ivar_stores(irep, index, klass)
      defs = @world.defs_for('initialize', [klass], true)
      return ['not_immediate', "unenumerated: initialize of #{klass} not known"] if defs.nil?

      frames = [[irep, [], false, index]]
      defs.each do |mdef|
        # BasicObject#initialize is mrb_do_nothing (see initialize_keeps_no_self?): it stores nothing.
        next if mdef.owner == 'BasicObject' && mdef.irep.nil? && mdef.name == 'initialize'

        body = body_irep(mdef)
        return ['not_immediate', "unenumerated: initialize #{mdef.owner}##{mdef.name} has no body"] unless body

        frames << [body, [0], true, nil]
      end

      stores = {}
      unenumerated = nil
      visited = Set.new
      until frames.empty?
        frame, seeds, self_frame, created = frames.shift
        next unless visited.add?([frame.label, self_frame])

        found, why = scan_object_frame(frame, seeds, self_frame, created, stores)
        unenumerated ||= why
        frames.concat(found)
      end

      bad = stores.values.find { |store| !store[:immediate] }
      return ['not_immediate', "SETIV #{bad[:frame]}:#{bad[:index]} stores a register not provably immediate"] if bad
      return ['not_immediate', unenumerated] if unenumerated

      ['immediate', stores.size]
    end

    # Scans one frame. +seeds+ are the registers holding the object at entry; +self_frame+ says R0 is the object;
    # +created+ is the index of the `new` that makes the object (nil in a callee frame). Returns [frames to scan
    # next, the first unenumerated reason or nil].
    def scan_object_frame(frame, seeds, self_frame, created, stores)
      prog = BytecodeIR.for(frame)
      return [[], "unenumerated: CFG of #{frame.label} unresolved"] unless prog.resolved? && prog.handlers_resolved?

      states = object_frame_states(prog, seeds, self_frame, created)
      found = []
      why = nil
      prog.instructions.each_with_index do |insn, i|
        s = states[i] or next

        why ||= object_insn_check(frame, i, insn.source, s, self_frame, created, stores, found)
      end
      [found, why]
    end

    # The registers holding the object before each instruction (nil = not reached): a forward may-alias flow over the
    # CFG, catch-handler edges included, as the escape analysis' own flow.
    def object_frame_states(prog, seeds, self_frame, created)
      insns = prog.instructions
      states = Array.new(insns.size)
      work = []
      merge = lambda do |index, regs|
        return if index >= insns.size

        cur = states[index]
        merged = cur ? cur | regs : Set.new(regs)
        return if cur && merged.size == cur.size

        states[index] = merged
        work << index
      end
      merge.call(0, seeds)
      until work.empty?
        i = work.pop
        out = object_transfer(insns[i].source, states[i], self_frame, created == i)
        insns[i].successors.each { |succ| merge.call(succ, out) }
        prog.successors_of(i, include_handlers: true).each do |succ|
          merge.call(succ, states[i] | out) unless insns[i].successors.include?(succ)
        end
      end
      states
    end

    # The registers holding the object after +insn+, given the set +s+ before it.
    def object_transfer(insn, s, self_frame, created)
      lead = insn.reg
      return s | [lead] if created

      out = Set.new(s)
      case insn.op
      when :MOVE
        move = BytecodeIR::OperandModel.move(insn)
        out.delete(move.dest)
        out << move.dest if s.include?(move.src)
      when :LOADSELF
        out.delete(lead)
        out << lead if self_frame
      else
        if BytecodeIR::Ops::SEND_FAMILY.include?(insn.op)
          # The result may be the receiver itself, so the destination holds the object when the call is on it.
          self_call = insn.op.to_s.start_with?('SS') ? self_frame : s.include?(lead)
          out.delete(lead)
          out << lead if self_call
        elsif lead && !STORES_LEAD.key?(insn.op) && !PASSES.include?(insn.op)
          out.delete(lead)
        end
      end
      out
    end

    # The reason the object leaves the scan at this instruction (nil when it does not). A SETIV on self and a send on
    # the object are recorded whatever +s+ holds, since the object is self there.
    def object_insn_check(frame, index, insn, s, self_frame, created, stores, found)
      op = insn.op
      return nil if created == index || PASSES.include?(op) || op == :MOVE || op == :LOADSELF
      return "closure #{op} in #{frame.label} may run with the object" if CLOSURE_OPS.include?(op)
      return "SUPER in #{frame.label} runs with the object as self" if self_frame && op.to_s.include?('SUPER')
      return "RETSELF of the object in #{frame.label}" if op == :RETSELF && self_frame

      lead = insn.reg
      if op == :SETIV
        # SETIV has no leading register: its stored value is its first register operand (as in STORES_LEAD).
        value = BytecodeIR::OperandModel.reg_operand(insn)
        return "SETIV stores the object (#{frame.label}:#{index})" if s.include?(value)

        record_store(frame, index, value, stores) if self_frame
        return nil
      end
      return object_send(frame, index, insn, s, self_frame, stores, found) if BytecodeIR::Ops::SEND_FAMILY.include?(op)
      return nil if s.empty?

      operands = ([lead] + insn.regs).compact
      here = "#{op} (#{frame.label}:#{index})"
      if STORES_LEAD.key?(op)
        return "#{here} stores the object" if operands.any? { |r| s.include?(r) }
        return nil
      end
      if KILLS_LEAD.include?(op)
        # Only INTERN and METHOD read their leading register; the rest read nothing but the register they write.
        reads = %i[INTERN METHOD].include?(op) ? operands : insn.regs.drop(1)
        return "#{here} reads the object" if reads.any? { |r| s.include?(r) }
        return nil
      end
      # GETIDX0 takes its receiver from its second operand, so every operand of these ops is checked, not just the leading one.
      return "#{here} operates on the object" if SEND_LIKE.include?(op) && operands.any? { |r| s.include?(r) }
      return nil if SEND_LIKE.include?(op) || BENIGN_LEADS.include?(op)

      if WINDOW_OPS.include?(op)
        return "#{here} with the object in a window" if object_window(insn, lead).any? { |r| s.include?(r) }
        # Class and method definitions run their body with self = the class, but the escape analysis refuses them under self.
        return "#{here} class machinery under self" if self_frame && CLASS_MACHINERY.include?(op)
        return nil
      end
      "#{here} is not modelled"
    end

    # The registers a window op reads, from the same operands the escape analysis' flow reads them from.
    def object_window(insn, lead)
      op = insn.op
      from = lead.to_i
      count = 2
      case op
      when :ARRAY
        three = BytecodeIR::OperandModel.src_and_literal(insn)
        from, count = three ? [three[0].to_i, three[1].to_i] : [from, BytecodeIR::OperandModel.uint_operand(insn).to_i]
      when :HASH then count = 2 * BytecodeIR::OperandModel.uint_operand(insn).to_i
      when :HASHADD then from += 1; count = 2 * BytecodeIR::OperandModel.uint_operand(insn).to_i
      when :ARYPUSH, :BLKCALL then from += 1; count = BytecodeIR::OperandModel.uint_operand(insn).to_i
      when :STRCAT then from += 1; count = 1
      end
      (from...(from + count)).to_a
    end

    # A send whose receiver is the object (the explicit register, or implicit self in a method frame) runs the callee
    # with the object as self. The object is only reachable through those registers, so any other send cannot reach it.
    def object_send(frame, index, insn, s, self_frame, stores, found)
      a = insn.reg
      self_call = insn.op.to_s.start_with?('SS') ? self_frame : s.include?(a)
      positional, kw = argument_slots(insn)
      block = insn.op.to_s.end_with?('B') ? 1 : 0
      args = ((a.to_i + 1)..(a.to_i + [positional + kw + block, 1].max)).to_a
      return "#{insn.op} passes the object (#{frame.label}:#{index})" if args.any? { |r| s.include?(r) }
      return nil unless self_call

      name = BytecodeIR::OperandModel.send_call(insn).name
      defs = @world.defs_named(name)
      # No definition at all sends the call to method_missing, which is not in this list: refuse it too.
      return "send #{name} to the object: callee set unknown or empty" if defs.nil? || defs.empty?

      why = nil
      defs.each do |mdef|
        body = body_irep(mdef)
        if body
          found << [body, [0], true, nil]
        elsif mdef.kind == :ivar_accessor
          # An attribute reader keeps nothing; a writer stores its one argument, read in this frame.
          record_store(frame, index, a.to_i + 1, stores) if name.end_with?('=') && positional == 1 && kw.zero?
        else
          why ||= "send #{name} to the object: opaque #{mdef.owner}##{mdef.name}"
        end
      end
      why
    end

    def record_store(frame, index, reg, stores)
      stores[[frame.label, index]] = { frame: frame.label, index: index, reg: reg,
                                       immediate: immediate_registers(frame).include?(reg) }
    end

    # Registers of +frame+ that hold an immediate at every point (flow-insensitive): every write is an immediate load or a
    # MOVE from such a register, and no formal parameter or block slot is among them.
    def immediate_registers(frame)
      @immediate_memo ||= {}
      @immediate_memo[frame.label] ||= compute_immediate_registers(frame)
    end

    def compute_immediate_registers(frame)
      insns = BytecodeIR.for(frame).instructions.map(&:source)
      return Set.new if insns.any? { |insn| NON_LEAD_WRITERS.include?(insn.op) }

      # ENTER's fields are mand, opt, rest, post, kw, kwrest, block, noblock: the caller writes R1..R(the sum of the
      # first seven), the block slot included when the method takes one.
      fields = frame.enter ? frame.enter.enter_fields : []
      formals = (1..fields.first(7).sum(&:to_i)).to_set
      writers = Hash.new { |h, k| h[k] = [] }
      insns.each do |insn|
        next if PASSES.include?(insn.op) || STORES_LEAD.key?(insn.op) || %i[SETIDX ARYPUSH HASHADD].include?(insn.op)

        lead = insn.reg or next
        writers[lead] << if IMMEDIATE_LOADS.include?(insn.op)
                           [:imm]
                         elsif insn.op == :MOVE
                           [:move, BytecodeIR::OperandModel.move(insn).src]
                         else
                           [:other]
                         end
      end
      candidates = writers.keys.reject { |r| formals.include?(r) }.select { |r| writers[r].none? { |w| w[0] == :other } }.to_set
      loop do
        drop = candidates.select { |r| writers[r].any? { |w| w[0] == :move && !candidates.include?(w[1]) } }
        break if drop.empty?

        candidates -= drop
      end
      candidates
    end
  end
end
