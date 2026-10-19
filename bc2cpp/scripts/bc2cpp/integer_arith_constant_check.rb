#!/usr/bin/env ruby
# frozen_string_literal: true

# Integer constant arithmetic typing (NUMERIC_CONSTANT_RANGES in the constant rows, docs/bc2cpp-type-check.md): a bare
# name whose every definition is integer arithmetic with a Fixnum interval is typed Integer (source
# inferred:integer-range), and the same name is refused when the program redefines an Integer operator (the owner
# scoped integer_ops_safe?, like DeclaredConstants.range_to_a_safe?). Each fixture is compiled by the host mrbc. The
# interval values and the operator predicate are checked in process; the typing is checked end to end, through
# type_check.rb --files, which is the analysis a build runs. Needs MRBC (a host mrbc); without it the check prints
# SKIP and exits 0.
#
#   MRBC=path/to/host/mrbc ruby scripts/bc2cpp/integer_arith_constant_check.rb

require 'json'
require 'open3'
require 'set'
require 'tmpdir'
require_relative '../../tools/bc2cpp/bc2cpp'

unless ENV['MRBC'] && File.executable?(ENV['MRBC'])
  puts 'SKIP integer_arith_constant_check: MRBC is not set to a host mrbc'
  exit 0
end

ROOT = File.expand_path('../..', __dir__)
TYPE_CHECK = File.join(ROOT, 'scripts/bc2cpp/type_check.rb')

failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

# The constant row for bare name `bare` in a type_check JSON run, or nil.
row_for = lambda do |rows, bare|
  rows.find { |r| r['name'] == bare || r['name'].end_with?("::#{bare}") }
end

# A program's constant rows from the end-to-end analysis (type_check.rb --files, the closed world of that program).
# Its exit status is 1 whenever a declared engine signature has no assignment in the fixture; the rows still stand.
typed_rows = lambda do |source|
  Dir.mktmpdir do |dir|
    rb = File.join(dir, 'fixture.rb')
    out = File.join(dir, 'facts.json')
    File.write(rb, source)
    _stdout, stderr, status = Open3.capture3({ 'MRBC' => ENV['MRBC'] }, RbConfig.ruby, TYPE_CHECK,
                                             '--files', rb, '--no-sends', '--format', 'json', '--out', out, '-q')
    unless File.exist?(out)
      warn stderr
      raise "type_check.rb wrote no JSON (exit #{status.exitstatus})"
    end

    JSON.parse(File.read(out))['constants']
  end
end

# The interval proof and the operator predicate over one program, in process.
analysis = lambda do |source|
  Dir.mktmpdir do |dir|
    rb = File.join(dir, 'fixture.rb')
    File.write(rb, source)
    ireps, root = compile_ireps([rb], 'integer_arith', dir)
    registry, _superclass_of, _containers, included, prepended, unknown = build_registry(ireps, root)
    safe = IntegerConstantRanges.integer_ops_safe?(registry, included, prepended, unknown)
    # FREEZE_SELF: the same owner-scoped proof the build passes (bc2cpp.rb), not a copy of it.
    freeze_safe = DeclaredConstants.stock_method?('freeze', 'Integer', registry, included, prepended, unknown)
    {
      safe: safe,
      freeze_safe: freeze_safe,
      ranges: IntegerConstantRanges.analyze(ireps, [], [], operators_safe: safe, freeze_safe: freeze_safe),
      refused: IntegerConstantRanges.analyze(ireps, [], [], operators_safe: false),
      # The exact-value proof with the operator gate bypassed, and with the gate as the program sets it.
      ints_ungated: IntegerConstants.analyze(ireps, [], [], operators_safe: true),
      ints_gated: IntegerConstants.analyze(ireps, [], [], operators_safe: safe)
    }
  end
end

positive = <<~RUBY
  module ZaIntArith
    ZA_BASE = 40
    ZA_STEP = 3
    ZA_SLOT = ZA_BASE - ZA_STEP
    ZA_COLS = ZA_SLOT / ZA_STEP + 1
    ZA_SPAN = ZA_STEP * ZA_COLS
    ZA_HALF = -7 / 2
    ZA_NONLIT = ZA_BASE + "abc".length
    ZA_BIG = 1073741823 + 1
  end
  module ZaWidth
    ZA_W = 320
  end
  module ZaWidthSmall
    ZA_W = 24
  end
  module ZaRangeOnly
    ZA_SLOT_RANGE = ZA_W - 4
  end
RUBY

