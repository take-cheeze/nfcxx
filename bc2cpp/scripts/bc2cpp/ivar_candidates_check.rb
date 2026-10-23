#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative 'type_check_fixture'

ROOT = File.expand_path('../..', __dir__)
TOOLS = ENV['BC2CPP_TOOLS_DIR'] || File.join(ROOT, 'tools/bc2cpp')
$LOAD_PATH.unshift(TOOLS)
require 'ivar_candidates'
require 'irep'
require 'bytecode_ir'

failures = []
check = lambda do |label, condition|
  puts "#{condition ? 'ok' : 'FAIL'} #{label}"
  failures << label unless condition
end

# Stand-ins for the settled compiler and the ctx fields the index reads. Each store and read is a plain instruction
# in an irep labelled by its method; `found` is what ClassLayout's store_log would hold for a traced store.
# The stubs answer what BytecodeIR::Program needs to build: they hold no branch, so no address resolves one.
StubInsn = Struct.new(:op, :ivar, :regs, :sym) do
  def addr = nil
  def branch_target = nil
end
StubIrep = Struct.new(:insns, :nlocals, :catch_handlers) do
  def instructions = insns

  def each_with_op(*ops)
    insns.each_with_index { |insn, idx| yield insn, idx if ops.include?(insn.op) }
  end
end
Definer = Struct.new(:owner, :irep)

class FakeGen
  attr_reader :family, :owner_of
  attr_accessor :assured

  def initialize(family: {}, owner_of: {}, assured: {})
    @family = family
    @owner_of = owner_of
    @assured = assured
  end

  def numeric_irep_owner = @owner_of
  def numeric_family(owner) = @family.fetch(owner, owner)
  def numeric_ivar_assured?(owner, name) = @assured.fetch([owner, name], false)
end

# A labelled method: { label => [owner, [insn, ...], found] }. `found` maps the index of each SETIV ClassLayout
# logged to what it traced (nil when unresolved). A nil store (LOADNIL then SETIV) is never logged, as in ClassLayout.
def scene(methods)
  ireps = {}
  owners = {}
  store_log = {}
  methods.each do |label, (owner, insns, found)|
    ireps[label] = StubIrep.new(insns)
    owners[label] = Definer.new(owner, label) if owner
    (found || {}).each { |idx, cls| store_log[[owner, label, idx]] = [:x, cls, nil, nil, 0, nil] }
  end
  [ireps, owners, store_log]
end

# The stub for nil_literal_write?: a SETIV fed directly by LOADNIL is a nil store.
NIL_WRITE = ->(irep, idx, _reg) { idx.positive? && irep.insns[idx - 1].op == 'LOADNIL' }

# The stubbed ireps carry no BytecodeIR, so the store-first oracle answers nil (every read counts) here. The cases
# that exercise the real per-path dataflow are in real_candidate below.
NO_PROOF = ->(_irep, _name) { nil }

def candidate(methods, gen, owner, name)
  ireps, owners, store_log = scene(methods)
  ctx = Struct.new(:ireps, :store_log).new(ireps, store_log)
  gen.owner_of.merge!(owners)
  index = IvarCandidates.index(ctx, gen, nil_write: NIL_WRITE, unstored_reads: NO_PROOF)
  IvarCandidates.type(index, gen, owner, name)
end

# Real Irep and Insn objects, so BytecodeIR::Program answers which reads are store-first. A method is
# { label => [owner, [insn, ...], found, catch_handlers, definer_label] }; definer_label is the method whose body
# the irep belongs to (its own label unless the irep is a block of that method).
# The index over real instructions (see real_candidate). Its nil answers come from the same per-path analysis.
def real_index(methods, gen)
  ireps = {}
  owners = {}
  store_log = {}
  methods.each do |label, (klass, insns, found, handlers, definer_label)|
    ireps[label] = Irep.new(label: label, instructions: insns, catch_handlers: handlers || [])
    owners[label] = Definer.new(klass, definer_label || label)
    (found || {}).each { |idx, cls| store_log[[klass, label, idx]] = [:x, cls, nil, nil, 0, nil] }
  end
  ctx = Struct.new(:ireps, :store_log).new(ireps, store_log)
  gen.owner_of.merge!(owners)
  real_nil_write = ->(irep, idx, _reg) { idx.positive? && irep.instructions[idx - 1].op == 'LOADNIL' }
  IvarCandidates.index(ctx, gen, nil_write: real_nil_write)
