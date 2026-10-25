#!/usr/bin/env ruby
# frozen_string_literal: true

# STRUCT_RECEIVER (tools/bc2cpp/registry.rb): the Struct.new receiver and the singleton receiver of `def obj.m` /
# `class << obj` are read from BytecodeIR.reaching_definitions (MOVEs followed), so every definition that reaches
# the send must be the same constant. The old linear read saw only the textually nearest writer: a local holding
# Struct (`k = Struct; k.new`) is a MOVE there, so its members and block defs were missed; a join
# `(c ? Hash : Struct).new` took the Struct branch that happens to come last, which is not the receiver on every path.
# Struct recognition refuses when the IR cannot prove the receiver or member names.
#
# 1. The registrations the shapes must produce (MRBC): the compiled snippet's registry and struct members.
#
# Usage: MRBC=path/to/mrbc ruby scripts/bc2cpp/struct_receiver_check.rb

require_relative 'check_support'

suite = FixtureCheck.new('struct_receiver_check')
suite.require_mrbc!
# The fixtures declare no RBS; the repository's signatures name engine classes these fixtures lack.
ENV['BC2CPP_SIG_DIRS'] = ''
require_relative '../../tools/bc2cpp/bc2cpp'
check = suite.method(:check)

SNIPPET = <<~RUBY
  class Host; end
  k = Struct
  Pt = k.new(:x) do
    def ext; end
  end
  Pt5 = k.new(:z)
  o = Host
  def o.zap; 1; end
  c = true
  Pt3 = (c ? Hash : Struct).new(:x) do
    def amb; end
  end
  Pt0 = Struct.new(:y) do
    def base; end
  end
  Pt7 = (c ? Struct : Struct).new(:w) do
    def both; end
  end
RUBY

# [registry, struct member lists] of the snippet, compiled by mrbc.
registry, members = suite.compile(SNIPPET) do |ireps, root|
  result = build_registry(ireps, root)
  [result[0], result[6]]
end
owner_of = ->(name) { registry.fetch(name, []).map(&:owner) }

puts '-- STRUCT_RECEIVER (registry)'
check.call('a Struct held in a local (MOVE receiver) is recognized: its members are registered',
           members['Pt'] == ['x'])
check.call('a Struct held in a local: its block defs register under the Struct owner', owner_of.call('ext') == ['Pt'])
check.call('a block-less `k.new(:z)` through a local Struct registers its members', members['Pt5'] == ['z'])
check.call('a singleton `def o.zap` with o = Host (MOVE receiver) registers under Host.singleton',
           owner_of.call('zap') == ['Host.singleton'])
check.call('a join `(c ? Hash : Struct).new` is not a Struct on every path: no member list',
           members['Pt3'].nil?)
check.call('a join `(c ? Hash : Struct).new`: its block defs are not registered under that owner',
           owner_of.call('amb').empty?)
check.call('a direct `Struct.new` with a block is still recognized (baseline)', members['Pt0'] == ['y'])
check.call('the direct Struct.new block defs still register under their owner', owner_of.call('base') == ['Pt0'])
check.call('a join where Struct is the receiver on every arm is still recognized (never less)',
           members['Pt7'] == ['w'] && owner_of.call('both') == ['Pt7'])

puts '-- STRUCT_MEMBERS ordered register flow'
member_source = <<~RUBY
  class FlowImplicitHost
    Struct
    Record = new(:flow_implicit)
  end
  flag = true
  first = :flow_first
  second = :flow_second
  FlowPlain = Struct.new(second, first, keyword_init: true)
  FlowBlock = Struct.new(second, first, keyword_init: true) do
    def flow_body; end
  end
  same = flag ? :flow_same : :flow_same
  FlowSame = Struct.new(same)
  FlowAlternate = flag ? Struct.new(:flow_alt_left) : Struct.new(:flow_alt_right)
  FlowOverride = Struct.new(:flow_override) do
    def flow_override; :custom; end
  end
  joined = flag ? :flow_left : :flow_right
  FlowJoined = Struct.new(joined) do
    def joined_body; end
  end
  name = :flow_old
  name = :flow_new
  decoy = :flow_decoy
  FlowOverwrite = Struct.new(name)
  FlowUnknown = Struct.new(:flow_partial, unknown_member)
  names = [:flow_packed_old]
  names[0] = :flow_packed_new
  FlowMutated = Struct.new(*names)
  begin
    rescued = :flow_before
    unknown_call
  rescue
    rescued = :flow_after
  end
  FlowRescued = Struct.new(rescued)
  factory = Struct
  changer = -> { factory = Hash }
  changer.call
  FlowCaptured = factory.new(:flow_captured) do
    def captured_body; end
  end
