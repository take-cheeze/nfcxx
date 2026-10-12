#!/usr/bin/env ruby
# frozen_string_literal: true

# Check STEP_LOOP_SUPPORT (docs/adr/0273): `a.step(limit, step) { }`, `a.upto(limit) { }` and
# `a.downto(limit) { }` with operands that are provably Integers compile to a native loop in
# the method's own frame instead of a block call.
#
#   - generated code: which sites are inlined, which of them carry STEP_LOOP_GUARD (an Integer
#     bound that may be a bignum, docs/adr/0287), and that a Float receiver or limit, a zero
#     step, a step that is not a literal and a loop that may yield keep the call;
#   - behaviour (needs a full-core libmruby, see Bc2cppFixtureRuntime.full_or_build): the
#     compiled methods return what the interpreted ones do (values, break, next, an empty
#     range, negative steps, parameterless blocks, captured locals, Float and Range users),
#     and so do guarded loops whose bound sits at, just inside and just past the top and the
#     bottom of the Fixnum range. That second half repeats against a build whose mrb_int is 32
#     bits wide (31-bit Fixnums) when BC2CPP_MRUBY_FULL32 and BC2CPP_MRBC32 name one, built
#     with -DMRB_32BIT -DMRB_INT32 (see scripts/bc2cpp/fixnum_overflow_check.rb).
#
# Usage: [MRBC=path/to/mrbc BC2CPP_MRUBY_FULL32=dir BC2CPP_MRBC32=mrbc32]
#        ruby scripts/bc2cpp/step_inline_check.rb

require 'tmpdir'
require_relative 'fixture_runtime'

failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

FIXTURE = <<~'RUBY'
  class StFx
    def step_sum; s = 0; 1.step(10, 3) { |i| s += i }; s; end
    def step_value; 1.step(10, 3) { |i| i * 100 }; end
    def step_neg; a = []; 10.step(1, -4) { |i| a << i }; a; end
    def step_empty; a = []; 5.step(1, 1) { |i| a << i }; a; end
    def step_empty_neg; a = []; 1.step(5, -1) { |i| a << i }; a; end
    def step_one; a = []; 4.step(4, 7) { |i| a << i }; a; end
    def step_noparam; n = 0; 0.step(9, 3) { n += 1 }; n; end
    def step_break; 1.step(100, 1) { |i| break i * 2 if i > 4 }; end
    def step_break_none; 1.step(3, 1) { |i| break :never if i > 9 }; end
    def step_next; a = []; 1.step(7, 1) { |i| next if i.odd?; a << i }; a; end
    def step_param_write; a = []; 1.step(3, 1) { |i| i += 10; a << i }; a; end
    def step_upvar; t = 0; last = nil; 2.step(8, 2) { |i| t += i; last = i }; [t, last]; end
    def step_ivar; @acc = []; 0.step(6, 3) { |i| @acc << i }; @acc; end
    def step_nested_block; a = []; 1.step(2, 1) { |i| [10, 20].each { |k| a << i + k } }; a; end
    def step_nested_step; a = []; 1.step(2, 1) { |i| 1.step(2, 1) { |j| a << i * j } }; a; end
    def step_big; a = []; 1073741820.step(1073741823, 1) { |i| a << i }; a; end
    def step_return; 1.step(9, 1) { |i| return i if i == 4 }; :none; end
    def step_raise; 1.step(9, 1) { |i| raise ArgumentError, "at #{i}" if i == 3 }; end
    def upto_sum; s = 0; 3.upto(6) { |i| s += i }; s; end
    def upto_empty; a = []; 6.upto(3) { |i| a << i }; a; end
    def upto_value; 3.upto(5) { |i| i }; end
    def upto_dynamic; n = 5; a = []; n.upto(n + 2) { |i| a << i }; a; end
    def downto_list; a = []; 6.downto(3) { |i| a << i }; a; end
    def downto_empty; a = []; 3.downto(6) { |i| a << i }; a; end
    def downto_dynamic; n = 5; a = []; (n * 2).downto(n + 2) { |i| a << i }; a; end
    # A bound outside the narrowest Fixnum range: not provable, so it keeps the per-loop test.
    def upto_wide; n = 1073741823; a = []; n.upto(n + 2) { |i| a << i }; a; end
    def downto_wide; n = 1073741823; a = []; (n + 2).downto(n) { |i| a << i }; a; end
    # Not provably Integer, or not a loop this pass may take: the call stays.
    def float_recv; a = []; 1.0.step(2.0, 0.5) { |x| a << x }; a; end
    def float_limit; a = []; 1.step(2.5, 1) { |x| a << x }; a; end
    def float_step; a = []; 1.step(2, 0.5) { |x| a << x }; a; end
    def float_upto; a = []; 1.upto(3.5) { |x| a << x }; a; end
    def float_dynamic; a = []; f = 2.5; 1.upto(f + 1) { |x| a << x }; a; end
    def unknown_limit(n); a = []; 1.step(n, 2) { |x| a << x }; a; end
    def unknown_step(k); a = []; 1.step(9, k) { |x| a << x }; a; end
    def zero_step; 0.step(5, 0) { |x| x }; end
    def no_block; 1.step(7, 3).to_a; end
    def range_step; a = []; (1..7).step(3) { |x| a << x }; a; end
  end
