#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'tmpdir'
require 'fileutils'
require_relative '../../tools/bc2cpp/type_check_run'
require_relative '../../tools/bc2cpp/type_check_report'
require_relative '../../tools/bc2cpp/bc2cpp'

# A cached refusal must be invalidated when its bit becomes a registered shape.
generator = Object.new
def generator.frozen_tables_model = nil
def generator.numeric_class_bit_count = @class_count.to_i
def generator.bytecode_ir_mask_classes(mask)
  @decodes = (@decodes || 0) + 1
  return Set[:Integer].freeze if mask == NumericFlow::INT
  return Set[:String].freeze if mask == @known_class_bit

  nil
end
context = IrContextResults.new(generator, {})
2.times { raise 'primitive decoding changed' unless context.classes(NumericFlow::INT) == Set[:Integer] }
raise 'repeated class decoding was not reused' unless generator.instance_variable_get(:@decodes) == 1
class_bit = 1 << NumericFlow::CLASS_BIT_BASE
raise 'unregistered numeric class was admitted' unless context.classes(class_bit).nil?
generator.instance_variable_set(:@known_class_bit, class_bit)
generator.instance_variable_set(:@class_count, 1)
raise 'new numeric class did not invalidate a cached refusal' unless context.classes(class_bit) == Set[:String]
array_bit = context.shape_bit(IrContextResults::Shape.new(container: :Array, elements: [NumericFlow::INT].freeze))
future_bit = array_bit << 1
raise 'unregistered shape was admitted' unless context.classes(future_bit).nil?
hash_bit = context.shape_bit(IrContextResults::Shape.new(container: :Hash, elements: [NumericFlow::INT].freeze))
raise 'new shape did not invalidate the cached refusal' unless hash_bit == future_bit && context.classes(hash_bit) == Set[:Hash]
raise 'shape union lost a member' unless context.classes(array_bit | hash_bit) == Set[:Array, :Hash]
raise 'unknown mask became exact' unless context.classes(array_bit | NumericFlow::OTHER).nil?
puts 'context class caching, shape registration and unknown-mask checks passed'

# Cached layouts must read current values and preserve duplicate keyword ordering.
frame_insn = lambda do |index, op, args|
  Insn.new(lineno: 1, addr: index, op: op, args: args, raw: "#{op} #{args}")
end
instructions = [frame_insn.call(0, 'LOADSYM', 'R3 :key'), frame_insn.call(1, 'LOADSYM', 'R5 :key'),
                frame_insn.call(2, 'SSEND', 'R1 :callee n=1|nk=2')]
body = Irep.new(label: 'frame', instructions: instructions, catch_handlers: [], nregs: 7, nlocals: 1)
frame_node = IrContextResults::Node.new(receiver: NumericFlow::INT)
state = [nil, NumericFlow::STR, NumericFlow::ARR, nil, NumericFlow::FLT, nil, NumericFlow::HSH]
first = context.frame(frame_node, body, 2, instructions.last, state)
raise 'implicit receiver or duplicate keyword order changed' unless first == [NumericFlow::INT, [NumericFlow::ARR], { 'key' => NumericFlow::HSH }]
layout = context.call_layout(body, 2, instructions.last)
raise 'call layout was rebuilt' unless context.call_layout(body, 2, instructions.last).equal?(layout)
raise 'call layout retained mutable metadata' unless layout.frozen? && layout.last.frozen? && layout.last.all? { |pair| pair.frozen? && pair.first.frozen? }
frame_node.receiver = NumericFlow::FLT
state[2] = NumericFlow::STR
state[6] = NumericFlow::NIL
second = context.frame(frame_node, body, 2, instructions.last, state)
raise 'cached layout retained old context values' unless second == [NumericFlow::FLT, [NumericFlow::STR], { 'key' => NumericFlow::NIL }]
raise 'frame argument/keyword containers were shared' if first[1].equal?(second[1]) || first[2].equal?(second[2])
explicit = frame_insn.call(0, 'SEND0', 'R1 :callee')
explicit_body = Irep.new(label: 'frame', instructions: [explicit], catch_handlers: [], nregs: 3, nlocals: 1)
raise 'explicit receiver or same-label body identity changed' unless context.frame(frame_node, explicit_body, 0, explicit, state) == [NumericFlow::STR, [], {}]
unknown = frame_insn.call(0, 'SSEND', 'R1 :callee n=1|nk=1')
unknown_body = Irep.new(label: 'unknown-key', instructions: [unknown], catch_handlers: [], nregs: 5, nlocals: 1)
2.times { raise 'entry keyword producer became a literal' if context.frame(frame_node, unknown_body, 0, unknown, state) }
splat = frame_insn.call(0, 'SSEND', 'R1 :callee n=1|nk=*')
splat_body = Irep.new(label: 'splat', instructions: [splat], catch_handlers: [], nregs: 5, nlocals: 1)
raise 'keyword splat acquired a fixed layout' if context.frame(frame_node, splat_body, 0, splat, state)
branch_instructions = [frame_insn.call(0, 'JMPIF', 'R0 3'), frame_insn.call(1, 'LOADSYM', 'R3 :key'),
                       frame_insn.call(2, 'JMP', '4'), frame_insn.call(3, 'LOADSYM', 'R3 :other'),
                       frame_insn.call(4, 'SSEND', 'R1 :callee n=1|nk=1')]
