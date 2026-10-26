#!/usr/bin/env ruby
# frozen_string_literal: true

# BYTECODE_CONSTANT_FACTS fixtures (tools/bc2cpp/bytecode_ir_constants.rb): each Ruby program is compiled by the host
# mrbc, its IREPs and constant sites are read by the registry, and BytecodeIR::ConstantFacts.analyze answers the class,
# exact value and Fixnum interval of every constant path and bare-name group. The expectations are the facts the
# IntegerConstants / IntegerConstantRanges proofs were tested for (literal, alias, arithmetic, join, poison, margin,
# operator gate), now read from the IR. Needs MRBC (a host mrbc); without it the check prints SKIP and exits 0.
#
#   MRBC=path/to/host/mrbc ruby scripts/bc2cpp/bytecode_ir_constants_check.rb

require 'set'
require_relative 'check_support'
require_relative '../../tools/bc2cpp/bc2cpp'
require_relative '../../tools/bc2cpp/bytecode_ir_constants'

suite = FixtureCheck.new('bytecode_ir_constants_check')
suite.require_mrbc!

check = suite.method(:check)

# Facts for one program: { paths: {path => Fact}, groups: {bare => Fact} } from the IR pass, with the operator gate
# the program sets (or forced off when +safe+ is false).
analyze = lambda do |source, safe: true|
  suite.compile(source) do |ireps, root|
    registry, _superclass_of, _containers, included, prepended, unknown, _structs, _decls, _walked, _ivars, sites = build_registry(ireps, root)
    operators_safe = safe && IntegerConstantRanges.integer_ops_safe?(registry, included, prepended, unknown)
    # The gate the build passes (bc2cpp.rb): stock Integer#freeze.
    freeze_safe = DeclaredConstants.stock_method?('freeze', 'Integer', registry, included, prepended, unknown)
    # The container gates the build passes (bc2cpp.rb): a stock freeze on Array, Hash or String answers its receiver.
    freeze_classes = %w[Array Hash String].select do |klass|
      DeclaredConstants.stock_method?('freeze', klass, registry, included, prepended, unknown)
    end.map(&:to_sym).to_set
    BytecodeIR::ConstantFacts.analyze(ireps, sites: sites, poisoned: Set.new, operators_safe: operators_safe,
                                             freeze_safe: freeze_safe, freeze_classes: freeze_classes)
  end
end

# The fact of a path (suffix match on the full lexical path) in a result.
fact_of = lambda do |result, path|
  result.paths.find { |p, _| p == path || p.end_with?("::#{path}") }&.last
end

positive = <<~RUBY
  module Fx
    BASE = 32
    TILE = BASE
    HALF = TILE / 2
    NEG = -7 / 2
    SPAN = BASE * 3 + 1
    NAME = "name"
    LIST = [1, 2]
    FROZEN = [1, 2].freeze
    RANGE = (1..3)
    FLOAT = 1.5
    BIG = 2_000_000_000
    BITS = BASE | 1
    FZ = BASE.freeze
  end
RUBY

result = analyze.call(positive)
tile = fact_of.call(result, 'Fx::TILE')
check.call('alias to a literal carries the value 32 and the interval [32, 32]',
           tile && tile.value == 32 && tile.interval == [32, 32] && tile.classes == Set[:Integer])
check.call('DIV floors: -7 / 2 is -4', fact_of.call(result, 'Fx::NEG')&.value == -4)
check.call('arithmetic over an alias: HALF = TILE / 2 is 16',
           fact_of.call(result, 'Fx::HALF')&.value == 16 && fact_of.call(result, 'Fx::HALF')&.interval == [16, 16])
check.call('SPAN = BASE * 3 + 1 is 97 with the interval [97, 97]',
           fact_of.call(result, 'Fx::SPAN')&.value == 97 && fact_of.call(result, 'Fx::SPAN')&.interval == [97, 97])
