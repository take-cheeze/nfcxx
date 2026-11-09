# frozen_string_literal: true

# CHECKED_SEND: the by-name call of a real SEND / SSEND instruction is an mrb_funcall,
# which skips two checks the VM makes for that instruction: an explicit-receiver OP_SEND raises
# NoMethodError for a private method, or a protected one unless the caller's self is a kind_of its class or module
# (SymbolCache passes `self` to those calls), and both opcodes raise ArgumentError for an
# attr_reader called with arguments. This marks the call so SymbolCache gives it a slot that
# bc2cpp_send checks (symbol_cache.rb, CHECKED_SEND); the direct, guarded and exact-class arms
# are not by name and keep their own checks.
#
# Only a site that is the original instruction is marked: an operator fallback (OP_ADD's slow
# path is not an OP_SEND, so mruby checks no visibility there), an inlined loop body and a
# synthetic send keep the plain call.
module CheckedSend
  EXPLICIT_OPS = %i[SEND SEND0].freeze
  IMPLICIT_OPS = %i[SSEND SSEND0].freeze

  def compile_send(insn, kwargs)
    code = super
    level = checked_send_level(insn, kwargs)
    return code unless level

    recv = kwargs[:self_implicit] ? 'self' : "r#{insn.reg}"
    if code.include?('mrb_funcall(M, ')
      head = "(M, #{recv}, \"#{insn.sym}\","
      marker = level == :explicit ? 'bc2cpp_funcall_explicit' : 'bc2cpp_funcall_noarg'
      code = replace_call_head(code, "mrb_funcall#{head}", "#{marker}#{head}")
    end
    # OUTSIDE_OWNER_CALL: the checked owner call takes the same level as an argument; so does the splat form over
    # the Array's items, or `o.private_m(*a)` and `proc_subclass.call(*a)` would skip the visibility check.
    if insn.positional_splat? && level == :explicit
      code = code.gsub(/(\bbc2cpp_funcall_argv\(M, #{Regexp.escape(recv)}, mrb_intern_\w+\(M, "#{Regexp.escape(insn.sym)}"\), ary_size\([^()]*\), ary_items\([^()]*\))\)/) { "#{$1}, true, self)" }
    end
    %w[bc2cpp_owner_call_named bc2cpp_owner_call_argv_named].each do |callee|
      next unless code.include?("#{callee}(M, ")

      head = "#{callee}(M, #{recv}, \"#{insn.sym}\","
      code = replace_call_head(code, "#{head} 0,", "#{head} #{level == :explicit ? 2 : 1},")
    end
    code
  end

  private

  # Replaces each `from` that starts an identifier, like gsub(/\bfrom/) but without a per-site Regexp, MatchData or
  # copy when nothing matches. A non-ASCII byte before a candidate defers to the Regexp, whose \b is Unicode-aware.
  def replace_call_head(code, from, to)
    pos = code.byteindex(from)
    return code unless pos

    out = nil
    start = 0
    while pos
      prev = pos.zero? ? nil : code.getbyte(pos - 1)
      return code.gsub(/\b#{Regexp.escape(from)}/) { to } if prev && prev >= 0x80

      if prev && ascii_word_byte?(prev)
        pos = code.byteindex(from, pos + 1)
      else
        (out ||= String.new(encoding: code.encoding)) << code.byteslice(start, pos - start) << to
        start = pos + from.bytesize
        pos = code.byteindex(from, start)
      end
    end
    return code unless out

    out << code.byteslice(start, code.bytesize - start)
  end

  def ascii_word_byte?(byte)
    byte == 95 || (byte >= 48 && byte <= 57) || (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122)
  end

  # :explicit, :noarg, or nil when this call keeps the plain mrb_funcall.
  def checked_send_level(insn, kwargs)
    irep = kwargs[:irep]
    idx = kwargs[:idx]
    return nil if @class_body_unit
    return nil unless irep && idx && insn.sym && kwargs[:call_receiver].nil? && kwargs[:call_arguments].nil?
    return nil if insn.keyword_arguments?
    return nil if insn.positional_splat? && kwargs[:self_implicit]

    original = BytecodeIR.for(irep).source_at(idx)
    return nil unless original && original.op == insn.op && original.sym == insn.sym

    if EXPLICIT_OPS.include?(insn.op) && !kwargs[:self_implicit]
      :explicit
    elsif IMPLICIT_OPS.include?(insn.op) && kwargs[:self_implicit] && insn.argc.to_i.positive? &&
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
