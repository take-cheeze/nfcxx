#!/usr/bin/env ruby
# frozen_string_literal: true

# ADR 0292: the else arm of a guarded numeric arm (FIXNUM_ARITHMETIC, FIXNUM_COMPARE, FLOAT_DIV_RECEIVER,
# INTEGER_LSHIFT, FIXNUM_SHIFT, FIXNUM_BINARY, INTEGER_UNARY) is a typed helper (bc2cpp_slow_<op>) that runs
# mruby's own numeric/bigint C entry point, and dispatches by name only for an operand class it does not own.
#
# 1. With MRBC: the generated code. Every such site in a method whose operands are unproven calls its helper
#    and has no by-name call of its own; the helper is defined once and holds the by-name fallback; a Ruby
#    redefinition of the operator (Integer#+, Float#-, Integer#<) puts the send back, and a proven site keeps
#    the NUMERIC_OPERAND_PROOF form without a helper.
# 2. With a full-core libmruby: the fixture's methods, compiled and interpreted, answer alike -- values
#    (Float bits included: -0.0, NaN), result representation (Integer#hash), exception class and message --
#    over a matrix of Fixnum / heap Integer / bigint / Float / nil / String / Array / user-class operands,
#    negative and oversized shift counts, floor division and modulo signs, at the top and bottom of the
#    Fixnum and mrb_int ranges. A numeric operand pair makes no by-name call, a bigint result leaves at most
#    one GC arena entry, and a loop of bigint arithmetic survives GC. The run repeats on a build whose
#    mrb_int is 32 bits (BC2CPP_MRUBY_FULL32, BC2CPP_MRBC32; -DMRB_32BIT -DMRB_INT32: 31-bit Fixnums) and,
#    with BC2CPP_MRUBY_NOBIGINT, on a build without mruby-bigint (where the bigint arms vanish).
#
# 3. ADR 0360 / 0364: the helpers whose operator only core classes answer (`/`, `^`, `>>`, `round`) have a closed
#    form with no by-name call; each is run directly against the real method over every member class pair, at all
#    three widths, and a user definer or a Complex/Rational build keeps the by-name body.
#
# 4. ADR 0367: `%` and `-@` call the bodies patches/mruby-expose-misc-bodies.patch exports (`mrb_int_mod_impl`,
#    `mrb_flo_mod_impl`, `mrb_str_uminus_impl`, `mrb_str_format_impl`); CoreMisc pins the wrappers that call them, so
#    an unpatched tree keeps the by-name helpers. The libmruby builds must come from a tree with every patch applied.
#
# 5. ADR 0366: `-`, `&`, `|` and `<<` run bodies mruby keeps static (Array#- & |, String#<<, IO#<<), which
#    patches/mruby-expose-collection-op-bodies.patch exports; their helpers are closed when the scanned tree carries
#    the patch and the build links the gems. scripts/bc2cpp/collection_ops_matrix.rb is the matrix: every helper
#    against the real operator over fresh receivers and operands (empty, frozen, subclass, shared, UTF-8, large,
#    nested, elements with a user hash/eql?/==, wrong operand types), comparing result or error class and message,
#    result class and identity, mutation of the receiver, the elements' logged calls and what an IO wrote.
#
# Usage: [MRBC=path/to/mrbc BC2CPP_MRUBY_FULL=dir BC2CPP_MRUBY_FULL32=dir BC2CPP_MRBC32=mrbc32
#         BC2CPP_MRUBY_NOBIGINT=dir BC2CPP_MRUBY_CORE=dir BC2CPP_NUMERIC_SLOW_ONLY=cmp|cmp-run|misc]
#         ruby scripts/bc2cpp/numeric_slow_check.rb

require 'tmpdir'
require_relative 'fixture_runtime'
require_relative 'collection_ops_matrix'

runtime = Bc2cppFixtureRuntime
# Every build this check runs against is full-core, so the exported gem bodies are linked.
runtime.collection_exports_linked = true
failures = []
# BC2CPP_NUMERIC_SLOW_ONLY=cmp runs only the comparison-helper sections (ADR 0362), cmp-run only their runs on libmruby.
ONLY_CMP = %w[cmp cmp-run].include?(ENV['BC2CPP_NUMERIC_SLOW_ONLY'])
ONLY_CMP_RUN = ENV['BC2CPP_NUMERIC_SLOW_ONLY'] == 'cmp-run'
# BC2CPP_NUMERIC_SLOW_ONLY=misc runs only the `%` / `-@` sections (ADR 0367).
ONLY_MISC = ENV['BC2CPP_NUMERIC_SLOW_ONLY'] == 'misc'
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

OPS = {
  'add' => '+', 'sub' => '-', 'mul' => '*', 'div' => '/', 'mod' => '%', 'band' => '&', 'bor' => '|',
  'bxor' => '^', 'lsh' => '<<', 'rsh' => '>>', 'lt' => '<', 'le' => '<=', 'gt' => '>', 'ge' => '>='
}.freeze
UNARY = { 'neg' => '-a', 'zero' => 'a.zero?', 'rnd' => 'a.round' }.freeze
HELPER = { '+' => 'add', '-' => 'sub', '*' => 'mul', '/' => 'div', '%' => 'mod', '&' => 'and', '|' => 'or',
           '^' => 'xor', '<<' => 'lshift', '>>' => 'rshift', '<' => 'lt', '<=' => 'le', '>' => 'gt', '>=' => 'ge' }.freeze

def open_methods
  OPS.map { |name, op| "    def #{name}(a, b) = a #{op} b" }.join("\n") + "\n" +
    UNARY.map { |name, expr| "    def #{name}(a) = #{expr}" }.join("\n")
end

FIXTURE = <<~RUBY
  class NsBox
    # Operators only a non-numeric receiver answers; the matrix below sends them numbers too.
    def +(o) = :box_add
    def -(o) = :box_sub
    def *(o) = :box_mul
    def /(o) = :box_div
    def <<(o) = :box_lsh
    def >>(o) = :box_rsh
    def inspect = "box"
  end

  class NsCmp
    include Comparable
    def <=>(o) = 0
    def inspect = "cmp"
  end

  # Called only from the driver, so no operand is proven.
  class NsOpen
  #{open_methods}

    def arena(a, b)
      w = NsProbe.arena
      a + b
      x = NsProbe.arena - w
      w = NsProbe.arena
      a - b
      y = NsProbe.arena - w
      w = NsProbe.arena
      a * b
      z = NsProbe.arena - w
      w = NsProbe.arena
      a / b
      q = NsProbe.arena - w
      w = NsProbe.arena
      a % b
      m = NsProbe.arena - w
      w = NsProbe.arena
      a << 3
      s = NsProbe.arena - w
      w = NsProbe.arena
      -a
      n = NsProbe.arena - w
      [x, y, z, q, m, s, n].max
    end

    def dispatched(a, b, op)
      w = NsProbe.dispatches
      case op
      when 0 then a + b
      when 1 then a - b
      when 2 then a * b
      when 3 then a / b
      when 4 then a % b
      when 5 then a & b
      when 6 then a | b
      when 7 then a ^ b
      when 8 then a << b
      when 9 then a >> b
      when 10 then a < b
      when 11 then a <= b
      when 12 then a > b
      when 13 then a >= b
      when 14 then -a
      when 15 then a.zero?
      when 16 then a.round
      end
      NsProbe.dispatches - w - 1 # the second probe call is itself one dispatch
    end
  end

  # Every operand here is proven an Integer or Float, so the sites keep the proof's form, no helper.
  class NsProven
    def run
      x = 7
      y = 2.5
      [x + 1, x * x, x - 3, y * 2, x < 9, y > 1.0, x / 2]
    end
  end
RUBY

FIXTURE_BIG = <<~RUBY
  class NsBig
    def churn(seed, n)
      acc = seed
      i = 0
      while i < n
        acc = (acc * 3 + i) % 340282366920938463463374607431768211457
        acc = acc >> 1 if i % 7 == 0
        acc = acc | 1
        acc = acc ^ 5
        acc = acc & 340282366920938463463374607431768211455
        acc = acc - 11 if acc > 99
        GC.start if i % 50 == 0
        i += 1
      end
      acc
    end

    def grow(seed, n)
      acc = seed
      n.times { acc = acc * 7 + 1 }
      acc
    end
  end
RUBY

# NUMERIC_SLOW_CLOSED (ADR 0360): no class of this world answers `/` except Integer and Float, so the helper's
# else is a proven NoMethodError instead of a by-name call. NsDivBox has no `/` (NsBox in FIXTURE does).
FIXTURE_DIV = <<~RUBY
  class NsDivBox
    def inspect = "divbox"
  end
  class NsDiv
    def div(a, b) = a / b
  end
RUBY

# NUMERIC_SLOW_CLOSED_CMP (ADR 0362): the numeric natives, Comparable's body (String, Symbol) and Hash's Ruby are
# the only answers to `<` `<=` `>` `>=`, so the helper mirrors the first two, keeps the method for a Hash and
# proves every other receiver a NoMethodError. NsSortKey has `<=>` without Comparable, which String and Symbol
# never reach. Neither class answers a comparison operator (NsCmp in FIXTURE includes Comparable).
FIXTURE_CMP = <<~RUBY
  class NsCmpBox
    def inspect = "cmpbox"
  end
  class NsSortKey
    def <=>(o) = 0
  end
  class NsCmpOpen
    def lt(a, b) = a < b
    def le(a, b) = a <= b
    def gt(a, b) = a > b
    def ge(a, b) = a >= b
  end
RUBY
CMP_OWNERS = %w[NsCmpOpen NsCmpBox NsSortKey].freeze
CMP_NAMES = { 'lt' => '<', 'le' => '<=', 'gt' => '>', 'ge' => '>=' }.freeze

# [what, source appended to FIXTURE_CMP, owners it adds, the helpers that stay closed]: a world that adds another
# answer to an operator, or another definition of the `<=>` the String/Symbol arm relies on, keeps the by-name helper
# of that operator (a `<` answer leaves `<=` `>` `>=` alone; a `<=>` one takes all four). NsSortKey in FIXTURE_CMP is
# the unrelated `<=>` definer that leaves them closed.
ALL = %w[lt le gt ge].freeze
REST = %w[le gt ge].freeze
NONE = [].freeze
CMP_WORLDS = [
  ['a class that includes Comparable', "class NsCmpUser\n  include Comparable\n  def <=>(o) = 0\nend\n", %w[NsCmpUser], NONE],
  ['a class that defines `<`', "class NsLess\n  def <(o) = true\nend\n", %w[NsLess], REST],
  ['a class method `<`', "class NsMetaLess\n  def self.<(o) = true\nend\n", %w[NsMetaLess], REST],
  ['a Hash subclass', "class NsHash < Hash\nend\n", %w[NsHash], NONE],
  ['a Numeric subclass', "class NsNum < Numeric\nend\n", %w[NsNum], NONE],
  ['a String subclass', "class NsStr < String\nend\n", %w[NsStr], NONE],
  ['Integer#< reopened', "class Integer\n  def <(o) = true\nend\n", %w[], REST],
  ['Comparable#< reopened', "module Comparable\n  def <(o) = true\nend\n", %w[], REST],
  ['String#<=> reopened', "class String\n  def <=>(o) = 0\nend\n", %w[], NONE],
  ['Symbol#<=> reopened', "class Symbol\n  def <=>(o) = 0\nend\n", %w[], NONE],
  ['Numeric#<=> reopened', "class Numeric\n  def <=>(o) = 0\nend\n", %w[], NONE],
  ['Object#<=> reopened', "class Object\n  def <=>(o) = 0\nend\n", %w[], NONE],
  ['a `<=>` on a class outside the lookup of String, Symbol and Numeric (NsSortKey)', "", %w[], ALL]
].freeze

# ADR 0364: `^` (Integer, nil, true, false), `>>` (Integer) and `round` (Integer, Float) are answered by no other
# class of this world. NsBitsBox has none of them (the main FIXTURE's NsBox defines `>>`, so `>>` stays open there).
FIXTURE_BITS = <<~RUBY
  class NsBitsBox
    def inspect = "bitsbox"
  end
  class NsBits
    def xor(a, b) = a ^ b
    def rsh(a, b) = a >> b
    def rnd(a) = a.round
  end
RUBY
BITS_OWNERS = %w[NsBits NsBitsBox].freeze

# Redefined operators: the arm must not be taken, the program's own method must still run.
REDEFINED = <<~RUBY
  class Integer
    def +(o) = :int_plus
  end
  class Float
    def -(o) = :flo_minus
  end
  class NsRe
    def add(a, b) = a + b
    def sub(a, b) = a - b
    def mul(a, b) = a * b
  end
RUBY
REDEFINED_CMP = <<~RUBY
  class Integer
    def <(o) = :int_lt
  end
  class NsReCmp
    def lt(a, b) = a < b
    def gt(a, b) = a > b
  end
RUBY

# Top Fixnum / mrb_int per build, as literals (AGENTS.md: a computed constant that crosses 32 bits breaks irep load).
# `:nobig` is the default-width build without mruby-bigint, where mrb_int is 32 bits wide and every Integer is a Fixnum.
WIDTHS = { 64 => { fmax: '4611686018427387903' }, 32 => { fmax: '1073741823' }, nobig: { fmax: '2147483647' } }.freeze

def driver(width)
  w = WIDTHS.fetch(width)
  <<~RUBY
    FM = #{w[:fmax]}
    IM = $bigint ? FM * 2 + 1 : FM # mrb_int max, computed: a parser without mruby-bigint rejects the 64-bit literal
    $vals = [0, 1, -1, 2, -2, 3, 7, -7, 10, FM, FM - 1, -FM, -FM - 1, IM, -IM, -IM - 1, 0.0, -0.0, 0.5, -1.5, 3.0,
             1.0e19, -1.0e19, Float::NAN, Float::INFINITY, -Float::INFINITY, nil, "s", [1], NsBox.new, NsCmp.new]
    $vals += [FM + 1, -FM - 2, IM + 1, -IM - 2, IM * 2, IM * IM, -(IM * IM), 2 ** 100, -(2 ** 100), 2.0 ** 70] if $bigint
    $counts = [0, 1, -1, 2, 5, 30, 31, 32, 33, 62, 63, 64, 65, 100, -2, -30, -31, -32, -62, -63, -64, -65, -100, -IM,
               -IM - 1, 2.5, -2.5, nil, "s", 1.0e19]
    $counts += [2 ** 100] if $bigint
    # The operand classes a helper owns, so the compiled run makes no by-name call for them.
    def owned(op, a, b)
      ca = a.is_a?(Float) ? :flt : (a.is_a?(Integer) ? :int : nil)
      cb = b.is_a?(Float) ? :flt : (b.is_a?(Integer) ? :int : nil)
      return false unless ca
      case op
      when 'add', 'sub', 'mul', 'div' then !cb.nil?
      when 'lt', 'le', 'gt', 'ge' then true
      when 'mod', 'band', 'bor', 'bxor' then ca == :int && cb == :int && !(op == 'mod' && b == 0)
      else false
      end
    end
    # `"s" * 2**62` and `[1] * 2**62` exhaust memory in the interpreter as well.
    def skip_repeat(op, a, b)
      op == 'mul' && (a.is_a?(String) || a.is_a?(Array)) && b.is_a?(Integer) && b.abs > 1000
    end
    def fmt(v)
      s = v.inspect
      s += " h=\#{v.hash}" if v.is_a?(Integer)
      s
    end
    def try
      fmt(yield)
    rescue => e
      "\#{e.class}: \#{e.message}"
    end
    o = NsOpen.new
    %w[add sub mul div mod band bor bxor lt le gt ge].each do |op|
      $vals.each do |a|
        $vals.each do |b|
          next if skip_repeat(op, a, b)
          puts "\#{op} \#{a.inspect} \#{b.inspect} => \#{try { o.send(op, a, b) }}"
        end
      end
    end
    %w[lsh rsh].each do |op|
      ($vals.grep(Integer) + [0.5, nil, "s"]).each do |a|
        $counts.each { |b| puts "\#{op} \#{a.inspect} \#{b.inspect} => \#{try { o.send(op, a, b) }}" }
      end
    end
    %w[neg zero rnd].each { |op| $vals.each { |a| puts "\#{op} \#{a.inspect} => \#{try { o.send(op, a) }}" } }
    puts 'end'
  RUBY
end

