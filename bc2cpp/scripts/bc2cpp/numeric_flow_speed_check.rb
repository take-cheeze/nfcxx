#!/usr/bin/env ruby
# frozen_string_literal: true

# NUMERIC_FLOW_SPEED (docs/adr/0467): NumericFlow reads an irep's bytecode facts from its BytecodeIR::Program and
# derives its Step table from them once (NumericFlow.table, kept in Program#numeric_flow_table); it caches nothing an
# oracle answers. Host only, under a second:
#   - the table is built once per Program and reused by every later run (the cache is hit), and there is no second
#     irep-level cache;
#   - the successor lists are the Program's own, with OP_ENTER's optional-argument table edges in them, and the
#     raise and rescue-only targets come from the Program's handler edges;
#   - it holds bytecode facts only: a run under another oracle (an input that changed) gets that oracle's answers,
#     and every run asks every question again, in the same order;
#   - a Program whose irep no longer has the instruction list it decoded raises instead of answering;
#   - join_state hands back the old state itself when nothing grows (the identity the worklist tests), and
#     reproduces `nil | nil` for a nil entry;
#   - the Hash ctx of #transfer and #raise_state still works.
#
# Usage: ruby scripts/bc2cpp/numeric_flow_speed_check.rb

require 'set'
require_relative '../../tools/bc2cpp/irep'
require_relative '../../tools/bc2cpp/bytecode_ir'
require_relative '../../tools/bc2cpp/numeric_flow'

failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

NF = NumericFlow
INT = NF::INT
FLT = NF::FLT
NIL_ = NF::NIL
OTHER = NF::OTHER

def insn(addr, op, args)
  Insn.new(lineno: 1, addr: addr, op: op, args: args, raw: "#{op} #{args}")
end

# Answers from a table, and logs every question but respond_to?.
class LogOracle
  attr_reader :log
  attr_accessor :entry, :send_result

  def initialize(entry, send_result)
    @entry = entry
    @send_result = send_result
    @log = []
  end

  def note(*question) = (@log << question)
  def entry_mask(_irep, reg) = note(:entry_mask, reg) && @entry.fetch(reg, OTHER)
  def const_mask(_insn) = note(:const_mask) && OTHER
  def ivar_slots(_irep) = note(:ivar_slots) && ['n']
  def ivar_entry_mask(_irep, name) = note(:ivar_entry_mask, name) && INT
  def ivar_fact_mask(_irep, name) = note(:ivar_fact_mask, name) && INT
  def send_mask(_irep, index, _insn, state) = note(:send_mask, index, state.dup) && @send_result
  def pool_mask(_irep, _insn) = note(:pool_mask) && FLT
  def op_native?(sym) = note(:op_native?, sym) && true
  def nil_raises?(sym) = note(:nil_raises?, sym) && true
end

# r2 = 0; while r1; r2 += r3; r4 = r2.f; end; return r2
loop_body = [insn(0, 'LOADI_0', "R2\t(0)"), insn(2, 'JMPNOT', "R1\t15"), insn(6, 'ADD', "R2\t(R3)"),
             insn(8, 'SEND0', "R4\t:f"), insn(11, 'GETIV', "R5\t@n"), insn(13, 'JMP', '2'), insn(15, 'RETURN', 'R2')]
irep = Irep.new(label: 'speed', nregs: 6, instructions: loop_body, catch_handlers: [], reps: [], pool: [])

puts '-- step table (host)'
first = LogOracle.new({ 1 => INT | NIL_, 3 => INT }, INT)
states = NF.states(irep, first, Set.new)
program = BytecodeIR.for(irep)
plan = program.numeric_flow_table
check.call('the first run derives the table once, on the Program', plan.is_a?(NF::Table) && plan.supported &&
           plan.steps.size == loop_body.size)
check.call('no second irep-level cache',
           irep.instance_variables.sort == (Irep.new.instance_variables + [:@bytecode_ir]).sort)
check.call('steps take op, branch kind and target from the BytecodeIR decode',
           plan.steps[1].op == 'JMPNOT' && plan.steps[1].branch == BytecodeIR::COND_NOT && plan.steps[1].goto == 6 &&
           program.decoded[1].goto == 6 && program.decoded[1].reg == 1 && program.decoded[5].goto == 1 &&
           program.decoded[2].cond.nil? && program.decoded[2].goto.nil?)
