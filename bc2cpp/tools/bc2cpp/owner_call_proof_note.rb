# frozen_string_literal: true

require_relative 'bytecode_ir'

# Debug note: with BC2CPP_OWNER_CALL_PROOF_NOTE=1, a `/* OWNER_CALL_PROOF ... */` line goes ahead of every owner call a
# send or another instruction emits, naming the site and what the class flow (`mask`), NumericFlow (`num`) and the
# exact-site proof (`exact`) say about the receiver. A probe compile's code is thrown away with its notes, so the
# shipped sources list exactly the owner calls that remain; scripts/bc2cpp/owner_call_proof_rows.rb reads them back.
# Only comments change, but the shard split weighs the text, so methods may land in other shards.
module OwnerCallProofNote
  MARK = 'OWNER_CALL_PROOF'

  def compile_send(insn, kwargs)
    code = super
    return code unless code.is_a?(String) && code.include?('CLOSED_WORLD owner-call: ')

    owner_call_annotate(code, insn.sym.to_s, owner_call_send_note(insn, kwargs))
  end

  # An owner call an instruction other than a send emits (string interpolation, an inlined loop): its registers.
  def compile_insn(insn, irep, owner_def, idx = nil, reg_offset = 0)
    code = super
    return code unless code.is_a?(String) && code.include?('CLOSED_WORLD owner-call: ') && irep && idx

    masks = Array(insn.regs).uniq.map { |reg| "R#{reg}:#{owner_call_mask_text(exact_flow_mask(irep, idx, reg))}" }
    owner_call_annotate(code, nil, "op=#{insn.op} in=#{owner_call_note_owner(owner_def)} regs=#{masks.join(',')} " \
                                   "at=#{owner_call_note_where(irep, insn.lineno)}")
  end

  private

  # A line of its own: the passes after this one match the call line itself up to its `*/` at the end.
  def owner_call_annotate(code, name, note)
    code.gsub(%r{^([ \t]*)(.*/\* CLOSED_WORLD owner-call: (\S+) \*/)$}) do
      indent, line, called = Regexp.last_match.captures
      fresh = (name.nil? || called == name) && !owner_call_noted?(code, Regexp.last_match.begin(0))
      fresh ? "#{indent}/* #{MARK} #{note.gsub('*/', '* /')} */\n#{indent}#{line}" : "#{indent}#{line}"
    end
  end

  def owner_call_noted?(code, line_start)
    return false unless line_start.positive?

    previous = code.rindex("\n", line_start - 2)
    code[(previous ? previous + 1 : 0)...line_start].include?(MARK)
  end

  def owner_call_send_note(insn, kwargs)
    irep = kwargs[:irep]
    site = kwargs[:idx] || kwargs[:trace_idx]
    return "name=#{insn.sym} mask=-" unless irep && site

    self_implicit = kwargs[:self_implicit]
    reg = self_implicit ? 0 : unshift_proof_reg(kwargs[:trace_receiver_reg] || insn.reg, kwargs[:trace_reg_offset] || 0)
    owner_def = kwargs[:owner_def]
    num = numeric_raw_mask(irep, site, reg, owner_def)
    exact = !self_implicit && exact_core_value_class(irep, site, reg)
    "name=#{insn.sym} in=#{owner_call_note_owner(owner_def)} self=#{self_implicit ? 1 : 0} argc=#{insn.argc || 0} " \
      "mask=#{owner_call_mask_text(exact_flow_mask(irep, site, reg))} num=#{num ? numeric_mask_name(num) : '-'} " \
      "exact=#{exact || '-'} at=#{owner_call_note_where(irep, BytecodeIR.for(irep).source_at(site)&.lineno)}"
  end

  def owner_call_mask_text(mask)
    return 'unmodelled' if mask.nil?

    class_mask_name(mask) + ((mask & NumericFlow::OTHER).zero? ? '' : '+OTHER')
  end

  def owner_call_note_owner(owner_def)
    owner_def ? "#{owner_def.owner}##{owner_def.name}" : '-'
  end

  def owner_call_note_where(irep, line)
    "#{irep.file.to_s.sub(%r{.*/(mruby-)}, '\\1')}:#{line}"
  end
end

CodeGen.prepend(OwnerCallProofNote)
