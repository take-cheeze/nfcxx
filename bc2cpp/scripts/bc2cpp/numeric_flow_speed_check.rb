#!/usr/bin/env ruby
# frozen_string_literal: true

# NUMERIC_FLOW_SPEED (docs/adr/0467): NumericFlow decodes an irep once (NumericFlow::Plan) and caches nothing an
# oracle answers. Host only, under a second:
#   - the plan is built once per irep and reused by every later run (the cache is hit);
#   - it holds bytecode facts only: a run under another oracle (an input that changed) gets that oracle's answers,
#     and every run asks every question again, in the same order;
#   - a plan whose irep no longer has the instruction list it decoded raises instead of answering;
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

puts '-- plan cache (host)'
first = LogOracle.new({ 1 => INT | NIL_, 3 => INT }, INT)
states = NF.states(irep, first, Set.new)
plan = irep.instance_variable_get(:@numeric_flow_plan)
check.call('the first run decodes the irep once', plan.is_a?(NF::Plan) && plan.supported)
check.call('the flow answers as before: an Integer counter at the loop head', states[1][2] == INT && states[6][2] == INT)
again = LogOracle.new({ 1 => INT | NIL_, 3 => INT }, INT)
states_again = NF.states(irep, again, Set.new)
check.call('a second run reuses the plan (cache hit)', irep.instance_variable_get(:@numeric_flow_plan).equal?(plan))
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
check.call('a shallow copy of the irep (same instructions) shares the plan',
           NF.states(clone, LogOracle.new({ 1 => INT | NIL_, 3 => INT }, INT), Set.new) == states)

stale = irep.dup
stale.instructions = loop_body.dup
raised = begin
  NF.states(stale, LogOracle.new({}, INT), Set.new)
  false
rescue RuntimeError => e
  e.message.include?('no longer matches')
end
check.call('a plan whose irep has another instruction list raises', raised)

puts '-- join_state (host)'
old = [INT, FLT, 0, 3]
check.call('no growth: the old state itself', NF.join_state(old, [INT, 0, 0, 3], 2).equal?(old))
check.call('an equal state: the old state itself', NF.join_state(old, old.dup, 2).equal?(old))
grown = NF.join_state(old, [FLT, FLT, 0, 3], 2)
check.call('growth: a new state, the old one untouched', grown == [INT | FLT, FLT, 0, 3] && old == [INT, FLT, 0, 3])
check.call('a provenance that disagrees is dropped', NF.join_state(old, [INT, FLT, 0, 4], 2) == [INT, FLT, 0, 0])
check.call('nothing joined yet: a copy of the edge', NF.join_state(nil, old, 2) == old && !NF.join_state(nil, old, 2).equal?(old))
check.call('a nil entry joins to false, as `nil | nil` does', NF.join_state([nil, 0], [nil, 0], 1) == [false, 0])

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
