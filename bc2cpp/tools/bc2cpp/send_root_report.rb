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
    # BC2CPP_POOL_DROP_REPORT loads this file for the pool report alone, which must not tag the generated text.
    return code unless ENV['BC2CPP_SEND_ROOT_REPORT'] && @closed_world && code.each_line.any? { |l| !l.lstrip.start_with?('//') && l.match?(BY_NAME) }

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
    # IVAR_POISON_CAUSES (ADR 0382): every blocking store, as `mask|kind|name|status|method`, where mask is `unmodelled`
    # (the irep has no flow) or `other` (the flow cannot name the value) and status is the producing name's state.
    # Unlike `blockers`, this follows the reaching definitions, so a joined register names the definition at fault.
    detail = group.sites.flat_map do |irep, idx, reg|
      culprits = send_root_culprits(irep, idx, reg, 0)
      culprits = [['other', 'join_state', '-', '-']] if culprits.empty? && !return_class_raw_mask(irep, idx, reg).then { |m| m && !m.anybits?(CodeGen::CLASS_POOL_UNSHIPPABLE) }
      culprits.map do |mask, kind, pname, status|
        [mask, kind, pname, status.to_s.sub(/ recv=.*/, ''), numeric_irep_owner[irep.label]&.name].join('|')
      end
    end
    ['POOL', family, name, (group.structural ? 'structural' : (group.failed ? 'failed' : 'open')) + cause,
     blockers.uniq.first(6).join(','), group.checked ? 'checked' : '-', detail.uniq.join(';;')]
  end

  # [mask kind, producer kind, producer name, status] of each reaching definition of +reg+ at +idx+ whose class set the
  # flow cannot name (the definition itself, a MOVE followed to its source).
  def send_root_culprits(irep, idx, reg, depth)
    raw = return_class_raw_mask(irep, idx, reg)
    return [] unless raw.nil? || raw.anybits?(CodeGen::CLASS_POOL_UNSHIPPABLE)
    return [['unmodelled', 'irep', '-', '-']] if raw.nil?

    why = {}
    defs = BytecodeIR.reaching_definitions(irep, idx, reg.to_s, refusal: why, through_handlers: true)
    return [['other', 'unreadable', why[:cause].to_s, '-']] if defs.nil? || defs.empty?

    defs.flat_map do |d|
      if d.entry?
        mask = class_pool_entry_mask(irep, d.reg)
        next [] unless mask.anybits?(CodeGen::CLASS_POOL_UNSHIPPABLE)

        reason = send_root_entry_reason(irep, d.reg.to_i)
        cand = reason.end_with?('pool_dropped') && depth < 3 && @entry_cand && @entry_cand[[irep.label, d.reg.to_i]]
        if cand
          # The pool was a candidate: the culprits are the values its call sites pass.
          sites, k = cand
          via = sites.flat_map { |(sirep, sidx, srecv, _argc, _own)| send_root_culprits(sirep, sidx, (srecv + k).to_s, depth + 2) }
          next via.map { |m, kd, n, st| [m, "via_#{reason.split(':').first}_arg:#{kd}", n, st] } unless via.empty?
        end
        [['other', 'entry', d.reg.to_i.zero? ? 'self' : "arg#{d.reg}", reason]]
      else
        after = return_class_raw_mask(irep, d.index + 1, d.reg)
        next [] unless after.nil? || after.anybits?(CodeGen::CLASS_POOL_UNSHIPPABLE)

        insn = irep.instructions[d.index]
        # The state after a literal is its own class set; a blocked `after` here is the join at a following branch target.
        next [] if insn.op.start_with?('LOADI') || %w[LOADNIL ARRAY ARRAY2 HASH STRING LOADTRUE LOADFALSE LOADSYM RANGE_INC RANGE_EXC].include?(insn.op)

        if insn.op == 'MOVE' && insn.regs[1] && depth < 6
          send_root_culprits(irep, d.index, insn.regs[1], depth + 1)
        else
          kind, pname, status = send_root_producer(irep, d.index + 1, d.reg)
          status = "#{send_root_status(pname)} recv=#{send_root_recv(irep, insn, d.index)}" if kind == 'send' && !status.to_s.start_with?('tracked')
          [[after.nil? ? 'unmodelled' : 'other', kind == 'send' ? "send:#{insn.op.downcase}" : insn.op.downcase, pname, status]]
        end
      end
    end
  end

  # Why argument +pos+ of +irep+ has no class pool: the first admission rule of ENTRY_ARG_CALLSITE_PROOF or
  # CONSTRUCTOR_POOLS it fails, or `pool_dropped` when it is a candidate whose sites pass a value the flow cannot name.
  def send_root_entry_reason(irep, pos)
    d = @owner_of[irep.label]
    return 'self' if pos.zero?
    return 'nested_block' unless d && d.irep == irep.label

    mand = mandatory_arity(irep)
    if d.name == 'initialize'
      constructor_pool_candidates
      return "ctor:off:#{@constructor_pool_refusal.to_s.sub(/ at .*|\d+ arguments.*/, '')}" if @constructor_pool_refusal
      return 'ctor:optional_position' if pos > mand

      status = @constructor_pool_status[irep.label]
      return "ctor:#{status.to_s.sub(/\d+ arguments.*|at .*/, '').strip}" if status && status != :ok

      return 'ctor:pool_dropped'
    end
    defs = @registry[d.name] || []
    return 'method:poly' if defs.size != 1
    return 'method:foreign_spelling' if @foreign_method_names.include?(d.name)
    return 'method:outside_token' if @outside_tokens.include?(d.name)
    return 'method:weird_name' unless d.name =~ /\A[A-Za-z_]/
    return 'method:optional_or_rest' unless pure_mandatory_arity?(irep)

    sites, poisoned = entry_arg_call_index
    return 'method:poisoned_name' if poisoned.include?(d.name)
    return 'method:dynamic_name' if numeric_dynamically_named?(d.name)
    return 'method:no_sites' if sites[d.name].empty?
    return 'method:arity_mismatch' unless sites[d.name].all? { |s| s[3] == mand }

    'method:pool_dropped'
  end

  # POOL_DROP_REPORT (ADR 0382): the dropped ivar pools counted by state and by the stores that dropped them. A pool counts
  # once per distinct blocker, so the blocker lines overlap; the state lines partition the dropped pools.
  def pool_drop_report
    return ['  (class pools are off)'] unless @class_ivar_pools

    states = Hash.new(0)
    blockers = Hash.new(0)
    dropped = 0
    @numeric_ivar_groups.each do |key, group|
      next if @class_ivar_pools.key?(key)

      dropped += 1
      row = send_root_pool_row(key, group)
      states[row[3]] += 1
      row[6].to_s.split(';;').map do |detail|
        mask, kind, name, status, = detail.split('|', 5)
        label = case kind
                when 'entry' then "entry #{status}"
                when /\Asend/ then "#{kind} #{status.to_s.split(':').first} #{name}"
                when /\Avia_/ then "#{kind} #{status}"
                else kind
                end
        "#{mask} #{label}"
      end.uniq.each { |label| blockers[label] += 1 }
    end
    lines = ["  POOL_DROPPED #{dropped}"]
    states.sort_by { |state, n| [-n, state] }.each { |state, n| lines << "  POOL_DROP_STATE #{state} #{n}" }
    blockers.sort_by { |label, n| [-n, label] }.each { |label, n| lines << "  POOL_DROP_BLOCKER #{label} pools=#{n}" }
    lines
  end

  def self.write(path)
    cg = ROWS[:codegen]
    pool_rows = cg ? cg.send_root_pool_rows : []
    File.write(path, "#{(ROWS.reject { |k, _| k == :codegen }.values + pool_rows).join("\n")}\n")
  end
end

CodeGen.prepend(SendRootReport)
at_exit { SendRootReport.write(ENV.fetch('BC2CPP_SEND_ROOT_REPORT')) if ENV['BC2CPP_SEND_ROOT_REPORT'] }
