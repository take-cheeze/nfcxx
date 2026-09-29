# frozen_string_literal: true

# Steps 6e and 6h: annotation candidates and static call targets (diagnostic only).

# ---------------------------------------------------------------------------
# Step 6e: annotation-candidate report (diagnostic only): SETIV sites whose
# source is an untouched incoming mandatory argument not already resolved by
# ArgTypes or an annotation, i.e. where a magic comment would matter.
# ---------------------------------------------------------------------------

# Like IvarLayout.trace_type, but returns nil at any writer: non-nil means
# `reg` (after MOVEs) is a bare incoming argument.
def opaque_argument_position(irep, idx, reg, mand)
  entry_reg = irep.walk_writers(idx - 1, reg, follow_moves: true, exhausted: ->(last) { last }) { nil }
  return nil unless entry_reg

  pos = entry_reg.to_i
  pos.between?(1, mand) ? pos : nil
end

def report_annotation_candidates(ireps, registry, arg_types, annotations)
  candidates = []
  registry.each_value do |defs|
    defs.each do |d|
      next unless d.irep

      # Mirrors drop_unsafe_embeddings: nothing on this class embeds unless its
      # #initialize is registered and compilable, so annotating is pointless
      # otherwise.
      init = registry.fetch('initialize', []).find { |md| md.owner == d.owner }
      next unless init&.irep && pure_mandatory_arity?(ireps.fetch(init.irep))

      irep = ireps.fetch(d.irep)
      enter = irep.instructions.find { |i| i.op == 'ENTER' }
      mand = enter ? enter.enter_fields.first : 0
      next if mand.zero?

      already_at = lambda do |pos|
        annotations[irep.label]&.args&.[](pos - 1) || arg_types[d.name]&.[](pos - 1)
      end
      seen_pos = Set.new

      irep.instructions.each_with_index do |insn, idx|
        next unless insn.op == 'SETIV'

        src_reg = insn.regs.first
        pos = opaque_argument_position(irep, idx, src_reg, mand)
        next unless pos
        next if already_at.call(pos)

        ivar = insn.ivar
        candidates << { owner: d.owner, name: d.name, ivar: ivar, pos: pos, mand: mand, via: 'SETIV' }
        seen_pos << pos
      end

      # Diagnostic only: an opaque argument used directly by fixnum-fastpath
      # arithmetic/comparison. Annotating it changes no output (trace_type only
      # reaches arguments from SETIV traces); it documents intent.
      irep.instructions.each_with_index do |insn, idx|
        regs = case insn.op
               when 'ADD', 'SUB', 'MUL', 'EQ', 'LT', 'LE', 'GT', 'GE'
                 [insn.reg, insn.paren_reg]
               when 'ADDI', 'SUBI'
                 [insn.reg]
               else
                 []
               end
        regs.compact.each do |reg|
          pos = opaque_argument_position(irep, idx, reg, mand)
          next unless pos
          next if seen_pos.include?(pos) || already_at.call(pos)

          candidates << { owner: d.owner, name: d.name, ivar: nil, pos: pos, mand: mand, via: insn.op }
          seen_pos << pos
        end
      end
    end
  end
  candidates
end

# ---------------------------------------------------------------------------
# Step 6h: static call-target reachability (diagnostic only, feeds "== never
# called =="): is a name ever a call target in the program's bytecode? A
# compiled entry point missing here and from extract_native_call_names has no
# known caller. Names are collected from:
#   - SEND0/SEND/SSEND0/SSEND/SENDB/SSENDB `:name` operands;
#   - fixed-name opcodes (ADD/SUB/.../GETIDX/SETIDX and *I variants), whose
#     fallback calls a hardcoded name: IMPLICIT_DISPATCH_NAMES must stay in
#     sync with compile_insn/compile_cmp's mrb_funcall fallbacks;
#   - LOADSYM symbol literals (send, method, &:name, respond_to?, or plain
#     data): over-counting only shrinks the "never called" list.
# ---------------------------------------------------------------------------

IMPLICIT_DISPATCH_NAMES = {
  'ADD' => '+', 'ADDI' => '+', 'ADDILV' => '+',
  'SUB' => '-', 'SUBI' => '-', 'SUBILV' => '-',
  'MUL' => '*', 'DIV' => '/',
  'EQ' => '==', 'LT' => '<', 'LE' => '<=', 'GT' => '>', 'GE' => '>=',
  'GETIDX' => '[]', 'GETIDX0' => '[]', 'SETIDX' => '[]=',
}.freeze

def collect_static_call_target_names(ireps)
  names = Set.new
  ireps.each_value do |irep|
    (irep.instructions || []).each do |insn|
      case insn.op
      # SENDB/SSENDB count too (docs/adr/0203): a method only called with a block
      # is still called.
      when 'SEND0', 'SEND', 'SSEND0', 'SSEND', 'SENDB', 'SSENDB', 'LOADSYM'
        name = insn.sym
        names << name if name
      else
        fixed = IMPLICIT_DISPATCH_NAMES[insn.op]
        names << fixed if fixed
      end
    end
  end
  names
end
