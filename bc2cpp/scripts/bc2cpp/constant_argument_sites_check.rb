# frozen_string_literal: true
#
# CONSTANT_ARGUMENT_SITES (tools/bc2cpp/constant_argument_sites.rb), report only: a pure method with one constant call site
# is decided by that tuple; an impure method is refused with its reason; a method called with two tuples has no single
# tuple. Each untrustworthy condition has its own fixture: an unresolved call (a literal and a computed target, and
# method_missing), a redefined pure name, a closed operator gate, and a body that may raise. The report is computed twice
# and must reproduce. Needs MRBC; without it the check prints SKIP and exits 0.
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

# The report on a fixture, computed from the same ireps and registry the code generator uses.
report_of = lambda do |source|
  suite.compile(source) do |ireps, root|
    registry = build_registry(ireps, root)[0]
    ConstantArgumentSites.report(ireps, registry)
  end
end

first = report_of.call(SOURCE)
second = report_of.call(SOURCE)
rows = first[:rows].to_h { |r| [r[:name], r] }

puts '== report'
puts "  summary #{first[:summary].inspect}"
suite.check('the report reproduces on a second run', first == second)

puts '== pure method with one constant call site'
pure = rows.fetch('pure_one')
suite.check('pure_one has one constant call site and a single tuple', pure[:constant_sites] == 1 && pure[:single_tuple])
suite.check('pure_one is pure', pure[:pure])
suite.check('pure_one has one jump, decided by the constant', pure[:jumps] == 1 && pure[:decided] == 1)
suite.check('the closed operator gate is open on this fixture', first[:summary][:operator_gate_closed] == false)

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

puts '== condition 1: unresolved calls'
literal = report_of.call(<<~'RUBY')
  class Dyn
    def dyn_one(x)
      x
    end
    def run
      send(:dyn_one, 3)
    end
  end
RUBY
dyn_one = literal[:rows].find { |r| r[:name] == 'dyn_one' }
suite.check('a send with a literal target names that method as unresolved', dyn_one[:unresolved].to_s.include?('send dyn_one'))
suite.check('a method with a literal dynamic target is not a single-tuple candidate', !dyn_one[:single_tuple])

computed = report_of.call(<<~'RUBY')
  class DynC
    def pure_one(x)
      if x then 1 else 2 end
    end
    def run(s)
      send(s, 1)
    end
    def go
      pure_one(3)
    end
  end
RUBY
computed_pure = computed[:rows].find { |r| r[:name] == 'pure_one' }
suite.check('a computed dynamic target makes every method unresolved', computed[:summary][:unresolved_global])
suite.check('pure_one with a computed target is not a single-tuple candidate', !computed_pure[:single_tuple])
suite.check('the computed target is reported on pure_one', computed_pure[:unresolved].to_s.include?('computed name'))

mm = report_of.call(<<~'RUBY')
  class Mm
    def pure_one(x)
      if x then 1 else 2 end
    end
    def method_missing(name, *args)
      nil
    end
    def run
      pure_one(3)
    end
  end
RUBY
mm_pure = mm[:rows].find { |r| r[:name] == 'pure_one' }
suite.check('a method_missing definition is not a reason: pure_one is unresolved for no reason', mm_pure[:unresolved].nil?)
suite.check('a method_missing definition leaves pure_one a single-tuple candidate', mm_pure[:single_tuple])

undef_src = report_of.call(<<~'RUBY')
  class Ud
    def pure_one(x)
      if x then 1 else 2 end
    end
    def gone
      1
    end
    undef_method :gone
    def run
      pure_one(3)
    end
  end
RUBY
ud = undef_src[:rows].find { |r| r[:name] == 'pure_one' }
suite.check('an UNDEF is not a reason: pure_one stays a single-tuple candidate', ud[:single_tuple] && ud[:unresolved].nil?)

alias_src = report_of.call(<<~'RUBY')
  class Al
    def pure_one(x)
      if x then 1 else 2 end
    end
    alias pure_alias pure_one
    def run
      pure_alias(3)
    end
  end
RUBY
al = alias_src[:rows].find { |r| r[:name] == 'pure_one' }
suite.check('an alias makes the old name unresolved, so pure_one is no single-tuple candidate', !al[:single_tuple] && al[:unresolved].to_s.include?('alias'))
suite.check('an alias does not make an unrelated method unresolved', alias_src[:rows].none? { |r| r[:name] == 'run' && r[:unresolved] })

# The jump decision needs a complete tuple only: an impure body (an ivar write) with one constant tuple still has its jump decided.
impure_jump = report_of.call(<<~'RUBY')
  class Ij
    def impure_jump(x)
      @seen = x
      if x then 1 else 2 end
    end
    def run
      impure_jump(3)
    end
  end
RUBY
ij = impure_jump[:rows].find { |r| r[:name] == 'impure_jump' }
suite.check('an impure body with one tuple is not pure', !ij[:pure])
suite.check('its jump is still decided by the single tuple', ij[:jumps] == 1 && ij[:decided] == 1)
suite.check('the pure-only summary does not count it', impure_jump[:summary][:jumps_decided_pure] == 0 && impure_jump[:summary][:jumps_decided] == 1)

# A may-raise body (x + 1 before the branch) with one tuple: the branch is still decided.
raise_jump = report_of.call(<<~'RUBY')
  class Rj
    def raise_jump(x)
      y = x + 1
      if x then y else 2 end
    end
    def run
      raise_jump(3)
    end
  end
RUBY
rj = raise_jump[:rows].find { |r| r[:name] == 'raise_jump' }
suite.check('a may-raise body is not pure', !rj[:pure] && !rj[:may_raise].empty?)
suite.check('its jump is decided by the single tuple despite may_raise', rj[:jumps] == 1 && rj[:decided] == 1)

puts '== condition 2: redefined pure name'
redef = report_of.call(<<~'RUBY')
  class Redef
    def ==(other)
      true
    end
    def same(x)
      if x == 1 then 1 else 2 end
    end
    def run
      same(3)
    end
  end
RUBY
same = redef[:rows].find { |r| r[:name] == 'same' }
suite.check('a Ruby definition of == is recorded in the summary', redef[:summary][:redefined_names].include?('=='))
suite.check('a body sending a redefined name is refused as impure', !same[:pure] && same[:impure].include?('redefined =='))

puts '== condition 3: operator gate'
gate = report_of.call(<<~'RUBY')
  class Integer
    def +(other)
      0
    end
  end
  class Gate
    def add1(x)
      x + 1
    end
    def run
      add1(3)
    end
  end
RUBY
add1 = gate[:rows].find { |r| r[:name] == 'add1' }
suite.check('a redefined Integer operator closes the gate', gate[:summary][:operator_gate_closed])
suite.check('an arithmetic op under a closed gate is refused as impure',
            !add1[:pure] && add1[:impure].any? { |reason| reason.start_with?('operator gate') })

puts '== condition 4: may raise'
raising = report_of.call(<<~'RUBY')
  class Raise
    def raises_add(x)
      x + 1
    end
    def run
      raises_add(3)
    end
  end
RUBY
raises = raising[:rows].find { |r| r[:name] == 'raises_add' }
suite.check('x + 1 is may_raise, not impure, when the gate is open', raises[:impure].empty? && !raises[:may_raise].empty?)
suite.check('a may_raise body is not pure', !raises[:pure])
suite.check('the summary counts the may_raise method', raising[:summary][:may_raise_methods] == 1)

suite.finish!
