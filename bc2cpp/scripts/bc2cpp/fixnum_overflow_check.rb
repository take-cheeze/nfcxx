#!/usr/bin/env ruby
# frozen_string_literal: true

# ADR 0279: every Fixnum-tier arithmetic arm is overflow-exact, and a computed result is
# never trusted to be a Fixnum.
#
# 1. With MRBC: the generated code of a closed-world fixture. No arm stores a bare
#    `mrb_fixnum_value(a op b)`; the tier is `mrb_int_*_overflow` + FIXABLE with the
#    mrb_num_* helper on the other side; `>>` boxes through FIXABLE; the result of an
#    ADD/SUB/MUL is not a proven Fixnum, so the next operator keeps its tag checks.
# 2. With a mruby build and g++: the fixture runs interpreted and compiled and must answer
#    alike on Fixnum/mrb_int boundary operands (fact(25), 2**62, MRB_INT_MAX/MIN, negative
#    shift counts, `-MIN`, `%` and `<<` edges) for every operator, both in methods the
#    Fixnum proof covers (OvfProven, called only with proven arguments) and in methods it
#    does not (OvfOpen). The same run repeats against a build whose mrb_int is 32 bits wide
#    (the Emscripten/Wio/PSP width, where a Fixnum has 31 bits) when BC2CPP_MRUBY_FULL32 and
#    BC2CPP_MRBC32 name one: `-DMRB_32BIT -DMRB_INT32` on a 64-bit host gives exactly that
#    arithmetic (`MRB_INT32` alone keeps 32-bit Fixnums: a different, unshifted regime).
#
# Usage: [MRBC=path/to/mrbc BC2CPP_MRUBY_CORE=dir BC2CPP_MRUBY_FULL=dir
#         BC2CPP_MRUBY_FULL32=dir BC2CPP_MRBC32=mrbc32] ruby scripts/bc2cpp/fixnum_overflow_check.rb

require 'tmpdir'
require_relative 'fixture_runtime'

runtime = Bc2cppFixtureRuntime
failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

FIXTURE = <<~RUBY
  class OvfProven
    def add(a, b) = a + b
    def sub(a, b) = a - b
    def mul(a, b) = a * b
    def inc(a) = a + 1
    def dec(a) = a - 1
    def neg(a) = -a
    def lsh(a, n) = a << n
    def rsh(a, n) = a >> n
    def mod(a, b) = a % b
    def fact(n) = n < 2 ? 1 : n * fact(n - 1)

    def count_up(n)
      i = 0
      s = 0
      while i < n
        s += i * i * i
        i += 1
      end
      s
    end

    def chain(a, b)
      (a + b) * (a - b) + a * b
    end

    def span(first, last)
      total = 0
      (first..last).each { |i| total += i }
      total
    end

    def ovf_mix(a) = (a + 1) * (a - 1)

    def run
      x = 2_000_000_000
      big = x * x
      add(big, big)
      add(big * 2, big)
      sub(0 - big * 2, big * 2)
      mul(big, 3)
      mul(x, x)
      inc(big * 2)
      dec(0 - big * 2)
      neg(big)
      lsh(3, 30)
      lsh(1, 62)
      lsh(1, 31)
      lsh(-1, 62)
      lsh(big, 1)
      rsh(1, -62)
      rsh(1, -31)
      rsh(1, -30)
      rsh(-1, -62)
      rsh(-5, 1)
      mod(-7, 3)
      mod(7, -3)
      mod(x, 7)
      fact(5)
      fact(25)
      count_up(3)
      count_up(200_000)
      chain(x, 3)
      chain(big, 5)
      span(1, 4)
      ovf_mix(7)
      big + 1
    end
  end

  class OvfOpen
    def add(a, b) = a + b
    def sub(a, b) = a - b
    def mul(a, b) = a * b
    def inc(a) = a + 1
    def dec(a) = a - 1
    def neg(a) = -a
    def lsh(a, n) = a << n
    def rsh(a, n) = a >> n
    def mod(a, b) = a % b
    def fact(n) = n < 2 ? 1 : n * fact(n - 1)
    def chain(a, b) = (a + b) * (a - b) + a * b
    def span(first, last)
      total = 0
      (first..last).each { |i| total += i }
      total
    end
  end
RUBY

