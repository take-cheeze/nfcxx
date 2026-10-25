#!/usr/bin/env ruby
# frozen_string_literal: true

# Constant proofs: declared Array sums, declared values across joins, and lexical holders,
# superclasses and mixins across joins. Every fixture has its own compiled program; core-method replacements and
# duplicate constant names must not change another fixture's world. Assertions retain their individual labels.
#
#   MRBC=path/to/host/mrbc ruby scripts/bc2cpp/constant_proofs_check.rb

require 'set'
require_relative 'check_support'
require_relative '../../tools/bc2cpp/bc2cpp'

suite = FixtureCheck.new('constant_proofs_check')
suite.require_mrbc!
check = suite.method(:check)
compile = suite.method(:compile)

# The declared gate and report rows use the same registry and core-method assumptions.
declared = lambda do |source, sig|
  compile.call(source) do |ireps, root, dir|
    rbs = File.join(dir, 'fixture.rbs')
    File.write(rbs, sig)
    registry, superclass_of, container_constants, included, prepended, unknown, _structs, _decls, _walked, _ivars,
      sites, = build_registry(ireps, root)
    # The mruby core definitions bc2cpp.rb adds from NATIVE_SRCS: without them no `+` or `freeze` is the core one.
    %w[+ freeze].each { |name| registry[name] << MethodDef.new(name: name, owner: '<native>', irep: nil, visibility: :public) }
    plus_safe = DeclaredConstants.array_sum_safe?(registry, superclass_of, prepended, unknown)
    range_safe = DeclaredConstants.range_to_a_safe?(registry, included, prepended, unknown)
    entries = DeclaredConstants.load([rbs], dir, registry.values.flatten.map(&:owner).to_set)
    result = DeclaredConstants.check(entries, ireps, registry, sites, Set.new, Set.new, container_constants, dir,
                                     plus_safe: plus_safe, range_safe: range_safe)
    rows = DeclaredConstants.array_sum_names(ireps, sites, registry, container_constants, plus_safe,
                                             range_safe: range_safe)
    {
      errors: result.diagnostics.select { |d| d[:severity] == 'error' }.map { |d| d[:message] },
      report: result.report.join("\n"),
      containers: result.containers,
      integer_names: result.integer_names,
      integer_keys: result.integer_keys,
      rows_sum: rows.key?('X'),
      ireps: ireps,
      sites: sites
    }
  end
end

sig = "X: Array\n"

# The sum needs both operands proven Array, so the declared Array on the frozen sum passes exactly where the rows
# type X as Array.
puts '== declared Array on a sum'
sum = declared.call("A = [1, 2]\nB = [3]\nX = (A + B).freeze\n", sig)
check.call('declared X: Array on (A + B).freeze passes (no TC1011 error)', sum[:errors].empty?)
check.call('the declared fact is Array (X is a container of class Array)', sum[:containers]['X'] == 'Array')
check.call('the rows type X as an array sum too (same proof)', sum[:rows_sum])
check.call('the report says checked, fact', sum[:report].include?('DECLARED_CONST X: Array: checked, fact'))

nested = declared.call("A = [1]\nB = [2]\nY = (A + B).freeze\nX = (Y + B).freeze\n", sig)
check.call('a sum over another proven sum passes', nested[:errors].empty? && nested[:rows_sum])

unfrozen = declared.call("A = [1]\nB = [2]\nX = A + B\n", sig)
check.call('an unfrozen A + B passes with the same proof as the rows', unfrozen[:errors].empty? && unfrozen[:rows_sum])

# Withholding: the sum proof is off whenever Ruby can replace Array#+ or Object#freeze, so the declared check fails too.
puts '== withheld when Ruby can replace the core method'
plus = declared.call("class Array\n  def +(other)\n    [self]\n  end\nend\nA = [1, 2]\nB = [3]\nX = (A + B).freeze\n", sig)
check.call('a program `class Array; def +` still fails the declared Array check',
           plus[:errors].any? { |m| m.include?('the assigned value is not a proven Array') })
check.call('the rows do not type it as an array sum either', !plus[:rows_sum])

frozen = declared.call("class Object\n  def freeze\n    self\n  end\nend\nA = [1, 2]\nB = [3]\nX = (A + B).freeze\n", sig)
check.call('a program `def freeze` still fails the declared Array check',
           frozen[:errors].any? { |m| m.include?('the assigned value is not a proven Array') })
