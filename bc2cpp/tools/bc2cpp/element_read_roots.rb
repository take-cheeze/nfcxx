# frozen_string_literal: true

require 'set'
require_relative 'register_flow'

# ELEMENT_READ_ROOTS (docs/bc2cpp-gc-roots.md, "What it does not cover"): the caller side of GC_KEEP_OVERWRITTEN.
# A compiled element read (GETIDX, GETIDX0, AREF) leaves the element in a C local. A by-name callee (a core native
# called by name, a bytecode method) can unlink it from its container; the arena roots that callee set are dropped
# when it returns, so the local becomes the only reference. A read is rooted (bc2cpp_keep, an arena entry) when its
# local is still live after a call that may run code the generator does not model.
#
# Liveness is RegisterFlow's, over the final per-instruction texts and the same CFG (handler edges included), so a
# copy the pass propagated is seen where it is read. A call is any text naming a function outside SAFE_CALLS. A
# refused method (see RegisterFlow#refusal) roots every element read, since its CFG is not trusted.
class ElementReadRoots < RegisterFlow
  ELEMENT_READ_OPS = Set[:GETIDX, :GETIDX0, :AREF].freeze

  # Functions whose text runs no Ruby code and unlinks no element: value constructors and predicates, the element
  # reads themselves, and the compiled Array stores and removals, which root the value they replace or unlink (see
  # bc2cpp_keep_old, bc2cpp_keep_removed) before it can be lost. A Hash key is hashed by its `hash` method, which may
  # run Ruby code, so no Hash function is listed.
  SAFE_CALLS = Set[
    'mrb_fixnum_value', 'mrb_fixnum', 'mrb_integer', 'mrb_integer_value', 'mrb_fixnum_p', 'mrb_integer_p',
    'mrb_float_p', 'mrb_float_value', 'mrb_float', 'mrb_nil_p', 'mrb_nil_value', 'mrb_undef_value',
    'mrb_array_p', 'mrb_hash_p', 'mrb_string_p', 'mrb_range_p', 'mrb_symbol_p', 'mrb_symbol_value', 'mrb_sym',
    'mrb_test', 'mrb_bool_value', 'mrb_immediate_p', 'mrb_obj_ptr', 'mrb_obj_value', 'mrb_ary_ptr',
    'mrb_hash_ptr', 'mrb_str_ptr', 'mrb_ptr', 'mrb_true_value', 'mrb_false_value', 'mrb_bool',
    'mrb_ary_entry', 'mrb_ary_ref', 'RARRAY_LEN', 'RARRAY_PTR', 'ARY_PTR', 'ARY_LEN',
    'bc2cpp_ary_entry', 'bc2cpp_ary_push', 'bc2cpp_ary_set', 'bc2cpp_raw_ary_set', 'bc2cpp_keep_old',
    'bc2cpp_keep_removed', 'bc2cpp_keep', 'bc2cpp_iv_set', 'bc2cpp_gv_set',
    'bc2cpp_mrb_ary_pop', 'bc2cpp_mrb_ary_shift',
    'mrb_ary_pop', 'mrb_ary_shift', 'mrb_ary_set', 'mrb_ary_splice', 'mrb_ary_clear', 'mrb_ary_replace',
    'mrb_ary_push'
  ].freeze

  # C keywords that take a parenthesised condition and are not calls.
  KEYWORDS = Set['if', 'while', 'for', 'switch', 'return', 'sizeof', 'else', 'do'].freeze
  CALL_NAME = /\b([A-Za-z_]\w*)\s*\(/
  # A clean copy of one register into another (a MOVE), the only shape that makes a second holder.
  COPY_DEF = /\A  r(\d+) = r(\d+);\n\z/
  # Comments run nothing. A call's text leads with its `// CLOSED_WORLD ...` comment, which RegisterFlow's definition
  # shape does not see past, so the call would read its own destination as well.
  COMMENT_LINE = %r{^[ \t]*//[^\n]*\n}
  COMMENT_BLOCK = %r{/\*.*?\*/}m

  # The rooting statement for an element read: its dest register, read in the arena.
  def self.keep_text(insn)
    "  bc2cpp_keep(M, r#{insn.regs.first});\n"
  end

  def self.element_read?(insn)
    ELEMENT_READ_OPS.include?(insn.op)
  end

  # The texts with a bc2cpp_keep appended to each element read the liveness test selects.
  def self.apply(irep, texts, captured, handlers: nil)
    program = BytecodeIR.for(irep)
    reads = (0...program.size).select { |i| element_read?(program.source_at(i)) }
    return texts if reads.empty?

    flow = new(irep, texts, captured, handlers)
    rooted = flow.rooted_reads(reads)
    return texts if rooted.empty?

    out = texts.dup
    rooted.each { |i| out[i] = "#{out[i]}#{keep_text(program.source_at(i))}" }
    out
  end

  # The element reads whose value is still held in a register that is live across a call. Every read when the CFG
  # is refused.
  def rooted_reads(reads)
    return reads if refusal

    scan
    live_out = live_out_sets(Set.new)
    reads.select { |index| rooted?(index, live_out) }
  end

  private

  # Walks the paths from the read at +index+, carrying the set of registers that hold its element (a mask): a clean
  # copy `rX = rY` from a holder adds X, a clean write removes its register. At a call, the holders it reads (its
  # receiver and arguments, which the callee holds in C locals) or that are live after it are at risk: the callee
  # may unlink the element and then use it, so the read is rooted. A handler edge leaves before the write completes,
  # so it carries the mask from before the write.
  def rooted?(index, live_out)
    mask = 1 << @program.source_at(index).regs.first.to_i
    seen = Set.new
    stack = @normal_succ[index].map { |s| [s, mask] } + @handler_succ[index].map { |s| [s, mask] }
    until stack.empty?
      node, held = stack.pop
      next if held.zero? || !seen.add?([node, held])
      return true if call?(node) && root_at_call?(node, held, live_out)

      after = holders_after(node, held)
      stack.concat(@normal_succ[node].map { |s| [s, after] })
      stack.concat(@handler_succ[node].map { |s| [s, held] })
    end
    false
  end

  # The holders a call keeps at risk: those it reads (its receiver and arguments, held in C locals while it runs) and
  # those live after it. The register the call overwrites is not live after it, unless a handler edge leaves before
  # the overwrite, so it is then kept.
  def root_at_call?(node, held, live_out)
    kill, reads = effect(node)
    overwritten = kill && @handler_succ[node].empty? ? 1 << kill : 0
    (((live_out[node] & ~overwritten) | reads) & held) != 0
  end

  def holders_after(node, held)
    copy = COPY_DEF.match(effect_text(node))
    if copy
      dest = 1 << copy[1].to_i
      return (held >> copy[2].to_i).odd? ? held | dest : held & ~dest
    end
    kill, = effect(node)
    kill ? held & ~(1 << kill) : held
  end

  # The node's text without its comments.
  def effect_text(node)
    @effect_texts ||= {}
    @effect_texts[node] ||= @texts[node].gsub(COMMENT_LINE, '').gsub(COMMENT_BLOCK, '')
  end

  # [the register the node cleanly defines or nil, the registers it reads], by RegisterFlow's definition shape.
  def effect(node)
    text = effect_text(node)
    match = CLEAN_DEF.match(text)
    if match && !match[2].match?(/(?<![=!<>])=(?!=)|\b(?:goto|return|throw)\b/)
      [match[1].to_i, mention_mask(match[2])]
    elsif (insn = @program.source_at(node)) && self.class.element_read?(insn)
      # An element read writes its destination on every branch, after the receiver and key it reads (the receiver may
      # be the destination itself, so every mention counts as a read).
      [insn.regs.first.to_i, mention_mask(text)]
    else
      [nil, mention_mask(text)]
    end
  end

  def call?(node)
    self.class.calls?(@texts[node])
  end

  # Whether generated text (comments aside) names a function the rule does not know to be safe.
  def self.calls?(text)
    text.gsub(COMMENT_LINE, '').gsub(COMMENT_BLOCK, '').scan(CALL_NAME) do |(name)|
      next if KEYWORDS.include?(name) || SAFE_CALLS.include?(name)

      return true
    end
    false
  end

  # The rooting lines for the block parameters +regs+ an inlined loop over a live Array binds to an element, emitted
  # before the body. Every iteration reads its element again, so the rooting is per iteration; it is needed only when
  # the body may call, since only a call can unlink the element while the parameter still holds it.
  def self.loop_keep(body, regs)
    return '' unless calls?(body)

    regs.map { |reg| "      bc2cpp_keep(M, r#{reg});\n" }.join
  end
end
