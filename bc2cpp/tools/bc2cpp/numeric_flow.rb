# frozen_string_literal: true

require 'set'
require_relative 'bytecode_ir_ops'
require_relative 'bytecode_ir'
require_relative 'bytecode_ir_numeric'

# NUMERIC_FLOW: a forward dataflow over one irep that says which
# registers provably hold an Integer (fixnum or bigint), a Float, an exact
# Array/Hash/String or nil at each instruction. It is the unguarded proof behind
# dropping the dynamic-send else of the guarded arithmetic and compare arms; it
# never trusts a hint or a runtime guard.
#
# Lattice per register: the set of classes the register may hold.
#   INT   an Integer (fixnum OR bigint -- never assume it fits mrb_int)
#   FLT   a Float
#   ARR   exactly ::Array (not a subclass)
#   HSH   exactly ::Hash
#   STR   exactly ::String
#   NIL   nil
#   OTHER anything else, including false and an unassigned local's other uses
#   RNG   exactly ::Range; EXC a pending exception object (what EXCEPT reads); and the bits from 1 << 9 up: exactly one closed-world class each
#         (CodeGen#numeric_class_bit). They enter through a proven `Klass.new`, a Range literal, or a true, false or
#         Symbol literal (LOADTRUE, LOADFALSE, LOADSYM: TrueClass, FalseClass, Symbol) and reach other methods only
#         through return values or the class pools. The Symbol bit also comes from a Symbol element of a
#         frozen literal and from a LOADSYM register (the numeric oracle's
#         literal_class_mask). FalseClass is the one falsy class bit: a truthiness
#         test leaves it on the falsy edge only. The oracle's false_class_bit names it; an oracle that names none
#         keeps every class bit on both edges (falsy_class_bits).
# Bits from OBJECT_KIND_BASE up are object kinds the oracle names: each is
# "exactly an instance of that kind" and truthy, like ARR. Unlike the class bits they ride through
# pooled arguments, ivars and constants; what a bit means, and what `[]` on it returns, is the
# oracle's (`index_mask`).
# 0 is "no value yet" (unreached). Join is bitwise OR, so the answer cannot
# depend on visiting order. A register is numeric when its set is a non-empty
# subset of INT|FLT.
#
# Instance variables the compiler tracks ride along as extra registers past the
# real ones ("slots"), so `@i = 0; ... @i + 1` and a loop-carried `@i += 1`
# are ordinary dataflow. What another method may store into a slot is bounded by
# the whole-program fact the oracle supplies. A register loaded
# from a slot or copied from another register remembers it (its provenance)
# until either changes, so `return unless @x` narrows the slot the test read and
# `r ? r + 1 : 0` the variable behind the copy the test used, not only the
# temporary.
module NumericFlow
  INT = 1
  FLT = 2
  ARR = 4
  HSH = 8
  STR = 16
  NIL = 32
  OTHER = 64
  # The element mask of a register whose elements are unknown (ElementType: `Array[untyped]`). OR-joins absorb it, so a
  # merge with any other value stays unknown; 0 (no element) is the join identity.
  ELEM_UNKNOWN = -1
  RNG = 128
  EXC = 256
  NUM = INT | FLT
  CONTAINERS = ARR | HSH | STR
  FALSY = NIL | OTHER
  CLASS_BIT_BASE = 9
  # LCF object kinds (LcfRowFlow) live above every class bit; CodeGen#numeric_class_bit refuses to grow into them.
  OBJECT_KIND_BASE = 320
  CLASS_BITS = ((1 << OBJECT_KIND_BASE) - 1) & (-1 << CLASS_BIT_BASE)
  # Bits a fact outside one method (argument, ivar, constant) may not carry: OTHER, Range, EXC and
  # every class bit. Only return values ship them across methods. Object kinds are not among them.
  OPAQUE = OTHER | (((1 << OBJECT_KIND_BASE) - 1) & (-1 << 7))
  # Provenance, not a class: the set came from a pool whose completeness is a runtime-checked claim. A mask
  # that carries it never equals a class bit, so every unguarded decoder refuses it; only CHECKED_POOL_EXACT reads it.
  CHECKED = 1 << (OBJECT_KIND_BASE - 1)
  # The result of a blockless Enumerator maker (`map` with no block on an exact Array or Hash). It is a fixed bit, not
  # a class bit from CodeGen#numeric_class_bit: no class name is attached, so every consumer that names a class from a
  # bit refuses it and treats the value as unknown. Class bits are allocated below ENUMERATOR_BIT.
  ENUMERATOR_BIT = OBJECT_KIND_BASE - 2
  ENUMERATOR = 1 << ENUMERATOR_BIT
  # The type layer's literal classes (BytecodeIR::Types.literal_class) the flow has a bit for. Symbol, true and false
  # are closed-world class bits only the oracle names (literal_class_mask).
  LITERAL_CLASS_MASKS = { Integer: INT, Float: FLT, Array: ARR, Hash: HSH, String: STR, NilClass: NIL, Range: RNG }.freeze
  # Every bit the codegen sites name: its constant name and the core class it stands for (nil for OTHER). A site
  # takes only the classes it uses, by name, through NumericFlow.class_bits; omitting one is deliberate, so no site
  # reads the whole table.
  BIT_TABLE = {
    INT => ['INT', 'Integer'], FLT => ['FLT', 'Float'], ARR => ['ARR', 'Array'], HSH => ['HSH', 'Hash'],
    STR => ['STR', 'String'], NIL => ['NIL', 'NilClass'], OTHER => ['OTHER', nil], RNG => ['RNG', 'Range']
  }.freeze

  # { bit => class name } for the named classes, in the order given. Raises on a name the table lacks, so a typo
  # fails at load time rather than dropping a class from a site.
  def self.class_bits(*names)
    names.to_h do |klass|
      entry = BIT_TABLE.find { |_bit, (_const, name)| name == klass }
      raise ArgumentError, "NumericFlow has no bit for #{klass.inspect}" unless entry

      [entry[0], klass]
    end.freeze
  end

  # [position, constant name] for every bit, ordered by position (the bit's index), as the mask printers name them.
  def self.mask_names
    BIT_TABLE.map { |bit, (const, _name)| [bit.bit_length - 1, const].freeze }.sort.freeze
  end

  module_function

  def numeric?(mask)
    mask.is_a?(Integer) && mask.positive? && (mask & ~NUM).zero?
  end

  def containers?(mask)
    mask.is_a?(Integer) && mask.positive? && (mask & ~CONTAINERS).zero?
  end

  # Result class of Integer/Float `+ - * /` (and `%`) on two operands, monotone in
  # both masks. +nil_raises+: nil has no such operator anywhere in the program, so
  # a nil operand only ever raises and contributes no value. Integer only for
  # Integer op Integer, Float as soon as either side may be a Float; an operand
  # of any other class makes the result unknown (OTHER); 0 when no value can flow
  # out (both paths raise, or an operand is unreached).
  def arith(left, right, nil_raises)
    unknown_bits = nil_raises ? ~(NUM | NIL) : ~NUM
    result = 0
    result |= OTHER if ((left | right) & unknown_bits).nonzero?
    ln = left & NUM
    rn = right & NUM
    if ln.nonzero? && rn.nonzero?
      result |= INT if (ln & rn & INT).nonzero?
      result |= FLT if ((ln | rn) & FLT).nonzero?
    end
    result
  end

  # Ops whose only effect on registers is writing their leading register (the
  # audited BytecodeIR::WRITES_LEADING_REG_OPS list), plus the read-only
  # leaders and the two a rescue clause adds: EXCEPT writes its leading register,
  # RESCUE its second. Any other op has no facts.
  SUPPORTED_OPS = (BytecodeIR::WRITES_LEADING_REG_OPS | BytecodeIR::Ops::READS_LEAD |
                   Set['EXCEPT', 'RESCUE']).freeze
  # Leading register is only read (or the op writes an enclosing frame).
  NO_WRITE_OPS = Set['NOP', 'ENTER', 'JMP', 'JMPIF', 'JMPNOT', 'JMPNIL', 'RETURN', 'RETURN_BLK', 'RETSELF',
                     'RETNIL', 'RETTRUE', 'RETFALSE', 'BREAK', 'STOP', 'SETUPVAR', 'SETIDX', 'DEBUG',
                     'KEYEND', 'RAISEIF', 'MATCHERR'].freeze
  # How many copies of one variable a recorded class test follows.
  CLASS_TEST_CHAIN_MAX = 8
  # How many branches on one test boolean a narrowed edge is carried through.
  CLASS_TEST_THREAD_MAX = 4
  ARITH_OPS = { 'ADD' => '+', 'SUB' => '-', 'MUL' => '*' }.freeze
  IMM_ARITH_OPS = { 'ADDI' => '+', 'SUBI' => '-', 'ADDILV' => '+', 'SUBILV' => '-' }.freeze
  # In-place container builders: the register keeps its exact class.
  KEEPS_CLASS = { 'ARYPUSH' => ARR, 'ARYCAT' => ARR, 'HASHADD' => HSH, 'HASHCAT' => HSH, 'STRCAT' => STR }.freeze

  # The facts the compiler proves elsewhere, as an object answering:
  #   entry_mask(irep, reg)                class set of an incoming argument
  #   const_mask(insn)                     class set of a GETCONST/GETMCNST
  #   ivar_slots(irep)                     tracked ivar names (see above)
  #   ivar_entry_mask(irep, name)          a slot's mask on method entry
  #   ivar_fact_mask(irep, name)           what any callee may leave in a slot
  #   send_mask(irep, index, insn, state)  class set of a SEND-family result
  #   upvar_mask(irep, insn)               class set of a GETUPVAR (a captured local)
  #   pool_mask(irep, insn)                class set of a LOADL
  #   index_mask(irep, index, insn, state) class set of a GETIDX/GETIDX0 result (optional)
  #   aref_mask(irep, index, insn, state)  class set of an AREF result (optional; TUPLE_RETURN_FACTS)
  #   operator_mask(irep, index, insn, symbol, state)
  #                                        class set of an ADD/SUB/MUL the native body does not run (optional;
  #                                        OPERATOR_SENDS)
  #   op_native?(symbol)                   `+ - * /` are the core Integer/Float bodies
  #   nil_raises?(symbol)                  nil answers `symbol` only by raising
  # Each answers OTHER (or false) when it proves nothing.
  #
  # Returns index -> state (an Array of masks, nil for an unreachable
  # instruction), or nil when the irep is not modelled. Incoming state arrays are read-only and may be shared.
  # Slots follow the nregs real registers, in ivar_slots order. +writes+, when given, receives for
  # each register the union of every value any instruction stores into it (what
  # a block created earlier may see when it runs later).
  #
  # NUMERIC_FLOW_SPEED, NUMERIC_CLASSES: the flow reads the irep's bytecode facts from its
  # BytecodeIR::Program (successor lists, raise targets, rescue-only targets, the decode and operands, the instructions
  # the oracle is asked about, the literal-element proof) and derives its own Step table from them once
  # (NumericFlow.table), keeps the run's facts in a Ctx with the oracle's optional methods looked up once, and joins
  # without allocating when nothing grows. It asks the
  # oracle the same questions, with the same arguments, in the same order as before; only its own bookkeeping changed.
  def states(irep, oracle, opaque_regs, writes = nil, share_states: ENV['BC2CPP_NUMERIC_SHARE_STATES'] != '0')
    program = BytecodeIR.for(irep)
    return nil unless program.resolved?
    return nil if program.handlers? && !program.handlers_resolved?

    instructions = program.instructions
    return nil if instructions.empty?

    unless program.built_from?(irep)
      raise "NumericFlow: the decoded plan of #{irep.label} no longer matches its instructions"
    end

    table = NumericFlow.table(program)
    return nil unless table.supported

    c = Ctx.for_run(irep, oracle, opaque_regs, writes, program.rescue_only_targets)
    c.load_readers = table.load_readers if c.elide_load_copies
    c.widened_slots = Array.new(c.nslots) if ENV['BC2CPP_NUMERIC_SLOT_UNIONS'] != '0'
    steps = table.steps
    nregs = c.nregs
    entry = Array.new(nregs, OTHER)
    entry[0] = oracle.self_mask if c.self_mask
    r = 1
    while r < nregs
      m = oracle.entry_mask(irep, r)
      entry[r] = m if m && !c.opq[r]
      r += 1
    end
    c.slots.each { |name| entry << oracle.ivar_entry_mask(irep, name) }
    # Element block (one entry per register), before the provenance block so join_state OR-joins it.
    entry.fill(ELEM_UNKNOWN, entry.size, nregs)
    entry.fill(0, entry.size, nregs) # provenance: which slot (+1) each register was loaded from
    entry.fill(0, entry.size, nregs) if c.tb # class tests: which test each register's boolean holds

    n = instructions.length
    pb = c.pb
    raises = program.raise_targets
    succ = program.successor_lists
    context_edges = c.context_edges
    ins = Array.new(n)
    outs = Array.new(n)
    ins[0] = entry
    work = [0]
    queued = Array.new(n, false)
    queued[0] = true
    until work.empty?
      i = work.shift
      queued[i] = false
      st = ins[i]
      next unless st

      insn = instructions[i].source
      step = steps[i]
      out = step_transfer(i, insn, step, st, c)
      # Every instruction of a protected range may raise into its handler, where the registers
      # are as they were at the raise: the state before the op, widened by what a
      # callee can do, or after it.
      if (handlers = raises[i])
        edge = step_raise_state(step, st, out, c)
        handlers.each do |target|
          old = ins[target]
          merged = join_state(old, edge, pb, share_states)
          next if merged.equal?(old)

          ins[target] = merged
          next if queued[target]

          queued[target] = true
          work << target
        end
      end
      next if outs[i] == out

      outs[i] = out
      targets = context_edges&.key?(i) ? context_edges.fetch(i) : succ[i]
      # A call that never returns (`raise`) has no normal successor; its handler edges are above.
      targets = EMPTY if c.noreturn && oracle.noreturn_call?(irep, i, insn)
      targets.each do |s|
        edge = step_refine_edge(step, i, s, out, c)
        next unless edge

        s = step_thread_class_test(steps, step, i, s, edge, c) if c.tb
        old = ins[s]
        merged = join_state(old, edge, pb, share_states)
        next if merged.equal?(old)

        ins[s] = merged
        next if queued[s]

        queued[s] = true
        work << s
      end
    end
    ins
  end

  EMPTY = [].freeze

  # Step kinds: what #step_transfer does with an instruction, decided once per op.
  K_NO_WRITE = 0
  K_SETIDX = 1
  K_SETIV = 2
  K_CALL = 3
  K_LOADI = 4
  K_LOADL = 5
  K_LOADSELF = 6
  K_LOADNIL = 7
  K_LITERAL = 8
  K_MOVE = 9
  K_KARG = 10
  K_KEY_P = 11
  K_CONST = 12
  K_GETUPVAR = 13
  K_GETIV = 14
  K_EXCEPT = 15
  K_RESCUE = 16
  K_RANGE = 17
  K_ARRAY = 18
  K_HASH = 19
  K_STRING = 20
  K_KEEPS = 21
  K_ARITH = 22
  K_IMM = 23
  K_IMM_LV = 24
  K_DIV = 25
  K_GETIDX = 26
  K_AREF = 27
  K_EQ = 28
  K_OTHER = 29
  STEP_KINDS = {
    'SETIV' => K_SETIV, 'LOADL' => K_LOADL, 'LOADSELF' => K_LOADSELF, 'LOADNIL' => K_LOADNIL,
    'LOADTRUE' => K_LITERAL, 'LOADFALSE' => K_LITERAL, 'LOADSYM' => K_LITERAL, 'SYMBOL' => K_LITERAL, 'INTERN' => K_LITERAL, 'MOVE' => K_MOVE, 'KARG' => K_KARG,
    'KEY_P' => K_KEY_P, 'GETCONST' => K_CONST, 'GETMCNST' => K_CONST, 'GETUPVAR' => K_GETUPVAR, 'GETIV' => K_GETIV,
    'EXCEPT' => K_EXCEPT, 'RESCUE' => K_RESCUE, 'RANGE_INC' => K_RANGE, 'RANGE_EXC' => K_RANGE, 'ARRAY' => K_ARRAY,
    'ARRAY2' => K_ARRAY, 'HASH' => K_HASH, 'STRING' => K_STRING, 'ARYPUSH' => K_KEEPS, 'ARYCAT' => K_KEEPS,
    'HASHADD' => K_KEEPS, 'HASHCAT' => K_KEEPS, 'STRCAT' => K_KEEPS, 'ADD' => K_ARITH, 'SUB' => K_ARITH,
    'MUL' => K_ARITH, 'ADDI' => K_IMM, 'SUBI' => K_IMM, 'ADDILV' => K_IMM_LV, 'SUBILV' => K_IMM_LV, 'DIV' => K_DIV,
    'GETIDX' => K_GETIDX, 'GETIDX0' => K_GETIDX, 'AREF' => K_AREF, 'EQ' => K_EQ
  }.freeze
  # Call kinds: which oracle question answers the result.
  C_SEND = 1 # SEND SEND0 SSEND SSEND0
  C_BLOCK = 2 # SENDB SSENDB
  C_SUPER = 3
  C_NONE = 4 # EXEC BLKCALL
  CALL_KINDS = { 'SEND' => C_SEND, 'SEND0' => C_SEND, 'SSEND' => C_SEND, 'SSEND0' => C_SEND, 'SENDB' => C_BLOCK,
                 'SSENDB' => C_BLOCK, 'SUPER' => C_SUPER, 'EXEC' => C_NONE, 'BLKCALL' => C_NONE }.freeze
  # Silent kinds (see #step_silent_call?): how the op decides whether it dispatches to Ruby.
  S_NONE = 0
  S_NUMERIC = 1 # ADD SUB MUL DIV EQ LT LE GT GE
  S_INDEX = 2 # GETIDX SETIDX
  S_INDEX0 = 3
  S_STRCAT = 4
  S_ALWAYS = 5
  S_CONST = 6 # GETCONST GETMCNST
  SILENT_KINDS = { 'ADD' => S_NUMERIC, 'SUB' => S_NUMERIC, 'MUL' => S_NUMERIC, 'DIV' => S_NUMERIC, 'EQ' => S_NUMERIC,
                   'LT' => S_NUMERIC, 'LE' => S_NUMERIC, 'GT' => S_NUMERIC, 'GE' => S_NUMERIC, 'GETIDX' => S_INDEX,
                   'SETIDX' => S_INDEX, 'GETIDX0' => S_INDEX0, 'STRCAT' => S_STRCAT, 'GETCONST' => S_CONST,
                   'GETMCNST' => S_CONST }.freeze
  # Branch kinds of a conditional jump: BytecodeIR's (Decoded#cond).
  B_IF = BytecodeIR::COND_IF
  B_NOT = BytecodeIR::COND_NOT
  B_NIL = BytecodeIR::COND_NIL
  BRANCH_KINDS = BytecodeIR::COND_KINDS

  # One instruction as the flow reads it. +op+, +branch+ and +goto+ are copied from the BytecodeIR decode
  # (BytecodeIR::Decoded: op, cond, goto) so the worklist reads one struct; the rest is the flow's own reading.
  # +a+ is the leading register where the op's rule reads it (nil otherwise), +b+ the second register the op reads
  # (MOVE's source, the parenthesised operand, SETIV's value).
  Step = Struct.new(:op, :kind, :call, :silent, :branch, :a, :b, :ivar, :goto, :sym, :result_write)

  # The flow's per-Program table: whether every op is modelled, and the Step of each instruction (nil when not).
  Table = Struct.new(:supported, :steps, :load_readers)

  # NumericFlow's Step table for +program+, derived once from the program's facts and kept in the program's one
  # analysis slot (BytecodeIR::Program#numeric_flow_table). It holds bytecode facts only, never an oracle answer.
  def table(program)
    program.numeric_flow_table ||= begin
      instructions = program.instructions
      supported = instructions.all? { |i| SUPPORTED_OPS.include?(i.op) || BytecodeIR::Ops::LOADI_OPS.include?(i.op) }
      decoded = program.decoded if supported
      operands = program.operands if supported
      steps = (instructions.map { |i| NumericFlow.decode_step(i.source, decoded[i.index], operands[i.index]).freeze }.freeze if supported)
      readers = {}
      steps&.each do |step|
        next unless step.kind == K_MOVE && step.a != step.b

        (readers[step.b] ||= []) << step.a
      end
      readers.transform_values! { |registers| registers.uniq.freeze }
      Table.new(supported, steps, readers.freeze).freeze
    end
  end

  # The flow's Step of an instruction from its IR facts: the BytecodeIR decode +decoded+ and the Operands +operands+
  # (Program#decoded, Program#operands). A check may pass a bare instruction; it is decoded the same way. Without a
  # Program's decode, +goto+ stays nil.
  def decode_step(insn, decoded = BytecodeIR.decode(insn), operands = BytecodeIR.operands(insn))
    decode_ir_step(decoded, operands)
  end

  def decode_ir_step(decoded, operands)
    op = decoded.op
    silent = SILENT_KINDS.fetch(op) { SILENT_CALL_OPS.include?(op) ? S_ALWAYS : S_NONE }
    step = Step.new(op, nil, nil, silent, decoded.cond)
    if NO_WRITE_OPS.include?(op)
      step.kind = op == 'SETIDX' ? K_SETIDX : K_NO_WRITE
      step.a = decoded.reg.to_i if op == 'SETIDX' || op == 'RAISEIF' || step.branch
      step.goto = decoded.goto if step.branch
      return step
    end
    if op == 'SETIV'
      step.kind = K_SETIV
      step.ivar = operands.ivar
      step.b = operands.b
      return step
    end

    step.a = decoded.reg
    step.call = CALL_KINDS[op]
    step.kind = if step.call then K_CALL
                elsif BytecodeIR::Ops::LOADI_OPS.include?(op) then K_LOADI
                else STEP_KINDS.fetch(op, K_OTHER)
                end
    step.ivar = operands.ivar if step.kind == K_GETIV
    step.b = operands.b
    step.sym = ARITH_OPS[op] || IMM_ARITH_OPS[op]
    step.result_write = RESULT_WRITE_KINDS.include?(step.kind)
    step
  end

  # The facts of one run: the oracle, the register file's layout and the class tests recorded so far. The oracle's
  # optional methods are looked up once (respond_to? is all they cost).
  class Ctx
    attr_reader :irep, :oracle, :opaque, :opq, :nregs, :slots, :nslots, :slot_of, :facts, :pb, :tb, :writes,
                :tests, :test_ids, :const_quiet, :rescue_only, :context_edges, :self_mask, :block_send, :super_mask,
                :preserves, :loadself, :keyword_mask, :keyword_presence, :array_mask, :hash_mask, :index_mask,
                :aref_mask, :operator_mask, :literal_class, :false_class, :class_eq_test, :note_class_test, :noreturn,
                :elide_load_copies

    # The run of NumericFlow.states, asking the oracle what the old setup asked, in the same order.
    def self.for_run(irep, oracle, opaque, writes, rescue_only)
      nregs = [irep.nregs.to_i, 1].max
      slots = oracle.ivar_slots(irep)
      slot_of = slots.each_with_index.to_h { |name, k| [name, nregs + k] }
      facts = slots.map { |name| oracle.ivar_fact_mask(irep, name) }
      # Provenance follows the ivar slots and the element block (one entry per register, ELEM_UNKNOWN in states).
      c = new(irep, oracle, opaque, nregs, slots, slot_of, facts, nregs + slots.size + nregs, writes)
      c.elide_load_copies = ENV['BC2CPP_NUMERIC_LOAD_COPY_ELISION'] != '0'
      c.elide_result_copies = ENV['BC2CPP_NUMERIC_RESULT_COPY_ELISION'] != '0'
      c.elem_base = nregs + slots.size
      # CLASS_NARROWING: a third block of nregs entries after the provenance, one per register, naming the
      # class test whose boolean result the register holds. Off (nil) unless the oracle can recognise a test.
      if oracle.respond_to?(:class_narrowing_active?) && oracle.class_narrowing_active?
        # A constant lookup runs Ruby only through const_missing; without one, `is_a?(Foo)` does not forget the ivars.
        c.narrowing(c.pb + nregs, [], {}, oracle.respond_to?(:const_lookup_quiet?) && oracle.const_lookup_quiet?)
      end
      c.rescue_only = rescue_only
      c
    end

    # A ctx Hash as the flow's callers built it before (a check drives #transfer and #raise_state with one).
    def self.from_hash(h)
      c = new(h[:irep], h[:oracle], h[:opaque], h[:nregs], h[:slots], h[:slot_of], h[:facts], h[:prov_base], h[:writes])
      c.narrowing(h[:test_base], h[:tests], h[:test_ids], h[:const_quiet]) if h[:test_base]
      c.rescue_only = h[:rescue_only] || Set.new
      c
    end

    attr_writer :rescue_only
    attr_reader :block_element

    # The element block starts right after the ivar slots (one entry per register; see states).
    # Where the element block starts; nil for a ctx built from a Hash, whose layout has no element block.
    attr_accessor :elem_base
    attr_accessor :load_readers, :widened_slots
    attr_accessor :elide_result_copies
    attr_writer :elide_load_copies

    def initialize(irep, oracle, opaque, nregs, slots, slot_of, facts, prov_base, writes)
      @elide_load_copies = false
      @elide_result_copies = false
      @irep = irep
      @oracle = oracle
      @opaque = opaque
      @opq = (opaque.empty? ? Array.new(nregs, false) : Array.new(nregs) { |r| opaque.include?(r.to_s) }).freeze
      @nregs = nregs
      @slots = slots
      @nslots = slots.size
      @slot_of = slot_of
      @facts = facts
      @pb = prov_base
      @block_element = oracle.respond_to?(:block_element_mask)
      @writes = writes
      @tb = nil
      @tests = nil
      @const_quiet = nil
      @context_edges = oracle.respond_to?(:context_enter_edges) ? oracle.context_enter_edges : nil
      @self_mask = oracle.respond_to?(:self_mask)
      @block_send = oracle.respond_to?(:block_send_mask)
      @super_mask = oracle.respond_to?(:super_mask)
      @preserves = oracle.respond_to?(:preserves_ivar_slots?)
      @loadself = oracle.respond_to?(:loadself_mask)
      @keyword_mask = oracle.respond_to?(:keyword_mask)
      @keyword_presence = oracle.respond_to?(:keyword_presence)
      @array_mask = oracle.respond_to?(:array_mask)
      @hash_mask = oracle.respond_to?(:hash_mask)
      @index_mask = oracle.respond_to?(:index_mask)
      @aref_mask = oracle.respond_to?(:aref_mask)
      @operator_mask = oracle.respond_to?(:operator_mask)
      @literal_class = oracle.respond_to?(:literal_class_mask)
      @false_class = oracle.respond_to?(:false_class_bit)
      @class_eq_test = oracle.respond_to?(:class_eq_test)
      @note_class_test = oracle.respond_to?(:note_class_test)
      @noreturn = oracle.respond_to?(:noreturn_call?)
    end

    def narrowing(test_base, tests, test_ids, const_quiet)
      @tb = test_base
      @tests = tests
      @test_ids = test_ids
      @const_quiet = const_quiet
      @test_slot = []
      @test_reach = []
    end

    # The id of test +key+ ([codes, predicate]), registered on first sight.
    def test_id(key)
      @test_ids[key] ||= (@tests << key).size
    end

    # True when test +id+ is aimed at an ivar slot (provenance code 1..nslots).
    def test_aims_slot?(id)
      fill_test_facts(id) if @test_slot.size < id
      @test_slot[id - 1]
    end

    # The highest register test +id+ is aimed at, or -1 for none.
    def test_reach(id)
      fill_test_facts(id) if @test_reach.size < id
      @test_reach[id - 1]
    end

    def fill_test_facts(id)
      slots = @nslots
      (@test_slot.size...id).each do |k|
        codes = @tests.fetch(k)[0]
        @test_slot << codes.any? { |code| code <= slots }
        @test_reach << codes.reduce(-1) { |reach, code| code > slots && code - slots - 1 > reach ? code - slots - 1 : reach }
      end
    end
  end

  # The state a handler starts from when +insn+ raises. A callee frame starts at R(a) and may
  # reuse every register from there up; any Ruby the op runs may have stored into an ivar.
  def raise_state(insn, before, after, ctx)
    step_raise_state(decode_step(insn), before, after, ctx.is_a?(Ctx) ? ctx : Ctx.from_hash(ctx))
  end

  def step_raise_state(step, before, after, c)
    state = before
    if step.kind == K_CALL
      state = before.dup
      state.fill(OTHER, step.a.to_i, c.nregs - step.a.to_i) if step.a.to_i < c.nregs
      refresh_slots(state, c)
    elsif step_silent_call?(step, before, c)
      state = before.dup
      refresh_slots(state, c)
    end
    join_state(state, after, c.pb)
  end

  # The state flowing along edge insn -> target: a conditional branch narrows the
  # tested register (and whatever it was loaded or copied from) by truthiness; nil
  # and false are the only falsy values. nil when the edge is infeasible.
  def step_refine_edge(step, index, target, state, c)
    return refine_raiseif(step.a, state) if step.op == :RAISEIF

    branch = step.branch
    return state unless branch

    goto = step.goto
    fall = index + 1
    return state if goto == fall || (target != goto && target != fall)

    taken = target == goto
    edge = narrow_chain(state, step.a, branch, taken, c, [])
    return edge unless edge && c.tb && branch != B_NIL

    narrow_by_class_test(edge, step.a, (branch == B_IF) == taken, c)
  end

  # The edge out of `JMPIF R` / `JMPNOT R` into another branch on the same register R, which holds a class test's
  # boolean, already decides that branch (`a || b` and `a && b` in a condition compile to two of them): continue at
  # its successor, so the narrowing the edge carries is not joined away with the path that tests again.
  def step_thread_class_test(steps, src, index, target, edge, c)
    return target unless src.branch == B_IF || src.branch == B_NOT

    reg = src.a
    id = edge[c.tb + reg].to_i
    return target if id.zero? || !c.tests.fetch(id - 1)[1].respond_to?(:narrow)

    goto = src.goto
    return target if goto == index + 1 || (target != goto && target != index + 1)

    truth = (src.branch == B_IF) == (target == goto)
    CLASS_TEST_THREAD_MAX.times do
      branch = steps[target]
      break unless branch && (branch.branch == B_IF || branch.branch == B_NOT) && branch.a == reg

      jump = branch.goto
      break if jump == target + 1

      target = (branch.branch == B_IF) == truth ? jump : target + 1
    end
    target
  end

  # CLASS_NARROWING: the register tested by the branch holds the boolean of a class test, so on the edge
  # where it is +truth+ the tested value and every variable it was copied from (the chain, recorded when the test
  # ran) is narrowed by the test's predicate. nil when no value can take the edge.
  def narrow_by_class_test(state, reg, truth, c)
    id = state[c.tb + reg].to_i
    return state if id.zero?

    codes, pred = c.tests.fetch(id - 1)
    return state unless pred.respond_to?(:narrow)

    slots = c.nslots
    out = state
    codes.each do |code|
      at = code <= slots ? c.nregs + code - 1 : code - slots - 1
      mask = state[at]
      next if mask.nil? || mask.zero?

      narrowed = pred.narrow(mask, truth)
      return nil if narrowed.zero?
      next if narrowed == mask

      out = out.dup if out.equal?(state)
      out[at] = narrowed
    end
    out
  end

  # Remember that +a+ holds the boolean of the class test +test+ ([subject offset, predicate]) of the SEND whose
  # leading register is +a+, aimed at every variable the subject register was a copy of when the call started. A call
  # clears the provenance, so the chain (`case x`: the argument copies the case temporary, which copies x) is read here.
  def record_class_test(out, state, a, test, c)
    subject = a + test[0]
    return if subject >= c.nregs

    slots = c.nslots
    pb = c.pb
    codes = []
    code = state[pb + subject].to_i
    while code.positive? && codes.size < CLASS_TEST_CHAIN_MAX
      if code > slots
        reg = code - slots - 1
        # At or above the callee frame, or captured: no longer (or never) the tested variable.
        break if reg >= a || c.opq[reg] || codes.include?(code)

        codes << code
        code = state[pb + reg].to_i
      else
        codes << code
        break
      end
    end
    return if codes.empty?

    out[c.tb + a] = c.test_id([codes.freeze, test[1]])
  end

  def record_class_eq(out, insn, step, index, id, c)
    codes, marker = c.tests.fetch(id - 1)
    a = step.a
    b = step.b
    oracle = c.oracle
    return if b >= c.nregs || codes.include?(c.nslots + 1 + a) || !c.class_eq_test
    # The guard of an EQ reads the subject from a register: an ivar-only chain is not narrowed.
    return if codes.none? { |code| code > c.nslots }

    pred = oracle.class_eq_test(c.irep, index, insn, marker)
    return unless pred

    out[c.tb + a] = c.test_id([codes, pred])
    oracle.note_class_test(c.irep, index, codes, c.nslots, pred) if c.note_class_test
  end

  # Forget every test aimed at provenance +code+ (the variable it narrows was rewritten).
  def clear_class_tests(out, c, code)
    tests = c.tests
    return if tests.empty?

    tb = c.tb
    q = tb
    last = tb + c.nregs
    while q < last
      id = out[q]
      out[q] = 0 if id.positive? && tests.fetch(id - 1)[0].include?(code)
      q += 1
    end
  end

  # `RAISEIF Ra` raises unless Ra is nil, so the fall-through edge holds only a nil (or unknown) Ra.
  def refine_raiseif(reg, state)
    mask = state[reg]
    return state if mask.nil? || mask.zero?

    narrowed = mask & FALSY
    return nil if narrowed.zero?

    return state if narrowed == mask

    out = state.dup
    out[reg] = narrowed
    out
  end

  # Provenance values: 0 none, 1..K slot k-1, K+1+r register r. +seen+ holds the registers already narrowed.
  def narrow_chain(state, reg, branch, taken, c, seen)
    return state if seen.include?(reg)

    seen << reg
    mask = state[reg]
    return state if mask.nil? || mask.zero?

    if c.false_class
      sure = maybe = c.oracle.false_class_bit.to_i
    else
      sure = 0
      maybe = CLASS_BITS
    end
    narrowed = narrow_branch(branch, taken, mask, sure, maybe)
    return nil if narrowed.zero?

    out = state
    if narrowed != mask
      out = state.dup
      out[reg] = narrowed
    end
    prov = state[c.pb + reg].to_i
    slots = c.nslots
    if prov.positive? && prov <= slots
      slot = c.nregs + prov - 1
      slot_narrowed = narrow_branch(branch, taken, state[slot], sure, maybe)
      return nil if slot_narrowed.zero? && !state[slot].zero?

      if slot_narrowed != state[slot]
        out = out.dup if out.equal?(state)
        out[slot] = slot_narrowed
      end
    elsif prov > slots
      out = narrow_chain(out, prov - slots - 1, branch, taken, c, seen)
    end
    out
  end

  # [definitely falsy, possibly falsy] class bits. FalseClass is the only class bit that is falsy, and it is falsy for
  # sure. An oracle that does not name it leaves every class bit possibly falsy and none definitely falsy.
  def falsy_class_bits(c)
    return [0, CLASS_BITS] unless c.false_class

    bit = c.oracle.false_class_bit.to_i
    [bit, bit]
  end

  # The class bit of a true, false or Symbol literal, or OTHER when the oracle names none.
  def literal_class_mask(insn, c)
    (c.literal_class && c.oracle.literal_class_mask(insn)) || OTHER
  end

  # A truthy edge drops nil and the definitely falsy class bits; a falsy edge keeps nil, OTHER and the possibly falsy
  # class bits. JMPNIL needs no class bits: only nil is nil.
  def narrow_by_truth(op, taken, mask, sure, maybe)
    narrow_branch(BRANCH_KINDS[op] || B_NIL, taken, mask, sure, maybe)
  end

  def narrow_branch(branch, taken, mask, sure, maybe)
    if branch == B_IF
      taken ? mask & ~(NIL | sure) : mask & (FALSY | maybe)
    elsif branch == B_NOT
      taken ? mask & (FALSY | maybe) : mask & ~(NIL | sure)
    else
      taken ? (mask & FALSY).zero? ? 0 : NIL : mask & ~NIL # JMPNIL: nil exactly on the taken edge
    end
  end

  # Masks join by union; a provenance survives only when both sides agree. +old+ itself when nothing changes, so a
  # caller tells growth by identity; nothing is allocated until the first entry that changes.
  # Flow-owned incoming states are read-only: transfers and edge refinements copy before mutation.
  # Standalone callers retain the copy on the first edge unless they explicitly share that invariant.
  def join_state(old, new, prov_base, share_states = false)
    return share_states ? new : new.dup if old.nil?
    # Equal states join to the old one (a union of equal masks, provenances that agree); Array#== finds that in C. A
    # nil entry is the exception: `nil | nil` is false, which the loop below reproduces.
    return old if old == new && !old.include?(nil)

    joined = nil
    size = old.size
    r = 0
    while r < size
      m = old[r]
      x = new[r]
      unless m.eql?(x) && m.is_a?(Integer)
        j = r < prov_base ? m | x : (m == x ? m : 0)
        unless j == m
          joined ||= old.dup
          joined[r] = j
        end
      end
      r += 1
    end
    joined || old
  end

  def transfer(index, insn, state, ctx)
    step_transfer(index, insn, decode_step(insn), state, ctx.is_a?(Ctx) ? ctx : Ctx.from_hash(ctx))
  end

  def step_transfer(index, insn, step, state, c)
    kind = step.kind
    if kind == K_NO_WRITE
      return state
    elsif kind == K_SETIDX
      # SETIDX writes no register but may call a user #[]=.
      return state unless step_silent_call?(step, state, c)

      out = state.dup
      refresh_slots(out, c)
      return out
    end

    nregs = c.nregs
    pb = c.pb
    if kind == K_SETIV
      slot = c.slot_of[step.ivar]
      return state unless slot

      out = state.dup
      out[slot] = state[step.b]
      # Registers loaded from the old value no longer mirror the slot.
      clear_provenance(out, pb, nregs, slot - nregs + 1)
      clear_class_tests(out, c, slot - nregs + 1) if c.tb
      return out
    end

    a = step.a
    return state if a.nil? || a >= nregs

    if c.elide_load_copies
      case kind
      when K_LOADI then return copy_reg_write(state, a, INT, c)
      when K_LOADNIL then return copy_reg_write(state, a, NIL, c)
      when K_STRING then return copy_reg_write(state, a, STR, c)
      when K_LOADSELF then return copy_reg_write(state, a, c.loadself ? c.oracle.loadself_mask : OTHER, c)
      when K_LOADL then return copy_reg_write(state, a, c.oracle.pool_mask(c.irep, insn), c)
      when K_LITERAL then return copy_reg_write(state, a, literal_class_mask(insn, c), c)
      end
    end

    if step.result_write
      mask = result_mask(index, insn, step, state, c)
      if c.elide_result_copies
        out = copy_reg_write(state, a, mask, c)
      else
        out = state.dup
        set_reg(out, a, mask, c)
      end
      if step_silent_call?(step, state, c)
        out = out.dup if out.equal?(state)
        refresh_slots(out, c)
      end
      return out
    end

    out = state.dup
    oracle = c.oracle
    irep = c.irep
    if kind == K_CALL
      # A block result needs its own proof: `break` replaces the callee's answer.
      call = step.call
      mask = if call == C_SEND
               oracle.send_mask(irep, index, insn, state)
             elsif call == C_BLOCK && c.block_send
               oracle.block_send_mask(irep, index, insn, state)
             elsif call == C_SUPER && c.super_mask
               oracle.super_mask(irep, index, insn, state)
             else OTHER
             end
      test = c.tb && (step.op == :SEND || step.op == :SEND0) ? oracle.class_test(irep, index, insn, state) : nil
      out.fill(OTHER, a + 1, nregs - a - 1) if a + 1 < nregs
      out.fill(ELEM_UNKNOWN, c.elem_base + a + 1, nregs - a - 1) if c.elem_base && a + 1 < nregs
      preserve = c.preserves && oracle.preserves_ivar_slots?(irep, index, insn, state)
      if preserve
        out.fill(0, pb, nregs) unless c.tb
      else
        refresh_slots(out, c)
      end
      clobber_class_test_copies(out, c, a) if c.tb
      set_reg(out, a, mask, c)
      # ELEMENT (step 2): a block send's elements, when the oracle proves them (block_element_mask); else unknown.
      out[c.elem_base + a] = oracle.block_element_mask(irep, index, insn, state) || ELEM_UNKNOWN if c.block_element && c.elem_base && call == C_BLOCK
      record_class_test(out, state, a, test, c) if test
      return out
    end

    case kind
    when K_LOADI
      set_reg(out, a, INT, c)
    when K_LOADL
      set_reg(out, a, oracle.pool_mask(irep, insn), c)
    when K_LOADSELF
      set_reg(out, a, c.loadself ? oracle.loadself_mask : OTHER, c)
    when K_LOADNIL
      set_reg(out, a, NIL, c)
    when K_LITERAL
      set_reg(out, a, literal_class_mask(insn, c), c)
    when K_MOVE
      src = step.b
      set_reg(out, a, src < nregs ? state[src] : OTHER, c)
      # `a` now mirrors `src` (and whatever `src` mirrored is reached through it).
      if src < nregs && src != a && !c.opq[a] && !c.opq[src]
        out[pb + a] = c.nslots + 1 + src
        copy_class_test(out, state, a, src, c) if c.tb
      end
    when K_GETIV
      slot = c.slot_of[step.ivar]
      set_reg(out, a, slot ? state[slot] : OTHER, c)
      out[pb + a] = slot - nregs + 1 if slot && !c.opq[a]
    when K_RESCUE
      # Reads the exception in its first register, writes the match flag to its second.
      b = step.b
      set_reg(out, b, OTHER, c) if b < nregs
    when K_STRING
      set_reg(out, a, STR, c)
    when K_IMM_LV
      sym = step.sym
      # R[b], R[b+1] are working space for the fallback method call.
      b = step.b
      set_reg(out, b, OTHER, c) if b < nregs
      set_reg(out, b + 1, OTHER, c) if b + 1 < nregs
      set_reg(out, a, oracle.op_native?(sym) ? arith(state[a], INT, oracle.nil_raises?(sym)) : OTHER, c)
    when K_EQ
      # `x.class == C`: the class-of boolean meets a class constant, which makes it the instance_of test of x.
      id = c.tb ? state[c.tb + a].to_i : 0
      set_reg(out, a, OTHER, c)
      record_class_eq(out, insn, step, index, id, c) if id.positive?
    else
      set_reg(out, a, OTHER, c)
    end
    refresh_slots(out, c) if step_silent_call?(step, state, c)
    out
  end

  RESULT_WRITE_KINDS = Set[K_KARG, K_KEY_P, K_CONST, K_GETUPVAR, K_EXCEPT, K_RANGE, K_ARRAY, K_HASH,
                           K_KEEPS, K_ARITH, K_IMM, K_DIV, K_GETIDX, K_AREF, K_OTHER].freeze

  def result_mask(index, insn, step, state, c)
    a = step.a
    nregs = c.nregs
    oracle = c.oracle
    irep = c.irep
    case step.kind
    when K_KARG
      c.keyword_mask ? oracle.keyword_mask(insn) : OTHER
    when K_KEY_P
      c.keyword_presence ? oracle.keyword_presence(insn) : OTHER
    when K_CONST
      oracle.const_mask(insn)
    when K_GETUPVAR
      oracle.upvar_mask(irep, insn)
    when K_EXCEPT
      c.rescue_only.include?(index) ? EXC : EXC | NIL
    when K_RANGE
      RNG
    when K_ARRAY
      c.array_mask ? oracle.array_mask(irep, index, insn, state) : ARR
    when K_HASH
      c.hash_mask ? oracle.hash_mask(irep, index, insn, state) : HSH
    when K_KEEPS
      keep = KEEPS_CLASS.fetch(step.op)
      state[a] == keep ? keep : OTHER
    when K_ARITH
      b = step.b
      sym = step.sym
      recv = state[a]
      # A receiver that can be no number runs no native arithmetic (OPERATOR_SENDS); one not reached yet (0) is
      # answered there too, so a pool still growing is not dropped by the numeric join.
      if c.operator_mask && recv.is_a?(Integer) && !recv.negative? && (recv & NUM).zero?
        oracle.operator_mask(irep, index, insn, sym, state)
      elsif oracle.op_native?(sym) && b < nregs
        arith(recv, state[b], oracle.nil_raises?(sym))
      else
        c.operator_mask ? oracle.operator_mask(irep, index, insn, sym, state) : OTHER
      end
    when K_IMM
      sym = step.sym
      oracle.op_native?(sym) ? arith(state[a], INT, oracle.nil_raises?(sym)) : OTHER
    when K_DIV
      b = step.b
      ok = oracle.op_native?('/') && b < nregs
      ok ? arith(state[a], state[b], oracle.nil_raises?('/')) : OTHER
    when K_GETIDX
      literal = BytecodeIR::NumericClasses.element_literal_mask(irep, index, c.opaque)
      literal || (c.index_mask ? oracle.index_mask(irep, index, insn, state) : OTHER)
    when K_AREF
      c.aref_mask ? oracle.aref_mask(irep, index, insn, state) : OTHER
    when K_OTHER
      OTHER
    end
  end

  # Equal class masks alone are insufficient: rewriting a value still invalidates aliases and tests.
  def copy_reg_write(state, r, mask, c)
    value = c.opq[r] ? OTHER : mask
    if unchanged_reg_write?(state, r, value, c)
      writes = c.writes
      writes[r] = (writes[r] || 0) | value if writes
      return state
    end

    out = state.dup
    set_reg(out, r, mask, c)
    out
  end

  def unchanged_reg_write?(state, r, value, c)
    return false unless state[r].eql?(value) && state[c.pb + r].eql?(0)
    return false if c.elem_base && !state[c.elem_base + r].eql?(ELEM_UNKNOWN)
    return false if c.tb && !state[c.tb + r].eql?(0)

    code = c.nslots + 1 + r
    if c.load_readers
      # Only MOVE installs a register provenance code in flow-created states.
      c.load_readers.fetch(r, EMPTY).each do |reader|
        return false if reader < c.nregs && state[c.pb + reader] == code
      end
    else
      q = c.pb
      last = q + c.nregs
      while q < last
        return false if state[q] == code

        q += 1
      end
    end
    if c.tb && !c.tests.empty?
      q = c.tb
      last = q + c.nregs
      while q < last
        id = state[q]
        return false if id.positive? && c.tests.fetch(id - 1)[0].include?(code)

        q += 1
      end
    end
    true
  end

  # Register +r+ (below nregs) now holds +mask+ (OTHER when a block captures it): nothing mirrors its old value any more.
  def set_reg(out, r, mask, c)
    value = c.opq[r] ? OTHER : mask
    out[r] = value
    writes = c.writes
    writes[r] = (writes[r] || 0) | value if writes
    pb = c.pb
    out[pb + r] = 0
    # A new value has no known elements until a rule proves them (ELEMENT, see ELEM_UNKNOWN).
    out[c.elem_base + r] = ELEM_UNKNOWN if c.elem_base
    # Registers that mirrored the old value of r no longer do.
    code = c.nslots + 1 + r
    clear_provenance(out, pb, c.nregs, code)
    return unless c.tb

    out[c.tb + r] = 0
    clear_class_tests(out, c, code)
  end

  # Every register whose provenance is +code+ loses it.
  def clear_provenance(out, pb, nregs, code)
    q = pb
    last = pb + nregs
    while q < last
      out[q] = 0 if out[q] == code
      q += 1
    end
  end

  # Non-call ops that dispatch to Ruby the flow does not follow, with the same `self`
  # an operator on a non-number, an index on anything but an exact
  # Array with an Integer index, interpolation, hash/array splat, range or constant lookup.
  SILENT_CALL_OPS = Set['ADD', 'SUB', 'MUL', 'DIV', 'EQ', 'LT', 'LE', 'GT', 'GE', 'GETIDX', 'GETIDX0', 'SETIDX',
                        'STRCAT', 'HASH', 'HASHADD', 'HASHCAT', 'ARYCAT', 'ARYSPLAT', 'AREF', 'RANGE_INC',
                        'RANGE_EXC', 'GETCONST', 'GETMCNST'].freeze

  def step_silent_call?(step, state, c)
    silent = step.silent
    return false if silent == S_NONE
    return false if c.nslots.zero?
    return false if silent == S_CONST && c.const_quiet

    a = step.a.to_i
    nregs = c.nregs
    case silent
    when S_NUMERIC
      b = step.b
      !(plain_number?(a < nregs ? state[a] : nil) && plain_number?(b < nregs ? state[b] : nil))
    when S_INDEX
      !((a < nregs ? state[a] : nil) == ARR && (a + 1 < nregs ? state[a + 1] : nil) == INT)
    when S_INDEX0
      b = step.b
      (b < nregs ? state[b] : nil) != ARR
    when S_STRCAT
      (a + 1 < nregs ? state[a + 1] : nil) != STR
    else true
    end
  end

  def plain_number?(mask)
    mask.is_a?(Integer) && mask.positive? && (mask & ~NUM).zero?
  end

  # Every slot may now hold what any callee could have stored, and no register still
  # mirrors a slot.
  def refresh_slots(out, c)
    nregs = c.nregs
    k = 0
    facts = c.facts
    widened = c.widened_slots
    while k < facts.size
      value = out[nregs + k]
      # Slot facts are fixed for a run; its last widened mask is already a fixed point of this union.
      unless widened && value.is_a?(Integer) && (value.eql?(facts[k]) || value.eql?(widened[k]))
        value |= facts[k]
        out[nregs + k] = value
        widened[k] = value if widened
      end
      k += 1
    end
    pb = c.pb
    tb = c.tb
    unless tb
      out.fill(0, pb, nregs)
      return
    end

    # CLASS_NARROWING: a call cannot write a local no block captures, so two registers that held the same value
    # still do; only the copies of a slot are forgotten (and, in the call, the callee's frame).
    slots = c.nslots
    q = 0
    while q < nregs
      out[pb + q] = 0 if out[pb + q] <= slots
      q += 1
    end
    return if slots.zero? || c.tests.empty?

    # Every test aimed at a slot is forgotten.
    q = 0
    while q < nregs
      id = out[tb + q]
      out[tb + q] = 0 if id.positive? && c.test_aims_slot?(id)
      q += 1
    end
  end

  # The callee frame starts at R(a): whatever mirrored a register from there up, or was tested through one, is gone.
  def clobber_class_test_copies(out, c, a)
    slots = c.nslots
    pb = c.pb
    tb = c.tb
    q = 0
    nregs = c.nregs
    while q < nregs
      code = out[pb + q]
      out[pb + q] = 0 if q >= a || (code > slots && code - slots - 1 >= a)
      id = out[tb + q]
      out[tb + q] = 0 if id.positive? && (q > a || c.test_reach(id) >= a)
      q += 1
    end
  end

  # `v = x.is_a?(C)`: the copy holds the same boolean, unless the test was aimed at the register being overwritten.
  def copy_class_test(out, state, dst, src, c)
    id = state[c.tb + src].to_i
    return if id.zero? || c.tests.fetch(id - 1)[0].include?(c.nslots + 1 + dst)

    out[c.tb + dst] = id
  end
end
