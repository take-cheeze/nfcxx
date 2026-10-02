# frozen_string_literal: true

# Debug report for the shared escape analysis (ADR 0316): with BC2CPP_ESCAPE_REPORT=<path>, every
# creation site in the closed world (LAMBDA, BLOCK, ARRAY, HASH, STRING, `new`) and every `initialize`
# gets one TSV row. It changes no generated code; scripts/bc2cpp_escape_report.rb aggregates it.
#
#   site  irep_label:index  owner#method  engine|core  op  kind  verdict  reason  uses  today
#   self  irep_label        owner#method  engine|core  initialize  self  verdict  -  0  -
#
# `kind` is `lambda`, `block:<callee name>`, `array`, `hash`, `string` or `object`. `today` says what the
# compiler does with the site without the analysis: `rproc` (a BLOCK_FALLBACK RProc is built),
# `confined` (CONFINED_LAMBDA_CALL proof held), `lambda` (LAMBDA_FALLBACK without a proof), `-` (not
# an RProc site, or no code is emitted for it).
module EscapeReport
  CREATING = %w[LAMBDA BLOCK ARRAY ARRAY2 HASH STRING].freeze
  TODAY = {}
  LAMBDA_REGIONS = {}

  def initialize(*args, **options)
    super
    EscapeReport.codegen = self unless options[:analysis_only]
  end

  class << self
    attr_accessor :codegen
  end

  def emit_block_fallback_glue(region, fn_name, **options)
    TODAY[[region[:parent_irep].label, region[:block_addr]]] = 'rproc' if region[:parent_irep]
    super
  end

  def recognize_lambda_fallback_regions(irep, **options)
    regions = super
    regions.each { |r| LAMBDA_REGIONS[[irep.label, r[:block_addr]]] = r[:upvars].empty? ? 'lambda' : 'confined' }
    regions
  end

  def self.write(path)
    analyzer = codegen&.escape_analyzer or return
    world = analyzer.world
    ireps = world.ireps
    owner_of = owner_table(world)
    rows = []
    ireps.each_value do |irep|
      owner = owner_of[irep.label] || '?'
      origin = CoreDefs.core_source?(irep.file) ? 'core' : 'engine'
      irep.instructions.each_with_index do |insn, i|
        kind = site_kind(irep, i, insn) or next
        verdict = analyzer.creation(irep, i, value_class: constructed_class(world, irep, i, insn))
        today = TODAY[[irep.label, insn.addr]] || LAMBDA_REGIONS[[irep.label, insn.addr]] || '-'
        rows << ['site', "#{irep.label}:#{i}", owner, origin, insn.op, kind, verdict.escapes? ? 'escapes' : 'confined',
                 verdict.escapes? ? verdict.reason : '-', verdict.uses.count { |u| u.kind == :call }, today,
                 receiver_classes(analyzer, irep, i, insn)].join("\t")
      end
    end
    world.reflective_sites.each { |label, idx| rows << ['reflective', "#{label}:#{idx}", owner_of[label] || '?', '', '', '', '', '', 0, ''].join("\t") }
    world.dynamic_sites.each { |label, idx, what| rows << ['dynamic', "#{label}:#{idx}", owner_of[label] || '?', '', what, '', '', '', 0, ''].join("\t") }
    callee_rows(analyzer, world, rows)
    rows.filter_map { |r| r.split("\t").values_at(5, 10) if r.start_with?("site\t") }.uniq.each do |kind, classes|
      next unless kind.start_with?('block:') && classes != '-'

      list = world.defs_for(kind.sub('block:', ''), classes.split(','), true)
      rows << ['calleefor', kind, classes, Array(list).map { |d| "#{d.owner}:#{analyzer.captures?(d, [:block])}" }.join(' '), '', '', '', '', 0, ''].join("\t")
    end
    initialize_defs(world).each do |mdef|
      verdict = analyzer.captures?(mdef, [:self]) ? 'escapes' : 'confined'
      rows << ['self', mdef.irep, "#{mdef.owner}##{mdef.name}", ireps[mdef.irep] && CoreDefs.core_source?(ireps[mdef.irep].file) ? 'core' : 'engine',
               'initialize', 'self', verdict, '-', 0, '-'].join("\t")
    end
    File.write(path, "#{rows.join("\n")}\n")
  end

  # One row per definition of each callee name that receives a literal block: does its block position
  # capture? (`opaque` = a native or other body the analysis cannot read.)
  def self.callee_rows(analyzer, world, rows)
    names = rows.filter_map { |r| r.split("\t")[5][/\Ablock:(.*)\z/, 1] if r.start_with?("site\t") }.uniq
    names.each do |name|
      list = world.defs_named(name)
      native = world.native_name?(name)
      rows << ['callee', name, list ? list.size : 'dynamic', native ? 'native' : '-', '', '', '', '', 0, ''].join("\t")
      Array(list).each do |d|
        verdict = analyzer.captures?(d, [:block]) ? 'captures' : 'keeps-nothing'
        rows << ['calleedef', name, "#{d.owner}##{d.name}", d.irep ? 'bytecode' : (d.kind || 'opaque').to_s, d.installer.to_s,
                 verdict, '', '', 0, ''].join("\t")
      end
    end
  end

  # label => "Owner#name" of the method whose body (or nested block) the irep is.
  def self.owner_table(world)
    table = {}
    names = world.ireps.keys.to_h { |label| [label, nil] }
    world.instance_variable_get(:@defs).each do |name, list|
      list.each { |d| names[d.irep] = "#{d.owner}##{name}" if d.irep }
    end
    world.ireps.each_value do |irep|
      irep.reps.each { |child| table[child] ||= irep.label }
    end
    resolve = lambda do |label|
      names[label] || (table[label] && resolve.call(table[label]))
    end
    world.ireps.each_key.to_h { |label| [label, resolve.call(label)] }
  end

  def self.initialize_defs(world)
    world.instance_variable_get(:@defs).fetch('initialize', []).select(&:irep)
  end

  # The class a `Const.new` constructs when the world declares that constant as a class.
  def self.constructed_class(world, irep, index, insn)
    return nil unless %w[SEND SENDB].include?(insn.op) && insn.sym == 'new'

    name = irep.agreed_constant_name(index, insn.reg)
    name if name && world.class_known?(name)
  end

  # The classes the class flow gives the receiver of the send a BLOCK is passed to ("-" when none).
  def self.receiver_classes(analyzer, irep, index, insn)
    call = irep.instructions[index + 1]
    return '-' unless insn.op == 'BLOCK' && call && %w[SENDB SSENDB].include?(call.op) && call.op == 'SENDB'

    Array(analyzer.receiver_classes.call(irep, index + 1, call.reg)).join(',').then { |s| s.empty? ? '-' : s }
  end

  def self.site_kind(irep, index, insn)
    case insn.op
    when 'LAMBDA' then 'lambda'
    when 'ARRAY' then 'array'
    when 'HASH' then 'hash'
    when 'STRING' then 'string'
    when 'SEND', 'SENDB' then 'object' if insn.sym == 'new' && insn.n_spec != '*'
    when 'BLOCK'
      call = irep.instructions[index + 1]
      call && %w[SENDB SSENDB].include?(call.op) ? "block:#{call.sym}" : 'block:?'
    end
  end
end

CodeGen.prepend(EscapeReport)
at_exit { EscapeReport.write(ENV.fetch('BC2CPP_ESCAPE_REPORT')) }