RUBY
member_source += "FlowPacked = Struct.new(#{16.times.map { |i| ":flow_pack_#{i}" }.join(', ')}, keyword_init: true)\n"
member_source += "FlowPackedBlock = Struct.new(#{16.times.map { |i| ":flow_pack_block_#{i}" }.join(', ')}, keyword_init: true) do\n def packed_body; end\nend\n"
registry, members = suite.compile(member_source) do |ireps, root|
  result = build_registry(ireps, root)
  [result[0], result[6]]
end
has_owner = ->(name, owner) { registry.fetch(name, []).any? { |definition| definition.owner == owner } }
%w[FlowPlain FlowBlock].each do |owner|
  check.call("#{owner} preserves ordered moved positional symbols with keyword_init", members[owner] == %w[flow_second flow_first])
  %w[flow_first flow_second].each do |name|
    check.call("#{owner} registers both native accessors for #{name}", has_owner.call(name, owner) && has_owner.call("#{name}=", owner))
  end
end
check.call('block methods retain their Struct owner', has_owner.call('flow_body', 'FlowBlock'))
check.call('implicit new after reading Struct does not invent a Struct layout', !members.key?('FlowImplicitHost::Record') && !has_owner.call('flow_implicit', 'FlowImplicitHost::Record'))
check.call('equal Symbol branch arms preserve one positional layout', members['FlowSame'] == ['flow_same'])
check.call('an alternate entry to SETCONST cannot name one branch layout', !members.key?('FlowAlternate') &&
           !has_owner.call('flow_alt_right', 'FlowAlternate'))
check.call('a block override retains both the native candidate and its real Ruby body',
           members['FlowOverride'] == ['flow_override'] && registry.fetch('flow_override').count { |definition| definition.owner == 'FlowOverride' && definition.irep } == 1 &&
           registry.fetch('flow_override').count { |definition| definition.owner == 'FlowOverride' && !definition.irep } == 1)
check.call('different Symbol branch arms refuse a fixed layout', !members.key?('FlowJoined'))
%w[flow_left flow_right].each do |name|
  check.call("different Symbol arms conservatively register #{name} accessors", has_owner.call(name, 'FlowJoined') && has_owner.call("#{name}=", 'FlowJoined'))
end
check.call('a block with no fixed layout retains its body definitions', has_owner.call('joined_body', 'FlowJoined'))
check.call('overwrite and unrelated symbol loads use the actual argument', members['FlowOverwrite'] == ['flow_new'] &&
           has_owner.call('flow_new', 'FlowOverwrite') && !has_owner.call('flow_old', 'FlowOverwrite') && !has_owner.call('flow_decoy', 'FlowOverwrite'))
check.call('unknown members publish no layout or partial accessor list', !members.key?('FlowUnknown') && !has_owner.call('flow_partial', 'FlowUnknown'))
check.call('mutated splat arrays publish no guessed layout or accessors', !members.key?('FlowMutated') && !has_owner.call('flow_packed_old', 'FlowMutated'))
check.call('handler paths with differing member names refuse positional layout', !members.key?('FlowRescued'))
check.call('an unproved handler merge publishes no partial native accessor list',
           %w[flow_before flow_after].none? { |name| has_owner.call(name, 'FlowRescued') || has_owner.call("#{name}=", 'FlowRescued') })