check.call('the rows do not type it as an array sum either', !frozen[:rows_sum])

# Operands must each prove Array: a String or an Integer operand is not a sum of Arrays.
puts '== non-Array operands'
strings = declared.call("A = 'a'\nB = 'b'\nX = (A + B).freeze\n", sig)
check.call('a String sum fails the declared Array check',
           strings[:errors].any? { |m| m.include?('the assigned value is not a proven Array') })
check.call('the rows do not type it as an array sum either', !strings[:rows_sum])

mixed = declared.call("A = [1]\nB = 2\nX = (A + B).freeze\n", sig)
check.call('an Array plus an Integer fails the declared Array check',
           mixed[:errors].any? { |m| m.include?('the assigned value is not a proven Array') })
check.call('the rows do not type it as an array sum either', !mixed[:rows_sum])

# Range#to_a operands (range_to_a_source?, withheld unless range_to_a_safe?): the operand is an inline literal
# `(lo..hi).to_a`, not a constant bound to one (the proof does not follow constants). The declared check and the rows agree.
puts '== Range#to_a operands'
range = declared.call("X = (('a'..'c').to_a + (1..2).to_a).freeze\n", sig)
check.call('a sum of two inline literal Range#to_a passes the declared Array check', range[:errors].empty?)
check.call('the rows type it as an array sum too (same proof)', range[:rows_sum])

redefined = declared.call("class Range\n  def to_a\n    1\n  end\nend\nX = (('a'..'c').to_a + [1]).freeze\n", sig)
check.call('a program `class Range; def to_a` fails the declared Array check',
           redefined[:errors].any? { |m| m.include?('the assigned value is not a proven Array') })
check.call('the rows do not type it as an array sum either', !redefined[:rows_sum])


# [irep, index, source register] of the top-level SETCONST of +name+.
setconst_of = lambda do |ireps, name|
  ireps.each_value.flat_map do |irep|
    irep.instructions.each_with_index.filter_map do |insn, idx|
      [irep, idx, insn.regs.last] if insn.op == :SETCONST && insn.const_name == name
    end
  end.first
end

gate = 'the declared element type needs a frozen array literal'

puts '== a frozen Array[Integer] literal on a join'
# The element check reads the one literal the frozen-array gate (JOIN_DOMINANCE) lets through, so a join is refused there.
plain = declared.call("C5 = [1, 2].freeze\n", "C5: Array[Integer]\n")
check.call('C5 = [1, 2].freeze passes Array[Integer] (no join: the element check runs)', plain[:errors].empty?)

mixed = declared.call("c = Time.now.year > 0\nC2 = (c ? [2.0] : [1]).freeze\n", "C2: Array[Integer]\n")
check.call('C2 = (c ? [2.0] : [1]).freeze is refused (the frozen-array gate does not prove a join)',
           mixed[:errors].any? { |m| m.include?(gate) })

same = declared.call("c = Time.now.year > 0\nC3 = (c ? [1] : [2]).freeze\n", "C3: Array[Integer]\n")
check.call('C3 = (c ? [1] : [2]).freeze is refused the same way, though both arms are Integer literals',
           same[:errors].any? { |m| m.include?(gate) })

# Every reaching value must be a frozen literal: a freeze on one arm only, or a freeze of a different element type on
# the other arm, must not be judged by the nearest freeze alone.
one_arm = declared.call("c = Time.now.year > 0\nt = Time.now.year.to_s\nt = [1].freeze if c\nC7 = t\n", "C7: Array[Integer]\n")
check.call('C7 refuses a String reaching the constant beside a frozen Integer arm',
           one_arm[:errors].any? { |m| m.include?('a frozen array literal') })
symbol_first = declared.call("c = Time.now.year > 0\nt = [:a].freeze\nt = [1].freeze if c\nC10 = t\n", "C10: Array[Integer]\n")
check.call('C10 refuses a Symbol literal reaching the constant beside an Integer literal',
           symbol_first[:errors].any? { |m| m.include?('not proven Integer') })
moved = declared.call("t = [1].freeze\nC8 = t\n", "C8: Array[Integer]\n")
check.call('C8 = t, a frozen Integer literal through a move, passes', moved[:errors].empty?)
both_int = declared.call("c = Time.now.year > 0\nt = [1].freeze\nt = [2].freeze if c\nC9 = t\n", "C9: Array[Integer]\n")
check.call('C9 passes when every reaching freeze is an Integer literal', both_int[:errors].empty?)

