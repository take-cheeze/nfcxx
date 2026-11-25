#!/usr/bin/env ruby
# frozen_string_literal: true

# Behaviour and placement oracle for the stack tuple arrays: a literal Array of immediates that never
# leaves its frame keeps its elements in a C++ buffer. Three halves:
#
#   1. placement: each method in POSITIVE has its buffer in the generated code (`mrb_value bc2cpp_tup<N>[k]`) and no
#      mruby Array for that literal; every method in NEGATIVE keeps the mruby Array, and the whole generated text of
#      NEGATIVE is byte-identical to the output with BC2CPP_STACK_TUPLES=0 (the kill switch).
#   2. parity, interpreted against compiled: every row (POSITIVE and NEGATIVE) prints the same value on both sides,
#      and each value matches the value written here.
#   3. the kill switch: BC2CPP_STACK_TUPLES=0 generates no `bc2cpp_tup` at all.
#
# The same three halves cover MULTI_RETURN (`x, y = f` through a buffer, BC2CPP_MULTI_RETURN) and LITERAL_MINMAX
# (`[a, b].min`, BC2CPP_LITERAL_MINMAX), the other Arrays that never leave their frame, and the literal rewrites below.
#
# Usage: MRBC=path/to/host/mrbc ruby scripts/bc2cpp/stack_tuples_check.rb
# Without MRBC the check aborts; without a full-core build (fixture_runtime.rb) its runtime half prints SKIP and the
# generation half still runs.

require 'tmpdir'
require_relative 'fixture_runtime'

ENV['BC2CPP_SIG_DIRS'] ||= ''
runtime = Bc2cppFixtureRuntime
failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

# Each method holds one placed literal (the placement count is in PLACED) or refuses for the reason in its comment.
POSITIVE = <<~RUBY
  class TupPos
    def pair_sum
      a = [1, 2]
      a[0] + a[1]
    end

    def set_read
      a = [1, 2, 3]
      a[1] = 40
      a[0] + a[1] + a[2]
    end

    def oob_read
      a = [5]
      a[3]
    end

    def neg_read
      a = [5, 6]
      a[-1]
    end

    def sized
      a = [4, 5, 6]
      a.size + a.length
    end

    def alias_store
      a = [1, 2]
      b = a
      b[0] = 9
      a[0]
    end

    def symbols
      a = [:x, nil, true]
      [a[0] == :x, a[1].nil?, a[2]].inspect
    end

    def store_value
      a = [0, 0]
      r = (a[1] = 7)
      [r, a[1]]
    end

    def big_fixnum
      a = [100_000, 2]
      a[0] + a[1]
    end

    def loop_read
      a = [1, 2]
      i = 0
      s = 0
      while i < 4
        s += a[1]
        i += 1
      end
      s
    end

    def two_arrays
      a = [1, 2]
      b = [3, 4]
      a[0] + b[1]
    end

    # The array escapes once, at the return or the ivar store, and the escape materialises the buffer (see
    # STACK_TUPLE_PROMOTE_OPS in codegen_stack_tuples.rb).
    def promo_return
      a = [1, 2]
      a[0] = 9
      a
    end

    def promo_store
      @kept = [3, 4]
      @kept[1]
    end
  end
RUBY

POSITIVE_EXPECTED = {
  'TupPos.new.pair_sum' => '3',
  'TupPos.new.set_read' => '44',
  'TupPos.new.oob_read' => 'nil',
  'TupPos.new.neg_read' => '6',
  'TupPos.new.sized' => '6',
  'TupPos.new.alias_store' => '9',
  'TupPos.new.symbols' => '"[true, true, true]"',
  'TupPos.new.store_value' => '[7, 7]',
  'TupPos.new.big_fixnum' => '100002',
  'TupPos.new.loop_read' => '8',
  'TupPos.new.two_arrays' => '5',
  'TupPos.new.promo_return' => '[9, 2]',
  'TupPos.new.promo_store' => '4',
}.freeze
# The methods that place a buffer: every other POSITIVE method must keep its Array.
POSITIVE_PLACED = %w[pair_sum set_read oob_read neg_read sized alias_store symbols store_value big_fixnum loop_read
                     two_arrays promo_return promo_store].freeze
# The methods whose only ARRAY is the placed literal: their chunk has no mruby Array construction at all.
POSITIVE_ONLY_LITERAL = %w[pair_sum set_read oob_read neg_read sized alias_store big_fixnum loop_read].freeze