puts '== positive: literals and named constants (exact values and intervals)'
pos = analysis.call(positive)
check.call('the operators are the core ones (no Ruby definition on Integer)', pos[:safe])
check.call('ZA_SLOT (= 40 - 3) has the interval [37, 37]', pos[:ranges]['ZA_SLOT'] == [37, 37])
check.call('ZA_COLS (= ZA_SLOT / ZA_STEP + 1) has the interval [13, 13]', pos[:ranges]['ZA_COLS'] == [13, 13])
check.call('ZA_SPAN (= ZA_STEP * ZA_COLS) has the interval [39, 39]', pos[:ranges]['ZA_SPAN'] == [39, 39])
check.call('ZA_NONLIT (a send operand) has no interval', !pos[:ranges].key?('ZA_NONLIT'))
check.call('ZA_BIG (1073741824) is outside the narrowest Fixnum range: no interval', !pos[:ranges].key?('ZA_BIG'))
check.call('ZA_SLOT_RANGE (= ZA_W - 4, ZA_W bound to 320 and 24) has the hull [20, 316]',
           pos[:ranges]['ZA_SLOT_RANGE'] == [20, 316])

puts '== floor division: -7 / 2 is -4 (mrb_div_int floors), not -3'
check.call('ZA_HALF has the interval [-4, -4]', pos[:ranges]['ZA_HALF'] == [-4, -4])

puts '== positive, end to end: arithmetic typed Integer'
rows = typed_rows.call(positive)
slot = row_for.call(rows, 'ZA_SLOT')
check.call('ZA_SLOT is typed Integer', slot && slot['type'] == 'Integer')
check.call('ZA_SPAN is typed Integer', (r = row_for.call(rows, 'ZA_SPAN')) && r['type'] == 'Integer')
half = row_for.call(rows, 'ZA_HALF')
check.call('ZA_HALF (floor division) is typed Integer', half && half['type'] == 'Integer')
range_only = row_for.call(rows, 'ZA_SLOT_RANGE')
# The IR (ADR 0501) admits an interval-only name as a Fixnum constant, so its row comes from the integer-constant set.
check.call('ZA_SLOT_RANGE (no single value, interval only) is typed Integer by inferred:integer-constant',
           range_only && range_only['type'] == 'Integer' && range_only['source'] == 'inferred:integer-constant')
nonlit = row_for.call(rows, 'ZA_NONLIT')
check.call('ZA_NONLIT (non-literal operand) stays untyped', nonlit && nonlit['type'].nil?)
big = row_for.call(rows, 'ZA_BIG')
# inferred:class-pool types any constant whose assignments are Integer-class (a bignum is still an Integer); what this
# proof refuses is the Fixnum interval, so the row must not come from inferred:integer-range.
check.call('ZA_BIG (outside the Fixnum range) gets no Fixnum interval',
           big && big['source'] != 'inferred:integer-range')

redefined = <<~RUBY
  class Integer
    def -(other)
      self
    end
  end
  module ZaIntArith
    ZA_BASE = 40
    ZA_STEP = 3
    ZA_SLOT = ZA_BASE - ZA_STEP
  end
  module ZaWidth
    ZA_W = 320
  end
  module ZaWidthSmall
    ZA_W = 24
  end
  module ZaRangeOnly
    ZA_SLOT_RANGE = ZA_W - 4
  end
RUBY

puts '== a program redefining Integer#- is refused'
red = analysis.call(redefined)
check.call('integer_ops_safe? is false (a Ruby def of - on Integer)', !red[:safe])
check.call('no interval is proven for any name', red[:ranges].empty? && red[:refused].empty?)
rows = typed_rows.call(redefined)
slot = row_for.call(rows, 'ZA_SLOT')
check.call('ZA_SLOT (= ZA_BASE - ZA_STEP) stays untyped', slot && slot['type'].nil?)
range_only = row_for.call(rows, 'ZA_SLOT_RANGE')
check.call('ZA_SLOT_RANGE stays untyped', range_only && range_only['type'].nil?)
check.call('the exact-value proof admits ZA_SLOT only because the gate is bypassed',
           red[:ints_ungated].include?('ZA_SLOT') && !red[:ints_gated].include?('ZA_SLOT'))
check.call('the exact-value proof still admits the literal ZA_BASE under the gate', red[:ints_gated].include?('ZA_BASE'))
base = row_for.call(rows, 'ZA_BASE')
check.call('a literal name (ZA_BASE) is still typed Integer', base && base['type'] == 'Integer')

prepended = <<~RUBY
  module ZaExt
    def -(other)
      self
    end
  end
  class Integer
    prepend ZaExt
  end
  module ZaIntArith
    ZA_BASE = 40
    ZA_STEP = 3
    ZA_SLOT = ZA_BASE - ZA_STEP
  end
RUBY

puts '== a module prepended into Integer is refused'
pre = analysis.call(prepended)
check.call('integer_ops_safe? is false (a prepend into Integer)', !pre[:safe])
rows = typed_rows.call(prepended)
slot = row_for.call(rows, 'ZA_SLOT')
check.call('ZA_SLOT stays untyped', slot && slot['type'].nil?)

