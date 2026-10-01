# frozen_string_literal: true

require_relative 'numeric_flow'

# CodeGen: RETURN_CLASS_TABLE (ADR 0289).
#
# A second run of NumericFlow whose oracle knows nothing outside the method except the class pools
# of ADR 0295, so an exact class never rests on the numeric pools or a hint. Sources: literals, a provably fresh `Klass.new`
# (exact_new_class_at) and calls of names in the return table, admitted as NUMERIC_RETURN_PROOF admits
# them. Everything needs ClosedWorld#exact_instances_singleton_free? (ADR 0280).
class CodeGen
  RETURN_CALL_OPS = %w[SEND SEND0 SSEND SSEND0].freeze
  # Classes with bits of their own in NumericFlow: a `Klass.new` of one of them gets no class bit.
  RETURN_CORE_CLASS = { NumericFlow::ARR => 'Array', NumericFlow::HSH => 'Hash', NumericFlow::STR => 'String',
                        NumericFlow::RNG => 'Range' }.freeze
  RETURN_BITLESS_CLASSES = %w[Array Hash String Range Integer Float NilClass Symbol TrueClass FalseClass].freeze

  # NumericFlow's oracle for the exact-class run: constants, captured locals and literals pool
  # nothing; arguments and ivars know only what the class pools of ADR 0295 prove.
  class ExactOracle
    def initialize(codegen)
      @cg = codegen
    end

    def entry_mask(irep, reg) = @cg.class_pool_entry_mask(irep, reg)
    def const_mask(_insn) = NumericFlow::OTHER
    def ivar_entry_mask(irep, name) = @cg.class_pool_ivar_entry_mask(irep, name)
    def ivar_fact_mask(irep, name) = @cg.class_pool_ivar_fact_mask(irep, name)
    def upvar_mask(_irep, _insn) = NumericFlow::OTHER
    def pool_mask(_irep, _insn) = NumericFlow::OTHER
    def op_native?(_sym) = false
    def nil_raises?(_sym) = false

    def ivar_slots(irep)
      irep.instructions.filter_map { |insn| insn.ivar if %w[GETIV SETIV].include?(insn.op) }.uniq.sort
    end

    def send_mask(irep, index, insn, state)
      @cg.return_class_send_mask(irep, index, insn, state)
    end
  end

  # The bit standing for "exactly +klass+", allocated on first use.
  def numeric_class_bit(klass)
    @numeric_class_bits ||= {}
    @numeric_class_bits[klass] ||= begin
      bit = NumericFlow::CLASS_BIT_BASE + @numeric_class_bits.size
      raise 'numeric class bits reached the LCF object kinds (NumericFlow::OBJECT_KIND_BASE)' if bit >= NumericFlow::OBJECT_KIND_BASE

      1 << bit
    end
  end

  def return_class_name_of_bit(bit)
    @numeric_class_bits&.key(bit)
  end

  # Build the table. Runs once the facts `exact_new_class_at` reads (ClassLayout, class_return_names) are final.
  def compute_return_classes
    @native_results_ready = false
    @rc_states = {}
    @rc_return = {}
    @rc_send_ireps = Hash.new { |h, k| h[k] = Set.new }
    @rc_new_class = {}
    @rc_oracle = ExactOracle.new(self)
    return unless @foreign_method_names && @closed_world&.exact_instances_singleton_free?

    setup_class_pools
    numeric_return_candidates.each { |name| @rc_return[name] = 0 }
    @ireps.each_value do |irep|
      irep.instructions.each do |insn|
        @rc_send_ireps[insn.sym] << irep.label if RETURN_CALL_OPS.include?(insn.op) && @rc_return.key?(insn.sym)
      end
    end
    loop do
      changed = grow_return_classes
      changed |= grow_class_pools
      break unless changed
    end
    # The numeric flow and the Fixnum proof ask for a register's class set; mid-fixpoint that would
    # recurse into the flow still being built (NATIVE_RESULT_FACTS, ADR 0302).
    @native_results_ready = true
  end

  # One growth pass; true when a name's set grew or the name was dropped (it may return an unmodelled class).
  def grow_return_classes
    changed = false
    @rc_return.keys.each do |name|
      current = @rc_return[name]
      joined = 0
      @registry[name].each { |d| joined |= return_class_def_mask(d) }
      if (joined & NumericFlow::OTHER) != 0
        @rc_return.delete(name)
      elsif (joined | current) == current
        next
      else
        @rc_return[name] = current | joined
      end
      @rc_send_ireps[name].each { |label| return_class_invalidate(label) }
      changed = true
    end
    changed
  end

  def return_class_invalidate(label)
    stack = [label]
    until stack.empty?
      cur = stack.pop
      @rc_states.delete(cur)
      stack.concat(Array(@ireps[cur]&.reps))
    end
  end

  def return_class_states(irep)
    return @rc_states[irep.label] if @rc_states.key?(irep.label)

    @rc_states[irep.label] = NumericFlow.states(irep, @rc_oracle, fixnum_proof_ctx(irep)[:upvars])
  end

  # Class set one definition returns: its own return sites and the `return`s of blocks nested in it.
  def return_class_def_mask(d)
    return native_result_def_mask(d, classes: true) if d.owner == '<native>'
    return NumericFlow::OTHER unless d.irep

    irep = @ireps[d.irep]
    states = return_class_states(irep)
    return NumericFlow::OTHER unless states

    joined = return_class_block_returns(irep)
    return NumericFlow::OTHER if joined.nil?

    irep.instructions.each_with_index do |insn, idx|
      state = states[idx]
      next unless state

      joined |= case insn.op
                when 'RETURN', 'RETURN_BLK' then state[insn.reg.to_i] || NumericFlow::OTHER
                when 'RETNIL' then NumericFlow::NIL
                when 'RETSELF', 'RETTRUE', 'RETFALSE', 'BREAK', 'STOP' then NumericFlow::OTHER
                else 0
                end
    end
    joined
  end

  # The value a `return` inside a block nested in +irep+ hands back from the method (RETURN_BLK, at
  # any depth); nil when such a block is not modelled. A `break` is the result of the call that took
  # the block, which a SENDB never reads. A lambda's own RETURN_BLK is counted as well: only ever a
  # superset.
  def return_class_block_returns(irep, seen = Set.new)
    joined = 0
    (irep.reps || []).each do |label|
      next unless seen.add?(label)

      child = @ireps[label]
      next unless child

      if child.instructions.any? { |i| i.op == 'RETURN_BLK' }
        states = return_class_states(child)
        return nil unless states

        child.instructions.each_with_index do |insn, idx|
          joined |= states[idx][insn.reg.to_i] || NumericFlow::OTHER if insn.op == 'RETURN_BLK' && states[idx]
        end
      end
      nested = return_class_block_returns(child, seen)
      return nil if nested.nil?

      joined |= nested
    end
    joined
  end

  # Class set of a SEND-family result: a tracked name's set, or the class bit of a stable `Klass.new`.
  def return_class_send_mask(irep, index, insn, state = nil)
    name = insn.sym
    return NumericFlow::OTHER unless name

    tracked = @rc_return[name]
    return tracked if tracked

    native = state && %w[SEND SEND0].include?(insn.op) && native_result_flow_mask(name, state[insn.reg.to_i])
    return native if native
    return NumericFlow::OTHER unless name == 'new' && %w[SEND SEND0].include?(insn.op)

    key = [irep.label, index]
    @rc_new_class[key] = exact_new_class_at(irep, index + 1, insn.reg, numeric_owner_of(irep)) unless @rc_new_class.key?(key)
    klass = @rc_new_class[key]
    klass && !RETURN_BITLESS_CLASSES.include?(klass) ? numeric_class_bit(klass) : NumericFlow::OTHER
  end

  # The one class +mask+ names, or nil when it is empty, mixed (nil, another class) or unmodelled.
  def return_class_of_mask(mask)
    return nil unless mask.is_a?(Integer) && mask.positive?

    RETURN_CORE_CLASS[mask] || return_class_name_of_bit(mask)
  end

  # The exact class of register +reg+ as read by the instruction at +idx+, or nil.
  def exact_flow_class(irep, idx, reg)
    return nil unless @rc_states && irep && idx && reg && @closed_world&.exact_instances_singleton_free?

    r = reg.to_i
    return nil if r >= irep.nregs.to_i || fixnum_proof_ctx(irep)[:upvars].include?(reg.to_s)

    states = return_class_states(irep)
    state = states && states[idx]
    state && return_class_of_mask(exact_flow_strip_nil(irep, idx, r, state[r]))
  end

  # The raw class set of a register at an instruction (NIL included), nil when unproven.
  def exact_flow_mask(irep, idx, reg)
    return nil unless @rc_states && irep && idx && reg && @closed_world&.exact_instances_singleton_free?

    r = reg.to_i
    return nil if r >= irep.nregs.to_i || fixnum_proof_ctx(irep)[:upvars].include?(reg.to_s)

    states = return_class_states(irep)
    state = states && states[idx]
    state && state[r]
  end

  # Inside a NILABLE_RECEIVER non-nil arm the one receiver register the arm tested is not nil.
  def exact_flow_strip_nil(irep, idx, reg, mask)
    @nonnil_receiver == [irep.label, idx, reg] ? mask & ~NumericFlow::NIL : mask
  end

  def with_nonnil_receiver(key)
    previous = @nonnil_receiver
    @nonnil_receiver = key
    yield
  ensure
    @nonnil_receiver = previous
  end

  # 'Array' | 'Hash' | 'String' | 'Range' (a core class the ADR 0253/0257/0270 arms use), or nil.
  def exact_flow_core_class(irep, idx, reg)
    klass = exact_flow_class(irep, idx, reg)
    klass if RETURN_CORE_CLASS.value?(klass)
  end

  # A closed-world class (never a core class) for the `.new`-style direct call of compile_send.
  def exact_flow_user_class(irep, idx, reg)
    klass = exact_flow_class(irep, idx, reg)
    klass unless RETURN_CORE_CLASS.value?(klass)
  end

  # Names with an exact class: for the diagnostic and the coverage report.
  def return_class_report
    (@rc_return || {}).filter_map do |name, mask|
      klass = return_class_of_mask(mask)
      "  RETCLASS #{name} (#{klass})" if klass
    end.sort
  end
end
