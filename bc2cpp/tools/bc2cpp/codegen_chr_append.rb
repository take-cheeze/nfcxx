# frozen_string_literal: true

require 'set'
require_relative 'bytecode_ir'

# CHR_APPEND: `str << n.chr` appends the byte n to an exact String when n is an Integer from 0 to 255, and builds no
# one-character String for it. Without it every byte costs an owner-call lookup for `chr`, a one-byte String that is
# dead on the next instruction, and a slow-path dispatch for `<<` on a String receiver.
#
# Integer#chr with no argument is int_chr_binary (mruby-string-ext): one byte for 0..255, RangeError otherwise, in
# every build. String#<< with a String argument ends in mrb_str_cat(str, ptr, len) (mrb_str_concat, mrb_str_cat_str),
# which mrb_str_cat of the one byte repeats call for call, the frozen check included.
#
# A (SEND0 chr, SEND << with one argument) pair is rewritten when all of these hold; any doubt keeps both instructions:
#   shape      the SEND follows the chr, appends R(b) to R(a) where R(b) is the chr's register (b == a + 1), and is
#              reached only from the chr
#   dead       no other instruction reads R(b) with the chr as a reaching definition, so the String is never needed
#   builtins   no Ruby definition shadows Integer#chr or String#<< (builtin_class_send_safe?)
# The fast path runs only when R(a) is exactly a String (its class is M->string_class) and R(b) is an Integer from 0
# to 255; any other value, including an out-of-range Integer (the RangeError), a frozen String (the FrozenError)
# and an Array receiver, runs the original two instructions.
#
# The chr and the append are separate instructions that one emitter compiles one after the other, so the chr is
# suppressed and the append carries both. The method counts each half (per instruction and register offset); a count
# that differs, from an emitter that skips one of them, recompiles the method without the rewrite. An inlined block body
# arrives with shifted registers and the offset, which the rewrite follows. BC2CPP_CHR_APPEND=0 turns it off.
class CodeGen
  def chr_append_enabled?
    ENV['BC2CPP_CHR_APPEND'] != '0'
  end

  # The instruction indexes of +irep+ the rewrite touches: { chr index => :chr, append index => :append }.
  def chr_append_plan(irep)
    @chr_append_plans ||= {}
    @chr_append_plans[irep.label] ||= compute_chr_append_plan(irep)
  end

  # Called by compile_method's wrapper: the counters of the method being compiled, nil outside one.
  attr_accessor :chr_append_state

  private

  def compute_chr_append_plan(irep)
    return {} unless chr_append_enabled?
    return {} unless builtin_class_send_safe?('chr', ['Integer']) && builtin_class_send_safe?('<<', ['String'])

    prog = BytecodeIR.for(irep)
    return {} unless prog.resolved? && prog.handlers_resolved?

    params = stack_tuple_params(irep)
    plan = {}
    prog.each_source do |insn, idx|
      next unless insn.op == :SEND0 && insn.sym == 'chr'

      append = idx + 1 < prog.size ? prog.source_at(idx + 1) : nil
      next unless append && append.op == :SEND && append.sym == '<<' && append.plain_fixed_argc? &&
                  append.argc.to_i == 1 && !append.keyword_arguments?

      b = reg_int(insn.reg)
      a = reg_int(append.reg)
      next unless a && b && b == a + 1
      next unless string_eq_only_predecessor?(prog, idx)
      next unless string_eq_literal_dead_after?(irep, prog, idx, b, params)

      plan[idx] = :chr
      plan[idx + 1] = :append
    end
    plan
  end

  def chr_append_text(a, b, chr_text, append_text)
    head = [
      "  // CHR_APPEND: r#{a} << r#{b}.chr appends the byte of an exact String when r#{b} is an Integer from 0 to 255, ",
      "and builds no one-character String\n",
      "  {\n",
      "    mrb_value bc2cpp_ca = r#{a};\n",
      "    if (mrb_string_p(bc2cpp_ca) && mrb_obj_ptr(bc2cpp_ca)->c == M->string_class && mrb_integer_p(r#{b}) &&\n",
      "        mrb_integer(r#{b}) >= 0 && mrb_integer(r#{b}) <= 255) {\n",
      "      char bc2cpp_ch = (char)mrb_integer(r#{b});\n",
      "      mrb_str_cat(M, bc2cpp_ca, &bc2cpp_ch, 1);\n",
      "    } else {\n"
    ]
    body = (chr_text + append_text).lines.map { |line| "  #{line}" }
    (head + body + ["    }\n", "  }\n"]).join
  end
end

# Prepended to CodeGen: counts the halves of each rewrite in one method and recompiles it without the rewrite when
# they do not match.
module ChrAppendCompileMethod
  def compile_method(label)
    return super unless chr_append_enabled?
    return super if chr_append_state

    @chr_append_off ||= Set.new
    return super if @chr_append_off.include?(label)

    state = { chr: Hash.new(0), append: Hash.new(0) }
    self.chr_append_state = state
    text = begin
      super
    ensure
      self.chr_append_state = nil
    end
    return text if state[:chr] == state[:append]

    warn "bc2cpp CHR_APPEND: #{label} compiled one half of a rewrite without the other; recompiled without it" if ENV['BC2CPP_CHR_APPEND_REPORT'] == '1'
    @chr_append_off << label
    super
  end
end

# Prepended to CodeGen, outermost: the chr of a planned pair emits a comment only, and the append emits both.
module ChrAppendCompileInsn
  def compile_insn(insn, irep, owner_def, idx = nil, reg_offset = 0)
    state = chr_append_state
    return super unless state && idx && !@resumable

    kind = chr_append_plan(irep)[idx]
    return super unless kind

    pair = kind == :chr ? idx : idx - 1
    key = [irep.label, pair, reg_offset]
    if kind == :chr
      state[:chr][key] += 1
      return "  // CHR_APPEND: the chr of the append below builds no String\n"
    end

    state[:append][key] += 1
    # A shifted body hands over the instruction with its registers already shifted (compile_shifted_body_insn), so the
    # append's own register is the shifted one and the chr is shifted the same way.
    chr_insn = BytecodeIR.for(irep).source_at(idx - 1)
    chr_insn = chr_insn.shift_regs(reg_offset) unless reg_offset.zero?
    a = reg_int(insn.reg)
    chr_text = super(chr_insn, irep, owner_def, idx - 1, reg_offset)
    append_text = super(insn, irep, owner_def, idx, reg_offset)
    chr_append_text(a, a + 1, chr_text, append_text)
  end
end

CodeGen.prepend(ChrAppendCompileMethod)
CodeGen.prepend(ChrAppendCompileInsn)
