#!/usr/bin/env ruby
# frozen_string_literal: true

# Constant typing: frozen containers, Hash merges, Array sums and integer arithmetic. Compatible positives share
# one end-to-end type_check.rb run; Object#freeze withdrawal shares another. Other method redefinitions each stay
# in their own closed world. Integer interval and operator predicates are also checked independently in process.
#
#   MRBC=path/to/host/mrbc ruby scripts/bc2cpp/constant_typing_check.rb

require 'set'
require 'tmpdir'
require_relative '../../tools/bc2cpp/bc2cpp'
require_relative 'type_check_fixture'

unless ENV['MRBC'] && File.executable?(ENV['MRBC'])
  puts 'SKIP constant_typing_check: MRBC is not set to a host mrbc'
  exit 0
end

failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

# Empty signatures make fixture diagnostics meaningful: engine-only declarations do not belong to these programs.
typed_rows = lambda do |source, cli: false|
  Dir.mktmpdir('constant-typing') do |dir|
    rb = File.join(dir, 'fixture.rb')
    out = File.join(dir, 'facts.json')
    sig = File.join(dir, 'sig')
    Dir.mkdir(sig)
    File.write(rb, source)
    report = if cli
               TypeCheckFixture.report(dir, files: [rb], options: ['--sig', sig], out: out,
                                       label: 'constant typing')
             else
               TypeCheckFixture.facts_report(dir, files: [rb], env: { 'BC2CPP_SIG_DIRS' => sig },
                                             label: 'constant typing')
             end
    report.fetch('constants')
  end
end
container_rows = lambda do |rows|
  rows.to_h { |row| [row.fetch('name'), [row['type'], row['source'], row['reason']]] }
end
row_for = lambda do |rows, bare|
  rows.find { |r| r['name'] == bare || r['name'].end_with?("::#{bare}") }
end

BASE = <<~RUBY
  module Gfx
    def self.freeze
      nil
    end
  end
  FROZEN_ARR = [1, 2].freeze
  FROZEN_HASH = { a: 1 }.freeze
  LIT_MERGE = { a: 1 }.merge({ b: 2 })
  MERGE_BASE = { 11 => 1 }
  CONST_MERGE = MERGE_BASE.merge({ 12 => 2 })
  KANA = (%w[a b] + [:t, nil]).freeze
  SUM = (KANA + %w[c]).freeze
  def go
    [FROZEN_ARR, FROZEN_HASH, LIT_MERGE, CONST_MERGE, SUM]
  end
  go
RUBY

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

puts '== shared end-to-end positives: containers and integer arithmetic'
# This unknown receiver adds no method definitions, so it cannot withdraw the positive proofs.
unknown_merge = "X_MERGE = $unproven.merge({ b: 2 })\n"
positive_rows = typed_rows.call(BASE + positive + frozen + unknown_merge, cli: true)

puts '== positives: stock owners, a foreign Ruby freeze'
rows = container_rows.call(positive_rows)
check.call('a frozen Array literal is Array', rows['FROZEN_ARR']&.first(2) == ['Array', 'inferred:constructed'])
check.call('a frozen Hash literal is Hash', rows['FROZEN_HASH']&.first(2) == ['Hash', 'inferred:constructed'])
check.call('a Hash literal merge is Hash', rows['LIT_MERGE']&.first(2) == ['Hash', 'inferred:hash-merge'])
check.call('a Hash merge of a constant Hash is Hash', rows['CONST_MERGE']&.first(2) == ['Hash', 'inferred:hash-merge'])
check.call('an Array sum that is frozen is Array', rows['SUM']&.first(2) == ['Array', 'inferred:array-sum'])
check.call('the sum over a frozen sum is Array', rows['KANA']&.first(2) == ['Array', 'inferred:array-sum'])

negatives = {
  'Array#freeze defined in Ruby' => [
    "class Array\n  def freeze\n    self\n  end\nend\n",
    %w[FROZEN_ARR KANA SUM]
  ],
  'a module mixed into Hash defines freeze' => [
    "module Frz\n  def freeze\n    self\n  end\nend\nclass Hash\n  include Frz\nend\n",
    %w[FROZEN_HASH]
  ],
  'a module prepended to Array defines freeze' => [
    "module Frz\n  def freeze\n    self\n  end\nend\nclass Array\n  prepend Frz\nend\n",
    %w[FROZEN_ARR KANA SUM]
  ],
  'an unresolved mixin into Hash' => [
    "class Hash\n  include NoSuchMixinAnywhere\nend\n",
    %w[FROZEN_HASH LIT_MERGE CONST_MERGE]
  ],
  'a Hash prepend (merge and freeze)' => [
    "module MergeP\n  def merge(other)\n    {}\n  end\nend\nclass Hash\n  prepend MergeP\nend\n",
    %w[FROZEN_HASH LIT_MERGE CONST_MERGE]
  ],
  'Hash#merge redefined in Ruby' => [
    "class Hash\n  def merge(other)\n    1\n  end\nend\n",
    %w[LIT_MERGE CONST_MERGE]
  ],
  'a singleton merge on the constant receiver' => [
    "MERGE_BASE_S = { 11 => 1 }\ndef MERGE_BASE_S.merge(other)\n  {}\nend\nSINGLE_MERGE = MERGE_BASE_S.merge({ 12 => 2 })\n",
    %w[SINGLE_MERGE]
  ]
}

negatives.each do |what, (extra, names)|
  puts "== negative: #{what}"
  program = BASE + extra
  # The Ruby definition is in the program itself, so each negative is its own closed world.
  rows = container_rows.call(typed_rows.call(program))
  names.each do |name|
    check.call("#{name} stays untyped (#{what})", rows[name] && rows[name][0].nil?)
  end
