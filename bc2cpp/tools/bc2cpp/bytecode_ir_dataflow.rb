# frozen_string_literal: true

# Reaching definitions over BytecodeIR's normal-flow CFG: the SET of writes
# that can supply a register's value at an instruction, through joins and
# loops. The backward walks in IrepScans see only the textually preceding
# writer; this answers the question every such walk approximates.
#
# Soundness first: any state the model cannot account for (an op outside the
# audited write model, a handler edge, a clobbered register, an unreachable
# join, the state cap) makes the query return nil, never a partial set.
module BytecodeIR
  # A definition reaching a use: +index+ is the writing instruction (ENTRY for
  # the value the method was entered with) and +reg+ the register it wrote
  # (the MOVE source when the chain was followed).
  Definition = Struct.new(:index, :reg) do
    def entry?
      index == ENTRY
    end
  end

  # Ops that write at most the register in their leading operand and open no
  # entry point (ops.h, vm.c); the same audited whitelist as
  # CodeGen::FIXNUM_PROOF_STEP_OVER_OPS (bc2cpp_bytecode_ir_check.rb keeps them
  # equal). LOADI* is matched by prefix. Anything else refuses.
  WRITES_LEADING_REG_OPS = Set[
    'NOP', 'MOVE', 'LOADL', 'LOADSYM', 'LOADNIL', 'LOADSELF', 'LOADTRUE', 'LOADFALSE',
    'GETGV', 'SETGV', 'GETSV', 'SETSV', 'GETIV', 'SETIV', 'GETCV', 'SETCV',
    'GETCONST', 'SETCONST', 'GETMCNST', 'SETMCNST', 'GETUPVAR',
    'GETIDX', 'GETIDX0', 'SETIDX',
    'JMP', 'JMPIF', 'JMPNOT', 'JMPNIL',
    'SSEND', 'SSEND0', 'SSENDB', 'SEND', 'SEND0', 'SENDB', 'SUPER', 'BLKCALL', 'BLKPUSH',
    'ENTER', 'KEY_P', 'KEYEND', 'KARG',
    'RETURN', 'RETURN_BLK', 'RETSELF', 'RETNIL', 'RETTRUE', 'RETFALSE', 'BREAK',
    'ADD', 'ADDI', 'SUB', 'SUBI', 'ADDILV', 'SUBILV', 'MUL', 'DIV',
    'EQ', 'LT', 'LE', 'GT', 'GE',
    'ARRAY', 'ARRAY2', 'ARYCAT', 'ARYPUSH', 'ARYSPLAT', 'AREF',
    'INTERN', 'SYMBOL', 'STRING', 'STRCAT', 'HASH', 'HASHADD', 'HASHCAT',
    'LAMBDA', 'BLOCK', 'METHOD', 'RANGE_INC', 'RANGE_EXC',
    'OCLASS', 'CLASS', 'MODULE', 'EXEC', 'DEF', 'TDEF', 'SDEF', 'ALIAS', 'UNDEF',
    'SCLASS', 'TCLASS', 'DEBUG', 'STOP'
  ].freeze

  # Ops whose leading register is only READ (vm.c tests or raises on regs[a]);
  # SETUPVAR stores into an enclosing frame, never a local. They step over
  # without defining anything. RAISEIF/MATCHERR fall through only on the
  # non-raising value, and the raise itself is a handler edge (refused below).
  READS_LEADING_REG_OPS = Set['JMPIF', 'JMPNOT', 'JMPNIL', 'RAISEIF', 'MATCHERR', 'SETUPVAR'].freeze

  # Ops that write a run of registers from their leading operand (vm.c), not just that operand. The run's extent
  # comes from the operands; only its values are runtime. ARGARY R(a) m1:r:m2:kd (vm.c OP_ARGARY, body 2492-2548)
  # writes R(a) (the rest Array, or the m1+m2 values without a rest), R(a+1) (the block slot, or the kdict with
  # keywords) and R(a+2) only when kd is set. APOST R(a) pre post (vm.c OP_APOST, body 3292-3324) writes R(a) (the
  # rest Array) and R(a+1)..R(a+post) (the post values, nil-filled when the array is short), whatever the array's
  # length. Both write only after their last check: ARGARY raises ("super called outside of method") before any
  # write, and APOST has no raise path of its own. Neither is a jump target or a block end, so a run opens no entry
  # point. Nil for every other op.
  def self.written_run(insn)
    lead = insn.reg
    return nil unless lead

    case insn.op
    when 'ARGARY'
      spec = insn.typed[1].value # [m1, r, m2, kd]
      lead.to_i..(lead.to_i + (spec[3] == 1 ? 2 : 1))
    when 'APOST'
      lead.to_i..(lead.to_i + insn.typed[2].value)
    end
  end

  # A callee's frame starts at R(a): it may overwrite every register above a.
  CALLEE_FRAME_OPS = Set['SEND', 'SEND0', 'SENDB', 'SSEND', 'SSEND0', 'SSENDB', 'SUPER', 'EXEC', 'BLKCALL'].freeze

  # Multi-write ops, refused by both walks (dataflow_effect). The vm.c fallback dispatch (L_SEND_SYM / L_SENDB_SYM)
  # starts a frame at R(a) and writes R(a+2) (nil); GETIDX0 and ADDI/SUBI also write R(a+1), SETIDX R(a+3). Every
  # such write is above a. ADDILV/SUBILV are not listed: their fallback is mrb_funcall, whose frame sits above the
  # caller's nregs.
  ORIGIN_FRAME_OPS = Set['GETIDX', 'GETIDX0', 'SETIDX', 'ADD', 'SUB', 'MUL', 'DIV', 'ADDI', 'SUBI',
                         'EQ', 'LT', 'LE', 'GT', 'GE', 'BLKCALL'].freeze

  # Expanded (instruction, register) states before a query gives up.
  DATAFLOW_MAX_STATES = 400

  class Program
    # Definitions of +reg+ (digits) that reach the read at the entry of
    # instruction +index+, sorted by index, or nil when the answer is not
    # provable. +follow_moves+ replaces a `MOVE Ra Rb` definition by the
    # definitions of Rb at that MOVE. +opaque_regs+ are registers written
    # outside this instruction list (nested blocks' SETUPVAR); asking about one
    # refuses, unless origin_transfers and no closure-creating op reaches +index+
    # (origin_closure_reach). Exception flow is not modelled: a query that touches a handler
    # target or a protected instruction refuses (RESCUE_SUPPORT compiles that
    # range apart, with re-initialised registers).
    #
    # +through_handlers+ (RECORD_HASH_PROOF, ADR 0285) crosses handler edges
    # instead of refusing at them: an instruction that can raise into a handler
    # contributes both the value it leaves (a completed write) and the value
    # it was entered with, since the raise happens before or after the write.
    #
    # +refusal+, when a Hash, receives `:cause` (the first reason the query
    # refused) and is otherwise not read: the answer is the same with or without it.
    def reaching_definitions(index, reg, opaque_regs: nil, follow_moves: true, max_states: DATAFLOW_MAX_STATES,
                             through_handlers: false, origin_transfers: false, refusal: nil)
      preds = instruction_predecessors
      return refused(refusal, :unresolved) unless preds
      return refused(refusal, :bad_index) unless index.between?(0, @instructions.length - 1)

      all_preds = through_handlers ? instruction_predecessors(include_handlers: true) : nil
      return refused(refusal, :unresolved) if through_handlers && !all_preds

      live = origin_transfers ? origin_reachable : nil
      if live
        # SETUPVAR writes into this frame only from a closure of it, which exists only after a closure-creating op
        # ran: with none reaching the query, opaque_regs cannot supply its value (see ORIGIN_CLOSURE_OPS).
        opaque_regs = nil unless origin_closure_reach.include?(index)
        # A query no execution reaches has no value to report, so it keeps its refusal.
        return refused(refusal, :no_predecessor) unless live.include?(index)
      end

      guarded = through_handlers ? Set.new : dataflow_handler_addrs
      seen = Set.new
      defs = Set.new
      work = [[index, reg.to_s]]
      until work.empty?
        i, r = work.pop
        next unless seen.add?([i, r])
        return refused(refusal, :state_cap) if seen.size > max_states
        return refused(refusal, :opaque_reg) if opaque_regs&.include?(r)
        return refused(refusal, :query_guarded) if guarded.include?(@instructions[i].addr)

        ps = all_preds ? all_preds[i] : preds[i]
        return refused(refusal, :no_predecessor) if ps.empty?

        ps.each do |p|
          if p == ENTRY
            defs << Definition.new(ENTRY, r)
            next
          end
          # Origin only: a predecessor no execution reaches (a jump left dead after a return) supplies no value.
          next if live && !live.include?(p)

          insn = @instructions[p].source
          # An origin-only EXCEPT defines its own register on every entry (origin_effect), so its handler
          # edges need not be known for that register.
          exact_entry = origin_transfers && insn.op == 'EXCEPT' && insn.reg == r
          return refused(refusal, :query_guarded) if guarded.include?(insn.addr) && !exact_entry
          # A protected JMPUW on a normal edge unwinds through its ensure (vm.c OP_JMPUW): the ensure body runs,
          # then RAISEIF jumps to the target, so that body's writes reach the target by no normal edge. The guard
          # above is off under through_handlers, so refuse here. The JMPUW's handler edge into the ensure stays
          # exact: the JMPUW writes nothing, so the ensure is entered with the values the JMPUW saw.
          return refused(refusal, :unwinding_jump) if insn.op == 'JMPUW' && preds[i].include?(p) &&
                                                     dataflow_handler_addrs.include?(insn.addr)

          # A handler-only edge may fire before the write completes.
          work << [p, r] if all_preds && !preds[i].include?(p)
          effect = origin_transfers ? origin_effect(insn, r) : dataflow_effect(insn, r)
          case effect
          when :refuse then return refused(refusal, "unmodelled:#{insn.op}")
          when :callee_clobber then return refused(refusal, :callee_frame_clobber)
          when :pass then work << [p, r]
          when :define
            if follow_moves && insn.op == 'MOVE'
              source = insn.regs[1]
              return refused(refusal, :move_without_source) unless source

              work << [p, source]
            else
              defs << Definition.new(p, r)
            end
          end
        end
      end
      defs.sort_by { |d| [d.index, d.reg.to_i] }
    end

    # JOIN_DOMINANCE (ADR 0261): does the write at +w+ (ENTRY: the method's
    # incoming value) supply +reg+ at +use+ on every path? True when no edge,
    # jump or exception, enters (w, use] from outside [w, use] and every op
    # stepped over is on the audited write list (ADR 0198's region test).
    # A multi-write op (ADD, GETIDX0, SEND, BLKCALL, ...) writes above its
    # leading register on a fallback or callee frame: an op stepped over that
    # does so to +reg+ (origin_effect :callee_clobber), or writes +reg+ itself
    # (:define), refuses, and so does a +w+ that is only a side write of +reg+.
    # ENTER's own slots are not refused here yet (see the join check). False
    # when an edge set is incomplete or a nested block writes +reg+.
    def write_dominates?(w, use, reg, opaque_regs: nil)
      return false if opaque_regs&.include?(reg.to_s)
      return false unless use.between?(0, @instructions.length - 1) && w >= ENTRY && w < use

      preds = instruction_predecessors(include_handlers: true) or return false
      low = [w, 0].max
      # The write itself must leave +reg+ holding its value on every path (a side write does not).
      return false if w >= 0 && origin_effect(@instructions[w].source, reg.to_s) != :define
      ((w + 1)..use).each do |k|
        insn = @instructions[k].source
        return false unless k == use || dataflow_steps_over?(insn)
        return false if k != use && %i[callee_clobber define].include?(origin_effect(insn, reg.to_s))

        preds[k].each do |p|
          return false if p == ENTRY ? w != ENTRY : (p < low || p > use)
        end
      end
      true
    end

    # Ops that leave the frame.
    FRAME_EXIT_OPS = Set['RETURN', 'RETURN_BLK', 'RETSELF', 'RETNIL', 'RETTRUE', 'RETFALSE', 'BREAK', 'STOP'].freeze
    # Ops that can hand `self` to code that reads its ivars.
    SELF_EXPOSING_OPS = Set['LOADSELF', 'SSEND', 'SSEND0', 'SSENDB', 'SUPER', 'BLOCK', 'LAMBDA', 'METHOD', 'EXEC', 'SCLASS'].freeze

    # INIT_ASSIGNED (ADR 0261): on every path, is `@ivar` assigned before it is
    # read, before the frame exits and before `self` can reach other code? A
    # zeroed typed slot would otherwise read 0/false where the ivar reads nil.
    # A forward must-analysis over normal and handler edges.
    def ivar_assigned_before_exposure?(ivar)
      preds = instruction_predecessors(include_handlers: true) or return false

      count = @instructions.length
      out = Array.new(count, true)
      changed = true
      while changed
        changed = false
        @instructions.each do |instruction|
          i = instruction.index
          reached = preds[i].map { |p| p == ENTRY ? false : out[p] }
          assigned = reached.empty? ? true : reached.all?
          assigned ||= instruction.source.op == 'SETIV' && instruction.source.ivar == ivar
          next if out[i] == assigned

          out[i] = assigned
          changed = true
        end
      end
      @instructions.all? do |instruction|
        i = instruction.index
        insn = instruction.source
        reached = preds[i].map { |p| p == ENTRY ? false : out[p] }
        assigned = reached.empty? || reached.all?
        observes = FRAME_EXIT_OPS.include?(insn.op) || SELF_EXPOSING_OPS.include?(insn.op) ||
                   (insn.op == 'GETIV' && insn.ivar == ivar) ||
                   (!%w[GETIV SETIV].include?(insn.op) && insn.regs.include?('0'))
        assigned || !observes
      end
    end

    # True when +index+'s value of +reg+ can only come from definitions for
    # which the block answers true (nil when the query refuses, so callers
    # cannot mistake a refusal for "no").
    def every_reaching_definition(index, reg, **options)
      defs = reaching_definitions(index, reg, **options) or return nil
      defs.all? { |d| yield d }
    end

    private

    # On the audited list of ops that write at most their leading register.
    def dataflow_steps_over?(insn)
      op = insn.op
      READS_LEADING_REG_OPS.include?(op) || WRITES_LEADING_REG_OPS.include?(op) || op.start_with?('LOADI')
    end

    # Origin-only transfers (SiteOriginTable's walk; codegen never passes origin_transfers:, so its answers
    # do not change). Each one follows vm.c for the op. JMPUW writes no register: its ensure unwinding needs
    # a protected range, and a protected predecessor is refused before this runs. RESCUE a b (vm.c OP_RESCUE)
    # reads R[a] and writes only R[b] (the match result). EXCEPT a (vm.c OP_EXCEPT) stores the exception or
    # nil into R[a] on every entry; the walk reaches it only for R[a] (see reaching_definitions).
    # ORIGIN_FRAME_OPS clobber or write above R(a) on a path the leading-register model misses. ENTER's rest,
    # post, keyword and block slots and its locals take values ENTER builds (see enter_passes?).
    def origin_effect(insn, reg)
      case insn.op
      when 'JMPUW' then :pass
      when 'RESCUE'
        second = insn.typed[1]
        second&.kind == :reg && second.value.to_s == reg ? :define : :pass
      when 'EXCEPT' then insn.reg == reg ? :define : :refuse
      when 'ENTER' then enter_passes?(insn, reg) ? :pass : :refuse
      else dataflow_effect(insn, reg)
      end
    end

    # Instruction indices reachable from the method entry over normal and handler edges (origin only), or nil
    # when a handler target does not resolve: the edge set is then incomplete, and a predecessor outside it
    # cannot be called dead.
    def origin_reachable
      return @origin_reachable if defined?(@origin_reachable)

      @origin_reachable = nil
      return nil unless handlers_resolved?

      extra = Hash.new { |h, k| h[k] = [] }
      handler_edges.each { |edge| extra[edge.src] << edge.target }
      @origin_reachable = forward_reachable([0], extra)
    end

    # Instruction indices a closure-creating op can reach (origin only): a block or lambda of this frame, or a
    # body run in place (EXEC, CLASS, MODULE, SCLASS), can write an outer register only once one of those ops
    # has run. Nil when handler edges do not resolve, as origin_reachable.
    ORIGIN_CLOSURE_OPS = Set['BLOCK', 'LAMBDA', 'EXEC', 'CLASS', 'MODULE', 'SCLASS'].freeze

    def origin_closure_reach
      return @origin_closure_reach if defined?(@origin_closure_reach)

      @origin_closure_reach = nil
      return nil unless handlers_resolved?

      extra = Hash.new { |h, k| h[k] = [] }
      handler_edges.each { |edge| extra[edge.src] << edge.target }
      starts = @instructions.filter_map { |i| i.index if ORIGIN_CLOSURE_OPS.include?(i.source.op) }
                            .flat_map { |c| @instructions[c].successors + extra[c] }
      @origin_closure_reach = forward_reachable(starts, extra)
    end

    # Indices reached from +starts+ (inclusive) over normal successors and the +extra+ edges.
    def forward_reachable(starts, extra)
      seen = Set.new
      work = starts.dup
      until work.empty?
        i = work.pop
        next unless seen.add?(i)

        @instructions[i].successors.each { |s| work << s }
        extra[i].each { |t| work << t }
      end
      seen.freeze
    end

    # vm.c OP_ENTER binds the arguments to R[1..req+opt] as passed, so a passed argument is its entry value.
    # The one exception is R[1] without keywords: argc==14 with a keyword hash packs the arguments into an
    # array there. R[0] (self) is never written.
    def enter_passes?(insn, reg)
      return true if reg == '0'

      req, opt, _rest, _post, kw, kwrest = insn.enter_fields
      keywords = kw.to_i.positive? || kwrest.to_i.positive?
      n = reg.to_i
      n.between?(1, req.to_i + opt.to_i) && (n != 1 || keywords)
    end

    # :pass (writes nothing relevant), :define (writes +reg+), :callee_clobber
    # (a callee frame at a lower register may overwrite +reg+) or :refuse.
    def dataflow_effect(insn, reg)
      op = insn.op
      return :pass if READS_LEADING_REG_OPS.include?(op)
      run = BytecodeIR.written_run(insn)
      return(run.cover?(reg.to_i) ? :define : :pass) if run
      lead = insn.reg
      return :callee_clobber if ORIGIN_FRAME_OPS.include?(op) && (lead.nil? || lead.to_i < reg.to_i)
      return :refuse unless WRITES_LEADING_REG_OPS.include?(op) || op.start_with?('LOADI')

      return :callee_clobber if CALLEE_FRAME_OPS.include?(op) && lead && lead.to_i < reg.to_i

      lead == reg ? :define : :pass
    end

    # Records the first refusal reason in +refusal+ (when given) and returns nil.
    def refused(refusal, cause)
      refusal[:cause] ||= cause if refusal
      nil
    end

    # Addresses the dataflow refuses to reason across: handler targets and the
    # protected ranges (end included, as the Fixnum proof's barrier does).
    def dataflow_handler_addrs
      @dataflow_handler_addrs ||= (handler_target_addrs | handler_protected_addrs(inclusive_end: true)).freeze
    end
  end

  # Registers of +irep+ that a nested block writes with SETUPVAR (only the
  # level that reaches +irep+ itself counts). Needs the irep tree (Irep#tree);
  # without it, every local register of an irep that has children is treated
  # as written.
  def self.own_upvar_written_regs(irep)
    cached = irep.instance_variable_get(:@own_upvar_written_regs)
    return cached if cached

    written = Set.new
    if !irep.reps.nil? && !irep.reps.empty?
      tree = irep.tree
      if tree
        collect_upvar_writes(tree, irep, 1, written)
      else
        (1...irep.nlocals.to_i).each { |n| written << n.to_s }
      end
    end
    irep.instance_variable_set(:@own_upvar_written_regs, written.freeze)
  end

  def self.collect_upvar_writes(tree, irep, depth, written)
    Array(irep.reps).each do |label|
      child = tree[label]
      raise ArgumentError, "bc2cpp: irep #{label} missing from the tree" unless child

      child.instructions.each do |insn|
        next unless insn.op == 'SETUPVAR'

        index, level = insn.upvar_ref
        written << index.to_s if level == depth - 1
      end
      collect_upvar_writes(tree, child, depth + 1, written)
    end
  end

  # Definitions reaching a read of +reg+ at +index+ in +irep+ with the irep's
  # own nested-block writes accounted for. See Program#reaching_definitions.
  def self.reaching_definitions(irep, index, reg, **options)
    self.for(irep).reaching_definitions(index, reg, opaque_regs: own_upvar_written_regs(irep), **options)
  end

  # Program#write_dominates? with the irep's own nested-block writes accounted for.
  def self.write_dominates?(irep, w, use, reg)
    self.for(irep).write_dominates?(w, use, reg, opaque_regs: own_upvar_written_regs(irep))
  end
end
