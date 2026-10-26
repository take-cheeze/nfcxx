# frozen_string_literal: true

# The typed operands of the ops NilNarrowing and ESCAPE_ANALYSIS's Analyzer#step read, built from an instruction's
# `source` (InsnOperands accessors). Program#decoded carries only the op, branch kind, leading register and target,
# so a pass needing more asks here. Every value is what the Insn accessor returns, unchanged. Ops and addresses are
# not modelled; they still come from `source`.
module BytecodeIR
  module OperandModel
    # MOVE R(dest) R(src): both registers, in operand order (Insn#regs).
    Move = Struct.new(:dest, :src)
    # A method send: the receiver register (Insn#reg, the leading operand) and the method name (Insn#sym).
    Send = Struct.new(:receiver, :name)
    # Numeric counts plus explicit flags: nil alone cannot distinguish absent counts from splats.
    ArgcSpec = Struct.new(:positional, :keyword, :positional_splat, :keyword_present, :keyword_splat) do
      def positional_splat? = positional_splat
      def keyword? = keyword_present
      def keyword_splat? = keyword_splat
      def positional_slots = positional_splat? ? 1 : (positional || 0)
      def keyword_slots = keyword_splat? ? 1 : 2 * (keyword || 0)
    end

    module_function

    def move(insn)
      dest, src = insn.regs
      Move.new(dest, src)
    end

    def send_call(insn)
      Send.new(insn.reg, insn.sym)
    end

    # The register a conditional branch (JMPIF, JMPNOT, JMPNIL) tests: its leading operand (Insn#reg).
    def test_reg(insn)
      insn.reg
    end

    # The leading register (Insn#reg), nil unless the leading operand is a register.
    def reg(insn)
      insn.reg
    end

    # Every register operand in order (Insn#regs).
    def regs(insn)
      insn.regs
    end

    # The first register operand wherever it sits (Insn#reg_operand).
    def reg_operand(insn)
      insn.reg_operand
    end

    # Formatting is reserved for Insn#argc_text and the legacy textual accessors.
    def argc_spec(insn)
      ArgcSpec.new(insn.argc, insn.keyword_argc, insn.positional_splat?, insn.keyword_arguments?, insn.keyword_splat?)
    end

    # The integer right after the leading register (Insn#uint_operand).
    def uint_operand(insn)
      insn.uint_operand
    end

    # The signed literal right after the leading register, as printed (`R1 -5`), as a String (Insn#imm_operand).
    # LOADI_0..LOADI_7 and LOADI__1 have no second operand (the value is in the opcode), so they read nil.
    def imm_operand(insn)
      second = insn.typed[1]
      reg(insn) && second&.kind == :int ? second.value.to_s : nil
    end

    # `R1 R2 3` as [source register, literal] (Insn#src_and_literal).
    def src_and_literal(insn)
      insn.src_and_literal
    end

    # The text inside the first parentheses (Insn#paren_value): `(0)` of BLKPUSH.
    def paren_value(insn)
      insn.paren_value
    end

    # The post-argument count of APOST R(a) pre post: its third operand's value (Insn#typed).
    def post_count(insn)
      insn.typed[2].value
    end
  end
end
