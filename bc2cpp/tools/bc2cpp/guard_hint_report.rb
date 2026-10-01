# frozen_string_literal: true

# Debug report for the hint-based guard families (ADR 0295): with BC2CPP_GUARD_HINT_REPORT=<path>,
# every explicit-receiver send compile_send handled is written as one TSV row (the last compile of
# a site wins, since compiles_clean? probes compile methods early):
#
#   irep_label  index  name  family  else_arm  receiver_origin  method_irep  origin_ivar  class_set
#
# `family` is the construct compile_send chose, `else_arm` is what its guard falls to (`nomethod`,
# `kept:<reason>`, `send`, `none`) and `receiver_origin` is receiver_trace_origin's nearest
# defining instruction; `class_set` is the class pools' set for the receiver register. scripts/bc2cpp_guard_hint_report.rb aggregates it.
module GuardHintReport
  FAMILIES = %w[EXACT_TYPED TYPED ELEMENT IVAR_ACCESSOR MONO_EMBED_GUARD POLY_SMALL_N POLY_TABLE
                CLOSED_WORLD_EXACT_CLASS CLOSED_WORLD_SELF POLY].freeze

  ROWS = {}

  def compile_send(insn, **kwargs)
    code = super
    irep = kwargs[:irep]
    site = kwargs[:idx] || kwargs[:trace_idx]
    if irep && site && !kwargs[:self_implicit] && insn.n_spec != '*' && !insn.nk_spec
      family = FAMILIES.find { |f| code.match?(%r{^\s*// #{f}\b}) }
      if family
        kept = code.scan(/CLOSED_WORLD kept: (\w+)/).flatten.uniq
        else_arm = if code.include?('bc2cpp_nomethod_named') then 'nomethod'
                   elsif !kept.empty? then "kept:#{kept.join('+')}"
                   elsif code.match?(/\bmrb_funcall(?:_id|_with_block)?\(M,/) then 'send'
                   else 'none'
                   end
        reg = unshift_proof_reg(kwargs[:trace_receiver_reg] || insn.reg, kwargs[:trace_reg_offset] || 0)
        origin = receiver_trace_origin(irep, site, reg)
        mask = exact_flow_mask(irep, site, reg)
        class_set = mask.nil? ? 'unmodelled' : class_mask_name(mask)
        class_set += ' [nilable arm]' if code.include?('// NILABLE_RECEIVER')
        ROWS[[irep.label, site]] = [irep.label, site, insn.sym, family, else_arm, origin, kwargs[:owner_def]&.irep,
                                    origin_ivar(irep, site, reg, kwargs[:owner_def]), class_set].join("\t")
      end
    end
    code
  end

  # `Owner#@ivar` when the nearest defining instruction is a GETIV, else empty.
  def origin_ivar(irep, site, reg, owner_def)
    irep.walk_writers(site - 1, reg.to_s, skip_ops: ['BLOCK', *READ_ONLY_OPCODE_SKIP]) do |ins|
      next IrepScans.follow(ins.regs[1]) if ins.op == 'MOVE' && ins.regs[1]

      break "#{owner_def&.owner}#@#{ins.ivar}" if ins.op == 'GETIV'
    end.to_s
  end

  def self.write(path)
    File.write(path, "#{ROWS.values.join("\n")}\n")
  end
end

CodeGen.prepend(GuardHintReport)
at_exit { GuardHintReport.write(ENV.fetch('BC2CPP_GUARD_HINT_REPORT')) }
