#!/usr/bin/env ruby
# frozen_string_literal: true

# Unit checks for BytecodeIR's instruction-level queries, over hand-built
# ireps so the expected answers are fixed independent of any compiled gem:
# the address-level branch queries behind the rescue/ensure recognizers, and
# the queries the block-region recognizers build on
# (tools/bc2cpp/bytecode_ir_regions.rb).
require 'set'
require_relative '../../tools/bc2cpp/irep'
require_relative '../../tools/bc2cpp/bytecode_ir'
require_relative '../../tools/bc2cpp/bytecode_ir_regions'
require_relative '../../tools/bc2cpp/bytecode_ir_resumable'

def insn(addr, op, args)
  Insn.new(lineno: 1, addr: addr, op: op, args: args, raw: "#{op} #{args}")
end

failures = []
check = ->(label, ok) { failures << label unless ok }
edge_pairs = ->(edges) { edges.map { |e| [e.src, e.target] } }
program = ->(list) { BytecodeIR::Program.new(Irep.new(label: 't', instructions: list)) }

# Yielding helper regions must have explicit exits and resolved control flow.
helper = ->(list, **fields) { Irep.new(label: 'helper', instructions: list, **fields) }
valid = helper.call([insn(0, 'JMPIF', "R1\t8"), insn(4, 'LOADNIL', 'R2'), insn(8, 'RETURN', 'R2')])
check.call('resumable region retains decoded instruction identity',
           BytecodeIR::ResumableRegion.build(valid).program.instructions.first.source.equal?(valid.instructions.first))
check.call('resumable region rejects unresolved branch',
           BytecodeIR::ResumableRegion.build(helper.call([insn(0, 'JMP', '7'), insn(4, 'RETNIL', '')])).nil?)
check.call('resumable region rejects nonlocal exit',
           BytecodeIR::ResumableRegion.build(helper.call([insn(0, 'BREAK', 'R1'), insn(4, 'RETNIL', '')])).nil?)
check.call('resumable region rejects fallthrough',
           BytecodeIR::ResumableRegion.build(helper.call([insn(0, 'LOADNIL', 'R1')])).nil?)
check.call('resumable region rejects nested blocks',
           BytecodeIR::ResumableRegion.build(helper.call([insn(0, 'RETNIL', '')], reps: ['child'])).nil?)

# Layout: 0 JMPIF->4 (guard entering region at its first address), region
# body [4, 12) with one internal jump, exit JMP at 12, 16 JMPUW, 20 outside.
irep = Irep.new(label: 't', instructions: [
  insn(0, 'JMPIF', "R1\t4"), insn(4, 'JMPNOT', "R1\t9"), insn(8, 'LOADNIL', 'R1 (nil)'),
  insn(9, 'MOVE', "R2\tR1"), insn(12, 'JMP', '20'), insn(16, 'JMPUW', '20'), insn(20, 'RETURN', 'R1')
])
rescue_program = BytecodeIR::Program.new(irep)
check.call('branch_edges in instruction order', edge_pairs.call(rescue_program.branch_edges) == [[0, 4], [4, 9], [12, 20], [16, 20]])
check.call('branch_edges without JMPUW', edge_pairs.call(rescue_program.branch_edges(jmpuw: false)) == [[0, 4], [4, 9], [12, 20]])
check.call('branch_targets', rescue_program.branch_targets == Set[4, 9, 20])
check.call('insn_at_addr', rescue_program.insn_at_addr(9).op == 'MOVE' && rescue_program.insn_at_addr(10).nil?)
check.call('clean region has no breaches', rescue_program.region_boundary_breaches(4...12, 12).empty?)

leaky = Irep.new(label: 't2', instructions: [
  insn(0, 'JMP', '8'), insn(4, 'JMPIF', "R1\t20"), insn(8, 'LOADNIL', 'R1 (nil)'), insn(12, 'JMP', '16'),
  insn(16, 'JMP', '8'), insn(20, 'RETURN', 'R1')
])
breaches = BytecodeIR::Program.new(leaky).region_boundary_breaches(4...12, 12)
check.call('inner branch leaving and outer branch entering', edge_pairs.call(breaches) == [[0, 8], [4, 20], [16, 8]])

