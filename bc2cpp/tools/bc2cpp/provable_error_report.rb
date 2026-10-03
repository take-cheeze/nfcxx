# frozen_string_literal: true

require 'set'
require_relative 'call_facts'

# Debug report for errors the compiler can prove (ADR 0317): with BC2CPP_PROVABLE_ERROR_REPORT=<path>,
# every send or operator of the engine ireps whose generated code can only raise is written as one TSV row.
# It measures; it changes no generated code.
#
#   kind gem method irep idx op name detail reach byname else
#
# kinds: nomethod (no class of the proven receiver set answers the name), nil_receiver (the set is exactly
# nil), arity (every definition of the name rejects the argument count, or every class of the proven set
# resolves to one that does), operator (an arithmetic or comparison operator on classes it always rejects),
# zero_divide (Integer / literal 0).
#
# reach: unconditional (the site is on every completing path of a method body outside any rescue range),
# conditional (a branch, an early return, or a block), rescue (inside a rescue/ensure range or a block under
# one), dead (not reachable from the entry), probed (the name is passed to respond_to? and friends).
module ProvableErrorReport
  ROWS = {}
  ENGINE_GEMS = %w[mruby-rpg2k mruby-lcf mruby-rgss].freeze
  BY_NAME = /\bbc2cpp_send\(|\bmrb_funcall\w*\(|\bbc2cpp_funcall_(?:argv|noarg|explicit)\(/
  SEND_OPS = %w[SEND SEND0 SENDB SSEND SSEND0 SSENDB].freeze
  ARITH = { 'ADD' => '+', 'SUB' => '-', 'MUL' => '*', 'DIV' => '/', 'LT' => '<', 'LE' => '<=', 'GT' => '>', 'GE' => '>=' }.freeze
  NUM = %w[Integer Float].freeze
  # Operand class pairs (left, right) the core operator always rejects, by operator.
  OPERATOR_REJECTS = {
    '+' => ->(l, r) { (NUM.include?(l) && !NUM.include?(r)) || (l == 'String' && r != 'String') || (l == 'Array' && r != 'Array') },
    '-' => ->(l, r) { (NUM.include?(l) && !NUM.include?(r)) || (l == 'Array' && r != 'Array') },
    '*' => ->(l, r) { NUM.include?(l) && !NUM.include?(r) },
    '/' => ->(l, r) { NUM.include?(l) && !NUM.include?(r) },
    '<' => ->(l, r) { (NUM.include?(l) && !NUM.include?(r)) || (l == 'String' && r != 'String') },
    '<=' => ->(l, r) { (NUM.include?(l) && !NUM.include?(r)) || (l == 'String' && r != 'String') },
    '>' => ->(l, r) { (NUM.include?(l) && !NUM.include?(r)) || (l == 'String' && r != 'String') },
    '>=' => ->(l, r) { (NUM.include?(l) && !NUM.include?(r)) || (l == 'String' && r != 'String') }
  }.freeze
  BIT_NAMES = { NumericFlow::INT => 'Integer', NumericFlow::FLT => 'Float', NumericFlow::ARR => 'Array',
                NumericFlow::HSH => 'Hash', NumericFlow::STR => 'String', NumericFlow::NIL => 'NilClass',
                NumericFlow::RNG => 'Range' }.freeze

  def compile_send(insn, **kwargs)
    code = super
    irep = kwargs[:irep]
    site = kwargs[:idx] || kwargs[:trace_idx]
    if irep && site
      ROWS[:codegen] = self
      lines = code.each_line.reject { |l| l.lstrip.start_with?('//') }
      ROWS[[irep.label, site]] = { byname: lines.count { |l| l.match?(BY_NAME) },
                                   else: code.include?('bc2cpp_nomethod_named') ? 'nomethod' : '-',
                                   miss: code.include?('CLOSED_WORLD proven_miss') }
    end
    code
  end

  # The exact class names a mask names, or nil when it names anything else.
  def error_mask_classes(mask)
    return nil unless mask.is_a?(Integer) && mask.positive?
    return nil if mask.anybits?(NumericFlow::OTHER | NumericFlow::EXC)

    names = []
    rest = mask
    BIT_NAMES.each do |bit, name|
      next unless rest.anybits?(bit)

      names << name
      rest &= ~bit
    end
    (@numeric_class_bits || {}).each do |klass, bit|
      next unless rest.anybits?(bit)

      names << klass
      rest &= ~bit
    end
    rest.zero? ? names : nil
  end

  # The classes the receiver register may hold at +idx+ (both flows agree: each is a sound over-approximation).
  def error_receiver_classes(irep, idx, reg, owner_def)
    return nil if fixnum_proof_ctx(irep)[:upvars].include?(reg.to_s)

    sets = [exact_flow_mask(irep, idx, reg), (numeric_raw_mask(irep, idx, reg, owner_def) if owner_def)]
           .filter_map { |m| error_mask_classes(m) }
    sets.empty? ? nil : sets.reduce(:&)
  end

  def error_stat(irep, key)
    (@error_stats ||= Hash.new(0))[[error_gem(irep), key]] += 1
  end

  def error_gem(irep)
    ENGINE_GEMS.find { |g| irep.file.to_s.include?("/#{g}/") } || (irep.file.to_s.include?('/3rd/mruby/') ? 'core' : 'other')
  end

  def error_reach(irep, idx, owner_def, name)
    program = BytecodeIR.for(irep)
    return 'dead' unless program.reachable_from(0).include?(idx)
    return 'probed' if @closed_world.instance_variable_get(:@probed_names).include?(name)
    return 'rescue' if rescue_covered_labels.include?(irep.label) ||
                       program.handler_protected_addrs(inclusive_end: true).include?(irep.instructions[idx].addr)
    return 'conditional' if owner_def.nil? || owner_def.irep != irep.label
    return 'conditional' unless program.every_path_reaches?(0, idx)

    'unconditional'
  end

  def error_arity_ok?(irep, argc)
    enter = irep.enter
    return true unless enter

    req, opt, rest, post, kw, kdict = enter.enter_fields
    return true unless kw.zero? && kdict.zero?

    argc >= req + post && (rest.positive? || argc <= req + opt + post)
  end

  def error_def_accepts?(definition, argc)
    return true if definition.owner == '<native>'
    return error_arity_ok?(@ireps.fetch(definition.irep), argc) if definition.irep

    definition.name.end_with?('=') ? argc == 1 : argc.zero?
  end

  # Does every possible callee of +name+ reject +argc+ positional arguments? false when anything is unknown.
  def error_name_rejects?(answers, name, argc)
    return false if answers.definers(name).nil? || answers.registrations.key?(name)

    defs = @registry.fetch(name, [])
    !defs.empty? && defs.none? { |d| error_def_accepts?(d, argc) }
  end

  def error_row(kind, irep, idx, owner_def, op, name, detail, reach)
    info = ROWS[[irep.label, idx]] || {}
    [kind, error_gem(irep), owner_def ? "#{owner_def.owner}##{owner_def.name}" : '-', irep.label, idx, op, name, detail,
     reach, info[:byname] || '', info[:else] || (info.empty? ? 'not-compiled' : '-')].join("\t")
  end

  def error_report_rows
    answers = call_facts_answers
    owners = entry_arg_body_owner
    out = []
    @ireps.each_value do |irep|
      next unless ENGINE_GEMS.include?(error_gem(irep)) || ENV['BC2CPP_PROVABLE_ERROR_ALL_GEMS']

      owner_def = owners[irep.label]
      irep.instructions.each_with_index do |insn, idx|
        if SEND_OPS.include?(insn.op) && insn.sym
          out.concat(error_send_rows(answers, irep, idx, insn, owner_def))
        elsif ARITH.key?(insn.op)
          out.concat(error_operator_rows(irep, idx, insn, owner_def))
        end
      end
    end
    out
  end

  def error_send_rows(answers, irep, idx, insn, owner_def)
    name = insn.sym
    rows = []
    explicit = %w[SEND SEND0 SENDB].include?(insn.op)
    reach = nil
    emit = lambda do |kind, detail|
      reach ||= error_reach(irep, idx, owner_def, name)
      rows << error_row(kind, irep, idx, owner_def, insn.op, name, detail, reach)
    end
    defined = answers.definers(name)
    if defined && defined.values_at(:ruby, :native, :foreign).all?(&:empty?) && !defined[:singleton] && answers.method_missing_classes.empty?
      error_stat(irep, :undefined_name)
      emit.call('undefined_name', explicit ? 'explicit' : 'self')
    end
    if explicit
      classes = error_receiver_classes(irep, idx, insn.reg.to_i, owner_def)
      error_stat(irep, classes.nil? ? :unproven : :proven)
      if classes && !classes.empty? && classes.none? { |k| answers.answers?(k, name) }
        emit.call(classes == ['NilClass'] ? 'nil_receiver' : 'nomethod', classes.sort.join('|'))
      end
    elsif owner_def && !owner_def.owner.end_with?('.singleton') && @closed_world.class_declared?(owner_def.owner)
      selves = answers.classes.select { |k| k != CallFacts::CLASS_OBJECT && answers.ancestors(k)[0].include?(answers.simple(owner_def.owner)) }
      error_stat(irep, :self_checked)
      emit.call('nomethod', "self:#{owner_def.owner}") if !selves.empty? && selves.none? { |k| answers.answers?(k, name) }
    end
    if insn.plain_fixed_argc?
      argc = insn.argc.to_i
      if error_name_rejects?(answers, name, argc)
        defs = @registry[name].map { |d| "#{d.owner}/#{d.irep ? error_arity_text(@ireps[d.irep]) : 'attr'}" }
        emit.call('arity', "argc=#{argc} defs=#{defs.join(',')}")
      elsif explicit && classes && !classes.empty? && answers.definers(name)
        error_stat(irep, :arity_exact_checked)
        targets = classes.map { |k| error_lookup(k, name) }
        emit.call('arity', "argc=#{argc} set=#{classes.sort.join('|')}") if targets.all? { |t| t && !error_def_accepts?(t, argc) }
      end
    end
    rows
  end

  # The one definition +klass+ resolves +name+ to, or nil when unknown or absent.
  def error_lookup(klass, name)
    return nil unless @closed_world.class_declared?(klass)

    target, known = closed_world_lookup_target(name, klass, Set.new, any_visibility: true)
    known ? target : nil
  end

  def error_arity_text(irep)
    enter = irep.enter
    enter ? enter.enter_fields.first(6).join(':') : '0'
  end

  def error_operator_rows(irep, idx, insn, owner_def)
    sym = ARITH.fetch(insn.op)
    return [] unless numeric_op_native?(sym)

    a = insn.reg.to_i
    b = insn.paren_reg.to_i
    left = error_receiver_classes(irep, idx, a, owner_def)
    right = error_receiver_classes(irep, idx, b, owner_def)
    error_stat(irep, left && right ? :operator_proven : :operator_unproven)
    rows = []
    reach = nil
    emit = lambda do |kind, detail|
      reach ||= error_reach(irep, idx, owner_def, sym)
      rows << error_row(kind, irep, idx, owner_def, insn.op, sym, detail, reach)
    end
    if left && right && !left.empty? && !right.empty? && left.product(right).all? { |l, r| OPERATOR_REJECTS.fetch(sym).call(l, r) }
      emit.call('operator', "#{left.sort.join('|')} #{sym} #{right.sort.join('|')}")
    end
    if insn.op == 'DIV' && left && left == ['Integer'] && error_zero_literal?(irep, idx, b)
      emit.call('zero_divide', 'Integer / 0')
    end
    rows
  end

  def error_zero_literal?(irep, idx, reg)
    value = irep.walk_dominating_writers(idx - 1, reg.to_s, use: idx, follow_moves: true) do |w|
      w.op.start_with?('LOADI') ? (w.paren_value || w.imm_operand).to_s : :other
    end
    value == '0'
  end

  def self.write(path)
    cg = ROWS.delete(:codegen)
    lines = cg ? cg.error_report_rows : []
    File.write("#{path}.stats", (cg&.instance_variable_get(:@error_stats) || {}).map { |(gem, key), n| "#{gem}\t#{key}\t#{n}" }.sort.join("\n") + "\n")
    File.write(path, "#{lines.join("\n")}\n")
  end
end

CodeGen.prepend(ProvableErrorReport)
at_exit { ProvableErrorReport.write(ENV.fetch('BC2CPP_PROVABLE_ERROR_REPORT')) } if ENV['BC2CPP_PROVABLE_ERROR_REPORT']
