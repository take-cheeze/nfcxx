#!/usr/bin/env ruby
# frozen_string_literal: true

require 'set'
require_relative '../../tools/bc2cpp/ir_argument_types'
require_relative '../../tools/bc2cpp/irep'

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
ReceiverBody = Struct.new(:instructions, :nlocals, :catch_handlers)
class ReceiverHarness < CodeGen
  attr_accessor :self_mask
  def bytecode_ir_source_classes(_body, _index, _register) = Set[:String]
  def return_class_self_receiver(_body) = @self_mask
  def bytecode_ir_mask_classes(mask) = mask
end
receiver_harness = ReceiverHarness.new
receiver_harness.self_mask = Set[:Left]
implicit_body = ReceiverBody.new([Insn.new(lineno: 1, addr: 0, op: :SSEND, args: '')])
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
    Insn.new(lineno: 1, addr: 0, op: :ENTER, args: '1:0:0:0:0:0:0:0 (0x0)'),
    Insn.new(lineno: 1, addr: 4, op: :RETURN, args: 'R1')
  ])]
end
graph_definitions = graph_bodies.keys.map { |label| GraphDefinition.new('Graph', label, label) }
graph_harness = GraphHarness.new({ 'middle' => graph_bodies['seed'], 'leaf' => graph_bodies['middle'] },
                                 { 'seed' => Set[:Integer].freeze })
graph_facts = IrCallGraphTypes.collect(graph_harness, graph_definitions, graph_bodies)
check.call('complete graph facts propagate over multiple rounds', graph_facts.dig('leaf', 1) == Set[:Integer])
limited = IrCallGraphTypes.collect(graph_harness, graph_definitions, graph_bodies, max_rounds: 1)
check.call('round limit retains completed facts without publishing pending nodes', limited.dig('middle', 1) == Set[:Integer] && !limited.key?('leaf'))
cyclic = GraphHarness.new({ 'seed' => graph_bodies['middle'], 'middle' => graph_bodies['seed'] }, {})
check.call('an unresolved recursive component never becomes an empty inferred type',
           IrCallGraphTypes.collect(cyclic, graph_definitions.first(2), graph_bodies).empty?)
aliased = graph_definitions + [GraphDefinition.new('Other', 'alias_seed', 'seed')]
check.call('shared body identities are not graph seeds', IrCallGraphTypes.collect(graph_harness, aliased, graph_bodies).empty?)
check.call('graph summary table and completed argument maps are immutable', graph_facts.frozen? && graph_facts['leaf'].frozen?)

if ENV['MRBC']
  require_relative 'type_check_fixture'
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
    report = File.join(dir, 'facts.json')
    facts = TypeCheckFixture.report(dir, env: { 'BC2CPP_SIG_DIRS' => '' }, out: report, label: 'compiler fixture')
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
      TypeCheckFixture.report(dir, env: { 'BC2CPP_SIG_DIRS' => '',
                                         'BC2CPP_IR_CALL_GRAPH_TYPES' => enabled ? '1' : '0' }, label: 'call graph fixture')
    end
    graph_on = run_graph.call(true)
    graph_off = run_graph.call(false)
    sink = ->(facts) { facts['methods'].find { |method| method['owner'] == 'IrGraphSink' && method['name'] == 'ir_graph_forward' } }
    check.call('call graph forwards a complete argument union into another polymorphic name',
               sink.call(graph_on)['params'][0]['type'].split(' | ').sort == %w[Array Integer] &&
                 sink.call(graph_on)['params'][0]['source'] == 'inferred:receiver-call-sites')
    # The pools type the forwarding parameter without the call graph: its entry is a poly name whose sites all reach it.
    check.call('disabled call graph still types forwarding parameter from its pooled callers (same union, receiver-call-sites)',
               sink.call(graph_off)['params'][0]['type'].split(' | ').sort == %w[Array Integer] &&
                 sink.call(graph_off)['params'][0]['source'] == 'inferred:receiver-call-sites')
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


# The printed arity remains the compatibility oracle for decoded classification.
require_relative '../../tools/bc2cpp/irep'
arity_spellings = (0..16).map { |count| "n=#{count}" } +
                  %w[n=* n=0|nk=0 n=3|nk=2 n=3|nk=* n=*|nk=0 n=*|nk=2 n=*|nk=*]
arity_spellings.each do |spelling|
  instruction = Insn.synthetic(:SEND, "R1 :arity_probe #{spelling}")
  expected_plain = instruction.n_spec && instruction.n_spec != '*' && instruction.nk_spec.nil?
  expected_splat = instruction.n_spec == '*' && instruction.nk_spec.nil?
  check.call("decoded arity matches printed semantics for #{spelling}",
             instruction.plain_fixed_argc? == expected_plain && instruction.pure_splat? == expected_splat)
