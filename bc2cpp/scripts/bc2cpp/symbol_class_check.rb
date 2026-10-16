#!/usr/bin/env ruby
# frozen_string_literal: true

# SYMBOL_CLASS (docs/adr/0424): a frozen literal table whose elements are Symbols carries the 'Symbol' class bit
# (the bit LOADSYM literals carry in the exact-class run) in its slot classes, so `TABLE[i]` is SYM where the index
# is an Integer. Every other class bit stays out of numeric arithmetic, truthiness and cross-method facts.
#
# 1. Model (CRuby, no mrbc): FrozenTables::Registry reads and names a Symbol slot; NumericFlow treats the bit as one
#    truthy, non-numeric, OPAQUE class: arithmetic on it is OTHER, a falsy edge drops it, a numeric test refuses it.
# 2. Generated code (MRBC): a closed-world fixture shows the Symbol slots in the facts report (FROZEN:Array[SYM*3]),
#    a Symbol that is not a literal (`"x".to_sym`) stays OTHER, and a hostile world (a redefined Array method, a
#    const_missing) proves no frozen table at all. BC2CPP_SYMBOL_CLASS=0 names the same tables OTHER.
#
# Usage: MRBC=path/to/mrbc ruby scripts/bc2cpp/symbol_class_check.rb

require 'tmpdir'
require_relative '../../tools/bc2cpp/frozen_tables'
require_relative 'fixture_runtime'

failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

NF = NumericFlow
SYM = 1 << NF::CLASS_BIT_BASE
FALSE_BIT = 1 << (NF::CLASS_BIT_BASE + 1)
INT = NF::INT
NIL_ = NF::NIL
OTHER = NF::OTHER

# ---------------------------------------------------------------------------
puts '-- model (host)'
reg = FrozenTables::Registry.new(symbol_bit: SYM)
syms = reg.intern(:array, [SYM, SYM, SYM], nil)
check.call('a Symbol slot reads the Symbol bit at a literal index in range', reg.read(syms, 1, true) == SYM)
check.call('a Symbol slot reads the Symbol bit or nil for an Integer index that is not a literal',
           reg.read(syms, nil, true) == (SYM | NIL_))
check.call('a literal index past the end reads nil', reg.read(syms, 3, true) == NIL_)
check.call('first/last of Symbol slots are the Symbol bit', reg.end_read(syms, 'first') == SYM && reg.end_read(syms, 'last') == SYM)
check.call('an index that may be a Range proves nothing', reg.read(syms, nil, false) == OTHER)
check.call('the table is named by its slot classes', reg.name(syms.bit) == 'FROZEN:Array[SYM*3]')
mixed = reg.intern(:array, [SYM, INT], nil)
check.call('a mixed table names each slot', reg.name(mixed.bit) == 'FROZEN:Array[SYM,INT]')
hash = reg.intern(:hash, [SYM, INT], [:up, 8])
check.call('a Hash literal key reads its Symbol value', reg.read(hash, :up, false) == SYM)
plain = FrozenTables::Registry.new
no_bit = plain.intern(:array, [OTHER, OTHER], nil)
check.call('without a Symbol bit the table is named OTHER', plain.name(no_bit.bit) == 'FROZEN:Array[OTHER*2]')

check.call('arithmetic on a Symbol is OTHER (no numeric result)', NF.arith(SYM, INT, false) == OTHER &&
                                                                    NF.arith(SYM, SYM, true) == OTHER)
check.call('a Symbol is not numeric and not a container', !NF.numeric?(SYM) && !NF.numeric?(INT | SYM) &&
                                                          !NF.containers?(SYM))
check.call('a Symbol is OPAQUE: it does not cross a method boundary through an argument, ivar or constant',
           NF::OPAQUE & SYM != 0)
check.call('a Symbol is truthy: the falsy edge of a test drops it, keeping nil and OTHER',
           NF.narrow_by_truth('JMPIF', false, SYM | NIL_ | OTHER, 0, FALSE_BIT) == (NIL_ | OTHER))
check.call('a Symbol is truthy: the truthy edge keeps it',
           NF.narrow_by_truth('JMPIF', true, SYM | NIL_, 0, FALSE_BIT) == SYM)
check.call('the Symbol bit does not collide with a class bit below it or an object kind',
           SYM > NF::RNG && SYM < (1 << NF::OBJECT_KIND_BASE) && SYM != NF::CHECKED)

# ---------------------------------------------------------------------------
puts '-- generated code (host mrbc)'
if ENV['MRBC']
  FIXTURE = <<~RUBY
    module SyTables
      NAMES = [:a, :b, :c].freeze
      MIXED = [:a, 1].freeze
      COMPUTED = ["x".to_sym].freeze
    end

    class SyUse
      def name_at(i); (SyTables::NAMES[i] || :none); end
      def mixed_at(i); (SyTables::MIXED[i] || 0); end
      def computed_at(i); (SyTables::COMPUTED[i] || 0); end
      def name_first; SyTables::NAMES.first; end
    end
  RUBY
  OWNERS = %w[SyTables SyUse].freeze
  SLOW = ->(src, dir, env: {}) do
    saved = env.to_h { |k, _| [k, ENV.fetch(k, nil)] }
    env.each { |k, v| ENV[k] = v }
    begin
      Bc2cppFixtureRuntime.generate(src, dir, only_owners: OWNERS)
    ensure
      saved.each { |k, v| v ? ENV[k] = v : ENV.delete(k) }
    end
  end

  Dir.mktmpdir('symbol_class') do |root|
    on_code, on_err = SLOW.call(FIXTURE, File.join(root, 'on'))
    off_code, off_err = SLOW.call(FIXTURE, File.join(root, 'off'), env: { 'BC2CPP_SYMBOL_CLASS' => '0' })
    check.call('the Symbol table names SYM*3 and the mixed one SYM,INT',
               on_err.include?('FROZEN:Array[SYM*3]') && on_err.include?('FROZEN:Array[SYM,INT]'))
    check.call('a Symbol written by a call (`"x".to_sym`) stays OTHER', on_err.include?('FROZEN:Array[OTHER]'))
    check.call('BC2CPP_SYMBOL_CLASS=0 names the same tables OTHER and no SYM',
               off_err.include?('FROZEN:Array[OTHER*3]') && off_err.include?('FROZEN:Array[OTHER,INT]') &&
               !off_err.match?(/FROZEN:\S*SYM/))
    check.call('the kill switch leaves the generated code of this fixture unchanged', on_code == off_code)
    check.call('the on run generates the fixture', !on_code.empty?)

    hostile = {
      'a redefined Array#freeze' => "class Array\n  def freeze; self; end\nend\n",
      'a const_missing' => "class SyUse\n  def self.const_missing(_n); 1; end\nend\n"
    }
    hostile.each do |what, extra|
      _code, err = SLOW.call(FIXTURE + extra, File.join(root, what.tr(' ', '_')))
      check.call("#{what} proves no table (no SYM name)", !err.include?('FROZEN:Array[SYM') && err.include?('off:'))
    end
  end
else
  puts '  SKIP generated code: set MRBC'
end

if failures.empty?
  puts 'bc2cpp symbol class check: PASS'
else
  warn "bc2cpp symbol class check: #{failures.size} failure(s)"
  exit 1
end