check.call('the flow answers as before: an Integer counter at the loop head', states[1][2] == INT && states[6][2] == INT)
again = LogOracle.new({ 1 => INT | NIL_, 3 => INT }, INT)
states_again = NF.states(irep, again, Set.new)
check.call('a second run reuses the table (cache hit)', BytecodeIR.for(irep).numeric_flow_table.equal?(plan))
check.call('and asks the oracle every question again, in the same order', again.log == first.log && !first.log.empty?)
check.call('equal answers give equal states', states_again == states)

changed = LogOracle.new({ 1 => INT | NIL_, 3 => FLT }, INT)
states_changed = NF.states(irep, changed, Set.new)
check.call('a changed entry answer reaches the result through the same plan', states_changed[1][2] == (INT | FLT))
changed_send = LogOracle.new({ 1 => INT | NIL_, 3 => INT }, FLT)
check.call('a changed send answer reaches the result', NF.states(irep, changed_send, Set.new)[5][4] == FLT)
check.call('an opaque register is an input too', NF.states(irep, LogOracle.new({ 1 => INT, 3 => INT }, INT), Set['2'])[1][2] == OTHER)
writes = {}
NF.states(irep, LogOracle.new({ 1 => INT | NIL_, 3 => INT }, INT), Set.new, writes)
check.call('writes collect every store', writes[2] == INT && writes[4] == INT && writes[5] == INT)

clone = irep.dup
clone.label = 'speed~spec'
check.call('a shallow copy of the irep (same instructions) shares the Program and its table',
           NF.states(clone, LogOracle.new({ 1 => INT | NIL_, 3 => INT }, INT), Set.new) == states)

stale = irep.dup
stale.instructions = loop_body.dup
raised = begin
  NF.states(stale, LogOracle.new({}, INT), Set.new)
  false
rescue RuntimeError => e
  e.message.include?('no longer matches')
end
check.call('a Program whose irep has another instruction list raises', raised)

puts '-- shared bytecode facts (host)'
# def f(a, b = 1, c = 2); r = 0; begin; r = a; rescue; r = 1; ensure; r = 2; end; r; end, flattened: ENTER with two
# optional arguments jumps into a three-entry JMP table; one rescue and one ensure handler share a range.
enter_body = [insn(0, 'ENTER', "1:2:0:0:0:0:0:0\t(0x0)"), insn(4, 'JMP', '13'), insn(7, 'JMP', '10'),
              insn(10, 'LOADI_1', "R2\t(1)"), insn(13, 'LOADI_2', "R3\t(2)"), insn(16, 'MOVE', "R4\tR1"),
              insn(19, 'EXCEPT', 'R5'), insn(21, 'LOADI_1', "R4\t(1)"), insn(23, 'RETURN', 'R4')]
handlers = [CatchHandler.new(type: :rescue, begin_addr: 16, end_addr: 19, target: 19),
            CatchHandler.new(type: :ensure, begin_addr: 16, end_addr: 19, target: 21)]
enter_irep = Irep.new(label: 'enter', nregs: 6, instructions: enter_body, catch_handlers: handlers, reps: [], pool: [])
ep = BytecodeIR.for(enter_irep)
check.call('ENTER reaches every optional-argument table entry', ep.successor_lists[0] == [1, 2, 3])
check.call('successor lists are the instructions\' own',
           ep.successor_lists.each_with_index.all? { |s, k| s.equal?(ep.instruction_at(k).successors) })
check.call('raise targets: per protected instruction, in handler order', ep.raise_targets == { 5 => [6, 7] })
check.call('rescue-only: a rescue target that no ensure shares', ep.rescue_only_targets == Set[6])
check.call('successors_of merges the raise targets', ep.successors_of(5, include_handlers: true) == [6, 7])
NF.states(enter_irep, LogOracle.new({ 1 => INT }, INT), Set.new)
check.call('the flow runs on the shared facts', ep.numeric_flow_table&.supported)