# Each method refuses (an escape that is not a return or ivar store as the array's last use, a loop-carried creation, an unknown or out-of-bounds index, a non-immediate element,
# a read the placement does not model). The values must still match the interpreter.
NEGATIVE = <<~RUBY
  class TupSink
    def keep(x); @k = x; nil; end
    def first_of(x); x[0]; end
  end

  class TupNeg
    # The array is used after the store that escapes it, so the escape is not its last use: it keeps its Array.
    def read_after
      a = [1, 2]
      @k = a
      a[0]
    end

    def branch_read(c)
      a = [1, 2]
      @k = a if c
      a[0]
    end

    def kept
      a = [1, 2]
      TupSink.new.keep(a)
      a[0]
    end

    def loop_made
      i = 0
      s = 0
      while i < 3
        t = [i, 1]
        s += t[0]
        i += 1
      end
      s
    end

    def unknown_index(i)
      a = [1, 2]
      a[i]
    end

    def grow
      a = [1, 2]
      a[5] = 1
      a.size
    end

    def passed
      a = [1, 2]
      TupSink.new.first_of(a)
    end

    def first_call
      a = [1, 2]
      a.first
    end

    def float_element
      a = [1.5, 2]
      a[0]
    end

    def bignum_element
      a = [2**40, 1]
      a[0]
    end

    def string_element
      a = ['s', 1]
      a[0]
    end

    def ivar_element
      @v = 3
      a = [@v, 1]
      a[0]
    end

    # A read in a rescue handler has no reaching definition through the handler edges (the producer query refuses).
    def rescued
      a = [3, 4]
      begin
        raise 'boom' if a.size == 2
      rescue RuntimeError
        a[1]
      end
    end

    def string_store
      a = [1, 2]
      a[0] = 'x'
      a[0]
    end

    def neg_store
      a = [1, 2]
      a[-1] = 5
      a[1]
    end

    def rescue_escape
      a = [1, 2]
      begin
        raise ArgumentError, 'x'
      rescue ArgumentError
        a
      end
    end

    # A self send (SSEND) reads its argument registers too: the literal escapes into the callee.
    def self_passed
      a = [1, 2]
      own_first(a)
    end

    def self_passed_literal
      own_include([2, 8], 8)
    end

    def own_first(x); x[0]; end
    def own_include(pair, v); pair.include?(v); end
  end
RUBY

NEGATIVE_EXPECTED = {
  'TupNeg.new.read_after' => '1',
  'TupNeg.new.branch_read(true)' => '1',
  'TupNeg.new.kept' => '1',
  'TupNeg.new.loop_made' => '3',
  'TupNeg.new.unknown_index(1)' => '2',
  'TupNeg.new.grow' => '6',
  'TupNeg.new.passed' => '1',
  'TupNeg.new.first_call' => '1',
  'TupNeg.new.float_element' => '1.5',
  'TupNeg.new.bignum_element' => '1099511627776',
  'TupNeg.new.string_element' => '"s"',
  'TupNeg.new.ivar_element' => '3',
  'TupNeg.new.rescued' => '4',
  'TupNeg.new.string_store' => '"x"',
  'TupNeg.new.neg_store' => '5',
  'TupNeg.new.rescue_escape' => '[1, 2]',
  'TupNeg.new.self_passed' => '1',
  'TupNeg.new.self_passed_literal' => 'true',
}.freeze

OWNERS_POS = %w[TupPos].freeze
OWNERS_NEG = %w[TupSink TupNeg].freeze

# A Ruby definition of Array#size reaches every exact Array: no placement anywhere in the program.
REDEFINED = <<~RUBY2
  class Array
    def size
      99
    end
  end

  class TupRedef
    def sized
      a = [4, 5]
      a.size
    end
  end
RUBY2
REDEFINED_EXPECTED = { 'TupRedef.new.sized' => '99' }.freeze
OWNERS_REDEF = %w[Array TupRedef].freeze

# STRING_EQ_LITERAL (codegen_string_eq.rb): `x == "literal"` compares the bytes when x is exactly a String and builds the
# literal only on the other path. The cases cover a match, a mismatch in content and in length, other classes, a String
# subclass that defines ==, an == that mutates and keeps its argument (it must see a fresh literal each time), and
# a literal that is kept (the pair is not rewritten).
STR_EQ = <<~RUBY3
  class SubStr < String
    def ==(other); true; end
  end

  class StrProbe
    attr_reader :seen
    def ==(other); @seen = other; other << "!"; false; end
  end

  class StrEq
    def same(x); x == "abc"; end
    def branch(x); x == "abc" ? 1 : 2; end
    def twice(x); (x == "a") || (x == "b"); end
    def neq(x); x != "abc"; end
    def kept(x); s = "abc"; x == s; s; end
  end
RUBY3
STR_EQ_EXPECTED = {
  'StrEq.new.same("abc")' => 'true',
  'StrEq.new.same("abd")' => 'false',
  'StrEq.new.same("ab")' => 'false',
  'StrEq.new.same("abcd")' => 'false',
  'StrEq.new.same("")' => 'false',
  'StrEq.new.same(:abc)' => 'false',
  'StrEq.new.same(nil)' => 'false',
  'StrEq.new.same(1)' => 'false',
  'StrEq.new.same(SubStr.new("zzz"))' => 'true',
  'StrEq.new.branch("abc")' => '1',
  'StrEq.new.branch("x")' => '2',
  'StrEq.new.twice("b")' => 'true',
  'StrEq.new.twice("c")' => 'false',
  'StrEq.new.neq("abc")' => 'false',
  'StrEq.new.neq("x")' => 'true',
  'StrEq.new.neq(nil)' => 'true',
  'StrEq.new.neq(SubStr.new("zzz"))' => 'false',
  'p = StrProbe.new; s = StrEq.new; s.same(p); s.same(p); p.seen' => '"abc!"',
  'StrEq.new.kept("abc")' => '"abc"',
}.freeze
OWNERS_STR = %w[SubStr StrProbe StrEq].freeze