end
zero_call = Insn.synthetic(:SEND0, 'R1 :arity_probe')
check.call('absent argc retains nil fixed-arity and false pure-splat results',
           zero_call.plain_fixed_argc?.nil? && zero_call.pure_splat? == false)
reinstalled_call = Insn.synthetic(:SEND, 'R1 :arity_probe n=2')
check.call('fixed argc is classified before operand replacement', reinstalled_call.plain_fixed_argc? == true)
reinstalled_call.typed = OperandSchema.parse(:SEND, 'R1 :arity_probe n=*')
check.call('classification observes replacement operands without a stale memo',
           reinstalled_call.plain_fixed_argc? == false && reinstalled_call.pure_splat? == true)

# Optional positionals: `def accept(a, b = nil)` (mandatory 1, optional 1). A call-site join is complete only when
# every reaching call passes the position: a call that omits it binds the default. Position p is read at register
# site + p, so position 2 of a call with receiver register 2 is register 4.
class OptionalArgumentHarness < ArgumentHarness
  attr_accessor :optional_count, :optional_shape

  def optional_arity(_irep) = @optional_count
  def optional_positionals_only?(_irep) = @optional_shape
end
opt_left = Definition.new('accept', 'opt_left')
opt_right = Definition.new('accept', 'opt_right')
opt_classes = { [:a, 2] => Set[:Left], [:b, 2] => Set[:Left], [:c, 2] => Set[:Left],
                [:a, 3] => Set[:Integer], [:b, 3] => Set[:String],
                [:a, 4] => Set[:Integer], [:b, 4] => Set[:Float] }
build_optional = lambda do |sites|
  OptionalArgumentHarness.new({ 'Left' => opt_left, 'Right' => opt_right }, sites, opt_classes).tap do |h|
    h.optional_count = 1
    h.optional_shape = true
  end
end
opt_sites = [[:a, 0, 2, 2], [:b, 0, 2, 2]]
opt_harness = build_optional.call(opt_sites)
check.call('optional position joins the values of calls that all pass it',
           opt_harness.bytecode_ir_optional_argument_classes(opt_left, 2) == Set[:Integer, :Float])
check.call('mandatory position of an optional def joins over the same complete sites',
           opt_harness.bytecode_ir_optional_argument_classes(opt_left, 1) == Set[:Integer, :String])
check.call('a position past the accepted counts is refused',
           opt_harness.bytecode_ir_optional_argument_classes(opt_left, 3).nil?)
check.call('the required-only API still refuses sites that pass more than its arity',
           opt_harness.bytecode_ir_argument_classes(opt_left, 1).nil?)
check.call('a reaching call that omits the optional withdraws its join (the default may be bound)',
           build_optional.call(opt_sites + [[:c, 0, 2, 1]]).bytecode_ir_optional_argument_classes(opt_left, 2).nil?)
check.call('a reaching call with more arguments than the def accepts withdraws the join',
           build_optional.call([[:a, 0, 2, 2], [:b, 0, 2, 3]]).bytecode_ir_optional_argument_classes(opt_left, 2).nil?)
check.call('rest, keyword or block shapes are not optional-positional joins',
           build_optional.call(opt_sites).tap { |h| h.optional_shape = false }.bytecode_ir_optional_argument_classes(opt_left, 2).nil?)
check.call('a single calling site gives its own value',
           build_optional.call([[:a, 0, 2, 2]]).bytecode_ir_optional_argument_classes(opt_left, 2) == Set[:Integer])
check.call('a site that reaches only another body is not a caller of this def',
           build_optional.call([[:a, 0, 2, 2], [:c, 0, 2, 1]]).tap { |h| opt_classes[[:c, 2]] = Set[:Right] }
                                                             .bytecode_ir_optional_argument_classes(opt_left, 2) == Set[:Integer])
check.call('optional join is immutable', opt_harness.bytecode_ir_optional_argument_classes(opt_left, 2).frozen?)
puts 'optional-positional call-site joins passed'

# Rest, block and required keyword joins. The argument lambdas read per-register values, so each site names its own
# registers; +reach+ says which sites are callers of the def.
Rest = Definition.new('gather', 'rest_def')
rest_sites = [[:r1, 0, 2, 3], [:r2, 0, 2, 1]]
rest_values = { [:r1, 4] => Set[:Integer], [:r1, 5] => Set[:String], [:r2, 3] => Set[:Float] }
rest_targets = { 'Left' => Rest }
rest_receivers = { r1: Set[:Left], r2: Set[:Left] }
rest_join = lambda do |sites = rest_sites, admit: ->(_body, _index) { true }, fixed: 1, minimum: 1|
  IrArgumentTypes.rest_classes(Rest, sites, receiver: ->(body, _index, _reg) { rest_receivers[body] },
                               target: ->(_name, klass) { rest_targets[klass] },
                               argument: ->(body, _index, reg) { rest_values[[body, reg]] },
                               fixed: fixed, minimum: minimum, admit: admit)
