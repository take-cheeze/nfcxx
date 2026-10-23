#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative 'type_check_fixture'
require_relative '../../tools/bc2cpp/ir_native_expression_types'

check = lambda do |message, condition|
  raise message unless condition

  puts "ok #{message}"
end
check.call('whole native bool constructor is typed', IrNativeExpressionTypes.classes('mrb_bool_value(mrb_test(recv))', 'Array') == [:TrueClass, :FalseClass])
check.call('ternary after a bool constructor is not a bool proof', IrNativeExpressionTypes.classes('mrb_bool_value(x) ? mrb_nil_value() : recv', 'Array').nil?)
check.call('opaque native expression remains unknown', IrNativeExpressionTypes.classes('custom(M, recv)', 'Array').nil?)
check.call('native receiver return retains its actual class', IrNativeExpressionTypes.classes('recv', 'Array') == [:Array])
check.call('native constructor parser handles parentheses in quotes', IrNativeExpressionTypes.classes('mrb_bool_value(strcmp("(", ")"))', 'Array') == [:TrueClass, :FalseClass])

require_relative '../../tools/bc2cpp/codegen_return_classes'
require_relative '../../tools/bc2cpp/irep'

# Instruction addresses equal indices, so branch targets name CFG nodes directly.
shape_body = lambda do |specs, handlers = []|
  Irep.new(label: "shape_#{specs.hash}", nlocals: 4, nregs: 12, reps: [], catch_handlers: handlers,
           instructions: specs.each_with_index.map do |(op, args), index|
             Insn.new(lineno: 1, addr: index, op: op, args: args)
           end)
end
shape_gen = Struct.new(:numeric_class_bit_count, :frozen_tables_model).new(0, nil)
shape_engine = IrContextResults.new(shape_gen, {})
allocation = ['ARRAY', "R4\t1"]
freeze_call = ['SEND0', "R4\t:freeze"]
check_shape_path = lambda do |message, specs, expected, handlers = []|
  body = shape_body.call(specs, handlers)
  target = specs.index(freeze_call)
  result = shape_engine.frozen_shape_preserved?(body, 0, target)
  check.call(message, result == expected)
  check.call("#{message} (cached)", shape_engine.frozen_shape_preserved?(body, 0, target) == expected)
end
check_shape_path.call('linear moves retain shapes', [allocation, ['MOVE', "R5\tR4"], freeze_call], true)
check_shape_path.call('branch joins preserve aliases', [allocation, ['JMPNOT', "R1\t4"], ['MOVE', "R5\tR4"],
                                                       ['JMP', '5'], ['MOVE', "R5\tR4"], freeze_call], true)
check_shape_path.call('pure backedges retain shapes', [allocation, ['JMPNOT', "R1\t5"], ['MOVE', "R5\tR4"],
                                                     ['LOADFALSE', 'R1'], ['JMP', '1'], freeze_call], true)
check_shape_path.call('unreachable mutations do not affect shapes', [allocation, ['JMP', '3'],
                                                                  ['ARYPUSH', "R4\tR1\t1"], freeze_call], true)
check_shape_path.call('allocation re-entry refuses shapes', [allocation, ['JMPIF', "R1\t0"], freeze_call], false)
check_shape_path.call('unresolved branch targets refuse shapes', [allocation, ['JMPIF', "R1\t99"], freeze_call], false)
check_shape_path.call('a mutation on an exiting branch still conservatively refuses shapes',
                     [allocation, ['JMPNOT', "R1\t4"], ['ARYPUSH', "R4\tR1\t1"], ['RETURN', 'R4'], freeze_call], false)
[
  ['ARYPUSH', "R5\tR1\t1"], ['HASHADD', "R5\t1"], ['SETIDX', 'R5'],
  ['SEND0', "R8\t:unknown"], ['SETIV', '@saved R5'], ['SETUPVAR', "R5\t1\t0"],
  ['BLOCK', "R8\tI(0)"], ['LAMBDA', "R8\tI(0)"], ['UNMODELLED', 'R5']
].each do |effect|
  check_shape_path.call("#{effect.first} through an alias or unrelated receiver refuses shapes",
                       [allocation, ['MOVE', "R5\tR4"], ['JMPNOT', "R1\t4"], effect, freeze_call], false)
