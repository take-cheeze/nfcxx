# frozen_string_literal: true

require_relative 'operand_schema'

# Insn accessors over OperandSchema's typed operands. Nothing here reads the
# disassembly text: the operand list is parsed once per instruction and every
# accessor is a lookup by operand kind.
module InsnOperands
  # The typed operand list. An instruction the schema cannot parse is a schema
  # gap, so it raises instead of answering nil to every question.
  def typed
    @typed ||= OperandSchema.parse(op, args) ||
               raise(ArgumentError, "bc2cpp: no operand schema for #{op} #{args.inspect}")
  end

  def first_of(*kinds)
    typed.find { |operand| kinds.include?(operand.kind) }
  end

  # First register operand as digits, only when it is the leading operand.
  def reg
    return @reg if defined?(@reg)

    lead = typed.first
    @reg = lead&.kind == :reg ? lead.value.to_s : nil
  end

  def reg_token
    reg && "R#{reg}"
  end

  # Every register an operand names, in operand order (`(R5)`, `R2[0]` and the
  # scope register of `(R5)::Name` included).
  def regs
    @regs ||= typed.filter_map do |operand|
      case operand.kind
      when :reg, :preg, :idx0 then operand.value.to_s
      when :mcnst then operand.value[0].to_s
      end
    end.freeze
  end

  # Kinds of the operands in order, e.g. %i[reg sym irep] for TDEF.
  def operand_kinds
    @operand_kinds ||= typed.map(&:kind).freeze
  end

  # First register operand wherever it sits (the value register of SETCONST,
  # whose leading operand is the name).
  def reg_operand
    typed.find { |operand| operand.kind == :reg }&.value&.to_s
  end

  def mentions_reg?(number)
    regs.include?(number.to_s)
  end

  # Register in parentheses: `(R2)` or the scope of `(R2)::Name`.
  def paren_reg
    return @paren_reg if defined?(@paren_reg)

    operand = first_of(:preg, :mcnst)
    @paren_reg = operand && (operand.kind == :mcnst ? operand.value[0] : operand.value).to_s
  end

  def sym
    return @sym if defined?(@sym)

    @sym = first_of(:sym)&.value
  end

  def sym_token
    sym
  end

  def ivar
    return @ivar if defined?(@ivar)

    name = first_of(:name)&.value
    @ivar = name&.start_with?('@') && !name.start_with?('@@') ? name[1..] : nil
  end

  def global_name
    return @global_name if defined?(@global_name)

    name = first_of(:name)&.value
    @global_name = name&.start_with?('$') ? name : nil
  end

  # Constant name of GETCONST/SETCONST (bare) and GETMCNST/SETMCNST (`::Name`).
  def const_name
    case op
    when 'SETCONST', 'GETCONST' then first_of(:name)&.value
    when 'GETMCNST', 'SETMCNST' then mcnst_name
    end
  end

  def mcnst_name
    first_of(:mcnst)&.value&.at(1)
  end

  def argc_operand
    first_of(:argc)&.value
  end

  # Positional argument count (`n=3`); nil for a splat or when absent.
  def argc
    return @argc if defined?(@argc)

    @argc = argc_operand&.at(0)
  end

  # `n=` / `nk=` as printed: digits, `*`, or nil when absent.
  def n_spec
    spec = argc_operand or return nil

    spec[0].nil? ? '*' : spec[0].to_s
  end

  def nk_spec
    spec = argc_operand or return nil
    return nil if spec[2]

    spec[1].nil? ? '*' : spec[1].to_s
  end

  def argc_text
    spec = argc_operand or return nil

    OperandSchema.argc_text(spec)
  end

  def pure_splat?
    n_spec == '*' && nk_spec.nil?
  end

  def plain_fixed_argc?
    n_spec && n_spec != '*' && nk_spec.nil?
  end

  def block_index
    return @block_index if defined?(@block_index)

    @block_index = first_of(:irep)&.value
  end

  def pool_index
    return @pool_index if defined?(@pool_index)

    @pool_index = first_of(:pool)&.value
  end

  # Target address of a branch op, nil for every other op.
  def branch_target
    return nil unless %w[JMP JMPUW JMPIF JMPNOT JMPNIL].include?(op)

    first_of(:addr)&.value
  end

  # Target of JMP/JMPUW/JMPIF/JMPNOT/JMPNIL excluding JMPUW (Insn#jump_target's
  # historical scope, kept for BytecodeIR).
  def jump_target
    op == 'JMPUW' ? nil : branch_target
  end

  def jmp_addr
    op == 'JMP' || op == 'JMPUW' ? first_of(:addr).value : 0
  end

  # Non-negative integer right after the leading register (`R1 3`).
  def uint_operand
    return @uint_operand if defined?(@uint_operand)

    second = typed[1]
    @uint_operand = reg && second && %i[int addr].include?(second.kind) && second.value >= 0 ? second.value : nil
  end

  # Signed literal right after the leading register, as printed (`R1 -5`).
  def imm_operand
    return @imm_operand if defined?(@imm_operand)

    second = typed[1]
    @imm_operand = reg && second&.kind == :int ? second.value.to_s : nil
  end

  # `R1 R2 3`: [source register, literal] as Strings.
  def src_and_literal
    return @src_and_literal if defined?(@src_and_literal)

    a, b, c = typed
    @src_and_literal = a&.kind == :reg && b&.kind == :reg && c&.kind == :int ? [b.value.to_s, c.value.to_s] : nil
  end

  # Text inside the first parentheses: `(5)` of LOADI_n, `(0)` of BLKPUSH, the
  # register of `(R2)`.
  def paren_value
    return @paren_value if defined?(@paren_value)

    operand = first_of(:plit, :preg, :mcnst)
    @paren_value = case operand&.kind
                   when :plit then operand.value
                   when :preg then "R#{operand.value}"
                   when :mcnst then "R#{operand.value[0]}"
                   end
  end

  # [index, level] of a GETUPVAR/SETUPVAR (`R3 1 0`), as Integers.
  def upvar_ref
    return @upvar_ref if defined?(@upvar_ref)

    ints = typed.select { |operand| operand.kind == :int }.map(&:value)
    @upvar_ref = %w[GETUPVAR SETUPVAR].include?(op) && ints.length == 2 ? ints : nil
  end

  def enter_fields
    @enter_fields ||= (first_of(:enter)&.value || []).freeze
  end

  def argary_spec
    first_of(:spec)&.value
  end

  # Child irep index of a DEF-family op whose operands are exactly
  # register, symbol, child (TDEF/SDEF shape).
  def def_child_index
    kinds = typed.map(&:kind)
    kinds == %i[reg sym irep] ? block_index : nil
  end

  def no_operands?
    typed.empty?
  end

  # Register operands moved up by +offset+, for compiling a block body inside
  # its parent's register file.
  def shift_regs(offset)
    shifted = typed.map do |operand|
      case operand.kind
      when :reg, :preg, :idx0 then OperandSchema::Operand.new(operand.kind, operand.value + offset)
      when :mcnst then OperandSchema::Operand.new(:mcnst, [operand.value[0] + offset, operand.value[1]])
      else operand
      end
    end
    Insn.new(lineno: lineno, addr: addr, op: op, raw: raw, args: OperandSchema.to_text(shifted))
  end
end
