# frozen_string_literal: true

require 'set'
require_relative 'element_read_roots'

# ELEMENT_READ_BODIES (docs/bc2cpp-gc-roots.md): ElementReadRoots' liveness test over a body compiled outside
# compile_method's own pass: a block that stays a function, a rescue's try body, an inlined loop body. Each body is
# the per-instruction texts of its irep's instructions in +nodes+; control that leaves the body goes to one of two
# virtual nodes:
#   QUIET  leaves without running more code that can see the body's registers, other than registers in +quiet_live+
#          that something roots again on the way out (a try body's alias registers and result, re-rooted by its glue).
#          It is not a call: a holder reaching it needs no root.
#   LOUD   leaves into code that can call while the registers in +loud_live+ (the enclosing function's) still hold the
#          element, or carries the element out in a variable no register analysis follows (a loop body's result, a
#          thrown value). A holder live there, or mentioned by the text that leaves, is rooted.
# Anything the CFG cannot place (a goto to a label it does not know, a catch handler inside the body, an address-taken
# alias) refuses the body, which then roots every read. BC2CPP_ELEMENT_READ_BODIES=0 roots every read in these bodies.
class ElementReadBodyRoots < ElementReadRoots
  def self.enabled?
    ENV['BC2CPP_ELEMENT_READ_BODIES'] != '0'
  end

  # +texts+: index-aligned with the irep's instructions. +nodes+: the indices the body emits (all when nil). +reads+:
  # the element reads it claimed (element_read_owned). +offset+: the register shift of a shifted body. +pinned+:
  # registers live everywhere (the enclosing function's, a nested block's captures). +labels+: label name => :quiet or
  # :loud for the gotos that leave the body; +prefix+ spells the body's own instruction labels. +returns+: what a
  # `return` text leaves to (:quiet or :loud), +quiet_returns+ the indices whose bare `return` is QUIET regardless.
  # +handler_exit+: the [begin, end) address range of the one handler every node may raise to QUIET through (a try
  # body). +loop_entry+: LOUD continues there (the next iteration).
  def initialize(irep, texts, reads:, nodes: nil, offset: 0, pinned: [], labels: {}, prefix: 'L', returns: :quiet,
                 quiet_returns: [], quiet_live: [], loud_live: [], handler_exit: nil, loop_entry: nil)
    super(irep, texts, pinned)
    @nodes = nodes ? nodes.to_set : (0...@insns.length).to_set
    @reads = reads
    @offset = offset
    @labels = labels
    @prefix = prefix
    @returns = returns
    @quiet_returns = quiet_returns.to_set
    @quiet_mask = mask_of(quiet_live)
    @loud_mask = mask_of(loud_live)
    @handler_exit = handler_exit
    @loop_entry = loop_entry
    @count = @insns.length
    @quiet = @count
    @loud = @count + 1
    @texts += ['', '']
  end

  # {read index => nil or [risky names, handler]} for the claimed reads to root; nil when the body is refused.
  def rooted_body_reads
    return nil if body_refusal

    scan
    @info[@quiet] = [nil, @quiet_mask, @quiet_mask]
    @info[@loud] = [nil, @loud_mask, @loud_mask]
    live_out = body_live_out
    @reads.each_with_object({}) do |index, out|
      risk = body_rooted?(index, live_out)
      out[index] = risk.is_a?(Array) ? risk : nil if risk
    end
  end

  # The texts with a bc2cpp_keep appended to each claimed read that needs one: every claimed read when refused, or when
  # +pinned+ is nil (the captured registers are not known).
  def self.root(irep, texts, reads, **opts)
    return texts if reads.empty?

    flow = enabled? && !opts[:pinned].nil? && new(irep, texts, reads: reads, **opts)
    rooted = flow ? flow.rooted_body_reads : nil
    rooted ||= reads.to_h { |i| [i, nil] }
    program = BytecodeIR.for(irep)
    offset = opts.fetch(:offset, 0)
    out = texts.dup
    rooted.each do |i, risk|
      out[i] = "#{out[i]}#{keep_line("r#{program.source_at(i).regs.first.to_i + offset}", risk, '  ')}"
    end
    out
  end

  private

  def body_refusal
    return 'unresolved' unless @program.resolved?
    return 'empty' if @insns.empty?
    return 'alias' if @texts.any? { |text| text.match?(/mrb_value\s*&|\[\s*&/) }
    return 'handlers' unless own_handler_only?

    @transparent = @texts.each_index.map { |i| transparent?(i) }
    return 'goto' unless build_body_edges
    return 'fallthrough' unless terminators_leave?

    nil
  end

  # No handler starts or ends inside the body (a nested rescue, an ensure): one that protects a node protects the
  # whole range a try body stands for (+handler_exit+), which bc2cpp_protect turns into the QUIET exit.
  def own_handler_only?
    return true unless @program.handlers?
    return false unless @handler_exit

    first, last = @handler_exit
    addrs = @nodes.map { |i| @insns[i].addr }
    @program.catch_handlers.all? do |h|
      addrs.none? { |a| a >= h.begin_addr && a < h.end_addr } || (h.begin_addr <= first && last <= h.end_addr)
    end
  end

  # The IR's normal edges inside the body, the fall-through of a text that emitted nothing, and an edge to QUIET or
  # LOUD for every way out. False when a text's goto has a target this cannot place.
  def build_body_edges
    total = @count + 2
    @normal_succ = Array.new(total) { [] }
    @handler_succ = Array.new(total, NO_EDGES)
    @nodes.each do |i|
      text = @texts[i]
      succ = if BARE_RETURN.match?(effect_text(i))
               [@quiet_returns.include?(i) || @returns == :quiet ? @quiet : @loud]
             else
               body_successors(i)
             end
      return false unless body_gotos(i, text, succ)

      if effect_text(i).match?(/\bthrow\b/)
        succ << @loud
      elsif effect_text(i).match?(/\breturn\b/)
        succ << (@returns == :loud ? @loud : @quiet)
      end
      @normal_succ[i] = succ.uniq
      @handler_succ[i] = [@quiet] if @handler_exit
    end
    @normal_succ[@loud] = [@loop_entry] if @loop_entry
    true
  end

  BARE_RETURN = /\A[ \t]*return\b[^;\n]*;\n\z/

  # The IR's successors inside the body, the fall-through of a text that emitted nothing, and LOUD for one outside it
  # or for falling off the body's last node.
  def body_successors(index)
    succ = @program.instruction_at(index).successors.dup
    succ << (index + 1) if @transparent[index] && !succ.include?(index + 1)
    succ.map { |s| @nodes.include?(s) ? s : @loud }
  end

  # Adds the exits +text+'s gotos take to +succ+. A body label must be one the IR's successors reach through texts
  # that emitted nothing (allowed_goto_addrs), as RegisterFlow requires of a method.
  def body_gotos(index, text, succ)
    return true unless text.include?('goto')

    targets = text.scan(/\bgoto\s+(\w+)\s*;/).flatten
    return false if text.scan(/\bgoto\b/).length != targets.length

    allowed = nil
    label = /\A#{Regexp.escape(@prefix)}(\d+)\z/
    targets.all? do |name|
      next true if text.match?(/^\s*#{Regexp.escape(name)}\s*:/)

      if (kind = @labels[name])
        succ << (kind == :loud ? @loud : @quiet)
        next true
      end
      match = label.match(name)
      match && (allowed ||= body_allowed_goto_addrs(index)).include?(match[1].to_i)
    end
  end

  def body_allowed_goto_addrs(index)
    seen = Set.new
    work = @program.instruction_at(index).successors.dup
    addrs = Set.new
    until work.empty?
      node = work.pop
      next unless seen.add?(node)

      addrs << @insns[node].addr
      work.concat(@program.instruction_at(node).successors) if @transparent[node]
    end
    addrs
  end

  # RegisterFlow#live_out_sets over the body's nodes and the two exits.
  def body_live_out
    total = @count + 2
    live_in = Array.new(total, 0)
    live_out = Array.new(total, 0)
    pinned_mask = mask_of(@pinned.to_a)
    changed = true
    while changed
      changed = false
      (total - 1).downto(0) do |i|
        normal_out = pinned_mask
        @normal_succ[i].each { |s| normal_out |= live_in[s] }
        handler_out = 0
        @handler_succ[i].each { |s| handler_out |= live_in[s] }
        live_out[i] = normal_out | handler_out
        kill, reads, = @info[i]
        incoming = reads | (kill ? normal_out & ~(1 << kill) : normal_out) | handler_out
        next if incoming == live_in[i]

        live_in[i] = incoming
        changed = true
      end
    end
    live_out
  end

  # ElementReadRoots#rooted? with the exits: reaching LOUD with a holder it keeps live, or leaving through a text that
  # mentions a holder, roots the read outright (the code after it is not known). QUIET ends the path.
  def body_rooted?(index, live_out)
    mask = 1 << (@program.source_at(index).regs.first.to_i + @offset)
    seen = Set.new
    callees = Set.new
    summary = self.class.summary_on?
    handler = @handler_exit || @loop_entry || @returns == :loud
    stack = @normal_succ[index].map { |s| [s, mask] } + @handler_succ[index].map { |s| [s, mask] }
    until stack.empty?
      node, held = stack.pop
      next if held.zero? || !seen.add?([node, held])
      next if node == @quiet
      return true if node == @loud && ((live_out[@loud] | @loud_mask) & held) != 0
      next if node == @loud
      return true if @normal_succ[node].include?(@loud) && (mention_mask(effect_text(node)) & held) != 0

      if call?(node) && root_at_call?(node, held, live_out)
        return true unless summary

        callees.merge(self.class.risky_names(@texts[node]))
      end

      after = holders_after(node, held)
      stack.concat(@normal_succ[node].map { |s| [s, after] })
      stack.concat(@handler_succ[node].map { |s| [s, held] })
    end
    callees.empty? ? false : [callees, handler]
  end
end