frozen = <<~RUBY
  module ZaFreeze
    ZF_BASE = 40
    ZF_STEP = 3
    ZF_NONE = 0
    ZF_SLOT = (ZF_BASE - ZF_STEP).freeze
    ZF_SPAN = (ZF_STEP * 13).freeze
    ZF_HALF = (-7 / 2).freeze
    ZF_ZERO = (ZF_BASE / ZF_NONE).freeze
    ZF_NONLIT = (ZF_BASE + "abc".length).freeze
    ZF_STR = "abc".freeze
    ZF_ARR = [1, 2].freeze
    ZF_SUM = (ZF_ARR + [3]).freeze
  end
RUBY

puts '== freeze returns its receiver: a frozen Integer expression keeps its interval'
fr = analysis.call(frozen)
check.call('freeze is stock on Integer (no Ruby freeze on its ancestors)', fr[:freeze_safe])
check.call('ZF_SLOT (= (ZF_BASE - ZF_STEP).freeze) has the interval [37, 37]', fr[:ranges]['ZF_SLOT'] == [37, 37])
check.call('ZF_SPAN (= (ZF_STEP * 13).freeze) has the interval [39, 39]', fr[:ranges]['ZF_SPAN'] == [39, 39])
check.call('ZF_HALF (= (-7 / 2).freeze) has the interval [-4, -4]', fr[:ranges]['ZF_HALF'] == [-4, -4])
check.call('ZF_ZERO (divisor interval holds 0) has no interval', !fr[:ranges].key?('ZF_ZERO'))
check.call('ZF_NONLIT (a send operand) has no interval', !fr[:ranges].key?('ZF_NONLIT'))
rows = typed_rows.call(frozen)
slot = row_for.call(rows, 'ZF_SLOT')
check.call('ZF_SLOT is typed Integer by inferred:integer-constant end to end (ADR 0501)',
           slot && slot['type'] == 'Integer' && slot['source'] == 'inferred:integer-constant')
zero = row_for.call(rows, 'ZF_ZERO')
check.call('ZF_ZERO (zero divisor) stays untyped', zero && zero['type'].nil?)
nonlit = row_for.call(rows, 'ZF_NONLIT')
check.call('ZF_NONLIT (non-literal operand) stays untyped', nonlit && nonlit['type'].nil?)
arr = row_for.call(rows, 'ZF_ARR')
check.call('a frozen literal keeps its class (ZF_ARR is Array)', arr && arr['type'] == 'Array')
sum = row_for.call(rows, 'ZF_SUM')
check.call('a frozen sum of frozen Arrays is Array (inferred:array-sum)', sum && sum['type'] == 'Array')
str = row_for.call(rows, 'ZF_STR')
check.call('a frozen String literal keeps its class (ZF_STR is String)', str && str['type'] == 'String')

freeze_integer = <<~RUBY
  class Integer
    def freeze
      self
    end
  end
  module ZaFreeze
    ZF_BASE = 40
    ZF_STEP = 3
    ZF_SLOT = (ZF_BASE - ZF_STEP).freeze
  end
RUBY

puts '== a Ruby freeze on Integer withdraws the freeze-through proof'
fi = analysis.call(freeze_integer)
check.call('freeze_safe is false (a Ruby freeze on Integer)', !fi[:freeze_safe])
check.call('ZF_SLOT has no interval without the freeze proof', !fi[:ranges].key?('ZF_SLOT'))
fi_slot = row_for.call(typed_rows.call(freeze_integer), 'ZF_SLOT')
check.call('ZF_SLOT is not typed by inferred:integer-range',
           fi_slot.nil? || fi_slot['source'] != 'inferred:integer-range')

freeze_object = <<~RUBY
  class Object
    def freeze
      self
    end
  end
  module ZaFreeze
    ZF_STR = "abc".freeze
    ZF_SLOT = (3 - 1).freeze
  end
RUBY

puts '== a Ruby freeze on Object withdraws the freeze-through proof for a frozen String and Integer'
fo = analysis.call(freeze_object)
check.call('freeze_safe is false (a Ruby freeze on Object, an ancestor of Integer)', !fo[:freeze_safe])
check.call('ZF_SLOT has no interval', !fo[:ranges].key?('ZF_SLOT'))
ostr = row_for.call(typed_rows.call(freeze_object), 'ZF_STR')
check.call('ZF_STR (frozen String) is untyped while Object#freeze is redefined', ostr && ostr['type'].nil?)

puts
if failures.empty?
  puts 'integer_arith_constant_check: all checks passed'
else
  puts "integer_arith_constant_check: #{failures.size} check(s) failed"
  exit 1
end
