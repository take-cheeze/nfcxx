# frozen_string_literal: true

# The typed operands of the ops NilNarrowing reads, built from an instruction's `source` (InsnOperands accessors).
# Program#decoded carries only the op, branch kind, leading register and target, so a pass needing more asks here.
# Every value is the String the Insn accessor returns, unchanged. Ops outside this slice still read `source`.
module BytecodeIR
  module OperandModel
    # MOVE R(dest) R(src): both registers, in operand order (Insn#regs).
    Move = Struct.new(:dest, :src)
    # A method send: the receiver register (Insn#reg, the leading operand) and the method name (Insn#sym).
    Send = Struct.new(:receiver, :name)

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
  end
end