RUBY

EDGE_DRIVER = <<~'RUBY'
  ed = StEdge.new
  %i[up_fit up_over up_recv_over up_both_over down_fit down_over step_fit step_over step_exact
     step_neg_fit step_neg_over step_neg_exact over_break fit_break over_next over_return over_raise
     over_upvar over_ivar over_nested over_value over_noparam over_param_write empty_fit empty_over].each do |name|
    out = begin
      ed.send(name).inspect
    rescue => e
      "#{e.class}: #{e.message}"
    end
    puts "#{name}: #{out}"
  end
  puts 'end'
RUBY

# The resumable loops answer across Fiber yields: the proven one is compiled, the wide one stays interpreted.
FLAT_DRIVER = <<~'RUBY'
  [StFlat, StFlatWide].each do |k|
    fl = k.new
    puts "#{k}: #{Array.new(4) { fl.go }.inspect}"
  end
RUBY

DRIVER = <<~'RUBY'
  fx = StFx.new
  %i[step_sum step_value step_neg step_empty step_empty_neg step_one step_noparam step_break step_break_none
     step_next step_param_write step_upvar step_ivar step_nested_block step_nested_step step_big step_return
     step_raise upto_sum upto_empty upto_value upto_dynamic downto_list downto_empty downto_dynamic
     upto_wide downto_wide float_recv float_limit float_step float_upto float_dynamic zero_step no_block range_step].each do |name|
    out = begin
      fx.send(name).inspect
    rescue => e
      "#{e.class}: #{e.message}"
    end
    puts "#{name}: #{out}"
  end
  [[3], [0], [9], [-2]].each { |args| puts "unknown_limit#{args}: #{(fx.unknown_limit(*args) rescue $!.class).inspect}" }
  [[2], [-2], [0], [1.5]].each { |args| puts "unknown_step#{args}: #{(fx.unknown_step(*args) rescue $!.class).inspect}" }
  puts 'end'
RUBY

INLINED = %w[step_sum step_value step_neg step_empty step_empty_neg step_one step_noparam step_break step_break_none
             step_next step_param_write step_upvar step_ivar step_nested_block step_nested_step step_big step_return
             step_raise upto_sum upto_empty upto_value downto_list downto_empty
             upto_dynamic downto_dynamic].freeze
# upto_dynamic / downto_dynamic take a bound computed by arithmetic on a literal local (`n + 2`, n = 5): its
# interval lies inside the narrowest Fixnum range, so it is a proven Fixnum (ADR 0326) and needs no test.
# upto_wide / downto_wide compute past that range: since ADR 0279 an Integer but not a proven Fixnum (it can
# overflow into a bignum), so the loop is inlined behind one Fixnum test per loop, with the original call as
# the else branch (ADR 0287).
GUARDED = %w[upto_wide downto_wide].freeze
KEPT = %w[float_recv float_limit float_step float_upto float_dynamic unknown_limit unknown_step zero_step no_block
          range_step].freeze