check.call('captured receiver writes refuse Struct ownership without nearest-writer fallback', !members.key?('FlowCaptured') && !has_owner.call('captured_body', 'FlowCaptured'))
%w[FlowPacked FlowPackedBlock].each do |owner|
  prefix = owner == 'FlowPacked' ? 'flow_pack_' : 'flow_pack_block_'
  expected = 16.times.map { |i| "#{prefix}#{i}" }
  check.call("#{owner} preserves fresh literal packed layout", members[owner] == expected)
  check.call("#{owner} registers every packed native reader and writer", expected.all? { |name| has_owner.call(name, owner) && has_owner.call("#{name}=", owner) })
end

bad_handler = Irep.new(label: 'unresolved_struct_handler', nlocals: 2, nregs: 8, reps: [],
                       catch_handlers: [CatchHandler.new(type: :rescue, begin_addr: 0, end_addr: 2, target: 99)],
                       instructions: [
                         Insn.new(addr: 0, op: :GETCONST, args: "R4\tStruct"),
                         Insn.new(addr: 1, op: :LOADSYM, args: "R5\t:flow_nearest"),
                         Insn.new(addr: 2, op: :SEND, args: "R4\t:new\tn=1"),
                         Insn.new(addr: 3, op: :SETCONST, args: "Foo\tR4")
                       ])
check.call('an unresolved receiver query never falls back to its nearest GETCONST',
           !struct_new_receiver?(bad_handler, 2, bad_handler.instructions[2]))
%i[SSEND SSEND0 SSENDB].each do |op|
  implicit = Irep.new(label: "implicit_struct_#{op}", nlocals: 2, nregs: 8, reps: [], catch_handlers: [],
                      instructions: [
                        Insn.new(addr: 0, op: :GETCONST, args: "R4\tStruct"),
                        Insn.new(addr: 1, op: :LOADSYM, args: "R5\t:flow_stale"),
                        Insn.new(addr: 2, op: op, args: "R4\t:new\tn=1"),
                        Insn.new(addr: 3, op: :SETCONST, args: "Foo\tR4")
                      ])
  check.call("#{op} ignores stale Struct in the call frame receiver slot", !struct_new_receiver?(implicit, 2, implicit.instructions[2]))
end

# FACTORY_READS (closed_world.rb): a read name keeps the factory proof only while its definitions are native. A
# program `==` can store the constant it is handed (argument) or receives (receiver), and a later `.new` through
# the stored reference would make a class the members proof never saw.
def closed_world_of(suite, snippet)
  suite.compile(snippet) do |ireps, root|
    result = build_registry(ireps, root)
    ClosedWorld.new(ireps: ireps, registry: result[0], class_decls: result[7], walked: result[8],
                    native_paths: [], ruby_paths: [], module_names: result[11].to_set)
  end
end

# `is_a?` is a SEND, so it reaches FACTORY_READS (`==` compiles to OP_EQ and always escapes).
ESCAPING_ARGUMENT = "class Keeper\n  def is_a?(other)\n    $kept = other\n    true\n  end\nend\n" \
                    "Pt = Struct.new(:x)\nKeeper.new.is_a?(Struct)\n$kept.new(:y)\n"
ESCAPING_RECEIVER = "class Struct\n  def inspect\n    $kept = self\n    'Struct'\n  end\nend\n" \
                    "Pt = Struct.new(:x)\nStruct.inspect\n$kept.new(:y)\n"
# No program defines is_a? here, so the read name is native-only and the factory proof stands.
NATIVE_READ = "Pt = Struct.new(:x)\nPt.new(:y).is_a?(Struct)\n"

puts '-- FACTORY_READS (closed world)'
check.call('a program is_a? handed a Struct as its argument makes the constant escape',
           closed_world_of(suite, ESCAPING_ARGUMENT).global_refusal == :class_factory_escape)
check.call('a Struct read by a program inspect that receives it (receiver side) makes the constant escape',
           closed_world_of(suite, ESCAPING_RECEIVER).global_refusal == :class_factory_escape)
check.call('a Struct read by a name no program defines keeps the closed world (control)',
           closed_world_of(suite, NATIVE_READ).global_refusal != :class_factory_escape)

puts '-- FACTORY_FLOW (closed world)'
class_fixture = <<~RUBY
  class FactoryBaseA; end
  class FactoryBaseB; end
  class FactoryUnrelated; end
  def factory_flow(flag)
    factory = Class
    base = flag ? FactoryBaseA : FactoryBaseB
    copy = factory
    copy.new(base)
    nil
  end