check.call("bit operator over a constant: BASE | 1 is 33, exact, with no interval",
           fact_of.call(result, "Fx::BITS")&.value == 33 && fact_of.call(result, 'Fx::BITS')&.interval.nil?)
check.call('String literal: class String, no value, no interval',
           (f = fact_of.call(result, 'Fx::NAME')) && f.classes == Set[:String] && f.value.nil? && f.interval.nil?)
check.call('Array literal: class Array',
           fact_of.call(result, 'Fx::LIST')&.classes == Set[:Array])
# A literal's `.freeze` answers its receiver when the container freeze is stock (freeze_classes): the class is Array and
# there is no value, since an Array is not an Integer.
check.call('frozen literal: a stock Array#freeze answers its receiver, so the binding is Array with no value',
           fact_of.call(result, 'Fx::FROZEN')&.classes == Set[:Array] && fact_of.call(result, 'Fx::FROZEN')&.value.nil?)
# A constructed value (`Color.new(...)`) is not modelled: the receiver is a class constant, whose name is poisoned by its
# CLASS op, so the binding has no class. It stays unknown until class identity is modelled.
constructed = analyze.call(<<~RUBY)
  module Ct
    CLR = Foo.new(1)
  end
RUBY
check.call('constructed value: Foo.new has no class (unknown, never a wrong class until class identity is modelled)',
           fact_of.call(constructed, 'Ct::CLR')&.classes.nil?)
check.call('Range literal: class Range', fact_of.call(result, 'Fx::RANGE')&.classes == Set[:Range])
check.call('Float literal: class Float, no value', (f = fact_of.call(result, 'Fx::FLOAT')) && f.classes == Set[:Float] && f.value.nil?)
check.call('Integer#freeze is the identity when stock: FZ = BASE.freeze is 32 with interval [32, 32]',
           fact_of.call(result, 'Fx::FZ')&.value == 32 && fact_of.call(result, 'Fx::FZ')&.interval == [32, 32])
check.call('fixnum_names admits TILE and not BIG (out of margin) or NAME (String)',
           result.fixnum_names.include?('TILE') && !result.fixnum_names.include?('BIG') &&
           !result.fixnum_names.include?('NAME'))
check.call('values and intervals report the group facts: TILE 32, HALF 16',
           result.values['TILE'] == 32 && result.intervals['HALF'] == [16, 16] && !result.values.key?('BIG'))
big = fact_of.call(result, 'Fx::BIG')
check.call('out-of-margin literal is Integer with no value and no interval (never folded as an immediate)',
           big && big.classes == Set[:Integer] && big.value.nil? && big.interval.nil?)

join_result = analyze.call(<<~RUBY)
  module Jn
    x = Object.new.frozen? ? 1 : 2
    LOW = x
  end
RUBY
low = fact_of.call(join_result, 'Jn::LOW')
check.call('a join of two literals is Integer with the hull interval [1, 2] and no single value',
           low && low.classes == Set[:Integer] && low.interval == [1, 2] && low.value.nil?)

poison = <<~RUBY
  class Pz
  end
  module Ps
    Pz = 5
  end
RUBY
poison_result = analyze.call(poison)
pz = poison_result.groups['Pz']
check.call('a CLASS of the bare name poisons the group: Pz has no class, value or interval for reads',
           pz && pz.classes.nil? && pz.value.nil? && pz.interval.nil?)

reassign_alias = <<~RUBY
  module Ra
    SRC = 10
    DST = SRC + 1
  end
  module Rb
    SRC = Ra::SRC
  end
RUBY
ra = analyze.call(reassign_alias)
check.call('bare-name group: two bindings of SRC merge into [10, 10]',
           ra.groups['SRC'] && ra.groups['SRC'].interval == [10, 10] && ra.groups['SRC'].value == 10)
check.call('alias of a group name gets the group value: DST = SRC + 1 is 11',
           fact_of.call(ra, 'Ra::DST')&.value == 11)