puts '-- join_state (host)'
old = [INT, FLT, 0, 3]
check.call('no growth: the old state itself', NF.join_state(old, [INT, 0, 0, 3], 2).equal?(old))
check.call('an equal state: the old state itself', NF.join_state(old, old.dup, 2).equal?(old))
grown = NF.join_state(old, [FLT, FLT, 0, 3], 2)
check.call('growth: a new state, the old one untouched', grown == [INT | FLT, FLT, 0, 3] && old == [INT, FLT, 0, 3])
check.call('a provenance that disagrees is dropped', NF.join_state(old, [INT, FLT, 0, 4], 2) == [INT, FLT, 0, 0])
check.call('nothing joined yet: a copy of the edge', NF.join_state(nil, old, 2) == old && !NF.join_state(nil, old, 2).equal?(old))
check.call('a nil entry joins to false, as `nil | nil` does', NF.join_state([nil, 0], [nil, 0], 1) == [false, 0])

# Distinct wide integers with equal values must not obscure another register's growth.
wide = (1 << 200) | INT
other_wide = wide.to_s.to_i
wide_old = [wide, INT, 2]
check.call('equal wide masks survive another mask growing',
           !wide.equal?(other_wide) && NF.join_state(wide_old, [other_wide, FLT, 2], 2) == [wide, INT | FLT, 2])
invalid_mask_raises = begin
  NF.join_state([INT, INT], [INT.to_f, FLT], 2)
  false
rescue TypeError
  true
end
check.call('an equal-valued Float still raises as an invalid mask', invalid_mask_raises)
random = Random.new(467)
join_matches = 2_000.times.all? do
  masks = Array.new(6) { random.rand(-1 << 240...1 << 240) }
  incoming = masks.map { |mask| random.rand(2).zero? ? mask.to_s.to_i : random.rand(-1 << 240...1 << 240) }
  previous = masks + [random.rand(4), random.rand(4)]
  incoming += [random.rand(4), random.rand(4)]
  expected = previous.each_with_index.map { |mask, reg| reg < 6 ? mask | incoming[reg] : mask == incoming[reg] ? mask : 0 }
  original = previous.dup
  NF.join_state(previous, incoming, 6) == expected && previous == original
end
check.call('wide and negative masks retain union and provenance behavior across 2,000 joins', join_matches)

puts '-- opaque registers (host)'
[Set.new, Set['0', '2', '02', '8', 1]].each do |opaque|
  context = NF::Ctx.new(nil, Object.new, opaque, 4, [], {}, [], 4, nil)
  check.call("opaque register membership matches canonical strings: #{opaque.to_a.inspect}",
             context.opq == Array.new(4) { |reg| opaque.include?(reg.to_s) } && context.opq.frozen?)
end

puts '-- Hash ctx (host)'
FakeCall = Struct.new(:op, :reg)
hash_oracle = Object.new
hash_oracle.define_singleton_method(:send_mask) { |*_args| NF::STR }
ctx = { oracle: hash_oracle, irep: nil, nregs: 4, slots: ['@value'], facts: [OTHER], slot_of: { '@value' => 4 },
        prov_base: 5, opaque: Set.new, writes: nil }
state = [OTHER, NF::STR, INT, OTHER, INT, 0, 0, 1, 0]
after = NF.transfer(0, FakeCall.new('SEND0', '1'), state, ctx)
check.call('transfer: the call result, the frame above it and the slot widened',
           after[1] == NF::STR && after[2] == OTHER && after[4] == (INT | OTHER) && after[5, 4].all?(&:zero?))
raised_state = NF.raise_state(FakeCall.new('SEND0', '1'), state, after, ctx)
check.call('raise_state joins the widened state with the result', raised_state[1] == (NF::STR | OTHER))

puts '-- unchanged load writes (host)'
load_context = lambda do |writes, opaque = Set.new|
  context = NF::Ctx.new(nil, Object.new, opaque, 4, ['n'], { 'n' => 4 }, [INT], 9, writes)
  context.elem_base = 5
  context.narrowing(13, [[[3].freeze, Object.new]].freeze, {}, false)
  context
end
clean_load = [OTHER, INT, OTHER, OTHER, INT] + Array.new(4, NF::ELEM_UNKNOWN) + Array.new(8, 0)
clean_load.freeze
load_writes = {}
unchanged = NF.copy_reg_write(clean_load, 1, INT, load_context.call(load_writes))
check.call('an unchanged load shares its frozen input and still records writes', unchanged.equal?(clean_load) && load_writes == { 1 => INT })
[[1, FLT], [10, 1], [6, INT], [14, 1], [11, 3], [15, 1]].each do |slot, value|
  input = clean_load.dup
  input[slot] = value
  input.freeze
  actual_writes = {}
  expected_writes = {}
  expected = input.dup
  NF.set_reg(expected, 1, INT, load_context.call(expected_writes))
  actual = NF.copy_reg_write(input, 1, INT, load_context.call(actual_writes))
  check.call("changed load metadata at #{slot} is copied and invalidated", !actual.equal?(input) && actual == expected && actual_writes == expected_writes)
