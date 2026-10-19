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
  # (the MOVE source when the chain was followed). +built+ is set when the
  # writer is an ENTER that stores the slot itself (Program#enter_built_kind,
  # origin walk only): :rest (an Array), :hash (a Hash), :block (a Proc or nil),
  # :arg (R1, a parameter's value), :post (a post parameter's value or nil) or
  # :local (nil). nil for every other definition.
  Definition = Struct.new(:index, :reg, :built) do
    def entry?
      index == ENTRY
    end
  end

  # Ops that write at most the register in their leading operand and open no
  # entry point (ops.h, vm.c). CodeGen::FIXNUM_PROOF_STEP_OVER_OPS is this
  # Set (ADR 0476). LOADI* is matched by prefix. Anything else refuses.
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
  # Exhaustive test/report queries must not retain a quadratic number of answers per body.
  DATAFLOW_CACHE_SIZE = 1024

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
    #
    # +raiseif_nil+ (RETURN_SITES, ADR 0503): vm.c OP_RAISEIF falls through only when R(a) is nil, so a RAISEIF of
    # the register on a normal edge is itself its definition (the nil value), not a step over.
    def reaching_definitions(index, reg, opaque_regs: nil, follow_moves: true, max_states: DATAFLOW_MAX_STATES,
                             through_handlers: false, origin_transfers: false, refusal: nil, raiseif_nil: false)
      # Mutable opaque sets and refusal diagnostics belong to the caller; do not retain them.
      if refusal || (opaque_regs && !opaque_regs.frozen?)
        return compute_reaching_definitions(index, reg, opaque_regs: opaque_regs, follow_moves: follow_moves,
                                            max_states: max_states, through_handlers: through_handlers,
                                            origin_transfers: origin_transfers, refusal: refusal,
                                            raiseif_nil: raiseif_nil)
      end

      @reaching_definitions_cache ||= {}
      opaque_key = opaque_regs&.map { |r| r.dup.freeze }&.sort&.freeze
      key = [index, reg.to_s.dup.freeze, opaque_key, follow_moves, max_states, through_handlers, origin_transfers,
             raiseif_nil]
      unless @reaching_definitions_cache.key?(key)
        result = compute_reaching_definitions(index, reg, opaque_regs: opaque_regs, follow_moves: follow_moves,
                                             max_states: max_states, through_handlers: through_handlers,
                                             origin_transfers: origin_transfers, raiseif_nil: raiseif_nil)
        return result if @reaching_definitions_cache.size >= DATAFLOW_CACHE_SIZE

        @reaching_definitions_cache[key] = result&.map { |d| Definition.new(d.index, d.reg.dup.freeze, d.built).freeze }&.freeze
      end
      # Definitions have a mutable public API; each caller receives its own copies.
      @reaching_definitions_cache[key]&.map { |d| Definition.new(d.index, d.reg.dup, d.built) }
    end

    def compute_reaching_definitions(index, reg, opaque_regs: nil, follow_moves: true, max_states: DATAFLOW_MAX_STATES,
                                     through_handlers: false, origin_transfers: false, refusal: nil, raiseif_nil: false)
      preds = instruction_predecessors
      return refused(refusal, :unresolved) unless preds
      return refused(refusal, :bad_index) unless index.between?(0, @instructions.length - 1)

      all_preds = through_handlers ? instruction_predecessors(include_handlers: true) : nil
      return refused(refusal, :unresolved) if through_handlers && !all_preds

      pred_lists = predecessor_lists(false)
      all_pred_lists = all_preds && predecessor_lists(true)

      # Instructions some execution reaches (nil when a handler target does not resolve). A predecessor outside
      # it supplies no value to a live state, so it is skipped in every mode (ADR 0476). A state that is itself
      # dead (a dead query, or a walk inside dead code) keeps every predecessor, as before.
      live = origin_reachable
      if origin_transfers && live
        # SETUPVAR writes into this frame only from a closure of it, which exists only after a closure-creating op
        # ran: with none reaching the query, opaque_regs cannot supply its value (see ORIGIN_CLOSURE_OPS).
        opaque_regs = nil unless origin_closure_reach.include?(index)
        # A query no execution reaches has no value to report, so it keeps its refusal.
        return refused(refusal, :no_predecessor) unless live.include?(index)
      end

      # Per-index flags instead of address sets, and a flat (index, register) work stack: the walk allocates
      # nothing per state but the seen entry (NUMERIC_FLOW_SPEED's lesson, ADR 0467). The answer is the same.
      guarded = through_handlers ? nil : dataflow_guarded_at
      live_at = live && live_flags
      seen = {}
      states = 0
      defs = Set.new
      work = [index, reg.to_s]
      until work.empty?
        r = work.pop
        i = work.pop
        seen_here = (seen[i] ||= {})
        next if seen_here.key?(r)

        seen_here[r] = true
        states += 1
        return refused(refusal, :state_cap) if states > max_states
        return refused(refusal, :opaque_reg) if opaque_regs&.include?(r)
        return refused(refusal, :query_guarded) if guarded && guarded[i]

        ps = (all_preds ? all_pred_lists : pred_lists)[i]
        return refused(refusal, :no_predecessor) if ps.empty?

        live_here = live_at && live_at[i]
        ps.each do |p|
          if p == ENTRY
            defs << Definition.new(ENTRY, r)
            next
          end
          # A predecessor no execution reaches (a jump left dead after a return) supplies no value to a live state.
          next if live_here && !live_at[p]

          insn = @instructions[p].source
          # An origin-only EXCEPT defines its own register on every entry (origin_effect), so its handler
          # edges need not be known for that register.
          return refused(refusal, :query_guarded) if guarded && guarded[p] &&
                                                     !(origin_transfers && insn.op == 'EXCEPT' && insn.reg == r)
          # A protected JMPUW on a normal edge unwinds through its ensure (vm.c OP_JMPUW): the ensure body runs,
          # then RAISEIF jumps to the target, so that body's writes reach the target by no normal edge. The guard
          # above is off under through_handlers, so refuse here. The JMPUW's handler edge into the ensure stays
          # exact: the JMPUW writes nothing, so the ensure is entered with the values the JMPUW saw.
          return refused(refusal, :unwinding_jump) if insn.op == 'JMPUW' && preds[i].include?(p) &&
                                                     dataflow_guarded_at[p]

          if raiseif_nil && insn.op == 'RAISEIF' && insn.reg == r && preds[i].include?(p) &&
             !raise_targets.fetch(p, EMPTY_TARGETS).include?(i)
            defs << Definition.new(p, r)
            next
          end
          # A handler-only edge may fire before the write completes.
          work.push(p, r) if all_preds && !preds[i].include?(p)
          effect = origin_transfers ? origin_effect(insn, r) : effect_of(dataflow_effect_at(p), r)
          case effect
          when :refuse then return refused(refusal, "unmodelled:#{insn.op}")
          when :refuse_enter_shape, :refuse_enter_temp
            return refused(refusal, "unmodelled:ENTER:#{effect.to_s.delete_prefix('refuse_enter_')}")
          when :callee_clobber then return refused(refusal, :callee_frame_clobber)
          when :pass then work.push(p, r)
          when :define
            if follow_moves && insn.op == 'MOVE'
              source = insn.regs[1]
              return refused(refusal, :move_without_source) unless source

              work.push(p, source)
            else
              built = insn.op == 'ENTER' ? enter_built_kind(insn, r) : nil
              defs << Definition.new(p, r, built)
            end
          end
        end
      end
      defs.sort_by { |d| [d.index, d.reg.to_i] }
    end

    private :compute_reaching_definitions

    # JOIN_DOMINANCE (ADR 0261): does the write at +w+ (ENTRY: the method's
    # incoming value) supply +reg+ at +use+ on every path? True when no edge,
    # jump or exception, enters (w, use] from outside [w, use] and every op
    # stepped over is on the audited write list (ADR 0198's region test).
    # A multi-write op (ADD, GETIDX0, SEND, BLKCALL, ...) writes above its
    # leading register on a fallback or callee frame: an op stepped over that
    # does so to +reg+ (origin_effect :callee_clobber), or writes +reg+ itself
    # (:define), refuses, and so does a +w+ that is only a side write of +reg+.
    # ENTER's own slots are not refused here yet (see the join check). False
    # when an edge set is incomplete or a nested block writes +reg+. Codegen's answer: ENTER's typed slots
    # (origin_effect typed_enter) stay refused here, as they were before the origin walk typed them.
    def write_dominates?(w, use, reg, opaque_regs: nil)
      return compute_write_dominates?(w, use, reg, opaque_regs: opaque_regs) if opaque_regs && !opaque_regs.frozen?

      @write_dominates_cache ||= {}
      opaque_key = opaque_regs&.map { |r| r.dup.freeze }&.sort&.freeze
      key = [w, use, reg.to_s.dup.freeze, opaque_key]
      unless @write_dominates_cache.key?(key)
        result = compute_write_dominates?(w, use, reg, opaque_regs: opaque_regs)
        return result if @write_dominates_cache.size >= DATAFLOW_CACHE_SIZE

        @write_dominates_cache[key] = result
      end
      @write_dominates_cache[key]
    end

    def compute_write_dominates?(w, use, reg, opaque_regs: nil)
      return false if opaque_regs&.include?(reg.to_s)
      return false unless use.between?(0, @instructions.length - 1) && w >= ENTRY && w < use

      preds = instruction_predecessors(include_handlers: true) or return false
      low = [w, 0].max
      # The write itself must leave +reg+ holding its value on every path (a side write does not).
      return false if w >= 0 && origin_effect(@instructions[w].source, reg.to_s, typed_enter: false) != :define
      ((w + 1)..use).each do |k|
        insn = @instructions[k].source
        return false unless k == use || dataflow_steps_over?(insn)
        # An exit's leading register is read, not written, and nothing falls through from it to +use+.
        return false if k != use && !FRAME_EXIT_OPS.include?(insn.op) &&
                        %i[callee_clobber define].include?(origin_effect(insn, reg.to_s, typed_enter: false))

        preds[k].each do |p|
          return false if p == ENTRY ? w != ENTRY : (p < low || p > use)
        end
      end
      true
    end

    private :compute_write_dominates?

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

    # Can +insn+ change +reg+ (digits)? The reaching-definitions model: anything but :pass (a write, a callee frame
    # below the register, an unmodelled op) counts. NIL_NARROWING and the captured-parameter rule read it
    # (rbs_param_check.rb, nil_narrowing.rb).
    def may_write?(insn, reg)
      dataflow_effect(insn, reg.to_s) != :pass
    end

    # may_write? of the instruction at +index+, from the walk's per-instruction effect table.
    def may_write_at?(index, reg)
      effect_of(dataflow_effect_at(index), reg.to_s) != :pass
    end

    private

    # On the audited list of ops that write at most their leading register.
    def dataflow_steps_over?(insn)
      op = insn.op
      READS_LEADING_REG_OPS.include?(op) || WRITES_LEADING_REG_OPS.include?(op) || op.start_with?('LOADI')
    end

    # Origin-only transfers (SiteOriginTable's walk; codegen never passes origin_transfers:, so its answers
    # do not change). Each one follows vm.c for the op. RESCUE a b (vm.c OP_RESCUE)
    # reads R[a] and writes only R[b] (the match result). EXCEPT a (vm.c OP_EXCEPT, :2161-2192) stores the exception
    # or nil into R[a] on every entry and writes no other register, so any other register passes through it to the
    # handler edges into it. Those edges exist only under through_handlers: the normal walk refuses at the handler
    # target (a guarded instruction) before this runs, except for R[a] itself (see reaching_definitions).
    # ORIGIN_FRAME_OPS clobber or write above R(a) on a path the leading-register model misses. ENTER is answered
    # by its register layout (enter_origin_effect). With typed_enter: false (write_dominates?, shared with
    # codegen) ENTER answers as it did before the origin walk typed its slots: self and a required or optional
    # argument pass to the entry value, every other slot (and the packed R(1)) refuses.
    def origin_effect(insn, reg, typed_enter: true)
      case insn.op
      when 'RESCUE'
        second = insn.typed[1]
        second&.kind == :reg && second.value.to_s == reg ? :define : :pass
      when 'EXCEPT' then insn.reg == reg ? :define : :pass
      when 'ENTER'
        if typed_enter then enter_origin_effect(insn, reg)
        else enter_passes?(insn, reg) ? :pass : :refuse
        end
      else dataflow_effect(insn, reg)
      end
    end

    # The slot of ENTER's register layout +reg+ names (origin walk only), from the vm.c register numbers
    # (3rd/mruby/src/vm.c OP_ENTER). With len = req + opt + rest + post and kd = 1 when the method takes
    # keywords or **rest (key > 0 or kdict):
    #   self   R0                  never written
    #   entry  R[2..req+opt]       a required or optional argument, or with keywords R[1]: its entry value
    #   arg    R[1], no keywords   the first positional parameter. ENTER can rebind it (vm.c:2647 packs the
    #                              arguments and a keyword hash into R1, and the moves at :2695 and :2720
    #                              overwrite it), so it is not the entry value, but every exit leaves the
    #                              parameter's value there (an argument, or nil when a proc got none)
    #   rest   R[req+opt+1]        an Array built from the extra arguments (vm.c:2710, :2725)
    #   post   R[req+opt+rest+1..len]  a post parameter: the argument moved there, or nil when none was passed
    #                              (vm.c:2700-2705, :2728; a post parameter implies a rest or optional one,
    #                              so the moves are not skipped by the argc-m2 > m1 test)
    #   hash   R[len+1]            the keyword Hash, passed or new (kd only; vm.c:2741)
    #   block  R[len+kd+1]         the block the caller passed, a Proc or nil (vm.c:2736). In the fast path
    #                              (no rest, optional, post or keywords; vm.c:2603-2612) ENTER stores nothing
    #                              here, and the caller has already put the same block in that slot
    #   local  R[len+kd+2..nlocals-1]  nil: stack_clear on both exits (vm.c:2612, :2750)
    #   temp   R[nlocals..]        not touched by ENTER: whatever the caller's frame left there
    # Field order is ENTER's operand (req:opt:rest:post:key:kdict:block:_), checked against mrbc output.
    # Nil when the operand does not have those eight fields, and :temp when the irep's nlocals is unknown.
    def enter_slot(insn, reg)
      fields = insn.enter_fields
      return nil unless fields.size == 8

      req, opt, rest, post, key, kdict = fields.first(6).map(&:to_i)
      n = reg.to_i
      kd = key.positive? || kdict.positive? ? 1 : 0
      len = req + opt + rest + post
      return :self if n.zero?
      return(n == 1 && kd.zero? ? :arg : :entry) if n <= req + opt
      return :rest if rest.positive? && n == req + opt + 1
      return :post if n <= len
      return :hash if kd == 1 && n == len + 1
      return :block if n == len + kd + 1

      nlocals && n < nlocals ? :local : :temp
    end

    # ENTER as a writer for the origin walk: :define for every slot ENTER stores (enter_built_kind says what),
    # :pass for self and the argument slots that keep their entry value, and a counted refusal for a register
    # ENTER does not account for (:refuse_enter_temp: a temporary above nlocals, or an irep without nlocals;
    # :refuse_enter_shape: an operand without the eight ASPEC fields).
    def enter_origin_effect(insn, reg)
      case enter_slot(insn, reg)
      when nil then :refuse_enter_shape
      when :self, :entry then :pass
      when :temp then :refuse_enter_temp
      else :define
      end
    end

    # The kind of value vm.c OP_ENTER stores into +reg+ (see enter_slot): :arg, :rest, :post, :hash, :block or
    # :local. nil for a register ENTER leaves alone (self and the entry-valued arguments) or does not account for.
    def enter_built_kind(insn, reg)
      kind = enter_slot(insn, reg)
      %i[arg rest post hash block local].include?(kind) ? kind : nil
    end

    # Instruction indices reachable from the method entry over normal and handler edges, or nil
    # when a handler target does not resolve: the edge set is then incomplete, and a predecessor outside it
    # cannot be called dead.
    def origin_reachable
      return @origin_reachable if defined?(@origin_reachable)

      @origin_reachable = nil
      return nil unless handlers_resolved?

      @origin_reachable = forward_reachable([0])
    end

    # Instruction indices a closure-creating op can reach (origin only): a block or lambda of this frame, or a
    # body run in place (EXEC, CLASS, MODULE, SCLASS), can write an outer register only once one of those ops
    # has run. Nil when handler edges do not resolve, as origin_reachable.
    ORIGIN_CLOSURE_OPS = Set['BLOCK', 'LAMBDA', 'EXEC', 'CLASS', 'MODULE', 'SCLASS'].freeze

    def origin_closure_reach
      return @origin_closure_reach if defined?(@origin_closure_reach)

      @origin_closure_reach = nil
      return nil unless handlers_resolved?

      starts = @instructions.filter_map { |i| i.index if ORIGIN_CLOSURE_OPS.include?(i.source.op) }
                            .flat_map { |c| @instructions[c].successors + raise_targets.fetch(c, EMPTY_TARGETS) }
      @origin_closure_reach = forward_reachable(starts)
    end

    EMPTY_TARGETS = [].freeze

    # Indices reached from +starts+ (inclusive) over normal successors and the handler edges (#raise_targets).
    def forward_reachable(starts)
      seen = Set.new
      work = starts.dup
      until work.empty?
        i = work.pop
        next unless seen.add?(i)

        @instructions[i].successors.each { |s| work << s }
        raise_targets.fetch(i, EMPTY_TARGETS).each { |t| work << t }
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
    # JMPUW writes no register (vm.c OP_JMPUW). Only an ensure whose range
    # covers it can run code on the way to its target, and a protected
    # predecessor is refused before this runs (the normal walk's guard, the
    # through_handlers walk's :unwinding_jump), so one that gets here is a
    # plain jump (ADR 0476; CodeGen#jmpuw_plain_jump_at? asks the narrower
    # question for emission).
    def dataflow_effect(insn, reg)
      effect_of(EffectEntry.for(insn), reg)
    end

    # What dataflow_effect needs of one instruction, independent of the register asked about: built once per
    # instruction for the walk (dataflow_effect_at), on the fly for the other callers.
    EffectEntry = Struct.new(:pass, :run, :frame, :writes, :callee, :lead, :lead_i) do
      def self.for(insn)
        op = insn.op
        lead = insn.reg
        new(READS_LEADING_REG_OPS.include?(op) || op == 'JMPUW', BytecodeIR.written_run(insn),
            ORIGIN_FRAME_OPS.include?(op), WRITES_LEADING_REG_OPS.include?(op) || op.start_with?('LOADI'),
            CALLEE_FRAME_OPS.include?(op), lead, lead&.to_i).freeze
      end
    end

    def effect_of(entry, reg)
      return :pass if entry.pass
      return(entry.run.cover?(reg.to_i) ? :define : :pass) if entry.run
      return :callee_clobber if entry.frame && (entry.lead_i.nil? || entry.lead_i < reg.to_i)
      return :refuse unless entry.writes
      return :callee_clobber if entry.callee && entry.lead_i && entry.lead_i < reg.to_i

      entry.lead == reg ? :define : :pass
    end

    # Filled as the walks reach each instruction: an operand is decoded only when an answer needs it, as before.
    def dataflow_effect_at(index)
      (@dataflow_effect_table ||= Array.new(@instructions.length))[index] ||=
        EffectEntry.for(@instructions[index].source)
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

    # instruction_predecessors as frozen Arrays in the same order (the walk only iterates them).
    def predecessor_lists(include_handlers)
      @predecessor_lists ||= {}
      @predecessor_lists[include_handlers] ||= instruction_predecessors(include_handlers: include_handlers)
                                                .map { |set| set.to_a.freeze }.freeze
    end

    # dataflow_handler_addrs as a flag per instruction index.
    def dataflow_guarded_at
      @dataflow_guarded_at ||= begin
        addrs = dataflow_handler_addrs
        @instructions.map { |instruction| addrs.include?(instruction.addr) }.freeze
      end
    end

    # origin_reachable as a flag per instruction index (nil when it is nil).
    def live_flags
      return @live_flags if defined?(@live_flags)

      live = origin_reachable
      @live_flags = live && Array.new(@instructions.length) { |i| live.include?(i) }.freeze
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
        collect_upvar_writes(tree, irep, written)
      else
        (1...irep.nlocals.to_i).each { |n| written << n.to_s }
      end
    end
    irep.instance_variable_set(:@own_upvar_written_regs, written.freeze)
  end

  # Every instruction of +irep+ and of the ireps nested in it, as (insn, depth): depth 0 for +irep+'s own, 1 for a
  # direct child's, and so on. +lookup+ maps a rep label to its Irep (nil skips that child). Relative to the root
  # +irep+, an upvar reference at level L in an instruction at depth k names the frame k - L - 1 (-1 is the root's
  # parent). Returns false, stopping the walk, when a nested irep is deeper than +max_depth+; true otherwise.
  def self.each_nested_insn(irep, lookup, depth = 0, max_depth: nil, &block)
    return false if max_depth && depth > max_depth

    irep.instructions.each { |insn| block.call(insn, depth) }
    Array(irep.reps).each do |label|
      child = lookup.call(label)
      next unless child
      return false unless each_nested_insn(child, lookup, depth + 1, max_depth: max_depth, &block)
    end
    true
  end

  # SETUPVAR registers that the blocks nested in +irep+ write in +irep+'s frame (only the level that reaches +irep+
  # counts: a child's own level-0 references, a grandchild's level-1 ones, ...).
  def self.collect_upvar_writes(tree, irep, written)
    lookup = ->(label) { tree[label] or raise ArgumentError, "bc2cpp: irep #{label} missing from the tree" }
    Array(irep.reps).each do |label|
      each_nested_insn(lookup.call(label), lookup) do |insn, depth|
        next unless insn.op == 'SETUPVAR'

        index, level = insn.upvar_ref
        written << index.to_s if level == depth
      end
    end
  end

  # Definitions reaching a read of +reg+ at +index+ in +irep+ with the irep's
  # own nested-block writes accounted for. See Program#reaching_definitions.
  def self.reaching_definitions(irep, index, reg, **options)
    self.for(irep).reaching_definitions(index, reg, opaque_regs: own_upvar_written_regs(irep), **options)
  end

  # The instruction writers of +reg+ that reach the read at +index+, as [index, instruction] pairs: one per join arm.
  # Nil when the answer is not provable (a refusal, the method's entry value, or a definition whose instruction does
  # not write that register).
  def self.writers_reaching(irep, index, reg)
    defs = reaching_definitions(irep, index, reg.to_s, origin_transfers: true)
    return nil unless defs && !defs.empty? && defs.none?(&:entry?)

    defs.map do |definition|
      insn = irep.instructions[definition.index]
      return nil unless insn.reg == definition.reg

      [definition.index, insn]
    end
  end

  # Whether every writer of +reg+ reaching the read at +index+ passes the block (see writers_reaching). A refusal fails.
  def self.all_writers_reaching?(irep, index, reg)
    writers = writers_reaching(irep, index, reg)
    !writers.nil? && writers.all? { |writer_index, insn| yield writer_index, insn }

  end

  # Instruction indices of every write of +reg+ that reaches the read at +index+ (MOVEs followed), or nil when the
  # answer is not provable, when none reaches, or when the method entry is among them (the value came in as an
  # argument). A walk over the textually last writer answers for one arm of a join only; ask this for all of them.
  # Handler edges are crossed (through_handlers), so a read inside a rescue range is answered, not refused.
  def self.reaching_writer_indices(irep, index, reg)
    defs = reaching_definitions(irep, index, reg, through_handlers: true)
    return nil if defs.nil? || defs.empty? || defs.any?(&:entry?)

    defs.map(&:index)
  end

  # Program#write_dominates? with the irep's own nested-block writes accounted for.
  def self.write_dominates?(irep, w, use, reg)
    self.for(irep).write_dominates?(w, use, reg, opaque_regs: own_upvar_written_regs(irep))
  end
end