# Ensure-region layout: range [4, 20) with target 20; jumps at 4 (out to 30),
# 8 (in-range), 12 (onto target), 16 (onto target); 0 enters from outside at 8
# and 24 (in the body [21, 28)) jumps out of it; 28 is an outside jump onto 20.
crossing = program.call([
  insn(0, 'JMP', '8'), insn(4, 'JMPIF', "R1\t30"), insn(8, 'JMP', '12'), insn(12, 'JMPNOT', "R1\t20"),
  insn(16, 'JMP', '20'), insn(20, 'EXCEPT', 'R2'), insn(24, 'JMP', '30'), insn(28, 'JMP', '20'),
  insn(30, 'RETURN', 'R1')
])
check.call('region_crossings lists in-out and out-in edges',
           edge_pairs.call(crossing.region_crossings(4...20)) == [[0, 8], [4, 30], [12, 20], [16, 20]])
check.call('region_crossings except_from ignores other sources',
           edge_pairs.call(crossing.region_crossings(4...20, except_from: 21...29)) == [[0, 8], [4, 30], [12, 20], [16, 20]])
check.call('region_crossings except_from drops a listed source',
           edge_pairs.call(crossing.region_crossings(4...20, except_from: 0...5)) == [[12, 20], [16, 20]])
check.call('branches_onto lists every source', edge_pairs.call(crossing.branches_onto(20)) == [[12, 20], [16, 20], [28, 20]])
check.call('branches_onto except_from', edge_pairs.call(crossing.branches_onto(20, except_from: 24...29)) == [[12, 20], [16, 20]])
check.call('branches_escaping', edge_pairs.call(crossing.branches_escaping(0...17, 4..12)) == [[4, 30], [12, 20], [16, 20]])
check.call('branches_escaping counts JMPUW', edge_pairs.call(rescue_program.branches_escaping(16..16, 0..10)) == [[16, 20]])
check.call('handlers? is false without handlers', !crossing.handlers?)

unresolved = Irep.new(label: 't3', instructions: [insn(0, 'JMP', '77'), insn(4, 'RETURN', 'R1')])
check.call('branch_edges survive unresolved targets', edge_pairs.call(BytecodeIR::Program.new(unresolved).branch_edges) == [[0, 77]])

# A block-carrying call `R2.each { }` with a MOVE chain feeding the receiver.
call = [
  insn(0, 'MOVE', "R3\tR1"),
  insn(3, 'MOVE', "R2\tR3"),
  insn(6, 'BLOCK', "R3\tI[0]"),
  insn(9, 'SENDB', "R2\t:each\tn=0"),
  insn(12, 'SSENDB', "R4\t:map\tn=0"),
  insn(16, 'RETURN', 'R2')
]
p = program.call(call)

pairs = p.adjacent_pairs('BLOCK', %w[SENDB SSENDB]).to_a
check.call('adjacent pair is BLOCK + SENDB', pairs.map { |a, b, i| [a.op, b.op, i] } == [['BLOCK', 'SENDB', 3]])
check.call('SSENDB after a SENDB is not paired', p.adjacent_pairs('BLOCK', %w[SSENDB]).to_a.empty?)
check.call('run_of_op stops at the first other op', program.call([insn(0, 'MOVE', "R1\tR2"), insn(3, 'MOVE', "R1\tR2"), insn(6, 'RETURN', 'R1')]).run_of_op(0, 'MOVE').map(&:addr) == [0, 3])
check.call('run_of_op is empty on another op or past the end', p.run_of_op(0, 'SENDB').empty? && p.run_of_op(99, 'MOVE').empty?)
check.call('op? finds present op', p.op?('SENDB', 'BREAK'))
check.call('op? rejects absent ops', !p.op?('BREAK', 'RETURN_BLK'))
check.call('instructions_with_op keeps program order',
           p.instructions_with_op('SSENDB', 'MOVE').map(&:addr) == [0, 3, 12])
seen = []
p.each_with_op('BLOCK', 'RETURN') { |source, index| seen << [source.addr, index] }
check.call('each_with_op yields source and index', seen == [[6, 2], [16, 5]])
check.call('previous of entry is nil', p.previous(0).nil?)
check.call('previous is the linear predecessor', p.previous(3).op == 'BLOCK')

root = p.copy_root(2, '2')
check.call('copy_root follows MOVE chain to the parameter register', root.reg == '1' && root.writer.nil?)
written = program.call([insn(0, 'LOADI_1', 'R1 (1)'), insn(2, 'MOVE', "R2\tR1"), insn(4, 'RETURN', 'R2')])
root = written.copy_root(1, '2')
check.call('copy_root reports a non-MOVE writer', root.reg == '1' && root.writer.op == 'LOADI_1')
check.call('copy_root of an unwritten register is itself',
           written.copy_root(1, '7').then { |r| r.reg == '7' && r.writer.nil? })
