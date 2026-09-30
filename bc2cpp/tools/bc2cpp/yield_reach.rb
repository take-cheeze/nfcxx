# frozen_string_literal: true

require 'set'
require_relative 'bytecode_ir'

# YIELD_REACH (ADR 0283): a whole-program, by-name "may this code suspend the current Fiber?"
# analysis over the ireps of a closed world. A compiled frame that sits between a Fiber's entry
# and a Fiber.yield breaks mruby's fiber switch (ADR 0269), so a frame whose execution provably
# cannot reach a yield above it is safe under any Fiber. Every question defaults to "may yield".
#
# Per node (method, block or class-body irep) it computes
#   nb(n)  a yield can happen above n's frame, not counting the blocks n's method *received*: those
#          are accounted where they were passed (a literal block is an edge of the passing node, a
#          forwarded one marks the forwarder);
#   own(n) nb(n), or n runs the block its method received and a block passed to that method may
#          yield.
# A call edge uses nb(callee), a literal-block edge nb(block), and only own() answers "can the frame
# of n itself be crossed". Names are resolved the way the compiler resolves POLY sites: by name over
# every definition, whatever the receiver.
class YieldReach
  # Sends whose first argument is the name to call.
  DYNAMIC_SENDS = %w[send __send__ public_send].freeze
  # Run a block or a string as arbitrary code. With a literal block the block is the edge; without
  # one the code is unknown.
  CODE_EVAL = %w[eval instance_eval class_eval module_eval].freeze
  BLOCK_EXEC = %w[instance_exec class_exec module_exec].freeze
  # Calls that run a Proc value.
  PROC_CALLS = %w[call () yield [] ===].freeze
  # Calls that leave the receiver's other uses harmless (they neither run nor keep a Proc).
  PROC_HARMLESS = %w[arity lambda? nil? == != ! block_given? is_a? kind_of? class frozen? object_id equal?
                     respond_to? parameters].freeze
  # A literal block given to these outlives the call: native code keeps it and runs it later from an
  # unrelated site (Hash default procs, Enumerator generators, define_method bodies).
  STORING_CALLS = %w[new define_method define_singleton_method at_exit proc lambda].freeze
  # Native reads that run a stored block.
  STORED_READS = %w[[] fetch dig default values_at fetch_values].freeze
  # Core methods whose computed send names a method some Symbol was converted for.
  CALLABLE_SEND_METHODS = %w[to_proc inject reduce].freeze
  # Symbol#to_proc and Method objects turn a method into a Proc value.
  CALLABLE_MAKERS = %w[to_proc method instance_method public_method singleton_method].freeze
  # Blocks handed to these constants' `new` receive an Enumerator::Yielder as their first argument.
  GENERATOR_CLASSES = %w[Enumerator Lazy Generator].freeze
  # What Enumerator::Yielder answers.
  YIELDER_MESSAGES = %w[<< yield call].freeze
  # Names bytecode operators dispatch to.
  OP_NAMES = {
    'ADD' => '+', 'ADDI' => '+', 'ADDILV' => '+', 'SUB' => '-', 'SUBI' => '-', 'SUBILV' => '-', 'MUL' => '*',
    'DIV' => '/', 'EQ' => '==', 'LT' => '<', 'LE' => '<=', 'GT' => '>', 'GE' => '>=', 'AREF' => '[]',
    'ASET' => '[]=', 'GETIDX' => '[]', 'GETIDX0' => '[]', 'SETIDX' => '[]=', 'STRCAT' => 'to_s', 'ARYCAT' => 'to_a', 'ARYSPLAT' => 'to_a', 'APOST' => 'to_a',
    'HASHCAT' => 'to_hash', 'RANGE_INC' => '<=>', 'RANGE_EXC' => '<=>', 'GETCONST' => 'const_missing',
    'GETMCNST' => 'const_missing', 'CLASS' => 'inherited', 'TDEF' => 'singleton_method_added',
    'DEF' => 'method_added', 'SDEF' => 'singleton_method_added', 'EXCEPT' => 'exception'
  }.freeze
  # Punctuation names have no identifier for the outside-source scan to find.
  OPERATOR_NAMES = %w[+ - * / % ** == != < <= > >= <=> === =~ !~ [] []= << >> ! & | ^ ~ +@ -@].freeze
  SEND_OPS = %w[SEND SEND0 SENDB SSEND SSEND0 SSENDB].freeze
  # Ops that copy a value without keeping or running it, or read it only as a condition.
  NEUTRAL_OPS = %w[MOVE GETUPVAR BLKPUSH BLKCALL JMPIF JMPNOT JMPNIL ENTER NOP STOP].freeze
  # Ops whose leading register is only read.
  LEAD_READERS = %w[SETIV SETGV SETCV SETCONST SETMCNST SETUPVAR SETSV RETURN RETURN_BLK BREAK JMPIF JMPNOT
                    JMPNIL ASET SETIDX ARYPUSH HASHADD EXCEPT RAISEIF].freeze
  NON_WRITERS = %w[JMP JMPUW STOP RETSELF].freeze

  Node = Struct.new(:label, :irep, :kind, :name, :parent, :owner, :calls, :lit, :bodies, :seed, :native,
                    :unknown_call, :proc_call, :unknown_block, :invokes, :stored_read, :fiber_body,
                    :yield_unknown, :super_forward, :forwards, :captured, :fwd_any, :fwd_enum, :enum_lit,
                    :any_lit, :enum_send, :klass, :generator, :yielder_calls, :yielder_leak, :callable_send, :fwd_callable,
                    keyword_init: true)

  attr_reader :nodes, :defs_by_name, :fiber_roots_unknown, :reasons, :enum_names

  # opaque_names: the names outside (native and foreign Ruby) code calls back into Ruby by, or nil
  # when they were not scanned. native_names: names some outside source defines.
  def initialize(ireps:, sound:, opaque_names:, native_names:)
    @ireps = ireps
    @sound = sound
    @opaque_names = opaque_names
    @native_names = native_names || Set.new
    @reasons = Hash.new(0)
    @nodes = {}
    @defs_by_name = Hash.new { |h, k| h[k] = [] }
    @passed = Hash.new { |h, k| h[k] = [] } # name => literal blocks passed at sites named so
    @upass = Set.new # names given a block of unknown origin
    @alias_of = Hash.new { |h, k| h[k] = Set.new }
    @fiber_roots_unknown = false
    @callable_names = Set.new
    @callable_all = false
    @enum_names = Set['each']
    @enum_all = false
    @storing_blocks = []
    @isolated = Hash.new { |h, k| h[k] = [] }
    @sealed = false
    build_nodes
    scan_all
    solve
  end

  def sound? = @sound

  # Nothing above this irep's frame can suspend the current Fiber.
  def yield_free?(label)
    @sound && @own.key?(label) && !@own[label]
  end

  # The body of this method, given a block that is itself yield-free, cannot suspend the Fiber.
  def body_yield_free?(label)
    @sound && @nb.key?(label) && !@nb[label]
  end

  def may_yield?(label) = !yield_free?(label)

  # The raw answer, also for a world the proof does not cover (open world): the refusal of methods
  # under a Fiber is best effort there, as it always was.
  def may_yield_unsealed?(label)
    @own.fetch(label, true)
  end

  # Nodes whose frame can lie above a Fiber.new body's entry.
  def fiber_crossable
    @fiber_crossable ||= compute_crossable
  end

  def method_labels = @nodes.values.select { |n| n.kind == :method }.map(&:label)
  def block_labels = @nodes.values.select { |n| n.kind == :block }.map(&:label)
  def fiber_body_labels = @nodes.values.select(&:fiber_body).map(&:label)

  def stats
    m = method_labels
    b = block_labels
    { methods: m.size, methods_free: m.count { |l| yield_free?(l) },
      blocks: b.size, blocks_free: b.count { |l| yield_free?(l) },
      bodies_nb_free: m.count { |l| body_yield_free?(l) }, fiber_bodies: fiber_body_labels.size,
      sealed: @sealed ? true : @seal_reasons, escaping_blocks: @esc.size, enum_names: @enum_all ? :all : @enum_names.size, reasons: @reasons.dup }
  end


  # Why nb(label) holds, recorded when the fixpoint first set it (so the chain is acyclic).
  def explain(label)
    @cause[label] || :none
  end

  # Root cause of nb(label): follows :call/:lit links down to a leaf.
  def root_cause(label)
    e = explain(label)
    return [:none, label] unless e.is_a?(Array)

    case e.first
    when :call, :native, :proc_call then e[2] ? root_cause(e[2]) : [e.first, label]
    when :lit then root_cause(e[1])
    else [e.first, label]
    end
  end

  private

  # -- nodes -----------------------------------------------------------------------------

  def build_nodes
    @ireps.each_value { |irep| @nodes[irep.label] ||= new_node(irep) }
    @super_of = {}
    @module_names = Set.new
    @ireps.each_value do |irep|
      irep.instructions.each_with_index do |insn, idx|
        record_class_decl(irep, insn, idx) if %w[CLASS MODULE].include?(insn.op)
        next unless insn.block_index

        child = irep.reps[insn.block_index]
        next unless child && @nodes[child]

        node = @nodes[child]
        node.parent = irep.label
        case insn.op
        when 'TDEF', 'DEF', 'SDEF'
          node.kind = :method
          node.name = insn.sym
          @defs_by_name[insn.sym] << child
        when 'BLOCK', 'LAMBDA', 'METHOD'
          node.kind = :block
        when 'EXEC'
          node.kind = :body
          node.klass = class_of_exec(irep, insn)
        end
      end
    end
    @nodes.each_value { |n| n.owner = owner_of(n) }
    @nodes.each_value { |n| n.klass ||= enclosing_class(n) }
  end

  # CLASS R :Name has its superclass in R+1; a name declared twice with different supers is unknown.
  def record_class_decl(irep, insn, idx)
    if insn.op == 'MODULE'
      @module_names << insn.sym
      return
    end
    w = irep.source_writer(idx - 1, insn.reg.to_i + 1)
    sup = case w&.op
          when 'LOADNIL' then :object
          when 'GETCONST' then w.const_name
          when 'GETMCNST' then w.mcnst_name
          else :unknown
          end
    @super_of[insn.sym] = @super_of.key?(insn.sym) && @super_of[insn.sym] != sup ? :unknown : sup
  end

  # Name of the class or module an EXEC opens: the CLASS/MODULE op that loaded its register.
  def class_of_exec(irep, exec)
    idx = irep.instructions.index { |i| i.equal?(exec) }
    return nil unless idx

    (idx - 1).downto([idx - 4, 0].max) do |k|
      i = irep.instructions[k]
      return i.sym if %w[CLASS MODULE].include?(i.op) && i.reg == exec.reg
    end
    nil
  end

  def enclosing_class(node)
    cur = node.parent && @nodes[node.parent]
    cur = @nodes[cur.parent] while cur && cur.kind != :body && cur.parent
    cur&.kind == :body ? cur.klass : nil
  end

  def new_node(irep)
    Node.new(label: irep.label, irep: irep, kind: :body, calls: Set.new, lit: [], bodies: [], seed: false,
             native: false, unknown_call: false, proc_call: false, unknown_block: false, invokes: false,
             stored_read: false, fiber_body: false, yield_unknown: false, super_forward: false,
             forwards: Set.new, captured: false, fwd_any: false, fwd_enum: false, enum_lit: [], any_lit: [],
             enum_send: false, klass: nil, generator: false, yielder_calls: Set.new, yielder_leak: false,
             callable_send: false, fwd_callable: false)
  end

  # The method whose block a `yield` in this node reaches: the nearest enclosing method.
  def owner_of(node)
    cur = node
    while cur
      return cur.label if cur.kind == :method
      return nil if cur.kind == :body

      cur = cur.parent && @nodes[cur.parent]
    end
    nil
  end

  # -- per-node facts -----------------------------------------------------------------------

  def scan_all
    mark_generators
    fiber_sites = 0
    fiber_classified = 0
    @nodes.each_value do |node|
      program = BytecodeIR.for(node.irep)
      irep = node.irep
      enter = irep.enter
      node.invokes = true if enter && enter.enter_fields[6].to_i.positive?
      irep.instructions.each_with_index do |insn, idx|
        op = insn.op
        node.calls << OP_NAMES[op] if OP_NAMES[op] && !insn.block_index
        case op
        when 'GETCONST', 'GETMCNST'
          fiber_sites += 1 if op == 'GETCONST' && insn.const_name == 'Fiber'
          @yielder_named_outside = true if %w[Yielder Generator].include?(insn.const_name) && !internal_file?(node)
        when 'BLKPUSH', 'BLKCALL' then node.invokes = true
        when 'SUPER'
          # The block this method received goes on to the super method.
          node.calls << (@nodes[node.owner]&.name || '')
          node.super_forward = true
        when 'LOADSYM' then @fiber_roots_unknown = true if insn.sym == 'Fiber'
        when 'STRING', 'SYMBOL'
          @fiber_roots_unknown = true if insn.pool_index && irep.pool[insn.pool_index] == 'Fiber'
        when 'ALIAS'
          new_name, old_name = insn.args.to_s.scan(/:?([^\s:]+)/).flatten
          @alias_of[new_name] << old_name if new_name && old_name
        when 'BLOCK', 'LAMBDA', 'METHOD'
          child = irep.reps[insn.block_index]
          node.lit << child if child
          @storing_blocks << child if child && op == 'LAMBDA'
        when 'EXEC'
          child = irep.reps[insn.block_index]
          node.bodies << child if child
        end
        note_index_read(node, program, insn, idx) if %w[GETIDX GETIDX0].include?(op)
        fiber_classified += scan_send(node, program, insn, idx) if SEND_OPS.include?(op)
      end
    end
    @fiber_roots_unknown = true if fiber_sites > fiber_classified
    @nodes.each_value { |n| seed_unknown_yield(n) } if @fiber_roots_unknown
    @reasons[:fiber_const_escapes] += 1 if @fiber_roots_unknown
    finish_scan
    @nodes.each_value { |n| scan_captures(n) if n.invokes }
  end

  # Literal blocks given to Enumerator.new and its kin get a yielder as first argument.
  def mark_generators
    @nodes.each_value do |node|
      irep = node.irep
      irep.instructions.each_with_index do |insn, idx|
        next unless insn.op == 'SENDB' && insn.sym == 'new'
        next unless GENERATOR_CLASSES.include?(const_receiver(irep, idx, insn.reg))

        prev = irep.instructions[idx - 1]
        next unless prev&.op == 'BLOCK'

        child = irep.reps[prev.block_index]
        @nodes[child].generator = true if child
      end
    end
  end

  # Values that are never a Proc, so `x[i]` on them does not run one.
  NON_PROC_WRITERS = %w[ARRAY ARRAY2 STRING HASH LOADI__1 LOADI_0 LOADI_1 LOADI_2 LOADI_3 LOADI_4 LOADI_5 LOADI_6
                        LOADI_7 LOADI8 LOADINEG LOADI16 LOADI32 LOADL LOADSYM LOADNIL LOADTRUE LOADFALSE INTERN
                        SYMBOL RANGE_INC RANGE_EXC STRCAT].freeze

  # `pr[1]` runs a Proc like `pr.call(1)`; the index ops do not say what the receiver is.
  def note_index_read(node, program, insn, idx)
    reg = insn.regs.last
    w = reg && node.irep.source_writer(idx - 1, reg)
    node.proc_call = true unless w && NON_PROC_WRITERS.include?(w.op)
  end

  def seed_unknown_yield(node)
    return unless node.yield_unknown

    node.seed = true
    @reasons[:yield_unknown_receiver] += 1
  end

  # Sets the facts of one send; returns 1 when it consumed a `Fiber` constant receiver.
  def scan_send(node, program, insn, idx)
    irep = node.irep
    name = insn.sym
    return 0 unless name

    op = insn.op
    dest = insn.reg
    explicit = %w[SEND SEND0 SENDB].include?(op)
    recv_const = explicit && dest ? const_receiver(irep, idx, dest) : nil
    fiber_recv = recv_const == 'Fiber'
    has_block = %w[SENDB SSENDB].include?(op)
    lit_block, forward = classify_send_block(node, program, insn, idx) if has_block
    consumed = fiber_recv ? scan_fiber_call(node, name, lit_block) : 0
    if name == 'yield' && explicit && !fiber_recv
      # An unknown receiver may be the Fiber class itself (seeded when the class escapes its literals).
      node.yield_unknown = true if recv_const.nil?
      node.calls << name
    elsif name == 'transfer'
      node.seed = true
    end
    targets = block_targets(name, recv_const)
    targets.each { |t| @passed[t] << lit_block } if lit_block && !(fiber_recv && name == 'new')
    @storing_blocks << lit_block if lit_block && targets.any? { |t| STORING_CALLS.include?(t) } && !fiber_recv
    note_yielder_call(node, program, idx, dest, name, explicit)
    resolved = name
    if DYNAMIC_SENDS.include?(name)
      resolved = scan_dynamic_send(node, program, insn, idx, dest, lit_block, forward) || name
    else
      node.forwards.merge(targets) if forward
    end
    scan_special_call(node, program, idx, dest, name, explicit, lit_block, recv_const, insn)
    node.stored_read = true if STORED_READS.include?(name)
    node.calls << resolved unless name == 'yield' && fiber_recv
    node.calls << 'to_a' if insn.n_spec == '*'
    node.calls << 'to_hash' if insn.nk_spec == '*'
    consumed
  end

  # Where a block given to `name` goes. `Klass.new { }` of a class the world defines hands it to that
  # class's initialize; only a native class (Hash's default proc, Proc, ...) keeps it itself, and a
  # receiver that is not a constant may be either.
  def block_targets(name, recv_const)
    return [name] unless name == 'new'
    return ["initialize@#{recv_const}"] if recv_const && world_class?(recv_const)

    %w[new initialize]
  end

  def world_class?(const)
    @world_classes ||= @nodes.values.select { |n| n.kind == :body }.filter_map(&:klass).to_set
    @world_classes.include?(const)
  end

  # A send on the yielder parameter of a generator block (or of a block inside one).
  def note_yielder_call(node, program, idx, dest, name, explicit)
    return unless explicit && dest && yielder_scope?(node)
    return unless classify_reg(node, program, idx, dest) == [:param, 1]

    YIELDER_MESSAGES.include?(name) ? node.yielder_calls << name : node.yielder_leak = true
  end

  # Generator block, or a block nested in one.
  def yielder_scope?(node)
    cur = node
    while cur
      return true if cur.generator

      cur = cur.parent && @nodes[cur.parent]
      return false unless cur&.kind == :block
    end
    false
  end

  # Returns [literal block label or nil, forwards-the-received-block?] and records the other kinds.
  def classify_send_block(node, program, insn, idx)
    kind, ref = classify_block(node, program, insn, idx, block_register(insn))
    case kind
    when :lit then [ref, false]
    when :sym
      node.calls << ref
      @callable_names << ref
      [nil, false]
    when :forward
      node.invokes = true
      [nil, true]
    else
      node.unknown_block = true
      @upass << insn.sym
      @reasons[:unknown_block] += 1
      [nil, false]
    end
  end

  def scan_fiber_call(node, name, lit_block)
    case name
    when 'new'
      if lit_block
        @nodes[lit_block].fiber_body = true
      else
        @fiber_roots_unknown = true
      end
    when 'current', 'alive?', 'resume' then nil
    else
      node.seed = true
      @reasons[:fiber_yield] += 1 if name == 'yield'
    end
    1
  end

  # A send whose name is computed. Returns the literal name when there is one.
  def scan_dynamic_send(node, program, insn, idx, dest, lit_block, forward)
    kind, ref = dest ? classify_reg(node, program, idx, dest.to_i + 1, elem0: insn.n_spec == '*') : [:unknown]
    return ref if kind == :sym

    file = node.irep.file.to_s
    if kind == :ivar && ref == 'meth' && file.include?('mruby-enumerator')
      # Enumerator dispatches to the method it was made for (to_enum, enum_for, Enumerator.new).
      node.enum_send = true
      node.fwd_enum = true if forward
      node.enum_lit << lit_block if lit_block
      @reasons[:enumerator_send] += 1
      return nil
    end
    if CALLABLE_SEND_METHODS.include?(@nodes[node.owner]&.name) && file.match?(%r{/mrblib/(symbol|enum)\.rb\z})
      # Symbol#to_proc and Enumerable#inject(:sym) call the method named by a Symbol: those given to them.
      node.callable_send = true
      node.fwd_callable = true if forward
      @reasons[:callable_send] += 1
      return nil
    end
    node.unknown_call = true
    node.fwd_any = true if forward
    node.any_lit << lit_block if lit_block
    @reasons[:dynamic_send] += 1
    nil
  end

  def scan_special_call(node, program, idx, dest, name, explicit, lit_block, recv_const, insn)
    if CODE_EVAL.include?(name)
      return node.calls << name if lit_block

      # Code built at run time is unknown; outside a closed world nothing about unknown code is claimed.
      node.seed = true if @sound
      @reasons[:eval] += 1
    elsif BLOCK_EXEC.include?(name)
      node.unknown_call = true unless lit_block
    elsif PROC_CALLS.include?(name)
      recv = explicit ? classify_reg(node, program, idx, dest) : [:unknown]
      recv.first == :forward ? node.invokes = true : node.proc_call = true
    end
    note_callable(node, program, idx, dest, name)
    note_enumerator(node, program, idx, dest, name, recv_const)
  end

  def note_callable(node, program, idx, dest, name)
    note_inject_symbol(node, program, idx, dest, name) if %w[inject reduce].include?(name)
    return unless CALLABLE_MAKERS.include?(name)

    target = if name == 'to_proc'
               kind, ref = dest ? classify_reg(node, program, idx, dest) : [:unknown]
               kind == :sym ? ref : nil
             else
               literal_symbol_arg(node, program, idx, dest)
             end
    target ? @callable_names << target : @callable_all = true
  end

  # `inject(:sym)` / `inject(init, :sym)` name the method to call; a block form names none.
  def note_inject_symbol(node, program, idx, dest, name)
    insn = node.irep.instructions[idx]
    return if insn.op == 'SENDB' || insn.op == 'SSENDB' || insn.argc == 0
    return unless dest

    n = insn.n_spec == '*' ? nil : insn.n_spec.to_i
    kind, ref = n ? classify_reg(node, program, idx, dest.to_i + n) : [:unknown]
    kind == :sym ? @callable_names << ref : @callable_all = true
  end

  # The method names an Enumerator can be made for: what to_enum/enum_for/Enumerator.new are given.
  def note_enumerator(node, program, idx, dest, name, recv_const)
    return if %w[to_enum enum_for].include?(node.name) && node.irep.file.to_s.include?('mruby-enumerator')

    if %w[to_enum enum_for].include?(name)
      lit = literal_symbol_arg(node, program, idx, dest)
      lit ? @enum_names << lit : @enum_all = true
    elsif name == 'new' && recv_const == 'Enumerator'
      kind, ref = dest ? classify_reg(node, program, idx, dest.to_i + 2) : [:unknown]
      @enum_names << ref if kind == :sym
      @enum_all = true if kind != :sym && node.irep.instructions[idx].n_spec.to_i >= 2
    end
  end

  def finish_scan
    ruby_names = @defs_by_name.keys.to_set
    @nodes.each_value do |node|
      node.lit = node.lit.compact
      node.native = node.calls.any? { |c| !ruby_names.include?(c) || @native_names.include?(c) }
    end
    # Class#new hands its block to initialize.
    @alias_of.each do |new_name, olds|
      olds.each do |o|
        @defs_by_name[new_name].concat(@defs_by_name[o])
        @passed[o].concat(@passed[new_name])
      end
    end
  end

  # -- register tracing ---------------------------------------------------------------------

  # Register of the block argument of a SENDB/SSENDB.
  def block_register(insn)
    dest = insn.reg
    return nil unless dest

    pos = insn.n_spec == '*' ? 1 : insn.n_spec.to_i
    kw = case insn.nk_spec
         when nil then 0
         when '*' then 1
         else insn.nk_spec.to_i * 2
         end
    dest.to_i + pos + kw + 1
  end

  # Name of the constant a receiver register was loaded from, or nil when it is not a plain
  # GETCONST in the same straight line.
  def const_receiver(irep, idx, reg)
    return nil unless reg

    w = irep.source_writer(idx - 1, reg)
    case w&.op
    when 'GETCONST' then w.const_name
    when 'GETMCNST' then w.mcnst_name
    end
  end

  # True when no jump lands between the two instructions.
  def straight?(program, irep, from_idx, to_idx)
    lo = irep.instructions[from_idx].addr
    hi = irep.instructions[to_idx].addr
    program.branch_targets.none? { |t| t > lo && t <= hi }
  end

  # Register that holds the block the method received (ENTER's block field).
  def block_reg_of(irep)
    enter = irep.enter
    return nil unless enter

    m, o, r, post, kw, kd, b = enter.enter_fields
    return nil unless b.to_i.positive?

    1 + m + o + (r.to_i.positive? ? 1 : 0) + post + (kw.to_i.positive? || kd.to_i.positive? ? 1 : 0)
  end

  # Indices of the instructions that write each register (by leading operand), per irep.
  def writers_of(irep)
    @writers ||= {}.compare_by_identity
    @writers[irep] ||= begin
      map = Hash.new { |h, k| h[k] = [] }
      irep.instructions.each_with_index do |i, n|
        r = i.reg
        map[r.to_i] << n if r && !LEAD_READERS.include?(i.op) && !NON_WRITERS.include?(i.op)
      end
      map
    end
  end

  # What a register holds when instruction idx reads it: [:lit, child_label], [:sym, name],
  # [:forward] (the block the method received), [:const, name], [:ivar, name] or [:unknown]. A
  # register with one writer in the whole irep holds that writer's value; a temporary with several
  # is followed only when no jump lands between its last writer and the read.
  def classify_reg(node, program, idx, reg, elem0: false)
    irep = node.irep
    reg = reg.to_i
    from = idx
    loop do
      ws = writers_of(irep)[reg]
      w_idx = if ws.size == 1
                ws.first
              else
                last = ws.select { |x| x < from }.max
                last && straight?(program, irep, last, from) ? last : nil
              end
      if w_idx.nil?
        return [:forward] if ws.empty? && reg == block_reg_of(irep)
        return [:param, 1] if ws.empty? && reg == 1 && node.generator && irep.enter&.enter_fields&.first.to_i >= 1

        return [:unknown]
      end
      w = irep.instructions[w_idx]
      case w.op
      when 'MOVE'
        reg = w.regs[1].to_i
        from = w_idx
        next
      when 'BLOCK', 'LAMBDA' then return [:lit, irep.reps[w.block_index]]
      when 'LOADSYM' then return [:sym, w.sym]
      when 'BLKPUSH' then return [:forward]
      when 'GETCONST' then return [:const, w.const_name]
      when 'GETIV' then return [:ivar, w.ivar]
      when 'GETUPVAR' then return classify_upvar(node, w)
      when 'ARRAY', 'ARYCAT', 'ARYPUSH'
        # The first element of an argument array is what the register held before it was built.
        return [:unknown] unless elem0

        from = w_idx
        next
      else return [:unknown]
      end
    end
  end

  # A GETUPVAR of an enclosing method's block parameter (or of the local its MOVE copies it to).
  def classify_upvar(node, insn)
    up = insn.upvar_ref
    return [:unknown] unless up

    index, level = up
    cur = node
    (level + 1).times { cur = cur&.parent && @nodes[cur.parent] }
    return [:param, 1] if cur&.generator && index == 1 && !writes_reg?(cur, 1)
    return [:unknown] unless cur && cur.kind == :method

    bp = block_reg_of(cur.irep)
    return [:unknown] unless bp

    only_block_writes?(cur, index, bp) ? [:forward] : [:unknown]
  end

  # Does the node, or a block below it, assign register +index+ (by write or SETUPVAR)?
  def writes_reg?(node, index)
    return true unless writers_of(node.irep)[index].empty?
    return true if node.irep.instructions.any? { |i| i.op == 'SETUPVAR' && i.upvar_ref&.first == index }

    node.lit.any? { |c| writes_upvar?(@nodes[c], index) }
  end

  def writes_upvar?(node, index)
    node.irep.instructions.any? { |i| i.op == 'SETUPVAR' && i.upvar_ref&.first == index } ||
      node.lit.any? { |c| writes_upvar?(@nodes[c], index) }
  end

  # Every write of register +index+ in the method (and every SETUPVAR of it below) is a MOVE of
  # the block register, so the register always holds the block.
  def only_block_writes?(method, index, bp)
    writers = method.irep.instructions.select do |i|
      i.reg == index.to_s && !LEAD_READERS.include?(i.op) && !NON_WRITERS.include?(i.op)
    end
    if writers.empty?
      return false unless index == bp
    elsif !writers.all? { |i| i.op == 'MOVE' && i.regs[1] == bp.to_s }
      return false
    end

    !descendant_sets?(method, index)
  end

  def descendant_sets?(method, index)
    method.lit.any? do |c|
      n = @nodes[c]
      n.irep.instructions.any? { |i| i.op == 'SETUPVAR' && i.upvar_ref&.first == index } ||
        descendant_sets?(n, index)
    end
  end

  def classify_block(node, program, insn, idx, block_reg)
    return [:unknown] unless block_reg

    irep = node.irep
    prev = irep.instructions[idx - 1]
    if prev&.op == 'BLOCK' && prev.reg == block_reg.to_s
      child = irep.reps[prev.block_index]
      return child ? [:lit, child] : [:unknown]
    end
    classify_reg(node, program, idx, block_reg)
  end

  def literal_symbol_arg(node, program, idx, dest)
    return nil unless dest

    kind, ref = classify_reg(node, program, idx, dest.to_i + 1, elem0: node.irep.instructions[idx].n_spec == '*')
    kind == :sym ? ref : nil
  end

  # -- does the received block escape? ----------------------------------------------------------

  # Marks node.captured when the block this method received is kept as a value (stored, returned,
  # passed as an ordinary argument or receiver of anything but a call), not merely run or
  # forwarded as the block of another call.
  def scan_captures(node)
    scan_keeps(node) { |r| r == [:forward] }.tap { |kept| node.captured = kept }
  end

  # Marks node.yielder_leak when the yielder parameter of a generator block is used other than as the
  # receiver of a message Enumerator::Yielder answers.
  def scan_yielder_leaks(node)
    node.yielder_leak ||= scan_keeps(node) { |r| r == [:param, 1] }
  end

  # Does any instruction keep, pass on or return a register for which the block answers true?
  def scan_keeps(node, &holds)
    irep = node.irep
    program = BytecodeIR.for(irep)
    irep.instructions.each_with_index do |insn, idx|
      op = insn.op
      next if NEUTRAL_OPS.include?(op)

      if SEND_OPS.include?(op)
        return true if send_keeps?(node, program, insn, idx, &holds)
      elsif insn.regs.any? { |r| holds.call(classify_reg(node, program, idx, r)) && !written_here?(insn, r) }
        return true
      end
    end
    false
  end

  # An op that only defines its leading register does not read it.
  def written_here?(insn, reg)
    insn.regs.first == reg && !LEAD_READERS.include?(insn.op) && !insn.op.start_with?('SET')
  end

  def send_keeps?(node, program, insn, idx, &holds)
    dest = insn.reg or return false
    pos = insn.n_spec == '*' ? 1 : insn.n_spec.to_i
    kw = insn.nk_spec.nil? ? 0 : (insn.nk_spec == '*' ? 1 : insn.nk_spec.to_i * 2)
    return true if (1..(pos + kw)).any? { |k| holds.call(classify_reg(node, program, idx, dest.to_i + k, elem0: false)) }
    return false unless %w[SEND SEND0 SENDB].include?(insn.op)

    holds.call(classify_reg(node, program, idx, dest)) &&
      !PROC_CALLS.include?(insn.sym) && !PROC_HARMLESS.include?(insn.sym) && !YIELDER_MESSAGES.include?(insn.sym)
  end

  # -- fixpoints ------------------------------------------------------------------------------

  def names_of(label)
    node = @nodes[label]
    names = Set[node.name]
    changed = true
    while changed
      changed = false
      @alias_of.each do |new_name, olds|
        next if names.include?(new_name) || olds.none? { |o| names.include?(o) }

        names << new_name
        changed = true
      end
    end
    names
  end

  # Per method: the union of the facts of the method and the blocks nested in it (they share its
  # received block).
  def aggregate_methods
    @agg = {}
    method_labels.each do |l|
      agg = { captured: false, forwards: Set.new, fwd_any: false, fwd_enum: false, fwd_callable: false, super: false }
      stack = [@nodes[l]]
      until stack.empty?
        n = stack.pop
        agg[:captured] ||= n.captured
        agg[:forwards].merge(n.forwards)
        agg[:fwd_any] ||= n.fwd_any
        agg[:fwd_enum] ||= n.fwd_enum
        agg[:fwd_callable] ||= n.fwd_callable
        agg[:super] ||= n.super_forward
        n.lit.each { |c| stack << @nodes[c] unless @nodes[c].fiber_body }
      end
      @agg[l] = agg
    end
  end

  def callable_defs
    @callable_defs ||= @callable_all ? method_labels : @callable_names.flat_map { |c| @defs_by_name[c] }.uniq
  end

  def enum_defs
    @enum_defs ||= @enum_all ? method_labels : @enum_names.flat_map { |n| @defs_by_name[n] + @isolated.fetch(n, []) }.uniq
  end

  # received(e): the blocks that can be handed to method e, by name, through forwarding (`&blk`,
  # super), and through the dynamic sends.
  def compute_received
    aggregate_methods
    @received = Hash.new { |h, k| h[k] = Set.new }
    enum_lit = @nodes.values.flat_map(&:enum_lit)
    any_lit = @nodes.values.flat_map(&:any_lit)
    isolated = @isolated.values.flatten.to_set
    method_labels.each do |l|
      names_of(l).each { |nm| @received[l].merge(@passed[nm]) } unless isolated.include?(l)
    end
    seed_initialize_received
    enum_defs.each { |d| @received[d].merge(enum_lit) }
    method_labels.each { |d| @received[d].merge(any_lit) }
    loop do
      grown = false
      @agg.each do |f, a|
        src = @received[f]
        next if src.empty?

        forward_targets(f, a).each do |d|
          before = @received[d].size
          @received[d].merge(src)
          grown ||= @received[d].size > before
        end
      end
      break unless grown
    end
  end

  # initialize receives the blocks of `Klass.new` for its own class, of `new` on an unknown receiver,
  # and (its owner being unknown) of any class that defines none of its own.
  def seed_initialize_received
    @init_classes = @defs_by_name['initialize'].map { |d| @nodes[d].klass }.to_set
    inherited = @passed.keys.grep(/\Ainitialize@/).map { |k| k.delete_prefix('initialize@') }.reject { |c| @init_classes.include?(c) }
    @defs_by_name['initialize'].each do |d|
      @received[d].merge(@passed["initialize@#{@nodes[d].klass}"])
      inherited.each { |c| @received[d].merge(@passed["initialize@#{c}"]) }
    end
  end

  def block_target_defs(name)
    return @defs_by_name.fetch(name, []) unless name.start_with?('initialize@')

    klass = name.delete_prefix('initialize@')
    own = @defs_by_name['initialize'].select { |d| @nodes[d].klass == klass }
    own.empty? ? @defs_by_name['initialize'] : own
  end

  # The definitions `super` in this method can reach: the same name in the superclass chain and in
  # any module (mixins are not resolved), or every definition when the chain is not known.
  def super_targets(label)
    node = @nodes[label]
    others = @defs_by_name[node.name] - [label]
    chain = ancestors_of(node.klass)
    return others unless chain

    others.select { |d| chain.include?(@nodes[d].klass) || @module_names.include?(@nodes[d].klass) || @nodes[d].klass.nil? }
  end

  def ancestors_of(klass)
    chain = []
    cur = klass
    while cur && cur != :object
      return nil if cur == :unknown || chain.include?(cur)

      chain << cur
      cur = @super_of[cur]
    end
    chain - [klass]
  end

  def forward_targets(label, agg)
    targets = agg[:forwards].flat_map { |m| callee_defs(@nodes[label], m) }
    targets.concat(enum_defs) if agg[:fwd_enum]
    targets.concat(method_labels) if agg[:fwd_any]
    targets.concat(callable_defs) if agg[:fwd_callable]
    targets.concat(super_targets(label)) if agg[:super]
    targets
  end

  # Does the method itself keep the block it receives (as opposed to handing it on)?
  def keeps_block?(label)
    a = @agg[label]
    a[:captured] || a[:forwards].any? { |m| STORING_CALLS.include?(m) }
  end

  # Blocks that can be kept as Proc values: literal blocks of storing calls, and blocks handed to a
  # method that keeps its block.
  def compute_escaping
    esc = Set.new(@storing_blocks)
    method_labels.each { |l| esc.merge(@received[l]) if keeps_block?(l) && !sealed_keeper?(l) }
    esc
  end

  # What Generator and Yielder keep is run only by their own messages, which the sealed model treats
  # as the yield of Enumerator#next; no other Proc call can reach it.
  def sealed_keeper?(label)
    n = @nodes[label]
    @sealed && %w[Generator Yielder].include?(n.klass) && internal_file?(n)  end

  # Blocks the analysis treats as invoked only by the Enumerator machinery: generator blocks (and
  # what they contain) and the blocks inside the Fibers mruby-enumerator itself creates.
  def sealed_candidates
    @nodes.values.select { |n| n.kind == :block && (yielder_scope?(n) || internal_fiber_block?(n)) }.map(&:label)
  end

  def internal_file?(node) = node.irep.file.to_s.include?('mruby-enumerator/mrblib')

  def internal_fiber_block?(node)
    cur = node
    while cur
      return true if cur.fiber_body && internal_file?(cur)

      cur = cur.parent && @nodes[cur.parent]
    end
    false
  end

  # The Enumerator machinery is modelled explicitly (a yielder is created by Generator#each and handed to
  # a generator block; the block the Fiber-driven `next` supplies runs only through the yielder) when
  # nothing lets a yielder or such a block go anywhere else.
  def compute_sealing
    @seal_reasons = []
    yielder_defs = @nodes.values.select { |n| n.kind == :method && n.klass == 'Yielder' && internal_file?(n) }
    @seal_reasons << :no_yielder if yielder_defs.empty?
    @seal_reasons << :yielder_named_outside if @yielder_named_outside
    @seal_reasons << :yielder_leak if @nodes.values.any? { |n| yielder_scope?(n) && n.yielder_leak }
    @sealed_blocks = sealed_candidates.to_set
    allowed = %w[Generator Yielder Enumerator]
    leaks = method_labels.select do |l|
      keeps_block?(l) && !allowed.include?(@nodes[l].klass) && @received[l].intersect?(@sealed_blocks)
    end
    @seal_reasons << :sealed_block_kept unless leaks.empty?
    @sealed = @seal_reasons.empty?
    return unless @sealed

    isolate_enumerator_machinery(yielder_defs)
    @sealed_blocks.each { |b| @esc.delete(b) }
  end

  # Generator and Yielder methods are reached only from mruby-enumerator's own code (an Enumerator's
  # dispatch, other Enumerator methods) and from generator blocks, never by a plain call to the name
  # (`each`, `<<`): the receivers of those are the objects the rest of the world creates. Yielder's
  # answer to a message is a Fiber.yield when the Enumerator is driven by `next`.
  def isolate_enumerator_machinery(yielder_defs)
    @yielder_methods = yielder_defs.reject { |n| n.name == 'initialize' }
    @yielder_methods.each { |n| n.seed = true }
    isolated = @nodes.values.select do |n|
      n.kind == :method && %w[Generator Yielder].include?(n.klass) && internal_file?(n) && n.name != 'initialize'
    end
    isolated.each do |n|
      @isolated[n.name] << n.label
      @defs_by_name[n.name].delete(n.label)
    end
    @enum_defs = nil
    @received = nil
    compute_received
    @esc = compute_escaping
  end

  # The definitions a call of +name+ from +node+ can reach.
  def callee_defs(node, name)
    defs = block_target_defs(name)
    node && internal_file?(node) && @isolated.key?(name) ? defs + @isolated[name] : defs
  end

  def solve
    @nb = {}
    @own = {}
    @cause = {}
    @nodes.each_key do |l|
      @nb[l] = false
      @own[l] = false
    end
    compute_received
    @esc = compute_escaping
    @nodes.each_value { |n| scan_yielder_leaks(n) if yielder_scope?(n) }
    compute_sealing
    opaque = opaque_defs
    callable = callable_defs
    loop do
      changed = false
      ctx = solve_context
      @nodes.each_value do |n|
        next if @nb[n.label]

        cause = nb_cause(n, opaque, ctx, callable)
        next unless cause

        @nb[n.label] = true
        @cause[n.label] = cause
        changed = true
      end
      @nodes.each_value do |n|
        next if @own[n.label]
        next unless @nb[n.label] || (invokes_deep?(n) && passed_own?(n, ctx))

        @own[n.label] = true
        changed = true
      end
      break unless changed
    end
  end

  # Facts of the current iteration that many nodes ask about.
  def solve_context
    {
      any_code: @nodes.each_value.any? { |n| @nb[n.label] && n.kind == :method && !@yielder_methods&.include?(n) } ||
        @esc.any? { |b| @nb[b] },
      # A block run by an unknown Proc call gets its own block from that call site, so only nb counts.
      any_block: @esc.any? { |b| @nb[b] }
    }
  end

  def nb_cause(n, opaque, ctx, callable)
    return [:seed] if n.seed
    return [:yielder] if @sealed && !n.yielder_calls.empty?

    n.calls.each do |c|
      d = callee_defs(n, c).find { |x| @nb[x] }
      return [:call, c, d] if d
    end
    b = n.lit.find { |x| !@nodes[x].fiber_body && @nb[x] && !(@sealed && @sealed_blocks.include?(x)) }
    return [:lit, b] if b

    x = n.bodies.find { |y| @nb[y] }
    return [:lit, x] if x
    return nil unless @sound # unknown code is only accounted for in a closed world

    return [:unknown_call] if n.unknown_call && ctx[:any_code]

    if n.callable_send
      d = callable.find { |y| @nb[y] }
      return [:call, nil, d] if d
    end
    if n.proc_call || n.unknown_block
      return [:proc_call] if ctx[:any_block]

      d = callable.find { |y| @nb[y] }
      return [:proc_call, nil, d] if d
    end
    if n.native
      d = opaque.find { |y| @nb[y] }
      return [:native, nil, d] if d
    end
    return [:stored_read] if n.stored_read && ctx[:any_block]

    nil
  end

  def invokes_deep?(node, seen = Set.new)
    return false unless seen.add?(node.label)
    return true if node.invokes
    return true if node.super_forward && supers_invoke?(node, seen)

    node.lit.any? { |b| !@nodes[b].fiber_body && invokes_deep?(@nodes[b], seen) }
  end

  def supers_invoke?(node, seen)
    owner = node.owner && @nodes[node.owner]
    return true unless owner&.name

    @defs_by_name[owner.name].any? { |d| d != owner.label && invokes_deep?(@nodes[d], seen) }
  end

  # Could a block that yields have been passed to the method owning +node+?
  def passed_own?(node, ctx)
    owner = node.owner && @nodes[node.owner]
    return ctx[:any_block] unless owner # no known method: the block is of unknown origin

    return true if @received[owner.label].any? { |b| @own[b] }

    ctx[:any_block] && names_of(owner.label).any? { |nm| @upass.include?(nm) }
  end

  def opaque_defs
    return method_labels unless @opaque_names

    (@opaque_names.to_a + OPERATOR_NAMES).flat_map { |nm| @defs_by_name.key?(nm) ? @defs_by_name[nm] : [] }.uniq
  end

  # -- reachability from Fiber.new bodies -------------------------------------------------------

  def compute_crossable
    roots = @fiber_roots_unknown ? @nodes.keys : fiber_body_labels
    opaque = opaque_defs
    seen = Set.new
    queue = roots.dup
    all_methods = method_labels
    escaping = @esc.to_a + (@sealed ? @sealed_blocks.to_a : [])
    until queue.empty?
      l = queue.shift
      next unless seen.add?(l)

      n = @nodes[l]
      n.calls.each { |c| queue.concat(callee_defs(n, c)) }
      queue.concat(n.lit.reject { |b| @nodes[b].fiber_body })
      queue.concat(n.bodies)
      queue.concat(enum_defs) if n.enum_send
      queue.concat(@yielder_methods.map(&:label)) if @sealed && !n.yielder_calls.empty?
      next unless @sound

      queue.concat(all_methods) if n.unknown_call
      queue.concat(callable_defs) if n.callable_send
      queue.concat(escaping + callable_defs) if n.proc_call || n.unknown_block || n.stored_read
      queue.concat(opaque) if n.native
    end
    seen
  end

  public

  # Methods a Fiber's frames can pass through and whose compiled code (or a block compiled into it)
  # may then sit below a Fiber.yield.
  def fiber_unsafe(labels)
    crossable = fiber_crossable
    labels.select do |l|
      node = @nodes[l]
      node && ((crossable.include?(l) && may_yield_unsealed?(l)) || nested_crossable_yielder?(node, crossable))
    end
  end

  private

  def nested_crossable_yielder?(node, crossable)
    node.lit.any? do |c|
      b = @nodes[c]
      !b.fiber_body && ((crossable.include?(c) && @own[c]) || nested_crossable_yielder?(b, crossable))
    end
  end
end
