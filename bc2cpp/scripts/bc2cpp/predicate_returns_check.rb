#!/usr/bin/env ruby
# frozen_string_literal: true

# Checks tools/bc2cpp/predicate_returns.rb on fixture sources: a method ending in `?` is accepted only when every value it
# returns is provably bool (literals, && / ||, a branch with an else whose arms are bool, a built-in predicate), and the
# violations name the method. Host only, a few milliseconds.
#
#   ruby scripts/bc2cpp/predicate_returns_check.rb

require_relative '../../tools/bc2cpp/predicate_returns'

failures = []
checks = 0
check = lambda do |what, condition|
  checks += 1
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

def names(source)
  PredicateReturns.violations_in('fixture.rb', source).map(&:name)
end

puts '== accepted predicates'
check.call('a comparison is bool', names("class A\n def a?; x == 1; end\nend\n").empty?)
check.call('true and false literals are bool', names("class A\n def a?; if x then true else false end; end\nend\n").empty?)
check.call('a return of bool plus a bool last value is bool',
           names("class A\n def a?; return false if x; true; end\nend\n").empty?)
check.call('a case with an else whose arms are bool is bool',
           names("class A\n def a?; case x\n when 1 then true\n else false\n end; end\nend\n").empty?)
check.call('a begin whose body and rescue are bool is bool',
           names("class A\n def a?; begin; true; rescue; false; end; end\nend\n").empty?)
check.call('a nested method does not count toward its outer returns',
           names("class A\n def a?; def b; 1; end; true; end\nend\n").empty?)
check.call('a method not ending in ? is not judged', names("class A\n def a; @x; end\nend\n").empty?)

puts '== violations'
check.call('an ivar value is not bool', names("class A\n def a?; @x; end\nend\n") == ['A#a?'])
check.call('an if without an else is not bool', names("class A\n def a?; if x then true end; end\nend\n") == ['A#a?'])
check.call('a bare return is not bool', names("class A\n def a?; return; end\nend\n") == ['A#a?'])
check.call('a return of a value is not bool', names("class A\n def a?; return nil; end\nend\n") == ['A#a?'])
check.call('a call to an unknown predicate is not a proof',
           names("class A\n def a?; x.nil? && y?; end\nend\n") == ['A#a?'])
check.call('an empty body is not bool', names("class A\n def a?; end\nend\n") == ['A#a?'])
check.call('the owner is the enclosing class path', names("module M\n class B\n  def a?; 1; end\n end\nend\n") == ['M::B#a?'])

puts
puts "predicate returns check: #{checks - failures.size} checks passed" if failures.empty?
abort "predicate returns check: #{failures.size} of #{checks} failed" unless failures.empty?
