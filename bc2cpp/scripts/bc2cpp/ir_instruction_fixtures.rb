# frozen_string_literal: true

# Keep addresses and operands explicit: joins and handlers rely on the exact control-flow shape.
module IrInstructionFixtures
  def insn(addr, op, args)
    Insn.new(lineno: 1, addr: addr, op: op, args: args, raw: "#{op} #{args}")
  end

end