self_alias = <<~RUBY
  module Sa
    TILE = 16
  end
  module Sb
    TILE = Sa::TILE
  end
RUBY
sa = analyze.call(self_alias)
check.call('a binding whose only source is its own bare name is not a fact (self-alias dropped, cycle)',
           sa.groups['TILE']&.value == 16 && sa.groups['TILE']&.interval == [16, 16])

gated = analyze.call(positive, safe: false)
check.call('an Integer operator redefinition gates arithmetic: SPAN has no interval and no value',
           (f = fact_of.call(gated, 'Fx::SPAN')) && f.interval.nil? && f.value.nil?)
check.call('a literal alias survives the operator gate: TILE keeps value 32',
           fact_of.call(gated, 'Fx::TILE')&.value == 32)

overflow = <<~RUBY
  module Of
    A = 1_000_000_000
    B = A + A
  end
RUBY
of = analyze.call(overflow)
b = fact_of.call(of, 'Of::B')
check.call('an intermediate outside the Fixnum margin has no value and no interval (B = A + A)',
           b && b.value.nil? && b.interval.nil? && b.classes == Set[:Integer])

# Program#constant_path answers from reaching definitions when no barrier is given: a join of two constants is
# refused, where the textually nearest arm (the old answer) was Hash.
puts '-- constant_path through reaching definitions'
constant_path_source = <<~RUBY
  class CpJoin
    def pick(c)
      (c ? Array : Hash).new
    end

    def plain
      Array.new
    end

    def qualified
      Fx::Inner.new
    end

    def loop_scope(n)
      x = Outer
      while n > 0
        x = x::Inner
        n -= 1
      end
      x.new
    end
  end
RUBY

suite.compile(constant_path_source) do |ireps, root|
  registry = build_registry(ireps, root)[0]
  # The receiver of the method's one `new` send, read as the send's constant path (as strict_new_class does).
  path_of_new = lambda do |name|
    md = registry.fetch(name).find { |d| d.owner == 'CpJoin' }
    irep = ireps.fetch(md.irep)
    idx = irep.instructions.index { |i| %i[SEND SEND0 SENDB].include?(i.op) && i.sym == 'new' }
    [irep, idx, irep.instructions[idx].reg]
  end

  irep, idx, reg = path_of_new.call('pick')
  check.call('a join of Array and Hash has no constant path (the textual walk answered Hash)',
             BytecodeIR.for(irep).constant_path(idx - 1, reg, skip_ops: BytecodeIR::Ops::LEAD_READ_ONLY).nil?)

  irep, idx, reg = path_of_new.call('plain')
  plain = BytecodeIR.for(irep).constant_path(idx - 1, reg)
  check.call('a single GETCONST is its own constant path (Array, no segments, unqualified)',
             plain && plain.root == :const && plain.name == 'Array' && plain.segments.empty? && !plain.qualified)

  irep, idx, reg = path_of_new.call('qualified')
  qualified = BytecodeIR.for(irep).constant_path(idx - 1, reg)
  check.call('Fx::Inner is rooted at Fx with the Inner segment, qualified',
             qualified && qualified.name == 'Fx' && qualified.segments == ['Inner'] && qualified.qualified)

  irep, idx, reg = path_of_new.call('loop_scope')
  check.call('a scope rebound inside a loop has no constant path (Outer on entry, Outer::Inner after one pass)',
             BytecodeIR.for(irep).constant_path(idx - 1, reg).nil?)

  # Barrier callers (codegen_receiver_facts) keep the textual walk: their barrier ops are the proof.
  irep, idx, reg = path_of_new.call('pick')
  barrier = BytecodeIR.for(irep).constant_path(idx - 1, reg, skip_ops: BytecodeIR::Ops::LEAD_READ_ONLY,
                                                                  barrier: %i[JMPUW])
  check.call('a barrier caller keeps the textual walk (nearest arm Hash; codegen asks every definition itself)',
             barrier&.name == 'Hash')
end

suite.finish!
