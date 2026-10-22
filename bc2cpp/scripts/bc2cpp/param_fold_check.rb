#!/usr/bin/env ruby
# frozen_string_literal: true

# PARAM_FOLD (tools/bc2cpp/codegen_param_fold.rb, ADR 0540): with BC2CPP_PARAM_FOLD=1 a decided jump on a parameter is
# folded when the method is complete, so the pooled call-site mask decides it. The fixtures are:
#   - a complete method whose only callers pass Integers: `if x` folds to goto (gate on), keeps its test (gate off);
#   - the same method with a define_method of the same name elsewhere: the test is kept with the gate on;
#   - the same method with a computed-name send that can reach it: the test is kept with the gate on;
#   - the same method with a method_missing on its owner: the test is kept with the gate on.
# The closed world is a ClosedWorld built from the fixture's own ireps and registry, with no outside sources. Needs MRBC;
# without it the check prints SKIP and exits 0.
#
#   MRBC=path/to/host/mrbc ruby scripts/bc2cpp/param_fold_check.rb

require 'set'
require_relative 'check_support'
require_relative '../../tools/bc2cpp/bc2cpp'

suite = FixtureCheck.new('param_fold_check')
suite.require_mrbc!

COMPLETE = <<~'RUBY'
  class Router
    def route(x)
      r = 0
      r += 1 if x
      r
    end

    def run
      route(3) + route(4)
    end
  end
RUBY

DEFINE_METHOD = COMPLETE + <<~'RUBY'
  class Dm
    define_method(:route) { |x| x }
  end
RUBY

# The computed send names the method from a String literal: DynamicNames reaches a method only through a name the program
# spells, so the literal "route" is what makes the send able to reach it.
COMPUTED_SEND = COMPLETE.sub("  def run\n", "  def go(n)\n    send(n, 3)\n  end\n\n  def run\n")
                        .sub("route(3) + route(4)\n", "route(3) + route(4) + go('route')\n")

METHOD_MISSING = COMPLETE.sub("  def run\n", "  def method_missing(*)\n    0\n  end\n\n  def run\n")


# The generated C++ of Router#route with BC2CPP_PARAM_FOLD set to +gate+ ('1' or '0'), for +source+ with +world+ set.
route_code = lambda do |gate, source = COMPLETE|
  previous = ENV['BC2CPP_PARAM_FOLD']
  ENV['BC2CPP_PARAM_FOLD'] = gate
  suite.compile(source) do |ireps, root|
    registry = build_registry(ireps, root)[0]
    # The fixture has no outside Ruby or native callers, so both scans are empty: entry_arg_candidates needs them, and
    # the numeric facts are computed in the constructor, so the world is passed there too.
    world = ClosedWorld.new(ireps: ireps, registry: registry, class_decls: {}, walked: [], native_paths: [], ruby_paths: [])
    gen = CodeGen.new(ireps, registry, {}, {}, {}, {}, {}, {}, {}, {}, {}, Set.new,
                      Set.new, Set.new, nil, {}, {}, Set.new, closed_world: world)
    method = registry.fetch('route').find { |d| d.owner == 'Router' }
    gen.compile_method(method.irep).fetch(:code)
  end
ensure
  ENV['BC2CPP_PARAM_FOLD'] = previous
end

# The parameter test of `if x` is the one jump the fold can decide; a test is a mrb_test( call.
tests = ->(code) { code.scan(/mrb_test\(/).size }
folded = ->(code) { code.scan(/DECIDED_BRANCH JMP(?:IF|NOT) R\d+: (?:taken|not taken)/).size }

gate_on = route_code.call('1')
gate_off = route_code.call('0')

puts '== complete method'
suite.check('with the gate on the parameter test is folded', folded.call(gate_on) == 1)
suite.check('with the gate off the parameter test is kept', folded.call(gate_off) == 0 && tests.call(gate_off) > tests.call(gate_on))

puts '== incomplete methods keep the test with the gate on'
suite.check('a define_method of the same name keeps the test',
            folded.call(route_code.call('1', DEFINE_METHOD)) == 0)
suite.check('a computed-name send that can reach the method keeps the test',
            folded.call(route_code.call('1', COMPUTED_SEND)) == 0)
suite.check('a method_missing on the owner keeps the test',
            folded.call(route_code.call('1', METHOD_MISSING)) == 0)

suite.finish!
