# frozen_string_literal: true

# CodeGen: the Integer-tag test on a native entry point's :int argument (ADR 0318).
#
# `Bitmap.new(w, h)` and the NativeDirect entries whose kinds say :int test `mrb_integer_p` on every such argument and
# keep the by-name send as the else. This file answers the question every site asks, "is this register provably a
# Fixnum here", and, behind BC2CPP_NATIVE_INT_ARGS=<file>, writes why the answer is no (a read-only probe: the generated
# code is byte-identical with it on).
module NativeIntArgs
  # One table for every CodeGen of the run, written once at exit (the last compile of a site wins).
  def self.lines
    @lines ||= {}.tap do |lines|
      at_exit { File.write(ENV.fetch('BC2CPP_NATIVE_INT_ARGS'), "#{lines.values.join("\n")}\n") }
    end
  end

  # BC2CPP_NUMERIC_CONSTANTS=0 restores master's tag tests.
  def native_int_args_on?
    ENV['BC2CPP_NUMERIC_CONSTANTS'] != '0'
  end

  # True when argument +position+ of the call is a register the Fixnum proof covers at the call.
  # +legacy+: the caller already used the Fixnum proof before ADR 0318 (the exact-flow arm), which the kill switch keeps.
  def native_int_arg_proven?(irep, proof_idx, owner_def, reg_offset, argv, position, legacy: false)
    on = native_int_args_on? && static_constant_world?
    return false unless on || legacy

    reg = argv[position].to_s[/\Ar(\d+)\z/, 1]
    return false unless reg

    shifted = unshift_proof_reg(reg.to_i, reg_offset)
    return false if shifted.nil?

    return proven_fixnum_operand?(irep, proof_idx, shifted.to_s, owner_def) unless on
    return true if fixnum_interval(irep, proof_idx, shifted.to_s, owner_def)

    # A constant leaf is the interval's to prove: INTEGER_CONSTANT_PROOF's name scan misses a native definition
    # (ADR 0318), so it does not vouch for one here.
    @fixnum_proof_skip_constants = true
    begin
      proven_fixnum_operand?(irep, proof_idx, shifted.to_s, owner_def)
    ensure
      @fixnum_proof_skip_constants = false
    end
  end

  # One NINT line per :int argument the Fixnum proof does not cover: the writer it comes from and the leaves behind it.
  def native_int_arg_probe(site, irep, proof_idx, owner_def, reg_offset, argv)
    return unless ENV['SKIP_UNSUPPORTED'] == '1' && irep && proof_idx && owner_def

    argv.each_index do |pos|
      reg = argv[pos].to_s[/\Ar(\d+)\z/, 1]
      shifted = reg && unshift_proof_reg(reg.to_i, reg_offset)
      key = [:nint, irep.label, proof_idx, pos]
      id = "#{irep.label}:#{proof_idx}"
      if shifted.nil?
        NativeIntArgs.lines[key] = ['NINT', id, site, owner_def.owner, pos, 'substituted', '-', '-'].join("\t")
        next
      end
      if proven_fixnum_operand?(irep, proof_idx, shifted.to_s, owner_def)
        NativeIntArgs.lines[key] = ['NINT', id, site, "#{owner_def.owner}##{owner_def.name}", pos, 'PROVEN', '-', '-'].join("\t")
        next
      end
      why = []
      if fixnum_interval(irep, proof_idx, shifted.to_s, owner_def, 0, why)
        NativeIntArgs.lines[key] = ['NINT', id, site, "#{owner_def.owner}##{owner_def.name}", pos, 'RANGE', '-', '-'].join("\t")
        next
      end

      NativeIntArgs.lines[key] =
        ['NINT', id, site, "#{owner_def.owner}##{owner_def.name}", pos, native_int_arg_top(irep, proof_idx, shifted.to_i),
         "#{native_int_arg_mask(irep, proof_idx, shifted.to_i, owner_def)} first=#{why.first}",
         native_int_arg_leaves(irep, proof_idx, shifted.to_i, owner_def)].join("\t").gsub(/[\r\n]/, ' ')
    end
  end

  def native_int_arg_top(irep, proof_idx, reg)
    insn = irep.source_writer(proof_idx - 1, reg.to_s)
    return 'param-or-none' unless insn

    op = insn.op
    case op
    when 'SEND', 'SEND0', 'SSEND', 'SSEND0' then "send:#{insn.sym}"
    when 'GETCONST' then "const:#{insn.const_name}"
    when 'GETMCNST' then "const:#{insn.mcnst_name}"
    when 'GETIV' then "iv:#{insn.ivar}"
    else op
    end
  end

  def native_int_arg_mask(irep, proof_idx, reg, owner_def)
    mask = numeric_raw_mask(irep, proof_idx, reg, owner_def)
    mask.nil? ? 'unmodelled' : numeric_mask_name(mask)
  end

  def native_int_arg_leaves(irep, proof_idx, reg, owner_def)
    numeric_root_leaves(irep, proof_idx - 1, reg, owner_def).join('|')
  rescue StandardError => e
    "ERR:#{e.class}:#{e.message[0, 80]}"
  end
end

class CodeGen
  include NativeIntArgs
end