# Guarded loops with a bound at the edges of the Fixnum range; `top` is the build's largest Fixnum
# (2**62 - 1, or 2**30 - 1 on the 32-bit-mrb_int targets), `bot` the smallest. Every edge method is
# guarded: a receiver or limit comes from arithmetic on a local that is not a proven Fixnum.
EDGE_METHODS = %w[up_fit up_over up_recv_over up_both_over down_fit down_over step_fit step_over step_exact
                  step_neg_fit step_neg_over step_neg_exact over_break fit_break over_next over_return over_raise
                  over_upvar over_ivar over_nested over_value over_noparam over_param_write empty_fit empty_over].freeze

def edge_fixture(top)
  <<~RUBY
    class StEdge
      def up_fit; t = #{top}; n = t - 2; a = []; n.upto(n + 2) { |i| a << i }; a; end
      def up_over; t = #{top}; n = t - 1; a = []; n.upto(n + 2) { |i| a << i }; a; end
      def up_recv_over; t = #{top}; n = t + 1; a = []; n.upto(n + 1) { |i| a << i }; a; end
      def up_both_over; t = #{top}; n = t + 3; a = []; n.upto(n + 2) { |i| a << i }; a; end
      def down_fit; t = #{top}; n = -t - 1 + 2; a = []; n.downto(n - 2) { |i| a << i }; a; end
      def down_over; t = #{top}; n = -t - 1 + 1; a = []; n.downto(n - 2) { |i| a << i }; a; end
      def step_fit; t = #{top}; n = t - 5; a = []; n.step(n + 4, 3) { |i| a << i }; a; end
      def step_over; t = #{top}; n = t - 5; a = []; n.step(n + 8, 3) { |i| a << i }; a; end
      def step_exact; t = #{top}; n = t - 6; a = []; n.step(n + 6, 3) { |i| a << i }; a; end
      def step_neg_fit; t = #{top}; n = -t - 1 + 5; a = []; n.step(n - 4, -3) { |i| a << i }; a; end
      def step_neg_over; t = #{top}; n = -t - 1 + 5; a = []; n.step(n - 8, -3) { |i| a << i }; a; end
      def step_neg_exact; t = #{top}; n = -t - 1 + 6; a = []; n.step(n - 6, -3) { |i| a << i }; a; end
      def over_break; t = #{top}; n = t - 1; n.upto(n + 5) { |i| break i if i > t }; end
      def fit_break; t = #{top}; n = t - 4; n.upto(n + 4) { |i| break i + 1 if i == t - 1 }; end
      def over_next; t = #{top}; n = t - 2; a = []; n.upto(n + 4) { |i| next if i.odd?; a << i }; a; end
      def over_return; t = #{top}; n = t - 1; n.upto(n + 3) { |i| return i if i > t }; :none; end
      def over_raise; t = #{top}; n = t - 1; n.upto(n + 3) { |i| raise ArgumentError, "at \#{i}" if i > t }; end
      def over_upvar; t = #{top}; n = t - 1; c = 0; last = nil; n.upto(n + 3) { |i| c += 1; last = i }; [c, last]; end
      def over_ivar; t = #{top}; n = t - 1; @acc = []; n.upto(n + 3) { |i| @acc << i }; @acc; end
      def over_nested; t = #{top}; n = t - 1; a = []; n.upto(n + 2) { |i| [1, 2].each { |k| a << i + k } }; a; end
      def over_value; t = #{top}; n = t - 1; n.upto(n + 2) { |i| i }; end
      def over_noparam; t = #{top}; n = t - 1; c = 0; n.upto(n + 3) { c += 1 }; c; end
      def over_param_write; t = #{top}; n = t - 1; a = []; n.upto(n + 2) { |i| i += 10; a << i }; a; end
      def empty_fit; t = #{top}; n = t - 1; a = []; n.upto(n - 1) { |i| a << i }; a; end
      def empty_over; t = #{top}; n = t + 2; a = []; n.downto(n + 1) { |i| a << i }; a; end
    end
  RUBY
end

