# frozen_string_literal: true

require_relative 'integer_constants'

# NUMERIC_CONSTANT_RANGES (ADR 0318): bare constant names whose every definition is an Integer expression of known
# interval, with the hull of those intervals.
#
# IntegerConstants admits literals, aliases and ADD/SUB only, so `HEADER_H = LINE_H + Window::BORDER * 2` or
# `COLS = SCREEN_W / TILE + 1` are not Fixnum constants. The soundness argument is IntegerConstants' (keyed by the
# bare name, every definition visible, same four poison sources); what differs is the value domain: an interval, so
# MUL and DIV can be admitted, and an interval inside the narrowest target Fixnum range is itself the proof that
# any run binds a Fixnum.
module IntegerConstantRanges
  # CodeGen::LOADI_FIXNUM_MIN/MAX, the narrowest target Fixnum range (CodeGen loads after this file).
  FIXNUM_MIN = -1_073_741_824
  FIXNUM_MAX = 1_073_741_823
  OPS = %w[ADD SUB MUL DIV ADDI SUBI].freeze
  LOADS = %w[GETCONST GETMCNST].freeze

  # BC2CPP_NUMERIC_CONSTANTS=0 turns the analysis and every use of it off (the output is master's).
  def self.enabled?
    ENV['BC2CPP_NUMERIC_CONSTANTS'] != '0'
  end

  # name => [lo, hi]
  def self.analyze(ireps, native_paths, foreign_paths, report: nil)
    defs = Hash.new { |h, k| h[k] = [] }
    poisoned = Set.new
    class_names = Set.new
    ireps.each_value do |irep|
      entries = IntegerConstants.const_entry_addrs(irep)
      irep.instructions.each_with_index do |insn, i|
        case insn.op
        when 'SETCONST', 'SETMCNST'
          name = insn.const_name
          next unless name

          src = insn.regs.last
          defs[name] << (src && !entries.include?(insn.addr) ? source_kind(irep, i, src, entries) : nil)
        when 'CLASS', 'MODULE'
          poisoned << insn.sym_token
          class_names << insn.sym_token
        end
      end
    end
    native = IntegerConstants.native_defined_const_names(native_paths)
    foreign = IntegerConstants.foreign_const_names(foreign_paths)
    poisoned.merge(native)
    poisoned.merge(foreign)
    known = resolve(defs, poisoned)
    explain(report, defs, known, class_names, native, foreign) if report
    known
  end

  # BC2CPP_NUMERIC_CONSTANTS_REPORT: one line per constant name with a definition and no interval, and why.
  def self.explain(report, defs, known, class_names, native, foreign)
    defs.each do |name, kinds|
      next if known.key?(name)

      why = []
      why << 'class/module' if class_names.include?(name)
      why << 'native' if native.include?(name)
      why << 'foreign-ruby' if foreign.include?(name)
      why << "unclassified-def(#{kinds.count(&:nil?)}/#{kinds.size})" if kinds.any?(&:nil?)
      unresolved = kinds.compact.flat_map { |kind| aliases(kind) }.reject { |n| n == name || known.key?(n) }.uniq
      why << "unresolved-alias(#{unresolved.first(4).join(',')})" unless unresolved.empty?
      why << 'range-or-cycle' if why.empty?
      report << "#{name}\t#{kinds.size}\t#{why.join(' ')}\t#{kinds.first(3).map(&:inspect).join(' ')}"
    end
  end

  def self.aliases(kind)
    case kind[0]
    when :alias then [kind[1]]
    when :arith then [kind[2], kind[3]].select { |k| k.is_a?(Array) }.flat_map { |k| aliases(k) }
    else []
    end
  end

  # A name becomes known once every definition has a known interval; a cycle never does, so it stays unproven.
  def self.resolve(defs, poisoned)
    known = {}
    loop do
      grew = false
      defs.each do |name, kinds|
        next if known.key?(name) || poisoned.include?(name) || kinds.empty? || kinds.any?(&:nil?)

        # `Scene::Map::TILE = Game::TILE` reads a value of its own name: by induction on assignment order it adds
        # nothing the other definitions do not bound.
        ranges = kinds.reject { |kind| kind == [:alias, name] }.map { |kind| eval_kind(kind, known) }
        next if ranges.empty? || ranges.any?(&:nil?)

        known[name] = [ranges.map(&:first).min, ranges.map(&:last).max]
        grew = true
      end
      break unless grew
    end
    known
  end

  # How `reg` is written at this point of the class body: [:literal, v], [:alias, NAME], [:arith, op, l, r] or nil.
  # The walk does not step over a jump target (see IntegerConstants.const_source_kind), except that a target may itself
  # be the load that writes the register: control reaching it runs that load.
  def self.source_kind(irep, idx, reg, entries)
    barrier = lambda do |insn, cur|
      load_here = insn.reg == cur.to_s && (LOADS.include?(insn.op) || insn.op.start_with?('LOADI'))
      entries.include?(insn.addr) && !load_here
    end
    irep.walk_writers(idx - 1, reg.to_s, barrier: barrier, follow_moves: true) do |insn, j, cur|
      if insn.op.start_with?('LOADI')
        value = literal(insn)
        next value.nil? ? nil : [:literal, value]
      end

      case insn.op
      when 'GETCONST' then (n = insn.const_name) && [:alias, n]
      when 'GETMCNST' then (n = insn.mcnst_name) && [:alias, n]
      when *OPS then arith_kind(irep, j, insn, cur, entries)
      end
    end
  end

  # The value a LOADI-family instruction loads, or nil outside the narrowest Fixnum range. LOADI_0..7 and
  # LOADI__1 carry no operand, so IntegerConstants.loadi_value cannot read them.
  def self.literal(insn)
    value = case insn.op
            when /\ALOADI_(\d)\z/ then Regexp.last_match(1).to_i
            when 'LOADI__1' then -1
            else insn.imm_operand&.to_i
            end
    value if value && value >= FIXNUM_MIN && value <= FIXNUM_MAX
  end

  def self.arith_kind(irep, idx, insn, cur, entries)
    return nil if entries.include?(insn.addr)

    left = source_kind(irep, idx, cur, entries)
    right = if %w[ADDI SUBI].include?(insn.op)
              imm = insn.imm_operand
              imm && [:literal, imm.to_i]
            else
              insn.regs[1] && source_kind(irep, idx, insn.regs[1], entries)
            end
    left && right ? [:arith, insn.op, left, right] : nil
  end

  def self.eval_kind(kind, known)
    case kind[0]
    when :literal then fit([kind[1], kind[1]])
    when :alias then known[kind[1]]
    when :arith
      left = eval_kind(kind[2], known)
      right = eval_kind(kind[3], known)
      left && right && combine(kind[1], left, right)
    end
  end

  def self.combine(op, left, right)
    case op
    when 'ADD', 'ADDI' then fit([left[0] + right[0], left[1] + right[1]])
    when 'SUB', 'SUBI' then fit([left[0] - right[1], left[1] - right[0]])
    when 'MUL' then corners(left, right) { |a, b| a * b }
    when 'DIV'
      # A divisor interval holding 0 raises or is unknown: no interval.
      return nil if right[0] <= 0 && right[1] >= 0

      corners(left, right) { |a, b| a.div(b) }
    end
  end

  def self.corners(left, right)
    values = left.product(right).map { |a, b| yield a, b }
    fit([values.min, values.max])
  end

  # Every intermediate result has to be a Fixnum on the narrowest target.
  def self.fit(range)
    range[0] >= FIXNUM_MIN && range[1] <= FIXNUM_MAX ? range : nil
  end
end
