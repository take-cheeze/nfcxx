# frozen_string_literal: true

# BytecodeIR facade: the core (bytecode_ir_core.rb) plus every analysis part that reopens `module BytecodeIR`.
# The parts require the core, never this file, so no require cycle exists; consumers require this file.
require_relative 'bytecode_ir_core'
require_relative 'bytecode_ir_handlers'
require_relative 'bytecode_ir_dataflow'
require_relative 'bytecode_ir_types'
require_relative 'bytecode_ir_classes'
require_relative 'bytecode_ir_tree'
require_relative 'bytecode_ir_operands'
require_relative 'bytecode_ir_constant_path'
require_relative 'bytecode_ir_containers'