end


what = 'a non-literal merge receiver (a global nothing proves)'
puts "== negative: #{what}"
rows = container_rows.call(positive_rows)
check.call("X_MERGE stays untyped (#{what})", rows['X_MERGE'] && rows['X_MERGE'][0].nil?)

# The interval proof and the operator predicate over one program, in process.
analysis = lambda do |source|
  Dir.mktmpdir do |dir|
    rb = File.join(dir, 'fixture.rb')
    File.write(rb, source)
    ireps, root = compile_ireps([rb], 'integer_arith', dir)
    registry, _superclass_of, _containers, included, prepended, unknown, _structs, _decls, _walked, _ivars, sites = build_registry(ireps, root)
    safe = IntegerConstantRanges.integer_ops_safe?(registry, included, prepended, unknown)
    # FREEZE_SELF: the same owner-scoped proof the build passes (bc2cpp.rb), not a copy of it.
    freeze_safe = DeclaredConstants.stock_method?('freeze', 'Integer', registry, included, prepended, unknown)
    # The bytecode IR facts, with the gates the build passes (bc2cpp.rb).
    ir = BytecodeIR::ConstantFacts.analyze(ireps, sites: sites, poisoned: Set.new, operators_safe: safe,
                                                  freeze_safe: freeze_safe, freeze_classes: Set.new)
    {
      safe: safe,
      freeze_safe: freeze_safe,
      ranges: IntegerConstantRanges.analyze(ireps, [], [], operators_safe: safe, freeze_safe: freeze_safe),
      refused: IntegerConstantRanges.analyze(ireps, [], [], operators_safe: false),
      # The exact-value proof with the operator gate bypassed, and with the gate as the program sets it.
      ints_ungated: IntegerConstants.analyze(ireps, [], [], operators_safe: true),
      ints_gated: IntegerConstants.analyze(ireps, [], [], operators_safe: safe),
      ir_ranges: ir.intervals,
      ir_values: ir.values,
      ir_fixnum: ir.fixnum_names
    }
  end
end


puts '== positive: literals and named constants (exact values and intervals)'
pos = analysis.call(positive)
check.call('the operators are the core ones (no Ruby definition on Integer)', pos[:safe])
# The IR intervals and Fixnum names are the proofs' own. The exact-value proof also admits a literal-only
# name outside the Fixnum margin (ZA_BIG, 1073741824), which the IR's Fixnum set leaves out on purpose: a Fixnum name is
# inside the margin by construction.
check.call('the IR intervals equal the interval proof (positive)', pos[:ir_ranges] == pos[:ranges])
check.call('an IR Fixnum name the exact-value proof lacks has an interval (positive)',
           (pos[:ir_fixnum] - pos[:ints_gated].to_set).all? { |name| pos[:ranges].key?(name) })
check.call('the only exact-value name outside the IR Fixnum set is ZA_BIG (positive)',
           (pos[:ints_gated].to_set - pos[:ir_fixnum]) == ['ZA_BIG'].to_set)
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
rows = positive_rows
slot = row_for.call(rows, 'ZA_SLOT')
check.call('ZA_SLOT is typed Integer', slot && slot['type'] == 'Integer')
check.call('ZA_SPAN is typed Integer', (r = row_for.call(rows, 'ZA_SPAN')) && r['type'] == 'Integer')
half = row_for.call(rows, 'ZA_HALF')
check.call('ZA_HALF (floor division) is typed Integer', half && half['type'] == 'Integer')
range_only = row_for.call(rows, 'ZA_SLOT_RANGE')
# The IR admits an interval-only name as a Fixnum constant, so its row comes from the integer-constant set.
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


puts '== freeze returns its receiver: a frozen Integer expression keeps its interval'
fr = analysis.call(frozen)
check.call('freeze is stock on Integer (no Ruby freeze on its ancestors)', fr[:freeze_safe])
check.call('ZF_SLOT (= (ZF_BASE - ZF_STEP).freeze) has the interval [37, 37]', fr[:ranges]['ZF_SLOT'] == [37, 37])
check.call('ZF_SPAN (= (ZF_STEP * 13).freeze) has the interval [39, 39]', fr[:ranges]['ZF_SPAN'] == [39, 39])
check.call('ZF_HALF (= (-7 / 2).freeze) has the interval [-4, -4]', fr[:ranges]['ZF_HALF'] == [-4, -4])
check.call('ZF_ZERO (divisor interval holds 0) has no interval', !fr[:ranges].key?('ZF_ZERO'))
check.call('ZF_NONLIT (a send operand) has no interval', !fr[:ranges].key?('ZF_NONLIT'))
rows = positive_rows
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


puts '== a Ruby freeze on Object withdraws the freeze-through proof for a frozen String and Integer'
fo = analysis.call(freeze_object)
check.call('freeze_safe is false (a Ruby freeze on Object, an ancestor of Integer)', !fo[:freeze_safe])
check.call('ZF_SLOT has no interval', !fo[:ranges].key?('ZF_SLOT'))
object_freeze_rows = typed_rows.call(BASE + freeze_object)
object_containers = container_rows.call(object_freeze_rows)
%w[FROZEN_ARR FROZEN_HASH KANA].each do |name|
  check.call("#{name} stays untyped (Object#freeze defined in Ruby (Array and Hash inherit it))",
             object_containers[name] && object_containers[name][0].nil?)
end
ostr = row_for.call(object_freeze_rows, 'ZF_STR')
check.call('ZF_STR (frozen String) is untyped while Object#freeze is redefined', ostr && ostr['type'].nil?)


puts "#{failures.empty? ? 'PASS' : 'FAIL'} constant_typing_check: #{failures.size} failure(s)"
exit(failures.empty? ? 0 : 1)