branch_body = Irep.new(label: 'joined-keys', instructions: branch_instructions, catch_handlers: [], nregs: 5, nlocals: 1)
2.times { raise 'joined keyword producers gained a fixed name' if context.frame(frame_node, branch_body, 4, branch_instructions.last, state) }
nonliteral_instructions = [frame_insn.call(0, 'LOADNIL', 'R3 (nil)'), frame_insn.call(1, 'SSEND', 'R1 :callee n=1|nk=1')]
nonliteral_body = Irep.new(label: 'nonliteral-key', instructions: nonliteral_instructions, catch_handlers: [], nregs: 5, nlocals: 1)
raise 'non-Symbol keyword producer gained a fixed name' if context.frame(frame_node, nonliteral_body, 1, nonliteral_instructions.last, state)
puts 'call layout isolation, dynamic values, duplicate keywords and refusal checks passed'

lookup_world_class = Struct.new(:closed_world, :registry, :superclass_of, :included, :prepended, :unknown_mixins, keyword_init: true)
lookup_cw = Object.new
def lookup_cw.method_missing_classes = Set.new
def lookup_cw.class_declared?(name) = %w[Child Base Pre Mix].include?(name)
def lookup_cw.outside_spells_class?(_name) = false
lookup_class = Class.new(CallFacts::Answers) do
  def definers(name, instance: false)
    return nil if name == 'unbounded'

    { native: name == 'native_first' ? Set['Pre'] : Set.new, foreign: Set.new }
  end
  def native_class_names = []
end
lookup_definition = Struct.new(:owner)
lookup_world = lookup_world_class.new(closed_world: lookup_cw,
  registry: { 'value' => [lookup_definition.new('Base'.dup), lookup_definition.new('<native>'), lookup_definition.new('Pre.singleton')],
              'native_first' => [lookup_definition.new('Base'.dup)] },
  superclass_of: { 'Child' => 'Base', 'Base' => :none },
  included: { 'Child' => ['Mix'] }, prepended: { 'Child' => ['Pre'] }, unknown_mixins: Set.new)
lookup_flag = ENV['BC2CPP_CALL_LOOKUP_INDEX']
begin
  ENV['BC2CPP_CALL_LOOKUP_INDEX'] = '1'
  indexed_lookup = lookup_class.new(lookup_world)
  ENV['BC2CPP_CALL_LOOKUP_INDEX'] = '0'
  plain_lookup = lookup_class.new(lookup_world)
ensure
  lookup_flag ? ENV['BC2CPP_CALL_LOOKUP_INDEX'] = lookup_flag : ENV.delete('BC2CPP_CALL_LOOKUP_INDEX')
end
path = indexed_lookup.send(:lookup_path, 'Child')
raise 'lookup prepend/include/superclass order changed' unless path.first(4) == %w[Pre Child Mix Base]
raise 'lookup path was rebuilt' unless indexed_lookup.send(:lookup_path, 'Child').equal?(path)
raise 'indexed lookup path is mutable' unless path.frozen? && path.all?(&:frozen?)
raise 'singleton/native owners entered the Ruby instance index' unless indexed_lookup.send(:ruby_owners, 'value') == Set['Base']
raise 'indexed owner set is mutable' unless indexed_lookup.send(:ruby_owners, 'value').frozen?
%w[value native_first absent unbounded].each do |name|
  2.times do
    raise "lookup index changed #{name}" unless indexed_lookup.resolves_in_ruby?('Child', name) == plain_lookup.resolves_in_ruby?('Child', name)
  end
