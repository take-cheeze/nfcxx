# frozen_string_literal: true

require 'set'
require_relative 'bytecode_ir'
require_relative 'bytecode_ir_ops'

# IR_BLOCK_OPERANDS: what a send's block operand, a receiver or an argument register holds, answered by
# BytecodeIR reaching definitions instead of the instruction textually before the read. Every query counts nested
# blocks' SETUPVAR writes, crosses handler edges and uses the origin walk's RESCUE/EXCEPT/ENTER model (a slot ENTER
# stores is defined by the ENTER), and a refused query is nil: each caller states what nil means.
module IrBlockOperands
  LITERAL_BLOCK_OPS = Set['BLOCK', 'LAMBDA'].freeze
  CONST_LOADS = Set['GETCONST', 'GETMCNST'].freeze

  module_function

  # Definitions of +reg+ reaching the read at +index+, or nil when the IR cannot list them.
  def definitions(irep, index, reg, follow_moves: true)
    return nil unless index.is_a?(Integer) && index.between?(0, irep.instructions.length - 1)

    defs = BytecodeIR.reaching_definitions(irep, index, reg.to_s, follow_moves: follow_moves, through_handlers: true,
                                                                  origin_transfers: true)
    defs && !defs.empty? ? defs : nil
  end

  # The register a SENDB/SSENDB reads its block from (vm.c OP_SENDB: R(a + argc + kwargs + 1), a packed `*` argument
  # list and a packed `**` hash taking one register each), as digits.
  def block_register(insn)
    return nil unless insn.reg && insn.argc_operand

    n, nk, = insn.argc_operand
    positional = n.nil? ? 1 : n
    keywords = if insn.nk_spec.nil? then 0
               elsif nk.nil? then 1
               else 2 * nk
               end
    (insn.reg.to_i + positional + keywords + 1).to_s
  end

  # Labels of the literal blocks the block operand of the send at +index+ can be, when every reaching definition is a
  # BLOCK/LAMBDA of +irep+; nil otherwise (a forwarded block, a stored Proc, nil, or an unprovable operand).
  def literal_block_labels(irep, index)
    insn = irep.instructions[index]
    return nil unless insn && BytecodeIR::Ops::BLOCK_SEND.include?(insn.op)

    reg = block_register(insn) or return nil
    defs = definitions(irep, index, reg) or return nil
    labels = defs.map do |df|
      return nil if df.entry?

      writer = irep.instructions[df.index]
      return nil unless LITERAL_BLOCK_OPS.include?(writer.op) && writer.block_index

      Array(irep.reps)[writer.block_index.to_i] or return nil
    end
    labels.uniq
  end

  # The one literal block the send at +index+ is given, or nil.
  def literal_block_label(irep, index)
    labels = literal_block_labels(irep, index)
    labels&.size == 1 ? labels.first : nil
  end

  # Name of the constant every definition of +reg+ reaching +index+ loads (GETCONST/GETMCNST of one name), or nil.
  def constant_name(irep, index, reg)
    defs = definitions(irep, index, reg) or return nil
    names = defs.map do |df|
      return nil if df.entry?

      writer = irep.instructions[df.index]
      return nil unless CONST_LOADS.include?(writer.op)

      writer.const_name.to_s
    end.uniq
    names.size == 1 && !names.first.empty? ? names.first : nil
  end

  # Do all definitions reaching +index+ come from writers whose op satisfies the block? false when unprovable.
  def all_writers?(irep, index, reg)
    defs = definitions(irep, index, reg) or return false
    defs.all? { |df| !df.entry? && yield(irep.instructions[df.index]) }
  end

  # Can an execution reach instruction +index+ (normal or handler edges)? true when the edges do not resolve.
  def live?(irep, index)
    program = BytecodeIR.for(irep)
    @live ||= {}.compare_by_identity
    live = @live.fetch(program) { @live[program] = compute_live(program) }
    live.nil? || live.include?(index)
  end

  def compute_live(program)
    return nil unless program.resolved? && program.handlers_resolved?

    handlers = program.raise_targets
    seen = Set.new
    stack = [0]
    until stack.empty?
      index = stack.pop
      next if index.nil? || !seen.add?(index)

      stack.concat(Array(program.successor_lists[index]))
      stack.concat(handlers.fetch(index, []))
    end
    seen
  end
end
