# frozen_string_literal: true

require_relative 'register_flow'
require_relative 'callee_arena'

# LOOP_ARENA: a bytecode loop of a compiled method gives back, at each backward jump, the GC arena entries its
# iteration made, as the interpreter's per-instruction restores do. A loop that calls a direct callee per element
# (`draw_event ordered[i]`, whose element read is rooted) otherwise keeps one entry per iteration until the method
# returns (CALLEE_ARENA).
#
# The loop's header saves the arena index when it is entered from outside (`bc2cpp_lb_J` is false); a backward jump
# sets it and drops the arena back to that index, keeping the store roots recorded above it (bc2cpp_arena_back, as
# bc2cpp_arena_exit does), then roots every register live out of the jump again. Sound because a value the method can
# still read after the jump is in a register live there (RegisterFlow's liveness, handler edges included), in a slot
# or object it reached, or rooted below the header's index; a callee holds nothing at a jump of its caller. Refused
# where something other than a register holds a value: a method RegisterFlow refuses, one with handlers or captured
# registers, and one that declares any other mrb_value local (a placed tuple, a buffer; an instruction's own scoped
# temporary is not one). BC2CPP_LOOP_ARENA=0 (or BC2CPP_CALLEE_ARENA=0) leaves every loop alone.
class LoopArena < RegisterFlow
  # The names a method's own mrb_value locals may have: its registers, self and the parameters.
  OWN_LOCAL = /\A(?:r\d+|self)\z/

  def self.on?
    CalleeArena.on? && ENV['BC2CPP_LOOP_ARENA'] != '0'
  end

  # [texts, declarations]: the per-instruction texts with the header and jump code added, and the locals they use
  # (to declare ahead of the first label). `prologue` is the method's text from its head to its first instruction.
  def self.apply(irep, texts, captured, prologue)
    return [texts, ''] unless on? && captured&.empty?
    return [texts, ''] if BytecodeIR.for(irep).handlers?

    params = prologue[/\A[^\n]*?\(([^()]*)\) \{\n/, 1]&.split(',')&.map { |p| p.strip[/(\w+)\z/, 1] }
    return [texts, ''] unless params
    return [texts, ''] if foreign_locals?(prologue.sub(/\A[^\n]*\n/, ''), params)
    return [texts, ''] if texts.any? { |t| foreign_locals?(t, params) }

    new(irep, texts, captured).place
  end

  # The numeric ops' temporary (`{ mrb_value bc2cpp_nt; ... }`, codegen_insn.rb and cmp_num_outline.rb), a yield's
  # argument buffer (`{ mrb_value blkcall_args[] = { r1, r2 }; ... }`, OP_BLKCALL) and an Array literal's elements
  # (`{ mrb_value elems[] = { r1, r2 }; ... }`, OP_ARRAY) are scoped to their own instruction's text, so they hold
  # nothing at a backward jump.
  SCOPED_TEMP = /\{\s*mrb_value (?:bc2cpp_nt;|blkcall_args\[\] =|elems\[\] =)/

  def self.foreign_locals?(text, params)
    text.gsub(SCOPED_TEMP, '{').scan(/\bmrb_value\s*(\*?)\s*([A-Za-z_]\w*)\s*(\[?)/).any? do |star, name, bracket|
      !star.empty? || !bracket.empty? || !(name.match?(OWN_LOCAL) || params.include?(name))
    end
  end

  def place
    return [@original, ''] if refusal

    scan
    live_out = live_out_sets(Set.new)
    jumps = (0...@insns.length).filter_map do |i|
      back = @normal_succ[i].select { |j| j <= i }
      [i, back.first] unless back.empty?
    end
    return [@original, ''] if jumps.empty?
    # Each backward edge is one goto in its jump's own text, so the code placed ahead of it runs only on that way.
    return [@original, ''] unless jumps.all? do |i, j|
      @normal_succ[i].count { |t| t <= i } == 1 && @original[i].include?("goto L#{@insns[j].addr};")
    end

    out = @original.dup
    headers = jumps.flat_map(&:last).uniq.sort
    headers.each do |j|
      out[j] = "  if (!bc2cpp_lb_#{j}) bc2cpp_la_#{j} = M->gc.arena_idx;\n  bc2cpp_lb_#{j} = false;\n#{out[j]}"
    end
    jumps.each do |i, j|
      # A conditional jump may fall through out of the loop: the arena is dropped on both ways, so both ways' live
      # registers are rooted again (live_out).
      roots = (1...@irep.nregs).select { |reg| live_out[i][reg] == 1 }
      text = +"  bc2cpp_lb_#{j} = true;\n  bc2cpp_arena_back(M, bc2cpp_la_#{j});\n"
      roots.each { |reg| text << "  bc2cpp_loop_root(r#{reg}, M);\n" }
      out[i] = "#{text}#{out[i]}"
    end
    decls = headers.map { |j| "  int bc2cpp_la_#{j} = 0;\n  bool bc2cpp_lb_#{j} = false;\n" }.join
    [out, decls]
  end
end