puts '== frozen_at? on a join'
frozen = declared.call("c = Time.now.year > 0\nF1 = (c ? [1].freeze : [2])\nF2 = (c ? [2] : [1].freeze)\n", '')
f1 = setconst_of.call(frozen[:ireps], 'F1')
f2 = setconst_of.call(frozen[:ireps], 'F2')
check.call('frozen_at? holds for F1, whose then arm is a .freeze result (the other arm is not)',
           DeclaredConstants.frozen_at?(f1[0], f1[1], f1[2]))
check.call('frozen_at? holds for F2, whose else arm is a .freeze result',
           DeclaredConstants.frozen_at?(f2[0], f2[1], f2[2]))

puts '== bool_compare_site? on a join'
bool = declared.call("c = Time.now.year > 0\nB1 = (c ? nil : ('abc'.length == 3))\nB2 = ('abc'.length == 3)\n", '')
b1 = setconst_of.call(bool[:ireps], 'B1')
b2 = setconst_of.call(bool[:ireps], 'B2')
check.call('B1 = (c ? nil : (\'abc\'.length == 3)) is not a bool: its then arm is nil',
           !DeclaredConstants.bool_compare_site?(b1[0], b1[1], b1[2], string_length_safe: true, integer_ops_safe: true))
check.call('B2 = (\'abc\'.length == 3) is a bool compare (straight line)',
           DeclaredConstants.bool_compare_site?(b2[0], b2[1], b2[2], string_length_safe: true, integer_ops_safe: true))

puts '== Fixnum evaluation on a join (kept refused)'
# A runtime addend keeps the ADD (mrbc folds a literal one). The 10000000000 arm is a bignum, and the 1 arm is a jump target,
# so the Evaluator's walk stops there and refuses; a Fixnum proof from the else arm alone would be wrong.
big = declared.call("c = Time.now.year > 0\nn = Time.now.year\nBIG = (c ? 10000000000 : 1) + n\n", "BIG: Integer\n")
check.call('BIG: Integer is refused for a ternary whose arm is outside the Fixnum margin',
           big[:errors].any? { |m| m.include?('the assigned value is not a proven Fixnum expression') })

puts '== an alias of a same-named constant (SELF_COPY)'
# `X = A::X` copies a value another binding of bare X stored, so the union over the other bindings still bounds X.
alias_ok = declared.call("module A; X = 16; end\nmodule B; X = A::X; end\n", "module A\n  X: Integer\nend\n")
check.call('A::X: Integer proves through B::X = A::X', alias_ok[:errors].empty? &&
           alias_ok[:integer_names].include?('X'))
alias_bad = declared.call("module A; X = 16; end\nmodule B; X = A::X; end\nmodule C; X = 'a'; end\n",
                          "module A\n  X: Integer\nend\n")
check.call('a non-Integer X elsewhere still withholds the fact', alias_bad[:errors].empty? &&
           !alias_bad[:integer_names].include?('X'))
only_copy = declared.call("module A; X = 16; end\nmodule B; X = A::X; end\n", "module B\n  X: Integer\nend\n")
check.call('B::X: Integer (the copy itself) proves too', only_copy[:errors].empty? &&
           only_copy[:integer_names].include?('X'))


# [op, name, key] of every GETCONST/GETMCNST read of the fixture, in instruction order of each irep.
reads_of = lambda do |source|
  compile.call(source) do |ireps, _root, _dir|
    info = LexicalConsts.analyze(ireps, static: true)
    reads = []
    ireps.each_value do |irep|
      irep.instructions.each do |insn|
        reads << [insn.op, insn.const_name, info.read_keys[insn]] if %i[GETCONST GETMCNST].include?(insn.op)
      end
    end
    reads
  end
end

puts '== a same-named constant in another scope (lexical, like the runtime)'
# A::X proves on its own assignment; C::X = 'a' only withholds the bare-name fact, as reads resolve per scope.
scoped_src = "module A; X = 16; def self.f; X; end; end\nmodule C; X = 'a'; def self.f; X; end; end\n"
scoped = declared.call(scoped_src, "module A\n  X: Integer\nend\n")
check.call('A::X: Integer proves beside a String C::X (no TC1011 error)', scoped[:errors].empty?)
check.call('the fact is keyed by the definition A::X, not the bare name X',
           scoped[:integer_keys].include?('A::X') && !scoped[:integer_names].include?('X'))