end
opaque_input = clean_load.dup
opaque_input[1] = OTHER
opaque_input.freeze
check.call('captured registers use the effective OTHER mask before deciding to share',
           NF.copy_reg_write(opaque_input, 1, INT, load_context.call({}, Set['1'])).equal?(opaque_input))
manual_load = load_context.call({})
load_instruction = insn(0, 'LOADI_1', 'R1 (1)')
manual_result = NF.transfer(0, load_instruction, clean_load, manual_load)
check.call('standalone transfer contexts retain copied write results', !manual_result.equal?(clean_load) && manual_result == clean_load)
hash_load = { irep: nil, oracle: Object.new, opaque: Set.new, nregs: 4, slots: ['n'],
              slot_of: { 'n' => 4 }, facts: [INT], prov_base: 5, writes: {} }
hash_input = ([OTHER, INT, OTHER, OTHER, INT] + Array.new(4, 0)).freeze
hash_result = NF.transfer(0, load_instruction, hash_input, hash_load)
check.call('legacy Hash transfer contexts retain copied write results', !hash_result.equal?(hash_input) && hash_result == hash_input)
bottom_input = clean_load.dup
bottom_input[1] = 0
bottom_writes = {}
check.call('an unchanged bottom write still creates its write-union entry',
           NF.copy_reg_write(bottom_input.freeze, 1, 0, load_context.call(bottom_writes)).equal?(bottom_input) && bottom_writes == { 1 => 0 })
load_random = Random.new(536)
matches_loads = 1000.times.all? do
  input = clean_load.dup
  input[1] = [INT, FLT, OTHER, 1 << 250, -1].sample(random: load_random)
  4.times do |register|
    input[5 + register] = [INT, NF::ELEM_UNKNOWN].sample(random: load_random)
    input[9 + register] = load_random.rand(7)
    input[13 + register] = load_random.rand(2)
  end
  input.freeze
  expected_writes, actual_writes = {}, {}
  expected = input.dup
  NF.set_reg(expected, 1, INT, load_context.call(expected_writes))
  context = load_context.call(actual_writes)
  context.load_readers = { 1 => (0...4).select { |register| input[9 + register] == 3 }.freeze }.freeze
  actual = NF.copy_reg_write(input, 1, INT, context)
  actual == expected && actual_writes == expected_writes
end
check.call('1,000 randomized load states preserve masks, elements, provenance, tests and writes', matches_loads)

puts '-- shared incoming states (host)'
# Freeze every input and output at the solver boundary; even a transient in-place write would fail here.
module ReadonlyFlowInputs
  def step_transfer(index, insn, step, state, ctx)
    super(index, insn, step, state.freeze, ctx).freeze
  end

  def step_raise_state(step, before, after, ctx)
    super(step, before.freeze, after.freeze, ctx).freeze
  end

  def step_refine_edge(step, index, target, state, ctx)
    super(step, index, target, state.freeze, ctx)&.freeze
  end

  def join_state(old, incoming, prov_base, share_states = false)
    super(old&.freeze, incoming.freeze, prov_base, share_states).freeze
  end
end
NF.singleton_class.prepend(ReadonlyFlowInputs)

class ClassLogOracle < LogOracle
  Predicate = Struct.new(:mask) do
    def narrow(value, truth) = truth ? value & mask : value & ~mask
  end

  def class_narrowing_active? = true
  def class_test(_irep, _index, _insn, _state) = [0, Predicate.new(INT)]
  def const_lookup_quiet? = true
  def preserves_ivar_slots?(*_args) = true
end

class_body = [insn(0, 'GETIV', "R1\t@n"), insn(3, 'MOVE', "R2\tR1"), insn(6, 'SEND0', "R2\t:is_a?"),
              insn(9, 'JMPNOT', "R2\t17"), insn(13, 'GETIV', "R3\t@n"), insn(16, 'RETURN', 'R3'),
              insn(17, 'LOADNIL', 'R3 (nil)'), insn(19, 'RETURN', 'R3')]