check.call('copy_root ignores writes after the start index', written.copy_root(0, '2').writer.nil?)
check.call('copy_root of nil is nil', written.copy_root(1, nil).nil?)
check.call('copy_root before the entry is the register itself', written.copy_root(-1, '1').writer.nil?)
no_src = program.call([insn(0, 'LOADI_1', 'R1 (1)'), insn(2, 'RETNIL', '')])
check.call('copy_root past the end clamps', no_src.copy_root(99, '1').writer.op == 'LOADI_1')

jumps = program.call([
  insn(0, 'JMPNOT', "R1\t9"), insn(4, 'JMP', '9'), insn(6, 'JMPUW', '9'), insn(9, 'RETURN', 'R1')
])
check.call('branch_target_addrs covers every jump op', jumps.branch_target_addrs == Set[9])
dangling = program.call([insn(0, 'JMP', '77'), insn(4, 'RETURN', 'R1')])
check.call('branch_target_addrs keeps a target that is not an instruction', dangling.branch_target_addrs == Set[77])
check.call('dangling target leaves the graph unresolved', !dangling.resolved?)
check.call('branch_target_addrs of straight-line code is empty', p.branch_target_addrs.empty?)

# Catch-handler edges. Layout: 0 LOADNIL, 2 SEND (range [2,8) -> rescue at 12),
# 4 JMPNOT->8, 6 LOADI, 8 JMP->16 (range end, not covered), 12 EXCEPT (handler),
# 14 JMP->16, 16 RETURN.
guarded = Irep.new(label: 'h', instructions: [
  insn(0, 'LOADNIL', 'R1 (nil)'), insn(2, 'SEND', "R1\t:f\tn=0"), insn(4, 'JMPNOT', "R1\t8"),
  insn(6, 'LOADI_1', 'R2 (1)'), insn(8, 'JMP', '16'), insn(12, 'EXCEPT', 'R3'),
  insn(14, 'JMP', '16'), insn(16, 'RETURN', 'R1')
], catch_handlers: [CatchHandler.new(type: :rescue, begin_addr: 2, end_addr: 8, target: 12)])
g = BytecodeIR::Program.new(guarded)
check.call('handler edges cover [begin, end)', g.handler_edges.map { |e| [e.src, e.target, e.kind] } ==
  [[1, 5, :rescue], [2, 5, :rescue], [3, 5, :rescue]])
check.call('handlers resolved', g.handlers_resolved?)
check.call('normal predecessors omit the handler', g.instruction_predecessors[5] == Set[])
check.call('handler predecessors include the range', g.instruction_predecessors(include_handlers: true)[5] == Set[1, 2, 3])
check.call('handler predecessors keep normal edges', g.instruction_predecessors(include_handlers: true)[7] == Set[4, 6])
check.call('normal successors untouched by handlers', g.instruction_at(1).successors == [2] && g.successors_of(1) == [2])
check.call('successors_of with handlers', g.successors_of(1, include_handlers: true) == [2, 5])
check.call('handler_target_addrs', g.handler_target_addrs == Set[12])
check.call('handler_protected_addrs is half-open', g.handler_protected_addrs == Set[2, 3, 4, 5, 6, 7])
check.call('handler_protected_addrs inclusive end', g.handler_protected_addrs(inclusive_end: true) == Set[2, 3, 4, 5, 6, 7, 8])
check.call('handler is unreachable without handler edges', !g.reachable_from(0).include?(5))
check.call('handler is reachable with handler edges', g.reachable_from(0, include_handlers: true).include?(5))
check.call('reachable_from honours avoiding', !g.reachable_from(0, avoiding: 2).include?(7) && g.reachable_from(2, avoiding: 2).empty?)
check.call('SEND dominates the join only through the handler', g.dominates?(1, 7, include_handlers: true))
check.call('handler does not dominate the join', !g.dominates?(5, 7, include_handlers: true))
check.call('handler unreachable on normal flow so nothing dominates it', !g.dominates?(0, 5))
check.call('dominates itself', g.dominates?(4, 4))
check.call('JMPNOT does not dominate the join when the handler bypasses it',
           !g.dominates?(2, 7, include_handlers: true) && g.dominates?(2, 7))