end
handler = CatchHandler.new(type: :rescue, begin_addr: 0, end_addr: 2, target: 2)
check_shape_path.call('handler edges refuse shapes', [allocation, ['NOP', ''], freeze_call], false, [handler])
check_shape_path.call('shape CFG budget exhaustion refuses shapes',
                     [allocation] + Array.new(IrContextResults::MAX_SHAPE_PATH_STATES) { ['NOP', ''] } + [freeze_call], false)

# The middle node's return stabilizes before its state-dependent effect does.
context_harness = Class.new(IrContextResults) do
  attr_reader :evaluations

  def initialize(*args, **kwargs)
    super
    @evaluations = Hash.new(0)
    @leaf_evaluations = nil
  end

  def evaluate_body(node)
    @evaluations[node.body.label] += 1
    child = case node.body.label
            when 'root' then 'middle'
            when 'middle' then 'leaf'
            when 'leaf' then 'tail'
            when 'tail' then 'end'
            end
    callee = child && add(Struct.new(:label).new(child), 1, [], {}, nil)
    node.states = [[callee ? callee.mask : NumericFlow::STR]]
    node.calls = {}
    node.arrays = {}
    case node.body.label
    when 'root' then callee&.states&.dig(0, 0).to_i
    when 'middle' then NumericFlow::INT
    else NumericFlow::STR
    end
  end
end
run_context_harness = lambda do |reuse, rounds = 48, contexts = 512|
  gen = Struct.new(:numeric_class_bit_count, :frozen_tables_model).new(0, nil)
  engine = context_harness.new(gen, {}, max_rounds: rounds, max_contexts: contexts)
  engine.instance_variable_set(:@reuse_evaluations, reuse)
  root = engine.add(Struct.new(:label).new('root'), 1, [], {}, nil)
  solved = engine.solve
  nodes = engine.instance_variable_get(:@nodes).values
  [solved, root.mask, nodes.map { |node| [node.body.label, node.mask, node.states, node.calls] }, engine.evaluations, nodes]
end
indexed, unindexed = run_context_harness.call(true), run_context_harness.call(false)
check.call('dependency reuse preserves state-dependent effects with stable return masks', indexed.first(3) == unindexed.first(3) && indexed[1] == NumericFlow::STR)
check.call('unchanged context dependencies skip real evaluations', indexed[3].values.sum < unindexed[3].values.sum)
check.call('completed solves release dependency graphs', indexed[4].all? { |node| node.evaluation.nil? })
generation_gen = Struct.new(:numeric_class_bit_count, :frozen_tables_model).new(0, nil)
generation_engine = context_harness.new(generation_gen, {})
generation_engine.instance_variable_set(:@reuse_evaluations, true)
generation_node = generation_engine.add(Struct.new(:label).new('leaf'), 1, [], {}, nil)
2.times { generation_engine.evaluate(generation_node) }
check.call('unchanged generations reuse an evaluation', generation_engine.evaluations['leaf'] == 1)
generation_gen.numeric_class_bit_count += 1
generation_engine.evaluate(generation_node)
check.call('numeric class registration invalidates an evaluation', generation_engine.evaluations['leaf'] == 2)
generation_engine.shape_bit(IrContextResults::Shape.new(container: :Array, elements: [NumericFlow::STR].freeze))
generation_engine.evaluate(generation_node)
check.call('private shape registration invalidates an evaluation', generation_engine.evaluations['leaf'] == 3)
(1..5).each do |rounds|
  check.call("dependency reuse preserves #{rounds}-round graph outcomes", run_context_harness.call(true, rounds).first(3) == run_context_harness.call(false, rounds).first(3))