# CHR_APPEND (codegen_chr_append.rb): `str << n.chr` appends the byte of an exact String when n is an Integer from 0 to 255
# and builds no one-character String. The cases cover the loop body of an inlined each (shifted registers), the plain
# statement, a value outside 0..255 (the RangeError), a frozen String (the FrozenError), an Array and a String subclass
# that defines <<, and a chr result that is read again (not rewritten).
CHR_APP = <<~RUBY4
  class ChrSub < String
    def <<(other); super("!"); end
  end

  class ChrApp
    def bytes(a); s = "".b; a.each { |c| s << (c & 255).chr }; s; end
    def direct(n); s = "x"; s << n.chr; s; end
    def frozen(n); s = "x".freeze; s << n.chr; s; end
    def into_array(n); a = []; a << n.chr; a; end
    def sub(s, n); s << n.chr; s; end
    def kept(n); c = n.chr; s = "a"; s << c; [s, c]; end
    def not_integer(n); s = "q"; s << n.chr; s; end
  end
RUBY4
CHR_APP_EXPECTED = {
  'ChrApp.new.bytes([72, 105, 33])' => '"Hi!"',
  'ChrApp.new.bytes([])' => '""',
  'ChrApp.new.bytes([256 + 65, 66])' => '"AB"',
  'ChrApp.new.direct(65)' => '"xA"',
  'ChrApp.new.direct(0).bytes.to_a' => '[120, 0]',
  'ChrApp.new.direct(255).bytes.to_a' => '[120, 255]',
  'begin; ChrApp.new.direct(256); rescue RangeError => e; e.message; end' => '"256 out of char range"',
  'begin; ChrApp.new.direct(-1); rescue RangeError => e; e.message; end' => '"-1 out of char range"',
  'begin; ChrApp.new.frozen(65); rescue => e; e.class; end' => 'FrozenError',
  'ChrApp.new.into_array(66)' => '["B"]',
  'ChrApp.new.sub(ChrSub.new("q"), 65)' => '"q!"',
  'ChrApp.new.sub("plain", 67)' => '"plainC"',
  'ChrApp.new.kept(68)' => '["aD", "D"]',
  'begin; ChrApp.new.not_integer(1.5); rescue => e; e.class; end' => 'NoMethodError',
}.freeze
OWNERS_CHR = %w[ChrSub ChrApp].freeze

# STRCAT_LITERAL (codegen_strcat_literal.rb): a literal piece of an interpolation appends its bytes to the accumulator,
# and STRCAT_STRING_ACC drops the accumulator's String check when it is proven. The cases cover operands of every kind
# (an object with its own to_s included), NUL and multibyte pieces, the shifted registers of an inlined block, a
# to_s that raises into a rescue, and an interpolation result that is appended to afterwards.
STRCAT_LIT = <<~'RUBY6'
  class ScObj
    def to_s; "obj"; end
  end

  class ScBad
    def to_s; raise ArgumentError, "bad to_s"; end
  end

  class ScLit
    def plain(x); "a#{x} (#{x})b"; end
    def nul(x); "\0#{x}\0"; end
    def multi(x); "\u00e9#{x}\u3042"; end
    def mapped(a); a.map { |v| "<#{v}>" }; end
    def joined(a); s = String.new; a.each { |v| s << "#{v}, " }; s; end
    def rescued(x); begin; "p#{x}q"; rescue ArgumentError => e; "r:#{e.message}"; end; end
    def appended(x); s = "#{x}!"; s << "?"; s; end
  end
RUBY6
STRCAT_LIT_EXPECTED = {
  'ScLit.new.plain(1)' => '"a1 (1)b"',
  'ScLit.new.plain("s")' => '"as (s)b"',
  'ScLit.new.plain(nil)' => '"a ()b"',
  'ScLit.new.plain(:sym)' => '"asym (sym)b"',
  'ScLit.new.plain(ScObj.new)' => '"aobj (obj)b"',
  'ScLit.new.nul(7).bytes.to_a' => '[0, 55, 0]',
  'ScLit.new.multi("x").bytesize' => '6',
  'ScLit.new.multi("x").size' => '3',
  'ScLit.new.mapped([1, "b", nil])' => '["<1>", "<b>", "<>"]',
  'ScLit.new.joined([1, 2])' => '"1, 2, "',
  'ScLit.new.rescued(3)' => '"p3q"',
  'ScLit.new.rescued(ScBad.new)' => '"r:bad to_s"',
  'ScLit.new.appended(5)' => '"5!?"',
  'ScLit.new.plain(1).frozen?' => 'false',
}.freeze
OWNERS_SC = %w[ScObj ScBad ScLit].freeze

