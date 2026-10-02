# frozen_string_literal: true

# Debug report for the interface-table question (ADR 0315): with BC2CPP_ITAB_REPORT=<path>, every
# explicit-receiver send whose guard chain has an else arm is written as one TSV row (the last compile of
# a site wins). Columns:
#
#   fn irep idx name argc block family else gates set origin origin_ivar listed cells native
#
# `else` is the arm the chain ended in (nomethod, kept:<reason>, send, violation, no_dispatch). `gates` lists
# EVERY ClosedWorld#refusal gate the name fails, not only the first one, so a site blocked by exactly one
# gate is visible. `set` is the receiver's proven instance classes (CodeGen#receiver_instances) or
# `unproven:<mask>`. `cells` says, per class of a proven set, what an interface-table cell would be.
# scripts/bc2cpp_interface_table_report.rb aggregates it.
module InterfaceTableReport
  ROWS = {}
  @names_source = nil
  class << self
    attr_accessor :names_source
  end
  CHAIN_FAMILIES = %w[TYPED IVAR_ACCESSOR MONO_EMBED_GUARD POLY_SMALL_N POLY_TABLE ELEMENT POLY].freeze

  def guarded_fallback_line(d, recv, name, argv, listed, site)
    line = super
    InterfaceTableReport.names_source = [@registry, @closed_world] if @closed_world
    (@itab_fallbacks ||= []) << { name: name, argc: argv.size, listed: listed.dup, site: site, line: line }
    line
  end

  def compile_send(insn, **kwargs)
    outer = @itab_fallbacks
    @itab_fallbacks = []
    code = super
    fallbacks = @itab_fallbacks
    @itab_fallbacks = outer
    irep = kwargs[:irep]
    site = kwargs[:idx] || kwargs[:trace_idx]
    return code unless irep && site && !kwargs[:self_implicit] && insn.n_spec != '*' && !insn.nk_spec
    return code if fallbacks.empty?

    family = CHAIN_FAMILIES.find { |f| code.match?(%r{^\s*// #{f}\b}) } || 'OTHER'
    fb = fallbacks.last
    ROWS[[irep.label, site]] = row(insn, kwargs, irep, site, family, fb, code)
    code
  end

  private

  def row(insn, kwargs, irep, site, family, fb, code)
    name = insn.sym
    kept = code.scan(/CLOSED_WORLD kept: (\w+)/).flatten.uniq
    else_kind = if code.include?('bc2cpp_nomethod_named') then 'nomethod'
                elsif code.include?('bc2cpp_guard_violation') then 'violation'
                elsif !kept.empty? then "kept:#{kept.join('+')}"
                elsif code.match?(/\bmrb_funcall(?:_id|_with_block)?\(M,/) then 'send'
                else 'no_dispatch'
                end
    reg = unshift_proof_reg(kwargs[:trace_receiver_reg] || insn.reg, kwargs[:trace_reg_offset] || 0)
    mask = exact_flow_mask(irep, site, reg)
    cw_site = fb[:site]
    instances = cw_site ? receiver_instances(cw_site, name) : nil
    set = instances ? instances.sort.join('|') : "unproven:#{mask.nil? ? 'unmodelled' : class_mask_name(mask)}"
    nilable = code.include?('// NILABLE_RECEIVER') ? '+nilable' : ''
    owner_def = kwargs[:owner_def]
    [owner_def ? "#{owner_def.owner}##{owner_def.name}" : irep.label, irep.label, site, name, fb[:argc],
     insn.op.end_with?('B') ? 'block' : '-', family, else_kind, gates(name, fb, instances).join(','),
     set + nilable, receiver_trace_origin(irep, site, reg), origin_ivar(irep, site, reg, owner_def),
     fb[:listed].join('|'), cells(name, fb, instances), native_detail(name)].join("\t")
  end

  # Every refusal gate the name fails, in ClosedWorld#refusal's order.
  def gates(name, fb, instances)
    cw = @closed_world
    return ['no_closed_world'] unless cw

    out = []
    out << "global:#{cw.global_refusal}" if cw.global_refusal
    installed = symbol_installed_names
    out << 'dynamic_install' if installed.nil? || installed.include?(name)
    out << 'unknown_definer' if cw.instance_variable_get(:@unknown_defs).include?(name)
    out << 'core_or_native' if cw.outside_names.include?(name) && !native_arms_lift_for?(name)
    self_owner = fb[:site] && fb[:site][:self_owner]
    reason, required = cw.send(:required_classes, name, cw.send(:instance_self?, self_owner) || !instances.nil?)
    out << reason.to_s if reason
    out << 'unlisted_class' if !reason && !required.subset?(fb[:listed].to_set)
    out << 'method_missing_receiver' unless cw.send(:method_missing_free?, self_owner, instances)
    out
  end

  def native_arms_lift_for?(name)
    @closed_world.send(:native_arms_lift?, name)
  end

  # Per class of a proven set: what its interface-table cell would be.
  def cells(name, fb, instances)
    return '-' unless instances

    instances.sort.map do |klass|
      "#{klass}=#{cell_kind(name, klass, fb[:argc])}"
    end.join('|')
  end

  def cell_kind(name, klass, argc)
    native_owners = (NativeDirect::ENTRIES[name] || {}).select { |_o, e| e.kinds.size == argc }.keys
    return 'native_direct' if native_owners.include?(klass)
    return 'native_core_direct' if NativeCoreDirect::ENTRIES.any? { |e| e.name == name && e.owner == klass && e.arity == argc }

    target, known = closed_world_lookup_target(name, klass, Set.new, any_visibility: true)
    return 'unknown_lookup' unless known
    unless target
      return @closed_world.outside_names.include?(name) ? 'absent_or_native' : 'absent'
    end
    return 'native_send' if target.owner == '<native>'
    return direct_callable?(target, argc) ? 'ruby_direct' : 'ruby_not_direct' if target.irep

    "accessor:#{target.kind}"
  end

  # Where the name is registered natively: the files spelling it and whether an audited direct entry exists.
  def native_detail(name)
    cw = @closed_world
    return '-' unless cw

    paths = cw.send(:native_paths_spelling, name).map do |path|
      path.sub(%r{.*/(3rd/mruby/|mruby-[\w-]+/|include/|src/)}, '\1').sub(%r{\A(3rd/mruby/)(mrbgems/[\w-]+|src)/.*}, '\1\2')
    end.uniq
    parts = []
    parts << "files=#{paths.join('+')}" unless paths.empty?
    parts << 'ruby_outside' if cw.instance_variable_get(:@outside_ruby_names).include?(name)
    direct = NativeDirect::ENTRIES[name]
    parts << "rgss_direct=#{direct.keys.join('+')}" if direct
    core = NativeCoreDirect::ENTRIES.select { |e| e.name == name }
    parts << "core_direct=#{core.map { |e| "#{e.owner}/#{e.arity}" }.join('+')}" unless core.empty?
    ruby = @registry.fetch(name, []).reject { |def_| def_.owner == '<native>' }.map(&:owner)
    parts << "ruby_owners=#{ruby.size}"
    parts.join(';')
  end

  def origin_ivar(irep, site, reg, owner_def)
    irep.walk_writers(site - 1, reg.to_s, skip_ops: ['BLOCK', *READ_ONLY_OPCODE_SKIP]) do |ins|
      next IrepScans.follow(ins.regs[1]) if ins.op == 'MOVE' && ins.regs[1]

      break "#{owner_def&.owner}#@#{ins.ivar}" if ins.op == 'GETIV'
    end.to_s
  end

  def self.write(path)
    File.write(path, "#{ROWS.values.join("\n")}\n")
    write_names("#{path}.names") if names_source
  end

  # name, ruby instance owners, ruby singleton owners, native?, outside name?: the per-name method-set sizes.
  def self.write_names(path)
    registry, world = names_source
    outside = world.outside_names
    lines = registry.map do |name, defs|
      ruby = defs.reject { |d| d.owner == '<native>' }
      single = ruby.count { |d| d.owner.end_with?('.singleton') }
      [name, ruby.size - single, single, defs.any? { |d| d.owner == '<native>' } ? 1 : 0, outside.include?(name) ? 1 : 0].join("\t")
    end
    File.write(path, "#{lines.join("\n")}\n")
  end
end

CodeGen.prepend(InterfaceTableReport)
at_exit { InterfaceTableReport.write(ENV.fetch('BC2CPP_ITAB_REPORT')) }