class_irep = Irep.new(label: 'shared-class', nregs: 6, instructions: class_body, catch_handlers: [], reps: [], pool: [])
# Two targets receive exactly the same unrefined edge; rewriting either target must leave the other alone.
split_body = [insn(0, 'JMPNOT', "R1\t9"), insn(4, 'LOADI_1', "R2\t(1)"), insn(6, 'JMP', '12'),
              insn(9, 'LOADL', "R2\tL[0]"), insn(12, 'RETURN', 'R2')]
split_irep = Irep.new(label: 'shared-split', nregs: 6, instructions: split_body, catch_handlers: [], reps: [], pool: [])
handler_body = [insn(0, 'GETIV', "R1\t@n"), insn(3, 'SEND0', "R2\t:f"), insn(6, 'RETURN', 'R2'),
                insn(8, 'EXCEPT', 'R3'), insn(10, 'RAISEIF', 'R3'), insn(12, 'RETURN', 'R1')]
handler_irep = Irep.new(label: 'shared-handler', nregs: 6, instructions: handler_body,
                        catch_handlers: [CatchHandler.new(type: :rescue, begin_addr: 0, end_addr: 6, target: 8)],
                        reps: [], pool: [])
class_factory = lambda do
  oracle = ClassLogOracle.new({ 1 => INT | NIL_, 3 => INT }, OTHER)
  oracle.define_singleton_method(:ivar_entry_mask) { |_irep, name| note(:ivar_entry_mask, name) && (INT | NIL_) }
  oracle
end
element_body = [insn(0, 'SENDB', "R2\t:map\tn=0"), insn(4, 'MOVE', "R1\tR2"), insn(7, 'RETURN', 'R1')]
element_irep = Irep.new(label: 'shared-elements', nregs: 6, instructions: element_body, catch_handlers: [], reps: [], pool: [])
element_factory = lambda do
  oracle = LogOracle.new({}, INT)
  oracle.define_singleton_method(:block_send_mask) { |*_args| NF::ARR }
  oracle.define_singleton_method(:block_element_mask) { |*_args| INT }
  oracle
end
context_factory = lambda do
  oracle = LogOracle.new({ 1 => INT }, INT)
  oracle.define_singleton_method(:context_enter_edges) { { 0 => [3] }.freeze }
  oracle
end
loads_factory = lambda do
  oracle = LogOracle.new({}, INT)
  oracle.define_singleton_method(:loadself_mask) { note(:loadself_mask) && NF::ARR }
  oracle.define_singleton_method(:literal_class_mask) { |instruction| note(:literal_class_mask, instruction.op) && (1 << 200) }
  oracle
end
loads_body = Irep.new(label: 'repeated-loads', nregs: 4, catch_handlers: [], reps: [],
                     pool: ['text', { type: :float, value: '1.5' }], instructions: [
  insn(0, 'LOADI_1', 'R1 (1)'), insn(1, 'LOADI_1', 'R1 (1)'),
  insn(2, 'LOADSELF', 'R1 (R0)'), insn(3, 'LOADSELF', 'R1 (R0)'),
  insn(4, 'LOADL', 'R1 L[1]'), insn(5, 'LOADL', 'R1 L[1]'),
  insn(6, 'LOADSYM', 'R1 :value'), insn(7, 'LOADSYM', 'R1 :value'),
  insn(8, 'STRING', 'R1 L[0]'), insn(9, 'STRING', 'R1 L[0]'),
  insn(10, 'LOADNIL', 'R1 (nil)'), insn(11, 'LOADNIL', 'R1 (nil)'), insn(12, 'RETURN', 'R1')])
alias_loads = Irep.new(label: 'load-alias-invalidation', nregs: 4, catch_handlers: [], reps: [], pool: [], instructions: [
  insn(0, 'LOADI_1', 'R1 (1)'), insn(1, 'MOVE', 'R2 R1'), insn(2, 'MOVE', 'R2 R1'),
  insn(3, 'LOADI_1', 'R1 (1)'), insn(4, 'RETURN', 'R2')])
alias_plan = NF.table(BytecodeIR.for(alias_loads))
check.call('the immutable load-reader index records MOVE destinations without duplicates',
           alias_plan.load_readers == { 1 => [2] } && alias_plan.load_readers.frozen? && alias_plan.load_readers[1].frozen?)
