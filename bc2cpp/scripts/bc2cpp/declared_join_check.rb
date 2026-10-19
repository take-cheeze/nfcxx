#!/usr/bin/env ruby
# frozen_string_literal: true

# DECLARED_CONSTANT_CHECK and the report-level owner proofs (docs/adr/0455, tools/bc2cpp/declared_constants.rb) over
# joins. A `c ? a : b` value is one writer per arm, and each proof must hold for every writer that reaches the read,
# or it withholds. Each fixture is compiled by the host mrbc. Needs MRBC (a host mrbc); without it the check prints SKIP
# and exits 0.
#
#   MRBC=path/to/host/mrbc ruby scripts/bc2cpp/declared_join_check.rb

require 'set'
require 'tmpdir'
require_relative '../../tools/bc2cpp/bc2cpp'

unless ENV['MRBC'] && File.executable?(ENV['MRBC'])
  puts 'SKIP declared_join_check: MRBC is not set to a host mrbc'
  exit 0
end

failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

# The declared check over one program and one RBS declaration (as declared_array_sum_check runs it), plus the program's
# irep tree for the owner proofs.
run = lambda do |source, sig|
  Dir.mktmpdir do |dir|
    rb = File.join(dir, 'fixture.rb')
    rbs = File.join(dir, 'fixture.rbs')
    File.write(rb, source)
    File.write(rbs, sig)
    ireps, root = compile_ireps([rb], 'declared_join', dir)
    registry, superclass_of, container_constants, included, prepended, unknown, _structs, _decls, _walked, _ivars,
      sites, = build_registry(ireps, root)
    %w[+ freeze].each { |name| registry[name] << MethodDef.new(name: name, owner: '<native>', irep: nil, visibility: :public) }
    plus_safe = DeclaredConstants.array_sum_safe?(registry, superclass_of, prepended, unknown)
    range_safe = DeclaredConstants.range_to_a_safe?(registry, included, prepended, unknown)
    entries = DeclaredConstants.load([rbs], dir, registry.values.flatten.map(&:owner).to_set)
    result = DeclaredConstants.check(entries, ireps, registry, sites, Set.new, Set.new, container_constants, dir,
                                     plus_safe: plus_safe, range_safe: range_safe)
    {
      errors: result.diagnostics.select { |d| d[:severity] == 'error' }.map { |d| d[:message] },
      ireps: ireps,
      sites: sites
    }
  end
end

# [irep, index, source register] of the top-level SETCONST of +name+.
setconst_of = lambda do |ireps, name|
  ireps.each_value.flat_map do |irep|
    irep.instructions.each_with_index.filter_map do |insn, idx|
      [irep, idx, insn.regs.last] if insn.op == 'SETCONST' && insn.const_name == name
    end
  end.first
end

gate = 'the declared element type needs a frozen array literal'

puts '== a frozen Array[Integer] literal on a join'
# The element check reads the one literal the frozen-array gate (JOIN_DOMINANCE) lets through, so a join is refused there.
plain = run.call("C5 = [1, 2].freeze\n", "C5: Array[Integer]\n")
check.call('C5 = [1, 2].freeze passes Array[Integer] (no join: the element check runs)', plain[:errors].empty?)

mixed = run.call("c = Time.now.year > 0\nC2 = (c ? [2.0] : [1]).freeze\n", "C2: Array[Integer]\n")
check.call('C2 = (c ? [2.0] : [1]).freeze is refused (the frozen-array gate does not prove a join)',
           mixed[:errors].any? { |m| m.include?(gate) })

same = run.call("c = Time.now.year > 0\nC3 = (c ? [1] : [2]).freeze\n", "C3: Array[Integer]\n")
check.call('C3 = (c ? [1] : [2]).freeze is refused the same way, though both arms are Integer literals',
           same[:errors].any? { |m| m.include?(gate) })

puts '== frozen_at? on a join'
frozen = run.call("c = Time.now.year > 0\nF1 = (c ? [1].freeze : [2])\nF2 = (c ? [2] : [1].freeze)\n", '')
f1 = setconst_of.call(frozen[:ireps], 'F1')
f2 = setconst_of.call(frozen[:ireps], 'F2')
check.call('frozen_at? holds for F1, whose then arm is a .freeze result (the other arm is not)',
           DeclaredConstants.frozen_at?(f1[0], f1[1], f1[2]))
check.call('frozen_at? holds for F2, whose else arm is a .freeze result',
           DeclaredConstants.frozen_at?(f2[0], f2[1], f2[2]))

puts '== bool_compare_site? on a join'
bool = run.call("c = Time.now.year > 0\nB1 = (c ? nil : ('abc'.length == 3))\nB2 = ('abc'.length == 3)\n", '')
b1 = setconst_of.call(bool[:ireps], 'B1')
b2 = setconst_of.call(bool[:ireps], 'B2')
check.call('B1 = (c ? nil : (\'abc\'.length == 3)) is not a bool: its then arm is nil',
           !DeclaredConstants.bool_compare_site?(b1[0], b1[1], b1[2], string_length_safe: true, integer_ops_safe: true))
check.call('B2 = (\'abc\'.length == 3) is a bool compare (straight line)',
           DeclaredConstants.bool_compare_site?(b2[0], b2[1], b2[2], string_length_safe: true, integer_ops_safe: true))

puts '== Fixnum evaluation on a join (kept refused)'
# A runtime addend keeps the ADD (mrbc folds a literal one). The 10000000000 arm is a bignum, and the 1 arm is a jump target,
# so the Evaluator's walk stops there and refuses; a Fixnum proof from the else arm alone would be wrong.
big = run.call("c = Time.now.year > 0\nn = Time.now.year\nBIG = (c ? 10000000000 : 1) + n\n", "BIG: Integer\n")
check.call('BIG: Integer is refused for a ternary whose arm is outside the Fixnum margin',
           big[:errors].any? { |m| m.include?('the assigned value is not a proven Fixnum expression') })

if failures.empty?
  puts 'declared_join_check: all checks passed'
else
  puts "declared_join_check: #{failures.size} failure(s)"
  exit 1
end