end
raise 'native prepend was bypassed' if indexed_lookup.resolves_in_ruby?('Child', 'native_first')
raise 'ordinary inherited Ruby body was lost' unless indexed_lookup.resolves_in_ruby?('Child', 'value')
raise 'simple nested name changed' unless indexed_lookup.simple('Outer::Base') == 'Base'
raise 'simple nested name was rebuilt' unless indexed_lookup.simple('Outer::Base').equal?(indexed_lookup.simple('Outer::Base'))
raise 'simple name froze its input' if lookup_world.registry['value'].first.owner.frozen?
2.times { raise 'unknown superclass gained a partial path' if indexed_lookup.send(:lookup_path, 'Mystery') }
unknown_world = lookup_world.dup
unknown_world.unknown_mixins = Set['Mix']
unknown_lookup = lookup_class.new(unknown_world)
2.times { raise 'unknown mixin gained a partial path' if unknown_lookup.send(:lookup_path, 'Child') }
other_world = lookup_world.dup
other_world.superclass_of = { 'Child' => :none }
raise 'lookup index leaked between worlds' if lookup_class.new(other_world).send(:lookup_path, 'Child').include?('Base')
cycle_world = lookup_world.dup
cycle_world.superclass_of = { 'Child' => 'Base', 'Base' => 'Child' }
cycle_lookup = lookup_class.new(cycle_world)
raise 'cycle lookup changed traversal semantics' unless cycle_lookup.send(:lookup_path, 'Child') == cycle_lookup.send(:build_lookup_path, 'Child')
puts 'method lookup index order, shadowing, refusals and world isolation checks passed'

cache = IrContextLeafEvaluations.new
key = ['leaf', NumericFlow::INT, [], [], false].freeze
node = IrContextResults::Node.new(states: [[NumericFlow::INT], nil], calls: { 1 => NumericFlow::INT },
                                  arrays: { 0 => IrContextResults::Shape.new(container: :Array, elements: [NumericFlow::INT]) })
cache.remember(key, node, NumericFlow::INT, classes: 0, shapes: 0)
node.states[0][0] = NumericFlow::STR
node.arrays[0].elements[0] = NumericFlow::STR
snapshot = cache.fetch(key, classes: 0, shapes: 0)
raise 'leaf snapshot retained mutable graph states' unless snapshot.states == [[NumericFlow::INT], nil]
replayed = IrContextResults::Node.new
raise 'leaf result changed during replay' unless snapshot.restore(replayed) == NumericFlow::INT
raise 'leaf snapshot retained mutable literal elements' unless replayed.arrays[0].elements == [NumericFlow::INT] && replayed.arrays[0].elements.frozen?
raise 'replayed states are mutable' unless replayed.states.frozen? && replayed.states.first.frozen?
raise 'leaf cache crossed a numeric class generation' if cache.fetch(key, classes: 1, shapes: 0)
raise 'leaf cache crossed a private shape generation' if cache.fetch(key, classes: 0, shapes: 1)
large = IrContextResults::Node.new(states: [Array.new(IrContextLeafEvaluations::MAX_STATE_CELLS + 1, NumericFlow::INT)])
cache.remember(['large'], large, NumericFlow::INT, classes: 0, shapes: 0)
raise 'oversized leaf retained' if cache.fetch(['large'], classes: 0, shapes: 0)
puts 'leaf evaluation isolation, generation and size-bound checks passed'

signatures = RbsSignatures::Applied.new(
  ir_methods: Set[['Base', 'selfish'], ['Base', 'shadowed'], ['Pre', 'shadowed']],
  ir_named_returns: { ['Base', 'selfish'] => :self, ['Base', 'shadowed'] => Set[:String] },
  ir_ivar_types: { ['Base', 'items'] => Set[:Array], ['Child', 'items'] => Set[:Integer], ['Base', 'marker'] => Set[:Symbol] },
  ir_ivar_elements: { ['Base', 'items'] => Set[:String] }
)
hierarchy = { 'Child' => 'Base', 'Base' => :none }
world = { superclass_of: hierarchy, included_modules: { 'Child' => ['Mix'] },
          prepended_modules: { 'Child' => ['Pre'] }, unknown_mixins: Set.new }
