# frozen_string_literal: true

require 'set'
require_relative 'bytecode_ir'
require_relative 'bytecode_ir_containers'
require_relative 'ir_symbol_flow'

# Sealed int16 local arrays (opt-in: BC2CPP_SEALED_INT16=1, default off).
#
# A local array literal of int16-range literals, indexed and stored inside one method, is emitted as a
# std::vector<int16_t> instead of an mrb_value Array. The proof is per array creation (an ARRAY instruction):
#
#   * the method has no nested blocks and no rescue/ensure ranges, so no other frame can reach the array;
#   * every element is a single literal integer, in int16 range, that reaches the ARRAY;
#   * every register read that a value of the array can reach is one of the sealed forms: MOVE (an alias copy),
#     GETIDX / GETIDX0 with a literal index, SETIDX with a literal index inside the fixed size and a literal
#     int16 value, or SEND0 `size`. Any other read refuses the whole array, so the array never escapes;
#   * the size never changes (no op in the sealed set grows the array), so the size is a compile-time constant.
#
# A read of a value that is not the array (an element, a method result) is not a use of the array and is left
# alone: only reads whose reaching definitions are all array definitions count.
#
# This is a proof, not a hint. Reaching definitions come from BytecodeIR.producers, and a read that any unlisted
# definition could reach refuses the array.
module SealedInt16Locals
  RANGE = (-32_768..32_767)
  SIZE_SYM = 'size'

  # One proven array: the ARRAY index, the register it was created in, its fixed size, its element values, its
  # instruction actions, and `range`: the [lo, hi] hull of every value it ever holds (the ARRAY literals and every
  # SETIDX literal). Every element an in-range read yields is in `range`, so the read is an int16 Fixnum.
  Proven = Struct.new(:index, :dst, :size, :values, :actions, :range)

  module_function

  def enabled?
    ENV['BC2CPP_SEALED_INT16'] == '1'
  end

  # The proven arrays of +irep+, each with its instruction actions keyed by instruction index. Empty unless the
  # switch is on and the method has no blocks or rescue ranges.
  def plan(irep)
    return [] unless enabled? && irep.reps.to_a.empty? && irep.catch_handlers.to_a.empty?

    prog = BytecodeIR.for(irep)
    claimed = Set.new
    proven = []
    prog.each_with_op(:ARRAY) do |insn, i|
      array = prove(irep, prog, i, insn)
      next unless array
      next if array.actions.keys.any? { |j| claimed.include?(j) }

      claimed.merge(array.actions.keys)
      proven << array
    end
    proven
  end

  # The Proven array created at +i+, or nil when the proof fails.
  def prove(irep, prog, i, insn)
    three = insn.src_and_literal
    dst = insn.reg.to_i
    src = three ? three[0].to_i : dst
    size = three ? three[1].to_i : insn.uint_operand.to_i
    return nil unless size.positive?

    values = (0...size).map do |k|
      value = literal_value(irep, prog, i, src + k)
      return nil unless value && RANGE.cover?(value)

      value
    end

    defs = Set[i]
    aliases = Set[dst]
    grow_aliases(irep, prog, defs, aliases)

    actions = {}
    (0...prog.size).each do |j|
      insn_j = prog.source_at(j)
      next unless insn_j

      IrSymbolFlow.reads(irep, insn_j).each do |reg|
        next unless aliases.include?(reg)

        producers = BytecodeIR.producers(irep, j, reg)
        next if producers.nil? || producers.empty?

        from_array = producers.select { |p| !p.entry? && defs.include?(p.index) }
        next if from_array.empty?
        return nil unless from_array.size == producers.size

        action = sealed_action(irep, prog, j, insn_j, reg, size)
        return nil unless action

        actions[j] = action
      end
    end
    return nil if actions.empty?

    stored = values + actions.values.select { |a| a[:kind] == :set }.map { |a| a[:value] }
    Proven.new(i, dst, size, values, actions, [stored.min, stored.max])
  end

  # Follow MOVE copies whose source reaches only array definitions: each copy is another alias of the array.
  def grow_aliases(irep, prog, defs, aliases)
    changed = true
    while changed
      changed = false
      prog.each_with_op(:MOVE) do |insn, j|
        dst, src = insn.regs.first(2).map(&:to_i)
        next unless aliases.include?(src) && !aliases.include?(dst)

        producers = BytecodeIR.producers(irep, j, src)
        next if producers.nil? || producers.empty?
        next unless producers.all? { |p| !p.entry? && defs.include?(p.index) }

        defs << j
        aliases << dst
        changed = true
      end
    end
  end

  # The sealed action for reading +reg+ (the array) at instruction +j+, or nil when the read is not a sealed form.
  def sealed_action(irep, prog, j, insn, reg, size)
    case insn.op
    when :MOVE
      { kind: :alias } if insn.regs[1].to_i == reg
    when :GETIDX
      index = literal_value(irep, prog, j, insn.regs[0].to_i + 1)
      { kind: :get, dst: insn.regs[0].to_i, index: index } if index && index >= 0 && insn.regs[0].to_i == reg
    when :GETIDX0
      { kind: :get, dst: insn.regs[0].to_i, index: 0 } if insn.regs[1].to_i == reg
    when :SETIDX
      receiver = insn.regs[0].to_i
      return nil unless receiver == reg

      index = literal_value(irep, prog, j, receiver + 1)
      value = literal_value(irep, prog, j, receiver + 2)
      return nil unless index && index >= 0 && index < size && value && RANGE.cover?(value)

      { kind: :set, dst: receiver, index: index, value_reg: receiver + 2, value: value }
    when :SEND0
      { kind: :size, dst: insn.regs[0].to_i } if insn.regs[0].to_i == reg && insn.sym == SIZE_SYM
    end
  end

  # The integer literal that is the only definition of +reg+ reaching +at+, or nil.
  def literal_value(irep, prog, at, reg)
    producers = BytecodeIR.producers(irep, at, reg)
    return nil unless producers&.size == 1 && !producers.first.entry?

    insn = producers.first.insn
    return nil unless BytecodeIR::Ops::LOADI_OPS.include?(insn&.op)

    loadi_value(insn)
  end

  # The value a LOADI-family instruction loads (the same decode as BytecodeIR::ConstantFacts#loadi_value).
  def loadi_value(insn)
    return BytecodeIR::Ops::LOADI_SLOT_VALUE[insn.op] if BytecodeIR::Ops::LOADI_SLOT.include?(insn.op)
    return -1 if insn.op == :LOADI__1

    BytecodeIR::OperandModel.imm_operand(insn)&.to_i
  end
end
