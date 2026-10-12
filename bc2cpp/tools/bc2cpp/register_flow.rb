# frozen_string_literal: true

require 'set'

# REGISTER_FLOW (ADR 0415): copy propagation and dead register-write removal
# over one method's emitted instruction texts. Registers are the C++ locals
# `rN`, so the text of an instruction is the exact definition of what it reads
# and writes; the CFG is BytecodeIR's. Kill switch: BC2CPP_REGISTER_FLOW=0.
#
# Soundness: the pass refuses (returns the texts untouched) unless the CFG is
# resolved, the method has no catch handler, and every `goto` in a text lands on
# a label that text defines or on an address its instruction's IR successors
# reach through instructions that emitted nothing. A register is pinned, never
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

  Stats = Hash.new(0)

  def self.enabled?
    ENV['BC2CPP_REGISTER_FLOW'] != '0'
  end

  def self.windows?
    ENV['BC2CPP_REGISTER_FLOW_WINDOWS'] == '1'
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
    collect_captured(tree, irep, 1, found) ? found : nil
  end

  # False when a nested block reads this frame's arguments implicitly (ARGARY),
  # which names no register.
  def self.collect_captured(tree, irep, depth, found)
    Array(irep.reps).all? do |label|
      child = tree[label] or raise ArgumentError, "bc2cpp: irep #{label} missing from the tree"
      child.instructions.each do |insn|
        return false if insn.op == 'ARGARY'

        index, level = insn.upvar_ref
        found << index.to_i if index && level == depth - 1
      end
      collect_captured(tree, child, depth + 1, found)
    end
  end

  # Returns the new per-instruction texts (the same Array when nothing changed).
  def self.optimize(irep, texts, captured)
    return texts unless enabled? && captured

    Stats['methods'] += 1
    flow = new(irep, texts, captured)
    flow.run
  end

  def initialize(irep, texts, captured)
    @irep = irep
    @insns = irep.instructions
    @original = texts
    @texts = texts.dup
    @captured = captured
    @program = BytecodeIR.for(irep)
  end

  def run
    reason = refusal
    if reason
      Stats["refused #{reason}"] += 1
      return @original
    end

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

  def transparent?(index)
    @texts[index].each_line.all? { |line| line.strip.empty? || line.lstrip.start_with?('//') }
  end

  # nil when the pass may run, else why not.
  def refusal
    return 'unresolved' unless @program.resolved?
    return 'handlers' if @program.handlers?
    return 'empty' if @insns.empty?
    return 'alias' if @texts.any? { |text| text.match?(/mrb_value\s*&|\[\s*&/) }

    @transparent = @texts.each_index.map { |i| transparent?(i) }
    build_edges
    return 'goto' unless gotos_follow_ir?
    return 'fallthrough' unless terminators_leave?

    nil
  end

  # IR successors plus the text-level fall-through of an instruction that emitted
  # nothing: its jump or return left no code, so control runs into the next text.
  def build_edges
    count = @insns.length
    @succ = Array.new(count) { |i| @program.instruction_at(i).successors.dup }
    count.times do |i|
      @succ[i] << i + 1 if @transparent[i] && i + 1 < count && !@succ[i].include?(i + 1)
    end
    @pred = Array.new(count) { [] }
    @succ.each_with_index { |targets, i| targets.each { |t| @pred[t] << i } }
    @pred[0] << BytecodeIR::ENTRY
  end

  def allowed_goto_addrs(index)
    seen = Set.new
    work = @succ[index].dup
    addrs = Set.new
    until work.empty?
      node = work.pop
      next unless seen.add?(node)

      addrs << @insns[node].addr
      work.concat(@succ[node]) if @transparent[node]
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
    all = mask_of(mentions(text))
    match = CLEAN_DEF.match(text)
    if match && !match[2].match?(/(?<![=!<>])=(?!=)|\b(?:goto|return|throw)\b/)
      [match[1].to_i, mask_of(mentions(match[2])), all]
    else
      [nil, all, all]
    end
  end

  def pure_write?(index)
    op = @insns[index].op
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
        out = pinned_mask
        @succ[i].each { |s| out |= live_in[s] }
        live_out[i] = out
        if dropped.include?(i)
          incoming = out
        else
          kill, reads, = @info[i]
          incoming = reads | (kill ? out & ~(1 << kill) : out)
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
    text = @texts[index]
    name = "r#{reg}"
    return true unless text.match?(/\b#{name}\b/)

    !text.match?(/(?:\+\+|--)\s*#{name}\b|&\s*#{name}\b|\b#{name}\b\s*(?:=(?!=)|[-+*\/%&|^]=|<<=|>>=|\+\+|--|[.\[]|->)|mrb_value\s+#{name}\b/)
  end

  def substitutable?(index, dest, src)
    return false unless self.class.windows? || COPY_READER_OPS.include?(@insns[index].op)
    return false unless readonly?(index, dest) && readonly?(index, src)

    text = @texts[index]
    stripped = text.gsub(/"(?:\\.|[^"\\])*"/, '""').gsub(%r{//[^\n]*}, '').gsub(%r{/\*.*?\*/}m, '')
    text.scan(/\br#{dest}\b/).length == stripped.scan(/\br#{dest}\b/).length
  end

  def substitute(index, dest, src)
    @texts[index] = @texts[index].gsub(/\br#{dest}\b/, "r#{src}")
    @info[index] = info_for(index)
  end
end
