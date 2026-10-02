# frozen_string_literal: true

# Debug report for element classes of mutable containers (ADR 0312): with BC2CPP_ELEMENT_REPORT=<path>,
# compile_insn records, per instruction, two kinds of TSV row (the last compile of an instruction wins,
# since compiles_clean? probes compile methods early). It changes no generated code.
#
#   site   irep_label:index  owner#method  op  name  operand  origin
#   store  irep_label:index  owner#method  op  name  origin  value_class_set
#   extreme  irep_label:index  owner#method  op  name  literal|not-adjacent  element_class_sets (comma separated)
#
# `site` rows are instructions whose emitted code can still reach a by-name call; `operand` is 0 for the
# receiver (arithmetic: 1 for the right operand) and `origin` is the join of the nearest defining
# instructions of that register, with an element read shown as `elem<container origin>`. `store` rows are
# element writes (`[]=`, `<<`, `push` ...) whose container is an ivar read; `value_class_set` is the numeric
# flow's class set of the stored value ("unmodelled" when the method has no flow states).
# scripts/bc2cpp_element_site_report.rb aggregates it.
module ElementSiteReport
  DYNAMIC = /bc2cpp_send\(|bc2cpp_getidx0?\(|bc2cpp_setidx\(|mrb_funcall|bc2cpp_slow_|bc2cpp_eqq\(/
  # Sends that return one element of their receiver.
  ELEMENT_READS = %w[first last max min sample pop shift fetch at dig [] min_by max_by detect find].freeze
  ELEMENT_STORES = %w[<< push []= unshift insert append].freeze
  ARITHMETIC = %w[ADD SUB MUL DIV LT LE GT GE EQ].freeze
  ROWS = {}

  # Join of the defining instructions of +reg+ at +idx+ as short tags: entry, ivar:name, const, call:name,
  # scall:name (implicit self), upvar, fresh_lit, idx<..> / name<..> (an element of the origin inside).
  def element_origin(irep, idx, reg, depth = 0)
    defs = BytecodeIR.reaching_definitions(irep, idx, reg.to_s)
    return ['refused'] unless defs

    defs.flat_map do |d|
      next ['entry'] if d.entry?

      insn = irep.instructions[d.index]
      case insn.op
      when 'GETIDX', 'GETIDX0'
        depth < 2 ? element_origin(irep, d.index, insn.reg, depth + 1).map { |o| "idx<#{o}>" } : ['idx<deep>']
      when 'SEND', 'SEND0'
        if ELEMENT_READS.include?(insn.sym) && insn.n_spec.to_i <= 1 && depth < 2
          element_origin(irep, d.index, insn.reg, depth + 1).map { |o| "#{insn.sym}<#{o}>" }
        else
          ["call:#{insn.sym}"]
        end
      when 'SSEND', 'SSEND0' then ["scall:#{insn.sym}"]
      when 'GETIV' then ["ivar:#{insn.ivar}"]
      when 'GETCONST' then ['const']
      when 'ARRAY', 'ARRAY2', 'HASH' then ['fresh_lit']
      when 'GETUPVAR' then ['upvar']
      else ["op:#{insn.op}"]
      end
    end.uniq.sort
  end

  def compile_insn(insn, irep, owner_def, idx = nil, reg_offset = 0)
    code = super
    return code unless reg_offset.zero? && idx && code.is_a?(String) && !code.include?('#error')

    owner = "#{owner_def&.owner}##{owner_def&.name}"
    record_element_store(insn, irep, owner_def, idx, owner)
    record_literal_extreme(insn, irep, owner_def, idx, owner)
    if code.match?(DYNAMIC)
      operands = case insn.op
                 when 'SEND', 'SEND0', 'GETIDX', 'GETIDX0', 'SETIDX' then [insn.reg]
                 when *ARITHMETIC then [insn.reg, insn.paren_reg]
                 else []
                 end
      operands.compact.each_with_index do |reg, k|
        ROWS[['site', irep.label, idx, k]] =
          ['site', "#{irep.label}:#{idx}", owner, insn.op, insn.sym, k, element_origin(irep, idx, reg).join('|')].join("\t")
      end
    end
    code
  end

  # The value register of an element write: SETIDX Ra stores R[a+2]; `<<`/push/[]= name their last argument.
  def element_store_value_reg(insn)
    case insn.op
    when 'SETIDX' then insn.reg.to_i + 2
    when 'SEND', 'SEND0'
      n = insn.n_spec.to_i
      insn.reg.to_i + n if ELEMENT_STORES.include?(insn.sym) && n.positive?
    end
  end

  # A SETIV of a container: the class set of what the literal it stores already holds (OTHER for a value
  # that is not a literal, since then the contents come from elsewhere). nil stores hold nothing.
  def record_ivar_creation(insn, irep, owner_def, idx, owner)
    defs = BytecodeIR.reaching_definitions(irep, idx, insn.regs.first)
    return if defs&.all? { |d| !d.entry? && irep.instructions[d.index].op == 'LOADNIL' }

    masks = defs ? defs.map { |d| literal_contents_mask(irep, d, owner_def) } : [NumericFlow::OTHER]
    mask = masks.include?(nil) ? nil : masks.reduce(0, :|)
    classes = mask ? class_mask_name(mask) : 'unmodelled'
    classes = 'EMPTY' if mask&.zero?
    ROWS[['store', irep.label, idx]] =
      ['store', "#{irep.label}:#{idx}", owner, 'SETIV', insn.ivar, "ivar:#{insn.ivar}", classes].join("\t")
  end

  # Class set of the elements of the literal a definition builds; OTHER when the definition is not a literal.
  def literal_contents_mask(irep, definition, owner_def)
    return NumericFlow::OTHER if definition.entry?

    lit = irep.instructions[definition.index]
    case lit.op
    when 'LOADNIL' then 0
    when 'ARRAY', 'ARRAY2'
      three = lit.src_and_literal
      first = three ? three[0].to_i : lit.reg.to_i
      count = three ? three[1].to_i : lit.uint_operand.to_i
      join_masks(irep, definition.index, (first...(first + count)).to_a, owner_def)
    when 'HASH'
      pairs = lit.uint_operand.to_i
      join_masks(irep, definition.index, (0...pairs).map { |i| lit.reg.to_i + (2 * i) + 1 }, owner_def)
    else NumericFlow::OTHER
    end
  end

  # Both flows are sound may-sets (OTHER = unknown), so the truth lies in their meet: the exact-class flow
  # (class bits, return-class table; ADR 0289, 0296) and the numeric flow each know things the other does
  # not. nil when neither models the method.
  def element_value_mask(irep, idx, reg, owner_def)
    exact = exact_flow_mask(irep, idx, reg.to_s)
    numeric = numeric_raw_mask(irep, idx, reg.to_s, owner_def)
    return exact || numeric unless exact && numeric
    return numeric if exact.anybits?(NumericFlow::OTHER)
    return exact if numeric.anybits?(NumericFlow::OTHER)

    (exact & numeric).zero? ? exact | numeric : exact & numeric
  end

  def join_masks(irep, idx, regs, owner_def)
    masks = regs.map { |reg| element_value_mask(irep, idx, reg, owner_def) }
    masks.include?(nil) ? nil : masks.reduce(0, :|)
  end

  # `[a, b].max` / `.min`: the literal is built by the instruction right before the send, so nothing else
  # can hold it and its elements are the registers' values there. One row per element: its class set.
  def record_literal_extreme(insn, irep, owner_def, idx, owner)
    return unless %w[SEND SEND0].include?(insn.op) && %w[min max].include?(insn.sym) && insn.n_spec.to_i.zero?

    prev = idx.positive? ? irep.instructions[idx - 1] : nil
    unless prev && %w[ARRAY ARRAY2].include?(prev.op) && prev.reg == insn.reg
      ROWS[['extreme', irep.label, idx]] = ['extreme', "#{irep.label}:#{idx}", owner, insn.op, insn.sym, 'not-adjacent', ''].join("\t")
      return
    end

    three = prev.src_and_literal
    first = three ? three[0].to_i : prev.reg.to_i
    count = three ? three[1].to_i : prev.uint_operand.to_i
    classes = (first...(first + count)).map do |reg|
      mask = element_value_mask(irep, idx - 1, reg, owner_def)
      mask ? class_mask_name(mask) : 'unmodelled'
    end
    ROWS[['extreme', irep.label, idx]] = ['extreme', "#{irep.label}:#{idx}", owner, insn.op, insn.sym, 'literal', classes.join(',')].join("\t")
  end

  def record_element_store(insn, irep, owner_def, idx, owner)
    return record_ivar_creation(insn, irep, owner_def, idx, owner) if insn.op == 'SETIV'

    value_reg = element_store_value_reg(insn)
    return unless value_reg

    origin = element_origin(irep, idx, insn.reg)
    return unless origin.any? { |o| o.start_with?('ivar:') }

    mask = element_value_mask(irep, idx, value_reg, owner_def)
    classes = mask ? class_mask_name(mask) : 'unmodelled'
    ROWS[['store', irep.label, idx]] =
      ['store', "#{irep.label}:#{idx}", owner, insn.op, insn.sym, origin.join('|'), classes].join("\t")
  end

  def self.write(path)
    File.write(path, "#{ROWS.values.join("\n")}\n") unless ROWS.empty?
  end
end

CodeGen.prepend(ElementSiteReport)
at_exit { ElementSiteReport.write(ENV.fetch('BC2CPP_ELEMENT_REPORT')) }
