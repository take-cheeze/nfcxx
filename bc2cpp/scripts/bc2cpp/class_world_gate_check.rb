#!/usr/bin/env ruby
# frozen_string_literal: true

# CLASS_WORLD_GATE: the owner-call codegen reads the class graph (tools/bc2cpp/class_world_gate.rb) and emits a direct
# call to a definition only for a receiver class the graph states exactly, with every ancestor exact. This check proves
# the gate on a fixture graph and on the real closed-build graph:
#
#   1. exact receiver: `Exact` (a plain class, no dynamic statement) is exact, its lookup of `bar` reaches
#      Exact#bar, and CodeGen#class_world_exact_target returns that definition (the direct form);
#   2. non-exact receiver: `Dyn` is reopened by a class_eval inside a method, so the graph marks it unknown; the gate
#      refuses it and the target is nil (the owner call stays, output unchanged);
#   3. unknown receiver: a name the graph does not know is refused, never guessed;
#   4. an exact class whose lookup reaches a definer the graph cannot place (a native owner) is refused;
#   5. BC2CPP_CLASS_WORLD_DIRECT=0 turns the direct form off for the exact receiver;
#   6. the real closed-build graph derives, accepts at least one class, and refuses an unknown name.
#
# Usage: ruby scripts/bc2cpp/class_world_gate_check.rb   (no mrbc needed: the graph is read from source)

require 'tmpdir'
require 'set'
require_relative 'check_support'
require_relative '../../tools/bc2cpp/bc2cpp'
require_relative '../../tools/bc2cpp/class_body_scan'
require_relative '../../tools/bc2cpp/class_world'
require_relative '../../tools/bc2cpp/class_world_gate'

suite = FixtureCheck.new('class_world_gate_check')

FIXTURE = <<~'RUBY'
  class Exact
    def bar; end
  end

  class Dyn
    def bar; end

    def self.reopen
      Dyn.class_eval { def baz; end }
    end
  end
RUBY

def fixture_world
  Dir.mktmpdir('class_world_gate') do |dir|
    path = File.join(dir, 'fixture.rb')
    File.write(path, FIXTURE)
    ClassWorld.build([ClassBodyScan.scan([path])])
  end
end

# A CodeGen with only the state class_world_exact_target reads; the registry is the one given.
Def = Struct.new(:owner, :name, :irep, :visibility, :kind, keyword_init: true)

def codegen_with(registry)
  gen = CodeGen.allocate
  gen.instance_variable_set(:@registry, registry)
  gen.instance_variable_set(:@unknown_mixins, Set.new)
  gen.instance_variable_set(:@prepended_modules, {})
  gen.define_singleton_method(:devirt_blocked_name?) { |_| false }
  gen.define_singleton_method(:symbol_installed_names) { Set.new }
  gen
end

def with_world(world)
  ClassWorldGate.instance_variable_set(:@world, world)
  yield
ensure
  ClassWorldGate.remove_instance_variable(:@world)
end

world = fixture_world
bar_registry = {
  'bar' => [
    Def.new(owner: 'Exact', name: 'bar', irep: 1, visibility: :public, kind: :method),
    Def.new(owner: 'Dyn', name: 'bar', irep: 2, visibility: :public, kind: :method)
  ]
}
exact_only = { 'bar' => [Def.new(owner: 'Exact', name: 'bar', irep: 1, visibility: :public, kind: :method)] }
native_definer = { 'bar' => [Def.new(owner: 'Exact', name: 'bar', irep: 1, visibility: :public, kind: :method),
                             Def.new(owner: '<native>', name: 'bar', irep: nil, visibility: :public, kind: :native)] }

with_world(world) do
  gen = codegen_with(exact_only)
  suite.check('fixture: Exact is exact and its ancestors are exact', ClassWorldGate.exact_receiver?('Exact', world))
  suite.check('fixture: Exact lookup of bar reaches Exact#bar (direct form)',
              gen.send(:class_world_exact_target, 'bar', 'Exact')&.owner == 'Exact')
  suite.check('fixture: Dyn (reopened by class_eval) is refused', !ClassWorldGate.exact_receiver?('Dyn', world))
  suite.check('fixture: Dyn gets no direct target (owner call kept)',
              codegen_with(bar_registry).send(:class_world_exact_target, 'bar', 'Dyn').nil?)
  suite.check('fixture: unknown receiver Nope is refused', !ClassWorldGate.exact_receiver?('Nope', world) &&
              codegen_with(exact_only).send(:class_world_exact_target, 'bar', 'Nope').nil?)
  suite.check('fixture: a native definer the graph cannot place keeps the owner call',
              codegen_with(native_definer).send(:class_world_exact_target, 'bar', 'Exact').nil?)
  suite.check('fixture: nil receiver class is refused', !ClassWorldGate.exact_receiver?(nil, world))

  previous = ENV['BC2CPP_CLASS_WORLD_DIRECT']
  begin
    ENV['BC2CPP_CLASS_WORLD_DIRECT'] = '0'
    suite.check('kill switch: BC2CPP_CLASS_WORLD_DIRECT=0 refuses the exact receiver',
                codegen_with(exact_only).send(:class_world_exact_target, 'bar', 'Exact').nil?)
  ensure
    ENV['BC2CPP_CLASS_WORLD_DIRECT'] = previous
  end
end

closed = ClassWorldGate.world
suite.check('closed build: the class graph derives from the sources', !closed.nil?)
accepted = closed ? closed.facts.count { |name, _| ClassWorldGate.exact_receiver?(name, closed) } : 0
suite.check("closed build: at least one class is accepted (#{accepted})", accepted.positive?)
suite.check('closed build: an unknown name is refused', closed && !ClassWorldGate.exact_receiver?('No::Such::Class', closed))

suite.finish!
