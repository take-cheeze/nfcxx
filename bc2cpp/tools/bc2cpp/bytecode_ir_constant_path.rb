# frozen_string_literal: true

require_relative 'bytecode_ir_regions'

# The constant expression a register holds, as a Program query: it is a pure
# reaching-definition question over the instruction list (walk_writers), so it
# belongs beside the other register queries rather than on Irep. Irep#constant_path
# (irep_scans.rb) delegates here.
module BytecodeIR
  # A constant expression read back from a register (Program#constant_path).
  # +root+ is :const (GETCONST), :object (OCLASS) or :nil (LOADNIL); +name+ and
  # +root_index+ are the GETCONST's name and instruction index (nil for the
  # others); +segments+ are the GETMCNST names applied on top, outermost first.
  ConstantPath = Struct.new(:root, :name, :root_index, :segments, :qualified)

  class Program
    # The constant expression held in +reg+ at instruction +from+ (inclusive):
    # MOVEs and GETMCNST scopes followed back to the GETCONST / OCLASS / LOADNIL
    # that roots it. Nil when anything else writes the register on the way (or
    # the register is never written). +skip_ops+ / +barrier+ are walk_writers'.
    # GETMCNST always carries its `::Name` (OperandSchema), so a segment is never nil.
    def constant_path(from, reg, skip_ops: nil, barrier: nil)
      segments = []
      qualified = false
      walk_writers(from, reg, skip_ops: skip_ops, barrier: barrier, follow_moves: true) do |insn, index|
        case insn.op
        when 'GETMCNST'
          segment = insn.mcnst_name
          next nil unless segment

          qualified = true
          segments.unshift(segment)
          KEEP
        when 'GETCONST'
          ConstantPath.new(:const, insn.const_name, index, segments, qualified)
        when 'OCLASS'
          ConstantPath.new(:object, nil, nil, segments, qualified)
        when 'LOADNIL'
          ConstantPath.new(:nil, nil, nil, segments, qualified)
        end
      end
    end
  end
end
