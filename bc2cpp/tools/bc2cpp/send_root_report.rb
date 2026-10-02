# frozen_string_literal: true

# Debug report (ADR 0309): with BC2CPP_SEND_ROOT_REPORT=<path>, every explicit-receiver send whose
# generated code still holds a by-name dispatch is written as one TSV row naming the nearest
# producer of its receiver and why that producer's class is not proven, and each by-name line of
# the generated C++ carries a `/*SR:<id>*/` tag so scripts/bc2cpp_send_root_report.rb can join a
# shipped site to its row:
#
#   id  owner  irep  site  name  receiver_class_set  producer_kind  producer_name  producer_status
#
# The producer walk is the nearest textual writer, so a joined register is attributed to one of its
# writers. The tag changes the generated text, so the report is never on in a real build.
module SendRootReport
  ROWS = {}
  BY_NAME = /\bbc2cpp_send\(|\bmrb_funcall\w*\(|\bbc2cpp_funcall_(?:argv|noarg|explicit)\(/

  def compile_send(insn, **kwargs)
    code = super
    return code unless @closed_world && code.each_line.any? { |l| !l.lstrip.start_with?('//') && l.match?(BY_NAME) }

    irep = kwargs[:irep]
    site = kwargs[:idx] || kwargs[:trace_idx]
    ROWS[:codegen] = self
    @send_root_owner = kwargs[:owner_def]
    id = irep && site ? "#{irep.label}:#{site}" : "n#{ROWS.size}"
    ROWS[id] = send_root_row(insn, kwargs, irep, site, id)
    code.each_line.map do |l|
      !l.lstrip.start_with?('//') && l.match?(BY_NAME) ? l.sub(/\n\z/, " /*SR:#{id}*/\n") : l
    end.join
  end

  def send_root_row(insn, kwargs, irep, site, id)
    owner = kwargs[:owner_def]&.owner
    if kwargs[:self_implicit] || !irep || !site || insn.n_spec == '*' || insn.nk_spec
      kind = if kwargs[:self_implicit] then 'self_implicit'
             elsif insn.n_spec == '*' || insn.nk_spec then 'splat_or_keyword'
             else 'no_site'
             end
      return [id, owner, irep&.label, site, insn.sym, '-', "skipped:#{kind}", '-', '-'].join("\t")
    end

    reg = unshift_proof_reg(kwargs[:trace_receiver_reg] || insn.reg, kwargs[:trace_reg_offset] || 0)
    mask = exact_flow_mask(irep, site, reg)
    kind, name, status = send_root_producer(irep, site, reg)
    [id, owner, irep.label, site, insn.sym, mask.nil? ? 'unmodelled' : class_mask_name(mask), kind, name, status].join("\t")
  end

  def send_root_producer(irep, site, reg)
    result = irep.walk_writers(site - 1, reg.to_s, skip_ops: ['BLOCK', *READ_ONLY_OPCODE_SKIP], follow_moves: true,
                                                   exhausted: ->(last) { [last == '0' ? 'self' : 'incoming_arg', '-', '-'] }) do |ins, index|
      case ins.op
      when 'SEND', 'SEND0', 'SENDB', 'SSEND', 'SSEND0', 'SSENDB'
        ['send', send_root_name(irep, ins, index), "#{send_root_status(ins.sym)} recv=#{send_root_recv(irep, ins, index)}"]
      when 'GETIV' then ['ivar', ins.ivar.to_s, send_root_ivar_status(irep, ins.ivar.to_s)]
      when 'GETIDX', 'GETIDX0' then ['index', '-', '-']
      when 'GETUPVAR' then ['upvar', '-', '-']
      when 'ARRAY', 'ARRAY2' then ['array', send_root_array_name(irep, ins, index), '-']
      else [ins.op.downcase, '-', '-']
      end
    end
    result.is_a?(Array) ? result : ['unknown', '-', '-']
  end

  # Why an ivar read has no pooled class set: the pool's mask, or the group's state and blockers.
  def send_root_ivar_status(irep, name)
    owner = numeric_irep_owner[irep.label]
    return 'no_owner' unless owner && @class_ivar_pools

    key = [numeric_family(owner.owner), name]
    mask = @class_ivar_pools[key]
    return "pooled:#{class_mask_name(mask)}" if mask

    group = @numeric_ivar_groups[key]
    return 'no_group' unless group

    return 'nested' if @send_root_nested

    @send_root_nested = true
    begin
      send_root_pool_row(key, group)[3..].join(' ')
    ensure
      @send_root_nested = false
    end
  end

  # The class set the flow proves for the producing send's own receiver.
  def send_root_recv(irep, ins, index)
    return 'selfcall' if %w[SSEND SSEND0 SSENDB].include?(ins.op)

    mask = exact_flow_mask(irep, index, ins.reg)
    return 'unmodelled' if mask.nil?

    (mask & NumericFlow::OTHER).zero? ? class_mask_name(mask) : 'OTHER'
  end

  # An Array literal producer names the class set of each element register.
  def send_root_array_name(irep, ins, index)
    three = ins.src_and_literal
    src = three ? three[0].to_i : ins.reg.to_i
    n = three ? three[1].to_i : ins.uint_operand.to_i
    sets = (src...(src + n)).map do |r|
      mask = exact_flow_mask(irep, index, r.to_s)
      fix = proven_fixnum_operand?(irep, index, r.to_s, @send_root_owner) ? '!' : ''
      (mask.nil? ? 'unmodelled' : class_mask_name(mask)) + fix
    end
    "[#{sets.join(',')}]"
  end

  # A `Klass.new` producer is named after the constant it constructs.
  def send_root_name(irep, ins, index)
    return ins.sym unless ins.sym == 'new'

    "new(#{irep.agreed_constant_name(index, ins.reg.to_s) || '?'})"
  end

  def send_root_status(name)
    @send_root_candidates ||= numeric_return_candidates.to_set
    mask = @rc_return && @rc_return[name]
    return "tracked:#{class_mask_name(mask)}" if mask
    return "candidate_dropped:#{send_root_blockers(name)}" if @send_root_candidates.include?(name)

    defs = @registry[name] || []
    return 'no_definition' if defs.empty?
    return 'foreign_spelling' if @foreign_method_names&.include?(name)
    return 'aliased' if numeric_aliased_names.include?(name)
    return 'not_fully_visible' unless @closed_world.name_fully_visible?(name) || native_result_name_kinds(name)

    unusable = defs.reject { |d| numeric_return_def_usable?(d) }
    "unusable_def:#{unusable.map { |d| "#{d.owner}#{d.irep.nil? ? '(native)' : ''}" }.first(3).join(',')}"
  end

  # The definitions of a dropped name whose class set is unmodelled.
  def send_root_blockers(name)
    return '' unless @rc_states

    @registry[name].select { |d| (return_class_def_mask(d) & NumericFlow::OTHER) != 0 }
                   .map { |d| "#{d.owner}#{d.irep.nil? ? '[attr]' : ''}" }.first(3).join(',')
  end

  # One row per ivar group the class pools dropped: family, ivar, why, and the producers of the values
  # its SETIV sites store that the exact-class flow cannot name (kind:name@writing method).
  def send_root_pool_rows
    return [] unless @class_ivar_pools

    @numeric_ivar_groups.filter_map do |key, group|
      send_root_pool_row(key, group).join("\t") unless @class_ivar_pools.key?(key)
    end
  end

  def send_root_pool_row(key, group)
    family, name = key
    blockers = group.sites.filter_map do |irep, idx, reg|
      mask = return_class_raw_mask(irep, idx, reg)
      next unless mask.nil? || mask.anybits?(CodeGen::CLASS_POOL_UNSHIPPABLE)

      kind, pname, = send_root_producer(irep, idx, reg)
      "#{kind}:#{pname}@#{numeric_irep_owner[irep.label]&.name}"
    end
    writer = (@registry["#{name}="] || []).any? { |d| d.kind == :ivar_accessor && d.irep.nil? && numeric_family(d.owner) == family }
    cause = if !group.structural then ''
            elsif writer then ':writer'
            elsif @numeric_wild_families.include?(family) then ':wild'
            else ':poisoned'
            end
    ['POOL', family, name, (group.structural ? 'structural' : (group.failed ? 'failed' : 'open')) + cause,
     blockers.uniq.first(6).join(',')]
  end

  def self.write(path)
    cg = ROWS[:codegen]
    pool_rows = cg ? cg.send_root_pool_rows : []
    File.write(path, "#{(ROWS.reject { |k, _| k == :codegen }.values + pool_rows).join("\n")}\n")
  end
end

CodeGen.prepend(SendRootReport)
at_exit { SendRootReport.write(ENV.fetch('BC2CPP_SEND_ROOT_REPORT')) }
