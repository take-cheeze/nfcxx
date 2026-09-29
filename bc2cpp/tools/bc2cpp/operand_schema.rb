# frozen_string_literal: true

# Typed operands for every mruby opcode. The RITE-binary loader builds them
# straight from decoded bytes (insn_decoder.rb). OperandSchema.parse builds them
# from operand text by the per-opcode kind list below, only for synthetic
# instructions (Insn.synthetic); OperandSchema.to_text regenerates the text,
# which is how scripts/bc2cpp_operand_schema_check.rb proves every schema entry
# against the decoder's own operand text.
module OperandSchema
  # kind: one of KINDS. value: Integer for numeric kinds, String for names, an
  # [Integer, String] pair for :mcnst, an [n, nk] pair for :argc (nil = `*`).
  Operand = Struct.new(:kind, :value)

  # One whitespace-delimited token each, except :argc (`n=3|nk=1`, one token),
  # :enter (one token, a trailing `(0x..)` flags token is kept as :plit) and
  # :rest (the remaining text).
  KINDS = %i[reg preg idx0 sym name mcnst pool irep int addr argc spec enter plit rest].freeze

  Z = [].freeze
  R = %i[reg].freeze
  RP = %i[reg preg].freeze
  RN = %i[reg name].freeze
  NR = %i[name reg].freeze
  RS = %i[reg sym].freeze
  RSA = %i[reg sym argc].freeze
  RI = %i[reg int].freeze
  RL = %i[reg plit].freeze
  RIR = %i[reg irep].freeze
  JC = %i[reg addr].freeze

  SCHEMAS = {
    'NOP' => Z, 'CALL' => Z, 'KEYEND' => Z, 'RETSELF' => Z, 'RETNIL' => Z, 'RETTRUE' => Z,
    'RETFALSE' => Z, 'STOP' => Z, 'EXT1' => Z, 'EXT2' => Z, 'EXT3' => Z,
    'MOVE' => %i[reg reg].freeze, 'RESCUE' => %i[reg reg].freeze,
    'LOADL' => %i[reg pool].freeze,
    'LOADI8' => RI, 'LOADINEG' => RI, 'LOADI16' => RI, 'LOADI32' => RI,
    'LOADI__1' => RL, 'LOADI_0' => RL, 'LOADI_1' => RL, 'LOADI_2' => RL, 'LOADI_3' => RL,
    'LOADI_4' => RL, 'LOADI_5' => RL, 'LOADI_6' => RL, 'LOADI_7' => RL,
    'LOADSYM' => RS,
    'LOADNIL' => RL, 'LOADTRUE' => RL, 'LOADFALSE' => RL,
    'LOADSELF' => RP,
    'GETGV' => RN, 'GETSV' => RN, 'GETCONST' => RN, 'GETIV' => RN, 'GETCV' => RN,
    'SETGV' => NR, 'SETSV' => NR, 'SETCONST' => NR, 'SETIV' => NR, 'SETCV' => NR,
    'GETMCNST' => %i[reg mcnst].freeze,
    'SETMCNST' => %i[mcnst reg].freeze,
    'GETUPVAR' => %i[reg int int].freeze, 'SETUPVAR' => %i[reg int int].freeze,
    'GETIDX' => RP, 'GETIDX0' => %i[reg idx0].freeze, 'SETIDX' => %i[reg preg preg].freeze,
    'JMP' => %i[addr].freeze, 'JMPUW' => %i[addr].freeze,
    'JMPIF' => JC, 'JMPNOT' => JC, 'JMPNIL' => JC,
    'SSEND' => RSA, 'SSENDB' => RSA, 'SEND' => RSA, 'SENDB' => RSA,
    'SSEND0' => RS, 'SEND0' => RS,
    'BLKCALL' => RI,
    'SUPER' => %i[reg argc].freeze,
    'ARGARY' => %i[reg spec plit].freeze, 'BLKPUSH' => %i[reg spec plit].freeze,
    'ENTER' => %i[enter plit].freeze,
    'KEY_P' => RS, 'KARG' => RS,
    'RETURN' => R, 'RETURN_BLK' => R, 'BREAK' => R,
    'LAMBDA' => RIR, 'BLOCK' => RIR, 'METHOD' => RIR, 'EXEC' => RIR,
    'RANGE_INC' => R, 'RANGE_EXC' => R, 'SCLASS' => R, 'TCLASS' => R, 'OCLASS' => R,
    'INTERN' => R, 'ARYSPLAT' => R, 'EXCEPT' => R, 'RAISEIF' => R, 'MATCHERR' => R,
    'DEF' => %i[reg sym preg].freeze,
    'TDEF' => %i[reg sym irep].freeze, 'SDEF' => %i[reg sym irep].freeze,
    'UNDEF' => %i[sym].freeze, 'ALIAS' => %i[sym name].freeze,
    'ADD' => RP, 'SUB' => RP, 'MUL' => RP, 'DIV' => RP, 'LT' => RP, 'LE' => RP, 'GT' => RP,
    'GE' => RP, 'EQ' => RP,
    'ADDI' => RI, 'SUBI' => RI,
    'ADDILV' => %i[reg reg int].freeze, 'SUBILV' => %i[reg reg int].freeze,
    'ARRAY' => RI, 'ARYPUSH' => RI, 'HASH' => RI, 'HASHADD' => RI,
    'ARYCAT' => RP, 'STRCAT' => RP, 'HASHCAT' => RP,
    'AREF' => %i[reg reg int].freeze, 'ASET' => %i[reg reg int].freeze,
    'APOST' => %i[reg int int].freeze,
    'SYMBOL' => %i[reg pool].freeze, 'STRING' => %i[reg pool].freeze,
    'CLASS' => RS, 'MODULE' => RS,
    'ERR' => %i[rest].freeze,
    'DEBUG' => %i[int int int].freeze
  }.freeze

  # `ARRAY2` is printed as `ARRAY` with a source register in front of the count.
  ARRAY2_SCHEMA = %i[reg reg int].freeze

  def self.schema_for(op, token_count)
    return ARRAY2_SCHEMA if op == 'ARRAY' && token_count == 3

    SCHEMAS[op]
  end

  # The operand text of an instruction with mrbc's trailing `\t; comment`
  # removed.
  def self.strip_comment(args)
    args.sub(/\s*;.*\z/m, '')
  end

  # Parses +args+ into an Array of Operand, or nil when the text does not fit
  # the opcode's schema (an unknown opcode or a print form this table lacks).
  def self.parse(op, args)
    text = strip_comment(args).strip
    tokens = text.split(/\s+/)
    schema = schema_for(op, tokens.length)
    return nil unless schema

    operands = []
    schema.each_with_index do |kind, i|
      if kind == :rest
        operands << Operand.new(:rest, tokens[i..].to_a.join(' '))
        tokens = tokens.first(i + 1)
        next
      end
      token = tokens[i] or return nil
      operand = parse_token(kind, token) or return nil
      operands << operand
    end
    return nil unless operands.length == schema.length && tokens.length == schema.length

    operands.freeze
  end

  def self.parse_token(kind, token)
    case kind
    when :reg then (m = token.match(/\AR(\d+)\z/)) && Operand.new(:reg, m[1].to_i)
    when :preg then (m = token.match(/\A\(R(\d+)\)\z/)) && Operand.new(:preg, m[1].to_i)
    when :idx0 then (m = token.match(/\AR(\d+)\[0\]\z/)) && Operand.new(:idx0, m[1].to_i)
    when :sym then token.start_with?(':') && token.length > 1 && Operand.new(:sym, token[1..])
    when :name then Operand.new(:name, token)
    when :mcnst
      (m = token.match(/\A\(R(\d+)\)::(.+)\z/)) && Operand.new(:mcnst, [m[1].to_i, m[2]])
    when :pool then (m = token.match(/\AL\[(\d+)\]\z/)) && Operand.new(:pool, m[1].to_i)
    when :irep then (m = token.match(/\AI\[(\d+)\]\z/)) && Operand.new(:irep, m[1].to_i)
    when :int then token.match?(/\A-?\d+\z/) && Operand.new(:int, token.to_i)
    when :addr then token.match?(/\A\d+\z/) && Operand.new(:addr, token.to_i)
    when :argc then parse_argc(token)
    when :spec then token.match?(/\A\d+(?::\d+){3}\z/) && Operand.new(:spec, token.split(':').map(&:to_i))
    when :enter
      token.match?(/\A\d+(?::\d+){7}\z/) && Operand.new(:enter, token.split(':').map(&:to_i))
    when :plit then token.match?(/\A\(.*\)\z/) && Operand.new(:plit, token[1..-2])
    end
  end

  def self.parse_argc(token)
    m = token.match(/\An=(\d+|\*)(?:\|nk=(\d+|\*))?\z/) or return nil
    n = m[1] == '*' ? nil : m[1].to_i
    nk = m[2].nil? ? 0 : (m[2] == '*' ? nil : m[2].to_i)
    Operand.new(:argc, [n, nk, m[2].nil?])
  end

  # Canonical single-space text of typed operands, comparable with
  # `tokens.join(' ')` of the source operand text.
  def self.to_text(operands)
    operands.map { |o| operand_text(o) }.join(' ')
  end

  def self.operand_text(operand)
    v = operand.value
    case operand.kind
    when :reg then "R#{v}"
    when :preg then "(R#{v})"
    when :idx0 then "R#{v}[0]"
    when :sym then ":#{v}"
    when :name, :rest then v
    when :mcnst then "(R#{v[0]})::#{v[1]}"
    when :pool then "L[#{v}]"
    when :irep then "I[#{v}]"
    when :int then v.to_s
    when :addr then format('%03d', v)
    when :argc then argc_text(v)
    when :spec, :enter then v.join(':')
    when :plit then "(#{v})"
    end
  end

  def self.argc_text(value)
    n, nk, no_nk = value
    text = "n=#{n.nil? ? '*' : n}"
    text += "|nk=#{nk.nil? ? '*' : nk}" unless no_nk
    text
  end
end
