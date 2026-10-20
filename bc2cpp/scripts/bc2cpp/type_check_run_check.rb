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
  SOURCE
  sig = File.join(dir, 'sig')
  Dir.mkdir(sig)
  File.write(File.join(sig, 'fixture.rbs'), "class TypeCheckPipeline\n  def value: (Integer) -> String\nend\n")
  results = %w[0 1].map do |mode|
    work = File.join(dir, "mode-#{mode}")
    Dir.mkdir(work)
    result = TypeCheckRun.run(root: root, mrbc: File.expand_path(ENV.fetch('MRBC')), workdir: work,
                              sources: [source], sig_dirs: [sig], display_root: dir,
                              extra_env: { 'BC2CPP_TYPE_CHECK_ONLY' => mode })
    [JSON.parse(File.read(result.facts_path)), File.read(result.rows_path), work]
  end
  baseline, optimized = results
  raise 'report-only mode changed type facts' unless baseline[0] == optimized[0]
  raise 'report-only mode changed receiver rows' unless baseline[1] == optimized[1]
  raise 'fixture did not exercise receiver reporting' if baseline[1].strip.empty?
  raise 'fixture did not retain signature errors' if TypeCheckReport.exit_status(TypeCheckReport.diagnostics(optimized[0], [])).zero?
  raise 'nilable index collection was skipped' unless optimized[0].key?('nilable_index')
  raise 'baseline did not emit the C++ sidecar' unless File.exist?(File.join(baseline[2], 'type_check_decls.h'))
  raise 'report-only mode emitted a C++ sidecar' if File.exist?(File.join(optimized[2], 'type_check_decls.h'))
end
puts 'type-check pipeline facts, receiver rows, diagnostics and emission checks passed'