cases = [
  ['repeated loads and oracle order', loads_body, Set.new, loads_factory],
  ['same-class rewrite invalidates register aliases', alias_loads, Set.new, loads_factory],
  ['loop and ivar provenance', irep, Set.new, -> { LogOracle.new({ 1 => INT | NIL_, 3 => FLT }, INT) }],
  ['captured registers', irep, Set['1', '2'], -> { LogOracle.new({ 1 => INT | NIL_, 3 => INT }, FLT) }],
  ['optional entry, rescue and ensure', enter_irep, Set.new, -> { LogOracle.new({ 1 => INT }, INT) }],
  ['sibling branch isolation', split_irep, Set.new, -> { LogOracle.new({}, INT) }],
  ['raising call, slots and EXCEPT/RAISEIF', handler_irep, Set.new, -> { LogOracle.new({}, FLT) }],
  ['class-test slot narrowing', class_irep, Set.new, class_factory],
  ['element block on block calls', element_irep, Set.new, element_factory],
  ['context-specific ENTER edges', enter_irep, Set.new, context_factory]
]
cases.each do |name, body, opaque, factory|
  shared_oracle = factory.call
  copied_oracle = factory.call
  shared_writes = {}
  copied_writes = {}
  previous_elision = ENV['BC2CPP_NUMERIC_LOAD_COPY_ELISION']
  begin
    ENV['BC2CPP_NUMERIC_LOAD_COPY_ELISION'] = '1'
    shared = NF.states(body, shared_oracle, opaque, shared_writes, share_states: true)
    ENV['BC2CPP_NUMERIC_LOAD_COPY_ELISION'] = '0'
    copied = NF.states(body, copied_oracle, opaque, copied_writes, share_states: false)
  ensure
    previous_elision ? ENV['BC2CPP_NUMERIC_LOAD_COPY_ELISION'] = previous_elision : ENV.delete('BC2CPP_NUMERIC_LOAD_COPY_ELISION')
  end
  check.call("#{name}: frozen-state results, writes and oracle order match copied edges",
             shared && shared == copied && shared_writes == copied_writes && shared_oracle.log == copied_oracle.log)
  if body.equal?(class_irep)
    check.call('the class-test fixture narrows the shared slot on its truthy edge', shared[4][6] == INT)
  elsif body.equal?(element_irep)
    check.call('the block-call fixture carries its element mask to the successor', shared[1][9] == INT)
  end
end
noop_body = Irep.new(label: 'shared-noop', nregs: 2, instructions: [insn(0, 'NOP', ''), insn(1, 'RETURN', 'R1')],
                     catch_handlers: [], reps: [], pool: [])
shared_noop = NF.states(noop_body, LogOracle.new({}, INT), Set.new, share_states: true)
copied_noop = NF.states(noop_body, LogOracle.new({}, INT), Set.new, share_states: false)
check.call('a read-only edge shares its first state only in sharing mode',
           shared_noop[0].equal?(shared_noop[1]) && !copied_noop[0].equal?(copied_noop[1]))
previous_sharing = ENV['BC2CPP_NUMERIC_SHARE_STATES']
begin
  ENV['BC2CPP_NUMERIC_SHARE_STATES'] = '0'
  withdrawn = NF.states(noop_body, LogOracle.new({}, INT), Set.new)
  check.call('the opt-out restores separate first-edge copies', !withdrawn[0].equal?(withdrawn[1]))
ensure
  previous_sharing ? ENV['BC2CPP_NUMERIC_SHARE_STATES'] = previous_sharing : ENV.delete('BC2CPP_NUMERIC_SHARE_STATES')
end
shared_edge = [INT, FLT, 0, 3].freeze
check.call('explicit first-edge sharing retains the incoming state', NF.join_state(nil, shared_edge, 2, true).equal?(shared_edge))
check.call('subsequent growth copies the shared edge without modifying it',
           NF.join_state(shared_edge, [FLT, FLT, 0, 4], 2, true) == [INT | FLT, FLT, 0, 0] &&
           shared_edge == [INT, FLT, 0, 3])

if failures.empty?
  puts 'bc2cpp numeric flow speed check: PASS'
else
  puts "bc2cpp numeric flow speed check: FAIL (#{failures.size})"
  exit 1
end
