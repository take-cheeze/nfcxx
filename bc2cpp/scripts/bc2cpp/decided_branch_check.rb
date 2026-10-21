#!/usr/bin/env ruby
# frozen_string_literal: true

# DECIDED_BRANCH (tools/bc2cpp/codegen_decided_branch.rb): a conditional jump whose tested register the NumericFlow state
# decides is emitted as an unconditional goto or as nothing; an undecided one keeps its test. The fixture has four decided
# jumps (`if nil`, `if "a"`, `unless nil`, `nil?`) and three kept ones (the ternary and the `if` on a parameter, and a join
# of nil with a string). Needs MRBC; without it the check prints SKIP and exits 0.
#
#   MRBC=path/to/host/mrbc ruby scripts/bc2cpp/decided_branch_check.rb

require 'set'
require_relative 'check_support'
require_relative '../../tools/bc2cpp/bc2cpp'

suite = FixtureCheck.new('decided_branch_check')
suite.require_mrbc!

SOURCE = <<~'RUBY'
  class Router
    def route(x)
      y = nil
      s = "a"
      z = x ? nil : "a"
      r = 0
      r += 1 if y
      r += 2 if s
      r += 4 if x
      r += 8 unless y
      r += 16 if y.nil?
      r += 32 if z
      r
    end
  end
RUBY

# The generated C++ of Router#route, with the gate set to +gate+ ('1' or '0') for the duration of the block.
route_code = lambda do |gate|
  previous = ENV['BC2CPP_DECIDED_BRANCH']
  ENV['BC2CPP_DECIDED_BRANCH'] = gate
  suite.compile(SOURCE) do |ireps, root|
    registry = build_registry(ireps, root)[0]
    gen = CodeGen.new(ireps, registry, {}, {}, {}, {}, {}, {}, {}, {}, {}, Set.new)
    method = registry.fetch('route').find { |d| d.owner == 'Router' }
    gen.compile_method(method.irep).fetch(:code)
  end
ensure
  ENV['BC2CPP_DECIDED_BRANCH'] = previous
end

tests = ->(code) { code.scan(/mrb_test\(|mrb_nil_p\(/).size }

on = route_code.call('1')
off = route_code.call('0')

puts '== decided jumps are folded'
suite.check('four decided jumps carry a DECIDED_BRANCH line', on.scan('DECIDED_BRANCH').size == 4)
suite.check('the nil-tested if and the nil? test are folded to goto (taken)',
            on.scan(/goto L\d+; \/\/ DECIDED_BRANCH JMPNOT R\d+: taken/).size == 1 &&
            on.scan(/goto L\d+; \/\/ DECIDED_BRANCH JMPNIL R\d+: taken/).size == 1)
suite.check('the string-tested if and the unless-nil are never taken',
            on.scan(%r{// DECIDED_BRANCH (JMPNOT|JMPIF) R\d+: not taken}).size == 2)

puts '== undecided jumps keep their test'
suite.check('the parameter test is kept', on.include?('if (!mrb_test(r1)) goto'))
suite.check('the ternary on the parameter and the join of nil and a string are kept',
            tests.call(on) == 3)

puts '== gate'
suite.check('BC2CPP_DECIDED_BRANCH=0 emits no DECIDED_BRANCH line', !off.include?('DECIDED_BRANCH'))
suite.check('with the gate off all seven tests are emitted as before', tests.call(off) == 7)
suite.check('with the gate on only the three undecided tests remain', tests.call(on) == 3)

suite.finish!
