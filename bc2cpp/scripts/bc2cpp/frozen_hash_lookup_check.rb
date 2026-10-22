#!/usr/bin/env ruby
# frozen_string_literal: true

# HASH_LOOKUP (docs/bc2cpp-type-check.md): `NAME[k]` on a frozen Hash literal whose keys hold the literal k is an Integer
# in the class run, when every value is an Integer literal and Hash#[] is stock. Each fixture is compiled by the host
# mrbc. The class rows are checked end to end through type_check.rb --files (the analysis a build runs). The value run
# (ConstantFacts without hash_lookup_safe) is checked in process: it must not change. Needs MRBC (a host mrbc); without
# it the check prints SKIP and exits 0.
#
#   MRBC=path/to/host/mrbc ruby scripts/bc2cpp/frozen_hash_lookup_check.rb

require 'json'
require 'open3'
require 'set'
require 'tmpdir'
require_relative '../../tools/bc2cpp/bc2cpp'

unless ENV['MRBC'] && File.executable?(ENV['MRBC'])
  puts 'SKIP frozen_hash_lookup_check: MRBC is not set to a host mrbc'
  exit 0
end

ROOT = File.expand_path('../..', __dir__)
TYPE_CHECK = File.join(ROOT, 'scripts/bc2cpp/type_check.rb')

failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

row_for = lambda do |rows, bare|
  rows.find { |r| r['name'] == bare || r['name'].end_with?("::#{bare}") }
end

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

# The value run and the class run of one program, in process, with the gates the build passes (bc2cpp.rb).
facts = lambda do |source|
  Dir.mktmpdir do |dir|
    rb = File.join(dir, 'fixture.rb')
    File.write(rb, source)
    ireps, root = compile_ireps([rb], 'frozen_hash_lookup', dir)
    registry, _superclass_of, _containers, included, prepended, unknown, _structs, _decls, _walked, _ivars, sites = build_registry(ireps, root)
    safe = IntegerConstantRanges.integer_ops_safe?(registry, included, prepended, unknown)
    freeze_safe = DeclaredConstants.stock_method?('freeze', 'Integer', registry, included, prepended, unknown)
    freeze_classes = %w[Array Hash String].select do |k|
      DeclaredConstants.stock_method?('freeze', k, registry, included, prepended, unknown)
    end.map(&:to_sym).to_set
    analyze = lambda do |lookup|
      BytecodeIR::ConstantFacts.analyze(ireps, sites: sites, poisoned: Set.new, operators_safe: safe,
                                                freeze_safe: freeze_safe, freeze_classes: freeze_classes,
                                                hash_lookup_safe: lookup)
    end
    off = analyze.call(false)
    on = analyze.call(true)
    { off: off, on: on }
  end
end

main = <<~RUBY
  module HlTables
    HL_TABLE = { 2 => 1, 4 => 2, 6 => 4, 8 => 8 }.freeze
    HL_STR_TABLE = { 2 => 1, 4 => "x" }.freeze
    HL_OPEN_TABLE = { 2 => 1 }
    HL_EMPTY_TABLE = {}.freeze
    HL_ARR = [1, 2, 3].freeze
    HL_HIT = HL_TABLE[2]
    HL_ALL = (HL_TABLE[2] | HL_TABLE[4] | HL_TABLE[6] | HL_TABLE[8]).freeze
    HL_MISS = HL_TABLE[3]
    HL_STR = HL_STR_TABLE[2]
    HL_OPEN = HL_OPEN_TABLE[2]
    HL_ARRV = HL_ARR[2]
    HL_EMPTY = HL_EMPTY_TABLE[2]
    HL_BLK = HL_TABLE.[](2) { 9 }
    hl_src = { 2 => 1, 4 => 2 }
    hl_src[2] = "s"
    HL_MUT = hl_src.freeze
    HL_MUT_HIT = HL_MUT[2]
    hl_ok = { 2 => 1 }
    HL_OK = hl_ok.freeze
    HL_OK_HIT = HL_OK[2]
    def self.hl_key
      2
    end
    HL_VAR = HL_TABLE[hl_key]
  end
RUBY

redefined = <<~RUBY
  class Hash
    def [](key)
      "redefined"
    end
  end
  module HlRed
    HL_RED_TABLE = { 2 => 1 }.freeze
    HL_RED = HL_RED_TABLE[2]
  end
RUBY

puts '== positive and negative, end to end (class rows)'
rows = typed_rows.call(main)
hit = row_for.call(rows, 'HL_HIT')
check.call('a literal-key hit HL_TABLE[2] is typed Integer (inferred:integer-class)',
           hit && hit['type'] == 'Integer' && hit['source'] == 'inferred:integer-class')
ok_hit = row_for.call(rows, 'HL_OK_HIT')
check.call('a local frozen in place (hl_ok.freeze, nothing between) gives a typed lookup (HL_OK_HIT)',
           ok_hit && ok_hit['type'] == 'Integer' && ok_hit['source'] == 'inferred:integer-class')
all = row_for.call(rows, 'HL_ALL')
check.call('ALL_DIRS-shaped (HL_TABLE[2] | HL_TABLE[4] | ...).freeze is typed Integer (inferred:integer-class)',
           all && all['type'] == 'Integer' && all['source'] == 'inferred:integer-class')
table = row_for.call(rows, 'HL_TABLE')
check.call('the frozen literal HL_TABLE keeps its own Hash row (unchanged producer)',
           table && table['type'] == 'Hash' && table['source'] == 'inferred:constructed')
{
  'HL_MISS (key 3 is not in the table)' => 'HL_MISS',
  'HL_STR (a non-Integer value in the table)' => 'HL_STR',
  'HL_OPEN (an unfrozen literal)' => 'HL_OPEN',
  'HL_ARRV (a non-Hash receiver)' => 'HL_ARRV',
  'HL_EMPTY (an empty table, so every key misses)' => 'HL_EMPTY',
  'HL_BLK (a call with a block)' => 'HL_BLK',
  'HL_VAR (a variable key)' => 'HL_VAR',
  'HL_MUT_HIT (the literal is mutated before it is frozen)' => 'HL_MUT_HIT'
}.each do |what, bare|
  row = row_for.call(rows, bare)
  check.call("#{what} is not typed Integer", row.nil? || row['type'] != 'Integer')
end

puts '== the value proof is unchanged by the class run (in process)'
f = facts.call(main)
check.call('fixnum_names is the same with and without hash_lookup_safe', f[:off].fixnum_names == f[:on].fixnum_names)
check.call('values are the same with and without hash_lookup_safe', f[:off].values == f[:on].values)
check.call('intervals are the same with and without hash_lookup_safe', f[:off].intervals == f[:on].intervals)
check.call('the class run admits HL_ALL and HL_HIT, the value run does not',
           f[:on].integer_class_names.include?('HL_ALL') && f[:on].integer_class_names.include?('HL_HIT') &&
           !f[:off].integer_class_names.include?('HL_ALL') && !f[:off].integer_class_names.include?('HL_HIT'))

puts '== negative: a program redefining Hash#[] (end to end)'
red = typed_rows.call(redefined)
red_row = row_for.call(red, 'HL_RED')
check.call('HL_RED stays untyped when Hash#[] is redefined', red_row.nil? || red_row['type'] != 'Integer')

puts
if failures.empty?
  puts 'frozen_hash_lookup_check: all checks passed'
else
  puts "frozen_hash_lookup_check: #{failures.size} check(s) failed"
  exit 1
end