contracts = RbsSignatures::IrContracts.new(signatures, **world)
raise 'prepared owner precedence changed' unless contracts.owners('Child') == RbsSignatures.contract_owners('Child', hierarchy, **world.reject { |key, _| key == :superclass_of })
raise 'prepared owner order was rebuilt' unless contracts.owners('Child').equal?(contracts.owners('Child'))
raise 'scalar ivar override was lost' unless contracts.ivars('Child')['items'] == Set[:Integer]
raise 'inherited element bound survived a scalar override' if contracts.elements('Child').key?('items')
raise 'unshadowed inherited ivar was lost' unless contracts.ivars('Child')['marker'] == Set[:Symbol]
raise 'lookup skipped an overriding method without a signature' unless contracts.target('Child', 'shadowed') == 'Pre'
raise 'receiver-relative self contract changed' unless contracts.named_returns[['Base', 'selfish']] == :self
raise 'prepared tables are mutable' unless contracts.named_returns.frozen? && contracts.ivars('Child').frozen? && contracts.ivars('Child')['items'].frozen?
blocked = RbsSignatures::IrContracts.new(signatures, **world.merge(unknown_mixins: Set['Mix']))
raise 'unknown mixin admitted partial contracts' unless blocked.owners('Child').empty? && blocked.ivars('Child').empty?
cyclic = RbsSignatures::IrContracts.new(signatures, **world.merge(superclass_of: { 'Child' => 'Base', 'Base' => 'Child' }))
raise 'cyclic hierarchy admitted contracts' unless cyclic.owners('Child').empty?
other = RbsSignatures::IrContracts.new(signatures, superclass_of: { 'Child' => 'Other' }, included_modules: {}, prepended_modules: {}, unknown_mixins: Set.new)
raise 'prepared contracts leaked between hierarchy worlds' if other.ivars('Child').key?('marker')
begin
  RbsSignatures.ir_types(RbsSignatures::Applied.new, nil, prepared: contracts)
  raise 'prepared contracts accepted another signature world'
rescue ArgumentError => error
  raise unless error.message == 'prepared IR contracts belong to another signature world'
end
puts 'prepared RBS precedence, shadowing, self-return and world isolation checks passed'

unless ENV['MRBC']
  puts 'SKIP type-check pipeline fixtures (set MRBC)'
  exit 0
end

root = File.expand_path('../..', __dir__)
Dir.mktmpdir('type-check-run') do |dir|
  source = File.join(dir, 'mruby-rpg2k/mrblib/fixture.rb')
  FileUtils.mkdir_p(File.dirname(source))
  File.write(source, <<~SOURCE)
    class TypeCheckPipeline
      def value; 1; end
      def receiver(value); value.unknown_pipeline_method; end
      def element(values); values[0]; end
    end
    class TypeRbsBase
      def initialize; @items = ['text']; end
      def items; @items; end
      def itself; self; end
    end
    class TypeRbsChild < TypeRbsBase
      def initialize; @items = 1; end
      def items; @items; end
      def inherited_self; itself; end
    end
  SOURCE
  sig = File.join(dir, 'sig')
  Dir.mkdir(sig)
  File.write(File.join(sig, 'fixture.rbs'), "class TypeCheckPipeline\n  def value: (Integer) -> String\nend\n")
  File.write(File.join(sig, 'inherited.rbs'), <<~RBS)
    class TypeRbsBase
      @items: Array[String]
      def items: () -> Array[String]
      def itself: () -> self
    end
    class TypeRbsChild < TypeRbsBase
      @items: Integer
      def items: () -> Integer
      def inherited_self: () -> self
    end
  RBS
  results = %w[0 1].map do |mode|
    work = File.join(dir, "mode-#{mode}")
    Dir.mkdir(work)
    result = TypeCheckRun.run(root: root, mrbc: File.expand_path(ENV.fetch('MRBC')), workdir: work,
                              sources: [source], sig_dirs: [sig], display_root: dir,
                              extra_env: { 'BC2CPP_TYPE_CHECK_ONLY' => mode, 'BC2CPP_IR_PREPARED_CONTRACTS' => mode, 'BC2CPP_CALL_LOOKUP_INDEX' => mode, 'BC2CPP_CLOSED_OPACITY_INDEX' => mode, 'BC2CPP_NUMERIC_LOAD_COPY_ELISION' => mode, 'BC2CPP_PROBE_REGISTER_FLOW' => mode })
    [JSON.parse(File.read(result.facts_path)), File.read(result.rows_path), work]
  end
  baseline, optimized = results
  raise 'report-only mode changed type facts' unless baseline[0] == optimized[0]
  self_row = optimized[0]['ir_feedback'].find { |row| row['owner'] == 'TypeRbsChild' && row['method'] == 'inherited_self' && row['kind'] == 'return' }
  raise 'inherited self return lost the child receiver' unless self_row && self_row['type'] == 'TypeRbsChild'
  raise 'report-only mode changed receiver rows' unless baseline[1] == optimized[1]
  raise 'fixture did not exercise receiver reporting' if baseline[1].strip.empty?
  raise 'fixture did not retain signature errors' if TypeCheckReport.exit_status(TypeCheckReport.diagnostics(optimized[0], [])).zero?
  raise 'nilable index collection was skipped' unless optimized[0].key?('nilable_index')
  raise 'baseline did not emit the C++ sidecar' unless File.exist?(File.join(baseline[2], 'type_check_decls.h'))
  raise 'report-only mode emitted a C++ sidecar' if File.exist?(File.join(optimized[2], 'type_check_decls.h'))
end
puts 'type-check pipeline facts, receiver rows, diagnostics and emission checks passed'
