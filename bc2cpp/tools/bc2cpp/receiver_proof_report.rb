# frozen_string_literal: true

require_relative 'block_send_report_columns'
require_relative 'receiver_proof_report_columns'
require_relative 'numeric_flow'

# Debug report (ADR 0331): with BC2CPP_RECEIVER_PROOF_REPORT=<path>, every engine explicit-receiver send whose
# generated code holds a by-name line is written as one TSV row (the last compile of a site wins), with where its
# receiver comes from and what would happen to the line if the receiver's class set were proven. It changes no
# generated code; scripts/bc2cpp_receiver_proof_report.rb aggregates it.
#
# The what-if recompiles the one send (in a forked child, so the build is untouched) with the receiver forced to a
# hypothetical class set and counts the by-name lines again, so "removed" is what the real consumers do with a
# proven set, not a model of them. Two hypotheses, both optimistic about the proof itself (they say what a proof would
# be worth, not that one exists, and the forced register ignores the other writers the real flow would join): `hyp`,
# the set the source's own data suggests; `floor`, every class that answers the name, so a line gone at the floor is
# gone for whatever set is proven. Each is forced without nil and with nil, the set an ivar, argument or call result
# needs.
#
# Columns (ReceiverProofReport::COLUMNS):
#   - source: `call` (a send result), `merge` (a literal written on one path of a join, as `x || []` is), `element`
#     (GETIDX), `argument`, `ivar`, `const`, `upvar`, `self`, `literal` (dominating, so already exact), `other`.
#   - detail: the callee, ivar or constant name; for `merge` the class and the producer of the other arm.
#   - existing: the classes the flow already proves (`-` when unproven); mask: the flow's raw class set.
#   - hyp / hyp_complete: the source's own set and whether nothing in its source is left unmodelled (`audit`: only
#     native definitions are, and NATIVE_RESULT_ASSUMED supplies their class).
#   - before / after / after_nil: by-name lines of the site, as compiled, with the receiver forced to `hyp`, and with it
#     forced to `hyp` or nil (the same as `after` for a merge, whose arms are never nil); nomethod_delta / reloc:
#     `bc2cpp_nomethod` and `bc2cpp_nil_receiver` lines the forced set adds (the second is a send that moved into the
#     nil helper, not one that went away).
#   - cells: per class of `hyp`, what the class's definition of the name is (native, Ruby not direct, ...).
#   - why: what keeps the source unmodelled: for `call` the producers of the unmodelled returns of its definitions
#     (`native:`, `accessor:`, `ivar:`, `arg`, `call:`, `element`, `const`, `block`, ...), for `ivar` the pool state.
#   - percls / pc_set / pc_after / pc_after_nil: for `call`, what the definitions the producing call's own proven
#     receiver resolves to return (instead of every definition of the name) and the by-name lines left with that set.
#   - answerers: the instance classes that answer the name (`unbounded` when nothing bounds it, `-` when none).
#   - floor_after / floor_nil / floor_reloc: by-name lines with the receiver forced to every answerer, and to every
#     answerer or nil, and the nil-helper lines that adds; kinds: the kinds of definition (cells) over the answerers.
module ReceiverProofReport
  ROWS = {}
  BY_NAME = /\bbc2cpp_send\(|\bmrb_funcall\w*\(|\bbc2cpp_funcall_(?:argv|noarg|explicit)\(/
  NOMETHOD = /\bbc2cpp_nomethod\w*\(/
  NIL_RECEIVER = /\bbc2cpp_nil_receiver\w*\(/
  LITERAL_CLASS = { 'ARRAY' => 'Array', 'ARRAY2' => 'Array', 'HASH' => 'Hash', 'STRING' => 'String', 'STR' => 'String',
                    'RANGE_INC' => 'Range', 'RANGE_EXC' => 'Range' }.freeze
  CORE_BIT = { NumericFlow::INT => 'Integer', NumericFlow::FLT => 'Float', NumericFlow::ARR => 'Array',
               NumericFlow::HSH => 'Hash', NumericFlow::STR => 'String', NumericFlow::RNG => 'Range' }.freeze
  # Class every native definition of a name returns, for the what-if only (nothing audits it here): a name whose only
  # unmodelled definitions are natives gets it, and its hypothesis is marked `audit` instead of complete.
  NATIVE_RESULT_ASSUMED = { 'keys' => 'Array', 'parameters' => 'Array', 'members' => 'Array', 'to_a' => 'Array',
                            'split' => 'Array', 'bytes' => 'Array', 'to_h' => 'Hash', 'to_s' => 'String',
                            'snap_to_bitmap' => 'RGSS::Bitmap' }.freeze
  CALL_OPS = %w[SEND SEND0 SENDB SSEND SSEND0 SSENDB].freeze

  def compile_send(insn, **kwargs)
    return super if @rp_force || !ReceiverProofReport.active?

    code = super
    return code unless @closed_world && @native_results_ready && insn.n_spec != '*' && !insn.nk_spec && !kwargs[:self_implicit]

    irep = kwargs[:irep]
    site = kwargs[:idx] || kwargs[:trace_idx]
    gem = irep && (ReceiverProofReport.gem_of(irep) || (ENV['BC2CPP_RECEIVER_PROOF_ANY'] == '1' ? 'other' : nil))
    return code unless site && gem && ReceiverProofReport.by_name(code).positive?

    ROWS[[irep.label, site]] = rp_row(insn, kwargs, irep, site, gem, code)
    code
  end

  # Forced receiver class set of the one send being re-compiled (registers as the consumers ask: proof registers).
  def exact_flow_mask(irep, idx, reg)
    f = @rp_force
    return f[:mask] if f && irep.label == f[:irep] && idx == f[:idx] && reg.to_s == f[:reg].to_s

    super
  end

  def exact_flow_class(irep, idx, reg)
    f = @rp_force
    if f && irep.label == f[:irep] && idx == f[:idx] && reg.to_s == f[:reg].to_s
      # The nil half is stripped as exact_flow_class does, or NILABLE_RECEIVER would never see a nil-or-class set.
      return return_class_of_mask(exact_flow_strip_nil(irep, idx, reg.to_i, f[:mask]))
    end

    super
  end

  # Only the shipped pass (SKIP_UNSUPPORTED=1) is reported: the diagnostic pass compiles every method again.
  def self.active?
    ENV['SKIP_UNSUPPORTED'] == '1' || ENV['BC2CPP_RECEIVER_PROOF_ANY'] == '1'
  end

  def self.gem_of(irep)
    BlockSendReport::ENGINE_GEMS.find { |g| irep.file.to_s.include?("/#{g}/") }
  end

  def self.by_name(code)
    code.lines.count { |l| !l.lstrip.start_with?('//') && l.match?(BY_NAME) }
  end

  def rp_row(insn, kwargs, irep, site, gem, code)
    name = insn.sym
    reg = unshift_proof_reg(kwargs[:trace_receiver_reg] || insn.reg, kwargs[:trace_reg_offset] || 0)
    owner = kwargs[:owner_def]
    owner_name = owner ? "#{owner.owner}##{owner.name}" : '-'
    argc = (insn.n_spec || '0').to_i
    where = "#{irep.file.to_s.sub(%r{.*/(mruby-)}, '\\1')}:#{irep.instructions[site]&.lineno}"
    source, detail, mask_h = reg ? rp_source(irep, site, reg) : ['other', 'no_reg', nil]
    why = mask_h && mask_h[:why] || '-'
    percls, pc_classes, pc_mask = mask_h && mask_h[:percls] || ['-', [], 0]
    mask = reg ? exact_flow_mask(irep, site, reg) : nil
    before = ReceiverProofReport.by_name(code)
    mask_s = mask.nil? ? 'unmodelled' : class_mask_name(mask) + ((mask & NumericFlow::OTHER).zero? ? '' : '+OTHER')
    classes = reg ? rp_instance_classes(mask) : nil
    base = [irep.label, site, gem, owner_name, name, argc, source, detail, classes ? classes.sort.join('|') : '-', mask_s]
    return (base + ['-', '-', '-', before, before, before, 0, 0, '-', '-', '-', '-', '-', '-', '-', '-', '-', '-', where]).join("\t") if classes || !reg

    # A merge never holds nil; every other source may, and a set that includes nil is what a real proof would be.
    nilable = !%w[merge literal].include?(source)
    probe = lambda do |set, with_nil = false|
      rp_what_if(insn, kwargs, irep, site, reg, [set, with_nil], code)
    end
    both = ->(set) { [probe.call(set), nilable ? probe.call(set, true) : nil] }
    hyp = mask_h && rp_instance_classes(mask_h[:mask])
    (after, nm_delta, _), (after_nil, _, reloc) = hyp ? both.call(hyp) : [[before, 0, 0], [before, 0, 0]]
    after_nil ||= after
    pc_set = percls == 'complete' ? rp_instance_classes(pc_mask) : nil
    (pc_after, _, _), (pc_after_nil, _, _) = pc_set ? both.call(pc_set) : [['-'], ['-']]
    pc_after_nil ||= pc_after
    answerers = rp_answerers(name)
    list = answerers.is_a?(Array) && !answerers.empty?
    (floor_after, _, _), (floor_nil, _, floor_reloc) = list ? both.call(answerers) : [['-'], ['-', 0, '-']]
    floor_nil ||= floor_after
    complete = if mask_h && mask_h[:complete] == :audit then 'audit'
               else mask_h && mask_h[:complete] ? 1 : 0
               end
    (base + [hyp ? hyp.sort.join('|') : '-', complete, why, before, after, after_nil, nm_delta, reloc,
             hyp ? rp_cells(name, argc, hyp) : '-', rp_answerers_text(answerers), floor_after, floor_nil, floor_reloc,
             list ? rp_kinds(name, argc, answerers) : '-', percls == 'complete' ? "complete:#{pc_classes.sort.join('|')}" : percls,
             pc_set ? pc_set.sort.join('|') : '-', pc_after, pc_after_nil, where]).join("\t")
  end

  # The instance classes that answer +name+, [] when none, or :unbounded when nothing bounds the name.
  def rp_answerers(name)
    set = call_facts_answers.members(name) or return :unbounded
    set.select { |k| instance_class?(k) || CORE_BIT.value?(k) }.sort
  end

  def rp_answerers_text(answerers)
    return 'unbounded' unless answerers.is_a?(Array)

    answerers.empty? ? '-' : answerers.join('|')
  end

  def rp_kinds(name, argc, classes)
    rp_cells(name, argc, classes).split('|').map { |c| c.split('=').last }.uniq.sort.join('+')
  end

  # Runs in a forked child: a recompile leaves memos behind (a block's direct-entry decision, for one) that would
  # change what the parent emits next, and the report must not.
  def rp_what_if(insn, kwargs, irep, site, reg, (classes, with_nil), code)
    reader, writer = IO.pipe
    pid = fork do
      reader.close
      # The class bits are allocated here, so the parent's table (and nothing it emits) never changes.
      mask = classes.sum { |k| rp_class_bit(k) } | (with_nil ? NumericFlow::NIL : 0)
      @rp_force = { irep: irep.label, idx: site, reg: reg, mask: mask }
      again = compile_send(insn, **kwargs)
      writer.write(Marshal.dump([ReceiverProofReport.by_name(again), again.scan(NOMETHOD).size - code.scan(NOMETHOD).size,
                                 again.scan(NIL_RECEIVER).size - code.scan(NIL_RECEIVER).size]))
      writer.close
      exit!(0)
    end
    writer.close
    result = reader.read
    reader.close
    _pid, status = Process.wait2(pid)
    raise "[receiver_proof_report] what-if of #{irep.label}:#{site} failed (#{status.exitstatus})" unless status.success?

    Marshal.load(result)
  end

  # The classes a class set names when every bit is an instance class (nil is an instance too), else nil.
  def rp_instance_classes(mask)
    return nil unless mask.is_a?(Integer) && mask.positive?

    rest = mask & ~NumericFlow::NIL
    classes = []
    CORE_BIT.each do |bit, klass|
      next unless rest.anybits?(bit)

      classes << klass
      rest &= ~bit
    end
    (@numeric_class_bits || {}).each do |klass, bit|
      next unless rest.anybits?(bit)
      return nil unless instance_class?(klass)

      classes << klass
      rest &= ~bit
    end
    rest.zero? && !classes.empty? ? classes : nil
  end

  def rp_class_bit(klass)
    CORE_BIT.key(klass) || numeric_class_bit(klass)
  end

  # [source, detail, hypothesis] of the receiver register: the nearest textual writer, and the set the source would
  # give were it proven (see the header). hypothesis is {mask:, complete:} or nil when the source has no candidate.
  def rp_source(irep, site, reg, hypothesis: true)
    found = irep.walk_writers(site - 1, reg.to_s, skip_ops: ['BLOCK', *READ_ONLY_OPCODE_SKIP], follow_moves: true,
                                                  exhausted: ->(last) { rp_incoming(irep, last, hypothesis) }) do |ins, i|
      rp_writer(irep, site, reg, ins, i, hypothesis)
    end
    found.is_a?(Array) ? found : ['other', 'unknown', nil]
  end

  # The register was never written in the body: self, or an incoming argument with its class pool state.
  def rp_incoming(irep, reg, hypothesis)
    return ['self', '-', nil] if reg == '0'
    return ['argument', '-', nil] unless hypothesis

    key = [irep.label, reg.to_i]
    pool = @class_arg_pools && @class_arg_pools[key]
    mask = pool || NumericFlow::OTHER
    ['argument', '-', { mask: mask & ~NumericFlow::OTHER & ~NumericFlow::NIL, complete: mask.nobits?(NumericFlow::OTHER),
                        why: rp_argument_why(key, pool) }]
  end

  # `pooled`, `no_candidate` (the method is not a pool candidate: no visible caller or an escaping entry) or
  # `dropped:<kinds>`: the producers of the argument at the call sites whose class set is unmodelled.
  def rp_argument_why(key, pool)
    return pool.anybits?(NumericFlow::OTHER) ? 'pool_has_other' : 'pooled' if pool

    cand = @entry_cand && @entry_cand[key]
    return 'no_candidate' unless cand

    sites, k = cand
    kinds = sites.filter_map do |ci, cx, recv, _argc, _own|
      reg = (recv + k).to_s
      m = return_class_raw_mask(ci, cx, reg)
      rp_producer_kind(ci, cx, reg) if m.nil? || m.anybits?(CodeGen::CLASS_POOL_UNSHIPPABLE)
    end
    "dropped:#{kinds.uniq.sort.first(4).join(',')}"
  end

  def rp_writer(irep, site, reg, ins, index, hypothesis)
    case ins.op
    when *CALL_OPS then ['call', ins.sym.to_s, hypothesis ? rp_call_hypothesis(irep, index, ins) : nil]
    when 'GETIV' then ['ivar', ins.ivar.to_s, hypothesis ? rp_ivar_hypothesis(irep, ins) : nil]
    when 'GETIDX', 'GETIDX0' then ['element', '-', nil]
    when 'GETUPVAR' then ['upvar', '-', nil]
    when 'GETCONST', 'GETMCNST' then ['const', ins.sym.to_s, nil]
    when *LITERAL_CLASS.keys then rp_literal_writer(irep, site, reg, ins, index)
    else ['other', ins.op.downcase, nil]
    end
  end

  # A literal that does not dominate the read is one arm of a join (`x || []`); the hypothesis is that the other arm
  # is the same class too, and `detail` names what the other arm is.
  def rp_literal_writer(irep, site, reg, ins, index)
    klass = LITERAL_CLASS[ins.op]
    return ['literal', klass, nil] if exact_core_value_class(irep, site, reg)

    other = irep.walk_writers(index - 1, ins.reg.to_s, skip_ops: ['BLOCK', *READ_ONLY_OPCODE_SKIP], follow_moves: true,
                                                       exhausted: ->(last) { last == '0' ? 'self' : 'argument' }) do |w, _wi|
      case w.op
      when *CALL_OPS then "call:#{w.sym}"
      when 'GETIV' then "ivar:#{w.ivar}"
      when 'GETIDX', 'GETIDX0' then 'element'
      when 'GETCONST' then "const:#{w.sym}"
      else w.op.downcase
      end
    end
    other = 'unknown' unless other.is_a?(String)
    ['merge', "#{klass}|#{other}", { mask: rp_class_bit(klass), complete: false, why: other }]
  end

  # Joined known classes over every definition of the called name; complete when none is unmodelled.
  def rp_call_hypothesis(irep, index, ins)
    defs = @registry[ins.sym] || []
    return { mask: 0, complete: false, why: 'no_definition' } if defs.empty?

    masks = defs.map { |d| return_class_def_mask(d) }
    joined = masks.reduce(0, :|)
    known = joined & ~NumericFlow::OTHER & ~NumericFlow::NIL
    open = defs.zip(masks).select { |_d, m| m.anybits?(NumericFlow::OTHER) }
    why = open.flat_map { |d, _m| rp_def_why(d) }.uniq.sort.first(4)
    complete = (joined & NumericFlow::OTHER).zero? ? true : false
    assumed = NATIVE_RESULT_ASSUMED[ins.sym]
    if assumed && !open.empty? && open.all? { |d, _m| d.owner == '<native>' }
      known |= rp_class_bit(assumed)
      complete = :audit
    end
    { mask: known, complete: complete, why: why.empty? ? '-' : why.join(','), percls: rp_percls(irep, index, ins) }
  end

  # The return set of the definitions the call's own proven receiver classes resolve to, instead of every
  # definition of the name: [status, classes, mask] with status `selfcall`, `recv_unproven`, `unresolved`,
  # `incomplete` or `complete`.
  def rp_percls(irep, index, ins)
    return ['selfcall', [], 0] unless %w[SEND SEND0].include?(ins.op)

    classes = receiver_instances({ irep: irep, idx: index, insn: ins }, ins.sym)
    return ['recv_unproven', [], 0] unless classes

    joined = 0
    classes.each do |klass|
      target, known = closed_world_lookup_target(ins.sym, klass, Set.new, any_visibility: true)
      return ['unresolved', classes, 0] unless known && target

      joined |= return_class_def_mask(target)
    end
    [joined.anybits?(NumericFlow::OTHER) ? 'incomplete' : 'complete', classes, joined & ~NumericFlow::OTHER & ~NumericFlow::NIL]
  end

  # What makes one definition's return unmodelled: the kind of each unmodelled return value.
  def rp_def_why(d)
    # `(absent)`: the registry's placeholder, but no native source of this build defines the name.
    return ["native:#{d.name}#{'(absent)' if @closed_world.native_paths_spelling(d.name).empty?}"] if d.owner == '<native>'
    return ["accessor:#{d.kind}"] unless d.irep

    irep = @ireps[d.irep]
    states = return_class_states(irep)
    return ['no_states'] unless states

    kinds = []
    irep.instructions.each_with_index do |insn, idx|
      next unless states[idx] && %w[RETURN RETURN_BLK RETSELF RETTRUE RETFALSE BREAK STOP].include?(insn.op)

      mask = insn.reg ? states[idx][insn.reg.to_i] || NumericFlow::OTHER : NumericFlow::OTHER
      next unless mask.anybits?(NumericFlow::OTHER)

      kinds << (%w[RETURN RETURN_BLK].include?(insn.op) ? rp_producer_kind(irep, idx, insn.reg.to_s) : insn.op.downcase)
    end
    block = return_class_block_returns(irep)
    kinds << 'block_return' if block.nil? || block.anybits?(NumericFlow::OTHER)
    kinds.empty? ? ['unknown'] : kinds
  end

  def rp_producer_kind(irep, idx, reg)
    source, detail, = rp_source(irep, idx, reg, hypothesis: false)
    %w[call ivar const].include?(source) ? "#{source}:#{detail}" : source
  end

  def rp_ivar_hypothesis(irep, ins)
    pool = class_pool_ivar_mask(irep, ins.ivar.to_s)
    mask = pool || NumericFlow::OTHER
    { mask: mask & ~NumericFlow::OTHER & ~NumericFlow::NIL, complete: mask.nobits?(NumericFlow::OTHER),
      why: rp_ivar_why(irep, ins.ivar.to_s, pool) }
  end

  # Why the slot has no class pool: `structural:` (outside, writer, wild or poisoned: a native or foreign source spells
  # the name, an attr_writer, an open family, a poisoned name) or `dropped:<kinds>` (a store whose class set is
  # unmodelled, by the producer of the stored value), the causes of SendRootReport#send_root_pool_row.
  def rp_ivar_why(irep, name, pool)
    return pool.anybits?(NumericFlow::OTHER) ? 'pool_has_other' : 'pooled' if pool

    owner = numeric_irep_owner[irep.label]
    return 'no_owner' unless owner && !owner.owner.end_with?('.singleton') && !owner.owner.start_with?('<')

    family = numeric_family(owner.owner)
    group = @numeric_ivar_groups[[family, name]]
    return 'no_group' unless group
    return "structural:#{rp_structural_cause(family, name)}" if group.structural

    kinds = group.sites.filter_map do |gi, gx, gr|
      m = return_class_raw_mask(gi, gx, gr)
      rp_producer_kind(gi, gx, gr.to_s) if m.nil? || m.anybits?(CodeGen::CLASS_POOL_UNSHIPPABLE)
    end
    "dropped:#{kinds.uniq.sort.first(4).join(',')}"
  end

  def rp_structural_cause(family, name)
    return 'outside' if @outside_ivar_names.include?(name)
    return 'writer' if (@registry["#{name}="] || []).any? { |d| d.kind == :ivar_accessor && d.irep.nil? && numeric_family(d.owner) == family }

    @numeric_wild_families.include?(family) ? 'wild' : 'poisoned'
  end

  # Per class: what the definition of +name+ is for an instance of it (the cell of a direct chain).
  def rp_cells(name, argc, classes)
    classes.sort.map do |klass|
      native_owners = (NativeDirect::ENTRIES[name] || {}).select { |_o, e| e.kinds.size == argc }.keys
      kind = if native_owners.include?(klass) then 'native_direct'
             elsif NativeCoreDirect::ENTRIES.any? { |e| e.name == name && e.owner == klass && e.arity == argc } then 'native_core_direct'
             else rp_cell_lookup(name, klass, argc)
             end
      "#{klass}=#{kind}"
    end.join('|')
  end

  def rp_cell_lookup(name, klass, argc)
    target, known = closed_world_lookup_target(name, klass, Set.new, any_visibility: true)
    return 'unknown_lookup' unless known
    return(@closed_world.outside_names.include?(name) ? 'absent_or_native' : 'absent') unless target
    return 'native_send' if target.owner == '<native>'
    return direct_callable?(target, argc) ? 'ruby_direct' : 'ruby_not_direct' if target.irep

    "accessor:#{target.kind}"
  end

  def self.write(path)
    File.write(path, "#{ROWS.values.join("\n")}\n")
  end
end

CodeGen.prepend(ReceiverProofReport)
at_exit { ReceiverProofReport.write(ENV.fetch('BC2CPP_RECEIVER_PROOF_REPORT')) }