end
(1..3).each do |contexts|
  check.call("dependency reuse preserves #{contexts}-node graph outcomes", run_context_harness.call(true, 48, contexts).first(3) == run_context_harness.call(false, 48, contexts).first(3))
end

# Exercise state ownership independently of the compiler's inferred class registry.
frame_engine = IrContextResults.new(generation_gen, {})
frame_node = IrContextResults::Node.new(receiver: NumericFlow::STR)
frame_body = Object.new
frame_insn = Object.new
frame_engine.define_singleton_method(:call_layout) { |*_args| @test_layout }
[false, true].each do |implicit|
  [-1, 0, 1, 3].each do |argc|
    [[], [['x', 6], ['missing', 9]], [['x', 2], ['x', 6]]].each do |keyword_registers|
      frame_engine.instance_variable_set(:@test_layout, [implicit, 1, argc, keyword_registers])
      state = [NumericFlow::OTHER, NumericFlow::INT, 0, nil, NumericFlow::STR, nil, NumericFlow::FLT].freeze
      frame_engine.instance_variable_set(:@frame_allocations, false)
      baseline = frame_engine.frame(frame_node, frame_body, 0, frame_insn, state)
      frame_engine.instance_variable_set(:@frame_allocations, true)
      optimized = frame_engine.frame(frame_node, frame_body, 0, frame_insn, state)
      check.call("frame masks preserve self=#{implicit} argc=#{argc} keywords=#{keyword_registers.size}", optimized == baseline)
      changed = state.dup
      changed[2] = NumericFlow::ARR
      changed[6] = NumericFlow::HSH
      again = frame_engine.frame(frame_node, frame_body, 0, frame_insn, changed)
      check.call('later frame masks do not mutate earlier frames', optimized == baseline)
      check.call('nonempty argument frames have separate storage', argc <= 0 || !optimized[1].equal?(again[1]))
      check.call('nonempty keyword frames have separate storage', keyword_registers.empty? || !optimized[2].equal?(again[2]))
      check.call('shared empty argument frame is immutable', argc.positive? || optimized[1].frozen?)
      check.call('shared empty keyword frame is immutable', !keyword_registers.empty? || optimized[2].frozen?)
    end
  end
end
frame_engine.instance_variable_set(:@test_layout, nil)
check.call('unresolved call layout still refuses a frame', frame_engine.frame(frame_node, frame_body, 0, frame_insn, []).nil?)

binding_engine = IrContextResults.new(generation_gen, {})
binding_engine.define_singleton_method(:binding_layout) do |_body|
  [[2, 0, 0, 0, 0, 0, 1, 0], [], [], 0, true]
end
arguments = [NumericFlow::INT, NumericFlow::STR].freeze
binding = binding_engine.bind(nil, arguments, {})
check.call('fixed bindings retain argument masks and a nil block slot', binding.masks == [*arguments, NumericFlow::NIL])
check.call('fixed bindings own frozen masks', binding.masks.frozen? && !binding.masks.equal?(arguments))
check.call('fixed bindings have immutable empty entry edges', binding.enter_edges.empty? && binding.enter_edges.frozen?)
binding_engine.bind(nil, [NumericFlow::STR, NumericFlow::INT], {})
check.call('later fixed bindings preserve earlier masks', binding.masks == [*arguments, NumericFlow::NIL])
[false, true].each do |root|
  check.call("fixed bindings reject missing arguments (root=#{root})", binding_engine.bind(nil, [NumericFlow::INT], {}, root: root).nil?)
  check.call("fixed bindings reject excess arguments (root=#{root})", binding_engine.bind(nil, [*arguments, NumericFlow::INT], {}, root: root).nil?)
  check.call("fixed bindings reject keywords (root=#{root})", binding_engine.bind(nil, arguments, { 'x' => NumericFlow::INT }, root: root).nil?)
end

unless ENV['MRBC']
  puts 'SKIP mrbc context fixtures (set MRBC)'
  exit
