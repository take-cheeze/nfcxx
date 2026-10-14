#!/usr/bin/env ruby
# frozen_string_literal: true

require 'set'
require_relative '../../tools/bc2cpp/ir_argument_types'

Definition = Struct.new(:name, :irep)
left = Definition.new('accept', 'left')
right = Definition.new('accept', 'right')
sites = [[:a, 0, 2, 1], [:b, 0, 2, 1], [:c, 0, 2, 1]]
receivers = { a: Set[:Left], b: Set[:Right], c: Set[:Left] }
arguments = { a: Set[:Integer], b: Set[:String], c: Set[:Float] }
targets = { 'Left' => left, 'Right' => right }
run = lambda do |entries = sites|
  IrArgumentTypes.classes(left, 1, entries, arity: 1,
                          receiver: ->(body, _index, _reg) { receivers[body] },
                          argument: ->(body, _index, _reg) { arguments[body] },
                          target: ->(_name, klass) { targets[klass] })
end
check = lambda do |label, condition|
  raise label unless condition

  puts "ok #{label}"
end
check.call('partition unrelated receiver and join same-body arguments', run.call == Set[:Integer, :Float])
receivers[:b] = nil
check.call('unknown unrelated receiver invalidates completeness', run.call.nil?)
receivers[:b] = Set[:Right]
arguments[:c] = nil
check.call('one unknown reaching argument invalidates union', run.call.nil?)
arguments[:c] = Set[:Float]
receivers[:b] = Set[:Right, :Left]
check.call('receiver union contributes if any target reaches body', run.call == Set[:Integer, :Float, :String])
targets.delete('Right')
check.call('unresolved union member refuses exclusion', run.call.nil?)
targets['Right'] = right
receivers[:b] = Set[:Right]
check.call('incorrect reaching arity refuses', run.call([[:a, 0, 2, 2]]).nil?)
check.call('no reaching sites gives no fact', run.call([sites[1]]).nil?)
check.call('returned class union is immutable', run.call.frozen?)

require_relative '../../tools/bc2cpp/codegen_return_classes'
World = Struct.new(:safe) do
  def exact_instances_singleton_free? = safe
end
Body = Struct.new(:label)
class ArgumentHarness < CodeGen
  attr_accessor :outside, :foreign, :poisoned, :dynamic, :world

  def initialize(definitions, sites, classes)
    @foreign_method_names = @foreign = Set.new
    @outside_tokens = @outside = Set.new
    @poisoned = Set.new
    @closed_world = @world = World.new(true)
    @native_results_ready = @rc_scoped_ready = true
    @ireps = definitions.values.to_h { |definition| [definition.irep, Body.new(definition.irep)] }
    @definitions, @sites, @classes = definitions, sites, classes
  end

  def pure_mandatory_arity?(_irep) = true
  def mandatory_arity(_irep) = 1
  def numeric_dynamically_named?(_name) = @dynamic
  def entry_arg_call_index = [{ 'accept' => @sites }, @poisoned]
  def bytecode_ir_source_classes(body, _index, register) = @classes[[body, register]]
  def bytecode_ir_argument_receiver_classes(body, index, register) = bytecode_ir_source_classes(body, index, register)
  def closed_world_exact_target(_name, klass) = @definitions[klass]
end
harness = ArgumentHarness.new({ 'Left' => left, 'Right' => right }, sites,
                              { [:a, 2] => Set[:Left], [:b, 2] => Set[:Right], [:c, 2] => Set[:Left],
                                [:a, 3] => Set[:Integer], [:b, 3] => Set[:String], [:c, 3] => Set[:Float] })
check.call('CodeGen API produces receiver-partitioned union', harness.bytecode_ir_argument_classes(left, 1) == Set[:Integer, :Float])
harness.foreign << 'accept'
check.call('foreign caller withdraws API fact', harness.bytecode_ir_argument_classes(left, 1).nil?)
harness.foreign.clear
harness.outside << 'accept'
check.call('outside caller withdraws API fact', harness.bytecode_ir_argument_classes(left, 1).nil?)
harness.outside.clear
harness.poisoned << 'accept'
check.call('reflective/non-call mention withdraws API fact', harness.bytecode_ir_argument_classes(left, 1).nil?)
harness.poisoned.clear
harness.dynamic = true
check.call('computed method name withdraws API fact', harness.bytecode_ir_argument_classes(left, 1).nil?)
harness.dynamic = false
harness.world.safe = false
check.call('singleton mutation withdraws API fact', harness.bytecode_ir_argument_classes(left, 1).nil?)