end
check.call('rest join is the union of every extra argument over the reaching sites',
           rest_join.call == Set[:Integer, :String])
check.call('rest with no reaching site passing an extra argument gives no element type',
           rest_join.call([[:r2, 0, 2, 1]]).nil?)
check.call('rest refuses a site below the mandatory count', rest_join.call([[:r1, 0, 2, 0]]).nil?)
check.call('rest refuses a site its admit rejects (keyword-carrying call)',
           rest_join.call(admit: ->(body, _index) { body != :r2 }).nil?)
rest_values.delete([:r1, 5])
check.call('rest refuses one unknown extra value', rest_join.call.nil?)
rest_values[[:r1, 5]] = Set[:String]
rest_receivers[:r2] = nil
check.call('rest refuses an unknown receiver of any site', rest_join.call.nil?)
rest_receivers[:r2] = Set[:Left]
check.call('rest result is immutable', rest_join.call.frozen?)

block_sites = [[:b1, 0, 2, 1], [:b2, 0, 2, 0]]
Block = Definition.new('yield_later', 'block_def')
block_targets = { 'Left' => Block }
block_receivers = { b1: Set[:Left], b2: Set[:Left] }
block_proc = lambda do |verdicts|
  IrArgumentTypes.block_proc(Block, block_sites, receiver: ->(body, _index, _reg) { block_receivers[body] },
                             target: ->(_name, klass) { block_targets[klass] },
                             proc_value: ->(body, _index, _reg, _argc) { verdicts[body] })
end
check.call('block is Proc when every reaching site passes a Proc', block_proc.call({ b1: true, b2: true }) == Set[:Proc])
check.call('one site without a Proc refuses the block join', block_proc.call({ b1: true, b2: false }).nil?)
check.call('no reaching site gives no block fact', IrArgumentTypes.block_proc(Block, [], receiver: ->(*) { Set[:Left] },
                                                                              target: ->(*) { nil }, proc_value: ->(*) { true }).nil?)

keyword_values = { k1: Set[:String], k2: Set[:Integer] }
keyword_sites = [[:k1, 0, 2, 1], [:k2, 0, 2, 1]]
keyword_join = lambda do |sites = keyword_sites|
  IrArgumentTypes.keyword_classes(Rest, sites, receiver: ->(_body, _index, _reg) { Set[:Left] },
                                  target: ->(_name, _klass) { Rest },
                                  value: ->(body, _index, _reg, _argc) { keyword_values[body] })
end
check.call('keyword join is the union of the value at every site', keyword_join.call == Set[:String, :Integer])
keyword_values[:k2] = nil
check.call('a site without a literal keyword value refuses the keyword join', keyword_join.call.nil?)
keyword_values[:k1] = Set[]
check.call('a required keyword join refuses a site that omits the key', keyword_join.call.nil?)
# Optional: an omitting site returns empty classes and the default joins in; an unknown site still refuses.
optional_values = { k1: Set[:String], k2: Set[] }
optional_join = lambda do |default|
  IrArgumentTypes.keyword_classes(Rest, keyword_sites, receiver: ->(*) { Set[:Left] }, target: ->(*) { Rest },
                                  value: ->(body, *) { optional_values[body] }, default: default)
end
check.call('optional keyword join adds the default class to the passed values', optional_join.call(Set[:NilClass]) == Set[:String, :NilClass])
optional_values[:k1] = Set[]
check.call('optional keyword join with every site omitting is the default class', optional_join.call(Set[:NilClass]) == Set[:NilClass])
optional_values[:k1] = nil
check.call('optional keyword join refuses an unknown site', optional_join.call(Set[:NilClass]).nil?)
puts 'rest, block and keyword call-site joins passed'

# Body analysis (BytecodeIR::Types) consumes the joins as ir_type_feedback passes them. Synthetic ireps: no mrbc.
require_relative '../../tools/bc2cpp/irep_arity'
body_irep = lambda do |instructions|
  Irep.new(label: 'body', nlocals: 4, nregs: 8, instructions: instructions.map { |op, text| Insn.new(lineno: 1, addr: 0, op: op, args: text) })
end
body_fact = lambda do |instructions, index, reg, **inputs|
  BytecodeIR::Types.new(body_irep.call(instructions), **inputs).fact_at(index, reg)&.classes
