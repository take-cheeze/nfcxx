#!/usr/bin/env ruby
# frozen_string_literal: true

# RANGE_COMPARE_FOLD (tools/bc2cpp/codegen_decided_branch.rb): a conditional jump on the boolean of LT/LE/GT/GE is decided
# when the operands' integer intervals settle the comparison on every path. With BC2CPP_RANGE_FOLD=1 the fixture's nine
# decidable jumps fold (four taken, five not taken) and its five undecided ones keep their test. With the gate off no
# range fold is emitted and every test stays. Needs MRBC; without it the check prints SKIP and exits 0.
#
#   MRBC=path/to/host/mrbc ruby scripts/bc2cpp/range_compare_fold_check.rb

require 'set'
require_relative 'check_support'
require_relative '../../tools/bc2cpp/bc2cpp'

suite = FixtureCheck.new('range_compare_fold_check')
suite.require_mrbc!

SOURCE = <<~'RUBY'
  class Gate
    LO = 1
    HI = 10
    BIG = 100

    def check(x)
      r = 0
      r += 1 if LO < HI
      r += 2 if HI < LO
      r += 4 if BIG >= HI
      r += 8 unless LO > BIG
      r += 16 if LO <= HI
      r += 32 if HI > BIG
      r += 64 if LO >= BIG
      r += 128 if BIG > HI
      r += 256 unless LO < HI
      r
    end

    def kept(x)
      r = 0
      r += 1 if x < HI
      r += 2 if W < HI
      v = x ? LO : HI
      r += 4 if v < 5
      r += 8 if LO < x
      r
    end

    # `c` is overwritten inside the begin body, so the rescue's test may read `x`, not the comparison.
    def rescued(x)
      r = 0
      c = LO < HI
      begin
        c = x
        x.zork
      rescue
        r += 1 if c
      end
      r
    end
  end

  # W has two definitions, so its interval is the hull [1, 20] and `W < HI` is not decided.
  class Narrow
    W = 1
  end

  class Wide
    W = 20
  end
RUBY

# A Ruby redefinition of Integer#< makes the comparison's meaning unknown: the operator is no longer the core one.
REDEFINED_SOURCE = <<~'RUBY'
  class Integer
    def <(other)
      false
    end
  end

  class Gate
    LO = 1
    HI = 10

    def check(x)
      r = 0
      r += 1 if LO < HI
      r
    end
  end
RUBY

# The generated C++ of +owner+#+name+ compiled with the range fold gate set to +gate+ ('1' or nil).
method_code = lambda do |gate, source, name, owner|
  previous = ENV['BC2CPP_RANGE_FOLD']
  ENV['BC2CPP_RANGE_FOLD'] = gate
  suite.compile(source) do |ireps, root|
    registry = build_registry(ireps, root)[0]
    # The core operators and const_missing are mruby's own definitions, which bc2cpp.rb adds from NATIVE_SRCS.
    %w[+ - * / < <= > >= const_missing].each do |op|
      registry[op] << MethodDef.new(name: op, owner: '<native>', irep: nil, visibility: :public)
    end
    CodeGen.integer_constant_ranges = IntegerConstantRanges.analyze(
      ireps, Set.new, Set.new, operators_safe: IntegerConstantRanges.integer_ops_safe?(registry, {}, {}, Set.new)
    )
    gen = CodeGen.new(ireps, registry, {}, {}, {}, {}, {}, {}, {}, {}, {}, Set.new)
    closed_world = ClosedWorld.new(ireps: ireps, registry: registry, class_decls: {}, walked: Set.new,
                                   native_paths: [], ruby_paths: [])
    gen.instance_variable_set(:@closed_world, closed_world)
    method = registry.fetch(name).find { |d| d.owner == owner }
    gen.compile_method(method.irep).fetch(:code)
  end
ensure
  ENV['BC2CPP_RANGE_FOLD'] = previous
end

# A conditional jump in the generated code: the tests the fold removes, one per JMPIF/JMPNOT/JMPNIL.
tests = ->(code) { code.scan(/mrb_test\(|mrb_nil_p\(/).size }
range_folds = ->(code) { code.scan(/DECIDED_BRANCH (?:JMPIF|JMPNOT) R\d+: (?:taken|not taken)/).size }

on_check = method_code.call('1', SOURCE, 'check', 'Gate')
off_check = method_code.call(nil, SOURCE, 'check', 'Gate')
on_kept = method_code.call('1', SOURCE, 'kept', 'Gate')
off_kept = method_code.call(nil, SOURCE, 'kept', 'Gate')

puts '== decidable comparisons fold'
suite.check('nine range folds in check (four taken, five not taken)',
            range_folds.call(on_check) == 9 &&
            on_check.scan(/goto L\d+; \/\/ DECIDED_BRANCH (JMPIF|JMPNOT) R\d+: taken/).size == 4 &&
            on_check.scan(%r{// DECIDED_BRANCH (JMPIF|JMPNOT) R\d+: not taken}).size == 5)
suite.check('all nine decided tests are gone from check', tests.call(on_check) == 0)
suite.check('the taken JMPIF on a true comparison is a goto',
            on_check.match?(/goto L\d+; \/\/ DECIDED_BRANCH JMPIF R\d+: taken/))

puts '== undecided comparisons keep their test'
suite.check('no range fold in kept', range_folds.call(on_kept).zero?)
suite.check('all five tests of kept remain', tests.call(on_kept) == 5)
suite.check('the parameter comparison keeps its test', on_kept.include?('if (!mrb_test(r'))

# The rescue's test reads `c`, which the begin body may overwrite with `x`: it has no single comparison writer.
on_rescued = method_code.call('1', SOURCE, 'rescued', 'Gate')
suite.check('a comparison overwritten in a begin body keeps the rescue test', range_folds.call(on_rescued).zero? &&
            tests.call(on_rescued) >= 1)

puts '== gate'
suite.check('gate off: no DECIDED_BRANCH line in check', !off_check.include?('DECIDED_BRANCH'))
suite.check('gate off: all nine tests of check are emitted', tests.call(off_check) == 9)
suite.check('gate off: kept is the same as with the gate on', off_kept == on_kept)
suite.check('gate off: no range folds anywhere', range_folds.call(off_check).zero? && range_folds.call(off_kept).zero?)

puts '== a redefined Integer#< keeps every test'
redefined = method_code.call('1', REDEFINED_SOURCE, 'check', 'Gate')
suite.check('the comparison test stays with the gate on', tests.call(redefined) == 1)
suite.check('no range fold when Integer#< is redefined', range_folds.call(redefined).zero?)

suite.finish!