# CALL_INLINE (codegen_call_inline.rb): a call the compiler already binds to one definition (here by the receiver being
# exactly a fresh IcPoint) becomes the callee's instructions when the callee is a small register-only body. The cases cover
# the Integer, Float, String and nil operands of the inlined arithmetic and compare (the slow arms), a branching callee, a
# callee that is only a move, and a callee that sends (not inlined).
CALL_INL = <<~RUBY5
  class IcPoint
    def initialize(x, y); @x = x; @y = y; end
    def sq(a); a * a; end
    def cmax(a, b); a > b ? a : b; end
    def ident(a); a; end
    def dec(a); a - 1; end
    def flag(a); a.nil?; end
    def sumxy; @x + @y; end
    def bump(d); @x += d; end
    def twice(a); sumxy + a; end
    def me; self; end
  end

  class IcUse
    def run(n); p = IcPoint.new(1, 2); p.sq(n) + p.cmax(n, 3) + p.ident(7); end
    def square(x); IcPoint.new(0, 0).sq(x); end
    def pick(a, b); IcPoint.new(0, 0).cmax(a, b); end
    def down(a); IcPoint.new(0, 0).dec(a); end
    def nosend(a); IcPoint.new(0, 0).flag(a); end
    def twice(n); pt = IcPoint.new(0, 0); [pt.sq(n), pt.sq(n + 1)]; end
    def state(n); pt = IcPoint.new(1, 2); pt.bump(n); [pt.sumxy, pt.twice(10)]; end
    def same; pt = IcPoint.new(0, 0); pt.me.equal?(pt); end
  end
RUBY5
CALL_INL_EXPECTED = {
  'IcUse.new.run(5)' => '37',
  'IcUse.new.run(2)' => '14',
  'IcUse.new.square(1.5)' => '2.25',
  'IcUse.new.square(70000)' => '4900000000',
  'begin; IcUse.new.square(nil); rescue NoMethodError => e; e.class; end' => 'NoMethodError',
  'IcUse.new.pick("a", "b")' => '"b"',
  'IcUse.new.pick(3, 3)' => '3',
  'IcUse.new.pick(4, 3)' => '4',
  'IcUse.new.down(10)' => '9',
  'IcUse.new.down(1.5)' => '0.5',
  'IcUse.new.nosend(nil)' => 'true',
  'IcUse.new.nosend(1)' => 'false',
  'IcUse.new.twice(3)' => '[9, 16]',
  'IcUse.new.state(5)' => '[8, 18]',
  'IcUse.new.state(1.5)' => '[4.5, 14.5]',
  'begin; IcUse.new.state(nil); rescue TypeError => e; e.class; end' => 'TypeError',
  'IcUse.new.same' => 'true'
}.freeze
OWNERS_INL = %w[IcPoint IcUse].freeze

# MULTI_RETURN (codegen_multi_return.rb): `x, y = f` with f a direct call whose every return is a fresh literal passes
# the elements through a frame-local buffer (`f_mr`); every other caller still gets an Array from `f_impl`. MrPos holds
# the placed callers (MULTI_RETURN_PLACED) and the callers that must keep the Array (MULTI_RETURN_KEPT): one that keeps
# the result, one that uses the masgn's value, an aliased Array, a destructure of a non-call, a callee with another
# return, a call in a rescue body. The strings are fresh per call, so a mutated element and a 300-iteration loop exercise identity and the GC.
MULTI_RET = <<~'RUBY7'
  class MrPos
    def initialize(x, y); @x = x; @y = y; end
    def pair; [@x * 2, @y + 1]; end
    def strs; ["a#{@x}", "b#{@y}"]; end
    def pick(c); c ? [@x, "s#{@y}"] : [@y, nil]; end
    def raising(c); raise ArgumentError, 'no' if c; [1, 2]; end
    def mixed(c); return nil if c; [3, 4]; end

    def both; x, y = pair; x + y; end
    def three; a, b, c = pair; [a, b, c]; end
    def one; a, = pair; a; end
    def branch(c); p, q = pick(c); [p, q]; end
    def mutated; s, t = strs; s << '!'; [s, t, strs]; end
    def raised(c); x, y = raising(c); [x, y]; end
    def rescued(c); begin; x, y = raising(c); rescue ArgumentError; x = :r; end; [x, y]; end
    def looped; i = 0; n = 0; while i < 300; a, b = strs; n += a.size + b.size; i += 1; end; n; end

    def kept; a = pair; a << 9; a; end
    def masgn_value; r = (x, y = pair); [r, x, y, r.frozen?]; end
    def aliased; a = pair; b = a; x, y = a; b << 5; [x, y, b]; end
    def use_mixed(c); a, b = mixed(c); [a, b]; end
    # A callee that destructures its own recursive call is a caller of its own buffer form.
    def rec(n); return [n, 0] if n == 0; a, b = rec(n - 1); [a + 1, b + n]; end
  end
