# frozen_string_literal: true

require_relative 'fixpoint'
require_relative 'numeric_flow'
require_relative 'ir_argument_types'
require_relative 'ir_call_graph_types'
require_relative 'ir_native_expression_types'
require_relative 'readonly_call_effects'
require_relative 'call_context_arguments'
require_relative 'bytecode_ir_ops'
require_relative 'bytecode_ir_returns'

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

  # NumericFlow's oracle for the exact-class run: captured locals and literals pool nothing; arguments,
  # ivars and constants know only what the class pools of ADR 0296 and ADR 0301 prove.
  class ExactOracle
    def initialize(codegen)
      @cg = codegen
    end

    def entry_mask(irep, reg) = @cg.class_pool_entry_mask(irep, reg)
    def const_mask(insn) = @cg.class_pool_const_mask(insn)
    def ivar_entry_mask(irep, name) = @cg.class_pool_ivar_entry_mask(irep, name)
    def ivar_fact_mask(irep, name) = @cg.class_pool_ivar_fact_mask(irep, name)
    def upvar_mask(irep, insn) = @cg.class_upvar_mask(irep, insn)
    def index_mask(irep, index, insn, state) = @cg.exact_lcf_index_mask(irep, index, insn, state)
    # ELEMENT (generic step 2): the element class mask of a map/collect result, or nil (unknown).
    def block_element_mask(irep, index, insn, _state) = @cg.block_element_class_mask(irep, index, insn)
    def pool_mask(_irep, _insn) = NumericFlow::OTHER
    # The class bit of a true, false or Symbol literal (exactly TrueClass, FalseClass or Symbol: each has one instance
    # or is a Symbol, and its mrb_class is that class, see the mrb_class immediate cases in mruby's class.h).
    LITERAL_CLASSES = { 'LOADTRUE' => 'TrueClass', 'LOADFALSE' => 'FalseClass', 'LOADSYM' => 'Symbol' }.freeze
    def literal_class_mask(insn)
      klass = LITERAL_CLASSES[insn.op]
      return nil unless klass && @cg.immediate_class_bits_enabled?

      @cg.numeric_class_bit(klass)
    end
    def false_class_bit = @cg.numeric_false_class_bit
    def op_native?(_sym) = false
    def nil_raises?(_sym) = false

    def ivar_slots(irep)
      BytecodeIR.for(irep).instructions_with_op('GETIV', 'SETIV').filter_map(&:ivar).uniq.sort
    end

    def send_mask(irep, index, insn, state)
      @cg.return_class_send_mask(irep, index, insn, state)
    end

    def preserves_ivar_slots?(irep, _index, insn, state)
      @cg.readonly_class_call?(irep, insn, state)
    end

    def block_send_mask(irep, index, insn, state)
      @cg.block_return_class_result(irep, index, insn, state) || @cg.core_ruby_class_result(irep, index, insn, state) ||
        @cg.bottom_block_receiver_mask(insn, state) || NumericFlow::OTHER
    end

    def class_test(irep, index, insn, _state) = @cg.class_test_for(irep, index, insn)
    def noreturn_call?(irep, index, insn) = @cg.class_narrowing_noreturn_call?(irep, index, insn)
    def class_narrowing_active? = @cg.class_narrowing_enabled?
    def const_lookup_quiet? = @cg.const_missing_free?
    def class_eq_test(irep, index, insn, marker) = @cg.class_eq_test(irep, index, insn, marker)
    def note_class_test(irep, index, codes, slots, pred) = @cg.note_class_test(irep, index, codes, slots, pred)
  end

  # Receiver facts belong to this flow, not to the method's global pools.
  class ReceiverOracle < ExactOracle
    def initialize(codegen, receiver)
      super(codegen)
      @receiver = receiver
    end

    def send_mask(irep, index, insn, state)
      return super unless %w[SSEND SSEND0].include?(insn.op)

      # SSEND reads self, not the previous contents of its result register.
      explicit = insn.dup
      explicit.op = insn.op.delete_prefix('S')
      inputs = state.dup
      inputs[insn.reg.to_i] = @receiver
      @cg.return_class_send_mask(irep, index, explicit, inputs)
    end

    def preserves_ivar_slots?(irep, index, insn, state)
      return super unless %w[SSEND SSEND0].include?(insn.op)

      explicit = insn.dup
      explicit.op = insn.op.delete_prefix('S')
      inputs = state.dup
      inputs[insn.reg.to_i] = @receiver
      super(irep, index, explicit, inputs)
    end

    def self_mask = @receiver
    def loadself_mask = @receiver
  end

  # POOL_SELF_CLASS: the generic oracle plus the class set of `self` for LOADSELF only.
  class LoadSelfOracle < ExactOracle
    def initialize(codegen, receiver)
      super(codegen)
      @receiver = receiver
    end

    def loadself_mask = @receiver
  end

  class ContextOracle < ReceiverOracle
    attr_reader :context_enter_edges

    def initialize(codegen, receiver, binding)
      super(codegen, receiver)
      @arguments = binding.masks
      @context_enter_edges = binding.enter_edges
    end

    def entry_mask(_irep, reg) = @arguments.fetch(reg - 1, NumericFlow::OTHER)
  end

  class ContextBlockOracle < ExactOracle
    def initialize(codegen, contexts)
      super(codegen)
      @contexts = contexts
    end

    def upvar_mask(irep, insn)
      @cg.return_class_context_upvar_mask(irep, insn, @contexts)
    end
  end

  # The bit standing for "exactly +klass+", allocated on first use.
  def numeric_class_bit(klass)
    @numeric_class_bits ||= {}
    @numeric_class_bits[klass] ||= begin
      bit = NumericFlow::CLASS_BIT_BASE + @numeric_class_bits.size
      raise 'numeric class bits reached the CHECKED provenance bit (NumericFlow::CHECKED)' if bit >= NumericFlow::OBJECT_KIND_BASE - 1

      1 << bit
    end
  end

  def return_class_name_of_bit(bit)
    @numeric_class_bits&.key(bit)
  end

  # BC2CPP_IMMEDIATE_CLASS_BITS=0 turns off the TrueClass, FalseClass and Symbol bits of true, false and Symbol literals.
  def immediate_class_bits_enabled?
    ENV.fetch('BC2CPP_IMMEDIATE_CLASS_BITS', '1') != '0'
  end

  # FalseClass's bit, or 0 when disabled. Allocated on every call, not on the first LOADFALSE: a flow may narrow on
  # a falsy edge before the method that loads false is analysed, and every flow must narrow with the same bit.
  def numeric_false_class_bit
    immediate_class_bits_enabled? ? numeric_class_bit('FalseClass') : 0
  end

  # Build the table. Runs once the facts `exact_new_class_at` reads (ClassLayout, class_return_names) are final.
  def compute_return_classes
    @native_results_ready = false
    @rc_states = {}
    @rc_writes = {}
    @rc_return = {}
    @rc_send_ireps = Hash.new { |h, k| h[k] = Set.new }
    @rc_new_class = {}
    @rc_scoped_return_cache = {}
    @rc_scoped_return_active = Set.new
    @rc_scoped_ready = false
    @rc_oracle = ExactOracle.new(self)
    return unless @foreign_method_names && @closed_world&.exact_instances_singleton_free?

    setup_block_return_dependencies
    setup_class_pools
    numeric_return_candidates.each do |name|
      @rc_return[name] = 0
      @rc_send_ireps[name].merge(return_call_labels(name))
    end
    @rc_checked_alias_names = checked_alias_name_candidates
    @rc_admitted_alias_names = Set.new
    @rc_narrowing = true
    Fixpoint.iterate('CodeGen return classes and class pools', Fixpoint::GROWTH_LIMIT) do
      changed = grow_return_classes
      changed |= grow_class_pools
      changed |= admit_checked_alias_names
      changed
    end
    # Receiver-specific summaries read the settled name-wide and class-pool facts.
    @rc_scoped_ready = true
    @rc_scoped_states = {}
    @rc_scoped_writes = {}
    @rc_scoped_active_labels = Set.new
    # Every answer cut short by a query already on the stack (a recursive cycle) bumps this. A scoped answer that
    # saw no cut while it was computed is a function of the settled tables alone, so its negative is kept too.
    @rc_scoped_cuts = 0
    # The numeric flow and the Fixnum proof ask for a register's class set; mid-fixpoint that would
    # recurse into the flow still being built (NATIVE_RESULT_FACTS, ADR 0302).
    @native_results_ready = true
  end

  # SETTER_POOLS (ADR 0370): names the irep-wide alias rule withdraws although no aliasing operation spells them.
  def checked_alias_name_candidates
    return Set.new unless @checked_pools_used

    Set.new(numeric_return_candidates(alias_mode: :operands) - numeric_return_candidates)
  end

  # A name of checked_alias_name_candidates joins the table once every definition is an attr_reader whose pool
  # carries CHECKED, once (a name the table later drops stays dropped). True when one was admitted.
  def admit_checked_alias_names
    admitted = false
    @rc_checked_alias_names.each do |name|
      next if @rc_return.key?(name) || @rc_admitted_alias_names.include?(name) || !checked_accessor_name?(name)

      @rc_admitted_alias_names << name
      @rc_return[name] = 0
      @rc_send_ireps[name].merge(return_call_labels(name))
      @rc_send_ireps[name].each { |label| return_class_invalidate(label) }
      admitted = true
    end
    admitted
  end

  # Labels of the bodies with a RETURN_CALL_OPS send of +name+: the flows a change of its set invalidates.
  def return_call_labels(name)
    @rc_call_labels ||= @ireps.each_with_object(Hash.new { |h, k| h[k] = Set.new }) do |(label, irep), index|
      BytecodeIR.for(irep).each_with_op(*RETURN_CALL_OPS) { |insn, _| index[insn.sym] << label }
    end
    @rc_call_labels.fetch(name, Set.new)
  end

  # One growth pass; true when a name's set grew or the name was dropped (it may return an unmodelled class).
  def grow_return_classes
    changed = false
    @rc_return.keys.each do |name|
      current = @rc_return[name]
      joined = 0
      return_table_definitions(name).each { |d| joined |= return_class_def_mask(d) }
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
    seen = Set.new
    until stack.empty?
      cur = stack.pop
      next unless seen.add?(cur)

      @rc_states.delete(cur)
      @rc_writes.delete(cur)
      stack.concat(Array(@ireps[cur]&.reps))
      stack.concat(Array(@block_return_parents&.fetch(cur, nil)))
    end
  end

  def return_class_states(irep)
    return @rc_states[irep.label] if @rc_states.key?(irep.label)

    writes = {}
    @rc_writes[irep.label] = writes
    @rc_states[irep.label] = BytecodeIR::NumericClasses.states(irep, return_class_table_oracle(irep), fixnum_proof_ctx(irep)[:upvars], writes)
  end

  # POOL_SELF_CLASS: the oracle of the table-building and pool-growth flow. A method body whose `self` is a fixed class
  # set (return_class_self_receiver) reads LOADSELF as that set, so `Menu.new(self, state)` passes the class of the
  # method's own receiver into the argument pool. Everything else about the flow is the generic oracle's: the register 0
  # and every implicit-receiver call still answer OTHER, which keeps this a pure refinement of LOADSELF.
  def return_class_table_oracle(irep)
    receiver = pool_self_class_enabled? ? return_class_self_receiver(irep) : nil
    return @rc_oracle unless receiver

    @rc_load_self_oracles ||= {}
    @rc_load_self_oracles[receiver] ||= LoadSelfOracle.new(self, receiver)
  end

  # Sends that run a method body with a receiver other than the one it was found on. A body reached through an
  # UnboundMethod, or defined from a Method object, is not owned by one class any more.
  POOL_SELF_REBINDING_SENDS = %w[instance_method public_instance_method bind bind_call unbind define_method].freeze

  def pool_self_class_enabled?
    pool_self_class_refusal.nil?
  end

  # Why LOADSELF stays unknown in the table-building flow, or nil. BC2CPP_POOL_SELF_CLASS=0 turns it off; a program that
  # rebinds method bodies (POOL_SELF_REBINDING_SENDS, `define_method` with a block excepted: a block body is not a method
  # irep and keeps the generic oracle) withdraws it, and so does Ruby outside the closed world that spells one of them.
  def pool_self_class_refusal
    return @pool_self_class_refusal if defined?(@pool_self_class_refusal)

    @pool_self_class_refusal = compute_pool_self_class_refusal
  end

  def compute_pool_self_class_refusal
    return 'BC2CPP_POOL_SELF_CLASS=0' if ENV.fetch('BC2CPP_POOL_SELF_CLASS', '1') == '0'
    return 'no closed world' unless @closed_world

    POOL_SELF_REBINDING_SENDS.each do |name|
      return "outside Ruby spells #{name}" if @closed_world.outside_ruby_token?(name)
    end
    @ireps.each_value do |irep|
      BytecodeIR.for(irep).each_with_op(*POOL_SELF_SEND_OPS) do |insn, _|
        next unless POOL_SELF_REBINDING_SENDS.include?(insn.sym)
        next if insn.sym == 'define_method' && insn.op.end_with?('B')

        return "#{insn.sym} at #{irep.label}"
      end
    end
    nil
  end

  POOL_SELF_SEND_OPS = %w[SEND SEND0 SENDB SSEND SSEND0 SSENDB].freeze

  # On-demand counterpart to the table-building flow. It can use stable scoped
  # return facts without changing the global name summaries or class pools.
  def return_class_scoped_states(irep)
    return nil unless @rc_scoped_ready
    return @rc_scoped_states[irep.label] if @rc_scoped_states.key?(irep.label)
    if @rc_scoped_active_labels.include?(irep.label)
      @rc_scoped_cuts += 1
      return nil
    end

    writes = {}
    @rc_scoped_writes[irep.label] = writes
    @rc_scoped_active_labels << irep.label
    building = true
    @rc_scoped_states[irep.label] = BytecodeIR::NumericClasses.states(irep, return_class_method_oracle(irep), fixnum_proof_ctx(irep)[:upvars], writes)
  ensure
    @rc_scoped_active_labels&.delete(irep.label) if building
  end

  # Only a uniquely owned instance method frame has this lexical self fact.
  # A shared body, a module body or a nested closure may run with another self.
  def return_class_method_oracle(irep)
    return @rc_oracle if ENV['BC2CPP_CALL_CONTEXT_RESULTS'] == '0'

    receiver = return_class_self_receiver(irep)
    receiver ? ReceiverOracle.new(self, receiver) : @rc_oracle
  end

  # The class set `self` holds in the instance method whose body is +irep+ (the declared class and its descendants, or
  # the class alone when it has none), or nil when the body is shared, is not an instance method of a declared class,
  # or the hierarchy is not fully visible.
  def return_class_self_receiver(irep)
    definition = @owner_of[irep.label]
    owner = definition&.owner
    return nil unless definition && !definition.core && @closed_world.class_declared?(owner) &&
                      @closed_world.instance_class?(owner)

    @rc_body_owners ||= (@registry.values.flatten + Array(self.class.core_hidden_defs))
                       .flat_map { |d| [d.irep, d.copy_irep].compact.uniq.map { |label| [label, d.owner] } }
                       .group_by(&:first).transform_values { |entries| entries.to_set(&:last) }
    return nil unless @rc_body_owners[irep.label] == Set[owner]

    if @closed_world.exact_class?(owner)
      numeric_class_bit(owner)
    else
      return nil if ENV['BC2CPP_USER_RECEIVER_UNIONS'] == '0'

      hierarchy = @closed_world.class_hierarchy(owner)
      return nil unless hierarchy && hierarchy[:wild].empty?

      classes = [owner] + hierarchy[:descendants].to_a
      return nil unless classes.size <= 8 && classes.all? { |klass| @closed_world.class_declared?(klass) && @closed_world.instance_class?(klass) }

      classes.reduce(0) { |mask, klass| mask | numeric_class_bit(klass) }
    end
  end

  # Class set one definition returns: its own return sites and the `return`s of blocks nested in it.
  def return_class_def_mask(d, scoped: false)
    return native_result_def_mask(d, classes: true) if d.owner == '<native>'
    return return_class_accessor_mask(d) unless d.irep

    irep = @ireps[d.irep]
    states = scoped ? return_class_scoped_states(irep) : return_class_states(irep)
    return NumericFlow::OTHER unless states

    joined = return_class_block_returns(irep, scoped: scoped)
    return NumericFlow::OTHER if joined.nil?

    BytecodeIR::NumericClasses.returned_mask(irep, states, joined)
  end

  # The value a `return` inside a block nested in +irep+ hands back from the method (RETURN_BLK, at
  # any depth); nil when such a block is not modelled. A `break` is the result of the call that took
  # the block, which a SENDB never reads. A lambda's own RETURN_BLK is counted as well: only ever a
  # superset.
  def return_class_block_returns(irep, scoped: false)
    BytecodeIR.nested_bodies(irep).reduce(0) do |joined, child|
      next joined unless BytecodeIR::NumericClasses.block_returns?(child)

      states = scoped ? return_class_scoped_states(child) : return_class_states(child)
      return nil unless states

      joined | BytecodeIR::NumericClasses.block_return_mask(child, states)
    end
  end

  # Class set of a SEND-family result: a tracked name's set, the receiver's own set for `freeze`, a native
  # result fact, or the class bit of a stable `Klass.new`.
  def return_class_send_mask(irep, index, insn, state = nil)
    name = insn.sym
    return NumericFlow::OTHER unless name

    ruby_result = state && core_ruby_class_result(irep, index, insn, state)
    return ruby_result if ruby_result

    core_result = state && native_core_class_result(insn, state)
    return core_result if core_result

    if name == 'dup' && insn.op == 'SEND0' && state && native_dup_result_safe?
      mask = state[insn.reg.to_i]
      allowed = RETURN_CORE_CLASS.keys.reduce(NumericFlow::NIL, :|) | (@numeric_class_bits || {}).values.reduce(0, :|)
      return mask if mask.is_a?(Integer) && (mask & ~allowed).zero?
    end

    tracked = @rc_return[name]
    return tracked if tracked && return_class_of_mask(tracked)
    scoped = state && @rc_scoped_ready && return_class_scoped_send_mask(name, insn, state)
    return scoped if scoped
    return tracked if tracked
    return return_class_freeze_mask(insn, state) if state && name == 'freeze' && insn.op == 'SEND0'

    native = state && %w[SEND SEND0].include?(insn.op) && native_result_flow_mask(name, state[insn.reg.to_i])
    return native if native
    return NumericFlow::OTHER unless name == 'new' && %w[SEND SEND0].include?(insn.op)

    # Read the constructor input before its result joins another CFG path.
    if ENV['BC2CPP_USER_RECEIVER_UNIONS'] != '0'
      klass = constant_object_owner(irep, index, insn.reg, numeric_owner_of(irep)&.owner)
      if klass && !RETURN_BITLESS_CLASSES.include?(klass) && stable_standard_constructor_class?(klass)
        return numeric_class_bit(klass)
      end
    end

    key = [irep.label, index]
    @rc_new_class[key] = exact_new_class_at(irep, index + 1, insn.reg, numeric_owner_of(irep)) unless @rc_new_class.key?(key)
    klass = @rc_new_class[key]
    return numeric_class_bit(klass) if klass && !RETURN_BITLESS_CLASSES.include?(klass)

    # CORE_NEW_EXACT: `Array.new(n)`, `Hash.new(0)`, `String.new(s)` on the proven core class object is a fresh
    # instance of exactly that class (Class#new allocates from its receiver, whatever #initialize does), so it is
    # the class's own bit, as a literal is.
    core_bit = klass && RETURN_CORE_CLASS.key(klass)
    core_bit && core_new_exact?(klass) ? core_bit : NumericFlow::OTHER
  end

  # The construction of +klass+ (a core class with its own bit) is Class#new on exactly that class: the constant
  # cannot be rebound, and the lookup of `new` and `allocate` up its chain is the standard one
  # (stable_standard_constructor_class?, the proof GENERIC_OBJECT_CONSTRUCTION builds by).
  def core_new_exact?(klass)
    @core_new_exact ||= {}
    return @core_new_exact[klass] if @core_new_exact.key?(klass)

    @core_new_exact[klass] = stable_standard_constructor_class?(klass) ? true : false
  end

  # IR callers consume only complete, unguarded facts from the settled oracles (ADR 0443).
  def bytecode_ir_call_result_classes(irep, index)
    return nil unless @foreign_method_names && @closed_world&.exact_instances_singleton_free? && @native_results_ready && @rc_scoped_ready

    insn = irep.instructions[index]
    return nil unless BytecodeIR::Ops::SEND.include?(insn.op)

    state = return_class_states(irep)&.[](index)
    return nil unless state

    oracle = return_class_table_oracle(irep)
    mask = insn.op.end_with?('B') ? oracle.block_send_mask(irep, index, insn, state) : oracle.send_mask(irep, index, insn, state)
    if (!mask.is_a?(Integer) || mask.anybits?(NumericFlow::OTHER)) && %w[SEND SEND0].include?(insn.op)
      receiver = state[insn.reg.to_i]
      known = NUMERIC_SEND_OWNERS.keys.sum
      if receiver.is_a?(Integer) && receiver.positive? && (receiver & ~known).zero?
        argc = insn.op == 'SEND0' ? 0 : (insn.plain_fixed_argc? ? insn.argc : nil)
        mask = NUMERIC_SEND_OWNERS.keys.reduce(0) do |joined, bit|
          receiver.anybits?(bit) ? joined | numeric_send_on_class(bit, insn.sym, argc, insn, state) : joined
        end
      end
    end
    classes = bytecode_ir_mask_classes(mask)
    return classes if classes
    return nil unless %w[SEND SEND0].include?(insn.op) && (argc = insn.op == 'SEND0' ? 0 : insn.plain_fixed_argc? && insn.argc)

    receivers = bytecode_ir_mask_classes(state[insn.reg.to_i])
    return nil unless receivers

    results = receivers.map { |klass| bytecode_ir_native_expression_classes(insn.sym, klass.to_s, argc) }
    results.any?(&:nil?) ? nil : results.reduce(Set.new, :|).freeze
  end

  # Exhaustive entry admission is retained; only the single-definition rule
  # is replaced by stable receiver-specific lookup. These facts never seed codegen.
  def bytecode_ir_argument_classes(definition, position, read: nil)
    return nil if ENV['BC2CPP_IR_ARGUMENT_TYPES'] == '0'
    return nil unless @foreign_method_names && @outside_tokens && @closed_world&.exact_instances_singleton_free?
    return nil unless @native_results_ready && @rc_scoped_ready

    name = definition.name
    return nil if @foreign_method_names.include?(name) || @outside_tokens.include?(name)
    return nil unless name.match?(/\A[A-Za-z_]/) && name != 'initialize'
    return nil if numeric_dynamically_named?(name)

    irep = @ireps[definition.irep]
    return nil unless irep && pure_mandatory_arity?(irep)

    arity = mandatory_arity(irep)
    return nil unless position.between?(1, arity)

    sites, poisoned = entry_arg_call_index
    return nil if poisoned.include?(name) || sites[name].empty?

    IrArgumentTypes.classes(definition, position, sites[name], arity: arity,
                            receiver: ->(body, index, register) {
                              implicit = read && %w[SSEND SSEND0 SSENDB].include?(body.instructions[index].op)
                              read && !implicit ? read.call(body, index, register) : bytecode_ir_argument_receiver_classes(body, index, register)
                            },
                            argument: ->(body, index, register) { read ? read.call(body, index, register) : bytecode_ir_source_classes(body, index, register) },
                            target: ->(method, klass) { closed_world_exact_target(method, klass) })
  end

  def bytecode_ir_call_graph_argument_classes(definition, position)
    return nil if ENV['BC2CPP_IR_CALL_GRAPH_TYPES'] == '0' || ENV['BC2CPP_IR_ARGUMENT_TYPES'] == '0'
    return nil unless @native_results_ready && @rc_scoped_ready

    @ir_call_graph_arguments ||= IrCallGraphTypes.collect(self, @registry.values.flatten, @ireps)
    @ir_call_graph_arguments.dig(definition.irep, position.to_s)
  end

  def numeric_oracle_pool_mask(irep, insn)
    NumericOracle.new(self).pool_mask(irep, insn)
  end

  def bytecode_ir_context_results
    return nil if ENV['BC2CPP_IR_CONTEXT_RESULTS'] == '0'
    return nil unless @foreign_method_names && @closed_world&.exact_instances_singleton_free? && @native_results_ready && @rc_scoped_ready

    @ir_context_results ||= IrContextResults.new(self, @ireps,
                                               max_contexts: Integer(ENV.fetch('BC2CPP_IR_CONTEXT_MAX_CONTEXTS', IrContextResults::MAX_CONTEXTS.to_s)),
                                               max_rounds: Integer(ENV.fetch('BC2CPP_IR_CONTEXT_MAX_ROUNDS', IrContextResults::MAX_ROUNDS.to_s)))
  end

  def bytecode_ir_argument_receiver_classes(irep, index, register)
    if %w[SSEND SSEND0 SSENDB].include?(irep.instructions[index].op)
      bytecode_ir_mask_classes(return_class_self_receiver(irep))
    else
      bytecode_ir_source_classes(irep, index, register)
    end
  end

  # Read-point facts retain slot invalidation and incoming-argument proofs (ADR 0444).
  def bytecode_ir_source_classes(irep, index, reg)
    return nil unless @foreign_method_names && @closed_world&.exact_instances_singleton_free? && @native_results_ready && @rc_scoped_ready
    return nil unless reg.to_s.match?(/\A\d+\z/) && reg.to_i < irep.nregs

    bytecode_ir_mask_classes(return_class_states(irep)&.[](index)&.[](reg.to_i))
  end

  def bytecode_ir_mask_classes(mask)
    return nil unless mask.is_a?(Integer) && mask.positive?
    return nil if mask.anybits?(NumericFlow::OTHER | NumericFlow::EXC | NumericFlow::CHECKED)

    primitive = { NumericFlow::INT => :Integer, NumericFlow::FLT => :Float, NumericFlow::ARR => :Array,
                  NumericFlow::HSH => :Hash, NumericFlow::STR => :String, NumericFlow::NIL => :NilClass, NumericFlow::RNG => :Range }
    # LCF object kinds (LcfRowFlow) are exactly one class each, named by the row-flow model, so they are admitted
    # only while that model is on: a kind bit without it names nothing.
    kinds = mask & ~((1 << NumericFlow::OBJECT_KIND_BASE) - 1)
    allowed = primitive.keys.reduce(NumericFlow::CLASS_BITS, :|)
    return nil unless ((mask & ~kinds) & ~allowed).zero?

    classes = primitive.filter_map { |bit, klass| klass if mask.anybits?(bit) }.to_set
    remaining = mask & NumericFlow::CLASS_BITS
    until remaining.zero?
      bit = remaining & -remaining
      klass = return_class_name_of_bit(bit)
      return nil unless klass

      classes << klass.to_sym
      remaining &= ~bit
    end
    until kinds.zero?
      bit = kinds & -kinds
      kind = lcf_rows_model&.kind(bit)
      return nil unless kind

      classes << (kind.file_class || kind.owner).to_sym
      kinds &= ~bit
    end
    classes.freeze
  end

  # A name-wide summary can be ambiguous even when this exact receiver selects one
  # body. Analyze that body with the CFG-aware flow; the element tracer's linear
  # writer scan is only suitable for guarded hints.
  def return_class_scoped_send_mask(name, insn, state)
    return nil unless %w[SEND SEND0].include?(insn.op)

    receiver = state[insn.reg.to_i]
    receiver_class = return_class_of_mask(receiver)
    return return_class_union_send_mask(name, insn, state, receiver) unless receiver_class
    return nil unless receiver_class && !RETURN_CORE_CLASS.value?(receiver_class)

    argc = insn.op == 'SEND0' ? 0 : (insn.plain_fixed_argc? ? insn.argc : nil)
    arguments = argc && (1..argc).map { |arg| state[insn.reg.to_i + arg] || NumericFlow::OTHER }
    contextual = arguments && ENV['BC2CPP_CALL_CONTEXT_RESULTS'] != '0'
    key = [receiver_class, name, contextual ? arguments : nil]
    return @rc_scoped_return_cache[key] if @rc_scoped_return_cache.key?(key)
    if @rc_scoped_return_active.include?(key)
      @rc_scoped_cuts += 1
      return nil
    end

    definition = closed_world_exact_target(name, receiver_class, accessor: argc == 0)
    return return_class_scoped_accessor_mask(definition, key) if definition && definition.irep.nil?
    return nil unless definition&.irep
    if @rc_scoped_active_labels.include?(definition.irep)
      @rc_scoped_cuts += 1
      return nil
    end

    @rc_scoped_return_active << key
    acquired = true
    cuts = @rc_scoped_cuts
    mask = contextual && return_class_context_def_mask(definition, state[insn.reg.to_i], arguments)
    mask ||= return_class_scoped_def_mask(definition)
    unless mask.is_a?(Integer) && mask.positive? && (mask & NumericFlow::OTHER).zero?
      # SCOPED_NEGATIVE_MEMO: no cycle was cut while this was computed, so asking again gives the same nil.
      @rc_scoped_return_cache[key] = nil if @rc_scoped_cuts == cuts
      return nil
    end

    klass = return_class_of_mask(mask)
    valid = klass && (contextual || !RETURN_CORE_CLASS.value?(klass))
    result = valid ? mask : nil
    @rc_scoped_return_cache[key] = result
  ensure
    @rc_scoped_return_active.delete(key) if acquired
  end

  # BOTTOM_BLOCK_RECEIVER: the receiver of a literal-block send is a name the table has not given a class yet (its
  # mask is 0, the optimistic start of the growth loop, not a class nobody can name), so the send has no result yet
  # either; the loop re-runs it when the name grows. Answering OTHER there dropped `x.keys.select { }` and
  # `@slot = @slot.select { }` for good, since a dropped name never returns to the table.
  def bottom_block_receiver_mask(insn, state)
    return nil unless bottom_block_receivers_enabled? && insn.op == 'SENDB' && !@rc_scoped_ready

    state[insn.reg.to_i] == 0 ? 0 : nil
  end

  # BC2CPP_BOTTOM_BLOCK_RECEIVERS=0 turns the bottom receiver of a literal-block send back into an unknown result.
  def bottom_block_receivers_enabled?
    ENV.fetch('BC2CPP_BOTTOM_BLOCK_RECEIVERS', '1') != '0'
  end

  # SCOPED_ACCESSOR_RETURN: the exact class selects one attr_reader, so the send answers that slot's class set
  # (return_class_accessor_mask) even when the name has another, unmodelled definition elsewhere and so is not in
  # the name-wide table. The receiver is exactly this class (singleton-free), so only this class's reader runs.
  def return_class_scoped_accessor_mask(definition, key)
    return nil unless scoped_accessor_return_enabled?

    mask = return_class_accessor_mask(definition)
    result = mask.positive? && (mask & NumericFlow::OTHER).zero? ? mask : nil
    @rc_scoped_return_cache[key] = result
  end

  # BC2CPP_SCOPED_ACCESSOR_RETURNS=0 turns the exact-receiver accessor fact off.
  def scoped_accessor_return_enabled?
    ENV.fetch('BC2CPP_SCOPED_ACCESSOR_RETURNS', '1') != '0'
  end

  # Every possible exact user receiver must select a stable Ruby body and agree
  # on one result class; unknown, nil and core receiver bits cannot be dropped.
  def return_class_union_send_mask(name, insn, state, receiver)
    return nil if ENV['BC2CPP_USER_RECEIVER_UNIONS'] == '0'
    return nil unless receiver.is_a?(Integer) && receiver.positive?

    bits = (@numeric_class_bits || {}).values.select { |bit| receiver.anybits?(bit) }
    return nil unless (2..8).cover?(bits.size) && bits.reduce(0, :|) == receiver

    result = nil
    bits.each do |bit|
      inputs = state.dup
      inputs[insn.reg.to_i] = bit
      mask = return_class_scoped_send_mask(name, insn, inputs)
      return nil unless mask && return_class_of_mask(mask)
      return nil if result && result != mask

      result = mask
    end
    result
  end

  def exact_flow_user_union_plan(irep, index, reg, name, argc)
    return nil if ENV['BC2CPP_USER_RECEIVER_UNIONS'] == '0'

    receiver = exact_flow_mask(irep, index, reg)
    return nil unless receiver.is_a?(Integer) && receiver.positive?

    bits = (@numeric_class_bits || {}).values.select { |bit| receiver.anybits?(bit) }
    return nil unless (2..8).cover?(bits.size) && bits.reduce(0, :|) == receiver

    bits.map do |bit|
      klass = return_class_name_of_bit(bit)
      candidate = closed_world_exact_target(name, klass)
      return nil unless direct_callable?(candidate, argc)
      return nil if @only_owners && !@only_owners.include?(candidate.owner) && !@other_owners&.include?(candidate.owner)

      [klass, candidate]
    end
  end

  # The final arm is exhaustive because the flow contains only these class bits.
  def user_receiver_union_code(plan, name, dest, recv, argv)
    groups = plan.group_by(&:last).map { |target, entries| [target, entries.map(&:first)] }
    calls = groups.map do |target, classes|
      impl = cpp_name(target.owner, target.name) + '_impl'
      args, = direct_call_args(target, argv, impl)
      call = "r#{dest} = #{impl}(M, #{([recv] + args).join(', ')});"
      check = classes.map { |klass| "#{owner_class_ptr_expr(klass)} == bc2cpp_union_class" }.join(' || ')
      [check, call]
    end
    last = calls.pop.last
    branches = calls.map { |check, call| "if (#{check}) {\n    #{call}\n  } else " }.join
    "  // USER_RECEIVER_CASES :#{name}, exhaustive exact class set, direct C++ calls with no dynamic fallback\n" \
      "  {\n  struct RClass* bc2cpp_union_class = mrb_obj_class(M, #{recv});\n  #{branches}{\n    #{last}\n  }\n  }\n"
  end

  # Nested returns use independent block flows; caller masks belong only to the
  # method frame. Captured writes remain opaque (ADR 0353).
  def return_class_context_def_mask(definition, receiver, arguments)
    body = @ireps.fetch(definition.irep)
    binding = CallContextArguments.bind(body, arguments)
    return nil unless binding
    unless Array(body.reps).empty?
      return nil if ENV['BC2CPP_BLOCK_CONTEXT_RESULTS'] == '0'
      return nil unless captured_local_class_enabled?
    end

    oracle = ContextOracle.new(self, receiver, binding)
    writes = {}
    states = BytecodeIR::NumericClasses.states(body, oracle, fixnum_proof_ctx(body)[:upvars], writes)
    return nil unless states

    block_returns = return_class_context_block_returns(body, states, writes)
    return nil if block_returns.nil?

    BytecodeIR::NumericClasses.exit_mask(body, states, block_returns) do |exit, state|
      case exit.op
      when 'RETURN' then state[exit.reg] || NumericFlow::OTHER
      when 'RETSELF' then receiver
      when 'RETNIL' then NumericFlow::NIL
      else NumericFlow::OTHER
      end
    end
  end

  # Captures include every later store; aliases never gain the captured slot's fact.
  def return_class_context_upvar_mask(irep, insn, contexts)
    index, level = insn.upvar_ref
    return NumericFlow::OTHER unless index

    ancestor, creation = captured_local_frame(irep, level)
    return NumericFlow::OTHER unless ancestor && index < ancestor.nregs.to_i
    return NumericFlow::OTHER if fixnum_proof_ctx(ancestor)[:upvars].include?(index.to_s)

    frame = contexts[ancestor.label]
    state = frame && frame[:states]&.[](creation)
    return NumericFlow::OTHER unless state

    (state[index] || NumericFlow::OTHER) | (frame[:writes][index] || 0)
  end

  def return_class_context_block_returns(body, states, writes)
    contexts = { body.label => { states: states, writes: writes } }
    oracle = ContextBlockOracle.new(self, contexts)
    # Depth first, so a child's frame is in +contexts+ before its own children read their captures from it.
    BytecodeIR.nested_bodies(body).reduce(0) do |joined, child|
      child_writes = {}
      child_states = BytecodeIR::NumericClasses.states(child, oracle, fixnum_proof_ctx(child)[:upvars], child_writes)
      contexts[child.label] = { states: child_states, writes: child_writes }
      next joined unless BytecodeIR::NumericClasses.block_returns?(child)
      return nil unless child_states

      joined | BytecodeIR::NumericClasses.block_return_mask(child, child_states)
    end
  end

  def return_class_scoped_def_mask(definition)
    return NumericFlow::OTHER unless definition&.irep

    return_class_def_mask(definition, scoped: true)
  end

  # ADR 0335: initialize_copy's answer is discarded; only a fresh object's class survives.
  def native_dup_result_safe?
    return @native_dup_result_safe if defined?(@native_dup_result_safe)

    @native_dup_result_safe = audit_native_dup_result
  end

  def audit_native_dup_result
    return false if ENV['BC2CPP_NATIVE_COLLECTION_RESULTS'] == '0'
    return false unless @closed_world&.exact_instances_singleton_free? && @native_name_sources && ownerless_native_dispatch_safe?('dup')

    paths = @closed_world.native_paths_spelling('dup')
    allowed = %w[3rd/mruby/src/class.c 3rd/mruby/src/kernel.c]
    !paths.empty? && paths.all? do |path|
      relative = allowed.find { |suffix| path.end_with?("/#{suffix}") }
      relative && NativeClassResults.source_matches?(path, relative)
    end && allowed.all? { |relative| paths.any? { |path| path.end_with?("/#{relative}") } }
  end

  # `x.freeze` is x when the only `freeze` in the build is Kernel#freeze.
  def return_class_freeze_mask(insn, state)
    mask = kernel_freeze_only? && state[insn.reg.to_i]
    mask.is_a?(Integer) ? mask : NumericFlow::OTHER
  end

  KERNEL_FREEZE_BODY = /MRB_API mrb_value\s+mrb_obj_freeze\(mrb_state \*mrb, mrb_value self\)\s*\{.*?\n  return self;\n\}/m

  # No Ruby definition, alias or installer of `freeze` reaches an instance (Graphics.freeze is a singleton
  # method), and every native registration of it is kernel.c's mrb_obj_freeze, whose body answers its
  # receiver (checked against the source on every run).
  def kernel_freeze_only?
    return @kernel_freeze_only if defined?(@kernel_freeze_only)

    @kernel_freeze_only = kernel_freeze_audit
  end

  def kernel_freeze_audit
    world = block_core_world
    installed = symbol_installed_names
    return false unless world && @native_name_sources && world.instance_native_dispatch_safe?('freeze') && installed &&
                        !installed.include?('freeze') && !devirt_blocked_name?('freeze')

    paths = world.native_paths_spelling('freeze')
    registrations, opaque = NativeExpressionDevirt.class_registrations(paths)
    entries = registrations.fetch('freeze', [])
    kernel = paths.find { |path| File.basename(path) == 'kernel.c' }
    !entries.empty? && opaque.fetch('freeze', []).empty? && entries.all? { |entry| entry[:function] == 'mrb_obj_freeze' } &&
      !kernel.nil? && File.read(kernel).match?(KERNEL_FREEZE_BODY)
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

    # The one register CHECKED_POOL_EXACT is compiling under its class test (ADR 0370).
    return @checked_pool_override[:klass] if @checked_pool_override && @checked_pool_override[:key] == [irep.label, idx, r]

    states = return_class_scoped_states(irep)
    state = states && states[idx]
    state && return_class_of_mask(exact_flow_strip_nil(irep, idx, r, state[r]))
  end

  # The raw class set of a register at an instruction (NIL included), nil when unproven.
  def exact_flow_mask(irep, idx, reg)
    return nil unless @rc_states && irep && idx && reg && @closed_world&.exact_instances_singleton_free?

    r = reg.to_i
    return nil if r >= irep.nregs.to_i || fixnum_proof_ctx(irep)[:upvars].include?(reg.to_s)

    states = return_class_scoped_states(irep)
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

require_relative 'ir_context_results'
