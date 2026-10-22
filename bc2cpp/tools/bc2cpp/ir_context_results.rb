# frozen_string_literal: true

require_relative 'bytecode_ir_regions'
require_relative 'numeric_flow'
require_relative 'call_context_arguments'
require_relative 'ir_context_leaf_evaluations'

# Reporting contexts form a finite may-set graph. Bottom stays private until a whole fixpoint settles.
class IrContextResults
  MAX_CONTEXTS = 512
  MAX_ROUNDS = 48
  MAX_CLASSES = 16
  CLASS_CACHE_LIMIT = 2048
  EMPTY_FRAME_ARGUMENTS = [].freeze
  EMPTY_FRAME_KEYWORDS = {}.freeze
  PURE_OPS = Set['ENTER', 'NOP', 'MOVE', 'LOADSELF', 'LOADNIL', 'LOADTRUE', 'LOADFALSE', 'LOADSYM',
                 'GETIV', 'RETURN', 'RETSELF', 'RETNIL', 'RETTRUE', 'RETFALSE', 'JMP', 'JMPIF', 'JMPNOT', 'JMPNIL'].freeze
  Shape = Struct.new(:container, :elements, keyword_init: true)
  Node = Struct.new(:key, :revision, :evaluation, :has_callees, :arrays, :body, :receiver, :arguments, :keywords, :binding, :root, :mask, :states, :calls, keyword_init: true)

  class Oracle < CodeGen::ContextOracle
    attr_reader :calls

    def initialize(engine, node)
      @engine, @node = engine, node
      @calls = {}
      node.arrays = {}
      super(engine.gen, node.receiver, node.binding)
    end

    def entry_mask(irep, reg)
      return NumericFlow::NIL if BytecodeIR.for(irep).send(:enter_slot, irep.enter, reg.to_s) == :local

      super
    end

    def const_mask(insn)
      numeric = @engine.gen.numeric_const_mask(insn)
      @engine.frozen_mask?(numeric) ? numeric : super
    end
    def pool_mask(irep, insn) = @engine.gen.send(:numeric_oracle_pool_mask, irep, insn)
    def literal_class_mask(insn)
      name = { 'LOADTRUE' => 'TrueClass', 'LOADFALSE' => 'FalseClass', 'LOADSYM' => 'Symbol' }[insn.op]
      name && @engine.gen.numeric_class_bit(name)
    end
    def false_class_bit = @engine.gen.numeric_class_bit('FalseClass')
    def class_narrowing_active? = false
    def op_native?(name) = @engine.gen.numeric_op_native?(name)
    def keyword_mask(insn) = @node.keywords.fetch(insn.sym.to_s, NumericFlow::OTHER)
    def keyword_presence(insn)
      names = @node.root ? %w[TrueClass FalseClass] : [@node.keywords.key?(insn.sym.to_s) ? 'TrueClass' : 'FalseClass']
      names.reduce(0) { |mask, name| mask | @engine.gen.numeric_class_bit(name) }
    end
    def array_mask(irep, index, insn, state)
      source, count = insn.src_and_literal || [insn.reg.to_i, insn.uint_operand]
      count = count.to_i if count
      @node.arrays[index] = Shape.new(container: :Array, elements: state.slice(source.to_i, count)&.dup&.freeze) if count && count <= 32 && source.to_i + count <= irep.nregs.to_i
      NumericFlow::ARR
    end
    def hash_mask(irep, index, insn, state)
      count = insn.uint_operand
      @node.arrays[index] = Shape.new(container: :Hash, elements: (0...count).map { |i| state[insn.reg.to_i + i * 2 + 1] }.freeze) if count && count <= 32 && insn.reg.to_i + count * 2 <= irep.nregs.to_i
      NumericFlow::HSH
    end
    def index_mask(irep, index, insn, state) = @engine.index_mask(irep, index, insn, state)
    def aref_mask(irep, index, insn, _state) = @engine.gen.tuple_aref_mask(irep, index, insn)
    def send_mask(irep, index, insn, state)
      @calls[index] = @engine.dispatch(@node, irep, index, insn, state)
    end
    def block_send_mask(_irep, index, _insn, _state)
      @calls[index] = NumericFlow::OTHER
    end
    def noreturn_call?(_irep, index, _insn) = @calls[index] == 0
    def preserves_ivar_slots?(irep, index, insn, state)
      @engine.readonly?(@node, irep, index, insn, state)
    end
  end

  attr_reader :gen

  def initialize(gen, ireps, max_contexts: MAX_CONTEXTS, max_rounds: MAX_ROUNDS)
    @gen, @ireps = gen, ireps
    raise ArgumentError, 'IR context budgets must be positive and bounded' unless (1..MAX_CONTEXTS).cover?(max_contexts) && (1..MAX_ROUNDS).cover?(max_rounds)
    @max_contexts, @max_rounds = max_contexts, max_rounds
    @nodes = {}
    @roots = {}
    @completed = Set.new
    @refused = Set.new
    @failed = false
    @shapes = {}
    @shape_bits = {}
    @shape_mask = 0
    @call_layouts = {}.compare_by_identity unless ENV['BC2CPP_IR_CALL_INDEX'] == '0'
    @binding_layouts = {}.compare_by_identity
    @class_cache = {}
    @reuse_evaluations = ENV['BC2CPP_IR_CONTEXT_REEVALUATION'] != '0'
    @frame_allocations = ENV['BC2CPP_IR_FRAME_ALLOCATIONS'] != '0'
    @leaf_evaluations = IrContextLeafEvaluations.new unless ENV['BC2CPP_IR_LEAF_EVALUATIONS'] == '0'
    native_tables = @gen.frozen_tables_model&.mask.to_i
    native_rows = @gen.instance_variable_get(:@lcf_rows)&.mask.to_i
    @shape_base = [NumericFlow::OBJECT_KIND_BASE + 256, native_tables.bit_length, native_rows.bit_length].max + 1
  end

  def call_classes(body, index)
    return nil if ENV['BC2CPP_IR_CONTEXT_RESULTS'] == '0' || @refused.include?(body.label)

    return classes(@roots.fetch(body.label).calls&.[](index)) if @completed.include?(body.label)

    @nodes = {}
    @failed = false
    @roots.delete(body.label)
    node = root(body)
    unless node && solve
      @refused.delete(@refused.first) if @refused.size >= MAX_CONTEXTS
      @refused << body.label
      return nil
    end

    if @completed.size >= 64
      oldest = @completed.first
      @completed.delete(oldest)
      @roots.delete(oldest)
    end
    @completed << body.label
    classes(node.calls&.[](index))
  end

  def source_classes(body, index, register)
    call_classes(body, -1) unless @completed.include?(body.label)
    return nil unless @completed.include?(body.label)

    classes(@roots.fetch(body.label).states&.[](index)&.[](register.to_i))
  end

  # Registered bits are immutable; visit only the shapes present in this receiver.
  def each_shape_in(bits)
    return enum_for(__method__, bits) unless block_given?

    until bits.zero?
      bit = bits & -bits
      yield @shape_bits.fetch(bit)
      bits &= ~bit
    end
  end

  def classes(mask)
    return nil unless mask.is_a?(Integer) && mask.positive? && !mask.anybits?(NumericFlow::OTHER | NumericFlow::EXC | NumericFlow::CHECKED)

    # Numeric class bits can still be allocated lazily during report queries.
    generation = @gen.numeric_class_bit_count
    if @class_cache_generation != generation
      @class_cache.clear
      @class_cache_generation = generation
    end
    return @class_cache[mask] if @class_cache.key?(mask)

    result = classes_for_mask(mask)
    @class_cache[mask] = result if @class_cache.size < CLASS_CACHE_LIMIT
    result
  end

  def classes_for_mask(mask)
    registry = @gen.frozen_tables_model
    tables = registry ? registry.tables(mask) : 0
    private_bits = mask & @shape_mask
    plain = mask & ~(tables | private_bits)
    output = @gen.bytecode_ir_mask_classes(plain)
    return nil unless output || plain.zero?

    output = output ? output.dup : Set.new
    registry&.each_shape_in(tables) { |shape| output << (shape.array? ? :Array : :Hash) }
    each_shape_in(private_bits) { |shape| output << shape.container }
    output.empty? ? nil : output.freeze
  end

  def mask(classes)
    return NumericFlow::OTHER unless classes && !classes.empty? && classes.size <= MAX_CLASSES

    primitive = { Integer: NumericFlow::INT, Float: NumericFlow::FLT, Array: NumericFlow::ARR,
                  Hash: NumericFlow::HSH, String: NumericFlow::STR, NilClass: NumericFlow::NIL, Range: NumericFlow::RNG }
    classes.reduce(0) { |bits, name| bits | primitive.fetch(name) { @gen.numeric_class_bit(name.to_s) } }
  end

  def frozen_mask?(value)
    return false unless value.is_a?(Integer) && !value.anybits?(NumericFlow::OTHER | NumericFlow::EXC | NumericFlow::CHECKED)

    tables = @gen.frozen_tables_model&.tables(value) || 0
    tables.nonzero? && !classes(value).nil?
  end

  def root(body)
    return @roots[body.label] if @roots.key?(body.label)

    definition = @gen.numeric_owner_of(body)
    return nil unless definition && definition.irep == body.label
    receiver = @gen.send(:return_class_self_receiver, body) || NumericFlow::OTHER
    layout = binding_layout(body)
    return nil unless layout

    fields, names = layout
    required, optional = fields.first(2)
    arguments = (1..required + optional).map do |position|
      direct = definition && @gen.bytecode_ir_argument_classes(definition, position)
      direct ||= definition && @gen.bytecode_ir_call_graph_argument_classes(definition, position)
      numeric = @gen.numeric_entry_mask(body, position)
      frozen_mask?(numeric) ? numeric : mask(direct)
    end
    keywords = names.to_h { |name| [name, NumericFlow::OTHER] }
    binding = bind(body, arguments, keywords, root: true)
    @roots[body.label] = binding && add(body, receiver, arguments, keywords, binding, root: true)
  end

  def bind(body, arguments, keywords, root: false)
    layout = binding_layout(body)
    return nil unless layout

    fields, names, required_names, index = layout
    required, optional, rest, post, key_count, keydict = fields
    return nil if arguments.size < required + post || rest.zero? && arguments.size > required + optional + post
    return nil unless root || (required_names - keywords.keys).empty?
    return nil unless root || keydict.positive? || (keywords.keys - names).empty?
    return nil unless keywords.empty? || key_count.positive? || keydict.positive?

    supplied = [arguments.size - required - post, optional].min
    values = arguments.take(required) + arguments.slice(required, supplied) + Array.new(optional - supplied, NumericFlow::OTHER)
    values << NumericFlow::ARR if rest.positive?
    values.concat(arguments.last(post)) if post.positive?
    values << NumericFlow::HSH if key_count.positive? || keydict.positive?
    values << NumericFlow::NIL
    edges = {}
    edges[index] = [index + supplied + 1] if optional.positive? && !root
    CallContextArguments::Binding.new(masks: values.freeze, enter_edges: edges.freeze)
  end

  # Bytecode is fixed for this engine; context values and budgets are not.
  def binding_layout(body)
    return build_binding_layout(body) if ENV['BC2CPP_IR_BINDING_INDEX'] == '0'
    return @binding_layouts[body] if @binding_layouts.key?(body)

    @binding_layouts[body] = build_binding_layout(body)
  end

  def build_binding_layout(body)
    fields = body.enter&.enter_fields
    return nil unless fields&.size == 8 && fields.all? { |value| value.is_a?(Integer) && value >= 0 }

    _required, optional, rest, _post, _key_count, keydict, block, extra = fields
    return nil if extra != 0 || rest > 1 || keydict > 1 || block > 1

    index = body.instructions.index(body.enter)
    return nil unless index
    if optional.positive?
      jumps = body.instructions[index + 1, optional + 1]
      return nil unless jumps&.size == optional + 1 && jumps.all? { |insn| insn.op == 'JMP' }
    end
    names = BytecodeIR.for(body).instructions_with_op('KARG').map { |insn| insn.sym.to_s.dup.freeze }.uniq.freeze
    optional_names = BytecodeIR.for(body).instructions_with_op('KEY_P').map { |insn| insn.sym.to_s }.uniq
    [fields.dup.freeze, names, (names - optional_names).freeze, index].freeze
  end

  def add(body, receiver, arguments, keywords, binding, root: false)
    # Even an existing node is a dependency: its states may change in a later round.
    @evaluating.has_callees = true if @evaluating
    key = [body.label, receiver, arguments, keywords.sort, root]
    if @nodes.key?(key)
      dependency = @nodes[key]
      @dependencies[dependency] = dependency.revision if @dependencies
      return dependency
    end
    if @nodes.size >= @max_contexts
      @failed = true
      return nil
    end
    @changed = true
    key[2] = arguments.dup.freeze
    key[3].each(&:freeze)
    key[3].freeze
    key.freeze
    node = @nodes[key] = Node.new(key: key, revision: 0, body: body, receiver: receiver, arguments: key[2],
                                 keywords: keywords.dup.freeze, binding: binding, root: root, mask: 0)
    @dependencies[node] = node.revision if @dependencies
    node
  end

  def solve
    return false if @failed

    @max_rounds.times do
      @changed = false
      @nodes.values.each do |node|
        value = evaluate(node)
        joined = node.mask | value
        if joined != node.mask
          node.mask = joined
          node.revision += 1 if @reuse_evaluations
          @changed = true
        end
      end
      return false if @failed
      return true unless @changed
    end
    false
  ensure
    # Completed roots retain flow results, never another root's dependency graph.
    @nodes.each_value { |node| node.evaluation = nil }
  end

  def evaluate(node)
    return evaluate_uncached(node) unless @reuse_evaluations

    classes, shapes = @gen.numeric_class_bit_count, @shapes.size
    previous = node.evaluation
    if previous && previous[1] == classes && previous[2] == shapes &&
       previous[3].all? { |dependency, revision| dependency.revision == revision }
      return previous[0]
    end

    old_states, old_calls, old_arrays = node.states, node.calls, node.arrays
    @dependencies = {}.compare_by_identity
    value = evaluate_uncached(node)
    # Effects read callee states, not just return masks; both invalidate readers (ADR 0527).
    node.revision += 1 if old_states != node.states || old_calls != node.calls || old_arrays != node.arrays
    node.evaluation = [value, classes, shapes, @dependencies] unless @failed
    value
  ensure
    @dependencies = nil
  end

  def evaluate_uncached(node)
    return evaluate_body(node) unless @leaf_evaluations

    classes, shapes = @gen.numeric_class_bit_count, @shapes.size
    snapshot = @leaf_evaluations.fetch(node.key, classes: classes, shapes: shapes)
    return snapshot.restore(node) if snapshot

    @evaluating = node
    node.has_callees = false
    value = evaluate_body(node)
    if !node.has_callees && !@failed && classes == @gen.numeric_class_bit_count && shapes == @shapes.size
      @leaf_evaluations.remember(node.key, node, value, classes: classes, shapes: shapes)
    end
    value
  ensure
    @evaluating = nil
  end

  def evaluate_body(node)
    body = node.body
    program = BytecodeIR.for(body)
    unless Array(body.reps).empty? && program.resolved? && !program.handlers?
      node.states = nil
      node.calls = {}
      return NumericFlow::OTHER
    end
    oracle = Oracle.new(self, node)
    node.states = BytecodeIR::NumericClasses.states(body, oracle, @gen.send(:fixnum_proof_ctx, body)[:upvars])
    node.calls = oracle.calls
    return NumericFlow::OTHER unless node.states

    BytecodeIR::NumericClasses.exit_mask(body, node.states) do |exit, state|
      case exit.op
      when 'RETURN' then state[exit.reg]
      when 'RETSELF' then node.receiver
      when 'RETNIL' then NumericFlow::NIL
      when 'RETTRUE' then @gen.numeric_class_bit('TrueClass')
      when 'RETFALSE' then @gen.numeric_class_bit('FalseClass')
      else NumericFlow::OTHER
      end
    end
  end

  def frame(node, body, index, insn, state)
    layout = call_layout(body, index, insn)
    return nil unless layout

    implicit, register, argc, keyword_registers = layout
    receiver = implicit ? node.receiver : state[register]
    arguments = if !@frame_allocations
                  (1..argc).map { |position| state[register + position] || NumericFlow::OTHER }
                elsif argc <= 0
                  EMPTY_FRAME_ARGUMENTS
                else
                  Array.new(argc) { |position| state[register + position + 1] || NumericFlow::OTHER }
                end
    # Only empty containers are shared; inferred masks remain local to this frame.
    keywords = @frame_allocations && keyword_registers.empty? ? EMPTY_FRAME_KEYWORDS : {}
    keyword_registers.each { |name, value_register| keywords[name] = state[value_register] || NumericFlow::OTHER }
    [receiver, arguments, keywords]
  end

  def call_layout(body, index, insn)
    return build_call_layout(body, index, insn) unless @call_layouts

    layouts = (@call_layouts[body] ||= {})
    return layouts[index] if layouts.key?(index)

    layouts[index] = build_call_layout(body, index, insn)
  end

  # Keyword names depend only on reaching bytecode definitions, never on context masks.
  def build_call_layout(body, index, insn)
    return nil unless %w[SEND SEND0 SSEND SSEND0].include?(insn.op)

    argc = insn.op.end_with?('0') ? 0 : insn.argc
    return nil unless argc && insn.nk_spec != '*'

    register = insn.reg.to_i
    keyword_registers = []
    insn.nk_spec.to_i.times do |position|
      key_register = register + argc + 1 + position * 2
      definitions = BytecodeIR.reaching_definitions(body, index, key_register.to_s, origin_transfers: true)
      return nil unless definitions&.size == 1 && !definitions.first.entry?

      producer = body.instructions[definitions.first.index]
      return nil unless producer.op == 'LOADSYM'

      keyword_registers << [producer.sym.to_s.dup.freeze, key_register + 1].freeze
    end
    [%w[SSEND SSEND0].include?(insn.op), register, argc, keyword_registers.freeze].freeze
  end

  def dispatch(node, body, index, insn, state)
    input = frame(node, body, index, insn, state)
    return NumericFlow::OTHER unless input

    receiver, arguments, keywords = input
    return 0 if receiver == 0 || arguments.any?(&:zero?) || keywords.values.any?(&:zero?)

    receivers = classes(receiver)
    unless receivers && receivers.size <= MAX_CLASSES
      direct = @gen.bytecode_ir_call_result_classes(body, index)
      return direct ? mask(direct) : NumericFlow::OTHER
    end

    if keywords.empty? && arguments.empty? && insn.sym == 'freeze'
      frozen = frozen_shape(node, body, index, insn, receivers)
      return frozen if frozen

      site = @gen.frozen_table_freeze_site(body, index)
      return site if site && site.positive? && receivers.all? { |klass| @gen.send(:frozen_table_name_safe?, 'freeze', klass.to_s) }
    end
    receivers.reduce(0) do |joined, klass|
      definition = @gen.send(:closed_world_exact_target, insn.sym, klass.to_s)
      result = if definition&.irep
                 callee = @ireps.fetch(definition.irep)
                 binding = bind(callee, arguments, keywords)
                 context = binding && add(callee, mask(Set[klass]), arguments, keywords, binding)
                 context ? context.mask : NumericFlow::OTHER
               elsif keywords.empty?
                 native(node, body, index, insn, state, klass, receiver, arguments.size)
               else NumericFlow::OTHER
               end
      joined | result
    end
  end

  def native(_node, body, index, insn, state, klass, receiver, argc)
    private_bits = receiver & @shape_mask
    if private_bits.nonzero? && (receiver & ~private_bits).zero? && argc.zero?
      if insn.sym == 'freeze'
        return receiver if @gen.send(:frozen_table_name_safe?, 'freeze', klass.to_s)
      end
    end
    expression = @gen.bytecode_ir_native_expression_classes(insn.sym, klass.to_s, argc)
    return receiver if expression == Set[klass] && Array(@gen.instance_variable_get(:@native_registered_expressions)&.[](insn.sym)).any? { |entry|
      entry[:owner][:class_name] == klass.to_s && entry[:arity] == argc && entry[:expression] == 'recv'
    }
    return mask(expression) if expression

    tables = @gen.frozen_tables_model&.tables(receiver) || 0
    if tables.nonzero?
      other = receiver & ~tables
      return @gen.frozen_table_send_mask(tables, insn.sym, argc) if other.zero?
    end
    explicit = insn.dup
    explicit.op = insn.op.end_with?('0') ? 'SEND0' : 'SEND'
    inputs = state.dup
    inputs[insn.reg.to_i] = mask(Set[klass])
    result = @gen.send(:return_class_send_mask, body, index, explicit, inputs) || NumericFlow::OTHER
    if result.anybits?(NumericFlow::OTHER) && CodeGen::NUMERIC_SEND_OWNERS.key?(inputs[insn.reg.to_i])
      result = @gen.send(:numeric_send_on_class, inputs[insn.reg.to_i], insn.sym, argc, explicit, inputs)
    end
    result
  end

  def frozen_shape(node, body, index, insn, receivers)
    return nil if ENV['BC2CPP_IR_CONTEXT_SHAPES'] == '0'
    return nil unless receivers.size == 1 && [:Array, :Hash].include?(receivers.first) &&
                      @gen.send(:frozen_table_name_safe?, 'freeze', receivers.first.to_s)

    definitions = BytecodeIR.reaching_definitions(body, index, insn.reg, origin_transfers: true)
    return nil unless definitions&.size == 1 && !definitions.first.entry?

    origin = definitions.first.index
    shape = node.arrays[origin]
    return nil unless shape && shape.container == receivers.first && shape.elements && shape.elements.all? { |mask| mask.is_a?(Integer) && !mask.anybits?(NumericFlow::OTHER | NumericFlow::EXC | NumericFlow::CHECKED) }
    corridor = body.instructions[origin + 1...index]
    return nil unless corridor.all? { |op| %w[MOVE NOP LOADNIL LOADSYM LOADTRUE LOADFALSE].include?(op.op) || op.op.start_with?('LOADI') } &&
                      BytecodeIR.for(body).linear_corridor?(origin, index)

    shape_bit(shape)
  end

  def shape_bit(shape)
    key = [shape.container, shape.elements]
    return @shapes[key] if @shapes.key?(key)
    return nil if @shapes.size >= 8192

    bit = 1 << (@shape_base + @shapes.size)
    @shapes[key] = bit
    @shape_bits[bit] = shape.freeze
    @shape_mask |= bit
    # A previously unknown mask may now name this newly registered shape.
    @class_cache.clear
    bit
  end

  def index_mask(body, index, insn, state)
    register = insn.op == 'GETIDX0' ? insn.regs[1].to_i : insn.reg.to_i
    receiver = state[register]
    private_bits = receiver & @shape_mask
    rest = receiver & ~private_bits
    plain = state.dup
    plain[register] = rest
    result = rest.zero? ? 0 : @gen.element_index_mask(body, index, insn, plain)
    each_shape_in(private_bits) do |shape|
      return NumericFlow::OTHER unless @gen.send(:frozen_table_name_safe?, '[]', shape.container.to_s)

      if shape.container == :Hash
        result |= shape.elements.reduce(NumericFlow::NIL, :|)
      else
        key = insn.op == 'GETIDX0' ? 0 : @gen.send(:frozen_table_literal_key, body, index, register + 1)
        integer = insn.op == 'GETIDX0' || state[register + 1] == NumericFlow::INT
        return NumericFlow::OTHER unless integer

        result |= if key.is_a?(Integer)
                    shape.elements[key] || NumericFlow::NIL
                  else shape.elements.reduce(NumericFlow::NIL, :|)
                  end
      end
    end
    result
  end

  # A transitive effect proof checks the entire reachable call graph, including recursive backedges.
  def readonly?(node, body, index, insn, state, seen = Set.new)
    return false if ENV['BC2CPP_IR_EFFECT_SUMMARIES'] == '0' || seen.size >= MAX_CONTEXTS

    input = frame(node, body, index, insn, state)
    return false unless input

    receiver, arguments, keywords = input
    return false unless keywords.empty? && (receivers = classes(receiver))

    receivers.all? do |klass|
      definition = @gen.send(:closed_world_exact_target, insn.sym, klass.to_s)
      callee = definition&.irep && @ireps[definition.irep]
      next false unless callee && Array(callee.reps).empty? && !BytecodeIR.for(callee).handlers?
      fields = callee.enter&.enter_fields
      next false unless fields && fields.values_at(2, 4, 5, 6, 7).all?(&:zero?)

      binding = bind(callee, arguments, {})
      context = binding && add(callee, mask(Set[klass]), arguments, {}, binding)
      next false unless context
      key = [callee.label, context.receiver, arguments]
      next true if seen.include?(key)
      next false unless context.states

      nested = seen.dup.add(key)
      callee.instructions.each_with_index.all? do |instruction, call_index|
        if %w[SEND SEND0 SSEND SSEND0].include?(instruction.op)
          inputs = context.states[call_index]
          inputs.nil? || readonly?(context, callee, call_index, instruction, inputs, nested)
        else
          PURE_OPS.include?(instruction.op) || instruction.op.match?(/\ALOADI(?:8|16|32|NEG|__1|_[0-7])\z/)
        end
      end
    end
  end
end