end

def real_candidate(methods, gen, owner, name)
  IvarCandidates.type(real_index(methods, gen), gen, owner, name)
end

set = lambda { |reg| StubInsn.new('SETIV', :x, [reg]) }
get = StubInsn.new('GETIV', :x, ['1'])
load_nil = StubInsn.new('LOADNIL', nil, ['2'])

# The reported case: #set stores, #get reads, and nothing assures that #get runs after a store.
gen = FakeGen.new
methods = {
  1 => ['Foo', [set.call('1')], { 0 => 'Bar' }],
  2 => ['Foo', [get], nil]
}
check.call('read in a method with no assurance adds nil to the single store', candidate(methods, gen, 'Foo', 'x') == 'Bar | nil')

gen = FakeGen.new(assured: { ['Foo', 'x'] => true })
check.call('assured readers keep the single store type without nil',
           candidate(methods, gen, 'Foo', 'x') == 'Bar')

gen = FakeGen.new(assured: { ['Foo', 'x'] => true })
nil_methods = { 1 => ['Foo', [load_nil, set.call('2')], { 1 => 'Bar' }],
                2 => ['Foo', [load_nil, set.call('2')], nil] }
check.call('a nil store adds nil even when every reader is assured',
           candidate(nil_methods, gen, 'Foo', 'x') == 'Bar | nil')

# Stores in a superclass and subclass share one slot: the candidate joins them, not the reader's own owner.
gen = FakeGen.new(family: { 'Sub' => 'Base', 'Base' => 'Base' }, assured: { ['Base', 'x'] => true })
family_methods = {
  1 => ['Base', [set.call('1')], { 0 => 'Integer' }],
  2 => ['Sub', [set.call('1')], { 0 => 'String' }],
  3 => ['Base', [get], nil]
}
check.call('stores in every family member join into the candidate',
           candidate(family_methods, gen, 'Base', 'x') == 'Integer | String')
check.call('the subclass row shares the family candidate',
           candidate(family_methods, gen, 'Sub', 'x') == 'Integer | String')

# An unresolved store (ClassLayout logged no class) cannot be joined: no candidate.
gen = FakeGen.new(assured: { ['Foo', 'x'] => true })
unresolved = { 1 => ['Foo', [set.call('1')], { 0 => nil }], 2 => ['Foo', [get], nil] }
check.call('an unresolved store leaves the candidate unknown',
           candidate(unresolved, gen, 'Foo', 'x') == ClassLayout::UNKNOWN)

# A store in a block is its own irep. ClassLayout never logs it, so it cannot be joined.
gen = FakeGen.new(assured: { ['Foo', 'x'] => true })
block_store = { 1 => ['Foo', [set.call('1')], { 0 => 'Bar' }], 2 => [nil, [set.call('1')], nil] }
check.call('a store in a block with no owner makes the ivar opaque',
           candidate(block_store, gen, 'Foo', 'x') == ClassLayout::UNKNOWN)

# No traced store at all: nothing to say, so the caller falls through to the other sources.
gen = FakeGen.new
check.call('an ivar with no traced store has no class-layout candidate',
           candidate({ 2 => ['Foo', [get], nil] }, gen, 'Foo', 'x').nil?)

# Per-path read-before-store on real instructions. Each read is in a method nothing assures, so nil is added exactly
# when some read of @x may run before any store in its own method.
def insn(addr, op, args) = Insn.new(lineno: 1, addr: addr, op: op, args: args, raw: "#{op} #{args}")

gen = FakeGen.new
store_first = { 1 => ['Foo', [insn(0, 'LOADI_1', "R2\t(1)"), insn(2, 'SETIV', "@x\tR2"), insn(4, 'GETIV', "R3\t@x"),
                              insn(6, 'RETURN', 'R3')], { 1 => 'Bar' }] }
check.call('a method that stores before reading adds no nil',
           real_candidate(store_first, gen, 'Foo', 'x') == 'Bar')

