# frozen_string_literal: true
require 'set'

# CodeGen: RECEIVER_SURVIVES (NumericFlow#survive_receiver): after a call or index whose name nil cannot answer
# returns normally, its receiver and the variable behind it are not nil. nil_unanswerable? is the soundness condition:
# no Ruby, foreign or native definition of the name on nil's lookup path and no method_missing there, so a nil
# receiver raises NoMethodError. BC2CPP_RECEIVER_SURVIVES=0 turns it off; BC2CPP_RECEIVER_SURVIVES_VERIFY=1 aborts
# at runtime when a register it narrowed holds nil right after the op.
class CodeGen
  def receiver_survives?(name)
    @receiver_survives ||= {}
    return @receiver_survives[name] if @receiver_survives.key?(name)

    @receiver_survives[name] = ENV['BC2CPP_RECEIVER_SURVIVES'] != '0' && nil_unanswerable?(name)
  end

  def receiver_survives_verify?
    return @receiver_survives_verify if defined?(@receiver_survives_verify)

    @receiver_survives_verify = ENV['BC2CPP_RECEIVER_SURVIVES_VERIFY'] == '1'
  end

  # The registers below +nregs+ whose NIL the narrowing at +index+ stripped, kept for the verify checks.
  def note_receiver_survives(irep, index, before, after, nregs)
    return unless receiver_survives_verify?

    regs = (0...nregs).select { |r| before[r].is_a?(Integer) && before[r].anybits?(NumericFlow::NIL) && !after[r].anybits?(NumericFlow::NIL) }
    return if regs.empty?

    ((@receiver_survives_sites ||= {})[[irep.label, index]] ||= Set.new).merge(regs)
  end

  # Registers the op at +index+ itself writes (its result and the callee frame from R(a) up): their later value is not
  # the receiver's, so the verify check reads only the registers below.
  def receiver_survives_checked_regs(irep, index)
    regs = @receiver_survives_sites&.[]([irep.label, index])
    return [] unless regs

    insn = BytecodeIR.for(irep).source_at(index)
    first_written = insn.reg.to_i
    regs.select { |r| r < first_written }.sort
  end
end

module ReceiverSurvivesVerify
  def compile_insn(insn, irep, owner_def, idx = nil, reg_offset = 0)
    code = super
    return code unless receiver_survives_verify? && idx && irep && reg_offset.zero? && !code.include?('#error')

    regs = receiver_survives_checked_regs(irep, idx)
    return code if regs.empty?

    where = "#{File.basename(irep.file.to_s)}:#{insn.lineno} #{irep.label}@#{idx}"
    checks = regs.map do |r|
      "  if (mrb_nil_p(r#{r})) mrb_bug(M, \"RECEIVER_SURVIVES_VERIFY: r#{r} is nil after #{insn.op} (#{where})\");\n"
    end
    code + checks.join
  end
end

CodeGen.prepend(ReceiverSurvivesVerify)