# Boundary operands, resolved against the build's own MRB_FIXNUM_*/MRB_INT_* (a 32-bit
# mrb_int has 31-bit Fixnums; mrb_int_value makes the heap Integer between the two).
SCENARIO = <<~CPP
  static int scenario(mrb_state* M) {
    mrb_value proven = mrb_obj_new(M, mrb_class_get(M, "OvfProven"), 0, nullptr);
    mrb_value open = mrb_obj_new(M, mrb_class_get(M, "OvfOpen"), 0, nullptr);
    call(M, "run", proven, "run");
    mrb_value vals[] = {
      mrb_fixnum_value(0), mrb_fixnum_value(1), mrb_fixnum_value(-1), mrb_fixnum_value(7), mrb_fixnum_value(-7),
      mrb_fixnum_value(MRB_FIXNUM_MAX), mrb_fixnum_value(MRB_FIXNUM_MIN),
      mrb_fixnum_value(MRB_FIXNUM_MAX - 1), mrb_fixnum_value(MRB_FIXNUM_MIN + 1),
      mrb_fixnum_value(MRB_FIXNUM_MAX / 2 + 1), mrb_fixnum_value(MRB_FIXNUM_MIN / 2),
      mrb_int_value(M, MRB_INT_MAX), mrb_int_value(M, MRB_INT_MIN + 1)
    };
    // MRB_INT_MIN itself only as a receiver: mruby's Integer#+ on a (n, MRB_INT_MIN) pair negates the
    // heap operand (mpz_add_int(-n)), which the VM's own OP_ADD never does; that is core's, not ours.
    mrb_value min = mrb_int_value(M, MRB_INT_MIN);
    const char* binary[] = { "add", "sub", "mul", "mod", "chain" };
    for (const char* op : binary) for (mrb_value a : vals) for (mrb_value b : vals) {
      mrb_value ab[2] = { a, b };
      call(M, op, open, op, 2, ab);
    }
    for (mrb_value b : vals) for (const char* op : binary) {
      mrb_value ab[2] = { min, b };
      call(M, op, open, op, 2, ab);
    }
    std::vector<mrb_value> unary(vals, vals + sizeof vals / sizeof vals[0]);
    unary.push_back(min);
    for (mrb_value a : unary) {
      call(M, "inc", open, "inc", 1, &a);
      call(M, "dec", open, "dec", 1, &a);
      call(M, "neg", open, "neg", 1, &a);
    }
    mrb_value f[] = { mrb_fixnum_value(20), mrb_fixnum_value(21), mrb_fixnum_value(25) };
    for (mrb_value n : f) call(M, "fact", open, "fact", 1, &n);
    mrb_int counts[] = { -70, -64, -63, -62, -31, -30, -1, 0, 1, 2, 30, 31, 32, 62, 63, 64, 70,
                         MRB_FIXNUM_MIN, MRB_FIXNUM_MIN + 1 };
    for (const char* op : { "lsh", "rsh" }) for (mrb_value a : unary) for (mrb_int n : counts) {
      mrb_value ab[2] = { a, mrb_fixnum_value(n) };
      call(M, op, open, op, 2, ab);
    }
    // Range#each with a bound at the top of the Fixnum and mrb_int ranges.
    mrb_value ranges[][2] = {
      { mrb_fixnum_value(MRB_FIXNUM_MAX - 2), mrb_fixnum_value(MRB_FIXNUM_MAX) },
      { mrb_fixnum_value(MRB_FIXNUM_MAX), mrb_int_value(M, (mrb_int)MRB_FIXNUM_MAX + 2) },
      { mrb_int_value(M, MRB_INT_MAX - 3), mrb_int_value(M, MRB_INT_MAX - 1) },
      { mrb_int_value(M, MRB_INT_MIN), mrb_int_value(M, MRB_INT_MIN + 2) },
    };
    for (auto& r : ranges) call(M, "span", open, "span", 2, r);
    return 0;
  }
CPP

def generated(dir)
  runtime = Bc2cppFixtureRuntime
  code, err = runtime.generate(FIXTURE, dir, closed: true, only_owners: %w[OvfProven OvfOpen])
  [code, err]
end

