#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative 'type_check_fixture'

ROOT = File.expand_path('../..', __dir__)
TOOLS = ENV['BC2CPP_TOOLS_DIR'] || File.join(ROOT, 'tools/bc2cpp')
$LOAD_PATH.unshift(TOOLS)
require 'ivar_candidates'

failures = []
check = lambda do |label, condition|
  puts "#{condition ? 'ok' : 'FAIL'} #{label}"
  failures << label unless condition
end

# Stand-ins for the settled compiler and the ctx fields the index reads. Each store and read is a plain instruction
# in an irep labelled by its method; `found` is what ClassLayout's store_log would hold for a traced store.
Insn = Struct.new(:op, :ivar, :regs)
Irep = Struct.new(:insns) do
  def each_with_op(*ops)
    insns.each_with_index { |insn, idx| yield insn, idx if ops.include?(insn.op) }
  end
end
Definer = Struct.new(:owner)

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
    ireps[label] = Irep.new(insns)
    owners[label] = Definer.new(owner) if owner
    (found || {}).each { |idx, cls| store_log[[owner, label, idx]] = [:x, cls, nil, nil, 0, nil] }
  end
  [ireps, owners, store_log]
end

# The stub for nil_literal_write?: a SETIV fed directly by LOADNIL is a nil store.
NIL_WRITE = ->(irep, idx, _reg) { idx.positive? && irep.insns[idx - 1].op == 'LOADNIL' }

def candidate(methods, gen, owner, name)
  ireps, owners, store_log = scene(methods)
  ctx = Struct.new(:ireps, :store_log).new(ireps, store_log)
  gen.owner_of.merge!(owners)
  index = IvarCandidates.index(ctx, gen, nil_write: NIL_WRITE)
  IvarCandidates.type(index, gen, owner, name)
end

set = lambda { |reg| Insn.new('SETIV', :x, [reg]) }
get = Insn.new('GETIV', :x, ['1'])
load_nil = Insn.new('LOADNIL', nil, ['2'])

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