# Fibers: a loop that may yield cannot fall back to a call, so a computed bound that is not a proven Fixnum keeps it
# interpreted; a proven one (StFlat, interval inside the Fixnum range) is inlined without a guard.
FLAT_FIXTURE = <<~'RUBY'
  class StFlat
    def initialize; @f = Fiber.new { run; :done }; end
    def go; @f.resume; end
    def run; n = 3; n.upto(n + 2) { |i| Fiber.yield i }; end
  end
  class StFlatWide
    def initialize; @f = Fiber.new { run; :done }; end
    def go; @f.resume; end
    def run; n = 1073741823; n.upto(n + 2) { |i| Fiber.yield i }; end
  end
RUBY

def body_of(code, fn, owner = 'StFx')
  code[/^mrb_value #{owner}_#{fn}_impl\(mrb_state\* M.*?(?=^(?:static )?mrb_value \w+\(mrb_state\* M|\z)/m].to_s
end

# The fixtures' top Fixnum per build: Fixnum is 62 bits under 64-bit mrb_int word boxing, 30 on the
# 32-bit targets. Literals, not shifts (AGENTS.md: a computed 32-bit-crossing constant breaks irep load).
TOP_FIXNUM = { 64 => '4611686018427387903', 32 => '1073741823' }.freeze
# A literal past the 32-bit range is emitted as a bigint literal, which needs the gem's define in
# the fixture's own compile (the libmruby build has it from mruby-bigint).
BIGINT_FLAG = '-DMRB_USE_BIGINT'

unless Bc2cppFixtureRuntime.mrbc && system(Bc2cppFixtureRuntime.mrbc, '--version', out: File::NULL, err: File::NULL)
  puts '  SKIP: no host mrbc (set MRBC); the generated-code and behavioural checks need it'
  exit 0
end

Dir.mktmpdir do |dir|
  code, err = Bc2cppFixtureRuntime.generate(FIXTURE, dir)
  INLINED.each do |fn|
    body = body_of(code, fn)
    check.call("#{fn}: the loop is inlined", body.include?('bc2cpp_step_i_') && !body.include?('#error'))
  end
  GUARDED.each do |fn|
    body = body_of(code, fn)
    check.call("#{fn}: an arithmetic bound is inlined behind a Fixnum test, with the call as the else branch",
               body.include?('STEP_LOOP_GUARD') && body.include?('bc2cpp_step_i_') && body.match?(/if \(mrb_fixnum_p\(r\d+\)( && mrb_fixnum_p\(r\d+\))*\) \{/) &&
               body.include?('BLOCK_FALLBACK') && !body.include?('#error'))
  end
  check.call('a proven Fixnum bound needs no guard', INLINED.none? { |fn| body_of(code, fn).include?('STEP_LOOP_GUARD') })
  KEPT.each do |fn|
    body = body_of(code, fn)
    check.call("#{fn}: the call is kept", !body.empty? && !body.include?('bc2cpp_step_i_') && !body.include?('#error'))
  end
  check.call('a literal limit is a constant of the loop', body_of(code, 'step_sum').include?('const long long bc2cpp_step_limit_'))
  check.call('the counter cannot wrap a 32-bit mrb_int (a long long)', body_of(code, 'step_big').include?('for (long long bc2cpp_step_i_'))
  check.call('no compiled method needed a resumable frame', !code.include?('RESUMABLE_'))
  check.call('the diagnostics list the inlined methods as compiled',
             INLINED.all? { |fn| err.include?("StFx_#{fn} / StFx_#{fn}_impl") })
end

Dir.mktmpdir do |dir|
  code, = Bc2cppFixtureRuntime.generate(edge_fixture(TOP_FIXNUM[64]), dir, only_owners: %w[StEdge])
  EDGE_METHODS.each do |fn|
    body = body_of(code, fn, 'StEdge')
    check.call("#{fn}: guarded and inlined", body.include?('STEP_LOOP_GUARD') && body.include?('bc2cpp_step_i_') && !body.include?('#error'))
  end
  # The guard is per loop: no test inside the counting loop.
  loop_body = body_of(code, 'up_fit', 'StEdge')[/for \(long long.*?\n\s+mrb_value r\d+ = mrb_nil_value/m].to_s
  check.call('the Fixnum test sits before the loop, not in it', !loop_body.include?('mrb_fixnum_p'))
end

Dir.mktmpdir do |dir|
  code, err = Bc2cppFixtureRuntime.generate(FLAT_FIXTURE, dir, only_owners: %w[StFlat StFlatWide])
  check.call('a resumable loop with a computed bound outside the Fixnum range is not guarded (its body may yield)',
             !code.include?('STEP_LOOP_GUARD') && err.include?('StFlatWide#run stays interpreted'))
  check.call('a resumable loop with a proven Fixnum computed bound is inlined without a guard',
             !err.include?('StFlat#run stays interpreted') && code.include?('Lbc2cpp_step_top_') && !code.include?('STEP_LOOP_GUARD'))
end

# [label, build dir, mrbc, extra flags, width]
builds = []
full = Bc2cppFixtureRuntime.full_or_build
builds << ['mrb_int 64', full, ENV['MRBC'], BIGINT_FLAG, 64] if full
# -no-pie: the fallback glue keeps a block function's address in an mrb_int, which a 32-bit mrb_int on a
# 64-bit host only holds for code below 2 GB (a real 32-bit target has 32-bit pointers).
if ENV['BC2CPP_MRUBY_FULL32'] && ENV['BC2CPP_MRBC32'] && Bc2cppFixtureRuntime.compiler?
  builds << ['mrb_int 32 (MRB_INT32, 31-bit Fixnums)', ENV['BC2CPP_MRUBY_FULL32'], ENV['BC2CPP_MRBC32'],
             "-DMRB_32BIT -DMRB_INT32 -no-pie #{BIGINT_FLAG}", 32]
end
puts '  SKIP behavioural comparison: needs a full-core libmruby (BC2CPP_MRUBY_FULL, or rake, g++ and 3rd/mruby)' if builds.empty?

builds.each do |label, build, mrbc, flags, width|
  puts "-- fixtures on real mruby (#{label}), interpreted and compiled"
  saved = ENV.values_at('MRBC', 'BC2CPP_CXXFLAGS')
  ENV['MRBC'] = mrbc
  ENV['BC2CPP_CXXFLAGS'] = flags
  begin
    Dir.mktmpdir do |dir|
      source = FIXTURE + edge_fixture(TOP_FIXNUM[width]) + FLAT_FIXTURE
      _code, err = Bc2cppFixtureRuntime.generate(source, dir)
      body = <<~CPP
        static int scenario(mrb_state* M) {
          std::fflush(stdout);
          const char* src = R"BCD(#{DRIVER}#{FLAT_DRIVER}#{EDGE_DRIVER})BCD";
          mrb_load_string(M, src);
          if (M->exc) { mrb_print_error(M); M->exc = nullptr; return 1; }
          return 0;
        }
      CPP
      built, output = Bc2cppFixtureRuntime.run(dir, err, %w[StFx StEdge StFlat StFlatWide], body, build: build, full: true)
      check.call('the fixtures build and run', built)
      sections = Bc2cppFixtureRuntime.sections(output)
      interpreted = sections['interpreted']
      compiled = sections['compiled']
      check.call("the driver prints #{interpreted&.size} lines in both runs",
                 interpreted && interpreted.last == 'end' && compiled&.last == 'end')
      check.call('interpreted and compiled runs print the same', interpreted == compiled)
      if interpreted && compiled
        interpreted.zip(compiled).reject { |a, b| a == b }.first(8).each { |a, b| puts "    interpreted: #{a}\n    compiled:    #{b}" }
        past_top = (TOP_FIXNUM[width].to_i + 1).to_s
        check.call("the interpreter really crosses the Fixnum range (#{past_top} appears)",
                   interpreted.any? { |line| line.start_with?('up_over:') && line.include?(past_top) })
        check.call('every edge method answered', EDGE_METHODS.all? { |fn| interpreted.any? { |line| line.start_with?("#{fn}:") } })
      end
      puts output.lines.last(20).join unless built
    end
  ensure
    ENV['MRBC'], ENV['BC2CPP_CXXFLAGS'] = saved
  end
end

if failures.empty?
  puts 'bc2cpp step inline check: PASS'
else
  warn "bc2cpp step inline check: #{failures.size} failure(s)"
  exit 1
end
