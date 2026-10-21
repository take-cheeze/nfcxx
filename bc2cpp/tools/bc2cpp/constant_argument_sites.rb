# frozen_string_literal: true

require 'set'
require_relative 'bytecode_ir'
require_relative 'call_site_index'

# CONSTANT_ARGUMENT_SITES (report only): for each method body, the call sites that pass constant arguments, whether every
# call site passes one constant tuple, whether the body is pure by a conservative allowlist, and how many of its
# conditional jumps the tuple would decide. Nothing is generated; the output is a report for a later value-specialization.
#
# A constant is an Integer literal (LOADI*), nil, true, false, a Symbol literal, or a constant named in +constants+ (a bare
# name => [:int, value] or a Symbol-or-nil value, the ConstantFacts values from ADR 0501). A value reaches a call through
# the bytecode reaching definitions, so a MOVE chain is followed. Anything else is UNKNOWN.
#
# Call sites are matched by method name (CallSiteIndex), so a method is "called only with tuple T" only over its name's
# sites. A computed-name site is kept as a caller of every name (CallSiteIndex.sites), which can only add sites.
module ConstantArgumentSites
  UNKNOWN = :unknown
  # Methods a pure body may send. Core operators and predicates; a program that redefines one is not checked here.
  PURE_NAMES = Set.new(%w[+ - * / % == != < > <= >= ! nil? is_a? kind_of? instance_of? respond_to? zero? positive? negative? abs]).freeze
  # Opcodes with no side effect of their own. GETCONST/GETMCNST may run const_missing, and the arithmetic and comparison
  # opcodes may dispatch to a redefined operator; both are accepted here and reported as a caveat, not checked.
  PURE_OPS = Set.new(%w[NOP MOVE LOADNIL LOADTRUE LOADFALSE LOADSYM LOADSELF LOADL STRING ENTER RETURN JMP JMPIF JMPNOT JMPNIL
                        GETIV GETCONST GETMCNST GETUPVAR ADD SUB MUL DIV ADDI SUBI EQ LT LE GT GE NOT
                        SEND SEND0 SEND1 SENDV]).freeze
  SEND_OPS = %w[SEND SEND0 SEND1 SENDV].freeze
  JUMP_OPS = %w[JMPIF JMPNOT JMPNIL].freeze
  LOADI_OP = /\ALOADI(?:8|16|32|NEG|__1|_[0-7])\z/

  module_function

  # Summary and per-method rows for every method definition in +registry+ (name => [definitions]).
  def report(ireps, registry, constants: {})
    index = CallSiteIndex.build(ireps)
    rows = []
    registry.each do |name, definitions|
      definitions.each do |definition|
        next unless definition.irep

        # The registry names a body by its label; the irep is the one in +ireps+.
        body = ireps.fetch(definition.irep)
        sites = CallSiteIndex.sites(index, name)
        tuples = sites.map { |irep, idx, dest, argc| argc && (1..argc).map { |k| value_at(irep, idx, dest + k, nil, constants) } }
        constant_tuples = tuples.select { |t| t && t.none?(UNKNOWN) }
        single = !tuples.empty? && tuples.all? { |t| t && t.none?(UNKNOWN) } && tuples.uniq.size == 1
        pure, impure_reasons = purity(body)
        decided = single && pure ? decided_jumps(body, tuples.first, constants) : nil
        rows << { name: name, owner: definition.owner, sites: sites.size, constant_sites: constant_tuples.size,
                  single_tuple: single, tuple: single ? tuples.first : nil, pure: pure, impure: impure_reasons,
                  jumps: decided && decided[:total], decided: decided && decided[:decided] }
      end
    end
    rows.sort_by! { |r| [r[:owner].to_s, r[:name].to_s] }
    { rows: rows, summary: summary(rows) }
  end

  def summary(rows)
    {
      methods: rows.size,
      with_constant_sites: rows.count { |r| r[:constant_sites].positive? },
      single_tuple: rows.count { |r| r[:single_tuple] },
      pure: rows.count { |r| r[:pure] },
      pure_single_tuple: rows.count { |r| r[:pure] && r[:single_tuple] },
      jumps_in_pure_single_tuple: rows.sum { |r| r[:jumps] || 0 },
      jumps_decided: rows.sum { |r| r[:decided] || 0 }
    }
  end

  # [pure, reasons]: pure is true when every instruction is in PURE_OPS, every send names PURE_NAMES, and the body has no
  # nested block (LAMBDA/BLOCK are not in PURE_OPS).
  def purity(irep)
    reasons = []
    BytecodeIR.for(irep).instructions.each do |ins|
      op = ins.op
      if SEND_OPS.include?(op)
        name = ins.source.sym
        reasons << "send #{name}" unless PURE_NAMES.include?(name)
      elsif !(op.match?(LOADI_OP) || PURE_OPS.include?(op))
        reasons << op
      end
    end
    [reasons.empty?, reasons.uniq]
  end

  # The jumps of +irep+ decided by parameters holding +tuple+ (one value per parameter): a jump is decided when the value of
  # its tested register is known. JMPNIL is decided by whether the value is nil; JMPIF/JMPNOT by its truthiness.
  def decided_jumps(irep, tuple, constants)
    total = 0
    decided = 0
    BytecodeIR.for(irep).instructions.each_with_index do |ins, idx|
      next unless JUMP_OPS.include?(ins.op)

      total += 1
      value = value_at(irep, idx, ins.source.reg.to_i, tuple, constants)
      decided += 1 unless value == UNKNOWN
    end
    { total: total, decided: decided }
  end

  # The value of register +reg+ read at instruction +index+ of +irep+: UNKNOWN unless every reaching definition gives the
  # same constant. +tuple+ supplies the parameters (entry definitions of R1..Rn); nil means the caller's values are unknown.
  def value_at(irep, index, reg, tuple, constants, depth = 0)
    return UNKNOWN if depth > 32

    defs = BytecodeIR.reaching_definitions(irep, index, reg.to_s)
    return UNKNOWN if defs.nil? || defs.empty?

    values = defs.map { |d| definition_value(irep, d, tuple, constants) }
    values.uniq.size == 1 ? values.first : UNKNOWN
  end

  def definition_value(irep, definition, tuple, constants)
    if definition.entry?
      slot = definition.reg.to_i - 1
      return UNKNOWN if tuple.nil? || slot.negative? || slot >= tuple.size

      return tuple[slot]
    end
    return UNKNOWN if definition.built

    literal_value(irep, BytecodeIR.for(irep).source_at(definition.index), constants)
  end

  # The value of a LOADI* literal, decoded as the numeric pass does (bytecode_ir_types.rb#integer_literal).
  def integer_literal(insn)
    case insn.op
    when 'LOADI__1' then -1
    when /\ALOADI_([0-7])\z/ then Regexp.last_match(1).to_i
    when 'LOADI8', 'LOADI16', 'LOADI32', 'LOADINEG'
      value = insn.imm_operand&.to_i
      value && insn.op == 'LOADINEG' ? -value.abs : value
    end
  end

  def literal_value(irep, insn, constants)
    return UNKNOWN if insn.nil?

    op = insn.op
    if op.match?(LOADI_OP)
      value = integer_literal(insn)
      return value.nil? ? UNKNOWN : [:int, value]
    end
    case op
    when 'LOADNIL' then nil
    when 'LOADTRUE' then true
    when 'LOADFALSE' then false
    when 'LOADSYM' then insn.sym_token ? [:sym, insn.sym_token.to_s] : UNKNOWN
    when 'GETCONST' then constants.fetch(insn.const_name.to_s, UNKNOWN)
    else UNKNOWN
    end
  end
end
