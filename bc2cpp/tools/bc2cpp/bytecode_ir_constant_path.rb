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
    # The constant expression held in +reg+ at instruction +from+ (inclusive), rooted at the
    # GETCONST / OCLASS / LOADNIL that every reaching definition agrees on (GETMCNST scopes
    # are followed through the same register). Nil when the definitions disagree, a value
    # comes from the frame entry, or anything else writes the register. A join of two
    # constants (`c ? Array : Hash`) is therefore nil, not the textually nearest arm.
    # GETMCNST always carries its `::Name` (OperandSchema), so a segment is never nil.
    #
    # +barrier+ callers keep the textual walk (constant_path_walk): their barrier ops are
    # the proof, and codegen_receiver_facts asks every reaching definition itself.
    def constant_path(from, reg, skip_ops: nil, barrier: nil)
      return constant_path_walk(from, reg, skip_ops: skip_ops, barrier: barrier) if barrier

      # +from+ is inclusive, so the definitions are those reaching the instruction after it.
      constant_path_at(from + 1, reg.to_s, Set[])
    end

    # Every reaching definition of +reg+ at +from+ must produce the same constant expression.
    # +active+ holds the GETMCNST writers being expanded, so a scope cycle through a loop refuses.
    def constant_path_at(from, reg, active)
      writers = BytecodeIR.writers_reaching(@irep, from, reg)
      return nil unless writers

      paths = writers.map { |index, insn| constant_path_of_writer(index, insn, active) }
      first = paths.first
      return nil unless first && paths.all? { |path| same_constant_path?(path, first) }

      first
    end

    def constant_path_of_writer(index, insn, active)
      case insn.op
      when 'GETCONST' then ConstantPath.new(:const, insn.const_name, index, [], false)
      when 'OCLASS' then ConstantPath.new(:object, nil, nil, [], false)
      when 'LOADNIL' then ConstantPath.new(:nil, nil, nil, [], false)
      when 'GETMCNST'
        segment = insn.mcnst_name
        return nil unless segment && active.add?(index)

        begin
          scope = constant_path_at(index, insn.reg.to_s, active)
        ensure
          active.delete(index)
        end
        return nil unless scope

        ConstantPath.new(scope.root, scope.name, scope.root_index, [*scope.segments, segment], true)
      end
    end

    # Agreement is on the expression, not on where it was written: two GETCONSTs of `Array` at
    # different indices name the same class.
    def same_constant_path?(path, other)
      path && path.root == other.root && path.name == other.name && path.segments == other.segments &&
        path.qualified == other.qualified
    end

    def constant_path_walk(from, reg, skip_ops: nil, barrier: nil)
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
