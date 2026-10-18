#!/usr/bin/env ruby
# frozen_string_literal: true

# DECLARED_CONSTANT_CHECK, ARRAY_SUM (docs/adr/0455, tools/bc2cpp/declared_constants.rb): a declared `X: Array` accepts
# an assignment that const_rows types `inferred:array-sum`, under the same proof and withholding. Each fixture is
# compiled by the host mrbc, then DeclaredConstants.check runs over it as bc2cpp.rb does. Every case also asserts that
# array_sum_names (the rows' source) and the declared check agree on X. Needs MRBC (a host mrbc); without it the check
# prints SKIP and exits 0.
#
#   MRBC=path/to/host/mrbc ruby scripts/bc2cpp/declared_array_sum_check.rb

require 'set'
require 'tmpdir'
require_relative '../../tools/bc2cpp/bc2cpp'

unless ENV['MRBC'] && File.executable?(ENV['MRBC'])
  puts 'SKIP declared_array_sum_check: MRBC is not set to a host mrbc'
  exit 0
end

failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

# The declared check and the rows' sum names over one program and one RBS declaration of X.
run = lambda do |source, sig|
  Dir.mktmpdir do |dir|
    rb = File.join(dir, 'fixture.rb')
    rbs = File.join(dir, 'fixture.rbs')
    File.write(rb, source)
    File.write(rbs, sig)
    ireps, root = compile_ireps([rb], 'declared_array_sum', dir)
    registry, superclass_of, container_constants, _included, prepended, unknown, _structs, _decls, _walked, _ivars,
      sites, = build_registry(ireps, root)
    # The mruby core definitions bc2cpp.rb adds from NATIVE_SRCS: without them no `+` or `freeze` is the core one.
    %w[+ freeze].each { |name| registry[name] << MethodDef.new(name: name, owner: '<native>', irep: nil, visibility: :public) }
    plus_safe =DeclaredConstants.array_sum_safe?(registry, superclass_of, prepended, unknown)
    entries = DeclaredConstants.load([rbs], dir, registry.values.flatten.map(&:owner).to_set)
    result = DeclaredConstants.check(entries, ireps, registry, sites, Set.new, Set.new, container_constants, dir,
                                     plus_safe: plus_safe)
    rows = DeclaredConstants.array_sum_names(ireps, sites, registry, container_constants, plus_safe)
    {
      errors: result.diagnostics.select { |d| d[:severity] == 'error' }.map { |d| d[:message] },
      report: result.report.join("\n"),
      containers: result.containers,
      rows_sum: rows.key?('X')
    }
  end
end

sig = "X: Array\n"

# The sum needs both operands proven Array, so the declared Array on the frozen sum passes exactly where the rows
# type X as Array.
puts '== declared Array on a sum'
sum = run.call("A = [1, 2]\nB = [3]\nX = (A + B).freeze\n", sig)
check.call('declared X: Array on (A + B).freeze passes (no TC1011 error)', sum[:errors].empty?)
check.call('the declared fact is Array (X is a container of class Array)', sum[:containers]['X'] == 'Array')
check.call('the rows type X as an array sum too (same proof)', sum[:rows_sum])
check.call('the report says checked, fact', sum[:report].include?('DECLARED_CONST X: Array: checked, fact'))

nested = run.call("A = [1]\nB = [2]\nY = (A + B).freeze\nX = (Y + B).freeze\n", sig)
check.call('a sum over another proven sum passes', nested[:errors].empty? && nested[:rows_sum])

unfrozen = run.call("A = [1]\nB = [2]\nX = A + B\n", sig)
check.call('an unfrozen A + B passes with the same proof as the rows', unfrozen[:errors].empty? && unfrozen[:rows_sum])

# Withholding: the sum proof is off whenever Ruby can replace Array#+ or Object#freeze, so the declared check fails too.
puts '== withheld when Ruby can replace the core method'
plus = run.call("class Array\n  def +(other)\n    [self]\n  end\nend\nA = [1, 2]\nB = [3]\nX = (A + B).freeze\n", sig)
check.call('a program `class Array; def +` still fails the declared Array check',
           plus[:errors].any? { |m| m.include?('the assigned value is not a proven Array') })
check.call('the rows do not type it as an array sum either', !plus[:rows_sum])

frozen = run.call("class Object\n  def freeze\n    self\n  end\nend\nA = [1, 2]\nB = [3]\nX = (A + B).freeze\n", sig)
check.call('a program `def freeze` still fails the declared Array check',
           frozen[:errors].any? { |m| m.include?('the assigned value is not a proven Array') })
check.call('the rows do not type it as an array sum either', !frozen[:rows_sum])

# Operands must each prove Array: a String or an Integer operand is not a sum of Arrays.
puts '== non-Array operands'
strings = run.call("A = 'a'\nB = 'b'\nX = (A + B).freeze\n", sig)
check.call('a String sum fails the declared Array check',
           strings[:errors].any? { |m| m.include?('the assigned value is not a proven Array') })
check.call('the rows do not type it as an array sum either', !strings[:rows_sum])

mixed = run.call("A = [1]\nB = 2\nX = (A + B).freeze\n", sig)
check.call('an Array plus an Integer fails the declared Array check',
           mixed[:errors].any? { |m| m.include?('the assigned value is not a proven Array') })
check.call('the rows do not type it as an array sum either', !mixed[:rows_sum])

puts "#{failures.empty? ? 'PASS' : 'FAIL'} declared_array_sum_check: #{failures.size} failure(s)"
exit(failures.empty? ? 0 : 1)