check.call('every path from the guarded call reaches the RETURN', g.every_path_reaches?(1, 7, include_handlers: true))
check.call('not every path passes the LOADI', !g.every_path_reaches?(2, 3))
check.call('every path reaches itself', g.every_path_reaches?(3, 3))
early = Irep.new(label: 'e', instructions: [
  insn(0, 'JMPIF', "R1\t8"), insn(4, 'RETURN', 'R1'), insn(8, 'LOADNIL', 'R2 (nil)'), insn(10, 'RETURN', 'R2')
])
check.call('an early RETURN is an exit, so the join is not on every path',
           !BytecodeIR::Program.new(early).every_path_reaches?(0, 2))
ret_in_range = Irep.new(label: 'r', instructions: [
  insn(0, 'RETURN', 'R1'), insn(2, 'EXCEPT', 'R2'), insn(4, 'RETURN', 'R2')
], catch_handlers: [CatchHandler.new(type: :ensure, begin_addr: 0, end_addr: 2, target: 2)])
rp = BytecodeIR::Program.new(ret_in_range)
check.call('RETURN inside a range stays an exit with handlers', !rp.every_path_reaches?(0, 1, include_handlers: true))
bad_target = Irep.new(label: 'b', instructions: [insn(0, 'RETURN', 'R1')],
                      catch_handlers: [CatchHandler.new(type: :rescue, begin_addr: 0, end_addr: 2, target: 99)])
bp = BytecodeIR::Program.new(bad_target)
check.call('unresolved handler target', !bp.handlers_resolved? && bp.handler_edges.empty? &&
  bp.instruction_predecessors(include_handlers: true).nil? && !bp.instruction_predecessors.nil?)
check.call('handler_target_addrs keeps a non-instruction target', bp.handler_target_addrs == Set[99])
check.call('no handlers, no handler edges', program.call([insn(0, 'RETURN', 'R1')]).handler_edges.empty?)
nest = ->(b, e) { CatchHandler.new(type: :rescue, begin_addr: b, end_addr: e, target: 50) }
outer, inner, cross = nest.call(0, 20), nest.call(4, 10), nest.call(8, 30)
lay = ->(list) { BytecodeIR::Program.new(Irep.new(label: 'n', instructions: [], catch_handlers: list)) }
check.call('nested handlers do not partially overlap', !lay.call([outer, inner]).handler_partially_overlaps?(inner))
check.call('crossing handlers partially overlap', lay.call([outer, cross]).handler_partially_overlaps?(outer))

# IR type queries use the shared reaching definitions, including joins and loops.
types_for = ->(list, **fields) { BytecodeIR::Types.new(Irep.new(label: 'types', instructions: list, **fields)) }
joined = types_for.call([
  insn(0, 'JMPIF', "R1\t12"), insn(4, 'LOADI_1', 'R2 (1)'), insn(8, 'JMP', '16'),
  insn(12, 'LOADNIL', 'R2 (nil)'), insn(16, 'MOVE', "R3\tR2"), insn(20, 'RETURN', 'R3')
])
check.call('types union branches through MOVE', joined.at(5, '3') == Set[:Integer, :NilClass])
check.call('types are immutable', joined.at(5, '3').frozen?)
loop_types = types_for.call([
  insn(0, 'LOADI_1', 'R2 (1)'), insn(4, 'JMPIF', "R1\t16"), insn(8, 'LOADI_2', 'R2 (2)'),
  insn(12, 'JMP', '4'), insn(16, 'RETURN', 'R2')
])
check.call('types join loop definitions', loop_types.at(4, '2') == Set[:Integer])
check.call('types state cap refuses', loop_types.at(4, '2', max_states: 1).nil?)
unknown_types = types_for.call([
  insn(0, 'JMPIF', "R1\t12"), insn(4, 'LOADI_1', 'R2 (1)'), insn(8, 'JMP', '16'),
  insn(12, 'GETIV', "R2\t:x"), insn(16, 'RETURN', 'R2')
])
reason = {}
check.call('unknown branch poisons type union', unknown_types.at(4, '2', refusal: reason).nil? && reason[:cause] == 'unknown:GETIV')
check.call('entry types stay unknown', joined.at(0, '1').nil?)
check.call('unresolved types refuse', types_for.call([insn(0, 'JMP', '99'), insn(4, 'RETURN', 'R1')]).at(1, '1').nil?)
check.call('callee clobber refuses types', types_for.call([
  insn(0, 'LOADI_1', 'R3 (1)'), insn(4, 'SEND0', "R1\t:foo"), insn(8, 'RETURN', 'R3')
]).at(2, '3').nil?)
check.call('overloaded arithmetic result stays unknown', types_for.call([
  insn(0, 'LOADI_1', 'R2 (1)'), insn(4, 'ADDI', "R2\t1"), insn(8, 'RETURN', 'R2')
]).at(2, '2').nil?)
[
  ['LOADTRUE', 'R2 (true)', :TrueClass], ['LOADFALSE', 'R2 (false)', :FalseClass],
  ['LOADSYM', "R2\t:foo", :Symbol], ['STRING', "R2\tL[0]", :String],
  ['ARRAY', "R2\t0", :Array], ['HASH', "R2\t0", :Hash],
  ['RANGE_INC', 'R2', :Range], ['BLOCK', "R2\tI[0]", :Proc]
].each do |op, args, type|
  check.call("literal types #{op}", types_for.call([insn(0, op, args), insn(4, 'RETURN', 'R2')]).at(1, '2') == Set[type])
