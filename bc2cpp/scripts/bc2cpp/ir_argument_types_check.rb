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
  instruction = Insn.synthetic('SEND', "R1 :arity_probe #{spelling}")
  expected_plain = instruction.n_spec && instruction.n_spec != '*' && instruction.nk_spec.nil?
  expected_splat = instruction.n_spec == '*' && instruction.nk_spec.nil?
  check.call("decoded arity matches printed semantics for #{spelling}",
             instruction.plain_fixed_argc? == expected_plain && instruction.pure_splat? == expected_splat)
end
zero_call = Insn.synthetic('SEND0', 'R1 :arity_probe')
check.call('absent argc retains nil fixed-arity and false pure-splat results',
           zero_call.plain_fixed_argc?.nil? && zero_call.pure_splat? == false)
reinstalled_call = Insn.synthetic('SEND', 'R1 :arity_probe n=2')
check.call('fixed argc is classified before operand replacement', reinstalled_call.plain_fixed_argc? == true)
reinstalled_call.typed = OperandSchema.parse('SEND', 'R1 :arity_probe n=*')
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
puts 'rest, block and keyword call-site joins passed'

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
    opt = row.call('RkdKwOpt', 'rkd_kw_opt')['keyword_params'].find { |param| param['name'] == 'flag' }
    check.call('optional keyword stays untyped', opt['required'] == false && opt['type'].nil?)
    # The emitted names are CRuby core classes, which the writer declares; pass them as its declared set.
    line = ->(owner, name) { TypeCheckRbs.method_line(row.call(owner, name), Set['Integer', 'String']) }
    check.call('candidate RBS writes the rest element type as *(T)', line.call('RkdRest', 'rkd_rest').include?('(*(Integer | String))'))
    check.call('candidate RBS writes the required block for a Proc block param',
               line.call('RkdBlock', 'rkd_block').include?(' { (*untyped) -> untyped } -> ') &&
                 !line.call('RkdBlock', 'rkd_block').include?('?{'))
    check.call('candidate RBS keeps the block optional when no caller passes a literal block',
               line.call('RkdBlockVar', 'rkd_block_var').include?('?{'))
    check.call('candidate RBS writes the required keyword type', line.call('RkdKw', 'rkd_kw').include?('key: String | Integer'))
    check.call('candidate RBS keeps an optional keyword untyped', line.call('RkdKwOpt', 'rkd_kw_opt').include?('?flag: untyped'))
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