RUBY7
MULTI_RET_EXPECTED = {
  'MrPos.new(1, 2).both' => '5',
  'MrPos.new(1, 2).three' => '[2, 3, nil]',
  'MrPos.new(1, 2).one' => '2',
  'MrPos.new(1, 2).branch(true)' => '[1, "s2"]',
  'MrPos.new(1, 2).branch(false)' => '[2, nil]',
  'MrPos.new(1, 2).mutated' => '["a1!", "b2", ["a1", "b2"]]',
  'MrPos.new(1, 2).rescued(true)' => '[:r, nil]',
  'MrPos.new(1, 2).rescued(false)' => '[1, 2]',
  'MrPos.new(1, 2).raised(false)' => '[1, 2]',
  'begin; MrPos.new(1, 2).raised(true); rescue ArgumentError => e; e.message; end' => '"no"',
  'MrPos.new(1, 2).looped' => '1200',
  'MrPos.new(2**40, 2).both' => '2199023255555',
  'MrPos.new(1.5, 2).both' => '6.0',
  'MrPos.new(1, 2).kept' => '[2, 3, 9]',
  'MrPos.new(1, 2).masgn_value' => '[[2, 3], 2, 3, false]',
  'MrPos.new(1, 2).aliased' => '[2, 3, [2, 3, 5]]',
  'MrPos.new(1, 2).use_mixed(true)' => '[nil, nil]',
  'MrPos.new(1, 2).use_mixed(false)' => '[3, 4]',
  'MrPos.new(1, 2).pair' => '[2, 3]',
  'MrPos.new(1, 2).pair.frozen?' => 'false',
  'begin; MrPos.new(nil, 2).both; rescue NoMethodError => e; e.class; end' => 'NoMethodError',
  'MrPos.new(1, 2).rec(3)' => '[3, 6]',
}.freeze
MULTI_RETURN_PLACED = { 'both' => 'pair', 'three' => 'pair', 'one' => 'pair', 'branch' => 'pick', 'mutated' => 'strs',
                        'raised' => 'raising', 'looped' => 'strs', 'rec' => 'rec' }.freeze
# A call inside a rescue body is compiled into the body's own function, which has no buffer: it keeps the Array.
MULTI_RETURN_KEPT = %w[kept masgn_value aliased use_mixed rescued].freeze
OWNERS_MR = %w[MrPos].freeze

# LITERAL_MINMAX (codegen_literal_minmax.rb): `[a, b].min` / `.max` straight into Enumerable#min is one helper call over
# the element registers; an all-fixnum list is answered in place, any other goes through an Array to Enumerable#min.
# MINMAX_KEPT reads the literal again (kept2) or calls min on a local copy (kept), so it keeps the Array.
MINMAX = <<~'RUBY8'
  class MmUse
    def lo(a, b); [a, b].min; end
    def hi(a, b); [a, b].max; end
    def three(a, b, c); [a, b, c].min; end
    def clamp(v); [[v, 0].max, 10].min; end
    def first_wins(a, b); [a, b].min.equal?(a); end
    def kept(a, b); x = [a, b]; x.min; end
    def kept2(a, b); x = [a, b]; [x.max, x]; end
  end
RUBY8
MINMAX_EXPECTED = {
  'MmUse.new.lo(1, 2)' => '1',
  'MmUse.new.lo(2, 1)' => '1',
  'MmUse.new.lo(-5, 5)' => '-5',
  'MmUse.new.hi(3, 3)' => '3',
  'MmUse.new.hi(-1, 4)' => '4',
  'MmUse.new.three(3, 1, 2)' => '1',
  'MmUse.new.clamp(15)' => '10',
  'MmUse.new.clamp(-3)' => '0',
  'MmUse.new.clamp(4)' => '4',
  'MmUse.new.lo(1.5, 1)' => '1',
  'MmUse.new.hi(1.5, 1)' => '1.5',
  'MmUse.new.lo(2**40, 1)' => '1',
  'MmUse.new.hi(2**40, 1)' => '1099511627776',
  'MmUse.new.lo("b", "a")' => '"a"',
  'MmUse.new.first_wins("a", "a")' => 'true',
  'begin; MmUse.new.lo(1, nil); rescue NoMethodError => e; e.class; end' => 'NoMethodError',
  'MmUse.new.kept(2, 1)' => '1',
  'MmUse.new.kept2(2, 1)' => '[2, [2, 1]]',
}.freeze
MINMAX_PLACED = { 'lo' => 'min', 'hi' => 'max', 'three' => 'min', 'clamp' => 'min', 'first_wins' => 'min' }.freeze
MINMAX_KEPT = %w[kept kept2].freeze
OWNERS_MM = %w[MmUse].freeze

