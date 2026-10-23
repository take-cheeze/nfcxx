# frozen_string_literal: true

require_relative 'bytecode_ir'

# Class and module body discovery on the IR, shared by every walk that
# descends into a CLASS/MODULE/SCLASS body.
module BytecodeIR
  # { opener index => body irep label } for each of +ops+ in +irep+ whose body
  # EXEC is the literal next instruction on the opener's register. An empty
  # body (`class Timeout < StandardError; end`) has no EXEC, so a later EXEC on
  # that register is not its body.
  def self.class_bodies(irep, *ops)
    bodies = {}
    program = self.for(irep)
    irep.each_with_op(*ops) do |insn, idx|
      exec = program.source_at(idx + 1)
      next unless exec&.op == 'EXEC' && exec.reg_token == insn.reg_token

      bodies[idx] = irep.reps[exec.block_index]
    end
    bodies
  end

  # The qualified name of the CLASS/MODULE at +idx+ when its outer scope is
  # agreed by every reaching definition in the IR: LOADNIL (the lexical +namespace+, nil at top level) or
  # OCLASS (`class ::Name`). Nil otherwise; a constant-path outer is resolved
  # by the caller.
  def self.class_body_path(irep, idx, namespace)
    program = self.for(irep)
    insn = program.source_at(idx)
    definitions = reaching_definitions(irep, idx, insn.reg, through_handlers: true, origin_transfers: true)
    return nil if definitions.nil? || definitions.empty? || definitions.any?(&:entry?)

    paths = definitions.map do |definition|
      case program.source_at(definition.index).op
      when 'LOADNIL' then namespace ? "#{namespace}::#{insn.sym}" : insn.sym
      when 'OCLASS' then insn.sym
      end
    end
    paths.first if paths.first && paths.uniq.size == 1
  end
end
