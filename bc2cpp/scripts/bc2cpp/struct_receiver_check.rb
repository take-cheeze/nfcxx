#!/usr/bin/env ruby
# frozen_string_literal: true

# STRUCT_RECEIVER (tools/bc2cpp/registry.rb): the Struct.new receiver and the singleton receiver of `def obj.m` /
# `class << obj` are read from BytecodeIR.reaching_definitions (MOVEs followed), so every definition that reaches
# the send must be the same constant. The old linear read saw only the textually nearest writer: a local holding
# Struct (`k = Struct; k.new`) is a MOVE there, so its members and block defs were missed; a join
# `(c ? Hash : Struct).new` took the Struct branch that happens to come last, which is not the receiver on every path.
# Where the IR cannot prove the set, the linear rule decides as before.
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
  index = body.instructions.index { |i| i.op == 'GETCONST' && i.const_name == 'Class' }
  check.call('an exhausted alias budget refuses instead of returning partial uses',
             FactoryFlow.uses(body, index, body.instructions[index].reg, max_aliases: 0).nil?)
end

suite.finish!