RUBY
world = closed_world_of(suite, class_fixture)
check.call('MOVE factory and superclass joins keep a finite closed world', world.global_refusal.nil?)
check.call('both incoming superclasses are marked dynamically subclassed',
           !world.native_subclass_free?(['FactoryBaseA']) && !world.native_subclass_free?(['FactoryBaseB']))
check.call('the superclass join leaves unrelated classes subclass-free', world.native_subclass_free?(['FactoryUnrelated']))

world = closed_world_of(suite, <<~RUBY)
  def factory_members(flag)
    factory = Struct
    name = flag ? :flow_left : :flow_right
    copy = factory
    copy.new(name)
    factory.new(:flow_second)
    nil
  end
RUBY
check.call('a Struct alias can feed multiple constructors with joined member names', world.global_refusal.nil?)
check.call('every possible member and writer is recorded',
           %w[flow_left flow_left= flow_right flow_right= flow_second flow_second=].all? { |name| world.unknown_def?(name) })
check.call('unrelated names are not treated as generated members', !world.unknown_def?('flow_unused'))

world = closed_world_of(suite, 'Class.new; nil')
check.call('Class.new without a superclass records the implicit Object subclass',
           world.global_refusal.nil? && !world.native_subclass_free?(['Object']))

safe = {
  'dead factory load' => 'Struct; nil',
  'joined factory receiver' => 'factory = flag ? Class : Class; factory.new(Object); nil',
  'superclass loaded before factory' => 'base = Object; factory = Class; factory.new(base); nil',
  'overwritten alias' => 'factory = Struct; factory = nil; $factory_kept = factory; nil',
  'native read through an alias' => 'factory = Struct; factory.inspect; nil',
  'conditional uses' => 'factory = Struct; if flag; factory.new(:flow_a); else; factory.new(:flow_b); end; nil',
  'loop uses' => 'factory = Class; while flag; factory.new(Object); flag = false; end; nil',
  'member overwrite' => 'name = :flow_old; name = :flow_new; Struct.new(name); nil'
}
safe.each do |label, code|
  world = closed_world_of(suite, "def factory_safe(flag); #{code}; end")
  check.call("#{label} does not escape", world.global_refusal.nil?)
  if label == 'member overwrite'
    check.call('only the reaching member name is recorded',
               world.unknown_def?('flow_new') && !world.unknown_def?('flow_old'))
  end
end

unsafe = {
  'escape after a native read' => 'factory = Struct; factory.inspect; $factory_kept = factory; nil',
  'escape after construction' => 'factory = Struct; factory.new(:flow_a); $factory_kept = factory; nil',
  'escape on another branch' => 'factory = Struct; if flag; factory.new(:flow_a); else; $factory_kept = factory; end; nil',
  'capture by a block' => 'factory = Struct; [1].map { factory.new(:flow_a) }; nil',
  'unknown superclass arm' => 'base = flag ? unknown_base : Object; Class.new(base); nil',
  'unknown member arm' => 'name = flag ? unknown_name : :flow_a; Struct.new(name); nil',
  'packed members' => 'names = [:flow_a]; Struct.new(*names); nil',
  'factory as constructor argument' => 'factory = Class; factory.new(factory); nil',
  'handler escape' => 'factory = Struct; begin; factory.new(:flow_a); rescue; $factory_kept = factory; end; nil',
  'Data constructor' => 'Data.new(:flow_a); nil'
}
unsafe.each do |label, code|
  world = closed_world_of(suite, "def factory_unsafe(flag); #{code}; end")
  check.call("#{label} conservatively refuses", world.global_refusal == :class_factory_escape)
end

suite.compile('factory = Class; copy = factory; copy.new(Object); nil') do |ireps, root|
  body = ireps.fetch(root)
  index = body.instructions.index { |i| i.op == :GETCONST && i.const_name == 'Class' }
  check.call('an exhausted alias budget refuses instead of returning partial uses',
             FactoryFlow.uses(body, index, body.instructions[index].reg, max_aliases: 0).nil?)
end

suite.finish!