end
rest_body = [[:ENTER, '0:0:1:0:0:0:0:0 (0x0)'], [:GETIDX0, 'R2 R1[0]'], [:RETURN, 'R2']]
check.call('rest element receiver sees the joined element type (with nil for an absent index)',
           body_fact.call(rest_body, 2, 2, inferred_rest_elements: { 1 => Set[:Integer, :String] }) == Set[:NilClass, :Integer, :String])
check.call('rest element receiver stays untyped without a join', body_fact.call(rest_body, 2, 2).nil?)
rest_copy = [[:ENTER, '0:0:1:0:0:0:0:0 (0x0)'], [:MOVE, 'R3 R1'], [:GETIDX0, 'R2 R3[0]'], [:RETURN, 'R2']]
check.call('a MOVE copy read only by element reads keeps the join',
           body_fact.call(rest_copy, 3, 2, inferred_rest_elements: { 1 => Set[:Integer] }) == Set[:NilClass, :Integer])
rest_mutated = [[:ENTER, '0:0:1:0:0:0:0:0 (0x0)'], [:MOVE, 'R3 R1'], [:SEND, 'R3 :push n=1'],
                [:GETIDX0, 'R2 R1[0]'], [:RETURN, 'R2']]
check.call('a body that calls a method on the rest array (or a copy) refuses the element join',
           body_fact.call(rest_mutated, 4, 2, inferred_rest_elements: { 1 => Set[:Integer] }).nil?)
# A signature's `*T` (declared_rest_elements) types the element read where the call-site join is withheld: the join is
# used only while the body cannot change the array, and the declared T stands in otherwise. With both, the join wins, as
# for a required parameter (definition_types before declared_definition). A declared bound is not a body fact for the
# undeclared query (`at`), which exact consumers use.
declared_rest = lambda do |instructions, index, reg, **inputs|
  BytecodeIR::Types.new(body_irep.call(instructions), **inputs).fact_at(index, reg)
end
declared_only = declared_rest.call(rest_body, 2, 2, declared_rest_elements: { 1 => Set[:Integer] })
check.call('a declared *Integer rest read in the body is Integer (nil for an absent index), and is declared',
           declared_only&.classes == Set[:NilClass, :Integer] && declared_only.declared?)
check.call('a declared rest element is not visible to the undeclared query',
           BytecodeIR::Types.new(body_irep.call(rest_body), declared_rest_elements: { 1 => Set[:Integer] }).at(2, 2).nil?)
check.call('a mutated rest with a declared *Integer takes only the declaration: the call-site join String is not added',
           declared_rest.call(rest_mutated, 4, 2, inferred_rest_elements: { 1 => Set[:Integer, :String] },
                              declared_rest_elements: { 1 => Set[:Integer] })&.classes == Set[:NilClass, :Integer])
rest_captured = [[:ENTER, '0:0:1:0:0:0:0:0 (0x0)'], [:LAMBDA, 'R3 I[0]'], [:GETIDX0, 'R2 R1[0]'], [:RETURN, 'R2']]
check.call('a closure capturing the rest withdraws the join, and the declared *Integer types the read',
           declared_rest.call(rest_captured, 3, 2, inferred_rest_elements: { 1 => Set[:Integer, :String] },
                              declared_rest_elements: { 1 => Set[:Integer] })&.classes == Set[:NilClass, :Integer] &&
           declared_rest.call(rest_captured, 3, 2, inferred_rest_elements: { 1 => Set[:Integer, :String] }).nil?)
check.call('a declared *String with a private join of Integer: the join is read, as for a required parameter',
           declared_rest.call(rest_body, 2, 2, inferred_rest_elements: { 1 => Set[:Integer] },
                              declared_rest_elements: { 1 => Set[:String] })&.classes == Set[:NilClass, :Integer])
keyword_body = [[:ENTER, '0:0:0:0:1:0:0:0 (0x0)'], [:KARG, 'R3 :key'], [:RETURN, 'R3']]
check.call('required keyword reads its joined type',
           body_fact.call(keyword_body, 2, 3, inferred_keywords: { 'key' => Set[:String, :Integer] }) == Set[:String, :Integer])
check.call('required keyword stays untyped without a join', body_fact.call(keyword_body, 2, 3).nil?)
declared_keyword = BytecodeIR::Types.new(body_irep.call(keyword_body), declared_keywords: { 'key' => Set[:Symbol] },
                                         inferred_keywords: { 'key' => Set[:String, :Integer] }).fact_at(2, 3)