def generated_checks(check, runtime)
  puts '-- generated code (closed world)'
  Dir.mktmpdir do |dir|
    code, = runtime.generate(FIXTURE, dir, closed: true, only_owners: %w[NsOpen NsProven NsBox NsCmp])
    chunk = lambda do |owner_method|
      code[/^\/\/ #{Regexp.escape(owner_method)} \(compiled from.*?(?=^\/\/ \S+#\S+ \(compiled from|\z)/m].to_s
    end
    OPS.each do |name, op|
      c = chunk.call("NsOpen##{name}")
      key = HELPER.fetch(op)
      check.call("NsOpen##{name}: `#{op}` calls bc2cpp_slow_#{key} and has no by-name call of its own",
                 c.match?(/bc2cpp_slow_#{key}(?:_f)?\(M, /) && !c.include?('bc2cpp_send(') && !c.include?('mrb_funcall('))
      helper = code[/^static mrb_value bc2cpp_slow_#{key}(?:_f)?\(mrb_state\* M.*?^\}\n/m].to_s
      # `^` `%` `&` `|` have no definer outside the core in this world (ADR 0364, 0367, 0366): their helper is the
      # '#if Complex/Rational' pair, the by-name body in front and the closed form behind (checked in
      # closed_bits_generated_checks, closed_misc_generated_checks and
      # closed_collection_generated_checks).
      definitions = %w[xor mod and or].include?(key) ? 2 : 1
      check.call("bc2cpp_slow_#{key} is defined once and dispatches the operands it does not own",
                 code.scan(/^static mrb_value bc2cpp_slow_#{key}(?:_f)?\(/).size == definitions && helper.include?('bc2cpp_send('))
    end
    UNARY.each_key do |name|
      c = chunk.call("NsOpen##{name}")
      key = { 'neg' => 'neg', 'zero' => 'zero', 'rnd' => 'round' }.fetch(name)
      check.call("NsOpen##{name}: INTEGER_UNARY calls bc2cpp_slow_#{key}, no by-name call of its own",
                 c.match?(/bc2cpp_slow_#{key}(?:_f)?\(M, /) && !c.include?('bc2cpp_send(') && !c.include?('mrb_funcall('))
    end
    check.call('the Float receiver joins the +,-,* helpers and -@ when Float has no Ruby definition',
               code.include?('bc2cpp_slow_add_f(') && code.include?('bc2cpp_slow_neg_f('))
    check.call('the helpers release the GC arena (restore, then protect the result)',
               code[/^static mrb_value bc2cpp_slow_add_f\(.*?^\}\n/m].to_s.match?(/mrb_gc_arena_restore\(M, ai\);\s+mrb_gc_protect\(M, r\);/))
    check.call('bigint calls are guarded by MRB_USE_BIGINT and declared extern "C"',
               code.include?('#ifdef MRB_USE_BIGINT') && code.include?('extern "C" mrb_value mrb_bint_lshift'))
    proven = chunk.call('NsProven#run')
    check.call('a proven site keeps NUMERIC_OPERAND_PROOF and gets no helper',
               !proven.include?('bc2cpp_slow_') && !proven.include?('bc2cpp_send('))
    check.call('a non-numeric receiver still reaches a user-defined operator (NsBox) through the helper',
               code.include?('bc2cpp_send(M, a'))
  end

  Dir.mktmpdir do |dir|
    code, = runtime.generate(REDEFINED, dir, closed: true, only_owners: %w[NsRe])
    chunk = lambda do |owner_method|
      code[/^\/\/ #{Regexp.escape(owner_method)} \(compiled from.*?(?=^\/\/ \S+#\S+ \(compiled from|\z)/m].to_s
    end
    check.call('NEG: Integer#+ redefined in Ruby keeps the by-name call (no helper)',
               chunk.call('NsRe#add').include?('bc2cpp_send(') && !chunk.call('NsRe#add').include?('bc2cpp_slow_add'))
    check.call('Integer#+ redefined leaves `*` on its helper', chunk.call('NsRe#mul').include?('bc2cpp_slow_mul'))
    sub = chunk.call('NsRe#sub')
    check.call('NEG: Float#- redefined takes the Integer-only helper (the Float receiver keeps its by-name call)',
               sub.include?('bc2cpp_slow_sub(M') && !sub.include?('bc2cpp_slow_sub_f('))
  end

  Dir.mktmpdir do |dir|
    code, = runtime.generate(REDEFINED_CMP, dir, closed: true, only_owners: %w[NsReCmp])
    lt = code[/^\/\/ NsReCmp#lt \(compiled from.*?(?=^\/\/ \S+#\S+ \(compiled from|\z)/m].to_s
    check.call('NEG: Integer#< redefined keeps the by-name call', lt.include?('bc2cpp_send(') && !lt.include?('bc2cpp_slow_lt'))
  end
end

# The `/` helper of a world where only Integer and Float answer it.
def closed_div_generated_checks(check, runtime)
  puts '-- generated code (closed world, only Integer and Float answer `/`)'
  Dir.mktmpdir do |dir|
    code, = runtime.generate(FIXTURE_DIV, dir, closed: true, only_owners: %w[NsDiv NsDivBox])
    call = code[/^\/\/ NsDiv#div \(compiled from.*?(?=^\/\/ \S+#\S+ \(compiled from|\z)/m].to_s
    helper = code[/^#if defined\(MRB_USE_COMPLEX\) \|\| defined\(MRB_USE_RATIONAL\)\n(?:.*?^\}\n){2}\n*#endif\n/m].to_s
    check.call('NsDiv#div calls bc2cpp_slow_div and has no by-name call of its own',
               call.include?('bc2cpp_slow_div(M, ') && !call.include?('bc2cpp_send(') && !call.include?('mrb_funcall('))
    closed = helper.split("#else\n", 2)[1].to_s
    check.call('bc2cpp_slow_div holds no by-name call: any other receiver is a proven NoMethodError',
               !helper.empty? && !closed.empty? && !closed.include?('bc2cpp_send(') && !closed.include?('mrb_funcall(') &&
               closed.include?('bc2cpp_nomethod'))
    check.call('bc2cpp_slow_div keeps the by-name helper for a build with Complex or Rational operands',
               helper.start_with?('#if defined(MRB_USE_COMPLEX) || defined(MRB_USE_RATIONAL)') &&
               helper.split("#else\n", 2).first.include?('bc2cpp_send('))
  end
  Dir.mktmpdir do |dir|
    source = "#{FIXTURE_DIV}class NsDivBox\n  def /(o) = :divbox\nend\n"
    code, = runtime.generate(source, dir, closed: true, only_owners: %w[NsDiv NsDivBox])
    helper = code[/^static mrb_value bc2cpp_slow_div\(mrb_state\* M.*?^\}\n/m].to_s
    check.call('NEG: a user class answering `/` keeps the by-name call in the helper', helper.include?('bc2cpp_send('))
  end
end

# The two copies of a helper written twice (ADR 0360, 0361): [by-name copy for a Complex or Rational build, the
# closed copy], or nil when the helper is written once.
def helper_pair(code, key)
  m = code.match(/^#if defined\(MRB_USE_COMPLEX\) \|\| defined\(MRB_USE_RATIONAL\)\n(static mrb_value bc2cpp_slow_#{key}(?:_f)?\(mrb_state\* M.*?^\}\n\n)#else\n(.*?^\}\n\n)#endif\n/m)
  m && [m[1], m[2]]
end

# What mruby's own static bodies and the helper's mirrors of them stand on: the four bodies the String and Array
# arms rewrite, and the Integer/Float ones the numeric arms reach through mrb_num_*. A changed digest means the
# mruby tree changed one: re-derive the mirror before updating it. The one native definition of each operator per
# class is audited the same way, so a second definer (a gem redefining String#+ in C) cannot slip in.
# ADR 0366 adds the bodies of `- & | <<` the same way: the numeric and object.c ones the helpers mirror, Array#<<'s
# one-operand body (mrb_ary_push), and the three patched gems, whose wrappers and `_impl` bodies the exported functions
# split (the patch's own text is part of what is pinned).
MIRRORED_BODIES = {
  'src/array.c' => { 'mrb_ary_plus' => '70d052eb8d9b436a', 'mrb_ary_times' => '7b777f06a387ade7',
                     'mrb_ary_push_m' => '286db48a1f83255f' },
  'src/string.c' => { 'mrb_str_plus_m' => '1b53105d32fe238a', 'mrb_str_times' => '489feea491fd043d' },
  'src/numeric.c' => { 'int_add' => 'e2ff7790d345696a', 'int_mul' => 'ec37fa6c951f6b88',
                       'flo_add' => '2a7487f52044d706', 'flo_mul' => 'cf89b421d3a89f54',
                       'int_sub' => '659a377919b60994', 'flo_sub' => 'c2655d4207e6df80', 'int_and' => 'b2cd98473eb58b5b',
                       'int_or' => '6a1f42516621cc17', 'int_lshift' => '988fa8922d825990' },
  'src/numops.c' => { 'mrb_num_add' => 'e819f8f8fe810d67', 'mrb_num_mul' => 'ee5f08a1b611d22c',
                      'mrb_num_sub' => '3e8d0b786849d6e3' },
  'src/object.c' => { 'true_and' => '1e4ce0d7604fbb30', 'true_or' => 'b487ed39272e00bc',
                      'false_and' => '613a0eab4d74b51c', 'false_or' => '7496a278915d63d4' },
  'mrbgems/mruby-array-ext/src/array.c' => { 'ary_sub' => 'd8200c43d995a595', 'ary_union' => '668fec870a0e18a8',
                                             'ary_intersection' => 'dce89a213b2522ec',
                                             'mrb_ary_ext_sub_impl' => 'b5b13a123ae63c10',
                                             'mrb_ary_ext_or_impl' => 'd7da4ea4d7183cef',
                                             'mrb_ary_ext_and_impl' => '1998f2c25ba0b8ad' },
  'mrbgems/mruby-string-ext/src/string.c' => { 'str_concat' => '1b0e42f3a9bc4cde', 'str_concat_m' => '8d67d65d7ba98435',
                                               'mrb_str_ext_concat_impl' => '74f63294577109f8' },
  'mrbgems/mruby-io/src/io.c' => { 'io_lshift' => '4cd6ffc961668c8b', 'io_lshift_fd' => 'd9d256d1429a2215',
                                   'mrb_io_lshift_impl' => '461cd91be12adb81' }
}.freeze
OPERATOR_DEFINERS = { 'array.c' => 2, 'string.c' => 2, 'numeric.c' => 4, 'time.c' => 1 }.freeze

def mirrored_body_checks(check, root)
  require 'digest'
  mruby = File.join(root, '3rd/mruby')
  unless File.exist?(File.join(mruby, 'src/array.c'))
    puts '  SKIP: no 3rd/mruby tree to pin the mirrored bodies against'
    return
  end
  puts '-- the mruby bodies the closed `+` / `*` helpers mirror are unchanged, and no second native definer exists --'
  MIRRORED_BODIES.each do |file, bodies|
    text = File.read(File.join(mruby, file))
    bodies.each do |name, digest|
      body = text[/^#{Regexp.escape(name)}\(mrb_state \*mrb, mrb_value[^)]*\)\n\{.*?^\}\n/m].to_s
      got = Digest::SHA256.hexdigest(body.gsub(/\s+/, ''))[0, 16]
      check.call("#{file}: #{name} is the body the helper mirrors (#{got})", !body.empty? && got == digest)
    end
  end
  found = Hash.new(0)
  (core_native_srcs(mruby) + external_gem_native_srcs(root) + Dir[File.join(root, 'mruby-rgss/src/*.cxx')]).each do |path|
    File.read(path, encoding: 'BINARY').scan(/MRB_OPSYM\((?:add|mul)\)|mrb_define_method(?:_id)?\([^;]*"[+*]"/) { found[File.basename(path)] += 1 }
  end
  check.call("`+` and `*` have exactly the native definitions the helper covers (#{found.sort.to_h})", found == OPERATOR_DEFINERS)
end

def closed_arith_generated_checks(check, runtime)
  puts '-- generated code (closed world, only Integer, Float, Array and String answer `+` and `*`) --'
  fixture_owners = %w[NsArith NsArithBox NsArithConv NsArithStr NsArithAry]
  Dir.mktmpdir do |dir|
    code, = runtime.generate(FIXTURE_ARITH, dir, closed: true, only_owners: fixture_owners)
    call = code[/^\/\/ NsArith#add \(compiled from.*?(?=^\/\/ \S+#\S+ \(compiled from|\z)/m].to_s
    check.call('NsArith#add calls bc2cpp_slow_add_f and has no by-name call of its own',
               call.include?('bc2cpp_slow_add_f(M, ') && !call.include?('bc2cpp_send(') && !call.include?('mrb_funcall('))
    %w[add mul].each do |key|
      pair = helper_pair(code, key)
      check.call("bc2cpp_slow_#{key}_f is written twice: by name for Complex/Rational builds, closed otherwise", !pair.nil?)
      next unless pair

      open_form, closed = pair
      check.call("bc2cpp_slow_#{key}_f keeps its by-name copy for a build with Complex or Rational", open_form.include?('bc2cpp_send('))
      check.call("bc2cpp_slow_#{key}_f holds no by-name call: any other receiver is a proven NoMethodError",
                 !closed.include?('bc2cpp_send(') && !closed.include?('mrb_funcall(') && closed.include?('bc2cpp_nomethod'))
      check.call("bc2cpp_slow_#{key}_f has an arm for each of String and Array",
                 closed.include?('mrb_string_p(a)') && closed.include?('mrb_array_p(a)'))
      check.call("bc2cpp_slow_#{key}_f is defined once per preprocessor branch",
                 code.scan(/^static mrb_value bc2cpp_slow_#{key}_f\(/).size == 2)
    end
    pair = helper_pair(code, 'sub')
    check.call('bc2cpp_slow_sub_f is written twice: by name for Complex/Rational builds, closed otherwise (ADR 0366)', !pair.nil?)
    if pair
      open_form, closed = pair
      check.call('bc2cpp_slow_sub_f keeps its by-name copy for a build with Complex or Rational', open_form.include?('bc2cpp_send('))
      check.call('bc2cpp_slow_sub_f holds no by-name call: its Array arm is the exported Array#- body, any other receiver a proven NoMethodError',
                 !closed.include?('bc2cpp_send(') && !closed.include?('mrb_funcall(') && closed.include?('bc2cpp_nomethod') &&
                 closed.include?('mrb_ary_ext_sub_impl(M, a, b)') && closed.include?('mrb_ensure_array_type(M, b)') &&
                 closed.include?('extern "C" mrb_value mrb_ary_ext_sub_impl(mrb_state*, mrb_value, mrb_value);') &&
                 !closed.include?('mrb_string_p(a)'))
    end
  end
  Dir.mktmpdir do |dir|
    source = "#{FIXTURE_ARITH}class NsArithBox\n  def +(o) = :box_add\nend\n"
    code, = runtime.generate(source, dir, closed: true, only_owners: fixture_owners)
    check.call('NEG: a user class answering `+` keeps the by-name helper for `+`', helper_pair(code, 'add').nil? &&
               code[/^static mrb_value bc2cpp_slow_add_f\(mrb_state\* M.*?^\}\n/m].to_s.include?('bc2cpp_send('))
    check.call('...and `*` stays closed', !helper_pair(code, 'mul').nil?)
  end
  Dir.mktmpdir do |dir|
    source = "#{FIXTURE_ARITH}class NsArithBox\n  def -(o) = :box_sub\nend\n"
    code, = runtime.generate(source, dir, closed: true, only_owners: fixture_owners)
    check.call('NEG: a user class answering `-` keeps the by-name helper for `-`', helper_pair(code, 'sub').nil? &&
               code[/^static mrb_value bc2cpp_slow_sub_f\(mrb_state\* M.*?^\}\n/m].to_s.include?('bc2cpp_send('))
    check.call('...and `+` `*` stay closed', !helper_pair(code, 'add').nil? && !helper_pair(code, 'mul').nil?)
  end
  Dir.mktmpdir do |dir|
    source = "#{FIXTURE_ARITH}class NsArithBox\n  def *(o) = :box_mul\nend\n"
    code, = runtime.generate(source, dir, closed: true, only_owners: fixture_owners)
    check.call('NEG: a user class answering `*` keeps the by-name helper for `*`', helper_pair(code, 'mul').nil?)
    check.call('...and `+` stays closed', !helper_pair(code, 'add').nil?)
  end
  Dir.mktmpdir do |dir|
    source = "#{FIXTURE_ARITH}class Integer\n  def +(o) = :int_plus\nend\n"
    code, = runtime.generate(source, dir, closed: true, only_owners: fixture_owners)
    check.call('NEG: Integer#+ redefined in Ruby leaves no helper for `+`', !code.include?('bc2cpp_slow_add'))
  end
  Dir.mktmpdir do |dir|
    time = File.join(Bc2cppFixtureRuntime::ROOT, '3rd/mruby/mrbgems/mruby-time')
    code, = runtime.generate(FIXTURE_ARITH, dir, closed: true, only_owners: fixture_owners, build_gems: { 'mruby-time' => time })
    check.call('NEG: a build that links mruby-time keeps `+` by name (Time#+ is static in mruby-time)',
               helper_pair(code, 'add').nil? && code[/^static mrb_value bc2cpp_slow_add_f\(mrb_state\* M.*?^\}\n/m].to_s.include?('bc2cpp_send('))
    check.call('...and `*`, which Time does not answer, stays closed', !helper_pair(code, 'mul').nil?)
    check.call('NEG: ...and `-` (Time#-)', helper_pair(code, 'sub').nil?)
  end
  Dir.mktmpdir do |dir|
    saved = ENV['BC2CPP_NUMERIC_SLOW_CLOSED']
    ENV['BC2CPP_NUMERIC_SLOW_CLOSED'] = '0'
    begin
      code, = runtime.generate(FIXTURE_ARITH, dir, closed: true, only_owners: fixture_owners)
    ensure
      ENV['BC2CPP_NUMERIC_SLOW_CLOSED'] = saved
    end
    check.call('BC2CPP_NUMERIC_SLOW_CLOSED=0 restores the old helpers',
               %w[add mul sub].all? { |key| helper_pair(code, key).nil? } && code.include?('bc2cpp_send('))
  end
end

# NUMERIC_SLOW_CLOSED `+` and `*` (ADR 0361): the classes that answer them are Integer, Float, Array and String (Time
# is out of a world without mruby-time), so the helpers' else is a proven NoMethodError. `-` stays open (Array#-).
# NsArithBox has no operator; NsArithConv answers every implicit conversion mruby does not apply here.
FIXTURE_ARITH = <<~RUBY
  class NsArithBox
    def inspect = "arithbox"
  end
  class NsArithConv
    def to_str = "conv"
    def to_ary = [9]
    def to_int = 3
    def to_f = 1.5
    def inspect = "conv"
  end
  class NsArithStr < String
  end
  class NsArithAry < Array
  end
  class NsArith
    def add(a, b) = a + b
    def sub(a, b) = a - b
    def mul(a, b) = a * b

    def arena(a, b)
      w = NsProbe.arena
      a + b
      x = NsProbe.arena - w
      w = NsProbe.arena
      a * b
      y = NsProbe.arena - w
      [x, y].max
    end

    def dispatched(a, b, op)
      w = NsProbe.dispatches
      case op
      when 0 then a + b
      when 1 then a * b
      end
      NsProbe.dispatches - w - 1 # the second probe call is itself one dispatch
    end

    # Strings and Arrays built and dropped under GC pressure: the helpers' arena entries must not leak or dangle.
    def churn(n)
      acc = []
      s = ""
      i = 0
      while i < n
        acc = acc + [i, i.to_s]
        acc = acc * 1
        acc = acc[-20, 20] if acc.size > 40
        s = s + "ab"
        s = s * 1
        s = s[-30, 30] if s.size > 60
        GC.start if i % 50 == 0
        i += 1
      end
      [acc, s]
    end
  end
RUBY

# The same pairs on the repeat counts a String or Array may take: the interpreter allocates the result, so a count
# that would not overflow into an error is skipped (an empty Array loops count times, a one-byte String allocates it).
def arith_driver(width)
  <<~RUBY
  FM = #{WIDTHS.fetch(width)[:fmax]}
  IM = $bigint ? FM * 2 + 1 : FM # mrb_int max, computed: a parser without mruby-bigint rejects the 64-bit literal
  $vals = [0, 1, -1, 2, 3, 7, -7, 10, FM, FM - 1, -FM, -FM - 1, IM, -IM, -IM - 1, 0.0, -0.0, 0.5, -1.5, 3.0, 2.5, 1.0e19,
           -1.0e19, Float::NAN, Float::INFINITY, -Float::INFINITY, nil, true, false, :sym, "", "ab", "\\u3042\\u3044",
           "ab".freeze, NsArithStr.new("xy"), [], [1, 2], [[3], 4], [1, "a", nil].freeze, NsArithAry.new([5, 6]),
           Array.new(131072, 0), {a: 1}, 1..2, Object.new, NsArithBox.new, NsArithBox, NsArithConv.new, Class]
  $vals += [FM + 1, -FM - 2, IM + 1, -IM - 2, IM * IM, 2 ** 100, -(2 ** 100), 2.0 ** 70] if $bigint
  def skip_repeat(a, b)
    return false unless b.is_a?(Integer) && b > 1000
    return a.empty? if a.is_a?(Array)
    return false unless a.is_a?(String)
    # Only a count that overflows the length is cheap; without bigint IM is not mrb_int's maximum (64 bits on the host).
    a.bytesize > 0 && (!$bigint || b <= IM / a.bytesize)
  end
  def desc(v)
    return "object" if v.instance_of?(Object) # its inspect carries an address
    return "ary(\#{v.size}, \#{v.first.inspect})" if v.is_a?(Array) && v.size > 20
    s = v.inspect
    s += " cls=\#{v.class}" if v.is_a?(String) || v.is_a?(Array)
    s += " frozen" if v.frozen? && (v.is_a?(String) || v.is_a?(Array))
    s += " h=\#{v.hash}" if v.is_a?(Integer)
    s
  end
  def try
    desc(yield)
  rescue => e
    "\#{e.class}: \#{e.message}"
  end
  o = NsArith.new
  %w[add sub mul].each do |op|
    $vals.each do |a|
      $vals.each do |b|
        next if op == 'mul' && skip_repeat(a, b)
        puts "\#{op} \#{desc(a)} \#{desc(b)} => \#{try { o.send(op, a, b) }}"
      end
    end
  end
  puts 'end'
  RUBY
end

ARITH_SCENARIO = <<~CPP
  #include <string>
  struct ArithCase {
    const char* name;
    const char* op;
    mrb_value (*bin)(mrb_state*, mrb_value, mrb_value);
  };
  static const ArithCase arith_cases[] = {
    { "add", "+", bc2cpp_slow_add_f }, { "mul", "*", bc2cpp_slow_mul_f }, { "sub", "-", bc2cpp_slow_sub_f },
  };
  struct ArithCall { const ArithCase* c; mrb_value a, b; bool method; };
  static mrb_value arith_body(mrb_state* M, void* ud) {
    ArithCall* k = (ArithCall*)ud;
    return k->method ? (mrb_funcall)(M, k->a, k->c->op, 1, k->b) : k->c->bin(M, k->a, k->b);
  }
  // Class, message and the printed value (frozen-ness and class of a String or Array result included).
  static std::string arith_describe(mrb_state* M, mrb_value v, bool raised, bool class_only) {
    if (raised) {
      std::string out = std::string("raised ") + mrb_obj_classname(M, v);
      if (!class_only) {
        mrb_value msg = (mrb_funcall)(M, v, "message", 0);
        out += ": " + std::string(RSTRING_PTR(msg), RSTRING_LEN(msg));
      }
      return out;
    }
    mrb_value s = mrb_inspect(M, v);
    std::string out = std::string(mrb_obj_classname(M, v)) + " " + std::string(RSTRING_PTR(s), RSTRING_LEN(s));
    out += mrb_test((mrb_funcall)(M, v, "frozen?", 0)) ? " frozen" : " live";
    if (mrb_integer_p(v) || mrb_bigint_p(v)) {
      mrb_value h = mrb_inspect(M, (mrb_funcall)(M, v, "hash", 0));
      out += " h=" + std::string(RSTRING_PTR(h), RSTRING_LEN(h));
    }
    return out;
  }
  static int scenario(mrb_state* M) {
    RClass* probe = mrb_define_module(M, "NsProbe");
    mrb_define_class_method(M, probe, "arena", [](mrb_state* M, mrb_value) { return mrb_fixnum_value(mrb_gc_arena_save(M)); }, MRB_ARGS_NONE());
    mrb_define_class_method(M, probe, "dispatches", [](mrb_state*, mrb_value) { return mrb_fixnum_value(dispatches); }, MRB_ARGS_NONE());
    std::fflush(stdout);
    const char* src = R"BCD(__SOURCE__)BCD";
    mrb_load_string(M, src);
    if (M->exc) { mrb_print_error(M); M->exc = nullptr; return 1; }
    // Each helper called directly against the method it stands for, over every pair of the driver's values.
    mrb_value vals = mrb_gv_get(M, mrb_intern_lit(M, "$vals"));
    mrb_value skip_owner = mrb_obj_value(M->object_class);
    int total = 0, bad = 0;
    for (const ArithCase& c : arith_cases) {
      for (mrb_int i = 0; i < RARRAY_LEN(vals); ++i) for (mrb_int j = 0; j < RARRAY_LEN(vals); ++j) {
        mrb_value a = RARRAY_PTR(vals)[i], b = RARRAY_PTR(vals)[j];
        mrb_value skip = (mrb_funcall)(M, skip_owner, "skip_repeat", 2, a, b);
        if (c.name[0] == 'm' && mrb_test(skip)) continue;
        int ai = mrb_gc_arena_save(M);
        ArithCall got_call = { &c, a, b, false }, want_call = { &c, a, b, true };
        mrb_bool e1 = FALSE, e2 = FALSE;
        mrb_value got = mrb_protect_error(M, arith_body, &got_call, &e1);
        mrb_value want = mrb_protect_error(M, arith_body, &want_call, &e2);
        // Two Integers are vm.c OP_MATH in the helper: an MRB_INT_MIN operand (wrong in the 32-bit bigint core's
        // Integer#op) is skipped, and without bigint the overflow RangeError is worded differently.
        bool ints = mrb_integer_p(a) && mrb_integer_p(b);
        if (ints && (mrb_integer(a) == MRB_INT_MIN || mrb_integer(b) == MRB_INT_MIN)) { mrb_gc_arena_restore(M, ai); continue; }
  #ifdef MRB_USE_BIGINT
        bool class_only = false;
  #else
        bool class_only = ints && e1 && e2;
  #endif
        std::string g = arith_describe(M, got, e1, class_only), w = arith_describe(M, want, e2, class_only);
        mrb_gc_arena_restore(M, ai);
        ++total;
        if (g != w) {
          ++bad;
          if (bad <= 8) {
            mrb_value as = mrb_inspect(M, a), bs = mrb_inspect(M, b);
            std::printf("  H MISMATCH %s %.60s %.60s helper=%.200s method=%.200s\\n", c.name, RSTRING_PTR(as), RSTRING_PTR(bs), g.c_str(), w.c_str());
          }
        }
      }
    }
    std::printf("  H summary %d cases, %d mismatches\\n", total, bad);
    return 0;
  }
CPP

# The helper of `key` as generated: [the #if-wrapped by-name form, the closed form] or nil when the helper has one body.
def cmp_helper_forms(code, key)
  wrapped = code[/^#if defined\(MRB_USE_COMPLEX\) \|\| defined\(MRB_USE_RATIONAL\)\n(?:static mrb_value bc2cpp_slow_#{key}\(.*?^\}\n\n)#else\n(?:static mrb_value bc2cpp_slow_#{key}\(.*?^\}\n\n)#endif\n/m]
  return nil unless wrapped

  by_name, closed = wrapped.split("#else\n", 2)
  [by_name, closed.to_s.sub(/#endif\n\z/, '')]
end

# The comparison helpers of a world where only the numeric natives, Comparable and Hash answer an operator.
def closed_cmp_generated_checks(check, runtime)
  puts '-- generated code (closed world, comparison operators answered by numbers, Comparable and Hash)'
  Dir.mktmpdir do |dir|
    code, = runtime.generate(FIXTURE_CMP, dir, closed: true, only_owners: CMP_OWNERS)
    CMP_NAMES.each do |name, op|
      call = code[/^\/\/ NsCmpOpen##{name} \(compiled from.*?(?=^\/\/ \S+#\S+ \(compiled from|\z)/m].to_s
      check.call("NsCmpOpen##{name} calls bc2cpp_slow_#{name} and has no by-name call of its own",
                 call.include?("bc2cpp_slow_#{name}(M, ") && !call.include?('bc2cpp_send(') && !call.include?('mrb_funcall('))
      by_name, closed = cmp_helper_forms(code, name)
      check.call("bc2cpp_slow_#{name}: the closed form is only a Hash call by name; every other receiver is a proven NoMethodError",
                 closed && closed.scan('bc2cpp_send(').size == 1 && closed.include?('MRB_TT_HASH') &&
                 closed.include?('bc2cpp_nomethod(') && closed.include?('mrb_cmp(') &&
                 closed.include?('comparison of %T with %T failed') && !closed.include?('mrb_funcall('))
      check.call("bc2cpp_slow_#{name} keeps the by-name helper for a build with Complex or Rational operands",
                 by_name && by_name.include?('bc2cpp_send(') && by_name.include?('comparison of %t with %t failed') &&
                 !by_name.include?('MRB_TT_HASH'))
    end
  end
  CMP_WORLDS.each do |what, extra, owners, closed|
    Dir.mktmpdir do |dir|
      code, = runtime.generate("#{FIXTURE_CMP}#{extra}", dir, closed: true, only_owners: CMP_OWNERS + owners)
      forms = CMP_NAMES.keys.select { |name| cmp_helper_forms(code, name) }
      check.call("#{closed == ALL ? 'POS' : 'NEG'}: #{what}: the closed form stays on [#{closed.join(' ')}]", forms == closed)
    end
  end
  Dir.mktmpdir do |dir|
    saved = ENV['BC2CPP_NUMERIC_SLOW_CLOSED']
    ENV['BC2CPP_NUMERIC_SLOW_CLOSED'] = '0'
    begin
      code, = runtime.generate(FIXTURE_CMP, dir, closed: true, only_owners: CMP_OWNERS)
    ensure
      ENV['BC2CPP_NUMERIC_SLOW_CLOSED'] = saved
    end
    check.call('BC2CPP_NUMERIC_SLOW_CLOSED=0 keeps the by-name helpers',
               CMP_NAMES.keys.none? { |name| cmp_helper_forms(code, name) } && code.include?('bc2cpp_slow_lt('))
  end
  Dir.mktmpdir do |dir|
    code, = runtime.generate(FIXTURE_CMP, dir, closed: false, only_owners: CMP_OWNERS)
    check.call('NEG: an open world keeps the by-name helpers', CMP_NAMES.keys.none? { |name| cmp_helper_forms(code, name) })
  end
end

# ADR 0367: `%` (Integer, Float, String) and `-@` (Integer, Float, Numeric, String) are answered by no other class of
# this world. NsMiscBox has neither; NsMiscNum is a Numeric that defines no operator (`-@` is Numeric's `0 - self`);
# NsMiscConv answers every implicit conversion mruby could apply to an operand; NsMutator's to_s empties the Array
# the format reads its arguments from.
FIXTURE_MISC = <<~RUBY
  class NsMiscBox
    def inspect = "miscbox"
    def to_s = "box"
  end
  class NsMiscNum < Numeric
    def inspect = "miscnum"
    def to_s = "miscnum"
  end
  class NsMiscStr < String
  end
  class NsMiscAry < Array
  end
  class NsMiscConv
    def to_str = "%s!"
    def to_ary = [9]
    def to_int = 3
    def to_f = 1.5
    def to_s = "conv"
    def inspect = "conv"
  end
  class NsMutator
    def initialize(a) = @a = a
    def to_s
      3.times { @a.shift } # not `clear`: an RGSS native of that name would take the call
      "m"
    end
  end
  class NsMisc
    def mod(a, b) = a % b
    def neg(a) = -a

    def arena(a, b)
      w = NsProbe.arena
      a % b
      x = NsProbe.arena - w
      w = NsProbe.arena
      -a
      y = NsProbe.arena - w
      [x, y].max
    end

    def dispatched(a, b, op)
      w = NsProbe.dispatches
      op == 0 ? a % b : -a
      NsProbe.dispatches - w - 1 # the second probe call is itself one dispatch
    end

    # Formats and frozen copies built and dropped under GC pressure: the arena entries must not leak or dangle.
    def churn(n)
      acc = []
      i = 0
      while i < n
        s = "%05d-%s-%x" % [i, "ab" * 3, i * 7]
        t = -s
        u = -(s + "x")
        acc << [s, t.frozen?, u.frozen?, t.equal?(s)]
        acc = acc[-10, 10] if acc.size > 20
        GC.start if i % 50 == 0
        i += 1
      end
      acc
    end
  end
RUBY
MISC_OWNERS = %w[NsMisc NsMiscBox NsMiscNum NsMiscStr NsMiscAry NsMiscConv NsMutator].freeze

def misc_driver(width)
  <<~RUBY
    FM = #{WIDTHS.fetch(width)[:fmax]}
    IM = $bigint ? FM * 2 + 1 : FM # mrb_int max, computed: a parser without mruby-bigint rejects the 64-bit literal
    $fmts = ["", "abc", "%d", "%i", "%u", "%s", "%p", "%%", "%x", "%X", "%o", "%b", "%B", "%e", "%E", "%f", "%g",
             "%G", "%a", "%5.2f", "%-6s|", "%+d", "% d", "%05d", "%#x", "%#o", "%*d", "%-*d", "%1$s %1$s", "%2$s %1$s",
             "%<a>d", "%<a>s", "%{a}", "%<a>5.1f", "%s %s", "%d %d %d", "%.3s", "%10.4s|", "%\\u3042",
             "\\u3042%s\\u3044", "%s" * 10, "%", "%z", "%-", "a\\0b%s", "%.0f", "%.10g", "% 5d", "%+.2e", "%08.3f",
             "%x%%%s", "%.2s", "%s\\n"]
    $strs = $fmts + ["%d".freeze, "%s".dup, NsMiscStr.new("%s-%s"), NsMiscStr.new("%d").freeze, "\\u3042\\u3044", "ab"]
    $nums = [0, 1, -1, 2, -2, 3, 7, -7, 10, 255, FM, FM - 1, -FM, -FM - 1, IM, -IM, -IM - 1, 0.0, -0.0, 0.5, -1.5, 2.5, 3.0,
             1.0e19, -1.0e19, 1.0e-5, Float::NAN, Float::INFINITY, -Float::INFINITY]
    $nums += [FM + 1, -FM - 2, IM + 1, -IM - 2, IM * 2, IM * IM, -(IM * IM), 2 ** 100, -(2 ** 100), 2.0 ** 70] if $bigint
    $others = [nil, true, false, :sym, :"", [], [1], [1, 2], [1, 2, 3], ["a", "b"], [[1]], [nil], [1.5, "x", :s], {}, {a: 1},
               {a: 1.5, b: "x"}, Hash.new(0), 1..2, NsMiscBox.new, NsMiscNum.new, Numeric.new, NsMiscAry.new([1, 2]),
               NsMiscConv.new, NsMiscBox, NsMiscNum, String, Integer, Object.new]
    $recvs = $nums + $strs + $others
    # The right-hand operands: numbers, format arguments, and every other class (Object.new and Numeric.new print an
    # address, so they are receivers only).
    $args = $nums + ["s", "42", "3.5", "", "\\u3042"] + $others.reject { |v| v.instance_of?(Object) || v.instance_of?(Numeric) }
    $vals = $recvs
    # ASCII only, so the run does not depend on the bytes a format produces (`%c` of a large code point).
    def esc(s)
      s.each_byte.map { |b| b < 128 ? b.chr : 92.chr + "x" + b.to_s(16) }.join
    end
    def desc(v)
      s = esc(v.inspect)
      s = "\#<\#{v.class}>" if s.include?(':0x') # a plain object's inspect carries an address
      s += " cls=\#{v.class}" if v.is_a?(String) || v.is_a?(Array)
      s += " frozen" if v.frozen? && (v.is_a?(String) || v.is_a?(Array))
      s += " h=\#{v.hash}" if v.is_a?(Integer)
      s
    end
    def try
      desc(yield)
    rescue => e
      "\#{e.class}: \#{esc(e.message)}"
    end
    def mut
      a = []
      a << NsMutator.new(a) << 1 << 2
      a
    end
    o = NsMisc.new
    $recvs.each do |a|
      $args.each { |b| puts "mod \#{desc(a)} \#{desc(b)} => \#{try { o.mod(a, b) }}" }
    end
    $recvs.each do |a|
      puts "neg \#{desc(a)} => \#{try { o.neg(a) }}"
      puts "neg same \#{desc(a)} => \#{try { a.frozen? && o.neg(a).equal?(a) }}" if a.is_a?(String)
    end
    # %c with a code point that is not a character reads an unset buffer under MRB_UTF8_STRING, so only valid ones are rows.
    ["%c", "%3c", "%-3c|", "%c%c"].each do |f|
      [65, 97, 0x3042, "x", "xy", "", nil, :sym, 1.5, [65, 66], [65, "z"]].each { |v| puts "chr \#{f} \#{desc(v)} => \#{try { o.mod(f, v) }}" }
    end
    puts "mut => \#{try { o.mod('%s %d %d', mut) }}"
    puts "mut short => \#{try { o.mod('%s %s', mut) }}"
    puts "mut hash => \#{try { o.mod('%{a} %s', mut) }}"
    puts 'end'
  RUBY
end

# The two helpers called directly (the generated TU is part of main.cpp) against the method they stand for. A receiver
# a helper owns makes no by-name call; every other receiver one, the proof's dispatch that raises the NoMethodError.
# `__LEGACY__` is 1 for a build that defines MRB_USE_COMPLEX / MRB_USE_RATIONAL, where the by-name copies run instead.
MISC_SCENARIO = <<~CPP
  #include <string>
  struct MiscCase { const char* name; const char* op; mrb_value (*bin)(mrb_state*, mrb_value, mrb_value); mrb_value (*un)(mrb_state*, mrb_value); };
  static const MiscCase misc_cases[] = {
    { "mod", "%", bc2cpp_slow_mod, nullptr }, { "neg", "-@", nullptr, bc2cpp_slow_neg_f },
  };
  struct MiscCall { const MiscCase* c; mrb_value a, b; bool method; };
  static mrb_value misc_body(mrb_state* M, void* ud) {
    MiscCall* k = (MiscCall*)ud;
    if (k->method) return k->c->un ? (mrb_funcall)(M, k->a, k->c->op, 0) : (mrb_funcall)(M, k->a, k->c->op, 1, k->b);
    return k->c->un ? k->c->un(M, k->a) : k->c->bin(M, k->a, k->b);
  }
  // Class, message and printed value; a String or Array result also its class, frozen-ness and identity with the receiver.
  static std::string misc_describe(mrb_state* M, mrb_value v, bool raised, mrb_value recv) {
    if (raised) {
      mrb_value msg = (mrb_funcall)(M, v, "message", 0);
      return std::string("raised ") + mrb_obj_classname(M, v) + ": " + std::string(RSTRING_PTR(msg), RSTRING_LEN(msg));
    }
    mrb_value s = mrb_inspect(M, v);
    std::string out(RSTRING_PTR(s), RSTRING_LEN(s));
    if (mrb_string_p(v) || mrb_array_p(v)) {
      out += std::string(" cls=") + mrb_obj_classname(M, v);
      out += mrb_test((mrb_funcall)(M, v, "frozen?", 0)) ? " frozen" : " live";
      out += mrb_obj_eq(M, v, recv) ? " same" : " fresh";
    }
    if (mrb_integer_p(v) || mrb_bigint_p(v)) {
      mrb_value h = mrb_inspect(M, (mrb_funcall)(M, v, "hash", 0));
      out += " h=" + std::string(RSTRING_PTR(h), RSTRING_LEN(h));
    }
    return out;
  }
  // Receivers a helper owns: no by-name call. Numeric receivers are Integer, Float, bigint and any Numeric for `-@`;
  // String for both; `%` has Integer, Float and String.
  static bool misc_owned(mrb_state* M, const MiscCase& c, mrb_value a) {
    bool num = mrb_integer_p(a) || mrb_bigint_p(a) || mrb_float_p(a);
    if (c.un) return num || mrb_string_p(a) || mrb_obj_is_kind_of(M, a, mrb_class_get(M, "Numeric"));
    return num || mrb_string_p(a);
  }
  static int scenario(mrb_state* M) {
    RClass* probe = mrb_define_module(M, "NsProbe");
    mrb_define_class_method(M, probe, "arena", [](mrb_state* M, mrb_value) { return mrb_fixnum_value(mrb_gc_arena_save(M)); }, MRB_ARGS_NONE());
    mrb_define_class_method(M, probe, "dispatches", [](mrb_state*, mrb_value) { return mrb_fixnum_value(dispatches); }, MRB_ARGS_NONE());
    std::fflush(stdout);
    const char* src = R"BCD(__SOURCE__)BCD";
    mrb_load_string(M, src);
    if (M->exc) { mrb_print_error(M); M->exc = nullptr; return 1; }
    mrb_value recvs = mrb_gv_get(M, mrb_intern_lit(M, "$recvs"));
    mrb_value args = mrb_gv_get(M, mrb_intern_lit(M, "$args"));
    int total = 0, bad = 0, wrong_calls = 0, strings = 0, errors = 0;
    for (const MiscCase& c : misc_cases) {
      mrb_int nb = c.un ? 1 : RARRAY_LEN(args);
      for (mrb_int i = 0; i < RARRAY_LEN(recvs); ++i) for (mrb_int j = 0; j < nb; ++j) {
        mrb_value a = RARRAY_PTR(recvs)[i];
        mrb_value b = c.un ? mrb_nil_value() : RARRAY_PTR(args)[j];
        int ai = mrb_gc_arena_save(M);
        MiscCall got_call = { &c, a, b, false }, want_call = { &c, a, b, true };
        mrb_bool e1 = FALSE, e2 = FALSE;
        dispatches = 0;
        mrb_value got = mrb_protect_error(M, misc_body, &got_call, &e1);
        int made = dispatches;
        std::string g = misc_describe(M, got, e1, a);
        mrb_value want = mrb_protect_error(M, misc_body, &want_call, &e2);
        std::string w = misc_describe(M, want, e2, a);
        mrb_gc_arena_restore(M, ai);
        ++total;
        if (e1) ++errors;
        if (mrb_string_p(a)) ++strings;
        if (__LEGACY__ == 0) {
          int expect = misc_owned(M, c, a) ? 0 : 1;
          if (made != expect) {
            ++wrong_calls;
            if (wrong_calls <= 8) std::printf("  H DISPATCH %s %d by-name calls, expected %d: %s\\n", c.name, made, expect, g.c_str());
          }
        }
        if (g != w) {
          ++bad;
          if (bad <= 8) {
            mrb_value as = mrb_inspect(M, a), bs = mrb_inspect(M, b);
            std::printf("  H MISMATCH %s %.*s %.*s helper=%s method=%s\\n", c.name, (int)RSTRING_LEN(as), RSTRING_PTR(as),
                        (int)RSTRING_LEN(bs), RSTRING_PTR(bs), g.c_str(), w.c_str());
          }
        }
      }
    }
    std::printf("  H summary %d cases, %d mismatches, %d wrong dispatch counts (%d errors, %d String receivers)\\n",
                total, bad, wrong_calls, errors, strings);
    return 0;
  }
CPP

# [what, source appended to FIXTURE_MISC, owners it adds, the helpers that stay closed]: a world that adds another
# answer to an operator, or another definition of what the String arm of `%` calls, keeps the by-name helper.
MISC_WORLDS = [
  ['a class that defines `%`', "class NsPct\n  def %(o) = 1\nend\n", %w[NsPct], %w[neg]],
  ['a class that defines `-@`', "class NsNeg\n  def -@ = 1\nend\n", %w[NsNeg], %w[mod]],
  ['a class method `%`', "class NsMetaPct\n  def self.%(o) = 1\nend\n", %w[NsMetaPct], %w[neg]],
  ['a String subclass that defines `%`', "class NsStrPct < String\n  def %(o) = 1\nend\n", %w[NsStrPct], %w[neg]],
  ['a Numeric subclass that defines `-@`', "class NsNumNeg < Numeric\n  def -@ = 1\nend\n", %w[NsNumNeg], %w[mod]],
  ['Integer#% reopened', "class Integer\n  def %(o) = 1\nend\n", %w[], %w[neg]],
  ['String#% reopened', "class String\n  def %(o) = 1\nend\n", %w[], %w[neg]],
  ['String#-@ reopened', "class String\n  def -@ = 1\nend\n", %w[], %w[mod]],
  ['Numeric#-@ reopened', "class Numeric\n  def -@ = 1\nend\n", %w[], %w[mod]],
  ['Integer#- reopened (the `0 - self` of Numeric#-@)', "class Integer\n  def -(o) = 1\nend\n", %w[], %w[mod]],
  ['a user `is_a?` (String#% calls it)', "class NsIsA\n  def is_a?(k) = true\nend\n", %w[NsIsA], %w[neg]],
  ['a user `kind_of?` leaves `%` closed', "class NsKindOf\n  def kind_of?(k) = true\nend\n", %w[NsKindOf], %w[mod neg]],
  ['a user `sprintf` (String#% calls it)', "class NsSprintf\n  def sprintf(*a) = 1\nend\n", %w[NsSprintf], %w[neg]],
  ['`Array` rebound', "Array = Hash\n", %w[], %w[neg]],
  ['a class under BasicObject (no Kernel#is_a?)', "class NsBare < BasicObject\nend\n", %w[NsBare], %w[neg]],
  ['a constant bound to BasicObject', "NS_BASE = BasicObject\n", %w[], %w[neg]]
].freeze

# The two helpers of a world where only Integer, Float, String and Numeric answer `%` and `-@`.
def closed_misc_generated_checks(check, runtime)
  puts '-- generated code (closed world, `%` and `-@` answered by Integer, Float, String and Numeric only)'
  Dir.mktmpdir do |dir|
    code, = runtime.generate(FIXTURE_MISC, dir, closed: true, only_owners: MISC_OWNERS)
    { 'mod' => ['NsMisc#mod', '%'], 'neg' => ['NsMisc#neg', '-@'] }.each do |key, (method, op)|
      call = code[/^\/\/ #{Regexp.escape(method)} \(compiled from.*?(?=^\/\/ \S+#\S+ \(compiled from|\z)/m].to_s
      check.call("#{method} calls bc2cpp_slow_#{key} and has no by-name call of its own",
                 call.match?(/bc2cpp_slow_#{key}(?:_f)?\(M, /) && !call.include?('bc2cpp_send(') && !call.include?('mrb_funcall('))
      by_name, closed = helper_pair(code, key).to_a
      check.call("bc2cpp_slow_#{key} (`#{op}`) is written twice: by name for Complex/Rational builds, closed otherwise", !closed.nil?)
      next unless closed

      check.call("bc2cpp_slow_#{key} holds no by-name call: any other receiver is a proven NoMethodError",
                 !closed.include?('bc2cpp_send(') && !closed.include?('mrb_funcall(') && closed.include?('bc2cpp_nomethod('))
      check.call("bc2cpp_slow_#{key} keeps the by-name copy for a build with Complex or Rational", by_name.include?('bc2cpp_send('))
    end
    _, mod = helper_pair(code, 'mod').to_a
    check.call('bc2cpp_slow_mod calls the exported bodies: Integer#%, Float#% and the sprintf formatter (String#%)',
               mod.to_s.include?('mrb_int_mod_impl(M, a, b)') && mod.to_s.include?('mrb_flo_mod_impl(M, a, b)') &&
               mod.to_s.include?('mrb_str_format_impl(') && mod.to_s.include?('extern "C" mrb_value mrb_int_mod_impl('))
    check.call('...with the Array test String#% makes (Kernel#is_a? against Array), copying the elements the splat copies',
               mod.to_s.include?('mrb_obj_is_kind_of(M, b, M->array_class)') && mod.to_s.include?('mrb_ary_new_from_values('))
    _, neg = helper_pair(code, 'neg').to_a
    check.call('bc2cpp_slow_neg calls String#-@ (exported) and mirrors Numeric#-@ (`0 - self`) for the rest',
               neg.to_s.include?('mrb_str_uminus_impl(M, a)') && neg.to_s.include?('mrb_num_sub(M, mrb_fixnum_value(0), a)') &&
               neg.to_s.include?('mrb_bint_sub_ii('))
  end
  MISC_WORLDS.each do |what, extra, owners, closed|
    Dir.mktmpdir do |dir|
      code, = runtime.generate("#{FIXTURE_MISC}#{extra}", dir, closed: true, only_owners: MISC_OWNERS + owners)
      forms = %w[mod neg].select { |key| helper_pair(code, key) }
      check.call("NEG: #{what}: the closed form stays on [#{closed.join(' ')}]", forms == closed)
    end
  end
  Dir.mktmpdir do |dir|
    saved = ENV['BC2CPP_NUMERIC_SLOW_CLOSED']
    ENV['BC2CPP_NUMERIC_SLOW_CLOSED'] = '0'
    begin
      code, = runtime.generate(FIXTURE_MISC, dir, closed: true, only_owners: MISC_OWNERS)
    ensure
      ENV['BC2CPP_NUMERIC_SLOW_CLOSED'] = saved
    end
    check.call('BC2CPP_NUMERIC_SLOW_CLOSED=0 keeps the by-name helpers', %w[mod neg].none? { |key| helper_pair(code, key) } && code.include?('bc2cpp_slow_mod('))
  end
  Dir.mktmpdir do |dir|
    code, = runtime.generate(FIXTURE_MISC, dir, closed: false, only_owners: MISC_OWNERS)
    check.call('NEG: an open world keeps the by-name helpers', %w[mod neg].none? { |key| helper_pair(code, key) })
  end
  # A build without the gem a String arm links against has no String arm: `-@` keeps the by-name helper when the scanned
  # natives still list string-ext's body (the exported function is not linked), `%` closes without the arm when sprintf's
  # Ruby is absent (there is no String#% to mirror).
  Dir.mktmpdir do |dir|
    code, = runtime.generate(FIXTURE_MISC, dir, closed: true, only_owners: MISC_OWNERS, drop_gems: %w[mruby-string-ext])
    check.call('NEG: a build without mruby-string-ext keeps the by-name `neg` helper', helper_pair(code, 'neg').nil?)
  end
  Dir.mktmpdir do |dir|
    code, = runtime.generate(FIXTURE_MISC, dir, closed: true, only_owners: MISC_OWNERS, drop_gems: %w[mruby-sprintf])
    _, mod = helper_pair(code, 'mod').to_a
    check.call('a build without mruby-sprintf closes `%` for Integer and Float only: no String arm, no formatter',
               mod && mod.include?('mrb_int_mod_impl(') && !mod.include?('mrb_str_format_impl') && !mod.include?('mrb_string_p(a)'))
  end
end

# The Ruby and native definitions the closed `%` and `-@` helpers stand on (CoreMisc), against the real core and against
# trees that stop matching the model (host only).
def core_misc_model_checks(check)
  require 'fileutils'
  require_relative '../../tools/bc2cpp/core_misc'
  puts '-- CoreMisc model (host)'
  root = File.expand_path('../..', __dir__)
  numeric_rb = "class Numeric\n  def -@\n    0 - self\n  end\nend\n"
  string_rb = <<~RUBY
    class String
      def %(args)
        if args.is_a? Array
          sprintf(self, *args)
        else
          sprintf(self, args)
        end
      end
    end
  RUBY
  numeric_c = "static mrb_value\nint_mod(mrb_state *mrb, mrb_value x)\n{\n  return mrb_int_mod_impl(mrb, x, mrb_get_arg1(mrb));\n}\n" \
              "static mrb_value\nflo_mod(mrb_state *mrb, mrb_value x)\n{\n  return mrb_flo_mod_impl(mrb, x, mrb_get_arg1(mrb));\n}\n"
  string_c = "static mrb_value\nstr_uminus(mrb_state *mrb, mrb_value str)\n{\n  return mrb_str_uminus_impl(mrb, str);\n}\n"
  Dir.mktmpdir do |dir|
    write = ->(rel, text) { File.join(dir, rel).tap { |path| FileUtils.mkdir_p(File.dirname(path)) && File.write(path, text) } }
    numeric_path = write.call('3rd/mruby/src/numeric.c', numeric_c)
    string_path = write.call('3rd/mruby/mrbgems/mruby-string-ext/src/string.c', string_c)
    entry = ->(owner, function, path) { { owner: { class_name: owner }, function: function, path: path } }
    regs = lambda do
      { '%' => [entry.call('Integer', 'int_mod', numeric_path), entry.call('Float', 'flo_mod', numeric_path)],
        '-@' => [entry.call('String', 'str_uminus', string_path)] }
    end
    ruby = ->(numeric: numeric_rb, string: string_rb, extra: nil) do
      paths = [write.call('3rd/mruby/mrblib/numeric.rb', numeric), write.call('3rd/mruby/mrbgems/mruby-sprintf/mrblib/string.rb', string)]
      paths << write.call('3rd/mruby/mrbgems/mruby-other/mrblib/other.rb', extra) if extra
      paths
    end
    verified = ->(op, paths = ruby.call, registrations = regs.call, opaque = {}) { CoreMisc.verified(op, paths, registrations, opaque) }
    check.call('a core tree that matches the model verifies both operators',
               verified.call('-@') == Set.new(%w[Numeric String]) && verified.call('%') == Set.new(%w[String Integer Float]))
    check.call('a changed Numeric#-@ body turns `-@` off',
               verified.call('-@', ruby.call(numeric: numeric_rb.sub('0 - self', 'self - 0'))).nil?)
    check.call('a changed String#% body turns `%` off',
               verified.call('%', ruby.call(string: string_rb.sub('args.is_a? Array', 'args.kind_of? Array'))).nil?)
    check.call('a second Ruby definer turns the operator off (Complex#-@ in a build that links it)',
               verified.call('-@', ruby.call(extra: "class Complex\n  def -@ = self\nend\n")).nil?)
    check.call('an alias of the name turns it off', verified.call('-@', ruby.call(extra: "class Array\n  alias -@ first\nend\n")).nil?)
    check.call('a build without sprintf has no String arm of `%` (String#% is absent)',
               verified.call('%', [ruby.call.first]) == Set.new(%w[Integer Float]))
    check.call('an unpatched wrapper (the old body, no exported impl) turns `%` off', begin
      write.call('3rd/mruby/src/numeric.c', numeric_c.sub('return mrb_int_mod_impl(mrb, x, mrb_get_arg1(mrb));',
                                                          "mrb_value y = mrb_get_arg1(mrb);\n  return y;"))
      verified.call('%').nil?
    ensure
      write.call('3rd/mruby/src/numeric.c', numeric_c)
    end)
    check.call('an unexpected native registration turns the operator off',
               verified.call('-@', ruby.call, { '-@' => [entry.call('String', 'str_uminus', string_path), entry.call('Rational', 'rational_minus', numeric_path)] }).nil?)
    check.call('an opaque registration of the name turns the operator off', verified.call('-@', ruby.call, regs.call, { '-@' => ['Foo'] }).nil?)
    check.call('no sources prove nothing', verified.call('-@', nil).nil? && CoreMisc.verified('-@', ruby.call, nil, {}).nil? && CoreMisc.verified('+', ruby.call, regs.call, {}).nil?)
  end
  real = File.join(root, '3rd/mruby/src/numeric.c')
  unless File.exist?(real)
    puts '  SKIP: no 3rd/mruby checkout'
    return
  end
  require_relative '../../tools/bc2cpp/compiled_gems'
  require_relative '../../tools/bc2cpp/bc2cpp'
  native = core_native_srcs("#{root}/3rd/mruby") + Dir["#{root}/mruby-rgss/src/*.cxx"] + external_gem_native_srcs(root)
  registrations, opaque = NativeExpressionDevirt.class_registrations(native)
  # The wio gem set has neither Complex nor Rational; foreign_mrblib_srcs lists every core gem's Ruby.
  core_ruby = foreign_mrblib_srcs(root).reject { |path| path.include?('/mruby-complex/') || path.include?('/mruby-rational/') }
  check.call('the patched 3rd/mruby still matches the model for `-@` (review CoreMisc when this fails; the patch must be applied)',
             CoreMisc.verified('-@', core_ruby, registrations.to_h, opaque.to_h) == Set.new(%w[Numeric String]))
  check.call('...for `%`', CoreMisc.verified('%', core_ruby, registrations.to_h, opaque.to_h) == Set.new(%w[String Integer Float]))
  check.call('...and for the calls String#% makes (Kernel#is_a?, Kernel#sprintf, the exported formatter)',
             CoreMisc.format_pins?(registrations.to_h, opaque.to_h, native))
  check.call('a build that links Complex keeps `-@` by name (Complex#-@ is a second definer)',
             CoreMisc.verified('-@', foreign_mrblib_srcs(root), registrations.to_h, opaque.to_h).nil?)
end

# CoreCompare against the real core and against trees that stop matching its model (host only).
def core_compare_model_checks(check)
  require 'fileutils'
  require_relative '../../tools/bc2cpp/core_compare'
  puts '-- Comparable model (host)'
  root = File.expand_path('../..', __dir__)
  compar_body = lambda do |op|
    <<~RUBY.gsub(/^/, '  ')
      def #{op} other
        cmp = self <=> other
        if cmp.nil?
          raise ArgumentError, "comparison of \#{self.class} with \#{other.class} failed"
        end
        cmp #{op} 0
      end
    RUBY
  end
  compar = lambda do |ops = CoreCompare::OPS, mutate: nil|
    text = "module Comparable\n#{ops.map { |op| compar_body.call(op) }.join("\n")}end\n"
    mutate ? text.sub(*mutate) : text
  end
  hash = "class Hash\n#{CoreCompare::OPS.map { |op| "  def #{op}(hash)\n    size #{op} hash.size\n  end\n" }.join}end\n"
  natives = CoreCompare::OPS.to_h { |op| [op, ['/x/3rd/mruby/src/numeric.c']] }
  Dir.mktmpdir do |dir|
    write = lambda do |rel, text|
      File.join(dir, rel).tap { |path| FileUtils.mkdir_p(File.dirname(path)) && File.write(path, text) }
    end
    tree = lambda do |compar_text: compar.call, hash_text: hash, extra: nil|
      paths = [write.call('3rd/mruby/mrblib/compar.rb', compar_text),
               write.call('3rd/mruby/mrbgems/mruby-hash-ext/mrblib/hash.rb', hash_text)]
      paths << write.call('3rd/mruby/mrbgems/mruby-other/mrblib/other.rb', extra) if extra
      paths
    end
    all = CoreCompare::OPS.to_set
    check.call('a core tree that matches the model verifies every operator', CoreCompare.verified(tree.call, natives) == all)
    # `String#sub` changes the first occurrence, which is the `<` body.
    check.call('a changed message turns the operator off (the interpolation is part of the body)',
               CoreCompare.verified(tree.call(compar_text: compar.call(mutate: ['failed', 'failed.'])), natives) == Set.new(%w[<= > >=]))
    check.call('a changed class in the message turns the operator off',
               CoreCompare.verified(tree.call(compar_text: compar.call(mutate: ['#{self.class}', '#{self}'])), natives) == Set.new(%w[<= > >=]))
    check.call('a changed test turns the operator off',
               CoreCompare.verified(tree.call(compar_text: compar.call(mutate: ['cmp < 0', 'cmp <= 0'])), natives) == Set.new(%w[<= > >=]))
    check.call('a second Ruby definer turns the operator off',
               !CoreCompare.verified(tree.call(extra: "class Time\n  def <(o) = true\nend\n"), natives).include?('<') &&
                 CoreCompare.verified(tree.call(extra: "class Time\n  def <(o) = true\nend\n"), natives).include?('<='))
    check.call('`<<` and `<=>` are not definers of `<` or `<=`',
               CoreCompare.verified(tree.call(extra: "class Proc\n  def <<(o) = o\nend\nclass Rational\n  def <=>(o) = 0\nend\n"), natives) == all)
    check.call('an alias of the name turns it off',
               !CoreCompare.verified(tree.call(extra: "class Array\n  alias < first\nend\n"), natives).include?('<'))
    check.call('the Hash definer is part of the model (a missing one turns the operator off)',
               CoreCompare.verified(tree.call(hash_text: "class Hash\nend\n"), natives).empty?)
    check.call('an unexpected native registration turns it off',
               !CoreCompare.verified(tree.call, natives.merge('<' => ['/x/mruby-rgss/src/lib.cxx'])).include?('<') &&
                 CoreCompare.verified(tree.call, natives.merge('<' => ['/x/mruby-rgss/src/lib.cxx'])).include?('>'))
    check.call('no sources prove nothing', CoreCompare.verified(nil, natives).empty? && CoreCompare.verified(tree.call, nil).empty?)
  end
  real = File.join(root, '3rd/mruby/mrblib/compar.rb')
  if File.exist?(real)
    require_relative '../../tools/bc2cpp/compiled_gems'
    require_relative '../../tools/bc2cpp/bc2cpp'
    native = core_native_srcs("#{root}/3rd/mruby") + Dir["#{root}/mruby-rgss/src/*.cxx"] + external_gem_native_srcs(root)
    check.call('the real 3rd/mruby still matches the model (review CoreCompare when this fails)',
               CoreCompare.verified(foreign_mrblib_srcs(root), extract_native_method_sources(native)) == CoreCompare::OPS.to_set)
  else
    puts '  SKIP: no 3rd/mruby checkout'
  end
end

# ADR 0364: the `^`, `>>` and `round` helpers of a world where no other class answers them.
def closed_bits_generated_checks(check, runtime)
  puts '-- generated code (closed world, `^` `>>` `round` answered by core classes only)'
  Dir.mktmpdir do |dir|
    code, = runtime.generate(FIXTURE_BITS, dir, closed: true, only_owners: BITS_OWNERS)
    blocks = code.scan(/^#if defined\(MRB_USE_COMPLEX\) \|\| defined\(MRB_USE_RATIONAL\)\n(?:.*?^\}\n){2}\n*#endif\n/m)
    { 'xor' => ['NsBits#xor', '^'], 'rshift' => ['NsBits#rsh', '>>'], 'round' => ['NsBits#rnd', 'round'] }.each do |key, (method, op)|
      call = code[/^\/\/ #{Regexp.escape(method)} \(compiled from.*?(?=^\/\/ \S+#\S+ \(compiled from|\z)/m].to_s
      check.call("#{method} calls bc2cpp_slow_#{key} and has no by-name call of its own",
                 call.include?("bc2cpp_slow_#{key}(M, ") && !call.include?('bc2cpp_send(') && !call.include?('mrb_funcall('))
      helper = blocks.find { |b| b.include?("bc2cpp_slow_#{key}(mrb_state* M") }.to_s
      open, closed = helper.split("}\n\n#else\n", 2).map(&:to_s)
      check.call("bc2cpp_slow_#{key} (`#{op}`) holds no by-name call: any other receiver is a proven NoMethodError",
                 !closed.empty? && !closed.include?('bc2cpp_send(') && !closed.include?('mrb_funcall(') &&
                 closed.include?('bc2cpp_nomethod'))
      check.call("bc2cpp_slow_#{key} keeps the by-name body for a build with Complex or Rational",
                 open.start_with?('#if defined(MRB_USE_COMPLEX) || defined(MRB_USE_RATIONAL)') && open.include?('bc2cpp_send('))
    end
  end
  Dir.mktmpdir do |dir|
    source = "#{FIXTURE_BITS}class NsBitsBox\n  def ^(o) = :x\n  def >>(o) = :y\n  def round = :z\nend\n"
    code, = runtime.generate(source, dir, closed: true, only_owners: BITS_OWNERS)
    { 'xor' => '^', 'rshift' => '>>', 'round' => 'round' }.each do |key, op|
      helper = code[/^static mrb_value bc2cpp_slow_#{key}\(mrb_state\* M.*?^\}\n/m].to_s
      # A user definition of the name also takes the site off the helper, so for `^` and `round` there may be none.
      check.call("NEG: a user class answering `#{op}` leaves no closed helper (by-name call kept)",
                 !code.include?("#else\n" \
 "static mrb_value bc2cpp_slow_#{key}(") && (helper.empty? || helper.include?('bc2cpp_send(')))
    end
  end
  Dir.mktmpdir do |dir|
    # The main fixture's NsBox defines `>>`: that helper stays open while `^` and `round` close.
    code, = runtime.generate(FIXTURE, dir, closed: true, only_owners: %w[NsOpen NsProven NsBox NsCmp])
    shift = code[/^static mrb_value bc2cpp_slow_rshift\(mrb_state\* M.*?^\}\n/m].to_s
    check.call('NEG: NsBox#>> keeps the `>>` helper open', !shift.empty? && shift.include?('bc2cpp_send('))
  end
end

# ADR 0366: the `- & | <<` helpers of a world whose only definers are the core natives and the three exported gem bodies.
# `<<` also needs the world to have no Ruby definer: the wio gem list less mruby-enumerator (Enumerator::Yielder#<< is
# interpreted Ruby of another gem), which is how the shipped wio world keeps `<<` open.
def closed_collection_generated_checks(check, runtime)
  puts '-- generated code (closed world, `- & | <<` answered by core classes and the exported gem bodies)'
  owners = Bc2cppCollectionOpsMatrix::OWNERS
  fixture = Bc2cppCollectionOpsMatrix::FIXTURE.gsub('\\#', '#')
  gen = lambda do |source = fixture, **options|
    Dir.mktmpdir do |dir|
      code, = runtime.generate(source, dir, closed: true, only_owners: owners, **options)
      code
    end
  end
  forms = ->(code) { %w[sub_f and or lshift].select { |key| helper_pair(code, key) } }

  code = gen.call(drop_gems: %w[mruby-enumerator])
  { 'sub_f' => ['NsColl#sub', '-', 'mrb_ary_ext_sub_impl'], 'and' => ['NsColl#band', '&', 'mrb_ary_ext_and_impl'],
    'or' => ['NsColl#bor', '|', 'mrb_ary_ext_or_impl'],
    'lshift' => ['NsColl#lsh', '<<', 'mrb_str_ext_concat_impl'] }.each do |key, (method, op, impl)|
    call = code[/^\/\/ #{Regexp.escape(method)} \(compiled from.*?(?=^\/\/ \S+#\S+ \(compiled from|\z)/m].to_s
    check.call("#{method} calls bc2cpp_slow_#{key} and has no by-name call of its own",
               call.match?(/bc2cpp_slow_#{key}\(M, /) && !call.include?('bc2cpp_send(') && !call.include?('mrb_funcall('))
    pair = helper_pair(code, key)
    check.call("bc2cpp_slow_#{key} (`#{op}`) is written twice: by name for Complex/Rational builds, closed otherwise", !pair.nil?)
    next unless pair

    open_form, closed = pair
    check.call("bc2cpp_slow_#{key} keeps its by-name copy for a build with Complex or Rational", open_form.include?('bc2cpp_send('))
    check.call("bc2cpp_slow_#{key} holds no by-name call: any other receiver is a proven NoMethodError, the bodies are the exported ones",
               !closed.include?('bc2cpp_send(') && !closed.include?('mrb_funcall(') && closed.include?('bc2cpp_nomethod') &&
               closed.include?("#{impl}(M, a, b)") && closed.include?("extern \"C\" mrb_value #{impl}(mrb_state*, mrb_value, mrb_value);"))
  end
  lshift = helper_pair(code, 'lshift')&.last.to_s
  check.call('`<<` has an arm for each of Integer, Array, String and IO (the class and its subclasses, not an exact class)',
             lshift.include?('mrb_ary_push(M, a, b)') && lshift.include?('mrb_io_lshift_impl(M, a, b)') &&
             lshift.include?('mrb_obj_is_kind_of(M, a, mrb_class_get(M, "IO"))'))
  check.call('the other helpers have no extern declaration of an export they do not call',
             helper_pair(code, 'and').last.scan('extern "C"').size == 1 && helper_pair(code, 'sub_f').last.scan('extern "C"').size == 1)
  check.call('every generated declaration is one the patch defines (no other mrb_*_impl is declared)',
             code.scan(/^extern "C" mrb_value (mrb_(?:ary_ext|str_ext|io_lshift)\w*_impl)\(/).flatten.uniq.sort ==
             %w[mrb_ary_ext_and_impl mrb_ary_ext_or_impl mrb_ary_ext_sub_impl mrb_io_lshift_impl mrb_str_ext_concat_impl])

  check.call('POS: the default wio world keeps `<<` open (Enumerator::Yielder#<< is interpreted Ruby) and closes `- & |`',
             forms.call(gen.call) == %w[sub_f and or])
  check.call('NEG: a user class answering `<<` keeps `<<` open', forms.call(gen.call("#{fixture}class NsCollBox\n  def <<(o) = :x\nend\n", drop_gems: %w[mruby-enumerator])) == %w[sub_f and or])
  check.call('NEG: a user class answering `-` keeps `-` open', forms.call(gen.call("#{fixture}class NsCollBox\n  def -(o) = :x\nend\n", drop_gems: %w[mruby-enumerator])) == %w[and or lshift])
  check.call('NEG: a user class answering `&` keeps `&` open', forms.call(gen.call("#{fixture}class NsCollBox\n  def &(o) = :x\nend\n", drop_gems: %w[mruby-enumerator])) == %w[sub_f or lshift])
  check.call('NEG: a user class answering `|` keeps `|` open', forms.call(gen.call("#{fixture}class NsCollBox\n  def |(o) = :x\nend\n", drop_gems: %w[mruby-enumerator])) == %w[sub_f and lshift])
  check.call('NEG: Array#- reopened in Ruby keeps `-` open', forms.call(gen.call("#{fixture}class Array\n  def -(o) = []\nend\n", drop_gems: %w[mruby-enumerator])) == %w[and or lshift])
  check.call('NEG: Integer#<< reopened in Ruby keeps `<<` open', forms.call(gen.call("#{fixture}class Integer\n  def <<(o) = 0\nend\n", drop_gems: %w[mruby-enumerator])) == %w[sub_f and or])
  check.call('NEG: a build without mruby-array-ext keeps `- & |` open (no exported body to link)',
             forms.call(gen.call(drop_gems: %w[mruby-enumerator mruby-array-ext])) == %w[lshift])
  check.call('NEG: a build without mruby-string-ext keeps `<<` open', forms.call(gen.call(drop_gems: %w[mruby-enumerator mruby-string-ext])) == %w[sub_f and or])
  check.call('NEG: a build without mruby-io keeps `<<` open', forms.call(gen.call(drop_gems: %w[mruby-enumerator mruby-io])) == %w[sub_f and or])
  time = File.join(Bc2cppFixtureRuntime::ROOT, '3rd/mruby/mrbgems/mruby-time')
  check.call('NEG: a build that links mruby-time keeps `-` open (Time#-)',
             forms.call(gen.call(drop_gems: %w[mruby-enumerator], build_gems: { 'mruby-time' => time })) == %w[and or lshift])
  extra_native = [['other_ext.c', "static void other_ext(mrb_state *mrb, struct RClass *klass) {\n" \
                                  "  mrb_define_method(mrb, klass, \"-\", other_minus, MRB_ARGS_REQ(1));\n" \
                                  "  mrb_define_method(mrb, klass, \"<<\", other_lshift, MRB_ARGS_REQ(1));\n}\n"]]
  check.call('NEG: a native `-` and `<<` another gem registers on a class the scan cannot name keep those helpers open',
             forms.call(gen.call(drop_gems: %w[mruby-enumerator], native: extra_native)) == %w[and or])
  saved = ENV['BC2CPP_NUMERIC_SLOW_CLOSED']
  ENV['BC2CPP_NUMERIC_SLOW_CLOSED'] = '0'
  begin
    off = gen.call(drop_gems: %w[mruby-enumerator])
  ensure
    ENV['BC2CPP_NUMERIC_SLOW_CLOSED'] = saved
  end
  check.call('BC2CPP_NUMERIC_SLOW_CLOSED=0 restores the old helpers', forms.call(off).empty? && !off.include?('mrb_ary_ext_sub_impl'))
  Bc2cppFixtureRuntime.collection_exports_linked = false
  begin
    unlinked = gen.call(drop_gems: %w[mruby-enumerator])
  ensure
    Bc2cppFixtureRuntime.collection_exports_linked = true
  end
  check.call('without BC2CPP_COLLECTION_EXPORTS=1 (a harness over a libmruby that lacks the exported bodies) `- & | <<` stay by name',
             forms.call(unlinked).empty? && !unlinked.include?('mrb_ary_ext_sub_impl'))
  Dir.mktmpdir do |dir|
    check.call('NEG: an open world keeps the by-name helpers',
               forms.call(runtime.generate(fixture, dir, closed: false, only_owners: owners).first).empty?)
  end

  # The proof reads the scanned sources: a wrapper that no longer calls the export, or an export that went static.
  real = File.join(Bc2cppFixtureRuntime::ROOT, '3rd/mruby/mrbgems/mruby-array-ext/src/array.c')
  if File.exist?(real)
    gen_probe = CodeGen.allocate
    text = File.read(real)
    Dir.mktmpdir do |dir|
      file = lambda do |name, body|
        File.join(dir, name).tap { |path| File.write(path, body) }
      end
      sub = ['ary_sub', 'mrb_ary_ext_sub_impl', 'mrb_ary_ext_sub_impl(mrb, self, other)']
      check.call('the patched array.c has the export and a wrapper that calls it', gen_probe.numeric_slow_export?(file.call('real.c', text), *sub))
      check.call('NEG: a wrapper that does not call the export (an unpatched tree)',
                 !gen_probe.numeric_slow_export?(file.call('unwrapped.c', text.sub('return mrb_ary_ext_sub_impl(mrb, self, other);', 'return mrb_nil_value();')), *sub))
      check.call('NEG: an export made static',
                 !gen_probe.numeric_slow_export?(file.call('static.c', text.sub("mrb_value\nmrb_ary_ext_sub_impl(", "static mrb_value\nmrb_ary_ext_sub_impl(")), *sub))
      check.call('NEG: a tree without the export at all',
                 !gen_probe.numeric_slow_export?(file.call('absent.c', text.gsub('mrb_ary_ext_sub_impl', 'other_name')), *sub))
    end
  else
    puts '  SKIP: no 3rd/mruby checkout'
  end
end

def div_driver(width)
  <<~RUBY
  FM = #{WIDTHS.fetch(width)[:fmax]}
  $vals = [0, 1, -1, 2, -2, 7, -7, FM, -FM, FM - 1, 0.0, -0.0, 0.5, -1.5, 3.0, 1.0e19, Float::NAN, Float::INFINITY,
           -Float::INFINITY, nil, true, false, "s", :sym, [1], {a: 1}, 1..2, NsDivBox.new, NsDivBox, Object.new]
  $vals += [FM + 1, -FM - 2, 2 ** 100, -(2 ** 100), 2.0 ** 70] if $bigint
  def try
    v = yield
    s = v.inspect
    s += " h=\#{v.hash}" if v.is_a?(Integer)
    s
  rescue => e
    "\#{e.class}: \#{e.message}"
  end
  o = NsDiv.new
  $vals.each { |a| $vals.each { |b| puts "div \#{a.inspect} \#{b.inspect} => \#{try { o.div(a, b) }}" } }
  puts 'end'
  RUBY
end

def bits_driver(width)
  <<~RUBY
  FM = #{WIDTHS.fetch(width)[:fmax]}
  IM = $bigint ? FM * 2 + 1 : FM # mrb_int max, computed: a parser without mruby-bigint rejects the 64-bit literal
  $vals = [0, 1, -1, 2, -2, 3, 7, -7, 255, FM, -FM, FM - 1, -FM - 1, IM, -IM, -IM - 1, 0.0, -0.0, 0.5, -0.5, 1.5, -1.5,
           2.5, -2.5, 3.0, 1.0e19, -1.0e19, Float::NAN, Float::INFINITY, -Float::INFINITY, nil, true, false, "s",
           "s".freeze, :sym, [1], {a: 1}, 1..2, NsBitsBox.new, NsBitsBox, Numeric.new, Object.new]
  $vals += [FM + 1, -FM - 2, IM + 1, -IM - 2, IM * IM, -(IM * IM), 2 ** 100, -(2 ** 100), 2.0 ** 70] if $bigint
  $counts = [0, 1, -1, 2, 5, 30, 31, 32, 33, 62, 63, 64, 65, 100, -2, -30, -31, -32, -62, -63, -64, -65, -100, -IM,
             -IM - 1, 2.5, -2.5, 0.0, 1.0e19, Float::NAN, nil, true, "s", :sym, [1], NsBitsBox.new]
  $counts += [2 ** 100, -(2 ** 100), IM + 1, -IM - 2] if $bigint
  def try
    v = yield
    s = v.inspect
    s += " h=\#{v.hash}" if v.is_a?(Integer)
    s
  rescue => e
    "\#{e.class}: \#{e.message}"
  end
  o = NsBits.new
  # An Integer receiver reads a non-Integer operand as its raw word (the method does too), which for a heap
  # object is its address and differs between the two runs; the direct matrix (same objects) covers those pairs.
  heap = ->(x) { !(x.is_a?(Numeric) || x.nil? || x == true || x == false || x.is_a?(Symbol)) || x.instance_of?(Numeric) }
  $vals.each { |a| $vals.each { |b| next if a.is_a?(Integer) && heap.(b); puts "xor \#{a.inspect} \#{b.inspect} => \#{try { o.xor(a, b) }}" } }
  $vals.each { |a| $counts.each { |b| puts "rsh \#{a.inspect} \#{b.inspect} => \#{try { o.rsh(a, b) }}" } }
  $vals.each { |a| puts "rnd \#{a.inspect} => \#{try { o.rnd(a) }}" }
  puts 'end'
  RUBY
end

# Each helper in `specs` ([helper, op, arity, rights]) called directly against the method it stands for, over every
# receiver in $vals and every operand in $vals (or $counts for a shift), compiled TU and interpreter in one process:
# value, Float bits, Integer#hash, exception class and message must agree.
def closed_scenario(specs, source)
  table = specs.map do |helper, op, arity, rights|
    "{ \"#{op}\", #{arity == 1 ? 'nullptr' : helper}, #{arity == 1 ? helper : 'nullptr'}, #{rights == :counts} }"
  end.join(",\n    ")
  <<~CPP
    #include <string>
    struct ClosedSpec {
      const char* op;
      mrb_value (*bin)(mrb_state*, mrb_value, mrb_value);
      mrb_value (*un)(mrb_state*, mrb_value);
      bool counts;
    };
    static const ClosedSpec closed_specs[] = {
        #{table}
    };
    struct ClosedCall { const ClosedSpec* s; mrb_value a, b; bool method; };
    static mrb_value closed_body(mrb_state* M, void* ud) {
      ClosedCall* k = (ClosedCall*)ud;
      if (k->method) return k->s->un ? (mrb_funcall)(M, k->a, k->s->op, 0) : (mrb_funcall)(M, k->a, k->s->op, 1, k->b);
      return k->s->un ? k->s->un(M, k->a) : k->s->bin(M, k->a, k->b);
    }
    static std::string closed_describe(mrb_state* M, mrb_value v, bool raised) {
      if (raised) {
        mrb_value msg = (mrb_funcall)(M, v, "message", 0);
        return std::string("raised ") + mrb_obj_classname(M, v) + ": " + std::string(RSTRING_PTR(msg), RSTRING_LEN(msg));
      }
      mrb_value s = mrb_inspect(M, v);
      std::string out(RSTRING_PTR(s), RSTRING_LEN(s));
      if (mrb_integer_p(v) || mrb_bigint_p(v)) {
        mrb_value h = mrb_inspect(M, (mrb_funcall)(M, v, "hash", 0));
        out += " h=" + std::string(RSTRING_PTR(h), RSTRING_LEN(h));
      }
      return out;
    }
    static int scenario(mrb_state* M) {
      std::fflush(stdout);
      const char* src = R"BCD(#{source})BCD";
      mrb_load_string(M, src);
      if (M->exc) { mrb_print_error(M); M->exc = nullptr; return 1; }
      mrb_value vals = mrb_gv_get(M, mrb_intern_lit(M, "$vals"));
      mrb_value counts = mrb_gv_get(M, mrb_intern_lit(M, "$counts"));
      int total = 0, bad = 0;
      for (const ClosedSpec& s : closed_specs) {
        mrb_value rights = s.counts ? counts : vals;
        mrb_int nb = s.un ? 1 : RARRAY_LEN(rights);
        int cases = 0, wrong = 0;
        for (mrb_int i = 0; i < RARRAY_LEN(vals); ++i) for (mrb_int j = 0; j < nb; ++j) {
          mrb_value a = RARRAY_PTR(vals)[i];
          mrb_value b = s.un ? mrb_nil_value() : RARRAY_PTR(rights)[j];
          int ai = mrb_gc_arena_save(M);
          ClosedCall got_call = { &s, a, b, false }, want_call = { &s, a, b, true };
          mrb_bool e1 = FALSE, e2 = FALSE;
          std::string g = closed_describe(M, mrb_protect_error(M, closed_body, &got_call, &e1), e1);
          std::string w = closed_describe(M, mrb_protect_error(M, closed_body, &want_call, &e2), e2);
          mrb_gc_arena_restore(M, ai);
          ++cases;
          if (g != w) {
            ++wrong;
            if (wrong <= 4) {
              mrb_value as = mrb_inspect(M, a), bs = mrb_inspect(M, b);
              std::printf("  H MISMATCH %s %.*s %.*s helper=%s method=%s\\n", s.op, (int)RSTRING_LEN(as), RSTRING_PTR(as),
                          (int)RSTRING_LEN(bs), RSTRING_PTR(bs), g.c_str(), w.c_str());
            }
          }
        }
        std::printf("  H op %s %d cases, %d mismatches\\n", s.op, cases, wrong);
        total += cases;
        bad += wrong;
      }
      std::printf("  H summary %d cases, %d mismatches\\n", total, bad);
      return 0;
    }
  CPP
end

# Receivers and operands of the comparison matrix. A class or module is an operand only: the full-core libmruby
# links mruby-class-ext (Module#<), which the wio gem set the proof is made for does not. Time, Set and Rational
# are left out for the same reason. Messages carry no address (`%p` of a plain object would).
def cmp_driver(width)
  <<~RUBY
    FM = #{WIDTHS.fetch(width)[:fmax]}
    IM = $bigint ? FM * 2 + 1 : FM
    NsPair = Struct.new(:a)
    $recvs = [0, 1, -1, 2, -2, 7, FM, FM - 1, -FM, -FM - 1, IM, -IM, -IM - 1, 0.0, -0.0, 0.5, -1.5, 3.0, 1.0e19, -1.0e19,
              Float::NAN, Float::INFINITY, -Float::INFINITY, nil, true, false,
              "", "a", "b", "ab", "abc", "B", "a\\0b", "\\u00e9", "\\u3042", "a" * 40, :a, :b, :ab, :"", :"a b", :abcdefghijkl, :"\\u00e9",
              [1], [], {}, {a: 1}, {a: 1, b: 2}, {b: 1}, {a: Float::NAN}, Hash.new(0), 1..2, Object.new, NsCmpBox.new,
              NsSortKey.new, Numeric.new, NsPair.new(1)]
    $recvs += [FM + 1, -FM - 2, IM + 1, -IM - 2, IM * 2, IM * IM, -(IM * IM), 2 ** 100, -(2 ** 100), 2.0 ** 70] if $bigint
    $vals = $recvs + [NsCmpBox, String, Symbol, Hash, Integer, Comparable]
    # ASCII only, so the run does not depend on the locale of the process reading its output.
    def lbl(v)
      s = v.inspect
      return "\#<\#{v.class}>" if s.include?(':0x')
      s.each_byte.map { |b| b < 128 ? b.chr : '\\\\x' + b.to_s(16) }.join
    end
    def try
      v = yield
      s = v.inspect
      s += " h=\#{v.hash}" if v.is_a?(Integer)
      s
    rescue => e
      "\#{e.class}: \#{e.message}"
    end
    o = NsCmpOpen.new
    %w[lt le gt ge].each do |op|
      $recvs.each { |a| $vals.each { |b| puts "\#{op} \#{lbl(a)} \#{lbl(b)} => \#{try { o.send(op, a, b) }}" } }
    end
    puts 'end'
  RUBY
end

# The four helpers called directly (the generated TU is part of main.cpp) against the operator they stand for.
# A receiver a helper owns (a number, a String, a Symbol, a Numeric) makes no by-name call; a Hash makes one (the
# method); every other receiver one, the proof's dispatch that raises the NoMethodError.
CMP_SCENARIO = <<~CPP
  #include <string>
  typedef mrb_value (*CmpFn)(mrb_state*, mrb_value, mrb_value);
  struct CmpCase { const char* name; const char* op; CmpFn fn; };
  static const CmpCase cmp_cases[] = {
    { "lt", "<", bc2cpp_slow_lt }, { "le", "<=", bc2cpp_slow_le }, { "gt", ">", bc2cpp_slow_gt }, { "ge", ">=", bc2cpp_slow_ge },
  };
  struct CmpCall { const CmpCase* c; mrb_value a, b; bool method; };
  static mrb_value cmp_body(mrb_state* M, void* ud) {
    CmpCall* k = (CmpCall*)ud;
    if (k->method) return (mrb_funcall)(M, k->a, k->c->op, 1, k->b);
    return k->c->fn(M, k->a, k->b);
  }
  static std::string cmp_describe(mrb_state* M, mrb_value v, bool raised) {
    if (raised) {
      mrb_value msg = (mrb_funcall)(M, v, "message", 0);
      return std::string("raised ") + mrb_obj_classname(M, v) + ": " + std::string(RSTRING_PTR(msg), RSTRING_LEN(msg));
    }
    mrb_value s = mrb_inspect(M, v);
    return std::string(RSTRING_PTR(s), RSTRING_LEN(s));
  }
  static bool cmp_owned(mrb_state* M, mrb_value a) {
    return mrb_integer_p(a) || mrb_bigint_p(a) || mrb_float_p(a) || mrb_string_p(a) || mrb_symbol_p(a) ||
           mrb_obj_is_kind_of(M, a, mrb_class_get(M, "Numeric"));
  }
  static int scenario(mrb_state* M) {
    std::fflush(stdout);
    const char* src = R"BCD(__SOURCE__)BCD";
    mrb_load_string(M, src);
    if (M->exc) { mrb_print_error(M); M->exc = nullptr; return 1; }
    // Class instances only the matrix has: an anonymous class prints an address, which both sides share here.
    mrb_load_string(M, "$anon = Class.new; $recvs += [$anon.new, Class.new(String).new]; $vals += [$anon, Class.new(Hash)]");
    if (M->exc) { mrb_print_error(M); M->exc = nullptr; return 1; }
    mrb_value recvs = mrb_gv_get(M, mrb_intern_lit(M, "$recvs"));
    mrb_value vals = mrb_gv_get(M, mrb_intern_lit(M, "$vals"));
    int total = 0, bad = 0, wrong_calls = 0, hashes = 0, strings = 0, symbols = 0, errors = 0;
    for (const CmpCase& c : cmp_cases) for (mrb_int i = 0; i < RARRAY_LEN(recvs); ++i) for (mrb_int j = 0; j < RARRAY_LEN(vals); ++j) {
      mrb_value a = RARRAY_PTR(recvs)[i], b = RARRAY_PTR(vals)[j];
      int ai = mrb_gc_arena_save(M);
      CmpCall got_call = { &c, a, b, false }, want_call = { &c, a, b, true };
      mrb_bool e1 = FALSE, e2 = FALSE;
      dispatches = 0;
      mrb_value got = mrb_protect_error(M, cmp_body, &got_call, &e1);
      int made = dispatches;
      std::string g = cmp_describe(M, got, e1);
      mrb_value want = mrb_protect_error(M, cmp_body, &want_call, &e2);
      std::string w = cmp_describe(M, want, e2);
      mrb_gc_arena_restore(M, ai);
      ++total;
      if (e1) ++errors;
      if (mrb_string_p(a)) ++strings;
      if (mrb_symbol_p(a)) ++symbols;
      if (mrb_type(a) == MRB_TT_HASH) ++hashes;
      int expect = cmp_owned(M, a) ? 0 : 1;
      if (made != expect) {
        ++wrong_calls;
        if (wrong_calls <= 8) std::printf("  H DISPATCH %s %d by-name calls, expected %d: %s\\n", c.name, made, expect, g.c_str());
      }
      if (g != w) {
        ++bad;
        if (bad <= 8) {
          mrb_value as = mrb_inspect(M, a), bs = mrb_inspect(M, b);
          std::printf("  H MISMATCH %s %.*s %.*s helper=%s method=%s\\n", c.name, (int)RSTRING_LEN(as), RSTRING_PTR(as),
                      (int)RSTRING_LEN(bs), RSTRING_PTR(bs), g.c_str(), w.c_str());
        }
      }
    }
    std::printf("  H summary %d cases, %d mismatches, %d wrong dispatch counts (%d errors, %d String, %d Symbol, %d Hash receivers)\\n",
                total, bad, wrong_calls, errors, strings, symbols, hashes);
    return 0;
  }
CPP

core_compare_model_checks(check)
core_misc_model_checks(check)

unless runtime.mrbc && system(runtime.mrbc, '--version', out: File::NULL, err: File::NULL)
  puts '  SKIP: no host mrbc (set MRBC); the generated-code and behavioural checks need it'
  exit 0
end

generated_checks(check, runtime) unless ONLY_CMP || ONLY_MISC
closed_div_generated_checks(check, runtime) unless ONLY_CMP || ONLY_MISC
closed_arith_generated_checks(check, runtime) unless ONLY_CMP || ONLY_MISC
closed_bits_generated_checks(check, runtime) unless ONLY_CMP || ONLY_MISC
closed_collection_generated_checks(check, runtime) unless ONLY_CMP || ONLY_MISC
closed_misc_generated_checks(check, runtime) unless ONLY_CMP
closed_cmp_generated_checks(check, runtime) unless ONLY_CMP_RUN || ONLY_MISC
mirrored_body_checks(check, Bc2cppFixtureRuntime::ROOT)

# [label, build dir, mrbc, extra flags, width, bigint?]
builds = []
# BC2CPP_MRUBY_FULL, or a full-core mruby built into BC2CPP_FULL_BUILD_DIR (the core-mrbtest shard shares it).
full = runtime.full || (ENV['BC2CPP_FULL_BUILD_DIR'] ? runtime.full_or_build : nil)
builds <<['mrb_int 64', full, ENV['MRBC'], '-DMRB_USE_BIGINT', 64, true] if full && runtime.compiler?
if ENV['BC2CPP_MRUBY_FULL32'] && ENV['BC2CPP_MRBC32'] && runtime.compiler?
  builds << ['mrb_int 32 (MRB_INT32, 31-bit Fixnums)', ENV['BC2CPP_MRUBY_FULL32'], ENV['BC2CPP_MRBC32'],
             '-DMRB_32BIT -DMRB_INT32 -no-pie -DMRB_USE_BIGINT', 32, true]
end
if ENV['BC2CPP_MRUBY_NOBIGINT'] && runtime.compiler?
  builds << ['no mruby-bigint (32-bit mrb_int, no heap Integers)', ENV['BC2CPP_MRUBY_NOBIGINT'], ENV['MRBC'], '', :nobig, false]
end
puts '-- SKIP run: set BC2CPP_MRUBY_FULL (full-core libmruby.a) and have g++' if builds.empty?

PROBE = <<~CPP
  static mrb_value probe_arena(mrb_state* M, mrb_value) { return mrb_fixnum_value(mrb_gc_arena_save(M)); }
  static mrb_value probe_dispatches(mrb_state* M, mrb_value) { return mrb_fixnum_value(dispatches); }
CPP

# Each helper called directly (the generated TU is part of main.cpp) against the method it stands for, over the
# driver's operands: the pairs an operator opcode never hands to a helper (two Integers for `/`, heap Integers
# for `+`) get the same scrutiny. Differences by design: two Integers add/sub/mul as vm.c OP_MATH, so an
# MRB_INT_MIN operand (wrong in the 32-bit bigint core's Integer#+) is skipped there, and without bigint
# only the class of the overflow RangeError is compared (the VM and the method word it differently).
HELPER_MATRIX = <<~CPP
  #include <string>
  struct HelperCase {
    const char* name;
    const char* op;
    mrb_value (*bin)(mrb_state*, mrb_value, mrb_value);
    mrb_value (*un)(mrb_state*, mrb_value);
    int kind;  // 0 arithmetic, 1 compare, 2 shift, 3 other binary, 4 unary
  };
  static const HelperCase helper_cases[] = {
    { "add", "+", bc2cpp_slow_add_f, nullptr, 0 }, { "sub", "-", bc2cpp_slow_sub_f, nullptr, 0 },
    { "mul", "*", bc2cpp_slow_mul_f, nullptr, 0 }, { "div", "/", bc2cpp_slow_div, nullptr, 3 },
    { "mod", "%", bc2cpp_slow_mod, nullptr, 3 }, { "and", "&", bc2cpp_slow_and, nullptr, 3 },
    { "or", "|", bc2cpp_slow_or, nullptr, 3 }, { "xor", "^", bc2cpp_slow_xor, nullptr, 3 },
    { "lshift", "<<", bc2cpp_slow_lshift, nullptr, 2 }, { "rshift", ">>", bc2cpp_slow_rshift, nullptr, 2 },
    { "lt", "<", bc2cpp_slow_lt, nullptr, 1 }, { "le", "<=", bc2cpp_slow_le, nullptr, 1 },
    { "gt", ">", bc2cpp_slow_gt, nullptr, 1 }, { "ge", ">=", bc2cpp_slow_ge, nullptr, 1 },
    { "neg", "-@", nullptr, bc2cpp_slow_neg_f, 4 }, { "zero", "zero?", nullptr, bc2cpp_slow_zero, 4 },
    { "round", "round", nullptr, bc2cpp_slow_round, 4 },
  };
  struct HelperCall { const HelperCase* c; mrb_value a, b; bool method; };
  static mrb_value helper_body(mrb_state* M, void* ud) {
    HelperCall* k = (HelperCall*)ud;
    if (k->method) {
      if (k->c->kind == 4) return (mrb_funcall)(M, k->a, k->c->op, 0);
      return (mrb_funcall)(M, k->a, k->c->op, 1, k->b);
    }
    return k->c->kind == 4 ? k->c->un(M, k->a) : k->c->bin(M, k->a, k->b);
  }
  static std::string helper_describe(mrb_state* M, mrb_value v, bool raised) {
    if (raised) {
      std::string out = std::string("raised ") + mrb_obj_classname(M, v);
  #ifdef MRB_USE_BIGINT
      mrb_value msg = (mrb_funcall)(M, v, "message", 0);
      out += ": " + std::string(RSTRING_PTR(msg), RSTRING_LEN(msg));
  #endif
      return out;
    }
    mrb_value s = mrb_inspect(M, v);
    std::string out(RSTRING_PTR(s), RSTRING_LEN(s));
    if (mrb_integer_p(v) || mrb_bigint_p(v)) {
      mrb_value h = mrb_inspect(M, (mrb_funcall)(M, v, "hash", 0));
      out += " h=" + std::string(RSTRING_PTR(h), RSTRING_LEN(h));
    }
    return out;
  }
  static mrb_bool helper_int_min_operand(mrb_value v) {
    return mrb_integer_p(v) && mrb_integer(v) == MRB_INT_MIN;
  }
  static void helper_matrix(mrb_state* M) {
    mrb_value vals = mrb_gv_get(M, mrb_intern_lit(M, "$vals"));
    mrb_value counts = mrb_gv_get(M, mrb_intern_lit(M, "$counts"));
    int total = 0, bad = 0;
    for (const HelperCase& c : helper_cases) {
      mrb_value rights = c.kind == 2 ? counts : vals;
      mrb_int nb = c.kind == 4 ? 1 : RARRAY_LEN(rights);
      for (mrb_int i = 0; i < RARRAY_LEN(vals); ++i) for (mrb_int j = 0; j < nb; ++j) {
        mrb_value a = RARRAY_PTR(vals)[i];
        mrb_value b = c.kind == 4 ? mrb_nil_value() : RARRAY_PTR(rights)[j];
        // `String#<<` and `Array#<<` mutate the receiver, so the second call would see the first's append.
        if (c.kind == 2 && (mrb_string_p(a) || mrb_array_p(a))) continue;
        // `"s" * 2**62` exhausts memory by either route.
        if (c.kind == 0 && mrb_type(a) != MRB_TT_INTEGER && mrb_type(a) != MRB_TT_FLOAT && mrb_type(a) != MRB_TT_BIGINT &&
            (mrb_integer_p(b) || mrb_bigint_p(b))) continue;
        if (c.kind == 0 && mrb_integer_p(a) && mrb_integer_p(b) && (helper_int_min_operand(a) || helper_int_min_operand(b))) continue;
        int ai = mrb_gc_arena_save(M);
        HelperCall got_call = { &c, a, b, false }, want_call = { &c, a, b, true };
        mrb_bool e1 = FALSE, e2 = FALSE;
        mrb_value got = mrb_protect_error(M, helper_body, &got_call, &e1);
        std::string g = helper_describe(M, got, e1);
        mrb_value want = mrb_protect_error(M, helper_body, &want_call, &e2);
        std::string w = helper_describe(M, want, e2);
        mrb_gc_arena_restore(M, ai);
        ++total;
        if (g != w) {
          ++bad;
          if (bad <= 8) {
            mrb_value as = mrb_inspect(M, a), bs = mrb_inspect(M, b);
            std::printf("  H MISMATCH %s %.*s %.*s helper=%s method=%s\\n", c.name, (int)RSTRING_LEN(as), RSTRING_PTR(as),
                        (int)RSTRING_LEN(bs), RSTRING_PTR(bs), g.c_str(), w.c_str());
          }
        }
      }
    }
    std::printf("  H summary %d cases, %d mismatches\\n", total, bad);
  }
CPP

def scenario_body(source)
  <<~CPP
    #{PROBE}
    #{HELPER_MATRIX}
    static int scenario(mrb_state* M) {
      RClass* probe = mrb_define_module(M, "NsProbe");
      mrb_define_class_method(M, probe, "arena", probe_arena, MRB_ARGS_NONE());
      mrb_define_class_method(M, probe, "dispatches", probe_dispatches, MRB_ARGS_NONE());
      std::fflush(stdout);
      const char* src = R"BCD(#{source})BCD";
      mrb_load_string(M, src);
      if (M->exc) { mrb_print_error(M); M->exc = nullptr; return 1; }
      helper_matrix(M);
      return 0;
    }
  CPP
end

builds.each do |label, build, mrbc, flags, width, bigint|
  next if ONLY_CMP || ONLY_MISC
  puts "-- fixture on real mruby (#{label}), interpreted and compiled"
  saved = ENV.values_at('MRBC', 'BC2CPP_CXXFLAGS')
  ENV['MRBC'] = mrbc
  ENV['BC2CPP_CXXFLAGS'] = flags
  begin
    Dir.mktmpdir do |dir|
      fixture = bigint ? FIXTURE + FIXTURE_BIG : FIXTURE
      _code, err = runtime.generate(fixture, dir, closed: true, only_owners: %w[NsOpen NsBox NsCmp NsProven NsBig])
      source = "$bigint = #{bigint}\n#{driver(width)}"
      if bigint
        source += <<~RUBY
          seed = 2 ** 70 + 12345
          puts "churn => \#{NsBig.new.churn(seed, 3000).inspect}"
          puts "churn small => \#{NsBig.new.churn(3, 300).inspect}"
          puts "grow => \#{NsBig.new.grow(seed, 200).to_s.size}"
          puts 'end big'
        RUBY
      end
      # Dispatch counts and arena depths: two-space lines, which the comparison skips.
      source += <<~RUBY
        o = NsOpen.new
        ops = %w[add sub mul div mod band bor bxor lsh rsh lt le gt ge]
        pool = $vals.first(31) + ($bigint ? $vals.last(10) : [])
        ops.each_with_index do |op, k|
          pool.each do |a|
            pool.each do |b|
              next if %w[lsh rsh].include?(op) && !(b.is_a?(Integer) && b.abs < 200)
              next if skip_repeat(op, a, b)
              n = begin; o.dispatched(a, b, k); rescue => e; -1; end
              puts "  D \#{op} \#{owned(op, a, b) ? 1 : 0} \#{a.inspect} \#{b.inspect} \#{n}"
            end
          end
        end
        [14, 15, 16].each do |k|
          pool.each do |a|
            # zero? on a bigint stays a by-name call (Numeric#zero? runs Integer#==, left to the method); so does round on a Float.
            own = a.is_a?(Float) ? (k != 16) : (a.is_a?(Integer) && k != 15)
            puts "  D un\#{k} \#{own ? 1 : 0} \#{a.inspect} nil \#{(o.dispatched(a, nil, k) rescue -1)}"
          end
        end
        ar = ($bigint ? [2 ** 70, -(2 ** 70), 2 ** 100 + 1] : [IM, -IM])
        ar.each { |a| ar.each { |b| puts "  A \#{a.inspect} \#{b.inspect} \#{(o.arena(a, b) rescue -1)}" } }
        puts 'end'
      RUBY
      built, output = runtime.run(dir, err, %w[NsOpen NsBox NsCmp NsProven NsBig], scenario_body(source), build: build, full: true)
      check.call('the fixture compiles and runs against real mruby', built)
      puts output.to_s.lines.last(25).join unless built
      next unless built

      sections = runtime.sections(output)
      interpreted = sections['interpreted'].to_a
      compiled = sections['compiled'].to_a
      strip = ->(lines) { lines.reject { |l| l.start_with?('  ') } }
      check.call('both runs finish', strip.call(interpreted).last == 'end' && strip.call(compiled).last == 'end')
      # Every helper called directly against the method it stands for (HELPER_MATRIX), in both runs.
      [interpreted, compiled].each do |lines|
        summary = lines.grep(/\A  H summary /).first.to_s
        lines.grep(/\A  H MISMATCH /).first(5).each { |l| puts "    #{l.strip}" }
        check.call("each helper agrees with its method called directly (#{summary.strip})",
                   summary.match?(/ (\d+) cases, 0 mismatches/) && summary[/ (\d+) cases/, 1].to_i > 5000)
      end
      check.call("the matrix is large (#{strip.call(interpreted).size} answers)", strip.call(interpreted).size > 5000)
      same = strip.call(interpreted) == strip.call(compiled)
      check.call('every answer is the interpreter\'s: value, Float bits, Integer#hash, exception class and message', same)
      strip.call(interpreted).zip(strip.call(compiled)).reject { |a, b| a == b }.first(8).each do |a, b|
        puts "    interpreted: #{a}\n    compiled:    #{b}"
      end
      errors = strip.call(interpreted).count { |l| l.include?('Error') }
      check.call("the matrix includes exceptions (#{errors})", errors > 100)
      if bigint
        check.call('a loop of bigint arithmetic survives GC and ends where the interpreter does',
                   interpreted.any? { |l| l.start_with?('churn =>') } && interpreted.include?('end big'))
        check.call('the interpreter really makes bigints (2**100 appears)',
                   interpreted.any? { |l| l.include?('1267650600228229401496703205376') })
      else
        check.call('without mruby-bigint an overflow is the interpreter\'s RangeError', interpreted.any? { |l| l.include?('RangeError') })
      end

      # A numeric operand pair the helper owns makes no by-name call in the compiled run.
      owned_lines = compiled.grep(/\A  D \S+ 1 /)
      # -1 marks a pair that raised (a zero divisor, an oversized shift): the count is lost with the frame.
      bad = owned_lines.reject { |l| %w[0 -1].include?(l.split.last) }
      check.call("operand pairs a helper owns make no by-name call (#{owned_lines.size} pairs)",
                 owned_lines.size > 500 && bad.empty? && owned_lines.count { |l| l.end_with?(' 0') } > 500)
      bad.first(5).each { |l| puts "    dispatched: #{l.strip}" }
      arena = compiled.grep(/\A  A /).map { |l| l.split.last.to_i }
      check.call("a bigint operation leaves at most one arena entry (#{arena.max})", !arena.empty? && arena.max <= 1)
    end
  ensure
    ENV['MRBC'], ENV['BC2CPP_CXXFLAGS'] = saved
  end
end

# [name, fixture, owners, driver, [[helper, op, arity, rights]...]]: a helper whose else is a proven NoMethodError
# (ADR 0360 `/`, ADR 0364 `^` `>>` `round`) against the methods it replaces, interpreted and compiled.
CLOSED_RUNS = [
  ['`/`', FIXTURE_DIV, %w[NsDiv NsDivBox], :div_driver, [['bc2cpp_slow_div', '/', 2, :vals]]],
  ['`^` `>>` `round`', FIXTURE_BITS, BITS_OWNERS, :bits_driver,
   [['bc2cpp_slow_xor', '^', 2, :vals], ['bc2cpp_slow_rshift', '>>', 2, :counts], ['bc2cpp_slow_round', 'round', 1, :vals]]]
].freeze

CLOSED_RUNS.each do |name, fixture, owners, driver_name, specs|
  builds.each do |label, build, mrbc, flags, width, bigint|
    next if ONLY_CMP || ONLY_MISC

    puts "-- closed #{name} helper on real mruby (#{label}), interpreted and compiled"
    saved = ENV.values_at('MRBC', 'BC2CPP_CXXFLAGS')
    ENV['MRBC'] = mrbc
    ENV['BC2CPP_CXXFLAGS'] = flags
    begin
      Dir.mktmpdir do |dir|
        _code, err = runtime.generate(fixture, dir, closed: true, only_owners: owners)
        source = "$bigint = #{bigint}\n#{send(driver_name, width)}"
        built, output = runtime.run(dir, err, owners, closed_scenario(specs, source), build: build, full: true)
        check.call("the closed #{name} fixture compiles and runs against real mruby", built)
        puts output.to_s.lines.last(25).join unless built
        next unless built

        sections = runtime.sections(output)
        interpreted = sections['interpreted'].to_a
        compiled = sections['compiled'].to_a
        strip = ->(lines) { lines.reject { |l| l.start_with?('  ') } }
        check.call('both runs finish', strip.call(interpreted).last == 'end' && strip.call(compiled).last == 'end')
        check.call("every #{name} answer is the interpreter's (#{strip.call(interpreted).size} answers)",
                   strip.call(interpreted) == strip.call(compiled) && strip.call(interpreted).size > 500)
        strip.call(interpreted).zip(strip.call(compiled)).reject { |a, b| a == b }.first(8).each do |a, b|
          puts "    interpreted: #{a}\n    compiled:    #{b}"
        end
        check.call('the matrix has NoMethodError and TypeError rows',
                   interpreted.count { |l| l.include?('NoMethodError') } > 50 && interpreted.count { |l| l.include?('TypeError') } > 20)
        [interpreted, compiled].each do |lines|
          summary = lines.grep(/\A  H summary /).first.to_s
          lines.grep(/\A  H MISMATCH /).first(5).each { |l| puts "    #{l.strip}" }
          lines.grep(/\A  H op /).each { |l| puts "    #{l.strip}" }
          check.call("each helper agrees with its method called directly (#{summary.strip})",
                     summary.match?(/ 0 mismatches/) && summary[/ (\d+) cases/, 1].to_i > 500)
        end
      end
    ensure
      ENV['MRBC'], ENV['BC2CPP_CXXFLAGS'] = saved
    end
  end
end

# ADR 0366: the closed `- & | <<` helpers against the real operators (scripts/bc2cpp/collection_ops_matrix.rb), at every
# width, once more with the Complex and Rational macros set (the by-name copies must still answer alike).
builds.product([false, true]).each do |(label, build, mrbc, flags, width, bigint), legacy|
  next if ONLY_CMP || ONLY_MISC

  puts "-- closed `- & | <<` helpers on real mruby (#{label}#{legacy ? ', Complex and Rational macros set' : ''}), " \
       'interpreted and compiled'
  saved = ENV.values_at('MRBC', 'BC2CPP_CXXFLAGS')
  ENV['MRBC'] = mrbc
  ENV['BC2CPP_CXXFLAGS'] = legacy ? "#{flags} -DMRB_USE_COMPLEX -DMRB_USE_RATIONAL" : flags
  begin
    Dir.mktmpdir do |dir|
      owners = Bc2cppCollectionOpsMatrix::OWNERS
      _code, err = runtime.generate(Bc2cppCollectionOpsMatrix::FIXTURE.gsub('\\#', '#'), dir, closed: true, only_owners: owners,
                                                                                               drop_gems: %w[mruby-enumerator])
      consts = "FM = #{WIDTHS.fetch(width)[:fmax]}\nIM = $bigint ? FM * 2 + 1 : FM"
      source = "$bigint = #{bigint}\n#{Bc2cppCollectionOpsMatrix.driver(consts)}"
      scenario = Bc2cppCollectionOpsMatrix::SCENARIO.sub('__SOURCE__') { source }
      built, output = runtime.run(dir, err, owners, scenario, build: build, full: true)
      check.call('the closed `- & | <<` fixture compiles and runs against real mruby', built)
      puts output.to_s.lines.last(25).join unless built
      next unless built

      sections = runtime.sections(output)
      interpreted = sections['interpreted'].to_a
      compiled = sections['compiled'].to_a
      strip = ->(lines) { lines.reject { |l| l.start_with?(' ') } }
      check.call('both runs finish', strip.call(interpreted).last == 'end' && strip.call(compiled).last == 'end')
      rows = strip.call(interpreted)
      check.call("every `- & | <<` answer is the interpreter's: result, class, identity, mutation, element calls, IO data, error class and message (#{rows.size} answers)",
                 rows == strip.call(compiled) && rows.size > 3000)
      rows.zip(strip.call(compiled)).reject { |a, b| a == b }.first(8).each { |a, b| puts "    interpreted: #{a}\n    compiled:    #{b}" }
      check.call('the matrix has NoMethodError, TypeError, FrozenError, RangeError and IOError rows',
                 %w[NoMethodError TypeError FrozenError RangeError IOError].all? { |e| rows.count { |l| l.include?(e) } > 5 })
      check.call('the matrix runs the elements\' own hash, eql? and == (logged), a failing one, an IO write and a shared Array',
                 rows.any? { |l| l.include?('[:hash, 1]') } && rows.any? { |l| l.include?('[:eql, 2]') } && rows.any? { |l| l.include?('[:eq, 1]') } &&
                 rows.any? { |l| l.include?('RuntimeError: bad hash') } && rows.any? { |l| l.include?('RuntimeError: bad ==') } &&
                 rows.any? { |l| l.include?('io="io"') } && rows.any? { |l| l.include?('NsCollFile') })
      messages = ['NsCollPlain cannot be converted to Array', "can't modify frozen Array", "can't modify frozen String",
                  'out of char range', 'closed stream']
      missing = messages.reject { |m| rows.any? { |l| l.include?(m) } }
      puts "    missing messages: #{missing.inspect}" unless missing.empty?
      check.call('the matrix reaches the wrong-type, frozen and out-of-range messages', missing.empty?)
      [interpreted, compiled].each do |lines|
        summary = lines.grep(/\A  H summary /).first.to_s
        lines.grep(/\A  H MISMATCH |\A    (?:helper|method)=/).first(15).each { |l| puts "    #{l.strip}" }
        lines.grep(/\A  H op /).each { |l| puts "    #{l.strip}" }
        check.call("each helper agrees with its operator called directly, fresh operands per call (#{summary.strip})",
                   summary.match?(/ 0 mismatches/) && summary[/ (\d+) cases/, 1].to_i > 3000)
      end
      unless legacy
        owned_lines = compiled.grep(/\A  D \S+ 1 /)
        bad = owned_lines.reject { |l| %w[0 -1].include?(l.split.last) }
        check.call("a pair the helpers own makes no by-name call (#{owned_lines.size} pairs)",
                   owned_lines.size > 30 && bad.empty? && owned_lines.count { |l| l.end_with?(" 0") } > 30)
        bad.first(5).each { |l| puts "    dispatched: #{l.strip}" }
        arena = compiled.grep(/\A  A /).map { |l| l.split.last.to_i }
        check.call("an Array, String, IO or bigint result leaves at most one arena entry (#{arena.max})", !arena.empty? && arena.max <= 1)
      end
      check.call('a loop of Array and String operations survives GC and ends where the interpreter does',
                 rows.any? { |l| l.start_with?('churn =>') } && rows.grep(/\Achurn =>/) == strip.call(compiled).grep(/\Achurn =>/))
    end
  ensure
    ENV['MRBC'], ENV['BC2CPP_CXXFLAGS'] = saved
  end
end

# The second pass defines MRB_USE_COMPLEX and MRB_USE_RATIONAL, as a libmruby that links those gems does: the helpers
# then keep their by-name copy, which must still build and answer as the interpreter does.
builds.product([false, true]).each do |(label, build, mrbc, flags, width, bigint), legacy|
  next if ONLY_CMP || ONLY_MISC
  puts "-- closed `+` and `*` helpers on real mruby (#{label}#{legacy ? ', Complex and Rational macros set' : ''}), " \
       'interpreted and compiled'
  saved = ENV.values_at('MRBC', 'BC2CPP_CXXFLAGS')
  ENV['MRBC'] = mrbc
  ENV['BC2CPP_CXXFLAGS'] = legacy ? "#{flags} -DMRB_USE_COMPLEX -DMRB_USE_RATIONAL" : flags
  begin
    Dir.mktmpdir do |dir|
      owners = %w[NsArith NsArithBox NsArithConv NsArithStr NsArithAry]
      _code, err = runtime.generate(FIXTURE_ARITH, dir, closed: true, only_owners: owners)
      source = "$bigint = #{bigint}\n#{arith_driver(width)}"
      # Dispatch counts and arena depths (two-space lines, which the comparison skips), then a GC-pressure loop.
      source += <<~RUBY
        o = NsArith.new
        pool = $vals.reject { |v| v.is_a?(Array) && v.size > 20 }
        pool.each do |a|
          pool.each do |b|
            [0, 1].each do |k|
              next if k == 1 && skip_repeat(a, b)
              own = (a.is_a?(Integer) || a.is_a?(Float) || a.is_a?(String) || a.is_a?(Array)) ? 1 : 0
              puts "  D \#{k} \#{own} \#{desc(a)} \#{desc(b)} \#{(o.dispatched(a, b, k) rescue -1)}"
            end
          end
        end
        [["ab", "cd"], ["ab", 3], [[1, 2], [3]], [[1], 3], [[1], ","], [1.5, 2], [1, "x"]].each do |a, b|
          puts "  A \#{desc(a)} \#{desc(b)} \#{(o.arena(a, b) rescue -1)}"
        end
        ($bigint ? [[2 ** 70, 1], [2 ** 70, 2 ** 70], [1.5, 2 ** 70]] : []).each do |a, b|
          puts "  A \#{desc(a)} \#{desc(b)} \#{(o.arena(a, b) rescue -1)}"
        end
        puts "churn => \#{o.churn(2000).inspect}"
        puts 'end churn'
      RUBY
      scenario = ARITH_SCENARIO.sub('__SOURCE__') { source }
      built, output = runtime.run(dir, err, owners, scenario, build: build, full: true)
      check.call('the closed `+` / `*` fixture compiles and runs against real mruby', built)
      puts output.to_s.lines.last(25).join unless built
      next unless built

      sections = runtime.sections(output)
      interpreted = sections['interpreted'].to_a
      compiled = sections['compiled'].to_a
      strip = ->(lines) { lines.reject { |l| l.start_with?('  ') } }
      check.call('both runs finish', strip.call(interpreted).last == 'end churn' && strip.call(compiled).last == 'end churn')
      check.call("every `+` / `-` / `*` answer is the interpreter's: value, class, frozen-ness, error class and message " \
                 "(#{strip.call(interpreted).size} answers)",
                 strip.call(interpreted) == strip.call(compiled) && strip.call(interpreted).size > 5000)
      strip.call(interpreted).zip(strip.call(compiled)).reject { |a, b| a == b }.first(8).each do |a, b|
        puts "    interpreted: #{a}\n    compiled:    #{b}"
      end
      check.call('the matrix has NoMethodError, TypeError, ArgumentError and RangeError rows',
                 %w[NoMethodError TypeError ArgumentError RangeError].all? { |e| interpreted.count { |l| l.include?(e) } > 20 })
      check.call('the matrix reaches the String#*, Array#* and Array#+ size errors and the negative count',
                 (!bigint || interpreted.any? { |l| l.include?('argument too big') }) && interpreted.any? { |l| l.include?('array size too big') } &&
                 interpreted.any? { |l| l.include?('negative argument') })
      [interpreted, compiled].each do |lines|
        summary = lines.grep(/\A  H summary /).first.to_s
        lines.grep(/\A  H MISMATCH /).first(5).each { |l| puts "    #{l.strip}" }
        check.call("each helper agrees with its method called directly (#{summary.strip})",
                   summary.match?(/ 0 mismatches/) && summary[/ (\d+) cases/, 1].to_i > 5000)
      end
      unless legacy
        owned_lines = compiled.grep(/\A  D \d 1 /)
        bad = owned_lines.reject { |l| %w[0 -1].include?(l.split.last) }
        check.call("a pair the helpers own makes no by-name call (#{owned_lines.size} pairs)",
                   owned_lines.size > 1000 && bad.empty? && owned_lines.count { |l| l.end_with?(' 0') } > 1000)
        bad.first(5).each { |l| puts "    dispatched: #{l.strip}" }
        arena = compiled.grep(/\A  A /).map { |l| l.split.last.to_i }
        check.call("a String, Array or bigint result leaves at most one arena entry (#{arena.max})", !arena.empty? && arena.max <= 1)
      end
      check.call('a loop of String and Array arithmetic survives GC and ends where the interpreter does',
                 strip.call(interpreted).any? { |l| l.start_with?('churn =>') } &&
                 strip.call(interpreted).grep(/\Achurn =>/) == strip.call(compiled).grep(/\Achurn =>/))
    end
  ensure
    ENV['MRBC'], ENV['BC2CPP_CXXFLAGS'] = saved
  end
end

# ADR 0367: the closed `%` and `-@` helpers against the methods they replace, at every width. The second pass defines
# MRB_USE_COMPLEX and MRB_USE_RATIONAL, as a libmruby that links those gems does: the by-name copies then run, and must
# answer as the interpreter does.
builds.product([false, true]).each do |(label, build, mrbc, flags, width, bigint), legacy|
  next if ONLY_CMP

  puts "-- closed `%` and `-@` helpers on real mruby (#{label}#{legacy ? ', Complex and Rational macros set' : ''}), " \
       'interpreted and compiled'
  saved = ENV.values_at('MRBC', 'BC2CPP_CXXFLAGS')
  ENV['MRBC'] = mrbc
  ENV['BC2CPP_CXXFLAGS'] = legacy ? "#{flags} -DMRB_USE_COMPLEX -DMRB_USE_RATIONAL" : flags
  begin
    Dir.mktmpdir do |dir|
      _code, err = runtime.generate(FIXTURE_MISC, dir, closed: true, only_owners: MISC_OWNERS)
      source = "$bigint = #{bigint}\n#{misc_driver(width)}"
      # Dispatch counts and arena depths (two-space lines, which the comparison skips), then a GC-pressure loop.
      source += <<~RUBY
        o = NsMisc.new
        ($nums + $strs.first(12)).each do |a|
          [1, 2.5, "x", [1, 2], nil].each do |b|
            own = (a.is_a?(Integer) || a.is_a?(Float) || a.is_a?(String)) ? 1 : 0
            puts "  D 0 \#{own} \#{desc(a)} \#{desc(b)} \#{(o.dispatched(a, b, 0) rescue -1)}"
          end
        end
        $recvs.each do |a|
          own = (a.is_a?(Integer) || a.is_a?(Float) || a.is_a?(String) || a.is_a?(Numeric)) ? 1 : 0
          puts "  D 1 \#{own} \#{desc(a)} nil \#{(o.dispatched(a, nil, 1) rescue -1)}"
        end
        [["%s %s", ["a", "b"]], ["%d", 5], ["%05.1f", 2.5], ["%{a}", {a: 1}], ["abc", []]].each do |a, b|
          puts "  A \#{desc(a)} \#{desc(b)} \#{(o.arena(a, b) rescue -1)}"
        end
        ($bigint ? [[2 ** 70, 3], [-(2 ** 70), 2 ** 65]] : [[IM, 3]]).each do |a, b|
          puts "  A \#{desc(a)} \#{desc(b)} \#{(o.arena(a, b) rescue -1)}"
        end
        puts "churn => \#{o.churn(1500).inspect}"
        puts 'end churn'
      RUBY
      scenario = MISC_SCENARIO.sub('__SOURCE__') { source }.gsub('__LEGACY__', legacy ? '1' : '0')
      built, output = runtime.run(dir, err, MISC_OWNERS, scenario, build: build, full: true)
      check.call('the closed `%` / `-@` fixture compiles and runs against real mruby', built)
      puts output.to_s.lines.last(25).join unless built
      next unless built

      sections = runtime.sections(output.to_s.scrub)
      interpreted = sections['interpreted'].to_a
      compiled = sections['compiled'].to_a
      strip = ->(lines) { lines.reject { |l| l.start_with?('  ') } }
      check.call('both runs finish', strip.call(interpreted).last == 'end churn' && strip.call(compiled).last == 'end churn')
      rows = strip.call(interpreted)
      check.call("every `%` and `-@` answer is the interpreter's: value, class, frozen-ness, error class and message (#{rows.size} answers)",
                 rows == strip.call(compiled) && rows.size > 5000)
      rows.zip(strip.call(compiled)).reject { |a, b| a == b }.first(8).each do |a, b|
        puts "    interpreted: #{a}\n    compiled:    #{b}"
      end
      check.call('the matrix has NoMethodError, TypeError, ArgumentError, ZeroDivisionError and RangeError rows',
                 %w[NoMethodError TypeError ArgumentError ZeroDivisionError RangeError].all? { |e| rows.count { |l| l.include?(e) } > 10 })
      check.call('the format directives are exercised (a padded integer, a hash reference, a width taken from an argument)',
                 rows.any? { |l| l.start_with?('mod "%05d" cls=String 7 h=') && l.include?('=> "00007" cls=String') } &&
                 rows.any? { |l| l.start_with?('mod "%{a}" cls=String {a: 1}') && l.include?('=> "1" cls=String') } &&
                 rows.any? { |l| l.start_with?('mod "%s %s" cls=String [1, 2] cls=Array =>') && l.include?('"1 2"') })
      check.call('String#-@ keeps a frozen receiver and freezes a copy of any other',
                 rows.any? { |l| l.start_with?('neg same "%d" cls=String frozen') && l.end_with?('=> true') } &&
                 rows.any? { |l| l.start_with?('neg "%s" cls=String =>') && l.include?('frozen') })
      check.call('an Array a format argument empties while it formats is read from the copy the splat made',
                 rows.include?('mut => "m 1 2" cls=String') && rows.include?('mut hash => ArgumentError: one hash required'))
      [interpreted, compiled].each do |lines|
        summary = lines.grep(/\A  H summary /).first.to_s
        lines.grep(/\A  H (?:MISMATCH|DISPATCH) /).first(5).each { |l| puts "    #{l.strip}" }
        check.call("each helper agrees with its operator called directly, with the by-name calls the proof allows (#{summary.strip})",
                   summary.match?(/ 0 mismatches, 0 wrong dispatch counts/) && summary[/ (\d+) cases/, 1].to_i > 5000)
      end
      unless legacy
        owned_lines = compiled.grep(/\A  D \d 1 /)
        bad = owned_lines.reject { |l| %w[0 -1].include?(l.split.last) }
        check.call("a receiver the helpers own makes no by-name call (#{owned_lines.size} receivers)",
                   owned_lines.size > 150 && bad.empty? && owned_lines.count { |l| l.end_with?(' 0') } > 150)
        bad.first(5).each { |l| puts "    dispatched: #{l.strip}" }
        arena = compiled.grep(/\A  A /).map { |l| l.split.last.to_i }
        check.call("a String or bigint result leaves at most one arena entry (#{arena.max})", !arena.empty? && arena.max <= 1)
      end
      check.call('a loop of formats and frozen copies survives GC and ends where the interpreter does',
                 rows.any? { |l| l.start_with?('churn =>') } && rows.grep(/\Achurn =>/) == strip.call(compiled).grep(/\Achurn =>/))
    end
  ensure
    ENV['MRBC'], ENV['BC2CPP_CXXFLAGS'] = saved
  end
end

# The String arms call exports of mruby-sprintf and mruby-string-ext through weak references, so a libmruby without
# those gems (the gem-free core build the other checks share) links the same generated code, and a String then takes
# the helper's NoMethodError arm, which is what that libmruby's interpreter answers (ADR 0367).
core_build = runtime.core
if core_build && runtime.compiler? && !ONLY_CMP
  puts '-- closed `%` helper linked against a gem-free libmruby (the gem exports are weak references)'
  Dir.mktmpdir do |dir|
    # A gem-free libmruby has no exported collection bodies either (ADR 0366), so those helpers stay by name here.
    runtime.collection_exports_linked = false
    begin
      _code, err = runtime.generate(FIXTURE_MISC, dir, closed: true, only_owners: MISC_OWNERS)
    ensure
      runtime.collection_exports_linked = true
    end
    scenario = <<~CPP
      static int scenario(mrb_state* M) {
        mrb_value o = mrb_obj_new(M, mrb_class_get(M, "NsMisc"), 0, nullptr);
        mrb_value a1[] = { mrb_str_new_lit(M, "%d"), mrb_fixnum_value(5) };
        call(M, "string", o, "mod", 2, a1);
        mrb_value a2[] = { mrb_fixnum_value(7), mrb_fixnum_value(3) };
        call(M, "integer", o, "mod", 2, a2);
        mrb_value a3[] = { mrb_float_value(M, 7.5), mrb_fixnum_value(2) };
        call(M, "float", o, "mod", 2, a3);
        mrb_value a4[] = { mrb_fixnum_value(7), mrb_float_value(M, 2.5) };
        call(M, "mixed", o, "mod", 2, a4);
        mrb_value a5[] = { mrb_fixnum_value(7), mrb_fixnum_value(0) };
        call(M, "zero", o, "mod", 2, a5);
        mrb_value a6[] = { mrb_nil_value(), mrb_fixnum_value(1) };
        call(M, "nil", o, "mod", 2, a6);
        return 0;
      }
    CPP
    built, output = runtime.run(dir, err, MISC_OWNERS, scenario, build: core_build, full: false)
    check.call('the closed `%` / `-@` fixture links against a gem-free libmruby', built)
    puts output.to_s.lines.last(25).join unless built
    if built
      sections = runtime.sections(output)
      strip = ->(lines) { lines.reject { |l| l.start_with?('  ') } }
      unless strip.call(sections['interpreted'].to_a) == strip.call(sections['compiled'].to_a)
        puts output.to_s.lines.map { |l| "    #{l}" }.join
      end
      check.call("...and answers as that libmruby's interpreter does: a String receiver raises, a number gets the method's answer (#{strip.call(sections['compiled'].to_a).size} answers)",
                 strip.call(sections['interpreted'].to_a) == strip.call(sections['compiled'].to_a) &&
                 strip.call(sections['compiled'].to_a).any? { |l| l.start_with?('string => raised') } &&
                 strip.call(sections['compiled'].to_a).any? { |l| l.start_with?('integer => 1') } &&
                 strip.call(sections['compiled'].to_a).any? { |l| l.start_with?('zero => raised ZeroDivisionError') })
    end
  end
end

builds.each do |label, build, mrbc, flags, width, bigint|
  next if ONLY_MISC

  puts "-- closed comparison helpers on real mruby (#{label}), interpreted and compiled"
  saved = ENV.values_at('MRBC', 'BC2CPP_CXXFLAGS')
  ENV['MRBC'] = mrbc
  ENV['BC2CPP_CXXFLAGS'] = flags
  begin
    Dir.mktmpdir do |dir|
      _code, err = runtime.generate(FIXTURE_CMP, dir, closed: true, only_owners: CMP_OWNERS)
      source = "$bigint = #{bigint}\n#{cmp_driver(width)}"
      scenario = CMP_SCENARIO.sub('__SOURCE__') { source }
      built, output = runtime.run(dir, err, CMP_OWNERS, scenario, build: build, full: true)
      check.call('the closed comparison fixture compiles and runs against real mruby', built)
      puts output.to_s.lines.last(25).join unless built
      next unless built

      sections = runtime.sections(output)
      interpreted = sections['interpreted'].to_a
      compiled = sections['compiled'].to_a
      strip = ->(lines) { lines.reject { |l| l.start_with?('  ') } }
      check.call('both runs finish', strip.call(interpreted).last == 'end' && strip.call(compiled).last == 'end')
      rows = strip.call(interpreted)
      check.call("every comparison answer is the interpreter's (#{rows.size} answers)",
                 rows == strip.call(compiled) && rows.size > 10_000)
      rows.zip(strip.call(compiled)).reject { |a, b| a == b }.first(8).each do |a, b|
        puts "    interpreted: #{a}\n    compiled:    #{b}"
      end
      check.call('the matrix has NoMethodError, ArgumentError and TypeError rows, and String, Symbol and Hash receivers',
                 %w[NoMethodError ArgumentError TypeError].all? { |e| rows.count { |l| l.include?(e) } > 50 } &&
                 rows.any? { |l| l.start_with?('lt "a" "b" => true') } && rows.any? { |l| l.start_with?('lt :a :b => true') } &&
                 rows.any? { |l| l.start_with?('lt {a: 1} {a: 1, b: 2} => true') })
      check.call("String and Symbol receivers raise Comparable's message",
                 rows.any? { |l| l.start_with?('lt "a" 1 =>') && l.end_with?('ArgumentError: comparison of String with Integer failed') } &&
                 rows.any? { |l| l.start_with?('ge :a nil =>') && l.end_with?('ArgumentError: comparison of Symbol with NilClass failed') })
      [interpreted, compiled].each do |lines|
        summary = lines.grep(/\A  H summary /).first.to_s
        lines.grep(/\A  H (?:MISMATCH|DISPATCH) /).first(5).each { |l| puts "    #{l.strip}" }
        check.call("each helper agrees with its operator called directly, with the by-name calls the proof allows (#{summary.strip})",
                   summary.match?(/ 0 mismatches, 0 wrong dispatch counts/) && summary[/ (\d+) cases/, 1].to_i > 10_000)
      end
    end
  ensure
    ENV['MRBC'], ENV['BC2CPP_CXXFLAGS'] = saved
  end
end

if failures.empty?
  puts 'bc2cpp numeric slow-path check: PASS'
else
  warn "bc2cpp numeric slow-path check: #{failures.size} failure(s)"
  exit 1
end
