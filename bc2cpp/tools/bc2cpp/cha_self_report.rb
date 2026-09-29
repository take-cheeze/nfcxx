# frozen_string_literal: true

# Debug report for CHA_SELF (ADR 0254): with BC2CPP_CHA_REPORT=<path>, every
# self-receiver send compile_send handled is written as one TSV row (the last
# compile of a site wins, since compiles_clean? probes compile methods early):
#
#   irep_label  index  name  self_owner  construct  dispatches  plan  detail  method_irep
#
# `construct` is the marker compile_send chose; `plan` is what cha_self_plan
# says about the site (`direct`, `arms`, or the refusal reason).
# scripts/bc2cpp_cha_self_report.rb aggregates it.
module ChaSelfReport
  CONSTRUCTS = %w[INHERITED_GUARD MONO_EMBED_GUARD POLY_SMALL_N POLY_TABLE CLOSED_WORLD_SELF LEXICAL_SELF_IVAR_ACCESSOR
                  LEXICAL_SELF MODULE_FUNCTION_SELF MONO TYPED IVAR_ACCESSOR POLY].freeze

  ROWS = {}

  def compile_send(insn, **kwargs)
    code = super
    owner_def = kwargs[:owner_def]
    irep = kwargs[:irep]
    if owner_def && irep && @closed_world && insn.n_spec != '*' && !insn.nk_spec
      recv = kwargs[:call_receiver] || (kwargs[:self_implicit] ? 'self' : "r#{insn.reg}")
      site = closed_world_site(recv, irep, kwargs[:idx], owner_def)
      if site && site[:self_owner]
        name = insn.sym
        plan, reason = cha_self_plan(name, insn.n_spec.to_i, site[:self_owner], explicit: !kwargs[:self_implicit])
        construct = CONSTRUCTS.find { |c| code.match?(%r{^\s*// #{c}\b}) } || 'OTHER'
        dispatches = code.scan(/\bmrb_funcall(?:_id|_with_block)?\(M,/).size
        detail = plan ? plan[:arms].map { |t, classes| "#{t.owner}=#{classes.size}" }.join(',') : ''
        kind = plan ? (plan[:arms].empty? ? 'direct' : 'arms') : reason
        ROWS[[irep.label, insn.addr]] =
          [irep.label, insn.addr, name, site[:self_owner], construct, dispatches, kind, detail, owner_def.irep].join("\t")
      end
    end
    code
  end

  def self.write(path)
    File.write(path, "#{ROWS.values.join("\n")}\n")
  end
end

CodeGen.prepend(ChaSelfReport)
at_exit { ChaSelfReport.write(ENV.fetch('BC2CPP_CHA_REPORT')) }