check.call('a declared keyword type wins over the call-site join', declared_keyword.classes == Set[:Symbol] && declared_keyword.declared?)
# Optional keyword `flag` in the layout mrbc emits: KEY_P, a JMPIF over the default, the default, a JMP to the join
# after KARG. The read is the last instruction, so its reaching definitions are the KARG value and the default.
optional_fact = lambda do |default, **inputs|
  karg = 4 + default.size # ENTER, KEY_P, JMPIF, default..., JMP, then KARG
  insns = [[:ENTER, '0:0:0:0:1:0:0:0 (0x0)'], [:KEY_P, 'R3 :flag'], [:JMPIF, "R3 #{4 * karg}"]] + default +
          [[:JMP, (4 * (karg + 1)).to_s], [:KARG, 'R3 :flag'], [:KEYEND, ''], [:RETURN, 'R3']]
  irep = Irep.new(label: 'body', nlocals: 4, nregs: 8, instructions: insns.each_with_index.map do |(op, args), i|
    Insn.new(lineno: 1, addr: 4 * i, op: op, args: args)
  end)
  BytecodeIR::Types.new(irep, **inputs).fact_at(insns.size - 1, 3)&.classes
end
check.call('optional keyword reads its join, which holds the passed class and the literal default class',
           optional_fact.call([[:LOADI_1, 'R3 (1)']], inferred_keywords: { 'flag' => Set[:Integer] }) == Set[:Integer])
check.call('a joined default class (omitted site) is read with the passed class',
           optional_fact.call([[:LOADNIL, 'R3 (0)']], inferred_keywords: { 'flag' => Set[:String, :NilClass] }) == Set[:String, :NilClass])
check.call('optional keyword with a literal default stays untyped without a join', optional_fact.call([[:LOADI_1, 'R3 (1)']]).nil?)
check.call('optional keyword with a non-literal default stays untyped even with the join absent',
           optional_fact.call([[:SEND0, 'R3 :to_s']]).nil?)
check.call('a declared optional keyword type wins over the join',
           optional_fact.call([[:LOADSYM, 'R3 :x']], declared_keywords: { 'flag' => Set[:Symbol] },
                                                      inferred_keywords: { 'flag' => Set[:Integer] }) == Set[:Symbol])
block_body = [[:ENTER, '0:0:0:0:0:0:1:0 (0x0)'], [:SEND, 'R1 :call n=0']]
check.call('a block called with .call is a Proc when every caller passes a literal block',
           body_fact.call(block_body, 1, 1, inferred_args: { 1 => Set[:Proc] }) == Set[:Proc])
check.call('a block without the join keeps its nominal Proc-or-nil bound', body_fact.call(block_body, 1, 1) == Set[:Proc, :NilClass])

# End to end through the codegen joins: a poisoned name (a splatted or dynamic caller) refuses the rest join, so the
# body sees nothing; the same name with a plain caller gives the join; BC2CPP_IR_ARGUMENT_TYPES=0 withdraws it.
class RestBodyHarness < ArgumentHarness
  attr_accessor :gather_sites

  def initialize(rest_irep, caller_classes)
    super({ 'Left' => Rest }, [], caller_classes)
    @ireps = { 'rest_def' => rest_irep }
  end

  def entry_arg_call_index = [{ 'gather' => @gather_sites }, @poisoned]
end
# One required parameter and a rest parameter: the rest register is R2 (mandatory + optional + 1), its element R3.
rest_irep = Irep.new(label: 'rest_def', nlocals: 4, nregs: 8, instructions: [
  Insn.new(lineno: 1, addr: 0, op: :ENTER, args: '1:0:1:0:0:0:0:0 (0x0)'),
  Insn.new(lineno: 1, addr: 4, op: :GETIDX0, args: 'R3 R2[0]'),
  Insn.new(lineno: 1, addr: 8, op: :RETURN, args: 'R3')
])
caller = ReceiverBody.new([Insn.new(lineno: 1, addr: 0, op: :SEND, args: 'R2 :gather n=1')])
end_to_end = RestBodyHarness.new(rest_irep, { [caller, 2] => Set[:Left], [caller, 4] => Set[:Integer] })
end_to_end.gather_sites = [[caller, 0, 2, 2]]
rest_join_of = -> { end_to_end.bytecode_ir_rest_argument_classes(Rest) }
body_element = lambda do |join|
  inputs = join ? { inferred_rest_elements: { 2 => join } } : {}
  BytecodeIR::Types.new(rest_irep, **inputs).fact_at(2, 3)&.classes
end
check.call('codegen rest join reaches the body as the element type',
           rest_join_of.call == Set[:Integer] && body_element.call(rest_join_of.call) == Set[:NilClass, :Integer])
