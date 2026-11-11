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
abort 'SKIP: set MRBC' unless ENV['MRBC']

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

# CALL_INLINE (codegen_call_inline.rb): a call the compiler already binds to one definition (here by the receiver being
# exactly a fresh IcPoint) becomes the callee's instructions when the callee is a small register-only body. The cases cover
# the Integer, Float, String and nil operands of the inlined arithmetic and compare (the slow arms), a branching callee, a
# callee that is only a move, index reads and writes, callees that send (explicit and self sends, one inlined twice
# into one method), a NoMethodError raised inside an inlined body, and a callee with a block (not inlined).
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
    def cells; @cells ||= [10, 20, 30]; end
    def at(i); cells[i]; end
    def put(i, v); cells[i] = v; end
    def zork(o); o.zork; end
    def sq2(n); sq(n) + sq(n); end
    def each_sq(a); a.map { |x| x * x }; end
    def label(n); n > 0 ? 'pos' : 'neg'; end
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
    def indexed(i); pt = IcPoint.new(0, 0); [pt.at(i), pt.put(i, 7), pt.at(i)]; end
    def sends(n); pt = IcPoint.new(0, 0); [pt.sq2(n), pt.sq2(n + 1), pt.flag(n)]; end
    def missing(o); IcPoint.new(0, 0).zork(o); end
    def blocky(a); IcPoint.new(0, 0).each_sq(a); end
    def named(n); pt = IcPoint.new(0, 0); [pt.label(n), pt.label(-n)]; end
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
  'IcUse.new.same' => 'true',
  'IcUse.new.indexed(1)' => '[20, 7, 7]',
  'IcUse.new.indexed(9)' => '[nil, 7, 7]',
  'begin; IcUse.new.indexed("x"); rescue => e; e.class; end' => 'TypeError',
  'IcUse.new.sends(3)' => '[18, 32, false]',
  'IcUse.new.sends(nil.to_i)' => '[0, 2, false]',
  'begin; IcUse.new.missing(1); rescue NoMethodError => e; e.class; end' => 'NoMethodError',
  'IcUse.new.blocky([1, 2, 3])' => '[1, 4, 9]',
  'IcUse.new.named(2)' => '["pos", "neg"]'
}.freeze
OWNERS_INL = %w[IcPoint IcUse].freeze

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

  inl_dir = File.join(dir, 'inl')
  Dir.mkdir(inl_dir)
  inl_code, inl_err = runtime.generate(CALL_INL, inl_dir, core: true, only_owners: OWNERS_INL)
  { 'run' => ['IcPoint#sq', 'IcPoint#cmax', 'IcPoint#ident'], 'square' => ['IcPoint#sq'], 'pick' => ['IcPoint#cmax'],
    'down' => ['IcPoint#dec'], 'state' => ['IcPoint#bump', 'IcPoint#sumxy'], 'same' => ['IcPoint#me'] }.each do |name, callees|
    chunk = method_chunk(inl_code, 'IcUse', name)
    callees.each { |c| check.call("IcUse##{name} inlines #{c}", chunk.include?("// CALL_INLINE #{c} (")) }
  end
  { 'indexed' => ['IcPoint#at', 'IcPoint#put'], 'sends' => ['IcPoint#sq2', 'IcPoint#flag'], 'missing' => ['IcPoint#zork'] }.each do |name, callees|
    chunk = method_chunk(inl_code, 'IcUse', name)
    callees.each { |c| check.call("IcUse##{name} inlines #{c}", chunk.include?("// CALL_INLINE #{c} (")) }
  end
  check.call('IcUse#named keeps the call to a callee that builds a String literal (STRING is not inlined)',
             !method_chunk(inl_code, 'IcUse', 'named').include?('CALL_INLINE'))
  check.call('IcUse#blocky keeps the call to a callee with a block', !method_chunk(inl_code, 'IcUse', 'blocky').include?('CALL_INLINE'))
  check.call('IcPoint#twice inlines its self call to IcPoint#sumxy (an SSEND bound to one definition)',
             method_chunk(inl_code, 'IcPoint', 'twice').include?('// CALL_INLINE IcPoint#sumxy ('))
  check.call('IcUse#nosend inlines IcPoint#flag, a callee that sends', method_chunk(inl_code, 'IcUse', 'nosend').include?('// CALL_INLINE IcPoint#flag ('))
  check.call('inlined bodies use their own register range, and the call line is gone',
             !method_chunk(inl_code, 'IcUse', 'square').include?('IcPoint_sq_impl(M'))
  saved_inl = ENV.fetch('BC2CPP_INLINE_CALLS', nil)
  ENV['BC2CPP_INLINE_CALLS'] = '0'
  inl_off_code = Dir.mktmpdir('call-inline-off') { |off| runtime.generate(CALL_INL, off, core: true, only_owners: OWNERS_INL).first }
  saved_inl.nil? ? ENV.delete('BC2CPP_INLINE_CALLS') : ENV['BC2CPP_INLINE_CALLS'] = saved_inl
  check.call('kill switch: BC2CPP_INLINE_CALLS=0 inlines nothing', !inl_off_code.include?('CALL_INLINE'))

  # 2. parity, interpreted against compiled
  build = runtime.full_or_build
  if build
    [[OWNERS_POS, pos_dir, pos_err, POSITIVE_EXPECTED, 'positive'],
     [OWNERS_NEG, neg_dir, neg_err, NEGATIVE_EXPECTED, 'negative'],
     [OWNERS_REDEF, redef_dir, redef_err, REDEFINED_EXPECTED, 'redefined'],
     [OWNERS_STR, str_dir, str_err, STR_EQ_EXPECTED, 'string literal compare'],
     [OWNERS_CHR, chr_dir, chr_err, CHR_APP_EXPECTED, 'chr append'],
     [OWNERS_INL, inl_dir, inl_err, CALL_INL_EXPECTED, 'call inline']].each do |owners, sub, err, expected, label|
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