site_keys = LexicalConsts.analyze(scoped[:ireps], static: true).site_keys
check.call('LEXICAL_CONST qualifies the fact\'s own SETCONST as A::X too (bc2cpp.rb keeps the key)',
           site_keys[scoped[:integer_keys]['A::X']] == 'A::X')
scoped_reads = reads_of.call(scoped_src).select { |op, name,| op == :GETCONST && name == 'X' }.map(&:last)
check.call('the X read in A resolves to A::X and the one in C to C::X', scoped_reads.sort == %w[A::X C::X])

puts '== a scoped read through a ternary holder'
holder = reads_of.call(<<~RUBY)
  module A2; X = 1; end
  module B2; X = 2; end
  c = Time.now.year > 0
  def pick; (c ? A2 : B2)::X; end
RUBY
check.call('(c ? A2 : B2)::X is refused: the arms name different holders, and A2::X is reachable',
           holder.include?([:GETMCNST, 'X', nil]) && !holder.include?([:GETMCNST, 'X', 'B2::X']))

agree = reads_of.call(<<~RUBY)
  module A3; X = 1; end
  module B3; X = 2; end
  c = Time.now.year > 0
  def pick; (c ? A3 : A3)::X; end
RUBY
check.call('(c ? A3 : A3)::X resolves: both arms name A3, so the holder is one definition',
           agree.include?([:GETMCNST, 'X', 'A3::X']))

puts '== a superclass that is a ternary'
super_arm = reads_of.call(<<~RUBY)
  class B0; W = 2; end
  W = 1
  c = Time.now.year > 0
  class S0 < (c ? B0 : nil)
    def f; W; end
  end
RUBY
check.call('W in S0 is refused: the superclass arm B0 supplies B0::W ahead of the top-level W',
           super_arm.include?([:GETCONST, 'W', nil]) && !super_arm.include?([:GETCONST, 'W', 'W']))

puts '== a mixin argument that is a ternary'
mixin_arm = reads_of.call(<<~RUBY)
  U = 0
  module A1; U = 1; end
  module B1; end
  c = Time.now.year > 0
  class C1
    include(c ? A1 : B1)
    def f; U; end
  end
RUBY
check.call('U in C1 is refused: the included arm A1 supplies A1::U ahead of the top-level U',
           mixin_arm.include?([:GETCONST, 'U', nil]) && !mixin_arm.include?([:GETCONST, 'U', 'U']))

mixin_agree = reads_of.call(<<~RUBY)
  U = 0
  module B4; end
  c = Time.now.year > 0
  class C4
    include(c ? B4 : B4)
    def f; U; end
  end
RUBY
check.call('U in C4 resolves when both arms include B4 (a module that does not define U)',
           mixin_agree.include?([:GETCONST, 'U', 'U']))


# The receiver of a send is a constant on every path only when one write reaches it. A loop back-edge from after the
# send can carry a second write (`x = Beta`), which the straight-line walk alone cannot see.
receiver_at_send = lambda do |source|
  gen = CodeGen.allocate
  answers = []
  compile.call(source) do |ireps, _root, _dir|
    ireps.each_value do |irep|
      irep.instructions.each_with_index do |insn, idx|
        next unless insn.op.to_s.start_with?('SEND') && insn.sym == 'foo'

        answers << [gen.send(:straight_line_constant_name, irep, idx, insn.reg), irep.agreed_constant_name(idx, insn.reg)]
      end
    end
  end
  answers.first
end
check.call('a loop back-edge write refuses the straight-line receiver constant',
           receiver_at_send.call("def probe(c)\n  x = Alpha\n  while c\n    x.foo\n    x = Beta\n  end\nend\n") == [nil, nil])
check.call('a straight-line receiver constant still resolves',
           receiver_at_send.call("def probe(c)\n  x = Alpha\n  x.foo\nend\n") == ['Alpha', 'Alpha'])
# A send inside a rescue range must still resolve: the reaching-definition query runs through handler edges.
check.call('a receiver constant inside a rescue range still resolves',
           receiver_at_send.call("def probe(c)\n  x = Alpha\n  begin\n    x.foo\n  rescue StandardError\n    nil\n  end\nend\n").first == 'Alpha')

suite.finish!