end_to_end.poisoned << 'gather'
check.call('a poisoned (splat or dynamic) caller refuses the rest join and so the body element type',
           rest_join_of.call.nil? && body_element.call(rest_join_of.call).nil?)
end_to_end.poisoned.clear
ENV['BC2CPP_IR_ARGUMENT_TYPES'] = '0'
begin
  check.call('BC2CPP_IR_ARGUMENT_TYPES=0 withdraws the rest join at the codegen boundary', rest_join_of.call.nil?)
ensure
  ENV.delete('BC2CPP_IR_ARGUMENT_TYPES')
end
check.call('the codegen join is restored once the switch is off', rest_join_of.call == Set[:Integer])
# The signature side, host only: RbsSignatures reads `*T` into the body as declared_rest_elements at the register after
# the required and optional positionals, and only for a positional-only rest (no post, keyword or keyword-rest).
require 'tmpdir'
require_relative '../../tools/bc2cpp/rbs_signatures'
SigDef = Struct.new(:owner, :name, :irep, :visibility)
sig_methods = { 'typed_rest' => [0, 0, 1, 0, '(*Integer) -> untyped'], 'untyped_rest' => [0, 0, 1, 0, '(*untyped) -> untyped'],
                'mixed_rest' => [1, 0, 1, 0, '(String, *Integer) -> untyped'],
                'post_rest' => [0, 0, 1, 1, '(*Integer, String) -> untyped'] }
sig_ireps = {}
sig_registry = {}
sig_source = +"class RestSig\n"
sig_methods.each do |name, (mand, opt, rest, post, type)|
  label = "sig_#{name}"
  rest_reg = mand + opt + 1
  sig_source << "  def #{name}: #{type}\n"
  sig_ireps[label] = Irep.new(label: label, nlocals: 4, nregs: 8, instructions: [
    Insn.new(lineno: 1, addr: 0, op: :ENTER, args: "#{mand}:#{opt}:#{rest}:#{post}:0:0:0:0 (0x0)"),
    Insn.new(lineno: 1, addr: 4, op: :GETIDX0, args: "R#{rest_reg + 1} R#{rest_reg}[0]"),
    Insn.new(lineno: 1, addr: 8, op: :RETURN, args: "R#{rest_reg + 1}")
  ])
  sig_registry[name] = [SigDef.new('RestSig', name, label, nil)]
end
sig_source << "end\n"
Dir.mktmpdir('rest-signature-fixture') do |dir|
  File.write(File.join(dir, 'rest.rbs'), sig_source)
  loaded = RbsSignatures.load([dir], display_root: dir)
  applied = RbsSignatures.apply(loaded, sig_ireps, sig_registry, {}, {}, {})
  body_of = lambda do |name, **inputs|
    irep = sig_ireps["sig_#{name}"]
    analysis = RbsSignatures.ir_types(applied, irep, **inputs)
    analysis.fact_at(2, irep.enter.enter_fields[0].to_i + irep.enter.enter_fields[1].to_i + 2)
  end
  typed = body_of.call('typed_rest')
  check.call('a signature `*Integer` types the body element read as Integer (declared, nil for an absent index)',
             typed&.classes == Set[:NilClass, :Integer] && typed.declared?)
  check.call('the TC1005 "accepted but give no hint" note no longer names a `*T` rest',
             loaded.diagnostics.none? { |d| d.message.start_with?('RestSig#typed_rest:') && d.message.include?('a rest parameter') } &&
             loaded.diagnostics.any? { |d| d.message.start_with?('RestSig#untyped_rest:') && d.message.include?('a rest parameter') })
  check.call('a signature `*untyped` gives the body no element type', body_of.call('untyped_rest').nil?)
  mixed = body_of.call('mixed_rest')
  check.call('a `*Integer` after a required parameter types the rest element, not the required one',
             mixed&.classes == Set[:NilClass, :Integer] && mixed.declared?)
  check.call('a rest followed by a post parameter gives no declared element type (the layout is not the one ENTER fills)',
             body_of.call('post_rest').nil?)
  joined = body_of.call('typed_rest', inferred_rest_elements: { 1 => Set[:Integer] })
  check.call('a signature `*Integer` and a complete private join of Integer read Integer',
             joined&.classes == Set[:NilClass, :Integer])
end

puts 'body consumes call-site joins (rest element, required keyword, Proc block) passed'