Instruction = Struct.new(:op)
ReceiverBody = Struct.new(:instructions)
class ReceiverHarness < CodeGen
  attr_accessor :self_mask
  def bytecode_ir_source_classes(_body, _index, _register) = Set[:String]
  def return_class_self_receiver(_body) = @self_mask
  def bytecode_ir_mask_classes(mask) = mask
end
receiver_harness = ReceiverHarness.new
receiver_harness.self_mask = Set[:Left]
implicit_body = ReceiverBody.new([Instruction.new('SSEND')])
check.call('implicit call uses lexical self rather than polluted output register',
           receiver_harness.bytecode_ir_argument_receiver_classes(implicit_body, 0, 2) == Set[:Left])
receiver_harness.self_mask = nil
check.call('unknown implicit self refuses despite known output register',
           receiver_harness.bytecode_ir_argument_receiver_classes(implicit_body, 0, 2).nil?)

require_relative '../../tools/bc2cpp/irep'
GraphDefinition = Struct.new(:owner, :name, :irep)
class GraphHarness
  def initialize(dependencies, seeds)
    @dependencies, @seeds = dependencies, seeds
  end
  def pure_mandatory_arity?(_body) = true
  def mandatory_arity(_body) = 1
  def bytecode_ir_source_classes(*) = nil
  def bytecode_ir_call_result_classes(*) = nil
  def bytecode_ir_argument_classes(definition, _position, read: nil)
    return @seeds[definition.irep] if @seeds.key?(definition.irep)

    dependency = @dependencies[definition.irep]
    read && dependency ? read.call(dependency, 1, 1) : nil
  end
end
graph_bodies = %w[seed middle leaf].to_h do |label|
  [label, Irep.new(label: label, nlocals: 2, nregs: 2, instructions: [
    Insn.new(lineno: 1, addr: 0, op: 'ENTER', args: '1:0:0:0:0:0:0:0 (0x0)'),
    Insn.new(lineno: 1, addr: 4, op: 'RETURN', args: 'R1')
  ])]
end
graph_definitions = graph_bodies.keys.map { |label| GraphDefinition.new('Graph', label, label) }
graph_harness = GraphHarness.new({ 'middle' => graph_bodies['seed'], 'leaf' => graph_bodies['middle'] },
                                 { 'seed' => Set[:Integer].freeze })
graph_facts = IrCallGraphTypes.collect(graph_harness, graph_definitions, graph_bodies)
check.call('complete graph facts propagate over multiple rounds', graph_facts.dig('leaf', '1') == Set[:Integer])
limited = IrCallGraphTypes.collect(graph_harness, graph_definitions, graph_bodies, max_rounds: 1)
check.call('round limit retains completed facts without publishing pending nodes', limited.dig('middle', '1') == Set[:Integer] && !limited.key?('leaf'))
cyclic = GraphHarness.new({ 'seed' => graph_bodies['middle'], 'middle' => graph_bodies['seed'] }, {})
check.call('an unresolved recursive component never becomes an empty inferred type',
           IrCallGraphTypes.collect(cyclic, graph_definitions.first(2), graph_bodies).empty?)
aliased = graph_definitions + [GraphDefinition.new('Other', 'alias_seed', 'seed')]
check.call('shared body identities are not graph seeds', IrCallGraphTypes.collect(graph_harness, aliased, graph_bodies).empty?)
check.call('graph summary table and completed argument maps are immutable', graph_facts.frozen? && graph_facts['leaf'].frozen?)

