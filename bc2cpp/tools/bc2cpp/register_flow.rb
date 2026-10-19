# frozen_string_literal: true

require 'set'

# REGISTER_FLOW (ADR 0415): copy propagation and dead register-write removal
# over one method's emitted instruction texts. Registers are the C++ locals
# `rN`, so the text of an instruction is the exact definition of what it reads
# and writes; the CFG is BytecodeIR's. Kill switch: BC2CPP_REGISTER_FLOW=0.
#
# Soundness: the pass refuses (returns the texts untouched) unless the CFG is
# resolved, every `goto` in a text lands on a label that text defines or on an
# address its instruction's normal IR successors reach through instructions that
# emitted nothing, and every catch handler is a rescue region codegen emitted
# (see handler_model_ok?). The optional-argument switch is the one generated text
# whose targets the IR does not give its instruction; add_dispatch_edges adds them,
# for that exact text only. A handler's edges run from every instruction it
# protects to its target, and a write is never killed on that edge: the raise
# may come before the write completes. A register is pinned, never
# dropped or substituted, when it is r0, is read or written through a nested
# block (Insn#upvar_ref), has its address taken or is redeclared inside a text.
# Only a text of the exact shape `  rD = <side-effect-free expression>;` counts
# as a definition; any other text that names a register counts as reading it.
class RegisterFlow
  PURE_WRITE_OPS = Set['MOVE', 'LOADL', 'LOADSYM', 'LOADNIL', 'LOADSELF', 'LOADTRUE', 'LOADFALSE'].freeze
  # A reader whose text takes the register as one plain operand. Window
  # consumers (SEND, ARRAY, ADD, ...) stay out: their texts write registers
  # next to the one they read.
  COPY_READER_OPS = Set['MOVE', 'RETURN', 'JMPIF', 'JMPNOT', 'JMPNIL', 'SETIV', 'SETGV', 'SETCV', 'SETCONST'].freeze
  # Experimental, off by default: BC2CPP_REGISTER_FLOW_WINDOWS=1 also rewrites reads inside window consumers.
  WALK_BUDGET = 400
  CLEAN_DEF = /\A  r(\d+) = ([^;{}\n"]*);\n\z/
  MENTION = /\br(\d+)\b/
  # One register's patterns, built on first use: its name as a whole word, and the forms that write it.
  REGISTER_PATTERNS = Hash.new do |cache, reg|
    name = "r#{reg}"
    cache[reg] = {
      mention: /\b#{name}\b/,
      write: /(?:\+\+|--)\s*#{name}\b|&\s*#{name}\b|\b#{name}\b\s*(?:=(?!=)|[-+*\/%&|^]=|<<=|>>=|\+\+|--|[.\[]|->)|mrb_value\s+#{name}\b/
    }
  end

  Stats = Hash.new(0)

  def self.enabled?
    ENV['BC2CPP_REGISTER_FLOW'] != '0'
  end

  def self.windows?
    ENV['BC2CPP_REGISTER_FLOW_WINDOWS'] == '1'
  end

  # BC2CPP_REGISTER_FLOW_GOTO=0 turns off the dispatch-switch edges; such a method is refused again.
  def self.goto_model?
    ENV['BC2CPP_REGISTER_FLOW_GOTO'] != '0'
  end

  # The text of the optional-argument switch. codegen_method.rb's emit_optional_dispatch
  # calls this too, so the text the pass matches is the text codegen emits.
  def self.dispatch_text(targets)
    out = String.new
    out << "  switch (bc2cpp_given_opt) {\n"
    targets.each_with_index do |addr, i|
      out << (i == targets.size - 1 ? "    default: goto L#{addr};\n" : "    case #{i}: goto L#{addr};\n")
    end
    out << "  }\n"
    out
  end

  # Kill switch for the handler model alone: 0 refuses every method with a catch handler.
  def self.handlers_enabled?
    ENV['BC2CPP_REGISTER_FLOW_HANDLERS'] != '0'
  end

  if ENV['BC2CPP_REGISTER_FLOW_STATS']
    at_exit { Stats.sort.each { |key, count| warn "register_flow: #{key} #{count}" } }
  end

  # Registers of +irep+ that a nested block reads or writes by upvar, or nil
  # when the irep tree is needed and missing.
  def self.captured_registers(irep)
    return Set.new if irep.reps.nil? || irep.reps.empty?

    tree = irep.tree or return nil
    found = Set.new
    collect_captured(tree, irep, found) ? found : nil
  end

  # False when a nested block reads this frame's arguments implicitly (ARGARY),
  # which names no register.
  def self.collect_captured(tree, irep, found)
    lookup = ->(label) { tree[label] or raise ArgumentError, "bc2cpp: irep #{label} missing from the tree" }
    Array(irep.reps).all? do |label|
      BytecodeIR.each_nested_insn(lookup.call(label), lookup) do |insn, depth|
        return false if insn.op == 'ARGARY'

        index, level = insn.upvar_ref
        found << index.to_i if index && level == depth
      end
    end
  end

  # Returns the new per-instruction texts (the same Array when nothing changed).
  # +handlers+ is the rescue model codegen emitted (see handler_model_ok?), or nil
  # when the method has no model: a method with a catch handler is then refused.
  #   { regions: [{begin_addr:, end_addr:, except_addr:}, ...],   every recognized region
  #     glue_reads: { begin_addr => [reg, ...] } }                 top-level regions only
  def self.optimize(irep, texts, captured, handlers: nil)
    return texts unless enabled? && captured

    Stats['methods'] += 1
    flow = new(irep, texts, captured, handlers)
    flow.run
  end

  def initialize(irep, texts, captured, handlers = nil)
    @irep = irep
    @insns = irep.instructions
    @original = texts
    @texts = texts.dup
    @captured = captured
    @handlers = handlers
    @program = BytecodeIR.for(irep)
  end

  def run
    # Only a pure write can change a text (copy propagation takes a MOVE, which is one). Without one the texts come
    # back unchanged, so the CFG and the refusal checks are not needed.
    return @original unless @insns.any? { |insn| pure_write_op?(insn.op) }

    reason = refusal
    if reason
      Stats["refused #{reason}"] += 1
      return @original
    end

    Stats['methods with handlers'] += 1 if @program.handlers?
    scan
    propagate_copies
    drop_dead_writes
    changed = @texts != @original
    Stats['methods changed'] += 1 if changed
    changed ? @texts : @original
  end

  private

  def mentions(text)
    text.scan(MENTION).flatten.map(&:to_i)
  end

  def mask_of(regs)
    regs.uniq.sum { |reg| 1 << reg }
  end

  def mention_mask(text)
    mask = 0
    text.scan(MENTION) { |(reg)| mask |= 1 << reg.to_i }
    mask
  end

  def transparent?(index)
    @texts[index].each_line.all? { |line| line.strip.empty? || line.lstrip.start_with?('//') }
  end

  # nil when the pass may run, else why not.
  def refusal
    return 'unresolved' unless @program.resolved?
    return 'handlers' if @program.handlers? && !self.class.handlers_enabled?
    return 'empty' if @insns.empty?
    return 'alias' if @texts.any? { |text| text.match?(/mrb_value\s*&|\[\s*&/) }

    @transparent = @texts.each_index.map { |i| transparent?(i) }
    # Window mode (experimental) keeps refusing handler methods: the handler model widens
    # only the default pass.
    return 'handlers' if @program.handlers? && (self.class.windows? || !handler_model_ok?)

    build_edges
    return 'goto' unless gotos_follow_ir?
    return 'fallthrough' unless terminators_leave?

    nil
  end

  # Exact handler coverage (docs/bc2cpp-register-output.md): each handler is a
  # recognized rescue region, each glue names the registers its try body reads,
  # and only that glue emitted text in a protected range.
  def handler_model_ok?
    return false unless @handlers && @program.handlers_resolved?

    regions = @handlers[:regions]
    handlers = @program.catch_handlers
    return false unless handlers.map { |h| [h.begin_addr, h.end_addr, h.target] }.sort ==
                        regions.map { |r| [r[:begin_addr], r[:end_addr], r[:except_addr]] }.sort

    glue = @handlers[:glue_reads]
    glue.each do |addr, regs|
      index = @program.address_to_index[addr] or return false
      mentioned = mentions(@texts[index])
      return false unless regs.all? { |reg| mentioned.include?(reg) }
    end

    handlers.all? do |handler|
      @insns.each_index.all? do |i|
        addr = @insns[i].addr
        next true unless addr >= handler.begin_addr && addr < handler.end_addr
        next true if glue.key?(addr)

        @transparent[i]
      end
    end
  end

  # Normal IR successors plus the text-level fall-through of an instruction that
  # emitted nothing: its jump or return left no code, so control runs into the
  # next text. @succ adds the handler edges (every instruction a handler
  # protects to its target), which liveness treats apart from normal flow.
  def build_edges
    count = @insns.length
    @normal_succ = Array.new(count) { |i| @program.instruction_at(i).successors.dup }
    count.times do |i|
      @normal_succ[i] << i + 1 if @transparent[i] && i + 1 < count && !@normal_succ[i].include?(i + 1)
    end
    add_dispatch_edges if self.class.goto_model?
    @handler_succ = Array.new(count) { [] }
    if @program.handlers?
      count.times do |i|
        @handler_succ[i] = @program.successors_of(i, include_handlers: true) - @program.successors_of(i)
      end
    end
    @succ = Array.new(count) { |i| (@normal_succ[i] + @handler_succ[i]).uniq }
    @pred = Array.new(count) { [] }
    @succ.each_with_index { |targets, i| targets.each { |t| @pred[t] << i } }
    @pred[0] << BytecodeIR::ENTRY
  end

  # OPTIONAL_ARG_SUPPORT (irep_arity.rb): the first table JMP's text is the switch
  # of RegisterFlow.dispatch_text over the table's targets, and every other table
  # JMP emitted nothing. The switch can reach each default-value target, but the IR
  # gives that JMP only its own target, so the targets become its normal successors here.
  # Only that exact text counts; any other shape keeps the goto refusal.
  def add_dispatch_edges
    table = optional_arg_table(@irep)
    table = optional_block_arg_table(@irep) || table unless table[1]
    _opt, sources, targets = table
    return unless sources

    indexes = sources.map { |addr| @program.address_to_index[addr] }
    target_indexes = targets.map { |addr| @program.address_to_index[addr] }
    return if indexes.include?(nil) || target_indexes.include?(nil)

    first = indexes.first
    return unless @texts[first] == self.class.dispatch_text(targets)
    return unless indexes.drop(1).all? { |i| @texts[i].empty? }

    @normal_succ[first] = (@normal_succ[first] + target_indexes).uniq
  end

  # Goto targets are judged on normal flow: the glue's `goto` to a shared exit
  # is a normal-flow edge, and a handler edge is not a jump the text makes.
  def allowed_goto_addrs(index)
    seen = Set.new
    work = @normal_succ[index].dup
    addrs = Set.new
    until work.empty?
      node = work.pop
      next unless seen.add?(node)

      addrs << @insns[node].addr
      work.concat(@normal_succ[node]) if @transparent[node]
    end
    addrs
  end

  def gotos_follow_ir?
    @texts.each_with_index.all? do |text, i|
      next true unless text.include?('goto')

      targets = text.scan(/\bgoto\s+(\w+)\s*;/).flatten
      next false if text.scan(/\bgoto\b/).length != targets.length

      allowed = nil
      targets.all? do |name|
        next true if text.match?(/^\s*#{Regexp.escape(name)}\s*:/)

        match = /\AL(\d+)\z/.match(name)
        match && (allowed ||= allowed_goto_addrs(i)).include?(match[1].to_i)
      end
    end
  end

  # An op the IR says never falls through must not fall through in its text.
  def terminators_leave?
    @insns.each_index.all? do |i|
      next true if @transparent[i] || !BytecodeIR::NO_FALLTHROUGH.include?(@insns[i].op)

      @texts[i].match?(/\b(?:goto|return|throw)\b|mrb_raise|bc2cpp_raise/)
    end
  end

  def scan
    @pinned = Set[0]
    @captured.each { |reg| @pinned << reg }
    @texts.each do |text|
      text.scan(/&\s*r(\d+)\b/) { |(reg)| @pinned << reg.to_i }
      text.scan(/\bmrb_value\s+r(\d+)\b/) { |(reg)| @pinned << reg.to_i }
    end
    @info = @texts.each_index.map { |i| info_for(i) }
  end

  # [definition register or nil, read mask, all-mention mask]
  def info_for(index)
    text = @texts[index]
    all = mention_mask(text)
    match = CLEAN_DEF.match(text)
    if match && !match[2].match?(/(?<![=!<>])=(?!=)|\b(?:goto|return|throw)\b/)
      [match[1].to_i, mention_mask(match[2]), all]
    else
      [nil, all, all]
    end
  end

  def pure_write?(index)
    pure_write_op?(@insns[index].op)
  end

  def pure_write_op?(op)
    PURE_WRITE_OPS.include?(op) || op.start_with?('LOADI')
  end

  # --- liveness -------------------------------------------------------------

  def live_out_sets(dropped)
    count = @insns.length
    live_in = Array.new(count, 0)
    pinned_mask = mask_of(@pinned.to_a)
    changed = true
    live_out = Array.new(count, 0)
    while changed
      changed = false
      (count - 1).downto(0) do |i|
        normal_out = pinned_mask
        @normal_succ[i].each { |s| normal_out |= live_in[s] }
        # A handler edge leaves before this instruction's write completes, so
        # the handler's reads stay live above the write and are never killed.
        handler_out = 0
        @handler_succ[i].each { |s| handler_out |= live_in[s] }
        out = normal_out | handler_out
        live_out[i] = out
        if dropped.include?(i)
          incoming = out
        else
          kill, reads, = @info[i]
          incoming = reads | (kill ? normal_out & ~(1 << kill) : normal_out) | handler_out
        end
        next if incoming == live_in[i]

        live_in[i] = incoming
        changed = true
      end
    end
    live_out
  end

  def drop_dead_writes
    dropped = Set.new
    loop do
      live_out = live_out_sets(dropped)
      fresh = @insns.each_index.select do |i|
        next false if dropped.include?(i) || !pure_write?(i)

        kill = @info[i][0]
        kill && !@pinned.include?(kill) && live_out[i][kill].zero?
      end
      break if fresh.empty?

      dropped.merge(fresh)
    end
    dropped.each do |i|
      Stats["dropped #{@insns[i].op.start_with?('LOADI') ? 'LOADI' : @insns[i].op}"] += 1
      @texts[i] = ''
    end
  end

  # --- copy propagation -------------------------------------------------------

  def propagate_copies
    @insns.each_index do |i|
      next unless @insns[i].op == 'MOVE'

      match = /\A  r(\d+) = r(\d+);\n\z/.match(@texts[i]) or next
      dest = match[1].to_i
      src = match[2].to_i
      next if dest == src || @pinned.include?(dest) || @pinned.include?(src)

      readers = copy_readers(i, dest, src) or next
      next unless readers.all? { |j| copy_available?(i, j, dest, src) }

      readers.each { |j| substitute(j, dest, src) }
      Stats['copies propagated'] += 1 unless readers.empty?
    end
  end

  # Instructions reading +dest+ after the copy at +origin+, or nil when one of
  # them cannot take +src+ instead.
  def copy_readers(origin, dest, src)
    readers = []
    seen = Set.new
    work = @succ[origin].map { |s| [s, false] }
    until work.empty?
      node, src_changed = work.pop
      next if node == origin || !seen.add?([node, src_changed])
      return nil if seen.size > WALK_BUDGET

      kill, reads, all = @info[node]
      if reads[dest] == 1
        return nil if src_changed || !substitutable?(node, dest, src)

        readers << node
      elsif kill == dest
        next
      end
      changed = src_changed || (all[src] == 1 && !readonly?(node, src))
      @succ[node].each { |s| work << [s, changed] }
    end
    readers.uniq
  end

  # Every path from the entry to +reader+ passes through the copy at +origin+
  # and neither register is written after it.
  def copy_available?(origin, reader, dest, src)
    seen = Set.new
    work = @pred[reader].dup
    until work.empty?
      node = work.pop
      return false if node == BytecodeIR::ENTRY
      next if node == origin || !seen.add?(node)
      return false if seen.size > WALK_BUDGET

      _kill, _reads, all = @info[node]
      return false if all[dest] == 1 && !readonly?(node, dest)
      return false if all[src] == 1 && !readonly?(node, src)

      work.concat(@pred[node])
    end
    true
  end

  # The text names +reg+ only as a value to read.
  def readonly?(index, reg)
    patterns = REGISTER_PATTERNS[reg]
    text = @texts[index]
    return true unless text.match?(patterns[:mention])

    !text.match?(patterns[:write])
  end

  def substitutable?(index, dest, src)
    return false unless self.class.windows? || COPY_READER_OPS.include?(@insns[index].op)
    return false unless readonly?(index, dest) && readonly?(index, src)

    text = @texts[index]
    stripped = text.gsub(/"(?:\\.|[^"\\])*"/, '""').gsub(%r{//[^\n]*}, '').gsub(%r{/\*.*?\*/}m, '')
    mention = REGISTER_PATTERNS[dest][:mention]
    text.scan(mention).length == stripped.scan(mention).length
  end

  def substitute(index, dest, src)
    @texts[index] = @texts[index].gsub(REGISTER_PATTERNS[dest][:mention], "r#{src}")
    @info[index] = info_for(index)
  end
end
