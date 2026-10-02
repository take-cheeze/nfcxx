# frozen_string_literal: true

require_relative 'numeric_flow'

# CodeGen: NUMERIC_OPERAND_PROOF (ADR 0276).
#
# FIXNUM_OPERAND_PROOF answers "is this register a small Integer", which is what
# a bare `mrb_fixnum()` needs. This answers the weaker "is it an Integer (fixnum
# or bigint) or a Float", which is all mruby's own numeric helpers need: with
# both operands proven, a guarded arm keeps its inline tiers but its last-resort
# else calls the core body (mrb_num_add/sub/mul, bc2cpp_num_div, bc2cpp_num_cmp)
# instead of a dynamic send. Overflow to a bigint stays inside those helpers,
# never in a C `mrb_int`.
#
# The sources live in NumericFlow (a forward dataflow, so loops and joins are
# handled); this file wires the whole-program facts it consumes and emits the
# arms. Every fact is an unguarded proof: a hint or a runtime guard never counts.
# Files: codegen_numeric_args.rb (pooled arguments), _ivars.rb, _returns.rb (also
# the core-send result rules) and _consts.rb.
class CodeGen
  NUMERIC_PROOF_NOTE = '  // NUMERIC_OPERAND_PROOF %s -- both operands proven Integer/Float; core body, no dynamic send'

  # Classes whose Integer/Float bodies the numeric arms may call directly.
  NUMERIC_OP_OWNERS = %w[Integer Float Numeric].freeze

  # NumericFlow's view of this CodeGen's facts.
  class NumericOracle
    def initialize(codegen)
      @cg = codegen
    end

    def entry_mask(irep, reg)
      @cg.numeric_entry_mask(irep, reg)
    end

    def const_mask(insn)
      @cg.numeric_const_mask(insn)
    end

    def ivar_slots(irep)
      @cg.numeric_ivar_slots(irep)
    end

    def ivar_entry_mask(irep, name)
      @cg.numeric_ivar_entry_mask(irep, name)
    end

    def ivar_fact_mask(irep, name)
      @cg.numeric_ivar_fact_mask(irep, name)
    end

    def nil_raises?(sym)
      @cg.numeric_nil_raises?(sym)
    end

    def send_mask(irep, index, insn, state)
      @cg.numeric_send_mask(irep, index, insn, state)
    end

    def index_mask(irep, index, insn, state)
      @cg.element_index_mask(irep, index, insn, state)
    end

    def aref_mask(irep, index, insn, _state)
      @cg.tuple_aref_mask(irep, index, insn)
    end

    def upvar_mask(irep, insn)
      @cg.numeric_upvar_mask(irep, insn)
    end

    def pool_mask(irep, insn)
      entry = insn.pool_index && irep.pool[insn.pool_index.to_i]
      return NumericFlow::OTHER unless entry.is_a?(Hash)

      case entry[:type]
      when :float then NumericFlow::FLT
      when :int32, :int64, :bigint then NumericFlow::INT
      else NumericFlow::OTHER
      end
    end

    def op_native?(sym)
      @cg.numeric_op_native?(sym)
    end
  end

  # Drop every memoized flow. Called once the proofs the flow reads are final
  # (compile probes run earlier with weaker facts).
  def reset_numeric_flow!
    @numeric_states = {}
    @numeric_writes = {}
    @numeric_oracle = NumericOracle.new(self)
    @numeric_op_native = {}
  end

  def numeric_op_native?(sym)
    @numeric_op_native ||= {}
    return @numeric_op_native[sym] if @numeric_op_native.key?(sym)

    @numeric_op_native[sym] = builtin_class_send_safe?(sym, NUMERIC_OP_OWNERS) ? true : false
  end

  # The MethodDef whose body (blocks included) contains +irep+, nil for a class
  # body or the root.
  def numeric_owner_of(irep)
    entry_arg_body_owner[irep.label]
  end

  # nil answers +sym+ only by raising NoMethodError: no Ruby definition on nil's
  # ancestors, no method_missing anywhere that could see nil, and no native
  # definition on NilClass (@nil_operator_names is the scanned set).
  def numeric_nil_raises?(sym)
    @numeric_nil_raises ||= {}
    return @numeric_nil_raises[sym] if @numeric_nil_raises.key?(sym)

    @numeric_nil_raises[sym] =
      !@nil_operator_names.nil? && !@closed_world.nil? && @closed_world.global_refusal.nil? &&
      @closed_world.method_missing_classes.empty? && !@nil_operator_names.include?(sym) &&
      (@registry[sym] || []).none? { |d| %w[NilClass Object Kernel BasicObject].include?(d.owner) }
  end

  # The facts that feed each other -- pooled entry arguments, ivar classes, return
  # classes and constants -- as one least fixpoint of may-sets: every fact starts
  # empty and only grows, and a fact that reaches an unmodelled class is dropped
  # for good. Any post-fixpoint is sound (each value stored, passed or returned
  # has its class in the set, by induction over the events of one run) and the
  # sets only grow, so it terminates. Flows are re-run for exactly the ireps
  # whose inputs changed.
  def compute_numeric_facts
    reset_numeric_flow!
    setup_numeric_entry_args
    setup_numeric_ivar_groups
    setup_lcf_rows
    setup_frozen_tables
    setup_numeric_returns
    setup_tuple_returns
    setup_numeric_consts
    # The numeric flow reads the exact-class flow (NATIVE_RESULT_FACTS, ADR 0302), which reads
    # none of the numeric pools, so it is final before the first numeric pass.
    compute_return_classes
    reset_numeric_flow!
    loop do
      changed = grow_entry_arg_numeric
      changed |= grow_numeric_ivar_groups
      changed |= grow_numeric_returns
      changed |= grow_tuple_returns
      changed |= grow_numeric_consts
      break unless changed
    end
  end

  def numeric_states_for(irep)
    reset_numeric_flow! unless @numeric_states
    return @numeric_states[irep.label] if @numeric_states.key?(irep.label)

    writes = {}
    @numeric_writes[irep.label] = writes
    @numeric_states[irep.label] = NumericFlow.states(irep, @numeric_oracle, fixnum_proof_ctx(irep)[:upvars], writes)
  end

  # Forget the flow of +label+ and of every block nested in it: those read its
  # registers through GETUPVAR (numeric_upvar_mask).
  def numeric_invalidate(label)
    stack = [label]
    until stack.empty?
      cur = stack.pop
      @numeric_states.delete(cur)
      @numeric_writes.delete(cur)
      stack.concat(Array(@ireps[cur]&.reps))
    end
  end

  # child irep label -> [parent irep, index of the BLOCK/LAMBDA creating it].
  def numeric_block_parents
    @numeric_block_parents ||= begin
      map = {}
      @ireps.each_value do |parent|
        parent.instructions.each_with_index do |insn, idx|
          next unless %w[BLOCK LAMBDA].include?(insn.op)

          child = parent.reps[insn.block_index.to_i]
          map[child] = [parent, idx] if child
        end
      end
      map
    end
  end

  # A local of an enclosing method, read by a block through GETUPVAR. The block
  # runs after the closure is created and sees the local as it was then or as any
  # later write of the defining frame left it, so the class set is the defining
  # irep's state at the creating BLOCK joined with everything ever stored into the
  # register there. A register a nested block writes (SETUPVAR) is unknown.
  def numeric_upvar_mask(irep, insn)
    index, level = insn.upvar_ref
    return NumericFlow::OTHER unless index

    cur = irep
    ancestor = nil
    creation = nil
    (level + 1).times do
      link = numeric_block_parents[cur.label]
      return NumericFlow::OTHER unless link

      ancestor, creation = link
      cur = ancestor
    end
    return NumericFlow::OTHER if fixnum_proof_ctx(ancestor)[:upvars].include?(index.to_s)

    states = numeric_states_for(ancestor)
    state = states && states[creation]
    return NumericFlow::OTHER unless state && index < ancestor.nregs.to_i

    state[index] | (@numeric_writes[ancestor.label][index] || 0)
  end

  # Class set of register +reg+ as read by the instruction at +idx+: 0 when the
  # instruction is unreached, nil when the irep is not modelled or a nested block
  # may write the register.
  def numeric_raw_mask(irep, idx, reg, owner_def)
    return nil unless irep && idx && reg && owner_def

    states = numeric_states_for(irep)
    return nil unless states

    state = states[idx]
    return 0 unless state

    r = reg.to_i
    return nil if r >= irep.nregs.to_i || fixnum_proof_ctx(irep)[:upvars].include?(reg.to_s)

    state[r]
  end

  # numeric_raw_mask restricted to a provably Integer/Float register, else nil.
  def numeric_operand_mask(irep, idx, reg, owner_def)
    mask = numeric_raw_mask(irep, idx, reg, owner_def)
    NumericFlow.numeric?(mask) ? mask : nil
  end

  # Class-set names for the diagnostic and the report, e.g. "INT|NIL".
  def numeric_mask_name(mask)
    names = { NumericFlow::INT => 'INT', NumericFlow::FLT => 'FLT', NumericFlow::ARR => 'ARR',
              NumericFlow::HSH => 'HSH', NumericFlow::STR => 'STR', NumericFlow::NIL => 'NIL',
              NumericFlow::OTHER => 'OTHER', NumericFlow::RNG => 'RNG' }
    found = names.filter_map { |bit, name| name if mask.anybits?(bit) }
    @lcf_rows&.kinds&.each { |k| found << @lcf_rows.name(k.bit) if mask.anybits?(k.bit) }
    @frozen_tables&.each_shape_in(mask) { |s| found << @frozen_tables.name(s.bit) }
    found.empty? ? 'NONE' : found.join('|')
  end

  # One line per fact, sorted, for the bc2cpp.rb diagnostic (and the coverage
  # report, which counts them).
  def numeric_facts_report
    lines = []
    (@entry_arg_numeric || {}).each do |(label, k), mask|
      d = @owner_of[label]
      lines << "  NUMARG #{d ? "#{d.owner}##{d.name}" : "<irep #{label}>"} arg#{k} (#{numeric_mask_name(mask)})"
    end
    (@numeric_ivar_groups || {}).each_value do |g|
      lines << "  NUMIVAR #{g.family}#@#{g.name} (#{numeric_mask_name(g.mask)})" unless g.failed
    end
    (@numeric_return || {}).each { |name, mask| lines << "  NUMRET #{name} (#{numeric_mask_name(mask)})" }
    (@numeric_const_groups || {}).each_value do |g|
      lines << "  NUMCONST #{g.name} (#{numeric_mask_name(g.mask)})" unless g.failed
    end
    lines.concat(tuple_facts_report)
    lines.sort
  end

  # The Fixnum tier of every ADD/SUB/MUL-family arm (ADR 0279): the result is
  # stored as an immediate only when the C op did not overflow AND it is
  # FIXABLE (mrb_int is wider than a fixnum under word boxing, and a 32-bit
  # mrb_int leaves 31 bits), else mrb_num_* runs Integer#+ etc. and builds the
  # bigint. The operands must be immediates, hence the callers' mrb_fixnum_p.
  FIXNUM_TIER_OPS = { '+' => %w[mrb_int_add_overflow mrb_num_add], '-' => %w[mrb_int_sub_overflow mrb_num_sub],
                      '*' => %w[mrb_int_mul_overflow mrb_num_mul] }.freeze

  def fixnum_exact_tier(name, dest, rhs)
    overflow, helper = FIXNUM_TIER_OPS.fetch(name)
    register = rhs.start_with?('r')
    "{ mrb_int bc2cpp_z; " \
      "if (#{overflow}(mrb_fixnum(r#{dest}), #{register ? "mrb_fixnum(#{rhs})" : rhs}, &bc2cpp_z) || !FIXABLE(bc2cpp_z)) " \
      "{ r#{dest} = #{helper}(M, r#{dest}, #{register ? rhs : "mrb_fixnum_value(#{rhs})"}); } " \
      "else { r#{dest} = mrb_fixnum_value(bc2cpp_z); } }"
  end

  # The C++ that finishes an operator whose operands are both proven numeric, or
  # nil to keep the guarded send. +arg_reg+/+arg_expr+ as compile_operator_fallback.
  def numeric_operator_fallback(name, dest_reg, arg_reg, arg_expr, irep, idx, owner_def, reg_offset)
    return nil unless numeric_op_native?(name)

    left = numeric_operand_mask(irep, idx, unshift_proof_reg(dest_reg, reg_offset), owner_def)
    return nil unless left

    right = arg_reg ? numeric_operand_mask(irep, idx, unshift_proof_reg(arg_reg, reg_offset), owner_def) : NumericFlow::INT
    return nil unless right

    argument = arg_reg ? "r#{arg_reg}" : arg_expr
    call = case name
           when '+' then "mrb_num_add(M, r#{dest_reg}, #{argument})"
           when '-' then "mrb_num_sub(M, r#{dest_reg}, #{argument})"
           when '*' then "mrb_num_mul(M, r#{dest_reg}, #{argument})"
           when '/' then "bc2cpp_num_div(M, r#{dest_reg}, #{argument})"
           when '<', '<=', '>', '>=' then "mrb_bool_value(bc2cpp_num_cmp(M, r#{dest_reg}, #{argument}) #{name} 0)"
           end
    return nil unless call

    "#{format(NUMERIC_PROOF_NOTE, ":#{name}")}\n  r#{dest_reg} = #{call};\n"
  end
end