if ENV['MRBC']
  require 'json'
  require 'open3'
  require 'tmpdir'
  require 'rbconfig'
  root = File.expand_path('../..', __dir__)
  Dir.mktmpdir('ir-argument-fixture') do |dir|
    File.write(File.join(dir, 'fixture.rb'), <<~SOURCE)
      class IrArgLeft
        def ir_argument_fixture(value)
          value
        end
        def ir_argument_entry
          previous = 'poisoned output'
          ir_argument_fixture(1)
        end
      end
      class IrArgRight
        def ir_argument_fixture(value)
          value
        end
      end
      class IrArgMain
        def ir_argument_run
          IrArgLeft.new.ir_argument_entry
          IrArgLeft.new.ir_argument_fixture([])
          IrArgRight.new.ir_argument_fixture('string')
        end
      end
    SOURCE
    mrbc = File.expand_path(ENV.fetch('MRBC'))
    report = File.join(dir, 'facts.json')
    output, status = Open3.capture2e({ 'MRBC' => mrbc, 'BC2CPP_SIG_DIRS' => '' }, RbConfig.ruby,
                                    File.join(root, 'scripts/bc2cpp/type_check.rb'), '--files', 'fixture.rb',
                                    '--format', 'json', '--no-sends', '--out', report, chdir: dir)
    raise "compiler fixture failed: #{output}" unless status.success?

    facts = JSON.parse(File.read(report))
    methods = facts.fetch('methods').select { |method| method['name'] == 'ir_argument_fixture' }
    left_param = methods.find { |method| method['owner'] == 'IrArgLeft' }.fetch('params').first
    right_param = methods.find { |method| method['owner'] == 'IrArgRight' }.fetch('params').first
    check.call('real compiler joins implicit self and explicit receiver callers',
               left_param['type'].split(' | ').sort == %w[Array Integer] && left_param['source'] == 'inferred:receiver-call-sites')
    check.call('real compiler excludes unrelated same-name caller', right_param['type'] == 'String')
  end
  Dir.mktmpdir('ir-call-graph-fixture') do |dir|
    File.write(File.join(dir, 'fixture.rb'), <<~SOURCE)
      class IrGraphLeft
        def ir_graph_entry(value)
          IrGraphSink.new.ir_graph_forward(value)
        end
      end
      class IrGraphRight
        def ir_graph_entry(value)
          value
        end
      end
      class IrGraphSink
        def ir_graph_forward(value)
          value
        end
      end
      class IrGraphOtherSink
        def ir_graph_forward(value)
          value
        end
      end
      class IrGraphMain
        def ir_graph_run
          IrGraphLeft.new.ir_graph_entry(1)
          IrGraphLeft.new.ir_graph_entry([])
          IrGraphRight.new.ir_graph_entry('unrelated')
          IrGraphOtherSink.new.ir_graph_forward('other')
        end
      end
    SOURCE
    run_graph = lambda do |enabled|
      output, status = Open3.capture2e({ 'MRBC' => File.expand_path(ENV.fetch('MRBC')), 'BC2CPP_SIG_DIRS' => '',
                                        'BC2CPP_IR_CALL_GRAPH_TYPES' => enabled ? '1' : '0' }, RbConfig.ruby,
                                      File.join(root, 'scripts/bc2cpp/type_check.rb'), '--files', 'fixture.rb',
                                      '--format', 'json', '--no-sends', chdir: dir)
      raise "call graph fixture failed: #{output}" unless status.success?

      JSON.parse(output)
    end
    graph_on = run_graph.call(true)
    graph_off = run_graph.call(false)
    sink = ->(facts) { facts['methods'].find { |method| method['owner'] == 'IrGraphSink' && method['name'] == 'ir_graph_forward' } }
    check.call('call graph forwards a complete argument union into another polymorphic name',
               sink.call(graph_on)['params'][0]['type'].split(' | ').sort == %w[Array Integer] &&
                 sink.call(graph_on)['params'][0]['source'] == 'inferred:call-graph')
    check.call('disabled call graph leaves forwarding parameter unknown', sink.call(graph_off)['params'][0]['type'].nil?)
    check.call('graph argument facts feed independent IR returns', graph_on['ir_feedback'].any? { |row|
      row['owner'] == 'IrGraphSink' && row['kind'] == 'return' && row['status'] == 'inferred' && row['type'].split(' | ').sort == %w[Array Integer]
    })
    File.open(File.join(dir, 'fixture.rb'), 'a') do |file|
      file.puts "class IrGraphUnknown; def ir_graph_unknown(receiver, value); receiver.ir_graph_forward(value); end; end"
    end
    opaque = run_graph.call(true)
    check.call('an opaque graph caller poisons the complete forwarded parameter', sink.call(opaque)['params'][0]['type'].nil?)
  end
else
  puts 'SKIP real compiler fixture (set MRBC)'
end