# The text of one method's C++ body, from its `// Owner#name (compiled from ...)` header to the next method's header.
def method_chunk(code, owner, name)
  code.split(%r{^(?=// \S+#\S+ \(compiled from)}).find { |chunk| chunk.start_with?("// #{owner}##{name} (") } || ''
end

# The generated text with BC2CPP_STACK_TUPLES=0 (the kill switch), with the environment restored.
def generate_without_tuples(source, owners)
  saved = ENV.fetch('BC2CPP_STACK_TUPLES', nil)
  ENV['BC2CPP_STACK_TUPLES'] = '0'
  Dir.mktmpdir('stack-tuples-off') do |dir|
    code, = Bc2cppFixtureRuntime.generate(source, dir, only_owners: owners)
    code
  end
ensure
  saved.nil? ? ENV.delete('BC2CPP_STACK_TUPLES') : ENV['BC2CPP_STACK_TUPLES'] = saved
end

harness_rows = lambda do |expected|
  rows = expected.keys
  <<~CPP
    static mrb_value eval(mrb_state* M, const char* src) { return mrb_load_string(M, src); }
    static int scenario(mrb_state* M) {
      const char* rows[] = {
    #{rows.map { |row| "    #{row.to_s.inspect}," }.join("\n")}
      };
      for (const char* src : rows) {
        mrb_value v = eval(M, src);
        if (M->exc) { show_exc(M, src); continue; }
        show(M, src, v);
      }
      return 0;
    }
  CPP
end

Dir.mktmpdir('stack-tuples') do |dir|
  # 1. placement and generation
  pos_dir = File.join(dir, 'pos')
  Dir.mkdir(pos_dir)
  pos_code, pos_err = runtime.generate(POSITIVE, pos_dir, only_owners: OWNERS_POS)
  File.write(File.join(ENV['BC2CPP_KEEP_DIR'], 'stack_tuples_pos.cxx'), pos_code) if ENV['BC2CPP_KEEP_DIR']
  check.call('positive fixture generates', !pos_code.to_s.empty?)
  POSITIVE_PLACED.each do |name|
    chunk = method_chunk(pos_code, 'TupPos', name)
    check.call("TupPos##{name} keeps its literal in a buffer", chunk.match?(/mrb_value bc2cpp_tup\d+\[\d+\];/))
  end
  POSITIVE_ONLY_LITERAL.each do |name|
    chunk = method_chunk(pos_code, 'TupPos', name)
    check.call("TupPos##{name} builds no mruby Array", !chunk.include?('mrb_ary_new_from_values'))
  end

  neg_dir = File.join(dir, 'neg')
  Dir.mkdir(neg_dir)
  neg_code, neg_err = runtime.generate(NEGATIVE, neg_dir, only_owners: OWNERS_NEG)
  File.write(File.join(ENV['BC2CPP_KEEP_DIR'], 'stack_tuples_neg.cxx'), neg_code) if ENV['BC2CPP_KEEP_DIR']
  NEGATIVE_EXPECTED.each_key do |row|
    owner, rest = row.split('.', 2)
    name = rest.sub(/\Anew\./, '').sub(/\(.*\z/, '')
    chunk = method_chunk(neg_code, owner, name)
    check.call("#{owner}##{name} refuses (keeps its Array)", !chunk.empty? && !chunk.include?('bc2cpp_tup'))
  end
  check.call('negative fixture has no bc2cpp_tup at all', !neg_code.include?('bc2cpp_tup'))

  off_code = generate_without_tuples(NEGATIVE, OWNERS_NEG)
  check.call('negative fixture is byte-identical with BC2CPP_STACK_TUPLES=0', neg_code == off_code)
  off_pos = generate_without_tuples(POSITIVE, OWNERS_POS)
  check.call('kill switch: positive fixture has no bc2cpp_tup', !off_pos.include?('bc2cpp_tup'))

  redef_dir = File.join(dir, 'redef')
  Dir.mkdir(redef_dir)
  redef_code, redef_err = runtime.generate(REDEFINED, redef_dir, only_owners: OWNERS_REDEF)
  check.call('redefined Array#size: no placement anywhere', !redef_code.include?('bc2cpp_tup'))
  check.call('redefined Array#size: byte-identical with BC2CPP_STACK_TUPLES=0',
             redef_code == generate_without_tuples(REDEFINED, OWNERS_REDEF))

  str_dir = File.join(dir, 'str')
  Dir.mkdir(str_dir)
  str_code, str_err = runtime.generate(STR_EQ, str_dir, core: true, only_owners: OWNERS_STR)
  %w[same branch twice neq].each do |name|
    check.call("StrEq##{name} compares the literal's bytes, with no String built for it",
               method_chunk(str_code, 'StrEq', name).include?('STRING_EQ_LITERAL'))
  end
  check.call('StrEq#kept keeps its literal, so the pair is not rewritten',
             !method_chunk(str_code, 'StrEq', 'kept').include?('STRING_EQ_LITERAL'))
  saved = ENV.fetch('BC2CPP_STRING_EQ_LITERAL', nil)
  ENV['BC2CPP_STRING_EQ_LITERAL'] = '0'
  str_off_code = Dir.mktmpdir('string-eq-off') { |off| runtime.generate(STR_EQ, off, core: true, only_owners: OWNERS_STR).first }
  saved.nil? ? ENV.delete('BC2CPP_STRING_EQ_LITERAL') : ENV['BC2CPP_STRING_EQ_LITERAL'] = saved
  check.call('kill switch: BC2CPP_STRING_EQ_LITERAL=0 rewrites nothing', !str_off_code.include?('STRING_EQ_LITERAL'))

  chr_dir = File.join(dir, 'chr')
  Dir.mkdir(chr_dir)
  chr_code, chr_err = runtime.generate(CHR_APP, chr_dir, core: true, only_owners: OWNERS_CHR)
  %w[bytes direct].each do |name|
    check.call("ChrApp##{name} appends the byte, with no one-character String built",
               method_chunk(chr_code, 'ChrApp', name).include?('CHR_APPEND: r'))
  end
  check.call('ChrApp#kept reads the chr result again, so the pair is not rewritten',
             !method_chunk(chr_code, 'ChrApp', 'kept').include?('CHR_APPEND'))
  saved_chr = ENV.fetch('BC2CPP_CHR_APPEND', nil)
  ENV['BC2CPP_CHR_APPEND'] = '0'
  chr_off_code = Dir.mktmpdir('chr-append-off') { |off| runtime.generate(CHR_APP, off, core: true, only_owners: OWNERS_CHR).first }
  saved_chr.nil? ? ENV.delete('BC2CPP_CHR_APPEND') : ENV['BC2CPP_CHR_APPEND'] = saved_chr
  check.call('kill switch: BC2CPP_CHR_APPEND=0 rewrites nothing', !chr_off_code.include?('CHR_APPEND'))

  sc_dir = File.join(dir, 'strcat')
  Dir.mkdir(sc_dir)
  sc_code, sc_err = runtime.generate(STRCAT_LIT, sc_dir, core: true, only_owners: OWNERS_SC)
  %w[plain nul multi mapped joined rescued].each do |name|
    chunk = method_chunk(sc_code, 'ScLit', name)
    check.call("ScLit##{name} appends its literal pieces, with no String built for them",
               chunk.include?('bc2cpp_str_cat_lit(M, r'))
  end
  check.call('ScLit#plain builds only its first piece, the accumulator',
             method_chunk(sc_code, 'ScLit', 'plain').scan('bc2cpp_pool_str(M, ').size == 1)
  check.call('ScLit#plain drops the String check of its proven accumulator',
             !method_chunk(sc_code, 'ScLit', 'plain').include?('mrb_ensure_string_type'))
  saved_sc = ENV.fetch('BC2CPP_STRCAT_LITERAL', nil)
  ENV['BC2CPP_STRCAT_LITERAL'] = '0'
  sc_off_code = Dir.mktmpdir('strcat-literal-off') { |off| runtime.generate(STRCAT_LIT, off, core: true, only_owners: OWNERS_SC).first }
  saved_sc.nil? ? ENV.delete('BC2CPP_STRCAT_LITERAL') : ENV['BC2CPP_STRCAT_LITERAL'] = saved_sc
  check.call('kill switch: BC2CPP_STRCAT_LITERAL=0 appends through a built String and keeps every String check',
             !sc_off_code.include?('// STRCAT_LITERAL: ') && !sc_off_code.include?('bc2cpp_str_cat_lit(M, r') &&
             method_chunk(sc_off_code, 'ScLit', 'plain').include?('mrb_ensure_string_type'))

  inl_dir = File.join(dir, 'inl')
  Dir.mkdir(inl_dir)
  inl_code, inl_err = runtime.generate(CALL_INL, inl_dir, core: true, only_owners: OWNERS_INL)
  { 'run' => ['IcPoint#sq', 'IcPoint#cmax', 'IcPoint#ident'], 'square' => ['IcPoint#sq'], 'pick' => ['IcPoint#cmax'],
    'down' => ['IcPoint#dec'], 'state' => ['IcPoint#bump', 'IcPoint#sumxy'], 'same' => ['IcPoint#me'] }.each do |name, callees|
    chunk = method_chunk(inl_code, 'IcUse', name)
    callees.each { |c| check.call("IcUse##{name} inlines #{c}", chunk.include?("// CALL_INLINE #{c} (")) }
  end
  check.call('IcPoint#twice inlines its self call to IcPoint#sumxy (an SSEND bound to one definition)',
             method_chunk(inl_code, 'IcPoint', 'twice').include?('// CALL_INLINE IcPoint#sumxy ('))
  check.call('IcUse#nosend keeps the call to a callee that sends', !method_chunk(inl_code, 'IcUse', 'nosend').include?('CALL_INLINE'))
  check.call('inlined bodies use their own register range, and the call line is gone',
             !method_chunk(inl_code, 'IcUse', 'square').include?('IcPoint_sq_impl(M'))
  saved_inl = ENV.fetch('BC2CPP_INLINE_CALLS', nil)
  ENV['BC2CPP_INLINE_CALLS'] = '0'
  inl_off_code = Dir.mktmpdir('call-inline-off') { |off| runtime.generate(CALL_INL, off, core: true, only_owners: OWNERS_INL).first }
  saved_inl.nil? ? ENV.delete('BC2CPP_INLINE_CALLS') : ENV['BC2CPP_INLINE_CALLS'] = saved_inl
  check.call('kill switch: BC2CPP_INLINE_CALLS=0 inlines nothing', !inl_off_code.include?('CALL_INLINE'))

  mr_dir = File.join(dir, 'mr')
  Dir.mkdir(mr_dir)
  mr_code, mr_err = runtime.generate(MULTI_RET, mr_dir, only_owners: OWNERS_MR)
  File.write(File.join(ENV['BC2CPP_KEEP_DIR'], 'multi_return.cxx'), mr_code) if ENV['BC2CPP_KEEP_DIR']
  MULTI_RETURN_PLACED.each do |name, callee|
    # The body only: a later method's rescue body is emitted ahead of that method's header.
    chunk = method_chunk(mr_code, 'MrPos', name).split(/^static mrb_value MrPos_/).first.to_s
    check.call("MrPos##{name} destructures MrPos##{callee} through its buffer, with no Array",
               chunk.include?("MrPos_#{callee}_mr(M, ") && !chunk.include?('bc2cpp_ary_entry'))
  end
  %w[pair strs pick raising].each do |name|
    check.call("MrPos##{name} writes its elements into the caller's buffer",
               method_chunk(mr_code, 'MrPos', name).include?("mrb_value MrPos_#{name}_mr(mrb_state* M, "))
  end
  MULTI_RETURN_KEPT.each do |name|
    check.call("MrPos##{name} keeps the Array", !method_chunk(mr_code, 'MrPos', name).match?(/MrPos_\w+_mr\(/))
  end
  check.call('MrPos#mixed (a nil return) has no buffer form', !mr_code.include?('MrPos_mixed_mr'))
  saved_mr = ENV.fetch('BC2CPP_MULTI_RETURN', nil)
  ENV['BC2CPP_MULTI_RETURN'] = '0'
  mr_off_code = Dir.mktmpdir('multi-return-off') { |off| runtime.generate(MULTI_RET, off, only_owners: OWNERS_MR).first }
  neg_mr_off = generate_without_tuples(NEGATIVE, OWNERS_NEG)
  saved_mr.nil? ? ENV.delete('BC2CPP_MULTI_RETURN') : ENV['BC2CPP_MULTI_RETURN'] = saved_mr
  check.call('kill switch: BC2CPP_MULTI_RETURN=0 passes no buffer', !mr_off_code.match?(/_mr\(/))
  check.call('a program with no destructured tuple call is byte-identical with BC2CPP_MULTI_RETURN=0',
             neg_mr_off == off_code)

  mm_dir = File.join(dir, 'mm')
  Dir.mkdir(mm_dir)
  mm_code, mm_err = runtime.generate(MINMAX, mm_dir, core: true, only_owners: OWNERS_MM)
  File.write(File.join(ENV['BC2CPP_KEEP_DIR'], 'literal_minmax.cxx'), mm_code) if ENV['BC2CPP_KEEP_DIR']
  MINMAX_PLACED.each do |name, op|
    chunk = method_chunk(mm_code, 'MmUse', name)
    check.call("MmUse##{name} calls bc2cpp_ary_#{op} with no Array", chunk.include?("bc2cpp_ary_#{op}(M, ") &&
               !chunk.include?('mrb_ary_new_from_values'))
  end
  check.call('MmUse#clamp places both literals', method_chunk(mm_code, 'MmUse', 'clamp').scan(/bc2cpp_ary_m(?:in|ax)\(M, /).size == 2)
  MINMAX_KEPT.each do |name|
    check.call("MmUse##{name} keeps the Array", !method_chunk(mm_code, 'MmUse', name).include?('bc2cpp_ary_m'))
  end
  saved_mm = ENV.fetch('BC2CPP_LITERAL_MINMAX', nil)
  ENV['BC2CPP_LITERAL_MINMAX'] = '0'
  mm_off_code = Dir.mktmpdir('literal-minmax-off') { |off| runtime.generate(MINMAX, off, core: true, only_owners: OWNERS_MM).first }
  saved_mm.nil? ? ENV.delete('BC2CPP_LITERAL_MINMAX') : ENV['BC2CPP_LITERAL_MINMAX'] = saved_mm
  check.call('kill switch: BC2CPP_LITERAL_MINMAX=0 calls no bc2cpp_ary_min/max', !mm_off_code.match?(/bc2cpp_ary_m(?:in|ax)\(/))

  # 2. parity, interpreted against compiled
  build = runtime.full_or_build
  if build
    [[OWNERS_POS, pos_dir, pos_err, POSITIVE_EXPECTED, 'positive'],
     [OWNERS_NEG, neg_dir, neg_err, NEGATIVE_EXPECTED, 'negative'],
     [OWNERS_REDEF, redef_dir, redef_err, REDEFINED_EXPECTED, 'redefined'],
     [OWNERS_STR, str_dir, str_err, STR_EQ_EXPECTED, 'string literal compare'],
     [OWNERS_CHR, chr_dir, chr_err, CHR_APP_EXPECTED, 'chr append'],
     [OWNERS_SC, sc_dir, sc_err, STRCAT_LIT_EXPECTED, 'interpolation literal append'],
     [OWNERS_INL, inl_dir, inl_err, CALL_INL_EXPECTED, 'call inline'],
     [OWNERS_MR, mr_dir, mr_err, MULTI_RET_EXPECTED, 'multi return'],
     [OWNERS_MM, mm_dir, mm_err, MINMAX_EXPECTED, 'literal min/max']].each do |owners, sub, err, expected, label|
      built, output = runtime.run(sub, err, owners, harness_rows.call(expected), build: build, full: true)
      sections = runtime.sections(output)
      check.call("#{label}: built and ran", built)
      check.call("#{label}: runtime parity, interpreted against compiled",
                 !sections['compiled'].to_a.empty? && sections['compiled'] == sections['interpreted'])
      expected.each do |src, value|
        check.call("#{label}: #{src} => #{value}", sections['compiled'].to_a.include?("#{src} => #{value}"))
      end
      warn output unless failures.empty?
    end
  else
    puts '  SKIP run: no full-core mruby build'
  end
end

abort "FAILED: #{failures.join(', ')}" unless failures.empty?
puts 'bc2cpp stack tuple arrays check: PASS'