gen = FakeGen.new
read_first = { 1 => ['Foo', [insn(0, 'GETIV', "R3\t@x"), insn(2, 'LOADI_1', "R2\t(1)"), insn(4, 'SETIV', "@x\tR2"),
                             insn(6, 'RETURN', 'R3')], { 2 => 'Bar' }] }
check.call('a method that reads before storing adds nil',
           real_candidate(read_first, gen, 'Foo', 'x') == 'Bar | nil')

gen = FakeGen.new
# JMPNOT at 0 skips the store at 4 and reaches the read at 8 unstored.
conditional = { 1 => ['Foo', [insn(0, 'JMPNOT', "R1\t8"), insn(4, 'SETIV', "@x\tR2"), insn(8, 'GETIV', "R3\t@x"),
                              insn(12, 'RETURN', 'R3')], { 1 => 'Bar' }] }
check.call('a read after a conditional store adds nil',
           real_candidate(conditional, gen, 'Foo', 'x') == 'Bar | nil')

gen = FakeGen.new
# #reader calls #setter, which may store: the call does not prove the store, so the read keeps nil.
self_call = {
  1 => ['Foo', [insn(0, 'SEND0', "R2\t:set_x"), insn(4, 'GETIV', "R3\t@x"), insn(6, 'RETURN', 'R3')], nil],
  2 => ['Foo', [insn(0, 'LOADI_1', "R2\t(1)"), insn(2, 'SETIV', "@x\tR2"), insn(4, 'RETURN', 'R2')], { 1 => 'Bar' }]
}
check.call('a read after a self-call that may store adds nil',
           real_candidate(self_call, gen, 'Foo', 'x') == 'Bar | nil')

gen = FakeGen.new
# The rescue edge leaves the state before the SETIV at 2 (it may raise before storing): the handler's read is unstored.
handler = { 1 => ['Foo', [insn(0, 'LOADI_1', "R2\t(1)"), insn(2, 'SETIV', "@x\tR2"), insn(4, 'RETURN', 'R2'),
                          insn(6, 'GETIV', "R3\t@x"), insn(8, 'RETURN', 'R3')], { 1 => 'Bar' }, [
                            CatchHandler.new(type: :rescue, begin_addr: 2, end_addr: 4, target: 6)
                          ]] }
check.call('a read in a rescue handler of the store adds nil', real_candidate(handler, gen, 'Foo', 'x') == 'Bar | nil')

gen = FakeGen.new
# A block's own store does not prove a read in that block: its frame can be entered before the method stores.
block_read = {
  1 => ['Foo', [insn(0, 'RETNIL', '')], nil],
  2 => ['Foo', [insn(0, 'LOADI_1', "R2\t(1)"), insn(2, 'SETIV', "@x\tR2"), insn(4, 'GETIV', "R3\t@x"),
                insn(6, 'RETURN', 'R3')], { 1 => 'Bar' }, nil, 1]
}
check.call('a read in a block of the method keeps nil after its own store',
           real_candidate(block_read, gen, 'Foo', 'x') == 'Bar | nil')

gen = FakeGen.new
# remove_instance_variable anywhere can clear the slot between the store and the read, so no read is store-first.
reflective = { 1 => ['Foo', [insn(0, 'LOADI_1', "R2\t(1)"), insn(2, 'SETIV', "@x\tR2"),
                             insn(4, 'SEND', "R2\t:remove_instance_variable\tn=1"), insn(8, 'GETIV', "R3\t@x"),
                             insn(10, 'RETURN', 'R3')], { 1 => 'Bar' }] }
check.call('a reflective ivar removal voids the store-first proof',
           real_candidate(reflective, gen, 'Foo', 'x') == 'Bar | nil')

# Reflection the GETIV scan cannot see. Method 1 is store-first; method 2 is the reflective access under test.
store_then_read = [insn(0, 'LOADI_1', "R2\t(1)"), insn(2, 'SETIV', "@x\tR2"), insn(4, 'GETIV', "R3\t@x"),
                   insn(6, 'RETURN', 'R3')]
store_program = ->(extra) { { 1 => ['Foo', store_then_read, { 1 => 'Bar' }], 2 => ['Foo', extra, nil] } }

