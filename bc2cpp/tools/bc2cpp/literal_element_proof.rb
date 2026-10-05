# frozen_string_literal: true

# Fresh, in-bounds array reads need no alias or mutation summary (ADR 0354).
module LiteralElementProof
  module_function

  def mask(irep, index, opaque)
    return nil if ENV['BC2CPP_LITERAL_ELEMENT_PROOF'] == '0'

    program = BytecodeIR.for(irep)
    return nil if program.handlers?

    insns = irep.instructions
    read = insns[index]
    return nil unless %w[GETIDX GETIDX0].include?(read.op)

    receiver = read.op == 'GETIDX' ? read.reg.to_i : read.regs[1].to_i
    literal_index = 0
    origin = index - 1
    if read.op == 'GETIDX'
      key = insns[origin]
      return nil unless key && key.reg.to_i == receiver + 1

      literal_index = integer_literal(key)
      return nil unless literal_index

      origin -= 1
    end
    array = insns[origin]
    return nil unless array && %w[ARRAY ARRAY2].include?(array.op) && array.reg.to_i == receiver

    source, count = array.src_and_literal || [array.reg.to_i, array.uint_operand]
    count = count.to_i if count
    return nil unless count && count.positive? && literal_index.between?(-count, count - 1)

    element = source.to_i + literal_index % count
    return nil if opaque.include?(element.to_s)

    # A linear corridor excludes alternate reaching writes and exception entries.
    cursor = origin - 1
    while cursor >= 0 && origin - cursor <= 32
      writer = insns[cursor]
      return nil unless pure?(writer)
      return nil unless linear?(program, cursor, index)

      if writer.reg.to_i == element
        return literal_mask(writer)
      end
      cursor -= 1
    end
    nil
  end

  def integer_literal(insn)
    return -1 if insn.op == 'LOADI__1'
    return -insn.uint_operand if insn.op == 'LOADINEG' && insn.uint_operand
    return insn.op.delete_prefix('LOADI_').to_i if insn.op.match?(/\ALOADI_[0-7]\z/)
    return insn.imm_operand.to_i if %w[LOADI8 LOADI16 LOADI32].include?(insn.op) && insn.imm_operand

    nil
  end

  def pure?(insn)
    insn.op.start_with?('LOADI') || %w[STRING LOADNIL ARRAY ARRAY2].include?(insn.op)
  end

  def literal_mask(insn)
    case insn.op
    when /\ALOADI/ then NumericFlow::INT
    when 'STRING' then NumericFlow::STR
    when 'LOADNIL' then NumericFlow::NIL
    when 'ARRAY', 'ARRAY2' then NumericFlow::ARR
    end
  end

  def linear?(program, first, last)
    predecessors = program.instance_variable_get(:@literal_element_predecessors)
    unless predecessors
      predecessors = Hash.new { |hash, key| hash[key] = [] }
      program.instructions.each_with_index do |insn, source|
        insn.successors.each { |target| predecessors[target] << source }
      end
      program.instance_variable_set(:@literal_element_predecessors, predecessors)
    end
    ((first + 1)..last).all? { |target| predecessors[target] == [target - 1] }
  end
end