puts '-- generated code (closed world)'
if ENV['MRBC']
  Dir.mktmpdir do |dir|
    code, = generated(dir)
    chunk = lambda do |owner_method|
      code[/^\/\/ #{Regexp.escape(owner_method)} \(compiled from.*?(?=^\/\/ \S+#\S+ \(compiled from|\z)/m].to_s
    end
    check.call('no arm stores a bare mrb_fixnum_value(a op b)',
               !code.match?(/mrb_fixnum_value\(mrb_fixnum\(r\d+\)\s*[-+*]/))
    %w[add sub mul inc dec].each do |name|
      c = chunk.call("OvfOpen##{name}")
      check.call("OvfOpen##{name}: overflow-checked, FIXABLE-checked, mrb_num_* on the other side",
                 c.match?(/mrb_int_(?:add|sub|mul)_overflow/) && c.include?('!FIXABLE(bc2cpp_z)') &&
                   c.match?(/mrb_num_(?:add|sub|mul)\(M/))
    end
    %w[add sub mul neg lsh rsh mod].each do |name|
      check.call("OvfOpen##{name}: the arm's else is a NUMERIC_SLOW_PATH helper call, no by-name call of its own (ADR 0292)",
                 chunk.call("OvfOpen##{name}").match?(/bc2cpp_slow_\w+\(M, /) && !chunk.call("OvfOpen##{name}").include?('bc2cpp_send('))
    end
    fact = chunk.call('OvfProven#fact')
    check.call('the proven recursion multiplies through the overflow tier',
               fact.include?('mrb_int_mul_overflow') && fact.include?('mrb_num_mul(M'))
    ovf_mix = chunk.call('OvfProven#ovf_mix')
    check.call('an ADD/SUB result is not a proven Fixnum: only the two ops on the argument are, the MUL keeps its tag checks',
               ovf_mix.scan('operands proven Fixnum').size == 2 && ovf_mix.match?(/mrb_fixnum_p\(r\d+\) && mrb_fixnum_p\(r\d+\)/))
        check.call('>> boxes its result through FIXABLE', chunk.call('OvfOpen#rsh').include?('FIXABLE(bc2cpp_shift_result)'))
    span = chunk.call('OvfOpen#span') + code.scan(/^static mrb_value OvfOpen_span_block\S*.*?^\}\n/m).join
    check.call('Range#each boxes its counter through FIXABLE and stops before ++i can wrap',
               span.include?('FIXABLE(bc2cpp_range_i_') && span.include?('>= bc2cpp_range_z_'))
  end
else
  puts '  SKIP: set MRBC'
end

# [label, build dir, mrbc, extra flags]
builds = []
# The boundary matrix needs bignums and Integer#-@ in the interpreter, which a gem-less core lacks
# (it raises where compiled code has its own Fixnum arms), so the run is against a full-core mruby:
# BC2CPP_MRUBY_FULL, or one built into BC2CPP_FULL_BUILD_DIR (the core-mrbtest shard shares it).
full = runtime.full || (ENV['BC2CPP_FULL_BUILD_DIR'] ? runtime.full_or_build : nil)
# -DMRB_USE_BIGINT: the libmruby builds have mruby-bigint, and the generated code's bigint arms
# (NUMERIC_SLOW_PATH, ADR 0292) are compiled in only with it.
builds << ['mrb_int 64', full, ENV['MRBC'], '-DMRB_USE_BIGINT'] if full && runtime.compiler?
if ENV['BC2CPP_MRUBY_FULL32'] && ENV['BC2CPP_MRBC32'] && runtime.compiler?
  builds << ['mrb_int 32 (MRB_INT32)', ENV['BC2CPP_MRUBY_FULL32'], ENV['BC2CPP_MRBC32'], '-DMRB_32BIT -DMRB_INT32 -DMRB_USE_BIGINT']
end

if builds.empty?
  puts '-- SKIP run: set BC2CPP_MRUBY_FULL (libmruby.a with the full-core gems) or BC2CPP_FULL_BUILD_DIR, and have g++'
end

builds.each do |label, build, mrbc, flags|
  puts "-- fixture on real mruby (#{label}), interpreted and compiled"
  saved = ENV.values_at('MRBC', 'BC2CPP_CXXFLAGS')
  ENV['MRBC'] = mrbc
  ENV['BC2CPP_CXXFLAGS'] = flags
  begin
    Dir.mktmpdir do |dir|
      _code, err = generated(dir)
      built, output = runtime.run(dir, err, %w[OvfProven OvfOpen], SCENARIO, build: build,
                                                                              full: File.exist?("#{build}/lib/libmruby.a"))
      check.call('the fixture compiles and runs against real mruby', built)
      puts output unless built
      next unless built

      sections = runtime.sections(output)
      values = ->(name) { sections.fetch(name, []).reject { |l| l.start_with?('  ') } }
      interpreted = values.call('interpreted')
      compiled = values.call('compiled')
      check.call("the run covers the boundary matrix (#{interpreted.size} answers)", interpreted.size > 1000)
      check.call('every method answers what the interpreter answers, values and exceptions alike',
                 !interpreted.empty? && interpreted == compiled)
      interpreted.zip(compiled).reject { |a, b| a == b }.first(8).each { |a, b| puts "    interpreted #{a}\n    compiled    #{b}" }
      fact25 = interpreted.find { |l| l.start_with?('fact => 15511210043330985984000000') }
      raised = interpreted.count { |l| l.include?('raised') }
      check.call('the interpreter really overflows (fact(25) is a bignum, or this core raises RangeError)',
                 fact25 || raised.positive?)
    end
  ensure
    ENV['MRBC'], ENV['BC2CPP_CXXFLAGS'] = saved
  end
end

if failures.empty?
  puts 'bc2cpp fixnum overflow check: PASS'
else
  warn "bc2cpp fixnum overflow check: #{failures.size} failure(s)"
  exit 1
end
