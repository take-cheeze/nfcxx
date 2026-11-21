# frozen_string_literal: true

require_relative 'bytecode_ir'
require_relative 'bytecode_ir_ops'
require_relative 'dynamic_names'

# CAPTURED_LOCAL_CLASS's world condition, shared by CodeGen and RECORD_FIELD_TRACE: every write of a local is an
# instruction of its frame or a SETUPVAR of a block nested in it. Only a write by name (Binding#local_variable_set,
# eval) could bypass them, so the condition is that the build cannot reach one.
module CapturedLocalWriters
  # Sends that can store into a local without a SETUPVAR the bytecode shows.
  NAMES = %w[binding local_variable_set eval].freeze
  # A rebinding send runs a block under another self; a string argument is an eval of source text.
  STRING_EVALS = %w[instance_eval class_eval module_eval instance_exec class_exec module_exec].freeze

  module_function

  # No native of the build implements or calls a way to write a local by name (so a computed-name send has nothing
  # to reach), no outside Ruby spells one, and no send, symbol or string of the world names one. A rebinding send
  # with a literal block is fine (its SETUPVARs are visible); without one it may eval text.
  def absent?(ireps, closed_world)
    return false unless closed_world && closed_world.global_refusal.nil?
    return false if NAMES.any? { |name| !closed_world.native_paths_spelling(name).empty? || closed_world.outside_ruby_token?(name) }

    ireps.each_value do |irep|
      BytecodeIR.for(irep).each_source do |insn, idx|
        sym = insn.sym
        next unless sym

        return false if NAMES.include?(sym)
        return false if STRING_EVALS.include?(sym) && BytecodeIR::Ops::SEND_FAMILY.include?(insn.op) &&
                        !literal_block_argument?(irep, idx, insn)
      end
    end
    !DynamicNames.universe(ireps).intersect?(NAMES)
  end

  # The block operand of the send at +idx+ is a literal block (BLOCK/LAMBDA) on every path.
  def literal_block_argument?(irep, idx, insn)
    return false unless BytecodeIR::Ops::BLOCK_SEND_FAMILY.include?(insn.op) && insn.reg

    n = insn.argc
    return false unless n

    writers = BytecodeIR.reaching_writer_indices(irep, idx, (insn.reg + n + 1))
    program = BytecodeIR.for(irep)
    writers&.all? { |i| BytecodeIR::Ops::LITERAL_PROC.include?(program.source_at(i).op) } || false
  end
end
