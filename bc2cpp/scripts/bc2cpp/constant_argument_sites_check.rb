#!/usr/bin/env ruby
# frozen_string_literal: true

# CONSTANT_ARGUMENT_SITES (tools/bc2cpp/constant_argument_sites.rb), report only: a pure method with one constant call site
# is decided by that tuple; an impure method is refused with its reason; a method called with two tuples has no single
# tuple. The report is computed twice and must reproduce. Needs MRBC; without it the check prints SKIP and exits 0.
#
#   MRBC=path/to/host/mrbc ruby scripts/bc2cpp/constant_argument_sites_check.rb

require 'set'
require_relative 'check_support'
require_relative '../../tools/bc2cpp/bc2cpp'
require_relative '../../tools/bc2cpp/constant_argument_sites'

suite = FixtureCheck.new('constant_argument_sites_check')
suite.require_mrbc!

SOURCE = <<~'RUBY'
  class Cal
    @n = 0
    def pure_one(x)
      if x then 1 else 2 end
    end
    def impure_one(x)
      @n = x
      x
    end
    def two(x)
      if x then 1 else 2 end
    end
    def run
      a = pure_one(3)
      b = impure_one(3)
      c = two(nil)
      d = two(2)
      [a, b, c, d]
    end
  end
RUBY

# The report on the fixture, computed from the same ireps and registry the code generator uses.
run_report = lambda do
  suite.compile(SOURCE) do |ireps, root|
    registry = build_registry(ireps, root)[0]
    ConstantArgumentSites.report(ireps, registry)
  end
end

first = run_report.call
second = run_report.call
rows = first[:rows].to_h { |r| [r[:name], r] }

puts '== report'
puts "  summary #{first[:summary].inspect}"
suite.check('the report reproduces on a second run', first == second)

puts '== pure method with one constant call site'
pure = rows.fetch('pure_one')
suite.check('pure_one has one constant call site and a single tuple', pure[:constant_sites] == 1 && pure[:single_tuple])
suite.check('pure_one is pure', pure[:pure])
suite.check('pure_one has one jump, decided by the constant', pure[:jumps] == 1 && pure[:decided] == 1)

puts '== impure method'
impure = rows.fetch('impure_one')
suite.check('impure_one is refused', !impure[:pure])
suite.check('impure_one names the ivar write', impure[:impure].include?('SETIV'))

puts '== method called with two constant tuples'
two = rows.fetch('two')
suite.check('two has two constant call sites', two[:constant_sites] == 2)
suite.check('two has no single tuple', !two[:single_tuple] && two[:jumps].nil?)

puts '== no call sites'
suite.check('run has no call sites, so it is not a constant-argument candidate', rows.fetch('run')[:constant_sites].zero?)

suite.finish!
