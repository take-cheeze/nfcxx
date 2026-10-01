# frozen_string_literal: true

# CHECKED_SEND (ADR 0299): the by-name call of a real SEND / SSEND instruction is an mrb_funcall,
# which skips two checks the VM makes for that instruction: an explicit-receiver OP_SEND raises
# NoMethodError for a private or protected method, and both opcodes raise ArgumentError for an
# attr_reader called with arguments. This marks the call so SymbolCache gives it a slot that
# bc2cpp_send checks (symbol_cache.rb, CHECKED_SEND); the direct, guarded and exact-class arms
# are not by name and keep their own checks (ADR 0297).
#
# Only a site that is the original instruction is marked: an operator fallback (OP_ADD's slow
# path is not an OP_SEND, so mruby checks no visibility there), an inlined loop body and a
# synthetic send keep the plain call.
module CheckedSend
  EXPLICIT_OPS = %w[SEND SEND0].freeze
  IMPLICIT_OPS = %w[SSEND SSEND0].freeze

  def compile_send(insn, **kwargs)
    code = super
    level = checked_send_level(insn, kwargs)
    return code unless level

    recv = kwargs[:self_implicit] ? 'self' : "r#{insn.reg}"
    marker = level == :explicit ? 'bc2cpp_funcall_explicit' : 'bc2cpp_funcall_noarg'
    code.gsub(/\bmrb_funcall\(M, #{Regexp.escape(recv)}, "#{Regexp.escape(insn.sym)}",/) do
      "#{marker}(M, #{recv}, \"#{insn.sym}\","
    end
  end

  private

  # :explicit, :noarg, or nil when this call keeps the plain mrb_funcall.
  def checked_send_level(insn, kwargs)
    irep = kwargs[:irep]
    idx = kwargs[:idx]
    return nil unless irep && idx && insn.sym && kwargs[:call_receiver].nil? && kwargs[:call_arguments].nil?
    return nil if insn.n_spec == '*' || insn.nk_spec

    original = irep.instructions[idx]
    return nil unless original && original.op == insn.op && original.sym == insn.sym

    if EXPLICIT_OPS.include?(insn.op) && !kwargs[:self_implicit]
      :explicit
    elsif IMPLICIT_OPS.include?(insn.op) && kwargs[:self_implicit] && insn.n_spec.to_i.positive? &&
          attr_reader_name?(insn.sym)
      :noarg
    end
  end

  # A name some attr_reader (or an accessor pair's reader) defines; only those are NOARG procs.
  def attr_reader_name?(name)
    @attr_reader_names ||= @registry.each_with_object(Set.new) do |(key, defs), names|
      names << key if !key.end_with?('=') && defs.any? { |d| d.kind == :ivar_accessor && d.irep.nil? }
    end
    @attr_reader_names.include?(name)
  end
end

CodeGen.prepend(CheckedSend)