end
{ int32: :Integer, int64: :Integer, bigint: :Integer, float: :Float }.each do |kind, type|
  pool = [{ type: kind, raw: '' }]
  check.call("pool types #{kind}", types_for.call([
    insn(0, 'LOADL', "R2\tL[0]"), insn(4, 'RETURN', 'R2')
  ], pool: pool).at(1, '2') == Set[type])
end
check.call('LOADL string pool refuses', types_for.call([
  insn(0, 'LOADL', "R2\tL[0]"), insn(4, 'RETURN', 'R2')
], pool: ['foo']).at(1, '2').nil?)
check.call('missing pool types refuse', types_for.call([
  insn(0, 'LOADL', "R2\tL[0]"), insn(4, 'RETURN', 'R2')
]).at(1, '2').nil?)
enter_types = types_for.call([
  insn(0, 'ENTER', '1:0:1:0:0:1:0:0 (0x0)'), insn(4, 'RETURN', 'R1')
], nlocals: 6)
{ '1' => nil, '2' => Set[:Array], '3' => Set[:Hash], '4' => Set[:Proc, :NilClass], '5' => Set[:NilClass] }.each do |reg, expected|
  check.call("ENTER types R#{reg}", enter_types.at(1, reg) == expected)
end
handler_types = types_for.call([
  insn(0, 'LOADI_1', 'R2 (1)'), insn(4, 'RETURN', 'R2'), insn(8, 'RETURN', 'R2')
], catch_handlers: [CatchHandler.new(type: :rescue, begin_addr: 0, end_addr: 4, target: 8)])
check.call('protected types refuse', handler_types.at(1, '2').nil?)

mutated = Irep.new(label: 'mutated', nlocals: 4, reps: ['writer'], instructions: [
  insn(0, 'LOADI_1', 'R2 (1)'), insn(4, 'BLOCK', "R3\tI[0]"), insn(8, 'RETURN', 'R2')
])
writer = Irep.new(label: 'writer', instructions: [insn(0, 'SETUPVAR', "R1\t2\t0")])
mutated.tree = { 'mutated' => mutated, 'writer' => writer }
check.call('closure writes refuse types', BytecodeIR::Types.new(mutated).at(2, '2').nil?)
check.call('unreachable use refuses types', types_for.call([
  insn(0, 'RETURN', 'R1'), insn(4, 'LOADI_1', 'R2 (1)'), insn(8, 'RETURN', 'R2')
]).at(2, '2').nil?)
check.call('unknown call result refuses types', types_for.call([
  insn(0, 'SEND0', "R2\t:foo"), insn(4, 'RETURN', 'R2')
]).at(1, '2').nil?)

if ENV['MRBC']
  require 'tmpdir'
  Dir.mktmpdir('bc2cpp-ir-types-') do |dir|
    path = File.join(dir, 'types.rb')
    File.write(path, <<~'SOURCE')
      def ir_types(flag)
        value = flag ? 1.5 : 0x1_0000_0000
        value
      end
    SOURCE
    ireps, = compile_ireps(path, 'ir_types', dir)
    body = ireps.values.find { |irep| irep.enter }
    return_index = body.instructions.index { |instruction| instruction.op == 'RETURN' }
    check.call('decoded numeric pools union classes',
               BytecodeIR::Types.new(body).at(return_index, body.instructions[return_index].reg) == Set[:Float, :Integer])
  end
end

abort("bc2cpp_bytecode_ir_check FAILED: #{failures.join(', ')}") unless failures.empty?
puts 'bc2cpp_bytecode_ir_check OK'
