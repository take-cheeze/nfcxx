# frozen_string_literal: true

require 'set'
require_relative 'call_facts'

# Debug report for the by-name sites a per-class native arm could remove (ADR 0323): with
# BC2CPP_NATIVE_ARMS_REPORT=<path>, every explicit-receiver send whose final code still reaches a by-name call
# is written as one TSV row (the last compile of a site wins). It changes no generated code.
#
#   irep idx gem fn name argc op byname else kept src set kinds cells gates levers installs
#
# `src` is how the receiver class set S was bounded: proven (exact-class flow), facts (CALL_FACTS, whatever
# the members), unbounded_facts (the facts name nothing finite) or none. `cells` is, per class of S, what a
# table or arm cell would be: ruby_direct, native_direct, native_core_direct, native_noentry (a native with no
# frame-independent entry: the cell would be a send), error (the class does not answer), and so on. `gates`
# are the whole-name ClosedWorld gates that fail today; `levers` are the same gates re-judged against S (the
# per-class proofs ADR 0315 asks for). scripts/bc2cpp_native_arms_report.rb aggregates the rows.
module NativeArmsReport
  ROWS = {}
  BY_NAME = /\bbc2cpp_send\(|\bmrb_funcall\w*\(|\bbc2cpp_funcall_(?:argv|noarg|explicit)\(/
  ENGINE_GEMS = %w[mruby-rpg2k mruby-lcf mruby-rgss].freeze
  CHAIN_FAMILIES = %w[TYPED IVAR_ACCESSOR MONO_EMBED_GUARD POLY_SMALL_N POLY_TABLE ELEMENT POLY].freeze
  @world = nil
  class << self
    attr_accessor :world
  end

  def guarded_fallback_line(d, recv, name, argv, listed, site)
    line = super
    (@arms_fallbacks ||= []) << { listed: listed.dup, site: site, argc: argv.size }
    line
  end

  def compile_send(insn, **kwargs)
    outer = @arms_fallbacks
    @arms_fallbacks = []
    code = super
    fallbacks = @arms_fallbacks
    @arms_fallbacks = outer
    irep = kwargs[:irep]
    site = kwargs[:idx] || kwargs[:trace_idx]
    return code unless irep && site && !kwargs[:self_implicit] && %w[SEND SEND0 SENDB].include?(insn.op)

    lines = code.each_line.reject { |l| l.lstrip.start_with?('//') }
    return code unless lines.any? { |l| l.match?(BY_NAME) }

    NativeArmsReport.world = self
    ROWS[[irep.label, site]] = arms_row(insn, kwargs, irep, site, code, fallbacks.last, lines)
    code
  end

  private

  def arms_gem(irep)
    ENGINE_GEMS.find { |g| irep.file.to_s.include?("/#{g}/") } || (irep.file.to_s.include?('/3rd/mruby/') ? 'core' : 'other')
  end

  def arms_kind(klass)
    answers = call_facts_answers
    if klass == CallFacts::CLASS_OBJECT then 'classobj'
    elsif CallFacts::CORE_SUPER.key?(klass) then 'core'
    elsif answers.native_class_names.include?(klass) && !@closed_world.class_declared?(klass) then 'native'
    else 'user'
    end
  end

  # [src, classes or nil]
  def arms_set(cw_site, name)
    exact = cw_site && receiver_instances(cw_site, name)
    return ['proven', exact.sort] if exact
    return ['none', nil] unless cw_site && call_facts_enabled? && @native_results_ready

    irep = cw_site[:irep]
    insn = cw_site[:insn]
    return ['none', nil] unless irep && insn&.sym == name && %w[SEND SEND0].include?(insn.op)

    reg = insn.reg.to_i
    return ['none', nil] if reg >= irep.nregs.to_i || fixnum_proof_ctx(irep)[:upvars].include?(reg.to_s)

    states = call_facts_states(irep)
    names = states && CallFacts::Flow.facts(states[cw_site[:idx]], reg)
    return ['none', nil] if names.nil? || names.empty?

    sets = names.filter_map { |m| call_facts_answers.members(m) }
    return ['unbounded_facts', nil] if sets.empty?

    set = sets.reduce(:&)
    ['facts', set.to_a.sort]
  end

  def arms_cell(name, klass, argc)
    answers = call_facts_answers
    return 'classobj' if klass == CallFacts::CLASS_OBJECT
    return 'error' unless answers.answers?(klass, name)
    return 'method_missing' if answers.method_missing_classes.include?(klass)

    simple = klass.split('::').last
    if @closed_world.class_declared?(klass)
      target, known = closed_world_lookup_target(name, klass, Set.new, any_visibility: true)
      return 'unknown_lookup' unless known
      return(direct_callable?(target, argc) ? 'ruby_direct' : 'ruby_not_direct') if target&.irep
      return "accessor:#{target.kind}" if target && target.owner != '<native>'
    elsif @registry.fetch(name, []).any? { |d| d.owner == klass && d.owner != '<native>' }
      target, known = closed_world_lookup_target(name, klass, Set.new, any_visibility: true)
      return(known && target&.irep && direct_callable?(target, argc) ? 'ruby_direct' : 'ruby_not_direct') if target
    end
    arms_native_cell(name, simple, argc)
  end

  # A direct entry whose argument needs a type guard keeps a by-name else for the other arguments (the real
  # method raises its own TypeError), so it is a relocation, not a removal.
  def arms_native_cell(name, simple, argc)
    direct = (NativeDirect::ENTRIES[name] || {}).find { |o, e| o.split('::').last == simple && e.kinds.size == argc }&.last
    return(direct.kinds.include?(:int) ? 'native_direct_guarded' : 'native_direct') if direct

    core = NativeCoreDirect::ENTRIES.find { |e| e.name == name && e.owner == simple && e.arity == argc }
    return(core.arg == :none ? 'native_core_direct' : 'native_core_direct_guarded') if core

    d = call_facts_answers.definers(name)
    return 'unbounded' if d.nil?
    return 'foreign_ruby' if d[:foreign].include?(simple) && !d[:native].include?(simple)

    d[:native].include?(simple) || d[:native].empty? ? 'native_noentry' : 'inherited_native_noentry'
  end

  def arms_row(insn, kwargs, irep, site, code, fb, lines)
    name = insn.sym
    argc = insn.argc.to_i
    kept = code.scan(/CLOSED_WORLD kept: (\w+)/).flatten.uniq
    else_kind = if code.include?('bc2cpp_nomethod_named') then 'nomethod'
                elsif code.include?('bc2cpp_guard_violation') then 'violation'
                elsif !kept.empty? then "kept:#{kept.join('+')}"
                else 'send'
                end
    cw_site = (fb && fb[:site]) || closed_world_site("r#{insn.reg.to_i}", irep, site, kwargs[:owner_def])
    src, set = arms_set(cw_site, name)
    kinds = set ? set.map { |k| arms_kind(k) }.uniq.sort.join('+') : '-'
    cells = set ? set.map { |k| "#{k}=#{arms_cell(name, k, argc)}" }.join('|') : '-'
    owner_def = kwargs[:owner_def]
    [irep.label, site, arms_gem(irep), owner_def ? "#{owner_def.owner}##{owner_def.name}" : '-', name, argc, insn.op,
     lines.count { |l| l.match?(BY_NAME) }, else_kind, kept.join('+').then { |s| s.empty? ? '-' : s }, src,
     set ? set.join(',') : '-', kinds, cells, arms_gates(name, fb, set).join(','), arms_levers(name, fb, set, src).join(','),
     CHAIN_FAMILIES.find { |f| code.match?(%r{^\s*// #{f}\b}) } || '-'].join("\t")
  end

  # Whole-name gates, as ClosedWorld#refusal judges them today (instances nil).
  def arms_gates(name, fb, set)
    cw = @closed_world
    return ['no_closed_world'] unless cw && fb

    out = []
    installed = symbol_installed_names
    out << 'dynamic_install' if installed.nil? || installed.include?(name)
    out << 'unknown_definer' if cw.unknown_def?(name)
    out << 'core_or_native' if cw.outside_names.include?(name) && !cw.send(:native_arms_lift?, name)
    reason, required = cw.send(:required_classes, name, !set.nil?)
    out << reason.to_s if reason
    out << 'unlisted_class' if !reason && !required.subset?(fb[:listed].to_set)
    out << 'method_missing_receiver' unless cw.send(:method_missing_free?, fb[:site] && fb[:site][:self_owner], set)
    out
  end

  # The gates re-judged for the proven set: scoped_ok (the listed classes cover S), native_ok (no member needs a
  # native cell the build does not have), plus the class-object install scope of the name.
  def arms_levers(name, fb, set, _src)
    cw = @closed_world
    return [] unless cw && fb && set

    out = []
    reason, required = cw.send(:required_classes, name, true)
    out << "opaque:#{reason}" if reason
    out << 'unlisted_whole' if !reason && !required.subset?(fb[:listed].to_set)
    out << 'unlisted_scoped' if !reason && !(required & set.to_set).subset?(fb[:listed].to_set)
    answers = call_facts_answers
    out << 'native_reaches_S' unless set.all? { |k| answers.native_free?(k, name) }
    out << 'perclass_blocked' unless set.all? { |k| arms_resolves_in_ruby?(k, name) }
    out << 'unbounded_name' if answers.definers(name).nil?
    out
  end

  # Per-class resolution (proof 2 of ADR 0315): the first definer of +name+ along +klass+'s ancestors is a Ruby
  # definition of the registry, or no ancestor defines it (a NoMethodError), so a native or outside definer
  # further up cannot be reached.
  def arms_resolves_in_ruby?(klass, name)
    answers = call_facts_answers
    return true unless answers.answers?(klass, name)

    d = answers.definers(name)
    return false if d.nil? || answers.method_missing_classes.include?(klass)

    anc, unknown = answers.ancestors(klass)
    return false if unknown

    first = anc.find { |a| d[:ruby].include?(a) || d[:native].include?(a) || d[:foreign].include?(a) || d[:modules].include?(a) }
    !first.nil? && d[:ruby].include?(first) && !d[:native].include?(first) && !d[:foreign].include?(first)
  end

  # name -> ["file:line", ...] of every ALIAS/UNDEF/alias_method/define_method/undef_method/remove_method and of
  # every DEF the registry did not register (ClosedWorld's unknown definers).
  def arms_install_sites
    children = @ireps.values.flat_map(&:reps).compact.to_set
    sites = Hash.new { |h, k| h[k] = [] }
    registered = Set.new
    @registry.each_value { |defs| defs.each { |d| registered << d.irep if d.irep } }
    @ireps.each do |label, irep|
      next if children.include?(label) && CoreDefs.core_source?(irep.file)

      irep.instructions.each_with_index do |insn, idx|
        case insn.op
        when 'ALIAS', 'UNDEF'
          sites[insn.sym] << "#{irep.file}:#{insn.lineno}"
        when 'DEF'
          method = irep.instructions[0...idx].reverse.find { |i| i.op == 'METHOD' }
          child = method && irep.reps[method.block_index.to_i]
          sites[insn.sym_token] << "#{irep.file}:#{insn.lineno}" unless child && registered.include?(child)
        when 'SEND', 'SEND0', 'SENDB', 'SSEND', 'SSEND0', 'SSENDB'
          next unless CodeGen::NAME_INSTALLER_SENDS.include?(insn.sym)

          syms = insn.plain_fixed_argc? && literal_symbol_args(irep, idx, insn.reg.to_i, insn.argc)
          (syms || ['<computed>']).each { |s| sites[s] << "#{irep.file}:#{insn.lineno}" }
        end
      end
    end
    sites
  end

  def self.write(path)
    File.write(path, "#{ROWS.values.join("\n")}\n")
    cg = world
    return unless cg

    lines = cg.send(:arms_install_sites).map { |name, sites| [name, sites.uniq.join(';')].join("\t") }
    File.write("#{path}.installs", "#{lines.join("\n")}\n")
    File.write("#{path}.names", "#{cg.send(:arms_name_rows).join("\n")}\n")
  end

  # name, Ruby instance owners, Ruby singleton owners, native owners (class names), outside Ruby owners.
  def arms_name_rows
    answers = call_facts_answers
    @registry.map do |name, defs|
      ruby = defs.reject { |d| d.owner == '<native>' }
      d = answers.definers(name)
      [name, ruby.count { |x| !x.owner.end_with?('.singleton') }, ruby.count { |x| x.owner.end_with?('.singleton') },
       d ? d[:native].to_a.sort.join(',') : '?', d ? d[:foreign].to_a.sort.join(',') : '?'].join("\t")
    end
  end
end

CodeGen.prepend(NativeArmsReport)
at_exit { NativeArmsReport.write(ENV.fetch('BC2CPP_NATIVE_ARMS_REPORT')) }
