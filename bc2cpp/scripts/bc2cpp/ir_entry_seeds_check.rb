#!/usr/bin/env ruby
# frozen_string_literal: true

require 'set'
require_relative '../../tools/bc2cpp/ir_entry_seeds'
require_relative '../../tools/bc2cpp/codegen_return_classes'
require_relative '../../tools/bc2cpp/codegen_entry_seeds'
require_relative '../../tools/bc2cpp/ir_call_graph_types'
require_relative '../../tools/bc2cpp/irep'

check = lambda do |label, condition|
  raise label unless condition

  puts "ok #{label}"
end

# -- which makers the native entries construct with their Array argument ----------------------------------------------
MAIN = 'src/main.cxx'
WIO = 'app/wio/src/maix_game_main.cxx'
main_text = <<~CXX
  const mrb_value args = mrb_ary_new_capa(M, argc - 1);
  game_obj = mrb_obj_new(M, mrb_class_get(M, "RPG2k"), 1, &em_args);
  game_obj = mrb_obj_new(M, mrb_class_get(M, "RPG2k"), 1, &args);
  game_obj = mrb_obj_new(M, mrb_class_get(M, "MZ"), 1, &em_args);
  game_obj = mrb_obj_new(M, mrb_class_get(M, "MZ"), 1, &args);
  em_args = args;
CXX
wio_text = <<~CXX
  mrb_value args = mrb_ary_new(g_mrb);
  g_game = mrb_obj_new(g_mrb, mrb_class_get(g_mrb, "RPG2k"), 1, &args);
CXX
texts = { MAIN => main_text, WIO => wio_text }
admitted = lambda do |native: { MAIN => Set['RPG2k', 'MZ'] }, ruby: {}, text: texts|
  IrEntrySeeds.admitted_makers(native, ruby, text)
end
check.call('the main entry admits the makers it constructs with its Array', admitted.call == Set['RPG2k', 'MZ'])
check.call('the wio entry admits the maker it constructs with its Array',
           admitted.call(native: { WIO => Set['RPG2k'] }) == Set['RPG2k'])
check.call('a maker spelled by both entries needs both to be constructions',
           admitted.call(native: { MAIN => Set['RPG2k', 'MZ'], WIO => Set['RPG2k'] }) == Set['RPG2k', 'MZ'])
check.call('a maker no native source spells is not admitted', admitted.call(native: {}).empty?)
check.call('a maker an entry spells without constructing is not admitted',
           admitted.call(native: { WIO => Set['MZ'] }, text: { WIO => wio_text }).empty?)
check.call('the entry Array must be the one main() declares and stores',
           admitted.call(text: { MAIN => main_text.sub('em_args = args;', '') }).empty?)
check.call('the wio Array must not be reassigned',
           admitted.call(native: { WIO => Set['RPG2k'] }, text: { WIO => "#{wio_text}args = nil;\n" }).empty?)
check.call('a spelled mention outside the construction calls refuses that maker',
           admitted.call(text: { MAIN => main_text + %(const char* name = "MZ";\n) }) == Set['RPG2k'])
