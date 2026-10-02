# frozen_string_literal: true

# Debug report (ADR 0309): with BC2CPP_SEND_ROOT_REPORT=<path>, every explicit-receiver send whose
# generated code still holds a by-name dispatch is written as one TSV row naming the nearest
# producer of its receiver and why that producer's class is not proven:
#
#   owner  method  site  name  receiver_class_set  producer_kind  producer_name  producer_status
#
# The producer walk is the nearest textual writer, so a joined register is attributed to one of its
# writers; scripts/bc2cpp_send_root_report.rb aggregates the rows.
module SendRootReport
  ROWS = {}

  def compile_send(insn, **kwargs)
    code = super
    irep = kwargs[:irep]
    site = kwargs[:idx] || kwargs[:trace_idx]
    if @closed_world && irep && site && !kwargs[:self_implicit] && insn.n_spec != '*' && !insn.nk_spec && code.match?(/\bbc2cpp_send\(|\bmrb_funcall/)
      reg = unshift_proof_reg(kwargs[:trace_receiver_reg] || insn.reg, kwargs[:trace_reg_offset] || 0)
      mask = exact_flow_mask(irep, site, reg)
      kind, name, status = send_root_producer(irep, site, reg)
      ROWS[[irep.label, site]] = [kwargs[:owner_def]&.owner, irep.label, site, insn.sym,
                                  mask.nil? ? 'unmodelled' : class_mask_name(mask), kind, name, status].join("\t")
    end
    code
  end

  def send_root_producer(irep, site, reg)
    result = irep.walk_writers(site - 1, reg.to_s, skip_ops: ['BLOCK', *READ_ONLY_OPCODE_SKIP], follow_moves: true,
                                                   exhausted: ->(last) { [last == '0' ? 'self' : 'incoming_arg', '-', '-'] }) do |ins|
      case ins.op
      when 'SEND', 'SEND0', 'SENDB', 'SSEND', 'SSEND0', 'SSENDB' then ['send', ins.sym, send_root_status(ins.sym)]
      when 'GETIV' then ['ivar', ins.ivar.to_s, '-']
      when 'GETIDX', 'GETIDX0' then ['index', '-', '-']
      when 'GETUPVAR' then ['upvar', '-', '-']
      else [ins.op.downcase, '-', '-']
      end
    end
    result.is_a?(Array) ? result : ['unknown', '-', '-']
  end

  def send_root_status(name)
    @send_root_candidates ||= numeric_return_candidates.to_set
    mask = @rc_return && @rc_return[name]
    return "tracked:#{class_mask_name(mask)}" if mask
    return 'candidate_dropped' if @send_root_candidates.include?(name)

    defs = @registry[name] || []
    return 'no_definition' if defs.empty?
    return 'foreign_spelling' if @foreign_method_names&.include?(name)
    return 'aliased' if numeric_aliased_names.include?(name)
    return 'not_fully_visible' unless @closed_world.name_fully_visible?(name) || native_result_name_kinds(name)

    unusable = defs.reject { |d| numeric_return_def_usable?(d) }
    "unusable_def:#{unusable.map { |d| "#{d.owner}#{d.irep.nil? ? '(native)' : ''}" }.first(3).join(',')}"
  end

  def self.write(path)
    File.write(path, "#{ROWS.values.join("\n")}\n")
  end
end

CodeGen.prepend(SendRootReport)
at_exit { SendRootReport.write(ENV.fetch('BC2CPP_SEND_ROOT_REPORT')) }