if ENV['MRBC']
  require_relative '../../tools/bc2cpp/type_check_rbs'
  rest_block_source = <<~SOURCE
    class RkdRest
      def rkd_rest(*items)
        items
      end
    end
    class RkdRestNone
      def rkd_rest_none(value, *items)
        items
      end
    end
    class RkdRestSplat
      def rkd_rest_splat(*items)
        items
      end
    end
    class RkdRestKw
      def rkd_rest_kw(*items)
        items
      end
    end
    class RkdBlock
      def rkd_block(&blk)
        blk
      end
    end
    class RkdBlockMissing
      def rkd_block_missing(value, &blk)
        blk
      end
    end
    class RkdBlockVar
      def rkd_block_var(&blk)
        blk
      end
    end
    class RkdKw
      def rkd_kw(value, key:)
        key
      end
    end
    class RkdKwMissing
      def rkd_kw_missing(value, key:)
        key
      end
    end
    class RkdKwSplat
      def rkd_kw_splat(value, key:)
        key
      end
    end
    class RkdKwOpt
      def rkd_kw_opt(value, flag: nil)
        flag
      end
    end
    class RkdKwOptLit
      def rkd_kw_opt_lit(value, flag: 1)
        flag
      end
    end
    class RkdKwOptExpr
      def rkd_kw_opt_expr(value, flag: value.to_s)
        flag
      end
    end
    class RkdKwOptOmit
      def rkd_kw_opt_omit(value, flag: nil)
        flag
      end
    end
    class RkdKwOptSplat
      def rkd_kw_opt_splat(value, flag: 1)
        flag
      end
    end
    class RkdMain
      def rkd_run(list)
        RkdRest.new.rkd_rest(1, "two")
        RkdRest.new.rkd_rest(3)
        RkdRestNone.new.rkd_rest_none(1)
        RkdRestNone.new.rkd_rest_none(2)
        RkdRestSplat.new.rkd_rest_splat(1, 2)
        RkdRestSplat.new.rkd_rest_splat(*list)
        RkdRestKw.new.rkd_rest_kw(1, 2)
        RkdRestKw.new.rkd_rest_kw(3, k: 4)
        RkdBlock.new.rkd_block { 1 }
        RkdBlock.new.rkd_block { 2 }
        RkdBlockMissing.new.rkd_block_missing(1) { 3 }
        RkdBlockMissing.new.rkd_block_missing(2)
        pr = proc { 4 }
        RkdBlockVar.new.rkd_block_var(&pr)
        RkdKw.new.rkd_kw(1, key: "v")
        RkdKw.new.rkd_kw(2, key: 3)
        RkdKwMissing.new.rkd_kw_missing(1, key: "v")
        RkdKwMissing.new.rkd_kw_missing(2, other: 3)
        RkdKwSplat.new.rkd_kw_splat(1, key: "v")
        h = { key: 2 }
        RkdKwSplat.new.rkd_kw_splat(1, **h)
        RkdKwOpt.new.rkd_kw_opt(2)
        RkdKwOptLit.new.rkd_kw_opt_lit(1, flag: 2)
        RkdKwOptLit.new.rkd_kw_opt_lit(2, flag: 3)
        RkdKwOptExpr.new.rkd_kw_opt_expr(1, flag: "x")
        RkdKwOptExpr.new.rkd_kw_opt_expr(2, flag: "y")
        RkdKwOptOmit.new.rkd_kw_opt_omit(1, flag: 2)
        RkdKwOptOmit.new.rkd_kw_opt_omit(2)
        opt_h = { flag: 2 }
        RkdKwOptSplat.new.rkd_kw_opt_splat(1, flag: 2)
        RkdKwOptSplat.new.rkd_kw_opt_splat(2, **opt_h)
      end
    end
  SOURCE
  Dir.mktmpdir('rest-kw-block-fixture') do |dir|
    File.write(File.join(dir, 'fixture.rb'), rest_block_source)
    report = File.join(dir, 'facts.json')
    facts = TypeCheckFixture.report(dir, env: { 'BC2CPP_SIG_DIRS' => '' }, out: report, label: 'rest/kw/block fixture')
    row = lambda do |owner, name|
      facts.fetch('methods').find { |method| method['owner'] == owner && method['name'] == name }
    end
    rest_type = ->(owner, name) { row.call(owner, name)&.dig('rest_param', 'type') }
    check.call('rest joins the extra arguments of every caller (Array[T] element)',
               rest_type.call('RkdRest', 'rkd_rest') == 'Integer | String' &&
                 row.call('RkdRest', 'rkd_rest')['rest_param']['source'] == 'inferred:receiver-call-sites')
    check.call('rest with only fixed-count callers stays untyped', rest_type.call('RkdRestNone', 'rkd_rest_none').nil?)
    check.call('a splatted caller poisons the rest join', rest_type.call('RkdRestSplat', 'rkd_rest_splat').nil?)
    check.call('a keyword-carrying caller refuses the rest join', rest_type.call('RkdRestKw', 'rkd_rest_kw').nil?)
    check.call('block is Proc when every caller passes a literal block',
               row.call('RkdBlock', 'rkd_block')['block_param'] == { 'type' => 'Proc', 'source' => 'inferred:receiver-call-sites' })
    check.call('a caller without a block refuses the block join', row.call('RkdBlockMissing', 'rkd_block_missing')['block_param'].nil?)
    check.call('a caller passing a non-literal proc refuses the block join', row.call('RkdBlockVar', 'rkd_block_var')['block_param'].nil?)
    kw = ->(owner, name) { row.call(owner, name)['keyword_params'].find { |param| param['name'] == 'key' } }
    check.call('required keyword joins the value passed at every caller',
               kw.call('RkdKw', 'rkd_kw')['type'] == 'String | Integer' && kw.call('RkdKw', 'rkd_kw')['required'] == true &&
                 kw.call('RkdKw', 'rkd_kw')['source'] == 'inferred:receiver-call-sites')
    check.call('a caller that omits the required keyword refuses its join', kw.call('RkdKwMissing', 'rkd_kw_missing')['type'].nil?)
    check.call('a double-splatted caller refuses the keyword join', kw.call('RkdKwSplat', 'rkd_kw_splat')['type'].nil?)
    opt = ->(owner, name) { row.call(owner, name)['keyword_params'].find { |param| param['name'] == 'flag' } }
    check.call('optional keyword joins its literal default when every caller omits it',
               opt.call('RkdKwOpt', 'rkd_kw_opt') == { 'name' => 'flag', 'required' => false, 'type' => 'nil', 'source' => 'inferred:receiver-call-sites' })
    check.call('optional keyword with literal default joins the passed class (same class as the default)',
               opt.call('RkdKwOptLit', 'rkd_kw_opt_lit') == { 'name' => 'flag', 'required' => false, 'type' => 'Integer', 'source' => 'inferred:receiver-call-sites' })
    check.call('an omitting caller joins the default class with the passed classes',
               opt.call('RkdKwOptOmit', 'rkd_kw_opt_omit')['type'].split(' | ').sort == %w[Integer nil])
    check.call('optional keyword with a non-literal default stays untyped', opt.call('RkdKwOptExpr', 'rkd_kw_opt_expr')['type'].nil?)
    check.call('a splat-keyword caller refuses the optional keyword join', opt.call('RkdKwOptSplat', 'rkd_kw_opt_splat')['type'].nil?)
    # The emitted names are CRuby core classes, which the writer declares; pass them as its declared set.
    line = ->(owner, name) { TypeCheckRbs.method_line(row.call(owner, name), Set['Integer', 'String']) }
    check.call('candidate RBS writes the rest element type as *(T)', line.call('RkdRest', 'rkd_rest').include?('(*(Integer | String))'))
    check.call('candidate RBS writes the required block for a Proc block param',
               line.call('RkdBlock', 'rkd_block').include?(' { (*untyped) -> untyped } -> ') &&
                 !line.call('RkdBlock', 'rkd_block').include?('?{'))
    check.call('candidate RBS keeps the block optional when no caller passes a literal block',
               line.call('RkdBlockVar', 'rkd_block_var').include?('?{'))
    check.call('candidate RBS writes the required keyword type', line.call('RkdKw', 'rkd_kw').include?('key: String | Integer'))
    check.call('candidate RBS writes an optional keyword type', line.call('RkdKwOptLit', 'rkd_kw_opt_lit').include?('?flag: Integer'))
    check.call('candidate RBS keeps an optional keyword with a non-literal default untyped',
               line.call('RkdKwOptExpr', 'rkd_kw_opt_expr').include?('?flag: untyped'))
  end
  Dir.mktmpdir('rest-kw-block-off') do |dir|
    File.write(File.join(dir, 'fixture.rb'), rest_block_source)
    off = TypeCheckFixture.report(dir, env: { 'BC2CPP_SIG_DIRS' => '', 'BC2CPP_IR_ARGUMENT_TYPES' => '0' }, label: 'rest/kw/block off')
    methods = off.fetch('methods')
    check.call('BC2CPP_IR_ARGUMENT_TYPES=0 restores untyped rest, keyword and block',
               methods.select { |m| m['owner'].start_with?('Rkd') }.all? do |m|
                 (m['rest_param'].nil? || m['rest_param']['type'].nil?) && m['block_param'].nil? &&
                   m['keyword_params'].all? { |p| p['type'].nil? }
               end)
  end
  puts 'rest, block and keyword call-site joins (compiler fixture) passed'
else
  puts 'SKIP rest, block and keyword compiler fixture (set MRBC)'
end