gen = FakeGen.new
literal_send = [insn(0, 'LOADSYM', "R2\t:greet"), insn(2, 'SEND', "R1\t:send\tn=1"), insn(4, 'RETURN', 'R1')]
check.call('a literal read in a store-first method drops nil beside a literal non-reflective send',
           real_candidate(store_program.call(literal_send), gen, 'Foo', 'x') == 'Bar')

gen = FakeGen.new
computed_send = [insn(0, 'SEND', "R1\t:send\tn=1"), insn(2, 'RETURN', 'R1')]
check.call('a computed-name send keeps nil on the store-first read',
           real_candidate(store_program.call(computed_send), gen, 'Foo', 'x') == 'Bar | nil')

{
  'an instance_variable_get of a computed name' => [insn(0, 'SEND', "R1\t:instance_variable_get\tn=1")],
  'an instance_variable_get of a literal name' => [insn(0, 'LOADSYM', "R2\t:@x"),
                                                    insn(2, 'SEND', "R1\t:instance_variable_get\tn=1")],
  'send(:instance_variable_get, ...)' => [insn(0, 'LOADSYM', "R2\t:instance_variable_get"),
                                          insn(2, 'SEND', "R1\t:send\tn=1")],
  'a Symbol naming a reflective method (&:instance_variable_get)' => [insn(0, 'LOADSYM', "R2\t:instance_variable_get")],
  'a computed method name for method(name)' => [insn(0, 'SEND', "R1\t:method\tn=1")],
  'a literal attr_reader' => [insn(0, 'LOADSYM', "R2\t:x"), insn(2, 'SEND', "R1\t:attr_reader\tn=1")],
  'a string eval' => [insn(0, 'SEND', "R1\t:eval\tn=1")]
}.each do |label, extra|
  gen = FakeGen.new
  check.call("#{label} keeps nil on the store-first read",
             real_candidate(store_program.call(extra), gen, 'Foo', 'x') == 'Bar | nil')
end

# The embedded layout (IvarLayout) types a slot by every store, so the nil a read before the first store sees is added
# by with_nil on top of that type. These use the same per-path reads as the class-layout candidates above.
gen = FakeGen.new
check.call('an embedded type read before its first store adds nil',
           IvarCandidates.with_nil(real_index(read_first, gen), gen, 'Foo', 'x', 'Integer') == 'Integer | nil')
gen = FakeGen.new
check.call('an embedded type stored before every read keeps its type',
           IvarCandidates.with_nil(real_index(store_first, gen), gen, 'Foo', 'x', 'Integer') == 'Integer')
gen = FakeGen.new
check.call('an embedded bool read after a conditional store adds nil',
           IvarCandidates.with_nil(real_index(conditional, gen), gen, 'Foo', 'x', 'bool') == 'bool | nil')
gen = FakeGen.new
check.call('an embedded type that already admits nil is not widened again',
           IvarCandidates.with_nil(real_index(read_first, gen), gen, 'Foo', 'x', 'Integer?') == 'Integer?')
gen = FakeGen.new(assured: { ['Foo', 'x'] => true })
check.call('an embedded type read only in an assured owner keeps its type',
           IvarCandidates.with_nil(real_index(read_first, gen), gen, 'Foo', 'x', 'Integer') == 'Integer')

if ENV['MRBC']
  source = <<~RUBY
    class CandidateField
      def set_bar
        @held = Bar.new
      end
      def read_held
        @held
      end
    end
    class Bar; end
    CandidateField.new.set_bar
    CandidateField.new.read_held
  RUBY
  Dir.mktmpdir('ivar-candidates-check') do |dir|
    File.write(File.join(dir, 'fixture.rb'), source)
    Dir.mkdir(File.join(dir, 'sig'))
    report = TypeCheckFixture.report(dir, files: ['fixture.rb'], env: { 'BC2CPP_TOOLS_DIR' => TOOLS },
                                     options: ['--sig', File.join(dir, 'sig')], label: 'ivar candidate')
    row = report['ivars'].find { |r| r['owner'] == 'CandidateField' && r['name'] == '@held' }
    check.call('mrbc: read before any store in another method adds nil to the candidate',
               row && row['type'].to_s.split(' | ').include?('nil'))
  end
else
  puts 'SKIP mrbc candidate fixture (set MRBC; not run in this environment)'
end

abort "#{failures.length} ivar candidate checks failed" unless failures.empty?
puts 'ivar candidates: all checks passed'