end

Dir.mktmpdir('ir-context-results') do |dir|
  source = <<~RUBY
    class ContextCases
      def identity(value); value; end
      def peer(value); identity(value); end
      def optional(value = 1); value; end
      def required_kw(x:); x; end
      def optional_kw(x: :default); x; end
      def rest(*values); values; end
      def post(value = 1, *rest, last); last; end
      def kwrest(**values); values; end
      def recursive(n, value); n == 0 ? value : recursive(n - 1, value); end
      def mutual_a(n, value); n == 0 ? value : mutual_b(n - 1, value); end
      def mutual_b(n, value); mutual_a(n, value); end
      def never(value); never(value); end
      def array(value); [value].freeze; end
      def build_hash(value); { answer: value }.freeze; end
      def branch_array(value, flag)
        values = [value]
        if flag; selected = values; else; selected = values; end
        selected.freeze
      end
      def loop_array(value, flag)
        values = [value]
        while flag; selected = values; flag = false; end
        values.freeze
      end
      def branch_hash(value, flag)
        values = { answer: value }
        if flag; selected = values; else; selected = values; end
        selected.freeze
      end
      def changed_array(value, flag)
        values = [value]
        selected = values
        selected[0] = 1 if flag
        values.freeze
      end
      def pure_a(value); pure_b(value); end
      def pure_b(value); value; end
      def opaque_writer(value); @state = value; end
      def effect_read; @state = :held; pure_a(1); @state; end
      def effect_write; @state = :held; opaque_writer('changed'); @state; end
      def call_int; identity(1); end
      def call_symbol; identity(:tag); end
      def call_peer; peer('text'); end
      def call_default; optional; end
      def call_given; optional(:tag); end
      def call_kw; required_kw(x: 'value'); end
      def call_kw_default; optional_kw; end
      def call_kw_given; optional_kw(x: 3); end
      def call_rest; rest(1, :tag); end
      def call_post; post(1, :tag, 'last'); end
      def call_kwrest; kwrest(x: 1, y: :tag); end
      def call_recursive; recursive(3, 'value'); end
      def call_mutual; mutual_a(3, :tag); end
      def call_never; never(1); end
      def call_array; array('element')[0]; end
      def call_hash; build_hash(1)[:answer]; end
      def call_branch_array; branch_array('element', true)[0]; end
      def call_branch_array_int; branch_array(1, false)[0]; end
      def call_loop_array; loop_array('element', true)[0]; end
      def call_branch_hash; branch_hash(1, true)[:answer]; end
      def call_changed_array; changed_array('element', true)[0]; end
      def call_absent; array('element')[8]; end
      def call_native; [].empty?; end
      def call_dynamic(other); other.identity(1); end
      def literal_array; []; end
      def later_element(other); other[0]; end
    end
    class OtherContext
      def identity(value); value.unknown_result; end
    end
  RUBY
  File.write(File.join(dir, 'fixture.rb'), source)
  controls = [
    { 'BC2CPP_IR_FRAME_ALLOCATIONS' => '0' }, { 'BC2CPP_IR_FIXED_BINDINGS' => '0' },
    { 'BC2CPP_IR_CONTEXT_REEVALUATION' => '0' }, { 'BC2CPP_IR_LEAF_EVALUATIONS' => '0' },
    { 'BC2CPP_IR_BINDING_INDEX' => '0', 'BC2CPP_IR_CALL_INDEX' => '0', 'BC2CPP_CLASS_MEMBER_INDEX' => '0' }
  ]
  variants = controls + [{ 'BC2CPP_IR_CONTEXT_RESULTS' => '0' }]
  %w[BC2CPP_IR_CONTEXT_MAX_CONTEXTS BC2CPP_IR_CONTEXT_MAX_ROUNDS].each do |budget|
    base = { budget => '1' }
    variants += [base] + controls.map { |control| base.merge(control) }
  end
  variants += [{ 'BC2CPP_IR_EFFECT_SUMMARIES' => '0' }, { 'BC2CPP_IR_CONTEXT_SHAPES' => '0' }]
  reports = nil
  run = lambda do |extra_env|
    reports ||= TypeCheckFixture.shared_reports(dir, variants: variants,
      env: { 'BC2CPP_SIG_DIRS' => '', 'BC2CPP_STRICT_HINTS' => '0' }, label: 'context fixture')
    reports.fetch(extra_env)
  end
  report = TypeCheckFixture.report(dir, env: { 'BC2CPP_SIG_DIRS' => '', 'BC2CPP_STRICT_HINTS' => '0' }, label: 'context CLI fixture')
  check.call('frame allocation elision preserves the complete report', report == run.call('BC2CPP_IR_FRAME_ALLOCATIONS' => '0'))
  check.call('fixed bindings preserve the complete report', report == run.call('BC2CPP_IR_FIXED_BINDINGS' => '0'))
  check.call('dependency reuse preserves the complete report', report == run.call('BC2CPP_IR_CONTEXT_REEVALUATION' => '0'))
  check.call('leaf evaluation reuse preserves the complete report', report == run.call('BC2CPP_IR_LEAF_EVALUATIONS' => '0'))
  check.call('structural indexes preserve the complete report', report == run.call('BC2CPP_IR_BINDING_INDEX' => '0', 'BC2CPP_IR_CALL_INDEX' => '0', 'BC2CPP_CLASS_MEMBER_INDEX' => '0'))
  returns = report['ir_feedback'].select { |row| row['kind'] == 'return' }.to_h { |row| [[row['owner'], row['method']], row] }
  expected = { 'call_int' => ['Integer'], 'call_symbol' => ['Symbol'], 'call_peer' => ['String'],
               'call_post' => ['String'], 'call_default' => ['Integer'], 'call_given' => ['Symbol'], 'call_kw' => ['String'],
               'call_kw_default' => ['Symbol'], 'call_kw_given' => ['Integer'],
               'call_recursive' => ['String'], 'call_mutual' => ['Symbol'], 'call_array' => ['String'],
               'call_hash' => %w[Integer nil], 'call_branch_array' => ['String'], 'call_branch_array_int' => ['Integer'],
               'call_loop_array' => ['String'],
               'call_branch_hash' => %w[Integer nil], 'call_absent' => ['nil'], 'effect_read' => ['Symbol'], 'call_native' => ['bool'] }
  expected.each do |name, types|
    row = returns[['ContextCases', name]]
    check.call("independent #{name}: #{row.inspect}", row['status'] == 'inferred' && row['type'].split(' | ').sort == types.sort)
  end
  check.call('a recursive component with no return stays unknown', returns[['ContextCases', 'call_never']]['status'] == 'unknown')
  check.call('an unknown explicit receiver does not inherit lexical self target', returns[['ContextCases', 'call_dynamic']]['status'] == 'unknown')
  check.call('a mutable array parameter gains no frozen element shape', returns[['ContextCases', 'later_element']]['status'] == 'unknown')
  check.call('an alias mutation withdraws the original element shape', returns[['ContextCases', 'call_changed_array']]['status'] == 'unknown')
  check.call('an actual writer does not preserve the previous Symbol-only field', returns[['ContextCases', 'effect_write']]['type'] != 'Symbol')
  check.call('native inventory distinguishes audited bool forms', report['native_direct_forms'].any? { |row| row['type'] == 'bool' })

  without = run.call('BC2CPP_IR_CONTEXT_RESULTS' => '0')
  baseline = without['ir_feedback'].find { |row| row['owner'] == 'ContextCases' && row['method'] == 'call_kw' && row['kind'] == 'return' }
  check.call('context opt-out withdraws keyword result proof', baseline['status'] == 'unknown')
  limited_report = run.call('BC2CPP_IR_CONTEXT_MAX_CONTEXTS' => '1')
  check.call('frame allocation elision preserves context-budget refusals', limited_report == run.call('BC2CPP_IR_CONTEXT_MAX_CONTEXTS' => '1', 'BC2CPP_IR_FRAME_ALLOCATIONS' => '0'))
  check.call('leaf reuse preserves context-budget refusals', limited_report == run.call('BC2CPP_IR_CONTEXT_MAX_CONTEXTS' => '1', 'BC2CPP_IR_LEAF_EVALUATIONS' => '0'))
  check.call('structural indexes preserve context-budget refusals', limited_report == run.call('BC2CPP_IR_CONTEXT_MAX_CONTEXTS' => '1', 'BC2CPP_IR_BINDING_INDEX' => '0', 'BC2CPP_IR_CALL_INDEX' => '0', 'BC2CPP_CLASS_MEMBER_INDEX' => '0'))
  check.call('dependency reuse preserves context-budget refusals', limited_report == run.call('BC2CPP_IR_CONTEXT_MAX_CONTEXTS' => '1', 'BC2CPP_IR_CONTEXT_REEVALUATION' => '0'))
  limited = limited_report['ir_feedback'].find { |row| row['method'] == 'call_kw' && row['kind'] == 'return' }
  check.call('a context budget never publishes a provisional keyword summary', limited['status'] == 'unknown')
  check.call('fixed bindings preserve context-budget refusals', limited_report == run.call('BC2CPP_IR_CONTEXT_MAX_CONTEXTS' => '1', 'BC2CPP_IR_FIXED_BINDINGS' => '0'))
  rounds_report = run.call('BC2CPP_IR_CONTEXT_MAX_ROUNDS' => '1')
  check.call('frame allocation elision preserves round-budget refusals', rounds_report == run.call('BC2CPP_IR_CONTEXT_MAX_ROUNDS' => '1', 'BC2CPP_IR_FRAME_ALLOCATIONS' => '0'))
  check.call('fixed bindings preserve round-budget refusals', rounds_report == run.call('BC2CPP_IR_CONTEXT_MAX_ROUNDS' => '1', 'BC2CPP_IR_FIXED_BINDINGS' => '0'))
  check.call('leaf reuse preserves round-budget refusals', rounds_report == run.call('BC2CPP_IR_CONTEXT_MAX_ROUNDS' => '1', 'BC2CPP_IR_LEAF_EVALUATIONS' => '0'))
  check.call('structural indexes preserve round-budget refusals', rounds_report == run.call('BC2CPP_IR_CONTEXT_MAX_ROUNDS' => '1', 'BC2CPP_IR_BINDING_INDEX' => '0', 'BC2CPP_IR_CALL_INDEX' => '0', 'BC2CPP_CLASS_MEMBER_INDEX' => '0'))
  check.call('dependency reuse preserves round-budget refusals', rounds_report == run.call('BC2CPP_IR_CONTEXT_MAX_ROUNDS' => '1', 'BC2CPP_IR_CONTEXT_REEVALUATION' => '0'))
  rounds = rounds_report['ir_feedback'].find { |row| row['method'] == 'call_kw' && row['kind'] == 'return' }
  check.call('a round budget never publishes bottom as a return type', rounds['status'] == 'unknown')
  no_effect = run.call('BC2CPP_IR_EFFECT_SUMMARIES' => '0')['ir_feedback'].find { |row| row['method'] == 'effect_read' && row['kind'] == 'return' }
  check.call('effect opt-out withdraws preserved slot refinement', no_effect['type'] != 'Symbol')
  %w[call_array call_branch_array call_branch_array_int call_loop_array call_branch_hash].each do |method|
    no_shape = run.call('BC2CPP_IR_CONTEXT_SHAPES' => '0')['ir_feedback'].find { |row| row['method'] == method && row['kind'] == 'return' }
    check.call("shape opt-out withdraws parameter-built frozen elements for #{method}", no_shape['status'] == 'unknown')
  end
end
puts 'context result checks passed'
