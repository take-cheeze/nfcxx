# frozen_string_literal: true

require_relative 'numeric_flow'

# No admitted instruction can call Ruby, allocate an object, or mutate an ivar.
module ReadonlyCallEffects
  OPS = Set['ENTER', 'MOVE', 'LOADSELF', 'LOADNIL', 'LOADT', 'LOADF', 'GETIV',
            'RETURN', 'RETSELF', 'RETNIL', 'RETTRUE', 'RETFALSE', 'JMP', 'JMPIF', 'JMPNOT', 'JMPNIL'].freeze

  def self.safe?(body)
    return false unless body && Array(body.reps).empty?
    return false unless body.enter&.enter_fields == Array.new(8, 0)

    program = BytecodeIR.for(body)
    return false unless program.resolved? && !program.handlers?

    body.instructions.all? { |insn| OPS.include?(insn.op) || insn.op.match?(/\ALOADI(?:_\d+|16|32)?\z/) }
  end
end

class CodeGen
  def readonly_class_call?(irep, insn, state)
    return false if ENV['BC2CPP_READONLY_CALL_EFFECTS'] == '0'
    return false unless @rc_scoped_ready && @closed_world&.exact_instances_singleton_free?
    return false unless insn.op == 'SEND0' || (insn.op == 'SEND' && insn.plain_fixed_argc? && insn.argc.zero?)

    receiver = state[insn.reg.to_i]
    return false unless receiver.is_a?(Integer) && receiver.positive?

    classes = (@numeric_class_bits || {}).select { |_klass, bit| receiver.anybits?(bit) }
    return false unless (1..8).cover?(classes.size) && classes.values.reduce(0, :|) == receiver

    classes.all? do |klass, _bit|
      definition = closed_world_exact_target(insn.sym, klass)
      definition&.irep && ReadonlyCallEffects.safe?(@ireps[definition.irep])
    end
  end
end
