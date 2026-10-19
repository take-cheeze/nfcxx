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

if failures.empty?
  puts 'bc2cpp numeric flow speed check: PASS'
else
  puts "bc2cpp numeric flow speed check: FAIL (#{failures.size})"
  exit 1
end