check.call('a comment or a longer string that contains the name is inert',
           admitted.call(text: { MAIN => main_text + %(// RPG2k note\nconst char* log = "[RPG2k-MAP] RPG2k/XP";\n) }) ==
           Set['RPG2k', 'MZ'])
check.call('a bare identifier outside the construction calls refuses that maker',
           admitted.call(text: { MAIN => main_text + %(RPG2k::Foo();\n) }) == Set['MZ'])
check.call('a native spelling in a file that is not an entry refuses that maker',
           admitted.call(native: { MAIN => Set['RPG2k', 'MZ'], '/work/src/other.cxx' => Set['MZ'] }) == Set['RPG2k'])
check.call('an entry that was not scanned as text admits nothing',
           admitted.call(native: { MAIN => Set['RPG2k'] }, text: {}).empty?)
check.call('a foreign Ruby spelling refuses that maker',
           admitted.call(ruby: { '/work/tools/x.rb' => Set['RPG2k'] }) == Set['MZ'])
check.call('the entry is found by a relative NATIVE_SRCS path too',
           admitted.call(native: { WIO => Set['RPG2k'] }, text: { WIO => wio_text }) == Set['RPG2k'])
check.call('a file named like an entry but not that entry is not one',
           IrEntrySeeds.entry_key('/work/src/main_copy.cxx').nil? && IrEntrySeeds.entry_key('/work/src/xmain.cxx').nil? &&
           IrEntrySeeds.entry_key('/work/app/wio/src/maix_game_main.cxx') == WIO)
pattern = IrEntrySeeds.construction_pattern('RPG2k')
check.call('the construction pattern accepts both state variables and nothing else',
           pattern.match?('mrb_obj_new(M, mrb_class_get(M, "RPG2k"), 1, &args)') &&
           pattern.match?('mrb_obj_new(g_mrb, mrb_class_get(g_mrb, "RPG2k"), 1, &args)') &&
           !pattern.match?('mrb_obj_new(M, mrb_class_get(M, "RPG2k"), 2, &args)') &&
           !pattern.match?('mrb_obj_new(M, mrb_class_get(M, "RPG2kX"), 1, &args)'))
check.call('the seeded argument class is the Array the entry declares', IrEntrySeeds::CTOR_ARG_CLASSES == Set[:Array])

# -- CodeGen: the seed is an initialize, position 1, of an admitted maker, and nothing else ----------------------
EntryDefinition = Struct.new(:owner, :name, :irep)
class EntrySeedHarness < CodeGen
  attr_accessor :admitted

  def initialize
    @admitted = true
  end

  def entry_seed_ctor_admitted?(_definition) = @admitted
end
harness = EntrySeedHarness.new
maker_init = EntryDefinition.new('MZ', 'initialize', 'mz_init')
check.call('the admitted maker initialize position 1 is seeded with an Array',
           harness.bytecode_ir_entry_seed_classes(maker_init, 1) == Set[:Array])
check.call('position 2 is not seeded', harness.bytecode_ir_entry_seed_classes(maker_init, 2).nil?)
check.call('a method that is not initialize is not seeded',
           harness.bytecode_ir_entry_seed_classes(EntryDefinition.new('MZ', 'start', 'mz_start'), 1).nil?)
check.call('a definition without a body is not seeded',
           harness.bytecode_ir_entry_seed_classes(EntryDefinition.new('MZ', 'initialize', nil), 1).nil?)
harness.admitted = false
check.call('a refused maker is not seeded', harness.bytecode_ir_entry_seed_classes(maker_init, 1).nil?)
harness.admitted = true
ENV['BC2CPP_ENTRY_SEEDS'] = '0'
check.call('BC2CPP_ENTRY_SEEDS=0 turns the seeds off', harness.bytecode_ir_entry_seed_classes(maker_init, 1).nil?)
ENV.delete('BC2CPP_ENTRY_SEEDS')

# -- IrCallGraphTypes: a seeded entry is a complete fact that forwards through the call graph ----------------------
class EntryGraphHarness
  def initialize(dependencies, seeds)
    @dependencies, @seeds = dependencies, seeds
  end

  def pure_mandatory_arity?(_body) = true
  def mandatory_arity(_body) = 1
  def bytecode_ir_source_classes(*) = nil
  def bytecode_ir_call_result_classes(*) = nil

  def bytecode_ir_argument_classes(definition, _position, read: nil)
    dependency = @dependencies[definition.irep]
    read && dependency ? read.call(dependency, 1, 1) : nil
  end

  def bytecode_ir_entry_seed_classes(definition, position)
    @seeds[definition.irep] if position == 1
  end
end
bodies = %w[ctor forward].to_h do |label|
  [label, Irep.new(label: label, nlocals: 2, nregs: 2, instructions: [
    Insn.new(lineno: 1, addr: 0, op: :ENTER, args: '1:0:0:0:0:0:0:0 (0x0)'),
    Insn.new(lineno: 1, addr: 4, op: :RETURN, args: 'R1')
  ])]
end
definitions = [EntryDefinition.new('MZ', 'initialize', 'ctor'), EntryDefinition.new('Sink', 'forward', 'forward')]
graph = EntryGraphHarness.new({ 'forward' => bodies['ctor'] }, { 'ctor' => Set[:Array].freeze })
facts = IrCallGraphTypes.collect(graph, definitions, bodies)
check.call('an entry seed is a complete fact and forwards to the callee it feeds',
           facts.dig('ctor', 1) == Set[:Array] && facts.dig('forward', 1) == Set[:Array])
unseeded = IrCallGraphTypes.collect(EntryGraphHarness.new({ 'forward' => bodies['ctor'] }, {}), definitions, bodies)
check.call('without the seed the entry makes no fact', unseeded.dig('ctor', 1).nil? && unseeded.dig('forward', 1).nil?)

# -- the real compiler: a program of its own has no native entry, so a maker of that name is not seeded --------
if ENV['MRBC']
  require_relative 'type_check_fixture'
  Dir.mktmpdir('entry-seeds-fixture') do |dir|
    File.write(File.join(dir, 'fixture.rb'), <<~SOURCE)
      class RPG2k
        def initialize(args)
          EntrySeedSink.new.entry_seed_forward(args)
        end
      end
      class EntrySeedSink
        def entry_seed_forward(value)
          value
        end
      end
      class EntrySeedMain
        def entry_seed_run
          RPG2k.new([])
        end
      end
    SOURCE
    run = lambda do |enabled|
      TypeCheckFixture.report(dir, env: { 'BC2CPP_SIG_DIRS' => '', 'BC2CPP_ENTRY_SEEDS' => enabled ? '1' : '0' },
                                    label: 'entry seed fixture')
    end
    param = lambda do |facts, owner, name|
      facts['methods'].find { |method| method['owner'] == owner && method['name'] == name }['params'][0]
    end
    on = run.call(true)
    off = run.call(false)
    check.call('an unscanned native entry seeds no maker constructor',
               param.call(on, 'RPG2k', 'initialize')['source'] != 'inferred:call-graph')
    check.call('the switch changes nothing for a program without the native entry',
               param.call(on, 'EntrySeedSink', 'entry_seed_forward') == param.call(off, 'EntrySeedSink', 'entry_seed_forward'))
  end
else
  puts 'SKIP real compiler fixture (set MRBC)'
end
