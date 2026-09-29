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

  # A callee's frame starts at R(a): it may overwrite every register above a.
  CALLEE_FRAME_OPS = Set['SEND', 'SEND0', 'SENDB', 'SSEND', 'SSEND0', 'SSENDB', 'SUPER', 'EXEC'].freeze

  # Expanded (instruction, register) states before a query gives up.
  DATAFLOW_MAX_STATES = 400

  class Program
    # Definitions of +reg+ (digits) that reach the read at the entry of
    # instruction +index+, sorted by index, or nil when the answer is not
    # provable. +follow_moves+ replaces a `MOVE Ra Rb` definition by the
    # definitions of Rb at that MOVE. +opaque_regs+ are registers written
    # outside this instruction list (nested blocks' SETUPVAR); asking about one
    # refuses. Exception flow is not modelled: a query that touches a handler
    # target or a protected instruction refuses (RESCUE_SUPPORT compiles that
    # range apart, with re-initialised registers).
    def reaching_definitions(index, reg, opaque_regs: nil, follow_moves: true, max_states: DATAFLOW_MAX_STATES)
      preds = instruction_predecessors
      return nil unless preds
      return nil unless index.between?(0, @instructions.length - 1)

      guarded = dataflow_handler_addrs
      seen = Set.new
      defs = Set.new
      work = [[index, reg.to_s]]
      until work.empty?
        i, r = work.pop
        next unless seen.add?([i, r])
        return nil if seen.size > max_states
        return nil if opaque_regs&.include?(r)
        return nil if guarded.include?(@instructions[i].addr)

        ps = preds[i]
        return nil if ps.empty?

        ps.each do |p|
          if p == ENTRY
            defs << Definition.new(ENTRY, r)
            next
          end

          insn = @instructions[p].source
          return nil if guarded.include?(insn.addr)

          case dataflow_effect(insn, r)
          when :refuse then return nil
          when :pass then work << [p, r]
          when :define
            if follow_moves && insn.op == 'MOVE'
              source = insn.regs[1]
              return nil unless source

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
    # False when an edge set is incomplete or a nested block writes +reg+.
    def write_dominates?(w, use, reg, opaque_regs: nil)
      return false if opaque_regs&.include?(reg.to_s)
      return false unless use.between?(0, @instructions.length - 1) && w >= ENTRY && w < use

      preds = instruction_predecessors(include_handlers: true) or return false
      low = [w, 0].max
      ((w + 1)..use).each do |k|
        insn = @instructions[k].source
        return false unless k == use || dataflow_steps_over?(insn)

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

    # :pass (writes nothing relevant), :define (writes +reg+) or :refuse.
    def dataflow_effect(insn, reg)
      op = insn.op
      return :pass if READS_LEADING_REG_OPS.include?(op)
      return :refuse unless WRITES_LEADING_REG_OPS.include?(op) || op.start_with?('LOADI')

      lead = insn.reg
      return :refuse if CALLEE_FRAME_OPS.include?(op) && lead && lead.to_i < reg.to_i

      lead == reg ? :define : :pass
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
