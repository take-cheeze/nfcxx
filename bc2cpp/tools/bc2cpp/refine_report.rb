# frozen_string_literal: true

require 'set'
require_relative 'call_facts'
require_relative 'refine_report_columns'

# Debug report for CALL_FACTS (ADR 0317): with BC2CPP_REFINE_REPORT=<path>, every explicit-receiver send of the
# generated code is written as one TSV row (the last compile of a site wins), with what the call facts prove
# about its receiver and what that would do to its by-name dispatch. It changes no generated code.
#
# Columns (scripts/bc2cpp_refine_report.rb aggregates them, see COLUMNS):
#   - existing: `proven:<classes>` when the exact-class flow already proves the receiver set.
#   - facts: the names an earlier call on the same value answered on every path (the FORWARD interface, sound).
#   - web: every name called on the value anywhere in the method (the BACKWARD interface, unsound for codegen:
#     a later NoMethodError would surface at the first call; an upper bound and a lint candidate only).
#   - verdict, for facts and for the web: none (no name), unbounded (no name bounds the class set), empty (no
#     class answers every name), error (no class of the set answers this send's name), removal (every class that
#     answers the name does so by a Ruby body and is listed or guardable: the by-name else is dead), gain_foreign
#     (a native or outside definer reaches the set), gain_unlisted (too many unlisted classes).
#   - usable: the set is what the build would accept (declared classes only, at most CALL_FACTS_MAX_CLASSES).
#   - single: the best verdict one fact alone gives (a multi-name interface is better when it beats this).
# Unlike the build, the report also judges SENDB sites. <path>.chains has one row per guard chain: how many of
# its classes resolve to a definition another class of the chain also reaches.
module RefineReport
  ROWS = {}
  CHAINS = {}
  BY_NAME = /\bbc2cpp_send\(|\bmrb_funcall\w*\(|\bbc2cpp_funcall_(?:argv|noarg|explicit)\(/
  CHAIN_FAMILIES = %w[TYPED IVAR_ACCESSOR MONO_EMBED_GUARD POLY_SMALL_N POLY_TABLE ELEMENT POLY].freeze
  RANK = { 'removal' => 5, 'gain_unlisted' => 4, 'gain_foreign' => 3, 'error' => 2, 'empty' => 1 }.freeze

  def guarded_fallback_line(d, recv, name, argv, listed, site)
    line = super
    (@refine_fallbacks ||= []) << { listed: listed.dup }
    line
  end

  def compile_send(insn, **kwargs)
    outer = @refine_fallbacks
    @refine_fallbacks = []
    code = super
    fallbacks = @refine_fallbacks
    @refine_fallbacks = outer
    irep = kwargs[:irep]
    site = kwargs[:idx] || kwargs[:trace_idx]
    return code unless irep && site && !kwargs[:self_implicit] && %w[SEND SEND0 SENDB].include?(insn.op)

    ROWS[:codegen] = self
    lines = code.each_line.reject { |l| l.lstrip.start_with?('//') }
    ROWS[[irep.label, site]] = {
      label: irep.label, site: site, name: insn.sym, op: insn.op, owner_def: kwargs[:owner_def],
      plain: insn.n_spec != '*' && !insn.nk_spec, argc: insn.argc,
      byname: lines.count { |l| l.match?(BY_NAME) }, nomethod: code.include?('bc2cpp_nomethod_named'),
      sample: lines.find { |l| l.match?(BY_NAME) }.to_s.strip[0, 150],
      family: CHAIN_FAMILIES.find { |f| code.match?(%r{^\s*// #{f}\b}) } || '-',
      kept: code.scan(/CLOSED_WORLD kept: (\w+)/).flatten.uniq, listed: fallbacks.last ? fallbacks.last[:listed] : []
    }
    code
  end

  def refine_gem(irep)
    ENGINE_GEMS.find { |g| irep.file.to_s.include?("/#{g}/") } || (irep.file.to_s.include?('/3rd/mruby/') ? 'core' : 'other')
  end

  def refine_kind(set)
    return 'empty' if set.empty?

    set.map do |k|
      if k == CallFacts::CLASS_OBJECT then 'classobj'
      elsif CallFacts::CORE_SUPER.key?(k) then 'core'
      elsif call_facts_answers.native_class_names.include?(k) && !@closed_world.class_declared?(k) then 'native'
      else 'user'
      end
    end.uniq.sort.join('+')
  end

  # Hash for one site judged under +names+ (an interface), see the header for the verdicts.
  def refine_verdict(row, names)
    none = { verdict: 'none', size: 0, kind: '-', tsize: 0, tkind: '-', set: [], target: [], usable: false }
    return none if names.nil? || names.empty?

    answers = call_facts_answers
    sets = names.filter_map { |m| answers.members(m) }
    return none.merge(verdict: 'unbounded') if sets.empty?

    set = sets.reduce(:&)
    name = row[:name]
    target = set.select { |k| answers.answers?(k, name) }
    usable = !set.empty? && set.size <= CodeGen::CALL_FACTS_MAX_CLASSES && set.all? { |k| answers.user_instance?(k) }
    base = { size: set.size, kind: refine_kind(set), tsize: target.size, tkind: refine_kind(target), set: set.to_a.sort,
             target: target.to_a.sort, usable: usable }
    return base.merge(verdict: 'empty') if set.empty?
    return base.merge(verdict: 'error') if target.empty?

    unlisted = target.reject { |k| row[:listed].include?(k) }
    verdict = if !target.all? { |k| answers.user_instance?(k) && answers.native_free?(k, name) } then 'gain_foreign'
              elsif unlisted.size > 8 || !unlisted.all? { |k| @closed_world.stable_class_constant?(k) } then 'gain_unlisted'
              else 'removal'
              end
    base.merge(verdict: verdict)
  end

  # The best verdict a single fact gives, preferring one the build would accept.
  def refine_single(row, facts)
    best = nil
    facts.each do |m|
      v = refine_verdict(row, [m])
      score = [v[:usable] ? 1 : 0, RANK.fetch(v[:verdict], 0)]
      best = [score, v] if best.nil? || (score <=> best[0]) == 1
    end
    best ? best[1] : refine_verdict(row, nil)
  end

  # site index -> every name called on the value its receiver may be, anywhere in +irep+: values are the
  # writers that reach a receiver (through MOVEs), merged when one send can see several of them.
  def refine_webs(irep)
    @refine_web_cache ||= {}
    @refine_web_cache[irep.label] ||= begin
      program = BytecodeIR.for(irep)
      opaque = fixnum_proof_ctx(irep)[:upvars]
      parent = Hash.new { |h, k| h[k] = k }
      find = ->(k) { parent[k] == k ? k : (parent[k] = find.call(parent[k])) }
      uses = {}
      irep.instructions.each_with_index do |insn, i|
        next unless %w[SEND SEND0 SENDB].include?(insn.op) && insn.sym

        defs = program.reaching_definitions(i, insn.reg, opaque_regs: opaque)
        next if defs.nil? || defs.empty?

        keys = defs.map { |d| d.entry? ? "entry#{d.reg}" : d.index.to_s }
        keys.each { |k| parent[find.call(k)] = find.call(keys.first) }
        uses[i] = keys.first
      end
      names = Hash.new { |h, k| h[k] = Set.new }
      uses.each { |i, key| names[find.call(key)] << irep.instructions[i].sym }
      uses.transform_values { |key| names[find.call(key)].to_a.sort }
    end
  end

  def refine_report_rows(rows)
    rows.filter_map do |row|
      irep = @ireps[row[:label]]
      real = irep.instructions[row[:site]]
      next unless irep && real && %w[SEND SEND0 SENDB].include?(real.op) && real.sym == row[:name]

      reg = real.reg.to_i
      owner_def = row[:owner_def]
      site = closed_world_site("r#{reg}", irep, row[:site], owner_def)
      existing = receiver_instances(site, row[:name]) if site
      states = call_facts_states(irep)
      usable = states && reg < irep.nregs.to_i && !fixnum_proof_ctx(irep)[:upvars].include?(reg.to_s)
      facts = usable ? CallFacts::Flow.facts(states[row[:site]], reg).to_a : []
      fwd = refine_verdict(row, facts)
      single = refine_single(row, facts)
      web = refine_webs(irep)[row[:site]]
      bwd = refine_verdict(row, web)
      chain_row(irep, row)
      [irep.label, row[:site], refine_gem(irep), owner_def ? "#{owner_def.owner}##{owner_def.name}" : '-', row[:op],
       row[:name], row[:argc], row[:plain] ? 'plain' : 'splat_or_kw',
       existing ? "proven:#{existing.sort.join('|')}" : 'unproven', row[:byname], row[:nomethod] ? 'nomethod' : '-',
       row[:kept].join('+').then { |s| s.empty? ? '-' : s }, row[:listed].size, facts.join(','),
       fwd[:verdict], fwd[:size], fwd[:kind], fwd[:tsize], fwd[:tkind], fwd[:set].join(','), fwd[:target].join(','),
       fwd[:usable] ? 1 : 0, single[:verdict], single[:usable] ? 1 : 0, web.to_a.join(','), bwd[:verdict], bwd[:size],
       bwd[:usable] ? 1 : 0, bwd[:kind], bwd[:set].join(','), bwd[:target].join(','), "#{irep.file}:#{real.lineno}",
       row[:listed].join(','), row[:family], row[:sample]].join("\t")
    end
  end

  # Classes of one guard chain that reach the same definition (a shared arm or a class-id interval could
  # replace their separate compares).
  def chain_row(irep, row)
    return if row[:listed].size < 2 || row[:family] == '-'

    groups = row[:listed].group_by do |klass|
      target, known = closed_world_lookup_target(row[:name], klass, Set.new, any_visibility: true)
      known && target ? "#{target.owner}##{target.name}@#{target.irep || target.kind}" : "unknown:#{klass}"
    end
    CHAINS[[irep.label, row[:site]]] = [irep.label, row[:site], row[:name], row[:family], row[:listed].size,
                                        groups.size, groups.values.map(&:size).sort.reverse.join(',')].join("\t")
  end

  def self.write(path)
    cg = ROWS.delete(:codegen)
    File.write(path, "#{(cg ? cg.refine_report_rows(ROWS.values) : []).join("\n")}\n")
    File.write("#{path}.chains", "#{CHAINS.values.join("\n")}\n")
  end
end

CodeGen.prepend(RefineReport)
at_exit { RefineReport.write(ENV.fetch('BC2CPP_REFINE_REPORT')) }
