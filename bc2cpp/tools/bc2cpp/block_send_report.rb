# frozen_string_literal: true

require 'set'
require_relative 'call_facts'
require_relative 'block_send_report_columns'

# Debug report for block sends (ADR 0325): with BC2CPP_BLOCK_SEND_REPORT=<path>, every literal-block and `&expr`
# send of the generated code is written as one TSV row (the last compile of a site wins) with what keeps its
# dynamic `mrb_funcall_with_block` and what each candidate lever would do to it. It changes no generated code;
# scripts/bc2cpp_block_send_report.rb aggregates it.
#
# Columns (BlockSendReport::COLUMNS):
#   - kind: `literal` (a BLOCK region) or `explicit` (`&expr`, no body).
#   - shape: what the glue text is: `removed` (the compiled call alone), `proven_guarded` (proven class arm, else kept
#     for the Fiber guard), `exact_arms` (exact-class arms in front of the dynamic send), `mono_direct` (one
#     resolved call, maybe with a chain else), `dynamic` (by-name only), `explicit`.
#   - existing: the receiver classes the exact-class flow proves (`unproven` otherwise).
#   - facts / fact_kind / fact_usable: the names an earlier call on the same value answered, the kinds of classes
#     that can answer all of them (`user`, `core`, `native`, mixed) and whether CALL_FACTS would accept the set.
#   - entry, free, free_if_entry: the block has a direct entry, is proved yield-free, would be yield-free.
#   - arms: the exact core classes that have a compiled arm for the name, with `+` when the body is relaxable.
#   - why: why a name has no core arm (first failing gate per class).
module BlockSendReport
  ROWS = {}
    BY_NAME = /\bbc2cpp_send\(|\bmrb_funcall\w*\(|\bbc2cpp_funcall_(?:argv|noarg|explicit)\(/

  def emit_block_fallback_glue(region, fn_name, **options)
    out = super
    BlockSendReport.record(self, region, out, options) unless options[:inline_offset]
    out
  end

  def emit_explicit_block_arg_glue(region)
    out = super
    BlockSendReport.record_explicit(self, region, out)
    out
  end

  def self.gem_of(irep)
    ENGINE_GEMS.find { |g| irep.file.to_s.include?("/#{g}/") } || (irep.file.to_s.include?('/3rd/mruby/') ? 'core' : 'other')
  end

  def self.shape_of(out)
    live = out.lines.reject { |l| l.lstrip.start_with?('//') }.join
    marker = out[%r{// BLOCK_CORE_DIRECT :\S+ -- (.*)}, 1].to_s
    shape = if marker.include?('no dynamic send') then 'removed'
            elsif marker.start_with?('proven') then 'proven_guarded'
            elsif marker.start_with?('exact') then 'exact_arms'
            elsif live.match?(/\b\w+_impl\(M/) then 'mono_direct'
            else 'dynamic'
            end
    [shape, marker, live.lines.count { |l| l.match?(BY_NAME) }]
  end

  def self.record(cg, region, out, options)
    irep = region[:parent_irep] or return
    idx = irep.instructions.index { |insn| insn.addr == region[:sendb_addr] } or return
    shape, marker, byname = shape_of(out)
    ROWS[[irep.label, idx]] = cg.block_send_row(region, irep, idx, 'literal', shape, marker, byname, options[:owner_def])
  end

  def self.record_explicit(cg, region, out)
    live = out.lines.reject { |l| l.lstrip.start_with?('//') }
    irep = cg.block_send_current_irep
    return unless irep

    idx = irep.instructions.index { |insn| insn.addr == region[:sendb_addr] } or return
    ROWS[[irep.label, idx]] = cg.block_send_row(region.merge(parent_irep: irep), irep, idx, 'explicit', 'explicit', '',
                                                live.count { |l| l.match?(BY_NAME) }, nil)
  end

  def block_send_current_irep
    @block_send_irep
  end

  def compile_method(label)
    saved = @block_send_irep
    @block_send_irep = @ireps[label]
    super
  ensure
    @block_send_irep = saved
  end

  # Facts of the receiver register at the send: [names, [kind, classes, usable]].
  def block_send_facts(irep, idx, reg)
    return [[], ['-', [], false]] unless @closed_world && @native_name_sources && call_facts_states(irep) && reg < irep.nregs.to_i && !fixnum_proof_ctx(irep)[:upvars].include?(reg.to_s)

    names = CallFacts::Flow.facts(call_facts_states(irep)[idx], reg).to_a
    return [names, ['-', [], false]] if names.empty?

    answers = call_facts_answers
    sets = names.filter_map { |m| answers.members(m) }
    return [names, ['unbounded', [], false]] if sets.empty?

    set = sets.reduce(:&)
    kinds = set.map do |k|
      if CallFacts::CORE_SUPER.key?(k) then 'core'
      elsif answers.native_class_names.include?(k) && !@closed_world.class_declared?(k) then 'native'
      else 'user'
      end
    end.uniq.sort.join('+')
    kinds = 'empty' if set.empty?
    usable = !set.empty? && set.size <= CodeGen::CALL_FACTS_MAX_CLASSES && set.all? { |k| answers.user_instance?(k) }
    [names, [kinds, set.to_a.sort, usable]]
  end

  def block_send_arms(name, argc)
    arms = block_core_arms(name, argc)
    arms.map { |arm| "#{arm[:class]}#{core_body_relaxable?(arm[:target].irep) ? '+' : ''}" }
  end

  # Why each exact core class has no arm for `name`: collected on a scratch table so the build's own is untouched.
  def block_send_why(name, argc)
    saved = @block_core_reasons
    saved_env = ENV['BC2CPP_BLOCK_CORE_WHY']
    @block_core_reasons = Hash.new { |h, k| h[k] = [] }
    ENV['BC2CPP_BLOCK_CORE_WHY'] = '1'
    BlockCoreDirectFallback::RECEIVERS.each { |klass, spec| block_core_target(klass, spec[:chain], name, argc) }
    @block_core_reasons[[name, argc]].uniq.join('; ')
  ensure
    @block_core_reasons = saved
    ENV['BC2CPP_BLOCK_CORE_WHY'] = saved_env
  end

  # The nearest textual writer of the receiver register: `ivar:@x`, `send:name`, `incoming_arg`, `const:X`, ...
  def block_send_producer(irep, idx, reg)
    found = irep.walk_writers(idx - 1, reg.to_s, skip_ops: ['BLOCK', *READ_ONLY_OPCODE_SKIP], follow_moves: true,
                                                 exhausted: ->(last) { last == '0' ? 'self' : 'incoming_arg' }) do |ins, i|
      case ins.op
      when 'SEND', 'SEND0', 'SENDB', 'SSEND', 'SSEND0', 'SSENDB'
        ins.sym == 'new' ? "new(#{irep.agreed_constant_name(i, ins.reg.to_s) || '?'})" : "send:#{ins.sym}"
      when 'GETIV' then "ivar:#{ins.ivar}"
      when 'GETCONST' then "const:#{ins.sym}"
      else ins.op.downcase
      end
    end
    found.is_a?(String) ? found : 'unknown'
  end

  def block_send_row(region, irep, idx, kind, shape, marker, byname, owner_def)
    name = region[:name]
    argc = region[:n].to_s
    reg = region[:dest_reg].to_i
    real = irep.instructions[idx]
    site = { irep: irep, idx: idx, insn: Insn.synthetic('SEND', "R#{reg} :#{name} n=#{region[:n]}") }
    existing = begin
      receiver_instances(site, name)
    rescue StandardError => e
      warn "[block_send_report] #{irep.label}:#{idx}: #{e.message}"
      nil
    end
    facts, (fkind, fset, fusable) = region[:self_implicit] ? [[], ['-', [], false]] : block_send_facts(irep, idx, reg)
    entry = region[:direct_entry] ? 1 : 0
    block_irep = region[:block_irep]
    free = kind == 'literal' && block_irep && yield_free_block?(block_irep) ? 1 : 0
    modelled = argc.match?(/\A\d+\z/) && block_core_world && @native_name_sources
    arms = modelled ? block_send_arms(name, argc.to_i) : []
    why = modelled && arms.empty? ? block_send_why(name, argc.to_i) : ''
    [irep.label, idx, BlockSendReport.gem_of(irep), owner_def ? "#{owner_def.owner}##{owner_def.name}" : '-', kind, name, argc,
     shape, existing ? existing.sort.join('|') : 'unproven', facts.join(','), fkind, fset.join('|'), fusable ? 1 : 0,
     entry, entry.positive? ? (region[:yield_free] ? 1 : 0) : 0, free, region[:needs_brk] ? 1 : 0, region[:needs_ret] ? 1 : 0,
     region[:self_source] || '-', arms.join(','), why, byname, marker,
     region[:self_implicit] ? 'self' : block_send_producer(irep, idx, reg), "#{irep.file}:#{real.lineno}"].join("\t")
  end

  def self.write(path)
    File.write(path, "#{ROWS.values.join("\n")}\n")
  end
end

CodeGen.prepend(BlockSendReport)
at_exit { BlockSendReport.write(ENV.fetch('BC2CPP_BLOCK_SEND_REPORT')) }
